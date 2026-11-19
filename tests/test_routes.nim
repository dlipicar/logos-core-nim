## Runtime Control and direct routes (`runtime/bindings.nim`, `runtime/engine.nim`):
## the Runtime Control binding each attempt gets (RUNTIME §9, §9.3), route
## establishment, renewal and closure (§4, §9.3), `materialize_route` and
## route handles (INTERFACE §2.5, §5.2; RUNTIME §4.1, §7.5), invocation access
## (INTERFACE §2.9.3), and the lifecycle methods through Runtime Control.
##
## The provider is the meter kit module; the consumer is a hand-written module
## that keeps the Runtime Control binding of each initialization, so the test
## calls Runtime Control as that module. Module code runs on the engine's
## workers, so the test modules keep their state in atomics.

import std/[atomics, monotimes, os, sequtils, strutils, tables, times, typedthreads]
import unittest2
import ../src/logos_core/runtime/engine
import logos_sdk/abi/[checks, types]
import ../src/logos_core/runtime/[invoke, remotemarked, routes]
import ./support/rcaddresses
import logos_sdk/cbor
import logos_sdk/commitment
import logos_sdk/iface/[accept, outcome, provider, surface]
import logos_sdk/codegen/common_types
import logos_sdk/testing/[kitbuild, kitruntime]
import logos_sdk/testing/fixtures/[meter_impl, sensor_impl]
import logos_sdk/testing/generated/meter_module_calls

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "routes" / kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

let
  sensorReg = checkStaticRegistration("sensor", sensorModuleStaticSymbols()).tryGet
  sensorSet = block:
    # The contracts the sensor provider's call surface resolves to.
    let b = bindNative(
      ModuleCode(kind: codeStatic, table: sensorReg.symbols), "sensor_module"
    ).tryGet.contracts
    acceptContractSet(
      b.primary.get.source, b.interfaces.mapIt(it.source), b.supporting.mapIt(it.source)
    ).tryGet

proc sensor(): ModuleRecord =
  ModuleRecord(
    module: "sensor_module",
    strategy: stDirectStatic,
    binding: "sensor",
    primaryContract: Opt.some(sensorSet.primary.root),
    implements: @[sensorSet.interfaces[0].root],
  )

func responseOf(schema: string, ifaces, supporting: seq[Contract]): seq[byte] =
  ## A `logos.schema_response` of these documents, as given.
  encodeCbor(
    cborMap(
      (cbor("interface_schemas"), cborArray(ifaces.mapIt(supportingEntry(it)))),
      (cbor("schema"), cbor(schema)),
      (cbor("supporting_schemas"), cborArray(supporting.mapIt(supportingEntry(it)))),
    )
  )

var subEndCalls: Atomic[int]

proc onSubEnd(
    id: LogosSubscriptionId, reason: CErrorCode, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  subEndCalls.atomicInc

proc registerSubEnd(
    h: var LogosRouteHandle, handler: LogosSubscriptionEndHandler = onSubEnd
): ErrorCode =
  toResult(h.vtable.observeSubscriptionEnd(addr h, handler, nil)).code

proc registerSubEnd(
    rc: ptr LogosRuntimeControlBinding, handler: LogosSubscriptionEndHandler = onSubEnd
): ErrorCode =
  toResult(rc.vtable.observeSubscriptionEnd(rc, handler, nil)).code

# Tests --------------------------------------------------------------------------------

suite "run.routes: Runtime Control binding (RUNTIME §9, §9.3; INTERFACE §5.2)":
  test "[RUN-0490] [RUN-0492] a generated Runtime identity is a lowercase UUID version 4 (§9.2 l.2669)":
    let id = newRuntimeInstanceId()
    check id.len == 36
    check id[8] == '-' and id[13] == '-' and id[14] == '4' and id[18] == '-'
    check id[19] in {'8', '9', 'a', 'b'}
    for c in id:
      check c in {'0' .. '9', 'a' .. 'f', '-'}
    check newRuntimeInstanceId() != id

  test "[RUN-0292] [RUN-0783] [RUN-0896] [RUN-0901] [RUN-0902] [RUN-0908] [RUN-0909] get_self and get_execution_permissions are caller-bound (§9.3 l.2553, l.2562)":
    let e = fixtureEngine(config(denying(deny(action = Opt.some(aaRuntimeControl)))))
    let (c, rc) = e.startClient()
    let r = rcCall(rc, "get_self", [0xA0'u8])
    check r.code == ecOk
    let me = LogosNSRuntimeControlGetSelfResponse.decode(r.response).tryGet
    check me.consumer.module_instance_id == c.instance
    check me.consumer.runtime_instance_id == e.runtimeInstanceId
    let p = rcCall(rc, "get_execution_permissions", [0xA0'u8])
    check p.code == ecOk
    check LogosNSRuntimeControlGetExecutionPermissionsResponse.decode(p.response).tryGet.kind ==
      LogosNSRuntimeControlGetExecutionPermissionsResponseKind.Unavailable
    # A method needing a policy grant is refused by the same policy.
    check rcCall(rc, "shutdown_runtime", [0xA0'u8]).code == ecNotAuthorised
    e.finish()

  test "[RUN-0897] [RUN-0905] [IFC-0521] get_self is callable during initialization (§9.3 l.2557)":
    initProbe.store(true)
    initSelfCode.store(-1)
    let e = fixtureEngine(config())
    discard e.startClient()
    initProbe.store(false)
    check initSelfCode.load == ord(ecOk)
    e.finish()

  test "[RUN-0293] the binding a module receives at initialization is the complete version-3 table (§8.1 l.1478)":
    let e = fixtureEngine(config())
    let (_, rc) = e.startClient()
    check checkRuntimeControl(rc).isOk
    check rc.state != nil
    check rc.vtable.abiVersion == RuntimeControlVtableAbiVersion
    check rc.vtable.structSize == csize_t(sizeof(LogosRuntimeControlVtable))
    e.finish()

  test "[RUN-0899] [RUN-0903] a call without an authenticated, realization-bound association is NOT_AUTHORISED (§9.3 l.2553, l.2563)":
    let e = fixtureEngine(config())
    let (c, rc) = e.startClient()
    for bare in ["get_self", "get_execution_permissions"]:
      # An attempt token the Runtime never issued, and an unknown instance.
      for (instance, attempt) in [
        (c.instance, "attempt-never-issued"), ("m-unknown", "a")
      ]:
        let r = rcInvoke(e, instance, attempt, bare, @[0xA0'u8])
        check r.isErr
        check r.error.code == ecNotAuthorised
      # The binding the instance received still answers.
      check rcCall(rc, bare, [0xA0'u8]).code == ecOk
    e.finish()

  test "[RUN-0042] [IFC-0416] [IFC-0418] [IFC-0419] method names and requests are checked before anything else (INTERFACE §4.5)":
    let e = fixtureEngine(config())
    let (_, rc) = e.startClient()
    check rcCall(rc, "no_such_method", [0xA0'u8]).code == ecMethodNotFound
    check rcCall(rc, "", [0xA0'u8]).code == ecMethodNotFound
    let extra = rcCall(rc, "get_self", encodeCbor(cborMap(@[(cbor("x"), cbor(1'u64))])))
    check extra.code == ecInvalidParams
    check extra.detail.len > 0
    let broken = rcCall(rc, "get_self", [0xFF'u8])
    check broken.code == ecInvalidParams
    check rcCall(rc, "start_module", [0xA0'u8]).code == ecInvalidParams
    # [K19 interim; G298] A remote method is checked and authorized like the
    # others; without remote transport its list is an empty page.
    let listeners = rcCall(rc, "list_remote_listeners", [0xA0'u8])
    check listeners.code == ecOk
    check LogosNSRuntimeControlListRemoteListenersResponse.decode(listeners.response).tryGet.listeners.len ==
      0
    var len: csize_t
    let empty = [0xA0'u8]
    let r = rc.vtable.call(
      rc,
      "get_self",
      cast[ptr UncheckedArray[uint8]](unsafeAddr empty[0]),
      1,
      nil,
      addr len,
    )
    check toResult(r).code == ecInvalidParams
    e.finish()

  test "[RUN-0043] [RUN-0044] [IFC-0501] [IFC-0939] [IFC-0940] [RUN-1152] [RUN-1153] [TXT-0106] connect_remote: a schema failure carries its detail; no Runtime identity, a non-remote address, this Runtime and then a profile its transport does not select are INVALID_PARAMS without it, in that order and with or without a profile; a valid endpoint names no enrolled Runtime (§4.4)":
    let e = fixtureEngine(config())
    let (_, rc) = e.startClient()
    var acquired = LogosRuntimeControlBinding()
    var root: ContractRoot
    proc connect(bytes: seq[byte]): RcResult =
      toResult(
        rc.vtable.connectRemote(
          rc,
          cast[ptr UncheckedArray[uint8]](unsafeAddr bytes[0]),
          csize_t(bytes.len),
          addr root,
          addr acquired,
        )
      )

    let schemaFailure = connect(@[0xA0'u8])
    check schemaFailure.code == ecInvalidParams
    check schemaFailure.detail.len > 0
    let other = Opt.some(OtherRuntime)
    let own = Opt.some(e.runtimeInstanceId)
    const
      noRuntime = "the endpoint names no Runtime"
      notRemote = "the endpoint's address is not remote"
      thisRuntime = "the endpoint names this Runtime"
      mismatch = "the address does not match the profile its transport selects"
    # Each IFC-0939 condition with no profile, with the profile its transport
    # selects and with one it does not: the message names the first that
    # applies, so the profile mismatch never hides one of the three.
    for (name, bytes, message) in [
      ("no Runtime identity", endpointOf(Opt.none(string), tlsAddress()), noRuntime),
      (
        "no Runtime identity, tls-tcp's profile",
        endpointOf(Opt.none(string), tlsAddress(Opt.some(RemoteTlsTcp))),
        noRuntime,
      ),
      (
        "no Runtime identity, quic's profile on tls-tcp",
        endpointOf(Opt.none(string), tlsAddress(Opt.some(RemoteQuic))),
        noRuntime,
      ),
      (
        "no Runtime identity, unix-stream",
        endpointOf(Opt.none(string), unixAddress()),
        noRuntime,
      ),
      ("unix-stream", endpointOf(other, unixAddress()), notRemote),
      (
        "unix-stream with a profile",
        endpointOf(other, unixAddress(Opt.some("logos.local.unix-stream"))),
        notRemote,
      ),
      ("unix-stream naming this Runtime", endpointOf(own, unixAddress()), notRemote),
      ("this Runtime", endpointOf(own, tlsAddress()), thisRuntime),
      (
        "this Runtime, tls-tcp's profile",
        endpointOf(own, tlsAddress(Opt.some(RemoteTlsTcp))),
        thisRuntime,
      ),
      (
        "this Runtime, tls-tcp's profile on quic",
        endpointOf(own, quicAddress(profile = Opt.some(RemoteTlsTcp))),
        thisRuntime,
      ),
      (
        "tls-tcp naming quic",
        endpointOf(other, tlsAddress(Opt.some(RemoteQuic))),
        mismatch,
      ),
      (
        "quic naming tls-tcp",
        endpointOf(other, quicAddress(profile = Opt.some(RemoteTlsTcp))),
        mismatch,
      ),
      (
        "quic with another alpn",
        endpointOf(other, quicAddress(alpn = Opt.some("h3"))),
        mismatch,
      ),
    ]:
      checkpoint name
      let r = connect(bytes)
      check r.code == ecInvalidParams
      check r.detail.len == 0
      check r.message == message
    for bytes in [
      endpointOf(other, tlsAddress()),
      endpointOf(other, tlsAddress(Opt.some(RemoteTlsTcp))),
      endpointOf(other, quicAddress(Opt.some(RemoteQuic), Opt.some(RemoteQuic))),
    ]:
      check connect(bytes).code == ecNotAuthorised
    check acquired.vtable == nil and acquired.state == nil
    e.finish()

  test "[RUN-1152] [RUN-1153] [TXT-0106] [RUN-1117] [RUN-1118] M8: a listener address whose profile or alpn contradicts its transport is INVALID_PARAMS without detail, after what is authorized without the payload":
    let e = fixtureEngine(
      config(
        denying(
          deny(
            action = Opt.some(aaRuntimeControl),
            operation = "set_remote_listener",
            consumer = "c2",
          ),
          deny(
            action = Opt.some(aaObserve),
            operation = "list_provider_exports",
            consumer = "c2",
          ),
        )
      )
    )
    let (_, rc) = e.startClient("c1")
    let (_, refused) = e.startClient("c2")
    let good = listenerAddress(tlsAddress(Opt.some(RemoteTlsTcp)))
    let goodQuic =
      listenerAddress(quicAddress(Opt.some(RemoteQuic), Opt.some(RemoteQuic)))
    let bad = [
      listenerAddress(tlsAddress(Opt.some(RemoteQuic))),
      listenerAddress(quicAddress(profile = Opt.some(RemoteTlsTcp))),
      listenerAddress(quicAddress(alpn = Opt.some("h3"))),
    ]
    proc setListener(a: LogosNSRuntimeControlRemoteListenerAddress): seq[byte] =
      encode(
        LogosNSRuntimeControlSetRemoteListenerRequest(
          listener: LogosNSRuntimeControlRemoteListenerRecord(
            address: a, enabled: false, runtime_control_enabled: false
          )
        )
      ).tryGet

    proc listExports(a: LogosNSRuntimeControlRemoteListenerAddress): seq[byte] =
      encode(LogosNSRuntimeControlListProviderExportsRequest(listener: Opt.some(a))).tryGet

    proc setExport(a: LogosNSRuntimeControlRemoteListenerAddress): seq[byte] =
      encode(
        LogosNSRuntimeControlSetProviderExportRequest(
          `export`: LogosNSRuntimeControlProviderExportRecord(
            enabled: true,
            listener: a,
            provider: LogosNSRuntimeModuleProviderAddress(provider: "no_such_provider"),
          )
        )
      ).tryGet

    # A matching address keeps the outcomes it had: a disabled listener is
    # the default state, the export list is empty, an unknown provider is not
    # disclosed.
    for a in [good, goodQuic]:
      check rcCall(rc, "set_remote_listener", setListener(a)).code == ecOk
      check rcCall(rc, "list_provider_exports", listExports(a)).code == ecOk
      check rcCall(rc, "set_provider_export", setExport(a)).code == ecNotAuthorised
    for a in bad:
      for (m, bytes) in [
        ("set_remote_listener", setListener(a)),
        ("list_provider_exports", listExports(a)),
        ("set_provider_export", setExport(a)),
      ]:
        checkpoint m
        let r = rcCall(rc, m, bytes)
        check r.code == ecInvalidParams
        check r.detail.len == 0
        # The method's own authority first where it names no target from the
        # payload; `set_provider_export`'s names one, so the address is
        # judged before it [reading, Fable synthesis §14.3].
        let denied = rcCall(refused, m, bytes)
        if m == "set_provider_export":
          check denied.code == ecInvalidParams
          check denied.detail.len == 0
        else:
          check denied.code == ecNotAuthorised
    e.finish()

  test "[RUN-0794] [RUN-0900] a binding that is stopping is NOT_READY (§3.4 l.629-631)":
    var cfg = config()
    cfg.stopDeadline = initDuration(seconds = 30) # stays `stopping` meanwhile
    let e = fixtureEngine(cfg)
    let (c, rc) = e.startClient()
    clientDestroyGate.store(true)
    var t: Thread[(Engine, string)]
    check e.stopping(c.instance, t)
    check rcCall(rc, "get_self", [0xA0'u8]).code == ecNotReady
    clientDestroyGate.store(false)
    joinThread(t)
    check stopReply.load == ord(msUnloaded)
    e.finish()

  test "[RUN-1117] [RUN-1118] [RUN-1122] [RUN-0039] [RUN-0850] [RUN-0874] what needs no payload is authorized first, readiness last (l.1827-1832)":
    var cfg = config(
      denying(
        deny(
          action = Opt.some(aaRuntimeControl),
          operation = "establish_route",
          consumer = "c2",
        ),
        deny(
          action = Opt.some(aaRuntimeControl),
          operation = "renew_route",
          consumer = "c2",
        ),
      )
    )
    cfg.stopDeadline = initDuration(seconds = 30) # stays `stopping` meanwhile
    let e = fixtureEngine(cfg)
    discard e.started(meter())
    let (_, rc) = e.startClient("c1")
    let (c2, refused) = e.startClient("c2")
    # A malformed request: the method's own authority first, where it names no
    # target from the payload.
    check rcCall(rc, "establish_route", [0xA0'u8]).code == ecInvalidParams
    check rcCall(refused, "establish_route", [0xA0'u8]).code == ecNotAuthorised
    check rcCall(refused, "renew_route", [0xA0'u8]).code == ecInvalidParams
    check rcCall(refused, "shutdown_runtime", [0x01'u8]).code == ecInvalidParams
    # An invalidated binding: authorization, then readiness.
    clientDestroyGate.store(true)
    var t: Thread[(Engine, string)]
    check e.stopping(c2.instance, t)
    check refused.establish("k").code == ecNotAuthorised
    check refused.renew("r", "route-unknown").code == ecNotAuthorised
    check rcCall(refused, "get_self", [0xA0'u8]).code == ecNotReady
    clientDestroyGate.store(false)
    joinThread(t)
    check stopReply.load == ord(msUnloaded)
    e.finish()

  test "[RUN-1115] [RUN-1116] [RUN-1117] [RUN-1118] [RUN-1119] [RUN-1120] [TXT-0156] the order of checks, steps 1 to 5: the method, what is authorized without the payload, the payload, the target, the revision (l.1824-1830)":
    let e = fixtureEngine(
      config(
        denying(
          deny(action = Opt.some(aaRuntimeControl), consumer = "c2"),
          deny(action = Opt.some(aaLifecycle), consumer = "c1", target = "hidden"),
        )
      )
    )
    discard e.started(meter(), "m")
    discard e.started(meter(), "hidden")
    let (_, rc) = e.startClient("c1")
    let (_, refused) = e.startClient("c2")
    # 1 before 2: an unknown method from a caller that may call none.
    check rcCall(refused, "no_such_method", [0xA0'u8]).code == ecMethodNotFound
    # 2 before 3: a malformed payload for a method the caller may not call.
    check rcCall(refused, "shutdown_runtime", [0x01'u8]).code == ecNotAuthorised
    check rcCall(rc, "shutdown_runtime", [0x01'u8]).code == ecInvalidParams
    # A lifecycle method's authority depends on its target (step 4): nothing
    # precedes the payload's check.
    check rcCall(refused, "start_module", [0xA0'u8]).code == ecInvalidParams
    # 3 before 4: a malformed request naming another Runtime's instance is the
    # schema failure, with its detail; well-formed, it is the foreign target,
    # without detail (TXT-0156).
    let foreign = "00000000-0000-4000-8000-000000000000"
    check foreign != e.runtimeInstanceId
    let target = cborMap(
      @[
        (cbor("module_instance_id"), cbor("m")),
        (cbor("runtime_instance_id"), cbor(foreign)),
      ]
    )
    let malformed = rcCall(
      rc,
      "get_execution_summary",
      encodeCbor(cborMap(@[(cbor("target"), target), (cbor("x"), cbor(1'u64))])),
    )
    check malformed.code == ecInvalidParams
    check malformed.detail.len > 0
    let elsewhere = rcCall(
      rc, "get_execution_summary", encodeCbor(cborMap(@[(cbor("target"), target)]))
    )
    check elsewhere.code == ecInvalidParams
    check elsewhere.detail.len == 0
    # 4 before 5: a stale revision for an instance the caller may not see, or
    # one that does not exist, is NOT_AUTHORISED without a current revision.
    for instance in ["hidden", "nobody"]:
      let r = rc.lifecycle(
        "start_module",
        "meter_module",
        Opt.some(instance),
        expected = Opt.some(999'u64),
        refusal = true,
      )
      check r.code == ecNotAuthorised
      check r.refused.isNone
    # 5 before 6: a stale revision on an instance whose state prohibits the
    # operation (a ready instance cannot be recovered) is `stale-revision`.
    proc recoverReq(instance: string, revision: uint64): seq[byte] =
      encode(
        LogosNSRuntimeControlRecoverModuleRequest(
          module: "meter_module",
          instance: instance,
          expected_execution_revision: revision,
        )
      ).tryGet

    let current = e.view("m").tryGet.execution.revision
    let prohibited = rcCall(rc, "recover_module", recoverReq("m", current))
    check prohibited.code == ecNotReady
    check prohibited.refused.isNone
    let stale = rcCall(rc, "recover_module", recoverReq("m", current + 7))
    check stale.code == ecOk
    check stale.refused.get.stale == Opt.some(current)
    e.finish()

  test "[RUN-1121] [TXT-0159] step 6 in row order: a reused request key (row 2) before a closed route (row 5)":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let a = rc.routeId("a")
    let b = rc.routeId("b")
    check rc.renew("rk", b).code == ecOk
    check rc.close(a).code == ecOk
    # Row 5 alone, then both: the key was used for `b`'s renewal.
    check rc.renew("fresh", a).code == ecNotReady
    let both = rc.renew("rk", a)
    check both.code == ecInvalidParams
    check both.detail.len == 0
    # The same request again is its replay.
    check rc.renew("rk", b).code == ecOk
    e.finish()

  test "[RUN-1121] [TXT-0158] step 6 in row order: a recovery that the state prohibits (row 4) and whose revision cannot advance (row 7) is NOT_READY":
    var cfg = config()
    cfg.revisionBudget = 4
    let e = fixtureEngine(cfg)
    let (_, rc) = e.startClient()
    let m = e.started(meter(), "m")
    discard e.started(meter(), "n")
    check e.stop("n").tryGet.state == msUnloaded # withdrawal is never refused
    let mask = 0xFFFF_FFFF'u64
    checkpoint "m's revision: " & $(m.execution.revision and mask)
    check (m.execution.revision and mask) >= cfg.revisionBudget
    # Row 7 alone: a start of `n` needs a revision that cannot advance.
    let exhausted = rc.lifecycle("start_module", "meter_module", Opt.some("n"))
    check exhausted.code == ecModule
    check "exhausted" in exhausted.message
    let both = rcCall(
      rc,
      "recover_module",
      encode(
        LogosNSRuntimeControlRecoverModuleRequest(
          module: "meter_module",
          instance: "m",
          expected_execution_revision: e.view("m").tryGet.execution.revision,
        )
      ).tryGet,
    )
    check both.code == ecNotReady
    check both.message == "the module instance is ready"
    e.finish()

  test "[RUN-1121] [RUN-1122] [RUN-1123] [TXT-0159] steps 5 to 8 from an invalidated binding: the revision and a table row before readiness, readiness before the contract root (l.1830-1833)":
    var cfg = config()
    cfg.stopDeadline = initDuration(seconds = 30) # both stay `stopping` meanwhile
    let e = fixtureEngine(cfg)
    discard e.started(meter())
    let (_, ready) = e.startClient("c1")
    let (t, _) = e.startClient("t")
    let (c2, rc) = e.startClient("c2")
    let unknown = newSeqWith(32, 0x5A'u8)
    let scope = access(methods = Opt.some(@[unknown]))
    # Step 8 alone: an access root the contract does not declare.
    check ready.establish("k1", scope = scope).code == ecInvalidParams
    clientDestroyGate.store(true)
    var t1, t2: Thread[(Engine, string)]
    check e.stopping(t.instance, t1)
    check e.stopping(c2.instance, t2)
    # Step 7 alone.
    let alone = rcCall(rc, "get_self", [0xA0'u8])
    check alone.code == ecNotReady
    check alone.message == "the Runtime Control binding is invalidated"
    # 6 before 7: a start that the target's state prohibits.
    let prohibited = rc.lifecycle("start_module", "client_module", Opt.some(t.instance))
    check prohibited.code == ecNotReady
    check prohibited.message == "the module instance is stopping"
    # 5 before 6 and 7: the same start with a stale revision.
    let stale = rc.lifecycle(
      "start_module",
      "client_module",
      Opt.some(t.instance),
      expected = Opt.some(999'u64),
      refusal = true,
    )
    check stale.code == ecOk
    check stale.refused.get.stale ==
      Opt.some(e.view(t.instance).tryGet.execution.revision)
    # 7 before 8.
    let late = rc.establish("k2", scope = scope)
    check late.code == ecNotReady
    check late.message == "the Runtime Control binding is invalidated"
    clientDestroyGate.store(false)
    joinThread(t1)
    joinThread(t2)
    e.finish()

  test "[RUN-0113] [RUN-0794] a caller waiting in start_module is released when its binding ends (§3.4)":
    let e = fixtureEngine(config())
    let s = e.create(slow()).tryGet
    let (c, rc) = e.startClient()
    slowGate.store(true)
    var t: Thread[(ptr LogosRuntimeControlBinding, string)]
    bgDone.store(false)
    createThread(
      t,
      proc(a: (ptr LogosRuntimeControlBinding, string)) {.thread.} =
        let r = lifecycle(a[0], "start_module", "slow_module", Opt.some(a[1]))
        bgCode.store(ord(r.code))
        bgDone.store(true),
      (rc, s.instance),
    )
    check waitUntil(
      proc(): bool =
        e.view(s.instance).tryGet.state == msLoaded
    )
    check not bgDone.load
    discard e.stop(c.instance)
    joinThread(t)
    check bgCode.load == ord(ecNotReady)
    slowGate.store(false)
    check waitUntil(
      proc(): bool =
        e.view(s.instance).tryGet.state == msReady
    )
    e.finish()

suite "run.routes: establish, renew and close (RUNTIME §4, §9.3)":
  test "[RUN-0557] [RUN-0943] [RUN-0542] [RUN-1180] [RUN-0184] [RUN-0536] [RUN-0593] [RUN-0782] [RUN-0942] a single route to a ready provider (§9.3 l.3135-3146)":
    let e = fixtureEngine(config())
    let m = e.started(meter())
    let (c, rc) = e.startClient()
    let r = rc.establish("k1")
    check r.code == ecOk
    let resp = r.routesOf
    check resp.routes.len == 1
    check not resp.partial
    check resp.continuations.len == 0
    let rec = resp.routes[0]
    check rec.consumer.module_instance_id == c.instance
    check rec.consumer.runtime_instance_id == e.runtimeInstanceId
    check rec.target_provider.provider == m.providerId
    check rec.target_provider.runtime_instance_id == Opt.some(e.runtimeInstanceId)
    check rec.module == "meter_module"
    check rec.instance == Opt.some(m.instance)
    check rec.expected_contract.get.schema_root == @meterRoot
    check rec.state.kind == LogosNSRuntimeControlRouteStateKind.Ready
    check rec.decision_id.isSome
    check rec.failure.isNone
    when declared(transportParity):
      # [G254; RUN-1161] A transported route's answer carries its invocation;
      # its record never does (RUN-0543).
      check rec.invocation.isSome
      var kept = rec
      kept.invocation = Opt.none(LogosNSRuntimeControlInvocationDescriptor)
      check e.routes().mapIt(encode(it).tryGet) == @[encode(kept).tryGet]
    else:
      check rec.invocation.isNone # a direct route (l.3469)
      check e.routes().mapIt(encode(it).tryGet) == @[encode(rec).tryGet]
    e.finish()

  test "[IMPL-DECISION G169] [RUN-1169] [RUN-0556] [RUN-0188] [RUN-0121] [RUN-0546] establishment failures":
    let e = fixtureEngine(config())
    let idle = e.create(meter()).tryGet
    let (_, rc) = e.startClient()
    var zero: Digest
    # [G169; l.3063] A `discover` allow, and no provider offers it.
    check rc.establish("a", root = zero).code == ecNotReady
    # An allowed provider that is not ready.
    check rc.establish("b").code == ecNotReady
    check rc.establish(
      "c", all = true, provider = Opt.some(providerAddress(idle.providerId))
    ).code == ecInvalidParams
    check e.start(idle.instance).tryGet.state == msReady
    let high = newSeq[byte](32).mapIt(0xFF'u8)
    let low = newSeq[byte](32)
    check rc.establish("d", scope = access(methods = Opt.some(@[high, low]))).code ==
      ecInvalidParams
    check rc.establish("e", scope = access(methods = Opt.some(@[low]))).code ==
      ecInvalidParams
    let event = declRoot("meter.changed_event")
    check rc.establish("f", scope = access(methods = Opt.some(@[event]))).code ==
      ecInvalidParams
    check rc.establish(
      "g", scope = access(publish = Opt.some(@[declRoot("meter.read")]))
    ).code == ecInvalidParams
    check rc.establish("h", scope = access(subscribe = Opt.some(@[event]))).code == ecOk
    check rc.establish(
      "i", provider = Opt.some(providerAddress(idle.providerId, Opt.some("elsewhere")))
    ).code == ecNotAuthorised
    check rc.establish("j", provider = Opt.some(providerAddress("p-unknown"))).code ==
      ecNotReady
    check rc.establish("k", provider = Opt.some(providerAddress(idle.providerId))).code ==
      ecOk
    check e.routes().len == 2
    e.finish()

  test "[RUN-0547] [RUN-1162] access lists must be strictly ascending without duplicates, INVALID_PARAMS without validation detail; nothing is sorted or deduplicated (l.2932)":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let common = meterSet.context.commonModel
    let read = declRoot("meter.read")
    let schema = @(declarationRoot(common, common.find("logos.schema").get))
    let event = declRoot("meter.changed_event")
    proc below(a, b: seq[byte]): bool =
      for i in 0 ..< min(a.len, b.len):
        if a[i] != b[i]:
          return a[i] < b[i]
      a.len < b.len

    let (lo, hi) =
      if below(read, schema):
        (read, schema)
      else:
        (schema, read)
    let before = e.routes().len
    for (key, scope) in [
      ("down", access(methods = Opt.some(@[hi, lo]))),
      ("twice", access(methods = Opt.some(@[read, read]))),
      ("events", access(subscribe = Opt.some(@[event, event]))),
    ]:
      let r = rc.establish(key, scope = scope)
      check r.code == ecInvalidParams
      check r.detail.len == 0
      check e.routes().len == before
    let scope = access(methods = Opt.some(@[lo, hi]), subscribe = Opt.some(@[event]))
    let up = rc.establish("up", scope = scope)
    check up.code == ecOk
    check up.routesOf.routes[0].access == scope
    e.finish()

  test "[IMPL-DECISION G52] [IMPL-DECISION G169] [RUN-1168] [RUN-0162] [RUN-0850] [RUN-0186] [RUN-0278] [RUN-0553] [RUN-0563] [RUN-0564] [RUN-0573] [CAP-0041] authorization at establishment (§9 l.1626, l.3138; G52)":
    for rule in [
      deny(action = Opt.some(aaRuntimeControl), operation = "establish_route"),
      deny(action = Opt.some(aaRoute)),
    ]:
      let e = fixtureEngine(config(denying(rule)))
      discard e.started(meter())
      let (_, rc) = e.startClient()
      check rc.establish("k").code == ecNotAuthorised
      check rc.establish("a", all = true).code == ecNotAuthorised
      check e.routes().len == 0
      e.finish()
    let e = fixtureEngine(config(denying(deny(action = Opt.some(aaDiscover)))))
    discard e.started(meter())
    let (_, rc) = e.startClient()
    check rc.establish("k", all = true).code == ecNotAuthorised
    var zero: Digest
    # [G169; l.3060-3061] No route allow and no `discover` allow.
    check rc.establish("z", root = zero).code == ecNotAuthorised
    check rc.establish("k").code == ecOk
    e.finish()

  test "[RUN-0568] [RUN-0944] [RUN-0945] [RUN-0947] request_key replay (§9.3 l.3176-3183)":
    let e = fixtureEngine(config())
    let m = e.create(meter()).tryGet
    let (_, rc) = e.startClient()
    check rc.establish("k2").code == ecNotReady # failures are not retained
    check e.start(m.instance).tryGet.state == msReady
    let first = rc.establish("k1")
    check first.code == ecOk
    let again = rc.establish("k1")
    check again.code == ecOk
    when declared(transportParity):
      check again.response == first.redacted # [G255] no one-time invocation
    else:
      check again.response == first.response
    check e.routes().len == 1
    check rc.establish("k1", all = true).code == ecInvalidParams
    check rc.renew("k1", first.routesOf.routes[0].route).code == ecInvalidParams
    check rc.establish("k2").code == ecOk
    check e.routes().len == 2
    e.finish()

  test "[RUN-0277] [RUN-0279] [RUN-0556] [RUN-0557] [RUN-0558] [RUN-0280] all-runtime-visible and single selection (§9.3 l.3140-3146)":
    let e = fixtureEngine(config())
    let a = e.started(meter())
    let b = e.create(meter()).tryGet
    let (_, rc) = e.startClient()
    let partial = rc.establish("x1", all = true)
    check partial.code == ecOk
    check partial.routesOf.routes.len == 1
    check partial.routesOf.partial
    check e.start(b.instance).tryGet.state == msReady
    let full = rc.establish("x2", all = true).routesOf
    check full.routes.len == 2
    check not full.partial
    let single = rc.establish("x3").routesOf
    check single.routes.len == 1
    check not single.partial
    check single.routes[0].target_provider.provider == a.providerId
    let chosen =
      rc.establish("x4", provider = Opt.some(providerAddress(b.providerId))).routesOf
    check chosen.routes[0].target_provider.provider == b.providerId
    e.finish()

  test "[RUN-1107] [TXT-0150] [RUN-1168] [RUN-1169] [IMPL-DECISION G169] a single request never selects a provider its route decision hides: the first allowed candidate, ready ones first; none allowed is NOT_AUTHORISED, an allowed one not ready NOT_READY (l.1423-1424, l.3060-3063)":
    # A rule that matches nothing keeps the internal policy in the parity
    # passes; `setPolicyForTests` then names the providers the engine made.
    let e = fixtureEngine(config(denying(deny(operation = "no-such-operation"))))
    let idle = e.create(meter()).tryGet
    let a = e.started(meter())
    let b = e.started(meter())
    let (_, rc) = e.startClient()
    proc hide(outcome: AuthzOutcome, providers: varargs[string]) =
      var rules: seq[AuthzRule]
      for p in providers:
        rules.add(deny(action = Opt.some(aaRoute), target = p, outcome = outcome))
      check e.setPolicyForTests(denying(rules)).isOk

    proc names(r: RcResult, provider: string): bool =
      ## `provider` appears anywhere in the answer.
      let text = (r.response & r.detail).mapIt(char(it)).join("") & r.message
      provider in text

    # Ready ones first: `a`, though created after `idle`.
    hide(azDeny)
    let first = rc.establish("k1")
    check first.code == ecOk
    check first.routesOf.routes[0].target_provider.provider == a.providerId
    # `a` hidden by a deny, then by a failed evaluation: `b`, and the response
    # names only `b`.
    for (key, outcome) in [("k2", azDeny), ("k3", azEvaluationFailed)]:
      hide(outcome, a.providerId)
      let r = rc.establish(key)
      check r.code == ecOk
      check r.routesOf.routes.len == 1
      check r.routesOf.routes[0].target_provider.provider == b.providerId
      check not r.names(a.providerId)
    # Every ready one hidden, the idle one allowed: NOT_READY.
    hide(azDeny, a.providerId, b.providerId)
    let waiting = rc.establish("k4")
    check waiting.code == ecNotReady
    check not waiting.names(idle.providerId)
    # Every one hidden: NOT_AUTHORISED, naming none.
    hide(azDeny, a.providerId, b.providerId, idle.providerId)
    let none = rc.establish("k5")
    check none.code == ecNotAuthorised
    check none.message == "not authorised"
    check not none.names(a.providerId) and not none.names(b.providerId)
    check e.routes().len == 3
    e.finish()

  test "[RUN-0570] [RUN-0625] [RUN-0360] renew_route (§9.3 l.3183-3190, l.3471-3484)":
    let e = fixtureEngine(
      config(
        denying(
          deny(action = Opt.some(aaRoute), operation = "renew_route", route = "route-x")
        )
      )
    )
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let first = rc.establish("k").routesOf.routes[0]
    let r = rc.renew("r1", first.route)
    check r.code == ecOk
    let renewed =
      LogosNSRuntimeControlRenewRouteResponse.decode(r.response).tryGet.route
    check renewed.route == first.route
    check renewed.decision_id != first.decision_id
    check renewed.access == first.access
    check rc.renew("r2", "route-unknown").code == ecNotAuthorised
    check rc.close(first.route).code == ecOk
    check rc.renew("r3", first.route).code == ecNotReady
    e.finish()

  test "[IMPL-DECISION G170] [RUN-1171] [TXT-0180] [TXT-0194] [RUN-0887] [RUN-0836] [RUN-0990] [RUN-0580] [IFC-0662] a denied renewal revokes the route [IMPL-DECISION G170] (TF-17)":
    let e = fixtureEngine(
      config(denying(deny(action = Opt.some(aaRoute), operation = "renew_route")))
    )
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let first = rc.establish("k").routesOf.routes[0]
    var h = rc.handle(first.route)
    var seen: EndSeen
    check h.observe(addr seen) == ecOk
    check rc.renew("r1", first.route).code == ecNotAuthorised
    let rec = e.routes()[0]
    check rec.state.kind == LogosNSRuntimeControlRouteStateKind.Revoked
    check rec.failure.get.code == "authority-denied"
    check rec.decision_id == first.decision_id
    check waitUntil(
      proc(): bool =
        seen.count.load == 1
    )
    check seen.code.load == ord(ecNotAuthorised)
    check h.read(5).error.code == ecNotAuthorised
    check rc.renew("r2", first.route).code == ecNotAuthorised
    # A terminal route is reported as it is: closing it changes neither its
    # state nor its failure record (l.3350).
    let closed = rc.close(first.route)
    check closed.code == ecOk
    check LogosNSRuntimeControlCloseRouteResponse.decode(closed.response).tryGet.state.kind ==
      LogosNSRuntimeControlRouteStateKind.Revoked
    check e.routes()[0].state.kind == LogosNSRuntimeControlRouteStateKind.Revoked
    check e.routes()[0].failure.get.code == "authority-denied"
    h.release()
    e.finish()

  test "[IMPL-DECISION G170] [RUN-1181] [TXT-0194] close_route (§9.3 l.3486-3492)":
    let e = fixtureEngine(
      config(
        denying(
          deny(
            action = Opt.some(aaRuntimeControl),
            operation = "close_route",
            consumer = "c3",
          )
        )
      )
    )
    discard e.started(meter())
    let (_, rc) = e.startClient("c1")
    let (_, other) = e.startClient("c2")
    let (_, refused) = e.startClient("c3")
    let mine = rc.routeId("k1")
    let theirs = rc.routeId("k2")
    let r = rc.close(mine)
    check r.code == ecOk
    let closed = LogosNSRuntimeControlCloseRouteResponse.decode(r.response).tryGet
    check closed.route == mine
    check closed.state.kind == LogosNSRuntimeControlRouteStateKind.Closed
    check rc.close(mine).code == ecOk
    check rc.close("route-unknown").code == ecNotAuthorised
    check refused.close(theirs).code == ecNotAuthorised
    check other.renew("o", theirs).code == ecNotAuthorised
    check other.close(theirs).code == ecOk
    for rec in e.routes():
      check rec.state.kind == LogosNSRuntimeControlRouteStateKind.Closed
      check rec.failure.isNone
    e.finish()

  test "[IMPL-DECISION G170] [RUN-1181] close_route's reason is diagnostic: it changes neither the answer nor the route (§9.3.16 l.3353)":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient("c1")
    let plain = rc.routeId("k1")
    let reasoned = rc.routeId("k2")
    let a = rc.close(plain)
    let b = rc.close(reasoned, Opt.some("operator request"))
    check a.code == ecOk and b.code == ecOk
    let closed = LogosNSRuntimeControlCloseRouteResponse.decode(b.response).tryGet
    check closed.route == reasoned
    check closed.state.kind == LogosNSRuntimeControlRouteStateKind.Closed
    # The same answer as without a reason, but for the route id.
    check encode(
      LogosNSRuntimeControlCloseRouteResponse(route: plain, state: closed.state)
    ).tryGet == a.response
    # Closing again with another reason answers the same bytes.
    let again = rc.close(reasoned, Opt.some("another reason"))
    check again.code == ecOk and again.response == b.response
    for rec in e.routes():
      check rec.state.kind == LogosNSRuntimeControlRouteStateKind.Closed
      check rec.failure.isNone
    e.finish()

suite "run.routes: route handles (INTERFACE §2.5, §5.2; RUNTIME §4.1, §7.5)":
  test "[IFC-0510] [IFC-0491] [IFC-0517] [RUN-0145] [RUN-0866] [RUN-0152] [RUN-0810] materialize a route and call the provider through it":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (c, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    let x = h.read(5).tryGet
    check x.label == "ch5"
    check x.reading.value == 50
    # [SPEC INTERFACE §2.9.3] The provider sees the consumer as its caller.
    let who = h.read(18).tryGet
    check who.label == c.instance
    check who.reading.label == Opt.some(e.runtimeInstanceId)
    check who.reading.value == 0
    h.release()
    e.finish()

  test "[IFC-0448] [IFC-0930] [RUN-0086] logos.schema is answered by the boundary (INTERFACE l.3275-3277)":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    let s = h.raw("schema", [0xA0'u8])
    check s.code == ecOk
    check acceptSchemaResponse(s.response, meterRoot).isOk
    check h.raw("schema", [0xA1'u8, 0x61, 0x78, 0x01]).code == ecInvalidParams
    h.release()
    e.finish()

  test "[CAP-0044] [IFC-0537] narrowed access never narrows the contract logos.schema returns (CA §3.1 l.268)":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let common = meterSet.context.commonModel
    let schemaMethod = @(declarationRoot(common, common.find("logos.schema").get))
    let narrowed =
      rc.establish("n", scope = access(methods = Opt.some(@[schemaMethod])))
    check narrowed.code == ecOk
    check narrowed.routesOf.routes[0].expected_contract.get.schema_root == @meterRoot
    var n = rc.handle(narrowed.routesOf.routes[0].route)
    var w = rc.handle(rc.routeId("w"))
    let fromNarrowed = n.raw("schema", [0xA0'u8])
    let fromWhole = w.raw("schema", [0xA0'u8])
    check fromNarrowed.code == ecOk
    check fromWhole.code == ecOk
    # The same bytes: the whole selected contract, `meter.read` (outside the
    # access) included, never a subset made for the route.
    check fromNarrowed.response == fromWhole.response
    check fromNarrowed.response == meterSchema
    check acceptSchemaResponse(fromNarrowed.response, meterRoot).isOk
    check n.read(5).error.code == ecNotAuthorised
    check w.read(5).isOk
    n.release()
    w.release()
    e.finish()

  test "[IMPL-DECISION G172] [RUN-0152] [RUN-0153] [RUN-0551] [RUN-0689] [IFC-0932] provider failures, bad requests and bad responses":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    let f = h.read(13)
    check f.isErr
    check f.error.code == ecModule
    check f.error.message == Opt.some("channel 13 is broken")
    check h.read(14).error.code == ecModule
    check h.read(16).error.code == ecModule
    check h.raw("nope", [0xA0'u8]).code == ecMethodNotFound
    let bad = h.raw("read", encodeCbor(cborMap(@[(cbor("channel"), cbor("x"))])))
    check bad.code == ecInvalidParams
    check bad.detail.len > 0
    check h.read(5).isOk
    h.release()
    e.finish()

  test "[IFC-0979] [IFC-0980] [TXT-0034] a provider's TIMEOUT, NOT_READY, NOT_AUTHORISED, TRANSPORT_ERROR or CANCELLED without a known cancellation is MODULE_ERROR without its message; its MODULE_ERROR passes through (INTERFACE l.3306-3311)":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    check h.read(13).error.message == Opt.some("channel 13 is broken")
    for channel in 9001'u32 .. 9005'u32:
      checkpoint("channel " & $channel)
      let f = h.read(channel)
      check f.isErr
      if f.isErr:
        check f.error.code == ecModule
        check f.error.message.isNone
    check h.read(5).isOk
    h.release()
    e.finish()

  test "[RUN-0154] [RUN-0866] [RUN-0188] the access scope and the per-call decision (§9.3 l.3003-3004; l.1732)":
    let e = fixtureEngine(
      config(denying(deny(action = Opt.some(aaCall), consumer = "denied")))
    )
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let empty =
      rc.establish("e", scope = access(methods = Opt.some(newSeq[seq[byte]]())))
    var h = rc.handle(empty.routesOf.routes[0].route)
    check h.read(5).error.code == ecNotAuthorised
    check h.raw("schema", [0xA0'u8]).code == ecNotAuthorised
    h.release()
    let readOnly =
      rc.establish("r", scope = access(methods = Opt.some(@[declRoot("meter.read")])))
    var r = rc.handle(readOnly.routesOf.routes[0].route)
    check r.read(5).isOk
    check r.raw("schema", [0xA0'u8]).code == ecNotAuthorised
    r.release()
    let (_, denied) = e.startClient("denied")
    var d = denied.handle(denied.routeId("d"))
    check d.read(5).error.code == ecNotAuthorised
    d.release()
    e.finish()

  test "[IMPL-DECISION G171] [RUN-1115] [RUN-1117] [RUN-1118] [RUN-1122] an ordinary call: its authorization before its payload, readiness after it (l.1824-1832)":
    var cfg = config(
      denying(
        deny(action = Opt.some(aaCall), consumer = "denied"),
        deny(
          action = Opt.some(aaRoute), operation = "renew_route", consumer = "revoked"
        ),
      )
    )
    cfg.stopDeadline = initDuration(seconds = 30) # `late` stays `stopping` meanwhile
    let e = fixtureEngine(cfg)
    discard e.started(meter())
    let (_, rc) = e.startClient("allowed")
    let (_, denied) = e.startClient("denied")
    let (_, revoking) = e.startClient("revoked")
    let (late, lateRc) = e.startClient("late")
    let malformed = encodeCbor(cborMap(@[(cbor("channel"), cbor("x"))]))
    var h = rc.handle(rc.routeId("a"))
    let bad = h.raw("read", malformed)
    check bad.code == ecInvalidParams
    check bad.detail.len > 0
    # Step 2's route access checks (TRANSPORT §8.1), which the consumer's side
    # owns in every placement: a method outside the route's access, then a
    # revoked route.
    let narrow =
      rc.establish("n", scope = access(methods = Opt.some(newSeq[seq[byte]]())))
    var n = rc.handle(narrow.routesOf.routes[0].route)
    let outside = n.raw("read", malformed)
    check outside.code == ecNotAuthorised
    check outside.detail.len == 0
    n.release()
    let route = revoking.routeId("k")
    var v = revoking.handle(route)
    check revoking.renew("r1", route).code == ecNotAuthorised
    let gone = v.raw("read", malformed)
    check gone.code == ecNotAuthorised
    check gone.detail.len == 0
    v.release()
    # Step 2's call decision.
    var d = denied.handle(denied.routeId("d"))
    let refused = d.raw("read", malformed)
    if overTransport:
      # [DECISIONS G171, interim reading] The provider's side makes the call
      # decision, after its session dispatches the Request (`rjOwner`,
      # tests/test_transport.nim). The consumer's own session cannot commit the
      # payload (TRANSPORT §4.1, l.640) and refuses it first, so a call that is
      # both malformed and denied is INVALID_PARAMS here and NOT_AUTHORISED when
      # direct (l.1257 not met in this corner).
      check refused.code == ecInvalidParams
      check refused.detail.len > 0
    else:
      check refused.code == ecNotAuthorised
      check refused.detail.len == 0
    d.release()
    # Step 7 after step 3: the consumer's side is not ready.
    var l = lateRc.handle(lateRc.routeId("l"))
    clientDestroyGate.store(true)
    var t: Thread[(Engine, string)]
    check e.stopping(late.instance, t)
    let notLive = l.raw("read", malformed)
    check notLive.code == ecInvalidParams
    check notLive.detail.len > 0
    check l.read(5).error.code == ecNotReady
    l.release()
    clientDestroyGate.store(false)
    joinThread(t)
    h.release()
    e.finish()

  test "[IFC-0512] [IFC-0513] [IFC-0514] [IFC-0515] [IFC-0943] [IFC-0945] [IFC-0946] [IFC-0947] [RUN-0146] [RUN-0147] [RUN-0184] [RUN-0531] materialize_route failures (INTERFACE §5.2 l.3884-3890)":
    let e = fixtureEngine(
      config(
        denying(
          deny(
            action = Opt.some(aaRoute), operation = "materialize_route", consumer = "c3"
          )
        )
      )
    )
    discard e.started(meter())
    let (_, rc) = e.startClient("c1")
    let (_, other) = e.startClient("c2")
    let (_, refused) = e.startClient("c3")
    let route = rc.routeId("k")
    for (code, h) in [
      rc.materialize("route-unknown"),
      other.materialize(route),
      refused.materialize(refused.routeId("k")),
    ]:
      check code == ecNotAuthorised
      check h.vtable == nil and h.state == nil
    var zero: Digest
    check rc.materialize(route, root = zero)[0] == ecVersionMismatch
    check rc.materialize(route, schema = @[0x01'u8])[0] == ecInvalidParams
    var h = rc.handle(route)
    var h2 = rc.handle(route) # several handles per route
    check h.read(1).isOk and h2.read(2).isOk
    h.release()
    h2.release()
    check rc.close(route).code == ecOk
    check rc.materialize(route)[0] == ecNotReady
    e.finish()

  test "[IFC-0942] describe_provider's descriptor bytes are not construction input; projected to the selected contract as one logos.schema_response they are (INTERFACE §5.2 l.3870)":
    let e = fixtureEngine(config())
    let m = e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.routeId("k")
    let d = rcCall(
      rc,
      "describe_provider",
      encode(
        LogosNSRuntimeControlDescribeProviderRequest(
          provider: providerAddress(m.providerId)
        )
      ).tryGet,
    )
    check d.code == ecOk
    let surface =
      LogosNSRuntimeControlDescribeProviderResponse.decode(d.response).tryGet.surface
    let (code, h) = rc.materialize(route, meterRoot, surface)
    check code == ecInvalidParams
    check h.vtable == nil and h.state == nil
    let b = acceptCallSurfaceDescriptor(surface, "meter_module").tryGet
    let projected = encodeCbor(
      schemaResponse(
        acceptContractSet(
          b.primary.get.source,
          b.interfaces.mapIt(it.source),
          b.supporting.mapIt(it.source),
        ).tryGet,
        meterRoot,
      ).tryGet
    )
    check projected == meterSchema
    let (madeCode, made) = rc.materialize(route, meterRoot, projected)
    check madeCode == ecOk
    var p = made
    check p.read(5).isOk
    p.release()
    e.finish()

  test "[IFC-0944] semantic CDDL, document-set and resource-limit failures of the construction input are INVALID_PARAMS without validation detail (INTERFACE §5.2 l.3886)":
    let e = fixtureEngine(config(extra = @[sensorReg]))
    discard e.started(meter())
    discard e.started(sensor(), "s1")
    let (_, rc) = e.startClient()
    let meterRoute = rc.routeId("m")
    let primary = sensorSet.primary.root
    let sensorRoute = rc.establish("s", primary).routesOf.routes[0].route
    # Deterministic CBOR and a logos.schema_response value each: the document
    # refers to a rule it does not define; the interface `_implements` names
    # is missing.
    let undefined =
      responseOf(meterSet.primary.source & "meter.broken = meter.missing\n", @[], @[])
    let incomplete = responseOf(sensorSet.primary.source, @[], sensorSet.supporting)
    check "undefined name" in acceptSchemaResponse(undefined).error
    check "names no supplied interface" in acceptSchemaResponse(incomplete).error
    let oversized = newSeq[byte](MaxSchemaResponseBytes + 1)
    for (route, root, bytes) in [
      (meterRoute, meterRoot, undefined),
      (sensorRoute, primary, incomplete),
      (meterRoute, meterRoot, oversized),
    ]:
      let r = rc.materializeStatus(route, root, bytes)
      check r.code == ecInvalidParams
      check r.detailNull and r.detailLen == 0
      check r.handle.vtable == nil and r.handle.state == nil
    # The same routes materialize from valid construction input.
    var good = rc.materializeStatus(
      sensorRoute, primary, encodeCbor(schemaResponse(sensorSet, primary).tryGet)
    )
    check good.code == ecOk
    good.handle.release()
    var h = rc.handle(meterRoute)
    h.release()
    e.finish()

  test "[RUN-0087] an interface route's logos.schema is the provider's validated interface contract, never a consumer's construction input or the primary contract (RUNTIME §2.4 l.432-434)":
    let e = fixtureEngine(config(extra = @[sensorReg]))
    discard e.started(sensor(), "s1")
    let (_, rc) = e.startClient()
    let iface = sensorSet.interfaces[0]
    let ifaceSchema = encodeCbor(schemaResponse(sensorSet, iface.root).tryGet)
    let route = rc.establish("i", iface.root).routesOf.routes[0].route
    # A consumer's copy of the interface document that differs only in a
    # comment reconstructs the same root. It is materialized first, so it is
    # the construction input this thread validated first.
    let copy = acceptContractSet(iface.source & "; the consumer's copy\n").tryGet
    check copy.primary.root == iface.root
    let copySchema = encodeCbor(schemaResponse(copy, iface.root).tryGet)
    check copySchema != ifaceSchema
    let (copyCode, copyMade) = rc.materialize(route, iface.root, copySchema)
    check copyCode == ecOk
    var c = copyMade
    let (code, made) = rc.materialize(route, iface.root, ifaceSchema)
    check code == ecOk
    var h = made
    let fromCopy = c.raw("schema", [0xA0'u8])
    check fromCopy.code == ecOk
    check fromCopy.response == ifaceSchema
    let fromExact = h.raw("schema", [0xA0'u8])
    check fromExact.code == ecOk
    check fromExact.response == ifaceSchema
    # The interface document alone: not the primary contract, and not
    # metrics_types, which only the primary contract uses.
    check sensorSet.supporting.len == 1
    let v = decodeCbor(fromExact.response).tryGet
    check v.lookup("schema").get.text == iface.source
    check v.lookup("interface_schemas").get.items.len == 0
    check v.lookup("supporting_schemas").get.items.len == 0
    c.release()
    h.release()
    e.finish()

  test "[RUN-0155] each direct route reaches the context of its own selected instance, never another initialization of the binding (RUNTIME §4.1 l.858)":
    var cfg = config()
    cfg.stateRoot = Opt.some(cfg.workDir / "state")
    let e = fixtureEngine(cfg)
    var ra = meter()
    ra.stateAssignment = Opt.some("sa")
    var rb = meter()
    rb.stateAssignment = Opt.some("sb")
    # Two initializations of the one static binding `meter`.
    let a = e.started(ra, "m1")
    let b = e.started(rb, "m2")
    let (_, rc) = e.startClient()
    var routes: seq[string]
    for (key, v) in [("a", a), ("b", b)]:
      let r = rc.establish(key, provider = Opt.some(providerAddress(v.providerId)))
      check r.code == ecOk
      check r.routesOf.routes[0].target_provider.provider == v.providerId
      routes.add(r.routesOf.routes[0].route)
    var ha = rc.handle(routes[0])
    var hb = rc.handle(routes[1])
    for (h, state, reads) in [
      (addr ha, "sa", 1'u64),
      (addr ha, "sa", 2'u64),
      (addr hb, "sb", 1'u64),
      (addr ha, "sa", 3'u64),
      (addr hb, "sb", 2'u64),
    ]:
      let r = h[].read(20).tryGet
      check r.label == state
      check r.reading.value == reads
    ha.release()
    hb.release()
    e.finish()

  test "[IFC-0656] [IFC-0657] [IFC-0659] [IFC-0661] [IFC-0663] [IFC-0664] [RUN-0256] [RUN-0837] [RUN-0839] [RUN-0840] observe_end and closure (INTERFACE §2.5 l.1474-1497)":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.routeId("k")
    var h = rc.handle(route)
    var late = rc.handle(route)
    var seen, lateSeen: EndSeen
    check toResult(h.vtable.observeEnd(addr h, nil, nil)).code == ecInvalidParams
    check h.observe(addr seen) == ecOk
    check h.observe(addr seen) == ecInvalidParams
    check rc.close(route).code == ecOk
    check waitUntil(
      proc(): bool =
        seen.count.load == 1
    )
    check seen.code.load == ord(ecNotReady)
    check h.read(5).error.code == ecNotReady
    check late.observe(addr lateSeen) == ecNotReady
    sleep(20)
    check seen.count.load == 1
    check lateSeen.count.load == 0
    h.release()
    late.release()
    e.finish()

  test "[IFC-0981] [TXT-0085] observe_subscription_end: one handler per binding and per handle, never called on registration; a terminal handle installs nothing (INTERFACE §2.5 l.1476-1484; DECISIONS I105)":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    subEndCalls.store(0)
    # The Runtime Control binding's registration.
    check rc.registerSubEnd(nil) == ecInvalidParams
    check rc.registerSubEnd() == ecOk
    check rc.registerSubEnd() == ecInvalidParams
    # A route handle's, with observe_end's rules.
    let route = rc.routeId("k")
    var h = rc.handle(route)
    var late = rc.handle(route)
    var seen: EndSeen
    check h.registerSubEnd(nil) == ecInvalidParams
    check h.registerSubEnd() == ecOk
    check h.registerSubEnd() == ecInvalidParams
    check h.observe(addr seen) == ecOk
    check rc.close(route).code == ecOk
    check waitUntil(
      proc(): bool =
        seen.count.load == 1
    )
    # [SPEC INTERFACE l.1459; I105] the retained code, and nothing installed:
    # the same refusal again, never INVALID_PARAMS for a second registration.
    check late.registerSubEnd() == ecNotReady
    check late.registerSubEnd() == ecNotReady
    sleep(20)
    check subEndCalls.load == 0 # [I105] registration only until re-pin P3
    h.release()
    late.release()
    e.finish()

  test "[IFC-0660] [SPEC INTERFACE l.1483] observe_end past the local registration capacity is MODULE_ERROR and changes no registration (DECISIONS I86)":
    var cfg = config()
    cfg.limits.endRegsPerConsumer = 2
    let e = fixtureEngine(cfg)
    discard e.started(meter())
    let (_, rc) = e.startClient()
    var routes: array[3, string]
    var hs: array[3, LogosRouteHandle]
    var seen: array[3, EndSeen]
    for i in 0 ..< 3:
      routes[i] = rc.routeId("k" & $i)
      hs[i] = rc.handle(routes[i])
    check hs[0].observe(addr seen[0]) == ecOk
    check hs[1].observe(addr seen[1]) == ecOk
    check hs[2].observe(addr seen[2]) == ecModule
    # The refused one retained nothing: its route's end does not reach it.
    check rc.close(routes[2]).code == ecOk
    sleep(20)
    check seen[2].count.load == 0
    # A released handle frees its place; the others still fire.
    hs[0].release()
    var again = rc.handle(rc.routeId("k3"))
    var againSeen: EndSeen
    check again.observe(addr againSeen) == ecOk
    check rc.close(routes[1]).code == ecOk
    check waitUntil(
      proc(): bool =
        seen[1].count.load == 1
    )
    check seen[0].count.load == 0
    hs[1].release()
    hs[2].release()
    again.release()
    e.finish()

  test "[IFC-0516] a released handle gets no terminal callback (INTERFACE §5.2 l.3912-3916)":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.routeId("k")
    var h = rc.handle(route)
    var seen: EndSeen
    check h.observe(addr seen) == ecOk
    h.release()
    check rc.close(route).code == ecOk
    sleep(20)
    check seen.count.load == 0
    e.finish()

suite "run.routes: routes follow their provider and consumer (RUNTIME §3.4, §9.3)":
  test "[RUN-1118] [RUN-1122] [RUN-0165] [RUN-1173] [RUN-0580] [RUN-0360] [TXT-0180] [RUN-0574] [RUN-0841] [RUN-0887] [IFC-0665] a stopped provider fails its routes":
    let e = fixtureEngine(config())
    let m = e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.routeId("k")
    var h = rc.handle(route)
    var seen: EndSeen
    check h.observe(addr seen) == ecOk
    check e.stop(m.instance).tryGet.state == msUnloaded
    check waitUntil(
      proc(): bool =
        seen.count.load == 1
    )
    check seen.code.load == ord(ecNotReady)
    check h.read(5).error.code == ecNotReady
    # [SPEC RUNTIME l.1828, l.1832] The payload is validated (step 3) before
    # readiness (step 7).
    let bad = h.raw("read", encodeCbor(cborMap(@[(cbor("channel"), cbor("x"))])))
    check bad.code == ecInvalidParams
    check bad.detail.len > 0
    check h.raw("schema", [0x01'u8]).code == ecInvalidParams
    check h.raw("nope", [0xA0'u8]).code == ecMethodNotFound
    let rec = e.routes()[0]
    check rec.state.kind == LogosNSRuntimeControlRouteStateKind.Failed
    check rec.failure.get.code == "provider-unavailable"
    # Restarting the provider does not revive the route (§9.3 l.3217).
    check e.start(m.instance).tryGet.state == msReady
    check h.read(5).error.code == ecNotReady
    check rc.renew("r", route).code == ecNotReady
    h.release()
    e.finish()

  test "[RUN-1001] a route stays bound to the provider it selected: when that provider stops it ends, and a new route selects another":
    let e = fixtureEngine(config())
    let a = e.started(meter(), "a")
    let b = e.started(meter(), "b")
    let (_, rc) = e.startClient("c")
    let first = rc.establish("k", provider = Opt.some(providerAddress(a.providerId)))
    check first.code == ecOk
    let route = first.routesOf.routes[0].route
    check first.routesOf.routes[0].target_provider.provider == a.providerId
    check e.stop("a").tryGet.state == msUnloaded
    let rec = e.routes().filterIt(it.route == route)
    check rec.len == 1
    check rec[0].state.kind == LogosNSRuntimeControlRouteStateKind.Failed
    # [SPEC RUNTIME l.3482, l.3553] Never retargeted: it still names `a`, a
    # renewal does not revive it and it cannot be materialized.
    check rec[0].target_provider.provider == a.providerId
    check rc.renew("r", route).code == ecNotReady
    let (code, h) = rc.materialize(route)
    check code != ecOk and h.vtable == nil
    # Consumers acquire new routes: a new key selects `b`.
    let next = rc.establish("k2")
    check next.code == ecOk
    check next.routesOf.routes[0].route != route
    check next.routesOf.routes[0].target_provider.provider == b.providerId
    e.finish()

  test "[RUN-1093] [RUN-0112] [TXT-0283] a stopped consumer closes its routes; a failed one fails them (l.589-591)":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (c1, rc1) = e.startClient()
    discard rc1.routeId("k")
    check e.stop(c1.instance).tryGet.state == msUnloaded
    let closed = e.routes()[0]
    check closed.state.kind == LogosNSRuntimeControlRouteStateKind.Closed
    check closed.failure.isNone
    let (c2, rc2) = e.startClient()
    discard rc2.routeId("k")
    let r = rcCall(
      rc2,
      "report_failure",
      encode(LogosNSRuntimeControlReportFailureRequest(reason: Opt.some("broken"))).tryGet,
    )
    check r.code == ecOk
    check r.response == @[0xA0'u8]
    check waitUntil(
      proc(): bool =
        e.view(c2.instance).tryGet.state == msError
    )
    let failed = e.routes()[1]
    check failed.state.kind == LogosNSRuntimeControlRouteStateKind.Failed
    check failed.failure.get.code == "consumer-unavailable"
    e.finish()

  test "[IFC-0740] [IFC-0287] [IFC-0288] [RUN-0299] [RUN-0300] an admitted call holds its provider's release and sees cancellation (§3.4 l.623)":
    var cfg = config()
    cfg.stopDeadline = PassingStop
    let e = fixtureEngine(cfg)
    let m = e.started(meter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    let before = destroyed.load
    gate.store(true)
    bgDone.store(false)
    var t: Thread[ptr LogosRouteHandle]
    createThread(t, background, addr h)
    check waitUntil(
      proc(): bool =
        held.load == 1
    )
    # The stop deadline passes with the call still inside the provider: still
    # `stopping`, `cleanup-timeout` reported, the provider not released
    # (RUNTIME l.575).
    let s = e.stop(m.instance).tryGet
    check s.state == msStopping
    check s.failure.isSome and s.failure.get.classification == "cleanup-timeout"
    check destroyed.load == before
    check e.routes()[0].state.kind == LogosNSRuntimeControlRouteStateKind.Failed
    gate.store(false)
    joinThread(t)
    when declared(transportParity):
      # [G260; TRANSPORT l.543] Past the stop deadline the session closed: the
      # caller's call failed TRANSPORT_ERROR, and the late result was not sent.
      check bgCode.load == ord(ecTransport)
    else:
      check bgCode.load == 0
      check bgValue.load == 1 # INTERFACE l.2101-2102: marked cancelled
    check waitUntil(
      proc(): bool =
        destroyed.load == before + 1
    )
    # [SPEC RUNTIME l.576] The release that followed completes the stop.
    check waitUntil(
      proc(): bool =
        e.view(m.instance).tryGet.state == msUnloaded
    )
    check e.view(m.instance).tryGet.failure.isNone
    h.release()
    e.finish()

suite "run.routes: ended route records (RUNTIME §7.5, §9.3)":
  test "[RUN-0584] [RUN-0570] [RUN-0564] [RUN-0946] [IMPL] each consumer keeps its newest ended records; a dropped id is unknown (l.3180, l.3249)":
    var cfg = config()
    cfg.endedRoutes = 2
    let e = fixtureEngine(cfg)
    discard e.started(meter())
    let (_, rc) = e.startClient("c1")
    let (_, other) = e.startClient("c2")
    let theirs = other.routeId("t")
    check other.close(theirs).code == ecOk
    let first = rc.establish("k1")
    var ids = @[first.routesOf.routes[0].route]
    check rc.close(ids[0]).code == ecOk
    for i in 2 .. 4:
      ids.add(rc.routeId("k" & $i))
      check rc.close(ids[^1]).code == ecOk
    # One consumer's ended routes do not evict another's.
    check e.routes().mapIt(it.route) == @[theirs, ids[2], ids[3]]
    # A dropped id answers as one that never existed (l.3157-3159, l.3188).
    let unknown = rc.renew("u", "route-unknown")
    for r in [rc.renew("r1", ids[0]), rc.close(ids[1])]:
      check r.code == ecNotAuthorised
      check r.message == unknown.message
    check rc.materialize(ids[0])[0] == ecNotAuthorised
    # A kept one still answers by its state.
    check rc.renew("r3", ids[3]).code == ecNotReady
    check rc.close(ids[3]).code == ecOk
    # [SPEC RUNTIME l.3175-3176] A replay returns the retained result; its use
    # stays subject to the current checks.
    let again = rc.establish("k1")
    check again.code == ecOk
    when declared(transportParity):
      check again.response == first.redacted # [G255] no one-time invocation
    else:
      check again.response == first.response
    check e.routes().len == 3
    e.finish()

  test "[RUN-0838] [IMPL] a record that a live handle reaches is kept and not counted (§7.5 l.1346)":
    var cfg = config()
    cfg.endedRoutes = 1
    let e = fixtureEngine(cfg)
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let held = rc.routeId("a")
    var h = rc.handle(held)
    check rc.close(held).code == ecOk
    let b = rc.routeId("b")
    check rc.close(b).code == ecOk
    let c = rc.routeId("c")
    check rc.close(c).code == ecOk
    check e.routes().mapIt(it.route) == @[held, c]
    # The handle still gets its route's end cause.
    check h.read(1).error.code == ecNotReady
    check rc.renew("r", held).code == ecNotReady
    check rc.renew("r", b).code == ecNotAuthorised
    # Released, the record joins the ended ones as the newest.
    h.release()
    check e.routes().mapIt(it.route) == @[held]
    check rc.renew("r", c).code == ecNotAuthorised
    e.finish()

  test "[RUN-0838] [IMPL] a handle stops reaching its record once its attempt's context is destroyed (INTERFACE l.2004-2006)":
    var cfg = config()
    cfg.endedRoutes = 0
    let e = fixtureEngine(cfg)
    discard e.started(meter())
    let (c, rc) = e.startClient()
    var h = rc.handle(rc.routeId("a"))
    check rc.close(rc.routeId("b")).code == ecOk
    check e.routes().len == 1
    check e.stop(c.instance).tryGet.state == msUnloaded
    when declared(transportParity):
      # [I90] The route's session and the consumer's connection reach the
      # record until the Runtime has seen them close, a moment after the stop
      # returned.
      check waitUntil(
        proc(): bool =
          e.routes().len == 0
      )
    else:
      check e.routes().len == 0
    h.release() # nothing reaches it any more; releasing finds no record
    e.finish()

suite "run.routes: lifecycle through Runtime Control (RUNTIME §9.3 l.3640-3690)":
  test "[RUN-0664] [RUN-1031] [RUN-1032] [RUN-1033] [RUN-1034] [RUN-1035] [RUN-1036] [RUN-1037] [RUN-1042] selection by instance, by name and by provider":
    let e = fixtureEngine(config())
    let m = e.create(meter(), "m1").tryGet
    let (c, rc) = e.startClient()
    let s = rc.lifecycle("start_module", "meter_module", Opt.some("m1"))
    check s.code == ecOk
    let started = s.accepted(LogosNSRuntimeControlStartModuleResponse)
    check started.instance == Opt.some("m1")
    check started.provider.isNone
    check started.state.kind == LogosNSRuntimeControlStateKind.Ready
    let v = e.view("m1").tryGet
    check v.intentOrigin.instance == c.instance
    let stop = rc.stoppedVia("meter_module")
    check stop.code == ecOk
    check stop.accepted(LogosNSRuntimeControlStopModuleResponse).instance ==
      Opt.some("m1")
    let prov = Opt.some(providerAddress(m.providerId))
    check rc.lifecycle("start_module", "meter_module", Opt.some("m1"), prov).code ==
      ecInvalidParams
    check rc.lifecycle("start_module", "meter_module", provider = prov).code ==
      ecInvalidParams
    check rc.lifecycle(
      "start_module", "meter_module", provider = prov, expected = Opt.some(1'u64)
    ).code == ecInvalidParams
    check rc.lifecycle(
      "start_module",
      "meter_module",
      provider = Opt.some(providerAddress(m.providerId, Opt.some("elsewhere"))),
    ).code == ecInvalidParams
    check rc.lifecycle(
      "start_module", "meter_module", provider = Opt.some(providerAddress("p-unknown"))
    ).code == ecNotAuthorised
    check rc.lifecycle("start_module", "meter_module", Opt.some("nobody")).code ==
      ecNotAuthorised
    check rc.lifecycle("start_module", "other_module", Opt.some("m1")).code ==
      ecInvalidParams
    # [re-pin P4a] A stale revision is the typed `stale-revision`, carrying
    # the instance's current execution revision (RUNTIME l.1818-1822).
    let stale = rc.lifecycle(
      "start_module",
      "meter_module",
      Opt.some("m1"),
      expected = Opt.some(999'u64),
      refusal = true,
    )
    check stale.code == ecOk
    check stale.refused.get.stale == Opt.some(e.view("m1").tryGet.execution.revision)
    discard e.create(meter(), "m2").tryGet
    check rc.lifecycle("start_module", "meter_module").code == ecInvalidParams
    check rc.lifecycle("start_module", "nothing_module").code == ecInvalidParams
    e.finish()

  test "[RUN-1041] one instance that provides a primary contract and an interface is one lifecycle target":
    let reg = checkStaticRegistration("sensor", sensorModuleStaticSymbols()).tryGet
    let b =
      bindNative(ModuleCode(kind: codeStatic, table: reg.symbols), "sensor_module")
    let primary = b.tryGet.contracts.primary.get.root
    let iface = b.tryGet.contracts.interfaces[0].root
    let e = fixtureEngine(config(extra = @[reg]))
    discard e.create(
      ModuleRecord(
        module: "sensor_module",
        strategy: stDirectStatic,
        binding: "sensor",
        primaryContract: Opt.some(primary),
        implements: @[iface],
      ),
      "s1",
    ).tryGet
    let (_, rc) = e.startClient()
    let s = rc.lifecycle("start_module", "sensor_module")
    check s.code == ecOk
    check s.accepted(LogosNSRuntimeControlStartModuleResponse).instance == Opt.some(
      "s1"
    )
    # Both contracts route to the one provider.
    let a = rc.establish("p", primary).routesOf.routes[0]
    let i = rc.establish("i", iface).routesOf.routes[0]
    check a.target_provider == i.target_provider and a.instance == i.instance
    let stop = rc.lifecycle("stop_module", "sensor_module")
    check stop.code == ecOk
    check stop.accepted(LogosNSRuntimeControlStopModuleResponse).instance ==
      Opt.some("s1")
    e.finish()

  test "[RUN-0665] [RUN-1038] [RUN-1039] [RUN-1040] name-only selection needs observation authority first (l.3666-3670)":
    let e = fixtureEngine(config(denying(deny(action = Opt.some(aaObserve)))))
    discard e.create(meter(), "m1").tryGet
    let (_, rc) = e.startClient()
    check rc.lifecycle("start_module", "meter_module").code == ecNotAuthorised
    check rc.lifecycle("start_module", "nothing_module").code == ecNotAuthorised
    check rc.lifecycle("start_module", "meter_module", Opt.some("m1")).code == ecOk
    e.finish()

  test "[RUN-1188] [TXT-0201] a caller with a call in progress in the target gets `stopping` at once, as every Runtime Control stop does (l.3551-3556)":
    var cfg = config()
    cfg.stopDeadline = initDuration(seconds = 30) # waiting would take this long
    let e = fixtureEngine(cfg)
    let m = e.started(meter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    gate.store(true)
    bgDone.store(false)
    var t: Thread[ptr LogosRouteHandle]
    createThread(t, background, addr h)
    check waitUntil(
      proc(): bool =
        held.load == 1
    )
    let begun = getMonoTime()
    let r = rc.lifecycle("stop_module", "meter_module", Opt.some(m.instance))
    check getMonoTime() - begun < initDuration(seconds = 5 * Slow)
    check r.code == ecOk
    check r.accepted(LogosNSRuntimeControlStopModuleResponse).state.kind ==
      LogosNSRuntimeControlStateKind.Stopping
    check held.load == 1
    gate.store(false)
    joinThread(t)
    check bgCode.load == 0
    check waitUntil(
      proc(): bool =
        e.view(m.instance).tryGet.state == msUnloaded
    )
    h.release()
    e.finish()

  test "[RUN-1188] [TXT-0201] a module stopping itself gets `stopping` at once":
    var cfg = config()
    cfg.stopDeadline = initDuration(seconds = 30) # the destroy ends well before
    let e = fixtureEngine(cfg)
    let (c, rc) = e.startClient()
    clientDestroyGate.store(true)
    let r = rc.lifecycle("stop_module", "client_module", Opt.some(c.instance))
    check r.code == ecOk
    check r.accepted(LogosNSRuntimeControlStopModuleResponse).state.kind ==
      LogosNSRuntimeControlStateKind.Stopping
    clientDestroyGate.store(false)
    check waitUntil(
      proc(): bool =
        e.view(c.instance).tryGet.state == msUnloaded
    )
    e.finish()

  test "[RUN-1188] [TXT-0201] [TXT-0202] stop_module answers `stopping` while the target's destroy is held, without waiting for it; get_readiness reports `unloaded` once it completes (l.3551-3556)":
    var cfg = config()
    cfg.stopDeadline = initDuration(seconds = 30) # the destroy ends well before
    let e = fixtureEngine(cfg)
    let (_, rc) = e.startClient()
    let (t, _) = e.startClient("target")
    clientDestroyGate.store(true)
    let begun = getMonoTime()
    let r = rc.lifecycle("stop_module", "client_module", Opt.some(t.instance))
    check getMonoTime() - begun < initDuration(seconds = 5 * Slow)
    check r.code == ecOk
    check r.accepted(LogosNSRuntimeControlStopModuleResponse).state.kind ==
      LogosNSRuntimeControlStateKind.Stopping
    let held = LogosNSRuntimeControlGetReadinessResponse.decode(
      rc.readiness("client_module", Opt.some(t.instance)).response
    )
    check held.isOk and held.get.state.kind == LogosNSRuntimeControlStateKind.Stopping
    check not rc.unloadedNow("client_module", Opt.some(t.instance))
    clientDestroyGate.store(false)
    check waitUntil(
      proc(): bool =
        rc.unloadedNow("client_module", Opt.some(t.instance))
    )
    e.finish()

  test "[RUN-0671] [RUN-0673] [RUN-0674] [RUN-1051] shutdown_runtime is Runtime-wide and acknowledges acceptance (l.3695-3700)":
    block:
      let e = fixtureEngine(
        config(
          denying(
            deny(action = Opt.some(aaRuntimeControl), operation = "shutdown_runtime")
          )
        )
      )
      let (_, rc) = e.startClient()
      check rcCall(rc, "shutdown_runtime", [0xA0'u8]).code == ecNotAuthorised
      e.finish()
    let e = fixtureEngine(config())
    let m = e.started(meter())
    let (c, rc) = e.startClient()
    let r = rcCall(rc, "shutdown_runtime", [0xA0'u8])
    check r.code == ecOk
    check r.response == @[0xA0'u8]
    e.shutdown()
    for id in [m.instance, c.instance]:
      let v = e.view(id).tryGet
      check v.state == msUnloaded
      check v.execution.intent == inRequested # shutdown preserves intent
    check e.close()

suite "run.rc: get_readiness (RUNTIME §9.3 l.3494-3496, l.3656-3675, l.3702-3712)":
  test "[RUN-0627] [RUN-0991] a local instance's state and execution from one snapshot, with its exact instance and no provider":
    let e = fixtureEngine(config())
    discard e.create(meter(), "m1").tryGet
    let (_, rc) = e.startClient()
    var r = rc.readiness("meter_module", Opt.some("m1"))
    check r.code == ecOk
    var g = LogosNSRuntimeControlGetReadinessResponse.decode(r.response).tryGet
    check g.instance == Opt.some("m1") and g.provider.isNone
    check g.state.kind == LogosNSRuntimeControlStateKind.Unloaded
    check g.execution.get.intent.kind ==
      LogosNSRuntimeControlExecutionStateIntentChoiceKind.Uninitialized
    check g.execution.get.intent_revision.isNone and g.failure.isNone
    let rev = g.execution.get.revision
    check rev == e.view("m1").tryGet.execution.revision
    # [RUN-0025] The conditional start an orchestrator makes from it.
    check rc.lifecycle(
      "start_module", "meter_module", Opt.some("m1"), expected = Opt.some(rev)
    ).code == ecOk
    r = rc.readiness("meter_module") # by name: the one instance
    g = LogosNSRuntimeControlGetReadinessResponse.decode(r.response).tryGet
    let v = e.view("m1").tryGet
    check g.state.kind == LogosNSRuntimeControlStateKind.Ready
    check g.execution.get.revision == v.execution.revision
    check g.execution.get.intent.kind ==
      LogosNSRuntimeControlExecutionStateIntentChoiceKind.Requested
    check g.execution.get.intent_revision == v.execution.intentRevision
    # A stale revision no longer starts it: the typed `stale-revision` names
    # the revision the snapshot now reports.
    let stale = rc.lifecycle(
      "start_module",
      "meter_module",
      Opt.some("m1"),
      expected = Opt.some(rev),
      refusal = true,
    )
    check stale.code == ecOk
    check stale.refused.get.stale == Opt.some(v.execution.revision)
    e.finish()

  test "a failed instance reports its classification and reason":
    let e = fixtureEngine(config())
    discard e.create(
      ModuleRecord(
        module: "meter_module",
        strategy: stDirectStatic,
        binding: "meter",
        primaryContract: Opt.some(default(Digest)),
      ),
      "bad",
    ).tryGet
    check e.start("bad").tryGet.state == msError
    let (_, rc) = e.startClient()
    let g = LogosNSRuntimeControlGetReadinessResponse.decode(
      rc.readiness("meter_module", Opt.some("bad")).response
    ).tryGet
    check g.state.kind == LogosNSRuntimeControlStateKind.Error
    check g.failure == Opt.some("initialization-failed")
    check g.reason.isSome
    e.finish()

  test "[RUN-1031] [RUN-1033] [RUN-1034] [RUN-1035] [RUN-1036] [RUN-1042] selectors as for start and stop":
    let e = fixtureEngine(config())
    let m = e.create(meter(), "m1").tryGet
    let (_, rc) = e.startClient()
    let prov = Opt.some(providerAddress(m.providerId))
    check rc.readiness("meter_module", Opt.some("m1"), prov).code == ecInvalidParams
    check rc.readiness("meter_module", provider = prov).code == ecInvalidParams
    check rc.readiness(
      "meter_module",
      provider = Opt.some(providerAddress(m.providerId, Opt.some("elsewhere"))),
    ).code == ecInvalidParams
    check rc.readiness(
      "meter_module", provider = Opt.some(providerAddress("p-unknown"))
    ).code == ecNotAuthorised
    check rc.readiness("meter_module", Opt.some("nobody")).code == ecNotAuthorised
    check rc.readiness("other_module", Opt.some("m1")).code == ecInvalidParams
    discard e.create(meter(), "m2").tryGet
    check rc.readiness("meter_module").code == ecInvalidParams
    check rc.readiness("nothing_module").code == ecInvalidParams
    e.finish()

  test "[RUN-1038] [RUN-1039] [IMPL-DECISION G161] observation authority: over the name scope first, then over the exact record":
    block:
      let e =
        fixtureEngine(config(denying(deny(action = Opt.some(aaObserve), target = ""))))
      discard e.create(meter(), "m1").tryGet
      let (_, rc) = e.startClient()
      check rc.readiness("meter_module").code == ecNotAuthorised
      check rc.readiness("nothing_module").code == ecNotAuthorised
      check rc.readiness("meter_module", Opt.some("m1")).code == ecNotAuthorised
      e.finish()
    let e = fixtureEngine(
      config(
        denying(
          deny(action = Opt.some(aaObserve), operation = "get_readiness", target = "m1")
        )
      )
    )
    discard e.create(meter(), "m1").tryGet
    let (_, rc) = e.startClient()
    # The exact record is refused like an unknown one, and a record selected
    # by name still needs its own authority.
    check rc.readiness("meter_module", Opt.some("m1")).code == ecNotAuthorised
    check rc.readiness("other_module", Opt.some("m1")).code == ecNotAuthorised
    check rc.readiness("meter_module").code == ecNotAuthorised
    e.finish()

suite "run.routes: marked methods on the remote profiles (RUNTIME l.1808, l.2939; TRANSPORT l.1188-1189)":
  # [DECISIONS G277] The check 5-7a calls where remote routes and provider
  # sessions are made (`runtime/remotemarked.nim`), over the vault contract,
  # which marks `store`'s request, `fetch`'s response and both of `exchange`.
  let
    vaultSet = acceptContractSet(readFile(repo / "tests/kit/vault_module.cddl")).tryGet
    vault = selectContract(
      ModuleBinding(module: "vault_module", primary: Opt.some(vaultSet.primary)),
      vaultSet.primary.root,
      vaultSet.context,
    ).get
    sensorContract = selectContract(
      ModuleBinding(
        module: "sensor_module",
        primary: Opt.some(sensorSet.primary),
        interfaces: sensorSet.interfaces,
      ),
      sensorSet.primary.root,
      sensorSet.context,
    ).get

  proc scope(
      c: SelectedContract, names: varargs[string]
  ): LogosNSRuntimeControlRouteAccess =
    ## A method list of these methods' roots (`schema`: the well-known one).
    var roots: seq[seq[byte]]
    for n in names:
      roots.add(@(c.methodRoot(n).get))
    LogosNSRuntimeControlRouteAccess(methods: Opt.some(roots))

  test "[TXT-0157] a tls-tcp or quic route whose permitted scope includes a marked method is refused, whichever payload is marked, and an absent list permits every method":
    check vault.sensitive.len == 3
    for profile in [RemoteTlsTcp, RemoteQuic]:
      check withoutMarked(profile)
      for marked in ["store", "fetch", "exchange"]:
        check refusesMarked(profile, vault.scope(marked), vault)
        check refusesMarked(profile, vault.scope("peek", marked, "schema"), vault)
      check refusesMarked(profile, LogosNSRuntimeControlRouteAccess(), vault)
      # the events lists do not matter
      check refusesMarked(
        profile,
        LogosNSRuntimeControlRouteAccess(
          publish_events: Opt.some(newSeq[seq[byte]]()),
          subscribe_events: Opt.some(newSeq[seq[byte]]()),
        ),
        vault,
      )

  test "[TXT-0157] a scope without a marked method passes: narrowed by the request or by a renewal's decision, empty, or over a contract that marks nothing":
    for profile in [RemoteTlsTcp, RemoteQuic]:
      check not refusesMarked(profile, vault.scope("peek"), vault)
      check not refusesMarked(profile, vault.scope("peek", "schema"), vault)
      check not refusesMarked(profile, vault.scope("schema"), vault)
      check not refusesMarked(profile, vault.scope(), vault)
      # a renewal narrowed from the whole contract to the unmarked method: the
      # caller passes the scope after the decision, so the same answer
      check refusesMarked(profile, LogosNSRuntimeControlRouteAccess(), vault)
      check not refusesMarked(profile, vault.scope("peek"), vault)
      check sensorContract.sensitive.len == 0
      check not refusesMarked(
        profile, LogosNSRuntimeControlRouteAccess(), sensorContract
      )

  test "[TXT-0129] another remote profile may carry marked payloads: the check refuses only tls-tcp and quic":
    for profile in ["logos.remote.erasing", "logos.remote.tls-tcp.v2", ""]:
      check not withoutMarked(profile)
      check not refusesMarked(profile, LogosNSRuntimeControlRouteAccess(), vault)
      check not refusesMarked(profile, vault.scope("store", "exchange"), vault)
