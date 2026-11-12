# Package

version = "0.0.1"
author = "Dario Gabriel Lipicar"
description = "The Logos Core module specs in Nim"
license = "MIT OR Apache-2.0"
srcDir = "src"
installExt = @["nim"]
bin = @["lcn_gen", "lcn_pkg"]
namedBin["lcn_gen"] = "lcn-gen"
namedBin["lcn_pkg"] = "lcn-pkg"

# Dependencies
#
# This file and nimble.lock are the only place dependency versions are decided.
# Nix builds from nimble.lock through nix/nimble-deps.json. After regenerating
# nimble.lock (`rm nimble.lock && nimble -y lock`), run `nix run .#update-nimble-deps`.

requires "nim == 2.2.14"
requires "results == 0.5.1"
requires "unittest2 == 0.3.0"
# BoringSSL for TLS 1.3 and QUIC (D28, tier 5); nothing imports it since package signing moved
# to SLH-DSA over the vendored slhdsa-c (DECISIONS I68).
requires "https://github.com/vacp2p/nim-boringssl == 0.0.14"
# Raw deflate and CRC-32 for LGX's gzip layer (PM §7.1).
requires "zlib == 0.3.0"
# The transport I/O thread's event loop (G77(a); DECISIONS I82). Only
# chronos/[asyncloop, timer, threadsync] are imported; stew is compiled with them, and
# httputils and bearssl (chronos's HTTP and TLS layers) are locked but never compiled.
# Every transitive package is pinned exactly, and before chronos: nimble 0.20.1 caches a
# download under the version its first requirement names, so chronos's `>=` ranges coming
# first would leave the pinned versions' entries checked out at the newest tag.
requires "stew == 0.5.2"
requires "httputils == 0.5.1"
requires "bearssl == 0.2.13"
requires "chronos == 4.4.1"

# Tasks

import std/[os, strutils]

proc runSuites(flags, outDir: string) =
  for file in listFiles("tests"):
    let name = file.extractFilename
    if name.startsWith("test_") and name.endsWith(".nim"):
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
  let dir = "build/lib/orc" & (if defined(release): "-release" else: "")
  mkDir(dir)
  exec "nim c --hints:off --mm:orc --app:lib --nimMainPrefix:liblogos_runtime" &
    (if defined(release): " -d:release" else: "") & " --nimcache:" & dir &
    "/nimcache-logos_runtime -o:" & dir & "/" & (
    when defined(macosx): "liblogos_runtime.dylib"
    elif defined(windows): "logos_runtime.dll"
    else: "liblogos_runtime.so"
  ) & " src/liblogos_runtime.nim"
  exec "nim r --hints:off --outdir:build/tools src/lcn_gen.nim logos-runtime --out:" &
    dir

task regen,
  "Rewrite the committed lcn-gen outputs (common types and mirrors, test fixtures)":
  exec "nim r --hints:off --outdir:build/tools tools/regen_nim.nim"
