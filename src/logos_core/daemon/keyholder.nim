## `logos_keyholder`: the key holder of logosd's hardened signing mode,
## `remote.signing = "key-holder"` (Tier 5 step 5-7a-1; DECISIONS G410; owner
## decision B1; 5-7a plan §3.6). docs/REMOTE.md, "Who signs".
##
## logosd starts it with `--session=<dir> --parent=<logosd's pid>` and one end
## of a socket pair as fd 3, and relays every TLS process's sign request to it
## there (`signsvc.HolderRelay`). The holder:
##
## 1. binds its life to logosd's first (`parentwatch`, as the Module Host
##    does), and exits when logosd is gone: fd 3 at its end, or another parent;
## 2. loads the key from `<session>/remote/credential/key.p8` itself
##    (`credential.loadCredentialKey`): logosd never opens that file in this
##    mode;
## 3. answers each `holder_sign` with the same checks logosd's own service
##    runs (`signsvc.signWith`: `checkSignInput` for the role logosd names,
##    then a rate limit of its own, 100 a second with bursts of 200 [IMPL]);
## 4. keeps its own count of signatures and refusals in
##    `<session>/remote/keyholder.count`, carried over from its earlier runs,
##    written every 60 s while it changes and at its exit [IMPL]. logosd neither
##    writes nor reads it; `logosctl remote credential show` prints it.
##
## What the mode gives, and what it does not: docs/REMOTE.md. Any other message
## on fd 3, or one that does not decode, ends the holder (exit 1).

{.push raises: [].}

import std/[atomics, os, posix, strutils]
from std/cmdline import commandLineParams
import results
import logos_sdk/base/[entrymarks, parentwatch]
import ../remote/carrier
import ../transport/tls/p256
import ./[credential, session, signsvc]

const
  ChannelFd* = cint(3) ## the socket pair to logosd
  SessionFlag* = "--session="
  PollMs = 1000 ## [IMPL] how often the holder looks at its parent and its count

var stopFlag: Atomic[bool]

proc onStop(sig: cint) {.noconv, lcnOwnRuntime: "this program's signal handler".} =
  stopFlag.store(true)

proc say(msg: string) =
  try:
    stderr.writeLine("logos_keyholder: " & msg)
  except IOError:
    discard

proc ended(msg: string, code = 1) {.noreturn.} =
  if msg.len > 0:
    say(msg)
  quit(code)

proc writeAll(fd: cint, data: openArray[byte]): bool =
  var off = 0
  while off < data.len:
    let n = posix.write(fd, unsafeAddr data[off], data.len - off)
    if n < 0:
      if errno == posix.EINTR:
        continue
      return false
    off += n
  true

proc sessionArg(args: openArray[string]): Opt[Session] =
  for a in args:
    if a.len > SessionFlag.len and a.startsWith(SessionFlag):
      let dir = a[SessionFlag.len .. ^1]
      if dir.isAbsolute:
        return Opt.some(Session(dir: dir))
  Opt.none(Session)

proc runKeyHolder*() {.noreturn.} =
  ## The whole program.
  discard signal(SIGPIPE, SIG_IGN)
  let args = commandLineParams()
  let parent = parentArg(args).valueOr:
    ended("no --parent=<pid> argument", 2)
  bindToParent(parent).isOkOr:
    ended(error)
  let s = sessionArg(args).valueOr:
    ended("no --session=<absolute directory> argument", 2)
  if fcntl(ChannelFd, F_GETFD) < 0:
    ended("no channel on fd 3", 2)
  discard fcntl(ChannelFd, F_SETFD, FD_CLOEXEC)
  let key = loadCredentialKey(s.credentialDir).valueOr:
    ended(error)
  var count = readHolderCount(s).valueOr:
    ended(error)
  var c = count.get(SignCount())
  var limit = newRateLimit(HolderRate, HolderBurst)
  discard signal(SIGTERM, onStop)
  discard signal(SIGINT, onStop)
  var reader = newRchReader()
  var buf = newSeq[byte](64 * 1024)
  var saved = c
  var lastSave = monoNs()

  proc save(force: bool) =
    let now = monoNs()
    if saved != c and (force or now - lastSave >= int64(HolderCountEveryMs) * 1_000_000):
      writeHolderCount(s, c).isOkOr:
        say(error)
      saved = c
      lastSave = now

  proc stop(msg: string, code: int) {.noreturn.} =
    save(true)
    key.free()
    ended(msg, code)

  while true:
    if stopFlag.load:
      stop("", 0)
    if int(getppid()) != parent:
      stop("logosd is gone", 1)
    var pfd = TPollfd(fd: ChannelFd, events: POLLIN)
    let r = poll(addr pfd, 1, PollMs)
    if r < 0:
      if errno == posix.EINTR:
        continue
      stop("cannot wait on the channel", 1)
    if r > 0:
      let n = posix.read(ChannelFd, addr buf[0], buf.len)
      if n < 0:
        if errno == posix.EINTR or errno == posix.EAGAIN:
          continue
        stop("cannot read the channel", 1)
      if n == 0:
        stop("", 0) # logosd closed the channel: an orderly end
      let frames = reader.feed(buf.toOpenArray(0, n - 1)).valueOr:
        stop("a frame over the channel's limit", 1)
      for body in frames:
        let m = decodeMessage(body).valueOr:
          stop("a frame that is not a channel message: " & error, 1)
        if m.kind != LcnRchMessageKind.lcn_Rch_holder_sign:
          stop("a channel message that is not holder_sign", 1)
        let h = m.arm_lcn_Rch_holder_sign
        let res = signWith(key, roleOf(h.role), h.alg, h.input, limit, c, monoNs())
        let f = frameOf(signAnswer(h.id, res)).valueOr:
          stop(error, 1)
        if not writeAll(ChannelFd, f):
          stop("logosd is gone", 1)
    save(false)

{.pop.}
