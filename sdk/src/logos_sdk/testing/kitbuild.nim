## Builds a kit source as a shared library (`--app:lib`) with this
## build's memory manager, mode and sanitizer, for the suites that load kit modules the way
## a Runtime does (`test_kit_dylib`, `test_realizer`). Each library gets its own
## `--nimMainPrefix`, so its `NimMain` is distinct from the host's and from any
## other library's, and its own nimcache, so suites can build in parallel.
##
## [4b-2 plan §4.3] Test processes running at once may build the same library:
## on POSIX each builds under an exclusive `lockf` on `<name>.lock` into its own
## file and renames it over the old one (the `peerbuild.nim` pattern), so no
## process loads a half-written library and no two share a nimcache at once.
##
## [DECISIONS I92] A suite built with `-d:lcnWipeAudit` (`test_wipe_routes`)
## builds its libraries and children as audit builds too (`kitAudit`): the free
## scan, on the Nim heap through `malloc`, in their own variant directory.
##
## [DECISIONS G438] A confined kit library is built strict by default
## (`-d:lcnKitStrictDestroy`): its destroy aborts when the module left
## something registered with its module thread's dispatcher, so the suite fails
## at that destroy. Turning it off takes a reason, which is written beside the
## library and to stdout; the variant directory's name says which (`-strict`),
## so a strict and a lenient library never share a path. This helper is for
## test suites only and never builds a release library.
##
## [DECISIONS G435] A kit source whose tree sets no search paths (an SDK fixture
## in an installed package, say) is compiled with the host's own package search
## paths (`hostPathArgs`), so it finds the packages the host was built with. A
## source whose tree sets them is built as that tree says.

import std/[compilesettings, os, osproc, strutils]
when defined(posix):
  import std/posix
import ./testdirs

const
  kitMm* =
    when compileOption("mm", "orc"):
      "orc"
    elif compileOption("mm", "refc"):
      "refc"
    elif compileOption("mm", "arc"):
      "arc"
    else:
      {.error: "kitbuild: unknown memory manager".}
  # The library is built under the host's sanitizer: MemorySanitizer takes what
  # uninstrumented code writes for uninitialized (DECISIONS I77).
  kitSanitizer* =
    when defined(asan):
      "asan"
    elif defined(tsan):
      "tsan"
    elif defined(msan):
      "msan"
    else:
      ""
  kitAudit* = defined(lcnWipeAudit)
  kitVariant* =
    kitMm & (when defined(release): "-release" else: "") &
    (when kitSanitizer.len > 0: "-" & kitSanitizer else: "") &
    (when kitAudit: "-wipeaudit" else: "")
  nimExe = getCurrentCompilerExe()
  hostLib = querySetting(libPath)
  hostSearchPaths = querySettingSeq(searchPaths)
    ## The host's search paths, in its order, its compiler's own library
    ## directories included.

func setsPaths(config: string): bool =
  ## Whether configuration text sets search paths: a `path`, `p` or
  ## `nimblePath` switch, in NimScript or `.cfg` form, or an included
  ## `nimble.paths`. Nim's switch names ignore case and underscores, and a
  ## `.cfg` file also takes one dash, so each line is compared without them.
  if "nimble.paths" in config:
    return true
  for raw in config.splitLines:
    let line = raw.strip
    if line.startsWith("#"):
      continue
    let squeezed = line.multiReplace((" ", ""), ("_", "")).toLowerAscii
    for key in ["path", "p", "nimblepath"]:
      for dashes in ["--", "-", ""]:
        if squeezed.startsWith(dashes & key & ":") or
            squeezed.startsWith(dashes & key & "="):
          return true
      if ("switch(\"" & key & "\",") in squeezed:
        return true
  false

proc pathsConfig*(source: string): string =
  ## The configuration file Nim reads for `source` that sets search paths, the
  ## nearest first, or "" when none does. Nim reads `config.nims` and `nim.cfg`
  ## in the source's directory and in each above it, and the project's own
  ## `<name>.nimcfg`, `<name>.nim.cfg` and `<name>.nims` (compiler/nimconf.nim).
  ## An installed SDK's `testing/config.nims` only defines `lcnTestHooks`, so
  ## it does not count.
  let dir = source.absolutePath.parentDir
  let stem = source.splitFile.name
  var files =
    @[dir / (stem & ".nimcfg"), dir / (stem & ".nim.cfg"), dir / (stem & ".nims")]
  for up in parentDirs(dir):
    files.add([up / "config.nims", up / "nim.cfg"])
  for file in files:
    if fileExists(file):
      let text =
        try:
          readFile(file)
        except IOError:
          ""
      if setsPaths(text):
        return file
  ""

proc treeSetsPaths*(source: string): bool =
  ## Whether a configuration file Nim reads for `source` sets search paths
  ## (`pathsConfig`).
  pathsConfig(source).len > 0

proc hostPathArgs*(source: string): seq[string] =
  ## [DECISIONS G435] `--path:` switches that give `source` the host's search
  ## paths when no configuration file of its tree sets any (`treeSetsPaths`),
  ## and none otherwise, so an in-tree build keeps its tree's paths and their
  ## order. Back to front: Nim puts each command-line path first, and skips a
  ## path it already has, so the library's list is the host's, in the host's
  ## order. Under `LCN_KIT_NIM` the host compiler's own library directories are
  ## left out: the compiler that builds the library adds its own. Core's
  ## `childbuild` uses it for programs built from an installed package.
  if treeSetsPaths(source):
    return
  let otherCompiler = getEnv("LCN_KIT_NIM").len > 0
  for i in countdown(hostSearchPaths.high, 0):
    if not (otherCompiler and hostSearchPaths[i].startsWith(hostLib)):
      result.add("--path:" & hostSearchPaths[i])

proc withheldPathsNote*(source: string): string =
  ## For a failed build's message: the configuration file that made
  ## `hostPathArgs` pass none of the host's search paths, or "".
  let config = pathsConfig(source)
  if config.len > 0:
    result =
      "\n[DECISIONS G435] The host's search paths were not passed: " & config &
      " sets search paths for " & source & ", so the build takes its paths from there."

type KitTree* = object
  ## Where a suite's kit libraries come from [IMPL]: the kit source directories and the
  ## directories of generated export lists, each searched in order, and the build directory.
  sources*: seq[string]
  generated*: seq[string]
  build*: string

proc kitTreeOf*(suite: string): KitTree =
  ## The tree of the suite at the absolute path `suite`: its own directories, then the SDK's
  ## fixtures, and the build directory under the working directory, the suite's repository.
  let tests = suite.parentDir
  KitTree(
    sources: @[tests / "kit", fixtureDir],
    generated: @[tests / "generated", generatedDir],
    build: absolutePath("build" / "kit-dylib"),
  )

template kitTree*(): KitTree =
  ## The calling suite's tree: paths follow the suite, not this helper.
  kitTreeOf(instantiationInfo(fullPaths = true).filename)

proc locate(dirs: openArray[string], file: string): string =
  ## `file` in the first of `dirs` that holds it.
  for dir in dirs:
    if fileExists(dir / file):
      return dir / file
  doAssert false, file & " is in none of " & $dirs

proc kitAuditFlags*(executable: bool): seq[string] =
  ## The audit build's switches (`tests/test_wipe.nims`); none otherwise. An
  ## executable exports the scan registry on Linux, for the libraries it loads.
  when kitAudit:
    result = @["-d:lcnTestHooks", "-d:lcnWipeAudit", "-d:useMalloc"]
    when defined(linux):
      if executable:
        result.add("--passL:-rdynamic")

const otherMm* = (if kitMm == "refc": "orc" else: "refc")
  ## [DECISIONS G342] The memory manager a mixed-manager case builds its module
  ## with: refc beside an orc host, orc beside a refc one.

proc kitCompiler(): (string, string) =
  ## [DECISIONS G341] The compiler a kit library is built with and its variant
  ## suffix: `LCN_KIT_NIM` when it is set (the toolchain check builds the
  ## libraries with a module library's own compiler, the host with this one),
  ## else this build's.
  let other = getEnv("LCN_KIT_NIM")
  if other.len == 0:
    return (nimExe, "")
  let (version, code) = execCmdEx(quoteShellCommand([other, "--version"]))
  doAssert code == 0, "LCN_KIT_NIM: " & version
  let words = version.splitWhitespace
  let at = words.find("Version")
  doAssert at >= 0 and at < words.high, "LCN_KIT_NIM: " & version
  (other, "-nim" & words[at + 1])

proc kitSwitches(): (seq[string], string) =
  ## [DECISIONS G341] A module library's own switch set and its variant
  ## suffix: `LCN_KIT_SWITCHES` when it is set (the `kit-toolchains-storage`
  ## and `kit-toolchains-delivery` checks build the libraries with
  ## logos-storage-nim's and logos-delivery's switches), split on white space and passed after the kit's own, so a
  ## switch it repeats wins; else none.
  let set = getEnv("LCN_KIT_SWITCHES").strip
  if set.len == 0:
    return (@[], "")
  var h = 0'u32 # FNV-1a: a stable name for the set's build directory
  for c in set:
    h = (h xor uint32(ord(c))) * 16777619'u32
  (set.splitWhitespace, "-sw" & toHex(h).toLowerAscii)

proc kitVariantOf*(mm: string): string =
  ## `kitVariant` for a library built with `mm` (and `LCN_KIT_NIM`,
  ## `LCN_KIT_SWITCHES`).
  mm & kitVariant[kitMm.len .. ^1] & kitCompiler()[1] & kitSwitches()[1]

proc exportListFlags*(tree: KitTree, kit: string): seq[string] =
  ## [DECISIONS G341] The link switch for the export list lcn-gen wrote for
  ## the kit `kit` (`<kit>_kit.exports` or `.map`, in the tree's generated
  ## directories); none on Windows, where a library exports only what it marks
  ## for export.
  when defined(macosx):
    @[
      "--passL:-Wl,-exported_symbols_list," &
        locate(tree.generated, kit & "_kit.exports")
    ]
  elif defined(windows):
    @[]
  else:
    @["--passL:-Wl,--version-script=" & locate(tree.generated, kit & "_kit.map")]

proc buildKitLibraryIn*(
    tree: KitTree,
    source, name: string,
    mm = kitMm,
    exports = "",
    strictDestroy = true,
    reason = "",
): string =
  ## The kit source `source` as `lib<name>` under the tree's build directory,
  ## in `<variant>/`, built with `mm` (by default this build's) and, when
  ## `exports` names a kit, linked with that kit's export list. A confined kit
  ## is strict about destroy unless `strictDestroy` is false, which takes a
  ## `reason` (DECISIONS G438).
  doAssert strictDestroy or reason.strip.len > 0,
    name & ": building a kit library without strict destroy takes a reason"
  let (compiler, _) = kitCompiler()
  let src = locate(tree.sources, source)
  let dir = tree.build / (kitVariantOf(mm) & (if strictDestroy: "-strict" else: ""))
  createDir(dir)
  if not strictDestroy:
    writeFile(dir / (name & ".lenient"), reason & "\n")
    echo "kitbuild: lib", name, " without strict destroy: ", reason
  result = dir / (DynlibFormat % name)
  let output =
    when defined(posix):
      result & ".tmp-" & $getCurrentProcessId()
    else:
      result
  # [DECISIONS G340] A module library leaves the process's signal dispositions
  # to its host: without -d:noSignalHandler its NimMain sets handlers for
  # SIGINT, SIGSEGV, SIGABRT, SIGFPE, SIGILL and SIGBUS and ignores SIGPIPE when
  # it is loaded (system/excpt.nim, `registerSignalHandler`).
  # A library that imports chronos records the host's SIGPIPE first and puts it
  # back last, whatever its main module imports first (P5): Nim initializes
  # an `--import:` module before any module of the library.
  var args = @[
    compiler,
    "c",
    "--hints:off",
    "--mm:" & mm,
    "-d:noSignalHandler",
    "--import:logos_sdk/base/hostsignals",
  ]
  when defined(release):
    args.add("-d:release")
  when kitSanitizer.len > 0:
    # [DECISIONS G342] A refc library is built without the sanitizer: refc's
    # conservative scan does not see what AddressSanitizer moves to its fake
    # stacks, and a refc build under -d:asan fails on its own (UBSan: a cell with
    # no type in `gc_common.prepareDealloc`, with no other manager in the
    # process). The project's sanitizer runs are orc builds (`logos_core.nimble`).
    if mm != "refc":
      args.add("-d:" & kitSanitizer)
  args.add(kitAuditFlags(false))
  if strictDestroy:
    args.add("-d:lcnKitStrictDestroy")
  args.add(kitSwitches()[0])
  args.add(hostPathArgs(src))
  if exports.len > 0:
    args.add(tree.exportListFlags(exports))
  args.add(
    [
      "--app:lib",
      "--nimMainPrefix:lib" & name,
      "--nimcache:" & dir / ("nimcache-" & name),
      "-o:" & output,
      src,
    ]
  )
  when defined(posix):
    let lock =
      posix.open(cstring(dir / (name & ".lock")), O_RDWR or O_CREAT or O_CLOEXEC, 0o644)
    doAssert lock >= 0, name & ".lock: " & osErrorMsg(osLastError())
    doAssert lockf(lock, F_LOCK, 0) == 0, name & ".lock: " & osErrorMsg(osLastError())
  let (log, code) = execCmdEx(quoteShellCommand(args))
  when defined(posix):
    if code == 0:
      moveFile(output, result)
    discard posix.close(lock) # releases the lock
  doAssert code == 0, "building " & source & " failed:\n" & log & withheldPathsNote(src)

template buildKitLibrary*(
    source, name: string, mm = kitMm, exports = "", strictDestroy = true, reason = ""
): string =
  ## `buildKitLibraryIn` with the calling suite's tree.
  buildKitLibraryIn(
    kitTreeOf(instantiationInfo(fullPaths = true).filename),
    source,
    name,
    mm,
    exports,
    strictDestroy,
    reason,
  )
