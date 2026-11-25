## The Package Manager's worker thread (Tier 5 step 5-5-3; DECISIONS G447;
## docs/PACKAGE-MANAGER.md §10). One thread per instance runs the jobs of
## `jobs.nim` in order, so no archive is written, read or judged on the module
## thread.
##
## - **Started** at `_MODULE_init`, after the store's start (`openShell`): the
##   thread gets its own copy of the inputs (`wjStart`). A thread that cannot be
##   created fails `_MODULE_init`.
## - **Jobs and answers** cross on two channels, and only values with no
##   reference (`jobs.refFree`). An answer is handed to the module thread by the
##   kit's `post`: one post at a time, re-armed by the drain (`posted`), so a
##   burst of answers costs one callback.
## - **No failure event** (G447, D2): a job's failure is its answer (a spool
##   write that failed, an archive refused or unavailable). A Defect ends the
##   process, as it would on the module thread: no handler here catches
##   `Exception` or `Defect` (Fable's D2 condition 1), so the channel calls,
##   whose inferred effect is `Exception`, run under `cast(raises: [])` and a
##   fault in them unwinds out of the thread, which ends the process.
## - **A worker that hangs** (a write or a sync that never returns) has no
##   event either: in 5-5-3 its operation and every later one wait with no
##   answer of their own; 5-5-4's operation deadline answers them.
## - **Stopped** at `_MODULE_destroy` (`stopWorker`): the stop flag ends an
##   inspection under way at its next check (`LgxStop`), `wjQuit` follows the
##   queued jobs, the thread deletes every spool file it holds and is joined;
##   then a drain still queued is waited for, bounded, since the kit runs a
##   posted callback while `_MODULE_destroy` runs and drops it after (G437).
##   Answers still queued are dropped.

{.push raises: [], gcsafe.}

import std/atomics
import results
import chronos
import logos_sdk/confined
import logos_sdk/base/entry
import ./jobs

export jobs

type
  WorkerDeliver* =
    proc(owner: pointer, r: sink WorkerResult) {.nimcall, gcsafe, raises: [].}
    ## Receives each answer on the module thread.

  WorkerShared = object
    jobs: Channel[WorkerJob]
    results: Channel[WorkerResult]
    stop: Atomic[bool] ## read by an inspection under way (`LgxStop`)
    posted: Atomic[bool] ## a drain is queued on the module thread
    poster: Poster
    owner: pointer
    deliver: WorkerDeliver
    closing: bool ## module thread only
    thread: Thread[ptr WorkerShared]

  Worker* = ptr WorkerShared

const StopWait = 10.seconds
  ## [IMPL] how long `stopWorker` waits for a drain the kit still holds

proc drainClose[T](ch: var Channel[T]) =
  ## Closes `ch` once whatever is still queued in it is destroyed: under orc `send` moves
  ## a value into the channel's buffer and `close` frees that buffer without destroying
  ## it (as `authority/core.nim`).
  {.cast(raises: []).}:
    while true:
      let (ok, _) = ch.tryRecv()
      if not ok:
        break
    ch.close()

proc drainWorker(payload: pointer) {.lcnModuleThread.} =
  ## [G447] On the module thread: every answer queued, to the owner.
  let w = cast[Worker](payload)
  w.posted.store(false)
  while true:
    var got: (bool, WorkerResult)
    {.cast(raises: []).}:
      got = w.results.tryRecv()
    if not got[0]:
      break
    if not w.closing:
      w.deliver(w.owner, move got[1])

proc workerMain(w: Worker) {.thread.} =
  var state: WorkerState
  let stop = LgxStop(addr w.stop)
  while true:
    var job: WorkerJob
    {.cast(raises: []).}:
      job = w.jobs.recv()
    if job.kind == wjQuit:
      break
    if w.stop.load and job.kind != wjDrop:
      continue # stopping: only deletions still run
    let r = state.runJob(job, stop)
    if r.isSome:
      {.cast(raises: []).}:
        w.results.send(r.get)
      if not w.posted.exchange(true):
        post(w.poster, entered(drainWorker), cast[pointer](w))
  state.close()

proc freeWorker(w: Worker) =
  w.jobs.drainClose()
  w.results.drainClose()
  deallocShared(w)

proc startWorker*(
    poster: Poster, owner: pointer, deliver: WorkerDeliver, config: sink WorkerConfig
): Result[Worker, string] =
  ## [G447] The worker thread, started with `config`; answers go to `deliver(owner, …)`
  ## on the module thread `poster` names.
  let w = cast[Worker](allocShared0(sizeof(WorkerShared)))
  w.jobs.open()
  w.results.open()
  w.poster = poster
  w.owner = owner
  w.deliver = deliver
  {.cast(raises: []).}:
    w.jobs.send(WorkerJob(kind: wjStart, config: config))
  try:
    createThread(w.thread, workerMain, w)
  except ResourceExhaustedError as e:
    # [Fable's D2 condition 2] The start's only failure, before `_MODULE_init` returns.
    w.freeWorker()
    return err("the Package Manager's worker thread could not be started: " & e.msg)
  ok(w)

proc submit*(w: Worker, job: sink WorkerJob) =
  ## [G447] Queues `job` for the worker; the channel has no bound, and the engine bounds
  ## what it queues (`SpoolLag` pieces per retrieval).
  if w.closing:
    return
  {.cast(raises: []).}:
    w.jobs.send(job)

proc abandonWorker*(w: Worker) =
  ## [G500] At a failed `_MODULE_init`: a worker that has answered nothing (only its
  ## `wjStart` was queued) is stopped, joined and freed at once.
  w.closing = true
  w.stop.store(true)
  {.cast(raises: []).}:
    w.jobs.send(WorkerJob(kind: wjQuit))
    joinThread(w.thread)
  if not w.posted.load:
    w.freeWorker()

proc stopWorker*(w: Worker): Future[void] {.async: (raises: []).} =
  ## [G447] At `_MODULE_destroy`: the thread stops after its current job and is joined,
  ## its spool files deleted; then the drain the kit may still hold is waited for.
  if w.closing:
    return
  w.closing = true
  w.stop.store(true)
  {.cast(raises: []).}:
    w.jobs.send(WorkerJob(kind: wjQuit))
    joinThread(w.thread)
  let until = Moment.now() + StopWait
  while w.posted.load and Moment.now() < until:
    try:
      await sleepAsync(1.milliseconds)
    except CancelledError:
      break
  if w.posted.load:
    return # the kit still holds a drain that reads `w`: it stays allocated
  w.freeWorker()

{.pop.}
