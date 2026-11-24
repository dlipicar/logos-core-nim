## The marks of `entry.nim` (DECISIONS G464-G467) [IMPL], apart so that a module
## `entry` imports can carry an exemption too. `lcn-gen lint-callbacks` reads
## them by name.

template lcnEntered*() {.pragma.}
  ## The tag `{.lcnCallback.}` leaves; `entered` reads it.

template lcnOnModuleThread*() {.pragma.}
  ## The tag `{.lcnModuleThread.}` leaves; `entered` reads it.

template lcnNoNimHeap*(reason: string) {.pragma.}
  ## [DECISIONS G467] A C-callable procedure that uses no Nim heap at all (the
  ## C allocator, its arguments and static data only), so it may run on a
  ## thread that never registered. The reason says why.

template lcnOwnRuntime*(reason: string) {.pragma.}
  ## [DECISIONS G467] A C-callable procedure that only this library's own
  ## runtime calls, on its own threads (a TLS callback during the transport's
  ## own call, an exit procedure, a signal handler). The reason says which.
