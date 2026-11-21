## The Host Embedding API in process (RUNTIME §13; `runtime/host.nim`): the
## `logos-core-nim.app-config.v1` configuration (G76), the §13.1 version and
## size checks, the §13.4 call order, registration, the start path to the
## orchestration instance's `ready` (RUNTIME l.3838), shutdown, waiting and destruction,
## and Runtime Control `get_readiness`.

import std/[atomics, monotimes, os, sequtils, strutils, times, typedthreads, unicode]
import unittest2
import logos_sdk/cbor
import logos_sdk/abi/[host, types]
import logos_sdk/crypto/blake3
import logos_sdk/iface/outcome
from logos_sdk/kit/rc_arms import accepted, refusal
import
  ../src/logos_core/runtime/[engine, host, host_config, host_config_types],
  logos_sdk/kit/rc_types
from ../src/logos_core/runtime/authscopes import AuthorityModule, caRoots
from ../src/logos_core/loader/contract import LoaderInstanceId, LoaderModuleName
from ../src/logos_core/runtime/plumbing import
  LoaderFaults, StateTransfer, TransferMode, MaxTransferBytes
import ../src/logos_core/permissions
from ../src/logos_core/crypto/slhdsa import Seed, keyPairFromSeeds
from std/posix import Mode, chmod
from ../src/logos_core/transport/io/sock import unixStream
from ../src/logos_core/transport/framing import MinFrameLimit
import
  logos_sdk/testing/[kitbuild, tunerconfig],
  ./support/[permfixture, shortdir, slowdown, withoutloader]
import logos_sdk/testing/fixtures/meter_impl

let work = currentSourcePath().parentDir.parentDir / "build" / "host" / kitVariant
removeDir(work)
createDir(work)

# Configurations -------------------------------------------------------------------

proc staticModule(instance, module, binding: string): LcnAppModule =
  LcnAppModule(
    instance: instance,
    module: module,
    implementation: LcnAppImplementation(
      kind: LcnAppImplementationKind.Direct_static,
      arm_Direct_static: LcnAppImplementationARDirectStaticMap(binding: binding),
    ),
  )

proc baseConfig(): LcnAppConfig =
  LcnAppConfig(
    runtime: LcnAppRuntime(work_dir: work / "w"),
    policy: LcnAppPolicy(),
    orchestration: "orch",
    modules: @[
      staticModule("orch", "test_orchestrator", "orchestrator"),
      staticModule("meter-1", "meter_module", "meter"),
    ],
  )

proc parse(c: LcnAppConfig): Result[HostConfig, ConfigError] =
  ## The configuration encoded as it is, schema-valid or not.
  parseHostConfig(AppConfigFormat, encodeCbor(toCbor(c)))

proc parseValue(v: CborValue): Result[HostConfig, ConfigError] =
  parseHostConfig(AppConfigFormat, encodeCbor(v))

proc rejects(r: Result[HostConfig, ConfigError], fragment: string): bool =
  if r.isOk:
    checkpoint "accepted"
    return false
  checkpoint r.error.message
  fragment in r.error.message

proc withEntry(v: CborValue, key: string, x: CborValue): CborValue =
  ## `v` with one more map entry, keys kept in deterministic order.
  var entries = v.entries
  entries.add((cbor(key), x))
  cborMap(entries)

proc root(b: byte): SchemaCommitment =
  SchemaCommitment(schema_root: newSeqWith(32, b))

func rootOf(c: SchemaCommitment): Digest =
  for i in 0 ..< result.len:
    result[i] = c.schema_root[i]

proc authorityPolicy(source = "test"): LcnAuthorityPolicy =
  ## The smallest policy 8a loads: anyone may observe.
  LcnAuthorityPolicy.fromCbor(
    cborMap(
      (cbor("format"), cbor("logos-core-nim.authority-policy.v1")),
      (cbor("source"), cbor(source)),
      (
        cbor("rules"),
        cborArray(
          cborMap(
            (cbor("kind"), cbor("allow")),
            (cbor("subject"), cborMap()),
            (
              cbor("scopes"),
              cborArray(cborMap((cbor("kind"), cbor("runtime-control")))),
            ),
          )
        ),
      ),
    )
  ).tryGet

proc caConfig(): LcnAppConfig =
  ## `baseConfig` with a Capability Authority instance `ca` deciding.
  result = baseConfig()
  result.runtime.store_dir = Opt.some(work / "store")
  result.runtime.state_root = Opt.some(work / "state")
  var ca = staticModule("ca", AuthorityModule, "logos_capability_authority")
  ca.state_assignment = Opt.some("ca-state")
  result.modules.add(ca)
  result.policy = LcnAppPolicy(
    kind: LcnAppPolicyKind.Capability_authority,
    arm_Capability_authority:
      LcnAppPolicyARCapabilityAuthorityMap(authority: "ca", policy: authorityPolicy()),
  )

template authorityArm(c: LcnAppConfig): untyped =
  c.policy.arm_Capability_authority

proc decoded(c: LcnAppConfig): Result[HostConfig, ConfigError] =
  ## Every check, without the refusal of what is not built yet.
  decodeHostConfig(AppConfigFormat, encodeCbor(toCbor(c)))

suite "run.host-config: logos-core-nim.app-config.v1 (RUNTIME §13.3; G76)":
  test "[RUN-0260] [RUN-0741] a valid configuration decodes into records, in order, with the default deadlines":
    var c = baseConfig()
    c.modules[1].primary_contract = Opt.some(root(7))
    c.ordering = Opt.some(@[LcnAppOrdering(prerequisite: "orch", dependent: "meter-1")])
    let r = parseHostConfig(AppConfigFormat, c.encode.get)
    check r.isOk
    let h = r.get
    check h.workDir == work / "w"
    check h.stateRoot.isNone
    check h.orchestration == "orch"
    check h.modules.len == 2
    check h.modules[0].instance == "orch"
    check h.modules[0].record.module == "test_orchestrator"
    check h.modules[0].record.binding == "orchestrator"
    check h.modules[1].record.primaryContract.get[0] == 7
    check h.ordering == @[("orch", "meter-1")]
    check h.startupDeadline == DefaultStartupDeadline
    check h.stopDeadline == DefaultStopDeadline
    check h.shutdownGrace == DefaultShutdownGrace
    check h.applyDeadline == DefaultApplyDeadline

  test "[RUN-0741] an unsupported configuration format identifier is rejected":
    let bytes = baseConfig().encode.get
    for f in ["logos-core-nim.daemon-config.v1", "logos-core-nim.app-config.v2", "x"]:
      check parseHostConfig(f, bytes).rejects("unsupported configuration format")

  test "[RUN-0264] [RUN-0741] malformed and non-deterministic CBOR are rejected with their detail":
    let bad = parseHostConfig(AppConfigFormat, [0xff'u8])
    check bad.rejects("deterministic-CBOR")
    check bad.error.detail == Opt.some(invalidParamsDetail(iprMalformedCbor))
    var trailing = baseConfig().encode.get
    trailing.add(0x00)
    check parseHostConfig(AppConfigFormat, trailing).error.detail ==
      Opt.some(invalidParamsDetail(iprMalformedCbor))
    # 5 as a two-byte integer: well formed, not deterministic.
    let nd = parseHostConfig(AppConfigFormat, [0x18'u8, 0x05])
    check nd.rejects("deterministic-CBOR")
    check nd.error.detail == Opt.some(invalidParamsDetail(iprNonDeterministicCbor))
    # Schema failures carry a message only.
    check parseValue(cbor(5'u64)).error.detail.isNone

  test "[RUN-0741] unknown keys and values outside the schema are rejected":
    let v = toCbor(baseConfig())
    check parseValue(v.withEntry("zzz", cbor(1'u64))).rejects("lcn.app_config")
    var rt = toCbor(baseConfig().runtime)
    var cv = toCbor(baseConfig())
    for e in cv.entries.mitems:
      if e[0].text == "runtime":
        e[1] = rt.withEntry("zzz", cbor(true))
    check parseValue(cv).rejects("lcn.app_config")
    var c = baseConfig()
    c.modules[0].instance = ""
    check parse(c).rejects("lcn.app_config")
    c = baseConfig()
    c.modules[0].module = repeat('a', 65)
    check parse(c).rejects("lcn.app_config")

  test "[RUN-0741] [RUN-0267] present arrays are non-empty (RUNTIME §8 l.1357)":
    var c = baseConfig()
    c.modules = @[]
    check parse(c).rejects("modules is empty")
    c = baseConfig()
    c.ordering = Opt.some(newSeq[LcnAppOrdering]())
    check parse(c).rejects("ordering is present but empty")
    c = baseConfig()
    c.modules[1].implements = Opt.some(newSeq[SchemaCommitment]())
    check parse(c).rejects("implements is present but empty")
    c = baseConfig()
    c.modules[1].primary_contract = Opt.some(root(7))
    c.modules[1].extends = Opt.some(newSeq[SchemaCommitment]())
    check parse(c).rejects("extends is present but empty")
    c = baseConfig()
    c.modules[1].requires = Opt.some(newSeq[LcnAppRequirement]())
    check parse(c).rejects("requires is present but empty")
    c = baseConfig()
    c.modules[1].requested_permissions = Opt.some(newSeq[LcnAppPermission]())
    check parse(c).rejects("requested_permissions is present but empty")

  test "[RUN-1105] [TXT-0548] [TXT-0552] [G394] the expected contract facts are the input's, and each set is checked":
    # [TXT-0548] `primary_contract`, `implements` and `extends` are carried
    # into the record as the configuration states them, for an instance and
    # for a declaration.
    var c = baseConfig()
    c.modules[1].primary_contract = Opt.some(root(7))
    c.modules[1].implements = Opt.some(@[root(8)])
    c.modules[1].extends = Opt.some(@[root(9), root(10)])
    var decl = LcnAppDeclaration(
      module: "other_module",
      implementation: c.modules[1].implementation,
      primary_contract: Opt.some(root(11)),
      extends: Opt.some(@[root(12)]),
    )
    c.declarations = Opt.some(@[decl])
    let h = parse(c).get
    let r = h.modules[1].record
    check r.primaryContract == Opt.some(rootOf(root(7)))
    check r.implements == @[rootOf(root(8))]
    check r.extends == @[rootOf(root(9)), rootOf(root(10))]
    check h.declarations[0].record.extends == @[rootOf(root(12))]
    check h.declarations[0].record.implements.len == 0
    # [RUN-1105; G394 r10] Unique over `implements` and `extends` together.
    c = baseConfig()
    c.modules[1].primary_contract = Opt.some(root(7))
    c.modules[1].implements = Opt.some(@[root(8)])
    c.modules[1].extends = Opt.some(@[root(8)])
    check parse(c).rejects("an implemented or extended schema commitment repeats")
    # [G394 r11] `extends` needs a contract the module provides.
    c = baseConfig()
    c.modules[1].extends = Opt.some(@[root(9)])
    check parse(c).rejects("extends needs a primary_contract or implements")
    # [TXT-0552] Each `requires` entry names a distinct contract.
    c = baseConfig()
    c.modules[1].requires = Opt.some(
      @[
        LcnAppRequirement(
          contract: root(7),
          cardinality: LcnAppRequirementCardinalityChoice(
            kind: LcnAppRequirementCardinalityChoiceKind.Single
          ),
        ),
        LcnAppRequirement(
          contract: root(7),
          cardinality: LcnAppRequirementCardinalityChoice(
            kind: LcnAppRequirementCardinalityChoiceKind.All_runtime_visible
          ),
        ),
      ]
    )
    check parse(c).rejects("two requires entries name one contract")

  test "[S5] a policy kind other than allow-all is not supported yet":
    var cv = toCbor(baseConfig())
    for e in cv.entries.mitems:
      if e[0].text == "policy":
        e[1] = cborMap(@[(cbor("kind"), cbor("deny-all"))])
    check parseValue(cv).rejects("policy kind is not supported yet")

  test "[RUN-0304] [RUN-0305] [RUN-0018] [CAP-0003] [CAP-0006] [I85] a capability-authority policy names this library's Capability Authority instance and 8a's policy":
    let ok = caConfig().decoded
    check ok.isOk
    let a = ok.get.authority.get
    check a.instance == "ca"
    # [I88] The statically linked authority is a direct-mode instance whose
    # record declares the pinned contract, so it has a provider record.
    for m in ok.get.modules:
      if m.instance == "ca":
        check m.record.primaryContract.isSome
        check @(m.record.primaryContract.get) == caRoots().contract
    check a.evaluationDeadline == DefaultEvaluationDeadline
    check not a.recovery
    check ok.get.authorityPolicy == encodeCbor(toCbor(authorityPolicy()))
    check parse(caConfig()).isOk
    var c = caConfig()
    c.authorityArm.authority = "nobody"
    check c.decoded.rejects("policy.authority names no instance in modules")
    c = caConfig()
    c.authorityArm.authority = "meter-1"
    check c.decoded.rejects(
      "policy.authority's module is not logos_capability_authority"
    )
    # [IMPL] The library's own binding, wired in process.
    c = caConfig()
    c.modules[2] = staticModule("ca", AuthorityModule, "my_authority")
    c.modules[2].state_assignment = Opt.some("ca-state")
    check c.decoded.rejects(
      "policy.authority must be the direct_static binding logos_capability_authority"
    )
    c.modules[2].implementation = LcnAppImplementation(
      kind: LcnAppImplementationKind.Direct_dynamic,
      arm_Direct_dynamic: LcnAppImplementationARDirectDynamicMap(
        artifact: LcnAppArtifact(
          id: "ca", local_path: work / "libca.so", hash: newSeq[byte](32)
        )
      ),
    )
    check c.decoded.rejects(
      "policy.authority must be the direct_static binding logos_capability_authority"
    )
    c = caConfig()
    c.modules[2].primary_contract = Opt.some(root(7))
    check c.decoded.rejects("is not the pinned Capability Authority contract")
    c.modules[2].primary_contract =
      Opt.some(SchemaCommitment(schema_root: caRoots().contract))
    check c.decoded.isOk
    # [RUNTIME l.1637] The orchestration instance is never the authority.
    c = caConfig()
    c.orchestration = "ca"
    check c.decoded.rejects("reserved logos_ prefix")
    # [C8]
    c = caConfig()
    c.runtime.store_dir = Opt.none(string)
    check c.decoded.rejects("capability-authority needs store_dir")
    c = caConfig()
    c.modules[2].state_assignment = Opt.none(string)
    check c.decoded.rejects("the authority instance needs a state_assignment")
    c = caConfig()
    c.runtime.state_root = Opt.none(string)
    check c.decoded.rejects("capability-authority needs state_root")
    # The evaluation deadline: 1..60000, below the startup deadline (C34(a)).
    for ms in [0'u32, 60_001]:
      c = caConfig()
      c.authorityArm.evaluation_deadline_ms = Opt.some(ms)
      check c.decoded.rejects("evaluation_deadline_ms must be 1 to 60000 milliseconds")
    c = caConfig()
    c.runtime.startup_deadline_ms = Opt.some(5000'u32)
    check c.decoded.rejects("evaluation_deadline_ms must be below startup_deadline_ms")
    c.authorityArm.evaluation_deadline_ms = Opt.some(4999'u32)
    c.authorityArm.recovery = Opt.some(true)
    let short = c.decoded.get.authority.get
    check short.evaluationDeadline == initDuration(milliseconds = 4999)
    check short.recovery
    # The policy is checked as the authority will load it.
    c = caConfig()
    c.authorityArm.policy = authorityPolicy("Not A Source")
    check c.decoded.rejects("policy: source does not match")

  test "[I85] call_audit sets the record ring and the evidence key":
    var c = baseConfig()
    c.call_audit = Opt.some(LcnAppCallAudit())
    let ok = c.decoded
    check ok.isOk
    check ok.get.callAudit
    check ok.get.callRecords == DefaultCallRecords
    check ok.get.evidence.isNone
    check parse(c).isOk
    check baseConfig().decoded.get.callRecords == DefaultCallRecords
    check not baseConfig().decoded.get.callAudit
    for n in [0'u32, 1_000_001]:
      c.call_audit = Opt.some(LcnAppCallAudit(call_records: Opt.some(n)))
      check c.decoded.rejects("call_audit.call_records must be 1 to 1000000")
    c.call_audit = Opt.some(LcnAppCallAudit(call_records: Opt.some(7'u32)))
    check c.decoded.get.callRecords == 7
    let key = LcnAppEvidenceKey(kid: @[1'u8, 2], secret_key_file: "key")
    c.call_audit = Opt.some(LcnAppCallAudit(evidence: Opt.some(key)))
    check c.decoded.rejects(
      "call_audit.evidence.secret_key_file must be an absolute path"
    )
    c.call_audit.get.evidence.get.secret_key_file = work / "key"
    check c.decoded.rejects("call_audit.evidence needs store_dir")
    c.runtime.store_dir = Opt.some(work / "store")
    let e = c.decoded.get.evidence.get
    check e.kid == @[1'u8, 2]
    check e.secretKeyFile == work / "key"

  test "[RUN-0784] [RUN-0785] [G53] orchestration names a listed instance outside the logos_ prefix":
    var c = baseConfig()
    c.orchestration = "nobody"
    check parse(c).rejects("orchestration names no instance")
    c = baseConfig()
    c.modules[0].module = "logos_orchestrator"
    check parse(c).rejects("reserved logos_ prefix")
    # The module name does not matter otherwise: the role follows the instance.
    c = baseConfig()
    c.orchestration = "meter-1"
    check parse(c).get.orchestration == "meter-1"

  test "[LDR-0006] [IMPL-DECISION G246] no configuration names the Module Loader's instance, module or binding":
    var c = baseConfig()
    c.modules[1].instance = LoaderInstanceId
    check parse(c).rejects("names the reserved Module Loader")
    c = baseConfig()
    c.modules[1].module = LoaderModuleName
    check parse(c).rejects("names the reserved Module Loader")
    c = baseConfig()
    c.modules[1] = staticModule("meter-1", "meter_module", LoaderBindingId)
    check parse(c).rejects("names the reserved Module Loader")
    c = baseConfig()
    c.orchestration = LoaderInstanceId
    check parse(c).rejects("orchestration names the reserved Module Loader instance")

  test "[IMPL-DECISION G279] [IMPL-DECISION G110] [IMPL-DECISION G253] [I93] permissions: the shipped profile by name, and protected initial settings by module or by instance":
    let amb = LcnAppPermissionSetting(permission: HostAmbient, constraints: @[0xA0'u8])
    var c = baseConfig()
    # Absent: no profile, the constant form (G229).
    check c.decoded.get.permissions == nil
    c.permissions = Opt.some(LcnAppPermissions())
    # [Rev R3] Bootstrap starts the orchestration instance through the precheck.
    check c.decoded.rejects(
      "permissions.initial does not provision the orchestration instance with the profile's minimum"
    )
    c.permissions.get.initial = Opt.some(
      @[
        LcnAppInitialSettings(module: "test_orchestrator", permissions: @[amb]),
        LcnAppInitialSettings(
          module: "meter_module", instance: Opt.some("meter-1"), permissions: @[]
        ),
      ]
    )
    let h = c.decoded
    check h.isOk
    check parse(c).isOk
    check build(h.get.permissions).name == ProfileV1
    check h.get.initialSettings ==
      @[
        InitialSettings(module: "test_orchestrator", permissions: @[ambient()]),
        InitialSettings(module: "meter_module", instance: "meter-1"),
      ]
    # Only the shipped identifier is a profile.
    check parseValue(
      toCbor(baseConfig()).withEntry(
        "permissions", cborMap((cbor("profile"), cbor("lcn-test.profile.v1")))
      )
    ).isErr
    # Present arrays are non-empty.
    c.permissions.get.initial = Opt.some(newSeq[LcnAppInitialSettings]())
    check c.decoded.rejects("permissions.initial is present but empty")
    proc entries(xs: varargs[LcnAppInitialSettings]): LcnAppConfig =
      result = baseConfig()
      result.permissions = Opt.some(
        LcnAppPermissions(
          initial: Opt.some(
            @[LcnAppInitialSettings(module: "test_orchestrator", permissions: @[amb])] &
              @xs
          )
        )
      )

    let other =
      LcnAppPermissionSetting(permission: "lcn-test.quota", constraints: @[0xA0'u8])
    check entries(LcnAppInitialSettings(module: "meter_module", permissions: @[other])).decoded
      .rejects(
        "permissions.initial entry for module meter_module names a permission the profile does not define"
      )
    let bad = LcnAppPermissionSetting(permission: HostAmbient, constraints: @[0x01'u8])
    check entries(LcnAppInitialSettings(module: "meter_module", permissions: @[bad])).decoded
      .rejects("has constraints the permission does not admit")
    check entries(
      LcnAppInitialSettings(module: "meter_module", permissions: @[amb, amb])
    ).decoded
      .rejects("is not ascending by permission name")
    check entries(LcnAppInitialSettings(module: "test_orchestrator", permissions: @[])).decoded
      .rejects("permissions.initial entry for module test_orchestrator is listed twice")
    check entries(
      LcnAppInitialSettings(
        module: "test_orchestrator", instance: Opt.some("meter-1"), permissions: @[]
      )
    ).decoded
      .rejects("names an instance of another module")
    check entries(
      LcnAppInitialSettings(
        module: "meter_module", instance: Opt.some("meter-2"), permissions: @[]
      )
    ).decoded
      .rejects("names no instance in modules")
    check entries(LcnAppInitialSettings(module: LoaderModuleName, permissions: @[])).decoded
      .rejects("names the reserved Module Loader")
    check entries(
      LcnAppInitialSettings(
        module: "meter_module", instance: Opt.some(LoaderInstanceId), permissions: @[]
      )
    ).decoded
      .rejects("names the reserved Module Loader")
    # An instance entry overrides its module's: the orchestration instance
    # left without the minimum.
    check entries(
      LcnAppInitialSettings(
        module: "test_orchestrator", instance: Opt.some("orch"), permissions: @[]
      )
    ).decoded
      .rejects("does not provision the orchestration instance")

  test "[IMPL-DECISION G279] [I93] under capability-authority the authority instance is provisioned too, and the policy is loaded against the selected profile":
    let amb = LcnAppPermissionSetting(permission: HostAmbient, constraints: @[0xA0'u8])
    var c = caConfig()
    c.permissions = Opt.some(
      LcnAppPermissions(
        initial: Opt.some(
          @[LcnAppInitialSettings(module: "test_orchestrator", permissions: @[amb])]
        )
      )
    )
    check c.decoded.rejects(
      "permissions.initial does not provision the authority instance with the profile's minimum"
    )
    c.permissions.get.initial.get.add(
      LcnAppInitialSettings(module: AuthorityModule, permissions: @[amb])
    )
    check c.decoded.isOk
    # A rule naming host-ambient: loaded with the profile, refused without.
    var v = toCbor(authorityPolicy())
    var rules = v.entries
    for e in rules.mitems:
      if e[0].text == "rules":
        e[1] = cborArray(
          cborMap(
            (cbor("kind"), cbor("allow")),
            (cbor("subject"), cborMap()),
            (
              cbor("scopes"),
              cborArray(
                cborMap(
                  (cbor("kind"), cbor("permission")),
                  (cbor("permission"), cbor(HostAmbient)),
                )
              ),
            ),
          )
        )
    c.authorityArm.policy = LcnAuthorityPolicy.fromCbor(cborMap(rules)).tryGet
    check c.decoded.isOk
    c.permissions = Opt.none(LcnAppPermissions)
    check c.decoded.isErr

  test "records: each passes the RUNTIME §8 checks; ids and state assignments are unique":
    var c = baseConfig()
    c.modules[1].module = "Meter"
    check parse(c).rejects("module instance meter-1:")
    c = baseConfig()
    c.modules[1].instance = "orch"
    check parse(c).rejects("listed twice")
    c = baseConfig()
    c.modules[0].state_assignment = Opt.some("s1")
    c.modules[1].state_assignment = Opt.some("s1")
    check parse(c).rejects("share a state assignment")
    c = baseConfig()
    c.modules[1].state_assignment = Opt.some("..")
    check parse(c).rejects("state assignment")
    c = baseConfig()
    c.modules[1].requested_permissions = Opt.some(
      @[
        LcnAppPermission(permission: "p", constraints: @[0xa0'u8]),
        LcnAppPermission(permission: "p", constraints: @[0xa0'u8]),
      ]
    )
    check parse(c).rejects("repeats")
    c = baseConfig()
    c.modules[1].implements = Opt.some(@[root(1), root(1)])
    check parse(c).rejects("repeats")

  test "ordering names listed instances, without a self edge, a cycle or the orchestration instance as a dependent":
    proc ordered(pairs: openArray[(string, string)]): LcnAppConfig =
      result = baseConfig()
      result.modules.add(staticModule("meter-2", "meter_module", "meter"))
      var o: seq[LcnAppOrdering]
      for (p, d) in pairs:
        o.add(LcnAppOrdering(prerequisite: p, dependent: d))
      result.ordering = Opt.some(o)

    check parse(ordered([("meter-1", "ghost")])).rejects("not in modules")
    check parse(ordered([("meter-1", "meter-1")])).rejects("one instance twice")
    check parse(ordered([("meter-1", "meter-2"), ("meter-2", "meter-1")])).rejects(
      "cycle"
    )
    check parse(ordered([("meter-1", "orch")])).rejects("orchestration instance")
    check parse(ordered([("meter-1", "meter-2"), ("orch", "meter-2")])).isOk

  test "[IFC-0923] [IMPL-DECISION G241] max_payload_depth is 128 to 1024, 1024 when absent":
    check parse(baseConfig()).get.maxPayloadDepth == DefaultMaxDepth
    var c = baseConfig()
    for (d, ok) in [
      (127'u16, false), (128'u16, true), (1024'u16, true), (1025'u16, false)
    ]:
      c.runtime.max_payload_depth = Opt.some(d)
      if ok:
        check parse(c).get.maxPayloadDepth == int(d)
      else:
        check parse(c).rejects("max_payload_depth must be 128 to 1024")

  test "[RUN-0741] [IMPL-DECISION G254] routing: one rule per caller and callee, none for the Loader or as Runtime Control, local-transport only with unix-stream":
    proc rule(
        callee: string, direct = false, caller = Opt.none(string)
    ): LcnAppRoutingRule =
      LcnAppRoutingRule(
        callee: callee,
        caller: caller,
        mode: LcnAppRoutingRuleModeChoice(
          kind: (
            if direct: LcnAppRoutingRuleModeChoiceKind.Direct
            else: LcnAppRoutingRuleModeChoiceKind.Local_transport
          )
        ),
      )

    check parse(baseConfig()).get.routing.len == 0
    var c = baseConfig()
    c.routing = Opt.some(newSeq[LcnAppRoutingRule]())
    check parse(c).rejects("routing is present but empty")
    c.routing = Opt.some(
      @[
        rule("meter_module"),
        rule("meter_module", direct = true, Opt.some("test_orchestrator")),
      ]
    )
    when unixStream:
      let h = parse(c).get
      check h.routing.len == 2
      # The rule naming the caller wins; then the rule for any caller; else direct.
      check selectMode(
        h.routing,
        RouteEnds(consumerModule: "test_orchestrator", providerModule: "meter_module"),
      ) == rmDirect
      check selectMode(
        h.routing, RouteEnds(consumerModule: "other", providerModule: "meter_module")
      ) == rmLocalTransport
      check selectMode(
        h.routing, RouteEnds(consumerModule: "other", providerModule: "other_module")
      ) == rmDirect
      c.routing = Opt.some(@[rule(AuthorityModule)]) # an ordinary consumer's route
      check parse(c).isOk
    else:
      check parse(c).rejects("local-transport is not supported on this platform")
    c.routing = Opt.some(@[rule("meter_module", direct = true), rule("meter_module")])
    check parse(c).rejects("two routing rules name the same caller and callee")
    c.routing = Opt.some(@[rule(LoaderModuleName, direct = true)])
    check parse(c).rejects("names the reserved Module Loader")
    c.routing =
      Opt.some(@[rule("meter_module", direct = true, Opt.some(LoaderModuleName))])
    check parse(c).rejects("names the reserved Module Loader")
    c.routing = Opt.some(@[rule("logos_runtime_control", direct = true)])
    check parse(c).rejects("logos_runtime_control as a callee")
    c.routing = Opt.some(@[rule("", direct = true)]) # the schema's .size (1..64)
    check parse(c).isErr

  test "[RUN-0741] [I90] transport: defaults, the one payload depth, frame_limit with what it raises, refusals naming the limit":
    let d = parse(baseConfig()).get.transport
    check int(d.frameLimit) == MinFrameLimit and int(d.peerFrameLimit) == MinFrameLimit
    check d.maxPayloadDepth == DefaultMaxDepth
    check d.terminationDrain == 0
    var c = baseConfig()
    c.runtime.max_payload_depth = Opt.some(200'u16)
    check parse(c).get.transport.maxPayloadDepth == 200 # [G241]
    c = baseConfig()
    c.transport =
      Opt.some(LcnAppTransport(frame_limit: Opt.some(uint32(MinFrameLimit) - 1)))
    check parse(c).rejects("transport.frame_limit must be at least 16777216")
    let big = 2'u32 * uint32(MinFrameLimit)
    c.transport = Opt.some(LcnAppTransport(frame_limit: Opt.some(big)))
    let t = parse(c).get.transport
    check t.frameLimit == big and t.peerFrameLimit == big
    check t.connOutputBytes >= 2 * int(big) and t.maxOutputBytes >= t.connOutputBytes
    check t.maxInputBytes >= int(big) and t.maxHelloInputBytes >= int(big)
    check t.callerUndeliveredBytes >= int(big)
    c.transport = Opt.some(LcnAppTransport(hello_timeout_ms: Opt.some(0'u32)))
    check parse(c).rejects("transport.hello_timeout_ms must be 1 to 3600000")
    c.transport =
      Opt.some(LcnAppTransport(write_stall_timeout_ms: Opt.some(3_600_001'u32)))
    check parse(c).rejects("transport.write_stall_timeout_ms must be 1 to 3600000")
    c.transport = Opt.some(LcnAppTransport(write_stall_timeout_ms: Opt.some(250'u32)))
    check parse(c).get.transport.writeStallTimeout == 250_000_000
    c.transport = Opt.some(LcnAppTransport(max_pending_output_bytes: Opt.some(0'u64)))
    check parse(c).rejects("transport.max_pending_output_bytes is out of range")
    c.transport = Opt.some(LcnAppTransport(conn_output_bytes: Opt.some(1024'u32)))
    check parse(c).rejects("transport: connOutputBytes cannot hold a maximal frame")
    c.transport =
      Opt.some(LcnAppTransport(caller_undelivered_bytes: Opt.some(1024'u32)))
    check parse(c).rejects("transport: callerUndeliveredBytes is below frameLimit")
    c.transport = Opt.some(LcnAppTransport(max_inbound: Opt.some(0'u16)))
    check parse(c).rejects("transport: ")
    c.transport = Opt.some(LcnAppTransport(max_in_flight: Opt.some(0'u32)))
    check parse(c).rejects("transport: ")
    c.transport = Opt.some(
      LcnAppTransport(
        max_inbound: Opt.some(8'u16),
        max_outbound: Opt.some(4'u16),
        max_calls: Opt.some(16'u32),
        max_in_flight: Opt.some(32'u32),
      )
    )
    let u = parse(c).get.transport
    check u.maxInbound == 8 and u.maxPendingHellos <= 8 and u.maxOutbound == 4
    check u.maxCalls == 16 and u.maxInFlight == 32

  test "[I90] [IMPL] endpoint_dir is an absolute path, <work_dir>/endpoints when absent":
    check parse(baseConfig()).get.endpointDir == work / "w" / "endpoints"
    var c = baseConfig()
    c.runtime.endpoint_dir = Opt.some("relative/e")
    check parse(c).rejects("endpoint_dir must be an absolute path")
    c.runtime.endpoint_dir = Opt.some(work / "e")
    check parse(c).get.endpointDir == work / "e"

  test "deadlines are 1 ms to 1 h and paths are absolute [IMPL]":
    var c = baseConfig()
    c.runtime.startup_deadline_ms = Opt.some(0'u32)
    check parse(c).rejects("startup_deadline_ms")
    c = baseConfig()
    c.runtime.stop_deadline_ms = Opt.some(3_600_001'u32)
    check parse(c).rejects("stop_deadline_ms")
    c = baseConfig()
    c.runtime.shutdown_grace_ms = Opt.some(250'u32)
    check parse(c).get.shutdownGrace.inMilliseconds == 250
    # [G61, fourth deadline; I87] live configuration application
    c = baseConfig()
    c.runtime.apply_deadline_ms = Opt.some(0'u32)
    check parse(c).rejects("apply_deadline_ms")
    c.runtime.apply_deadline_ms = Opt.some(3_600_001'u32)
    check parse(c).rejects("apply_deadline_ms")
    c.runtime.apply_deadline_ms = Opt.some(1500'u32)
    check parse(c).get.applyDeadline.inMilliseconds == 1500
    c = baseConfig()
    c.runtime.work_dir = "relative/w"
    check parse(c).rejects("work_dir must be an absolute path")
    c = baseConfig()
    # Logos text never holds NUL, so the schema already refuses it.
    c.runtime.state_root = Opt.some(work / "s\0x")
    check parse(c).isErr
    c = baseConfig()
    c.modules[1].implementation = LcnAppImplementation(
      kind: LcnAppImplementationKind.Direct_dynamic,
      arm_Direct_dynamic: LcnAppImplementationARDirectDynamicMap(
        artifact:
          LcnAppArtifact(id: "a", local_path: "libsensor.so", hash: newSeq[byte](32))
      ),
    )
    check parse(c).rejects("local_path must be an absolute path")

  test "[RUN-0741] [IMPL] store_dir is absolute and apart from work_dir and state_root; an identity needs it":
    var c = baseConfig()
    c.runtime.store_dir = Opt.some(work / "store")
    c.runtime.runtime_instance_id = Opt.some("rt-1")
    let ok = parse(c).get
    check ok.storeDir == Opt.some(work / "store")
    check ok.runtimeInstanceId == "rt-1"
    c.runtime.store_dir = Opt.some("relative/store")
    check parse(c).rejects("store_dir must be an absolute path")
    c.runtime.store_dir = Opt.some(work / "w")
    check parse(c).rejects("store_dir and work_dir must be apart")
    c.runtime.store_dir = Opt.some(work / "w" / "store")
    check parse(c).rejects("store_dir and work_dir must be apart")
    c.runtime.store_dir = Opt.some(work)
    check parse(c).rejects("store_dir and work_dir must be apart")
    c.runtime.store_dir = Opt.some(work / "s" / "store")
    c.runtime.state_root = Opt.some(work / "s")
    check parse(c).rejects("store_dir and state_root must be apart")
    c = baseConfig()
    c.runtime.runtime_instance_id = Opt.some("rt-1")
    check parse(c).rejects("runtime_instance_id needs store_dir")

  test "[RUN-0741] [IMPL-DECISION G55] declarations: one per module name, each a valid record":
    proc declaration(module, binding: string): LcnAppDeclaration =
      LcnAppDeclaration(
        module: module,
        implementation: LcnAppImplementation(
          kind: LcnAppImplementationKind.Direct_static,
          arm_Direct_static: LcnAppImplementationARDirectStaticMap(binding: binding),
        ),
      )

    var c = baseConfig()
    c.runtime.state_root = Opt.some(work / "state")
    var keep = declaration("meter_module", "meter")
    keep.persistent_state = Opt.some(true)
    c.declarations = Opt.some(@[keep, declaration("other_module", "other")])
    let ok = parse(c).get
    check ok.declarations.len == 2
    check ok.declarations[0].record.module == "meter_module"
    check ok.declarations[0].record.binding == "meter"
    check ok.declarations[0].persistentState
    check not ok.declarations[1].persistentState
    c.declarations = Opt.some(newSeq[LcnAppDeclaration]())
    check parse(c).rejects("declarations is present but empty")
    c.declarations = Opt.some(
      @[declaration("meter_module", "meter"), declaration("meter_module", "x")]
    )
    check parse(c).rejects("module meter_module is declared twice")
    var empty = declaration("meter_module", "meter")
    empty.implements = Opt.some(newSeq[SchemaCommitment]())
    c.declarations = Opt.some(@[empty])
    check parse(c).rejects("declaration meter_module: implements is present but empty")
    c.declarations = Opt.some(@[keep])
    c.runtime.state_root = Opt.none(string)
    check parse(c).rejects("persistent_state needs state_root")

  test "[RUN-0259] [RUN-0741] [CFG-0016] [CFG-0017] [CFG-0018] [CFG-0019] [I87] a configuration declaration is accepted before any record names it, with the instance's provisioned value":
    var c = baseConfig()
    c.runtime.state_root = Opt.some(work / "state")
    c.modules[1].configuration =
      Opt.some(tunerDeclBytes(default = Opt.some(tunerValue())))
    c.modules[1].provisioned_configuration = Opt.some(tunerValue("p"))
    let h = parse(c).get
    let m = h.modules[1]
    check m.configuration.isSome
    check m.record.configuration == Opt.some(m.configuration.get.digest)
    check m.configuration.get.defaultValue.get.bytes == tunerValue()
    check m.configuration.get.provisioned.get.bytes == tunerValue("p")
    check not m.configuration.get.live
    check h.modules[0].configuration.isNone and h.modules[0].record.configuration.isNone
    # [G141] A provisioned value belongs to an instance whose module declares
    # a configuration.
    c.modules[1].configuration = Opt.none(seq[byte])
    check parse(c).rejects(
      "module instance meter-1: provisioned_configuration needs configuration"
    )
    c.modules[1].configuration = Opt.some(@[0x01'u8])
    check parse(c).rejects(
      "module instance meter-1: the configuration declaration is not one"
    )
    c.modules[1].configuration = Opt.some(tunerDeclBytes())
    c.modules[1].provisioned_configuration =
      Opt.some(encodeCbor(cborMap((cbor("station"), cbor("x")))))
    check parse(c).rejects(
      "module instance meter-1: the provisioned configuration is not a complete value of " &
        TunerRoot
    )
    c.modules[1].provisioned_configuration = Opt.none(seq[byte])
    c.modules[1].configuration =
      Opt.some(tunerDeclBytes(default = Opt.some(encodeCbor(cbor(1'u64)))))
    check parse(c).rejects("the default value is not a complete value of " & TunerRoot)
    var d = tunerDecl()
    d.schema.schema_commitment.schema_root[0] =
      d.schema.schema_commitment.schema_root[0] xor 1
    c.modules[1].configuration = Opt.some(encode(d).tryGet)
    check parse(c).rejects("the configuration schema root is not the declared one")
    d = tunerDecl()
    d.schema.root = "tuner.missing"
    c.modules[1].configuration = Opt.some(encode(d).tryGet)
    check parse(c).rejects(
      "the configuration root tuner.missing is not a type of its schema"
    )
    # A declaration carries the binding for instances created later; a
    # provisioned value is never given to a module name (RUN-0923).
    c = baseConfig()
    c.declarations = Opt.some(
      @[
        LcnAppDeclaration(
          module: "tuner_module",
          implementation: LcnAppImplementation(
            kind: LcnAppImplementationKind.Direct_static,
            arm_Direct_static: LcnAppImplementationARDirectStaticMap(binding: "tuner"),
          ),
          configuration: Opt.some(tunerDeclBytes(live = true)),
        )
      ]
    )
    let declared = parse(c).get.declarations[0]
    check declared.configuration.get.live
    check declared.record.configuration == Opt.some(declared.configuration.get.digest)
    check declared.configuration.get.provisioned.isNone
    c.declarations.get[0].configuration = Opt.some(@[0xa0'u8])
    check parse(c).rejects(
      "declaration tuner_module: the configuration declaration is not one"
    )

  test "[IMPL] the names the Runtime assigns are refused in the configuration":
    let form = "m-" & repeat("0a", 16) & "-1"
    check isRuntimeForm(form)
    check not isRuntimeForm("m-" & repeat("0A", 16) & "-1")
    check not isRuntimeForm("m-" & repeat("0a", 16) & "-")
    check not isRuntimeForm("meter-1")
    var c = baseConfig()
    c.modules[1].instance = form
    check parse(c).rejects("Runtime-assigned name form")
    c = baseConfig()
    c.modules[1].state_assignment = Opt.some("s-" & repeat("0a", 16) & "-7")
    check parse(c).rejects("Runtime-assigned name form")
    c = baseConfig()
    c.modules[1].instance = "p-" & repeat("0a", 16) & "-2"
    check parse(c).rejects("Runtime-assigned name form")

  test "[IMPL-DECISION I96] [IMPL-DECISION G306] state_transfers: between a source not listed and a listed target with its own assignment, with a store and a state root; move only in this build":
    proc transfer(
        source, target: string, copy = false, maxBytes = Opt.none(uint64)
    ): LcnAppStateTransfer =
      LcnAppStateTransfer(
        `from`: source,
        to: target,
        mode: LcnAppStateTransferModeChoice(
          kind: (
            if copy: LcnAppStateTransferModeChoiceKind.Copy
            else: LcnAppStateTransferModeChoiceKind.Move
          )
        ),
        max_bytes: maxBytes,
      )

    proc withTransfers(t: seq[LcnAppStateTransfer]): LcnAppConfig =
      result = baseConfig()
      result.runtime.store_dir = Opt.some(work / "store")
      result.runtime.state_root = Opt.some(work / "state")
      result.modules[1].state_assignment = Opt.some("meter-2-state")
      result.state_transfers = Opt.some(t)

    let ok1 = parse(withTransfers(@[transfer("meter-0", "meter-1")])).tryGet
    check ok1.transfers ==
      @[StateTransfer(source: "meter-0", target: "meter-1", mode: tmMove)]
    # The schema: mode is required, with no default.
    let noMode = cborMap((cbor("from"), cbor("meter-0")), (cbor("to"), cbor("meter-1")))
    let v = toCbor(withTransfers(@[transfer("meter-0", "meter-1")]))
    var entries: seq[CborEntry]
    for e in v.entries:
      if e.key == cbor("state_transfers"):
        entries.add((e.key, cborArray(noMode)))
      else:
        entries.add(e)
    check parseValue(cborMap(entries)).rejects("does not match lcn.app_config")
    check parse(withTransfers(@[])).rejects("state_transfers is present but empty")
    var noStore = withTransfers(@[transfer("meter-0", "meter-1")])
    noStore.runtime.store_dir = Opt.none(string)
    check parse(noStore).rejects("needs store_dir and state_root")
    var noRoot = withTransfers(@[transfer("meter-0", "meter-1")])
    noRoot.runtime.state_root = Opt.none(string)
    check parse(noRoot).rejects("needs store_dir and state_root")
    let form = "m-" & repeat("0a", 16) & "-1"
    for (t, fragment) in [
      (transfer(LoaderInstanceId, "meter-1"), "reserved Module Loader"),
      (transfer(form, "meter-1"), "Runtime-assigned name form"),
      (transfer("meter-1", "meter-1"), "same instance"),
      (transfer("orch", "meter-1"), "from is listed in modules"),
      (transfer("meter-0", "meter-9"), "to is not listed in modules"),
      (transfer("meter-0", "orch"), "to has no state_assignment"),
      (transfer("meter-0", "meter-1", maxBytes = Opt.some(5'u64)), "for copy only"),
    ]:
      check parse(withTransfers(@[t])).rejects(fragment)
    var two = withTransfers(@[])
    two.modules.add(staticModule("meter-3", "meter_module", "meter"))
    two.modules[2].state_assignment = Opt.some("meter-3-state")
    two.state_transfers =
      Opt.some(@[transfer("x", "meter-1"), transfer("x", "meter-3")])
    check parse(two).rejects("x is the source of two entries")
    two.state_transfers =
      Opt.some(@[transfer("x", "meter-1"), transfer("y", "meter-1")])
    check parse(two).rejects("meter-1 is the target of two entries")
    # A source that is also a target is a listed instance: no chain.
    two.state_transfers =
      Opt.some(@[transfer("x", "meter-1"), transfer("meter-1", "meter-3")])
    check parse(two).rejects("from is listed in modules")
    # Copy bounds.
    for n in [0'u64, MaxTransferBytes + 1]:
      check decoded(withTransfers(@[transfer("meter-0", "meter-1", true, Opt.some(n))]))
        .rejects("max_bytes must be 1 to")
    let copy =
      withTransfers(@[transfer("meter-0", "meter-1", true, Opt.some(MaxTransferBytes))])
    let parsed = parse(copy).tryGet.transfers[0]
    check parsed.mode == tmCopy and parsed.maxBytes == MaxTransferBytes
    check parse(withTransfers(@[transfer("meter-0", "meter-1", true)])).tryGet.transfers[
      0
    ].maxBytes == 0 # the default, `DefaultTransferBytes`, applies
    # Never the authority instance, wired to its directory before bootstrap.
    var ca = caConfig()
    ca.modules[1].state_assignment = Opt.some("meter-2-state")
    ca.state_transfers = Opt.some(@[transfer("ca", "meter-1")])
    check parse(ca).rejects("names the Capability Authority instance")
    ca.state_transfers = Opt.some(@[transfer("meter-0", "ca")])
    check parse(ca).rejects("names the Capability Authority instance")

  test "[IMPL] [IMPL-DECISION G272] module_host is an absolute regular executable, of this user or root and writable by its owner only; module_host_env names each variable once; a hosted record needs module_host; no direct routing rule names a hosted module":
    # Tier 4b step 4b-3 (plan §2.2, §3, R4; DECISIONS G264).
    let dir = work / "module-host"
    createDir(dir)
    let program = dir / "logos-module-host"
    writeFile(program, "#!/bin/sh\nexit 2\n")
    when defined(posix):
      check chmod(cstring(program), Mode(0o755)) == 0
    let hosted = LcnAppModule(
      instance: "probe-1",
      module: "probe_module",
      implementation: LcnAppImplementation(
        kind: LcnAppImplementationKind.Process_hosted_dynamic,
        arm_Process_hosted_dynamic: LcnAppImplementationARProcessHostedDynamicMap(
          artifact: LcnAppArtifact(
            id: "probe", local_path: dir / "libprobe.so", hash: newSeq[byte](32)
          )
        ),
      ),
    )
    var c = baseConfig()
    c.modules.add(hosted)
    check parse(c).rejects("module instance probe-1: hosted_dynamic needs module_host")
    c.runtime.module_host = Opt.some(program)
    when not defined(posix):
      # [plan §2.1] The host is a stub here.
      check parse(c).rejects("module_host is not supported on this platform")
    else:
      let accepted = parse(c)
      check accepted.isOk
      if accepted.isOk:
        check accepted.get.moduleHost == Opt.some(program)
        check accepted.get.moduleHostEnv.len == 0
        let r = accepted.get.modules[^1].record
        check r.strategy == stHostedDynamic and r.placement == "process"
      c.runtime.module_host = Opt.some("logos-module-host")
      check parse(c).rejects("module_host must be an absolute path")
      c.runtime.module_host = Opt.some(program)
      check chmod(cstring(program), Mode(0o775)) == 0
      check parse(c).rejects("module_host is writable by its group or others")
      check chmod(cstring(program), Mode(0o644)) == 0
      check parse(c).rejects("module_host is not executable")
      check chmod(cstring(program), Mode(0o755)) == 0
      let link = dir / "link"
      removeFile(link)
      createSymlink(program, link)
      c.runtime.module_host = Opt.some(link)
      check parse(c).rejects("module_host is a symbolic link")
      c.runtime.module_host = Opt.some(dir)
      check parse(c).rejects("module_host is not a regular file")
      c.runtime.module_host = Opt.some(dir / "missing")
      check parse(c).rejects("module_host does not exist")
      c.runtime.module_host = Opt.some(program)
      c.runtime.module_host_env = Opt.some(newSeq[string]())
      check parse(c).rejects("module_host_env is present but empty")
      c.runtime.module_host_env = Opt.some(@["A=B"])
      check parse(c).rejects("module_host_env names A=B badly or twice")
      c.runtime.module_host_env = Opt.some(@["TSAN_OPTIONS", "TSAN_OPTIONS"])
      check parse(c).rejects("module_host_env names TSAN_OPTIONS badly or twice")
      c.runtime.module_host_env = Opt.some(@["TSAN_OPTIONS", "ASAN_OPTIONS"])
      check parse(c).get.moduleHostEnv == @["TSAN_OPTIONS", "ASAN_OPTIONS"]
      # A declaration needs it as a module does.
      c = baseConfig()
      c.declarations = Opt.some(
        @[
          LcnAppDeclaration(
            module: "probe_module", implementation: hosted.implementation
          )
        ]
      )
      check parse(c).rejects(
        "declaration probe_module: hosted_dynamic needs module_host"
      )
      # [Rev R10] A direct routing rule naming a hosted_dynamic module, as
      # callee or as caller, is refused; local-transport is accepted.
      c = baseConfig()
      c.runtime.module_host = Opt.some(program)
      c.modules.add(hosted)
      proc rule(
          callee: string,
          mode: LcnAppRoutingRuleModeChoiceKind,
          caller = Opt.none(string),
      ): LcnAppRoutingRule =
        LcnAppRoutingRule(
          callee: callee, caller: caller, mode: LcnAppRoutingRuleModeChoice(kind: mode)
        )

      type M = LcnAppRoutingRuleModeChoiceKind
      c.routing = Opt.some(@[rule("probe_module", M.Direct)])
      check parse(c).rejects(
        "routing: the direct routing rule any -> probe_module names probe_module, which is hosted_dynamic"
      )
      c.routing = Opt.some(@[rule("meter_module", M.Direct, Opt.some("probe_module"))])
      check parse(c).rejects(
        "routing: the direct routing rule probe_module -> meter_module names probe_module, which is hosted_dynamic"
      )
      c.routing = Opt.some(
        @[
          rule("probe_module", M.Local_transport),
          rule("meter_module", M.Direct, Opt.some("client_module")),
        ]
      )
      check parse(c).isOk

  test "[RUN-0284] a hosted_dynamic implementation is an artifact in a placement, never a static binding":
    var c = baseConfig()
    c.runtime.module_host = Opt.some(work / "module-host" / "logos-module-host")
    let artifact = LcnAppArtifact(
      id: "probe", local_path: work / "libprobe.so", hash: newSeq[byte](32)
    )
    c.modules.add(
      LcnAppModule(
        instance: "probe-1",
        module: "probe_module",
        implementation: LcnAppImplementation(
          kind: LcnAppImplementationKind.Process_hosted_dynamic,
          arm_Process_hosted_dynamic:
            LcnAppImplementationARProcessHostedDynamicMap(artifact: artifact),
        ),
      )
    )
    var cv = toCbor(c)
    for e in cv.entries.mitems:
      if e[0].text == "modules":
        for m in e[1].items.mitems:
          for f in m.entries.mitems:
            if f[0].text == "implementation" and
                f[1].entries.anyIt(it[0].text == "placement"):
              f[1] = f[1].withEntry("binding", cbor("probe"))
    check parseValue(cv).rejects("lcn.app_config")
    # Without its placement, or with a placement other than `process`.
    for placement in ["sandbox", "container"]:
      var pv = toCbor(c)
      for e in pv.entries.mitems:
        if e[0].text == "modules":
          for m in e[1].items.mitems:
            for f in m.entries.mitems:
              if f[0].text == "implementation":
                for g in f[1].entries.mitems:
                  if g[0].text == "placement":
                    g[1] = cbor(placement)
      check parseValue(pv).rejects("lcn.app_config")

  test "[RUN-0740] docs/HOST-CONFIG.md names the identifier and carries the schema verbatim":
    let root = currentSourcePath().parentDir.parentDir
    let doc = readFile(root / "docs" / "HOST-CONFIG.md")
    check ("# Host configuration: `" & AppConfigFormat & "`") in doc
    check (
      "```cddl\n" & readFile(root / "src/logos_core/runtime/host_config.cddl") & "```"
    ) in doc

# The test orchestrator --------------------------------------------------------------
#
# A consumer-only module for the orchestration role. Module code runs on the
# engine's workers, so its state is in atomics.

type OrchMode = enum
  omPlain ## LOGOS_OK at once
  omShutdown ## `shutdown_runtime` from its own initialization
  omStartBroken ## `start_module` on `broken-1` from its own initialization
  omWaitProbe ## `logos_runtime_wait_for_shutdown` from its own initialization
  omAutostart ## after initialization, its own thread starts the deployment

const Targets = [
  ("test_orchestrator", "orch"),
  ("meter_module", "meter-1"),
  ("sensor_module", "sensor-1"),
]

const AlreadyRequested = 1000 ## an orchestrator result: intent was not uninitialized

var
  orchMode: Atomic[int]
  orchFail: Atomic[bool] ## MODULE_ERROR at the end of initialization
  orchGate, orchDestroyGate: Atomic[bool] ## true while closed
  orchNames, orchInits, orchDestroys: Atomic[int]
  orchRc: Atomic[pointer] ## the latest initialization's Runtime Control binding
  orchHandle: Atomic[pointer] ## the host handle, for omWaitProbe
  orchInitCode: Atomic[int] ## what its own call from initialization returned
  orchResults: array[Targets.len + 1, Atomic[int]]
    ## per target, the start's code or AlreadyRequested; then a stale start
  orchThreadLive, orchThreadDone: Atomic[bool]
  orchCalls: Atomic[int]
    ## calls through its binding not yet past `release_response`: a module
    ## releases every response before its `_MODULE_destroy` returns (INTERFACE
    ## l.1619, l.3831), so the destroy waits for these, the test's own included
  orchThread: Thread[ptr LogosRuntimeControlBinding]

proc copyBytes(p: ptr UncheckedArray[uint8], n: csize_t): seq[byte] =
  result = newSeq[byte](int(n))
  for i in 0 ..< int(n):
    result[i] = p[i]

proc ec(r: LogosResult): ErrorCode =
  errorCode(int64(r.code)).get

proc text(r: LogosResult): string =
  if r.message.isNil:
    ""
  else:
    $r.message

proc rcCall(
    rc: ptr LogosRuntimeControlBinding, name: string, params: openArray[byte]
): (ErrorCode, seq[byte]) {.gcsafe.} =
  discard orchCalls.fetchAdd(1)
  defer:
    discard orchCalls.fetchSub(1)
  var buf: ptr UncheckedArray[uint8]
  var len: csize_t
  let r = rc.vtable.call(
    rc,
    cstring(name),
    cast[ptr UncheckedArray[uint8]](unsafeAddr params[0]),
    csize_t(params.len),
    addr buf,
    addr len,
  )
  result[0] = r.ec
  if buf != nil:
    result[1] = copyBytes(buf, len)
    rc.vtable.releaseResponse(rc, buf, len)

const StaleAnswer = -4
  ## [re-pin P4a] a start answered with the typed `stale-revision`: a
  ## successful call whose response holds the error arm

proc startModule(
    rc: ptr LogosRuntimeControlBinding, module, instance: string, expected: Opt[uint64]
): int {.gcsafe.} =
  ## The start's code, or `StaleAnswer`.
  let (code, response) = rcCall(
    rc,
    "start_module",
    encode(
      LogosNSRuntimeControlStartModuleRequest(
        module: module,
        instance: Opt.some(instance),
        expected_execution_revision: expected,
      )
    ).tryGet,
  )
  if code == ecOk and
      LogosNSRuntimeControlStartModuleResponse.decode(response).tryGet.refusal.isSome:
    return StaleAnswer
  ord(code)

proc readiness(
    rc: ptr LogosRuntimeControlBinding, module, instance: string
): Result[LogosNSRuntimeControlGetReadinessResponse, ErrorCode] {.gcsafe.} =
  let (c, response) = rcCall(
    rc,
    "get_readiness",
    encode(
      LogosNSRuntimeControlGetReadinessRequest(
        module: module, instance: Opt.some(instance)
      )
    ).tryGet,
  )
  if c != ecOk:
    return err(c)
  ok(LogosNSRuntimeControlGetReadinessResponse.decode(response).tryGet)

proc orchestrate(rc: ptr LogosRuntimeControlBinding) {.thread.} =
  ## [SPEC RUNTIME l.3709-3712; RUN-0025] The orchestrator's own logic: a
  ## conditional start of every target that was never started.
  var meterRevision = 0'u64
  for i, (module, instance) in Targets:
    let g = rc.readiness(module, instance)
    if g.isErr:
      orchResults[i].store(ord(g.error))
      continue
    let x = g.get.execution.get
    if instance == "meter-1":
      meterRevision = x.revision
    if x.intent.kind != LogosNSRuntimeControlExecutionStateIntentChoiceKind.Uninitialized:
      orchResults[i].store(AlreadyRequested)
      continue
    orchResults[i].store(rc.startModule(module, instance, Opt.some(x.revision)))
  # The revision read before the start is stale now.
  orchResults[Targets.len].store(
    rc.startModule("meter_module", "meter-1", Opt.some(meterRevision))
  )
  orchThreadDone.store(true)

proc orchName(): cstring {.cdecl.} =
  orchNames.atomicInc
  "test_orchestrator"

proc orchInit(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.cdecl.} =
  orchInits.atomicInc
  orchRc.store(input.runtimeControl)
  while orchGate.load:
    sleep(1)
  {.cast(gcsafe).}:
    case OrchMode(orchMode.load)
    of omPlain:
      discard
    of omShutdown:
      orchInitCode.store(
        ord(rcCall(input.runtimeControl, "shutdown_runtime", [0xA0'u8])[0])
      )
    of omStartBroken:
      orchInitCode.store(
        input.runtimeControl.startModule("meter_module", "broken-1", Opt.none(uint64))
      )
    of omWaitProbe:
      orchInitCode.store(
        ord(runtimeWaitForShutdown(cast[ptr LogosRuntimeHandle](orchHandle.load)).ec)
      )
    of omAutostart:
      orchThreadLive.store(true)
      createThread(orchThread, orchestrate, input.runtimeControl)
  if orchFail.load:
    result.code = CErrorCode(ord(ecModule))
    result.message = "cannot orchestrate"
    return
  outContext[] = cast[ptr LogosModuleContext](allocShared0(16))

proc orchDestroy(module: ptr LogosModuleContext) {.cdecl.} =
  while orchDestroyGate.load:
    sleep(1)
  if orchThreadLive.load:
    joinThread(orchThread) # its calls end before the binding does
    orchThreadLive.store(false)
  while orchCalls.load > 0:
    sleep(1)
  deallocShared(module)
  orchDestroys.atomicInc

proc orchTable(): seq[(string, pointer)] =
  @[
    ("logos_test_orchestrator_MODULE_name", cast[pointer](orchName)),
    ("logos_test_orchestrator_MODULE_init", cast[pointer](orchInit)),
    ("logos_test_orchestrator_MODULE_destroy", cast[pointer](orchDestroy)),
  ]

proc resetOrchestrator() =
  orchMode.store(ord(omPlain))
  orchFail.store(false)
  orchGate.store(false)
  orchDestroyGate.store(false)
  orchNames.store(0)
  orchInits.store(0)
  orchDestroys.store(0)
  orchRc.store(nil)
  orchHandle.store(nil)
  orchInitCode.store(-1)
  for r in orchResults.mitems:
    r.store(-1)
  orchThreadDone.store(false)

# Host calls ---------------------------------------------------------------------------

let sensorLib = buildKitLibrary("sensor_impl.nim", "hostsensor")

proc digestOfFile(path: string): seq[byte] =
  var h: Blake3Hasher
  h.init()
  let bytes = readFile(path)
  h.update(bytes.toOpenArrayByte(0, bytes.high))
  @(h.finish())

var handles = 0

proc deployment(extra: seq[LcnAppModule] = @[]): LcnAppConfig =
  ## The orchestrator and the meter, each in its own work directory.
  inc handles
  result = baseConfig()
  result.runtime.work_dir = work / ("h" & $handles)
  result.runtime.state_root = Opt.some(work / ("h" & $handles) / "state")
  result.modules.add(extra)

proc broken(): LcnAppModule =
  ## A meter whose expected primary contract it does not have.
  result = staticModule("broken-1", "meter_module", "meter")
  result.primary_contract = Opt.some(root(0))

proc sensor(): LcnAppModule =
  LcnAppModule(
    instance: "sensor-1",
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

proc runtimeConfig(
    bytes: openArray[byte], format: cstring = AppConfigFormat
): LogosRuntimeConfig =
  LogosRuntimeConfig(
    abiVersion: RuntimeHostAbiVersion,
    structSize: csize_t(sizeof(LogosRuntimeConfig)),
    configurationFormat: format,
    configuration:
      if bytes.len > 0:
        cast[ptr UncheckedArray[uint8]](unsafeAddr bytes[0])
      else:
        nil,
    configurationLen: csize_t(bytes.len),
  )

proc create(c: LcnAppConfig): ptr LogosRuntimeHandle =
  let bytes = c.encode.get
  var cfg = runtimeConfig(bytes)
  check runtimeCreate(addr cfg, addr result).ec == ecOk

proc nativeBinding(
    id: cstring, symbols: var seq[LogosRuntimeNativeSymbol]
): LogosRuntimeNativeBinding =
  LogosRuntimeNativeBinding(
    abiVersion: RuntimeHostAbiVersion,
    structSize: csize_t(sizeof(LogosRuntimeNativeBinding)),
    binding: id,
    symbols:
      if symbols.len > 0:
        cast[ptr UncheckedArray[LogosRuntimeNativeSymbol]](addr symbols[0])
      else:
        nil,
    symbolCount: csize_t(symbols.len),
  )

proc register(
    rt: ptr LogosRuntimeHandle, id: string, table: openArray[(string, pointer)]
): LogosResult =
  var names: seq[string]
  for (n, _) in table:
    names.add(n)
  var symbols = newSeq[LogosRuntimeNativeSymbol](table.len)
  for i in 0 ..< table.len:
    symbols[i] = LogosRuntimeNativeSymbol(
      name: cstring(names[i]), address: cast[LogosRuntimeSymbolAddress](table[i][1])
    )
  var b = nativeBinding(cstring(id), symbols)
  runtimeRegisterBinding(rt, addr b)

proc registered(c: LcnAppConfig): ptr LogosRuntimeHandle =
  ## A handle for `c` with the orchestrator and meter bindings registered.
  result = create(c)
  check result.register("orchestrator", orchTable()).ec == ecOk
  check result.register("meter", meterModuleStaticSymbols()).ec == ecOk

proc waitUntil(cond: proc(): bool {.closure.}, seconds = 20): bool =
  let until = getMonoTime() + initDuration(seconds = seconds)
  while getMonoTime() < until:
    if cond():
      return true
    sleep(2)
  cond()

proc finish(rt: ptr LogosRuntimeHandle) =
  ## Request, wait and destroy, each OK.
  orchGate.store(false)
  orchDestroyGate.store(false)
  check runtimeRequestShutdown(rt).ec == ecOk
  check runtimeWaitForShutdown(rt).ec == ecOk
  check runtimeDestroy(rt).ec == ecOk

proc state(rt: ptr LogosRuntimeHandle, instance: string): ModuleState =
  engineOf(rt).view(instance).tryGet.state

proc failureOf(rt: ptr LogosRuntimeHandle, instance: string): string =
  let v = engineOf(rt).view(instance).tryGet
  if v.failure.isSome: v.failure.get.classification else: ""

var
  startCode, waitCode: Atomic[int] ## the call's code, -1 while it runs
  otherThreadCode: Atomic[int]

proc startOn(rt: ptr LogosRuntimeHandle) {.thread.} =
  startCode.store(ord(runtimeStart(rt).ec))

proc waitOn(rt: ptr LogosRuntimeHandle) {.thread.} =
  waitCode.store(ord(runtimeWaitForShutdown(rt).ec))

proc failOn(rt: ptr LogosRuntimeHandle) {.thread.} =
  otherThreadCode.store(ord(runtimeStart(nil).ec))

# Structures and results ---------------------------------------------------------------

suite "run.host-api: structures and results (RUNTIME §13.1, §13.2, §13.4)":
  setup:
    resetOrchestrator()

  test "[RUN-0719] [RUN-0720] [RUN-0721] the version and size come first; past version 1's fields nothing is read":
    let bytes = deployment().encode.get
    var rt = cast[ptr LogosRuntimeHandle](1)
    var cfg = runtimeConfig(bytes, nil) # a null format is not reached
    cfg.abiVersion = 2
    check runtimeCreate(addr cfg, addr rt).ec == ecVersionMismatch
    check rt == nil
    cfg = runtimeConfig(bytes, nil)
    cfg.structSize = csize_t(RuntimeConfigV1Extent - 1)
    check runtimeCreate(addr cfg, addr rt).ec == ecVersionMismatch
    cfg.structSize = 0
    check runtimeCreate(addr cfg, addr rt).ec == ecVersionMismatch
    # A later version's larger structure, its tail filled with garbage.
    var larger = newSeq[byte](sizeof(LogosRuntimeConfig) + 64)
    for b in larger.mitems:
      b = 0xFF
    cfg = runtimeConfig(bytes)
    cfg.structSize = csize_t(larger.len)
    copyMem(addr larger[0], addr cfg, sizeof(cfg))
    check runtimeCreate(cast[ptr LogosRuntimeConfig](addr larger[0]), addr rt).ec == ecOk
    check rt != nil
    check runtimeDestroy(rt).ec == ecOk
    # The binding structure has the same two checks.
    rt = create(deployment())
    var symbols = @[
      LogosRuntimeNativeSymbol(
        name: "logos_test_orchestrator_MODULE_name",
        address: cast[LogosRuntimeSymbolAddress](orchName),
      )
    ]
    var b = nativeBinding(nil, symbols) # a null identifier is not reached
    b.abiVersion = 0
    check runtimeRegisterBinding(rt, addr b).ec == ecVersionMismatch
    b = nativeBinding(nil, symbols)
    b.structSize = csize_t(NativeBindingV1Extent - 1)
    check runtimeRegisterBinding(rt, addr b).ec == ecVersionMismatch
    check runtimeDestroy(rt).ec == ecOk

  test "[RUN-0753] [RUN-0755] null arguments are INVALID_PARAMS, and the output handle is cleared first":
    var rt = cast[ptr LogosRuntimeHandle](1)
    check runtimeCreate(nil, addr rt).ec == ecInvalidParams
    check rt == nil
    let bytes = deployment().encode.get
    var cfg = runtimeConfig(bytes)
    check runtimeCreate(addr cfg, nil).ec == ecInvalidParams
    check runtimeRegisterBinding(nil, nil).ec == ecInvalidParams
    check runtimeStart(nil).ec == ecInvalidParams
    check runtimeRequestShutdown(nil).ec == ecInvalidParams
    check runtimeWaitForShutdown(nil).ec == ecInvalidParams
    check runtimeDestroy(nil).ec == ecInvalidParams
    rt = create(deployment())
    check runtimeRegisterBinding(rt, nil).ec == ecInvalidParams
    check runtimeDestroy(rt).ec == ecOk

  test "[RUN-0741] [RUN-0742] the format and the bytes: every failure is INVALID_PARAMS and creates nothing":
    let bytes = deployment().encode.get
    var rt = cast[ptr LogosRuntimeHandle](1)
    for f in [cstring(nil), cstring(""), cstring("logos-core-nim.app-config.v2")]:
      var cfg = runtimeConfig(bytes, f)
      check runtimeCreate(addr cfg, addr rt).ec == ecInvalidParams
      check rt == nil
    var cfg = runtimeConfig(bytes)
    cfg.configuration = nil
    check runtimeCreate(addr cfg, addr rt).ec == ecInvalidParams
    check rt == nil
    # No bytes at all, malformed and non-deterministic CBOR carry their detail.
    cfg.configurationLen = 0
    var r = runtimeCreate(addr cfg, addr rt)
    check r.ec == ecInvalidParams
    check copyBytes(r.detail, r.detailLen) == invalidParamsDetail(iprMalformedCbor)
    let nd = @[0x18'u8, 0x05]
    cfg = runtimeConfig(nd)
    r = runtimeCreate(addr cfg, addr rt)
    check r.ec == ecInvalidParams
    check copyBytes(r.detail, r.detailLen) ==
      invalidParamsDetail(iprNonDeterministicCbor)
    # A semantic failure has a message and no detail.
    var c = deployment()
    c.orchestration = "nobody"
    let sem = c.encode.get
    cfg = runtimeConfig(sem)
    r = runtimeCreate(addr cfg, addr rt)
    check r.ec == ecInvalidParams and "orchestration names no instance" in r.text
    check r.detail == nil and r.detailLen == 0
    check rt == nil
    # [IMPL] create opened nothing: no work directory yet.
    c = deployment()
    rt = create(c)
    check not dirExists(c.runtime.work_dir)
    check runtimeDestroy(rt).ec == ecOk

  test "[CAP-0230] [I85] create reads the call-evidence key file: one it cannot use fails INVALID_PARAMS naming call_audit.evidence and creates nothing; no evidence is exported before start":
    createDir(work)
    var seed: Seed
    let (sk, _) = keyPairFromSeeds(seed, seed, seed)
    let path = work / "evidence.key"
    proc put(mode: int) =
      removeFile(path)
      # The byte overload: a seq cast to a string has no terminating NUL, and
      # Windows writes a string with fprintf("%s"), which runs past its end.
      writeFile(path, sk)
      check chmod(cstring(path), Mode(mode)) == 0

    var c = deployment()
    c.runtime.store_dir = Opt.some(work / "evidence-store")
    c.call_audit = Opt.some(
      LcnAppCallAudit(
        evidence: Opt.some(LcnAppEvidenceKey(kid: @[1'u8], secret_key_file: path))
      )
    )
    let bytes = c.encode.get
    var rt = cast[ptr LogosRuntimeHandle](1)
    proc refused(fragment: string): bool =
      var cfg = runtimeConfig(bytes)
      let r = runtimeCreate(addr cfg, addr rt)
      checkpoint r.text
      r.ec == ecInvalidParams and "call_audit.evidence" in r.text and fragment in r.text and
        rt == nil

    removeFile(path)
    check refused("cannot be read")
    when not defined(windows): # [I85] the mode is checked on POSIX only
      put(0o644)
      check refused("0600")
    put(0o600)
    rt = create(c)
    check rt.auditRecords.len == 0
    check rt.exportCallEvidence(0).isErr
    check runtimeDestroy(rt).ec == ecOk
    removeFile(path)

  test "[RUN-0764] a result's message lives in its thread until that thread's next call; OK has none; 512 bytes at most":
    var rt: ptr LogosRuntimeHandle
    let bad = runtimeCreate(nil, addr rt)
    let p = bad.message
    check $p == "config is null"
    otherThreadCode.store(-1)
    var t: Thread[ptr LogosRuntimeHandle]
    createThread(t, failOn, nil)
    joinThread(t)
    check otherThreadCode.load == ord(ecInvalidParams)
    check bad.message == p and $p == "config is null" # another thread's call
    rt = create(deployment())
    let good = runtimeRequestShutdown(rt)
    check good.ec == ecOk and good.message.isNil and good.detail.isNil
    check good.detailLen == 0
    # A message is cut to 512 bytes before a continuation byte.
    let long = "logos_" & repeat("é", 600) & "_MODULE_init"
    let r = rt.register("x", [(long, nil.pointer)])
    check r.ec == ecNotReady # shutdown was requested: call order first
    check runtimeWaitForShutdown(rt).ec == ecOk
    check runtimeDestroy(rt).ec == ecOk
    rt = create(deployment())
    let cut = rt.register("x", [(long, nil.pointer)])
    check cut.ec == ecInvalidParams
    check cut.text.startsWith("symbol logos_é")
    check cut.text.len <= 512 and cut.text.len > 500
    check validateUtf8(cut.text) == -1
    check runtimeDestroy(rt).ec == ecOk

# Registration -------------------------------------------------------------------------

suite "run.host-api: registration (RUNTIME §13.3)":
  setup:
    resetOrchestrator()

  test "[RUN-0748] [RUN-1084] a table's own properties are checked; nothing invalid is kept":
    let rt = create(deployment())
    var t = orchTable()
    check rt.register("orch-bad", @[t[0], t[0]] & t[1 .. 2]).text.contains(
      "appears twice"
    )
    check rt.register("orch-bad", []).text.contains("the symbol table is empty")
    check rt.register("orch-bad", @[(t[0][0], nil.pointer)] & t[1 .. 2]).text.contains(
      "null address"
    )
    check rt.register("orch-bad", t & @[("not_a_symbol", t[0][1])]).ec == ecInvalidParams
    check rt.register("orch-bad", t & meterModuleStaticSymbols()).text.contains(
      "two modules"
    )
    check rt.register("orch-bad", @[t[0], t[2]]).text.contains("lacks")
    check rt.register("", t).ec == ecInvalidParams
    check rt.register(repeat('b', 129), t).ec == ecInvalidParams
    # Null pointers inside the structure.
    var symbols = @[
      LogosRuntimeNativeSymbol(
        name: nil, address: cast[LogosRuntimeSymbolAddress](orchName)
      )
    ]
    var b = nativeBinding("orch-bad", symbols)
    check runtimeRegisterBinding(rt, addr b).text == "a symbol name is null"
    b = nativeBinding(nil, symbols)
    check runtimeRegisterBinding(rt, addr b).ec == ecInvalidParams
    b = nativeBinding("orch-bad", symbols)
    b.symbols = nil
    check runtimeRegisterBinding(rt, addr b).ec == ecInvalidParams
    # [RUN-0756] None of these was kept: the identifier is still free.
    check rt.register("orch-bad", t).ec == ecOk
    check rt.register("orch-bad", t).text.contains("already registered")
    check runtimeDestroy(rt).ec == ecOk

  test "[LDR-0006] [IMPL-DECISION G246] the Module Loader's binding id cannot be registered":
    let rt = create(deployment())
    let r = rt.register(LoaderBindingId, orchTable())
    check r.ec == ecInvalidParams and "reserved for the Module Loader" in r.text
    check rt.register("orchestrator", orchTable()).ec == ecOk
    check runtimeDestroy(rt).ec == ecOk

  test "[RUN-1085] [RUN-0747] registering runs no module code and creates no instance":
    var c = deployment()
    let rt = registered(c)
    check rt.register("spare", orchTable()).ec == ecOk # never named by a record
    check orchNames.load == 0 and orchInits.load == 0
    check engineOf(rt) == nil
    check runtimeStart(rt).ec == ecOk
    let ids = engineOf(rt).list().mapIt(it.instance)
    # [I89] The Module Loader, established first, is the only other instance.
    check ids == @[LoaderInstanceId, "orch", "meter-1"]
    rt.finish()

  test "[RUN-0749] the table is copied: the caller's storage may change once the call returns":
    let rt = create(deployment())
    var names = orchTable().mapIt(it[0])
    var symbols = newSeq[LogosRuntimeNativeSymbol]()
    for i, (_, p) in orchTable():
      symbols.add(
        LogosRuntimeNativeSymbol(
          name: cstring(names[i]), address: cast[LogosRuntimeSymbolAddress](p)
        )
      )
    var id = "orchestrator"
    var b = nativeBinding(cstring(id), symbols)
    check runtimeRegisterBinding(rt, addr b).ec == ecOk
    for n in names.mitems:
      for ch in n.mitems:
        ch = 'z'
    for s in symbols.mitems:
      s.address = nil
    id[0] = 'x'
    check rt.register("meter", meterModuleStaticSymbols()).ec == ecOk
    check runtimeStart(rt).ec == ecOk
    check rt.state("orch") == msReady
    rt.finish()

  test "[RUN-0758] registration after start, or after a shutdown request, is NOT_READY":
    var rt = registered(deployment())
    check runtimeStart(rt).ec == ecOk
    check rt.register("late", orchTable()).ec == ecNotReady
    rt.finish()
    rt = create(deployment())
    check runtimeRequestShutdown(rt).ec == ecOk
    check rt.register("late", orchTable()).ec == ecNotReady
    check runtimeWaitForShutdown(rt).ec == ecOk
    check runtimeDestroy(rt).ec == ecOk

  test "[RUN-1086] a table without a call symbol the surface needs registers, and its instance fails binding":
    let rt = create(deployment())
    var t = meterModuleStaticSymbols()
    var dropped = false
    var kept: seq[(string, pointer)]
    for e in t:
      if not dropped and "_CALL_" in e[0]:
        dropped = true
      else:
        kept.add(e)
    check dropped
    check rt.register("orchestrator", orchTable()).ec == ecOk
    check rt.register("meter", kept).ec == ecOk
    check runtimeStart(rt).ec == ecOk
    check engineOf(rt).start("meter-1").tryGet.state == msError
    check rt.failureOf("meter-1") == "loader-abi-invalid" # a typed Loader error (I89)
    rt.finish()

# Startup ------------------------------------------------------------------------------

suite "run.host-api: startup (RUNTIME §13.2, l.1640, l.3838-3940) [G191]":
  setup:
    resetOrchestrator()

  test "[RUN-0309] [RUN-0023] [RUN-0784] [RUN-0724] [RUN-0746] [IMPL-DECISION G191] start realizes the orchestration instance only, with intent requested":
    let rt = registered(deployment())
    check runtimeStart(rt).ec == ecOk
    # [I89] The Module Loader is established and ready before orchestration.
    let loader = engineOf(rt).list()[0]
    check loader.instance == LoaderInstanceId and loader.state == msReady
    check loader.intentOrigin.host and not loader.orchestration
    let all = engineOf(rt).list().withoutLoader
    check all.len == 2
    check all[0].instance == "orch" and all[0].state == msReady and all[0].orchestration
    check all[0].intentOrigin.host
    check all[1].instance == "meter-1" and all[1].state == msUnloaded
    check all[1].execution.intent == inUninitialized and not all[1].orchestration
    # What the orchestrator itself observes (G191 interim).
    let rc = cast[ptr LogosRuntimeControlBinding](orchRc.load)
    let g = rc.readiness("test_orchestrator", "orch").get
    check g.execution.get.intent.kind ==
      LogosNSRuntimeControlExecutionStateIntentChoiceKind.Requested
    check g.execution.get.intent_revision == all[0].execution.intentRevision
    check g.execution.get.intent_revision.isSome
    rt.finish()

  test "[RUN-0725] [RUN-0025] with no further host call, the orchestrator starts the deployment by conditional start":
    orchMode.store(ord(omAutostart))
    let rt = registered(deployment(@[sensor()]))
    check runtimeStart(rt).ec == ecOk
    check waitUntil(
      proc(): bool =
        orchThreadDone.load
    )
    check orchResults[0].load == AlreadyRequested # itself: not restarted
    check orchResults[1].load == ord(ecOk)
    check orchResults[2].load == ord(ecOk)
    check orchResults[3].load == StaleAnswer # a stale revision
    check rt.state("meter-1") == msReady
    check rt.state("sensor-1") == msReady # direct_dynamic, verified by its digest
    rt.finish()

  test "[RUN-0757] start is attempted once, and never after a shutdown request":
    var rt = registered(deployment())
    check runtimeStart(rt).ec == ecOk
    check runtimeStart(rt).ec == ecNotReady
    rt.finish()
    rt = registered(deployment())
    check runtimeRequestShutdown(rt).ec == ecOk
    check runtimeStart(rt).ec == ecNotReady
    check engineOf(rt) == nil
    check runtimeWaitForShutdown(rt).ec == ecOk
    check runtimeDestroy(rt).ec == ecOk

  test "[RUN-0759] [RUN-1202] a shutdown accepted before ready is CANCELLED, and stays CANCELLED when the init then fails":
    for fail in [false, true]:
      resetOrchestrator()
      orchMode.store(ord(omShutdown))
      orchFail.store(fail)
      let rt = registered(deployment())
      check runtimeStart(rt).ec == ecCancelled
      check waitUntil(
        proc(): bool =
          orchInitCode.load != -1
      )
      check orchInitCode.load == ord(ecOk) # the request was accepted
      check runtimeWaitForShutdown(rt).ec == ecOk
      check runtimeDestroy(rt).ec == ecOk

  test "[IMPL] R1: a shutdown request overlapping start is accepted, and start is CANCELLED":
    orchGate.store(true)
    let rt = registered(deployment())
    startCode.store(-1)
    var t: Thread[ptr LogosRuntimeHandle]
    createThread(t, startOn, rt)
    check waitUntil(
      proc(): bool =
        orchInits.load == 1
    )
    check runtimeRequestShutdown(rt).ec == ecOk
    check waitUntil(
      proc(): bool =
        startCode.load != -1
    )
    check startCode.load == ord(ecCancelled)
    orchGate.store(false)
    joinThread(t)
    check runtimeWaitForShutdown(rt).ec == ecOk
    check runtimeDestroy(rt).ec == ecOk

  test "[RUN-1201] [RUN-0737] [RUN-0765] a failed start: MODULE_ERROR, TIMEOUT for the startup deadline, or NOT_AUTHORISED; nothing stopped, and the handle shuts down":
    orchFail.store(true)
    var rt = registered(deployment())
    var r = runtimeStart(rt)
    check r.ec == ecModule and "initialization-failed" in r.text
    check rt.state("orch") == msError
    check engineOf(rt).start("meter-1").tryGet.state == msReady # still running
    rt.finish()
    resetOrchestrator()
    orchGate.store(true)
    var c = deployment()
    # [I89] The deadline also bounds the Module Loader's own start, which this
    # test is not about: scaled by `Slow`. The gated init passes it whatever
    # its length.
    c.runtime.startup_deadline_ms = Opt.some(uint32(250 * Slow))
    rt = registered(c)
    r = runtimeStart(rt)
    check r.ec == ecTimeout and "startup-timeout" in r.text
    rt.finish()
    resetOrchestrator()
    rt = registered(deployment())
    rt.setPolicyForTests(
      proc(): AuthzPolicy =
        denying(AuthzRule(action: Opt.some(aaExecute), target: "orch", outcome: azDeny))
    )
    check runtimeStart(rt).ec == ecNotAuthorised
    check orchInits.load == 0
    rt.finish()

  test "[RUN-0682] a dependent that fails to start leaves start OK":
    orchMode.store(ord(omStartBroken))
    let rt = registered(deployment(@[broken()]))
    check runtimeStart(rt).ec == ecOk
    check orchInitCode.load != -1
    check rt.state("broken-1") == msError
    check rt.state("orch") == msReady
    rt.finish()

  test "[IMPL-DECISION G243] [IMPL-DECISION S4] [IMPL] R2: a static binding never registered fails start before any module runs":
    let rt = create(deployment())
    check rt.register("orchestrator", orchTable()).ec == ecOk
    let r = runtimeStart(rt)
    check r.ec == ecInvalidParams
    check "meter-1" in r.text and "meter" in r.text
    # [S4 changed] The engine refuses it once the store is open, since only
    # there is a retained instance told apart (RUNTIME l.1321).
    check orchNames.load == 0 and orchInits.load == 0
    # The attempt is spent: registration is closed and destroy needs a shutdown.
    check rt.register("meter", meterModuleStaticSymbols()).ec == ecNotReady
    check runtimeDestroy(rt).ec == ecNotReady
    check runtimeStart(rt).ec == ecNotReady
    check runtimeRequestShutdown(rt).ec == ecOk
    check runtimeWaitForShutdown(rt).ec == ecOk
    check runtimeDestroy(rt).ec == ecOk

  test "[IMPL-DECISION G243] [IMPL-DECISION G55] a declaration naming a static binding never registered fails start too":
    var c = deployment()
    c.declarations = Opt.some(
      @[
        LcnAppDeclaration(
          module: "spare_module",
          implementation: LcnAppImplementation(
            kind: LcnAppImplementationKind.Direct_static,
            arm_Direct_static: LcnAppImplementationARDirectStaticMap(binding: "spare"),
          ),
        )
      ]
    )
    let rt = registered(c)
    let r = runtimeStart(rt)
    check r.ec == ecInvalidParams
    check "spare_module" in r.text and "spare" in r.text
    check engineOf(rt) == nil and orchNames.load == 0
    check runtimeRequestShutdown(rt).ec == ecOk
    check runtimeWaitForShutdown(rt).ec == ecOk
    check runtimeDestroy(rt).ec == ecOk

  test "[IMPL] the work directory and state root are made private when missing":
    let c = deployment()
    let rt = registered(c)
    check runtimeStart(rt).ec == ecOk
    check dirExists(c.runtime.work_dir) and dirExists(c.runtime.state_root.get)
    when defined(posix):
      check getFilePermissions(c.runtime.work_dir) ==
        {fpUserRead, fpUserWrite, fpUserExec}
    rt.finish()

  test "[I90] [IMPL] with a local-transport rule, the endpoint directory is made private at start; an unsafe one fails start":
    when unixStream:
      let rule = LcnAppRoutingRule(
        callee: "meter_module",
        mode: LcnAppRoutingRuleModeChoice(
          kind: LcnAppRoutingRuleModeChoiceKind.Local_transport
        ),
      )
      # [G58 amended 2026-11-21] The endpoint base must leave `sun_path` room
      # for an endpoint, so the work directories with a rule are short.
      let short =
        makeShortBase("lchost", deepest = "/u/open/12345678/logos_meter_module.sock")
      var c = deployment()
      c.routing = Opt.some(@[rule])
      c.runtime.work_dir = short / "c"
      let rt = registered(c)
      check runtimeStart(rt).ec == ecOk
      let dir = c.runtime.work_dir / "endpoints"
      check dirExists(dir)
      check getFilePermissions(dir) == {fpUserRead, fpUserWrite, fpUserExec}
      rt.finish()
      # Without a rule, no endpoint directory is made.
      let plain = deployment()
      let rt2 = registered(plain)
      check runtimeStart(rt2).ec == ecOk
      check not dirExists(plain.runtime.work_dir / "endpoints")
      rt2.finish()
      # One that others can write to is refused: the start fails, nothing runs.
      var u = deployment()
      u.routing = Opt.some(@[rule])
      u.runtime.work_dir = short / "u"
      let open = u.runtime.work_dir / "open"
      createDir(open)
      check chmod(cstring(open), Mode(0o777)) == 0
      u.runtime.endpoint_dir = Opt.some(open)
      let rt3 = registered(u)
      let r = runtimeStart(rt3)
      checkpoint r.text
      check r.ec == ecModule and "the endpoint directory" in r.text
      check "writable by others" in r.text
      rt3.finish()
      removeDir(short)
    else:
      skip()

# Persistent Runtime state ---------------------------------------------------------------

proc persistent(c: LcnAppConfig, base: string, id = Opt.none(string)): LcnAppConfig =
  ## `c` with the store and state root under `base`, shared by every run.
  result = c
  result.runtime.store_dir = Opt.some(base / "store")
  result.runtime.state_root = Opt.some(base / "state")
  result.runtime.runtime_instance_id = id

proc orchBinding(): ptr LogosRuntimeControlBinding =
  cast[ptr LogosRuntimeControlBinding](orchRc.load)

proc recoverRequest(instance: string, v: InstanceView): seq[byte] =
  encode(
    LogosNSRuntimeControlRecoverModuleRequest(
      module: v.module,
      instance: instance,
      expected_execution_revision: v.execution.revision,
    )
  ).tryGet

proc selfId(): string =
  let rc = cast[ptr LogosRuntimeControlBinding](orchRc.load)
  let (code, response) = rcCall(rc, "get_self", [0xA0'u8])
  check code == ecOk
  LogosNSRuntimeControlGetSelfResponse.decode(response).tryGet.consumer.runtime_instance_id

suite "run.host-api: persistent Runtime state (I82) [G191] [G192]":
  setup:
    resetOrchestrator()

  test "[RUN-0698] [RUN-0646] [RUN-0632] [IMPL-DECISION G191] a restart resumes orchestration; retained intent waits for it":
    let base = work / "restart-1"
    orchMode.store(ord(omAutostart))
    var rt = registered(persistent(deployment(), base))
    check runtimeStart(rt).ec == ecOk
    check waitUntil(
      proc(): bool =
        orchThreadDone.load
    )
    check rt.state("meter-1") == msReady
    let orch1 = engineOf(rt).view("orch").tryGet
    let meter1 = engineOf(rt).view("meter-1").tryGet
    check meter1.intentOrigin.instance == "orch"
    rt.finish()
    resetOrchestrator()
    rt = registered(persistent(deployment(), base))
    check runtimeStart(rt).ec == ecOk
    let orch2 = engineOf(rt).view("orch").tryGet
    check orch2.state == msReady
    check orch2.intentOrigin.host
    check orch2.execution.intentRevision == orch1.execution.intentRevision
    check orch2.execution.revision > orch1.execution.revision
    let meter2 = engineOf(rt).view("meter-1").tryGet
    check meter2.state == msUnloaded
    check meter2.execution.intent == inRequested
    check meter2.intentOrigin.instance == "orch"
    check meter2.execution.intentRevision == meter1.execution.intentRevision
    # The orchestrator resumes it, keeping its origin and intent revision.
    check rcCall(orchBinding(), "recover_module", recoverRequest("meter-1", meter2))[0] ==
      ecOk
    let meter3 = engineOf(rt).view("meter-1").tryGet
    check meter3.state == msReady
    check meter3.intentOrigin.instance == "orch"
    check meter3.execution.intentRevision == meter1.execution.intentRevision
    rt.finish()

  test "[RUN-0698] [RUN-1109] [IMPL-DECISION G191] orchestration stopped before shutdown is started again, with a diagnostic":
    let base = work / "restart-2"
    var rt = registered(persistent(deployment(), base))
    check runtimeStart(rt).ec == ecOk
    let before = engineOf(rt).view("orch").tryGet
    check engineOf(rt).stop("orch").tryGet.state == msUnloaded
    rt.finish()
    rt = registered(persistent(deployment(), base))
    check runtimeStart(rt).ec == ecOk
    let after = engineOf(rt).view("orch").tryGet
    check after.state == msReady and after.intentOrigin.host
    check after.execution.intentRevision.get > before.execution.intentRevision.get
    check engineOf(rt).diagnostics.anyIt("whose intent was stopped" in it)
    rt.finish()

  test "[TXT-0168] [IMPL-DECISION G192] the Runtime's identity is the store's, or the configured one":
    let base = work / "restart-3"
    var rt = registered(persistent(deployment(), base))
    check runtimeStart(rt).ec == ecOk
    let id = selfId()
    check id.len == 36
    rt.finish()
    rt = registered(persistent(deployment(), base))
    check runtimeStart(rt).ec == ecOk
    check selfId() == id
    rt.finish()
    # Another configured identity for this store: refused before anything runs.
    rt = registered(persistent(deployment(), base, Opt.some("rt-other")))
    let r = runtimeStart(rt)
    check r.ec == ecInvalidParams
    check orchInits.load == 2
    rt.finish()
    # A new store takes the configured one.
    rt = registered(persistent(deployment(), work / "restart-4", Opt.some("rt-named")))
    check runtimeStart(rt).ec == ecOk
    check selfId() == "rt-named"
    rt.finish()

  test "[RUN-1103] [TXT-0299] [TXT-0300] [IMPL-DECISION G160] a configured static instance whose declaration changed is not refused: start is OK, its retained record stays, and it remains `unloaded` with `static-binding-mismatch`":
    let base = work / "restart-5"
    orchMode.store(ord(omAutostart))
    var rt = registered(persistent(deployment(), base))
    check runtimeStart(rt).ec == ecOk
    check waitUntil(
      proc(): bool =
        orchThreadDone.load
    )
    check rt.state("meter-1") == msReady
    rt.finish()
    resetOrchestrator()
    var c = persistent(deployment(), base)
    c.modules[1].primary_contract = Opt.some(root(7))
    rt = registered(c)
    check runtimeStart(rt).ec == ecOk
    check orchInits.load == 1
    let v = engineOf(rt).view("meter-1").tryGet
    check v.state == msUnloaded and v.execution.intent == inRequested
    check rt.failureOf("meter-1") == "static-binding-mismatch"
    check v.primaryContract.isNone # the retained record, not the changed one
    let (code, _) =
      rcCall(orchBinding(), "recover_module", recoverRequest("meter-1", v))
    check code == ecNotReady
    check rt.state("meter-1") == msUnloaded
    rt.finish()
    # The same facts again: the same instance is realizable.
    rt = registered(persistent(deployment(), base))
    check runtimeStart(rt).ec == ecOk
    let w = engineOf(rt).view("meter-1").tryGet
    let (again, _) =
      rcCall(orchBinding(), "recover_module", recoverRequest("meter-1", w))
    check again == ecOk
    check rt.state("meter-1") == msReady
    check rt.failureOf("meter-1") == ""
    rt.finish()

  test "[RUN-1103] [RUN-1191] [TXT-0300] a retained instance whose static binding is no longer registered: start is OK, its recovery is NOT_READY with `static-binding-mismatch`, never a `loader-` classification":
    let base = work / "restart-unbound"
    orchMode.store(ord(omAutostart))
    var rt = registered(persistent(deployment(), base))
    check runtimeStart(rt).ec == ecOk
    check waitUntil(
      proc(): bool =
        orchThreadDone.load
    )
    check rt.state("meter-1") == msReady
    rt.finish()
    resetOrchestrator()
    # The next configuration drops meter-1, and its binding is not registered.
    var c = persistent(deployment(), base)
    c.modules = c.modules.filterIt(it.instance != "meter-1")
    rt = create(c)
    check rt.register("orchestrator", orchTable()).ec == ecOk
    check runtimeStart(rt).ec == ecOk
    let v = engineOf(rt).view("meter-1").tryGet
    check v.state == msUnloaded and v.execution.intent == inRequested
    check rt.failureOf("meter-1") == "static-binding-mismatch"
    let (code, _) =
      rcCall(orchBinding(), "recover_module", recoverRequest("meter-1", v))
    check code == ecNotReady
    # [SPEC RUNTIME l.3607] The more specific classification; the Loader is
    # never asked.
    check rt.failureOf("meter-1") == "static-binding-mismatch"
    check rt.state("meter-1") == msUnloaded
    rt.finish()

  test "[RUN-1102] [RUN-1103] [TXT-0300] an implementation incompatible with the retained state, registered under another binding id for a replacement instance: the replacement starts; the retained instance keeps its record, `unloaded` with `static-binding-mismatch`":
    let base = work / "restart-replaced"
    orchMode.store(ord(omAutostart))
    var rt = registered(persistent(deployment(), base))
    check runtimeStart(rt).ec == ecOk
    check waitUntil(
      proc(): bool =
        orchThreadDone.load
    )
    check rt.state("meter-1") == msReady
    rt.finish()
    resetOrchestrator()
    # The deployment registers the new implementation as `meter-v2` and
    # configures the replacement `meter-2` on it; `meter` is not registered,
    # and meter-1 is still configured on it.
    let c = persistent(
      deployment(@[staticModule("meter-2", "meter_module", "meter-v2")]), base
    )
    rt = create(c)
    check rt.register("orchestrator", orchTable()).ec == ecOk
    check rt.register("meter-v2", meterModuleStaticSymbols()).ec == ecOk
    check runtimeStart(rt).ec == ecOk
    let v = engineOf(rt).view("meter-1").tryGet
    check v.state == msUnloaded and v.execution.intent == inRequested
    check rt.failureOf("meter-1") == "static-binding-mismatch"
    let r = engineOf(rt).view("meter-2").tryGet
    check r.state == msUnloaded and r.failure.isNone
    check orchBinding().startModule(
      "meter_module", "meter-2", Opt.some(r.execution.revision)
    ) == ord(ecOk)
    check rt.state("meter-2") == msReady
    check rt.failureOf("meter-2") == ""
    check rt.state("meter-1") == msUnloaded
    check rt.failureOf("meter-1") == "static-binding-mismatch"
    rt.finish()

  test "[IMPL] two handles on one store: the second start is MODULE_ERROR":
    let base = work / "restart-6"
    let a = registered(persistent(deployment(), base))
    check runtimeStart(a).ec == ecOk
    let b = registered(persistent(deployment(), base))
    let r = runtimeStart(b)
    check r.ec == ecModule and "in use" in r.text
    b.finish()
    a.finish()

# Shutdown and destruction -------------------------------------------------------------

suite "run.host-api: shutdown and destruction (RUNTIME §13.2, §10.2) [G60]":
  setup:
    resetOrchestrator()

  test "[RUN-0726] [RUN-0727] [RUN-0728] [RUN-0729] [RUN-0760] [RUN-0705] [RUN-0706] a request accepts at once; a wait initiates nothing; every wait gets the one result":
    let rt = registered(deployment())
    check runtimeStart(rt).ec == ecOk
    waitCode.store(-1)
    var t: Thread[ptr LogosRuntimeHandle]
    createThread(t, waitOn, rt)
    sleep(50)
    check waitCode.load == -1 # waiting alone starts nothing
    check rt.state("orch") == msReady
    orchDestroyGate.store(true)
    check runtimeRequestShutdown(rt).ec == ecOk # returns while the destroy is held
    check runtimeRequestShutdown(rt).ec == ecOk
    sleep(20)
    check waitCode.load == -1
    check runtimeDestroy(rt).ec == ecNotReady # [RUN-0761] not shut down yet
    orchDestroyGate.store(false)
    joinThread(t)
    check waitCode.load == ord(ecOk)
    check runtimeWaitForShutdown(rt).ec == ecOk
    check runtimeWaitForShutdown(rt).ec == ecOk
    check engineOf(rt).view("orch").tryGet.execution.intent == inRequested # kept
    check runtimeDestroy(rt).ec == ecOk

  test "[RUN-0730] a shutdown through Runtime Control is the one a wait sees":
    let rt = registered(deployment())
    check runtimeStart(rt).ec == ecOk
    waitCode.store(-1)
    var t: Thread[ptr LogosRuntimeHandle]
    createThread(t, waitOn, rt)
    let rc = cast[ptr LogosRuntimeControlBinding](orchRc.load)
    check rcCall(rc, "shutdown_runtime", [0xA0'u8])[0] == ecOk
    joinThread(t)
    check waitCode.load == ord(ecOk)
    check runtimeRequestShutdown(rt).ec == ecOk # joins the completed one
    check runtimeDestroy(rt).ec == ecOk

  test "[IMPL-DECISION G60] [RUN-0733] [RUN-0734] cleanup past the grace is MODULE_ERROR; destroy waits for module code and can be retried":
    var c = deployment()
    c.runtime.shutdown_grace_ms = Opt.some(100'u32)
    let rt = registered(c)
    check runtimeStart(rt).ec == ecOk
    check runtimeDestroy(rt).text == "the Runtime has not shut down"
    orchDestroyGate.store(true)
    check runtimeRequestShutdown(rt).ec == ecOk
    let r = runtimeWaitForShutdown(rt)
    check r.ec == ecModule and "orch" in r.text
    check runtimeWaitForShutdown(rt).ec == ecModule
    let refused = runtimeDestroy(rt)
    check refused.ec == ecNotReady and "still running" in refused.text
    check runtimeWaitForShutdown(rt).ec == ecModule # the handle is still valid
    orchDestroyGate.store(false)
    var destroyed = false
    for _ in 0 ..< 10_000:
      if runtimeDestroy(rt).ec == ecOk:
        destroyed = true
        break
      sleep(1)
    check destroyed
    check orchDestroys.load == 1

  test "[RUN-0736] destroy before start, and after a shutdown that had no Runtime":
    var rt = create(deployment())
    check runtimeDestroy(rt).ec == ecOk
    rt = registered(deployment())
    check runtimeRequestShutdown(rt).ec == ecOk
    check runtimeWaitForShutdown(rt).ec == ecOk
    check runtimeDestroy(rt).ec == ecOk

  test "[RUN-0763] [IMPL] R3: a wait from module code is NOT_READY":
    orchMode.store(ord(omWaitProbe))
    let rt = registered(deployment())
    orchHandle.store(rt)
    check runtimeStart(rt).ec == ecOk
    check orchInitCode.load == ord(ecNotReady)
    rt.finish()

  test "100 rounds: a request against a wait on another thread, and destroy retried against completion":
    for _ in 0 ..< 100:
      resetOrchestrator()
      var rt = registered(deployment())
      check runtimeStart(rt).ec == ecOk
      waitCode.store(-1)
      var t: Thread[ptr LogosRuntimeHandle]
      createThread(t, waitOn, rt)
      check runtimeRequestShutdown(rt).ec == ecOk
      joinThread(t)
      check waitCode.load == ord(ecOk)
      check runtimeDestroy(rt).ec == ecOk
      rt = registered(deployment())
      check runtimeStart(rt).ec == ecOk
      check runtimeRequestShutdown(rt).ec == ecOk
      var tries = 0
      while runtimeDestroy(rt).ec != ecOk:
        inc tries
        check tries < 100_000
        if tries >= 100_000:
          break

var
  hookCalls: Atomic[int] ## termination hook calls
  hookNames: Atomic[int] ## how many instances the last call named
  hookData: Atomic[pointer] ## the data the last call carried

proc onTermination(
    data: pointer, unresolved: seq[string]
) {.nimcall, gcsafe, raises: [].} =
  discard hookCalls.fetchAdd(1)
  hookNames.store(unresolved.len)
  hookData.store(data)

suite "run.host-api: the termination hook (RUNTIME l.3823-3824) [IMPL-DECISION G304] [IMPL-DECISION G249]":
  setup:
    resetOrchestrator()
    hookCalls.store(0)
    hookNames.store(0)
    hookData.store(nil)

  test "[IMPL-DECISION G304] a null handle or hook is INVALID_PARAMS; set before start OK; after a start attempt NOT_READY":
    check runtimeSetTerminationHook(nil, onTermination, nil).ec == ecInvalidParams
    let rt = registered(deployment())
    check runtimeSetTerminationHook(rt, nil, nil).ec == ecInvalidParams
    check runtimeSetTerminationHook(rt, onTermination, nil).ec == ecOk
    check runtimeSetTerminationHook(rt, onTermination, nil).ec == ecOk # replaced
    check runtimeStart(rt).ec == ecOk
    let late = runtimeSetTerminationHook(rt, onTermination, nil)
    check late.ec == ecNotReady and late.text == "start was already attempted"
    rt.finish()
    check hookCalls.load == 0

  test "[IMPL-DECISION G304] [IMPL-DECISION G249] a Loader loss calls the hook once with its data; the wait says the host process must end; destroy waits for the confirmation":
    let rt = registered(deployment())
    var marker = 7
    check runtimeSetTerminationHook(rt, onTermination, addr marker).ec == ecOk
    check runtimeStart(rt).ec == ecOk
    check setLoaderFaultsForTests(engineOf(rt), LoaderFaults(reportFailure: true)).isOk
    check waitUntil(
      proc(): bool =
        hookCalls.load == 1
    )
    check hookData.load == cast[pointer](addr marker)
    check hookNames.load >= 1
    orchGate.store(false)
    orchDestroyGate.store(false)
    check runtimeRequestShutdown(rt).ec == ecOk
    let r = runtimeWaitForShutdown(rt)
    check r.ec == ecModule and "the host process must end" in r.text
    let refused = runtimeDestroy(rt)
    check refused.ec == ecNotReady and "the host process must end" in refused.text
    check hookCalls.load == 1
    confirmTerminationForTests(engineOf(rt))
    var destroyed = false
    for _ in 0 ..< 10_000:
      if runtimeDestroy(rt).ec == ecOk:
        destroyed = true
        break
      sleep(1)
    check destroyed
    check hookCalls.load == 1
