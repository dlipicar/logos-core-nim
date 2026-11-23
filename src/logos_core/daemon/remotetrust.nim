## logosd's remote trust input and its continuity mark (Tier 5 step 5-7a-1;
## DECISIONS G408, G299, G324; RUNTIME §9.3.7 l.2590-2682). docs/DAEMON.md §6a.
##
## `remote/trust.cbor` is `lcn.remote_trust` (`remote_trust.cddl`): the
## complete remote trust-anchor set and the enrollment records, in RUNTIME's
## published schema, under one revision that every offline change raises by
## one (l.2673). `state/remote-trust-mark.cbor` keeps the highest revision
## used, the BLAKE3-256 of that file's bytes, the anchor set, and for each
## enrollment key (`runtime_instance_id`, `profile`) the record accepted, or
## every record of a conflict (l.2664, l.2674). logosd reads neither unless
## `remote.enabled` (G407), so a session without it needs no mark.
##
## | Mark       | File                                    | Decision                         |
## |------------|-----------------------------------------|----------------------------------|
## | absent     | any                                     | refused: re-establish (l.2680)   |
## | revision r | revision > r, the enrollment rules pass | mark written, then used          |
## | revision r | revision = r, same digest               | accepted (identical replay)      |
## | revision r | revision = r, other digest              | refused (l.2675)                 |
## | revision r | revision < r                            | refused (l.2675)                 |
##
## The enrollment rules, per key against the mark (l.2650-2656): a higher
## revision replaces; the same record keeps; a different record at the same
## revision is a conflict, and the start goes on with that identity rejected
## until a later file carries a higher revision for it (l.2653-2654); a lower
## revision is stale and refuses the start, and so does a key the mark holds
## that the file omits. The last two are stricter than the text (G408;
## REMOTE.md gives their cost). A `revoked` record supersedes lower revisions
## and admits no session (l.2655).
##
## logosd never creates a mark (G299): `logosctl remote trust init` writes an
## empty input at revision 1 and its mark together, and `logosctl remote trust
## reestablish --revision N` writes one after loss (l.2680-2682). Every change
## is offline, under the session lock, and applies at the next start (B3):
## `logosctl remote trust` builds the next file with the pure edits below, and
## `commitRemoteTrust` writes it as revision + 1 only when it changes
## something and passes logosd's checks (G397's pattern).

{.push raises: [].}

import std/strutils
import results
import logos_sdk/crypto/blake3
from logos_sdk/cbor import cmpBytes
import ../durable
import ../transport/tls/[p256, trustsnap, x509]
import ./[remote_trust_types, session]

export results, remote_trust_types, trustsnap, directAnchorProblems

const
  MaxRemoteTrustBytes* = 16 * 1024 * 1024
    ## [IMPL] the bound on `remote/trust.cbor`, its mark and a peer file
  RemoteTrustFile* = RemoteName & "/" & TrustName
  RemoteNotEstablished* =
    "remote trust continuity is not established: run logosctl remote trust init " &
    "for a new session, or logosctl remote trust reestablish --revision N after loss"
  AppliesAtNextStart* = "the change applies at the next start of logosd"
  RevokeCloses* = "restarting logosd is what closes that Runtime's connections (B3)"

type
  Enrollment* = LcnEnrollmentRemoteRuntimeEnrollment

  EnrollmentKey* = object ## [SPEC RUNTIME §9.3.7] l.2650
    runtime*: string
    profile*: string

  KeyState* = object
    ## One enrollment key's accepted state: its record, or, in a conflict,
    ## every record at that revision, in encoding order.
    key*: EnrollmentKey
    records*: seq[Enrollment]

  RemoteTrustState* = object ## The remote trust input as read.
    file*: LcnRemoteTrust
    digest*: seq[byte] ## BLAKE3-256 of the file's bytes

  AcceptedRemote* = object ## The state a start uses.
    revision*: uint64
    anchors*: seq[LcnRemoteAnchor]
    keys*: seq[KeyState] ## in key order

  RemoteStart* = object
    ## What a start decided before any mark moves: the state to use, and
    ## whether the mark must be written first.
    state*: RemoteTrustState
    advance*: bool
    accepted*: AcceptedRemote
    snapshot*: TrustSnapshot
    report*: seq[string] ## [G324 extended] the loader report
    conflicts*: seq[string] ## one line per identity a conflict rejects

# Records --------------------------------------------------------------------------------

proc profileText*(p: LcnEnrollmentRemoteIdentityProfile): string =
  ## The profile's text, as its encoding has it.
  toCbor(p).text

proc keyOf*(r: Enrollment): EnrollmentKey =
  case r.kind
  of LcnEnrollmentRemoteRuntimeEnrollmentKind.Active:
    EnrollmentKey(
      runtime: r.arm_Active.runtime_instance_id,
      profile: profileText(r.arm_Active.profile),
    )
  of LcnEnrollmentRemoteRuntimeEnrollmentKind.Revoked:
    EnrollmentKey(
      runtime: r.arm_Revoked.runtime_instance_id,
      profile: profileText(r.arm_Revoked.profile),
    )

func revisionOf*(r: Enrollment): uint64 =
  case r.kind
  of LcnEnrollmentRemoteRuntimeEnrollmentKind.Active: r.arm_Active.revision
  of LcnEnrollmentRemoteRuntimeEnrollmentKind.Revoked: r.arm_Revoked.revision

func active*(r: Enrollment): bool =
  r.kind == LcnEnrollmentRemoteRuntimeEnrollmentKind.Active

func keysOf*(r: Enrollment): seq[seq[byte]] =
  if not r.active:
    return @[]
  case r.arm_Active.subject_public_keys.kind
  of LcnEnrollmentRemoteRuntimeEnrollmentARActiveSubjectPublicKeysChoiceKind.Tuple1:
    @[r.arm_Active.subject_public_keys.arm_Tuple1[0]]
  of LcnEnrollmentRemoteRuntimeEnrollmentARActiveSubjectPublicKeysChoiceKind.Tuple2:
    @[
      r.arm_Active.subject_public_keys.arm_Tuple2[0],
      r.arm_Active.subject_public_keys.arm_Tuple2[1],
    ]

func `$`*(k: EnrollmentKey): string =
  "Runtime " & k.runtime & " (" & k.profile & ")"

func cmpKey(a, b: EnrollmentKey): int =
  ## Byte order of the Runtime id, then of the profile.
  result = cmp(a.runtime, b.runtime)
  if result == 0:
    result = cmp(a.profile, b.profile)

proc recordBytes(r: Enrollment): Result[seq[byte], string] =
  r.encode

proc sameRecord(a, b: Enrollment): Result[bool, string] =
  ok(?recordBytes(a) == ?recordBytes(b))

proc activeRecord*(
    runtime, profile: string,
    revision: uint64,
    anchor: openArray[byte],
    keys: openArray[seq[byte]],
): Result[Enrollment, string] =
  ## An `active` record, checked against the published schema.
  var choice: LcnEnrollmentRemoteRuntimeEnrollmentARActiveSubjectPublicKeysChoice
  case keys.len
  of 1:
    choice = LcnEnrollmentRemoteRuntimeEnrollmentARActiveSubjectPublicKeysChoice(
      kind:
        LcnEnrollmentRemoteRuntimeEnrollmentARActiveSubjectPublicKeysChoiceKind.Tuple1,
      arm_Tuple1: (keys[0],),
    )
  of 2:
    choice = LcnEnrollmentRemoteRuntimeEnrollmentARActiveSubjectPublicKeysChoice(
      kind:
        LcnEnrollmentRemoteRuntimeEnrollmentARActiveSubjectPublicKeysChoiceKind.Tuple2,
      arm_Tuple2: (keys[0], keys[1]),
    )
  else:
    return err("an active record holds one or two keys, not " & $keys.len)
  let p = ?LcnEnrollmentRemoteIdentityProfile.fromCbor(
    CborValue(kind: ckText, text: profile, validUtf8: true)
  )
  let r = Enrollment(
    kind: LcnEnrollmentRemoteRuntimeEnrollmentKind.Active,
    arm_Active: LcnEnrollmentRemoteRuntimeEnrollmentARActiveMap(
      runtime_instance_id: runtime,
      profile: p,
      revision: revision,
      trust_anchor: @anchor,
      subject_public_keys: choice,
    ),
  )
  discard ?r.encode
  ok(r)

proc revokedRecord*(
    runtime, profile: string, revision: uint64
): Result[Enrollment, string] =
  ## A `revoked` record, checked against the published schema.
  let p = ?LcnEnrollmentRemoteIdentityProfile.fromCbor(
    CborValue(kind: ckText, text: profile, validUtf8: true)
  )
  let r = Enrollment(
    kind: LcnEnrollmentRemoteRuntimeEnrollmentKind.Revoked,
    arm_Revoked: LcnEnrollmentRemoteRuntimeEnrollmentARRevokedMap(
      runtime_instance_id: runtime, profile: p, revision: revision
    ),
  )
  discard ?r.encode
  ok(r)

# The file's own rules ---------------------------------------------------------------------

func isRuntimeIdV4*(s: string): bool =
  ## [SPEC RUNTIME §9.3.7] l.2592: a lowercase canonical UUID version 4.
  isRuntimeId(s)

proc checkRecord(r: Enrollment): Result[void, string] =
  let k = keyOf(r)
  if not isRuntimeIdV4(k.runtime):
    return err(
      "the enrollment of " & k.runtime.escape &
        " does not name a lowercase UUID version 4 Runtime id (RUNTIME l.2592)"
    )
  let keys = keysOf(r)
  if keys.len == 2 and keys[0] == keys[1]:
    return err("the enrollment of " & $k & " holds the same key twice")
  ok()

proc checkRemoteTrust*(f: LcnRemoteTrust): Result[void, string] =
  ## [G408] The rules a file meets on its own, beyond the schema: anchor
  ## identifiers distinct; each record names a UUIDv4 Runtime id and distinct
  ## keys; each enrollment key once [IMPL: a conflict arises between the file
  ## and the mark, never within one file].
  for i in 1 ..< f.anchors.len:
    for j in 0 ..< i:
      if f.anchors[i].id == f.anchors[j].id:
        return err("anchor " & anchorName(f.anchors[i].id) & " is listed twice")
  var keys: seq[EnrollmentKey]
  for r in f.enrollments:
    ?checkRecord(r)
    let k = keyOf(r)
    if k in keys:
      return err(
        "the file holds two records for " & $k & "; it holds one per enrollment key"
      )
    keys.add(k)
  ok()

proc stateOf(f: LcnRemoteTrust): Result[RemoteTrustState, string] =
  let bytes = ?f.encode
  ok(RemoteTrustState(file: f, digest: @(blake3(bytes))))

proc decodeRemoteTrust*(bytes: openArray[byte]): Result[RemoteTrustState, string] =
  ## The schema and the bound, no other rule.
  if bytes.len > MaxRemoteTrustBytes:
    return err(RemoteTrustFile & " is larger than 16 MiB")
  let f = LcnRemoteTrust.decode(bytes).valueOr:
    return err(RemoteTrustFile & " is not a remote trust input: " & error)
  ok(RemoteTrustState(file: f, digest: @(blake3(bytes))))

proc readRemoteTrust*(s: Session): Result[Opt[RemoteTrustState], string] =
  ## The input decoded, no rule applied (`remote trust show`); none when absent.
  let bytes = ?readSessionFile(s.remoteTrustPath, MaxRemoteTrustBytes)
  if bytes.isNone:
    return ok(Opt.none(RemoteTrustState))
  ok(Opt.some(?decodeRemoteTrust(bytes.get)))

proc checkedRemoteTrust*(s: Session): Result[RemoteTrustState, string] =
  ## [G408] A start's first read: present, decoded, and every rule of
  ## `checkRemoteTrust`.
  let t = (?readRemoteTrust(s)).valueOr:
    return err(
      "there is no " & RemoteTrustFile & ": remote.enabled needs one; " &
        RemoteNotEstablished
    )
  ?checkRemoteTrust(t.file)
  ok(t)

# The mark -------------------------------------------------------------------------------

proc readRemoteMark*(s: Session): Result[Opt[LcnRemoteTrustMark], string] =
  let bytes = ?readSessionFile(s.remoteTrustMarkPath, MaxRemoteTrustBytes)
  if bytes.isNone:
    return ok(Opt.none(LcnRemoteTrustMark))
  let m = LcnRemoteTrustMark.decode(bytes.get).valueOr:
    return err(RemoteTrustMarkName & " is not a remote trust mark: " & error)
  ok(Opt.some(m))

proc insertKey(keys: var seq[KeyState], r: Enrollment): Result[void, string] =
  ## `r` into its key's place: a new key in key order, or one more record of
  ## the key's conflict, in encoding order.
  let k = keyOf(r)
  var at = 0
  while at < keys.len and cmpKey(keys[at].key, k) < 0:
    inc at
  if at < keys.len and cmpKey(keys[at].key, k) == 0:
    let b = ?recordBytes(r)
    var i = 0
    while i < keys[at].records.len and cmpBytes(?recordBytes(keys[at].records[i]), b) < 0:
      inc i
    keys[at].records.insert(r, i)
  else:
    keys.insert(KeyState(key: k, records: @[r]), at)
  ok()

proc markKeys*(m: LcnRemoteTrustMark): Result[seq[KeyState], string] =
  ## The mark's records by key. A key with several records is a conflict: all
  ## at one revision and all different. Anything else is a damaged mark.
  var keys: seq[KeyState]
  for r in m.enrollments:
    ?checkRecord(r)
    ?keys.insertKey(r)
  for k in keys:
    for i in 1 ..< k.records.len:
      if revisionOf(k.records[i]) != revisionOf(k.records[0]):
        return err(RemoteTrustMarkName & " holds two revisions for " & $k.key)
      if ?sameRecord(k.records[i], k.records[i - 1]):
        return err(RemoteTrustMarkName & " holds one record of " & $k.key & " twice")
  for i in 1 ..< m.anchors.len:
    for j in 0 ..< i:
      if m.anchors[i].id == m.anchors[j].id:
        return err(RemoteTrustMarkName & " lists one anchor twice")
  ok(keys)

func markOf(a: AcceptedRemote, digest: seq[byte]): LcnRemoteTrustMark =
  var records: seq[Enrollment]
  for k in a.keys:
    records.add(k.records)
  LcnRemoteTrustMark(
    revision: a.revision, digest: digest, anchors: a.anchors, enrollments: records
  )

proc writeRemoteMark*(
    s: Session, a: AcceptedRemote, digest: seq[byte]
): Result[void, string] =
  ## Durable before the state is used (RUNTIME l.2674).
  let bytes = ?markOf(a, digest).encode
  writeAtomic(s.stateDir, RemoteTrustMarkName, bytes)

# Continuity and the enrollment rules -----------------------------------------------------

proc fileKeys(f: LcnRemoteTrust): seq[EnrollmentKey] =
  for r in f.enrollments:
    result.add(keyOf(r))

proc fromFile*(t: RemoteTrustState): Result[AcceptedRemote, string] =
  ## The file's own state: each key's one record, as `init` and `reestablish`
  ## take it.
  var keys: seq[KeyState]
  for r in t.file.enrollments:
    ?keys.insertKey(r)
  ok(AcceptedRemote(revision: t.file.revision, anchors: t.file.anchors, keys: keys))

proc merged*(
    f: LcnRemoteTrust, held: openArray[KeyState]
): Result[seq[KeyState], string] =
  ## [SPEC RUNTIME §9.3.7] l.2650-2656 and G408: the state after a file above
  ## the mark, key by key.
  var next: seq[KeyState]
  let present = fileKeys(f)
  for h in held:
    if h.key notin present:
      return err(
        "the file omits " & $h.key & ", which revision " & $revisionOf(h.records[0]) &
          " enrolled; a record is revoked, never removed"
      )
  for r in f.enrollments:
    let k = keyOf(r)
    var found = -1
    for i, h in held:
      if cmpKey(h.key, k) == 0:
        found = i
        break
    if found < 0:
      ?next.insertKey(r)
      continue
    let h = held[found]
    let theirs = revisionOf(h.records[0])
    let ours = revisionOf(r)
    if ours > theirs:
      ?next.insertKey(r)
    elif ours < theirs:
      return err(
        "the file's record of " & $k & " is at revision " & $ours &
          ", below the revision " & $theirs &
          " already accepted: a stale record refuses the start"
      )
    else:
      # The same revision: the same record keeps; a different one conflicts,
      # and every record of the conflict is kept.
      var known = false
      for x in h.records:
        if ?sameRecord(x, r):
          known = true
      for x in h.records:
        ?next.insertKey(x)
      if not known:
        ?next.insertKey(r)
  ok(next)

proc decideRemote*(
    t: RemoteTrustState, mark: Opt[LcnRemoteTrustMark]
): Result[(bool, AcceptedRemote), string] =
  ## [G299; RUNTIME l.2673-2682] The table above: whether the mark advances,
  ## and the state to use.
  if mark.isNone:
    return err(RemoteNotEstablished)
  let m = mark.get
  let held = markKeys(m).valueOr:
    return err(error & "; " & RemoteNotEstablished)
  if t.file.revision > m.revision:
    let keys = ?merged(t.file, held)
    return ok(
      (
        true,
        AcceptedRemote(revision: t.file.revision, anchors: t.file.anchors, keys: keys),
      )
    )
  if t.file.revision == m.revision:
    if t.digest == m.digest:
      return ok(
        (false, AcceptedRemote(revision: m.revision, anchors: m.anchors, keys: held))
      )
    return err(
      "the remote trust input's revision " & $t.file.revision &
        " has other contents than the revision accepted; a changed file needs a higher revision"
    )
  err(
    "the remote trust input's revision " & $t.file.revision & " is below the revision " &
      $m.revision & " already accepted: rollback is refused"
  )

# The snapshot and the loader report ------------------------------------------------------

func heldOf(r: Enrollment, k: EnrollmentKey): HeldRecord =
  if r.active:
    HeldRecord(
      runtime: k.runtime,
      profile: k.profile,
      revision: revisionOf(r),
      status: hsActive,
      anchor: r.arm_Active.trust_anchor,
      keys: keysOf(r),
    )
  else:
    HeldRecord(
      runtime: k.runtime, profile: k.profile, revision: revisionOf(r), status: hsRevoked
    )

proc snapshotOf*(a: AcceptedRemote): Result[TrustSnapshot, string] =
  ## [G408] `transport/tls/trustsnap`'s input from the accepted state.
  var anchors: seq[HeldAnchor]
  for x in a.anchors:
    anchors.add(HeldAnchor(id: x.id, certificate: x.certificate))
  var held: seq[HeldKey]
  for k in a.keys:
    var h: HeldKey
    for r in k.records:
      h.records.add(heldOf(r, k.key))
    held.add(h)
  buildSnapshot(a.revision, anchors, held)

func indexOfAnchor(anchors: openArray[LcnRemoteAnchor], id: openArray[byte]): int =
  for i, a in anchors:
    if a.id == @id:
      return i
  -1

proc remoteReport*(
    anchors: openArray[LcnRemoteAnchor], keys: openArray[KeyState]
): seq[string] =
  ## [G324 extended; plan §3.4] What fails closed in the verifier, for the
  ## owner to fix: (1) a tls-tcp active record whose anchor is not in the set,
  ## or whose anchor's key is not among its keys; (2) a record's key that no
  ## anchor can match, since under a direct anchor only the anchor
  ## certificate's key can; (3) an anchor that cannot be a direct anchor, or
  ## that no record names. Nothing is changed.
  var named: seq[seq[byte]]
  for k in keys:
    for r in k.records:
      if not r.active:
        continue
      named.add(r.arm_Active.trust_anchor)
      if k.key.profile != TlsTcpProfile:
        continue
      let what = $k.key & " revision " & $revisionOf(r)
      let id = r.arm_Active.trust_anchor
      let i = anchors.indexOfAnchor(id)
      if i < 0:
        result.add(
          what & ": its anchor " & anchorName(id) & " is not in the anchor set"
        )
        continue
      let anchorKey = certificateSpki(anchors[i].certificate)
      if anchorKey.isErr:
        continue # (3) reports the anchor
      let held = keysOf(r)
      if anchorKey.get notin held:
        result.add(
          what & ": the key of its anchor " & anchorName(id) & " is not among its keys"
        )
        continue
      for key in held:
        if key != anchorKey.get:
          result.add(
            what & ": its other key matches no anchor; under a direct anchor only " &
              "the anchor certificate's key can"
          )
  for a in anchors:
    let problems = directAnchorProblems(a.certificate)
    if problems.len > 0:
      result.add(
        "anchor " & anchorName(a.id) & " cannot be a direct anchor: " &
          problems.join("; ")
      )
    if a.id notin named:
      result.add("anchor " & anchorName(a.id) & ": no active record names it")

func conflictLines*(keys: openArray[KeyState]): seq[string] =
  for k in keys:
    if k.records.len > 1:
      result.add(
        $k.key & " has " & $k.records.len & " conflicting records at revision " &
          $revisionOf(k.records[0]) &
          ": that identity is rejected until a record at a higher revision resolves it"
      )

# The start ------------------------------------------------------------------------------

proc confirmRemoteTrust*(
    s: Session, seen = Opt.none(seq[byte])
): Result[RemoteStart, string] =
  ## [G299; G408] A start's second read, which writes nothing: the file's
  ## rules, a change since the first read of this start (`seen`, its digest)
  ## refused, continuity and the enrollment rules against the mark, and the
  ## snapshot. `commitRemoteMark` then moves the mark if it must.
  let t = ?checkedRemoteTrust(s)
  if seen.isSome and seen.get != t.digest:
    return err("it changed since the first read of this start")
  let mark = ?readRemoteMark(s)
  let (advance, accepted) = ?decideRemote(t, mark)
  let snapshot = ?snapshotOf(accepted)
  ok(
    RemoteStart(
      state: t,
      advance: advance,
      accepted: accepted,
      snapshot: snapshot,
      report: remoteReport(accepted.anchors, accepted.keys),
      conflicts: conflictLines(accepted.keys),
    )
  )

proc commitRemoteMark*(s: Session, st: RemoteStart): Result[void, string] =
  ## [RUNTIME l.2674] The mark, durably, before the state is used; nothing
  ## when the start replays the revision accepted.
  if not st.advance:
    return ok()
  writeRemoteMark(s, st.accepted, st.state.digest)

proc establishRemoteTrust*(s: Session): Result[RemoteStart, string] =
  ## Both reads and the mark, for a caller with no second input to check
  ## between them.
  let first = ?checkedRemoteTrust(s)
  let st = ?confirmRemoteTrust(s, Opt.some(first.digest))
  ?commitRemoteMark(s, st)
  ok(st)

# The writers (offline, under the session lock) ---------------------------------------------

proc writeRemoteTrustFile*(
    s: Session, f: LcnRemoteTrust
): Result[RemoteTrustState, string] =
  let bytes = ?f.encode
  ensurePrivateDir(s.remoteDir).isOkOr:
    return err(error)
  ?writeAtomic(s.remoteDir, TrustName, bytes)
  ok(RemoteTrustState(file: f, digest: @(blake3(bytes))))

proc initRemoteTrust*(s: Session): Result[RemoteTrustState, string] =
  ## [G299; G408] `logosctl remote trust init`: an empty input at revision 1
  ## and its mark. Refused where either exists: that would roll back.
  if (?readSessionFile(s.remoteTrustPath, MaxRemoteTrustBytes)).isSome:
    return err(RemoteTrustFile & " exists; remote trust init makes only a first one")
  if (?readSessionFile(s.remoteTrustMarkPath, MaxRemoteTrustBytes)).isSome:
    return err(
      "state/" & RemoteTrustMarkName &
        " exists: a remote trust input was accepted here; restore " & RemoteTrustFile &
        ", then run logosctl remote trust reestablish --revision N"
    )
  let t = ?writeRemoteTrustFile(s, LcnRemoteTrust(revision: 1))
  ?writeRemoteMark(s, ?fromFile(t), t.digest)
  ok(t)

type RemoteChange* = object ## What a writer did.
  state*: RemoteTrustState ## the input after it: written, or as it was
  changed*: bool ## false: the edit changed nothing and nothing was written
  report*: seq[string] ## the loader report of that input, as a start gives it
  conflicts*: seq[string]

func anchorIdOf*(certificate: openArray[byte]): seq[byte] =
  ## [IMPL] The identifier `remote trust anchor add` and `remote credential`
  ## give an anchor when none is named: the BLAKE3-256 of its DER.
  @(blake3(certificate))

proc withRemoteAnchor*(
    f: LcnRemoteTrust, a: LcnRemoteAnchor
): Result[LcnRemoteTrust, string] =
  ## [G408; G324] `remote trust anchor add`: a direct anchor, at its place in
  ## identifier order. A certificate that cannot be one is refused up front
  ## (the report's case 3); an identifier already present is refused unless
  ## it is the same anchor, which changes nothing.
  let problems = directAnchorProblems(a.certificate)
  if problems.len > 0:
    return err("the certificate cannot be a direct anchor: " & problems.join("; "))
  let i = f.anchors.indexOfAnchor(a.id)
  if i >= 0:
    if f.anchors[i].certificate == a.certificate:
      return ok(f)
    return err(
      "anchor " & anchorName(a.id) &
        " exists with another certificate; remote trust anchor remove withdraws it first"
    )
  var r = f
  var at = 0
  while at < r.anchors.len and cmpBytes(r.anchors[at].id, a.id) < 0:
    inc at
  r.anchors.insert(a, at)
  ok(r)

func withoutRemoteAnchor*(
    f: LcnRemoteTrust, id: openArray[byte]
): Result[LcnRemoteTrust, string] =
  ## [RUNTIME l.2677] `remote trust anchor remove`: a withdrawal. Records
  ## that name the anchor stay and fail closed (the report's case 1).
  let i = f.anchors.indexOfAnchor(id)
  if i < 0:
    return err("no anchor has the identifier " & anchorName(id))
  var r = f
  r.anchors.delete(i)
  ok(r)

proc withEnrollment*(
    f: LcnRemoteTrust, rec: Enrollment
): Result[LcnRemoteTrust, string] =
  ## [RUNTIME l.2650-2656] `remote trust enroll add`: a new key's record, or
  ## one at a higher revision than the record held. The same record changes
  ## nothing; a lower revision, or another record at the same one, is
  ## refused, so a writer never makes a stale record or a conflict.
  ?checkRecord(rec)
  let k = keyOf(rec)
  var r = f
  for i, x in f.enrollments:
    if cmpKey(keyOf(x), k) != 0:
      continue
    let held = revisionOf(x)
    let given = revisionOf(rec)
    if given > held:
      r.enrollments[i] = rec
      return ok(r)
    if given == held and ?sameRecord(x, rec):
      return ok(f)
    if given == held:
      return err(
        "the record of " & $k & " at revision " & $held &
          " differs from the one held: a change needs revision " & $(held + 1)
      )
    return err(
      "the record of " & $k & " is at revision " & $given & ", below the revision " &
        $held & " held"
    )
  var at = 0
  while at < r.enrollments.len and cmpKey(keyOf(r.enrollments[at]), k) < 0:
    inc at
  r.enrollments.insert(rec, at)
  ok(r)

proc withRevocation*(
    f: LcnRemoteTrust, runtime, profile: string
): Result[LcnRemoteTrust, string] =
  ## [RUNTIME l.2655] `remote trust enroll revoke`: a `revoked` record one
  ## revision above the record held. Already revoked changes nothing.
  let k = EnrollmentKey(runtime: runtime, profile: profile)
  for x in f.enrollments:
    if cmpKey(keyOf(x), k) == 0:
      if not x.active:
        return ok(f)
      if revisionOf(x) == high(uint64):
        return err("the record of " & $k & " cannot take a higher revision")
      return f.withEnrollment(?revokedRecord(runtime, profile, revisionOf(x) + 1))
  err("no record enrolls " & $k)

proc decodePeer*(bytes: openArray[byte]): Result[LcnRemotePeer, string] =
  ## [G408] A peer file, `lcn.remote_peer`.
  if bytes.len > MaxRemoteTrustBytes:
    return err("the peer file is larger than 16 MiB")
  LcnRemotePeer.decode(bytes).mapErr(
    proc(e: string): string =
      "not a peer file: " & e
  )

proc withPeer*(f: LcnRemoteTrust, p: LcnRemotePeer): Result[LcnRemoteTrust, string] =
  ## [G408] `remote trust import FILE`: the peer's anchor and its record, as
  ## one change. An active record must name the anchor it comes with.
  if p.enrollment.active and p.enrollment.arm_Active.trust_anchor != p.anchor.id:
    return err(
      "the peer file's record names anchor " &
        anchorName(p.enrollment.arm_Active.trust_anchor) & ", not its anchor " &
        anchorName(p.anchor.id)
    )
  (?f.withRemoteAnchor(p.anchor)).withEnrollment(p.enrollment)

proc validateRemoteTrust*(
    f: LcnRemoteTrust, mark: Opt[LcnRemoteTrustMark]
): Result[RemoteStart, string] =
  ## [G408; G397's pattern] What logosd's start applies to a file: the schema
  ## and the bound, `checkRemoteTrust`, and, when a mark exists, continuity
  ## and the enrollment rules against it. A writer applies it to what it
  ## writes, so it never writes a file logosd refuses.
  let t = ?decodeRemoteTrust(?f.encode)
  ?checkRemoteTrust(t.file)
  var advance = true
  var accepted: AcceptedRemote
  if mark.isSome:
    (advance, accepted) = ?decideRemote(t, mark)
  else:
    accepted = ?fromFile(t)
  let snapshot = ?snapshotOf(accepted)
  ok(
    RemoteStart(
      state: t,
      advance: advance,
      accepted: accepted,
      snapshot: snapshot,
      report: remoteReport(accepted.anchors, accepted.keys),
      conflicts: conflictLines(accepted.keys),
    )
  )

proc commitRemoteTrust*(
    s: Session, cur: RemoteTrustState, next: LcnRemoteTrust
): Result[RemoteChange, string] =
  ## [G408; G397's pattern] Every writer's last step, under the session lock:
  ## `next` is `cur`'s file with one edit. The same bytes: nothing is
  ## written. Otherwise it is written as revision + 1 if it passes
  ## `validateRemoteTrust` against the mark.
  let mark = ?readRemoteMark(s)
  let nextBytes = ?next.encode
  let curBytes = ?cur.file.encode
  if nextBytes == curBytes:
    var ch = RemoteChange(state: cur, changed: false)
    let now = validateRemoteTrust(cur.file, mark)
    if now.isOk:
      ch.report = now.get.report
      ch.conflicts = now.get.conflicts
    return ok(ch)
  if cur.file.revision == high(uint64):
    return err("the remote trust input's revision cannot grow")
  var f = next
  f.revision = cur.file.revision + 1
  let st = ?validateRemoteTrust(f, mark)
  let written = ?writeRemoteTrustFile(s, f)
  ok(
    RemoteChange(
      state: written, changed: true, report: st.report, conflicts: st.conflicts
    )
  )

proc reestablishRemote*(s: Session, revision: uint64): Result[RemoteStart, string] =
  ## [RUNTIME l.2680-2682] `logosctl remote trust reestablish --revision N`:
  ## after loss of the mark, a new one from the current file, when the owner
  ## names its revision and the file passes logosd's own checks. The file's
  ## records are taken as they are: a conflict the lost mark held is gone.
  let t = (?readRemoteTrust(s)).valueOr:
    return err("there is no " & RemoteTrustFile & " to re-establish from")
  if revision != t.file.revision:
    return err(
      "the remote trust input is at revision " & $t.file.revision & ", not " & $revision
    )
  let st = validateRemoteTrust(t.file, Opt.none(LcnRemoteTrustMark)).valueOr:
    return err(error & "; no mark was written")
  ?writeRemoteMark(s, st.accepted, t.digest)
  ok(st)

{.pop.}
