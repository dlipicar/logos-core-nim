## What crosses between a confined kit's threads [IMPL] (DECISIONS G335, G337,
## G339), in C memory and without chronos, so the consumer helpers
## (`consumert`) and the kit runtime (`kitrt`) can name it.
##
## - `Node` heads everything a module thread's queue holds; `TaskNode` is a
##   unit of work its owner keeps in its own C memory (a delivery, an end
##   report, a completion), which the module thread runs, or drops when the
##   instance is gone.
## - `StatusCopy` holds a status or a failure copied on the thread that
##   received it (INTERFACE l.1792-1794, l.2161), for another thread to read.
##
## Every copy here is zeroed after its last use, marked or not (INTERFACE
## l.363; DECISIONS G276).

{.push raises: [], gcsafe.}

import results
import ../abi/[checks, types]
import ../iface/outcome
import ../base/wipe

type
  NodeKind* = enum
    nkJob ## an entry handed off
    nkPost ## a C callback from `post`
    nkTask ## a `TaskNode`

  Node* = object ## The head of what a module thread's queue holds.
    next*: ptr Node
    kind*: NodeKind

  TaskFn* = proc(task: ptr TaskNode, drop: bool) {.nimcall, gcsafe, raises: [].}
    ## Runs `task` on the module thread; with `drop`, releases what it holds
    ## without running anything of the instance's.

  TaskNode* = object
    node*: Node
    run*: TaskFn
    counted*: bool ## counts against the context's delivery bound
    duringDestroy*: bool
      ## [DECISIONS G437] still runs while the module is destroyed, until its
      ## instance is released: the completion of something the module started
      ## (a prepared call's, a cancellation notice). Every other task is dropped
      ## from the start of destroy.

  PostTaskFn* =
    proc(context: pointer, task: ptr TaskNode): bool {.nimcall, gcsafe, raises: [].}
    ## Queues `task` for the module thread of `context`; false when it is
    ## counted and the bound is reached. Any thread; never waits or allocates.

  Dispatcher* = object
    ## [DECISIONS G339, P2] Where a route handle's callbacks run: in the
    ## delivery when `post` is nil, else on a confined kit's module thread.
    context*: pointer
    post*: PostTaskFn

  StatusCopy* = object
    ## A status or a failure in fixed storage; `clear` it before first use.
    code*: int64
    messageLen*: int ## -1: none; `MaxMessageBytes + 1`: longer than allowed
    detailLen*: int ## -1: none
    bad*: bool ## not a status a receiver can read: MODULE_ERROR without diagnostics
    message*: array[MaxMessageBytes + 2, char]
    detail*: array[MaxDetailBytes, uint8]

func confined*(d: Dispatcher): bool =
  not d.post.isNil

proc clear*(s: var StatusCopy) =
  if s.messageLen > 0:
    secureZero(addr s.message[0], s.messageLen)
  if s.detailLen > 0:
    secureZero(addr s.detail[0], s.detailLen)
  s.messageLen = -1
  s.detailLen = -1
  s.bad = false
  s.code = 0

proc copyResult*(dst: var StatusCopy, r: LogosResult) =
  ## A `logos_result_t` as received, without the Nim heap.
  dst.code = int64(r.code)
  dst.bad = false
  dst.messageLen = -1
  dst.detailLen = -1
  if r.message != nil:
    var n = 0
    while n <= MaxMessageBytes and r.message[n] != '\0':
      dst.message[n] = r.message[n]
      inc n
    dst.message[n] = '\0'
    dst.messageLen = n
  if r.detail != nil:
    if int(r.detailLen) > MaxDetailBytes:
      dst.bad = true
    else:
      for i in 0 ..< int(r.detailLen):
        dst.detail[i] = r.detail[i]
      dst.detailLen = int(r.detailLen)
  elif r.detailLen != 0:
    dst.bad = true

proc copyFailure*(dst: var StatusCopy, f: InvocationFailure) =
  dst.code = int64(ord(f.code))
  dst.bad = false
  dst.messageLen = -1
  dst.detailLen = -1
  if f.message.isSome:
    let n = min(f.message.unsafeGet.len, MaxMessageBytes + 1)
    for i in 0 ..< n:
      dst.message[i] = f.message.unsafeGet[i]
    dst.message[n] = '\0'
    dst.messageLen = n
  if f.detail.isSome:
    if f.detail.unsafeGet.len > MaxDetailBytes:
      dst.bad = true
    else:
      for i, b in f.detail.unsafeGet:
        dst.detail[i] = b
      dst.detailLen = f.detail.unsafeGet.len

proc readCopy*(src: var StatusCopy): Result[void, InvocationFailure] =
  ## A copied status as its receiver reads it (`readStatus`); the copy is
  ## zeroed.
  if src.bad:
    result = err(
      InvocationFailure(
        code: ecModule, message: Opt.some("invalid status: its detail cannot be read")
      )
    )
  else:
    let view = LogosResult(
      code: CErrorCode(src.code),
      message:
        if src.messageLen >= 0:
          cast[cstring](addr src.message[0])
        else:
          nil,
      detail:
        if src.detailLen >= 0:
          cast[ptr UncheckedArray[uint8]](addr src.detail[0])
        else:
          nil,
      detailLen: csize_t(max(src.detailLen, 0)),
    )
    var r = readStatus(view)
    if r.isOk:
      result = ok()
    else:
      result = err(
        InvocationFailure(
          code: r.unsafeError.code,
          message: move(r.unsafeError.message),
          detail: move(r.unsafeError.detail),
        )
      )
  src.clear()

{.pop.}
