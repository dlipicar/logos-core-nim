## lcn-gen: the canonical C type headers of an accepted Logos schema set or
## module binding (INTERFACE §2, §2.1-§2.3, §2.5, §3.2; C mapping revision 3),
## `logos_types.h` (§5.2) and `logos_runtime.h` (RUNTIME §13): C types, method
## typedefs and, for a module binding, its provider functions and module
## symbols (§2.4, §2.6). Every header is stamped PROVISIONAL ABI.

import std/[os, parseopt, strutils]
import results
import ./logos_core/iface/accept
import ./logos_core/codegen/[callsgen, hostgen, kitgen, nimgen]

const usage = """
Usage:
  lcn-gen logos-types [--out:DIR]
  lcn-gen logos-runtime [--out:DIR]
  lcn-gen types [--out:DIR] [--system] [--module:NAME] [PRIMARY.cddl]
                [--interface:FILE]... [--supporting:FILE]...
  lcn-gen nim-common [--out:DIR] [--import-prefix:P]
  lcn-gen nim [--out:DIR] [--import-prefix:P] [--system] [--module:NAME] PRIMARY.cddl
              [--interface:FILE]... [--supporting:FILE]...
  lcn-gen kit [--out:DIR] [--import-prefix:P] [--system] PRIMARY.cddl
              [--interface:FILE]... [--supporting:FILE]...
              [--configuration:FILE --configuration-root:NAME
               [--live-reconfiguration]]
  lcn-gen calls [--out:DIR] [--import-prefix:P] [--system] PRIMARY.cddl
                [--interface:FILE]... [--supporting:FILE]...

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
kit          accepts a concrete module document's set and writes the Nim
             types and DIR/<module>_kit.nim: the module's exported ABI
             symbols, typed _CALL_ provider functions included, over
             handlers its author writes in Nim (PROVISIONAL); with
             --configuration, also DIR/<module>_configuration_types.nim, and
             the kit checks and delivers the configuration (CONFIG §6, §8)
calls        accepts a provider's set (a concrete module document, or an
             interface document) and writes DIR/<stem>_types.h,
             <stem>_types.nim, <stem>_calls.nim and <stem>_calls.h: typed
             calls to each exposed method through a route handle, for Nim
             callers and, once exported, C callers (PROVISIONAL)

--import-prefix:P  how Nim output imports this library (default: logos_core/)

--out:DIR          output directory (default: .)
--module:NAME      the runtime module name of an explicit module binding; it
                   must agree with PRIMARY's _module and _implements
--system           the set is a Logos system contract (reserved logos names)
--interface:FILE   an implemented interface document (repeatable)
--supporting:FILE  a supporting schema document (repeatable)
--configuration:FILE
                   kit: the module's configuration schema (CONFIG §2), a
                   supporting schema resolved against the common schema only
--configuration-root:NAME
                   kit: the configuration value's type in that schema
--live-reconfiguration
                   kit: the module declares live reconfiguration and exports
                   _MODULE_apply_configuration (CONFIG §8)

Limits (INTERFACE §2.1): no identifier-length limit; identifiers are never
truncated, hashed or aliased. Input is bounded by the INTERFACE §5.3 schema
limits (1 MiB per document, 8 MiB per input set, 65,536 schema nodes, 128
nesting levels), and work and memory grow linearly with it. A choice whose
largest C discriminant exceeds UINT32_MAX, and for nim output names that
collide under Nim's identifier rules, fail with an error. On any failure
nothing is written.
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

proc main(): int =
  var
    command = ""
    primary = ""
    module = ""
    outDir = "."
    prefix = "logos_core/"
    opts = AcceptOptions()
    interfaces, supporting: seq[string]
    configuration, configurationRoot = ""
    live = false
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if command.len == 0:
        command = key
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
      of "system":
        opts.system = true
      of "interface":
        interfaces.add(val)
      of "supporting":
        supporting.add(val)
      of "configuration":
        configuration = val
      of "configuration-root":
        configurationRoot = val
      of "live-reconfiguration":
        live = true
      of "help", "h":
        echo usage
        return 0
      else:
        return fail("unknown option " & key & "\n" & usage)
    of cmdEnd:
      discard
  if (configuration.len > 0 or configurationRoot.len > 0 or live) and command != "kit":
    return fail("--configuration options apply to kit only\n" & usage)
  if (configuration.len > 0) != (configurationRoot.len > 0) or
      (live and configuration.len == 0):
    return fail(
      "--configuration and --configuration-root go together, and " &
        "--live-reconfiguration needs them\n" & usage
    )
  case command
  of "logos-types":
    write(outDir, "logos_types.h", logosTypesHeader())
  of "logos-runtime":
    write(outDir, "logos_runtime.h", logosRuntimeHeader())
  of "nim-common":
    let module = commonNimModule(NimOptions(importPrefix: prefix)).valueOr:
      return fail(error)
    write(outDir, "common_types.nim", module)
  of "types", "nim", "kit", "calls":
    if primary.len == 0 and (module.len == 0 or command != "types"):
      return fail("no primary document\n" & usage)
    var sources: seq[string]
    try:
      for f in (if primary.len > 0: @[primary] else: @[]) & interfaces & supporting:
        sources.add(readFile(f))
    except CatchableError as e:
      return fail(e.msg)
    if module.len > 0:
      let first = if primary.len > 0: 1 else: 0
      let b = acceptBinding(
        module,
        if primary.len > 0:
          Opt.some(sources[0])
        else:
          Opt.none(string),
        sources[first ..< first + interfaces.len],
        sources[first + interfaces.len .. ^1],
        opts,
      ).valueOr:
        return fail("the module binding is not accepted: " & error)
      if command == "types":
        let header = contractHeader(b.cSchemaSet).valueOr:
          return fail(error)
        return write(outDir, b.cSchemaSet.headerName & "_types.h", header)
    let set = acceptContractSet(
      sources[0], sources[1 .. interfaces.len], sources[interfaces.len + 1 .. ^1], opts
    ).valueOr:
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
      let module = nimModule(set, NimOptions(importPrefix: prefix), opts.system).valueOr:
        return fail(error)
      if command == "kit":
        var kopts = KitOptions(importPrefix: prefix)
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
          configTypes = configurationTypesModule(set, c, kopts).valueOr:
            return fail(error)
        let kit = kitModule(set, kopts, opts.system).valueOr:
          return fail(error)
        var outputs = @[(set.cSchemaSet.headerName & "_types.nim", module)]
        if configTypes.len > 0:
          outputs.add((configurationTypesName(set) & ".nim", configTypes))
        outputs.add((set.cSchemaSet.headerName & "_kit.nim", kit))
        for (name, text) in outputs:
          let r = write(outDir, name, text)
          if r != 0:
            return r
        return 0
      return write(outDir, set.cSchemaSet.headerName & "_types.nim", module)
    let header = contractHeader(set.cSchemaSet).valueOr:
      return fail(error)
    write(outDir, set.cSchemaSet.headerName & "_types.h", header)
  else:
    fail(usage.strip)

when isMainModule:
  quit(main())
