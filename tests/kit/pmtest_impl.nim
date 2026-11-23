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
## - `resolve {name, version}` answers the driver's outcome for that exact root:
##   the selected packages with their schema roots, and the resolver's
##   counters; or the error code and its message.

{.used.} # imported by the tests for the C symbols it exports
import ../generated/pmtest_module_kit
import ../../src/logos_core/pm/shell
import ../../src/logos_core/package/[errors, records, resolver]

type PmTest* = ref object
  shell: Shell

proc initModule(_: type PmTest, init: ModuleInit): Result[PmTest, InvocationFailure] =
  let s = ?openShell(init)
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

proc `resolve`(
    m: PmTest, request: PmtestResolveRequest, inv: Invocation
): Future[Result[PmtestResolveResponse, InvocationFailure]] {.async: (raises: []).} =
  type K = PmtestResolveResponseKind
  let outcome = await m.shell.resolveRoot(
    RootReference(package: Opt.some(request.name), version: Opt.some(request.version))
  )
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

exportPmtestModule(PmTest)
