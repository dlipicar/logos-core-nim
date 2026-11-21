## Run by `checkInstalls` in logos_core.nimble (first in every `nimble test*` task and in
## `build_runtime_lib`, and before `nimble build` in a checkout with `nimbledeps/`), and as its own
## step after `nimble setup` in CI and in `tools/ci/windows.ps1` [IMPL] (DECISIONS G436): each install
## `nimble.paths` names must be the one `nimble.lock` records. Nimble 0.26.2 checks no checksum of
## the lock (draft #191), so without this a changed or foreign install would run the suites. Run
## from the repository's root; exits 1 with one line per finding.
##
## It imports only the standard library and the SDK's helper, both from this tree: it is compiled
## from the installs it judges, so a third-party import would be built from them.

import std/os
import logos_sdk/testing/lockcheck

const developLinks: seq[string] = @[]
  ## Packages this repository may take from a `nimble develop` link instead of an install. None:
  ## core takes every locked package from an install. A name is added here, in a reviewed change,
  ## never through an environment variable or a flag, so the check cannot be turned off in passing.

proc main(): int =
  let findings = installMismatches(getCurrentDir(), developLinks)
  if findings.len == 0:
    echo "check_installs: every install nimble.paths names is the one nimble.lock records"
    return 0
  stderr.writeLine(
    "check_installs: the installs do not match nimble.lock (DECISIONS G436):"
  )
  for finding in findings:
    stderr.writeLine("  " & finding)
  1

when isMainModule:
  quit(main())
