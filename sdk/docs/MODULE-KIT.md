# The module kit: writing a Logos module in Nim

`lcn-gen kit` turns a module's contract into a Nim module, its *kit*. The kit exports the C symbols a
Runtime loads (INTERFACE §2.6) and calls the handlers you write in Nim. This guide covers generating a
kit, writing handlers, the thread-confined mode and its `async` handlers, publishing events, calling
other modules, and building the library. The decisions behind it are DECISIONS G335–G342 and I71; the
kit's output is PROVISIONAL (App A.3, A.4) until the spec owner settles it.

The example below is a whole module. `sdk/tests/test_module_kit_guide.nim` takes its files and command
lines from this document, generates the kit, builds the library and calls it, so the example is kept
working.

## 1. The example

The contract, `counter_module.cddl`:

```cddl counter_module.cddl
; -- metadata --
_module = "counter_module"

; The module-kit guide's example (sdk/docs/MODULE-KIT.md): a thread-confined
; counter. `increment` has a plain handler, `settle` an async one.

counter.increment_request = {
  key: tstr .size (1..64),
  amount: uint64,
}

counter.increment_response = {
  total: uint64,
}

counter.settle_request = {
  key: tstr .size (1..64),
  millis: uint32,
}

counter.settle_response = {
  total: uint64,
  caller: tstr .size (0..256),
}

counter.changed_event = {
  key: tstr .size (1..64),
  total: uint64,
}
```

Its implementation, `counter_impl.nim`:

```nim counter_impl.nim
## The module-kit guide's example (sdk/docs/MODULE-KIT.md).

import std/tables
import ./generated/counter_module_kit

type Counter = ref object
  services: ModuleServices
  totals: Table[string, uint64] ## GC'd state: only the module thread touches it

proc initModule(_: type Counter, init: ModuleInit): Result[Counter, InvocationFailure] =
  ok(Counter(services: init.services))

proc increment(
    m: Counter, request: CounterIncrementRequest
): Result[CounterIncrementResponse, InvocationFailure] =
  if request.amount == 0:
    return err(failure(ecInvalidParams, "amount must not be 0"))
  let total = m.totals.getOrDefault(request.key) + request.amount
  m.totals[request.key] = total
  # Queued: subscribers may see it after this response (§5).
  discard m.services.publish(CounterChangedEvent(key: request.key, total: total))
  ok(CounterIncrementResponse(total: total))

proc settle(
    m: Counter, request: CounterSettleRequest, inv: Invocation
): Future[Result[CounterSettleResponse, InvocationFailure]] {.async: (raises: []).} =
  try:
    await sleepAsync(int(request.millis).milliseconds)
  except CancelledError:
    return Result[CounterSettleResponse, InvocationFailure].err(
      failure(ecCancelled, "settle was cancelled")
    )
  let total = m.totals.getOrDefault(request.key)
  # Awaited: the subscribers have it before the response goes.
  discard await m.services.publishAsync(CounterChangedEvent(key: request.key, total: total))
  let who = inv.caller()
  let caller = (if who.isOk: who.unsafeGet.moduleInstance.get("") else: "")
  Result[CounterSettleResponse, InvocationFailure].ok(
    CounterSettleResponse(total: total, caller: caller)
  )

exportCounterModule(Counter)
```

## 2. Generating the kit

```sh generate
lcn-gen kit --confined --async-api --out:generated counter_module.cddl
```

This accepts the contract (INTERFACE §1.1, §5.3) and writes into `generated/`:

| File | What |
|---|---|
| `counter_module_types.nim` | the contract's Nim types, with their CBOR encoders and checked decoders |
| `counter_module_kit.nim` | the exported symbols, over your handlers; `export<Module>(T)` |
| `counter_module_kit.exports`, `.map` | the library's export list for macOS ld and GNU ld (§8) |

Regenerate whenever the contract changes; never edit the output. Other forms:

- `--interface:FILE` (repeatable): an interface the module implements, named by its root in the
  contract's `_implements`. Its methods and events join the module's.
- `--supporting:FILE`: a supporting schema the documents use.
- `--module:NAME` with no contract file: an interface-only provider, whose methods and events are its
  interfaces' alone (INTERFACE l.2833-2840). With no `--interface` either, the kit exports only
  `_MODULE_name`, `_init` and `_destroy` (l.2573).
- `--extends:FILE`: an earlier version of the contract or of an interface that this one extends
  (COMMITMENT §9.1). Consumers built against it keep working (INTERFACE §2.6 l.1693-1696).
- `--configuration:FILE --configuration-root:NAME [--live-reconfiguration]`: the module's configuration
  schema (CONFIG §2). `initModule` then takes the checked value as its third argument, and with live
  reconfiguration you write `applyConfiguration(T, <Root>)`.
- Without `--confined`, the kit is a *plain* kit (§3).

## 3. Handlers, and which thread runs them

You write a `ref object` type and instantiate `export<Module>(T)` once, at top level. The kit calls
these procs, found by overload resolution in your module:

- `initModule(T, ModuleInit): Result[T, InvocationFailure]`. `ModuleInit` holds `services` (the
  instance's Runtime bindings, valid until destroy), `stateDir` and the configuration.
- `destroyModule(T)`, optional.
- One handler per method, named by its bare method name (dots become underscores):
  `<bare>(T, <Request>): Result[<Response>, InvocationFailure]`.

A failure carries a code and a message of up to 512 bytes, `failure(code, message)`. A handler may
answer `ecMethodNotFound`, `ecInvalidParams`, `ecModule`, and `ecCancelled` once its invocation was
cancelled. Any other code reaches the caller as MODULE_ERROR (INTERFACE l.3306-3311). A request has
been checked against the contract before your handler sees it, and the response is checked before it
leaves.

**Plain kit.** Handlers run on whatever thread the Runtime or Module Host calls from, several at once
on one instance (INTERFACE l.1899-1905). A module must not depend on one call thread or on the Runtime
serializing calls (l.1942-1947): if it needs serial execution, it serializes itself. Under refc, such a
handler must not store GC'd values (strings, seqs, refs, tables) in the instance: they belong to the
heap of the thread that made them (I71). An orc module has no such limit.

**Confined mode** (`--confined`, G335). Each instance gets a **module thread** of its own, which runs a
chronos event loop. Every entry that touches the instance is handed to that thread while the calling
thread waits: `_MODULE_init`, `_destroy`, `_dispatch`, `_apply_configuration` and the typed functions.
The instance is made, used and freed on that thread only, so a refc module may keep GC'd state in it,
as the example's `totals` table does. **A refc module whose handlers keep GC'd state must be confined**
(G342). In confined mode:

- A handler may be `async` and take the invocation as a third argument (§4). While it awaits, the
  thread serves the next call.
- A call that reaches the module from its own module thread runs inline: a subscriber that re-enters
  from the delivering thread, or a route call back into itself. The thread keeps serving meanwhile.
- Never block the module thread. A blocking call made on it (a synchronous `invoke`, a Runtime Control
  call) holds every other call to the instance until it returns, and if the module it calls calls back
  into this one meanwhile, the two wait for each other for good. Use `invokeAsync` (§6).
- `services.poster.post(fn, payload)` runs a C callback on the module thread from any thread, one Nim
  has never seen included: a C or Rust library's own threads. C code linked into the library calls
  `lcn_kit_post(poster, fn, payload)` instead. Stop posting before `destroyModule` returns: a callback
  still queued then is dropped.
- At destroy, `destroyModule` runs on the module thread, events already queued are delivered, and both
  of the kit's threads are joined before `_MODULE_destroy` returns.

## 4. Async handlers

```nim
proc <bare>(m: T, request: <Request>, inv: Invocation):
    Future[Result[<Response>, InvocationFailure]] {.async: (raises: []).}
```

`initModule`, `destroyModule` and `applyConfiguration` may return a future of their result too.

- Use `inv` for the invocation: `inv.caller()`, `inv.isCancelled()`, `publishScoped(inv, event)`.
  Inside an async task, `services.caller()` and `services.isCancelled()` answer NOT_READY, since a
  resumed task may belong to another call. `inv` refuses use (NOT_READY) once its call has ended, so
  don't keep it (G336).
- A cancelled call cancels your future at its current `await`, which raises `CancelledError`. Catch it
  to clean up and answer `ecCancelled`, as the example does. A handler future that ends cancelled all
  the same is answered CANCELLED by the kit (G338).
- `--async-api` also exports `_MODULE_async_api`, the deferred provider surface (INTERFACE §2.9.2). A
  Runtime or Module Host then submits calls without holding one of its threads until the response, so
  a call that takes long to answer holds no call slot (G100). The handlers stay the same.

## 5. Publishing events

For each event the contract declares, the kit generates:

- `publish(services, event)`: to the instance's subscribers. In confined mode the kit checks the event
  and **queues** it for a publisher thread of its own, which hands events to the Runtime in order. Its
  result is the kit's check, or NOT_READY when the queue is full (64 events or 1 MiB). **OK means
  queued, not delivered**: a subscriber can see the event after your handler has answered.
  `publishRefusals(services)` and `lastPublishRefusal(services)` report what the Runtime later refused
  (G337).
- `publishAsync(services, event)` (confined): a future of the Runtime's own answer, which waits for
  room in the queue. Await it where order matters, as `settle` does.
- `publishScoped(services, event)` from a plain handler, or `publishScoped(inv, event)` from an async
  one: to the subscribers of this call alone. A call answers only after its scoped events were
  delivered (RUNTIME l.1200).

In a plain kit, `publish` calls the Runtime's callback at once and returns its result.

## 6. Calling other modules

`lcn-gen calls PROVIDER.cddl` writes typed helpers for another module's contract, `<stem>_calls.nim`.
The same file serves plain and confined modules.

- **Routes.** `newRouteSet(services)` makes a set for this instance. `openRoute(set, root, schema, …)`
  establishes routes to a contract through the Runtime and wraps each handle, and `close(set)` in
  `destroyModule` releases every handle, call and subscription the set holds. A route you got some
  other way joins through `wrapRoute(handle, onRouteEnd, user, dispatcher)`.
- **Calls.** `invoke(route, request)` waits for the response. `prepareInvoke(route, request, onDone,
  user, timeoutMs)` returns a prepared call that completes `onDone`; a nonzero `timeoutMs` is its
  deadline (TIMEOUT). In confined mode, `await invokeAsync(route, request, timeoutMs)` gives the
  outcome as a future, on the module thread.
- **Events.** `subscribe(route, <Event>, onEvent, onEnd, onInvalid, user)` delivers each event decoded
  and checked; one that does not decode goes to `onInvalid`. A subscription the Runtime ends reaches
  `onEnd` with NOT_AUTHORISED (an authority withdrew it) or MODULE_ERROR, after the events already
  delivered. A route's own end reaches the handle's `onRouteEnd` alone. `subscribe(set, eventId, …)`
  takes Runtime Control events.
- **The handler rule** (INTERFACE l.1934-1940). Inside a handler or end callback of a handle, the same
  thread's operations on that handle answer NOT_READY, except the running handler unsubscribing itself.
  So does `release` from a call's own completion. Other threads wait their turn.
- **Confined mode.** Pass the kit's dispatcher (`newRouteSet(services)` does): every handler, end
  callback and completion then runs on the module thread, never on the delivering thread. At most 1024
  events wait for your handlers at once (`setDeliveryBound` lowers it). A delivery that finds the queue
  full ends its subscription, and `onEnd(MODULE_ERROR)` follows the events already queued (G339).
- A marked response (`_sensitive`) is erased once `onDone` returns: copy what you keep.

## 7. Where the module runs

A caller sees a provider only through its contract (INTERFACE l.2146-2147). The same library runs in
the Runtime's process (`direct_dynamic`) or in a Module Host process (`hosted_dynamic`), and nothing in
the kit or in your code changes. The operator chooses in the daemon configuration
([DEPLOYMENT.md](../../docs/DEPLOYMENT.md) §8, §22). Either way, payloads pass between the modules
themselves; the Runtime only sets up and checks the routes.

The module may use either memory manager, whatever the Runtime and Module Host use: each library runs
its own Nim runtime, and only C data crosses the boundary (G342). The packaged logosd and Module Host
are orc builds, and a refc build of either refuses every contract with a marked field (G277).

## 8. Building the library

On Linux:

```sh linux
nim c --app:lib --mm:refc -d:noSignalHandler --import:logos_sdk/base/hostsignals \
  --nimMainPrefix:libcounter --passL:-Wl,--version-script=generated/counter_module_kit.map \
  -o:libcounter_module.so counter_impl.nim
```

On macOS:

```sh macos
nim c --app:lib --mm:refc -d:noSignalHandler --import:logos_sdk/base/hostsignals \
  --nimMainPrefix:libcounter --passL:-Wl,-exported_symbols_list,generated/counter_module_kit.exports \
  -o:libcounter_module.dylib counter_impl.nim
```

- `--nimMainPrefix` gives the library's Nim runtime a name of its own, distinct from the host's and
  from every other library's.
- `-d:noSignalHandler` leaves the host's signal handlers alone (G340); the kit warns without it.
- `--import:logos_sdk/base/hostsignals` records the host's `SIGPIPE` disposition before chronos sets
  it, and the kit puts it back. A confined kit needs it, as does any library that imports chronos.
- The export list makes the library export its ABI and nothing else (G341): not its `NimMain`, and not
  the C functions it carries, so two modules in one process never bind each other's copies.
- `--mm:refc` or `--mm:orc`, as you like (§7). Add your own switches after these.

**Toolchain** (G341). Nim 2.2.14 for refc libraries, 2.2.12 or later for orc ones; `results` 0.5.x;
for confined mode, chronos 4.4.x (this repository locks 4.4.1; confined mode uses no API newer than
4.4.0), built without `chronosStrictReentrancy`, which the kit refuses. The kit compiles with
logos-storage-nim's switches (`-d:chronosHandleException`, `--styleCheck:error`, `--fieldChecks:on`
with `ProveField` as an error, among others) and logos-delivery's (`--deepcopy:on`,
`-d:nimOldCaseObjects`); the `kit-toolchains` flake check builds the test libraries with both sets.

**Getting the SDK.** Until the SDK is a nimble package of its own (the repository split's packaging
step), put this repository's `sdk/src` on the Nim path (`--path:`, or a `nimble.paths` entry), with
the packages `logos_core.nimble` locks. A module repository will then `requires` the SDK instead.
