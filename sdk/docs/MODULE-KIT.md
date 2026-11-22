# The module kit: writing a Logos module in Nim

`lcn-gen kit` turns a module's contract into a Nim module, its *kit*. The kit exports the C symbols a
Runtime loads (INTERFACE §2.6) and calls the handlers you write in Nim. This guide covers generating a
kit, writing handlers, the thread-confined mode and its `async` handlers, publishing events, calling
other modules, building the library, and requiring the SDK from a module repository. The decisions behind
it are DECISIONS G335–G342, I71 and G433–G436; the kit's output is PROVISIONAL (App A.3, A.4) until the spec owner settles it.

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
- A post after `_MODULE_destroy` returned is refused, and so is a delivery or completion for a route
  handle, subscription or prepared call the module left unreleased (G440). That gate keeps the
  Runtime's memory safe; it is not permission. A refused callback never runs and its payload stays
  yours, and a thread still posting after destroy is residual work: stop or join every thread that
  holds the poster, and release every handle, before `destroyModule` returns.
- At destroy, `destroyModule` runs on the module thread, the events the module published are
  delivered, and both of the kit's threads are joined before `_MODULE_destroy` returns.
- `destroyModule` may be `async` and await what the module started: a callback a foreign thread posts
  to it, the completion of a prepared call or of `invokeAsync`, and `publishAsync` (G437). Events and
  end reports from routes are not delivered once destroy has begun, and posts still queued when
  `destroyModule` returns are dropped.
- Whether the Runtime still admits a call made during destroy is another matter: ordinary call paths
  close at stop and at shutdown (RUNTIME l.3713-3716). Cleanup that needs another module belongs in a
  preparation method the module declares and the deployment calls before stopping it (l.3739).
- `destroyModule` closes every stream and transport the module opened on its module thread. A
  descriptor you registered with chronos yourself is unregistered before it is closed: one closed while
  still registered counts as left. The kit reports what is left in one stderr line naming the module,
  and leaves it open, since it never closes what it did not open (G438). In the SDK's test builds a
  confined kit aborts there instead, so your own suite fails at the destroy that missed a close.
- Before `destroyModule` returns, stop or join every thread you gave the module thread's chronos
  dispatcher handle to (for chronos's cross-thread `callSoon`): no thread may call into it afterwards.
- Never close or replace the module thread's dispatcher: the kit's own wake-up is registered with it,
  so nothing queued for the module is served once it is gone. A library may close dispatchers on
  threads it starts itself, as logos-storage-nim's `ffi` package does on its own threads. A destroy
  that finds another dispatcher says so in its line and counts nothing (G438); a test build aborts
  there.

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
- Never build a release library with `logos_sdk/testing/kitbuild`. It is the test suites' helper, and
  it builds confined kits strict about destroy (`-d:lcnKitStrictDestroy`, G438): they abort when a
  destroy left something registered.

**Toolchain** (G341). Nim 2.2.14 for refc libraries, 2.2.12 or later for orc ones; `results` 0.5.x;
for confined mode, chronos 4.4.x (this repository locks 4.4.1; confined mode uses no API newer than
4.4.0), built without `chronosStrictReentrancy`, which the kit refuses. The kit compiles with
logos-storage-nim's switches (`-d:chronosHandleException`, `--styleCheck:error`, `--fieldChecks:on`
with `ProveField` as an error, among others) and logos-delivery's (`--deepcopy:on`,
`-d:nimOldCaseObjects`); the `kit-toolchains-storage` and `kit-toolchains-delivery` flake checks
build the test libraries with each set. Two more, `kit-toolchains-storage-2d81a762` and
`kit-toolchains-delivery-0de7b335`, build them against each library's own chronos (the main line
after 4.4.0) and the stew, bearssl or httputils it locks, beside a host on 4.4.1 (G439).

**A library's own switches stay with it.** Nim reads the `config.nims` and `nim.cfg` files above the
source it compiles, so a module library's own configuration applies when its repository builds it, and
never when another repository builds against it. A repository that builds a kit against
logos-storage-nim gets none of storage's switches: its build line carries the ones the library needs.
The `kit-toolchains` checks pass storage's and delivery's sets for that reason.

## 9. Requiring the SDK

The SDK is the nimble package `logos_sdk` (`sdk/logos_sdk.nimble`, DECISIONS G433): the modules this
guide imports, the kit, `lcn-gen`, the contracts it ships and the test helpers under
`logos_sdk/testing`. A module repository requires it by name and one minor version (G434):

```nim module.nimble
requires "logos_sdk >= 0.1.0 & < 0.2.0"
```

Until the repository split's extraction the SDK has no address of its own, so it is not required by
URL, and none of our packages is ever required by commit or by `file://`. Nimble meets the requirement
in one of two ways.

- **An install** into the module repository's Nimble directory, from a committed tree in a copy with no
  `origin`. From a checkout with an origin, Nimble locks the repository's root, and a fresh setup then
  installs `logos_core` in the SDK's place. The order is install, lock (which reads the network), setup;
  `setup` before the first lock fails:

  ```sh install
  git clone CORE_CHECKOUT SDK_COPY && git -C SDK_COPY remote remove origin
  cd SDK_COPY/sdk && nimble --useSystemNim -y --nimbleDir:MODULE/nimbledeps install
  cd MODULE && nimble --useSystemNim -y lock && nimble --useSystemNim setup -l
  ```

  A fresh clone of the module repository, CI's included, installs the SDK the same way before its
  `nimble setup`.
- **A develop link** (`nimble develop -a:CORE_CHECKOUT/sdk`), while you change the SDK itself. It builds
  and sets up, but `nimble lock` refuses it, so switch to an install whenever the lock has to change.

**One SDK revision per Nimble directory.** The SDK's version stays `0.1.0` while it changes, so two
installs with different content can share it. When they meet in one Nimble directory, `setup` and
`lock` take whichever the filesystem lists first, and `setup` keeps it even over a lock that names the
other's checksum, without a word; `bin/lcn-gen` links the one installed last. Nimble checks no lock
checksum for any package (Nimble 0.26.2; core's DECISIONS G436). So install each SDK revision into a
fresh Nimble directory, record the core commit it came from, and have a suite check that every
directory `nimble.paths` names, `logos_sdk`'s among them, ends in the checksum the lock records for
it. That is a check for mismatches, not against tampering: an install edited in place keeps its name
and passes. `logos_sdk/testing/lockcheck`'s `installMismatches` does that from the project's root;
pass the names of any packages you take from a develop link, written in the suite itself rather than
read from the environment. The same suite checks that `nimbledeps/bin/lcn-gen` resolves into the
directory `nimble.paths` names for `logos_sdk`: the link follows the last install, not the lock.

**The generated-code check.** A module repository that commits its generated files compares them with a
fresh generation by the installed SDK's `lcn-gen`, which Nimble builds at install with the module
repository's compiler. With local dependencies that is `nimbledeps/bin/lcn-gen`. `lcn-gen --version`
prints the SDK's version, and the check compares it with the lock's `logos_sdk` entry. Until the
extraction every SDK revision is `0.1.0`, so the version cannot tell two revisions apart; the
`nimble.paths` test above does.

**The installed files.** The SDK's contracts are under its install, for `lcn-gen calls` (§6):
`$(nimble path logos_sdk)/logos_sdk/contracts/lcn_storage_fetch.cddl`.

**Where Nimble keeps its caches.** Nimble 0.26 keeps `pkgcache/`, its download cache, and `buildtemp/`
under the configured Nimble directory, `~/.nimble` by default, in local-dependencies mode too.
`--nimbleDir` moves `pkgcache/` and not `buildtemp/`. A run can reuse an earlier run's clones without a
git call, so a check that must fetch nothing looks there too, or runs with `HOME`, `XDG_CONFIG_HOME` and
`XDG_CACHE_HOME` pointed at a fresh directory outside every checkout (G436).
