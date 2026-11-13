## Step 8b (DECISIONS I85): the decision cache (CA §8 l.857-867; plan §2.7).
##
## - Only Capability Authority allows with `valid_until` are kept (CAP-0119,
##   CAP-0120). `renew-route` and every `module_execution` decision bypass it
##   and are never stored (CA l.857, l.859; RUNTIME l.3184, l.3539).
## - The key is the binding generation and the exact `evaluate_request` bytes,
##   so the consumer, operation, target and scopes match by construction
##   (CA l.865); nothing crosses a generation (CAP-0347, CAP-0348).
## - A use needs the wall clock before `valid_until` and the engine clock's
##   monotonic reading before the deadline fixed at receipt, so a backward
##   wall-clock step never extends authority (RUN-0939, CAP-0342).
## - Invalidation: everything on `policy_changed`, binding or path loss, and
##   shutdown; the entries listing a grant on its revocation or expiry
##   (CAP-0171, CAP-0172, CAP-0184, CAP-0185); a retired instance's entries.
## - [IMPL] At most `MaxCachedDecisions` entries, the least recently used
##   dropped first. Nothing is persisted (CA l.879).

{.push raises: [].}

import std/tables
import results
import ./authz

const MaxCachedDecisions* = 4096 ## [IMPL]

type
  CacheEntry = object
    answer: AuthzAnswer
    validUntil: uint64
    monoDeadline: int64 ## monotonic nanoseconds
    used: uint64

  DecisionCache* = object
    entries: Table[seq[byte], CacheEntry]
    tick: uint64

func cacheKey*(generation: uint64, request: openArray[byte]): seq[byte] =
  for i in 0 ..< 8:
    result.add(byte((generation shr (8 * i)) and 0xFF))
  result.add(request)

proc get*(
    c: var DecisionCache, key: seq[byte], wallNow: uint64, monoNow: int64
): Opt[AuthzAnswer] =
  c.entries.withValue(key, e):
    if wallNow < e.validUntil and monoNow < e.monoDeadline:
      inc c.tick
      e.used = c.tick
      return Opt.some(e.answer)
  c.entries.del(key)
  Opt.none(AuthzAnswer)

proc put*(
    c: var DecisionCache, key: seq[byte], answer: AuthzAnswer, monoDeadline: int64
) =
  if answer.validUntil.isNone:
    return
  if key notin c.entries and c.entries.len >= MaxCachedDecisions:
    var oldest: seq[byte]
    var least = high(uint64)
    for k, e in c.entries:
      if e.used < least:
        least = e.used
        oldest = k
    c.entries.del(oldest)
  inc c.tick
  c.entries[key] = CacheEntry(
    answer: answer,
    validUntil: answer.validUntil.get,
    monoDeadline: monoDeadline,
    used: c.tick,
  )

proc clear*(c: var DecisionCache) =
  c.entries.clear()

template dropWhere(c: var DecisionCache, pred: untyped) =
  var gone: seq[seq[byte]]
  for k, e in c.entries:
    let a {.inject.} = e.answer
    if pred:
      gone.add(k)
  for k in gone:
    c.entries.del(k)

proc dropGrant*(c: var DecisionCache, grant: string) =
  ## [CAP-0185] The decisions that list `grant`.
  c.dropWhere(grant in a.grants)

proc dropInstance*(c: var DecisionCache, instance: string) =
  ## A retired instance's decisions, as consumer or target.
  c.dropWhere(a.request.consumer == instance or a.request.instance == instance)

func len*(c: DecisionCache): int =
  c.entries.len
