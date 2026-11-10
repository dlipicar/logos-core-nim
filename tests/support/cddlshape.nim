## Mirrored spec CDDL (the CBOR object definitions of HASH and COMMITMENT) as a
## shape checker for tests: integer-keyed maps with optional keys, choices,
## `[* T]`, text literals, integer ranges and the few primitives those specs use.
## Independent of `logos_core/cddl`, which implements only the cdCDDLe subset for
## module schemas.

import std/[sequtils, sets, strutils, tables]
import ../../src/logos_core/cbor
import ./specdata

type Shapes* = object
  maps: Table[string, seq[(string, bool)]]
    ## rule -> (type text, optional) of keys 0, 1, ...
  choices: Table[string, seq[string]] ## rule -> alternatives (aliases have one)
  opaque*: HashSet[string] ## rules accepted as any map (checked elsewhere)

proc stripComment(s: string): string =
  let i = s.find(';')
  (if i >= 0: s[0 ..< i] else: s).strip

proc loadShapes*(files: openArray[string]): Shapes =
  ## The rules of the mirrored files; a later file's rule replaces an earlier one.
  var sh: Shapes
  for f in files:
    var
      name = ""
      body: seq[string]
    proc flush(sh: var Shapes) =
      if name.len == 0:
        return
      let text = body.join(" ").strip
      if text.startsWith("{"):
        var keys: seq[(string, bool)]
        for line in body:
          var l = line.strip.strip(chars = {','})
          let optional = l.startsWith("?")
          if optional:
            l = l[1 .. ^1].strip
          let colon = l.find(':')
          if colon > 0 and l[0 ..< colon].allIt(it.isDigit):
            doAssert parseInt(l[0 ..< colon]) == keys.len, name
            keys.add((l[colon + 1 .. ^1].strip, optional))
        sh.maps[name] = keys
        sh.choices.del(name)
      else:
        sh.choices[name] = text.split(" / ").mapIt(it.strip).filterIt(it.len > 0)
        sh.maps.del(name)

    for raw in mirror(f).splitLines:
      let line = stripComment(raw)
      if raw.len > 0 and raw[0] notin {' ', '}'} and '=' in line:
        sh.flush()
        let eq = line.find('=')
        name = line[0 ..< eq].strip
        body = @[line[eq + 1 .. ^1].strip]
      elif line.len > 0:
        body.add(line)
    sh.flush()
  sh

proc has*(sh: Shapes, rule: string): bool =
  rule in sh.maps or rule in sh.choices

proc alternatives*(sh: Shapes, rule: string): seq[string] =
  ## A choice rule's alternatives, as written.
  sh.choices.getOrDefault(rule)

proc keyTypes*(sh: Shapes, rule: string): seq[string] =
  ## A map rule's value types for keys 0, 1, ..., as written.
  sh.maps.getOrDefault(rule).mapIt(it[0])

proc conforms*(sh: Shapes, v: CborValue, typ: string): bool =
  let t = typ.strip
  if " / " in t and not t.startsWith("\""):
    # an inline choice, e.g. `1: normalized-value-root / value-node`
    return t.split(" / ").anyIt(sh.conforms(v, it))
  if t.startsWith("\""):
    return v.kind == ckText and v.text == t[1 ..^ 2]
  if t.startsWith("[*") and t.endsWith("]"):
    return v.kind == ckArray and v.items.allIt(sh.conforms(it, t[2 ..^ 2]))
  if ".." in t:
    let bounds = t.split("..")
    let i = v.getInt64
    return
      i.isSome and i.get >= parseBiggestInt(bounds[0]) and
      i.get <= parseBiggestInt(bounds[1])
  case t
  of "tstr":
    return v.kind == ckText and v.validUtf8
  of "bstr":
    return v.kind == ckBytes
  of "bool":
    return v.isBool
  of "uint .size 8":
    return v.kind == ckUint
  else:
    discard
  if t in sh.maps:
    let keys = sh.maps[t]
    if v.kind != ckMap:
      return false
    var present = 0
    for i, (k, optional) in keys:
      let x = v.lookup(uint64(i))
      if x.isNone:
        if not optional:
          return false
      elif not sh.conforms(x.get, k):
        return false
      else:
        inc present
    return v.entries.len == present
  if t in sh.choices:
    return sh.choices[t].anyIt(sh.conforms(v, it))
  if t in sh.opaque:
    return v.kind == ckMap
  raiseAssert "no mirrored rule " & t
