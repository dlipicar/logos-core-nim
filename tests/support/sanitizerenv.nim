## The sanitizers' run-time settings as the suites pass them on to the processes they start
## (DECISIONS G442).
##
## - `SanitizerEnv`, the one list of their variables. Every environment a test gives a Module
##   Host names it (`tools/lint/sanitizerenv.py` checks that), so a host gets the check's
##   `log_path` and its reports land where `tools/sanitizer/reports.sh` finds them.
## - `deliverySettings`, what a case that checks a child's environment compares with, in any
##   build.
## - `reportsDir` and `takeCanary`: a sanitizer check's report directory, and the canary
##   checker. A canary child writes one stack trace (`__sanitizer_print_stack_trace`); once it is
##   reaped, its file moves to `<dir>/canary/` if it is nothing but the frames of one trace, and
##   stays where it is otherwise, so the check fails on it and prints it.

import std/[os, strutils]

const
  SanitizerEnv* =
    ["ASAN_OPTIONS", "LSAN_OPTIONS", "MSAN_OPTIONS", "TSAN_OPTIONS", "UBSAN_OPTIONS"]
    ## every sanitizer runtime's settings: a host's environment allow-list names all of them
  Sanitized* = defined(asan) or defined(tsan) or defined(msan)
    ## a sanitizer build (the switches in `config.nims`)
  OwnVariable =
    when defined(asan):
      "ASAN_OPTIONS"
    elif defined(tsan):
      "TSAN_OPTIONS"
    elif defined(msan):
      "MSAN_OPTIONS"
    else:
      ""
  CanaryDir* = "canary" ## under the report directory; `reports.sh` does not count it
  NeutralSetting = "verbosity=0" ## a setting every runtime takes, its default

proc sanitizerSettings*(): seq[string] =
  ## `NAME=value` for each of `SanitizerEnv` this process has: what a host started with a whole
  ## environment of the test's own (`hostowner.startHost`) gets beside it.
  for name in SanitizerEnv:
    if existsEnv(name):
      result.add(name & "=" & getEnv(name))

proc deliverySettings*(): seq[(string, string)] =
  ## Each of `SanitizerEnv` with a value: this process's own where it has one (a sanitizer check
  ## sets all five), else `verbosity=0`, set here first. A child started after this sees each
  ## with that value, whatever the build.
  for name in SanitizerEnv:
    if getEnv(name).len == 0:
      putEnv(name, NeutralSetting)
    result.add((name, getEnv(name)))

proc logDirOf*(settings: string): string =
  ## The directory of the last `log_path` in `settings` ("" without one, or for `stderr` and
  ## `stdout`).
  var path = ""
  for part in settings.split(':'):
    if part.startsWith("log_path="):
      path = part["log_path=".len .. ^1]
  if path.len == 0 or path in ["stderr", "stdout"]:
    return ""
  path.parentDir

proc reportsDir*(): string =
  ## Where this build's sanitizer sends reports, from this process's settings; "" outside a
  ## sanitizer build or when no `log_path` is set (a suite not run by `reports.sh`).
  when OwnVariable.len > 0:
    logDirOf(getEnv(OwnVariable))
  else:
    ""

proc reportFileOf*(dir: string, pid: int): string =
  ## The report file of process `pid` in `dir` (`report.<program>.<pid>`, or `report.<pid>`);
  ## "" if it has none.
  let suffix = "." & $pid
  for kind, path in walkDir(dir):
    if kind == pcFile:
      let name = path.extractFilename
      if name.startsWith("report.") and name.endsWith(suffix):
        return path
  ""

func isOneTrace*(text: string): bool =
  ## Nothing but the frames of one stack trace: lines `#0`, `#1`, ... in order, blank lines
  ## aside. A function name is not needed: under MemorySanitizer a host's frames may have none.
  var want = 0
  for line in text.splitLines:
    let s = line.strip(trailing = false)
    if s.len == 0:
      continue
    if s[0] != '#':
      return false
    var i = 1
    while i < s.len and s[i] in Digits:
      inc i
    if i == 1 or i >= s.len or s[i] notin {' ', '\t'}:
      return false
    let n =
      try:
        parseInt(s[1 ..< i])
      except ValueError:
        return false
    if n != want:
      return false
    inc want
  want > 0

type CanaryOutcome* = enum
  coMoved = "moved to the canary directory"
  coMissing = "no report file for the process"
  coNotATrace = "the file is more than one stack trace: left as a report"

proc takeCanary*(dir: string, pid: int): CanaryOutcome =
  ## Moves the report file of `pid`, a canary child that is already reaped, into
  ## `dir/canary/` if it holds one trace and nothing else.
  let path = reportFileOf(dir, pid)
  if path.len == 0:
    return coMissing
  let text =
    try:
      readFile(path)
    except IOError:
      return coMissing
  if not isOneTrace(text):
    return coNotATrace
  createDir(dir / CanaryDir)
  moveFile(path, dir / CanaryDir / path.extractFilename)
  coMoved
