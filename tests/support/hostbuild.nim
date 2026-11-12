## Builds `liblogos_runtime` (`src/liblogos_runtime.nim`) the way
## `kitbuild.buildKitLibrary` builds a kit module: `--app:lib` with this build's
## memory manager, mode and sanitizer, its own `--nimMainPrefix` and nimcache.
## Also compiles `tests/host/embed_main.c` against it, as a program that knows
## only `logos_runtime.h`.

import std/[os, osproc, strutils]
import ./kitbuild

const
  root = currentSourcePath().parentDir.parentDir.parentDir
  nimExe = getCurrentCompilerExe()
  sanitizerFlags =
    when defined(asan):
      @["-fsanitize=address,undefined"]
    elif defined(tsan):
      @["-fsanitize=thread"]
    elif defined(msan):
      @["-fsanitize=memory"]
    else:
      newSeq[string]()

proc libDir*(): string =
  root / "build" / "lib" / kitVariant

proc buildRuntimeLibrary*(): string =
  ## `liblogos_runtime` under `build/lib/<variant>/`.
  let dir = libDir()
  createDir(dir)
  result = dir / (DynlibFormat % "logos_runtime")
  var args = @[nimExe, "c", "--hints:off", "--mm:" & kitMm]
  when defined(release):
    args.add("-d:release")
  when defined(asan):
    args.add("-d:asan")
  elif defined(tsan):
    args.add("-d:tsan")
  elif defined(msan):
    args.add("-d:msan")
  when defined(macosx):
    # Linked by name from `embed_main`: found through its rpath.
    args.add("--passL:-Wl,-install_name,@rpath/" & (DynlibFormat % "logos_runtime"))
  args.add(
    [
      "--app:lib",
      "--nimMainPrefix:liblogos_runtime",
      "--nimcache:" & dir / "nimcache-logos_runtime",
      "-o:" & result,
      root / "src" / "liblogos_runtime.nim",
    ]
  )
  let (output, code) = execCmdEx(quoteShellCommand(args))
  doAssert code == 0, "building liblogos_runtime failed:\n" & output

proc cCompiler(): string =
  when defined(macosx) and (defined(asan) or defined(tsan)):
    # As config.nims: the Xcode toolchain's sanitizer runtimes.
    let (path, code) = execCmdEx("env -u DEVELOPER_DIR /usr/bin/xcrun --find clang")
    doAssert code == 0, "sanitizer builds on macOS need Xcode"
    path.strip
  elif defined(msan):
    "clang"
  else:
    getEnv("CC", "cc")

proc buildEmbedMain*(library: string): string =
  ## `tests/host/embed_main.c` as a program linked against `library`, with
  ## warnings as errors in strict C11.
  let dir = library.parentDir
  result = dir / "embed_main"
  var args = @[
    cCompiler(),
    "-std=c11",
    "-Wall",
    "-Wextra",
    "-Werror",
    "-pedantic",
    "-I" & root / "tests" / "generated",
    "-o",
    result,
    root / "tests" / "host" / "embed_main.c",
  ]
  when sanitizerFlags.len > 0:
    # The runtimes' defaults and suppressions, as every Nim test program has them
    # (config.nims). The program needs its own: the library's copy comes after the
    # runtime's weak defaults in symbol lookup order, so the runtime never sees it.
    args.add(root / "tests" / "support" / "sanitizers.c")
  args.add(["-L" & dir, "-llogos_runtime", "-Wl,-rpath," & dir])
  args.add(sanitizerFlags)
  let (output, code) = execCmdEx(quoteShellCommand(args))
  doAssert code == 0, "building embed_main failed:\n" & output
