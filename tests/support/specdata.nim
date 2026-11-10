## Test access to spec/mirrors and spec/pins.toml. Tests run from the repository
## root under both nimble and Nix.

import std/[os, parsecfg, streams, strutils]
import results
import ../../src/logos_core/base/hex

proc repoPath*(rel: string): string =
  rel

proc readRepoFile*(rel: string): string =
  readFile(repoPath(rel))

proc mirror*(rel: string): string =
  readRepoFile("spec/mirrors" / rel)

proc hexBytes*(s: string): seq[byte] =
  ## Hex digits with any whitespace in between.
  hex.fromHex(s.multiReplace((" ", ""), ("\n", ""), ("\t", ""), ("\r", ""))).get()

proc mirrorHex*(rel: string): seq[byte] =
  hexBytes(mirror(rel))

proc pin*(name: string, field = "value"): string =
  ## A field of the `[name]` table in spec/pins.toml.
  let cfg = loadConfig(newStringStream(readRepoFile("spec/pins.toml")))
  let value = cfg.getSectionValue(name, field)
  doAssert value.len > 0, "spec/pins.toml has no " & name & "." & field
  value
