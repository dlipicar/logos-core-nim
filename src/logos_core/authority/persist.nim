## The Capability Authority's state files [IMPL] (DECISIONS I84; on step 6's
## `durable.nim`, I82).
##
## The CA's state lives in its own state assignment, not in the Runtime's
## snapshot: grants and audit are the CA instance's state, the Runtime thread
## alone writes its snapshot, and the CA never waits on that thread. Every
## file is one deterministic-CBOR value of `state.cddl`:
##
## | File | Content | Written |
## |---|---|---|
## | `lock` | the exclusive lock (a second CA on the directory fails, G111 (a)) | at open |
## | `meta.cbor` | format, runtime id, CA contract root, policy digest/revision/time, audit floor, the policy-change records | at open, at a policy change, when a segment goes |
## | `grants/<id>.cbor` | the grant, its target's facts, its issue, revoke and expiry records | before each transition takes effect |
## | `audit/<16 hex>.cbor` | up to `segmentRecords` other records from the named sequence number | behind, within a second |
##
## A failed write is reported to the caller, which fails closed (`core.nim`).
## `failNext` and `failAll` inject failures for tests.

{.push raises: [].}

import std/[os, strutils]
import results
import ../durable
import ./state_types

export results, state_types

const
  MetaName* = "meta.cbor"
  GrantsDir* = "grants"
  AuditDir* = "audit"
  StateFormat* = "logos-core-nim.authority-state.v1"
  MaxMetaBytes = 64 * 1024 * 1024
  MaxGrantBytes = 64 * 1024 * 1024
  MaxSegmentBytes = 512 * 1024 * 1024

type
  Store* = object
    dir*: string
    lock: DurableLock
    failNext*: int ## tests: the next `failNext` writes or removals fail
    failAll*: bool ## tests: every write or removal fails while set

  Loaded* = object
    meta*: Opt[LcnAsMeta]
    grants*: seq[LcnAsGrant]
    segments*: seq[LcnAsSegment]

func segmentName*(first: uint64): string =
  const digits = "0123456789abcdef"
  result = newString(16)
  var x = first
  for i in countdown(15, 0):
    result[i] = digits[int(x and 0xF)]
    x = x shr 4
  result.add ".cbor"

proc openStore*(dir: string): Result[Store, string] =
  ## Creates the directories (0700), takes the lock and removes leftover
  ## temporary files.
  ?ensurePrivateDir(dir)
  var s = Store(dir: dir)
  s.lock = ?acquire(dir)
  for sub in [GrantsDir, AuditDir]:
    let r = ensurePrivateDir(dir / sub)
    if r.isErr:
      s.lock.release()
      return err(r.error)
  for d in [dir, dir / GrantsDir, dir / AuditDir]:
    for name in fileNames(d):
      if isTmp(name):
        discard removeIfPresent(d / name)
  ok(s)

proc close*(s: var Store) =
  if s.lock.isHeld:
    s.lock.release()

proc injected(s: var Store): bool =
  if s.failAll:
    return true
  if s.failNext > 0:
    dec s.failNext
    return true
  false

proc write(
    s: var Store, sub, name: string, data: openArray[byte]
): Result[void, string] =
  if s.injected:
    return err("injected write failure")
  writeAtomic(
    if sub.len == 0:
      s.dir
    else:
      s.dir / sub,
    name,
    data,
  )

proc remove(s: var Store, sub, name: string): Result[void, string] =
  if s.injected:
    return err("injected removal failure")
  removeDurably(s.dir / sub, name)

proc writeMeta*(s: var Store, m: LcnAsMeta): Result[void, string] =
  s.write("", MetaName, ?encode(m))

proc writeGrant*(s: var Store, id: string, g: LcnAsGrant): Result[void, string] =
  s.write(GrantsDir, id & ".cbor", ?encode(g))

proc removeGrant*(s: var Store, id: string): Result[void, string] =
  s.remove(GrantsDir, id & ".cbor")

proc writeSegment*(s: var Store, seg: LcnAsSegment): Result[void, string] =
  s.write(AuditDir, segmentName(seg.first), ?encode(seg))

proc removeSegment*(s: var Store, first: uint64): Result[void, string] =
  s.remove(AuditDir, segmentName(first))

proc load*(s: Store): Result[Loaded, string] =
  ## Every file, decoded. Anything that does not decode fails the load: the
  ## CA then does not open, and nothing is changed.
  var r: Loaded
  let meta = ?readBounded(s.dir / MetaName, MaxMetaBytes)
  if meta.isSome:
    let m = decode(LcnAsMeta, meta.get).valueOr:
      return err(MetaName & ": " & error)
    r.meta = Opt.some(m)
  for name in fileNames(s.dir / GrantsDir):
    if not name.endsWith(".cbor"):
      return err(GrantsDir & "/" & name & ": an unexpected file")
    let data = ?readBounded(s.dir / GrantsDir / name, MaxGrantBytes)
    if data.isSome:
      let g = decode(LcnAsGrant, data.get).valueOr:
        return err(GrantsDir & "/" & name & ": " & error)
      r.grants.add g
  for name in fileNames(s.dir / AuditDir):
    if not name.endsWith(".cbor"):
      return err(AuditDir & "/" & name & ": an unexpected file")
    let data = ?readBounded(s.dir / AuditDir / name, MaxSegmentBytes)
    if data.isSome:
      let seg = decode(LcnAsSegment, data.get).valueOr:
        return err(AuditDir & "/" & name & ": " & error)
      if segmentName(seg.first) != name:
        return err(AuditDir & "/" & name & ": does not hold its named records")
      r.segments.add seg
  ok(r)
