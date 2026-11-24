## The closure-iterator probe (Tier 5 step 5-3c-1; DECISIONS G454): what 5-3c-2's resumable
## resolver relies on, checked on this compiler under orc, refc and orc-release (5-3c's plan §3.5,
## rules I1 to I6; Fable's review of the plan, §2). Pure Nim and chronos.

{.push raises: [].}

import std/volatile
import unittest2
import chronos

type
  StepKind = enum
    skValue
    skDone

  Step = object
    kind: StepKind
    value: int

  Steps = iterator (): Step {.closure, gcsafe, raises: [].}

  State = ref object
    items: seq[int]
    factoryCalls: int
    ended: bool ## I5: a nested iterator's `done` is marked here

  Runner = ref object ## I6: what drives the iterator holds it; the state does not.
    it: Steps
    got: seq[int]
    resumes: int
    done: Future[void]

  Held = object ## a local with a destructor
    live: bool

var destroyed {.threadvar.}: int

when defined(gcDestructors):
  proc `=destroy`(h: Held) =
    if h.live:
      inc destroyed

else:
  proc `=destroy`(h: var Held) = # refc's signature
    if h.live:
      inc destroyed

proc `=copy`(a: var Held, b: Held) {.error.}

proc inner(s: State, base: int): Steps =
  ## I1: the factory captures `base` once; the iterator has no parameters.
  inc s.factoryCalls
  iterator body(): Step {.closure, gcsafe, raises: [].} =
    for i in 0 ..< 3:
      if base == 10 and i == 1:
        s.ended = true
        yield Step(kind: skDone)
        return
      yield Step(kind: skValue, value: base + i)

  body

proc outer(s: State): Steps =
  iterator body(): Step {.closure, gcsafe, raises: [].} =
    for round in 0 ..< 3:
      let sub = s.inner(round * 10)
      for st in sub():
        yield st
      if s.ended: # I5: checked after each nested loop
        return

  body

proc resume(arg: pointer) {.gcsafe, raises: [].} =
  let r = cast[Runner](arg)
  inc r.resumes
  let st = r.it()
  if st.kind == skDone:
    r.done.complete()
    GC_unref(r)
    return
  r.got.add(st.value)
  if r.got.len == 2:
    GC_fullCollect() # a full collection between two resumes
  callSoon(resume, arg)

proc heldOnce(): Steps =
  iterator body(): Step {.closure, gcsafe, raises: [].} =
    let h = Held(live: true)
    yield Step(kind: skValue, value: 1)
    yield Step(kind: skValue, value: ord(h.live))

  body

proc dropSuspended() {.noinline.} =
  var it = heldOnce()
  discard it()
  it = nil

proc scrubStack() {.noinline.} =
  var buf: array[4096, uint]
  for i in 0 ..< buf.len:
    volatileStore(addr buf[i], 0'u)

proc collect() =
  ## refc destroys an iterator's lifted locals when its environment is collected, even after the
  ## body has run to its end, and scans the stack conservatively: a dead frame's copy of the
  ## environment's address, in a slot the collector's own frames reuse without writing, keeps it alive
  ## until a later collection (seen on Linux, not on the Mac). So that region is overwritten first.
  scrubStack()
  GC_fullCollect()

proc runOut() {.noinline.} =
  let it = heldOnce()
  while not finished(it):
    discard it()

proc byIndex(s: State): Steps =
  ## I2: an index into a list the driver writes between resumes.
  iterator body(): Step {.closure, gcsafe, raises: [].} =
    var i = 0
    while i < s.items.len:
      yield Step(kind: skValue, value: s.items[i])
      inc i
    yield Step(kind: skDone)

  body

proc ownList(list: seq[int]): Steps =
  ## I2: a list nothing writes while the loop runs, the factory's own.
  iterator body(): Step {.closure, gcsafe, raises: [].} =
    for x in list:
      yield Step(kind: skValue, value: x)
    yield Step(kind: skDone)

  body

proc drain(it: Steps, s: State, grow: bool): seq[int] =
  while true:
    let st = it()
    if st.kind == skDone:
      return
    result.add(st.value)
    if grow and s.items.len < 200:
      s.items[0] = -1 # neither a value already yielded nor `ownList`'s
      for k in 0 ..< 50:
        s.items.add(1_000 + s.items.len + k)

proc raising(): iterator (): int {.closure, gcsafe, raises: [ValueError].} =
  iterator body(): int {.closure, gcsafe, raises: [ValueError].} =
    yield 1
    raise newException(ValueError, "probe")

  body

suite "the closure iterators 5-3c-2's resolver relies on (G454; I1 to I6)":
  test "[IMPL-DECISION G454] a factory-made iterator with a nested one, resumed by callSoon across polls and a full collection (I1, I5, I6)":
    let s = State()
    let r = Runner(it: s.outer, done: newFuture[void]("probe"))
    GC_ref(r)
    callSoon(resume, cast[pointer](r))
    waitFor r.done
    check r.got == @[0, 1, 2, 10]
    check r.resumes == 5
    check s.factoryCalls == 2 # one per round reached, not one per step
    # I5: the outer iterator stopped at the mark; `finished` lags one call.
    check not finished(r.it)
    discard r.it()
    check finished(r.it)

  test "[IMPL-DECISION G454] a suspended iterator dropped while it holds a local with a destructor runs it once":
    destroyed = 0
    dropSuspended()
    collect()
    check destroyed == 1
    destroyed = 0
    runOut()
    when defined(gcDestructors): # orc: at the end of its scope, before any collection
      check destroyed == 1
    collect()
    check destroyed == 1

  test "[IMPL-DECISION G454] across a yield, an index sees the list's writes and the factory's list sees none (I2)":
    let s = State(items: @[1, 2])
    let a = s.byIndex
    let b = ownList(s.items)
    let fromA = a.drain(s, grow = true)
    check s.items.len > 100 # past any capacity the list had
    check fromA[0] == 1
    check fromA[1 .. ^1] == s.items[1 .. ^1]
    let fromB = b.drain(s, grow = false)
    check fromB == @[1, 2]

  test "[IMPL-DECISION G454] an exception leaving the iterator does not finish it (I4: never resume one)":
    let it = raising()
    check it() == 1
    expect ValueError:
      discard it()
    check not finished(it)
