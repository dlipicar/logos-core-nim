## Step 7 (DECISIONS I86): the list snapshots of Runtime Control
## `list_modules` and `list_routes`, their cursors and their limits (RUNTIME
## §9.3 l.3372-3413). Runtime thread only.
##
## [IMPL] A snapshot is built once, after method authorization, filters and
## per-record visibility, and keeps each record's value with the facts its
## disclosure is judged by (`observe.Subject`). Every page it issues that
## continues gets a fresh cursor: 32 bytes from the operating system's CSPRNG
## as unpadded base64url (43 characters), one per page position. A cursor resolves only for the
## consumer, method, effective filters and effective limit of the query that
## made the snapshot (l.3386); anything else, and an expired or evicted
## snapshot, is unknown. A retried cursor returns the same page, and the same
## next cursor, while its snapshot lives and the decision is unchanged.
##
## Accounting (l.3394-3398): per consumer at most `snapshotsPerConsumer`
## snapshots and `snapshotBytesPerConsumer` bytes, its least recently used
## snapshot evicted first; in all at most `snapshotsTotal` and
## `snapshotBytesTotal`, past which, after reclaiming expired snapshots, a new
## snapshot is refused (MODULE_ERROR) and never another consumer's evicted.
## A snapshot expires after `snapshotIdle` without a page and `snapshotLifetime`
## after it was made, and is reclaimed when its consumer's attempt ends.

{.push raises: [].}

import std/[base64, monotimes, strutils, sysrand, tables, times]
import results
import ./[observe, plumbing, rc_types]

type
  ListKind* = enum
    lkModules = "list_modules"
    lkRoutes = "list_routes"

  ListSnapshot* = ref object
    consumer*: string ## the consumer instance
    attempt*: string ## its attempt: the snapshot ends with it
    kind*: ListKind
    filters*: string ## the effective filters, normalized
    limit*: int ## the effective limit
    subjects*: seq[Subject]
    sizes*: seq[int] ## each record's encoded size
    modules*: seq[LogosNSRuntimeControlModuleRecord] ## lkModules
    routes*: seq[LogosNSRuntimeControlRouteRecord] ## lkRoutes
    bytes*: int ## what it is accounted for
    tokens*: Table[string, int] ## cursor -> position
    positions: Table[int, string] ## position -> its cursor
    created*, used*: MonoTime

  Snapshots* = object
    limits: EngineLimits
    byToken: Table[string, ListSnapshot]
    byConsumer: Table[string, seq[ListSnapshot]] ## least recently used first
    count, total: int

  Page* = object
    first*: int ## the position it starts at
    picked*: seq[int] ## the positions it returns
    next*: Opt[int] ## the position of the next disclosable record

func initSnapshots*(limits: EngineLimits): Snapshots =
  Snapshots(limits: limits)

func count*(s: Snapshots): int =
  s.count

func total*(s: Snapshots): int =
  s.total

func len*(x: ListSnapshot): int =
  x.subjects.len

proc newToken(): string =
  var raw: array[32, byte]
  doAssert urandom(raw), "no system randomness"
  var text = newString(32)
  for i, b in raw:
    text[i] = char(b)
  base64.encode(text, safe = true).strip(leading = false, chars = {'='})

proc forget(s: var Snapshots, x: ListSnapshot) =
  for t in x.tokens.keys:
    s.byToken.del(t)
  dec s.count
  s.total -= x.bytes
  var mine = s.byConsumer.getOrDefault(x.consumer)
  for i in 0 ..< mine.len:
    if mine[i] == x:
      mine.delete(i)
      break
  if mine.len == 0:
    s.byConsumer.del(x.consumer)
  else:
    s.byConsumer[x.consumer] = mine

func expired(s: Snapshots, x: ListSnapshot, now: MonoTime): bool =
  now - x.used >= s.limits.snapshotIdle or now - x.created >= s.limits.snapshotLifetime

proc reclaim*(s: var Snapshots, now: MonoTime) =
  ## Drops every expired snapshot.
  var gone: seq[ListSnapshot]
  for mine in s.byConsumer.values:
    for x in mine:
      if s.expired(x, now):
        gone.add(x)
  for x in gone:
    s.forget(x)

proc endAttempt*(s: var Snapshots, attempt: string) =
  ## The consumer's Runtime Control binding is gone (RUNTIME l.629): so are
  ## its snapshots.
  var gone: seq[ListSnapshot]
  for mine in s.byConsumer.values:
    for x in mine:
      if x.attempt == attempt:
        gone.add(x)
  for x in gone:
    s.forget(x)

proc nextReclaim*(s: Snapshots): Opt[MonoTime] =
  for mine in s.byConsumer.values:
    for x in mine:
      let at =
        min(x.used + s.limits.snapshotIdle, x.created + s.limits.snapshotLifetime)
      if result.isNone or at < result.get:
        result = Opt.some(at)

proc retain*(s: var Snapshots, x: ListSnapshot, now: MonoTime): Result[void, string] =
  ## [SPEC RUNTIME l.3394-3402] Accounts `x` to its consumer, evicting that
  ## consumer's least recently used snapshots to make room; refuses it when it
  ## cannot fit, leaving every other snapshot as it was.
  let l = s.limits
  if x.bytes > l.snapshotBytesPerConsumer or x.bytes > l.snapshotBytesTotal:
    return err("the snapshot is larger than a consumer may retain")
  s.reclaim(now)
  var mine = s.byConsumer.getOrDefault(x.consumer)
  var own = 0
  for y in mine:
    own += y.bytes
  # What the consumer's own evictions can free, oldest first, before any is
  # made: an aggregate refusal changes nothing.
  var evict = 0
  var freed = 0
  while mine.len - evict + 1 > l.snapshotsPerConsumer or
      own - freed + x.bytes > l.snapshotBytesPerConsumer:
    freed += mine[evict].bytes
    inc evict
  if s.count - evict + 1 > l.snapshotsTotal or
      s.total - freed + x.bytes > l.snapshotBytesTotal:
    return err("the Runtime's snapshot capacity is exhausted")
  for i in 0 ..< evict:
    s.forget(mine[i])
  x.created = now
  x.used = now
  s.byConsumer.mgetOrPut(x.consumer, @[]).add(x)
  inc s.count
  s.total += x.bytes
  ok()

proc issue*(s: var Snapshots, x: ListSnapshot, position: int): string =
  ## The cursor for the page of `x` starting at `position`: one per position,
  ## so a retried page hands back the same cursor.
  result = x.positions.getOrDefault(position)
  if result.len > 0:
    return
  result = newToken()
  while result in s.byToken:
    result = newToken()
  x.tokens[result] = position
  x.positions[position] = result
  s.byToken[result] = x

proc resolve*(
    s: var Snapshots,
    token, consumer: string,
    kind: ListKind,
    filters: string,
    limit: int,
    now: MonoTime,
): Opt[(ListSnapshot, int)] =
  ## [SPEC RUNTIME l.3386-3391] The snapshot and position of a cursor, when
  ## it is known, unexpired, and bound to exactly this query. The snapshot
  ## becomes its consumer's most recently used.
  let x = s.byToken.getOrDefault(token)
  if x.isNil:
    return
  if s.expired(x, now):
    s.forget(x)
    return
  if x.consumer != consumer or x.kind != kind or x.filters != filters or x.limit != limit:
    return
  x.used = now
  var mine = s.byConsumer.getOrDefault(x.consumer)
  for i in 0 ..< mine.len:
    if mine[i] == x:
      mine.delete(i)
      break
  mine.add(x)
  s.byConsumer[x.consumer] = mine
  Opt.some((x, x.tokens.getOrDefault(token)))

proc drop*(s: var Snapshots, x: ListSnapshot) =
  if not x.isNil and x.consumer in s.byConsumer:
    for y in s.byConsumer.getOrDefault(x.consumer):
      if y == x:
        s.forget(x)
        return

proc page*(
    x: ListSnapshot,
    first, budget: int,
    admits: proc(s: Subject): bool {.gcsafe, raises: [].},
): Result[Page, string] =
  ## [SPEC RUNTIME l.3379-3384, l.3389, l.3392] The page from `first`: at
  ## most the limit, fewer to stay within `budget` bytes, only records the
  ## current decision still admits; `next` exactly when a later record is
  ## admitted now. A first admitted record that alone exceeds the budget is an
  ## error, never skipped.
  var p = Page(first: first)
  var used = 0
  var i = first
  while i < x.len:
    if admits(x.subjects[i]):
      if p.picked.len == x.limit:
        p.next = Opt.some(i)
        return ok(p)
      if used + x.sizes[i] > budget:
        if p.picked.len == 0:
          return err("a record does not fit in a response")
        p.next = Opt.some(i)
        return ok(p)
      used += x.sizes[i]
      p.picked.add(i)
    inc i
  ok(p)
