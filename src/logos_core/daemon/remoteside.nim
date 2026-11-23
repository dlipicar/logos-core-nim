## logosd's side of the remote processes (Tier 5 step 5-7a-2; DECISIONS G410,
## G411; 5-7a plan §3.1, §3.6). docs/REMOTE.md.
##
## - **Restart locks at start** (plan §3.1 item 3): before it reads the remote
##   trust input, logosd takes every restart lock under `<work_dir>/remote/`,
##   without waiting, retried for 2 s [IMPL]. A lock it cannot take means a
##   remote process of an earlier run is alive: logosd refuses to start and
##   names the lock and the pid that process wrote into it. So no TLS process
##   outlives the run that gave it its snapshot (owner decision B3).
## - **The remote hooks** (`host.runtimeSetRemoteHooks`): the certificate the
##   listener processes serve with, and the signer that answers their sign
##   requests on the remote supervisor's one sign thread:
##   - `logosd` (the default): logosd's signing service (`signsvc`), with
##     logosd's limit for each process;
##   - `key-holder`: logosd starts `logos_keyholder` (`spawnKeyHolder`) and
##     relays each request to it, after logosd's own checks and limit
##     (`signsvc.HolderRelay`), waiting at most 5 s for the answer [IMPL]; the
##     holder ending answers `unavailable` from then on;
##   - `process-copy` (tests only): the key itself, handed to each process.
## - **Its log**: each remote process's end and restart, as a log line.
##
## On Windows logosd has no remote side (TRANSPORT l.1133): the lock check
## finds nothing and no hooks are made.

{.push raises: [].}

import std/tables
import results
import ./[config, credential, daemon_config_types, remoteexposure, session, signsvc]
import ../runtime/host

when defined(posix):
  import std/[monotimes, os, posix, strutils, times]
  import logos_sdk/base/parentwatch
  import ../transport/tls/p256
  import ./logging

  proc lcnSpawn(
    path: cstring,
    argv, envp: cstringArray,
    carrier, listener, lock: cint,
    pid: ptr cint,
  ): cint {.importc: "lcn_host_spawn", cdecl.}
    ## `runtime/hostspawn.c`, compiled with the Runtime (`hostsup`)

  proc flock(fd: cint, op: cint): cint {.importc, header: "<sys/file.h>".}

  var ONoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

const
  LockRetryMs = 2_000 ## [IMPL; plan §3.1 item 3]
  HolderAnswerMs = 5_000 ## [IMPL] how long a relayed request waits for the holder

type
  RemoteSideObj = object
    ## What the hooks read. Only the remote supervisor's sign thread uses it
    ## while the Runtime runs; logosd frees it once the Runtime is destroyed.
    ## `limits`, `relay` and `reader` are the sign thread's: made and grown
    ## there, and emptied there by `signEndHook` before it exits, since under
    ## refc no thread frees memory another thread's heap made.
    signing: RemoteSigning
    service: pointer ## rsLogosd: the Daemon's SignService, borrowed
    limits: Table[uint64, ProcessSigning]
    relay: HolderRelay
    holderFd: cint ## rsKeyHolder: logosd's end of the holder's channel; -1: gone
    holderPid: cint
    asked: uint64
    reader: FrameReader
    readerMade: bool ## `reader` made, on the sign thread
    exposure: ExposureSink ## [G412; Q4] the engine's write of durable disables

  RemoteSide* = ptr RemoteSideObj

when defined(posix):
  # Restart locks ----------------------------------------------------------------------------

  proc lockHolderPid(path: string): string =
    try:
      readFile(path).strip
    except IOError, OSError:
      ""

  proc checkRemoteLocks*(workDir: string): Result[void, string] =
    ## [plan §3.1 item 3] Every restart lock under `<work_dir>/remote/` free,
    ## or why not, naming the lock and its process.
    let dir = remoteLockDir(workDir)
    if not dirExists(dir):
      return ok()
    var paths: seq[string]
    try:
      for kind, path in walkDir(dir):
        if kind == pcFile and path.endsWith(".lock"):
          paths.add(path)
    except OSError:
      return err("cannot read " & dir)
    for path in paths:
      let fd = posix.open(cstring(path), O_RDWR or O_CLOEXEC or ONoFollow)
      if fd < 0:
        continue # gone in between
      let until = getMonoTime() + initDuration(milliseconds = LockRetryMs)
      var taken = false
      while true:
        if flock(fd, 2 or 4) == 0: # LOCK_EX | LOCK_NB
          taken = true
          break
        if getMonoTime() >= until:
          break
        sleep(100)
      discard posix.close(fd) # which frees the lock
      if not taken:
        let pid = lockHolderPid(path)
        return err(
          "the remote restart lock " & path & " is held" &
            (if pid.len > 0: " by process " & pid else: "") &
            ", a remote process of an earlier run: logosd starts once it has ended"
        )
    ok()

  # The key holder ----------------------------------------------------------------------------

  proc spawnKeyHolder(
      program: string, s: Session
  ): Result[tuple[fd: cint, pid: cint], string] =
    ## [G410] `logos_keyholder --session=<dir> --parent=<pid>`, its fd 3 one
    ## end of a socket pair whose other end logosd keeps.
    var pair: array[2, cint]
    if socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0:
      return err("no socket pair: " & $strerror(errno))
    for fd in pair:
      discard fcntl(fd, F_SETFD, FD_CLOEXEC)
    let session = "--session=" & s.dir
    let parent = ParentFlag & $getpid()
    var argv = [cstring("logos_keyholder"), cstring(session), cstring(parent), nil]
    var envp = [cstring(nil)]
    var pid: cint = -1
    let r = lcnSpawn(
      cstring(program),
      cast[cstringArray](addr argv[0]),
      cast[cstringArray](addr envp[0]),
      pair[1],
      -1,
      -1,
      addr pid,
    )
    discard posix.close(pair[1])
    if r != 0:
      discard posix.close(pair[0])
      return err("cannot start " & program & ": " & $strerror(r))
    ok((pair[0], pid))

  proc holderGone(side: RemoteSide) =
    if side.holderFd >= 0:
      discard posix.close(side.holderFd)
      side.holderFd = -1
      {.cast(gcsafe).}:
        logWarn("remote signing: the key holder is gone; signing is unavailable")

  proc holderAsk(side: RemoteSide, process: uint64, req: LcnRchMessage): SignResult =
    ## One relayed request and its answer, synchronously: an answer to an
    ## earlier request that timed out is dropped.
    if side.holderFd < 0:
      return unavailable()
    let f = frameOf(req).valueOr:
      return unavailable()
    var off = 0
    while off < f.len:
      let n = posix.write(side.holderFd, unsafeAddr f[off], f.len - off)
      if n < 0:
        if errno == EINTR:
          continue
        side.holderGone()
        return unavailable()
      off += n
    var buf: array[4096, byte]
    let until = getMonoTime() + initDuration(milliseconds = HolderAnswerMs)
    while true:
      let left = int((until - getMonoTime()).inMilliseconds)
      if left <= 0:
        side.relay.forget(process)
        return unavailable()
      var pfd = TPollfd(fd: side.holderFd, events: POLLIN)
      let p = poll(addr pfd, 1, cint(left))
      if p < 0 and errno == EINTR:
        continue
      if p == 0:
        continue # the deadline, checked above
      if p < 0:
        side.holderGone()
        return unavailable()
      let n = posix.read(side.holderFd, addr buf[0], buf.len)
      if n < 0 and errno == EINTR:
        continue
      if n <= 0:
        side.holderGone()
        return unavailable()
      let frames = side.reader.feed(buf.toOpenArray(0, n - 1)).valueOr:
        side.holderGone()
        return unavailable()
      for body in frames:
        let m = decodeMessage(body).valueOr:
          side.holderGone()
          return unavailable()
        let back = side.relay.returned(m).valueOr:
          {.cast(gcsafe).}:
            logWarn("remote signing: " & error)
          side.holderGone()
          return unavailable()
        if back[0] == process and back[1].answerId == side.asked:
          return answerOf(back[1])

  # The hooks ---------------------------------------------------------------------------------

  proc signHook(
      data: pointer, process: uint64, role: TlsRole, alg: uint16, input: seq[byte]
  ): SignResult {.nimcall, gcsafe, raises: [].} =
    let side = cast[RemoteSide](data)
    {.cast(gcsafe).}:
      if not side.readerMade:
        side.reader = newRchReader()
        side.readerMade = true
      var p = side.limits.getOrDefault(process, newProcessSigning(role))
      inc side.asked
      let m = LcnRchSign(id: side.asked, alg: alg, input: input)
      case side.signing
      of rsLogosd:
        let svc {.cursor.} = cast[SignService](side.service)
        result = answerOf(svc.answer(p, m))
      of rsKeyHolder:
        let req = side.relay.relay(process, p, m)
        result =
          if req.isErr:
            answerOf(req.error)
          else:
            side.holderAsk(process, req.get)
      of rsProcessCopy:
        result = refused()
      side.limits[process] = p

  proc signEndHook(data: pointer) {.nimcall, gcsafe, raises: [].} =
    ## On the sign thread, as it ends: what `signHook` made there.
    let side = cast[RemoteSide](data)
    reset(side.limits)
    reset(side.relay)
    reset(side.reader)
    side.readerMade = false

  proc noteHook(data: pointer, text: string) {.nimcall, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      logInfo(text)

  proc newRemoteSide*(
      s: Session,
      settings: RemoteSettings,
      dc: LcnDcRemote,
      cred: CredentialInfo,
      service: SignService,
  ): Result[(RemoteSide, RemoteHooks), string] =
    ## The remote side for this start, and the hooks for the Runtime. With
    ## `rsLogosd`, `service` is the Daemon's, which outlives the Runtime. `dc`
    ## is the configuration's `remote`, whose entries' digests the durable
    ## disables carry (Q4).
    let sink = ?newExposureSink(s, dc)
    var hooks = RemoteHooks(
      certificate: cred.certificate,
      note: noteHook,
      persist: sink.persist,
      persistData: sink,
    )
    var holder = (fd: cint(-1), pid: cint(-1))
    case settings.signing
    of rsLogosd:
      if service == nil:
        closeExposureSink(sink)
        return err("no signing service")
    of rsKeyHolder:
      holder = spawnKeyHolder(settings.keyHolder, s).valueOr:
        closeExposureSink(sink)
        return err(error)
      logInfo("remote signing: the key holder runs as process " & $holder.pid)
    of rsProcessCopy:
      when defined(logosTestSigning):
        let key = loadCredentialKey(cred.dir).valueOr:
          closeExposureSink(sink)
          return err(error)
        defer:
          key.free()
        hooks.testKey = toPkcs8(key).valueOr:
          closeExposureSink(sink)
          return err(error)
      else:
        closeExposureSink(sink)
        return err("remote.signing \"process-copy\" needs a logosd built for tests")
    let side = createShared(RemoteSideObj)
    side.signing = settings.signing
    side.service = cast[pointer](service)
    side.holderFd = holder.fd
    side.holderPid = holder.pid
    side.exposure = sink
    if settings.signing != rsProcessCopy:
      hooks.sign = signHook
      hooks.signEnd = signEndHook
      hooks.signData = side
    ok((side, hooks))

  proc closeRemoteSide*(side: RemoteSide) =
    ## Once the Runtime is destroyed (no sign thread runs): the holder's
    ## channel closed, which ends it, and the holder reaped, killed after 2 s.
    if side == nil:
      return
    if side.holderFd >= 0:
      discard posix.close(side.holderFd)
      side.holderFd = -1
    if side.holderPid > 0:
      var status: cint
      let until = getMonoTime() + initDuration(seconds = 2)
      while waitpid(Pid(side.holderPid), status, WNOHANG) == 0:
        if getMonoTime() >= until:
          discard kill(Pid(-side.holderPid), SIGKILL)
          discard waitpid(Pid(side.holderPid), status, 0)
          break
        sleep(20)
      side.holderPid = -1
    closeExposureSink(side.exposure)
    reset(side[])
    freeShared(side)

else:
  proc checkRemoteLocks*(workDir: string): Result[void, string] =
    ok()

  proc newRemoteSide*(
      s: Session,
      settings: RemoteSettings,
      dc: LcnDcRemote,
      cred: CredentialInfo,
      service: SignService,
  ): Result[(RemoteSide, RemoteHooks), string] =
    err("the remote profiles are not supported on this platform")

  proc closeRemoteSide*(side: RemoteSide) =
    discard

{.pop.}
