## Strict UTF-8 check (RFC 3629): no overlong forms, no surrogates, nothing
## above U+10FFFF.

{.push raises: [].}

func isValidUtf8*(s: openArray[byte]): bool =
  var i = 0
  while i < s.len:
    let c = s[i]
    if c < 0x80:
      inc i
      continue
    var
      need: int
      lo = 0x80'u8
      hi = 0xbf'u8
    if c >= 0xc2 and c <= 0xdf:
      need = 1
    elif c == 0xe0:
      need = 2
      lo = 0xa0
    elif c >= 0xe1 and c <= 0xec or c == 0xee or c == 0xef:
      need = 2
    elif c == 0xed:
      need = 2
      hi = 0x9f
    elif c == 0xf0:
      need = 3
      lo = 0x90
    elif c >= 0xf1 and c <= 0xf3:
      need = 3
    elif c == 0xf4:
      need = 3
      hi = 0x8f
    else:
      return false
    if i + need > s.len - 1:
      return false
    let second = s[i + 1]
    if second < lo or second > hi:
      return false
    for k in 2 .. need:
      if (s[i + k] and 0xc0) != 0x80:
        return false
    i += need + 1
  true

func isValidUtf8*(s: string): bool =
  isValidUtf8(s.toOpenArrayByte(0, s.high))
