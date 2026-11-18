## logosd's trust file and its continuity (Tier 4b step 4b-6; DECISIONS G137,
## G299; D27; decision 11; PACKAGE MANAGER l.395-400). docs/DAEMON.md §6.
##
## `trust.cbor` is the revisioned trust input: its revision and, in 4b, D27's
## development switch (Tier 5 adds the package-signing anchors). Without the
## file the compiled-in floor applies: revision 1, switch off.
## `state/trust-mark.cbor` keeps the highest revision used and the digest of
## its bytes, written durably before that revision is used.
##
## | Mark       | File                                 | Decision                         |
## |------------|--------------------------------------|----------------------------------|
## | absent     | any                                  | refused: re-establish (PKG-0421) |
## | revision r | revision > r                         | mark written, then used          |
## | revision r | revision = r, same digest            | accepted (identical replay)      |
## | revision r | revision = r, other digest           | refused (PKG-0420)               |
## | revision r | revision < r, or below the floor     | refused (PKG-0420)               |
##
## logosd never creates a mark (P6-31): `logosctl init` writes the file and its
## mark together, and `logosctl trust reestablish --revision N` writes one
## when the owner names the file's revision. Every change is offline, under
## the session lock, and applies at the next start (BCP l.359).

{.push raises: [].}

import std/os
import results
import logos_sdk/cbor
import logos_sdk/crypto/blake3
import ../durable
import ./[session, trust_types]

export results, trust_types

const
  TrustFormat* = "logos-core-nim.trust.v1"
  MarkFormat* = "logos-core-nim.trust-mark.v1"
  FloorRevision* = 1'u64 ## [G137] the compiled-in floor
  MaxTrustBytes = 1024 * 1024
  NotEstablished* =
    "trust continuity is not established; run logosctl trust reestablish --revision N"

type TrustInput* = object ## The trust input in force: the file, or the floor.
  file*: LcnTrustFile
  digest*: seq[byte] ## BLAKE3-256 of the deterministic bytes
  present*: bool ## the file exists

func floorFile*(): LcnTrustFile =
  LcnTrustFile(revision: FloorRevision, development: false)

proc inputOf(f: LcnTrustFile, present: bool): Result[TrustInput, string] =
  let bytes = f.encode.valueOr:
    return err(error)
  ok(TrustInput(file: f, digest: @(blake3(bytes)), present: present))

proc readTrust*(s: Session): Result[TrustInput, string] =
  ## [G137] The trust file, or the floor when there is none. A file below the
  ## floor is refused.
  let bytes = ?readSessionFile(s.trustPath, MaxTrustBytes)
  if bytes.isNone:
    return inputOf(floorFile(), false)
  let f = LcnTrustFile.decode(bytes.get).valueOr:
    return err(TrustName & " is not a trust file: " & error)
  if f.revision < FloorRevision:
    return err(TrustName & " is below the compiled-in floor (revision 1)")
  ok(TrustInput(file: f, digest: @(blake3(bytes.get)), present: true))

proc readMark*(s: Session): Result[Opt[LcnTrustMark], string] =
  let bytes = ?readSessionFile(s.stateDir / TrustMarkName, MaxTrustBytes)
  if bytes.isNone:
    return ok(Opt.none(LcnTrustMark))
  let m = LcnTrustMark.decode(bytes.get).valueOr:
    return err(TrustMarkName & " is not a trust mark: " & error)
  ok(Opt.some(m))

proc writeMark*(s: Session, t: TrustInput): Result[void, string] =
  ## Durable before the revision is used (PKG-0419).
  let bytes = LcnTrustMark(revision: t.file.revision, digest: t.digest).encode.valueOr:
    return err(error)
  writeAtomic(s.stateDir, TrustMarkName, bytes)

type Continuity* = enum
  cAccept ## identical replay: the mark stays
  cAdvance ## a higher revision: write the mark, then use it

func decide*(t: TrustInput, mark: Opt[LcnTrustMark]): Result[Continuity, string] =
  ## [PKG-0418 to PKG-0421; G299] The table above.
  if mark.isNone:
    return err(NotEstablished)
  let m = mark.get
  if t.file.revision > m.revision:
    return ok(cAdvance)
  if t.file.revision == m.revision:
    if t.digest == m.digest:
      return ok(cAccept)
    return err(
      "the trust file's revision " & $t.file.revision &
        " has other contents than the revision recorded; a changed file needs a higher revision"
    )
  err(
    "the trust file's revision " & $t.file.revision & " is below the revision " &
      $m.revision & " already used: rollback is refused"
  )

proc establishTrust*(s: Session): Result[TrustInput, string] =
  ## [G299] logosd's start step: read, decide, and write the mark before the
  ## revision is used.
  let t = ?readTrust(s)
  let mark = ?readMark(s)
  case ?decide(t, mark)
  of cAccept:
    discard
  of cAdvance:
    ?writeMark(s, t)
  ok(t)

proc writeTrustFile*(s: Session, f: LcnTrustFile): Result[TrustInput, string] =
  ## Offline, under the session lock: the file only; logosd moves the mark at
  ## its next start.
  let bytes = f.encode.valueOr:
    return err(error)
  ?writeAtomic(s.dir, TrustName, bytes)
  ok(TrustInput(file: f, digest: @(blake3(bytes)), present: true))

proc initTrust*(s: Session, development: bool): Result[TrustInput, string] =
  ## [G299] `logosctl init`: revision 1 with the switch off, or revision 2 with
  ## it on, so revision 1 keeps the floor's one content (P6-32); and its mark.
  let f =
    if development:
      LcnTrustFile(revision: FloorRevision + 1, development: true)
    else:
      floorFile()
  let t = ?writeTrustFile(s, f)
  ?writeMark(s, t)
  ok(t)

proc setDevelopment*(s: Session, on: bool): Result[TrustInput, string] =
  ## [D27; G137] `logosctl trust development on|off`: the next revision with
  ## the switch set. Turning it off is a withdrawal.
  let t = ?readTrust(s)
  if t.file.revision == high(uint64):
    return err("the trust file's revision cannot grow")
  writeTrustFile(s, LcnTrustFile(revision: t.file.revision + 1, development: on))

proc reestablish*(s: Session, revision: uint64): Result[TrustInput, string] =
  ## [S4b6-1, a Choice] `logosctl trust reestablish --revision N`: the mark
  ## written from the current file when the owner names its revision.
  let t = ?readTrust(s)
  if revision != t.file.revision:
    return
      err("the trust file is at revision " & $t.file.revision & ", not " & $revision)
  ?writeMark(s, t)
  ok(t)

{.pop.}
