## A provider whose primary contract extends two earlier contracts (COMMITMENT
## §9.1; re-pin P8b, synthesis §3). `relay_module` (document B) declares two
## methods, two events and one implemented interface, `pulse`. Its earlier
## views are derived from B's text when the tests run, so every root is
## computed, never typed:
##
## - A1 drops the method `reset` and keeps the interface;
## - A2 drops the event `cleared` and does not select the interface.
##
## No kit or generator takes `extends` (P8 Q3), so the module is a scripted
## static table, as `test_hosted_routes`'s `vault_module` is: its
## `_MODULE_call_surface` returns the descriptor of B with `extends = [A1, A2]`,
## and its dispatch answers every method of B. `relayBadTable` returns a
## descriptor whose A1 entry is swapped for a document B does not extend (its
## `read` takes another channel type), with that document's own commitment:
## no SDK call builds such a descriptor.

import std/[algorithm, atomics, sequtils, strutils]
import results
import logos_sdk/abi/types
import logos_sdk/base/hex
import logos_sdk/cbor
import logos_sdk/hash/hashinput
import logos_sdk/iface/[accept, cmap, outcome, provider, surface]
import ../../src/logos_core/runtime/records

export accept.ModuleBinding

const
  RelayModule* = "relay_module"
  PulseDoc* =
    "_interface = \"pulse\"\n\npulse.ping_request = {}\npulse.ping_response = {}\n"
  ReadDecls =
    "relay.read_request = {\n  channel: uint32,\n}\n\n" &
    "relay.read_response = {\n  value: uint64,\n}\n\n"
  ResetDecls = "relay.reset_request = {}\n\nrelay.reset_response = {}\n\n"
  ChangedDecl* = "relay.changed_event"
  ClearedDecl* = "relay.cleared_event"
  EventDecls =
    ChangedDecl & " = {\n  channel: uint32,\n}\n\n" & ClearedDecl &
    " = {\n  channel: uint32,\n}\n"
  RelayValue* = 42'u64 ## what `read` answers, on every view

let
  pulseRoot* = acceptContractSet(PulseDoc).tryGet.primary.root
  implementsLine = "_implements = [h'" & toHex(pulseRoot) & "']\n"
  relayDoc* =
    "_module = \"" & RelayModule & "\"\n" & implementsLine & "\n" & ReadDecls &
    ResetDecls & EventDecls
  relayA1Doc* = relayDoc.replace(ResetDecls, "") ## no `reset`; selects `pulse`
  relayA2Doc* = relayDoc.replace(implementsLine, "").replace(
      "\n" & ClearedDecl & " = {\n  channel: uint32,\n}\n", ""
    ) ## no `cleared`; no interface

proc relayBinding*(
    extends: openArray[string] = [relayA1Doc, relayA2Doc]
): ModuleBinding =
  ## B with these earlier documents, as the Runtime accepts its descriptor.
  acceptBinding(
    RelayModule, Opt.some(relayDoc), [PulseDoc], [], AcceptOptions(), extends
  ).tryGet

proc earlierRoot(b: ModuleBinding, source: string): Digest =
  for c in b.extends:
    if c.source == source:
      return c.root
  doAssert false, "no such extends entry"

let
  relay = relayBinding()
  relayRoot* = relay.primary.get.root
  relayA1Root* = relay.earlierRoot(relayA1Doc)
  relayA2Root* = relay.earlierRoot(relayA2Doc)
  relayDescriptor* = callSurfaceDescriptor(relay).tryGet

proc relaySchema*(root: Digest): seq[byte] =
  ## A consumer's construction input for one of the provider's contracts: the
  ## provider's own schema answer for it (INTERFACE §5.1).
  encodeCbor(schemaResponse(relay, root).tryGet)

proc relayRecord*(
    binding = "relay",
    primary = Opt.some(relayRoot),
    implements = @[pulseRoot],
    extends = @[relayA1Root, relayA2Root],
): ModuleRecord =
  ## A record stating every contract the descriptor validates.
  ModuleRecord(
    module: RelayModule,
    strategy: stDirectStatic,
    binding: binding,
    primaryContract: primary,
    implements: implements,
    extends: extends,
  )

# The descriptor B does not extend -------------------------------------------------------

proc badDescriptor(): seq[byte] =
  let swapped = relayA1Doc.replace(
    "relay.read_request = {\n  channel: uint32,",
    "relay.read_request = {\n  channel: uint64,",
  )
  doAssert swapped != relayA1Doc
  let root = acceptContractSet(swapped, [PulseDoc]).tryGet.primary.root
  let good = decodeCbor(relayDescriptor).tryGet
  var fields: seq[CborEntry]
  for (k, v) in good.entries:
    if k.text != "extends":
      fields.add((k, v))
      continue
    var items: seq[CborValue]
    for entry in v.items:
      if entry.lookup("document").get.text == relayA1Doc:
        items.add(
          cborMap(
            (cbor("commitment"), schemaCommitment(root)),
            (cbor("document"), cbor(swapped)),
            (cbor("supporting_schemas"), cborArray()),
          )
        )
      else:
        items.add(entry)
    # Both entries are in B's namespace: ordered by root bytes.
    items.sort(
      proc(a, b: CborValue): int =
        cmpBytes(
          a.lookup("commitment").get.lookup("schema_root").get.bytes,
          b.lookup("commitment").get.lookup("schema_root").get.bytes,
        )
    )
    fields.add((k, cborArray(items)))
  encodeCbor(cborMap(fields))

let relayBadDescriptor* = badDescriptor()

# The scripted module ------------------------------------------------------------------------

var
  relayCalls*: Atomic[int] ## dispatched calls, every view's
  publishFn: Atomic[pointer]
  publishData: Atomic[pointer]
  goodBytes, badBytes: ptr UncheckedArray[uint8]
  goodLen, badLen: int

proc sharedCopy(b: seq[byte]): ptr UncheckedArray[uint8] =
  result = cast[ptr UncheckedArray[uint8]](allocShared0(b.len))
  for i, x in b:
    result[i] = x

goodBytes = sharedCopy(relayDescriptor)
goodLen = relayDescriptor.len
badBytes = sharedCopy(relayBadDescriptor)
badLen = relayBadDescriptor.len

proc relayName(): cstring {.cdecl, gcsafe, raises: [].} =
  RelayModule

proc relayCallSurface(outLen: ptr csize_t): ptr uint8 {.cdecl, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    outLen[] = csize_t(goodLen)
    cast[ptr uint8](goodBytes)

proc relayBadCallSurface(outLen: ptr csize_t): ptr uint8 {.cdecl, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    outLen[] = csize_t(badLen)
    cast[ptr uint8](badBytes)

proc relayInit(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.cdecl, gcsafe, raises: [].} =
  publishFn.store(cast[pointer](input.publish))
  publishData.store(input.publishUserData)
  outContext[] = cast[ptr LogosModuleContext](allocShared0(8))

proc relayDestroy(module: ptr LogosModuleContext) {.cdecl, gcsafe, raises: [].} =
  deallocShared(module)

proc relayFree(
    module: ptr LogosModuleContext, p: pointer
) {.cdecl, gcsafe, raises: [].} =
  if p != nil:
    deallocShared(p)

proc relayDispatch(
    module: ptr LogosModuleContext,
    methodName: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    outResp: ptr ptr UncheckedArray[uint8],
    outLen: ptr csize_t,
): LogosResult {.cdecl, gcsafe, raises: [].} =
  ## B's implementation, whichever view the route selected (INTERFACE l.202).
  relayCalls.atomicInc
  let response =
    case $methodName
    of "read":
      encodeCbor(cborMap((cbor("value"), cbor(RelayValue))))
    of "reset", "ping":
      encodeCbor(cborMap())
    else:
      return LogosResult(code: CErrorCode(ord(ecModule)))
  let buf = cast[ptr UncheckedArray[uint8]](allocShared0(response.len))
  for i, x in response:
    buf[i] = x
  outResp[] = buf
  outLen[] = csize_t(response.len)

proc table(surface: pointer): seq[(string, pointer)] =
  result = @[
    ("logos_relay_module_MODULE_name", cast[pointer](relayName)),
    ("logos_relay_module_MODULE_call_surface", surface),
    ("logos_relay_module_MODULE_init", cast[pointer](relayInit)),
    ("logos_relay_module_MODULE_destroy", cast[pointer](relayDestroy)),
    ("logos_relay_module_MODULE_dispatch", cast[pointer](relayDispatch)),
    ("logos_relay_module_MODULE_free", cast[pointer](relayFree)),
  ]
  # The per-method functions B's C mapping names; no test calls them.
  for c in cLayout(cSchemaSet(relay)).tryGet.calls:
    result.add((c.symbol, cast[pointer](relayDispatch)))

proc relayTable*(): seq[(string, pointer)] =
  table(cast[pointer](relayCallSurface))

proc relayBadTable*(): seq[(string, pointer)] =
  table(cast[pointer](relayBadCallSurface))

proc relayPublish*(name: string, channel: uint32): CErrorCode =
  ## The module's own publish callback, as its code would call it.
  let f = cast[LogosPublishFn](publishFn.load)
  let data = encodeCbor(cborMap((cbor("channel"), cbor(uint64(channel)))))
  f(
    publishData.load,
    cstring(name),
    cast[ptr UncheckedArray[uint8]](unsafeAddr data[0]),
    csize_t(data.len),
  )
