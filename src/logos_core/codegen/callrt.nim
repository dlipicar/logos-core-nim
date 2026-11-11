## Runtime support for the module kit's typed provider functions [IMPL]
## (INTERFACE §2.4, §2.7, §2.7.1).
##
## A typed call (`logos_<module-C>_CALL_<namespace>_<Method>`) converts its C
## inputs to the request's CBOR value and validates it exactly as
## `_MODULE_dispatch` does. Once the handler's response has been checked against
## the response schema, the call writes it into C outputs. lcn-gen generates
## the converters between the two (`cmirror`): Nim objects with the C layout of
## the §2.3 declarations ("mirrors"), filled from and read into checked CBOR
## values.
##
## Response storage comes from one `CallArena` per call:
##
## - Blocks come from the C allocator and are chained through their first word.
##   Each block's 16-byte header keeps the payload aligned for every member
##   type.
## - On success the arena becomes the response owner (§2.7.1). Its state is the
##   newest block and its release function frees the chain. That needs no Nim
##   runtime, so a caller may clear owners on any thread, concurrently.
## - A response that allocated nothing gets the empty owner.
## - On failure the call releases the arena before it returns, and it leaves
##   the owner and every output as the caller initialized them (§2.4). Outputs
##   are first written to locals and copied only on success.
##
## Empty byte strings and lists [IMPL]:
##
## - An empty output points to static storage, never null: every reading of
##   §2.3 accepts a non-null pointer with zero length.
## - An input with zero length or count may have any pointer, null included.
##
## Every other null input pointer is INVALID_PARAMS. That includes a text, a
## struct or array passed by pointer, a byte string or list with a nonzero
## length, and a required recursive pointer (§2.3).
##
## Stack [IMPL]: the converters recurse once per nesting level, as the Nim
## codecs do, so a call at the payload depth limit (`MaxConvertDepth`) needs up
## to 1 MiB of stack on the calling thread (I72).

{.push raises: [], gcsafe.}

import std/atomics
import results
import ../cbor
import ../abi/types

export results, cbor, types

proc cCalloc(n, size: csize_t): pointer {.importc: "calloc", header: "<stdlib.h>".}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}

const
  MaxConvertDepth* = DefaultMaxDepth
    ## [SPEC INTERFACE §4.5.1] Converter nesting at most the payload depth
    ## limit: each level is at least one CBOR container, so a deeper C value
    ## could only encode a payload the validator rejects. The bound also keeps a
    ## cyclic C input from recursing without end.
  MaxCount* = high(int32)
    ## [IMPL] The largest byte-string length or list count a typed input may
    ## state.
  BlockHeader = 16

type CallArena* = object ## The storage behind one typed response.
  head: pointer ## the newest block; each block's first word links the previous

var
  liveBlocks: Atomic[int]
  failCountdown {.threadvar.}: int
  emptyStorage {.align(16).}: array[16, uint8]
    ## what empty byte strings and lists point to; never written

proc arenaBlocks*(): int =
  ## Blocks allocated and not yet released, across all threads (tests).
  liveBlocks.load

proc failArenaAllocation*(n: int) =
  ## Test hook: the `n`th arena allocation from now on this thread fails as if
  ## out of memory; 0 disables it.
  failCountdown = n

proc alloc*(a: var CallArena, size: int): Result[pointer, string] =
  ## `size` zeroed bytes owned by the arena.
  if failCountdown > 0:
    dec failCountdown
    if failCountdown == 0:
      return err("out of memory for the response (test hook)")
  if size < 0 or size > high(int) - BlockHeader:
    return err("a response allocation of " & $size & " bytes")
  let p = cCalloc(1, csize_t(BlockHeader + size))
  if p == nil:
    return err("out of memory for the response")
  cast[ptr pointer](p)[] = a.head
  a.head = p
  discard liveBlocks.fetchAdd(1)
  ok(cast[pointer](cast[uint](p) + BlockHeader))

proc releaseBlocks(state: pointer) {.cdecl, gcsafe, raises: [].} =
  ## [SPEC INTERFACE §2.7.1] The owner's release: the C allocator only, so any
  ## thread may call it, and distinct owners concurrently.
  var p = state
  while p != nil:
    let next = cast[ptr pointer](p)[]
    cFree(p)
    discard liveBlocks.fetchSub(1)
    p = next

proc release*(a: var CallArena) =
  ## Frees everything the arena holds (a failed call).
  releaseBlocks(a.head)
  a.head = nil

proc owner*(a: var CallArena): LogosResponseOwner =
  ## [SPEC INTERFACE §2.4, §2.7.1] Transfers the arena to a response owner: the
  ## empty owner when it holds nothing.
  if a.head == nil:
    return LogosResponseOwner()
  result = LogosResponseOwner(state: a.head, release: releaseBlocks)
  a.head = nil

# Outputs -------------------------------------------------------------------------

proc empty[T](): ptr UncheckedArray[T] =
  cast[ptr UncheckedArray[T]](addr emptyStorage)

proc text*(a: var CallArena, s: string): Result[cstring, string] =
  ## [SPEC INTERFACE §2.2] A NUL-terminated copy. A text containing U+0000 has
  ## no canonical C value.
  if '\0' in s:
    return err("a text value contains U+0000")
  let p = ?a.alloc(s.len + 1)
  if s.len > 0:
    copyMem(p, unsafeAddr s[0], s.len)
  ok(cast[cstring](p))

proc bytes*(
    a: var CallArena,
    b: openArray[byte],
    data: var ptr UncheckedArray[uint8],
    len: var csize_t,
): Result[void, string] =
  ## [SPEC INTERFACE §2.2, §2.3] An unbounded or ranged byte string's pointer
  ## and length.
  if b.len == 0:
    data = empty[uint8]()
    len = 0
    return ok()
  let p = ?a.alloc(b.len)
  copyMem(p, unsafeAddr b[0], b.len)
  data = cast[ptr UncheckedArray[uint8]](p)
  len = csize_t(b.len)
  ok()

proc fill*[N: static int](
    b: openArray[byte], dst: var array[N, uint8]
): Result[void, string] =
  ## [SPEC INTERFACE §2.2] A positive exact-size byte string.
  if b.len != N:
    return err("a byte string of " & $b.len & " bytes for " & $N)
  for i in 0 ..< N:
    dst[i] = b[i]
  ok()

proc list*(
    a: var CallArena, T: typedesc, n: int
): Result[ptr UncheckedArray[T], string] =
  ## [SPEC INTERFACE §2.3] Zeroed storage for `n` list elements.
  if n == 0:
    return ok(empty[T]())
  if n > high(int) div sizeof(T):
    return err("a list of " & $n & " elements")
  ok(cast[ptr UncheckedArray[T]](?a.alloc(n * sizeof(T))))

proc boxed*(a: var CallArena, T: typedesc): Result[ptr T, string] =
  ## [SPEC INTERFACE §2.3] Zeroed storage for a recursive pointer's target.
  ok(cast[ptr T](?a.alloc(sizeof(T))))

# Inputs --------------------------------------------------------------------------

proc depthCheck*(depth: int): Result[void, string] =
  if depth > MaxConvertDepth:
    return err("a value nested deeper than " & $MaxConvertDepth & " levels")
  ok()

proc inText*(p: cstring): Result[CborValue, string] =
  ## [SPEC INTERFACE §3.1] An accepted text argument: NUL-terminated. Its UTF-8
  ## is checked with the rest of the request.
  if p == nil:
    return err("a null text pointer")
  ok(cbor($p))

proc counted*(p: pointer, n: csize_t): Result[int, string] =
  ## A byte string's length or a list's count, with its pointer.
  if n > csize_t(MaxCount):
    return err("a length or count of " & $n)
  if n > 0 and p == nil:
    return err("a null pointer with a nonzero length or count")
  ok(int(n))

proc inBytes*(p: ptr UncheckedArray[uint8], n: csize_t): Result[CborValue, string] =
  ## [SPEC INTERFACE §2.2] An unbounded or ranged byte string.
  let len = ?counted(p, n)
  if len == 0:
    return ok(cbor(newSeq[byte]()))
  ok(cbor(p.toOpenArray(0, len - 1)))

proc present*[T](p: ptr T): Result[ptr T, string] =
  ## A struct, array or recursive target passed by pointer.
  if p == nil:
    return err("a null pointer")
  ok(p)
