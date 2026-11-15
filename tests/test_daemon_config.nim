## logosd's daemon-config and its session (Tier 4b step 4b-6; DECISIONS
## G293-G295, G297, G299, G300, G303; docs/DAEMON.md §2-§9): the schema rules
## of `daemon_config.cddl` and `trust.cddl`; DAEMON.md §3's checks, in order;
## the derived host configuration for three daemon-configs through the
## library's own checks; the system rules S1-S5 decided by the Capability
## Authority's own evaluator; the trust file's continuity table; the evidence
## key's binding and rotation; and `logosctl init`'s session. No logosd
## process and no Runtime: those are `test_logosd` (6b).

import std/[os, sequtils, strutils]
import unittest2
import ../src/logos_core/cbor
import ../src/logos_core/base/hex
import ../src/logos_core/crypto/blake3
import
  ../src/logos_core/daemon/
    [compose, daemon_config_types, evkey, session, sessioninit, trust_types, trustfile]
import ../src/logos_core/runtime/authz
from ../src/logos_core/runtime/authscopes import evaluateRequest, AuthorityModule
from ../src/logos_core/permissions import PermissionSetting, HostAmbient, profileV1
from ../src/logos_core/loader/contract import LoaderInstanceId, LoaderModuleName
from ../src/logos_core/orchestration/settings import OrchestratorModule
import ../src/logos_core/base/clock
from ../src/logos_core/durable import release
import ./support/[authfixture, kitbuild, schemasuite]

let work =
  currentSourcePath().parentDir.parentDir / "build" / "daemon-config" / kitVariant
removeDir(work)
createDir(work)

var dirs = 0

proc freshDir(prefix = "s"): string =
  ## An absolute path under `work` that does not exist yet.
  inc dirs
  work / (prefix & $dirs)

proc freshSession(): Session =
  let s = Session(dir: freshDir())
  check createLayout(s).isOk
  s

# Values ---------------------------------------------------------------------------

const
  Zero32 = "h'" & repeat("00", 32) & "'"
  CaPolicy = """{"kind": "capability-authority", "source": "test", "rules": []}"""

proc dcBytes(diag: string): seq[byte] =
  encodeCbor(parseDiag(diag).expect("diagnostic notation"))

proc dcOf(diag: string): LcnDaemonConfig =
  decodeDaemonConfig(dcBytes(diag)).expect("a daemon-config")

proc dcText(policy = CaPolicy, extra = ""): string =
  ## A daemon-config for Runtime `rt-1` with `policy` and `extra` fields.
  "{\"format\": \"logos-core-nim.daemon-config.v1\", " &
    "\"runtime\": {\"runtime_instance_id\": \"rt-1\"}, \"policy\": " & policy &
    (if extra.len > 0: ", " & extra else: "") & "}"

proc hostedModule(instance: string, module = "svc"): string =
  "{\"instance\": \"" & instance & "\", \"module\": \"" & module &
    "\", \"implementation\": {\"strategy\": \"hosted_dynamic\", \"placement\": \"process\", " &
    "\"artifact\": {\"id\": \"" & module & "\", \"local_path\": \"/opt/" & module &
    "/lib" & module & ".so\", \"hash\": " & Zero32 &
    ", \"hash_suite\": \"logos.hash-suite.blake3-256\"}}}"

proc staticModule(instance, module: string): string =
  "{\"instance\": \"" & instance & "\", \"module\": \"" & module &
    "\", \"implementation\": {\"strategy\": \"direct_static\", \"binding\": \"b\"}}"

let
  prod = TrustInput(file: floorFile()) ## the floor: switch off
  dev = TrustInput(file: LcnTrustFile(revision: 2, development: true))

proc checked(
    diag: string, trust = prod, hooksBuild = true
): Result[DaemonConfig, string] =
  checkDaemonConfig(dcOf(diag), trust, hooksBuild, checkKey = true)

proc refusal(diag: string, trust = prod, hooksBuild = true): string =
  let r = checked(diag, trust, hooksBuild)
  if r.isOk: "" else: r.error

# dc.schema --------------------------------------------------------------------------

const
  DcRules = [
    "lcn.daemon_config", "lcn.dc_runtime", "lcn.dc_policy", "lcn.dc_orchestration",
    "lcn.dc_restart", "lcn.dc_override", "lcn.dc_call_audit", "lcn.dc_evidence_store",
    "lcn.dc_permissions", "lcn.dc_ctl", "lcn.dc_test_hooks",
  ]
  TrustRules = ["lcn.trust_file", "lcn.trust_mark", "lcn.ev_key_binding"]

let
  dcModel = ruleModel(daemonConfigDocuments())
  dcCodec = codecTable("Lcn", DcRules)
  trustModel = ruleModel(trustDocuments())
  trustCodec = codecTable("Lcn", TrustRules)

func ownRule(name: string): bool =
  name == "lcn.daemon_config" or name.startsWith("lcn.dc_")

template holds(model: RuleModel, codec: untyped, name: string) =
  let problems = model.checkRule(name, codec)
  for p in problems:
    checkpoint name & ": " & p
  check problems.len == 0

suite "dc.schema: daemon_config.cddl and trust.cddl [IMPL-DECISION G293] [IMPL-DECISION G299]":
  test "every rule of the two schemas has its test here, and each generated type round-trips":
    for r in dcModel.names:
      if r.ownRule:
        checkpoint r
        check r in DcRules
    for r in DcRules:
      checkpoint r
      check r in dcModel.names
      check dcCodec(r, dcModel.samples(r)[0]).isSome
    check trustModel.names.len == TrustRules.len
    for r in TrustRules:
      checkpoint r
      check r in trustModel.names
      check trustCodec(r, trustModel.samples(r)[0]).isSome

  for r in DcRules:
    test r:
      holds(dcModel, dcCodec, r)

  for r in TrustRules:
    test r:
      holds(trustModel, trustCodec, r)

  test "a daemon-config's diagnostic text and its deterministic CBOR round-trip":
    let text = dcText(
      extra =
        "\"modules\": [" & hostedModule("svc") &
        "], \"orchestration\": {\"start\": [\"svc\"], \"restart\": {\"kind\": \"disabled\"}}, " &
        "\"ctl\": {\"workers\": 2}"
    )
    let bytes = dcBytes(text)
    let dc = dcOf(text)
    check dc.encode.get == bytes
    check encodeCbor(parseDiag(decodeCbor(bytes).get.toDiag).get) == bytes

# dc.checks --------------------------------------------------------------------------

suite "dc.checks: DAEMON.md §3, checks 1 to 4 [IMPL-DECISION G293] [IMPL-DECISION G300]":
  test "check 1: one deterministic-CBOR lcn.daemon_config within 64 MiB":
    check decodeDaemonConfig(dcBytes(dcText())).isOk
    var trailing = dcBytes(dcText())
    trailing.add(0x00)
    check "not deterministic CBOR" in decodeDaemonConfig(trailing).error
    check "not deterministic CBOR" in decodeDaemonConfig([0xFF'u8]).error
    let unknown = dcBytes(dcText(extra = "\"other\": 1"))
    check "does not match lcn.daemon_config" in decodeDaemonConfig(unknown).error
    let format = dcBytes(dcText().replace("daemon-config.v1", "daemon-config.v2"))
    check "does not match lcn.daemon_config" in decodeDaemonConfig(format).error
    let noId = dcBytes(
      "{\"format\": \"logos-core-nim.daemon-config.v1\", \"runtime\": {}, \"policy\": " &
        CaPolicy & "}"
    )
    check "does not match lcn.daemon_config" in decodeDaemonConfig(noId).error
    let big = newSeq[byte](MaxConfigBytes + 1)
    check decodeDaemonConfig(big).error ==
      "the daemon configuration is larger than 64 MiB"

  test "check 2: reserved instance ids and module names, and no direct_static operator module":
    check checked(dcText(extra = "\"modules\": [" & hostedModule("svc") & "]")).isOk
    for id in [OrchestratorInstance, AuthorityInstance, CtlInstance, LoaderInstanceId]:
      checkpoint id
      check refusal(dcText(extra = "\"modules\": [" & hostedModule(id) & "]")) ==
        "modules: instance " & id & " uses a reserved instance id"
    for m in [LoaderModuleName, AuthorityModule, CtlModule, OrchestratorModule]:
      checkpoint m
      check refusal(dcText(extra = "\"modules\": [" & hostedModule("x", m) & "]")) ==
        "modules: instance x uses the reserved module name " & m
    check "is direct_static" in
      refusal(dcText(extra = "\"modules\": [" & staticModule("x", "svc") & "]"))
    let decl =
      "{\"module\": \"svc\", \"implementation\": {\"strategy\": \"direct_static\", \"binding\": \"b\"}}"
    check "declarations: module svc is direct_static" in
      refusal(dcText(extra = "\"declarations\": [" & decl & "]"))
    let reservedDecl = decl.replace("\"svc\"", "\"logosctl\"")
    check refusal(dcText(extra = "\"declarations\": [" & reservedDecl & "]")) ==
      "declarations: module logosctl uses a reserved module name"

  test "check 2: ordering and orchestration.start name operator instances; overrides may name logosctl and authority; initial settings never name a system instance":
    let mods = "\"modules\": [" & hostedModule("a") & ", " & hostedModule("b") & "]"
    check checked(
      dcText(
        extra =
          mods & ", \"ordering\": [{\"prerequisite\": \"a\", \"dependent\": \"b\"}]"
      )
    ).isOk
    check refusal(
      dcText(
        extra =
          mods &
          ", \"ordering\": [{\"prerequisite\": \"authority\", \"dependent\": \"b\"}]"
      )
    ) == "ordering: authority is not an operator instance in modules"
    check refusal(dcText(extra = mods & ", \"orchestration\": {\"start\": [\"c\"]}")) ==
      "orchestration.start: c is not an operator instance in modules"
    check refusal(
      dcText(extra = mods & ", \"orchestration\": {\"start\": [\"a\", \"a\"]}")
    ) == "orchestration.start lists a twice"
    const off = "{\"kind\": \"disabled\"}"
    for id in ["a", CtlInstance, AuthorityInstance]:
      checkpoint id
      check checked(
        dcText(
          extra =
            mods & ", \"orchestration\": {\"overrides\": [{\"instance\": \"" & id &
            "\", \"restart\": " & off & "}]}"
        )
      ).isOk
    check "orchestration.overrides: orchestrator is neither" in
      refusal(
        dcText(
          extra =
            mods &
            ", \"orchestration\": {\"overrides\": [{\"instance\": \"orchestrator\", \"restart\": " &
            off & "}]}"
        )
      )
    let ambient =
      "{\"permission\": \"logos-core-nim.host-ambient\", \"constraints\": h'a0'}"
    check checked(
      dcText(
        extra =
          mods &
          ", \"permissions\": {\"initial\": [{\"module\": \"svc\", \"permissions\": [" &
          ambient & "]}]}"
      )
    ).isOk
    for (m, i) in [
      ("logosctl", ""), ("svc", "logosctl"), ("svc", "logos_module_loader")
    ]:
      checkpoint m & "/" & i
      let inst = (if i.len > 0: ", \"instance\": \"" & i & "\"" else: "")
      check "permissions.initial: an entry names a system instance or module" in
        refusal(
          dcText(
            extra =
              mods & ", \"permissions\": {\"initial\": [{\"module\": \"" & m & "\"" &
              inst & ", \"permissions\": [" & ambient & "]}]}"
          )
        )

  test "check 3: allow-all needs the development switch":
    let allowAll = dcText(policy = "{\"kind\": \"allow-all\"}")
    check refusal(allowAll) ==
      "policy: allow-all needs the development switch (logosctl trust development on)"
    check checked(allowAll, dev).isOk

  test "[IMPL-DECISION G300] check 3: test_hooks needs a hook build and the development switch, and selects in-process hooks":
    let hooks = dcText(
      extra =
        "\"test_hooks\": {\"ctl_command_delay_ms\": 50, \"loader_failure_after_ms\": 200}"
    )
    check refusal(hooks, dev, hooksBuild = false) ==
      "test_hooks: this logosd has no test hooks"
    check refusal(hooks, prod, hooksBuild = false) ==
      "test_hooks: this logosd has no test hooks"
    check refusal(hooks, prod, hooksBuild = true) ==
      "test_hooks: needs the development switch"
    let c = checked(hooks, dev, hooksBuild = true).get
    check c.hooks.ctlCommandDelayMs == Opt.some(50'u32)
    check c.hooks.loaderFailureAfterMs == Opt.some(200'u32)
    let none = checked(dcText(), dev, hooksBuild = true).get
    check none.hooks.ctlCommandDelayMs.isNone and none.hooks.loaderFailureAfterMs.isNone
    check HooksBuild # tests are built with lcnTestHooks

  test "[IMPL-DECISION G293] ctl: the socket directory is absolute; workers 1 to 32; idle timeout 100 to 600000 ms":
    let d = checked(dcText()).get
    check d.ctl.socketDir == "" and d.ctl.workers == DefaultWorkers and
      d.ctl.idleTimeoutMs == DefaultIdleTimeoutMs
    let c = checked(
      dcText(
        extra =
          "\"ctl\": {\"socket_dir\": \"/run/logos\", \"workers\": 32, \"idle_timeout_ms\": 100}"
      )
    ).get
    check c.ctl.socketDir == "/run/logos" and c.ctl.workers == 32 and
      c.ctl.idleTimeoutMs == 100
    check refusal(dcText(extra = "\"ctl\": {\"socket_dir\": \"run\"}")) ==
      "ctl.socket_dir must be an absolute path"
    check refusal(dcText(extra = "\"ctl\": {\"workers\": 0}")) ==
      "ctl.workers must be 1 to 32"
    check refusal(dcText(extra = "\"ctl\": {\"workers\": 33}")) ==
      "ctl.workers must be 1 to 32"
    check refusal(dcText(extra = "\"ctl\": {\"idle_timeout_ms\": 99}")) ==
      "ctl.idle_timeout_ms must be 100 to 600000"
    check refusal(dcText(extra = "\"ctl\": {\"idle_timeout_ms\": 600001}")) ==
      "ctl.idle_timeout_ms must be 100 to 600000"

  test "[IMPL-DECISION G293] [batch E 19] check 4: the store needs the evidence key, whose kid and Runtime match its binding; the store's bounds":
    let s = freshSession()
    let k = createEvidenceKey(s.keysDir, "rt-1").get
    let evidence =
      "\"evidence\": {\"kid\": h'" & k.binding.kid.toHex & "', \"secret_key_file\": \"" &
      k.keyFile & "\"}"
    check checked(dcText(extra = "\"call_audit\": {" & evidence & "}")).get.store.isNone
    let st =
      checked(dcText(extra = "\"call_audit\": {" & evidence & ", \"store\": {}}")).get
    check st.store.get ==
      StoreSettings(
        maxRecords: DefaultStoreRecords,
        maxAgeDays: DefaultStoreAgeDays,
        queue: DefaultStoreQueue,
      )
    check refusal(dcText(extra = "\"call_audit\": {\"store\": {}}")) ==
      "call_audit.store needs call_audit.evidence"
    check checked(dcText(extra = "\"call_audit\": {\"call_records\": 10}")).get.store.isNone
    for (field, value) in [
      ("max_records", "0"),
      ("max_records", "100000001"),
      ("max_age_days", "0"),
      ("max_age_days", "3651"),
      ("queue", "15"),
      ("queue", "1048577"),
    ]:
      checkpoint field & " " & value
      check refusal(
        dcText(
          extra =
            "\"call_audit\": {" & evidence & ", \"store\": {\"" & field & "\": " & value &
            "}}"
        )
      )
        .startsWith("call_audit.store." & field & " must be ")
    let bounds = checked(
      dcText(
        extra =
          "\"call_audit\": {" & evidence &
          ", \"store\": {\"max_records\": 100000000, \"max_age_days\": 3650, \"queue\": 16}}"
      )
    ).get
    check bounds.store.get ==
      StoreSettings(maxRecords: 100_000_000, maxAgeDays: 3650, queue: 16)
    # Another Runtime's key, a kid that is not the key's, a missing key.
    let other =
      dcText(extra = "\"call_audit\": {" & evidence & "}").replace("rt-1", "rt-2")
    check refusal(other) ==
      "call_audit.evidence: the evidence key belongs to Runtime rt-1, not to Runtime rt-2"
    var wrongKid = k.binding.kid
    wrongKid[0] = wrongKid[0] xor 1
    check refusal(
      dcText(
        extra =
          "\"call_audit\": {\"evidence\": {\"kid\": h'" & wrongKid.toHex &
          "', \"secret_key_file\": \"" & k.keyFile & "\"}}"
      )
    ) == "call_audit.evidence: call_audit.evidence.kid does not match the evidence key"
    check refusal(
      dcText(
        extra =
          "\"call_audit\": {" & evidence.replace(k.keyFile, s.keysDir / "none.key") & "}"
      )
    )
      .startsWith("call_audit.evidence: ")
    # `checkKey` false reads no key (init checks its value before the key exists).
    check checkDaemonConfig(dcOf(other), prod, checkKey = false).isOk

  test "the checks run in order: the first failing one is reported":
    let both = dcText(
      policy = "{\"kind\": \"allow-all\"}",
      extra =
        "\"modules\": [" & hostedModule("logosctl") & "], \"ctl\": {\"workers\": 0}",
    )
    check refusal(both) == "modules: instance logosctl uses a reserved instance id"
    let gateAndCtl =
      dcText(policy = "{\"kind\": \"allow-all\"}", extra = "\"ctl\": {\"workers\": 0}")
    check refusal(gateAndCtl).startsWith("policy: allow-all needs")
    let ctlAndStore =
      dcText(extra = "\"ctl\": {\"workers\": 0}, \"call_audit\": {\"store\": {}}")
    check refusal(ctlAndStore) == "ctl.workers must be 1 to 32"

# dc.compose -------------------------------------------------------------------------

proc entryFor(c: Composition, module: string, instance = ""): seq[string] =
  ## The permissions of the initial settings for `module` and `instance`.
  for e in c.appConfig.permissions.get.initial.get:
    if e.module == module and e.instance.get("") == instance:
      for p in e.permissions:
        result.add(p.permission & "=" & p.constraints.toHex)

suite "dc.compose: the derived host configuration [IMPL-DECISION G294] [IMPL-DECISION G295]":
  test "init's default: the system instances, the layout's paths, the reference profile, host-ambient for each":
    let s = Session(dir: freshDir())
    let dc = defaultDaemonConfig("rt-1")
    let p = prepareDaemon(s, dc.encode.get, prod).get
    let app = p.composition.appConfig
    check app.modules.mapIt(it.instance) ==
      @[OrchestratorInstance, CtlInstance, AuthorityInstance]
    check app.modules.mapIt(it.module) ==
      @[OrchestratorModule, CtlModule, AuthorityModule]
    check app.orchestration == OrchestratorInstance
    check app.runtime.work_dir == s.workDir
    check app.runtime.state_root == Opt.some(s.modulesDir)
    check app.runtime.store_dir == Opt.some(s.storeDir)
    check app.runtime.endpoint_dir == Opt.some(s.endpointDir)
    check app.runtime.runtime_instance_id == Opt.some("rt-1")
    check app.runtime.module_host.isNone
    check app.modules[0].state_assignment == Opt.some(OrchestratorState)
    check app.modules[2].state_assignment == Opt.some(AuthorityState)
    check app.modules[1].state_assignment.isNone
    check app.policy.kind == LcnAppPolicyKind.Capability_authority
    let ca = app.policy.arm_Capability_authority
    check ca.authority == AuthorityInstance and ca.recovery == Opt.some(true)
    check ca.policy.source == DefaultPolicySource and ca.policy.format == PolicyFormat
    check app.permissions.get.profile == PermissionProfileId
    let ambient = @[HostAmbient & "=a0"]
    check p.composition.entryFor(OrchestratorModule, OrchestratorInstance) == ambient
    check p.composition.entryFor(CtlModule, CtlInstance) == ambient
    check p.composition.entryFor(AuthorityModule, AuthorityInstance) == ambient
    check app.call_audit.isNone
    # The orchestration value: the authority, then logosctl, started.
    let o = p.composition.orchestrator
    check o.authority.get.instance == AuthorityInstance
    check o.defaults.get.mapIt(it.instance) == @[CtlInstance]
    check p.composition.bytes == app.encode.get

  test "allow-all under the development switch: no authority instance, no policy":
    let s = Session(dir: freshDir())
    let p =
      prepareDaemon(s, dcBytes(dcText(policy = "{\"kind\": \"allow-all\"}")), dev).get
    let app = p.composition.appConfig
    check app.modules.mapIt(it.instance) == @[OrchestratorInstance, CtlInstance]
    check app.policy.kind == LcnAppPolicyKind.Allow_all
    check p.composition.orchestrator.authority.isNone
    check p.composition.entryFor(AuthorityModule, AuthorityInstance).len == 0

  test "an operator deployment: hosted modules, their module-level host-ambient, ordering, the start list, restart and audit":
    let s = freshSession()
    let k = createEvidenceKey(s.keysDir, "rt-1").get
    let host = getAppFilename()
    let text = dcText(
        extra =
          "\"modules\": [" & hostedModule("a") & ", " & hostedModule("b", "other") &
          "], \"ordering\": [{\"prerequisite\": \"a\", \"dependent\": \"b\"}], " &
          "\"orchestration\": {\"start\": [\"a\", \"b\"], \"restart\": {\"kind\": \"backoff\", " &
          "\"initial_delay_ms\": 100, \"max_delay_ms\": 1000, \"multiplier\": 2, \"stable_ms\": 5000}, " &
          "\"overrides\": [{\"instance\": \"logosctl\", \"restart\": {\"kind\": \"disabled\"}}], \"resync_ms\": 2000}, " &
          "\"permissions\": {\"initial\": [{\"module\": \"other\", \"permissions\": [{\"permission\": \"logos-core-nim.host-ambient\", \"constraints\": h'a0'}]}]}, " &
          "\"call_audit\": {\"call_records\": 64, \"evidence\": {\"kid\": h'" &
          k.binding.kid.toHex & "', \"secret_key_file\": \"" & k.keyFile &
          "\"}, \"store\": {}}"
      )
      .replace(
        "{\"runtime_instance_id\": \"rt-1\"}",
        "{\"runtime_instance_id\": \"rt-1\", \"module_host\": \"" & host & "\"}",
      )
    let p = prepareDaemon(s, dcBytes(text), prod).get
    let app = p.composition.appConfig
    check app.modules.mapIt(it.instance) ==
      @[OrchestratorInstance, CtlInstance, AuthorityInstance, "a", "b"]
    check app.runtime.module_host == Opt.some(host)
    check app.ordering.get.mapIt(it.prerequisite & ">" & it.dependent) == @["a>b"]
    check p.composition.entryFor("svc") == @[HostAmbient & "=a0"] # added (G280)
    check p.composition.entryFor("other") ==
      @[HostAmbient & "=a0"] # the operator's, once
    check app.call_audit.get.call_records == Opt.some(64'u32)
    check app.call_audit.get.evidence.get.kid == k.binding.kid
    let o = p.composition.orchestrator
    check o.defaults.get.mapIt(it.instance & ":" & it.module) ==
      @[CtlInstance & ":" & CtlModule, "a:svc", "b:other"]
    check o.ordering.get.len == 1 and o.resync_ms == Opt.some(2000'u32)
    check o.restart.isSome and o.overrides.get.len == 1
    check p.config.store.isSome

  test "the fifth check: a derived configuration the library refuses is reported as such":
    let s = Session(dir: freshDir())
    let missing = dcText().replace(
        "{\"runtime_instance_id\": \"rt-1\"}",
        "{\"runtime_instance_id\": \"rt-1\", \"module_host\": \"" & work / "no-host" &
          "\"}",
      )
    check prepareDaemon(s, dcBytes(missing), prod).error ==
      "the derived host configuration is refused: module_host does not exist"
    # A check 1-4 failure is reported before composition.
    check prepareDaemon(s, dcBytes(dcText(policy = "{\"kind\": \"allow-all\"}")), prod).error
      .startsWith("policy: allow-all needs")

  test "[IMPL-DECISION G294] the default module_host: libexec beside the resolved executable, else a sibling, else none":
    let root = freshDir("mh")
    createDir(root / "bin")
    createDir(root / "libexec" / "logos-core")
    writeFile(root / "bin" / "logosd", "")
    let libexec = root / "libexec" / "logos-core" / ModuleHostName
    writeFile(libexec, "")
    createDir(root / "profile")
    createSymlink(root / "bin" / "logosd", root / "profile" / "logosd")
    check defaultModuleHost("") == Opt.none(string)
    let viaLink = defaultModuleHost(root / "profile" / "logosd")
    check viaLink.isSome and
      viaLink.get.endsWith("/libexec/logos-core/" & ModuleHostName)
    check sameFile(viaLink.get, libexec)
    removeFile(libexec)
    check defaultModuleHost(root / "bin" / "logosd").isNone
    writeFile(root / "bin" / ModuleHostName, "")
    let sibling = defaultModuleHost(root / "profile" / "logosd")
    check sibling.isSome and sameFile(sibling.get, root / "bin" / ModuleHostName)

# dc.policy --------------------------------------------------------------------------

proc moduleOf(instance: string): string =
  case instance
  of OrchestratorInstance: OrchestratorModule
  of CtlInstance: CtlModule
  of AuthorityInstance: AuthorityModule
  of LoaderInstanceId: LoaderModuleName
  else: "svc"

proc daemonFacts(): SharedFacts =
  result = newSharedFacts(Rt)
  for id in [
    OrchestratorInstance, CtlInstance, AuthorityInstance, LoaderInstanceId, "a", "b",
    "c",
  ]:
    doAssert result.putInstance(id, InstanceFacts(module: moduleOf(id))).isOk

proc rcReq(consumer, operation: string, target = ""): AuthzRequest =
  ## A Runtime Control request as the engine asks it: a lifecycle or an
  ## observation of one instance, a list over the whole scope, or a
  ## Runtime-wide method.
  const
    lifecycle = [
      "start_module", "stop_module", "recover_module", "retire_module",
      "update_configuration", "apply_configuration",
    ]
    lists = ["list_modules", "list_routes", "list_remote_listeners"]
    runtimeWide = ["shutdown_runtime"]
  if operation in lifecycle:
    AuthzRequest(
      action: aaLifecycle,
      operation: operation,
      consumer: consumer,
      target: target,
      instance: target,
      module: moduleOf(target),
    )
  elif operation in lists:
    AuthzRequest(
      action: aaObserve, operation: operation, consumer: consumer, filters: true
    )
  elif operation in runtimeWide:
    AuthzRequest(action: aaRuntimeControl, operation: operation, consumer: consumer)
  else:
    AuthzRequest(
      action: aaObserve,
      operation: operation,
      consumer: consumer,
      target: target,
      instance: target,
      module: moduleOf(target),
    )

proc execReq(consumer, target: string, stop = false, hosted = false): AuthzRequest =
  ## An execution as the engine asks it under the reference profile: a start
  ## carries the instance's saved host-ambient setting.
  AuthzRequest(
    action: (if stop: aaStop else: aaExecute),
    operation: (if stop: "stop_module" else: "start_module"),
    consumer: consumer,
    target: target,
    instance: target,
    module: moduleOf(target),
    hosted: hosted,
    permissions:
      if stop:
        @[]
      else:
        @[PermissionSetting(permission: HostAmbient, constraints: @[0xA0'u8])],
  )

proc eventReq(consumer, event: string): AuthzRequest =
  AuthzRequest(
    action: aaObserveEvent, operation: event, consumer: consumer, filters: true
  )

type PolicyEnv = object
  facts: SharedFacts
  clock: Clock
  sink: ChannelSink
  a: Authority

proc openPolicy(diag: string): PolicyEnv =
  let dc = dcOf(diag)
  let orch = orchestratorValue(dc).expect("an orchestration value")
  let policy = mergedPolicy(dc.policy.arm_Capability_authority, orch).expect("a policy")
  let dir = freshDir("ca")
  privateDir(dir)
  result.facts = daemonFacts()
  result.clock = newTestClock()
  result.sink = newChannelSink()
  result.a = openTest(
    dir,
    policy.encode.get,
    result.facts,
    result.clock,
    result.sink.sink,
    profile = profileV1,
  )

proc close(e: var PolicyEnv) =
  closeAuthority(e.a)
  freeChannelSink(e.sink)
  freeClock(e.clock)
  freeSharedFacts(e.facts)

proc allows(e: PolicyEnv, q: AuthzRequest): bool =
  let req = evaluateRequest(q, Rt).expect("an evaluate request")
  let r = e.a.evaluate(systemCaller(), req)
  doAssert r.kind == LogosNSCapabilityAuthorityEvaluateResponseKind.Map_decision,
    "not a decision"
  r.arm_Map_decision.decision.result.kind ==
    LogosNSCapabilityAuthorityDecisionResultKind.Allow

const OperatorRules =
  """[{"kind": "allow", "subject": {"instances": ["a"]}, "scopes": [{"kind": "runtime-control", "methods": ["list_modules"]}]},
        {"kind": "allow", "subject": {"instances": ["logosctl"]}, "scopes": [{"kind": "runtime-control", "methods": ["stop_module"]}, {"kind": "module-execution", "targets": {}, "actions": ["stop"]}]}]"""

proc policyText(): string =
  dcText(
    policy =
      "{\"kind\": \"capability-authority\", \"source\": \"test\", \"rules\": " &
      OperatorRules & "}",
    extra =
      "\"modules\": [" & hostedModule("a") & ", " & hostedModule("b") & ", " &
      hostedModule("c") & "], \"orchestration\": {\"start\": [\"a\", \"b\"]}",
  )

suite "dc.policy: the system rules S1 to S5, decided by the Capability Authority [IMPL-DECISION G295]":
  test "S3 and S4: logosctl's Runtime Control and executions, never against the bootstrap services or itself":
    var e = openPolicy(policyText())
    for m in [
      "list_modules", "list_routes", "get_readiness", "get_configuration",
      "get_permission_settings",
    ]:
      checkpoint m
      check e.allows(rcReq(CtlInstance, m, "a"))
    check e.allows(rcReq(CtlInstance, "shutdown_runtime"))
    for m in [
      "start_module", "stop_module", "recover_module", "retire_module",
      "update_configuration", "apply_configuration",
    ]:
      checkpoint m
      check e.allows(rcReq(CtlInstance, m, "a"))
      for target in [LoaderInstanceId, AuthorityInstance, CtlInstance]:
        checkpoint m & " " & target
        check not e.allows(rcReq(CtlInstance, m, target))
    check e.allows(execReq(CtlInstance, "c"))
    check e.allows(execReq(CtlInstance, "c", hosted = true))
    check e.allows(execReq(CtlInstance, "c", stop = true))
    for target in [LoaderInstanceId, AuthorityInstance, CtlInstance]:
      checkpoint target
      check not e.allows(execReq(CtlInstance, target))
      check not e.allows(execReq(CtlInstance, target, stop = true))
    # Not in the shell's method set; no event subscription.
    check not e.allows(rcReq(CtlInstance, "list_remote_listeners"))
    check not e.allows(eventReq(CtlInstance, "module_state_changed"))
    e.close()

  test "S5: orchestration is restored only by recover_module and configured only by daemon-config":
    var e = openPolicy(policyText())
    check e.allows(rcReq(CtlInstance, "recover_module", OrchestratorInstance))
    check e.allows(rcReq(CtlInstance, "get_configuration", OrchestratorInstance))
    for m in [
      "start_module", "stop_module", "retire_module", "update_configuration",
      "apply_configuration",
    ]:
      checkpoint m
      check not e.allows(rcReq(CtlInstance, m, OrchestratorInstance))
    check not e.allows(execReq(CtlInstance, OrchestratorInstance, stop = true))
    e.close()

  test "[DECISIONS I94 P5] S2: the orchestration module's calls and events, and the executions it originates":
    var e = openPolicy(policyText())
    check e.allows(rcReq(OrchestratorInstance, "list_modules"))
    check e.allows(rcReq(OrchestratorInstance, "get_readiness", "c"))
    check e.allows(rcReq(OrchestratorInstance, "recover_module", "c"))
    check e.allows(rcReq(OrchestratorInstance, "start_module", "a"))
    check not e.allows(rcReq(OrchestratorInstance, "stop_module", "a"))
      # no stop defaults
    check not e.allows(rcReq(OrchestratorInstance, "shutdown_runtime"))
    for ev in [
      "module_state_changed", "execution_state_changed", "inventory_changed",
      "configuration_state_changed", "permission_settings_changed",
    ]:
      checkpoint ev
      check e.allows(eventReq(OrchestratorInstance, ev))
    check not e.allows(eventReq(OrchestratorInstance, "route_state_changed"))
    for target in ["a", "b", CtlInstance, AuthorityInstance]:
      checkpoint target
      check e.allows(execReq(OrchestratorInstance, target))
      check e.allows(execReq(OrchestratorInstance, target, hosted = true))
    check not e.allows(execReq(OrchestratorInstance, "c")) # not in its start list
    check not e.allows(execReq(OrchestratorInstance, "a", stop = true))
    e.close()

  test "operator rules: what they allow, and deny over allow for the system rules":
    var e = openPolicy(policyText())
    check e.allows(rcReq("a", "list_modules"))
    check not e.allows(rcReq("b", "list_modules"))
    check not e.allows(rcReq("a", "stop_module", "b"))
    # The operator's allow of stop_module for logosctl does not reach S4's targets.
    check e.allows(rcReq(CtlInstance, "stop_module", "b"))
    check not e.allows(rcReq(CtlInstance, "stop_module", AuthorityInstance))
    check not e.allows(execReq(CtlInstance, AuthorityInstance, stop = true))
    e.close()

  test "the merged policy: every array a set, the system rules first-class, init's policy loadable":
    let dc = defaultDaemonConfig("rt-1")
    let orch = orchestratorValue(dc).get
    let p = mergedPolicy(dc.policy.arm_Capability_authority, orch).get
    let bytes = p.encode.get
    check encodeCbor(decodeCbor(bytes).get) == bytes
    check p.rules.len == systemRules(orch).get.len
    check p.source == DefaultPolicySource
    var e = openPolicy(dcText())
    check e.allows(rcReq(CtlInstance, "list_modules"))
    e.close()

# dc.trust ---------------------------------------------------------------------------

proc input(revision: uint64, development: bool): TrustInput =
  let f = LcnTrustFile(revision: revision, development: development)
  TrustInput(file: f, digest: @(blake3(f.encode.get)), present: true)

proc markOf(t: TrustInput): Opt[LcnTrustMark] =
  Opt.some(LcnTrustMark(revision: t.file.revision, digest: t.digest))

suite "dc.trust: the trust file's continuity [IMPL-DECISION G137] [IMPL-DECISION G299] [D27]":
  test "[PKG-0418] [PKG-0419] [PKG-0420] [PKG-0421] the decision table":
    let r2 = input(2, true)
    check decide(r2, Opt.none(LcnTrustMark)).error == NotEstablished
    check decide(r2, markOf(input(1, false))).get == cAdvance
    check decide(r2, markOf(r2)).get == cAccept
    let changed = decide(r2, markOf(input(2, false)))
    check changed.isErr and "other contents than the revision recorded" in changed.error
    let rollback = decide(input(1, false), markOf(r2))
    check rollback.error ==
      "the trust file's revision 1 is below the revision 2 already used: rollback is refused"

  test "without a file the compiled-in floor applies; a file below it is refused":
    let s = freshSession()
    let t = readTrust(s).get
    check not t.present and t.file.revision == FloorRevision and not t.file.development
    check establishTrust(s).error == NotEstablished # logosd never creates a mark
    check writeTrustFile(s, LcnTrustFile(revision: 0, development: false)).isOk
    check readTrust(s).error ==
      TrustName & " is below the compiled-in floor (revision 1)"

  test "init writes revision 1, or 2 with the switch, and its mark; a start accepts the identical replay":
    let s = freshSession()
    let t = initTrust(s, development = false).get
    check t.file.revision == 1 and not t.file.development and t.present
    check readMark(s).get.get.revision == 1
    check establishTrust(s).get.digest == t.digest
    let d = freshSession()
    let td = initTrust(d, development = true).get
    check td.file.revision == 2 and td.file.development
    check readMark(d).get.get.revision == 2

  test "[D27] the switch: each change is the next revision; the mark moves at the next start, before it is used":
    let s = freshSession()
    discard initTrust(s, development = false).get
    let on = setDevelopment(s, true).get
    check on.file.revision == 2 and on.file.development
    check readMark(s).get.get.revision == 1 # offline: the file only
    check establishTrust(s).get.file.development
    check readMark(s).get.get == LcnTrustMark(revision: 2, digest: on.digest)
    let off = setDevelopment(s, false).get # a withdrawal
    check off.file.revision == 3 and not off.file.development
    check not establishTrust(s).get.file.development
    check readMark(s).get.get.revision == 3

  test "a changed file at the same revision, and a rollback, are refused; reestablish names the file's revision":
    let s = freshSession()
    discard initTrust(s, development = false).get
    discard setDevelopment(s, true).get
    discard establishTrust(s).get
    check writeTrustFile(s, LcnTrustFile(revision: 2, development: false)).isOk
    check "other contents" in establishTrust(s).error
    check writeTrustFile(s, LcnTrustFile(revision: 1, development: false)).isOk
    check "rollback is refused" in establishTrust(s).error
    check reestablish(s, 2).error == "the trust file is at revision 1, not 2"
    check reestablish(s, 1).isOk
    check establishTrust(s).isOk
    check readMark(s).get.get.revision == 1

  test "the trust file is a private regular file: group access or a link is refused":
    let s = freshSession()
    discard initTrust(s, development = false).get
    setFilePermissions(s.trustPath, {fpUserRead, fpUserWrite, fpGroupRead})
    check "accessible to group or other" in readTrust(s).error
    removeFile(s.trustPath)
    let elsewhere = freshDir("t")
    createDir(elsewhere)
    writeFile(elsewhere / "trust.cbor", "")
    setFilePermissions(elsewhere / "trust.cbor", {fpUserRead, fpUserWrite})
    createSymlink(elsewhere / "trust.cbor", s.trustPath)
    check "is not a regular file" in readTrust(s).error

# dc.keys ----------------------------------------------------------------------------

suite "dc.keys: the evidence key and its binding to one Runtime [IMPL-DECISION G149] [batch E 19]":
  test "a new key: the secret file 0600, its kid from the public key, its binding":
    let s = freshSession()
    let k = createEvidenceKey(s.keysDir, "rt-1").get
    check k.binding.kid.len == KidBytes
    check k.binding.kid == @(blake3(k.binding.public_key).toOpenArray(0, KidBytes - 1))
    check k.binding.runtime_instance_id == "rt-1" and k.binding.retired_ms.isNone
    check k.keyFile == s.keysDir / keyFileName(k.binding.kid)
    check getFilePermissions(k.keyFile) == {fpUserRead, fpUserWrite}
    check readBinding(s.keysDir / bindingFileName(k.binding.kid)).get == k.binding
    check checkEvidenceKey(k.keyFile, k.binding.kid, "rt-1").isOk

  test "the key, its kid and the Runtime must match the binding":
    let s = freshSession()
    let k = createEvidenceKey(s.keysDir, "rt-1").get
    check checkEvidenceKey(k.keyFile, k.binding.kid, "rt-2").error ==
      "the evidence key belongs to Runtime rt-1, not to Runtime rt-2"
    var bad = k.binding.kid
    bad[^1] = bad[^1] xor 0x80
    check checkEvidenceKey(k.keyFile, bad, "rt-1").error ==
      "call_audit.evidence.kid does not match the evidence key"
    # A binding naming another public key.
    var tampered = k.binding
    tampered.public_key[0] = tampered.public_key[0] xor 1
    let path = s.keysDir / bindingFileName(k.binding.kid)
    removeFile(path)
    writeFile(path, cast[string](tampered.encode.get))
    check checkEvidenceKey(k.keyFile, k.binding.kid, "rt-1").error ==
      "the evidence key does not match its binding"
    removeFile(path)
    check "has no binding file" in
      checkEvidenceKey(k.keyFile, k.binding.kid, "rt-1").error

  test "rotation: a new key for the same Runtime; the old binding retired, its secret gone":
    let s = freshSession()
    let old = createEvidenceKey(s.keysDir, "rt-1").get
    check rotateEvidenceKey(s.keysDir, old.binding.kid, "rt-2").error ==
      "the current evidence key belongs to Runtime rt-1"
    let fresh = rotateEvidenceKey(s.keysDir, old.binding.kid, "rt-1").get
    check fresh.binding.kid != old.binding.kid
    check fresh.binding.runtime_instance_id == "rt-1"
    check not fileExists(old.keyFile)
    let retired = readBinding(s.keysDir / bindingFileName(old.binding.kid)).get
    check retired.retired_ms.isSome and retired.public_key == old.binding.public_key
    check checkEvidenceKey(fresh.keyFile, fresh.binding.kid, "rt-1").isOk
    let all = listEvidenceKeys(s.keysDir).get
    check all.len == 2
    check all.mapIt(it.binding.kid) == @[old.binding.kid, fresh.binding.kid] or
      all[0].binding.created_ms == all[1].binding.created_ms
    for x in all:
      if x.binding.kid == old.binding.kid:
        check x.keyFile == "" and x.binding.retired_ms.isSome
      else:
        check x.keyFile == fresh.keyFile

# dc.init ----------------------------------------------------------------------------

func isUuid4(s: string): bool =
  if s.len != 36:
    return false
  for i, c in s:
    if i in [8, 13, 18, 23]:
      if c != '-':
        return false
    elif c notin {'0' .. '9', 'a' .. 'f'}:
      return false
  s[14] == '4' and s[19] in {'8', '9', 'a', 'b'}

suite "dc.init: logosctl init's session [IMPL-DECISION G192] [batch E 19] [U8]":
  test "a new session: the layout owner-only, a fresh Runtime id, its key, revision 1, the default daemon-config":
    let s = Session(dir: freshDir())
    let r = initSession(s, InitOptions()).get
    check r.runtimeId.isUuid4
    for d in [
      s.dir, s.keysDir, s.stateDir, s.storeDir, s.modulesDir, s.evidenceDir, s.workDir
    ]:
      checkpoint d
      check getFilePermissions(d) == {fpUserRead, fpUserWrite, fpUserExec}
    check getFilePermissions(s.configPath) == {fpUserRead, fpUserWrite}
    check not dirExists(s.runDir) # made at each start
    let (dc, bytes) = readDaemonConfig(s).get
    check dc.runtime.runtime_instance_id == r.runtimeId
    check dc.policy.kind == LcnDcPolicyKind.Capability_authority
    let p = dc.policy.arm_Capability_authority
    check p.source == DefaultPolicySource and p.recovery == Opt.some(true) and
      p.rules.len == 0
    check dc.call_audit.isNone and dc.modules.isNone
    check r.key.binding.runtime_instance_id == r.runtimeId
    check checkEvidenceKey(r.key.keyFile, r.key.binding.kid, r.runtimeId).isOk
    check r.trust.file.revision == 1 and not r.trust.file.development
    check establishTrust(s).isOk
    check prepareDaemon(s, bytes, readTrust(s).get).isOk
    # Another session gets another Runtime id.
    let other = initSession(Session(dir: freshDir()), InitOptions()).get
    check other.runtimeId != r.runtimeId

  test "--development writes revision 2; --config's id is replaced; --module-config reaches the derived configuration":
    let s = Session(dir: freshDir())
    let cfg = dcOf(
      dcText(
        policy = "{\"kind\": \"allow-all\"}",
        extra = "\"modules\": [" & hostedModule("a") & "]",
      )
        .replace(
          "{\"runtime_instance_id\": \"rt-1\"}",
          "{\"runtime_instance_id\": \"rt-1\", \"module_host\": \"" & getAppFilename() &
            "\"}",
        )
    )
    let r = initSession(s, InitOptions(config: Opt.some(cfg), development: true)).get
    check r.trust.file.revision == 2 and r.trust.file.development
    let (dc, _) = readDaemonConfig(s).get
    check dc.runtime.runtime_instance_id == r.runtimeId and r.runtimeId != "rt-1"
    check dc.policy.kind == LcnDcPolicyKind.Allow_all
    check dc.modules.get[0].instance == "a"
    # A provisioned value is set on the instance, then checked as logosd
    # checks it: this module declares no configuration (G141).
    let p = Session(dir: freshDir())
    check initSession(
      p,
      InitOptions(
        config: Opt.some(cfg),
        development: true,
        moduleConfigs: @[("a", @[0xA1'u8, 0x01, 0x02])],
      ),
    ).error ==
      "the derived host configuration is refused: module instance a: provisioned_configuration needs configuration"
    check not dirExists(p.dir)

  test "a refused init leaves nothing behind; a session is made only once":
    let s = Session(dir: freshDir())
    let allowAll = dcOf(dcText(policy = "{\"kind\": \"allow-all\"}"))
    check initSession(s, InitOptions(config: Opt.some(allowAll))).error.startsWith(
      "policy: allow-all needs"
    )
    check not dirExists(s.dir)
    check initSession(s, InitOptions(moduleConfigs: @[("x", @[0xA0'u8])])).error ==
      "--module-config names no operator instance x"
    check not dirExists(s.dir)
    check initSession(s, InitOptions()).isOk
    check initSession(s, InitOptions()).error ==
      s.dir & " exists and is not empty; a session is made only once"
    check fileExists(s.configPath)
    # An operator's empty owner-only directory is accepted, and emptied again,
    # not removed, when init is refused; one group or other may access is not.
    let e = Session(dir: freshDir())
    createDir(e.dir)
    setFilePermissions(e.dir, {fpUserRead, fpUserWrite, fpUserExec})
    check initSession(e, InitOptions(config: Opt.some(allowAll))).isErr
    check dirExists(e.dir) and toSeq(walkDir(e.dir)).len == 0
    check initSession(e, InitOptions()).isOk
    let open = Session(dir: freshDir())
    createDir(open.dir)
    setFilePermissions(
      open.dir, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec}
    )
    check initSession(open, InitOptions()).error ==
      "the session directory is not usable: " & open.dir &
      " is accessible to group or other"
    check dirExists(open.dir) and toSeq(walkDir(open.dir)).len == 0

  test "the session lock: one holder at a time":
    let s = Session(dir: freshDir())
    discard initSession(s, InitOptions()).get
    var held = lockSession(s).get
    check lockSession(s).error == SessionBusy
    held.release()
    var again = lockSession(s).get
    again.release()

  test "[DECISIONS G88] the session directory: the flag, else LOGOSCTL_SESSION_DIR, else HOME/.logos-core; relative paths resolved":
    let savedEnv = getEnv(SessionEnv)
    let savedHome = getEnv("HOME")
    putEnv(SessionEnv, "/srv/logos")
    check resolveSession("/tmp/x").get.dir == "/tmp/x"
    check resolveSession().get.dir == "/srv/logos"
    delEnv(SessionEnv)
    putEnv("HOME", "/home/u")
    check resolveSession().get.dir == "/home/u/.logos-core"
    check resolveSession("rel/dir").get.dir == getCurrentDir() / "rel" / "dir"
    delEnv("HOME")
    check resolveSession().isErr
    putEnv("HOME", savedHome)
    if savedEnv.len > 0:
      putEnv(SessionEnv, savedEnv)

  test "run/ is emptied at each start without following a link; work/ is kept":
    let s = Session(dir: freshDir())
    discard initSession(s, InitOptions()).get
    check resetRunDir(s).isOk
    let outside = freshDir("o")
    createDir(outside)
    writeFile(outside / "keep", "x")
    writeFile(s.runDir / SocketName, "")
    createSymlink(outside, s.endpointDir / "link")
    writeFile(s.workDir / "restart.lock", "")
    check resetRunDir(s).isOk
    check fileExists(outside / "keep")
    check not fileExists(s.runDir / SocketName)
    check dirExists(s.endpointDir) and toSeq(walkDir(s.endpointDir)).len == 0
    check fileExists(s.workDir / "restart.lock")
    check getFilePermissions(s.runDir) == {fpUserRead, fpUserWrite, fpUserExec}
