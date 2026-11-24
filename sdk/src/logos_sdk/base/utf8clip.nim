## Text cut to a byte bound at a UTF-8 boundary, so text that reaches a tstr
## stays valid UTF-8: every clip helper in the SDK and core calls `clipUtf8`
## (DECISIONS I135). A module of its own, not `cbor/utf8`: `logos_sdk/cbor`
## re-exports that one, and a new export there made Nim 2.2.14 resolve the
## `encode` that `authority/facts.nim` takes from `kit/rc_types` to the module
## `cbor/encode` instead.

{.push raises: [].}

func utf8Cut*(s: openArray[char], n: int): int =
  ## [IMPL] The length of the longest prefix of `s` that has at most `n` bytes
  ## and does not end inside a UTF-8 sequence: `s.len` when that fits, else `n`
  ## moved back over the continuation bytes (`10xxxxxx`) at the cut. A valid
  ## string cut there stays valid.
  if s.len <= n:
    return s.len
  result = max(n, 0)
  while result > 0 and (uint8(s[result]) and 0xc0'u8) == 0x80'u8:
    dec result

func clipUtf8*(s: string, n: int): string =
  ## `s` cut to at most `n` bytes at a UTF-8 boundary (`utf8Cut`).
  if s.len <= n:
    s
  else:
    s[0 ..< utf8Cut(s, n)]

func clipUtf8InPlace*(s: var string, n: int) =
  ## As `clipUtf8`, shortening `s` itself: the cut tail stays in its capacity,
  ## where a wipe of `s` still reaches it (DECISIONS G276).
  s.setLen(utf8Cut(s, n))
