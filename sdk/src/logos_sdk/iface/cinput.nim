## INTERFACE §3, §3.2: the reverse mapper's input set and its includes.
##
## [SPEC INTERFACE §3 l.2203-2219, §3.2 l.2288-2298] The input is an explicitly
## supplied set of header sources identified by logical names. Contract-header
## includes resolve against those names only: never the filesystem, a network or
## include-search paths (l.2295). Every supplied body is parsed and kept with its
## macro definitions (l.2205), whether it is included once, several times or not
## at all (l.2297, l.2300).
##
## [IMPL-DECISION G317] The fixed common header is exactly `#include
## "logos_types.h"`, which is never resolved against the set; its declarations
## are the predefined environment, in scope whether or not a header includes it
## (l.2217-2219, l.2640). The allowed standard headers are `<stdbool.h>`,
## `<stddef.h>` and `<stdint.h>`: the headers `logos_types.h` itself includes
## (l.3432-3434), which declare the §3.1 table's `bool`, `size_t` and
## fixed-width types (l.2298 points at §3.1, which names none). An include
## cycle is rejected, which is stricter than the text: l.2297 only makes a
## repeated include the same header.

{.push raises: [].}

import std/[strutils, tables]
import results
import ./[cparse, creject]

export results, creject, cparse

const
  FixedHeader* = "logos_types.h" ## [SPEC INTERFACE §3.2 l.2298, §5.2]
  StandardHeaders* = ["stdbool.h", "stddef.h", "stdint.h"] ## [IMPL-DECISION G317]
  MaxSetBytes* = 16_777_216 ## [IMPL-DECISION G321] one input set
  MaxHeaders* = 1024 ## [IMPL-DECISION G321]
  MaxIncludeDepth* = 64 ## [IMPL-DECISION G321]

type
  HeaderSource* = object
    name*: string ## the logical name
    text*: string

  ItemRef* = object
    header*: int ## index into `HeaderSet.headers`
    item*: int ## index into that header's `items`

  HeaderSet* = object
    headers*: seq[ParsedHeader] ## in input order
    byName*: Table[string, int]
    includes*: seq[seq[int]]
      ## each header's resolved contract includes, in source order, repeats kept
    order*: seq[seq[ItemRef]]
      ## each header's translation order: its top-level items with each
      ## contract header spliced in at its first inclusion

func checkLogicalName*(name: string): Result[void, string] =
  ## [SPEC INTERFACE §3.2 l.2289] Nonempty, slash-separated and relative, with no
  ## empty, `.` or `..` component and no backslash.
  if name.len == 0:
    return err("an empty logical name")
  if '\\' in name:
    return err(name & ": a backslash in a logical name")
  if '\0' in name:
    return err("a NUL in a logical name")
  for c in name.split('/'):
    if c.len == 0 or c == "." or c == "..":
      return err(name & ": an empty, . or .. component")
  ok()

func dirOf(name: string): seq[string] =
  let parts = name.split('/')
  parts[0 ..^ 2]

func resolveInclude*(includer, target: string): Result[string, (RejectReason, string)] =
  ## [SPEC INTERFACE §3.2 l.2291-2294] `target` resolved against the including
  ## header's logical directory, with `.` removed and `..` resolved.
  if target.len == 0:
    return err((rkIncludeName, "an empty include name"))
  if target.startsWith("/"):
    return err((rkIncludeName, target & ": not relative"))
  if '\\' in target:
    return err((rkIncludeName, target & ": a backslash in an include name"))
  var path = dirOf(includer)
  for c in target.split('/'):
    if c.len == 0:
      return err((rkIncludeName, target & ": an empty path component"))
    if c == ".":
      continue
    if c == "..":
      if path.len == 0:
        return err((rkIncludeAboveRoot, target & " resolves above the logical root"))
      path.setLen(path.len - 1)
    else:
      path.add(c)
  ok(path.join("/"))

proc readSet*(sources: openArray[HeaderSource]): Result[HeaderSet, Rejection] =
  ## [SPEC INTERFACE §3, §3.2] Parses every supplied header and resolves its
  ## includes; rejects the set on the first fault.
  if sources.len > MaxHeaders:
    return err(reject(rkLimit, "", 0, "more than " & $MaxHeaders & " headers"))
  var hs = HeaderSet(headers: @[], includes: @[], order: @[])
  var total = 0
  for s in sources:
    let r = checkLogicalName(s.name)
    if r.isErr:
      return err(reject(rkLogicalName, s.name, 0, r.error))
    if s.name == FixedHeader:
      return err(
        reject(
          rkLogicalName, s.name, 0,
          "logos_types.h is the predefined environment, not a supplied header",
        )
      )
    if s.name in hs.byName:
      return err(
        reject(rkDuplicateName, s.name, 0, "a second header with this logical name")
      )
    total += s.text.len
    if total > MaxSetBytes:
      return err(reject(rkLimit, s.name, 0, "an input set larger than 16 MiB"))
    hs.byName[s.name] = hs.headers.len
    hs.headers.add(?parseHeader(s.name, s.text))
  # Resolve contract includes.
  for h in hs.headers:
    var incs: seq[int] = @[]
    for it in h.items:
      if it.kind != ciInclude:
        continue
      if it.angle:
        if it.name notin StandardHeaders:
          return err(
            reject(
              rkIncludeForm,
              h.name,
              it.line,
              "<" & it.name &
                "> is not an allowed standard header (stdbool.h, stddef.h, stdint.h)",
            )
          )
        continue
      if it.name == FixedHeader:
        continue
      let target = resolveInclude(h.name, it.name)
      if target.isErr:
        return err(reject(target.error[0], h.name, it.line, target.error[1]))
      let j = hs.byName.getOrDefault(target.get, -1)
      if j < 0:
        return err(
          reject(
            rkIncludeMissing,
            h.name,
            it.line,
            "\"" & it.name & "\" (" & target.get & ") is not a supplied header",
          )
        )
      incs.add(j)
    hs.includes.add(incs)
  # [IMPL-DECISION G317] no cycles; the depth is bounded.
  var state = newSeq[int](hs.headers.len) # 0 new, 1 on the stack, 2 done
  proc visit(
      hs: HeaderSet, state: var seq[int], h, depth: int
  ): Result[void, Rejection] =
    if depth > MaxIncludeDepth:
      return
        err(reject(rkLimit, hs.headers[h].name, 0, "includes nested deeper than 64"))
    state[h] = 1
    for j in hs.includes[h]:
      if state[j] == 1:
        return err(
          reject(
            rkIncludeCycle,
            hs.headers[h].name,
            0,
            "an include cycle through " & hs.headers[j].name,
          )
        )
      if state[j] == 0:
        ?visit(hs, state, j, depth + 1)
    state[h] = 2
    ok()

  for h in 0 ..< hs.headers.len:
    if state[h] == 0:
      ?visit(hs, state, h, 0)
  # Translation orders.
  proc splice(hs: HeaderSet, h: int, seen: var seq[bool], o: var seq[ItemRef]) =
    seen[h] = true
    var k = 0
    for i, it in hs.headers[h].items:
      if it.kind == ciInclude and not it.angle and it.name != FixedHeader:
        let j = hs.includes[h][k]
        inc k
        if not seen[j]:
          splice(hs, j, seen, o)
      else:
        o.add(ItemRef(header: h, item: i))

  for h in 0 ..< hs.headers.len:
    var seen = newSeq[bool](hs.headers.len)
    var o: seq[ItemRef] = @[]
    splice(hs, h, seen, o)
    hs.order.add(o)
  ok(hs)

func closure*(hs: HeaderSet, h: int): seq[int] =
  ## Header `h` and every header it includes, directly or not, in first-inclusion
  ## order.
  var seen = newSeq[bool](hs.headers.len)
  var o: seq[int] = @[]
  var stack = @[h]
  while stack.len > 0:
    let x = stack.pop()
    if seen[x]:
      continue
    seen[x] = true
    o.add(x)
    for k in countdown(hs.includes[x].high, 0):
      stack.add(hs.includes[x][k])
  o

func `$`*(hs: HeaderSet): string =
  ## The logical names of the set's headers.
  var names: seq[string] = @[]
  for h in hs.headers:
    names.add(h.name)
  "HeaderSet(" & names.join(", ") & ")"
