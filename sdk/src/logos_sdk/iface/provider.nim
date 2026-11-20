## INTERFACE §2.6: the provider call-surface descriptor that
## `logos_<module-C>_MODULE_call_surface()` returns.
##
## `callSurfaceDescriptor` encodes it from an accepted module binding;
## `acceptCallSurfaceDescriptor` validates one as an ABI caller must before the
## provider is registered or invoked: limits, closed maps, every document parsed
## and resolved under §5.3, every root recomputed and compared, supporting
## entries exact per contract and ordered, interfaces and earlier (`extends`)
## contracts ordered by derived namespace then root, no duplicate identity or
## interface namespace, the binding rules (`_module`, `_implements`, reserved
## and colliding bare method names) and each earlier contract extended by the
## described contract of its namespace. The descriptor is metadata: it has no
## root of its own.

{.push raises: [].}

import std/[algorithm, sequtils, sets]
import ../cbor
import ../hash/hashinput
import ./[accept, surface]

export accept

const
  MaxDescriptorBytes* = 8_388_608 ## [SPEC INTERFACE §2.6] the encoded descriptor
  MaxDescriptorInterfaces* = 256 ## [SPEC INTERFACE §2.6] `interfaces` entries
  MaxDescriptorExtends* = 256 ## [SPEC INTERFACE §2.6] `extends` entries
  MaxSupportingNamespaceBytes* = 128
    ## [SPEC INTERFACE §2.6] `provider-supporting-schema.namespace`
  DescriptorRequired* = ["interfaces"]
    ## [SPEC INTERFACE §2.6] `provider-call-surface`'s required keys
  DescriptorOptional* = ["primary", "extends"] ## and its optional ones
  ContractEntryKeys* = ["commitment", "document", "supporting_schemas"]
    ## [SPEC INTERFACE §2.6] `provider-contract-schema`
  SupportingEntryKeys* = ["namespace", "commitment", "document"]
    ## [SPEC INTERFACE §2.6] `provider-supporting-schema`

func isProvider*(b: ModuleBinding): bool =
  ## [SPEC INTERFACE §2.6] The binding exposes a provider contract: its primary
  ## contract or an implemented interface declares a method or an event. Only
  ## such a module exports `_MODULE_call_surface`.
  var docs = b.interfaces
  if b.primary.isSome:
    docs.insert(b.primary.get, 0)
  docs.anyIt(it.model.methods.len > 0 or it.model.events.len > 0)

func sameSet(supplied: openArray[Digest], own: seq[Contract]): bool =
  ## The supplied roots, each once, are exactly the roots of `own`.
  let mine = own.mapIt(it.root).toHashSet
  supplied.len == own.len and supplied.toHashSet == mine and
    supplied.toHashSet.len == supplied.len

func matchesContracts*(
    b: ModuleBinding,
    primary: Opt[Digest],
    interfaces: openArray[Digest],
    extends: openArray[Digest],
): bool =
  ## [SPEC INTERFACE §2.6 l.1717] Contract references that a package, Runtime
  ## input, static registration or protected built-in declaration supplies
  ## match the validated descriptor exactly: the same optional primary root, the
  ## same set of implemented-interface roots and the same set of extended
  ## roots.
  let own =
    if b.primary.isSome:
      Opt.some(b.primary.get.root)
    else:
      Opt.none(Digest)
  own == primary and sameSet(interfaces, b.interfaces) and sameSet(extends, b.extends)

func byNamespace(cs: seq[Contract]): seq[Contract] =
  ## [SPEC INTERFACE §2.6] Derived namespace UTF-8 bytes, then root bytes.
  result = cs
  result.sort(cmpContract)

func contractEntry(c: Contract, supporting: seq[Contract]): CborValue =
  cborMap(
    (cbor("commitment"), schemaCommitment(c.root)),
    (cbor("document"), cbor(c.source)),
    (cbor("supporting_schemas"), cborArray(supporting.mapIt(supportingEntry(it)))),
  )

func callSurfaceDescriptor*(b: ModuleBinding): Result[seq[byte], string] =
  ## [SPEC INTERFACE §2.6] The deterministic-CBOR `provider-call-surface` of an
  ## accepted binding: the primary contract with every supporting schema it or
  ## its interfaces use, then each interface (by namespace, then root) with
  ## exactly the supporting schemas it uses, then, when the binding has any,
  ## each earlier contract (by namespace, then root) with the supporting
  ## schemas it or the interfaces it selects use. A binding with neither a
  ## primary contract nor an interface, more than 256 interfaces or `extends`
  ## entries, or an encoding over 8 MiB has no descriptor.
  if b.primary.isNone and b.interfaces.len == 0:
    return err("a descriptor needs a primary contract, an interface or both")
  if b.interfaces.len > MaxDescriptorInterfaces:
    return err("more than 256 implemented interfaces")
  if b.extends.len > MaxDescriptorExtends:
    return err("more than 256 extends entries")
  var fields: seq[CborEntry]
  if b.primary.isSome:
    fields.add(
      (cbor("primary"), contractEntry(b.primary.get, supportingOf(b, b.primary.get)))
    )
  fields.add(
    (
      cbor("interfaces"),
      cborArray(byNamespace(b.interfaces).mapIt(contractEntry(it, supportingOf(b, it)))),
    )
  )
  if b.extends.len > 0:
    # [SPEC INTERFACE §2.6] `? extends: [+ …]`: absent rather than empty.
    fields.add(
      (
        cbor("extends"),
        cborArray(byNamespace(b.extends).mapIt(contractEntry(it, supportingOf(b, it)))),
      )
    )
  let bytes = encodeCbor(cborMap(fields))
  if bytes.len > MaxDescriptorBytes:
    return err("the descriptor is larger than 8,388,608 bytes")
  ok(bytes)

# Validation ------------------------------------------------------------------------

type
  SupportingClaim = object
    namespace: string
    root: Digest
    document: string

  ContractClaim = object
    root: Digest
    document: string
    supporting: seq[SupportingClaim]

func closedMap(
    v: CborValue,
    what: string,
    required: openArray[string],
    optional: openArray[string] = [],
): Result[void, string] =
  ## A map with text keys from exactly these sets: CDDL maps without a wildcard
  ## entry are closed.
  if v.kind != ckMap:
    return err(what & " is not a map")
  for (k, _) in v.entries:
    let name = k.getText
    if name.isNone or (name.get notin required and name.get notin optional):
      return err(what & " has an unknown key")
  for key in required:
    if v.lookup(key).isNone:
      return err(what & " lacks " & key)
  ok()

func sizedText(v: CborValue, what: string, maxBytes: int): Result[string, string] =
  let t = v.getText
  if t.isNone:
    return err(what & " is not UTF-8 text")
  if t.get.len < 1 or t.get.len > maxBytes:
    return err(what & " is not 1 to " & $maxBytes & " bytes")
  ok(t.get)

func parseSupporting(v: CborValue): Result[SupportingClaim, string] =
  ?closedMap(v, "a supporting entry", SupportingEntryKeys)
  let namespace =
    ?sizedText(v.lookup("namespace").get, "a namespace", MaxSupportingNamespaceBytes)
  let root = ?parseSchemaCommitment(v.lookup("commitment").get)
  let document = ?sizedText(v.lookup("document").get, "a document", MaxDocumentBytes)
  ok(SupportingClaim(namespace: namespace, root: root, document: document))

func parseContract(v: CborValue, what: string): Result[ContractClaim, string] =
  ?closedMap(v, what, ContractEntryKeys)
  let root = ?parseSchemaCommitment(v.lookup("commitment").get)
  let document =
    ?sizedText(v.lookup("document").get, what & " document", MaxDocumentBytes)
  var c = ContractClaim(root: root, document: document)
  let supp = v.lookup("supporting_schemas").get
  if supp.kind != ckArray:
    return err(what & " supporting_schemas is not an array")
  for x in supp.items:
    c.supporting.add(?parseSupporting(x))
  # [SPEC INTERFACE §2.6] Distinct namespaces and roots, ordered by namespace
  # UTF-8 bytes and then root bytes.
  var roots: HashSet[Digest]
  for i, s in c.supporting:
    if roots.containsOrIncl(s.root):
      return err(what & " lists one supporting schema root twice")
    if i > 0 and cmp(c.supporting[i - 1].namespace, s.namespace) >= 0:
      return
        err(what & " supporting entries are not in strictly ascending namespace order")
  ok(c)

func union(claims: seq[ContractClaim]): Result[seq[SupportingClaim], string] =
  ## Each supporting schema once. A namespace that several contracts need must
  ## name the same document and root in each entry.
  var all: seq[SupportingClaim]
  for c in claims:
    for s in c.supporting:
      var known = false
      for a in all:
        if a.namespace == s.namespace:
          if a.root != s.root or a.document != s.document:
            return
              err("the entries for supporting namespace " & s.namespace & " disagree")
          known = true
        elif a.root == s.root:
          return err("one supporting schema root appears under two namespaces")
      if not known:
        all.add(s)
  ok(all)

func findSource(cs: seq[Contract], source: string): Opt[Contract] =
  for c in cs:
    if c.source == source:
      return Opt.some(c)
  Opt.none(Contract)

func sameSupporting(
    claimed: seq[SupportingClaim], expected: seq[Contract], what: string
): Result[void, string] =
  ## [SPEC INTERFACE §2.6] All and only the supporting schemas the contract
  ## needs (both lists are in namespace order).
  if claimed.len != expected.len:
    return err(what & " does not list exactly the supporting schemas it uses")
  for i, s in claimed:
    if s.root != expected[i].root:
      return err(what & " does not list exactly the supporting schemas it uses")
  ok()

proc acceptCallSurfaceDescriptor*(
    data: openArray[byte], module: string, opts = AcceptOptions()
): Result[ModuleBinding, string] =
  ## [SPEC INTERFACE §2.6] Validates the bytes `_MODULE_call_surface()` returned
  ## for the module named `module` (`_MODULE_name()`) and returns the binding
  ## they describe. Any failure makes the provider invalid.
  if data.len == 0:
    return err("an empty descriptor")
  if data.len > MaxDescriptorBytes:
    return err("the descriptor is larger than 8,388,608 bytes")
  let v = decodeCbor(data).valueOr:
    return err("not Logos deterministic CBOR: " & $error)
  ?closedMap(v, "the descriptor", DescriptorRequired, DescriptorOptional)
  let list = v.lookup("interfaces").get
  if list.kind != ckArray:
    return err("interfaces is not an array")
  if list.items.len > MaxDescriptorInterfaces:
    return err("more than 256 interfaces")
  let extendsV = v.lookup("extends")
  if extendsV.isSome:
    if extendsV.get.kind != ckArray:
      return err("extends is not an array")
    # [SPEC INTERFACE §2.6] `[+ …]`, at most 256 entries, counted before any
    # entry is parsed.
    if extendsV.get.items.len == 0:
      return err("extends is present and empty")
    if extendsV.get.items.len > MaxDescriptorExtends:
      return err("more than 256 extends entries")
  let primaryV = v.lookup("primary")
  if primaryV.isNone and list.items.len == 0:
    return err("a descriptor needs a primary contract, an interface or both")
  var primary = Opt.none(ContractClaim)
  if primaryV.isSome:
    primary = Opt.some(?parseContract(primaryV.get, "the primary entry"))
  var ifaces: seq[ContractClaim]
  for x in list.items:
    ifaces.add(?parseContract(x, "an interface entry"))
  var earlier: seq[ContractClaim]
  if extendsV.isSome:
    for x in extendsV.get.items:
      earlier.add(?parseContract(x, "an extends entry"))
  # [SPEC INTERFACE §2.6] Distinct schema roots among the `extends` entries.
  var claimed: HashSet[Digest]
  for c in earlier:
    if claimed.containsOrIncl(c.root):
      return err("two extends entries claim one schema root")
  # [IMPL-DECISION G392] r7: an `extends` entry's supporting schemas join the
  # gather-once set, so one that needs another document for a namespace is
  # refused here.
  var claims = ifaces & earlier
  if primary.isSome:
    claims.insert(primary.get, 0)
  let supp = ?union(claims)
  # Parse, resolve and check every document: the primary and interface
  # documents as one construction input set, and each `extends` document as its
  # own, related to the described contract of its namespace.
  let b = ?acceptBinding(
    module,
    primary.map(
      proc(c: ContractClaim): string =
        c.document
    ),
    ifaces.mapIt(it.document),
    supp.mapIt(it.document),
    opts,
    earlier.mapIt(it.document),
  )
  # Every claimed commitment and namespace against its recomputed value.
  for s in supp:
    let c = b.supporting.findSource(s.document).valueOr:
      return err("a supporting entry's document is not in the binding")
    if c.model.namespace != s.namespace:
      return err(
        "the supporting entry " & s.namespace & " names a document with namespace " &
          c.model.namespace
      )
    if c.root != s.root:
      return err("the supporting entry " & s.namespace & " has the wrong commitment")
  if primary.isSome:
    let p = b.primary.get
    if p.root != primary.get.root:
      return err("the primary entry has the wrong commitment")
    ?sameSupporting(primary.get.supporting, supportingOf(b, p), "the primary entry")
  var described: seq[Contract]
  for claim in ifaces:
    let c = b.interfaces.findSource(claim.document).valueOr:
      return err("an interface entry's document is not in the binding")
    if c.root != claim.root:
      return
        err("the interface entry " & c.model.namespace & " has the wrong commitment")
    ?sameSupporting(
      claim.supporting, supportingOf(b, c), "the interface entry " & c.model.namespace
    )
    described.add(c)
  for i in 1 ..< described.len:
    let byName = cmp(described[i - 1].model.namespace, described[i].model.namespace)
    if byName == 0:
      return err("two interface entries have namespace " & described[i].model.namespace)
    if byName > 0:
      return err("interface entries are not in namespace, then root order")
  var olders: seq[Contract]
  for claim in earlier:
    let c = b.extends.findSource(claim.document).valueOr:
      return err("an extends entry's document is not in the binding")
    if c.root != claim.root:
      return err("the extends entry " & c.model.namespace & " has the wrong commitment")
    ?sameSupporting(
      claim.supporting, supportingOf(b, c), "the extends entry " & c.model.namespace
    )
    olders.add(c)
  # [SPEC INTERFACE §2.6] `extends` entries by derived namespace, then root.
  for i in 1 ..< olders.len:
    if cmpContract(olders[i - 1], olders[i]) >= 0:
      return err("extends entries are not in namespace, then root order")
  # Nothing above may let a non-canonical descriptor through.
  let again = ?callSurfaceDescriptor(b)
  if again != @data:
    return err("the descriptor is not the canonical encoding of its binding")
  ok(b)
