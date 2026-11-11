## INTERFACE §2.6: the provider call-surface descriptor, encoded from an
## accepted binding and validated as an ABI caller must.

import std/[algorithm, sequtils, strutils]
import unittest2
import ../src/logos_core/hash
import ../src/logos_core/iface/[provider, surface]
import ../src/logos_core/base/hex
import ./support/specdata

# Documents ---------------------------------------------------------------------------

const
  unitsDoc = "units.count = uint64\n"
  tagsDoc = "tags.label = tstr\n"
  alphaDoc =
    "_interface = \"alpha\"\n\nalpha.get_request = {}\nalpha.get_response = {\n  n: units.count,\n}\n"
  betaDoc =
    "_interface = \"beta\"\n\nbeta.tag_request = {\n  label: tags.label,\n}\n" &
    "beta.tag_response = {\n  n: units.count,\n}\n"
  ticksDoc = "_interface = \"ticks\"\nticks.tick_event = { n: uint64 }\n"

proc rootOf(doc: string, supp: openArray[string] = []): Digest =
  let r = acceptContractSet(doc, [], supp)
  if r.isErr:
    checkpoint r.error
  r.get.primary.root

proc implementing(roots: varargs[Digest]): string =
  var rs = @roots
  rs.sort(
    proc(a, b: Digest): int =
      cmpBytes(a, b)
  )
  "_implements = [" & rs.mapIt("h'" & toHex(it) & "'").join(", ") & "]\n"

let
  alphaRoot = rootOf(alphaDoc, [unitsDoc])
  betaRoot = rootOf(betaDoc, [unitsDoc, tagsDoc])
  moduleDoc =
    "_module = \"demo_module\"\n" & implementing(alphaRoot, betaRoot) &
    "\ndemo.ping_request = {}\ndemo.ping_response = {\n  label: tags.label,\n}\n"

proc bound(
    module: string,
    primary: Opt[string],
    ifaces: openArray[string] = [],
    supp: openArray[string] = [],
): ModuleBinding =
  let r = acceptBinding(module, primary, ifaces, supp)
  if r.isErr:
    checkpoint r.error
  r.get

proc full(): ModuleBinding =
  bound("demo_module", Opt.some(moduleDoc), [betaDoc, alphaDoc], [unitsDoc, tagsDoc])

proc descriptor(b: ModuleBinding): seq[byte] =
  let r = callSurfaceDescriptor(b)
  if r.isErr:
    checkpoint r.error
  r.get

proc decoded(b: ModuleBinding): CborValue =
  decodeCbor(descriptor(b)).get

proc rejected(v: CborValue, module = "demo_module"): string =
  ## The validation error for the descriptor `v`; "" when it is accepted.
  let r = acceptCallSurfaceDescriptor(encodeCbor(v), module)
  if r.isOk: "" else: r.error

proc put(m: CborValue, key: string, value: CborValue) =
  for e in m.entries.mitems:
    if e.key.getText == Opt.some(key):
      e.value = value
      return
  m.entries.add((cbor(key), value))

proc drop(m: CborValue, key: string) =
  m.entries.keepItIf(it.key.getText != Opt.some(key))

proc supportingEntryOf(doc: string): CborValue =
  supportingEntry(acceptContractSet(doc).get.primary)

proc entryOf(doc: string, root: Digest, supp: openArray[string]): CborValue =
  cborMap(
    (cbor("commitment"), schemaCommitment(root)),
    (cbor("document"), cbor(doc)),
    (cbor("supporting_schemas"), cborArray(supp.mapIt(supportingEntryOf(it)))),
  )

# The mirror --------------------------------------------------------------------------

suite "ifc.call-surface: the provider call-surface descriptor (INTERFACE §2.6)":
  test "[IFC-0226] [IFC-0227] [IFC-0228] the descriptor maps, keys and limits are the mirrored CDDL's":
    let src = mirror("IFC/2.6.call-surface.cddl")
    # A plain line scan, not std/re: PCRE is loaded at run time and Android has none.
    var rules: seq[(string, seq[string], seq[string])] # name, keys, optional keys
    var inRule = false
    for line in src.splitLines:
      if line.endsWith(" = {"):
        rules.add (line[0 ..^ 5], newSeq[string](), newSeq[string]())
        inRule = true
      elif line == "}":
        inRule = false
      elif inRule:
        var field = line.strip
        let optional = field.startsWith("?")
        if optional:
          field = field[1 ..^ 1].strip
        let colon = field.find(':')
        if colon > 0:
          if optional:
            rules[^1][2].add field[0 ..< colon]
          else:
            rules[^1][1].add field[0 ..< colon]
    check rules.len == 3
    check rules[0] == ("provider-call-surface", @["interfaces"], @["primary"])
    check DescriptorKeys.toSeq.filterIt(it != "primary") == rules[0][1]
    check rules[1][0] == "provider-contract-schema"
    check rules[1][1] == ContractEntryKeys.toSeq
    check rules[2][0] == "provider-supporting-schema"
    check rules[2][1] == SupportingEntryKeys.toSeq
    check ".size (1.." & $MaxDocumentBytes & ")" in src
    check "namespace: tstr .size (1.." & $MaxSupportingNamespaceBytes & ")" in src

  test "[IFC-0229] [IFC-0231] [IFC-0244] [IFC-0673] [IFC-0240] [IFC-0674] a binding's descriptor round-trips":
    let b = full()
    let bytes = descriptor(b)
    let back = acceptCallSurfaceDescriptor(bytes, "demo_module")
    check back.isOk
    check back.get.primary.get.root == b.primary.get.root
    check back.get.interfaces.mapIt(it.root) == b.interfaces.mapIt(it.root)
    check back.get.supporting.mapIt(it.root) == b.supporting.mapIt(it.root)
    check encodeCbor(decodeCbor(bytes).get) == bytes
    let v = decodeCbor(bytes).get
    let ifaces = v.lookup("interfaces").get.items
    check ifaces.mapIt(it.lookup("document").get.text) == @[alphaDoc, betaDoc]
    proc names(e: CborValue): seq[string] =
      e.lookup("supporting_schemas").get.items.mapIt(it.lookup("namespace").get.text)

    check names(v.lookup("primary").get) == @["tags", "units"]
    check names(ifaces[0]) == @["units"]
    check names(ifaces[1]) == @["tags", "units"]
    check v.lookup("primary").get.lookup("commitment").get ==
      schemaCommitment(b.primary.get.root)

  test "[IFC-0231] an interfaces-only descriptor; a binding with neither has none":
    let b = bound("ticks_module", Opt.none(string), [ticksDoc])
    check acceptCallSurfaceDescriptor(descriptor(b), "ticks_module").isOk
    check decoded(b).lookup("primary").isNone
    let bare = bound("bare_module", Opt.none(string))
    check callSurfaceDescriptor(bare).isErr
    check rejected(cborMap((cbor("interfaces"), cborArray()))).len > 0

  test "isProvider: a method or event in the primary contract or an interface":
    check full().isProvider
    check bound("ticks_module", Opt.none(string), [ticksDoc]).isProvider
    check not bound(
      "types_module", Opt.some("_module = \"types_module\"\ndemo.t = uint64\n")
    ).isProvider
    check not bound("bare_module", Opt.none(string)).isProvider

  test "[IFC-0229] [IFC-0230] size, count and encoding limits":
    check acceptCallSurfaceDescriptor(newSeq[byte](), "demo_module").isErr
    check acceptCallSurfaceDescriptor(
      newSeq[byte](MaxDescriptorBytes + 1), "demo_module"
    ).error
      .contains("8,388,608")
    var bytes = descriptor(full())
    bytes.add 0x00
    check acceptCallSurfaceDescriptor(bytes, "demo_module").error.contains(
      "deterministic"
    )
    let v = decoded(full())
    let one = v.lookup("interfaces").get.items[0]
    v.put("interfaces", cborArray(newSeqWith(MaxDescriptorInterfaces + 1, one)))
    check rejected(v).contains("256")

  test "[IFC-0227] [IFC-0228] closed maps and field types":
    var v = decoded(full())
    v.put("extra", cbor(1'u64))
    check rejected(v).contains("unknown key")
    v = decoded(full())
    v.drop("interfaces")
    check rejected(v).contains("lacks interfaces")
    v = decoded(full())
    v.lookup("primary").get.put("note", cbor("x"))
    check rejected(v).contains("unknown key")
    v = decoded(full())
    v.lookup("interfaces").get.items[0].put("document", cbor(""))
    check rejected(v).contains("1 to")
    v = decoded(full())
    v.lookup("primary").get.lookup("supporting_schemas").get.items[0].put(
      "namespace", cbor('n'.repeat(MaxSupportingNamespaceBytes + 1))
    )
    check rejected(v).contains("1 to 128")

  test "[IFC-0245] an unknown profile identifier":
    let v = decoded(full())
    v.lookup("primary").get.lookup("commitment").get.put(
      "hash_profile", cbor("logos.hash-profile.2099-01")
    )
    check rejected(v).contains("hash_profile")

  test "[IFC-0244] [IFC-0245] [IFC-0242] a root mismatch in any entry":
    let wrong = schemaCommitment(rootOf(tagsDoc))
    var v = decoded(full())
    v.lookup("primary").get.put("commitment", wrong)
    check rejected(v).contains("wrong commitment")
    v = decoded(full())
    v.lookup("interfaces").get.items[1].put("commitment", wrong)
    check rejected(v).contains("wrong commitment")
    # The same wrong supporting root everywhere the namespace occurs.
    v = decoded(full())
    let other = schemaCommitment(alphaRoot)
    for e in @[v.lookup("primary").get] & v.lookup("interfaces").get.items:
      for s in e.lookup("supporting_schemas").get.items:
        if s.lookup("namespace").get.text == "units":
          s.put("commitment", other)
    check rejected(v).contains("wrong commitment")

  test "[IFC-0242] a supporting namespace that is not its document's":
    let v = decoded(full())
    for e in @[v.lookup("primary").get] & v.lookup("interfaces").get.items:
      for s in e.lookup("supporting_schemas").get.items:
        if s.lookup("namespace").get.text == "units":
          s.put("namespace", cbor("unitz"))
    check rejected(v).contains("namespace")

  test "[IFC-0245] duplicate contract identity and duplicate interface namespace":
    var v = decoded(full())
    let items = v.lookup("interfaces").get.items
    v.put("interfaces", cborArray(@[items[0], items[0], items[1]]))
    check rejected(v).len > 0
    let alpha2 =
      "_interface = \"alpha\"\n\nalpha.put_request = {}\nalpha.put_response = {}\n"
    let mod2 =
      "_module = \"demo_module\"\n" & implementing(alphaRoot, rootOf(alpha2)) &
      "\ndemo.ping_request = {}\ndemo.ping_response = {}\n"
    v = cborMap(
      (cbor("primary"), entryOf(mod2, Digest.default, [unitsDoc])),
      (
        cbor("interfaces"),
        cborArray(
          entryOf(alphaDoc, alphaRoot, [unitsDoc]), entryOf(alpha2, rootOf(alpha2), [])
        ),
      ),
    )
    check rejected(v).len > 0

  test "[IFC-0245] interfaces out of namespace order":
    let v = decoded(full())
    let items = v.lookup("interfaces").get.items
    v.put("interfaces", cborArray(@[items[1], items[0]]))
    check rejected(v).contains("order")

  test "[IFC-0245] [IFC-0240] [IFC-0673] a missing or unused supporting schema":
    var v = decoded(full())
    let beta = v.lookup("interfaces").get.items[1]
    beta.put(
      "supporting_schemas",
      cborArray(@[beta.lookup("supporting_schemas").get.items[0]]), # tags only
    )
    check rejected(v).contains("exactly the supporting schemas")
    v = decoded(full())
    let alpha = v.lookup("interfaces").get.items[0]
    alpha.put(
      "supporting_schemas",
      cborArray(supportingEntryOf(tagsDoc), supportingEntryOf(unitsDoc)),
    )
    check rejected(v).contains("exactly the supporting schemas")
    v = decoded(full())
    let prim = v.lookup("primary").get
    prim.put(
      "supporting_schemas",
      cborArray(
        supportingEntryOf("extra.x = uint64\n"),
        supportingEntryOf(tagsDoc),
        supportingEntryOf(unitsDoc),
      ),
    )
    check rejected(v).contains("unused")

  test "[IFC-0243] supporting entries in namespace order, each once":
    var v = decoded(full())
    let prim = v.lookup("primary").get
    let s = prim.lookup("supporting_schemas").get.items
    prim.put("supporting_schemas", cborArray(@[s[1], s[0]]))
    check rejected(v).contains("ascending")
    v = decoded(full())
    let p2 = v.lookup("primary").get
    let s2 = p2.lookup("supporting_schemas").get.items
    p2.put("supporting_schemas", cborArray(@[s2[0], s2[0], s2[1]]))
    check rejected(v).len > 0

  test "[IFC-0674] [IFC-0241] one namespace, one document across entries":
    let v = decoded(full())
    let alpha = v.lookup("interfaces").get.items[0]
    let other = "units.count = uint32\n"
    alpha.put("supporting_schemas", cborArray(supportingEntryOf(other)))
    check rejected(v).contains("disagree")
    # A supporting entry whose document is an interface.
    let w =
      cborMap((cbor("interfaces"), cborArray(entryOf(alphaDoc, alphaRoot, [ticksDoc]))))
    check rejected(w, "a_module").contains("supporting schema has role interface")

  test "[IFC-0235] [IFC-0245] the primary is a concrete module named by _MODULE_name":
    check rejected(decoded(full()), module = "other_module").contains("other_module")
    let v = decoded(full())
    v.put("primary", entryOf(ticksDoc, rootOf(ticksDoc), []))
    check rejected(v).len > 0

  test "[IFC-0236] [IFC-0237] [IFC-0238] [IFC-0245] interface entries are interfaces, named by their namespace, implementing nothing":
    let modOnly =
      "_module = \"m2_module\"\nm2.ping_request = {}\nm2.ping_response = {}\n"
    var v =
      cborMap((cbor("interfaces"), cborArray(entryOf(modOnly, rootOf(modOnly), []))))
    check rejected(v, "m2_module").len > 0
    let misnamed =
      "_interface = \"gamma\"\n\ndelta.get_request = {}\ndelta.get_response = {}\n"
    v = cborMap((cbor("interfaces"), cborArray(entryOf(misnamed, Digest.default, []))))
    check rejected(v, "g_module").len > 0
    let implementingIface =
      "_interface = \"gamma\"\n" & implementing(alphaRoot) &
      "\ngamma.get_request = {}\ngamma.get_response = {}\n"
    v = cborMap(
      (cbor("interfaces"), cborArray(entryOf(implementingIface, Digest.default, [])))
    )
    check rejected(v, "g_module").len > 0

  test "[IFC-0245] a reserved common-schema bare method name; a bare name used twice":
    let reserved =
      "_interface = \"gamma\"\n\ngamma.schema_request = {}\ngamma.schema_response = {}\n"
    var v =
      cborMap((cbor("interfaces"), cborArray(entryOf(reserved, Digest.default, []))))
    check rejected(v, "g_module").contains("well-known method name schema")
    let gamma =
      "_interface = \"gamma\"\n\ngamma.get_request = {}\ngamma.get_response = {}\n"
    v = cborMap(
      (
        cbor("interfaces"),
        cborArray(
          entryOf(alphaDoc, alphaRoot, [unitsDoc]), entryOf(gamma, rootOf(gamma), [])
        ),
      )
    )
    check rejected(v, "g_module").contains("bare name")

  test "[IFC-0246] supplied contract references match the descriptor exactly":
    let b = full()
    let p = Opt.some(b.primary.get.root)
    check b.matchesContracts(p, [betaRoot, alphaRoot])
    check b.matchesContracts(p, [alphaRoot, betaRoot])
    check not b.matchesContracts(p, [alphaRoot])
    check not b.matchesContracts(Opt.none(Digest), [alphaRoot, betaRoot])
    check not b.matchesContracts(p, [alphaRoot, betaRoot, rootOf(ticksDoc)])
    let t = bound("ticks_module", Opt.none(string), [ticksDoc])
    check t.matchesContracts(Opt.none(Digest), [rootOf(ticksDoc)])
    check not t.matchesContracts(Opt.some(rootOf(ticksDoc)), [rootOf(ticksDoc)])
