## A shared library whose load-time code leaves a mark: it creates the file
## named by `LCN_LOAD_MARKER`. `tests/test_realizer.nim` uses it to show that a
## library whose bytes fail verification is never mapped (LOADER §3, §12).
## It exports no module ABI symbol.

import std/os

let marker = getEnv("LCN_LOAD_MARKER")
if marker.len > 0:
  writeFile(marker, "loaded")
