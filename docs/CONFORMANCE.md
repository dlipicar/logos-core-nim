# Conformance and traceability

Every normative unit of the twelve specs has a stable ID. A section we claim must have a test for each
of its units. `tools/spectrace/spectrace.py` does the bookkeeping. In the dev shell it is `spectrace`;
`nix run .#spectrace -- <command>` also works. By default it reads the pinned specs from the
`logos-lips` flake input.

## Requirement ledger

Each spec's ledger sits under the conformance tree of the package that owns it: `sdk/conformance/` for the
SDK (CDE, CMT, HSH and IFC) and `conformance/` for core (the rest). `<tree>/requirements/<PFX>.jsonl` holds one line per unit. The first line records the spec file,
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

`<tree>/claims/<PFX>.toml` gives each section a status. Each unit is claimed by the package that implements
its rule (DECISIONS R8). A spec two packages share (IFC, RUN, CFG) has a claims file in each, and each
gives the other package's units `out-of-scope:<package>`. `spectrace owners` holds that each unit has one
owner, that a unit neither claims has the same status in both files, and that a claimed unit's tests and
inspection items are in its owner's trees. The longest matching section key wins,
and `default` covers the rest. Section keys are `§4.4`, `App B.1`, or `§1/Heading` for an unnumbered
heading under a numbered one.

| Status | Meaning |
|---|---|
| `claimed` | Built. Every live `kw`, `cddl` and `block` unit in the section must be referenced by a test. |
| `deferred:tier-N` | Not built yet; N is the tier in `docs/SPEC-STATUS.md`. |
| `deferred:tier-4b` | Tier 4b is closed (DECISIONS I97): no unit may carry it, and the gate refuses it with `--closed-tier 4b`. |
| `informative` | Nothing to test (References, Copyright, and appendices the spec marks informative). |
| `out-of-scope:<why>` | Normative, but not this repository's to implement: a requirement on another party (modules, contracts, applications, specifications, deployments) or a MAY not taken. |

"Deferred" means not built. Behaviour that is built and differs from the text is a deviation: it is
recorded in `docs/DECISIONS.md`, and its unit is deferred only when the text's behaviour is not built.

**What a RUNTIME claim covers (BCP l.286).** A claim of conformance to RUNTIME covers a Runtime
instance with its orchestration module (RUNTIME l.66). This repository's RUNTIME claim is for the
engine with the reference orchestration module, `lcn_orchestrator`, wherever a host names it
(DECISIONS I94). logosd does: its Runtime instance is the engine with `lcn_orchestrator` as instance
`orchestrator` (`docs/DAEMON.md` §4; the facts block of `docs/DEPLOYMENT.md`, which
`tests/test_deployment.nim` compares with logosd's composition). A host embedding `liblogos_runtime`
that names another orchestration module supplies an engine without this one, so its claim is joint
with the module it supplies, which carries the orchestration duties (`docs/HOST-CONFIG.md`,
"Orchestration duties").

The sections from here to "Properties not claimed" are dated records, except "What is claimed at the end of Tier 4b":
each keeps the ids and spec lines of the revision it was written at (4b-6's BCP-0093 is BCP-0103 at 6cac8335).

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
  Deferred: §3.5 permission profiles, enforcers and definitions (G110; Tier 4b, claimed in step
  4b-4a, below), hosted placements, OS permission revocation (Tier 5), and the route ticket's
  decision, expiry and revocation, which the Runtime supplies in 10b.
- **TRANSPORT** is claimed for the sans-I/O protocol and the unix-stream I/O layer. Deferred: what the
  Runtime and the Module Host trigger (10b, Tier 4b), Windows and the remote profiles (Tier 5). Out of
  scope: §8.1.2 (a MAY profile left unused, l.1075) and requirements on contracts and deployments.
- **INTERFACE** adds the Runtime as ABI caller, route and Runtime Control binding, asynchronous calls
  and the invocation context. Deferred: the boundary-invariance units until a second boundary exists,
  marked-payload erasure (Tier 4b; until then no route is made to a contract that marks a payload,
  G244; claimed in step 4b-3b, below), the reverse mapper (claimed in step 5-1, below) and remote
  bindings (Tier 5).
- **PACKAGE MANAGER**, **SYSTEM BCP** and **SECURITY CONSIDERATIONS** keep the parts built; the
  Package Manager handoff and installation are Tier 5 (the handoff moved there from Tier 4b by owner
  decision 1 (a), 2026-11-13), complete-system composition Tier 4b, and platform profiles Tier 5
  (with the BCP's QUIC and Package Manager realization profiles, §5.3). The BCP's
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

### What Tier 4b step 4b-2 changes

Tier 4b step 4b-2 (DECISIONS I90) builds transported local routes: a host routing rule (G254) selects
`local-transport` for a route, and the Runtime serves a direct provider at an endpoint of its own
(G257). Part 4b-2a builds the provider side:

- **RUNTIME**: a transported route's live `establish_route` and `renew_route` answers carry the
  `local-transport` invocation descriptor and a one-time ticket (RUN-1161, RUN-1179); no observation,
  record, retained answer or stored file holds a ticket (RUN-0543, RUN-0544; a replay carries no
  `invocation`, G255). Four §6.2 units are claimed for the Runtime-served endpoint (RUN-0220,
  RUN-0226, RUN-0229, RUN-0230); the rest of §6.2 and §4.2.1 wait for the Module Host. RUN-0045,
  RUN-0552 and IFC-0010 are remote-only and move to Tier 5.
- **TRANSPORT**: the session is bound to the Runtime's authority decision and ends with it, also
  after a renewal (TRN-0153, TRN-0317); the ticket goes only to the consumer (TRN-0195). The end of a
  route terminates, drains or closes its sessions by cause (G260). An authority end answers the Requests
  not yet admitted `NOT_AUTHORISED` and leaves the admitted ones unanswered, which the consumer fails
  `TRANSPORT_ERROR` at the close (RUNTIME l.1271, TRANSPORT l.979; G174 replaced at re-pin P5d). At 6cac8335 a drain
  terminates too: admission stops with `NOT_READY`, then ProtocolError `NOT_READY` and close (TRANSPORT
  l.977, DECISIONS I106).
- **CAPABILITY AUTHORITY**: the ticket binds the decision, its freshness and revocation (CAP-0254).
- **LOADER**: the MAY of l.193 is taken (LDR-0021 leaves inspection).

Part 4b-2b builds the consumer's transported handle, on the Runtime thread until the Module Host
moves it (4b-3):

- **RUNTIME**: `materialize_route` on a transported route connects with the route's one-time ticket
  and returns once the provider holds the session (RUN-0800, RUN-0802); a Hello rejection gives its
  code, a loss TRANSPORT_ERROR, and nothing is replayed or renewed (RUN-0803 to RUN-0806). A further
  handle needs `renew_route` (G258; RUN-0801's reuse is not taken, G164). The execution-boundary
  invariance units are claimed (RUN-0007, RUN-0008, RUN-0014, and INTERFACE IFC-0007 to IFC-0015 but
  IFC-0010): one scripted sequence gives the same codes, messages, details and payloads through a
  direct and a transported handle.
- **TRANSPORT**: the handle's observer learns a lost connection (TRN-0278; TRANSPORT_ERROR, G256) and
  the route's end (G260); a peer that is not the Runtime's identity fails the route (TRN-0187,
  TRN-0191; G259).
- **INTERFACE**: a cancelled or timed-out asynchronous call sends Cancel (IFC-0729); IFC-0480 and
  IFC-0948 move from inspection to tests.

Part 4b-2c builds events over local transport:

- **RUNTIME**: `subscribe` through a transported handle returns `LOGOS_OK` only after the matching
  successful `SubscriptionResult` (RUN-0192); handlers of transported subscriptions run on the event
  workers in commitment order, one at a time per subscription (RUN-0234); an ordinary publication
  sends each subscriber connection one Event for its own matching subscriptions (RUN-0246); a new
  connection never inherits an old invocation's destination (RUN-0832). The activation and each
  delivery are decided as on a direct route (G175); an oversized Event closes that subscriber's
  connection (G165 (a)); a connection whose output overflows is closed and the publisher waits for
  the shared output budget with no finite bound (G261, D3 (a); HOST-CONFIG).
- **TRANSPORT**: the end of a route or a release discards queued Events and releases their
  credits; no handler starts afterwards and none touches released state (TRN-0290).

The parity suites `test_routes_lt`, `test_async_lt`, `test_routes_ca_lt`, `test_events_lt` and
`test_events_ca_lt` rerun the route, asynchronous-call and event suites with every route to the test
providers over local transport. What a consumer sees differently, and why:

- A transported route's live `establish_route` or `renew_route` answer carries `invocation`; its
  replay does not (G255).
- A second `materialize_route` on one route ticket is NOT_AUTHORISED until `renew_route` (G258).
- An ended route's record stays listed until its connections have closed, a moment after the end:
  the session and the consumer's connection reach it until then (RUNTIME §7.5 l.1346).
- The wire does not carry the caller's mode, so a provider with a deferred surface serves every
  Request through it, also those a direct caller made synchronously.
- A call still running when its provider's stop deadline passes reaches its caller as
  TRANSPORT_ERROR (TRANSPORT l.543; G260), where a direct caller waits for its result.
- A handler runs on an event worker once its Event arrives, after the publication returned, not on
  the publishing thread before it returns (INTERFACE l.1961 against l.1975-1977 for a direct route).
  The suites wait for deliveries; the cases about what a handler does inside the publication are
  skipped (a nested provider entry on the publishing thread, a handler that closes the destination
  of that publication, a publication still in its handler when its invocation is released).
- A `subscribe-event` decision at delivery that does not allow ends the subscription as on a direct
  route: the provider's session sends a SubscriptionEnd, and the handle reports it (re-pin P3a,
  DECISIONS G175 amended; K40 is gone). The report runs on an event worker, as on a direct route.

### What Tier 4b step 4b-3 changes

Tier 4b step 4b-3 (DECISIONS I91) adds the Module Host, `logos-module-host`, and `hosted_dynamic`
with the `process` placement. Part 4b-3.1a builds the host program, its supervision and the carrier
(G264-G266), the Loader's hosted driver, and hosted consumer-only modules: their lifecycle and
their Runtime Control binding, events and asynchronous calls included (G267, G271), with the
execution scope `local-transport` in a `process` (G272). So:

- **LOADER**: the Loader advertises `hosted_dynamic {process}` when `runtime.module_host` is set
  (LDR-0034, LDR-0035) and never `force_release`; a placement it does not advertise is
  `unsupported-strategy` before any code is read (LDR-0067, LDR-0068). The handoff and the paths stay
  out of every record and error (LDR-0045, LDR-0149). The hosted provider endpoint (§5.3) is part
  4b-3.2's, below; the trusted transport adapter handoff (§5.4) is not used (K3: the carrier is a
  further private handoff) and is labelled `out-of-scope`, as are LDR-0163 and LDR-0164
  (`force_release`, K7). A hosted cleanup returns only once the host's end is confirmed, so absence
  is always established and LDR-0125's failed realization never arises (an inspection item).
- **RUNTIME §4.2.1**: a hosted module's Runtime Control calls are answered through its own
  attempt's binding, so they have the values, errors, decisions and transitions of a direct
  module's (RUN-0169 to RUN-0172, RUN-0180; `test_hosted` compares the same probe library realized
  both ways on two engines with one Runtime instance id). The consumer is the carrier's attempt,
  never a field of a frame. A hosted record names an artifact, never a static binding (RUN-0284).
  RUNTIME §4.2.1 and §6.2 are claimed with part 4b-3.4; that the host keeps no registry or
  routing policy, only a route's invocation material (RUN-0173), and that the boundary never
  treats an earlier view as authorization (RUN-0179) are an inspection item.
- **Ends** (part 4b-3.1b; G268-G270, G275): a host that ends by itself or whose carrier breaks puts
  its instance in `error` with `host-terminated`, fails its routes and starts termination (RUN-0812,
  RUN-0813); a deadline ends the host and keeps the deadline's classification, and a startup past
  its deadline is `error` (RUN-0227); a live application whose host ends is MODULE_ERROR. After the
  Module Loader's loss each host is ended and its cleanup resolves only when the end is confirmed
  (RUN-1067 to RUN-1070, tagged again on hosts); after an unclean end a host of the previous run is
  never adopted, and its instance waits for its restart lock (RUN-0814).
- **Hosted providers** (part 4b-3.2; G267, G272-G274): the Runtime makes and validates a hosted
  provider's endpoint before its host starts, hands the host the listener and validates the path
  again before `ready`; the Loader's record names it (LDR-0047, LDR-0049, LDR-0101, LDR-0102); a
  listener that does not arrive fails the placement with nothing served (TRN-0186, LDR-0089). The
  host serves that listener only, with the Runtime's transport loop. Payloads go between the
  consumer's process and the host directly, and the Runtime stays on the control path (the owner's
  direct layout, G267): it judges every Hello, admits every call, subscription and delivery and keeps
  every session, from what the host reports without payloads; the host keeps only the session state
  it was given, checks each payload with the Runtime's own checks on the same contract, runs the
  provider and commits the Response (G273), and reports the commitments a call record retains
  (G274) (RUN-0226, RUN-0815, LDR-0147, TRN-0317). No carrier frame holds a request, response or
  event payload (`test_hosted_routes` P-13 traces every frame). So a route to a hosted provider
  behaves as a transported route to a direct one; `test_hosted_routes` (P-1 to P-14) shows it with
  the meter kit library realized in a host. With no routing rule a route with a hosted end is
  `local-transport`; a `direct` rule naming a hosted module is refused (G272). TRN-0184 to
  TRN-0186, LDR-0081 to LDR-0083, LDR-0145 to LDR-0147 and RUN-0200 are claimed with part 4b-3.4;
  `test_module_host` (H-5, H-6) shows the host's side of the listener.
- **Hosted consumers** (part 4b-3.3; G267): a hosted consumer's route handles and connections are
  in its host, which keeps a route's invocation material from the answers it passes on and nothing
  else of the Runtime's state (RUN-0173 to RUN-0176; RUN-0173 is also an inspection item, with RUN-0179), and
  connects to the peer identity and module the Runtime names (TRN-0187). The host sends
  `materialize_route`'s exact route id, expected root and construction input (RUN-0177); the
  Runtime rebuilds the contract and makes the §4.1 checks against its current state (RUN-0178,
  RUN-0179), and admits each call, subscription change and end observer in a direct handle's
  order, so codes, ends and their causes are a direct consumer's, and a handle is never retargeted
  (RUN-0181, RUN-0182, RUN-0256, RUN-0837); a stopping hosted consumer's calls are refused
  NOT_READY from stop step 1 as a direct one's (RUN-1093, RUN-0794). `test_hosted_routes` (C-1 to
  C-10, S-18) shows it with the probe kit library in a host, to direct and hosted providers, and C-14
  with a consumer written with lcn-gen's typed helpers (Tier 5 step N-1). The
  host waits for its handlers, end observers and completions before `_MODULE_destroy`.
- **Boundary invariance** (part 4b-3.4; RUNTIME l.51-53, l.161, l.970; INTERFACE Abstract):
  `test_boundary_invariance` runs one case table from the probe through one route handle in four
  placements (a direct or hosted consumer, a direct or hosted provider) and finds every answer,
  validation detail, response, delivery and completion, and the selected contract, the direct
  run's: the meter kit's calls, failures, events and asynchronous calls, the same through a deferred
  provider, and the shapes kit's C shapes and payload depth limit. RUN-0007, RUN-0008, RUN-0014,
  RUN-0181 and IFC-0007 to IFC-0015 (but IFC-0010) are tagged again with it.
- **Differences from direct realization**, none visible to a module's Runtime Control calls: a
  host's environment is `module_host_env` only, and on macOS CoreFoundation may add its own
  `__CF_USER_TEXT_ENCODING` inside the process.

### What Tier 4b step 4b-3b changes

Tier 4b step 4b-3b (DECISIONS I92) builds the erasure of marked payloads (INTERFACE §1.4.1), so the
**INTERFACE** entry changes: IFC-0575 to IFC-0577, IFC-0580 and IFC-0581 are claimed, and
**SECURITY CONSIDERATIONS** claimed SEC-0057 until re-pin P6b, where SEC l.404 became descriptive and
the IFC units carry it. IFC-0575 is claimed for orc builds of the Runtime and the
host; a refc build of either never carries a marked payload. So:

- **Who erases** (G277, the owner's reading of l.388): each participant answers for its own copies.
  The Runtime, the endpoints it serves, the Module Host and the code lcn-gen generates are the
  participants this repository controls; a module's own copies are the module's (l.400-401).
- **What is erased** (G276): byte buffers that can hold a method payload are zeroed at last use
  whether or not it is marked; value trees, commitment intermediates and hasher states when the side
  is marked, and always where they exist before the method is resolved; generated code for marked
  declarations only. A shared request copy is released only once execution is released and nothing
  holds it, through a cancel or a timeout too (IFC-0576, l.2121).
- **Paths** (G277, re-deciding G244): a contract that marks a payload is routed on `direct` and
  `local-transport` paths, hosted ends included, and refused MODULE_ERROR only on a path kind without
  erasure (a remote mode, once Tier 5 adds one); no switch turns the refusal off (IFC-0578,
  IFC-0579). The remote profiles `logos.remote.tls-tcp` and `logos.remote.quic` carry no marked payload:
  a route on either whose permitted scope includes a marked method is refused INVALID_PARAMS (RUNTIME
  l.1808, l.2939; TRANSPORT l.1188-1189; re-pin P4d, `runtime/remotemarked`), a check 5-7a calls where it
  builds remote routes.
- **Builds** (G277's build condition, IF l.388-389): a participant erases only in an orc or arc
  build, where a channel moves a message's heap parts; under refc a channel deep-copies each message
  and frees the copy unerased. A refc Runtime refuses every marked route, with G244's code, message
  and place; a refc Module Host fails the `init` of a provider whose contract marks a payload, and a
  hosted consumer's materialization of a route to one. No channel message holds a payload's bytes or
  a payload value root inline (G276; W-12), since a channel copies inline bytes into its queue and
  never clears them.
- **Diagnostics** (G278): for a marked request the INVALID_PARAMS path stops before the first key
  taken from the payload; generated messages for a marked declaration carry no path; a provider's
  failure text is forwarded to its caller only; no marked value or value root reaches a diagnostic,
  an audit record, an observation result or the carrier (IFC-0580).
- **Retention** (IFC-0581): a decision that retains a marked side refuses the call NOT_AUTHORISED
  before dispatch, recorded as `sensitive-retention` without a value root, on direct, transported
  and hosted paths alike; an unmarked method of the same contract keeps its retention.
- **How it is shown**: test builds rename `free` and `realloc` to a scan that searches every
  released block for a per-run canary and the value roots of the payloads that carry it
  (`base/wipeaudit`; "Test hooks" below). `test_wipe_routes` runs every method and rejection of the
  `vault_module` kit, whose contract marks `store`'s request, `fetch`'s response and both of
  `exchange`, through raw dispatch, the generated typed entries and the generated call helpers, on
  direct, transported and hosted routes, with a deferred provider through a cancel and a timeout,
  and with audit builds of the Module Host for a hosted provider and a hosted consumer: no released
  block, carrier frame, host stderr, diagnostic, record or engine file holds a pattern. The carrier
  trace exempts exactly the `init`'s `wipe_audit`, the patterns themselves, and runs from before the
  hosts start. The scan proves itself in-process and in an audit host (W-3: a copy left unwiped on
  purpose makes the host exit 97), which tells an armed host from one never armed. The scan sees the
  Nim heap under orc and arc; under refc the cases that need a marked route are skipped, and W-10
  and `test_hosted_routes` C-10 check the refusal on the product paths, with no test hook. A refc
  host under an orc Runtime is checked too.
- **Not claimed** (also under "Properties not claimed"): a host ended by force, a refc build of the
  Runtime or the Module Host (it refuses instead), values reached through a ref in generated code
  under refc, the kit's per-thread failure text until the thread's next kit call, and values held on
  the stack.

### What Tier 4b step 4b-5 changes

Tier 4b step 4b-5 (DECISIONS I94) adds the reference orchestration module, `lcn_orchestrator`, so the
**RUNTIME** entry changes: RUNTIME is claimed for the engine with the reference orchestration module,
wherever a host names it in `orchestration` (logosd will, from step 4b-6); a host that names another
module carries the duties `docs/HOST-CONFIG.md` lists under "Orchestration duties". The orchestration
module's duties leave the deferred list: startup defaults (RUN-0025), acting only through its Runtime
Control binding (RUN-0021), reconciliation and resumption (RUN-1063, RUN-1065), the restart policy
and its accounting (RUN-0684 to RUN-0686) and the cancellation of pending recovery (RUN-0687) are
claimed; the module's tests tag RUN-1064, RUN-0983 and RUN-1055 besides their inspection items.
RUN-0696 (resumption once permissions or authority allow) is claimed by part 4b-5c, which makes the
module take `permission_settings_changed` as a hint: its tests cover a permission withdrawn and given
back, a startup default refused for a missing permission, and a resumption that is accepted and then
fails (charged), besides the authority half's cases. The same part widens what the module reads as a
resumption to four classifications that name an enforcement outcome (DECISIONS G291 as amended), and
a source test pins the engine routines that set the authority and permission ones. "The reference orchestration module" in `docs/HOST-CONFIG.md` documents its configuration, its
state file and what it decides.

### What Tier 4b step 4b-4 changes

Tier 4b step 4b-4 (DECISIONS I93) builds permissions, the half the Runtime enforces. Part 4b-4a
builds the registry and the Capability Authority's side, so the **CAPABILITY AUTHORITY** entry
changes: §3.5 is claimed. The one profile this repository ships, `logos-core-nim.permission-profile.v1`
(G279), defines `logos-core-nim.host-ambient`: its constraints, containment, enforcement component
(Runtime admission) and its unenforceable and revoked behaviours (CAP-0021, CAP-0083;
`docs/PERMISSIONS.md`). The authority takes the selected profile through its wiring: an undefined
permission is `unknown-permission`, constraints that do not conform `invalid-constraints` (CAP-0072 to
CAP-0074), and a start needs its execution scope and every permission scope in one rule or grant
(G207 amended). Inspection items carry the facility classes (CAP-0075 to CAP-0082: one name stands for
all seven, with no per-class limit; G283), device restrictions (CAP-0292, CAP-0293, not applicable) and
provider-enforced permissions (CAP-0294 to CAP-0297, not applicable; G286). Hosted placements
(CAP-0065, CAP-0066) are claimed with part 4b-4c, below.

Part 4b-4b builds the Runtime's half in direct mode, so the **RUNTIME** entry changes: with a profile
selected in `app-config.v1` `permissions`, each instance has its own permission settings, provisioned
by the host, saved and restored (`prm`), replaced by `update_permission_settings` and reconciled by
stopping a running instance with its intent and origin kept (RUN-0914, RUN-1066); settings that
cannot be enforced are `failed` (G281, G285). Admission refuses settings that are `failed` or lack
host-ambient before any decision (G284), the execution decision covers one permission scope per saved
setting (G217 amended; CAP-0063, CAP-0068), `get_execution_permissions` answers the permissions
admission installed (G282), a revoked grant stops the instance (CAP-0192), and
`permission_settings_changed_event` follows every committed change. RUN-0914, RUN-1066, RUN-0923 and
CAP-0192 are claimed, and the settings units the constant form (G229) answered by inspection are now
tested. Without a profile the constant form stands. PKG-0335 moves to Tier 5: no requested permission
reaches a scope until package-backed requests are presented to policy.

Part 4b-4c extends this to hosted instances, so the **CAPABILITY AUTHORITY** entry is claimed whole:
a hosted start's execution decision is asked before the Loader realizes the Module Host's process and
covers `local-transport` in the `process` placement and the permission scopes (CAP-0065, CAP-0066;
G272). The settings of a hosted instance settle once its host's forced end is confirmed (G285), and a
hosted instance whose host of the previous run may still run holds them `pending` until its restart
lock is free (G275). Sandbox and container placements, and any enforcement by the operating system,
are not built and are outside Tier 5 (DECISIONS D16; Tier 5 plan §3, area K; corrected 2026-11-17,
step 5-0).

### What Tier 4b step 4b-6 changes

Tier 4b step 4b-6 (DECISIONS I95) builds `logosd`, the host of one Runtime, the persistent `logosctl`
module with its owner-only socket (D13 (a)) and the shell `logosctl` (`docs/DAEMON.md`).

- **SYSTEM BCP**: the logosctl instance is the activation path of BCP l.384-390 (G296): BCP-0084 and
  BCP-0086 to BCP-0089; its wire format is documented (BCP-0090, `logos-core-nim.ctl.v1`); and the
  development switch (D27, G299, G300): non-production is identified in the start log and every
  `logosctl` output, development trust comes only from the protected trust file, and the switch never
  bypasses authority (BCP-0093 to BCP-0096; inspection items `bcp-non-production-doc` and
  `bcp-switch-gates`). BCP-0036, BCP-0049, BCP-0050 and BCP-0092 are tagged by `test_logosd` and keep
  the BCP's `deferred:tier-4b` default until logosd composes the whole system (4b-8).
- **RUNTIME**: under logosd the Runtime id is host-assigned by `logosctl init` (G192 amended), and
  logosd ends its process when the Module Loader fails (l.3823-3824; G302): it does not destroy the
  Runtime, confirms every Module Host gone by its restart lock, and exits 4.
- **CAPABILITY AUTHORITY**, call evidence: CAP-0415 to CAP-0418 stay claimed through the library's
  integration (I85). logosd adds a persistent store and an owner-only offline export (G301): the record
  as stored, complete and with no proofs, signed with the session's current evidence key for the Runtime
  its binding names. What the store keeps, how long, and what it does not protect are documented in
  DAEMON.md §9 (CA l.1320; CAP-0415): it is plaintext, protected by file modes only, and drops records
  under load as recorded gaps. A hosted provider's roots in a stored record rest on its Module Host, as
  for the ring (G274).
- No remote listener, export or enrollment exists (G298, K19): the remote Runtime Control methods
  answer after authorization as `docs/HOST-CONFIG.md` says.

### What Tier 4b step 4b-7 changes

Tier 4b step 4b-7 (DECISIONS I96) builds state transfer to a replacement instance (RUNTIME
l.3546-3554): a `state_transfers` entry in protected host configuration (G306) gives a new instance,
with a fresh state assignment of its own (G305), the state of an instance it replaces, applied once at
`start`. Part 7a builds `move` (G307), part 7b `copy`.

- **RUNTIME**: RUN-0925 (permissions, configuration and grants come from the replacement's own
  provisioning) and RUN-0998 (the source stopped and quiescent before its state is migrated: no
  realization or cleanup left, a hosted source's restart lock present and free) are claimed.
  RUN-1000 moves to Tier 5: the replacement's ordinary package acceptance waits for the Package
  Manager; its authorization, initialization and readiness are the ordinary ones and are tested.
- What a `move` relies on: one `rename(2)` within `state_root`'s file system, then a flush of the
  directory. A crash after the commit is completed at the next start; a target whose directory is
  missing is never started on an empty one. Processes a module started on its own are outside the
  quiescence evidence, as for a restart.
- What a `copy` relies on: the whole tree measured before anything is written, then copied into a
  staging directory in `state_root` with every file and directory flushed before the commit, so a
  committed copy is always complete; the next start renames it, or removes a staging directory no
  commit owes. Directories and regular files only; owners, times, extended attributes and ACLs are
  not kept. The state passes through the Runtime's process (the owner's F1), one 64 KiB buffer zeroed
  before it is freed; that erasure is claimed for orc builds only (R5), like the marked-payload
  erasure. `copy` is not built on Windows (`LOGOS_ERR_MODULE`).
- Part 7c builds the separately authorized disposal of preserved state (RUNTIME l.3587-3588, BCP
  l.394-395): `logosctl state purge`, offline, for a retired instance's directory only, never while a
  transfer from it is owed; and `logosctl state list`. The tombstone keeps the assignment reserved.

### What is claimed at the end of Tier 4b

Tier 4b is closed (DECISIONS I97, 2026-11-16): `spectrace gate --closed-tier 1 --closed-tier 2
--closed-tier 3 --closed-tier 4 --closed-tier 4b` (the flake's `spec-gate` check) fails on any
status that still defers to one of them. The sections above say what each step changed; this is the
claim as it stands.

- **RUNTIME** is claimed for the Runtime instance that `logosd` runs: the engine plus the reference
  orchestration module (RUNTIME l.66; DECISIONS I94), in direct and local-transport mode, with hosted
  realizations through the Module Host (I91). A host that embeds `liblogos_runtime` without `logosd`
  names the reference module or carries its duties itself (`docs/HOST-CONFIG.md`, "Orchestration
  duties"). Tier 5: remote mode, facades, enrollment, listeners and exports, and package-backed
  selection with the Package Manager handoff (owner decision 1 (a)).
- **LOADER** is claimed for `direct_static`, `direct_dynamic` and `hosted_dynamic` with placement
  `process`; `sandbox` and `container` are refused `unsupported-strategy`. Out of scope: force
  release (LDR-0163, LDR-0164; K7) and the §5.4 adapter handoff (K3).
- **CONFIGURATION** is claimed, with the Loader's handoff to hosted modules.
- **CAPABILITY AUTHORITY** is claimed. Permissions are one definition, `logos-core-nim.host-ambient`,
  enforced by Runtime admission (CAP-0075 to CAP-0082 by inspection, G283; CAP-0292 and CAP-0293 and
  CAP-0294 to CAP-0297 not applicable, G286). It grants or refuses all of a module's operating-system
  access at once; no finer containment is claimed (`docs/PERMISSIONS.md`, "What is not enforced").
- **TRANSPORT** is claimed for the sans-I/O protocol, the unix-stream I/O layer and its integration
  into the Runtime and the Module Host. Out of scope: §8.1.2 (G48(a)). Tier 5: §8.2.1 (Windows) and
  the remote profiles.
- **INTERFACE** adds execution-boundary invariance (direct against local transport, I91) and
  marked-payload erasure for orc builds, with the five non-claims below (I92). Tier 5: remote mode
  (IFC-0010) and remote bindings; the reverse mapper is claimed in step 5-1 (below).
- **PACKAGE MANAGER** keeps Tier 3's artifacts and the §11 resolver, and adds PKG-0288 (by tags) and
  PKG-0422 (a true "no", G137 as amended 2026-11-16). The handoff (§17), trust continuity beyond
  PKG-0422's statement (G299) and installation are Tier 5.
- **SYSTEM BCP**: `logosd` follows §5.1's bootstrap (BCP-0021 to BCP-0024 are claimed as met, I97's
  rule; G310) and publishes the §5.4 deployment document, [DEPLOYMENT.md](DEPLOYMENT.md). Every gated
  unit of §5.2 to §5.5 that it meets or answers is claimed; `spectrace deploydoc` (flake check
  `spec-deploydoc`) keeps the document's items, the units' evidence and its duty table in step, and
  `tests/test_deployment.nim` checks its facts against the code. **No complete Logos module system is
  claimed** (below). Tier 5: the QUIC and Package Manager realization profiles.
- **SECURITY CONSIDERATIONS**: as at the end of Tier 4, plus SEC-0057 (marked-payload erasure, orc
  builds). At 6cac8335 `conformance/claims/SEC.toml` claims no unit: SEC-0021 and SEC-0057 were
  retired, their rules descriptive and carried by BCP-0049, BCP-0050, BCP-0081 and IFC-0575 to
  IFC-0581 (re-pin P6b).

The gate at the close: RUN 829/829, LDR 131/131, CFG 122/122, CAP 385/385, TRN 242/242, IFC 624/624,
PKG 212/212, BCP 49/49, SEC 2/2, with nothing deferred to Tier 4b and to Tier 5 RUN 133, TRN 58,
IFC 172, PKG 308, BCP 4, SEC 1.

### What Tier 5 step 5-1 changes

The C-to-CDDL reverse mapper, `lcn-gen cddl` (DECISIONS I98, D30, G139; G317 to G322). INTERFACE §3 is
claimed in both directions, with IFC-0003 and IFC-0004: IFC 776/776, with 20 units left for Tier 5
(IFC-0010 and the remote bindings of §5.2).

Since 6cac8335 (re-pin P2) the common names are the ones the INTERFACE §5.2 listing states, and
`logos_types.h` is that listing copied (G158 settled, I26), so IFC-0003, IFC-0004 and the §3.8 units
(IFC-0355 to IFC-0357, IFC-0861 to IFC-0863) no longer hold under an interim. The subject is mapper
input: `lcn-gen cddl` needs `--module` or `--subject` (INTERFACE §3.2 l.2244-2246; G318).

**Limits of the claim.** `lcn-gen cddl` refuses a header set over 16 MiB (G321). A schema set within the §5.3 limits can generate
a larger one, for example when inline declarations are nested deeply, and the §3.8 round trip is not
provided for such a set. The refusal is explicit and nothing is written. At this limit the tool can need
about 3 GB of memory.

### What Tier 5 step 5-2 changes

The `logos.remote.tls-tcp` carrier's library (DECISIONS I99; G323 to G328), under
`src/logos_core/transport/tls/`: TLS 1.3 only with mutual authentication over TCP, the RFC 9266
channel binding, the signing seam and P-256 credentials. Nothing runs it yet: the TLS processes that
will (facade and listener processes, logosd's signing service) are steps 5-7a and 5-7b, and no
deployment enables a remote surface (`docs/DEPLOYMENT.md` keeps its answers). TRN-0219, TRN-0220,
TRN-0228, TRN-0233 and TRN-0376 are claimed by `tests/test_remote_tls.nim` (part 5-2b).

Part 5-2a adds the verifier: a trust snapshot built from protected input and never changed by a peer,
and nine checks in a fixed order (accepted time, one certificate that is a direct anchor, the
enrollment, the key, complete DER equality with the anchor, validity, Key Usage, Extended Key Usage,
unprocessed critical extensions; G324, G325). Accepted current time is the system clock at or past
`TimeFloor`. TRN-0216, TRN-0221, TRN-0223 to TRN-0226 and TRN-0370 to TRN-0375 are claimed. What needs
routes, tickets, provider sessions and the remote trust input stays Tier 5 (5-7a), and TRN-0222 waits for
the facade process that passes the invocation's Runtime as the one expected (5-7b). The suite's Nix checks
also run the carrier against pyOpenSSL (G128, suite `tls.independent peer`); where `LCN_TLS_PEER_PYTHON` is
not set, as under `nimble test`, those five cases are skipped.

Part 5-7a-1 adds the protected input the snapshot is built from: logosd's remote trust input and its
mark (G408), accepted at the start before any connection (TRN-0217), and the Runtime's own credential
(G409), the one algorithm pair this implementation offers and accepts (TRN-0369). The handshakes are
signed through the control channel by logosd's signing service, its key holder or, in tests, the
process itself (G410), each in `test_remote_tls`.

Part 5-2d pinned nim-boringssl 0.0.16 and turned on its `BORINGSSL_ZERO_RECORD_BUFFERS` (G327). The re-pin
to 6cac8335 took the option off again (P4d): the new text forbids marked payloads on `tls-tcp` and `quic`
whatever the library does (TRANSPORT l.1188-1189; RUNTIME l.1808, l.2939), so the build is upstream's
BoringSSL, whose TLS record buffers keep the plaintext they carried. The carrier still erases its own
copies of decrypted data (G276: the stream's read buffer, partial frames, frames not taken, the framed
copy of a body it sends). A frame read is the caller's (`TlsFrame`), as is a body given to `writeFrame`.
`test_remote_tls`'s free scan finds no released block of the carrier's holding the plaintext of 256 KiB
sent through two streams; BoringSSL's blocks, all C++, are zeroed and released unscanned (G276).

Not claimed: erasure on remote paths. `tls-tcp` gives none and carries no marked payload; a route on it
or on `quic` whose permitted scope includes a marked method is refused (G277, `runtime/remotemarked`,
called from 5-7a; RUN-1163 and TRN-0398 are deferred to it).

### What the re-pin's P8a changes

Contract extension at 6cac8335 (DECISIONS I112, G392), in the SDK and the Package Manager:

- **The relation** (COMMITMENT §9.1): claimed for two documents this implementation constructs. A claim alone never
  establishes it (CMT-0242).
- **The descriptor's `extends`** (INTERFACE §2.6): limits, order, identity across the three arrays, each entry built by the
  rules of its role and related to the described contract of its namespace (IFC-0968, IFC-0969). IFC-0246's comparison of
  supplied references is claimed with the Runtime's use of it (P8b, P8c).
- **Schema answers** for an earlier root (IFC-0958): claimed by the binding's answer. No route selects an earlier root until
  P8b lets a record state `extends`.
- **The Package Manager** (PM §4, §9): every contract document is built from the selected variant and compared with its
  commitment, and each `extends` entry is checked against the declaration's contracts when the Package Manager can build the
  pair (PKG-0577 to PKG-0580, PKG-0589, PKG-0590). When it cannot, the Runtime validates the provider (PM l.1143); that half
  is P8b's.

### What the re-pin's P8b changes

Contract extension in the Runtime at 6cac8335 (DECISIONS I112 part b, G394, G391):

- **Records** (RUNTIME §8): `extends` in the host configuration, the store and static records; unique with `implements`,
  never without a primary contract or `implements` (RUN-1105, G394 r10, r11). Each set a record states must equal the
  validated descriptor's; a claimed relation the descriptor does not establish fails the bind (RUN-0265, RUN-1104). Once a
  record supplies any reference, an omitted primary is none and an omitted `implements` or `extends` is empty, each
  compared (IFC-0246; G393, the interim on TF-62; re-pin P8c).
- **Preserved facts** (RUNTIME l.1303; RUN-0258): claimed for the stored record of a host-configuration input, which keeps
  `extends` with the other facts and compares it when the instance comes back. The handoff path is 5-8's, and 5-8's
  handoff test carries the id. The claim rests on G393's strict rule: nothing a record does not state is exposed.
- **Routes to an earlier view** (RUNTIME l.90-91, l.1347, l.1368, l.2852, l.2995; INTERFACE §1.2): claimed over direct
  routes, the Runtime's local-transport endpoint and a hosted consumer's session (IFC-0957, IFC-0958's route half). A
  hosted provider that extends is checked in process only: no kit or generator takes `extends`.
- **Discovery** (CA l.249-256): one `discover` decision per extended view (G394 r15).
- **The handoff's `extends`** (PM §12; PKG-0338, PKG-0347, PKG-0351): deferred by name to 5-8 (G391).

### What the re-pin's P9 changes

The Credential Store scope, the claim statement and the close at 6cac8335 (DECISIONS I113, G159, G309, D27, I94, I104):

- **The deployment document's new items** (BCP §5.4): BCP-0101 (the Credential Store, `None`, by inspection) and BCP-0102
  (admission pools, by the test_deployment test) are claimed. BCP-0103 (non-production mechanisms identified by name)
  is claimed by the logosd test that carried BCP-0093, which is retired at 6cac8335.
- **The Credential Store** (LOGOS-MODULE-CREDENTIAL-STORE) is not claimed (owner row 38; G159 settled): "Properties not
  claimed".
- **The claim statement** (BCP l.286; TXT-0350): "Claims" above; test_deployment compares the facts' composition with
  logosd's.
- **The pending file** holds only the 53 units and 19 text entries that stay deferred past the re-pin, each owned by a
  Tier 5 work item (I104's note); nothing else follows `6a4dfa28`.

### What Tier 5 step 5-4 changes

The Windows spike and the Windows CI leg (DECISIONS I100; G329 to G334). TRN-0352 is claimed: an
unsupported placement fails without an unprotected fallback or isolation downgrade (TRANSPORT l.1152). On
Windows, where `logos.local.unix-stream` is not supported until 5-9, the Loader advertises no hosted
placement and refuses a hosted request before any artifact code is loaded, the module is never realized
direct instead, the unix-stream entry points fail and leave nothing behind, and a local-transport rule
is refused (`tests/test_windows_profile.nim`). The evidence runs on the Windows CI leg only, which
blocks since part 5-4c; elsewhere the suite skips. The other 16 §8.2.1 units, Windows support itself,
are 5-9's.

### What Tier 5 step N-1 changes

The module kit (DECISIONS I101; G335 to G342). Sub-part 2 adds lcn-gen's consumer helpers (G339): a
generated `<stem>_calls.nim` has, over a wrapped route handle, a typed `subscribe` per event and
`invoke` and `prepareInvoke` per method, and `logos_sdk/kit/routes` gives a module instance its
routes and typed Runtime Control subscriptions. IFC-0671, the permission for a generated typed
subscription helper, is taken for Nim and leaves the inspection item for a test
(`tests/test_consumert.nim`); IFC-0192, its C example, stays an inspection item, since
`<stem>_calls.h` has no subscription helper. The helpers keep IFC-0966 and IFC-0967 for a module
that uses them (the inspection item says how). A marked response decoded by `prepareInvoke` is
erased once its receiver returns (`test_wipe_routes` W-8, orc). Nothing else changes: the helpers
call the route and binding vtables as a module would, and the Runtime's side is unchanged.

Sub-part 3 adds the thread-confined kit (`lcn-gen kit --confined`; G335 to G337): each context runs
on its own module thread, every instance-dependent entry hands its work over while the caller waits,
and publication goes through a publisher thread or, in a call's scope, through the entry thread
while the module thread serves new entries. **IFC-0281 and IFC-0282 are claimed for confined
modules** (they were out of scope as requirements on modules): a direct subscriber re-enters the
publishing module during each of `publish`, `publishAsync` and `publishScoped`, from the publisher
thread and from the entry thread, with plain and async handlers (`sdk/tests/test_kit_confined.nim`),
and through the Runtime and a Module Host with the module built with the other memory manager
(`tests/test_kit_mixed.nim`, G342). A handler that blocks its module thread in a synchronous route
call of its own while the callee calls back is a route-call cycle, outside these units; the guide says
so. The consumer helpers' callbacks run on the module thread through the handle's dispatcher (G339),
with no change to what the Runtime sees.

Sub-part 4 adds the deferred provider (`lcn-gen kit --confined --async-api`; G338): the kit exports
`_MODULE_async_api`, whose `submit` queues the invocation for the module thread and returns, whose
`request_cancel` cancels an async handler's future, and whose job completes once and releases once,
the response or the failure's diagnostics in one block its owner frees on any thread; and
`invokeAsync`, a route call as a future on the module thread. **Twelve provider units are claimed**
(they were out of scope as requirements on providers that export `_MODULE_async_api`): IFC-0743,
0746, 0748, 0750 to 0752, 0754, 0762, 0763, 0766, 0769 and IFC-0779, whose reason ("a requirement on
calling modules") was wrong, since l.2136 binds the provider. IFC-0753, claimed for the Runtime's own
adapter, gains the generated provider's tests. IFC-0758 and IFC-0767 stay out of scope, relabelled
"the author's backend": the kit cancels the handler's future, and backend work behind it is the
author's. Evidence: `sdk/tests/test_kit_confined.nim` (in process, orc, refc and orc-release),
`sdk/tests/test_kit_dylib.nim` (a confined library through its three surfaces) and
`tests/test_kit_mixed.nim` MX-4 (through the Runtime, `direct_dynamic` and hosted). Nothing changes
on the Runtime's or the Module Host's side, which already served deferred providers (I78).

Sub-part 5 adds interface-only provider kits (`lcn-gen kit --module:NAME` without a primary
document, and `--extends` for the descriptor's earlier contracts; G339). No unit changes status:
INTERFACE l.2833-2840 (IFC-0877 to IFC-0881) were claimed for the C mapping and the reverse mapper,
and the kit's cases join IFC-0880 and IFC-0881 for the conformance set's other three cases. An
interface-only kit, an events-only one whose descriptor carries the earlier contract it extends, a
types-only primary with a callable interface, and a lifecycle-only module each describe exactly
their binding (IFC-0230, IFC-0231) and export exactly the functions its header declares (IFC-0878).
Evidence: `sdk/tests/test_kit.nim`, `sdk/tests/test_kit_dylib.nim` and `sdk/tests/test_nimgen.nim`.
No Runtime or Module Host code changes: both take a provider's binding from its descriptor, with or
without a primary contract (the interface-only case of `tests/test_events.nim`'s I106 test); no core
suite loads one of these kits yet.

Sub-part 6 places the confined kit in logosd and writes the author's guide. No unit changes status.
The ledger, a confined kit module built with refc, runs in orc logosd's own process
(`direct_dynamic`) and in a Module Host it starts (`hosted_dynamic`), called through `logosctl call`
by `lcn_call`: its GC'd state stays on its module thread under concurrent calls, an async handler
answers with its caller, and it stops and starts again (`tests/test_logosd.nim`; G342). The
`kit-toolchains-storage` and `kit-toolchains-delivery` flake checks (Linux) build the test kit
libraries with logos-storage-nim's and logos-delivery's switch sets, one set each, and run `test_kit_dylib`, `run.mixed` and `test_kit_mixed` against them
(G341). `sdk/docs/MODULE-KIT.md` is the author's guide, its example built and called by
`sdk/tests/test_module_kit_guide.nim`. I71's limit, that a refc module's handlers on threads other
than the loading one must not store GC'd values, now holds for kits without `--confined` only.

### What Tier 5 step N-2b changes

The CLI module `lcn_call` (DECISIONS I102; G343 to G350). No unit changes status. The CLI socket is a
second activation surface beside the logosctl instance's, documented with BCP l.389's five items in
[DAEMON.md](DAEMON.md) §7a: BCP-0085's inspection reason names both, BCP-0090's wire format now covers
`logos-core-nim.cli.v1` too, and `tests/test_lcn_call.nim` adds evidence for BCP-0086 to BCP-0089 (activation
through the logosctl instance, a request that cannot select an instance or artifact, the route `lcn_call`
holds, the launcher's uid check). IFC-0942 gains `describe`, which materializes from the surface projected to
the selected contract. RUN-0174 is re-tested for a Module Host's prepared `establish_route` and
`renew_route` (`test_hosted_routes` C-2b), which kept no material before this step.

### What Tier 5 step N-2c changes

`logosctl subscribe` and `events` (DECISIONS I102; G346, G349). No unit changes status. `test_lcn_call`
adds end-to-end evidence for RUN-1095 and TRN-0392 in logosd: a grant `lcn_call` issued itself, once
revoked, ends its subscription with `NOT_AUTHORISED` while the route stays usable, and the stream reports
it (exit 6). Events cannot be marked (INTERFACE §1.2.1 l.215), so streams add no marked payload.

### What Tier 5 step N-2d changes

`logosctl call` of a marked method on the local node (DECISIONS I102; G349's N-2d amendment). No unit
changes status. IFC-0575 gains evidence for a consumer outside the Runtime and the kits: `lcn_call` and
the launcher erase every copy they make of a marked request or response, which `tests/test_wipe_cli.nim`
(W-13) checks with the free scan in `lcn_call`'s audit Module Host, in the providers' and in the
launcher's process, on success, refusal, provider failure, cancel and a closed stdout. A marked value
reaches `lcn_call` only from a passed file, so none is in a process's arguments.

### What Tier 5 step 5-3a-2 changes

The package trust file and its administration (DECISIONS I114; G396, G397, G398; G137, G299, G303 amended).
`<session>/trust.cbor` is the package trust file, `logos-core-nim.trust.v2`: one revision covers the
development switch, the baseline signing profile, every anchor (kid, key, exact package names, development
marker) and the catalog and provenance selections. Its schema and rules are core's
(`src/logos_core/package/trustdoc.cddl`, `trustdoc.nim`), so the Package Manager reads the same document in
5-3b; logosd applies them at both reads of a start, before continuity (`docs/DAEMON.md` §6), and
`logosctl trust` writes it offline, each change as the next revision.

- **Claimed:** PKG-0418 to PKG-0421 (continuity over every field; the mark survives restart; rollback and
  other contents at one revision refused; no mark, no start, and `trust reestablish` restores it),
  PKG-0083 (a development anchor through the same file, in force only with the switch on), PKG-0166 (only
  the trust file selects a provenance profile) and PKG-0169 (a selected profile is refused before package
  material is accepted). TXT-0463 (one added name is a later revision) leaves the pending list with
  PKG-0418. PKG 253/253, with 333 units left for Tier 5.
- **Limits of the claim.** PKG-0421 rests on the Package Manager getting its trust input only from
  logosd's accepted start (5-3b builds it so; plan Q10). PKG-0166 covers "select" until a profile can be
  selected: of the seven sources PM l.733-734 lists, the Storage object arrives with 5-3b and the caller
  with 5-6a, and Nix metadata and the provenance object only if 5-10 and 5-11 are built, each adding its
  case under the same tag. Rollback resistance is not
  claimed beyond the session's own files (PM l.406): whoever can write the session can replace the file and
  its mark together.
- **Bounds.** The file is at most 1 MiB (`MaxTrustBytes`), the same wherever it is read; a kid and a
  package name are 1 to 128 bytes and a key 48 bytes. The number of anchors and names is bounded only by
  the file's size.
- **Key separation** (PM l.533): no anchor may use a call-evidence key of the session, retired ones
  included. It supplies evidence to PKG-0435, claimed since step 5-7a-1, where the TLS key and the
  evidence key each refuse the other's file (G409).

### What Tier 5 step 5-3b-1 changes

The Package Manager's engine (DECISIONS I116; G399's value, G401 to G406 as built in 5-3b-1; G90 amended,
G150 replaced), documented in `docs/PACKAGE-MANAGER.md`. It is a library in `src/logos_core/pm/` with no
I/O of its own; the module that hosts it, the daemon's end and the channel come with 5-3b-2, so logosd
still deploys no Package Manager.

- **Claimed:** PM §4.2 and §4.4 as the mandatory baseline (G404): no catalog profile exists, a trust input
  that selects one is refused by the Package Manager's input check as at logosd's start, and the catalog
  document is closed (PKG-0085 to PKG-0093, PKG-0114, PKG-0115, PKG-0449). §13's retrieval through
  `lcn.storage_fetch` (PKG-0353). The verification cache and what it may answer (PKG-0076, PKG-0077),
  rotation (PKG-0079), what no catalog or Storage content may do (PKG-0019, PKG-0021, PKG-0069, PKG-0081,
  PKG-0082), no freshness from a signature or the catalog's sequence (PKG-0112), the baseline applied with
  no provenance profile (PKG-0167), and the catalog document and its acquisition (PKG-0472, PKG-0473).
  PKG-0085, PKG-0089 and PKG-0449 are claimed by inspection. PKG 278/278, with 308 units left for Tier 5.
- **Limits of the claim.** The engine is tested in one process over scripted providers; the hosted case
  over a real route is 5-3b-2's (`test_pm_hosted`), and so is PKG-0474 (the bindings and the locator
  encodings). PKG-0080 (a removed anchor never used for an installation, update or handoff) is 5-5's; the
  inspection half is tagged here. The resolver's limits are a parameter of the engine with no configured
  source yet.
- **Bounds.** An archive at most 1 GiB, held in memory while it is checked; a catalog at most 4 MiB and
  65,536 entries; at most 4,096 cached verifications (256 by default); one call at most a day
  (300 s by default). Each is a protected input field (`docs/PACKAGE-MANAGER.md` §2).

### What Tier 5 step 5-3b-2 changes

The Package Manager as a hosted module under logosd (DECISIONS I116, closed; G399's daemon section, G400,
G402's grants and hosted case, G405's shell, G443; G140 and G361 amended). With a `package_manager` section, logosd hands one
`hosted_dynamic` instance its `lcn.pm_input` as protected realization input, adds the system rules S9 to S11, and
the instance acquires its catalog and resolves roots over routes to its Storage providers. Until step 5-6a that
module is a test build (`pmtest_module`), so a packaged deployment has none.

- **Claimed:** PKG-0474, the bindings' retrieval API and locator encodings (`docs/PACKAGE-MANAGER.md` §4,
  `sdk/docs/STORAGE-FETCH.md` §5, `docs/DAEMON.md` §3). PKG-0353 is now also tested hosted, under logosd, over
  real routes (`test_logosd_pm`, `test_pm_hosted`). PKG 279/279, with 307 units left for Tier 5.
- **Limits of the claim.** The only `lcn.storage_fetch` provider is the test fake; the storage module is N-4's.
  A trust file change reaches the Package Manager only at the next start (BCP-0049). The resolver limits are
  bounded, not cheap: at logosd's preset (G443) one package with a maximum-size manifest in the closure held the
  Package Manager's thread about a minute for one step before 5-3c-1; "Resolver limits" below gives the measured
  cost. Since 5-3c-1 and 5-3c-2 (G454, G455) the resolution's longest hold measured is under 11 ms at the preset
  and at the maxima ("The resumable run"), and a large closure costs time in all, a turn at a time.

## Properties not claimed

- A complete Logos module system (BCP §5.1; owner decision 10 (a), K18; DECISIONS G310, I97): there
  is no packaged Package Manager (the hosted one is a test build until step 5-6a, and it only resolves),
  so no package is installed, selected or trusted for running, and BCP's units that bind the whole are
  claimed only where `logosd` meets them on its own. `docs/DEPLOYMENT.md` answers each
  missing facility "None" or "Not supported", with the tier that changes it where one is planned.
- The Credential Store (BCP l.287-289; owner row 38, 2026-11-18; DECISIONS G159): optional to
  implement and deploy, and not claimed. Its provider would have to answer `NOT_AUTHORISED`, which
  provider code may not return (TF-53). logosd deploys none (`docs/DEPLOYMENT.md` row 24, §25), and the
  specification has no ledger, claims file or mirror here.
- Operating-system isolation of hosted modules (SEC l.207-209): a Module Host is a process of the
  daemon's user with the daemon's view of the file system, the network and devices; placements
  `sandbox` and `container` are not offered (`docs/DEPLOYMENT.md` §8; DECISIONS G265 for what a module
  starts, below).

- Protection between processes of the same OS identity (TRANSPORT §8.2 l.1088-1092): Module Hosts
  run as the daemon's user, so a process running as that user can replace a socket pathname or
  impersonate an endpoint. Deployments that need that protection must run hosts under distinct OS
  identities, which this implementation does not set up (DECISIONS G58). The same holds on Windows
  once the profile is built there (step 5-9): a consumer of the Runtime's own user can delete,
  rename or re-secure the endpoint, and TRANSPORT l.1137 is read as not reaching it (DECISIONS G332,
  the owner's reading, 2026-11-17).
- Containment of what a hosted module starts: a Module Host's process group is killed after every
  end of the host, but a process the module moved into another group or session outlives it
  (DECISIONS G265). Placement `process` is a separate address space, not a sandbox.
- What a hosted provider's host commits, and the roots of its call records: the host runs module
  code in its own address space (SEC l.205), and it checks and commits a hosted call's request and
  response, its Events and its scoped publications itself. So that a consumer receives only a
  checked Response, that a Runtime order (a failure Response, a session's end) takes effect when the
  host's loop processes it and nothing after it is sent (DECISIONS G273), that a call record's
  request and response roots are the values the consumer exchanged (DECISIONS G274), and that the
  host serves only the listener it was handed, all rest on the host program. Every authorization
  decision does not: the Runtime judges every Hello, call, subscription and delivery from names,
  roots and connection numbers, and no verdict reads a payload. Both are interims (plan R16, K38,
  K44), reported as TF-50 and TF-51.

- Erasure of a marked payload (INTERFACE §1.4.1; DECISIONS I92) where no wipe can run or reach:
  - **A Module Host ended by force**: SIGKILL at a startup, stop or apply deadline (G269), or
    `_exit(70)` on a broken carrier (G266), ends the process without running any wipe. This is a
    non-claim for that host's own buffers only (LOADER l.571 permits the forced end); the Runtime's
    and the peer's keep their claim.
  - **A refc build of the Runtime or the Module Host**: under refc, Nim's `Channel[T]` deep-copies
    each message into the channel's region and frees that copy inside the standard library,
    unerased, and the Runtime and the host pass payload bytes in channel messages. So a refc build
    never carries a marked payload: the Runtime refuses every marked route, and the host a marked
    provider at `init` and a marked route at materialization (G277). IFC-0575 is claimed for orc
    builds of the Runtime and the host. What ships is orc (`build_runtime_lib`, the packaged host).
  - **Generated code under refc** is claimed except for values reached through a ref (a recursive
    type): `wipeTyped` follows a ref only when it can see the ref is the value's alone, which only
    orc and arc can tell. Under orc a ref another owner shares is left to that owner.
  - **The kit's per-thread failure text**: a failure a kit provider returns is copied into its
    thread's slot for the caller and zeroed at that thread's next kit entry, not when the caller is
    done with it.
  - **Values on the stack**: fixed-size values held in locals (a digest, a scalar) are not zeroed;
    every heap and shared-heap copy is.
  - **A marked value typed on the command line** (DECISIONS I102, G349's N-2d amendment): `logosctl`
    takes its arguments from the process's argv, which it does not erase, and the shell keeps its
    history. `lcn_call` refuses a marked request given as `NAME=VALUE` or `--request` before reading
    anything, so the value reaches no provider; the launcher, which has no schema, sends it in the
    `cli.v1` frame, and both wipe their copies of that frame. A marked value is given from a file or
    stdin (DAEMON.md §7a).
  - **What a marked response's reader keeps**: `lcn_call` writes a marked response to the stdout the
    launcher passed and wipes its own copies; sensitivity does not protect plaintext from its
    intended recipient (INTERFACE l.380-381), and a terminal, pipe or file that receives it is the user's.
  - **A provider's own failure text**: a provider that puts a marked value in its failure message or
    detail sends it to the caller, and `lcn_call` shows it, labelled "(declared)", without erasing its
    copies of that text. §1.4.1 binds the marked request and response; the kits' typed consumers erase
    a failure's text too (DECISIONS I115), `lcn_call` does not yet [IMPL].

## Unix-stream endpoints and peer checks

TRANSPORT §8.2 and §9.1 as built in `src/logos_core/transport/io/` (DECISIONS G58, I83):

- **Layout.** `<base>/<8 hex>/logos_<module>.sock`. The base is a real directory that only the
  effective uid can write to, or a root-owned sticky directory such as `/tmp` `[IMPL]`. The
  per-instance directory is new (a random name, never reused), owned by the effective uid and set
  to 0700 with `fchmod` whatever the umask. `bind` never follows, removes or replaces an existing
  object; the socket is set to 0600 and listens before any handoff. When the path would not fit
  `sun_path`, the socket's name is `logos_<p>.sock`, `p` the longest prefix of the module name that
  fits (RUNTIME l.296-297 leaves the concrete pathname to the implementation; G58 amended
  2026-11-21 `[IMPL]`); the directory holds that one socket, and tickets carry the path. Only a base
  that leaves no room for `<8 hex>/logos_.sock` fails, and the Runtime refuses it at open.
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
| `controlReserve` (error Responses, SubscriptionResults, SubscriptionEnds, the Hello response) | conn | 64 KiB | ProtocolError `TRANSPORT_ERROR` from the final slot, close |
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

### The tls-tcp carrier's limits

`TlsConfig` (`transport/tls/params.nim`; DECISIONS I99), checked before a connection or listener
starts. The defaults are `[IMPL]`. "listener" is one listening socket; "conn" is one TLS connection.

| Limit | Scope | Default | On exhaustion |
|---|---|---|---|
| `handshakeTimeoutMs` (TCP connect and the TLS handshake, signing included) | conn | 10 s | the attempt fails; nothing else is tried |
| `maxHandshakes` (handshakes in progress) | listener | 64 | the connection is closed at once, unread |
| `maxConnections` (connections held: handshaking, open, or in teardown) | listener | 1024 | the connection is closed at once, unread |
| `readBound` (ciphertext read from the socket and not yet consumed) | conn | 64 KiB | the socket is not read until it drains |
| `writeBound` (ciphertext sealed and not yet sent) | conn | 16 MiB | `writeFrame` fails with nothing sealed and the stream stays usable; a frame with no output waiting always fits |
| `frameLimit`, `peerFrameLimit` | conn | 16 MiB | as TRANSPORT §2.1: a declared length over `frameLimit` fails the read; a body over `peerFrameLimit` is not written |
| `closeWaitMs` (close_notify and the reader's end at close) | conn | 2 s | the connection is freed anyway |

A listener's connections hold at most `maxConnections` × (`readBound` + `writeBound` + `frameLimit`)
bytes of Transport input and output, and each listener process has one listener (owner decision B1).
A caller's outbound connections have no count here: the facade process opens one for each consumer
route and bounds them with its routes (5-7b).

## Resolver limits

PACKAGE MANAGER §11 (PKG-0597, PKG-0598) as built in `src/logos_core/package/resolver.nim`
(DECISIONS G361). Protected policy supplies every limit; `resolverLimits` and
`decodeResolverLimits` refuse a missing, non-positive or larger value before any root operation, and
no package, manifest, catalog, source or caller can change one. The maxima are the greatest values
supported (`MaxResolverLimits`); logosd's preset is what a deployment gets when its `package_manager`
section names no `resolver_limits` (DECISIONS G443; [DAEMON.md](DAEMON.md) §3):

| Limit | Maximum | logosd's preset | Counts |
|---|---|---|---|
| `partial_closure_names` | 4,096 | 256 | distinct package names in one partial closure, the root included |
| `dependency_depth` | 4,095 | 32 | the greatest number of edges on a path from the root (4,096 names make no longer path) |
| `candidates_per_name` | 4,096 | 256 | records charged for one package name: one per name and version (DECISIONS I110, B3) |
| `assignment_attempts` | 1,048,576 | 1,024 | tentative bindings in one root operation, never decreasing |

At the maxima a chain of 4,096 names resolves in each build mode (`tests/test_resolver.nim`). There
is no time-out to reach: exceeding a limit ends the root operation with `dependency-unavailable` and
changes nothing (DECISIONS G399, ruling M1), and the Package Manager's log names the limit.

### What a resolution costs

The limits bound the number of attempts, not the cost of one, so the cost was measured
(`tools/pmbench.nim`, over the shapes of `tests/support/pmshapes.nim`). The shapes run through the
Package Manager's driver with every inspection answered at once. A step is one resolver run, the time
one handler holds the Package Manager's module thread. The driver reruns the resolver from the root
after each inspection (DECISIONS G405), so a closure of n names takes n + 1 steps, and the thread is
free between two steps while a retrieval runs. The figures are CPU time, orc with `-d:release`, one
run at a time, on an Apple M1 Max (macOS) and an AMD Ryzen AI 9 HX 370 (x86_64 Linux). CI asserts
the shapes' counts, never a time (`test_pm_driver`, ruling M6). The tables in this subsection are the
resolver as 5-3b-2 built it (`10cc598`); "After the incremental search" gives 5-3c-1's.

The shapes:
- **wide**: a root with w dependency names that sort last and 20 names, each with two versions, that
  sort first, then a name no candidate satisfies, so every assignment of the 20 is tried. One
  manifest of 4 MiB holds about 80,000 dependency entries;
- **dense**: n names, each needing every later one;
- **layered**: n names in L layers, each needing every name of a later layer;
- **chain**: n names, each needing the next;
- **hub**: a dense core of n names and one name, sorting last, that needs all of them, in v versions.

**At logosd's preset** (256 / 32 / 256 / 1,024):

| Shape | Ended by | Steps | Longest step, Mac | Longest step, Linux | Total, Mac | Total, Linux |
|---|---|---|---|---|---|---|
| chain, 33 names (depth 32) | resolved | 34 | 0.56 ms | 0.53 ms | 9.9 ms | 11.6 ms |
| dense, 32 names | resolved | 33 | 2.0 ms | 1.8 ms | 27 ms | 21.7 ms |
| layered, 256 names in 32 layers | resolved | 257 | 659 ms | 553 ms | 60.9 s | 43.5 s |
| hub, 30 names, 256 versions of the last | no closure | 288 | 49 ms | 38 ms | 6.6 s | 5.2 s |
| wide, w = 80,000 | `assignment_attempts` | 31 | 55.7 s | 76.0 s | 121.3 s | 171.2 s |
| dense or chain past depth 32 | `dependency_depth` | 34 | 18 ms | — | 0.26 s | — |

**At the maxima** (4,096 / 4,095 / 4,096 / 1,048,576), with `assignment_attempts` lowered where a row
says:

| Shape | Attempts | Ended by | Steps | Longest step, Mac | Longest step, Linux | Total, Mac | Total, Linux |
|---|---|---|---|---|---|---|---|
| wide, w = 10,000 | 1,000 | `assignment_attempts` | 31 | 5.55 s | 3.29 s | 12.0 s | 7.67 s |
| wide, w = 80,000 | 100 | `assignment_attempts` | 28 | 4.98 s | 6.92 s | 23.6 s | 33.4 s |
| wide, w = 80,000 | 1,000 | `assignment_attempts` | 31 | 49.5 s | 73.6 s | 113.7 s | 167.7 s |
| wide, w = 80,000 | 10,000 | — | — | over 900 s, stopped | — | — | — |
| dense, 128 names | | resolved | 129 | 89 ms | 79 ms | 4.0 s | 2.92 s |
| dense, 256 names | | resolved | 257 | 738 ms | 611 ms | 64.0 s | 46.1 s |
| chain, 1,024 names | | resolved | 1,025 | 312 ms | 200 ms | 99.0 s | 58.4 s |
| chain, 2,048 names | | resolved | 2,049 | 1.13 s | 734 ms | 747.5 s | 485.7 s |
| hub, 255 names, 1 version | | resolved | 258 | 698 ms | 613 ms | 59.8 s | 46.1 s |
| hub, 255 names, 4 versions | | no closure | 261 | 666 ms | 546 ms | 62.7 s | 47.7 s |

What the figures say:
- **Honest closures at the preset** hold the thread under 1 s for each step: a chain or a dense
  closure at the depth limit takes milliseconds, and 256 names in 32 layers, the most the preset
  admits of that shape, under 0.7 s. Its total is about a minute, spread over 257 steps.
- **The wide shape misses the 1 s target at the preset.** One package with a maximum-size manifest
  in the closure costs about 55 ms for each attempt on the Mac and about 75 ms on Linux, so its
  longest step at 1,024 attempts is about 56 s (Linux: about 76 s). Only `assignment_attempts` bounds
  it. `partial_closure_names` counts bound names only: the specification does not define a partial
  closure (PACKAGE MANAGER l.1243, l.1257-1260; an editorial remark in the spec owner's comments
  document, logos-lips `f19745f8`), and counting a required name before it is bound would change
  results, not only cost. No limit counts dependency entries (logos-lips `17284d73`). Any accepted
  signer with a package in the closure can bring it. The value is not lowered toward 20, which would be below
  honest need (DECISIONS G443, ruling M5).
- **At the maxima** the cost grows past any target. By extrapolation from the rows above, not
  measured: one step of the wide shape at 1,048,576 attempts takes about 14.5 h; the dense shape at
  4,096 names about 50 min for its longest step and about 48 days in total; a chain at depth 4,095
  about 4.5 s for its longest step and about 1.6 h in total. [DEPLOYMENT.md](DEPLOYMENT.md) §12 says
  what raising a limit costs.
- **Why:** each bind and each unbind recomputes every depth over the dependency entries of every
  bound package, each attempt scans every required name, and the driver reruns the resolver from the
  root after each inspection. A bind checks its bound dependencies for a cycle in one walk (DECISIONS
  G361's amendment): before, the hub of 255 names took 1,020 ms for its longest step with one version
  and 1,763 ms with four, on the Mac.
- **The cost fix** is a step of its own after 5-3b (DECISIONS G443): incremental depths, ordered
  unresolved names, a run resumed instead of rerun, and slicing by a fixed count of work, so no
  result or counter changes. It comes before 5-5, or before the first step that lets a consumer other
  than the operator's tools start a root operation, whichever is first. Its first half, the
  incremental search, is built (5-3c-1, DECISIONS G454; below). The second, the run resumed and
  sliced, is built too (5-3c-2, G455; "The resumable run" below).

### After the incremental search

5-3c-1 keeps the search and changes its state (DECISIONS G454): numbered names, the unresolved names
on a heap, depths kept for bound names with a trail, versions tested as they come, and the cycle walk
pruned by depth. The rows below are one synchronous `resolve` of each shape (`tools/pmbench.nim
--sync`), every inspection answered at once, each run in its own process: the resolver ("new") and the
frozen oracle, which is the search at `10cc598` (`tests/support/oracle_resolver.nim`). Both give the
same outcome and counters in every row, and `test_resolver` compares the two on these shapes at both
limit sets. The figures are CPU time, orc with `-d:release`, on the two machines above. Work is the
resolver's count of units (G454), the same on both. Peak is the process's maximum resident memory:
the resolver's, the oracle's, and that of the input alone (`--sync input`), which both start from. The
Mac ran these with other work loaded on it (load average about 250), so its CPU times are high.
**One run at logosd's preset** (256 / 32 / 256 / 1,024):

| Shape | Ended by | New, Mac | Oracle, Mac | New, Linux | Oracle, Linux | Work | Peak MiB, Mac: new / oracle |
|---|---|---|---|---|---|---|---|
| chain, 33 names | resolved | 0.35 ms | 0.65 ms | 0.54 ms | 0.99 ms | 385 | 7.1 / 7.1 |
| dense, 32 names | resolved | 0.74 ms | 2.4 ms | 0.65 ms | 4.0 ms | 4,558 | 7.8 / 7.9 |
| layered, 256 names in 32 layers | resolved | 30.2 ms | 728 ms | 28.1 ms | 521 ms | 286,525 | 42.5 / 45.4 |
| hub, 30 names, 256 versions of the last | no closure | 8.8 ms | 57.0 ms | 6.4 ms | 40.0 ms | 163,946 | 10.8 / 10.8 |
| lift, 30 names, 256 versions of `y` | resolved | 9.1 ms | 54.9 ms | 2.8 ms | 35.1 ms | 127,447 | 8.6 / 8.6 |
| wide, w = 80,000 | `assignment_attempts` | 67.0 ms | 64.4 s | 66.3 ms | 47.9 s | 328,234 | 198 / 153 |

**One run at the maxima** (4,096 / 4,095 / 4,096 / 1,048,576), with `assignment_attempts` lowered where a row says. The oracle is not run past 1,024 names, where one of its runs takes minutes:

| Shape | Ended by | New, Mac | Oracle, Mac | New, Linux | Oracle, Linux | Work | Peak MiB, Mac: new / oracle / input |
|---|---|---|---|---|---|---|---|
| dense, 256 names | resolved | 29.6 ms | 724 ms | 23.8 ms | 538 ms | 294,526 | 44.5 / 47.7 / — |
| dense, 1,024 names | resolved | 458 ms | 43.4 s | 347 ms | 40.2 s | 4,717,054 | 511 / 534 / 84.3 |
| dense, 2,048 names | resolved | 1.96 s | — | 1.30 s | — | 18,871,294 | 1,936 / — / 306 |
| dense, 4,096 names | resolved | 8.29 s | — | 5.83 s | — | 75,491,326 | 7,539 / — / 1,185 |
| chain, 2,048 names | resolved | 19.5 ms | 1.31 s | 14.9 ms | 754 ms | 24,565 | 17.7 / 19.2 / — |
| chain, 4,095 names | resolved | 40.1 ms | 5.79 s | 31.1 ms | 3.15 s | 49,129 | 28.1 / 30.6 / 12.9 |
| hub, 255 names, 4 versions | no closure | 28.8 ms | 700 ms | 22.5 ms | 463 ms | 460,325 | 38.7 / 39.5 / — |
| lift, 255 names, 4 versions | resolved | 33.0 ms | 759 ms | 24.9 ms | 591 ms | 390,229 | 44.2 / 47.4 / — |
| layered, 1,024 names in 64 layers | resolved | 439 ms | 44.7 s | 332 ms | 38.3 s | 4,648,069 | 503 / 525 / 83.1 |
| layered, 4,096 names in 64 layers | resolved | 8.06 s | — | 5.21 s | — | 74,330,677 | 7,441 / — / 1,168 |
| wide, w = 80,000, 1,000 attempts | `assignment_attempts` | 55.9 ms | 62.1 s | 64.4 ms | 53.9 s | 328,042 | 198 / 153 / 26.1 |
| wide, w = 80,000, 100,000 attempts | `assignment_attempts` | 233 ms | — | 217 ms | — | 1,120,042 | 198 / — / — |

**Through the driver at the preset**, which still reruns the resolver from the root after each inspection (before, from the table above → after):

| Shape | Steps | Longest step, Mac | Longest step, Linux | Total, Mac | Total, Linux |
|---|---|---|---|---|---|
| chain, 33 names | 34 | 0.56 ms → 0.30 ms | 0.53 ms → 0.46 ms | 9.9 ms → 7.2 ms | 11.6 ms → 10.5 ms |
| dense, 32 names | 33 | 2.0 ms → 0.66 ms | 1.8 ms → 1.00 ms | 27 ms → 12.2 ms | 21.7 ms → 18.5 ms |
| layered, 256 names in 32 layers | 257 | 659 ms → 39.4 ms | 553 ms → 20.4 ms | 60.9 s → 3.96 s | 43.5 s → 2.56 s |
| hub, 30 names, 256 versions of the last | 288 | 49 ms → 14.4 ms | 38 ms → 6.1 ms | 6.6 s → 1.48 s | 5.2 s → 961 ms |
| lift, 30 names, 256 versions of `y` | 288 | — → 8.7 ms | — → 2.5 ms | — → 792 ms | — → 493 ms |
| wide, w = 80,000 | 31 | 55.7 s → 77.5 ms | 76.0 s → 86.6 ms | 121.3 s → 1.98 s | 171.2 s → 2.28 s |

What the figures say:
- **An attempt no longer scans every required name.** The wide shape's 1,024 attempts take
  67 ms instead of 64 s on the Mac (Linux: 66 ms instead of 48 s), about 0.06 ms each. 100,000
  attempts take about 0.22 s, so the maximum's 1,048,576 would take about 2.4 s by extrapolation
  (before: about 14.5 h).
- **Depths change only where a bind changes them.** A chain of 4,095 names takes 40 ms instead of
  5.8 s (Linux: 31 ms instead of 3.2 s). The dense and layered shapes now cost about their edges:
  4,096 dense names (about 8.4 million edges) take 8.3 s (Linux: 5.8 s), and 4,096 names in 64 layers
  8.1 s (Linux: 5.2 s).
- **Writing the closure was cubic** in a dense closure: it copied each dependency's candidate, its
  lists included, for every edge. The oracle keeps that cost, which is most of its 43 s at dense 1,024;
  the resolver reads them in place.
- **Through the driver** at the preset, the longest step falls from 55.7 s to 78 ms (wide) and from
  659 ms to 39 ms (layered) on the Mac, and from 76.0 s to 87 ms and from 553 ms to 20 ms on Linux. The totals still count one rerun from the root after each inspection,
  which 5-3c-2 removed (G455; "The resumable run" below); its slicing is what bounds one turn at the maxima.
- **Memory** is of the same order as before. At dense 1,024 the resolver peaks at 511 MiB and the
  oracle at 534 MiB, of which 84 MiB is the input. At the maxima a dense closure of 4,096 names peaks
  at 7.4 GiB, of which 1.2 GiB is the input (Linux: 7.3 and 1.2 GiB). The rest, about 750 bytes for each of the 8.4 million
  edges, is held as before: each requirement in its dependent's candidate and in its name's list, the
  inspections and catalog picks it reads, and the closure's edges. The wide shape's 80,000 names cost
  45 MiB more than the oracle's, in the arrays kept for each numbered name.

### The resumable run

5-3c-2 (DECISIONS G455) makes a root operation's resolution one run that the driver holds for the
operation's life. Nothing is rerun from the root: a step resumes the run, and the run stops where it
needs an inspection or once its turn's work is spent (`ResolverTurnWork`, 32,768 units). Between two
turns the module thread is free for route answers, timers, readiness events and other operations
([PACKAGE-MANAGER.md](PACKAGE-MANAGER.md) §4). After the outcome the run's state is freed by turns of
their own, the release. 5-3c-3 brings contracts within the same bound: each is numbered once, in
sliced steps (G455). The rows are each shape through the driver (`tools/pmbench.nim --budget`),
every inspection answered at once, each in its own process:
- a turn is one step, the time one handler holds the module thread;
- the steps are the turns that end with the work spent ("Turns"), one for each inspection, and the
  outcome;
- the figures are CPU time, orc with `-d:release`, on the Linux machine above (framework.lan, x86_64),
  on 5-3c-3 merged with master `a27379f`, so with `CborValue` acyclic (G478), at a load under 1, with
  the queue lock held and nothing else queued. The Mac is not given: it was shared at a load of 50 to
  100 while 5-3c-3 was measured, and 5-3c-2's Mac figures, taken at a load of 30 to 80, are in this
  file's history. One run's longest turn still varies by up to half between runs (the wide shape at the
  preset: 5.0 to 8.4 ms over five runs, four of them on 5-3c-3's branch);
- work is the run's count of units (G454), the same on every machine and under any budget. It is
  higher than 5-3c-2's: since 5-3c-3 it also counts each frame's requirements, walked once for the
  contracts and pins they ask, a requirement's version text as it is copied, and each record's
  numbering (a unit, and one for each 16 of its entries for a record with no contracts; G455).

**At logosd's preset** (256 / 32 / 256 / 1,024):

| Shape | Ended by | Steps | Turns | Longest turn | Total | Work |
|---|---|---|---|---|---|---|
| chain, 33 names | resolved | 34 | 0 | 0.07 ms | 0.43 ms | 1,420 |
| dense, 32 names | resolved | 33 | 0 | 0.12 ms | 0.99 ms | 9,614 |
| layered, 256 names in 32 layers | resolved | 258 | 1 | 2.15 ms | 23.3 ms | 586,428 |
| hub, 30 names, 256 versions of the last | no closure | 288 | 0 | 0.26 ms | 10.2 ms | 219,271 |
| lift, 30 names, 256 versions of `y` | resolved | 288 | 0 | 0.26 ms | 4.94 ms | 141,629 |
| wide, w = 80,000 | `assignment_attempts` | 71 | 40 | 5.11 ms | 40.9 ms | 1,736,843 |

**At the maxima** (4,096 / 4,095 / 4,096 / 1,048,576), with `assignment_attempts` lowered where a row
says. The last row is a catalog at its bound of 65,536 entries (`package_manager.limits`), most of
them one name's versions:

| Shape | Ended by | Turns | Longest turn | Total | Release: turns, longest | Work | Peak MiB |
|---|---|---|---|---|---|---|---|
| dense, 256 names | resolved | 2 | 2.01 ms | 23.4 ms | 6, 0.59 ms | 604,974 | 34 |
| dense, 1,024 names | resolved | 57 | 2.17 ms | 271 ms | 81, 0.73 ms | 9,655,370 | 425 |
| dense, 2,048 names | resolved | 235 | 2.22 ms | 1.07 s | 320, 1.06 ms | 38,602,134 | 1,693 |
| dense, 4,096 names | resolved | 941 | 3.43 ms | 4.25 s | 1,272, 1.53 ms | 154,366,234 | 6,554 |
| chain, 2,048 names | resolved | 1 | 1.09 ms | 11.3 ms | 2, 0.59 ms | 85,988 | 14 |
| chain, 4,095 names | resolved | 2 | 2.63 ms | 22.2 ms | 3, 1.07 ms | 171,964 | 24 |
| hub, 255 names, 4 versions | no closure | 7 | 0.68 ms | 17.6 ms | 2, 0.59 ms | 778,060 | 30 |
| lift, 255 names, 4 versions | resolved | 2 | 2.06 ms | 18.4 ms | 6, 0.61 ms | 699,247 | 34 |
| layered, 1,024 names in 64 layers | resolved | 55 | 2.21 ms | 267 ms | 77, 0.71 ms | 9,494,840 | 420 |
| layered, 4,096 names in 64 layers | resolved | 1,256 | 3.66 ms | 4.16 s | 1,063, 1.61 ms | 151,657,929 | 6,486 |
| wide, w = 80,000, 1,000 attempts | `assignment_attempts` | 40 | 5.07 ms | 39.7 ms | 11, 1.40 ms | 1,735,755 | 129 |
| wide, w = 80,000, 100,000 attempts | `assignment_attempts` | 172 | 5.22 ms | 199 ms | 11, 1.59 ms | 6,190,998 | 129 |
| lift, 30 names, 65,500 versions of `y` (a catalog of 65,532 entries) | `candidates_per_name` | 34 | 6.24 ms | 63.7 ms | 7, 3.53 ms | 3,314,182 | 99 |

**The turn budget:** the plan's 65,536 units against 32,768, for the shapes whose longest turn the
budget decides:

| Shape | Turns at 32,768 / 65,536 | Longest turn at 32,768 / 65,536 | Longest release turn at 32,768 / 65,536 |
|---|---|---|---|
| dense, 4,096 names | 941 / 469 | 3.43 ms / 5.51 ms | 1.53 ms / 2.79 ms |
| layered, 4,096 names in 64 layers | 1,256 / 624 | 3.66 ms / 4.87 ms | 1.61 ms / 2.01 ms |
| dense, 1,024 names | 57 / 27 | 2.17 ms / 5.97 ms | 0.73 ms / 1.27 ms |
| dense, 2,048 names | 235 / 116 | 2.22 ms / 4.91 ms | 1.06 ms / 1.83 ms |
| wide, w = 80,000 | 40 / 22 | 5.11 ms / 5.04 ms | 1.41 ms / 3.17 ms |
| wide, w = 80,000, 100,000 attempts | 172 / 86 | 5.22 ms / 5.07 ms | 1.59 ms / 2.73 ms |
| lift, 30 names, 65,500 versions of `y` (a catalog of 65,532 entries) | 34 / 17 | 6.24 ms / 4.92 ms | 3.53 ms / 6.01 ms |

**Contracts** (5-3c-3), at the preset and 32,768 units, each listed contract a commitment's encoding of
221 bytes (`tests/support/pmshapes.nim`). `contracts c k`: k manifests of two dependency entries listing
c contracts each, on names whose records provide none, so nothing completes. `provider p l`: a record
providing p contracts, numbered out of order so they are sorted, and a later bind looking l of them up.
`versioned c v`: v versions each listing c contracts that nothing provides, each bound and given up.
Without G478 the work and the turns are the same; its other figures are under the table:

| Shape | Contracts listed | Turns | Largest step | Work | Longest turn | Total | Peak MiB | ns per unit |
|---|---|---|---|---|---|---|---|---|
| contracts 18,000, 1 manifest | 36,000 | 250 | 256 | 8,241,382 | 0.26 ms | 41.2 ms | 47 | 5.0 |
| contracts 8,000, 4 manifests | 64,000 | 443 | 256 | 14,614,068 | 0.52 ms | 75.9 ms | 78 | 5.2 |
| contracts 18,000, 8 manifests | 288,000 | 1,998 | 256 | 65,819,050 | 0.46 ms | 356 ms | 341 | 5.4 |
| contracts 18,000, 32 manifests | 1,152,000 | 7,989 | 257 | 263,218,973 | 0.54 ms | 1.44 s | 1,346 | 5.5 |
| provider 20,000, 1 looked up | 1 | 150 | 1,251 | 4,932,920 | 0.56 ms | 49.2 ms | 29 | 10.0 |
| provider 20,000, 20,000 looked up | 20,000 | 295 | 1,251 | 9,698,750 | 0.26 ms | 45.2 ms | 46 | 4.7 |
| versioned 8,000, 8 versions | 64,000 | 441 | 256 | 14,611,173 | 0.22 ms | 70.4 ms | 78 | 4.8 |

What the figures say:
- **Nothing is rerun.** Through the driver at the preset each total is one run's: 256 names in 32
  layers take 23.3 ms instead of 2.56 s, and the wide shape 41 ms instead of 2.28 s.
- **One turn holds the thread for a few milliseconds.** At 32,768 units the longest turn of every
  shape, at the preset and at the maxima, is under 7 ms here and was under 9 ms in every run of 5-3c-3's
  bench; every contract shape's is under 0.6 ms. The longest are the wide shape's, whose root, the
  build of one candidate from a maximum-size manifest of about 80,000 entries in one go, takes about
  3 ms on the Mac (G455) and whose other turns do nearly the same work, and the catalog of 65,532
  entries'. Each varies by up to half between runs (the wide shape 5.0 to 8.4 ms, the catalog 4.3 to
  6.2 ms).
- **What keeps turns even** is that work counts what takes time (G455): each list's growth, a
  candidate's manifest entries, a name first numbered in a bind (with its bytes, as the setup counts
  it), each level of a heap operation and, since 5-3c-3, each contract numbered (a unit and its encoded
  bytes), each probe of the intern table and each step of a contract lookup. Counted as one unit each,
  the wide shape's 80,000 new names and a heap holding them made turns of 10 to 16 ms at the same
  budget. A unit costs about 17 to 40 ns in every plain shape whose steps the budget ends (dense 4,096:
  154 million units in 4.25 s), and 4.7 to 10 ns in the contract shapes, whose bytes overcount (safe);
  0.7 to 1.4 ns since 5-3c-4, which encodes no catalog contract on the module thread.
  The chain shapes' time per unit is well above that, about 130 ns, as in 5-3c-2: their time is their
  steps, one for each of up to 4,095 inspections at about 42 units each, and a step's fixed cost (its
  resume, and the bench's clock reads around it) is a few µs.
- **Contracts are within the bound** (5-3c-3, G455). Before it, one dependency entry listing 18,000
  contracts on a name with a record held the thread for 5.2 s in one turn on the Mac, and its work read
  80. Now the most work counted between two turn checks is 257 units in the contract shapes and 1,251 in
  the provider shape (`largestStep`). `test_pm_driver` asserts it under 2,048 for each contract shape,
  and under a test hook that makes every contract's hash collide (2,200 contracts, 5.7 million more
  units, largest step 256).
- **Inspections carry encodings** (5-3c-4, G482). The counts are unchanged for a run that ends by
  itself: pmbench's 45 runs (19 shapes at 32,768 and 65,536, the 7 contract shapes at 32,768) give master
  `7a307a8` and this tree the same outcome, counters, steps, turns, work, largest step and release turns,
  every one (framework.lan, the two builds alternating run by run). Three exceptions, by design:
  - a run dropped while a catalog record is being numbered: its release counts that record without the
    contracts already moved into the walk;
  - the engine's turns: a judgment's decode turns are gone. Master's engine decoded the bench's
    maximal judgment, 80,000 entries and 22,000 contracts, in 100 turns of its own
    (`DecodeOperation`), 79 for 80,000 entries alone and 22 for 22,000 contracts alone; now it takes
    none (`tools/pmbench.nim receive` on both trees);
  - an inspection built by hand that repeats a provided contract: the builder keeps the repeat, where
    `provided` gives each once. No bench shape does.

  The times, from the same session: the module thread no longer encodes a catalog contract, so the
  contract shapes' totals fall to between an eighth and a quarter (contracts 18,000 × 32 from 1.45 s to
  0.36 s, 18,000 × 8 from 340 ms to 67 ms; 0.7 to 1.4 ns a unit against 4.7 to 6.3), and their longest
  turns from 0.23-0.58 ms to 0.07-0.43 ms. The plain shapes are unchanged: totals within 3% but for one
  run each way (wide with 1,000 attempts, 41 against 46 ms at 32,768 and 43 against 39 at 65,536), and
  the longest turns within their noise. The bench's peaks for the contract shapes are 1.5 to 7.5 MiB
  higher, the same at 8 manifests as at 32: the bench keeps every answer as values (the oracle's form)
  and builds a record's encodings when it is supplied, so one record's buffer lives through its walk
  beside the bench's values. In the module the values are the worker's and are freed there, and the
  resolver's own heap falls ("The operation bound").
- **Without G478, ORC's cycle collector held the thread** in the contract shapes: on 5-3c-3's branch
  before G478 (the same machine, at a load of about 4), the longest turns were 3 to 118 ms, on resumes
  that counted no more work than their neighbors, in the code that dropped the last reference to a
  `CborValue` (DECISIONS G478). Longest turn, total and peak MiB in the table's order: 7.37 ms, 55.6 ms,
  55; 9.38 ms, 97.0 ms, 93; 36.5 ms, 444 ms, 406; 118 ms, 1.71 s, 1,633; 3.02 ms, 36.0 ms, 34; 7.95 ms,
  63.8 ms, 56; 6.82 ms, 94.4 ms, 94. With it, the totals are 16 to 29% lower and the peaks 14 to 18%
  lower. Provider with 1 lookup is the exception in the table only: its total varies from 23 to 49 ms
  between runs of this tree (six runs), and over five rounds alternating with the branch its median
  is 23.5 ms against 28.6 without G478.
- **What the turn test cannot see.** `largestStep` catches work counted in one lump, not work counted
  not at all, which was the contract defect (80 units for 5 s). The bench is the check for that, at
  every change to `resolver.nim`: a shape whose steps the budget ends and whose time per unit is well
  above the plain shapes' (17 to 40 ns), or one with a long turn of little work, does work it does not
  count. It is not a suite gate: CI asserts counts, never time.
- **The shapes without contracts against 5-3c-2** (3b2d6a0, the two builds alternating, three rounds,
  both without G478): dense 4,096, layered 4,096 in 64 layers and dense 1,024 within 3%; chain 4,095
  about 23 ms against 20; lift 30 with 65,500 versions of `y` 59 ms against 54 (8%); the preset's
  shapes within their noise; the longest turns unchanged.
- **The budget:** at 65,536 the longest turns are up to about three times as long (dense 1,024: 6.0 ms
  against 2.2; dense 4,096: 5.5 ms against 3.4) for half the turns, and the totals are within 3% (the
  catalog's within 10%). 32,768 keeps most turns at 1 to 3 ms, which leaves room for a slower machine.
- **A turn bounds the hold, not the resolution.** Dense 4,096 still takes 4.25 s of the thread in all,
  in 941 turns. The wide shape at the maximum `assignment_attempts` (1,048,576) took 1.8 s on the Mac
  in 1,344 turns, the longest 5.1 ms (5-3c-2).
- **The setup** (the names numbered, each name's versions and each identity's records put in order)
  is the run's first turns (G455): the catalog of 65,532 entries has no turn over 6.3 ms. What is left
  before the first turn is the driver's copy of the catalog, 2.6 ms at 65,532 entries and under 1 ms at
  4,096.
- **The release** frees what a run holds, a turn at a time: at dense 4,096, 1,272 turns, the longest
  1.5 ms, and 0.26 s in all. Freed at once, that state held the thread for seconds.
- **Memory:** 6.3 to 6.4 GiB at 4,096 dense or layered names, 129 MiB for the wide shape and 99 MiB
  for the catalog of 65,532 entries. A listed contract is a 4-byte number in the run, each distinct
  one's encoding kept once (G477's figures below).
- **CI asserts counts:** `test_pm_driver` gives each shape, the contract shapes among them, the same
  outcome, counters, work and retrievals under budgets of 32,768, 1,000, 64, 17 and 1 units and under
  none (M6).

### The operation bound

G477. One root operation reads at most `operation_entries` inputs (5-5-3's protected key). The unit is
one walk, `inputUnits` beside `Inspection` in `package/resolver.nim`: a unit for each record read
(inspected or installed), for each of its dependency entries, for each contract a dependency entry lists
(PM l.295) and for each contract it provides; each record once. A count equal to the bound goes on; the
read that takes it over ends the operation with `package-unavailable` (PM l.1308-1309). The four resolver
limits and their counters are untouched. The count is the same on every machine; `tools/pmbench.nim`
prints it (`entries=`). 5-5-3's verification cache weighs the same walk in bytes.

| Shape | Limits | Units read |
|---|---|---|
| chain 33 | preset | 65 |
| dense 32 | preset | 528 |
| layered 256/32 | preset | 32,007 |
| hub 30/256 | preset | 8,405 |
| wide 80,000 | preset | 80,051 |
| chain 4,095 | maxima | 8,189 |
| hub 255/4, lift 255/4 | maxima | 33,668, 32,653 |
| dense 4,096 | maxima | 8,390,656 |
| layered 4,096/64 | maxima | 8,261,695 |
| wide 80,000, 1,048,576 attempts | maxima | 80,062 |
| lift 30/65,500 | maxima | 12,756 |

The table's shapes list no contracts. The resolver state a unit costs, on the Mac under orc
`-d:release` (peak RSS less the input's; `build/scratch/memprobe.nim` and `memprobe2.nim`, each
inspection built when it is asked for), by what the units are:
- requirements on names that never bind, bound by k manifests of the same 80,000 names: about 0.8 KiB;
  dense 4,096 is the same (6.5 GiB);
- the same with distinct names: about 1.6 to 1.8 KiB, the worst measured;
- dependency entries listing contracts (k bound manifests, each of 10 entries with 8,000 contracts, or
  of 1 entry with 18,000), the contracts encoded commitments of 221 bytes: about 1.5 KiB, and held and
  never bound about 1.0 KiB, until 5-3c-3 numbered them (G455). Now (`memprobe2.nim`'s `fancd`), 0.3
  to 0.45 KiB when no two manifests list the same contract: a 4-byte number for each listed contract,
  and each distinct one's encoding kept once. When they repeat, the peak is one manifest's decoded
  contracts while they are numbered, about 150 MiB for 80,000, for 8 or 16 manifests alike;
- inspections of plain entries held and never bound: 0.1 to 0.2 KiB.

Since 5-3c-4 (G482) an inspection holds each contract as its encoding, 221 bytes here, and 5 to 8
bytes beside it, where it held about 1.0 KiB of decoded values. The resolver's own heap at its peak
(`memprobe2.nim` read with `getOccupiedMem` at each turn's end, orc `-d:release`, the Mac), against
5-3c-3's tree with the same probe: when the manifests list the same 80,000 contracts, 92.9 to 42.5 MiB
for 8 manifests and 95.5 to 45.1 MiB for 16; when no two list the same contract, 377 to 328 bytes a
unit (8 manifests of 10 entries with 8,000 contracts each), 339 to 314 (16) and 362 to 332 (8 of one
entry with 18,000), most of it each distinct encoding kept once. Units, work, turns and the largest
step are the same in each. The bound's figures above stand: the worst unit is still a requirement on
a name that never binds.

So one operation's resolver state is at most about 460 MiB at the proposed default of 262,144 units,
and about 29 GiB at the proposed maximum of 2^24 (1.8 KiB a unit).

### The archive's inspection

The other hold on the Package Manager's module thread is the verification cache's inspection of a
fetched archive (DECISIONS G403; `pm/vcache.nim` `inspect`). It takes BLAKE3 of the whole archive
and, on a miss, opens it in memory with `openLgx`: the gzip member, the USTAR entries, the manifest's
signature, and the selected variant's artifacts against their digests. `archive_bytes` bounds the
archive, 1 GiB by default ([PACKAGE-MANAGER.md](PACKAGE-MANAGER.md) §2).

It was measured for 5-3c's plan §5 and for 5-5. 5-5-2b replaced the in-memory reader with a streaming
one, and 5-5-3 moved the inspection off the module thread to a spool file; both measured again at the
same sizes ("The streaming reader", "The worker and the spool"). The setup:
- the archive is signed for the host, with one data artifact of pseudo-random, so incompressible,
  bytes (`tools/pmbench.nim archive`);
- `tools/pmbench.nim inspect` reads it and times a miss, a hit and BLAKE3 alone;
- the figures are CPU time, orc with `-d:release`, each the median of three processes, with each
  process's peak memory;
- the core is 5-3c-1's, whose `lgx.nim`, `vcache.nim` and `signing.nim` are those of `10cc598`.

| Archive | Bytes | Miss, Mac | Miss, Linux | Hit, Mac | Hit, Linux | BLAKE3 alone, Mac | BLAKE3 alone, Linux | Peak MiB, Mac / Linux |
|---|---|---|---|---|---|---|---|---|
| 1 MiB | 1,065,981 | 6.5 ms | 4.1 ms | 0.62 ms | 0.14 ms | 0.62 ms | 0.12 ms | 16 / 11 |
| 64 MiB | 67,146,429 | 326 ms | 211 ms | 42 ms | 8.8 ms | 39 ms | 8.8 ms | 550 / 458 |
| 1 GiB (1,023 MiB of payload) | 1,073,037,548 | 6.03 s | 4.19 s | 672 ms | 140 ms | 648 ms | 139 ms | 8,833 / 8,803 |

What the figures say:
- **A miss holds the thread** for about 4 ms per MiB on Linux and 6 ms on the Mac: 4.2 s and 6.0 s
  for 1 GiB. BLAKE3 of the archive is 0.14 s of it on Linux. The rest is inflating, the USTAR entries
  and their copies, and the artifacts' own digests.
- **A hit** reads the whole archive too, for its digest: 0.14 s for 1 GiB on Linux and 0.67 s on the
  Mac, which ran loaded (a load average of 110 to 130).
- **Memory:** one inspection peaks at about 8.2 times the archive, 8.8 GiB for 1 GiB on both machines.
  That includes the process's own copy of the archive, which the Package Manager also holds after a
  retrieval. So the default `archive_bytes` needs about 9 GiB for one inspection.
- 5-5-3's worker removes the hold from the module thread, and 5-5-2b's streaming reader is what
  bounds the memory.

## Storage fetch limits

`lcn.storage_fetch` (DECISIONS G395; `sdk/docs/STORAGE-FETCH.md` §3): a read asks for 1 to 1,048,576
bytes, and a provider refuses any other `length` with `invalid-length` before it looks at the object; a
response holds at most 1 MiB of data, far below the 16 MiB frame body (TRANSPORT l.372). A locator is 1
to 4,096 bytes, as a package source's `object` is (PACKAGE MANAGER l.789-801).

## The streaming reader

Step 5-5-2b (DECISIONS G446, G75's sixth row, G29's note of 2026-11-22). `package/lgx.nim` reads an archive in
one pass of 1 MiB pieces. Over a file (`inspectLgx(fileSource(path), …)`) one inspection keeps the manifest
files, the path table, a digest per selected file and the selected variant's documents (at most 64 MiB), so its
peak does not grow with the archive. Over bytes the caller already holds the archive, and `openLgx` also keeps the
selected artifacts' bytes. Since 5-5-3 the verification cache inspects over the archive's spool file ("The worker
and the spool"). An installed package is inflated twice, once to judge it and once to extract it.

- **Tested:** `test_lgx_peak` runs each inspection in a child process and reads its peak resident size. Over a
  file the peaks at 64 MiB and 256 MiB of incompressible content differ by at most 8 MiB and stay under 96 MiB.
  The control, the reader before 5-5-2b (`tests/support/lgxoracle.nim`) on the 64 MiB archive, passes 96 MiB.
  `test_lgx_equiv` compares every reading with that reader's results (G29's note).
- **The full corpus** [IMPL]: by default `test_lgx_equiv` samples its 180-file archive (each cut that keeps
  `manifest.cose` costs four signature verifications). `LCN_LGX_FULL_CORPUS=1` samples nothing: all three
  archives are cut at every 512-byte boundary of the tar stream and of the compressed stream and at every trailer
  byte, and every entry of each is dropped, doubled, swapped and has each header field broken. It runs once in the
  final CI pass, orc-release on Linux, from the dev shell, since a flake check does not see the caller's
  environment: `LCN_LGX_FULL_CORPUS=1 nim c -r --mm:orc -d:release tests/test_lgx_equiv.nim`. In that build on
  the Mac it compares 9,315 archives in about 20 minutes (1,198 s); by default, about 1,430 in under 2 minutes.
- **Measured** (a scratch program, not committed: 5-3c-1's `pmbench archive` and `pmbench inspect`, with
  `inspectLgx` over the file beside them; one signed archive whose one data artifact is incompressible; CPU time
  of the inspection and the process's peak, each the median of three processes; Mac, `-d:release`). "In memory" is
  the verification cache's inspection, BLAKE3 of the archive and then `openLgx`, the archive read into the
  process first; 5-3c-1 measured the same with the reader before 5-5-2b.

  | Archive | Over a file, orc | Over a file, refc | In memory, orc | In memory, refc | In memory before 5-5-2b, orc (5-3c-1) |
  |---|---|---|---|---|---|
  | 1 MiB (1,065,982 bytes) | 2.7 ms, 10.6 MiB | 3.4 ms, 13.2 MiB | 4.3 ms, 11.6 MiB | 5.0 ms, 14.3 MiB | 6.5 ms, 16 MiB |
  | 64 MiB (67,146,429) | 57 ms, 10.6 MiB | 54 ms, 13.2 MiB | 166 ms, 138 MiB | 187 ms, 267 MiB | 326 ms, 550 MiB |
  | 256 MiB (268,534,430) | 205 ms, 10.6 MiB | 211 ms, 13.2 MiB | 675 ms, 522 MiB | 757 ms, 1,035 MiB | not measured |
  | 1 GiB (1,073,037,548; 1,023 MiB of content) | 793 ms, 10.6 MiB | 844 ms, 13.2 MiB | 2.90 s, 2,056 MiB | 3.04 s, 4,104 MiB | 6.03 s, 8,833 MiB |

  Reading a file costs about 0.8 s of CPU per GiB, all of it inflating and hashing. The in-memory figures also
  hash the whole archive (5-3c-1: about 0.65 s per GiB on the Mac), and 5-3c-1's Mac ran at a load average of 110
  to 130. In memory the peak is about twice the archive under orc and four times under refc: the archive and the
  selected artifact's bytes, where the reader before 5-5-2b took about 8.2 times. `test_lgx_peak` with
  `LCN_LGX_PEAK_GIB=1` gives the same bound under orc in a debug build: 11.3 MiB for an archive of 1,057,314,997
  bytes, the largest the default compressed limit admits for its shape, and 1.82 GiB for the reader before 5-5-2b
  at 256 MiB.

## The worker and the spool

Step 5-5-3 (DECISIONS G446's spool half, G447). Each retrieved archive goes, 1 MiB `read_object` answer at a time,
to the Package Manager's worker thread, which appends it to a spool file with its BLAKE3 and then judges the file
with the streaming reader; the module thread looks the digest up and receives the judgment. So no archive is in
memory and no inspection runs on the module thread.

- **Tested:** `test_pm_driver` "the worker and the spool (G446, G447)" (at most `SpoolLag` pieces unwritten, the
  file's modes, the share's wait, a cancel, a spool write that fails, decoding a turn at a time), with 5-3b's and
  5-3c's suites unchanged on the worker.
- **Measured** (`tools/pmbench.nim spool`: the fetcher's spooled mode, the jobs over a channel, the worker's appends
  and judgment, the module thread's receipt and decoding, both sides on one thread and timed apart; CPU time, the
  archives of "The streaming reader", three processes each, each process's peak; Mac, `-d:release`). The module
  thread's work per piece is the fetcher's copy of the answer and the hand-over. A hit spools and hashes the archive
  again and answers from the cache; a miss also runs the inspection pass.

  | Archive | Module thread per piece (longest), in all: orc | refc | Worker, miss / hit: orc | refc | Peak, orc / refc |
  |---|---|---|---|---|---|
  | 1 MiB | 0.06-0.09 ms (0.18), 0.13-0.19 ms | 0.13 ms (0.30), 0.25-0.32 ms | 3.8-4.2 / 1.1-1.2 ms | 4.7-5.1 / 1.1-1.2 ms | 13.8 / 19.9 MiB |
  | 64 MiB | 0.03 ms (0.16), 2.0-2.4 ms | 0.08 ms (0.24), 5.2 ms | 106-115 / 55-59 ms | 107-112 / 57-58 ms | 13.8 / 24.4 MiB |
  | 1 GiB | 0.03 ms (0.20), 28-34 ms | 0.075 ms (0.24), 76-79 ms | 1.63-1.69 / 0.86-0.95 s | 1.66-1.72 / 0.88-0.93 s | 13.8 / 25.2 MiB |

  Beside the earlier figures for 1 GiB: before 5-5-2b a miss held the module thread 6.03 s and peaked at 8,833 MiB
  (5-3c-1, "The archive's inspection"); 5-5-2b's reader in memory 2.90 s and 2,056 MiB, over a file 0.79 s and
  10.6 MiB. Now the module thread holds at most 0.2 ms at a time, and the worker's miss is the hash (about
  0.9 s a GiB) and the inspection pass (about 0.8 s). A piece crosses as a `string`: as a `seq[byte]`, refc's
  channel copied it one element at a time, 3.4 ms a piece on the module thread.
- **The judgment's receipt** (`tools/pmbench.nim receive`; plan W3; DECISIONS G482 since 5-3c-4). A judgment
  crosses as the resolver holds it, its contracts as encodings in one buffer, and is cached and handed to its
  operation in the turn it arrives: no turn decodes it. The worker builds it from the manifest's values. The
  largest a 4 MiB manifest allows, on framework.lan (x86_64, load about 2), this tree and master `7a307a8` in one
  session, three runs each, CPU time. The module thread's part is the receive and the estimate; under orc the
  receive is a move:

  | Judgment | orc: worker's build / receive and estimate | refc: worker's build / send / receive / estimate | master `7a307a8`: decode turns, longest (orc / refc); refc receive |
  |---|---|---|---|
  | 80,000 dependencies, no contracts | 0.9-1.8 / 0.06-0.11 ms | 13-23 / 4.0-7.1 / 4.4-8.6 / 0.41-0.52 ms | 79, 0.73-0.76 / 7.0-7.9 ms; 13.5-16.1 ms |
  | 1 dependency, 22,000 contracts | 17-19 / under 0.01 ms | 29-30 / 0.82-0.85 / 0.77-0.78 / 0.001 ms | 22, 0.77-1.34 / 8.0-8.7 ms; 3.1-3.2 ms |
  | 20,000 dependencies, 20,000 contracts | 15-27 / 0.02-0.03 ms | 29-42 / 1.6-2.8 / 1.8-3.7 / 0.08 ms | 40, 0.69-0.79 / 8.0-8.9 ms; 7.8-7.9 ms |
  | 80,000 dependencies, 22,000 contracts | 18-19 / 0.09-0.11 ms | 47-51 / 4.7-5.3 / 5.1-5.4 / 0.39-0.41 ms | 100, 0.70-0.80 / 1.1-1.2 ms; 23.9-24.3 ms |

  Under orc, which the packaged logosd is (DAEMON.md §1), the module thread holds a judgment's arrival for at
  most 0.11 ms. Under refc the receive is still one step, a copy, now 5.1 to 5.4 ms for the largest judgment where
  master's took 23.9 to 24.3 ms on the same machine (an entry no longer holds a list of its own), under 5-3c's
  longest turn; the fallback of plan W3 (pieces of 4,096 entries) stays unbuilt (G447). The encode is the
  worker's: 18 to 19 ms of its time under orc for the largest judgment, 47 to 51 ms under refc. Before 5-3c-4
  (D1) the module thread decoded a judgment in up to 100 turns, up to 8.9 ms each under refc here; the Mac's
  figures for that are G447's.
- **The verification cache's bound** (G447): no inspection over 256 KiB by its estimate is cached, so the cache
  holds at most `cache_entries` × 256 KiB, 64 MiB at the default and 1 GiB at the maximum. The estimate's
  constants were measured as the heap's growth over many copies, under orc and refc, and `test_pm_vcache` holds the
  estimate above it for five shapes.
  - **A contract's weight** (`ContractUnitBytes`, G447 amended by G482): 192 bytes beyond its encoding, since an
    inspection holds its contracts as encodings in one buffer (5-3c-4). Measured with `tools/pmbench.nim
    unitbytes` (the Mac, `-d:release`): at worst 186.7 B under orc and 188.7 B under refc, at 22 contracts, where
    the buffer of 4,180 bytes is rounded up to two pages; 4.7 to 8.0 B for 1,000 contracts or more, 34 B for one.
    It was 1,024 for a decoded tree of nine CBOR values (655 B and 848 B). The constant moves which archives the
    cache keeps, never an outcome.

## The operations

Step 5-5-4 (DECISIONS G448, G449, G453's target platform; I121). `inspect`, `install`, `remove` and `update` run in
two slots, one for inspections and one for every installed-state mutation, each with a queue of at most 16 behind it
(`MODULE_ERROR` past that); each running operation has `operation_deadline_ms` from when it takes its slot. The
module thread holds the snapshot of installed records, the holds and the retired list; the worker holds the store's
files after the start (Fable's design A). A commit's new snapshot shares every unchanged record.

- **Tested:** `test_pm_install` (39 cases, through `tests/support/pmworld.nim` with a store and the worker's jobs
  inline): the slots and queues, the deadline and the last commit, the checks before resolution, the spool budget and
  the refetch by digest, the retained check, install, remove, update and inspect, failures at each step, signer
  replacement and C6, the request checks, the admission failure, `nix`, messages and the handoff. After each
  mutation kind and each failure point, the live snapshot equals the one a restart builds from disk.
  `test_pm_hosted` "[IMPL-DECISION G449]" (3 cases) runs them in a hosted instance with the fake provider: across a
  restart; during a paced extraction (the `LCN_TEST_EXTRACT_PACE_MS` hook, "Test hooks"), with a second operation
  and a route renewal answered; and through two stops. `test_logosd_pm` keeps an installed record across logosd's
  restart.
- **A stop** (G449, Fable's stop check `tier5-plans/fable-checks/step5-5-4-stop-drain.md`): the Runtime cancels the
  provider's admitted calls, the kit (with the asynchronous provider API) cancels the handler, the engine cancels the
  operation, the call ends, `_MODULE_destroy` follows, and the worker's stop flag ends its job within one piece.
  Measured on the Mac under orc: 0.49 s with an install's call in flight (10.08 s, the stop deadline, before the kit
  had the API), and 0.37 s after an operation's deadline answered while the worker extracts. Both suites assert
  under 5 s. Both stops run in hosted direct mode (no routing rule: logosd's default for the Package Manager);
  local transport is not covered.
- **Measured** (`tools/pmbench.nim installed`, `module` and `commit`; the Mac, `-d:release`, three runs each):

  | Measure | orc | refc |
  |---|---|---|
  | one module declaration's decode, a 4 MiB module of 22,076 commitments (the module thread's hold between turns) | 21 ms | 38 ms |
  | a snapshot of 200,000 records at the longest identities (the index's bound) | 188 MiB | 259 MiB |
  | `packages()`, the resolver's copy, at 200,000 records | 45-54 ms, 147 MiB | 195-210 ms, 261 MiB |
  | 10,000 records with 4 dependencies each: snapshot / `packages()` | 35 MiB / 6.3-8.5 ms | 42.5 MiB / 38 ms |
  | `next()`, a commit's new snapshot, at 200,000 / 10,000 records | 6-13 ms / 0.1-0.35 ms | 7 ms / 0.1-0.35 ms |
  | the worker's commit at 10,000 records (a 3.27 MB index): CPU, wall | 35-43 ms, 39-49 ms | 42-49 ms, 48-59 ms |
  | the worker's commit at 200,000 records (a 65.4 MB index): CPU | 771 ms | — |

  The module declaration's decode is the longest hold the operations add to the module thread, about twice 5-3c's
  longest resolver turn on the Mac (under 11 ms, "Resolver limits") under orc. The resolver's copy and the
  snapshots are module-thread memory (DEPLOYMENT §12). The commit runs on the worker.
- **The store's start** (`tools/pmbench.nim start`; G445's note; the Mac, `-d:release`, three runs each): records
  written directly, each a data package's manifest, record file and an empty signature file (the start verifies no
  signature), then `openStore` timed. Under orc, 0.83-1.03 ms a record at 1,000 records, 0.84-0.96 ms at 10,000
  (8.4-9.6 s) and 1.01-1.02 ms at 50,000 (50.7-51.0 s); under refc 1.46-1.67 ms at 10,000 (14.6-16.7 s). Per
  record under orc: the manifest's commitment 0.5 ms (of it 0.1 ms the PM §4 schema's root, computed again at
  each call), decoding the manifest 20 µs and the record file 50 µs. The start runs in `_MODULE_init`, inside the
  startup deadline (120 s by default): about 120,000 records under orc and 80,000 under refc fit it on the Mac,
  below the index's 200,000 (DEPLOYMENT §12).
- **Limits** (G449): no job cancel, so an operation that ends by its deadline or its caller's cancel leaves its
  worker job to run to its end, at most one more extraction of the largest archive (a 16 MiB install took
  0.86-0.91 s end to end in a test build on the Mac, so about a minute for 1 GiB); a call cancelled after its last
  commit began ends cancelled while the commit goes on (INTERFACE l.2112); a worker that hangs in a write or a sync
  makes a stop end at the stop deadline.
- **The exception: a large response's way out** (G447; planning's ruling of 2026-11-23; `tools/pmbench.nim
  reply`; the Mac (an M1 Max), `-d:release`, CPU time, best of five, three runs each, at a load average of 60 to
  80; and server.lan, a Ryzen 5 4500U, inside the bench's Nix build, at 2.6 to 3.8).
  The worker encodes a response and the module thread carries the bytes (G447), but on their way out the bytes
  still hold the module thread longer than a turn. A maximal `{installed}` (65,536 artifacts, a 16.0 MiB body,
  the admission bound of PM l.824) holds it 98.6-99.1 ms under orc and 174.9-175.7 ms under refc in one turn
  on the Mac, nine to sixteen times 5-3c's longest turn there (under 11 ms, "Resolver limits"), and
  198.1-203.8 ms and 388.2-398.7 ms on server.lan; a 4 MiB one (one module's declaration of `implements`
  commitments) 24.1-24.4 ms and 43.9-44.7 ms on the Mac, 50.9-51.3 ms and 95.1-95.5 ms on server.lan. Each
  step, timed alone as the code runs it, in ms, the Mac / server.lan:

  | Step | Thread | 16 MiB, orc | 16 MiB, refc | 4 MiB, orc | 4 MiB, refc |
  |---|---|---|---|---|---|
  | the record's value and its encoding (`wjStage`, `wjReply`) | worker | 76.6-77.2 / 185.0-187.2 | 125.7-129.0 / 343.1-344.2 | 19.7-19.8 / 48.1-48.5 | 32.5-33.4 / 87.0-87.6 |
  | the kit's `encode`: pmtest's `{response: bstr}` encoded again | module | 19.3-19.6 / 35.6-36.9 | 24.5-26.2 / 56.3-57.0 | 4.8-4.9 / 9.0-9.3 | 5.1-5.2 / 7.8-7.9 |
  | the completion's block, filled a byte at a time (the SDK's `confinedrt.completeDeferred`) | module | 21.7-21.8 / 37.3-42.3 | 21.7-22.0 / 44.3 | 5.4 / 12.8-12.9 | 5.4-5.5 / 11.0 |
  | the host's `checkResponse`: the schema check and the response's commitment (`completeOp`) | module | 54.2-54.8 / 108.8-109.5 | 68.9-70.6 / 155.0-155.4 | 13.1-13.2 / 25.4-25.6 | 18.8-19.4 / 41.0-41.3 |
  | `respond`'s channel send (refc copies the `IoCommand`) | module | 0 / 0 | 55.0-56.2 / 117.6-127.8 | 0 / 0 | 13.8-13.9 / 31.9-32.0 |
  | the rest: the receive, pmtest's copy, the wipes, the host's copy, the block's release | module | 3.0-3.1 / 15.7-15.8 | 2.9-3.1 / 14.1-14.2 | 0.8 / 3.6 | 0.8 / 3.3 |
  | **the module thread in all** | module | **98.6-99.1 / 198.1-203.8** | **174.9-175.7 / 388.2-398.7** | **24.1-24.4 / 50.9-51.3** | **43.9-44.7 / 95.1-95.5** |
  | the transport's commitment, computed again (`CalleeConn.respond`) | I/O | 52.5-53.5 / 103.2-104.1 | 70.2-73.4 / 163.6-164.3 | 12.8-12.9 / 25.4 | 19.2-19.7 / 43.2-43.5 |
  | the Response's encoding | I/O | 18.8-19.1 / 33.5-35.7 | 19.4 / 28.5-28.6 | 4.6-4.7 / 8.0-8.6 | 4.8 / 7.0-7.1 |
  | the rest: the receive (refc copies), `decodeValue`, the frame | I/O | 0.7-0.8 / 3.2 | 53.4-54.1 / 116.7-125.9 | 0.2 / 0.9 | 13.2-13.6 / 31.5 |

  - **Its scope: confined kit modules, not the Package Manager alone** (RUNTIME §4.1 l.838-840: a response
    that does not validate and commit is not returned; Fable's check
    `tier5-plans/fable-checks/large-response-completion.md`):
    storage_module, blockchain_module, pmtest and 5-6a's facade. With the asynchronous API the kit completes on
    the module thread (`confinedrt.nim:1024-1086`), and the Module Host copies and checks the response inline
    on that thread (`host/endpoint.nim:519-562`, `:443-468`; `runtime/callcheck.nim:81-98`). The Runtime's own
    completion, for a provider in its process, does the same (`runtime/asynccall.nim:562-597`). A confined kit
    without the API pays it on the host's call worker instead (`host/endpoint.nim:480-512`).
  - **The wait** (read from the code, not run). The completing thread also waits with no bound of its own: the
    host's `commit` sleeps while the I/O loop has no room (`host/endpoint.nim:222-238`), which happens once
    64 MiB is submitted and not yet committed (`maxPendingOutputBytes`, `transport/io/loop.nim:379-408`). A
    consumer that stops reading is closed only at the write stall timeout (`writeStallTimeout`, 30 s by
    default). So a few maximal replies to a stalled consumer can hold a confined module's thread for up to 30 s.
  - **The worker's encode** waits in the worker's queue, so another operation's file work waits behind it
    (77 ms under orc for 16 MiB on the Mac, 186 ms on server.lan); it holds no turn.
  - **What 5-6a's facade avoids** by carrying the worker's bytes: the kit's second encoding and pmtest's copy,
    22-28 ms of the 16 MiB figure on the Mac and 45-63 ms on server.lan. The rest stays: about 77 ms under orc
    and 148 ms under refc on the Mac, 153-158 ms and 325-336 ms on server.lan.
  - **The fix is the core item "large-response completion"** (planning's ruling; designed with Fable after the
    pause): the facade passing the bytes through (5-6a's part); completing off the module thread (INTERFACE
    §2.9.2 lets a completion come from any thread); the SDK's completion copy; and the response's commitment,
    computed twice, and its speed; the wait above goes with it. The item is held by the pause. Nothing is
    changed in 5-5-4.

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
sockets that write crafted frames (`tests/transport_io_body.nim`, the suite `test_transport_io`), and
the child-process peer `tests/support/trnpeer.nim`. Nothing under `src/` refers to them, advertises
them or falls back to them. They use only the test tickets of `tests/support/trnowner.nim` and test data. No claim depends on
another implementation recognizing them.

Hooks under `src/` follow one rule (D27, revised 2026-11-13; DECISIONS I89):

1. Their code exists only inside `when defined(lcnTestHooks)`.
2. Only test builds set the define: `tests/config.nims` sets it for every suite, nimble's and the flake's
   alike. No flake package or app, nimble `bin` or `build_*` task sets it.
3. Each module that holds hooks puts a marker constant in the binary under the define
   (`sdk/src/logos_sdk/base/testhooks.nim`). The flake check `no-test-hooks` fails when any deployment
   package or app of the system holds it, and requires it in a probe built with the define.
4. A hook does nothing until the Runtime's host selects it. In an in-process suite, that is a call by the
   test.

The hooks so far (markers `host`, `engine`, `plumbing`, `sidetable`, `loader`, `orchestration`,
`hostsup`, `wipeaudit`, `ctlmodule`, `evstore`, `tls_engine`, `tls_stream`, `tls_keysigner`,
`pm_store`, `pm_jobs` and `pm_admission`):

- `host.setPolicyForTests`: the authority policy the next `start` installs.
- `engine.loaderJournalForTests`: the Module Loader's request journal, kept in the engine's side table.
- `engine.setLoaderFaultsForTests`, `releaseLoaderStallForTests`, `clearLoaderFaultsForTests` and
  `stalledLoaderCallsForTests`: faults injected into the next Module Loader call of a method (an
  invocation that fails before any work, a reply lost or garbled after the work, a reply held), or
  the Loader's report of its own failure (DECISIONS I89 part 4b-1d).
- `engine.confirmTerminationForTests`: stands in for the protected mechanism that confirms a lost
  Loader's realizations are gone (RUNTIME l.3689; G249), which a deployment does by ending the host
  process.
- `orchestration/testhooks.nim` (DECISIONS I94): `setOrchestratorFaultsForTests` and
  `clearOrchestratorFaultsForTests` select faults in the reference orchestration module (the next
  lifecycle answer dropped, as a crash would lose it; every state-file write failing; every event
  dropped; a pause between a read and the guarded request it decided on, `openPauseGateForTests`),
  and `callsForTests`, `callTimesForTests` and `targetsForTests` read its record of the calls it made.
- `hostsup` (DECISIONS I91): `holdEnd` delays the confirmation of a Module Host's end (`holdEnds`
  every host's, those not yet spawned included), `breakCarrier` treats the next frame from a host as
  malformed, `dropNextListener` spawns the next provider's host without its listener, `hostEnds` and
  `pidOf` read what supervision saw, and `traceMarkers` and `traced` count the carrier frames the
  Runtime sends and receives and those holding any of up to eight given byte strings
  (`test_hosted_routes` P-13, `test_wipe_routes` W-7). The engine's `moduleHostForTests` hands a test an instance's host, `realizationForTests`
  reads an instance's `realization` when no client is left to ask, and `hostedEndpointForTests`
  reads the path of an instance's hosted endpoint. The `logos-module-host` program itself has no
  hooks: its suites drive it through its carrier
  (`tests/support/hostowner.nim`) and a probe module.

- Erasure (DECISIONS I92): `engine.setErasureMissingForTests` names route modes that
  `establish_route` treats as path kinds without erasure, so a contract that marks a payload is
  refused on them as G244 did (G277); `engine.setWipeAuditForTests` (with `hostsup.setWipeAudit`)
  has every Module Host spawned afterwards sent the given patterns in its `init`.
- The free scan (`base/wipeaudit`, marker `wipeaudit`) has its own define, `lcnWipeAudit`, which
  only `tests/test_wipe.nims`, `tests/test_wipe_routes.nims` and the audit builds of the Module Host
  and the kits those suites build set. It compiles only with `lcnTestHooks` (a compile error
  otherwise), so an audit build is a test-hook build and the `no-test-hooks` probe covers it. `free`
  and `realloc` in all the C of such a build go through a shim that searches each released block for
  the registered patterns. It is inert until armed, by `armWipeAudit` in a test process or by the
  Runtime's `init` in an audit host, which exits 97 at a graceful end that found a pattern. Only a
  test-hook Runtime writes the `init`'s `wipe_audit`, and only after `setWipeAuditForTests`; nothing
  under `logosd` calls it, so the audit cannot be armed in a deployment. A host built without the
  define treats an `init` that carries the field, even an empty list, as carrier loss
  (`test_module_host` H-15). The carrier trace exempts exactly that field.

- logosctl's closing (DECISIONS I97): `plumbing.holdRcAnswerForTests`, `releaseRcAnswerForTests` and
  `rcAnswerHeldForTests` hold a Runtime Control method's successful call between the Runtime's answer
  and the call's outcome, and `ctlmodule.closingSeenForTests` reports that a command's unanswered call
  has seen the instance closing. Only `test_ctl_module` calls them.
- logosd (DECISIONS I95, G300): `ctlmodule.setCommandDelayForTests` holds each socket command,
  `assemble.failLoaderForTests` has the Module Loader report its own failure, and
  `assemble.diagnoseForTests` (over `engine.diagnoseForTests`; I95 amended 2026-11-16) has the Runtime
  record diagnostics holding text it did not write. A test-hook logosd selects them from daemon-config's
  `test_hooks` (`ctl_command_delay_ms`, `loader_failure_after_ms` or `loader_failure_on_file`,
  `diagnostics`), and only
  with the development switch on; a packaged logosd has no hook code and refuses `test_hooks`. No
  environment variable or socket command selects a hook.
- The call-evidence store (G301): `evstore.pauseForTests` holds its writer, and `waitWrittenForTests`
  waits for it, both called by `test_evidence_store` and `test_host_authority`.
- The tls-tcp carrier (I99): `testsigner.keySigner` holds the TLS key in the process (owner decision
  B1: tests only); `engine.newTlsContextForTests` makes settings no conforming peer has (TLS 1.2
  allowed, or no certificate) to show the refusals; `stream.abortForTests` ends a connection without
  close_notify. All are called by `test_remote_tls`, which is also an audit build (`base/wipeaudit`).
- Signing with the TLS key (G410): `remote.signing = "process-copy"` and `signsvc.testKeyMessage`,
  which send the key to a TLS process, exist only in a build with `-d:logosTestSigning` (owner
  decision B1: tests only); a packaged logosd refuses the setting. `test_remote_signing` and
  `test_remote_tls` are built with it.
- The Package Manager's installed state (5-5; DECISIONS G446, G447, G449): `store.crashAt=` stops
  a commit at a named point, as a crash would, `store.rules` changes a root's path rules, and
  `store.syncMode=` its sync; `jobs.failStage` fails the stage of a named package, and
  `jobs.setCrashAt` sets the crash point on the worker's half of the store;
  `admission.admissionLimitForTests` lowers the admission bound. `test_pm_store` and
  `test_pm_install` call them in the test's process.
- The resolver (5-3c; DECISIONS G455, G482): `resolver.contractHashShiftForTests` shifts every
  contract's hash so that all of them collide; `inspectionBytesForTests` lowers the bound
  `eligibleInspection` asserts on an inspection's encodings; `heldContractsForTests` reads how many
  contract encodings a run's inspection of a source still holds. `test_resolver` calls them in the
  test's process.
- The extraction pace (5-5-4): a test-hook build of `pm/store.nim` reads `LCN_TEST_EXTRACT_PACE_MS`
  once, when the module library is loaded, and pauses the extraction sink that many milliseconds
  for each MiB written. It is the one hook a variable selects, because it lives in the Module Host's
  process, which a test cannot call. The Runtime's host passes the variable only when its
  configuration's `module_host_env` names it, so the Runtime's host still selects it (rule 4). Only
  `test_pm_hosted` does, to stop an instance inside a long extraction. A packaged build of the module
  has no hook code, so the variable does nothing there.

No deployment binary contains them.

## Tagging tests

A test covers a unit by carrying its ID in brackets anywhere in the test file, normally in the test
name:

```nim
test "[CDE-0042] map keys sort by encoded bytes":
```

A test of an interim choice for an open item also carries `[IMPL-DECISION Gn]`.

A unit that cannot be tested (pure prose, a rule about other implementations) is covered by an item
in `<tree>/inspection/<PFX>.toml` that states why:

```toml
[[item]]
ids = ["HSH-0004"]
reason = "Statement about what a profile document must contain; satisfied by HASH itself."
```

A unit's evidence counts only in its owner's trees: a test under `tests/` for core or `sdk/tests/` for the
SDK, or an item in that package's `conformance/inspection/` (R8).

`spectrace gate` (a flake check) fails when a claimed unit has no test or inspection item there, when a
test names an unknown or retired ID, when a claims file has an invalid status, when an inspection item
names a unit that is not claimed (inspection stands for a test, so it covers claimed units only), or,
with `--closed-tier N`, when any status defers to tier N. It prints the deferred units per label.

## Mirrors and pins

`spectrace mirror` checks every file in `spec/mirrors/` against its block in the spec (see
`spec/mirrors.toml`); `--write` refreshes them. `spectrace pins` checks that every value in
`spec/pins.toml` still appears in the section it is pinned from. The tests recompute those values from
the mirrors. `oracle/selftest.py` cross-checks the vectors with an independent implementation.
