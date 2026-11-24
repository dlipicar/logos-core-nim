## `logos_remote`: the remote program (Tier 5 step 5-7a-2; DECISIONS G411;
## 5-7a plan §3.1). logosd starts it with a role and its own pid; run any
## other way it exits 2. 5-7a-2 builds the listener role
## (`logos_core/remote/listener.nim`); 5-7a-4 adds the target role. On Windows
## logosd does not start (TRANSPORT l.1133): the program says so and exits 2.

when defined(windows):
  try:
    stderr.writeLine(
      "logos_remote: the remote profiles are not supported on this platform"
    )
  except IOError:
    discard
  quit(2)
else:
  import logos_core/remote/listener

  runRemote()
