## Builds `tests/support/trnpeer.nim`, the child-process peer of
## `test_transport_io`, with this build's memory manager, mode and sanitizer
## (the `kitbuild.nim` variant), so the peer always runs under the same
## sanitizer as the suite (`childbuild.nim`).

import ./childbuild

var built: string

proc peerProgram*(): string =
  ## The peer executable, built once per test process.
  if built.len == 0:
    built = buildChild("tests/support/trnpeer.nim", "trnpeer", "peer")
  built
