## Inbound remote Runtime Control (Tier 5 step 5-7a-2; DECISIONS G412, G413,
## G415; 5-7a plan §3.5, §3.8, §8). As processes: logosd with `tls-tcp`
## listener records and a capability-authority policy, and an enrolled
## source Runtime played by a test client built on the carrier
## (`support/tls_fixtures`): it authenticates as that Runtime, sends the
## Transport Hello for `logos_runtime_control` with a consumer reference as
## its token, and calls Runtime Control as that forwarded consumer (plan §5
## item 2: no target process yet).
##
## - the Hello's token rules (RUNTIME l.1694-1699): each refusal a
##   ProtocolError `NOT_AUTHORISED`, no session, no method run;
## - the order of checks (l.1835): the method authorized before its payload
##   is decoded or validated;
## - O1's subject rule as the engine applies it to a forwarded consumer;
## - forwarded discovery (l.2765-2767) and the export rules;
## - the listener and export records over remote Runtime Control, and Q4's
##   durable disables across restarts, a SIGKILL, a changed configuration
##   entry, `remote exposure reset` and a failing write;
## - the methods' errors (l.3434-3449) and the interims of G413.

when defined(posix):
  import std/[json, os, posix, strutils]
  import unittest2
  import logos_sdk/cbor
  import logos_sdk/crypto/blake3
  import logos_sdk/iface/[accept, outcome]
  import logos_sdk/kit/rc_types
  import
    ../src/logos_core/daemon/[
      config, credential, daemon_config_types, remoteexposure, remotetrust, session,
      sessioninit,
    ]
  from ../src/logos_core/authority/scopes import encode, sortSet
  import ../src/logos_core/transport/[boundary, envelope, hello]
  import ../src/logos_core/transport/session as tsession
  import ../src/logos_core/runtime/host
  from ../src/logos_core/runtime/hostsup import nil # compiles hostspawn.c
  import ./support/[daemonbuild, daemonproc, shortdir, slowdown, tls_fixtures]

  type RcOutcome = outcome.Outcome ## (not `choice.Outcome`)

  const
    ReadyMs = 120_000 * Slow
    StopMs = 60_000 * Slow
    AnswerMs = 20_000 * Slow ## a Hello's or a call's answer
    EndMs = 2_000 * Slow ## [plan §3.1] a closed connection is seen within 2 s
    RcModule = "logos_runtime_control"
    Consumer = "m1" ## the forwarded consumer's instance id on the source Runtime
    MeterInstance = "meter-1"

  let
    dExe = logosdProgram()
    ctlExe = logosctlProgram()
    rExe = remoteProgram()
    a = newParty(IdA) # the enrolled source Runtime
    stranger = newParty(IdC) # never enrolled

  proc rcBoundaryOf(): Boundary =
    let docs = rcDocuments()
    let set = acceptContractSet(docs[0], docs[1], docs[2], AcceptOptions(system: true))
      .expect("the Runtime Control contract")
    boundary(set, set.primary.root).expect("a Runtime Control boundary")

  let
    rcB = rcBoundaryOf()
    rcRoot = rcB.selected
    meterRoot = @(
      acceptContractSet(readFile("spec/mirrors/IFC/3.9.1.module.cddl"))
      .expect("the meter_module contract set").primary.root
    )

  # Helpers -----------------------------------------------------------------------------------

  proc textOf(b: openArray[byte]): string =
    result = newString(b.len)
    for i, x in b:
      result[i] = char(x)

  proc bytesOf(s: string): seq[byte] =
    @(s.toOpenArrayByte(0, s.high))

  proc freePorts(n: int): seq[uint16] =
    ## `n` distinct loopback ports nothing listens on now.
    var fds: seq[SocketHandle]
    for _ in 0 ..< n:
      let fd = socket(posix.AF_INET, posix.SOCK_STREAM, 0)
      doAssert fd.cint >= 0
      var sa: Sockaddr_in
      sa.sin_family = TSa_Family(posix.AF_INET)
      sa.sin_addr.s_addr = htonl(0x7f000001'u32)
      doAssert bindSocket(fd, cast[ptr SockAddr](addr sa), SockLen(sizeof(sa))) == 0
      var len = SockLen(sizeof(sa))
      doAssert getsockname(fd, cast[ptr SockAddr](addr sa), addr len) == 0
      result.add(ntohs(sa.sin_port))
      fds.add(fd)
    for fd in fds:
      discard close(fd)

  proc boundListener(): (cint, uint16) =
    ## A listening loopback socket and its port: what a bind at it then meets.
    let fd = socket(posix.AF_INET, posix.SOCK_STREAM, 0)
    doAssert fd.cint >= 0
    var sa: Sockaddr_in
    sa.sin_family = TSa_Family(posix.AF_INET)
    sa.sin_addr.s_addr = htonl(0x7f000001'u32)
    doAssert bindSocket(fd, cast[ptr SockAddr](addr sa), SockLen(sizeof(sa))) == 0
    doAssert listen(fd, 16) == 0
    var len = SockLen(sizeof(sa))
    doAssert getsockname(fd, cast[ptr SockAddr](addr sa), addr len) == 0
    (fd.cint, ntohs(sa.sin_port))

  proc digestOfFile(path: string): seq[byte] =
    var h: Blake3Hasher
    h.init()
    let bytes = readFile(path)
    h.update(bytes.toOpenArrayByte(0, bytes.high))
    @(h.finish())

  proc readWithin(s: TlsStream, ms: int): Result[Opt[seq[byte]], string] =
    ## The next frame; none once the connection ended; an error when nothing
    ## came within `ms`.
    let f = s.readFrame()
    if not waitFor f.withTimeout(milliseconds(ms)):
      f.cancelSoon()
      return err("no frame within " & $ms & " ms")
    let r = f.read()
    if r.isErr or r.get.isNone:
      return ok(Opt.none(seq[byte]))
    ok(Opt.some(r.get.get.body))

  proc closedWithin(s: TlsStream, ms: int): bool =
    let f = s.readWithin(ms)
    f.isOk and f.get.isNone

  # Policy ------------------------------------------------------------------------------------

  func remoteSubject(): LcnApSubject =
    LcnApSubject(runtimes: Opt.some(@[IdA]))

  proc rcAllow(methods: openArray[string], subject = remoteSubject()): LcnApRule =
    ## [G415] An allow of Runtime Control `methods` for `subject`.
    var ms: seq[LcnApDecl]
    for m in methods:
      ms.add(LcnApDecl(kind: LcnApDeclKind.Tstr, arm_Tstr: m))
    sortSet(ms)
    LcnApRule(
      kind: LcnApRuleKind.lcn_Ap_allow,
      arm_lcn_Ap_allow: LcnApAllow(
        subject: subject,
        scopes: @[
          LcnApScope(
            kind: LcnApScopeKind.lcn_Ap_runtime_control,
            arm_lcn_Ap_runtime_control: LcnApRuntimeControl(methods: Opt.some(ms)),
          )
        ],
      ),
    )

  proc discoverAllow(root: seq[byte]): LcnApRule =
    ## `discover` of the providers of `root`, for consumers of `a`.
    LcnApRule(
      kind: LcnApRuleKind.lcn_Ap_allow,
      arm_lcn_Ap_allow: LcnApAllow(
        subject: remoteSubject(),
        scopes: @[
          LcnApScope(
            kind: LcnApScopeKind.lcn_Ap_provider_access,
            arm_lcn_Ap_provider_access: LcnApProviderAccess(
              contract: LcnApProviderAccessContractChoice(
                kind: LcnApProviderAccessContractChoiceKind.logos_Schema_commitment,
                arm_logos_Schema_commitment: SchemaCommitment(schema_root: root),
              ),
              actions: @[LcnApAction(kind: LcnApActionKind.Discover)],
            ),
          )
        ],
      ),
    )

  const ListenerMethods = [
    "list_remote_listeners", "set_remote_listener", "list_provider_exports",
    "set_provider_export",
  ]

  # Addresses ---------------------------------------------------------------------------------

  func dcAddress(port: uint16): LcnRcRemoteListenerAddress =
    LcnRcRemoteListenerAddress(
      kind: LcnRcRemoteListenerAddressKind.lcn_Rc_tls_tcp_runtime_address,
      arm_lcn_Rc_tls_tcp_runtime_address:
        LcnRcTlsTcpRuntimeAddress(host: "127.0.0.1", port: port),
    )

  func rcAddress(
      port: uint16, profile = ""
  ): LogosNSRuntimeControlRemoteListenerAddress =
    var t = LogosNSRuntimeControlTlsTcpRuntimeAddress(host: "127.0.0.1", port: port)
    if profile.len > 0:
      t.profile = Opt.some(profile)
    LogosNSRuntimeControlRemoteListenerAddress(
      kind:
        LogosNSRuntimeControlRemoteListenerAddressKind.logos_NS_runtime_control_Tls_tcp_runtime_address,
      arm_logos_NS_runtime_control_Tls_tcp_runtime_address: t,
    )

  func quicAddress(port: uint16): LogosNSRuntimeControlRemoteListenerAddress =
    LogosNSRuntimeControlRemoteListenerAddress(
      kind:
        LogosNSRuntimeControlRemoteListenerAddressKind.logos_NS_runtime_control_Quic_runtime_address,
      arm_logos_NS_runtime_control_Quic_runtime_address:
        LogosNSRuntimeControlQuicRuntimeAddress(host: "127.0.0.1", port: port),
    )

  # logosd ------------------------------------------------------------------------------------

  var cases = 0

  type
    Listener = tuple[enabled, rc: bool]

    Case = object
      dir: string
      s: Session
      ports: seq[uint16]
        ## the listener records' ports, in order: [0] serves Runtime Control
        ## to the tests that change the others
      rid: string ## logosd's Runtime id
      server: Party ## logosd's credential, as the peer pins it (no key)

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
      checkpoint("logosctl: " & r.stdout & r.stderr)
      newJNull()

  proc enroll(c: Case, revision: uint64) =
    let anchor = LcnRemoteAnchor(id: anchorIdOf(a.cert), certificate: a.cert)
    let record = remotetrust.activeRecord(
      a.id, params.TlsTcpProfile, revision, anchorIdOf(a.cert), @[a.spki]
    ).get
    check writeRemoteTrustFile(
      c.s,
      LcnRemoteTrust(revision: revision, anchors: @[anchor], enrollments: @[record]),
    ).isOk

  proc listenersOf(
      ports: openArray[uint16], ls: openArray[Listener]
  ): seq[LcnRcRemoteListenerRecord] =
    for i, l in ls:
      result.add(
        LcnRcRemoteListenerRecord(
          address: dcAddress(ports[i]),
          enabled: l.enabled,
          runtime_control_enabled: l.rc,
        )
      )

  proc meterModule(dir: string): LcnAppModule =
    ## A provider of the meter contract that no case starts: its artifact is
    ## a placeholder file, and its provider record exists from its creation.
    let lib = dir / "meter.placeholder"
    writeFile(lib, "not a library: never loaded")
    let artifact =
      LcnAppArtifact(id: "meter_module", local_path: lib, hash: digestOfFile(lib))
    LcnAppModule(
      instance: MeterInstance,
      module: "meter_module",
      primary_contract: Opt.some(SchemaCommitment(schema_root: meterRoot)),
      implementation: LcnAppImplementation(
        kind: LcnAppImplementationKind.Direct_dynamic,
        arm_Direct_dynamic: LcnAppImplementationARDirectDynamicMap(artifact: artifact),
      ),
    )

  proc configOf(
      c: Case, rules: seq[LcnApRule], ls: openArray[Listener], meter: bool
  ): LcnDaemonConfig =
    var dc = defaultDaemonConfig("assigned-by-init")
    dc.runtime.remote_program = Opt.some(rExe)
    dc.remote = Opt.some(
      LcnDcRemote(enabled: true, listeners: Opt.some(listenersOf(c.ports, ls)))
    )
    var rs = rules
    sortSet(rs)
    dc.policy.arm_Capability_authority.rules = rs
    if meter:
      dc.modules = Opt.some(@[meterModule(c.dir)])
    dc

  proc newCase(
      rules: seq[LcnApRule],
      ls: openArray[Listener] = [(true, true), (true, true), (false, true)],
      meter = false,
  ): Case =
    ## A session with remote on, the listener records `ls` on free loopback
    ## ports, a capability-authority policy of `rules`, a TLS credential and
    ## `a` enrolled.
    inc cases
    result.dir = makeShortBase("lrc" & $cases, deepest = "/s/run/logosctl.sock")
    result.s = Session(dir: result.dir / "s")
    result.ports = freePorts(ls.len)
    let dc = result.configOf(rules, ls, meter)
    let path = result.dir / "config.cbor"
    writeFile(path, textOf(dc.encode.expect("an encoding")))
    let init = result.ctl("init", "--config", "@" & path)
    if init.code != 0:
      checkpoint("init: " & init.stdout & init.stderr)
    check init.code == 0
    check result.ctl("remote", "trust", "init").code == 0
    check result.ctl("remote", "credential", "new").code == 0
    result.enroll(2)
    let (raw, _) = readDaemonConfig(result.s).expect("the configuration")
    result.rid = raw.runtime.runtime_instance_id
    let cred = currentCredential(result.s).expect("the credential").get
    result.server = Party(id: result.rid, cert: cred.certificate, spki: cred.spki)

  proc setConfig(c: Case, dc: LcnDaemonConfig) =
    ## The session's configuration replaced (logosd stopped).
    let path = c.dir / "config-next.cbor"
    writeFile(path, textOf(dc.encode.expect("an encoding")))
    let r = c.ctl("daemon", "config", "set", "@" & path)
    if r.code != 0:
      checkpoint("daemon config set: " & r.stdout & r.stderr)
    check r.code == 0

  proc start(c: Case, env: openArray[(string, string)] = []): Child =
    spawnChild(dExe, ["--session-dir", c.s.dir], c.dir, "logosd", env)

  proc ready(c: Case, d: Child): bool =
    for _ in 0 ..< ReadyMs div 20:
      if not d.alive:
        checkpoint("logosd ended: " & d.errText)
        return false
      if entryExists(c.s.socketPath) and c.ctl("status").code == 0:
        return true
      sleep(20)
    false

  proc up(c: Case, env: openArray[(string, string)] = []): Child =
    result = c.start(env)
    check c.ready(result)

  proc down(c: Case, d: Child) =
    let code = stopChild(d, StopMs)
    if code != 0:
      checkpoint("logosd: " & d.errText)
    check code == 0

  # The source Runtime ------------------------------------------------------------------------

  proc dial(c: Case, port: uint16, p = a): Result[TlsStream, string] =
    waitFor connect(
      TlsTcpAddress(host: "127.0.0.1", port: port),
      clientContext(p),
      pinnedCheck([c.server]),
      keySigner(p.key, tlsClient),
      fastConfig(),
    )

  proc serves(c: Case, port: uint16): bool =
    ## A TLS connection to `port` is accepted and stays up: a listener
    ## process serves it.
    let s = c.dial(port)
    if s.isErr:
      return false
    let f = s.get.readWithin(300)
    result = f.isErr # nothing came, and the connection did not end
    waitFor s.get.close()

  proc tokenOf(runtime: string, instance = Consumer): seq[byte] =
    LogosNSRuntimeModuleInstanceAddress(
      runtime_instance_id: runtime, module_instance_id: instance
    ).encode.get(@[])

  proc helloOf(token: openArray[byte], module = RcModule, schema = rcRoot): seq[byte] =
    helloRequest(module, token, schema).expect("a Hello")

  type Opened = object
    s: TlsStream ## nil when the dial failed
    code: ErrorCode ## ecOk: the Hello was answered with a Hello
    closed: bool ## after a refusal: the connection ended within `EndMs`

  proc openWith(
      c: Case, port: uint16, body: openArray[byte], after: openArray[seq[byte]] = []
  ): Opened =
    ## Sends the Hello `body`, and `after` right behind it, then reads the
    ## answer: a Hello echoing the Runtime Control contract with an empty
    ## token, or a refusal.
    let s = c.dial(port)
    if s.isErr:
      checkpoint("dial: " & s.error)
      result.code = ecTransport
      return
    result.s = s.get
    if (waitFor s.get.writeFrame(body)).isErr:
      result.code = ecTransport
      return
    for f in after:
      discard waitFor s.get.writeFrame(f)
    let f = s.get.readWithin(AnswerMs)
    if f.isErr or f.get.isNone:
      result.code = ecTransport
      result.closed = f.isOk
      return
    let sent = Hello(module: RcModule, schema: rcRoot)
    let r = acceptHelloResponse(sent, f.get.get)
    if r.isOk:
      result.code = ecOk
      return
    result.code = r.error.code
    result.closed = s.get.closedWithin(EndMs)

  type Rc = object
    s: TlsStream
    c: CallerConn
    open: bool

  proc rcOpen(c: Case, port: uint16, instance = Consumer): Rc =
    let o = c.openWith(port, helloOf(tokenOf(a.id, instance)))
    check o.code == ecOk
    Rc(s: o.s, c: callerConn(rcB), open: o.code == ecOk)

  proc close(r: var Rc) =
    if r.s != nil:
      waitFor r.s.close()
      r.s = nil

  proc failed(code: ErrorCode, msg = ""): RcOutcome =
    RcOutcome(
      ok: false,
      failure: InvocationFailure(
        code: code, message: (if msg.len > 0: Opt.some(msg)
        else: Opt.none(string))
      ),
    )

  proc call(r: var Rc, methodName: string, params: CborValue): RcOutcome =
    if r.s == nil:
      return failed(ecNotReady, "no connection")
    let q = r.c.request(methodName, params)
    if q.isErr:
      return failed(q.error.code, "local: " & q.error.msg)
    let (id, bytes) = q.get
    if (waitFor r.s.writeFrame(bytes)).isErr:
      return failed(ecTransport, "the write failed")
    while true:
      let f = r.s.readWithin(AnswerMs)
      if f.isErr:
        return failed(ecTimeout, f.error)
      if f.get.isNone:
        return failed(ecTransport, "the connection ended")
      for e in r.c.receive(f.get.get):
        if e.kind == ceResponse and e.id == id:
          return e.outcome

  proc code(o: RcOutcome): ErrorCode =
    if o.ok: ecOk else: o.failure.code

  proc message(o: RcOutcome): string =
    if o.ok:
      ""
    else:
      o.failure.message.get("")

  proc decoded[T](o: RcOutcome, _: typedesc[T]): T =
    check o.ok
    if o.ok:
      result = T.decode(encodeCbor(o.response)).expect("a " & $T)

  type Raw = object
    code: ErrorCode ## the Response's, or the ProtocolError's
    protocol: bool ## a ProtocolError, after which the connection ends

  proc rawCall(
      r: var Rc,
      id: uint64,
      methodName: string,
      params: CborValue,
      commitment: PayloadCommitment,
  ): Raw =
    ## A Request built here, past the caller's own checks: what a peer that
    ## does not check its params sends.
    let bytes = encodeMessage(
        Message(
          kind: mkRequest,
          request: envelope.Request(
            id: id, methodName: methodName, params: params, commitment: commitment
          ),
        )
      )
      .expect("a Request")
    if (waitFor r.s.writeFrame(bytes)).isErr:
      return Raw(code: ecTransport)
    let f = r.s.readWithin(AnswerMs)
    if f.isErr or f.get.isNone:
      return Raw(code: ecTransport)
    let m = decodeMessage(f.get.get).expect("a message")
    case m.kind
    of mkResponse:
      check m.response.id == id
      Raw(code: (if m.response.ok: ecOk else: m.response.failure.code))
    of mkProtocolError:
      Raw(code: m.protocolError.code, protocol: true)
    else:
      Raw(code: ecModule)

  proc empty(): CborValue =
    cborMap()

  proc withAddressField(v: CborValue, key: string, x: CborValue): CborValue =
    ## A `set_remote_listener` request whose address gains the field `key`.
    result = v
    for (k, l) in v.entries:
      if k.text == "listener":
        for (k2, a) in l.entries:
          if k2.text == "address":
            a.entries.add((cbor(key), x))

  proc listeners(r: var Rc): seq[LogosNSRuntimeControlRemoteListenerRecord] =
    let o = r.call("list_remote_listeners", empty())
    check o.ok
    if o.ok:
      result = o.decoded(LogosNSRuntimeControlListRemoteListenersResponse).listeners

  func isQuic(a: LogosNSRuntimeControlRemoteListenerAddress): bool =
    a.kind ==
      LogosNSRuntimeControlRemoteListenerAddressKind.logos_NS_runtime_control_Quic_runtime_address

  proc cborEach(ls: seq[LogosNSRuntimeControlRemoteListenerRecord]): seq[seq[byte]] =
    ## Each record's bytes, in the list's order.
    for l in ls:
      result.add(encodeCbor(toCbor(l)))

  proc listenerAt(
      r: var Rc, port: uint16
  ): Opt[LogosNSRuntimeControlRemoteListenerRecord] =
    for l in r.listeners:
      if not l.address.isQuic and
          l.address.arm_logos_NS_runtime_control_Tls_tcp_runtime_address.port == port:
        return Opt.some(l)

  proc setListener(r: var Rc, port: uint16, enabled, rc: bool): RcOutcome =
    r.call(
      "set_remote_listener",
      toCbor(
        LogosNSRuntimeControlSetRemoteListenerRequest(
          listener: LogosNSRuntimeControlRemoteListenerRecord(
            address: rcAddress(port), enabled: enabled, runtime_control_enabled: rc
          )
        )
      ),
    )

  proc setRecord(
      r: var Rc, address: LogosNSRuntimeControlRemoteListenerAddress, enabled: bool
  ): RcOutcome =
    r.call(
      "set_remote_listener",
      toCbor(
        LogosNSRuntimeControlSetRemoteListenerRequest(
          listener: LogosNSRuntimeControlRemoteListenerRecord(
            address: address, enabled: enabled, runtime_control_enabled: false
          )
        )
      ),
    )

  proc setExport(
      r: var Rc, port: uint16, provider: string, enabled: bool, runtime = ""
  ): RcOutcome =
    var p = LogosNSRuntimeModuleProviderAddress(provider: provider)
    if runtime.len > 0:
      p.runtime_instance_id = Opt.some(runtime)
    r.call(
      "set_provider_export",
      toCbor(
        LogosNSRuntimeControlSetProviderExportRequest(
          `export`: LogosNSRuntimeControlProviderExportRecord(
            listener: rcAddress(port), provider: p, enabled: enabled
          )
        )
      ),
    )

  proc exposureText(c: Case): string =
    let r = c.ctl("remote", "exposure", "list")
    check r.code == 0
    r.stdout

  func listenerLine(port: uint16): string =
    ## The listener's row in `remote exposure list --text`.
    "tls-tcp 127.0.0.1:" & $port & " "

  # The Hello ---------------------------------------------------------------------------------

  proc cborText(s: string): seq[byte] =
    ## A text string's deterministic encoding (under 256 bytes).
    if s.len < 24:
      result = @[byte(0x60 + s.len)]
    else:
      result = @[0x78'u8, byte(s.len)]
    result.add(bytesOf(s))

  proc swappedToken(runtime: string): seq[byte] =
    ## The address with its keys in the wrong order: well-formed CBOR, not
    ## deterministic.
    result = @[0xA2'u8]
    result.add(cborText("runtime_instance_id") & cborText(runtime))
    result.add(cborText("module_instance_id") & cborText(Consumer))

  proc longHeadToken(runtime: string): seq[byte] =
    ## The address with a text length in a longer head than it needs.
    result = @[0xA2'u8, 0x78, 18]
    result.add(bytesOf("module_instance_id"))
    result.add(cborText(Consumer))
    result.add(cborText("runtime_instance_id") & cborText(runtime))

  proc longIdToken(runtime: string): seq[byte] =
    ## Deterministic, with an instance id longer than an address allows.
    result = @[0xA2'u8]
    result.add(cborText("module_instance_id") & cborText(repeat('x', 129)))
    result.add(cborText("runtime_instance_id") & cborText(runtime))

  proc noTokenHello(): seq[byte] =
    ## A Hello without its `token` field.
    let v = toCbor(
      Message(
        kind: mkHello,
        hello: Hello(module: RcModule, token: tokenOf(IdA), schema: rcRoot),
      )
    )
    var entries: seq[CborEntry]
    for (k, x) in v.entries:
      if not (k.kind == ckText and k.text == "token"):
        entries.add((k, x))
    encodeCbor(cborMap(entries))

  proc listenerChange(port: uint16): seq[byte] =
    ## A Request to disable the listener at `port`, ready to send after a
    ## Hello: it must never run when the Hello is refused.
    var conn = callerConn(rcB)
    let q = conn.request(
      "set_remote_listener",
      toCbor(
        LogosNSRuntimeControlSetRemoteListenerRequest(
          listener: LogosNSRuntimeControlRemoteListenerRecord(
            address: rcAddress(port), enabled: false, runtime_control_enabled: false
          )
        )
      ),
    )
    q.expect("a Request")[1]

  suite "remote: inbound Runtime Control, the Hello [RUNTIME l.1685-1701, l.2741-2747; G413]":
    teardown:
      # Leaves daemonproc's list of children empty before the program ends:
      # under orc its exit procedure would free it a second time
      # (build/scratch/upstream/ISSUES.md 194).
      killAll()

    test "[RUN-0339] [RUN-0340] [RUN-0342] [TRN-0206] [RUN-0343] [RUN-0344] [RUN-0849] [RUN-0508] [RUN-0513] [IMPL-DECISION G413] the token is one deterministic consumer address owned by the authenticated Runtime: missing, empty, malformed, non-deterministic, trailing-byte and mismatched ones are ProtocolError NOT_AUTHORISED with no session and no method run; another module NOT_AUTHORISED, another contract VERSION_MISMATCH; the accepted Hello is answered with the Runtime Control contract and an empty token":
      let c = newCase(@[rcAllow(ListenerMethods)])
      let d = c.up()
      let p1 = c.ports[0]
      let p2 = c.ports[1]
      let change = listenerChange(p2)
      var trailing = tokenOf(IdA)
      trailing.add(0x00'u8)
      let refused = [
        ("missing", noTokenHello()),
        ("empty", helloOf(@[])),
        ("not CBOR", helloOf(@[0xff'u8, 0x00])),
        ("a text, not an address", helloOf(cborText("m1"))),
        (
          "an address missing its Runtime",
          helloOf(@[0xA1'u8] & cborText("module_instance_id") & cborText(Consumer)),
        ),
        ("keys out of order", helloOf(swappedToken(IdA))),
        ("a longer head", helloOf(longHeadToken(IdA))),
        ("trailing bytes", helloOf(trailing)),
        ("another enrolled Runtime's consumer", helloOf(tokenOf(IdB))),
        ("a consumer of this Runtime", helloOf(tokenOf(c.rid))),
        ("an instance id over 128 bytes", helloOf(longIdToken(IdA))),
        ("another module", helloOf(tokenOf(IdA), module = "meter_module")),
      ]
      for (what, body) in refused:
        checkpoint(what)
        let o = c.openWith(p1, body, after = [change])
        check o.code == ecNotAuthorised
        check o.closed
        if o.s != nil:
          waitFor o.s.close()
      block:
        checkpoint("another contract")
        var other = rcRoot
        other[0] = other[0] xor 1
        let o = c.openWith(p1, helloOf(tokenOf(IdA), schema = other), after = [change])
        check o.code == ecVersionMismatch
        check o.closed
        if o.s != nil:
          waitFor o.s.close()
      # [RUN-0342] No refused Hello ran the change sent behind it.
      check c.serves(p2)
      var r = c.rcOpen(p1)
      let l2 = r.listenerAt(p2)
      check l2.isSome and l2.get.enabled and l2.get.runtime_control_enabled
      # [RUN-0336] A Runtime with no enrollment: its handshake is refused.
      let s = c.dial(p1, stranger)
      if s.isOk:
        check s.get.closedWithin(EndMs)
        waitFor s.get.close()
      r.close()
      c.down(d)

    test "[RUN-0898] [RUN-0340] [RUN-0711] [IMPL-DECISION G413] get_self names the forwarded consumer with its own Runtime, with no policy grant; get_execution_permissions and report_failure are NOT_AUTHORISED for a consumer with no realization here, even when a rule allows them":
      let c = newCase(@[rcAllow(["get_execution_permissions", "report_failure"])])
      let d = c.up()
      var r = c.rcOpen(c.ports[0])
      let me = r.call("get_self", empty()).decoded(LogosNSRuntimeControlGetSelfResponse)
      check me.consumer.runtime_instance_id == IdA
      check me.consumer.module_instance_id == Consumer
      check r.call("get_execution_permissions", empty()).code == ecNotAuthorised
      check r.call("report_failure", empty()).code == ecNotAuthorised
      # Another consumer of the same Runtime on its own connection.
      var r2 = c.rcOpen(c.ports[0], instance = "m2")
      let me2 =
        r2.call("get_self", empty()).decoded(LogosNSRuntimeControlGetSelfResponse)
      check me2.consumer.module_instance_id == "m2"
      check me2.consumer.runtime_instance_id == IdA
      r2.close()
      r.close()
      c.down(d)

  suite "remote: inbound Runtime Control, authority [RUNTIME l.1824-1835; CA; G415, O1]":
    teardown:
      killAll()

    test "[RUN-1124] [RUN-0338] [IMPL-DECISION G413] a method is authorized before its payload is decoded or validated: refused, a bad payload is NOT_AUTHORISED and the session stays; allowed, the same payload is INVALID_PARAMS, and a commitment for another type closes the session":
      let c = newCase(@[rcAllow(["list_provider_exports"])])
      let d = c.up()
      var r = c.rcOpen(c.ports[0])
      let bad = cborMap((cbor("limit"), cbor("ten")))
      let goodListeners =
        rcB.commitRequest("list_remote_listeners", empty()).expect("a commitment")
      let goodExports =
        rcB.commitRequest("list_provider_exports", empty()).expect("a commitment")
      # Refused before the payload: the schema-invalid params, then a
      # commitment that names another type.
      check r.rawCall(1, "list_remote_listeners", bad, goodListeners).code ==
        ecNotAuthorised
      var wrong = goodListeners
      wrong.subtreeRoot[0] = wrong.subtreeRoot[0] xor 1
      let w = r.rawCall(2, "list_remote_listeners", empty(), wrong)
      check w.code == ecNotAuthorised and not w.protocol
      check r.rawCall(3, "no_such_method", empty(), goodListeners).code ==
        ecMethodNotFound
      # Allowed: the payload checks run.
      check r.rawCall(4, "list_provider_exports", bad, goodExports).code ==
        ecInvalidParams
      check r.rawCall(5, "list_provider_exports", empty(), goodExports).code == ecOk
      var wrong2 = goodExports
      wrong2.subtreeRoot[0] = wrong2.subtreeRoot[0] xor 1
      let w2 = r.rawCall(6, "list_provider_exports", empty(), wrong2)
      check w2.code == ecInvalidParams and w2.protocol
      check r.s.closedWithin(EndMs)
      r.close()
      c.down(d)

    test "[RUN-0337] [RUN-0338] [RUN-0598] [IMPL-DECISION G415] O1: an empty subject, a module-only subject and an instances subject naming the forwarded consumer's instance id do not match it; a runtimes subject naming its Runtime does":
      let c = newCase(
        @[
          rcAllow(["list_remote_listeners"], LcnApSubject()),
          rcAllow(["list_provider_exports"], LcnApSubject(modules: Opt.some(@["m"]))),
          rcAllow(["list_routes"], LcnApSubject(instances: Opt.some(@[Consumer]))),
          rcAllow(["list_modules"]),
        ]
      )
      let d = c.up()
      var r = c.rcOpen(c.ports[0])
      check r.call("list_remote_listeners", empty()).code == ecNotAuthorised
      check r.call("list_provider_exports", empty()).code == ecNotAuthorised
      check r.call("list_routes", empty()).code == ecNotAuthorised
      check r.call("list_modules", empty()).code == ecOk
      r.close()
      c.down(d)

  suite "remote: inbound Runtime Control, forwarded discovery [RUNTIME l.2750-2767; G413]":
    teardown:
      killAll()

    test "[RUN-0092] [RUN-0514] [RUN-0516] [RUN-0517] [RUN-0518] [RUN-0622] [RUN-0618] [RUN-0985] [RUN-0510] [IMPL-DECISION G413] a provider is shown to a forwarded consumer only while an enabled export through an enabled listener names it, and a configured provider and an allowed discover export nothing; an export of no listener record or of another Runtime's provider is INVALID_PARAMS, of an unknown provider NOT_AUTHORISED":
      let c = newCase(
        @[
          rcAllow(@ListenerMethods & @["list_modules", "describe_provider"]),
          discoverAllow(meterRoot),
        ],
        meter = true,
      )
      let d = c.up()
      let ls = c.ctlJson("module", "ls"){"result"}{"modules"}
      var provider = ""
      for m in ls:
        if m{"instance"}.getStr == MeterInstance:
          provider = m{"provider"}{"provider"}.getStr
      check provider.len > 0
      var r = c.rcOpen(c.ports[0])
      proc shown(r: var Rc): bool =
        let o = r.call("list_modules", empty())
        check o.ok
        for m in o.decoded(LogosNSRuntimeControlListModulesResponse).modules:
          if m.provider.isSome and m.provider.get.provider == provider:
            return true
        false

      proc described(r: var Rc): ErrorCode =
        let o = r.call(
          "describe_provider",
          toCbor(
            LogosNSRuntimeControlDescribeProviderRequest(
              provider: LogosNSRuntimeModuleProviderAddress(provider: provider)
            )
          ),
        )
        o.code

      # [RUN-0514, RUN-0516, RUN-0518, RUN-0622] Two enabled listeners, a
      # configured provider and a discover rule, and no export: hidden.
      check not r.shown
      check r.described == ecNotAuthorised
      # [RUN-0618, RUN-0985] An export needs its listener's record and a
      # provider of this Runtime.
      check r.setExport(1, provider, true).code == ecInvalidParams
      check r.setExport(c.ports[1], provider, true, runtime = IdB).code ==
        ecInvalidParams
      check r.setExport(c.ports[1], "p-unknown", true).code == ecNotAuthorised
      # Through the disabled listener: allowed, and still hidden.
      check r.setExport(c.ports[2], provider, true).code == ecOk
      check not r.shown
      check r.described == ecNotAuthorised
      # [RUN-0092] Through an enabled listener: shown.
      let e = r.setExport(c.ports[1], provider, true)
      check e.code == ecOk
      if e.ok:
        let x = e.decoded(LogosNSRuntimeControlSetProviderExportResponse).`export`
        check x.provider.runtime_instance_id == Opt.some(c.rid) # [RUN-0510]
      check r.shown
      # Disclosed: past its authorization, it has not been bound, so it has
      # no surface to describe yet.
      check r.described == ecNotReady
      # Disabled again: hidden.
      check r.setExport(c.ports[1], provider, false).code == ecOk
      check not r.shown
      check r.described == ecNotAuthorised
      r.close()
      c.down(d)

  suite "remote: listener and export records through remote Runtime Control [RUNTIME l.3289-3322; G412, Q4]":
    teardown:
      killAll()

    test "[RUN-0509] [RUN-0616] [RUN-0617] [RUN-0595] [RUN-0596] [IMPL-DECISION G412] turning Runtime Control off on a listener ends its Runtime Control sessions and refuses new ones; disabling it stops new connections; both stay off across a SIGKILL right after the answer and a restart; an enable through Runtime Control lifts them":
      let c = newCase(@[rcAllow(ListenerMethods)])
      let d = c.up()
      let p2 = c.ports[1]
      var r = c.rcOpen(c.ports[0])
      var r2 = c.rcOpen(p2)
      check r2.call("list_remote_listeners", empty()).code == ecOk
      let off = r.setListener(p2, true, false)
      check off.code == ecOk
      # [RUN-0616, RUN-0617] Its sessions end; a new Hello there is refused.
      check r2.s.closedWithin(EndMs)
      r2.close()
      let o = c.openWith(p2, helloOf(tokenOf(IdA)))
      check o.code == ecNotAuthorised
      if o.s != nil:
        waitFor o.s.close()
      check c.serves(p2) # the listener itself still accepts
      # Disabled, and logosd killed as soon as the answer came.
      check r.setListener(p2, false, false).code == ecOk
      killChild(d)
      r.close()
      let d2 = c.up()
      check not c.serves(p2)
      r = c.rcOpen(c.ports[0])
      let l2 = r.listenerAt(p2)
      check l2.isSome and not l2.get.enabled and not l2.get.runtime_control_enabled
      # Lifted by an enable through Runtime Control.
      check r.setListener(p2, true, true).code == ecOk
      check c.serves(p2)
      r.close()
      c.down(d2)
      # [RUN-0595, RUN-0596] Each change through Runtime Control is logged
      # with its consumer, its origin and the resulting state; the
      # configuration's records are not.
      let changed =
        "remote listener tls-tcp 127.0.0.1:" & $p2 &
        ": enabled true, runtime_control_enabled true, set by " & Consumer &
        " of Runtime " & IdA & " through Runtime Control"
      check changed in d2.errText
      check "tls-tcp 127.0.0.1:" & $c.ports[0] & ": enabled" notin d2.errText
      check listenerLine(p2) notin c.exposureText
      let d3 = c.up()
      var r3 = c.rcOpen(p2)
      check r3.call("get_self", empty()).code == ecOk
      r3.close()
      c.down(d3)

    test "[RUN-0613] [RUN-0516] [IMPL-DECISION G412] [IMPL-DECISION G411] an enable through Runtime Control lasts for the run, and a rule allowing it enables nothing: its listener process, started on the supervision thread, serves after the call's session ends; the next start applies the configuration":
      let c = newCase(@[rcAllow(ListenerMethods)])
      let p3 = c.ports[2]
      let d = c.up()
      check not c.serves(p3)
      var r = c.rcOpen(c.ports[0])
      let on = r.setListener(p3, true, true)
      check on.code == ecOk
      if on.ok:
        check on.decoded(LogosNSRuntimeControlSetRemoteListenerResponse).listener.enabled
      r.close()
      sleep(1_000)
      check c.serves(p3)
      var r3 = c.rcOpen(p3)
      check r3.call("get_self", empty()).code == ecOk
      r3.close()
      c.down(d)
      check listenerLine(p3) notin c.exposureText
      let d2 = c.up()
      check not c.serves(p3)
      c.down(d2)

    test "[RUN-0615] [IMPL-DECISION G412] a disable stops new connections at the address; the retained disable is listed offline, removed by `remote exposure reset`, and dropped when its configuration entry changes":
      let c = newCase(@[rcAllow(ListenerMethods)])
      let p2 = c.ports[1]
      let d = c.up()
      var r = c.rcOpen(c.ports[0])
      check c.serves(p2)
      check r.setListener(p2, false, true).code == ecOk
      check not c.serves(p2)
      r.close()
      c.down(d)
      let listed = c.exposureText
      check listenerLine(p2) in listed
      check c.ctl("remote", "exposure", "reset", "--all").code == 0
      check listenerLine(p2) notin c.exposureText
      let d2 = c.up()
      check c.serves(p2)
      r = c.rcOpen(c.ports[0])
      check r.setListener(p2, false, true).code == ecOk
      r.close()
      c.down(d2)
      check listenerLine(p2) in c.exposureText
      # The configuration entry changes: the disable no longer applies.
      let (raw, _) = readDaemonConfig(c.s).expect("the configuration")
      var dc = raw
      var x = dc.remote.get
      var ls = x.listeners.get
      ls[1].runtime_control_enabled = false
      x.listeners = Opt.some(ls)
      dc.remote = Opt.some(x)
      c.setConfig(dc)
      let d3 = c.up()
      check c.serves(p2) # enabled, as the changed entry says
      let o = c.openWith(p2, helloOf(tokenOf(IdA)))
      check o.code == ecNotAuthorised # and without Runtime Control
      if o.s != nil:
        waitFor o.s.close()
      c.down(d3)
      check listenerLine(p2) notin c.exposureText

    test "[RUN-0988] [RUN-0989] [IMPL-DECISION G412] a disable whose record cannot be written: the listener is off for the run and the answer MODULE_ERROR says it was not recorded; once the write succeeds a repeat records it; an enable whose removal fails leaves it off":
      let c = newCase(@[rcAllow(ListenerMethods)])
      let p2 = c.ports[1]
      let failFile = c.dir / "exposure.fail"
      let env = [("LCN_REMOTE_TEST_EXPOSURE_FAIL_FILE", failFile)]
      let d = c.up(env)
      var r = c.rcOpen(c.ports[0])
      var r2 = c.rcOpen(p2)
      writeFile(failFile, "")
      let o = r.setListener(p2, false, true)
      check o.code == ecModule
      check "not recorded" in o.message
      # [RUN-0989] A failed write is no readiness failure: the Runtime serves on.
      check r.call("get_self", empty()).code == ecOk
      check r2.s.closedWithin(EndMs)
      r2.close()
      check not c.serves(p2)
      removeFile(failFile)
      check r.setListener(p2, false, true).code == ecOk
      r.close()
      c.down(d)
      check listenerLine(p2) in c.exposureText
      # The enable's removal of the entry fails: the listener stays off.
      let d2 = c.up(env)
      r = c.rcOpen(c.ports[0])
      writeFile(failFile, "")
      check r.setListener(p2, true, true).code == ecModule
      check not c.serves(p2)
      removeFile(failFile)
      check r.setListener(p2, true, true).code == ecOk
      check c.serves(p2)
      r.close()
      c.down(d2)
      check listenerLine(p2) notin c.exposureText

    test "[RUN-0502] [RUN-0503] [RUN-0613] [TRN-0206] [RUN-0614] [RUN-0984] [RUN-0986] [RUN-0987] [IMPL-DECISION G412] the methods' errors: an address with path INVALID_PARAMS, with server_name kept; an address contradicting its profile INVALID_PARAMS without detail; a quic record kept disabled and its enable MODULE_ERROR; a bind failure TRANSPORT_ERROR; the state unchanged by each failure":
      let c = newCase(@[rcAllow(ListenerMethods)])
      let d = c.up()
      var r = c.rcOpen(c.ports[0])
      let before = r.listeners
      # [RUN-0984, RUN-0986] A tls-tcp address naming the quic profile.
      let bad = r.setRecord(rcAddress(c.ports[2], "logos.remote.quic"), false)
      check bad.code == ecInvalidParams
      check bad.ok or bad.failure.detail.isNone
      # [RUN-0502, RUN-0503] An address with `path`: refused by the schema,
      # an error Response that leaves the session open; one with
      # `server_name`: kept. The raw Requests go on a connection of their own,
      # since their ids are not the caller's (ids only increase, TRANSPORT
      # §2.1).
      var rp = c.rcOpen(c.ports[0])
      for quic in [false, true]:
        let address =
          (if quic: quicAddress(c.ports[2] + 2) else: rcAddress(c.ports[2] + 3))
        let valid = toCbor(
          LogosNSRuntimeControlSetRemoteListenerRequest(
            listener: LogosNSRuntimeControlRemoteListenerRecord(
              address: address, enabled: false, runtime_control_enabled: false
            )
          )
        )
        let commitment =
          rcB.commitRequest("set_remote_listener", valid).expect("a commitment")
        let withPath = withAddressField(valid, "path", cbor("/tmp/x"))
        let withPathAnswer =
          rp.rawCall(uint64(1 + ord(quic)), "set_remote_listener", withPath, commitment)
        check withPathAnswer.code == ecInvalidParams
        check not withPathAnswer.protocol
      rp.close()
      var named = rcAddress(c.ports[2] + 4)
      named.arm_logos_NS_runtime_control_Tls_tcp_runtime_address.server_name =
        Opt.some("peer.example")
      check r.setRecord(named, false).code == ecOk
      let kept = r.listenerAt(c.ports[2] + 4)
      check kept.isSome and
        kept.get.address.arm_logos_NS_runtime_control_Tls_tcp_runtime_address.server_name ==
        Opt.some("peer.example")
      # [RUN-0503] A quic record, disabled: kept. Enabling it: MODULE_ERROR.
      let qport = c.ports[2] + 1
      check r.setRecord(quicAddress(qport), false).code == ecOk
      let qon = r.setRecord(quicAddress(qport), true)
      check qon.code == ecModule
      var quics = 0
      for l in r.listeners:
        if l.address.isQuic:
          inc quics
          check not l.enabled
      check quics == 1
      # The records the failures touched are as before, plus the quic one and
      # the one with a server name.
      let beforeBind = r.listeners
      check beforeBind.len == before.len + 2
      # [RUN-0987, RUN-0614] A port another socket holds: TRANSPORT_ERROR and
      # the records unchanged. Its port may be one a record above names, so
      # the lists are compared whole.
      let (held, hport) = boundListener()
      let t = r.setListener(hport, true, true)
      check t.code == ecTransport
      check r.listeners.cborEach == beforeBind.cborEach
      let l = r.listenerAt(hport)
      check l.isNone or not l.get.enabled
      discard close(held)
      r.close()
      c.down(d)

    test "[IMPL-DECISION G413] the interims: establish_route for a forwarded consumer is MODULE_ERROR once authorized (NOT_AUTHORISED before), and a Runtime Control event subscription MODULE_ERROR":
      let c = newCase(@[rcAllow(["establish_route"])])
      let d = c.up()
      var r = c.rcOpen(c.ports[0])
      let req = toCbor(
        LogosNSRuntimeControlEstablishRouteRequest(
          request_key: "k1",
          contract: SchemaCommitment(schema_root: meterRoot),
          cardinality: LogosNSRuntimeControlProviderRequirementCardinality(
            kind: LogosNSRuntimeControlProviderRequirementCardinalityKind.Single
          ),
          access: LogosNSRuntimeControlRouteAccess(),
        )
      )
      let er = r.call("establish_route", req)
      check er.code == ecModule
      check "remote" in er.message
      let sub = r.c.subscribe(7, "logos.runtime_control.inventory_changed_event")
      if sub.isErr:
        checkpoint("subscribe: " & $sub.error.code & " " & sub.error.msg)
      check sub.isOk
      if sub.isOk:
        check (waitFor r.s.writeFrame(sub.get)).isOk
        let f = r.s.readWithin(AnswerMs)
        check f.isOk and f.get.isSome
        if f.isOk and f.get.isSome:
          let m = decodeMessage(f.get.get).expect("a message")
          check m.kind == mkSubscriptionResult
          if m.kind == mkSubscriptionResult:
            check m.subscriptionResult.failure.isSome
            if m.subscriptionResult.failure.isSome:
              check m.subscriptionResult.failure.get.code == ecModule
      r.close()
      c.down(d)
      let c2 = newCase(@[rcAllow(["list_modules"])])
      let d2 = c2.up()
      var r2 = c2.rcOpen(c2.ports[0])
      check r2.call("establish_route", req).code == ecNotAuthorised
      r2.close()
      c2.down(d2)

  suite "remote: deployment input [RUNTIME l.3319-3322; G412]":
    teardown:
      # Leaves daemonproc's list of children without a payload before the
      # program ends, as each suite here does (ISSUES.md 194).
      killAll()

    test "[RUN-0621] [IMPL-DECISION G412] a configuration record is refused as Runtime Control refuses the same record: a tls-tcp address naming another profile":
      inc cases
      let dir = makeShortBase("lrc" & $cases, deepest = "/s/run/logosctl.sock")
      let s = Session(dir: dir / "s")
      var dc = defaultDaemonConfig(IdB) # a UUIDv4, as remote.enabled needs
      dc.runtime.remote_program = Opt.some(rExe)
      var t = LcnRcTlsTcpRuntimeAddress(host: "127.0.0.1", port: 4100)
      t.profile = Opt.some("logos.remote.quic")
      dc.remote = Opt.some(
        LcnDcRemote(
          enabled: true,
          listeners: Opt.some(
            @[
              LcnRcRemoteListenerRecord(
                address: LcnRcRemoteListenerAddress(
                  kind: LcnRcRemoteListenerAddressKind.lcn_Rc_tls_tcp_runtime_address,
                  arm_lcn_Rc_tls_tcp_runtime_address: t,
                ),
                enabled: false,
                runtime_control_enabled: false,
              )
            ]
          ),
        )
      )
      let path = dir / "candidate.cbor"
      writeFile(path, textOf(dc.encode.expect("an encoding")))
      let r = runOnce(
        ctlExe,
        @["--session-dir", s.dir, "--text", "daemon", "config", "check", "@" & path],
        dir,
        timeoutMs = 120_000 * Slow,
      )
      checkpoint(r.stdout & r.stderr)
      check r.code != 0
      check "profile" in (r.stdout & r.stderr)
