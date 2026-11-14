## The reference orchestration module's test hooks (DECISIONS I94; the
## test-hook rule, D27 as amended 2026-11-13, `base/testhooks.nim`).
##
## This file holds code only under `-d:lcnTestHooks`, which only test builds
## set; the module's other sources reach it only inside `when
## defined(lcnTestHooks)`. Every hook is inert until a test selects it by a
## call:
##
## - `dropNextAnswer`: the next lifecycle completion is discarded and the
##   worker halts, leaving a charged call's `pending` written, as a crash
##   would leave it.
## - `failWrites`: every write of the state file fails.
## - `suppressHints`: event handlers drop what they receive.
## - `pauseBeforeRequest`: the worker waits between a read and the guarded
##   request it decided on, while the gate is set.
##
## Calls are counted per method and target instance, so a test shows which
## calls were made, when, and that none targets the Module Loader.

{.push raises: [], gcsafe.}

import ../base/testhooks

testHooksMarker("orchestration")

when defined(lcnTestHooks):
  import std/[atomics, locks, monotimes]

  type OrchestratorFaults* = object
    dropNextAnswer*: bool
    failWrites*: bool
    suppressHints*: bool
    pauseBeforeRequest*: bool

  const
    MaxRecorded = 4096
    NameBytes = 32
    InstanceBytes = 128

  type Recorded = object
    methodName: array[NameBytes, char]
    methodLen: int
    instance: array[InstanceBytes, char]
    instanceLen: int
    atNs: int64

  var
    dropNext: Atomic[bool]
    failWrites: Atomic[bool]
    suppressHints: Atomic[bool]
    pauseGate: Atomic[bool]
    pausedCount: Atomic[int]
    halted: Atomic[int]
    recordLock: Lock
    recorded: ptr array[MaxRecorded, Recorded]
    recordedLen: int

  initLock(recordLock)
  recorded = cast[ptr array[MaxRecorded, Recorded]](allocShared0(
    sizeof(array[MaxRecorded, Recorded])
  ))

  proc setOrchestratorFaultsForTests*(f: OrchestratorFaults) =
    dropNext.store(f.dropNextAnswer)
    failWrites.store(f.failWrites)
    suppressHints.store(f.suppressHints)
    pauseGate.store(f.pauseBeforeRequest)

  proc clearOrchestratorFaultsForTests*() =
    ## Every fault off, the counters and the call record emptied.
    setOrchestratorFaultsForTests(OrchestratorFaults())
    pausedCount.store(0)
    halted.store(0)
    withLock recordLock:
      recordedLen = 0

  proc openPauseGateForTests*() =
    pauseGate.store(false)

  proc pausedForTests*(): int =
    ## How many times the worker has waited at the gate.
    pausedCount.load

  proc haltedForTests*(): int =
    ## How many workers `dropNextAnswer` halted.
    halted.load

  proc fill[N: static int](dst: var array[N, char], n: var int, s: string) =
    n = min(s.len, N)
    for i in 0 ..< n:
      dst[i] = s[i]

  proc text[N: static int](a: array[N, char], n: int): string =
    result = newString(n)
    for i in 0 ..< n:
      result[i] = a[i]

  proc recordCall*(methodName, instance: string) =
    withLock recordLock:
      if recordedLen < MaxRecorded:
        var r = Recorded(atNs: getMonoTime().ticks)
        fill(r.methodName, r.methodLen, methodName)
        fill(r.instance, r.instanceLen, instance)
        recorded[recordedLen] = r
        inc recordedLen

  proc callTimesForTests*(methodName: string, instance = ""): seq[int64] =
    ## The monotonic times (ns) of the recorded calls of `methodName` on
    ## `instance` (any instance when empty), in order.
    withLock recordLock:
      for i in 0 ..< recordedLen:
        let r = recorded[i]
        if text(r.methodName, r.methodLen) == methodName and
            (instance.len == 0 or text(r.instance, r.instanceLen) == instance):
          result.add(r.atNs)

  proc callsForTests*(methodName: string, instance = ""): int =
    callTimesForTests(methodName, instance).len

  proc targetsForTests*(): seq[string] =
    ## Every instance a recorded call named.
    withLock recordLock:
      for i in 0 ..< recordedLen:
        let r = recorded[i]
        if r.instanceLen > 0:
          result.add(text(r.instance, r.instanceLen))

  proc dropThisAnswer*(): bool =
    ## True once after `dropNextAnswer` was selected; the worker then halts.
    if dropNext.exchange(false):
      halted += 1
      return true
    false

  proc writesFail*(): bool =
    failWrites.load

  proc hintsSuppressed*(): bool =
    suppressHints.load

  proc pauseGateSet*(): bool =
    pauseGate.load

  proc notePaused*() =
    pausedCount += 1

{.pop.}
