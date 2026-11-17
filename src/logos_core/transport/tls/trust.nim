## TRANSPORT §8.4.1 l.1223-1226, l.1245-1254; RUNTIME l.2005-2028, l.2669-2723;
## owner decisions B2, B3 (2026-11-17); I99: the trust snapshot the tls-tcp
## verifier checks a peer against. It is built from protected input (5-7a loads
## the remote trust anchors and the enrollment records at start, B3) and never
## changes afterwards: nothing a peer presents adds an anchor or an enrollment
## (T l.1223-1224). No BoringSSL here.

{.push raises: [].}

import std/tables
import results

export results

type
  RecordStatus* = enum
    rsActive ## the current record is `active`
    rsRevoked ## the current record is `revoked`: no new or existing session (R l.2699)
    rsConflicting ## two different records at the current revision (R l.2697-2698)

  EnrollmentRecord* = object
    ## The current `logos.remote.tls-tcp` record of one Runtime: the loader keeps
    ## the highest revision (R l.2694-2696), so a stale record never gets here.
    runtime*: string ## the enrolled Runtime's id (lowercase UUIDv4)
    revision*: uint64
    status*: RecordStatus
    anchor*: string ## `active`: the trust anchor's identifier
    spkis*: seq[seq[byte]]
      ## `active`: one or two DER `SubjectPublicKeyInfo` (R l.2019-2021);
      ## `conflicting`: every key either record names, so that an inbound key
      ## held by a conflicting identity fails (T l.1253-1254)

  TrustSnapshot* = ref object
    ## The anchors of the remote trust-anchor set (identifier to certificate
    ## DER, B2: each a direct anchor) at one set revision (R l.2718-2723), and
    ## the current tls-tcp record of each enrolled Runtime. Immutable.
    anchorRevision: uint64
    anchors: Table[string, seq[byte]]
    records: Table[string, EnrollmentRecord]

func isRuntimeId*(s: string): bool =
  ## [SPEC RUNTIME §9.4] l.2669-2670: for the remote profiles a Runtime id is a
  ## lowercase canonical UUIDv4 (8-4-4-4-12 hex digits, version 4, the RFC 9562
  ## variant).
  if s.len != 36:
    return false
  for i, c in s:
    if i in [8, 13, 18, 23]:
      if c != '-':
        return false
    elif c notin {'0' .. '9', 'a' .. 'f'}:
      return false
  s[14] == '4' and s[19] in {'8', '9', 'a', 'b'}

proc newTrustSnapshot*(
    anchorRevision: uint64,
    anchors: openArray[(string, seq[byte])],
    records: openArray[EnrollmentRecord],
): Result[TrustSnapshot, string] =
  ## Checks and freezes protected input: anchor identifiers unique and
  ## non-empty, each Runtime once, its id a lowercase UUIDv4, an `active` record
  ## naming a known anchor and one or two distinct keys.
  let snap = TrustSnapshot(anchorRevision: anchorRevision)
  for (id, der) in anchors:
    if id.len == 0 or id.len > 128:
      return err("a trust anchor identifier must be 1 to 128 octets")
    if der.len == 0:
      return err("trust anchor " & id & " has no certificate")
    if id in snap.anchors:
      return err("trust anchor " & id & " is listed twice")
    snap.anchors[id] = der
  for r in records:
    if not isRuntimeId(r.runtime):
      return err("not a lowercase UUIDv4 Runtime id: " & r.runtime)
    if r.runtime in snap.records:
      return err("Runtime " & r.runtime & " has two current records")
    case r.status
    of rsActive:
      if r.anchor notin snap.anchors:
        return err("Runtime " & r.runtime & " names unknown trust anchor " & r.anchor)
      if r.spkis.len notin 1 .. 2:
        return err("Runtime " & r.runtime & " must hold one or two keys")
      if r.spkis.len == 2 and r.spkis[0] == r.spkis[1]:
        return err("Runtime " & r.runtime & " holds the same key twice")
      for k in r.spkis:
        if k.len == 0:
          return err("Runtime " & r.runtime & " holds an empty key")
    of rsRevoked, rsConflicting:
      discard
    snap.records[r.runtime] = r
  ok(snap)

func anchorRevision*(t: TrustSnapshot): uint64 =
  t.anchorRevision

func anchorCount*(t: TrustSnapshot): int =
  t.anchors.len

func recordCount*(t: TrustSnapshot): int =
  t.records.len

func anchor*(t: TrustSnapshot, id: string): Opt[seq[byte]] =
  ## The certificate DER of anchor `id`.
  if id in t.anchors:
    Opt.some(t.anchors.getOrDefault(id))
  else:
    Opt.none(seq[byte])

func record*(t: TrustSnapshot, runtime: string): Opt[EnrollmentRecord] =
  ## The current record of `runtime`.
  if runtime in t.records:
    Opt.some(t.records.getOrDefault(runtime))
  else:
    Opt.none(EnrollmentRecord)

func holdersOf*(t: TrustSnapshot, spki: seq[byte]): seq[EnrollmentRecord] =
  ## Every current record, of any status, that names the key `spki`.
  result = @[]
  for r in t.records.values:
    for k in r.spkis:
      if k == spki:
        result.add(r)
        break

{.pop.}
