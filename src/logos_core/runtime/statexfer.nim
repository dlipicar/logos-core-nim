## The file-system part of a state transfer to a replacement instance (Tier 4b
## step 4b-7; DECISIONS I96, G305-G307) [IMPL].
##
## A module instance's state assignment is realized as one directory,
## `<state_root>/<assignment>` (G143; `dirOf`, which the realizer uses too).
## A transfer fills the replacement's fresh assignment from the source's
## preserved storage: `move` renames the source's directory to the target's,
## one `rename(2)` on one file system, and then flushes `state_root`; it reads
## nothing. `copy` (part 7b, POSIX only) measures the source's tree first,
## then copies it into a staging directory in `state_root`, which the engine
## renames to the target's once the transfer is committed; the bytes pass
## through this process (owner's F1). An assignment's characters are
## `[A-Za-z0-9._-]` and never `.` or `..` (`realizer.pathSafe`), so a
## directory never leaves `state_root`, and a name starting with `+` is never
## an assignment's. A `copy` skips the protected realization input's reserved
## name and its temporary names at the top of the source (G400, `protinput`).
##
## Every proc is a plain system call checked by its return value, as in
## `durable.nim`, so none raises.

{.push raises: [], gcsafe.}

import std/[os, strutils]
import results
import ../durable
import logos_sdk/base/wipe
import logos_sdk/crypto/blake3
from ./protinput import isProtectedInputName

when defined(posix):
  import std/posix

  proc cRename(
    a, b: cstring
  ): cint {.importc: "rename", header: "<stdio.h>", sideEffect.}

elif defined(windows):
  import std/winlean

export results

type EntryKind* = enum
  ekMissing ## nothing by that name
  ekDir ## a directory
  ekLinkToDir ## a symbolic link to a directory (an operator's layout)
  ekOther ## anything else: a file, a dangling link, a device

func dirOf*(stateRoot, assignment: string): string =
  ## [G143] The one mapping from a state assignment to its directory.
  stateRoot / assignment

proc entryKind*(path: string): EntryKind =
  ## What `path` is, without following a link at its end, except to tell a
  ## link to a directory from any other link.
  when defined(posix):
    var s: Stat
    if lstat(cstring(path), s) != 0:
      return (if errno == ENOENT: ekMissing else: ekOther)
    if S_ISDIR(s.st_mode):
      return ekDir
    if S_ISLNK(s.st_mode):
      var t: Stat
      if stat(cstring(path), t) == 0 and S_ISDIR(t.st_mode):
        return ekLinkToDir
    ekOther
  else:
    try:
      if symlinkExists(path):
        return (if dirExists(path): ekLinkToDir else: ekOther)
      if dirExists(path):
        return ekDir
      if fileExists(path):
        return ekOther
      ekMissing
    except CatchableError:
      ekOther

proc moveDir*(stateRoot, fromName, toName: string): Result[void, string] =
  ## [IMPL-DECISION I96] Renames `<state_root>/<fromName>` to
  ## `<state_root>/<toName>`, then flushes `state_root`. The caller has seen
  ## that the target does not exist. A link at the source moves as the link.
  let a = dirOf(stateRoot, fromName)
  let b = dirOf(stateRoot, toName)
  when defined(posix):
    if cRename(cstring(a), cstring(b)) != 0:
      return err("cannot rename " & a & " to " & b & ": " & $strerror(errno))
    syncDir(stateRoot)
  elif defined(windows):
    # Without MOVEFILE_REPLACE_EXISTING: an existing target is an error.
    if moveFileExW(newWideCString(a), newWideCString(b), MOVEFILE_WRITE_THROUGH) == 0:
      return
        err("cannot rename " & a & " to " & b & ": Windows error " & $getLastError())
    ok()
  else:
    err("not supported on this platform")

# Copy (part 7b) --------------------------------------------------------------------

const
  StagingPrefix* = "+transfer-"
    ## [IMPL-DECISION I96] A `copy`'s staging directory in `state_root`. `+` is
    ## outside an assignment's alphabet, so no instance owns such a name.
  PurgePrefix* = "+purge-" ## part 7c's purge renames a directory to this first
  MaxTransferFiles* = 1_000_000 ## entries (files and directories) one `copy` may hold
  MaxTransferDepth* = 64 ## directory levels below the source's root
  FreeSpaceMargin* = 64'u64 * 1024 * 1024
    ## what `state_root`'s file system keeps free beyond a `copy`'s bytes
  CopyBlock = 64 * 1024 ## the one buffer a `copy` reads and writes through

type
  TreeSize* = object
    bytes*: uint64 ## regular files' bytes
    files*: uint64 ## regular files
    entries*: uint64 ## files and directories, the root excluded

  TreeFailureKind* = enum
    tfContent ## an entry other than a directory or a regular file
    tfBound ## `max_bytes`, `MaxTransferFiles`, `MaxTransferDepth` or the free space
    tfSystem ## a system call failed

  TreeFailure* = object
    kind*: TreeFailureKind
    message*: string

func stagingName*(assignment: string): string =
  ## [IMPL-DECISION I96] The staging name of the copy into `assignment`: fixed
  ## length, derived from the target so a restart finds it.
  let d = blake3(assignment.toOpenArrayByte(0, assignment.high))
  result = StagingPrefix
  for i in 0 ..< 16:
    result.add(toHex(int(d[i]), 2).toLowerAscii)

func isReserved*(name: string): bool =
  ## A name in `state_root` only a transfer or a purge makes.
  name.startsWith(StagingPrefix) or name.startsWith(PurgePrefix)

func failure(kind: TreeFailureKind, message: string): TreeFailure =
  TreeFailure(kind: kind, message: message)

when defined(posix):
  var
    O_DIRECTORY {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
    O_NOFOLLOW {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
    AT_SYMLINK_NOFOLLOW {.importc: "AT_SYMLINK_NOFOLLOW", header: "<fcntl.h>".}: cint
    AT_REMOVEDIR {.importc: "AT_REMOVEDIR", header: "<fcntl.h>".}: cint

  proc c_openat(
    fd: cint, path: cstring, flags: cint
  ): cint {.importc: "openat", header: "<fcntl.h>", varargs, sideEffect.}

  proc fstatat(
    fd: cint, path: cstring, st: var Stat, flags: cint
  ): cint {.importc, header: "<sys/stat.h>", sideEffect.}

  proc mkdirat(
    fd: cint, path: cstring, mode: Mode
  ): cint {.importc, header: "<sys/stat.h>", sideEffect.}

  proc fchmodat(
    fd: cint, path: cstring, mode: Mode, flags: cint
  ): cint {.importc, header: "<sys/stat.h>", sideEffect.}

  proc unlinkat(
    fd: cint, path: cstring, flags: cint
  ): cint {.importc, header: "<unistd.h>", sideEffect.}

  proc fdopendir(fd: cint): ptr DIR {.importc, header: "<dirent.h>", sideEffect.}

  func describe(what, path: string, e: cint): string =
    what & " " & path & ": " & $strerror(e)

  func join(rel, name: string): string =
    if rel.len == 0:
      name
    else:
      rel & "/" & name

  proc openDirAt(dfd: cint, name: string): cint =
    c_openat(dfd, cstring(name), O_RDONLY or O_DIRECTORY or O_NOFOLLOW or O_CLOEXEC)

  proc names(fd: cint): Result[seq[string], cint] =
    ## The entries of the directory open as `fd`, without `.` and `..`. Takes
    ## `fd`: it is closed on return.
    let d = fdopendir(fd)
    if d == nil:
      let e = errno
      discard posix.close(fd)
      return err(e)
    var r: seq[string] = @[]
    while true:
      errno = 0
      let x = readdir(d)
      if x == nil:
        let e = errno
        discard closedir(d)
        if e != 0:
          return err(e)
        return ok(r)
      let n = $cast[cstring](x.d_name[0].addr)
      if n != "." and n != "..":
        r.add(n)

  proc measureDir(
      dfd: cint, rel: string, depth: int, maxBytes: uint64, size: var TreeSize
  ): Result[void, TreeFailure] =
    let ns = names(posix.dup(dfd)).valueOr:
      return err(failure(tfSystem, describe("cannot read directory", rel, error)))
    for n in ns:
      if depth == 0 and isProtectedInputName(n):
        continue # [G400] never copied, so never counted
      let path = join(rel, n)
      var s: Stat
      if fstatat(dfd, cstring(n), s, AT_SYMLINK_NOFOLLOW) != 0:
        return err(failure(tfSystem, describe("cannot inspect", path, errno)))
      inc size.entries
      if size.entries > MaxTransferFiles:
        return err(
          failure(
            tfBound, "the source holds more than " & $MaxTransferFiles & " entries"
          )
        )
      if S_ISREG(s.st_mode):
        inc size.files
        size.bytes += uint64(s.st_size)
        if size.bytes > maxBytes:
          return err(
            failure(tfBound, "the source holds more than max_bytes (" & $maxBytes & ")")
          )
      elif S_ISDIR(s.st_mode):
        if depth + 1 > MaxTransferDepth:
          return err(
            failure(
              tfBound, "the source nests deeper than " & $MaxTransferDepth & " levels"
            )
          )
        let sub = openDirAt(dfd, n)
        if sub < 0:
          return err(failure(tfSystem, describe("cannot open directory", path, errno)))
        let r = measureDir(sub, path, depth + 1, maxBytes, size)
        discard posix.close(sub)
        ?r
      else:
        return err(
          failure(
            tfContent,
            "the source holds an entry other than a directory or a regular file: " & path,
          )
        )
    ok()

  proc measureTree*(root: string, maxBytes: uint64): Result[TreeSize, TreeFailure] =
    ## [IMPL-DECISION I96] Walks `root` (a link at the root is followed once;
    ## inside, none is) and counts its regular files and bytes, reading only
    ## metadata. Refuses any other entry and the bounds before anything is
    ## written.
    let fd = posix.open(cstring(root), O_RDONLY or O_DIRECTORY or O_CLOEXEC)
    if fd < 0:
      return err(failure(tfSystem, describe("cannot open directory", root, errno)))
    var size = TreeSize()
    let r = measureDir(fd, "", 0, maxBytes, size)
    discard posix.close(fd)
    ?r
    ok(size)

  proc freeBytes*(path: string): Result[uint64, string] =
    ## The bytes an unprivileged process may still write on `path`'s file
    ## system.
    var s: Statvfs
    if statvfs(cstring(path), s) != 0:
      return err(describe("cannot inspect the file system of", path, errno))
    ok(uint64(s.f_bavail) * uint64(s.f_frsize))

  proc flushOrFail(fd: cint, path: string): Result[void, TreeFailure] =
    syncFd(fd).isOkOr:
      return err(failure(tfSystem, "cannot flush " & path & ": " & error))
    ok()

  proc copyFile(
      sfd, dfd: cint,
      name, path: string,
      buf: var seq[byte],
      maxBytes: uint64,
      size: var TreeSize,
  ): Result[void, TreeFailure] =
    let i = c_openat(sfd, cstring(name), O_RDONLY or O_NOFOLLOW or O_CLOEXEC)
    if i < 0:
      return err(failure(tfSystem, describe("cannot open", path, errno)))
    var s: Stat
    if fstat(i, s) != 0 or not S_ISREG(s.st_mode):
      discard posix.close(i)
      return err(failure(tfContent, "the source changed while it was copied: " & path))
    let o = c_openat(
      dfd,
      cstring(name),
      O_WRONLY or O_CREAT or O_EXCL or O_NOFOLLOW or O_CLOEXEC,
      cint(s.st_mode and 0o777),
    )
    if o < 0:
      let e = errno
      discard posix.close(i)
      return err(failure(tfSystem, describe("cannot create the copy of", path, e)))
    var r: Result[void, TreeFailure] = ok()
    block copying:
      while true:
        let n = posix.read(i, buf[0].addr, buf.len)
        if n < 0:
          if errno == EINTR:
            continue
          r = err(failure(tfSystem, describe("cannot read", path, errno)))
          break copying
        if n == 0:
          break
        size.bytes += uint64(n)
        if size.bytes > maxBytes:
          r =
            err(failure(tfBound, "the source grew past max_bytes while it was copied"))
          break copying
        var done = 0
        while done < n:
          let w = posix.write(o, buf[done].addr, n - done)
          if w < 0:
            if errno == EINTR:
              continue
            r =
              err(failure(tfSystem, describe("cannot write the copy of", path, errno)))
            break copying
          done += w
      r = flushOrFail(o, path)
    discard posix.close(i)
    discard posix.close(o)
    ?r
    inc size.files
    ok()

  proc copyDir(
      sfd, dfd: cint,
      rel: string,
      buf: var seq[byte],
      maxBytes: uint64,
      size: var TreeSize,
  ): Result[void, TreeFailure] =
    let ns = names(posix.dup(sfd)).valueOr:
      return err(failure(tfSystem, describe("cannot read directory", rel, error)))
    for n in ns:
      if rel.len == 0 and isProtectedInputName(n):
        # [IMPL-DECISION G400] One instance's protected realization input is
        # never copied into another's directory.
        continue
      let path = join(rel, n)
      var s: Stat
      if fstatat(sfd, cstring(n), s, AT_SYMLINK_NOFOLLOW) != 0:
        return err(failure(tfSystem, describe("cannot inspect", path, errno)))
      inc size.entries
      if size.entries > MaxTransferFiles:
        return err(
          failure(
            tfBound, "the source holds more than " & $MaxTransferFiles & " entries"
          )
        )
      if S_ISREG(s.st_mode):
        ?copyFile(sfd, dfd, n, path, buf, maxBytes, size)
      elif S_ISDIR(s.st_mode):
        if mkdirat(dfd, cstring(n), Mode(0o700)) != 0:
          return
            err(failure(tfSystem, describe("cannot create the copy of", path, errno)))
        let a = openDirAt(sfd, n)
        if a < 0:
          return err(failure(tfSystem, describe("cannot open directory", path, errno)))
        let b = openDirAt(dfd, n)
        if b < 0:
          let e = errno
          discard posix.close(a)
          return err(failure(tfSystem, describe("cannot open the copy of", path, e)))
        var r = copyDir(a, b, path, buf, maxBytes, size)
        if r.isOk:
          r = flushOrFail(b, path)
        discard posix.close(a)
        discard posix.close(b)
        ?r
      else:
        return err(
          failure(
            tfContent,
            "the source holds an entry other than a directory or a regular file: " & path,
          )
        )
    ok()

  proc copyTree*(
      root, staging: string, maxBytes: uint64
  ): Result[TreeSize, TreeFailure] =
    ## [IMPL-DECISION I96; F1] Copies `root` into the new directory `staging`
    ## (mode 0700): directories and regular files only, each file with its
    ## permission bits, every file and directory flushed. The bytes pass
    ## through one `CopyBlock` buffer in this process, zeroed before it is
    ## freed, on every path. The caller removes `staging` on an error.
    let sfd = posix.open(cstring(root), O_RDONLY or O_DIRECTORY or O_CLOEXEC)
    if sfd < 0:
      return err(failure(tfSystem, describe("cannot open directory", root, errno)))
    if mkdir(cstring(staging), Mode(0o700)) != 0:
      let e = errno
      discard posix.close(sfd)
      return err(failure(tfSystem, describe("cannot create", staging, e)))
    let dfd =
      posix.open(cstring(staging), O_RDONLY or O_DIRECTORY or O_NOFOLLOW or O_CLOEXEC)
    if dfd < 0:
      let e = errno
      discard posix.close(sfd)
      return err(failure(tfSystem, describe("cannot open", staging, e)))
    var buf = newSeq[byte](CopyBlock)
    var size = TreeSize()
    var r = copyDir(sfd, dfd, "", buf, maxBytes, size)
    secureZero(buf[0].addr, buf.len)
    if r.isOk:
      r = flushOrFail(dfd, staging)
    discard posix.close(sfd)
    discard posix.close(dfd)
    ?r
    ok(size)

  proc removeAt(dfd: cint, name, path: string): Result[void, string] =
    ## Removes the entry `name` of the directory open as `dfd`, a directory's
    ## content first. A link is removed, never followed. A directory without
    ## the owner's access gets it first: what is removed keeps no mode.
    var s: Stat
    if fstatat(dfd, cstring(name), s, AT_SYMLINK_NOFOLLOW) != 0:
      if errno == ENOENT:
        return ok()
      return err(describe("cannot inspect", path, errno))
    if not S_ISDIR(s.st_mode):
      if unlinkat(dfd, cstring(name), 0) != 0 and errno != ENOENT:
        return err(describe("cannot remove", path, errno))
      return ok()
    if (s.st_mode and 0o700) != 0o700:
      discard fchmodat(dfd, cstring(name), Mode(0o700), 0)
    let sub = openDirAt(dfd, name)
    if sub < 0:
      return err(describe("cannot open directory", path, errno))
    let ns = names(posix.dup(sub))
    if ns.isErr:
      discard posix.close(sub)
      return err(describe("cannot read directory", path, ns.error))
    for n in ns.get:
      let r = removeAt(sub, n, path & "/" & n)
      if r.isErr:
        discard posix.close(sub)
        return r
    discard posix.close(sub)
    if unlinkat(dfd, cstring(name), AT_REMOVEDIR) != 0 and errno != ENOENT:
      return err(describe("cannot remove", path, errno))
    ok()

  proc removeTree*(parent, name: string): Result[void, string] =
    ## [IMPL-DECISION I96] Removes `<parent>/<name>` and everything under it,
    ## following no link, then flushes `parent`.
    let pfd = posix.open(cstring(parent), O_RDONLY or O_DIRECTORY or O_CLOEXEC)
    if pfd < 0:
      return err(describe("cannot open directory", parent, errno))
    let r = removeAt(pfd, name, parent / name)
    discard posix.close(pfd)
    ?r
    syncDir(parent)

else:
  proc measureTree*(root: string, maxBytes: uint64): Result[TreeSize, TreeFailure] =
    err(failure(tfSystem, "not supported on this platform"))

  proc freeBytes*(path: string): Result[uint64, string] =
    err("not supported on this platform")

  proc copyTree*(
      root, staging: string, maxBytes: uint64
  ): Result[TreeSize, TreeFailure] =
    err(failure(tfSystem, "not supported on this platform"))

  proc removeTree*(parent, name: string): Result[void, string] =
    err("not supported on this platform")
