## Builds a `tests/kit/` source as a shared library (`--app:lib`) with this
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

import std/[os, osproc, strutils]
when defined(posix):
  import std/posix

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
  kitTestsDir = currentSourcePath().parentDir.parentDir
  nimExe = getCurrentCompilerExe()

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

proc kitVariantOf*(mm: string): string =
  ## `kitVariant` for a library built with `mm` (and `LCN_KIT_NIM`).
  mm & kitVariant[kitMm.len .. ^1] & kitCompiler()[1]

proc exportListFlags*(kit: string): seq[string] =
  ## [DECISIONS G341] The link switch for the export list lcn-gen wrote for
  ## the kit `kit` (`tests/generated/<kit>_kit.exports` or `.map`); none on
  ## Windows, where a library exports only what it marks for export.
  let base = kitTestsDir / "generated" / kit & "_kit"
  when defined(macosx):
    @["--passL:-Wl,-exported_symbols_list," & base & ".exports"]
  elif defined(windows):
    @[]
  else:
    @["--passL:-Wl,--version-script=" & base & ".map"]

proc buildKitLibrary*(source, name: string, mm = kitMm, exports = ""): string =
  ## `tests/kit/<source>` as `lib<name>` under `build/kit-dylib/<variant>/`,
  ## built with `mm` (by default this build's) and, when `exports` names a
  ## kit, linked with that kit's export list.
  let (compiler, _) = kitCompiler()
  let dir = kitTestsDir.parentDir / "build" / "kit-dylib" / kitVariantOf(mm)
  createDir(dir)
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
  var args = @[compiler, "c", "--hints:off", "--mm:" & mm, "-d:noSignalHandler"]
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
  if exports.len > 0:
    args.add(exportListFlags(exports))
  args.add(
    [
      "--app:lib",
      "--nimMainPrefix:lib" & name,
      "--nimcache:" & dir / ("nimcache-" & name),
      "-o:" & output,
      kitTestsDir / "kit" / source,
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
  doAssert code == 0, "building " & source & " failed:\n" & log
