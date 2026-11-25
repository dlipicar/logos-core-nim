## The Package Manager's cursors and their retention policy (Tier 5 step 5-6b-1;
## DECISIONS G499; docs/PACKAGE-MANAGER.md §15; PACKAGE MANAGER l.1645-1654,
## l.1729-1734). Portable and pure: the engine holds one `Cursors`, on the module
## thread, with its clock and its token source injected.
##
## **The retention policy (PM l.1731), for both lists:**
## - **A cursor holds no snapshot of its own.** It names the snapshot it began on
##   (`epoch`: the installed snapshot's sequence, or the catalog's epoch) and a
##   position in that snapshot's listing order. A continuation against the same
##   snapshot goes on; once a commit or a new catalog has superseded it, the cursor
##   has expired and the call is `invalid-request` (l.1654). A superseded snapshot
##   is never retained for a cursor, so storage charged is the cursor record only.
## - **A page job in flight** holds its installed snapshot for the job's length,
##   as `get_runtime_handoff` does (G451's R1): that is the engine's, not this.
## - **Count and age** [IMPL]: `PerOrigin` (8) cursors per origin and `Aggregate`
##   (256) in all; a cursor expires `IdleMs` (60 s) after its last use and
##   `LifeMs` (10 min) after it was made. Expired records are reclaimed on every
##   query and by the engine's 1 s timer.
## - **Overload:** an origin at its limit loses its own least recently used cursor
##   (PKG-0540), never another origin's; with the aggregate full and none of the
##   asking origin's cursors to give up, the issue fails (`ciFull`) and the call is
##   `MODULE_ERROR` with no detail (PKG-0541).
## - **A realization's cursors die with it:** nothing here is persisted, and a
##   binding never queries (PKG-0528).
##
## **Tokens:** 32 bytes from the operating system's random source, base64url
## without padding (43 characters, within the method's 512), keying a record of the
## origin (the caller's Runtime and module instance), the method, the `package`
## filter, the epoch, the position and its times. A token unknown to this
## realization, presented by another origin, or used for another method or filter
## is `invalid-request`; so is an expired one. A token is spent by the page it
## continues: the next page has a token of its own.

{.push raises: [], gcsafe.}

import std/[base64, sysrand, tables]
import results

export results

const
  PerOrigin* = 8 ## [IMPL; G499] cursors one origin holds
  Aggregate* = 256 ## [IMPL; G499] cursors in all
  IdleMs* = 60_000'i64 ## [IMPL; G499] a cursor's life after its last use
  LifeMs* = 600_000'i64 ## [IMPL; G499] a cursor's life after it was made
  TokenBytes* = 32 ## [IMPL; G499] a token's random bytes

type
  CursorMethod* = enum
    cmListPackages = "list_packages"
    cmListInstalled = "list_installed_packages"

  Origin* = object
    ## [G499] An ordinary caller's authenticated address: its Runtime and module
    ## instance (PM l.1645).
    runtime*: string
    instance*: string

  CursorRecord* = object
    origin*: Origin
    meth*: CursorMethod
    filter*: Opt[string] ## the `package` filter of the query it continues
    epoch*: uint64 ## the snapshot it began on
    position*: int ## the next record's place in that snapshot's listing order
    made*: int64 ## monotonic ms
    used*: int64

  TokenSource* = proc(): string {.gcsafe, raises: [].}
    ## A fresh token: `TokenBytes` random bytes, base64url without padding; empty
    ## when the random source failed.

  CursorIssue* = enum
    ciIssued
    ciFull ## [PKG-0541] the aggregate is full and the origin holds none to give up
    ciNoToken ## the random source failed

  CursorRefusal* = enum
    crUnknown ## no such token in this realization
    crOther ## another origin's, or another method's or filter's
    crExpired ## idle or absolute expiry, or its snapshot superseded

  Cursors* = object
    records: Table[string, CursorRecord] ## by token
    tokens: TokenSource
    issuedCount: int ## since the start, for the tests and the log

func `==`*(a, b: Origin): bool =
  a.runtime == b.runtime and a.instance == b.instance

func `$`*(o: Origin): string =
  "module instance " & o.instance & " of Runtime " & o.runtime

func tokenText*(bytes: openArray[byte]): string =
  ## [G499] base64url without padding.
  result = base64.encode(bytes, safe = true)
  while result.len > 0 and result[^1] == '=':
    result.setLen(result.len - 1)

proc randomToken*(): string {.gcsafe, raises: [].} =
  ## [G499] `TokenBytes` bytes from the operating system's random source; empty when
  ## it failed.
  var b: array[TokenBytes, byte]
  if not urandom(b):
    return ""
  tokenText(b)

func initCursors*(tokens: TokenSource): Cursors =
  Cursors(tokens: tokens)

func len*(c: Cursors): int =
  c.records.len

func issued*(c: Cursors): int =
  c.issuedCount

func held*(c: Cursors, o: Origin): int =
  for _, r in c.records:
    if r.origin == o:
      inc result

func expired(r: CursorRecord, now: int64): bool =
  now - r.used >= IdleMs or now - r.made >= LifeMs

proc reclaim*(c: var Cursors, now: int64, installed, catalog: uint64) =
  ## [G499] Drops every record that has expired by age, or whose snapshot a commit
  ## (`installed`, the current snapshot's sequence) or a new catalog (`catalog`, the
  ## catalog's epoch) has superseded.
  var gone: seq[string]
  for t, r in c.records:
    let current =
      case r.meth
      of cmListPackages: catalog
      of cmListInstalled: installed
    if r.expired(now) or r.epoch != current:
      gone.add(t)
  for t in gone:
    c.records.del(t)

proc dropOldest(c: var Cursors, o: Origin) =
  var oldest = ""
  var at = high(int64)
  for t, r in c.records:
    if r.origin == o and r.used < at:
      at = r.used
      oldest = t
  if oldest.len > 0:
    c.records.del(oldest)

proc issue*(
    c: var Cursors,
    origin: Origin,
    meth: CursorMethod,
    filter: Opt[string],
    epoch: uint64,
    position: int,
    now: int64,
): (CursorIssue, string) =
  ## [G499] A cursor for the next page. The origin at `PerOrigin` loses its least
  ## recently used cursor first (PKG-0540); with `Aggregate` held and none of the
  ## origin's to give up, nothing is issued (`ciFull`, PKG-0541). Call `reclaim`
  ## first, so that expired records are not counted.
  let mine = c.held(origin)
  if mine >= PerOrigin:
    c.dropOldest(origin)
  elif c.records.len >= Aggregate:
    if mine == 0:
      return (ciFull, "")
    c.dropOldest(origin)
  let token = c.tokens()
  if token.len == 0 or token in c.records:
    return (ciNoToken, "")
  c.records[token] = CursorRecord(
    origin: origin,
    meth: meth,
    filter: filter,
    epoch: epoch,
    position: position,
    made: now,
    used: now,
  )
  inc c.issuedCount
  (ciIssued, token)

proc take*(
    c: var Cursors,
    token: string,
    origin: Origin,
    meth: CursorMethod,
    filter: Opt[string],
    epoch: uint64,
    now: int64,
): Result[CursorRecord, CursorRefusal] =
  ## [G499; PM l.1645-1654] The record `token` keys, for the page that continues it:
  ## the same origin, method and filter, unexpired, on the current snapshot
  ## (`epoch`). The record stays until `spend`, so a page refused at a bound can be
  ## asked again with the same token.
  var r: CursorRecord
  if not c.records.pop(token, r):
    return err(crUnknown)
  if r.origin != origin or r.meth != meth or r.filter != filter:
    c.records[token] = r
    return err(crOther)
  if r.expired(now) or r.epoch != epoch:
    return err(crExpired)
  r.used = now
  c.records[token] = r
  ok(r)

proc spend*(c: var Cursors, token: string) =
  ## The page `token` continued was answered: its next page has a token of its own.
  c.records.del(token)

{.pop.}
