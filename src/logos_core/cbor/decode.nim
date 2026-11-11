## Strict deterministic CBOR decoder.
##
## Two passes, both iterative (G59):
## 1. well-formedness (RFC 8949 Appendix C), indefinite lengths included, so a
##    malformed item is reported as `malformed-cbor` wherever it occurs;
## 2. decoding under the deterministic rules (INTERFACE §4.4, cdCDDLe §9): any
##    violation is `non-deterministic-cbor`.
## Invalid UTF-8 text is reported separately: INTERFACE §4.5 rejects it as a
## schema mismatch, and the transport must forward it inside opaque payloads.
## Floating-point items are not part of Logos deterministic CBOR (INTERFACE §4.4
## item 5) and are rejected as non-deterministic unless `allowFloats` asks for
## the generic CBOR data model. Tags and simple values decode; whether a schema
## allows them is decided above this layer.

{.push raises: [].}

import ./[value, floats, utf8, encode]

export value

type
  CborErrorKind* = enum
    cekMalformed ## not a single well-formed CBOR data item
    cekNonDeterministic ## well-formed, but violates INTERFACE §4.4
    cekInvalidUtf8 ## a text string that is not UTF-8 (INTERFACE §4.5)
    cekTooDeep
      ## arrays and maps deeper than `maxDepth`, or tags deeper than `maxTagDepth`

  CborError* = object
    kind*: CborErrorKind
    offset*: int ## byte offset of the offending item
    msg*: string

  DecodeOptions* = object
    maxDepth*: int
      ## [SPEC INTERFACE §4.5.1] arrays and maps on any path, at most this many;
      ## a root container is depth one, and scalars and byte-string contents
      ## add none
    maxTagDepth*: int
      ## [IMPL] tags on any path, bounded apart so they cannot nest without
      ## limit while adding no payload depth
    allowFloats*: bool
      ## decode floating-point items: the generic CBOR data model, not
      ## Logos deterministic CBOR (INTERFACE §4.4 item 5)
    allowInvalidUtf8*: bool
      ## keep invalid text with `validUtf8 = false` instead of failing

const
  DefaultMaxDepth* = 1024
    ## [IMPL-DECISION G59] the payload-depth limit; configurable, and at least
    ## the 128 INTERFACE §4.5.1 requires
  MinMaxDepth* = 128 ## [SPEC INTERFACE §4.5.1]
  DefaultMaxTagDepth* = 1024 ## [IMPL]

func defaultDecodeOptions*(): DecodeOptions =
  DecodeOptions(maxDepth: DefaultMaxDepth, maxTagDepth: DefaultMaxTagDepth)

func cborError(kind: CborErrorKind, offset: int, msg: string): CborError =
  CborError(kind: kind, offset: offset, msg: msg)

func `$`*(e: CborError): string =
  let kind =
    case e.kind
    of cekMalformed: "malformed-cbor"
    of cekNonDeterministic: "non-deterministic-cbor"
    of cekInvalidUtf8: "invalid-utf8"
    of cekTooDeep: "too-deep"
  kind & " at " & $e.offset & ": " & e.msg

type Head = object
  major: uint8
  ai: uint8
  arg: uint64
  next: int ## offset after the head

func readHead(data: openArray[byte], pos: int): Result[Head, CborError] =
  if pos >= data.len:
    return err(cborError(cekMalformed, pos, "truncated"))
  let
    ib = data[pos]
    major = ib shr 5
    ai = ib and 0x1f
  if ai < 24 or ai == 31:
    return ok(Head(major: major, ai: ai, arg: uint64(ai), next: pos + 1))
  if ai >= 28:
    return err(cborError(cekMalformed, pos, "reserved additional information"))
  let size = 1 shl (ai - 24)
  if data.len - pos - 1 < size:
    return err(cborError(cekMalformed, pos, "truncated head"))
  var arg = 0'u64
  for i in 1 .. size:
    arg = (arg shl 8) or uint64(data[pos + i])
  ok(Head(major: major, ai: ai, arg: arg, next: pos + 1 + size))

# Pass 1: well-formedness ------------------------------------------------------

type
  WfKind = enum
    wfDefinite ## array, map or tag with a known number of items left
    wfIndefinite ## indefinite array or map
    wfChunks ## indefinite byte or text string

  WfFrame = object
    kind: WfKind
    tag: bool ## a tag frame, counted against `maxTagDepth`
    left: uint64 ## for wfDefinite
    count: uint64 ## items seen, for wfIndefinite maps
    isMap: bool
    major: uint8 ## for wfChunks

func tooDeep(start: int, what: string, limit: int): CborError =
  cborError(cekTooDeep, start, what & " nested deeper than " & $limit)

func checkWellFormed(
    data: openArray[byte], opts: DecodeOptions
): Result[void, CborError] =
  var
    stack: seq[WfFrame]
    pos = 0
    containers, tags = 0 ## arrays and maps, and tags, open on the stack
  while true:
    let start = pos
    let h = ?readHead(data, pos)
    pos = h.next
    var
      complete = true # the item at `start` is finished
      breakHere = false
    if stack.len > 0 and stack[^1].kind == wfChunks:
      if h.major == 7 and h.ai == 31:
        breakHere = true
      elif h.major != stack[^1].major or h.ai == 31:
        return err(cborError(cekMalformed, start, "invalid chunk in indefinite string"))
    if breakHere:
      discard
    else:
      case h.major
      of 0, 1:
        if h.ai == 31:
          return err(cborError(cekMalformed, start, "indefinite integer"))
      of 2, 3:
        if h.ai == 31:
          # Chunks are definite strings, so this adds one frame at most.
          stack.add(WfFrame(kind: wfChunks, major: h.major))
          complete = false
        else:
          if h.arg > uint64(data.len - pos):
            return err(cborError(cekMalformed, start, "truncated string"))
          pos += int(h.arg)
      of 4, 5:
        let isMap = h.major == 5
        if containers + 1 > opts.maxDepth:
          return err(tooDeep(start, "arrays and maps", opts.maxDepth))
        if h.ai == 31:
          stack.add(WfFrame(kind: wfIndefinite, isMap: isMap))
          inc containers
          complete = false
        else:
          let left =
            if isMap:
              h.arg * 2
            else:
              h.arg
          if isMap and h.arg > uint64(high(int64)):
            return err(cborError(cekMalformed, start, "truncated map"))
          if left > uint64(data.len - pos):
            return err(cborError(cekMalformed, start, "truncated container"))
          if left > 0:
            stack.add(WfFrame(kind: wfDefinite, left: left, isMap: isMap))
            inc containers
            complete = false
      of 6:
        if h.ai == 31:
          return err(cborError(cekMalformed, start, "indefinite tag"))
        if tags + 1 > opts.maxTagDepth:
          return err(tooDeep(start, "tags", opts.maxTagDepth))
        stack.add(WfFrame(kind: wfDefinite, left: 1, tag: true))
        inc tags
        complete = false
      else:
        if h.ai == 31:
          if stack.len == 0 or stack[^1].kind != wfIndefinite:
            return err(cborError(cekMalformed, start, "unexpected break"))
          breakHere = true
        elif h.ai == 24 and h.arg < 32:
          return err(cborError(cekMalformed, start, "two-byte simple value below 32"))
    if breakHere:
      let frame = stack.pop()
      if frame.kind == wfIndefinite:
        dec containers
        if frame.isMap and frame.count mod 2 == 1:
          return err(
            cborError(cekMalformed, start, "indefinite map with a key and no value")
          )
      complete = true
    # Close every container this item completes.
    while complete and stack.len > 0:
      case stack[^1].kind
      of wfDefinite:
        dec stack[^1].left
        if stack[^1].left == 0:
          if stack.pop().tag:
            dec tags
          else:
            dec containers
        else:
          complete = false
      of wfIndefinite:
        inc stack[^1].count
        complete = false
      of wfChunks:
        complete = false
    if complete and stack.len == 0:
      break
  if pos != data.len:
    return err(cborError(cekMalformed, pos, "trailing bytes after the data item"))
  ok()

# Pass 2: deterministic decoding ---------------------------------------------------

type Frame = object
  node: CborValue
  start: int
  left: uint64
  keyStart, keyEnd: int ## encoded bytes of the pending map key
  prevKeyStart, prevKeyEnd: int
  key: CborValue

func decodeDeterministic(
    data: openArray[byte], opts: DecodeOptions
): Result[CborValue, CborError] =
  var
    stack: seq[Frame]
    pos = 0
    containers, tags = 0 ## arrays and maps, and tags, open on the stack
  while true:
    let start = pos
    let h = ?readHead(data, pos)
    pos = h.next
    if h.ai == 31:
      return err(cborError(cekNonDeterministic, start, "indefinite-length item"))
    let shortest =
      case h.ai
      of 24:
        h.arg >= 24
      of 25:
        h.arg > 0xff
      of 26:
        h.arg > 0xffff
      of 27:
        h.arg > 0xffff_ffff'u64
      else:
        true
    if h.major != 7 and not shortest:
      return err(cborError(cekNonDeterministic, start, "argument not in shortest form"))
    # Pass 1 already bounded both depths; these keep pass 2 safe on its own.
    if h.major in 4'u8 .. 5'u8 and containers + 1 > opts.maxDepth:
      return err(tooDeep(start, "arrays and maps", opts.maxDepth))
    if h.major == 6 and tags + 1 > opts.maxTagDepth:
      return err(tooDeep(start, "tags", opts.maxTagDepth))
    var item: CborValue = nil
    case h.major
    of 0:
      item = CborValue(kind: ckUint, uint: h.arg)
    of 1:
      item = CborValue(kind: ckNint, nint: h.arg)
    of 2:
      let n = int(h.arg)
      item = CborValue(kind: ckBytes, bytes: @(data.toOpenArray(pos, pos + n - 1)))
      pos += n
    of 3:
      let n = int(h.arg)
      var text = newString(n)
      for i in 0 ..< n:
        text[i] = char(data[pos + i])
      let valid = isValidUtf8(data.toOpenArray(pos, pos + n - 1))
      if not valid and not opts.allowInvalidUtf8:
        return err(cborError(cekInvalidUtf8, start, "text string is not UTF-8"))
      item = CborValue(kind: ckText, text: text, validUtf8: valid)
      pos += n
    of 4:
      let node = CborValue(
        kind: ckArray, items: newSeqOfCap[CborValue](int(min(h.arg, 1024'u64)))
      )
      if h.arg == 0:
        item = node
      else:
        stack.add(Frame(node: node, start: start, left: h.arg))
        inc containers
    of 5:
      let node = CborValue(
        kind: ckMap, entries: newSeqOfCap[CborEntry](int(min(h.arg, 1024'u64)))
      )
      if h.arg == 0:
        item = node
      else:
        stack.add(Frame(node: node, start: start, left: h.arg * 2, prevKeyStart: -1))
        inc containers
    of 6:
      stack.add(Frame(node: CborValue(kind: ckTag, tag: h.arg), start: start, left: 1))
      inc tags
    else:
      case h.ai
      of 25, 26, 27:
        if not opts.allowFloats:
          # [SPEC INTERFACE §4.4 item 5] no floating-point item at any depth
          return err(cborError(cekNonDeterministic, start, "floating-point data item"))
        let width =
          case h.ai
          of 25: fw16
          of 26: fw32
          else: fw64
        if not isShortest(width, h.arg):
          return
            err(cborError(cekNonDeterministic, start, "float not in shortest form"))
        item = CborValue(kind: ckFloat, width: width, floatBits: h.arg)
      of 24:
        item = CborValue(kind: ckSimple, simple: uint8(h.arg))
      else:
        item = CborValue(kind: ckSimple, simple: h.ai)
    var itemStart = start
    # Attach the finished item, then every container it completes.
    while item != nil:
      if stack.len == 0:
        if pos != data.len:
          return err(cborError(cekMalformed, pos, "trailing bytes after the data item"))
        return ok(item)
      case stack[^1].node.kind
      of ckArray:
        stack[^1].node.items.add(item)
      of ckTag:
        stack[^1].node.content = item
      else:
        if stack[^1].left mod 2 == 0:
          if stack[^1].prevKeyStart >= 0:
            let order = cmpBytes(
              data.toOpenArray(stack[^1].prevKeyStart, stack[^1].prevKeyEnd - 1),
              data.toOpenArray(itemStart, pos - 1),
            )
            if order == 0:
              return err(cborError(cekNonDeterministic, itemStart, "duplicate map key"))
            if order > 0:
              return
                err(cborError(cekNonDeterministic, itemStart, "map keys out of order"))
          stack[^1].key = item
          stack[^1].keyStart = itemStart
          stack[^1].keyEnd = pos
        else:
          stack[^1].node.entries.add((stack[^1].key, item))
          stack[^1].prevKeyStart = stack[^1].keyStart
          stack[^1].prevKeyEnd = stack[^1].keyEnd
          stack[^1].key = nil
      dec stack[^1].left
      if stack[^1].left == 0:
        let frame = stack.pop()
        if frame.node.kind == ckTag:
          dec tags
        else:
          dec containers
        item = frame.node
        itemStart = frame.start
      else:
        item = nil

func decodeCbor*(
    data: openArray[byte], opts = defaultDecodeOptions()
): Result[CborValue, CborError] =
  ## Decodes exactly one data item. Accepts only the unique deterministic
  ## encoding of the value, so `encodeCbor(decoded) == data` on success.
  ?checkWellFormed(data, opts)
  decodeDeterministic(data, opts)

func decodeCbor*(
    data: string, opts = defaultDecodeOptions()
): Result[CborValue, CborError] =
  decodeCbor(data.toOpenArrayByte(0, data.high), opts)
