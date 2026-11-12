## The grant table [IMPL] (CA §6; NA-05, G51; DECISIONS I84).
##
## A grant is kept as issued, with its target's facts when issued (for
## historical visibility, CA l.78-79) and its lifecycle audit records.
## `expired` is derived at every read from `now >= expires_at` (CAP-0140,
## CAP-0144), whether or not the expiry timer has run; the timer only does the
## transition work (event and record). Targets and scopes are never rewritten
## (CAP-0336), and `issuer` is written once.

{.push raises: [].}

import std/[algorithm, heapqueue, tables]
import results
import ./[audit, policy, scopes]

export results

type
  GrantEntry* = object
    grant*: Grant ## as issued, then as revoked; status `active` or `revoked`
    targetFacts*: FactsSnapshot
    records*: seq[StoredRecord] ## its issue, revoke and expiry records
    expiryEmitted*: bool ## the expiry event went out
    expiryRecorded*: bool ## its expiry record is in `records`

  GrantTable* = object
    byId*: Table[string, GrantEntry]
    ids*: seq[string] ## ascending by bytes (CAP-0330)
    expiry*: HeapQueue[(uint64, string)] ## `(expires_at, id)` of unexpired grants

func status*(g: Grant, now: uint64): GrantStatusKind =
  if g.status.kind == GrantStatusKind.Revoked:
    GrantStatusKind.Revoked
  elif g.expires_at.isSome and now >= g.expires_at.get:
    GrantStatusKind.Expired
  else:
    GrantStatusKind.Active

func statusValue*(k: GrantStatusKind): LogosNSCapabilityAuthorityGrantStatus =
  LogosNSCapabilityAuthorityGrantStatus(kind: k)

func current*(g: Grant, now: uint64): Grant =
  ## The grant with its derived status.
  result = g
  result.status = statusValue(g.status(now))

func terminalAt*(e: GrantEntry, now: uint64): Opt[uint64] =
  ## When it became revoked or expired, if it has.
  if e.grant.revoked_at.isSome:
    Opt.some(e.grant.revoked_at.get)
  elif e.grant.expires_at.isSome and now >= e.grant.expires_at.get:
    Opt.some(e.grant.expires_at.get)
  else:
    Opt.none(uint64)

func issuerModule*(g: Grant): Opt[Address] =
  if g.issuer.kind == LogosNSCapabilityAuthorityGrantIssuerKind.Module:
    Opt.some(g.issuer.arm_Module.module)
  else:
    Opt.none(Address)

func len*(t: GrantTable): int =
  t.byId.len

func contains*(t: GrantTable, id: string): bool =
  id in t.byId

proc put*(t: var GrantTable, e: sink GrantEntry) =
  ## Inserts a new grant, or replaces the entry of a known one.
  let id = e.grant.grant_id
  if id notin t.byId:
    let at = t.ids.lowerBound(id, cmp)
    t.ids.insert(id, at)
    if e.grant.expires_at.isSome and e.grant.status.kind == GrantStatusKind.Active:
      t.expiry.push((e.grant.expires_at.get, id))
  t.byId[id] = e

proc remove*(t: var GrantTable, id: string) =
  ## Purges a terminal grant (its expiry heap entry, if any, is skipped later).
  if id in t.byId:
    t.byId.del(id)
    let at = t.ids.lowerBound(id, cmp)
    if at < t.ids.len and t.ids[at] == id:
      t.ids.delete(at)

func oldestTerminal*(t: GrantTable, now: uint64): Opt[string] =
  ## The terminal grant with the oldest `terminalAt`, ties by id.
  var best = Opt.none((uint64, string))
  for id, e in t.byId:
    let at = e.terminalAt(now)
    if at.isSome:
      let k = (at.get, id)
      if best.isNone or k < best.get:
        best = Opt.some(k)
  if best.isSome:
    Opt.some(best.get[1])
  else:
    Opt.none(string)

func firstAfter*(t: GrantTable, id: string): int =
  ## The index of the first id strictly greater than `id`.
  t.ids.upperBound(id, cmp)

func nextExpiry*(t: GrantTable): Opt[uint64] =
  if t.expiry.len > 0:
    Opt.some(t.expiry[0][0])
  else:
    Opt.none(uint64)
