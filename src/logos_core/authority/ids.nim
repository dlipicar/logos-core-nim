## Decision and grant ids [IMPL] (CA l.546-551; NA-08; DECISIONS I84).
##
## `d-<32 hex>-<16 hex>` and `g-<32 hex>-<16 hex>`: a 128-bit prefix drawn
## from protected entropy at every open, then a fixed-width counter from 0.
## A restored counter alone never separates runs (l.549), so each issuer run
## gets fresh entropy, and cloned state gets a fresh prefix at its next open.
## The fixed width keeps one run's grant ids in issuance order.

{.push raises: [].}

import std/sysrand
import results
import ../base/hex

export results

type
  EntropyFn* = proc(dest: var openArray[byte]): bool {.nimcall, gcsafe, raises: [].}
    ## Fills `dest` with protected entropy; false when none is available.

  IdAllocator* = object
    prefix: string
    next: uint64
    exhausted: bool

const IdLen* = 2 + 32 + 1 + 16

proc systemEntropy*(dest: var openArray[byte]): bool =
  urandom(dest)

proc newIdAllocator*(entropy: EntropyFn = systemEntropy): Result[IdAllocator, string] =
  ## Fails when no entropy is available: the CA then does not open (l.551).
  var b: array[16, byte]
  if entropy == nil or not entropy(b):
    return err("no protected entropy for the id prefix")
  ok(IdAllocator(prefix: toHex(b)))

func hex16(n: uint64): string =
  const digits = "0123456789abcdef"
  result = newString(16)
  var x = n
  for i in countdown(15, 0):
    result[i] = digits[int(x and 0xF)]
    x = x shr 4

proc nextId*(a: var IdAllocator, kind: char): Opt[string] =
  ## The next id of `kind` (`d` or `g`), or none once the counter ran out.
  if a.exhausted:
    return Opt.none(string)
  let id = $kind & "-" & a.prefix & "-" & hex16(a.next)
  if a.next == high(uint64):
    a.exhausted = true
  else:
    inc a.next
  Opt.some(id)

proc exhaustForTest*(a: var IdAllocator) =
  a.next = high(uint64)
