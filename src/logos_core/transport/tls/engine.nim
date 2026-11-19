## TRANSPORT §8.4.1; I99, G326, G328: one TLS 1.3 connection with mutual
## authentication, sans-I/O. An engine owns one BoringSSL connection between
## two memory buffers: the caller feeds it what the socket delivered, sends what
## it produced, answers its signing requests (`signing.nim`), and reads and
## writes application bytes once it is established. It never blocks and does no
## I/O, so the chronos driver (`stream.nim`) and any other loop can drive it.
##
## The peer's certificates are checked inside the handshake by the `PeerCheck`
## the engine was given (the enrollment checks of 5-2a, or a test's), before
## either side has sent or accepted any application data.

{.push raises: [].}

import results
import logos_sdk/base/[testhooks, wipe]
import ./[boring, params, signing]

export results, signing

testHooksMarker("tls_engine")

type
  PeerIdentity* = object
    ## Who the peer authenticated as: its Runtime id, and the enrollment
    ## revision and trust anchor that admitted it.
    runtime*: string
    revision*: uint64
    anchor*: string

  PeerCheck* = proc(
    chain: seq[seq[byte]], peerRole: TlsRole
  ): Result[PeerIdentity, string] {.gcsafe, raises: [].}
    ## Checks the certificates the peer presented (DER, leaf first) for a peer
    ## acting as `peerRole`: who it is, or why it fails. It runs inside the
    ## handshake; a failure ends the handshake with a `bad_certificate` alert.

  TlsContext* = ref object
    ## One side's settings (G326) and its certificate, shared by its engines.
    ## The private key is not here: every signature comes from the `Signer`.
    ctx: ptr SSL_CTX
    role: TlsRole

  Progress* = enum
    prNeedInput ## send `takeOutput`, then feed what the peer sends
    prNeedSignature ## answer `signRequest` with `answerSignature`
    prEstablished ## authenticated; application data may flow
    prFailed ## see `failure`; send `takeOutput` (an alert) and close

  ReadKind* = enum
    rdData ## `n` bytes were read
    rdNeedInput ## feed more input
    rdClosed ## the peer sent close_notify: a clean end
    rdFailed ## see `failure`

  ReadOutcome* = object
    kind*: ReadKind
    n*: int

  TlsEngine* = ref object
    ssl: ptr SSL
    rbio: ptr BIO
    wbio: ptr BIO
    role: TlsRole
    check: PeerCheck
    peer: PeerIdentity
    checkError: string
    signAlg: uint16
    signInput: seq[byte]
    signWanted: bool
    answer: SignResult
    answered: bool
    established: bool
    inputEnded: bool
    failure: string
    sessionsOffered: int

const MaxRecordPlaintext = 16 * 1024 ## RFC 8446 §5.1

let exIndex = SSL_get_ex_new_index(0, nil, nil, nil, nil)
  ## The SSL object's slot that points back to its engine.

proc engineOf(ssl: ptr SSL): TlsEngine =
  cast[TlsEngine](SSL_get_ex_data(ssl, exIndex))

proc cbSign(
    ssl: ptr SSL,
    outp: ptr uint8,
    outLen: ptr csize_t,
    maxOut: csize_t,
    alg: uint16,
    inp: ptr uint8,
    inLen: csize_t,
): enum_ssl_private_key_result_t {.cdecl.} =
  ## BoringSSL asks for a CertificateVerify signature: record the input and
  ## suspend the handshake until `answerSignature`.
  let e = engineOf(ssl)
  if e == nil:
    return ssl_private_key_failure
  e.signAlg = alg
  e.signInput = copyBytes(inp, int(inLen))
  e.signWanted = true
  e.answered = false
  ssl_private_key_retry

proc cbComplete(
    ssl: ptr SSL, outp: ptr uint8, outLen: ptr csize_t, maxOut: csize_t
): enum_ssl_private_key_result_t {.cdecl.} =
  let e = engineOf(ssl)
  if e == nil:
    return ssl_private_key_failure
  if not e.answered:
    return ssl_private_key_retry
  e.signWanted = false
  case e.answer.status
  of ssSigned:
    let n = e.answer.signature.len
    if n == 0 or csize_t(n) > maxOut:
      e.failure = "the signer's signature does not fit"
      return ssl_private_key_failure
    copyMem(outp, addr e.answer.signature[0], n)
    outLen[] = csize_t(n)
    ssl_private_key_success
  of ssRefused:
    e.failure = "the signer refused the handshake signature"
    ssl_private_key_failure
  of ssUnavailable:
    e.failure = "no signer answered"
    ssl_private_key_failure

var keyMethod = SSL_PRIVATE_KEY_METHOD(sign: cbSign, decrypt: nil, complete: cbComplete)

proc peerChain(ssl: ptr SSL): seq[seq[byte]] =
  result = @[]
  let sk = cast[ptr OPENSSL_STACK](SSL_get0_peer_certificates(ssl))
  if sk == nil:
    return
  for i in 0 ..< int(OPENSSL_sk_num(sk)):
    let b = cast[ptr CRYPTO_BUFFER](OPENSSL_sk_value(sk, csize_t(i)))
    result.add(copyBytes(CRYPTO_BUFFER_data(b), int(CRYPTO_BUFFER_len(b))))

proc cbVerify(ssl: ptr SSL, alert: ptr uint8): enum_ssl_verify_result_t {.cdecl.} =
  ## [SPEC TRANSPORT §8.4.1] l.1240-1241: the peer's credential is checked
  ## before the handshake completes, so before any Transport Hello.
  let e = engineOf(ssl)
  if e == nil or e.check == nil:
    alert[] = AlertInternalError
    return ssl_verify_invalid
  let peerRole = if e.role == tlsClient: tlsServer else: tlsClient
  let r = e.check(peerChain(ssl), peerRole)
  if r.isOk:
    e.peer = r.get
    ssl_verify_ok
  else:
    e.checkError = r.error
    alert[] = AlertBadCertificate
    ssl_verify_invalid

proc cbNewSession(ssl: ptr SSL, sess: ptr SSL_SESSION): cint {.cdecl.} =
  ## Counts sessions offered for resumption; none is kept (T l.1296).
  let e = engineOf(ssl)
  if e != nil:
    inc e.sessionsOffered
  0

proc makeContext(
    role: TlsRole, certificate: openArray[byte], withCertificate: bool
): Result[TlsContext, string] =
  let ctx = SSL_CTX_new(TLS_method())
  if ctx == nil:
    return err("cannot make a TLS context: " & sslErrors())
  let c = TlsContext(ctx: ctx, role: role)
  var algs = [SigAlgEcdsaP256Sha256]
  # [SPEC TRANSPORT §8.4.1] TLS 1.3 only (l.1235-1236); no resumption, no early
  # data (l.1296); one signature algorithm both ways (l.1238-1239, G326).
  let configured =
    SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION.uint16) == 1 and
    SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION.uint16) == 1 and
    SSL_CTX_set_num_tickets(ctx, 0) == 1 and
    SSL_CTX_set_signing_algorithm_prefs(ctx, addr algs[0], 1) == 1 and
    SSL_CTX_set_verify_algorithm_prefs(ctx, addr algs[0], 1) == 1 and
    SSL_CTX_set1_groups_list(ctx, GroupsList) == 1
  if not configured:
    SSL_CTX_free(ctx)
    return err("cannot configure the TLS context: " & sslErrors())
  discard SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_OFF.cint)
  discard SSL_CTX_set_options(ctx, SSL_OP_NO_TICKET.uint32)
  SSL_CTX_set_early_data_enabled(ctx, 0)
  SSL_CTX_sess_set_new_cb(ctx, cbNewSession)
  if withCertificate:
    if certificate.len == 0 or
        SSL_CTX_use_certificate_ASN1(
          ctx, csize_t(certificate.len), unsafeAddr certificate[0]
        ) != 1:
      SSL_CTX_free(ctx)
      return err("cannot use the certificate: " & sslErrors())
    SSL_CTX_set_private_key_method(ctx, addr keyMethod)
  # [SPEC TRANSPORT §8.4.1] mutual authentication (l.1237): a client must
  # present a certificate, and every peer's is checked by the `PeerCheck`.
  SSL_CTX_set_custom_verify(
    ctx, cint(SSL_VERIFY_PEER or SSL_VERIFY_FAIL_IF_NO_PEER_CERT), cbVerify
  )
  ok(c)

proc newTlsContext*(
    role: TlsRole, certificate: openArray[byte]
): Result[TlsContext, string] =
  ## Settings for `role` with `certificate` (DER), whose key the `Signer` of
  ## each connection holds.
  makeContext(role, certificate, true)

proc free*(c: TlsContext) =
  ## Frees the settings; engines made from them keep what they need.
  if c != nil and c.ctx != nil:
    SSL_CTX_free(c.ctx)
    c.ctx = nil

proc role*(c: TlsContext): TlsRole =
  c.role

proc newEngine*(
    c: TlsContext, check: PeerCheck, serverName = ""
): Result[TlsEngine, string] =
  ## A connection in `c`'s role. A client sends `serverName` as SNI `host_name`
  ## when it is not empty (T l.1271); a server ignores it.
  if c == nil or c.ctx == nil:
    return err("no TLS context")
  if check == nil:
    return err("no peer check")
  if c.role == tlsClient and serverName.len > 0:
    ?checkServerName(serverName)
  let ssl = SSL_new(c.ctx)
  if ssl == nil:
    return err("cannot make a TLS connection: " & sslErrors())
  let rbio = BIO_new(BIO_s_mem())
  let wbio = BIO_new(BIO_s_mem())
  if rbio == nil or wbio == nil:
    if rbio != nil:
      discard BIO_free(rbio)
    if wbio != nil:
      discard BIO_free(wbio)
    SSL_free(ssl)
    return err("out of memory")
  # A read from an empty input buffer means "wait" until the input ends.
  discard BIO_set_mem_eof_return(rbio, -1)
  SSL_set_bio(ssl, rbio, wbio)
  let e = TlsEngine(ssl: ssl, rbio: rbio, wbio: wbio, role: c.role, check: check)
  if SSL_set_ex_data(ssl, exIndex, cast[pointer](e)) != 1:
    SSL_free(ssl)
    return err("cannot link the TLS connection: " & sslErrors())
  case c.role
  of tlsClient:
    SSL_set_connect_state(ssl)
    if serverName.len > 0 and SSL_set_tlsext_host_name(ssl, serverName.cstring) != 1:
      SSL_free(ssl)
      return err("cannot set SNI: " & sslErrors())
  of tlsServer:
    SSL_set_accept_state(ssl)
  ok(e)

proc free*(e: TlsEngine) =
  ## Frees the connection and both buffers; the engine answers nothing after.
  if e != nil and e.ssl != nil:
    discard SSL_set_ex_data(e.ssl, exIndex, nil)
    SSL_free(e.ssl)
    e.ssl = nil
    e.rbio = nil
    e.wbio = nil
    wipe(e.answer.signature)
    if e.failure.len == 0:
      e.failure = "closed"

proc isFreed*(e: TlsEngine): bool =
  e.ssl == nil

proc fail(e: TlsEngine, what: string, r: cint) =
  if e.failure.len > 0:
    discard sslErrors()
    return
  if e.checkError.len > 0:
    e.failure = "peer check failed: " & e.checkError
    discard sslErrors()
    return
  let code = SSL_get_error(e.ssl, r)
  let detail = sslErrors()
  e.failure =
    if e.inputEnded and code in [SSL_ERROR_SYSCALL.cint, SSL_ERROR_ZERO_RETURN.cint] and
        detail.len == 0:
      what & ": the transport ended"
    else:
      what & ": TLS error " & $code & (if detail.len > 0: ": " & detail
      else: "")

proc feed*(e: TlsEngine, data: openArray[byte]) =
  ## Ciphertext the peer sent.
  if e.ssl == nil or data.len == 0:
    return
  discard BIO_write(e.rbio, unsafeAddr data[0], cint(data.len))

proc feedEnd*(e: TlsEngine) =
  ## The transport ended: no more input will come.
  e.inputEnded = true
  if e.ssl != nil:
    discard BIO_set_mem_eof_return(e.rbio, 0)

proc inputBuffered*(e: TlsEngine): int =
  ## Ciphertext fed and not yet consumed.
  if e.ssl == nil:
    0
  else:
    int(BIO_pending(e.rbio))

proc pendingOutput*(e: TlsEngine): int =
  if e.ssl == nil:
    0
  else:
    int(BIO_pending(e.wbio))

proc takeOutput*(e: TlsEngine, maxLen = 64 * 1024): seq[byte] =
  ## Up to `maxLen` bytes of ciphertext to send, in order.
  let n = min(e.pendingOutput, maxLen)
  if n == 0:
    return @[]
  result = newSeq[byte](n)
  let got = BIO_read(e.wbio, addr result[0], cint(n))
  result.setLen(max(int(got), 0))

proc advance*(e: TlsEngine): Progress =
  ## Runs the handshake as far as the input allows.
  if e.failure.len > 0 or e.ssl == nil:
    return prFailed
  if e.established:
    return prEstablished
  if e.signWanted and not e.answered:
    return prNeedSignature
  ERR_clear_error()
  let r = SSL_do_handshake(e.ssl)
  if r == 1:
    e.established = true
    return prEstablished
  let code = SSL_get_error(e.ssl, r)
  if code == SSL_ERROR_WANT_READ:
    if e.inputEnded and e.inputBuffered == 0:
      e.failure = "handshake: the transport ended"
      return prFailed
    return prNeedInput
  if code == SSL_ERROR_WANT_PRIVATE_KEY_OPERATION and e.signWanted:
    return prNeedSignature
  e.fail("handshake", r)
  prFailed

proc signRequest*(e: TlsEngine): tuple[role: TlsRole, alg: uint16, input: seq[byte]] =
  ## What `advance` is waiting to have signed (`prNeedSignature`).
  (e.role, e.signAlg, e.signInput)

proc answerSignature*(e: TlsEngine, r: SignResult) =
  ## The signer's answer; the next `advance` goes on (or fails, for a refusal).
  if e.signWanted:
    e.answer = r
    e.answered = true

proc readApp*(e: TlsEngine, dst: var openArray[byte]): ReadOutcome =
  ## Application bytes into `dst`, once established.
  if e.ssl == nil or not e.established or e.failure.len > 0 or dst.len == 0:
    return ReadOutcome(kind: rdFailed, n: 0)
  ERR_clear_error()
  let r = SSL_read(e.ssl, addr dst[0], cint(min(dst.len, high(cint).int)))
  if r > 0:
    return ReadOutcome(kind: rdData, n: int(r))
  let code = SSL_get_error(e.ssl, r)
  if code == SSL_ERROR_ZERO_RETURN:
    return ReadOutcome(kind: rdClosed, n: 0)
  if code == SSL_ERROR_WANT_READ and not (e.inputEnded and e.inputBuffered == 0):
    return ReadOutcome(kind: rdNeedInput, n: 0)
  if code == SSL_ERROR_WANT_READ:
    e.failure = "read: the transport ended without close_notify"
  else:
    e.fail("read", r)
  ReadOutcome(kind: rdFailed, n: 0)

proc writeApp*(e: TlsEngine, src: openArray[byte]): Result[void, string] =
  ## Application bytes, sealed into records in `takeOutput`. The output buffer
  ## grows as needed: the driver bounds how much it lets wait.
  if e.ssl == nil or not e.established:
    return err("not established")
  if e.failure.len > 0:
    return err(e.failure)
  var off = 0
  while off < src.len:
    let n = min(src.len - off, MaxRecordPlaintext)
    ERR_clear_error()
    let r = SSL_write(e.ssl, unsafeAddr src[off], cint(n))
    if r <= 0:
      e.fail("write", r)
      return err(e.failure)
    off += int(r)
  ok()

proc shutdown*(e: TlsEngine) =
  ## Queues close_notify in `takeOutput`.
  if e.ssl != nil and e.established and e.failure.len == 0:
    ERR_clear_error()
    discard SSL_shutdown(e.ssl)
    discard sslErrors()

proc channelBinding*(e: TlsEngine): Result[seq[byte], string] =
  ## [SPEC TRANSPORT §8.4.1] l.1279-1282: RFC 9266 `tls-exporter`: the label
  ## `EXPORTER-Channel-Binding`, a zero-length context, 32 bytes.
  if e.ssl == nil or not e.established:
    return err("not established")
  var v = newSeq[byte](ChannelBindingLen)
  var none: uint8 = 0
  if SSL_export_keying_material(
    e.ssl,
    addr v[0],
    csize_t(ChannelBindingLen),
    ExporterLabel.cstring,
    csize_t(ExporterLabel.len),
    addr none,
    0,
    1,
  ) != 1:
    return err("cannot export the channel binding: " & sslErrors())
  ok(v)

proc established*(e: TlsEngine): bool =
  e.established

proc failure*(e: TlsEngine): string =
  e.failure

proc peer*(e: TlsEngine): PeerIdentity =
  ## Set once the peer check passed.
  e.peer

proc role*(e: TlsEngine): TlsRole =
  e.role

proc version*(e: TlsEngine): int =
  if e.ssl == nil:
    0
  else:
    int(SSL_version(e.ssl))

proc peerSignatureAlgorithm*(e: TlsEngine): uint16 =
  if e.ssl == nil:
    0
  else:
    SSL_get_peer_signature_algorithm(e.ssl)

proc sessionReused*(e: TlsEngine): bool =
  e.ssl != nil and SSL_session_reused(e.ssl) == 1

proc sessionsOffered*(e: TlsEngine): int =
  ## Sessions the peer offered for resumption (none with a conforming peer).
  e.sessionsOffered

proc alpnSelected*(e: TlsEngine): string =
  ## [SPEC TRANSPORT §8.4.1] l.1217: the ALPN protocol the handshake selected,
  ## "" when none. `logos.remote.tls-tcp` sets no ALPN list and no selection
  ## callback on either side, so it is always "".
  if e.ssl == nil:
    return ""
  var data: ptr uint8
  var n: cuint
  SSL_get0_alpn_selected(e.ssl, addr data, addr n)
  if data == nil or n == 0:
    return ""
  result = newString(int(n))
  copyMem(addr result[0], data, int(n))

proc serverNameSeen*(e: TlsEngine): string =
  ## A server's view of the client's SNI `host_name`, "" when none was sent.
  if e.ssl == nil:
    return ""
  let n = SSL_get_servername(e.ssl, TlsextNametypeHostName)
  if n == nil:
    ""
  else:
    $n

proc groupId*(e: TlsEngine): uint16 =
  if e.ssl == nil:
    0
  else:
    SSL_get_group_id(e.ssl)

when defined(lcnTestHooks):
  proc newTlsContextForTests*(
      role: TlsRole,
      certificate: openArray[byte],
      maxVersion = TLS1_3_VERSION.uint16,
      withCertificate = true,
  ): Result[TlsContext, string] =
    ## Test hook (D27): settings a conforming peer never has, to show the
    ## refusals: an earlier TLS version allowed, or no certificate.
    let c = ?makeContext(role, certificate, withCertificate)
    if SSL_CTX_set_min_proto_version(c.ctx, TLS1_2_VERSION.uint16) != 1 or
        SSL_CTX_set_max_proto_version(c.ctx, maxVersion) != 1:
      c.free()
      return err("cannot set the versions")
    if maxVersion < TLS1_3_VERSION.uint16:
      # TLS 1.2 also signs with the context's one algorithm.
      discard SSL_CTX_set_strict_cipher_list(c.ctx, "ECDHE-ECDSA-AES128-GCM-SHA256")
    ok(c)

{.pop.}
