## RUNTIME §8: the resolved module record a direct realization starts from.
##
## Runtime combines accepted external facts (a Package Manager handoff, or the
## protected bootstrap, static registration and test-harness inputs §8 allows)
## with its own decisions, then validates the result before creating any
## Runtime-owned state from it (§8 l.1398-1400, l.1543-1546). The first Tier 4
## slice takes records from host registration and test harnesses only (G55):
## each names one protected static binding or one accepted dynamic artifact,
## both for direct mode (§8 l.1515-1519).
##
## [IMPL] An absent `implements`, `requires` or `requested_permissions` is an
## empty sequence here; a decoder for an input that can encode a present but
## empty array rejects it before building a record (§8 l.1430-1432).

{.push raises: [].}

import std/sets
import results
import ../cbor
import ../cbor/utf8
import ../hash/hashinput
import ../iface/names
import ../package/manifest
import ../pins
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
    strategy*: Strategy ## `direct_static` or `direct_dynamic`
    binding*: string ## the protected static binding (`direct_static`)
    artifact*: ArtifactRecord
      ## the accepted dynamic artifact (`direct_dynamic`); its digest is
      ## accepted evidence only because a protected input supplied it (§8)
    primaryContract*: Opt[Digest] ## expected primary contract root
    implements*: seq[Digest] ## expected implemented interface roots
    requires*: seq[ProviderRequirement]
    requestedPermissions*: seq[RequestedPermission]
    stateAssignment*: Opt[string] ## Runtime's state assignment for the instance
    declaresConfiguration*: bool
      ## the input carried a configuration declaration (CONFIG is not built)

func sized(s: string, lo, hi: int): bool =
  s.len >= lo and s.len <= hi and isValidUtf8(s)

func checkRecord*(r: ModuleRecord): Result[void, string] =
  ## [SPEC RUNTIME §8] Rejects a malformed record instead of creating a
  ## partially trusted registry entry from it (l.1543-1546).
  checkModuleName(r.module, system = true).isOkOr:
    return err(error)
  case r.strategy
  of stDirectStatic:
    if not r.binding.sized(1, MaxBindingIdBytes):
      return err("a static binding identifier must have 1 to 128 UTF-8 bytes")
  of stDirectDynamic:
    let a = r.artifact
    if not a.id.sized(1, MaxArtifactIdBytes):
      return err("an artifact id must have 1 to 128 UTF-8 bytes")
    if not a.localPath.sized(1, MaxLocalPathBytes):
      return err("an artifact path must have 1 to 4096 UTF-8 bytes")
    # [SPEC RUNTIME §8 l.1405] An unknown suite is rejected before any
    # realization is directed; the digest length is fixed by the type.
    if a.hashSuite != HashSuiteId:
      return err("unknown artifact hash suite")
  of stHostedDynamic:
    # [IMPL] local-transport mode is not built (the slice is direct only).
    return err("hosted realization is not supported")
  var seen = initHashSet[Digest]()
  for c in r.implements:
    if c in seen:
      return err("an implemented schema commitment repeats") # §8 l.1432
    seen.incl(c)
  var names = initHashSet[string]()
  for p in r.requestedPermissions:
    if not p.permission.sized(1, MaxPermissionNameBytes):
      return err("a permission name must have 1 to 128 UTF-8 bytes")
    if p.permission in names:
      return err("a requested permission name repeats") # §8 l.1433
    names.incl(p.permission)
    if p.constraints.len < 1 or p.constraints.len > MaxConstraintsBytes:
      return err("permission constraints must have 1 to 1048576 bytes")
    decodeCbor(p.constraints).isOkOr:
      # [SPEC RUNTIME §8 l.1450-1452] one Logos deterministic-CBOR value
      return err("permission constraints are not one deterministic-CBOR value")
    if p.reason.isSome and not p.reason.get.sized(1, MaxReasonBytes):
      return err("a permission reason must have 1 to 512 UTF-8 bytes")
  if r.stateAssignment.isSome:
    let s = r.stateAssignment.get
    if not s.sized(1, MaxAssignmentIdBytes) or not s.pathSafe:
      return err("a state assignment must be 1 to 128 bytes of [A-Za-z0-9._-]")
  if r.declaresConfiguration:
    # [IMPL] I71, I74: no CONFIG handoff yet, so no record that declares
    # configuration is accepted (§8 l.1384-1386 requires validating it first).
    return err("module configuration is not supported yet")
  ok()

func descriptor*(r: ModuleRecord): RealizationDescriptor =
  ## [SPEC RUNTIME §8; LOADER §3] What the realizer is asked to realize.
  RealizationDescriptor(
    strategy: r.strategy, module: r.module, binding: r.binding, artifact: r.artifact
  )
