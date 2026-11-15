## The restart lock of a hosted instance (Tier 4b step 4b-3; DECISIONS G275;
## plan R6) [IMPL]: `<work_dir>/hosts/<hash>.lock`, the directory 0700, one
## file per instance id. The Runtime takes the lock (`flock`, exclusive)
## before it spawns the instance's Module Host, hands it over as the host's
## fd 5 and closes its own copy: the lock is held for as long as the host,
## or a process it forked without exec, lives. After an unclean end of the
## Runtime, a lock that cannot be taken says a host of the previous run may
## still be running (RUNTIME l.613, l.3533).
##
## On Windows there is no Module Host, and every lock is free.

{.push raises: [], gcsafe.}

import std/[os, strutils]
import ../crypto/blake3

when defined(posix):
  import std/posix

  proc flock(fd: cint, op: cint): cint {.importc, header: "<sys/file.h>".}

  const
    LockEx = cint(2)
    LockNb = cint(4)

type LockOutcome* = enum
  loTaken ## the lock is held by the caller now
  loHeld ## another open file holds it: a host may still be running
  loFailed ## the file cannot be made or locked

func lockName(instance: string): string =
  ## A fixed-length name: instance ids may be longer than a file name.
  let d = blake3(instance.toOpenArrayByte(0, instance.high))
  for i in 0 ..< 16:
    result.add(toHex(int(d[i]), 2).toLowerAscii)
  result.add(".lock")

func lockPath*(workDir, instance: string): string =
  workDir / "hosts" / lockName(instance)

proc takeHostLock*(workDir, instance: string): (LockOutcome, cint) =
  ## [G275] Opens (making it if needed) and locks `instance`'s restart lock,
  ## without waiting. `loTaken` gives the descriptor (close-on-exec), which
  ## the caller owns; a closed descriptor releases the lock.
  when defined(posix):
    let dir = workDir / "hosts"
    try:
      createDir(dir)
      setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
    except OSError, IOError:
      return (loFailed, cint(-1))
    let fd = posix.open(
      cstring(lockPath(workDir, instance)), O_RDWR or O_CREAT or O_CLOEXEC, 0o600
    )
    if fd < 0:
      return (loFailed, cint(-1))
    if flock(fd, LockEx or LockNb) != 0:
      let e = errno
      discard posix.close(fd)
      let o = if e == EWOULDBLOCK or e == EAGAIN: loHeld else: loFailed
      return (o, cint(-1))
    (loTaken, fd)
  else:
    (loTaken, cint(-1))

proc closeLock*(fd: cint) =
  when defined(posix):
    if fd >= 0:
      discard posix.close(fd)

proc lockFree*(workDir, instance: string): bool =
  ## [G275] No process holds `instance`'s restart lock: there is no lock
  ## file, or the lock can be taken (it is given back at once).
  when defined(posix):
    let path = lockPath(workDir, instance)
    if not fileExists(path):
      return true
    let fd = posix.open(cstring(path), O_RDWR or O_CLOEXEC)
    if fd < 0:
      return true # [IMPL] gone in between
    let taken = flock(fd, LockEx or LockNb) == 0
    discard posix.close(fd)
    taken
  else:
    true
