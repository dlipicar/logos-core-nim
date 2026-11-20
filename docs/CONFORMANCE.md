# Conformance and traceability

Every normative unit of the twelve specs has a stable ID. A section we claim must have a test for each
of its units. `tools/spectrace/spectrace.py` does the bookkeeping. In the dev shell it is `spectrace`;
`nix run .#spectrace -- <command>` also works. By default it reads the pinned specs from the
`logos-lips` flake input.

## Requirement ledger

Each spec's files sit under the conformance tree of the package that owns them: `conformance/` for core
and `sdk/conformance/` for the SDK (CDE, CMT and HSH). `<tree>/requirements/<PFX>.jsonl` holds one line per unit. The first line records the spec file,
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

`<tree>/claims/<PFX>.toml` gives each section a status. A spec two packages share has a claims file in each,
and `spectrace owners` holds that each unit has one owner. The longest matching section key wins,
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
  C-10, S-18) shows it with the probe kit library in a host, to direct and hosted providers. The
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
  orchestration module (RUNTIME l.72; DECISIONS I94), in direct and local-transport mode, with hosted
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

## Properties not claimed

- A complete Logos module system (BCP §5.1; owner decision 10 (a), K18; DECISIONS G310, I97): there
  is no Package Manager, so no package is installed, selected or trusted, and BCP's units that bind
  the whole are claimed only where `logosd` meets them on its own. `docs/DEPLOYMENT.md` answers each
  missing facility "None" or "Not supported", with the tier that changes it where one is planned.
- Operating-system isolation of hosted modules (SEC l.207-209): a Module Host is a process of the
  daemon's user with the daemon's view of the file system, the network and devices; placements
  `sandbox` and `container` are not offered (`docs/DEPLOYMENT.md` §8; DECISIONS G265 for what a module
  starts, below).

- Protection between processes of the same OS identity (TRANSPORT §8.2 l.1107-1111): Module Hosts
  run as the daemon's user, so a process running as that user can replace a socket pathname or
  impersonate an endpoint. Deployments that need that protection must run hosts under distinct OS
  identities, which this implementation does not set up (DECISIONS G58). The same holds on Windows
  once the profile is built there (step 5-9): a consumer of the Runtime's own user can delete,
  rename or re-secure the endpoint, and TRANSPORT l.1156 is read as not reaching it (DECISIONS G332,
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
    non-claim for that host's own buffers only (LOADER l.573 permits the forced end); the Runtime's
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
no package, manifest, catalog, source or caller can change one. These are the greatest values
supported (`MaxResolverLimits`):

| Limit | Maximum | Counts |
|---|---|---|
| `partial_closure_names` | 4,096 | distinct package names in one partial closure, the root included |
| `dependency_depth` | 4,095 | the greatest number of edges on a path from the root (4,096 names make no longer path) |
| `candidates_per_name` | 4,096 | records charged for one package name: one per name and version (DECISIONS I110, B3) |
| `assignment_attempts` | 1,048,576 | tentative bindings in one root operation, never decreasing |

At these values a chain of 4,096 names resolves in each build mode (`tests/test_resolver.nim`). Each
bind recomputes every depth, so the worst case is about 4.3e9 edge visits: slow, with no time-out to
reach. Exceeding a limit ends the root operation with `dependency-unavailable` and changes nothing.

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
`hostsup`, `wipeaudit`, `ctlmodule`, `evstore`, `tls_engine`, `tls_stream` and `tls_keysigner`):

- `host.setPolicyForTests`: the authority policy the next `start` installs.
- `engine.loaderJournalForTests`: the Module Loader's request journal, kept in the engine's side table.
- `engine.setLoaderFaultsForTests`, `releaseLoaderStallForTests`, `clearLoaderFaultsForTests` and
  `stalledLoaderCallsForTests`: faults injected into the next Module Loader call of a method (an
  invocation that fails before any work, a reply lost or garbled after the work, a reply held), or
  the Loader's report of its own failure (DECISIONS I89 part 4b-1d).
- `engine.confirmTerminationForTests`: stands in for the protected mechanism that confirms a lost
  Loader's realizations are gone (RUNTIME l.3825; G249), which a deployment does by ending the host
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

`spectrace gate` (a flake check) fails when a claimed unit has no test or inspection item, when a
test names an unknown or retired ID, when a claims file has an invalid status, when an inspection item
names a unit that is not claimed (inspection stands for a test, so it covers claimed units only), or,
with `--closed-tier N`, when any status defers to tier N. It prints the deferred units per label.

## Mirrors and pins

`spectrace mirror` checks every file in `spec/mirrors/` against its block in the spec (see
`spec/mirrors.toml`); `--write` refreshes them. `spectrace pins` checks that every value in
`spec/pins.toml` still appears in the section it is pinned from. The tests recompute those values from
the mirrors. `oracle/selftest.py` cross-checks the vectors with an independent implementation.
