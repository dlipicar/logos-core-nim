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

task regen,
  "Rewrite the committed lcn-gen outputs (common types and mirrors, test fixtures)":
  exec "nim r --hints:off --outdir:build/tools tools/regen_nim.nim"
