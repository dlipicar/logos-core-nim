## The Package Manager's refusal lines, limited (Tier 5 step 5-6b; DECISIONS G495, G504;
## Fable §17.3 point 3). A refused observation writes one operator line naming the
## caller, the method and why (G495). Under `allow-all` any module may call the
## observation methods, so the lines are limited for each caller: the first line of a
## kind is written, the same line again within `RefusalLogMs` is only counted, and the
## first one after that is written with the count. A kind is the whole line, so the
## log still tells one caller's methods and causes apart (Fable §11.2 point 1); the
## reasons are fixed texts, so the kinds of one caller are a few.

{.push raises: [], gcsafe.}

import std/[monotimes, tables, times]

const
  RefusalLogMs* = 60_000
    ## [IMPL; G495] a line written again within this is counted, not written
  RefusalKinds* = 1024
    ## [IMPL] the kinds held before old ones are given up: past their interval, with
    ## their count written

type
  Held = object
    since: MonoTime ## when its line was last written
    count: int ## the refusals of its kind not written since

  RefusalLog* = object
    byLine: Table[string, Held]

func counted(line: string, n: int): string =
  line & " (" & $n & " more like it since its last line)"

proc due(h: Held, now: MonoTime): bool =
  now - h.since >= initDuration(milliseconds = RefusalLogMs)

proc admit*(r: var RefusalLog, line: string, now: MonoTime): seq[string] =
  ## The lines to write for one refusal whose line is `line`: it, with the count held
  ## since its last line; nothing while its last line is younger than `RefusalLogMs`.
  ## With `RefusalKinds` held, kinds past their interval are given up first, each
  ## with its count when it has one.
  var held = false
  r.byLine.withValue(line, h):
    held = true
    if not h[].due(now):
      inc h.count
    else:
      result.add(
        if h.count > 0:
          counted(line, h.count)
        else:
          line
      )
      h.since = now
      h.count = 0
  if held:
    return
  if r.byLine.len >= RefusalKinds:
    var gone: seq[string] = @[]
    for k, h in r.byLine:
      if h.due(now):
        gone.add(k)
        if h.count > 0:
          result.add(counted(k, h.count))
    for k in gone:
      r.byLine.del(k)
  r.byLine[line] = Held(since: now)
  result.add(line)

proc flush*(r: var RefusalLog): seq[string] =
  ## The counts not written yet, one line each, as the Package Manager stops.
  for k, h in r.byLine:
    if h.count > 0:
      result.add(counted(k, h.count))
  r.byLine.clear()

func kinds*(r: RefusalLog): int =
  ## The kinds held.
  r.byLine.len

{.pop.}
