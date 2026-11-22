## [IMPL-DECISION G409] Whether a program holds libssl code (Tier 5 step
## 5-7a-1; Fable's check of logosd's link and planning's ruling, 2026-11-22).
##
## The BoringSSL binding compiles libssl's sources into every program that
## imports it (`ssl/*.cc` and the amalgamated `boringssl_units/ssl_*.cc`). logosd
## calls libcrypto only and links with dead stripping, so none of that code may
## be left in it. The check takes every symbol that only those objects define,
## from a nimcache that compiled them, and finds none in the program. Labels a
## compiler makes in each object (exception tables, temporaries) are left out:
## their names collide across objects by chance. A list that does not name
## `SSL_new` is no list of libssl's symbols, and the check fails. So does a
## program that holds none of libcrypto's symbols, which logosd calls: its
## symbol table was stripped, and finding nothing in it would prove nothing.
##
## Plain builds only: a sanitizer adds per-object constructors (ASan's global
## registration among them) that can keep libssl's tables and their code alive.

import std/[algorithm, os, osproc, sets, strutils]

type SslCheck* = object
  objects*: int ## libssl objects in the nimcache
  candidates*: HashSet[string] ## the symbols only they define
  left*: seq[string] ## of those, the ones the program holds
  libcrypto*: int ## the program's symbols that BoringSSL's other objects define

func isSslObject*(name: string): bool =
  name.endsWith(".o") and not name.startsWith("._") and
    ("boringssl@sssl@s" in name or "boringssl_units@sssl_" in name)

func isBoringObject(name: string): bool =
  "@pboringssl@s" in name or "@pboringssl_units@s" in name

func compilerLabel(name: string): bool =
  if name.startsWith("GCC_except_table"):
    return true
  when defined(macosx):
    # Mach-O temporaries: `ltmp0`, `l_.str`, `LCPI0_0`. C symbols start with `_`.
    if name.startsWith("l") or name.startsWith("L"):
      return true
  false

proc definedSymbols(path: string): HashSet[string] =
  let (output, code) =
    execCmdEx(quoteShellCommand(["nm", "-P", "--defined-only", path]))
  if code != 0:
    raise newException(OSError, "nm " & path & ": " & output)
  for line in output.splitLines:
    let f = line.splitWhitespace
    if f.len >= 2 and f[1] != "U" and not compilerLabel(f[0]):
      result.incl(f[0])

func entryPoint*(): string =
  ## libssl's `SSL_new`, as `nm` names it on this system.
  when defined(macosx): "_SSL_new" else: "SSL_new"

proc checkNoSsl*(nimcache, program: string): SslCheck =
  ## Raises OSError when `nm` fails.
  var ssl, other, crypto: HashSet[string]
  for kind, path in walkDir(nimcache):
    let name = path.extractFilename
    if kind != pcFile or not name.endsWith(".o") or name.startsWith("._"):
      continue
    if isSslObject(name):
      inc result.objects
      ssl.incl(definedSymbols(path))
    else:
      let defined = definedSymbols(path)
      other.incl(defined)
      if isBoringObject(name):
        crypto.incl(defined)
  result.candidates = ssl - other
  crypto.excl(ssl)
  for s in definedSymbols(program):
    if s in result.candidates:
      result.left.add(s)
    elif s in crypto:
      inc result.libcrypto
  result.left.sort()

func problem*(c: SslCheck): string =
  ## Empty when the program holds no libssl code.
  if c.objects == 0:
    return "the nimcache holds no libssl object"
  if entryPoint() notin c.candidates:
    return "the libssl objects define no " & entryPoint()
  if c.libcrypto == 0:
    return "the program holds none of libcrypto's symbols: no symbol table to check"
  if c.left.len > 0:
    return
      $c.left.len & " of libssl's " & $c.candidates.len &
      " symbols are in the program, among them " &
      c.left[0 ..< min(10, c.left.len)].join(", ")
  ""
