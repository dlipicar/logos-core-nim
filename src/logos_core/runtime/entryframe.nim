## INTERFACE §2.9.3: this thread's stack of active provider entries (`Frame`),
## which `current` reads, and the fixed-size text and event-name check every
## caller of module code shares.
##
## Split from `callside.nim` (which re-exports it) so a Module Host, which runs
## provider entries and a Runtime Control binding but none of the Runtime,
## links only this: `callside` brings in the Runtime's own state, and with it
## each generated schema loaded at start (part 4b-3.2). [IMPL]

{.push raises: [], gcsafe.}

import results
import ../abi/[cstatus, types]
import ../cbor/utf8
import ../iface/outcome

const
  TextCapacity* = 160 ## instance ids are at most 128 bytes; tokens are shorter
  MaxEventNameBytes* = 128 ## [SPEC INTERFACE §1.5] a complete event identifier

type
  FixedText* = object
    len: int
    data: array[TextCapacity, char]

  Frame* = object
    ## One provider entry active on this thread, or a barrier (`context` nil)
    ## that hides every entry below it from `current` while a consumer
    ## callback runs (INTERFACE l.2170).
    context*: ptr LogosInvocationContext
    access*: pointer
    previous*: ptr Frame

func fixed*(s: string): FixedText =
  doAssert s.len <= TextCapacity
  result.len = s.len
  for i, c in s:
    result.data[i] = c

func `$`*(t: FixedText): string =
  result = newString(t.len)
  for i in 0 ..< t.len:
    result[i] = t.data[i]

func utf8View*(t: var FixedText): LogosUtf8View =
  ## A borrowed view of `t`'s bytes, valid while `t` stays where it is.
  LogosUtf8View(
    data: (if t.len == 0: nil
    else: cast[ptr UncheckedArray[uint8]](addr t.data[0])),
    len: csize_t(t.len),
  )

proc checkEventName*(name: cstring): Result[string, InvocationFailure] =
  ## [SPEC INTERFACE §1.5, §2.5, §2.9.3] A malformed event identifier is
  ## INVALID_PARAMS: null, empty, longer than 128 bytes or not UTF-8.
  if name == nil:
    return err(failure(ecInvalidParams, "a null event name"))
  let s = $name
  if s.len == 0 or s.len > MaxEventNameBytes or not isValidUtf8(s):
    return err(failure(ecInvalidParams, "an event name has 1 to 128 UTF-8 bytes"))
  ok(s)

proc checkEventName*(name: openArray[byte]): Result[string, InvocationFailure] =
  ## The same check for a name a Module Host sent as bytes.
  var s = newString(name.len)
  for i, b in name:
    if b == 0:
      return err(failure(ecInvalidParams, "an event name has 1 to 128 UTF-8 bytes"))
    s[i] = char(b)
  checkEventName(cstring(s))

# The invocation-context stack ---------------------------------------------------------

var
  active {.threadvar.}: ptr Frame
  runtimeOwned {.threadvar.}: bool

proc markRuntimeThread*() =
  ## The engine's own threads: the Runtime thread and its lifecycle and call
  ## workers, where module initialization, destruction and completion
  ## callbacks run.
  runtimeOwned = true

proc setRuntimeOwned*(owned: bool) =
  ## [plan §2.6; G267] A Module Host's Runtime Control worker takes the calling
  ## host thread's kind for one call: one the host runs module code on, or one
  ## module code created.
  runtimeOwned = owned

proc inRuntimeCallback*(): bool =
  ## [SPEC RUNTIME l.4083] Whether this thread is one the Runtime owns, or is
  ## inside a provider entry or a consumer callback: module code whose
  ## completion shutdown may require.
  runtimeOwned or active != nil

proc push*(f: var Frame) =
  f.previous = active
  active = addr f

proc pop*(f: var Frame) =
  active = f.previous

template barrier*(body: untyped) =
  ## [SPEC INTERFACE l.2170] A consumer callback (an event handler) never sees
  ## the invocation context of a provider entry below it on this thread.
  var fence = Frame()
  push(fence)
  body
  pop(fence)

proc currentOp*(state: pointer): ptr LogosInvocationContext {.cdecl.} =
  ## [SPEC INTERFACE §2.9.3, l.2166-2170] The context of the innermost provider
  ## entry active on this thread for the instance `state` belongs to, so a
  ## nested entry into another instance hides nothing; none outside one, and
  ## none past a consumer callback's barrier.
  var f = active
  while f != nil:
    if f.context == nil:
      return nil
    if f.access == state:
      return f.context
    f = f.previous
  nil
