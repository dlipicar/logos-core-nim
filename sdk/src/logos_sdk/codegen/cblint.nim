## `lcn-gen lint-callbacks`: every C-callable procedure registers its thread
## first, or says why it need not (DECISIONS G464-G467) [IMPL].
##
## A procedure is C-callable when it carries `cdecl`, `noconv`, `stdcall` or
## `exportc`, itself or from an enclosing `{.push.}`, and has a body. Each one
## must be one of:
##
## - marked `{.lcnCallback.}` or `{.lcnModuleThread.}`;
## - exempt with a reason, `{.lcnNoNimHeap: "…".}` or `{.lcnOwnRuntime: "…".}`;
## - an entry whose first statement is `kitEnter()` or `bindingEnter()`.
##
## A procedure the marks give the C calling convention is accepted whatever
## else it carries. An `importc` declaration and a procedure type have no body
## and are not checked. Outside `logos_sdk/base/entry.nim`, a conversion or a
## cast to `Entered[...]` is refused too: `entered(p)` is the only way to make
## one.
##
## It is a text heuristic in the manner of `tools/lint/ctortry.py`: comments and
## string literals are blanked first, so code inside them is never read. It
## sees no procedure a macro builds from strings, and no `cast` of a procedure
## to a callback type. `--self-test` runs the fixtures below.

{.push raises: [].}

import std/[algorithm, os, strutils]

type
  Finding* = object
    path*: string
    line*: int
    name*: string
    message*: string

  Stats* = object
    files*: int
    callable*: int ## C-callable procedures with a body
    marked*: int ## `{.lcnCallback.}` or `{.lcnModuleThread.}`
    entries*: int ## `kitEnter()` or `bindingEnter()` first
    noNimHeap*: int
    ownRuntime*: int

const
  RoutineWords = ["proc", "func", "method", "iterator", "converter"]
  CallableWords = ["cdecl", "noconv", "stdcall", "exportc"]
  MarkWords = ["lcnCallback", "lcnModuleThread"]
  ExemptWords = ["lcnNoNimHeap", "lcnOwnRuntime"]
  EntryCalls = ["kitEnter", "bindingEnter"]
  EntryModule = "logos_sdk/base/entry.nim"
  SkippedDirs = ["nimbledeps", "build", "nimcache", ".git"]

func isIdentStart(c: char): bool =
  c in {'a' .. 'z', 'A' .. 'Z', '_', '\x80' .. '\xff'}

func isIdent(c: char): bool =
  c.isIdentStart or c in {'0' .. '9'}

proc blank(text: string): string =
  ## `text` with every comment and the inside of every string and character
  ## literal replaced by spaces; newlines, quotes and offsets kept.
  result = text
  var i = 0
  let n = text.len
  template wipeTo(e: int) =
    for k in i ..< min(e, n):
      if result[k] != '\n':
        result[k] = ' '

  while i < n:
    let c = text[i]
    if c == '#':
      if i + 1 < n and text[i + 1] == '[' or
          (i + 2 < n and text[i + 1] == '#' and text[i + 2] == '['):
        # A block comment, nested ones included.
        var depth = 0
        var j = i
        while j < n:
          if text[j] == '#' and j + 1 < n and text[j + 1] == '[':
            inc depth
            j += 2
          elif text[j] == ']' and j + 1 < n and text[j + 1] == '#':
            dec depth
            j += 2
            if depth == 0:
              break
          else:
            inc j
        wipeTo(j)
        i = j
      else:
        var j = i
        while j < n and text[j] != '\n':
          inc j
        wipeTo(j)
        i = j
    elif c == '"':
      let raw = i > 0 and text[i - 1].isIdent
        # r"…" and a generalized raw literal (ident"…"): no escapes
      if i + 2 < n and text[i + 1] == '"' and text[i + 2] == '"':
        var j = i + 3
        while j < n:
          if text[j] == '"' and j + 2 < n and text[j + 1] == '"' and text[j + 2] == '"':
            # The closing quotes are the last three of the run.
            var e = j + 3
            while e < n and text[e] == '"':
              inc e
            j = e - 3
            break
          inc j
        let s = i
        i = s + 3
        wipeTo(j)
        i = min(j + 3, n)
      else:
        var j = i + 1
        while j < n and text[j] != '\n':
          if raw:
            if text[j] == '"':
              if j + 1 < n and text[j + 1] == '"':
                j += 2
                continue
              break
          else:
            if text[j] == '\\':
              j += 2
              continue
            if text[j] == '"':
              break
          inc j
        inc i
        wipeTo(j)
        i = min(j + 1, n)
    elif c == '\'' and not (i > 0 and text[i - 1].isIdent):
      # A character literal; `1'u8` is a number's suffix.
      var j = i + 1
      if j < n and text[j] == '\\':
        j += 2
        while j < n and text[j] != '\'' and text[j] != '\n':
          inc j
      else:
        inc j
      if j < n and text[j] == '\'':
        inc i
        wipeTo(j)
        i = j + 1
      else:
        inc i
    else:
      inc i

func lineOf(text: string, offset: int): int =
  result = 1
  for k in 0 ..< min(offset, text.len):
    if text[k] == '\n':
      inc result

func indentAt(code: string, offset: int): int =
  ## The indentation of the line holding `offset`.
  var s = offset
  while s > 0 and code[s - 1] != '\n':
    dec s
  while s < code.len and code[s] == ' ':
    inc s
    inc result

func wordAt(code: string, i: int): string =
  var j = i
  while j < code.len and code[j].isIdent:
    inc j
  code[i ..< j]

type
  PragmaItem = object
    name: string
    value: (int, int) ## its value's span in the text, or (-1, -1)

  Routine = object
    offset: int
    name: string
    pragmas: seq[PragmaItem]
    body: int ## where the body starts, or -1 when there is none

proc pragmaItems(code: string, a, b: int): seq[PragmaItem] =
  ## The items of the pragma list in `code[a ..< b]`, between `{.` and `.}`.
  var i = a
  while i < b:
    while i < b and code[i] in {' ', '\n', ',', '\t'}:
      inc i
    if i >= b:
      break
    var item = PragmaItem(value: (-1, -1))
    if code[i] == '`':
      var j = i + 1
      while j < b and code[j] != '`':
        inc j
      item.name = code[i + 1 ..< j]
      i = j + 1
    else:
      item.name = code.wordAt(i)
      i += max(item.name.len, 1)
    var depth = 0
    var j = i
    while j < b:
      let c = code[j]
      if c in {'(', '[', '{'}:
        inc depth
      elif c in {')', ']', '}'}:
        dec depth
      elif c == ',' and depth == 0:
        break
      inc j
    var v = i
    while v < j and code[v] == ' ':
      inc v
    if v < j and code[v] in {':', '('}:
      item.value = (v + 1, j)
    result.add item
    i = j + 1

proc routineAt(code: string, kw, kwEnd: int): Routine =
  ## The routine whose keyword is at `code[kw ..< kwEnd]`.
  result = Routine(offset: kw, body: -1)
  let indent = code.indentAt(kw)
  var i = kwEnd
  while i < code.len and code[i] == ' ':
    inc i
  if i < code.len and code[i] == '`':
    var j = i + 1
    while j < code.len and code[j] != '`':
      inc j
    result.name = code[i + 1 ..< j]
  elif i < code.len and code[i].isIdentStart:
    result.name = code.wordAt(i)
  var depth = 0
  while i < code.len:
    let c = code[i]
    case c
    of '`':
      inc i
      while i < code.len and code[i] != '`':
        inc i
    of '(', '[':
      inc depth
    of '{':
      if depth == 0 and i + 1 < code.len and code[i + 1] == '.':
        # A pragma list of the routine itself.
        var j = i + 2
        var d = 0
        while j < code.len:
          if code[j] == '.' and j + 1 < code.len and code[j + 1] == '}' and d == 0:
            break
          if code[j] in {'(', '[', '{'}:
            inc d
          elif code[j] in {')', ']', '}'}:
            dec d
          inc j
        result.pragmas.add code.pragmaItems(i + 2, j)
        i = j + 1
      else:
        inc depth
    of ')', ']', '}':
      dec depth
      if depth < 0:
        return # a procedure type inside brackets
    of '=':
      if depth == 0:
        let prev =
          if i > 0:
            code[i - 1]
          else:
            ' '
        let next =
          if i + 1 < code.len:
            code[i + 1]
          else:
            ' '
        if prev notin {'=', '<', '>', '!', '.', ':'} and next != '=':
          var j = i + 1
          while j < code.len and code[j] in {' ', '\n'}:
            inc j
          if code.wordAt(j) == "nil":
            return # a procedure-typed variable or parameter initialized nil
          result.body = i + 1
          return
    of '\n':
      if depth == 0:
        var j = i + 1
        while j < code.len:
          var k = j
          while k < code.len and code[k] == ' ':
            inc k
          if k < code.len and code[k] == '\n':
            j = k + 1
            continue
          if k >= code.len or k - j <= indent:
            return # no body: a declaration or a type
          break
    of ',', ';':
      if depth == 0:
        return # a procedure type in a list
    else:
      discard
    inc i

func has(r: Routine, names: openArray[string]): bool =
  for p in r.pragmas:
    if p.name in names:
      return true

func firstStatement(code: string, body: int): string =
  var i = body
  while i < code.len and code[i] in {' ', '\n'}:
    inc i
  var j = i
  while j < code.len and code[j] != '\n':
    inc j
  code[i ..< j].strip

func isEntryCall(s: string): bool =
  for e in EntryCalls:
    if s == e or s.replace(" ", "") == e & "()":
      return true

proc lintText*(path, text: string, stats: var Stats): seq[Finding] =
  ## The findings in one file's text.
  let code = blank(text)
  inc stats.files
  # The `{.push.}` stack: whether each level makes procedures C-callable.
  var pushed: seq[bool]
  var i = 0
  while i < code.len:
    let c = code[i]
    if c == '`':
      # A quoted identifier (`method`, `=destroy`): never a keyword.
      inc i
      while i < code.len and code[i] notin {'`', '\n'}:
        inc i
      inc i
      continue
    if c == '{' and i + 1 < code.len and code[i + 1] == '.':
      var j = i + 2
      while j < code.len and code[j] == ' ':
        inc j
      let w = code.wordAt(j)
      if w in ["push", "pop"]:
        var e = j
        while e < code.len and
            not (code[e] == '.' and e + 1 < code.len and code[e + 1] == '}'):
          inc e
        if w == "push":
          var callable = false
          for p in code.pragmaItems(j + 4, e):
            if p.name in CallableWords:
              callable = true
          pushed.add callable
        elif pushed.len > 0:
          discard pushed.pop
        i = e + 2
        continue
    if c.isIdentStart and (i == 0 or not code[i - 1].isIdent) and
        (i == 0 or code[i - 1] != '.'):
      let w = code.wordAt(i)
      if w in RoutineWords:
        let r = code.routineAt(i, i + w.len)
        let name = if r.name.len > 0: r.name else: "an anonymous procedure"
        if r.body >= 0:
          let marked = r.has(MarkWords)
          let callable = marked or r.has(CallableWords) or true in pushed
          if callable and not r.has(["importc"]):
            inc stats.callable
            if marked:
              inc stats.marked
            else:
              var exempt = false
              for p in r.pragmas:
                if p.name in ExemptWords:
                  exempt = true
                  var reason = ""
                  if p.value[0] >= 0:
                    let v = text[p.value[0] ..< p.value[1]].strip
                    if v.len >= 2 and v[0] == '"' and v[^1] == '"':
                      reason = v[1 ..^ 2].strip
                  if reason.len == 0:
                    result.add Finding(
                      path: path,
                      line: text.lineOf(i),
                      name: name,
                      message: p.name & " needs its reason as a string literal",
                    )
                  elif p.name == "lcnNoNimHeap":
                    inc stats.noNimHeap
                  else:
                    inc stats.ownRuntime
              if not exempt:
                if code.firstStatement(r.body).isEntryCall:
                  inc stats.entries
                else:
                  result.add Finding(
                    path: path,
                    line: text.lineOf(i),
                    name: name,
                    message:
                      "C-callable and does not register its thread first: mark it " &
                      "{.lcnCallback.} or {.lcnModuleThread.}, start it with kitEnter() " &
                      "or bindingEnter(), or exempt it with {.lcnNoNimHeap: \"why\".} " &
                      "or {.lcnOwnRuntime: \"why\".} (DECISIONS G464-G467)",
                  )
        i += w.len
        continue
      if w == "Entered" and not path.replace('\\', '/').endsWith(EntryModule):
        var j = i + w.len
        while j < code.len and code[j] == ' ':
          inc j
        if j < code.len and code[j] == '[':
          var d = 0
          var e = j
          while e < code.len:
            if code[e] == '[':
              inc d
            elif code[e] == ']':
              dec d
              if d == 0:
                break
            inc e
          var k = e + 1
          while k < code.len and code[k] == ' ':
            inc k
          var castTo = false
          var b = i - 1
          while b >= 0 and code[b] == ' ':
            dec b
          if b >= 4 and code[b] == '[' and code[b - 4 .. b - 1] == "cast":
            castTo = true
          if castTo or (k < code.len and code[k] == '('):
            result.add Finding(
              path: path,
              line: text.lineOf(i),
              name: "Entered",
              message:
                "makes an Entered value without its check: use entered(p) " &
                "(DECISIONS G464)",
            )
        i += w.len
        continue
      i += max(w.len, 1)
      continue
    inc i

proc nimFiles(root: string): seq[string] =
  if fileExists(root):
    return @[root]
  try:
    for kind, p in walkDir(root):
      let name = p.extractFilename
      case kind
      of pcDir, pcLinkToDir:
        if name notin SkippedDirs and not name.startsWith("result"):
          result.add nimFiles(p)
      of pcFile, pcLinkToFile:
        if name.endsWith(".nim"):
          result.add p
  except OSError:
    discard
  result.sort()

proc lintPaths*(paths: openArray[string], stats: var Stats): seq[Finding] =
  ## The findings in every `.nim` file under `paths` (files or directories).
  for root in paths:
    for f in nimFiles(root):
      let text =
        try:
          readFile(f)
        except IOError:
          result.add Finding(path: f, line: 0, name: "", message: "cannot be read")
          continue
      result.add lintText(f, text, stats)

# The self-test --------------------------------------------------------------------

type Fixture = object
  name: string
  text: string
  flagged: seq[string] ## the names flagged, in order

const Fixtures = [
  Fixture(
    name: "a bare cdecl procedure",
    text: "proc onDone(p: pointer) {.cdecl.} =\n  echo \"done\"\n",
    flagged: @["onDone"],
  ),
  Fixture(
    name: "a noconv procedure",
    text: "proc onSig(s: cint) {.noconv.} =\n  discard\n",
    flagged: @["onSig"],
  ),
  Fixture(
    name: "an exportc procedure in nph's layout",
    text:
      "proc lcnThing(\n    a: cint\n): cint {.\n    exportc: \"lcn_thing\", dynlib\n.} =\n  a\n",
    flagged: @["lcnThing"],
  ),
  Fixture(
    name: "lcnNoNimHeap without a reason, and with an empty one",
    text:
      "proc a() {.cdecl, lcnNoNimHeap.} =\n  discard\n" &
      "proc b() {.cdecl, lcnNoNimHeap: \"  \".} =\n  discard\n" &
      "proc c() {.cdecl, lcnOwnRuntime: someConst.} =\n  discard\n",
    flagged: @["a", "b", "c"],
  ),
  Fixture(
    name: "a cdecl anonymous procedure in a field",
    text:
      "let v = Vtable(\n  call: proc(p: pointer) {.cdecl.} =\n    echo \"x\",\n  n: 1,\n)\n",
    flagged: @["an anonymous procedure"],
  ),
  Fixture(
    name: "callbackEnter first is not accepted: the mark is",
    text: "proc onEvent(p: pointer) {.cdecl.} =\n  callbackEnter()\n  echo \"x\"\n",
    flagged: @["onEvent"],
  ),
  Fixture(
    name: "kitEnter after another statement",
    text: "proc entry() {.exportc: \"e\", cdecl.} =\n  let x = 1\n  kitEnter()\n",
    flagged: @["entry"],
  ),
  Fixture(
    name: "procedures under a push of cdecl, then after its pop",
    text:
      "{.push cdecl, gcsafe.}\nproc inside() =\n  discard\n{.pop.}\n" &
      "proc outside() =\n  discard\n",
    flagged: @["inside"],
  ),
  Fixture(
    name: "a conversion and a cast to Entered",
    text:
      "let a = Entered[PostFn](raw)\nlet b = cast[Entered[PostFn]](raw)\n" &
      "proc ok(fn: Entered[PostFn], g: Entered[PostFn]) = discard\n",
    flagged: @["Entered", "Entered"],
  ),
  Fixture(
    name: "a generated template's procedures",
    text:
      "template exportThings*() =\n" &
      "  proc thingName(): cstring {.exportc: \"thing_name\", dynlib, cdecl, gcsafe, raises: [].} =\n" &
      "    system.cstring(\"thing\")\n" &
      "  proc thingInit(): cint {.exportc: \"thing_init\", dynlib, cdecl.} =\n" &
      "    kitEnter()\n    0\n",
    flagged: @["thingName"],
  ),
  Fixture(
    name: "accepted: the marks, the exemptions and the entries",
    text:
      "proc onA(p: pointer) {.lcnCallback.} =\n  echo \"a\"\n" &
      "proc onB(p: pointer) {.lcnModuleThread.} =\n  echo \"b\"\n" &
      "proc relC(s: pointer) {.cdecl, lcnNoNimHeap: \"the C allocator only\".} =\n  cFree(s)\n" &
      "proc tlsD(s: pointer): cint {.cdecl, lcnOwnRuntime: \"a TLS callback\".} =\n  0\n" &
      "proc entE(): cint {.exportc: \"e\", cdecl.} =\n  ## Doc.\n  ##\n  # note\n\n  kitEnter()\n  0\n" &
      "proc opF(b: pointer) {.cdecl.} =\n  bindingEnter()\n" &
      "proc plain(x: int): int =\n  x\n",
    flagged: @[],
  ),
  Fixture(
    name: "accepted: declarations, types and procedure-typed values",
    text:
      "proc lcnZero(\n  p: pointer, n: csize_t\n) {.importc: \"lcn_zero\", cdecl, noSideEffect.}\n" &
      "proc one(): cint {.importc: \"one\", cdecl.}\n  ## its doc\n" &
      "proc fwd(a: cint) {.cdecl.}\n" &
      "type\n  PostFn* = proc(payload: pointer) {.cdecl, gcsafe, raises: [].}\n" &
      "  Pair = (proc() {.cdecl.}, int)\n" & "var cb: proc() {.cdecl.} = nil\n" &
      "proc take(fn: proc(p: pointer) {.cdecl.}, n: int) =\n  discard\n" &
      "proc opt(fn: proc() {.cdecl.} = nil) =\n  discard\n" &
      "proc generic[P: proc](p: P) =\n  discard\n" & "let x = a == b\n",
    flagged: @[],
  ),
  Fixture(
    name: "accepted: code inside comments, strings and character literals",
    text:
      "# proc a() {.cdecl.} =\n#   discard\n" & "#[ proc b() {.cdecl.} =\n  discard ]#\n" &
      "let s = \"proc c() {.cdecl.} = discard\"\n" &
      "let t = \"\"\"\nproc d() {.cdecl.} =\n  discard\n\"\"\"\n" &
      "let u = r\"proc e() {.cdecl.} = \"\"x\"\"\"\n" &
      "let q = '\"'\nlet n = 1'u8\nlet w = ident\"cdecl\"\n" &
      "let e2 = \"\\\"proc f() {.cdecl.} =\"\n",
    flagged: @[],
  ),
]

proc selfTest*(): seq[string] =
  ## Each fixture's verdict; a list of the ones that changed.
  for f in Fixtures:
    var stats: Stats
    var got: seq[string]
    for x in lintText("fixture.nim", f.text, stats):
      got.add x.name
    if got != f.flagged:
      result.add f.name & ": flagged " & $got & ", expected " & $f.flagged

{.pop.}
