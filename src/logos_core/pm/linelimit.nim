## The Package Manager's operator lines that a caller can repeat, limited (Tier 5 step
## 5-6b; DECISIONS G495, G501; Fable §17.3 point 3, §17.7). A refused observation writes
## one line naming the caller, the method and why (G495); a reader's watch writes one as
## it is admitted (G501), and a reader's watch or handoff one as the Runtime cancels it.
## Under `allow-all` any module may call the observation methods, and a reader may open
## and cancel in a loop, so each such line has a kind, keyed by its caller, and a burst:
##
## - in a window of `LineWindowMs` from the first line of a kind, `burst` lines of it are
##   written; the rest are counted, and the first line after the window is written with
##   that count ("… (N more like it since its last line)": N lines not written);
## - at `LineKinds` kinds, those whose window passed are given up, each with its count,
##   by a sweep at most once a window; when none can be, a new kind's line is counted into
##   one overflow kind for the whole table (callers may be without bound once remote ones
##   exist, 5-7a), itself a line a window and given up by a sweep like the others, so the
##   table never passes `LineKinds`;
## - the counts not written yet are written as the Package Manager stops (`flush`), each
##   as the last line held with the number of the others.
##
## A kind is fixed text, apart from the line written: the refusal's whole line (the
## reasons are fixed texts, never request data), so one caller's methods and causes stay
## apart (Fable §11.2 point 1); for the other lines the method, the event and the caller,
## so the figures a line carries ("N of 4", what a reader asked for) are not in its kind.

{.push raises: [], gcsafe.}

import std/[monotimes, tables, times]

const
  LineWindowMs* = 60_000
    ## [IMPL; G495] a kind's window: `burst` lines of it are written, the rest counted
  LineKinds* = 1024
    ## [IMPL] the kinds held; past it, kinds whose window passed are given up, then new
    ## kinds are counted into the overflow kind
  RefusalBurst* = 1 ## [IMPL; G495] a refusal's line: once a window
  ReaderLineBurst* = 8
    ## [IMPL; G501, §17.7] a reader's or caller's line of one kind (a watch admitted,
    ## cancelled or ended; a call cancelled; a reader's handoff failed): 8 a window, twice
    ## a reader's watch bound
  OverflowLine* =
    "package-manager: lines of a new kind are counted, not written: " & $LineKinds &
    " kinds of line are held" ## the overflow kind's line

type
  Held = object
    since: MonoTime ## the start of its window
    written: int ## its lines written in the window
    count: int ## its lines not written since its last written one
    last: string ## the last of those, for its count

  LineLimit* = object
    byKind: Table[string, Held]
    overflow: Held ## [§17.7] no kind could be added; `since` unset until first used
    overflowUsed: bool
    lastSweep: MonoTime ## [§17.7] the last sweep for kinds past their window, when full
    swept: bool

func counted(line: string, n: int): string =
  ## `line`, and `n` more of its kind not written since its kind's last line.
  if n == 0:
    line
  else:
    line & " (" & $n & " more like it since its last line)"

func held(h: Held): string =
  ## The last line of `h` not written, with the others held before it.
  counted(h.last, h.count - 1)

proc due(h: Held, now: MonoTime): bool =
  now - h.since >= initDuration(milliseconds = LineWindowMs)

proc take(
    h: var Held, line: string, burst: int, now: MonoTime, lines: var seq[string]
) =
  ## One line of the kind `h`: written while its window has room, else counted.
  if h.due(now):
    h.since = now
    h.written = 0
  if h.written < burst:
    lines.add(counted(line, h.count))
    inc h.written
    h.count = 0
  else:
    inc h.count
    h.last = line

proc admit*(
    r: var LineLimit, kind, line: string, burst: int, now: MonoTime
): seq[string] =
  ## The lines to write for one line `line` of the kind `kind`: `line` itself (with the
  ## count held since its kind's last line), a counted line of a kind given up, or
  ## nothing while its kind's window is full.
  var held = false
  r.byKind.withValue(kind, h):
    held = true
    h[].take(line, burst, now, result)
  if held:
    return
  if r.byKind.len >= LineKinds and
      (not r.swept or now - r.lastSweep >= initDuration(milliseconds = LineWindowMs)):
    r.swept = true
    r.lastSweep = now
    var gone: seq[string] = @[]
    for k, h in r.byKind:
      if h.due(now):
        gone.add(k)
        if h.count > 0:
          result.add(h.held)
    for k in gone:
      r.byKind.del(k)
    if r.overflowUsed and r.overflow.due(now):
      if r.overflow.count > 0:
        result.add(r.overflow.held)
      r.overflowUsed = false
      r.overflow = Held()
  if r.byKind.len >= LineKinds:
    if not r.overflowUsed:
      r.overflowUsed = true
      r.overflow = Held(since: now)
    r.overflow.take(OverflowLine, 1, now, result)
    return
  var h = Held(since: now)
  h.take(line, burst, now, result)
  r.byKind[kind] = h

proc flush*(r: var LineLimit): seq[string] =
  ## The counts not written yet, one line each, as the Package Manager stops.
  for _, h in r.byKind:
    if h.count > 0:
      result.add(h.held)
  if r.overflowUsed and r.overflow.count > 0:
    result.add(r.overflow.held)
  r.byKind.clear()
  r.overflowUsed = false
  r.overflow = Held()
  r.swept = false

func kinds*(r: LineLimit): int =
  ## The kinds held, the overflow kind not counted.
  r.byKind.len

{.pop.}
