## The Package Manager's protected input, `logos-core-nim.pm-input.v1` (Tier 5
## step 5-3b; DECISIONS G399; docs/PACKAGE-MANAGER.md §2). Its schema is
## `input.cddl` (generated codecs in `input_types.nim`).
##
## The embedding host writes it once per start (logosd's compose, from the
## daemon configuration's `package_manager` section and the trust file the
## start accepted), and the hosted Package Manager reads it at initialization
## through the protected realization input (G400). It is never module
## configuration: configuration must not carry protected trust input
## (CONFIGURATION l.58). The Package Manager checks it again here, whoever
## wrote it, so a refused selection or a malformed binding never reaches its
## engine (G404; BCP l.409-410).

{.push raises: [].}

import std/[sets, strutils]
import results
import logos_sdk/base/hex
import logos_sdk/cbor
import logos_sdk/crypto/blake3
import ../package/trustdoc
from ../package/resolver import
  ResolverLimits, decodeResolverLimits, names, depth, candidates, attempts
import ./input_types

export
  results, trustdoc, input_types, blake3, ResolverLimits, names, depth, candidates,
  attempts

const
  PmInputFormat* = "logos-core-nim.pm-input.v1"
  MaxPmInputBytes* = 16 * 1024 * 1024
    ## [IMPL; G400] the protected realization input's bound (`host_config.cddl`)
  MaxArchiveBytes* = 1 shl 30 ## [IMPL; G402] `limits.archive_bytes`' maximum and default
  MaxCatalogBytes* = 4 * 1024 * 1024 ## [IMPL; G401] `limits.catalog_bytes`'
  MaxCatalogEntries* = 65_536 ## [IMPL; G401] `limits.catalog_entries`'
  MaxCacheEntries* = 4096 ## [IMPL; G403] `limits.cache_entries`' maximum
  DefaultCacheEntries* = 256 ## [IMPL; G403]
  MaxReadDeadlineMs* = 86_400_000'u32 ## [IMPL; G402] one day
  DefaultReadDeadlineMs* = 300_000'u32
    ## [IMPL; G402, planning 2026-11-21] above storage_module's longest call at its
    ## defaults (120 s direct, 180 s private), and above its 120 s network phase for
    ## the wait after `not-ready`: the deadline catches a provider that broke its
    ## own bound; availability comes from `unavailable`.

type
  PmLimits* = object
    archiveBytes*: int64 ## one archive, held in memory while it is inspected
    catalogBytes*: int ## the catalog document
    catalogEntries*: int
    cacheEntries*: int ## the verification cache (G403)
    readDeadlineMs*: uint32
      ## one call, and the wait for `ready` after `not-ready` (G402)

  PmBinding* = object
    name*: string ## what an LGX source's `storage` names (PM l.854-857)
    instance*: string ## the `lcn.storage_fetch` provider instance

  PmCatalogRef* = object
    ## [G401] The protected catalog: the document's binding, locator and digest.
    storage*: string
    locator*: seq[byte]
    digest*: Blake3Digest

  PmInput* = object
    ## A checked input. `trust` is the package-signing trust input of `trustFile`,
    ## whose every rule passed (`trustdoc.acceptedSigning`).
    trustBytes*: seq[byte]
    trustFile*: LcnPackageTrust
    trust*: TrustInput
    bindings*: seq[PmBinding] ## in the input's order
    catalog*: PmCatalogRef
    resolverLimits*: ResolverLimits
      ## [SPEC PM §11 l.1241-1254] the resolver limits: required, the embedding
      ## host's resolved values, never a default of the Package Manager's
    limits*: PmLimits

func defaultLimits*(): PmLimits =
  PmLimits(
    archiveBytes: MaxArchiveBytes,
    catalogBytes: MaxCatalogBytes,
    catalogEntries: MaxCatalogEntries,
    cacheEntries: DefaultCacheEntries,
    readDeadlineMs: DefaultReadDeadlineMs,
  )

func bounded(field: string, v: uint64, high: uint64): Result[uint64, string] =
  if v < 1 or v > high:
    return err("limits." & field & " must be 1 to " & $high)
  ok(v)

func limitsOf(l: Opt[LcnPmLimits]): Result[PmLimits, string] =
  ## [G399] Each bound as `input.cddl` states it; an absent one is its default.
  var r = defaultLimits()
  if l.isNone:
    return ok(r)
  let x = l.get
  if x.archive_bytes.isSome:
    r.archiveBytes =
      int64(?bounded("archive_bytes", x.archive_bytes.get, uint64(MaxArchiveBytes)))
  if x.catalog_bytes.isSome:
    r.catalogBytes =
      int(?bounded("catalog_bytes", uint64(x.catalog_bytes.get), MaxCatalogBytes))
  if x.catalog_entries.isSome:
    r.catalogEntries =
      int(?bounded("catalog_entries", uint64(x.catalog_entries.get), MaxCatalogEntries))
  if x.cache_entries.isSome:
    r.cacheEntries =
      int(?bounded("cache_entries", uint64(x.cache_entries.get), MaxCacheEntries))
  if x.read_deadline_ms.isSome:
    r.readDeadlineMs = uint32(
      ?bounded(
        "read_deadline_ms", uint64(x.read_deadline_ms.get), uint64(MaxReadDeadlineMs)
      )
    )
  ok(r)

proc checkedValue*(v: LcnPmInput): Result[PmInput, string] =
  ## [G399] The rules beyond the schema, in order: the format; at least one
  ## binding, with unique names; the catalog's binding is one of them; the
  ## resolver limits; the bounds; the trust bytes as the trust file, with every rule of
  ## `trustdoc.checkTrust` (so a selected catalog or provenance profile refuses
  ## the input, G404).
  if v.format != PmInputFormat:
    return err("format is not " & PmInputFormat)
  if v.storage.len == 0:
    return err("storage holds no binding")
  var names = initHashSet[string]()
  var bindings: seq[PmBinding]
  for b in v.storage:
    if b.binding in names:
      return err("storage names the binding " & b.binding.escape & " twice")
    names.incl(b.binding)
    bindings.add(PmBinding(name: b.binding, instance: b.instance))
  if v.catalog.storage notin names:
    return err(
      "catalog.storage names " & v.catalog.storage.escape & ", which is not a binding"
    )
  if v.catalog.digest.len != Blake3OutLen:
    return err("catalog.digest is not 32 bytes")
  var digest: Blake3Digest
  for i in 0 ..< Blake3OutLen:
    digest[i] = v.catalog.digest[i]
  # [SPEC PM §11 l.1251-1253] One decoder for the set: exactly the four keys,
  # each positive and within its maximum. A refusal is a configuration
  # failure that names the field, before any root operation (l.1510).
  let resolver = decodeResolverLimits(toCbor(v.resolver_limits)).valueOr:
    return err("resolver_limits: " & error)
  let limits = ?limitsOf(v.limits)
  let file = decodeTrust(v.trust).valueOr:
    return err("trust: " & error)
  let signing = acceptedSigning(file).valueOr:
    return err("trust: " & error)
  ok(
    PmInput(
      trustBytes: v.trust,
      trustFile: file,
      trust: signing,
      bindings: bindings,
      catalog: PmCatalogRef(
        storage: v.catalog.storage, locator: v.catalog.`object`, digest: digest
      ),
      resolverLimits: resolver,
      limits: limits,
    )
  )

proc decodePmInput*(bytes: openArray[byte]): Result[PmInput, string] =
  ## [G399] One deterministic-CBOR `lcn.pm_input` within `MaxPmInputBytes`,
  ## closed, with every rule of `checkedValue`.
  if bytes.len > MaxPmInputBytes:
    return err("larger than 16 MiB")
  let v = decodeCbor(bytes).valueOr:
    return err("not deterministic CBOR: " & $error)
  if v.kind == ckMap:
    # [SPEC PM §11 l.1251] The resolver limits before the schema, by their own
    # decoder, so an absent set or an omitted limit is refused by name.
    var found = false
    for (k, x) in v.entries:
      if k.getText.get("") == "resolver_limits":
        found = true
        discard decodeResolverLimits(x).valueOr:
          return err("resolver_limits: " & error)
    if not found:
      return err("resolver_limits is absent: the Package Manager has no default")
  let x = LcnPmInput.fromCbor(v).valueOr:
    return err("does not match lcn.pm_input: " & error)
  checkedValue(x)

func binding*(i: PmInput, name: string): Opt[PmBinding] =
  for b in i.bindings:
    if b.name == name:
      return Opt.some(b)
  Opt.none(PmBinding)

func toValue*(i: PmInput): LcnPmInput =
  ## The value `i` was checked from, with every bound written out.
  var storage: seq[LcnPmBinding]
  for b in i.bindings:
    storage.add(LcnPmBinding(binding: b.name, instance: b.instance))
  LcnPmInput(
    trust: i.trustBytes,
    storage: storage,
    catalog: LcnPmCatalogRef(
      storage: i.catalog.storage,
      `object`: i.catalog.locator,
      digest: @(i.catalog.digest),
    ),
    resolver_limits: LcnPmResolverLimits(
      partial_closure_names: uint64(i.resolverLimits.names),
      dependency_depth: uint64(i.resolverLimits.depth),
      candidates_per_name: uint64(i.resolverLimits.candidates),
      assignment_attempts: uint64(i.resolverLimits.attempts),
    ),
    limits: Opt.some(
      LcnPmLimits(
        archive_bytes: Opt.some(uint64(i.limits.archiveBytes)),
        catalog_bytes: Opt.some(uint32(i.limits.catalogBytes)),
        catalog_entries: Opt.some(uint32(i.limits.catalogEntries)),
        cache_entries: Opt.some(uint16(i.limits.cacheEntries)),
        read_deadline_ms: Opt.some(i.limits.readDeadlineMs),
      )
    ),
  )

{.pop.}
