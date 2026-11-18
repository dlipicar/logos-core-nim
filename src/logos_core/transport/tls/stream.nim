## TRANSPORT §8.4, §8.4.1; I99: authenticated TLS streams over chronos. The
## driver moves ciphertext between an engine (`engine.nim`) and a chronos
## `StreamTransport` (TCP), with the rules the spike found (step5-2-spike.md
## §4): one reader task per connection, bounded by `readBound`; one flush
## routine that a reader never waits for; teardown by closing the transport
## first; one acceptor per listening socket; a deadline on every handshake.
##
## A `TlsStream` exists only once its handshake completed and the peer check
## passed, so no Transport frame is sent or read before (T l.1240-1241,
## l.1297-1298). It carries TRANSPORT §2.1 frames, gives its channel binding
## once, and carries one provider session (T l.1289-1290): its owner closes it
## when that session ends.

{.push raises: [].}

import std/deques
import chronos
import results
import ../framing
import ../../base/[testhooks, wipe]
import ./[boring, engine, params, signing]

export chronos, results, engine, params, signing

testHooksMarker("tls_stream")

type
  TlsError* = object of CatchableError

  StreamRegistry* = ref object
    ## The open streams of one process, so that every connection of a peer
    ## Runtime can be closed when its enrollment is revoked or conflicting
    ## (T l.1276-1277).
    streams: seq[TlsStream]

  TlsStream* = ref object
    engine: TlsEngine
    tr: StreamTransport
    cfg: TlsConfig
    signer: Signer
    inEvent: AsyncEvent
    spaceEvent: AsyncEvent
    fed: int ## input chunks fed so far: a wait for input is for one more
    eof: bool
    reader: Future[void].Raising([])
    outLock: AsyncLock
    inFlight: int ## ciphertext handed to the transport and not yet sent
    prefix: array[4, byte] ## a frame's length prefix, as it arrives
    prefixLen: int
    body: seq[byte] ## the frame being read, allocated at its declared length
    bodyLen: int ## bytes of `body` filled
    inBody: bool
    framingError: string
    ready: Deque[TlsFrame]
    readBuf: seq[byte]
    binding: seq[byte]
    bindingTaken: bool
    closing: bool
    closed: bool
    registry: StreamRegistry

  TlsFrame* = ref object
    ## One TRANSPORT §2.1 frame body read from a stream. It is handed over by
    ## reference, so the stream and its futures keep no copy: the body is the
    ## caller's to erase when it holds a marked payload (`wipe`).
    body*: seq[byte]

  StreamHandler* = proc(s: TlsStream): Future[void] {.async: (raises: []), gcsafe.}
    ## Owns an accepted stream; the listener closes it when this returns.

  TlsListener* = ref object
    server: StreamServer
    ctx: TlsContext
    check: PeerCheck
    signer: Signer
    cfg: TlsConfig
    onStream: StreamHandler
    acceptor: Future[void].Raising([])
    tasks: seq[Future[void].Raising([])]
    handshaking: seq[TlsStream]
    registry: StreamRegistry
    closing: bool
    refusedOverBound: int
    failedHandshakes: int
    lastFailure: string

# Erasure -----------------------------------------------------------------------------

when defined(lcnTestHooks):
  var recordErasureMissingForTests* = false
    ## Test hook (D27): behave as a build whose BoringSSL frees decrypted
    ## records unerased. It can only add the refusal, never lift it.

proc carrierErases*(): bool =
  ## [DECISIONS G277, G327] Whether the carrier erases what it holds of a
  ## marked payload: BoringSSL's record buffers (`recordBuffersErased`, the
  ## BORINGSSL_ZERO_RECORD_BUFFERS build) and the carrier's own copies, which
  ## it always wipes (`wipePlaintext`, `sealFrame`). A frame `readFrame`
  ## returns and a body given to `writeFrame` are the caller's. The TLS
  ## processes add their own conditions (5-7a); until they are shown, remote
  ## paths refuse marked contracts whatever this says.
  result = recordBuffersErased
  when defined(lcnTestHooks):
    if recordErasureMissingForTests:
      result = false

proc requireErasure*(): Result[void, string] =
  ## The refusal a marked payload meets on a carrier that does not erase.
  if carrierErases():
    return ok()
  err(
    MarkedUnsupported &
      ": this build's TLS library frees decrypted records unerased (BORINGSSL_ZERO_RECORD_BUFFERS)"
  )

# The registry ------------------------------------------------------------------------

proc newStreamRegistry*(): StreamRegistry =
  StreamRegistry(streams: @[])

proc add(r: StreamRegistry, s: TlsStream) =
  if r != nil:
    r.streams.add(s)

proc remove(r: StreamRegistry, s: TlsStream) =
  if r == nil:
    return
  for i in 0 ..< r.streams.len:
    if r.streams[i] == s:
      r.streams.del(i)
      return

proc len*(r: StreamRegistry): int =
  if r == nil: 0 else: r.streams.len

# The driver --------------------------------------------------------------------------

proc newStream(
    e: TlsEngine, tr: StreamTransport, cfg: TlsConfig, signer: Signer
): TlsStream =
  TlsStream(
    engine: e,
    tr: tr,
    cfg: cfg,
    signer: signer,
    inEvent: newAsyncEvent(),
    spaceEvent: newAsyncEvent(),
    outLock: newAsyncLock(),
    ready: initDeque[TlsFrame](),
    readBuf: newSeq[byte](16 * 1024),
    binding: @[],
  )

proc pump(s: TlsStream) {.async: (raises: []).} =
  ## The one reader of the transport: ciphertext into the engine, holding back
  ## while `readBound` bytes wait unconsumed.
  var buf = newSeq[byte](16 * 1024)
  try:
    while true:
      while s.engine.inputBuffered >= s.cfg.readBound:
        s.spaceEvent.clear()
        await s.spaceEvent.wait()
      let n = await s.tr.readOnce(addr buf[0], buf.len)
      if n == 0:
        break
      s.engine.feed(buf.toOpenArray(0, n - 1))
      inc s.fed
      s.inEvent.fire()
  except CancelledError:
    discard
  except TransportError:
    discard
  s.eof = true
  s.engine.feedEnd()
  s.inEvent.fire()

proc waitIn(s: TlsStream, seen: int) {.async: (raises: [CancelledError]).} =
  ## Until input fed after `seen`, or the end of the input.
  while s.fed == seen and not s.eof:
    s.inEvent.clear()
    await s.inEvent.wait()

proc flush(s: TlsStream, wait = false) {.async: (raises: [CancelledError, TlsError]).} =
  ## Sends what the engine produced, in order. A flush that finds another one
  ## running returns: that one drains what was added meanwhile (it looks again
  ## before it lets go, with no await between), so a reader never waits on a
  ## writer that waits on the peer. `wait` waits for its turn instead (writers,
  ## shutdown), which is the writers' backpressure.
  if s.engine.pendingOutput == 0 and not wait:
    return
  if s.outLock.locked and not wait:
    return
  await s.outLock.acquire()
  try:
    while true:
      let chunk = s.engine.takeOutput()
      if chunk.len == 0:
        break
      s.inFlight = chunk.len
      discard await s.tr.write(chunk)
      s.inFlight = 0
  except TransportError as x:
    raise newException(TlsError, "write: " & x.msg)
  finally:
    s.inFlight = 0
    try:
      s.outLock.release()
    except AsyncLockError:
      discard

proc handshake(s: TlsStream) {.async: (raises: [CancelledError, TlsError]).} =
  while true:
    let seen = s.fed
    case s.engine.advance()
    of prEstablished:
      s.spaceEvent.fire()
      await s.flush()
      return
    of prNeedInput:
      s.spaceEvent.fire()
      await s.flush()
      await s.waitIn(seen)
    of prNeedSignature:
      await s.flush()
      let (role, alg, input) = s.engine.signRequest()
      let answer = await s.signer(role, alg, input)
      s.engine.answerSignature(answer)
    of prFailed:
      let why = s.engine.failure
      try:
        await s.flush() # the alert, if there is one
      except TlsError:
        discard
      raise newException(TlsError, why)

proc wipePlaintext(s: TlsStream) =
  ## [DECISIONS G327; INTERFACE l.381] The carrier's own copies of decrypted
  ## data, erased before they are released: the read buffer, a partial frame
  ## and frames read but not taken. A frame `readFrame` returned is the
  ## caller's.
  wipe(s.readBuf)
  wipe(s.body)
  for f in s.ready:
    wipe(f.body)
  s.ready.clear()
  s.inBody = false
  s.bodyLen = 0
  s.prefixLen = 0

proc release(s: TlsStream) {.async: (raises: []).} =
  ## Closes the transport first (that ends the reader), waits for the reader
  ## within `closeWaitMs`, then frees the engine. Safe to repeat.
  if s.closed:
    return
  s.closed = true
  s.registry.remove(s)
  await s.tr.closeWait()
  if s.reader != nil and not s.reader.finished:
    try:
      discard await s.reader.withTimeout(milliseconds(s.cfg.closeWaitMs))
    except CancelledError:
      discard
  wipe(s.binding)
  s.wipePlaintext()
  s.engine.free()

proc startDriver(s: TlsStream) =
  s.reader = s.pump()

proc establish(
    s: TlsStream
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  ## The handshake within the deadline; on failure the stream is released.
  s.startDriver()
  var failure = ""
  try:
    await s.handshake().wait(milliseconds(s.cfg.handshakeTimeoutMs))
    let b = s.engine.channelBinding()
    if b.isErr:
      failure = b.error
    else:
      s.binding = b.get
  except AsyncTimeoutError:
    failure = "handshake: no answer within " & $s.cfg.handshakeTimeoutMs & " ms"
  except TlsError as x:
    failure = x.msg
  except CancelledError as x:
    await s.release()
    raise x
  if failure.len > 0:
    await s.release()
    return err(failure)
  ok()

# Streams -----------------------------------------------------------------------------

proc peer*(s: TlsStream): PeerIdentity =
  ## [SPEC TRANSPORT §8.4.1] who the peer authenticated as (5-7a checks it
  ## against the route, l.1212-1213).
  s.engine.peer

proc engine*(s: TlsStream): TlsEngine =
  ## The connection's engine, for what it reports (version, algorithms).
  s.engine

proc isClosed*(s: TlsStream): bool =
  s.closed

proc takeChannelBinding*(s: TlsStream): Result[seq[byte], string] =
  ## [SPEC TRANSPORT §8.4.1] l.1279-1290: the connection's 32-byte
  ## `tls-exporter` value, given once: to the provider's ticket redemption or
  ## the caller's route session. It lives in this stream only and is wiped at
  ## close; nothing moves it to another connection (l.1284).
  if s.closed:
    return err("closed")
  if s.bindingTaken:
    return err("the channel binding was already taken")
  s.bindingTaken = true
  ok(s.binding)

proc close*(s: TlsStream) {.async: (raises: []).} =
  ## close_notify when the connection is still sound, then the transport.
  if s.closed or s.closing:
    return
  s.closing = true
  if s.engine.established and s.engine.failure.len == 0:
    s.engine.shutdown()
    try:
      await s.flush(wait = true).wait(milliseconds(s.cfg.closeWaitMs))
    except CatchableError:
      discard
  await s.release()

proc wipe*(f: TlsFrame) =
  ## Erases a frame's body.
  if f != nil:
    wipe(f.body)

proc absorb(s: TlsStream, data: openArray[byte]): Result[void, string] =
  ## Splits decrypted bytes into frames. A frame's body is allocated at its
  ## declared length once the prefix is read (TRANSPORT §2.1, §8.3: a length
  ## over `frameLimit` fails before anything is allocated), so it never grows
  ## and leaves no unerased copy behind.
  var i = 0
  while i < data.len:
    if not s.inBody:
      let take = min(4 - s.prefixLen, data.len - i)
      copyMem(addr s.prefix[s.prefixLen], unsafeAddr data[i], take)
      s.prefixLen += take
      i += take
      if s.prefixLen < 4:
        break
      s.prefixLen = 0
      let n = parsePrefix(s.prefix, s.cfg.frameLimit)
      if n.isErr:
        return err("a frame of " & $n.error.declared & " bytes is over the limit")
      s.body = newSeq[byte](int(n.get))
      s.bodyLen = 0
      s.inBody = true
    else:
      let take = min(s.body.len - s.bodyLen, data.len - i)
      if take > 0:
        copyMem(addr s.body[s.bodyLen], unsafeAddr data[i], take)
        s.bodyLen += take
        i += take
    if s.inBody and s.bodyLen == s.body.len:
      s.ready.addLast(TlsFrame(body: move s.body))
      s.body = @[]
      s.inBody = false
  ok()

proc readFrame*(
    s: TlsStream
): Future[Result[Opt[TlsFrame], string]] {.async: (raises: [CancelledError]).} =
  ## The next TRANSPORT §2.1 frame; none at a clean end (close_notify). An end
  ## without close_notify, a TLS failure or a frame over `frameLimit` is an
  ## error, after which the stream is to be closed. The frame is the caller's,
  ## to erase when it holds a marked payload.
  while true:
    if s.ready.len > 0:
      return ok(Opt.some(s.ready.popFirst()))
    if s.closed or s.closing:
      return err("closed")
    if s.framingError.len > 0:
      return err(s.framingError)
    let seen = s.fed
    let o = s.engine.readApp(s.readBuf)
    s.spaceEvent.fire()
    case o.kind
    of rdData:
      let got = s.absorb(s.readBuf.toOpenArray(0, o.n - 1))
      if got.isErr:
        s.framingError = got.error
        return err(got.error)
    of rdNeedInput:
      try:
        await s.flush()
      except TlsError as x:
        return err(x.msg)
      await s.waitIn(seen)
    of rdClosed:
      if s.inBody or s.prefixLen > 0:
        return err("the peer closed inside a frame")
      return ok(Opt.none(TlsFrame))
    of rdFailed:
      return err(s.engine.failure)

proc outputRetained*(s: TlsStream): int =
  ## Ciphertext sealed and not yet sent: what `writeBound` limits.
  s.engine.pendingOutput + s.inFlight

proc sealFrame(s: TlsStream, body: openArray[byte]): Result[void, string] =
  ## Hands one frame to the engine, which seals it into records, and erases
  ## the framed copy. [SPEC TRANSPORT §8.6] A frame that would pass `writeBound`
  ## while earlier output waits is refused before anything is sealed.
  if s.closed or s.closing:
    return err("closed")
  if not fits(body.len, s.cfg.peerFrameLimit):
    return err("a frame of " & $body.len & " bytes is over the peer's limit")
  let retained = s.outputRetained
  if retained > 0 and retained + body.len > s.cfg.writeBound:
    return err("output bound: " & $retained & " bytes wait to be sent")
  var f = frame(body, s.cfg.peerFrameLimit)
  if f.isErr:
    return err("a frame of " & $body.len & " bytes is over the peer's limit")
  let written = s.engine.writeApp(f.get)
  wipe(f.get)
  written

proc flushWritten(
    s: TlsStream
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  try:
    await s.flush(wait = true)
  except TlsError as x:
    return err(x.msg)
  ok()

proc writeFrame*(
    s: TlsStream, body: openArray[byte]
): Future[Result[void, string]].Raising([CancelledError]) =
  ## One TRANSPORT §2.1 frame; the future completes once earlier output has
  ## been sent. `body` is sealed before this returns, so the carrier keeps no
  ## plaintext copy of it; `body` stays the caller's. Past `writeBound` it
  ## fails with nothing sealed, and the stream stays usable.
  let sealed = s.sealFrame(body)
  if sealed.isErr:
    let failed =
      Future[Result[void, string]].Raising([CancelledError]).init("tls.writeFrame")
    failed.complete(sealed)
    return failed
  s.flushWritten()

# Connecting --------------------------------------------------------------------------

proc connectTcp(
    address: TlsTcpAddress
): Future[Result[StreamTransport, string]] {.async: (raises: [CancelledError]).} =
  ## Tries `host`'s addresses in resolver order while TCP connect fails.
  var addrs: seq[TransportAddress] = @[]
  try:
    addrs = resolveTAddress(address.host, Port(address.port))
  except TransportAddressError as x:
    return err("cannot resolve " & address.host & ": " & x.msg)
  var last = "no address for " & address.host
  for ta in addrs:
    try:
      let tr = await connect(ta, flags = {SocketFlags.TcpNoDelay})
      return ok(tr)
    except TransportError as x:
      last = "cannot connect to " & $ta & ": " & x.msg
  err(last)

proc connect*(
    address: TlsTcpAddress,
    ctx: TlsContext,
    peerCheck: PeerCheck,
    signer: Signer,
    config: TlsConfig,
    registry: StreamRegistry = nil,
): Future[Result[TlsStream, string]] {.async: (raises: [CancelledError]).} =
  ## [SPEC TRANSPORT §8.4.1] A client stream to `address`, authenticated by
  ## `peerCheck` (which names the Runtime it must be, l.1242-1243). Any TLS failure
  ## ends the attempt: nothing else is tried (l.1219-1221).
  ?config.check()
  ?address.check()
  if config.carriesMarked:
    ?requireErasure()
  if ctx == nil or ctx.role != tlsClient:
    return err("a client stream needs a client context")
  let e = ?newEngine(ctx, peerCheck, address.serverName)
  var trr = Result[StreamTransport, string].err("not connected")
  try:
    trr = await connectTcp(address).wait(milliseconds(config.handshakeTimeoutMs))
  except AsyncTimeoutError:
    trr = Result[StreamTransport, string].err(
      "cannot connect within " & $config.handshakeTimeoutMs & " ms"
    )
  except CancelledError as x:
    e.free()
    raise x
  if trr.isErr:
    e.free()
    return err(trr.error)
  let s = newStream(e, trr.get, config, signer)
  ?(await s.establish())
  s.registry = registry
  registry.add(s)
  ok(s)

# Listening ---------------------------------------------------------------------------

proc removeTask(l: TlsListener, f: Future[void].Raising([])) =
  for i in 0 ..< l.tasks.len:
    if l.tasks[i] == f:
      l.tasks.del(i)
      return

proc removeHandshaking(l: TlsListener, s: TlsStream) =
  for i in 0 ..< l.handshaking.len:
    if l.handshaking[i] == s:
      l.handshaking.del(i)
      return

proc serveOne(l: TlsListener, tr: StreamTransport) {.async: (raises: []).} =
  let er = newEngine(l.ctx, l.check)
  if er.isErr:
    inc l.failedHandshakes
    l.lastFailure = er.error
    await tr.closeWait()
    return
  let s = newStream(er.get, tr, l.cfg, l.signer)
  l.handshaking.add(s)
  var done = Result[void, string].err("cancelled")
  try:
    done = await s.establish()
  except CancelledError:
    discard
  l.removeHandshaking(s)
  if done.isErr:
    inc l.failedHandshakes
    l.lastFailure = done.error
    return
  if l.closing:
    await s.close()
    return
  s.registry = l.registry
  l.registry.add(s)
  await l.onStream(s)
  await s.close()

proc acceptLoop(l: TlsListener) {.async: (raises: []).} =
  while not l.closing:
    var tr: StreamTransport = nil
    try:
      tr = await l.server.accept()
    except CancelledError:
      return
    except TransportError:
      if l.closing:
        return
      continue
    if l.closing:
      await tr.closeWait()
      return
    if l.handshaking.len >= l.cfg.maxHandshakes or l.tasks.len >= l.cfg.maxConnections:
      # Over a bound (TRANSPORT §8.6): closed at once, unread.
      inc l.refusedOverBound
      await tr.closeWait()
      continue
    let task = l.serveOne(tr)
    l.tasks.add(task)
    task.addCallback(
      proc(udata: pointer) {.gcsafe, raises: [].} =
        l.removeTask(task)
    )

proc serve*(
    host: string,
    port: uint16,
    ctx: TlsContext,
    peerCheck: PeerCheck,
    signer: Signer,
    config: TlsConfig,
    onStream: StreamHandler,
    registry: StreamRegistry = nil,
): Result[TlsListener, string] =
  ## A listener on `host`:`port` (0: any free port) that hands each
  ## authenticated stream to `onStream`.
  ?config.check()
  if config.carriesMarked:
    ?requireErasure()
  if ctx == nil or ctx.role != tlsServer:
    return err("a listener needs a server context")
  if peerCheck == nil or signer == nil or onStream == nil:
    return err("a listener needs a peer check, a signer and a handler")
  var server: StreamServer = nil
  try:
    let ta = initTAddress(host, Port(port))
    server = createStreamServer(ta, flags = {ServerFlags.ReuseAddr})
  except CatchableError as x:
    return err("cannot listen on " & host & ":" & $port & ": " & x.msg)
  let l = TlsListener(
    server: server,
    ctx: ctx,
    check: peerCheck,
    signer: signer,
    cfg: config,
    onStream: onStream,
    tasks: @[],
    handshaking: @[],
    registry: (if registry == nil: newStreamRegistry() else: registry),
  )
  l.acceptor = l.acceptLoop()
  ok(l)

proc localPort*(l: TlsListener): uint16 =
  uint16(l.server.localAddress().port)

proc registry*(l: TlsListener): StreamRegistry =
  l.registry

proc refusedOverBound*(l: TlsListener): int =
  ## Connections closed unread because `maxHandshakes` or `maxConnections` was
  ## reached.
  l.refusedOverBound

proc connectionsHeld*(l: TlsListener): int =
  ## Connections that count against `maxConnections`, until their teardown ends.
  l.tasks.len

proc failedHandshakes*(l: TlsListener): int =
  l.failedHandshakes

proc lastFailure*(l: TlsListener): string =
  l.lastFailure

proc handshakesInProgress*(l: TlsListener): int =
  l.handshaking.len

proc closePeer*(
    r: StreamRegistry, runtime: string
): Future[int] {.async: (raises: []).} =
  ## [SPEC TRANSPORT §8.4.1] l.1276-1277: closes every open stream of
  ## `runtime`; the number closed.
  if r == nil:
    return 0
  var victims: seq[TlsStream] = @[]
  for s in r.streams:
    if s.engine.peer.runtime == runtime:
      victims.add(s)
  for s in victims:
    await s.close()
  victims.len

proc closeAll(r: StreamRegistry) {.async: (raises: []).} =
  if r == nil:
    return
  let all = r.streams
  for s in all:
    await s.close()

when defined(lcnTestHooks):
  proc abortForTests*(s: TlsStream) {.async: (raises: []).} =
    ## Test hook (D27): the transport ends with no close_notify, as when TCP
    ## is lost.
    await s.release()

proc close*(l: TlsListener) {.async: (raises: []).} =
  ## Stops accepting, ends handshakes in progress and closes the streams it
  ## accepted.
  if l.closing:
    return
  l.closing = true
  try:
    l.server.stop()
  except TransportOsError:
    discard
  await l.server.closeWait()
  if l.acceptor != nil and not l.acceptor.finished:
    try:
      discard await l.acceptor.withTimeout(milliseconds(l.cfg.closeWaitMs))
    except CancelledError:
      discard
  let pending = l.handshaking
  for s in pending:
    await s.release()
  await l.registry.closeAll()
  let tasks = l.tasks
  for t in tasks:
    if not t.finished:
      try:
        discard await t.withTimeout(milliseconds(l.cfg.closeWaitMs))
      except CancelledError:
        discard

{.pop.}
