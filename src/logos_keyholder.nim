## `logos_keyholder`: the key holder of logosd's `remote.signing = "key-holder"`
## (Tier 5 step 5-7a-1; DECISIONS G410). logosd starts it; run any other way
## it exits 2. On Windows there is no remote side here: the program says so and
## exits 2.

when defined(windows):
  try:
    stderr.writeLine(
      "logos_keyholder: the remote profiles are not supported on this platform"
    )
  except IOError:
    discard
  quit(2)
else:
  import logos_core/daemon/keyholder

  runKeyHolder()
