## Erasure of marked payloads (Tier 4b step 4b-3b plan §4.2; DECISIONS G276,
## I92): the primitives, the encoder and decoder, the commitment layer and the
## connection buffers.
##
## The free scan (`base/wipeaudit`) searches every released block for a canary
## (32 random bytes per run) and the value roots derived from it. It sees the
## Nim heap only under orc and arc with `-d:useMalloc` (`test_wipe.nims`), and
## not on Windows: there the cases that need it are skipped, and the unit
## checks, which read the memory before it is released, still run.

import std/[algorithm, os, random, strutils, sysrand]
import unittest2
import results
import ../src/logos_core/base/[wipe, wipeaudit]
import ../src/logos_core/cbor
import ../src/logos_core/crypto/blake3
import ../src/logos_core/hash/hashinput
import ../src/logos_core/iface/accept
import ../src/logos_core/transport/[boundary, envelope]
import ../src/logos_core/abi/cstatus

let canary = urandom(32)
let scans = wipeAuditScans()

proc bytesAt(p: pointer, n: int): seq[byte] =
  result = newSeq[byte](n)
  if n > 0:
    copyMem(addr result[0], p, n)

proc allZero(p: pointer, n: int): bool =
  let a = cast[ptr UncheckedArray[byte]](p)
  for i in 0 ..< n:
    if a[i] != 0:
      return false
  true

proc arm(patterns: sink seq[seq[byte]]) =
  ## The patterns are taken and zeroed once registered: pass copies.
  armWipeAudit(patterns)

proc hits(): int =
  ## Blocks released holding a pattern since arming; the backtraces go to stderr.
  result = wipeAuditHits()
  if result > 0:
    reportWipeAudit()

# A reference encoder: the rules of INTERFACE §4.4 written plainly, recursion
# and all. The encoder before 4b-3b wrote the same bytes (the vectors of
# test_cbor pin both).

proc refEncode(v: CborValue, o: var seq[byte]) =
  case v.kind
  of ckUint:
    writeHead(o, 0, v.uint)
  of ckNint:
    writeHead(o, 1, v.nint)
  of ckBytes:
    writeHead(o, 2, uint64(v.bytes.len))
    o.add(v.bytes)
  of ckText:
    writeHead(o, 3, uint64(v.text.len))
    o.add(v.text.toOpenArrayByte(0, v.text.high))
  of ckSimple:
    if v.simple < 24:
      o.add(0xe0'u8 or v.simple)
    else:
      o.add(0xf8)
      o.add(v.simple)
  of ckFloat:
    let ai =
      case v.width
      of fw16: 25'u8
      of fw32: 26'u8
      of fw64: 27'u8
    o.add(0xe0'u8 or ai)
    for i in countdown(ord(v.width) - 1, 0):
      o.add(uint8((v.floatBits shr (8 * i)) and 0xff))
  of ckArray:
    writeHead(o, 4, uint64(v.items.len))
    for x in v.items:
      refEncode(x, o)
  of ckTag:
    writeHead(o, 6, v.tag)
    refEncode(v.content, o)
  of ckMap:
    var es: seq[(seq[byte], seq[byte])]
    for (k, x) in v.entries:
      var kb, xb: seq[byte]
      refEncode(k, kb)
      refEncode(x, xb)
      es.add((kb, xb))
    es.sort(
      proc(a, b: (seq[byte], seq[byte])): int =
        cmpBytes(a[0], b[0])
    )
    writeHead(o, 5, uint64(es.len))
    for (kb, xb) in es:
      o.add(kb)
      o.add(xb)

proc refEncode(v: CborValue): seq[byte] =
  refEncode(v, result)

proc randomBytes(r: var Rand, n: int): seq[byte] =
  for _ in 0 ..< n:
    result.add(byte(r.rand(255)))

proc randomScalar(r: var Rand): CborValue =
  let lens = [0, 1, 23, 24, 255, 256, 300]
  case r.rand(6)
  of 0:
    cbor([0'u64, 23, 24, 255, 256, 65535, 65536, high(uint32), high(uint64)][r.rand(8)])
  of 1:
    cborNint(r.rand(1 shl 20).uint64)
  of 2:
    cbor(r.randomBytes(lens[r.rand(lens.high)]))
  of 3:
    cbor(repeat('a', lens[r.rand(lens.high)]))
  of 4:
    cborSimple([20'u8, 21, 22, 23, 32, 255][r.rand(5)])
  of 5:
    cborFloatBits([fw16, fw32, fw64][r.rand(2)], 0x3c00)
  else:
    cbor(r.rand(1) == 1)

proc randomTree(r: var Rand, depth: int): CborValue =
  if depth == 0 or r.rand(3) == 0:
    return r.randomScalar()
  case r.rand(2)
  of 0:
    var items: seq[CborValue]
    for _ in 0 ..< r.rand(5):
      items.add(r.randomTree(depth - 1))
    cborArray(items)
  of 1:
    var
      entries: seq[CborEntry]
      seen: seq[seq[byte]]
    for _ in 0 ..< r.rand(6):
      let k = r.randomTree(depth - 1)
      let kb = refEncode(k)
      if kb notin seen:
        seen.add(kb)
        entries.add((k, r.randomTree(depth - 1)))
    cborMap(entries)
  else:
    cborTag(uint64(r.rand(1 shl 17)), r.randomTree(depth - 1))

# The contract of the vault: `store` marks its request, `get` its response.
const VaultDoc =
  "_module = \"vault_module\"\n" &
  "_sensitive = [\"vault.get_response\", \"vault.store_request\"]\n\n" &
  "vault.store_request = {\n  secret: bstr,\n}\n\n" &
  "vault.store_response = {\n  ok: bool,\n}\n\n" &
  "vault.get_request = {\n  slot: uint32,\n}\n\n" &
  "vault.get_response = {\n  secret: bstr,\n}\n"

suite "wipe: primitives (W-1)":
  test "[IFC-0575] wiping a seq or string zeroes it to its capacity, stale tail included":
    var s = newSeqOfCap[byte](64)
    for i in 0 ..< 40:
      s.add(byte(i + 1))
    s.setLen(10) # bytes 10 to 39 are stale
    let p = addr s[0]
    let cap = s.capacity
    wipe(s)
    check s.len == 0
    check s.capacity == cap
    check allZero(p, cap)

    var t = newStringOfCap(48)
    t.add(repeat('x', 30))
    t.setLen(5)
    let q = addr t[0]
    let tcap = t.capacity
    wipe(t)
    check t.len == 0
    check allZero(q, tcap)

  test "[IFC-0575] secureZero and wipeObject zero memory; a hasher's state is zeroed":
    var a: array[48, byte]
    for i in 0 ..< a.len:
      a[i] = 0xa5
    secureZero(addr a[0], a.len)
    check allZero(addr a[0], a.len)

    var h: Blake3Hasher
    h.init()
    h.update(canary)
    var held = false
    let raw = bytesAt(addr h, sizeof(h))
    for i in 0 .. raw.len - canary.len:
      if raw[i ..< i + canary.len] == canary:
        held = true
    check held # the state buffers input not yet compressed
    h.wipe()
    check allZero(addr h, sizeof(h))

  test "[IFC-0575] wiping a value tree zeroes every byte and text string in it":
    var name = "secret-key" # a literal is shared storage: wiped by copy-on-write
    name.add('!')
    let
      key = cbor(name)
      leaf = cbor(canary)
      deep = cbor(canary)
      tree = cborArray(
        cborMap((key, leaf), (cbor(1'u64), cborTag(24, cborArray(deep)))), cbor("x")
      )
    let
      kp = addr key.text[0]
      kc = key.text.capacity
      lp = addr leaf.bytes[0]
      lc = leaf.bytes.capacity
      dp = addr deep.bytes[0]
      dc = deep.bytes.capacity
    wipe(tree)
    check key.text.len == 0 and leaf.bytes.len == 0 and deep.bytes.len == 0
    check allZero(kp, kc) and allZero(lp, lc) and allZero(dp, dc)

  test "wiping a tree leaves the literals it was built from intact (orc and refc)":
    proc literal(): CborValue =
      cborMap((cbor("literal-key"), cbor("literal-text")))

    var t = cborArray(literal(), literal())
    wipe(t)
    let again = literal()
    check again.entries[0].key.text == "literal-key"
    check again.entries[0].value.text == "literal-text"

  test "[IFC-0575] wiping a commitment zeroes its value root":
    var c = PayloadCommitment()
    for i in 0 ..< c.valueRoot.len:
      c.valueRoot[i] = 0x5a
      c.subtreeRoot[i] = 0x11
    wipe(c)
    check allZero(addr c.valueRoot[0], c.valueRoot.len)
    check c.subtreeRoot[0] == 0x11 # the declaration's root is no payload

  test "the marked scope nests, and is left on an exception":
    check not inMarkedScope()
    markedScope(false):
      check not inMarkedScope()
    markedScope(true):
      check inMarkedScope()
      markedScope(false):
        check inMarkedScope()
    check not inMarkedScope()
    try:
      markedScope(true):
        raise newException(ValueError, "x")
    except ValueError:
      discard
    check not inMarkedScope()

  test "[IFC-0575] a shared-heap copy is zeroed before it is released":
    if not scans:
      skip()
    else:
      arm(@[canary])
      let p = allocShared(canary.len)
      copyMem(p, unsafeAddr canary[0], canary.len)
      freeWiped(p, canary.len)
      check hits() == 0
      let q = allocShared(canary.len)
      copyMem(q, unsafeAddr canary[0], canary.len)
      deallocShared(q) # the control: not wiped
      check wipeAuditHits() == 1
      disarmWipeAudit()

  test "[IFC-0575] a buffer handed across the ABI is zeroed whole when released":
    if not scans:
      skip()
    else:
      arm(@[canary])
      var held = canary & canary
      var
        buf: ptr UncheckedArray[uint8]
        len: csize_t
      discard give(held, addr buf, addr len)
      wipe(held)
      check int(len) == 64
      releaseGiven(buf)
      check hits() == 0
      disarmWipeAudit()

  test "[IFC-0575] a marked-scope commit leaves no copy of the payload or its value root":
    if not scans:
      skip()
    else:
      let s = acceptContractSet(VaultDoc).get
      let b = boundary(s, s.primary.root).get
      check b.marked("store") == (true, false)
      check b.marked("get") == (false, true)
      var params = cborMap((cbor("secret"), cbor(canary)))
      var first = b.commitRequest("store", params).get
      var root = first.valueRoot
      wipe(first)
      arm(@[canary, @root])
      var c = b.commitRequest("store", params).get
      check c.valueRoot == root
      wipe(c)
      wipeObject(root)
      wipe(params)
      check hits() == 0
      disarmWipeAudit()

suite "wipe: encoder and decoder (W-2)":
  test "[IFC-0575] the encoder writes the reference bytes into one buffer of exact size":
    var r = initRand(0x4b3b)
    for _ in 0 ..< 400:
      let v = r.randomTree(4)
      let want = refEncode(v)
      let got = encodeCbor(v)
      check got == want
      check encodedSize(v) == want.len
      check got.capacity == got.len # sized once: never grown
      var appended = @[0xaa'u8]
      encodeCbor(v, appended)
      check appended[1 .. ^1] == want

  test "[IFC-0575] encoding a payload leaves no copy, its map keys included":
    if not scans:
      skip()
    else:
      arm(@[canary])
      var tree = cborArray(
        cborMap((cbor(canary), cbor(1'u64)), (cbor("v"), cbor(canary))),
        cborTag(24, cborMap((cbor(canary & @[1'u8]), cborArray(cbor(canary))))),
      )
      var e = encodeCbor(tree)
      check wipeAuditFinds(e) == 1
      var more = e # an output with no room: moved once, the old storage zeroed
      encodeCbor(tree, more)
      wipe(e)
      wipe(more)
      wipe(tree)
      check hits() == 0
      disarmWipeAudit()

  test "[IFC-0575] a failing decode leaves no copy of what it read":
    if not scans:
      skip()
    else:
      arm(@[canary])
      # [h'canary', 1] with 1 written in two bytes: non-deterministic, after the copy.
      var bad = @[0x82'u8, 0x58, 0x20] & canary & @[0x18'u8, 0x01]
      check decodeCbor(bad).isErr
      # {h'canary': h'canary'} cut short in its value.
      var cut = @[0xa1'u8, 0x58, 0x20] & canary & @[0x58'u8, 0x20] & canary[0 .. 9]
      check decodeCbor(cut).isErr
      # Text that is not UTF-8 after the canary: rejected before it is copied.
      var text = @[0x82'u8, 0x58, 0x20] & canary & @[0x62'u8, 0xff, 0xfe]
      check decodeCbor(text).isErr
      wipe(bad)
      wipe(cut)
      wipe(text)
      check hits() == 0
      # A decode that succeeds: the tree is the caller's to wipe.
      var good = @[0x81'u8, 0x58, 0x20] & canary
      var v = decodeCbor(good).get
      wipe(good)
      wipe(v)
      check hits() == 0
      disarmWipeAudit()

suite "wipe: the free scan (W-3)":
  test "an unwiped copy is reported with a backtrace; a wiped one is not":
    if not scans:
      skip()
    else:
      arm(@[canary])
      block:
        var leak = canary # released unwiped
        check leak.len == 32
      check wipeAuditHits() == 1
      let path = getTempDir() / ("lcn-wipe-report-" & $getCurrentProcessId())
      var f: File
      check open(f, path, fmWrite)
      reportWipeAudit(cint(getFileHandle(f)))
      close(f)
      let report = readFile(path)
      removeFile(path)
      check "wipe audit: pattern 0 in a released block of" in report
      check report.splitLines.len > 3 # the backtrace
      arm(@[canary])
      block:
        var done = canary
        wipe(done)
      check wipeAuditHits() == 0
      var region = @[1'u8, 2] & canary
      check wipeAuditFinds(region) == 1
      wipe(region)
      disarmWipeAudit()

when not defined(windows):
  import chronos/[asyncloop, timer]
  import ../src/logos_core/transport/limits
  import ../src/logos_core/transport/io/[api, conn, sock]

  var framesSeen: int

  proc dropEvent(ev: sink IoEvent, ctx: pointer) {.nimcall, gcsafe, raises: [].} =
    var e = ev
    wipe(e)

  proc leaveFrame(
      io: Io, c: Conn, body: var seq[byte]
  ) {.nimcall, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      inc framesSeen

  proc tick(arg: pointer) {.gcsafe, raises: [].} =
    discard

  proc pump(until: proc(): bool {.closure.}, turns = 500): bool =
    ## Runs the dispatcher in turns of at most 10 ms until `until` holds.
    for _ in 0 ..< turns:
      if until():
        return true
      var t = setTimer(Moment.fromNow(10.milliseconds), tick, nil)
      try:
        poll()
      except CatchableError:
        discard
      cancelTimer(t)
    until()

  proc opened(): (Io, Conn, cint) =
    ## An established connection over a socket pair, and the peer's end.
    var fds: array[2, cint]
    doAssert socketPair(addr fds) == 0
    doAssert setNonblock(fds[0]) == 0 and setNonblock(fds[1]) == 0
    let io = newIo(defaultTransportConfig(), defaultLimits(), dropEvent, nil)
    io.onFrame = leaveFrame
    theIo = io
    let c = io.newConn(ConnId(1), roCaller, fds[0])
    c.phase = phOpen
    io.track(c)
    doAssert c.register()
    io.updateReading(c)
    (io, c, fds[1])

  proc send(fd: cint, bytes: var seq[byte]) =
    doAssert sockSend(fd, addr bytes[0], csize_t(bytes.len)) == bytes.len
    wipe(bytes)

  suite "wipe: connection buffers (W-11)":
    test "[IFC-0575] a frame body is zeroed once its handler returns":
      if not scans:
        skip()
      else:
        arm(@[canary])
        let (io, c, peer) = opened()
        framesSeen = 0
        var wire = framed(canary)
        peer.send(wire)
        check pump(
          proc(): bool =
            {.cast(gcsafe).}:
              framesSeen == 1
        )
        io.finalClose(c)
        discard fdClose(peer)
        theIo = nil
        check hits() == 0
        disarmWipeAudit()

    test "[IFC-0575] a partial body is zeroed when the connection closes":
      if not scans:
        skip()
      else:
        arm(@[canary])
        let (io, c, peer) = opened()
        framesSeen = 0
        var whole = framed(canary & canary)
        var part = whole[0 ..< 4 + 40]
        wipe(whole)
        peer.send(part)
        discard pump(
          proc(): bool =
            false,
          turns = 5,
        )
        discard fdClose(peer) # end of input: the connection is lost
        check pump(
          proc(): bool =
            c.phase == phDone
        )
        check framesSeen == 0
        theIo = nil
        check hits() == 0
        disarmWipeAudit()

    test "[IFC-0575] a framed copy is zeroed once written, and once dropped":
      if not scans:
        skip()
      else:
        arm(@[canary])
        block written:
          let (io, c, peer) = opened()
          check io.commit(c, canary, fcData)
          var got = newSeq[byte](64)
          var n = 0
          check pump(
            proc(): bool =
              let r = sockRecv(peer, addr got[n], csize_t(got.len - n))
              if r > 0:
                n += int(r)
              n == canary.len + 4
          )
          check wipeAuditFinds(got) == 1
          wipe(got)
          io.finalClose(c)
          discard fdClose(peer)
          theIo = nil
        check hits() == 0
        arm(@[canary])
        block dropped:
          let (io, c, peer) = opened()
          check io.commit(c, canary, fcData)
          io.finalClose(c) # before any write: the frame is dropped
          discard fdClose(peer)
          theIo = nil
        check hits() == 0
        disarmWipeAudit()
