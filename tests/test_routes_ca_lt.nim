## The local-transport parity pass under a Capability Authority (step 4b-2;
## DECISIONS I85, I90): `test_routes` with the authority bound and the meter and
## sensor providers routed over local transport (`support/routefixture`).
## Transported routes are POSIX-only (TRANSPORT §8.2.1): elsewhere the suite
## compiles and skips.

import ../src/logos_core/transport/io/sock

when unixStream:
  const caParity = true
  const transportParity = true
  include ./test_routes
else:
  import unittest2

  suite "local-transport parity":
    test "unix-stream is not available on this platform":
      skip()
