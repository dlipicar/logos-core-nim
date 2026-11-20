# Spec status: what is built against which open item

The specs are logos-lips `draft/logos-core-module-specs` at `6a4dfa28` (the `logos-lips` flake input),
since 2026-11-10; before that `f4f83471`. The spec owner revised them after four reports in
`docs/logos-core/discussion/` of logos-lips:
`claude-spec-comments.md` (C-, CM-, IF-, EC-, TR-, RT-, CA-, PM-, SO-), `human-spec-comments.md`
(HC-), `claude-spec-comments-2.md` (NX-, NE-, NI-, NL-, NA-, NR-, ND-, NP-, NC-, NS-, NO-, NF-) and
`module-port-gaps.md`, and answered every item except the HC- items, the Fable 5.1 items (G151,
G153–G156) and NP-11 to NP-14. Work is ordered so the parts least likely to change are built first.
A follow-up report at 6a4dfa28, `claude-spec-comments-3.md` (TF-, TL-, TS-, TP-; logos-lips `68628d95`),
carries the gaps found since (DECISIONS G157–G166) and restates the unanswered ones. G167 was found
after that report (2026-11-11) and is not yet reported.

**Corrected 2026-11-11 (review against 6a4dfa28, items E2, E8, C10):** the paragraph above overstates
two things and is out of date on one. The owner answered two documents, `claude-spec-comments.md` and
`claude-spec-comments-2.md`; `human-spec-comments.md` has no reply, and `module-port-gaps.md` was never
committed to logos-lips. The items with no answer are NE-07, NL-12, NA-12, ND-10 (G151), ND-12 (G153),
NP-11 to NP-15 (NP-15 is G156) and the HC- items. Of the HC- items, the 6a4dfa28 text settles HC-01, 03,
05, 06, 08, 09, 11, 12 and 13 (`claude-spec-comments-3.md` Appendix C), so HC-02, 04, 07 and 10 stay
open. G154 (ND-13) is settled by spec text and G155 (ND-14) is moot. NE-07, NL-12, NA-12 and NP-14 have
no row below; `claude-spec-comments-2.md`, "Remarks on the responses", restates them. G167 is now
reported as TF-12 in `claude-spec-comments-3.md`, logos-lips `457527eb` (branch
`draft/logos-core-module-specs-discussion`).
Line numbers in the rows below are those of the report that raised each item (`f4f83471`); the Status
column is current.

Paths below are where the files are since the SDK moved to `sdk/` (DECISIONS R7). Rows of
`docs/DECISIONS.md` keep the paths they were written with; `tools/restructure/pathmap.toml` maps them.

## Tiers at 6a4dfa28

| Tier | Area | State |
|---|---|---|
| 1 | Deterministic CBOR, BLAKE3, cdCDDLe, HASH, COMMITMENT | Built and adapted. Every risky interim the owner answered matched (G1, G2, G4, G6–G10, G12–G14, G119, G120, G122, G152); G11 moved to RFC 9682; floats and depth follow INTERFACE §4.4–§4.5.1 (I48). The commitment pipeline now counts containers, so it supports the full payload depth (I51). Open: G151, G153, G156 (Fable items, sent as ND-10, ND-12, NP-15) and G157; G154 is settled by spec text and G155 is moot. |
| 2 | INTERFACE acceptance and the C mapping | Rebuilt to C mapping revision 3: explicit bindings (`lcn-gen types --module`), per-document groups and root checks, interfaces importing supporting schemas, floats and depth in the payload decoder. Promoted on 2026-11-10 (ABI v2, part A): §2.4 `_FN_t` typedefs and `_CALL_` provider functions, §2.6 `_MODULE_` symbols (I64, I65). Part B: `abi/` mirrors every §5.2 struct (layout compared with `logos_types.h`) and holds the §2.4, §2.6, §2.9 and §5.2 checks (I66). Part C: the §2.6 provider call-surface descriptor, encoded from a binding and validated as an ABI caller must (I67). IFC gate 383/383. The common section of `logos_types.h` waits on G158. Settled at 6cac8335 (re-pin P2): the §5.2 listing, copied (I26). |
| 3 | TRANSPORT sans-I/O; PM artifacts | TRANSPORT receiver and sender rules done, with §3.4 and the per-connection part of §8.6 now claimed; §8.1.2 system-service sessions are a non-claim (a MAY profile that G48 leaves unused by keeping the Loader and CA direct; step 10a); G165 is open for the Tier 4 publish adapter. LGX done (I49). Package signing is SLH-DSA-SHA2-192s over vendored slhdsa-c (R4, I68), with PM §4.3 claimed. Promoted on 2026-11-11 as sans-I/O: PM §6 catalog entries and inspection records, §11 dependency resolution over installed records, catalog entries and protected limits (I69), with PM §6 and §11 claimed (PKG gate 209/209); G167 (recorded edges of an installed package reused as a dependency) decided (a), reported as TF-12 (`claude-spec-comments-3.md`, logos-lips `457527eb`). Re-pin P7b (2026-11-19, I110): §11 follows 6cac8335 (greatest-path depth, every examined record charged, documented maxima under G361, `contracts`, installed-record eligibility); G167 is settled by PM l.1304-1307. |
| 4 | RUNTIME, RC, LOADER, CONFIG, CA; unix-stream transport with I/O | No spec item blocks it any more (corrected 2026-11-11, review item E7: G165 blocks the Tier 4 publish adapter and G107 the Windows local transport, G168 (reported in TF-10) runs on an interim, and the review's owner decisions on G47, G61, G82, G110, G140, I52 and the Tier 4b rows were taken on 2026-11-11, after the Fable session's review of the recommendations; DECISIONS, "Re-decided 2026-11-11"); INTERFACE ABI v2 is done (Tier 2, parts A–C), and the Nim module kit opens it: part A is built (exported identity, lifecycle and provider symbols, the `_MODULE_dispatch` adapter and publish helpers, tested in process and as shared libraries; I70, I71), and so is part B (the typed `_CALL_` provider functions: C converters, arena response owners, failure rollback; I72), with the INTERFACE §2.3, §2.4 and §2.6–§2.8 provider-side units claimed; and so is part C (`lcn-gen calls`: typed call helpers over a route handle for Nim and C callers, with their §2.7.2 cleanup helpers; I73), with §2.7.2 and the route caller's §5.2 units claimed (IFC gate 449/449). The typed converters and the Nim codecs keep their frames on the heap, so a provider entry at the default payload depth limit fits a macOS or iOS secondary thread (I79, resolving review item A26). The direct-mode Runtime slice has started (owner, 2026-11-11: G52, G53, G55 re-decided): step 1, the internal Module Loader for `direct_static` and `direct_dynamic` (verified copies, symbol and call-surface checks, realize, release, get_status), is built (I74), and so is step 2, the module-instance registry and lifecycle (create, start, stop, report_failure, ordering, startup and stop deadlines, shutdown, the test authorizer; I75), and so is step 3, Runtime Control and direct routes (the per-attempt Runtime Control binding with nine methods, establish, renew and close of local direct routes, `materialize_route` and route handles with response copy, `observe_end`, the invocation context, routes that follow their provider and consumer; I76). Building it found five gaps, G169–G173, reported as TF-16 to TF-20 (`claude-spec-comments-3.md`, logos-lips working tree, not yet committed), each built on its interim. So is step 4, events and asynchronous calls (route subscriptions, direct and invocation-scoped publication, the per-delivery `publish-event` and `subscribe-event` decisions, asynchronous calls through route handles and Runtime Control, deferred provider completion; I78), with the Runtime's INTERFACE §2.5 and §2.9 units claimed (IFC gate 506/506). Its owner decisions are G174, G175 and G177 (2026-11-11), and it found G174's code, G175's activation check, G176 and G178, reported as TF-21 to TF-24 (logos-lips `a9fe9c66`); G178 keeps Runtime Control subscriptions out until it is answered. The step-3 leftovers are built too: ended route records are dropped per consumer once nothing reaches them, and a stop past its deadline records `cleanup-timeout` (I80); what the end of that cleanup does is G180, on its interim. So is step 5, the start path and the Host Embedding API (`liblogos_runtime` and `logos_runtime.h`, the `logos-core-nim.app-config.v1` host configuration documented in `docs/HOST-CONFIG.md`, the bootstrap of the orchestration instance, shutdown, waiting and destruction, and Runtime Control `get_readiness`; I81), with RUNTIME §13 claimed (RUN gate 49/49). Building it found G190–G192 (where bootstrap ends and what `start` returns; the bootstrap-realized instance's intent; host acceptance of a Runtime-generated id), reported as TF-25 to TF-27 (logos-lips `bf9b325f`), each built on an interim the owner accepted. So is step 6a, persistent Runtime state (`durable.nim` and `runtime/store.nim`: one deterministic-CBOR snapshot written before each change is exposed, revisions past every earlier run, a restart that restores instances, intents and origins, reconciles the configuration and resumes orchestration; `runtime.store_dir` and `runtime.runtime_instance_id`; I82), and so is step 6b, Runtime Control `recover_module`, `retire_module` and `create_module`, with `declarations` in the host configuration (I82). Step 6 found G193 (what a preserved instance is after an unclean end), G194 and G195 (the codes for a `retire_module` target on another Runtime and for `create_module` with no declaration), reported as TF-29 and TF-30 (logos-lips `9a8d4c14`), each built on the owner's interim, and built G160's rewritten interim (TF-08), G191's second question (TF-26) and G192's persistence part (TF-27). Transport step 10a is built (I83): part 1, the unix-stream I/O thread, endpoints, the peer check and the Hello over sockets; part 2, calls and events over sockets, event output and its overflow, execution slots held until the provider's work ends with delayed admission (A21), the route's access scope, the end of a session, and the aggregate limits, documented in `docs/CONFORMANCE.md`. TRANSPORT §5.2, §8.2 (not §8.2.1), §8.5, §8.6 and §9 are claimed and §8.1.2 is a non-claim (TRN gate 232/232), with CA §11's CAP-0253, CAP-0255 and CAP-0256 (CAP gate 3/3); the Runtime integration is 4b (10b). Step 8a, the Capability Authority, is built (I84): the `logos-core-nim.authority-policy.v1` policy (`docs/AUTHORITY-POLICY.md`), G47 facts, scopes, `evaluate`, grants, `list_grants`, `query_audit`, notification and its own durable state (8a.1), and the `direct_static` module `logos_capability_authority` with `watch_changes` and the wiring step 8b uses (8a.2), on the interims G205–G207 (TL-04, extended). CA l.392 (no permission profile selected) is recorded, and CAP-0307 to CAP-0321 do not apply (no protected-renewal profile). The engine wiring is 8b. Step 8b-1, its binding and decisions, is built (I85): the Capability Authority binding and its notices, evaluation off the Runtime thread with parked operations, the decision cache (G52's open half), the bootstrap and recovery rules, the execution decision at `start_module` and `recover_module`, route `valid_until`, `expires_at` and expiry, and the `capability-authority` host configuration parsed and checked but refused until 8b-2. It builds G217 (TF-32) and G218 (TL-03) on interims approved with the step plan. So is step 8b-2, authority over time (I85): execution renewal on its own lane, the policy-change retention rule and grant endings, enforcement stops (G168 extended), route re-authorization after a notice (G216, TF-33), events under the authority (G175 re-checked), routed authority calls (G215, TF-31), and the `capability-authority` host configuration accepted, with the library's own authority wired at its state directory (H4 runs it through the host API). G170, G174 and G190 are re-checked on their interims. Step 9a, module configuration, is built (I87): configuration declarations in the host configuration and `declarations`, the per-instance state with its own side record in `store_dir`, the package default and the protected provisioned value (re-staged by value root, G141), Runtime Control `get_configuration_schema`, `get_configuration_summary`, `get_configuration` and `update_configuration` with `configuration_state_changed`, the selection of a value at start, recovery and bootstrap with its handoff to `_MODULE_init`, and `lcn-gen kit --configuration` (typed values, the embedded commitment and the input checks in the kit). It found G233 to G236 (the 16 MiB frame bound on a state, the revision headroom, a summary without a binding, the applied revision of a failed apply), reported as TF-30 points 3 and 4 and TL-09, TL-10, each built on its interim; G21, G141, G162, G171, G190 and G228 are built or extended. So is step 9b, live reconfiguration (I87): `apply_configuration` with CONFIG §8's preconditions in table order, the hook on a lifecycle worker under `apply_deadline_ms` (G61's fourth deadline, 120 s by default) and excluded from release, promotion with the attempted record's value revision (G236), rejection, indeterminate outcomes, stops, shutdown and a reported failure that wait for the hook, and provider calls that keep running meanwhile (IFC-0270 claimed; IFC gate 507/507); G237 (an application deadline that passes while stopping) is built on its interim, an addition to TF-28 not yet sent. The tests reference 111 of the 151 CFG units, with CFG-0010, CFG-0129 and CFG-0134 by inspection; CONFIG §7's declaration updates are not built (a binding is fixed for its instance). No CA section is claimed yet (step 11 claims); the tests now reference 218 CAP and 322 RUN units, 71 and 51 of them new since step 8a (23 and 6 in 8b-2). Prerequisites: the redone rows (G27, G47, G49–G53, G55, G61, G82); R4 is built (I68). G58: no same-identity claim (decided 2026-11-10). Gaps G159–G162 have interims; G163 and G164 are settled by spec text (review 2026-11-11, items B10, B11). **Closed on 2026-11-13** (step 11, I88). Steps 6 (persistence and recovery, I82), 8a (the Capability Authority, I84), 8b (the Runtime side of authority, I85), 7 (observation and Runtime Control events, I86), 9 (configuration, I87), 10a (the unix-stream transport I/O layer, I83) and 11 (deviations and claims, I88) are built. RUNTIME (for the Runtime engine; the host supplies the orchestration module, whose duties `docs/HOST-CONFIG.md` lists), CONFIG, the Capability Authority and TRANSPORT are claimed, with the Runtime's INTERFACE units; LOADER is not: the in-process realizer is a LOADER-shaped implementation-local mechanism, not a Module Loader instance (S11-1 option (b); G230; TF-36), so LOADER is `deferred:tier-4b` as a whole and its tests keep their tags as evidence (until Tier 4b step 4b-1, below). `spectrace gate --closed-tier 1 --closed-tier 2 --closed-tier 3 --closed-tier 4` (the flake's `spec-gate`): RUN 756/756, CFG 122/122, CAP 365/365, TRN 232/232, IFC 610/610, PKG 210/210, BCP 3/3, SEC 1/1; deferred to Tier 4b: RUN 82, LDR 136, CAP 19, TRN 10, IFC 15, PKG 12, BCP 46, SEC 1; to Tier 5: RUN 124, CAP 1, TRN 58, IFC 171, PKG 298, BCP 4, SEC 1. What is not claimed carries its reason in `conformance/claims/` (`docs/CONFORMANCE.md`, "What is claimed at the end of Tier 4"): RUNTIME §5.2.1 singleton mode is a MAY not taken (l.1094); TRANSPORT §8.1.2 is a MAY profile left unused under G48(a) (l.1075), with RUN-0318. Step 11 fixed I78's nested-call deadlock by overflow workers on both pools (G242), C-08 and IF-02 (G241), refuses routes to contracts that mark a payload (G244), and keeps four deviations (I88); closing the claims found and fixed three holes: an authority record without a contract had no provider record, `execution_release` did not close admission, and `logos.schema` answered from a consumer's construction input (I88). Open items carried forward: TF-36 (G230), G178, TL-08, TF-03. |
| 4b | logosctl, logosd, module host | After the Tier 4 engine. D13 (persistent logosctl module, owner-only socket) and D27 (protected-configuration switch, testnet = production) were re-decided on 2026-11-10; on 2026-11-11 D27 was completed (non-production identification, locally generated dev keys, the switch in the trust file), and G82 (`logosctl authz check` dropped), G92 and G143 (upgrade by explicit transfer of the state assignment) were re-decided; on 2026-11-15 G92 was re-decided again (batch F, item 21): no assignment moves, the replacement gets a fresh one filled by `copy` or `move`. Deferred here from the Runtime slice step 6 (I82): the RUNTIME §10.1 units that bind the orchestration module (RUN-0684, RUN-0685, RUN-0686, RUN-0687's orchestration half, RUN-1063, RUN-1065, RUN-0696) and RUN-0025, as requirements on the orchestration module; Takes over from Tier 4 at its close (`deferred:tier-4b`, I88): the realizer as a `logos_module_loader` instance (S11-1 option (a), the first item; TF-36), **built in step 4b-1 (I89, 2026-11-13)**: the Runtime binds the Loader and realizes every other instance through it, LOADER is claimed for the direct strategies (G248), and RUNTIME's Loader-conditional rules are claimed with it, Loader loss (RUN-1067 to RUN-1072; G246, G249, G252) and the shutdown order (RUN-1075, RUN-1076) included; the owner's batch A (2026-11-13) answered S4b1-1 to S4b1-4 (G249 to G252) and amended D27 (the test-hook rule) and G110 (the enforcer is Runtime admission); the gate after 4b-1: RUN 763/763, LDR 117/117 (19 deferred), BCP 3/3 (BCP-0021 to BCP-0024 tagged, still deferred). The default orchestration module, **built in step 4b-5 (I94, 2026-11-13; parts 4b-5a and 4b-5b; part 4b-5c, the permission settings hint, 2026-11-14)**: `lcn_orchestrator`, a consumer-only kit module a host registers and names in `orchestration` (G53 resolved by decision 8: its name confers nothing), acting only through its Runtime Control binding; guarded startup defaults, reconciliation with hints and periodic resync, the restart policy with its retry accounting in its state directory, resumption against retry (G289, which amends G193 as the owner answered S4b5-1 in batch B 9), lifecycle ordering seen by orchestration (G287), probes for what permissions or authority hold back (G288, owner batch B 10), the binding inferred from `list_modules` (G290) and an enforcement stop past its deadline as a resumption (G291), no shutdown sequencing (G292); `docs/HOST-CONFIG.md` "The reference orchestration module". RUN-0021, RUN-0025, RUN-0684 to RUN-0687, RUN-1063 and RUN-1065 are claimed; RUN-0696 is claimed with part 4b-5c; G290 and G291 were decided by the owner (2026-11-13), and whether to ask for a Runtime start marker (an addition to TF-29) is the owner's call; the gate after 4b-5b, merged with 4b-2a: RUN 780/780 (56 deferred to Tier 4b). Then the rest of LOADER (the hosted strategy, §5.3, §5.4) with the Module Host (4b-3), **part 4b-3.1a built (I91, 2026-11-14)**: `logos-module-host` (G264), its supervision (G265) and the carrier (G266), the Loader's hosted driver advertising `hosted_dynamic {process}` only when `runtime.module_host` is set, and hosted consumer-only modules started and stopped, their Runtime Control calls, events and asynchronous calls answered through their attempt's own binding (G267, G271) and their execution requests naming `local-transport` in a `process` (G272); **part 4b-3.1b built (I91, 2026-11-14)**: a host's own end and a broken carrier (`host-terminated`, G268), deadlines that end a host (G269), a live application whose host ends (G270), the Module Loader's loss with live hosts, and the restart lock after an unclean end (G275, amending G193; G180 amended for hosts); LDR-0034, LDR-0040, RUN-0169 to RUN-0172, RUN-0180, RUN-0227, RUN-0284 and RUN-0812 to RUN-0814 are claimed (gate: RUN 804/804 with 158 deferred, LDR 119/119 with 17), and **part 4b-3.2 built (I91, 2026-11-14; the owner's direct layout)**: the hosted provider endpoint (§5.3, §5.4), made and validated by the Runtime and served by the host, with payloads going between the consumer's process and the host directly while the Runtime admits every Hello, call, subscription and delivery from what the host reports without payloads (G267; the same payload checks in the host, RUN-0815), the host committing each Response (G273, the K38 interim) and reporting the commitments a call record retains (G274, the K44 interim), and routes to it `local-transport` (G272); `test_hosted_routes` P-1 to P-14; **part 4b-3.3 built (I91, 2026-11-14)**: hosted consumers' route handles, in the host, which keeps each route's invocation material and connects to the provider itself while the Runtime admits each materialization and operation (G267, with plan R11's acknowledgement replaced by the Runtime's first cause); `test_hosted_routes` C-1 to C-8 and S-18; **part 4b-3.4 built (I91, 2026-11-14)**: the boundary-invariance suite (one case table, four placements, every answer, delivery and completion the direct run's) and the claims of 4b-3.2 to 4b-3.4: RUNTIME §4.2.1 and §6.2, LOADER §5.3, TRN-0184 to TRN-0186, inspection items RUN-0173, RUN-0179 and LDR-0125, LOADER §5.4 (K3) and LDR-0163, LDR-0164 (K7) `out-of-scope` (gate, merged with 4b-5c: RUN 826/826 with 136 deferred, 10 of them to Tier 4b; LDR 131/131, none deferred; TRN 242/242); CAP-0065 and CAP-0066 stay with 4b-4; the Module Host and hosted placements (RUNTIME §4.2.1, §6.2; CA hosted placements); step 10b, now step 4b-2 (transported routes and tickets, the decision, expiry and revocation the route ticket carries: CAP-0254, TRN-0153, TRN-0185, TRN-0317; G165, NA-04), **part 4b-2a built (I90, 2026-11-13)**: routing rules (G254), the transport I/O thread in the engine, tickets at establish and renew with replays that omit them (G255, the NA-04 interim), the Runtime-served endpoint of a direct provider (G257) with Hello, calls, Cancel and introspection, and the end of a route on the provider side (G260, G174 amended); RUN-0220, RUN-0226, RUN-0229, RUN-0230, RUN-0501, RUN-1161, RUN-0543, RUN-0544, RUN-1179, TRN-0153, TRN-0195, TRN-0317, CAP-0254 and LDR-0021 are claimed, and RUN-0045, RUN-0552 and IFC-0010 move to Tier 5; **part 4b-2b built (I90, 2026-11-13)**: the consumer's transported handle on the Runtime thread (one connection and one ticket per handle, G164, G258; the handle's two codes and TRANSPORT_ERROR for a lost connection, G256; a peer mismatch fails the route, G259; the consumer side of a route's end, G260; Cancel for asynchronous calls), with RUN-0007, RUN-0008, RUN-0014, RUN-0800 to RUN-0806, TRN-0187, TRN-0191, TRN-0278, IFC-0729 and INTERFACE's execution-boundary invariance claimed, and parity suites that rerun the route and asynchronous-call suites over sockets; **part 4b-2c built (I90, 2026-11-13)**: events over local transport (a subscription activated by the provider's Runtime before `subscribe` returns, delivery on the event workers in commitment order, the publish adapter with G165 (a) and D3 (a) (G261), scoped publication over a session with its exact codes), with RUN-0192, RUN-0234, RUN-0246, RUN-0832 and TRN-0290 claimed and the event suites rerun over sockets; the default orchestration module (RUNTIME l.194, l.3774-3806; built in 4b-5, above); package-backed selection, the Package Manager handoff and the pin table (RT-04, G55), moved to Tier 5 (owner decision 1 (a), 2026-11-13; I97); upgrade transfer (G92, G143), **part 4b-7a built (I96, 2026-11-16)**: `state_transfers` in `app-config.v1` and `daemon-config.v1`, applied once at `start`: the replacement gets a fresh assignment (G305) filled by `move`, a rename of the source's directory (G307), on the protected entry's authority (G306); the source is retired in the write that creates the replacement, and refused while anything of a realization is left, while a hosted source's restart lock is missing or held, or while another instance's retained intent names it; a committed rename is completed at the next start, and a replacement whose directory is missing is never started on an empty one; RUN-0925 and RUN-0998 are claimed and RUN-1000 moves to Tier 5 (package acceptance); **part 4b-7b built (I96, 2026-11-16)**: `copy`, measured first (directories and regular files only, `max_bytes`, entries, depth, free space), staged and flushed before the commit, the source's directory left as the rollback, the bytes read in the Runtime's process through one zeroed buffer (the owner's F1), not on Windows; **part 4b-7c built (I96, 2026-11-16)**: `logosctl state list` and `state purge` (G143 re-decided), offline, a purge only of a retired instance's preserved directory and never while a transfer from it is owed; permission enforcement (G110, with RUN-0914, RUN-1066 and RUN-0923), **part 4b-4a built (I93, 2026-11-14)**: the permission registry and the shipped profile `logos-core-nim.permission-profile.v1` with `logos-core-nim.host-ambient` (G279, G280, G283, G286; `docs/PERMISSIONS.md`), and the Capability Authority's side: `unknown-permission`, then `invalid-constraints`, permission scopes only beside a start, and one rule or one grant for a whole request (G205 and G207 amended, owner batch D 17); CA §3.5 is claimed (CAP 382/382; CAP-0065 and CAP-0066 wait for 4b-4c, CAP-0192 for 4b-4b); **part 4b-4b built (I93, 2026-11-14)**: the Runtime's half in direct mode: the profile selected and new instances provisioned in `app-config.v1` `permissions` (G110), each instance's settings saved and restored (`prm`), replaced and reconciled by stop and re-realize with intent and origin kept (G281, G285), refused before any decision when `failed` or lacking host-ambient (G284; owner batch D 15), the execution decision's permission scopes (G217 amended), the installed snapshot (G282), the stop when a grant is revoked and `permission_settings_changed_event`; RUN-0914, RUN-1066, RUN-0923 and CAP-0192 are claimed, G229's constant form stays for no profile, PKG-0335 moves to Tier 5; the gate after 4b-4b: RUN 797/797, CAP 383/383 (CAP-0065 and CAP-0066 wait for 4b-4c); **part 4b-4c built (I93, 2026-11-14)**: hosted instances: the execution decision before the Loader realizes a Module Host's process, covering `local-transport` in a `process` and the permission scopes (CAP-0065, CAP-0066 claimed; G272), settlement once a host's forced end is confirmed and `failed` where nothing ends it (G285 amended), settings held `pending` while a host of the previous run may still run (G275 amended), and `get_execution_permissions` from a host; the gate after 4b-4c: CAP 385/385, none deferred; marked-payload erasure (INTERFACE §1.4.1; SEC-0057 until re-pin P6b retired it), **built in step 4b-3b (I92, 2026-11-15)**: the Runtime, its served endpoints, the Module Host and generated code zero their copies of a marked payload (byte buffers always, trees, commitment intermediates and hashers when marked, generated code for marked declarations only; G276), no marked value or value root reaches a diagnostic, a record or the carrier and a marked request's INVALID_PARAMS path stops before the first key taken from the payload (G278, S4b3b-2 (b)), a decision that retains a marked side is refused before dispatch on every path (IFC-0581), and G244's refusal is lifted for the participants the Runtime controls, hosted ends included, in orc and arc builds, while a refc Runtime or host refuses every marked contract (G277, the owner's reading S4b3b-1, batch C 14, with the build condition after the Fable check; the orc-only claim scope accepted by the owner 2026-11-15, R5); IFC-0575 to IFC-0577, IFC-0580 and IFC-0581 are claimed for orc builds (SEC-0057 too, until re-pin P6b), with the non-claims in `docs/CONFORMANCE.md` (a host ended by force, K43; refc builds of the Runtime or the host, which refuse instead; refs in generated values under refc; the kit's per-thread failure text; stack values); the gate after 4b-3b: IFC 624/624 (none deferred to Tier 4b), SEC 2/2; logosd and logosctl (D13, D27), **built in step 4b-6 (I95, 2026-11-15; parts 4b-6a to 4b-6c)**: `daemon-config.v1` (G293), logosd's composition and its system rules (G294, G295), the trust file, its mark and the development switch (G299, G300), the persistent `logosctl` instance and its owner-only socket (G296, D13 (a)), request keys (G297), the shell (G303), logosd's process with Loader-loss supervision (G302), the in-process Host API additions (G304), the call-evidence store and its export (G301; G115, G143 and G149 built for logosd), no remote surface (G298, K19), packaging and service units (G146); the eight void rows (G76, G78, G79, G80, G83, G84, G85, G87) redone; BCP-0084, BCP-0086 to BCP-0090 and BCP-0093 to BCP-0096 are claimed, BCP-0036, BCP-0049, BCP-0050 and BCP-0092 tagged and left to 4b-8; and complete-system composition (BCP), **closed in step 4b-8 (I97, 2026-11-16; parts 4b-8a to 4b-8c) without a complete-system claim** (owner decision 10 (a): no Package Manager, K18): a unit that is met is claimed whether or not the whole is (I97's rule; BCP-0021 to BCP-0024 by logosd's tests, G310), the §5.2, §5.3 and §5.5 profile rules by tags and inspection items (G311, G312), and BCP §5.4 by `docs/DEPLOYMENT.md`, logosd's deployment document, every gated unit answered under G309 and kept in step with the code by `spectrace deploydoc` (flake check `spec-deploydoc`) and `tests/test_deployment.nim`; PKG-0422 is claimed with a true "no" (G137 amended, owner 2026-11-16), RUN-0844 by inspection, PKG-0288 by tags. **Closed on 2026-11-16** (step 4b-8, I97). Steps 4b-1 to 4b-8 (I89 to I97) are built. `spectrace gate --closed-tier 1 --closed-tier 2 --closed-tier 3 --closed-tier 4 --closed-tier 4b` (the flake's `spec-gate`): RUN 829/829, LDR 131/131, CFG 122/122, CAP 385/385, TRN 242/242, IFC 624/624, PKG 212/212, BCP 49/49, SEC 2/2; nothing deferred to Tier 4b; to Tier 5: RUN 133, TRN 58, IFC 172, PKG 308, BCP 4, SEC 1 (`docs/CONFORMANCE.md`, "What is claimed at the end of Tier 4b"). |
| 5 | The Package Manager (trust in use, sources and catalog, the Storage role, installation, the service, package-backed selection; SLSA provenance and the Nix profile, droppable); remote Runtimes and their transport (`tls-tcp`; QUIC, droppable); the reverse mapper; the Windows local transport, by its spike | Open since Tier 4b closed (I97). Planned in the workspace's `TIER5-PLAN.md` (approved 2026-11-16; the owner's decisions in `tier5-plans/owner-decisions.md`); this row and the section **The Tier 5 plan** below were rewritten to that plan by step 5-0 (I103, 2026-11-17): the areas and their units, the steps, the open items with their interims, and each step's progress. Outside Tier 5: sandbox and container placements and operating-system enforcement of permissions (D16), the Credential Store (no spec at `6a4dfa28`), mobile (M12). |

## The Tier 5 plan

From the Tier 5 plan (`TIER5-PLAN.md` in the workspace) as of 2026-11-17 (step 5-0, DECISIONS I103). No
Tier 5 merge comes before step 4b-8's closing checks and step 5-0 (plan A9). Each step adds its line to
the log at the end of this section, re-opens the inspection items its work makes untrue, and updates
`docs/DEPLOYMENT.md` where it changes an answer, in its own merge.

### Areas and units

The 676 units `deferred:tier-5` at `3c6f3c3`. Areas A1 and A3 are counted by work (PM l.1649-1702's
inspect, install, remove and update units and the §14 result encoders are installation's), the others by
section; *Steps* says whose work makes each unit claimable. The PKG units are listed by step after the
table (each unit with its reason: the workspace's `tier5-plans/step5-0-pkg-recount.tsv`).

| Area | What | Units | Steps |
|---|---|---|---|
| A4 | Signing-trust continuity in use (PM §4.1-§4.3) | PKG 30 | 5-3a 4, 5-3b 16, 5-5 7, 5-8 2, 5-7a 1 (PKG-0435, the TLS key) |
| A2 | Sources, the catalog document and the Storage role (PM §2, §4, §4.4, §6, §13) | PKG 13 | 5-3b 10, 5-6a 2, 5-8 1 |
| A3 | Installation and installed state (PM §1, §5, §7-§8, §10, §14; §15's inspect, install, remove and update) | PKG 63; BCP-0033, BCP-0035 | 5-5 |
| A1 | The `logos_package_manager` service: contract, queries, watch, progress (PM Abstract, §15-§15.2) | PKG 77 | 5-6a 28, 5-6b 49 |
| B | Package-backed selection and the handoff's use (PM §4, §9, §11, §12; RUNTIME §9.3) | PKG 19; RUN 7 (RUN-0995 to RUN-0997, RUN-1000, RUN-1023 to RUN-1025) | 5-8 |
| C | SLSA provenance (PM §4.5 and its §14 codes), droppable | PKG 75 | 5-11 |
| D | Nix realization profile (PM §2, §7.3, §8), droppable | PKG 31; BCP-0034 | 5-10 |
| E1 | `logos.remote.tls-tcp` (TRANSPORT §8.4, §8.4.1) | TRN 36 | 5-2 |
| E2 | `logos.remote.quic` (TRANSPORT §8.4.2), droppable | TRN 5; BCP-0032; RUN-0503 (counted in F) | 5-12 |
| F | Remote Runtimes (RUNTIME §9, §9.3; INTERFACE §5.2) | RUN 126; IFC 20 | 5-7a, 5-7b |
| G | Windows local transport (TRANSPORT §8.2.1) | TRN 17 | 5-4 (the spike: go on three builds, no chronos fork, G329-G333; TRN-0352's test), 5-9 |
| H | The reverse mapper (INTERFACE §3) | IFC 152, and IFC-0887, IFC-0904 to re-evidence; **claimed by 5-1 (I98)** | 5-1 |
| K | iOS baseline (SEC-0044); sandbox and container placements and OS-enforced permissions have no gated unit | SEC 1 | outside Tier 5: M12 |
| | **Total** | **676**: PKG 308, RUN 133, IFC 172, TRN 58, BCP 4, SEC 1 | |

The 308 PKG units by step (`PKG-` omitted):

| Step | Area | Units | Ids |
|---|---|---|---|
| 5-3a | A4 | 4 | 0418-0421 |
| 5-3b | A2 | 10 | 0019, 0021, 0069, 0114, 0115, 0353, 0449, 0472-0474 |
| 5-3b | A4 | 16 | 0076, 0077, 0079, 0081-0083, 0085-0093, 0112 |
| 5-5 | A3 | 63 | 0011, 0012, 0172, 0177, 0178, 0181, 0182, 0189, 0190, 0192, 0204, 0219, 0222, 0271, 0274, 0291-0293, 0356, 0357, 0359-0363, 0389-0411, 0468-0471, 0487-0489, 0493, 0498-0500, 0534-0537 |
| 5-5 | A4 | 7 | 0080, 0436-0441 |
| 5-6a | A1 | 28 | 0003-0008, 0366-0380, 0388, 0519-0524 |
| 5-6a | A2 | 2 | 0513, 0514 |
| 5-6b | A1 | 49 | 0381, 0383-0387, 0525-0533, 0538-0542, 0544-0562, 0564-0573 |
| 5-7a | A4 | 1 | 0435 |
| 5-8 | B | 19 | 0060, 0287, 0289, 0335, 0337-0345, 0347-0351, 0512 (and TXT-0545, riding on 0351: G391) |
| 5-8 | A2 | 1 | 0354 |
| 5-8 | A4 | 2 | 0423, 0424 |
| 5-10 | D | 31 | 0017, 0224-0252, 0273 |
| 5-11 | C | 75 | 0118-0170, 0450-0467, 0515-0518 |

**Re-pin P7a (2026-11-19, I110):** PKG-0275 is stale (G156 settled), PKG-0365 (`_module`) now heads PM §4.3
and is claimed with it. PKG-0273, which names only the realized output at 6cac8335, is deferred to 5-10, and
PKG-0274, whose LGX half is the extraction check, to 5-5 (G362). App A's 38 rules are new units, copies of rules
the sections state: ten are claimed and 28 are deferred by name with their twins, five to 5-5, two to 5-8 and 21 to 5-6a
(G363). PKG-0568 is now deferred by name to 5-6b (G362). The count by step above is still that of 6a4dfa28.

A dropped area's units that bind without it stay and are claimed in their own steps: TRN-0352, PKG-0190,
PKG-0166, PKG-0167, PKG-0169, the `nix` and `quic` refusals (plan A1). At the close (5-13) every unit
still deferred is relabelled by decision E2, with the status keys that name Tier 5, so that
`--closed-tier 5` passes.

### Open items and their interims

The plan's §6, with the owner's decisions so far. *Open* names the decision that will settle it.

| Step | Item | Interim | State |
|---|---|---|---|
| 5-1 | TL-01 (G158) | recognize the common type names we generate; G158 is the limit of IFC-0003, IFC-0004 and the §3.8 units | decided (A10); settled by spec text at 6cac8335 (re-pin P2): the §5.2 listing states the names, and the limit is gone |
| 5-2 | TS-04 | follow the text: one connection per route, one per consumer for control, a session reused only by the same route (TRANSPORT l.1289; RUNTIME l.1801) | decided (B9) |
| 5-2 | G86, real Runtimes' TLS credentials | a P-256 key and a self-signed certificate as a direct anchor (G86 as re-decided; 5-2's G324) | decided (B2) |
| 5-2, 5-7a | marked payloads on remote paths (G277; 5-2's G327) | `tls-tcp` and `quic` carry no marked payload (TRANSPORT l.1188-1189; RUNTIME l.1808, l.2939): re-pin P4d built the refusal (`runtime/remotemarked`), which 5-7a calls, and took 5-2d's opt-in `BORINGSSL_ZERO_RECORD_BUFFERS` off again; the carrier erases its own copies (G276) | decided 2026-11-17 (owner); settled by spec text at 6cac8335 (re-pin P4d) |
| 5-3a | the package trust file and the remote trust input; provenance continuity | — | open (C2, C3) |
| 5-3a | the `lcn.storage_fetch` contract has no readiness signal (G91, G136) | 5-3a adds one | planned |
| 5-3b | NP-12 | no platform tag in the catalog document | open (C7) |
| 5-3b | TF-07 (G166) | the plan's §6 wording; the answer to PM l.402 stays *no* | open (C5); recovery by re-install is PM l.1675 at 6cac8335 (PKG-0608, 5-5) |
| 5-3b | no §4.2 freshness profile is defined | claim the baseline; a configuration that asks for a profile is refused | open (C9) |
| 5-5 | PM-11 (G93) | `local_path` per artifact; one self-contained module library | open (C8) |
| 5-5 | NP-15 (G156), PKG-0275 | keep G156; PKG-0275 by reading | settled by PM l.1096-1101 at 6cac8335 (re-pin P7a): PKG-0275 is stale |
| 5-5 | TF-12, TF-14 | keep I69's interims; exclude an installed candidate whose signer is no longer accepted | TF-12 settled by PM l.1304-1307 at 6cac8335 (G167); the signer exclusion built at re-pin P7b (I110) |
| 5-5 | the no-op install and update while the retained signer is not accepted (TF-07's second point); a D9 stop | fail with `signature-verification-failed` | decided (C6: fail); built at re-pin P7b, the update half in the resolver and the install half at resolution (G166) |
| 5-6a | where the Package Manager runs | hosted in its own process, the engine's binding over TRANSPORT §8.1.2 | open (C1) |
| 5-6b | package record observation | deny by default; the grant is protected deployment input | open (C4) |
| 5-7a | NF-06 (G81), the authority part | G81 (a) narrowed | decided (B5); compared with CA l.77-78 at 6cac8335 (re-pin P6a): the enrolled half of TXT-0359 (claimed for the half with no Runtime enrolled) and TXT-0360 (riding RUN-1125) are 5-7a's |
| 5-7a | NA-04 (G255); TF-30 point 1 (G194) | kept | decided (B9) |
| 5-7a | enrollment and trust-anchor changes (G87) | offline, under the session lock, at the next start | decided (B3) |
| 5-7a | G298 | its answers stay for a profile the build lacks; *no record is kept* is re-decided with listener records | decided (B8) |
| 5-7a, 5-7b | the remote process layout; facades | Runtime-owned TLS processes, a signing seam (logosd signs by default); a facade is a provider record, never served by logosd | decided (B1, B4) |
| 5-7b | NL-07 (G355) | the `route_failure` spellings and the state table | decided (B6) |
| 5-7b | NR-04 (G356) | resolve or fail | decided (B7) |
| 5-8 | TF-44 (G351); a D9 stop | the plan's §6 wording | open (D2) |
| 5-8 | how a package-backed instance comes to exist | configured entries with pins written offline (recommended) | open (D1) |
| 5-8 | TF-04, TS-06, TP-07 | `requires` stays advisory; a pin is protected input; `create_module` carries none | open (D3) |
| 5-8 | TF-30 point 2 (G195) | G195's answer; a Package Manager not ready is a transient failure | open (D7); G195's answer settled by spec text at 6cac8335 (re-pin P4a): `declaration-unavailable` |
| 5-4, 5-9 | the Windows readings: logosd's own user; the build key | one user is not a security boundary (G58's non-claim); keyed on the OS and `afunix.sys` builds (5-4's G332, G333) | decided 2026-11-17 (owner) |
| 5-11 | NP-13 | provenance attests the assembled archive | open (E3) |
| 5-13 | TF-43 (G310); the units still deferred | the member set of E1; E2's relabels | open (E1, E2, E3) |
| N-2 | marked methods through the CLI | refused, naming the method (INTERFACE l.388-389); local-only support later (N-2d), non-local targets refused | decided 2026-11-17 (owner) |

Unanswered upstream and bearing on Tier 5: NP-12 to NP-14 (NP-11 is settled by text: PM l.964, l.1180, and
NP-15 by PM l.1096-1101 at 6cac8335),
NE-07, NL-12, NA-12, HC-02, HC-04, HC-07, HC-10; in `claude-spec-comments-3.md` TF-04, TF-07, TF-12,
TF-14, TF-30 (points 1 and 2; 3 and 4 are settled by CFG l.198 and RUNTIME l.1812, re-pin P6b), TF-43, TF-44, TF-45, TF-52, TS-04 to TS-06, TP-07, TL-01, TL-02, and the TF-06 remarks of
G352 and G354 (DECISIONS, "Open items").

### Inspection items that hold only while a feature is absent

- CAP-0075 to CAP-0082 (one permission, `logos-core-nim.host-ambient`; G283) and CAP-0292 to CAP-0297
  (not applicable; G286): re-checked only if a finer permission profile, OS enforcement or a sandbox or
  container placement is built, which is area K, outside Tier 5. LOADER has no such item: an
  unadvertised placement is absent (LOADER l.255).
- RUN-0488 (facades come with remote transport) and the claimed RUN units whose evidence shows only that
  there is no remote: step 5-7 re-opens them.
- `docs/DEPLOYMENT.md`'s `None` and `Not supported` rows that name Tier 5 change with the step that builds
  their facility (`spectrace deploydoc` fails until the row, its inspection reason and the facts agree).

### Log

- 2026-11-17, step 5-0 (I103): this section; records only, no unit changes status.
- 2026-11-17, step 5-2 (I99), E1, the `logos.remote.tls-tcp` carrier's library, parts 5-2b, 5-2a and 5-2d:
  TLS 1.3 only with mutual authentication through a `PeerCheck`, the channel binding, the signing seam
  (G323), the parameters (G326), P-256 credentials and streams over chronos (5-2b); the trust snapshot
  and the enrollment checks under B2's direct anchors (G324) with accepted time (G325) (5-2a);
  nim-boringssl 0.0.16 with `BORINGSSL_ZERO_RECORD_BUFFERS` on and the carrier's own copies erased (G327;
  5-2d); pyOpenSSL as the independent peer in the suite's Nix checks (G128; 5-2c). 17 TRN units claimed: TRN-0216, TRN-0219 to TRN-0221, TRN-0223 to TRN-0226, TRN-0228,
  TRN-0233, TRN-0370 to TRN-0376. E1's other 19 units are 5-7a's, but for TRN-0222, which is 5-7b's (the
  facade process passes the invocation's Runtime as the one expected); remote paths refuse marked
  contracts until 5-7a shows the TLS processes' erasure (G277). The re-pin's P4d removed the option again:
  `tls-tcp` and `quic` never carry a marked payload (G327).
- 2026-11-18, step 5-1 (I98), H, the reverse mapper, parts 5-1a to 5-1c: `lcn-gen cddl` reconstructs the
  schema documents and module binding of an explicit C header set (G317 to G322). 152 IFC units claimed,
  IFC-0887 and IFC-0904 re-evidenced in both directions; the gate is IFC 776/776 with 20 units left to 5-7a
  and 5-7b. G158's interim stays the limit of IFC-0003, IFC-0004 and the §3.8 units.
- 2026-11-19, re-pin P2 (I105), the INTERFACE ABI at 6cac8335: C mapping revision `4u`, ABI version 3 with
  `observe_subscription_end` on both vtables (registration only until P3), `logos_publish_fn` returning
  `logos_error_code_t` (interim result, I105), `logos_types.h` as the copied §5.2 listing (G158 settled: the
  limit of IFC-0003, IFC-0004 and the §3.8 units is gone) and the reverse mapper's subject as input (G318).
  IFC-0959 and IFC-0971 to IFC-0975 and IFC-0981 claimed; IFC-0170, IFC-0884 and IFC-0935 retired.
- 2026-11-19, re-pin P3a (I106), events and subscription ends at 6cac8335: one event-name check on
  every binding operation and carrier name; the publish result of IF l.3351 (I105's interim completed);
  SubscriptionEnd and coded termination on the session; the Runtime's ends of route and Runtime
  Control subscriptions, reported through `observe_subscription_end` (G225 settled by spec text);
  direct delivery behind a busy handler queued with a copy, a nested publication behind it run in
  place, the bound ending the subscription at once (G176 settled by spec text). 29 units claimed:
  IFC-0960 to IFC-0967, IFC-0970, RUN-1094, RUN-1095, RUN-1098, RUN-1099, RUN-1159, TRN-0388,
  TRN-0389, TRN-0391 to TRN-0395, and the changed IFC-0280, IFC-0712, TRN-0016, TRN-0040, TRN-0045,
  TRN-0125, TRN-0163, TRN-0274; stale IFC-0186 and TRN-0200 re-evidenced; 48 text entries cleared,
  TXT-0168 and TXT-0169 moved to P5. P3b's 23 entries remain.
- 2026-11-19, re-pin P3b (I107), the remote profiles at 6cac8335: a Runtime Control listener address
  whose `profile` or `alpn` contradicts its transport is INVALID_PARAMS without detail after what is
  authorized without the payload (M8); `connect_remote` refuses an endpoint with no Runtime identity, a
  non-remote address, this Runtime or a mismatching profile before NOT_AUTHORISED; the `tls-tcp` carrier
  checks `profile` and sends and selects no ALPN. RUN-1152 to RUN-1155, TRN-0396, TRN-0399, TRN-0400,
  IFC-0939 and IFC-0940 claimed (RUN-1154, RUN-1155 and TRN-0400 by inspection); TRN-0397 deferred to
  5-7a, TRN-0401 to TRN-0403 to step 5-12; 12 text entries cleared. P3 holds no pending entry.
- 2026-11-19, re-pin P4d (I108), marked payloads on the remote profiles at 6cac8335: a route on `tls-tcp`
  or `quic` whose permitted scope includes a marked method is INVALID_PARAMS (`runtime/remotemarked`, which
  5-7a calls; G277); nim-boringssl's `BORINGSSL_ZERO_RECORD_BUFFERS` is off again and the carrier's
  conditional refusal gone (G327); the free scan leaves BoringSSL's C++ out (G276). TXT-0157 and TXT-0129
  cleared; RUN-1163 and TRN-0398 stay deferred to 5-7a.
- 2026-11-19, re-pin P4a (I108), Runtime Control's typed errors at 6cac8335: a stale revision at the
  seven guarded methods is a successful response holding the error arm, `stale-revision` with the
  current revision, and changes nothing; `create_module` with no declaration is `declaration-unavailable`
  to a caller authorized to create the module and NOT_AUTHORISED to any other (G195 replaced);
  `configuration-rejected` is the type and the arm only (produced from re-pin P6b on). logosctl exits 4 with the code,
  and orchestration counts the error arm as a refusal. `rc_types` regenerated, the enrollment rules
  mirrored from §9.3.7, App B decoded. RUN-1113, RUN-1114, RUN-1127 to RUN-1138, RUN-1146 to RUN-1150,
  RUN-1185, RUN-1187, RUN-1203 to RUN-1206 and RUN-1208 claimed, with CFG-0152, CFG-0154 and CFG-0155
  (moved from P6); RUN-1124, RUN-1125 and TXT-0163 deferred to 5-7a; 17 text entries cleared and 15
  stale ids replaced.
- 2026-11-19, re-pin P4b (I108), the order of checks at 6cac8335:
  - What is authorized without the payload comes before payload validation, for Runtime Control
    and for ordinary calls.
  - Readiness comes after each handler's expected revision and precondition rows, in row order,
    and before every success.
  - A transported Request whose params fail their schema goes to its owner, which checks it after
    admission. An ordinary transported call that is both malformed and denied answers
    INVALID_PARAMS, not NOT_AUTHORISED (G171's interim reading, Fable synthesis §8).
  - `stop_module` answers on acceptance (`stopping`).
  - The provider status set is checked at the five ABI call sites, and a Capability Authority
    status outside it is a failed evaluation.

  G171, G172, G173, G194 and G228 are settled by spec text. Claimed: RUN-1115 to RUN-1123,
  RUN-1141, RUN-1162, RUN-1188, IFC-0979 and IFC-0980. Stale ids: RUN-0347 and RUN-0548 replaced;
  RUN-0268 moved to P8, and RUN-0630, RUN-0639, RUN-0675, RUN-0912 and RUN-1053 to P5, where their
  successors are claimed. 9 text entries cleared.
- 2026-11-19, re-pin P4c (I108), route selection, a narrowed allow and the route states at 6cac8335:
  - A `single` request without an exact provider decides every candidate in one batch, ready ones
    first, and selects the first allowed one; a denial or a failed evaluation hides a candidate (M7,
    G169 settled).
  - An allow narrower than a route's bound scope revokes it with `authority-denied`, at renewal and
    at re-authorization (M9, G170 and G216 settled); [IMPL] a narrowed execution renewal ends the
    execution as `authority-denied` too.
  - A route at its authority's validity end is `revoked` with `authority-expired` (G218 settled).
  - A `connect_remote` binding passes continuations through to the module (G356 settled by l.3030-3031
    and owner row 37); continuations and facades are 5-7b's.

  Claimed: CAP-0429, CAP-0432 to CAP-0434, RUN-1107, RUN-1161, RUN-1164, RUN-1168 to RUN-1171,
  RUN-1173 and RUN-1179 to RUN-1181, with RUN-1106 and RUN-1165 by inspection; CAP-0305, IFC-0581,
  RUN-0289, RUN-0326 and RUN-0360 compared. RUN-1167 and RUN-1174 to RUN-1176 deferred to 5-7b, with
  TXT-0182 to TXT-0188 riding on RUN-1167. Thirteen stale ids replaced or recorded. 56 text entries
  cleared and TXT-0269 moved to P5. P4 holds no pending entry.
- 2026-11-19, re-pin P5a (I109), the lifecycle at 6cac8335:
  - A stop past its deadline, or past the shutdown deadline, stays `stopping` with `cleanup-timeout`
    until its cleanup ends, which completes it `unloaded` (or `error` if the cleanup fails); a Module
    Host is ended then. G180 is settled by RUNTIME l.575-577, its interim reversed.
  - An indeterminate configuration application during a stop leaves the instance `stopping` (G237
    settled by CONFIGURATION l.327-329).
  - A stop of an `error` instance goes through `stopping` (M10), and every state change fits the
    lifecycle table (RUN-1091; G358, checked under `lcnTestHooks` in every suite).
  - Shutdown expiry releases what ordering held back and reports what is still `stopping` (M11).
  - An unclean end restores `error` with `host-terminated` (G193 replaced); the store, format v2,
    marks a completed shutdown's last record (G357, the TF-58 interim). An older build refuses a v2
    store.

  Claimed: RUN-1087 to RUN-1093, RUN-1096, RUN-1097, RUN-1110, RUN-1142, RUN-1194 to RUN-1197 and
  RUN-1200, with RUN-1089, RUN-1096 and RUN-1097 also by inspection; RUN-0070, RUN-0100, RUN-0121,
  RUN-0227 and RUN-0707 compared. Stale ids RUN-0061, RUN-0109, RUN-0111 and RUN-0912 replaced. 39
  text entries cleared, and TXT-0275 and TXT-0323 moved to P8.
- 2026-11-19, re-pin P5b (I109), classifications and recovery at 6cac8335:
  - Three classifications join `FailureKind` in l.3605's order: `configuration-missing`,
    `static-binding-mismatch` and `prerequisite-unavailable`. An older build refuses a store that
    holds one.
  - An `unloaded` instance with `requested` intent reports what keeps it from starting (M13, l.3613):
    missing configuration at refusal (G162 settled), an unready prerequisite at refusal and after each
    committed step (G359, the UF-42 interim), the denial and enforcement causes as before (G168
    settled). A refusal for configuration or a mismatch replaces an `error` instance's cause, and both
    join orchestration's resumable set (G291 amended).
  - A retained static instance whose facts or binding no longer match is not refused at `start`: it
    keeps its record, is never realized that run, and reports `static-binding-mismatch` (M14,
    l.1319-1322; G160 changed, G243 changed). A dynamic one keeps G160's startup refusal.
  - Every failure change commits and is reported by `execution_state_changed_event` (G227 settled);
    G268 to G270 and G275 are settled by l.3606 and l.3634-3637, behaviour unchanged.

  Claimed: RUN-1102, RUN-1103, RUN-1183, RUN-1184, RUN-1191, RUN-1192 and RUN-1193, with RUN-1102
  also by inspection; RUN-0696 compared. RUN-1190 deferred to 5-7b with G355, with TXT-0205 and
  TXT-0206 riding on it. Stale ids RUN-0630, RUN-0639, RUN-0675 and RUN-1053 replaced. 13 text
  entries cleared.
- 2026-11-19, re-pin P5c (I109), Loader loss, shutdown and startup at 6cac8335:
  - The Module Loader has failed only when its instance leaves `ready` (M16, l.3686-3687). An invalid
    answer no longer fails it: the operation goes the way a failed invocation of it goes (G252
    narrowed). An authority ending of a Loader that owns realizations is its failure (reading D1). A
    Module Host that ended before its Loader failed now resolves when the Loader fails. G360 records the
    TF-57 interim in Fable's wording, the reproductions, the lost-answer dead end and the UF-47 interim.
  - During shutdown the authority keeps renewing executions and is released after them (M12, l.3731;
    I85 amended).
  - `start` answers from this run only (l.3838, l.3938-3940, l.3955; G190 replaced): TIMEOUT for an
    expired startup deadline, the orchestration's or the Loader's (G61), and its own code at once for
    a refusal that records no failure. G191 and G192 are settled by l.1557-1559 and l.2587-2588.

  Claimed: RUN-1108, RUN-1109, RUN-1198, RUN-1199, RUN-1201 and RUN-1202. 17 text entries cleared,
  App A's by typed readings.
- 2026-11-19, re-pin P5d (I109), route ends at 6cac8335:
  - An admitted call that its route's end ends is TRANSPORT_ERROR (l.1271; G174 replaced), and a call
    a revocation or expiry finds not yet admitted is NOT_AUTHORISED (l.1261). This reverses the batch
    B 7 amendment the owner saw: a transported or hosted provider's in-flight Request is no longer
    answered NOT_AUTHORISED; its session ends and the caller fails it TRANSPORT_ERROR at the close
    (P5 Q3 (a); TRANSPORT l.979). G260's revoked row follows.
  - A provider realization's end and a local refusal after the Runtime admitted the call are
    TRANSPORT_ERROR too; a CANCELLED that a route's end caused completes TRANSPORT_ERROR (reading d4).
  - M17 conforms on reading: only the caller's own deadline on an invocation is TIMEOUT
    (INTERFACE l.2025); a `route-timeout` end is a loss of readiness, NOT_READY (l.1263).

  Claimed: RUN-1100 and RUN-1101. 3 text entries cleared. P5 closed.
- 2026-11-19, re-pin P7a (I110), the manifest, signing and LGX at 6cac8335:
  - The manifest gains `extends`, a dependency's `contracts` and `contract_documents` (UF-15, UF-38 and
    UF-39 as written), checked for order, uniqueness and non-emptiness. The roots are recomputed from the
    mirror (`d517cf20…`, `23de138c…`).
  - A claim that names another manifest schema is `unsupported-manifest`, judged after the signature and
    the profile and before the manifest decodes (M26; G29 revised).
  - A wrong artifact kind and a path-rule violation are `invalid-package`. Every variant's paths and
    files are checked, and a file missing from any variant is `artifact-integrity-failed` (M23 to M25;
    I37, G40, G41).
  - G156 is settled. PKG-0273 is deferred to 5-10 and PKG-0274 to 5-5, and TXT-0463 and TXT-0472 ride PKG-0418
    (5-3a) and PKG-0293 (5-5); TXT-0497 and TXT-0498 ride PKG-0568 (5-6b) (G362).
  - App A: the §10, §12 and appendix blocks are mirrored and pinned, and one test compares the appendix's 38 rules
    with the section excerpts in spec order. A copy takes its twin's status (G363).

  Claimed: PKG-0576, PKG-0581 to PKG-0588 and PKG-0591; PKG-0365 moved to §4.3; App A's PKG-0613 to PKG-0617,
  PKG-0621 to PKG-0623, PKG-0625 and PKG-0629, with 28 copies deferred. 36 text entries cleared and 4 deferred.
- 2026-11-19, re-pin P7b (I110), the resolver at 6cac8335:
  - Depth is the greatest path from the root, recomputed after each bind; every examined record is charged, an
    ineligible one and each root record too; the limits have documented maxima (G361; `docs/CONFORMANCE.md`,
    "Resolver limits"), and a chain of 4,096 names resolves at them.
  - A dependency's `contracts` must all be provided. An installed record is ineligible for an unsupported schema
    or a signer no longer accepted, and a `retained` hook fails the operation on absent or altered bytes.
  - Pins apply per record (Q8); an update walks the newer releases and reports `unchanged` when none applies,
    under the owner's interims on TF-59 and TF-60 (B3, Q6, Q7; owner row 40).
  - G167 is settled; G166 is partly settled, with TXT-0493 to TXT-0495 riding PKG-0608 to 5-5.

  Claimed: PKG-0592, PKG-0593 and PKG-0597 to PKG-0607 (PKG-0597, PKG-0604 and PKG-0605 by inspection;
  PKG-0594 to PKG-0596 out of scope); PKG-0317 is stale. 19 text entries cleared and 3 deferred. P7 closed.
- 2026-11-19, re-pin P6a (I111), the Capability Authority at 6cac8335:
  - The denial codes follow CA §7's table: the first that applies, with "covers" by kind and action (G377). A deny
    rule states `consumer-denied` (the default) or `target-denied`, and `consumer-denied` wins across rules; the
    lapsed-grant codes keep G207's one holder while TL-04 is open; `issue_grant` answers `not-granted` or
    `scope-denied` under UF-53.
  - No `evaluate` decision before its record is acknowledged: at its append under the backlog bound, with no audit
    write failing (G376). Retention drops only written segments.
  - A module evaluates for itself under a rule or grant naming `evaluate`, which the authority checks itself (G378),
    and its scopes name only its own instance and providers (G379, the interim on TF-61).
  - A repeated revoke records nothing (G206 settled, reversed); `scopes` is limited to 4,194,304 encoded bytes;
    App A is mirrored and tied to the body; a `query_audit` result is cut to what fits (G51, UF-54). G217 and G226
    are settled by the text, G205 in part.
  - `spectrace` lets a deferred text entry ride another spec's unit when its sentence names that spec's section:
    TXT-0360 rides RUN-1125 to 5-7a. TXT-0359 is claimed for the half with no Runtime enrolled.

  Claimed: CAP-0430, CAP-0431, CAP-0435 to CAP-0444 (CAP-0436 and CAP-0439 by inspection) and App A's CAP-0446 to
  CAP-0495; CAP-0393 and CAP-0422 re-read. 44 text entries cleared and 1 deferred.
- 2026-11-19, re-pin P6b (I111), Configuration, the Loader, BCP and SECURITY at 6cac8335:
  - A valid rejection of a live configuration is the `configuration-rejected` error arm (CFG l.323); a Runtime
    Control state over the frame is INVALID_PARAMS without detail (CFG l.198, G233 settled for that path); a held
    realization's absent or non-live binding comes before NOT_READY, and an instance with no realization stays
    NOT_READY (G171 restated). G234, G235 and G236 are settled by the text, behaviour unchanged.
  - LOADER's Appendix A is mirrored and tied to the body (LDR-0167 to LDR-0191). BCP-0104: a scan finds every
    `logos.` identifier the code names mirrored or listed with its line, and no provenance profile.
  - BCP-0098, SEC-0021 and SEC-0057 are retired, so `conformance/claims/SEC.toml` claims no unit. P6 is closed.

  Claimed: CFG-0151, CFG-0153, CFG-0156, LDR-0167 to LDR-0191 and BCP-0104. 54 text entries cleared; BCP-0098,
  CFG-0046, CFG-0145, SEC-0021 and SEC-0057 retired.
- 2026-11-20, re-pin P8a (I112), contract extension in the SDK and the Package Manager at 6cac8335:
  - COMMITMENT §9.1's relation is decided on two constructed models (`extendsContract`); a model no document built is
    refused, and `_module` is compared as written (TF-55; G392).
  - A binding keeps the earlier contracts it extends, and the descriptor carries them in `extends`: each accepted as its own
    set, related to the described contract of its namespace, out of the binding's set rules, identity checked across the
    three arrays (I67 revised; G392 r2-r7). `matchesContracts` takes the extended set. An earlier root answers `logos.schema`
    with its own documents.
  - The Package Manager builds every contract document from the selected variant and compares its root, judges reserved
    names per document, and checks each `extends` entry against the declaration's contracts under G392's rule (I37).
  - After P8a no record can state `extends`, so no route selects an earlier root; P8b adds the Runtime.

  Claimed: CMT-0242, IFC-0958 (its SDK half until P8b), IFC-0968, IFC-0969, PKG-0577 to PKG-0580, PKG-0589 and PKG-0590;
  IFC-0226, IFC-0230 and IFC-0245 compared. 14 text entries cleared. IFC-0246 stays pending until P8b.
- 2026-11-20, re-pin P8b (I112 part b), contract extension in the Runtime at 6cac8335:
  - A record may state `extends` (host configuration, store, static records); each set it states must equal the validated
    descriptor's, and an `extends` entry that does not hold fails the bind (G394 r10, r11).
  - A route may select an earlier contract the provider extends and resolves only that contract's methods and events
    (r12); its schema answer is built when the route is made and held by it, with the 8 MiB check (r14). The Runtime's
    endpoint and a Module Host's serve the earlier roots through one function (Q4), and each session builds its boundary
    from the selected root's own input, so payloads stay between the caller and the provider.
  - `describe_provider` asks a discover decision per extended view (r15); `list_modules` reports `extends` (r13).
  - PKG-0338, PKG-0347 and PKG-0351, the handoff's `extends`, are deferred by name to 5-8, and TXT-0545 rides PKG-0351
    there (G391); `spectrace` derives a section-less new-side entry's section from its lines (Q1).
  - Held on TF-62: the rule for a record that omits a field (IFC-0246's engine half) and RUN-0258's record, so P8 stays
    open.

  Claimed: IFC-0957, RUN-1104 and RUN-1105, and IFC-0958's route half; RUN-0265 and RUN-0267 compared; RUN-0268 stale
  (RUN-1105). 11 text entries cleared, TXT-0545 deferred.

## Tiers at f4f83471 (the original plan)

| Tier | Area | Verdict |
|---|---|---|
| 1 — build now | Deterministic CBOR (INTERFACE §4.1–4.4, cdCDDLe §9), BLAKE3, cdCDDLe, HASH layout and payloads, COMMITMENT schema model and identity | Safe. No item changes det-CBOR rules or cdCDDLe bytes of existing constructs, and no normative vector is reported wrong. The risky rules (CM-01/G1, CM-02/G2, CM-04/G7, CM-05/G8, CM-07, G9) each live in one named proc with an `[IMPL-DECISION]` test. |
| 2 — build now, types only | INTERFACE §1 schema conventions, §4.5/§5.3 validation, §4.6 outcomes, §5.1 common schema, call surface; C type mapping §2.1–2.3, §2.5, §2.7, §3.9 forward cases | Safe for schema handling. Generated C is stamped provisional; no `_dispatch`/`_destroy`/export set. |
| 3 — build now, sans-I/O | TRANSPORT §1, §2, §4.1, §6, §7, §8.1, §8.3; PM §4 manifest, §4.1 trust input, §4.3 COSE_Sign1/Ed25519, §7.1 LGX | Codecs and state machines are safe when generated from the mirrored CDDL. No sockets, fetch or catalog. |
| 4 — after the revision | RUNTIME engine, RC, stop/shutdown; LOADER; CONFIG; CA | Registry, persistence, workers and direct routes are stable; the stop sequence, authorization point and handle-to-session model are likely redesigned. |
| 5 — blocked | PM fetch/catalog/storage role; logosctl/logosd; payload modules; module host; reverse mapper; QUIC/Nix/SLSA; mobile/Windows | Wait for the revision. |

Three spec facts drive the order:

1. Pinned values ripple. Every imported reference commits to the whole common-schema root
   (COMMITMENT l.657, l.705), and the hash-profile and commitment-model ids are literals inside
   `logos.schema_commitment` (INTERFACE l.2401-2406). Any common-type addition, error-code value or
   profile bump changes the common root, the nine subtree roots in COMMITMENT §5, both PM manifest roots
   and every contract root that imports a common type. So every pinned value lives in
   `spec/pins.toml` and is recomputed from `spec/mirrors/`, never typed into code.
2. The init struct and both vtables are append-only (INTERFACE l.2769, l.2780-2784), so many fixes are
   additive. `_dispatch`, typed method functions, `_destroy` and `logos_publish_fn` are not versioned,
   and several reports target exactly those.
3. Transport envelope maps are closed (TRANSPORT l.124-126, l.1167): any field addition breaks old
   peers, so the envelope codec is generated from the mirrored CDDL.

## When a spec revision lands

1. Bump the `logos-lips` input: change the `rev=` in `flake.nix` (line 12 pins it), then run
   `nix flake update logos-lips`; the update alone does not move a pinned `rev` (corrected 2026-11-11,
   review item E8).
2. `spectrace sync --specs <raw dir>` lists added, changed and retired requirement IDs per section.
3. `spectrace mirror` and `spectrace pins` fail where CDDL or pinned values changed; review the diff,
   run `spectrace mirror --write`, re-copy the pins, and let the recompute tests confirm.
4. Walk the rows below (settled / changed / still open) and update `docs/DECISIONS.md`.
5. Re-tier what is left and report before continuing.

## Columns

- **Milestones** are those of the original full plan (M0 foundations … M13 live acceptance). The tier is
  the earliest tier any of them falls in (M1 → 1, M2 → 2, M5/M7 → 3, M3/M4 → 4, later → 5); an item
  can also matter to later tiers.
- **Risk** rates what changes if the owner settles the item differently from our interim choice:
  HIGH = bytes, roots, the C ABI or a core rule; `-n` = small blast radius; `-c` = only if another fix
  lands. "=s" in the note means our interim choice already equals the suggested fix.
- **Code / test** points at the isolated rule once it exists.
- **Status**: `open`, `settled by spec text (…)`, `resolved in <rev>`, or `changed in <rev>`.

## Counts

| Tier | Items | HIGH |
|---|---|---|
| 0 | 4 | 0 |
| 1 | 34 | 15 |
| 2 | 41 | 12 |
| 3 | 62 | 6 |
| 4 | 58 | 1 |
| 5 | 18 | 2 |
| all | 217 | 36 |

## Tier 0 — foundations

| ID | Report | Spec §§ | Milestones | Risk | Likely fix, interim choice | Code / test | Status |
|---|---|---|---|---|---|---|---|
| C-12 | claude-spec-comments | BCP §1 vs §5.3; RUNTIME §9 | M0,M3,M4 | MED | If audit/evidence types move namespace, their roots and evidence bytes change. | — | resolved in 6a4dfa28: upward dependencies listed (BCP §1.1); audit and evidence keep their namespace |
| GN-01 | claude-spec-comments | all | M0 (all) | LOW | Editorial. | — | resolved in 6a4dfa28: every spec declares BCP 14 language |
| NX-05 | claude-spec-comments-2 | RUNTIME References; BCP §1 | M0, M3 | LOW | Additive: Y. Add normative references. The "move shared records into RUNTIME" option would rename them, changing their C names and roots. | — | resolved in 6a4dfa28: references repaired; no records moved |
| SO-10 | claude-spec-comments | mirrors; cdCDDLe §12 | M0,M1 | LOW | Published vectors would expose any CM-xx divergence. | — | resolved in 6a4dfa28 (no change); the owner points to mirrors and a corpus that logos-lips does not hold; remarked in `claude-spec-comments.md`, "Remarks on the response" (logos-lips `68628d95`) |

## Tier 1 — encoding, hashing, commitments

| ID | Report | Spec §§ | Milestones | Risk | Likely fix, interim choice | Code / test | Status |
|---|---|---|---|---|---|---|---|
| NC-05 | claude-spec-comments-2 | HASH §5, §6.1 l.506-509; cdCDDLe §5.1; CA §4, §9, §13 | M1, M2, M4 | HIGH | Additive: P [REV]. `sensitive` marker with salted commitments and zeroization (touches the HASH algorithm and the model). The per-method no-retain option would be LOW. | `commitment/schema.nim` `methodBodyOf`, `commitment/construct.nim` `sensitiveNames`; suite `commitment: sensitivity`; retention of a marked payload refused before dispatch, `engine.admit` (I85), tests `[IFC-0581]` in `tests/test_wipe_routes.nim` (W-9, on direct, transported and hosted routes; I92) | resolved in 6a4dfa28: `_sensitive` declarations, no hash change (CMT-0227..0233); built in `commitment/construct.nim` |
| ND-01 | claude-spec-comments-2 | INTERFACE §1.7, §5.1; BCP §5.3 | M1, M2, M8 | HIGH | Additive: Y [CR]. `logos.uint256` or `logos.decimal_uint` common type. A native scalar kind would be [REV]. | — | resolved in 6a4dfa28 (declined) |
| ND-04 | claude-spec-comments-2 | cdCDDLe §5.1, §9; COMMITMENT l.1295-1296 | M1, M2 | HIGH | Additive: Y [REV?]. Bounded arrays `[n*m T]`. The cdCDDLe occurrence node already carries min/max (cdCDDLe l.496-500). | `runtime/routes.nim` `checkAccessOrder`; `authority/scopes.nim` `checkScopeSet`; tests `[RUN-0547] [RUN-0548]`, `[CAP-0022]`..`[CAP-0025]` | resolved in 6a4dfa28 (declined); remarked in `claude-spec-comments-2.md`, "Remarks on the responses" (logos-lips `68628d95`; review item E5); Tier 4 interims, built: `route_access` lists (RUNTIME l.3024-3025) INVALID_PARAMS without detail, never sorted (I76); CA set arrays (CA l.130-131, l.138) `invalid-request`, never sorted (I84); permission names (RUNTIME l.2537): no definition exists, so any named permission is INVALID_PARAMS (G229, I86) |
| ND-05 | claude-spec-comments-2 | cdCDDLe l.171; COMMITMENT; HASH §5 | M1, M2, M10 | HIGH | Additive: Y [REV]. Typed `{*K=&gt;V}` maps: new model kind and a keyed HASH layout. The association-list option only adds a validator rule. | — | resolved in 6a4dfa28 (declined) |
| ND-06 | claude-spec-comments-2 | INTERFACE l.425, §5.1; HASH §4 | M1, M2 | HIGH | Additive: Y [CR]/[REV]. `bstr .cbor T` and/or `logos.json_text`. | — | resolved in 6a4dfa28: embedded encodings are contract semantics |
| ND-08 | claude-spec-comments-2 | INTERFACE l.97, l.111-112; COMMITMENT l.352-353 | M1, M2, M8, M10 | HIGH | Additive: Y [REV?]. New import forms between contracts; existing schemas are unchanged. COMMITMENT l.745 names "add import forms" as a revision trigger. | `iface/accept.nim` `supportingOf`, `iface/surface.nim`; tests `[IFC-0021] [IFC-0025] [IFC-0560]`, `[IFC-0930] [IFC-0931]` | changed in 6a4dfa28: interfaces may import leaf supporting schemas (I18 reversed): done |
| NR-08 | claude-spec-comments-2 | TRANSPORT §2, §5, §7, §8.4.2; INTERFACE §5.1 l.2479-2484 | M1, M2, M5, M11 | HIGH | Additive: N [CR]. New value in the closed error-code set; overload rejection without closing the connection; limits; second QUIC stream. | `transport/limits.nim` `TransportLimits`; suite `trn.limits` | resolved in 6a4dfa28 (declined): existing aggregate bounds; no new error code; per-connection limits documented (I52) |
| C-01 | claude-spec-comments | COMMITMENT §5 l.697 vs INTERFACE §1.1/§5.3, BCP §6.1 | M1,M2 | LOW | Only changes what the parser accepts; roots unaffected. =s | — | resolved in 6a4dfa28 (COMMITMENT §5); =s |
| C-02 | claude-spec-comments | COMMITMENT §3.1 vs INTERFACE §2, §3.8 | M1,M2,M10 | LOW | Affects only names we already reject. =s | — | resolved in 6a4dfa28: one segment below the namespace (COMMITMENT §3.1); =s |
| CM-01 | claude-spec-comments | COMMITMENT §8, §9.2; HASH §7.3 | M1 | **HIGH** | Value roots through alias chains. poc2 does the opposite (outermost). cl l.183-188 | `commitment/normalize.nim` `throughLocal`; tests `[CMT-0224…0226]` (App B.1), `[IMPL-DECISION G1]` | resolved in 6a4dfa28 (COMMITMENT §8, App B.1 vector passes); =s |
| CM-02 | claude-spec-comments | COMMITMENT §8, §9.3; HASH §5, §7.4 | M1 (values in M3/M5) | **HIGH** | Field 1 under reference-value nodes, for every value with common or Runtime Control types. poc2 does the opposite. cl l.190-197 | `hash/layout.nim` `rootBelowReference`, `hash/view.nim` `verifyView`; tests `hash: App B.4 imported reference context` | resolved in 6a4dfa28 (HASH §7.4 l.707-712, checked by §8 l.1239-1242; App B.4 vectors pass; citation corrected 2026-11-11, review item D3); =s |
| CM-03 | claude-spec-comments | INTERFACE §1.1/§1.7; COMMITMENT §5 | M1,M2 | LOW | Acceptance only. =s | — | resolved in 6a4dfa28 (COMMITMENT §5); =s |
| CM-04 | claude-spec-comments | COMMITMENT §9.4; HASH §8 | M1,M4 | **HIGH-n** | What a view discloses; changes view and evidence bytes, not roots. cl l.205-209 | `hash/view.nim` `viewOf` / `verifyView` (field and tuple-position segments); test `[IMPL-DECISION G7]` | resolved in 6a4dfa28 (HASH §8); =s |
| CM-05 | claude-spec-comments | COMMITMENT §9.4 | M1,M4 | **HIGH-n** | Bytes of semantic paths in views and evidence. cl l.211-214 | `hash/view.nim` `verifyView` (choice step); test `[IMPL-DECISION G8]` | resolved in 6a4dfa28 (COMMITMENT §9.4); =s |
| CM-06 | claude-spec-comments | COMMITMENT §3.1 l.490-503 | M1 | MED | Changes which schemas are accepted, not the roots of accepted ones. | — | resolved in 6a4dfa28 (COMMITMENT §3.1, with examples) |
| CM-07 | claude-spec-comments | HASH §4 l.162-165 | M1 | **HIGH-n** | Packing of literal-element lists, and so their value roots. cl l.223-227 | `commitment/normalize.nim` `packKindOf` (G119); test `[IMPL-DECISION G119] [IMPL-DECISION CM-07]` | resolved in 6a4dfa28 (HASH §4); =s |
| CM-08 | claude-spec-comments | HASH §8, §9 | M1 | LOW | An input of the verifier API. | `hash/view.nim` `ViewSchema`, `verifyView(schema)` (G120); test `[IMPL-DECISION G120]` | resolved in 6a4dfa28 (HASH §8); =s |
| CM-09 | claude-spec-comments | COMMITMENT §6; HASH §7.2 | M1 | MED | "Remove it" drops a domain tag → new profile id → every pinned root changes. | — | resolved in 6a4dfa28 (HASH §7.2: kept, unused); no root moved |
| CM-10 | claude-spec-comments | cdCDDLe §5.1 l.172 | M1 | LOW | Acceptance. =s | `cddl/syntax.nim` `parseMember`; test `[IMPL-DECISION G10]` | resolved in 6a4dfa28 (cdCDDLe §5.1); =s |
| CM-11 | claude-spec-comments | cdCDDLe §5 l.125/455 | M1 | LOW | Escape spelling is not kept in canonical form. | `cddl/syntax.nim` `readEscape`, `bracedScalar`, `isC1`; tests `[CDE-0203]…[CDE-0209]`, `[IMPL-DECISION G157]` | changed in 6a4dfa28: RFC 9682 §2 strings; done (G11); line breaks in byte strings are G157 |
| CM-12 | claude-spec-comments | cdCDDLe §5.1 l.163 | M1 | LOW | Acceptance. | `cddl/syntax.nim` `checkRangeBound`; test `[IMPL-DECISION G12]` | resolved in 6a4dfa28 (cdCDDLe §5.1); =s |
| CM-13 | claude-spec-comments | cdCDDLe §7.4 (doc says "§7.2 / l.332"), §10 | M1 | LOW | Decoder rejection list. =s | `cddl/codec.nim` `decodeType`; test `[IMPL-DECISION G13]` | resolved in 6a4dfa28 (cdCDDLe §10); =s |
| CM-14 | claude-spec-comments | cdCDDLe §8; COMMITMENT §5 | M1 | MED | Changes cdCDDLe document content only; no root or vector impact. | `cddl/canon.nim` `canonicalize(scope)`; test `[IMPL-DECISION G14]` | resolved in 6a4dfa28 (COMMITMENT §5); =s |
| HC-11 | human-spec-comments | INTERFACE §2.1/§2.3; COMMITMENT §9.1 l.1288 | M1,M2,M10 | **HIGH-c** | Only if fixing HC-04 needs an ordering that stays stable when fields are added: struct layout, `_ARM_&lt;i&gt;` values, choice-index hashing. hc l.239-252 | — | resolved in 6a4dfa28 by spec text (no reply; review 2026-11-11, item E1): fields and parameters ordered by field-name bytes, source order not ABI-visible (INTERFACE l.895-897); deterministic, not append-stable; `claude-spec-comments-3.md` Appendix C |
| IF-01 | claude-spec-comments | INTERFACE §4.4/§4.5; TRANSPORT §2.3 | M1,M5 | MED | Which layer rejects floats; the encoder is unchanged. | `cbor/decode.nim` (`allowFloats`, I48), `transport/envelope.nim` `decodeValue`, `checkPayload` (I58); tests `[IFC-0976]`, `[IFC-0920]`, `[TRN-0203]` | changed in 6a4dfa28: floats rejected at any depth: decoder (I48) and transport close done |
| IF-02 | claude-spec-comments | INTERFACE §4.5/§5.1 | M1,M2 (+ripple) | **HIGH** | The suggested new reason value edits the common schema → every pinned root changes. cl l.284-290 | `cbor/decode.nim` `maxDepth`/`maxTagDepth` (I48); `iface/payload.nim` `ContractValidator.maxDepth` (I61); `transport/limits.nim` (I52, I59); commitment pipeline counts containers (I51); tests `[IFC-0923] [IFC-0926] [IFC-0928] [IFC-0929]`, `[IFC-0925] [IFC-0927]`, `[TRN-0269]`..`[TRN-0271]`; `runtime.max_payload_depth` (I88, G241); suite `run.depth` in `tests/test_async.nim`, tests `[IMPL-DECISION G241]` | resolved in 6a4dfa28 (INTERFACE §4.5.1): arrays and maps only, ≥ 128, configurable: done in every layer; the Runtime's one setting is `runtime.max_payload_depth` in app-config v1 (128 to 1024, default 1024; I88, G241), and 10b passes it, plus the envelope's levels, to the transport |
| NA-01 | claude-spec-comments-2 | CA §5, §7; INTERFACE §5.1 l.2503-2506; RUNTIME §9.3 | M1, M2, M3, M4 | MED | Additive: P [CR]. Detail allowed under NOT_AUTHORISED (N, changes the detail table) or a consumer-scoped pending event (Y). | — | resolved in 6a4dfa28 (declined) |
| NC-03 | claude-spec-comments-2 | INTERFACE §5.1; CONFIG §5; RUNTIME §9.3 | M1, M2, M4 | MED | Additive: N [CR]. New value in the closed `invalid_params_reason` set, or typed failure arms. | `iface/outcome.nim` `toFailure`; common roots in `spec/pins.toml`; test `[IFC-0441]` | changed in 6a4dfa28: new reason `configuration-schema-mismatch`, common roots recomputed: done; produced since I87 (`update_configuration`, test `[IFC-0441]` in `tests/test_config.nim`); remarked in `claude-spec-comments.md` (with EC-01 to EC-04) and `claude-spec-comments-2.md`, "Remarks on the responses" (logos-lips `68628d95`; review item E5) |
| ND-02 | claude-spec-comments-2 | INTERFACE §5.1 | M1, M2, M3, M4 | LOW | Additive: Y [CR]. Timestamp and duration common types. | — | resolved in 6a4dfa28 (declined) |
| ND-07 | claude-spec-comments-2 | INTERFACE §1.4, §5.1; PM §15; CA; LOADER | M1, M2, M4, M7, M8 | MED | Additive: P [CR]. `logos.domain_error`; PM, CA and LOADER switching to it changes their schemas and generated names. | — | resolved in 6a4dfa28 (declined) |
| NX-02 | claude-spec-comments-2 | TRANSPORT §5.1; INTERFACE §2.6, §5.1 | M1, M2, M5 | LOW | Additive: Y [CR]. Restrict the snapshot-event model to Runtime contracts (editorial). Add `logos.revision`. Optional on-subscription hook. | — | resolved in 6a4dfa28: no snapshot protocol; contracts define reconciliation |
| G151 | claude-spec-comments-2 (ND-10) | cdCDDLe §5.1 l.164 vs §8 l.530, l.537 | M1 | LOW | §5.1 allows `.size` on any target; the §8 node holds only a primitive. Interim: `x .size n` with `x` a rule name is rejected as unsupported, so no bytes are committed to. | `cddl/syntax.nim` `checkSize`; vector `unsupported-size-named-target` | settled in 6cac8335: cdCDDLe §5.1 l.157 limits the target (DECISIONS G151) |
| G152 | claude-spec-comments-2 (ND-11) | COMMITMENT §4 l.560-562 vs §8 l.1101 | M1 | **HIGH-n** | A leaf-bodied declaration's own node gets two identities (subtree root, leaf hash at `[]`); decides the schema identity in value nodes typed by it, so value roots. Interim: the subtree root. | `commitment/schema.nim` `nodeIdentity`, `commitment/normalize.nim` `identityOf`; tests `[IMPL-DECISION G152]` | settled by spec text (COMMITMENT §4 l.569-571); =s |
| PM-06 | claude-spec-comments | PM §4.3; CA §9.1 | M1,M7 | MED | Signature edge cases; no byte change. | `crypto/slhdsa.nim`, `crypto/cose.nim`, `package/signing.nim` (I68), `runtime/evidence.nim` (I85); PKG §4.3 claimed; suite `run.evidence` in `tests/test_evidence.nim` | changed in 6a4dfa28: SLH-DSA-SHA2-192s replaces Ed25519; built 2026-11-10 (R4, I68) |

## Tier 2 — schema surface and C types

| ID | Report | Spec §§ | Milestones | Risk | Likely fix, interim choice | Code / test | Status |
|---|---|---|---|---|---|---|---|
| NL-01 | claude-spec-comments-2 | RUNTIME §3.4, §10.2; INTERFACE §2.6, §2.8; LOADER §9; PM §4; BCP §5.4 | M2, M3, M4, M5, M7, M9 | HIGH | Additive: P. Declared stop budget [MR] plus a deadline handed to the module: either a `prepare_stop` hook (Y) or a `_destroy` parameter (N, changes the ABI). | — | resolved in 6a4dfa28 (declined; review item E6): drain and cleanup deadlines are deployment-supplied (RUNTIME l.3835; BCP l.372); a long flush goes into a declared method called before stop (RUNTIME l.3871) |
| NL-02 | claude-spec-comments-2 | RUNTIME §3.4 l.592-600, §10.2 l.3253-3261, §3.7 | M2, M3, M4 | HIGH | Additive: N. Rewrites the stop sequence: consumer routes stay open during a pre-stop phase, and admission closes per instance in reverse order. | — | resolved in 6a4dfa28 (declined) |
| NL-03 | claude-spec-comments-2 | INTERFACE §2.6; RUNTIME §3.4, §10.2 | M2, M3 | HIGH | Additive: P. `_destroy` returns `logos_result_t` (N) or a `report_cleanup` call is appended to the vtable (Y). | — | resolved in 6a4dfa28 (declined) |
| NR-11 | claude-spec-comments-2 | INTERFACE §2.8, §5.2; RUNTIME §4.1 | M2, M3, M5 | HIGH | Additive: Y. Async call appended to the route vtable, or several handles sharing one session (the handle-to-session model goes N:1). | `runtime/asynccall.nim`; tests `tests/test_async.nim` | changed in 6a4dfa28: async calls with independently owned prepared handles (INTERFACE ABI v2): built (I78) |
| AP-9 | claude-spec-comments | INTERFACE §1.1/§1.8 | M2 | LOW | Answered. | — | resolved in 6a4dfa28 |
| C-04 | claude-spec-comments | INTERFACE §2.3 vs §2 intro | M2 | LOW | Both suggested fixes accept "always emit the tag". =s | G64: `iface/cmap.nim` `choiceDef` always emits `kind`; test `[IFC-0148]` (tagged map union) | resolved in 6a4dfa28: tagged-map arms keep the literal tag; =s |
| C-05 | claude-spec-comments | INTERFACE A.4/A.5 vs RUNTIME §4.1 | M2,M3 | LOW | Helper names that are never exported. =s | — | resolved in 6a4dfa28 |
| C-06 | claude-spec-comments | RUNTIME §1.3 vs TRANSPORT §8.2 | M2,M5 | LOW | Socket path layout. =s | — | resolved in 6a4dfa28 |
| C-11 | claude-spec-comments | INTERFACE A.3; SECURITY l.230/441 | M2,M9 | LOW | Editorial. | — | resolved in 6a4dfa28 (no change); remarked in `claude-spec-comments.md`, "Remarks on the response" (logos-lips `68628d95`; review item E5) |
| HC-02 | human-spec-comments | LOADER §1/§3/§6; RUNTIME §5.2/5.3/7.5; TRANSPORT §1.3/§5 | M2,M5,M8 | **HIGH** | Subscribe `{0,id,event}` (l.193) gains a filter; one host per instance is broken. hc l.57-76 | — | awaiting owner follow-up |
| HC-03 | human-spec-comments | INTERFACE §2.4/§2.6; CA §2/§3.1; PM §15 | M2,M3,M4,M7,M8 | **HIGH** | Consumer passed into the unversioned `_dispatch` and typed signatures. hc l.80-98 | — | resolved in 6a4dfa28 by spec text (no reply; review 2026-11-11, item E1): the invocation context's `caller` supplies the authenticated origin (INTERFACE l.2181-2186); `claude-spec-comments-3.md` Appendix C |
| HC-04 | human-spec-comments | INTERFACE §1.2/1.4; TRANSPORT §3.1/§8.3/§10; CA §3.1; PM §4 | M2,M4,M5,M7 | **HIGH** | Exact-root identity, Hello equality, bare-name rule. hc l.102-122 | — | awaiting owner follow-up |
| HC-05 | human-spec-comments | INTERFACE §2.8/§5.2; TRANSPORT §5.3 | M2,M3 | MED | An async op can be appended to the vtable. | — | resolved in 6a4dfa28 by spec text (no reply; review 2026-11-11, item E1): `prepare_call` on Runtime Control and route bindings (INTERFACE l.2013-2016); several prepared calls may be outstanding on one handle (RUNTIME l.1363-1364); `claude-spec-comments-3.md` Appendix C |
| HC-06 | human-spec-comments | INTERFACE §5.1/§5.2; TRANSPORT §6 | M2,M3,M5 | MED | Cancel can be appended; HIGH if `call` gains a timeout parameter. | — | resolved in 6a4dfa28 by spec text (no reply; review 2026-11-11, item E1): a prepared call takes a caller-selected timeout (INTERFACE l.2059) and ends with TIMEOUT or, after `cancel`, CANCELLED (l.2067); `claude-spec-comments-3.md` Appendix C |
| HC-07 | human-spec-comments | INTERFACE §2.6/§2.8/A.3; BCP §6.1 | M2,M8 | **HIGH** | The mandatory export set would change. hc l.166-182 | — | awaiting owner follow-up |
| HC-10 | human-spec-comments | INTERFACE §5.2 l.2626, A.4; RUNTIME §7.3 | M2,M3,M8 | **HIGH** | `logos_publish_fn` return type and the publish helpers. hc l.221-237 | `runtime/events.nim`, `host/rcbinding.nim` `publishOp`; `codegen/kitrt.nim` `publishEncoded`; tests `[RUN-0242]`, `[TXT-0061]` | resolved in 6cac8335 by spec text: the callback returns `logos_error_code_t`, the publisher-side result (INTERFACE §5.2 l.3351; RUNTIME §7.3 l.1148-1149), and the kit passes it through (App A.4). Built in re-pin P2 with an interim result (I105) that P3 completes |
| IF-03 | claude-spec-comments | INTERFACE §2.3; RUNTIME l.1814; CA l.1001 | M2,M3,M4 | **HIGH** | C names and struct shape for tuple arms and list items. cl l.293-298 | `iface/cmap.nim`: the `_LIST`, `_TUPLE` and `_BSTR` families and the `_LI`, `_TU<i>`, `_AR_<Label>`, `_AR<i>` steps; tests `[IFC-0632] [IFC-0914] [IFC-0915] [IFC-0916]` | changed in 6a4dfa28: shape =s, names per C mapping revision 3 (G62 retired): done |
| IF-04 | claude-spec-comments | INTERFACE §1.5 vs §2.5 | M2 | **HIGH-n** | C form of choice-of-maps events. cl l.300-303 | `iface/cmap.nim` `choiceDef`; test `[IFC-0866] [IFC-0867]` | changed in 6a4dfa28: ordinary tagged union, `_event` stem kept (G63 retired): done |
| IF-05 | claude-spec-comments | INTERFACE §2.3, §3.5 | M2,M10 | LOW | Header text, not ABI. | — | resolved in 6a4dfa28 |
| IF-06 | claude-spec-comments | INTERFACE §3.4 | M2,M10 | **HIGH-n** | Position of the `has_` flag is struct layout. =s. cl l.311-314 | `iface/cmap.nim`; test `[IFC-0631]` | resolved in 6a4dfa28; =s (G66) |
| IF-07 | claude-spec-comments | INTERFACE §2.7 | M2 | MED | Allocation unit and free order. | `codegen/callrt.nim` `CallArena`, response owners (I72); suite `ifc.kit: typed provider functions` in `sdk/tests/test_kit.nim` | resolved in 6a4dfa28: built by I72 (review 2026-11-11, item C6) |
| IF-08 | claude-spec-comments | INTERFACE §2.7, A.5 | M2 | MED | Name of a non-exported free helper. | `lcn_clear_<namespace>_<Method>` in `codegen/cmirror.nim`, `codegen/callsgen.nim` (I73); suites `ifc.calls` in `sdk/tests/test_calls.nim` | resolved in 6a4dfa28: our helpers are `lcn_clear_…` (I73), built (review 2026-11-11, item C6) |
| IF-09 | claude-spec-comments | INTERFACE §1.3/§2.1; RUNTIME §1.3 | M2 | LOW | Name reservation; HIGH only if the symbol-derivation scheme changes. =s | `iface/names.nim` (the G69 checks removed) | resolved in 6a4dfa28: no extra reservation; G69 retired: done |
| IF-10 | claude-spec-comments | INTERFACE §5.2; RUNTIME §4.2 | M2,M6 | LOW | Editorial. | — | resolved in 6a4dfa28 |
| IF-11 | claude-spec-comments | INTERFACE §2.1 | M2 | LOW | Header order, not ABI. | `iface/cmap.nim` `emit`, `ordered`; test `[IFC-0882]` (§3.9.3 byte for byte) | resolved in 6a4dfa28: placement is not canonical; ours is I60 |
| NA-06 | claude-spec-comments-2 | CA §3.5, §10, §12; INTERFACE §2.6 | M2, M4 | MED | Additive: P. Scoped CA check method for providers (Y), or the allowed scope delivered with each dispatch (N, changes `_dispatch`). Depends on HC-03. | — | resolved in 6a4dfa28: restricted integration, no `_dispatch` change |
| NC-01 | claude-spec-comments-2 | CONFIG §3, §4, §7; INTERFACE §2.6 | M2, M4, M7 | MED | Additive: Y. Optional migration hook; MAY→MUST on retaining configuration. | — | resolved in 6a4dfa28 (declined) |
| ND-03 | claude-spec-comments-2 | TRANSPORT §2.1, §3.1; INTERFACE §4.6 | M2, M3, M5 | MED | Additive: N. Sender-side size check with a named reason (maybe [CR]); Hello maximum would be [W]. | `transport/framing.nim` `fits`, `frame`; `transport/session.nim`; suite `trn.size` | resolved in 6a4dfa28: sender-side size checks, MODULE_ERROR, no Hello maximum: done (I53) |
| ND-09 | claude-spec-comments-2 | INTERFACE §1.2, §5.3; cdCDDLe §7 | M2 | LOW | Additive: Y. Doc-comment convention; comments are still stripped before hashing. | — | resolved in 6a4dfa28 (declined) |
| NE-03 | claude-spec-comments-2 | INTERFACE §5.2; RUNTIME §4.4, §7.5, §9.3; CA §3 | M2, M3, M4 | MED | Additive: P. An ended-callback on subscribe is N if the `subscribe` signature changes and Y if it is appended. Default own-route observation plus a `consumers` scope selector is Y. | `runtime/bindings.nim` `routeObserveEndOp`, `runtime/events.nim`; tests `tests/test_routes.nim`, `tests/test_events.nim` | changed in 6a4dfa28: required `observe_end` on the route binding: built (I76); a route's end deactivates its subscriptions (I78) |
| NE-04 | claude-spec-comments-2 | INTERFACE §2.6; RUNTIME §9.3 | M2, M3 | LOW | Additive: Y. Provider session-end notification; `consumer` on `route_state_changed_event`. | — | resolved in 6a4dfa28 (declined) |
| NI-01 | claude-spec-comments-2 | INTERFACE §5.2; RUNTIME §9.3 | M2, M3 | LOW | Additive: Y. Append the ids to `logos_module_init_input_t` (l.2769), or add `describe_self`. | — | resolved in 6a4dfa28: `get_self` in Runtime Control; no ABI change |
| NL-05 | claude-spec-comments-2 | RUNTIME §3.4, §13; INTERFACE §2.6; SECURITY §11.5 | M2, M3, M12 | MED | Additive: Y. Suspend/resume host operations plus an optional hook; no new state proposed. The engine needs a quiesce-without-destroy path. | — | resolved in 6a4dfa28 (declined) |
| NL-09 | claude-spec-comments-2 | INTERFACE (new profile); TRANSPORT §3.2, §5.1 | M2, M8 | LOW | Additive: Y. Long-running-operation conventions. | — | resolved in 6a4dfa28 (declined; review item E6): one delayed result is one Request and its final Response (TRANSPORT l.841-843); anything longer is a contract-defined resource, no generic job protocol (l.851, l.858) |
| NR-12 | claude-spec-comments-2 | INTERFACE §2.6; TRANSPORT §6 | M2, M5 | MED | Additive: P. Statement or optional `_cancel` (Y). Its token needs a `_dispatch` change (N) or an appended getter (Y). | `runtime/invoke.nim`, `runtime/asynccall.nim`; tests `tests/test_routes.nim`, `tests/test_async.nim` | changed in 6a4dfa28: sticky cancellation in the invocation context (I76), optional `request_cancel` (I78): built |
| NX-04 | claude-spec-comments-2 | INTERFACE §2, §2.1, §3.9.5 | M2, M10 | MED | Additive: N (narrowing). Acceptance rule that rejects derived C names equal to `logos_types.h` names, or reserved namespaces. No accepted schema's generated name changes. It becomes HIGH only if the owner re-prefixes the common types instead. | `iface/cmap.nim` `cDeclarations` at acceptance (I23); test `[IFC-0123]` | resolved in 6a4dfa28: capitalized stems avoid the collision; the I23 interim is gone: done |
| PM-11 | claude-spec-comments | PM §10/§12; LOADER §3/§5; INTERFACE §2.6 | M2,M4,M7,M8 | MED | OPEN; the init input can grow compatibly. | — | resolved in 6a4dfa28: documented deployment convention (G93); remarked in `claude-spec-comments.md`, "Remarks on the response" (logos-lips `68628d95`; review item E5) |
| SO-07 | claude-spec-comments | INTERFACE §1.3 | M2,M7,M8 | MED | Renaming `lcn.` changes our own roots and C symbols. | — | resolved in 6a4dfa28 (declined; review item E6): only `logos.`, `logos-` and `logos_` are reserved (INTERFACE l.256-258); clashes surface through the collision rules |
| G153 | claude-spec-comments-2 (ND-12) | INTERFACE §2, §2.1, §5.3 | M2 | LOW | A cycle of local aliases (`a = b`, `b = a`) resolves and has a root but no value and no C form. Interim: rejected at acceptance; cycles through a structure are recursion and stay. Narrowing only. | `commitment/construct.nim` `checkAliasCycles`; tests `[CMT-0240]`, `[IMPL-DECISION G153]` | settled in 6cac8335: COMMITMENT §3 l.188 (DECISIONS G153) |
| G154 | claude-spec-comments-2 (ND-13) | INTERFACE §2.1, §2.3 | M2 | LOW | §2.3 forward-declares only targets of recursive by-value edges, so `{ kids: [* demo.node] }` inside `demo.node` does not compile. Interim: a list target on a cycle of by-value and list edges also gets a forward typedef. Header text only. | `iface/cmap.nim` `ordered`, `resolveGraph`; test `[IFC-0633]` | settled by spec text in 6a4dfa28 (INTERFACE §2.3 l.1077) |
| G155 | claude-spec-comments-2 (ND-14) | INTERFACE §2.1 l.676-679 vs §3.9.3 | M2 | LOW | CONTRA: least-name topological order gives `left, node, branch, right`; the required §3.9.3 header has `left, node, right, branch`. Interim: dependency depth, then qualified name, which reproduces §3.9.3. Header order only. | `iface/cmap.nim` `ordered`; test `[IFC-0882]` | moot in 6a4dfa28: placement is not canonical (IF-11) |

## Tier 3 — sans-I/O transport codecs, PM artifacts

| ID | Report | Spec §§ | Milestones | Risk | Likely fix, interim choice | Code / test | Status |
|---|---|---|---|---|---|---|---|
| NE-05 | claude-spec-comments-2 | TRANSPORT §5.2, §1.3; INTERFACE §2.8, §5.2; BCP §5.4 | M5 | HIGH | Additive: N [W]. Per-subscription buffering, a lag marker or closing one subscription, a coalesce hint on Subscribe. This replaces "close the connection" and needs new fields in closed envelope maps. | — | resolved in 6a4dfa28 (declined): bounded admission, backpressure or close; no envelope field |
| NP-02 | claude-spec-comments-2 | PM §4, §7.1 l.837/846, §10; LOADER §3 | M5, M7, M12 | HIGH | Additive: Y [MR]. Executable artifact kind (0755, symlinks) plus a new realization strategy where the signed executable acts as the Module Host. | — | resolved in 6a4dfa28 (declined) |
| NR-14 | claude-spec-comments-2 | TRANSPORT §8.2 l.951-967; SECURITY §11 | M5, M9 | HIGH | Additive: N. Security fix: a per-route socketpair or nonce instead of a socket path changes the endpoint model. Only MED if the owner picks uid+pid checks instead. | — | resolved in 6a4dfa28: same-identity protection needs distinct OS identities or failing the placement; G58 decided 2026-11-10: no same-identity claim (corrected 2026-11-11, review item E3) |
| AP-7 (G108) | claude-spec-comments | LOADER l.330 | M5 | LOW | Answered. | — | resolved in 6a4dfa28 |
| C-07 | claude-spec-comments | PM §4 l.341/363 vs §8 | M7 | MED | Validation rule, error value, check precedence. =s | `package/manifest.nim` `checkManifest` (shared schema/default artifacts allowed, one implementation artifact per module), `package/lgx.nim` `openLgx` (G29 check order); tests `[PKG-0053] [PKG-0054]`, `[PKG-0267]` | resolved in 6a4dfa28 (PM §4, §8 l.1070); =s |
| C-08 | claude-spec-comments | LOADER §6, §10 l.612 | M4,M5 | MED | Meaning of an error value; a new value would change the Loader root. =s | `runtime/artifact.nim` `stage` (`sfControls`), `runtime/realizer.nim` `runBind`; test `[LDR-0144]` | changed in 6a4dfa28 (review 2026-11-11, item A3): an advertised strategy whose required controls cannot be established fails with `realization-failed` (LOADER l.628); `unsupported-strategy` stays for an unadvertised one (l.377); G28's weaker-substitute refusal changes; done: `hosted_dynamic` is `unsupported-strategy` before anything is read (I74); a direct-dynamic staging control that cannot be established is `realization-failed`, an unreadable source stays `artifact-unavailable` (I88); hosted placements' controls come with the Module Host (Tier 4b) |
| C-10 | claude-spec-comments | RUNTIME Abs vs LOADER §5, §5.4 | M4,M5 | LOW | An in-process Loader fits both suggested fixes. =s | — | resolved in 6a4dfa28: separate-process compositions provide implementation-defined handoffs; remarked in `claude-spec-comments.md`, "Remarks on the response" (logos-lips `68628d95`; review item E5) |
| EC-05 | claude-spec-comments | RUNTIME §4.1; INTERFACE §5.2 | M3,M5 | MED | Error code. | — | resolved in 6a4dfa28: NOT_AUTHORISED vs NOT_READY by enforcement cause |
| EC-06 | claude-spec-comments | RUNTIME §3.4 | M3,M5 | MED | Error code. | — | resolved in 6a4dfa28: NOT_READY while stopping |
| HC-01 | human-spec-comments | INTERFACE §1.2/1.3; RUNTIME §9.3; PM §4.1; CA §3.1/3.3 | M4,M6,M7 | MED | Fields for publisher selection. | — | resolved in 6a4dfa28 by spec text (no reply; review 2026-11-11, item E1): the verified signer and package of a selection are observable provenance, not publisher identity (RUNTIME l.3519-3525); equal names or commitments establish no equal behaviour (l.1436-1437); a route request can pin one provider (l.3141); `claude-spec-comments-3.md` Appendix C |
| NC-04 | claude-spec-comments-2 | RUNTIME §8, §9.3; PM §4 | M3, M4, M7 | LOW | Additive: Y [MR]. Persistent-state declaration. | — | resolved in 6a4dfa28 (declined) for PM; state carriers are a Runtime/profile matter |
| NC-06 | claude-spec-comments-2 | TRANSPORT §8.2; SECURITY §11 | M5, M12 | LOW | Additive: Y. Likely a "files travel as bytes" statement. | — | resolved in 6a4dfa28: files through an ordinary broker contract |
| NE-01 | claude-spec-comments-2 | TRANSPORT §5.2-5.3; INTERFACE §1.5, §5.2; RUNTIME §7.3 | M5, M8 | LOW | Additive: Y. State the notify-then-fetch rule; optional targeted publish. | `runtime/asynccall.nim`, `runtime/events.nim`; tests `tests/test_async.nim`, `tests/test_events.nim` | resolved in 6a4dfa28 (adapted): one-shot deferred result, invocation-scoped events: built (I78) |
| NE-02 | claude-spec-comments-2 | TRANSPORT §5.3, §6, §7; RUNTIME §6.4, §7.2; INTERFACE §2.8 | M3, M5 | MED | Additive: N. Events caused by a call are delivered after its Response, so publishing inside direct-mode dispatch must be deferred. HIGH [W] if a correlation field is added to Event instead. | — | resolved in 6a4dfa28 (declined): no Response-before-Event barrier; never reorder |
| NI-04 | claude-spec-comments-2 | RUNTIME §9.3; PM §15 | M3, M4, M7 | MED | Additive: P. New `destroy_module` (Y). `remove_package` fails with `package-in-use` (N for PM). | — | resolved in 6a4dfa28: `retire_module`; package removal retires nothing |
| NI-06 | claude-spec-comments-2 | PM §5, §6, §12; CA §3.3 | M3, M4, M7 | LOW | Additive: Y. Add `signer` to PM records and the handoff; optional signer constraint in scopes. | — | resolved in 6a4dfa28 (adopted): the verified signer is kept with records and handoffs; `VerifiedPackage.signer` changes with R4 |
| NL-04 | claude-spec-comments-2 | RUNTIME §6.2, §10.1; LOADER §6, §9, §11 | M4, M5 | MED | Additive: N. Source of the startup timeout, overrun behaviour, recovery carve-out. | — | resolved in 6a4dfa28: startup expiry prevents readiness; owner supplies deadlines |
| NL-07 | claude-spec-comments-2 | RUNTIME §9.3; LOADER §10; CONFIG §8 | M3, M4, M5, M6 | MED | Additive: P. `? failure` field (Y). A facade `unknown` state extends the closed `state` enum (N). | — | resolved in 6a4dfa28: machine-readable classifications over open failure codes; remarked in `claude-spec-comments-2.md`, "Remarks on the responses" (logos-lips `68628d95`; review item E5); a facade record's `failure` and `state`: interim G355 (owner, B6, 2026-11-17), Tier 5 step 5-7b |
| NL-08 | claude-spec-comments-2 | LOADER §7; RUNTIME §10.1 | M4, M5 | LOW | Additive: Y. Optional liveness probe. | — | resolved in 6a4dfa28 (declined) |
| NO-03 | claude-spec-comments-2 | RUNTIME §9.3; PM §4 | M3, M4, M7 | LOW | Additive: Y [MR]. Usage method; footprint field. | — | resolved in 6a4dfa28 (declined) |
| NP-01 | claude-spec-comments-2 | PM §4, §6; RUNTIME §9.3 | M3, M7 | LOW | Additive: Y [MR]. Optional signed metadata; operator label. | — | resolved in 6a4dfa28 (declined) |
| NP-03 | claude-spec-comments-2 | PM §4, §9; LOADER §3; BCP §5.3 | M3, M4, M7, M12 | MED | Additive: P [MR]. `module-binary` no longer mandatory (code that assumes a binary must handle its absence). | — | resolved in 6a4dfa28 (declined) |
| NP-04 | claude-spec-comments-2 | PM §4, §12; RUNTIME §13.3 | M4, M7, M12 | MED | Additive: P [MR]. `runtime_handoff.artifact` becomes optional. | — | resolved in 6a4dfa28 (declined) |
| NP-05 | claude-spec-comments-2 | PM §4, §10 | M7 | LOW | Additive: Y [MR]. Licence metadata. | — | resolved in 6a4dfa28 (review item E6): licence material as verified `resource` artifacts; replacing executable bytes goes through acceptance, never an in-place swap (PM l.1202-1203) |
| NP-06 | claude-spec-comments-2 | PM §4, §7.1 | M7 | LOW | Additive: Y [MR]. `requires_runtime`. | — | resolved in 6a4dfa28 (declined): deployment-documented values; G73 is such a profile |
| NP-07 | claude-spec-comments-2 | PM §7.1; BCP §5.4 | M7, M9 | LOW | Additive: Y. Define the installation root. | — | resolved in 6a4dfa28: installation root and inventory scope are documented deployment choices |
| NP-08 | claude-spec-comments-2 | PM §15; RUNTIME §9.3 | M3, M7 | LOW | Additive: Y. PM events; record-created event. | — | resolved in 6a4dfa28 (adopted): `watch_installed_packages`, `progress_key`; Tier 5 |
| NP-09 | claude-spec-comments-2 | PM; CA §3.5; SECURITY | M7, M9, M12 | LOW | Additive: Y [MR]. Platform-integration artifact. | — | resolved in 6a4dfa28 (declined) |
| NP-10 | claude-spec-comments-2 | PM §4.1; CA §8 | M4, M7 | MED | Additive: N. Anti-rollback for trust input; withdrawn-signer default. | — | resolved in 6a4dfa28 (adopted): monotonic trust revision and high-water mark; G137 continuity decided 2026-11-10 (one protected trust file with a monotonic revision and a compiled-in floor); the dev anchor is an entry of the trust file, its switch or marker inside the same revisioned file (re-decided 2026-11-11, review items E4, A12) |
| NP-11 | claude-spec-comments-2 | PM §7.1, §10 | M7 | MED | Additive: Y [MR]. LGX `common/` directory. | — | open (not answered) |
| NP-12 | claude-spec-comments-2 | PM §4.5, §5, §6 | M7, M11 | MED | Additive: P. Several manifests per identity, or a split distribution form. | — | open (not answered) |
| NR-06 | claude-spec-comments-2 | TRANSPORT §8.1 | M5, M6 | LOW | Additive: Y. Clarify that renewal rebinds live sessions. | — | resolved in 6a4dfa28: renewal never rebinds a live session |
| NR-13 | claude-spec-comments-2 | TRANSPORT §3.1, §8.2; RUNTIME App B.1 | M5, M6 | LOW | Additive: P. Define a local control profile or delete the unused variant. | — | resolved in 6a4dfa28: no general local Runtime Control profile |
| NS-01 | claude-spec-comments-2 | SECURITY §11; LOADER §1, §3 | M5, M9, M12 | LOW | Additive: Y. Statement plus placement profile. | — | resolved in 6a4dfa28: profiles name the consent principal and bypass controls |
| NS-02 | claude-spec-comments-2 | RUNTIME §4.2.1, §10.1; LOADER §7 | M5 | MED | Additive: N. Module Host stops and exits when it loses its Runtime connection. | — | resolved in 6a4dfa28: loss of owner control ends hosted admission |
| PM-01 | claude-spec-comments | PM §4.5/§5/§6/§13 | M7,M8 | **HIGH** | OPEN; locator encoding and fetch contract are undefined. cl l.546-553 | — | resolved in 6a4dfa28: implementation-defined, documented locators (G5 closes) |
| PM-02 | claude-spec-comments | PM §5/§7/§13 | M7,M9 | MED | Additive source kind. | — | resolved in 6a4dfa28; =s |
| PM-03 | claude-spec-comments | PM §15 | M7 | MED | Follows HC-03. | — | changed in 6a4dfa28: observation policy, not method permission (G39); Tier 5; cursors and snapshot accounting are keyed on the caller from the invocation context (PM l.1625, l.1704; INTERFACE l.2181-2183), no deviation needed (review 2026-11-11, item A11) |
| PM-04 | claude-spec-comments | PM §4, §7.1 | M7 | MED | Pax touches only the reader; shrinking the path limit changes manifest roots. | `package/lgx.nim` `splitPath`; test `[IMPL-DECISION G40]` | resolved in 6a4dfa28 (PM §7.1 l.920-924); =s |
| PM-05 | claude-spec-comments | PM §7.1 | M7 | MED | Archive acceptance. | `package/lgx.nim` `gunzip`, `readTar`, `writeLgx`, `checkStructure`; tests `[IMPL-DECISION G41]`, `[PKG-0492]` | resolved in 6a4dfa28 (PM §7.1); =s, plus whole-block padding: done (I49) |
| PM-07 | claude-spec-comments | PM §11/§15 | M7 | MED | Tie-break. | — | resolved in 6a4dfa28 (PM §11); =s |
| PM-08 | claude-spec-comments | PM §11 | M7 | MED | Error. | — | resolved in 6a4dfa28 (PM §11); =s |
| PM-09 | claude-spec-comments | PM §3, §7.1 | M7 | LOW | Diagnostic file. | `package/lgx.nim` `checkStructure`; test `[PKG-0477]` (a root `manifest.json`) | changed in 6a4dfa28: `manifest.json` removed; a root one is `invalid-package`; done (I49) |
| PM-10 | claude-spec-comments | PM §10 l.1082 (doc says §7.1), §4 l.316 | M7,M9,M12 | MED | Platform strings; turning them into an enum would change manifest roots. | `package/lgx.nim` `compatible`, `checkInstallPaths`, `hostPathRules`, `hostPlatform`; tests `[PKG-0486]`, `[PKG-0495]` | changed in 6a4dfa28: deployment-defined values, undefined values never match, install-namespace collisions; done (I49) |
| PM-15 | claude-spec-comments | PM Scope/§11 | M7 | MED | Manifest field → manifest roots change. | — | resolved in 6a4dfa28 (PM §11); =s |
| RT-04 | claude-spec-comments | RUNTIME §9.3; PM §5/§11; CA §3.3 | M3,M4,M7 | MED | Possible new `create_module` field. | `runtime/host_config.nim` (`modules`, `declarations`), `runtime/engine.nim` `createModule` | changed in 6a4dfa28: exact pinned package selection (G55); done for direct records: the host's `modules` and `declarations` are the protected exact pins (I82, G55 re-decided 2026-11-11), and `create_module` has no selector; the package pin table comes with the Package Manager handoff (Tier 5, owner decision 1 (a); I97) |
| RT-05 | claude-spec-comments | LOADER §7; RUNTIME §10 | M4,M5 | MED | Adopt-or-terminate rule. | — | resolved in 6a4dfa28: Loader loss keeps custody; replacement waits for confirmed end; remarked in `claude-spec-comments.md`, "Remarks on the response" (logos-lips `68628d95`; review item E5) |
| RT-06 | claude-spec-comments | RUNTIME §9.3 | M3,M4,M7 | MED | New Runtime Control op (additive). | — | resolved in 6a4dfa28: explicit replacement instance and state migration |
| SO-01 | claude-spec-comments | PM §4.2/§4.4/§6/§11/§13/§15 | M7,M9,M13 | **HIGH** | Our catalog document would be replaced. cl l.657-670 | — | resolved in 6a4dfa28: implementation-defined and documented (G90, G150, G74 stand) |
| SO-02 | claude-spec-comments | PM §4.5/§6/§13 | M7,M8 | **HIGH** | `lcn.storage_fetch` would become a spec contract. cl l.672-679 | — | resolved in 6a4dfa28: no common fetch interface (`lcn.storage_fetch` stands) |
| SO-05 | claude-spec-comments | CA §3.5; PM §4 | M4,M7,M8 | MED | Permission names. | — | resolved in 6a4dfa28 (declined): deployments document permissions (G110) |
| SO-09 | claude-spec-comments | RUNTIME §12; TRANSPORT §2.1 | M8 (M5) | MED | The spec calls streaming "future". | — | resolved in 6a4dfa28: no streaming protocol; sender size checks only |
| TR-01 | claude-spec-comments | TRANSPORT §1.2/§1.4/§2.3/§3.3 | M5 | MED | Receiver rule. | `transport/session.nim` `receive` (both sides), `transport/hello.nim` `acceptHello`; tests `[TRN-0272]`..`[TRN-0275]` (suites `trn.direction`, `trn.hello`) | resolved in 6a4dfa28 (TRANSPORT §2.3); =s, plus a first ProtocolError closes without a reply (G30): done |
| TR-02 | claude-spec-comments | §1.4, §5.1, §6 | M5 | MED | Receiver rule. | `transport/session.nim` `abandon`, `abandonSubscription`, `onResponse`; tests `[TRN-0280]`..`[TRN-0289]` (suite `trn.correlation`) | changed in 6a4dfa28 (TRANSPORT §3.4): the first late reply to an abandoned call is validated, then discarded (G31): done |
| TR-03 | claude-spec-comments | §5.1 | M5 | MED | Error code. | `transport/session.nim` `onSubscribe`, `onUnsubscribe`, `subscribe`, `unsubscribe`; tests `[TRN-0302]`..`[TRN-0306]` (suite `trn.subscribe`) | changed in 6a4dfa28 (TRANSPORT §5.1): overlapping operations close; failed and ended ids count as used (G32): done |
| TR-04 | claude-spec-comments | §3.1 | M5 | MED | Error code. | `transport/hello.nim` `acceptHelloResponse`; test `[TRN-0277] [TRN-0070]` | resolved in 6a4dfa28 (TRANSPORT §3.1); =s |
| TR-05 | claude-spec-comments | §3.1/§3.2/§8.1.1; INTERFACE §4.6 | M5,M6 | MED | When the Hello happens. | `transport/hello.nim` `acceptHelloResponse` (the callee's ProtocolError code is the outcome); suite `trn.hello`. When the Hello runs is 10b (Tier 4b) | resolved in 6a4dfa28 (RUNTIME §4.1); =s |
| TR-06 | claude-spec-comments | §8.1; CA §8 | M4,M5 | MED | HIGH only if a new message kind is added. | `transport/session.nim` `beginTermination`, `finishTermination`; tests `[TRN-0321]`..`[TRN-0324]` (suite `trn.termination`) | resolved in 6a4dfa28 (TRANSPORT §8.1); =s (G35); termination mode done (I57) |
| TR-07 | claude-spec-comments | §4.1 | M5 | MED | Close vs error response. | `transport/boundary.nim` `acceptResponse`, `acceptEvent`; test `[TRN-0097] [TRN-0300]` | resolved in 6a4dfa28 (TRANSPORT §4.1); =s |
| TR-08 | claude-spec-comments | §4.1 | M5 | MED | Check precedence. | `transport/boundary.nim` `acceptRequest`; tests `[TRN-0292]`..`[TRN-0298]` | resolved in 6a4dfa28 (TRANSPORT §4.1 l.655-673): the code's order conforms; G37 restated |
| TR-09 | claude-spec-comments | §8.2, §9.1 | M5,M12 | MED | Windows mechanism. | — | resolved in 6a4dfa28: conditional Windows applicability with stated requirements (G107 spike) |
| G156 | claude-spec-comments-2 (NP-15) | PM §8 l.1000 vs §4 l.326 and §8 l.974 | M7 | LOW | An artifact without its `hash` is named `artifact-integrity-failed` by §8 l.1000, but the §4 CDDL requires the field, so the manifest fails validation, which l.974 makes `invalid-package`. Error code only; no bytes change. Interim: `invalid-package` (the schema check runs first, G29). | `package/manifest.nim` `decodeManifest`; test `[PKG-0258]` | settled at 6cac8335 (re-pin P7a): PM l.1096-1101 drops the bullet, so the interim is the text; PKG-0275 is stale |

## Tier 4 — runtime, Loader, CONFIG, CA

| ID | Report | Spec §§ | Milestones | Risk | Likely fix, interim choice | Code / test | Status |
|---|---|---|---|---|---|---|---|
| NX-03 | claude-spec-comments-2 | CA §3, §3.1, §5, §8, §9, §9.1; RUNTIME §4.1, §4.3, §9; TRANSPORT §8.1 | M3, M4 | HIGH | Additive: P. Core rule: whether each call is an authorization decision point. Either per-call evaluation is added on the call path, or the CA `call` action is dropped. Call audit and evidence records change either way. | `runtime/callaudit.nim`, `engine.captureOf` (I85); suite `run.audit` in `tests/test_audit.nim` | changed in 6a4dfa28: every call is an authorization point; cached decisions allowed (G52) |
| AP-1 (G54) | claude-spec-comments | RUNTIME l.164 | M3 | LOW | Answered. | — | resolved in 6a4dfa28 |
| AP-2 (G57) | claude-spec-comments | RUNTIME l.3060 | M4 | LOW | Answered. | — | resolved in 6a4dfa28 |
| AP-4 (G60) | claude-spec-comments | RUNTIME §13.3/13.4 | M3 | LOW | Answered. | — | resolved in 6a4dfa28 |
| AP-5 (G50) | claude-spec-comments | CA l.1049 | M4 | LOW | Answered. | `runtime/evidence.nim` `checkSide` (I85); suite `run.evidence` | changed in 6a4dfa28: empty sides omitted |
| AP-8 | claude-spec-comments | RUNTIME §4.2 | M3,M8 | LOW | Answered. | — | resolved in 6a4dfa28 |
| C-09 | claude-spec-comments | CA §2 vs RUNTIME §9 | M4,M6 | MED | Policy rule. =s | — | declined in 6a4dfa28 (corrected 2026-11-17, step 5-0: `claude-spec-comments-3.md` Appendix B lists it as declined; no definition of "resolve" for an address owned by another Runtime was added, while historical addresses were, CA l.77-80); remarked as NF-06 in `claude-spec-comments-2.md`, "Remarks on the responses" (logos-lips `68628d95`; review item E5); interim: G81 (a) narrowed (owner, B5, 2026-11-17), Tier 5 step 5-7a |
| CA-01 | claude-spec-comments | CA §3.3, §8 | M4 | MED | Rule. | — | resolved in 6a4dfa28; =s (G46) |
| CA-02 | claude-spec-comments | CA §2 | M4 | MED | Possible new field on `evaluate`. | `authority/facts.nim`, `policy.nim` (I84); suite `cap.evaluate` in `tests/test_authority.nim` | changed in 6a4dfa28: protected attribute integration (G47) |
| CA-03 | claude-spec-comments | CA §3.1 | M4 | MED | OPEN; removing it changes a CA schema; tied to HC-02. | `authority/scopes.nim`, `core.nim` (the publisher is the consumer; I84); suites `cap.scopes`, `cap.evaluate` | changed in 6a4dfa28: `publish-event` enforced at publish and delivery (G49) |
| CA-04 | claude-spec-comments | CA §9.1 | M4 | MED | Array order is bytes, but CA l.110-115 already points to our choice. | — | resolved in 6a4dfa28; =s |
| CA-05 | claude-spec-comments | CA §6, §9 | M4 | MED | Ordering and cursors. | `authority/cursor.nim`, `audit.nim` (I84); suites `cap.list`, `cap.audit` | changed in 6a4dfa28: live `list_grants` continuation, timestamp-ordered audit (G51) |
| CA-06 | claude-spec-comments | CA §9 | M3,M4 | MED | Which `decision_id`. | `runtime/dcache.nim`, `engine.decide`, `engine.captureOf` (I85); suites `run.authority` in `tests/test_runtime_authority.nim` and `run.audit` in `tests/test_audit.nim` | changed in 6a4dfa28: the actual call decision (G52) |
| CA-07 | claude-spec-comments | CA §9.1 | M4 | MED | Additive method. | `host.exportCallEvidence` (I85, in-process); suite `run.host-api` in `tests/test_host_authority.nim` | resolved in 6a4dfa28; =s (G115) |
| EC-01 | claude-spec-comments | RUNTIME §9.3 | M3 | MED | Error code. | — | resolved in 6a4dfa28: precondition table; remarked in `claude-spec-comments.md`, "Remarks on the response" (logos-lips `68628d95`; review item E5) |
| EC-02 | claude-spec-comments | RUNTIME §9.1/§9.3; CONFIG §3 | M3,M4 | MED | Error code. | — | resolved in 6a4dfa28: precondition table; remarked in `claude-spec-comments.md`, "Remarks on the response" (logos-lips `68628d95`; review item E5) |
| EC-03 | claude-spec-comments | RUNTIME §9.3 | M3 | MED | Error code. | — | resolved in 6a4dfa28: precondition table; remarked in `claude-spec-comments.md`, "Remarks on the response" (logos-lips `68628d95`; review item E5) |
| EC-04 | claude-spec-comments | CONFIG §8; RUNTIME §9.3 | M4 | MED | Error code; a failure arm would change the Runtime Control root. | — | resolved in 6a4dfa28: CONFIG table with VERSION_MISMATCH and TRANSPORT_ERROR (G21); remarked in `claude-spec-comments.md`, "Remarks on the response" (logos-lips `68628d95`; review item E5) |
| EC-07 | claude-spec-comments | RUNTIME Sys. Svc Availability | M3,M4 | MED | Error code. | — | resolved in 6a4dfa28: precondition table |
| EC-08 | claude-spec-comments | INTERFACE §5.2 | M3,M6 | MED | Error code. | `abi/checks.nim` (I66); suites `ifc.abi-*` in `sdk/tests/test_abi.nim` | changed in 6a4dfa28 (review 2026-11-11, item A4): VERSION_MISMATCH only for an unsupported version or extent; a null vtable, state or required operation is MODULE_ERROR (INTERFACE l.3819-3820); G25 superseded; done in `abi/checks.nim` (I66) |
| EC-10 | claude-spec-comments | RUNTIME §9.3 | M3,M4,M6 | MED | Free text becomes an enum → Runtime Control root changes. | — | changed in 6a4dfa28: open failure codes with defined lists (G27) |
| EC-11 | claude-spec-comments | RUNTIME §13.3/§13.4 | M3 | MED | Error code. (For all EC items: allocating *new* codes instead would cause the common-schema ripple.) | — | resolved in 6a4dfa28 |
| HC-08 | human-spec-comments | INTERFACE Invariance; RUNTIME §12; CONFIG §1/§6 | M3,M8 | MED | Affects our methods that take host paths (G99). | — | resolved in 6a4dfa28 by spec text (no reply; review 2026-11-11, item E1): a path grants no access in another realization (RUNTIME l.3910); co-location gives no shared namespace, and a contract taking a path defines whose namespace and the failure (l.3917-3920); G99 is decided per contract when the payload modules are ported (re-decided 2026-11-11, review item A9); `claude-spec-comments-3.md` Appendix C |
| HC-09 | human-spec-comments | CA §9; RUNTIME | M3,M4 | MED | Additive. | — | resolved in 6a4dfa28 by spec text (no reply; review 2026-11-11, item E1): no Core logging facility; optional diagnostic logging through ordinary module contracts and deployment integration (BCP l.550-552); `claude-spec-comments-3.md` Appendix C |
| HC-12 | human-spec-comments | RUNTIME §9.2/§9.3 | M3 | MED | Field (changes the Runtime Control root). | — | resolved in 6a4dfa28 by spec text (no reply; review 2026-11-11, item E1): `create_module_request` carries only `request_key` and `module` (RUNTIME l.2233-2236), the key is idempotency only (l.3627); `claude-spec-comments-3.md` Appendix C |
| HC-13 | human-spec-comments | CA §5/§8; RUNTIME §4.3/§9 | M4 | MED | Pending-decision state. | — | resolved in 6a4dfa28 by spec text (no reply; review 2026-11-11, item E1): each call is an authorization point (RUNTIME l.1732-1735); a denial is final and approval workflows are ordinary module contracts (l.741-743); `claude-spec-comments-3.md` Appendix C |
| NA-02 | claude-spec-comments-2 | CA §8, §9; RUNTIME §2.4 | M4 | LOW | Additive: Y. Pending-approval event; approver role. | — | resolved in 6a4dfa28 (declined) |
| NA-03 | claude-spec-comments-2 | RUNTIME §9.3 | M3 | LOW | Additive: Y. Always set `expires_at`. | `runtime/routes.nim`, `engine.establish`, `engine.renew` (I85; G218); suite `run.authority` | resolved in 6a4dfa28 |
| NA-04 | claude-spec-comments-2 | RUNTIME §9.3 | M3, M4 | MED | Additive: N. `request_key` retains only successful results. | — | resolved in 6a4dfa28: use the spec's replay rule; remarked in `claude-spec-comments-2.md`, "Remarks on the responses" (logos-lips `68628d95`; review item E5); interim decided by the owner (decision 12, 2026-11-13) and built in Tier 4b step 4b-2a (I90, G255): a replay returns the retained record without `invocation`, and the consumer renews |
| NA-05 | claude-spec-comments-2 | CA §6, §9 | M4 | LOW | Additive: Y. `issuer`, `decision_id` on grants. | `authority/core.nim` (I84); suite `cap.grants` | resolved in 6a4dfa28: `issuer` added |
| NA-07 | claude-spec-comments-2 | CA §8; RUNTIME §4.4, §9.3 | M3, M4 | MED | Additive: N. Eager re-evaluation of live routes on policy change. | `engine.notice`, `runtime/dcache.nim`, `engine.reauthRoutes` (I85, G216); suite `run.authority` | resolved in 6a4dfa28: re-evaluation at admission; how a route is re-authorized is G216 (TF-33) |
| NA-08 | claude-spec-comments-2 | CA §3, §5, §9 | M4 | LOW | Additive: Y. Unique `decision_id` (random 128-bit ids satisfy it now). | `authority/ids.nim` (I84); suite `cap.ids` | resolved in 6a4dfa28 |
| NA-09 | claude-spec-comments-2 | RUNTIME §7.5; CA §5, §6; BCP §2 | M3, M4 | MED | Additive: Y. Optional `on_behalf_of`; the specs defer delegation by design. | — | resolved in 6a4dfa28 (declined) |
| NA-10 | claude-spec-comments-2 | CA §9, §9.1 | M4 | LOW | Additive: Y. Redacted scope form. | — | resolved in 6a4dfa28 (declined) |
| NA-11 | claude-spec-comments-2 | RUNTIME §9, §10.1; CA §1, §8 | M4 | MED | Additive: N. Bootstrap versus CA precedence rule. | `engine.derivedRule`, `engine.checkBinding` (I85); suite `run.authority` | resolved in 6a4dfa28 |
| NC-02 | claude-spec-comments-2 | CONFIG §4; RUNTIME §9.3 | M4 | MED | Additive: P. Package-default acceptance MAY→MUST; reset action; refusal code. | — | resolved in 6a4dfa28: NOT_READY keeps intent (gap G162) |
| NE-06 | claude-spec-comments-2 | RUNTIME §3.4, §9.3, §10.2 | M3 | MED | Additive: N. One ordering rule within `stopping`. | — | resolved in 6a4dfa28 (declined; review item E6): delivery of an event published while stopping is not guaranteed (RUNTIME l.1239-1241) |
| NI-02 | claude-spec-comments-2 | RUNTIME §9.3, §2.4, §10.1; CA §3.1 | M3, M4, M6 | MED | Additive: N. Provider id bound to the instance for its whole life, so it must be persisted. | `runtime/store.nim`, `engine.restore` (I82); suite `run.persist` in `tests/test_persist.nim` | resolved in 6a4dfa28 |
| NI-03 | claude-spec-comments-2 | RUNTIME Term., §9.3; CONFIG §3; CA §6 | M3, M4 | MED | Additive: N. Persist both ids in every profile; define what happens to records that name a lost identity. | `runtime/store.nim`, `engine.load` (I82, G192); `tests/test_persist.nim`, `tests/test_host.nim` | resolved in 6a4dfa28 |
| NI-05 | claude-spec-comments-2 | RUNTIME §9.3 | M3 | MED | Additive: N. `instance` becomes mandatory on events and the stop response; ambiguity error code. | — | changed in 6a4dfa28: exactly one of `instance` or `provider` |
| NI-07 | claude-spec-comments-2 | CA §6; RUNTIME §9.3 | M3, M4 | MED | Additive: P. New `orphaned` grant status (the closed enum grows) or a stable-selector target. | — | resolved in 6a4dfa28 (declined) |
| NL-06 | claude-spec-comments-2 | RUNTIME §3.4, §9.3 | M3, M4 | MED | Additive: N. `error` persists until an explicit start, recover or stop; align `start_module`. | — | resolved in 6a4dfa28 |
| NL-10 | claude-spec-comments-2 | RUNTIME §10.1, §9.3 | M3, M4 | LOW | Additive: Y. MUST resume retained intent (matches the plan's decision D24); `restart_module`. | `engine.recover`, `engine.bootstrap` (I82, the engine half of D24); `tests/test_persist.nim` | resolved in 6a4dfa28 |
| NL-11 | claude-spec-comments-2 | CONFIG §8; RUNTIME §9.1 | M4 | MED | Additive: N. Mandatory deadline for `apply_configuration`. | — | resolved in 6a4dfa28: mandatory application deadline (G61) |
| NO-01 | claude-spec-comments-2 | RUNTIME §9.3 | M3, M6 | LOW | Additive: Y. Cursors on list methods. | `runtime/inventory.nim`, `runtime/observe.nim`, `engine.listModules`, `engine.listRoutes` (I86; G161, G226); suites `run.rc: list_modules`, `run.rc: list_routes` in `tests/test_observe.nim` and `tests/test_observe_ca.nim` | resolved in 6a4dfa28 |
| NO-02 | claude-spec-comments-2 | RUNTIME §9.3 | M3, M6 | MED | Additive: P. New fields and events (Y); `instance` mandatory (N). | `runtime/rcevents.nim`, `engine.observedRc`, `engine.hintRc`, `engine.routeEndedRc` (I86 part 7b; G178, G225, G226); suites `run.rc: the events`, `run.rc: inventory_changed` in `tests/test_rcevents.nim` and `tests/test_rcevents_ca.nim` | resolved in 6a4dfa28: `inventory_changed` hint |
| NO-04 | claude-spec-comments-2 | RUNTIME §9.3 | M3 | LOW | Additive: Y. `describe_runtime`. | — | resolved in 6a4dfa28 (declined) |
| NO-05 | claude-spec-comments-2 | RUNTIME §9.3 l.2243 | M3, M4 | MED | Additive: N. Initial permission-settings state. | `engine.permissionSettings` (I86; the constant form of direct mode, G229); suite `run.rc: permission settings in direct mode` in `tests/test_observe.nim`; with a profile, `runtime/settings.nim` and `engine.createInst` (I93; G110, G281), suite `run.permissions: settings` in `tests/test_permissions.nim` | resolved in 6a4dfa28 |
| NO-06 | claude-spec-comments-2 | RUNTIME §9.3, §10.1 | M4 | MED | Additive: N. Effect of widening a running instance's permissions. | `engine.profiledSettings`, `engine.settleSettings` (I93; reconciliation by stop and re-realize, G281); suite `run.permissions: reconciliation` in `tests/test_permissions.nim` | resolved in 6a4dfa28 |
| NO-07 | claude-spec-comments-2 | CA §3.3; RUNTIME §9.3 | M3, M4 | MED | Additive: N. Table mapping lifecycle methods to CA actions; `load`/`unload` may be dropped. | `runtime/authscopes.nim`, `engine.execute` (I85); suite `run.authority` | resolved in 6a4dfa28: CA actions `start` and `stop` |
| NR-04 | claude-spec-comments-2 | RUNTIME §9.3; INTERFACE §5.2 | M3, M6 | MED | Additive: P. Drop `continuations` from the module-facing response (N) or define a follow-up call (Y). | — | resolved in 6a4dfa28; remarked in `claude-spec-comments-2.md`, "Remarks on the responses" (logos-lips `68628d95`; review item E5); continuations on a `connect_remote` binding: interim G356, resolve or fail (owner, B7, 2026-11-17), Tier 5 step 5-7b |
| NX-01 | claude-spec-comments-2 | CA §8, §10; RUNTIME §7.3, §9.3; INTERFACE §2.5 | M3, M4 | MED | Additive: P. Likely: `grant_changed` carries only a revision and subscribers fetch the grant (N for the CA contract). Alternatives: the Runtime filters by target (Y), or a provider admission hook plus targeted publish (Y, new ABI). | `authority/provider.nim` `watch_changes` (I84); `engine.subscribe` refuses ordinary subscriptions to the notices (I85); suites `cap.watch`, `run.authority` | changed in 6a4dfa28: `watch_changes`, restricted subscriptions (G82) |
| NX-06 | claude-spec-comments-2 | RUNTIME §9.3 | M3 | LOW | Additive: Y. Content rule for `reason`; Runtime MAY withhold module text. | — | resolved in 6a4dfa28 |
| RT-02 | claude-spec-comments | RUNTIME §9, §10.2 | M3,M4 | MED | Authority basis for engine calls. =s | — | resolved in 6a4dfa28; =s (G48) |
| RT-03 | claude-spec-comments | RUNTIME §1.3 | M4 | LOW | A name. | — | changed in 6a4dfa28: no canonical name; `logos_` reserved (G53); the reference orchestration module is `lcn_orchestrator`, which the host names (I94) |
| SO-03 | claude-spec-comments | RUNTIME §3.6/§3.7/§8/§9.3/§10.1/§13.3; PM; CONFIG §4; CA §9.1 | M4,M6,M9 | MED | Config file format. | — | resolved in 6a4dfa28 (declined; review item E6): encodings stay deployment-defined, and BCP l.359 now requires the deployment to document accepted representations, provisioning, validation and when replacement or revocation takes effect |
| SO-04 | claude-spec-comments | RUNTIME §9; CA §1/§6 | M4 | MED | Policy format. | — | resolved in 6a4dfa28 (declined; review item E6): no policy language; BCP l.360 now requires the deployment to document its policy input format and the permissions its bootstrap and system-service integrations need |
| SO-06 | claude-spec-comments | BCP §2; SECURITY §13/§14; CA §10 | M4,M6 | MED | HIGH if the CA gains a human principal. | — | resolved in 6a4dfa28: no human principal in the CA |

## Tier 5 — blocked or later milestones

| ID | Report | Spec §§ | Milestones | Risk | Likely fix, interim choice | Code / test | Status |
|---|---|---|---|---|---|---|---|
| NR-01 | claude-spec-comments-2 | TRANSPORT §3.1 l.422, §8.4; RUNTIME §9.3 | M6, M11, M12 | HIGH | Additive: Y. New provider-initiated or relayed carrier and address kind; reverses "caller opens the connection" for that profile only. Existing tls-tcp code is untouched. | — | resolved in 6a4dfa28 (declined) |
| AP-3 (G26) | claude-spec-comments | RUNTIME l.433 | M6 | LOW | Answered. | — | resolved in 6a4dfa28 |
| AP-6 (G83) | claude-spec-comments | RUNTIME l.35-38 | M6 | LOW | Answered. | — | resolved in 6a4dfa28 |
| C-03 | claude-spec-comments | INTERFACE Abs/§3/§3.8/§3.9 vs BCP §6.1 | M10 | LOW | Wording about conformance classes; decides whether M10 is mandatory. | — | resolved in 6a4dfa28: mapping conformance needs both directions (G139) |
| EC-09 | claude-spec-comments | RUNTIME §9.3 l.2991-3017 | M6 | MED | Error code. | — | resolved in 6a4dfa28 |
| NP-13 | claude-spec-comments-2 | PM §4.5 | M11 | MED | Additive: P. Per-variant provenance. | — | open (not answered) |
| NR-02 | claude-spec-comments-2 | RUNTIME §9.3; CA §3.4 | M6 | LOW | Additive: Y. Pairing bundle plus provisioning method (large, but new). | — | resolved in 6a4dfa28 (declined) |
| NR-03 | claude-spec-comments-2 | RUNTIME §9.3 | M6 | LOW | Additive: Y. Facade set/remove methods. | — | resolved in 6a4dfa28 (declined) |
| NR-05 | claude-spec-comments-2 | RUNTIME §9.3; TRANSPORT §3.2 | M6 | MED | Additive: N. Define "remote runtime disconnect". | — | resolved in 6a4dfa28 |
| NR-07 | claude-spec-comments-2 | TRANSPORT §8.4.1-2 | M6, M11 | LOW | Additive: Y. TCP keepalive / QUIC PING; no envelope change. | — | resolved in 6a4dfa28 (declined; review item E6): no keepalive; facade readiness needs fresh evidence (RUNTIME l.3764-3765) and callers bound calls with a timeout (INTERFACE l.2059) |
| NR-09 | claude-spec-comments-2 | RUNTIME §9.3; TRANSPORT §8.4.1 | M6 | MED | Additive: P. Provider's clock governs expiry, or a relative `expires_in_ms`. | — | resolved in 6a4dfa28 |
| NR-10 | claude-spec-comments-2 | TRANSPORT §8.4.1 | M6 | LOW | Additive: Y. Clarify SPKI pinning, no host-name check, SNI only. | — | resolved in 6a4dfa28 |
| NS-03 | claude-spec-comments-2 | SECURITY §11; BCP §5.4 | M9, M12 | LOW | Additive: Y. Checklist items. | — | resolved in 6a4dfa28 |
| PM-12 | claude-spec-comments | PM §4.5 | M11 | MED | Profile. | — | changed in 6a4dfa28: spec DSSE SLH-DSA profile (G94) |
| PM-13 | claude-spec-comments | PM §4.5/§14 | M11 | MED | Error mapping. | — | changed in 6a4dfa28 (review 2026-11-11, item A5): an absent required provenance locator is `invalid-package`, only retrieval failure is `package-unavailable` (PM l.1487-1488); G113's missing-locator mapping changes; not built (Tier 5) |
| PM-14 | claude-spec-comments | PM §4.5 | M11 | MED | Rule. | — | changed in 6a4dfa28: direct Nix root is `unsupported-source` (G114) |
| RT-01 | claude-spec-comments | RUNTIME Term/§9/§9.3; BCP §2/§5.1/§7 | M6,M9 | **HIGH** | A local activation profile would replace the logosctl design (D13). cl l.441-452 | — | resolved in 6a4dfa28: activation deployment-defined; D13 re-decided 2026-11-10: a persistent logosctl module behind an owner-only socket |
| SO-08 | claude-spec-comments | SECURITY §13 etc. | M9 | LOW | Additive. | — | changed in 6a4dfa28: build mode alone must not enable development trust; D27 re-decided 2026-11-10: a protected-configuration switch |
