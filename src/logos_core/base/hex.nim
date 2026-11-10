## Lowercase hexadecimal, as the specs write digests and CBOR vectors.

{.push raises: [].}

import results

export results

const hexDigits = "0123456789abcdef"

func toHex*(data: openArray[byte]): string =
  var s = newString(data.len * 2)
  for i, b in data:
    s[2 * i] = hexDigits[int(b shr 4)]
    s[2 * i + 1] = hexDigits[int(b and 0x0f)]
  s

func nibble(c: char): Opt[byte] =
  case c
  of '0' .. '9':
    Opt.some(byte(ord(c) - ord('0')))
  of 'a' .. 'f':
    Opt.some(byte(ord(c) - ord('a') + 10))
  of 'A' .. 'F':
    Opt.some(byte(ord(c) - ord('A') + 10))
  else:
    Opt.none(byte)

func fromHex*(s: string): Result[seq[byte], string] =
  ## Accepts an even number of hex digits, either case, nothing else.
  if s.len mod 2 != 0:
    return err("odd number of hex digits")
  var bytes = newSeq[byte](s.len div 2)
  for i in 0 ..< bytes.len:
    let
      hi = nibble(s[2 * i]).valueOr:
        return err("invalid hex digit at " & $(2 * i))
      lo = nibble(s[2 * i + 1]).valueOr:
        return err("invalid hex digit at " & $(2 * i + 1))
    bytes[i] = (hi shl 4) or lo
  ok(bytes)
