## INTERFACE §2.6: the provider call-surface descriptor that
## `logos_<module-C>_MODULE_call_surface()` returns.
##
## `callSurfaceDescriptor` encodes it from an accepted module binding;
## `acceptCallSurfaceDescriptor` validates one as an ABI caller must before the
## provider is registered or invoked: limits, closed maps, every document parsed
## and resolved under §5.3, every root recomputed and compared, supporting
## entries exact per contract and ordered, interfaces ordered by derived
## namespace then root, no duplicate identity or interface namespace, and the
## binding rules (`_module`, `_implements`, reserved and colliding bare method
## names). The descriptor is metadata: it has no root of its own.

{.push raises: [].}

import std/[algorithm, sequtils, sets]
import ../cbor
import ../hash/hashinput
import ./[accept, surface]

export accept

const
  MaxDescriptorBytes* = 8_388_608 ## [SPEC INTERFACE §2.6] the encoded descriptor
  MaxDescriptorInterfaces* = 256 ## [SPEC INTERFACE §2.6] `interfaces` entries
  MaxSupportingNamespaceBytes* = 128
    ## [SPEC INTERFACE §2.6] `provider-supporting-schema.namespace`
  DescriptorKeys* = ["primary", "interfaces"]
    ## [SPEC INTERFACE §2.6] `provider-call-surface` (`primary` optional)
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

func matchesContracts*(
    b: ModuleBinding, primary: Opt[Digest], interfaces: openArray[Digest]
): bool =
  ## [SPEC INTERFACE §2.6] Contract references that a package, Runtime input,
  ## static registration or protected built-in declaration supplies match the
  ## validated descriptor exactly: the same optional primary root and the same
  ## set of implemented-interface roots.
  let own =
    if b.primary.isSome:
      Opt.some(b.primary.get.root)
    else:
      Opt.none(Digest)
  if own != primary or interfaces.len != b.interfaces.len:
    return false
  let mine = b.interfaces.mapIt(it.root).toHashSet
  interfaces.toHashSet == mine and interfaces.toHashSet.len == interfaces.len

func supportingOf(b: ModuleBinding, c: Contract): seq[Contract] =
  ## The binding's supporting schemas that `c` references, in namespace order.
  let used = c.model.importedRoots
  b.supporting.filterIt(it.root in used)

func byNamespace(cs: seq[Contract]): seq[Contract] =
  ## [SPEC INTERFACE §2.6] Derived namespace UTF-8 bytes, then root bytes.
  result = cs
  result.sort(
    proc(a, b: Contract): int =
      let byName = cmp(a.model.namespace, b.model.namespace)
      if byName != 0:
        byName
      else:
        cmpBytes(a.root, b.root)
  )

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
  ## exactly the supporting schemas it uses. A binding with neither a primary
  ## contract nor an interface, more than 256 interfaces or an encoding over
  ## 8 MiB has no descriptor.
  if b.primary.isNone and b.interfaces.len == 0:
    return err("a descriptor needs a primary contract, an interface or both")
  if b.interfaces.len > MaxDescriptorInterfaces:
    return err("more than 256 implemented interfaces")
  var fields: seq[CborEntry]
  if b.primary.isSome:
    fields.add((cbor("primary"), contractEntry(b.primary.get, b.supporting)))
  fields.add(
    (
      cbor("interfaces"),
      cborArray(byNamespace(b.interfaces).mapIt(contractEntry(it, supportingOf(b, it)))),
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
  ?closedMap(v, "the descriptor", ["interfaces"], ["primary"])
  let list = v.lookup("interfaces").get
  if list.kind != ckArray:
    return err("interfaces is not an array")
  if list.items.len > MaxDescriptorInterfaces:
    return err("more than 256 interfaces")
  let primaryV = v.lookup("primary")
  if primaryV.isNone and list.items.len == 0:
    return err("a descriptor needs a primary contract, an interface or both")
  var primary = Opt.none(ContractClaim)
  if primaryV.isSome:
    primary = Opt.some(?parseContract(primaryV.get, "the primary entry"))
  var ifaces: seq[ContractClaim]
  for x in list.items:
    ifaces.add(?parseContract(x, "an interface entry"))
  var claims = ifaces
  if primary.isSome:
    claims.insert(primary.get, 0)
  let supp = ?union(claims)
  # Parse, resolve and check every document as one construction input set.
  let b = ?acceptBinding(
    module,
    primary.map(
      proc(c: ContractClaim): string =
        c.document
    ),
    ifaces.mapIt(it.document),
    supp.mapIt(it.document),
    opts,
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
    ?sameSupporting(primary.get.supporting, b.supporting, "the primary entry")
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
  # Nothing above may let a non-canonical descriptor through.
  let again = ?callSurfaceDescriptor(b)
  if again != @data:
    return err("the descriptor is not the canonical encoding of its binding")
  ok(b)
