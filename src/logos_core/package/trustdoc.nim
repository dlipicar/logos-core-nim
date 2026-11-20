## The package trust file, `logos-core-nim.trust.v2` (Tier 5 step 5-3a-2;
## DECISIONS G396, G398, G137; C2, C3; PACKAGE MANAGER l.401-449, l.733-745).
## Its schema is `trustdoc.cddl` (generated codecs in `trustdoc_types.nim`);
## docs/DAEMON.md §6 documents it.
##
## One revision covers the development switch, the signing profile, every
## anchor (kid, 48-byte key, exact package names, development marker) and the
## catalog and provenance selections, so all of it is under continuity
## (PKG-0418). Decoding and the rules are two steps: `decodeTrust` reads v2,
## or the Tier 4b v1 as the v2 content with no anchor and nothing selected,
## against the schema; `checkTrust` applies what the schema does not say. A
## reader that only shows the file decodes it; whoever accepts package
## material under it applies the rules, then converts it with
## `acceptedSigning`. Continuity is the caller's (logosd's
## `daemon/trustfile.nim`).

{.push raises: [].}

import std/strutils
import results
import logos_sdk/base/hex
import logos_sdk/cbor
import ./[trust, trustdoc_types]

export results, trust, trustdoc_types

const
  TrustFormat* = "logos-core-nim.trust.v2"
  TrustFormatV1* = "logos-core-nim.trust.v1" ## [IMPL; G396] read, never written
  FloorRevision* = 1'u64 ## [G137] the compiled-in floor
  MaxTrustBytes* = 1024 * 1024
    ## [IMPL; G396] The file's only bound, the same wherever it is read.

func floorTrust*(): LcnPackageTrust =
  ## [G137; G396] The compiled-in floor: revision 1, the switch off, no
  ## anchor, nothing selected.
  LcnPackageTrust(revision: FloorRevision)

proc decodeTrust*(bytes: openArray[byte]): Result[LcnPackageTrust, string] =
  ## [G396] One deterministic-CBOR value within `MaxTrustBytes`, against the
  ## schema of its format: `lcn.package_trust`, or `lcn.trust_file` (v1), read
  ## as the v2 content with no anchor and nothing selected. No rule of
  ## `checkTrust` is applied.
  if bytes.len > MaxTrustBytes:
    return err("larger than 1 MiB")
  let v = decodeCbor(bytes).valueOr:
    return err("not deterministic CBOR: " & $error)
  let format = v.lookup("format")
  if format.isSome and format.get.getText == Opt.some(TrustFormatV1):
    let f = LcnTrustFile.fromCbor(v).valueOr:
      return err("does not match lcn.trust_file: " & error)
    return ok(LcnPackageTrust(revision: f.revision, development: f.development))
  let t = LcnPackageTrust.fromCbor(v).valueOr:
    return err("does not match lcn.package_trust: " & error)
  ok(t)

func quoted(s: string): string =
  ## Text from the file, on one line.
  s.escape

func checkTrust*(t: LcnPackageTrust): Result[void, string] =
  ## [G396; G398] The rules beyond the schema, in order:
  ## - the revision is not below the floor (G137);
  ## - the anchors are in strictly ascending kid byte order, so no two share a
  ##   kid (PKG-0107);
  ## - each anchor names at least one package (PM l.417), in strictly
  ##   ascending UTF-8 byte order, so each once. One content has one
  ##   encoding, so a digest names contents, not spellings;
  ## - nothing is selected: no catalog profile is built (C9) and no provenance
  ##   profile until step 5-11 (C3), and a selected profile this
  ##   implementation does not support is refused (PM l.745).
  ## Names are compared byte for byte and none is special (PM l.418-419); a
  ## key is any 48 bytes, and two kids may share one (PM l.531-534).
  if t.revision < FloorRevision:
    return
      err("revision " & $t.revision & " is below the compiled-in floor (revision 1)")
  let anchors = t.signing.anchors
  for i, a in anchors:
    if i > 0 and cmpBytes(anchors[i - 1].kid, a.kid) >= 0:
      return
        err("the anchors are not in strictly ascending kid order at kid " & a.kid.toHex)
    if a.packages.len == 0:
      return err("kid " & a.kid.toHex & " authorizes no package name")
    for j in 1 ..< a.packages.len:
      if a.packages[j - 1] >= a.packages[j]:
        return err(
          "the package names of kid " & a.kid.toHex &
            " are not in strictly ascending byte order at " & a.packages[j].quoted
        )
  if t.catalog.selected.isSome:
    return err(
      "this implementation supports no catalog profile; the file selects " &
        t.catalog.selected.get.quoted
    )
  if t.provenance.selected.isSome:
    return err(
      "this implementation supports no provenance profile; the file selects " &
        t.provenance.selected.get.quoted
    )
  ok()

func inForce*(t: LcnPackageTrust, a: LcnTrustAnchor): bool =
  ## [G137] A development anchor is in force only while the file's switch is
  ## on; turning it off withdraws the anchor in the same revision (PM l.409).
  t.development or not a.development

func acceptedSigning*(t: LcnPackageTrust): Result[TrustInput, string] =
  ## [G396; PM §4.1, §4.3] The package-signing trust input of a file that
  ## passes every rule of `checkTrust`: the anchors in force, each through
  ## `addAnchor`, so its rules (PKG-0071 to PKG-0073) apply unchanged.
  ?checkTrust(t)
  var r: TrustInput
  for a in t.signing.anchors:
    if t.inForce(a):
      ?r.addAnchor(a.kid, a.public_key, a.packages)
  ok(r)

{.pop.}
