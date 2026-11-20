## The logosctl module and logosd's assembly, in-process (Tier 4b step 4b-6;
## DECISIONS G296, G302, G304; D13(a); K20; BOOTSTRAP l.384-390;
## docs/DAEMON.md §4, §7, §15).
##
## Each case makes a session with `logosctl init`'s library function, runs
## `assembleDaemon` and `startDaemon` on it as logosd's `main` does, and talks
## to the socket with `ctlwire` from the test thread. Teardown requests
## shutdown, waits, destroys and removes the directory, also on failure.
## logosd's process part (signals, exit codes) is `test_logosd`.

when defined(posix):
  import std/[atomics, hashes, locks, monotimes, os, sequtils, strutils, times]
  import unittest2
  import logos_sdk/cbor
  import logos_sdk/crypto/blake3
  from logos_sdk/base/perthread import releasePerThread
  import logos_sdk/iface/outcome
  from ../src/logos_core/runtime/plumbing import
    RcMethod, holdRcAnswerForTests, rcAnswerHeldForTests, releaseRcAnswerForTests
  import logos_sdk/abi/host as abihost
  import ../src/logos_core/runtime/[engine, host], logos_sdk/kit/[rc_arms, rc_types]
  from ../src/logos_core/durable import DurableLock, release
  from ../src/logos_core/loader/contract import LoaderInstanceId
  from ../src/logos_core/transport/io/peercred import effectiveUid
  import
    ../src/logos_core/daemon/
      [assemble, ctlmodule, ctlwire, daemon_config_types, logging, session, sessioninit]
  import logos_sdk/testing/kitbuild, ./support/[shortdir, slowdown]

  import std/posix

  const
    Patience = 60 * Slow
      ## seconds a bounding wait allows: 20 s times Slow did not cover a start
      ## at load 400 under refc and ASan (4b-8's load fix)
    Timeout = 15_000 * Slow ## a client's wait for a reply, ms
    IdleMs = min(60_000 * Slow, 600_000)
      ## `ctl.idle_timeout_ms` where no case is about it, at most what the
      ## daemon-config takes: at 2 s times Slow, RUN-0663's 16 clients under
      ## ASan at load 400 were closed before they sent their command (send:
      ## Broken pipe; 4b-8's load fix)

  # Captured log lines --------------------------------------------------------------------

  var
    logLock: Lock
    logBuf: ptr UncheckedArray[char]
    logLen: int
  const LogCap = 1 shl 20
  initLock(logLock)
  logBuf = cast[ptr UncheckedArray[char]](allocShared0(LogCap))

  proc capture(line: string) {.nimcall, gcsafe, raises: [].} =
    withLock logLock:
      for c in line & "\n":
        if logLen < LogCap:
          logBuf[logLen] = c
          inc logLen

  proc logText(): string =
    withLock logLock:
      result = newString(logLen)
      for i in 0 ..< logLen:
        result[i] = logBuf[i]

  proc clearLog() =
    withLock logLock:
      logLen = 0

  setLogSink(capture)

  var notified: Atomic[int]

  proc notifyTest() {.nimcall, gcsafe, raises: [].} =
    notified += 1

  # Sessions and daemons -----------------------------------------------------------------

  let sensorLib = buildKitLibrary("sensor_impl.nim", "ctlsensor")

  proc digestOfFile(path: string): seq[byte] =
    var h: Blake3Hasher
    h.init()
    let bytes = readFile(path)
    h.update(bytes.toOpenArrayByte(0, bytes.high))
    @(h.finish())

  proc sensorDeclaration(): LcnAppDeclaration =
    LcnAppDeclaration(
      module: "sensor_module",
      implementation: LcnAppImplementation(
        kind: LcnAppImplementationKind.Direct_dynamic,
        arm_Direct_dynamic: LcnAppImplementationARDirectDynamicMap(
          artifact: LcnAppArtifact(
            id: "sensor", local_path: sensorLib, hash: digestOfFile(sensorLib)
          )
        ),
      ),
    )

  var sessions = 0

  type Edit = proc(dc: var LcnDaemonConfig) {.closure.}

  proc newSession(edit: Edit = nil, development = false): Session =
    inc sessions
    let base = makeShortBase("ctl" & $sessions, deepest = "/s/run/logosctl.sock")
    let s = Session(dir: base / "s")
    var dc = defaultDaemonConfig("assigned-by-init")
    dc.declarations = Opt.some(@[sensorDeclaration()])
    dc.ctl = Opt.some(
      LcnDcCtl(workers: Opt.some(4'u8), idle_timeout_ms: Opt.some(uint32(IdleMs)))
    )
    if edit != nil:
      edit(dc)
    let r = initSession(s, InitOptions(config: Opt.some(dc), development: development))
    doAssert r.isOk, "init: " & r.error
    s

  type Live = object
    s: Session
    d: Daemon
    lock: DurableLock
    up: bool
    unstarted: bool ## assembled, and no start has succeeded

  var live: ptr Live ## what the teardown ends, if a case left it running

  proc assembled(s: Session): Live =
    result.s = s
    result.lock = lockSession(s).expect("the session lock")
    let d = assembleDaemon(s, AssembleOptions(version: "test", notify: notifyTest))
    doAssert d.isOk, "assemble: " & d.error.message
    result.d = d.get
    result.unstarted = true
    # [IMPL] The teardown's from now on, whatever the case does next: a
    # daemon left running reads the next case's handoff, which is
    # process-wide, and its logosctl takes that case's socket path.
    if live != nil:
      live[] = result

  proc boot(s: Session): Live =
    ## Starts, then waits for the socket: the orchestrator starts the logosctl
    ## instance after `runtimeStart` returns (DAEMON.md §4).
    result = assembled(s)
    let serving = "logosctl: serving " & result.d.socketPath
    let before = logText().count(serving)
    let r = startDaemon(result.d)
    doAssert r.isOk, "start: " & r.error.message
    result.up = true
    result.unstarted = false
    if live != nil:
      live[] = result # a failed wait below leaves it to the teardown
    let until = getMonoTime() + initDuration(seconds = Patience)
    while logText().count(serving) == before:
      doAssert getMonoTime() < until,
        "not serving: " & result.d.socketPath & "; the log:\n" & logText()
      sleep(5)

  proc finish(l: var Live) =
    if not l.up:
      return
    l.up = false
    discard runtimeRequestShutdown(l.d.rt)
    check int64(runtimeWaitForShutdown(l.d.rt).code) == 0
    check destroyRuntime(l.d).isOk
    l.d.release()
    l.lock.release()
    check not entryExists(l.d.socketPath)

  proc abandon(l: var Live) =
    ## A daemon assembled and never started, or whose start failed: destroyed
    ## as before a start, and released.
    l.unstarted = false
    check destroyRuntime(l.d).isOk
    l.d.release()
    l.lock.release()

  proc client(l: Live): cint =
    connectCtl(l.d.socketPath, Timeout).expect("a connection")

  proc ask(fd: cint, m: LcnCtlMessage): LcnCtlReply =
    roundTrip(fd, m, Timeout).expect("a reply")

  proc rc[Req](fd: cint, m: LcnCtlMethodKind, req: Req): LcnCtlReply =
    ask(fd, rcMessage(m, req.encode.expect("an encoding")))

  proc okBytes(r: LcnCtlReply): seq[byte] =
    check r.outcome.kind == LcnCtlOutcomeKind.lcn_Ctl_ok
    if r.outcome.kind == LcnCtlOutcomeKind.lcn_Ctl_ok:
      return r.outcome.arm_lcn_Ctl_ok.result.get(@[])

  proc rcCode(r: LcnCtlReply): ErrorCode =
    if r.outcome.kind != LcnCtlOutcomeKind.lcn_Ctl_rc_error:
      return ecOk
    errorCode(int64(r.outcome.arm_lcn_Ctl_rc_error.code)).get(ecModule)

  proc refusal(r: LcnCtlReply): string =
    if r.outcome.kind != LcnCtlOutcomeKind.lcn_Ctl_refused:
      return ""
    reasonOf(r.outcome.arm_lcn_Ctl_refused.reason.kind)

  func m(entries: varargs[(string, CborValue)]): CborValue =
    var xs: seq[CborEntry]
    for (k, v) in entries:
      xs.add((cbor(k), v))
    cborMap(xs)

  proc sendRaw(fd: cint, bytes: openArray[byte]) =
    check writeFrame(fd, bytes, Timeout).isOk

  proc readReply(fd: cint): LcnCtlReply =
    let f = readFrame(fd, Timeout).expect("a frame")
    LcnCtlReply.decode(f).expect("a reply")

  proc closedByPeer(fd: cint): bool =
    ## The connection was closed: EOF on the next read.
    let r = readFrame(fd, Timeout)
    r.isErr and r.error.kind == feEof

  proc waitUntil(cond: proc(): bool {.closure.}, seconds = Patience): bool =
    let until = getMonoTime() + initDuration(seconds = seconds)
    while getMonoTime() < until:
      if cond():
        return true
      sleep(5)
    cond()

  proc target(l: Live, instance: string): LogosNSRuntimeModuleInstanceAddress =
    LogosNSRuntimeModuleInstanceAddress(
      module_instance_id: instance,
      runtime_instance_id: l.d.prepared.config.value.runtime.runtime_instance_id,
    )

  proc modules(fd: cint): seq[LogosNSRuntimeControlModuleRecord] =
    let r =
      fd.rc(LcnCtlMethodKind.List_modules, LogosNSRuntimeControlListModulesRequest())
    LogosNSRuntimeControlListModulesResponse.decode(r.okBytes).expect("modules").modules

  proc createKeyed(l: Live, key: string): LcnCtlReply =
    let fd = l.client
    defer:
      closeFd(fd)
    fd.rc(
      LcnCtlMethodKind.Create_module,
      LogosNSRuntimeControlCreateModuleRequest(
        module: "sensor_module", request_key: key
      ),
    )

  var answers: array[16, Atomic[int]] ## each creator's reply, hashed

  proc creator(arg: (ptr Live, int)) {.thread.} =
    ## 8 creators share one request key; 8 have a key each.
    let (lp, i) = arg
    let key =
      if i < 8:
        "lcli-shared"
      else:
        "lcli-" & $i
    let r = lp[].createKeyed(key)
    answers[i].store(hash(encodeCbor(r.toCbor)))
    releasePerThread()

  proc starter(rt: ptr LogosRuntimeHandle) {.thread.} =
    doAssert int64(runtimeStart(rt).code) == 0
    releasePerThread()

  var
    startThread: Thread[ptr LogosRuntimeHandle] ## a case's `starter`
    starting: bool ## `startThread` runs and is not joined yet

  suite "daemon.ctl: the logosctl module and logosd's assembly (DAEMON.md §7) [IMPL-DECISION G296] [IMPL-DECISION G302]":
    setup:
      clearLog()
      notified.store(0)
      var l {.inject.} = Live()
      live = addr l

    teardown:
      # [IMPL] Also after a case that failed before its daemon was up: a hold
      # left on would hold the next case's logosctl init (4b-8's closing
      # check), and a start left running ends once it is released.
      when defined(lcnTestHooks):
        setCommandDelayForTests(0)
        holdInitForTests(false)
        setCredOfForTests(nil)
        releaseRcAnswerForTests()
      if live != nil:
        if starting:
          joinThread(startThread)
          starting = false
          live[].up = true
          live[].unstarted = false
        if live[].up:
          finish(live[])
        elif live[].unstarted:
          abandon(live[])
      live = nil

    test "[BCP-0090] [BCP-0084] [BCP-0089] daemon-info and get_self: the logosctl instance's own address; the log line carries the peer, the request does not":
      l = boot(newSession())
      let fd = l.client
      defer:
        closeFd(fd)
      let info = LcnCtlDaemonInfo.decode(fd.ask(infoMessage()).okBytes).expect("info")
      check info.version == "test"
      check info.runtime_instance_id ==
        l.d.prepared.config.value.runtime.runtime_instance_id
      check info.trust_revision == 1
      check info.socket == l.d.socketPath
      let me = LogosNSRuntimeControlGetSelfResponse
        .decode(
          fd.rc(LcnCtlMethodKind.Get_self, LogosNSRuntimeControlGetSelfRequest()).okBytes
        )
        .expect("get_self")
      check me.consumer.module_instance_id == "logosctl"
      check me.consumer.runtime_instance_id == info.runtime_instance_id
      let log = logText()
      check ("logosctl: get_self from uid " & $getuid() & " pid " & $getpid()) in log

    test "[BCP-0094] every reply names the deployment the handoff gave":
      l = boot(newSession())
      let fd = l.client
      check fd.ask(infoMessage()).deployment.isProduction
      closeFd(fd)
      finish(l)
      l = boot(newSession(development = true))
      let fd2 = l.client
      defer:
        closeFd(fd2)
      check not fd2.ask(infoMessage()).deployment.isProduction
      check not fd2.rc(LcnCtlMethodKind.Get_self, LogosNSRuntimeControlGetSelfRequest()).deployment.isProduction

    test "[BCP-0087] frames the module refuses: refused with a reason, the connection closed, no call made":
      l = boot(newSession())
      proc refusedWith(bytes: seq[byte]): string =
        let fd = l.client
        defer:
          closeFd(fd)
        sendRaw(fd, bytes)
        result = readReply(fd).refusal
        check closedByPeer(fd)

      let good = infoMessage().encode.expect("bytes")
      # Non-deterministic CBOR: a map's length in a longer head than needed.
      var loose = good
      loose[0] = 0xB8
      loose.insert(byte(good[0] and 0x1F), 1)
      check refusedWith(loose) == "protocol"
      # Another protocol.
      check refusedWith(
        encodeCbor(
          m(("protocol", cbor("other.v1")), ("command", m(("op", cbor("daemon-info")))))
        )
      ) == "protocol"
      # An unknown key, and a method outside the set.
      check refusedWith(
        encodeCbor(
          m(
            ("protocol", cbor(CtlProtocol)),
            ("command", m(("op", cbor("daemon-info")))),
            ("extra", cbor(1)),
          )
        )
      ) == "command"
      check refusedWith(
        encodeCbor(
          m(
            ("protocol", cbor(CtlProtocol)),
            (
              "command",
              m(
                ("op", cbor("rc")),
                ("method", cbor("evaluate")),
                ("params", cbor(newSeq[byte]())),
              ),
            ),
          )
        )
      ) == "command"
      # A length beyond the bound: refused before the body is read.
      let fd = l.client
      defer:
        closeFd(fd)
      let n = uint32(MaxFrameBytes + 1)
      let header = [byte(n shr 24), byte(n shr 16), byte(n shr 8), byte(n)]
      check posix.write(fd, unsafeAddr header[0], 4) == 4
      check readReply(fd).refusal == "too-large"
      check closedByPeer(fd)
      check "logosctl: evaluate" notin logText()
      check "logosctl: daemon-info from" notin logText()

    test "a partial frame, then nothing: closed after the idle timeout":
      l = boot(
        newSession(
          proc(dc: var LcnDaemonConfig) =
            dc.ctl = Opt.some(LcnDcCtl(idle_timeout_ms: Opt.some(uint32(300))))
        )
      )
      let fd = l.client
      defer:
        closeFd(fd)
      let part = [byte 0, 0, 0, 9, 0xA1]
      check posix.write(fd, unsafeAddr part[0], part.len) == part.len
      let t0 = getMonoTime()
      let r = readFrame(fd, Timeout)
      check r.isErr and r.error.kind == feEof
      check inMilliseconds(getMonoTime() - t0) >= 250

    test "[BCP-0089] [K20] a peer of another uid is closed with nothing written, and logged; the shell refuses a listener of another uid before sending":
      l = boot(newSession())
      when defined(lcnTestHooks):
        setCredOfForTests(
          proc(fd: cint): Result[Peer, string] {.nimcall, gcsafe, raises: [].} =
            ok(Peer(uid: effectiveUid() + 1, pid: Opt.some(int32(4242))))
        )
        let fd = l.client
        defer:
          closeFd(fd)
        check closedByPeer(fd)
        check waitUntil(
          proc(): bool =
            "refused a connection from uid " & $(getuid() + 1) & " pid 4242" in logText()
        )
        setCredOfForTests(nil)
        let other = connectCtl(
          l.d.socketPath,
          Timeout,
          proc(fd: cint): Result[Peer, string] {.nimcall, gcsafe, raises: [].} =
            ok(Peer(uid: effectiveUid() + 1, pid: Opt.none(int32))),
        )
        check other.isErr
        check "nothing was sent" in other.error
        check "logosctl: daemon-info" notin logText()

    test "busy: with one worker held by a command, a second connection is answered busy":
      l = boot(
        newSession(
          proc(dc: var LcnDaemonConfig) =
            dc.ctl = Opt.some(LcnDcCtl(workers: Opt.some(1'u8)))
        )
      )
      when defined(lcnTestHooks):
        setCommandDelayForTests(1_000 * Slow)
        let a = l.client
        defer:
          closeFd(a)
        sendRaw(a, infoMessage().encode.expect("bytes"))
        sleep(100)
        let b = l.client
        defer:
          closeFd(b)
        check readReply(b).refusal == "busy"
        check closedByPeer(b)
        check readReply(a).outcome.kind == LcnCtlOutcomeKind.lcn_Ctl_ok
        setCommandDelayForTests(0)

    test "[RUN-0663] create_module: 16 concurrent commands, 8 with distinct keys and 8 with one shared key, make 9 instances with 8 equal answers; the key holds across a restart":
      l = boot(
        newSession(
          proc(dc: var LcnDaemonConfig) =
            dc.ctl = Opt.some(
              LcnDcCtl(
                workers: Opt.some(16'u8), idle_timeout_ms: Opt.some(uint32(IdleMs))
              )
            )
        )
      )
      var threads: array[16, Thread[(ptr Live, int)]]
      for i in 0 ..< 16:
        createThread(threads[i], creator, (addr l, i))
      joinThreads(threads)
      for i in 1 ..< 8:
        check answers[i].load == answers[0].load
      let fd = l.client
      let made = fd.modules.filterIt(it.module == "sensor_module")
      closeFd(fd)
      check made.len == 9
      let shared = LogosNSRuntimeControlCreateModuleResponse
        .decode(l.createKeyed("lcli-shared").okBytes)
        .expect("created").accepted.get
      let s = l.s
      finish(l)
      l = boot(s)
      let again = LogosNSRuntimeControlCreateModuleResponse
        .decode(l.createKeyed("lcli-shared").okBytes)
        .expect("created").accepted.get
      check again.instance == shared.instance

    test "[RUN-0698] the system instances: stop and update_configuration NOT_AUTHORISED for logosctl; recover_module on a failed orchestrator succeeds":
      l = boot(newSession())
      let fd = l.client
      defer:
        closeFd(fd)
      for (module, instance) in [
        ("logos_module_loader", LoaderInstanceId),
        ("logos_capability_authority", "authority"),
        ("logosctl", "logosctl"),
        ("lcn_orchestrator", "orchestrator"),
      ]:
        let stop = fd.rc(
          LcnCtlMethodKind.Stop_module,
          LogosNSRuntimeControlStopModuleRequest(
            module: module, instance: Opt.some(instance)
          ),
        )
        check stop.rcCode == ecNotAuthorised
        let upd = fd.rc(
          LcnCtlMethodKind.Update_configuration,
          LogosNSRuntimeControlUpdateConfigurationRequest(
            kind: LogosNSRuntimeControlUpdateConfigurationRequestKind.Discard,
            arm_Discard: LogosNSRuntimeControlUpdateConfigurationRequestARDiscardMap(
              target: l.target(instance),
              expected_schema_commitment: LogosNSModuleConfigurationSchemaCommitment(
                schema_root: newSeq[byte](32), schema_subtree_root: newSeq[byte](32)
              ),
            ),
          ),
        )
        check upd.rcCode == ecNotAuthorised
      let e = engineOf(l.d.rt)
      let v = e.view("orchestrator").expect("a view")
      check e.reportFailure("orchestrator", v.attempt, "test").isOk
      check waitUntil(
        proc(): bool =
          e.view("orchestrator").expect("a view").state == msError
      )
      # [RUNTIME l.613, l.3538] The instance is `error` before its realization's
      # cleanup ends, and that cleanup commits again: a revision read before it
      # would be stale (`stale-revision`), and a recovery before it NOT_READY.
      check waitUntil(
        proc(): bool =
          not e.cleanupPending("orchestrator")
      )
      let rec = fd.modules.filterIt(it.instance == Opt.some("orchestrator"))[0]
      let r = fd.rc(
        LcnCtlMethodKind.Recover_module,
        LogosNSRuntimeControlRecoverModuleRequest(
          instance: "orchestrator",
          module: "lcn_orchestrator",
          expected_execution_revision: rec.execution.get.revision,
        ),
      )
      check r.rcCode == ecOk

    test "list_routes through the socket: no record carries an invocation (RUNTIME l.3365)":
      l = boot(newSession())
      let fd = l.client
      defer:
        closeFd(fd)
      let r =
        fd.rc(LcnCtlMethodKind.List_routes, LogosNSRuntimeControlListRoutesRequest())
      let routes = LogosNSRuntimeControlListRoutesResponse
        .decode(r.okBytes)
        .expect("routes").routes
      for x in routes:
        check x.invocation.isNone

    test "shutdown_runtime through the socket is answered, then the wait returns":
      l = boot(newSession())
      let fd = l.client
      defer:
        closeFd(fd)
      let r = fd.rc(
        LcnCtlMethodKind.Shutdown_runtime, LogosNSRuntimeControlShutdownRuntimeRequest()
      )
      check r.rcCode == ecOk
      check int64(runtimeWaitForShutdown(l.d.rt).code) == 0
      check destroyRuntime(l.d).isOk
      l.d.release()
      l.lock.release()
      l.up = false
      check not entryExists(l.d.socketPath)

    test "[I97] shutdown_runtime whose answer is still on its way when the instance closes: the socket gets the Runtime's answer, not CANCELLED":
      when defined(lcnTestHooks):
        l = boot(newSession())
        holdRcAnswerForTests(rmShutdownRuntime)
        let fd = l.client
        defer:
          closeFd(fd)
        sendRaw(
          fd,
          rcMessage(
            LcnCtlMethodKind.Shutdown_runtime,
            LogosNSRuntimeControlShutdownRuntimeRequest().encode.expect("bytes"),
          ).encode
            .expect("bytes"),
        )
        # The Runtime has accepted and begun shutting down; the answer waits on
        # its call worker while the instance's destroy sets `closing`.
        check waitUntil(rcAnswerHeldForTests)
        check waitUntil(closingSeenForTests)
        releaseRcAnswerForTests()
        let r = readReply(fd)
        check r.outcome.kind == LcnCtlOutcomeKind.lcn_Ctl_ok
        check r.rcCode == ecOk
        check int64(runtimeWaitForShutdown(l.d.rt).code) == 0
        check destroyRuntime(l.d).isOk
        l.d.release()
        l.lock.release()
        l.up = false
        check not entryExists(l.d.socketPath)

    test "[I97] any other call whose answer is still on its way when the instance closes is CANCELLED":
      when defined(lcnTestHooks):
        l = boot(newSession())
        holdRcAnswerForTests(rmListRoutes)
        let fd = l.client
        defer:
          closeFd(fd)
        sendRaw(
          fd,
          rcMessage(
            LcnCtlMethodKind.List_routes,
            LogosNSRuntimeControlListRoutesRequest().encode.expect("bytes"),
          ).encode
            .expect("bytes"),
        )
        check waitUntil(rcAnswerHeldForTests)
        discard runtimeRequestShutdown(l.d.rt)
        check waitUntil(closingSeenForTests)
        releaseRcAnswerForTests()
        check readReply(fd).rcCode == ecCancelled
        check int64(runtimeWaitForShutdown(l.d.rt).code) == 0
        check destroyRuntime(l.d).isOk
        l.d.release()
        l.lock.release()
        l.up = false
        check not entryExists(l.d.socketPath)

    test "a stop while a command is in flight: the command gets its answer or CANCELLED; the socket is gone; every thread joined":
      l = boot(newSession())
      when defined(lcnTestHooks):
        setCommandDelayForTests(500 * Slow)
        let fd = l.client
        defer:
          closeFd(fd)
        sendRaw(
          fd,
          rcMessage(
            LcnCtlMethodKind.Get_self,
            LogosNSRuntimeControlGetSelfRequest().encode.expect("bytes"),
          ).encode
            .expect("bytes"),
        )
        sleep(50)
        discard runtimeRequestShutdown(l.d.rt)
        let r = readFrame(fd, Timeout)
        if r.isOk:
          let reply = LcnCtlReply.decode(r.get).expect("a reply")
          check reply.outcome.kind in {
            LcnCtlOutcomeKind.lcn_Ctl_ok, LcnCtlOutcomeKind.lcn_Ctl_rc_error,
            LcnCtlOutcomeKind.lcn_Ctl_refused,
          }
        setCommandDelayForTests(0)
        check int64(runtimeWaitForShutdown(l.d.rt).code) == 0
        check destroyRuntime(l.d).isOk
        l.d.release()
        l.lock.release()
        l.up = false
        check not entryExists(l.d.socketPath)

    test "[BCP-0086] [BCP-0088] [BCP-0021] [BCP-0022] [BCP-0023] [BCP-0024] the order: no answer before init returned; the socket only once the Loader realizes logosctl; every instance through the Loader":
      when defined(lcnTestHooks):
        holdInitForTests(true)
        l = assembled(newSession())
        check not entryExists(l.d.socketPath)
        createThread(startThread, starter, l.d.rt)
        starting = true
        # [IMPL] Only bounds the wait: the start reaches logosctl's init after
        # the orchestrator and the authority, which took longer than 20 s
        # times Slow under ASan on a host at load 100 (4b-8's closing check).
        let reached = waitUntil(
          proc(): bool =
            initWaitingForTests(),
          seconds = 60 * Slow,
        )
        # If it was not, the teardown releases init, joins the start and ends
        # the daemon.
        check reached
        if reached:
          check entryExists(l.d.socketPath)
          let fd = l.client
          defer:
            closeFd(fd)
          sendRaw(fd, infoMessage().encode.expect("bytes"))
          var none = TPollfd(fd: fd, events: POLLIN)
          check poll(addr none, 1, cint(200)) == 0 # held: no answer yet
          holdInitForTests(false)
          check readReply(fd).outcome.kind == LcnCtlOutcomeKind.lcn_Ctl_ok
          joinThread(startThread)
          starting = false
          l.up = true
          l.unstarted = false
          let journal = engineOf(l.d.rt).loaderJournalForTests()
          let realized = journal.filterIt(it.meth == "realize").mapIt(it.instance)
          check realized.len >= 3
          check realized[0] == "orchestrator"
          for i in ["orchestrator", "authority", "logosctl"]:
            check i in realized
          check LoaderInstanceId notin realized

    test "[G302] [G304] a Loader loss: the hook fires with its instances, the supervisor requests shutdown, the wait names the loss; destroy is not attempted":
      when defined(lcnTestHooks):
        l = boot(newSession())
        check failLoaderForTests(l.d.rt).isOk
        check waitUntil(
          proc(): bool =
            notified.load > 0
        )
        check l.d.supervisor.loaderLost.isSome
        check onLoaderLoss(l.d.supervisor, l.d.rt)
        let w = runtimeWaitForShutdown(l.d.rt)
        check errorCode(int64(w.code)).get(ecOk) == ecModule
        check "the host process must end" in $w.message
        check "termination required" in logText()
        # The process would end here (exit 4); the test confirms the termination
        # instead, as the protected mechanism would, then destroys.
        confirmTerminationForTests(engineOf(l.d.rt))
        check destroyRuntime(l.d).isOk
        l.d.release()
        l.lock.release()
        l.up = false
else:
  import unittest2

  suite "daemon.ctl: the logosctl module (POSIX only)":
    test "[IMPL] the logosctl socket needs unix-stream; logosd is not built on this platform":
      skip()
