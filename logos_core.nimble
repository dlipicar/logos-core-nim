# Package

version = "0.0.1"
author = "Dario Gabriel Lipicar"
description = "The Logos Core module specs in Nim"
license = "MIT OR Apache-2.0"
srcDir = "src"
installExt = @["nim"]

# Dependencies
#
# This file and nimble.lock are the only place dependency versions are decided.
# Nix builds from nimble.lock through nix/nimble-deps.json. After regenerating
# nimble.lock (`rm nimble.lock && nimble -y lock`), run `nix run .#update-nimble-deps`.

requires "nim == 2.2.14"
requires "results == 0.5.1"
requires "unittest2 == 0.3.0"

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
