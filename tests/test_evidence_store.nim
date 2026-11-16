## logosd's call-evidence store (Tier 4b step 4b-6; DECISIONS G301, G143;
## docs/DAEMON.md §9): concurrent offers, reopening, a torn tail, the bounds,
## drops as gaps, and the export of a stored record as call evidence. The
## sink through `runtimeSetCallRecordSink`, with records a Runtime retained,
## is `test_host_authority`'s (its call-record fixture).
##
## Signing is slow (SLH-DSA-SHA2-192s): one container is signed; every other
## export case fails before a signature.

import std/[atomics, os, sequtils, strutils, times, typedthreads]
import unittest2
import
  ../src/logos_core/daemon/
    [config, daemon_config_types, evexport, evstore, session, sessioninit]
import ../src/logos_core/durable
import ../src/logos_core/runtime/evidence
from ../src/logos_core/authority/scopes import encode
import ./support/[evfixture, kitbuild]

when defined(posix):
  import std/posix

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "evstore" / kitVariant
removeDir(work)
createDir(work)

const
  Producer = "6f1c2c3e-5d0a-4b8e-9a51-0d7c1e2f3a4b"
  DayMs = 86_400_000'i64
  WaitMs = 60_000

let kid = newSeqWith(16, 0x6B'u8)

var
  dropLines: Atomic[int]
  cutLines: Atomic[int]
  clockOffset: Atomic[int64]

proc testLog(line: string) {.nimcall, gcsafe, raises: [].} =
  if "dropped" in line:
    discard dropLines.fetchAdd(1)
  if "torn" in line:
    discard cutLines.fetchAdd(1)

proc testClock(): uint64 {.nimcall, gcsafe, raises: [].} =
  let t = getTime()
  uint64(t.toUnix * 1000 + t.nanosecond div 1_000_000 + clockOffset.load)

proc options(
    dir: string,
    queue = 4096,
    maxRecords = 1_000_000,
    maxAgeDays = 30,
    segmentEntries = DefaultSegmentEntries,
    producer = Producer,
): StoreOptions =
  StoreOptions(
    dir: dir,
    producer: producer,
    kid: kid,
    maxRecords: maxRecords,
    maxAgeDays: maxAgeDays,
    queue: queue,
    segmentEntries: segmentEntries,
    clock: testClock,
    log: testLog,
  )

proc tag(i: uint64): seq[byte] =
  let s = "record " & $i
  @(s.toOpenArrayByte(0, s.high))

proc entries(dir: string): seq[LcnEvEntry] =
  ## Every entry after the headers, oldest segment first.
  for (first, name) in segmentNames(dir):
    let p = parseSegment(first, readSegment(dir, name).tryGet)
    check p.header.isSome
    check not p.damaged
    result.add(p.entries)

func describe(e: LcnEvEntry): string =
  case e.kind
  of LcnEvEntryKind.lcn_Ev_record:
    "r" & $e.arm_lcn_Ev_record.seq
  of LcnEvEntryKind.lcn_Ev_gap:
    "g" & $e.arm_lcn_Ev_gap.gap.first & "+" & $e.arm_lcn_Ev_gap.gap.count
  of LcnEvEntryKind.lcn_Ev_header:
    "h"

when defined(posix):
  proc modeOf(path: string): int =
    var st: Stat
    check stat(cstring(path), st) == 0
    int(st.st_mode.cint and 0o777)

# Concurrent offers --------------------------------------------------------------------

const
  Offerers = 8
  PerOfferer = 200

var nextIndex: Atomic[int]

proc offerer(st: EvidenceStore) {.thread.} =
  for _ in 0 ..< PerOfferer:
    let i = uint64(nextIndex.fetchAdd(1))
    st.offer(i, tag(i))

suite "daemon.evstore: the call-evidence store (G301; DAEMON.md §9)":
  test "8 threads offering at once: every seq stored once, in order, across rotated segments":
    let dir = work / "threads"
    let st = openStore(options(dir, segmentEntries = 101)).tryGet
    check st.base == 0
    check st.boot == 1
    var ts: array[Offerers, Thread[EvidenceStore]]
    for t in ts.mitems:
      createThread(t, offerer, st)
    for t in ts.mitems:
      joinThread(t)
    let n = uint64(Offerers * PerOfferer)
    check st.waitWrittenForTests(n, WaitMs)
    check st.dropped == 0
    closeStore(st)
    let es = entries(dir)
    check es.len == int(n)
    check es.allIt(it.kind == LcnEvEntryKind.lcn_Ev_record)
    for i, e in es:
      check e.arm_lcn_Ev_record.seq == uint64(i)
      check e.arm_lcn_Ev_record.record == tag(uint64(i))
    let names = segmentNames(dir)
    check names.len == int(n div 100)
    check names.mapIt(it[0]) == toSeq(0 ..< names.len).mapIt(uint64(it * 100))
    when defined(posix):
      check modeOf(dir) == 0o700
      for (_, name) in names:
        check modeOf(dir / name) == 0o600

  test "a reopened store continues the seqs, cutting off a torn tail; an open that stores nothing leaves one header-only segment":
    let dir = work / "reopen"
    var st = openStore(options(dir)).tryGet
    for i in 0'u64 ..< 10:
      st.offer(i, tag(i))
    closeStore(st)
    let names = segmentNames(dir)
    check names.len == 1
    let path = dir / names[0][1]
    let size = getFileSize(path)
    # A torn entry: a length that promises more bytes than follow.
    var f: File
    check open(f, path, fmAppend)
    f.write("\x00\x00\x01\x00abc")
    f.close()
    check getFileSize(path) == size + 7
    cutLines.store(0)
    st = openStore(options(dir)).tryGet
    check st.base == 10
    check st.boot == 2
    check getFileSize(path) == size
    check cutLines.load == 1
    for i in 0'u64 ..< 3:
      st.offer(i, tag(100 + i))
    closeStore(st)
    check segmentNames(dir).mapIt(it[0]) == @[0'u64, 10]
    let es = entries(dir)
    check es.mapIt(it.arm_lcn_Ev_record.seq) == toSeq(0'u64 ..< 13'u64)
    check es[10 .. 12].mapIt(it.arm_lcn_Ev_record.record) ==
      @[tag(100), tag(101), tag(102)]
    for boot in 3'u64 .. 4:
      st = openStore(options(dir)).tryGet
      check st.base == 13
      check st.boot == boot
      closeStore(st)
    check segmentNames(dir).mapIt(it[0]) == @[0'u64, 10, 13]
    let last = parseSegment(13, readSegment(dir, segmentName(13)).tryGet)
    check last.header.isSome
    check last.header.get.boot == 4
    check last.header.get.producer == Producer
    check last.header.get.kid == kid
    check last.entries.len == 0

  test "[IMPL-DECISION G143] bounds: whole segments are reaped by count and, by an injected clock, by age":
    let dir = work / "count"
    var st = openStore(options(dir, maxRecords = 30, segmentEntries = 11)).tryGet
    for i in 0'u64 ..< 100:
      st.offer(i, tag(i))
    check st.waitWrittenForTests(100, WaitMs)
    closeStore(st)
    # Rotating to seq 90 reaped every segment more than 30 seqs back.
    check segmentNames(dir).mapIt(it[0]) == @[60'u64, 70, 80, 90]
    check findRecord(dir, 59).tryGet.isNone
    check findRecord(dir, 60).tryGet.isSome
    check findRecord(dir, 99).tryGet.get.record.record == tag(99)

    let aged = work / "age"
    clockOffset.store(0)
    st = openStore(options(aged)).tryGet
    for i in 0'u64 ..< 5:
      st.offer(i, tag(i))
    closeStore(st)
    clockOffset.store(29 * DayMs)
    closeStore(openStore(options(aged)).tryGet)
    check segmentNames(aged).mapIt(it[0]) == @[0'u64, 5]
    clockOffset.store(31 * DayMs)
    closeStore(openStore(options(aged)).tryGet)
    clockOffset.store(0)
    check segmentNames(aged).mapIt(it[0]) == @[5'u64]
    check findRecord(aged, 0).tryGet.isNone

  test "overflow: a queue of 4 with the writer paused drops what does not fit; the gaps name exactly the dropped seqs, and the drops are logged":
    let dir = work / "overflow"
    let st = openStore(options(dir, queue = 4)).tryGet
    dropLines.store(0)
    st.pauseForTests(true)
    for i in 0'u64 ..< 10:
      st.offer(i, tag(i))
    check st.dropped == 6
    st.pauseForTests(false)
    check st.waitWrittenForTests(10, WaitMs)
    st.offer(10, tag(10))
    st.offer(11, tag(11))
    check st.waitWrittenForTests(12, WaitMs)
    st.pauseForTests(true)
    # Out of order: 17 is dropped before 16, and 13 arrives after 14 and 15.
    for i in [12'u64, 14, 15, 17, 16, 13]:
      st.offer(i, tag(i))
    st.offer(18, @[]) # an empty record is dropped too
    check st.dropped == 9
    st.pauseForTests(false)
    check st.waitWrittenForTests(19, WaitMs)
    closeStore(st)
    check entries(dir).mapIt(describe(it)) ==
      @[
        "r0", "r1", "r2", "r3", "g4+6", "r10", "r11", "r12", "r13", "r14", "r15",
        "g16+3",
      ]
    check dropLines.load >= 2

  test "[CAP-0416] [CAP-0417] export: the container verifies under the binding's key with the Runtime as producer, holds the stored record byte for byte and no proof; a dropped, reaped or unknown seq is not retained; a segment another Runtime wrote is refused":
    let s = Session(dir: work / "export" / "s")
    let made = initSession(s, InitOptions()).tryGet
    var (dc, _) = readDaemonConfig(s).tryGet
    dc.call_audit = Opt.some(
      LcnDcCallAudit(
        evidence: Opt.some(
          LcnAppEvidenceKey(
            kid: made.key.binding.kid, secret_key_file: made.key.keyFile
          )
        ),
        store: Opt.some(LcnDcEvidenceStore()),
      )
    )
    check writeAtomic(s.dir, DaemonConfigName, dc.encode.tryGet).isOk
    let records = (0 ..< 3).mapIt(
      meterCallRecordBytes(made.runtimeId, "d-" & $it, uint64(1_000 + it))
    )
    var o = options(s.evidenceDir, producer = made.runtimeId)
    o.kid = made.key.binding.kid
    var st = openStore(o).tryGet
    st.offer(0, records[0])
    st.offer(1, records[1])
    st.offer(2, @[]) # dropped: seq 2 is a gap
    st.offer(3, records[2])
    closeStore(st)

    let container = exportStored(s, 1)
    check container.isOk
    var ctx = newEvidenceContext()
    check ctx.accept(made.key.binding.kid, made.runtimeId, made.key.binding.public_key).isOk
    let v = verifyEvidence(container.get, ctx)
    check v.isOk
    check v.get.producer == made.runtimeId
    check encode(v.get.record).tryGet == records[1]
    check v.get.record.arm_Call_success.decision_id == "d-1"
    check v.get.proofs.isNone

    for gone in [2'u64, 4, 1_000]:
      let r = exportStored(s, gone)
      check r.isErr
      check r.error.notRetained
      check ("seq " & $gone & " is not retained") in r.error.message
    # Reaped: an open bounded to one seq drops every older segment.
    o.maxRecords = 1
    closeStore(openStore(o).tryGet)
    let reaped = exportStored(s, 0)
    check reaped.isErr
    check reaped.error.notRetained
    # A segment written for another Runtime.
    o.maxRecords = 1_000_000
    o.producer = "another-runtime"
    st = openStore(o).tryGet
    let next = st.base
    st.offer(0, meterCallRecordBytes("another-runtime", "d-x", 9))
    closeStore(st)
    let other = exportStored(s, next)
    check other.isErr
    check not other.error.notRetained
    check (
      "was written by Runtime another-runtime; the current evidence key belongs to Runtime " &
      made.runtimeId
    ) in other.error.message
