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

func encodeScalar(v: CborValue, output: var seq[byte]) =
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
  of ckArray, ckMap, ckTag:
    raiseAssert "not a scalar"

type
  EncodedEntry = tuple[key, value: seq[byte]]

  Frame = object
    node: CborValue ## the array, map or tag being written
    next: int ## children finished: items, keys and values, or the tag content
    buf: seq[byte] ## maps: the key or value being written
    key: seq[byte] ## maps: the finished key waiting for its value
    entries: seq[EncodedEntry] ## maps: finished entries, sorted at the end

func encodeCbor*(v: CborValue, output: var seq[byte]) =
  ## Iterative, like the decoder: nesting costs heap, not call stack (INTERFACE
  ## §4.5.1). Arrays and tags write straight into their sink; a map collects
  ## its encoded entries, sorts them by key bytes and then writes them into
  ## its own sink. A sink is the innermost unfinished map's buffer, or `output`.
  var
    stack: seq[Frame]
    maps: seq[int] ## indices of the map frames in `stack`
    pending = v

  template sink(): ptr seq[byte] =
    # Taken fresh for every write: `stack.add` may move the buffers.
    if maps.len == 0:
      addr output
    else:
      addr stack[maps[^1]].buf

  while true:
    case pending.kind
    of ckArray:
      writeHead(sink()[], 4, uint64(pending.items.len))
      if pending.items.len > 0:
        stack.add(Frame(node: pending))
        pending = pending.items[0]
        continue
    of ckTag:
      writeHead(sink()[], 6, pending.tag)
      stack.add(Frame(node: pending))
      pending = pending.content
      continue
    of ckMap:
      if pending.entries.len == 0:
        writeHead(sink()[], 5, 0)
      else:
        stack.add(Frame(node: pending))
        maps.add(stack.high)
        pending = pending.entries[0].key
        continue
    else:
      encodeScalar(pending, sink()[])
    # `pending` is finished: close every container it completes.
    while true:
      if stack.len == 0:
        return
      let top = stack.high
      case stack[top].node.kind
      of ckArray:
        inc stack[top].next
        if stack[top].next < stack[top].node.items.len:
          pending = stack[top].node.items[stack[top].next]
          break
        stack.setLen(top)
      of ckTag:
        stack.setLen(top)
      else:
        let child = move stack[top].buf
        stack[top].buf = @[]
        if stack[top].next mod 2 == 0:
          stack[top].key = child
        else:
          stack[top].entries.add((move stack[top].key, child))
          stack[top].key = @[]
        inc stack[top].next
        let n = stack[top].node.entries.len
        if stack[top].next < 2 * n:
          let e = stack[top].node.entries[stack[top].next div 2]
          pending = if stack[top].next mod 2 == 0: e.key else: e.value
          break
        var entries = move stack[top].entries
        stack.setLen(top)
        maps.setLen(maps.len - 1)
        entries.sort(
          proc(a, b: EncodedEntry): int =
            cmpBytes(a.key, b.key)
        )
        for i in 1 ..< entries.len:
          doAssert entries[i - 1].key != entries[i].key, "duplicate CBOR map key"
        let s = sink()
        writeHead(s[], 5, uint64(n))
        for (kb, xb) in entries:
          s[].add(kb)
          s[].add(xb)

func encodeCbor*(v: CborValue): seq[byte] =
  var output: seq[byte]
  encodeCbor(v, output)
  output
