## lcn-gen: the canonical C type headers of an accepted Logos schema set or
## module binding (INTERFACE §2, §2.1-§2.3, §2.5, §3.2; C mapping revision 4),
## `logos_types.h` (§5.2) and `logos_runtime.h` (RUNTIME §13): C types, method
## typedefs and, for a module binding, its provider functions and module
## symbols (§2.4, §2.6). In the other direction, `lcn-gen cddl` reconstructs the schema documents and the module
## binding of an explicit C header set (INTERFACE §3; DECISIONS G321).

import std/[os, parseopt, strutils]
import results
import logos_sdk/base/hex
import logos_sdk/iface/[accept, rmap]
import logos_sdk/codegen/[callsgen, cblint, hostgen, kitgen, nimgen, sdkroot]

const sdkVersion = block:
  ## [DECISIONS G433] The SDK's version, read from its nimble file when lcn-gen is
  ## compiled: beside `src/` in the repository and in Nimble's build at install,
  ## beside this file in an installed package. `lcn-gen --version` prints it, so a
  ## module repository can check that the program is the SDK its lock names.
  let here = currentSourcePath().parentDir
  var found = ""
  for file in [here.parentDir / "logos_sdk.nimble", here / "logos_sdk.nimble"]:
    if found.len == 0 and fileExists(file):
      for line in staticRead(file).splitLines:
        if line.startsWith("version"):
          found = line.split('"')[1]
          break
  doAssert found.len > 0, "no version in the SDK's nimble file"
  found

const usage =
  """
Usage:
  lcn-gen --version
  lcn-gen logos-types [--out:DIR]
  lcn-gen logos-runtime [--out:DIR]
  lcn-gen types [--out:DIR] [--system] [--module:NAME] [PRIMARY.cddl]
                [--interface:FILE]... [--supporting:FILE]...
  lcn-gen nim-common [--out:DIR] [--import-prefix:P]
  lcn-gen nim [--out:DIR] [--import-prefix:P] [--system] [--module:NAME] PRIMARY.cddl
              [--interface:FILE]... [--supporting:FILE]...
  lcn-gen kit [--out:DIR] [--import-prefix:P] [--system] [--confined [--async-api]]
              [--module:NAME] [PRIMARY.cddl] [--interface:FILE]...
              [--supporting:FILE]... [--extends:FILE]...
              [--configuration:FILE --configuration-root:NAME
               [--live-reconfiguration]]
  lcn-gen calls [--out:DIR] [--import-prefix:P] [--system] PRIMARY.cddl
                [--interface:FILE]... [--supporting:FILE]...
  lcn-gen cddl [--out:DIR] [--system] (--module:NAME | --subject:NS) [--header]
               [LOGICAL=]HEADER...
  lcn-gen lint-callbacks [--self-test] [PATH...]

logos-types  writes DIR/logos_types.h
logos-runtime
             writes DIR/logos_runtime.h, the Host Embedding API (RUNTIME §13)
types        accepts the construction input set (INTERFACE §1.1, §5.3) and
             writes DIR/<module or namespace>_types.h; with --module, the
             module binding (INTERFACE §2): PRIMARY may then be left out for
             an interface-only provider, whose implemented interfaces are
             the --interface documents
nim-common   writes DIR/common_types.nim (the pinned common schema)
nim          accepts the set and writes DIR/<module or namespace>_types.nim
kit          accepts a concrete module document's set, or with --module and
             no PRIMARY an interface-only provider's binding (its
             implemented interfaces are the --interface documents; none: a
             module with lifecycle symbols only), and writes the Nim types
             and DIR/<module>_kit.nim: the module's exported ABI symbols,
             typed _CALL_ provider functions included, over handlers its
             author writes in Nim (PROVISIONAL); with
             --configuration, also DIR/<module>_configuration_types.nim, and
             the kit checks and delivers the configuration (CONFIG §6, §8);
             also DIR/<module>_kit.exports and DIR/<module>_kit.map, the
             library's export list for macOS ld (-exported_symbols_list) and
             GNU ld (--version-script): its ABI symbols and nothing else
calls        accepts a provider's set (a concrete module document, or an
             interface document) and writes DIR/<stem>_types.h,
             <stem>_types.nim, <stem>_calls.nim and <stem>_calls.h: typed
             calls to each exposed method through a route handle, for Nim
             callers and, once exported, C callers (PROVISIONAL)
cddl         reads exactly the C headers named, without a preprocessor, and
             writes DIR/<namespace>.cddl for each document it reconstructs
             (INTERFACE §3); prints the module binding. An include resolves
             against the logical names of those headers only; a header's
             logical name is LOGICAL, or else its file name. The subject
             is input, never inferred: --module or --subject names it
             exactly
lint-callbacks
             checks every C-callable procedure in the .nim files under each
             PATH: marked {.lcnCallback.} or {.lcnModuleThread.}, exempt
             with {.lcnNoNimHeap: "why".} or {.lcnOwnRuntime: "why".}, or
             starting with kitEnter() or bindingEnter() (DECISIONS G464-G467);
             and no Entered value made without entered(p). Prints each
             finding and exits 1 on any; --self-test runs its fixtures first

--import-prefix:P  how Nim output imports this library (default: """ &
  SdkImportRoot & """)

--out:DIR          output directory (default: .)
--module:NAME      the runtime module name of an explicit module binding; it
                   must agree with PRIMARY's _module and _implements; cddl: the
                   module to reconstruct
--subject:NS       cddl: the namespace of the document to reconstruct
--header           cddl: also write the canonical, identity-checked header,
                   DIR/<module or namespace>_types.h
--system           the set is a Logos system contract (reserved logos names)
--interface:FILE   an implemented interface document (repeatable)
--supporting:FILE  a supporting schema document (repeatable)
--extends:FILE     kit: an earlier contract that PRIMARY or an interface
                   extends (COMMITMENT §9.1), carried in the call-surface
                   descriptor's extends (INTERFACE §2.6; repeatable); its
                   supporting schemas are among the --supporting documents
--configuration:FILE
                   kit: the module's configuration schema (CONFIG §2), a
                   supporting schema resolved against the common schema only
--configuration-root:NAME
                   kit: the configuration value's type in that schema
--live-reconfiguration
                   kit: the module declares live reconfiguration and exports
                   _MODULE_apply_configuration (CONFIG §8)
--confined         kit: each context runs on its own module thread, which runs
                   chronos; handlers may be async (DECISIONS G335-G337). Build
                   the library with --import:logos_sdk/base/hostsignals
--async-api        kit, with --confined, of a provider: also export
                   _MODULE_async_api, the deferred provider surface (INTERFACE
                   §2.9.2; DECISIONS G338)

Limits (INTERFACE §2.1): no identifier-length limit; identifiers are never
truncated, hashed or aliased. Input is bounded by the INTERFACE §5.3 schema
limits (1 MiB per document, 8 MiB per input set, 65,536 schema nodes, 128
nesting levels), and work and memory grow linearly with it. A choice whose
largest C discriminant exceeds UINT32_MAX, and for nim output names that
collide under Nim's identifier rules, fail with an error. cddl reads at most
16 MiB and 1,024 headers per set, includes nested 64 deep and literals
parenthesized 64 deep, and what it reconstructs is held to the same schema
limits; it has no identifier-length limit either. At 16 MiB it can need about
3 GB of memory. A header set over 16 MiB is refused, even one generated from
documents within the schema limits: inline declarations nested deep repeat
their field path, up to about 190 times the document's size. Exceeding a limit
is an error, never a shorter result. On any failure nothing is written.
"""

proc fail(msg: string): int =
  try:
    stderr.writeLine("lcn-gen: " & msg)
  except IOError:
    discard
  1

proc write(dir, name, text: string): int =
  let path = dir / name
  try:
    createDir(dir)
    writeFile(path, text)
    echo path
  except CatchableError as e:
    return fail("cannot write " & path & ": " & e.msg)
  0

proc headerSources(files: seq[string]): Result[seq[HeaderSource], string] =
  ## [IMPL-DECISION G321] `[LOGICAL=]FILE`: each named file is read once. The
  ## running size is checked first, so that an oversized set fails without being
  ## loaded.
  var res: seq[HeaderSource]
  var total = 0'i64
  for f in files:
    let eq = f.find('=')
    let (logical, path) =
      if eq >= 0:
        (f[0 ..< eq], f[eq + 1 .. ^1])
      else:
        (extractFilename(f), f)
    try:
      total += getFileSize(path)
      if total > MaxSetBytes:
        return
          err("[" & $rkLimit & "] " & logical & ": an input set larger than 16 MiB")
      res.add(HeaderSource(name: logical, text: readFile(path)))
    except CatchableError as e:
      return err("cannot read " & path & ": " & e.msg)
  ok(res)

proc writeAll(dir: string, outputs: seq[(string, string)]): int =
  ## Every output, or none: each is written beside its name first.
  var pending: seq[string]
  proc discardPending() =
    for p in pending:
      try:
        removeFile(p)
      except CatchableError:
        discard

  try:
    createDir(dir)
    for (name, text) in outputs:
      let tmp = dir / name & ".tmp"
      pending.add(tmp)
      writeFile(tmp, text)
    for (name, _) in outputs:
      moveFile(dir / name & ".tmp", dir / name)
      echo dir / name
  except CatchableError as e:
    discardPending()
    return fail("cannot write to " & dir & ": " & e.msg)
  0

proc reverse(files: seq[string], opts: RmapOptions, dir: string, header: bool): int =
  ## [SPEC INTERFACE §3] `lcn-gen cddl`.
  let sources = headerSources(files).valueOr:
    return fail(error)
  let r = reconstruct(sources, opts).valueOr:
    return fail($error)
  var docs: seq[RDocument]
  if r.primary.isSome:
    docs.add(r.primary.get)
  docs.add(r.interfaces)
  docs.add(r.supporting)
  var outputs: seq[(string, string)]
  for d in docs:
    outputs.add((d.namespace & ".cddl", d.cddl))
  if header:
    outputs.add((r.schemaSet.headerName & "_types.h", r.header))
  let code = writeAll(dir, outputs)
  if code != 0:
    return code
  # [IMPL-DECISION G321] The recovered binding is retained tooling data (l.2284).
  if r.module.isSome:
    echo "module ", r.module.get
  if r.primary.isSome:
    let p = r.primary.get
    echo(if r.module.isSome: "primary " else: "subject ", p.namespace)
  for i in r.interfaces:
    echo "implements ", i.namespace, " ", toHex(i.contract.root)
  0

proc main(): int =
  var
    command = ""
    primary = ""
    module = ""
    subject = ""
    wantHeader = false
    headers: seq[string]
    outDir = "."
    prefix = SdkImportRoot
    opts = AcceptOptions()
    interfaces, supporting, extends: seq[string]
    configuration, configurationRoot = ""
    live = false
    confined = false
    asyncApi = false
    lintSelfTest = false
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if command.len == 0:
        command = key
      elif command in ["cddl", "lint-callbacks"]:
        headers.add(key)
      elif primary.len == 0:
        primary = key
      else:
        return fail("unexpected argument " & key & "\n" & usage)
    of cmdLongOption, cmdShortOption:
      case key
      of "out":
        outDir = val
      of "import-prefix":
        prefix = val
      of "module":
        module = val
      of "subject":
        subject = val
      of "header":
        wantHeader = true
      of "system":
        opts.system = true
      of "interface":
        interfaces.add(val)
      of "supporting":
        supporting.add(val)
      of "extends":
        extends.add(val)
      of "configuration":
        configuration = val
      of "configuration-root":
        configurationRoot = val
      of "live-reconfiguration":
        live = true
      of "confined":
        confined = true
      of "self-test":
        lintSelfTest = true
      of "async-api":
        asyncApi = true
      of "help", "h":
        echo usage
        return 0
      of "version":
        echo "lcn-gen " & sdkVersion
        return 0
      else:
        return fail("unknown option " & key & "\n" & usage)
    of cmdEnd:
      discard
  if (configuration.len > 0 or configurationRoot.len > 0 or live) and command != "kit":
    return fail("--configuration options apply to kit only\n" & usage)
  if confined and command != "kit":
    return fail("--confined applies to kit only\n" & usage)
  if extends.len > 0 and command != "kit":
    return fail("--extends applies to kit only\n" & usage)
  if asyncApi and not confined:
    return fail("--async-api needs kit --confined\n" & usage)
  if (configuration.len > 0) != (configurationRoot.len > 0) or
      (live and configuration.len == 0):
    return fail(
      "--configuration and --configuration-root go together, and " &
        "--live-reconfiguration needs them\n" & usage
    )
  if (subject.len > 0 or wantHeader) and command != "cddl":
    return fail("--subject and --header apply to cddl only\n" & usage)
  if lintSelfTest and command != "lint-callbacks":
    return fail("--self-test applies to lint-callbacks only\n" & usage)
  case command
  of "cddl":
    if interfaces.len > 0 or supporting.len > 0:
      return fail("cddl takes headers, not --interface or --supporting\n" & usage)
    if module.len > 0 and subject.len > 0:
      return fail("--module and --subject exclude each other\n" & usage)
    # [SPEC INTERFACE §3.2 l.2245] The subject is mapper input, never inferred.
    if module.len == 0 and subject.len == 0:
      return fail("cddl needs --module or --subject\n" & usage)
    if headers.len == 0:
      return fail("no header\n" & usage)
    reverse(
      headers,
      RmapOptions(module: module, subject: subject, system: opts.system),
      outDir,
      wantHeader,
    )
  of "lint-callbacks":
    if lintSelfTest:
      let failed = selfTest()
      for f in failed:
        stderr.writeLine "lint-callbacks self-test: " & f
      if failed.len > 0:
        return 1
      echo "lint-callbacks self-test: every fixture's verdict holds"
    if headers.len == 0 and lintSelfTest:
      return 0
    var stats: Stats
    let found = lintPaths(
      if headers.len > 0:
        headers
      else:
        @["."],
      stats,
    )
    for f in found:
      echo f.path, ":", f.line, ": ", f.name, ": ", f.message
    echo "lint-callbacks: ",
      stats.files, " files, ", stats.callable, " C-callable procedures (", stats.marked,
      " marked, ", stats.entries, " entries, ", stats.noNimHeap, " lcnNoNimHeap, ",
      stats.ownRuntime, " lcnOwnRuntime), ", found.len, " findings"
    if found.len > 0: 1 else: 0
  of "logos-types":
    write(outDir, "logos_types.h", logosTypesHeader())
  of "logos-runtime":
    write(outDir, "logos_runtime.h", logosRuntimeHeader())
  of "nim-common":
    let module = commonNimModule(NimOptions(importPrefix: prefix)).valueOr:
      return fail(error)
    write(outDir, "common_types.nim", module)
  of "types", "nim", "kit", "calls":
    if primary.len == 0 and (module.len == 0 or command notin ["types", "kit"]):
      return fail("no primary document\n" & usage)
    var sources, earlier: seq[string]
    try:
      for f in (if primary.len > 0: @[primary] else: @[]) & interfaces & supporting:
        sources.add(readFile(f))
      for f in extends:
        earlier.add(readFile(f))
    except CatchableError as e:
      return fail(e.msg)
    let
      first = if primary.len > 0: 1 else: 0
      ifaceSources = sources[first ..< first + interfaces.len]
      suppSources = sources[first + interfaces.len .. ^1]

    proc bindingOf(name: string): Result[ModuleBinding, string] =
      acceptBinding(
        name,
        if primary.len > 0:
          Opt.some(sources[0])
        else:
          Opt.none(string),
        ifaceSources,
        suppSources,
        opts,
        earlier,
      )
        .mapErr(
          proc(e: string): string =
            "the module binding is not accepted: " & e
        )

    proc writeKit(b: ModuleBinding, types: string): int =
      ## [DECISIONS G339, G341] The kit of `b`, its types, its configuration
      ## types and its export lists.
      var kopts =
        KitOptions(importPrefix: prefix, confined: confined, asyncApi: asyncApi)
      var configTypes = ""
      if configuration.len > 0:
        let text =
          try:
            readFile(configuration)
          except CatchableError as e:
            return fail(e.msg)
        let cset = configurationSet(text).valueOr:
          return fail(error)
        let c = KitConfiguration(set: cset, root: configurationRoot, live: live)
        kopts.configuration = Opt.some(c)
        configTypes = configurationTypesModule(b, c, kopts).valueOr:
          return fail(error)
      let kit = kitModule(b, kopts, opts.system).valueOr:
        return fail(error)
      let header = b.cSchemaSet.headerName
      var outputs = @[(header & "_types.nim", types)]
      if configTypes.len > 0:
        outputs.add((configurationTypesName(b) & ".nim", configTypes))
      outputs.add((header & "_kit.nim", kit))
      # [DECISIONS G341] The library's export lists, for its link.
      let symbols = kitSymbols(b, kopts, opts.system).valueOr:
        return fail(error)
      for kind in ExportListKind:
        let name = exportListName(b, kind)
        outputs.add((name, exportList(name, symbols, kind)))
      for (name, text) in outputs:
        let r = write(outDir, name, text)
        if r != 0:
          return r
      0

    var bound = Opt.none(ModuleBinding)
    if module.len > 0:
      let b = bindingOf(module).valueOr:
        return fail(error)
      if command == "types":
        let header = contractHeader(b.cSchemaSet).valueOr:
          return fail(error)
        return write(outDir, b.cSchemaSet.headerName & "_types.h", header)
      bound = Opt.some(b)
    if primary.len == 0:
      # [DECISIONS G339] The kit of an interface-only binding (INTERFACE
      # l.2833-2840), or of a module with lifecycle symbols only.
      let b = bound.get
      let types = nimModule(b, NimOptions(importPrefix: prefix), opts.system).valueOr:
        return fail(error)
      return writeKit(b, types)
    let set = acceptContractSet(sources[0], ifaceSources, suppSources, opts).valueOr:
      return fail("the schema set is not accepted: " & error)
    if command == "calls":
      let header = contractHeader(set.cSchemaSet).valueOr:
        return fail(error)
      let module = nimModule(set, NimOptions(importPrefix: prefix), opts.system).valueOr:
        return fail(error)
      let calls = callsModule(set, CallsOptions(importPrefix: prefix), opts.system).valueOr:
        return fail(error)
      let callsHeader = callsHeaderFile(set).valueOr:
        return fail(error)
      let stem = set.cSchemaSet.headerName
      for (name, text) in [
        (stem & "_types.h", header),
        (stem & "_types.nim", module),
        (stem & "_calls.nim", calls),
        (stem & "_calls.h", callsHeader),
      ]:
        let r = write(outDir, name, text)
        if r != 0:
          return r
      return 0
    if command in ["nim", "kit"]:
      let types = nimModule(set, NimOptions(importPrefix: prefix), opts.system).valueOr:
        return fail(error)
      if command == "kit":
        let b =
          if bound.isSome:
            bound.get
          elif extends.len > 0:
            # [SPEC INTERFACE §2.6 l.1693-1696] The set's binding with the
            # earlier contracts its descriptor carries.
            let own = set.binding.valueOr:
              return fail(error)
            bindingOf(own.module).valueOr:
              return fail(error)
          else:
            set.binding.valueOr:
              return fail(error)
        return writeKit(b, types)
      return write(outDir, set.cSchemaSet.headerName & "_types.nim", types)
    let header = contractHeader(set.cSchemaSet).valueOr:
      return fail(error)
    write(outDir, set.cSchemaSet.headerName & "_types.h", header)
  else:
    fail(usage.strip)

when isMainModule:
  quit(main())
