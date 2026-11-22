## The test owner of one Module Host (Tier 4b step 4b-3; plan §4.3,
## `test_module_host`): it spawns `logos-module-host` as the supervision does
## (`hostsup.spawnProcess`), holds the Runtime's end of the carrier and speaks
## lane 0 itself, with no engine. Every wait is scaled by `Slow`.

import std/[monotimes, os, posix, times]
import results
import ../../src/logos_core/runtime/[carrier, hostsup]
import ../../src/logos_core/transport/io/sock
import ./[sanitizerenv, slowdown]

export carrier, sanitizerenv, slowdown

type HostRun* = object
  pid*: int
  fd*: cint ## the Runtime's end; -1 once closed
  reader: FrameReader
  queue: seq[seq[byte]]
  eof*: bool ## the host closed its end
  status*: cint ## the raw wait status, once `reaped`
  reaped*: bool

const DefaultWaitMs* = 10_000

proc startHost*(
    program: string,
    env: seq[string] = @[],
    listener = cint(-1),
    lock = cint(-1),
    sanitizerEnv = true,
): HostRun =
  ## `env` (`NAME=value` entries) is the host's whole environment, as the supervision's
  ## allow-list makes it. [G442] With `sanitizerEnv`, the default, this process's `SanitizerEnv`
  ## settings are added, so the host reports where the sanitizer check reads; a case turns it off
  ## only to show a host without them.
  var whole = env
  if sanitizerEnv:
    whole.add(sanitizerSettings())
  var fds: array[2, cint]
  doAssert socketPair(addr fds) == 0, "no socket pair"
  # [G442] sanitizer-env: `whole` has them, added above
  let pid = spawnProcess(program, whole, fds[1], listener, lock)
  discard fdClose(fds[1])
  doAssert pid.isOk, "the host did not start: " & pid.error
  HostRun(pid: pid.get, fd: fds[0], reader: newCarrierReader())

proc sendRaw*(r: HostRun, bytes: openArray[byte]): bool =
  ## Every byte, or false once the host's end is gone.
  var off = 0
  while off < bytes.len:
    let n = sockSend(r.fd, unsafeAddr bytes[off], csize_t(bytes.len - off))
    if n <= 0:
      if wouldBlock(n):
        sleep(1)
        continue
      return false
    off += int(n)
  true

proc send*(r: HostRun, m: LcnCarrierMessage): bool =
  r.sendRaw(frameOf(m).expect("a test message encodes"))

proc next*(r: var HostRun, waitMs = DefaultWaitMs): Opt[LcnCarrierMessage] =
  ## The host's next message; none at its end of the carrier or after
  ## `waitMs` × `Slow`.
  let until = getMonoTime() + initDuration(milliseconds = waitMs * Slow)
  while r.queue.len == 0 and not r.eof:
    let left = (until - getMonoTime()).inMilliseconds
    if left <= 0:
      return Opt.none(LcnCarrierMessage)
    var p = TPollfd(fd: r.fd, events: POLLIN)
    if posix.poll(addr p, 1, cint(min(left, 100))) <= 0:
      continue
    let (outcome, _) = readFrames(r.fd, r.reader, r.queue)
    if outcome != roFrames:
      r.eof = true
  if r.queue.len == 0:
    return Opt.none(LcnCarrierMessage)
  let f = r.queue[0]
  r.queue.delete(0)
  Opt.some(decodeMessage(f).expect("the host's message decodes"))

proc closeCarrier*(r: var HostRun) =
  if r.fd >= 0:
    discard fdClose(r.fd)
    r.fd = -1

proc waitExit*(r: var HostRun, waitMs = DefaultWaitMs): bool =
  ## Reaps the host; false if it is still running after `waitMs` × `Slow`.
  if r.reaped:
    return true
  let until = getMonoTime() + initDuration(milliseconds = waitMs * Slow)
  while true:
    var st: cint
    let w = waitpid(Pid(r.pid), st, WNOHANG)
    if w == Pid(r.pid):
      r.status = st
      r.reaped = true
      return true
    if getMonoTime() >= until:
      return false
    sleep(2)

proc exitedWith*(r: HostRun): int =
  ## The exit status; -1 when it did not exit normally.
  if r.reaped and WIFEXITED(r.status):
    int(WEXITSTATUS(r.status))
  else:
    -1

proc killedBy*(r: HostRun): int =
  if r.reaped and WIFSIGNALED(r.status):
    int(WTERMSIG(r.status))
  else:
    0

proc stop*(r: var HostRun) =
  ## Teardown: the host's group is killed and reaped, the carrier closed.
  if not r.reaped:
    discard kill(Pid(-r.pid), SIGKILL)
    discard r.waitExit()
  r.closeCarrier()
