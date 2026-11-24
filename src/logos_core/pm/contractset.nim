## The Package Manager's contract set (Tier 5 step 5-6a-1; DECISIONS G490, G491): PACKAGE
## MANAGER App A from the pinned documents, with the manifest schema (PM §4) and the Module
## Configuration types (CONFIGURATION §9) it names, as the module's document declares them.
## The module checks its values with it (`installed.nim`), and logosd names its root as the
## composed instance's `primary_contract` (`daemon/compose.nim`), so that the Runtime gives
## the instance a provider record (RUNTIME §9.3 l.2862-2871). One computation for both, from
## the mirrored text, never a typed constant.

{.push raises: [], gcsafe.}

import std/strutils
import results
import logos_sdk/iface/accept
import logos_sdk/kit/rc_types
import ../pins

export results, accept

proc configurationTypes(): Result[string, string] =
  ## [SPEC CONFIGURATION §9] The Module Configuration types, as mirrored into the Runtime
  ## Control types (their supporting document, from `spec/mirrors/CFG/`).
  let (_, _, supporting) = rcDocuments()
  for d in supporting:
    if "logos.module_configuration.configuration_declaration =" in d:
      return ok(d)
  err("the Runtime Control types carry no Module Configuration types")

proc pmContractSet*(): Result[ContractSet, string] =
  ## [SPEC PM App A; G490] The `logos_package_manager` contract, a Logos system module's.
  let cfg = ?configurationTypes()
  acceptContractSet(
    PackageManagerContractDocument,
    [],
    [PackageManifestDocument, cfg],
    AcceptOptions(system: true),
  )
