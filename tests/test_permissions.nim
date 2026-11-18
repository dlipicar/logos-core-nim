## Permissions (Tier 4b step 4b-4; DECISIONS I93, G279-G286). Part a: the
## registry and the shipped profile; the Capability Authority's side is the
## `cap.permissions` suite of `test_authority.nim`. Part b, direct mode: an
## instance's settings (RUNTIME §9.3 l.2526-2604), their reconciliation by stop
## and re-realize, restoration, admission (the precheck and the execution
## decision's permission scopes), the installed snapshot, and the event.
##
## The engine suites use the route fixture's client module as the caller of
## Runtime Control and as a target whose `_MODULE_destroy` can be held, the
## slow module as a target never started, and the meter kit module. Every
## instance is provisioned with host-ambient unless a case says otherwise.
## `test_permissions_ca` runs them with a Capability Authority bound (the
## fake one, `support/fakeca`), and adds the cases a decision needs.

import std/[algorithm, atomics, monotimes, os, sequtils, strutils, times, typedthreads]
import unittest2
import ../src/logos_core/runtime/engine
import ../src/logos_core/runtime/[settings, store]
from ../src/logos_core/runtime/authscopes import AuthorityModule, evaluateRequest
from ../src/logos_core/authority/logos_capability_authority_types import toCbor
from ../src/logos_core/authority/scopes import GrantStatusKind
import logos_sdk/abi/types
import logos_sdk/cbor
import logos_sdk/codegen/nimrt
import logos_sdk/commitment
import logos_sdk/iface/[accept, outcome, provider, surface]
import logos_sdk/codegen/common_types
import ../src/logos_core/package/manifest
import ./support/[kitbuild, kitruntime, permfixture]
import ./kit/meter_impl
import ./generated/meter_module_calls

let
  repo = currentSourcePath().parentDir.parentDir
  work =
    repo / "build" / (when declared(caParity): "permissions_ca" else: "permissions") /
    kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

when not declared(caParity):
  suite "perm.registry: definitions and the shipped profile":
    test "[CAP-0083] [IMPL-DECISION G279] every shipped definition names its enforcement component and what happens when it cannot enforce or is revoked":
      let p = profileV1()
      check p.name == ProfileV1
      check checkProfile(p).isOk
      check p.definitions.len == 1
      let d = p.definitions[0]
      check d.name == HostAmbient
      check d.enforcement == epRuntimeAdmission and d.active
      check d.unenforceable == ueFailOperation
      check d.revoked == rvStopExecution
      check d.root == HostAmbientRoot and d.schema == HostAmbientDocument
      check p.minimum == @[ambient()]
      check builtinProfile(ProfileV1).isSome
      check builtinProfile(TestProfileName).isNone
      check builtinProfile("").isNone

    test "[IMPL-DECISION G283] host-ambient stands for every facility class, claims no containment, and its only constraints value is the empty map":
      let p = profileV1()
      let d = p.definitions[0]
      check d.facilities == {
        fcNetwork, fcFilesystem, fcPersistentState, fcProcess, fcDevice, fcResources,
        fcPlacement,
      }
      check not d.containment
      check HostAmbientConstraints == encodeCbor(cborMap())
      check p.validate(HostAmbient, HostAmbientConstraints).isOk
      check p.validate(HostAmbient, encodeCbor(cborMap((cbor("a"), cbor(1))))).error ==
        peInvalid
      check p.validate(HostAmbient, encodeCbor(cbor(0))).error == peInvalid
      check p.validate(HostAmbient, @[0xa0'u8, 0xa0]).error == peInvalid
      check p.validate(HostAmbient, newSeq[byte]()).error == peInvalid

    test "[CAP-0021] containment is the definition's: host-ambient by equality, a quota within a larger one, nothing for an unknown name":
      let t = testProfile()
      check checkProfile(t).isOk
      check t.contained(HostAmbient, HostAmbientConstraints, HostAmbientConstraints)
      check t.contained(Quota, quota(5), quota(10))
      check t.contained(Quota, quota(10), quota(10))
      check not t.contained(Quota, quota(11), quota(10))
      check not t.contained(Quota, @[0xa0'u8], quota(10))
      check not t.contained("lcn-test.other", @[0xa0'u8], @[0xa0'u8])
      check not NoProfile.contained(
        HostAmbient, HostAmbientConstraints, HostAmbientConstraints
      )

    test "[IMPL-DECISION G280] a definition the Module Loader would enforce is inactive; only Runtime admission is active":
      let t = testProfile()
      check t.activeIn(Quota)
      check t.activeIn(HostAmbient)
      check not t.activeIn(Unenforced)
      check not t.activeIn("lcn-test.other")
      check t.defines(Unenforced)

    test "[IMPL] settings: names strictly ascending by UTF-8 bytes, then every name defined and every value conforming":
      let t = testProfile()
      check t.checkSettings(newSeq[PermissionSetting]()).isOk
      check t.checkSettings(@[setting(Quota, quota(1)), ambient()]).isOk
      check t.checkSettings(@[ambient(), setting(Quota, quota(1))]).error == peUnordered
      check t.checkSettings(@[ambient(), ambient()]).error == peUnordered
      check t.checkSettings(@[setting("lcn-test.other", @[0xa0'u8])]).error == peUnknown
      check t.checkSettings(@[setting(Quota, @[0xa0'u8])]).error == peInvalid
      check t.missing(@[setting(Quota, quota(1))]) == @[HostAmbient]
      check t.missing(@[ambient()]).len == 0
      check NoProfile.checkSettings(@[ambient()]).error == peUnknown
      check not NoProfile.selected

    test "[IMPL] a profile breaking its rules is refused":
      var p = testProfile()
      p.definitions = @[p.definitions[2], p.definitions[0]]
      check checkProfile(p).isErr
      p = testProfile()
      p.minimum = @[unenforced()]
      check checkProfile(p).isErr
      p = testProfile()
      p.definitions[0].root = "lcn_test_permissions.nothing"
      check checkProfile(p).isErr
      p = testProfile()
      p.name = ""
      check checkProfile(p).isErr

    test "[IMPL] the settings state: a replacement's status follows what remains of the realization; a settlement only from pending":
      let t = testProfile()
      let s = initialSettings(@[ambient()])
      check s.revision == 1 and s.application == saApplied
      check s.repeats(@[ambient()])
      check not s.repeats(newSeq[PermissionSetting]())
      let running = s.replaced(@[], rmRunning, t)
      check running.revision == 2 and running.application == saPending
      check s.replaced(@[], rmOverrun, t).application == saFailed
      check s.replaced(@[], rmNone, t).application == saApplied
      check s.replaced(@[unenforced()], rmNone, t).application == saFailed
      check running.settled(rmRunning, t).isNone
      check running.settled(rmNone, t) == Opt.some(saApplied)
      check running.settled(rmOverrun, t) == Opt.some(saFailed)
      check s.settled(rmNone, t).isNone
      var failed = s
      failed.application = saFailed
      check not failed.repeats(@[ambient()])
      check failed.toRc.failure == Opt.some("enforcement-failed")
      check s.toRc.failure.isNone
      for x in [s, running, failed]:
        let back = settingsOf(prmBytes(x).tryGet).tryGet
        check back == x
      # [I93] A record breaking the rules the schema cannot express.
      var zero = s
      zero.revision = 0
      check settingsOf(prmBytes(zero).tryGet).isErr

# Set-up -------------------------------------------------------------------------------

proc pconfig(
    policy = allowAll(), entries: seq[InitialSettings] = @[], profile = true
): EngineConfig =
  ## The route fixture's configuration with the test profile selected and every
  ## module provisioned with host-ambient; `entries` come after, and the last
  ## module entry wins, so a case's entry overrides the default.
  result = config(policy)
  if profile:
    result.permissions = testProfile
    for m in ["client_module", "meter_module", "slow_module", AuthorityModule]:
      result.initialSettings.add(InitialSettings(module: m, permissions: @[ambient()]))
    result.initialSettings.add(entries)

proc latestBinding(): ptr LogosRuntimeControlBinding =
  ## The Runtime Control binding of the client module's latest initialization.
  cast[ptr LogosRuntimeControlBinding](clients[(clientInits.load - 1) mod MaxClients].load)

proc target(e: Engine, id: string, runtime = ""): LogosNSRuntimeModuleInstanceAddress =
  LogosNSRuntimeModuleInstanceAddress(
    runtime_instance_id: (if runtime.len > 0: runtime else: e.runtimeInstanceId),
    module_instance_id: id,
  )

proc readSettings(
    rc: ptr LogosRuntimeControlBinding, t: LogosNSRuntimeModuleInstanceAddress
): RcResult =
  rcCall(
    rc,
    "get_permission_settings",
    encode(LogosNSRuntimeControlGetPermissionSettingsRequest(target: t)).tryGet,
  )

proc writeSettings(
    rc: ptr LogosRuntimeControlBinding,
    t: LogosNSRuntimeModuleInstanceAddress,
    revision: uint64,
    xs: seq[PermissionSetting],
): RcResult =
  rcCall(
    rc,
    "update_permission_settings",
    encode(
      LogosNSRuntimeControlUpdatePermissionSettingsRequest(
        target: t, expected_revision: revision, permissions: xs.toRc
      )
    ).tryGet,
  )

type SettingsView = LogosNSRuntimeControlPermissionSettingsState

proc read(r: RcResult): SettingsView =
  check r.code == ecOk
  if r.code == ecOk:
    result =
      LogosNSRuntimeControlGetPermissionSettingsResponse.decode(r.response).tryGet.state

proc written(r: RcResult): SettingsView =
  check r.code == ecOk
  if r.code == ecOk:
    result = LogosNSRuntimeControlUpdatePermissionSettingsResponse.decode(r.response).tryGet.state

func status(s: SettingsView): string =
  ($s.application.kind).toLowerAscii

proc now(rc: ptr LogosRuntimeControlBinding, e: Engine, id: string): SettingsView =
  rc.readSettings(e.target(id)).read

func perms(s: SettingsView): seq[PermissionSetting] =
  fromRc(s.permissions)

proc installed(rc: ptr LogosRuntimeControlBinding): Opt[seq[PermissionSetting]] =
  ## `get_execution_permissions` through `rc`: the snapshot, or none for
  ## `unavailable`.
  let r = rcCall(rc, "get_execution_permissions", [0xA0'u8])
  check r.code == ecOk
  if r.code != ecOk:
    return Opt.none(seq[PermissionSetting])
  let a = LogosNSRuntimeControlGetExecutionPermissionsResponse.decode(r.response).tryGet
  case a.kind
  of LogosNSRuntimeControlGetExecutionPermissionsResponseKind.Available:
    Opt.some(fromRc(a.arm_Available.permissions))
  of LogosNSRuntimeControlGetExecutionPermissionsResponseKind.Unavailable:
    Opt.none(seq[PermissionSetting])

proc recoverBy(rc: ptr LogosRuntimeControlBinding, e: Engine, id: string): RcResult =
  rcCall(
    rc,
    "recover_module",
    encode(
      LogosNSRuntimeControlRecoverModuleRequest(
        module: e.view(id).tryGet.module,
        instance: id,
        expected_execution_revision: e.view(id).tryGet.execution.revision,
      )
    ).tryGet,
  )

proc stateIs(e: Engine, id: string, s: ModuleState): bool =
  waitUntil(
    proc(): bool =
      e.view(id).tryGet.state == s
  )

proc statusIs(rc: ptr LogosRuntimeControlBinding, e: Engine, id, s: string): bool =
  waitUntil(
    proc(): bool =
      rc.now(e, id).status == s
  )

proc executeAnswers(e: Engine, id: string): seq[AuthzAnswer] =
  e.answers().filterIt(it.request.action == aaExecute and it.request.instance == id)

proc client2(e: Engine, id: string): ptr LogosRuntimeControlBinding =
  ## A second client instance `id`, ready; its binding.
  discard e.started(client(), id)
  latestBinding()

func ascending(a, b: seq[byte]): bool =
  ## `a` sorts strictly before `b`, bytewise.
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]:
      return a[i] < b[i]
  a.len < b.len

func lone(): ModuleRecord =
  ## A module no `initial` entry names, which requests host-ambient in its
  ## declaration.
  ModuleRecord(
    module: "lone_module",
    strategy: stDirectStatic,
    binding: "slow",
    requestedPermissions:
      @[RequestedPermission(permission: HostAmbient, constraints: @[0xA0'u8])],
  )

# Settings --------------------------------------------------------------------------------

suite "run.permissions: settings under a selected profile (RUNTIME l.2526-2587)":
  teardown:
    leftover()

  test "[RUN-0893] [RUN-0894] [IMPL-DECISION G110] a new instance's settings: the entry naming it, else its module's, else revision 1 with none; never its requested_permissions":
    let e = fixtureEngine(
      pconfig(
        entries = @[
          InitialSettings(module: "slow_module", instance: "s2", permissions: @[]),
          InitialSettings(
            module: "meter_module",
            instance: "m1",
            permissions: @[setting(Quota, quota(3)), ambient()],
          ),
        ]
      )
    )
    let (_, rc) = e.startClient("c")
    discard e.create(slow(), "s1").tryGet
    discard e.create(slow(), "s2").tryGet
    discard e.create(meter(), "m1").tryGet
    discard e.create(lone(), "l").tryGet
    let s1 = rc.now(e, "s1")
    check s1.revision == 1 and s1.status == "applied" and s1.failure.isNone
    check s1.perms == @[ambient()]
    check rc.now(e, "s2").perms.len == 0
    check rc.now(e, "m1").perms == @[setting(Quota, quota(3)), ambient()]
    let l = rc.now(e, "l")
    check l.revision == 1 and l.status == "applied" and l.failure.isNone
    check l.perms.len == 0
    e.finish()

  test "[RUN-0892] [RUN-0468] an unknown name, invalid constraints, or names out of order or repeated: INVALID_PARAMS without detail, and nothing is saved":
    let e = fixtureEngine(pconfig())
    let (_, rc) = e.startClient("c")
    discard e.create(slow(), "s").tryGet
    for xs in [
      @[setting("lcn-test.other", @[0xA0'u8])],
      @[setting(Quota, @[0xA0'u8])],
      @[setting(HostAmbient, @[0xA1'u8, 0x61, 0x61, 0x01])],
      @[ambient(), setting(Quota, quota(1))],
      @[ambient(), ambient()],
    ]:
      let r = rc.writeSettings(e.target("s"), 1, xs)
      check r.code == ecInvalidParams
      check r.detail.len == 0
    let s = rc.now(e, "s")
    check s.revision == 1 and s.perms == @[ambient()]
    e.finish()

  test "[RUN-0474] a stale expected revision is refused without mutation":
    let e = fixtureEngine(pconfig())
    let (_, rc) = e.startClient("c")
    discard e.create(slow(), "s").tryGet
    check rc.writeSettings(e.target("s"), 5, @[]).code == ecInvalidParams
    check rc.writeSettings(e.target("s"), 1, @[]).written.revision == 2
    let stale = rc.writeSettings(e.target("s"), 1, @[ambient()])
    check stale.code == ecInvalidParams and stale.detail.len == 0
    check rc.now(e, "s").revision == 2
    check rc.now(e, "s").perms.len == 0
    e.finish()

  test "[RUN-0475] repeating applied settings returns the existing state: no update, no restart":
    let e = fixtureEngine(pconfig())
    let (_, rc) = e.startClient("c")
    discard e.started(slow(), "t")
    let before = e.view("t").tryGet
    let s = rc.writeSettings(e.target("t"), 1, @[ambient()]).written
    check s.revision == 1 and s.status == "applied"
    let after = e.view("t").tryGet
    check after.state == msReady
    check after.execution.revision == before.execution.revision
    e.finish()

  test "[RUN-0470] [RUN-0471] [RUN-0890] [RUN-0476] [IMPL-DECISION G281] with no realization a replacement applies at once, or fails for a definition no active point enforces; the revision advances per replacement only":
    let e = fixtureEngine(pconfig())
    let (_, rc) = e.startClient("c")
    discard e.create(slow(), "s").tryGet
    let a =
      rc.writeSettings(e.target("s"), 1, @[setting(Quota, quota(2)), ambient()]).written
    check a.revision == 2 and a.status == "applied"
    check a.failure.isNone
    let f = rc.writeSettings(e.target("s"), 2, @[unenforced(), ambient()]).written
    check f.revision == 3 and f.status == "failed"
    check f.failure == Opt.some("enforcement-failed")
    # [R7] The failed replacement of an `unloaded` instance is its failure.
    check e.view("s").tryGet.failure.get.kind == fkPermissionEnforcementFailed
    check rc.now(e, "s").revision == 3
    # [RUN-0476] A retry of the failed array is a new replacement.
    let retry = rc.writeSettings(e.target("s"), 3, @[unenforced(), ambient()]).written
    check retry.revision == 4 and retry.status == "failed"
    let ok = rc.writeSettings(e.target("s"), 4, @[ambient()]).written
    check ok.revision == 5 and ok.status == "applied" and ok.failure.isNone
    e.finish()

  test "[RUN-0910] a target on another Runtime: INVALID_PARAMS without detail":
    let e = fixtureEngine(pconfig())
    let (_, rc) = e.startClient("c")
    discard e.create(slow(), "s").tryGet
    const Foreign = "00000000-0000-4000-8000-000000000000"
    let g = rc.readSettings(e.target("s", Foreign))
    check g.code == ecInvalidParams and g.detail.len == 0
    let u = rc.writeSettings(e.target("s", Foreign), 1, @[])
    check u.code == ecInvalidParams and u.detail.len == 0
    check rc.now(e, "s").revision == 1
    e.finish()

  test "[RUN-0473] [RUN-0481] settings authority is per method and target: it changes no intent, and grants no start":
    # The internal policy's rules decide, in the parity pass too.
    let e = fixtureEngine(
      pconfig(
        denying(
          deny(
            action = Opt.some(aaLifecycle),
            operation = "update_permission_settings",
            consumer = "c",
            target = "y",
          ),
          deny(
            action = Opt.some(aaLifecycle),
            operation = "start_module",
            consumer = "c",
            target = "x",
          ),
        )
      )
    )
    let (_, rc) = e.startClient("c")
    discard e.create(slow(), "x").tryGet
    discard e.create(slow(), "y").tryGet
    let before = e.view("x").tryGet
    check rc.writeSettings(e.target("y"), 1, @[]).code == ecNotAuthorised
    check rc.now(e, "y").revision == 1
    check rc.writeSettings(e.target("x"), 1, @[]).written.revision == 2
    let after = e.view("x").tryGet
    check after.execution.intent == inUninitialized
    check after.execution.revision == before.execution.revision
    check rc.lifecycle("start_module", "slow_module", Opt.some("x")).code ==
      ecNotAuthorised
    check e.view("x").tryGet.execution.intent == inUninitialized
    e.finish()

  test "[IMPL-DECISION G253] the Module Loader holds the profile's minimum by its construction, and an update aimed at it while bound is NOT_READY":
    let e = fixtureEngine(pconfig())
    let (_, rc) = e.startClient("c")
    let s = rc.now(e, LoaderInstanceId)
    check s.revision == 1 and s.status == "applied"
    check s.perms == @[ambient()]
    let r = rc.writeSettings(e.target(LoaderInstanceId), 1, @[])
    check r.code == ecNotReady
    check rc.now(e, LoaderInstanceId).revision == 1
    e.finish()

# Reconciliation --------------------------------------------------------------------------

suite "run.permissions: reconciliation by stop and re-realize (RUNTIME l.2590-2601)":
  teardown:
    leftover()

  test "[RUN-0914] [RUN-1066] [RUN-0912] [RUN-0916] [RUN-0917] [RUN-0475] narrowing a running instance: pending while its stop runs, then unloaded with no failure, intent and origin kept, then applied":
    let e = fixtureEngine(pconfig())
    let (_, rc) = e.startClient("c")
    let t = e.client2("t")
    let origin = e.view("t").tryGet.intentOrigin
    clientDestroyGate.store(true)
    let p = rc.writeSettings(e.target("t"), 1, @[]).written
    check p.revision == 2 and p.status == "pending"
    # [RUN-0917] The stop began before the reply, and with it the realization
    # lost its admission: `pending` is no grace period.
    check e.view("t").tryGet.state == msStopping
    check rcCall(t, "get_execution_permissions", [0xA0'u8]).code == ecNotReady
    # [RUN-0475] Repeating pending settings: the state, no second stop.
    let again = rc.writeSettings(e.target("t"), 2, @[]).written
    check again.revision == 2 and again.status == "pending"
    # [RUN-0916] Not `applied` before absence is established.
    sleep(50 * Slow)
    check rc.now(e, "t").status == "pending"
    clientDestroyGate.store(false)
    check e.stateIs("t", msUnloaded)
    check rc.statusIs(e, "t", "applied")
    let v = e.view("t").tryGet
    check v.failure.isNone
    check v.execution.intent == inRequested
    check v.intentOrigin == origin
    check rc.now(e, "t").revision == 2
    e.finish()

  test "[RUN-0911] [RUN-0913] [RUN-0915] [RUN-0912] [RUN-0909] [IMPL-DECISION G217] widening stops the instance too; the engine does not restart it, and its recovery is decided with the widened scopes":
    let e = fixtureEngine(pconfig())
    let (_, rc) = e.startClient("c")
    let t = e.client2("t")
    check t.installed == Opt.some(@[ambient()])
    let wide = @[setting(Quota, quota(10)), ambient()]
    check rc.writeSettings(e.target("t"), 1, wide).written.status == "pending"
    check e.stateIs("t", msUnloaded)
    check rc.statusIs(e, "t", "applied")
    sleep(50 * Slow)
    check e.view("t").tryGet.state == msUnloaded # [RUN-0915]
    let before = e.executeAnswers("t").len
    check rc.recoverBy(e, "t").code == ecOk
    check e.stateIs("t", msReady)
    let asked = e.executeAnswers("t")
    check asked.len == before + 1
    if asked.len > 0:
      check asked[^1].request.permissions == wide
    # [RUN-0909] The new realization sees its own snapshot.
    check latestBinding().installed == Opt.some(wide)
    e.finish()

  test "[RUN-0479] [RUN-0890] [RUN-0480] [RUN-0476] [RUN-0469] [RUN-0917] [IMPL-DECISION G285] [IMPL-DECISION G284] a reconciliation stop past its deadline: failed, the instance stopped; the late cleanup restores nothing; a start is refused until an accepted replacement applies":
    var cfg = pconfig()
    cfg.stopDeadline = PassingStop
    let e = fixtureEngine(cfg)
    let (_, rc) = e.startClient("c")
    discard e.client2("t")
    clientDestroyGate.store(true)
    check rc.writeSettings(e.target("t"), 1, @[]).written.status == "pending"
    # [RUN-0917] No grace period: the stop deadline applies as to any stop.
    check e.stateIs("t", msError)
    check e.view("t").tryGet.failure.get.kind == fkCleanupTimeout
    check rc.statusIs(e, "t", "failed")
    let f = rc.now(e, "t")
    check f.revision == 2 and f.failure == Opt.some("enforcement-failed")
    check f.perms.len == 0 # [RUN-0479] the saved settings are kept
    # [G285] A replacement while the old realization may persist fails at once.
    let late = rc.writeSettings(e.target("t"), 2, @[ambient()]).written
    check late.revision == 3 and late.status == "failed"
    clientDestroyGate.store(false)
    check waitUntil(
      proc(): bool =
        not e.cleanupPending("t")
    )
    # [RUN-0480] The cleanup's end leaves it failed and the instance stopped.
    sleep(50 * Slow)
    check rc.now(e, "t").status == "failed"
    check e.view("t").tryGet.state == msError
    let refused = e.start("t")
    check refused.isErr and refused.error.code == ecNotAuthorised
    let v = e.view("t").tryGet
    check v.failure.get.kind == fkPermissionEnforcementFailed
    check v.execution.intent == inRequested
    # [RUN-0476] The retry of the failed array advances the revision and
    # applies; without host-ambient the start is still refused (RUN-0469).
    let retry = rc.writeSettings(e.target("t"), 3, @[ambient()]).written
    check retry.revision == 4 and retry.status == "applied"
    let none = rc.writeSettings(e.target("t"), 4, @[]).written
    check none.revision == 5 and none.status == "applied"
    let denied = e.start("t")
    check denied.isErr and denied.error.code == ecNotAuthorised
    check e.view("t").tryGet.failure.get.kind == fkAuthorityDenied
    check rc.writeSettings(e.target("t"), 5, @[ambient()]).written.status == "applied"
    check e.start("t").tryGet.state == msReady
    e.finish()

  test "[RUN-0891] [IMPL-DECISION G281] a resumption that fails after the settings applied is an execution failure; the settings stay applied":
    let e = fixtureEngine(pconfig())
    let (_, rc) = e.startClient("c")
    discard e.started(slow(), "s")
    check rc.writeSettings(e.target("s"), 1, @[setting(Quota, quota(1)), ambient()]).code ==
      ecOk
    check e.stateIs("s", msUnloaded)
    check rc.statusIs(e, "s", "applied")
    # Only the resumption is bounded by the short deadline: the starts before
    # it, the parity pass's authority among them, are not this case.
    check e.setStartupDeadlineForTests(PassingStop).isOk
    slowGate.store(true)
    let r = e.recover("s", e.view("s").tryGet.execution.revision)
    check r.isOk and r.get.state == msError
    check e.view("s").tryGet.failure.get.kind == fkStartupTimeout
    let s = rc.now(e, "s")
    check s.revision == 2 and s.status == "applied" and s.failure.isNone
    slowGate.store(false)
    e.finish()

  test "[RUN-0478] reconciliation completes without the caller that asked for it":
    let e = fixtureEngine(pconfig())
    let (_, rc) = e.startClient("c")
    discard e.started(meter(), "m")
    check rc.writeSettings(e.target("m"), 1, @[]).code == ecOk
    check e.stop("c").isOk
    check e.stateIs("m", msUnloaded)
    let (_, rc2) = e.startClient("c2")
    check rc2.statusIs(e, "m", "applied")
    check e.view("m").tryGet.failure.isNone
    e.finish()

  test "[IMPL-DECISION G281] a running instance given a definition no active point enforces: pending, then failed once it is stopped, with its failure set":
    let e = fixtureEngine(pconfig())
    let (_, rc) = e.startClient("c")
    discard e.started(slow(), "s")
    check rc.writeSettings(e.target("s"), 1, @[unenforced(), ambient()]).written.status ==
      "pending"
    check e.stateIs("s", msUnloaded)
    check rc.statusIs(e, "s", "failed")
    check e.view("s").tryGet.failure.get.kind == fkPermissionEnforcementFailed
    check e.view("s").tryGet.execution.intent == inRequested
    e.finish()

# Restart ----------------------------------------------------------------------------------

when not declared(caParity):
  # The parity pass has no persistent case: its authority instance is created
  # by `fixtureEngine`, which opens no store.
  var stores = 0

  proc storeConfig(entries: seq[InitialSettings] = @[], profile = true): EngineConfig =
    ## The case's store, under the store's own Runtime identity.
    result = pconfig(entries = entries, profile = profile)
    result.runtimeInstanceId = ""
    result.storeDir = Opt.some(work / ("store" & $stores))

  proc reopened(cfg: EngineConfig): Result[Engine, EngineError] =
    result = openEngine(cfg)
    if result.isOk:
      live = result.get

  proc persistent(cfg: EngineConfig): Engine =
    reopened(cfg).tryGet

  proc putPrm(dir, id: string, s: SettingsState) =
    ## Writes `id`'s side record into a closed store, as a crash would have
    ## left it.
    var (st, _) = openStore(dir).tryGet
    st.putSide(PrmSide, id, prmBytes(s).tryGet).tryGet
    st.close()

  proc getPrm(dir, id: string): Opt[seq[byte]] =
    var (st, _) = openStore(dir).tryGet
    result = st.getSide(PrmSide, id).tryGet
    st.close()

  suite "run.permissions: restoration (RUNTIME l.2541-2544, l.2590, l.2637)":
    setup:
      inc stores
    teardown:
      leftover()

    test "[RUN-0477] [RUN-0895] a replacement is saved before its reply and survives a restart, failed included":
      let cfg = storeConfig()
      var e = persistent(cfg)
      let (_, rc) = e.startClient("c")
      discard e.create(slow(), "a").tryGet
      discard e.create(slow(), "b").tryGet
      let a0 =
        rc.writeSettings(e.target("a"), 1, @[setting(Quota, quota(7)), ambient()])
      check a0.written.revision == 2
      check rc.writeSettings(e.target("b"), 1, @[unenforced()]).written.status ==
        "failed"
      e.finish()
      e = persistent(cfg)
      check e.start("c").tryGet.state == msReady # restored
      let rc2 = latestBinding()
      let a = rc2.now(e, "a")
      check a.revision == 2 and a.status == "applied"
      check a.perms == @[setting(Quota, quota(7)), ambient()]
      let b = rc2.now(e, "b")
      check b.revision == 2 and b.status == "failed"
      check b.failure == Opt.some("enforcement-failed")
      e.finish()

    test "[RUN-0478] [RUN-0895] [IMPL-DECISION G281] settings pending when the Runtime ended settle at the next open, at the same revision: applied, or failed for an inactive definition":
      let cfg = storeConfig()
      var e = persistent(cfg)
      discard e.create(slow(), "a").tryGet
      discard e.create(slow(), "b").tryGet
      e.finish()
      let dir = cfg.storeDir.get
      putPrm(
        dir,
        "a",
        SettingsState(revision: 4, permissions: @[ambient()], application: saPending),
      )
      putPrm(
        dir,
        "b",
        SettingsState(revision: 6, permissions: @[unenforced()], application: saPending),
      )
      e = persistent(cfg)
      let (_, rc) = e.startClient("c")
      let a = rc.now(e, "a")
      check a.revision == 4 and a.status == "applied"
      let b = rc.now(e, "b")
      check b.revision == 6 and b.status == "failed"
      check e.view("b").tryGet.failure.get.kind == fkPermissionEnforcementFailed
      e.finish()
      # Written back: the record itself settled.
      check settingsOf(getPrm(dir, "a").get).tryGet.application == saApplied

    test "[RUN-0895] [RUN-0894] a changed initial entry does not touch a restored instance; one created without a profile opens with the default":
      var e = persistent(storeConfig(profile = false))
      discard e.create(slow(), "old").tryGet
      e.finish()
      e = persistent(storeConfig())
      discard e.create(slow(), "a").tryGet
      let (_, rc) = e.startClient("c")
      let old = rc.now(e, "old")
      check old.revision == 1 and old.perms.len == 0 and old.status == "applied"
      check rc.now(e, "a").perms == @[ambient()]
      e.finish()
      e = persistent(
        storeConfig(
          entries = @[
            InitialSettings(
              module: "slow_module", permissions: @[setting(Quota, quota(1)), ambient()]
            )
          ]
        )
      )
      discard e.create(slow(), "n").tryGet
      let (_, rc2) = e.startClient("c2")
      check rc2.now(e, "a").perms == @[ambient()]
      check rc2.now(e, "n").perms == @[setting(Quota, quota(1)), ambient()]
      e.finish()

    test "[RUN-0923] a retired instance's settings go with it; a new instance of its module gets fresh provisioning":
      let cfg = storeConfig()
      var e = persistent(cfg)
      let (_, rc) = e.startClient("c")
      discard e.create(slow(), "a").tryGet
      check rc.writeSettings(e.target("a"), 1, @[]).written.revision == 2
      let r = rcCall(
        rc,
        "retire_module",
        encode(
          LogosNSRuntimeControlRetireModuleRequest(
            target: e.target("a"),
            expected_execution_revision: e.view("a").tryGet.execution.revision,
          )
        ).tryGet,
      )
      check r.code == ecOk
      discard e.create(slow(), "b").tryGet
      let b = rc.now(e, "b")
      check b.revision == 1 and b.perms == @[ambient()]
      e.finish()
      check getPrm(cfg.storeDir.get, "a").isNone
      check getPrm(cfg.storeDir.get, "b").isSome

    test "[IMPL] the store must agree with the selection: settings with no profile selected, or naming a permission the profile does not define, refuse the open":
      let cfg = storeConfig()
      var e = persistent(cfg)
      discard e.create(slow(), "a").tryGet
      e.finish()
      let none = reopened(storeConfig(profile = false))
      check none.isErr
      if none.isErr:
        check "no permission profile is selected" in none.error.message
      putPrm(
        cfg.storeDir.get,
        "a",
        SettingsState(
          revision: 2,
          permissions: @[setting("lcn-test.other", @[0xA0'u8])],
          application: saApplied,
        ),
      )
      let undefined = reopened(cfg)
      check undefined.isErr
      if undefined.isErr:
        check "does not define" in undefined.error.message

# Admission ---------------------------------------------------------------------------------

suite "run.permissions: admission (CA l.343-345, l.364, l.417; RUNTIME l.2538)":
  teardown:
    leftover()

  test "[RUN-0469] [CAP-0068] [IMPL-DECISION G284] settings without host-ambient refuse the start before any decision: NOT_AUTHORISED, the instance unloaded with authority-denied, intent kept":
    let e = fixtureEngine(
      pconfig(
        entries =
          @[InitialSettings(module: "slow_module", instance: "bare", permissions: @[])]
      )
    )
    discard e.create(slow(), "bare").tryGet
    let r = e.start("bare")
    check r.isErr and r.error.code == ecNotAuthorised
    let v = e.view("bare").tryGet
    check v.state == msUnloaded
    check v.failure.get.kind == fkAuthorityDenied
    check v.execution.intent == inRequested
    check e.executeAnswers("bare").len == 0
    check e.diagnostics().anyIt("lack logos-core-nim.host-ambient" in it)
    e.finish()

  test "[CAP-0063] [IMPL-DECISION G217] the execution request carries the execution scope and one permission scope per saved setting, as a set; without a profile, the execution scope alone":
    let e = fixtureEngine(
      pconfig(
        entries = @[
          InitialSettings(
            module: "slow_module",
            instance: "q",
            permissions: @[setting(Quota, quota(3)), ambient()],
          )
        ]
      )
    )
    let (_, rc) = e.startClient("c")
    discard e.create(slow(), "q").tryGet
    check rc.lifecycle("start_module", "slow_module", Opt.some("q")).code == ecOk
    let asked = e.executeAnswers("q")
    check asked.len == 1
    if asked.len == 1:
      check asked[0].request.permissions == @[setting(Quota, quota(3)), ambient()]
      let req = evaluateRequest(asked[0].request, e.runtimeInstanceId).tryGet
      check req.scopes.len == 3
      # A set: ascending by encoded bytes, no two equal (CA l.364).
      let bytes = req.scopes.mapIt(encodeCbor(toCbor(it)))
      for i in 1 ..< bytes.len:
        check bytes[i - 1].ascending(bytes[i])
    e.finish()
    let plain = fixtureEngine(pconfig(profile = false))
    let (_, rc2) = plain.startClient("c")
    discard plain.create(slow(), "q").tryGet
    check rc2.lifecycle("start_module", "slow_module", Opt.some("q")).code == ecOk
    let b = plain.executeAnswers("q")
    check b.len == 1
    if b.len == 1:
      check b[0].request.permissions.len == 0
      check evaluateRequest(b[0].request, plain.runtimeInstanceId).tryGet.scopes.len == 1
    plain.finish()

  test "[RUN-0906] [RUN-0907] the snapshot is what admission installed: the saved settings at admission, not the declaration":
    let e = fixtureEngine(pconfig())
    let (_, rc) = e.startClient("c")
    var rec = client()
    rec.requestedPermissions =
      @[RequestedPermission(permission: Quota, constraints: quota(9))]
    discard e.create(rec, "t").tryGet
    check e.start("t").tryGet.state == msReady
    let t = latestBinding()
    check t.installed == Opt.some(@[ambient()])
    check rc.installed == Opt.some(@[ambient()])
    e.finish()

  test "[RUN-0908] without a profile nothing is installed: unavailable":
    let e = fixtureEngine(pconfig(profile = false))
    let (_, rc) = e.startClient("c")
    check rc.installed.isNone
    e.finish()

  when not declared(caParity):
    test "[IMPL-DECISION G284] [IMPL-DECISION G110] an orchestration instance provisioned without host-ambient fails the bootstrap NOT_AUTHORISED":
      let e = fixtureEngine(
        pconfig(
          entries =
            @[InitialSettings(module: "client_module", instance: "o", permissions: @[])]
        )
      )
      let r = e.bootstrap(@[BootstrapInstance(instance: "o", record: client())], "o")
      check r.isErr and r.error.code == ecNotAuthorised
      check e.view("o").tryGet.failure.get.kind == fkAuthorityDenied
      e.finish()

# The event ---------------------------------------------------------------------------------

const
  SettingsEvent = "logos.runtime_control.permission_settings_changed_event"
  EventCap = 32
  EventBytes = 512

type Seen = object
  count: Atomic[int]
  lens: array[EventCap, int]
  data: array[EventCap, array[EventBytes, byte]]

var seen: Seen

proc onSettings(
    name: cstring, data: ptr UncheckedArray[uint8], len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let s = cast[ptr Seen](userData)
  let i = s.count.load
  if i < EventCap:
    let n = min(int(len), EventBytes)
    for j in 0 ..< n:
      s.data[i][j] = data[j]
    s.lens[i] = n
  s.count += 1

proc events(): seq[(string, uint64, string)] =
  for i in 0 ..< min(seen.count.load, EventCap):
    var b = newSeq[byte](seen.lens[i])
    for j in 0 ..< b.len:
      b[j] = seen.data[i][j]
    let ev = LogosNSRuntimeControlPermissionSettingsChangedEvent.decode(b).tryGet
    result.add((ev.target.module_instance_id, ev.state.revision, ev.state.status))

suite "run.permissions: permission_settings_changed (RUNTIME l.2603-2604)":
  teardown:
    leftover()

  test "[RUN-0482] every committed change of saved settings or status arrives in commit order, and only for a target the subscriber may observe":
    # The internal policy's rules decide, in the parity pass too.
    let e = fixtureEngine(
      pconfig(denying(deny(action = Opt.some(aaObserveEvent), target = "hidden")))
    )
    let (_, rc) = e.startClient("c")
    seen.count.store(0)
    var id: LogosSubscriptionId
    check toResult(
      rc.vtable.subscribe(rc, SettingsEvent, onSettings, addr seen, addr id)
    ).code == ecOk
    discard e.create(slow(), "u").tryGet
    discard e.started(slow(), "r")
    discard e.create(slow(), "hidden").tryGet
    check rc.writeSettings(e.target("u"), 1, @[]).code == ecOk
    check rc.writeSettings(e.target("u"), 2, @[unenforced()]).code == ecOk
    check rc.writeSettings(e.target("hidden"), 1, @[]).code == ecOk
    check rc.writeSettings(e.target("r"), 1, @[]).code == ecOk
    check e.stateIs("r", msUnloaded)
    check waitUntil(
      proc(): bool =
        events().anyIt(it[0] == "r" and it[2] == "applied")
    )
    sleep(50 * Slow)
    check events() ==
      @[
        ("u", 2'u64, "applied"),
        ("u", 3'u64, "failed"),
        ("r", 2'u64, "pending"),
        ("r", 2'u64, "applied"),
      ]
    discard toResult(rc.vtable.unsubscribe(rc, id))
    e.finish()

# Decisions with an authority bound ---------------------------------------------------------

when declared(caParity):
  type StartArgs = object
    rc: ptr LogosRuntimeControlBinding
    params: seq[byte]

  var
    startCode: Atomic[int]
    startDone: Atomic[bool]
    startThread: Thread[StartArgs]

  proc startOn(a: StartArgs) {.thread.} =
    let r = rcCall(a.rc, "start_module", a.params)
    startCode.store(ord(r.code))
    startDone.store(true)

  proc startReq(id: string): seq[byte] =
    encode(
      LogosNSRuntimeControlStartModuleRequest(
        module: "client_module", instance: Opt.some(id)
      )
    ).tryGet

  proc startBy(rc: ptr LogosRuntimeControlBinding, id: string): ErrorCode =
    ## A start by a module, so the authority decides its execution.
    rcCall(rc, "start_module", startReq(id)).code

  func narrowing(name: string, constraints: seq[byte]): Rule =
    Rule(
      what: "execute",
      verdict: vAllow,
      validMs: Everything,
      permName: name,
      permConstraints: constraints,
    )

  proc quotaTen(): EngineConfig =
    pconfig(
      entries = @[
        InitialSettings(
          module: "client_module",
          instance: "t",
          permissions: @[setting(Quota, quota(10)), ambient()],
        )
      ]
    )

  suite "run.permissions: decisions with an authority bound (CA l.343-345, l.568-569)":
    setup:
      setScript()
      forget()
    teardown:
      release()
      setScript()
      leftover()

    test "[IMPL-DECISION G282] [RUN-0906] [RUN-0907] [CAP-0068] an allow narrowing a permission is installed narrowed; the saved settings keep theirs":
      let e = fixtureEngine(quotaTen())
      let (_, rc) = e.startClient("c")
      discard e.create(client(), "t").tryGet
      setScript(narrowing(Quota, quota(5)))
      check rc.startBy("t") == ecOk
      check latestBinding().installed == Opt.some(
        @[setting(Quota, quota(5)), ambient()]
      )
      check rc.now(e, "t").perms == @[setting(Quota, quota(10)), ambient()]
      e.finish()

    test "[CAP-0084] [CAP-0068] [BCP-0049] [BCP-0081] [IMPL-DECISION G282] an allow broadening a permission, leaving one out, or allowing another is an evaluation failure":
      let e = fixtureEngine(quotaTen())
      let (_, rc) = e.startClient("c")
      discard e.create(client(), "t").tryGet
      for r in [
        narrowing(Quota, quota(20)), narrowing(Quota, @[]), rule(vPermission, "execute")
      ]:
        setScript(r)
        check rc.startBy("t") == ecNotAuthorised
        let v = e.view("t").tryGet
        check v.state == msUnloaded
        check v.failure.get.kind == fkAuthorityEvaluationFailed
      e.finish()

    test "[CAP-0192] [RUN-1066] revoking the grant that covered host-ambient stops the execution: authority-revoked, intent and origin kept, the settings untouched":
      let e = fixtureEngine(pconfig())
      let (_, rc) = e.startClient("c")
      discard e.create(client(), "t").tryGet
      setScript(allow("execute", grants = @["gh"]))
      check rc.startBy("t") == ecOk
      setScript()
      check publish(
        GrantChangedName,
        grantChanged("gh", GrantStatusKind.Revoked, "c", e.runtimeInstanceId),
      )
      check e.stateIs("t", msUnloaded)
      let v = e.view("t").tryGet
      check v.failure.get.kind == fkAuthorityRevoked
      check v.execution.intent == inRequested
      check v.intentOrigin.instance == "c"
      let s = rc.now(e, "t")
      check s.revision == 1 and s.status == "applied"
      e.finish()

    test "[RUN-0913] [IMPL-DECISION G284] a replacement while the execution decision is pending: the decision is asked again, for the replaced settings":
      let e = fixtureEngine(pconfig())
      let (_, rc) = e.startClient("c")
      let rc2 = e.client2("c2")
      discard e.create(client(), "t").tryGet
      hold()
      setScript(rule(vHang, "execute"))
      startDone.store(false)
      createThread(startThread, startOn, StartArgs(rc: rc, params: startReq("t")))
      check waitUntil(
        proc(): bool =
          hanging.load >= 1
      )
      let wide = @[setting(Quota, quota(4)), ambient()]
      let s = rc2.writeSettings(e.target("t"), 1, wide).written
      check s.revision == 2 and s.status == "applied"
      release()
      check waitUntil(
        proc(): bool =
          startDone.load
      )
      joinThread(startThread)
      check ErrorCode(startCode.load) == ecOk
      let asked = e.executeAnswers("t")
      check asked.len >= 1
      if asked.len >= 1:
        check asked[^1].request.permissions == wide
      check latestBinding().installed == Opt.some(wide)
      e.finish()
