## A short private base directory for unix-stream endpoints (4b-2 plan §4.3):
## TMPDIR when the deepest path a suite makes fits `sun_path` and its
## filesystem holds sockets, else /tmp. Mode 0700, as `checkEndpointBase`
## requires. Used by the suites with local-transport routes or a logosd.
##
## [IMPL] How a base ends:
## - A suite's base, one per process, holds endpoint sockets only: the exit
##   removes it.
## - A case's own base (`perCase`) is ended by the suite's teardown, as its
##   last statement (`endCaseBases`): removed when the case passed, kept when
##   it failed, with `kept for diagnosis: <path>` on stderr.
## - A session that later cases share holds its base (`holdShortBase`, once
##   its boot has returned). Ending the session gives the base back to the
##   case that ends it (`unholdShortBase`), whose teardown decides.
## - A case's or a held base still listed at the exit is kept and printed the
##   same way: its case never reached its teardown (a `quit`, a `require`,
##   UNITTEST2_ABORT_ON_ERROR), or a filtered run left its session up.
##
## No base of another process is removed, at a start or anywhere: a run that
## crashed or was killed (a timeout, a signal) runs neither teardowns nor exit
## procedures, so its bases stay, `<prefix>-<pid>` like the kept ones, for a
## manual clean-up. The bases are made and ended on the main thread only.

import std/[exitprocs, os, sequtils, strutils]
import ../../src/logos_core/transport/io/sock
when defined(posix):
  import std/posix

type Bases = ref object
  ## All the state. The exit procedure reads it through its own captured
  ## reference only, and never changes it: every module's globals are destroyed
  ## before exit procedures run (orc), and a thread's defect can run them from
  ## that thread (refc).
  ofProcess: seq[string] ## the suites' bases: the exit removes them
  ofCase: seq[string] ## the current case's: `endCaseBases` ends them
  held: seq[string] ## the shared sessions': `unholdShortBase` gives one back

var bases: Bases ## the run's way to the object, never the exit procedure's

proc say(line: string) =
  try:
    stderr.writeLine(line)
  except IOError:
    discard

proc removeBase(dir: string) =
  ## A removal that fails is reported and fails nothing.
  try:
    removeDir(dir)
  except system.OSError as e:
    say("could not remove " & dir & ": " & e.msg)

proc keepBase(dir: string) =
  if dirExists(dir):
    say("kept for diagnosis: " & dir)

proc registry(): Bases =
  if bases.isNil:
    let b = Bases()
    bases = b
    addExitProc(
      proc() =
        for dir in b.ofProcess:
          if dirExists(dir):
            removeBase(dir)
        for dir in b.ofCase:
          keepBase(dir)
        for dir in b.held:
          keepBase(dir)
    )
  bases

proc holdsSockets(dir: string): bool =
  when unixStream:
    let fd = unixSocket()
    let path = dir / "probe.sock"
    result = sockBind(fd, cstring(path)) == 0
    discard fdClose(fd)
    discard unlink(cstring(path))
  else:
    false

proc makeShortBase*(
    prefix: string, deepest = "/12345678/logos_storage_module.sock", perCase = false
): string =
  ## `<root>/<prefix>-<pid>`, made fresh. `deepest` is the longest path the
  ## caller puts under it. `perCase`: one of the current case's bases, else
  ## the suite's.
  var root = getEnv("TMPDIR", "/tmp").strip(leading = false, chars = {'/'})
  let name = prefix & "-" & $getCurrentProcessId()
  if root.len == 0 or root.len + 1 + name.len + deepest.len + 1 > int(sunPathMax()):
    root = "/tmp"
  result = root / name
  removeDir(result)
  createDir(result)
  if not holdsSockets(result) and root != "/tmp":
    removeDir(result)
    result = "/tmp" / name
    removeDir(result)
    createDir(result)
  when defined(posix):
    doAssert chmod(cstring(result), 0o700) == 0
  let r = registry()
  if perCase:
    if result notin r.ofCase:
      r.ofCase.add(result)
  elif result notin r.ofProcess:
    r.ofProcess.add(result)

proc holdShortBase*(base: string) =
  ## A case's base becomes the session's that later cases share.
  let r = registry()
  if base in r.ofCase:
    r.ofCase.keepItIf(it != base)
    r.held.add(base)

proc unholdShortBase*(base: string) =
  ## A held base goes back to the current case, whose teardown ends it; any
  ## other base is left as it is.
  let r = registry()
  if base in r.held:
    r.held.keepItIf(it != base)
    r.ofCase.add(base)

proc endCaseBases*(failed: bool) =
  ## The teardown's last statement, once the case's daemons and children have
  ## stopped: removes the case's bases, or keeps them when it `failed`.
  let r = registry()
  let mine = r.ofCase
  r.ofCase = @[]
  for base in mine:
    if failed:
      keepBase(base)
    else:
      removeBase(base)
