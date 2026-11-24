## [DECISIONS I147] The tests' one way to signal or wait on a process they
## started. A pid of 1 or less fails the test and nothing is sent: kill(-1)
## reaches every process the user owns, kill(0) the test's own process group,
## and kill(1) is init's; waitpid(-1) reaps any child. A spawn that left its
## pid at -1 then fails one test instead of ending the user's session, as a
## stale declaration of `hostspawn.c`'s spawn did twice.

when defined(posix):
  import std/posix

  proc requirePid*(pid: SomeInteger, what = "signal") =
    ## Fails the test (an AssertionDefect, raised in any context) unless
    ## `pid` is above 1.
    if int64(pid) <= 1:
      raiseAssert "refused to " & what & " pid " & $pid &
        ": no process was started [I147]"

  proc signalPid*(pid: SomeInteger, sig: cint): cint =
    ## `kill(pid, sig)`.
    requirePid(pid)
    kill(Pid(pid), sig)

  proc signalPidGroup*(leader: SomeInteger, sig: cint): cint =
    ## `kill(-leader, sig)`: the process group `leader`'s spawn made.
    requirePid(leader, "signal the process group of")
    kill(Pid(-int64(leader)), sig)

  proc pidGone*(pid: SomeInteger): bool =
    ## `pid` no longer exists (ESRCH).
    signalPid(pid, 0) != 0 and errno == ESRCH
