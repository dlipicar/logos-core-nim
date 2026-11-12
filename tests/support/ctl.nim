## The control channel between `test_transport_io` and a `trnpeer` child:
## framed deterministic CBOR (the `framing.nim` codec) over a blocking stream
## socket. Route tickets travel only here, never in argv or the environment
## (TRANSPORT §8.1).

import std/posix
import results
import ../../src/logos_core/cbor
import ../../src/logos_core/transport/framing

proc waitReadable*(fd: cint, timeoutMs: int): bool =
  var p = TPollfd(fd: fd, events: POLLIN)
  posix.poll(addr p, 1, cint(timeoutMs)) > 0

proc writeAll*(fd: cint, data: openArray[byte]): bool =
  var off = 0
  while off < data.len:
    let n = posix.write(fd, unsafeAddr data[off], data.len - off)
    if n < 0:
      if errno == EINTR:
        continue
      return false
    off += n
  true

proc readExact*(fd: cint, buf: var openArray[byte], timeoutMs: int): bool =
  var off = 0
  while off < buf.len:
    if not waitReadable(fd, timeoutMs):
      return false
    let n = posix.read(fd, addr buf[off], buf.len - off)
    if n < 0 and errno == EINTR:
      continue
    if n <= 0:
      return false
    off += n
  true

proc ctlSend*(fd: cint, v: CborValue): bool =
  writeAll(fd, frame(encodeCbor(v)).get)

proc ctlRecv*(fd: cint, timeoutMs = 10_000): Opt[CborValue] =
  var p: array[4, byte]
  if not readExact(fd, p, timeoutMs):
    return Opt.none(CborValue)
  let n = parsePrefix(p, MinFrameLimit).valueOr:
    return Opt.none(CborValue)
  var body = newSeq[byte](n)
  if not readExact(fd, body, timeoutMs):
    return Opt.none(CborValue)
  let v = decodeCbor(body).valueOr:
    return Opt.none(CborValue)
  Opt.some(v)

proc field*(v: CborValue, key: string): CborValue =
  v.lookup(key).get(cbor(""))

proc text*(v: CborValue, key: string): string =
  v.field(key).getText.get("")

proc num*(v: CborValue, key: string): uint64 =
  v.field(key).getUint64.get(0)

proc bytes*(v: CborValue, key: string): seq[byte] =
  v.field(key).getBytes.get(@[])

proc flag*(v: CborValue, key: string): bool =
  v.field(key).getBool.get(false)
