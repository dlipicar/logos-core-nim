## Child processes for the transport I/O tests. Spawned with `posix_spawn`, never
## `fork` (ThreadSanitizer does not support `fork` in a threaded process). The
## control socket becomes the child's fd 3 and an inherited listener its fd 4;
## every other descriptor the parent opened is close-on-exec. A child that does
## not exit by its deadline is killed, and that fails the test.

import std/[monotimes, os, posix, times]
import ../../src/logos_core/transport/io/sock

type Peer* = object
  pid*: Pid
  ctl*: cint ## the parent's end of the control channel, or -1
  output*: cint ## the read end of the child's stdout, or -1

var environ {.importc.}: cstringArray

proc fcntlDup(
  fd, cmd, arg: cint
): cint {.importc: "fcntl", header: "<fcntl.h>", varargs.}

let F_DUPFD_CLOEXEC {.importc, header: "<fcntl.h>".}: cint

proc dupCloexec*(fd: cint): cint =
  ## A close-on-exec copy of `fd`.
  result = fcntlDup(fd, F_DUPFD_CLOEXEC, 0)
  doAssert result >= 0

proc dupHigh(fd: cint): cint =
  ## A close-on-exec copy above every fd the child is given, so `dup2` onto 3
  ## or 4 never meets itself (and leaves the target open across exec).
  result = fcntlDup(fd, F_DUPFD_CLOEXEC, 64)
  doAssert result >= 0

proc spawnPeer*(
    exe: string,
    args: openArray[string],
    listener: cint = -1,
    withCtl = true,
    captureStdout = false,
    prefix: openArray[string] = [],
): Peer =
  ## Runs `prefix & exe & args` (`prefix`: e.g. `sudo -n -u user`).
  var fa: Tposix_spawn_file_actions
  doAssert posix_spawn_file_actions_init(fa) == 0
  var temps: seq[cint]
  result.ctl = -1
  result.output = -1
  if withCtl:
    var sp: array[2, cint]
    doAssert socketPair(addr sp) == 0
    result.ctl = sp[0]
    let c = dupHigh(sp[1])
    discard fdClose(sp[1])
    temps.add(c)
    doAssert posix_spawn_file_actions_adddup2(fa, c, 3) == 0
  if listener >= 0:
    let l = dupHigh(listener)
    temps.add(l)
    doAssert posix_spawn_file_actions_adddup2(fa, l, 4) == 0
  if captureStdout:
    var p: array[2, cint]
    doAssert pipe(p) == 0
    discard fcntl(p[0], F_SETFD, FD_CLOEXEC)
    let w = dupHigh(p[1])
    discard posix.close(p[1])
    temps.add(w)
    result.output = p[0]
    doAssert posix_spawn_file_actions_adddup2(fa, w, 1) == 0
  var attr: Tposix_spawnattr
  doAssert posix_spawnattr_init(attr) == 0
  var all = @prefix
  all.add(exe)
  all.add(@args)
  let argv = allocCStringArray(all)
  let r = posix_spawnp(result.pid, cstring(all[0]), fa, attr, argv, environ)
  deallocCStringArray(argv)
  discard posix_spawn_file_actions_destroy(fa)
  discard posix_spawnattr_destroy(attr)
  for t in temps:
    discard fdClose(t)
  doAssert r == 0, "posix_spawn " & all[0] & ": " & $strerror(r)

proc release(p: var Peer) =
  if p.ctl >= 0:
    discard fdClose(p.ctl)
    p.ctl = -1
  if p.output >= 0:
    discard posix.close(p.output)
    p.output = -1

proc waitPeer*(p: var Peer, timeoutMs = 30_000): int =
  ## The child's exit status; -1 when it was killed at the deadline or ended
  ## by a signal.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  var status: cint
  while true:
    let r = waitpid(p.pid, status, WNOHANG)
    if r == p.pid:
      break
    if getMonoTime() > deadline:
      discard kill(p.pid, SIGKILL)
      discard waitpid(p.pid, status, 0)
      p.release()
      return -1
    sleep(5)
  p.release()
  if WIFEXITED(status):
    int(WEXITSTATUS(status))
  else:
    -1

proc killPeer*(p: var Peer) =
  ## SIGKILL, then reap.
  discard kill(p.pid, SIGKILL)
  var status: cint
  discard waitpid(p.pid, status, 0)
  p.release()

proc readLine*(p: Peer, timeoutMs = 10_000): string =
  ## One line of the child's captured stdout, without the newline.
  var c: char
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    var pfd = TPollfd(fd: p.output, events: POLLIN)
    if posix.poll(addr pfd, 1, 50) <= 0:
      continue
    if posix.read(p.output, addr c, 1) != 1:
      return result
    if c == '\n':
      return result
    result.add(c)
