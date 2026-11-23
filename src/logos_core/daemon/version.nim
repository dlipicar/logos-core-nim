## The version logosd and logosctl report (Tier 4b step 4b-6; DECISIONS G88).
## `nimble build` defines `NimblePkgVersion` from the package's `version`; the
## flake passes `-d:lcnVersion=…` from the same value. A plain `nim c` reports
## core's version with `-dev` (lint-packaging keeps it so). G88's "1.0.0" applies
## at release.

const
  NimblePkgVersion {.strdefine.} = ""
  lcnVersion* {.strdefine.} =
    if NimblePkgVersion.len > 0: NimblePkgVersion else: "0.1.0-dev"
