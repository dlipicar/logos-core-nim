## The Runtime's persistent state store (RUNTIME §9.2 l.2623-2641, §9.3
## l.3504-3507, l.3537-3543, l.3585-3588, l.3627-3633). [IMPL] (DECISIONS I82)
##
## One snapshot, `<store_dir>/runtime-state.cbor`: one Logos deterministic-CBOR
## `lcn.rs_state` value (`store.cddl`, codecs generated into `store_types.nim`).
## The Runtime thread rewrites it whole, by atomic replace (`durable.nim`),
## before it exposes a change. Side records (`putSide`) live next to it, one
## file each, for state that should not be in every snapshot (step 9's
## configuration); at open, side records of instances the snapshot does not
## know are removed. The directory's lock is held from `openStore` to `close`:
## taking it is the evidence that no earlier holder, and none of its direct
## realizations, is still running.
##
## Corruption (bytes that do not decode deterministically, a schema mismatch,
## another format, or a broken invariant) fails `openStore`, and nothing is
## modified. There is no repair: the host restores a backup or starts a new
## store (docs/HOST-CONFIG.md).
##
## Without a directory the store is in memory: nothing is written, and side
## records are kept in a table.

{.push raises: [].}

import std/[os, sets, strutils, tables]
import results
import logos_sdk/cbor
import logos_sdk/cbor/utf8
import logos_sdk/crypto/blake3
import ../durable
import logos_sdk/codegen/common_types
import ./[forwarded, plumbing, store_types]

export results

const
  StoreFormat* = "logos-core-nim.runtime-state.v2"
    ## [IMPL] (DECISIONS G357) what `write` writes; a v1 store is read as a v2
    ## store without `completed_shutdown` and `enforced`
  StoreFormatV1* = "logos-core-nim.runtime-state.v1"
  SnapshotName* = "runtime-state.cbor"
  MaxStoreBytes* = 64 * 1024 * 1024
    ## [IMPL] the largest snapshot or side record written or read; records may
    ## carry 1 MiB permission constraints (`records.MaxConstraintsBytes`)
  SideSuffix = ".cbor"

type
  StoredInstance* = object ## One `lcn.rs_instance`, as the engine uses it.
    instance*: string
    providerId*: string ## empty when the record expects no contract
    created*: bool ## made by `create_module` (else by the host)
    record*: ModuleRecord
    state*: ModuleState
    failure*: Opt[Failure]
    revision*: uint64
    intent*: Intent
    intentRevision*: uint64 ## when `intent` is `requested`
    origin*: Origin ## when `intent` is `requested`
    enforced*: Opt[Failure]
      ## [G357] when `state` is `stopping`: the classification an enforcement
      ## stop leaves when it completes (RUNTIME l.3613)

  RetiredId* = object ## A tombstone: a retired host-assigned instance id.
    instance*: string
    stateAssignment*: Opt[string] ## the assignment it keeps reserved

  CreateKey* = object ## One `create_module` key association.
    consumer*: string
    key*: string
    module*: string
    instance*: string

  Snapshot* = object
    runtimeInstanceId*: string
    epoch*: uint64
    instances*: seq[StoredInstance]
    retired*: seq[RetiredId]
    createKeys*: seq[CreateKey]
    completedShutdown*: bool
      ## [G357] this snapshot is the last one of a completed shutdown (RUNTIME
      ## l.3637): its `stopping` records ended cleanly. Only the snapshot
      ## `finishShutdown` writes carries it; the next run's first write drops it.

  Store* = object
    dir: string ## empty: in memory
    lock: DurableLock
    memory: Table[string, seq[byte]] ## in-memory side records, by file name

func isPersistent*(s: Store): bool =
  s.dir.len > 0

func dir*(s: Store): string =
  s.dir

# Conversions ------------------------------------------------------------------------

func commitment(d: Digest): SchemaCommitment =
  SchemaCommitment(schema_root: @d)

func digestOf(c: SchemaCommitment): Result[Digest, string] =
  if c.schema_root.len != 32:
    return err("a schema root is not 32 bytes")
  var d: Digest
  for i in 0 ..< 32:
    d[i] = c.schema_root[i]
  ok(d)

func rsArtifact(a: ArtifactRecord): LcnRsArtifact =
  LcnRsArtifact(
    id: a.id, local_path: a.localPath, hash: @(a.hash), hash_suite: a.hashSuite
  )

func artifactOf(a: LcnRsArtifact): Result[ArtifactRecord, string] =
  if a.hash.len != 32:
    return err("an artifact hash is not 32 bytes")
  var h: array[32, byte]
  for i in 0 ..< 32:
    h[i] = a.hash[i]
  ok(
    ArtifactRecord(id: a.id, localPath: a.local_path, hash: h, hashSuite: a.hash_suite)
  )

func toRs*(r: ModuleRecord): LcnRsRecord =
  ## The persisted form of a record: `lcn.rs_record`.
  result = LcnRsRecord(module: r.module, state_assignment: r.stateAssignment)
  case r.strategy
  of stDirectStatic:
    result.implementation = LcnRsImplementation(
      kind: LcnRsImplementationKind.Direct_static,
      arm_Direct_static: LcnRsImplementationARDirectStaticMap(binding: r.binding),
    )
  of stDirectDynamic:
    result.implementation = LcnRsImplementation(
      kind: LcnRsImplementationKind.Direct_dynamic,
      arm_Direct_dynamic:
        LcnRsImplementationARDirectDynamicMap(artifact: rsArtifact(r.artifact)),
    )
  of stHostedDynamic:
    # [plan §2.13] The selection only: nothing about a Module Host (LDR-0149).
    result.implementation = LcnRsImplementation(
      kind: LcnRsImplementationKind.Process_hosted_dynamic,
      arm_Process_hosted_dynamic:
        LcnRsImplementationARProcessHostedDynamicMap(artifact: rsArtifact(r.artifact)),
    )
  if r.primaryContract.isSome:
    result.primary_contract = Opt.some(commitment(r.primaryContract.get))
  if r.implements.len > 0:
    var s: seq[SchemaCommitment]
    for d in r.implements:
      s.add(commitment(d))
    result.implements = Opt.some(s)
  if r.extends.len > 0:
    # [plan §2.1] Written only when non-empty, so a record without `extends`
    # keeps its bytes and its fact bytes (G160).
    var s: seq[SchemaCommitment]
    for d in r.extends:
      s.add(commitment(d))
    result.extends = Opt.some(s)
  if r.requires.len > 0:
    var s: seq[LcnRsRequirement]
    for q in r.requires:
      s.add(
        LcnRsRequirement(
          contract: commitment(q.contract),
          cardinality: LcnRsRequirementCardinalityChoice(
            kind: (
              if q.cardinality == cardSingle:
                LcnRsRequirementCardinalityChoiceKind.Single
              else:
                LcnRsRequirementCardinalityChoiceKind.All_runtime_visible
            )
          ),
        )
      )
    result.requires = Opt.some(s)
  if r.requestedPermissions.len > 0:
    var s: seq[LcnRsPermission]
    for p in r.requestedPermissions:
      s.add(
        LcnRsPermission(
          permission: p.permission, constraints: p.constraints, reason: p.reason
        )
      )
    result.requested_permissions = Opt.some(s)
  if r.configuration.isSome:
    result.configuration_commitment = Opt.some(@(r.configuration.get))

func fromRs*(r: LcnRsRecord): Result[ModuleRecord, string] =
  ## A record read back; it must pass `checkRecord`, and a present array is
  ## non-empty (the writer never writes an empty one).
  var m = ModuleRecord(module: r.module, stateAssignment: r.state_assignment)
  case r.implementation.kind
  of LcnRsImplementationKind.Direct_static:
    m.strategy = stDirectStatic
    m.binding = r.implementation.arm_Direct_static.binding
  of LcnRsImplementationKind.Direct_dynamic:
    m.strategy = stDirectDynamic
    m.artifact = ?artifactOf(r.implementation.arm_Direct_dynamic.artifact)
  of LcnRsImplementationKind.Process_hosted_dynamic:
    m.strategy = stHostedDynamic
    m.placement = "process"
    m.artifact = ?artifactOf(r.implementation.arm_Process_hosted_dynamic.artifact)
  if r.primary_contract.isSome:
    m.primaryContract = Opt.some(?digestOf(r.primary_contract.get))
  if r.implements.isSome:
    if r.implements.get.len == 0:
      return err("a record's implements is present but empty")
    for c in r.implements.get:
      m.implements.add(?digestOf(c))
  if r.extends.isSome:
    if r.extends.get.len == 0:
      return err("a record's extends is present but empty")
    for c in r.extends.get:
      m.extends.add(?digestOf(c))
  if r.requires.isSome:
    if r.requires.get.len == 0:
      return err("a record's requires is present but empty")
    for q in r.requires.get:
      let contract = ?digestOf(q.contract)
      m.requires.add(
        ProviderRequirement(
          contract: contract,
          cardinality: (
            if q.cardinality.kind == LcnRsRequirementCardinalityChoiceKind.Single:
              cardSingle
            else:
              cardAllVisible
          ),
        )
      )
  if r.requested_permissions.isSome:
    if r.requested_permissions.get.len == 0:
      return err("a record's requested_permissions is present but empty")
    for p in r.requested_permissions.get:
      m.requestedPermissions.add(
        RequestedPermission(
          permission: p.permission, constraints: p.constraints, reason: p.reason
        )
      )
  if r.configuration_commitment.isSome:
    # [IMPL-DECISION I87] the accepted binding's digest; the binding and the
    # state are the instance's `cfg` side record.
    let c = r.configuration_commitment.get
    if c.len != 32:
      return err("a configuration commitment is not 32 bytes")
    var d: Digest
    for i in 0 ..< 32:
      d[i] = c[i]
    m.configuration = Opt.some(d)
  ?checkRecord(m)
  ok(m)

proc recordBytes*(r: ModuleRecord): seq[byte] =
  ## The deterministic CBOR of a record's persisted form.
  encodeCbor(toCbor(toRs(r)))

proc factBytes*(r: ModuleRecord): seq[byte] =
  ## [IMPL-DECISION G160, interim (TF-08)] The declaration facts of a record:
  ## its persisted form without the artifact's `local_path` (where the accepted
  ## artifact is found, not what it is) and without permission `reason` text.
  var x = r
  x.artifact.localPath = ""
  for p in x.requestedPermissions.mitems:
    p.reason = Opt.none(string)
  recordBytes(x)

const ConfigSide* = "cfg" ## [I87] the side-record kind of an instance's configuration

proc configBytes*(s: ConfigState): Result[seq[byte], string] =
  ## [IMPL-DECISION I87] The `cfg` side record of one configurable instance:
  ## its whole binding and its state, never the in-flight attempt.
  let (binding, state) = encodeStored(s)
  var r = LcnCfgRecord(binding: binding, state: state)
  if s.lastProvisioned.isSome:
    r.last_provisioned = Opt.some(@(s.lastProvisioned.get))
  encode(r)

proc configOf*(data: openArray[byte], digest: Digest): Result[ConfigState, string] =
  ## A `cfg` side record read back, for an instance whose record names the
  ## binding `digest`; the result owns new blobs.
  let r = ?LcnCfgRecord.decode(data)
  var last: Opt[Digest]
  if r.last_provisioned.isSome:
    var d: Digest
    for i in 0 ..< 32:
      d[i] = r.last_provisioned.get[i]
    last = Opt.some(d)
  decodeStored(r.binding, r.state, digest, last)

const XferSide* = "xfer"
  ## [I96] the side-record kind of a transferred instance's provenance

type XferRecord* = object
  ## [IMPL-DECISION I96; G306] One `lcn.xfer_record`: where a transferred
  ## instance's state came from, as the deployment's entry was applied.
  source*: string ## the transfer's source instance
  sourceAssignment*: string ## its state assignment
  mode*: TransferMode
  bytes*: uint64 ## copied; 0 for a move, which reads nothing
  files*: uint64
  epoch*: uint64 ## the revision epoch of the start that applied it
  at*: uint64 ## Unix seconds

proc xferBytes*(r: XferRecord): Result[seq[byte], string] =
  encode(
    LcnXferRecord(
      `from`: r.source,
      from_assignment: r.sourceAssignment,
      mode:
        case r.mode
        of tmMove:
          LcnXferRecordModeChoice(kind: LcnXferRecordModeChoiceKind.Move)
        of tmCopy:
          LcnXferRecordModeChoice(kind: LcnXferRecordModeChoiceKind.Copy),
      bytes: r.bytes,
      files: r.files,
      epoch: r.epoch,
      at: r.at,
    )
  )

proc xferOf*(data: openArray[byte]): Result[XferRecord, string] =
  ## An `xfer` side record read back.
  let r = ?LcnXferRecord.decode(data)
  ok(
    XferRecord(
      source: r.`from`,
      sourceAssignment: r.from_assignment,
      mode:
        case r.mode.kind
        of LcnXferRecordModeChoiceKind.Move: tmMove
        of LcnXferRecordModeChoiceKind.Copy: tmCopy
      ,
      bytes: r.bytes,
      files: r.files,
      epoch: r.epoch,
      at: r.at,
    )
  )

func classificationOf*(text: string): Result[Failure, string] =
  ## The failure a stored classification names (RUNTIME l.3605, l.3607).
  if text.startsWith("loader-"):
    let code = text[7 ..^ 1]
    for c in LoaderErrorCode:
      if $c == code:
        return ok(Failure(kind: fkLoader, loader: c))
    return err("unknown failure classification " & text)
  for k in FailureKind:
    if k != fkLoader and $k == text:
      return ok(Failure(kind: k))
  err("unknown failure classification " & text)

func rsFailure(f: Failure): LcnRsFailure =
  # [IMPL] A realizer's text may name host paths: it is not stored.
  var reason = (if f.internal: "" else: f.reason)
  if reason.len > 512:
    # `lcn.rs_failure.reason`: cut at a character boundary.
    var n = 512
    while n > 0 and (uint8(reason[n]) and 0xC0'u8) == 0x80'u8:
      dec n
    reason = reason[0 ..< n]
  LcnRsFailure(
    classification: f.classification,
    reason: (if reason.len > 0: Opt.some(reason) else: Opt.none(string)),
  )

func failureOf(f: LcnRsFailure): Result[Failure, string] =
  var r = ?classificationOf(f.classification)
  r.reason = f.reason.get("")
  ok(r)

func originArm(o: Origin): LcnRsOriginARInstanceMap =
  ## [G413] A forwarded consumer's origin keeps its Runtime.
  if o.instance.isForwarded:
    let p = o.instance.forwardedParts
    LcnRsOriginARInstanceMap(instance: p.instance, runtime: Opt.some(p.runtime))
  else:
    LcnRsOriginARInstanceMap(instance: o.instance)

func toRs(x: StoredInstance): LcnRsInstance =
  result = LcnRsInstance(
    instance: x.instance,
    record: toRs(x.record),
    revision: x.revision,
    source: LcnRsInstanceSourceChoice(
      kind: (
        if x.created: LcnRsInstanceSourceChoiceKind.Create_module
        else: LcnRsInstanceSourceChoiceKind.Host
      )
    ),
    state: LcnRsInstanceStateChoice(
      kind:
        case x.state
        of msUnloaded: LcnRsInstanceStateChoiceKind.Unloaded
        of msLoaded: LcnRsInstanceStateChoiceKind.Loaded
        of msReady: LcnRsInstanceStateChoiceKind.Ready
        of msStopping: LcnRsInstanceStateChoiceKind.Stopping
        of msError: LcnRsInstanceStateChoiceKind.Error
    ),
    intent: LcnRsInstanceIntentChoice(
      kind:
        case x.intent
        of inUninitialized: LcnRsInstanceIntentChoiceKind.Uninitialized
        of inRequested: LcnRsInstanceIntentChoiceKind.Requested
        of inStopped: LcnRsInstanceIntentChoiceKind.Stopped
    ),
  )
  if x.providerId.len > 0:
    result.provider = Opt.some(x.providerId)
  if x.failure.isSome:
    result.failure = Opt.some(rsFailure(x.failure.get))
  if x.enforced.isSome:
    result.enforced = Opt.some(rsFailure(x.enforced.get))
  if x.intent == inRequested:
    result.intent_revision = Opt.some(x.intentRevision)
    result.origin = Opt.some(
      if x.origin.host:
        LcnRsOrigin(kind: LcnRsOriginKind.Host, arm_Host: LcnRsOriginARHostMap())
      else:
        LcnRsOrigin(kind: LcnRsOriginKind.Instance, arm_Instance: originArm(x.origin))
    )

func consumerOf(instance: string, runtime: Opt[string]): Result[string, string] =
  ## [G413] The engine's id of a stored consumer: a forwarded one's from its
  ## Runtime and instance id.
  if runtime.isNone:
    return ok(instance)
  let id = forwardedId(runtime.get, instance)
  if id.len == 0:
    return err("a forwarded consumer's Runtime id is not valid")
  ok(id)

func fromRs(x: LcnRsInstance): Result[StoredInstance, string] =
  let record = ?fromRs(x.record)
  var s = StoredInstance(
    instance: x.instance,
    providerId: x.provider.get(""),
    created: x.source.kind == LcnRsInstanceSourceChoiceKind.Create_module,
    record: record,
    revision: x.revision,
  )
  s.state =
    case x.state.kind
    of LcnRsInstanceStateChoiceKind.Unloaded: msUnloaded
    of LcnRsInstanceStateChoiceKind.Loaded: msLoaded
    of LcnRsInstanceStateChoiceKind.Ready: msReady
    of LcnRsInstanceStateChoiceKind.Stopping: msStopping
    of LcnRsInstanceStateChoiceKind.Error: msError
  s.intent =
    case x.intent.kind
    of LcnRsInstanceIntentChoiceKind.Uninitialized: inUninitialized
    of LcnRsInstanceIntentChoiceKind.Requested: inRequested
    of LcnRsInstanceIntentChoiceKind.Stopped: inStopped
  if x.failure.isSome:
    s.failure = Opt.some(?failureOf(x.failure.get))
  if x.enforced.isSome:
    if s.state != msStopping:
      return
        err("instance " & x.instance & ": an enforced classification out of stopping")
    s.enforced = Opt.some(?failureOf(x.enforced.get))
  if s.intent == inRequested:
    if x.intent_revision.isNone or x.origin.isNone:
      return err(
        "instance " & x.instance & ": requested intent without its revision or origin"
      )
    s.intentRevision = x.intent_revision.get
    let o = x.origin.get
    if o.kind == LcnRsOriginKind.Host:
      s.origin = hostOrigin()
    else:
      let c = consumerOf(o.arm_Instance.instance, o.arm_Instance.runtime)
      if c.isErr:
        return err("instance " & x.instance & ": " & c.error)
      s.origin = moduleOrigin(c.get)
    if s.intentRevision > s.revision:
      return err("instance " & x.instance & ": an intent revision past the revision")
  elif x.intent_revision.isSome or x.origin.isSome:
    return err("instance " & x.instance & ": intent fields without requested intent")
  if s.state == msError and s.failure.isNone:
    return err("instance " & x.instance & ": error without a failure") # l.3758
  let expects = s.record.primaryContract.isSome or s.record.implements.len > 0
  if expects != (s.providerId.len > 0):
    return
      err("instance " & x.instance & ": its provider record does not match its record")
  ok(s)

proc encodeSnapshot*(snap: Snapshot): Result[seq[byte], string] =
  var x = LcnRsState(
    format: LcnRsStateFormatChoice(kind: LcnRsStateFormatChoiceKind.Case1),
    runtime_instance_id: snap.runtimeInstanceId,
    epoch: snap.epoch,
  )
  if snap.completedShutdown:
    x.completed_shutdown = Opt.some(true)
  for i in snap.instances:
    x.instances.add(toRs(i))
  for r in snap.retired:
    x.retired.add(
      LcnRsRetired(instance: r.instance, state_assignment: r.stateAssignment)
    )
  for k in snap.createKeys:
    x.create_keys.add(
      LcnRsCreateKey(
        consumer: (
          if k.consumer.isForwarded: k.consumer.forwardedParts.instance else: k.consumer
        ),
        consumer_runtime:
          if k.consumer.isForwarded:
            Opt.some(k.consumer.forwardedParts.runtime)
          else:
            Opt.none(string),
        key: k.key,
        module: k.module,
        instance: k.instance,
      )
    )
  encode(x)

proc checkInvariants(s: Snapshot): Result[void, string] =
  ## What the schema cannot say.
  var
    ids = initHashSet[string]()
    providers = initHashSet[string]()
    assignments = initHashSet[string]()
  for x in s.instances:
    if x.instance in ids:
      return err("instance " & x.instance & " is listed twice")
    ids.incl(x.instance)
    if x.providerId.len > 0:
      if x.providerId in providers:
        return err("provider " & x.providerId & " is listed twice")
      providers.incl(x.providerId)
    if x.record.stateAssignment.isSome:
      let a = x.record.stateAssignment.get
      if a in assignments:
        return err("two instances share the state assignment " & a)
      assignments.incl(a)
    if (x.revision shr 32) > s.epoch:
      return err("instance " & x.instance & ": a revision past the stored epoch")
  var retired = initHashSet[string]()
  for r in s.retired:
    if r.instance in ids or r.instance in retired:
      return err("retired instance " & r.instance & " is listed twice")
    retired.incl(r.instance)
    if r.stateAssignment.isSome:
      if r.stateAssignment.get in assignments:
        return err("a retired state assignment is in use: " & r.stateAssignment.get)
      assignments.incl(r.stateAssignment.get)
  var keys = initHashSet[(string, string)]()
  for k in s.createKeys:
    if (k.consumer, k.key) in keys:
      return err("a create_module key is listed twice")
    keys.incl((k.consumer, k.key))
    if k.instance notin ids:
      return err("a create_module key names an unknown instance")
  if not isValidUtf8(s.runtimeInstanceId):
    return err("the Runtime identity is not UTF-8")
  ok()

proc decodeSnapshot*(data: openArray[byte]): Result[Snapshot, string] =
  ## One snapshot: deterministic CBOR, `lcn.rs_state`, and its invariants.
  let x = LcnRsState.decode(data).valueOr:
    return err("the state store does not decode: " & error)
  var s = Snapshot(
    runtimeInstanceId: x.runtime_instance_id,
    epoch: x.epoch,
    completedShutdown: x.completed_shutdown.isSome,
  )
  for i in x.instances:
    s.instances.add(?fromRs(i))
  if x.format.kind == LcnRsStateFormatChoiceKind.Case0:
    # [G357] v1 has neither field.
    if s.completedShutdown:
      return err("a v1 state store carries completed_shutdown")
    for i in s.instances:
      if i.enforced.isSome:
        return err("a v1 state store carries an enforced classification")
  for r in x.retired:
    s.retired.add(RetiredId(instance: r.instance, stateAssignment: r.state_assignment))
  for k in x.create_keys:
    let consumer = ?consumerOf(k.consumer, k.consumer_runtime)
    s.createKeys.add(
      CreateKey(consumer: consumer, key: k.key, module: k.module, instance: k.instance)
    )
  ?checkInvariants(s)
  ok(s)

# The store --------------------------------------------------------------------------

proc openStore*(dir: string): Result[(Store, Opt[Snapshot]), string] =
  ## Takes the lock on `dir` (created 0700 when missing), removes leftover
  ## temporary files (torn writes; the files they were replacing are whole)
  ## and reads the snapshot, if there is one. An empty `dir` is an in-memory
  ## store. On an error nothing is modified and the lock is not held.
  if dir.len == 0:
    return ok((Store(), Opt.none(Snapshot)))
  ?ensurePrivateDir(dir)
  var lock = ?acquire(dir)
  var snap = Opt.none(Snapshot)
  block reading:
    let data = readBounded(dir / SnapshotName, MaxStoreBytes).valueOr:
      lock.release()
      return err(error)
    if data.isSome:
      let s = decodeSnapshot(data.get).valueOr:
        lock.release()
        return err(error)
      snap = Opt.some(s)
  for name in fileNames(dir):
    if name.isTmp:
      removeIfPresent(dir / name).isOkOr:
        lock.release()
        return err(error)
  ok((Store(dir: dir, lock: lock), snap))

proc write*(s: var Store, snap: Snapshot): Result[void, string] =
  ## Replaces the snapshot durably; an in-memory store writes nothing.
  let bytes = ?encodeSnapshot(snap)
  if bytes.len > MaxStoreBytes:
    return err("the state store would exceed " & $MaxStoreBytes & " bytes")
  if not s.isPersistent:
    return ok()
  writeAtomic(s.dir, SnapshotName, bytes)

proc close*(s: var Store) =
  ## Releases the lock.
  s.lock.release()

# Side records -----------------------------------------------------------------------

func hexOf(d: openArray[byte]): string =
  const digits = "0123456789abcdef"
  for b in d:
    result.add(digits[int(b shr 4)])
    result.add(digits[int(b and 0x0F)])

func sideName(kind, instance: string): string =
  ## [IMPL] An instance id may hold any UTF-8 text, so the file is named by its
  ## hash and holds the id itself.
  kind & "-" & hexOf(blake3(instance.toOpenArrayByte(0, instance.high))) & SideSuffix

func validKind(kind: string): bool =
  kind.len in 1 .. 16 and kind.allCharsInSet({'a' .. 'z'})

proc putSide*(
    s: var Store, kind, instance: string, value: openArray[byte]
): Result[void, string] =
  ## Replaces the side record `kind` of `instance`, durably.
  doAssert kind.validKind, "a side-record kind is 1 to 16 lowercase letters"
  let bytes = ?encode(LcnRsSide(instance: instance, value: @value))
  if bytes.len > MaxStoreBytes:
    return err("a side record would exceed " & $MaxStoreBytes & " bytes")
  let name = sideName(kind, instance)
  if not s.isPersistent:
    s.memory[name] = bytes
    return ok()
  writeAtomic(s.dir, name, bytes)

proc readSide(s: Store, name: string): Result[Opt[LcnRsSide], string] =
  let data =
    if s.isPersistent:
      ?readBounded(s.dir / name, MaxStoreBytes)
    elif name in s.memory:
      Opt.some(s.memory.getOrDefault(name))
    else:
      Opt.none(seq[byte])
  if data.isNone:
    return ok(Opt.none(LcnRsSide))
  let side = LcnRsSide.decode(data.get).valueOr:
    return err("side record " & name & " does not decode: " & error)
  let kind = name.split('-')[0]
  if sideName(kind, side.instance) != name:
    return err("side record " & name & " names another instance")
  ok(Opt.some(side))

proc getSide*(s: Store, kind, instance: string): Result[Opt[seq[byte]], string] =
  ## The side record `kind` of `instance`, if there is one.
  doAssert kind.validKind, "a side-record kind is 1 to 16 lowercase letters"
  let side = ?s.readSide(sideName(kind, instance))
  if side.isNone:
    return ok(Opt.none(seq[byte]))
  ok(Opt.some(side.get.value))

proc deleteSide*(s: var Store, kind, instance: string): Result[void, string] =
  doAssert kind.validKind, "a side-record kind is 1 to 16 lowercase letters"
  let name = sideName(kind, instance)
  if not s.isPersistent:
    s.memory.del(name)
    return ok()
  removeDurably(s.dir, name)

func isSideName(name: string): bool =
  ## [IMPL] Exactly the names `sideName` writes: `<kind>-<64 hex>.cbor`.
  ## Anything else in the directory (an AppleDouble `._*` file an exFAT or
  ## network volume adds, an editor's backup) is not ours and is left alone.
  if not name.endsWith(SideSuffix):
    return false
  let dash = name.find('-')
  if dash < 0:
    return false
  let hex = name[dash + 1 ..< name.len - SideSuffix.len]
  name[0 ..< dash].validKind and hex.len == 64 and
    hex.allCharsInSet({'0' .. '9', 'a' .. 'f'})

proc sideNames(s: Store): seq[string] =
  if s.isPersistent:
    for name in fileNames(s.dir):
      if name != SnapshotName and name.isSideName:
        result.add(name)
  else:
    for name in s.memory.keys:
      result.add(name)

proc listSide*(s: Store, kind: string): Result[seq[(string, seq[byte])], string] =
  ## Every side record of `kind`, as (instance, value).
  doAssert kind.validKind, "a side-record kind is 1 to 16 lowercase letters"
  var found: seq[(string, seq[byte])]
  for name in s.sideNames:
    if name.startsWith(kind & "-"):
      let side = ?s.readSide(name)
      if side.isSome:
        found.add((side.get.instance, side.get.value))
  ok(found)

proc reapSides*(
    s: var Store, known: HashSet[string], retired = initHashSet[string]()
): Result[seq[string], string] =
  ## [IMPL] Removes the side records of instances that are not known (retired,
  ## or a crash between a side write and the snapshot commit); returns their
  ## instances. A side record that does not decode fails the open.
  ## [I96; RUNTIME l.3588] An `xfer` record of a `retired` instance is kept
  ## with its tombstone: retirement erases no audit history.
  var reaped: seq[string]
  for name in s.sideNames:
    let side = ?s.readSide(name)
    if side.isSome and side.get.instance notin known and
        not (name.startsWith(XferSide & "-") and side.get.instance in retired):
      if s.isPersistent:
        ?removeDurably(s.dir, name)
      else:
        s.memory.del(name)
      reaped.add(side.get.instance)
  ok(reaped)
