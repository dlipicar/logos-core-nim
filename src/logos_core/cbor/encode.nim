## Deterministic CBOR encoder.
##
## INTERFACE §4.4, cdCDDLe §9 and RFC 8949 §4.2.1 impose the same byte rules at
## spec f4f83471, so one encoder serves module payloads, transport envelopes,
## cdCDDLe documents, hash inputs and COSE structures (I9). Output is
## deterministic by construction: shortest heads, definite lengths, map entries
## sorted by their encoded keys. Duplicate keys are a programming error.

{.push raises: [].}

import std/algorithm
import ./value

func writeHead*(output: var seq[byte], major: uint8, arg: uint64) =
  ## The shortest head for `arg` (INTERFACE §4.4 item 2).
  let ib = major shl 5
  if arg < 24:
    output.add(ib or uint8(arg))
  elif arg <= 0xff:
    output.add(ib or 24)
    output.add(uint8(arg))
  elif arg <= 0xffff:
    output.add(ib or 25)
    for shift in [8, 0]:
      output.add(uint8((arg shr shift) and 0xff))
  elif arg <= 0xffff_ffff'u64:
    output.add(ib or 26)
    for shift in [24, 16, 8, 0]:
      output.add(uint8((arg shr shift) and 0xff))
  else:
    output.add(ib or 27)
    for shift in [56, 48, 40, 32, 24, 16, 8, 0]:
      output.add(uint8((arg shr shift) and 0xff))

func cmpBytes*(a, b: openArray[byte]): int =
  ## Bytewise lexicographic order (INTERFACE §4.4 item 1: no length-first sort).
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]:
      return (if a[i] < b[i]: -1 else: 1)
  cmp(a.len, b.len)

func encodeCbor*(v: CborValue, output: var seq[byte])

func encodeEntries(entries: seq[CborEntry], output: var seq[byte]) =
  var encoded = newSeqOfCap[tuple[key, value: seq[byte]]](entries.len)
  for (k, x) in entries:
    var kb, xb: seq[byte]
    encodeCbor(k, kb)
    encodeCbor(x, xb)
    encoded.add((kb, xb))
  encoded.sort(
    proc(a, b: tuple[key, value: seq[byte]]): int =
      cmpBytes(a.key, b.key)
  )
  for i in 1 ..< encoded.len:
    doAssert encoded[i - 1].key != encoded[i].key, "duplicate CBOR map key"
  writeHead(output, 5, uint64(encoded.len))
  for (kb, xb) in encoded:
    output.add(kb)
    output.add(xb)

func encodeCbor*(v: CborValue, output: var seq[byte]) =
  case v.kind
  of ckUint:
    writeHead(output, 0, v.uint)
  of ckNint:
    writeHead(output, 1, v.nint)
  of ckBytes:
    writeHead(output, 2, uint64(v.bytes.len))
    output.add(v.bytes)
  of ckText:
    writeHead(output, 3, uint64(v.text.len))
    output.add(v.text.toOpenArrayByte(0, v.text.high))
  of ckArray:
    writeHead(output, 4, uint64(v.items.len))
    for item in v.items:
      encodeCbor(item, output)
  of ckMap:
    encodeEntries(v.entries, output)
  of ckTag:
    writeHead(output, 6, v.tag)
    encodeCbor(v.content, output)
  of ckSimple:
    if v.simple < 24:
      output.add(0xe0'u8 or v.simple)
    else:
      output.add(0xf8)
      output.add(v.simple)
  of ckFloat:
    let ai =
      case v.width
      of fw16: 25'u8
      of fw32: 26'u8
      of fw64: 27'u8
    output.add(0xe0'u8 or ai)
    let bytes = int(ord(v.width))
    for i in countdown(bytes - 1, 0):
      output.add(uint8((v.floatBits shr (8 * i)) and 0xff))

func encodeCbor*(v: CborValue): seq[byte] =
  var output: seq[byte]
  encodeCbor(v, output)
  output
