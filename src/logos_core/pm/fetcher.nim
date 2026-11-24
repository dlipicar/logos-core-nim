## One object's retrieval over an `lcn.storage_fetch` route, as a state
## machine without I/O (Tier 5 step 5-3b; DECISIONS G402;
## docs/PACKAGE-MANAGER.md §4; STORAGE-FETCH §3, §4; PACKAGE MANAGER l.854-858).
##
## The engine (`engine.nim`) turns each `FetchStep` into a call, a wait or a
## timer, and feeds the answer back. The steps:
## 1. `stat_object`; a size over the bound is refused before any read. An
##    `unavailable` answer is not retried: the provider spent its whole lookup
##    bound on that call (planning, 2026-11-21).
## 2. `read_object` in 1 MiB steps, one after another, the BLAKE3-256 digest
##    computed while reading.
## 3. `unavailable` from a `read_object` after a successful `stat_object`: the
##    same offset again after a back-off, at most three times in a row. The
##    bytes a locator names are fixed (STORAGE-FETCH §3), so a read resumes
##    from its offset.
## 4. `not-ready`, or a route that is no longer usable: the same call again once
##    the binding is usable, the wait bounded by `read_deadline_ms`.
## 5. Anything else ends the retrieval as unavailable: `invalid-locator`,
##    `out-of-range`, `invalid-length`, an invocation error, a call past its
##    deadline, or data other than `min(length, size - offset)` bytes.
##
## The bytes are untrusted until verified, by the caller: the catalog by its
## pinned digest, an archive by `openLgx` (PM l.389, l.397, l.443-444). The
## provider's `detail` is foreign text, quoted when logged (BCP l.557-558).
##
## **Spooled** (5-5-3; G446, G447): an archive's retrieval keeps no bytes. Each
## `read_object` answer is taken as it arrives (`takeChunk`) and the worker
## appends it to the archive's spool file and digests it; `skDone` then carries
## neither bytes nor a digest. The catalog's retrieval keeps its bytes.

{.push raises: [].}

import std/strutils
import results
import logos_sdk/crypto/blake3

export results, blake3

const
  ReadStep* = 1024 * 1024 ## [SPEC STORAGE-FETCH §4] `read_object`'s largest length
  MaxReadRetries* = 3 ## [IMPL; G402] `unavailable` from `read_object`, in a row
  ReadRetryBackoffMs* = [1_000'u32, 2_000, 4_000]
    ## [IMPL; G402] the wait before each of those retries

type
  FailureCode* = enum
    ## [SPEC STORAGE-FETCH §4] `lcn.storage_fetch.failure`'s codes.
    fcInvalidLength = "invalid-length"
    fcInvalidLocator = "invalid-locator"
    fcNotReady = "not-ready"
    fcUnavailable = "unavailable"
    fcOutOfRange = "out-of-range"

  AnswerKind* = enum
    akValue ## the call's success arm
    akFailure ## the contract's failure arm
    akRouteLost
      ## the call failed because the route is no longer usable (R §7.5, a
      ## terminal route, or a hosted route's transport failure)
    akError ## any other invocation error, a deadline among them

  Answer* = object ## One call's answer, as the engine's caller saw it.
    case kind*: AnswerKind
    of akValue:
      size*: uint64 ## `stat_object`'s
      data*: seq[byte] ## `read_object`'s
    of akFailure:
      code*: FailureCode
      detail*: string
    of akRouteLost, akError:
      error*: string

  CallKind* = enum
    ckStat
    ckRead

  StepKind* = enum
    skCall ## issue `call`
    skWait ## wait until the binding is usable, then issue `call` (step 4)
    skBackoff ## wait `ms`, then issue `call` (step 3)
    skDone ## the object's bytes and digest
    skUnavailable ## the retrieval ended; `reason` says why

  Call* = object
    kind*: CallKind
    offset*: uint64
    length*: uint32

  FetchStep* = object
    case kind*: StepKind
    of skCall, skWait, skBackoff:
      call*: Call
      ms*: uint32 ## the wait's bound or the back-off
    of skDone:
      bytes*: seq[byte]
      digest*: Blake3Digest
    of skUnavailable:
      reason*: string

  Retrieval* = object
    ## One object's retrieval. `maxBytes` is the bound its use sets
    ## (`catalog_bytes` or `archive_bytes`).
    locator*: seq[byte]
    maxBytes*: int64
    deadlineMs*: uint32
    size: uint64
    sized: bool
    offset: uint64
    retries: int
    hasher: ref Blake3Hasher
      ## not spooled. Behind a reference: refc copies a `Retrieval` through its type
      ## information, which holds none of the `importc` hasher's bytes, so a copied value
      ## lost its state (upstream ISSUES 195, the second shape)
    bytes: seq[byte]
    pending: Call
    finished: bool
    spooled: bool
    chunk: string
      ## spooled: the last `read_object` answer, until taken; a `string`, which refc's
      ## channel copies in one block (`jobs.nim`)

func quoted*(detail: string): string =
  ## A provider's `detail`, on one line, as foreign text.
  detail.escape

proc initRetrieval*(
    locator: openArray[byte], maxBytes: int64, deadlineMs: uint32, spooled = false
): Retrieval =
  ## `spooled`: each piece is handed on (`takeChunk`), none kept (G447).
  result = Retrieval(
    locator: @locator, maxBytes: maxBytes, deadlineMs: deadlineMs, spooled: spooled
  )
  if not spooled:
    result.hasher = new Blake3Hasher
    result.hasher[].init()

func finished*(f: Retrieval): bool =
  f.finished

func pending*(f: Retrieval): Call =
  ## The call now outstanding, waited for or backed off.
  f.pending

func received*(f: Retrieval): uint64 =
  f.offset

func spooled*(f: Retrieval): bool =
  f.spooled

func size*(f: Retrieval): Opt[uint64] =
  ## The object's size, once `stat_object` answered.
  if f.sized:
    Opt.some(f.size)
  else:
    Opt.none(uint64)

func hasChunk*(f: Retrieval): bool =
  f.chunk.len > 0

proc takeChunk*(f: var Retrieval): string =
  ## [G447] Spooled: the piece the last `read_object` answered, for the spool file.
  move f.chunk

proc unavailable(f: var Retrieval, reason: string): FetchStep =
  f.finished = true
  f.bytes.setLen(0)
  if f.hasher != nil:
    f.hasher[].wipe()
  FetchStep(kind: skUnavailable, reason: reason)

proc nextRead(f: var Retrieval): FetchStep =
  if f.offset == f.size:
    f.finished = true
    if f.spooled:
      return FetchStep(kind: skDone) # the worker holds the bytes and their digest
    let digest = f.hasher[].finish()
    f.hasher[].wipe()
    return FetchStep(kind: skDone, bytes: move f.bytes, digest: digest)
  let left = f.size - f.offset
  f.pending =
    Call(kind: ckRead, offset: f.offset, length: uint32(min(uint64(ReadStep), left)))
  FetchStep(kind: skCall, call: f.pending)

proc abandon*(f: var Retrieval, reason: string): FetchStep =
  ## Ends the retrieval as unavailable, whatever is outstanding: its spool file
  ## could not be written (G446).
  doAssert not f.finished
  f.chunk.setLen(0)
  f.unavailable(reason)

proc start*(f: var Retrieval): FetchStep =
  ## Step 1: the object's size.
  f.pending = Call(kind: ckStat)
  FetchStep(kind: skCall, call: f.pending)

func what(c: Call): string =
  case c.kind
  of ckStat:
    "stat_object"
  of ckRead:
    "read_object at offset " & $c.offset

proc onAnswer*(f: var Retrieval, a: Answer): FetchStep =
  ## The answer to `pending`.
  doAssert not f.finished
  let c = f.pending
  case a.kind
  of akRouteLost:
    return FetchStep(kind: skWait, call: c, ms: f.deadlineMs)
  of akError:
    return f.unavailable(c.what & " failed: " & a.error)
  of akFailure:
    case a.code
    of fcNotReady:
      return FetchStep(kind: skWait, call: c, ms: f.deadlineMs)
    of fcUnavailable:
      if c.kind == ckStat:
        return f.unavailable("stat_object answered unavailable")
      if f.retries >= MaxReadRetries:
        return f.unavailable(
          c.what & " answered unavailable " & $(MaxReadRetries + 1) & " times in a row"
        )
      let ms = ReadRetryBackoffMs[f.retries]
      inc f.retries
      return FetchStep(kind: skBackoff, call: c, ms: ms)
    of fcInvalidLength, fcInvalidLocator, fcOutOfRange:
      var reason = c.what & " answered " & $a.code
      if a.detail.len > 0:
        reason.add(": " & a.detail.quoted)
      return f.unavailable(reason)
  of akValue:
    case c.kind
    of ckStat:
      if a.size > uint64(f.maxBytes):
        return f.unavailable(
          "the object is " & $a.size & " bytes, more than the bound of " & $f.maxBytes
        )
      f.size = a.size
      f.sized = true
      if not f.spooled:
        f.bytes = newSeqOfCap[byte](int(a.size))
      return f.nextRead()
    of ckRead:
      if uint64(a.data.len) != uint64(c.length):
        return f.unavailable(
          c.what & " answered " & $a.data.len & " bytes, not " & $c.length
        )
      f.retries = 0
      if f.spooled:
        f.chunk = newString(a.data.len)
        copyMem(addr f.chunk[0], unsafeAddr a.data[0], a.data.len)
      else:
        f.hasher[].update(a.data)
        f.bytes.add(a.data)
      f.offset += uint64(a.data.len)
      return f.nextRead()

proc onWaitExpired*(f: var Retrieval): FetchStep =
  ## A wait of step 4 reached its bound.
  doAssert not f.finished
  f.unavailable(
    f.pending.what & ": the binding was not usable within " & $f.deadlineMs & " ms"
  )

proc onDeadline*(f: var Retrieval): FetchStep =
  ## The outstanding call passed its deadline (step 5).
  doAssert not f.finished
  f.unavailable(f.pending.what & " passed its deadline of " & $f.deadlineMs & " ms")

proc resume*(f: var Retrieval): FetchStep =
  ## After a wait or a back-off: the same call again.
  doAssert not f.finished
  FetchStep(kind: skCall, call: f.pending)

{.pop.}
