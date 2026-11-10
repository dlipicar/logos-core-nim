## lcn-gen: the canonical C type headers of an accepted Logos schema set
## (INTERFACE §2.1-§2.3, §2.5) and `logos_types.h` (§5.2). Types only for now
## (D29): method signatures, lifecycle symbols and vtables come later. Every
## header is stamped PROVISIONAL ABI.

import std/[os, parseopt, strutils]
import results
import ./logos_core/iface/accept
import ./logos_core/codegen/nimgen

const usage = """
Usage:
  lcn-gen logos-types [--out:DIR]
  lcn-gen types [--out:DIR] [--system] PRIMARY.cddl
                [--interface:FILE]... [--supporting:FILE]...
  lcn-gen nim-common [--out:DIR] [--import-prefix:P]
  lcn-gen nim [--out:DIR] [--import-prefix:P] [--system] PRIMARY.cddl
              [--interface:FILE]... [--supporting:FILE]...

logos-types  writes DIR/logos_types.h
types        accepts the construction input set (INTERFACE §1.1, §5.3) and
             writes DIR/<module or namespace>_types.h
nim-common   writes DIR/common_types.nim (the pinned common schema)
nim          accepts the set and writes DIR/<module or namespace>_types.nim

--import-prefix:P  how Nim output imports this library (default: logos_core/)

--out:DIR          output directory (default: .)
--system           the set is a Logos system contract (reserved logos names)
--interface:FILE   an implemented interface document (repeatable)
--supporting:FILE  a supporting schema document (repeatable)
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
    outDir = "."
    prefix = "logos_core/"
    opts = AcceptOptions()
    interfaces, supporting: seq[string]
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
      of "system":
        opts.system = true
      of "interface":
        interfaces.add(val)
      of "supporting":
        supporting.add(val)
      of "help", "h":
        echo usage
        return 0
      else:
        return fail("unknown option " & key & "\n" & usage)
    of cmdEnd:
      discard
  case command
  of "logos-types":
    write(outDir, "logos_types.h", logosTypesHeader())
  of "nim-common":
    let module = commonNimModule(NimOptions(importPrefix: prefix)).valueOr:
      return fail(error)
    write(outDir, "common_types.nim", module)
  of "types", "nim":
    if primary.len == 0:
      return fail("no primary document\n" & usage)
    var sources: seq[string]
    try:
      for f in @[primary] & interfaces & supporting:
        sources.add(readFile(f))
    except CatchableError as e:
      return fail(e.msg)
    let set = acceptContractSet(
      sources[0], sources[1 .. interfaces.len], sources[interfaces.len + 1 .. ^1], opts
    ).valueOr:
      return fail("the schema set is not accepted: " & error)
    if command == "nim":
      let module = nimModule(set, NimOptions(importPrefix: prefix), opts.system).valueOr:
        return fail(error)
      return write(outDir, set.cSchemaSet.headerName & "_types.nim", module)
    let header = contractHeader(set.cSchemaSet).valueOr:
      return fail(error)
    write(outDir, set.cSchemaSet.headerName & "_types.h", header)
  else:
    fail(usage.strip)

when isMainModule:
  quit(main())
