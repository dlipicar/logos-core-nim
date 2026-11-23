## `list_packages`' selection and order (Tier 5 step 5-6a-1; DECISIONS G500;
## `src/logos_core/pm/listing.nim`): which entries of a catalog in use the method lists,
## and in what order. 5-6b serves the method; this is the part that does not depend on
## who asks.

import std/[algorithm, sequtils]
import unittest2
import results
import ../src/logos_core/package/records
import ../src/logos_core/pm/[catalog, listing]
import ./support/pmfixture

proc nixEntry(name, version: string): CatalogEntry =
  CatalogEntry(
    identity: PackageIdentity(package: name, version: version),
    source: PackageSource(kind: skNix, flakeRef: "github:o/" & name),
  )

func names(c: Catalog, at: seq[int]): seq[string] =
  for i in at:
    result.add(c.entries[i].identity.package & "@" & c.entries[i].identity.version)

suite "pm.listing: list_packages' selection and order (PACKAGE MANAGER l.1656-1657; G500)":
  test "[IMPL-DECISION G500] the lgx entries in the catalog's canonical order, a nix entry omitted; the package filter keeps that package's entries":
    # Given out of order; the catalog in use is canonical (`decodeCatalog`).
    let entries = @[
      entryOf("lib", "1.0.0"),
      nixEntry("app", "3.0.0"),
      entryOf("app", "1.0.0"),
      entryOf("app", "2.0.0"),
      entryOf("lib", "1.2.0"),
      nixEntry("tool", "1.0.0"),
      entryOf("app", "2.0.0", locator = "mirror/app-2.0.0"), # a second source
    ]
    let c = decodeCatalog(catalogBytes(entries)).tryGet
    check c.entries.len == entries.len
    let all = selection(c)
    check c.names(all) ==
      @["app@2.0.0", "app@2.0.0", "app@1.0.0", "lib@1.2.0", "lib@1.0.0"]
    # The positions are increasing: the selection keeps the canonical order.
    check all == sorted(all)
    for i in all:
      check c.entries[i].source.kind == skLgx
    let apps = selection(c, Opt.some("app"))
    check c.names(apps) == @["app@2.0.0", "app@2.0.0", "app@1.0.0"]
    check selection(c, Opt.some("tool")).len == 0
    check selection(c, Opt.some("none")).len == 0
    check ListedSources == {skLgx}
    # The two sources of app 2.0.0 keep their order: the source record's bytes.
    let twoSources = apps.filterIt(c.entries[it].identity.version == "2.0.0")
    check twoSources.len == 2
    check entryOrder(c.entries[twoSources[0]], c.entries[twoSources[1]]) < 0
