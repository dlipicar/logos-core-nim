## The reference orchestration module through the Host Embedding API
## (DECISIONS I94, part 4b-5b): a host configuration names an `lcn_orchestrator`
## instance as the orchestration instance, with the module's declaration
## (`orchestratorDeclaration()`) and, when a case provisions one, its value
## (`encodeSettings`), and registers the bindings `lcn_orchestrator` and
## `flaky` (`tests/kit/flaky_impl.nim`). Runtimes keep `store_dir` and
## `state_root`, so a case restarts a Runtime on the same directories. An
## unclean end is a stored snapshot that still shows instances `ready`, as
## `test_persist` writes it (G193).
##
## Cases with an external authority use the library's own Capability
## Authority with a policy that lets the orchestration module observe and
## start the flaky instances; it starts the authority itself under the derived
## rules (RUNTIME l.1640-1643, l.1674-1680).

import std/[atomics, locks, monotimes, os, strutils, tables, times]
import unittest2
import ../src/logos_core/runtime/[engine, host, store]
import ../src/logos_core/runtime/host_config_types except
  LcnAuthorityPolicy, LcnAuthorityPolicyAuditMap
import ../src/logos_core/abi/types
import ../src/logos_core/cbor
import ../src/logos_core/iface/outcome
import ../src/logos_core/orchestration
import ../src/logos_core/orchestration/[accounting, testhooks]
import ./support/authfixture except
  LogosNSRuntimeModuleInstanceAddress, LogosNSRuntimeModuleInstanceId,
  LogosNSRuntimeModuleName, LogosNSRuntimeModuleProviderAddress,
  LogosNSRuntimeModuleProviderId, LogosNSRuntimeModuleStateAssignmentId,
  LogosNSRuntimeRouteId, LogosNSRuntimeRuntimeInstanceId
import ./kit/flaky_impl

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "orchestration_host"
removeDir(work)
createDir(work)

const
  RtId = "rt-orch"
  Orch = "orch"
  Ca = "ca"
  OrchState = "orch-state"
  CaState = "ca-state"
  Flaky = "flaky_module"
  CaModule = "logos_capability_authority"

# Diagnostics: plain bytes behind a lock, written on the module's threads -------------

var
  diagLock: Lock
  diagBuf: ptr UncheckedArray[char]
  diagLen: int
const DiagCap = 1 shl 20
initLock(diagLock)
diagBuf = cast[ptr UncheckedArray[char]](allocShared0(DiagCap))

proc sink(line: string) {.nimcall, gcsafe, raises: [].} =
  withLock diagLock:
    for c in line & "\n":
      if diagLen < DiagCap:
        diagBuf[diagLen] = c
        inc diagLen

proc diagText(): string =
  withLock diagLock:
    result = newString(diagLen)
    for i in 0 ..< diagLen:
      result[i] = diagBuf[i]

proc clearDiag() =
  withLock diagLock:
    diagLen = 0

setOrchestratorDiagnostics(sink)

# The deployment -----------------------------------------------------------------------

proc ms(n: int): int64 =
  int64(n) * Slow

proc restart(
    initial = 20, maxMs = 200, mult = 2, attempts = 3, stable = 100
): LcnOrchestratorRestart =
  LcnOrchestratorRestart(
    kind: LcnOrchestratorRestartKind.Backoff,
    arm_Backoff: LcnOrchestratorRestartARBackoffMap(
      initial_delay_ms: uint32(ms(initial)),
      max_delay_ms: uint32(ms(maxMs)),
      multiplier: uint32(mult),
      max_attempts: Opt.some(uint32(attempts)),
      stable_ms: uint32(ms(stable)),
    ),
  )

func disabled(): LcnOrchestratorRestart =
  LcnOrchestratorRestart(
    kind: LcnOrchestratorRestartKind.Disabled,
    arm_Disabled: LcnOrchestratorRestartARDisabledMap(),
  )

proc starts(slots: varargs[int]): Opt[seq[LcnOrchestratorDefault]] =
  var ds: seq[LcnOrchestratorDefault]
  for s in slots:
    ds.add(LcnOrchestratorDefault(module: Flaky, instance: flakyInstance(s)))
  Opt.some(ds)

proc value(
    defaults = Opt.none(seq[LcnOrchestratorDefault]),
    restart = Opt.some(restart()),
    authority = false,
): OrchestratorSettings =
  OrchestratorSettings(
    authority: (
      if authority:
        Opt.some(LcnOrchestratorTarget(module: CaModule, instance: Ca))
      else:
        Opt.none(LcnOrchestratorTarget)
    ),
    defaults: defaults,
    restart: restart,
    resync_ms: Opt.some(uint32(ms(200))),
  )

proc module(instance, module, binding: string): LcnAppModule =
  LcnAppModule(
    instance: instance,
    module: module,
    implementation: LcnAppImplementation(
      kind: LcnAppImplementationKind.Direct_static,
      arm_Direct_static: LcnAppImplementationARDirectStaticMap(binding: binding),
    ),
  )

proc caPolicy(): host_config_types.LcnAuthorityPolicy =
  ## The orchestration module may use Runtime Control and start or stop the
  ## flaky instances; nothing else.
  let bytes = policyBytes(
    @[
      allowRule(
        subject(modules = @[OrchestratorModule]),
        @[
          rcPattern(),
          mePattern(
            subject(modules = @[Flaky]),
            @[
              policy_types.LcnApModuleExecutionActionsLIChoiceKind.Start,
              policy_types.LcnApModuleExecutionActionsLIChoiceKind.Stop,
            ],
          ),
        ],
      )
    ]
  )
  host_config_types.LcnAuthorityPolicy.fromCbor(decodeCbor(bytes).tryGet).tryGet

proc deployment(
    dir: string,
    v: Opt[OrchestratorSettings],
    slots: seq[int],
    authority = false,
    recovery = false,
    stateDir = true,
): LcnAppConfig =
  var orch = module(Orch, OrchestratorModule, OrchestratorBinding)
  orch.configuration = Opt.some(orchestratorDeclaration().tryGet)
  if v.isSome:
    orch.provisioned_configuration = Opt.some(encodeSettings(v.get).tryGet)
  if stateDir:
    orch.state_assignment = Opt.some(OrchState)
  var modules = @[orch]
  for s in slots:
    modules.add(module(flakyInstance(s), Flaky, "flaky"))
  result = LcnAppConfig(
    runtime: LcnAppRuntime(
      work_dir: dir / "w",
      state_root: Opt.some(dir / "state"),
      store_dir: Opt.some(dir / "store"),
      runtime_instance_id: Opt.some(RtId),
      stop_deadline_ms: Opt.some(uint32(ms(300))),
    ),
    policy: LcnAppPolicy(kind: LcnAppPolicyKind.Allow_all),
    orchestration: Orch,
    modules: modules,
  )
  if authority:
    var ca = module(Ca, CaModule, CaModule)
    ca.state_assignment = Opt.some(CaState)
    result.modules.add(ca)
    result.policy = LcnAppPolicy(
      kind: LcnAppPolicyKind.Capability_authority,
      arm_Capability_authority: LcnAppPolicyARCapabilityAuthorityMap(
        authority: Ca,
        policy: caPolicy(),
        evaluation_deadline_ms: Opt.some(60_000'u32),
        recovery: (if recovery: Opt.some(true) else: Opt.none(bool)),
      ),
    )

# Host calls ---------------------------------------------------------------------------

proc ec(r: LogosResult): ErrorCode =
  errorCode(int64(r.code)).get

proc text(r: LogosResult): string =
  if r.message.isNil:
    ""
  else:
    $r.message

proc create(c: LcnAppConfig): ptr LogosRuntimeHandle =
  let bytes = c.encode.get
  var cfg = LogosRuntimeConfig(
    abiVersion: RuntimeHostAbiVersion,
    structSize: csize_t(sizeof(LogosRuntimeConfig)),
    configurationFormat: AppConfigFormat,
    configuration: cast[ptr UncheckedArray[uint8]](unsafeAddr bytes[0]),
    configurationLen: csize_t(bytes.len),
  )
  check runtimeCreate(addr cfg, addr result).ec == ecOk

proc register(
    rt: ptr LogosRuntimeHandle, id: string, table: openArray[(string, pointer)]
): ErrorCode =
  var names: seq[string]
  for (n, _) in table:
    names.add(n)
  var symbols = newSeq[LogosRuntimeNativeSymbol](table.len)
  for i in 0 ..< table.len:
    symbols[i] = LogosRuntimeNativeSymbol(
      name: cstring(names[i]), address: cast[LogosRuntimeSymbolAddress](table[i][1])
    )
  var b = LogosRuntimeNativeBinding(
    abiVersion: RuntimeHostAbiVersion,
    structSize: csize_t(sizeof(LogosRuntimeNativeBinding)),
    binding: cstring(id),
    symbols: cast[ptr UncheckedArray[LogosRuntimeNativeSymbol]](addr symbols[0]),
    symbolCount: csize_t(symbols.len),
  )
  runtimeRegisterBinding(rt, addr b).ec

var live: ptr LogosRuntimeHandle ## the Runtime the teardown ends, if any

proc registered(c: LcnAppConfig): ptr LogosRuntimeHandle =
  result = create(c)
  check result.register(OrchestratorBinding, orchestratorStaticSymbols()) == ecOk
  check result.register("flaky", flakyModuleStaticSymbols()) == ecOk
  live = result

proc boot(c: LcnAppConfig): (ptr LogosRuntimeHandle, Engine) =
  let rt = registered(c)
  let r = runtimeStart(rt)
  check r.ec == ecOk
  (rt, engineOf(rt))

proc finish(rt: ptr LogosRuntimeHandle) =
  ## Request, wait and destroy, each OK. Destroy is retried while a worker is
  ## still leaving module code after shutdown (RUN-0761), as `Engine.close`
  ## does for the engine-level tests.
  if live == rt:
    live = nil
  for i in 0 ..< FlakySlots:
    flaky[i].initGate.store(false)
    flaky[i].destroyGate.store(false)
  check runtimeRequestShutdown(rt).ec == ecOk
  check runtimeWaitForShutdown(rt).ec == ecOk
  let until = getMonoTime() + initDuration(seconds = 10 * Slow)
  var r = runtimeDestroy(rt)
  while r.ec == ecNotReady and "still running" in r.text and getMonoTime() < until:
    sleep(1)
    r = runtimeDestroy(rt)
  check r.ec == ecOk

proc waitUntil(cond: proc(): bool {.closure.}, seconds = 10 * Slow): bool =
  let until = getMonoTime() + initDuration(seconds = seconds)
  while getMonoTime() < until:
    if cond():
      return true
    sleep(2)
  cond()

proc state(e: Engine, id: string): ModuleState =
  e.view(id).tryGet.state

proc isReady(e: Engine, id: string): proc(): bool =
  result = proc(): bool =
    e.state(id) == msReady

proc recovers(id: string): int =
  callsForTests("recover_module", id)

proc reportFailure(e: Engine, id: string) =
  let v = e.view(id).tryGet
  check e.reportFailure(id, v.attempt, "test").isOk

proc stateFile(dir: string): string =
  dir / "state" / OrchState / StateFileName

proc entryOf(dir, id: string): Opt[Entry] =
  ## The instance's open episode, as the module last wrote it.
  let path = stateFile(dir)
  if not fileExists(path):
    return Opt.none(Entry)
  let s = readFile(path)
  let a = decodeState(s.toOpenArrayByte(0, s.high)).tryGet
  if id in a.entries:
    Opt.some(a.entries.getOrDefault(id))
  else:
    Opt.none(Entry)

proc crash(dir: string, ids: openArray[string]) =
  ## The store as an unclean end leaves it: `ids` still `ready` (G193).
  var (s, snap) = openStore(dir / "store").tryGet
  var x = snap.get
  for i in 0 ..< x.instances.len:
    if x.instances[i].instance in ids:
      x.instances[i].state = msReady
      x.instances[i].failure = Opt.none(Failure)
  s.write(x).tryGet
  s.close()

suite "orch.host: the reference orchestration module behind the Host Embedding API (I94) [IMPL-DECISION G288] [IMPL-DECISION G289] [IMPL-DECISION G290]":
  setup:
    resetFlaky()
    clearOrchestratorFaultsForTests()
    clearDiag()

  teardown:
    if live != nil:
      live.finish()

  test "[RUN-1063] [RUN-1064] a clean restart: every instance with requested intent is resumed once, uncharged":
    let dir = work / "clean"
    let c = deployment(dir, Opt.some(value(defaults = starts(0, 1))), @[0, 1])
    var (rt, e) = boot(c)
    check waitUntil(e.isReady(flakyInstance(0)))
    check waitUntil(e.isReady(flakyInstance(1)))
    rt.finish()
    clearOrchestratorFaultsForTests()
    (rt, e) = boot(c)
    check waitUntil(e.isReady(flakyInstance(0)))
    check waitUntil(e.isReady(flakyInstance(1)))
    for s in [0, 1]:
      let id = flakyInstance(s)
      check recovers(id) == 1
      check callsForTests("start_module", id) == 0 # requested: no default
      check entryOf(dir, id).isNone # a resumption is never charged
      check e.view(id).tryGet.intentOrigin.instance == Orch
    rt.finish()

  test "[RUN-1063] [RUN-1064] [RUN-0686] [IMPL-DECISION G289] an unclean end: a survivor is resumed once, uncharged; an open episode continues charged and ends at max_attempts":
    let dir = work / "unclean"
    flaky[1].failInits.store(1000)
    let c = deployment(
      dir,
      Opt.some(
        value(
          defaults = starts(0, 1),
          restart =
            Opt.some(restart(initial = 20, maxMs = 400, mult = 16, attempts = 4)),
        )
      ),
      @[0, 1],
    )
    var (rt, e) = boot(c)
    check waitUntil(e.isReady(flakyInstance(0)))
    # Two charged recoveries 20 ms apart; the third would be 320 ms later.
    check waitUntil(
      proc(): bool =
        let x = entryOf(dir, flakyInstance(1))
        x.isSome and x.get.attempts == 2 and x.get.pending.isNone and
          e.state(flakyInstance(1)) == msError
    )
    rt.finish()
    crash(dir, [Orch, flakyInstance(0)])
    clearOrchestratorFaultsForTests()
    (rt, e) = boot(c)
    check waitUntil(e.isReady(flakyInstance(0)))
    check recovers(flakyInstance(0)) == 1
    check entryOf(dir, flakyInstance(0)).isNone
    check waitUntil(
      proc(): bool =
        "restart attempts exhausted after 4 of 4" in diagText()
    )
    check recovers(flakyInstance(1)) == 2 # attempts 3 and 4: the episode went on
    let x = entryOf(dir, flakyInstance(1)).get # written before it is reported
    check x.attempts == 4 and x.exhausted
    sleep(int(ms(500)))
    check recovers(flakyInstance(1)) == 2
    rt.finish()

  test "[RUN-0685] the restart policy is protected input: disabled is never retried; with none provisioned the package default applies":
    flaky[0].failInits.store(1)
    let dir = work / "disabled"
    var (rt, e) = boot(
      deployment(
        dir, Opt.some(value(defaults = starts(0), restart = Opt.some(disabled()))), @[0]
      )
    )
    check waitUntil(
      proc(): bool =
        e.state(flakyInstance(0)) == msError
    )
    sleep(int(ms(300)))
    check recovers(flakyInstance(0)) == 0
    check "the restart policy is disabled" in diagText()
    rt.finish()
    # No provisioned value: the declaration's default, 1 s doubling, 8 attempts.
    flaky[1].failInits.store(1000)
    clearOrchestratorFaultsForTests()
    clearDiag() # the first Runtime's "operational" must not satisfy the wait below
    (rt, e) = boot(deployment(work / "package", Opt.none(OrchestratorSettings), @[1]))
    # Operational first: a failure it finds at its first pass would be resumed.
    check waitUntil(
      proc(): bool =
        "operational" in diagText()
    )
    let t0 = getMonoTime().ticks
    check e.start(flakyInstance(1)).isOk
    check waitUntil(
      proc(): bool =
        "recover_module flaky-1: attempt 1 of 8" in diagText()
    )
    let t = callTimesForTests("recover_module", flakyInstance(1))
    check t.len == 1 and (t[0] - t0) div 1_000_000 >= 1000 - 2
    rt.finish()

  test "[RUN-0312] [RUN-1063] [IMPL-DECISION G290] with an external authority the module starts it under the derived rules, then, once it is bound, its defaults":
    let dir = work / "authority"
    let (rt, e) = boot(
      deployment(
        dir,
        Opt.some(value(defaults = starts(0), authority = true)),
        @[0],
        authority = true,
      )
    )
    check waitUntil(e.isReady(flakyInstance(0)))
    check e.authorityBound()[0]
    check e.view(Ca).tryGet.intentOrigin.instance == Orch
    check e.view(flakyInstance(0)).tryGet.intentOrigin.instance == Orch
    # Every call that names an instance before the first naming flaky-0 names
    # the authority; flaky-0's start follows the authority's.
    let targets = targetsForTests()
    let first = targets.find(flakyInstance(0))
    check first > 0
    for i in 0 ..< first:
      check targets[i] == Ca
    let caStarts = callTimesForTests("start_module", Ca)
    let flakyStarts = callTimesForTests("start_module", flakyInstance(0))
    check caStarts.len == 1 and flakyStarts.len == 1
    check flakyStarts[0] > caStarts[0]
    check callsForTests("list_modules") >= 1
    rt.finish()

  test "[RUN-0696] [RUN-1063] [RUN-1065] recovery: the authority fails; the module recovers it under the derived rules, then resumes what its loss stopped, intent and origin kept":
    let dir = work / "recovery"
    let (rt, e) = boot(
      deployment(
        dir,
        Opt.some(value(defaults = starts(0), authority = true)),
        @[0],
        authority = true,
        recovery = true,
      )
    )
    check waitUntil(e.isReady(flakyInstance(0)))
    check waitUntil(
      proc(): bool =
        e.authorityBound()[0]
    )
    let before = flaky[0].inits.load
    e.reportFailure(Ca)
    # The executions it authorized end; then the module brings it back.
    check waitUntil(
      proc(): bool =
        recovers(Ca) >= 1
    )
    check waitUntil(e.isReady(Ca))
    check waitUntil(
      proc(): bool =
        flaky[0].inits.load > before and e.state(flakyInstance(0)) == msReady
    )
    let v = e.view(flakyInstance(0)).tryGet
    check v.execution.intent == inRequested
    check v.intentOrigin.instance == Orch
    check recovers(flakyInstance(0)) >= 1
    check entryOf(dir, flakyInstance(0)).isNone # resumed, never charged
    rt.finish()

  test "[RUN-0686] without a state directory under an enabled policy, or with a corrupt state file, the start fails and says why; disabled needs no directory":
    var rt =
      registered(deployment(work / "nodir", Opt.some(value()), @[], stateDir = false))
    check runtimeStart(rt).ec == ecModule
    check "needs a state directory" in diagText()
    rt.finish()
    # A corrupt file is never overwritten: the start fails naming it.
    let dir = work / "corrupt"
    let c = deployment(dir, Opt.some(value(defaults = starts(0))), @[0])
    var (r2, e) = boot(c)
    check waitUntil(e.isReady(flakyInstance(0)))
    r2.finish()
    writeFile(stateFile(dir), "not a state file")
    clearDiag()
    rt = registered(c)
    check runtimeStart(rt).ec == ecModule
    check StateFileName in diagText() and "remove the file" in diagText()
    check readFile(stateFile(dir)) == "not a state file"
    rt.finish()
    # Disabled everywhere: nothing is counted, no directory is needed.
    (rt, e) = boot(
      deployment(
        work / "nodir-disabled",
        Opt.some(value(defaults = starts(0), restart = Opt.some(disabled()))),
        @[0],
        stateDir = false,
      )
    )
    check waitUntil(e.isReady(flakyInstance(0)))
    rt.finish()

  test "[RUN-1063] [RUN-1064] [RUN-0684] [IMPL-DECISION G289] disabled, an unclean end: every requested survivor in error, the authority too, is resumed once; a later failure is not retried":
    let dir = work / "disabled-unclean"
    let c = deployment(
      dir,
      Opt.some(
        value(defaults = starts(0), authority = true, restart = Opt.some(disabled()))
      ),
      @[0],
      authority = true,
    )
    var (rt, e) = boot(c)
    check waitUntil(e.isReady(flakyInstance(0)))
    rt.finish()
    crash(dir, [Orch, Ca, flakyInstance(0)])
    clearOrchestratorFaultsForTests()
    (rt, e) = boot(c)
    check waitUntil(e.isReady(Ca))
    check waitUntil(e.isReady(flakyInstance(0)))
    check recovers(Ca) == 1
    check recovers(flakyInstance(0)) == 1
    e.reportFailure(flakyInstance(0))
    check waitUntil(
      proc(): bool =
        e.state(flakyInstance(0)) == msError
    )
    sleep(int(ms(300)))
    check recovers(flakyInstance(0)) == 1
    rt.finish()

  test "docs/HOST-CONFIG.md carries the module's configuration schema verbatim":
    let doc = readFile(repo / "docs" / "HOST-CONFIG.md")
    check (
      "```cddl\n" & readFile(repo / "src/logos_core/orchestration/config.cddl") & "```"
    ) in doc
