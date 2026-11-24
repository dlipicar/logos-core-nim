## logosd's daemon-config and its session (Tier 4b step 4b-6; DECISIONS
## G293-G295, G297, G299, G300, G303, G396, G398; docs/DAEMON.md §2-§9): the
## schema rules of `daemon_config.cddl`, `trust.cddl` and
## `package/trustdoc.cddl`; DAEMON.md §3's checks, in order; the derived host
## configuration for three daemon-configs through the library's own checks;
## the system rules S1-S5 decided by the Capability Authority's own evaluator;
## the trust file's continuity table and logosd's start order over it; the
## `logosctl trust` writers' edits and checks (G397); the evidence key's
## binding and rotation; and `logosctl init`'s session. Tier 5 step N-2b
## adds the `cli` field, the `lcn_call` instance and its rules S6-S8
## (G343-G346). No logosd process and no Runtime: those are `test_logosd`
## (6b) and `test_lcn_call`.

import std/[algorithm, os, sequtils, strutils]
import unittest2
import logos_sdk/cbor
import logos_sdk/base/hex
import logos_sdk/crypto/blake3
import
  ../src/logos_core/daemon/
    [compose, daemon_config_types, evkey, session, sessioninit, trust_types, trustfile]
import ../src/logos_core/runtime/authz
from ../src/logos_core/runtime/store import openStore, close
from ../src/logos_core/runtime/authscopes import evaluateRequest, AuthorityModule
from ../src/logos_core/authority/facts import InstanceFacts, putInstance, putProvider
from logos_sdk/kit/rc_types import LogosNSRuntimeControlRouteAccess, encode
from logos_sdk/cbor/encode import cmpBytes
import logos_sdk/contracts/generated/lcn_storage_fetch_root
from ../src/logos_core/permissions import PermissionSetting, HostAmbient, profileV1
from ../src/logos_core/loader/contract import LoaderInstanceId, LoaderModuleName
from ../src/logos_core/orchestration/settings import OrchestratorModule
import logos_sdk/base/clock
from ../src/logos_core/durable import release, writeAtomic
from ../src/logos_core/cli/lcn_call_configuration_types import
  LcnCallSettings, LcnCallSettingsDeploymentChoiceKind, decode
import ./support/authfixture, logos_sdk/testing/[kitbuild, schemasuite]
from ../src/logos_core/transport/tls/trust import TrustSnapshot, newTrustSnapshot
import ../src/logos_core/remote/carrier_types
from ../src/logos_core/pm/input import MaxReadDeadlineMs
import logos_sdk/iface/accept
import ../src/logos_core/pins as core_pins
from ../src/logos_core/package/resolver import
  ResolverLimits, resolverLimits, `==`, MaxResolverLimits, names, depth, candidates,
  attempts

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

func dq(path: string): string =
  ## `path` inside a diagnostic-notation text string: a Windows path's
  ## backslashes escaped.
  path.replace("\\", "\\\\")

template posixTest(name: string, body: untyped) =
  ## A test of what only a POSIX host has (file modes, links, hosted modules,
  ## POSIX paths): logosd and logosctl run on POSIX hosts only (DAEMON.md).
  test name:
    when defined(posix):
      body
    else:
      skip()

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

proc withState(module, assignment: string): string =
  ## A module entry of `hostedModule` or `staticModule` with a state assignment.
  module[0 ..< module.len - 1] & ", \"state_assignment\": \"" & assignment & "\"}"

proc staticModule(instance, module: string): string =
  "{\"instance\": \"" & instance & "\", \"module\": \"" & module &
    "\", \"implementation\": {\"strategy\": \"direct_static\", \"binding\": \"b\"}}"

let
  prod = TrustFileState(file: floorTrust()) ## the floor: switch off
  dev = TrustFileState(file: LcnPackageTrust(revision: 2, development: true))

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
    "lcn.dc_permissions", "lcn.dc_ctl", "lcn.dc_cli", "lcn.dc_package_manager",
    "lcn.dc_test_hooks", "lcn.dc_test_diagnostics", "lcn.dc_remote",
    "lcn.dc_remote_signing",
  ]
  TrustRules = ["lcn.trust_mark", "lcn.ev_key_binding"]
  TrustdocRules = [
    "lcn.package_trust", "lcn.trust_signing", "lcn.trust_anchor", "lcn.trust_selection",
    "lcn.trust_file",
  ] ## [G396] package/trustdoc.cddl: the trust file, v2 and the v1 still read

let
  dcModel = ruleModel(daemonConfigDocuments())
  dcCodec = codecTable("Lcn", DcRules)
  trustModel = ruleModel(trustDocuments())
  trustCodec = codecTable("Lcn", TrustRules)
  trustdocModel = ruleModel(trustdocDocuments())
  trustdocCodec = codecTable("Lcn", TrustdocRules)

func ownRule(name: string): bool =
  name == "lcn.daemon_config" or name.startsWith("lcn.dc_")

template holds(model: RuleModel, codec: untyped, name: string) =
  let problems = model.checkRule(name, codec)
  for p in problems:
    checkpoint name & ": " & p
  check problems.len == 0

suite "dc.schema: daemon_config.cddl, trust.cddl and package/trustdoc.cddl [IMPL-DECISION G293] [IMPL-DECISION G299] [IMPL-DECISION G396]":
  test "every rule of the three schemas has its test here, and each generated type round-trips":
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
    check trustdocModel.names.len == TrustdocRules.len
    for r in TrustdocRules:
      checkpoint r
      check r in trustdocModel.names
      check trustdocCodec(r, trustdocModel.samples(r)[0]).isSome

  for r in DcRules:
    test r:
      holds(dcModel, dcCodec, r)

  for r in TrustRules:
    test r:
      holds(trustModel, trustCodec, r)

  for r in TrustdocRules:
    test r:
      holds(trustdocModel, trustdocCodec, r)

  test "[BCP-0090] a daemon-config's diagnostic text and its deterministic CBOR round-trip":
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
    for id in [
      OrchestratorInstance, AuthorityInstance, CtlInstance, CliInstance,
      LoaderInstanceId, PmInstance,
    ]:
      checkpoint id
      check refusal(dcText(extra = "\"modules\": [" & hostedModule(id) & "]")) ==
        "modules: instance " & id & " uses a reserved instance id"
    for m in [
      LoaderModuleName, AuthorityModule, CtlModule, CliModule, OrchestratorModule,
      PmModule,
    ]:
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

  test "[IMPL-DECISION I96] check 2: state_transfers names no system instance, and no orchestration.start entry is a transfer source":
    let mods =
      "\"modules\": [" & withState(hostedModule("b"), "b-state") & ", " &
      hostedModule("c") & "]"
    proc transfers(source, target: string): string =
      ", \"state_transfers\": [{\"from\": \"" & source & "\", \"to\": \"" & target &
        "\", \"mode\": \"move\"}]"

    check checked(dcText(extra = mods & transfers("a", "b"))).isOk
    for id in [OrchestratorInstance, AuthorityInstance, CtlInstance, LoaderInstanceId]:
      checkpoint id
      check refusal(dcText(extra = mods & transfers(id, "b"))) ==
        "state_transfers: " & id & " to b names the system instance " & id
      check refusal(dcText(extra = mods & transfers("a", id))) ==
        "state_transfers: a to " & id & " names the system instance " & id
    check refusal(
      dcText(
        extra = mods & transfers("c", "b") & ", \"orchestration\": {\"start\": [\"c\"]}"
      )
    ) == "orchestration.start: c is a state_transfers source, retired at start"

  test "check 3: allow-all needs the development switch":
    let allowAll = dcText(policy = "{\"kind\": \"allow-all\"}")
    check refusal(allowAll) ==
      "policy: allow-all needs the development switch (logosctl trust development on)"
    check checked(allowAll, dev).isOk

  test "[IMPL-DECISION G300] check 3: test_hooks needs a hook build and the development switch, and selects in-process hooks":
    let hooks = dcText(
      extra =
        "\"test_hooks\": {\"ctl_command_delay_ms\": 50, \"loader_failure_after_ms\": 200, " &
        "\"loader_failure_on_file\": \"/tmp/f\", " &
        "\"diagnostics\": {\"text\": \"t\", \"count\": 3}}"
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
    check c.hooks.loaderFailureOnFile == Opt.some("/tmp/f")
    check c.hooks.diagnostics.isSome # [I95 amended 2026-11-16]
    check c.hooks.diagnostics.get.text == "t" and c.hooks.diagnostics.get.count == 3
    let none = checked(dcText(), dev, hooksBuild = true).get
    check none.hooks.ctlCommandDelayMs.isNone and none.hooks.loaderFailureAfterMs.isNone
    check none.hooks.diagnostics.isNone and none.hooks.loaderFailureOnFile.isNone
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

  test "[IMPL-DECISION G344] cli: absolute paths; workers 1 to 32, streams 1 to 64; the timeouts' bounds":
    let d = checked(dcText()).get
    check d.cli.artifact.isNone and d.cli.socketDir == ""
    check d.cli.workers == DefaultCliWorkers and d.cli.streams == DefaultCliStreams
    check d.cli.idleTimeoutMs == DefaultIdleTimeoutMs and
      d.cli.routeIdleMs == DefaultRouteIdleMs
    let art =
      "\"artifact\": {\"id\": \"lcn_call\", \"local_path\": \"/opt/lib/liblcn_call.so\", " &
      "\"hash\": " & Zero32 & ", \"hash_suite\": \"logos.hash-suite.blake3-256\"}"
    let c = checked(
      dcText(
        extra =
          "\"cli\": {" & art & ", \"socket_dir\": \"/run/cli\", \"workers\": 32, " &
          "\"streams\": 64, \"idle_timeout_ms\": 600000, \"route_idle_ms\": 1000}"
      )
    ).get
    check c.cli.artifact.get.local_path == "/opt/lib/liblcn_call.so"
    check c.cli.socketDir == "/run/cli" and c.cli.workers == 32 and c.cli.streams == 64
    check c.cli.idleTimeoutMs == 600000 and c.cli.routeIdleMs == 1000
    check refusal(dcText(extra = "\"cli\": {" & art.replace("/opt/lib/", "") & "}")) ==
      "cli.artifact.local_path must be an absolute path"
    check refusal(dcText(extra = "\"cli\": {\"socket_dir\": \"run\"}")) ==
      "cli.socket_dir must be an absolute path"
    for (field, value, message) in [
      ("workers", "0", "cli.workers must be 1 to 32"),
      ("workers", "33", "cli.workers must be 1 to 32"),
      ("streams", "0", "cli.streams must be 1 to 64"),
      ("streams", "65", "cli.streams must be 1 to 64"),
      ("idle_timeout_ms", "99", "cli.idle_timeout_ms must be 100 to 600000"),
      ("idle_timeout_ms", "600001", "cli.idle_timeout_ms must be 100 to 600000"),
      ("route_idle_ms", "999", "cli.route_idle_ms must be 1000 to 86400000"),
      ("route_idle_ms", "86400001", "cli.route_idle_ms must be 1000 to 86400000"),
    ]:
      checkpoint field & " " & value
      check refusal(dcText(extra = "\"cli\": {\"" & field & "\": " & value & "}")) ==
        message

  test "[IMPL-DECISION G293] [batch E 19] check 4: the store needs the evidence key, whose kid and Runtime match its binding; the store's bounds":
    let s = freshSession()
    let k = createEvidenceKey(s.keysDir, "rt-1").get
    let evidence =
      "\"evidence\": {\"kid\": h'" & k.binding.kid.toHex & "', \"secret_key_file\": \"" &
      dq(k.keyFile) & "\"}"
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
          "', \"secret_key_file\": \"" & dq(k.keyFile) & "\"}}"
      )
    ) == "call_audit.evidence: call_audit.evidence.kid does not match the evidence key"
    check refusal(
      dcText(
        extra =
          "\"call_audit\": {" &
          evidence.replace(dq(k.keyFile), dq(s.keysDir / "none.key")) & "}"
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

# dc.remote --------------------------------------------------------------------------

const RemoteId = "1b4e28ba-2fa1-4d3b-a3f5-ef19a2b0c0de" ## a lowercase UUID version 4

proc remoteText(remote: string, id = RemoteId): string =
  ## A daemon-config for Runtime `id` with `remote` as its `remote` field.
  dcText(extra = "\"remote\": " & remote).replace("\"rt-1\"", "\"" & id & "\"")

suite "dc.remote: the remote section, DAEMON.md §3 check 4 [IMPL-DECISION G407] [IMPL-DECISION G410]":
  test "[RUN-0492] with remote.enabled the Runtime id must be a lowercase canonical UUID version 4; without it, any id":
    let on = checked(remoteText("{\"enabled\": true}"))
    check on.isOk
    if on.isOk:
      check on.get.remote.enabled and on.get.remote.signing == rsLogosd
    const Refused = "runtime.runtime_instance_id must be a lowercase UUID version 4"
    for id in [
      "rt-1", # not a UUID
      "1B4E28BA-2FA1-4D3B-A3F5-EF19A2B0C0DE", # upper case
      "1b4e28ba-2fa1-1d3b-a3f5-ef19a2b0c0de", # version 1
      "1b4e28ba-2fa1-4d3b-c3f5-ef19a2b0c0de", # variant 110
      "1b4e28ba2fa14d3ba3f5ef19a2b0c0de", # not canonical: no hyphens
      "{1b4e28ba-2fa1-4d3b-a3f5-ef19a2b0c0de}", # not canonical: braces
      "1b4e28ba-2fa1-4d3b-a3f5-ef19a2b0c0dg", # not hex
    ]:
      checkpoint id
      check Refused in refusal(remoteText("{\"enabled\": true}", id))
      # The same id without remote, or with it off, is accepted (RUN-0490: any id).
      check checked(remoteText("{\"enabled\": false}", id)).isOk
      check checked(dcText().replace("\"rt-1\"", "\"" & id & "\"")).isOk
    let off = checked(dcText())
    check off.isOk and not off.get.remote.enabled
    for v in ["8", "9", "a", "b"]:
      check isUuidV4("1b4e28ba-2fa1-4d3b-" & v & "3f5-ef19a2b0c0de")
    # init's ids qualify.
    for _ in 0 ..< 32:
      check isUuidV4(newRuntimeId().get)

  posixTest "[IMPL-DECISION G410] signing: logosd by default; key-holder with a checked key_holder program and only then; process-copy in a test build only":
    let holder = freshDir("kh")
    createDir(holder)
    let program = holder / "logos_keyholder"
    writeFile(program, "#!/bin/sh\n")
    setFilePermissions(program, {fpUserRead, fpUserWrite, fpUserExec})
    let kh = checked(
      remoteText(
        "{\"enabled\": true, \"signing\": \"key-holder\", \"key_holder\": \"" &
          dq(program) & "\"}"
      )
    )
    check kh.isOk
    if kh.isOk:
      check kh.get.remote.signing == rsKeyHolder and kh.get.remote.keyHolder == program
    check checked(remoteText("{\"enabled\": true, \"signing\": \"logosd\"}")).isOk
    check "remote.signing \"key-holder\" needs remote.key_holder" in
      refusal(remoteText("{\"enabled\": true, \"signing\": \"key-holder\"}"))
    check "remote.key_holder needs remote.signing \"key-holder\"" in
      refusal(
        remoteText("{\"enabled\": true, \"key_holder\": \"" & dq(program) & "\"}")
      )
    # Checked as runtime.module_host is (checkProgramFile).
    for (path, why) in [
      ("relative/logos_keyholder", "must be an absolute path"),
      (holder / "missing", "does not exist"),
      (holder, "is not a regular file"),
    ]:
      checkpoint path
      check ("remote.key_holder " & why) in
        refusal(
          remoteText(
            "{\"enabled\": true, \"signing\": \"key-holder\", \"key_holder\": \"" &
              dq(path) & "\"}"
          )
        )
    setFilePermissions(program, {fpUserRead, fpUserWrite, fpUserExec, fpGroupWrite})
    check "remote.key_holder is writable by its group or others" in
      refusal(
        remoteText(
          "{\"enabled\": true, \"signing\": \"key-holder\", \"key_holder\": \"" &
            dq(program) & "\"}"
        )
      )
    let copy = dcOf(remoteText("{\"enabled\": true, \"signing\": \"process-copy\"}"))
    check "accepted only by a logosd built for tests" in
      checkRemote(copy, testSigningBuild = false).error
    let accepted = checkRemote(copy, testSigningBuild = true)
    check accepted.isOk and accepted.get.signing == rsProcessCopy

proc tlsAddress(port: int, extra = ""): string =
  "{\"transport\": \"tls-tcp\", \"host\": \"127.0.0.1\", \"port\": " & $port & extra &
    "}"

proc listener(address: string, enabled = false): string =
  "{\"address\": " & address & ", \"enabled\": " & $enabled &
    ", \"runtime_control_enabled\": false}"

proc export1(address: string, provider = "p-x", runtime = ""): string =
  "{\"listener\": " & address & ", \"provider\": {\"provider\": \"" & provider & "\"" &
    (if runtime.len > 0: ", \"runtime_instance_id\": \"" & runtime & "\""
    else: "") & "}, \"enabled\": true}"

proc withRecords(
    listeners: seq[string], exports: seq[string] = @[], enabled = true
): string =
  var r = "{\"enabled\": " & $enabled
  if listeners.len > 0:
    r.add ", \"listeners\": [" & listeners.join(", ") & "]"
  if exports.len > 0:
    r.add ", \"exports\": [" & exports.join(", ") & "]"
  r & "}"

proc prepared(
    diag: string, snapshot = Opt.none(TrustSnapshot)
): Result[Prepared, string] =
  let seen =
    if snapshot.isSome:
      Opt.some(RemoteSeen(snapshot: snapshot.get))
    else:
      Opt.none(RemoteSeen)
  prepareDaemon(Session(dir: freshDir()), dcBytes(diag), prod, remote = seen)

suite "dc.remote: allow-all, listeners and exports [IMPL-DECISION G412] [IMPL-DECISION G415]":
  test "[IMPL-DECISION G415] policy allow-all is refused with remote.enabled, and accepted with it off":
    let on = dcText(
        policy = "{\"kind\": \"allow-all\"}", extra = "\"remote\": {\"enabled\": true}"
      )
      .replace("\"rt-1\"", "\"" & RemoteId & "\"")
    check "policy: allow-all is refused with remote.enabled" in refusal(on, dev)
    check checked(on.replace("\"enabled\": true", "\"enabled\": false"), dev).isOk

  test "[IMPL-DECISION G412] listeners and exports need remote.enabled":
    let a = tlsAddress(7400)
    check "remote.listeners and remote.exports need remote.enabled" in
      refusal(remoteText(withRecords(@[listener(a)], enabled = false)))
    check "remote.listeners and remote.exports need remote.enabled" in
      refusal(remoteText(withRecords(@[], @[export1(a)], enabled = false)))
    check checked(remoteText(withRecords(@[listener(a)], @[export1(a)]))).isOk

  test "[IMPL-DECISION G408] [IMPL-DECISION G412] compose: the snapshot given, else an empty one, and the records as Runtime Control holds them":
    let a = tlsAddress(7400)
    let p = prepared(remoteText(withRecords(@[listener(a)], @[export1(a)]))).get
    let r = p.composition.appConfig.remote.get
    let m = LcnRchMessage.decode(r.snapshot).get
    check m.kind == LcnRchMessageKind.lcn_Rch_snapshot
    check m.arm_lcn_Rch_snapshot.records.len == 0
    check r.listeners.get.len == 1 and r.exports.get.len == 1
    check r.listeners.get[0].address.arm_lcn_Rc_tls_tcp_runtime_address.port == 7400
    let t = newTrustSnapshot(3, [], []).get
    let q = prepared(remoteText("{\"enabled\": true}"), Opt.some(t)).get
    let s = LcnRchMessage.decode(q.composition.appConfig.remote.get.snapshot).get
    check s.arm_lcn_Rch_snapshot.revision == 3
    check q.composition.appConfig.remote.get.listeners.isNone
    # without remote.enabled, no remote section
    check prepared(dcText()).get.composition.appConfig.remote.isNone

  test "[SPEC RUNTIME l.3319-3321] [IMPL-DECISION G412] the records are validated as Runtime Control validates them":
    let a = tlsAddress(7400)
    let b = tlsAddress(7401)
    for (records, why) in [
      (
        withRecords(
          @[listener(tlsAddress(7400, ", \"profile\": \"logos.remote.quic\""))]
        ),
        "an address whose profile its transport does not select",
      ),
      (withRecords(@[listener(a), listener(a)]), "an address is given twice"),
      (withRecords(@[listener(a)], @[export1(b)]), "an export names no listener here"),
      (
        withRecords(
          @[listener(a)],
          @[export1(a, runtime = "7d0e3f1a-9b2c-4a5d-8e6f-1a2b3c4d5e6f")],
        ),
        "an export names another Runtime's provider",
      ),
      (
        withRecords(@[listener(a)], @[export1(a), export1(a)]),
        "an export is given twice",
      ),
      (
        withRecords(@[listener(a, enabled = true)]),
        "an enabled listener needs runtime.remote_program",
      ),
    ]:
      checkpoint why
      let r = prepared(remoteText(records))
      check r.isErr and why in r.error
    # this Runtime's own id on a provider, two exports of one provider on two
    # listeners, and a disabled quic listener are all accepted
    check prepared(
      remoteText(
        withRecords(
          @[
            listener(a),
            listener(b),
            listener(
              "{\"transport\": \"quic\", \"host\": \"127.0.0.1\", \"port\": 7402}"
            ),
          ],
          @[export1(a, runtime = RemoteId), export1(b)],
        )
      )
    ).isOk

  posixTest "[IMPL-DECISION G411] [IMPL-DECISION G412] an enabled listener: tls-tcp with remote_program; quic refused":
    let dir = freshDir("rp")
    createDir(dir)
    let program = dir / "logos_remote"
    writeFile(program, "#!/bin/sh\n")
    setFilePermissions(program, {fpUserRead, fpUserWrite, fpUserExec})
    proc withProgram(records: string): string =
      remoteText(records).replace(
        "{\"runtime_instance_id\": \"" & RemoteId & "\"}",
        "{\"runtime_instance_id\": \"" & RemoteId & "\", \"remote_program\": \"" &
          dq(program) & "\"}",
      )

    let p =
      prepared(withProgram(withRecords(@[listener(tlsAddress(7400), enabled = true)])))
    check p.isOk
    if p.isOk:
      check p.get.composition.appConfig.runtime.remote_program == Opt.some(program)
    let q = prepared(
      withProgram(
        withRecords(
          @[
            listener(
              "{\"transport\": \"quic\", \"host\": \"127.0.0.1\", \"port\": 7402}",
              enabled = true,
            )
          ]
        )
      )
    )
    check q.isErr and "not supported by this Runtime" in q.error
    check "remote_program is writable by its group or others" in (
      block:
        setFilePermissions(program, {fpUserRead, fpUserWrite, fpUserExec, fpGroupWrite})
        let r = prepared(withProgram(withRecords(@[])))
        if r.isOk: "" else: r.error
    )

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

  posixTest "[IMPL-DECISION G343] lcn_call: composed from cli.artifact, hosted, stateless, host-ambient, its settings provisioned, not started":
    # A test logosd is built without the compiled hash: no artifact, no lcn_call.
    check lcnCallArtifactHash.len == 0
    let s = Session(dir: freshDir())
    let none = prepareDaemon(s, dcBytes(dcText()), prod).get
    check CliInstance notin none.composition.appConfig.modules.mapIt(it.instance)
    let host = getAppFilename()
    let text = dcText(
        extra =
          "\"cli\": {\"artifact\": {\"id\": \"lcn_call\", \"local_path\": \"/opt/lib/liblcn_call.so\", " &
          "\"hash\": " & Zero32 &
          ", \"hash_suite\": \"logos.hash-suite.blake3-256\"}, \"workers\": 3, \"route_idle_ms\": 5000}"
      )
      .replace(
        "{\"runtime_instance_id\": \"rt-1\"}",
        "{\"runtime_instance_id\": \"rt-1\", \"module_host\": \"" & host & "\"}",
      )
    for (trust, deployment) in [
      (prod, LcnCallSettingsDeploymentChoiceKind.Production),
      (dev, LcnCallSettingsDeploymentChoiceKind.Non_production),
    ]:
      checkpoint $deployment
      let p = prepareDaemon(s, dcBytes(text), trust).get
      let app = p.composition.appConfig
      check app.modules.mapIt(it.instance) ==
        @[OrchestratorInstance, CtlInstance, CliInstance, AuthorityInstance]
      let m = app.modules[2]
      check m.module == CliModule and m.state_assignment.isNone
      check m.implementation.kind == LcnAppImplementationKind.Process_hosted_dynamic
      check m.implementation.arm_Process_hosted_dynamic.artifact.local_path ==
        "/opt/lib/liblcn_call.so"
      let v = LcnCallSettings.decode(m.provisioned_configuration.get).get
      check v.socket == s.runDir / "lcn_call.sock"
      check v.workers == 3 and v.streams == uint8(DefaultCliStreams)
      check v.route_idle_ms == 5000 and v.idle_timeout_ms == uint32(
        DefaultIdleTimeoutMs
      )
      check v.deployment.kind == deployment
      check p.composition.entryFor(CliModule, CliInstance) == @[HostAmbient & "=a0"]
      # [G343] Not in the start list: the first launcher starts it.
      check CliInstance notin p.composition.orchestrator.defaults.get.mapIt(it.instance)

  posixTest "an operator deployment: hosted modules, their module-level host-ambient, ordering, the start list, restart and audit":
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

  posixTest "[IMPL-DECISION I96] [IMPL-DECISION G306] state_transfers pass through unchanged; the library's own checks apply":
    let s = Session(dir: freshDir())
    let host = getAppFilename()
    proc text(mode: string): string =
      dcText(
        extra =
          "\"modules\": [" & withState(hostedModule("b"), "b-state") &
          "], \"state_transfers\": [{\"from\": \"a\", \"to\": \"b\", \"mode\": \"" & mode &
          "\"}]"
      )
        .replace(
          "{\"runtime_instance_id\": \"rt-1\"}",
          "{\"runtime_instance_id\": \"rt-1\", \"module_host\": \"" & host & "\"}",
        )

    let p = prepareDaemon(s, dcBytes(text("move")), prod).get
    let t = p.composition.appConfig.state_transfers.get
    check t.len == 1
    check t[0].`from` == "a" and t[0].to == "b"
    check t[0].mode.kind == LcnAppStateTransferModeChoiceKind.Move
    let c = prepareDaemon(s, dcBytes(text("copy")), prod).get
    check c.composition.appConfig.state_transfers.get[0].mode.kind ==
      LcnAppStateTransferModeChoiceKind.Copy
    let none = prepareDaemon(s, dcBytes(dcText()), prod).get
    check none.composition.appConfig.state_transfers.isNone

  posixTest "the fifth check: a derived configuration the library refuses is reported as such":
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

  posixTest "[IMPL-DECISION G294] the default module_host: libexec beside the resolved executable, else a sibling, else none":
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
  of CliInstance: CliModule
  of PmInstance: PmModule
  else: "svc"

proc daemonFacts(): SharedFacts =
  result = newSharedFacts(Rt)
  for id in [
    OrchestratorInstance, CtlInstance, AuthorityInstance, LoaderInstanceId, CliInstance,
    "a", "b", "c",
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

proc openPolicy(diag: string, cli = false, pm = Opt.none(PmSettings)): PolicyEnv =
  let dc = dcOf(diag)
  let orch = orchestratorValue(dc).expect("an orchestration value")
  let policy =
    mergedPolicy(dc.policy.arm_Capability_authority, orch, cli, pm).expect("a policy")
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

proc denial(e: PolicyEnv, q: AuthzRequest): DenialKind =
  let req = evaluateRequest(q, Rt).expect("an evaluate request")
  let r = e.a.evaluate(systemCaller(), req)
  doAssert r.kind == LogosNSCapabilityAuthorityEvaluateResponseKind.Map_decision,
    "not a decision"
  let d = r.arm_Map_decision.decision
  doAssert d.denial.isSome, "not a denial"
  d.denial.get.code.kind

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

  test "[IMPL-DECISION G377] the system denials' codes: S2 and S3 deny the consumer, S4 and S5 their named targets":
    var e = openPolicy(policyText())
    check e.denial(eventReq(OrchestratorInstance, "route_state_changed")) ==
      DenialKind.Consumer_denied
    check e.denial(eventReq(CtlInstance, "module_state_changed")) ==
      DenialKind.Consumer_denied
    for target in [LoaderInstanceId, AuthorityInstance, CtlInstance]:
      checkpoint target
      check e.denial(rcReq(CtlInstance, "stop_module", target)) ==
        DenialKind.Target_denied
      check e.denial(execReq(CtlInstance, target)) == DenialKind.Target_denied
    check e.denial(rcReq(CtlInstance, "retire_module", OrchestratorInstance)) ==
      DenialKind.Target_denied
    check e.denial(execReq(CtlInstance, OrchestratorInstance, stop = true)) ==
      DenialKind.Target_denied
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

const CliOperatorRules =
  """[{"kind": "allow", "subject": {"instances": ["lcn_call"]}, "scopes": [{"kind": "runtime-control", "methods": ["get_configuration", "recover_module", "start_module", "stop_module"]}, {"kind": "module-execution", "targets": {}, "actions": ["start", "stop"]}]}]"""

proc cliPolicyText(rules = "[]"): string =
  dcText(
    policy =
      "{\"kind\": \"capability-authority\", \"source\": \"test\", \"rules\": " & rules &
      "}",
    extra =
      "\"modules\": [" & hostedModule("a") & "], \"orchestration\": {\"start\": [\"a\"]}",
  )

suite "dc.policy.cli: lcn_call's system rules S6 to S8 and the events rule [IMPL-DECISION G345] [IMPL-DECISION G346] [IMPL-DECISION G350]":
  test "S6: lcn_call's Runtime Control methods and nothing else the system grants":
    var e = openPolicy(cliPolicyText(), cli = true)
    check e.allows(rcReq(CliInstance, "list_modules"))
    for m in [
      "get_configuration", "start_module", "stop_module", "recover_module",
      "retire_module", "update_configuration", "apply_configuration",
    ]:
      checkpoint m
      check not e.allows(rcReq(CliInstance, m, "a"))
    check not e.allows(rcReq(CliInstance, "shutdown_runtime"))
    e.close()

  test "S7 and the events rule: three events, no other; no execution, with consumer-denied":
    var e = openPolicy(cliPolicyText(), cli = true)
    for ev in ["module_state_changed", "execution_state_changed", "inventory_changed"]:
      checkpoint ev
      check e.allows(eventReq(CliInstance, ev))
    for ev in [
      "route_state_changed", "configuration_state_changed",
      "permission_settings_changed",
    ]:
      checkpoint ev
      check e.denial(eventReq(CliInstance, ev)) == DenialKind.Consumer_denied
    check e.denial(execReq(CliInstance, "a")) == DenialKind.Consumer_denied
    check e.denial(execReq(CliInstance, "a", stop = true)) == DenialKind.Consumer_denied
    e.close()

  test "[plan R7] an operator may grant lcn_call more methods; S7 still refuses every start and stop":
    var e = openPolicy(cliPolicyText(CliOperatorRules), cli = true)
    # The methods are granted; the events rule still holds (a method grant
    # with no event list covers every subscription, and S7 denies the others).
    check e.allows(rcReq(CliInstance, "get_configuration", "a"))
    check e.allows(rcReq(CliInstance, "stop_module", "a"))
    check e.allows(eventReq(CliInstance, "module_state_changed"))
    check e.denial(eventReq(CliInstance, "route_state_changed")) ==
      DenialKind.Consumer_denied
    # A stop or start also needs the execution decision for the requester,
    # which S7 refuses whatever the operator allows: no self-exit (G350).
    for target in ["a", CliInstance]:
      checkpoint target
      check not e.allows(execReq(CliInstance, target, stop = true))
      check not e.allows(execReq(CliInstance, target))
    # [Fable, R7] Recovery is decided on the instance's original starter's
    # execution authority, so a granted recover_module would take effect;
    # lcn_call never calls it.
    check e.allows(rcReq(CliInstance, "recover_module", "a"))
    e.close()

  test "S8: logosctl starts, stops and recovers lcn_call, and may not retire or reconfigure it (target-denied)":
    var e = openPolicy(cliPolicyText(), cli = true)
    for m in ["start_module", "stop_module", "recover_module", "get_configuration"]:
      checkpoint m
      check e.allows(rcReq(CtlInstance, m, CliInstance))
    check e.allows(execReq(CtlInstance, CliInstance, hosted = true))
    check e.allows(execReq(CtlInstance, CliInstance, stop = true))
    for m in ["retire_module", "update_configuration", "apply_configuration"]:
      checkpoint m
      check e.denial(rcReq(CtlInstance, m, CliInstance)) == DenialKind.Target_denied
      check e.allows(rcReq(CtlInstance, m, "a"))
    e.close()

  test "without lcn_call, none of S6 to S8":
    let orch = orchestratorValue(dcOf(cliPolicyText())).get
    check systemRules(orch, cli = true).get.len > systemRules(orch).get.len
    var e = openPolicy(cliPolicyText())
    check not e.allows(rcReq(CliInstance, "list_modules"))
    check e.allows(rcReq(CtlInstance, "retire_module", CliInstance))
    e.close()

# dc.trust ---------------------------------------------------------------------------

proc stateOf(f: LcnPackageTrust): TrustFileState =
  TrustFileState(file: f, digest: @(blake3(f.encode.get)), present: true)

proc input(revision: uint64, development: bool): TrustFileState =
  stateOf(LcnPackageTrust(revision: revision, development: development))

proc markOf(t: TrustFileState): Opt[LcnTrustMark] =
  Opt.some(LcnTrustMark(revision: t.file.revision, digest: t.digest))

proc anchorOf(
    kid: string, names: openArray[string], development = false, key = newSeq[byte](48)
): LcnTrustAnchor =
  LcnTrustAnchor(
    kid: @(kid.toOpenArrayByte(0, kid.high)),
    public_key: key,
    packages: @names,
    development: development,
  )

proc docOf(
    revision: uint64, anchors: openArray[LcnTrustAnchor], development = false
): LcnPackageTrust =
  LcnPackageTrust(
    revision: revision,
    development: development,
    signing: LcnTrustSigning(anchors: @anchors),
  )

proc anchored(revision: uint64, development = false): LcnPackageTrust =
  ## A file with an operator anchor and a development anchor.
  docOf(
    revision,
    [
      anchorOf("dev", ["logos.example"], development = true),
      anchorOf("org", ["logos.storage"]),
    ],
    development,
  )

proc markRevision(s: Session): uint64 =
  readMark(s).get.get.revision

proc setDevelopment(s: Session, on: bool): Result[TrustFileState, string] =
  ## `logosctl trust development on|off` without its lock and output.
  let cur = ?readTrust(s)
  ok((?commitTrust(s, cur, cur.file.withDevelopment(on), @[])).state)

proc current(s: Session): LcnPackageTrust =
  readTrust(s).get.file

proc commit(s: Session, next: LcnPackageTrust): Result[TrustChange, string] =
  ## A `logosctl trust` writer's last step, `next` an edit of the current
  ## file: the session's evidence keys when either file names an anchor.
  let cur = ?readTrust(s)
  var keys: seq[seq[byte]]
  if cur.file.signing.anchors.len > 0 or next.signing.anchors.len > 0:
    keys = ?sessionEvidenceKeys(s)
  commitTrust(s, cur, next, keys)

proc commit(
    s: Session, next: Result[LcnPackageTrust, string]
): Result[TrustChange, string] =
  s.commit(?next)

proc fileBytes(s: Session): string =
  readFile(s.trustPath)

# dc.package_manager ---------------------------------------------------------------

const
  PmBinding = """[{"binding": "main", "instance": "st"}]"""
  PmCatalog =
    """{"storage": "main", "object": h'636174616c6f67', "digest": """ & Zero32 & "}"

  PmArtifactPath = "/opt/pm/liblogos_package_manager.so"
  PmArtifact =
    "{\"id\": \"logos_package_manager\", \"local_path\": \"" & PmArtifactPath &
    "\", \"hash\": " & Zero32 & ", \"hash_suite\": \"logos.hash-suite.blake3-256\"}"

proc pmSection(
    state = "pm",
    storage = PmBinding,
    catalog = PmCatalog,
    extra = "",
    artifact = PmArtifact,
): string =
  ## [G491] The section: the state assignment of the instance logosd composes and,
  ## here, its artifact (a test logosd has no companion library's hash).
  "{\"state\": \"" & state & "\"" &
    (if artifact.len > 0: ", \"artifact\": " & artifact else: "") & ", \"storage\": " &
    storage & ", \"catalog\": " & catalog & (if extra.len > 0: ", " & extra
  else: "") & "}"

proc pmText(
    section = pmSection(), modules = @[hostedModule("st", "storesvc")]
): string =
  dcText(
    extra = "\"modules\": [" & modules.join(", ") & "], \"package_manager\": " & section
  )

proc directModule(instance: string): string =
  "{\"instance\": \"" & instance & "\", \"module\": \"dsvc\", \"implementation\": " &
    "{\"strategy\": \"direct_dynamic\", \"artifact\": {\"id\": \"dsvc\", " &
    "\"local_path\": \"/opt/dsvc/libdsvc.so\", \"hash\": " & Zero32 &
    ", \"hash_suite\": \"logos.hash-suite.blake3-256\"}}}"

proc withHost(text: string): string =
  ## `text` with a `module_host`, which a composed hosted instance needs.
  text.replace(
    "{\"runtime_instance_id\": \"rt-1\"}",
    "{\"runtime_instance_id\": \"rt-1\", \"module_host\": \"" & getAppFilename() & "\"}",
  )

func presetLine(instance: string): string =
  ## The start's log line for logosd's preset (DAEMON.md §3, `package_manager`'s row).
  "package_manager: " & instance & " gets resolver limits partial_closure_names " &
    $PresetPartialClosureNames & ", dependency_depth " & $PresetDependencyDepth &
    ", candidates_per_name " & $PresetCandidatesPerName & ", assignment_attempts " &
    $PresetAssignmentAttempts & " (logosd's preset)"

suite "dc.package_manager: the Package Manager's section, its input and S9 to S11 [IMPL-DECISION G399] [IMPL-DECISION G400] [IMPL-DECISION G402]":
  test "check 2: each refusal names the field it concerns":
    let relative = PmArtifact.replace(PmArtifactPath, "lib/liblogos_package_manager.so")
    for (text, want) in [
      (
        pmText(pmSection(artifact = relative)),
        "package_manager.artifact.local_path must be an absolute path",
      ),
      (pmText(pmSection(storage = "[]")), "package_manager.storage holds no binding"),
      (
        pmText(
          pmSection(
            storage =
              """[{"binding": "main", "instance": "st"}, {"binding": "main", "instance": "st"}]"""
          )
        ),
        "package_manager.storage: binding main is named twice",
      ),
      (
        # [G491] Storage's own-instance check: the composed instance is no provider.
        pmText(
          pmSection(
            storage = """[{"binding": "main", "instance": "package_manager"}]"""
          )
        ),
        "package_manager.storage: binding main names the Package Manager's own instance",
      ),
      (
        pmText(pmSection(storage = """[{"binding": "main", "instance": "zz"}]""")),
        "package_manager.storage: binding main: zz is not an entry of modules",
      ),
      (
        pmText(modules = @[directModule("st")]),
        "package_manager.storage: binding main: st is not hosted_dynamic",
      ),
      (
        pmText(
          pmSection(
            catalog =
              """{"storage": "other", "object": h'63', "digest": """ & Zero32 & "}"
          )
        ),
        "package_manager.catalog.storage: other is not a binding",
      ),
      (
        pmText(pmSection(extra = "\"limits\": {\"read_deadline_ms\": 0}")),
        "package_manager: limits.read_deadline_ms must be 1 to " & $MaxReadDeadlineMs,
      ),
      (
        pmText(
          pmSection(
            extra =
              "\"resolver_limits\": {\"partial_closure_names\": 4097, \"dependency_depth\": 1, " &
              "\"candidates_per_name\": 1, \"assignment_attempts\": 1}"
          )
        ),
        "package_manager: resolver_limits: resolver limit partial_closure_names is above its maximum 4096",
      ),
    ]:
      checkpoint want
      check refusal(text) == want

  test "[ruling C1] resolver_limits holds all four limits or is absent: a partial one fails check 1":
    let text = pmText(
      pmSection(
        extra =
          "\"resolver_limits\": {\"partial_closure_names\": 16, \"dependency_depth\": 15}"
      )
    )
    check decodeDaemonConfig(dcBytes(text)).isErr

  test "[ruling C4] the composed input passes the Package Manager's decoder: a trust state it refuses fails the check":
    var t = floorTrust()
    t.catalog = LcnTrustSelection(selected: Opt.some("logos.catalog.example"))
    check refusal(pmText(), TrustFileState(file: t)).startsWith(
      "package_manager: trust: this implementation supports no catalog profile"
    )

  test "[IMPL-DECISION G443] the preset's relations: attempts at least names, depth below names, each within its maximum":
    let names = int(PresetPartialClosureNames)
    let depth = int(PresetDependencyDepth)
    let candidates = int(PresetCandidatesPerName)
    let attempts = int(PresetAssignmentAttempts)
    # A full closure takes one attempt per name; a path of `names` names has at most
    # `names - 1` edges, so a larger depth limit could never trip (fable-checks §7.1).
    check attempts >= names
    check depth < names
    check names <= MaxResolverLimits.names
    check depth <= MaxResolverLimits.depth
    check candidates <= MaxResolverLimits.candidates
    check attempts <= MaxResolverLimits.attempts
    check resolverLimits(names, depth, candidates, attempts).isOk

  test "[ruling C2] [ruling C3] the preset applies when resolver_limits is absent, and the start line names its origin":
    let c = checked(pmText()).get
    check c.pm.isSome
    let pm = c.pm.get
    check pm.instance == PmInstance
    check pm.state == "pm"
    check pm.artifact.isSome and pm.artifact.get.local_path == PmArtifactPath
    check pm.providers == @["st"]
    check pm.limitsOrigin == loPreset
    let preset = resolverLimits(
      int64(PresetPartialClosureNames),
      int64(PresetDependencyDepth),
      int64(PresetCandidatesPerName),
      int64(PresetAssignmentAttempts),
    )
    check pm.resolverLimits == preset.get
    check pmStartLine(pm) == presetLine(PmInstance)
    let own = checked(
      pmText(
        pmSection(
          extra =
            "\"resolver_limits\": {\"partial_closure_names\": 16, \"dependency_depth\": 15, " &
            "\"candidates_per_name\": 4, \"assignment_attempts\": 1000}"
        )
      )
    ).get.pm.get
    check own.limitsOrigin == loOperator
    check pmStartLine(own) ==
      "package_manager: package_manager gets resolver limits partial_closure_names 16, dependency_depth 15, " &
      "candidates_per_name 4, assignment_attempts 1000 (package_manager.resolver_limits)"

  test "compose: the instance's lcn.pm_input, byte for byte, its only protected input":
    let s = Session(dir: freshDir())
    let p = prepareDaemon(s, dcBytes(withHost(pmText())), prod).get
    let app = p.composition.appConfig
    let expected = dcBytes(
      "{\"trust\": h'" & prod.file.encode.get.toHex &
        "', \"format\": \"logos-core-nim.pm-input.v1\", " & "\"catalog\": " & PmCatalog &
        ", \"storage\": " & PmBinding & ", \"resolver_limits\": {\"dependency_depth\": " &
        $PresetDependencyDepth & ", \"assignment_attempts\": " &
        $PresetAssignmentAttempts & ", \"candidates_per_name\": " &
        $PresetCandidatesPerName & ", \"partial_closure_names\": " &
        $PresetPartialClosureNames & "}}"
    )
    check app.protected_inputs.isSome
    check app.protected_inputs.get.len == 1
    if app.protected_inputs.get.len == 1:
      check app.protected_inputs.get[0].instance == PmInstance
      check app.protected_inputs.get[0].input == expected
    # [G491] The instance logosd composes: hosted in its own process, with the section's
    # state assignment and artifact, no configuration (the input is not configuration),
    # and the host configuration's mark (G490).
    let rec = app.modules.filterIt(it.instance == PmInstance)
    check rec.len == 1
    if rec.len == 1:
      check rec[0].module == PmModule
      check rec[0].configuration.isNone
      check rec[0].state_assignment == Opt.some("pm")
      check rec[0].implementation.kind == LcnAppImplementationKind.Process_hosted_dynamic
      check rec[0].implementation.arm_Process_hosted_dynamic.artifact.local_path ==
        PmArtifactPath
      # Its primary contract, so that the Runtime gives it a provider record: PM App A,
      # computed here from the pinned documents on its own.
      let pmRoot = acceptContractSet(
        core_pins.PackageManagerContractDocument,
        [],
        [
          core_pins.PackageManifestDocument,
          readFile(
            currentSourcePath().parentDir.parentDir /
              "spec/mirrors/CFG/9.configuration-types.cddl"
          ),
        ],
        AcceptOptions(system: true),
      ).tryGet.primary.root
      check rec[0].primary_contract.map(
        proc(c: SchemaCommitment): seq[byte] =
          c.schema_root
      ) == Opt.some(@pmRoot)
    check app.package_manager == Opt.some(PmInstance)
    # Without the section, no instance gets one.
    let plain = prepareDaemon(
      Session(dir: freshDir()),
      dcBytes(
        withHost(
          dcText(extra = "\"modules\": [" & hostedModule("st", "storesvc") & "]")
        )
      ),
      prod,
    ).get
    check plain.composition.appConfig.protected_inputs.isNone

  posixTest "[IMPL-DECISION G491] [PKG-0513] the composed Package Manager: from package_manager.artifact, host-ambient, started by the orchestrator after the operator's list; this logosd, with no compiled hash, refuses a section without the artifact, naming the field; logosctl's checks compose a stand-in":
    # A test logosd is built without the companion library's hash (`pmArtifactHash`):
    # the section must give the artifact. The packaged logosd's own library is checked
    # by the flake's smoke check.
    check pmArtifactHash.len == 0
    let p =
      prepareDaemon(Session(dir: freshDir()), dcBytes(withHost(pmText())), prod).get
    check p.composition.entryFor(PmModule, PmInstance) == @[HostAmbient & "=a0"]
    check p.composition.orchestrator.defaults.get.mapIt(it.instance)[^1] == PmInstance
    let none = prepareDaemon(
      Session(dir: freshDir()),
      dcBytes(withHost(pmText(pmSection(artifact = "")))),
      prod,
    )
    check none.isErr
    if none.isErr:
      check none.error ==
        "package_manager: this logosd has no Package Manager library; give package_manager.artifact"
    # [G343, G491] The companion library's place, beside lcn_call's.
    let exe = getAppFilename()
    let place = (
      expandFilename(exe).parentDir / ".." / "lib" / "logos-core" / PmLibrary
    ).normalizedPath
    check companionLibrary(exe, PmLibrary).get == place
    # logosctl's checks cannot know which logosd starts: they compose a stand-in at
    # the companion's place, with an all-zero digest, and the start decides.
    check not PmCompanion
    let shell = prepareDaemon(
      Session(dir: freshDir()),
      dcBytes(withHost(pmText(pmSection(artifact = "")))),
      prod,
      exe = exe,
      pmCompanion = true,
    )
    check shell.isOk
    if shell.isOk:
      let rec =
        shell.get.composition.appConfig.modules.filterIt(it.instance == PmInstance)
      check rec.len == 1
      if rec.len == 1:
        let a = rec[0].implementation.arm_Process_hosted_dynamic.artifact
        check a.id == PmModule
        check a.local_path == place
        check a.hash == newSeq[byte](32)

  test "[G402] [IMPL-DECISION G491] S9 to S12 with the section: six rules, each provider once, in byte order":
    let orch = orchestratorValue(dcOf(pmText())).get
    let base = systemRules(orch).get
    let two = PmSettings(instance: PmInstance, providers: @["st", "a", "st"])
    let rules = systemRules(orch, pm = Opt.some(two)).get
    check rules.len == base.len + 6
    let added = rules[base.len .. ^1].mapIt(toDiag(it))
    # S9's Runtime Control rule names no target: a list method's decision
    # names none, so a rule with `targets` would never allow list_modules (I86).
    check "\"list_modules\"" in added[0]
    check "\"targets\"" notin added[0]
    check "\"providers\": {\"instances\": [\"a\", \"st\"]}" in added[2]
    check "\"providers\": {\"instances\": [\"a\", \"st\"]}" in added[3]
    check added[4].startsWith(
      "{\"kind\": \"allow\", \"subject\": {\"instances\": [\"a\", \"st\"]}"
    )
    # S12: logosctl may not retire or reconfigure the composed instance.
    check added[5].startsWith("{\"kind\": \"deny\"")
    check "\"target-denied\"" in added[5]
    check "\"modules\": [\"logos_package_manager\"]" in added[5]
    # They are in the policy compose hands the authority.
    let c = checked(pmText()).get
    let s = Session(dir: freshDir())
    let ca = prepareDaemon(s, dcBytes(withHost(pmText())), prod).get.composition.appConfig.policy
    check ca.kind == LcnAppPolicyKind.Capability_authority
    check ca.arm_Capability_authority.policy.rules.len ==
      systemRules(orch, pm = c.pm).get.len

  test "[G402] S9 to S11, decided by the Capability Authority: the routes, calls, readiness event and list_modules, and nothing else":
    # The Package Manager `pm` and its provider `st` (record p-st); `b`'s
    # record p-b also implements lcn.storage_fetch but is no binding.
    let text = pmText()
    var e = openPolicy(text, pm = checked(text).get.pm)
    check e.facts.putInstance(PmInstance, InstanceFacts(module: PmModule)).isOk
    check e.facts.putInstance("st", InstanceFacts(module: "storesvc")).isOk
    check e.facts.putProvider("p-st", "st").isOk
    check e.facts.putProvider("p-b", "b").isOk
    proc rc(operation: string, route = ""): AuthzRequest =
      AuthzRequest(
        action: aaRuntimeControl,
        operation: operation,
        consumer: PmInstance,
        target: route,
        route: route,
      )

    proc fetch(
        action: AuthzAction,
        operation: string,
        declaration: openArray[byte] = [],
        provider = "p-st",
        access: seq[byte] = @[],
    ): AuthzRequest =
      AuthzRequest(
        action: action,
        operation: operation,
        consumer: PmInstance,
        target: provider,
        provider: provider,
        route: "route-1",
        module: "storesvc",
        contract: @LcnStorageFetchRoot,
        declaration: @declaration,
        access: access,
      )

    # The access the Package Manager's establishment asks (pm/shell.nim).
    var methods = @[
      @LcnStorageFetchStatObjectRoot,
      @LcnStorageFetchReadObjectRoot,
      @LcnStorageFetchFetchReadinessRoot,
    ]
    methods.sort(
      proc(a, b: seq[byte]): int =
        cmpBytes(a, b)
    )
    let access =
      LogosNSRuntimeControlRouteAccess(
        methods: Opt.some(methods),
        subscribe_events: Opt.some(@[@LcnStorageFetchReadinessChangedRoot]),
      ).encode.get
    # S9: the Runtime Control methods that hold a route, and list_modules.
    check e.allows(rc("establish_route"))
    check e.allows(rc("renew_route", "route-1"))
    check e.allows(rc("close_route", "route-1"))
    check e.allows(rcReq(PmInstance, "list_modules"))
    # No other Runtime Control method, and no Runtime Control event (S9's deny).
    check not e.allows(rcReq(PmInstance, "list_routes"))
    check not e.allows(rcReq(PmInstance, "shutdown_runtime"))
    check not e.allows(rcReq(PmInstance, "get_readiness", "st"))
    check not e.allows(rcReq(PmInstance, "start_module", "st"))
    for ev in ["module_state_changed", "route_state_changed", "inventory_changed"]:
      checkpoint ev
      check e.denial(eventReq(PmInstance, ev)) == DenialKind.Consumer_denied
    # S9's route and calls, and S10's subscription: to the binding's provider only.
    for p in ["p-st", "p-b"]:
      checkpoint p
      let mine = p == "p-st"
      check e.allows(fetch(aaRoute, "establish_route", provider = p, access = access)) ==
        mine
      check e.allows(fetch(aaRoute, "renew_route", provider = p, access = access)) ==
        mine
      for (name, root) in [
        ("stat_object", LcnStorageFetchStatObjectRoot),
        ("read_object", LcnStorageFetchReadObjectRoot),
        ("fetch_readiness", LcnStorageFetchFetchReadinessRoot),
      ]:
        checkpoint name
        check e.allows(fetch(aaCall, name, root, provider = p)) == mine
      check e.allows(
        fetch(
          aaSubscribeEvent,
          "fetch_readiness_changed",
          LcnStorageFetchReadinessChangedRoot,
          provider = p,
        )
      ) == mine
    # S11: the binding's provider instance publishes that event; no other does.
    proc published(publisher, provider: string): AuthzRequest =
      AuthzRequest(
        action: aaPublishEvent,
        operation: "fetch_readiness_changed",
        consumer: publisher,
        target: PmInstance,
        provider: provider,
        route: "route-1",
        module: "storesvc",
        contract: @LcnStorageFetchRoot,
        declaration: @LcnStorageFetchReadinessChangedRoot,
      )

    check e.allows(published("st", "p-st"))
    check not e.allows(published("b", "p-b"))
    e.close()

  test "[IMPL-DECISION G491] the replaced field: package_manager.instance is refused before the schema, naming state and artifact":
    let text =
      pmText(pmSection().replace("{\"state\"", "{\"instance\": \"pm\", \"state\""))
    check decodeDaemonConfig(dcBytes(text)).error ==
      "package_manager.instance is no longer a field: logosd composes the Package " &
      "Manager itself as the instance package_manager; give package_manager.state (its " &
      "state assignment) and, to override the companion library, package_manager.artifact"

  test "[IMPL-DECISION G490] [IMPL-DECISION G491] an operator logos_ module or declaration is refused; package_manager is not in orchestration.start, and ordering and overrides may name it":
    let st = hostedModule("st", "storesvc")
    check refusal(pmText(modules = @[st, hostedModule("x", "logos_thing")])) ==
      "modules: instance x uses the reserved module-name prefix logos_"
    let decl =
      "{\"module\": \"logos_thing\", \"implementation\": {\"strategy\": \"hosted_dynamic\", " &
      "\"placement\": \"process\", \"artifact\": {\"id\": \"t\", \"local_path\": \"/opt/t/libt.so\", " &
      "\"hash\": " & Zero32 & ", \"hash_suite\": \"logos.hash-suite.blake3-256\"}}}"
    check refusal(dcText(extra = "\"declarations\": [" & decl & "]")) ==
      "declarations: module logos_thing uses the reserved module-name prefix logos_"
    proc withOrchestration(o: string): string =
      dcText(
        extra =
          "\"modules\": [" & st & "], \"package_manager\": " & pmSection() &
          ", \"orchestration\": " & o
      )

    check refusal(withOrchestration("{\"start\": [\"package_manager\"]}")) ==
      "orchestration.start: package_manager is started by logosd itself; it is not listed here"
    check checked(withOrchestration("{\"start\": [\"st\"]}")).isOk
    const off = "{\"kind\": \"disabled\"}"
    check checked(
      withOrchestration(
        "{\"overrides\": [{\"instance\": \"package_manager\", \"restart\": " & off &
          "}]}"
      )
    ).isOk
    let ordered = dcText(
      extra =
        "\"modules\": [" & st & "], \"package_manager\": " & pmSection() &
        ", \"ordering\": [{\"prerequisite\": \"package_manager\", \"dependent\": \"st\"}]"
    )
    check checked(ordered).isOk
    # Without the section there is no such instance to order against.
    check refusal(
      dcText(
        extra =
          "\"modules\": [" & st &
          "], \"ordering\": [{\"prerequisite\": \"package_manager\", \"dependent\": \"st\"}]"
      )
    ) == "ordering: package_manager is not an operator instance in modules"
    # [G491] The orchestrator starts it after the operator's list, with no entry there.
    let orch = orchestratorValue(dcOf(withOrchestration("{\"start\": [\"st\"]}"))).get
    let defaults = orch.defaults.get
    check defaults[^1].module == PmModule and defaults[^1].instance == PmInstance
    check defaults.filterIt(it.instance == "st").len == 1
    check orchestratorValue(dcOf(dcText(extra = "\"modules\": [" & st & "]"))).get.defaults.get
      .filterIt(it.instance == PmInstance).len == 0

  test "[IMPL-DECISION G491] S2 authorizes the orchestrator's start of package_manager from the composed start list; S12: logosctl starts, stops and recovers it, and may not retire or reconfigure it (target-denied)":
    let text = pmText()
    var e = openPolicy(text, pm = checked(text).get.pm)
    check e.facts.putInstance(PmInstance, InstanceFacts(module: PmModule)).isOk
    check e.allows(execReq(OrchestratorInstance, PmInstance, hosted = true))
    for m in ["start_module", "stop_module", "recover_module", "get_configuration"]:
      checkpoint m
      check e.allows(rcReq(CtlInstance, m, PmInstance))
    check e.allows(execReq(CtlInstance, PmInstance, hosted = true))
    check e.allows(execReq(CtlInstance, PmInstance, stop = true))
    for m in ["retire_module", "update_configuration", "apply_configuration"]:
      checkpoint m
      check e.denial(rcReq(CtlInstance, m, PmInstance)) == DenialKind.Target_denied
      check e.allows(rcReq(CtlInstance, m, "a"))
    e.close()

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

  test "[PKG-0418] [PKG-0420] [IMPL-DECISION G396] the decision table again, every file with anchors; two digests at one revision are refused":
    let r2 = stateOf(anchored(2))
    let r3 = stateOf(anchored(3))
    check decide(r2, Opt.none(LcnTrustMark)).error == NotEstablished
    check decide(r3, markOf(r2)).get == cAdvance
    check decide(r2, markOf(r2)).get == cAccept
    check "rollback is refused" in decide(r2, markOf(r3)).error
    var other = anchored(2)
    other.signing.anchors[1].public_key[0] = 1
    check stateOf(other).digest != r2.digest
    check "other contents than the revision recorded" in
      decide(stateOf(other), markOf(r2)).error
    check "other contents than the revision recorded" in
      decide(r2, markOf(stateOf(other))).error

  test "without a file the compiled-in floor applies; a file below it is refused":
    let s = freshSession()
    let t = readTrust(s).get
    check not t.present and t.file == floorTrust()
    check t.file.revision == FloorRevision and not t.file.development
    check t.digest == stateOf(floorTrust()).digest
    check establishTrust(s).error == NotEstablished # logosd never creates a mark
    check writeTrustFile(s, LcnPackageTrust(revision: 0, development: false)).isOk
    check readTrust(s).get.file.revision == 0 # decoded: trust show reads it
    check checkedTrust(s).error ==
      "revision 0 is below the compiled-in floor (revision 1)"
    check establishTrust(s).error == checkedTrust(s).error

  test "init writes the v2 floor at revision 1, or revision 2 with the switch, and its mark; a start accepts the identical replay":
    let s = freshSession()
    let t = initTrust(s, development = false).get
    check t.file == floorTrust() and t.present
    check readTrust(s).get == t
    check readMark(s).get.get.revision == 1
    check establishTrust(s).get.state.digest == t.digest
    let d = freshSession()
    let td = initTrust(d, development = true).get
    check td.file.revision == 2 and td.file.development
    check td.file.signing.anchors.len == 0 and td.file.provenance.selected.isNone
    check readMark(d).get.get.revision == 2

  test "[D27] the switch: each change is the next revision; the mark moves at the next start, before it is used":
    let s = freshSession()
    discard initTrust(s, development = false).get
    let on = setDevelopment(s, true).get
    check on.file.revision == 2 and on.file.development
    check readMark(s).get.get.revision == 1 # offline: the file only
    check establishTrust(s).get.state.file.development
    check readMark(s).get.get == LcnTrustMark(revision: 2, digest: on.digest)
    let off = setDevelopment(s, false).get # a withdrawal
    check off.file.revision == 3 and not off.file.development
    check not establishTrust(s).get.state.file.development
    check readMark(s).get.get.revision == 3

  test "[IMPL-DECISION G137] the switch keeps the anchors, and turning it off withdraws the development anchors":
    let s = freshSession()
    discard initTrust(s, development = false).get
    check writeTrustFile(s, anchored(2, development = true)).isOk
    let on = establishTrust(s).get
    check on.signing.len == 2
    let off = setDevelopment(s, false).get
    check off.file.signing == anchored(2).signing
    let after = establishTrust(s).get
    check after.signing.len == 1
    check after.signing.anchor("org".toOpenArrayByte(0, 2)).isSome
    check after.signing.anchor("dev".toOpenArrayByte(0, 2)).isNone

  test "a changed file at the same revision, and a rollback, are refused; reestablish names the file's revision":
    let s = freshSession()
    discard initTrust(s, development = false).get
    discard setDevelopment(s, true).get
    discard establishTrust(s).get
    check writeTrustFile(s, LcnPackageTrust(revision: 2, development: false)).isOk
    check "other contents" in establishTrust(s).error
    check writeTrustFile(s, LcnPackageTrust(revision: 1, development: false)).isOk
    check "rollback is refused" in establishTrust(s).error
    check reestablish(s, 2, @[]).error == "the trust file is at revision 1, not 2"
    check reestablish(s, 1, @[]).isOk
    check establishTrust(s).isOk
    check readMark(s).get.get.revision == 1

  test "[PKG-0418] [PKG-0420] [TXT-0463] every field is under the revision: one name added, a marker flipped or a key changed at the same revision is refused":
    let s = freshSession()
    discard initTrust(s, development = false).get
    check writeTrustFile(s, anchored(2)).isOk
    check establishTrust(s).isOk
    check s.markRevision == 2
    var oneName = anchored(2)
    oneName.signing.anchors[1].packages.add("logos.wallet")
    var marker = anchored(2)
    marker.signing.anchors[1].development = true
    var key = anchored(2)
    key.signing.anchors[1].public_key[0] = 1
    for (what, f) in [
      ("one name added", oneName), ("a marker flipped", marker), ("a key changed", key)
    ]:
      checkpoint what
      check writeTrustFile(s, f).isOk
      check "other contents than the revision recorded" in establishTrust(s).error
      check s.markRevision == 2
    # The same change at a later revision is accepted (PM l.420).
    oneName.revision = 3
    check writeTrustFile(s, oneName).isOk
    let r = establishTrust(s).get
    check s.markRevision == 3
    check r.signing.authorize("org".toOpenArrayByte(0, 2), "logos.wallet").isOk

  test "[IMPL-DECISION G398] [PKG-0169] [PKG-0166] the start order: a file a rule refuses leaves the mark where it was, before continuity; the accepted selection is the decoded one":
    let s = freshSession()
    discard initTrust(s, development = false).get
    check establishTrust(s).isOk
    var prov = anchored(2)
    prov.provenance.selected = Opt.some("logos.package-provenance.slsa-v1.2")
    var cat = anchored(2)
    cat.catalog.selected = Opt.some("logos.catalog.any")
    var unsorted = anchored(2)
    unsorted.signing.anchors =
      @[unsorted.signing.anchors[1], unsorted.signing.anchors[0]]
    for (what, f, refusal) in [
      (
        "a provenance profile", prov,
        "supports no provenance profile; the file selects \"logos.package-provenance.slsa-v1.2\"",
      ),
      ("a catalog profile", cat, "supports no catalog profile"),
      ("kids out of order", unsorted, "not in strictly ascending kid order"),
    ]:
      checkpoint what
      check writeTrustFile(s, f).isOk
      check readTrust(s).isOk # decoded: trust show and config check read it
      check refusal in checkedTrust(s).error
      check refusal in establishTrust(s).error
      check s.markRevision == 1
      # At the mark's revision the rule refuses it, not continuity.
      var same = f
      same.revision = 1
      check writeTrustFile(s, same).isOk
      check refusal in establishTrust(s).error
      check s.markRevision == 1
    # A profile string written by hand is refused by the schema.
    let v = anchored(2).toCbor
    let signing = v.lookup("signing").get
    signing.entries.keepItIf(it.key.getText != Opt.some("profile"))
    signing.entries.add((cbor("profile"), cbor("logos.package-signing.other")))
    check writeAtomic(s.dir, TrustName, encodeCbor(v)).isOk
    check "does not match lcn.package_trust" in establishTrust(s).error
    check s.markRevision == 1
    # Accepted: the selection is the decoded file's, empty, and nothing else.
    check writeTrustFile(s, anchored(2)).isOk
    let bytes = readFile(s.trustPath)
    let accepted = establishTrust(s).get
    check accepted.state.file == decodeTrust(bytes.toOpenArrayByte(0, bytes.high)).get
    check accepted.state.file.provenance.selected.isNone
    check accepted.state.file.catalog.selected.isNone

  test "the two reads of a start: a change between them is refused before the mark moves":
    let s = freshSession()
    discard initTrust(s, development = false).get
    check writeTrustFile(s, anchored(2)).isOk
    let seen = checkedTrust(s).get
    check writeTrustFile(s, anchored(3)).isOk
    check establishTrust(s, @[], Opt.some(seen.digest)).error ==
      "it changed since the first read of this start"
    check s.markRevision == 1
    check establishTrust(s, @[], Opt.some(checkedTrust(s).get.digest)).isOk
    check s.markRevision == 3

  test "[IMPL-DECISION G396] a Tier 4b v1 file reads as its v2 content with the digest of its own bytes, and keeps its continuity":
    let s = freshSession()
    let v1 = LcnTrustFile(revision: 2, development: true).encode.get
    check writeAtomic(s.dir, TrustName, v1).isOk
    check writeMark(s, TrustFileState(file: input(2, true).file, digest: @(blake3(v1)))).isOk
    let t = readTrust(s).get
    check t.file == LcnPackageTrust(revision: 2, development: true)
    check t.digest == @(blake3(v1)) and t.digest != input(2, true).digest
    check establishTrust(s).get.state.digest == t.digest
    check s.markRevision == 2
    # The first writer writes v2, at the next revision.
    let off = setDevelopment(s, false).get
    let written = readFile(s.trustPath)
    check decodeCbor(written.toOpenArrayByte(0, written.high)).get
      .lookup("format").get.getText == Opt.some(TrustFormat)
    check establishTrust(s).get.state.digest == off.digest
    check s.markRevision == 3

  test "[I114] a session without trust.cbor whose mark holds the Tier 4b floor is refused, naming trust reestablish --revision 1":
    let s = freshSession()
    let v1Floor = LcnTrustFile(revision: 1, development: false).encode.get
    check writeMark(s, TrustFileState(file: floorTrust(), digest: @(blake3(v1Floor)))).isOk
    let r = establishTrust(s)
    check r.isErr
    check "other contents than the revision recorded" in r.error
    check "run logosctl trust reestablish --revision 1" in r.error
    check reestablish(s, 1, @[]).isOk
    check establishTrust(s).isOk
    # An absent file below a higher mark is a rollback.
    check writeMark(s, input(2, false)).isOk
    check "rollback is refused" in establishTrust(s).error

  test "[PKG-0435] an anchor whose key is an evidence key of the session, current or retired, is refused at start":
    let s = freshSession()
    discard initTrust(s, development = false).get
    let old = createEvidenceKey(s.keysDir, "rt-1").get
    let fresh = rotateEvidenceKey(s.keysDir, old.binding.kid, "rt-1").get
    let elsewhere = freshDir("k")
    createDir(elsewhere)
    let outside = createEvidenceKey(elsewhere, "rt-1").get
    let keys = sessionEvidenceKeys(s, outside.keyFile, outside.binding.kid).get
    check keys.len == 3
    for (what, key) in [
      ("retired", old.binding.public_key),
      ("current", fresh.binding.public_key),
      ("configured elsewhere", outside.binding.public_key),
    ]:
      checkpoint what
      check writeTrustFile(s, docOf(2, [anchorOf("org", ["logos.storage"], key = key)])).isOk
      check "is a call-evidence key of this session" in establishTrust(s, keys).error
      check s.markRevision == 1
    check writeTrustFile(s, anchored(2)).isOk
    check establishTrust(s, keys).isOk

  test "[IMPL-DECISION G397] a start reads the evidence keys only when the trust file names an anchor, and an unreadable binding then refuses it":
    let s = freshSession()
    discard initTrust(s, development = false).get
    let k = createEvidenceKey(s.keysDir, "rt-1").get
    let path = s.keysDir / bindingFileName(k.binding.kid)
    removeFile(path)
    writeFile(path, "not a binding")
    check sessionEvidenceKeys(s).isErr
    check startEvidenceKeys(s, checkedTrust(s).get).get.len == 0
    check writeTrustFile(s, anchored(2)).isOk
    check startEvidenceKeys(s, checkedTrust(s).get).isErr
    check s.markRevision == 1

  posixTest "the trust file is a private regular file: group access or a link is refused":
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

# dc.trustctl ------------------------------------------------------------------------

proc kid(t: string): seq[byte] =
  @(t.toOpenArrayByte(0, t.high))

func okDoc(f: LcnPackageTrust): Result[LcnPackageTrust, string] =
  ok(f)

suite "dc.trustctl: the logosctl trust writers over the package trust file [IMPL-DECISION G397]":
  test "[PKG-0418] [TXT-0463] each change is the next revision, one added name included; the file keeps its canonical form and logosd accepts it":
    let s = freshSession()
    discard initTrust(s, development = false).get
    let a = s.commit(
      s.current.withAnchor(
        anchorOf("org", ["logos.storage", "logos.chat", "logos.chat"])
      )
    ).get
    check a.changed and a.state.file.revision == 2
    check a.state.file.signing.anchors[0].packages == @["logos.chat", "logos.storage"]
    var other = newSeq[byte](48)
    other[0] = 1
    let b = s.commit(
      s.current.withAnchor(
        anchorOf("dev", ["logos.example"], development = true, key = other)
      )
    ).get
    check b.state.file.revision == 3
    check b.state.file.signing.anchors.mapIt(it.kid) == @[kid "dev", kid "org"]
    let c = s.commit(s.current.withNames(kid "org", ["logos.wallet"])).get
    check c.changed and c.state.file.revision == 4
    check readTrust(s).get == c.state
    let accepted = establishTrust(s).get
    check s.markRevision == 4
    check accepted.signing.authorize(kid "org", "logos.wallet").isOk
    check accepted.signing.anchor(kid "dev").isNone # the switch is off
    let d = s.commit(s.current.withoutNames(kid "org", ["logos.chat"])).get
    check d.state.file.revision == 5
    check d.state.file.signing.anchors[1].packages == @["logos.storage", "logos.wallet"]
    let e = s.commit(s.current.withoutAnchor(kid "dev")).get
    check e.state.file.revision == 6 and e.state.file.signing.anchors.len == 1
    check establishTrust(s).isOk
    check s.markRevision == 6

  test "[IMPL-DECISION G397] a change that adds or sets what is already so writes nothing: names already present, the same anchor again, the switch as it is":
    let s = freshSession()
    discard initTrust(s, development = false).get
    let org = anchorOf("org", ["logos.storage"])
    discard s.commit(s.current.withAnchor(org)).get
    let before = s.fileBytes
    for (what, next) in [
      ("names already present", s.current.withNames(kid "org", ["logos.storage"])),
      ("the same anchor again", s.current.withAnchor(org)),
      ("the switch as it is", okDoc(s.current.withDevelopment(false))),
    ]:
      checkpoint what
      let r = s.commit(next).get
      check not r.changed and r.state.file.revision == 2
      check s.fileBytes == before
    # Without a file, the floor: nothing is written either.
    let f = freshSession()
    check not f.commit(f.current.withDevelopment(false)).get.changed
    check not fileExists(f.trustPath)

  test "[PKG-0107] [PKG-0072] [PKG-0434] [PKG-0435] the writers' refusals write nothing: a kid already an anchor, an unknown kid, a withdrawal of what is not there, the last name removed, a name or kid out of bounds, a key not of 48 bytes, an evidence key":
    let s = freshSession()
    discard initTrust(s, development = false).get
    let k = createEvidenceKey(s.keysDir, "rt-1").get
    discard s.commit(s.current.withAnchor(anchorOf("org", ["logos.storage"]))).get
    let before = s.fileBytes
    let long = repeat('n', 129)
    var otherKey = newSeq[byte](48)
    otherKey[0] = 1
    for (what, next, refusal) in [
      (
        "a kid already an anchor",
        s.current.withAnchor(anchorOf("org", ["logos.chat"])),
        "is already an anchor",
      ),
      (
        "another key for a kid",
        s.current.withAnchor(anchorOf("org", ["logos.storage"], key = otherKey)),
        "is already an anchor",
      ),
      (
        "names added to an unknown kid",
        s.current.withNames(kid "dev", ["logos.chat"]),
        "no anchor has kid 646576",
      ),
      (
        "names removed from an unknown kid",
        s.current.withoutNames(kid "dev", ["logos.chat"]),
        "no anchor has kid 646576",
      ),
      (
        "an absent anchor removed",
        s.current.withoutAnchor(kid "dev"),
        "no anchor has kid 646576",
      ),
      (
        "an absent name removed",
        s.current.withoutNames(kid "org", ["logos.chat"]),
        "authorizes no package named \"logos.chat\"; no name was removed",
      ),
      (
        "the last name removed",
        s.current.withoutNames(kid "org", ["logos.storage"]),
        "would authorize no package name",
      ),
      ("an empty name", s.current.withNames(kid "org", [""]), "1 to 128 bytes"),
      ("a name of 129 bytes", s.current.withNames(kid "org", [long]), "1 to 128 bytes"),
      (
        "a kid of 129 bytes",
        s.current.withAnchor(anchorOf(long, ["x"])),
        "a kid is 1 to 128 bytes",
      ),
      (
        "no name",
        s.current.withAnchor(anchorOf("new", newSeq[string]())),
        "at least one package",
      ),
      (
        "a key of 47 bytes",
        s.current.withAnchor(anchorOf("new", ["x"], key = newSeq[byte](47))),
        "lcn.package_trust",
      ),
      (
        "an evidence key",
        s.current.withAnchor(anchorOf("new", ["x"], key = k.binding.public_key)),
        "is a call-evidence key of this session",
      ),
    ]:
      checkpoint what
      let r = s.commit(next)
      check r.isErr and refusal in r.error
      check s.fileBytes == before
    # A withdrawal names the kid alone: adding is no answer to it.
    check s.current.withoutAnchor(kid "dev").error == "no anchor has kid 646576"
    check s.current.withoutNames(kid "dev", ["x"]).error == "no anchor has kid 646576"

  test "[IMPL-DECISION G397] remove-names is all or nothing: one name the anchor does not authorize, byte for byte, refuses the change, naming every such name":
    let s = freshSession()
    discard initTrust(s, development = false).get
    let composed = "caf\u00e9"
    discard s.commit(
      s.current.withAnchor(anchorOf("org", ["logos.chat", "logos.storage", composed]))
    ).get
    let before = s.fileBytes
    # Another case, a repeated name, and the decomposed form of a present name.
    let r = s.commit(
      s.current.withoutNames(
        kid "org",
        ["logos.chat", "Logos.Storage", "logos.wallet", "logos.wallet", "cafe\u0301"],
      )
    )
    check r.isErr
    check r.error ==
      "kid " & toHex(kid "org") &
      " authorizes no package named \"Logos.Storage\", \"logos.wallet\", " &
      "cafe\u0301".escape & "; no name was removed"
    check s.fileBytes == before
    check s.current.signing.anchors[0].packages ==
      @[composed, "logos.chat", "logos.storage"]
    # Every name present: removed, the next revision.
    let done = s.commit(s.current.withoutNames(kid "org", ["logos.chat", composed])).get
    check done.changed and done.state.file.revision == 3
    check done.state.file.signing.anchors[0].packages == @["logos.storage"]

  test "[IMPL-DECISION G398] [PKG-0169] [PKG-0435] a file logosd refuses: every writer refuses it and says to correct the file; reestablish writes no mark; a change that removes what is refused is written":
    let s = freshSession()
    discard initTrust(s, development = false).get
    var prov = anchored(2)
    prov.provenance.selected = Opt.some("logos.package-provenance.slsa-v1.2")
    check writeTrustFile(s, prov).isOk
    let before = s.fileBytes
    for (what, next) in [
      ("a change", okDoc(s.current.withDevelopment(true))),
      ("a change that changes nothing", okDoc(s.current.withDevelopment(false))),
      ("an added name", s.current.withNames(kid "org", ["logos.chat"])),
    ]:
      checkpoint what
      let r = s.commit(next)
      check r.isErr
      check "supports no provenance profile; the file selects \"logos.package-provenance.slsa-v1.2\"" in
        r.error
      check r.error.endsWith(CorrectByHand)
      check s.fileBytes == before
    let re = reestablish(s, 2, @[])
    check re.isErr
    check "supports no provenance profile" in re.error
    check re.error.endsWith("; no mark was written")
    check s.markRevision == 1
    # Key separation as well: an anchor written by hand with an evidence key.
    let k = createEvidenceKey(s.keysDir, "rt-1").get
    check writeTrustFile(
      s,
      docOf(
        2,
        [
          anchorOf("bad", ["x"], key = k.binding.public_key),
          anchorOf("org", ["logos.storage"]),
        ],
      ),
    ).isOk
    let keys = sessionEvidenceKeys(s).get
    check "is a call-evidence key" in reestablish(s, 2, keys).error
    check s.markRevision == 1
    # Removing that anchor fixes the file: written, then accepted.
    let fixed = s.commit(s.current.withoutAnchor(kid "bad")).get
    check fixed.changed and fixed.state.file.revision == 3
    check establishTrust(s, keys).isOk
    check s.markRevision == 3

  test "the revision cannot grow past the largest uint64":
    let s = freshSession()
    check writeTrustFile(s, LcnPackageTrust(revision: high(uint64))).isOk
    check s.commit(s.current.withDevelopment(true)).error ==
      "the trust file's revision cannot grow"

# dc.keys ----------------------------------------------------------------------------

suite "dc.keys: the evidence key and its binding to one Runtime [IMPL-DECISION G149] [batch E 19]":
  test "a new key: the secret file 0600, its kid from the public key, its binding":
    let s = freshSession()
    let k = createEvidenceKey(s.keysDir, "rt-1").get
    check k.binding.kid.len == KidBytes
    check k.binding.kid == @(blake3(k.binding.public_key).toOpenArray(0, KidBytes - 1))
    check k.binding.runtime_instance_id == "rt-1" and k.binding.retired_ms.isNone
    check k.keyFile == s.keysDir / keyFileName(k.binding.kid)
    when defined(posix):
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
    when defined(posix):
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
    # [RUNTIME l.2630-2632] init made the Runtime's store, with the id and no
    # instance: logosd never makes one (DAEMON.md §2).
    var (rs, snap) = openStore(s.storeDir).get
    rs.close()
    check snap.isSome
    check snap.get.runtimeInstanceId == r.runtimeId
    check snap.get.instances.len == 0 and snap.get.epoch == 0
    # Another session gets another Runtime id.
    let other = initSession(Session(dir: freshDir()), InitOptions()).get
    check other.runtimeId != r.runtimeId

  posixTest "--development writes revision 2; --config's id is replaced; --module-config reaches the derived configuration":
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
    when defined(posix):
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

  posixTest "[DECISIONS G88] the session directory: the flag, else LOGOSCTL_SESSION_DIR, else HOME/.logos-core; relative paths resolved":
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

  posixTest "run/ is emptied at each start without following a link; work/ is kept":
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

suite "dc.docs: docs/DAEMON.md carries the schemas and the system rules verbatim":
  test "[PKG-0474] every daemon CDDL file, the package trust file's and the launcher's, S1-S12 and logosd's preset of the resolver limits, word for word":
    let root = currentSourcePath().parentDir.parentDir
    let doc = readFile(root / "docs" / "DAEMON.md")
    for name in [
      "daemon/daemon_config.cddl", "daemon/trust.cddl", "package/trustdoc.cddl",
      "daemon/ctl.cddl", "daemon/logosctl.cddl", "daemon/evstore.cddl", "cli/cli.cddl",
      "daemon/remote_trust.cddl",
    ]:
      checkpoint name
      let schema = readFile(root / "src/logos_core" / name)
      check ("```cddl\n" & schema & "```") in doc
    check ("## 3. `" & DaemonConfigFormat & "`") in doc
    let orch = orchestratorValue(defaultDaemonConfig("x")).get
    var listing = "```text\n"
    let base = systemRules(orch).get
    for r in base:
      listing.add(toDiag(r) & "\n")
    check (listing & "```") in doc
    # [G345, G346] S6 to S8, which logosd adds when it composes lcn_call.
    var cli = "```text\n"
    for r in systemRules(orch, cli = true).get[base.len .. ^1]:
      cli.add(toDiag(r) & "\n")
    check (cli & "```") in doc
    # [G402, G491] S9 to S12, which logosd adds with a package_manager section.
    let withCli = systemRules(orch, cli = true).get.len
    let pm = PmSettings(instance: "package_manager", providers: @["storage"])
    var pmRules = "```text\n"
    for r in systemRules(orch, cli = true, pm = Opt.some(pm)).get[withCli .. ^1]:
      pmRules.add(toDiag(r) & "\n")
    check (pmRules & "```") in doc
    # [G399; ruling C2, C3] logosd's preset and the start's log line.
    let preset =
      "`partial_closure_names` " & $PresetPartialClosureNames & ", `dependency_depth` " &
      $PresetDependencyDepth & ", `candidates_per_name` " & $PresetCandidatesPerName &
      " and `assignment_attempts` " & $PresetAssignmentAttempts
    check preset in doc
    check "`package_manager: <instance> gets resolver limits partial_closure_names N, dependency_depth N, candidates_per_name N, assignment_attempts N (logosd's preset)`" in
      doc
