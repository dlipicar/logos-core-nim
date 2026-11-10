## INTERFACE §2, §2.1-§2.3, §2.5, §3.9.1-§3.9.4 (forward), §3.9.5 (forward
## rejection) and §5.2: the canonical C type mapping, compared with the spec's C
## blocks and compiled as C11.

import std/[algorithm, os, osproc, sequtils, strutils]
import unittest2
import ../src/logos_core/hash
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
  ## lines, include guards or function declarations (§2.4, §2.6: not generated).
  let s = withoutComments(text)
  var items: seq[string]
  var cur = ""
  var depth = 0
  var parenTop = false
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
    of '(':
      if depth == 0:
        parenTop = true
    of ';':
      if depth == 0:
        if not parenTop:
          items.add(norm(cur))
        cur = ""
        parenTop = false
    else:
      discard
    inc i
  items.filterIt(
    not (
      it.startsWith("#include") or it.startsWith("#ifndef") or it.startsWith("#endif") or
      (it.startsWith("#define") and it.splitWhitespace.len == 2)
    )
  )

proc decls(s: ContractSet): seq[string] =
  let r = cDeclarations(s.cSchemaSet)
  if r.isErr:
    checkpoint r.error
  cItems(r.get.join("\n\n"))

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

let
  ifc392 = mirror("IFC/3.9.2.interface.cddl")
  mod392 = mirror("IFC/3.9.2.module.cddl")
  sup392 = mirror("IFC/3.9.2.supporting.cddl")

# Compiling -------------------------------------------------------------------------

const outDir = "build/codegen"

proc compiles(name, header: string): string =
  ## Writes `logos_types.h` and `header` and compiles a translation unit that
  ## includes it as C11 with every warning an error; "" when it compiles.
  createDir(outDir)
  writeFile(outDir / "logos_types.h", logosTypesHeader())
  writeFile(outDir / name & ".h", header)
  writeFile(outDir / name & ".c", "#include \"" & name & ".h\"\n")
  let cc = findExe("cc")
  if cc.len == 0:
    return "no C compiler (cc) on PATH"
  # A wrapped clang (Nix) passes linker flags that -fsyntax-only leaves unused.
  let (version, _) = execCmdEx(quoteShell(cc) & " --version")
  let quiet = if "clang" in version: " -Qunused-arguments" else: ""
  let cmd =
    quoteShell(cc) & quiet &
    " -std=c11 -Wall -Wextra -Wpedantic -Werror -fsyntax-only -I " & quoteShell(outDir) &
    " " & quoteShell(outDir / name & ".c")
  let (output, code) = execCmdEx(cmd)
  if code == 0: "" else: output

proc compilesSet(name: string, s: ContractSet): string =
  let h = contractHeader(s.cSchemaSet)
  if h.isErr:
    return h.error
  compiles(name, h.get)

# Tests -----------------------------------------------------------------------------

suite "ifc.c-types: required C mapping cases (INTERFACE §3.9.1-§3.9.4)":
  test "[IFC-0116] [IFC-0360] [IFC-0361] [IFC-0362] [IFC-0363] [IFC-0364] [IFC-0365] [IFC-0367] §3.9.1: the declaration-only module":
    let got = decls(mirror("IFC/3.9.1.module.cddl"))
    check got == cItems(mirror("IFC/3.9.1.module.h"))
    check got.defines.len == 0

  test "[IFC-0117] [IFC-0370] [IFC-0371] [IFC-0372] [IFC-0373] [IFC-0374] [IFC-0375] [IFC-0376] [IFC-0377] [IFC-0378] [IFC-0379] [IFC-0380] [IFC-0382] §3.9.2: the metadata-extended construction set":
    let s = accepted(mod392, [ifc392], [sup392])
    check toHex(s.interfaces[0].root) ==
      "ca004a96bbbce568ab0e7f996020e12d0dca353603671d5d6d8d5e364b830d32"
    let got = decls(s)
    check got == cItems(mirror("IFC/3.9.2.module.h"))
    # Exactly the four metadata constants and the one literal macro shown.
    check got.defines.len == 5

  test "[IFC-0384] [IFC-0385] [IFC-0386] [IFC-0387] [IFC-0388] §3.9.3: recursive aggregate references":
    check decls(mirror("IFC/3.9.3.module.cddl")) == cItems(mirror("IFC/3.9.3.module.h"))

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
    let t = decls(source).text
    for half in ["resolve_request", "report_response"]:
      let stem = "storage_" & half
      check (
        "typedef enum{LOGOS_" & stem.toUpperAscii & "_ARM_0=0,LOGOS_" & stem.toUpperAscii &
        "_ARM_1=1,}logos_" & stem & "_kind_t;"
      ) in t
      check (
        "typedef struct logos_choice_" & stem & "{logos_" & stem &
        "_kind_t kind;union{logos_" & stem & "_arm_0_map_t arm_0;logos_" & stem &
        "_arm_1_map_t arm_1;}value;}logos_" & stem & "_t;"
      ) in t
    # The map-valued halves stay flattened (§2.4): no aggregate of their own.
    check "logos_storage_resolve_response_t" notin t
    check "logos_storage_report_request_t" notin t
    check compilesSet("ifc394", accepted(source)) == ""

  test "[IFC-0119] the same accepted set always yields the same declarations":
    let a = decls(mod392, [ifc392], [sup392])
    let reordered = mod392.replace(
      "sensor.control.settings = {\n  kind: \"sensor\",\n  limit: metrics_types.counter,\n}",
      "sensor.control.settings = {\n  limit: metrics_types.counter,\n  kind: \"sensor\",\n}",
    )
    check reordered != mod392
    check decls(reordered, [ifc392], [sup392]) == a

suite "ifc.c-types: naming and schema metadata (INTERFACE §2, §2.1)":
  test "[IFC-0121] the §2.1 multi-document constants: primary, implements, interface, supporting":
    let source = module(
      implementing(rootOf(ifc392)) &
        "storage.tag_request = { tag: storage_types.tag }\nstorage.tag_response = {}\n",
      "storage_module",
    )
    let got = decls(source, [ifc392], ["storage_types.tag = tstr\n"])
    check got.defines == cItems(mirror("IFC/2.1.namespaces.h"))

  test "[IFC-0122] a dotted primary namespace keeps its exact value; its types keep the complete projection":
    let source = module(
      "logos.runtime_control.state = { phase: uint64 }\n" &
        "logos.runtime_control.ping_request = {}\nlogos.runtime_control.ping_response = {}\n",
      "logos_runtime_control",
    )
    let got = decls(source, opts = AcceptOptions(system: true))
    check got.defines == cItems(mirror("IFC/2.1.dotted-namespace.h"))
    check "logos_logos_runtime_control_state_t" in got.text

  test "[IFC-0115] [IFC-0116] [IFC-0117] [IFC-0367] a role constant only where §3.2 cannot recover the role":
    # One simple document whose role its contents show: none.
    check decls(module(ping)).defines.len == 0
    check decls("demo.x = uint64\n").defines.len == 0
    check decls("_interface = \"demo\"\n" & ping).defines.len == 0
    # A types-only interface would read back as a supporting schema.
    check decls("_interface = \"demo\"\ndemo.x = uint64\n").defines ==
      @["#define LOGOS_DEMO_INTERFACE_NAMESPACE \"demo\""]
    # A namespace that is not simple.
    check decls("demo_types.x = uint64\n").defines ==
      @["#define LOGOS_DEMO_TYPES_SUPPORTING_NAMESPACE \"demo_types\""]
    check decls(module("demo.sub.ping_request = {}\ndemo.sub.ping_response = {}\n")).defines ==
      @["#define LOGOS_DEMO_MODULE_PRIMARY_NAMESPACE \"demo.sub\""]

  test "[IFC-0118] [IFC-0123] [IFC-0396] §3.9.5: a namespace-projection collision rejects the set":
    let iface = "_interface = \"a.b\"\na.b.get_request = {}\na.b.get_response = {}\n"
    let source = module(
      implementing(rootOf(iface)) &
        "demo.get2_request = { v: a_b.value }\ndemo.get2_response = {}\n"
    )
    check "namespace-projection collision" in
      rejection(source, [iface], ["a_b.value = uint64\n"])

  test "[IFC-0123] two derivations of one C identifier reject the set":
    # The inline map at demo.a field b and the named map demo.a_b share a tag.
    check "C identifier collision: logos_map_demo_a_b" in
      rejection("demo.a = { b: { c: uint64 } }\ndemo.a_b = { d: uint64 }\n")
    # A named type spelled like an inline composite's typedef.
    check "C identifier collision: logos_demo_x_y_map_t" in
      rejection("demo.x = { y: { z: uint64 } }\ndemo.x_y_map = uint64\n")

  test "[IFC-0475] NX-04 interim: an identifier logos_types.h declares rejects the set":
    check "logos_types.h" in rejection("module.context = uint64\n")
    check "logos_types.h" in rejection("schema.commitment = { x: uint64 }\n")

  test "§2.1 common types use one logos_ prefix; logos.error_code is the status enum":
    let t = decls(
      "demo.x = { code: logos.error_code, d: logos.error_detail, c: logos.schema_commitment }\n"
    ).text
    check "logos_error_code_t code;" in t
    check "logos_error_detail_t d;" in t
    check "logos_schema_commitment_t c;" in t

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
    check "typedef struct logos_map_demo_x{logos_tstr_size_64_t a;logos_tstr_size_1_64_t b;logos_bstr_size_1_4096_t c;size_t c_len;}logos_demo_x_t;" in
      got

  test "[IFC-0129] [IFC-0135] exact byte strings are arrays; pairs stay adjacent":
    let t = decls(
      "demo.x = { digest: bstr .size 32, data: bstr, xs: [* uint64], z: bstr .size 0 }\n"
    ).text
    check cItems(mirror("IFC/2.2.exact-bstr.h"))[0] in t
    check "{const uint8_t*data;size_t data_len;uint8_t digest[32];const uint64_t*xs;size_t xs_count;logos_bstr_size_0_t z;}" in
      t

  test "[IFC-0131] [IFC-0132] [IFC-0133] [IFC-0134] maps in field order, has_ flags beside their field":
    check decls(mirror("IFC/2.3.space_info.cddl")) ==
      cItems(mirror("IFC/2.3.space_info.h"))
    check decls(mirror("IFC/2.3.peer_info.cddl")) ==
      cItems(mirror("IFC/2.3.peer_info.h"))

  test "[IFC-0136] [IFC-0138] empty values hold one uint8_t _empty":
    let t = decls(
      "_interface = \"demo\"\ndemo.done_event = {}\n" &
        "demo.e = {}\ndemo.t = []\ndemo.b = bstr .size 0\ndemo.u = { p: [], q: bstr .size 0 }\n"
    ).text
    for (tag, name) in [
      ("event_demo_done_event", "demo_done_event"),
      ("map_demo_e", "demo_e"),
      ("tuple_demo_t", "demo_t"),
      ("bstr_demo_b", "demo_b"),
    ]:
      check ("typedef struct logos_" & tag & "{uint8_t _empty;}logos_" & name & "_t;") in
        t
    check "{logos_tuple_size_0_t p;logos_bstr_size_0_t q;}" in t
    let fixed = cItems(logosTypesHeader())
    for item in cItems(mirror("IFC/2.3.empty.h")):
      check item in fixed

  test "[IFC-0142] [IFC-0143] [IFC-0145] [IFC-0147] a choice in canonical arm order":
    check decls(mirror("IFC/2.3.value.cddl")) == cItems(mirror("IFC/2.3.value.h"))

  test "[IFC-0148] [IFC-0150] [IFC-0152] a tagged map union: arm maps, kept tag fields, literal macros":
    let got = decls(mirror("IFC/2.3.entry.cddl"))
    for m in cItems(mirror("IFC/2.3.entry-literals.h")):
      check m in got
    let t = got.text
    check "typedef struct logos_map_storage_entry_arm_0{const char*kind;const char*path;}logos_storage_entry_arm_0_map_t;" in
      t
    check "typedef struct logos_map_storage_entry_arm_1{const char*const*entries;size_t entries_count;const char*kind;const char*path;}logos_storage_entry_arm_1_map_t;" in
      t
    check "logos_storage_entry_kind_t kind;union{logos_storage_entry_arm_0_map_t arm_0;logos_storage_entry_arm_1_map_t arm_1;}value;" in
      t

  test "[IFC-0149] nested inline composites are named by owner and path":
    let t = decls(mirror("IFC/2.3.record.cddl")).text
    check "typedef struct logos_map_storage_record_sub{logos_storage_record_sub_inner_choice_t inner;}logos_storage_record_sub_map_t;" in
      t
    check "}logos_storage_record_sub_inner_choice_kind_t;" in t
    check "typedef struct logos_choice_storage_record_sub_inner{" in t
    check "typedef struct logos_map_storage_record{logos_storage_record_sub_map_t sub;}logos_storage_record_t;" in
      t

  test "[IFC-0172] [IFC-0173] a map-bodied event is an event struct":
    let source = "_interface = \"storage\"\n" & mirror("IFC/2.5.event.cddl")
    check decls(source) == cItems(mirror("IFC/2.5.event.h"))

  test "[IFC-0141] literal fields keep their scalar type and get one macro each":
    let t = decls(
      """demo.lits = {
  a: 7,
  b: -5,
  c: -9223372036854775808,
  d: true,
  e: "é1",
  f: "a??=b",
}
"""
    ).text
    check "#define LOGOS_DEMO_LITS_A_LITERAL UINT64_C(7)" in t
    check "#define LOGOS_DEMO_LITS_B_LITERAL INT64_C(-5)" in t
    check cItems(
      "#define LOGOS_DEMO_LITS_C_LITERAL (-INT64_C(9223372036854775807) - 1)"
    )[0] in t
    check "#define LOGOS_DEMO_LITS_D_LITERAL true" in t
    # [IMPL-DECISION G65] \xNN escapes; a following hex digit starts a new literal.
    check "#define LOGOS_DEMO_LITS_E_LITERAL \"\\xc3\\xa9\"\"1\"" in t
    check "#define LOGOS_DEMO_LITS_F_LITERAL \"a?\\?=b\"" in t
    check "{uint64_t a;int64_t b;int64_t c;bool d;const char*e;const char*f;}" in t

suite "ifc.c-types: recorded mapping decisions (G62-G66, G72, G154)":
  test "G62: tuples, lists and byte strings as choice arms or list elements are path-named structs":
    let t = decls(
      "demo.pair = [uint64] / [uint64, uint64]\n" &
        "demo.rows = { names: [* [* tstr]], blobs: [* bstr], cells: [* [uint64, tstr]] }\n"
    ).text
    check "typedef struct logos_tuple_demo_pair_arm_0{uint64_t item_0;}logos_demo_pair_arm_0_tuple_t;" in
      t
    check "typedef struct logos_tuple_demo_pair_arm_1{uint64_t item_0;uint64_t item_1;}logos_demo_pair_arm_1_tuple_t;" in
      t
    check "typedef struct logos_list_demo_rows_names_list_item{const char*const*items;size_t count;}logos_demo_rows_names_list_item_list_t;" in
      t
    check "typedef struct logos_bstr_demo_rows_blobs_list_item{const uint8_t*data;size_t len;}logos_demo_rows_blobs_list_item_bstr_t;" in
      t
    check "{const logos_demo_rows_blobs_list_item_bstr_t*blobs;size_t blobs_count;const logos_demo_rows_cells_list_item_tuple_t*cells;size_t cells_count;const logos_demo_rows_names_list_item_list_t*names;size_t names_count;}" in
      t

  test "G63: a choice-of-maps event is a choice with the event tag":
    let t = decls(
      "_interface = \"demo\"\ndemo.changed_event = { kind: \"a\", x: uint64 } / { kind: \"b\" }\n"
    ).text
    check "typedef struct logos_event_demo_changed_event{logos_demo_changed_event_kind_t kind;union{" in
      t
    # Canonical arm order: the shorter map first.
    check "#define LOGOS_DEMO_CHANGED_EVENT_ARM_0_KIND_LITERAL \"b\"" in t
    check "#define LOGOS_DEMO_CHANGED_EVENT_ARM_1_KIND_LITERAL \"a\"" in t

  test "G66: an optional inline tuple has its has_ flag before its first member":
    check "{bool has_p;uint64_t p_0;const char*p_1;}" in
      decls("demo.x = { ? p: [uint64, tstr] }\n").text

  test "G72: constants, literal macros, constraint typedefs, forward typedefs, definitions":
    let got = decls(
      module(
        "demo.a = { k: \"x\", s: tstr .size 3, n: demo.n }\ndemo.n = { ? next: demo.n }\n" &
          ping
      ),
      supp = [],
    )
    check got ==
      @[
        "#define LOGOS_DEMO_A_K_LITERAL \"x\"",
        "typedef const char*logos_tstr_size_3_t;",
        "typedef struct logos_map_demo_n logos_demo_n_t;",
        "struct logos_map_demo_n{bool has_next;const logos_demo_n_t*next;};",
        "typedef struct logos_map_demo_a{const char*k;logos_demo_n_t n;logos_tstr_size_3_t s;}logos_demo_a_t;",
      ]

  test "G154: an aggregate a list points into from its own cycle is forward-declared":
    let self = decls("demo.node = { kids: [* demo.node], v: uint64 }\n")
    check self ==
      @[
        "typedef struct logos_map_demo_node logos_demo_node_t;",
        "struct logos_map_demo_node{const logos_demo_node_t*kids;size_t kids_count;uint64_t v;};",
      ]
    let mutual = decls("demo.a = { bs: [* demo.b] }\ndemo.b = { a: demo.a }\n")
    check mutual ==
      @[
        "typedef struct logos_map_demo_b logos_demo_b_t;",
        "typedef struct logos_map_demo_a{const logos_demo_b_t*bs;size_t bs_count;}logos_demo_a_t;",
        "struct logos_map_demo_b{logos_demo_a_t a;};",
      ]
    check compilesSet(
      "g154", accepted("demo.a = { bs: [* demo.b] }\ndemo.b = { a: demo.a }\n")
    ) == ""

suite "ifc.c-types: logos_types.h and compiled headers (INTERFACE §5.2)":
  test "[IFC-0481] logos_types.h holds the §5.2 block, the §2.3 empty types and the common types":
    let fixed = cItems(logosTypesHeader())
    for item in cItems(mirror("IFC/5.2.logos_types.h")):
      if "<module>" notin item:
        check item in fixed
    let t = fixed.text
    for name in [
      "logos_error_detail_t", "logos_invalid_params_reason_t",
      "logos_invalid_params_path_segment_t", "logos_invalid_params_detail_t",
      "logos_schema_commitment_t",
    ]:
      check ("}" & name & ";") in t
    # [SPEC INTERFACE §2.1] No choice declaration for logos.error_code.
    check "LOGOS_ERROR_CODE_ARM_0" notin t
    check "#define LOGOS_SCHEMA_COMMITMENT_HASH_SUITE_LITERAL \"logos.hash-suite.blake3-256\"" in
      t
    check ProvisionalStamp in logosTypesHeader()
    check compiles("logos_types_only", "#include \"logos_types.h\"\n") == ""

  test "[IFC-0475] generated headers include logos_types.h, carry the stamp and compile as C11":
    let s = accepted(mod392, [ifc392], [sup392])
    let h = contractHeader(s.cSchemaSet).get
    check "#include \"logos_types.h\"" in h
    check "PROVISIONAL ABI (spec f4f83471)" in h
    check s.cSchemaSet.headerName == "sensor_module"
    check compilesSet("ifc392", s) == ""
    check compilesSet("ifc391", accepted(mirror("IFC/3.9.1.module.cddl"))) == ""
    check compilesSet("ifc393", accepted(mirror("IFC/3.9.3.module.cddl"))) == ""
    check compilesSet("ifc23", accepted(mirror("IFC/2.3.entry.cddl"))) == ""
    check compilesSet("storage", accepted(mirror("IFC/1.8.module.cddl"))) == ""
    check compilesSet(
      "kitchen",
      accepted(
        """demo.k = {
  a: 7, b: -9223372036854775808, c: "é1",
  d: bstr .size 32, e: [* bstr .size 4], f: [* [uint64, tstr]],
  g: demo.v / [uint64] / [uint64, uint64], ? h: [uint64, bstr],
  i: logos.schema_commitment, j: [], l: bstr .size 0,
}
demo.v = { x: uint64 }
demo.tree = { ? left: demo.tree, kids: [* demo.tree] }
"""
      ),
    ) == ""
