## Unicode Normalization Form C (UAX #15) for checking that LGX archive paths
## are NFC-normalized (PM §7.1). The tables (`nfc_tables.nim`) are generated
## from Python's unicodedata by oracle/gen_nfc_tables.py; Hangul syllables are
## handled algorithmically.

{.push raises: [].}

import results
import ../cbor/utf8
import ./nfc_tables

export results
export nfc_tables.UnicodeVersion

const
  SBase = 0xAC00'u32
  LBase = 0x1100'u32
  VBase = 0x1161'u32
  TBase = 0x11A7'u32
  LCount = 19'u32
  VCount = 21'u32
  TCount = 28'u32
  NCount = VCount * TCount
  SCount = LCount * NCount

func ccc(cp: uint32): uint8 =
  var (lo, hi) = (0, int(CccRanges.high))
  while lo <= hi:
    let mid = (lo + hi) div 2
    let (first, last, class) = CccRanges[mid]
    if cp < first:
      hi = mid - 1
    elif cp > last:
      lo = mid + 1
    else:
      return class
  0

func decompose(cp: uint32, output: var seq[uint32]) =
  if cp >= SBase and cp < SBase + SCount:
    let s = cp - SBase
    output.add(LBase + s div NCount)
    output.add(VBase + (s mod NCount) div TCount)
    if s mod TCount != 0:
      output.add(TBase + s mod TCount)
    return
  var (lo, hi) = (0, int(DecompIndex.high))
  while lo <= hi:
    let mid = (lo + hi) div 2
    let (c, offset, length) = DecompIndex[mid]
    if cp < c:
      hi = mid - 1
    elif cp > c:
      lo = mid + 1
    else:
      for i in 0 ..< int(length):
        output.add(DecompData[int(offset) + i])
      return
  output.add(cp)

func compose(a, b: uint32): uint32 =
  ## The primary composite of `a` and `b`, or 0.
  if a >= LBase and a < LBase + LCount and b >= VBase and b < VBase + VCount:
    return SBase + ((a - LBase) * VCount + (b - VBase)) * TCount
  if a >= SBase and a < SBase + SCount and (a - SBase) mod TCount == 0 and b > TBase and
      b < TBase + TCount:
    return a + (b - TBase)
  var (lo, hi) = (0, int(CompositionPairs.high))
  while lo <= hi:
    let mid = (lo + hi) div 2
    let (x, y, c) = CompositionPairs[mid]
    if a < x or (a == x and b < y):
      hi = mid - 1
    elif a > x or (a == x and b > y):
      lo = mid + 1
    else:
      return c
  0

func decodeUtf8(s: string): seq[uint32] =
  ## Code points of valid UTF-8.
  var cps: seq[uint32]
  var i = 0
  while i < s.len:
    let b = uint32(s[i])
    var (cp, n) =
      if b < 0x80:
        (b, 0)
      elif b < 0xE0:
        (b and 0x1F, 1)
      elif b < 0xF0:
        (b and 0x0F, 2)
      else:
        (b and 0x07, 3)
    for j in 1 .. n:
      cp = (cp shl 6) or (uint32(s[i + j]) and 0x3F)
    cps.add(cp)
    i += n + 1
  cps

func encodeUtf8(cps: openArray[uint32]): string =
  var s = ""
  for cp in cps:
    if cp < 0x80:
      s.add(char(cp))
    elif cp < 0x800:
      s.add(char(0xC0 or (cp shr 6)))
      s.add(char(0x80 or (cp and 0x3F)))
    elif cp < 0x10000:
      s.add(char(0xE0 or (cp shr 12)))
      s.add(char(0x80 or ((cp shr 6) and 0x3F)))
      s.add(char(0x80 or (cp and 0x3F)))
    else:
      s.add(char(0xF0 or (cp shr 18)))
      s.add(char(0x80 or ((cp shr 12) and 0x3F)))
      s.add(char(0x80 or ((cp shr 6) and 0x3F)))
      s.add(char(0x80 or (cp and 0x3F)))
  s

func toNfc*(s: string): Result[string, string] =
  ## UAX #15 canonical decomposition, canonical ordering, then canonical
  ## composition. Fails only on invalid UTF-8.
  if not isValidUtf8(s):
    return err("not valid UTF-8")
  var d: seq[uint32]
  for cp in decodeUtf8(s):
    decompose(cp, d)
  # Canonical ordering: a stable sort of each run of non-starters by class.
  var i = 0
  while i < d.len:
    if ccc(d[i]) == 0:
      inc i
      continue
    var j = i
    while j < d.len and ccc(d[j]) != 0:
      inc j
    for k in i + 1 ..< j:
      var m = k
      while m > i and ccc(d[m - 1]) > ccc(d[m]):
        swap(d[m - 1], d[m])
        dec m
    i = j
  if d.len == 0:
    return ok("")
  # Canonical composition.
  var starterPos = 0
  var lastClass = int(ccc(d[0]))
  if lastClass != 0:
    lastClass = 256 # a leading non-starter blocks nothing it could compose with
  var compPos = 1
  for pos in 1 ..< d.len:
    let ch = d[pos]
    let chClass = int(ccc(ch))
    let composite = compose(d[starterPos], ch)
    if composite != 0 and (lastClass < chClass or lastClass == 0):
      d[starterPos] = composite
      continue
    if chClass == 0:
      starterPos = compPos
    lastClass = chClass
    d[compPos] = ch
    inc compPos
  d.setLen(compPos)
  ok(encodeUtf8(d))

func isNfc*(s: string): bool =
  ## Valid UTF-8 already in Normalization Form C.
  let n = toNfc(s)
  n.isOk and n.get == s
