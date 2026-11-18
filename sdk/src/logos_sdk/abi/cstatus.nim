## INTERFACE §5.1, §5.2: the C-side status and response buffers every native
## binding returns: a failure status whose message and detail live in the
## calling thread's storage, and responses in `malloc` buffers the caller
## releases once. Shared by the Runtime's bindings (`runtime/callside.nim`) and
## a Module Host's (`host/`), so both sides build statuses the same way
## [DECISIONS G266].

{.push raises: [], gcsafe.}

import results
import ./[checks, types]
import ../iface/outcome

export outcome

proc cMalloc*(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc cFree*(p: pointer) {.importc: "free", header: "<stdlib.h>".}

template bindingEnter*() =
  ## [IMPL] As the module kit's entries: a thread this Nim runtime did not
  ## create (a module's own) registers before its first allocation.
  setupForeignThreadGc()
  enterThread()
  when not defined(gcDestructors):
    var stackBottom {.volatile, noinit.}: pointer
    nimGC_setStackBottom(addr stackBottom)

var
  statusMessage {.threadvar.}: array[MaxMessageBytes + 1, char]
  statusDetail {.threadvar.}: array[MaxDetailBytes, uint8]

func clip*(m: string): string =
  ## At most `MaxMessageBytes` bytes, cut before a continuation byte, no NUL.
  var s = m
  for c in s.mitems:
    if c == '\0':
      c = ' '
  if s.len <= MaxMessageBytes:
    return s
  var n = MaxMessageBytes
  while n > 0 and (uint8(s[n]) and 0xC0'u8) == 0x80'u8:
    dec n
  s.setLen(n) # in place: the cut tail stays in the capacity a wipe zeroes
  s

proc status*(f: InvocationFailure): LogosResult =
  ## [SPEC INTERFACE §5.1, §5.2] A failure status whose message and detail live
  ## in this thread's storage until the next binding operation on it. That
  ## storage is zeroed before each status is written, so no earlier message
  ## outlives its turn, and the clipped copy of the message is zeroed once
  ## stored [DECISIONS G276].
  wipeObject(statusMessage)
  wipeObject(statusDetail)
  var r = LogosResult(code: CErrorCode(ord(f.code)))
  if f.message.isSome:
    var m = clip(f.message.get)
    for i, c in m:
      statusMessage[i] = c
    statusMessage[m.len] = '\0'
    wipe(m)
    r.message = cast[cstring](addr statusMessage[0])
  if f.detail.isSome and f.detail.get.len <= MaxDetailBytes and f.code == ecInvalidParams:
    for i, b in f.detail.get:
      statusDetail[i] = b
    r.detail = cast[ptr UncheckedArray[uint8]](addr statusDetail[0])
    r.detailLen = csize_t(f.detail.get.len)
  r

proc status*(code: ErrorCode, message: string): LogosResult =
  status(InvocationFailure(code: code, message: Opt.some(message)))

func failureOf*(f: AbiFailure): InvocationFailure =
  ## A producer's own valid failure, forwarded as it gave it; any other
  ## rejection as MODULE_ERROR without its diagnostics (I66).
  if f.reason.len == 0:
    InvocationFailure(code: f.code, message: f.message, detail: f.detail)
  else:
    InvocationFailure(code: f.code)

proc takeFailure*(c: var AbiCheck): InvocationFailure =
  ## `failureOf` of a failed check, whose own copy of the producer's
  ## diagnostics is then zeroed [DECISIONS G276, G278].
  result = failureOf(c.eResultPrivate)
  wipe(c.eResultPrivate)

func failure*(code: ErrorCode, message: string): InvocationFailure =
  InvocationFailure(code: code, message: Opt.some(message))

proc status*(f: AbiFailure): LogosResult =
  status(failureOf(f))

const GivenHeader = 16
  ## [IMPL] Before a buffer `give` hands out: its size, so `releaseGiven` zeroes
  ## all of it whatever length the caller passes back; 16 bytes keep malloc's
  ## alignment for the response.

proc give*(
    bytes: openArray[byte], outBuf: ptr ptr UncheckedArray[uint8], outLen: ptr csize_t
): LogosResult =
  ## A success: the response in a C buffer the caller releases once, through
  ## the binding's release operation (`releaseGiven`).
  let n = max(bytes.len, 1)
  let base = cast[ptr UncheckedArray[uint8]](cMalloc(csize_t(n + GivenHeader)))
  if base == nil:
    return status(ecModule, "out of memory")
  cast[ptr int](base)[] = n
  let p = cast[ptr UncheckedArray[uint8]](addr base[GivenHeader])
  for i, b in bytes:
    p[i] = b
  outBuf[] = p
  outLen[] = csize_t(bytes.len)
  LogosResult()

proc releaseGiven*(p: pointer) =
  ## A buffer from `give`: zeroed to its full size, then freed [DECISIONS G276].
  if p == nil:
    return
  let base = cast[pointer](cast[uint](p) - GivenHeader)
  secureZero(base, cast[ptr int](base)[] + GivenHeader)
  cFree(base)

func view*(p: ptr UncheckedArray[uint8], len: csize_t): seq[byte] =
  result = newSeq[byte](int(len))
  for i in 0 ..< int(len):
    result[i] = p[i]
