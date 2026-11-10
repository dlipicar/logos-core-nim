## PM §5, §11: package versions are Semantic Versioning 2.0.0 strings without a
## leading `v` or build metadata; selection uses SemVer precedence.

{.push raises: [].}

import std/strutils
import results

export results

type SemVer* = object
  major*, minor*, patch*: string ## decimal, no leading zeros; any length
  pre*: seq[string] ## pre-release identifiers, empty for a normal release

func isDigits(s: string): bool =
  if s.len == 0:
    return false
  for c in s:
    if c notin {'0' .. '9'}:
      return false
  true

func isNumeric(s: string): bool =
  ## A SemVer numeric identifier: `0` or digits without a leading zero.
  s.isDigits and (s.len == 1 or s[0] != '0')

func isIdentChar(c: char): bool =
  c in {'0' .. '9', 'A' .. 'Z', 'a' .. 'z', '-'}

func parseSemVer*(s: string): Result[SemVer, string] =
  ## [SPEC PM §5] A `package_version`: SemVer 2.0.0 `<version core>` with an
  ## optional pre-release, no build metadata, no leading `v`.
  var core = s
  var v = SemVer()
  let dash = s.find('-')
  if '+' in s:
    return err("build metadata is not allowed in a package version")
  if dash >= 0:
    core = s[0 ..< dash]
    let pre = s[dash + 1 .. ^1]
    if pre.len == 0:
      return err("an empty pre-release")
    for ident in pre.split('.'):
      if ident.len == 0:
        return err("an empty pre-release identifier")
      for c in ident:
        if not c.isIdentChar:
          return err("pre-release identifiers use [0-9A-Za-z-]")
      if ident.isDigits and not ident.isNumeric:
        return err("a numeric pre-release identifier has a leading zero")
      v.pre.add(ident)
  let parts = core.split('.')
  if parts.len != 3:
    return err("not MAJOR.MINOR.PATCH")
  for p in parts:
    if not p.isNumeric:
      return err("a version number is empty, not decimal, or has a leading zero")
  v.major = parts[0]
  v.minor = parts[1]
  v.patch = parts[2]
  ok(v)

func isPrerelease*(v: SemVer): bool =
  v.pre.len > 0

func cmpNumber(a, b: string): int =
  if a.len != b.len:
    return cmp(a.len, b.len)
  cmp(a, b)

func cmpIdent(a, b: string): int =
  let (na, nb) = (a.isDigits, b.isDigits)
  if na and nb:
    cmpNumber(a, b)
  elif na:
    -1
  elif nb:
    1
  else:
    cmp(a, b)

func cmp*(a, b: SemVer): int =
  ## SemVer 2.0.0 §11 precedence.
  for (x, y) in [(a.major, b.major), (a.minor, b.minor), (a.patch, b.patch)]:
    let c = cmpNumber(x, y)
    if c != 0:
      return c
  if a.pre.len == 0 or b.pre.len == 0:
    return cmp(b.pre.len, a.pre.len) # a normal release ranks above a pre-release
  for i in 0 ..< min(a.pre.len, b.pre.len):
    let c = cmpIdent(a.pre[i], b.pre[i])
    if c != 0:
      return c
  cmp(a.pre.len, b.pre.len)

func `<`*(a, b: SemVer): bool =
  cmp(a, b) < 0

func `$`*(v: SemVer): string =
  let core = v.major & "." & v.minor & "." & v.patch
  if v.pre.len > 0:
    core & "-" & v.pre.join(".")
  else:
    core
