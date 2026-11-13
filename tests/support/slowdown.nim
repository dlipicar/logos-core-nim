## How much slower a sanitizer build runs [IMPL]: its instrumented code, such
## as the byte-by-byte copies and checks of multi-MiB transport payloads, and
## its slower thread hand-offs on a loaded host. A bound that only limits how
## long a test waits for something that will happen, or how long a flush may
## take, is multiplied by it; a deadline a test is about is not. Shared by the
## route, Capability Authority and transport fixtures.

const Slow* =
  when defined(tsan):
    10
  elif defined(asan) or defined(msan):
    3
  else:
    1
