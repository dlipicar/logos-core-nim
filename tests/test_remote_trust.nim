## logosd's remote trust input and its continuity mark (Tier 5 step 5-7a-1;
## DECISIONS G408, G299, G324; RUNTIME §9.3.7 l.2590-2682; docs/DAEMON.md
## §6a). In-process: the CDDL and its derivation from the mirror, the start
## table, the enrollment rules, the loader report, the writers and the
## snapshot. As processes: logosd's start with and without `remote.enabled`,
## and `logosctl remote trust` under the session lock.

when defined(posix):
  import std/[json, os, sequtils, strutils, times]
  import unittest2
  import logos_sdk/cbor
  import
    ../src/logos_core/daemon/
      [config, daemon_config_types, remotetrust, session, sessioninit]
  import ../src/logos_core/transport/tls/p256
  from ../src/logos_core/durable import ensurePrivateDir, removeIfPresent, writeAtomic
  import ./support/[daemonbuild, daemonproc, genfixtures_core, shortdir, slowdown]
  from logos_sdk/testing/kitbuild import kitVariant

  import std/posix

  const
    IdA = "0b6f3c3e-9d0f-4c1a-8f43-7a8f2b9b1a01"
    IdB = "5d2e8c71-3a4b-4e6f-9a1b-2c3d4e5f6a02"
    IdC = "9e8d7c6b-5a49-4382-b170-6f5e4d3c2b03"
    Quic = "logos.remote.quic"
    Ku = "critical,digitalSignature"
    ReadyMs = 120_000 * Slow
    StopMs = 60_000 * Slow

  type Peer = object
    id: string
    key: P256Key
    cert: seq[byte]
    spki: seq[byte]

  proc newPeer(id: string, keyUsage = Ku, extendedKeyUsage = ""): Peer =
    let now = getTime().toUnix()
    let key = newP256Key().get
    let cert = key.selfSignedCertificate(
      CertificateOptions(
        commonName: id,
        notBefore: now - 3600,
        notAfter: now + 365 * 86400,
        keyUsage: keyUsage,
        extendedKeyUsage: extendedKeyUsage,
      )
    ).get
    Peer(id: id, key: key, cert: cert, spki: key.spkiDer().get)

  proc textOf(b: openArray[byte]): string =
    ## The bytes as a string, copied (a cast would alias the seq's payload).
    result = newString(b.len)
    if b.len > 0:
      copyMem(addr result[0], unsafeAddr b[0], b.len)

  proc anchor(p: Peer): LcnRemoteAnchor =
    LcnRemoteAnchor(id: anchorIdOf(p.cert), certificate: p.cert)

  proc active(
      p: Peer, revision: uint64, keys: seq[seq[byte]] = @[], profile = TlsTcpProfile
  ): Enrollment =
    activeRecord(
      p.id,
      profile,
      revision,
      anchorIdOf(p.cert),
      (if keys.len > 0: keys else: @[p.spki]),
    ).get

  proc revoked(p: Peer, revision: uint64): Enrollment =
    revokedRecord(p.id, TlsTcpProfile, revision).get

  let
    a = newPeer(IdA)
    b = newPeer(IdB)
    c3 = newPeer(IdC)

  let work =
    currentSourcePath().parentDir.parentDir / "build" / "remote-trust" / kitVariant
  removeDir(work)
  createDir(work)
  var sessions = 0

  proc newSession(): Session =
    inc sessions
    result = Session(dir: work / ("s" & $sessions))
    check createLayout(result).isOk

  proc put(
      s: Session,
      revision: uint64,
      anchors: seq[LcnRemoteAnchor],
      records: seq[Enrollment],
  ) =
    check writeRemoteTrustFile(
      s, LcnRemoteTrust(revision: revision, anchors: anchors, enrollments: records)
    ).isOk

  proc markText(s: Session): string =
    try:
      readFile(s.remoteTrustMarkPath)
    except IOError:
      ""

  proc started(s: Session): RemoteStart =
    let r = establishRemoteTrust(s)
    if r.isErr:
      checkpoint(r.error)
      fail()
      return
    r.get

  proc refused(s: Session, part: string): bool =
    ## The start is refused naming `part`, and the mark is left as it was.
    let before = markText(s)
    let r = establishRemoteTrust(s)
    if r.isOk:
      checkpoint("the start was accepted")
      return false
    if part notin r.error:
      checkpoint(r.error)
      return false
    markText(s) == before

  suite "remote.trust: the input, the mark and the start table [IMPL-DECISION G408]":
    test "[IMPL-DECISION G408] the input's CDDL is closed; its records are RUNTIME's §9.3.7 schema, generated from the mirror, and one written by hand reads unchanged":
      let extra = parseDiag(
        """{"format": "logos-core-nim.remote-trust.v1", "revision": 1, "anchors": [], "enrollments": [], "nodes": []}"""
      ).get
      check decodeRemoteTrust(encodeCbor(extra)).isErr
      let otherFormat = parseDiag(
        """{"format": "logos-core-nim.remote-trust.v2", "revision": 1, "anchors": [], "enrollments": []}"""
      ).get
      check decodeRemoteTrust(encodeCbor(otherFormat)).isErr
      # The records' rules are the mirror's text with only the names changed.
      let mirrored = enrollmentRules(readFile(repoDir / remoteEnrollmentMirror))
      check remoteTrustDocuments()[0].endsWith(mirrored)
      check "logos.runtime_enrollment." notin mirrored
      # A record as another implementation writes it, in diagnostic notation.
      let hand = parseDiag(
        "{\"runtime_instance_id\": \"" & IdA &
          "\", \"profile\": \"logos.remote.tls-tcp\", \"revision\": 3, \"status\": \"active\", " &
          "\"trust_anchor\": h'0102', \"subject_public_keys\": [h'" & anchorName(a.spki) &
          "']}"
      ).get
      let bytes = encodeCbor(hand)
      let rec = Enrollment.decode(bytes).expect("a published record")
      check rec.encode.get == bytes
      check keyOf(rec) == EnrollmentKey(runtime: IdA, profile: TlsTcpProfile)
      check revisionOf(rec) == 3 and keysOf(rec) == @[a.spki]
      # Unknown fields are refused in a record too (the schema is closed).
      let more = parseDiag(
        "{\"runtime_instance_id\": \"" & IdA &
          "\", \"profile\": \"logos.remote.tls-tcp\", \"revision\": 3, \"status\": \"revoked\", \"note\": 1}"
      ).get
      check Enrollment.decode(encodeCbor(more)).isErr

    test "[RUN-0497] [RUN-0498] [RUN-0499] [RUN-0500] [IMPL-DECISION G299] [IMPL-DECISION G408] every row of the start table, with the mark unchanged where the start is refused; a withdrawal by a higher revision; mark loss, init and reestablish":
      let s = newSession()
      # No mark: refused, whatever the file.
      s.put(1, @[], @[])
      check s.refused("not established")
      check markText(s) == ""
      check removeIfPresent(s.remoteTrustPath).isOk
      # init: an empty input at revision 1 and its mark.
      check initRemoteTrust(s).isOk
      check initRemoteTrust(s).error.contains("exists")
      var st = s.started
      check st.accepted.revision == 1 and not st.advance
      # A higher revision: the mark moves before use.
      s.put(2, @[a.anchor], @[a.active(1)])
      st = s.started
      check st.advance and st.accepted.revision == 2
      let mark2 = markText(s)
      let m = readRemoteMark(s).get.get
      check m.revision == 2 and m.anchors == @[a.anchor] and m.enrollments.len == 1
      # The same revision with other contents, and a lower revision: refused.
      s.put(2, @[], @[a.active(1)])
      check s.refused("other contents")
      s.put(1, @[a.anchor], @[a.active(1)])
      check s.refused("rollback")
      # The identical replay: accepted, and nothing is written.
      s.put(2, @[a.anchor], @[a.active(1)])
      st = s.started
      check not st.advance and markText(s) == mark2
      # A higher revision with the same set is allowed (l.2673-2676).
      s.put(3, @[a.anchor], @[a.active(1)])
      check s.started.advance
      # Withdrawal: a higher revision whose set omits the anchor (l.2677); the
      # record that names it is held and reported.
      s.put(4, @[], @[a.active(1)])
      st = s.started
      check st.accepted.anchors.len == 0
      check st.report.anyIt(it.contains("is not in the anchor set"))
      check st.snapshot.anchorCount == 0
      check st.snapshot.record(IdA).get.status == rsActive
      # Mark loss (l.2680-2682): refused until re-established; init refuses to
      # roll back over the file.
      check removeIfPresent(s.remoteTrustMarkPath).isOk
      check s.refused("not established")
      check initRemoteTrust(s).isErr
      check reestablishRemote(s, 3).error.contains("revision 4, not 3")
      check markText(s) == ""
      check reestablishRemote(s, 4).isOk
      st = s.started
      check not st.advance and st.accepted.revision == 4
      # init also refuses when only the mark is left.
      check removeIfPresent(s.remoteTrustPath).isOk
      check initRemoteTrust(s).error.contains("reestablish")
      check s.refused("there is no")

    test "[RUN-0494] [RUN-0495] [IMPL-DECISION G408] the enrollment rules per key: a higher revision replaces, a stale record refuses the whole start, a conflict rejects that identity while the start goes on, an omitted key refuses the start, and revoked supersedes":
      let s = newSession()
      check initRemoteTrust(s).isOk
      let anchors = @[a.anchor, b.anchor]
      s.put(2, anchors, @[a.active(1), b.active(1)])
      check s.started.snapshot.record(IdA).get.revision == 1
      s.put(3, anchors, @[a.active(2), b.active(1)])
      check s.started.snapshot.record(IdA).get.revision == 2
      # Stale: refused as a whole, though B's record is fine.
      s.put(4, anchors, @[a.active(1), b.active(1)])
      check s.refused("stale record")
      # A conflict: another record of A at revision 2. The start goes on; A is
      # rejected, B stays usable.
      let other = a.active(2, @[a.spki, c3.spki])
      s.put(4, anchors, @[other, b.active(1)])
      var st = s.started
      check st.conflicts.len == 1 and st.conflicts[0].contains("Runtime " & IdA)
      check st.snapshot.record(IdA).get.status == rsConflicting
      check c3.spki in st.snapshot.record(IdA).get.spkis
      check st.snapshot.record(IdB).get.status == rsActive
      check readRemoteMark(s).get.get.enrollments.len == 3
      # The conflict holds across a replay and a higher file revision that
      # carries one of its records.
      check s.started.snapshot.record(IdA).get.status == rsConflicting
      s.put(5, anchors, @[a.active(2), b.active(1)])
      check s.started.snapshot.record(IdA).get.status == rsConflicting
      # A higher revision for the key resolves it.
      s.put(6, anchors, @[a.active(3), b.active(1)])
      st = s.started
      check st.conflicts.len == 0 and st.snapshot.record(IdA).get.status == rsActive
      # A key the mark holds that the file omits refuses the start.
      s.put(7, anchors, @[a.active(3)])
      check s.refused("omits Runtime " & IdB)
      # Revoked supersedes lower revisions and admits no session (l.2655).
      s.put(7, anchors, @[a.active(3), b.revoked(2)])
      check s.started.snapshot.record(IdB).get.status == rsRevoked
      s.put(8, anchors, @[a.active(3), b.active(1)])
      check s.refused("stale record")
      # Another profile's record is a key of its own; the snapshot has none of it.
      s.put(8, anchors, @[a.active(3), a.active(1, profile = Quic), b.revoked(2)])
      st = s.started
      check st.accepted.keys.len == 3
      check st.snapshot.recordCount == 2

    test "[RUN-0869] [RUN-0493] [TRN-0217] [IMPL-DECISION G408] only the session's own protected files carry enrollment and trust: a file group or other may access, a link, or a change between a start's two reads is refused":
      let s = newSession()
      check initRemoteTrust(s).isOk
      check chmod(cstring(s.remoteTrustPath), 0o644) == 0
      check checkedRemoteTrust(s).error.contains("group or other")
      check chmod(cstring(s.remoteTrustPath), 0o600) == 0
      check chmod(cstring(s.remoteTrustMarkPath), 0o640) == 0
      check s.refused("group or other")
      check chmod(cstring(s.remoteTrustMarkPath), 0o600) == 0
      let moved = s.dir / "elsewhere.cbor"
      moveFile(s.remoteTrustPath, moved)
      createSymlink(moved, s.remoteTrustPath)
      check checkedRemoteTrust(s).error.contains("not a regular file")
      check removeIfPresent(s.remoteTrustPath).isOk
      moveFile(moved, s.remoteTrustPath)
      let first = checkedRemoteTrust(s).get
      s.put(2, @[a.anchor], @[a.active(1)])
      check confirmRemoteTrust(s, Opt.some(first.digest)).error.contains(
        "changed since the first read"
      )
      # A record must name a lowercase UUIDv4 Runtime (l.2592).
      let upper = activeRecord(
        IdA.toUpperAscii, TlsTcpProfile, 1, anchorIdOf(a.cert), [a.spki]
      ).get
      s.put(2, @[a.anchor], @[upper])
      check s.refused("UUID version 4")
      s.put(2, @[a.anchor], @[a.active(1), a.active(2)])
      check s.refused("two records")

    test "[IMPL-DECISION G324] [IMPL-DECISION G408] the loader report: an anchor whose key a record does not hold, a key no anchor can match, and an anchor that cannot be a direct anchor or that no record names":
      let serverOnly = newPeer(IdC, extendedKeyUsage = "serverAuth")
      let noSign = newPeer(IdC, keyUsage = "critical,keyEncipherment")
      let unused = newPeer(IdB)
      let anchors =
        @[a.anchor, b.anchor, serverOnly.anchor, noSign.anchor, unused.anchor]
      let keys = @[
        KeyState(
          key: EnrollmentKey(runtime: IdA, profile: TlsTcpProfile),
          records: @[a.active(1, @[a.spki, c3.spki])],
        ),
        KeyState(
          key: EnrollmentKey(runtime: IdB, profile: TlsTcpProfile),
          records:
            @[activeRecord(IdB, TlsTcpProfile, 1, anchorIdOf(b.cert), [c3.spki]).get],
        ),
      ]
      let report = remoteReport(anchors, keys)
      check report.anyIt(it.contains("Runtime " & IdA) and it.contains("other key"))
      check report.anyIt(
        it.contains("Runtime " & IdB) and it.contains("not among its keys")
      )
      let sid = anchorName(anchorIdOf(serverOnly.cert))
      check report.anyIt(
        it.startsWith("anchor " & sid) and it.contains("lacks clientAuth")
      )
      let nid = anchorName(anchorIdOf(noSign.cert))
      check report.anyIt(
        it.startsWith("anchor " & nid) and
          it.contains("does not permit digital signatures")
      )
      check report.anyIt(
        it ==
          "anchor " & anchorName(anchorIdOf(unused.cert)) & ": no active record names it"
      )
      check not report.anyIt(it.startsWith("anchor " & anchorName(anchorIdOf(a.cert))))
      # anchor add refuses case 3 up front.
      check LcnRemoteTrust().withRemoteAnchor(serverOnly.anchor).error.contains(
        "cannot be a direct anchor"
      )
      check LcnRemoteTrust()
        .withRemoteAnchor(LcnRemoteAnchor(id: @[1'u8], certificate: @[1'u8, 2, 3])).isErr

    test "[IMPL-DECISION G408] the writers: each change is written as revision + 1 only when it changes something and logosd would accept it; refusals write nothing":
      let s = newSession()
      check initRemoteTrust(s).isOk
      proc commit(next: Result[LcnRemoteTrust, string]): Result[RemoteChange, string] =
        let cur = readRemoteTrust(s).get.get
        commitRemoteTrust(s, cur, ?next)

      proc file(): LcnRemoteTrust =
        readRemoteTrust(s).get.get.file

      var ch = commit(file().withRemoteAnchor(a.anchor)).get
      check ch.changed and ch.state.file.revision == 2
      check ch.report.anyIt(it.contains("no active record names it"))
      check not commit(file().withRemoteAnchor(a.anchor)).get.changed
      check commit(
        file().withRemoteAnchor(
          LcnRemoteAnchor(id: anchorIdOf(a.cert), certificate: b.cert)
        )
      ).error
        .contains("another certificate")
      check commit(file().withoutRemoteAnchor(anchorIdOf(b.cert))).error.contains(
        "no anchor"
      )
      ch = commit(file().withEnrollment(a.active(1))).get
      check ch.changed and ch.state.file.revision == 3 and ch.report.len == 0
      check not commit(file().withEnrollment(a.active(1))).get.changed
      check commit(file().withEnrollment(a.active(1, @[a.spki, b.spki]))).error.contains(
        "needs revision 2"
      )
      check commit(file().withEnrollment(a.active(0))).error.contains(
        "below the revision"
      )
      check commit(file().withEnrollment(a.active(2, @[a.spki, b.spki]))).get.changed
      ch = commit(file().withRevocation(IdA, TlsTcpProfile)).get
      check ch.changed and revisionOf(ch.state.file.enrollments[0]) == 3
      check not ch.state.file.enrollments[0].active
      check not commit(file().withRevocation(IdA, TlsTcpProfile)).get.changed
      check commit(file().withRevocation(IdB, TlsTcpProfile)).error.contains(
        "no record"
      )
      # A peer file: its record must name the anchor it comes with.
      var peer = LcnRemotePeer(anchor: b.anchor, enrollment: b.active(1))
      check commit(file().withPeer(peer)).get.changed
      peer.anchor = c3.anchor
      check commit(file().withPeer(peer)).error.contains("names anchor")
      # A file the mark would refuse is never written: here, a mark already
      # past the revision the writer would write.
      check s.started.accepted.revision == 6
      var m = readRemoteMark(s).get.get
      m.revision = 9
      check writeAtomic(s.stateDir, RemoteTrustMarkName, m.encode.get).isOk
      let before = readFile(s.remoteTrustPath)
      check commit(file().withoutRemoteAnchor(anchorIdOf(a.cert))).error.contains(
        "rollback"
      )
      check readFile(s.remoteTrustPath) == before

    test "[IMPL-DECISION I99] [IMPL-DECISION G408] the snapshot: every anchor by its hex id at the set's revision, the tls-tcp keys only, a conflict holding every key either record names":
      let anchors = @[
        HeldAnchor(id: anchorIdOf(a.cert), certificate: a.cert),
        HeldAnchor(id: anchorIdOf(b.cert), certificate: b.cert),
      ]
      let held = @[
        HeldKey(
          records: @[
            HeldRecord(
              runtime: IdA,
              profile: TlsTcpProfile,
              revision: 2,
              status: hsActive,
              anchor: anchorIdOf(a.cert),
              keys: @[a.spki],
            ),
            HeldRecord(
              runtime: IdA,
              profile: TlsTcpProfile,
              revision: 2,
              status: hsActive,
              anchor: anchorIdOf(a.cert),
              keys: @[a.spki, c3.spki],
            ),
          ]
        ),
        HeldKey(
          records: @[
            HeldRecord(
              runtime: IdB,
              profile: TlsTcpProfile,
              revision: 1,
              status: hsActive,
              anchor: anchorIdOf(b.cert),
              keys: @[b.spki],
            )
          ]
        ),
        HeldKey(
          records:
            @[HeldRecord(runtime: IdC, profile: Quic, revision: 1, status: hsRevoked)]
        ),
      ]
      let snap = buildSnapshot(7, anchors, held).get
      check snap.anchorRevision == 7 and snap.anchorCount == 2
      check snap.anchor(anchorName(anchorIdOf(b.cert))).get == b.cert
      check snap.recordCount == 2 and snap.record(IdC).isNone
      let conflict = snap.record(IdA).get
      check conflict.status == rsConflicting and conflict.spkis == @[a.spki, c3.spki]
      check snap.holdersOf(c3.spki).len == 1
      let one = snap.record(IdB).get
      check one.status == rsActive and one.anchor == anchorName(anchorIdOf(b.cert))
      check anchorName([0x0a'u8, 0xff]) == "0aff"

  # As processes ---------------------------------------------------------------------------

  let
    dExe = logosdProgram()
    ctlExe = logosctlProgram()

  var cases = 0

  type Case = object
    dir: string
    s: Session

  proc newCase(): Case =
    inc cases
    result.dir = makeShortBase("lrt" & $cases, deepest = "/s/run/logosctl.sock")
    result.s = Session(dir: result.dir / "s")

  proc ctl(c: Case, args: varargs[string]): Ran =
    runOnce(
      ctlExe,
      @["--session-dir", c.s.dir, "--text"] & @args,
      c.dir,
      timeoutMs = 120_000 * Slow,
    )

  proc ctlJson(c: Case, args: varargs[string]): JsonNode =
    let r = runOnce(
      ctlExe,
      @["--session-dir", c.s.dir, "--json"] & @args,
      c.dir,
      timeoutMs = 120_000 * Slow,
    )
    try:
      parseJson(r.stdout)
    except CatchableError:
      checkpoint("not JSON: " & r.stdout & r.stderr)
      newJNull()

  proc initRemote(c: Case, enabled: bool): Ran =
    var dc = defaultDaemonConfig("assigned-by-init")
    if enabled:
      dc.remote = Opt.some(LcnDcRemote(enabled: true))
    let path = c.dir / "config.cbor"
    writeFile(path, textOf(dc.encode.expect("an encoding")))
    c.ctl("init", "--config", "@" & path)

  proc start(c: Case): Child =
    spawnChild(dExe, ["--session-dir", c.s.dir], c.dir, "logosd")

  proc ready(c: Case, d: Child): bool =
    ## The socket answers `status`, or the daemon ended.
    for _ in 0 ..< ReadyMs div 20:
      if not d.alive:
        return false
      if entryExists(c.s.socketPath) and c.ctl("status").code == 0:
        return true
      sleep(20)
    false

  proc runs(c: Case): (bool, string) =
    ## logosd starts and answers, then stops cleanly; its log.
    let d = c.start()
    let up = c.ready(d)
    let code = stopChild(d, StopMs)
    (up and code == 0, d.errText)

  proc refusedStart(c: Case): (bool, string) =
    let d = c.start()
    (waitExit(d, ReadyMs) == 1, d.errText)

  suite "remote.trust: logosd and logosctl [IMPL-DECISION G408]":
    teardown:
      # Leaves daemonproc's list of children empty before the program ends:
      # under orc its exit procedure would free it a second time
      # (build/scratch/upstream/ISSUES.md 194).
      killAll()

    test "[IMPL-DECISION G407] [IMPL-DECISION G408] [RUN-0500] logosd reads no remote input without remote.enabled; with it, a start without a mark is refused until remote trust init, a stale record refuses the start and a conflict is logged while the start goes on":
      let c = newCase()
      check c.initRemote(false).code == 0
      var (ok1, log1) = c.runs()
      check ok1
      check not dirExists(c.s.remoteDir) and not fileExists(c.s.remoteTrustMarkPath)
      check "remote trust" notin log1
      c.s.dir.removeDir
      check c.initRemote(true).code == 0
      var (no, log2) = c.refusedStart()
      check no and "remote trust init" in log2
      let made = c.ctl("remote", "trust", "init")
      check made.code == 0 and AppliesAtNextStart in made.stdout
      var (ok2, log3) = c.runs()
      check ok2 and "remote trust: revision 1, 0 anchors, 0 enrollment keys" in log3
      # A conflict: logged, and the start goes on.
      c.s.put(2, @[a.anchor], @[a.active(1)])
      check c.runs()[0]
      c.s.put(3, @[a.anchor], @[a.active(1, @[a.spki, b.spki])])
      let (ok3, log4) = c.runs()
      check ok3
      check "remote-trust-report: Runtime " & IdA & " (" & TlsTcpProfile &
        ") has 2 conflicting records" in log4
      # A stale record refuses the start, naming it.
      c.s.put(4, @[a.anchor], @[a.active(0)])
      let (stale, log5) = c.refusedStart()
      check stale and "stale record" in log5
      if not (ok1 and ok2 and ok3 and stale):
        checkpoint(log1 & log2 & log3 & log4 & log5)

    test "[IMPL-DECISION G408] logosctl remote trust: every change says it applies at the next start and revoke that the restart closes the connections; the writers are refused while logosd runs; show gives the input, the mark and the report":
      let c = newCase()
      check c.initRemote(true).code == 0
      check c.ctl("remote", "trust", "init").code == 0
      let certPath = c.dir / "a.der"
      writeFile(certPath, textOf(a.cert))
      let d = c.start()
      check c.ready(d)
      let busy = c.ctl("remote", "trust", "anchor", "add", certPath)
      check busy.code == 1 and SessionBusy in busy.stderr
      check c.ctl("remote", "trust", "show").code == 0
      check stopChild(d, StopMs) == 0
      let id = anchorName(anchorIdOf(a.cert))
      var r = c.ctl("remote", "trust", "anchor", "add", certPath)
      check r.code == 0
      check r.stdout.contains(
        "remote trust revision 2: anchor " & id & " added; " & AppliesAtNextStart
      )
      check r.stdout.contains(
        "remote-trust-report: anchor " & id & ": no active record names it"
      )
      r = c.ctl("remote", "trust", "anchor", "add", certPath)
      check r.code == 0 and "nothing was written" in r.stdout
      let recPath = c.dir / "a.cbor"
      writeFile(recPath, textOf(a.active(1).encode.get))
      r = c.ctl("remote", "trust", "enroll", "add", "@" & recPath)
      check r.code == 0 and AppliesAtNextStart in r.stdout
      check "remote-trust-report" notin r.stdout
      let peerPath = c.dir / "b.cbor"
      writeFile(
        peerPath,
        textOf(LcnRemotePeer(anchor: b.anchor, enrollment: b.active(1)).encode.get),
      )
      r = c.ctl("remote", "trust", "import", "@" & peerPath)
      check r.code == 0 and "remote trust revision 4" in r.stdout
      r = c.ctl("remote", "trust", "enroll", "revoke", IdB, "--profile", "tls-tcp")
      check r.code == 0 and AppliesAtNextStart in r.stdout and RevokeCloses in r.stdout
      check c.ctl("remote", "trust", "enroll", "add", "@" & recPath).code == 0
      let bad = c.ctl("remote", "trust", "enroll", "add", "@" & certPath)
      check bad.code == 1
      let j = c.ctlJson("remote", "trust", "show")
      check j{"result", "revision"}.getInt == 5
      check j{"result", "mark", "revision"}.getInt == 1
      check j{"result", "continuity"}.getStr ==
        "accepted at the next start (a higher revision)"
      check j{"result", "enrollments"}.len == 2
      check j{"result", "anchors"}[0]{"problems"}.len == 0
      let (ok, log) = c.runs()
      check ok and
        "remote trust: revision 5, 2 anchors, 2 enrollment keys (a higher revision: the mark moved)" in
        log
      if not ok:
        checkpoint(log)
