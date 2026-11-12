## The protected attribute source of the Capability Authority [IMPL]
## (CA §3 l.71-81, l.103-108; decision G47; DECISIONS I84).
##
## `SharedFacts` holds what the Runtime knows about its local module
## instances: each instance's module name and execution selection, and which
## instance backs each provider. The Runtime writes it (step 8b: an instance is
## put before it is exposed and removed at retirement); the CA only reads it.
## Nothing in it comes from a request (CAP-0276).
##
## The table is one deterministic-CBOR value in a shared buffer under a lock,
## with a version that every change increments. A reader copies the bytes and
## decodes them on its own heap, so no garbage-collected value crosses threads
## under either memory manager. `FactsView` caches the decoded table per
## reader and refreshes it only when the version moved.
##
## Freshness (G47, CAP-0279 to CAP-0282): an instance's name and selection are
## fixed for its life, and a provider id is bound to one instance for that
## instance's life (`putProvider` refuses a rebinding). The only transitions
## are retirement and `close`, after which every lookup is unavailable
## (CAP-0278, CAP-0283).

{.push raises: [].}

import std/[locks, tables]
import results
import ../cbor
from ../runtime/rc_types import LogosNSRuntimeControlExecutionSelection, encode, decode

export results, LogosNSRuntimeControlExecutionSelection

type
  ExecutionSelection* = LogosNSRuntimeControlExecutionSelection

  InstanceFacts* = object
    module*: string
    selection*: Opt[ExecutionSelection]
      ## [SPEC RUNTIME §9.3] signer, package and version, when known

  FactsLookupKind* = enum
    flFound
    flUnknown ## the Runtime does not know it (CA l.77: `invalid-request`)
    flUnavailable ## the source is lost (CAP-0278: `authority-unavailable`)

  FactsLookup* = object
    case kind*: FactsLookupKind
    of flFound:
      instance*: string
      facts*: InstanceFacts
    else:
      discard

  FactsObj = object
    lock: Lock
    runtimeId: cstring
    blob: ptr UncheckedArray[byte]
    blobLen: int
    version: uint64
    closed: bool

  SharedFacts* = ptr FactsObj

  FactsView* = object ## One reader's decoded copy.
    version: uint64
    loaded: bool
    closed: bool
    instances: Table[string, InstanceFacts]
    providers: Table[string, string]

# The encoded table ------------------------------------------------------------------

proc encodeTable(
    instances: Table[string, InstanceFacts], providers: Table[string, string]
): Result[seq[byte], string] =
  var inst: seq[CborEntry]
  for id, f in instances:
    let sel =
      if f.selection.isSome:
        cbor(?encode(f.selection.get))
      else:
        cborNull()
    inst.add((cbor(id), cborArray(cbor(f.module), sel)))
  var prov: seq[CborEntry]
  for p, i in providers:
    prov.add((cbor(p), cbor(i)))
  ok(encodeCbor(cborMap((cbor("i"), cborMap(inst)), (cbor("p"), cborMap(prov)))))

proc decodeTable(
    data: openArray[byte],
    instances: var Table[string, InstanceFacts],
    providers: var Table[string, string],
): Result[void, string] =
  instances.clear()
  providers.clear()
  if data.len == 0:
    return ok()
  let v = decodeCbor(data).valueOr:
    return err("facts: " & $error)
  let inst = v.lookup("i")
  let prov = v.lookup("p")
  if inst.isNone or prov.isNone or inst.get.kind != ckMap or prov.get.kind != ckMap:
    return err("facts: malformed table")
  for (k, e) in inst.get.entries:
    if k.kind != ckText or e.kind != ckArray or e.items.len != 2 or
        e.items[0].kind != ckText:
      return err("facts: malformed instance")
    var f = InstanceFacts(module: e.items[0].text)
    if e.items[1].kind == ckBytes:
      f.selection = Opt.some(?decode(ExecutionSelection, e.items[1].bytes))
    instances[k.text] = f
  for (k, e) in prov.get.entries:
    if k.kind != ckText or e.kind != ckText:
      return err("facts: malformed provider")
    providers[k.text] = e.text
  ok()

proc selectionBytes(f: InstanceFacts): Result[seq[byte], string] =
  if f.selection.isSome:
    encode(f.selection.get)
  else:
    ok(newSeq[byte]())

proc sameFacts(a, b: InstanceFacts): Result[bool, string] =
  ok(a.module == b.module and ?a.selectionBytes() == ?b.selectionBytes())

# The shared table -------------------------------------------------------------------

proc newSharedFacts*(runtimeId: string): SharedFacts =
  result = cast[SharedFacts](allocShared0(sizeof(FactsObj)))
  initLock(result.lock)
  result.runtimeId = cast[cstring](allocShared0(runtimeId.len + 1))
  if runtimeId.len > 0:
    copyMem(result.runtimeId, unsafeAddr runtimeId[0], runtimeId.len)

proc freeSharedFacts*(f: SharedFacts) =
  ## Only once no thread uses `f` any more.
  if f == nil:
    return
  if f.blob != nil:
    deallocShared(f.blob)
  deallocShared(f.runtimeId)
  deinitLock(f.lock)
  deallocShared(f)

proc runtimeId*(f: SharedFacts): string =
  $f.runtimeId

proc readBlob(f: SharedFacts, closed: var bool, version: var uint64): seq[byte] =
  withLock f.lock:
    closed = f.closed
    version = f.version
    if f.blobLen > 0:
      result = newSeq[byte](f.blobLen)
      copyMem(addr result[0], f.blob, f.blobLen)

proc writeBlob(f: SharedFacts, data: seq[byte]) =
  ## Under `f.lock`.
  if f.blob != nil:
    deallocShared(f.blob)
    f.blob = nil
  f.blobLen = data.len
  if data.len > 0:
    f.blob = cast[ptr UncheckedArray[byte]](allocShared(data.len))
    copyMem(f.blob, unsafeAddr data[0], data.len)
  inc f.version

template update(f: SharedFacts, body: untyped) =
  ## Runs `body` with `instances` and `providers` bound to the current table,
  ## and stores the result, all under the lock: writers are serialized.
  withLock f.lock:
    if f.closed:
      return err("the attribute source is closed")
    var instances {.inject.}: Table[string, InstanceFacts]
    var providers {.inject.}: Table[string, string]
    var current: seq[byte]
    if f.blobLen > 0:
      current = newSeq[byte](f.blobLen)
      copyMem(addr current[0], f.blob, f.blobLen)
    ?decodeTable(current, instances, providers)
    body
    f.writeBlob(?encodeTable(instances, providers))
  return ok()

proc putInstance*(
    f: SharedFacts, id: string, facts: InstanceFacts
): Result[void, string] =
  ## Before the instance is exposed. The facts are fixed for its life: a
  ## second put with other facts is refused.
  f.update:
    if id in instances:
      if not ?sameFacts(instances.getOrDefault(id), facts):
        return err("the facts of instance " & id & " are fixed for its life")
    instances[id] = facts

proc removeInstance*(f: SharedFacts, id: string): Result[void, string] =
  ## At retirement, before it is exposed. Its providers go with it.
  f.update:
    instances.del(id)
    var gone: seq[string]
    for p, i in providers:
      if i == id:
        gone.add p
    for p in gone:
      providers.del(p)

proc putProvider*(
    f: SharedFacts, providerId, instanceId: string
): Result[void, string] =
  ## Binds a provider to its backing instance, once (G47).
  f.update:
    if instanceId notin instances:
      return err("unknown instance " & instanceId)
    if providerId in providers and providers.getOrDefault(providerId) != instanceId:
      return err("provider " & providerId & " is bound to another instance")
    providers[providerId] = instanceId

proc removeProvider*(f: SharedFacts, providerId: string): Result[void, string] =
  ## At its instance's retirement.
  f.update:
    providers.del(providerId)

proc close*(f: SharedFacts) =
  ## Source loss: every later lookup is unavailable.
  withLock f.lock:
    f.closed = true
    inc f.version

proc isClosed*(f: SharedFacts): bool =
  withLock f.lock:
    result = f.closed

# Reading ----------------------------------------------------------------------------

proc refresh*(v: var FactsView, f: SharedFacts) =
  ## Brings `v` up to date with `f`. A table that does not decode (a Runtime
  ## fault) reads as unavailable.
  var closed: bool
  var version: uint64
  let data = f.readBlob(closed, version)
  if v.loaded and version == v.version:
    return
  v.version = version
  v.loaded = true
  v.closed = closed
  if not closed and decodeTable(data, v.instances, v.providers).isErr:
    v.closed = true

func lookup*(v: FactsView, id: string): FactsLookup =
  if v.closed or not v.loaded:
    FactsLookup(kind: flUnavailable)
  elif id in v.instances:
    FactsLookup(kind: flFound, instance: id, facts: v.instances.getOrDefault(id))
  else:
    FactsLookup(kind: flUnknown)

func backing*(v: FactsView, providerId: string): FactsLookup =
  ## The instance that backs a local provider.
  if v.closed or not v.loaded:
    FactsLookup(kind: flUnavailable)
  elif providerId in v.providers:
    v.lookup(v.providers.getOrDefault(providerId))
  else:
    FactsLookup(kind: flUnknown)

func available*(v: FactsView): bool =
  v.loaded and not v.closed

proc lookup*(f: SharedFacts, id: string): FactsLookup =
  var v: FactsView
  v.refresh(f)
  v.lookup(id)

proc backing*(f: SharedFacts, providerId: string): FactsLookup =
  var v: FactsView
  v.refresh(f)
  v.backing(providerId)

# Facts accessors ---------------------------------------------------------------------

func signer*(f: InstanceFacts): Opt[seq[byte]] =
  if f.selection.isSome and f.selection.get.signer.isSome:
    Opt.some(f.selection.get.signer.get.public_key)
  else:
    Opt.none(seq[byte])

func package*(f: InstanceFacts): Opt[string] =
  if f.selection.isSome and f.selection.get.package.isSome:
    Opt.some(f.selection.get.package.get.package)
  else:
    Opt.none(string)

func version*(f: InstanceFacts): Opt[string] =
  if f.selection.isSome and f.selection.get.package.isSome:
    Opt.some(f.selection.get.package.get.version)
  else:
    Opt.none(string)
