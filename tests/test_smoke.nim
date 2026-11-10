## Phase 0 smoke test: the build wiring works under every memory manager.

import unittest2
import ../src/logos_core

suite "smoke":
  test "hex round trip":
    let data = @[byte 0x00, 0x7f, 0x80, 0xff]
    check data.toHex == "007f80ff"
    check fromHex("007F80ff").get == data
    check fromHex("0g").isErr
    check fromHex("abc").isErr

  test "vendored BLAKE3 is linked":
    check blake3Version() == "1.8.7"
    # BLAKE3("") from the reference test vectors.
    check blake3(newSeq[byte]()).toHex ==
      "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
