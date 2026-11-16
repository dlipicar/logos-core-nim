## `logos-core-nim.daemon-config.v1`: logosd's protected deployment input
## (Tier 4b step 4b-6; DECISIONS G293; U1). Its schema is `daemon_config.cddl`
## (generated codecs in `daemon_config_types.nim`); `docs/DAEMON.md` §3
## documents it (BCP l.359).
##
## The checks here are the first four of DAEMON.md §3, in order; each failure
## names the field. The fifth, the derived host configuration passing the
## library's own checks, is `compose.prepareDaemon`. Nothing here starts a
## thread or runs module code; check 4 reads the evidence key file.

{.push raises: [].}

import std/[os, sets]
import results
import ../cbor
import ../loader/contract
from ../runtime/authscopes import AuthorityModule
from ../orchestration/settings import OrchestratorModule
import ./[daemon_config_types, evkey, session, trustfile]

export results, daemon_config_types

const
  DaemonConfigFormat* = "logos-core-nim.daemon-config.v1"
  HooksBuild* = defined(lcnTestHooks)
    ## [G300] This build holds test hooks; a packaged logosd never does.
  OrchestratorInstance* = "orchestrator" ## [G294] the system instances' fixed ids
  AuthorityInstance* = "authority"
  CtlInstance* = "logosctl"
  CtlModule* = "logosctl" ## [G53] the logosctl module's name and binding
  CtlBinding* = "logosctl"
  ReservedInstances* =
    [OrchestratorInstance, AuthorityInstance, CtlInstance, LoaderInstanceId]
  ReservedModules* = [LoaderModuleName, AuthorityModule, CtlModule, OrchestratorModule]
  CtlMethods* = [
    "get_self", "list_modules", "list_routes", "get_readiness", "get_execution_summary",
    "get_permission_settings", "get_configuration_schema", "get_configuration_summary",
    "get_configuration", "update_configuration", "apply_configuration", "create_module",
    "start_module", "stop_module", "recover_module", "retire_module", "shutdown_runtime",
  ] ## [D13(a); decision 9; G296] what the logosctl instance may call
  DefaultWorkers* = 4
  MaxWorkers* = 32
  DefaultIdleTimeoutMs* = 30_000
  MinIdleTimeoutMs* = 100
  MaxIdleTimeoutMs* = 600_000
  DefaultStoreRecords* = 1_000_000 ## [G143; G301]
  MaxStoreRecords* = 100_000_000
  DefaultStoreAgeDays* = 30
  MaxStoreAgeDays* = 3650
  DefaultStoreQueue* = 4096 ## [U6]
  MinStoreQueue* = 16
  MaxStoreQueue* = 1_048_576

type
  CtlSettings* = object ## [G296] the logosctl instance's socket
    socketDir*: string ## empty: `run/`
    workers*: int
    idleTimeoutMs*: int

  StoreSettings* = object ## [G301] the call-evidence store
    maxRecords*: int
    maxAgeDays*: int
    queue*: int

  HookSelection* = object ## [G300] what `test_hooks` selects, in a hook build
    ctlCommandDelayMs*: Opt[uint32]
    loaderFailureAfterMs*: Opt[uint32]
    loaderFailureOnFile*: Opt[string] ## once this file exists
    diagnostics*: Opt[LcnDcTestDiagnostics] ## [I95 amended 2026-11-16]

  DaemonConfig* = object ## A decoded daemon-config that passed checks 1 to 4.
    value*: LcnDaemonConfig
    ctl*: CtlSettings
    store*: Opt[StoreSettings]
    hooks*: HookSelection

func isReservedInstance*(id: string): bool =
  id in ReservedInstances

func isReservedModule*(name: string): bool =
  name in ReservedModules

proc decodeDaemonConfig*(bytes: openArray[byte]): Result[LcnDaemonConfig, string] =
  ## Check 1: one deterministic-CBOR value, nothing after it, matching the
  ## schema, within 64 MiB.
  if bytes.len > MaxConfigBytes:
    return err("the daemon configuration is larger than 64 MiB")
  let v = decodeCbor(bytes).valueOr:
    return err("the daemon configuration is not deterministic CBOR: " & $error)
  let dc = LcnDaemonConfig.fromCbor(v).valueOr:
    return err("the daemon configuration does not match lcn.daemon_config: " & error)
  ok(dc)

proc readDaemonConfig*(s: Session): Result[(LcnDaemonConfig, seq[byte]), string] =
  ## `daemon-config.cbor`, decoded (check 1), with its bytes.
  let bytes = ?readSessionFile(s.configPath)
  if bytes.isNone:
    return err(s.dir & " has no " & DaemonConfigName & ": run logosctl init")
  let dc = ?decodeDaemonConfig(bytes.get)
  ok((dc, bytes.get))

func isStatic(i: LcnAppImplementation): bool =
  i.kind == LcnAppImplementationKind.Direct_static

proc checkNames(dc: LcnDaemonConfig): Result[void, string] =
  ## Check 2: reserved names and strategies.
  var operator = initHashSet[string]()
  for m in dc.modules.get(@[]):
    let what = "modules: instance " & m.instance
    if m.instance.isReservedInstance:
      return err(what & " uses a reserved instance id")
    if m.module.isReservedModule:
      return err(what & " uses the reserved module name " & m.module)
    if m.implementation.isStatic:
      # [G293] logosd registers no operator binding.
      return err(
        what &
          " is direct_static; logosd hosts operator modules as direct_dynamic or hosted_dynamic"
      )
    operator.incl(m.instance)
  for d in dc.declarations.get(@[]):
    let what = "declarations: module " & d.module
    if d.module.isReservedModule:
      return err(what & " uses a reserved module name")
    if d.implementation.isStatic:
      return err(
        what &
          " is direct_static; logosd hosts operator modules as direct_dynamic or hosted_dynamic"
      )
  for o in dc.ordering.get(@[]):
    for id in [o.prerequisite, o.dependent]:
      if id notin operator:
        return err("ordering: " & id & " is not an operator instance in modules")
  var sources = initHashSet[string]()
  for t in dc.state_transfers.get(@[]):
    # [I96; G306] A transfer is between operator instances: logosd's own
    # (and the Loader) keep their state where they are.
    for id in [t.`from`, t.to]:
      if id.isReservedInstance:
        return err(
          "state_transfers: " & t.`from` & " to " & t.to & " names the system instance " &
            id
        )
    sources.incl(t.`from`)
  if dc.orchestration.isSome:
    let o = dc.orchestration.get
    var seen = initHashSet[string]()
    for id in o.start.get(@[]):
      if id in sources:
        # [I96] The transfer retires its source at this start.
        return err(
          "orchestration.start: " & id & " is a state_transfers source, retired at start"
        )
      if id notin operator:
        return
          err("orchestration.start: " & id & " is not an operator instance in modules")
      if seen.containsOrIncl(id):
        return err("orchestration.start lists " & id & " twice")
    for v in o.overrides.get(@[]):
      if v.instance notin operator and v.instance notin [CtlInstance, AuthorityInstance]:
        return err(
          "orchestration.overrides: " & v.instance &
            " is neither an operator instance nor logosctl or authority"
        )
  if dc.permissions.isSome and dc.permissions.get.initial.isSome:
    for e in dc.permissions.get.initial.get:
      if e.module.isReservedModule or e.instance.get("").isReservedInstance:
        return err(
          "permissions.initial: an entry names a system instance or module " &
            "(logosd provisions those itself)"
        )
  ok()

proc checkGates(
    dc: LcnDaemonConfig, trust: TrustInput, hooksBuild: bool
): Result[HookSelection, string] =
  ## Check 3: what the development switch gates (decision 11; D27; G300).
  let development = trust.file.development
  if dc.policy.kind == LcnDcPolicyKind.Allow_all and not development:
    return err(
      "policy: allow-all needs the development switch (logosctl trust development on)"
    )
  var hooks = HookSelection()
  if dc.test_hooks.isSome:
    if not hooksBuild:
      return err("test_hooks: this logosd has no test hooks")
    if not development:
      return err("test_hooks: needs the development switch")
    hooks.ctlCommandDelayMs = dc.test_hooks.get.ctl_command_delay_ms
    hooks.loaderFailureAfterMs = dc.test_hooks.get.loader_failure_after_ms
    hooks.loaderFailureOnFile = dc.test_hooks.get.loader_failure_on_file
    hooks.diagnostics = dc.test_hooks.get.diagnostics
  ok(hooks)

proc checkCtl(dc: LcnDaemonConfig): Result[CtlSettings, string] =
  var c = CtlSettings(workers: DefaultWorkers, idleTimeoutMs: DefaultIdleTimeoutMs)
  if dc.ctl.isNone:
    return ok(c)
  let x = dc.ctl.get
  if x.socket_dir.isSome:
    if not isAbsolute(x.socket_dir.get):
      return err("ctl.socket_dir must be an absolute path")
    c.socketDir = x.socket_dir.get
  if x.workers.isSome:
    let w = int(x.workers.get)
    if w < 1 or w > MaxWorkers:
      return err("ctl.workers must be 1 to 32")
    c.workers = w
  if x.idle_timeout_ms.isSome:
    let t = int(x.idle_timeout_ms.get)
    if t < MinIdleTimeoutMs or t > MaxIdleTimeoutMs:
      return err("ctl.idle_timeout_ms must be 100 to 600000")
    c.idleTimeoutMs = t
  ok(c)

proc checkAudit(
    dc: LcnDaemonConfig, checkKey: bool
): Result[Opt[StoreSettings], string] =
  ## Check 4: the evidence store needs the key; the key, its kid and the
  ## Runtime id match the binding (batch E 19).
  if dc.call_audit.isNone:
    return ok(Opt.none(StoreSettings))
  let a = dc.call_audit.get
  if a.evidence.isSome and checkKey:
    let e = a.evidence.get
    checkEvidenceKey(e.secret_key_file, e.kid, dc.runtime.runtime_instance_id).isOkOr:
      return err("call_audit.evidence: " & error)
  if a.store.isNone:
    return ok(Opt.none(StoreSettings))
  if a.evidence.isNone:
    return err("call_audit.store needs call_audit.evidence")
  let s = a.store.get
  var r = StoreSettings(
    maxRecords: DefaultStoreRecords,
    maxAgeDays: DefaultStoreAgeDays,
    queue: DefaultStoreQueue,
  )
  if s.max_records.isSome:
    r.maxRecords = int(s.max_records.get)
    if r.maxRecords < 1 or r.maxRecords > MaxStoreRecords:
      return err("call_audit.store.max_records must be 1 to 100000000")
  if s.max_age_days.isSome:
    r.maxAgeDays = int(s.max_age_days.get)
    if r.maxAgeDays < 1 or r.maxAgeDays > MaxStoreAgeDays:
      return err("call_audit.store.max_age_days must be 1 to 3650")
  if s.queue.isSome:
    r.queue = int(s.queue.get)
    if r.queue < MinStoreQueue or r.queue > MaxStoreQueue:
      return err("call_audit.store.queue must be 16 to 1048576")
  ok(Opt.some(r))

proc checkDaemonConfig*(
    dc: LcnDaemonConfig, trust: TrustInput, hooksBuild = HooksBuild, checkKey = true
): Result[DaemonConfig, string] =
  ## Checks 2 to 4 of DAEMON.md §3 on a decoded value. `hooksBuild` is this
  ## build's: a test passes `false` to check a packaged logosd's refusal.
  ## `checkKey` false skips reading the key file, for a value checked before
  ## its key exists (`logosctl init`).
  ?checkNames(dc)
  let hooks = ?checkGates(dc, trust, hooksBuild)
  let ctl = ?checkCtl(dc)
  let store = ?checkAudit(dc, checkKey)
  ok(DaemonConfig(value: dc, ctl: ctl, store: store, hooks: hooks))

{.pop.}
