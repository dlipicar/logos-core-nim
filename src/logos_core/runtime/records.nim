## RUNTIME §8: the resolved module record a direct realization starts from.
##
## Runtime combines accepted external facts (a Package Manager handoff, or the
## protected bootstrap, static registration and test-harness inputs §8 allows)
## with its own decisions, then validates the result before creating any
## Runtime-owned state from it (§8 l.1325-1328, l.1457). The first Tier 4
## slice takes records from host registration and test harnesses only (G55):
## each names one protected static binding or one accepted dynamic artifact,
## for direct mode (§8 l.1434-1438) or, since Tier 4b step 4b-3, a dynamic
## artifact for a Module Host (`hosted_dynamic`, placement `process`).
##
## [IMPL] An absent `implements`, `extends`, `requires` or
## `requested_permissions` is an empty sequence here; a decoder for an input
## that can encode a present but empty array rejects it before building a
## record (§8 l.1357).

{.push raises: [].}

import std/sets
import results
import logos_sdk/cbor
import logos_sdk/cbor/utf8
import logos_sdk/hash/hashinput
import logos_sdk/iface/names
import ../package/manifest
import logos_sdk/pins
import ./realizer

export hashinput.Digest, manifest.RequestedPermission, realizer.Strategy

const
  MaxPermissionNameBytes* = 128 ## [SPEC PM §4] `requested_permission.permission`
  MaxConstraintsBytes* = 1_048_576 ## [SPEC PM §4] `requested_permission.constraints`
  MaxReasonBytes* = 512 ## [SPEC PM §4] `requested_permission.reason`

type
  Cardinality* = enum
    ## [SPEC RUNTIME §9.2] `provider_requirement_cardinality`
    cardSingle = "single"
    cardAllVisible = "all-runtime-visible"

  ProviderRequirement* = object ## [SPEC PM §4] `provider_requirement`
    contract*: Digest ## the schema root of the required contract
    cardinality*: Cardinality

  ModuleRecord* = object
    ## [SPEC RUNTIME §8] One resolved module record for direct mode.
    module*: string ## the flat runtime module name (§1.3)
    strategy*: Strategy
    binding*: string ## the protected static binding (`direct_static`)
    artifact*: ArtifactRecord
      ## the accepted dynamic artifact (`direct_dynamic`, `hosted_dynamic`);
      ## its digest is accepted evidence only because a protected input
      ## supplied it (§8)
    placement*: string
      ## [SPEC LOADER §3; plan §2.6] `hosted_dynamic`'s placement: `process`
      ## is the one this Runtime realizes (Tier 4b step 4b-3)
    primaryContract*: Opt[Digest] ## expected primary contract root
    implements*: seq[Digest] ## expected implemented interface roots
    extends*: seq[Digest]
      ## [SPEC RUNTIME §8 l.1340-1344] expected extended contract roots: earlier
      ## contracts that a contract the module provides extends (CMT §9.1)
    requires*: seq[ProviderRequirement]
    requestedPermissions*: seq[RequestedPermission]
    stateAssignment*: Opt[string] ## Runtime's state assignment for the instance
    configuration*: Opt[Digest]
      ## [SPEC RUNTIME §8 l.1308-1309; CONFIG §2] the accepted configuration
      ## binding's digest (`config.bindingDigest`, DECISIONS I87 C4), when the
      ## module declares configuration. Only an accepted declaration supplies
      ## it; the binding itself travels beside the record.

func sized(s: string, lo, hi: int): bool =
  s.len >= lo and s.len <= hi and isValidUtf8(s)

func checkRecord*(r: ModuleRecord): Result[void, string] =
  ## [SPEC RUNTIME §8] Rejects a malformed record instead of creating a
  ## partially trusted registry entry from it (l.1457).
  checkModuleName(r.module, system = true).isOkOr:
    return err(error)
  case r.strategy
  of stDirectStatic:
    if not r.binding.sized(1, MaxBindingIdBytes):
      return err("a static binding identifier must have 1 to 128 UTF-8 bytes")
  of stDirectDynamic, stHostedDynamic:
    if r.strategy == stHostedDynamic and r.placement notin HostedPlacements:
      # [SPEC LOADER §3] One of the placement values; whether one is
      # advertised is the Loader's (`unsupported-strategy`, l.364).
      return err("unknown hosted placement")
    let a = r.artifact
    if not a.id.sized(1, MaxArtifactIdBytes):
      return err("an artifact id must have 1 to 128 UTF-8 bytes")
    if not a.localPath.sized(1, MaxLocalPathBytes):
      return err("an artifact path must have 1 to 4096 UTF-8 bytes")
    # [SPEC RUNTIME §8 l.1331] An unknown suite is rejected before any
    # realization is directed; the digest length is fixed by the type.
    if a.hashSuite != HashSuiteId:
      return err("unknown artifact hash suite")
  # [SPEC RUNTIME §8 l.1358; G394 r10] Implemented and extended commitments
  # are unique over the two arrays together.
  var seen = initHashSet[Digest]()
  for c in r.implements & r.extends:
    if c in seen:
      return err("an implemented or extended schema commitment repeats")
    seen.incl(c)
  if r.extends.len > 0 and r.primaryContract.isNone and r.implements.len == 0:
    # [G394 r11] R is silent; PM l.1142 refuses the same declaration, and
    # l.1344's earlier contracts are those of "a contract provided by the
    # module", which such a record names none of.
    return err("extends needs a primary_contract or implements")
  var required = initHashSet[Digest]()
  for q in r.requires:
    if q.contract in required:
      return err("two requires entries name one contract") # §8 l.1358
    required.incl(q.contract)
  var names = initHashSet[string]()
  for p in r.requestedPermissions:
    if not p.permission.sized(1, MaxPermissionNameBytes):
      return err("a permission name must have 1 to 128 UTF-8 bytes")
    if p.permission in names:
      return err("a requested permission name repeats") # §8 l.1359
    names.incl(p.permission)
    if p.constraints.len < 1 or p.constraints.len > MaxConstraintsBytes:
      return err("permission constraints must have 1 to 1048576 bytes")
    decodeCbor(p.constraints).isOkOr:
      # [SPEC RUNTIME §8 l.1372-1373] one Logos deterministic-CBOR value
      return err("permission constraints are not one deterministic-CBOR value")
    if p.reason.isSome and not p.reason.get.sized(1, MaxReasonBytes):
      return err("a permission reason must have 1 to 512 UTF-8 bytes")
  if r.stateAssignment.isSome:
    let s = r.stateAssignment.get
    if not s.sized(1, MaxAssignmentIdBytes) or not s.pathSafe:
      return err("a state assignment must be 1 to 128 bytes of [A-Za-z0-9._-]")
  ok()

func descriptor*(r: ModuleRecord): RealizationDescriptor =
  ## [SPEC RUNTIME §8; LOADER §3] What the realizer is asked to realize.
  RealizationDescriptor(
    strategy: r.strategy,
    module: r.module,
    binding: r.binding,
    artifact: r.artifact,
    placement: r.placement,
  )
