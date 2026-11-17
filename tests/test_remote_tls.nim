## TRANSPORT §8.4.1; owner B1; I99, G323, G326, G328: the `logos.remote.tls-tcp`
## carrier's library (step 5-2b): P-256 credentials, the signing seam, the
## sans-I/O engine and authenticated streams over loopback TCP. The peer checks
## here are the fixture's (`support/tls_fixtures.nim`: one pinned SPKI per
## Runtime id); the enrollment checks are 5-2a's. The one suite that imports
## the TLS library, so that one test build per variant compiles BoringSSL.

import std/[sequtils, strutils]
import unittest2
import results
import ../src/logos_core/transport/tls/boring
import ./support/[slowdown, tls_fixtures]

proc waitUntil(cond: proc(): bool {.gcsafe, raises: [].}, ms: int): bool =
  ## Runs the event loop until `cond` holds, at most `ms` × `Slow`.
  let until = Moment.now() + milliseconds(ms * Slow)
  while not cond():
    if Moment.now() > until:
      return false
    waitFor sleepAsync(milliseconds(2))
  true

type Seen = ref object
  peers: seq[string]
  bindings: seq[seq[byte]]
  sni: seq[string]
  versions: seq[int]
  readErrors: seq[string]
  frames: int

proc echoHandler(seen: Seen): StreamHandler =
  ## Records what the server saw, then echoes frames until the end.
  result = proc(s: TlsStream): Future[void] {.async: (raises: []), gcsafe.} =
    seen.peers.add(s.peer.runtime)
    seen.sni.add(s.engine.serverNameSeen)
    seen.versions.add(s.engine.version)
    let b = s.takeChannelBinding()
    seen.bindings.add(
      if b.isOk:
        b.get
      else:
        @[]
    )
    try:
      while true:
        let f = await s.readFrame()
        if f.isErr:
          seen.readErrors.add(f.error)
          return
        if f.get.isNone:
          return
        inc seen.frames
        if (await s.writeFrame(f.get.get)).isErr:
          return
    except CancelledError:
      discard

proc delayed(inner: Signer, ms: int): Signer =
  result = proc(
      role: TlsRole, alg: uint16, input: seq[byte]
  ): Future[SignResult] {.async: (raises: [CancelledError]), gcsafe.} =
    await sleepAsync(milliseconds(ms))
    return await inner(role, alg, input)

type SignerLog = ref object
  calls: int
  cancelled: int

proc counted(inner: Signer, log: SignerLog, ms: int): Signer =
  ## Answers after `ms`; counts calls and cancellations.
  result = proc(
      role: TlsRole, alg: uint16, input: seq[byte]
  ): Future[SignResult] {.async: (raises: [CancelledError]), gcsafe.} =
    inc log.calls
    try:
      await sleepAsync(milliseconds(ms))
    except CancelledError as x:
      inc log.cancelled
      raise x
    return await inner(role, alg, input)

proc refusing(): Signer =
  result = proc(
      role: TlsRole, alg: uint16, input: seq[byte]
  ): Future[SignResult] {.async: (raises: [CancelledError]), gcsafe.} =
    return refused()

proc silent(): Signer =
  result = proc(
      role: TlsRole, alg: uint16, input: seq[byte]
  ): Future[SignResult] {.async: (raises: [CancelledError]), gcsafe.} =
    await sleepAsync(hours(1))
    return unavailable()

let
  a = newParty(IdA)
  b = newParty(IdB)
  c = newParty(IdC)

proc listen(
    server: Party,
    seen: Seen,
    known: openArray[Party],
    signer: Signer = nil,
    config = fastConfig(),
    ctx: TlsContext = nil,
): TlsListener =
  let sctx =
    if ctx == nil:
      serverContext(server)
    else:
      ctx
  let sig =
    if signer == nil:
      keySigner(server.key, tlsServer)
    else:
      signer
  serve("127.0.0.1", 0, sctx, pinnedCheck(known), sig, config, echoHandler(seen)).get

proc addressOf(l: TlsListener, serverName = ""): TlsTcpAddress =
  TlsTcpAddress(host: "127.0.0.1", port: l.localPort, serverName: serverName)

proc dial(
    l: TlsListener,
    client: Party,
    server: Party,
    serverName = "",
    signer: Signer = nil,
    config = fastConfig(),
    ctx: TlsContext = nil,
    registry: StreamRegistry = nil,
): Result[TlsStream, string] =
  let cctx =
    if ctx == nil:
      clientContext(client)
    else:
      ctx
  let sig =
    if signer == nil:
      keySigner(client.key, tlsClient)
    else:
      signer
  waitFor connect(
    l.addressOf(serverName), cctx, expectCheck(server), sig, config, registry
  )

proc roundTrip(s: TlsStream, body: seq[byte]): Result[seq[byte], string] =
  ?(waitFor s.writeFrame(body))
  let f = ?(waitFor s.readFrame())
  if f.isNone:
    return err("closed")
  ok(f.get)

suite "tls.credentials":
  test "[IMPL-DECISION I99] a P-256 key, its PKCS#8 form, a self-signed certificate and the SPKI an enrollment holds":
    let k = newP256Key().get
    let spki = k.spkiDer().get
    check spki.len == 91 # SEQUENCE { id-ecPublicKey, prime256v1 }, 65-byte point
    var p8 = k.toPkcs8().get
    let k2 = fromPkcs8(p8).get
    check k2.spkiDer().get == spki
    check fromPkcs8(p8 & @[0'u8]).isErr # nothing after the key
    check fromPkcs8(@[1'u8, 2, 3]).isErr
    p8.setLen(0)
    let cert = k.selfSignedCertificate(
      CertificateOptions(
        commonName: IdA,
        notBefore: nowPosix(),
        notAfter: nowPosix() + 86400,
        keyUsage: "critical,digitalSignature",
        extendedKeyUsage: "clientAuth,serverAuth",
      )
    ).get
    check certificateSpki(cert).get == spki
    check certificateSpki(cert & @[0'u8]).isErr
    let x = parseCertificate(cert).get
    let flags = X509_get_extension_flags(x)
    check (flags and EXFLAG_KUSAGE.uint32) != 0
    check (X509_get_key_usage(x) and KuDigitalSignature) != 0
    check (flags and EXFLAG_XKUSAGE.uint32) != 0
    check (X509_get_extended_key_usage(x) and XKU_SSL_CLIENT.uint32) != 0
    check (X509_get_extended_key_usage(x) and XKU_SSL_SERVER.uint32) != 0
    X509_free(x)
    let bad = k.selfSignedCertificate(
      CertificateOptions(commonName: "", notBefore: 0, notAfter: 1)
    )
    check bad.isErr
    k.free()
    k2.free()

  test "[IMPL-DECISION I99] two keys differ; a key that is not P-256 is refused":
    let k1 = newP256Key().get
    let k2 = newP256Key().get
    check k1.spkiDer().get != k2.spkiDer().get
    # An Ed25519 PKCS#8 key (RFC 8410 §10.3's example).
    let ed = @[
      0x30'u8, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04,
      0x22, 0x04, 0x20, 0xd4, 0xee, 0x72, 0xdb, 0xf9, 0x13, 0x58, 0x4a, 0xd5, 0xb6,
      0xd8, 0xf1, 0xf7, 0x69, 0xf8, 0xad, 0x3a, 0xfe, 0x7c, 0x28, 0xcb, 0xf1, 0xd4,
      0xfb, 0xe0, 0x97, 0xa8, 0x8f, 0x44, 0x75, 0x58, 0x42,
    ]
    check fromPkcs8(ed).error == "not a P-256 key"
    k1.free()
    k2.free()

suite "tls.signing":
  proc cvInput(context: string, hashLen = 32): seq[byte] =
    result = newSeqWith(64, 0x20'u8)
    for ch in context:
      result.add(byte(ch))
    result.add(0)
    result.add(newSeqWith(hashLen, 0xab'u8))

  test "[IMPL-DECISION G323] a signer signs a TLS 1.3 CertificateVerify input of its own role and nothing else":
    let cli = cvInput("TLS 1.3, client CertificateVerify")
    let srv = cvInput("TLS 1.3, server CertificateVerify", 48)
    check checkSignInput(tlsClient, SigAlgEcdsaP256Sha256, cli).isOk
    check checkSignInput(tlsServer, SigAlgEcdsaP256Sha256, srv).isOk
    check checkSignInput(tlsClient, SigAlgEcdsaP256Sha256, srv).isErr
    check checkSignInput(tlsServer, SigAlgEcdsaP256Sha256, cli).isErr
    check checkSignInput(tlsClient, 0x0804, cli).isErr # rsa_pss_rsae_sha256
    check checkSignInput(tlsClient, SigAlgEcdsaP256Sha256, cli[0 .. ^2]).isErr
    var padded = cli
    padded[3] = 0x21
    check checkSignInput(tlsClient, SigAlgEcdsaP256Sha256, padded).isErr
    var sep = cli
    sep[64 + 33] = 1
    check checkSignInput(tlsClient, SigAlgEcdsaP256Sha256, sep).isErr
    check checkSignInput(tlsClient, SigAlgEcdsaP256Sha256, newSeq[byte](64)).isErr

  test "[IMPL-DECISION G323] the test signer answers for its role only, with a signature its key verifies":
    let sig = keySigner(a.key, tlsClient)
    let cli = cvInput("TLS 1.3, client CertificateVerify")
    let r = waitFor sig(tlsClient, SigAlgEcdsaP256Sha256, cli)
    check r.status == ssSigned
    check r.signature.len in 64 .. 72
    check (waitFor sig(tlsServer, SigAlgEcdsaP256Sha256, cli)).status == ssRefused
    check (waitFor sig(tlsClient, SigAlgEcdsaP256Sha256, @[1'u8])).status == ssRefused

suite "tls.params":
  test "[TRN-0376] a server_name must be a DNS name valid for SNI host_name, not an IP literal":
    for good in ["example.org", "a.b-c.example", "x", "node-1.logos.example"]:
      check checkServerName(good).isOk
    for bad in [
      "",
      "127.0.0.1",
      "10.0.0.256",
      "::1",
      "[::1]",
      "a_b.example",
      "-a.example",
      "a-.example",
      "example.org.",
      "a..b",
      "é.example",
      repeat('a', 64) & ".example",
      repeat("abcdefghi.", 26) & "example",
    ]:
      check checkServerName(bad).isErr
    var cfg = defaultTlsConfig()
    check cfg.check().isOk
    cfg.frameLimit = 1024
    check cfg.check().isErr

suite "tls.handshake":
  test "[TRN-0219] [TRN-0220] [TRN-0228] [TRN-0233] [IMPL-DECISION G326] mutual TLS 1.3 with ecdsa_secp256r1_sha256 both ways; each side learns the other's Runtime; a 32-byte channel binding equal at both ends and new per connection":
    let seen = Seen()
    let l = listen(b, seen, [a])
    let s1 = l.dial(a, b).get
    check s1.peer.runtime == IdB
    check s1.engine.version == 0x0304
    check s1.engine.peerSignatureAlgorithm == SigAlgEcdsaP256Sha256
    check s1.roundTrip(@[1'u8, 2, 3]).get == @[1'u8, 2, 3]
    let b1 = s1.takeChannelBinding().get
    check b1.len == ChannelBindingLen
    check s1.takeChannelBinding().isErr # given once
    check seen.peers == @[IdA]
    check seen.versions == @[0x0304]
    check seen.bindings == @[b1]
    let s2 = l.dial(a, b).get
    check s2.roundTrip(@[4'u8]).get == @[4'u8]
    let b2 = s2.takeChannelBinding().get
    check b2 != b1
    check seen.bindings[1] == b2
    waitFor s1.close()
    waitFor s2.close()
    waitFor l.close()

  test "[TRN-0233] no session is offered or resumed; nothing passes before the handshake":
    let seen = Seen()
    let l = listen(b, seen, [a])
    let s = l.dial(a, b).get
    check s.roundTrip(@[9'u8]).isOk
    check s.engine.sessionsOffered == 0
    check not s.engine.sessionReused
    let s2 = l.dial(a, b).get
    check s2.roundTrip(@[9'u8]).isOk
    check not s2.engine.sessionReused
    check s2.engine.sessionsOffered == 0
    waitFor s.close()
    waitFor s2.close()
    waitFor l.close()

  test "[TRN-0219] a TLS 1.2 client and a TLS 1.2 server are refused":
    let seen = Seen()
    let l = listen(b, seen, [a])
    let old =
      newTlsContextForTests(tlsClient, a.cert, maxVersion = TLS1_2_VERSION.uint16).get
    let r = l.dial(a, b, ctx = old)
    check r.isErr
    check waitUntil(
      proc(): bool =
        l.failedHandshakes == 1,
      2000,
    )
    check "UNSUPPORTED_PROTOCOL" in l.lastFailure
    check "PROTOCOL_VERSION" in r.error
    check seen.peers.len == 0
    waitFor l.close()
    old.free()
    let oldServer =
      newTlsContextForTests(tlsServer, b.cert, maxVersion = TLS1_2_VERSION.uint16).get
    let seen2 = Seen()
    let l2 = listen(b, seen2, [a], ctx = oldServer)
    let r2 = l2.dial(a, b)
    check r2.isErr
    check "PROTOCOL_VERSION" in r2.error
    check seen2.peers.len == 0
    waitFor l2.close()
    oldServer.free()

  test "[TRN-0220] [IMPL-DECISION G328] a client with no certificate is refused: the server reads nothing, the client's first read fails":
    let seen = Seen()
    let l = listen(b, seen, [a])
    let bare = newTlsContextForTests(tlsClient, @[], withCertificate = false).get
    let r = l.dial(a, b, ctx = bare)
    if r.isOk:
      # TLS 1.3: the client finishes before the server has checked it (G328).
      let f = waitFor r.get.readFrame()
      check f.isErr
      waitFor r.get.close()
    check waitUntil(
      proc(): bool =
        l.failedHandshakes == 1,
      2000,
    )
    check "PEER_DID_NOT_RETURN_A_CERTIFICATE" in l.lastFailure
    check seen.peers.len == 0
    waitFor l.close()
    bare.free()

  test "[TRN-0221] [IMPL-DECISION G328] a client whose key the server's check refuses gets no stream: its frames are never read":
    let seen = Seen()
    let l = listen(b, seen, [a])
    let r = l.dial(c, b)
    if r.isOk:
      discard waitFor r.get.writeFrame(@[1'u8, 2])
      let f = waitFor r.get.readFrame()
      check f.isErr
      waitFor r.get.close()
    check waitUntil(
      proc(): bool =
        l.failedHandshakes == 1,
      2000,
    )
    check "not pinned" in l.lastFailure
    check seen.peers.len == 0
    check seen.frames == 0
    waitFor l.close()

  test "[TRN-0222] the client refuses a server its check does not accept":
    let seen = Seen()
    let l = listen(c, seen, [a])
    let r = l.dial(a, b) # expects b, meets c
    check r.isErr
    check "not pinned" in r.error
    check waitUntil(
      proc(): bool =
        l.failedHandshakes == 1,
      2000,
    )
    check seen.peers.len == 0
    waitFor l.close()

  test "[TRN-0376] SNI host_name is sent when the address names a server_name, and not otherwise; an IP literal is refused before connecting":
    let seen = Seen()
    let l = listen(b, seen, [a])
    let s1 = l.dial(a, b, serverName = "node-b.logos.example").get
    check s1.roundTrip(@[1'u8]).isOk
    let s2 = l.dial(a, b).get
    check s2.roundTrip(@[1'u8]).isOk
    check seen.sni == @["node-b.logos.example", ""]
    let ip = l.dial(a, b, serverName = "127.0.0.1")
    check ip.isErr
    check "IP literal" in ip.error
    check l.dial(a, b, serverName = "bad_name.example").isErr
    check seen.peers.len == 2
    waitFor s1.close()
    waitFor s2.close()
    waitFor l.close()

suite "tls.streams":
  test "[IMPL-DECISION I99] frames up to 1 MiB pass through the read bound in order; close_notify is a clean end":
    let seen = Seen()
    let l = listen(b, seen, [a])
    let s = l.dial(a, b).get
    var big = newSeq[byte](1024 * 1024)
    for i in 0 ..< big.len:
      big[i] = byte(i mod 251)
    check s.roundTrip(big).get == big
    for i in 0 ..< 20:
      check (waitFor s.writeFrame(@[byte(i)])).isOk
    for i in 0 ..< 20:
      check (waitFor s.readFrame()).get.get == @[byte(i)]
    waitFor s.close()
    check waitUntil(
      proc(): bool =
        l.registry.len == 0,
      2000,
    )
    check seen.readErrors.len == 0
    waitFor l.close()

  test "[IMPL-DECISION I99] a frame over the limit is refused by the sender, and by the receiver when it is declared":
    let seen = Seen()
    let l = listen(b, seen, [a])
    let s = l.dial(a, b).get
    let tooBig = newSeq[byte](int(defaultTlsConfig().peerFrameLimit) + 1)
    check (waitFor s.writeFrame(tooBig)).isErr
    # A declared length over the receiver's limit, written below the framing.
    check s.engine.writeApp([0xff'u8, 0xff, 0xff, 0xff]).isOk
    discard waitFor s.writeFrame(@[1'u8])
    check waitUntil(
      proc(): bool =
        seen.readErrors.len == 1,
      2000,
    )
    check "over the limit" in seen.readErrors[0]
    waitFor s.close()
    waitFor l.close()

  test "[IMPL-DECISION I99] a transport that ends without close_notify is an error, not an end":
    let seen = Seen()
    let l = listen(b, seen, [a])
    let s = l.dial(a, b).get
    check s.roundTrip(@[7'u8]).isOk
    waitFor s.abortForTests()
    check waitUntil(
      proc(): bool =
        seen.readErrors.len == 1,
      2000,
    )
    check "close_notify" in seen.readErrors[0] or "ended" in seen.readErrors[0]
    waitFor l.close()

  test "[TRN-0227] closePeer closes every stream of one Runtime and no other":
    let seen = Seen()
    let l = listen(b, seen, [a, c])
    let a1 = l.dial(a, b).get
    let a2 = l.dial(a, b).get
    let c1 = l.dial(c, b).get
    for s in [a1, a2, c1]:
      check s.roundTrip(@[1'u8]).isOk
    check l.registry.len == 3
    check (waitFor l.registry.closePeer(IdA)) == 2
    check l.registry.len == 1
    for s in [a1, a2]:
      let f = waitFor s.readFrame()
      check f.isErr or f.get.isNone
    check c1.roundTrip(@[2'u8]).isOk
    waitFor a1.close()
    waitFor a2.close()
    waitFor c1.close()
    waitFor l.close()

suite "tls.signing seam":
  test "[IMPL-DECISION G323] signatures answered later by another task complete the handshake on both sides":
    let seen = Seen()
    let l = listen(b, seen, [a], signer = delayed(keySigner(b.key, tlsServer), 30))
    let s = l.dial(a, b, signer = delayed(keySigner(a.key, tlsClient), 30)).get
    check s.roundTrip(@[5'u8]).isOk
    check seen.peers == @[IdA]
    waitFor s.close()
    waitFor l.close()

  test "[IMPL-DECISION G323] a refused signature fails the handshake closed, on either side":
    let seen = Seen()
    let l = listen(b, seen, [a], signer = refusing())
    let r = l.dial(a, b)
    check r.isErr
    check waitUntil(
      proc(): bool =
        l.failedHandshakes == 1,
      2000,
    )
    check "refused" in l.lastFailure
    waitFor l.close()
    let seen2 = Seen()
    let l2 = listen(b, seen2, [a])
    let r2 = l2.dial(a, b, signer = refusing())
    check r2.isErr
    check "refused" in r2.error
    check waitUntil(
      proc(): bool =
        l2.failedHandshakes == 1,
      2000,
    )
    check seen2.peers.len == 0
    waitFor l2.close()

  test "[IMPL-DECISION I99] a signer that never answers meets the handshake deadline; a cancelled handshake drops its signature and the signer serves the next":
    let seen = Seen()
    let l = listen(b, seen, [a])
    let t0 = Moment.now()
    let r = l.dial(a, b, signer = silent(), config = fastConfig(300))
    check r.isErr
    check "300 ms" in r.error
    check Moment.now() - t0 < milliseconds(300 + 2000 * Slow)
    let log = SignerLog()
    let slow = counted(keySigner(a.key, tlsClient), log, 200)
    let cctx = clientContext(a)
    let fut = connect(l.addressOf(), cctx, expectCheck(b), slow, fastConfig())
    check waitUntil(
      proc(): bool =
        log.calls == 1,
      2000,
    )
    waitFor fut.cancelAndWait()
    check log.cancelled == 1
    let s = l.dial(a, b, signer = slow, ctx = cctx).get
    check s.roundTrip(@[1'u8]).isOk
    check log.calls == 2
    waitFor s.close()
    waitFor l.close()

  test "[IMPL-DECISION I99] 32 handshakes with slow signers run at once without blocking the event loop":
    let seen = Seen()
    let l = listen(b, seen, [a], signer = delayed(keySigner(b.key, tlsServer), 50))
    let cctx = clientContext(a)
    let sig = delayed(keySigner(a.key, tlsClient), 50)
    var ticking = true
    var maxGap = ZeroDuration
    proc ticker() {.async: (raises: []).} =
      var last = Moment.now()
      while ticking:
        try:
          await sleepAsync(milliseconds(1))
        except CancelledError:
          return
        let now = Moment.now()
        maxGap = max(maxGap, now - last)
        last = now

    let t = ticker()
    let t0 = Moment.now()
    var futs: seq[Future[Result[TlsStream, string]].Raising([CancelledError])] = @[]
    for i in 0 ..< 32:
      futs.add(connect(l.addressOf(), cctx, expectCheck(b), sig, fastConfig()))
    var streams: seq[TlsStream] = @[]
    for f in futs:
      let r = waitFor f
      check r.isOk
      if r.isOk:
        streams.add(r.get)
    let wall = Moment.now() - t0
    ticking = false
    waitFor t
    check streams.len == 32
    # Serially the signatures alone would take 32 × 100 ms.
    check wall < milliseconds(3200 * Slow)
    check maxGap < milliseconds(250 * Slow)
    for s in streams:
      waitFor s.close()
    waitFor l.close()

  test "[IMPL-DECISION I99] past the handshake bound a connection is closed at once, unread":
    let seen = Seen()
    var cfg = fastConfig()
    cfg.maxHandshakes = 2
    let l = listen(b, seen, [a], config = cfg)
    var idle: seq[StreamTransport] = @[]
    for i in 0 ..< 2:
      idle.add(waitFor connect(initTAddress("127.0.0.1", Port(l.localPort))))
    check waitUntil(
      proc(): bool =
        l.handshakesInProgress == 2,
      2000,
    )
    let third = waitFor connect(initTAddress("127.0.0.1", Port(l.localPort)))
    check waitUntil(
      proc(): bool =
        l.refusedOverBound == 1,
      2000,
    )
    var buf: array[16, byte]
    let n =
      try:
        waitFor third.readOnce(addr buf[0], buf.len)
      except CatchableError:
        0
    check n == 0
    for t in idle & @[third]:
      waitFor t.closeWait()
    check waitUntil(
      proc(): bool =
        l.handshakesInProgress == 0,
      2000,
    )
    let s = l.dial(a, b).get
    check s.roundTrip(@[1'u8]).isOk
    waitFor s.close()
    waitFor l.close()

freeContexts()
for p in [a, b, c]:
  p.free()
