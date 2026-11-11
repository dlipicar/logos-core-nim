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
## before its first use under refc (the module kit's entry points do).

{.push raises: [].}

template perThread*(accessor: untyped, T: typedesc, load: untyped) =
  ## Declares `accessor(): lent T`, which returns this thread's table and runs
  ## `load` the first time a thread asks. `load` must not depend on the thread.
  var state {.threadvar, gensym.}: T
  var ready {.threadvar, gensym.}: bool

  proc accessor(): lent T {.gcsafe, raises: [].} =
    if not ready:
      state = load
      ready = true
    state
