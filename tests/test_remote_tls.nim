## TRANSPORT §8.4.1; owner B1; I99, G323, G326, G328: the `logos.remote.tls-tcp`
## carrier's library: P-256 credentials, the signing seam, the sans-I/O engine
## and authenticated streams over loopback TCP (step 5-2b, with the fixture's
## check that pins one SPKI per Runtime id, `support/tls_fixtures.nim`); the
## trust snapshot and the enrollment checks, alone and through real handshakes
## (step 5-2a; G324, G325). The one suite that imports the TLS library, so that
## one test build per variant compiles BoringSSL.

import std/[sequtils, strutils, sysrand]
import unittest2
import results
import logos_sdk/base/[wipe, wipeaudit]
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
        if (await s.writeFrame(f.get.get.body)).isErr:
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
    check: PeerCheck = nil,
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
  let chk =
    if check == nil:
      pinnedCheck(known)
    else:
      check
  serve("127.0.0.1", 0, sctx, chk, sig, config, echoHandler(seen)).get

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
    check: PeerCheck = nil,
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
  let chk =
    if check == nil:
      expectCheck(server)
    else:
      check
  waitFor connect(l.addressOf(serverName), cctx, chk, sig, config, registry)

proc roundTrip(s: TlsStream, body: seq[byte]): Result[seq[byte], string] =
  ?(waitFor s.writeFrame(body))
  let f = ?(waitFor s.readFrame())
  if f.isNone:
    return err("closed")
  ok(f.get.body)

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

  test "[TRN-0221] [IMPL-DECISION G328] a server sends no Transport data before its check passed":
    let seen = Seen()
    let speaksFirst: StreamHandler = proc(
        s: TlsStream
    ): Future[void] {.async: (raises: []), gcsafe.} =
      inc seen.frames
      try:
        discard await s.writeFrame(@[7'u8])
        discard await s.readFrame()
      except CancelledError:
        discard
    let l = serve(
      "127.0.0.1",
      0,
      serverContext(b),
      pinnedCheck([a]),
      keySigner(b.key, tlsServer),
      fastConfig(),
      speaksFirst,
    ).get
    # refused: the handler never runs and the client's first read is a failure
    let refused = l.dial(c, b)
    if refused.isOk:
      check (waitFor refused.get.readFrame()).isErr
      waitFor refused.get.close()
    check waitUntil(
      proc(): bool =
        l.failedHandshakes == 1,
      2000,
    )
    check seen.frames == 0
    # accepted: the same handler speaks first
    let s = l.dial(a, b).get
    let f = waitFor s.readFrame()
    check f.isOk and f.get.isSome and f.get.get.body == @[7'u8]
    check seen.frames == 1
    waitFor s.close()
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
      check (waitFor s.readFrame()).get.get.body == @[byte(i)]
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

  test "[IMPL-DECISION I99] past the connection bound a connection is closed at once, unread, until one ends":
    let seen = Seen()
    var cfg = fastConfig()
    cfg.maxHandshakes = 2
    cfg.maxConnections = 2
    let l = listen(b, seen, [a], config = cfg)
    let s1 = l.dial(a, b).get
    let s2 = l.dial(a, b).get
    check s1.roundTrip(@[1'u8]).isOk
    check s2.roundTrip(@[2'u8]).isOk
    check l.connectionsHeld == 2
    check l.handshakesInProgress == 0
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
    waitFor third.closeWait()
    waitFor s1.close()
    check waitUntil(
      proc(): bool =
        l.connectionsHeld == 1,
      2000,
    )
    let s3 = l.dial(a, b).get
    check s3.roundTrip(@[3'u8]).isOk
    waitFor s2.close()
    waitFor s3.close()
    waitFor l.close()

  test "[IMPL-DECISION I99] a limit below the handshake bound is refused":
    var cfg = fastConfig()
    cfg.maxConnections = cfg.maxHandshakes - 1
    check cfg.check().isErr
    cfg = fastConfig()
    cfg.writeBound = 1024
    check cfg.check().isErr

  test "[IMPL-DECISION I99] output past the write bound is refused with nothing sealed, and the stream stays usable":
    let hold = newAsyncEvent()
    let quiet: StreamHandler = proc(
        s: TlsStream
    ): Future[void] {.async: (raises: []), gcsafe.} =
      # Reads nothing until released, so the sender's output backs up.
      try:
        await hold.wait()
        while true:
          let f = await s.readFrame()
          if f.isErr or f.get.isNone:
            return
      except CancelledError:
        discard
    var cfg = fastConfig()
    cfg.writeBound = 64 * 1024
    let l = serve(
      "127.0.0.1",
      0,
      serverContext(b),
      pinnedCheck([a]),
      keySigner(b.key, tlsServer),
      cfg,
      quiet,
    ).get
    let s = l.dial(a, b, config = cfg).get
    let body = newSeq[byte](32 * 1024)
    var pending: seq[Future[Result[void, string]].Raising([CancelledError])] = @[]
    var refusal = ""
    for i in 0 ..< 4096:
      let w = s.writeFrame(body)
      if w.finished and w.value.isErr:
        refusal = w.value.error
        break
      pending.add(w)
    require refusal.startsWith("output bound")
    # the bound, plus each record's header and tag
    check s.outputRetained <= cfg.writeBound + cfg.writeBound div 256
    let before = s.outputRetained
    check (waitFor s.writeFrame(body)).isErr
    check s.outputRetained == before
    hold.fire()
    for w in pending:
      check (waitFor w).isOk
    check s.outputRetained == 0
    check (waitFor s.writeFrame(body)).isOk
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

# Step 5-2a: the trust snapshot and the enrollment checks ---------------------------------

proc uuid(n: int): string =
  ## A lowercase UUIDv4 for party `n`.
  "00000000-0000-4000-8000-" & align($n, 12, '0')

let
  now = nowPosix()
  clock = fixedClock(now)
  eServer = newParty(uuid(1), extendedKeyUsage = "serverAuth")
  eClient = newParty(uuid(2), extendedKeyUsage = "clientAuth")
  eAny = newParty(uuid(3), extendedKeyUsage = "anyExtendedKeyUsage")
  eBoth = newParty(uuid(4), extendedKeyUsage = "clientAuth,serverAuth")
  kuEnc = newParty(uuid(5), keyUsage = "critical,keyEncipherment")
  expired = newParty(uuid(6), notBefore = now - 2 * 86400, notAfter = now - 86400)
  future = newParty(uuid(7), notBefore = now + 86400, notAfter = now + 2 * 86400)
  noKu = newParty(uuid(8), keyUsage = "")
  expiredKuEnc = newParty(
    uuid(9),
    keyUsage = "critical,keyEncipherment",
    notBefore = now - 2 * 86400,
    notAfter = now - 86400,
  )
  oddParties =
    [eServer, eClient, eAny, eBoth, kuEnc, expired, future, noKu, expiredKuEnc]

proc verdict(
    t: TrustSnapshot, p: Party, role: TlsRole, expected: string, cert: seq[byte] = @[]
): Result[PeerIdentity, string] =
  checkPeer(t, @[(if cert.len > 0: cert else: p.cert)], role, expected, clock())

proc reason(r: Result[PeerIdentity, string]): string =
  if r.isOk: "ok" else: r.error

suite "tls.trust":
  test "[IMPL-DECISION I99] Runtime ids are lowercase UUIDv4 (RUNTIME l.2670); the snapshot refuses malformed protected input":
    check isRuntimeId(IdA)
    check isRuntimeId(uuid(1))
    for bad in [
      "", IdA.toUpperAscii, "0b6f3c3e-9d0f-1c1a-8f43-7a8f2b9b1a01",
      "0b6f3c3e-9d0f-4c1a-7f43-7a8f2b9b1a01", "0b6f3c3e9d0f4c1a8f437a8f2b9b1a01",
      "0b6f3c3e-9d0f-4c1a-8f43-7a8f2b9b1a0g",
    ]:
      check not isRuntimeId(bad)
    let anchors = @[(a.anchorId, a.cert)]
    check newTrustSnapshot(1, anchors, [activeRecord(a)]).isOk
    var upper = activeRecord(a)
    upper.runtime = IdA.toUpperAscii
    check newTrustSnapshot(1, anchors, [upper]).isErr
    var unknownAnchor = activeRecord(a)
    unknownAnchor.anchor = "nope"
    check newTrustSnapshot(1, anchors, [unknownAnchor]).isErr
    check newTrustSnapshot(
      1, anchors, [activeRecord(a, keys = @[a.spki, b.spki, c.spki])]
    ).isErr
    check newTrustSnapshot(1, anchors, [activeRecord(a, keys = @[a.spki, a.spki])]).isErr
    check newTrustSnapshot(1, anchors, [activeRecord(a), activeRecord(a, 2)]).isErr
    check newTrustSnapshot(1, anchors & anchors, [activeRecord(a)]).isErr
    let t =
      newTrustSnapshot(3, anchors, [activeRecord(a, keys = @[a.spki, b.spki])]).get
    check t.anchorRevision == 3
    check t.holdersOf(b.spki).len == 1

  test "[TRN-0216] [TRN-0217] a presented credential creates or alters nothing: an unknown key fails, again, and the snapshot is unchanged":
    let t = enrolled([a, b])
    let before = (t.anchorCount, t.recordCount)
    for i in 0 ..< 3:
      check verdict(t, c, tlsClient, "").reason.startsWith("3 enrollment")
      check verdict(t, c, tlsServer, IdC).reason.startsWith("3 enrollment")
    check (t.anchorCount, t.recordCount) == before
    check t.record(IdC).isNone
    check t.holdersOf(c.spki).len == 0

suite "tls.verify":
  test "[TRN-0223] [TRN-0224] [TRN-0225] [TRN-0374] [IMPL-DECISION G324] the expected Runtime's active record, or the one record that holds an inbound key; the direct anchor passes on its active status":
    let t = enrolled([a, b])
    let toB = verdict(t, b, tlsServer, IdB)
    check toB.isOk
    check toB.get == PeerIdentity(runtime: IdB, revision: 1, anchor: b.anchorId)
    let fromA = verdict(t, a, tlsClient, "")
    check fromA.isOk
    check fromA.get.runtime == IdA
    # another Runtime's certificate for the expected one
    check verdict(t, a, tlsServer, IdB).reason.startsWith("4 key")

  test "[TRN-0375] [IMPL-DECISION G325] no accepted current time fails first; the system clock is accepted only at or past the floor":
    let t = enrolled([a])
    check checkPeer(t, @[a.cert], tlsClient, "", noClock()()).reason.startsWith(
      "1 time"
    )
    check checkPeer(t, @[], tlsClient, "", noClock()()).reason.startsWith("1 time")
    let sys = systemClock()()
    check sys.isOk
    check sys.get >= TimeFloor

  test "[TRN-0224] [TRN-0370] [TRN-0374] [TRN-0375] [IMPL-DECISION G324] one certificate, the direct anchor: a chain, a re-issued certificate for the same key or no certificate fails":
    let t = enrolled([a, b])
    check checkPeer(t, @[a.cert, b.cert], tlsClient, "", clock()).reason.startsWith(
      "2 chain"
    )
    check checkPeer(t, @[], tlsClient, "", clock()).reason.startsWith("2 chain")
    check checkPeer(t, @[@[1'u8, 2, 3]], tlsClient, "", clock()).reason.startsWith(
      "2 chain"
    )
    let reissued = a.key.selfSignedCertificate(
      CertificateOptions(
        commonName: IdA,
        notBefore: now - 3600,
        notAfter: now + 86400,
        keyUsage: ServerKu,
      )
    ).get
    check certificateSpki(reissued).get == a.spki
    check verdict(t, a, tlsClient, "", reissued).reason.startsWith("5 anchor")
    check verdict(t, a, tlsServer, IdA, reissued).reason.startsWith("5 anchor")

  test "[TRN-0226] no match, several Runtimes, a conflicting, revoked or stale enrollment: each fails authentication":
    # inbound: no record holds the key
    check verdict(enrolled([a]), b, tlsClient, "").reason.startsWith("3 enrollment: no")
    # inbound: two Runtimes hold the key
    let two =
      snapshotOf([a, b], [activeRecord(a), activeRecord(b, keys = @[b.spki, a.spki])])
    check verdict(two, a, tlsClient, "").reason ==
      "3 enrollment: 2 Runtimes hold this key"
    # conflicting: inbound by key, outbound by name
    let conflict = snapshotOf(
      [a, b],
      [
        activeRecord(a),
        EnrollmentRecord(
          runtime: IdB, revision: 4, status: rsConflicting, spkis: @[b.spki, c.spki]
        ),
      ],
    )
    check verdict(conflict, b, tlsClient, "").reason.contains("conflicting")
    check verdict(conflict, c, tlsClient, "").reason.contains("conflicting")
    check verdict(conflict, b, tlsServer, IdB).reason.contains("conflicting")
    check verdict(conflict, a, tlsClient, "").isOk
    # revoked: outbound by name; inbound its key is held by no active record
    let revoked = snapshotOf(
      [a, b],
      [activeRecord(a), EnrollmentRecord(runtime: IdB, revision: 5, status: rsRevoked)],
    )
    check verdict(revoked, b, tlsServer, IdB).reason.contains("revoked")
    check verdict(revoked, b, tlsClient, "").reason.startsWith("3 enrollment: no")
    # stale: only the current revision reaches the snapshot; its new key
    # replaced the old one
    let rotated = snapshotOf([a, c], [activeRecord(a, 2, keys = @[c.spki])])
    check verdict(rotated, a, tlsServer, IdA).reason.startsWith("4 key")
    check verdict(rotated, a, tlsClient, "").reason.startsWith("3 enrollment")

  test "[TRN-0226] [IMPL-DECISION G324] a caller also refuses a target whose key another Runtime's current record holds":
    let two =
      snapshotOf([a, b], [activeRecord(a), activeRecord(b, keys = @[b.spki, a.spki])])
    check verdict(two, a, tlsServer, IdA).reason ==
      "3 enrollment: 2 Runtimes hold this key"
    let conflicting = snapshotOf(
      [a],
      [
        activeRecord(a),
        EnrollmentRecord(
          runtime: IdB, revision: 4, status: rsConflicting, spkis: @[a.spki]
        ),
      ],
    )
    check verdict(conflicting, a, tlsServer, IdA).reason ==
      "3 enrollment: 2 Runtimes hold this key"
    # a revoked record names no key, so it holds none
    let revoked = snapshotOf(
      [a],
      [activeRecord(a), EnrollmentRecord(runtime: IdB, revision: 5, status: rsRevoked)],
    )
    check verdict(revoked, a, tlsServer, IdA).isOk

  test "[TRN-0371] the validity period at accepted current time, also for the direct anchor":
    let t = enrolled(oddParties)
    check verdict(t, expired, tlsClient, "").reason.startsWith("6 validity")
    check verdict(t, future, tlsServer, future.id).reason.startsWith("6 validity")
    check checkPeer(
      t, @[expired.cert], tlsClient, "", fixedClock(now - 2 * 86400 + 60)()
    ).isOk

  test "[TRN-0372] Key Usage, when present, must permit digital signatures":
    let t = enrolled(oddParties)
    check verdict(t, kuEnc, tlsClient, "").reason.startsWith("7 key usage")
    check verdict(t, noKu, tlsClient, "").isOk

  test "[TRN-0373] Extended Key Usage, when present, must name the role; anyExtendedKeyUsage alone does not":
    let t = enrolled(oddParties)
    check verdict(t, eServer, tlsServer, eServer.id).isOk
    check verdict(t, eServer, tlsClient, "").reason.startsWith("8 extended key usage")
    check verdict(t, eClient, tlsClient, "").isOk
    check verdict(t, eClient, tlsServer, eClient.id).reason.startsWith("8")
    check verdict(t, eAny, tlsClient, "").reason.startsWith("8")
    check verdict(t, eAny, tlsServer, eAny.id).reason.startsWith("8")
    check verdict(t, eBoth, tlsClient, "").isOk
    check verdict(t, eBoth, tlsServer, eBoth.id).isOk

  test "[TRN-0370] [IMPL-DECISION G324] a critical extension path validation would not process fails":
    let odd = withCriticalExtension(c)
    let t = snapshotOf([c], [activeRecord(c)])
    let t2 = newTrustSnapshot(1, @[(c.anchorId, odd)], [activeRecord(c)]).get
    check checkPeer(t2, @[odd], tlsClient, "", clock()).reason.startsWith(
      "9 extensions"
    )
    check verdict(t, c, tlsClient, "").isOk

  test "[IMPL-DECISION G324] the first failing check is the one reported":
    let t = enrolled(oddParties)
    # expired and without digitalSignature: validity (6) comes before key usage (7)
    check verdict(t, expiredKuEnc, tlsClient, "").reason.startsWith("6 validity")
    # a stranger's chain of two: the chain (2) comes before the enrollment (3)
    check checkPeer(t, @[c.cert, c.cert], tlsClient, "", clock()).reason.startsWith(
      "2 chain"
    )

suite "tls.enrollment handshakes":
  test "[TRN-0221] [TRN-0222] [TRN-0223] [TRN-0225] both ends authenticate through their enrollments before any Transport data":
    let t = enrolled([a, b])
    let seen = Seen()
    let l = listen(b, seen, [], check = anyEnrolled(t, clock))
    let s = l.dial(a, b, check = expectRuntime(t, IdB, clock)).get
    check s.peer == PeerIdentity(runtime: IdB, revision: 1, anchor: b.anchorId)
    check s.roundTrip(@[3'u8]).get == @[3'u8]
    check seen.peers == @[IdA]
    waitFor s.close()
    waitFor l.close()

  test "[TRN-0222] the caller refuses a target that is not the Runtime it named":
    let t = enrolled([a, b, c])
    let seen = Seen()
    let l = listen(c, seen, [], check = anyEnrolled(t, clock))
    let r = l.dial(a, c, check = expectRuntime(t, IdB, clock))
    check r.isErr
    check "4 key" in r.error
    check waitUntil(
      proc(): bool =
        l.failedHandshakes == 1,
      2000,
    )
    check seen.peers.len == 0
    waitFor l.close()

  test "[TRN-0221] [TRN-0226] an unenrolled, revoked or conflicting caller is refused and closed; its frames are never read":
    let cases = [
      ("unenrolled", enrolled([b])),
      (
        "revoked",
        snapshotOf(
          [a, b],
          [
            activeRecord(b),
            EnrollmentRecord(runtime: IdA, revision: 2, status: rsRevoked),
          ],
        ),
      ),
      (
        "conflicting",
        snapshotOf(
          [a, b],
          [
            activeRecord(b),
            EnrollmentRecord(
              runtime: IdA, revision: 2, status: rsConflicting, spkis: @[a.spki]
            ),
          ],
        ),
      ),
    ]
    for (name, t) in cases:
      checkpoint name
      let seen = Seen()
      let l = listen(b, seen, [], check = anyEnrolled(t, clock))
      let r = l.dial(a, b, check = expectRuntime(t, IdB, clock))
      if r.isOk:
        # TLS 1.3: the client finishes before the server has checked it (G328).
        discard waitFor r.get.writeFrame(@[1'u8])
        check (waitFor r.get.readFrame()).isErr
        waitFor r.get.close()
      check waitUntil(
        proc(): bool =
          l.failedHandshakes == 1,
        2000,
      )
      check "3 enrollment" in l.lastFailure
      check seen.peers.len == 0
      check seen.frames == 0
      waitFor l.close()

# G128: an independent peer (pyOpenSSL, so OpenSSL against BoringSSL) -----------------------

when (defined(linux) or defined(macosx)) and not defined(android) and not defined(ios):
  import std/tables
  import ./support/tlspeers

  const PeerId = IdC

  proc peerTrust(own: Party, peerCert: seq[byte]): TrustSnapshot =
    ## `own` and the peer, each enrolled with its certificate as direct anchor.
    let peerRecord = EnrollmentRecord(
      runtime: PeerId,
      revision: 1,
      status: rsActive,
      anchor: "peer-anchor",
      spkis: @[certificateSpki(peerCert).get],
    )
    newTrustSnapshot(
      7,
      [(own.anchorId, own.cert), ("peer-anchor", peerCert)],
      [activeRecord(own), peerRecord],
    ).get

  proc dialPeer(
      peer: PyPeer, own: Party, t: TrustSnapshot, serverName = ""
  ): Result[TlsStream, string] =
    waitFor connect(
      TlsTcpAddress(host: "127.0.0.1", port: peer.port, serverName: serverName),
      clientContext(own),
      expectRuntime(t, PeerId, fixedClock(nowPosix())),
      keySigner(own.key, tlsClient),
      fastConfig(10_000 * Slow),
    )

  proc pattern(n: int): seq[byte] =
    ## More than one TLS record's worth of bytes.
    result = newSeq[byte](n)
    for i in 0 ..< n:
      result[i] = byte(i mod 251)

  suite "tls.independent peer":
    test "[TRN-0219] [TRN-0220] [TRN-0228] [TRN-0233] [TRN-0376] [IMPL-DECISION G128] our client and a pyOpenSSL server: TLS 1.3, both certificates checked, the same exporter, a clean close":
      if peerPython().len == 0:
        skip()
      else:
        let bench = newPeerBench(a.cert)
        var peer = bench.startServer()
        let r = peer.dialPeer(a, peerTrust(a, bench.cert), "peer.example")
        checkpoint(if r.isErr: r.error else: "connected")
        check r.isOk
        var binding: seq[byte]
        if r.isOk:
          let s = r.get
          check s.peer.runtime == PeerId
          check s.engine.version == TLS1_3_VERSION.int
          binding = s.takeChannelBinding().get
          check binding.len == ChannelBindingLen
          let body = pattern(100_000)
          let echoed = s.roundTrip(body)
          check echoed.isOk and echoed.get == body
          waitFor s.close()
        let report = peer.finish()
        checkpoint $report
        check report.getOrDefault("exit") == "0"
        check report.getOrDefault("handshake") == "ok"
        check report.getOrDefault("version") == "TLSv1.3"
        check report.getOrDefault("group") == "X25519MLKEM768"
        check report.getOrDefault("binding") == hexOf(binding)
        check report.getOrDefault("sni") == "peer.example"
        check report.getOrDefault("close") == "clean"
        bench.remove()

    test "[TRN-0219] [TRN-0220] [TRN-0228] [TRN-0233] [IMPL-DECISION G128] a pyOpenSSL client and our server: TLS 1.3, both certificates checked, the same exporter, a clean close":
      if peerPython().len == 0:
        skip()
      else:
        let bench = newPeerBench(a.cert)
        let seen = Seen()
        let l = listen(
          a,
          seen,
          [],
          config = fastConfig(10_000 * Slow),
          check = anyEnrolled(peerTrust(a, bench.cert), fixedClock(nowPosix())),
        )
        var peer = bench.startClient(l.localPort)
        let report = peer.finish()
        checkpoint $report
        check report.getOrDefault("exit") == "0"
        check report.getOrDefault("handshake") == "ok"
        check report.getOrDefault("version") == "TLSv1.3"
        check report.getOrDefault("group") == "X25519MLKEM768"
        check report.getOrDefault("echo") == "ok"
        check report.getOrDefault("close") == "clean"
        check seen.peers == @[PeerId]
        check seen.versions == @[TLS1_3_VERSION.int]
        check seen.frames == 1
        check seen.readErrors.len == 0
        check seen.bindings.len == 1
        if seen.bindings.len == 1:
          check seen.bindings[0].len == ChannelBindingLen
          check hexOf(seen.bindings[0]) == report.getOrDefault("binding")
        waitFor l.close()
        bench.remove()

    test "[TRN-0219] [IMPL-DECISION G128] a pyOpenSSL server and a pyOpenSSL client that stop at TLS 1.2 are refused":
      if peerPython().len == 0:
        skip()
      else:
        let bench = newPeerBench(a.cert)
        var server = bench.startServer(["--tls12"])
        let r = server.dialPeer(a, peerTrust(a, bench.cert))
        check r.isErr
        if r.isErr:
          check "PROTOCOL_VERSION" in r.error
        let serverReport = server.finish()
        checkpoint $serverReport
        check serverReport.getOrDefault("exit") == "0"
        check serverReport.getOrDefault("handshake") == "failed"

        let seen = Seen()
        let l = listen(
          a,
          seen,
          [],
          check = anyEnrolled(peerTrust(a, bench.cert), fixedClock(nowPosix())),
        )
        var client = bench.startClient(l.localPort, ["--tls12"])
        let clientReport = client.finish()
        checkpoint $clientReport
        check clientReport.getOrDefault("exit") == "0"
        check clientReport.getOrDefault("handshake") == "failed"
        check waitUntil(
          proc(): bool =
            l.failedHandshakes == 1,
          2000,
        )
        check "UNSUPPORTED_PROTOCOL" in l.lastFailure
        check seen.peers.len == 0
        waitFor l.close()
        bench.remove()

    test "[TRN-0220] [TRN-0233] [IMPL-DECISION G128] [IMPL-DECISION G328] a pyOpenSSL client with no certificate is refused and its frame is never read":
      if peerPython().len == 0:
        skip()
      else:
        let bench = newPeerBench(a.cert)
        let seen = Seen()
        let l = listen(
          a,
          seen,
          [],
          check = anyEnrolled(peerTrust(a, bench.cert), fixedClock(nowPosix())),
        )
        var peer = bench.startClient(l.localPort, ["--no-cert"])
        let report = peer.finish()
        checkpoint $report
        check report.getOrDefault("exit") == "0"
        check report.getOrDefault("echo", "ok") != "ok"
        check waitUntil(
          proc(): bool =
            l.failedHandshakes == 1,
          2000,
        )
        check seen.peers.len == 0
        check seen.frames == 0
        waitFor l.close()
        bench.remove()

    test "[TRN-0219] [IMPL-DECISION G326] [IMPL-DECISION G128] a pyOpenSSL server that has only P-256 is reached through HelloRetryRequest":
      # Our first ClientHello carries no P-256 key share, so this group is only
      # reachable after the server asks for one.
      if peerPython().len == 0:
        skip()
      else:
        let bench = newPeerBench(a.cert)
        var peer = bench.startServer(["--p256-only"])
        let r = peer.dialPeer(a, peerTrust(a, bench.cert))
        checkpoint(if r.isErr: r.error else: "connected")
        check r.isOk
        var binding: seq[byte]
        if r.isOk:
          let s = r.get
          binding = s.takeChannelBinding().get
          let echoed = s.roundTrip(@[7'u8])
          check echoed.isOk and echoed.get == @[7'u8]
          waitFor s.close()
        let report = peer.finish()
        checkpoint $report
        check report.getOrDefault("exit") == "0"
        check report.getOrDefault("group") == "secp256r1"
        check report.getOrDefault("binding") == hexOf(binding)
        bench.remove()

# G327: erasure of decrypted data -----------------------------------------------------------

proc arm(patterns: sink seq[seq[byte]]) =
  ## The patterns are taken and zeroed once registered: pass copies.
  armWipeAudit(patterns)

proc hits(): int =
  ## Blocks released holding a pattern since arming; the backtraces go to stderr.
  result = wipeAuditHits()
  if result > 0:
    reportWipeAudit()

type Sink = ref object
  frames: int
  bytes: int
  done: bool

proc wipingHandler(sink: Sink): StreamHandler =
  ## Reads frames to the end, erasing each, as an owner of marked data must.
  result = proc(s: TlsStream): Future[void] {.async: (raises: []), gcsafe.} =
    try:
      while true:
        var f = await s.readFrame()
        if f.isErr or f.get.isNone:
          break
        inc sink.frames
        sink.bytes += f.get.get.body.len
        wipe(f.get.get)
    except CancelledError:
      discard
    sink.done = true

suite "tls.erasure":
  test "[IMPL-DECISION G327] this build's BoringSSL zeroes its record buffers, so the carrier takes marked payloads":
    check recordBuffersErased
    check carrierErases()
    check requireErasure().isOk
    var cfg = fastConfig()
    cfg.carriesMarked = true
    let seen = Seen()
    let l = listen(b, seen, [a], config = cfg)
    let s = l.dial(a, b, config = cfg).get
    check s.roundTrip(@[1'u8]).isOk
    waitFor s.close()
    waitFor l.close()

  test "[IMPL-DECISION G277] [IMPL-DECISION G327] a carrier whose TLS library leaves records unerased refuses marked payloads, on both sides":
    recordErasureMissingForTests = true
    var cfg = fastConfig()
    cfg.carriesMarked = true
    check not carrierErases()
    let r = serve(
      "127.0.0.1",
      0,
      serverContext(b),
      pinnedCheck([a]),
      keySigner(b.key, tlsServer),
      cfg,
      echoHandler(Seen()),
    )
    check r.isErr
    check "BORINGSSL_ZERO_RECORD_BUFFERS" in r.error
    let seen = Seen()
    let l = listen(b, seen, [a])
    let refused = l.dial(a, b, config = cfg)
    check refused.isErr
    check MarkedUnsupported in refused.error
    # unmarked traffic is unaffected
    let s = l.dial(a, b).get
    check s.roundTrip(@[2'u8]).isOk
    recordErasureMissingForTests = false
    waitFor s.close()
    waitFor l.close()
    check seen.peers == @[IdA]

  test "[IMPL-DECISION G327] no released block holds decrypted data: BoringSSL's record buffers and the carrier's own copies are erased":
    if not wipeAuditScans():
      skip()
    else:
      var marker = urandom(32)
      var data = newSeq[byte](256 * 1024)
      for i in 0 ..< data.len:
        data[i] = marker[i mod marker.len]
      let sink = Sink()
      let l = serve(
        "127.0.0.1",
        0,
        serverContext(b),
        pinnedCheck([a]),
        keySigner(b.key, tlsServer),
        fastConfig(),
        wipingHandler(sink),
      ).get
      let s = l.dial(a, b).get
      arm(@[marker])
      # the control: a copy released unerased is found
      var leak = data[0 ..< 64]
      leak = @[]
      check wipeAuditHits() >= 1
      disarmWipeAudit()
      arm(@[marker])
      for i in 0 ..< 4:
        check (waitFor s.writeFrame(data.toOpenArray(i * 65536, i * 65536 + 65535))).isOk
      waitFor s.close()
      check waitUntil(
        proc(): bool =
          sink.done,
        5000,
      )
      check sink.frames == 4
      check sink.bytes == data.len
      waitFor l.close()
      check hits() == 0
      disarmWipeAudit()
      wipe(data)
      wipe(marker)

freeContexts()
for p in [a, b, c]:
  p.free()
for p in oddParties:
  p.free()
