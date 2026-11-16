## logosd's log (Tier 4b step 4b-6; DAEMON.md §12): stderr, one line per
## event, `logosd[<pid>]: <level>: <text>`, written whole under a lock from any
## thread. There is no log file; a service manager collects stderr.
##
## The rule for what a line may hold (SEC l.527; IF l.395, SEC l.305-306,
## l.403, G278): no payload, no value root, no ticket, key or record content,
## and no provider failure text of a marked method. Method names, schema roots,
## codes and instance ids are metadata and stay. Callers keep to it. Here each
## line is made one line (`logtext.oneLine`): no text in it can end it and
## start another that reads as logosd's (I95, amended 2026-11-16).

{.push raises: [], gcsafe.}

import std/[atomics, locks, os]
import results
from ../base/logtext import oneLine

type
  LogLevel* = enum
    llError = "error"
    llWarn = "warn"
    llInfo = "info"

  LogSink* = proc(line: string) {.nimcall, gcsafe, raises: [].}
    ## Receives each formatted line, without its newline.

var
  threshold: Atomic[int]
  sinkLock: Lock
  sink: LogSink

initLock(sinkLock)
threshold.store(ord(llInfo))

when defined(posix):
  proc cWrite(
    fd: cint, p: pointer, n: csize_t
  ): int {.importc: "write", header: "<unistd.h>".}

else:
  proc cWrite(
    fd: cint, p: pointer, n: csize_t
  ): int {.importc: "_write", header: "<io.h>".}

proc stderrSink(line: string) {.nimcall, gcsafe, raises: [].} =
  let s = line & "\n"
  var off = 0
  while off < s.len:
    let n = cWrite(2, unsafeAddr s[off], csize_t(s.len - off))
    if n <= 0:
      return
    off += n

func parseLevel*(s: string): Result[LogLevel, string] {.raises: [].} =
  case s
  of "error":
    ok(llError)
  of "warn":
    ok(llWarn)
  of "info":
    ok(llInfo)
  else:
    err("--log-level must be error, warn or info")

proc setLogLevel*(l: LogLevel) =
  threshold.store(ord(l))

proc setLogSink*(s: LogSink) =
  ## Where lines go; nil restores stderr. Tests capture lines with it.
  withLock sinkLock:
    {.cast(gcsafe).}:
      sink = s

proc logLine*(level: LogLevel, text: string) =
  if ord(level) > threshold.load:
    return
  let line = "logosd[" & $getCurrentProcessId() & "]: " & $level & ": " & oneLine(text)
  withLock sinkLock:
    {.cast(gcsafe).}:
      if sink.isNil:
        stderrSink(line)
      else:
        sink(line)

template logError*(text: string) =
  logLine(llError, text)

template logWarn*(text: string) =
  logLine(llWarn, text)

template logInfo*(text: string) =
  logLine(llInfo, text)

{.pop.}
