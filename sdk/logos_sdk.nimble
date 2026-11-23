# Package

version = "0.1.0"
author = "Dario Gabriel Lipicar"
description =
  "Logos Core layer 1: CBOR, CDDL, hashing, commitments, INTERFACE, the generators and the module kit"
license = "MIT OR Apache-2.0"
srcDir = "src"
installExt = @["nim", "nims", "c", "h", "S", "cddl", "exports", "map"]
installFiles = @[
  "logos_sdk/crypto/blake3/LICENSE_A2", "logos_sdk/crypto/blake3/LICENSE_CC0",
  "logos_sdk/crypto/blake3/VERSION",
]
bin = @["lcn_gen"]
namedBin["lcn_gen"] = "lcn-gen"

when (NimbleMajor, NimbleMinor) < (0, 26):
  {.error: "logos_sdk needs Nimble >= 0.26".}

# Dependencies (DECISIONS G341, G433, G434)
#
# Ranges, because a module repository resolves them against its own libraries' locks. Each
# is a subset of what core pins exactly (logos_core.nimble), and lint-packaging checks that
# core's lock lies inside them. No unittest2: nothing under sdk/src imports it. A dependent
# whose tests use it requires it itself.

requires "nim >= 2.2.14 & < 2.3.0"
requires "results >= 0.5.0 & < 0.6.0"
requires "chronos >= 4.4.0 & < 4.5.0"
