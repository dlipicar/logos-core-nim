## The operations' slots and their queues (Tier 5 step 5-5-4; DECISIONS G449;
## docs/PACKAGE-MANAGER.md §11; plan §4.6, §4.13).
##
## Two slots for each instance, each running one operation at a time, first in,
## first out, neither waiting for the other:
## - **the mutation slot**: `install_package`, `remove_package` and
##   `update_package`, one installed-state mutation at a time (PKG-0409 to
##   0411; the MAY for disjoint mutations, PKG-0411, is not used);
## - **the inspection slot**: `inspect_package`, which does not queue behind
##   mutations.
##
## Each slot holds at most `MaxQueuedOperations` waiting requests, the running
## one not counted. A request past that is refused at once, before any work and
## with no snapshot taken: the invocation error `MODULE_ERROR` (PM l.1516-1517;
## plan §4.13). A waiting request that is cancelled, or whose caller is gone,
## leaves its queue without running, and the next one moves up.

{.push raises: [], gcsafe.}

import results

export results

const MaxQueuedOperations* = 16
  ## [IMPL; plan §4.13, planning's ruling Q-C] the requests waiting in one slot

type
  SlotKind* = enum
    slMutation ## install, remove, update
    slInspection ## inspect

  Slot* = object
    running: Opt[uint64]
    waiting: seq[uint64] ## first in, first out

  Admission* = enum
    adRun ## the slot was free: the request runs now
    adQueued ## it waits behind the running one
    adFull ## refused: the queue holds `MaxQueuedOperations` already

func running*(s: Slot): Opt[uint64] =
  s.running

func waiting*(s: Slot): int =
  s.waiting.len

func isWaiting*(s: Slot, request: uint64): bool =
  request in s.waiting

proc admit*(s: var Slot, request: uint64): Admission =
  ## The request arrives: it runs, waits, or is refused.
  if s.running.isNone:
    s.running = Opt.some(request)
    return adRun
  if s.waiting.len >= MaxQueuedOperations:
    return adFull
  s.waiting.add(request)
  adQueued

proc withdraw*(s: var Slot, request: uint64): bool =
  ## A waiting request leaves its queue without running; false if it was not
  ## waiting.
  let i = s.waiting.find(request)
  if i < 0:
    return false
  s.waiting.delete(i)
  true

proc finish*(s: var Slot, request: uint64): Opt[uint64] =
  ## The running request ended: the next one, if any, now runs.
  doAssert s.running == Opt.some(request), "only the running request finishes"
  if s.waiting.len == 0:
    s.running = Opt.none(uint64)
  else:
    s.running = Opt.some(s.waiting[0])
    s.waiting.delete(0)
  s.running

proc clear*(s: var Slot): seq[uint64] =
  ## Every request the slot holds, the running one first, in order; the slot is
  ## left empty (the module stops).
  if s.running.isSome:
    result.add(s.running.get)
  result.add(s.waiting)
  s.running = Opt.none(uint64)
  s.waiting.setLen(0)

{.pop.}
