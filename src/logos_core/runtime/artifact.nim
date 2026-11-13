## LOADER §3, §12; RUNTIME §3.6: a dynamic-library artifact verified and mapped
## without a path-replacement gap.
##
## [IMPL] The Loader copies the accepted library into a private directory it
## created (mode 0700, `mkdtemp`), makes the copy read-only, hashes the copy's
## bytes as they are on disk, and maps that copy. Only the Runtime's own user
## can write there, so the bytes mapped are the bytes verified (LOADER §3
## l.205-207 names "a protected immutable artifact location"). The source path
## is read once and never mapped. Error messages name no host path (§10).
##
## Libraries are mapped with `RTLD_NOW | RTLD_LOCAL` (RUNTIME §2.1) and never
## unloaded: `dlclose` does not undo code that already ran (§3.6), a binding
## must outlive every context made from it (§2.2), and unloading a library
## whose runtime started threads is unsafe (TF-03).

{.push raises: [].}

import std/[dynlib, os]
when defined(posix):
  import std/posix
  # macOS declares `mkdtemp` in <unistd.h>, glibc and musl in <stdlib.h>.
  when defined(macosx):
    proc cMkdtemp(tmpl: cstring): cstring {.importc: "mkdtemp", header: "<unistd.h>".}
  else:
    proc cMkdtemp(tmpl: cstring): cstring {.importc: "mkdtemp", header: "<stdlib.h>".}
import results
import ../crypto/blake3
import ../pins

export results

type
  ArtifactRecord* = object ## [SPEC LOADER §3] `logos.module_loader.artifact`
    id*: string
    localPath*: string
    hash*: array[32, byte]
    hashSuite*: string

  StageFailure* = enum
    sfUnavailable ## `artifact-unavailable`: the source cannot be read
    sfIntegrity ## `artifact-integrity-failed`
    sfControls
      ## [SPEC LOADER l.628; C-08, I88] `realization-failed`: the private copy,
      ## the control that maps the verified bytes without a path-replacement
      ## gap (l.214), cannot be created, written, protected or hashed

  StageError* = object
    kind*: StageFailure
    msg*: string

const LibraryExtension* =
  when defined(windows):
    ".dll"
  elif defined(macosx):
    ".dylib"
  else:
    ".so"

proc privateDir*(base: string): Result[string, string] =
  ## A new directory under `base` that only this user can enter (0700).
  try:
    createDir(base)
  except OSError, IOError:
    return err("cannot create the artifact base directory")
  when defined(posix):
    var tmpl = base / "lcn-artifacts-XXXXXX"
    if cMkdtemp(cstring(tmpl)) == nil:
      return err("mkdtemp failed: " & $strerror(errno))
    ok(tmpl)
  else:
    try:
      let dir = base / ("lcn-artifacts-" & $getCurrentProcessId())
      createDir(dir)
      setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
      ok(dir)
    except OSError, IOError:
      err("cannot create the artifact directory")

proc fail(kind: StageFailure, msg: string): Result[string, StageError] =
  err(StageError(kind: kind, msg: msg))

proc digestOf(path: string): Result[Blake3Digest, string] =
  var f: File
  if not open(f, path, fmRead):
    return err("cannot reopen the staged copy")
  defer:
    close(f)
  var h: Blake3Hasher
  h.init()
  var buf = newSeq[byte](1 shl 16)
  try:
    while true:
      let n = f.readBuffer(addr buf[0], buf.len)
      if n <= 0:
        break
      h.update(buf.toOpenArray(0, n - 1))
  except IOError:
    return err("cannot read the staged copy")
  ok(h.finish())

proc stage*(a: ArtifactRecord, dir, name: string): Result[string, StageError] =
  ## [SPEC LOADER §3 l.203-209] Copies `a.localPath` to `dir/name` (read-only)
  ## and checks the copy against `a.hash` under `a.hashSuite`, which the caller
  ## has already checked is the pinned BLAKE3-256 suite. Returns the copy's
  ## path; a mismatching copy is removed. A source that cannot be read is
  ## `sfUnavailable` (LOADER l.622); a copy that cannot be made, written,
  ## protected or hashed is `sfControls` (l.628).
  doAssert a.hashSuite == HashSuiteId
  let dest = dir / (name & LibraryExtension)
  var src, dst: File
  if not open(src, a.localPath, fmRead):
    return fail(sfUnavailable, "the artifact cannot be read")
  try:
    if fileExists(dest) or not open(dst, dest, fmWrite):
      close(src)
      return fail(sfControls, "cannot create the staged copy")
  except OSError, IOError:
    close(src)
    return fail(sfControls, "cannot create the staged copy")
  var failed = Opt.none(StageFailure)
  var buf = newSeq[byte](1 shl 16)
  while failed.isNone:
    var n = 0
    try:
      n = src.readBuffer(addr buf[0], buf.len)
    except IOError:
      failed = Opt.some(sfUnavailable)
      break
    if n <= 0:
      break
    try:
      if dst.writeBuffer(addr buf[0], n) != n:
        failed = Opt.some(sfControls)
    except IOError:
      failed = Opt.some(sfControls)
  close(src)
  try:
    flushFile(dst)
  except IOError:
    if failed.isNone:
      failed = Opt.some(sfControls)
  close(dst)
  if failed.isSome:
    discard tryRemoveFile(dest)
    return
      if failed.get == sfUnavailable:
        fail(sfUnavailable, "the artifact cannot be read")
      else:
        fail(sfControls, "cannot write the staged copy")
  try:
    setFilePermissions(dest, {fpUserRead, fpUserExec})
  except OSError:
    discard tryRemoveFile(dest)
    return fail(sfControls, "cannot protect the staged copy")
  let d = digestOf(dest).valueOr:
    discard tryRemoveFile(dest)
    return fail(sfControls, error)
  if d != a.hash:
    discard tryRemoveFile(dest)
    return fail(sfIntegrity, "the artifact bytes do not match the accepted digest")
  ok(dest)

proc mapLibrary*(path: string): LibHandle =
  ## [SPEC RUNTIME §2.1] Maps the staged copy; nil when the platform loader
  ## refuses it. Runs the library's load-time code.
  when defined(posix):
    cast[LibHandle](dlopen(cstring(path), RTLD_NOW or RTLD_LOCAL))
  else:
    loadLib(path)
