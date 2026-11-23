## Spool files (Tier 5 step 5-5-3; DECISIONS G446's spool half, G447;
## docs/PACKAGE-MANAGER.md §9; PACKAGE MANAGER §7.1, §8 l.1094). The worker
## (`jobs.nim`) writes each retrieved archive here, one 1 MiB `read_object`
## answer at a time, and reads it back for the inspection pass; no archive is
## held in memory.
##
## - **Where:** `<state_dir>/install/spool/`, a directory of the installation
##   root that the store's start empties (`store.nim`, PKG-0611). A file is
##   `<request>-<n>.lgx`: the root operation and the archive's place in it.
##   Created with `O_EXCL | O_NOFOLLOW`, mode 0600, in a 0700 directory.
## - **The digest** is BLAKE3-256 of the bytes as they are appended, so the
##   verification cache is keyed without reading the file again.
## - **Not synced:** a spool file lives for one operation and the next start
##   deletes what a crash left.
## - **A write that fails** (`ENOSPC` included) makes the archive unavailable,
##   as a failed read does (PM l.1094); the first failure is kept and every later
##   append is dropped. It is not exhaustion (PM l.1279-1280).
## - **The inspections' share** `[IMPL]`: the archives spooled for inspection at
##   once are at most `SpoolShareArchives` × `archive_bytes` in all. A retrieval
##   whose archive would pass it waits, first in, first out, for one to be
##   deleted; the first one always fits (§4.3).

{.push raises: [].}

import std/[os, strutils]
import results
import logos_sdk/crypto/blake3

when defined(posix):
  import std/posix

  var O_NOFOLLOW {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
    # not in std/posix; its value differs by architecture (as in extract.nim)

export results, blake3

const
  SpoolShareArchives* = 4
    ## [IMPL; G446] the inspections' share of the spool, in archives of `archive_bytes`
  SpoolExtension* = ".lgx"

type SpoolWriter* = object ## One spool file being appended to.
  path*: string
  size*: int64
  failure*: string ## the first failure; empty while every write succeeded
  hasher: ref Blake3Hasher
    ## behind a reference: refc copies a `SpoolWriter` (into and out of the worker's table)
    ## through its type information, which holds none of the `importc` hasher's bytes, so the
    ## copy's digest ignored what was appended (upstream ISSUES 195, the second shape)
  open: bool
  when defined(posix):
    fd: cint
  else:
    file: File

func spoolName*(request, n: uint64): string =
  ## [G446] The file name of the `n`th archive of root operation `request`.
  $request & "-" & $n & SpoolExtension

func isSpoolName*(name: string): bool =
  ## Whether `name` is one `spoolName` gives: no separator, no `..`.
  if not name.endsWith(SpoolExtension) or name.len > 48:
    return false
  let stem = name[0 ..< name.len - SpoolExtension.len]
  let dash = stem.find('-')
  if dash <= 0 or dash == stem.high:
    return false
  for i, c in stem:
    if i != dash and c notin Digits:
      return false
  true

when defined(posix):
  proc fail(w: var SpoolWriter, what: string, code: cint) =
    if w.failure.len == 0:
      w.failure = what & " " & w.path & ": " & $strerror(code)

proc createSpool*(dir, name: string): SpoolWriter =
  ## [G446] A new spool file `dir/name`; a failure is kept in `failure`.
  doAssert name.isSpoolName, "a spool name"
  result = SpoolWriter(path: dir / name, hasher: new Blake3Hasher)
  result.hasher[].init()
  when defined(posix):
    let fd = posix.open(
      cstring(result.path),
      O_WRONLY or O_CREAT or O_EXCL or O_NOFOLLOW or O_CLOEXEC,
      0o600,
    )
    if fd < 0:
      result.fail("cannot create the spool file", errno)
      return
    result.fd = fd
    result.open = true
  else:
    if not open(result.file, result.path, fmWrite):
      result.failure = "cannot create the spool file " & result.path
      return
    result.open = true

proc append*(w: var SpoolWriter, chunk: openArray[byte]) =
  ## Appends `chunk` and hashes it; after a failure, nothing.
  if w.failure.len > 0 or not w.open:
    return
  when defined(posix):
    var at = 0
    while at < chunk.len:
      let n = posix.write(w.fd, unsafeAddr chunk[at], chunk.len - at)
      if n < 0:
        if errno == EINTR:
          continue
        w.fail("cannot write the spool file", errno)
        return
      at += n
  else:
    try:
      if chunk.len > 0 and w.file.writeBytes(chunk, 0, chunk.len) != chunk.len:
        w.failure = "cannot write the spool file " & w.path
        return
    except IOError as e:
      w.failure = "cannot write the spool file " & w.path & ": " & e.msg
      return
  w.hasher[].update(chunk)
  w.size += int64(chunk.len)

proc closeFile(w: var SpoolWriter) =
  if not w.open:
    return
  w.open = false
  when defined(posix):
    if posix.close(w.fd) != 0:
      w.fail("cannot close the spool file", errno)
  else:
    close(w.file)

proc finish*(w: var SpoolWriter): Blake3Digest =
  ## Closes the file and gives the digest of every byte appended. The caller reads
  ## `failure` first: with one, the digest names no complete archive.
  w.closeFile()
  result = w.hasher[].finish()
  w.hasher[].wipe()

proc removeSpool*(path: string): Result[void, string] =
  ## Deletes a spool file; one already gone is not an error.
  try:
    removeFile(path)
    ok()
  except OSError as e:
    err("cannot delete the spool file " & path & ": " & e.msg)

proc abandon*(w: var SpoolWriter): Result[void, string] =
  ## Closes and deletes an unfinished spool file.
  w.closeFile()
  if w.hasher != nil:
    w.hasher[].wipe()
  removeSpool(w.path)

{.pop.}
