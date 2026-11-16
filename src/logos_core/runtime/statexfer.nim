## The file-system part of a state transfer to a replacement instance (Tier 4b
## step 4b-7; DECISIONS I96, G305-G307) [IMPL].
##
## A module instance's state assignment is realized as one directory,
## `<state_root>/<assignment>` (G143; `dirOf`, which the realizer uses too).
## A transfer fills the replacement's fresh assignment from the source's
## preserved storage: `move` renames the source's directory to the target's,
## one `rename(2)` on one file system, and then flushes `state_root`; it reads
## nothing. An assignment's characters are `[A-Za-z0-9._-]` and never `.` or
## `..` (`realizer.pathSafe`), so a directory never leaves `state_root`.
##
## Every proc is a plain system call checked by its return value, as in
## `durable.nim`, so none raises.

{.push raises: [], gcsafe.}

import std/os
import results
import ../durable

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
