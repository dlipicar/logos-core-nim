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
import ../base/wipe

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

func headSize(arg: uint64): int =
  if arg < 24:
    1
  elif arg <= 0xff:
    2
  elif arg <= 0xffff:
    3
  elif arg <= 0xffff_ffff'u64:
    5
  else:
    9

func encodedSize*(v: CborValue): int =
  ## The length of `v`'s deterministic encoding, without encoding it.
  var stack = @[v]
  while stack.len > 0:
    let n = stack.pop()
    case n.kind
    of ckUint:
      result += headSize(n.uint)
    of ckNint:
      result += headSize(n.nint)
    of ckBytes:
      result += headSize(uint64(n.bytes.len)) + n.bytes.len
    of ckText:
      result += headSize(uint64(n.text.len)) + n.text.len
    of ckSimple:
      result += (if n.simple < 24: 1 else: 2)
    of ckFloat:
      result += 1 + ord(n.width)
    of ckArray:
      result += headSize(uint64(n.items.len))
      for x in n.items:
        stack.add(x)
    of ckMap:
      result += headSize(uint64(n.entries.len))
      for (k, x) in n.entries:
        stack.add(k)
        stack.add(x)
    of ckTag:
      result += headSize(n.tag)
      stack.add(n.content)

type Frame = object
  node: CborValue ## the array, map or tag being written
  next: int ## children finished: items, keys then values, or the tag content
  keys: seq[seq[byte]] ## maps: each entry's encoded key, by entry index
  order: seq[int] ## maps: entry indices in the order of their encoded keys

func sized(v: CborValue): seq[byte] =
  newSeqOfCap[byte](encodedSize(v))

func sortKeys(f: var Frame): bool =
  ## The entry order of a map whose keys are all encoded (INTERFACE §4.4 item
  ## 1); false when two keys are equal. Duplicate keys are a programming error,
  ## reported by `encodeCbor` once nothing of the encoding is held.
  let n = f.keys.len
  f.order = newSeq[int](n)
  for i in 0 ..< n:
    f.order[i] = i
  let keys = addr f.keys
  f.order.sort(
    proc(a, b: int): int =
      cmpBytes(keys[][a], keys[][b])
  )
  for i in 1 ..< n:
    if cmpBytes(keys[][f.order[i - 1]], keys[][f.order[i]]) == 0:
      return false
  true

func encodeInto(v: CborValue, output: var seq[byte]): bool =
  ## Iterative, like the decoder: nesting costs heap, not call stack (INTERFACE
  ## §4.5.1). Everything is written into storage sized for it beforehand, so
  ## nothing is reallocated [DECISIONS G276]. A map first encodes each key
  ## into its own buffer of exact size, then writes its entries in the order of
  ## those encodings; the key buffers are zeroed when it closes. The sink is the
  ## key being encoded by the innermost map still encoding keys, or `output`.
  ## False for a map with a duplicate key, every key buffer zeroed: the caller
  ## raises once it holds nothing (a Defect skips the destructors of a func
  ## that raises nothing else, which would leave these buffers allocated).
  var
    stack: seq[Frame]
    keying: seq[int] ## indices of the map frames still encoding their keys
    pending = v

  template sink(): ptr seq[byte] =
    # Taken fresh for every write: `stack.add` may move the buffers.
    if keying.len == 0:
      addr output
    else:
      let m = keying[^1]
      addr stack[m].keys[stack[m].next]

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
      writeHead(sink()[], 5, uint64(pending.entries.len))
      if pending.entries.len > 0:
        var f = Frame(node: pending)
        f.keys = newSeq[seq[byte]](pending.entries.len)
        f.keys[0] = sized(pending.entries[0].key)
        stack.add(move f)
        keying.add(stack.high)
        pending = pending.entries[0].key
        continue
    else:
      encodeScalar(pending, sink()[])
    # `pending` is finished: close every container it completes.
    while true:
      if stack.len == 0:
        return true
      let top = stack.high
      inc stack[top].next
      case stack[top].node.kind
      of ckArray:
        if stack[top].next < stack[top].node.items.len:
          pending = stack[top].node.items[stack[top].next]
          break
        stack.setLen(top)
      of ckTag:
        stack.setLen(top)
      else:
        let n = stack[top].node.entries.len
        var i = stack[top].next
        if i < n:
          # Still encoding keys.
          stack[top].keys[i] = sized(stack[top].node.entries[i].key)
          pending = stack[top].node.entries[i].key
          break
        if i == n:
          # Every key is encoded: from here on the entries go to the outer sink.
          keying.setLen(keying.len - 1)
          if not stack[top].sortKeys():
            for f in stack.mitems:
              for k in f.keys.mitems:
                wipe(k)
            return false
        i -= n # values finished
        if i < n:
          let j = stack[top].order[i]
          sink()[].add(stack[top].keys[j])
          pending = stack[top].node.entries[j].value
          break
        # [DECISIONS G276] A key may be payload: its own encoding is zeroed.
        for k in stack[top].keys.mitems:
          wipe(k)
        stack.setLen(top)

func encodeCbor*(v: CborValue, output: var seq[byte]) =
  ## Appends `v`'s encoding to `output`. When `output` has no room for it, it
  ## is moved once into storage of the final size and the old storage is zeroed
  ## [DECISIONS G276].
  let need = output.len + encodedSize(v)
  if output.capacity < need:
    var grown = newSeqOfCap[byte](need)
    grown.add(output)
    wipe(output)
    output = move grown
  doAssert encodeInto(v, output), "duplicate CBOR map key"

func encodeCbor*(v: CborValue): seq[byte] =
  ## [DECISIONS G276] One allocation, of exactly the encoded length: no
  ## reallocation leaves a stale copy of a payload behind.
  var output = newSeqOfCap[byte](encodedSize(v))
  if not encodeInto(v, output):
    wipe(output)
    output = @[] # released before the Defect, which skips this func's destructors
    raiseAssert "duplicate CBOR map key"
  output
