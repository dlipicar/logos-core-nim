## logosd's package trust file and its continuity (Tier 4b step 4b-6, Tier 5
## step 5-3a-2; DECISIONS G137, G299, G396, G398; D27; decision 11; PACKAGE
## MANAGER l.401-406). docs/DAEMON.md §6.
##
## `trust.cbor` is the package trust file, `lcn.package_trust`
## (`package/trustdoc.nim`): its revision covers the development switch, the
## signing anchors and the catalog and provenance selections. A Tier 4b v1
## file is still read. Without the file the compiled-in floor applies:
## revision 1, switch off, no anchor, nothing selected.
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
import logos_sdk/base/hex
import logos_sdk/crypto/blake3
import ../durable
import ../package/trustdoc
import ./[evkey, session, trust_types]

export results, trustdoc, trust_types

const
  MarkFormat* = "logos-core-nim.trust-mark.v1"
  NotEstablished* =
    "trust continuity is not established; run logosctl trust reestablish --revision N"

type
  TrustFileState* = object ## The trust file in force: the file, or the floor.
    file*: LcnPackageTrust ## [G396] a v1 file as its v2 content
    digest*: seq[byte] ## BLAKE3-256 of the file's bytes, or of the floor's
    present*: bool ## the file exists

  AcceptedTrust* = object ## What a start accepted.
    state*: TrustFileState
    signing*: TrustInput
      ## [G396] the anchors in force, for the Package Manager (step 5-3b)

proc stateOf(f: LcnPackageTrust, present: bool): Result[TrustFileState, string] =
  let bytes = f.encode.valueOr:
    return err(error)
  ok(TrustFileState(file: f, digest: @(blake3(bytes)), present: present))

proc readTrust*(s: Session): Result[TrustFileState, string] =
  ## [G137; G396] The trust file decoded, v2 or v1, or the floor when there
  ## is none. No rule is applied: `trust show`, the deployment of every
  ## offline answer and `daemon config check` read a file the rules refuse.
  let bytes = ?readSessionFile(s.trustPath, MaxTrustBytes)
  if bytes.isNone:
    return stateOf(floorTrust(), false)
  let f = decodeTrust(bytes.get).valueOr:
    return err(TrustName & " is not a trust file: " & error)
  ok(TrustFileState(file: f, digest: @(blake3(bytes.get)), present: true))

proc checkedTrust*(s: Session): Result[TrustFileState, string] =
  ## [G396; G398] `readTrust`, then every rule of `checkTrust`: what both
  ## reads of a start apply.
  let t = ?readTrust(s)
  ?checkTrust(t.file)
  ok(t)

proc readMark*(s: Session): Result[Opt[LcnTrustMark], string] =
  let bytes = ?readSessionFile(s.stateDir / TrustMarkName, MaxTrustBytes)
  if bytes.isNone:
    return ok(Opt.none(LcnTrustMark))
  let m = LcnTrustMark.decode(bytes.get).valueOr:
    return err(TrustMarkName & " is not a trust mark: " & error)
  ok(Opt.some(m))

proc writeMark*(s: Session, t: TrustFileState): Result[void, string] =
  ## Durable before the revision is used (PKG-0419).
  let bytes = LcnTrustMark(revision: t.file.revision, digest: t.digest).encode.valueOr:
    return err(error)
  writeAtomic(s.stateDir, TrustMarkName, bytes)

type Continuity* = enum
  cAccept ## identical replay: the mark stays
  cAdvance ## a higher revision: write the mark, then use it

proc v1FloorDigest(): Result[seq[byte], string] =
  ## The digest a Tier 4b session's mark holds for the v1 floor.
  let bytes = ?LcnTrustFile(revision: FloorRevision, development: false).encode
  ok(@(blake3(bytes)))

proc decide*(t: TrustFileState, mark: Opt[LcnTrustMark]): Result[Continuity, string] =
  ## [PKG-0418 to PKG-0421; G299] The table above. Without a file at the
  ## revision of a mark that holds the v1 floor's digest, the refusal names
  ## the fix [I114; Q15].
  if mark.isNone:
    return err(NotEstablished)
  let m = mark.get
  if t.file.revision > m.revision:
    return ok(cAdvance)
  if t.file.revision == m.revision:
    if t.digest == m.digest:
      return ok(cAccept)
    let changed =
      "the trust file's revision " & $t.file.revision &
      " has other contents than the revision recorded"
    if not t.present and m.revision == FloorRevision and m.digest == ?v1FloorDigest():
      return err(
        changed & ": there is no " & TrustName &
          " and the mark holds the Tier 4b floor; run logosctl trust reestablish --revision 1"
      )
    return err(changed & "; a changed file needs a higher revision")
  err(
    "the trust file's revision " & $t.file.revision & " is below the revision " &
      $m.revision & " already used: rollback is refused"
  )

proc sessionEvidenceKeys*(
    s: Session, keyFile = "", kid: openArray[byte] = []
): Result[seq[seq[byte]], string] =
  ## [G397] The public key of every evidence-key binding under `keys/`,
  ## retired ones included (a retired binding keeps its public key), and of
  ## the binding beside the configured key file `keyFile` with `kid`, which
  ## may live elsewhere.
  var keys: seq[seq[byte]]
  for k in ?listEvidenceKeys(s.keysDir):
    keys.add(k.binding.public_key)
  if keyFile.len > 0:
    keys.add((?readBinding(keyFile.parentDir / bindingFileName(kid))).public_key)
  ok(keys)

func separateKeys*(
    t: LcnPackageTrust, evidenceKeys: openArray[seq[byte]]
): Result[void, string] =
  ## [G397; PM l.533, CA l.1309-1312] No anchor, in force or not, uses a key
  ## of the session's call evidence.
  for a in t.signing.anchors:
    if a.public_key in evidenceKeys:
      return err(
        "the key of kid " & a.kid.toHex &
          " is a call-evidence key of this session; a package-signing key is used for nothing else"
      )
  ok()

proc establishTrust*(
    s: Session, evidenceKeys: seq[seq[byte]] = @[], seen = Opt.none(seq[byte])
): Result[AcceptedTrust, string] =
  ## [G299; G396] logosd's start step, in order: read and decode, every rule
  ## of `checkTrust`, key separation against `evidenceKeys`, the conversion,
  ## a change since the first read of this start (`seen`, its digest)
  ## refused, then continuity, and the mark written before the revision is
  ## used. Nothing can fail after the mark moved.
  let t = ?checkedTrust(s)
  ?separateKeys(t.file, evidenceKeys)
  let signing = ?acceptedSigning(t.file)
  if seen.isSome and seen.get != t.digest:
    return err("it changed since the first read of this start")
  let mark = ?readMark(s)
  case ?decide(t, mark)
  of cAccept:
    discard
  of cAdvance:
    ?writeMark(s, t)
  ok(AcceptedTrust(state: t, signing: signing))

proc writeTrustFile*(s: Session, f: LcnPackageTrust): Result[TrustFileState, string] =
  ## Offline, under the session lock: the file only, always v2; logosd moves
  ## the mark at its next start.
  let bytes = f.encode.valueOr:
    return err(error)
  ?writeAtomic(s.dir, TrustName, bytes)
  ok(TrustFileState(file: f, digest: @(blake3(bytes)), present: true))

proc initTrust*(s: Session, development: bool): Result[TrustFileState, string] =
  ## [G299] `logosctl init`: the floor at revision 1 with the switch off, or
  ## revision 2 with it on, so revision 1 keeps the floor's one content
  ## (P6-32); and its mark.
  var f = floorTrust()
  if development:
    f.revision = FloorRevision + 1
    f.development = true
  let t = ?writeTrustFile(s, f)
  ?writeMark(s, t)
  ok(t)

proc setDevelopment*(s: Session, on: bool): Result[TrustFileState, string] =
  ## [D27; G137] `logosctl trust development on|off`: the next revision with
  ## the switch set, everything else kept. Turning it off is a withdrawal,
  ## of the development anchors too.
  let t = ?readTrust(s)
  if t.file.revision == high(uint64):
    return err("the trust file's revision cannot grow")
  var f = t.file
  f.revision = t.file.revision + 1
  f.development = on
  writeTrustFile(s, f)

proc reestablish*(s: Session, revision: uint64): Result[TrustFileState, string] =
  ## [S4b6-1, a Choice] `logosctl trust reestablish --revision N`: the mark
  ## written from the current file when the owner names its revision.
  let t = ?readTrust(s)
  if revision != t.file.revision:
    return
      err("the trust file is at revision " & $t.file.revision & ", not " & $revision)
  ?writeMark(s, t)
  ok(t)

{.pop.}
