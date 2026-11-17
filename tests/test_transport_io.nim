## The unix-stream transport I/O layer over real sockets (TRANSPORT §2.1, §2.3,
## §3.1, §4, §5, §6, §8.1, §8.2, §8.6, §9.1; G58, G61, G77). The cases are in
## `transport_io_body.nim`. They need POSIX sockets and descriptors, and
## unix-stream is POSIX-only until 5-9 (TRANSPORT §8.2.1, G107): elsewhere the
## suite compiles and skips (G334).

import ../src/logos_core/transport/io/sock

when unixStream:
  include ./transport_io_body
else:
  import unittest2

  suite "unix-stream transport I/O":
    test "unix-stream is not available on this platform":
      skip()
