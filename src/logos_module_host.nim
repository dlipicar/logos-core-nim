## `logos-module-host`: the Module Host program (Tier 4b step 4b-3; DECISIONS
## G264; plan §2.2). A Module Loader starts it, one process per hosted
## realization; run any other way it exits 2. On Windows hosted placement is
## not supported (G107): the program says so and exits 2.

when defined(windows):
  try:
    stderr.writeLine(
      "logos-module-host: hosted placement is not supported on this platform"
    )
  except IOError:
    discard
  quit(2)
else:
  import logos_core/host/main

  runHost()
