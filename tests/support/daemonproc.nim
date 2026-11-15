## logosd and logosctl as child processes, for `test_logosd` (Tier 4b step
## 4b-6; plan §4.4). Spawned with `posix_spawn`, never `fork`; stdout and
## stderr go to files in the case's directory, so a chatty child never
## blocks. Every pid is registered: `killAll` (and an exit procedure, if the
## test process dies) ends what is left with SIGKILL.

import std/[exitprocs, monotimes, os, posix, strutils, times]

var environ {.importc.}: cstringArray

type
  Child* = object
    pid*: Pid
    outPath*, errPath*: string

  Ran* = object ## A finished one-shot run.
    code*: int
    stdout*, stderr*: string

var running: seq[Pid]

proc killAll*() =
  for pid in running:
    discard kill(pid, SIGKILL)
    var status: cint
    discard waitpid(pid, status, 0)
  running = @[]

addExitProc(killAll)

proc envWith(overrides: openArray[(string, string)]): seq[string] =
  var i = 0
  while environ[i] != nil:
    let kv = $environ[i]
    var keep = true
    for (k, _) in overrides:
      if kv.startsWith(k & "="):
        keep = false
    if keep:
      result.add(kv)
    inc i
  for (k, v) in overrides:
    result.add(k & "=" & v)
  when defined(asan) and compileOption("mm", "refc"):
    # A refc child under ASan: no stack-use-after-return detection (plan §4).
    var found = false
    for j in 0 ..< result.len:
      if result[j].startsWith("ASAN_OPTIONS="):
        result[j].add(":detect_stack_use_after_return=0")
        found = true
    if not found:
      result.add("ASAN_OPTIONS=detect_stack_use_after_return=0")

proc spawnChild*(
    exe: string,
    args: openArray[string],
    dir, name: string,
    env: openArray[(string, string)] = [],
): Child =
  ## Runs `exe args` with stdout and stderr in `dir/name.out` and `.err`.
  result.outPath = dir / (name & ".out")
  result.errPath = dir / (name & ".err")
  var fa: Tposix_spawn_file_actions
  doAssert posix_spawn_file_actions_init(fa) == 0
  doAssert posix_spawn_file_actions_addopen(
    fa, 1, cstring(result.outPath), O_WRONLY or O_CREAT or O_TRUNC, 0o600
  ) == 0
  doAssert posix_spawn_file_actions_addopen(
    fa, 2, cstring(result.errPath), O_WRONLY or O_CREAT or O_TRUNC, 0o600
  ) == 0
  var attr: Tposix_spawnattr
  doAssert posix_spawnattr_init(attr) == 0
  var all = @[exe]
  all.add(@args)
  let argv = allocCStringArray(all)
  let envp = allocCStringArray(envWith(env))
  let r = posix_spawn(result.pid, cstring(exe), fa, attr, argv, envp)
  deallocCStringArray(argv)
  deallocCStringArray(envp)
  discard posix_spawn_file_actions_destroy(fa)
  discard posix_spawnattr_destroy(attr)
  doAssert r == 0, "posix_spawn " & exe & ": " & $strerror(r)
  running.add(result.pid)

func exitOf(status: cint): int =
  if WIFEXITED(status):
    int(WEXITSTATUS(status))
  elif WIFSIGNALED(status):
    128 + int(WTERMSIG(status))
  else:
    -1

proc forget(pid: Pid) =
  let i = running.find(pid)
  if i >= 0:
    running.del(i)

proc waitExit*(c: Child, timeoutMs: int): int =
  ## The exit code, or -1 if the child still runs at the deadline.
  let until = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while true:
    var status: cint
    let r = waitpid(c.pid, status, WNOHANG)
    if r == c.pid:
      forget(c.pid)
      return exitOf(status)
    if r < 0:
      forget(c.pid)
      return -1
    if getMonoTime() >= until:
      return -1
    sleep(10)

proc alive*(c: Child): bool =
  var status: cint
  waitpid(c.pid, status, WNOHANG) == 0

proc stopChild*(c: Child, timeoutMs: int): int =
  ## SIGTERM, then SIGKILL after `timeoutMs`: the exit code.
  discard kill(c.pid, SIGTERM)
  result = waitExit(c, timeoutMs)
  if result < 0:
    discard kill(c.pid, SIGKILL)
    result = waitExit(c, timeoutMs)

proc killChild*(c: Child) =
  discard kill(c.pid, SIGKILL)
  discard waitExit(c, 10_000)

proc errText*(c: Child): string =
  try:
    readFile(c.errPath)
  except IOError:
    ""

proc outText*(c: Child): string =
  try:
    readFile(c.outPath)
  except IOError:
    ""

var runs = 0

proc runOnce*(
    exe: string,
    args: openArray[string],
    dir: string,
    env: openArray[(string, string)] = [],
    timeoutMs = 60_000,
): Ran =
  ## A one-shot child to its end (killed at the deadline: code -1).
  inc runs
  let c = spawnChild(exe, args, dir, "run" & $runs, env)
  result.code = waitExit(c, timeoutMs)
  if result.code < 0:
    killChild(c)
  result.stdout = c.outText
  result.stderr = c.errText
