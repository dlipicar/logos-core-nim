## The Module Host's dispatch pool, its counts (DECISIONS I146) [IMPL].
##
## Every job posted to the pool is claimed, under the pool's lock, at the post:
## by an idle worker, by a new worker whose thread index the claim takes, or,
## with every worker busy at the cap, as a waiting job that the next worker to
## finish takes before it counts itself idle. So the jobs queued never exceed
## the workers that will take them, and two posts never start the same thread.
## Pure, so the counting is tested without threads (`test_module_host`).

type
  DispatchClaim* = enum
    dcIdle ## an idle worker takes the job
    dcGrow ## a new worker, at `DispatchCounts.claim`'s returned index
    dcWaiting ## every worker busy at the cap: the next one to finish takes it

  DispatchCounts* = object
    idle*: int ## workers waiting for a job that no post has claimed
    waiting*: int ## jobs queued with no worker claimed for them
    count*: int ## workers started

func claim*(c: var DispatchCounts, cap: int): tuple[kind: DispatchClaim, index: int] =
  ## A post's claim; `index` is the new worker's, for `dcGrow` only.
  if c.idle > 0:
    dec c.idle
    (dcIdle, -1)
  elif c.count < cap:
    inc c.count
    (dcGrow, c.count - 1)
  else:
    inc c.waiting
    (dcWaiting, -1)

func finished*(c: var DispatchCounts): bool =
  ## A worker's job ended: true when it takes a waiting job next, false when
  ## it now counts as idle.
  if c.waiting > 0:
    dec c.waiting
    true
  else:
    inc c.idle
    false
