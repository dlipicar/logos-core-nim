## Compiling generated and hand-written C headers in every supported language mode
## (INTERFACE §3.9.6: C17, C23, C++17, C++20, C++23), shared by `test_codegen` and
## `test_rmap`.
##
## Every compile uses UTF-8 source and ordinary string literal encodings
## (INTERFACE §3.5 l.2565, IFC-0852): `-finput-charset=UTF-8 -fexec-charset=UTF-8`.

import std/[os, osproc, strutils]
import unittest2
import logos_sdk/iface/cmap

type Mode* = tuple[cxx: bool, std, fallback: string]

const modes*: array[5, Mode] = [
  (false, "c17", "c17"),
  (false, "c23", "c2x"),
  (true, "c++17", "c++17"),
  (true, "c++20", "c++2a"),
  (true, "c++23", "c++2b"),
]

const deviceTarget* = defined(android) or defined(ios)
  ## A suite cross-compiled for an emulator or simulator runs where there is no C
  ## compiler. There a test that compiles headers reports SKIPPED and its other
  ## checks still run; the host suites compile every header.

const staticAssert* =
  "#ifdef __cplusplus\n#define CHECK(c) static_assert(c, #c)\n#else\n" &
  "#define CHECK(c) _Static_assert(c, #c)\n#endif\n"

template checkCompiles*(call: untyped) =
  when deviceTarget:
    skip()
  else:
    check call == ""

proc compilerFor*(cxx: bool): string =
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

proc compileUnitIn*(dir, name, source: string, extra = ""): string =
  ## Writes `logos_types.h` and the translation unit `name` into `dir` and checks
  ## its syntax in every supported language mode with every warning an error; ""
  ## when all compile, else the first failure.
  createDir(dir)
  writeFile(dir / "logos_types.h", logosTypesHeader())
  let unit = dir / name & ".c"
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
        " -Wall -Wextra -Wpedantic -Werror -fsyntax-only" &
        " -finput-charset=UTF-8 -fexec-charset=UTF-8" & extra & " -I " & quoteShell(dir) &
        " " & quoteShell(unit)
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
