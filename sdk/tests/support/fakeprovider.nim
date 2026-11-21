## Provider invocations a test builds, as a Runtime keeps them (INTERFACE
## §2.9.2; DECISIONS G338): fixed storage, never GC'd memory, so the module's
## threads write the completion here and the test's thread reads it. The
## context's operations count any use after the release; its caller is the
## invocation's own id.

{.push raises: [], gcsafe.}

import std/[atomics, os]
import results
import logos_sdk/abi/[checks, types]
import logos_sdk/iface/outcome
import logos_sdk/testing/kitruntime

export atomics

type
  ContextPublish* = proc(
    invocation: ptr LogosInvocationContext,
    eventName: cstring,
    cborData: ptr UncheckedArray[uint8],
    cborDataLen: csize_t,
  ): LogosResult {.cdecl, gcsafe, raises: [].}

  FakeInvocation* = object
    inv*: LogosProviderInvocation ## first: the kit's pointer is the fake's
    context*: LogosInvocationContext
    id: array[24, char] ## the caller's module instance, NUL-terminated
    methodName*: array[16, char]
    params*: array[512, uint8]
    completes*, releases*, lateUses*: Atomic[int]
    released*, cancelled*, outOfOrder*: Atomic[bool]
    result*: LogosResult ## as completed: its message and detail are the owner's
    response*: ptr UncheckedArray[uint8]
    responseLen*: int
    owner*: LogosResponseOwner
    messageCopy: array[1200, char] ## taken at completion
    messageLen: int
    responseCopy: array[1024, uint8]
    completeThread*: uint64
    atCompletion*: int ## what `completionProbe` returned when it completed

var
  fakes*: array[72, FakeInvocation]
  fakePublish*: ContextPublish ## the context's `publish`; nil answers LOGOS_OK
  completionProbe*: proc(): int {.nimcall, gcsafe, raises: [].}
    ## read when an invocation completes, into `atCompletion`

proc here(): uint64 =
  uint64(getThreadId())

proc view(s: cstring): LogosUtf8View =
  LogosUtf8View(data: cast[ptr UncheckedArray[uint8]](s), len: csize_t(s.len))

proc fakeOf(c: ptr LogosInvocationContext): ptr FakeInvocation =
  cast[ptr FakeInvocation](c.state)

proc late(fi: ptr FakeInvocation) =
  if fi.released.load:
    fi.lateUses += 1

proc fiCaller(
    invocation: ptr LogosInvocationContext, outCaller: ptr LogosCallerView
): LogosResult {.cdecl, gcsafe, raises: [].} =
  let fi = fakeOf(invocation)
  fi.late()
  outCaller[] = LogosCallerView(
    kind: CallerModule,
    runtimeInstanceId: view(cstring(runtimeId)),
    moduleInstanceId: view(cast[cstring](addr fi.id[0])),
  )
  LogosResult()

proc fiCancelled(
    invocation: ptr LogosInvocationContext
): bool {.cdecl, gcsafe, raises: [].} =
  let fi = fakeOf(invocation)
  fi.late()
  fi.cancelled.load

proc fiPublish(
    invocation: ptr LogosInvocationContext,
    eventName: cstring,
    cborData: ptr UncheckedArray[uint8],
    cborDataLen: csize_t,
): LogosResult {.cdecl, gcsafe, raises: [].} =
  fakeOf(invocation).late()
  {.cast(gcsafe).}:
    let p = fakePublish
  if p.isNil:
    LogosResult()
  else:
    p(invocation, eventName, cborData, cborDataLen)

var fiVtable = LogosInvocationContextVtable(
  abiVersion: 1,
  structSize: csize_t(sizeof(LogosInvocationContextVtable)),
  caller: fiCaller,
  isCancelled: fiCancelled,
  publish: fiPublish,
)

proc fiComplete(
    inv: ptr LogosProviderInvocation,
    r: LogosResult,
    response: ptr UncheckedArray[uint8],
    len: csize_t,
    owner: LogosResponseOwner,
) {.cdecl, gcsafe, raises: [].} =
  let fi = cast[ptr FakeInvocation](inv)
  fi.late()
  fi.result = r
  fi.response = response
  fi.responseLen = int(len)
  fi.owner = owner
  fi.messageLen = -1
  if r.message != nil:
    var n = 0
    while n < fi.messageCopy.high and r.message[n] != '\0':
      fi.messageCopy[n] = r.message[n]
      inc n
    fi.messageLen = n
  for i in 0 ..< min(int(len), fi.responseCopy.len):
    fi.responseCopy[i] = response[i]
  fi.completeThread = here()
  {.cast(gcsafe).}:
    let probe = completionProbe
  if not probe.isNil:
    fi.atCompletion = probe()
  fi.completes += 1

proc fiRelease(inv: ptr LogosProviderInvocation) {.cdecl, gcsafe, raises: [].} =
  let fi = cast[ptr FakeInvocation](inv)
  if fi.completes.load != 1:
    fi.outOfOrder.store(true)
  fi.releases += 1
  fi.released.store(true)

proc prepareFake*(
    i: int, bare: string, params: openArray[byte], id = "deferred"
): ptr FakeInvocation =
  ## `fakes[i]`, cleared, as an invocation of `bare` with `params` from the
  ## caller `id`.
  {.cast(gcsafe).}:
    let fi = addr fakes[i]
  zeroMem(fi, sizeof(FakeInvocation))
  doAssert id.len < fi.id.len and bare.len < fi.methodName.len and
    params.len <= fi.params.len
  for k, c in id:
    fi.id[k] = c
  for k, c in bare:
    fi.methodName[k] = c
  for k, b in params:
    fi.params[k] = b
  fi.messageLen = -1
  fi.context = LogosInvocationContext(vtable: addr fiVtable, state: fi)
  fi.inv = LogosProviderInvocation(
    abiVersion: AsyncProviderAbiVersion,
    structSize: csize_t(sizeof(LogosProviderInvocation)),
    `method`: cast[cstring](addr fi.methodName[0]),
    paramsCbor: cast[ptr UncheckedArray[uint8]](addr fi.params[0]),
    paramsCborLen: csize_t(params.len),
    context: addr fi.context,
    complete: fiComplete,
    executionRelease: fiRelease,
  )
  fi

proc submit*(
    api: ptr LogosAsyncProviderApi,
    module: ptr LogosModuleContext,
    fi: ptr FakeInvocation,
) =
  api.submit(module, addr fi.inv)

proc cancel*(
    api: ptr LogosAsyncProviderApi,
    module: ptr LogosModuleContext,
    fi: ptr FakeInvocation,
) =
  ## As a Runtime cancels: the context says so first, then the hook (l.2109).
  fi.cancelled.store(true)
  api.requestCancel(module, addr fi.inv)

proc settledIn*(fi: ptr FakeInvocation, ms = 10_000): bool =
  ## Whether `fi` was released within `ms`.
  var waited = 0
  while fi.releases.load == 0 and waited < ms:
    sleep(1)
    inc waited
  fi.releases.load > 0

proc status*(fi: ptr FakeInvocation): AbiCheck =
  ## The completion as the Runtime reads it (l.2087-2091).
  checkOutcome(
    fi.result, completionShape(fi.response, csize_t(fi.responseLen), fi.owner)
  )

proc message*(fi: ptr FakeInvocation): string =
  let st = fi.status
  if st.isErr:
    st.error.message.get("")
  else:
    ""

proc responseOf*(fi: ptr FakeInvocation): seq[byte] =
  for i in 0 ..< fi.responseLen:
    result.add(fi.response[i])

proc unchanged*(fi: ptr FakeInvocation): bool =
  ## The regions the owner governs still hold what the completion held.
  if (fi.messageLen >= 0) != (fi.result.message != nil):
    return false
  for i in 0 ..< max(fi.messageLen, 0):
    if fi.result.message[i] != fi.messageCopy[i]:
      return false
  for i in 0 ..< fi.responseLen:
    if fi.response[i] != fi.responseCopy[i]:
      return false
  true

proc clearFake*(fi: ptr FakeInvocation) =
  ## Clears the completion's owner, on this thread.
  let o = fi.owner
  fi.owner = LogosResponseOwner()
  if not o.release.isNil:
    o.release(o.state)

proc exactlyOnce*(fi: ptr FakeInvocation): bool =
  ## One completion, then one release, and no use after it.
  fi.completes.load == 1 and fi.releases.load == 1 and not fi.outOfOrder.load and
    fi.lateUses.load == 0

proc same*(a, b: AbiCheck): bool =
  ## The same outcome: success, or one code with the same diagnostics.
  if a.isOk or b.isOk:
    return a.isOk == b.isOk
  a.error.code == b.error.code and a.error.message == b.error.message and
    a.error.detail == b.error.detail

{.pop.}
