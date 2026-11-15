## The logosctl shell's output (Tier 4b step 4b-6; DECISIONS G89, U2).
## docs/DAEMON.md §7.
##
## JSON is one object per command: `{"deployment", "command", "status":
## "ok"|"error", ? "code", ? "message", ? "request_key", ? "result"}`.
## Results are rendered from their CBOR as G89 says: maps keyed by text (any
## other key by its diagnostic notation), byte strings as lowercase hex,
## integers outside ±2^53 as decimal strings, a tag as `{"tag", "value"}`, a
## float by its diagnostic notation. Configuration values, schemas and the
## daemon-config also carry a `"diag"` member beside their hex.
##
## Text is tables and diagnostic notation. Anything a publisher supplied (a
## `reason`) is quoted and labelled "(declared)", never shown as an
## identifier (BOOTSTRAP l.381).

{.push raises: [].}

import std/[json, strutils]
import results
import ../cbor
import ../base/hex

export json

const JsonSafe = 9_007_199_254_740_992'u64 ## 2^53

proc jsonOf*(v: CborValue): JsonNode =
  ## [G89] A CBOR value as JSON.
  case v.kind
  of ckUint:
    if v.uint > JsonSafe:
      newJString($v.uint)
    else:
      newJInt(BiggestInt(v.uint))
  of ckNint:
    # The value is -1 - nint.
    if v.nint >= JsonSafe:
      if v.nint == high(uint64):
        newJString("-18446744073709551616")
      else:
        newJString("-" & $(v.nint + 1))
    else:
      newJInt(-BiggestInt(v.nint) - 1)
  of ckBytes:
    newJString(toHex(v.bytes).toLowerAscii)
  of ckText:
    newJString(v.text)
  of ckArray:
    var a = newJArray()
    for x in v.items:
      a.add(jsonOf(x))
    a
  of ckMap:
    var o = newJObject()
    for (k, x) in v.entries:
      let key =
        if k.kind == ckText:
          k.text
        else:
          toDiag(k)
      o[key] = jsonOf(x)
    o
  of ckTag:
    %*{"tag": jsonOf(cbor(v.tag)), "value": jsonOf(v.content)}
  of ckSimple:
    case v.simple
    of SimpleFalse:
      newJBool(false)
    of SimpleTrue:
      newJBool(true)
    of SimpleNull:
      newJNull()
    else:
      %*{"simple": int(v.simple)}
  of ckFloat:
    newJString(toDiag(v))

proc jsonOfBytes*(bytes: openArray[byte]): JsonNode =
  ## A response's bytes as JSON; bytes that do not decode as their hex.
  let v = decodeCbor(bytes)
  if v.isErr:
    return %*{"hex": toHex(bytes).toLowerAscii}
  jsonOf(v.get)

proc valueJson*(bytes: openArray[byte]): JsonNode =
  ## A configuration value, schema or daemon-config: hex and diag.
  var o = %*{"hex": toHex(bytes).toLowerAscii}
  let v = decodeCbor(bytes)
  if v.isOk:
    o["diag"] = newJString(toDiag(v.get))
  o

proc diagOf*(bytes: openArray[byte]): string =
  let v = decodeCbor(bytes)
  if v.isErr:
    return "h'" & toHex(bytes).toLowerAscii & "'"
  toDiag(v.get)

proc envelope*(
    deployment, command: string, ok: bool, code = "", message = "", requestKey = ""
): JsonNode =
  result = %*{
    "deployment": deployment, "command": command, "status": (if ok: "ok" else: "error")
  }
  if code.len > 0:
    result["code"] = newJString(code)
  if message.len > 0:
    result["message"] = newJString(message)
  if requestKey.len > 0:
    result["request_key"] = newJString(requestKey)

proc withResult*(env: JsonNode, r: JsonNode): JsonNode =
  if not r.isNil:
    env["result"] = r
  env

# Text ---------------------------------------------------------------------------------

func declaredText*(reason: string): string =
  ## [BCP l.381] Publisher-supplied text, quoted and labelled.
  escapeJson(reason) & " (declared)"

func table*(header: openArray[string], rows: openArray[seq[string]]): string =
  ## Left-aligned columns, two spaces apart.
  var widths = newSeq[int](header.len)
  for i, h in header:
    widths[i] = h.len
  for r in rows:
    for i, c in r:
      if i < widths.len:
        widths[i] = max(widths[i], c.len)
  proc line(cells: openArray[string]): string =
    for i, c in cells:
      if i > 0:
        result.add("  ")
      if i == cells.high:
        result.add(c)
      else:
        result.add(c.alignLeft(widths[i]))

  result = line(header)
  for r in rows:
    result.add("\n" & line(r))

func field*(v: CborValue, key: string): Opt[CborValue] =
  if v.kind != ckMap:
    return Opt.none(CborValue)
  v.lookup(key)

func textField*(v: CborValue, key: string, absent = "-"): string =
  let f = v.field(key)
  if f.isNone:
    return absent
  let x = f.get
  case x.kind
  of ckText:
    x.text
  of ckUint:
    $x.uint
  of ckMap:
    # A choice rendered as a one-entry map or a { kind } map.
    let k = x.lookup("kind")
    if k.isSome and k.get.kind == ckText:
      k.get.text
    else:
      toDiag(x)
  else:
    toDiag(x)

{.pop.}
