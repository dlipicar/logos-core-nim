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

{.push raises: [].}

import results
import ./catalog

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
