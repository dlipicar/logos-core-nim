## The trust snapshot builder (Tier 5 step 5-7a-1; DECISIONS G408, G324, I99;
## RUNTIME l.2650-2656, l.2673-2678): the remote trust state logosd accepted
## at its start (`daemon/remotetrust.nim`) as the `TrustSnapshot` the tls-tcp
## verifier checks a peer against (`trust.nim`). logosd builds it once per
## start (owner decision B3) and gives it to each remote process at spawn
## (5-7a-2); nothing changes it afterwards. No BoringSSL here.
##
## The input is plain data, so this module needs nothing of the daemon: the
## anchor set at its revision, and for each enrollment key the record
## accepted, or every record of a conflict at that revision.

{.push raises: [].}

import std/strutils
import results
import ./trust

export results, trust

const TlsTcpProfile* = "logos.remote.tls-tcp"
  ## The one profile this verifier serves (TRANSPORT §8.4.1)

type
  HeldStatus* = enum
    hsActive
    hsRevoked

  HeldRecord* = object ## One accepted enrollment record (RUNTIME l.2599-2632).
    runtime*: string
    profile*: string
    revision*: uint64
    status*: HeldStatus
    anchor*: seq[byte] ## `active`: the trust anchor's identifier
    keys*: seq[seq[byte]] ## `active`: one or two DER `SubjectPublicKeyInfo`

  HeldKey* = object
    ## One enrollment key's accepted state: one record, or, in a conflict, every
    ## record held at that revision (R l.2653-2654).
    records*: seq[HeldRecord]

  HeldAnchor* = object
    id*: seq[byte]
    certificate*: seq[byte] ## DER: a direct anchor (G324)

func anchorName*(id: openArray[byte]): string =
  ## A trust anchor identifier as the snapshot names it: lowercase hex.
  result = newStringOfCap(id.len * 2)
  for b in id:
    result.add(toHex(b, 2).toLowerAscii)

func conflicting*(k: HeldKey): bool =
  k.records.len > 1

func currentRecord*(k: HeldKey): Result[EnrollmentRecord, string] =
  ## [G324] What the verifier holds for one key: `active` with its anchor and
  ## keys, `revoked`, or `conflicting` with every key either record names, so
  ## that an inbound key a conflicting identity holds fails (T l.1253-1254).
  if k.records.len == 0:
    return err("an enrollment key holds no record")
  let first = k.records[0]
  if k.conflicting:
    var keys: seq[seq[byte]]
    for r in k.records:
      if r.runtime != first.runtime or r.profile != first.profile or
          r.revision != first.revision:
        return err("a conflict's records differ in key or revision")
      for key in r.keys:
        if key notin keys:
          keys.add(key)
    return ok(
      EnrollmentRecord(
        runtime: first.runtime,
        revision: first.revision,
        status: rsConflicting,
        spkis: keys,
      )
    )
  case first.status
  of hsActive:
    ok(
      EnrollmentRecord(
        runtime: first.runtime,
        revision: first.revision,
        status: rsActive,
        anchor: anchorName(first.anchor),
        spkis: first.keys,
      )
    )
  of hsRevoked:
    ok(
      EnrollmentRecord(
        runtime: first.runtime, revision: first.revision, status: rsRevoked
      )
    )

proc buildSnapshot*(
    revision: uint64, anchors: openArray[HeldAnchor], held: openArray[HeldKey]
): Result[TrustSnapshot, string] =
  ## The snapshot of the accepted state: every anchor, at the set's revision,
  ## and the current record of each `logos.remote.tls-tcp` key. A record of
  ## another profile is held by logosd and has no use here.
  var named: seq[(string, seq[byte])]
  for a in anchors:
    named.add((anchorName(a.id), a.certificate))
  var records: seq[EnrollmentRecord]
  for k in held:
    if k.records.len > 0 and k.records[0].profile == TlsTcpProfile:
      records.add(?currentRecord(k))
  newTrustSnapshot(revision, named, records)

{.pop.}
