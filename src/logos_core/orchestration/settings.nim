## The reference orchestration module's configuration (DECISIONS I94; RUNTIME
## l.183, l.194, l.746-751, l.3786-3790; CONFIG l.52-53, l.132, l.142).
##
## The value is `lcn_orchestrator.config` (`config.cddl`). The kit checks it
## against the schema before `initModule`; `settingsOf` then checks what the
## schema does not say [IMPL]: the bounds of each number, unique instances, the
## ordering graph (no self-edge, no duplicate, no cycle), and an authority that
## is not the Module Loader. A violation fails the orchestration start with
## MODULE_ERROR and the rule's text (G190).
##
## For a host (4b-6): `OrchestratorSettings` is the typed value,
## `validateSettings` the same checks, `encodeSettings` its deterministic CBOR
## for `provisioned_configuration` (G141), and `orchestratorDeclaration` the
## `configuration_declaration` with the package default (decision 8): a host
## that provisions nothing gets it through CONFIG's ordinary selection.

{.push raises: [], gcsafe.}

import std/[sets, tables]
import results
import ../loader/contract
import ../runtime/rc_types
import ./[lcn_orchestrator_kit, policy]

export results, lcn_orchestrator_configuration_types, policy

const
  OrchestratorModule* = "lcn_orchestrator" ## [I94] P1: the module's name
  OrchestratorBinding* = "lcn_orchestrator"
    ## [I94] P1: the `direct_static` binding a host registers
  ConfigDocument* = staticRead("config.cddl")
    ## the schema text, the same bytes the kit's roots were recomputed from
  ConfigRoot* = "lcn_orchestrator.config"
  MaxDefaults* = 4096 ## [IMPL] bounds the schema does not state
  MaxOrdering* = 16384
  MaxOverrides* = 4096
  MaxInstanceBytes* = 128
  MaxModuleBytes* = 64
  MinInitialMs* = 1'i64
  MaxInitialMs* = 3_600_000'i64
  MaxMaxMs* = 86_400_000'i64
  MaxMultiplier* = 16'i64
  MaxAttemptsLimit* = 1_000_000'i64
  MaxStableMs* = 86_400_000'i64
  MinResyncMs* = 10'i64
  MaxResyncMs* = 3_600_000'i64

type
  OrchestratorSettings* = LcnOrchestratorConfig
    ## [I94] P4: the module's configuration value, as a host builds it

  Target* = object
    module*, instance*: string

  StartDefault* = object
    module*, instance*: string
    kind*: DefaultKind

  Settings* = object ## A checked value, in the form the worker uses.
    authority*: Opt[Target]
    defaults*: seq[StartDefault] ## the authority first, then the listed ones
    defaultIndex*: Table[string, int]
    prerequisites*: Table[string, seq[string]] ## dependent → prerequisites
    dependents*: Table[string, seq[string]] ## prerequisite → dependents
    order*: seq[string]
      ## the instances `ordering` names, prerequisites before dependents
    restart*: Restart
    overrides*: Table[string, Restart]
    resyncMs*: int64

func textOk(s: string, maxBytes: int): bool =
  s.len >= 1 and s.len <= maxBytes

proc restartOf(r: LcnOrchestratorRestart, where: string): Result[Restart, string] =
  case r.kind
  of LcnOrchestratorRestartKind.Disabled:
    ok(disabledRestart())
  of LcnOrchestratorRestartKind.Backoff:
    let b = r.arm_Backoff
    let initial = int64(b.initial_delay_ms)
    let maxMs = int64(b.max_delay_ms)
    let mult = int64(b.multiplier)
    let stable = int64(b.stable_ms)
    if initial < MinInitialMs or initial > MaxInitialMs:
      return err(where & ".initial_delay_ms must be 1..3600000")
    if maxMs < initial or maxMs > MaxMaxMs:
      return err(where & ".max_delay_ms must be initial_delay_ms..86400000")
    if mult < 1 or mult > MaxMultiplier:
      return err(where & ".multiplier must be 1..16")
    if stable < 0 or stable > MaxStableMs:
      return err(where & ".stable_ms must be 0..86400000")
    var attempts = 0'i64
    if b.max_attempts.isSome:
      attempts = int64(b.max_attempts.get)
      if attempts < 1 or attempts > MaxAttemptsLimit:
        return err(where & ".max_attempts must be 1..1000000")
    ok(
      Restart(
        enabled: true,
        backoff: Backoff(
          initialMs: initial,
          maxMs: maxMs,
          multiplier: mult,
          maxAttempts: attempts,
          stableMs: stable,
        ),
      )
    )

proc topological(
    pairs: seq[(string, string)], nodes: seq[string]
): Result[seq[string], string] =
  ## [IMPL] Kahn's order over `(prerequisite, dependent)` pairs, ties broken by
  ## first appearance, so the order is the same on every start.
  var indegree = initTable[string, int]()
  var outs = initTable[string, seq[string]]()
  for n in nodes:
    indegree[n] = 0
  for (pre, dep) in pairs:
    indegree.mgetOrPut(dep, 0) += 1
    outs.mgetOrPut(pre, @[]).add(dep)
  var queue: seq[string]
  for n in nodes:
    if indegree.getOrDefault(n) == 0:
      queue.add(n)
  var i = 0
  while i < queue.len:
    let n = queue[i]
    inc i
    for d in outs.getOrDefault(n):
      indegree[d] = indegree.getOrDefault(d) - 1
      if indegree.getOrDefault(d) == 0:
        queue.add(d)
  if queue.len < nodes.len:
    for n in nodes:
      if indegree.getOrDefault(n) > 0:
        return err("ordering has a cycle through " & n)
  ok(queue)

proc settingsOf*(c: OrchestratorSettings): Result[Settings, string] =
  ## [IMPL; I94] The checked form of a value, or the first rule it breaks.
  var s = Settings(restart: packageRestart(), resyncMs: DefaultResyncMs)
  if c.authority.isSome:
    let a = c.authority.get
    if not a.module.textOk(MaxModuleBytes) or not a.instance.textOk(MaxInstanceBytes):
      return err("authority names an invalid module or instance")
    if a.instance == LoaderInstanceId:
      return err(
        "authority cannot be the Module Loader: it is established only by the " &
          "Runtime's bootstrap"
      )
    s.authority = Opt.some(Target(module: a.module, instance: a.instance))
    s.defaultIndex[a.instance] = 0
    s.defaults.add(
      StartDefault(module: a.module, instance: a.instance, kind: defaultStart)
    )
  if c.defaults.isSome:
    let ds = c.defaults.get
    if ds.len > MaxDefaults:
      return err("defaults has more than 4096 entries")
    var seen = initHashSet[string]()
    for d in ds:
      if not d.module.textOk(MaxModuleBytes) or not d.instance.textOk(MaxInstanceBytes):
        return err("defaults names an invalid module or instance")
      if seen.containsOrIncl(d.instance):
        return err("defaults lists " & d.instance & " twice")
      let kind =
        if d.action.isSome and
            d.action.get.kind == LcnOrchestratorDefaultActionChoiceKind.Stop:
          defaultStop
        else:
          defaultStart
      if s.authority.isSome and d.instance == s.authority.get.instance:
        if kind == defaultStop or d.module != s.authority.get.module:
          return err("defaults contradicts authority for " & d.instance)
        continue
      s.defaultIndex[d.instance] = s.defaults.len
      s.defaults.add(StartDefault(module: d.module, instance: d.instance, kind: kind))
  if c.ordering.isSome:
    let os = c.ordering.get
    if os.len > MaxOrdering:
      return err("ordering has more than 16384 pairs")
    var seen = initHashSet[(string, string)]()
    var nodes: seq[string]
    var known = initHashSet[string]()
    var pairs: seq[(string, string)]
    for o in os:
      if not o.dependent.textOk(MaxInstanceBytes) or
          not o.prerequisite.textOk(MaxInstanceBytes):
        return err("ordering names an invalid instance")
      if o.dependent == o.prerequisite:
        return err("ordering makes " & o.dependent & " its own prerequisite")
      if seen.containsOrIncl((o.prerequisite, o.dependent)):
        return
          err("ordering lists " & o.prerequisite & " before " & o.dependent & " twice")
      for n in [o.prerequisite, o.dependent]:
        if not known.containsOrIncl(n):
          nodes.add(n)
      pairs.add((o.prerequisite, o.dependent))
      s.prerequisites.mgetOrPut(o.dependent, @[]).add(o.prerequisite)
      s.dependents.mgetOrPut(o.prerequisite, @[]).add(o.dependent)
    s.order = ?topological(pairs, nodes)
  if c.restart.isSome:
    s.restart = ?restartOf(c.restart.get, "restart")
  if c.overrides.isSome:
    let ov = c.overrides.get
    if ov.len > MaxOverrides:
      return err("overrides has more than 4096 entries")
    for o in ov:
      if not o.instance.textOk(MaxInstanceBytes):
        return err("overrides names an invalid instance")
      if o.instance in s.overrides:
        return err("overrides lists " & o.instance & " twice")
      s.overrides[o.instance] = ?restartOf(o.restart, "overrides[" & o.instance & "]")
  if c.resync_ms.isSome:
    let r = int64(c.resync_ms.get)
    if r < MinResyncMs or r > MaxResyncMs:
      return err("resync_ms must be 10..3600000")
    s.resyncMs = r
  ok(s)

proc validateSettings*(c: OrchestratorSettings): Result[void, string] =
  ## [I94] P4: the checks `initModule` makes, for a host's early errors.
  discard ?settingsOf(c)
  ok()

proc encodeSettings*(c: OrchestratorSettings): Result[seq[byte], string] =
  ## [I94] P4: the value's deterministic CBOR, checked against the schema,
  ## for `provisioned_configuration`.
  ?validateSettings(c)
  encode(c)

func restartFor*(s: Settings, instance: string): Restart =
  ## The instance's override, or the value's policy.
  s.overrides.getOrDefault(instance, s.restart)

func defaultFor*(s: Settings, instance: string): DefaultKind =
  let i = s.defaultIndex.getOrDefault(instance, -1)
  if i < 0:
    defaultNone
  else:
    s.defaults[i].kind

func needsStateDir*(s: Settings): bool =
  ## [SPEC RUNTIME l.3789] Some policy is enabled: the accounting must survive.
  if s.restart.enabled:
    return true
  for r in s.overrides.values:
    if r.enabled:
      return true
  false

proc packageDefault*(): OrchestratorSettings =
  ## [D8; I94] The package default: only the restart policy.
  OrchestratorSettings(
    restart: Opt.some(
      LcnOrchestratorRestart(
        kind: LcnOrchestratorRestartKind.Backoff,
        arm_Backoff: LcnOrchestratorRestartARBackoffMap(
          initial_delay_ms: uint32(PackageInitialMs),
          max_delay_ms: uint32(PackageMaxMs),
          multiplier: uint32(PackageMultiplier),
          max_attempts: Opt.some(uint32(PackageMaxAttempts)),
          stable_ms: uint32(PackageStableMs),
        ),
      )
    )
  )

proc orchestratorDeclaration*(): Result[seq[byte], string] =
  ## [I94] P3: the `configuration_declaration` a host gives the module's
  ## instance: the schema binding of `config.cddl` (its roots recomputed by
  ## lcn-gen from the text) and the package default.
  let default = ?encode(packageDefault())
  encode(
    LogosNSModuleConfigurationConfigurationDeclaration(
      schema: LogosNSModuleConfigurationSchemaBinding(
        document: ConfigDocument,
        root: ConfigRoot,
        schema_commitment: LogosNSModuleConfigurationSchemaCommitment(
          schema_root: @(configurationRoots.schemaRoot),
          schema_subtree_root: @(configurationRoots.subtreeRoot),
        ),
      ),
      default_value: Opt.some(default),
    )
  )

{.pop.}
