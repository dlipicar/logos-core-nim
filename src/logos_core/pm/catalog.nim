## The catalog document, the protected catalog and the kept catalog (Tier 5
## step 5-3b; DECISIONS G401, amending G90 and replacing G150;
## docs/PACKAGE-MANAGER.md §3; PACKAGE MANAGER l.834-835, PKG-0472, PKG-0473).
## Both documents' schemas are `catalog.cddl`.
##
## - **The document** is unsigned deterministic CBOR, closed, with its entries
##   in canonical order and each `{identity, source}` once. Its entries are
##   untrusted location data (PKG-0115): a candidate reached through one is
##   judged by its own signature.
## - **The protected catalog** (PM l.1328, l.1331) is the document the
##   Package Manager's protected input pins by binding, locator and BLAKE3-256
##   digest. Bytes that do not match the digest are not read.
## - **No refresh.** A locator names fixed bytes for one provider, so reading
##   it again never gives a newer document; a new catalog is a new locator and
##   digest at logosd's next start.
## - **The kept catalog** is the last accepted document, in the state
##   directory. At start it is in use only while its locator and digest equal
##   the configured ones; it never stands in for another configured document.
## - **The sequence orders documents and claims no freshness** (C9, PKG-0112).
##   A document is accepted when its sequence is greater than the kept one's,
##   or equal with equal bytes; a lower sequence, or an equal one with other
##   bytes, is refused. After the state directory is lost, the first document
##   read is accepted.

{.push raises: [].}

import std/algorithm
import results
import logos_sdk/base/hex
import logos_sdk/cbor
import logos_sdk/crypto/blake3
import ../package/[records, semver]
import ./input

export results, records, blake3

const
  CatalogFormat* = "logos-core-nim.catalog.v1"
  KeptFormat* = "logos-core-nim.catalog-kept.v1"
  KeptName* = "catalog.kept" ## [G401] in the Package Manager's state directory

type
  Catalog* = object
    sequence*: uint64
    entries*: seq[CatalogEntry] ## in canonical order
    digest*: Blake3Digest ## of `bytes`
    bytes*: seq[byte] ## the document as it was read

  KeptCatalog* = object
    ## [G401] The last accepted document and the reference it was read by.
    storage*: string
    locator*: seq[byte]
    catalog*: Catalog

func entryOrder*(a, b: CatalogEntry): int =
  ## [G401; PM l.1657] The canonical order: package-name UTF-8 bytes, then
  ## descending SemVer precedence, then the source record's deterministic-CBOR
  ## bytes. A package version has no build metadata, so equal precedence is
  ## equal version text, and 0 means the same `{identity, source}`.
  let n = cmp(a.identity.package, b.identity.package)
  if n != 0:
    return n
  let va = parseSemVer(a.identity.version)
  let vb = parseSemVer(b.identity.version)
  if va.isOk and vb.isOk:
    let p = cmp(va.get, vb.get)
    if p != 0:
      return -p
  else:
    let t = cmp(a.identity.version, b.identity.version)
    if t != 0:
      return t
  cmpBytes(a.source.encoded, b.source.encoded)

func documentValue(sequence: uint64, entries: openArray[CatalogEntry]): CborValue =
  var items = newSeqOfCap[CborValue](entries.len)
  for e in entries:
    items.add(e.toCbor)
  cborMap(
    (cbor("format"), cbor(CatalogFormat)),
    (cbor("sequence"), cbor(sequence)),
    (cbor("entries"), CborValue(kind: ckArray, items: items)),
  )

func encodeCatalog*(
    sequence: uint64, entries: openArray[CatalogEntry]
): Result[seq[byte], string] =
  ## [G401] The canonical document for `entries` in any order: sorted, and
  ## refused when an `{identity, source}` repeats. One identity may have
  ## several sources (PM l.1329-1330); that is no repetition.
  var sorted = @entries
  sorted.sort(entryOrder)
  for i in 1 ..< sorted.len:
    if entryOrder(sorted[i - 1], sorted[i]) == 0:
      return err("the entry " & $sorted[i].identity & " repeats with the same source")
  ok(encodeCbor(documentValue(sequence, sorted)))

func onlyKeys(v: CborValue, keys: openArray[string]): Result[void, string] =
  ## A map with exactly `keys`, each once.
  if v.kind != ckMap:
    return err("not a map")
  for (k, _) in v.entries:
    if k.kind != ckText or k.text notin keys:
      return err("an unknown field")
  for k in keys:
    if v.lookup(k).isNone:
      return err("no " & k)
  ok()

proc decodeCatalog*(
    bytes: openArray[byte], maxBytes = MaxCatalogBytes, maxEntries = MaxCatalogEntries
): Result[Catalog, string] =
  ## [G401] A `lcn.package_catalog` document: within `maxBytes` and
  ## `maxEntries`, deterministic CBOR, closed, the right format, every entry
  ## one that `decodeCatalogEntry` accepts, in strictly canonical order. Any
  ## failure refuses the whole document.
  if bytes.len > maxBytes:
    return err("larger than " & $maxBytes & " bytes")
  let v = decodeCbor(bytes).valueOr:
    return err("not deterministic CBOR: " & $error)
  onlyKeys(v, ["format", "sequence", "entries"]).isOkOr:
    return err("not a catalog document: " & error)
  if v.lookup("format").get.getText != Opt.some(CatalogFormat):
    return err("format is not " & CatalogFormat)
  let s = v.lookup("sequence").get
  if s.kind != ckUint:
    return err("sequence is not an unsigned integer")
  let items = v.lookup("entries").get
  if items.kind != ckArray:
    return err("entries is not an array")
  if items.items.len > maxEntries:
    return err("more than " & $maxEntries & " entries")
  var c = Catalog(sequence: s.uint, digest: blake3(bytes), bytes: @bytes)
  for i, item in items.items:
    let e = decodeCatalogEntry(item).valueOr:
      return err("entry " & $i & ": " & error)
    if c.entries.len > 0:
      let o = entryOrder(c.entries[^1], e)
      if o == 0:
        return err("entry " & $i & " repeats " & $e.identity & " with the same source")
      if o > 0:
        return err("entry " & $i & " (" & $e.identity & ") is out of canonical order")
    c.entries.add(e)
  ok(c)

proc pinnedCatalog*(
    bytes: openArray[byte], pin: PmCatalogRef, limits = defaultLimits()
): Result[Catalog, string] =
  ## [G401] The protected catalog: bytes whose BLAKE3-256 is the pinned digest,
  ## checked before they are decoded, then `decodeCatalog`.
  if bytes.len > limits.catalogBytes:
    return err("larger than " & $limits.catalogBytes & " bytes")
  if blake3(bytes) != pin.digest:
    return err("its digest is not the pinned one")
  decodeCatalog(bytes, limits.catalogBytes, limits.catalogEntries)

# The kept catalog ------------------------------------------------------------------

func encodeKept*(k: KeptCatalog): seq[byte] =
  encodeCbor(
    cborMap(
      (cbor("format"), cbor(KeptFormat)),
      (cbor("storage"), cbor(k.storage)),
      (cbor("object"), cbor(k.locator)),
      (cbor("digest"), cbor(k.catalog.digest)),
      (cbor("document"), cbor(k.catalog.bytes)),
    )
  )

proc decodeKept*(
    bytes: openArray[byte], limits = defaultLimits()
): Result[KeptCatalog, string] =
  ## [G401] A `lcn.pm_catalog_kept` value whose document still has its digest
  ## and passes `decodeCatalog` under the current bounds.
  if bytes.len > limits.catalogBytes + 8192:
    return err("larger than the catalog bound")
  let v = decodeCbor(bytes).valueOr:
    return err("not deterministic CBOR: " & $error)
  onlyKeys(v, ["format", "storage", "object", "digest", "document"]).isOkOr:
    return err("not a kept catalog: " & error)
  if v.lookup("format").get.getText != Opt.some(KeptFormat):
    return err("format is not " & KeptFormat)
  let storage = v.lookup("storage").get.getText.valueOr:
    return err("storage is not text")
  let locator = v.lookup("object").get.getBytes.valueOr:
    return err("object is not bytes")
  let digest = v.lookup("digest").get.getBytes.valueOr:
    return err("digest is not bytes")
  let document = v.lookup("document").get.getBytes.valueOr:
    return err("document is not bytes")
  if storage.len < 1 or storage.len > 128 or locator.len < 1 or locator.len > 4096 or
      digest.len != Blake3OutLen:
    return err("a field is out of its bounds")
  var pin = PmCatalogRef(storage: storage, locator: locator)
  for i in 0 ..< Blake3OutLen:
    pin.digest[i] = digest[i]
  let c = ?pinnedCatalog(document, pin, limits)
  ok(KeptCatalog(storage: storage, locator: locator, catalog: c))

func matches*(k: KeptCatalog, pin: PmCatalogRef): bool =
  ## [G401] The kept document is the configured one: the same locator and the
  ## same digest.
  k.locator == pin.locator and k.catalog.digest == pin.digest

# Sequence continuity ---------------------------------------------------------------

type
  CatalogState* = object
    ## [G401] What the Package Manager holds: the configured pin, the kept
    ## document (if any) and the catalog in use (if any).
    pin*: PmCatalogRef
    limits*: PmLimits
    kept*: Opt[KeptCatalog]
    inUse*: Opt[Catalog]

  Offered* = object
    ## An accepted document, and the kept file's new bytes when they change.
    catalog*: Catalog
    keptBytes*: Opt[seq[byte]]

proc initCatalogState*(
    pin: PmCatalogRef, limits: PmLimits, keptBytes: Opt[seq[byte]]
): (CatalogState, Opt[string]) =
  ## [G401] The state at start, before any read: the kept document is in use
  ## when it matches the pin. A kept file that does not decode is set aside,
  ## as after the state directory's loss, and the second value says why.
  var s = CatalogState(pin: pin, limits: limits)
  var note = Opt.none(string)
  if keptBytes.isSome:
    let k = decodeKept(keptBytes.get, limits)
    if k.isOk:
      s.kept = Opt.some(k.get)
      if k.get.matches(pin):
        s.inUse = Opt.some(k.get.catalog)
    else:
      note = Opt.some("the kept catalog is set aside: " & k.error)
  (s, note)

proc offer*(s: var CatalogState, bytes: openArray[byte]): Result[Offered, string] =
  ## [G401] A document read by the pinned locator: the pinned digest, the
  ## document's rules, then sequence continuity against the kept one. On
  ## success it is the catalog in use and the new kept document; on failure
  ## nothing changes, so a catalog in use stays in use (PM l.480, PKG-0093).
  let c = ?pinnedCatalog(bytes, s.pin, s.limits)
  if s.kept.isSome:
    let k = s.kept.get.catalog
    if c.sequence < k.sequence:
      return err(
        "sequence " & $c.sequence & " is lower than the kept catalog's (" & $k.sequence &
          ")"
      )
    if c.sequence == k.sequence and c.bytes != k.bytes:
      return err(
        "sequence " & $c.sequence & " equals the kept catalog's, with other entries"
      )
  let kept = KeptCatalog(storage: s.pin.storage, locator: s.pin.locator, catalog: c)
  let same =
    s.kept.isSome and s.kept.get.locator == kept.locator and
    s.kept.get.storage == kept.storage and s.kept.get.catalog.bytes == c.bytes
  s.kept = Opt.some(kept)
  s.inUse = Opt.some(c)
  ok(
    Offered(
      catalog: c,
      keptBytes:
        if same:
          Opt.none(seq[byte])
        else:
          Opt.some(encodeKept(kept)),
    )
  )

func digestText*(c: Catalog): string =
  c.digest.toHex

{.pop.}
