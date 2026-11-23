## The catalog document, the protected catalog and the kept catalog (Tier 5
## step 5-3b; DECISIONS G401; docs/PACKAGE-MANAGER.md §3): the codec against
## `catalog.cddl` and the pinned PACKAGE MANAGER §6 entry rule, the canonical
## order, the bounds, the digest pin, and sequence continuity across starts.

import std/strutils
import unittest2
import logos_sdk/commitment
import logos_sdk/iface/accept
import ../src/logos_core/pins
import ./support/pmfixture

const CatalogCddl = staticRead("../src/logos_core/pm/catalog.cddl")

type CatalogSchema = object
  set: SchemaSet
  document, kept: SchemaNode

proc loadCatalogSchema(): CatalogSchema =
  ## `catalog.cddl` with the records it names, as the Package Manager's module
  ## document declares them. One document's declarations share one namespace,
  ## so the two `lcn.` rules are renamed into the module's; their bodies are
  ## the file's.
  let renamed = CatalogCddl.multiReplace(
    ("lcn.package_catalog", "logos.package_manager.lcn_package_catalog"),
    ("lcn.pm_catalog_kept", "logos.package_manager.lcn_pm_catalog_kept"),
  )
  let doc = recordsDocument().get & "\n" & renamed
  let c =
    acceptContractSet(doc, [], [PackageManifestDocument], AcceptOptions(system: true))
  doAssert c.isOk, c.error
  let m = c.get.primary.model
  CatalogSchema(
    set: c.get.schemaSet,
    document: m.find("logos.package_manager.lcn_package_catalog").get.body,
    kept: m.find("logos.package_manager.lcn_pm_catalog_kept").get.body,
  )

let schema = loadCatalogSchema()

proc validDocument(bytes: openArray[byte]): bool =
  let v = decodeCbor(bytes)
  v.isOk and schema.set.validates(0, schema.document, v.get)

proc validKept(bytes: openArray[byte]): bool =
  let v = decodeCbor(bytes)
  v.isOk and schema.set.validates(0, schema.kept, v.get)

proc rawDocument(
    entries: openArray[CborValue], sequence = 1'u64, format = CatalogFormat
): seq[byte] =
  encodeCbor(
    cborMap(
      (cbor("format"), cbor(format)),
      (cbor("sequence"), cbor(sequence)),
      (cbor("entries"), cborArray(entries)),
    )
  )

proc refusal(
    bytes: openArray[byte], maxBytes = MaxCatalogBytes, maxEntries = MaxCatalogEntries
): string =
  let r = decodeCatalog(bytes, maxBytes, maxEntries)
  check r.isErr
  if r.isErr: r.error else: ""

proc nixEntry(): CatalogEntry =
  CatalogEntry(
    identity: PackageIdentity(package: "logos.nixonly", version: "1.0.0"),
    source: PackageSource(kind: skNix, flakeRef: "github:logos-co/example"),
  )

proc mixed(): seq[CatalogEntry] =
  ## Out of canonical order on purpose: two sources for one identity, a
  ## pre-release, a two-digit minor and a second package.
  @[
    entryOf("logos.wallet", "2.0.0"),
    entryOf("logos.example", "1.0.0-rc.1"),
    entryOf("logos.example", "1.10.0", locator = "b"),
    entryOf("logos.example", "1.0.0"),
    entryOf("logos.example", "1.9.0"),
    entryOf("logos.example", "1.10.0", locator = "a"),
  ]

suite "catalog document (G401)":
  test "[PKG-0472] the document is canonical: names ascending, SemVer descending, then source bytes":
    let bytes = encodeCatalog(4, mixed()).get
    let c = decodeCatalog(bytes)
    check c.isOk
    var order: seq[string]
    for e in c.get.entries:
      order.add($e.identity & " " & textOf(e.source.objectLocator))
    check order ==
      @[
        "logos.example@1.10.0 a", "logos.example@1.10.0 b",
        "logos.example@1.9.0 logos.example@1.9.0",
        "logos.example@1.0.0 logos.example@1.0.0",
        "logos.example@1.0.0-rc.1 logos.example@1.0.0-rc.1",
        "logos.wallet@2.0.0 logos.wallet@2.0.0",
      ]
    check c.get.sequence == 4
    check c.get.digest == blake3(bytes)
    check c.get.bytes == bytes

  test "the encoding does not depend on the input order, and decoding it gives it back":
    var reversed = mixed()
    for i in 0 ..< reversed.len div 2:
      swap(reversed[i], reversed[reversed.high - i])
    let a = encodeCatalog(1, mixed()).get
    let b = encodeCatalog(1, reversed).get
    check a == b
    let c = decodeCatalog(a).get
    check encodeCatalog(c.sequence, c.entries).get == a

  test "the document and the kept catalog match catalog.cddl and the PM §6 entry rule":
    let bytes = encodeCatalog(2, mixed() & @[nixEntry()]).get
    check bytes.validDocument
    check rawDocument([], format = "logos-core-nim.catalog.v2").validDocument == false
    let c = decodeCatalog(bytes).get
    let kept =
      encodeKept(KeptCatalog(storage: "main", locator: bytesOf("catalog"), catalog: c))
    check kept.validKept
    check decodeKept(kept).isOk

  test "one identity with several sources is no repetition; the same source twice is":
    let two = encodeCatalog(
      1,
      [
        entryOf("logos.example", "1.0.0", locator = "a"),
        entryOf("logos.example", "1.0.0", locator = "b"),
      ],
    )
    check two.isOk
    let same = encodeCatalog(
      1, [entryOf("logos.example", "1.0.0"), entryOf("logos.example", "1.0.0")]
    )
    check same.isErr
    check same.error == "the entry logos.example@1.0.0 repeats with the same source"
    let raw = rawDocument(
      [
        entryOf("logos.example", "1.0.0").toCbor,
        entryOf("logos.example", "1.0.0").toCbor,
      ]
    )
    check raw.refusal == "entry 1 repeats logos.example@1.0.0 with the same source"

  test "[PKG-0472] a document out of canonical order is refused whole":
    let lower = rawDocument(
      [
        entryOf("logos.example", "1.0.0").toCbor,
        entryOf("logos.example", "1.1.0").toCbor,
      ]
    )
    check lower.refusal == "entry 1 (logos.example@1.1.0) is out of canonical order"
    let names = rawDocument(
      [
        entryOf("logos.wallet", "1.0.0").toCbor,
        entryOf("logos.example", "1.0.0").toCbor,
      ]
    )
    check names.refusal == "entry 1 (logos.example@1.0.0) is out of canonical order"
    let sources = rawDocument(
      [
        entryOf("logos.example", "1.0.0", locator = "b").toCbor,
        entryOf("logos.example", "1.0.0", locator = "a").toCbor,
      ]
    )
    check sources.refusal == "entry 1 (logos.example@1.0.0) is out of canonical order"

  test "a nix entry is kept in the document":
    let bytes = encodeCatalog(1, [entryOf("logos.example", "1.0.0"), nixEntry()]).get
    let c = decodeCatalog(bytes).get
    check c.entries.len == 2
    check c.entries[1].source.kind == skNix

  test "[PKG-0115] [PKG-0473] an entry carries location only: an entry with a signer, a key or a hash is refused":
    for field in ["signer", "public_key", "commitment", "kid"]:
      var e = entryOf("logos.example", "1.0.0").toCbor
      e.entries.add((cbor(field), cbor(newSeq[byte](48))))
      check rawDocument([e]).refusal.startsWith("entry 0: ")

  test "every malformed document is refused whole":
    let good = entryOf("logos.example", "1.0.0").toCbor
    check rawDocument([good], format = "logos-core-nim.catalog.v2").refusal ==
      "format is not logos-core-nim.catalog.v1"
    let extra = encodeCbor(
      cborMap(
        (cbor("format"), cbor(CatalogFormat)),
        (cbor("sequence"), cbor(1)),
        (cbor("entries"), cborArray(good)),
        (cbor("signature"), cbor(newSeq[byte](4))),
      )
    )
    check extra.refusal == "not a catalog document: an unknown field"
    let missing = encodeCbor(
      cborMap((cbor("format"), cbor(CatalogFormat)), (cbor("entries"), cborArray(good)))
    )
    check missing.refusal == "not a catalog document: no sequence"
    let textual = encodeCbor(
      cborMap(
        (cbor("format"), cbor(CatalogFormat)),
        (cbor("sequence"), cbor("1")),
        (cbor("entries"), cborArray(good)),
      )
    )
    check textual.refusal == "sequence is not an unsigned integer"
    let negative = encodeCbor(
      cborMap(
        (cbor("format"), cbor(CatalogFormat)),
        (cbor("sequence"), cbor(-1'i64)),
        (cbor("entries"), cborArray(good)),
      )
    )
    check negative.refusal == "sequence is not an unsigned integer"
    let badVersion = entryOf("logos.example", "1.0").toCbor
    check rawDocument([badVersion]).refusal.startsWith("entry 0: ")
    var bytes = rawDocument([good])
    bytes.add(0'u8)
    check bytes.refusal.startsWith("not deterministic CBOR")
    check bytesOf("not cbor").refusal.startsWith("not deterministic CBOR")
    check encodeCbor(cborArray()).refusal == "not a catalog document: not a map"

  test "the bounds: bytes, then entries":
    let bytes = encodeCatalog(1, mixed()).get
    check bytes.refusal(maxBytes = bytes.len - 1) ==
      "larger than " & $(bytes.len - 1) & " bytes"
    check decodeCatalog(bytes, maxBytes = bytes.len).isOk
    check bytes.refusal(maxEntries = 5) == "more than 5 entries"
    check decodeCatalog(bytes, maxEntries = 6).isOk

suite "the protected catalog (G401)":
  test "only the pinned bytes are read":
    let bytes = encodeCatalog(1, mixed()).get
    let pin = pinOf(bytes)
    check pinnedCatalog(bytes, pin).isOk
    let other = encodeCatalog(2, mixed()).get
    let r = pinnedCatalog(other, pin)
    check r.isErr
    check r.error == "its digest is not the pinned one"
    # Bytes that are not even CBOR fail the pin, not the decoder.
    let junk = pinnedCatalog(bytesOf("junk"), pin)
    check junk.error == "its digest is not the pinned one"

  test "the size bound comes before the digest":
    let bytes = encodeCatalog(1, mixed()).get
    var l = defaultLimits()
    l.catalogBytes = bytes.len - 1
    let r = pinnedCatalog(bytes, pinOf(bytes), l)
    check r.error == "larger than " & $(bytes.len - 1) & " bytes"

  test "the entry bound of the input applies":
    let bytes = encodeCatalog(1, mixed()).get
    var l = defaultLimits()
    l.catalogEntries = 2
    let r = pinnedCatalog(bytes, pinOf(bytes), l)
    check r.error == "more than 2 entries"

suite "the kept catalog and sequence continuity (G401)":
  test "[PKG-0092] with no kept catalog (a first start, or after the state is lost) the first document is accepted":
    let bytes = encodeCatalog(9, mixed()).get
    var (s, note) = initCatalogState(pinOf(bytes), defaultLimits(), Opt.none(seq[byte]))
    check note.isNone
    check s.inUse.isNone
    check s.kept.isNone
    let r = s.offer(bytes)
    check r.isOk
    check r.get.catalog.sequence == 9
    check r.get.keptBytes.isSome
    check s.inUse.get.bytes == bytes
    let kept = decodeKept(r.get.keptBytes.get).get
    check kept.storage == "main"
    check kept.locator == bytesOf("catalog")
    check kept.catalog.bytes == bytes

  test "[PKG-0093] across a restart the kept catalog is in use when its locator and digest match":
    let bytes = encodeCatalog(3, mixed()).get
    let pin = pinOf(bytes)
    var (first, _) = initCatalogState(pin, defaultLimits(), Opt.none(seq[byte]))
    let kept = first.offer(bytes).get.keptBytes
    var (s, note) = initCatalogState(pin, defaultLimits(), kept)
    check note.isNone
    check s.inUse.isSome
    check s.inUse.get.bytes == bytes
    # Reading the same document again changes nothing and writes nothing.
    let again = s.offer(bytes)
    check again.isOk
    check again.get.keptBytes.isNone
    # A failed read keeps the catalog in use.
    let failed = s.offer(bytesOf("other bytes"))
    check failed.isErr
    check s.inUse.get.bytes == bytes

  test "a kept catalog never stands in for another configured one":
    let old = encodeCatalog(3, mixed()).get
    var (first, _) = initCatalogState(pinOf(old), defaultLimits(), Opt.none(seq[byte]))
    let kept = first.offer(old).get.keptBytes
    let fresh = encodeCatalog(4, mixed()[0 .. 2]).get
    # Another digest, the same locator.
    var (s, _) = initCatalogState(pinOf(fresh), defaultLimits(), kept)
    check s.inUse.isNone
    check s.kept.isSome
    # The same digest under another locator is another configured catalog too.
    var (t, _) =
      initCatalogState(pinOf(old, locator = "elsewhere"), defaultLimits(), kept)
    check t.inUse.isNone

  test "[PKG-0091] [PKG-0472] the sequence rules: greater, equal and identical, equal and different, lower":
    let base = encodeCatalog(5, mixed()).get
    var (first, _) = initCatalogState(pinOf(base), defaultLimits(), Opt.none(seq[byte]))
    let kept = first.offer(base).get.keptBytes
    proc tryDoc(
        bytes: seq[byte], locator = "catalog"
    ): (Result[Offered, string], CatalogState) =
      var (s, _) =
        initCatalogState(pinOf(bytes, locator = locator), defaultLimits(), kept)
      let r = s.offer(bytes)
      (r, s)

    let greater = tryDoc(encodeCatalog(6, mixed()[0 .. 1]).get)
    check greater[0].isOk
    check greater[1].inUse.get.sequence == 6
    check greater[1].kept.get.catalog.sequence == 6
    let identical = tryDoc(base, locator = "copy")
    check identical[0].isOk
    check identical[0].get.keptBytes.isSome # another locator is written
    let different = tryDoc(encodeCatalog(5, mixed()[0 .. 1]).get)
    check different[0].isErr
    check different[0].error ==
      "sequence 5 equals the kept catalog's, with other entries"
    check different[1].inUse.isNone
    check different[1].kept.get.catalog.bytes == base
    let lower = tryDoc(encodeCatalog(4, mixed()).get)
    check lower[0].isErr
    check lower[0].error == "sequence 4 is lower than the kept catalog's (5)"
    check lower[1].inUse.isNone
    check lower[1].kept.get.catalog.sequence == 5

  test "[PKG-0093] every refusal keeps what was there":
    let base = encodeCatalog(5, mixed()).get
    var (first, _) = initCatalogState(pinOf(base), defaultLimits(), Opt.none(seq[byte]))
    let kept = first.offer(base).get.keptBytes
    let good = entryOf("logos.example", "1.0.0").toCbor
    for bad in [
      rawDocument([good], sequence = 6, format = "x"),
      rawDocument(
        [
          entryOf("logos.example", "1.0.0").toCbor,
          entryOf("logos.example", "2.0.0").toCbor,
        ],
        sequence = 6,
      ),
      rawDocument([good, good], sequence = 6),
      bytesOf("junk"),
    ]:
      var (s, _) = initCatalogState(pinOf(bad), defaultLimits(), kept)
      let r = s.offer(bad)
      check r.isErr
      check s.inUse.isNone
      check s.kept.get.catalog.bytes == base

  test "a kept file that does not decode is set aside":
    let base = encodeCatalog(5, mixed()).get
    var (s, note) =
      initCatalogState(pinOf(base), defaultLimits(), Opt.some(bytesOf("junk")))
    check note.isSome
    check note.get.startsWith("the kept catalog is set aside: ")
    check s.kept.isNone
    check s.inUse.isNone
    check s.offer(base).isOk

  test "a kept file whose document lost its digest is set aside":
    let base = encodeCatalog(5, mixed()).get
    let c = decodeCatalog(base).get
    var k = KeptCatalog(storage: "main", locator: bytesOf("catalog"), catalog: c)
    k.catalog.bytes = encodeCatalog(5, mixed()[0 .. 1]).get
    let bytes = encodeKept(k)
    let r = decodeKept(bytes)
    check r.isErr
    check r.error == "its digest is not the pinned one"

  test "[PKG-0112] no field of either document calls the sequence fresh":
    let bytes = encodeCatalog(5, mixed()).get
    let c = decodeCatalog(bytes).get
    let kept =
      encodeKept(KeptCatalog(storage: "main", locator: bytesOf("catalog"), catalog: c))
    var keys: seq[string]
    for doc in [bytes, kept]:
      for (k, _) in decodeCbor(doc).get.entries:
        keys.add(k.getText.get)
    check keys ==
      @[
        "format", "entries", "sequence", "digest", "format", "object", "storage",
        "document",
      ]
    for k in keys:
      for word in ["fresh", "latest", "newest", "expires", "revoked"]:
        check word notin k
