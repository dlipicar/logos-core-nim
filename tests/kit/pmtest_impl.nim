## The Package Manager's shell under a test name (Tier 5 step 5-3b, F5;
## DECISIONS G405): `pmtest_module` (`tests/kit/pmtest_module.cddl`), a
## thread-confined kit module whose body is `pm/shell.nim`. Until 5-6a lifts
## the refusal of a hosted `logos_` provider, the hosted skeleton runs under this
## name. Never shipped: 5-6a's `logos_package_manager` replaces it over the same
## shell.
##
## - `status` answers the catalog in use (its sequence, digest and entry
##   count), each binding's route state, route id, readiness and the routes
##   established for it, and the root operations still running.
## - Its resolutions take turns of a single work unit (`PmtestTurnWork`, G455).
## - `resolve {name, version}` answers the driver's outcome for that exact root:
##   the selected packages with their schema roots, and the resolver's
##   counters; or the error code and its message.
## - `handoff {package, version, module}` (5-5-4) answers `get_runtime_handoff`'s
##   response bytes, a query that takes no slot.
## - `inspect`, `install`, `remove` and `update` (5-5-4, G449) carry one
##   operation through `shell.operate`: the request's fields become its root
##   (`source` is a deterministic-CBOR `package_source`, PM §15), and the
##   answer comes back as the §15 response value, deterministic CBOR in
##   `response`; a full queue or an admission bound is the invocation error
##   `MODULE_ERROR`.

{.used.} # imported by the tests for the C symbols it exports
import ../generated/pmtest_module_kit
import ../../src/logos_core/pm/shell
import logos_sdk/cbor
import ../../src/logos_core/package/[errors, records, resolver]

type PmTest* = ref object
  shell: Shell

const PmtestTurnWork = 1'i64
  ## [IMPL; G455] Every hosted resolution is sliced at each work unit, so each
  ## goes through the event loop turn by turn, as one at the maxima does
  ## (`test_pm_hosted`'s sliced case). It changes no outcome.

proc initModule(_: type PmTest, init: ModuleInit): Result[PmTest, InvocationFailure] =
  let s = ?openShell(init, turnWork = PmtestTurnWork)
  ok(PmTest(shell: s))

proc destroyModule(m: PmTest) {.async: (raises: []).} =
  await m.shell.closeShell()

func stateOf(s: RouteState): PmtestBindingStateChoice =
  type K = PmtestBindingStateChoiceKind
  PmtestBindingStateChoice(
    kind:
      case s
      of rsIdle: K.Idle
      of rsEstablishing: K.Establishing
      of rsReady: K.Ready
      of rsRenewing: K.Renewing
      of rsBackoff: K.Backoff
      of rsStopped: K.Stopped
  )

func readinessOf(r: Readiness): PmtestBindingReadinessChoice =
  type K = PmtestBindingReadinessChoiceKind
  PmtestBindingReadinessChoice(
    kind:
      case r
      of rdStarting: K.Starting
      of rdReady: K.Ready
      of rdOffline: K.Offline
  )

proc `status`(
    m: PmTest, request: PmtestStatusRequest
): Result[PmtestStatusResponse, InvocationFailure] =
  let st = m.shell.shellStatus()
  var r = PmtestStatusResponse(pending: uint64(st.pending))
  if st.catalog.isSome:
    let c = st.catalog.get
    r.catalog = Opt.some(
      PmtestCatalog(
        sequence: c.sequence, digest: @(c.digest), entries: uint64(c.entries.len)
      )
    )
  for b in st.bindings:
    r.bindings.add(
      PmtestBinding(
        name: b.binding.name,
        instance: b.binding.instance,
        state: stateOf(b.binding.state),
        route:
          if b.binding.route.len > 0:
            Opt.some(b.binding.route)
          else:
            Opt.none(string),
        readiness: b.binding.readiness.map(readinessOf),
        established: uint64(b.established),
      )
    )
  ok(r)

func cancelled(): InvocationFailure =
  ## [G338; G449] A handler the kit cancelled (the Runtime's cancel, a stop): its
  ## operation was cancelled in the engine, and the call ends CANCELLED.
  failure(ecCancelled, "the operation was cancelled")

proc `resolve`(
    m: PmTest, request: PmtestResolveRequest, inv: Invocation
): Future[Result[PmtestResolveResponse, InvocationFailure]] {.async: (raises: []).} =
  type K = PmtestResolveResponseKind
  let outcome =
    try:
      await m.shell.resolveRoot(
        RootReference(
          package: Opt.some(request.name), version: Opt.some(request.version)
        )
      )
    except CancelledError:
      return err(cancelled())
  if outcome.isErr:
    let e = outcome.error
    var msg = e.msg
    if msg.len > 512:
      # Cut at a character boundary: the schema bounds the UTF-8 bytes.
      var n = 512
      while n > 0 and (ord(msg[n]) and 0xC0) == 0x80:
        dec n
      msg.setLen(n)
    return ok(
      PmtestResolveResponse(
        kind: K.Map_error,
        arm_Map_error: PmtestResolveResponseARMapErrorMap(
          error: $e.code,
          message: (if msg.len > 0: Opt.some(msg) else: Opt.none(string)),
        ),
      )
    )
  let r = outcome.get
  var packages: seq[PmtestSelected]
  for p in r.packages:
    packages.add(
      PmtestSelected(
        package: p.identity.package,
        version: p.identity.version,
        schema_root: @(p.commitment.schemaRoot),
        installed: p.installed,
      )
    )
  ok(
    PmtestResolveResponse(
      kind: K.Map_counters_packages,
      arm_Map_counters_packages: PmtestResolveResponseARMapCountersPackagesMap(
        packages: packages,
        counters: PmtestCounters(
          names: uint64(r.counters.names),
          depth: uint64(r.counters.depth),
          attempts: uint64(r.counters.attempts),
        ),
      ),
    )
  )

proc sourceOf(bytes: Opt[seq[byte]]): Result[Opt[PackageSource], InvocationFailure] =
  ## A request's `source`: one deterministic-CBOR `package_source` (PM §15).
  if bytes.isNone:
    return ok(Opt.none(PackageSource))
  let v = decodeCbor(bytes.get)
  if v.isErr:
    return err(failure(ecInvalidParams, "source: not one deterministic-CBOR value"))
  let s = decodeSource(v.get)
  if s.isErr:
    return err(failure(ecInvalidParams, "source: " & s.error))
  ok(Opt.some(s.get))

proc run(
    m: PmTest, op: OperationRequest
): Future[Result[seq[byte], InvocationFailure]] {.async: (raises: []).} =
  let a =
    try:
      await m.shell.operate(op)
    except CancelledError:
      return err(cancelled())
  case a.kind
  of oaResponse:
    ok(encodeCbor(a.response))
  of oaModuleError:
    err(moduleError(a.reason))
  of oaEncoded:
    var b = newSeq[byte](a.encoded.len)
    if b.len > 0:
      copyMem(addr b[0], unsafeAddr a.encoded[0], b.len)
    ok(b)

proc `inspect`(
    m: PmTest, request: PmtestInspectRequest, inv: Invocation
): Future[Result[PmtestInspectResponse, InvocationFailure]] {.async: (raises: []).} =
  let source = ?sourceOf(request.source)
  let op = OperationRequest(
    kind: opInspect,
    root:
      RootReference(package: request.package, version: request.version, source: source),
  )
  let response = ?(await m.run(op))
  ok(PmtestInspectResponse(response: response))

proc `install`(
    m: PmTest, request: PmtestInstallRequest, inv: Invocation
): Future[Result[PmtestInstallResponse, InvocationFailure]] {.async: (raises: []).} =
  let source = ?sourceOf(request.source)
  let op = OperationRequest(
    kind: opInstall,
    root: RootReference(
      package: Opt.some(request.package), version: request.version, source: source
    ),
  )
  let response = ?(await m.run(op))
  ok(PmtestInstallResponse(response: response))

proc `remove`(
    m: PmTest, request: PmtestRemoveRequest, inv: Invocation
): Future[Result[PmtestRemoveResponse, InvocationFailure]] {.async: (raises: []).} =
  let op = OperationRequest(
    kind: opRemove,
    identity: PackageIdentity(package: request.package, version: request.version),
  )
  let response = ?(await m.run(op))
  ok(PmtestRemoveResponse(response: response))

proc `update`(
    m: PmTest, request: PmtestUpdateRequest, inv: Invocation
): Future[Result[PmtestUpdateResponse, InvocationFailure]] {.async: (raises: []).} =
  let source = ?sourceOf(request.source)
  let op = OperationRequest(
    kind: opUpdate,
    root: RootReference(
      package: Opt.some(request.package),
      version: request.target_version,
      source: source,
      newerThan:
        Opt.some(PackageIdentity(package: request.package, version: request.version)),
    ),
  )
  let response = ?(await m.run(op))
  ok(PmtestUpdateResponse(response: response))

proc `handoff`(
    m: PmTest, request: PmtestHandoffRequest, inv: Invocation
): Future[Result[PmtestHandoffResponse, InvocationFailure]] {.async: (raises: []).} =
  let a =
    try:
      await m.shell.handoff(
        PackageIdentity(package: request.package, version: request.version),
        request.module,
      )
    except CancelledError:
      return err(cancelled())
  case a.kind
  of oaResponse:
    ok(PmtestHandoffResponse(response: encodeCbor(a.response)))
  of oaModuleError:
    err(moduleError(a.reason))
  of oaEncoded:
    var b = newSeq[byte](a.encoded.len)
    if b.len > 0:
      copyMem(addr b[0], unsafeAddr a.encoded[0], b.len)
    ok(PmtestHandoffResponse(response: b))

exportPmtestModule(PmTest)
