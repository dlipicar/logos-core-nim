## `list_grants` cursors [IMPL] (CA l.703-714; CAP-0331 to CAP-0335;
## DECISIONS I84).
##
## `base64url(det-CBOR [1, qhash, last_id, issued_ms, mac])`, unpadded:
## - `qhash`: the first 16 bytes of BLAKE3 over the det-CBOR of
##   `[consumer, target or null, status or null, limit]`;
## - `mac`: the first 16 bytes of keyed BLAKE3 over the det-CBOR of the
##   preceding four elements, with a 32-byte key drawn at every open.
##
## A continuation selects ids strictly greater than `last_id` in the state as
## it is then: live, not a snapshot. Cursors expire after a lifetime (600 s by
## default) and all of them die at restart. A bad MAC, a malformed or expired
## cursor, another consumer's cursor and a changed query all fail the same way,
## so nothing about another query is revealed.

{.push raises: [].}

import std/[base64, strutils]
import results
import ../cbor
import ../crypto/blake3
import ./scopes

export results

type
  CursorKey* = array[32, byte]

  CursorQuery* = object
    consumer*: Address
    target*: Opt[Address]
    status*: Opt[GrantStatusKind]
    limit*: uint64

  CursorState* = object
    lastId*: string
    issuedMs*: uint64

proc queryHash(q: CursorQuery): seq[byte] =
  let v = cborArray(
    toCbor(q.consumer),
    (if q.target.isSome: toCbor(q.target.get) else: cborNull()),
    (if q.status.isSome: cbor(int(ord(q.status.get))) else: cborNull()),
    cbor(q.limit),
  )
  let d = blake3(encodeCbor(v))
  @(d[0 ..< 16])

proc mac(key: CursorKey, head: CborValue): seq[byte] =
  var h: Blake3Hasher
  h.initKeyed(key)
  h.update(encodeCbor(head))
  let d = h.finish()
  @(d[0 ..< 16])

func sameBytes(a, b: openArray[byte]): bool =
  ## Constant-time for equal lengths.
  if a.len != b.len:
    return false
  var d = 0'u8
  for i in 0 ..< a.len:
    d = d or (a[i] xor b[i])
  d == 0

proc makeCursor*(key: CursorKey, q: CursorQuery, s: CursorState): string =
  let head = cborArray(cbor(1), cbor(q.queryHash), cbor(s.lastId), cbor(s.issuedMs))
  let whole = cborArray(
    cbor(1), cbor(q.queryHash), cbor(s.lastId), cbor(s.issuedMs), cbor(mac(key, head))
  )
  encode(encodeCbor(whole), safe = true).strip(leading = false, chars = {'='})

proc readCursor*(
    key: CursorKey, q: CursorQuery, cursor: string, now: uint64, lifetimeMs: uint64
): Opt[CursorState] =
  ## The cursor's state, or none for any failure.
  var raw: string
  try:
    var padded = cursor
    while padded.len mod 4 != 0:
      padded.add '='
    raw = decode(padded)
  except ValueError:
    return Opt.none(CursorState)
  let v = decodeCbor(raw).valueOr:
    return Opt.none(CursorState)
  if v.kind != ckArray or v.items.len != 5:
    return Opt.none(CursorState)
  let ver = v.items[0].getUint64()
  let qh = v.items[1].getBytes()
  let last = v.items[2].getText()
  let issued = v.items[3].getUint64()
  let tag = v.items[4].getBytes()
  if ver != Opt.some(1'u64) or qh.isNone or last.isNone or issued.isNone or tag.isNone:
    return Opt.none(CursorState)
  let head = cborArray(v.items[0], v.items[1], v.items[2], v.items[3])
  if not sameBytes(tag.get, mac(key, head)) or not sameBytes(qh.get, q.queryHash):
    return Opt.none(CursorState)
  if issued.get > now or now - issued.get >= lifetimeMs:
    return Opt.none(CursorState)
  Opt.some(CursorState(lastId: last.get, issuedMs: issued.get))
