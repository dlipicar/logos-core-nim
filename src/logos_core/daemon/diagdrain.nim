## logosd's drain of the Runtime's retained diagnostics into its log (Tier 4b
## step 4b-6; I95, amended 2026-11-16; DAEMON.md §12; RUNTIME l.1227; BCP
## l.550-552).
##
## The Runtime keeps its diagnostics in memory, in a ring of `MaxDiagnostics`.
## logosd reads them with a cursor (`runtimeDiagnosticsAfter`): once at start,
## after bootstrap, so a state transfer's line is there; every `DrainPeriodMs`
## while it runs, on a thread of its own; and once more after the Runtime's
## shutdown, or before a Loader-loss exit. Each is one line,
## `runtime: <text>`, a warning when it reports a failed requirement (a call
## record not kept, state not persisted) and information otherwise. Those the
## ring dropped between two reads become one warning that counts them. The
## Runtime wrote every line to the logging rule (logging.nim), and text it did
## not write is quoted and attributed there (`logtext.supplied`).

{.push raises: [], gcsafe.}

import std/[atomics, os]
import results
import ../runtime/host
import ./logging

const DrainPeriodMs* = 1_000 ## [IMPL] how often logosd reads them while it runs

type
  Drain* = object
    ## Where one reader of one Runtime's diagnostics is: the serial of the last
    ## it logged. Kept in the `Daemon`, which is copied, so nothing else.
    cursor: uint64

  DrainThread* = object
    ## The periodic read, on a thread of its own. Not moved once started.
    rt: ptr LogosRuntimeHandle
    drain: Drain
    stopping: Atomic[bool]
    thread: Thread[ptr DrainThread]
    running: bool

proc drainNow*(d: var Drain, rt: ptr LogosRuntimeHandle) =
  ## Logs what the Runtime retained since the last read. Never while a
  ## `DrainThread` holds this reader.
  if rt == nil:
    return
  let (entries, overwritten) = runtimeDiagnosticsAfter(rt, d.cursor)
  if overwritten > 0:
    logWarn("runtime: " & $overwritten & " diagnostics dropped")
  for e in entries:
    if e.warn:
      logWarn("runtime: " & e.text)
    else:
      logInfo("runtime: " & e.text)
    d.cursor = e.serial

proc drainMain(t: ptr DrainThread) {.thread.} =
  while true:
    var waited = 0
    while waited < DrainPeriodMs and not t.stopping.load:
      sleep(20)
      waited += 20
    if t.stopping.load:
      return
    t.drain.drainNow(t.rt)

proc startDraining*(
    t: var DrainThread, d: Drain, rt: ptr LogosRuntimeHandle
): Result[void, string] =
  ## Reads every `DrainPeriodMs`, from where `d` is, until `stopDraining`.
  t.rt = rt
  t.drain = d
  t.stopping.store(false)
  try:
    createThread(t.thread, drainMain, addr t)
  except ResourceExhaustedError as e:
    return err("cannot start the diagnostics thread: " & e.msg)
  t.running = true
  ok()

proc stopDraining*(t: var DrainThread, d: var Drain) =
  ## Ends the thread, after its read in progress, and hands where it got to
  ## back to `d`, for a last `drainNow`.
  if t.running:
    t.stopping.store(true)
    joinThread(t.thread)
    t.running = false
    d = t.drain

{.pop.}
