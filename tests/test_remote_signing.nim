## Signing with the Runtime's TLS key over the remote control channel (Tier 5
## step 5-7a-1; DECISIONS G409, G410, G411; owner decision B1; 5-7a plan §3.6,
## §8), with no TLS engine: the handshakes signed this way are
## `test_remote_tls`'s. The channel's messages and the snapshot message;
## logosd's signing service; the relay to the key holder and the holder's own
## checks, rate limit and count file; the test copy; no key on the channel by
## default.

when defined(posix):
  import std/[os, posix, sequtils, strutils]
  import unittest2
  import ../src/logos_core/daemon/[credential, remotetrust, session, signsvc]
  import ../src/logos_core/remote/carrier
  import ../src/logos_core/transport/tls/[p256, testsigner, trustsnap]
  from ../src/logos_core/durable import ensurePrivateDir
  import ./support/[daemonbuild, daemonproc, rchannel, slowdown]
  from logos_sdk/testing/kitbuild import kitVariant

  const
    IdA = "0b6f3c3e-9d0f-4c1a-8f43-7a8f2b9b1a01"
    IdB = "5d2e8c71-3a4b-4e6f-9a1b-2c3d4e5f6a02"
    IdC = "9e8d7c6b-5a49-4382-b170-6f5e4d3c2b03"
    EcdsaP256 = 0x0403'u16
    WaitMs = 60_000 * Slow

  let work =
    currentSourcePath().parentDir.parentDir / "build" / "remote-signing" / kitVariant

  var cases = 0

  proc newCase(name: string): Session =
    inc cases
    let dir = work / ($cases & "-" & name)
    removeDir(dir)
    doAssert ensurePrivateDir(work).isOk
    doAssert ensurePrivateDir(dir).isOk
    Session(dir: dir)

  proc withCredential(name: string): (Session, CredentialInfo) =
    let s = newCase(name)
    let c = newCredential(s, IdA).get
    (s, c)

  proc cvInput(role: TlsRole, hashLen = 32): seq[byte] =
    ## A TLS 1.3 CertificateVerify input for `role` (RFC 8446 §4.4.3).
    result = newSeq[byte](64)
    for i in 0 ..< 64:
      result[i] = 0x20
    let ctx =
      if role == tlsClient:
        "TLS 1.3, client CertificateVerify"
      else:
        "TLS 1.3, server CertificateVerify"
    for ch in ctx:
      result.add(byte(ch))
    result.add(0)
    for i in 0 ..< hashLen:
      result.add(byte(i))

  proc verifies(cert, input, sig: seq[byte]): bool =
    ## Whether `sig` is an ECDSA P-256 SHA-256 signature of `input` by the
    ## certificate's key.
    let x = parseCertificate(cert).get
    defer:
      X509_free(x)
    let md = EVP_MD_CTX_new()
    defer:
      EVP_MD_CTX_free(md)
    sig.len > 0 and
      EVP_DigestVerifyInit(md, nil, EVP_sha256(), nil, X509_get0_pubkey(x)) == 1 and
      EVP_DigestVerify(
        md, unsafeAddr sig[0], csize_t(sig.len), unsafeAddr input[0], csize_t(input.len)
      ) == 1

  proc statuses(rs: openArray[SignResult]): (int, int, int) =
    for r in rs:
      case r.status
      of ssSigned:
        inc result[0]
      of ssRefused:
        inc result[1]
      of ssUnavailable:
        inc result[2]

  proc signAll(
      sig: Signer, role: TlsRole, inputs: openArray[seq[byte]], alg = EcdsaP256
  ): seq[SignResult] =
    var futs: seq[Future[SignResult]]
    for x in inputs:
      futs.add(sig(role, alg, x))
    discard waitFor withTimeout(allFutures(futs), milliseconds(WaitMs))
    for f in futs:
      result.add(
        if f.completed:
          f.value
        else:
          unavailable()
      )

  # The key holder as a child of this test process ----------------------------------------

  type Holder = object
    child: Child
    e: RchEnd

  const FrozenLimitVariable = "LCN_TEST_HOLDER_LIMIT_FROZEN"
    ## The holder's test hook (`daemon/keyholder.nim`): its limit's clock held at
    ## its start.

  proc startHolder(
      s: Session, name = "holder", args: seq[string] = @[], frozenLimit = false
  ): Holder =
    let (ours, theirs) = socketPair()
    let a =
      if args.len > 0:
        args
      else:
        @["--session=" & s.dir, "--parent=" & $getpid()]
    let env =
      if frozenLimit:
        @[(FrozenLimitVariable, "1")]
      else:
        @[]
    result.child =
      spawnChild(keyholderProgram(), a, s.dir, name, env = env, channel = theirs)
    discard posix.close(theirs)
    result.e = endOf(ours)

  proc collect(e: RchEnd, n: int): Future[seq[LcnRchMessage]] {.async: (raises: []).} =
    var got: seq[LcnRchMessage]
    for _ in 0 ..< n:
      let m = await e.receive()
      if m.isNone:
        break
      got.add(m.get)
    return got

  proc holderAnswers(h: Holder, reqs: openArray[LcnRchMessage]): seq[LcnRchMessage] =
    ## The holder's answers, read while the requests are written: the holder
    ## writes each answer before it reads the next request, so a writer that
    ## read nothing would fill the pair and stall both.
    let reading = h.e.collect(reqs.len)
    for r in reqs:
      if not waitFor h.e.send(r):
        break
    if waitFor reading.withTimeout(milliseconds(WaitMs)):
      result = reading.read

  proc endHolder(h: Holder): int =
    waitFor h.e.close()
    waitExit(h.child, WaitMs)

  suite "remote.signing: the channel, the signing service and the key holder [IMPL-DECISION G410]":
    teardown:
      # Before the exit procedures: upstream ISSUES.md 194.
      killAll()

    test "[IMPL-DECISION G411] the channel's messages round-trip; a frame that is no message ends it":
      let ms = @[
        signRequest(7, EcdsaP256, cvInput(tlsClient)),
        holderRequest(8, tlsServer, EcdsaP256, cvInput(tlsServer)),
        signAnswer(9, signed(@[byte 0x30, 1, 2])),
        signAnswer(10, refused()),
        signAnswer(11, unavailable()),
        toMessage(LcnRchTestKey(pkcs8: @[byte 1, 2, 3])),
      ]
      for m in ms:
        let f = frameOf(m).get
        var r = newRchReader()
        let bodies = r.feed(f).get
        check bodies.len == 1
        let back = decodeMessage(bodies[0]).get
        check back.encode.get == m.encode.get
      check decodeMessage(@[byte 0xa1, 0x61, 0x78, 0x01]).isErr
      check signAnswer(9, signed(@[byte 1])).answerOf.status == ssSigned
      check signAnswer(9, refused()).answerOf.status == ssRefused
      check signAnswer(9, unavailable()).answerOf.status == ssUnavailable
      check signAnswer(9, refused()).withId(4).answerId == 4
      check not signRequest(1, EcdsaP256, @[byte 1]).isAnswer
      # An input over the schema's bound does not encode.
      check frameOf(signRequest(1, EcdsaP256, newSeq[byte](257))).isErr

    test "[IMPL-DECISION G408] [IMPL-DECISION G324] the snapshot message carries the verifier's snapshot unchanged":
      let anchor = HeldAnchor(id: @[byte 0xab, 0xcd], certificate: @[byte 0x30, 0x01])
      let active = HeldRecord(
        runtime: IdA,
        profile: TlsTcpProfile,
        revision: 3,
        status: hsActive,
        anchor: anchor.id,
        keys: @[@[byte 1, 2], @[byte 3]],
      )
      let gone =
        HeldRecord(runtime: IdB, profile: TlsTcpProfile, revision: 5, status: hsRevoked)
      var c1 = active
      c1.runtime = IdC
      var c2 = c1
      c2.keys = @[@[byte 9]]
      let snap = buildSnapshot(
        4,
        [anchor],
        [
          HeldKey(records: @[active]),
          HeldKey(records: @[gone]),
          HeldKey(records: @[c1, c2]),
        ],
      ).get
      let m = snapshotMessage(snap)
      let back = decodeMessage(frameOf(m).get[4 ..^ 1]).get
      let again = snapshotOf(back.arm_lcn_Rch_snapshot).get
      check again.anchorRevision == 4
      check again.anchorIds == @["abcd"]
      check again.anchor("abcd").get == @[byte 0x30, 0x01]
      check again.runtimes == @[IdA, IdB, IdC]
      check again.record(IdA).get.status == rsActive
      check again.record(IdA).get.anchor == "abcd"
      check again.record(IdA).get.spkis == @[@[byte 1, 2], @[byte 3]]
      check again.record(IdB).get.status == rsRevoked
      check again.record(IdC).get.status == rsConflicting
      check again.record(IdC).get.spkis.len == 3
      check snapshotMessage(again).encode.get == m.encode.get
      # A revoked record holding a key, or an active one naming no anchor, is
      # refused.
      var bad = back.arm_lcn_Rch_snapshot
      for r in bad.records.mitems:
        if r.runtime_instance_id == IdB:
          r.keys = @[@[byte 1]]
      check snapshotOf(bad).isErr
      bad = back.arm_lcn_Rch_snapshot
      for r in bad.records.mitems:
        if r.runtime_instance_id == IdA:
          r.anchor = Opt.none(string)
      check snapshotOf(bad).isErr

    test "the client end: its role only, ids it sent only, unavailable once closed":
      var sent: seq[uint64]
      let c = newSignClient(
        tlsClient,
        proc(id: uint64, alg: uint16, input: seq[byte]): bool {.gcsafe, raises: [].} =
          {.cast(gcsafe).}:
            sent.add(id)
          true,
      )
      let sig = c.signer
      check (waitFor sig(tlsServer, EcdsaP256, cvInput(tlsServer))).status == ssRefused
      check sent.len == 0
      let f = sig(tlsClient, EcdsaP256, cvInput(tlsClient))
      check sent == @[1'u64]
      check c.waiting == 1
      check not c.deliver(2, signed(@[byte 1])) # never sent
      check c.deliver(1, signed(@[byte 0x30]))
      check (waitFor f).status == ssSigned
      check c.deliver(1, signed(@[byte 0x30])) # late: dropped
      let g = sig(tlsClient, EcdsaP256, cvInput(tlsClient))
      c.close()
      check (waitFor g).status == ssUnavailable
      check (waitFor sig(tlsClient, EcdsaP256, cvInput(tlsClient))).status ==
        ssUnavailable
      check sent.len == 2

    test "[IMPL-DECISION G410] logosd's service signs through the channel what checkSignInput accepts":
      let (s, cred) = withCredential("service")
      let svc = newSignService(s.credentialDir).get
      defer:
        svc.close()
      let (p, l) = socketPair()
      let process = endOf(p)
      let logosd = endOf(l)
      let c = process.clientOn(tlsClient)
      let faults = new int
      asyncSpawn process.pumpAnswers(c, faults)
      # The limit's clock held still: the burst below is exact however slowly
      # this build serves it (under MemorySanitizer the bucket refilled as fast
      # as the burst drained it).
      asyncSpawn logosd.serveService(svc, tlsClient, frozenNs = monoNs())
      let sig = c.signer
      let x = cvInput(tlsClient)
      let ok = waitFor sig(tlsClient, EcdsaP256, x)
      check ok.status == ssSigned
      check verifies(cred.certificate, x, ok.signature)
      check verifies(
        cred.certificate,
        cvInput(tlsClient, 48),
        (waitFor sig(tlsClient, EcdsaP256, cvInput(tlsClient, 48))).signature,
      )
      # The other role's context, another algorithm, another length, bad
      # padding: refused at logosd's end.
      var padded = x
      padded[3] = 0x21
      for (alg, input) in [
        (EcdsaP256, cvInput(tlsServer)),
        (0x0804'u16, x),
        (EcdsaP256, x[0 ..^ 2]),
        (EcdsaP256, padded),
      ]:
        check (waitFor sig(tlsClient, alg, input)).status == ssRefused
      check svc.count.signed == 2
      check svc.count.refused == 4
      # [IMPL] logosd's limit per process: a burst over it is refused. The six
      # requests above each took a token, refused or not.
      let rs = signAll(sig, tlsClient, newSeqWith(260, x))
      let (signedN, refusedN, unavailableN) = statuses(rs)
      check unavailableN == 0
      check signedN == ProcessBurst - 6
      check refusedN == 260 - (ProcessBurst - 6)
      # No key crossed the channel: the process's end read answers only, and
      # logosd's end wrote answers only.
      check process.got.allIt(it in {lcn_Rch_signed, lcn_Rch_sign_refused})
      check logosd.sent.allIt(it in {lcn_Rch_signed, lcn_Rch_sign_refused})
      check faults[] == 0
      waitFor process.close()
      waitFor logosd.close()

    test "[IMPL-DECISION G410] key-holder mode: logosd relays, the holder checks, limits and counts itself":
      let (s, cred) = withCredential("holder")
      let h = startHolder(s)
      let (p, l) = socketPair()
      let process = endOf(p)
      let logosd = endOf(l)
      let relay = new HolderRelay
      let c = process.clientOn(tlsServer)
      let faults = new int
      asyncSpawn process.pumpAnswers(c, faults)
      let served = logosd.serveRelay(h.e, tlsServer, relay)
      let sig = c.signer
      let x = cvInput(tlsServer)
      let ok = waitFor sig(tlsServer, EcdsaP256, x)
      check ok.status == ssSigned
      check verifies(cred.certificate, x, ok.signature)
      # logosd refuses what it would not sign itself; the holder never sees it.
      check (waitFor sig(tlsServer, EcdsaP256, cvInput(tlsClient))).status == ssRefused
      check h.e.sent == @[lcn_Rch_holder_sign]
      check relay[].waiting == 0
      check faults[] == 0
      # The process ends, then the holder: its count file at its exit.
      waitFor process.close()
      check waitFor served.withTimeout(milliseconds(WaitMs))
      check endHolder(h) == 0
      let first = readHolderCount(s).get.get
      check first.signed == 1
      check first.refused == 0
      # A later run: its own check of a role other than the input's, sent to
      # it directly as only logosd could, and its count carried on. Its limit's
      # clock is held still (the test hook): the burst below is exact however
      # slowly this build serves it (under MemorySanitizer the bucket refilled
      # as fast as the burst drained it, and all 260 were signed).
      let h2 = startHolder(s, "holder2", frozenLimit = true)
      let direct = h2.holderAnswers(
        [
          holderRequest(100, tlsClient, EcdsaP256, cvInput(tlsServer)),
          holderRequest(101, tlsServer, EcdsaP256, x),
        ]
      )
      check direct.len == 2
      if direct.len == 2:
        check direct[0].answerOf.status == ssRefused
        check direct[1].answerOf.status == ssSigned
      # Its own limit, 100 a second with bursts of 200 [IMPL]. The two requests
      # above each took a token, refused or not.
      var burst: seq[LcnRchMessage]
      for i in 0 ..< 260:
        burst.add(holderRequest(uint64(200 + i), tlsServer, EcdsaP256, x))
      let answers = h2.holderAnswers(burst)
      check answers.len == 260
      let (bs, br, bu) = statuses(answers.mapIt(it.answerOf))
      check bu == 0
      check bs == HolderBurst - 2
      check br == 260 - (HolderBurst - 2)
      check endHolder(h2) == 0
      let count = readHolderCount(s).get.get
      check count.signed == uint64(2 + bs)
      check count.refused == uint64(1 + br)
      waitFor logosd.close()

    test "[IMPL-DECISION G410] [IMPL-DECISION G409] what logosd reads at a key-holder start never opens key.p8: it reads, and a rotation is taken up, with the key unreadable; the key loader is refused":
      if getuid() == 0:
        skip() # mode 0200 does not stop root reading
      else:
        let (s, cred) = withCredential("unread")
        discard rotateCredential(s, IdA).get
        let next = nextCredentialDir(s)
        for dir in [cred.dir, next]:
          setFilePermissions(keyPath(dir), {fpUserWrite})
        check loadCredentialKey(cred.dir).isErr
        check newSignService(cred.dir).isErr
        # assemble's steps in key-holder mode: the take-up, then the check.
        check takeUpCredential(s).get
        let now = currentCredential(s).get
        check now.isSome
        check now.get.revisionOf == 2
        check not dirExists(next)
        check not dirExists(s.remoteDir / OldCredentialName)
        check loadCredentialKey(credentialDir(s)).isErr
        setFilePermissions(keyPath(credentialDir(s)), {fpUserRead, fpUserWrite})
        let loaded = loadCredentialKey(credentialDir(s))
        check loaded.isOk
        if loaded.isOk:
          loaded.get.free()

    test "[IMPL-DECISION G410] the key holder ends on anything but holder_sign, and needs its arguments":
      let (s, _) = withCredential("holder-ends")
      let h = startHolder(s)
      check waitFor h.e.send(signRequest(1, EcdsaP256, cvInput(tlsServer)))
      check (waitFor h.e.receive()).isNone
      check waitExit(h.child, WaitMs) == 1
      check "not holder_sign" in h.child.errText
      let g = startHolder(s, "holder-garbage")
      check waitFor g.e.sendBytes(@[byte 0, 0, 0, 2, 0xff, 0xff])
      check waitExit(g.child, WaitMs) == 1
      check "not a channel message" in g.child.errText
      let none = startHolder(s, "holder-noparent", @["--session=" & s.dir])
      check waitExit(none.child, WaitMs) == 2
      check "--parent" in none.child.errText
      let other = newCase("holder-nokey")
      let k = startHolder(other, "holder-nokey")
      check waitExit(k.child, WaitMs) == 1
      check "there is no credential/cert.der" in k.child.errText
      for x in [h.e, g.e, none.e, k.e]:
        waitFor x.close()

    test "[IMPL-DECISION G410] the relay maps answers back and refuses answers to nothing":
      var r: HolderRelay
      var p = newProcessSigning(tlsClient)
      let req =
        r.relay(7, p, LcnRchSign(id: 42, alg: EcdsaP256, input: cvInput(tlsClient)))
      check req.isOk
      let hid = req.get.arm_lcn_Rch_holder_sign.id
      check req.get.arm_lcn_Rch_holder_sign.role.roleOf == tlsClient
      let back = r.returned(signAnswer(hid, signed(@[byte 0x30]))).get
      check back[0] == 7
      check back[1].answerId == 42
      check r.returned(signAnswer(hid + 5, refused())).isErr
      check r.returned(signRequest(1, EcdsaP256, @[byte 1])).isErr
      let req2 =
        r.relay(8, p, LcnRchSign(id: 1, alg: EcdsaP256, input: cvInput(tlsClient)))
      r.forget(8)
      check r.waiting == 0
      check r.returned(signAnswer(req2.get.arm_lcn_Rch_holder_sign.id, refused())).get[
        0
      ] == 0
      let no =
        r.relay(9, p, LcnRchSign(id: 3, alg: EcdsaP256, input: cvInput(tlsServer)))
      check no.isErr
      check no.error.answerOf.status == ssRefused

    test "[IMPL-DECISION G410] process copy (test builds only): the key on the channel, signing in the process":
      let (s, cred) = withCredential("copy")
      let m = testKeyMessage(s.credentialDir).get
      check m.kind == lcn_Rch_test_key
      var der = m.arm_lcn_Rch_test_key.pkcs8
      let key = fromPkcs8(der).get
      defer:
        key.free()
      check key.spkiDer.get == cred.spki
      let x = cvInput(tlsClient)
      let r = waitFor keySigner(key, tlsClient)(tlsClient, EcdsaP256, x)
      check r.status == ssSigned
      check verifies(cred.certificate, x, r.signature)
