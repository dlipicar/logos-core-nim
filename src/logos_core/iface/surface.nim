## INTERFACE §1.4, §1.5, §2.1, §5.1: call surfaces, schema commitments and the
## `logos.schema` response.
##
## A call surface lists what an accepted contract set exposes: each method by its
## bare wire name (with its defining contract) and each event by its complete
## schema event identifier. `logos.schema_commitment` names one schema root under
## the pinned commitment model, hash profile and suite. `logos.schema_response`
## carries the documents that reconstruct a route's selected contract.

{.push raises: [].}

import std/[algorithm, sequtils]
import ../cbor
import ../hash/hashinput
import ../pins
import ./accept

export accept

const MaxSchemaResponseBytes* = 8_388_608
  ## [SPEC INTERFACE §5.1] the encoded `logos.schema_response`

type
  SurfaceMethod* = object
    bare*: string ## [SPEC INTERFACE §2.1] the method-name string on the wire
    name*: string ## the qualified method (`storage.exists`)
    namespace*: string ## the defining contract's namespace
    request*, response*: string ## the declarations' qualified names
    contract*: Digest ## the defining contract's schema root
    doc*: int ## the defining document's index in `ContractSet.documents`

  SurfaceEvent* = object
    id*: string ## [SPEC INTERFACE §1.5] the complete schema event identifier
    namespace*: string
    contract*: Digest
    doc*: int

  CallSurface* = object
    methods*: seq[SurfaceMethod] ## by bare name
    events*: seq[SurfaceEvent] ## by identifier

# Call surface ----------------------------------------------------------------------

func callSurface*(s: ContractSet): CallSurface =
  ## [SPEC INTERFACE §1.2, §1.4] The primary contract's methods and events and
  ## those of every implemented interface, each keeping its defining contract.
  ## A supporting schema exposes nothing.
  var c = CallSurface()
  let docs = s.documents
  for i, d in docs:
    if d.model.role notin {srModule, srInterface}:
      continue
    if i > s.interfaces.len:
      break # supporting schemas follow the interfaces
    for m in d.model.methods:
      c.methods.add(
        SurfaceMethod(
          bare: bareMethodName(m.name, d.model.namespace),
          name: m.name,
          namespace: d.model.namespace,
          request: m.request,
          response: m.response,
          contract: d.root,
          doc: i,
        )
      )
    for e in d.model.events:
      c.events.add(
        SurfaceEvent(id: e.name, namespace: d.model.namespace, contract: d.root, doc: i)
      )
  c.methods.sort(
    proc(a, b: SurfaceMethod): int =
      cmp(a.bare, b.bare)
  )
  c.events.sort(
    proc(a, b: SurfaceEvent): int =
      cmp(a.id, b.id)
  )
  c

func findMethod*(c: CallSurface, bare: string): Opt[SurfaceMethod] =
  for m in c.methods:
    if m.bare == bare:
      return Opt.some(m)
  Opt.none(SurfaceMethod)

func findEvent*(c: CallSurface, id: string): Opt[SurfaceEvent] =
  for e in c.events:
    if e.id == id:
      return Opt.some(e)
  Opt.none(SurfaceEvent)

# logos.schema_commitment -----------------------------------------------------------

func schemaCommitment*(root: Digest): CborValue =
  ## [SPEC INTERFACE §5.1] `logos.schema_commitment` for `root`. The literals are
  ## the pinned identifiers, which the common schema's own literals must equal
  ## (checked by the tests against the mirror).
  cborMap(
    (cbor("commitment_model"), cbor(CommitmentModelId)),
    (cbor("hash_profile"), cbor(HashProfileId)),
    (cbor("hash_suite"), cbor(HashSuiteId)),
    (cbor("schema_root"), cbor(root)),
  )

func parseSchemaCommitment*(v: CborValue): Result[Digest, string] =
  ## The root of a `logos.schema_commitment`; any other model, profile or suite
  ## identifier is unknown in this revision.
  if v.isNil or v.kind != ckMap or v.entries.len != 4:
    return err("a schema commitment is a map of four fields")
  for (key, want) in [
    ("commitment_model", CommitmentModelId),
    ("hash_profile", HashProfileId),
    ("hash_suite", HashSuiteId),
  ]:
    let x = v.lookup(key)
    if x.isNone or x.get.getText != Opt.some(want):
      return err("unknown or missing " & key)
  let root = v.lookup("schema_root")
  if root.isNone:
    return err("missing schema_root")
  let d = toDigest(root.get).valueOr:
    return err("schema_root is not 32 bytes")
  ok(d)

# logos.schema_response -------------------------------------------------------------

func supportingEntry*(c: Contract): CborValue =
  ## A supporting-schema entry: its commitment, document and namespace (the
  ## shape of `logos.schema_response` entries and of INTERFACE §2.6
  ## `provider-supporting-schema`).
  cborMap(
    (cbor("commitment"), schemaCommitment(c.root)),
    (cbor("document"), cbor(c.source)),
    (cbor("namespace"), cbor(c.model.namespace)),
  )

func byNamespace(cs: seq[Contract]): seq[Contract] =
  var sorted = cs
  sorted.sort(
    proc(a, b: Contract): int =
      let byName = cmp(a.model.namespace, b.model.namespace)
      if byName != 0:
        byName
      else:
        cmpBytes(a.root, b.root)
  )
  sorted

func schemaResponse*(s: ContractSet, selected: Digest): Result[CborValue, string] =
  ## [SPEC INTERFACE §5.1] The `logos.schema_response` of a route that selects
  ## the contract `selected` of this set: the primary concrete contract with
  ## exactly its interfaces and the supporting schemas validated for the set, or
  ## one implemented interface with all and only the supporting schemas it uses
  ## (never the primary schema, another interface, or a supporting schema only
  ## they need).
  var v: CborValue
  if selected == s.primary.root:
    v = cborMap(
      (
        cbor("interface_schemas"),
        cborArray(byNamespace(s.interfaces).mapIt(supportingEntry(it))),
      ),
      (cbor("schema"), cbor(s.primary.source)),
      (cbor("supporting_schemas"), cborArray(s.supporting.mapIt(supportingEntry(it)))),
    )
  else:
    var found = false
    for c in s.interfaces:
      if c.root == selected:
        found = true
        v = cborMap(
          (cbor("interface_schemas"), cborArray()),
          (cbor("schema"), cbor(c.source)),
          (
            cbor("supporting_schemas"),
            cborArray(s.supportingOf(c).mapIt(supportingEntry(it))),
          ),
        )
    if not found:
      return err("the set has no contract with the selected root")
  if encodeCbor(v).len > MaxSchemaResponseBytes:
    # [SPEC INTERFACE §5.1] Such a contract cannot be exposed through a route.
    return err("the schema response is larger than 8 MiB")
  ok(v)

func entries(v: CborValue, key: string): Result[seq[Contract], string] =
  ## The (namespace, root, document) of each entry; their documents are accepted
  ## later, with the whole set.
  var cs: seq[Contract]
  for e in v.lookup(key).get.items:
    let root = ?parseSchemaCommitment(e.lookup("commitment").get)
    cs.add(
      Contract(
        source: e.lookup("document").get.text,
        model: SchemaModel(namespace: e.lookup("namespace").get.text),
        root: root,
      )
    )
  for i in 1 ..< cs.len:
    let byName = cmp(cs[i - 1].model.namespace, cs[i].model.namespace)
    if byName > 0 or (byName == 0 and cmpBytes(cs[i - 1].root, cs[i].root) >= 0):
      return err(key & " entries are not in ascending namespace, root order")
    if byName == 0:
      return err(key & " has two entries with namespace " & cs[i].model.namespace)
  ok(cs)

func matches(claimed, built: seq[Contract], what: string): Result[void, string] =
  ## Entries are in namespace order; each names its document's derived
  ## namespace and recomputed root.
  if claimed.len != built.len:
    return err(what & " entries do not match the documents the contract uses")
  for i, c in claimed:
    if c.model.namespace != built[i].model.namespace:
      return err(
        what & " entry " & c.model.namespace & " names a document with namespace " &
          built[i].model.namespace
      )
    if c.root != built[i].root:
      return err(what & " entry " & c.model.namespace & " has the wrong commitment")
  ok()

proc acceptSchemaResponse*(
    data: openArray[byte], opts = AcceptOptions()
): Result[ContractSet, string] =
  ## [SPEC INTERFACE §5.1, §5.3] Validates an encoded `logos.schema_response`
  ## and returns the set its documents reconstruct, whose primary contract is
  ## the selected one.
  if data.len == 0 or data.len > MaxSchemaResponseBytes:
    return err("a schema response is 1 byte to 8 MiB")
  let v = decodeCbor(data).valueOr:
    return err("not Logos deterministic CBOR: " & $error)
  let ctx = pinnedContext()
  let decl = ctx.commonModel.find("logos.schema_response")
  if decl.isNone or not schemaSet(ctx.commonModel).validates(0, decl.get.body, v):
    return err("not a logos.schema_response value")
  let
    ifaces = ?entries(v, "interface_schemas")
    supp = ?entries(v, "supporting_schemas")
    set = ?acceptContractSet(
      v.lookup("schema").get.text, ifaces.mapIt(it.source), supp.mapIt(it.source), opts
    )
  ?matches(ifaces, byNamespace(set.interfaces), "interface_schemas")
  ?matches(supp, set.supporting, "supporting_schemas")
  ok(set)

proc acceptSchemaResponse*(
    data: openArray[byte], expected: Digest, opts = AcceptOptions()
): Result[ContractSet, string] =
  ## [SPEC INTERFACE §5.1, §5.3; RUNTIME materialize_route] Validates the
  ## encoded `logos.schema_response` of a route expected to select the contract
  ## `expected`, and returns the reconstructed set.
  let set = ?acceptSchemaResponse(data, opts)
  if set.primary.root != expected:
    return err("the documents reconstruct another contract than the expected root")
  ok(set)
