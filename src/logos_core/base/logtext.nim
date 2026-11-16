## Text bound for a log line or a diagnostic (I95, amended 2026-11-16; DAEMON.md
## §12). A line is one line: no character in it can end it, start another or
## move a terminal's cursor. Text the Runtime did not write is also cut to a
## bound and named by the instance that supplied it, since it is that instance's
## word and no evidence of another's identity (BCP l.551).

{.push raises: [], gcsafe.}

const ForeignTextLimit* = 256
  ## [IMPL] the bytes kept of text the Runtime did not write, in one diagnostic

func oneLine*(s: string): string =
  ## `s` with each control character replaced by a space: C0 (a line break
  ## included), DEL, and C1 (U+0080 to U+009F, which some terminals obey).
  result = newString(s.len)
  var n = 0
  var i = 0
  while i < s.len:
    let b = byte(s[i])
    if b < 0x20 or b == 0x7f:
      result[n] = ' '
      inc n
      inc i
    elif b == 0xc2 and i + 1 < s.len and byte(s[i + 1]) in 0x80'u8 .. 0x9f'u8:
      result[n] = ' '
      inc n
      i += 2
    else:
      result[n] = s[i]
      inc n
      inc i
  result.setLen(n)

func capped*(s: string, limit: int): string =
  ## `s` cut to at most `limit` bytes at a UTF-8 boundary, with "..." added
  ## when anything was cut.
  if s.len <= limit:
    return s
  var cut = max(limit - 3, 0)
  while cut > 0 and (byte(s[cut]) and 0xc0) == 0x80:
    dec cut
  s[0 ..< cut] & "..."

func supplied*(text, by: string): string =
  ## Text `by` supplied, in a diagnostic: one line, at most
  ## `ForeignTextLimit` bytes, quoted, and attributed.
  "\"" & capped(oneLine(text), ForeignTextLimit) & "\" (text from " & oneLine(by) & ")"

{.pop.}
