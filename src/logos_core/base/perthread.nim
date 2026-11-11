## Immutable tables that each thread loads once [IMPL].
##
## The library keeps parsed schemas, the pinned common schema and similar
## derived tables for the life of the process. Under ORC, reading a shared
## `ref` from several threads changes its reference count without
## synchronization, and under refc every thread has its own heap; neither allows
## one table to be read by concurrent provider calls (INTERFACE §2.8). Each
## thread therefore loads its own copy on first use and keeps it in
## thread-local storage. Loading is deterministic, so every copy is equal.
##
## A thread the Nim runtime did not create must call `setupForeignThreadGc`
## before its first allocation, under every memory manager: under ORC Nim
## 2.2.14 gives each thread its own allocator region and a C thread has none
## until then (its first allocation crashes). The module kit's entry points and
## the Runtime's bindings call it, then `enterThread`.
##
## Thread-local storage holds the only reference to a thread's tables, so they
## are released when the thread ends [IMPL]:
## - A thread Nim started releases them in its destruction handler, which runs
##   while the thread still owns its allocator region.
## - Under ORC, any other thread releases them in a thread-exit hook
##   (`thread_exit.c`), collects cycles and then gives its allocator region
##   back. The hook also runs on Nim's threads, after Nim gave the region back,
##   where it only frees the handler list.
## - Under refc a C thread keeps them unless it calls `releasePerThread` last.
## - The thread that ran this module's initialization keeps them: it may be the
##   process's main thread, and its hook would run during process exit.

{.push raises: [].}

{.compile: "thread_exit.c".}

type Release* = proc() {.nimcall, gcsafe, raises: [].}

var
  releases {.threadvar.}: seq[Release]
  pending {.threadvar.}: int # `releases.len`, readable without the heap
  hooked {.threadvar.}: bool
  initThread {.threadvar.}: bool
  nimEnded {.threadvar.}: bool # Nim ran this thread's destruction handlers

initThread = true

proc lcnOnThreadExit(
  fn: proc() {.cdecl, gcsafe, raises: [].}
): cint {.importc: "lcn_on_thread_exit", cdecl.}

proc releasePerThread*() {.gcsafe.} =
  ## Frees this thread's tables. A later use loads them again. Under ORC it then
  ## collects cycles: the collector's per-thread root buffer is freed only by a
  ## collection that leaves it empty.
  for i in countdown(releases.high, 0):
    releases[i]()
  releases = @[]
  pending = 0
  when defined(gcOrc):
    GC_fullCollect()

proc releaseAtNimThreadEnd() {.gcsafe, raises: [].} =
  releasePerThread()
  nimEnded = true

proc releaseAtThreadExit() {.cdecl, gcsafe, raises: [].} =
  # On a C thread this always runs, tables or not: the cycle collector's root
  # buffer is allocated by any call that drops a possibly cyclic reference, and
  # only a collection frees it (upstream draft 10). On a Nim thread the handler
  # already did, and the allocator region is gone.
  if not nimEnded:
    releasePerThread()
  # The handler list `onThreadDestruction` added to: Nim runs it but never frees
  # it, and never runs it on a thread it did not start (upstream draft 11).
  nimThreadDestructionHandlers = @[]
  # A C thread's allocator region goes back to the pool; on a Nim thread it
  # already has, and this does nothing.
  when declared(tearDownForeignThreadGc):
    tearDownForeignThreadGc()

proc enterThread*() {.gcsafe.} =
  ## Arranges this thread's release when it ends; cheap after the first call.
  ## Every entry from a thread this library may not have started calls it, after
  ## `setupForeignThreadGc`.
  if hooked or initThread:
    return
  hooked = true
  onThreadDestruction(releaseAtNimThreadEnd)
  when defined(gcDestructors):
    discard lcnOnThreadExit(releaseAtThreadExit)

proc onThreadRelease*(release: Release) {.gcsafe.} =
  ## Runs `release` when this thread's tables are released: for thread-local
  ## state other than `perThread` tables.
  releases.add release
  pending = releases.len
  enterThread()

template perThread*(accessor: untyped, T: typedesc, load: untyped) =
  ## Declares `accessor(): lent T`, which returns this thread's table and runs
  ## `load` the first time a thread asks. `load` must not depend on the thread.
  var state {.threadvar, gensym.}: T
  var ready {.threadvar, gensym.}: bool

  proc release() {.nimcall, gcsafe, raises: [], gensym.} =
    state = default(T)
    ready = false

  proc accessor(): lent T {.gcsafe, raises: [].} =
    if not ready:
      state = load
      ready = true
      onThreadRelease(release)
    state
