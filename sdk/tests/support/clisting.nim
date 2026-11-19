## [SPEC INTERFACE §2.1 l.801-814, §5.2 l.3324-3325] The §5.2 listing is
## copied, never derived, but the common types' structure is still derived
## (`cmap.commonDeclarations`), because the mirrors and the reverse mapper need
## to know which schema node each C item stands for. This compares the two by
## parsing the listing's common section. It runs in a test and when the common
## mirrors are generated; acceptance never parses the listing.

import std/[algorithm, sequtils, strutils]
import results
import logos_sdk/pins
import logos_sdk/iface/cmap
from logos_sdk/iface/cparse import parseHeader, render

const
  CommonStart = "/* -- Common schema value types -- */"
  CommonEnd = "/* -- Result type -- */"

proc commonSection*(): Result[string, string] =
  ## The listing's common section: the §2.3 empty types and the six common
  ## types with their support declarations, from its "Common schema value
  ## types" comment up to its "Result type" one. Each marker must occur once.
  for m in [CommonStart, CommonEnd]:
    if LogosTypesFixed.count(m) != 1:
      return
        err("the pinned §5.2 listing has " & $LogosTypesFixed.count(m) & " of " & m)
  let a = LogosTypesFixed.find(CommonStart)
  let b = LogosTypesFixed.find(CommonEnd)
  if b < a:
    return err("the pinned §5.2 listing's common section ends before it begins")
  ok(LogosTypesFixed[a ..< b])

proc itemsOf(name, text: string): Result[seq[string], string] =
  let h = parseHeader(name, text).valueOr:
    return err(name & " is outside the accepted C subset: " & $error)
  var res = h.items.mapIt(render(it))
  res.sort()
  ok(res)

proc listingDifferences*(declarations: seq[string]): Result[seq[string], string] =
  ## How `declarations` (the §2.3 empty types and the mapped common schema)
  ## differ from the listing's common section, compared by item in both
  ## directions: every item only one side declares. Empty when they agree in
  ## every name, tag, member, type, constant and value.
  let want = ?itemsOf("logos_types.h (INTERFACE §5.2)", ?commonSection())
  let got = ?itemsOf("the mapped common schema", declarations.join("\n\n"))
  var res: seq[string]
  for x in want:
    if x notin got:
      res.add("only the listing declares " & x)
  for x in got:
    if x notin want:
      res.add("only the mapping declares " & x)
  ok(res)

proc mappedCommon*(): seq[string] =
  ## What the mapping declares for the listing's common section.
  @[LogosTypesEmpty.strip] & commonDeclarations()

proc commonListingCheck*(): Result[void, string] =
  ## Fails, with every difference, unless the mapped common schema is the
  ## listing's common section.
  let d = ?listingDifferences(mappedCommon())
  if d.len > 0:
    return err("the mapped common schema is not the §5.2 listing: " & d.join("; "))
  ok()
