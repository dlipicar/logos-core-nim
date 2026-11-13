## Module configuration (CONFIG §1-§9; RUNTIME §9.3 l.2394-2457, l.2606-2612;
## DECISIONS I87): the CFG and Runtime Control configuration types, declaration
## acceptance (`runtime/configcheck.nim`), configuration state and its
## transitions (`runtime/config.nim`), the five Runtime Control operations,
## startup delivery and promotion, sources across restarts, and events.
##
## Static kit registrations only, so the suite never dlopens (MSan on aarch64).

import std/[atomics, locks, monotimes, os, strutils, times, typedthreads]
when defined(posix):
  import std/posix
import unittest2
import ../src/logos_core/runtime/engine
import ../src/logos_core/runtime/store
import ../src/logos_core/abi/types
import ../src/logos_core/cbor
import ../src/logos_core/codegen/nimrt
import ../src/logos_core/commitment
import ../src/logos_core/iface/[accept, outcome, provider, surface]
import ../src/logos_core/iface/common_types
import ../src/logos_core/transport/envelope
import ../src/logos_core/transport/framing
import ./support/[kitbuild, kitruntime, tunerconfig]
import ./kit/[meter_impl, tuner_impl]
import ./generated/[meter_module_calls, tuner_module_types]

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "config" / kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

# Fixtures ---------------------------------------------------------------------------

proc stateFor(a: AcceptedConfiguration): ConfigState =
  newState(runtimeBinding(a))

proc stageValue(
    s: var ConfigState, bytes: seq[byte], provenance = pvRuntimeControlUpdate
): ValueRecord =
  ## Stages `bytes` as the engine does: a blob owned by the request, adopted.
  let root = checkValue(
    s.binding.digest, s.binding.document, s.binding.root,
    s.binding.commitment.subtreeRoot, bytes,
  ).tryGet
  let b = newBlob(bytes)
  s.adopt(s.withStaged(b, root, provenance))
  drop(b)
  s.staged.get

func holds(hay, needle: seq[byte]): bool =
  ## `needle` occurs in `hay`.
  for i in 0 .. hay.len - needle.len:
    if hay[i ..< i + needle.len] == needle:
      return true
  false

proc rcRoundTrip[T](x: T, declaration: string) =
  ## The value encodes to deterministic CBOR the mirror schema accepts, and
  ## decodes back to an equal encoding.
  let bytes = encode(x).tryGet
  let v = rcSchema().decodeChecked(declaration, bytes).tryGet
  check encodeCbor(toCbor(fromChecked(T, v))) == bytes

# Types ------------------------------------------------------------------------------

suite "cfg.types: CONFIG §9 and the Runtime Control configuration types":
  let
    target = LogosNSRuntimeModuleInstanceAddress(
      runtime_instance_id: "r-1", module_instance_id: "tuner-1"
    )
    record = LogosNSModuleConfigurationValueRecord(
      value: tunerValue(),
      schema_commitment: tunerCommitment(),
      value_commitment: LogosNSModuleConfigurationValueCommitment(
        schema_subtree_root: tunerCommitment().schema_subtree_root,
        value_root: newSeq[byte](32),
      ),
      value_revision: 3,
      provenance: toRc(pvRuntimeControlUpdate),
    )
    meta = LogosNSModuleConfigurationValueRecordMetadata(
      schema_commitment: record.schema_commitment,
      value_commitment: record.value_commitment,
      value_revision: 3,
      provenance: toRc(pvPackageDefault),
    )

  test "[CFG-0111] [CFG-0112] [CFG-0113] [CFG-0114] [CFG-0115] [CFG-0116] [CFG-0117] [CFG-0118] [CFG-0119] [CFG-0120] [CFG-0121] every configuration type round-trips through its mirror codec":
    rcRoundTrip(tunerCommitment(), "logos.module_configuration.schema_commitment")
    rcRoundTrip(record.value_commitment, "logos.module_configuration.value_commitment")
    rcRoundTrip(tunerBinding(live = true), "logos.module_configuration.schema_binding")
    rcRoundTrip(
      tunerDecl(Opt.some(tunerValue())),
      "logos.module_configuration.configuration_declaration",
    )
    for p in Provenance:
      rcRoundTrip(toRc(p), "logos.module_configuration.provenance")
    rcRoundTrip(record, "logos.module_configuration.value_record")
    rcRoundTrip(meta, "logos.module_configuration.value_record_metadata")
    rcRoundTrip(
      LogosNSModuleConfigurationConfigurationState(
        state_revision: 4,
        schema_commitment: tunerCommitment(),
        current: Opt.some(record),
        staged: Opt.some(record),
      ),
      "logos.module_configuration.configuration_state",
    )
    rcRoundTrip(
      LogosNSModuleConfigurationConfigurationStateSummary(
        state_revision: 4,
        schema_commitment: Opt.some(tunerCommitment()),
        current: Opt.some(meta),
      ),
      "logos.module_configuration.configuration_state_summary",
    )
    rcRoundTrip(
      LogosNSModuleConfigurationConfigurationInput(
        value: tunerValue(), schema_commitment: tunerCommitment(), value_revision: 1
      ),
      "logos.module_configuration.configuration_input",
    )
    # A live flag is `true` when present: the codec writes presence only.
    var flagged = tunerBinding()
    flagged.live_reconfiguration = Opt.some(false)
    check encode(flagged).tryGet == encode(tunerBinding(live = true)).tryGet

  test "[RUN-0452] [RUN-0453] [RUN-0454] [RUN-0455] [RUN-0456] [RUN-0457] [RUN-0458] [RUN-0459] [RUN-0460] [RUN-0461] [RUN-0462] [RUN-0466] the five methods and the event round-trip, the commitment carrying a subtree root":
    rcRoundTrip(
      LogosNSRuntimeControlGetConfigurationSchemaRequest(target: target),
      "logos.runtime_control.get_configuration_schema_request",
    )
    rcRoundTrip(
      LogosNSRuntimeControlGetConfigurationSchemaResponse(
        target: target, state_revision: 2, schema: tunerBinding()
      ),
      "logos.runtime_control.get_configuration_schema_response",
    )
    rcRoundTrip(
      LogosNSRuntimeControlGetConfigurationSummaryRequest(target: target),
      "logos.runtime_control.get_configuration_summary_request",
    )
    rcRoundTrip(
      LogosNSRuntimeControlGetConfigurationSummaryResponse(
        target: target, state: summaryWithout()
      ),
      "logos.runtime_control.get_configuration_summary_response",
    )
    rcRoundTrip(
      LogosNSRuntimeControlGetConfigurationRequest(target: target),
      "logos.runtime_control.get_configuration_request",
    )
    rcRoundTrip(
      LogosNSRuntimeControlGetConfigurationResponse(
        target: target,
        state: LogosNSModuleConfigurationConfigurationState(
          state_revision: 1,
          schema_commitment: tunerCommitment(),
          staged: Opt.some(record),
        ),
      ),
      "logos.runtime_control.get_configuration_response",
    )
    let stage = LogosNSRuntimeControlUpdateConfigurationRequest(
      kind: LogosNSRuntimeControlUpdateConfigurationRequestKind.Stage,
      arm_Stage: LogosNSRuntimeControlUpdateConfigurationRequestARStageMap(
        target: target,
        expected_state_revision: 0,
        expected_schema_commitment: tunerCommitment(),
        value: tunerValue(),
      ),
    )
    rcRoundTrip(stage, "logos.runtime_control.update_configuration_request")
    let drop = LogosNSRuntimeControlUpdateConfigurationRequest(
      kind: LogosNSRuntimeControlUpdateConfigurationRequestKind.Discard,
      arm_Discard: LogosNSRuntimeControlUpdateConfigurationRequestARDiscardMap(
        target: target,
        expected_state_revision: 1,
        expected_schema_commitment: tunerCommitment(),
      ),
    )
    rcRoundTrip(drop, "logos.runtime_control.update_configuration_request")
    rcRoundTrip(
      LogosNSRuntimeControlUpdateConfigurationResponse(
        target: target, state_revision: 1, staged: Opt.some(record)
      ),
      "logos.runtime_control.update_configuration_response",
    )
    rcRoundTrip(
      LogosNSRuntimeControlApplyConfigurationRequest(
        target: target, expected_state_revision: 1
      ),
      "logos.runtime_control.apply_configuration_request",
    )
    rcRoundTrip(
      LogosNSRuntimeControlApplyConfigurationResponse(
        target: target, state_revision: 2, applied_value_revision: 1
      ),
      "logos.runtime_control.apply_configuration_response",
    )
    rcRoundTrip(
      LogosNSRuntimeControlConfigurationStateChangedEvent(
        target: target, state: summaryWithout()
      ),
      "logos.runtime_control.configuration_state_changed_event",
    )
    # [RUN-0466] `expected_schema_commitment` is a configuration-schema
    # commitment: without its subtree root it is not one.
    var v = toCbor(stage)
    var short = LogosNSModuleConfigurationSchemaCommitment(
      schema_root: tunerCommitment().schema_root
    )
    check rcSchema()
      .check("logos.module_configuration.schema_commitment", toCbor(short)).isErr
    check rcSchema().check("logos.runtime_control.update_configuration_request", v).isOk

# Declarations -----------------------------------------------------------------------

suite "cfg.declaration: accepting a configuration declaration (CONFIG §2; RUN-0259)":
  test "[CFG-0005] [CFG-0012] [CFG-0013] [CFG-0014] [CFG-0015] [CFG-0017] [CFG-0018] [RUN-0259] the tuner declaration is accepted, both roots recomputed":
    let a = acceptConfiguration(tunerDecl(Opt.some(tunerValue()))).tryGet
    check @(a.roots.schemaRoot) == tunerCommitment().schema_root
    check @(a.roots.subtreeRoot) == tunerCommitment().schema_subtree_root
    check a.digest == bindingDigest(tunerBinding())
    check not a.live
    check a.defaultValue.isSome and a.provisioned.isNone
    check acceptConfiguration(tunerDecl(live = true)).tryGet.live
    var falseFlag = tunerDecl()
    falseFlag.schema.live_reconfiguration = Opt.some(false)
    check acceptConfiguration(falseFlag).isErr
    # The binding identity covers the live flag (C4).
    check bindingDigest(tunerBinding(live = true)) != a.digest
    # The CBOR form the host configuration carries.
    let bytes = encode(tunerDecl()).tryGet
    check acceptConfiguration(bytes).tryGet.digest == a.digest
    check acceptConfiguration(@[0xA0'u8]).isErr

  test "[CFG-0012] [CFG-0013] [CFG-0014] [CFG-0015] [CFG-0019] an unacceptable schema document or root is rejected":
    proc rejects(document, root: string, fix = true): bool =
      var b = tunerBinding()
      b.document = document
      b.root = root
      if fix:
        let r = acceptContractSet(document)
        if r.isOk:
          let m = r.get.primary.model
          b.schema_commitment.schema_root = @(schemaRoot(m))
          let d = m.find(root)
          if d.isSome and d.get.kind == dkType:
            b.schema_commitment.schema_subtree_root = @(declarationRoot(m, d.get))
      acceptConfiguration(LogosNSModuleConfigurationConfigurationDeclaration(schema: b)).isErr

    check rejects("", "tuner.config")
    check rejects(
      "tuner.config = { pad: bstr }\n" & ";".repeat(MaxDocumentChars), "tuner.config"
    )
    # More nodes than INTERFACE §5.3 allows.
    var wide = "big.config = {\n"
    for i in 0 .. MaxSchemaNodes:
      wide.add("  f" & $i & ": uint32,\n")
    wide.add("}\n")
    check rejects(wide, "big.config")
    # Deeper than 128 levels.
    var deep =
      "deep.config = " & "[".repeat(MaxSchemaNesting + 1) & "uint32" &
      "]".repeat(MaxSchemaNesting + 1) & "\n"
    check rejects(deep, "deep.config")
    # An unresolved name, and a name from another document: nothing is fetched.
    check rejects("tuner.config = { station: tuner.missing }\n", "tuner.config")
    check rejects("tuner.config = { station: other.station }\n", "tuner.config")
    # A module document is not a configuration schema.
    check rejects(
      "_module = \"tuner_module\"\n\ntuner.config = { volume: uint32 }\n",
      "tuner.config",
    )
    # A root it does not declare, and one naming nothing.
    check rejects(tunerDocument, "tuner.missing")
    check rejects(tunerDocument, "")

  test "[CFG-0017] [CFG-0018] a declared root that is not the recomputed one is rejected":
    var d = tunerDecl()
    d.schema.schema_commitment.schema_root[0] =
      d.schema.schema_commitment.schema_root[0] xor 1
    check acceptConfiguration(d).isErr
    d = tunerDecl()
    d.schema.schema_commitment.schema_subtree_root[0] =
      d.schema.schema_commitment.schema_subtree_root[0] xor 1
    check acceptConfiguration(d).isErr

  test "[CFG-0007] [CFG-0022] [CFG-0023] [CFG-0024] [CFG-0025] [CFG-0045] [CFG-0048] [CFG-0049] [CFG-0150] a default or provisioned value must be one complete deterministic value of the root":
    # Not a value of the root.
    let missing = encodeCbor(cborMap((cbor("station"), cbor("radio-1"))))
    check acceptConfiguration(tunerDecl(Opt.some(missing))).isErr
    # Non-deterministic (a non-shortest integer) and trailing bytes.
    var loose = tunerValue(volume = 5)
    let i = loose.find(0x05'u8)
    loose[i] = 0x18
    loose.insert(0x05'u8, i + 1)
    check acceptConfiguration(tunerDecl(Opt.some(loose))).isErr
    check acceptConfiguration(tunerDecl(Opt.some(tunerValue() & @[0x00'u8]))).isErr
    check acceptConfiguration(tunerDecl(Opt.some(newSeq[byte]()))).isErr
    # Too large: 8,388,608 bytes is the limit.
    check acceptConfiguration(tunerDecl(), Opt.some(newSeq[byte](MaxValueBytes + 1))).isErr
    # The provisioned value is checked as the default is.
    check acceptConfiguration(tunerDecl(), Opt.some(missing)).isErr
    let a = acceptConfiguration(tunerDecl(), Opt.some(tunerValue("radio-2"))).tryGet
    check a.provisioned.get.bytes == tunerValue("radio-2")
    # Its value root is the one the commitment model computes.
    let v = decodeCbor(tunerValue("radio-2")).tryGet
    let (sub, root) = loadSchemaSet(acceptContractSet(tunerDocument).tryGet)
      .commitment("tuner.config", v).tryGet
    check a.provisioned.get.valueRoot == root
    check sub == a.roots.subtreeRoot

# State ------------------------------------------------------------------------------

suite "cfg.state: configuration state and its transitions (CONFIG §3, §4, §6)":
  setup:
    let before = liveConfigBlobs()
    let acc = acceptConfiguration(tunerDecl()).tryGet

  teardown:
    check liveConfigBlobs() == before

  test "[CFG-0026] [CFG-0030] [CFG-0034] [CFG-0035] [CFG-0036] [CFG-0050] [CFG-0051] staging advances the revision even for an equal value; discarding only with a staged record":
    var s = stateFor(acc)
    check s.revision == 0 and s.current.isNone and s.staged.isNone
    check s.select == selNone
    let r1 = s.stageValue(tunerValue())
    check s.revision == 1 and r1.valueRevision == 1
    check r1.provenance == pvRuntimeControlUpdate
    let r2 = s.stageValue(tunerValue())
    check s.revision == 2 and r2.valueRevision == 2 and r2.valueRoot == r1.valueRoot
    s.adopt(s.discarded)
    check s.revision == 3 and s.staged.isNone
    s.adopt(s.discarded)
    check s.revision == 3
    s.release()

  test "[CFG-0031] [CFG-0032] [CFG-0033] the revision never wraps":
    var s = stateFor(acc)
    s.revision = high(uint64) - 1
    check s.canMutate
    discard s.stageValue(tunerValue())
    check s.revision == high(uint64)
    check not s.canMutate and not s.canAdvance
    s.release()

  test "[CFG-0033] [CFG-0072] a pending promotion keeps one revision step reserved (G234)":
    var s = stateFor(acc)
    let r = s.stageValue(tunerValue())
    s.adopt(s.withAttempt(r))
    check s.headroom == 1
    s.revision = high(uint64) - 1
    # One more mutation would leave the promotion no revision.
    check not s.canMutate
    s.revision = high(uint64) - 2
    check s.canMutate
    discard s.stageValue(tunerValue("radio-3"))
    check s.revision == high(uint64) - 1
    s.adopt(s.promoted)
    check s.revision == high(uint64)
    check s.current.get.valueRevision == r.valueRevision
    # An attempt with the current record promotes nothing: no headroom.
    var t = stateFor(acc)
    let c = t.stageValue(tunerValue())
    t.adopt(t.withAttempt(c))
    t.adopt(t.promoted)
    t.adopt(t.withAttempt(t.current.get))
    check t.headroom == 0
    s.release()
    t.release()

  test "[CFG-0047] [CFG-0052] [CFG-0053] selection: staged, else current; an ineligible record is not absence":
    var s = stateFor(acc)
    let r = s.stageValue(tunerValue(), pvPackageDefault)
    check s.select == selStaged
    s.adopt(s.withAttempt(r))
    s.adopt(s.promoted)
    check s.select == selCurrent
    check s.current.get.provenance == pvPackageDefault
    # [TF-06] A record under another commitment cannot start the instance,
    # and does not count as absent either.
    var crafted = s
    var c = crafted.current.get
    c.commitment.subtreeRoot[0] = c.commitment.subtreeRoot[0] xor 1
    crafted.current = Opt.some(c)
    check crafted.select == selIneligible
    s.release()

  test "[CFG-0072] [CFG-0073] [CFG-0094] [CFG-0054] promotion clears the staged record only at the attempted value revision":
    # Staged unchanged: promoted and cleared.
    var s = stateFor(acc)
    let r = s.stageValue(tunerValue(), pvProtectedProvisioning)
    s.adopt(s.withAttempt(r))
    s.adopt(s.promoted)
    check s.revision == 2 and s.staged.isNone and s.attempted.isNone
    check s.current.get.valueRevision == 1
    check s.current.get.provenance == pvProtectedProvisioning
    # Replaced during the attempt: the replacement stays staged.
    let r2 = s.stageValue(tunerValue("radio-2"))
    s.adopt(s.withAttempt(r2))
    let r3 = s.stageValue(tunerValue("radio-3"))
    s.adopt(s.promoted)
    check s.current.get.valueRevision == r2.valueRevision
    check s.staged.get.valueRevision == r3.valueRevision
    # Discarded during the attempt: it stays absent.
    s.adopt(s.withAttempt(s.staged.get))
    s.adopt(s.discarded)
    let at = s.revision
    s.adopt(s.promoted)
    check s.current.get.valueRevision == r3.valueRevision
    check s.staged.isNone and s.revision == at + 1
    # A failed attempt changes nothing else.
    let r4 = s.stageValue(tunerValue("radio-4"))
    s.adopt(s.withAttempt(r4))
    let rev = s.revision
    s.adopt(s.withoutAttempt)
    check s.revision == rev and s.staged.get.valueRevision == r4.valueRevision
    check s.current.get.valueRevision == r3.valueRevision
    # Starting from the current record: no revision change.
    s.adopt(s.discarded)
    let rev2 = s.revision
    s.adopt(s.withAttempt(s.current.get))
    s.adopt(s.promoted)
    check s.revision == rev2
    s.release()

  test "[CFG-0037] [CFG-0038] [CFG-0039] [CFG-0040] [CFG-0041] the frame-size arithmetic equals a real encoding and refuses an oversized state":
    var s = stateFor(acc)
    for n in [0, 1, 23, 24, 255, 256, 65535, 65536, 100_000]:
      var t = stateFor(acc)
      discard t.stageValue(tunerValue(pad = n))
      t.adopt(t.withAttempt(t.staged.get))
      t.adopt(t.promoted)
      discard t.stageValue(tunerValue("radio-9", pad = n div 2))
      # The real response with maximal ids, call id and revisions.
      var id = 'a'.repeat(128)
      var st = stateOf(t)
      st.state_revision = high(uint64)
      var cur = st.current.get
      cur.value_revision = high(uint64)
      st.current = Opt.some(cur)
      var stg = st.staged.get
      stg.value_revision = high(uint64)
      st.staged = Opt.some(stg)
      let response = LogosNSRuntimeControlGetConfigurationResponse(
        target: LogosNSRuntimeModuleInstanceAddress(
          runtime_instance_id: id, module_instance_id: id
        ),
        state: st,
      )
      let real = encodeCbor(
        toCbor(
          Message(
            kind: mkResponse,
            response:
              envelope.Response(id: high(uint64), ok: true, resultMap: toCbor(response)),
          )
        )
      )
      check t.frameBytes(t.current, t.staged) == real.len
      t.release()
    # Two values near 8 MiB cannot both be kept.
    let big = tunerValue(pad = MaxValueBytes - 64)
    check big.len <= MaxValueBytes
    discard s.stageValue(big)
    s.adopt(s.withAttempt(s.staged.get))
    s.adopt(s.promoted)
    let b = newBlob(big)
    let next = s.withStaged(b, s.current.get.valueRoot, pvRuntimeControlUpdate)
    check not next.admissible
    drop(b)
    # The boundary: the largest second value that fits, then one byte more.
    let fixed = s.frameBytes(s.current, Opt.none(ValueRecord))
    var room = MinFrameLimit - fixed
    var lo = 0
    var hi = MaxValueBytes
    proc fits(n: int): bool =
      let v = newBlob(newSeq[byte](n))
      let t = s.withStaged(v, s.current.get.valueRoot, pvRuntimeControlUpdate)
      result = t.admissible
      drop(v)

    while lo < hi:
      let mid = (lo + hi + 1) div 2
      if fits(mid):
        lo = mid
      else:
        hi = mid - 1
    check lo > 0 and lo < room
    check fits(lo) and not fits(lo + 1)
    s.release()

  test "[CFG-0040] while an attempt is in flight, the attempted record must fit with the new staged one":
    var s = stateFor(acc)
    discard s.stageValue(tunerValue())
    s.adopt(s.withAttempt(s.staged.get))
    s.adopt(s.promoted)
    # The current value is small; the attempted one is near 8 MiB.
    let big = s.stageValue(tunerValue(pad = MaxValueBytes - 64))
    s.adopt(s.withAttempt(big))
    let b = newBlob(newSeq[byte](MaxValueBytes - 64))
    let next = s.withStaged(b, big.valueRoot, pvRuntimeControlUpdate)
    check next.frameBytes(next.current, next.staged) <= MinFrameLimit
    check not next.admissible
    drop(b)
    s.release()

  test "[CFG-0107] [CFG-0058] [CFG-0106] [CFG-0108] summaries carry metadata only; without a binding only the revision (G235)":
    let w = summaryWithout()
    check w.state_revision == 0
    check w.schema_commitment.isNone and w.current.isNone and w.staged.isNone
    var s = stateFor(acc)
    discard s.stageValue(tunerValue())
    let sm = s.summary
    check sm.state_revision == 1 and sm.staged.isSome and sm.current.isNone
    check sm.schema_commitment.get == toRc(s.binding.commitment)
    check not encode(sm).tryGet.holds(tunerValue())
    s.release()

  test "[CFG-0066] [CFG-0150] the startup input is one configuration_input with the record's commitment and revision":
    var s = stateFor(acc)
    let r = s.stageValue(tunerValue())
    let input =
      LogosNSModuleConfigurationConfigurationInput.decode(encodeInput(r)).tryGet
    check input.value == tunerValue()
    check input.value_revision == r.valueRevision
    check input.schema_commitment == toRc(acc.roots)
    s.release()

  test "persisted state reads back with its records, revision and provenance":
    var s = stateFor(acc)
    discard s.stageValue(tunerValue(), pvPackageDefault)
    s.adopt(s.withAttempt(s.staged.get))
    s.adopt(s.promoted)
    discard s.stageValue(tunerValue("radio-2"))
    s.lastProvisioned = Opt.some(s.current.get.valueRoot)
    let (b, st) = s.encodeStored
    var back = decodeStored(b, st, s.binding.digest, s.lastProvisioned).tryGet
    check back.revision == s.revision
    check back.current.get.provenance == pvPackageDefault
    check back.staged.get.value.toBytes == tunerValue("radio-2")
    check back.binding.live == s.binding.live
    check back.lastProvisioned == s.lastProvisioned
    var other = s.binding.digest
    other[0] = other[0] xor 1
    check decodeStored(b, st, other, Opt.none(Digest)).isErr
    back.release()
    s.release()

# The tuner module ---------------------------------------------------------------------
#
# A hand-written configurable module: its `_MODULE_init` keeps a copy of the
# `configuration_input` it was given (on the shared heap: module code runs on
# the engine's workers) and can be made to fail. `tuner_live` also exports
# `_MODULE_apply_configuration`, which keeps its input too and answers as
# `applyMode` says, after waiting while `applyHold` is set.

var
  tunerLock: Lock
  tunerBuf: ptr UncheckedArray[byte]
  tunerLen: int
  tunerPresent: bool
  tunerInits: Atomic[int]
  tunerFail: Atomic[bool]
  tunerDestroys: Atomic[int]
  applyBuf: ptr UncheckedArray[byte]
  applyLen: int
  applyMode: Atomic[int]
    ## 0: LOGOS_OK; 1: a valid rejection (NOT_AUTHORISED with a message);
    ## 2: an invalid result (LOGOS_OK with a message)
  applyHold: Atomic[bool] ## the hook waits while it is set
  applyEntered: Atomic[int] ## hook calls begun
  applyCalls: Atomic[int] ## hook calls past the hold
  tunerRc: Atomic[pointer] ## the latest instance's own Runtime Control binding
initLock(tunerLock)

proc tunerName(): cstring {.cdecl.} =
  "tuner_module"

proc tunerInit(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.cdecl.} =
  tunerInits += 1
  tunerRc.store(input.runtimeControl)
  withLock tunerLock:
    if tunerBuf != nil:
      deallocShared(tunerBuf)
      tunerBuf = nil
    tunerPresent = input.configurationCbor != nil
    tunerLen = int(input.configurationCborLen)
    if tunerPresent and tunerLen > 0:
      tunerBuf = cast[ptr UncheckedArray[byte]](allocShared(tunerLen))
      copyMem(tunerBuf, input.configurationCbor, tunerLen)
  if tunerFail.load:
    result.code = CErrorCode(ord(ecModule))
    result.message = "cannot start"
    return
  outContext[] = cast[ptr LogosModuleContext](allocShared0(16))

proc tunerDestroy(module: ptr LogosModuleContext) {.cdecl.} =
  tunerDestroys += 1
  deallocShared(module)

proc tunerApply(
    module: ptr LogosModuleContext, cbor: ptr UncheckedArray[uint8], len: csize_t
): LogosResult {.cdecl.} =
  applyEntered += 1
  while applyHold.load:
    sleep(1)
  withLock tunerLock:
    if applyBuf != nil:
      deallocShared(applyBuf)
    applyLen = int(len)
    applyBuf = cast[ptr UncheckedArray[byte]](allocShared(max(applyLen, 1)))
    copyMem(applyBuf, cbor, applyLen)
  applyCalls += 1
  case applyMode.load
  of 1:
    result.code = CErrorCode(ord(ecNotAuthorised))
    result.message = "the tuner says the secret word is wrong"
  of 2:
    result.message = "fine, mostly"
  else:
    discard

proc tunerTable(live: bool): seq[(string, pointer)] =
  result = @[
    ("logos_tuner_module_MODULE_name", cast[pointer](tunerName)),
    ("logos_tuner_module_MODULE_init", cast[pointer](tunerInit)),
    ("logos_tuner_module_MODULE_destroy", cast[pointer](tunerDestroy)),
  ]
  if live:
    result.add(
      ("logos_tuner_module_MODULE_apply_configuration", cast[pointer](tunerApply))
    )

proc tunerRegs(): seq[StaticRegistration] =
  ## The hand-written tuner, startup-only and live, and the generated kit
  ## (`tests/kit/tuner_impl.nim`, live).
  @[
    checkStaticRegistration("tuner", tunerTable(false)).tryGet,
    checkStaticRegistration("tuner_live", tunerTable(true)).tryGet,
    checkStaticRegistration("tuner_kit", tunerModuleStaticSymbols()).tryGet,
  ]

proc lastInput(): Opt[seq[byte]] =
  ## The configuration input the latest `_MODULE_init` was given.
  withLock tunerLock:
    if tunerPresent:
      var b = newSeq[byte](tunerLen)
      for i in 0 ..< tunerLen:
        b[i] = tunerBuf[i]
      result = Opt.some(b)

proc lastApplied(): seq[byte] =
  ## The configuration input the latest `_MODULE_apply_configuration` was given.
  withLock tunerLock:
    result = newSeq[byte](applyLen)
    for i in 0 ..< applyLen:
      result[i] = applyBuf[i]

proc resetTuner() =
  tunerInits.store(0)
  tunerFail.store(false)
  tunerDestroys.store(0)
  applyMode.store(0)
  applyHold.store(false)
  applyEntered.store(0)
  applyCalls.store(0)
  tunerRc.store(nil)
  withLock tunerLock:
    tunerPresent = false
    applyLen = 0

func tuner(a: AcceptedConfiguration, binding = "tuner"): ModuleRecord =
  ModuleRecord(
    module: "tuner_module",
    strategy: stDirectStatic,
    binding: binding,
    configuration: Opt.some(a.digest),
  )

proc createTuner(
    e: Engine, id: string, a: AcceptedConfiguration, binding = "tuner"
): InstanceView =
  e.create(tuner(a, binding), id, configuration = Opt.some(a)).tryGet

include ./support/configrc

proc inputFor(value: seq[byte], revision: uint64): seq[byte] =
  encode(
    LogosNSModuleConfigurationConfigurationInput(
      schema_commitment: tunerCommitment(), value: value, value_revision: revision
    )
  ).tryGet

proc reasonOf(detail: seq[byte]): string =
  ## The `reason` of an encoded `logos.invalid_params_detail`.
  let v = decodeCbor(detail).tryGet
  v.lookup("reason").get.text

proc tunerEngine(policy = allowAll(), depth = 0): Engine =
  var cfg = config(policy, extra = tunerRegs())
  cfg.maxPayloadDepth = depth
  fixtureEngine(cfg)

# Sources and startup ----------------------------------------------------------------------

suite "cfg.startup: sources, selection, delivery and promotion (CONFIG §4, §6; I87)":
  setup:
    resetTuner()
    let blobs = liveConfigBlobs()

  teardown:
    leftover()
    check liveConfigBlobs() == blobs

  test "[CFG-0046] [CFG-0051] [CFG-0063] [CFG-0064] [CFG-0066] [CFG-0072] [CFG-0076] [CFG-0027] [RUN-0291] [IFC-0519] a new instance stages its default; its first start delivers it as one configuration_input and promotes it":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    let a = tunerAccepted(default = Opt.some(tunerValue()))
    discard e.createTuner("t1", a)
    let t = e.target("t1")
    var s = rc.summary(t)
    check s.state_revision == 1
    check s.current.isNone and s.staged.isSome
    check provenanceOf(s.staged.get.provenance) == pvPackageDefault
    check s.staged.get.value_revision == 1
    check e.start("t1").tryGet.state == msReady
    check lastInput() == Opt.some(inputFor(tunerValue(), 1))
    s = rc.summary(t)
    check s.state_revision == 2
    check s.staged.isNone and s.current.isSome
    check s.current.get.value_revision == 1
    check rc.state(t).current.get.value == tunerValue()
    # A restart of the realization delivers the current record; nothing
    # changes (the attempted record is already current).
    check e.stop("t1").tryGet.state == msUnloaded
    check e.start("t1").tryGet.state == msReady
    check lastInput() == Opt.some(inputFor(tunerValue(), 1))
    check rc.summary(t).state_revision == 2
    e.finish()

  test "[CFG-0044] [CFG-0052] [G141] a provisioned value is staged as protected-provisioning in place of the default":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    let p = tunerValue("radio-2", 7)
    let a = tunerAccepted(default = Opt.some(tunerValue()), provisioned = Opt.some(p))
    discard e.createTuner("t1", a)
    let st = rc.state(e.target("t1"))
    check st.state_revision == 1
    check st.staged.get.value == p
    check provenanceOf(st.staged.get.provenance) == pvProtectedProvisioning
    e.finish()

  test "[CFG-0026] [CFG-0042] [CFG-0128] [CFG-0009] [G162] without a value a start is NOT_READY with intent requested and no module code run; an update starts nothing":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    discard e.createTuner("t1", tunerAccepted())
    let t = e.target("t1")
    check rc.summary(t).state_revision == 0
    let r = e.start("t1")
    check r.isErr and r.error.code == ecNotReady
    let v = e.view("t1").tryGet
    check v.state == msUnloaded and v.failure.isNone
    check v.execution.intent == inRequested
    check tunerInits.load == 0
    check rc.stage(t, 0, tunerValue()).updated.state_revision == 1
    check e.view("t1").tryGet.state == msUnloaded
    check tunerInits.load == 0
    check e.start("t1").tryGet.state == msReady
    check lastInput() == Opt.some(inputFor(tunerValue(), 1))
    e.finish()

  test "[CFG-0074] [CFG-0075] a failed start promotes nothing and keeps the staged record":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    discard e.createTuner("t1", tunerAccepted(default = Opt.some(tunerValue())))
    let t = e.target("t1")
    tunerFail.store(true)
    let v = e.start("t1").tryGet
    check v.state == msError
    check v.failure.get.kind == fkInitializationFailed
    var s = rc.summary(t)
    check s.state_revision == 1 and s.current.isNone and s.staged.isSome
    tunerFail.store(false)
    check e.start("t1").tryGet.state == msReady
    s = rc.summary(t)
    check s.state_revision == 2 and s.current.get.value_revision == 1
    e.finish()

  test "[RUN-1086] [CFG-0091] a live declaration on a binding without apply_configuration fails binding (the Loader's abi-invalid)":
    let e = tunerEngine()
    discard e.startClient()
    let a = tunerAccepted(default = Opt.some(tunerValue()), live = true)
    discard e.createTuner("t1", a)
    let v = e.start("t1").tryGet
    check v.state == msError
    check v.failure.get.kind == fkLoader and v.failure.get.loader == lecAbiInvalid and
      v.failure.get.internal
    check tunerInits.load == 0
    discard e.createTuner("t2", a, binding = "tuner_live")
    check e.start("t2").tryGet.state == msReady
    e.finish()

  test "[RUN-0259] a record naming a binding without its accepted declaration is refused":
    let e = tunerEngine()
    let a = tunerAccepted()
    check e.create(tuner(a), "t1").error.code == ecInvalidParams
    let b = tunerAccepted(live = true)
    check e.create(tuner(a), "t1", configuration = Opt.some(b)).error.code ==
      ecInvalidParams
    check e.create(client(), "c", configuration = Opt.some(a)).error.code ==
      ecInvalidParams
    e.finish()

  test "[CFG-0133] [CFG-0135] a new instance of the same module inherits no configuration, under a changed declaration or the same one; the old instance is unchanged (CONFIG §7 l.251, l.261)":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    let a = tunerAccepted(default = Opt.some(tunerValue()))
    discard e.createTuner("t1", a)
    let t1 = e.target("t1")
    check rc.stage(t1, 1, tunerValue("radio-2", 9)).updated.state_revision == 2
    check e.start("t1").tryGet.state == msReady
    let before = rc.state(t1)
    check before.current.get.value == tunerValue("radio-2", 9)
    # A replacement under a changed declaration (live, another binding): no
    # record at all, so its start is NOT_READY (G162).
    discard e.createTuner("t2", tunerAccepted(live = true), binding = "tuner_live")
    let s2 = rc.state(e.target("t2"))
    check s2.state_revision == 0 and s2.current.isNone and s2.staged.isNone
    let r = e.start("t2")
    check r.isErr and r.error.code == ecNotReady
    # Another instance under the same declaration: its own package default,
    # never t1's current value.
    discard e.createTuner("t3", a)
    let s3 = rc.state(e.target("t3"))
    check s3.state_revision == 1 and s3.current.isNone
    check s3.staged.get.value == tunerValue()
    check provenanceOf(s3.staged.get.provenance) == pvPackageDefault
    check e.start("t3").tryGet.state == msReady
    check lastInput() == Opt.some(inputFor(tunerValue(), 1))
    check encode(rc.state(t1)).tryGet == encode(before).tryGet
    check e.view("t1").tryGet.state == msReady
    e.finish()

  test "[CFG-0063] [CFG-0068] [CFG-0069] [CFG-0070] [CFG-0072] a generated kit, bound statically, is started with the typed value and its revision, then with the next staged one":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    let a = tunerAccepted(default = Opt.some(tunerValue("kit-1", 4)), live = true)
    discard e.createTuner("k", a, "tuner_kit")
    let starts = tunerStarts.load
    check e.start("k").tryGet.state == msReady
    check tunerStarts.load == starts + 1
    let t = e.target("k")
    var s = rc.summary(t)
    check tunerLastRevision.load == s.current.get.value_revision
    check tunerLastVolume.load == 4'u32
    check rc.stage(t, s.state_revision, tunerValue("kit-2", 6)).code == ecOk
    check e.stop("k").tryGet.state == msUnloaded
    check e.start("k").tryGet.state == msReady
    s = rc.summary(t)
    check s.staged.isNone
    check tunerLastRevision.load == s.current.get.value_revision
    check tunerLastVolume.load == 6'u32
    e.finish()

# Runtime Control operations ---------------------------------------------------------------

suite "cfg.operations: the configuration methods (CONFIG §5; RUNTIME §9.3 l.2394-2457)":
  setup:
    resetTuner()
    let blobs = liveConfigBlobs()

  teardown:
    leftover()
    check liveConfigBlobs() == blobs

  test "[CFG-0006] [CFG-0058] [CFG-0107] [G235] an instance without a binding: a summary at revision 0, the other methods INVALID_PARAMS":
    let e = tunerEngine()
    let (c, rc) = e.startClient("c")
    let t = e.target(c.instance)
    let s = rc.summary(t)
    check s.state_revision == 0
    check s.schema_commitment.isNone and s.current.isNone and s.staged.isNone
    check rc.schemaOf(t).code == ecInvalidParams
    check rc.stateOf(t).code == ecInvalidParams
    let u = rc.stage(t, 0, tunerValue())
    check u.code == ecInvalidParams and u.detail.len == 0
    check rc.discardStaged(t, 0).code == ecInvalidParams
    e.finish()

  test "[G228] [CFG-0020] [CFG-0056] [CFG-0057] [RUN-0484] [RUN-0485] a target on another Runtime is INVALID_PARAMS; an unknown or refused one NOT_AUTHORISED":
    let e = tunerEngine(denying(deny(operation = "get_configuration")))
    let (_, rc) = e.startClient()
    discard e.createTuner("t1", tunerAccepted(default = Opt.some(tunerValue())))
    var away = e.target("t1")
    away.runtime_instance_id = "another-runtime"
    check rc.summaryOf(away).code == ecInvalidParams
    check rc.stage(away, 1, tunerValue()).code == ecInvalidParams
    check rc.summaryOf(e.target("nobody")).code == ecNotAuthorised
    check rc.stage(e.target("nobody"), 0, tunerValue()).code == ecNotAuthorised
    # Each method is authorized on its own.
    check rc.stateOf(e.target("t1")).code == ecNotAuthorised
    check rc.summaryOf(e.target("t1")).code == ecOk
    e.finish()

  test "[CFG-0005] [CFG-0061] get_configuration_schema returns the accepted binding; get_configuration one snapshot with the values":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    discard e.createTuner("t1", tunerAccepted(default = Opt.some(tunerValue())))
    let t = e.target("t1")
    let r = rc.schemaOf(t)
    check r.code == ecOk
    let schema =
      LogosNSRuntimeControlGetConfigurationSchemaResponse.decode(r.response).tryGet
    check schema.state_revision == 1
    check encode(schema.schema).tryGet == encode(tunerBinding()).tryGet
    check schema.target == t
    let st = rc.state(t)
    check st.state_revision == 1
    check st.schema_commitment == tunerCommitment()
    check st.current.isNone
    check st.staged.get.value == tunerValue()
    e.finish()

  test "[CFG-0030] [CFG-0034] [CFG-0036] [CFG-0053] [CFG-0059] [CFG-0060] [RUN-0918] stage and discard advance the revision; a stale revision or commitment is refused without detail":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    discard e.createTuner("t1", tunerAccepted())
    let t = e.target("t1")
    let v = tunerValue("radio-3", 9)
    let staged = rc.stage(t, 0, v).updated
    check staged.state_revision == 1
    check staged.staged.get.value == v
    check staged.staged.get.value_revision == 1
    check provenanceOf(staged.staged.get.provenance) == pvRuntimeControlUpdate
    check staged.target == t
    # An equal value is staged again, at a new revision (l.205).
    check rc.stage(t, 1, v).updated.state_revision == 2
    var r = rc.stage(t, 1, v)
    check r.code == ecInvalidParams and r.detail.len == 0
    var other = tunerCommitment()
    other.schema_root[0] = other.schema_root[0] xor 1
    r = rc.stage(t, 2, v, other)
    check r.code == ecVersionMismatch and r.detail.len == 0
    let d = rc.discardStaged(t, 2).updated
    check d.state_revision == 3 and d.staged.isNone
    # Nothing staged: nothing changes (l.207).
    check rc.discardStaged(t, 3).updated.state_revision == 3
    check rc.summary(t).state_revision == 3
    check rc.discardStaged(t, 2).code == ecInvalidParams
    e.finish()

  test "[CFG-0022] [CFG-0023] [CFG-0048] [CFG-0049] [IFC-0441] a malformed value is INVALID_PARAMS without detail; one not of the root carries configuration-schema-mismatch and its path":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    discard e.createTuner("t1", tunerAccepted())
    let t = e.target("t1")
    for bad in [@[0x18'u8], @[0x18'u8, 0x01], @[0x01'u8, 0x01]]:
      let r = rc.stage(t, 0, bad)
      check r.code == ecInvalidParams and r.detail.len == 0
    let wrong = encodeCbor(
      cborMap(@[(cbor("station"), cbor(5'u64)), (cbor("volume"), cbor(1'u64))])
    )
    let r = rc.stage(t, 0, wrong)
    check r.code == ecInvalidParams
    check r.detail.len > 0
    check reasonOf(r.detail) == "configuration-schema-mismatch"
    let path = decodeCbor(r.detail).tryGet.lookup("path").get
    check path.items.len == 1 and path.items[0].text == "station"
    check rc.summary(t).state_revision == 0
    e.finish()

  test "[IFC-0923] [IFC-0926] [IMPL-DECISION G241] a configuration value is checked at the Runtime's payload depth, counted from the value's root":
    proc nested(levels: int): seq[byte] =
      ## {station: [[...[]...]]}: `levels` containers in all.
      var x = cborArray()
      for _ in 3 .. levels:
        x = cborArray(x)
      encodeCbor(cborMap((cbor("station"), x)))

    for depth in [MinMaxDepth, 0]:
      let p = (if depth == 0: DefaultMaxDepth else: depth)
      checkpoint "max_payload_depth " & $depth
      let e = tunerEngine(depth = depth)
      let (_, rc) = e.startClient()
      discard e.createTuner("t1", tunerAccepted())
      let t = e.target("t1")
      let at = rc.stage(t, 0, nested(p))
      check at.code == ecInvalidParams
      check reasonOf(at.detail) == "configuration-schema-mismatch"
      let over = rc.stage(t, 0, nested(p + 1))
      check over.code == ecInvalidParams and over.detail.len == 0
      check rc.summary(t).state_revision == 0
      e.finish()
    # A provisioned value (host config) is checked the same way.
    let b = runtimeBinding(tunerAccepted())
    proc fault(levels, depth: int): ValueFault =
      checkValue(
        b.digest, b.document, b.root, b.commitment.subtreeRoot, nested(levels), depth
      ).error.fault

    check fault(MinMaxDepth, MinMaxDepth) == vfMismatch
    check fault(MinMaxDepth + 1, MinMaxDepth) == vfTooDeep
    check fault(MinMaxDepth + 1, DefaultMaxDepth) == vfMismatch
    drop(b.document)

  test "[CFG-0057] the schema-mismatch detail needs get_configuration_schema authority":
    let e = tunerEngine(denying(deny(operation = "get_configuration_schema")))
    let (_, rc) = e.startClient()
    discard e.createTuner("t1", tunerAccepted())
    let t = e.target("t1")
    let wrong = encodeCbor(cborMap(@[(cbor("volume"), cbor(1'u64))]))
    let r = rc.stage(t, 0, wrong)
    check r.code == ecInvalidParams and r.detail.len == 0
    check rc.stage(t, 0, tunerValue()).code == ecOk
    e.finish()

  test "[CFG-0037] [CFG-0038] [CFG-0039] [G233] a value that with the current one would not fit a get_configuration response is MODULE_ERROR, nothing changed":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    discard e.createTuner("t1", tunerAccepted())
    let t = e.target("t1")
    let big = tunerValue(pad = 8_388_500)
    check big.len <= MaxValueBytes
    check rc.stage(t, 0, big).updated.state_revision == 1
    check e.start("t1").tryGet.state == msReady
    check rc.summary(t).state_revision == 2
    let r = rc.stage(t, 2, tunerValue("radio-9", pad = 8_388_500))
    check r.code == ecModule
    check rc.summary(t).state_revision == 2
    check rc.stage(t, 2, tunerValue()).updated.state_revision == 3
    e.finish()

  test "[RUN-0642] [I87] get_execution_summary and list_modules report a configured instance without its configuration":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    let value = tunerValue("secret-station")
    discard e.createTuner("t1", tunerAccepted(default = Opt.some(value)))
    check e.start("t1").tryGet.state == msReady
    let station = @("secret-station".toOpenArrayByte(0, 13))
    let s = rcCall(
      rc,
      "get_execution_summary",
      encode(LogosNSRuntimeControlGetExecutionSummaryRequest(target: e.target("t1"))).tryGet,
    )
    check s.code == ecOk
    check not s.response.holds(value) and not s.response.holds(station)
    let summary =
      LogosNSRuntimeControlGetExecutionSummaryResponse.decode(s.response).tryGet
    check summary.target == e.target("t1")
    check summary.state.kind == LogosNSRuntimeControlStateKind.Ready
    let l = rcCall(
      rc,
      "list_modules",
      encode(LogosNSRuntimeControlListModulesRequest(instance: Opt.some("t1"))).tryGet,
    )
    check l.code == ecOk
    check not l.response.holds(value) and not l.response.holds(station)
    let listed = LogosNSRuntimeControlListModulesResponse.decode(l.response).tryGet
    check listed.modules.len == 1 and listed.modules[0].instance == Opt.some("t1")
    e.finish()

# Persistence and restarts -----------------------------------------------------------------

proc storeConfig(dir: string): EngineConfig =
  result = config(extra = tunerRegs())
  result.storeDir = Opt.some(dir)
  result.runtimeInstanceId = ""

proc storeEngine(dir: string): Engine =
  ## A persistent engine over `dir`, remembered so `leftover` can close it.
  result = openEngine(storeConfig(dir)).tryGet
  live = result

proc tunerAt(
    id: string, a: AcceptedConfiguration, binding = "tuner"
): BootstrapInstance =
  BootstrapInstance(instance: id, record: tuner(a, binding), configuration: Opt.some(a))

proc boot(
    e: Engine, tuners: seq[BootstrapInstance]
): Result[InstanceView, EngineError] =
  ## The client as orchestration instance, then `tuners`.
  e.bootstrap(@[BootstrapInstance(instance: "c", record: client())] & tuners, "c")

proc latestClient(): ptr LogosRuntimeControlBinding =
  cast[ptr LogosRuntimeControlBinding](clients[(clientInits.load - 1) mod MaxClients].load)

proc sideFiles(dir: string): seq[string] =
  for kind, f in walkDir(dir):
    if f.extractFilename.startsWith("cfg-"):
      result.add(f)

proc setMode(dir: string, mode: int) =
  when defined(posix):
    doAssert chmod(cstring(dir), Mode(mode)) == 0

proc asRoot(): bool =
  when defined(posix):
    getuid() == 0
  else:
    true

suite "cfg.sources: configuration state across restarts (CONFIG §4, §7; G141; I87)":
  setup:
    resetTuner()
    let blobs = liveConfigBlobs()

  teardown:
    leftover()
    check liveConfigBlobs() == blobs

  test "[CFG-0027] [CFG-0028] [CFG-0054] [CFG-0130] [CFG-0131] [G141] the state survives a restart; a provisioned value is staged again only when its value root changed":
    let dir = work / "store-restage"
    let (a, b) = (tunerValue("a"), tunerValue("b"))
    proc declared(p: Opt[seq[byte]]): BootstrapInstance =
      tunerAt("t1", tunerAccepted(default = Opt.some(tunerValue()), provisioned = p))

    var e = storeEngine(dir)
    check e.boot(@[declared(Opt.some(a))]).isOk
    check sideFiles(dir).len == 1
    var st = latestClient().state(e.target("t1"))
    check st.state_revision == 1 and st.staged.get.value == a
    e.finish()
    # The same value: nothing is staged again.
    e = storeEngine(dir)
    check e.boot(@[declared(Opt.some(a))]).isOk
    st = latestClient().state(e.target("t1"))
    check st.state_revision == 1 and st.staged.get.value == a
    check provenanceOf(st.staged.get.provenance) == pvProtectedProvisioning
    # A promotion survives the restart too.
    check e.start("t1").tryGet.state == msReady
    e.finish()
    e = storeEngine(dir)
    check e.boot(@[declared(Opt.some(a))]).isOk
    st = latestClient().state(e.target("t1"))
    check st.state_revision == 2 and st.current.get.value == a and st.staged.isNone
    e.finish()
    # A changed value is staged.
    e = storeEngine(dir)
    check e.boot(@[declared(Opt.some(b))]).isOk
    st = latestClient().state(e.target("t1"))
    check st.state_revision == 3 and st.staged.get.value == b
    check provenanceOf(st.staged.get.provenance) == pvProtectedProvisioning
    e.finish()
    # Removed, then the same value again: nothing is staged.
    for p in [Opt.none(seq[byte]), Opt.some(b)]:
      e = storeEngine(dir)
      check e.boot(@[declared(p)]).isOk
      check latestClient().summary(e.target("t1")).state_revision == 3
      e.finish()
    # Another value is.
    e = storeEngine(dir)
    check e.boot(@[declared(Opt.some(a))]).isOk
    check latestClient().state(e.target("t1")).staged.get.value == a
    e.finish()

  test "[CFG-0132] [CFG-0029] a changed binding or a lost configuration record does not restore the instance":
    let dir = work / "store-changed"
    var e = storeEngine(dir)
    check e.boot(@[tunerAt("t1", tunerAccepted(default = Opt.some(tunerValue())))]).isOk
    e.finish()
    e = storeEngine(dir)
    let r = e.boot(@[tunerAt("t1", tunerAccepted(live = true), "tuner_live")])
    check r.isErr and r.error.code == ecInvalidParams and "t1" in r.error.message
    e.finish()
    for f in sideFiles(dir):
      removeFile(f)
    let opened = openEngine(storeConfig(dir))
    check opened.isErr
    check opened.error.code == ecModule and "t1" in opened.error.message

  test "[G233] [CFG-0039] a provisioned value that would not fit beside the current one fails the start, nothing staged":
    let dir = work / "store-big"
    var e = storeEngine(dir)
    let big = tunerValue("a", pad = 8_388_500)
    check e.boot(@[tunerAt("t1", tunerAccepted(provisioned = Opt.some(big)))]).isOk
    check e.start("t1").tryGet.state == msReady
    e.finish()
    e = storeEngine(dir)
    let other = tunerValue("b", pad = 8_388_500)
    let r = e.boot(@[tunerAt("t1", tunerAccepted(provisioned = Opt.some(other)))])
    check r.isErr and r.error.code == ecModule and "t1" in r.error.message
    e.finish()
    e = storeEngine(dir)
    check e.boot(@[tunerAt("t1", tunerAccepted(provisioned = Opt.some(big)))]).isOk
    let s = latestClient().summary(e.target("t1"))
    check s.state_revision == 2 and s.staged.isNone
    e.finish()

  test "[G190] an orchestration instance with no configuration value fails the bootstrap with MODULE_ERROR":
    let e = tunerEngine()
    let r = e.bootstrap(@[tunerAt("t1", tunerAccepted())], "t1")
    check r.isErr and r.error.code == ecModule
    check e.view("t1").tryGet.execution.intent == inRequested
    check tunerInits.load == 0
    e.finish()

  test "[RUN-1019] [I87] retiring an instance removes its configuration record":
    let dir = work / "store-retire"
    let e = storeEngine(dir)
    check e.boot(@[]).isOk
    let rc = latestClient()
    discard e.createTuner("t1", tunerAccepted(default = Opt.some(tunerValue())))
    check sideFiles(dir).len == 1
    let v = e.view("t1").tryGet
    let r = rcCall(
      rc,
      "retire_module",
      encode(
        LogosNSRuntimeControlRetireModuleRequest(
          target: e.target("t1"), expected_execution_revision: v.execution.revision
        )
      ).tryGet,
    )
    check r.code == ecOk
    check sideFiles(dir).len == 0
    e.finish()

  test "[G162] [G168] a start refused for want of a configuration value keeps intent and clears a retained execution refusal":
    let dir = work / "store-g162"
    var cfg = storeConfig(dir)
    cfg.policy =
      denying(AuthzRule(action: Opt.some(aaExecute), target: "t1", outcome: azDeny))
    var e = openEngine(cfg).tryGet
    live = e
    check e.boot(@[]).isOk
    discard e.createTuner("t1", tunerAccepted())
    let denied = e.start("t1")
    check denied.isErr and denied.error.code == ecNotAuthorised
    check e.view("t1").tryGet.failure.get.kind == fkAuthorityDenied
    e.finish()
    # Allowed now, and still without a value.
    e = storeEngine(dir)
    check e.boot(@[]).isOk
    check e.view("t1").tryGet.failure.get.kind == fkAuthorityDenied
    let r = e.start("t1")
    check r.isErr and r.error.code == ecNotReady
    let v = e.view("t1").tryGet
    check v.failure.isNone
    check v.state == msUnloaded and v.execution.intent == inRequested
    check tunerInits.load == 0
    e.finish()

  test "[I87] a configuration record that cannot be written creates nothing":
    if asRoot():
      skip()
    else:
      let dir = work / "store-readonly"
      let e = storeEngine(dir)
      check e.boot(@[]).isOk
      setMode(dir, 0o500)
      let r = e.create(
        tuner(tunerAccepted()), "t1", configuration = Opt.some(tunerAccepted())
      )
      setMode(dir, 0o700)
      check r.isErr and r.error.code == ecModule
      check e.view("t1").isErr
      check sideFiles(dir).len == 0
      e.finish()

# Live reconfiguration -----------------------------------------------------------------------

type ApplyArg =
  (ptr LogosRuntimeControlBinding, LogosNSRuntimeModuleInstanceAddress, uint64)

var
  applyReply: Atomic[int] ## the code `applyOn` got, or -2 while it waits
  applyRevision: Atomic[int] ## and on success the applied value revision

proc applyOn(arg: ApplyArg) {.thread.} =
  let r = arg[0].applyOf(arg[1], arg[2])
  if r.code == ecOk:
    let a = LogosNSRuntimeControlApplyConfigurationResponse.decode(r.response)
    applyRevision.store(int(a.get.applied_value_revision))
  applyReply.store(ord(r.code))

proc applying(
    rc: ptr LogosRuntimeControlBinding,
    t: LogosNSRuntimeModuleInstanceAddress,
    revision: uint64,
    th: var Thread[ApplyArg],
): bool =
  ## Applies from `th` with the hook held, and waits until the hook is entered.
  applyReply.store(-2)
  applyRevision.store(0)
  let entered = applyEntered.load
  applyHold.store(true)
  createThread(th, applyOn, (rc, t, revision))
  waitUntil(
    proc(): bool =
      applyEntered.load > entered
  )

proc shutdownOn(e: Engine) {.thread.} =
  e.shutdown()

proc readyLive(
    e: Engine, rc: ptr LogosRuntimeControlBinding, id: string
): LogosNSRuntimeModuleInstanceAddress =
  ## A live tuner `id`, started with its default (state revision 2 once that
  ## is current), with `radio-2` then staged at revision 3.
  let a = tunerAccepted(default = Opt.some(tunerValue()), live = true)
  discard e.createTuner(id, a, binding = "tuner_live")
  doAssert e.start(id).tryGet.state == msReady
  result = e.target(id)
  doAssert rc.stage(result, 2, tunerValue("radio-2", 9)).updated.state_revision == 3

let
  tunerSet = acceptContractSet(readFile(repo / "tests/kit/tuner_module.cddl")).tryGet
  tunerRoot = tunerSet.primary.root
  tunerSchema = encodeCbor(schemaResponse(tunerSet, tunerRoot).tryGet)

proc nowOf(h: var LogosRouteHandle): RadioNowResponse =
  ## `radio.now` of the generated kit tuner, through `h`.
  let r = h.raw("now", encodeCbor(toCbor(RadioNowRequest())))
  doAssert r.code == ecOk, $r.code
  fromChecked(RadioNowResponse, decodeCbor(r.response).tryGet)

proc liveEngine(applyMs = 0, stopMs = 0): Engine =
  var cfg = config(extra = tunerRegs())
  if applyMs > 0:
    cfg.applyDeadline = initDuration(milliseconds = applyMs * Slow)
  if stopMs > 0:
    cfg.stopDeadline = initDuration(milliseconds = stopMs * Slow)
  fixtureEngine(cfg)

var
  asyncCode: Atomic[int] ## the code the latest asynchronous apply completed with
  asyncDone: Atomic[int] ## asynchronous applies completed

proc onApplied(
    userData: pointer,
    r: LogosResult,
    response: ptr UncheckedArray[uint8],
    len: csize_t,
    owner: LogosResponseOwner,
) {.cdecl, gcsafe, raises: [].} =
  if not owner.release.isNil:
    owner.release(owner.state)
  asyncCode.store(int(r.code))
  asyncDone += 1

proc applyAsync(
    rc: ptr LogosRuntimeControlBinding,
    t: LogosNSRuntimeModuleInstanceAddress,
    revision: uint64,
    timeoutMs = -1,
): LogosAsyncCall =
  ## `apply_configuration` as an asynchronous Runtime Control call, submitted.
  let params = encode(
    LogosNSRuntimeControlApplyConfigurationRequest(
      target: t, expected_state_revision: revision
    )
  ).tryGet
  var o = LogosAsyncOptions(
    abiVersion: AsyncCallAbiVersion,
    structSize: csize_t(sizeof(LogosAsyncOptions)),
    hasTimeout: timeoutMs >= 0,
    timeoutMs: uint64(max(timeoutMs, 0)),
  )
  var cb = LogosAsyncCallbacks(
    abiVersion: AsyncCallAbiVersion,
    structSize: csize_t(sizeof(LogosAsyncCallbacks)),
    complete: onApplied,
  )
  let r = rc.vtable.prepareCall(
    rc,
    "apply_configuration",
    cast[ptr UncheckedArray[uint8]](unsafeAddr params[0]),
    csize_t(params.len),
    addr o,
    addr cb,
    addr result,
  )
  doAssert r.code == 0
  result.vtable.submit(addr result)

suite "cfg.apply: live reconfiguration (CONFIG §8; LOADER §8, §11; I87)":
  setup:
    resetTuner()
    let blobs = liveConfigBlobs()

  teardown:
    applyHold.store(false)
    tunerGate.store(false)
    leftover()
    check liveConfigBlobs() == blobs

  test "[CFG-0089] [CFG-0092] [CFG-0094] [CFG-0102] [CFG-0103] [CFG-0144] [G236] apply hands the staged record to the hook as one configuration_input, makes it current and answers its value revision; the lifecycle does not change":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    let t = e.readyLive(rc, "t1")
    let before = e.view("t1").tryGet
    let r = rc.applyOf(t, 3).applied
    check r.target == t
    check r.state_revision == 4
    check r.applied_value_revision == 3
    check lastApplied() == inputFor(tunerValue("radio-2", 9), 3)
    let s = rc.summary(t)
    check s.state_revision == 4
    check s.current.get.value_revision == 3 and s.staged.isNone
    check provenanceOf(s.current.get.provenance) == pvRuntimeControlUpdate
    let after = e.view("t1").tryGet
    check after.state == msReady
    check after.execution.revision == before.execution.revision
    check tunerInits.load == 1 and tunerDestroys.load == 0
    # Nothing is staged now.
    check rc.applyOf(t, 4).code == ecInvalidParams
    e.finish()

  test "[CFG-0093] [CFG-0141] [CFG-0142] [CFG-0143] [CFG-0090] [CFG-0006] [G171] [G228] the preconditions, in their row order, refuse without invoking the hook or changing anything":
    let e = tunerEngine()
    let (c, rc) = e.startClient("c")
    var r = rc.applyOf(e.target(c.instance), 0)
    check r.code == ecInvalidParams and r.detail.len == 0
    var away = e.target("t1")
    away.runtime_instance_id = "another-runtime"
    check rc.applyOf(away, 3).code == ecInvalidParams
    let t = e.readyLive(rc, "t1")
    r = rc.applyOf(t, 2)
    check r.code == ecInvalidParams and r.detail.len == 0
    check rc.discardStaged(t, 3).updated.state_revision == 4
    r = rc.applyOf(t, 4)
    check r.code == ecInvalidParams and r.detail.len == 0
    # A startup-only binding.
    discard e.createTuner("t2", tunerAccepted(default = Opt.some(tunerValue())))
    check e.start("t2").tryGet.state == msReady
    let t2 = e.target("t2")
    check rc.stage(t2, 2, tunerValue("radio-2")).code == ecOk
    r = rc.applyOf(t2, 3)
    check r.code == ecInvalidParams and r.detail.len == 0
    # Not ready: after the request's own rows.
    let a = tunerAccepted(default = Opt.some(tunerValue()), live = true)
    discard e.createTuner("t3", a, binding = "tuner_live")
    let t3 = e.target("t3")
    check rc.applyOf(t3, 0).code == ecInvalidParams
    check rc.applyOf(t3, 1).code == ecNotReady
    check applyEntered.load == 0
    check rc.summary(t).state_revision == 4
    check rc.summary(t2).state_revision == 3
    check rc.summary(t3).state_revision == 1
    e.finish()

  test "[CFG-0141] the binding's, the staged record's and the realization's commitments must agree (the VERSION_MISMATCH row)":
    let c = tunerAccepted().roots
    var d = c
    d.subtreeRoot[0] = d.subtreeRoot[0] xor 1
    check commitmentsAgree(c, c, c)
    check not commitmentsAgree(d, c, c)
    check not commitmentsAgree(c, d, c)
    check not commitmentsAgree(c, c, d)

  test "[CFG-0057] apply_configuration is authorized on its own; a refusal invokes nothing":
    let e = tunerEngine(denying(deny(operation = "apply_configuration")))
    let (_, rc) = e.startClient()
    let t = e.readyLive(rc, "t1")
    check rc.applyOf(t, 3).code == ecNotAuthorised
    check applyEntered.load == 0
    check rc.summary(t).state_revision == 3
    e.finish()

  test "[CFG-0145] [CFG-0146] a valid rejection is MODULE_ERROR without the hook's status; nothing changes and the instance stays ready":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    let t = e.readyLive(rc, "t1")
    applyMode.store(1)
    let r = rc.applyOf(t, 3)
    check r.code == ecModule
    check "secret" notin r.message and r.detail.len == 0
    check applyCalls.load == 1
    let s = rc.summary(t)
    check s.state_revision == 3 and s.current.get.value_revision == 1
    check s.staged.get.value_revision == 3
    check e.view("t1").tryGet.state == msReady
    applyMode.store(0)
    check rc.applyOf(t, 3).applied.state_revision == 4
    e.finish()

  test "[CFG-0149] a caller's timeout or cancellation does not decide the application; the hook's outcome does (CONFIG §8 l.315)":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    for (id, timeoutMs) in [("t1", 50), ("t2", -1)]:
      let t = e.readyLive(rc, id)
      let (entered, completed) = (applyEntered.load, asyncDone.load)
      applyHold.store(true)
      var call = rc.applyAsync(t, 3, timeoutMs)
      check waitUntil(
        proc(): bool =
          applyEntered.load > entered
      )
      if timeoutMs < 0:
        call.vtable.cancel(addr call)
      check waitUntil(
        proc(): bool =
          asyncDone.load > completed
      )
      check asyncCode.load == ord(if timeoutMs < 0: ecCancelled else: ecTimeout)
      # The caller has its outcome; the application has none yet.
      check rc.summary(t).state_revision == 3
      applyHold.store(false)
      check waitUntil(
        proc(): bool =
          rc.summary(t).state_revision == 4
      )
      let s = rc.summary(t)
      check s.current.get.value_revision == 3 and s.staged.isNone
      check provenanceOf(s.current.get.provenance) == pvRuntimeControlUpdate
      check e.view(id).tryGet.state == msReady
      call.vtable.release(addr call)
    e.finish()

  test "[CFG-0101] [CFG-0147] [CFG-0148] [RUN-1052] an invalid hook result is indeterminate: MODULE_ERROR, `error` with configuration-indeterminate, the realization released and nothing promoted":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    let t = e.readyLive(rc, "t1")
    applyMode.store(2)
    check rc.applyOf(t, 3).code == ecModule
    let v = e.view("t1").tryGet
    check v.state == msError
    check v.failure.get.kind == fkConfigurationIndeterminate
    check waitUntil(
      proc(): bool =
        not e.cleanupPending("t1")
    )
    check tunerDestroys.load == 1
    let s = rc.summary(t)
    check s.state_revision == 3 and s.current.get.value_revision == 1
    check s.staged.get.value_revision == 3
    # A new start delivers the staged record.
    applyMode.store(0)
    check e.start("t1").tryGet.state == msReady
    check lastInput() == Opt.some(inputFor(tunerValue("radio-2", 9), 3))
    e.finish()

  test "[CFG-0095] [CFG-0100] [CFG-0040] one application at a time; an update during it is admitted and stays staged when the promotion does not clear it":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    let t = e.readyLive(rc, "t1")
    var th: Thread[ApplyArg]
    check rc.applying(t, 3, th)
    check rc.applyOf(t, 3).code == ecNotReady
    check rc.stage(t, 3, tunerValue("radio-3", 2)).updated.state_revision == 4
    applyHold.store(false)
    joinThread(th)
    check applyReply.load == ord(ecOk)
    check applyRevision.load == 3
    let s = rc.summary(t)
    check s.state_revision == 5
    check s.current.get.value_revision == 3
    check s.staged.get.value_revision == 4
    check applyEntered.load == 1
    e.finish()

  test "[CFG-0136] [CFG-0137] [CFG-0139] [G61] past the apply deadline the outcome is indeterminate: MODULE_ERROR at once, the context kept until the hook returns, its late success ignored":
    let e = liveEngine(applyMs = 100)
    let (_, rc) = e.startClient()
    let t = e.readyLive(rc, "t1")
    var th: Thread[ApplyArg]
    check rc.applying(t, 3, th)
    check waitUntil(
      proc(): bool =
        applyReply.load != -2
    )
    check applyReply.load == ord(ecModule)
    joinThread(th)
    let v = e.view("t1").tryGet
    check v.state == msError
    check v.failure.get.kind == fkConfigurationIndeterminate
    check applyCalls.load == 0 and tunerDestroys.load == 0
    check e.cleanupPending("t1")
    applyHold.store(false)
    check waitUntil(
      proc(): bool =
        not e.cleanupPending("t1")
    )
    check tunerDestroys.load == 1 and applyCalls.load == 1
    let s = rc.summary(t)
    check s.state_revision == 3 and s.current.get.value_revision == 1
    check s.staged.get.value_revision == 3
    check e.view("t1").tryGet.state == msError
    e.finish()

  test "[CFG-0138] [CFG-0140] a stop during an application waits for the hook; a valid result is still made current, and the stop then completes":
    let e = liveEngine(stopMs = 10_000)
    let (_, rc) = e.startClient()
    let t = e.readyLive(rc, "t1")
    var th: Thread[ApplyArg]
    check rc.applying(t, 3, th)
    var st: Thread[(Engine, string)]
    check e.stopping("t1", st)
    check tunerDestroys.load == 0
    check stopReply.load == -2
    applyHold.store(false)
    joinThread(th)
    check applyReply.load == ord(ecOk) and applyRevision.load == 3
    joinThread(st)
    check stopReply.load == ord(msUnloaded)
    check tunerDestroys.load == 1
    let v = e.view("t1").tryGet
    check v.state == msUnloaded and v.failure.isNone
    check v.execution.intent == inStopped
    check rc.summary(t).current.get.value_revision == 3
    e.finish()

  test "[RUN-0656] [RUN-0690] [CFG-0103] [CFG-0140] a failure the module reports during an application: `error` at once, the hook's valid result still made current without restoring readiness, the realization released once it returns [IMPL]":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    let t = e.readyLive(rc, "t1")
    let own = cast[ptr LogosRuntimeControlBinding](tunerRc.load)
    var th: Thread[ApplyArg]
    check rc.applying(t, 3, th)
    let r = rcCall(
      own,
      "report_failure",
      encode(LogosNSRuntimeControlReportFailureRequest(reason: Opt.some("lost"))).tryGet,
    )
    check r.code == ecOk
    check waitUntil(
      proc(): bool =
        e.view("t1").tryGet.state == msError
    )
    check tunerDestroys.load == 0
    check applyReply.load == -2
    applyHold.store(false)
    joinThread(th)
    check applyReply.load == ord(ecOk)
    check applyRevision.load == 3
    check waitUntil(
      proc(): bool =
        tunerDestroys.load == 1
    )
    let v = e.view("t1").tryGet
    check v.state == msError
    let s = rc.summary(t)
    check s.current.get.value_revision == 3 and s.staged.isNone
    e.finish()

  test "[G237] [CFG-0136] [CFG-0138] past the apply deadline during a stop: `error` with configuration-indeterminate, then `unloaded` once the stop completes in time":
    let e = liveEngine(applyMs = 1000, stopMs = 10_000)
    let (_, rc) = e.startClient()
    let t = e.readyLive(rc, "t1")
    var th: Thread[ApplyArg]
    check rc.applying(t, 3, th)
    var st: Thread[(Engine, string)]
    check e.stopping("t1", st)
    check waitUntil(
      proc(): bool =
        applyReply.load != -2
    )
    check applyReply.load == ord(ecModule)
    var v = e.view("t1").tryGet
    check v.state == msError
    check v.failure.get.kind == fkConfigurationIndeterminate
    check stopReply.load == -2
    # A second stop is answered with the state at once, as during `stopping`.
    check e.stop("t1").tryGet.state == msError
    applyHold.store(false)
    joinThread(th)
    joinThread(st)
    check stopReply.load == ord(msUnloaded)
    v = e.view("t1").tryGet
    check v.state == msUnloaded and v.failure.isNone
    check tunerDestroys.load == 1
    check rc.summary(t).current.get.value_revision == 1
    e.finish()

  test "[G237] [G180] past the stop deadline as well, the stop answers with cleanup-timeout and the instance stays `error` when the hook returns":
    let e = liveEngine(applyMs = 500, stopMs = 1500)
    let (_, rc) = e.startClient()
    let t = e.readyLive(rc, "t1")
    var th: Thread[ApplyArg]
    check rc.applying(t, 3, th)
    var st: Thread[(Engine, string)]
    check e.stopping("t1", st)
    check waitUntil(
      proc(): bool =
        applyReply.load != -2
    )
    check e.view("t1").tryGet.failure.get.kind == fkConfigurationIndeterminate
    check waitUntil(
      proc(): bool =
        stopReply.load != -2
    )
    joinThread(st)
    check stopReply.load == ord(msError)
    check e.view("t1").tryGet.failure.get.kind == fkCleanupTimeout
    applyHold.store(false)
    joinThread(th)
    check waitUntil(
      proc(): bool =
        not e.cleanupPending("t1")
    )
    let v = e.view("t1").tryGet
    check v.state == msError and v.failure.get.kind == fkCleanupTimeout
    check rc.summary(t).current.get.value_revision == 1
    e.finish()

  test "[CFG-0138] [CFG-0140] shutdown waits for an application in flight, whose valid result is still made current":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    let t = e.readyLive(rc, "t1")
    var th: Thread[ApplyArg]
    check rc.applying(t, 3, th)
    var sh: Thread[Engine]
    createThread(sh, shutdownOn, e)
    check waitUntil(
      proc(): bool =
        e.view("t1").tryGet.state == msStopping
    )
    check tunerDestroys.load == 0
    applyHold.store(false)
    joinThread(th)
    check applyReply.load == ord(ecOk) and applyRevision.load == 3
    joinThread(sh)
    check tunerDestroys.load == 1
    check e.view("t1").tryGet.state == msUnloaded
    e.finish()

  test "[CFG-0092] [CFG-0096] [CFG-0097] [CFG-0098] [CFG-0145] a generated kit applies the typed value; its refusal leaves the value in force":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    let a = tunerAccepted(default = Opt.some(tunerValue("kit-1", 4)), live = true)
    discard e.createTuner("k", a, "tuner_kit")
    check e.start("k").tryGet.state == msReady
    let t = e.target("k")
    check rc.stage(t, 2, tunerValue("kit-2", 6)).code == ecOk
    check rc.applyOf(t, 3).applied.applied_value_revision == 3
    check tunerAppliedVolume.load == 6'u32
    check rc.stage(t, 4, tunerValue("refuse", 8)).code == ecOk
    check rc.applyOf(t, 5).code == ecModule
    check tunerAppliedVolume.load == 6'u32
    check e.view("k").tryGet.state == msReady
    let s = rc.summary(t)
    check s.current.get.value_revision == 3 and s.staged.get.value_revision == 5
    e.finish()

  test "[IFC-0270] provider calls keep running while a configuration is applied, and see the value in force until it is promoted":
    let e = tunerEngine()
    let (_, rc) = e.startClient()
    let a = tunerAccepted(default = Opt.some(tunerValue("kit-1", 4)), live = true)
    var rec = tuner(a, "tuner_kit")
    rec.primaryContract = Opt.some(tunerRoot)
    discard e.create(rec, "k", configuration = Opt.some(a)).tryGet
    check e.start("k").tryGet.state == msReady
    let t = e.target("k")
    check rc.stage(t, 2, tunerValue("hold", 6)).code == ecOk
    let route = rc.establish("now", root = tunerRoot)
    check route.code == ecOk
    var (code, h) =
      rc.materialize(route.routesOf.routes[0].route, tunerRoot, tunerSchema)
    check code == ecOk
    check h.nowOf().station == "kit-1"
    tunerGate.store(true)
    applyReply.store(-2)
    var th: Thread[ApplyArg]
    createThread(th, applyOn, (rc, t, 3'u64))
    check waitUntil(
      proc(): bool =
        tunerHeld.load > 0
    )
    # The hook is held: calls are still answered, from the value in force.
    for _ in 0 ..< 3:
      let now = h.nowOf()
      check now.station == "kit-1" and now.volume == 4'u32 and now.applied == 0
    check applyReply.load == -2
    check e.view("k").tryGet.state == msReady
    tunerGate.store(false)
    joinThread(th)
    check applyReply.load == ord(ecOk)
    let now = h.nowOf()
    check now.station == "hold" and now.volume == 6'u32 and now.applied == 1
    h.release()
    e.finish()
