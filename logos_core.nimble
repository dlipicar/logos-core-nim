# Package

version = "0.1.0"
author = "Dario Gabriel Lipicar"
description = "The Logos Core module specs in Nim"
license = "MIT OR Apache-2.0"
srcDir = "src"
installExt = @["nim", "c", "h", "cddl", "exports", "map"]
installFiles = @["logos_core/crypto/slhdsa/LICENSE", "logos_core/crypto/slhdsa/VERSION"]
bin = @["lcn_pkg", "logos_module_host"]
namedBin["lcn_pkg"] = "lcn-pkg"
namedBin["logos_module_host"] = "logos-module-host"
# logosd and logosctl need unix-stream sockets, peer credentials and signals: POSIX hosts
# only (DECISIONS I95; docs/DAEMON.md). The Module Host lands beside logosd, where its
# default lookup finds it.
when not defined(windows):
  bin.add ["logosd", "logosctl"]

# [DECISIONS G436] Nimble 0.26.2 or later: 0.20.1 empties or crashes on a lock made over an existing
# one, and on macOS crashes without --useSystemNim. Every Nimble command passes --useSystemNim, so
# Nimble neither installs nor locks a Nim: the one on the path must be the pin below.
when (NimbleMajor, NimbleMinor) < (0, 26):
  {.error: "logos_core needs Nimble >= 0.26".}

# Dependencies
#
# This file and nimble.lock are the only place dependency versions are decided.
# Nix builds from nimble.lock through nix/nimble-deps.json. After regenerating
# nimble.lock (`rm nimble.lock && nimble --useSystemNim -y lock`), run
# `nix run .#update-nimble-deps`. The lock has no `nim` entry.

requires "nim == 2.2.14"
requires "results == 0.5.1"
requires "unittest2 == 0.3.0"
# BoringSSL for TLS 1.3 and QUIC (D28). Only `transport/tls/boring.nim` imports it (the tls-tcp
# carrier, DECISIONS I99), so only the TLS suite and the TLS programs compile it.
requires "https://github.com/iftech/nim-boringssl == 0.0.16"
# Raw deflate and CRC-32 for LGX's gzip layer (PM §7.1).
requires "zlib == 0.3.0"
# The transport I/O thread's event loop (G77(a); DECISIONS I83), and the tls-tcp carrier's
# streams (I99), which also import chronos's TCP transports; stew is compiled with them, and
# httputils and bearssl (chronos's HTTP and TLS layers) are locked but never compiled.
# Every transitive package is pinned exactly, and before chronos: Nimble caches each download
# under the version range of the first requirement that names it, and its discovery follows
# chronos's `>=` ranges first when chronos comes first, so the pinned versions' entries would
# be checked out at the newest tag.
requires "stew == 0.5.2"
requires "httputils == 0.5.1"
requires "bearssl == 0.2.13"
requires "chronos == 4.4.1"

# Tasks

import std/[algorithm, os, strutils]

# `LCN_SHARD=k/n` runs every n-th suite of the sorted list, starting at the k-th (1-based), so CI
# can split one task across n jobs (.github/workflows/ci.yml). Unset, every suite runs.
proc shardOf(spec: string): (int, int) =
  if spec.len == 0:
    return (1, 1)
  let parts = spec.split('/')
  var k, n = 0
  if parts.len == 2:
    try:
      k = parseInt(parts[0])
      n = parseInt(parts[1])
    except ValueError:
      discard
  if n < 1 or k < 1 or k > n:
    echo "LCN_SHARD must be k/n with 1 <= k <= n, got '" & spec & "'"
    quit(QuitFailure)
  (k, n)

proc checkInstalls() =
  # [DECISIONS G436] Nimble 0.26.2 checks none of nimble.lock's checksums (draft #191), so every
  # install nimble.paths names is first compared with the lock's.
  exec "nim r --hints:off tools/check_installs.nim"

# Nimble also runs this hook when a dependent installs logos_core, in its buildtemp/ copy of the
# package, which leaves nimbledeps/ out: there the check is skipped. In a checkout set up with
# `setup -l` it runs. A checkout on global dependencies has no nimbledeps/ and is not checked.
before build:
  if dirExists(thisDir() / "nimbledeps"):
    checkInstalls()

proc runSuites(flags, outDir: string) =
  checkInstalls()
  var suites: seq[string]
  for dir in ["tests", "sdk/tests"]:
    for file in listFiles(dir):
      let name = file.extractFilename
      if name.startsWith("test_") and name.endsWith(".nim"):
        suites.add file
  suites.sort()
  let (k, n) = shardOf(getEnv("LCN_SHARD"))
  if n > 1:
    echo "Shard " & $k & "/" & $n & " of " & $suites.len & " suites"
  for i, file in suites:
    if i mod n == k - 1:
      exec "nim c -r " & flags & " --outdir:build/tests/" & outDir & " " & file

task test, "Run every test suite under --mm:orc":
  runSuites("--mm:orc", "orc")

task test_release, "Run every test suite under --mm:orc -d:release":
  runSuites("--mm:orc -d:release", "orc-release")

task test_refc, "Run every test suite under --mm:refc":
  runSuites("--mm:refc", "refc")

# The sanitizer switches are in config.nims, their run-time defaults in
# tests/support/sanitizers.c.
task test_asan, "Run every test suite under AddressSanitizer and UBSan":
  runSuites("--mm:orc -d:asan", "asan")

task test_tsan, "Run every test suite under ThreadSanitizer":
  runSuites("--mm:orc -d:tsan", "tsan")

task test_msan, "Run every test suite under MemorySanitizer (clang on Linux)":
  runSuites("--mm:orc -d:msan", "msan")

task build_runtime_lib,
  "Build liblogos_runtime and logos_runtime.h under build/lib/ (RUNTIME §13)":
  checkInstalls()
  let dir = "build/lib/orc" & (if defined(release): "-release" else: "")
  mkDir(dir)
  # -d:noSignalHandler: loading the library leaves the host's signal handlers (DECISIONS G340).
  exec "nim c --hints:off --mm:orc --app:lib --nimMainPrefix:liblogos_runtime -d:noSignalHandler" &
    (if defined(release): " -d:release" else: "") & " --nimcache:" & dir &
    "/nimcache-logos_runtime -o:" & dir & "/" & (
    when defined(macosx): "liblogos_runtime.dylib"
    elif defined(windows): "logos_runtime.dll"
    else: "liblogos_runtime.so"
  ) & " src/liblogos_runtime.nim"
  exec "nim r --hints:off --outdir:build/tools sdk/src/lcn_gen.nim logos-runtime --out:" &
    dir

task regen,
  "Rewrite the committed lcn-gen outputs (common types and mirrors, test fixtures)":
  exec "nim r --hints:off --outdir:build/tools tools/regen_nim.nim"
