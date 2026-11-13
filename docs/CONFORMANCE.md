# Conformance and traceability

Every normative unit of the twelve specs has a stable ID. A section we claim must have a test for each
of its units. `tools/spectrace/spectrace.py` does the bookkeeping. In the dev shell it is `spectrace`;
`nix run .#spectrace -- <command>` also works. By default it reads the pinned specs from the
`logos-lips` flake input.

## Requirement ledger

`conformance/requirements/<PFX>.jsonl` holds one line per unit. The first line records the spec file,
the spec revision and the next free ID.

| Prefix | Spec | Prefix | Spec |
|---|---|---|---|
| TRN | transport | PKG | package-manager |
| IFC | interface | CAP | capability-authority |
| RUN | runtime | SEC | security-considerations |
| CFG | configuration | BCP | system-bcp |
| LDR | loader | CMT | commitment-model |
| HSH | hash-profile | CDE | cdcddle |

Unit kinds (G117, G118, I6):

| Kind | Unit |
|---|---|
| `kw` | A sentence, list item or table row with an uppercase BCP 14 keyword. A list item with no keyword inherits its keyword lead-in. |
| `lc` | The same, with a lowercase must, shall or should. Informative: every spec says lowercase forms keep their ordinary meaning, so no claim needs them tested (G117, review item B1). |
| `cddl` | One CDDL rule, identified by its rule name. |
| `block` | Any other fenced block: vectors, C declarations, examples. |
| `heading` | A section heading. |

IDs survive spec revisions. Matching tries an exact fingerprint first (BLAKE3 over kind and
whitespace-normalized text), then the most similar unit of the same kind in the same section
(similarity ≥ 0.8; a CDDL rule matches the rule of the same name, whatever changed). A unit with no match gets a new ID. A unit that
disappears is kept, marked `retired`, and its ID is never reused.

```bash
spectrace sync --specs ~/repos/logos-lips/docs/logos-core/raw --rev <commit>
```

`sync` rewrites the ledger and prints the added, changed, retired and moved IDs per spec; review
that output against the spec diff. `spectrace check` (a flake check) fails while the ledger does not
match the pinned specs.

## Claims

`conformance/claims/<PFX>.toml` gives each section a status. The longest matching section key wins,
and `default` covers the rest. Section keys are `§4.4`, `App B.1`, or `§1/Heading` for an unnumbered
heading under a numbered one.

| Status | Meaning |
|---|---|
| `claimed` | Built. Every live `kw`, `cddl` and `block` unit in the section must be referenced by a test. |
| `deferred:tier-N` | Not built yet; N is the tier in `docs/SPEC-STATUS.md`. |
| `deferred:tier-4b` | Not built yet: `logosctl`, `logosd`, the Module Host and what they bring (SPEC-STATUS's Tier 4b). |
| `informative` | Nothing to test (References, Copyright, and appendices the spec marks informative). |
| `out-of-scope:<why>` | Normative, but not this repository's to implement: a requirement on another party (modules, contracts, applications, specifications, deployments) or a MAY not taken. |

"Deferred" means not built. Behaviour that is built and differs from the text is a deviation: it is
recorded in `docs/DECISIONS.md`, and its unit is deferred only when the text's behaviour is not built.

### What is claimed at the end of Tier 4

Tiers 1 to 4 are closed: `spectrace gate --closed-tier 1 --closed-tier 2 --closed-tier 3
--closed-tier 4` (the flake's `spec-gate` check) fails on any status that still defers to one of them
(DECISIONS I88).

- **RUNTIME** is claimed for the **Runtime engine** in direct mode. RUNTIME l.72 defines a Runtime
  instance as the engine plus an orchestration module; until Tier 4b the host supplies the
  orchestration module, and `docs/HOST-CONFIG.md` ("Orchestration duties") lists what it must do.
  The in-process realizer is an implementation-local realization mechanism (l.212), not a Module
  Loader, so the Loader-conditional rules are not triggered (until Tier 4b step 4b-1, below).
  Deferred to Tier 4b: local transport mode (§4.2.1, §6.2 and the hosted and transported units), the
  orchestration module's duties, Loader loss, package-backed selection, upgrade transfer, and the
  stops caused by permission reconciliation; to Tier 5: remote Runtimes, facades, enrollment,
  listeners and exports. Out of scope: §5.2.1 singleton mode (a MAY not taken, l.1094), the Runtime
  side of system-service sessions over unix-stream (a MAY profile left unused under G48(a)), and
  requirements on modules, applications, specifications and deployments.
- **LOADER** is not claimed (until Tier 4b step 4b-1, below): it is `deferred:tier-4b` as a whole.
  The realizer follows LOADER's direct strategies, records and error codes ("a LOADER-shaped
  internal realizer"), but LOADER's subject is a Module Loader provider backed by a local module
  instance (LOADER l.23-26), and a Runtime may conform without one (RUNTIME l.27; BCP l.281). Its
  tests keep their `[LDR-…]` tags as evidence; representing the realizer as a `logos_module_loader`
  instance is the first item of Tier 4b (TF-36).
- **CONFIGURATION** is claimed in full for direct mode.
- **CAPABILITY AUTHORITY** is claimed for the local Authority and the Runtime's side of authority.
  Deferred: §3.5 permission profiles, enforcers and definitions (G110; Tier 4b), hosted placements, OS
  permission revocation (Tier 5), and the route ticket's decision, expiry and revocation, which the
  Runtime supplies in 10b.
- **TRANSPORT** is claimed for the sans-I/O protocol and the unix-stream I/O layer. Deferred: what the
  Runtime and the Module Host trigger (10b, Tier 4b), Windows and the remote profiles (Tier 5). Out of
  scope: §8.1.2 (a MAY profile left unused, l.1075) and requirements on contracts and deployments.
- **INTERFACE** adds the Runtime as ABI caller, route and Runtime Control binding, asynchronous calls
  and the invocation context. Deferred: the boundary-invariance units until a second boundary exists,
  marked-payload erasure (Tier 4b; until then no route is made to a contract that marks a payload,
  G244), the reverse mapper and remote bindings (Tier 5).
- **PACKAGE MANAGER**, **SYSTEM BCP** and **SECURITY CONSIDERATIONS** keep the parts built; the
  Package Manager handoff and complete-system composition are Tier 4b, installation and platform
  profiles Tier 5 (with the BCP's QUIC and Package Manager realization profiles, §5.3). The BCP's
  duties of specification authors (§5.2, §5.5) are out of scope.

### What Tier 4b step 4b-1 changes

Tier 4b step 4b-1 (DECISIONS I89) binds a `logos_module_loader` instance, so three entries above
change:

- **RUNTIME**: the Runtime's bootstrap mechanism realizes only the Module Loader instance (l.212;
  G57), and every other instance is realized and released through the bound Loader's contract
  (l.1641). The Loader-conditional rules are claimed with it: `loader-<code>` classifications
  (l.3754), lost Loader answers (l.3793; G252), Loader loss (l.3813-3825; the host must end its
  process, G249) and the shutdown order (l.3847-3864). The rest of the Tier 4b list above stays
  deferred.
- **LOADER** is claimed for the direct strategies. The Loader advertises `direct_static` and
  `direct_dynamic` only (plan K10), so the hosted strategy, the hosted provider endpoint and the
  trusted transport adapter handoff (§5.3, §5.4) wait for the Module Host (step 4b-3), and
  `force_release` is never advertised (K7). `conformance/claims/LDR.toml` lists the deferred units.
- **SYSTEM BCP**: bootstrap's Loader step (BCP l.287-290, BCP-0021 to BCP-0024) is tagged by tests,
  and its units keep the BCP's `deferred:tier-4b` default until logosd composes the system (4b-8).

## Properties not claimed

- Protection between processes of the same OS identity (TRANSPORT §8.2 l.1107-1111): Module Hosts
  run as the daemon's user, so a process running as that user can replace a socket pathname or
  impersonate an endpoint. Deployments that need that protection must run hosts under distinct OS
  identities, which this implementation does not set up (DECISIONS G58).

## Unix-stream endpoints and peer checks

TRANSPORT §8.2 and §9.1 as built in `src/logos_core/transport/io/` (DECISIONS G58, I83):

- **Layout.** `<base>/<8 hex>/logos_<module>.sock`. The base is a real directory that only the
  effective uid can write to, or a root-owned sticky directory such as `/tmp` `[IMPL]`. The
  per-instance directory is new (a random name, never reused), owned by the effective uid and set
  to 0700 with `fchmod` whatever the umask. `bind` never follows, removes or replaces an existing
  object; the socket is set to 0600 and listens before any handoff. A path that does not fit
  `sun_path` fails the placement; nothing is shortened.
- **macOS `bind`.** Darwin's `bind` follows a dangling symbolic link at the socket name and creates
  the socket at its target. `bindEndpoint` therefore looks at the name with
  `fstatat(AT_SYMLINK_NOFOLLOW)` first and refuses anything there (TRN-0182). The name is inside
  the Runtime's fresh 0700 directory, so only processes of the Runtime's own identity can race that
  check, which the non-claim above already covers.
- **Listener validation** (`validateEndpoint`): socket type and domain, the listening state, the
  bound name, and the directory's and socket's dev/ino against those recorded at creation. Linux
  reads the listening state with `SO_ACCEPTCONN`. macOS does not answer that `getsockopt`, so it
  reads `soi_options` from `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`. Other Apple systems have
  neither, so validation reports the state as unsupported and fails.
- **Peer check.** `SO_PEERCRED` on Linux and Android; `getpeereid` with `LOCAL_PEERPID` on Darwin
  and iOS. The caller compares the peer's effective uid with the expected identity before it writes
  any byte, and credentials it cannot read count as a mismatch. On a mismatch it closes without
  sending anything, so the ticket is neither disclosed nor consumed, and reports `TRANSPORT_ERROR`.
  The uid is what is checked; a pid is diagnostic only. What a caller sees names the process that
  created and bound the listener (the Runtime, under §8.2), not a Module Host serving the
  transferred descriptor.
- **Paths.** `connect` uses the exact path it is given and derives nothing from a module name.
- **Other-identity test (G129).** A listener created by a different OS user is tested in CI, where
  the job creates a throwaway user (`LCN_PEER_USER`); elsewhere that test is skipped, and a test that
  expects a different uid from a same-uid listener covers the same path.

## Transport limits

TRANSPORT §8.6 (TRN-0378, TRN-0380) as built in `src/logos_core/transport/` (DECISIONS I52, I83).
Every value is a field of `TransportConfig` (`io/api.nim`), checked before a transport I/O thread
starts: finite and positive, every input pool at least `frameLimit` so a maximal frame can always be
admitted, and `connOutputBytes` at least `peerFrameLimit` plus `controlReserve`. The defaults are
`[IMPL]`. "loop" is one transport I/O thread, which is one process; "conn" is one connection.

| Limit | Scope | Default | On exhaustion |
|---|---|---|---|
| `frameLimit` (largest frame body read) | conn | 16 MiB | ProtocolError `INVALID_PARAMS`, close |
| `peerFrameLimit` (largest frame body sent) | conn | 16 MiB | the message is not sent: a Request fails locally with `MODULE_ERROR`, a success Response becomes `MODULE_ERROR`, an Event is not committed (see below) |
| `maxPayloadDepth` (nesting in `params`, `result`, `data`) | conn | 1024 | ProtocolError `INVALID_PARAMS`, close; sending fails locally |
| `maxInbound` (accepted connections, pending Hellos included) | loop | 1024 | accept, ProtocolError `MODULE_ERROR` without reading, close |
| `maxPendingHellos` | loop | 64 | same |
| `helloTimeout` (the whole Hello exchange; at the deadline the sockets already readable and the owner's queued commands are handled first) | conn | 10 s | callee: close without ProtocolError; caller: `TRANSPORT_ERROR` |
| `maxHelloInputBytes` (frame bodies read before establishment) | loop | 32 MiB | the frame waits, bounded by `helloTimeout` |
| `maxOutbound` | loop | 1024 | caller: local `MODULE_ERROR`, nothing opened |
| `maxInputBytes` (frame bodies held after establishment: being read, queued for an execution slot, or Events not yet released by the caller's owner) | loop | 256 MiB | reading pauses up to `admissionTimeout` (10 s; room freed by the deadline counts, as for `helloTimeout`), then ProtocolError `TRANSPORT_ERROR`, close |
| `maxOutputBytes` (committed output) | loop | 256 MiB | as `connOutputBytes` |
| `connOutputBytes` | conn | 2 × `peerFrameLimit` + `controlReserve` | Event: overflow (below); success Response: waits, not committed; control frame: the reserve, then ProtocolError `TRANSPORT_ERROR`, close |
| `controlReserve` (error Responses, SubscriptionResults, the Hello response) | conn | 64 KiB | ProtocolError `TRANSPORT_ERROR` from the final slot, close |
| `writeStallTimeout` (output pending, no byte written; at the deadline a write is tried first, and a socket that accepts nothing is judged one dispatcher turn later, after the sockets that were ready) | conn | 30 s | close without ProtocolError |
| `closeLinger` (flushing a final ProtocolError) | conn | 1 s | close without finishing the flush |
| `terminationDrain` (in-flight work after a session's authorization ends) | conn | 0 s | — |
| `maxInFlight` (execution slots) | conn | 1024 | the Request waits in the delayed-admission queue |
| `maxDelayedRequests` / `maxDelayedBytes` (that queue) | conn | 64 / 32 MiB | ProtocolError `TRANSPORT_ERROR`, close |
| `maxPastCapFrames` / `maxPastCapBytes` (every frame read while at the slot cap) | conn | 4096 / 64 MiB | same |
| `maxTotalExecuting` (execution slots) | loop | 4096 | the Request waits in its connection's delayed-admission queue; freed slots go to the waiting connections in turn |
| `maxCalls` (calls with no terminal Response, abandoned ones included) | conn | 1024 | local `MODULE_ERROR`, nothing sent |
| `maxTotalCalls` | loop | 16384 | same |
| `maxSubscriptionIds` (subscription-id history, which bounds subscriptions) | conn | 4096 | caller: local `MODULE_ERROR`; callee: ProtocolError `TRANSPORT_ERROR`, close |
| `maxTotalSubscriptions` (active subscriptions, callee side) | loop | 16384 | SubscriptionResult error `MODULE_ERROR`; the session stays |
| `maxTotalSubscriptionIds` (subscription-id history, both sides) | loop | 65536 | caller: local `MODULE_ERROR`; callee: ProtocolError `TRANSPORT_ERROR`, close |
| `callerUndeliveredBytes` (Event frames handed to the caller's owner and not released) | conn | 32 MiB | reading pauses after the Event that reaches it (so it is exceeded by less than one frame) until the owner releases them, with no finite bound; a callee of this implementation closes the connection after its `writeStallTimeout` |
| `maxPendingOutputBytes` (Response and Event payloads submitted and not yet committed) | loop | 64 MiB | `submit` returns busy; `submitWait` waits up to its deadline, or with no finite bound when it has none |

Execution slots (A21): a dispatched Request holds its slot until the provider's work ends, even after
its Response or CANCELLED is committed or its connection closed. While a connection is at its cap it
keeps reading, so a Cancel or Unsubscribe is always processed; a Cancel for a queued Request commits
CANCELLED without dispatching it, and the end of a session answers queued Requests `NOT_AUTHORISED`.

Fixed statements:

- Closing a connection ends every subscription on it.
- Responses are never dropped for capacity, and a queued Request is never answered with an error for
  capacity.
- No limit promises that a Cancel overtakes a frame already committed to the same stream (TRN-0387).
  A Cancel acts only on a Request whose Response is not yet committed.
- There is no common overload response.

## Event output overflow

TRANSPORT §5.2 (TRN-0309, TRN-0310) as built in `io/callee.nim` and `io/loop.nim`:

- **Commitment.** An Event is committed when the I/O thread appends it to the connection's ordered
  output queue, after the checks: an active subscription, the route's publish scope, and for scoped
  publication the request still executing. A committed Event is written or the connection closes; it
  is never dropped.
- **Before commitment: backpressure.** A publication waits in the owner's command channel and counts
  against `maxPendingOutputBytes`. `submit` returns busy when that budget is full; `submitWait` waits
  for room, up to the caller's deadline or with no finite bound. `submitWait` refuses to run on the
  I/O thread or a registered owner thread, where waiting could deadlock.
- **Overflow (the close action).** An Event that does not fit the connection's output budget is not
  committed: the connection sends ProtocolError `TRANSPORT_ERROR` from its final slot, flushes for at
  most `closeLinger` (1 s), and closes. A connection that cannot be written for `writeStallTimeout`
  (30 s) closes without a ProtocolError. Closing ends every subscription on that connection.
- **Too large for the peer.** An Event larger than `peerFrameLimit` is never committed. The
  publication chooses: report it to the publisher and keep the connection, or ProtocolError
  `TRANSPORT_ERROR` and close (G165, chosen by the Runtime adapter).
- Neither action discards a committed Event.

## Test hooks

TRANSPORT §8.5 (TRN-0241 to TRN-0244). The hooks that inject or observe framed messages are all under
`tests/`: the sans-I/O session state machines driven directly (`tests/test_transport.nim`), raw
sockets that write crafted frames (`tests/test_transport_io.nim`), and the child-process peer
`tests/support/trnpeer.nim`. Nothing under `src/` refers to them, advertises them or falls back to
them. They use only the test tickets of `tests/support/trnowner.nim` and test data. No claim depends on
another implementation recognizing them.

Hooks under `src/` follow one rule (D27, revised 2026-11-13; DECISIONS I89):

1. Their code exists only inside `when defined(lcnTestHooks)`.
2. Only test builds set the define: `tests/config.nims` sets it for every suite, nimble's and the flake's
   alike. No flake package or app, nimble `bin` or `build_*` task sets it.
3. Each module that holds hooks puts a marker constant in the binary under the define
   (`src/logos_core/base/testhooks.nim`). The flake check `no-test-hooks` fails when any deployment
   package or app of the system holds it, and requires it in a probe built with the define.
4. A hook does nothing until the Runtime's host selects it. In an in-process suite, that is a call by the
   test.

The hooks so far (markers `host`, `engine`, `plumbing`, `sidetable` and `loader`):

- `host.setPolicyForTests`: the authority policy the next `start` installs.
- `engine.loaderJournalForTests`: the Module Loader's request journal, kept in the engine's side table.
- `engine.setLoaderFaultsForTests`, `releaseLoaderStallForTests`, `clearLoaderFaultsForTests` and
  `stalledLoaderCallsForTests`: faults injected into the next Module Loader call of a method (an
  invocation that fails before any work, a reply lost or garbled after the work, a reply held), or
  the Loader's report of its own failure (DECISIONS I89 part 4b-1d).
- `engine.confirmTerminationForTests`: stands in for the protected mechanism that confirms a lost
  Loader's realizations are gone (RUNTIME l.3825; G249), which a deployment does by ending the host
  process.

No deployment binary contains them.

## Tagging tests

A test covers a unit by carrying its ID in brackets anywhere in the test file, normally in the test
name:

```nim
test "[CDE-0042] map keys sort by encoded bytes":
```

A test of an interim choice for an open item also carries `[IMPL-DECISION Gn]`.

A unit that cannot be tested (pure prose, a rule about other implementations) is covered by an item
in `conformance/inspection/<PFX>.toml` that states why:

```toml
[[item]]
ids = ["HSH-0004"]
reason = "Statement about what a profile document must contain; satisfied by HASH itself."
```

`spectrace gate` (a flake check) fails when a claimed unit has no test or inspection item, when a
test names an unknown or retired ID, when a claims file has an invalid status, when an inspection item
names a unit that is not claimed (inspection stands for a test, so it covers claimed units only), or,
with `--closed-tier N`, when any status defers to tier N. It prints the deferred units per label.

## Mirrors and pins

`spectrace mirror` checks every file in `spec/mirrors/` against its block in the spec (see
`spec/mirrors.toml`); `--write` refreshes them. `spectrace pins` checks that every value in
`spec/pins.toml` still appears in the section it is pinned from. The tests recompute those values from
the mirrors. `oracle/selftest.py` cross-checks the vectors with an independent implementation.
