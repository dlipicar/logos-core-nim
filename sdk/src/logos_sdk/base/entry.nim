## How code of a Nim library starts on a thread its own Nim runtime did not
## start (DECISIONS G339, G464, G465) [IMPL].
##
## Every kit library, the Runtime's library and a Module Host carry their own
## Nim runtime. For each, a thread another runtime or C code started is
## foreign: under orc its first allocation faults until it has taken an
## allocator region (`setupForeignThreadGc`; DECISIONS I77 (7)), and under refc
## its collector has no stack bottom. A thread that registered once stays
## registered, so a missing registration shows only on a thread that never ran
## the library's code, and never under `useMalloc` (every sanitizer build),
## which has no per-thread region.
##
## - `enterForeignThread` registers the calling thread. The kit's `kitEnter`
##   and `callbackEnter` and the bindings' `bindingEnter` are it.
## - `{.lcnCallback.}` marks a procedure a binding runs (an event handler, an
##   end report, a completion): it gives the procedure the C calling convention
##   and makes `enterForeignThread` its first statement, in its own frame.
## - `{.lcnModuleThread.}` marks a procedure meant to run on a confined kit's
##   module thread (one given to `post` or `lcn_kit_post`): it registers in the
##   same way and, with test hooks, fails at once on any other thread.
## - `entered(p)` makes an `Entered[F]` of a procedure carrying either mark and
##   refuses, at compile time, one that carries neither. The SDK's helpers that
##   hand a procedure to a binding or a poster take `Entered[F]`.
## - `{.lcnNoNimHeap: "reason".}` and `{.lcnOwnRuntime: "reason".}` exempt a
##   C-callable procedure from registering: one that uses no Nim heap at all,
##   and one only this library's own runtime calls. `lcn-gen lint-callbacks`
##   accepts these four marks, an `importc`, and `kitEnter` or `bindingEnter`
##   as the first statement, and nothing else.

{.push raises: [], gcsafe.}

import std/macros
import ./perthread

var
  foreignEntered {.threadvar.}: bool ## `enterForeignThread` ran on this thread
  confinedThread {.threadvar.}: bool ## this thread is a confined kit's module thread

template enterForeignThread*() =
  ## [IMPL] Registers the calling thread with this library's Nim runtime;
  ## cheap after the first call on a thread. Under refc it also raises the
  ## collector's stack bottom to this frame: refc scans only between the stack
  ## pointer and the bottom it recorded, and a shared library's runtime starts
  ## in a load-time constructor deeper in the stack than the calls that come
  ## later. The bottom only ever widens, so a nested entry leaves the outer
  ## frames scanned. Expand it in the entry's own frame.
  setupForeignThreadGc()
  enterThread()
  foreignEntered = true
  when not defined(gcDestructors):
    var entryStackBottom {.volatile, noinit.}: pointer
    nimGC_setStackBottom(addr entryStackBottom)

proc threadEntered*(): bool =
  ## [DECISIONS G466] Whether `enterForeignThread` ran on the calling thread:
  ## the test probe. Reads one thread variable; any thread, no Nim heap.
  foreignEntered

proc enterConfinedThread*() =
  ## [DECISIONS G336] Marks the calling thread as a confined kit's module
  ## thread: from now on the invocation-scoped operations read its confined
  ## scope, which is nil outside a plain handler (NOT_READY).
  confinedThread = true

proc onConfinedThread*(): bool =
  ## Whether the calling thread is a confined kit's module thread.
  confinedThread

proc cFputs(s: cstring, f: pointer): cint {.importc: "fputs", header: "<stdio.h>".}
proc cAbort() {.importc: "abort", header: "<stdlib.h>", noreturn.}
var cStderr {.importc: "stderr", header: "<stdio.h>".}: pointer

proc offModuleThread(name: cstring) {.noinline.} =
  ## [DECISIONS G465] Test hooks: a module-thread procedure ran elsewhere.
  ## The C library only: the thread may hold no allocator region.
  discard cFputs("lcnModuleThread: ", cStderr)
  discard cFputs(name, cStderr)
  discard cFputs(" ran off its module thread (DECISIONS G465)\n", cStderr)
  cAbort()

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

type Entered*[F] = distinct F
  ## [DECISIONS G464] A procedure that registers its thread first: made only
  ## by `entered`. `fn` gives back the procedure itself.

template fn*[F](e: Entered[F]): F =
  F(e)

proc toEntered[F](p: F): Entered[F] =
  ## Only `entered` calls this, once it has checked the mark.
  Entered[F](p)

proc markProc(p, tag, enter, check, off: NimNode): NimNode =
  ## The marked procedure: the C calling convention, `gcsafe`, `raises: []`
  ## where not given, the tag, and `enter` first, after the leading
  ## documentation; with `check` and `off` (not nil), under test hooks, the
  ## module-thread assertion after it.
  if p.kind notin {nnkProcDef, nnkLambda}:
    error("{.lcnCallback.} and {.lcnModuleThread.} mark a procedure", p)
  result = p
  var have: seq[string]
  for x in result.pragma:
    case x.kind
    of nnkIdent, nnkSym:
      have.add($x)
    of nnkExprColonExpr:
      have.add($x[0])
    else:
      discard
  if "cdecl" notin have and "noconv" notin have:
    result.addPragma(ident"cdecl")
  if "gcsafe" notin have:
    result.addPragma(ident"gcsafe")
  if "raises" notin have:
    result.addPragma(nnkExprColonExpr.newTree(ident"raises", nnkBracket.newTree()))
  result.addPragma(tag)
  let body = result.body
  var stmts = newStmtList()
  var leading = true
  var rest: seq[NimNode]
  var items: seq[NimNode]
  if body.kind == nnkStmtList:
    for s in body:
      items.add s
  else:
    items.add body
  for s in items:
    if leading and s.kind == nnkCommentStmt:
      stmts.add s
    else:
      leading = false
      rest.add s
  stmts.add newCall(enter)
  if check != nil:
    let name = newLit($result.name)
    stmts.add nnkWhenStmt.newTree(
      nnkElifBranch.newTree(
        newCall(ident"defined", ident"lcnTestHooks"),
        nnkIfStmt.newTree(
          nnkElifBranch.newTree(
            newCall(ident"not", newCall(check)), newStmtList(newCall(off, name))
          )
        ),
      )
    )
  for s in rest:
    stmts.add s
  result.body = stmts

macro lcnCallback*(p: untyped): untyped =
  ## [DECISIONS G464] Marks a procedure a binding runs on whatever thread it
  ## uses: it registers that thread before anything else.
  markProc(p, bindSym"lcnEntered", bindSym"enterForeignThread", nil, nil)

macro lcnModuleThread*(p: untyped): untyped =
  ## [DECISIONS G465] Marks a procedure meant for a confined kit's module
  ## thread: it registers as `{.lcnCallback.}` does and, with test hooks,
  ## aborts with its name when it runs on any other thread (C or Rust code
  ## that called it rather than posting it).
  markProc(
    p,
    bindSym"lcnOnModuleThread",
    bindSym"enterForeignThread",
    bindSym"onConfinedThread",
    bindSym"offModuleThread",
  )

proc tagged(s: NimNode): bool =
  ## Whether the procedure `s` carries `lcnEntered` or `lcnOnModuleThread`.
  let impl = s.getImpl
  if impl.kind notin RoutineNodes:
    return false
  for x in impl.pragma:
    let k =
      case x.kind
      of nnkSym, nnkIdent:
        x
      of nnkExprColonExpr, nnkCall:
        x[0]
      else:
        nil
    if k != nil and k.kind in {nnkSym, nnkIdent} and
        $k in ["lcnEntered", "lcnOnModuleThread"]:
      return true
  false

macro entered*(p: typed): untyped =
  ## [DECISIONS G464] `Entered[F]` of `p`, a procedure marked
  ## `{.lcnCallback.}` or `{.lcnModuleThread.}`; a compile-time error for any
  ## other.
  var s = p
  while s.kind in {nnkHiddenStdConv, nnkHiddenSubConv, nnkConv, nnkHiddenCallConv}:
    s = s[^1]
  if s.kind != nnkSym or s.symKind notin {nskProc, nskFunc}:
    error(
      "entered: give a procedure marked {.lcnCallback.} or {.lcnModuleThread.} by name",
      p,
    )
  if not tagged(s):
    error(
      "entered: `" & $s &
        "` does not register its thread first; mark it {.lcnCallback.} " &
        "or {.lcnModuleThread.} (DECISIONS G464)",
      p,
    )
  result = newCall(bindSym"toEntered", s)

{.pop.}
