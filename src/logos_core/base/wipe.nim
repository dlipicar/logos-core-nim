## Erasure of buffers that may hold a marked payload (INTERFACE §1.4.1
## l.380-386; Tier 4b step 4b-3b; DECISIONS G276, I92) [IMPL].
##
## - `secureZero` zeroes memory with a call the compiler may not remove
##   (`wipe.c`: `explicit_bzero`, `memset_s`, `SecureZeroMemory`, or a
##   volatile loop). `zeroMem` is `memset`, which may be elided before a free.
## - `wipe` on a `seq` or `string` zeroes it to its `capacity`, then empties
##   it: bytes beyond `len` may hold what a shorter length left behind.
## - `freeWiped` zeroes a shared-heap copy before `deallocShared`.
## - The **marked scope** is a per-thread flag set while a marked payload is
##   validated or committed (`markedScope`). The commitment layer reads it to
##   wipe its own temporaries before dropping them, so the flag need not pass
##   through every signature. A value tree is wiped by its last holder only:
##   trees are refs, and wiping one still in use would erase it for its other
##   holders (INTERFACE l.384).
##
## Wipes are explicit calls, never `=destroy` hooks, so orc and refc behave
## alike. Under refc a `let` copy of a seq aliases the original (Nim drafts 70,
## 80): wiped values are `var`.

{.push raises: [], gcsafe.}

{.compile: "wipe.c".}

const
  ChannelsMove* = defined(gcDestructors)
    ## [DECISIONS G277] Whether this build's memory manager moves a channel
    ## message's heap parts to its receiver (orc, arc). Under refc a channel
    ## deep-copies each message and frees the copy unerased, so a refc build
    ## carries no marked payload: the Runtime refuses every marked route
    ## (`engine.erases`), and a Module Host refuses a marked provider at
    ## `init` and a marked route when its consumer materializes it.
  MarkedUnsupported* =
    "marked payloads are not supported on this path (INTERFACE §1.4.1)"
    ## [DECISIONS G244, G277] The refusal of a marked route, wherever it is
    ## made.
  MarkedUnsupportedByHost* =
    "marked payloads are not supported by this build of the Module Host (INTERFACE §1.4.1)"
    ## [DECISIONS G277] A refc Module Host's refusal of a provider whose
    ## contracts mark a payload, at `init`.

when defined(lcnWipeAudit):
  # The free scan of the erasure tests: in every audit-build image that wipes.
  import ./wipeaudit

proc lcnSecureZero(
  p: pointer, n: csize_t
) {.importc: "lcn_secure_zero", cdecl, noSideEffect.}

proc secureZero*(p: pointer, n: int) {.inline, noSideEffect.} =
  ## Zeroes `n` bytes at `p`; nothing when `p` is nil or `n` is not positive.
  if p != nil and n > 0:
    lcnSecureZero(p, csize_t(n))

proc wipe*[T: SomeNumber | bool | char](s: var seq[T]) {.noSideEffect.} =
  ## Zeroes `s` to its capacity, then empties it.
  let c = s.capacity
  if c > 0:
    s.setLen(c)
    secureZero(addr s[0], c * sizeof(T))
  s.setLen(0)

proc wipe*(s: var string) {.noSideEffect.} =
  ## Zeroes `s` to its capacity, then empties it.
  let c = s.capacity
  if c > 0:
    s.setLen(c)
    secureZero(addr s[0], c)
  s.setLen(0)

proc wipeObject*[T](x: var T) {.inline, noSideEffect.} =
  ## Zeroes a value with no heap parts (a hasher state, a digest).
  secureZero(addr x, sizeof(T))

proc freeWiped*(p: pointer, n: int) =
  ## A shared-heap copy of `n` bytes: zeroed, then released.
  if p != nil:
    secureZero(p, n)
    deallocShared(p)

var markedDepth {.threadvar.}: int

proc enterMarked*() {.noSideEffect.} =
  {.cast(noSideEffect).}:
    inc markedDepth

proc leaveMarked*() {.noSideEffect.} =
  {.cast(noSideEffect).}:
    dec markedDepth

proc inMarkedScope*(): bool {.noSideEffect.} =
  ## Whether this thread is validating or committing a marked payload.
  {.cast(noSideEffect).}:
    markedDepth > 0

template markedScope*(marked: bool, body: untyped) =
  ## Runs `body` with the marked scope set when `marked` is.
  let lcnMarked = marked
  if lcnMarked:
    enterMarked()
  try:
    body
  finally:
    if lcnMarked:
      leaveMarked()

proc wipeIfMarked*(s: var seq[byte]) {.noSideEffect.} =
  if inMarkedScope():
    wipe(s)

proc wipeIfMarked*(s: var string) {.noSideEffect.} =
  if inMarkedScope():
    wipe(s)

{.pop.}
