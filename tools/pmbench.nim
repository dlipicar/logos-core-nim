## The resolver limits' measurement (Tier 5 step 5-3b-2; planning's rulings of 2026-11-22, M1 to
## M6 and 7.1 to 7.2; DECISIONS G399, G443): one shape of `tests/support/pmshapes.nim`, resolved
## through the Package Manager's driver one step at a time.
##
## For each run it prints the outcome, the counters, the longest step (what the module thread is
## held for, M2) and the total of the steps, in wall time and in the process's CPU time (one
## thread: the CPU time is what the step costs on an idle core, whatever else the machine runs).
## CI never runs it and asserts no time (M6); `test_pm_driver` asserts the shapes' counts.
##
## Usage: pmbench <shape> <size> [k | v | L] [names depth candidates attempts]
##   pmbench wide 80000 20 4096 4095 4096 1000
##   pmbench dense 1024
##   pmbench chain 4096
##   pmbench hub 255 1
##   pmbench layered 256 32 256 32 256 1024

import std/[monotimes, os, strutils, times]
import ../tests/support/pmshapes

proc main() =
  let args = commandLineParams()
  if args.len < 2:
    quit(
      "usage: pmbench <wide|dense|chain|hub|layered> <size> [k | v | L] [names depth candidates attempts]",
      2,
    )
  let shapeName = args[0]
  let size = parseInt(args[1])
  var rest = args[2 .. ^1]
  var k = defaultParameter(shapeName)
  if shapeName in ["wide", "hub", "layered"] and rest.len > 0:
    k = parseInt(rest[0])
    rest = rest[1 .. ^1]
  let m = MaxResolverLimits
  var lim = [m.names, m.depth, m.candidates, m.attempts]
  for i in 0 ..< min(rest.len, 4):
    lim[i] = parseInt(rest[i])
  let limits = resolverLimits(lim[0], lim[1], lim[2], lim[3]).get
  let built = getMonoTime()
  let s = shapeOf(shapeName, size, k).valueOr:
    quit("unknown shape " & shapeName, 2)
  let buildMs = (getMonoTime() - built).inMilliseconds
  let r = driveShape(s, limits)
  let c = r.counters
  echo shapeName,
    " size=",
    size,
    (
      if shapeName == "wide": " k=" & $k
      elif shapeName == "hub": " v=" & $k
      elif shapeName == "layered": " L=" & $k
      else: ""
    ),
    " limits=",
    lim.join("/"),
    " build_ms=",
    buildMs
  echo "  outcome=",
    (
      if r.outcome.isOk: "ok (" & $r.outcome.get.packages.len & " packages)"
      else: $r.outcome.error
    )
  echo "  counters: names=",
    c.names,
    " depth=",
    c.depth,
    " candidates=",
    c.mostConsidered,
    " attempts=",
    c.attempts,
    " limit=",
    (if c.limit.len > 0: c.limit else: "none")
  echo "  steps=",
    r.steps,
    " longest_ms=",
    r.longest.inMicroseconds.float / 1000.0,
    " total_ms=",
    r.total.inMicroseconds.float / 1000.0,
    " longest_cpu_ms=",
    formatFloat(r.longestCpu * 1000.0, ffDecimal, 3),
    " total_cpu_ms=",
    formatFloat(r.totalCpu * 1000.0, ffDecimal, 3)

when isMainModule:
  main()
