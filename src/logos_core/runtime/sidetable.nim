## The private handoffs between the Runtime and its Module Loader instance
## (Tier 4b step 4b-1; DECISIONS I89; D14, C-10) [IMPL].
##
## LOADER l.304-316, l.427 and l.704 keep the instance-bound bindings and the
## native results of a realization out of the contract: they cross "only
## through a private Runtime-to-Loader handoff". This is that handoff: one
## table per engine, in shared memory under one lock, holding plain pointers
## only, so any thread may read it under either memory manager.
##
## - **Inbound**, keyed by module instance, one entry per attempt: the
##   initialization services the Runtime supplies for the instance's
##   `_MODULE_init` (its Runtime Control binding, publish callback and
##   invocation access; LOADER §6 steps 5-6). The Runtime puts it before it
##   sends `realize` and withdraws it when the reply arrives. The Loader writes
##   back one field, `failedPhase`: `fpInit` when the error it returns came
##   from `_MODULE_init` itself (RUNTIME l.1566-1569; G250). A slot for a
##   transferred listener is reserved for hosted realization (4b-3, C-10).
## - **Outbound**, keyed by realization id: what the Runtime needs to call an
##   active direct provider and to publish for it (its dispatch, free and
##   asynchronous entries, its context, whether it declares events). The
##   Loader writes it when a realization becomes active and withdraws it once
##   `_MODULE_destroy` has returned (LDR-0152).
## - **Journal** (a test hook, only under `lcnTestHooks`; plan §2.12): each
##   request the Loader served, as plain values, in order.

{.push raises: [], gcsafe.}

import std/locks
import results
import ../abi/types
import ../base/testhooks

export results

testHooksMarker("sidetable")

const MaxKeyBytes = 128
  ## [SPEC RUNTIME §8; LOADER §7] module instance and realization ids

type Key = object
  bytes: array[MaxKeyBytes, char]
  len: int

when defined(lcnTestHooks):
  type
    JournalEntry* = object
      ## [plan §2.12] One request the Loader served, as plain values.
      meth*: string ## the method's name
      instance*: string ## the module instance it names
      realization*: string ## the realization id it names; empty: none
      module*: string ## `realize`: the descriptor's module name
      strategy*: string ## `realize`: the descriptor's implementation strategy
      source*: string ## `realize`: the static binding id or the artifact id

    JournalSlot = object
      fields: array[6, Key]
      next: ptr JournalSlot

type
  FailedPhase* = enum
    ## [IMPL-DECISION G250] Where an attempt's realization error came from.
    fpNone ## anything before `_MODULE_init` ran (the default)
    fpInit ## `_MODULE_init` failed, rejected its input or broke its contract

  InboundHandoff* = object
    ## [SPEC LOADER §6 steps 5-6] The instance-bound bindings for one attempt.
    runtimeControl*: ptr LogosRuntimeControlBinding
    publish*: LogosPublishFn
    publishUserData*: pointer
    invocationAccess*: LogosInvocationAccess
    listener*: pointer
      ## [C-10] reserved for a transferred listener (hosted realization,
      ## 4b-3); nil in 4b-1

  OutboundHandoff* = object
    ## [SPEC LOADER l.704] What the Runtime calls an active direct
    ## realization through. Valid until the realization is released.
    dispatch*: ModuleDispatchFn ## nil for a consumer-only module
    free*: ModuleFreeFn
    asyncApi*: ptr LogosAsyncProviderApi ## nil: the synchronous provider ABI
    context*: ptr LogosModuleContext
    declaresEvents*: bool

  InEntry = object
    key: Key
    handoff: InboundHandoff
    phase: FailedPhase
    next: ptr InEntry

  OutEntry = object
    key: Key
    handoff: OutboundHandoff
    next: ptr OutEntry

  SideTableObj = object
    lock: Lock
    inbound: ptr InEntry
    outbound: ptr OutEntry
    when defined(lcnTestHooks):
      journal: ptr JournalSlot
      journalTail: ptr JournalSlot

  SideTable* = ptr SideTableObj

proc toKey(s: string): Opt[Key] =
  if s.len == 0 or s.len > MaxKeyBytes:
    return Opt.none(Key)
  var k = Key(len: s.len)
  copyMem(addr k.bytes[0], unsafeAddr s[0], s.len)
  Opt.some(k)

func `==`(a, b: Key): bool =
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a.bytes[i] != b.bytes[i]:
      return false
  true

proc newSideTable*(): SideTable =
  result = createShared(SideTableObj)
  initLock(result.lock)

proc freeSideTable*(t: SideTable) =
  ## Frees the table and every entry still in it.
  if t == nil:
    return
  var i = t.inbound
  while i != nil:
    let n = i.next
    freeShared(i)
    i = n
  var o = t.outbound
  while o != nil:
    let n = o.next
    freeShared(o)
    o = n
  when defined(lcnTestHooks):
    var j = t.journal
    while j != nil:
      let n = j.next
      freeShared(j)
      j = n
  deinitLock(t.lock)
  freeShared(t)

proc findIn(t: SideTable, k: Key): ptr InEntry =
  var p = t.inbound
  while p != nil:
    if p.key == k:
      return p
    p = p.next
  nil

proc findOut(t: SideTable, k: Key): ptr OutEntry =
  var p = t.outbound
  while p != nil:
    if p.key == k:
      return p
    p = p.next
  nil

# Inbound ------------------------------------------------------------------------------

proc putInbound*(
    t: SideTable, instance: string, h: InboundHandoff
): Result[void, string] =
  ## The Runtime's handoff for the attempt it is about to send `realize` for.
  ## One per instance at a time: a second is refused.
  let k = toKey(instance).valueOr:
    return err("the module instance id has 1 to 128 bytes")
  let e = createShared(InEntry)
  e.key = k
  e.handoff = h
  var taken = false
  withLock t.lock:
    if t.findIn(k) != nil:
      taken = true
    else:
      e.next = t.inbound
      t.inbound = e
  if taken:
    freeShared(e)
    return err("the instance already has an inbound handoff")
  ok()

proc inbound*(t: SideTable, instance: string): Opt[InboundHandoff] =
  ## The Loader's read of the instance's handoff; none when the Runtime put
  ## none.
  let k = toKey(instance).valueOr:
    return Opt.none(InboundHandoff)
  withLock t.lock:
    let e = t.findIn(k)
    if e != nil:
      return Opt.some(e.handoff)
  Opt.none(InboundHandoff)

proc setFailedPhase*(t: SideTable, instance: string, phase: FailedPhase) =
  ## [G250] The Loader's note, before it returns an error, of where the error
  ## came from. Nothing happens when the entry is gone.
  let k = toKey(instance).valueOr:
    return
  withLock t.lock:
    let e = t.findIn(k)
    if e != nil:
      e.phase = phase

proc withdrawInbound*(t: SideTable, instance: string): Opt[FailedPhase] =
  ## Removes the instance's handoff once the reply arrived; returns the phase
  ## the Loader wrote, none when there was no entry.
  let k = toKey(instance).valueOr:
    return Opt.none(FailedPhase)
  var gone: ptr InEntry
  withLock t.lock:
    var p = addr t.inbound
    while p[] != nil:
      if p[].key == k:
        gone = p[]
        p[] = gone.next
        break
      p = addr p[].next
  if gone == nil:
    return Opt.none(FailedPhase)
  result = Opt.some(gone.phase)
  freeShared(gone)

# Outbound -----------------------------------------------------------------------------

proc putOutbound*(
    t: SideTable, realization: string, h: OutboundHandoff
): Result[void, string] =
  ## The Loader's handoff for a realization that has become active. A
  ## realization id is never issued twice, so a second is refused.
  let k = toKey(realization).valueOr:
    return err("the realization id has 1 to 128 bytes")
  let e = createShared(OutEntry)
  e.key = k
  e.handoff = h
  var taken = false
  withLock t.lock:
    if t.findOut(k) != nil:
      taken = true
    else:
      e.next = t.outbound
      t.outbound = e
  if taken:
    freeShared(e)
    return err("the realization already has an outbound handoff")
  ok()

proc outbound*(t: SideTable, realization: string): Opt[OutboundHandoff] =
  let k = toKey(realization).valueOr:
    return Opt.none(OutboundHandoff)
  withLock t.lock:
    let e = t.findOut(k)
    if e != nil:
      return Opt.some(e.handoff)
  Opt.none(OutboundHandoff)

proc withdrawOutbound*(t: SideTable, realization: string) =
  ## The Loader's removal once `_MODULE_destroy` has returned.
  let k = toKey(realization).valueOr:
    return
  var gone: ptr OutEntry
  withLock t.lock:
    var p = addr t.outbound
    while p[] != nil:
      if p[].key == k:
        gone = p[]
        p[] = gone.next
        break
      p = addr p[].next
  if gone != nil:
    freeShared(gone)

proc counts*(t: SideTable): (int, int) =
  ## The inbound and outbound entries held, for tests.
  withLock t.lock:
    var p = t.inbound
    while p != nil:
      inc result[0]
      p = p.next
    var o = t.outbound
    while o != nil:
      inc result[1]
      o = o.next

# Journal (test hook) ------------------------------------------------------------------

when defined(lcnTestHooks):
  proc textKey(s: string): Key =
    ## `s`, cut at `MaxKeyBytes`.
    result.len = min(s.len, MaxKeyBytes)
    if result.len > 0:
      copyMem(addr result.bytes[0], unsafeAddr s[0], result.len)

  proc text(k: Key): string =
    result = newString(k.len)
    if k.len > 0:
      copyMem(addr result[0], unsafeAddr k.bytes[0], k.len)

  proc journal*(t: SideTable, e: JournalEntry) =
    ## Appends `e`; the Loader calls it for each request it serves.
    let slot = createShared(JournalSlot)
    slot.fields = [
      textKey(e.meth),
      textKey(e.instance),
      textKey(e.realization),
      textKey(e.module),
      textKey(e.strategy),
      textKey(e.source),
    ]
    withLock t.lock:
      if t.journalTail == nil:
        t.journal = slot
      else:
        t.journalTail.next = slot
      t.journalTail = slot

  proc journalOf*(t: SideTable): seq[JournalEntry] =
    ## Every entry so far, copied onto the calling thread's heap.
    withLock t.lock:
      var p = t.journal
      while p != nil:
        result.add(
          JournalEntry(
            meth: p.fields[0].text,
            instance: p.fields[1].text,
            realization: p.fields[2].text,
            module: p.fields[3].text,
            strategy: p.fields[4].text,
            source: p.fields[5].text,
          )
        )
        p = p.next
