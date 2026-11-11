## INTERFACE §2, §2.1-§2.3, §2.5, §3.2 (generated guards), §3.9.1-§3.9.10
## (forward), §5.2: the canonical C type mapping, revision 3, compared with the
## spec's C blocks and compiled as C17, C23, C++17, C++20 and C++23.

import std/[algorithm, os, osproc, sequtils, strutils]
import unittest2
import ../src/logos_core/[hash, pins]
import ../src/logos_core/iface/accept
import ../src/logos_core/base/hex
import ./support/specdata

# Accepting sets ------------------------------------------------------------------

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

proc bound(
    module: string,
    primary = Opt.none(string),
    ifaces: openArray[string] = [],
    supp: openArray[string] = [],
    opts = AcceptOptions(),
): ModuleBinding =
  let r = acceptBinding(module, primary, ifaces, supp, opts)
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

proc implementing(roots: varargs[Digest]): string =
  var rs = @roots
  rs.sort(
    proc(a, b: Digest): int =
      cmpBytes(a, b)
  )
  "_implements = [" & rs.mapIt("h'" & toHex(it) & "'").join(", ") & "]\n"

proc rootOf(source: string): Digest =
  accepted(source).primary.root

proc rootLiteral(source: string): string =
  ## The 64 hex digits of the first `h'...'` literal in `source`.
  let i = source.find("h'")
  doAssert i >= 0
  source[i + 2 ..< i + 66]

const ping = "demo.ping_request = {}\ndemo.ping_response = {}\n"

# Normalized C ----------------------------------------------------------------------

proc withoutComments(text: string): string =
  var s = ""
  var i = 0
  var inStr = false
  while i < text.len:
    let c = text[i]
    if inStr:
      s.add(c)
      if c == '\\' and i + 1 < text.len:
        s.add(text[i + 1])
        i += 2
        continue
      if c == '"':
        inStr = false
      inc i
    elif text.continuesWith("/*", i):
      let j = text.find("*/", i + 2)
      i = j + 2
      s.add(' ')
    else:
      if c == '"':
        inStr = true
      s.add(c)
      inc i
  s.replace("\\\n", " ")

proc norm(x: string): string =
  ## Whitespace collapsed, and dropped next to C punctuation (outside strings).
  const punct = {'*', ';', '{', '}', '(', ')', '[', ']', ',', '='}
  var r = ""
  var inStr = false
  var space = false
  for c in x:
    if inStr:
      r.add(c)
      if c == '"' and r.len >= 2 and r[^2] != '\\':
        inStr = false
      continue
    if c in Whitespace:
      space = r.len > 0
      continue
    if space and c notin punct and r[^1] notin punct:
      r.add(' ')
    space = false
    r.add(c)
    if c == '"':
      inStr = true
  r

proc cItems(text: string): seq[string] =
  ## The top-level declarations of a C text, normalized: no comments, include
  ## lines, conditionals, guards or document identity macros.
  # The C++ linkage wrapper's braces enclose declarations; they are no item.
  var lines = withoutComments(text).splitLines
  for i in 1 ..< lines.len:
    if lines[i - 1].strip == "#ifdef __cplusplus" and
        lines[i].strip in ["extern \"C\" {", "}"]:
      lines[i] = ""
  let s = lines.join("\n")
  var items: seq[string]
  var cur = ""
  var depth = 0
  var inStr = false
  var i = 0
  while i < s.len:
    let c = s[i]
    if inStr:
      cur.add(c)
      if c == '"' and s[i - 1] != '\\':
        inStr = false
      inc i
      continue
    if c == '#' and depth == 0 and cur.strip.len == 0:
      var j = s.find('\n', i)
      if j < 0:
        j = s.len
      # `#define NAME VALUE`: the space after NAME is significant.
      let words = s[i ..< j].strip.splitWhitespace(2)
      if words.len > 2:
        items.add(words[0] & " " & words[1] & " " & norm(words[2]))
      else:
        items.add(words.join(" "))
      cur = ""
      i = j + 1
      continue
    cur.add(c)
    case c
    of '"':
      inStr = true
    of '{':
      inc depth
    of '}':
      dec depth
    of ';':
      if depth == 0:
        items.add(norm(cur))
        cur = ""
    else:
      discard
    inc i
  items.filterIt(
    not (
      it.startsWith("#include") or it.startsWith("#if") or it.startsWith("#else") or
      it.startsWith("#error") or it.startsWith("#endif") or
      it.startsWith("#define LOGOS_DOCUMENT_") or
      (it.startsWith("#define") and it.splitWhitespace.len == 2)
    )
  )

proc decls(s: CSchemaSet): seq[string] =
  let r = cDeclarations(s)
  if r.isErr:
    checkpoint r.error
  cItems(r.get.join("\n\n"))

proc decls(s: ContractSet): seq[string] =
  decls(s.cSchemaSet)

proc decls(
    primary: string,
    ifaces: openArray[string] = [],
    supp: openArray[string] = [],
    opts = AcceptOptions(),
): seq[string] =
  decls(accepted(primary, ifaces, supp, opts))

proc text(items: seq[string]): string =
  items.join("\n")

proc defines(items: seq[string]): seq[string] =
  items.filterIt(it.startsWith("#define"))

proc sameSet(a, b: seq[string]): bool =
  ## Placement is not canonical (§2.1): equal as sets of declarations.
  let (x, y) = (a.sorted, b.sorted)
  if x != y:
    checkpoint "only generated: " & $x.filterIt(it notin y)
    checkpoint "only expected: " & $y.filterIt(it notin x)
  x == y

proc header(s: ContractSet): string =
  let h = contractHeader(s.cSchemaSet)
  if h.isErr:
    checkpoint h.error
  h.get

let
  ifc392 = mirror("IFC/3.9.2.interface.cddl")
  mod392 = mirror("IFC/3.9.2.module.cddl")
  sup392 = mirror("IFC/3.9.2.supporting.cddl")

# Compiling -------------------------------------------------------------------------

const outDir = "build/codegen/ifc"

type Mode = tuple[cxx: bool, std, fallback: string]

const modes: array[5, Mode] = [
  (false, "c17", "c17"),
  (false, "c23", "c2x"),
  (true, "c++17", "c++17"),
  (true, "c++20", "c++2a"),
  (true, "c++23", "c++2b"),
]

proc compilerFor(cxx: bool): string =
  ## $CC / $CXX, else the first such compiler on PATH: MinGW and MSYS2 have no `cc`.
  result = getEnv(if cxx: "CXX" else: "CC")
  let names =
    if cxx:
      ["c++", "g++", "clang++"]
    else:
      ["cc", "gcc", "clang"]
  for name in names:
    if result.len == 0:
      result = findExe(name)

proc compileUnit(name, source: string, extra = ""): string =
  ## Writes `logos_types.h` and the translation unit `name` and checks its syntax
  ## in every supported language mode with every warning an error; "" when all
  ## compile, else the first failure.
  createDir(outDir)
  writeFile(outDir / "logos_types.h", logosTypesHeader())
  let unit = outDir / name & ".c"
  writeFile(unit, source)
  for m in modes:
    let cc = compilerFor(m.cxx)
    if cc.len == 0:
      return "no " & (if m.cxx: "C++" else: "C") & " compiler on PATH"
    # A wrapped clang (Nix) passes linker flags that -fsyntax-only leaves unused.
    let (version, _) = execCmdEx(quoteShell(cc) & " --version")
    let quiet = if "clang" in version: " -Qunused-arguments" else: ""
    let lang = if m.cxx: " -x c++" else: ""
    var output = ""
    for std in [m.std, m.fallback]:
      let cmd =
        quoteShell(cc) & quiet & lang & " -std=" & std &
        " -Wall -Wextra -Wpedantic -Werror -fsyntax-only" & extra & " -I " &
        quoteShell(outDir) & " " & quoteShell(unit)
      let (o, code) = execCmdEx(cmd)
      if code == 0:
        output = ""
        break
      output = m.std & ": " & o
      if "std=" notin o: # an older compiler may know only the draft name
        break
    if output.len > 0:
      return output
  ""

proc compiles(name, header: string, extra = ""): string =
  createDir(outDir)
  writeFile(outDir / name & ".h", header)
  compileUnit(name, "#include \"" & name & ".h\"\n", extra)

proc compilesSet(name: string, s: ContractSet): string =
  let h = contractHeader(s.cSchemaSet)
  if h.isErr:
    return h.error
  compiles(name, h.get)

const deviceTarget = defined(android) or defined(ios)
  ## A suite cross-compiled for an emulator or simulator runs where there is no C
  ## compiler. There a test that compiles headers reports SKIPPED and its other
  ## checks still run; the host suites compile every header.

template checkCompiles(call: untyped) =
  when deviceTarget:
    skip()
  else:
    check call == ""

const staticAssert =
  "#ifdef __cplusplus\n#define CHECK(c) static_assert(c, #c)\n#else\n" &
  "#define CHECK(c) _Static_assert(c, #c)\n#endif\n"

# Tests -----------------------------------------------------------------------------

suite "ifc.c-types: required C mapping cases (INTERFACE §3.9.1-§3.9.5)":
  test "[IFC-0360] [IFC-0361] [IFC-0362] [IFC-0363] [IFC-0364] [IFC-0365] [IFC-0874] §3.9.1: the declaration-only form plus the primary-namespace constant":
    let got = decls(mirror("IFC/3.9.1.module.cddl"))
    check sameSet(
      got,
      cItems(mirror("IFC/3.9.1.module.h")) &
        "#define LOGOS_PRIMARY_NAMESPACE_meter_module \"meter\"",
    )

  test "[IFC-0370] [IFC-0371] [IFC-0372] [IFC-0373] [IFC-0374] [IFC-0375] [IFC-0376] [IFC-0377] [IFC-0378] [IFC-0379] [IFC-0380] [IFC-0382] [IFC-0592] [IFC-0594] §3.9.2: the metadata-extended construction set":
    let s = accepted(mod392, [ifc392], [sup392])
    # The implementation constant's group is the interface whose recomputed root
    # the `_implements` literal names.
    check toHex(s.interfaces[0].root) == rootLiteral(mod392)
    let got = decls(s)
    check sameSet(got, cItems(mirror("IFC/3.9.2.module.h")))
    # Exactly the four document and binding constants and the one literal macro.
    check got.defines.len == 5

  test "[IFC-0610] [IFC-0875] interface and supporting documents keep their role constants when generated alone":
    let inProvider = decls(mod392, [ifc392], [sup392])
    let iface =
      "#define LOGOS_INTERFACE_NAMESPACE_metrics_provider \"metrics_provider\""
    let supp = "#define LOGOS_SUPPORTING_NAMESPACE_metrics_types \"metrics_types\""
    check iface in inProvider
    check supp in inProvider
    check decls(ifc392).defines == @[iface]
    check sameSet(
      decls(sup392), @[supp, "typedef uint64_t logos_metrics_types_Counter_t;"]
    )

  test "[IFC-0583] [IFC-0584] [IFC-0880] module bindings: interface-only, events-only, types-only primary, lifecycle-only":
    # The §3.9.1 module symbols under another module name; a module without a
    # provider contract has only the identity and lifecycle ones (§2.6).
    proc moduleSymbols(module: string, provider = true): seq[string] =
      for item in cItems(mirror("IFC/3.9.1.module.h")):
        if "_MODULE_" in item and (
          provider or
          ["_MODULE_call_surface(", "_MODULE_free(", "_MODULE_dispatch("].allIt(
            it notin item
          )
        ):
          result.add(item.replace("meter_module", module))

    # §3.9.2: sensor_module bound to metrics_provider alone, without a primary:
    # the role and implementation constants, the interface method typedef, the
    # concrete interface method and the module symbols shown there.
    let only = bound("sensor_module", ifaces = [ifc392])
    check only.primary.isNone
    check only.interfaces[0].root == rootOf(ifc392) # the binding changes no identity
    check sameSet(
      decls(only.cSchemaSet),
      @[
        "#define LOGOS_INTERFACE_NAMESPACE_metrics_provider \"metrics_provider\"",
        "#define LOGOS_IMPLEMENTS_sensor_module_INDEX0 \"metrics_provider\"",
      ] &
        cItems(mirror("IFC/3.9.2.module.h")).filterIt(
          "metrics_provider_Snapshot" in it or "_MODULE_" in it
        ),
    )
    check moduleSymbols("sensor_module").allIt(it in decls(only.cSchemaSet))
    check only.cSchemaSet.headerName == "sensor_module"
    # An interface that declares only events.
    let ticks = "_interface = \"ticks\"\nticks.tick_event = { n: uint64 }\n"
    check sameSet(
      decls(bound("tick_module", ifaces = [ticks]).cSchemaSet),
      @[
        "#define LOGOS_INTERFACE_NAMESPACE_ticks \"ticks\"",
        "#define LOGOS_IMPLEMENTS_tick_module_INDEX0 \"ticks\"",
        "typedef struct logos_ticks_Tick_event_EVENT{uint64_t n;}logos_ticks_Tick_event_t;",
      ] & moduleSymbols("tick_module"),
    )
    # A types-only primary document with an implemented callable interface.
    let typesOnly =
      module(implementing(rootOf(ifc392)) & "demo.t = uint64\n", "types_module")
    let tb = bound("types_module", Opt.some(typesOnly), [ifc392])
    check sameSet(
      decls(tb.cSchemaSet),
      @[
        "#define LOGOS_PRIMARY_NAMESPACE_types_module \"demo\"",
        "#define LOGOS_IMPLEMENTS_types_module_INDEX0 \"metrics_provider\"",
        "#define LOGOS_INTERFACE_NAMESPACE_metrics_provider \"metrics_provider\"",
        "typedef uint64_t logos_demo_T_t;",
      ] &
        cItems(mirror("IFC/3.9.2.module.h"))
        .filterIt("metrics_provider_Snapshot" in it)
        .mapIt(it.replace("sensor_module", "types_module")) &
        moduleSymbols("types_module"),
    )
    # A module with lifecycle declarations but no contracts: no documents, and
    # no provider symbols.
    let bare = bound("bare_module")
    check bare.primary.isNone and bare.interfaces.len == 0
    check sameSet(
      decls(bare.cSchemaSet), moduleSymbols("bare_module", provider = false)
    )
    check contractHeader(bare.cSchemaSet).isOk
    # A supplied binding agrees with the primary's `_module` and `_implements`.
    check acceptBinding("other_module", Opt.some(typesOnly), [ifc392]).isErr
    check acceptBinding("types_module", Opt.some(typesOnly)).isErr
    check acceptBinding("sensor_module", Opt.some(mod392), [ifc392], [sup392]).isOk
    # A supporting document is not a binding's implemented interface.
    check acceptBinding("x_module", Opt.none(string), [sup392]).isErr

  test "[IFC-0384] [IFC-0385] [IFC-0386] [IFC-0387] [IFC-0882] §3.9.3: recursive aggregate references":
    check sameSet(
      decls(mirror("IFC/3.9.3.module.cddl")),
      cItems(mirror("IFC/3.9.3.module.h")) &
        "#define LOGOS_SUPPORTING_NAMESPACE_recursive \"recursive\"",
    )

  test "[IFC-0391] §3.9.4: choice-valued request and response halves get complete named choices":
    let source = module(
      mirror("IFC/2.4.resolve.cddl") & """
storage.report_request = { id: uint64 }
storage.report_response =
    { kind: "found", size: uint64 } /
    { kind: "missing" }
""",
      "storage_module",
    )
    let got = decls(source)
    for (stem, labels) in [
      ("storage_Resolve_request", @["By_id", "By_name"]),
      ("storage_Report_response", @["Found", "Missing"]),
    ]:
      check ("typedef uint32_t logos_" & stem & "_KIND_t;") in got
      for i, l in labels:
        check ("#define LOGOS_ARM_" & stem & "_CASE_" & l & " " & $i & "u") in got
      check (
        "typedef struct logos_" & stem & "_CHOICE{logos_" & stem & "_KIND_t kind;union{" &
        labels.mapIt("logos_" & stem & "_AR_" & it & "_t arm_" & it & ";").join("") &
        "}value;}logos_" & stem & "_t;"
      ) in got
    # The map-valued halves stay flattened (§2.4): no aggregate of their own.
    check "logos_storage_Resolve_response_t" notin got.text
    check "logos_storage_Report_request_t" notin got.text
    checkCompiles compilesSet("ifc394", accepted(source))

  test "[IFC-0123] [IFC-0883] §3.9.5: dotted and underscored namespaces stay apart":
    let iface =
      "_interface = \"a.b\"\na.b.value = uint64\n" &
      "a.b.get_request = { v: a_b.value }\na.b.get_response = { v: a.b.value }\n"
    let got = decls(iface, supp = ["a_b.value = uint64\n"])
    for item in cItems(mirror("IFC/3.9.5.rejection.h")):
      check item in got
    checkCompiles compilesSet(
      "ifc395", accepted(iface, supp = ["a_b.value = uint64\n"])
    )

suite "ifc.c-types: the header frame (INTERFACE §2, §3.2)":
  test "[IFC-0597] [IFC-0598] [IFC-0599] [IFC-0600] [IFC-0603] [IFC-0604] [IFC-0605] [IFC-0606] [IFC-0816] [IFC-0817] mapping and context checks precede every guard":
    let h = header(accepted(mod392, [ifc392], [sup392]))
    let fixed = cItems(mirror("IFC/5.2.logos_types.h"))
    # The revision this mapping implements is the one logos_types.h defines.
    check ("#define LOGOS_C_MAPPING_REVISION " & $CMappingRevision & "u") in fixed
    check mirror("IFC/2.revision-check.h").strip in h
    let firstGuard = h.find("#ifdef LOGOS_DOCUMENT_")
    check firstGuard > 0
    check h.find("#include \"logos_types.h\"") < h.find("LOGOS_C_MAPPING_REVISION")
    check h.find("LOGOS_C_MAPPING_REVISION") < firstGuard
    # One marker per pinned identifier, as logos_types.h defines it.
    for m in contextMarkers():
      check ("#define " & m & " 1") in fixed
      let check = "#if !defined(" & m & ") || " & m & " != 1"
      check check in h
      check h.find(check) < firstGuard
    # Nothing encloses the checks, and the header defines neither.
    check h.find("#if") == h.find("#if !defined(LOGOS_C_MAPPING_REVISION)")
    check "#define LOGOS_C_MAPPING_REVISION" notin h
    check "#define LOGOS_C_CONTEXT_" notin h

  test "[IFC-0588] [IFC-0589] [IFC-0590] generated headers wrap their declarations for C++ linkage":
    let wrapper = mirror("IFC/2.linkage.h").splitLines
    let (open, close) = (wrapper[0 .. 2].join("\n"), wrapper[^3 .. ^1].join("\n"))
    for h in [header(accepted(mod392, [ifc392], [sup392])), logosTypesHeader()]:
      check open in h
      check close in h
      check h.find(open) < h.find("typedef ")
      check h.rfind(close) > h.rfind("typedef ")

  test "[IFC-0803] [IFC-0808] [IFC-0809] [IFC-0810] [IFC-0811] [IFC-0812] [IFC-0814] [IFC-0815] [IFC-0818] each document group has a checked guard":
    let s = accepted(mod392, [ifc392], [sup392])
    let h = header(s)
    for c in s.documents:
      let ns = projectNamespace(c.model.namespace)
      let guard = "LOGOS_DOCUMENT_" & ns & "_DEFINED"
      check ("#ifdef " & guard) in h
      check ("#define " & guard & " 1") in h
      for i in 0 .. 3:
        # Root bytes 8i..8i+7, most significant first, as 0x + 16 lowercase
        # digits + ULL; recomputed from the documents, never typed in.
        let lit = "0x" & toHex(c.root)[16 * i ..< 16 * i + 16] & "ULL"
        let name = "LOGOS_DOCUMENT_" & ns & "_ROOT_" & $i
        check ("#define " & name & " " & lit) in h
        check ("!defined(" & name & ") || " & name & " != " & lit) in h
        # The comparison comes before the repeated group is suppressed.
        check h.find(name & " != ") < h.find("#define " & guard)
    # The module binding's constants are outside every document guard.
    let binding = h.find("#define LOGOS_PRIMARY_NAMESPACE_sensor_module")
    check binding > h.rfind("#endif /* LOGOS_DOCUMENT_")
    check h.find("#define LOGOS_IMPLEMENTS_sensor_module_INDEX0") > binding

  test "[IFC-0803] [IFC-0813] [IFC-0814] a repeated identical group is suppressed; a conflicting or incomplete identity stops compilation":
    let a = accepted(mod392, [ifc392], [sup392])
    let b = bound("other_module", ifaces = [ifc392])
    createDir(outDir)
    writeFile(outDir / "sensor_module_types.h", header(a))
    writeFile(outDir / "other_module_types.h", contractHeader(b.cSchemaSet).get)
    checkCompiles compileUnit(
      "guards_ok",
      "#include \"sensor_module_types.h\"\n#include \"other_module_types.h\"\n" &
        "#include \"sensor_module_types.h\"\n",
    )
    when not deviceTarget:
      let ns = "LOGOS_DOCUMENT_metrics_provider_"
      let wrong = compileUnit(
        "guards_conflict",
        "#define " & ns & "DEFINED 1\n#define " & ns & "ROOT_0 0x0000000000000000ULL\n" &
          "#include \"other_module_types.h\"\n",
      )
      check "Conflicting Logos schema document metrics_provider" in wrong
      let missing = compileUnit(
        "guards_missing",
        "#define " & ns & "DEFINED 1\n#include \"other_module_types.h\"\n",
      )
      check "Conflicting Logos schema document metrics_provider" in missing

  test "[IFC-0118] every accepted set has a metadata-extended header":
    var n = 0
    for f in walkFiles("spec/mirrors/IFC/*.cddl"):
      let s = acceptContractSet(readFile(f))
      if s.isOk:
        checkpoint f
        check contractHeader(s.get.cSchemaSet).isOk
        inc n
    check n >= 10
    check contractHeader(accepted(mod392, [ifc392], [sup392]).cSchemaSet).isOk
    check contractHeader(bound("other_module", ifaces = [ifc392]).cSchemaSet).isOk

  test "[IFC-0625] [IFC-0626] the generator keeps the §5.3 limits; past them nothing is produced":
    # A declaration body is nesting level 1 and every child adds one (§5.3).
    proc nested(lists: int): string =
      result = "uint64"
      for _ in 1 .. lists:
        result = "[" & result & "]"
      result = "demo.deep = " & result & "\n"

    check contractHeader(accepted(nested(127)).cSchemaSet).isOk
    let r = acceptContractSet(nested(128))
    check r.isErr
    check "nests deeper than 128" in r.error

suite "ifc.c-types: names and schema metadata (INTERFACE §2, §2.1)":
  test "[IFC-0593] [IFC-0609] [IFC-0612] the §2.1 multi-document constants: primary, implements, interface, supporting":
    let source = module(
      implementing(rootOf(ifc392)) &
        "storage.tag_request = { tag: storage_types.tag }\nstorage.tag_response = {}\n",
      "storage_module",
    )
    let got = decls(source, [ifc392], ["storage_types.tag = tstr\n"])
    check sameSet(got.defines, cItems(mirror("IFC/2.1.namespaces.h")))
    # Every document alone gets its one role constant.
    check decls(module(ping)).defines ==
      @["#define LOGOS_PRIMARY_NAMESPACE_demo_module \"demo\""]
    check decls("demo.x = uint64\n").defines ==
      @["#define LOGOS_SUPPORTING_NAMESPACE_demo \"demo\""]
    check decls("_interface = \"demo\"\n" & ping).defines ==
      @["#define LOGOS_INTERFACE_NAMESPACE_demo \"demo\""]
    check decls("_interface = \"demo\"\ndemo.x = uint64\n").defines ==
      @["#define LOGOS_INTERFACE_NAMESPACE_demo \"demo\""]

  test "[IFC-0613] a dotted primary namespace keeps its exact value; its types keep the complete projection":
    let source = module(
      "logos.runtime_control.state = { phase: uint64 }\n" &
        "logos.runtime_control.ping_request = {}\nlogos.runtime_control.ping_response = {}\n",
      "logos_runtime_control",
    )
    let got = decls(source, opts = AcceptOptions(system: true))
    check got.defines == cItems(mirror("IFC/2.1.dotted-namespace.h"))
    check "logos_logos_NS_runtime_control_State_t" in got.text

  test "§2.1 sensitivity constants follow `_sensitive` in ASCII order, also in a provider header":
    let iface =
      "_interface = \"vault\"\n_sensitive = [\"vault.get_response\", \"vault.store_request\"]\n" &
      "vault.get_request = {}\nvault.get_response = { secret: bstr }\n" &
      "vault.store_request = { secret: bstr }\nvault.store_response = {}\n"
    let want = @[
      "#define LOGOS_SENSITIVE_vault_INDEX0 \"vault.get_response\"",
      "#define LOGOS_SENSITIVE_vault_INDEX1 \"vault.store_request\"",
    ]
    for item in want:
      check item in decls(iface)
      check item in decls(bound("vault_module", ifaces = [iface]).cSchemaSet)
    check decls(ifc392).filterIt("SENSITIVE" in it).len == 0

  test "[IFC-0901] module-name projection: single, repeated and trailing underscores; a_Ub is not canonical":
    for (name, c) in [
      ("vault_module", "vault_module"),
      ("a__b", "a_U_b"),
      ("a_", "a_U"),
      ("a___b_", "a_U_U_b_U"),
    ]:
      check projectModule(name) == c
      check decodeModule(c) == Result[string, string].ok(name)
    check decodeModule("a_Ub").isErr
    check decodeModule("a_U").get == "a_"
    check decls(module(ping, "a__b")).defines ==
      @["#define LOGOS_PRIMARY_NAMESPACE_a_U_b \"demo\""]
    check "#define LOGOS_IMPLEMENTS_a_U_INDEX0 \"metrics_provider\"" in
      decls(bound("a_", ifaces = [ifc392]).cSchemaSet)

  test "§2.1 namespace projection: dots become _NS_, underscores stay":
    for (ns, c) in [
      ("storage", "storage"),
      ("metrics_provider", "metrics_provider"),
      ("logos.runtime_control", "logos_NS_runtime_control"),
    ]:
      check projectNamespace(ns) == c
      check decodeNamespace(c).get == ns
    check decodeNamespace("a_NS_").isErr

  test "[IFC-0618] [IFC-0619] [IFC-0620] [IFC-0887] [IFC-0889] [IFC-0891] every fixed keyword spelling as a field escapes its member only":
    check CEscapedIdentifiers.toSeq.sorted ==
      mirror("IFC/2.1.keywords.txt").splitWhitespace.sorted
    var fields: seq[string]
    for kw in CEscapedIdentifiers:
      fields.add("  " & kw & ": uint64,")
    let all = "demo.kw = {\n" & fields.join("\n") & "\n}\n"
    let t = decls(all).text
    for kw in CEscapedIdentifiers:
      check ("uint64_t " & kw & "_;") in t
    checkCompiles compilesSet("keywords", accepted(all))
    # Complete identifiers: has_class, class_len and class_count stay; class0 is
    # no keyword; fields keep their schema order.
    let got = decls(
      "demo.k = { class: uint64, class0: uint64, ? for: bstr, ? int: [* uint64], " &
        "? do: [uint64, tstr], ordinary: bool }\n"
    )
    check (
      "typedef struct logos_demo_K_MAP{uint64_t class_;uint64_t class0;" &
      "bool has_do;uint64_t do_0;const char*do_1;bool has_for;const uint8_t*for_;size_t for_len;" &
      "bool has_int;const uint64_t*int_;size_t int_count;bool ordinary;}logos_demo_K_t;"
    ) in got

  test "[IFC-0595] [IFC-0596] the same accepted set always yields the same declarations":
    let a = decls(mod392, [ifc392], [sup392])
    let reordered = mod392.replace(
      "sensor.control.settings = {\n  kind: \"sensor\",\n  limit: metrics_types.counter,\n}",
      "sensor.control.settings = {\n  limit: metrics_types.counter,\n  kind: \"sensor\",\n}",
    )
    check reordered != mod392
    check decls(reordered, [ifc392], [sup392]) == a
    check cDeclarations(accepted(mod392, [ifc392], [sup392]).cSchemaSet).get ==
      cDeclarations(accepted(mod392, [ifc392], [sup392]).cSchemaSet).get

  test "[IFC-0123] [IFC-0617] [IFC-0621] [IFC-0622] [IFC-0895] look-alike names stay distinct and whole":
    let got = decls(
      "demo.x_t = uint64\ndemo.x_kind = uint64\ndemo.x = uint64 / tstr\n" &
        "demo.a_b = { v: \"named\" }\ndemo.a = { b: { v: \"inline\" } }\n"
    )
    check "typedef uint64_t logos_demo_X_t_t;" in got
    check "typedef uint64_t logos_demo_X_kind_t;" in got
    check "typedef uint32_t logos_demo_X_KIND_t;" in got
    check "#define LOGOS_LITERAL_demo_A_b_V \"named\"" in got
    check "#define LOGOS_LITERAL_demo_A_B_V \"inline\"" in got
    # Long common prefixes that differ only at the end are never shortened.
    let long = 'n'.repeat(120)
    let lg = decls(
      "demo." & long & "_a = { " & long & "_x: uint64 }\ndemo." & long & "_b = uint64\n"
    )
    check (
      "typedef struct logos_demo_" & capitalize(long) & "_a_MAP{uint64_t " & long &
      "_x;}logos_demo_" & capitalize(long) & "_a_t;"
    ) in lg
    check ("typedef uint64_t logos_demo_" & capitalize(long) & "_b_t;") in lg
    checkCompiles compilesSet(
      "lookalike",
      accepted(
        "demo.x_t = uint64\ndemo.x_kind = uint64\ndemo.x = uint64 / tstr\n" &
          "demo.a_b = { v: \"named\" }\ndemo.a = { b: { v: \"inline\" } }\n" & "demo." &
          long & "_a = uint64\ndemo." & long & "_b = uint64\n"
      ),
    )

  test "§2.1 common types use their fixed names; logos.error_code is the status enum":
    let got = decls(
      "demo.x = { code: logos.error_code, d: logos.error_detail, c: logos.schema_commitment }\n"
    )
    check "typedef struct logos_demo_X_MAP{logos_schema_commitment_t c;logos_error_code_t code;logos_error_detail_t d;}logos_demo_X_t;" in
      got

  test "[IFC-0123] namespaces that spell a fixed common name keep their own stems (NX-04)":
    for (src, want) in [
      ("error.code = uint64\n", "typedef uint64_t logos_error_Code_t;"),
      (
        "module.context = { x: uint64 }\n",
        "typedef struct logos_module_Context_MAP{uint64_t x;}logos_module_Context_t;",
      ),
      ("schema.commitment = tstr\n", "typedef const char*logos_schema_Commitment_t;"),
    ]:
      checkpoint src
      check want in decls(src)
      checkCompiles compilesSet(
        "fixed_" & src.split(" ")[0].replace(".", "_"), accepted(src)
      )

suite "ifc.c-types: primitives and composites (INTERFACE §2.2, §2.3, §2.5)":
  test "[IFC-0128] [IFC-0475] constrained strings; logos_types.h constraints are not redeclared":
    let got = decls(
      "demo.x = { a: tstr .size 64, b: tstr .size (1..64), c: bstr .size (1..4096) }\n"
    )
    let want = cItems(mirror("IFC/2.2.constrained.h"))
    check want[0] in got
    check want[1] in got
    check want[2] notin got
    check want[2] in cItems(logosTypesHeader())
    check "typedef struct logos_demo_X_MAP{logos_tstr_size_64_t a;logos_tstr_size_1_64_t b;logos_bstr_size_1_4096_t c;size_t c_len;}logos_demo_X_t;" in
      got

  test "[IFC-0129] [IFC-0135] [IFC-0630] exact byte strings are arrays; pairs stay adjacent":
    let t = decls(
      "demo.x = { digest: bstr .size 32, data: bstr, xs: [* uint64], z: bstr .size 0 }\n"
    ).text
    check cItems(mirror("IFC/2.2.exact-bstr.h"))[0] in t
    check "{const uint8_t*data;size_t data_len;uint8_t digest[32];const uint64_t*xs;size_t xs_count;logos_bstr_size_0_t z;}" in
      t
    check "logos_bstr_size_32" notin t

  test "[IFC-0131] [IFC-0132] [IFC-0133] [IFC-0134] maps in field order, has_ flags beside their field":
    let role = "#define LOGOS_SUPPORTING_NAMESPACE_storage \"storage\""
    check sameSet(
      decls(mirror("IFC/2.3.space_info.cddl")),
      cItems(mirror("IFC/2.3.space_info.h")) & role,
    )
    check sameSet(
      decls(mirror("IFC/2.3.peer_info.cddl")),
      cItems(mirror("IFC/2.3.peer_info.h")) & role,
    )

  test "[IFC-0136] [IFC-0138] empty values hold one uint8_t _empty":
    let got = decls(
      "_interface = \"demo\"\ndemo.done_event = {}\n" &
        "demo.e = {}\ndemo.t = []\ndemo.b = bstr .size 0\ndemo.u = { p: [], q: bstr .size 0 }\n"
    )
    for (stem, family) in [
      ("Done_event", "EVENT"), ("E", "MAP"), ("T", "TUPLE"), ("B", "BSTR")
    ]:
      check (
        "typedef struct logos_demo_" & stem & "_" & family &
        "{uint8_t _empty;}logos_demo_" & stem & "_t;"
      ) in got
    check "typedef struct logos_demo_U_MAP{logos_tuple_size_0_t p;logos_bstr_size_0_t q;}logos_demo_U_t;" in
      got
    let fixed = cItems(logosTypesHeader())
    for item in cItems(mirror("IFC/2.3.empty.h")):
      check item in fixed

  test "[IFC-0142] [IFC-0145] [IFC-0147] [IFC-0634] [IFC-0635] [IFC-0639] a symbolic choice: labels in ASCII order, uint32_t kind":
    check sameSet(
      decls(mirror("IFC/2.3.value.cddl")),
      cItems(mirror("IFC/2.3.value.h")) &
        "#define LOGOS_SUPPORTING_NAMESPACE_storage \"storage\"",
    )

  test "[IFC-0148] [IFC-0645] [IFC-0647] a tagged map union: arm maps keep their tag fields; File = 1, Dir = 0":
    let got = decls(mirror("IFC/2.3.entry.cddl"))
    for m in cItems(mirror("IFC/2.3.entry-literals.h")):
      check m in got
    check "#define LOGOS_ARM_storage_Entry_CASE_Dir 0u" in got
    check "#define LOGOS_ARM_storage_Entry_CASE_File 1u" in got
    check "typedef struct logos_storage_Entry_AR_File_MAP{const char*kind;const char*path;}logos_storage_Entry_AR_File_t;" in
      got
    check "typedef struct logos_storage_Entry_AR_Dir_MAP{const char*const*entries;size_t entries_count;const char*kind;const char*path;}logos_storage_Entry_AR_Dir_t;" in
      got
    check "typedef struct logos_storage_Entry_CHOICE{logos_storage_Entry_KIND_t kind;union{logos_storage_Entry_AR_Dir_t arm_Dir;logos_storage_Entry_AR_File_t arm_File;}value;}logos_storage_Entry_t;" in
      got

  test "[IFC-0149] nested inline composites are named by owner and path":
    let got = decls(mirror("IFC/2.3.record.cddl"))
    check "typedef struct logos_storage_Record_Sub_MAP{logos_storage_Record_Sub_Inner_t inner;}logos_storage_Record_Sub_t;" in
      got
    check "typedef uint32_t logos_storage_Record_Sub_Inner_KIND_t;" in got
    check "typedef struct logos_storage_Record_MAP{logos_storage_Record_Sub_t sub;}logos_storage_Record_t;" in
      got

  test "[IFC-0172] [IFC-0173] a map-bodied event is an event struct":
    let source = "_interface = \"storage\"\n" & mirror("IFC/2.5.event.cddl")
    check sameSet(
      decls(source),
      cItems(mirror("IFC/2.5.event.h")) &
        "#define LOGOS_INTERFACE_NAMESPACE_storage \"storage\"",
    )

  test "[IFC-0872] generated literals: zero, the uint64 maximum, -1, the int64 minimum, escaped text":
    let source = """demo.lits = {
  a: 0,
  b: 18446744073709551615,
  c: -1,
  d: -9223372036854775808,
  e: true,
  f: "é1",
  g: "a??=b",
}
"""
    let got = decls(source)
    for (field, value) in [
      ("A", "UINT64_C(0)"),
      ("B", "UINT64_C(18446744073709551615)"),
      ("C", "(-INT64_C(1))"),
      ("D", "(-INT64_C(9223372036854775807)- INT64_C(1))"),
      ("E", "true"),
      ("F", "\"\\303\\2511\""),
      ("G", "\"a\\?\\?=b\""),
    ]:
      check ("#define LOGOS_LITERAL_demo_Lits_" & field & " " & value) in got
    check "{uint64_t a;uint64_t b;int64_t c;int64_t d;bool e;const char*f;const char*g;}" in
      got.text
    # The values survive compilation in every language mode.
    let h = contractHeader(accepted(source).cSchemaSet).get
    createDir(outDir)
    writeFile(outDir / "lits_types.h", h)
    checkCompiles compileUnit(
      "lits",
      "#include \"lits_types.h\"\n" & staticAssert &
        "CHECK(LOGOS_LITERAL_demo_Lits_A == 0);\n" &
        "CHECK(LOGOS_LITERAL_demo_Lits_B == UINT64_MAX);\n" &
        "CHECK(LOGOS_LITERAL_demo_Lits_C == -1);\n" &
        "CHECK(LOGOS_LITERAL_demo_Lits_D == INT64_MIN);\n" &
        "CHECK(LOGOS_LITERAL_demo_Lits_E == true);\n" &
        "CHECK(sizeof(LOGOS_LITERAL_demo_Lits_F) == 4);\n" &
        "CHECK(sizeof(LOGOS_LITERAL_demo_Lits_G) == 6);\n",
    )

  test "§2.3 text literals: printable ASCII as is, three-digit octal for every other byte":
    check cStringLiteral("a\"b\\c?\n\r\t\x01\x7Fé1") ==
      "\"a\\\"b\\\\c\\?\\n\\r\\t\\001\\177\\303\\2511\""

suite "ifc.c-types: choices (INTERFACE §2.3, §3.9.9)":
  test "[IFC-0639] [IFC-0643] [IFC-0906] symbolic labels: primitive, literal, tagged and untagged map, list, tuple, reference":
    # A supporting schema uses no other supporting schema (§1.1): the reference
    # to ext.types.w is made from a module.
    let got = decls(
      module(
        "demo.num = int16 / tstr\n" &
          "demo.mode = \"on\" / \"off-line\" / 7 / -2 / true\n" &
          "demo.shape = { w: uint64, h: uint64 } / { r: uint64, ? z: bool }\n" &
          "demo.seqs = [* uint64] / tstr\ndemo.tup = [uint64, tstr] / uint64\n" &
          "demo.v = { x: uint64 }\n" & "demo.r = demo.v / ext.types.w\n" & ping
      ),
      supp = ["ext.types.w = tstr\n"],
    )
    for (stem, labels) in [
      ("demo_Num", @["Int16", "Tstr"]),
      ("demo_Mode", @["Neg2", "Num7", "Off_line", "On", "True"]),
      ("demo_Shape", @["Map_h_w", "Map_r"]),
      ("demo_Seqs", @["List", "Tstr"]),
      ("demo_Tup", @["Tuple2", "Uint64"]),
      ("demo_R", @["demo_V", "ext_NS_types_W"]),
    ]:
      for i, l in labels:
        check ("#define LOGOS_ARM_" & stem & "_CASE_" & l & " " & $i & "u") in got
    # int16 / tstr: canonical order is tstr first; the C order is the labels'.
    let num = accepted("demo.num = int16 / tstr\n").primary.model.find("demo.num").get
    check num.body.arms[0].scalar == skTstr

  test "[IFC-0638] [IFC-0640] [IFC-0641] [IFC-0646] [IFC-0907] whole-choice indexed form: a literal field with no token, duplicate labels":
    let s = accepted(
      "demo.bad = { k: \"a b\", x: uint64 } / { k: \"c\" }\n" &
        "demo.dup = \"a-b\" / \"a_b\"\n"
    )
    let got = decls(s)
    let bad = s.primary.model.find("demo.bad").get.body
    for i, arm in bad.arms:
      check ("#define LOGOS_ARM_demo_Bad_CASE" & $i & " " & $i & "u") in got
      let lit = arm.fields.filterIt(it.name == "k")[0].node.literal.text
      check ("#define LOGOS_LITERAL_demo_Bad_AR" & $i & "_K \"" & lit & "\"") in got
      check ("logos_demo_Bad_AR" & $i & "_t arm_" & $i & ";") in got.text
    check "LOGOS_ARM_demo_Bad_CASE_" notin got.text
    let dup = s.primary.model.find("demo.dup").get.body
    for i, arm in dup.arms:
      check ("#define LOGOS_ARM_demo_Dup_CASE" & $i & " " & $i & "u") in got
      check ("#define LOGOS_LITERAL_demo_Dup_AR" & $i & " \"" & arm.literal.text & "\"") in
        got

  test "[IFC-0908] nested choices choose their forms independently; labels follow UTF-8 field order":
    let s = accepted(
      "demo.nest = { inner: \"x-y\" / \"x_y\" } / { k: \"p\", v: uint64 / tstr }\n" &
        "demo.order = { bb: \"x\", c: \"y\" } / { bb: \"z\" }\n"
    )
    let got = decls(s)
    check "#define LOGOS_ARM_demo_Nest_CASE_Map_inner 0u" in got
    check "#define LOGOS_ARM_demo_Nest_CASE_P 1u" in got
    let inner =
      s.primary.model.find("demo.nest").get.body.arms.filterIt(it.fields.len == 1)[0].fields[
        0
      ].node
    for i in 0 ..< inner.arms.len:
      check (
        "#define LOGOS_ARM_demo_Nest_AR_Map_inner_Inner_CASE" & $i & " " & $i & "u"
      ) in got
    check "#define LOGOS_ARM_demo_Nest_AR_P_V_CASE_Tstr 0u" in got
    # "bb" sorts before "c" as UTF-8 text; its encoded CBOR key sorts after.
    check "#define LOGOS_ARM_demo_Order_CASE_X_y 0u" in got
    check "#define LOGOS_ARM_demo_Order_CASE_Z 1u" in got

  test "[IFC-0644] [IFC-0911] direct literal arms have no union member; references to named literals keep theirs":
    let got = decls(
      "demo.flag = \"on\" / \"off\"\ndemo.leaf = \"leaf\"\n" &
        "demo.mixed = \"none\" / uint64 / demo.leaf\n"
    )
    check "typedef struct logos_demo_Flag_CHOICE{logos_demo_Flag_KIND_t kind;}logos_demo_Flag_t;" in
      got
    check "#define LOGOS_LITERAL_demo_Flag_AR_On \"on\"" in got
    check "typedef struct logos_demo_Mixed_CHOICE{logos_demo_Mixed_KIND_t kind;union{uint64_t arm_Uint64;logos_demo_Leaf_t arm_demo_Leaf;}value;}logos_demo_Mixed_t;" in
      got
    check "#define LOGOS_LITERAL_demo_Mixed_AR_None \"none\"" in got
    check "#define LOGOS_ARM_demo_Mixed_CASE_None 0u" in got

  test "[IFC-0866] [IFC-0867] a choice-valued event body is an ordinary choice without a wrapper":
    let got = decls(
      "_interface = \"demo\"\ndemo.changed_event = { kind: \"a\", x: uint64 } / { kind: \"b\" }\n"
    )
    check "typedef struct logos_demo_Changed_event_CHOICE{logos_demo_Changed_event_KIND_t kind;union{logos_demo_Changed_event_AR_A_t arm_A;logos_demo_Changed_event_AR_B_t arm_B;}value;}logos_demo_Changed_event_t;" in
      got
    check "#define LOGOS_LITERAL_demo_Changed_event_AR_A_Kind \"a\"" in got
    check "_EVENT" notin got.text

  test "[IFC-0635] [IFC-0912] the discriminant stays uint32_t whatever the enum storage":
    let s = accepted(mirror("IFC/2.3.value.cddl"))
    createDir(outDir)
    writeFile(outDir / "kind_types.h", header(s))
    checkCompiles compileUnit(
      "kind_width",
      "#include \"kind_types.h\"\n" & staticAssert &
        "CHECK(sizeof(logos_storage_Value_KIND_t) == 4);\n" &
        "CHECK((logos_storage_Value_KIND_t)-1 > 0);\n" &
        "CHECK(LOGOS_ARM_storage_Value_CASE_Uint64 == 2);\n",
      " -fshort-enums",
    )

suite "ifc.c-types: paths and aggregates (INTERFACE §2.1, §2.3, §3.9.10)":
  test "[IFC-0632] tuples, lists and byte strings as choice arms or list elements are one aggregate value":
    let got = decls(
      "demo.pair = [uint64] / [uint64, uint64]\n" &
        "demo.rows = { names: [* [* tstr]], blobs: [* bstr], cells: [* [uint64, tstr]], " &
        "digests: [* bstr .size 32], empties: [* []] }\n"
    )
    check "typedef struct logos_demo_Pair_AR_Tuple1_TUPLE{uint64_t item_0;}logos_demo_Pair_AR_Tuple1_t;" in
      got
    check "typedef struct logos_demo_Pair_AR_Tuple2_TUPLE{uint64_t item_0;uint64_t item_1;}logos_demo_Pair_AR_Tuple2_t;" in
      got
    check "typedef struct logos_demo_Rows_Names_LI_LIST{const char*const*items;size_t count;}logos_demo_Rows_Names_LI_t;" in
      got
    check "typedef struct logos_demo_Rows_Blobs_LI_BSTR{const uint8_t*data;size_t len;}logos_demo_Rows_Blobs_LI_t;" in
      got
    check "typedef struct logos_demo_Rows_Digests_LI_BSTR{uint8_t data[32];}logos_demo_Rows_Digests_LI_t;" in
      got
    check "typedef struct logos_demo_Rows_Cells_LI_TUPLE{uint64_t item_0;const char*item_1;}logos_demo_Rows_Cells_LI_t;" in
      got
    check "typedef struct logos_demo_Rows_MAP{const logos_demo_Rows_Blobs_LI_t*blobs;size_t blobs_count;const logos_demo_Rows_Cells_LI_t*cells;size_t cells_count;const logos_demo_Rows_Digests_LI_t*digests;size_t digests_count;const logos_tuple_size_0_t*empties;size_t empties_count;const logos_demo_Rows_Names_LI_t*names;size_t names_count;}logos_demo_Rows_t;" in
      got

  test "[IFC-0631] an optional inline tuple has one has_ flag before its first member":
    let got =
      decls("demo.x = { ? p: [uint64, tstr], ? e: [], n: [uint64, [uint64, bstr]] }\n")
    check "typedef struct logos_demo_X_MAP{bool has_e;logos_tuple_size_0_t e;uint64_t n_0;logos_demo_X_N_TU1_t n_1;bool has_p;uint64_t p_0;const char*p_1;}logos_demo_X_t;" in
      got
    check "typedef struct logos_demo_X_N_TU1_TUPLE{uint64_t item_0;logos_demo_X_N_TU1_TU1_t item_1;}logos_demo_X_N_TU1_t;" in
      got
    check "typedef struct logos_demo_X_N_TU1_TU1_BSTR{const uint8_t*data;size_t len;}logos_demo_X_N_TU1_TU1_t;" in
      got

  test "[IFC-0914] [IFC-0915] [IFC-0916] complete paths: left_right vs left.right, every list and tuple step, equal shapes apart":
    let got = decls(
      "demo.left = { right: { v: \"l\" } }\ndemo.left_right = { v: \"r\" }\n" &
        "demo.deep = { a: [* [uint64, [* { k: \"z\" }]]] }\n" &
        "demo.two = { a: { x: uint64 }, b: { x: uint64 } }\n"
    )
    check "#define LOGOS_LITERAL_demo_Left_Right_V \"l\"" in got
    check "#define LOGOS_LITERAL_demo_Left_right_V \"r\"" in got
    check "typedef struct logos_demo_Left_Right_MAP{const char*v;}logos_demo_Left_Right_t;" in
      got
    check "typedef struct logos_demo_Left_right_MAP{const char*v;}logos_demo_Left_right_t;" in
      got
    check "#define LOGOS_LITERAL_demo_Deep_A_LI_TU1_LI_K \"z\"" in got
    check "typedef struct logos_demo_Deep_A_LI_TU1_LI_MAP{const char*k;}logos_demo_Deep_A_LI_TU1_LI_t;" in
      got
    check "typedef struct logos_demo_Deep_A_LI_TUPLE{uint64_t item_0;logos_demo_Deep_A_LI_TU1_t item_1;}logos_demo_Deep_A_LI_t;" in
      got
    check "typedef struct logos_demo_Two_A_MAP{uint64_t x;}logos_demo_Two_A_t;" in got
    check "typedef struct logos_demo_Two_B_MAP{uint64_t x;}logos_demo_Two_B_t;" in got

  test "[IFC-0633] an aggregate a list points into from its own cycle is forward-declared":
    check sameSet(
      decls("demo.node = { kids: [* demo.node], v: uint64 }\n"),
      @[
        "#define LOGOS_SUPPORTING_NAMESPACE_demo \"demo\"",
        "typedef struct logos_demo_Node_MAP logos_demo_Node_t;",
        "struct logos_demo_Node_MAP{const logos_demo_Node_t*kids;size_t kids_count;uint64_t v;};",
      ],
    )
    check sameSet(
      decls("demo.a = { bs: [* demo.b] }\ndemo.b = { a: demo.a }\n"),
      @[
        "#define LOGOS_SUPPORTING_NAMESPACE_demo \"demo\"",
        "typedef struct logos_demo_B_MAP logos_demo_B_t;",
        "typedef struct logos_demo_A_MAP{const logos_demo_B_t*bs;size_t bs_count;}logos_demo_A_t;",
        "struct logos_demo_B_MAP{logos_demo_A_t a;};",
      ],
    )
    checkCompiles compilesSet(
      "forwards", accepted("demo.a = { bs: [* demo.b] }\ndemo.b = { a: demo.a }\n")
    )

suite "ifc.c-types: logos_types.h and compiled headers (INTERFACE §3.9.6, §5.2)":
  test "[IFC-0603] [IFC-0934] logos_types.h holds the §5.2 block, the §2.3 empty types and the common types":
    let h = logosTypesHeader()
    let fixed = cItems(h)
    for item in cItems(mirror("IFC/5.2.logos_types.h")):
      if "<module-C>" notin item:
        check item in fixed
    # [IMPL-DECISION G158, pending] The common types' interim names.
    for name in [
      "logos_error_detail_t", "logos_invalid_params_reason_t",
      "logos_invalid_params_path_segment_t", "logos_invalid_params_detail_t",
      "logos_schema_commitment_t",
    ]:
      check fixed.anyIt(it.endsWith("}" & name & ";"))
    # [SPEC INTERFACE §2.1] No choice declaration for logos.error_code.
    check "LOGOS_ARM_error_code" notin h
    check "#define LOGOS_LITERAL_schema_commitment_Hash_suite \"logos.hash-suite.blake3-256\"" in
      fixed
    check ("PROVISIONAL ABI (spec " & SpecRevision[0 .. 7] & ")") in h
    checkCompiles compileUnit("logos_types_only", "#include \"logos_types.h\"\n")

  test "[IFC-0297] [IFC-0475] contract headers include logos_types.h and redeclare none of its types":
    let s = accepted(mod392, [ifc392], [sup392])
    let h = header(s)
    check "#include \"logos_types.h\"" in h
    check ("PROVISIONAL ABI (spec " & SpecRevision[0 .. 7] & ")") in h
    check s.cSchemaSet.headerName == "sensor_module"
    var fixedNames: seq[string]
    for item in cItems(logosTypesHeader()):
      if item.startsWith("typedef"):
        fixedNames.add(item.split({'}', ' ', '*', ')'})[^1].strip(chars = {';'}))
    for c in [h, header(accepted(mirror("IFC/1.8.module.cddl")))]:
      for item in cItems(c):
        if item.startsWith("typedef"):
          check item.split({'}', ' ', '*'})[^1].strip(chars = {';'}) notin fixedNames

  test "[IFC-0585] [IFC-0629] [IFC-0633] [IFC-0891] generated headers compile as C17, C23, C++17, C++20 and C++23":
    checkCompiles compilesSet("ifc392", accepted(mod392, [ifc392], [sup392]))
    checkCompiles compilesSet("ifc391", accepted(mirror("IFC/3.9.1.module.cddl")))
    checkCompiles compilesSet("ifc393", accepted(mirror("IFC/3.9.3.module.cddl")))
    checkCompiles compilesSet("ifc23", accepted(mirror("IFC/2.3.entry.cddl")))
    checkCompiles compilesSet("storage", accepted(mirror("IFC/1.8.module.cddl")))
    checkCompiles compilesSet(
      "kitchen",
      accepted(
        """demo.k = {
  a: 7, b: -9223372036854775808, c: "é1",
  d: bstr .size 32, e: [* bstr .size 4], f: [* [uint64, tstr]],
  g: demo.v / [uint64] / [uint64, uint64], ? h: [uint64, bstr],
  i: logos.schema_commitment, j: [], l: bstr .size 0,
  m: "on" / "off" / demo.v, n: [* demo.mode],
}
demo.v = { x: uint64 }
demo.mode = "a" / "b"
demo.tree = { ? left: demo.tree, kids: [* demo.tree], t: [demo.tree / uint64] }
"""
      ),
    )

# Method typedefs, provider functions and module symbols ------------------------------

proc linkRun(name, cSource, cxxSource: string): string =
  ## Compiles `cSource` as C17 and `cxxSource` as C++17 next to the headers in
  ## `outDir`, links them with the C++ compiler and runs the program: "" when it
  ## exits 0, else the first failure. Proves C linkage and symbol distinctions
  ## through the native toolchain (§3.9.6, §3.9.7).
  createDir(outDir)
  writeFile(outDir / "logos_types.h", logosTypesHeader())
  let (cc, cxx) = (compilerFor(false), compilerFor(true))
  if cc.len == 0 or cxx.len == 0:
    return "no C or C++ compiler on PATH"
  let base = outDir / name
  writeFile(base & "_impl.c", cSource)
  writeFile(base & "_main.cpp", cxxSource)
  let exe = base & (when defined(windows): ".exe" else: "")
  for cmd in [
    quoteShell(cc) & " -std=c17 -Wall -Werror -I " & quoteShell(outDir) & " -c " &
      quoteShell(base & "_impl.c") & " -o " & quoteShell(base & "_impl.o"),
    quoteShell(cxx) & " -std=c++17 -Wall -Werror -I " & quoteShell(outDir) & " -c " &
      quoteShell(base & "_main.cpp") & " -o " & quoteShell(base & "_main.o"),
    quoteShell(cxx) & " " & quoteShell(base & "_impl.o") & " " &
      quoteShell(base & "_main.o") & " -o " & quoteShell(exe),
    quoteShell(exe),
  ]:
    let (o, code) = execCmdEx(cmd)
    if code != 0:
      return cmd & ":\n" & o
  ""

proc fnItem(text: string): string =
  ## One C declaration, normalized like `cItems`.
  let items = cItems(text)
  doAssert items.len == 1, text
  items[0]

suite "ifc.c-abi: method typedefs, provider functions and module symbols (INTERFACE §2.4, §2.6, §3.9.4, §3.9.8)":
  test "[IFC-0154] [IFC-0155] [IFC-0156] [IFC-0164] §2.4: the storage.exists typedef and provider function":
    let got = decls(module(mirror("IFC/2.4.exists.cddl"), "storage_module"))
    let want = cItems(mirror("IFC/2.4.exists.h"))
    check want.len == 2
    for item in want:
      check item in got

  test "[IFC-0158] [IFC-0159] [IFC-0160] [IFC-0392] §2.4, §3.9.4: one wrapper parameter for each choice-valued half":
    let source = module(
      mirror("IFC/2.4.resolve.cddl") & """
storage.report_request = { id: uint64 }
storage.report_response =
    { kind: "found", size: uint64 } /
    { kind: "missing" }
""",
      "storage_module",
    )
    let got = decls(source)
    check cItems(mirror("IFC/2.4.resolve.h"))[0] in got
    check fnItem(
      """typedef logos_result_t (*logos_storage_Report_FN_t)(
    logos_module_context_t* module,
    logos_response_owner_t* response_owner,
    uint64_t in_id,
    logos_storage_Report_response_t* out_response
);"""
    ) in got
    # The provider functions take exactly the typedefs' parameters, and each
    # choice-valued half is one wrapper with no flattened arm field beside it.
    for (m, params) in [
      (
        "Resolve",
        "(logos_module_context_t*module,logos_response_owner_t*response_owner," &
          "const logos_storage_Resolve_request_t*in_request,bool*out_matched);",
      ),
      (
        "Report",
        "(logos_module_context_t*module,logos_response_owner_t*response_owner," &
          "uint64_t in_id,logos_storage_Report_response_t*out_response);",
      ),
    ]:
      check ("logos_result_t logos_storage_module_CALL_storage_" & m & params) in got
      check ("typedef logos_result_t(*logos_storage_" & m & "_FN_t)" & params) in got
    checkCompiles compilesSet("abi394", accepted(source))

  test "[IFC-0165] [IFC-0166] [IFC-0167] §2.4: an empty request adds no parameter; a struct output is caller-allocated":
    let source = module(
      mirror("IFC/2.3.space_info.cddl") & mirror("IFC/2.4.space.cddl"), "storage_module"
    )
    let got = decls(source)
    check cItems(mirror("IFC/2.4.space.h"))[0] in got
    check fnItem(
      """typedef logos_result_t (*logos_storage_Space_FN_t)(
    logos_module_context_t* module,
    logos_response_owner_t* response_owner,
    logos_storage_Space_info_t* out_info
);"""
    ) in got

  test "[IFC-0168] [IFC-0169] [IFC-0170] §2.4: parameters follow canonical field order, not source order":
    let got = decls(module(mirror("IFC/2.4.upload_url.cddl"), "storage_module"))
    check cItems(mirror("IFC/2.4.upload_url.h"))[0] in got
    check cItems(mirror("IFC/3.3.upload_url.h"))[0] in got
    # An empty response has no output parameter (rule 7).
    let empty = decls(module(ping, "storage_module"))
    check fnItem(
      """typedef logos_result_t (*logos_demo_Ping_FN_t)(
    logos_module_context_t* module,
    logos_response_owner_t* response_owner
);"""
    ) in empty

  test "[IFC-0864] [IFC-0888] §2.4 rules 2-10: every field form as an input and as an output":
    const fields = """{
  a: uint32,
  ? b: tstr,
  c: tstr .size (1..64),
  d: bstr,
  e: bstr .size (1..4096),
  f: bstr .size 32,
  g: bstr .size 0,
  h: [* uint64],
  i: [* tstr],
  j: [* demo.rec],
  k: demo.rec,
  l: { x: uint64 },
  m: demo.mode,
  ? n: [uint64, [tstr, bool]],
  o: [],
  ? p: [],
  q: logos.error_code,
  r: "lit",
  class: uint8,
}
"""
    let source = module(
      "demo.rec = { v: uint64 }\ndemo.mode = \"a\" / \"b\"\n" & "demo.all_request = " &
        fields & "demo.all_response = " & fields
    )
    let got = decls(source)
    # I64: `out_d`, an unbounded byte string's output, is `const uint8_t**`.
    check fnItem(
      """typedef logos_result_t (*logos_demo_All_FN_t)(
    logos_module_context_t* module,
    logos_response_owner_t* response_owner,
    uint32_t in_a,
    bool in_has_b,
    const char* in_b,
    logos_tstr_size_1_64_t in_c,
    uint8_t in_class,
    const uint8_t* in_d,
    size_t in_d_len,
    logos_bstr_size_1_4096_t in_e,
    size_t in_e_len,
    const uint8_t (*in_f)[32],
    const logos_bstr_size_0_t* in_g,
    const uint64_t* in_h,
    size_t in_h_count,
    const char* const* in_i,
    size_t in_i_count,
    const logos_demo_Rec_t* in_j,
    size_t in_j_count,
    const logos_demo_Rec_t* in_k,
    const logos_demo_All_request_L_t* in_l,
    const logos_demo_Mode_t* in_m,
    bool in_has_n,
    uint64_t in_n_0,
    const logos_demo_All_request_N_TU1_t* in_n_1,
    const logos_tuple_size_0_t* in_o,
    bool in_has_p,
    const logos_tuple_size_0_t* in_p,
    logos_error_code_t in_q,
    const char* in_r,
    uint32_t* out_a,
    bool* out_has_b,
    const char** out_b,
    logos_tstr_size_1_64_t* out_c,
    uint8_t* out_class,
    const uint8_t** out_d,
    size_t* out_d_len,
    logos_bstr_size_1_4096_t* out_e,
    size_t* out_e_len,
    uint8_t (*out_f)[32],
    logos_bstr_size_0_t* out_g,
    uint64_t** out_h,
    size_t* out_h_count,
    const char*** out_i,
    size_t* out_i_count,
    logos_demo_Rec_t** out_j,
    size_t* out_j_count,
    logos_demo_Rec_t* out_k,
    logos_demo_All_response_L_t* out_l,
    logos_demo_Mode_t* out_m,
    bool* out_has_n,
    uint64_t* out_n_0,
    logos_demo_All_response_N_TU1_t* out_n_1,
    logos_tuple_size_0_t* out_o,
    bool* out_has_p,
    logos_tuple_size_0_t* out_p,
    logos_error_code_t* out_q,
    const char** out_r
);"""
    ) in got
    # The escape applies to the complete identifier: `in_class` needs none (§2.1).
    check "in_class_" notin got.text and "out_class_" notin got.text
    checkCompiles compilesSet("abiforms", accepted(source))

  test "[IFC-0903] §3.9.8: methods init, destroy and upload_url beside the lifecycle symbols":
    let source = module(
      "demo.init_request = {}\ndemo.init_response = {}\n" &
        "demo.destroy_request = {}\ndemo.destroy_response = {}\n" &
        "demo.upload_url_request = {}\ndemo.upload_url_response = {}\n",
      "x_module",
    )
    let got = decls(source).text
    for m in ["Init", "Destroy", "Upload_url"]:
      check ("(*logos_demo_" & m & "_FN_t)") in got
      check ("logos_result_t logos_x_module_CALL_demo_" & m & "(") in got
    check "logos_x_module_MODULE_init(" in got
    check "void logos_x_module_MODULE_destroy(" in got
    checkCompiles compilesSet("abi398", accepted(source))

  test "[IFC-0205] [IFC-0225] §2.6: the identity, lifecycle and provider symbols, without the optional hooks":
    let symbols = cItems(mirror("IFC/2.6.symbols.h")).mapIt(
        it.replace("<module-C>", "meter_module")
      )
    let got = decls(mirror("IFC/3.9.1.module.cddl"))
    check symbols.len == 7
    for s in symbols:
      # [IMPL] The optional hook is the module author's to declare.
      check (s in got) == ("_MODULE_apply_configuration(" notin s)
    check "_MODULE_async_api" notin got.text
    # Without a provider contract nothing beyond identity and lifecycle.
    let bare = decls(bound("bare_module").cSchemaSet)
    check bare.len == 3
    check bare.allIt(
      "_MODULE_name(" in it or "_MODULE_init(" in it or "_MODULE_destroy(" in it
    )

  test "[IFC-0586] [IFC-0623] [IFC-0892] [IFC-0896] [IFC-0897] provider functions keep C linkage and stay distinct through linking":
    let iface =
      "_interface = \"demo\"\ndemo.get_request = {}\ndemo.get_response = { n: uint64 }\n"
    # 63 bytes: the longest module names differ only in their last letter.
    let long = "m" & 'n'.repeat(60)
    var headers, impl, calls: string
    for (suffix, n) in [("_a", 1), ("_b", 2)]:
      let b = bound(long & suffix, ifaces = [iface])
      let h = contractHeader(b.cSchemaSet)
      check h.isOk
      writeFile(outDir / (long & suffix) & ".h", h.get)
      headers.add("#include \"" & long & suffix & ".h\"\n")
      let p = "logos_" & long & suffix
      impl.add(
        "logos_result_t " & p &
          "_CALL_demo_Get(logos_module_context_t* module, logos_response_owner_t* " &
          "response_owner, uint64_t* out_n) {\n  (void)module; (void)response_owner;\n" &
          "  *out_n = " & $n &
          ";\n  logos_result_t r = {LOGOS_OK, 0, 0, 0};\n  return r;\n}\n" &
          "const char* " & p & "_MODULE_name(void) { return \"" & long & suffix &
          "\"; }\n"
      )
      calls.add(
        "  { logos_demo_Get_FN_t f = &" & p & "_CALL_demo_Get;\n" &
          "    uint64_t n = 0; logos_response_owner_t o = {0, 0};\n" &
          "    if (f(0, &o, &n).code != LOGOS_OK || n != " & $n & ") return 1;\n" &
          "    if (std::strcmp(" & p & "_MODULE_name(), \"" & long & suffix &
          "\") != 0) return 2; }\n"
      )
    when deviceTarget:
      skip()
    else:
      check linkRun(
        "abilink",
        headers & impl,
        "#include <cstring>\n" & headers & "int main() {\n" & calls & "  return 0;\n}\n",
      ) == ""
