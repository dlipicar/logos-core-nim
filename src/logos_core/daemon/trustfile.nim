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
## when the owner names the file's revision and the file passes logosd's
## checks. Every change is offline, under the session lock, and applies at the
## next start (BCP l.359, l.364): `logosctl trust` builds the next file with
## the pure edits below, and `commitTrust` writes it as revision + 1 only
## when it changes something and passes logosd's checks (G397).

{.push raises: [].}

import std/[algorithm, os, sequtils, strutils]
import results
import logos_sdk/base/hex
import logos_sdk/crypto/blake3
from logos_sdk/cbor import cmpBytes
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

proc startEvidenceKeys*(
    s: Session, t: TrustFileState, keyFile = "", kid: openArray[byte] = []
): Result[seq[seq[byte]], string] =
  ## [G397] What key separation compares at a start whose first read gave
  ## `t`: nothing when the file names no anchor, so a session without anchors
  ## never reads its bindings for it; otherwise `sessionEvidenceKeys`, and a
  ## binding that cannot be read refuses the start (fail closed). A file that
  ## gains an anchor after the first read is refused as changed since then.
  if t.file.signing.anchors.len == 0:
    return ok(newSeq[seq[byte]]())
  sessionEvidenceKeys(s, keyFile, kid)

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

# The writers (G397) ------------------------------------------------------------------

const CorrectByHand* =
  "correct " & TrustName &
  " by hand, then run a trust change or logosctl trust reestablish --revision N"
  ## [G397; Q17] What a writer adds when the file it starts from is refused.

type TrustChange* = object ## What a writer did.
  state*: TrustFileState ## the file in force after it: written, or as it was
  changed*: bool ## false: the change changed nothing and nothing was written

func indexOfKid(f: LcnPackageTrust, kid: openArray[byte]): int =
  for i, a in f.signing.anchors:
    if a.kid == @kid:
      return i
  -1

func checkKid(kid: openArray[byte]): Result[void, string] =
  if kid.len notin 1 .. 128:
    return err("a kid is 1 to 128 bytes, not " & $kid.len)
  ok()

func canonicalNames(names: openArray[string]): Result[seq[string], string] =
  ## [G396] Each name once, in strictly ascending byte order; a name is 1 to
  ## 128 bytes (PM l.242) and taken as given, never folded (PM l.418-419).
  var r: seq[string]
  for n in names:
    if n.len notin 1 .. 128:
      return err(
        "the package name " & n.escape & " is " & $n.len &
          " bytes; a package name is 1 to 128 bytes"
      )
    r.add(n)
  r.sort(system.cmp[string])
  r = deduplicate(r, isSorted = true)
  ok(r)

func absentKid(kid: openArray[byte]): string =
  "no anchor has kid " & kid.toHex

func unknownKid(kid: openArray[byte]): string =
  absentKid(kid) & "; trust anchor add adds one"

func withAnchor*(
    f: LcnPackageTrust, a: LcnTrustAnchor
): Result[LcnPackageTrust, string] =
  ## [G397] `trust anchor add`: a new anchor, its names in canonical order,
  ## at its place in kid order. A kid already present is refused (PKG-0107),
  ## unless the anchor is the same one, which changes nothing.
  ?checkKid(a.kid)
  var a = a
  a.packages = ?canonicalNames(a.packages)
  if a.packages.len == 0:
    return err("an anchor names at least one package (PM l.417)")
  let i = f.indexOfKid(a.kid)
  if i >= 0:
    if f.signing.anchors[i] == a:
      return ok(f)
    return err(
      "kid " & a.kid.toHex &
        " is already an anchor; trust anchor add-names adds names to it, and a new key or marker needs trust anchor remove first"
    )
  var r = f
  var at = 0
  while at < r.signing.anchors.len and cmpBytes(r.signing.anchors[at].kid, a.kid) < 0:
    inc at
  r.signing.anchors.insert(a, at)
  ok(r)

func withoutAnchor*(
    f: LcnPackageTrust, kid: openArray[byte]
): Result[LcnPackageTrust, string] =
  ## [G397; PM l.436-437] `trust anchor remove`: a withdrawal. A kid that
  ## names no anchor is refused: withdrawing what is not there withdraws
  ## nothing, and a mistyped kid must not pass for a withdrawal.
  let i = f.indexOfKid(kid)
  if i < 0:
    return err(absentKid(kid))
  var r = f
  r.signing.anchors.delete(i)
  ok(r)

func withNames*(
    f: LcnPackageTrust, kid: openArray[byte], names: openArray[string]
): Result[LcnPackageTrust, string] =
  ## [G397; PM l.420] `trust anchor add-names`: one added name is a change,
  ## so a new revision. Names already present change nothing.
  let i = f.indexOfKid(kid)
  if i < 0:
    return err(unknownKid(kid))
  var r = f
  r.signing.anchors[i].packages =
    ?canonicalNames(r.signing.anchors[i].packages & @names)
  ok(r)

func withoutNames*(
    f: LcnPackageTrust, kid: openArray[byte], names: openArray[string]
): Result[LcnPackageTrust, string] =
  ## [G397; PM l.417] `trust anchor remove-names`, all or nothing: a name
  ## the anchor does not authorize, compared byte for byte (PM l.418-419), is
  ## refused with every such name, and nothing is removed; leaving the anchor
  ## no name is refused.
  let i = f.indexOfKid(kid)
  if i < 0:
    return err(absentKid(kid))
  var absent: seq[string]
  for n in names:
    if n notin f.signing.anchors[i].packages and n.escape notin absent:
      absent.add(n.escape)
  if absent.len > 0:
    return err(
      "kid " & kid.toHex & " authorizes no package named " & absent.join(", ") &
        "; no name was removed"
    )
  var r = f
  var kept: seq[string]
  for n in r.signing.anchors[i].packages:
    if n notin names:
      kept.add(n)
  if kept.len == 0:
    return err(
      "kid " & kid.toHex &
        " would authorize no package name; trust anchor remove withdraws the anchor"
    )
  r.signing.anchors[i].packages = kept
  ok(r)

func withDevelopment*(f: LcnPackageTrust, on: bool): LcnPackageTrust =
  ## [D27; G137] `trust development on|off`. Turning the switch off is a
  ## withdrawal, of the development anchors too (PM l.409).
  result = f
  result.development = on

proc validateTrust*(
    f: LcnPackageTrust, evidenceKeys: openArray[seq[byte]]
): Result[TrustInput, string] =
  ## [G396; G397] What logosd's start applies to a file before continuity:
  ## the schema and the 1 MiB bound, every rule of `checkTrust`, key
  ## separation and the conversion. A writer applies it to what it writes, so
  ## it never writes a file logosd refuses.
  let bytes = ?f.encode
  let d = ?decodeTrust(bytes)
  ?checkTrust(d)
  ?separateKeys(d, evidenceKeys)
  acceptedSigning(d)

proc commitTrust*(
    s: Session, cur: TrustFileState, next: LcnPackageTrust, evidenceKeys: seq[seq[byte]]
): Result[TrustChange, string] =
  ## [G397; Q16, Q17] Every writer's last step, under the session lock: `next`
  ## is `cur`'s file with one edit. Equal to it, nothing is written. Otherwise
  ## it is written as revision + 1, always v2, if it passes `validateTrust`
  ## against `evidenceKeys` (the session's, read when either file names an
  ## anchor). A refusal that `cur` itself already earns, a hand-set selection
  ## for one, says to correct the file by hand.
  let now = validateTrust(cur.file, evidenceKeys)
  proc refusal(e: string): string =
    if now.isErr:
      e & "; " & CorrectByHand
    else:
      e

  if next == cur.file:
    if now.isErr:
      return err(refusal(now.error))
    return ok(TrustChange(state: cur, changed: false))
  if cur.file.revision == high(uint64):
    return err("the trust file's revision cannot grow")
  var f = next
  f.revision = cur.file.revision + 1
  discard validateTrust(f, evidenceKeys).valueOr:
    return err(refusal(error))
  let written = ?writeTrustFile(s, f)
  ok(TrustChange(state: written, changed: true))

proc reestablish*(
    s: Session, revision: uint64, evidenceKeys: seq[seq[byte]]
): Result[TrustFileState, string] =
  ## [S4b6-1, a Choice; G397] `logosctl trust reestablish --revision N`: the
  ## mark written from the current file when the owner names its revision and
  ## the file passes `validateTrust`, so the mark never names a revision
  ## logosd refuses.
  let t = ?readTrust(s)
  if revision != t.file.revision:
    return
      err("the trust file is at revision " & $t.file.revision & ", not " & $revision)
  discard validateTrust(t.file, evidenceKeys).valueOr:
    return err(error & "; no mark was written")
  ?writeMark(s, t)
  ok(t)

{.pop.}
