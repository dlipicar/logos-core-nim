## The protected realization input's file (Tier 5 step 5-3b-2; DECISIONS
## G400) [IMPL].
##
## An instance whose host configuration carries `protected_inputs` gets its
## bytes, at each realization attempt, in `<state_dir>/.lcn-protected-input`.
## The Loader writes the file once the state directory is established (LOADER
## l.282) and before `_MODULE_init`, or before the Module Host starts. It
## removes the file when initialization returns and again at release, and the
## Runtime removes it when the instance is retired. An attempt without
## protected input removes a leftover first, so a module never reads a file
## that was not written for that attempt.
##
## Module code may write its own state directory, so every step inside it is
## relative to a descriptor of the directory and follows no link, as
## `statexfer.nim` and the endpoint code do:
## - the reserved name is inspected without following a link; a directory
##   there fails the write, and anything else there is removed with
##   `unlinkat`, which never follows a link;
## - the bytes go to `.lcn-protected-input.<128 random bits, hex>`, created
##   `O_EXCL | O_NOFOLLOW`, mode 0600 (a name that exists is tried again under
##   a new random name, at most `TempAttempts` times), written, flushed, and
##   moved onto the reserved name with `renameat`; then the directory is
##   flushed.
##
## The directory itself is opened following a link at its end: an operator may
## lay a state assignment out as a link to a directory (`statexfer.ekLinkToDir`),
## and the state root is the Runtime's, not the module's.
##
## On Windows (direct realizations only; the Module Host is POSIX-only) the
## temporary file is created `CREATE_NEW` with `FILE_FLAG_OPEN_REPARSE_POINT`
## and moved with `MoveFileExW`, as `durable.nim` does; a directory or a reparse
## point at the reserved name fails the write.
##
## Not secret storage: the file passes through a directory that backups and
## state copies may read (HOST-CONFIG.md). Every message names the file, never
## its bytes.

{.push raises: [], gcsafe.}

import std/[strutils, sysrand]
import results

when defined(posix):
  import std/posix
  import ../durable
elif defined(windows):
  import std/[os, winlean]

export results

const
  ProtectedInputName* = ".lcn-protected-input"
    ## [G400] reserved in every state directory (HOST-CONFIG.md)
  MaxProtectedInputBytes* = 16_777_216 ## [G400] `lcn.app_protected_input.input`'s bound
  TempAttempts = 4 ## [IMPL] random temporary names tried before the write fails

func isProtectedInputName*(name: string): bool =
  ## The reserved name or one of its temporary names: what a state copy skips.
  name == ProtectedInputName or name.startsWith(ProtectedInputName & ".")

proc tempName(): Opt[string] =
  var b: array[16, byte]
  if not urandom(b):
    return Opt.none(string)
  var s = ProtectedInputName & "."
  for x in b:
    s.add(toHex(int(x), 2).toLowerAscii)
  Opt.some(s)

when defined(posix):
  var
    O_DIRECTORY {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
    O_NOFOLLOW {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
    AT_SYMLINK_NOFOLLOW {.importc: "AT_SYMLINK_NOFOLLOW", header: "<fcntl.h>".}: cint

  proc c_openat(
    fd: cint, path: cstring, flags: cint
  ): cint {.importc: "openat", header: "<fcntl.h>", varargs, sideEffect.}

  proc fstatat(
    fd: cint, path: cstring, st: var Stat, flags: cint
  ): cint {.importc, header: "<sys/stat.h>", sideEffect.}

  proc unlinkat(
    fd: cint, path: cstring, flags: cint
  ): cint {.importc, header: "<unistd.h>", sideEffect.}

  proc renameat(
    a: cint, an: cstring, b: cint, bn: cstring
  ): cint {.importc, header: "<stdio.h>", sideEffect.}

  proc fdopendir(fd: cint): ptr DIR {.importc, header: "<dirent.h>", sideEffect.}

  func describe(what: string, e: cint): string =
    what & " " & ProtectedInputName & ": " & $strerror(e)

  proc openDir(dir: string): Result[cint, string] =
    let fd = posix.open(cstring(dir), O_RDONLY or O_DIRECTORY or O_CLOEXEC)
    if fd < 0:
      return err("cannot open the state directory: " & $strerror(errno))
    ok(fd)

  proc clearAt(dfd: cint, name: string, dirFails: bool): Result[bool, string] =
    ## Removes `name` unless it is a directory, which fails when `dirFails` and
    ## is left otherwise; true when something was removed.
    var s: Stat
    if fstatat(dfd, cstring(name), s, AT_SYMLINK_NOFOLLOW) != 0:
      if errno == ENOENT:
        return ok(false)
      return err(describe("cannot inspect", errno))
    if S_ISDIR(s.st_mode):
      if not dirFails:
        return ok(false)
      return err("a directory is at the reserved name " & ProtectedInputName)
    if unlinkat(dfd, cstring(name), 0) != 0:
      if errno == ENOENT:
        return ok(false)
      return err(describe("cannot remove", errno))
    ok(true)

  proc tempsAt(dfd: cint): seq[string] =
    ## The temporary names a crash between create and rename left behind.
    let d = fdopendir(posix.dup(dfd))
    if d == nil:
      return
    while true:
      let x = readdir(d)
      if x == nil:
        break
      let n = $cast[cstring](x.d_name[0].addr)
      if n != ProtectedInputName and isProtectedInputName(n):
        result.add(n)
    discard closedir(d)

  proc removeAll(dfd: cint, dirFails: bool): Result[bool, string] =
    var removed = ?clearAt(dfd, ProtectedInputName, dirFails)
    for t in tempsAt(dfd):
      if ?clearAt(dfd, t, false):
        removed = true
    ok(removed)

  proc writeAll(fd: cint, data: openArray[byte]): cint =
    ## 0, or the errno of the failed write.
    var off = 0
    while off < data.len:
      let n = posix.write(fd, unsafeAddr data[off], data.len - off)
      if n < 0:
        if errno == EINTR:
          continue
        return errno
      off += n
    0

  proc writeAt(dfd: cint, data: openArray[byte]): Result[void, string] =
    discard ?removeAll(dfd, true)
    var name = ""
    var fd: cint = -1
    for _ in 0 ..< TempAttempts:
      name = tempName().valueOr:
        return err("no random bytes for the temporary name of " & ProtectedInputName)
      fd = c_openat(
        dfd,
        cstring(name),
        O_WRONLY or O_CREAT or O_EXCL or O_NOFOLLOW or O_CLOEXEC,
        Mode(0o600),
      )
      if fd >= 0 or errno != EEXIST:
        break
    if fd < 0:
      return err(describe("cannot create the temporary file of", errno))
    var e = writeAll(fd, data)
    if e == 0 and syncFd(fd).isErr:
      e = EIO
    if posix.close(fd) != 0 and e == 0:
      e = errno
    if e != 0:
      discard unlinkat(dfd, cstring(name), 0)
      return err(describe("cannot write", e))
    if renameat(dfd, cstring(name), dfd, cstring(ProtectedInputName)) != 0:
      let x = errno
      discard unlinkat(dfd, cstring(name), 0)
      return err(describe("cannot rename onto", x))
    syncFd(dfd).isOkOr:
      return err("cannot flush the state directory: " & error)
    ok()

  proc writeProtectedInput*(
      stateDir: string, data: openArray[byte]
  ): Result[void, string] =
    ## [G400] Replaces the reserved file with `data`, durably.
    if data.len == 0 or data.len > MaxProtectedInputBytes:
      return err("the protected input has 1 to " & $MaxProtectedInputBytes & " bytes")
    let dfd = ?openDir(stateDir)
    let r = writeAt(dfd, data)
    discard posix.close(dfd)
    r

  proc removeProtectedInput*(stateDir: string): Result[void, string] =
    ## [G400] Removes the reserved file and any temporary file of it, following
    ## no link. A missing directory or file is nothing to remove, and so is a
    ## directory at the reserved name: nothing there is read as the file.
    let dfd = posix.open(cstring(stateDir), O_RDONLY or O_DIRECTORY or O_CLOEXEC)
    if dfd < 0:
      if errno == ENOENT:
        return ok()
      return err("cannot open the state directory: " & $strerror(errno))
    let r = removeAll(dfd, false)
    var flushed: Result[void, string] = ok()
    if r.isOk and r.get:
      flushed = syncFd(dfd)
    discard posix.close(dfd)
    discard ?r
    flushed.isOkOr:
      return err("cannot flush the state directory: " & error)
    ok()

  proc readProtectedInput*(
      stateDir: string, maxBytes = MaxProtectedInputBytes
  ): Result[Opt[seq[byte]], string] =
    ## [G400] The reserved file's bytes, opened without following a link; none
    ## when there is no file. More than `maxBytes`, or anything but a regular
    ## file, is an error.
    let dfd = ?openDir(stateDir)
    let fd =
      c_openat(dfd, cstring(ProtectedInputName), O_RDONLY or O_NOFOLLOW or O_CLOEXEC)
    let oe = errno
    discard posix.close(dfd)
    if fd < 0:
      if oe == ENOENT:
        return ok(Opt.none(seq[byte]))
      return err(describe("cannot open", oe))
    var s: Stat
    if fstat(fd, s) != 0 or not S_ISREG(s.st_mode):
      discard posix.close(fd)
      return err(ProtectedInputName & " is not a regular file")
    if s.st_size > maxBytes:
      discard posix.close(fd)
      return err(ProtectedInputName & " is larger than " & $maxBytes & " bytes")
    var data = newSeq[byte](int(s.st_size))
    var off = 0
    while true:
      if off == data.len:
        # One byte more tells a file that grew since `fstat`.
        var extra: byte
        let n = posix.read(fd, addr extra, 1)
        if n < 0 and errno == EINTR:
          continue
        if n != 0:
          discard posix.close(fd)
          return err(ProtectedInputName & " changed while it was read")
        break
      let n = posix.read(fd, addr data[off], data.len - off)
      if n < 0:
        if errno == EINTR:
          continue
        let e = errno
        discard posix.close(fd)
        return err(describe("cannot read", e))
      if n == 0:
        discard posix.close(fd)
        return err(ProtectedInputName & " changed while it was read")
      off += n
    discard posix.close(fd)
    ok(Opt.some(data))

elif defined(windows):
  const
    InvalidAttributes = -1'i32
    MoveReplace = 0x1'i32 ## MOVEFILE_REPLACE_EXISTING
    MoveWriteThrough = 0x8'i32 ## MOVEFILE_WRITE_THROUGH

  func describe(what: string, e: int32): string =
    what & " " & ProtectedInputName & ": Windows error " & $e

  proc clearPath(path: string, dirFails: bool): Result[bool, string] =
    let w = newWideCString(path)
    let a = getFileAttributesW(w)
    if a == InvalidAttributes:
      return ok(false)
    if (a and FILE_ATTRIBUTE_DIRECTORY) != 0 or (a and FILE_ATTRIBUTE_REPARSE_POINT) != 0:
      if not dirFails:
        return ok(false)
      return err(
        "a directory or a reparse point is at the reserved name " & ProtectedInputName
      )
    if deleteFileW(w) == 0:
      return err(describe("cannot remove", int32(getLastError())))
    ok(true)

  proc removeAll(stateDir: string, dirFails: bool): Result[bool, string] =
    var removed = ?clearPath(stateDir / ProtectedInputName, dirFails)
    try:
      for kind, p in walkDir(stateDir, relative = true):
        if p != ProtectedInputName and isProtectedInputName(p):
          if ?clearPath(stateDir / p, false):
            removed = true
    except CatchableError:
      discard
    ok(removed)

  proc writeProtectedInput*(
      stateDir: string, data: openArray[byte]
  ): Result[void, string] =
    if data.len == 0 or data.len > MaxProtectedInputBytes:
      return err("the protected input has 1 to " & $MaxProtectedInputBytes & " bytes")
    discard ?removeAll(stateDir, true)
    var name = ""
    var h = INVALID_HANDLE_VALUE
    for _ in 0 ..< TempAttempts:
      name = tempName().valueOr:
        return err("no random bytes for the temporary name of " & ProtectedInputName)
      h = createFileW(
        newWideCString(stateDir / name),
        GENERIC_WRITE,
        0,
        nil,
        CREATE_NEW,
        FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OPEN_REPARSE_POINT,
        0,
      )
      if h != INVALID_HANDLE_VALUE:
        break
    if h == INVALID_HANDLE_VALUE:
      return err(describe("cannot create the temporary file of", int32(getLastError())))
    let wtmp = newWideCString(stateDir / name)
    var off = 0
    while off < data.len:
      var written: int32
      let chunk = int32(min(data.len - off, 1 shl 30))
      if writeFile(h, unsafeAddr data[off], chunk, addr written, nil) == 0:
        let e = int32(getLastError())
        discard closeHandle(h)
        discard deleteFileW(wtmp)
        return err(describe("cannot write", e))
      off += int(written)
    if flushFileBuffers(h) == 0:
      let e = int32(getLastError())
      discard closeHandle(h)
      discard deleteFileW(wtmp)
      return err(describe("cannot flush", e))
    discard closeHandle(h)
    if moveFileExW(
      wtmp,
      newWideCString(stateDir / ProtectedInputName),
      MoveReplace or MoveWriteThrough,
    ) == 0:
      let e = int32(getLastError())
      discard deleteFileW(wtmp)
      return err(describe("cannot rename onto", e))
    ok()

  proc removeProtectedInput*(stateDir: string): Result[void, string] =
    if not dirExists(stateDir):
      return ok()
    discard ?removeAll(stateDir, false)
    ok()

  proc readProtectedInput*(
      stateDir: string, maxBytes = MaxProtectedInputBytes
  ): Result[Opt[seq[byte]], string] =
    let path = stateDir / ProtectedInputName
    let a = getFileAttributesW(newWideCString(path))
    if a == InvalidAttributes:
      return ok(Opt.none(seq[byte]))
    if (a and FILE_ATTRIBUTE_DIRECTORY) != 0 or (a and FILE_ATTRIBUTE_REPARSE_POINT) != 0:
      return err(ProtectedInputName & " is not a regular file")
    try:
      let size = getFileSize(path)
      if size > maxBytes:
        return err(ProtectedInputName & " is larger than " & $maxBytes & " bytes")
      let text = readFile(path)
      if text.len > maxBytes:
        return err(ProtectedInputName & " is larger than " & $maxBytes & " bytes")
      var data = newSeq[byte](text.len)
      if text.len > 0:
        copyMem(addr data[0], unsafeAddr text[0], text.len)
      ok(Opt.some(data))
    except CatchableError as e:
      err("cannot read " & ProtectedInputName & ": " & e.msg)
