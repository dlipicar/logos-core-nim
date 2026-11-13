## CONFIG §3-§8: one module instance's configuration state, as the Runtime
## thread owns it (DECISIONS I87).
##
## Pure: nothing here runs a thread, takes a lock or reaches the store. The
## engine owns one `ConfigState` per instance whose declaration has a
## configuration-schema binding, and changes it only through the transitions
## below, each computed as a new value (`staged`, `discarded`, `withAttempt`,
## `promoted`, `withoutAttempt`) and taken with `adopt` once it is persisted.
##
## Bytes. The schema document and every value live in `Blob`s: immutable,
## shared-heap, with an atomic reference count. A `ConfigState` held by an
## instance, or retained for a reply (`retained`), owns one reference per
## blob it names; a value the transition functions return borrows them until
## `adopt` takes it. No 8 MiB copy goes through a channel, and no thread frees
## another thread's memory under refc (I75).
##
## Frame admission (CONFIG l.108-115) [IMPL-DECISION G233]: a state is
## admissible when a maximal `get_configuration` response for it fits a
## 16 MiB Transport frame body: 128-byte instance and Runtime ids, the 9-byte
## call id, and every revision at its 9-byte encoding, so a promotion is never
## refused for growing a revision (at most 24 bytes over-rejected).
##
## Revision headroom (CONFIG l.99-101, l.234, l.241) [IMPL-DECISION G234]:
## while an attempt whose promotion would change the state is in flight, one
## revision step stays reserved for that promotion.

{.push raises: [], gcsafe.}

import std/atomics
import results
import ../cbor
import ../crypto/blake3
import ../hash/hashinput
import ../transport/envelope
import ../transport/framing
import ./rc_types

export results, hashinput.Digest

type
  ConfigBlob = object
    refs: Atomic[int]
    len: int
    data: ptr UncheckedArray[byte]

  Blob* = ptr ConfigBlob ## immutable shared bytes; nil is empty

  Provenance* = enum
    ## [SPEC CONFIG §4] `logos.module_configuration.provenance`
    pvPackageDefault = "package-default"
    pvProtectedProvisioning = "protected-provisioning"
    pvRuntimeControlUpdate = "runtime-control-update"

  SchemaRoots* = object
    ## The two digests of a `logos.module_configuration.schema_commitment`;
    ## its other three fields are fixed by the schema.
    schemaRoot*, subtreeRoot*: Digest

  Binding* = object
    ## [SPEC CONFIG §2, §7] An instance's accepted configuration-schema
    ## binding: fixed for the instance's life.
    document*: Blob ## the CDDL text
    root*: string
    commitment*: SchemaRoots
    live*: bool
    digest*: Digest
      ## [IMPL] blake3 of the binding's deterministic CBOR: its identity, the
      ## record's `configuration_commitment`

  ValueRecord* = object ## [SPEC CONFIG §3 l.117-119]
    value*: Blob
    valueRoot*: Digest
    commitment*: SchemaRoots
      ## its value commitment's subtree root is `commitment.subtreeRoot`
      ## (CFG-0150)
    valueRevision*: uint64
    provenance*: Provenance

  ConfigState* = object
    binding*: Binding
    revision*: uint64 ## [SPEC CONFIG §3 l.89-101]
    current*, staged*: Opt[ValueRecord]
    attempted*: Opt[ValueRecord]
      ## the immutable record of the startup or live-reconfiguration attempt
      ## in flight (l.233, l.301)
    lastProvisioned*: Opt[Digest]
      ## [IMPL-DECISION G141] the value root of the last provisioned value
      ## accepted, so an unchanged one is not staged again

  Selection* = enum
    ## [SPEC CONFIG §4 l.142-146] what a startup would use
    selNone ## no record
    selIneligible ## the selected record is under another commitment (l.145)
    selStaged
    selCurrent

const
  MaxValueBytes* = 8_388_608 ## [SPEC CONFIG §2] one complete value
  MaxDocumentChars* = 1_048_576 ## [SPEC CONFIG §9] `schema_binding.document`
  MaxRootChars* = 255 ## [SPEC CONFIG §9] `schema_binding.root`

# Blobs ------------------------------------------------------------------------------

var liveBlobs: Atomic[int]

proc newBlob*(data: openArray[byte]): Blob =
  ## A blob holding a copy of `data`, with one reference.
  result = createShared(ConfigBlob)
  result.len = data.len
  result.data = cast[ptr UncheckedArray[byte]](allocShared(max(data.len, 1)))
  if data.len > 0:
    copyMem(result.data, unsafeAddr data[0], data.len)
  result.refs.store(1)
  discard liveBlobs.fetchAdd(1)

proc newBlob*(s: string): Blob =
  newBlob(s.toOpenArrayByte(0, s.high))

proc retain*(b: Blob): Blob =
  if b != nil:
    discard b.refs.fetchAdd(1)
  b

proc drop*(b: Blob) =
  if b != nil and b.refs.fetchSub(1) == 1:
    deallocShared(b.data)
    freeShared(b)
    discard liveBlobs.fetchSub(1)

func len*(b: Blob): int =
  if b.isNil: 0 else: b.len

func address*(b: Blob): ptr UncheckedArray[byte] =
  ## Where the bytes are, for a C call that borrows them; nil for no blob.
  if b.isNil: nil else: b.data

template bytesOf*(b: Blob): openArray[byte] =
  b.data.toOpenArray(0, b.len - 1)

proc toBytes*(b: Blob): seq[byte] =
  result = newSeq[byte](b.len)
  if b.len > 0:
    copyMem(addr result[0], b.data, b.len)

proc toText*(b: Blob): string =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], b.data, b.len)

proc liveConfigBlobs*(): int =
  ## Blobs not yet freed, in this process: tests check none leak.
  liveBlobs.load

# Ownership --------------------------------------------------------------------------

proc retainAll(s: ConfigState) =
  discard retain(s.binding.document)
  for r in [s.current, s.staged, s.attempted]:
    if r.isSome:
      discard retain(r.get.value)

proc release*(s: var ConfigState) =
  ## Drops every reference `s` owns; `s` is empty afterwards.
  drop(s.binding.document)
  for r in [s.current, s.staged, s.attempted]:
    if r.isSome:
      drop(r.get.value)
  s = ConfigState()

proc retained*(s: ConfigState): ConfigState =
  ## A copy of `s` that owns its own references: for a reply.
  retainAll(s)
  s

proc adopt*(s: var ConfigState, next: ConfigState) =
  ## `s` becomes `next`, a transition of it: `next`'s blobs are retained and
  ## the ones `s` held dropped.
  retainAll(next)
  var old = s
  s = next
  release(old)

# Transitions ------------------------------------------------------------------------

func newState*(binding: Binding): ConfigState =
  ## [SPEC CONFIG §3 l.90] Revision zero, no record (CFG-0026). Borrows the
  ## binding's document.
  ConfigState(binding: binding)

func eligible*(s: ConfigState, r: ValueRecord): bool =
  ## [SPEC CONFIG §4 l.145; TF-06] Only a record under the accepted
  ## commitment may start the instance.
  r.commitment == s.binding.commitment

func select*(s: ConfigState): Selection =
  ## [SPEC CONFIG §4 l.142] The staged record when one exists, else the
  ## current one. An ineligible record is not absence (CFG-0047).
  if s.staged.isSome:
    if s.eligible(s.staged.get): selStaged else: selIneligible
  elif s.current.isSome:
    if s.eligible(s.current.get): selCurrent else: selIneligible
  else:
    selNone

func promotes*(s: ConfigState, r: ValueRecord): bool =
  ## Making `r` current changes the state: it is not the current record.
  s.current.isNone or s.current.get.valueRevision != r.valueRevision

func commitmentsAgree*(binding, staged, initialized: SchemaRoots): bool =
  ## [SPEC CONFIG §8 l.296] A live application needs the accepted binding's
  ## commitment, the staged record's and the one the realization was
  ## initialized under to be one commitment; otherwise VERSION_MISMATCH.
  binding == staged and staged == initialized

func canAdvance*(s: ConfigState): bool =
  ## [SPEC CONFIG §3 l.99-100] The revision never wraps (CFG-0031, CFG-0032).
  s.revision < high(uint64)

func headroom*(s: ConfigState): uint64 =
  ## [IMPL-DECISION G234] The revision steps a concurrent mutation must leave
  ## free: one while an attempt whose promotion changes the state is in
  ## flight (CONFIG l.101, l.234, l.241).
  if s.attempted.isSome and s.promotes(s.attempted.get): 1 else: 0

func canMutate*(s: ConfigState): bool =
  ## A mutation can advance the revision and still leave the headroom.
  s.revision < high(uint64) - s.headroom

func withStaged*(
    s: ConfigState, value: Blob, valueRoot: Digest, provenance: Provenance
): ConfigState =
  ## [SPEC CONFIG §5 l.205] Staging always advances the revision, even for an
  ## equal value. The caller checked `canMutate`. Borrows `value`.
  result = s
  inc result.revision
  result.staged = Opt.some(
    ValueRecord(
      value: value,
      valueRoot: valueRoot,
      commitment: s.binding.commitment,
      valueRevision: result.revision,
      provenance: provenance,
    )
  )

func discarded*(s: ConfigState): ConfigState =
  ## [SPEC CONFIG §5 l.206-207] Discarding a staged record advances the
  ## revision; with none it changes nothing.
  result = s
  if s.staged.isSome:
    inc result.revision
    result.staged = Opt.none(ValueRecord)

func withAttempt*(s: ConfigState, r: ValueRecord): ConfigState =
  ## [SPEC CONFIG §6 l.220; §8 l.301] The attempt's immutable snapshot.
  result = s
  result.attempted = Opt.some(r)

func withoutAttempt*(s: ConfigState): ConfigState =
  ## [SPEC CONFIG §6 l.238-240; §8 l.311-316] A failed, rejected or
  ## indeterminate attempt changes nothing else.
  result = s
  result.attempted = Opt.none(ValueRecord)

func promoted*(s: ConfigState): ConfigState =
  ## [SPEC CONFIG §6 l.233-236, §8 l.306-309] The attempted record becomes
  ## current; the staged record is cleared only when it still has the
  ## attempted value revision. One revision step when anything changed
  ## (CFG-0072, CFG-0073); none when the attempted record was current.
  result = s
  result.attempted = Opt.none(ValueRecord)
  if s.attempted.isNone:
    return
  let a = s.attempted.get
  if not s.promotes(a):
    return
  inc result.revision
  result.current = Opt.some(a)
  if s.staged.isSome and s.staged.get.valueRevision == a.valueRevision:
    result.staged = Opt.none(ValueRecord)

# Response shapes --------------------------------------------------------------------

func toRc*(c: SchemaRoots): LogosNSModuleConfigurationSchemaCommitment =
  LogosNSModuleConfigurationSchemaCommitment(
    schema_root: @(c.schemaRoot), schema_subtree_root: @(c.subtreeRoot)
  )

func digestOf(b: openArray[byte]): Result[Digest, string] =
  if b.len != DigestLen:
    return err("a digest is not 32 bytes")
  var d: Digest
  for i in 0 ..< DigestLen:
    d[i] = b[i]
  ok(d)

func fromRc*(
    c: LogosNSModuleConfigurationSchemaCommitment
): Result[SchemaRoots, string] =
  ## A checked commitment: its fixed fields are the schema's.
  let
    schemaRoot = ?digestOf(c.schema_root)
    subtreeRoot = ?digestOf(c.schema_subtree_root)
  ok(SchemaRoots(schemaRoot: schemaRoot, subtreeRoot: subtreeRoot))

func toRc*(p: Provenance): LogosNSModuleConfigurationProvenance =
  LogosNSModuleConfigurationProvenance(
    kind:
      case p
      of pvPackageDefault:
        LogosNSModuleConfigurationProvenanceKind.Package_default
      of pvProtectedProvisioning:
        LogosNSModuleConfigurationProvenanceKind.Protected_provisioning
      of pvRuntimeControlUpdate:
        LogosNSModuleConfigurationProvenanceKind.Runtime_control_update
  )

func fromRc(p: LogosNSModuleConfigurationProvenance): Provenance =
  case p.kind
  of LogosNSModuleConfigurationProvenanceKind.Package_default:
    pvPackageDefault
  of LogosNSModuleConfigurationProvenanceKind.Protected_provisioning:
    pvProtectedProvisioning
  of LogosNSModuleConfigurationProvenanceKind.Runtime_control_update:
    pvRuntimeControlUpdate

func valueCommitment(r: ValueRecord): LogosNSModuleConfigurationValueCommitment =
  LogosNSModuleConfigurationValueCommitment(
    schema_subtree_root: @(r.commitment.subtreeRoot), value_root: @(r.valueRoot)
  )

func metadata*(r: ValueRecord): LogosNSModuleConfigurationValueRecordMetadata =
  ## [SPEC CONFIG §9] A record without its value (CFG-0058, CFG-0108).
  LogosNSModuleConfigurationValueRecordMetadata(
    schema_commitment: toRc(r.commitment),
    value_commitment: r.valueCommitment,
    value_revision: r.valueRevision,
    provenance: toRc(r.provenance),
  )

proc toRc*(r: ValueRecord): LogosNSModuleConfigurationValueRecord =
  ## The complete record, its value copied.
  LogosNSModuleConfigurationValueRecord(
    value: r.value.toBytes,
    schema_commitment: toRc(r.commitment),
    value_commitment: r.valueCommitment,
    value_revision: r.valueRevision,
    provenance: toRc(r.provenance),
  )

func summary*(s: ConfigState): LogosNSModuleConfigurationConfigurationStateSummary =
  ## [SPEC CONFIG §9 l.420-425] Metadata only: no value, no document.
  result = LogosNSModuleConfigurationConfigurationStateSummary(
    state_revision: s.revision, schema_commitment: Opt.some(toRc(s.binding.commitment))
  )
  if s.current.isSome:
    result.current = Opt.some(s.current.get.metadata)
  if s.staged.isSome:
    result.staged = Opt.some(s.staged.get.metadata)

func summaryWithout*(): LogosNSModuleConfigurationConfigurationStateSummary =
  ## [IMPL-DECISION G235 (TL-09)] An instance without a binding: revision
  ## zero, nothing else (CONFIG l.50, l.329).
  LogosNSModuleConfigurationConfigurationStateSummary(state_revision: 0)

proc stateOf*(s: ConfigState): LogosNSModuleConfigurationConfigurationState =
  ## [SPEC CONFIG §9] The complete state, values copied.
  result = LogosNSModuleConfigurationConfigurationState(
    state_revision: s.revision, schema_commitment: toRc(s.binding.commitment)
  )
  if s.current.isSome:
    result.current = Opt.some(toRc(s.current.get))
  if s.staged.isSome:
    result.staged = Opt.some(toRc(s.staged.get))

proc bindingOf*(b: Binding): LogosNSModuleConfigurationSchemaBinding =
  ## [SPEC CONFIG §9] The binding as `get_configuration_schema` returns it.
  LogosNSModuleConfigurationSchemaBinding(
    document: b.document.toText,
    root: b.root,
    schema_commitment: toRc(b.commitment),
    live_reconfiguration: (if b.live: Opt.some(true) else: Opt.none(bool)),
  )

proc bindingDigest*(b: LogosNSModuleConfigurationSchemaBinding): Digest =
  ## [IMPL] The binding's identity: blake3 of its deterministic CBOR, so a
  ## change of document, root, commitment or live flag changes it (C4).
  let bytes = encodeCbor(toCbor(b))
  blake3(bytes)

proc encodeInput*(r: ValueRecord): seq[byte] =
  ## [SPEC CONFIG §6 l.224] Exactly one deterministic
  ## `logos.module_configuration.configuration_input`.
  encodeCbor(
    toCbor(
      LogosNSModuleConfigurationConfigurationInput(
        value: r.value.toBytes,
        schema_commitment: toRc(r.commitment),
        value_revision: r.valueRevision,
      )
    )
  )

# Frame admission (CONFIG l.108-115) --------------------------------------------------

const MaxIdChars = 128 ## RUNTIME l.1860-1861: the longest legal ids

func headerLen(n: int): int =
  ## The CBOR head of a byte string of `n` bytes.
  if n < 24:
    1
  elif n < 256:
    2
  elif n < 65536:
    3
  elif n.uint64 < 0x1_0000_0000'u64:
    5
  else:
    9

proc placeholder(r: ValueRecord): LogosNSModuleConfigurationValueRecord =
  LogosNSModuleConfigurationValueRecord(
    value: @[0'u8],
    schema_commitment: toRc(r.commitment),
    value_commitment: r.valueCommitment,
    value_revision: high(uint64),
    provenance: toRc(r.provenance),
  )

proc frameBytes*(s: ConfigState, current, staged: Opt[ValueRecord]): int =
  ## [SPEC CONFIG l.108-111; TRANSPORT §2.1] The Transport `response-ok`
  ## frame body of a `get_configuration` holding `current` and `staged`, with
  ## maximal ids, call id and revisions [G233]. The template holds one-byte
  ## values; each real value adds its length and its header's growth.
  var state = LogosNSModuleConfigurationConfigurationState(
    state_revision: high(uint64), schema_commitment: toRc(s.binding.commitment)
  )
  var extra = 0
  if current.isSome:
    state.current = Opt.some(placeholder(current.get))
    let n = current.get.value.len
    extra += headerLen(n) + n - 2
  if staged.isSome:
    state.staged = Opt.some(placeholder(staged.get))
    let n = staged.get.value.len
    extra += headerLen(n) + n - 2
  var id = newString(MaxIdChars)
  for c in id.mitems:
    c = 'a'
  let response = LogosNSRuntimeControlGetConfigurationResponse(
    target: LogosNSRuntimeModuleInstanceAddress(
      runtime_instance_id: id, module_instance_id: id
    ),
    state: state,
  )
  let message = Message(
    kind: mkResponse,
    response: envelope.Response(id: high(uint64), ok: true, resultMap: toCbor(response)),
  )
  encodeCbor(toCbor(message)).len + extra

proc admissible*(s: ConfigState): bool =
  ## [SPEC CONFIG l.108-115] `s` fits the frame, and while an attempt is in
  ## flight it also fits with the attempted record current (CFG-0039,
  ## CFG-0040).
  if s.frameBytes(s.current, s.staged) > MinFrameLimit:
    return false
  if s.attempted.isSome and s.frameBytes(s.attempted, s.staged) > MinFrameLimit:
    return false
  true

# Persistence ------------------------------------------------------------------------

proc toRcState(s: ConfigState): LogosNSModuleConfigurationConfigurationState =
  stateOf(s)

proc encodeStored*(s: ConfigState): (seq[byte], seq[byte]) =
  ## The two deterministic-CBOR parts of the persisted record: the binding
  ## and the state (current and staged; never the in-flight attempt).
  (encodeCbor(toCbor(bindingOf(s.binding))), encodeCbor(toCbor(toRcState(s))))

proc fromRc(r: LogosNSModuleConfigurationValueRecord): Result[ValueRecord, string] =
  let commitment = ?fromRc(r.schema_commitment)
  if r.value_commitment.schema_subtree_root != @(commitment.subtreeRoot):
    return err("a value record's two subtree roots differ")
  let valueRoot = ?digestOf(r.value_commitment.value_root)
  # The blob last: nothing fails after it.
  ok(
    ValueRecord(
      value: newBlob(r.value),
      valueRoot: valueRoot,
      commitment: commitment,
      valueRevision: r.value_revision,
      provenance: fromRc(r.provenance),
    )
  )

proc decodeStored*(
    binding, state: openArray[byte], digest: Digest, lastProvisioned: Opt[Digest]
): Result[ConfigState, string] =
  ## A persisted record read back: its binding must have the identity
  ## `digest` the instance's record names. The result owns new blobs.
  if blake3(binding) != digest:
    return err("its binding is not the one the instance record names")
  let b = ?LogosNSModuleConfigurationSchemaBinding.decode(binding)
  let st = ?LogosNSModuleConfigurationConfigurationState.decode(state)
  let commitment = ?fromRc(b.schema_commitment)
  if ?fromRc(st.schema_commitment) != commitment:
    return err("its state is under another commitment than its binding")
  var current, staged: Opt[ValueRecord]
  if st.current.isSome:
    current = Opt.some(?fromRc(st.current.get))
  if st.staged.isSome:
    let r = fromRc(st.staged.get)
    if r.isErr:
      if current.isSome:
        drop(current.get.value)
      return err(r.error)
    staged = Opt.some(r.get)
  ok(
    ConfigState(
      binding: Binding(
        document: newBlob(b.document),
        root: b.root,
        commitment: commitment,
        live: b.live_reconfiguration.get(false),
        digest: digest,
      ),
      revision: st.state_revision,
      current: current,
      staged: staged,
      lastProvisioned: lastProvisioned,
    )
  )
