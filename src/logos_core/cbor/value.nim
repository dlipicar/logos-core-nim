## CBOR data model (RFC 8949 §2) as decoded and encoded by `logos_core/cbor`.
##
## The model keeps everything a well-formed deterministic item can carry, including
## tags, floats and simple values: INTERFACE §4.4 restricts encodings, not values, and
## G38 makes such values a schema mismatch, decided above this layer.

{.push raises: [].}

import results

export results

type
  CborKind* = enum
    ckUint ## major type 0
    ckNint ## major type 1: the value is -1 - `nint`
    ckBytes ## major type 2
    ckText ## major type 3
    ckArray ## major type 4
    ckMap ## major type 5
    ckTag ## major type 6
    ckSimple ## major type 7: false, true, null, undefined and other simple values
    ckFloat ## major type 7: half, single or double precision

  FloatWidth* = enum
    fw16 = 2
    fw32 = 4
    fw64 = 8

  CborValue* = ref CborValueObj
  CborEntry* = tuple[key, value: CborValue]

  CborValueObj* = object
    case kind*: CborKind
    of ckUint:
      uint*: uint64
    of ckNint:
      nint*: uint64
    of ckBytes:
      bytes*: seq[byte]
    of ckText:
      text*: string ## UTF-8 bytes
      validUtf8*: bool
        ## false only when decoded with `allowInvalidUtf8`; INTERFACE §4.5 rejects
        ## such text at the schema boundary
    of ckArray:
      items*: seq[CborValue]
    of ckMap:
      entries*: seq[CborEntry]
        ## decoded maps are in deterministic order; the encoder sorts any order
    of ckTag:
      tag*: uint64
      content*: CborValue
    of ckSimple:
      simple*: uint8
    of ckFloat:
      width*: FloatWidth
      floatBits*: uint64 ## the IEEE 754 bits at `width`, in the low bits

const
  SimpleFalse* = 20'u8
  SimpleTrue* = 21'u8
  SimpleNull* = 22'u8
  SimpleUndefined* = 23'u8

func cbor*(v: uint64): CborValue =
  CborValue(kind: ckUint, uint: v)

func cbor*(v: int64): CborValue =
  if v >= 0:
    CborValue(kind: ckUint, uint: uint64(v))
  else:
    CborValue(kind: ckNint, nint: uint64(-(v + 1)))

func cbor*(v: int): CborValue =
  cbor(int64(v))

func cbor*(v: bool): CborValue =
  CborValue(kind: ckSimple, simple: (if v: SimpleTrue else: SimpleFalse))

func cbor*(v: string): CborValue =
  CborValue(kind: ckText, text: v, validUtf8: true)

func cbor*(v: openArray[byte]): CborValue =
  CborValue(kind: ckBytes, bytes: @v)

func cborNint*(n: uint64): CborValue =
  ## The negative integer -1 - `n`; reaches -2^64.
  CborValue(kind: ckNint, nint: n)

func cborArray*(items: varargs[CborValue]): CborValue =
  CborValue(kind: ckArray, items: @items)

func cborMap*(entries: varargs[CborEntry]): CborValue =
  CborValue(kind: ckMap, entries: @entries)

func cborTag*(tag: uint64, content: CborValue): CborValue =
  CborValue(kind: ckTag, tag: tag, content: content)

func cborSimple*(n: uint8): CborValue =
  ## Simple values 24..31 have no valid encoding (RFC 8949 §3.3).
  doAssert n < 24 or n >= 32
  CborValue(kind: ckSimple, simple: n)

func cborNull*(): CborValue =
  cborSimple(SimpleNull)

func cborUndefined*(): CborValue =
  cborSimple(SimpleUndefined)

func cborFloatBits*(width: FloatWidth, bits: uint64): CborValue =
  ## A float exactly as encoded; the encoder writes these bits at this width.
  CborValue(kind: ckFloat, width: width, floatBits: bits)

func isBool*(v: CborValue): bool =
  v.kind == ckSimple and v.simple in {SimpleFalse, SimpleTrue}

func isNull*(v: CborValue): bool =
  v.kind == ckSimple and v.simple == SimpleNull

func getBool*(v: CborValue): Opt[bool] =
  if v.isBool:
    Opt.some(v.simple == SimpleTrue)
  else:
    Opt.none(bool)

func getUint64*(v: CborValue): Opt[uint64] =
  if v.kind == ckUint:
    Opt.some(v.uint)
  else:
    Opt.none(uint64)

func getInt64*(v: CborValue): Opt[int64] =
  ## The integer if it fits in int64.
  case v.kind
  of ckUint:
    if v.uint <= uint64(high(int64)):
      Opt.some(int64(v.uint))
    else:
      Opt.none(int64)
  of ckNint:
    if v.nint <= uint64(high(int64)):
      Opt.some(-int64(v.nint) - 1)
    else:
      Opt.none(int64)
  else:
    Opt.none(int64)

func getText*(v: CborValue): Opt[string] =
  if v.kind == ckText and v.validUtf8:
    Opt.some(v.text)
  else:
    Opt.none(string)

func getBytes*(v: CborValue): Opt[seq[byte]] =
  if v.kind == ckBytes:
    Opt.some(v.bytes)
  else:
    Opt.none(seq[byte])

func `==`*(a, b: CborValue): bool =
  ## Data-model equality: map entry order does not matter, floats compare by
  ## width and bits (so equal values are exactly those with equal encodings).
  if cast[pointer](a) == cast[pointer](b):
    return true
  if a.isNil or b.isNil or a.kind != b.kind:
    return false
  case a.kind
  of ckUint:
    a.uint == b.uint
  of ckNint:
    a.nint == b.nint
  of ckBytes:
    a.bytes == b.bytes
  of ckText:
    a.text == b.text
  of ckArray:
    if a.items.len != b.items.len:
      return false
    for i in 0 ..< a.items.len:
      if a.items[i] != b.items[i]:
        return false
    true
  of ckMap:
    if a.entries.len != b.entries.len:
      return false
    for (k, v) in a.entries:
      var found = false
      for (k2, v2) in b.entries:
        if k == k2:
          if v != v2:
            return false
          found = true
          break
      if not found:
        return false
    true
  of ckTag:
    a.tag == b.tag and a.content == b.content
  of ckSimple:
    a.simple == b.simple
  of ckFloat:
    a.width == b.width and a.floatBits == b.floatBits

func lookup*(v: CborValue, key: CborValue): Opt[CborValue] =
  ## The value under `key` of a map.
  if v.kind == ckMap:
    for (k, x) in v.entries:
      if k == key:
        return Opt.some(x)
  Opt.none(CborValue)

func lookup*(v: CborValue, key: string): Opt[CborValue] =
  ## The value under text key `key` of a map.
  lookup(v, cbor(key))

func lookup*(v: CborValue, key: uint64): Opt[CborValue] =
  lookup(v, cbor(key))
