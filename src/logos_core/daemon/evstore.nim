## logosd's call-evidence store (Tier 4b step 4b-6; DECISIONS G301, G115,
## G143; CAPABILITY AUTHORITY l.1169, l.1320-1330). docs/DAEMON.md §9.
##
## The Runtime retains call records in a ring (`runtime/callaudit.nim`); a
## store, set as its sink (`runtimeSetCallRecordSink`, G304), keeps them on
## disk too, so the owner can export one as call evidence later
## (`logosctl audit evidence export`).
##
## - **Offer.** `offer(index, bytes)` copies the record into shared memory and
##   files it under a short lock; it never blocks the call path and never waits
##   for the disk. The record with ring index `i` gets seq `base + i`, `base`
##   being the seq after the last one stored when the store opened, so records
##   offered out of order by several threads still get unique seqs, stored in
##   order. At most `queue` records wait: one past the window of `queue` seqs
##   after the next one to write is dropped, and its seq counted.
## - **Writer.** One thread, woken by a condition variable, writes at most
##   `BatchEntries` entries at a time in seq order, a gap entry for every run of
##   dropped seqs, and flushes the segment to the medium after each batch. It
##   logs drops once per batch.
## - **Segments** (`evstore.cddl`). `seg-<first seq, 20 digits>.lcr`, 0600 in a
##   0700 directory, each entry a 4-byte big-endian length then one
##   deterministic-CBOR `lcn.ev_entry`; the first is a header naming the
##   producer (the Runtime id), the kid of the evidence key configured at open,
##   and the open's number (`boot`). Each open starts a segment; a segment is
##   rotated at `segmentEntries` entries or `segmentBytes` bytes.
## - **Bounds** (G143). Whole segments, oldest first, are reaped at open and at
##   each rotation while the store spans more than `maxRecords` seqs (records,
##   and the dropped records its gaps stand for), and while the oldest was last
##   written more than `maxAgeDays` ago (the file's modification time). The
##   segment being written is never reaped.
## - **Crash.** A segment is only appended to. At open, a torn or undecodable
##   tail of the newest segment is cut off; a segment with nothing after its
##   header is replaced by the new one. A failed write closes the segment and
##   the next batch starts another, so damage stays at a segment's end; a
##   reader stops there.
## - **What it does not do** (G301): no proof enters it; nothing is encrypted
##   or integrity-protected beyond the file modes; nothing is sent anywhere.
##
## Shared state is plain memory under one lock (no garbage-collected value
## crosses threads, under ORC or refc). The writer thread owns the files.

{.push raises: [].}

import std/[locks, os, strutils, times, typedthreads]
import results
import ../durable
import logos_sdk/base/testhooks
import ./evstore_types

export results, evstore_types

testHooksMarker("evstore")

const
  StoreFormat* = "logos-core-nim.evidence-store.v1"
  SegmentPrefix* = "seg-"
  SegmentSuffix* = ".lcr"
  SegmentDigits = 20
  DefaultSegmentEntries* = 10_000 ## [IMPL] rotation: entries in one segment
  DefaultSegmentBytes* = 16 * 1024 * 1024 ## [IMPL] rotation: bytes in one segment
  BatchEntries* = 256 ## [IMPL] the most entries one flush writes
  MaxRecordBytes* = 1024 * 1024 ## `lcn.ev_record.record`'s bound
  MaxEntryBytes* = MaxRecordBytes + 256 ## [IMPL] one entry, framing aside
  KidBytes = 16
  MaxProducerBytes = 128
  MessageBytes = 512
  DayMs = 86_400_000'u64

type
  ClockMs* = proc(): uint64 {.nimcall, gcsafe, raises: [].}
    ## Milliseconds since the Unix epoch.

  StoreLog* = proc(line: string) {.nimcall, gcsafe, raises: [].}

  StoreOptions* = object
    dir*: string ## `<session>/state/evidence`
    producer*: string ## the Runtime id
    kid*: seq[byte] ## the configured evidence key's kid, 16 bytes
    maxRecords*: int
    maxAgeDays*: int
    queue*: int
    segmentEntries*: int = DefaultSegmentEntries
    segmentBytes*: int = DefaultSegmentBytes
    clock*: ClockMs ## nil: the wall clock
    log*: StoreLog ## nil: none

  Phase = enum
    phOpening
    phRunning
    phFailed
    phStopped

  Pending = object
    full: bool
    index: uint64
    atMs: uint64
    data: ptr UncheckedArray[byte]
    len: int

  DropRange = object
    first, count: uint64 ## ring indices

  StoreObj = object
    lock: Lock
    cond: Cond ## the writer's wake-up, and the opener's
    phase: Phase
    stopping: bool
    paused: bool ## [test hook] the writer takes nothing while set
    message: array[MessageBytes, char] ## the open's failure
    # The options, as plain memory.
    dir: cstring
    producer: cstring
    kid: array[KidBytes, byte]
    maxRecords, maxAgeDays: int
    segmentEntries, segmentBytes: int
    clock: ClockMs
    log: StoreLog
    # The queue: slot `i mod cap` holds ring index `i` while `next <= i < next + cap`.
    cap: int
    slots: ptr UncheckedArray[Pending]
    next: uint64 ## the ring index the writer takes next
    seen: uint64 ## one past the highest index offered
    done: uint64 ## indices below this are written (or lost to a write failure)
    drops: ptr UncheckedArray[DropRange] ## sorted, disjoint, not adjacent
    dropLen, dropCap: int
    dropped: uint64 ## every seq dropped since open
    base: uint64 ## seq = base + index
    boot: uint64
    thread: Thread[ptr StoreObj]

  EvidenceStore* = ptr StoreObj

proc wallMs(): uint64 {.nimcall, gcsafe, raises: [].} =
  let t = getTime()
  uint64(max(t.toUnix, 0)) * 1000 + uint64(t.nanosecond div 1_000_000)

proc sharedCString(s: string): cstring =
  let p = cast[ptr UncheckedArray[char]](allocShared0(s.len + 1))
  for i, c in s:
    p[i] = c
  cast[cstring](p)

proc setMessage(st: EvidenceStore, m: string) =
  let n = min(m.len, MessageBytes - 1)
  for i in 0 ..< n:
    st.message[i] = m[i]
  st.message[n] = '\0'

# Segment files -----------------------------------------------------------------------

func segmentName*(first: uint64): string =
  SegmentPrefix & align($first, SegmentDigits, '0') & SegmentSuffix

func segmentFirst*(name: string): Opt[uint64] =
  ## The first seq a segment's name gives; none for another name.
  if not (name.startsWith(SegmentPrefix) and name.endsWith(SegmentSuffix)):
    return Opt.none(uint64)
  let digits = name[SegmentPrefix.len ..< name.len - SegmentSuffix.len]
  if digits.len != SegmentDigits or not digits.allCharsInSet(Digits):
    return Opt.none(uint64)
  try:
    Opt.some(uint64(parseBiggestUInt(digits)))
  except ValueError:
    Opt.none(uint64)

proc segmentNames*(dir: string): seq[(uint64, string)] =
  ## The segments in `dir`, by first seq.
  for name in fileNames(dir):
    let first = segmentFirst(name)
    if first.isSome:
      result.add((first.get, name))
  for i in 1 ..< result.len:
    var j = i
    while j > 0 and result[j - 1][0] > result[j][0]:
      swap(result[j - 1], result[j])
      dec j

proc frame(e: LcnEvEntry): Result[seq[byte], string] =
  let body = ?e.encode
  if body.len > MaxEntryBytes:
    return err("an entry is larger than " & $MaxEntryBytes & " bytes")
  var framed = newSeqOfCap[byte](body.len + 4)
  let n = uint32(body.len)
  framed.add(byte(n shr 24))
  framed.add(byte(n shr 16))
  framed.add(byte(n shr 8))
  framed.add(byte(n))
  framed.add(body)
  ok(framed)

type ParsedSegment* = object
  header*: Opt[LcnEvHeader]
  entries*: seq[LcnEvEntry] ## after the header
  validBytes*: int ## where the readable part ends
  damaged*: bool ## bytes follow that are torn or do not decode
  endSeq*: uint64 ## one past the last seq it holds; its first seq when none

proc parseSegment*(first: uint64, bytes: openArray[byte]): ParsedSegment =
  ## Its header, then every entry up to the first torn or undecodable one.
  result.endSeq = first
  var off = 0
  while off < bytes.len:
    if bytes.len - off < 4:
      result.damaged = true
      break
    let n =
      (int(bytes[off]) shl 24) or (int(bytes[off + 1]) shl 16) or
      (int(bytes[off + 2]) shl 8) or int(bytes[off + 3])
    if n < 1 or n > MaxEntryBytes or bytes.len - off - 4 < n:
      result.damaged = true
      break
    let e = LcnEvEntry.decode(bytes.toOpenArray(off + 4, off + 4 + n - 1)).valueOr:
      result.damaged = true
      break
    if result.header.isNone:
      if e.kind != LcnEvEntryKind.lcn_Ev_header or
          e.arm_lcn_Ev_header.format != StoreFormat:
        result.damaged = true
        break
      result.header = Opt.some(e.arm_lcn_Ev_header)
    else:
      case e.kind
      of LcnEvEntryKind.lcn_Ev_header:
        result.damaged = true
        break
      of LcnEvEntryKind.lcn_Ev_record:
        let s = e.arm_lcn_Ev_record.seq
        if s < result.endSeq:
          result.damaged = true
          break
        result.endSeq = s + 1
      of LcnEvEntryKind.lcn_Ev_gap:
        let g = e.arm_lcn_Ev_gap.gap
        if g.first < result.endSeq or g.count < 1 or g.first + g.count < g.first:
          result.damaged = true
          break
        result.endSeq = g.first + g.count
      result.entries.add(e)
    off += 4 + n
    result.validBytes = off

proc readSegment*(dir, name: string): Result[seq[byte], string] =
  let bytes = ?readBounded(dir / name, high(int32))
  if bytes.isNone:
    return err(name & " is gone")
  ok(bytes.get)

proc modifiedMs(path: string): Result[uint64, string] =
  try:
    let t = getLastModificationTime(path)
    ok(uint64(max(t.toUnix, 0)) * 1000 + uint64(t.nanosecond div 1_000_000))
  except OSError as e:
    err("cannot inspect " & path & ": " & e.msg)

# The writer --------------------------------------------------------------------------

type
  Item = object
    gap: bool
    index: uint64 ## a record's index, or a gap's first
    count: uint64 ## a gap's
    atMs: uint64
    data: ptr UncheckedArray[byte]
    len: int

  Writer = object
    st: EvidenceStore
    dir, producer: string
    kid: seq[byte]
    segments: seq[(uint64, string)] ## the closed ones, oldest first
    current: AppendFile
    currentFirst: uint64
    entries, bytes: int ## the current segment's

proc say(w: Writer, line: string) =
  if w.st.log != nil:
    w.st.log("call-evidence store: " & line)

proc clockMs(w: Writer): uint64 =
  if w.st.clock != nil:
    w.st.clock()
  else:
    wallMs()

proc reap(w: var Writer, endSeq: uint64) =
  ## [G143] Whole segments, oldest first, while the store spans more than
  ## `maxRecords` seqs or the oldest is older than `maxAgeDays`.
  let maxAge = uint64(w.st.maxAgeDays) * DayMs
  let now = w.clockMs
  while w.segments.len > 0:
    let (first, name) = w.segments[0]
    var reaped = endSeq - first > uint64(w.st.maxRecords)
    if not reaped:
      let m = modifiedMs(w.dir / name)
      reaped = m.isOk and now > m.get and now - m.get > maxAge
    if not reaped:
      break
    removeDurably(w.dir, name).isOkOr:
      w.say("cannot reap " & name & ": " & error)
      break
    w.segments.delete(0)

proc startSegment(w: var Writer, first: uint64): Result[void, string] =
  ## A new segment whose first seq is `first`, with its header.
  let name = segmentName(first)
  var f = ?createAppend(w.dir, name)
  let header = ?frame(
    LcnEvEntry(
      kind: LcnEvEntryKind.lcn_Ev_header,
      arm_lcn_Ev_header: LcnEvHeader(producer: w.producer, kid: w.kid, boot: w.st.boot),
    )
  )
  f.append(header).isOkOr:
    f.close()
    discard removeDurably(w.dir, name)
    return err(name & ": " & error)
  w.current = f
  w.currentFirst = first
  w.entries = 1
  w.bytes = header.len
  ok()

proc closeSegment(w: var Writer) =
  if w.current.isOpen:
    w.current.close()
    w.segments.add((w.currentFirst, segmentName(w.currentFirst)))

proc open(w: var Writer): Result[void, string] =
  ## Steps at open: the directory, the newest segment's tail, the base and
  ## boot, the new segment, the bounds.
  ?ensurePrivateDir(w.dir)
  w.segments = segmentNames(w.dir)
  var base = 0'u64
  var boot = 0'u64
  if w.segments.len > 0:
    let (first, name) = w.segments[^1]
    let bytes = ?readSegment(w.dir, name)
    let p = parseSegment(first, bytes)
    base = p.endSeq
    if p.header.isSome:
      boot = p.header.get.boot
    if p.entries.len == 0:
      # Nothing after the header: the new segment, named alike, replaces it.
      ?removeDurably(w.dir, name)
      w.segments.setLen(w.segments.len - 1)
      if p.header.isNone and w.segments.len > 0:
        let (pf, pn) = w.segments[^1]
        let older = parseSegment(pf, ?readSegment(w.dir, pn))
        if older.header.isSome:
          boot = older.header.get.boot
    elif p.damaged:
      ?writeAtomic(w.dir, name, bytes.toOpenArray(0, p.validBytes - 1))
      w.say(
        name & ": a torn tail of " & $(bytes.len - p.validBytes) & " bytes was cut off"
      )
  w.st.base = base
  w.st.boot = boot + 1
  ?w.startSegment(base)
  w.reap(base)
  ok()

proc rotate(w: var Writer, first: uint64) =
  w.closeSegment()
  w.startSegment(first).isOkOr:
    w.say(error)
  w.reap(first)

proc entryOf(w: Writer, it: Item): Result[seq[byte], string] =
  let st = w.st
  if it.gap:
    return frame(
      LcnEvEntry(
        kind: LcnEvEntryKind.lcn_Ev_gap,
        arm_lcn_Ev_gap:
          LcnEvGap(gap: LcnEvGapGapMap(first: st.base + it.index, count: it.count)),
      )
    )
  var record = newSeq[byte](it.len)
  for i in 0 ..< it.len:
    record[i] = it.data[i]
  frame(
    LcnEvEntry(
      kind: LcnEvEntryKind.lcn_Ev_record,
      arm_lcn_Ev_record:
        LcnEvRecord(seq: st.base + it.index, at_ms: it.atMs, record: record),
    )
  )

proc write(w: var Writer, items: openArray[Item]) =
  ## The batch, in order, flushed once per segment it touches.
  var buf: seq[byte]
  var dropped = 0'u64
  template flush() =
    if buf.len > 0:
      if w.current.isOpen:
        w.current.append(buf).isOkOr:
          w.say("a write failed (" & error & "); the segment is closed")
          w.closeSegment()
      buf.setLen(0)

  for k, it in items:
    let seqNo = w.st.base + it.index
    if not w.current.isOpen or w.entries >= w.st.segmentEntries or
        w.bytes >= w.st.segmentBytes:
      flush()
      w.rotate(seqNo)
      if not w.current.isOpen:
        w.say(
          $(items.len - k) & " entries from seq " & $seqNo & " are lost: no segment"
        )
        return
    if it.gap:
      dropped += it.count
    var e = w.entryOf(it)
    if e.isErr:
      w.say("record " & $seqNo & " is not stored: " & e.error)
      e = w.entryOf(Item(gap: true, index: it.index, count: 1))
      if e.isErr:
        continue
    buf.add(e.get)
    inc w.entries
    w.bytes += e.get.len
  flush()
  if dropped > 0:
    w.say(
      $dropped & " call records dropped: the queue was full (gap entries record them)"
    )

proc collect(st: EvidenceStore, items: var seq[Item]) =
  ## Under the lock: the entries ready to write, in index order.
  let cap = uint64(st.cap)
  while items.len < BatchEntries:
    let n = st.next
    let slot = addr st.slots[int(n mod cap)]
    if slot.full and slot.index == n:
      items.add(Item(index: n, atMs: slot.atMs, data: slot.data, len: slot.len))
      slot[] = Pending()
      st.next = n + 1
    elif st.dropLen > 0 and st.drops[0].first == n:
      let r = st.drops[0]
      items.add(Item(gap: true, index: n, count: r.count))
      for i in 1 ..< st.dropLen:
        st.drops[i - 1] = st.drops[i]
      dec st.dropLen
      st.next = n + r.count
    elif st.stopping and n < st.seen:
      # A record never offered: the store closes without it.
      var m = n + 1
      while m < st.seen:
        let s = st.slots[int(m mod cap)]
        if (s.full and s.index == m) or (st.dropLen > 0 and st.drops[0].first == m):
          break
        inc m
      items.add(Item(gap: true, index: n, count: m - n))
      st.next = m
    else:
      break

proc writerMain(st: EvidenceStore) {.thread.} =
  var w = Writer(st: st, dir: $st.dir, producer: $st.producer, kid: @(st.kid))
  let opened = w.open()
  withLock st.lock:
    if opened.isErr:
      st.setMessage(opened.error)
      st.phase = phFailed
    else:
      st.phase = phRunning
    broadcast(st.cond)
  if opened.isErr:
    return
  var items: seq[Item]
  while true:
    items.setLen(0)
    var last = false
    withLock st.lock:
      while true:
        if not st.paused or st.stopping:
          collect(st, items)
        if items.len > 0:
          break
        if st.stopping:
          last = true
          break
        wait(st.cond, st.lock)
    if last:
      break
    w.write(items)
    for it in items:
      if it.data != nil:
        deallocShared(it.data)
    withLock st.lock:
      st.done = st.next
      broadcast(st.cond)
  w.closeSegment()

# The store ---------------------------------------------------------------------------

proc freeStore(st: EvidenceStore) =
  for i in 0 ..< st.cap:
    if st.slots[i].data != nil:
      deallocShared(st.slots[i].data)
  deallocShared(st.slots)
  if st.drops != nil:
    deallocShared(st.drops)
  deallocShared(st.dir)
  deallocShared(st.producer)
  deinitCond(st.cond)
  deinitLock(st.lock)
  freeShared(st)

proc openStore*(o: StoreOptions): Result[EvidenceStore, string] =
  ## Opens the store in `o.dir` and starts its writer; returns once the open
  ## is done (the newest segment checked, a new one started, the bounds
  ## applied).
  if o.producer.len < 1 or o.producer.len > MaxProducerBytes:
    return err("the producer is 1 to 128 bytes")
  if o.kid.len != KidBytes:
    return err("the kid is 16 bytes")
  if o.maxRecords < 1 or o.maxAgeDays < 1 or o.queue < 1:
    return err("max_records, max_age_days and queue are at least 1")
  if o.segmentEntries < 2 or o.segmentBytes < 1:
    return err("a segment holds at least its header and one entry")
  let st = createShared(StoreObj)
  initLock(st.lock)
  initCond(st.cond)
  st.dir = sharedCString(o.dir)
  st.producer = sharedCString(o.producer)
  for i in 0 ..< KidBytes:
    st.kid[i] = o.kid[i]
  st.maxRecords = o.maxRecords
  st.maxAgeDays = o.maxAgeDays
  st.segmentEntries = o.segmentEntries
  st.segmentBytes = o.segmentBytes
  st.clock = o.clock
  st.log = o.log
  st.cap = o.queue
  st.slots = cast[ptr UncheckedArray[Pending]](allocShared0(o.queue * sizeof(Pending)))
  try:
    createThread(st.thread, writerMain, st)
  except ResourceExhaustedError as e:
    freeStore(st)
    return err("cannot start the store's writer: " & e.msg)
  var failed = false
  withLock st.lock:
    while st.phase == phOpening:
      wait(st.cond, st.lock)
    failed = st.phase == phFailed
  if failed:
    joinThread(st.thread)
    let m = $cast[cstring](addr st.message[0])
    freeStore(st)
    return err(m)
  ok(st)

proc addDrop(st: EvidenceStore, index: uint64) =
  ## Under the lock: `index` joins the sorted drop ranges.
  var i = st.dropLen
  while i > 0 and st.drops[i - 1].first > index:
    dec i
  if i > 0 and st.drops[i - 1].first + st.drops[i - 1].count == index:
    inc st.drops[i - 1].count
    if i < st.dropLen and st.drops[i].first == index + 1:
      st.drops[i - 1].count += st.drops[i].count
      for k in i + 1 ..< st.dropLen:
        st.drops[k - 1] = st.drops[k]
      dec st.dropLen
    return
  if i < st.dropLen and st.drops[i].first == index + 1:
    st.drops[i].first = index
    inc st.drops[i].count
    return
  if st.dropLen == st.dropCap:
    let cap = max(16, st.dropCap * 2)
    let grown =
      cast[ptr UncheckedArray[DropRange]](allocShared0(cap * sizeof(DropRange)))
    for k in 0 ..< st.dropLen:
      grown[k] = st.drops[k]
    if st.drops != nil:
      deallocShared(st.drops)
    st.drops = grown
    st.dropCap = cap
  for k in countdown(st.dropLen, i + 1):
    st.drops[k] = st.drops[k - 1]
  st.drops[i] = DropRange(first: index, count: 1)
  inc st.dropLen

proc offer*(st: EvidenceStore, index: uint64, bytes: openArray[byte]) =
  ## The record retained as ring index `index`. Never blocks beyond the lock;
  ## a record that does not fit the queue, or is empty or too large, is
  ## dropped and its seq recorded as a gap.
  if st == nil:
    return
  let at =
    if st.clock != nil:
      st.clock()
    else:
      wallMs()
  var data: ptr UncheckedArray[byte] = nil
  let fits = bytes.len >= 1 and bytes.len <= MaxRecordBytes
  if fits:
    data = cast[ptr UncheckedArray[byte]](allocShared(bytes.len))
    for i, b in bytes:
      data[i] = b
  var unused = data
  withLock st.lock:
    if st.phase == phRunning and not st.stopping and index >= st.next:
      if index >= st.seen:
        st.seen = index + 1
      if not fits or index >= st.next + uint64(st.cap):
        st.addDrop(index)
        inc st.dropped
      else:
        st.slots[int(index mod uint64(st.cap))] =
          Pending(full: true, index: index, atMs: at, data: data, len: bytes.len)
        unused = nil
      signal(st.cond)
  if unused != nil:
    deallocShared(unused)

proc evidenceSink*(
    data: pointer, index: uint64, bytes: openArray[byte]
) {.nimcall, gcsafe, raises: [].} =
  ## The store as a `CallRecordSink`: `data` is the store.
  offer(cast[EvidenceStore](data), index, bytes)

proc base*(st: EvidenceStore): uint64 =
  ## The seq of ring index 0 in this open.
  st.base

proc boot*(st: EvidenceStore): uint64 =
  st.boot

proc dropped*(st: EvidenceStore): uint64 =
  withLock st.lock:
    result = st.dropped

proc written*(st: EvidenceStore): uint64 =
  ## Ring indices below this are flushed (or were lost to a failed write).
  withLock st.lock:
    result = st.done

proc stop*(st: EvidenceStore) =
  ## Writes what was offered, then ends the writer; later offers are dropped.
  ## The memory stays until `closeStore`, so a sink still called (a Runtime
  ## not destroyed) stays safe.
  if st == nil:
    return
  var join = false
  withLock st.lock:
    if st.phase == phRunning:
      st.stopping = true
      st.phase = phStopped
      join = true
      broadcast(st.cond)
  if join:
    joinThread(st.thread)

proc closeStore*(st: EvidenceStore) =
  ## `stop`, then frees the store. Only once nothing can offer to it: after
  ## the Runtime it is the sink of was destroyed.
  if st == nil:
    return
  stop(st)
  freeStore(st)

when defined(lcnTestHooks):
  proc pauseForTests*(st: EvidenceStore, paused: bool) =
    ## The writer takes nothing while paused (the overflow case).
    withLock st.lock:
      st.paused = paused
      broadcast(st.cond)

  proc waitWrittenForTests*(st: EvidenceStore, index: uint64, timeoutMs: int): bool =
    ## Whether ring indices below `index` were flushed within `timeoutMs`.
    let until = wallMs() + uint64(timeoutMs)
    while true:
      if st.written >= index:
        return true
      if wallMs() > until:
        return false
      sleep(2)

# Reading (logosctl) ------------------------------------------------------------------

type
  SegmentSummary* = object
    name*: string
    first*, endSeq*: uint64
    records*, gaps*: int
    dropped*: uint64 ## the seqs its gaps stand for
    header*: Opt[LcnEvHeader]
    damaged*: bool

  FoundRecord* = object
    segment*: string
    header*: LcnEvHeader
    record*: LcnEvRecord

proc summarize*(dir: string): Result[seq[SegmentSummary], string] =
  ## Every segment, oldest first. Read-only: logosd may be writing.
  var xs: seq[SegmentSummary]
  for (first, name) in segmentNames(dir):
    let bytes = ?readSegment(dir, name)
    let p = parseSegment(first, bytes)
    var s = SegmentSummary(
      name: name, first: first, endSeq: p.endSeq, header: p.header, damaged: p.damaged
    )
    for e in p.entries:
      if e.kind == LcnEvEntryKind.lcn_Ev_record:
        inc s.records
      elif e.kind == LcnEvEntryKind.lcn_Ev_gap:
        inc s.gaps
        s.dropped += e.arm_lcn_Ev_gap.gap.count
    xs.add(s)
  ok(xs)

proc findRecord*(dir: string, seqNo: uint64): Result[Opt[FoundRecord], string] =
  ## The record stored as `seqNo`; none when it is not retained (reaped,
  ## dropped, cut off, or never stored).
  let names = segmentNames(dir)
  var at = -1
  for i, (first, _) in names:
    if first <= seqNo:
      at = i
  if at < 0:
    return ok(Opt.none(FoundRecord))
  let (first, name) = names[at]
  let p = parseSegment(first, ?readSegment(dir, name))
  if p.header.isNone:
    return ok(Opt.none(FoundRecord))
  for e in p.entries:
    if e.kind == LcnEvEntryKind.lcn_Ev_record and e.arm_lcn_Ev_record.seq == seqNo:
      return ok(
        Opt.some(
          FoundRecord(segment: name, header: p.header.get, record: e.arm_lcn_Ev_record)
        )
      )
  ok(Opt.none(FoundRecord))

{.pop.}
