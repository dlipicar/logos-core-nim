## Descriptor-relative extraction, and reads below a record directory (Tier 5 step 5-5-2;
## DECISIONS G446; docs/PACKAGE-MANAGER.md §9; PACKAGE MANAGER §7.1 l.926-933, §10 l.1176-1195).
## POSIX only.
##
## - **Writing** (PKG-0204, PKG-0274): every name is created relative to a directory descriptor
##   that this extraction opened, never through a path. A directory is made with `mkdirat` (0700)
##   and opened `O_DIRECTORY | O_NOFOLLOW`; a file is created `O_CREAT | O_EXCL | O_NOFOLLOW`,
##   0400, and written in 1 MiB chunks. So no component that is a link is followed, nothing outside
##   the record's directory is named, and a name that already exists, a planted link included,
##   fails (`efExists`): the destination stays inside the installation root by construction. The
##   reader has already refused `..`, `.`, empty segments and non-NFC paths (G40).
## - **Modes** (G444): directories 0700, files 0400, nothing executable, nothing rewritten
##   (PKG-0499, PKG-0500). Directory descriptors are opened per file and closed, so a variant of
##   65,536 files never holds more than its depth open.
## - **Syncs:** with `sync`, each file is `fsync`ed before it is closed, and `finish` syncs each
##   directory it created, deepest first, then the root it was given (DECISIONS G445). The plain
##   `fsyncOnly` and Linux's `syncFs` are here rather than in `durable.nim`, the Runtime store's
##   byte level, which this step leaves unchanged.
## - **Reading below a record** (`hashBelow`, `readBelow`): each component is opened relative to
##   its parent with `O_NOFOLLOW`, and the last must be a regular file. A link anywhere below the
##   record's `a/` fails, as an absent or unreadable file does (`efRead`).
## - **The stop flag** is checked between chunks and between files (5-5's W2).

{.push raises: [].}

import std/[algorithm, atomics, sets, strutils]
import results
import logos_sdk/crypto/blake3

when defined(posix):
  import std/posix

export results, blake3

const ChunkBytes* = 1 shl 20 ## [IMPL] one write, one hash update

type
  StopFlag* = ptr Atomic[bool] ## nil: never stopped

  ExtractFault* = enum
    efExists = "a name already exists, or is a link"
    efWrite = "a write to the state filesystem failed"
    efRead = "a file is absent, not a regular file, or unreadable"
    efStopped = "stopped"

  ExtractError* = object
    fault*: ExtractFault
    detail*: string ## the path and the system's error, for the operator's log only

  DirTree* = object
    ## The directories one extraction created below `root`, by relative path.
    root: cint
    made: HashSet[string]
    order: seq[string] ## creation order

func stopped*(f: StopFlag): bool =
  not f.isNil and f[].load(moRelaxed)

func fail(f: ExtractFault, detail: string): ExtractError =
  ExtractError(fault: f, detail: detail)

when defined(posix):
  var
    O_DIRECTORY {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
    O_NOFOLLOW {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

  proc c_openat(
    fd: cint, path: cstring, flags: cint
  ): cint {.importc: "openat", header: "<fcntl.h>", varargs.}

  proc c_mkdirat(
    fd: cint, path: cstring, mode: Mode
  ): cint {.importc: "mkdirat", header: "<sys/stat.h>".}

  func describe(what, path: string, e: cint): string =
    what & " " & path & ": " & $strerror(e)

  proc closeFd*(fd: cint) =
    if fd >= 0:
      discard posix.close(fd)

  proc openDir*(path: string): Result[cint, string] =
    ## The directory at `path`, opened `O_DIRECTORY | O_NOFOLLOW`.
    let fd =
      posix.open(cstring(path), O_RDONLY or O_DIRECTORY or O_NOFOLLOW or O_CLOEXEC)
    if fd < 0:
      return err(describe("cannot open directory", path, errno))
    ok(fd)

  proc openDirAt(parent: cint, name, shown: string): Result[cint, ExtractError] =
    let fd = c_openat(
      parent, cstring(name), O_RDONLY or O_DIRECTORY or O_NOFOLLOW or O_CLOEXEC
    )
    if fd < 0:
      let e = errno
      if e in [ELOOP, ENOTDIR, ENOENT]:
        return
          err(fail(efExists, describe("not a directory of this extraction", shown, e)))
      return err(fail(efWrite, describe("cannot open directory", shown, e)))
    ok(fd)

  proc makeDirAt*(parent: cint, name: string, shown = ""): Result[cint, ExtractError] =
    ## Creates `name` (0700) in the directory `parent` and opens it; an existing name fails
    ## `efExists`.
    let label = if shown.len > 0: shown else: name
    if c_mkdirat(parent, cstring(name), Mode(0o700)) != 0:
      let e = errno
      if e == EEXIST:
        return err(fail(efExists, describe("already exists:", label, e)))
      return err(fail(efWrite, describe("cannot create directory", label, e)))
    openDirAt(parent, name, label)

  proc fsyncOnly*(fd: cint): Result[void, string] =
    ## [IMPL] (DECISIONS G445) A plain `fsync` of `fd`. On Linux it flushes the device too; on
    ## Darwin it moves the data to the drive and stops at the drive's cache, for a caller that
    ## issues one `F_FULLFSYNC` after a batch: the store's commit, through `writeAtomic`.
    ## (`durable.syncFd` is `F_FULLFSYNC` on Darwin.)
    while fsync(fd) != 0:
      if errno != EINTR:
        return err($strerror(errno))
    ok()

  when defined(linux):
    proc c_syncfs(fd: cint): cint {.importc: "syncfs".}

    proc syncFs*(fd: cint): Result[void, string] =
      ## [IMPL] (DECISIONS G445) `syncfs(2)`: writes the dirty data and metadata of the whole
      ## filesystem holding `fd`, and waits for it. From Linux 5.8 it also fails when a write
      ## anywhere on that filesystem failed since `fd` last checked, so the store keeps one
      ## descriptor, opened before its writes, for this call.
      if c_syncfs(fd) != 0:
        return err($strerror(errno))
      ok()

  proc syncAt(fd: cint, shown: string): Result[void, ExtractError] =
    fsyncOnly(fd).isOkOr:
      return err(fail(efWrite, "cannot sync " & shown & ": " & error))
    ok()

  func initTree*(root: cint): DirTree =
    ## A tree below the open directory `root`, which the caller keeps and closes.
    DirTree(root: root)

  proc parentOf(t: var DirTree, segs: openArray[string]): Result[cint, ExtractError] =
    ## The directory holding the last of `segs`, made when this tree has not made it yet. The
    ## result is a new descriptor, or `t.root`.
    var fd = t.root
    for i in 0 ..< segs.len - 1:
      let prefix = segs[0 .. i].join("/")
      let next =
        if prefix in t.made:
          openDirAt(fd, segs[i], prefix)
        else:
          let made = makeDirAt(fd, segs[i], prefix)
          if made.isOk:
            t.made.incl(prefix)
            t.order.add(prefix)
          made
      if fd != t.root:
        closeFd(fd)
      fd = ?next
    ok(fd)

  proc writeAll(
      fd: cint, data: openArray[byte], path: string, stop: StopFlag
  ): Result[void, ExtractError] =
    var off = 0
    while off < data.len:
      if stop.stopped:
        return err(fail(efStopped, "stopped while writing " & path))
      let want = min(ChunkBytes, data.len - off)
      let n = posix.write(fd, unsafeAddr data[off], want)
      if n < 0:
        if errno == EINTR:
          continue
        return err(fail(efWrite, describe("cannot write", path, errno)))
      off += n
    ok()

  proc extractFile*(
      t: var DirTree,
      path: string,
      data: openArray[byte],
      sync: bool,
      stop: StopFlag = nil,
  ): Result[void, ExtractError] =
    ## [SPEC PM §7.1 l.926-933] Writes `data` as the new file `path` (a checked relative path)
    ## below the tree's root, mode 0400, its directories made as needed.
    if stop.stopped:
      return err(fail(efStopped, "stopped before " & path))
    let segs = path.split('/')
    let dir = ?t.parentOf(segs)
    defer:
      if dir != t.root:
        closeFd(dir)
    let fd = c_openat(
      dir,
      cstring(segs[^1]),
      O_WRONLY or O_CREAT or O_EXCL or O_NOFOLLOW or O_CLOEXEC,
      cint(0o400),
    )
    if fd < 0:
      let e = errno
      if e in [EEXIST, ELOOP]:
        return err(fail(efExists, describe("already exists:", path, e)))
      return err(fail(efWrite, describe("cannot create", path, e)))
    let written = writeAll(fd, data, path, stop)
    let synced =
      if written.isOk and sync:
        syncAt(fd, path)
      else:
        written
    if posix.close(fd) != 0 and synced.isOk:
      return err(fail(efWrite, describe("cannot close", path, errno)))
    synced

  proc finish*(t: var DirTree, sync: bool): Result[void, ExtractError] =
    ## With `sync`: each directory the tree made, deepest first, then its root.
    if not sync:
      return ok()
    var dirs = t.order
    dirs.sort(
      proc(a, b: string): int =
        cmp(b.count('/'), a.count('/'))
    )
    for d in dirs:
      var fd = t.root
      let segs = d.split('/')
      for i, s in segs:
        let next = openDirAt(fd, s, segs[0 .. i].join("/"))
        if fd != t.root:
          closeFd(fd)
        fd = ?next
      let r = syncAt(fd, d)
      closeFd(fd)
      ?r
    syncAt(t.root, "the record directory")

  proc openBelow(root: cint, path: string): Result[cint, ExtractError] =
    ## The regular file `path` below `root`, every component opened with `O_NOFOLLOW`.
    let segs = path.split('/')
    var fd = root
    for i in 0 ..< segs.len - 1:
      let next = c_openat(
        fd, cstring(segs[i]), O_RDONLY or O_DIRECTORY or O_NOFOLLOW or O_CLOEXEC
      )
      let e = errno
      if fd != root:
        closeFd(fd)
      if next < 0:
        return err(fail(efRead, describe("cannot open directory of", path, e)))
      fd = next
    let f = c_openat(fd, cstring(segs[^1]), O_RDONLY or O_NOFOLLOW or O_CLOEXEC)
    let e = errno
    if fd != root:
      closeFd(fd)
    if f < 0:
      return err(fail(efRead, describe("cannot open", path, e)))
    var st: Stat
    if fstat(f, st) != 0 or not S_ISREG(st.st_mode):
      closeFd(f)
      return err(fail(efRead, path & " is not a regular file"))
    ok(f)

  proc hashBelow*(
      root: cint, path: string, stop: StopFlag = nil
  ): Result[Blake3Digest, ExtractError] =
    ## The BLAKE3-256 of the regular file `path` below `root`.
    let fd = ?openBelow(root, path)
    defer:
      closeFd(fd)
    var h: Blake3Hasher
    h.init()
    var buf = newSeq[byte](ChunkBytes)
    while true:
      if stop.stopped:
        return err(fail(efStopped, "stopped while hashing " & path))
      let n = posix.read(fd, addr buf[0], buf.len)
      if n < 0:
        if errno == EINTR:
          continue
        return err(fail(efRead, describe("cannot read", path, errno)))
      if n == 0:
        break
      h.update(buf.toOpenArray(0, n - 1))
    ok(h.finish())

  proc readBelow*(
      root: cint, path: string, maxBytes: int
  ): Result[seq[byte], ExtractError] =
    ## The bytes of the regular file `path` below `root`, at most `maxBytes`.
    let fd = ?openBelow(root, path)
    defer:
      closeFd(fd)
    var data: seq[byte]
    var buf = newSeq[byte](min(ChunkBytes, maxBytes + 1))
    while true:
      let n = posix.read(fd, addr buf[0], buf.len)
      if n < 0:
        if errno == EINTR:
          continue
        return err(fail(efRead, describe("cannot read", path, errno)))
      if n == 0:
        break
      if data.len + n > maxBytes:
        return err(fail(efRead, path & " is larger than " & $maxBytes & " bytes"))
      data.add(buf.toOpenArray(0, n - 1))
    ok(data)

{.pop.}
