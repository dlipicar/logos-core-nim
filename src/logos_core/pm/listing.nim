## `list_packages`' selection and order (Tier 5 step 5-6a-1; DECISIONS G500; PACKAGE
## MANAGER l.1656-1657): which catalog entries the method lists, and in what order.
## 5-6b serves the method to readers (C4), with its pages and cursors (G499); this is
## the part that does not depend on who asks.
##
## - **The selection** (l.1656): exact catalog identities whose source kind this
##   provider implements. It implements `lgx` (`ListedSources`); a `nix` entry is
##   omitted until 5-10's profile.
## - **The filter**: with `package`, only that package's entries.
## - **The order** (l.1657) is the catalog's canonical order (`entryOrder`), which a
##   catalog in use already has (`decodeCatalog`), so the selection keeps it.
##
## 5-6b-1 adds what both lists' pages share (G499, G500):
## - **`list_installed_packages`' order** (l.1660): package-name UTF-8 bytes,
##   descending SemVer precedence, then the manifest commitment's bytes. The index
##   keeps another order (version text, `installed.identityOrder`), so the engine
##   sorts each snapshot once by `installedOrder`, and a cursor's position is a
##   place in that order.
## - **`limit`** (l.1640-1641): absent, 100; present, 1 to 1000, else
##   `invalid-request`.
## - **The page byte budget** [IMPL; G500]: a page stops before a record that would
##   take its records' bytes past `PageBudget`, or at `limit`; a first record always
##   goes in, whatever its size (a record is within the admission bound, so a
##   one-record page fits the frame, §1.3 of the plan).
## - **A page's bytes** (`pageBytes`): `{packages: [...], ? next_cursor}` framed
##   around the records' encodings as they are, never decoded again. The keys sort
##   `packages` before `next_cursor` (bytewise, INTERFACE §4.4 item 1).

{.push raises: [].}

import results
import logos_sdk/cbor
import ../package/[manifest, records, semver]
import ./catalog

const
  DefaultLimit* = 100 ## [SPEC PM l.1640]
  MaxLimit* = 1000 ## [SPEC PM l.1641]
  PageBudget* = 256 * 1024
    ## [IMPL; G500] a page's records' bytes: about 80-90 ms a pass on the Mac under orc
    ## and 0.36 s on server.lan under refc at G497's measured rate (plan §5.4)

const ListedSources* = {skLgx}
  ## [IMPL; PM l.1656] the source kinds this provider implements: `nix` waits for
  ## 5-10's realization profile

func listed*(e: CatalogEntry, package: Opt[string]): bool =
  ## Whether `list_packages` lists `e`, with its optional `package` filter.
  e.source.kind in ListedSources and
    (package.isNone or package.get == e.identity.package)

func selection*(c: Catalog, package = Opt.none(string)): seq[int] =
  ## [SPEC PM l.1656-1657] The positions in `c.entries` that `list_packages` lists, in
  ## its order: the catalog's canonical order (`entryOrder`).
  for i, e in c.entries:
    if e.listed(package):
      result.add(i)

func limitOf*(limit: Opt[uint16]): Opt[int] =
  ## [SPEC PM l.1640-1641] The page's record limit; none: out of range
  ## (`invalid-request`).
  if limit.isNone:
    return Opt.some(DefaultLimit)
  let n = int(limit.get)
  if n < 1 or n > MaxLimit:
    return Opt.none(int)
  Opt.some(n)

func installedOrder*(
    a: PackageIdentity,
    ac: ManifestCommitment,
    b: PackageIdentity,
    bc: ManifestCommitment,
): int =
  ## [SPEC PM l.1660] `list_installed_packages`' order: package-name UTF-8 bytes,
  ## descending SemVer precedence, then the manifest commitment's deterministic-CBOR
  ## bytes. A version has no build metadata, so equal precedence is equal text.
  let n = cmp(a.package, b.package)
  if n != 0:
    return n
  let va = parseSemVer(a.version)
  let vb = parseSemVer(b.version)
  if va.isOk and vb.isOk:
    let p = cmp(va.get, vb.get)
    if p != 0:
      return -p
  else:
    let t = cmp(a.version, b.version)
    if t != 0:
      return t
  cmpBytes(encodeCbor(ac.toCbor), encodeCbor(bc.toCbor))

func fits*(used, next, count: int, budget = PageBudget): bool =
  ## [G500] Whether a record of `next` bytes joins a page of `count` records holding
  ## `used` bytes: the first always does.
  count == 0 or used + next <= budget

func pageText*(items: string, count: int, next: Opt[string]): string =
  ## [SPEC PM §15] One page, `{packages: [items], ? next_cursor: next}`, from `count`
  ## values encoded back to back in `items`, copied once.
  var head: seq[byte]
  head.writeHead(5, (if next.isSome: 2'u64 else: 1'u64))
  head.add(encodeCbor(cbor("packages")))
  head.writeHead(4, uint64(count))
  var tail: seq[byte]
  if next.isSome:
    tail.add(encodeCbor(cbor("next_cursor")))
    tail.add(encodeCbor(cbor(next.get)))
  result = newStringOfCap(head.len + items.len + tail.len)
  for b in head:
    result.add(char(b))
  result.add(items)
  for b in tail:
    result.add(char(b))
