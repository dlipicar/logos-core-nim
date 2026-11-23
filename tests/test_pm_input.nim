## The Package Manager's protected input (Tier 5 step 5-3b; DECISIONS G399,
## G404; docs/PACKAGE-MANAGER.md §2): its schema, its bounds and the rules
## beyond the schema, each refusing the whole input.

import std/strutils
import unittest2
import logos_sdk/cbor
import ../src/logos_core/package/resolver
import ./support/pmfixture

proc encoded(v: LcnPmInput): seq[byte] =
  v.encode.get

proc refusal(v: LcnPmInput): string =
  let r = decodePmInput(v.encoded)
  check r.isErr
  if r.isErr: r.error else: ""

proc refusal(bytes: seq[byte]): string =
  let r = decodePmInput(bytes)
  check r.isErr
  if r.isErr: r.error else: ""

proc document(): seq[byte] =
  catalogBytes([entryOf("logos.example", "1.0.0")])

proc withLimit(field: string, value: uint64): LcnPmInput =
  var l = LcnPmLimits()
  case field
  of "archive_bytes":
    l.archive_bytes = Opt.some(value)
  of "catalog_bytes":
    l.catalog_bytes = Opt.some(uint32(value))
  of "catalog_entries":
    l.catalog_entries = Opt.some(uint32(value))
  of "cache_entries":
    l.cache_entries = Opt.some(uint16(value))
  of "read_deadline_ms":
    l.read_deadline_ms = Opt.some(uint32(value))
  else:
    doAssert false
  pmValue(defaultTrust(), document(), limits = Opt.some(l))

suite "PM protected input (G399)":
  test "an input with every bound absent takes the defaults":
    let doc = document()
    let r = decodePmInput(pmValue(defaultTrust(), doc).encoded)
    check r.isOk
    let i = r.get
    check i.bindings == @[PmBinding(name: "main", instance: "storage_module")]
    check i.catalog.storage == "main"
    check i.catalog.locator == bytesOf("catalog")
    check i.catalog.digest == blake3(doc)
    check i.limits == defaultLimits()
    check i.limits.archiveBytes == 1 shl 30
    check i.limits.catalogBytes == 4 * 1024 * 1024
    check i.limits.catalogEntries == 65_536
    check i.limits.cacheEntries == 256
    check i.limits.readDeadlineMs == 300_000'u32
    check i.trustBytes == defaultTrust()
    check i.trust.len == 1
    check i.binding("main").isSome
    check i.binding("other").isNone

  test "toValue writes every bound out and decodes to the same input":
    let first = decodePmInput(pmValue(defaultTrust(), document()).encoded).get
    let again = decodePmInput(first.toValue.encoded)
    check again.isOk
    check again.get.bindings == first.bindings
    check again.get.catalog == first.catalog
    check again.get.limits == first.limits
    check again.get.trustBytes == first.trustBytes
    check first.toValue.limits.isSome

  test "several bindings keep their order, and the catalog may use any of them":
    let v = pmValue(
      defaultTrust(),
      document(),
      bindings = [("main", "storage_module"), ("mirror", "storage_module_2")],
      catalogStorage = "mirror",
    )
    let r = decodePmInput(v.encoded)
    check r.isOk
    check r.get.bindings.len == 2
    check r.get.bindings[1].name == "mirror"
    check r.get.catalog.storage == "mirror"

  test "each bound is accepted at 1 and at its maximum":
    for (field, high) in [
      ("archive_bytes", uint64(MaxArchiveBytes)),
      ("catalog_bytes", uint64(MaxCatalogBytes)),
      ("catalog_entries", uint64(MaxCatalogEntries)),
      ("cache_entries", uint64(MaxCacheEntries)),
      ("read_deadline_ms", uint64(MaxReadDeadlineMs)),
    ]:
      let low = decodePmInput(withLimit(field, 1).encoded)
      check low.isOk
      let top = decodePmInput(withLimit(field, high).encoded)
      check top.isOk

  test "each bound is refused at 0 and above its maximum":
    for (field, high) in [
      ("archive_bytes", uint64(MaxArchiveBytes)),
      ("catalog_bytes", uint64(MaxCatalogBytes)),
      ("catalog_entries", uint64(MaxCatalogEntries)),
      ("cache_entries", uint64(MaxCacheEntries)),
      ("read_deadline_ms", uint64(MaxReadDeadlineMs)),
    ]:
      let zero = withLimit(field, 0).refusal
      check zero == "limits." & field & " must be 1 to " & $high
      let over = withLimit(field, high + 1).refusal
      check over == "limits." & field & " must be 1 to " & $high

  test "the bounds set read as given":
    var l = LcnPmLimits(
      archive_bytes: Opt.some(4096'u64),
      catalog_bytes: Opt.some(2048'u32),
      catalog_entries: Opt.some(16'u32),
      cache_entries: Opt.some(2'u16),
      read_deadline_ms: Opt.some(50'u32),
    )
    let r =
      decodePmInput(pmValue(defaultTrust(), document(), limits = Opt.some(l)).encoded)
    check r.isOk
    check r.get.limits ==
      PmLimits(
        archiveBytes: 4096,
        catalogBytes: 2048,
        catalogEntries: 16,
        cacheEntries: 2,
        readDeadlineMs: 50,
      )

suite "PM protected input refusals (G399, G404)":
  test "no binding":
    let v = pmValue(defaultTrust(), document(), bindings = [])
    check v.refusal == "storage holds no binding"

  test "a binding named twice":
    let v =
      pmValue(defaultTrust(), document(), bindings = [("main", "a"), ("main", "b")])
    check v.refusal == "storage names the binding \"main\" twice"

  test "a catalog on no binding":
    let v = pmValue(defaultTrust(), document(), catalogStorage = "other")
    check v.refusal == "catalog.storage names \"other\", which is not a binding"

  test "[PKG-0086] [PKG-0087] [PKG-0090] a trust file that selects a catalog profile is refused (G404)":
    var t = trustOf([anchorOf("org", ["logos.example"])])
    t.catalog.selected = Opt.some("logos.catalog.example")
    let msg = pmValue(t.trustBytes, document()).refusal
    check msg.startsWith("trust: this implementation supports no catalog profile")

  test "[PKG-0086] [PKG-0090] a trust file that selects a provenance profile is refused (G404)":
    var t = trustOf([anchorOf("org", ["logos.example"])])
    t.provenance.selected = Opt.some("logos.provenance.example")
    let msg = pmValue(t.trustBytes, document()).refusal
    check msg.startsWith("trust: this implementation supports no provenance profile")

  test "trust bytes that are no trust file":
    let msg = pmValue(bytesOf("not cbor"), document()).refusal
    check msg.startsWith("trust: ")

  test "a trust file that breaks a rule of checkTrust":
    let t = trustOf([anchorOf("org", ["logos.wallet", "logos.example"])])
    let msg = pmValue(t.trustBytes, document()).refusal
    check msg.startsWith("trust: the package names of kid ")

  test "another format":
    var v = pmValue(defaultTrust(), document())
    let good = v.toCbor
    var entries: seq[CborEntry]
    for (k, x) in good.entries:
      if k.getText == Opt.some("format"):
        entries.add((k, cbor("logos-core-nim.pm-input.v2")))
      else:
        entries.add((k, x))
    let msg = encodeCbor(CborValue(kind: ckMap, entries: entries)).refusal
    check msg.startsWith("does not match lcn.pm_input")

  test "an unknown field (the input is closed)":
    let good = pmValue(defaultTrust(), document()).toCbor
    var entries = good.entries
    entries.add((cbor("extra"), cbor(1)))
    let msg = encodeCbor(CborValue(kind: ckMap, entries: entries)).refusal
    check msg.startsWith("does not match lcn.pm_input")

  test "a digest that is not 32 bytes":
    let good = pmValue(defaultTrust(), document()).toCbor
    var entries: seq[CborEntry]
    for (k, x) in good.entries:
      if k.getText == Opt.some("catalog"):
        var c = x
        for e in c.entries.mitems:
          if e.key.getText == Opt.some("digest"):
            e.value = cbor(newSeq[byte](31))
        entries.add((k, c))
      else:
        entries.add((k, x))
    let msg = encodeCbor(CborValue(kind: ckMap, entries: entries)).refusal
    check msg.startsWith("does not match lcn.pm_input")

  test "bytes that are not deterministic CBOR":
    var bytes = pmValue(defaultTrust(), document()).encoded
    bytes.add(0'u8)
    check bytes.refusal.startsWith("not deterministic CBOR")

  test "more than 16 MiB":
    let bytes = newSeq[byte](MaxPmInputBytes + 1)
    check bytes.refusal == "larger than 16 MiB"

proc withoutKey(v: CborValue, key: string): CborValue =
  ## `v`, a map, without `key`.
  var kept: seq[CborEntry]
  for (k, x) in v.entries:
    if k.getText.get("") != key:
      kept.add((k, x))
  cborMap(kept)

proc limitsBytes(limits: CborValue): seq[byte] =
  ## The default input with `resolver_limits` replaced by `limits`.
  let v = toCbor(pmValue(defaultTrust(), document()))
  var e: seq[CborEntry]
  for (k, x) in v.entries:
    if k.getText.get("") == "resolver_limits":
      e.add((k, limits))
    else:
      e.add((k, x))
  encodeCbor(cborMap(e))

suite "PM protected input: the resolver limits (G399, planning 2026-11-22)":
  test "[G399] the input's resolver limits reach the engine as written":
    let l = resolverLimits(7, 6, 5, 4).get
    let r = decodePmInput(
      pmValue(defaultTrust(), document(), resolverLimits = limitsValue(l)).encoded
    )
    check r.isOk
    let x = r.get.resolverLimits
    check x.names == 7
    check x.depth == 6
    check x.candidates == 5
    check x.attempts == 4
    let again = decodePmInput(r.get.toValue.encoded)
    check again.isOk
    check again.get.resolverLimits == x

  test "[G399] an input without resolver_limits is refused, naming the field (PM l.1251)":
    let v = toCbor(pmValue(defaultTrust(), document())).withoutKey("resolver_limits")
    let why = encodeCbor(v).refusal
    check "resolver_limits" in why

  test "[G399] a set that omits a limit is refused, naming the limit":
    for k in ResolverLimitKeys:
      let full = toCbor(limitsValue(MaxResolverLimits))
      let why = limitsBytes(full.withoutKey(k)).refusal
      check "resolver_limits" in why
      check k in why

  test "[G399] a zero or above-maximum limit is refused by decodeResolverLimits":
    var zero = limitsValue(MaxResolverLimits)
    zero.dependency_depth = 0
    let a = pmValue(defaultTrust(), document(), resolverLimits = zero).refusal
    check a == "resolver_limits: resolver limit dependency_depth is not positive"
    var high = limitsValue(MaxResolverLimits)
    high.assignment_attempts = uint64(MaxResolverLimits.attempts) + 1
    let b = pmValue(defaultTrust(), document(), resolverLimits = high).refusal
    check b.startsWith("resolver_limits: resolver limit assignment_attempts is above")

  test "[G399] an unknown key in resolver_limits is refused (the set is closed)":
    let full = toCbor(limitsValue(MaxResolverLimits))
    var e: seq[CborEntry]
    for (k, x) in full.entries:
      e.add((k, x))
    e.add((cbor("zz_extra"), cbor(1)))
    let why = limitsBytes(cborMap(e)).refusal
    check why.len > 0
