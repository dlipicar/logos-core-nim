## The free scan of the erasure tests (Tier 4b step 4b-3b plan §4.1; DECISIONS
## I92) [IMPL]: test support under the test-hook rule (`testhooks.nim`).
##
## 1. Everything here exists only under `when defined(lcnWipeAudit)`.
## 2. Only test builds set the define: `tests/test_wipe.nims`, and the audit
##    variants of the Module Host and the kits that the tests build for it.
## 3. `testHooksMarker("wipeaudit")` puts the test-hook marker in every binary
##    built with the define.
## 4. The scanner is inert until armed: in a test process by `armWipeAudit`,
##    in an audit-build Module Host by the Runtime's carrier `init`, which
##    carries patterns only after a test's `setWipeAuditForTests`.
##
## The audit build renames `free` and `realloc` in all the C it compiles
## (`wipeaudit.c`). The scan sees the Nim heap only with `-d:useMalloc` under
## orc or arc: refc's heap never reaches `free` (`wipeAuditScans`).

{.used.}

when defined(lcnWipeAudit):
  {.push raises: [], gcsafe.}

  import ./testhooks

  testHooksMarker("wipeaudit")

  {.passc: "-Dfree=lcn_wipe_free -Drealloc=lcn_wipe_realloc".}
  {.compile: "wipeaudit.c".}

  proc lcnWipeSupported(): cint {.importc: "lcn_wipe_supported", cdecl.}
  proc lcnWipeArm(
    patterns: ptr byte, lens: ptr csize_t, count: cint
  ) {.importc: "lcn_wipe_arm", cdecl.}

  proc lcnWipeDisarm() {.importc: "lcn_wipe_disarm", cdecl.}
  proc lcnWipeHits(): clong {.importc: "lcn_wipe_hits", cdecl.}
  proc lcnWipeScan(p: pointer, n: csize_t): cint {.importc: "lcn_wipe_scan", cdecl.}
  proc lcnWipeReport(fd: cint) {.importc: "lcn_wipe_report", cdecl.}

  const
    MinPattern* = 16
    MaxPattern* = 64
    MaxPatterns* = 8

  proc wipeAuditScans*(): bool =
    ## Whether released blocks are scanned in this build: the Nim heap reaches
    ## `free` only with `-d:useMalloc` under orc or arc, and not on Windows.
    when defined(useMalloc) and defined(gcDestructors):
      lcnWipeSupported() != 0
    else:
      false

  proc zeroed(s: var seq[byte]) =
    # Released after arming: zeroed first, or the scanner finds its own copy.
    # The release is an opaque call that reads the block, so this is kept.
    if s.len > 0:
      zeroMem(addr s[0], s.len)

  proc armWipeAudit*(patterns: sink seq[seq[byte]]) =
    ## Searches every block released from now on for `patterns` (16 to 64
    ## bytes each, at most `MaxPatterns`), and clears the hits. `patterns` is
    ## taken: its copies are zeroed once registered.
    var
      patterns = patterns
      flat = newSeqOfCap[byte](MaxPatterns * MaxPattern)
      lens: seq[csize_t]
    for p in patterns:
      doAssert p.len in MinPattern .. MaxPattern,
        "a wipe-audit pattern is 16 to 64 bytes"
      flat.add(p)
      lens.add(csize_t(p.len))
    doAssert lens.len in 1 .. MaxPatterns, "1 to 8 wipe-audit patterns"
    lcnWipeArm(addr flat[0], addr lens[0], cint(lens.len))
    zeroed(flat)
    for p in patterns.mitems:
      zeroed(p)

  proc disarmWipeAudit*() =
    lcnWipeDisarm()

  proc wipeAuditHits*(): int =
    ## Blocks released holding a pattern since the scanner was armed.
    int(lcnWipeHits())

  proc wipeAuditFinds*(p: pointer, n: int): int =
    ## Patterns found in a live region of `n` bytes.
    if p == nil or n <= 0:
      0
    else:
      int(lcnWipeScan(p, csize_t(n)))

  proc wipeAuditFinds*(s: openArray[byte]): int =
    if s.len == 0:
      0
    else:
      wipeAuditFinds(unsafeAddr s[0], s.len)

  proc reportWipeAudit*(fd: cint = 2) =
    ## Writes a backtrace per recorded hit (the first 16) to `fd`.
    lcnWipeReport(fd)

  {.pop.}
