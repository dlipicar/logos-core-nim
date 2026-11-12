## Durable files: the byte level under the Runtime's state store
## (`runtime/store.nim`) and the Capability Authority's own state directory
## (step 8a). [IMPL] (DECISIONS I82)
##
## - **Atomic replace.** A file is written to `<name>.tmp`, flushed to the
##   medium (`fsync`, or `fcntl(F_FULLFSYNC)` on Darwin, whose `fsync` stops at
##   the drive's cache), renamed over `<name>`, and the directory is flushed
##   too, so after a crash the name holds either the old bytes or the new ones.
##   On Windows: `FlushFileBuffers`, then `MoveFileExW` with
##   `MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH`.
## - **Bounded read.** A file larger than the caller's bound is refused before
##   it is read. Its integrity is the caller's check: the store decodes one
##   deterministic-CBOR value and checks it against its schema.
## - **The lock.** `flock(LOCK_EX | LOCK_NB)` on `<dir>/lock`, opened
##   `O_CLOEXEC` and held until released. Such a lock belongs to the open file
##   description, so a second holder in the same process is refused too. On
##   Windows: `LockFileEx` with `LOCKFILE_EXCLUSIVE_LOCK |
##   LOCKFILE_FAIL_IMMEDIATELY`.
## - **Modes.** A directory is created 0700; one that group or other may access
##   is refused. Files are created 0600. Windows: the directory's ACL is
##   inherited, nothing is checked (docs/HOST-CONFIG.md).
##
## Everything is a plain system call checked by its return value, so every
## proc here is `raises: []`.

{.push raises: [].}

import std/[os, strutils]
import results

when defined(posix):
  import std/posix
elif defined(windows):
  import std/winlean

export results

const
  LockName* = "lock"
  TmpSuffix* = ".tmp"

type DurableLock* = object ## An exclusive lock on a directory, held until `release`.
  when defined(windows):
    handle: Handle
  else:
    fd: cint
  held: bool

when defined(posix):
  var
    LOCK_EX {.importc: "LOCK_EX", header: "<sys/file.h>".}: cint
    LOCK_NB {.importc: "LOCK_NB", header: "<sys/file.h>".}: cint
    LOCK_UN {.importc: "LOCK_UN", header: "<sys/file.h>".}: cint
  proc flock(fd: cint, op: cint): cint {.importc, header: "<sys/file.h>".}
  proc c_rename(a, b: cstring): cint {.importc: "rename", header: "<stdio.h>".}
  when defined(macosx):
    var F_FULLFSYNC {.importc: "F_FULLFSYNC", header: "<fcntl.h>".}: cint

  func describe(what, path: string, e: cint): string =
    what & " " & path & ": " & $strerror(e)

  proc flushFd(fd: cint): cint =
    ## To the medium, not only to the drive.
    when defined(macosx):
      if fcntl(fd, F_FULLFSYNC) == 0:
        return 0
      # Some file systems refuse F_FULLFSYNC; fsync is then the best there is.
    fsync(fd)

  proc flushDir(dir: string): Result[void, string] =
    let fd = posix.open(cstring(dir), O_RDONLY or O_CLOEXEC)
    if fd < 0:
      return err(describe("cannot open directory", dir, errno))
    let rc = flushFd(fd)
    let e = errno
    discard posix.close(fd)
    if rc != 0:
      return err(describe("cannot flush directory", dir, e))
    ok()

elif defined(windows):
  const
    LOCKFILE_FAIL_IMMEDIATELY = 0x1'i32
    LOCKFILE_EXCLUSIVE_LOCK = 0x2'i32

  proc lockFileEx(
    hFile: Handle, dwFlags, dwReserved, nLow, nHigh: DWORD, lpOverlapped: pointer
  ): WINBOOL {.stdcall, dynlib: "kernel32", importc: "LockFileEx".}

  func describe(what, path: string, e: int32): string =
    what & " " & path & ": Windows error " & $e

# Directories ----------------------------------------------------------------------

proc ensurePrivateDir*(path: string): Result[void, string] =
  ## [IMPL] Creates `path` with mode 0700 when it is missing (its parents get
  ## the usual mode). An existing directory that group or other may access is
  ## refused.
  try:
    if not dirExists(path):
      createDir(path.parentDir)
      when defined(posix):
        if mkdir(cstring(path), 0o700) != 0 and errno != EEXIST:
          return err(describe("cannot create", path, errno))
      else:
        createDir(path)
  except CatchableError as e:
    return err(e.msg)
  when defined(posix):
    var s: Stat
    if stat(cstring(path), s) != 0:
      return err(describe("cannot inspect", path, errno))
    if not S_ISDIR(s.st_mode):
      return err(path & " is not a directory")
    if (s.st_mode.cint and 0o077) != 0:
      return err(path & " is accessible to group or other")
    if s.st_uid != getuid():
      return err(path & " is owned by another user")
  ok()

proc fileNames*(dir: string): seq[string] =
  ## The regular files directly in `dir`, by name.
  try:
    for kind, path in walkDir(dir, relative = true):
      if kind == pcFile:
        result.add(path)
  except CatchableError:
    discard

# Reading --------------------------------------------------------------------------

proc readBounded*(path: string, maxBytes: int): Result[Opt[seq[byte]], string] =
  ## The file's bytes; none when it does not exist; an error when it is larger
  ## than `maxBytes` or cannot be read.
  try:
    if not fileExists(path):
      return ok(Opt.none(seq[byte]))
    let size = getFileSize(path)
    if size > maxBytes:
      return err(path & " is larger than " & $maxBytes & " bytes")
    let text = readFile(path)
    if text.len > maxBytes:
      return err(path & " is larger than " & $maxBytes & " bytes")
    var data = newSeq[byte](text.len)
    for i, c in text:
      data[i] = byte(c)
    ok(Opt.some(data))
  except CatchableError as e:
    err("cannot read " & path & ": " & e.msg)

proc removeIfPresent*(path: string): Result[void, string] =
  try:
    if fileExists(path):
      removeFile(path)
    ok()
  except CatchableError as e:
    err("cannot remove " & path & ": " & e.msg)

# Writing --------------------------------------------------------------------------

proc writeAtomic*(dir, name: string, data: openArray[byte]): Result[void, string] =
  ## Replaces `dir/name` with `data`, durably: after a crash the name holds
  ## the old bytes or the new ones, never a mix.
  let path = dir / name
  let tmp = path & TmpSuffix
  when defined(posix):
    let fd =
      posix.open(cstring(tmp), O_WRONLY or O_CREAT or O_TRUNC or O_CLOEXEC, 0o600)
    if fd < 0:
      return err(describe("cannot create", tmp, errno))
    var off = 0
    while off < data.len:
      let n = posix.write(fd, unsafeAddr data[off], data.len - off)
      if n < 0:
        if errno == EINTR:
          continue
        let e = errno
        discard posix.close(fd)
        discard posix.unlink(cstring(tmp))
        return err(describe("cannot write", tmp, e))
      off += n
    if flushFd(fd) != 0:
      let e = errno
      discard posix.close(fd)
      discard posix.unlink(cstring(tmp))
      return err(describe("cannot flush", tmp, e))
    if posix.close(fd) != 0:
      let e = errno
      discard posix.unlink(cstring(tmp))
      return err(describe("cannot close", tmp, e))
    if c_rename(cstring(tmp), cstring(path)) != 0:
      let e = errno
      discard posix.unlink(cstring(tmp))
      return err(describe("cannot rename", tmp, e))
    flushDir(dir)
  elif defined(windows):
    let wtmp = newWideCString(tmp)
    let wpath = newWideCString(path)
    let h =
      createFileW(wtmp, GENERIC_WRITE, 0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0)
    if h == INVALID_HANDLE_VALUE:
      return err(describe("cannot create", tmp, int32(getLastError())))
    var off = 0
    while off < data.len:
      var written: int32
      let chunk = int32(min(data.len - off, 1 shl 30))
      if writeFile(h, unsafeAddr data[off], chunk, addr written, nil) == 0:
        let e = int32(getLastError())
        discard closeHandle(h)
        discard deleteFileW(wtmp)
        return err(describe("cannot write", tmp, e))
      off += int(written)
    if flushFileBuffers(h) == 0:
      let e = int32(getLastError())
      discard closeHandle(h)
      discard deleteFileW(wtmp)
      return err(describe("cannot flush", tmp, e))
    discard closeHandle(h)
    if moveFileExW(wtmp, wpath, MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) == 0:
      let e = int32(getLastError())
      discard deleteFileW(wtmp)
      return err(describe("cannot replace", path, e))
    ok()

proc removeDurably*(dir, name: string): Result[void, string] =
  ## Removes `dir/name` and flushes the directory, so the removal survives a
  ## crash.
  ?removeIfPresent(dir / name)
  when defined(posix):
    flushDir(dir)
  else:
    ok()

# The lock -------------------------------------------------------------------------

proc acquire*(dir: string): Result[DurableLock, string] =
  ## The exclusive lock on `dir`. An error naming "in use" when another holder,
  ## in this process or another, has it.
  let path = dir / LockName
  when defined(posix):
    let fd = posix.open(cstring(path), O_RDWR or O_CREAT or O_CLOEXEC, 0o600)
    if fd < 0:
      return err(describe("cannot open", path, errno))
    if flock(fd, LOCK_EX or LOCK_NB) != 0:
      let e = errno
      discard posix.close(fd)
      if e == EWOULDBLOCK or e == EAGAIN:
        return err("the state store is in use")
      return err(describe("cannot lock", path, e))
    ok(DurableLock(fd: fd, held: true))
  elif defined(windows):
    let h = createFileW(
      newWideCString(path),
      GENERIC_READ or GENERIC_WRITE,
      FILE_SHARE_READ or FILE_SHARE_WRITE,
      nil,
      OPEN_ALWAYS,
      FILE_ATTRIBUTE_NORMAL,
      0,
    )
    if h == INVALID_HANDLE_VALUE:
      return err(describe("cannot open", path, int32(getLastError())))
    var ov: array[32, byte] # an OVERLAPPED, zeroed: offset 0
    if lockFileEx(
      h, DWORD(LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY), 0, 1, 0, addr ov
    ) == 0:
      discard closeHandle(h)
      return err("the state store is in use")
    ok(DurableLock(handle: h, held: true))

proc release*(l: var DurableLock) =
  ## Gives the lock up; closing the descriptor releases it.
  if not l.held:
    return
  l.held = false
  when defined(posix):
    discard flock(l.fd, LOCK_UN)
    discard posix.close(l.fd)
  elif defined(windows):
    discard closeHandle(l.handle)

func isHeld*(l: DurableLock): bool =
  l.held

func isTmp*(name: string): bool =
  name.endsWith(TmpSuffix)
