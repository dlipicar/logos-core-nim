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
  s[0 ..< n]

proc status*(f: InvocationFailure): LogosResult =
  ## [SPEC INTERFACE §5.1, §5.2] A failure status whose message and detail live
  ## in this thread's storage until the next binding operation on it.
  var r = LogosResult(code: CErrorCode(ord(f.code)))
  if f.message.isSome:
    let m = clip(f.message.get)
    for i, c in m:
      statusMessage[i] = c
    statusMessage[m.len] = '\0'
    r.message = cast[cstring](addr statusMessage[0])
  if f.detail.isSome and f.detail.get.len <= MaxDetailBytes and f.code == ecInvalidParams:
    let d = f.detail.get
    for i, b in d:
      statusDetail[i] = b
    r.detail = cast[ptr UncheckedArray[uint8]](addr statusDetail[0])
    r.detailLen = csize_t(d.len)
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

func failure*(code: ErrorCode, message: string): InvocationFailure =
  InvocationFailure(code: code, message: Opt.some(message))

proc status*(f: AbiFailure): LogosResult =
  status(failureOf(f))

proc give*(
    bytes: openArray[byte], outBuf: ptr ptr UncheckedArray[uint8], outLen: ptr csize_t
): LogosResult =
  ## A success: the response in a C buffer the caller releases once.
  let p = cast[ptr UncheckedArray[uint8]](cMalloc(csize_t(max(bytes.len, 1))))
  if p == nil:
    return status(ecModule, "out of memory")
  for i, b in bytes:
    p[i] = b
  outBuf[] = p
  outLen[] = csize_t(bytes.len)
  LogosResult()

func view*(p: ptr UncheckedArray[uint8], len: csize_t): seq[byte] =
  result = newSeq[byte](int(len))
  for i in 0 ..< int(len):
    result[i] = p[i]
