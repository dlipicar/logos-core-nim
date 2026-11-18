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
import logos_sdk/abi/[checks, types]
import logos_sdk/base/perthread
import logos_sdk/cbor/[decode, utf8]
import logos_sdk/hash/hashinput
import logos_sdk/iface/[accept, outcome, payload, surface]
import ../transport/boundary
import ./[callcheck, plumbing]
import logos_sdk/abi/cstatus
import ./entryframe

export callcheck, cstatus, entryframe

type
  SchemaBlob* = object
    ## The construction input `materialize_route` validated, shared by the
    ## handle, its subscriptions and its prepared calls, which may outlive it
    ## (RUNTIME l.880-884).
    refs: Atomic[int]
    root*: Digest
    len*: int
    data*: ptr UncheckedArray[byte]
    depth*: int ## [IF-02, I88] the engine's payload depth setting

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

# Results ---------------------------------------------------------------------------

proc status*(e: EngineError): LogosResult =
  status(e.code, e.message)

func failureOf*(e: EngineError): InvocationFailure =
  InvocationFailure(code: e.code, message: Opt.some(e.message))

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
  let s = ?buildSelected(b.data.toOpenArray(0, b.len - 1), b.root, b.depth)
  selectedCache[key] = s
  ok(s)

proc cacheSelected*(root: Digest, set: ContractSet, depth: int) =
  ## Keeps the set `materialize_route` just validated for this thread.
  hookSelected()
  if (root, depth) notin selectedCache:
    let s = buildSelected(set, root, depth)
    if s.isOk:
      selectedCache[(root, depth)] = s.get

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
