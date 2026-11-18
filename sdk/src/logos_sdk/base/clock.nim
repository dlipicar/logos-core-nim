## One clock for the Capability Authority, and later the Runtime's authority
## checks (step 8b) and the transport's ticket checks (step 10a) [IMPL]
## (DECISIONS I84).
##
## `wallMs` is Unix time in milliseconds: the CA's `logos.capability_authority.timestamp`
## (CA l.505). `monoNs` is a monotonic reading for deadlines.
##
## The system clock is the default value, `Clock()`. A test clock is frozen: it
## moves only when a test sets or advances it, so expiry and validity checks
## are exact. It lives in shared memory and is read with atomics, so a test
## thread may move it while the CA thread reads it, under either memory
## manager.

{.push raises: [].}

import std/[atomics, monotimes, times]

type
  ClockState = object
    wall: Atomic[int64]
    mono: Atomic[int64]

  Clock* = object
    ## Copied by value. A test clock's state is freed by `freeClock` once no
    ## copy is used any more.
    state: ptr ClockState

proc systemClock*(): Clock =
  Clock()

func isTest*(c: Clock): bool =
  c.state != nil

proc wallMs*(c: Clock): int64 =
  ## Unix time in milliseconds.
  if c.state == nil:
    let t = getTime()
    t.toUnix * 1000 + int64(t.nanosecond div 1_000_000)
  else:
    c.state.wall.load(moAcquire)

proc monoNs*(c: Clock): int64 =
  if c.state == nil:
    getMonoTime().ticks
  else:
    c.state.mono.load(moAcquire)

proc newTestClock*(wallMs: int64 = 1_800_000_000_000): Clock =
  ## A frozen clock at `wallMs`.
  let s = cast[ptr ClockState](allocShared0(sizeof(ClockState)))
  s.wall.store(wallMs, moRelease)
  s.mono.store(1_000_000_000, moRelease)
  Clock(state: s)

proc setWall*(c: Clock, wallMs: int64) =
  ## Sets the wall time only, as a skewed or corrected system clock would.
  doAssert c.state != nil, "not a test clock"
  c.state.wall.store(wallMs, moRelease)

proc advance*(c: Clock, ms: int64) =
  ## Moves both readings forward by `ms`.
  doAssert c.state != nil, "not a test clock"
  discard c.state.wall.fetchAdd(ms, moAcquireRelease)
  discard c.state.mono.fetchAdd(ms * 1_000_000, moAcquireRelease)

proc freeClock*(c: var Clock) =
  if c.state != nil:
    deallocShared(c.state)
    c.state = nil
