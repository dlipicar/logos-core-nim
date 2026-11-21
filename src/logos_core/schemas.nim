## Where core's schema documents are, in a checkout and in an installed package alike
## (DECISIONS G435): a dependent that generates from them, as the daemon generates its host
## configuration types, reads them through `coreSchemaDir`, never by a path into core's tree.

import std/os

const coreSchemaDir* = currentSourcePath().parentDir
  ## `logos_core/`: `runtime/host_config.cddl`, `authority/policy.cddl` and the rest
