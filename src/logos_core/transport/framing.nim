## TRANSPORT §2.1: stream framing. Each message is a 4-byte big-endian length
## and that many bytes of CBOR. Sans-I/O: the reader takes whatever bytes the
## carrier delivered and yields complete frame bodies.

{.push raises: [].}

import results

export results

const
  MinFrameLimit* = 16 * 1024 * 1024
    ## [SPEC TRANSPORT §2.1] The smallest configured maximum a stream
    ## implementation must support (`trn-max-frame-floor` in spec/pins.toml).
  FrameCeiling* = uint64(high(uint32)) ## what the length prefix can express

type
  FrameErrorKind* = enum
    feTooLarge ## a declared length over the configured maximum
    feTruncated ## the stream ended inside a frame

  FrameError* = object
    kind*: FrameErrorKind
    declared*: uint64 ## the declared body length

  FrameReader* = object
    ## Splits a byte stream into frame bodies. After an error it accepts nothing
    ## more: the connection is to be closed (§2.1).
    limit: uint32
    pending: seq[byte] ## at most a header and the body declared by it
    want: int ## the body length being read; -1 while reading a header
    failed: bool

func newFrameReader*(limit: uint32 = MinFrameLimit): FrameReader =
  ## `limit` is the configured maximum accepted frame size [SPEC TRANSPORT §2.1].
  FrameReader(limit: limit, want: -1)

func limit*(r: FrameReader): uint32 =
  r.limit

func failed*(r: FrameReader): bool =
  r.failed

func buffered*(r: FrameReader): int =
  ## Bytes held for an incomplete frame.
  r.pending.len

func frame*(body: openArray[byte]): Result[seq[byte], string] =
  ## [SPEC TRANSPORT §2.1] The length prefix and the body.
  if uint64(body.len) > FrameCeiling:
    return err("a frame body is at most 4,294,967,295 bytes")
  let n = uint32(body.len)
  var s = newSeqOfCap[byte](4 + body.len)
  s.add([byte(n shr 24), byte(n shr 16), byte(n shr 8), byte(n)])
  s.add(body)
  ok(s)

func feed*(
    r: var FrameReader, data: openArray[byte]
): Result[seq[seq[byte]], FrameError] =
  ## The frame bodies `data` completes, in order. A declared length over the
  ## limit fails as soon as its 4 bytes arrive: the body is neither read nor
  ## allocated [SPEC TRANSPORT §2.1, §8.3].
  if r.failed:
    return err(FrameError(kind: feTooLarge))
  var frames: seq[seq[byte]]
  var i = 0
  while i < data.len:
    if r.want < 0:
      let take = min(4 - r.pending.len, data.len - i)
      r.pending.add(data.toOpenArray(i, i + take - 1))
      i += take
      if r.pending.len == 4:
        let n =
          (uint32(r.pending[0]) shl 24) or (uint32(r.pending[1]) shl 16) or
          (uint32(r.pending[2]) shl 8) or uint32(r.pending[3])
        r.pending.setLen(0)
        if n > r.limit:
          r.failed = true
          r.pending = @[]
          return err(FrameError(kind: feTooLarge, declared: uint64(n)))
        r.want = int(n)
    if r.want >= 0:
      let take = min(r.want - r.pending.len, data.len - i)
      if take > 0:
        r.pending.add(data.toOpenArray(i, i + take - 1))
        i += take
      if r.pending.len == r.want:
        frames.add(move r.pending)
        r.pending = @[]
        r.want = -1
  ok(frames)

func finish*(r: FrameReader): Result[void, FrameError] =
  ## At end of stream: whether it ended between frames.
  if r.want >= 0 or r.pending.len > 0:
    return err(FrameError(kind: feTruncated, declared: uint64(max(r.want, 0))))
  ok()
