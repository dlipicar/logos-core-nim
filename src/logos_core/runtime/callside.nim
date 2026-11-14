## INTERFACE §2.5, §2.9.3, §5.1, §5.2: what the native bindings share
## (`bindings.nim`, `events.nim`, `invoke.nim`, `asynccall.nim`).
##
## Everything here lives on the shared heap or in a thread's own storage and
## holds plain values only, so any thread may use it under either memory
## manager: fixed-size text, failure statuses and response buffers, the
## construction input of a route handle (`SchemaBlob`) and this thread's copy of
## the contract it selects (`Selected`), the state behind a Runtime Control
## binding (`AttemptServices`), a route handle (`HandleState`) and an
## invocation context (`InvocationState`), and this thread's stack of active
## provider entries (`Frame`), which `current` reads.

{.push raises: [], gcsafe.}

import std/[atomics, locks, tables]
import results
import ../abi/[checks, types]
import ../base/perthread
import ../cbor/[decode, utf8]
import ../hash/hashinput
import ../iface/[accept, outcome, payload, surface]
import ../transport/boundary
import ./plumbing
import ../abi/cstatus

export cstatus

const
  TextCapacity* = 160 ## instance ids are at most 128 bytes; tokens are shorter
  MaxEventNameBytes* = 128 ## [SPEC INTERFACE §1.5] a complete event identifier

type
  FixedText* = object
    len: int
    data: array[TextCapacity, char]

  SchemaBlob* = object
    ## The construction input `materialize_route` validated, shared by the
    ## handle, its subscriptions and its prepared calls, which may outlive it
    ## (RUNTIME l.880-884).
    refs: Atomic[int]
    root*: Digest
    len*: int
    data*: ptr UncheckedArray[byte]
    depth*: int ## [IF-02, I88] the engine's payload depth setting

  Selected* = object ## One selected contract, as this thread loaded it.
    boundary*: Boundary
    validator*: ContractValidator

  AttemptServices* = object
    ## One execution attempt's Runtime Control binding, publish callback and
    ## invocation-access state. Valid until the attempt's context has been
    ## destroyed.
    engine*: Engine
    instance*: FixedText
    attempt*: FixedText
    binding*: LogosRuntimeControlBinding
    host*: pointer
      ## [plan §2.6] a hosted attempt's `hostsup.Host`, whose requests use
      ## `binding`: the host frees these services with itself, after its last
      ## request

  CallbackState* = enum
    cbNone
    cbScheduled
    cbRunning
    cbDone
    cbSuppressed

  HandleState* = object
    ## One materialized route handle. Freed when its `release` and every
    ## terminal callback scheduled for it are done.
    engine*: Engine
    consumer*, attempt*, route*: FixedText
    root*: Digest
    blob*: ptr SchemaBlob
    generation*: uint64
      ## [G177] its own invocation-path generation (one per materialization)
    conn*: uint64
      ## [I90] a transported handle's link (`transported.nim`); 0: a direct one
    refs*: Atomic[int]
    lock*: Lock
    cond*: Cond
    cb*: CallbackState
    handler*: LogosRouteEndHandler
    userData*: pointer
    code*: CErrorCode

  InvocationState* = object
    ## The state behind one invocation context (INTERFACE §2.9.3): a
    ## synchronous provider entry's, on its caller's stack, or a deferred
    ## invocation's, on the shared heap (`guarded`), whose entries are counted
    ## so the state outlives every admitted one (l.2137-2141, l.2175-2177).
    context*: LogosInvocationContext
    engine*: Engine
    access*: pointer ## the provider's invocation-access state (`current`)
    ticket*: ptr CallTicket
    runtimeId*, consumer*, provider*, route*: FixedText
    generation*: uint64 ## the invocation path's generation (scoped events)
    conn*, requestId*: uint64
      ## [I90] a served invocation's session and Request: its scoped
      ## publications go to that connection (`events.scopedPublish`); 0: none
    blob*: ptr SchemaBlob ## borrowed: the selected contract
    guarded*: bool
    glock*: Lock
    entries*: int ## admitted entries still running (guarded only)
    released*: bool ## `execution_release` came
    finished*: bool ## the Runtime was told the invocation is idle
    owner*: pointer ## the deferred invocation this state belongs to
    system*: bool
      ## [SPEC INTERFACE l.2183; RUNTIME l.1652-1667; G163] the caller is the
      ## Runtime's protected path (an engine `evaluate`): a SYSTEM_SERVICE
      ## caller view with the Runtime id and no module view (I85)

  Frame* = object
    ## One provider entry active on this thread, or a barrier (`context` nil)
    ## that hides every entry below it from `current` while a consumer
    ## callback runs (INTERFACE l.2170).
    context*: ptr LogosInvocationContext
    access*: pointer
    previous*: ptr Frame

func fixed*(s: string): FixedText =
  doAssert s.len <= TextCapacity
  result.len = s.len
  for i, c in s:
    result.data[i] = c

func `$`*(t: FixedText): string =
  result = newString(t.len)
  for i in 0 ..< t.len:
    result[i] = t.data[i]

func utf8View*(t: var FixedText): LogosUtf8View =
  ## A borrowed view of `t`'s bytes, valid while `t` stays where it is.
  LogosUtf8View(
    data: (if t.len == 0: nil
    else: cast[ptr UncheckedArray[uint8]](addr t.data[0])),
    len: csize_t(t.len),
  )

# Results ---------------------------------------------------------------------------

proc status*(e: EngineError): LogosResult =
  status(e.code, e.message)

func failureOf*(e: EngineError): InvocationFailure =
  InvocationFailure(code: e.code, message: Opt.some(e.message))

proc checkEventName*(name: cstring): Result[string, InvocationFailure] =
  ## [SPEC INTERFACE §1.5, §2.5, §2.9.3] A malformed event identifier is
  ## INVALID_PARAMS: null, empty, longer than 128 bytes or not UTF-8.
  if name == nil:
    return err(failure(ecInvalidParams, "a null event name"))
  let s = $name
  if s.len == 0 or s.len > MaxEventNameBytes or not isValidUtf8(s):
    return err(failure(ecInvalidParams, "an event name has 1 to 128 UTF-8 bytes"))
  ok(s)

# Construction input and the selected contract ---------------------------------------

proc newBlob*(
    root: Digest, bytes: ptr UncheckedArray[uint8], len: int, depth = DefaultMaxDepth
): ptr SchemaBlob =
  result = createShared(SchemaBlob)
  result.root = root
  result.len = len
  result.depth = depth
  result.data = cast[ptr UncheckedArray[byte]](allocShared(max(len, 1)))
  for i in 0 ..< len:
    result.data[i] = bytes[i]
  result.refs.store(1)

proc retain*(b: ptr SchemaBlob): ptr SchemaBlob =
  discard b.refs.fetchAdd(1)
  b

proc drop*(b: ptr SchemaBlob) =
  if b != nil and b.refs.fetchSub(1) == 1:
    deallocShared(b.data)
    freeShared(b)

var
  selectedCache {.threadvar.}: Table[(Digest, int), Selected]
    ## by root and payload depth: one thread may serve engines set apart
  selectedHooked {.threadvar.}: bool

proc dropSelected() {.nimcall, gcsafe, raises: [].} =
  selectedCache = default(Table[(Digest, int), Selected])
  selectedHooked = false

proc hookSelected() =
  if not selectedHooked:
    selectedHooked = true
    onThreadRelease(dropSelected)

proc selectedOf*(b: ptr SchemaBlob): Result[Selected, string] =
  ## This thread's copy of the selected contract, rebuilt from the
  ## construction input `materialize_route` validated. Released with the
  ## thread's tables.
  hookSelected()
  let key = (b.root, b.depth)
  if key in selectedCache:
    try:
      return ok(selectedCache[key])
    except KeyError:
      discard
  let set = ?acceptSchemaResponse(
    b.data.toOpenArray(0, b.len - 1), b.root, AcceptOptions(system: true)
  )
  let bd = ?boundary(set, b.root)
  let v = ?validator(set, b.depth)
  let s = Selected(boundary: bd, validator: v)
  selectedCache[key] = s
  ok(s)

proc cacheSelected*(root: Digest, set: ContractSet, depth: int) =
  ## Keeps the set `materialize_route` just validated for this thread.
  hookSelected()
  if (root, depth) notin selectedCache:
    let b = boundary(set, root)
    let v = validator(set, depth)
    if b.isOk and v.isOk:
      selectedCache[(root, depth)] = Selected(boundary: b.get, validator: v.get)

# Route handles ------------------------------------------------------------------------

proc freeHandle*(h: ptr HandleState) =
  drop(h.blob)
  deinitCond(h.cond)
  deinitLock(h.lock)
  freeShared(h)

proc dropHandle*(h: ptr HandleState) =
  if h.refs.fetchSub(1) == 1:
    freeHandle(h)

var generations: Atomic[uint64]

proc nextGeneration*(): uint64 =
  ## [G177] A fresh invocation-path generation; never reused in this process.
  generations.fetchAdd(1) + 1

# The invocation-context stack ---------------------------------------------------------

var
  active {.threadvar.}: ptr Frame
  runtimeOwned {.threadvar.}: bool

proc markRuntimeThread*() =
  ## The engine's own threads: the Runtime thread and its lifecycle and call
  ## workers, where module initialization, destruction and completion
  ## callbacks run.
  runtimeOwned = true

proc setRuntimeOwned*(owned: bool) =
  ## [plan §2.6; G267] A Module Host's Runtime Control worker takes the calling
  ## host thread's kind for one call: one the host runs module code on, or one
  ## module code created.
  runtimeOwned = owned

proc inRuntimeCallback*(): bool =
  ## [SPEC RUNTIME l.4083] Whether this thread is one the Runtime owns, or is
  ## inside a provider entry or a consumer callback: module code whose
  ## completion shutdown may require.
  runtimeOwned or active != nil

proc push*(f: var Frame) =
  f.previous = active
  active = addr f

proc pop*(f: var Frame) =
  active = f.previous

template barrier*(body: untyped) =
  ## [SPEC INTERFACE l.2170] A consumer callback (an event handler) never sees
  ## the invocation context of a provider entry below it on this thread.
  var fence = Frame()
  push(fence)
  body
  pop(fence)

proc currentOp*(state: pointer): ptr LogosInvocationContext {.cdecl.} =
  ## [SPEC INTERFACE §2.9.3, l.2166-2170] The context of the innermost provider
  ## entry active on this thread for the instance `state` belongs to, so a
  ## nested entry into another instance hides nothing; none outside one, and
  ## none past a consumer callback's barrier.
  var f = active
  while f != nil:
    if f.context == nil:
      return nil
    if f.access == state:
      return f.context
    f = f.previous
  nil

# Entry guards of a deferred invocation ------------------------------------------------

proc enterGuard*(s: ptr InvocationState): bool =
  ## [SPEC INTERFACE l.2137-2141, l.2175-2177] Admits one entry using a
  ## deferred invocation's state; false once `execution_release` came, which
  ## closes admission (l.2177; I88), even while entries admitted before it
  ## still hold the state.
  if not s.guarded:
    return true
  withLock s.glock:
    if s.released or s.finished:
      return false
    inc s.entries
  true

proc leaveGuard*(s: ptr InvocationState) =
  ## One admitted entry returned. The last one after `execution_release` tells
  ## the Runtime thread the invocation is idle.
  if not s.guarded:
    return
  var idle = false
  withLock s.glock:
    dec s.entries
    if s.released and s.entries == 0 and not s.finished:
      s.finished = true
      idle = true
  if idle:
    s.engine.post(Msg(kind: mkDeferredIdle, target: s.owner))
