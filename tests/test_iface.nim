## INTERFACE §1 schema acceptance and §5.3 dynamic schema validation.

import std/[algorithm, re, sequtils, strutils]
import unittest2
import ../src/logos_core/[cbor, hash, commitment]
import ../src/logos_core/iface/accept
import ../src/logos_core/base/hex
import ./support/specdata

proc accepted(
    primary: string,
    ifaces: openArray[string] = [],
    supp: openArray[string] = [],
    opts = AcceptOptions(),
): ContractSet =
  let r = acceptContractSet(primary, ifaces, supp, opts)
  if r.isErr:
    checkpoint r.error
  r.get

proc rejection(
    primary: string,
    ifaces: openArray[string] = [],
    supp: openArray[string] = [],
    opts = AcceptOptions(),
): string =
  let r = acceptContractSet(primary, ifaces, supp, opts)
  doAssert r.isErr, "accepted:\n" & primary
  r.error

proc module(body: string, name = "demo_module"): string =
  "_module = \"" & name & "\"\n" & body

proc iface(ns, body: string): string =
  "_interface = \"" & ns & "\"\n" & body

proc implementing(roots: varargs[Digest]): string =
  var rs = @roots
  rs.sort(
    proc(a, b: Digest): int =
      cmpBytes(a, b)
  )
  "_implements = [" & rs.mapIt("h'" & toHex(it) & "'").join(", ") & "]\n"

proc rootOf(source: string): Digest =
  accepted(source).primary.root

const ping = "demo.ping_request = {}\ndemo.ping_response = {}\n"

let
  ifc392 = mirror("IFC/3.9.2.interface.cddl")
  mod392 = mirror("IFC/3.9.2.module.cddl")
  sup392 = mirror("IFC/3.9.2.supporting.cddl")

suite "iface: schema files and metadata (INTERFACE §1.1, §1.2)":
  test "[IFC-0018] [IFC-0097] [IFC-0098] [IFC-0099] [IFC-0100] [IFC-0101] [IFC-0102] [IFC-0103] [IFC-0104] [IFC-0105] [IFC-0106] [IFC-0107] [IFC-0108] [IFC-0109] [IFC-0110] [IFC-0111] [IFC-0112] [IFC-0113] the §1.8 storage module is one complete document":
    let s = accepted(mirror("IFC/1.8.module.cddl"))
    let m = s.primary.model
    check m.role == srModule
    check m.moduleName == Opt.some("storage_module")
    check m.namespace == "storage"
    check m.methods.mapIt(it.name) ==
      @[
        "storage.destroy", "storage.exists", "storage.init", "storage.space",
        "storage.start", "storage.upload_url",
      ]
    check m.events.mapIt(it.name) ==
      @[
        "storage.started_event", "storage.upload_done_event",
        "storage.upload_progress_event",
      ]

  test "[IFC-0094] [IFC-0095] [IFC-0096] [IFC-0032] [IFC-0031] the §1.8 metrics_provider interface":
    let m = accepted(mirror("IFC/1.8.interface.cddl")).primary.model
    check m.role == srInterface
    check m.namespace == "metrics_provider"
    check m.methods.mapIt(it.name) == @["metrics_provider.snapshot"]
    check m.moduleName.isNone

  test "[IFC-0027] [IFC-0028] a module begins with its metadata block":
    let meta = mirror("IFC/1.2.module-metadata.cddl")
    check accepted(meta & "\n" & ping, opts = AcceptOptions()).primary.model.moduleName ==
      Opt.some("storage_module")
    check "metadata comes first" in rejection(ping & "_module = \"demo_module\"\n")
    check "metadata comes first" in
      rejection(
        "demo.ping_request = {}\n_interface = \"demo\"\ndemo.ping_response = {}\n"
      )

  test "[IFC-0031] [IFC-0032] an interface declares _interface naming its namespace":
    let meta = mirror("IFC/1.2.interface-metadata.cddl")
    let m = accepted(
      meta &
        "\nmetrics_provider.read_request = {}\nmetrics_provider.read_response = {}\n"
    ).primary.model
    check m.role == srInterface
    check "_interface does not name the namespace" in rejection(iface("other", ping))

  test "[IFC-0029] a document cannot declare both _module and _interface":
    check "both a module and an interface" in
      rejection("_module = \"demo_module\"\n_interface = \"demo\"\n" & ping)

  test "[IFC-0030] [IFC-0044] _implements only on concrete modules":
    let r = rootOf(ifc392)
    check "only a concrete module" in
      rejection(implementing(r) & "demo.counter = uint64\n", [ifc392])
    check "only a concrete module" in
      rejection(iface("demo", implementing(r) & ping), [ifc392])

  test "[IFC-0033] [IFC-0037] [IFC-0038] [IFC-0039] [IFC-0040] [IFC-0370] [IFC-0371] [IFC-0372] [IFC-0373] [IFC-0374] [IFC-0375] [IFC-0376] [IFC-0377] [IFC-0378] [IFC-0380] §3.9.2: _implements names the interface's recomputed root":
    let s = accepted(mod392, [ifc392], [sup392])
    let literal = mod392.findAll(re"h'([0-9a-f]{64})'")
    check literal.len == 1
    check toHex(rootOf(ifc392)) == literal[0][2 .. ^2]
    check s.primary.model.implemented == @[rootOf(ifc392)]
    check s.interfaces.mapIt(it.model.namespace) == @["metrics_provider"]
    check s.supporting.mapIt(it.model.namespace) == @["metrics_types"]

  test "[IFC-0034] [IFC-0035] [IFC-0036] [IFC-0042] _implements is a nonempty array of 32-byte root literals":
    let r = rootOf(ifc392)
    check "nonempty" in rejection(module("_implements = []\n" & ping), [ifc392])
    check "32-byte" in rejection(module("_implements = [h'00']\n" & ping), [ifc392])
    check "32-byte" in
      rejection(module("_implements = [\"metrics_provider\"]\n" & ping), [ifc392])
    check "32-byte" in
      rejection(module("_implements = [h'" & toHex(r) & "00']\n" & ping), [ifc392])
    check "nonempty" in
      rejection(module("_implements = h'" & toHex(r) & "'\n" & ping), [ifc392])
    discard accepted(module(implementing(r) & ping), [ifc392])

  test "[IFC-0038] [IFC-0039] roots in strictly ascending order, each naming one supplied interface":
    let
      a = iface("alpha", "alpha.one_request = {}\nalpha.one_response = {}\n")
      b = iface("beta", "beta.two_request = {}\nbeta.two_response = {}\n")
      ra = rootOf(a)
      rb = rootOf(b)
      (lo, hi) = (if cmpBytes(ra, rb) < 0: (ra, rb) else: (rb, ra))
      both = "_implements = [h'" & toHex(lo) & "', h'" & toHex(hi) & "']\n"
      swapped = "_implements = [h'" & toHex(hi) & "', h'" & toHex(lo) & "']\n"
      twice = "_implements = [h'" & toHex(lo) & "', h'" & toHex(lo) & "']\n"
    check accepted(module(both & ping), [a, b]).interfaces.len == 2
    check "ascending" in rejection(module(swapped & ping), [a, b])
    check "twice" in rejection(module(twice & ping), [a, b])
    check "names no supplied interface" in rejection(module(implementing(ra) & ping))

  test "[IFC-0040] an _implements root must name an interface document":
    let sup = "demo_types.count = uint64\n"
    check "has role supporting" in
      rejection(module(implementing(rootOf(sup)) & ping), [sup])

  test "[IFC-0022] [IFC-0023] the input set holds every required document and nothing unused":
    check "undefined name metrics_types.counter" in rejection(mod392, [ifc392])
    check "names no supplied interface" in rejection(mod392, [], [sup392])
    check "is not in _implements" in rejection(module(ping), [ifc392])
    check "is unused" in rejection(module(ping), [], [sup392])
    check "same schema root" in rejection(module(ping), [], [sup392, sup392]) or
      "two supporting schemas declare namespace" in
      rejection(module(ping), [], [sup392, sup392])
    let other = "metrics_types.counter = uint32\n"
    check "two supporting schemas declare namespace metrics_types" in
      rejection(mod392, [ifc392], [sup392, other])

  test "[IFC-0019] [IFC-0021] interfaces see the common schema and nothing else":
    let usesCommon = iface(
      "demo",
      "demo.ping_request = {}\ndemo.ping_response = { code: logos.error_code }\n",
    )
    discard accepted(usesCommon)
    let usesSupporting = iface(
      "demo",
      "demo.ping_request = {}\ndemo.ping_response = { n: metrics_types.counter }\n",
    )
    check "undefined name metrics_types.counter" in rejection(usesSupporting)
    check "undefined name metrics_types.counter" in
      rejection(usesSupporting, [], [sup392])
    check "uses no interface or supporting schema" in rejection(
      usesCommon, [], [sup392]
    )
    check "uses no interface or supporting schema" in rejection(usesCommon, [ifc392])

  test "[IFC-0020] [IFC-0021] supporting schemas see the common schema and nothing else":
    discard accepted("demo_types.c = logos.schema_commitment\n")
    check "undefined name metrics_types.counter" in
      rejection("demo_types.c = metrics_types.counter\n", [], [sup392])
    check "undefined name sensor.control.settings" in
      rejection(mod392, [ifc392], [sup392, "demo_types.s = sensor.control.settings\n"])

  test "[IFC-0024] include and import directives never alter resolution":
    # A directive written as a comment is a comment: it neither supplies a
    # dependency nor changes the document's root.
    let plain = "demo_types.c = uint64\n"
    let directive =
      ";# import metrics_types from metrics_types.cddl\n;# include common\n" & plain
    check rootOf(plain) == rootOf(directive)
    check "undefined name metrics_types.counter" in
      rejection(
        ";# import metrics_types.counter\ndemo_types.c = metrics_types.counter\n"
      )

  test "[IFC-0025] an external reference resolves to exactly one supplied declaration":
    let s = accepted(mod392, [ifc392], [sup392])
    let refs = s.primary.model.nodesOf.filterIt(it.kind == snImportedRef)
    check refs.len == 1
    check refs[0].imported.root == s.supporting[0].root
    check "undefined name demo_types.missing" in
      rejection(module("demo.t = demo_types.missing\n"))

suite "iface: prelude, names and reservations (INTERFACE §1.3)":
  test "[IFC-0048] the prelude names cannot be redefined":
    for alias in ["uint8", "uint64", "int8", "int64"]:
      check ("redefines the prelude name " & alias) in
        rejection(module(alias & " = uint .size 1\n" & ping))

  test "[IFC-0049] [IFC-0050] [IFC-0051] [IFC-0052] [IFC-0053] [IFC-0054] [IFC-0055] [IFC-0056] every prelude alias normalizes to its fixed-width primitive":
    let m = accepted(
      module(
        "demo.t = { a: uint8, b: uint16, c: uint32, d: uint64, e: int8, f: int16, g: int32, h: int64 }\n"
      )
    ).primary.model
    let fields = m.find("demo.t").get.body.fields
    check fields.mapIt($it.node.scalar) ==
      @["uint8", "uint16", "uint32", "uint64", "int8", "int16", "int32", "int64"]
    check fields.allIt(it.node.kind == snPrimitive)

  test "[IFC-0059] [IFC-0060] lowercase snake_case for types, methods, events and fields":
    for bad in [
      "demo.Thing = uint8\n", "demo.2thing = uint8\n", "demo.thing_ = uint8\n",
      "demo.th__ing = uint8\n", "demo.th-ing = uint8\n", "Demo.thing = uint8\n",
      "demo.Ping_request = {}\ndemo.Ping_response = {}\n", "demo.Tick_event = {}\n",
      "demo.t = { Field: uint8 }\n", "demo.t = { two__parts: uint8 }\n",
      "demo.t = { x: { Inner: uint8 } }\n", "demo.t = [* { bad_: uint8 }]\n",
    ]:
      let e = rejection(module(bad))
      check "snake_case" in e or "cdCDDLe" in e
    discard accepted(module("demo.thing2 = { a_1b: uint8 }\n"))

  test "[IFC-0059] [IFC-0060] the rules apply to each dot segment of a qualified name":
    discard accepted(module("sensor.control.thing = uint8\n"))
    check "snake_case" in rejection(module("sensor.Control.thing = uint8\n"))
    check "snake_case" in rejection(module("sensor_.control.thing = uint8\n"))

  test "[IFC-0061] the namespace holds at most 128 bytes":
    let ns128 = "n" & "a".repeat(127)
    let ns129 = "n" & "a".repeat(128)
    discard accepted(module(ns128 & ".t = uint8\n"))
    check "longer than 128 bytes" in rejection(module(ns129 & ".t = uint8\n"))
    let dotted = "a".repeat(60) & "." & "b".repeat(67)
    check dotted.len == 128
    discard accepted(module(dotted & ".t = uint8\n"))

  test "[IFC-0058] reserved logos names are only for Logos-defined contracts":
    for bad in ["logos.thing = uint8\n", "logos_thing.t = uint8\n"]:
      let e = rejection(module(bad))
      check "reserved" in e or "snake_case" in e
    check "reserved" in rejection(iface("logos.demo", "logos.demo.t = uint8\n"))
    discard accepted(
      iface("logos.demo", "logos.demo.t = uint8\n"), opts = AcceptOptions(system: true)
    )

  test "module names follow the RUNTIME §1.3 grammar":
    for bad in [
      "",
      "Demo",
      "1demo",
      "demo-module",
      "a_call_b",
      "a_publish_b",
      "logos_demo",
      "x".repeat(65),
    ]:
      check "module name" in rejection(module(ping, name = bad))
    discard accepted(module(ping, name = "x".repeat(64)))
    discard
      accepted(module(ping, name = "logos_demo"), opts = AcceptOptions(system: true))

  test "[IMPL-DECISION G69] module names ending in _call or _publish and the namespaces call and publish":
    check "(G69)" in rejection(module(ping, name = "demo_call"))
    check "(G69)" in rejection(module(ping, name = "demo_publish"))
    check "(G69)" in rejection(module("call.t = uint8\n"))
    check "(G69)" in rejection(module("publish.t = uint8\n"))

  test "[IFC-0062] field names do not begin with has_":
    check "begins with has_" in rejection(module("demo.t = { has_name: tstr }\n"))
    check "begins with has_" in
      rejection(
        module("demo.ping_request = { has_x: bool }\ndemo.ping_response = {}\n")
      )
    check "begins with has_" in rejection(module("demo.tick_event = { has_x: bool }\n"))
    check "begins with has_" in rejection(module("demo.t = { a: { has_x: bool } }\n"))
    discard accepted(module("demo.t = { hash: bstr, hasx: bool }\n"))

  test "[IFC-0063] field names do not end with _len, _count or _<digits>":
    for f in ["data_len", "item_count", "x_0", "pos_12"]:
      check "reserved suffix" in rejection(module("demo.t = { " & f & ": uint8 }\n"))
    discard accepted(
      module("demo.t = { len: uint8, count: uint8, x0: uint8, a_b1: uint8 }\n")
    )

  test "[IFC-0064] [IFC-0065] field names are not C17 keywords or <stdbool.h> names":
    for f in C17Keywords:
      check "C17 keyword" in rejection(module("demo.t = { " & f & ": uint8 }\n"))
    for f in StdboolNames:
      check "<stdbool.h>" in rejection(module("demo.t = { " & f & ": uint8 }\n"))
    check C17Keywords.len == 34

  test "[IFC-0066] supporting schemas declare no callable suffixes":
    for n in ["ping_request", "ping_response", "tick_event"]:
      check "callable suffix" in rejection("demo_types." & n & " = { a: uint8 }\n")

suite "iface: methods, events and types (INTERFACE §1.4-§1.7)":
  test "[IFC-0075] [IFC-0076] the exists method pair":
    let m = accepted(module(mirror("IFC/1.4.exists.cddl"))).primary.model
    check m.methods.mapIt(it.name) == @["storage.exists"]
    check m.find("storage.exists").get.request == "storage.exists_request"

  test "[IFC-0068] request and response bodies are map-valued":
    check "must be a map or a choice of maps" in
      rejection(module("demo.ping_request = uint8\ndemo.ping_response = {}\n"))
    check "must be a map or a choice of maps" in
      rejection(module("demo.ping_request = {}\ndemo.ping_response = [* uint8]\n"))
    check "must be a map or a choice of maps" in
      rejection(
        module("demo.ping_request = { a: \"x\" } / uint8\ndemo.ping_response = {}\n")
      )
    discard accepted(module(mirror("IFC/2.4.resolve.cddl")))

  test "[IFC-0069] a bare method name holds at most 128 bytes":
    let ok = "m" & "e".repeat(127)
    let long = "m" & "e".repeat(128)
    discard
      accepted(module("demo." & ok & "_request = {}\ndemo." & ok & "_response = {}\n"))
    check "longer than 128 bytes" in
      rejection(
        module("demo." & long & "_request = {}\ndemo." & long & "_response = {}\n")
      )

  test "[IFC-0070] [IFC-0447] the well-known method name schema is reserved":
    check pinnedContext().wellKnownMethods == @["schema"]
    check "well-known method name schema" in
      rejection(module("demo.schema_request = {}\ndemo.schema_response = {}\n"))
    check "well-known method name schema" in
      rejection(iface("demo", "demo.schema_request = {}\ndemo.schema_response = {}\n"))

  test "[IFC-0072] every local declaration carries the namespace":
    check "share no namespace" in rejection(module("demo.a = uint8\nother.b = uint8\n"))

  test "[IFC-0073] a local reference uses the qualified name":
    check "undefined name a" in rejection(module("demo.a = uint8\ndemo.b = { x: a }\n"))
    discard accepted(module("demo.a = uint8\ndemo.b = { x: demo.a }\n"))

  test "[IFC-0074] exposed bare method names are unique across implemented contracts":
    let mp = rootOf(ifc392)
    check "two exposed methods have the bare name snapshot" in
      rejection(
        module(
          implementing(mp) & "demo.snapshot_request = {}\ndemo.snapshot_response = {}\n"
        ),
        [ifc392],
      )
    let
      a = iface("alpha", "alpha.ping_request = {}\nalpha.ping_response = {}\n")
      b = iface("beta", "beta.ping_request = {}\nbeta.ping_response = {}\n")
    check "two exposed methods have the bare name ping" in
      rejection(module(implementing(rootOf(a), rootOf(b)) & "demo.t = uint8\n"), [a, b])

  test "[IFC-0079] map keys are bare identifiers":
    check "map keys must be barewords" in
      rejection(module("demo.t = { \"a\": uint8 }\n"))

  test "[IFC-0081] [IFC-0082] [IFC-0083] [IFC-0084] events are map-valued, at most 128 bytes":
    let m = accepted(module(mirror("IFC/1.5.events.cddl"))).primary.model
    check m.events.mapIt(it.name) ==
      @["storage.upload_done_event", "storage.upload_progress_event"]
    check "must be a map or a choice of maps" in
      rejection(module("demo.tick_event = uint8\n"))
    discard accepted(module("demo.a_event = { kind: \"a\" } / { kind: \"b\" }\n"))
    let id128 = "demo." & "e".repeat(117) & "_event"
    check id128.len == 128
    discard accepted(module(id128 & " = {}\n"))
    check "longer than 128 bytes" in
      rejection(module("demo." & "e".repeat(118) & "_event = {}\n"))

  test "[IFC-0087] [IFC-0088] named types":
    let m = accepted(module(mirror("IFC/1.6.types.cddl"))).primary.model
    check m.declarations.mapIt(it.name) == @["storage.peer_info", "storage.space_info"]
    let peer = m.find("storage.peer_info").get.body
    check peer.fields.mapIt((it.name, it.optional)) ==
      @[("addrs", false), ("id", false), ("name", true)]

  test "[IFC-0090] [IFC-0091] [IFC-0092] only the allowed types":
    for bad in [
      "demo.t = uint\n", "demo.t = int\n", "demo.t = nint\n", "demo.t = any\n",
      "demo.t = float32\n", "demo.t = float64\n", "demo.t = float16\n",
      "demo.t = { * tstr => uint8 }\n", "demo.t = #6.1(uint8)\n",
      "demo.t = tstr .regexp \"a\"\n", "demo.t = bstr .cbor uint8\n",
      "demo.t = uint .bits demo.f\n", "demo.t = 1..5\n", "demo.t = h'00'\n",
      "demo.t = { ? a: uint8, * b: uint8 }\n", "demo.t = [? uint8]\n",
    ]:
      discard rejection(module(bad))
    discard accepted(
      module(
        "demo.t = { a: bool, b: tstr, c: bstr, d: tstr .size 4, e: bstr .size (1..9), " &
          "f: [* uint8], g: [uint8, tstr], ? h: \"lit\", i: 7, j: -3, k: true, " &
          "l: uint8 / tstr }\n"
      )
    )

  test "[IFC-0144] every choice admits a structural selection plan":
    # Arms the plan cannot tell apart, at the top level and nested.
    for bad in [
      "demo.t = uint8 / uint16\n", "demo.t = { a: uint8 } / { a: uint16 }\n",
      "demo.t = { a: tstr / tstr .size 2 }\n", "demo.t = [* (uint8 / int8)]\n",
    ]:
      checkpoint bad
      check "selection plan" in rejection(module(bad))
    discard accepted(module("demo.t = uint8 / tstr\ndemo.u = { a: 1 } / { a: 2 }\n"))

  test "a tstr schema type excludes U+0000":
    let s = accepted(module("demo.t = { a: tstr }\n"))
    let set = s.schemaSet
    let d = s.primary.model.find("demo.t").get
    check set.validates(0, d.body, cborMap((cbor("a"), cbor("ok"))))
    check not set.validates(0, d.body, cborMap((cbor("a"), cbor("a\0b"))))

suite "iface: dynamic schema limits (INTERFACE §5.3)":
  test "[IFC-0526] [IFC-0527] [IFC-0531] one document holds at most 1 MiB":
    let base = module("demo.t = uint8\n")
    let pad = "; " & "x".repeat(1_048_576 - base.len - 3) & "\n"
    check (pad & base).len == MaxDocumentBytes
    discard accepted(pad & base)
    check "larger than 1 MiB" in rejection(";" & pad & base)

  test "[IFC-0528] [IFC-0531] one input set holds at most 8 MiB":
    var supp: seq[string]
    var refs: seq[string]
    for i in 0 ..< 8:
      let ns = "types" & $char(ord('a') + i)
      let body = ns & ".t = uint8\n"
      supp.add("; " & "x".repeat(1_048_000 - body.len - 3) & "\n" & body)
      refs.add("f" & $char(ord('a') + i) & ": " & ns & ".t")
    let primary = module("demo.t = { " & refs.join(", ") & " }\n")
    discard accepted(primary, [], supp)
    let extra =
      "; " & "x".repeat(8_388_608 - supp.mapIt(it.len).foldl(a + b) - primary.len) & "\n"
    check "larger than 8 MiB" in rejection(extra & primary, [], supp)

  test "[IFC-0529] [IFC-0531] at most 65,536 schema nodes":
    # Each `[* uint8]` field is two nodes (the list and its element); a map is one.
    proc wide(n: int): string =
      var fields: seq[string]
      for i in 0 ..< n:
        fields.add("f" & $i & "x: [* uint8]")
      module("demo.t = { " & fields.join(", ") & " }\n")

    check accepted(wide(32767)).primary.model.nodesOf.len == 65535
    check "more than 65,536" in rejection(wide(32768))

  test "[IFC-0530] [IFC-0531] at most 128 levels of structural nesting":
    proc nested(n: int): string =
      module("demo.t = " & "[* ".repeat(n) & "uint8" & "]".repeat(n) & "\n")

    check accepted(nested(128)).primary.model.nestingOf == 128
    check "deeper than 128 levels" in rejection(nested(129))

  test "[IFC-0532] [IMPL-DECISION G153] cyclic references and deep input are bounded":
    check "form a cycle (G153)" in
      rejection(module("demo.a = demo.b\ndemo.b = demo.a\n"))
    check "form a cycle (G153)" in rejection(module("demo.a = demo.a\n"))
    check "form a cycle (G153)" in
      rejection(module("demo.a = demo.b\ndemo.b = demo.c\ndemo.c = demo.b\n"))
    check "cdCDDLe" in rejection(module("demo.t = " & "[".repeat(5000) & "\n"))
    discard accepted(module("demo.n = { ? next: demo.n }\n"))

  test "[IFC-0533] [IFC-0534] [IFC-0535] resolution uses only the supplied documents":
    # A reference that names a file, package or URL is just an unresolved name.
    for name in ["storage_types.thing", "https.example", "file.cddl"]:
      check ("undefined name " & name) in rejection(module("demo.t = " & name & "\n"))
    check "cdCDDLe" in rejection(module("demo.t = { a uint8 }\n"))

# Call surfaces and logos.schema ------------------------------------------------------

import ../src/logos_core/iface/surface

proc encoded(v: CborValue): seq[byte] =
  encodeCbor(v)

proc entryOf(ns: string, root: Digest, doc: string): CborValue =
  cborMap(
    (cbor("namespace"), cbor(ns)),
    (cbor("commitment"), schemaCommitment(root)),
    (cbor("document"), cbor(doc)),
  )

proc response(schema: string, ifaces, supp: seq[CborValue]): seq[byte] =
  encoded(
    cborMap(
      (cbor("schema"), cbor(schema)),
      (cbor("interface_schemas"), cborArray(ifaces)),
      (cbor("supporting_schemas"), cborArray(supp)),
    )
  )

proc commonDecl(name: string): SchemaNode =
  pinnedContext().commonModel.find(name).get.body

proc commonValidates(name: string, v: CborValue): bool =
  schemaSet(pinnedContext().commonModel).validates(0, commonDecl(name), v)

suite "iface: call surfaces (INTERFACE §1.4, §1.5, §2.1)":
  test "[IFC-0074] [IFC-0084] the §1.8 storage surface: bare method names and event identifiers":
    let s = accepted(mirror("IFC/1.8.module.cddl"))
    let c = s.callSurface
    check c.methods.mapIt(it.bare) ==
      @["destroy", "exists", "init", "space", "start", "upload_url"]
    check c.events.mapIt(it.id) ==
      @[
        "storage.started_event", "storage.upload_done_event",
        "storage.upload_progress_event",
      ]
    let e = c.findMethod("exists").get
    check e.name == "storage.exists"
    check e.request == "storage.exists_request"
    check e.response == "storage.exists_response"
    check e.contract == s.primary.root
    check c.findMethod("storage.exists").isNone
    check c.findMethod("schema").isNone

  test "[IFC-0380] implemented interface methods keep their defining contract":
    let s = accepted(mod392, [ifc392], [sup392])
    let c = s.callSurface
    check c.methods.mapIt((it.bare, it.namespace)) ==
      @[("configure", "sensor.control"), ("snapshot", "metrics_provider")]
    check c.findMethod("snapshot").get.contract == rootOf(ifc392)
    check c.findMethod("configure").get.contract == s.primary.root
    check c.findMethod("snapshot").get.doc == 1
    check accepted(sup392).callSurface.methods.len == 0

suite "iface: schema commitments and logos.schema (INTERFACE §5.1)":
  test "[IFC-0444] logos.schema_commitment carries the pinned identifiers":
    let root = rootOf(ifc392)
    let v = schemaCommitment(root)
    check commonValidates("logos.schema_commitment", v)
    check parseSchemaCommitment(v) == Result[Digest, string].ok(root)
    check parseSchemaCommitment(decodeCbor(encoded(v)).get).get == root
    # The common schema's literals are the pins, field by field.
    let body = commonDecl("logos.schema_commitment")
    for f in body.fields:
      if f.node.kind == snLiteral:
        check v.lookup(f.name).get.getText == Opt.some(f.node.literal.text)
    for key in ["commitment_model", "hash_profile", "hash_suite"]:
      var bad = cborMap()
      for (k, x) in v.entries:
        bad.entries.add((k, (if k.text == key: cbor("logos.other") else: x)))
      check parseSchemaCommitment(bad).isErr
      check not commonValidates("logos.schema_commitment", bad)
    check parseSchemaCommitment(cborMap((cbor("schema_root"), cbor(root)))).isErr

  test "[IFC-0445] [IFC-0446] [IFC-0448] [IFC-0454] a primary-contract route's response reconstructs it":
    let s = accepted(mod392, [ifc392], [sup392])
    let v = s.schemaResponse(s.primary.root).get
    check commonValidates("logos.schema_response", v)
    check commonValidates("logos.schema_request", cborMap())
    check v.lookup("schema").get.text == mod392
    check v.lookup("interface_schemas").get.items.mapIt(it.lookup("document").get.text) ==
      @[ifc392]
    check v.lookup("supporting_schemas").get.items.mapIt(
      it.lookup("namespace").get.text
    ) == @["metrics_types"]
    let back = acceptSchemaResponse(encoded(v), s.primary.root).get
    check back.primary.root == s.primary.root
    check back.documents.mapIt(it.root) == s.documents.mapIt(it.root)
    check "another contract" in acceptSchemaResponse(encoded(v), rootOf(ifc392)).error

  test "[IFC-0449] [IFC-0450] [IFC-0458] [IFC-0459] an interface route exposes the interface alone":
    let s = accepted(mod392, [ifc392], [sup392])
    let ir = rootOf(ifc392)
    let v = s.schemaResponse(ir).get
    check v.lookup("schema").get.text == ifc392
    check v.lookup("interface_schemas").get.items.len == 0
    check v.lookup("supporting_schemas").get.items.len == 0
    check acceptSchemaResponse(encoded(v), ir).get.primary.root == ir
    check "no contract with the selected root" in s.schemaResponse(rootOf(sup392)).error
    # An interface route that also carries the primary's documents is invalid.
    let leaky =
      response(ifc392, @[], @[entryOf("metrics_types", rootOf(sup392), sup392)])
    check "uses no interface or supporting schema" in
      acceptSchemaResponse(leaky, ir).error

  test "[IFC-0451] [IFC-0452] entries name valid documents with their own namespace and root":
    let
      ir = rootOf(ifc392)
      sr = rootOf(sup392)
      s = accepted(mod392, [ifc392], [sup392])
      good = @[entryOf("metrics_provider", ir, ifc392)]
      supp = @[entryOf("metrics_types", sr, sup392)]
    check acceptSchemaResponse(response(mod392, good, supp), s.primary.root).isOk
    check "has role supporting" in
      acceptSchemaResponse(
        response(mod392, @[entryOf("metrics_types", sr, sup392)], supp), s.primary.root
      ).error
    check "names a document with namespace" in
      acceptSchemaResponse(
        response(mod392, @[entryOf("metrics_providers", ir, ifc392)], supp),
        s.primary.root,
      ).error
    check "wrong commitment" in
      acceptSchemaResponse(
        response(mod392, @[entryOf("metrics_provider", sr, ifc392)], supp),
        s.primary.root,
      ).error
    check "wrong commitment" in
      acceptSchemaResponse(
        response(mod392, good, @[entryOf("metrics_types", ir, sup392)]), s.primary.root
      ).error
    check "not a logos.schema_response" in
      acceptSchemaResponse(
        response(mod392, @[entryOf("", ir, ifc392)], supp), s.primary.root
      ).error

  test "[IFC-0453] [IFC-0455] entries are distinct, ordered, and all used":
    let
      a = iface("alpha", "alpha.one_request = {}\nalpha.one_response = {}\n")
      b = iface("beta", "beta.two_request = {}\nbeta.two_response = {}\n")
      ra = rootOf(a)
      rb = rootOf(b)
      m = module(implementing(ra, rb) & ping)
      s = accepted(m, [a, b])
      ea = entryOf("alpha", ra, a)
      eb = entryOf("beta", rb, b)
    let v = s.schemaResponse(s.primary.root).get
    check v.lookup("interface_schemas").get.items.mapIt(it.lookup("namespace").get.text) ==
      @["alpha", "beta"]
    check acceptSchemaResponse(response(m, @[ea, eb], @[]), s.primary.root).isOk
    check "not in ascending" in
      acceptSchemaResponse(response(m, @[eb, ea], @[]), s.primary.root).error
    check "not in ascending" in
      acceptSchemaResponse(response(m, @[ea, ea], @[]), s.primary.root).error
    check "not in _implements" in
      acceptSchemaResponse(
        response(module(implementing(ra) & ping), @[ea, eb], @[]),
        accepted(module(implementing(ra) & ping), [a]).primary.root,
      ).error
    check "is unused" in
      acceptSchemaResponse(
        response(m, @[ea, eb], @[entryOf("metrics_types", rootOf(sup392), sup392)]),
        s.primary.root,
      ).error

  test "[IFC-0456] [IFC-0457] at most 8 MiB, or the contract cannot be exposed":
    var supp: seq[string]
    var refs: seq[string]
    for i in 0 ..< 8:
      let ns = "types" & $char(ord('a') + i)
      let body = ns & ".t = uint8\n"
      supp.add("; " & "x".repeat(1_048_400 - body.len - 3) & "\n" & body)
      refs.add("f" & $char(ord('a') + i) & ": " & ns & ".t")
    var primary = module("demo.t = { " & refs.join(", ") & " }\n")
    let room = MaxInputSetBytes - supp.mapIt(it.len).foldl(a + b) - primary.len
    primary = "; " & "x".repeat(room - 3) & "\n" & primary
    let s = accepted(primary, [], supp)
    check s.documents.mapIt(it.source.len).foldl(a + b) == MaxInputSetBytes
    check "larger than 8 MiB" in s.schemaResponse(s.primary.root).error
    var big = newSeq[byte](MaxSchemaResponseBytes + 1)
    check "1 byte to 8 MiB" in acceptSchemaResponse(big, s.primary.root).error
    check "1 byte to 8 MiB" in acceptSchemaResponse([], s.primary.root).error

# Payloads and outcomes ---------------------------------------------------------------

import ../src/logos_core/iface/payload

proc bytesOf(h: string): seq[byte] =
  hexBytes(h)

proc storage(): ContractValidator =
  accepted(mirror("IFC/1.8.module.cddl")).validator

proc paramsError(v: ContractValidator, m: string, data: openArray[byte]): PayloadError =
  let r = v.checkParams(m, data)
  doAssert r.isErr
  r.error

proc detailOf(e: PayloadError): CborValue =
  decodeCbor(e.toFailure.detail.get).get

suite "iface: call and event encodings (INTERFACE §4.1-§4.3)":
  test "[IFC-0401] [IFC-0402] the §4.2 space_info map in deterministic key order":
    let v = cborMap(
      (cbor("used"), cbor(9663676416'u64)),
      (cbor("quota"), cbor(10737418240'u64)),
      (cbor("available"), cbor(1073741824'u64)),
    )
    let b = encodeCbor(v)
    # Keys by their complete encodings: 0x64 "used" < 0x65 "quota" < 0x69 "available".
    check toHex(b).startsWith("a3" & "6475736564")
    check toHex(b).find("6571756f7461") < toHex(b).find("69617661696c61626c65")
    let s = accepted(module(mirror("IFC/2.3.space_info.cddl")))
    check s.schemaSet.validates(
      0, s.primary.model.find("storage.space_info").get.body, v
    )
    # Keys out of encoded-byte order are not deterministic.
    let unsorted = bytesOf("a2" & "626161" & "02" & "6178" & "01")
    check storage().paramsError("exists", unsorted).reason ==
      Opt.some(iprNonDeterministicCbor)

  test "[IFC-0405] [IFC-0406] params and result maps of storage.exists":
    let v = storage()
    let params = encodeCbor(cborMap((cbor("cid"), cbor("bafy..."))))
    check v.checkParams("exists", params).get == cborMap((cbor("cid"), cbor("bafy...")))
    check v.checkResult("exists", encodeCbor(cborMap((cbor("exists"), cbor(true))))).isOk
    check v.checkResult("destroy", encodeCbor(cborMap())).isOk
    check v.checkParams("space", encodeCbor(cborMap())).isOk
    check v.checkResult("exists", encodeCbor(cborMap())).error.code == ecModule

  test "[IFC-0403] choice selection does not depend on source order":
    let
      a = accepted(module("demo.v = uint64 / tstr / bool\n"))
      b = accepted(module("demo.v = bool / uint64 / tstr\n"))
    check a.primary.root == b.primary.root
    for x in [cbor(7'u64), cbor("t"), cbor(true)]:
      let na = a.schemaSet.normalize(0, "demo.v", x).get
      let nb = b.schemaSet.normalize(0, "demo.v", x).get
      check na.node.armIndex == nb.node.armIndex

  test "§4.1 primitive encodings and fixed-width ranges":
    let s = accepted(
      module(
        "demo.p_request = { b: bool, u8: uint8, i8: int8, u64: uint64, i64: int64, t: tstr, y: bstr }\n" &
          "demo.p_response = {}\n"
      )
    )
    let v = s.validator
    proc params(b, u8, i8, u64, i64, t, y: CborValue): seq[byte] =
      encodeCbor(
        cborMap(
          (cbor("b"), b),
          (cbor("u8"), u8),
          (cbor("i8"), i8),
          (cbor("u64"), u64),
          (cbor("i64"), i64),
          (cbor("t"), t),
          (cbor("y"), y),
        )
      )

    let good = params(
      cbor(true),
      cbor(255'u64),
      cbor(-128'i64),
      cbor(high(uint64)),
      cbor(low(int64)),
      cbor("x"),
      cbor(@[1'u8]),
    )
    check v.checkParams("p", good).isOk
    let enc = toHex(good)
    check "f5" in enc # true
    check "387f" in enc # -128: major type 1, argument 127
    check "3b7fffffffffffffff" in enc # int64 minimum
    check "1bffffffffffffffff" in enc # uint64 maximum
    check "18ff" in enc # 255, shortest
    for (field, bad) in [
      ("u8", cbor(256'u64)),
      ("i8", cbor(-129'i64)),
      ("i8", cbor(128'u64)),
      ("u64", cbor(-1'i64)),
      ("b", cbor(1'u64)),
      ("t", cbor(@[1'u8])),
      ("y", cbor("x")),
    ]:
      var m = decodeCbor(good).get
      for e in m.entries.mitems:
        if e.key.text == field:
          e.value = bad
      let err = v.paramsError("p", encodeCbor(m))
      check err.code == ecInvalidParams
      check err.reason == Opt.some(iprSchemaMismatch)
      check err.path == @[cbor(field)]

  test "[IFC-0431] [IFC-0432] [IFC-0433] [IFC-0434] [IFC-0435] [IFC-0436] [IFC-0437] [IFC-0438] the §5.1 prelude aliases admit exactly their ranges":
    proc admits(alias: string, x: CborValue): bool =
      let v = accepted(
        module("demo.x_request = { v: " & alias & " }\ndemo.x_response = {}\n")
      ).validator
      v.checkParams("x", encodeCbor(cborMap((cbor("v"), x)))).isOk

    # (alias, least, greatest, one below, one above)
    for (alias, lo, hi, below, above) in [
      ("uint8", cbor(0'u64), cbor(255'u64), cbor(-1'i64), cbor(256'u64)),
      ("uint16", cbor(0'u64), cbor(65535'u64), cbor(-1'i64), cbor(65536'u64)),
      ("uint32", cbor(0'u64), cbor(4294967295'u64), cbor(-1'i64), cbor(4294967296'u64)),
      # No CBOR integer lies above 2^64 - 1; the last column repeats -1.
      ("uint64", cbor(0'u64), cbor(high(uint64)), cbor(-1'i64), cborNint(0)),
      ("int8", cbor(-128'i64), cbor(127'u64), cbor(-129'i64), cbor(128'u64)),
      ("int16", cbor(-32768'i64), cbor(32767'u64), cbor(-32769'i64), cbor(32768'u64)),
      (
        "int32",
        cbor(-2147483648'i64),
        cbor(2147483647'u64),
        cbor(-2147483649'i64),
        cbor(2147483648'u64),
      ),
      (
        "int64",
        cbor(low(int64)),
        cbor(uint64(high(int64))),
        cborNint(uint64(high(int64)) + 1), # -2^63 - 1
        cbor(uint64(high(int64)) + 1),
      ),
    ]:
      checkpoint alias
      check admits(alias, lo)
      check admits(alias, hi)
      check not admits(alias, below)
      check not admits(alias, above)
      check not admits(alias, cbor("0"))

suite "iface: payload validation (INTERFACE §4.4, §4.5)":
  test "[IFC-0415] [IFC-0416] non-deterministic or malformed CBOR is INVALID_PARAMS":
    let v = storage()
    for h in [
      "a1636369641800", # cid: non-shortest 0
      "bf63636964636269ffff", # indefinite-length map
      "a163636964 7f6162ff", # indefinite-length text
      "a2636369646161636369646162", # duplicate key
    ]:
      let e = v.paramsError("exists", bytesOf(h))
      check e.code == ecInvalidParams
      check e.reason == Opt.some(iprNonDeterministicCbor)
      check e.path.len == 0
      check decodeCbor(e.toFailure.detail.get).get ==
        cborMap((cbor("reason"), cbor("non-deterministic-cbor")))
    for h in ["a163636964", "a16363696461 61 00", "ff", ""]:
      let e = v.paramsError("exists", bytesOf(h))
      check e.code == ecInvalidParams
      check e.reason == Opt.some(iprMalformedCbor)

  test "[IFC-0417] outgoing bytes are deterministic by construction":
    let a = encodeCbor(cborMap((cbor("b"), cbor(1'u64)), (cbor("a"), cbor(2'u64))))
    let b = encodeCbor(cborMap((cbor("a"), cbor(2'u64)), (cbor("b"), cbor(1'u64))))
    check a == b
    check toHex(a) == "a2616102616201"
    check decodeCbor(a).isOk

  test "[IFC-0418] an unknown bare method name is METHOD_NOT_FOUND":
    let v = storage()
    for name in ["missing", "storage.exists", "exists_request", "schema", "Exists", ""]:
      let e = v.paramsError(name, encodeCbor(cborMap()))
      check e.code == ecMethodNotFound
      check e.reason.isNone
      check e.toFailure.detail.isNone

  test "[IFC-0419] wrong types, missing or unknown fields are INVALID_PARAMS with a path":
    let v = accepted(mirror("IFC/3.9.1.module.cddl")).validator
    let ok = cborMap((cbor("channel"), cbor(3'u64)))
    check v.checkParams("read", encodeCbor(ok)).isOk
    let cases = [
      (cborMap(), newSeq[CborValue]()),
      (cborMap((cbor("channel"), cbor("3"))), @[cbor("channel")]),
      (cborMap((cbor("channel"), cbor(4294967296'u64))), @[cbor("channel")]),
      (
        cborMap((cbor("channel"), cbor(3'u64)), (cbor("extra"), cbor(1'u64))),
        @[cbor("extra")],
      ),
      (cborArray(cbor(3'u64)), newSeq[CborValue]()),
    ]
    for (x, path) in cases:
      let e = v.paramsError("read", encodeCbor(x))
      check e.code == ecInvalidParams
      check e.reason == Opt.some(iprSchemaMismatch)
      check e.path == path
      check detailOf(e) ==
        cborMap(
          (cbor("reason"), cbor("schema-mismatch")), (cbor("path"), cborArray(path))
        )
      check checkFailure(e.toFailure).isOk

  test "[IFC-0419] paths through lists, tuples, choices and references":
    let v = accepted(
      module(
        "demo.item = { kind: \"a\", n: uint8 } / { kind: \"b\", s: tstr }\n" &
          "demo.put_request = { items: [* demo.item], pair: [uint8, tstr] }\n" &
          "demo.put_response = {}\n"
      )
    ).validator
    proc put(items, pair: CborValue): seq[byte] =
      encodeCbor(cborMap((cbor("items"), items), (cbor("pair"), pair)))

    let
      a = cborMap((cbor("kind"), cbor("a")), (cbor("n"), cbor(1'u64)))
      badB = cborMap((cbor("kind"), cbor("b")), (cbor("s"), cbor(1'u64)))
      pair = cborArray(cbor(1'u64), cbor("x"))
    check v.checkParams("put", put(cborArray(a), pair)).isOk
    check v.paramsError("put", put(cborArray(a, badB), pair)).path ==
      @[cbor("items"), cbor(1'u64), cbor("s")]
    check v.paramsError("put", put(cborArray(a), cborArray(cbor(1'u64), cbor(2'u64)))).path ==
      @[cbor("pair"), cbor(1'u64)]
    let c = cborMap((cbor("kind"), cbor("c")))
    check v.paramsError("put", put(cborArray(c), pair)).path ==
      @[cbor("items"), cbor(0'u64)]

  test "[IFC-0420] [IFC-0421] [IFC-0422] text that is not UTF-8 is a schema mismatch, never passed on":
    let v = storage()
    let bad = bytesOf("a1636369646261ff") # cid: "a\xff"
    let r = v.checkParams("exists", bad)
    check r.isErr
    check r.error.code == ecInvalidParams
    check r.error.reason == Opt.some(iprSchemaMismatch)
    check r.error.path == @[cbor("cid")]
    check detailOf(r.error).lookup("reason").get.text == "schema-mismatch"

  test "[IFC-0126] [IFC-0127] [IFC-0125] tstr values exclude U+0000; aliases bound integers":
    let v = storage()
    let e = v.paramsError("exists", encodeCbor(cborMap((cbor("cid"), cbor("a\0")))))
    check e.reason == Opt.some(iprSchemaMismatch)
    check e.path == @[cbor("cid")]

  test "[IMPL-DECISION G38] floats, tags, null and undefined are schema mismatches":
    let v = storage()
    for x in [
      cborFloatBits(fw16, 0x3c00),
      cborTag(1, cbor(1'u64)),
      cborNull(),
      cborUndefined(),
      cborSimple(16),
    ]:
      let e = v.paramsError("exists", encodeCbor(cborMap((cbor("cid"), x))))
      check e.reason == Opt.some(iprSchemaMismatch)
      check e.path == @[cbor("cid")]

  test "[IMPL-DECISION G59] nesting past the decoder cap is INVALID_PARAMS without detail":
    let v = storage()
    var b = newSeq[byte]()
    for _ in 0 .. DefaultMaxDepth:
      b.add(0x81)
    b.add(0x00)
    let e = v.paramsError("exists", b)
    check e.code == ecInvalidParams
    check e.reason.isNone
    check e.toFailure.detail.isNone

  test "event data is one map of the event's type":
    let v = storage()
    let data = cborMap(
      (cbor("bytes_sent"), cbor(1'u64)),
      (cbor("bytes_total"), cbor(2'u64)),
      (cbor("session"), cbor("s")),
    )
    check v.checkEvent("storage.upload_progress_event", encodeCbor(data)).isOk
    check v.checkEvent("storage.started_event", encodeCbor(cborMap())).isOk
    check v.checkEvent("storage.upload_progress_event", encodeCbor(cborMap())).isErr
    check v.checkEvent("upload_progress", encodeCbor(data)).isErr
    check v.checkEvent("storage.upload_progress_event", @[0xa0'u8, 0x00]).error.reason ==
      Opt.some(iprMalformedCbor)

suite "iface: shared error codes and invocation failures (INTERFACE §5.1)":
  test "[IFC-0439] [IFC-0461] the registry is 0-9, named as logos_types.h names it":
    let arms = commonDecl("logos.error_code").arms.mapIt(it.literal.unsigned)
    check arms == (0'u64 .. 9'u64).toSeq
    check ErrorCode.toSeq.mapIt(uint64(it.ord)) == arms
    let header = mirror("IFC/5.2.logos_types.h")
    for c in ErrorCode:
      check header.contains(re("\\b" & c.cName & "\\s*=\\s*" & $c.ord & ","))
    check $ecModule == "MODULE_ERROR"
    check $ecTransport == "TRANSPORT_ERROR"
    check header.contains(re("LOGOS_ERROR_MESSAGE_MAX_LEN " & $MaxMessageBytes & "u"))
    check header.contains(re("LOGOS_ERROR_DETAIL_MAX_LEN " & $MaxDetailBytes & "u"))

  test "[IFC-0462] [IFC-0463] unknown codes are invalid; a provider's unknown status is a module failure":
    check parseErrorCode(cbor(9'u64)).get == ecCancelled
    check parseErrorCode(cbor(10'u64)).isErr
    check parseErrorCode(cbor(-1'i64)).isErr
    check not commonValidates("logos.error_code", cbor(10'u64))
    check providerStatus(2) == ecInvalidParams
    check providerStatus(10) == ecModule
    check providerStatus(-1) == ecModule
    check providerStatus(high(int64)) == ecModule
    check errorCode(10).isNone

  test "[IFC-0464] [IFC-0465] messages are at most 512 UTF-8 bytes, and never with LOGOS_OK":
    check checkStatus(ecOk, Opt.none(string), Opt.none(seq[byte])).isOk
    check checkStatus(ecOk, Opt.some("fine"), Opt.none(seq[byte])).isErr
    check checkStatus(
      ecOk, Opt.none(string), Opt.some(invalidParamsDetail(iprMalformedCbor))
    ).isErr
    check checkStatus(ecModule, Opt.some("x".repeat(512)), Opt.none(seq[byte])).isOk
    check checkStatus(ecModule, Opt.some("x".repeat(513)), Opt.none(seq[byte])).isErr
    check checkStatus(ecModule, Opt.some("\xff"), Opt.none(seq[byte])).isErr
    check checkFailure(InvocationFailure(code: ecOk)).isErr

  test "[IFC-0466] [IFC-0467] [IFC-0468] [IFC-0469] [IFC-0470] detail is one valid value of 1-4096 bytes, for INVALID_PARAMS only":
    let good =
      invalidParamsDetail(iprSchemaMismatch, Opt.some(@[cbor("a"), cbor(0'u64)]))
    check checkDetail(ecInvalidParams, good).isOk
    check checkDetail(ecModule, good).isErr
    check checkDetail(ecNotAuthorised, good).isErr
    check checkDetail(ecInvalidParams, good & @[0x00'u8]).isErr # trailing bytes
    check checkDetail(ecInvalidParams, []).isErr
    check checkDetail(ecInvalidParams, bytesOf("a1 66726561736f6e 6b 66 6f 6f")).isErr
    check checkDetail(
      ecInvalidParams, encodeCbor(cborMap((cbor("reason"), cbor("other"))))
    ).isErr
    check checkDetail(
      ecInvalidParams,
      encodeCbor(
        cborMap((cbor("reason"), cbor("malformed-cbor")), (cbor("x"), cbor(1'u64)))
      ),
    ).isErr
    check checkDetail(
      ecInvalidParams, bytesOf("a1 66 726561736f6e 78 0e 6d616c666f726d65642d63626f72")
    ).isErr
    let longPath = (0 ..< 5000).mapIt(cbor(uint64(it)))
    let capped = invalidParamsDetail(iprSchemaMismatch, Opt.some(longPath))
    check capped.len <= MaxDetailBytes
    check decodeCbor(capped).get == cborMap((cbor("reason"), cbor("schema-mismatch")))
    check checkDetail(ecInvalidParams, capped).isOk

  test "[IFC-0440] [IFC-0441] [IFC-0442] [IFC-0443] the detail types":
    check commonValidates("logos.error_detail", cbor(@[1'u8]))
    check commonValidates("logos.error_detail", cbor(newSeq[byte](4096)))
    check not commonValidates("logos.error_detail", cbor(newSeq[byte]()))
    check not commonValidates("logos.error_detail", cbor(newSeq[byte](4097)))
    check commonDecl("logos.invalid_params_reason").arms.mapIt(it.literal.text).sorted ==
      InvalidParamsReason.toSeq.mapIt($it).sorted
    check commonValidates("logos.invalid_params_path_segment", cbor("k"))
    check commonValidates("logos.invalid_params_path_segment", cbor(3'u64))
    check not commonValidates("logos.invalid_params_path_segment", cbor(-3'i64))
    for r in InvalidParamsReason:
      check commonValidates("logos.invalid_params_detail", detailValue(r))
      check commonValidates(
        "logos.invalid_params_detail", detailValue(r, Opt.some(@[cbor("a")]))
      )
