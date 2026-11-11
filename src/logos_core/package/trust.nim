## PM §4.1, §4.3: package-signing trust input. Each accepted `kid` maps to
## exactly one 48-byte SLH-DSA-SHA2-192s public key and authorizes a non-empty
## set of exact package names. Matching is byte equality: no case folding,
## Unicode normalization, prefixes, wildcards, or an all-packages entry. Where
## the input comes from (one protected trust file with a monotonic revision and
## a compiled-in floor) is G137, built with the Package Manager at tier 4/5.

{.push raises: [].}

import std/[sets, tables]
import results
import ../base/hex
import ../crypto/slhdsa

export results, slhdsa

const
  MinKidBytes* = 1 ## [SPEC PM §4.3] `package_signing_key_id = bstr .size (1..128)`
  MaxKidBytes* = 128
  MaxPackageNameBytes* = 128 ## [SPEC PM §4] `package_name = tstr .size (1..128)`

type
  TrustAnchor* = object
    kid*: seq[byte]
    key*: PublicKey
    packages*: HashSet[string] ## the exact names this signer may sign

  TrustInput* = object
    anchors: Table[seq[byte], TrustAnchor]

  TrustRefusal* = enum
    trUnknownKid = "no accepted anchor has this kid"
    trNotAuthorized = "the signer is not authorized for this package name"

func len*(t: TrustInput): int =
  t.anchors.len

func addAnchor*(
    t: var TrustInput, kid, key: openArray[byte], packages: openArray[string]
): Result[void, string] =
  ## [SPEC PM §4.1, §4.3] Accepts one anchor: a 1..128-byte kid not already
  ## used, a key of exactly 48 bytes (`PK.seed || PK.root`; any 48 bytes are a
  ## possible key, and no other length is repaired), and a non-empty set of
  ## package names, each 1..128 bytes.
  if kid.len < MinKidBytes or kid.len > MaxKidBytes:
    return err("a kid is 1 to 128 bytes")
  if @kid in t.anchors:
    return err("two trust anchors use kid " & kid.toHex)
  if key.len != PublicKeyBytes:
    return err("the key of kid " & kid.toHex & " is not 48 bytes")
  var k: PublicKey
  copyMem(addr k[0], unsafeAddr key[0], PublicKeyBytes)
  if packages.len == 0:
    return err("kid " & kid.toHex & " authorizes no package name")
  var names = initHashSet[string]()
  for p in packages:
    if p.len == 0 or p.len > MaxPackageNameBytes:
      return err("a package name is 1 to 128 bytes")
    names.incl(p)
  t.anchors[@kid] = TrustAnchor(kid: @kid, key: k, packages: names)
  ok()

func anchor*(t: TrustInput, kid: openArray[byte]): Opt[TrustAnchor] =
  ## The anchor a `kid` selects; the kid alone establishes nothing (§4.3).
  let k = @kid
  if k in t.anchors:
    Opt.some(t.anchors.getOrDefault(k))
  else:
    Opt.none(TrustAnchor)

func authorize*(
    t: TrustInput, kid: openArray[byte], package: string
): Result[TrustAnchor, TrustRefusal] =
  ## [SPEC PM §4.1] The signer `kid` is accepted and authorized for exactly
  ## `package`.
  let a = t.anchor(kid).valueOr:
    return err(trUnknownKid)
  if package notin a.packages:
    return err(trNotAuthorized)
  ok(a)
