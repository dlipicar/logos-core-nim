## The local-transport parity pass (step 4b-2c; DECISIONS I90): `test_events`
## with the meter and sensor providers routed over local transport
## (`support/routefixture`). Transported routes are POSIX-only (TRANSPORT
## §8.2.1): elsewhere the suite compiles and skips.

import ../src/logos_core/transport/io/sock

when unixStream:
  const transportParity = true
  include ./test_events
else:
  import unittest2

  suite "local-transport parity":
    test "unix-stream is not available on this platform":
      skip()
