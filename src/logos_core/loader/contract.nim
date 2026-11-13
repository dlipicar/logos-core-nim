## The Module Loader contract as data (Tier 4b step 4b-1; DECISIONS I89): its
## pinned roots, recomputed from the mirrored LOADER text (`spec/mirrors/LDR/`)
## the way `authority/scopes.nim` recomputes the Capability Authority's, and the
## names this implementation reserves for its one Loader instance.
##
## Pinned ids and roots are data, never hand-typed constants (CLAUDE.md): the
## engine compares a Loader instance's validated call surface with
## `loaderRoots().contract` when it binds it (RUNTIME l.1649).

{.push raises: [].}

import std/tables
import results
import ../commitment
import ../iface/[accept, names]
import ../base/perthread
import ./logos_module_loader_types

const
  LoaderModuleName* = "logos_module_loader"
    ## [SPEC LOADER l.35] The canonical flat runtime module name; the test
    ## suites check it against the name generated from the mirrored contract.
  LoaderInstanceId* = LoaderModuleName
    ## [IMPL-DECISION G246] The module instance id of the Runtime's one Loader
    ## instance. Reserved: no host configuration, `create_module` or
    ## orchestration field can name it (4b-5 and 4b-6 import it; C1).
  LoaderBindingId* = LoaderModuleName
    ## [IMPL-DECISION G246] The static binding id of the Loader's registration,
    ## known only to the Runtime's bootstrap mechanism; reserved like the id.

type
  LoaderMethod* = enum
    ## [SPEC LOADER §13] The five methods of the contract.
    lmListCapabilities = "list_capabilities"
    lmRealize = "realize"
    lmApplyConfiguration = "apply_configuration"
    lmGetStatus = "get_status"
    lmRelease = "release"

  LoaderRoots* = object
    contract*: seq[byte] ## the contract's schema root
    methods*: array[LoaderMethod, seq[byte]] ## each method's declaration root

proc loadRoots(): LoaderRoots =
  let docs = ldrDocuments()
  let set = acceptContractSet(docs[0], docs[1], docs[2], AcceptOptions(system: true))
  doAssert set.isOk, "the mirrored Module Loader contract does not accept: " & set.error
  let c = set.get.primary
  result.contract = @(c.root)
  var byName: Table[string, seq[byte]]
  for m in c.model.methods:
    byName[bareMethodName(m.name, c.model.namespace)] = @(declarationRoot(c.model, m))
  doAssert byName.len == LoaderMethod.high.ord + 1,
    "the Module Loader contract declares another set of methods"
  for m in LoaderMethod:
    doAssert $m in byName, "no Module Loader method " & $m
    result.methods[m] = byName.getOrDefault($m)

perThread(ldrRoots, LoaderRoots, loadRoots())

proc loaderRoots*(): lent LoaderRoots =
  ## [SPEC RUNTIME l.1645-1650; LOADER §13] The pinned Module Loader contract
  ## root and its method roots, recomputed from the mirrors once per thread.
  ldrRoots()

proc loaderContract*(): SchemaCommitment =
  ## The Module Loader contract (LOADER §3-§10) as a schema commitment.
  SchemaCommitment(schema_root: loaderRoots().contract)
