# logos-core-nim — Decisions the Logos Core specs do not make

This is the repository copy of the decision record (the planning copy lived outside the repo and is
now frozen). New decisions are added here.

**Spec under implementation:** logos-lips, branch `draft/logos-core-module-specs`, commit `6a4dfa28`
since 2026-11-10 (before that `f4f83471`, 2026-10-03), files `docs/logos-core/raw/spec-*.md`.
Short names used below:

| Short | File |
|---|---|
| TRANSPORT | `spec-module-transport.md` |
| INTERFACE | `spec-module-interface.md` |
| RUNTIME | `spec-module-runtime.md` |
| CONFIG | `spec-module-configuration.md` |
| LOADER | `spec-module-loader.md` |
| PM | `spec-module-package-manager.md` |
| CA | `spec-module-capability-authority.md` |
| SECURITY | `spec-module-security-considerations.md` |
| BCP | `spec-module-system-bcp.md` |
| COMMITMENT | `spec-module-commitment-model.md` |
| HASH | `spec-module-hash-profile.md` |
| cdCDDLe | `spec-cdcddle.md` |

Line numbers (`l.N`) in entries written before 2026-11-10 refer to those files at `f4f83471`. Lines
cited in a *Revised/Settled 2026-11-10 (6a4dfa28)* note, in the 6a4dfa28 section below, in R4 and in
G157 onward refer to `6a4dfa28`, and so do lines cited in a *2026-11-11 (review against 6a4dfa28)* note.

**Date of decisions:** 2026-10-16 to 2026-10-21. **Decided by:** the project owner, from options
prepared after a full read of the twelve specs and a skeptic pass that checked every question against
all twelve documents before it was asked.

## How to read this document

Every entry has:

- **Kind**
  - **SCOPE** — a project-level choice (what to build, where, for which platforms).
  - **GAP** — the specs are silent or ambiguous on something an implementation must decide.
  - **CONTRA** — two specs disagree, or one spec disagrees with itself.
  - **FREE** — the specs explicitly leave the choice to implementations or deployments.
  - **spec-resolved** — the question turned out to be (partly) answered by the spec text; the entry
    records where, so it is not raised as a gap.
- **Specs** — the sections (and lines) the question touches.
- **Description** — what the spec says, and what it leaves open.
- **Options offered** — exactly the choices put to the owner; *(recommended)* marks the one proposed.
  "Other" answers typed by the owner are quoted.
- **Decision** — what was chosen, with any refinement.
- **Status** — `decided`, `OPEN`, or `revised` (with the reason).

GAP and CONTRA entries form the list of questions to take to the spec author; how and when to raise
them is the owner's call. Process rule for the implementation (D9): any new gap found while building
stops that work item until the owner answers; the answer is added here.

## Open items

| ID | Question | Blocks |
|---|---|---|
| G157 | What a line break inside a single-quoted cdCDDLe byte string contributes (TF-11) | nothing: interim reject (`unsupported`), which falls short of cdCDDLe §11 l.621 for this literal (inside the subset, l.127, l.159; review item A28) |
| G158 | The "dedicated common-name projection" INTERFACE §5.2 names but never defines (TL-01) | the generated common section of `logos_types.h` (interim: stem = local name) |
| G159–G164 | Gaps found reviewing RUNTIME, CONFIG and BCP at 6a4dfa28 (TL-02, TF-08, TF-09, TF-10, a TF-06 note, TS-04) | nothing yet: each has a conformant Tier 4 interim; G163 and G164 are settled by spec text (review 2026-11-11, items B10, B11) |
| G165 | An oversized Event from the void `logos_publish_fn`: close the subscriber's connection (TRANSPORT §2.1) or drop it (RUNTIME §7.3) (a TF-06 note, which reads it as close) | nothing: interim (a), close with TRANSPORT_ERROR (owner decision 12, 2026-11-13); built with transported events (I90, 4b-2c, 2026-11-13) |
| G166 | Key rotation: no operation moves an installed package to the new key, so it must be removed and reinstalled or re-released (TF-07) | installation and Runtime handoff (Tier 5) |
| G167 | How an installed package reused as a dependency brings its recorded edges into a new closure; decided (a), fixed exact pins (the Fable 5.2 opinion agrees and names a fourth reading, (d), with other counters); reported as TF-12 in `claude-spec-comments-3.md`, logos-lips `457527eb` | nothing: the resolver follows (a) (I69) |
| G168 | Whether an instance denied execution after `start_module` was accepted stays `unloaded` or enters `error`, and what `start_module` returns; reported in TF-10 | the Capability Authority integration; interim: NOT_AUTHORISED, `unloaded` with `failure = authority-denied` |
| G169 | Which code `establish_route` returns when it returns nothing because an allowed provider is not ready, or because an allowed discovery matches no provider (TF-16) | nothing: interim NOT_READY when the caller holds a route allow for that provider or a `discover` allow for the contract, NOT_AUTHORISED otherwise |
| G170 | The routes of a stopped consumer, `close_route` on a terminal route, and what a denied renewal does to the route (TF-17) | nothing: interim: closed with no failure; reported unchanged; revoked with `authority-denied` |
| G171 | The order of checks for a Runtime Control request, a route call and `materialize_route` (TF-18) | nothing: interim: authorize what needs no payload, validate the payload, authorize the target, check readiness, compare roots |
| G172 | Which status codes provider code may return, and what the ABI caller does with the ones that carry Runtime meanings (TF-19) | nothing: interim: a valid provider status passes through unchanged (INTERFACE l.3180) |
| G173 | When `start_module` and `stop_module` answer, and how a module that stops itself is answered (TF-20) | nothing: interim: start at `ready` or the failure, stop at `unloaded` (or `error` with `cleanup-timeout` at the stop deadline, G61, G180), and `stopping` at once when the caller is the target or has a call in progress in it |
| G174 | The code of an admitted call that the end of its route terminates (TF-23); what the call does is decided, (a) | nothing: interim: the handle's retained termination code, so NOT_AUTHORISED for a revoked route and NOT_READY otherwise |
| G255, G256 | A replayed establish or renew answer for a transported route (NA-04); a transported connection lost with no known cause (TF-15) | nothing: interims the owner decided (decision 12, 2026-11-13): the replay omits `invocation` and the consumer renews; TRANSPORT_ERROR with the route still `ready` (I90) |
| G175 | Whether activating an event subscription needs a `subscribe-event` decision (TF-24); the delivery checks are decided, (a) | nothing: interim: decided at activation and at each delivery; a Runtime Control `subscribe` asks the event's own decision (I86) |
| G176 | Delivery on the publishing thread and one thread at a time per subscription deadlock when two publishers deliver into each other's handlers (TF-21) | nothing: interim: the publisher waits; the wait ends when the awaited subscription is deactivated, with a diagnostic after 2 s |
| G178 | On which thread, and when, a Runtime Control subscription's handler runs (TF-22) | nothing: interim: Runtime-owned event workers, one handler at a time per subscription, in commit order, after the change is exposed; RUNTIME l.1182 knowingly not applied to these events (I86) |
| G180 | Whether the end of a cleanup that its stop deadline overran leaves `error` (RUNTIME l.611 against l.612 and l.3757) (TF-28) | nothing: interim: it stays `error` with `cleanup-timeout`, and a later stop gives `unloaded` |
| G190–G192 | Where bootstrap ends and the codes `logos_runtime_start` returns when it does not; the intent of the bootstrap-realized instance; how a host accepts a Runtime-generated id (TF-25, TF-26, TF-27) | nothing: interims accepted by the owner and built in I81 (`ready`, NOT_AUTHORISED or MODULE_ERROR, CANCELLED first; `requested`; acceptance by choosing the format); G191's second question (orchestration after a restart) and G192's persistence part built in I82 |
| G193 | What a preserved instance is after the Runtime ended without completing shutdown, and whether bringing it back is a retry (TF-29) | nothing: interim `error` with `other`, "the Runtime ended without completing shutdown"; a resumption, not a retry (I82), amended 2026-11-13: an open episode stays charged (G289, I94) |
| G194, G195 | The codes for a `retire_module` target on another Runtime, and for `create_module` when no declaration is selected (TF-30 points 1 and 2) | nothing: interims INVALID_PARAMS without detail, and non-revealing NOT_AUTHORISED (I82) |
| G205–G207 | The Capability Authority's codes and the order of its outcomes; the record of a repeated revoke; which scopes make one `evaluate` (TL-04, extended) | nothing: interims approved with the step 8a plan and built in I84 (the order of `docs/AUTHORITY-POLICY.md`; a second success record; one non-permission scope); amended 2026-11-14 with permissions (I93): `invalid-constraints` produced, permission scopes only beside a start, one rule or grant for the whole request (owner, batch D 17) |
| G217 | Which permission scopes an execution decision must cover (TF-32) | nothing: interim: with a permission profile, the module-execution operation and one permission scope per saved setting; without one, the module-execution operation only (I85, I93) |
| G218 | The state an expired route enters (TL-03) | nothing: interim `revoked` with `authority-expired`; a later `renew_route` is NOT_AUTHORISED (I85) |
| G225 | A Runtime Control subscription the Runtime ends gives its subscriber no signal (TF-35) | nothing: interim: past its queue bound the subscription ends with a diagnostic, `unsubscribe` of it is LOGOS_OK, and observers resynchronize by query (I86) |
| G226 | Which facts of an observation a Runtime Control selector is compared with; a route record always discloses its consumer (TF-34) | nothing: interim: the observation's own subject facts, never a route's consumer; a `providers` selector matches only an observation exposing a provider (I86) |
| G227 | A realization change without a lifecycle transition (TL-08, extended) | nothing: interim: it commits, so the revision advances and a guarded request prepared before it is INVALID_PARAMS (I86) |
| G228 | The code for a `get_execution_summary` or permission-settings target on another Runtime (TF-30 point 1) | nothing: interim INVALID_PARAMS without detail, as G194 (I86) |
| G230 | The `selection` a summary reports for a realization mechanism that is not the Module Loader (TF-36) | nothing: since I89 only the Module Loader instance, which the bootstrap mechanism realizes, reports `implementation-specific` (G57) |
| G249, G251 | A host-side signal to end the process after Loader loss (RUNTIME §13); ordinary routes to the Module Loader (Tier 4b step 4b-1; TF-45 point 4 and TF-37) | nothing: interims the owner approved (batch A, 2026-11-13), built in I89 |
| G268–G270, G275 | What a Module Host's own end, a deadline's end and the loss of a live application do to the instance; a host of the previous run after an unclean end (Tier 4b step 4b-3; TF-29 for G268, TF-28 for G269, TF-40 for G270, TF-39 for G275) | nothing: interims the owner decided (batch C 11-13, 2026-11-14), built in I91 |
| G273, G274 | What decides a Response committed at a hosted endpoint, and when a Runtime order takes effect there; whose roots a hosted provider's call record holds (Tier 4b step 4b-3, K38, K44; TF-50, TF-51 at logos-lips d064b6d8) | nothing: interims (plan R16, the owner's direct layout of 2026-11-14): the host commits and a Runtime order takes effect when the host processes it; the provider host's verified roots, trust stated in CONFORMANCE; built in I91 |
| G289–G291 | Resumption against retry as orchestration sees it, and whether a Runtime start marker is asked for (TF-41, whose suggested resolution asks for one); the authority binding inferred from `list_modules` (under TF-25); an enforcement stop past its deadline as a resumption (TF-41 with TF-28) (Tier 4b step 4b-5) | nothing: G289 the owner's answer (batch B 9), G290 and G291 the owner's (2026-11-13), built in I94 |
| G233 | The code for a configuration state that would not fit the 16 MiB frame (TF-30 point 3) | nothing: interim MODULE_ERROR without detail and no mutation; revisions measured at their 9-byte maximum (I87) |
| G234 | The code when the configuration-state revision cannot advance (TF-30 point 4) | nothing: interim MODULE_ERROR, no mutation and no module behavior; one revision step held back while a promotion is pending (I87) |
| G235 | The `state_revision` of a configuration summary for an instance without a binding (TL-09) | nothing: interim `{state_revision: 0}` with the other fields omitted (I87) |
| G236 | What `apply_configuration`'s `applied_value_revision` names (TL-10) | nothing: interim the attempted record's value revision (I87, step 9b) |
| G237 | The state after an `apply_configuration` deadline passes while the instance is `stopping` (TF-28) | nothing: interim `error` with `configuration-indeterminate` at expiry, then `unloaded`, failure cleared, when the stop completes within its own deadline (I87, step 9b) |
| G305–G307 | A replacement's state: a fresh assignment filled by migration (K31; TF-42 point 1); who authorizes the migration (K32; TF-42 point 2); whether one migration may consume the source (S4b7-1; in no TF item) (Tier 4b step 4b-7) | nothing: the owner's answers (batch F item 21, 2026-11-15), built in I96 |
| G310 | What a complete Logos module system contains, and which deployments BCP §5.1 and §5.4 bind (TF-43; K18, S4b8-1, K50) | nothing: interim TF-43's reading, no complete-system claim without a Package Manager (owner decision 10 (a)); the claim is Tier 5's decision E1, at step 5-13 |
| G81 | What a grant target owned by another Runtime resolves to (NF-06, remarked on C-09, which `6a4dfa28` declined) | Tier 5 step 5-7a's authority part: interim (a) narrowed, the owner's B5 (2026-11-17) |
| G351 | "Package-backed" is not defined, and when the Package Manager handoff is obtained again is not stated (TF-44; K28, K29) | Tier 5 step 5-8 (a D9 stop): interim proposed in the Tier 5 plan §6, owner decision D2 open |
| G354 | A `call` record that cannot be built or stored after the call's outcome (a TF-06 remark) | nothing: interim as built in I85 and I95 |
| G355, G356 | The `failure` and `state` a facade's record reports (NL-07); continuations on a `connect_remote` binding (NR-04); both remarked in `claude-spec-comments-2.md` | Tier 5 step 5-7b: interims the owner decided (B6, B7, 2026-11-17) |
| G116 | Who provides the live-acceptance host and the persistent testnet seeder | the live testnet run |
| G151, G153, G156 | Gaps found while building Tiers 1–3, sent as ND-10, ND-12 and NP-15; not answered in 6a4dfa28, restated in `claude-spec-comments-2.md` | nothing yet: each has an interim choice in one named proc with a test |

IDs in parentheses are where each item was reported: `claude-spec-comments-3.md` at logos-lips `68628d95`
(branch `draft/logos-core-module-specs-discussion`), except TF-12 (G167), added at `457527eb`, and
TF-21 to TF-24 (G174 to G178), added at `a9fe9c66`, TF-25 to TF-27 (G190 to G192), added at
`bf9b325f`, TF-28 (G180), added at `235c22e6`, and TF-29 (G193), TF-30 (G194, G195, G228), TF-32 (G217), TF-34 (G226), TF-35 (G225) and TF-36 (G230), added at `9a8d4c14`, where TL-08 (G227) was extended. That report
names no DECISIONS IDs. TF-30 points 3 and 4 (G233, G234) were added at `9a8d4c14` with the rest of
TF-30; TL-09 (G235) and TL-10 (G236) are in the `68628d95` report. Review items (A3, B1, …) are those of
the 2026-11-11 review of this file against the 6a4dfa28 text.

**The later items (2026-11-17, step 5-0).** TF-37 to TF-49 were added at `8169d766`, TF-50 and TF-51 at
`d064b6d8`, TF-52 at `c11d6765`; the TF-06 editorial remarks grew up to `554694b9`. Every item from TF-37
on, and the TF-06 remarks the table names, are in the comments document only (Fable's; it sends nothing to
the spec owner): "not sent" in a row means not sent to the spec owner. The rows each item carries:

| Item | Rows | K items |
|---|---|---|
| TF-37 | G251 | S4b1-3 |
| TF-38 | G257 | K8 |
| TF-39 | G275 | K33 |
| TF-40 | G270 | K9 |
| TF-41 | G289, G291 (with TF-28) | K34, K46 |
| TF-42 | G305 (point 1), G306 (point 2) | K31, K32 |
| TF-43 | G309 (point 4), G310 (points 1 to 3) | K18, K50, S4b8-1 |
| TF-44 | G351 | K28, K29 |
| TF-45 | G247 (point 1), G253 (point 2), G252 (point 3), G246 and G249 (point 4) | K5, K37, S4b1-4, K4, S4b1-1 |
| TF-46 | G253, G281, G282 | K36, K25, K26 |
| TF-47 | G260 (point 2), G175 (point 1) | K13, K40 |
| TF-48 | I92: a Module Host ended by force, a non-claim in CONFORMANCE | K43 |
| TF-49 | G250 | K35 |
| TF-50 | G273 | K38 |
| TF-51 | G274 | K44 |
| TF-52 | none yet: owner decision B1 (Runtime-owned TLS processes) answers it here; Tier 5 step 5-7a records the row | — |
| TF-06 remarks | G311 (S4b8-2), G312 (K49), G352 (K22), G354 (the call record), G298 (K19) | K19, K22, K49, S4b8-2 |

No longer open at 6a4dfa28: G5 (implementation-defined, PM-01), G49 (answered, CA-03), G93 (answered,
PM-11), G152 (settled as our interim), G154 (settled by INTERFACE §2.3 l.1077), G155 (moot: placement is
not canonical, IF-11). Found settled by spec text on review (2026-11-11): G163 (INTERFACE l.2183), G164
(RUNTIME l.2845-2848).

External dependencies (not spec questions): an org-owned package-signing key (and a provenance key),
an org Apple Developer ID, and the storage mix bootstrap data (mix pool and SPRs) for testnet.

## Spec revision 6a4dfa28 (2026-11-10)

The owner answered `claude-spec-comments.md` and `claude-spec-comments-2.md` and published logos-lips
`6a4dfa28`. The HC- items and the Fable 5.1 items (G151, G153–G156, ND-10..14, NP-15) await a follow-up.
Each row below also carries a *Revised* or *Settled* note. Where the code changed, the note says so.

**Revised 2026-11-11 (review against 6a4dfa28, item B17):** of the Fable 5.1 items only G151, G153 and
G156 (ND-10, ND-12, NP-15) still await a follow-up: G152 and G154 are settled by spec text (ND-11, ND-13)
and G155 is moot (ND-14). Of the HC- items only HC-02, HC-04, HC-07 and HC-10 are open; the text settles
the other nine (`claude-spec-comments-3.md`, Appendix C). The review also moved G113 out of "Settled as we
had chosen" (A5) and added rows it found settled or changed without a note.

| Outcome | Rows |
|---|---|
| Settled as we had chosen | G1, G2, G3, G4, G6, G7, G8, G9, G10, G12, G13, G14, G119, G120, G122, G152 (Tier 1); G29 (its precedence revised, A22), G40, G41, G43, G44, G142 (PM); G46, G48, G54, G56, G57, G60, G81, G115 (Runtime, CA); D17. Found on review 2026-11-11: G18, G19, G20, G23, G24 (RUNTIME l.1912-1918, l.630; B2), G22 (by cause, B3), G26 (B5), G83 (AP-6, to be redone with D13; C2), G117 (uppercase half only, B1), D14 (RUNTIME l.29-30; B7) |
| Settled differently: code changed | G11 (RFC 9682 strings), G38 (floats rejected), G59 (depth counts arrays and maps), G45 (`manifest.json` invalid), G73 (defined values, install-namespace collisions); G25 (null vtable `MODULE_ERROR`; I66 already follows the text; review item A4) |
| Settled differently: Tier 4/5 plans change | G27, G39, G47, G49, G50, G51, G52, G53, G55, G61, G82, G94, G114, G149; G28 (`realization-failed`, A3), G113 (a missing locator is `invalid-package`, A5) |
| Superseded by PM-06 (SLH-DSA-SHA2-192s) | G42, G135, I33; D18 and G137 keep their shape with 48-byte keys; R4 built 2026-11-10 over vendored slhdsa-c (I68); I41's key and signature formats (review item C8) |
| Implementation-defined, to be documented | G5, G90, G91, G93 |
| Re-decided 2026-11-10 | D13 (RT-01), D27 (SO-08); with D13, G76's CLI format and G78, G79, G80, G83, G84, G85, G86, G87 are to be redone (review items C2, C3, A14) |
| Re-decided 2026-11-11 | G52, G53, G55 (for the first Tier 4 slice); after the review, with the Fable 5.2 session's view (owner: "Accept all"): G47, G61, G82, G86, G92, G99, G100, G110, G117 (lowercase half), G137, G140, G143, D18, D27, the section 13 dev-key bullet and I52 (items A6, A7, A9, A10, A12–A18, A21, B1) |
| Revised 2026-11-13 (owner, batch A, Tier 4b step 4b-1) | D27 (the test-hook rule, item 1), G110 (the enforcer is Runtime admission, item 2) |
| Revised 2026-11-14 (owner, batch D, Tier 4b step 4b-4) | G207 (one rule or grant covers a whole request, item 17), G283 (K27: CAP-0075 to CAP-0082 by one inspection item, item 16); G205 amended with it (I93) |
| Re-decided 2026-11-15 (owner, batch F, Tier 4b step 4b-7) | G92 (item 21: a fresh assignment filled by `copy` or `move`, the source retired in the same write, no snapshot for `move`; with F1) |
| Transport, settled as chosen | G30 (plus a silent close on a first ProtocolError), G33, G34, G35, G36, G37 (order restated, no code change) |
| Transport, settled differently: code changed | G31 (late replies validated), G32 (overlap closes, ids stay used); I51–I59 |
| Transport, to decide before Tier 4 | G107 (direction confirmed, more requirements), G165 (new; a TF-06 note); G58 decided 2026-11-10: no same-identity claim, and its socket layout is settled as chosen (RUNTIME l.316-317; review item B6) |
| INTERFACE, settled as chosen | G64, G66, G68, G70, G71 (helper names implementation-defined; our C helpers became `lcn_…`, I73, review item C5), G139 (both mapping directions); G154 by spec text (§2.3 l.1077) |
| INTERFACE, superseded by C mapping revision 3: code changed | G62, G63, G65, G69, G72 (retired), G155 (moot); I18 reversed (ND-08); I23 loses the NX-04 interim; I25, I26, I27 rewritten; I60–I63; G67 (response owners, IF-07), built since by I72 (review item C6) |
| INTERFACE, superseded and not yet built | none since 2026-11-11: G67 was listed here until the review found it built (C6) |

## Contents

1. Scope and process (D1–D31)
2. Commitment model, hash profile, cdCDDLe
3. Interface: schemas, C mapping, code generation
4. Error codes the specs require but do not assign
5. Transport
6. Runtime, lifecycle and system services
7. Capability Authority
8. Configuration
9. Package Manager, packages and distribution
10. logosctl, logosd and the session
11. Payload and dependency modules
12. Platforms, build, CI and tooling
13. Implementation defaults chosen without a separate question
14. Index
15. Revisions and implementation choices since work started (R1–R5, I1–I97)

---

## 1. Scope and process

### D1 — How the payload modules reach the new core
- **Kind:** SCOPE · **Specs:** INTERFACE §2.6 (required exports), RUNTIME §1.2, §2.2 (missing symbol
  fails realization), LOADER §3 (adapter code lives inside the module's own artifact), BCP §3.3, §6.1.
- **Description:** Today's blockchain, storage and delivery modules are Qt plugins exporting a JSON
  dispatch ABI. The specs require each module artifact to export the canonical C ABI derived from its
  CDDL contract, with any language adapter inside the module itself.
- **Options offered:** (a) new spec-native modules wrapping the same libraries *(recommended)*;
  (b) a Qt-plugin adapter hosting today's plugins behind the new runtime; (c) adapter first, then native.
- **Decision:** (a). No Qt in the node. (The skeptic pass later confirmed (b) is not conformant: a
  loader-side translator over artifacts lacking the mandatory symbols would be a fourth realization
  strategy, which LOADER §3 does not allow.)

### D2 — Shape of the CLI
- **Kind:** SCOPE · **Specs:** BCP §7 (host-shell applications, informative); none define a CLI.
- **Description:** The run-a-node guide (Testnet v0.3) uses `logosctl` 0.3.2 commands. The specs define
  no CLI; a CLI participates as an ordinary module instance (BCP §2).
- **Options offered:** (a) same commands and output as the guide *(recommended)*; (b) a spec-shaped CLI
  mirroring Runtime Control / Package Manager operations, with the guide rewritten; (c) both.
- **Decision:** (b) spec-shaped; the docs.logos.co guide is rewritten.

### D3 — Where the implementation lives
- **Kind:** SCOPE · **Specs:** none.
- **Options offered (location):** (a) new repo in logos-workspace *(recommended)*; (b) evolve
  logos-core-poc2; (c) fresh repo seeded from poc2. **Decision:** (a), later changed (see G131).
- **Options offered (name):** `logos-co/logos-core-nim`; `logos-co/logos-core`; `dlipicar/logos-core-nim`
  first. **Decision:** `dlipicar/logos-core-nim`, transferred to logos-co later.
- **Options offered (visibility):** public; private. **Decision:** public.
- **Status:** revised 2026-10-21 — independent repo, not part of logos-workspace (G131). poc2 is
  reference material only.

### D4 — Where the payload modules' code lives
- **Kind:** SCOPE · **Specs:** BCP §3.3, §6.1 ("The underlying library can retain its own public API and
  internal types behind that adapter").
- **Options offered (first round):** (a) existing module repos, new major *(recommended)*; (b) new repos;
  (c) inside the core repo first. The owner answered: "can we build the modules in the main library
  repos? that is, the big libraries each of the module repos consume, on a branch".
- **Options offered (second round):** (a) yes, all three — branches in logos-storage-nim and
  logos-delivery, blockchain via a fork *(recommended)*; (b) Nim libraries only; (c) inside
  logos-core-nim first.
- **Decision:** (a). Repos: `logos-storage/logos-storage-nim`, `logos-messaging/logos-delivery`
  (signed commits required), fork `dlipicar/logos-blockchain` (no push access upstream). Dependency
  modules follow G101/G102.

### D5 — Platforms
- **Kind:** SCOPE · **Specs:** RUNTIME §2.1, §2.3, §5.2; TRANSPORT §8.2; SECURITY §11.
- **Options offered (multi-select):** Linux x86_64; macOS arm64; Linux aarch64; Windows x86_64. The owner
  selected all four and added: "Plus Android and iOS (we may not have logosctl there, but we'll want to
  be able to run the runtime and the modules)". Follow-up from the owner: "leave blockchain out for
  platforms other than macOS/linux".
- **Decision:** node + logosctl/logosd on Linux x86_64/aarch64, macOS arm64, Windows x86_64; runtime +
  modules on Android and iOS. blockchain on Linux and macOS only (libp2p/rln/lez_rln too, G103);
  Windows/Android/iOS run storage + delivery.

### D6 — Tracking the moving spec branch
- **Kind:** SCOPE · **Specs:** all (the branch has had five revisions since August).
- **Options offered:** (a) pin `f4f83471` and bump deliberately *(recommended)*; (b) follow the branch
  head. **Decision:** (b). Automation: G127.

### D7 — Where our own test vectors live
- **Kind:** SCOPE · **Specs:** cdCDDLe §12; most specs ship no vectors (see §2 below).
- **Options offered:** (a) our repo, offered upstream later *(recommended)*; (b) upstream as we go;
  (c) our repo only. **Decision:** (a), marked non-normative.

### D8 — Binary name and coexistence with logosctl 0.3.x
- **Kind:** SCOPE · **Specs:** none.
- **Options offered:** (a) `logosctl`, new major, separate session dir *(recommended)*; (b) a different
  name for now. **Decision:** (a); refined by G88 (Docker-style split: `logosctl` + `logosd`).

### D9 — What the implementation does when it meets a spec gap
- **Kind:** SCOPE · **Specs:** all.
- **Options offered:** (a) decide the narrowest option, log it, file upstream *(recommended)*; (b) stop
  and ask the owner each time; (c) propose spec PRs ourselves.
- **Decision:** (b). Every gap blocks its work item until answered; answers are added here.
- **Related process question — when to settle the ~45 interpretation questions found while planning:**
  (a) at the start of each milestone *(recommended)*; (b) now, in batches; (c) when each one is hit.
  **Decision:** (b) — they are all answered in sections 2-12.

### D10 — Language of the blockchain module
- **Kind:** SCOPE · **Specs:** INTERFACE §2 (C ABI); BCP §6.1.
- **Options offered:** (a) Nim over the Rust library's C FFI *(recommended)*; (b) Rust, exporting the C
  ABI directly. **Decision:** (b). Consequence: the code generator, kits and the conformance harness must
  be language-neutral (they test built artifacts).

### D11 — Where modules run on desktop
- **Kind:** SCOPE/FREE · **Specs:** RUNTIME §2, §4.2 (placement is policy), §5.1, §5.3 ("In-process
  placement is a trust and containment decision"); LOADER §4; BCP §5.3.
- **Options offered:** (a) one process per module *(recommended)*; (b) single process everywhere;
  (c) configurable, default in-process. Owner's answer: "Configurable, default one process per module".
- **Decision:** configurable per module, default one hosted process per module; mobile always
  single-process direct_static.

### D12 — CI
- **Kind:** SCOPE · **Options offered:** (a) GitHub-hosted, all 6 platforms *(recommended)*; (b) desktop in
  CI, mobile manual; (c) self-hosted runners. **Decision:** (a). Cache: G132.
- **Revised 2026-11-09 (R1):** legs narrowed to Linux x86_64, Linux aarch64 and macOS arm64 until Tier 4 work starts.
- **Revised 2026-11-16 (R6):** Linux x86_64, Linux aarch64 and macOS arm64 in the `nix` and `nimble` jobs, and Windows x86_64 in the `windows` job, on the Nimble path (G334). Android and iOS join with M12.

### D13 — How a shell `logosctl` reaches the daemon
- **Kind:** GAP · **Specs:** RUNTIME Terminology ("Every consumer is a module instance"), §9 l.1465
  ("Runtime MUST accept a Runtime Control invocation only from an authenticated module instance"),
  §9 l.1603-1636 (remote forwarding, Hello token), §9.3 l.1825 (remote listeners are tls-tcp or quic
  only); BCP §2 (a CLI participates as a module instance), §5.1 (every local module is realized by the
  Loader), §7 (informative "protected deployment activation"); TRANSPORT §3.1, §8.4.
- **Description:** The specs define no local channel through which an outside process (a shell command)
  becomes an authenticated Runtime Control consumer. The only fully specified path for another process
  is remote Runtime Control over `logos.remote.tls-tcp` with enrollment. An out-of-model admin socket
  that bypasses Runtime Control would violate RUNTIME l.215 and l.1465.
- **Options offered:** (a) a persistent consumer-only `logosctl` module inside the daemon, reached over an
  implementation-local owner-only socket documented as the BCP §7 activation/presentation hop
  *(recommended)*; (b) a per-invocation module instance activated through that socket; (c) logosctl
  embeds a minimal source Runtime and uses remote Runtime Control over loopback mTLS with enrollment
  (fully spec-defined; TLS 1.3 and certificate provisioning on the critical path).
- **Decision:** (c) loopback mTLS remote Runtime Control. Follow-ups: G78–G87.
- **Revised 2026-11-10 (6a4dfa28):** RT-01 answered: activation is deployment-defined (RUNTIME l.1606-1607, BCP l.384-390, BCP §7 l.485-532), and host-shell activation of logosctl as an admitted local module is what the spec now describes. (c) is not forbidden, but retained intent origins block `retire_module` (RUNTIME l.3556-3595, l.3632-3634), which favours a persistent logosctl instance. **Status:** to be re-decided before Tier 4b.
- **Re-decided 2026-11-10 (owner: "proceed with your recommendations"):** (a). A persistent, consumer-only `logosctl` module instance inside the daemon, admitted through the Loader like any local module; a shell `logosctl` reaches it over an implementation-local, owner-only socket that is the deployment-defined activation and presentation hop (RUNTIME l.1606-1607, BCP §7). One persistent instance keeps the retained intent origins `retire_module` needs (RUNTIME l.3556-3595). The socket carries presentation only: every operation is that module's Runtime Control call under its own authorization. (c) is dropped; G78–G87 rows that assume loopback mTLS are to be redone with Tier 4b.
- **Revised 2026-11-11 (review against 6a4dfa28, item D4):** the `retire_module` reason in the two notes above is misplaced. RUNTIME l.3568-3569 make a retained `requested` intent a live dependency only when the Runtime performing retirement owns it and its authenticated origin is the retirement target, and l.3571 needs no discovery of intents owned by other Runtimes. That rule bites option (b) (a per-invocation instance inside the daemon), not (c), whose CLI instance lived in another Runtime. What favours one stable origin is l.3539-3542: recovery preserves the intent's origin and rechecks its execution authority across connection loss and restart. The decision (a) is unaffected. D15, section 10 and G76 still describe (c) (review items C1-C3).
- **Built 2026-11-15 (I95, part 4b-6b):** (a), as G296: the `logosctl` instance in logosd and the
  owner-only socket, with D13(a)'s four conditions (DAEMON.md §7).

### D14 — Module Loader construction
- **Kind:** CONTRA/FREE (settled by RUNTIME l.29-30 at 6a4dfa28) · **Specs:** BCP §5.1 (bootstrap Loader, then orchestration, then every module
  via the Loader); LOADER §3 (`direct_static`), §5 (handoffs); RUNTIME §13.3 (static registration).
- **Description:** Private handoffs (file descriptors, process-local bindings) cannot travel over the
  Loader's CBOR contract, which conflicts with Runtime and Loader being allowed in different processes.
- **Options offered:** (a) Loader statically linked in the daemon, registered via the Host Embedding API,
  private handoffs through an in-process side table *(recommended)*; (b) out-of-process Loader with an
  SCM_RIGHTS side channel; (c) no Loader at first (Runtime-only claim).
- **Decision:** (a). Loader failure follows the spec path (G56).
- **Settled 2026-11-11 (review against 6a4dfa28, item B7):** RUNTIME l.28-30: Runtime and Loader "need not share a process or binary", and "The composition also supplies the private realization handoffs required by LOGOS-MODULE-LOADER through implementation-defined mechanisms". Settled as (a) chose: the in-process side table is such a mechanism. What remains is the remark on C-10 in `claude-spec-comments.md` (logos-lips `68628d95`): `realize_request` has no field for the provider endpoint Runtime hands over (LOADER l.318-321, l.340-345).
- **Built 2026-11-13 (I89, part 4b-1b):** the side table, `runtime/sidetable.nim`: inbound per
  instance, outbound per realization id, one lock, owned by the engine handle.

### D15 — Where authority policy lives
- **Kind:** FREE · **Specs:** RUNTIME §9 l.1490-1521 (default-deny policy mandatory; internal policy
  allowed "for local trusted deployments"), CA §1, §12; BCP §5.3 (call evidence mandatory for every
  Runtime).
- **Options offered:** (a) internal policy emitting CA-shaped records, CA module later *(recommended)*;
  (b) `logos_capability_authority` module from the start; (c) internal only.
- **Decision:** (b) in the node daemon. The CLI's embedded Runtime uses internal policy (G78).
- **Revised 2026-11-11 (review against 6a4dfa28, item C1):** the last sentence has no subject any more. D13's re-decision (a) dropped the CLI's embedded Runtime: there is one Runtime, the daemon's, and logosctl is a module instance in it under the daemon's Capability Authority. G78 goes with the section 10 redo.
- **Note 2026-11-15 (I95):** under logosd the `authority` instance is logosd's own, its policy the
  operator's rules merged with the system rules (G295). The "CLI's embedded Runtime" above has no
  referent.

### D16 — Optional profiles in scope
- **Kind:** SCOPE · **Specs:** BCP §5.3 (profile matrix).
- **Options offered (multi-select; all mandatory pieces incl. tls-tcp are in scope regardless):** QUIC
  remote transport; Nix package profile; SLSA provenance; sandbox/container placements.
- **Decision:** QUIC, Nix, SLSA. Not sandbox/container placements.

### D17 — Origin of packages and the catalog
- **Kind:** GAP/SCOPE · **Specs:** PM §5 (closed `package_source`: `{kind:"lgx", storage, object,
  ?provenance_object}` or `{kind:"nix", flake_ref, …}`), §6 l.786 ("An LGX source's `storage` and
  `object` fields identify the Storage object containing the package archive"), §4.5 l.583, §7 l.808
  (unknown kind = `unsupported-source`), §13 (Storage distribution role; PM "MAY retrieve package
  catalogs … from Logos Storage"); RUNTIME §3.6 step 2 and SECURITY §3.1 l.142 (protected bootstrap
  input may supply accepted digests); BCP §5.5 (a backend name cannot define a profile).
- **Description:** A spec LGX source can only name a Logos Storage object; there is no URL or file kind,
  and the storage module must be installed before anything can be fetched. No catalog document, origin
  or refresh is defined.
- **Options offered (first):** (a) bundle storage, fetch the rest via Storage *(recommended)*; (b) the same
  plus a dev-only file source; (c) propose URL/file kinds upstream. The owner asked for the spec text,
  then added: catalog and packages must share one origin.
- **Options offered (second):** (a) Logos Storage for both *(recommended)*; (b) Storage plus a mechanism
  to learn the latest catalog CID (not in the specs); (c) a URL kind for both (spec extension).
- **Decision:** (a). storage_module and the system services ship with logosd as protected bootstrap
  input; the catalog is a Storage object whose locator is in the daemon config (G90). The meaning of
  `storage`/`object` is open (G5).
- **Settled 2026-11-10 (6a4dfa28):** PM-02: the first Storage and PM providers come from protected deployment input, with no source or installed record (PM §13 l.1440-1442). Matches.
- **Revised 2026-11-11 (review against 6a4dfa28, item B8):** the §6 sentence quoted under Specs is gone, and "the meaning of `storage`/`object` is open (G5)" no longer holds. PM l.856-859: `storage` identifies a deployment-configured binding to a Logos Storage provider and `object` the archive within it; both are opaque byte locators whose retrieval API and encoding are implementation-defined and documented. PM l.836: catalog format, acquisition and refresh are implementation-defined and documented. G5 is closed; (a) stands with documented locators (G90, G91).

### D18 — Who signs packages
- **Kind:** FREE · **Specs:** PM §2, §4, §4.1 l.440-441 (a local development deployment MAY configure its
  own anchor through the same protected trust-input path), §4.3 (mandatory COSE_Sign1 Ed25519 profile);
  SECURITY §13 (no unsigned compatibility path); BCP §5.2-§5.3.
- **Description:** Today's `.lgx` packages (manifest.json, did:jwk signature, SHA-256 root hash) cannot
  pass spec verification, and there is no unsigned or legacy import path.
- **Options offered:** (a) dev anchor now, org key later *(recommended)*; (b) org key before testnet.
- **Decision:** (b). A dev anchor is used only for CI and local work. Provisioning: G137.
- **Revised 2026-11-10 (6a4dfa28):** PM-06: package signatures are SLH-DSA-SHA2-192s with 48-byte public keys (PM §4.3 l.483-573). The org and dev anchors keep their roles; the key type changes with R4.
- **Revised 2026-11-11 (review against 6a4dfa28, item A13):** whether the dev key may be a shared, published key: see D27 (PM l.546; SECURITY l.534). **Needs an owner decision** (review item A13).
- **Re-decided 2026-11-11 (owner: "Accept all", after the Fable 5.2 session's review of the recommendations, item A13):** no shared or published dev key. Dev keys are generated
  locally per developer and per CI job; see D27.

### D19 — Getting runtime and modules onto Android/iOS
- **Kind:** FREE · **Specs:** RUNTIME §2.3, §5.2; SECURITY §11.4, §11.5.
- **Options offered:** (a) bundled at app build *(recommended)*; (b) Package Manager installs on Android
  too. **Decision:** (a); the PM installs no executable code on mobile.

### D20 — Payload contracts
- **Kind:** FREE · **Specs:** INTERFACE §1.1-§1.7 (snake_case, map/choice bodies, no `any`, floats,
  unkeyed maps or bare int/uint), §4.6 (domain failures in the response schema); INTERFACE §1.8 says the
  storage example is "illustrative only".
- **Description:** No spec defines the blockchain, storage or delivery contracts; their content is ours.
- **Options offered:** (a) the node-flow subset with JSON carried in tstr fields *(recommended)*; (b) the
  full surface with JSON in tstr; (c) the full surface, fully typed.
- **Decision:** (c), including today's lifecycle/config methods (G97).

### D21 — How payload modules get their configuration
- **Kind:** FREE · **Specs:** CONFIG §1 (no credentials, trust input, permissions or grants in
  configuration), §2-§8; RUNTIME §9 l.2269-2274 (Runtime must implement all five configuration
  operations regardless).
- **Options offered:** (a) Core configuration from the start *(recommended)*; (b) methods first, Core
  configuration later; (c) methods only.
- **Decision:** (a). Secrets live in state_dir; no configuration-file path crosses the boundary.

### D22 — How storage gets started
- **Kind:** FREE · **Specs:** RUNTIME §3.7 (no startup from dependency edges; lifecycle-ordering
  constraints come only from host/deployment), l.187 (orchestration applies startup defaults only while
  intent is `uninitialized`); PM Scope (no optional dependencies).
- **Description:** Today storage is auto-started by package_downloader through an optional dependency;
  the specs forbid dependency-driven startup and have no downloader role.
- **Options offered:** (a) orchestration startup default with an ordering constraint, no
  package_downloader *(recommended)*; (b) keep a downloader module calling `start_module`.
- **Decision:** (a).

### D23 — Acceptance criterion
- **Kind:** SCOPE · **Options offered:** (a) offline CI plus one gated live run *(recommended)*; (b) live
  testnet required; (c) offline only. **Decision:** (b), with offline CI e2e as well; the live run happens
  only after the owner's go-ahead at the time.

### D24 — Restarts and failures
- **Kind:** FREE · **Specs:** RUNTIME §9.3 l.3036-3076 (execution intent and revisions persist; recovery
  preserves origin and package selection), §10.1 (restart policy may be disabled; if enabled it must be
  bounded; retry accounting must survive orchestration restart), §10.2.
- **Options offered:** (a) persist and resume, no auto-restart *(recommended)*; (b) plus bounded backoff.
- **Decision:** (b). Retry accounting is persisted (required by RUNTIME §10.1 l.3214 once a policy is on).
- **Built 2026-11-12 (I82), the engine half only (owner's U1 for step 6):** retained intent, its origin
  and revision persist, an unclean end is visible as `error` (G193), and recovery goes through
  `recover_module` (RUNTIME l.3786); the engine restarts nothing on its own. The restart policy and its
  retry accounting are the orchestration module's (l.3786-3788; l.3214 once a policy is on): RUN-0684,
  RUN-0685, RUN-0686, RUN-0687 (its orchestration half), RUN-1063, RUN-1065, RUN-0696 and RUN-0025 are
  deferred as requirements on the orchestration module, Tier 4b.
- **Built 2026-11-13 (I94, part 4b-5b):** the orchestration half: the reference orchestration module holds the
  restart policy and its retry accounting (RUNTIME l.3786-3789; the citation l.3214 above is l.3789 at
  6a4dfa28). RUN-0684 to RUN-0687, RUN-1063, RUN-1065 and RUN-0025 are claimed; RUN-0696 is claimed
  with part 4b-5c (2026-11-14), once the module takes the permission settings event as a hint.

### D25 — Module permissions
- **Kind:** FREE (with a CA §3.5 reading) · **Specs:** CA §3.5 ("a profile that permits operating-system
  or platform access MUST define permission names and constraints for every facility it exposes");
  BCP §5.4; RUNTIME l.2240 (omitted permissions are denied).
- **Options offered:** (a) one coarse ambient permission *(recommended)*; (b) zero permissions; (c)
  fine-grained net/fs permissions failing closed where unenforceable.
- **Decision:** (a). Identifier and constraints: G110.
- **Built 2026-11-14 (I93, parts 4b-4a and 4b-4b):** the profile `logos-core-nim.permission-profile.v1`
  (G279) with host-ambient alone, standing for every facility class (G283); `docs/PERMISSIONS.md`.

### D26 — `logosctl call` arguments
- **Kind:** FREE · **Specs:** INTERFACE §1.3 (snake_case), §1.4, §2.1 l.677-682 (canonical field order;
  "source declaration order is not ABI-visible"), §3.8 l.1892 (declaration order may differ for the same
  commitment), §4.5; COMMITMENT §7 (scalars typed by schema; no floats).
- **Options offered:** (a) named only (key=value, --json), typed from the schema *(recommended)*;
  (b) positional in canonical order plus named; (c) positional in declaration order plus named.
- **Decision:** (a). No camelCase aliases; `@file` supplies tstr/bstr content.

### D27 — Development vs production
- **Kind:** GAP · **Specs:** SECURITY §13 (development features explicitly non-production; no mechanism);
  PM §4.1 (dev anchor through the same path); INTERFACE l.2300 (debug and release builds emit identical
  bytes); TRANSPORT §8.5, BCP §5.5 (test hooks).
- **Options offered:** (a) runtime switch plus compiled-out test hooks; testnet = production
  *(recommended)*; (b) the same with testnet = development; (c) compile-time only.
- **Decision:** (c) separate dev and release builds; verification code identical.
- **Revised 2026-11-10 (6a4dfa28):** SO-08: "Build mode alone MUST NOT enable development trust or exemptions" (BCP l.398-401). (c) alone no longer conforms: a development deployment also needs explicit protected configuration. **Status:** to be re-decided ((a) or (b)) before Tier 4b.
- **Re-decided 2026-11-10 (owner: "proceed with your recommendations"):** (a). One build serves development and production: development trust (the published dev anchor) and every exemption is enabled only by an explicit switch in the daemon's protected configuration, never by the build mode (BCP l.400). Test hooks are compiled out of release builds, and in debug builds they still need that switch. Testnet deployments run with the switch off: testnet = production.
- **Revised 2026-11-11 (review against 6a4dfa28, items A12, A13):** three points the re-decision leaves out. (1) BCP l.399: a deployment enabling a non-production mechanism MUST identify itself as non-production in its documentation and operator-facing diagnostics, so the switch must also make logosd say so. (2) G137 and section 13 still say release builds refuse the published dev key, which conflicts with "one build serves development and production" (see G137). (3) "The published dev anchor": an anchor is a public key, but if the dev key's private half is published (shared in the repository or CI so that anyone can sign dev packages), that conflicts with PM l.546 (package producers MUST protect signing keys against disclosure and unauthorized signing) and BCP l.401 (a non-production designation MUST NOT waive requirements); SECURITY l.534 describes development trust as "a locally generated package-signing trust anchor". The alternatives are a locally generated dev key per developer and per CI job, or a recorded deliberate departure. **Needs an owner decision** (review items A12, A13).
- **Re-decided 2026-11-11 (owner: "Accept all", after the Fable 5.2 session's review of the recommendations, items A12, A13):** (a) stands, completed:
  - A release binary accepts the dev anchor only while the protected switch is on, and the deployment
    then identifies itself as non-production in its documentation and operator-facing diagnostics
    (BCP l.399), so logosd says so.
  - The switch, or a per-entry development marker, lives in the revisioned trust file (G137).
  - Dev keys are generated locally per developer and per CI job; no dev private key is shared or
    published (PM l.546; SECURITY l.534; BCP l.401). A published private key appears only in test
    vectors that never enter a deployment trust input.
  - The specs do not define what makes an anchor "development" (in the TF-06 list,
    `claude-spec-comments-3.md`, logos-lips `d77cfa41`), so our marker is our own criterion and is
    documented as such.
- **Revised 2026-11-13 (owner, batch A item 1):** the test-hook rule, which replaces "compiled out of
  release builds" with "compiled only into test builds" (step 4b-1, I89; CONFORMANCE "Test hooks"):
  - Hook code under `src/` exists only inside `when defined(lcnTestHooks)`.
  - Only test builds set the define (`tests/config.nims`, for nimble and the flake's test derivations
    alike); no flake package or app, nimble `bin` or `build_*` task does, and a test-built library sets
    it only if it holds hooks.
  - Each module that holds hooks puts the marker `LCN_TEST_HOOKS_BUILD` in the binary under the
    define. The flake check `no-test-hooks` searches every deployment package and app of the system
    for it, and requires it in a probe built with the define, so the search is not vacuous.
  - A hook stays inert until protected input selects it: the second sentence of the re-decision
    (a) stands. In an in-process suite the test, which is that Runtime's host, selects it; under
    logosd (4b-6) it is the trust-file switch the daemon hands down, never an environment variable or
    a peer's message (BCP l.398, l.400; SECURITY l.532).
  - `host.setPolicyForTests`, which every build had, moves under the define.
- **Built 2026-11-15 (I95, parts 4b-6a and 4b-6b):** the switch is in the trust file (G299); it gates
  allow-all and `test_hooks`; logosd selects hooks by in-process calls after reading it, and says
  NON-PRODUCTION in its log and in every `logosctl` output (G300).

### D28 — TLS and QUIC stack
- **Kind:** FREE · **Specs:** TRANSPORT §8.4.1 (TLS 1.3 only, mutual TLS, RFC 9266 tls-exporter, no
  resumption or 0-RTT), §8.4.2 (QUIC v1, ALPN `logos.remote.quic`).
- **Description:** chronos' built-in TLS is BearSSL, which lacks TLS 1.3.
- **Options offered:** (a) BoringSSL + lsquic, as nim-libp2p and delivery use *(recommended)*;
  (b) OpenSSL 3.5 for both; (c) OpenSSL 3 + ngtcp2.
- **Decision:** (a), statically linked with hidden symbols.
- **Revised 2026-11-10 (6a4dfa28):** BoringSSL (nim-boringssl 0.0.14) implements only SLH-DSA-SHA2-128s and SHAKE-256f, and its SHA2 path is SHA-256 only, so it cannot provide the SLH-DSA-SHA2-192s PM-06 requires. BoringSSL stays the TLS stack; the signature implementation is R4.

### D29 — Code generator outputs
- **Kind:** FREE · **Specs:** BCP §6.1 ("Code generation is an implementation technique rather than a
  conformance requirement"); INTERFACE §2 (canonical C ABI), App A (informative).
- **Options offered:** (a) C header + Nim + Rust from one generator *(recommended)*; (b) C header + Nim,
  Rust by hand. **Decision:** (a), plus configuration init glue (CONFIG §6 requires it of init code).
- **Status (2026-11-17, step 5-0):** the C header and Nim outputs are built (`lcn-gen`); no Rust output
  is built, and none is planned in Tier 5 or the node track: the Tier 5 plan's A4 (a) ports the
  blockchain module as a Nim kit module over its C binding, and rln and lez_rln are decided once their
  repository is in the workspace. The repository split (owner, 2026-11-16) gives a Rust SDK a
  repository of its own; the Rust output is that repository's.

### D30 — C->CDDL reverse mapper
- See **G139**. **Decision:** (a), implement it and claim it.
- **Status (2026-11-18, step 5-1c):** implemented and claimed (I98): `lcn-gen cddl`, with INTERFACE §3
  claimed in both directions. G158's interim is the limit of the common names (TL-01).

### D31 — Build system
- **Kind:** FREE · **Specs:** none.
- **Options offered:** (a) nimble + Nix flake *(recommended)*; (b) Nix only; (c) nimble only. The owner
  asked what is lost against Nix-only and whether builds stay reproducible; after the explanation
  (Nix builds stay reproducible when derived from nimble.lock; plain nimble builds pin Nim sources but
  not the C toolchain; nimble.lock and generated Nix deps can drift; iOS needs the host Xcode SDK either
  way) the follow-up offered (a) nimble + Nix *(recommended)* or (b) Nix only.
- **Decision:** (b) Nix only. Windows via the logos-nix cross overlay (llvm-mingw evaluated, G126),
  Android via the nixpkgs NDK, iOS via the host Xcode SDK (the one impure input).

---
- **Revised 2026-11-09 (R2):** Nimble declares the Nim dependencies and Nix builds from the same lock; both `nimble test` and `nix flake check` must work.

## 2. Commitment model, hash profile, cdCDDLe

Background: these three specs decide every schema root and value root that travels on the wire
(TRANSPORT §4.1 requires each Request, response-ok and Event to carry `{schema_subtree_root,
value_root}`, recomputed and compared by the receiver). The only byte-level vectors the specs ship are
HASH App A (one schema root), HASH App B.1-B.3 (layout digests over synthetic identities), cdCDDLe App A
(one 522-byte canonical document), the COMMITMENT §5 registry of 10 pinned roots, INTERFACE §3.9.2 and
the two PM manifest roots. COMMITMENT App A/B are structural and use placeholder identities. No vector
exercises identity assignment through references, aliases or leaf-bodied declarations. A wrong reading
below would not break our own consistency, only interoperability with another implementation.

**Revised 2026-11-11 (review against 6a4dfa28, item D5):** the vector statement no longer holds. HASH
App B.4 (l.1442-1476) exercises a local alias chain, an import and leaf-bodied declarations
(`a.alias = a.import`, `a.import = types.alias`, `types.count = uint64`), with every schema identity
computed from the documents (l.1476), and HASH §9 l.1265 requires every Appendix B digest; COMMITMENT
App B.1 adds a normative chain vector (G1). G17 and D7 cite the old statement; their decisions stand.

### G1 — Value identity under alias chains
- **Kind:** GAP · **Specs:** COMMITMENT §8 (value tree, local references), §9.2; HASH §7.3 (a child
  record's identity must equal field 2 of the child payload).
- **Description:** COMMITMENT §8 gives a one-hop rule: a local reference never inlines its target and
  adds no node; the containing node keeps the referring location's identity and the child carries the
  referenced declaration's identity. It never addresses chains such as `a.x = a.y` with `a.y = tstr`.
- **Options offered:** (a) the innermost declaration `a.y` — the one-hop rule applied at each step
  *(recommended)*; (b) the outermost declaration `a.x` (what poc2 does); (c) ask the spec author.
- **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** CM-01: local-reference chains create no intermediate node; the child uses the terminal declaration (COMMITMENT §8, normative chain vector in App B.1). Matches (a); the B.1 vector passes.

### G2 — Schema root of payloads below an imported reference
- **Kind:** GAP · **Specs:** COMMITMENT §8, §9.3; HASH §5 ("needed to interpret the node"), §7.4
  (reference-value payload `{0:"reference-value", 1:schema-root, 2:referring location, 3:referenced
  root, 4:referenced subtree root, 5:child}`; every payload's field 1 is a schema root).
- **Description:** For payloads beneath a reference-value node, the specs do not say whether field 1 is
  the outer value's root or the referenced schema's root. This affects every value containing
  `logos.schema_commitment`, `logos.error_detail` or any Runtime Control record.
- **Options offered:** (a) the referenced schema root *(recommended)*; (b) the outer value's root (poc2);
  (c) ask the spec author.
- **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** CM-02: imported descendants use the referenced document's root (COMMITMENT §8, HASH §8, App B.4 positive and negative vectors). Matches; the B.4 vectors pass.
- **Revised 2026-11-11 (review against 6a4dfa28, item D3):** citation: the rule is HASH §7.4 l.707-712 (field 1 of every value payload is the root of the document that defines field 2's identity; a reference-value child and its descendants use the referenced document's root); HASH §8 l.1239-1242 only has the verifier check it. Decision unchanged.

### G3 — Unqualified common names
- **Kind:** CONTRA · **Specs:** COMMITMENT §5 l.697-698 (unqualified common names are "interpreted as
  names in that namespace") vs INTERFACE §1.1, §5.3 and BCP §6.1 l.388-390 (interoperability requires
  complete documents with explicit qualified names).
- **Description:** Whether a module schema may write `error_code` to mean `logos.error_code`.
- **Options offered:** (a) reject, raise upstream *(recommended)*; (b) accept per COMMITMENT §5;
  (c) ask the spec author.
- **Decision:** (a). Only `logos.`-qualified common names are accepted.
- **Settled 2026-11-10 (6a4dfa28):** C-01: fixed in COMMITMENT §5 (imported definitions and prelude). Matches (a).

### G4 — Declarations nested deeper than the namespace
- **Kind:** GAP · **Specs:** COMMITMENT §3.1 step 2 (the namespace must be a proper prefix of every name;
  nothing forbids extra segments) vs INTERFACE §2 l.537 (every accepted schema set MUST be representable
  in both forms) and §3.8 (CDDL -> C -> CDDL MUST reproduce the same model).
- **Description:** `storage.sub.thing` next to `storage.x` projects to `logos_storage_sub_thing_t`, which
  maps back to `storage.sub_thing`; a bare method name `sub.read` would contain a dot.
- **Options offered:** (a) reject *(recommended)*; (b) accept; (c) ask the spec author.
- **Decision:** (a), derived from the §3.8 round-trip requirement.
- **Settled 2026-11-10 (6a4dfa28):** C-02: a declaration is one identifier segment below its schema namespace (COMMITMENT §3.1); dotted namespaces stay valid. Matches.

### G6 — Referencing a common callable declaration
- **Kind:** GAP · **Specs:** INTERFACE §1.1, §1.7 (imply types only); COMMITMENT §5 (silent).
- **Description:** Whether a schema node may reference `logos.schema_request` / `logos.schema_response`
  (callables) or only common named types.
- **Options offered:** (a) named types only *(recommended)*; (b) callables too; (c) ask the spec author.
- **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** CM-03: imported references target named type declarations, which excludes `logos.schema_request` and `logos.schema_response` (COMMITMENT §5). Matches.

### G7 — What a verified-view path ending in a field or tuple position discloses
- **Kind:** GAP · **Specs:** COMMITMENT §9.4 (semantic paths); HASH §8 (verified views), App B.1 (list
  elements disclose the inner value); an empty path discloses the whole value.
- **Options offered:** (a) the inner value node, as for list elements *(recommended)*; (b) the wrapper
  node (label + child record); (c) ask the spec author.
- **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** CM-04: a path ending at a present field, list element or tuple position discloses the contained normalized value (HASH §8). Matches.

### G8 — Choice-arm segment when crossing a choice
- **Kind:** GAP · **Specs:** COMMITMENT §9.4 (defines `choice-arm-segment`; never states it is required).
- **Options offered:** (a) required *(recommended)*; (b) optional (implied by the value).
- **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** CM-05: continuing through a choice needs a `choice-arm` segment; a path may end at the choice (COMMITMENT §9.4). Matches.

### G9 — Literal outcomes in the choice selection plan
- **Kind:** GAP · **Specs:** COMMITMENT §3.1 (choice selection plan; the normative plan table l.490-503
  now names a "map-field-literal test").
- **Description:** When checking that a choice's arms are distinguishable, which literals count.
- **Options offered:** (a) only literal constraints on the arm's top-level observed value, following
  references and nested choices *(recommended)*; (b) every literal reachable in an arm; (c) ask.
- **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** CM-06: literal tests follow references and choice alternatives without descending into containers (COMMITMENT §3.1, with examples). Matches.

### G119 — Are literal-element lists packable?
- **Kind:** GAP · **Specs:** HASH §4 l.162-165 (packable scalar kinds: bool, uint8..uint64, int8..int64;
  lists of tstr, bstr, reference, choice or composite values are not packable).
- **Description:** Lists such as `[* true]` or `[* 5]` have a literal element schema; literals appear in
  neither list.
- **Options offered:** (a) packable — a literal's scalar kind is bool/uint64 *(recommended)*; (b) not
  packable; (c) ask the spec author.
- **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** CM-07: Boolean and integer literal element schemas are packable (HASH §4). Matches.

### G120 — Where the verified-view verifier gets the schema
- **Kind:** GAP · **Specs:** HASH §8, §9; INTERFACE §5.3 (schema text is untrusted input).
- **Options offered:** (a) caller-supplied; the verifier recomputes its root and rejects a mismatch with
  the view's root *(recommended)*; (b) only schemas already known by root in a pinned registry.
- **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** CM-08: the verifier takes the schema construction input separately from the view (HASH §8). Matches.
- **Revised 2026-11-11 (review against 6a4dfa28, item A23):** `verifyView` now requires the schema; the schema-less replay is `verifyPhysicalProof`, for App B only (I21, TF-13).

### G122 — `logos.schema.reference`
- **Kind:** GAP · **Specs:** COMMITMENT §6; HASH §7.2 (define the domain); no spec object produces it.
- **Options offered:** (a) implement it, unit tests only *(recommended)*; (b) leave it unclaimed.
- **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** CM-09: `logos.schema.reference` hashes a standalone `schema-import` pair that nothing in this revision uses (HASH §7.2). Matches.

### G10 — `0*` and `*1` occurrence spellings
- **Kind:** GAP · **Specs:** cdCDDLe §5.1 l.172 ("occurrences other than the supported `?` map-member and
  `*` array-member forms" are unsupported).
- **Description:** `[0* T]` means `[* T]` and `*1` means `?`, but they are other spellings.
- **Options offered:** (a) reject *(recommended)*; (b) normalize. **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** CM-10: explicit numeric occurrence bounds are rejected, including `0*` and `*1` (cdCDDLe §5.1). Matches (a).

### G11 — String-escape grammar
- **Kind:** GAP · **Specs:** cdCDDLe §5 l.125 (parse and resolve follow RFC 8610), l.455 (escape spelling
  is not preserved). RFC 9682 later updated CDDL's escape syntax.
- **Options offered:** (a) RFC 8610, as cited *(recommended)*; (b) RFC 9682 (documented deviation).
- **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** CM-11: text and byte-string literals follow RFC 9682 §2 (cdCDDLe §5 l.127): braced `\u{…}` escapes, no C1 controls; RFC 8610 for the rest. The parser follows it (`cddl/syntax.nim` `readEscape`, `bracedScalar`, `isC1`). What a line break inside a single-quoted byte string contributes is G157.
- **Revised 2026-11-11 (review against 6a4dfa28, item A29):** the parser had applied RFC 9682's C1 exclusion to comments as well; comments now follow RFC 8610's `PCHAR`, and U+10FFFE and U+10FFFF are rejected outside escapes (I12).

### G12 — Named range bounds
- **Kind:** GAP · **Specs:** cdCDDLe §5.1 l.163 ("inclusive integer ranges written with `..`"; RFC 8610
  allows value names as bounds).
- **Options offered:** (a) reject; integer-literal bounds only *(recommended)*; (b) resolve names to
  literals. **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** CM-12: range bounds are integer literals in the source, `.size` included (cdCDDLe §5.1). Matches.

### G13 — Non-flattened nested choices
- **Kind:** GAP · **Specs:** cdCDDLe §7.2 / l.332 (canonicalization MUST flatten nested type choices),
  §10 (decoder rejections; this case not named).
- **Options offered:** (a) the decoder rejects it *(recommended)*; (b) only the checker flags it.
- **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** CM-13: decoders reject a choice directly inside a choice (cdCDDLe §10). Matches (a).

### G14 — Scope of the cdCDDLe document built for a Logos schema
- **Kind:** GAP · **Specs:** cdCDDLe §8 (schema-as-data); COMMITMENT §5 (prelude, common and supporting
  schemas).
- **Options offered:** (a) authored rules only; prelude, common and supporting names stay type-reference
  nodes resolved against an explicit external scope *(recommended)*; (b) merge the resolved graph, then
  filter by origin. **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** CM-14: each cdCDDLe document holds only its own rules (COMMITMENT §5). Matches (a).

### G15 — Generic (non-Logos) cdCDDLe mode
- **Kind:** FREE · **Specs:** cdCDDLe §2 (scope).
- **Options offered:** (a) no — Logos subset only *(recommended)*; (b) yes. **Decision:** (a).

### G16 — cdCDDLe vector format and error classes
- **Kind:** FREE · **Specs:** cdCDDLe §12 fixes each record (name; exactly one of input-cddl or
  input-cbor-hex; expect valid/invalid; canonical-diagnostic; canonical-cbor-hex; error-class; notes)
  but not the error-class vocabulary or the container format.
- **Options offered:** (a) a JSON array of §12 records with error classes named after the violated rule
  *(recommended)*; (b) a CBOR file with coarse classes.
- **Decision:** (b): CBOR container; classes syntax, unsupported, resolution, canonical, decode.

### G151 — `.size` on a named target
- **Kind:** GAP, **OPEN** (found while building; reported as ND-10 in `claude-spec-comments-2.md`, logos-lips `e7c53b7b`) · **Specs:** cdCDDLe §5.1 l.164 (the
  `.size` control is supported, with no limit on its target), §6 l.227 (every graph in the subset has a
  model), §8 l.530 and l.537 (the node's target is a `primitive`, one of `uint`, `tstr`, `bstr`).
- **Description:** `b = tstr` and `a = b .size 3` is inside §5.1, but §8 has no node for it.
- **Options:** (a) keep rejecting it as unsupported until the owner answers; (b) allow a reference target
  in the `.size` node; (c) state in §5.1 that the target is written as a primitive.
- **Interim (D9):** (a). No mirrored schema uses it: every `.size` in the specs is on `uint`, `tstr` or
  `bstr` directly.
- **6a4dfa28:** not answered (ND-10 awaits the owner's follow-up). Interim unchanged.
- **Restated:** against 6a4dfa28 in `claude-spec-comments-2.md`, "Items without a response" (logos-lips
  `68628d95`).
- **Revised 2026-11-11 (review against 6a4dfa28, item B9):** the interim now conforms to cdCDDLe §11:
  l.621 requires accepting every graph "satisfying the supported-subset and canonical-model validity
  rules" (it said "within the supported subset"), and l.548 makes `uint`, `tstr` or `bstr` the only valid
  `.size` target in the model, so a named target fails a canonical-model validity rule. Only l.166 (the
  subset lists `.size` with no target limit) and l.238 (every graph within the subset MUST have a model)
  remain against it; ND-10 stays open for that.

### G152 — Identity of a leaf-bodied declaration's own node
- **Kind:** GAP, **OPEN** until 6a4dfa28, now settled by spec text (COMMITMENT §4 l.569-571) (found while building; reported as ND-11 in `claude-spec-comments-2.md`, logos-lips `e7c53b7b`) · **Specs:** COMMITMENT §4 l.560-562
  (an empty path uses the declaration's subtree root; a primitive, literal or reference node uses its leaf
  hash; "exactly one schema identity" per node), §8 l.1101 (a child value carries the referenced local
  declaration's schema identity), §9.2 (`schema-leaf-payload` allows the path `[]`).
- **Description:** In `demo.id = uint8` the body node sits at the empty path and is a primitive, so the two
  rules give it two identities. The choice sets the schema identity carried by every value node typed by
  such a declaration, so it changes value roots.
- **Options:** (a) the declaration's subtree root (the empty-path rule wins); (b) the leaf hash at path
  `[]`; (c) ask the owner to state the precedence.
- **Interim (D9):** (a), in `commitment/schema.nim` `nodeIdentity`, test `[IMPL-DECISION G152]`. It agrees
  with §8 l.1101. Only value roots depend on it, and none are built yet; schema roots do not.
- **Settled 2026-11-10 (6a4dfa28):** COMMITMENT §4 l.569-571 now says an empty path always uses the declaration's subtree root, including when its body is a primitive, literal or reference node. Matches the interim (a); ND-11 itself has no separate answer yet.
- **Revised 2026-11-11 (review against 6a4dfa28, item B16):** the Kind line kept **OPEN** beside the Settled note; it now reads settled. "None are built yet" in the interim is out of date: value roots are built (`commitment/normalize.nim` `identityOf`; the COMMITMENT App B.1 and HASH App B.4 vectors pass) and follow (a).

### G17 — Independent oracle for self-written vectors
- **Kind:** FREE · **Specs:** none (most specs ship no vectors; see the background above).
- **Options offered:** (a) an independent Python reference (cbor2 + blake3) written from the spec text
  *(recommended)*; (b) the Python reference plus poc2 where its rules match; (c) no oracle.
- **Decision:** (a). Disagreements block.

---

### G157 — A line break inside a single-quoted byte string
- **Kind:** GAP · **Specs:** cdCDDLe §5 l.127 (string literals follow RFC 9682 §2); RFC 9682 §2.1 (the
  byte-string grammar admits CRLF in `BCHAR`).
- **Description:** RFC 9682 lets a single-quoted byte string span lines, but neither it nor cdCDDLe says
  which bytes the source line break contributes (LF, CRLF as written, or nothing), so two parsers can give
  the same source different literal bytes and different schema roots.
- **Interim:** reject it as `unsupported` (`cddl/syntax.nim`, vector
  `unsupported-bytes-quoted-line-break`). **Status:** OPEN, found 2026-11-10; reported as TF-11 in
  `claude-spec-comments-3.md` (logos-lips `68628d95`), rated minor there: in a Logos schema document a
  byte-string literal is valid only in `_implements` (COMMITMENT l.396-397).
- **Revised 2026-11-11 (review against 6a4dfa28, item A28):** the interim knowingly falls short of
  cdCDDLe §11 l.621. A single-quoted byte string with a line break is inside the grammar (l.127, RFC 9682
  §2.1) and inside the subset (l.159, byte-string literals), yet it is rejected under `unsupported`, the
  class §5 keeps for constructs outside the subset (l.134-137, l.168-176). That is the price of not
  committing to bytes the text does not define; it ends when TF-11 is answered.

## 3. Interface: schemas, C mapping, code generation

### G117 — What counts as normative text
- **Kind:** GAP (uppercase half settled by every spec's Requirements Language at 6a4dfa28) · **Specs:** only cdCDDLe §4 l.87-88 cites BCP 14 (RFC 2119/8174); the other eleven
  specs use uppercase MUST/SHOULD/MAY without the boilerplate, and 55 lines use lowercase must/should.
- **Options offered:** (a) uppercase keywords are BCP 14 everywhere; every lowercase modal becomes a
  traceability row needing a test or a written triage reason *(recommended)*; (b) uppercase only.
- **Decision:** (a).
- **Settled 2026-11-11 (review against 6a4dfa28, item B1):** the premise is gone: all twelve specs now
  state "Uppercase requirement keywords in this specification follow BCP 14" and "Lowercase forms retain
  their ordinary English meanings" (INTERFACE l.74-75; the same two lines in each spec). The uppercase half
  of (a) is settled as chosen. The lowercase half is contradicted: a lowercase modal is ordinary English,
  not a requirement, so whether I6's `lc` units still need a test or a written triage reason, or are
  triaged in bulk, is open. **Needs an owner decision** (review item B1).
- **Re-decided 2026-11-11 (owner: "Accept all", after the Fable 5.2 session's review of the recommendations, item B1):** the lowercase half is triaged in bulk as informative; the
  text settles it (INTERFACE l.75 and the same line in every spec). `spectrace` keeps `lc` units in the
  ledger, so tests may still cite them, but no claim needs them covered (`GATED_KINDS`); the gate's
  claimed counts drop to CMT 201, HSH 176 and CDE 181 (from 205, 178 and 184). Behaviour stated
  declaratively with no modal at all (TRANSPORT l.541-545, for instance) is still specified, and its
  tests stay. G118 and C-11 are unaffected.

### G118 — Uppercase keywords inside informative sections
- **Kind:** GAP · **Specs:** INTERFACE App A.3 l.2934-2981 (MUSTs under a section titled
  "Informative"); SECURITY (category Informational) l.230, l.441.
- **Options offered:** (a) claim and test them as normative, raise the inconsistency upstream
  *(recommended)*; (b) exclude them. **Decision:** (a).
- **Note:** the question originally also cited RUNTIME App A and BCP §6-§8; the final review found those
  contain only MAYs and lowercase modals (covered by G117), so the citation was narrowed.
- **Revised 2026-11-11 (review against 6a4dfa28, item D7):** at 6a4dfa28 the uppercase keywords in
  informative text are in INTERFACE App A (l.3980 on; A.3 is l.4016-4077), SECURITY (category
  Informational, l.8) l.240, l.403 (new) and l.475, and BCP l.552, which follows the informative §8
  (l.534) after a horizontal rule (l.548), so whether it belongs to §8 is a reading. The old SECURITY
  l.230 and l.441 are now l.240 and l.475. Every spec now declares uppercase keywords BCP 14 with no
  exemption for informative text (G117), so (a) stands. SECURITY l.475 and BCP l.552 have no normative
  counterpart; remarked under C-11 in `claude-spec-comments.md` (logos-lips `68628d95`).

### G139 — Is the C->CDDL reverse mapper a conformance requirement?
- **Kind:** CONTRA · **Specs** (lines at `6a4dfa28`; corrected 2026-11-17, step 5-0): INTERFACE
  Abstract l.22-31 (the mapping is bidirectional and canonical; a conforming implementation of the
  bidirectional mapping MUST recover the same model from either representation, l.23), §3, §3.8
  l.2610-2634, §3.9 (normative cases, 13 named rejection cases) vs BCP §6.1 l.442 ("Code generation is an
  implementation technique rather than a conformance requirement"), l.482 ("Generated code is not
  required for conformance").
- **Options offered:** (a) implement it, every spec piece tested, raise the contradiction
  *(recommended)*; (b) defer and mark unclaimed; (c) ask the spec author first.
- **Decision:** (a), implement it and claim it (D30).
- **Revised 2026-11-10 (6a4dfa28):** C-03: an implementation of the bidirectional mapping supports both directions; a module need not implement authoring tools (INTERFACE abstract l.23-24). (a) stands: the reverse mapper is mandatory because lcn-gen claims mapping conformance.
- **Status (2026-11-18, step 5-1c):** (a) is implemented and claimed (D30, I98). The duty is ours
  because we claim the mapping: a Runtime or a module conforms without it (INTERFACE l.24; BCP l.442,
  l.482), and a conforming implementation *of the bidirectional mapping* recovers the same model both
  ways (l.23). G158's interim is the limit of the common names (TL-01).

### G38 — Floats inside opaque payloads
- **Kind:** GAP · **Specs:** INTERFACE §4.4 (Logos deterministic CBOR, preferred float serialization
  rule), §1.7 (schemas cannot declare floats), §4.5 (reasons malformed-cbor / non-deterministic-cbor /
  schema-mismatch); TRANSPORT §2.3 (schema-free envelope checks).
- **Description:** Whether a CBOR float anywhere inside a params/result/data map is a profile violation
  (ProtocolError and close in transport mode) or only a schema mismatch (a correlated INVALID_PARAMS).
  Tags, null and undefined are already spec-resolved: they pass the envelope and fail as schema-mismatch.
- **Options offered:** (a) schema mismatch; a non-shortest float is `non-deterministic-cbor`
  *(recommended)*; (b) profile violation (`non-deterministic-cbor` at the envelope).
- **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** IF-01: floating-point items MUST NOT appear at any depth (INTERFACE §4.4 item 5, l.3109), and one inside `params`, `result` or `data` is a Transport validation failure (INTERFACE §4.5 l.3138-3139; TRANSPORT §2.3). The decoder rejects floats as non-deterministic unless a caller asks for the generic data model (`allowFloats`, I48). (a) is withdrawn.
- **Code 2026-11-10 (6a4dfa28):** `envelope.decodeValue` maps the decoder's float rejection to `eeNonDeterministic` (ProtocolError INVALID_PARAMS, then close), and the sender refuses to encode one (I58). Tags, null and invalid UTF-8 inside payloads still pass the envelope and fail as schema-mismatch at the boundary (I30 stands: INTERFACE l.3139 moves only floats). Tests `[IFC-0920]`, `[TRN-0203]`.

### G59 — Value nesting depth
- **Kind:** GAP · **Specs:** INTERFACE §2.3, §3.9.3 and COMMITMENT l.427-428 (recursive types are legal);
  INTERFACE §4.4-§4.5, HASH (no depth bound); SECURITY §10 l.367 (frame limits not bounding other state
  is a residual risk); INTERFACE §4.5 (closed `invalid_params_reason` list).
- **Description:** A 16 MiB frame can nest about 16 million levels. No spec caps depth, and a schema-valid
  value rejected for depth has no matching INVALID_PARAMS reason.
- **Options offered:** (a) iterative processing plus a configurable cap (default 1024), over-cap =
  INVALID_PARAMS without detail, raised upstream *(recommended)*; (b) iterative, no cap.
- **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** IF-02: INTERFACE §4.5.1 counts only arrays and maps (a root container is depth one; tags, scalars and byte-string contents add none), requires a documented, configurable limit of at least 128, and a depth-only rejection is `INVALID_PARAMS` without detail. Our default stays 1024; tags get their own bound (I48). TRANSPORT §2.3 allows one more level for the envelope.
- **Code 2026-11-10 (6a4dfa28):** P is configurable from 128 to 1024 (`TransportLimits.payloadDepth`, default 1024; I59); the whole message may nest P + 1; a deeper payload is ProtocolError INVALID_PARAMS without detail, then close; the sender refuses one locally (I58). INTERFACE §4.5.1 l.3152 forbids internal structures that reduce P: validation, normalization, the value-tree check and the hash layout used to count recursion steps, so a recursive payload of 513 arrays failed as schema-mismatch. They now count maps and arrays (I51). Tests `[TRN-0269] [TRN-0270] [TRN-0271] [IFC-0923]`, `[IFC-0925] [IFC-0927]`.
- **Revised 2026-11-11 (review against 6a4dfa28, item D1):** the code note's citation is corrected from l.3151 to l.3152 ("Internal schema, normalization, or hashing structures MUST NOT reduce the supported payload depth"). I51 records one structure that still does: `parseNode` value objects, used only by verified views, nest several CBOR containers per payload container under the decoder's 1024, so views of very deep values are refused. Whether verifier input counts as a supported payload under l.3152 is a reading; no payload path uses those objects.

Background for G62-G72: INTERFACE §2 requires any two implementations to produce identical C header sets
"modulo whitespace, comments, include layout, and include guards", and §2.4 makes the exported per-method
signatures mandatory, so these are not cosmetic. Runtime Control itself (RUNTIME l.1814, a tuple-arm
choice) and the CA (l.1001, `[* bstr]` in a list position) use shapes the C mapping does not define.

**Revised 2026-11-11 (review against 6a4dfa28, item D6):** the quoted sentence is gone. INTERFACE
l.641-642 now require any two implementations to produce the same canonical declarations and constants
(names, types, values, dependencies, field and parameter order, choice representation) and let
whitespace, comments, declaration placement permitted by §2.1, include layout and include guards differ.

### G62 — C form of inline tuples, lists or unbounded bstr as choice arms or list elements
- **Kind:** GAP · **Specs:** INTERFACE §2.3 (defines inline tuples only as fields or named tuples; lists
  and bstr as adjacent pairs; inline composites path-named `list_item`, `tuple_<i>`, `arm_<i>`);
  COMMITMENT l.496 (declares `[uint64] / [uint64, uint64]` valid).
- **Options offered:** (a) path-named synthetic types extending the spec's naming: a tuple arm is a struct
  with `item_<i>` fields, a list/bstr becomes an adjacent ptr+len pair inside it; raised upstream
  *(recommended)*; (b) reject in the C mapping (no typed C bindings for Runtime Control and CA).
- **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** superseded by IF-03 and C mapping revision 3: the `_LIST`, `_TUPLE` and `_BSTR` aggregate families and the `_LI`, `_TU<i>`, `_AR_<Label>` and `_AR<i>` path steps (§2.1 l.775-832, §2.3 l.1033-1038). Built in `iface/cmap.nim`. Tests `[IFC-0632] [IFC-0914] [IFC-0915] [IFC-0916]`. **Status:** retired.

### G63 — Choice-of-maps event bodies in C
- **Kind:** GAP · **Specs:** INTERFACE §1.5 (allows choice-of-maps events) vs §2.5 (maps only map-bodied
  events).
- **Options offered:** (a) mirror the method rule: a wrapper struct with a kind tag and a union of arm
  structs, as §2.4 rules 4-5 do for requests *(recommended)*; (b) reject them. **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** superseded by IF-04: a choice-valued event body is an ordinary `_CHOICE` that keeps the `_event` stem and has no wrapper (§2.5 l.1394-1397). Built. Test `[IFC-0866] [IFC-0867]`. **Status:** retired.

### G64 — Tagged-choice tag member
- **Kind:** CONTRA · **Specs:** INTERFACE §2.3 (a generator MAY omit the tag member) vs §2 (headers must
  be identical across implementations).
- **Options offered:** (a) always emit it *(recommended)*; (b) always omit it. **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** C-04 (§2.3 l.1215): arm maps keep their literal tag fields. Matches (a). Test `[IFC-0148] [IFC-0645] [IFC-0647]`.

### G65 — Literal macro spelling
- **Kind:** GAP · **Specs:** INTERFACE §2.3 (macro holds "the exact C scalar literal"), §3.5 (reverse
  mapper checks the macro).
- **Options offered:** (a) stdint macros: `UINT64_C(7)`, `INT64_C(-5)`, INT64_MIN as
  `(-INT64_C(9223372036854775807) - 1)`, `true`/`false`, C strings with `\xNN` escapes *(recommended)*;
  (b) plain suffixes (`7u`, `7ull`, `-5ll`, `1`/`0`). **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** superseded by IF-05 (§2.3 l.1085-1096): `UINT64_C(n)`, `(-INT64_C(n))`, the minimum as `(-INT64_C(9223372036854775807) - INT64_C(1))`, and text with `\"`, `\\`, `\?`, `\n`, `\r`, `\t` and a three-digit octal escape for every other byte. Built. Test `[IFC-0872]` (static asserts in five language modes). **Status:** retired.

### G66 — Optional inline tuple vs the `has_` adjacency rule
- **Kind:** GAP · **Specs:** INTERFACE §3.4 (a `has_` flag sits adjacent to the member it guards); an
  inline tuple expands into several members.
- **Options offered:** (a) `has_<f>` immediately before the first expanded member *(recommended)*;
  (b) reject optional inline tuples. **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** IF-06 (§2.3 l.1014). Matches (a). Test `[IFC-0631]`.

### G67 — Allocation and free order of recursive typed outputs
- **Kind:** GAP · **Specs:** INTERFACE §2.7 (callers free each dynamic output with `_free`; recursive
  `const B*` edges not addressed).
- **Options offered:** (a) one provider allocation per node, freed children first *(recommended)*; (b) one
  block per output tree. **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** superseded by IF-07: one response owner per typed response, and callers never free individual pointers (§2.7 l.1805-1854, §2.7.1 l.1856-1904). Not built (Tier 4, a promotion candidate). **Status:** retired.
- **Revised 2026-11-11 (review against 6a4dfa28, item C6):** "Not built" is out of date: response owners are built for typed provider functions (I72: each call's `CallArena` becomes the response owner) and for the typed call helpers (I73).

### G68 — Freeing typed route-helper outputs
- **Kind:** GAP · **Specs:** INTERFACE §2.7 ("the side that decodes … owns and frees its own decoded
  allocations"), App A.5; no API named.
- **Options offered:** (a) generated consumer-side free helpers, never the provider's `_free`
  *(recommended)*; (b) helpers take an allocator parameter. **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** IF-08: call helpers return a response owner plus typed cleanup (§2.7.2 l.1906-1926). Consistent with (a). Not built.
- **Revised 2026-11-11 (review against 6a4dfa28, item C6):** "Not built" is out of date: the §2.7.2 cleanup helpers are built as `lcn_clear_<namespace>_<Method>` (I73).

### G69 — Static-link symbol collisions
- **Kind:** GAP · **Specs:** INTERFACE §1.3, §2.1 (a schema set deriving the same C identifier twice is
  invalid); RUNTIME §1.3 (`_call_` / `_publish_` reserved in module names).
- **Description:** Module `foo` with namespace `call` and method `surface` derives
  `logos_foo_call_call_surface`, which module `foo_call` also exports; names ending in `_call`/`_publish`
  are not covered.
- **Options offered:** (a) reject module names ending `_call`/`_publish` and namespaces named
  `call`/`publish`, raised upstream *(recommended)*; (b) detect only at registration.
- **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** IF-09: separate `_MODULE_` and `_CALL_` families and no further reservations (§2.1 l.703-747, l.769-773). The checks are gone from `iface/names.nim`: `demo_call`, `demo_publish` and the namespaces `call` and `publish` are accepted. RUNTIME §1.3's `_call_`/`_publish_` infix rule for module names is the Runtime's to enforce (Tier 4). **Status:** retired.
- **Revised 2026-11-11 (review against 6a4dfa28, item C7):** the infix rule is not left to Tier 4: INTERFACE l.261 makes `_module` values containing `_call_` or `_publish_` invalid, so schema acceptance rejects them, and it does (`iface/names.nim` `checkModuleName`). What G69 removed is only its own extra reservation.

### G70 — Source of `schema_cbor` for `materialize_route`
- **Kind:** GAP · **Specs:** INTERFACE §5.2 (one `logos.schema_response`, 1 B-8 MiB, validated against
  `expected_contract_root`); RUNTIME §4.2 ("Generated typed helpers can carry this expectation by
  construction"); `route_record` carries only the commitment.
- **Options offered:** (a) generated bindings embed it at build; generic clients (logosctl) use
  `describe_provider` *(recommended)*; (b) always fetch at run time. **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** IF-10 (§5.2 l.3870-3879): the route construction input may be embedded, supplied, a projected descriptor or an introspection response, and the same exact root is validated. Matches (a). Tier 4.

### G71 — Generated helper names
- **Kind:** CONTRA (both informative) · **Specs:** INTERFACE App A.4/A.5 (`logos_<module>_publish_<ns>_<event>`,
  `logos_<ns>_invoke_<method>(route, …)`) vs RUNTIME §4.1 (`logos_storage_exists(h, …)`).
- **Options offered:** (a) INTERFACE A.4/A.5 — matches the reserved `_publish_` infix and cannot collide
  with provider symbols *(recommended)*; (b) RUNTIME §4.1 style. **Decision:** (a); helpers are never
  exported from module artifacts (INTERFACE l.235-238).
- **Settled 2026-11-10 (6a4dfa28):** C-05 (§2.1 l.886-889): helper names are implementation-defined, stay outside the header set used for reconstruction and do not affect identity. (a) stays our naming.
- **Revised 2026-11-11 (review against 6a4dfa28, item C5):** "(a) stays our naming" no longer holds for the C call helpers: I73 names them `lcn_invoke_<namespace>_<Method>` and `lcn_clear_<namespace>_<Method>`, because the exported `logos_` prefix belongs to the ABI (INTERFACE l.266-269) and helper names are implementation-defined (l.886). App A.5's `logos_<ns>_invoke_<method>` is only the informative example.

### G72 — Header declaration order
- **Kind:** GAP · **Specs:** INTERFACE §2.1 (orders forward declarations, type definitions, fields, choice
  arms; not macros, lifecycle symbols and typedefs relative to provider declarations).
- **Options offered:** (a) forward declarations, type definitions (spec order), literal macros by name,
  provider functions by qualified name, lifecycle symbols; raised upstream *(recommended)*; (b) ask the
  spec author. **Decision:** (a).
- **Status:** revised 2026-11-10 (building Tier 2). §3.9.2's required header puts the literal macros
  right after the document-role constants, before any typedef, so the order of type declarations is:
  role constants, literal macros by name, constrained-string typedefs by name, forward typedefs by
  qualified name, then definitions in dependency order (G155). Provider functions and lifecycle symbols
  come after them once §2.4 and §2.6 are built (Tier 4). `iface/cmap.nim` `emit`, test `G72`.
- **Revised 2026-11-10 (6a4dfa28):** superseded by IF-11 (§2.1 l.891-897): the placement of independent declarations is not canonical. Our order is now an [IMPL] choice (I60). **Status:** retired.

### G153 — Local alias cycles
- **Kind:** GAP, **OPEN** (found while building; reported as ND-12 in `claude-spec-comments-2.md`, logos-lips `2f6cbcb0`) · **Specs:** INTERFACE §2 (every
  accepted schema set has one canonical C form), §2.1 (aliases become typedefs), §5.3 l.2878-2879,
  l.2889-2895 (cyclic references are bounded, IFC-0532; reject unresolved or conflicting definitions);
  COMMITMENT §3.1 (a reference node names its target and nothing more).
- **Description:** `demo.a = demo.b` with `demo.b = demo.a` (or `demo.a = demo.a`) resolves, builds a
  schema model and has a schema root, but no value and no C form: a typedef cannot name itself. No
  rule rejects it.
- **Options:** (a) reject a chain of local aliases that never reaches a structure, a scalar or an import,
  at acceptance; (b) accept it and fail only in the C mapping; (c) ask the owner to state it.
- **Interim (D9):** (a), in `iface/accept.nim` `checkAliasCycles`, test `[IMPL-DECISION G153]`. A cycle
  that passes through a map, tuple, list or choice is untouched (it is the recursion §2.3 maps to
  pointers). Narrowing only: no set the spec gives a C form for is rejected.
- **6a4dfa28:** not answered (ND-12). Interim unchanged.
- **Restated:** against 6a4dfa28 in `claude-spec-comments-2.md`, "Items without a response" (logos-lips
  `68628d95`).

### G154 — Forward typedefs for list targets on a reference cycle
- **Kind:** GAP, settled by spec text at 6a4dfa28 (found while building; reported as ND-13 in `claude-spec-comments-2.md`, logos-lips `2f6cbcb0`) · **Specs:** INTERFACE §2.1 (canonical
  order: forward declarations, then definitions with non-recursive dependencies first), §2.3 (recursive
  by-value edges become `const T*` and their targets get forward typedefs; a list member is a
  `const T*` plus a count).
- **Description:** `demo.node = { kids: [* demo.node] }` has no by-value edge, so the spec's rule emits
  no forward typedef, yet the `kids` member spells `logos_demo_node_t` inside the definition that
  introduces it, which does not compile. The same holds across declarations: with
  `demo.a = { bs: [* demo.b] }` and `demo.b = { a: demo.a }`, b embeds a by value and a's list member
  spells b's typedef, so no order of definitions compiles without one.
- **Options:** (a) a list member's target also gets a forward typedef when both lie on one cycle of the
  graph of by-value and list edges; (b) forward-declare every list target; (c) ask the owner.
- **Interim (D9):** (a), in `iface/cmap.nim` `resolveGraph`, test `G154`. Header text only: struct
  layouts and every identifier are unchanged.
- **6a4dfa28:** not answered (ND-13). Interim unchanged.
- **Settled 2026-11-10 (6a4dfa28) by spec text:** §2.3 l.1077: "The generator MUST also emit a forward typedef whenever an aggregate type name is used before its complete definition, including uses through variable-length lists." `cmap.ordered` makes each definition wait for every typedef it spells that no forward typedef supplies, so the only uses before a definition are recursive pointers and list members on a cycle, and both get forward typedefs. Now `[SPEC INTERFACE §2.3 l.1077]`; ND-13 needs no answer for us. Test `[IFC-0633]`.

### G155 — Tie-breaking among independent type definitions
- **Kind:** CONTRA, moot at 6a4dfa28 (found while building; reported as ND-14 in `claude-spec-comments-2.md`, logos-lips `2f6cbcb0`) · **Specs:** INTERFACE §2.1 l.676-679
  ("place non-recursive dependencies before dependents and break independent ties by qualified schema
  name") vs the required §3.9.3 output (l.2102-2152).
- **Description:** A topological order that picks the least qualified name among the definitions ready
  at each step gives `left, node, branch, right` for §3.9.3 (branch is ready once node is placed, and
  `branch` < `right`). The required header has `left, node, right, branch`.
- **Options:** (a) order by dependency depth (the longest chain of definitions a definition waits for),
  then by qualified name, which reproduces §3.9.3; (b) the least-name topological order, which
  contradicts §3.9.3; (c) ask the owner which text is meant.
- **Interim (D9):** (a), in `iface/cmap.nim` `ordered`, test `[IFC-0384]` (§3.9.3 byte-for-byte). Header
  order only, not ABI.
- **6a4dfa28:** not answered (ND-14). Interim unchanged.
- **Moot 2026-11-10 (6a4dfa28):** IF-11 (§2.1 l.891-897) makes the placement of independent declarations non-canonical, so no tie-break is required. Depth-then-name stays as our placement (I60), and the §3.9.3 header is still reproduced byte for byte (`[IFC-0882]`).

---

### G158 — The common-name projection
- **Kind:** GAP · **Specs:** INTERFACE §5.2 l.3382-3383 ("derived by Sections 2.1 through 2.3, including
  the dedicated common-name projection and the `logos.error_code` exception"); §2.1 l.834-843 names only
  `logos_error_code_t`, `logos_error_detail_t` and `logos_schema_commitment_t`; §3.1 l.2248
  ("Fixed `logos_<common-name>_t`").
- **Description:** no section defines the projection, so the C names of `logos.invalid_params_detail`,
  `logos.invalid_params_reason`, `logos.invalid_params_path_segment`, `logos.schema_request`,
  `logos.schema_response`, their kind typedefs and arm macros, the inline `path` list and the
  `schema_commitment` literal macros are undefined. They are ABI-visible: a reverse mapper must
  recognize them.
- **Interim:** stem = the local name, then the ordinary §2.1 families (for example
  `logos_invalid_params_reason_KIND_t`), confined to the generated common section of `logos_types.h`,
  which stays PROVISIONAL. **Status:** OPEN, found 2026-11-10 (reviewer item N1); reported as TL-01 in
  `claude-spec-comments-3.md` (logos-lips `68628d95`); blocks that section under D9.
- **Reverse half (5-1, I98):** the same interim projection applies in reverse. `iface/rmap.nim` parses
  this repository's `logos_types.h` and recognizes a common type by the C name the projection gives it,
  computed and never typed. IFC-0003, IFC-0004, IFC-0355 to IFC-0357 and IFC-0861 to IFC-0863 hold under
  it. The status stays OPEN, and the limit is stated in `docs/CONFORMANCE.md` and at the `"§3"` key of `conformance/claims/IFC.toml`.

## 4. Error codes the specs require but do not assign

Background: INTERFACE §5.1 fixes a closed registry (0 OK, 1 METHOD_NOT_FOUND, 2 INVALID_PARAMS,
3 MODULE_ERROR, 4 NOT_AUTHORISED, 5 TRANSPORT_ERROR, 6 TIMEOUT, 7 VERSION_MISMATCH, 8 NOT_READY,
9 CANCELLED); only INVALID_PARAMS may carry detail, and only with reason malformed-cbor,
non-deterministic-cbor or schema-mismatch. Expected domain failures must be LOGOS_OK with a typed
response (INTERFACE §4.6). RUNTIME §3.4 l.633 reserves NOT_READY for "Runtime-owned lifecycle, provider,
or route readiness". Execution-boundary invariance (INTERFACE intro, RUNTIME l.40-64) requires the same
code in direct, local and remote mode. Many MUST-reject rules name no code; these entries fix them so
tests can assert exact values.

**Revised 2026-11-11 (review against 6a4dfa28, item D6):** INTERFACE l.3228-3232 add a fourth detail
reason, `configuration-schema-mismatch`. RUNTIME §3.4's NOT_READY rule is now l.660, and RUNTIME l.1907-1919
("Invocation precondition errors") assign several of the codes below (G18-G20, G24; review item B2).

### G18 — `request_key` reused with different fields
- **Kind:** GAP (settled by RUNTIME l.1912 at 6a4dfa28) · **Specs:** RUNTIME §9.3 (create_module / establish_route idempotency).
- **Options offered:** (a) INVALID_PARAMS without detail *(recommended)*; (b) MODULE_ERROR.
- **Decision:** (a).
- **Settled 2026-11-11 (review against 6a4dfa28, item B2):** RUNTIME l.1912 and l.1918: a retained `request_key` reused within its scope for different request fields or another operation is `INVALID_PARAMS` without validation detail. Matches (a).

### G19 — Stale expected revision on a compare-and-set request
- **Kind:** CONTRA (settled by RUNTIME l.1913 and CONFIG l.195 at 6a4dfa28) · **Specs:** RUNTIME §9.1, §9.3 (expected execution / permission revisions), CONFIG
  (expected configuration revision) vs RUNTIME l.633.
- **Options offered (first):** (a) NOT_READY *(recommended)*; (b) INVALID_PARAMS. **First decision:** (a).
- **Re-check (final review):** l.633 limits NOT_READY to readiness, and a stale revision is not readiness.
  Options: (a) split — readiness preconditions keep NOT_READY, stale revisions become INVALID_PARAMS
  without detail *(recommended)*; (b) keep NOT_READY and record a CONTRA.
- **Decision:** INVALID_PARAMS without detail. **Status:** revised.
- **Settled 2026-11-11 (review against 6a4dfa28, item B2):** RUNTIME l.1913 and l.1918: an expected execution, permission-settings or configuration-state revision that does not equal the current one is `INVALID_PARAMS` without validation detail; CONFIG §5 l.195 says the same for configuration, and l.196 makes a stale configuration-schema commitment `VERSION_MISMATCH`. Matches the revised decision.

### G20 — Lifecycle preconditions not met
- **Kind:** GAP (settled by RUNTIME l.1914-1915 at 6a4dfa28) · **Specs:** RUNTIME §9.3 (start_module while stopping, recover_module outside allowed
  states, renew_route on a closed or failed route the caller may observe).
- **Options offered:** (a) NOT_READY *(recommended)*; (b) INVALID_PARAMS. **Decision:** (a) (these are
  Runtime-owned lifecycle/route readiness, within l.633).
- **Settled 2026-11-11 (review against 6a4dfa28, item B2):** RUNTIME l.1914 (the Runtime-owned lifecycle state prohibits the requested operation) and l.1915 (renewal of a closed or failed route) are `NOT_READY`. Matches (a).

### G21 — `apply_configuration` failures
- **Kind:** CONTRA · **Specs:** CONFIG §8 (live reconfiguration), RUNTIME §9.3 (the response has no
  failure variant) vs RUNTIME l.633.
- **Options offered (first):** (a) preconditions NOT_READY / module rejects MODULE_ERROR / indeterminate
  MODULE_ERROR *(recommended)*; (b) all MODULE_ERROR. **First decision:** (a).
- **Re-check:** "no staged record" and "binding not live-reconfigurable" are not readiness. Same split as
  G19 *(recommended)* vs keep.
- **Decision:** readiness preconditions NOT_READY; no staged record or non-live binding INVALID_PARAMS;
  module rejection and indeterminate outcome MODULE_ERROR. **Status:** revised.
- **Revised 2026-11-10 (6a4dfa28):** EC-04: CONFIG's precondition table (l.290-299, l.315-319) uses VERSION_MISMATCH and separates MODULE_ERROR from TRANSPORT_ERROR. Add both when CONFIG is built (Tier 4).
- **Revised 2026-11-11 (review against 6a4dfa28, item B2):** also CONFIG §5 l.194-198, which apply to every configuration operation: no accepted configuration binding and a stale revision are `INVALID_PARAMS` without detail, a stale configuration-schema commitment `VERSION_MISMATCH`, a malformed value `INVALID_PARAMS` without detail, and a value that does not conform `INVALID_PARAMS`, optionally with `configuration-schema-mismatch`.
- **Built 2026-11-13 (I87, step 9a), for the §5 operations:** the CONFIG l.192-198 rows in table order
  after the caller's association and the method's authority (G171): no binding and a stale state
  revision INVALID_PARAMS without detail; a stale configuration-schema commitment VERSION_MISMATCH; a
  malformed or too deep value INVALID_PARAMS without detail; a value outside the schema INVALID_PARAMS
  with `configuration-schema-mismatch` and its path, only for a caller that also holds
  `get_configuration_schema` authority (otherwise without detail); then the frame (G233) and the
  revision (G234), MODULE_ERROR. The §8 rows of `apply_configuration` come with live reconfiguration
  (step 9b); until then it is MODULE_ERROR, "not supported by this Runtime yet".

### G22 — Calls on a dead route handle
- **Kind:** GAP (settled by RUNTIME l.1341-1350 at 6a4dfa28) · **Specs:** RUNTIME §4.1 (calls on closed, failed, revoked or expired handles MUST
  fail), INTERFACE §5.2; TRANSPORT §3.2 (connection close gives TRANSPORT_ERROR).
- **Options offered:** (a) closed/failed NOT_READY, revoked/expired NOT_AUTHORISED, checked at the
  Runtime boundary so every mode agrees *(recommended)*; (b) all NOT_AUTHORISED; (c) all TRANSPORT_ERROR.
- **Decision:** (a).
- **Settled 2026-11-11 (review against 6a4dfa28, items B3, A20):** RUNTIME l.1343-1347 classify a new operation through the handle by cause, not by the route-state label (l.1345): `NOT_AUTHORISED` when route authority was withdrawn, has expired or cannot be established; otherwise explicit closure or lost readiness is `NOT_READY`; `NOT_AUTHORISED` wins when both are known (l.1347); a transport failure that prevents a result stays `TRANSPORT_ERROR` (l.1350). (a)'s shape stands with that refinement. TRANSPORT l.996 adds that a known authorization failure governs later new local operations. The rule applies at the boundary that decides whether to admit a new operation (l.1349), so the Tier 4 route handle classifies and must keep the close cause (l.1346). I54's `NOT_READY` for every closed `CallerConn` is the Tier 3 default, which the handle overrides when the cause is a known authorization failure, such as a received ProtocolError `NOT_AUTHORISED` after termination (TRANSPORT l.991).
- **Re-checked at 4b-2b (2026-11-13, I90):** a transported handle keeps two codes (`runtime/transported.nim`): the route's own end cause, which every new operation reports first (l.1343-1347), and the first terminal cause its observer saw. A connection that ends while the route lives gives later operations that connection's code: `NOT_AUTHORISED` after a received ProtocolError `NOT_AUTHORISED` (TRANSPORT l.991, l.996), otherwise TRANSPORT_ERROR (l.1350; G256), never an inferred `NOT_READY`. The route's later end replaces it for new operations.

### G23 — Calls into a stopping provider; calls on an invalidated Runtime Control binding
- **Kind:** GAP (settled by RUNTIME l.630 at 6a4dfa28) · **Specs:** RUNTIME §3.4 (stopping invalidates the instance's RC bindings); TRANSPORT
  (in-flight calls get TRANSPORT_ERROR when the connection closes; CANCELLED only for processed Cancels).
- **Options offered:** (a) NOT_READY for both *(recommended)*; (b) CANCELLED. **Decision:** (a); in-flight
  transport calls keep the mandated TRANSPORT_ERROR.
- **Settled 2026-11-11 (review against 6a4dfa28, item B2):** RUNTIME l.630: a new invocation rejected only because its provider is stopping or its Runtime Control binding was logically invalidated is `NOT_READY` while the binding storage stays valid; known authorization failures keep their precedence (l.632). Matches (a).

### G24 — A required system service other than the CA is unavailable
- **Kind:** GAP (settled by RUNTIME l.1916 at 6a4dfa28) · **Specs:** RUNTIME "System Service Availability" (fail the dependent operation), l.1516
  (an unavailable external CA means deny, hence NOT_AUTHORISED).
- **Options offered:** (a) NOT_READY for Loader / Package Manager *(recommended)*; (b) MODULE_ERROR.
- **Decision:** (a).
- **Settled 2026-11-11 (review against 6a4dfa28, item B2):** RUNTIME l.1916: an unavailable required non-authority system service that prevents the operation is `NOT_READY`; an unavailable Capability Authority keeps the authorization-failure rules (l.1919). Matches (a).

### G25 — Native binding failures
- **Kind:** GAP · **Specs:** INTERFACE §5.2 (a vtable failing its checks MUST be rejected; failed
  `materialize_route` / `connect_remote` leave outputs null; no codes named; `connect_remote` through a
  remote binding is INVALID_PARAMS).
- **Options offered:** (a) vtable VERSION_MISMATCH (like `_init`'s version check) / materialize_route
  returns the route-establishment failure's code / non-remote endpoint INVALID_PARAMS *(recommended)*;
  (b) all INVALID_PARAMS. **Decision:** (a).
- **Revised 2026-11-11 (review against 6a4dfa28, item A4):** settled differently for the vtable. INTERFACE l.3819-3820: `VERSION_MISMATCH` only for an unsupported vtable version or too small an extent; a null vtable, null state or null required operation in a binding from its producer is `MODULE_ERROR`. I66 already follows the text, so (a)'s "vtable VERSION_MISMATCH" is withdrawn. The other codes are now listed: `materialize_route` l.3886-3892 (malformed construction input `INVALID_PARAMS`, an unknown, foreign or hidden route non-revealing `NOT_AUTHORISED`, a root mismatch `VERSION_MISMATCH`, readiness and authorization per RUNTIME §7.5, Hello failures per RUNTIME §4.1), and `connect_remote` through a remote binding, or with an endpoint that omits the Runtime identity, is not remote or names the caller's own Runtime, `INVALID_PARAMS` without detail (l.3842, l.3845).

### G26 — Listener, export and enrollment rejections
- **Kind:** GAP (partly spec-resolved; settled by RUNTIME l.3437-3443 at 6a4dfa28) · **Specs:** RUNTIME §9.3 l.2991-3017; l.433 and l.2774-2776
  (unknown or hidden targets give a non-revealing NOT_AUTHORISED — already mandated).
- **Options offered:** (a) malformed or unsupported profile INVALID_PARAMS; unknown/hidden NOT_AUTHORISED
  *(recommended)*; (b) all NOT_AUTHORISED. **Decision:** (a).
- **Settled 2026-11-11 (review against 6a4dfa28, item B5):** RUNTIME l.3437-3443: invalid listener or export field combinations, a missing listener record and a provider the Runtime does not own are `INVALID_PARAMS` without detail; unknown, hidden or denied targets stay non-revealing `NOT_AUTHORISED`; failure to bind or activate a valid listener is `TRANSPORT_ERROR`; other failures use the specific shared code or `MODULE_ERROR`, and resource exhaustion alone is not a readiness failure. Enrollment validation is a provisioning requirement, not a Runtime Control method (l.2689-2691). Matches (a), which gains the activation and resource codes.

### G27 — Vocabulary of `route_failure.code` and `permission_settings_state.failure`
- **Kind:** GAP · **Specs:** RUNTIME §9.3 (both `tstr .size(1..64)` with no value list, yet l.2864-2871 and
  l.2937-2943 require distinguishing facade failure, remote unreachable / not ready / stopped / failed,
  denial vs evaluation failure, contract mismatch, enrollment/listener/export defects, ticket defects,
  expiry, revocation, connection loss).
- **Options offered:** (a) a fixed, documented kebab-case list with one value per class *(recommended)*;
  (b) free text. **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** EC-10: failure codes are open text strings with defined lists, not a closed enum (RUNTIME `route_failure` l.2088, l.2493-2530; module failures l.3750-3762; `failure_code` l.1945). Use the spec's lists and accept unknown codes. The RC root changes with the CDDL.

### G28 — Loader values for weaker-substitute refusal and disallowed init results
- **Kind:** CONTRA (settled by LOADER l.628 at 6a4dfa28) · **Specs:** LOADER §6 l.395-396, l.423, §10 l.612 (`unsupported-strategy` lets
  Runtime choose another strategy or placement), l.615-616 (initialization failures are
  `realization-failed`); TRANSPORT l.960 (no isolation downgrade).
- **Options offered (first):** (a) `unsupported-strategy` / `abi-invalid` *(recommended)*;
  (b) `unsupported-strategy` / `realization-failed`. **First decision:** (a).
- **Re-check:** (a) follow LOADER's own definitions — refusal = `unsupported-strategy`, but Runtime never
  reselects a weaker strategy or placement and fails the request; disallowed init result =
  `realization-failed` *(recommended)*; (b) keep the first answer as a documented deviation.
- **Decision:** re-check (a). **Status:** revised.
- **Revised 2026-11-11 (review against 6a4dfa28, item A3):** settled differently. LOADER l.628 (new at 6a4dfa28): a realization request that uses an advertised strategy and, where applicable, an advertised hosted placement MUST fail with `realization-failed` when the required security or deployment controls cannot be established. `unsupported-strategy` is only for a strategy or placement the Loader did not advertise (l.377), and it still lets Runtime pick another advertised one (l.621). So refusing a weaker substitute (l.428, l.666-667) is `realization-failed`, and the re-check's "refusal = `unsupported-strategy`" is withdrawn. A disallowed init result stays `realization-failed` (l.625-627). Not built (Tier 4).

### G60 — Host Embedding API edge cases
- **Kind:** GAP (partly spec-resolved; settled by RUNTIME l.4050-4053 at 6a4dfa28) · **Specs:** RUNTIME §13.3 l.3436 (listed binding defects =
  INVALID_PARAMS), §13.4 l.3470 (otherwise the applicable shared code, else MODULE_ERROR).
- **Options offered:** (a) `wait_for_shutdown` returns MODULE_ERROR when cleanup failures were recorded;
  bad bindings rejected at `register_binding` with INVALID_PARAMS *(recommended)*; (b) LOGOS_OK with
  failures only logged; rejection at realization.
- **Decision:** (a). Symbol defects beyond the l.3436 list are the remaining gap.
- **Settled 2026-11-11 (review against 6a4dfa28, item B4):** RUNTIME l.4050-4053 close the remaining gap: besides duplicates, empty tables and null addresses, a malformed canonical symbol name, an ambiguous module symbol family or a missing unconditional module ABI symbol is `INVALID_PARAMS` at registration, checked without invoking module code; requirements that depend on the call surface or configuration binding are checked during implementation binding. Other failures use the applicable shared code or `MODULE_ERROR` (l.4088). Matches (a).
- **Built 2026-11-11 (I81):** `logos_runtime_wait_for_shutdown` returns LOGOS_OK, or MODULE_ERROR
  naming the instances when any realization's cleanup is unresolved or failed at completion
  (`cleanup-timeout`, `cleanup-failed`, a startup attempt or a teardown still outstanding); every wait
  returns that one result (RUN-0760). `engine.shutdownOutcome`.
- **Extended 2026-11-13 (I89, parts 4b-1c and 4b-1d; plan R3):** shutdown keeps the Module Loader
  while it owns a realization or runs a call. A release still running when the grace ends makes the
  result MODULE_ERROR, and `destroy` is NOT_READY until it returns. After Loader loss with
  realizations owned, the message adds "; the Module Loader failed: the host process must end" (G249).
- **2026-11-14 (I91, part 4b-3.1b):** a lost Loader's own release, begun once it owns nothing, is waited
  for as any release in progress is; the grace bounds it.

---

## 5. Transport

Background: TRANSPORT fixes the message directions (§1.2, §1.4), the envelope checks (§2.3: frame length,
deterministic CBOR, known kind, required fields, field types — each failure is "do not dispatch,
INVALID_PARAMS if writable, close"), the Hello order and codes (§3.1, §8.3), and one receiver leniency
(§6: a Cancel for an unknown id is ignored). It ships no byte vectors. The entries below cover receiver
behaviour it leaves open; all were chosen fail-closed so evil-peer tests are unambiguous.

### G30 — Wrong-direction or pre-Hello messages
- **Kind:** GAP · **Specs:** TRANSPORT §1.2, §1.4 (directions), §2.3 (direction and state are not in the
  envelope checks), §3.1 step 3, §3.3 (only a second Hello is covered); RUNTIME §6.2 (nothing dispatched
  before Hello succeeds).
- **Options offered:** (a) ProtocolError INVALID_PARAMS + close *(recommended)*; (b) drop and log.
- **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** TRANSPORT §2.3 l.417-421 mandates (a) for wrong-direction messages and for ordinary messages before Hello. One code change: a well-formed ProtocolError sent as the first message closes with no reply and consumes no ticket (l.421); `acceptHello` returns `HelloFailure(peer: true, reason: hrPeer)`. Tests `[TRN-0272]`..`[TRN-0275]`.

### G31 — Uncorrelated Response, SubscriptionResult or Event
- **Kind:** GAP · **Specs:** TRANSPORT §1.4 (exactly one Response per Request id), §6, §5.1; RUNTIME §9.3
  (timeout policy is the implementation's, so a late Response to a call the caller abandoned after its
  own timeout is legitimate).
- **Options offered:** (a) tombstones — replies to ids the caller abandoned are dropped silently;
  never-sent or duplicate ids get ProtocolError INVALID_PARAMS + close *(recommended)*; (b) always close;
  (c) always drop. **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** §3.4 l.580-603 replaces the silent drop. An abandoned call keeps its response declaration; its first terminal Response is fully validated (envelope, schema, roots; an invalid one closes), then discarded, and the call is retired. A second Response is a duplicate: INVALID_PARAMS, then close. `abandonSubscription` suppresses only Event callbacks: events are still validated, and a late SubscriptionResult still updates state and is reported, since it is protocol state (l.596-597). Never-sent ids, duplicates and unsolicited messages close, as before. Correlation state is kept while the connection is open (l.601-602), bounded by I52. Tests `[TRN-0280]`..`[TRN-0289]`. (a)'s silent drop is withdrawn.

### G32 — Subscription id misuse
- **Kind:** GAP · **Specs:** TRANSPORT §5.1 (caller ids unique per connection; at most one outstanding
  control operation per id; exactly one SubscriptionResult per syntactically valid Subscribe/Unsubscribe;
  no code named for reused or unknown ids).
- **Options offered:** (a) a failed SubscriptionResult with INVALID_PARAMS for reuse, unknown id and
  overlap, state unchanged *(recommended)*; (b) failed result for reuse/unknown, ProtocolError + close
  for overlap. **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** §5.1 l.731, l.741-749 mandates (b) and widens "used". An operation over an id whose previous result is not yet committed gets ProtocolError INVALID_PARAMS and close, with no SubscriptionResult; this check comes first. A Subscribe reusing an id from any earlier valid Subscribe (successful, failed or ended) gets a failed result INVALID_PARAMS, and so does an Unsubscribe with no active subscription. The id counts as used before the event name is resolved, so a Subscribe that fails NOT_AUTHORISED still uses it ("state unchanged" in l.727, l.736 is the active state; the id history is l.747-748). The caller keeps its own used-id set and refuses reuse locally. Tests `[TRN-0302]`..`[TRN-0306]`.

### G33 — Non-empty Hello response token
- **Kind:** GAP · **Specs:** TRANSPORT §3.1 (caller validates the token "under the profile's response
  rules", no code), §8.1, §8.2; RUNTIME §9 (every defined profile requires an empty response token).
- **Options offered:** (a) ProtocolError NOT_AUTHORISED + close *(recommended)*; (b) INVALID_PARAMS.
- **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** §3.1 l.518-534: the caller checks module, token and schema in that order, and a non-empty token is NOT_AUTHORISED. Matches (a). Test `[TRN-0277]`.

### G34 — When the provider Hello runs and what the consumer sees when it fails
- **Kind:** GAP · **Specs:** TRANSPORT §3.1, §3.2 (synthetic TRANSPORT_ERROR on close), §8.1.1 (tickets
  live at most 60 s); INTERFACE §4.6; RUNTIME §4.1, §9 (Hello authorization failure = NOT_AUTHORISED).
- **Options offered:** (a) the Hello runs inside `materialize_route`, which returns the peer's code
  (NOT_AUTHORISED, VERSION_MISMATCH) *(recommended)*; (b) lazy connect on first call, failures surface as
  TRANSPORT_ERROR. **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** RUNTIME §4.1 l.783-793: `materialize_route` completes peer validation and Hello before it returns. Matches (a). Tier 3 returns the peer's code from `acceptHelloResponse`; `materialize_route` is Tier 4.

### G35 — Route expiry or revocation on a live session
- **Kind:** GAP · **Specs:** TRANSPORT §8.1 (reject new operations, then end subscriptions and the
  session), §8.2, §8.4.1 (one session per connection); CA §8 (sessions may stay open but unusable while a
  fresh decision is fetched); RUNTIME §9.3 (audit distinguishes expiry, revocation, connection loss). The
  on-wire signal is unspecified.
- **Options offered:** (a) new Requests in the window get NOT_AUTHORISED; then ProtocolError
  NOT_AUTHORISED + close *(recommended)*; (b) silent close. **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** §8.1 l.987-996. Matches (a), built as `CalleeConn.beginTermination` and `finishTermination`: new Requests get a committed response-err NOT_AUTHORISED without dispatch, subscriptions end and nothing more is published, then ProtocolError NOT_AUTHORISED with no message or detail, and close. Termination waits for no Request and reads no unread one. The choices the spec leaves open are I57. Tests `[TRN-0321]`..`[TRN-0324]`.

### G36 — Schema-invalid response-ok or Event
- **Kind:** GAP · **Specs:** TRANSPORT §4.1 (receiver validates against the declared type and compares
  roots; a mismatch is ProtocolError + close); SECURITY §8 (fail closed).
- **Options offered:** (a) fail closed: ProtocolError INVALID_PARAMS, close the provider session, the
  waiting caller gets TRANSPORT_ERROR *(recommended)*; (b) reject only that message.
- **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** §4.1 l.674-679: ProtocolError INVALID_PARAMS and close, even when no commitment can be recomputed; pending calls get TRANSPORT_ERROR. Matches (a). The test now covers an Event too: `[TRN-0097] [TRN-0300]`.

### G37 — Schema check vs commitment check on a Request
- **Kind:** GAP · **Specs:** TRANSPORT §4.1 (sentence order: validate, recompute, compare; no explicit
  precedence, unlike §8.3 for Hello); RUNTIME §4.1 (validation and hashing may be combined).
- **Description:** A Request that is schema-invalid and whose subtree root is also wrong could get
  response-err INVALID_PARAMS (session kept) or ProtocolError + close.
- **Options offered:** (a) schema first *(recommended)*; (b) commitment first.
- **Decision:** (b) commitment first: any root mismatch closes the session.
- **Settled 2026-11-10 (6a4dfa28), restated:** §4.1 l.655-673 fixes the order: (1) envelope, correlation, method resolution and the access scope; (2) the subtree root, where a mismatch closes; (3) the schema, where a Request gets response-err INVALID_PARAMS and the session stays while a response-ok or Event closes; (4) the value root of the validated value, where a mismatch closes. Untyped CBOR is never hashed. Only the subtree root precedes the schema check, so "any root mismatch closes first" overstated (b); the code already followed this order. Tests `[TRN-0292]`..`[TRN-0298]`.

### G58 — Socket layout
- **Kind:** CONTRA (settled by RUNTIME l.316-317 at 6a4dfa28) · **Specs:** RUNTIME §1.3 (the module name drives `<runtime-dir>/logos_<name>.sock`) vs
  TRANSPORT §8.2 (Runtime creates a 0700 directory per instance, binds and listens, transfers the
  listener; callers check the peer's OS identity before sending the ticket); sun_path limits (104 bytes
  on macOS, 108 on Linux).
- **Options offered:** (a) a per-instance 0700 directory containing the §1.3 name:
  `<short base>/<8-hex>/logos_<name>.sock`, placement fails if the path doesn't fit, peer check by euid,
  Module Hosts run as the daemon's uid *(recommended)*; (b) RUNTIME §1.3 literally, one hosted instance per
  name. **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** NR-14 (TRANSPORT §8.2 l.1107-1111): Module Hosts that run as the daemon's uid cannot claim protection from one another. Before Tier 4, decide whether we claim same-identity protection (a distinct OS identity per host, or the placement fails) or document that we do not. Unchanged for Tier 3.
- **Decided 2026-11-10 (owner: "proceed with your recommendations"):** we do not claim protection between processes of the same OS identity. Module Hosts run as the daemon's uid, as (a) placed them; TRANSPORT §8.2 l.1107-1111 lets a deployment that makes no such claim keep that layout, and `docs/CONFORMANCE.md` states the non-claim. A distinct OS identity per host stays possible later without changing the socket layout.
- **Settled 2026-11-11 (review against 6a4dfa28, item B6):** the layout question itself is settled by RUNTIME l.316-317: the module name derives local socket names inside the protected per-instance directory of TRANSPORT §8.2 (example `<instance-dir>/logos_<name>.sock`), and the concrete pathname is implementation-defined and subject to the host's pathname limit. Settled as (a) chose (C-06).
- **Runtime-served endpoints 2026-11-13 (I90, G257):** the endpoint the Runtime serves for a direct provider uses the same layout, `<runtime.endpoint_dir>/<8 hex>/logos_<module>.sock` (default `<work_dir>/endpoints`), the base 0700 and owned by the Runtime's uid, checked at start.

### G107 — Local transport on Windows
- **Kind:** GAP · **Specs:** TRANSPORT §8.2 l.947, §9.1 l.1135 (`logos.local.unix-stream` is mandatory
  where the OS supports Unix-domain stream sockets — Windows 10 1803+ does), l.956 (listener transfer),
  l.967 (an equivalent peer-identity mechanism); "0700 on POSIX filesystems" does not cover NTFS.
- **Description:** chronos maps "Unix" sockets to named pipes on Windows, which are not Unix-domain
  sockets. Windows AF_UNIX has no socketpair or SCM_RIGHTS; PID-based peer checks race with PID reuse.
- **Options offered:** (a) our own AF_UNIX/IOCP transport: peer check via `SIO_AF_UNIX_GETPEERPID` plus a
  token-SID comparison while holding the host's process handle, owner-only DACL directory, listener by
  handle inheritance, spike first *(recommended)*; (b) direct placement on Windows.
- **Owner's answer:** "let's use AF_UNIX on windows. We can adapt chronos (fork + upstream PR) to it if
  needed".
- **Decision:** (a), via a chronos fork with an upstream PR if needed.
- **Revised 2026-11-10 (6a4dfa28):** direction confirmed (§8.2.1 l.1148-1172; §9.1 l.1369), with more requirements: non-null DACLs with no permissive inheritance, an `IO_REPARSE_TAG_AF_UNIX` check, restricted handle inheritance or targeted Winsock sharing, and per-version qualification of `SIO_AF_UNIX_GETPEERPID` attribution (l.1170-1171) before support is claimed. Until then Windows local placements fail (l.1152). No Tier 3 code.
- **Revised 2026-11-11 (review against 6a4dfa28, item B15):** two points the note above leaves out. TRANSPORT l.1163-1166: before connecting, the caller's protected context must hold an independently authenticated reference to the expected listener's process object and keep its handle from before connection through peer verification; opening a process only from an identifier learned from the connection MUST NOT establish that reference, and the listener handoff must authenticate the target process (l.1160). (a)'s "while holding the host's process handle" therefore needs a handle obtained independently of the connection, such as the one from launching the host, not one opened from the PID the socket reports. And the profile is optional on Windows: an implementation MAY support it only where it meets these requirements (l.1150-1151; §9.1 l.1369), not mandatory as the Specs line says.
- **Revised 2026-11-17 (step 5-4, I100):** the spike is done: AF_UNIX on Windows meets §8.2.1 for placement
  `process` on the three measured builds, under G332's reading of T l.1156, with **no chronos fork**
  (G329). The design is G329-G333; step 5-9 builds it. Until then Windows still fails closed (T l.1152;
  `tests/test_windows_profile.nim`).

### G108 — Private channel between the daemon and a module host
- **Kind:** FREE · **Specs:** LOADER §5.4 l.330 ("Channel setup and descriptor transfer are determined by
  the implementation"); RUNTIME §4.2.1 l.880-888 (the hosted module's RC binding travels over a
  realization-internal protected carrier; the consumer comes from protected launch state).
- **Options offered:** (a) one inherited socketpair per host (an AF_UNIX pair / duplicated socket on
  Windows) carrying RC in Transport-envelope form and Loader control in a separate CBOR framing; no
  ticket; never in public records *(recommended)*; (b) a second per-instance unix socket with its own
  ticket. **Decision:** (a).
- **Note:** asked as a GAP; re-labelled FREE at the final review because LOADER §5.4 delegates it.
- **Revised 2026-11-17 (G331, step 5-4):** on Windows the carrier is a connected AF_UNIX pair made by
  listen, connect and accept in the per-instance protected directory, its path deleted at once, one end
  inherited through the handle list (measured: `tools/winprobe`, Q12).

### G329 — The event loop for AF_UNIX on Windows
- **Kind:** FREE (Tier 5 plan A8; G107) · **Specs:** TRANSPORT §8.6 (limits that stay enforceable).
- **Description:** the transport loop drives raw sockets by readiness (`selectors2`, `addReader2`); chronos
  4.4.1 on Windows is an IOCP loop with no readiness calls. Four ways through its exported API were
  measured (`tools/winprobe/loopprobe.nim`, I100): (a) overlapped I/O, (b) zero-byte reads, (c)
  `WSAEventSelect` with `registerWaitable`, (d) `IOCTL_AFD_POLL`. All four work on the three measured
  builds; (c) and (d) at the documented limit of 2048 connections in one process.
- **Decision (step 5-4; reviewed by the Fable session, 2026-11-16):** variant (c). Per socket,
  `WSAEventSelect` (`FD_READ`, `FD_WRITE`, `FD_CLOSE`, `FD_ACCEPT`, `FD_CONNECT`) on an auto-reset event,
  waited by `registerWaitable(…, WT_EXECUTEINWAITTHREAD, InfiniteDuration, …)`; `WSAEnumNetworkEvents` in
  the callback, the existing try-until-WOULDBLOCK code on top, so `conn`, `caller` and `callee` are
  shared. Every accepted socket gets its own `WSAEventSelect` before its first read, since it starts
  with the listener's event and mask. **No chronos fork** (A8).
- **The coupling:** chronos 4.4.1 exports `registerWaitable`, `closeWaitable`, `WaitableHandle`,
  `PtrCustomOverlapped`, `CompletionData.udata`, `getThreadDispatcher`, `poll` and `ThreadSignalPtr`, and
  calls `registerWaitable` "a private procedure" in its own source. The lock file holds the version; the
  Windows leg's `loopprobe` checks the symbols on every run. **We move off it** when an update drops or
  changes one of them, or `loopprobe` shows a change: then our own wait threads over
  `WaitForMultipleObjects`, waking the loop through `ThreadSignalPtr`; (a) is the last resort; (d) rests
  on an undocumented IOCTL and is not used.
- **Status:** decided; built by step 5-9.

### G330 — Peer attribution and the expected process on Windows
- **Kind:** FREE (G107) · **Specs:** TRANSPORT l.1111, l.1129, l.1131, l.1163-1171.
- **Description:** measured on every measured build (I100): `SIO_AF_UNIX_GETPEERPID` on the caller's
  socket names the process that created, bound and listened on the listener, never the acceptor, in
  every transfer variant and timing, and keeps naming it after it has ended.
- **Decision (step 5-4; reviewed by the Fable session):** the expected process object for every
  unix-stream endpoint on Windows is **logosd's**, since logosd creates every listener (T l.1122). Each
  caller holds a `PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE` handle to logosd for its life (a
  Module Host by the handle list at launch; logosd its own process). Before Hello: (1) `GETPEERPID`
  equals that handle's pid; (2) the handle is not signalled, read from the handle because the query
  keeps naming an ended process (T l.1168); (3) the token user SID equals the expected Runtime user SID.
  Any failure closes before Hello as the peer-verification failure of §8.2, TRANSPORT_ERROR (T l.1131,
  l.1168); on a build G333 lists, a diagnostic says the attribution did not match. The identity
  compared is the token user, the counterpart of T l.1129's user check; check (1) admits one process,
  not any of the user's. Elevation and integrity are recorded, not compared. **What it proves:** that
  logosd created the listener, not which process serves it (T l.1111); a path redirected to another
  listener logosd created would pass, which takes the Runtime's identity or an administrator: the
  same-identity case of G58, no finer on POSIX. While logosd is down, new connections fail closed.
- **Status:** decided; built by step 5-9, on G333's builds only.

### G331 — Listener transfer and handle hygiene on Windows
- **Kind:** FREE (G107, G108) · **Specs:** TRANSPORT l.1159-1161.
- **Decision (step 5-4; reviewed by the Fable session):** at launch the listener goes to the Module Host
  by `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`, with the G108 carrier end and the logosd handle; never
  inherit-all. To a running host, `WSADuplicateSocketW` targeted at a host whose process handle logosd
  has held since creating it, the `WSAPROTOCOL_INFOW` sent over that host's carrier (measured: the
  handle list leaks nothing unlisted; the sharing record gives a third process nothing and the target
  nothing a second time). G108's Windows carrier as noted there.
- **Status:** decided; built by step 5-9.

### G332 — Filesystem protection of Windows endpoints
- **Kind:** Reading and FREE (G107, G58) · **Specs:** TRANSPORT l.1107-1109, l.1119, l.1125, l.1129,
  l.1152, l.1154-1157.
- **Decision (step 5-4; reviewed by the Fable session; reading decided by the owner, 2026-11-17, item
  6):** **volume:** when the endpoint base is created, its volume is read once, and a volume without
  persistent ACLs or reparse points, or on a network redirector, fails the placement (T l.1152).
  **Directory:** per instance under `<work_dir>/endpoints`, its owner set to the Runtime's user and a
  protected DACL `D:P(A;OICI;FA;;;<runtime user>)`. **After `bind`:** the socket object's owner and
  protected DACL set the same way, and its file id recorded. **Validation (T l.1125, l.1157):** the
  reparse tag `IO_REPARSE_TAG_AF_UNIX`, the file id, the owner equal to the Runtime's user under any
  token, the endpoint's final path equal to the expected path's own final path (case and 8.3 names
  alias; the runners' `TEMP` is an 8.3 path), and every ancestor from the trusted root down not a
  reparse point and giving delete, delete-child, change-security or ownership rights to no one but
  SYSTEM, Administrators, TrustedInstaller and the Runtime's user. Paths are compared by object, never
  as strings. logosd and Module Hosts do not run with SeBackup or SeRestore enabled, which bypass every
  DACL check. **T l.1156 reading (i)** (owner): one OS user is not a security boundary (G58's non-claim);
  a consumer that is the Runtime's own user holds the other rights as that user, not through the entry
  that grants use, and CONFORMANCE's same-identity non-claim covers Windows in the same words.
- **Status:** decided; built by step 5-9.

### G333 — The Windows builds the profile is offered on
- **Kind:** Reading (G107; the comments document's candidate on T l.1170 and l.1165) · **Specs:**
  TRANSPORT l.1152, l.1170-1171.
- **Decision (owner, 2026-11-17, item 7; drafted by step 5-4, reviewed by the Fable session):**
  unix-stream is offered on Windows only on a build whose facts are committed under
  `tools/winprobe/facts/`, keyed by **the OS build number with the `afunix.sys` build number**. The
  patch level (UBR) and the driver's full version are recorded per qualification run, not keyed; the
  Windows leg's probe step reports any change of facts on its runners. **Why a coarse key is safe** (T
  l.1171): G330 compares the query with one process object held beforehand, so an update that moved
  attribution would make connections fail closed, never accept the wrong process. Every other build is
  refused and fails closed (T l.1152), Windows 10 included. A build is added by running the probe there
  and committing its facts. Measured: 26200 (`afunix.sys` 26100), 26100, 20348.
- **Status:** decided; the build check is step 5-9's.

---

### G165 — Oversized Event from a publish callback with no result channel
- **Kind:** CONTRA · **Specs:** TRANSPORT §2.1 l.389 (an Event too large for the peer: "Its publication
  boundary MUST report failure where that boundary permits it; otherwise the sender MUST send
  ProtocolError `TRANSPORT_ERROR` when writable and close the affected connection") vs RUNTIME §7.3
  l.1226-1227 (`logos_publish_fn` has no result channel, so Runtime records the failure as a diagnostic
  and drops the event).
- **Description:** A module publishes, through the void `logos_publish_fn`, an Event too large for
  one subscriber's peer maximum. TRANSPORT closes that subscriber's connection; RUNTIME drops the event.
- **Options offered:** (a) the RUNTIME drop covers validation failures (l.1225); an oversized Event
  closes that subscriber's connection with ProtocolError `TRANSPORT_ERROR` *(recommended)*; (b) drop
  and log, and keep the connection.
- **Decision (owner, decision 12, 2026-11-13):** (a), as an interim until the TF-06 note is answered:
  an oversized Event from `logos_publish_fn` closes that subscriber's connection with ProtocolError
  `TRANSPORT_ERROR` (`tlClose`); the scoped `publish`, which can report, reports it (`tlReport`). Tier 3
  built the typed `PublishError(peTooLarge)`; the adapter comes with transported events (I90, part
  4b-2c).
- **Built 2026-11-13 (I90, part 4b-2c):** `events.publishOp` sends each transported subscriber
  connection its Event with `cmdPublishConn` and `tlClose`: an Event over that peer's frame maximum
  commits nothing there and closes the connection with ProtocolError `TRANSPORT_ERROR`; the other
  subscribers, direct or transported, still get it. The consumer's handle observes TRANSPORT_ERROR
  and the route stays `ready` (G256). A scoped publication over a session uses `tlReport`: the
  verdict `peTooLarge` is MODULE_ERROR. `test_transported` (the `bulk` kit module, a 17 MiB Event).
- **Reported:** as a note in the editorial item TF-06 of `claude-spec-comments-3.md` (logos-lips `68628d95`), not
  as a contradiction: it reads RUNTIME l.1225-1227 as covering events that fail validation and TRANSPORT
  l.388-389 as governing size, which is option (a), and asks RUNTIME to say that its drop covers
  validation failures only.

### G323 — The signing seam: what a TLS signer signs, and where that is checked
- **Kind:** FREE · **Specs:** TRANSPORT §8.4.1 l.1237-1239 (mutual authentication, P-256 with
  `ecdsa_secp256r1_sha256`); owner decision B1 (2026-11-16: a signing seam in the carrier, logosd signs
  by default, a key-holder process is the hardened setup, a key in each TLS process is for tests only).
- **Description:** under B1 the TLS processes do not hold the TLS key: each CertificateVerify is signed
  by another process. What may a signer be asked to sign, and who checks it?
- **Decision:** the library's `checkSignInput` (`transport/tls/signing.nim`), applied by every signer at
  the end that holds the key: the algorithm is `ecdsa_secp256r1_sha256` and the input is a TLS 1.3
  CertificateVerify content for the signer's role (64 octets of 0x20, `TLS 1.3, client
  CertificateVerify` for a facade process or `server` for a listener process, a zero octet, a 32- or
  48-octet hash). The role is the one the signing channel was made for, never one a request names; the
  bound on requests in flight is the wrappers' (5-7a). A process that takes over a TLS process gets
  signatures for its role while it holds its channel, never the key. The engine waits for the
  `Signer` without blocking its event loop, and drops a cancelled request's late answer. The key in the
  process (`testsigner.nim`, `keySigner`) is a D27 test hook.
- **Status:** decided 2026-11-17 by step 5-2 (plan `tier5-plans/step5-2-tls.md` §3.5); built in part
  5-2b (I99). The signing channel, logosd's signing service and the key-holder program are 5-7a's; the
  service also counts signatures per channel, as a diagnostic (Fable's check, 2026-11-18).

### G324 — Which certificates the tls-tcp verifier accepts
- **Kind:** READING, under owner decision B2 · **Specs:** TRANSPORT §8.4.1 l.1248-1250, l.1258-1267;
  RUNTIME l.2680, l.2723.
- **Description:** RFC 5280 path validation under the enrollment's anchor and protected certificate
  policy (l.1258), with revocation evidence for every non-anchor certificate (l.1265). B2 (owner,
  2026-11-17, approved as written) makes each Runtime's credential a self-signed certificate held as a
  direct anchor, and accepts no certificate that is not itself an anchor.
- **Options offered:** (a) a direct anchor only: one certificate, DER-equal to the enrollment's anchor;
  any other chain fails, as a certificate whose status cannot be established under a policy that
  defines no revocation evidence (l.1265, l.1267) *(recommended)*; (b) CA anchors with path validation
  and a revocation policy.
- **Decision:** (a). The verifier (`transport/tls/verify.nim`) runs nine checks in a fixed order and
  reports the first that fails: accepted time (G325); one certificate; the enrollment (as client the
  expected Runtime's current record is `active`, as server exactly one current record holds the key and
  it is `active`; a `conflicting` record holds both records' keys); the SPKI among the record's keys;
  complete DER equality with the anchor; the validity period at accepted time, also for the direct
  anchor (l.1259); Key Usage, when present, permitting digital signatures; Extended Key Usage, when
  present, naming the peer's role, `anyExtendedKeyUsage` alone failing (l.1262-1263); and [IMPL] no
  critical extension outside BoringSSL's processed set (RFC 5280 §4.2). The anchor's self-signature is
  not checked: the anchor is protected input and DER equality decides (l.1260). Proof of possession is
  TLS's CertificateVerify (l.1264). Two rules are this implementation's policy, stricter than the text:
  the anchor followed by an extra certificate fails, though the extra one is not on the path; and a
  caller, too, fails a target whose key another Runtime's current record holds (l.1253 stands in the
  paragraph on inbound callers).
- **Limits (Fable's check, 2026-11-18):** (1) key rotation has no overlap: an enrollment names one
  anchor and a direct anchor has one key, so a second key in the record (RUNTIME l.2701) can never pass;
  rotation is a new anchor, a higher anchor-set revision and a higher enrollment revision, taken up at a
  restart (B3). (2) Renewing a certificate with the same key needs no enrollment revision (RUNTIME
  l.2703), but the new certificate is a new anchor, so every peer needs a higher anchor-set revision
  (l.2718-2722), and a Runtime stops being reachable when its anchor's validity ends. (3) An enrollment
  under a CA anchor is a valid record that never authenticates: it fails closed, and 5-7a's loader
  reports an active record whose anchor's key is not among its keys.
- **Status:** decided 2026-11-17 with B2; built in part 5-2a (I99).

### G325 — Accepted current time for the tls-tcp verifier
- **Kind:** FREE · **Specs:** TRANSPORT §8.4.1 l.1259 ("using accepted current time"), l.1267
  ("Authentication MUST fail if the required time or status cannot be established").
- **Options offered:** (a) the system clock, refused below a floor in the source *(recommended)*; (b) the
  clock alone; (c) time from protected input (no such input exists).
- **Decision:** (a). `verify.systemClock` reads the system clock and refuses a reading earlier than
  `TimeFloor` (2026-11-17T00:00:00Z, the date of part 5-2a; later steps raise it); a clock that cannot
  be read or reads below the floor fails authentication as time that cannot be established. The floor
  catches a clock reset to the epoch, not one a few days off; B2's long validity keeps that small.
- **Owed by 5-7a (Fable's check, 2026-11-18):** before a remote surface can be enabled the deployment
  document states this time assurance (RUNTIME l.3037), and says whether certificate validity, decision
  expiry and route deadlines share one accepted clock (l.3034).
- **Status:** decided 2026-11-17 by step 5-2 (plan §3.4); built in part 5-2a (I99).

### G326 — The tls-tcp carrier's TLS parameters
- **Kind:** FREE · **Specs:** TRANSPORT §8.4.1 l.1235-1239, l.1271-1272, l.1296; RUNTIME l.1978-1984.
- **Decision:** TLS 1.3 as both minimum and maximum (l.1235-1236); a client certificate requested and
  required (l.1237); `ecdsa_secp256r1_sha256` the only signature algorithm signed or accepted
  (l.1238-1239); key exchange groups X25519MLKEM768 (the pinned BoringSSL's default), X25519 and
  secp256r1 in that order, so a peer without the hybrid group still meets RFC 8446 §9.1's; BoringSSL's
  fixed TLS 1.3 cipher suites; no tickets, no session cache, no early data (l.1296); no ALPN (the
  `tls-tcp` address has no `alpn`); a client sends `server_name` as SNI `host_name` only when the address
  has one, after checking it is an LDH DNS name of at most 253 octets and not an IP literal (l.1271); a
  server reads SNI and selects nothing by it (l.1272); no certificate-authorities list.
- **A recorded limit (Fable's check, 2026-11-18):** verifying only `ecdsa_secp256r1_sha256` is narrower
  than RFC 8446 §9.1, which also names `rsa_pss_rsae_sha256`. Kept: no RSA peer exists, B2's credential
  is P-256, and l.1238 has enrollment select algorithms its intended peers support. A peer enrolled with
  another key type can never be verified, so 5-7a's loader reports an enrolled key that is not P-256.
- **Status:** decided 2026-11-17 by step 5-2 (plan §3.3); built in part 5-2b (I99).

### G327 — The TLS library's plaintext buffers
- **Kind:** owner question · **Specs:** INTERFACE l.381 (owned temporary buffers holding payload data
  erased before release or reuse), l.388-393 (no path for a marked payload unless its participants
  support that; library buffers are named).
- **Description:** step 5-2's spike (`tier5-plans/step5-2-spike.md` §7) showed that the pinned
  BoringSSL frees each decrypted record unerased (16 of 16 records of a 256 KiB transfer): records are
  opened in place in the connection's read buffer, which upstream allocates with `malloc` and releases
  with `free`, so it is never zeroed: BoringSSL c0e15d1d (2017) introduced zeroing in `OPENSSL_free` and,
  in the same change, moved this buffer from `OPENSSL_malloc` to plain `malloc`/`free` to keep the new
  cost off a hot path.
- **Options offered:** (a) keep G277's refusal of marked contracts on remote paths, no patch; (b) carry
  the erasure in the library through a branch of nim-boringssl's BoringSSL fork, raised upstream; (c) a
  zero-on-free `free` in the TLS programs.
- **Decision (owner, 2026-11-17):** (b), fix the erasure in the library rather than refuse for good:
  "let's put the zeroing in a nim-boringssl branch, we'll raise a PR in nim-boringssl to upstream the
  change". **Revised the same day (owner): an option, off by default,** so that other consumers of
  nim-boringssl (nim-libp2p and others) see no change. With `BORINGSSL_ZERO_RECORD_BUFFERS` defined, the
  BoringSSL fork allocates the record buffers (`ssl/ssl_buffer.cc`) with `OPENSSL_malloc`, so
  `OPENSSL_free` zeroes them, which upstream never did for this buffer; without it the code is
  upstream's. nim-boringssl turns its booldefine `BORINGSSL_ZERO_RECORD_BUFFERS` (false by default)
  into that define as `BORINGSSL_USE_ASM` turns into `OPENSSL_NO_ASM`, and exports
  `boringsslZeroRecordBuffers` so a consumer can tell which build it got. The fork carries the change as
  a second local patch the weekly upstream sync replays; nim-boringssl moves its submodule. Draft PRs,
  opened on the owner's go-ahead: https://github.com/iftech/boringssl/pull/13 (the fork) and
  https://github.com/iftech/nim-boringssl/pull/26 (option, test, version; depends on #13). Freed blocks
  holding plaintext: 16 with the default (as stock), 0 with the option. On the Mac (M1 Max, both ends
  in one process, AES-GCM with assembly, 16 KiB records): the default build matches stock; the option
  costs nothing measurable on handshakes and about 2.5 % of bulk throughput.
- **Done in part 5-2d (2026-11-17).** Both PRs merged; nim-boringssl 0.0.16 released (tag `c3161dc2`,
  its BoringSSL the fork's `b8b94f8e`: upstream `26584e7a` with the option) and pinned, from its new
  home `https://github.com/iftech/nim-boringssl`. `config.nims` sets `-d:BORINGSSL_ZERO_RECORD_BUFFERS=true`,
  which every build reads (nimble's tasks, the flake's checks, the Android suites). `boring.nim` gives
  `recordBuffersErased` (nim-boringssl's `boringsslZeroRecordBuffers`, false when the binding does not
  declare it). The carrier erases its own copies of decrypted data: `TlsStream`'s read buffer, a
  partial frame and frames not taken, at release; a frame is read into a body allocated at its declared
  length, so it never grows; `writeFrame` seals a body before it returns and erases the framed copy;
  and a frame read is handed over as a `TlsFrame` reference, so no future keeps a copy (an earlier
  version that returned the bytes by value left one copy per frame in the future, found by the free
  scan). `carrierErases()` is `recordBuffersErased`; a stream configured to carry marked payloads
  (`TlsConfig.carriesMarked`) is refused by `connect` and `serve` unless it holds, with G277's message
  (`requireErasure`). `test_remote_tls` runs as an audit build (`test_remote_tls.nims`) and shows no
  released block holding the plaintext after 256 KiB through two streams (16 with the option off,
  which the suite also catches by its first erasure case).
- **Still to do (5-7a):** the facade and listener processes' own erasure, and the remote route kind,
  whose `erases` stays false until then: G277's refusal of marked contracts on remote paths stands. A
  remote path may carry a marked payload only where `carrierErases()` and the processes' erasure both
  hold.

### G328 — When a TLS 1.3 peer has completed the mutual-authentication handshake
- **Kind:** READING · **Specs:** TRANSPORT §8.4.1 l.1240-1241 ("before sending or accepting a
  Transport Hello"), l.1297-1298.
- **Description:** in TLS 1.3 a client's handshake completes once it has verified the server and sent
  its Finished; the server checks the client's certificate after that. A client therefore holds an
  established connection before it knows whether the server accepted it.
- **Decision:** (a) each peer has completed the handshake when its own TLS handshake completes; the
  client has validated the server before it sends its Hello, and the server reads no Transport data
  until its own check passed, so a refused client's frames are never read and its first read fails.
  The alternative, the client waiting for a first server message, needs a round trip the spec does not
  define (the caller speaks first in TRANSPORT §3).
  A server sends no Transport data before its own check passed. In 5-7 the caller's session is
  established at the Hello reply (RUNTIME l.783), never when `connect` returns.
- **Status:** decided 2026-11-17 by step 5-2 (plan §3.7); Fable's check of 2026-11-18 finds the reading
  sound and no D9 stop; built in part 5-2b (I99; `test_remote_tls` "[TRN-0220] … [IMPL-DECISION G328]"
  and "[TRN-0221] [IMPL-DECISION G328] a server sends no Transport data before its check passed").

## 6. Runtime, lifecycle and system services

### G48 — Engine-originated calls that have no module consumer
- **Kind:** GAP · **Specs:** RUNTIME Terminology (every consumer is a module instance; the engine is
  outside the participant model), §9 l.1499 (startup realizes orchestration), l.1640 (Runtime-internal
  coordination "MUST NOT be represented using a fabricated consumer reference"), §10.2; BCP §5.1;
  TRANSPORT §3.1 (a Hello needs a consumer-bound ticket).
- **Description:** Bootstrap realization of the orchestrator, releases during shutdown and CA `evaluate`
  calls are made by the engine for no module.
- **Options offered:** (a) the Loader and the CA always run direct in-process; the engine invokes them
  through its enforcement boundary under bootstrap policy, never over Transport *(recommended)*; (b) a
  synthetic engine consumer identity. **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** RT-02: Runtime-owned system-service bindings (RUNTIME l.1652-1679); local system-service tickets last at most 60 s (TRANSPORT §8.1.2). Matches (a) in its direct-binding form.
- **Built 2026-11-13 (I89, part 4b-1c):** the Module Loader is bound directly, a Runtime-owned
  system-service binding: the engine's calls into it carry a SYSTEM_SERVICE context, and the Loader
  serves only those (G251).

### G53 — Names of the orchestration and CLI modules
- **Kind:** GAP · **Specs:** RUNTIME §1.3, INTERFACE §1.3 (`logos_` reserved for Logos-defined runtime
  and system modules); BCP §5 (assigns names to PM, Loader, CA, Runtime Control only).
- **Options offered:** (a) `orchestrator` + `logosctl`, asking the author whether orchestration should get
  a `logos_` name *(recommended)*; (b) `logos_orchestrator` + `logosctl`. **Decision:** (b).
- **Revised 2026-11-10 (6a4dfa28):** RT-03: orchestration has no canonical name (RUNTIME l.190-192), and `logos_` is reserved for Logos-defined runtime and system modules (l.310). `logos_orchestrator` must be renamed outside the prefix or dropped. To be re-decided with D13.
- **Re-decided 2026-11-11 (owner: "Add the denying test authorizer, otherwise go with your recommendations"):** no orchestration module name. The host's protected bootstrap input
  names the instance that holds the orchestration role (RUNTIME l.187-192), under any module name that
  conforms to INTERFACE §1.3 and does not start with `logos_`; no name confers the role or its authority.
  The tests use a static `test_orchestrator` module. logosd's default orchestration instance is chosen
  with Tier 4b; the CLI module stays `logosctl` (D13). **Status:** decided.
- **Built 2026-11-11 (I81):** the host configuration's `orchestration` field names the instance; the
  bootstrap creates every configured instance and starts only that one (RUN-0309, RUN-0784).
- **Built 2026-11-13 (I94, part 4b-5b):** the reference orchestration module is `lcn_orchestrator`, a host-named
  instance whose name confers nothing; logosd's default orchestration instance is one (decision 8),
  from step 4b-6.
- **Built 2026-11-15 (I95, part 4b-6a):** logosd's orchestration instance is `orchestrator`, of
  `lcn_orchestrator` (G294).

### G54 — What `list_modules` shows
- **Kind:** spec-resolved · **Specs:** RUNTIME l.164 (system services are ordinary records), l.2963-2964
  (what list_modules returns); Runtime Control is intrinsic, not a module instance.
- **Options offered:** (a) Runtime Control never listed; system instances listed under observation policy
  *(recommended)*; (b) Runtime Control as a synthetic record. **Decision:** (a).
- **Settled 2026-11-11 (review against 6a4dfa28, item B12):** RUNTIME l.169 (system service instances keep ordinary provider and lifecycle records), l.3351-3355 (`list_modules` returns the runtime-known records visible to the caller: local providers, local instances and local facades) and l.73, l.1602 (Runtime Control is intrinsic to the Runtime, not a module instance). Settled as (a) chose; the outcome table listed it without a note.

### G55 — Choosing the installed package for a module name
- **Kind:** GAP · **Specs:** RUNTIME §9.3 (`create_module_request = {request_key, module}` is closed;
  "Runtime MUST select one accepted declaration … under active policy or fail"; the selection is retained
  and never re-inferred from inventory or newer packages); PM §5, §11 (several versions may be installed;
  nothing forbids two packages declaring one module); CA §3.3 (module_execution_scope may carry
  package/version).
- **Options offered:** (a) highest installed normal release; two different packages declaring the module
  fail without disclosure; an explicit pin is a CA module_execution_scope grant *(recommended)*; (b) highest
  release, no pinning. **Decision:** (a). The bootstrap pin counts as one candidate (G92).
- **Revised 2026-11-10 (6a4dfa28):** RT-04: package selection is protected deployment policy with exact package and version pinning; no substitution and no `create_module` selector (BCP l.367; RUNTIME §9.3, l.3616-3622); starting an instance uses its retained declaration (l.3637). (a) "highest installed release" is withdrawn.
- **Re-decided 2026-11-11 (owner: "Add the denying test authorizer, otherwise go with your recommendations"):** exact pins in protected deployment input. For each module name the
  deployment names exactly one package and version: the protected daemon configuration (G76) and the
  bootstrap registrations compiled into the binary (section 13). `create_module` for a module name without
  a pin, or whose pinned package is not installed and accepted, fails without disclosure. Nothing is
  inferred from inventory. Changing a pin is a protected configuration change and affects only instances
  created afterwards; start and recovery keep the retained declaration (l.3637). The first Tier 4 slice
  takes records only from host registration (RUNTIME §13.3) and test harnesses; the pin table arrives with
  the Package Manager handoff. **Status:** decided.
- **Revised 2026-11-11 (review against 6a4dfa28, item A8):** adds to the 6a4dfa28 note, which withdrew
  only "highest installed release". Two more parts of (a) go with it: "an explicit pin is a CA
  module_execution_scope grant", because "A package constraint in an authorization scope restricts
  selected facts; it does not select, install, or replace an implementation" (RUNTIME l.3620); and "The
  bootstrap pin counts as one candidate", which has no meaning when protected selection names one exact
  package and version and an unavailable one fails without substitution (l.3616-3617). The re-decision
  above already starts from protected deployment input as the only selector.
- **Built 2026-11-12 (I82):** for direct records, the pin carrier is the host configuration's
  `declarations` (`logos-core-nim.app-config.v1`): one accepted declaration per module name, protected
  input like the configured modules (BCP l.367). `create_module` for a name with no declaration fails
  without disclosure as a non-revealing NOT_AUTHORISED (G195). A created instance keeps its record;
  a changed declaration affects later creations only (l.3621). The package-backed pin table still
  arrives with the Package Manager handoff, in Tier 5 (owner decision 1 (a), 2026-11-13; I97).

### G56 — Module hosts orphaned by a failed Loader
- **Kind:** GAP · **Specs:** LOADER §7 (realization ids are scoped to the issuing provider; no adoption
  rule); RUNTIME §10.1 (a module failure does not terminate the Runtime), §10.2 step 5 (forced cleanup by
  the Runtime host or deployment mechanism).
- **Options offered:** (a) the daemon kills the orphaned hosts, their instances become `error`, the
  orchestrator recovers them through the new Loader *(recommended)*; (b) ask the spec author.
- **Decision:** (a).
- **Settled 2026-11-11 (review against 6a4dfa28, item B12):** RUNTIME l.3820-3825: Loader loss is not a release; when the owning Loader has failed and control cannot be kept, Runtime marks the instances `error`, fails their routes, preserves intent and arranges termination through protected supervision (l.3823), and rebinding transfers nothing (l.3825; LOADER l.476-477). Settled as (a) chose, with two conditions: no replacement is realized until the deployment mechanism confirms that the old execution envelope and its state access have ended (l.3821-3822, l.3824); and temporary unavailability of the Loader is not failure, so it does not change healthy instances' state (l.3816-3818, l.3827). The remark on RT-05 in `claude-spec-comments.md` (logos-lips `68628d95`) asks what tells the two cases apart.
- **Built in-process 2026-11-13 (I89, part 4b-1d):** for direct realizations, as RUNTIME l.3820-3825
  says, with the host ending its process (G249); with Module Hosts, 4b-3.

### G57 — How the bootstrap Loader reports its own realization
- **Kind:** spec-resolved · **Specs:** RUNTIME l.3060-3061 ("Other realization mechanisms MUST use
  implementation-specific").
- **Options offered:** (a) `implementation-specific` *(recommended)*; (b) `direct_static`.
- **Decision:** (a).
- **Settled 2026-11-11 (review against 6a4dfa28, item B12):** RUNTIME l.3527-3528: the implementation record reports the Loader strategy and hosted placement, and "Other realization mechanisms MUST use `implementation-specific`". Settled as (a) chose.
- **Built 2026-11-13 (I89, part 4b-1c):** a bootstrap mechanism whose only registration is the
  Loader's realizes the Loader instance, whose summary reports `implementation-specific`; every other
  instance reports the strategy the Loader realized it with.

### G61 — Timeout defaults
- **Kind:** FREE · **Specs:** TRANSPORT §8.1.1 (tickets ≤ 60 s), §6 (a timeout can only send Cancel and
  accept the single committed response); RUNTIME §6.2 (a hosted startup timeout is mandatory, value
  free), §9.3, §10.2, §13.2.
- **Options offered:** (a) Hello 10 s; route call 30 s then Cancel and TIMEOUT; hosted startup 120 s; stop
  drain 10 s; shutdown grace 10 s per realization then force-release; Ctrl-C during start queued until start
  returns *(recommended)*; (b) the same without a default call timeout. **Decision:** (a), all in the
  deployment profile and overridable.
- **Revised 2026-11-10 (6a4dfa28):** NL-11: CONFIG makes an application deadline mandatory (l.269-275). Add it to the timeout set.
- **Revised 2026-11-11 (review against 6a4dfa28, item A18):** three parts of (a) do not fit the text. Startup: RUNTIME l.664 requires a finite startup deadline, with its start point and phases documented, for each supported realization, not only hosted ones; on expiry, native initialization still running MUST NOT be destroyed or unloaded concurrently (l.667), though protected supervision may end an isolated envelope (l.669). Shutdown: the deployment supplies drain deadlines and the permitted escalation (l.3835), and a shared-process native realization MUST NOT be force-released (l.3838), so "then force-release" can apply only to hosted realizations. Calls: `TIMEOUT` comes only from expiry of a prepared call's caller-selected duration (INTERFACE l.2059-2061, l.2067), and a synchronous `call` has none, so "route call 30 s then Cancel and TIMEOUT" must be either a default `timeout_ms` set by our bindings or a policy deadline, which ends delivery (l.2062) but has no assigned code. **Needs an owner decision** (review item A18).
- **Re-decided 2026-11-11 (owner: "Accept all", after the Fable 5.2 session's review of the recommendations, item A18):**
  - Startup: one finite startup deadline, 120 s by default, for every supported realization, direct ones
    included (RUNTIME l.664). It starts when the execution attempt is accepted, which is after every
    ordering prerequisite is ready, so a dependant's deadline is not spent waiting for them. It covers
    binding, `_MODULE_init` and the readiness checks. On expiry the instance enters `error` with
    `startup-timeout` (l.1162, l.3753); native code still running is neither destroyed nor unloaded
    (l.667), and a context it returns later is destroyed through the mechanism that made it (l.666-668).
    While that attempt is outstanding, recovery and replacement wait (l.3538, l.3824) and `start` is
    NOT_READY. Built in the Runtime slice (I75).
  - Stop and shutdown: the drain deadlines are deployment input, 10 s each by default (l.3835). A
    shared-process native realization is never force-released (l.3838): on expiry the cleanup failure is
    recorded (`cleanup-timeout`) and shutdown continues (l.3860-3861); ending the process is the
    deployment's action (l.3839). Only hosted realizations may be terminated.
  - Calls: no Runtime default call timeout. `TIMEOUT` comes only from a caller-selected `timeout_ms`
    (INTERFACE l.2059-2061). The callers we own set one: logosctl has a default timeout that becomes the
    `timeout_ms` of `prepare_call`, because a synchronous `call` has no bound and nothing else detects a
    silent connection failure (INTERFACE l.1495).
  - The rest of (a) stands: Hello 10 s; Ctrl-C during a start is queued until the start returns.
  - The CONFIG application-attempt deadline (CONFIG l.269-275) is the fourth deadline in the set. The
    code a call returns when a policy deadline ends it (INTERFACE l.2062) is unassigned; that gap is in
    the TF-06 list (`claude-spec-comments-3.md`, logos-lips `d77cfa41`).
- **Built 2026-11-11 (I81):** the host configuration carries `startup_deadline_ms`, `stop_deadline_ms`
  and `shutdown_grace_ms` (1 ms to 1 h), with the engine's defaults when absent.
- **Built 2026-11-13 (I87, step 9b), the fourth deadline:** `apply_deadline_ms` (1 ms to 1 h), 120 s by
  default (owner, step 9 plan): expiry is destructive, so the default is as long as the startup
  deadline. It starts when an `apply_configuration` is accepted, after its preconditions, and covers
  the worker queue and the hook. On expiry the outcome is indeterminate: the caller gets MODULE_ERROR,
  the instance enters `error` with `configuration-indeterminate`, and the context stays owned until the
  hook returns (CONFIG l.269-272). `docs/HOST-CONFIG.md` documents it.
- **Amended 2026-11-14 (owner: "Go with option 2", as the Fable 5.2 session recommended):** the Module
  Loader's start has its own startup deadline, `EngineConfig.loaderStartupDeadline`, 120 s by default
  (`DefaultLoaderStartupDeadline`). The deadline above bounds every other realization, but no longer the
  Loader's. This is not a D9 gap: RUNTIME l.664 leaves the deadlines, their start points and their
  phases to the host or deployment.
  - Why: since I89 the Loader's realization at open ran under the modules' startup deadline. A host or
    test that shortened that deadline for its modules therefore also shortened the Loader's start. CI
    run 43589472593 failed `test_engine`'s RUN-0796 case this way: its 150 ms × `Slow` deadline failed
    the open, and the failure reproduced in 4 of 200 runs on a loaded host.
  - Start point and phases (l.664): the deadline starts at the engine's open (`openEngine`; the host
    API's `start`). It covers:
    - the Loader's binding by the bootstrap mechanism;
    - its `_MODULE_init` and readiness checks, through `ready`;
    - the binding checks that follow (l.1645-1650: the pinned contract, then `list_capabilities`).
  - The value is finite and positive: above zero and at most an hour, the host configuration's longest
    deadline. Any other value makes the open INVALID_PARAMS.
  - At expiry, in any of those phases:
    - the Loader's record is `error` with `startup-timeout`;
    - nothing later makes it `ready` or binds it (l.665);
    - nothing is destroyed while its init still runs (l.667), and a call already inside it returns first
      (l.623);
    - the open then fails with MODULE_ERROR "the Module Loader cannot start: startup-timeout: the startup
      deadline passed", once what it started is released (G190).
  - Only a host restart tries again. What `start` returns stays G190's TF-25 interim.
  - `lcn.app_config` has no field for it, so `host.nim` uses the default. Step 4b-6's daemon
    configuration must set the field or take its default.
  - Tested in `test_loader_engine`: the G190 case, the modules' deadline not bounding the Loader, the
    range, and an expiry during the binding checks (a held `list_capabilities`).

### G77 — Thread model
- **Kind:** FREE · **Specs:** RUNTIME §6, §13.2 (the Runtime progresses without the host running a loop);
  INTERFACE §2.8 (calls may arrive on any thread).
- **Options offered:** (a) chronos loop on a Runtime-owned thread, bounded worker pool for blocking native
  dispatch, completions via ThreadSignal *(recommended)*; (b) a dispatch thread per module instance.
- **Decision:** (a).

### G121 — Singleton direct-call mode
- **Kind:** FREE · **Specs:** RUNTIME §5.2.1 (optional; 2 MUST, 1 SHOULD, 3 MAY once implemented).
- **Options offered:** (a) implement it *(recommended)*; (b) leave it unclaimed. **Decision:** (a).

### G92 — A newer installed storage_module vs the bootstrap pin
- **Kind:** GAP · **Specs:** RUNTIME §9.3 l.3056-3059 (selection retained; never inferred from a newer
  available package), l.3072 (recovery MUST preserve the retained selection), l.1317 (reuse of state
  across identities is an authority-bearing policy decision); PM §11.
- **Options offered (first):** (a) no — the pin wins, storage updates ship with logosd *(recommended)*;
  (b) yes, a newer installed one supersedes it. **First decision:** (b).
- **Re-check (final review):** the spec makes an automatic switch at restart impossible. Options: (a) only
  an explicit `module upgrade storage_module` switches, keeping the state *(recommended)*; (b) revert to
  "pin always wins"; (c) automatic at start with a new instance and state migration.
- **Decision:** (a): stop the old instance, create a new one selected per G55, bind it to the old
  instance's state assignment (a policy decision the deployment profile allows), start it; restarts never
  switch. **Status:** revised.
- **Revised 2026-11-11:** with G55 re-decided, "selected per G55" means the exact pin the protected
  configuration holds when the new instance is created; how `module upgrade` changes that pin is decided
  with Tier 4b.
- **Revised 2026-11-11 (review against 6a4dfa28, item A7):** the procedure falls short of RUNTIME
  l.3546-3553. A deployment upgrade uses a new instance selected under current policy (l.3547). Before
  state moves, the deployment MUST stop the old instance and confirm quiescence and cleanup of every
  realization that could still reach that state (l.3548); the procedure has no such step. The replacement
  gets a fresh state assignment unless an explicit authorized state-reassignment or sharing policy applies,
  and filling it from the old instance needs a separately authorized migration or restoration (l.3549-3550;
  distinct instances share no state assignment by default, l.1451). It passes ordinary acceptance,
  authorization, initialization and readiness checks (l.3552), and existing routes are not retargeted to it
  (l.3553). The procedure also says nothing about the old instance (retired or kept stopped) or how its
  configuration, permission settings and grants reach the new one. To be decided with G55 and G143.
  **Needs an owner decision** (review item A7).
- **Re-decided 2026-11-11 (owner: "Accept all", after the Fable 5.2 session's review of the recommendations, items A6, A7):** the shape is RUNTIME l.3546-3553, and the state
  moves by transfer of its assignment, not by a fresh assignment plus migration (l.3549-3550). An upgrade
  (`module upgrade`):
  1. creates a new instance selected under current policy: the exact pin the protected configuration
     holds (G55; l.3547);
  2. stops the old instance and confirms quiescence and cleanup of every realization that could still
     reach its state (l.3548);
  3. snapshots the state where its size allows (the deployment profile states the limit), so a rollback
     is possible: with a transferred assignment the new version can alter the only copy (l.3554;
     BCP l.366);
  4. removes the assignment from the old instance before the new one starts (l.1451), and transfers it to
     the new instance as a separate authorized step: retirement needs the old instance `unloaded`, or in
     `error` with intent not `requested` (l.3563), and transfers nothing itself (l.3587-3588);
  5. provisions the new instance's configuration, permission settings (G110) and grants afresh;
  6. starts it through ordinary acceptance, authorization, initialization and readiness checks (l.3552).

  Existing routes are never retargeted to it (l.3553). Compatibility is declared explicitly per module
  and version pair, never inferred from names or versions (l.3551). Whether the old instance is then
  retired or kept stopped is decided with Tier 4b.
- **Re-decided 2026-11-15 (owner: "Accept, start 4b-6", taking the Fable session's position on batch F
  item 21 and F1, `tier4b-plans/fable-batches-efg.md` §2.1 and §5; Tier 4b step 4b-7, started 2026-11-16,
  "Start 4b-7"):** no assignment identifier moves. The re-decision of 2026-11-11 above is replaced in
  steps 3 and 4:
  - The replacement receives a **fresh state assignment** of its own (RUNTIME l.3549's rule), filled by a
    separately authorized migration (l.3550) that the deployment chooses per transfer: `copy` (the
    source's directory is copied and left as it was) or `move` (the directory is renamed to the
    replacement's). The identifier stays on the retired source's tombstone (l.2637, l.3587); the split
    between the abstract assignment and its concrete storage is l.94-95 and l.1448 (G305, the K31 row).
  - **The old instance is retired** in the same durable write that creates the replacement (step 4's open
    question, l.3563-3588; CONFIG l.265).
  - **`move` takes no snapshot** (step 3 changes): the operator's backup is the rollback, and the
    documents say so (l.3554; BCP l.394). `copy` keeps the source, which is the snapshot. The transfer's
    `mode` is required, with no default.
  - **The authorization** is protected offline configuration, a `state_transfers` entry applied once at
    start (G306, the K32 row; decision 9: no socket command and no Runtime Control method, l.3554). The
    entry is also the explicit compatibility assertion (l.3551).
  - **Four conditions** from what is built: a hosted source whose restart lock file (G275) is absent is
    refused; a transfer target whose directory is missing is never realized on a recreated empty one
    (BCP l.405); no purge while a rename is owed; the transfer record is kept with the tombstone (l.3588).
  - **F1:** `copy` reads the module's state in the Runtime's process (logosd's); its block buffer is
    zeroed, and the documents say so. `move` reads nothing.

  Steps 1, 2, 5 and 6 stand. Built in step 4b-7 (I96).
- **Completed 2026-11-16 (I96, part 7a; `move`):** the six steps as built. (1) The replacement is an
  instance the host configuration lists, with the declaration it holds (the pin until packages;
  `module upgrade` under package pins is Tier 5). (2) The transfer refuses a source that still has a
  realization, its cleanup, a hosted restart lock that is held or missing, or a dependent's retained
  intent (NOT_READY), and otherwise ends its intent with its retirement. (3) `move` takes no snapshot;
  the documents send the operator to the backup. (4) No assignment moves (G305): the replacement's
  fresh assignment is filled by renaming the source's directory, and the source is retired in the
  write that creates the replacement. (5) Configuration, permission settings and grants come only from
  the replacement's own provisioning. (6) The replacement starts through the ordinary path. The
  `state_transfers` entry is the compatibility assertion (G306). `copy` (part 7b, 2026-11-16) fills
  it with a copy instead, leaving the source's directory as the rollback; it is not built on Windows.

### G143 — State layout, retention and audit retention
- **Kind:** FREE · **Specs:** RUNTIME §8, l.1317 (allocation, reuse, retention, deletion, migration of
  concrete state are policy decisions); LOADER §5.1; BCP §5.4 (the deployment must document directories,
  state realization, retention, cleanup, recovery); CA l.941 (audit retention is deployment policy).
- **Options offered:** (a) `<session>/state/<module_instance_id>/` (0700); identity and state survive
  package update and `module upgrade`; state kept after `package rm` until `logosctl state purge` with
  logosd stopped; audit store bounded by count and age *(recommended)*; (b) `package rm` deletes the
  instances' state. **Decision:** (a).
- **Revised 2026-11-11 (review against 6a4dfa28, item A6):** "identity and state survive ... `module
  upgrade`" contradicts RUNTIME l.3547 ("A deployment upgrade uses a new module instance"), l.3549 (the
  replacement gets a fresh state assignment unless an explicit authorized reassignment or sharing policy
  applies) and l.3623 (`create_module` gives a fresh instance identity). Identity and state survive a
  package update (l.3546: installing or updating MUST NOT replace an instance's retained selection), not an
  upgrade. Whether the state directory stays keyed by `<module_instance_id>` or by state assignment is to
  be decided with G92. **Needs an owner decision** (review items A6, A7).
- **Re-decided 2026-11-11 (owner: "Accept all", after the Fable 5.2 session's review of the recommendations, items A6, A7):** identity and state survive a package update, not an
  upgrade (RUNTIME l.3546-3549); a package update changes nothing that is running (l.3546), and an upgrade
  follows G92. The state directory is keyed by state assignment, `<state root>/<assignment>/` (0700), as
  the Runtime slice already does (I74, I75). The rest of (a) stands: state is kept after `package rm`
  until `logosctl state purge` with logosd stopped, and the audit store is bounded by count and age.
- **Built 2026-11-12 (I82):** the Runtime's own state is in `runtime.store_dir`, which `create` keeps
  apart from `state_root` and `work_dir`. Retiring an instance keeps its state directory and reserves its
  assignment (BCP l.395); no purge exists yet.
- **Built for logosd 2026-11-15 (I95, part 4b-6c; G301):** the audit store is logosd's call-evidence
  store, bounded by `call_audit.store.max_records` and `max_age_days` (whole segments reaped at open and
  at rotation). `logosctl state purge` is left to step 4b-7.
- **Re-decided 2026-11-15 (owner: "Accept, start 4b-6", taking the Fable session's position on batch F
  item 21, `tier4b-plans/fable-batches-efg.md` §2.1 and §5, which includes "no purge while a rename is
  owed"; built 2026-11-16, Tier 4b step 4b-7 part 7c, I96):** the layout
  stays `<state root>/<assignment>/` (0700). Two name forms in the state root are the Runtime's,
  both outside the assignment alphabet: `+transfer-<hash of the target's assignment>` (a `copy`
  being staged) and `+purge-<random>` (a directory being removed); each start completes or removes
  them, and touches no other name. `logosctl state list` and `logosctl state purge` are built,
  offline, with logosd stopped: a purge removes a retired instance's preserved directory (or, with
  `--assignment`, one no instance and no tombstone names), never a live instance's (BCP l.395:
  retirement is not deletion), never an assignment the configuration names, never a symbolic link,
  and never while a transfer record names the assignment as its source and the target's directory
  is missing (NOT_READY: the rename is owed). The tombstone keeps reserving the assignment. After
  `move`, the source's directory is gone and `state list` shows where it went (the target's
  transfer record, kept even when the target is retired). The audit store stays 4b-6's (G301).

---

### G159 — Credential Store references without a definition
- **Kind:** GAP · **Specs:** BCP l.23, l.52, l.199-209, l.276, l.282-285; SECURITY l.528-529.
- **Description:** BCP and SECURITY refer to an optional Credential Store that no spec defines.
- **Interim:** none needed: it is optional and we build none. **Status:** OPEN, found 2026-11-10; reported
  as TL-02 in `claude-spec-comments-3.md` (logos-lips `68628d95`): publish it or drop the references.

### G160 — Static registration across a host binary upgrade
- **Kind:** GAP · **Specs:** RUNTIME l.1395 (retained declarations bound to the linked implementation
  through protected registration), l.3637 (start uses the retained declaration, never a replacement),
  l.2629-2635 (a fresh address when continuity is lost), l.2631-2632 (a host-assigned id is the host's).
- **Description:** relinking a host that statically links a module (D14) replaces the implementation;
  the spec does not say whether the instance survives. With persistence (I82) the same question covers
  every configured instance whose configured record differs from the retained one.
- **Interim until 2026-11-12:** keep the instance only when the declaration facts are byte-identical;
  otherwise allocate a fresh instance. Withdrawn: the Runtime cannot allocate a fresh address under a
  host-assigned id.
- **Interim (rewritten 2026-11-12, owner's U4 for step 6):** at `start`, a configured instance the store
  holds is compared by its declaration facts: its record without the artifact's `local_path` and without
  the permissions' `reason` texts, as deterministic CBOR (`store.factBytes`).
  - Equal facts: the same instance. When the record differs only in those two fields, the retained
    record takes the configured ones (one write first, I82).
  - Different facts: `start` fails INVALID_PARAMS naming the instance, before anything is changed or
    run; the host gives the changed module a new instance id.
  - Instances that `create_module` made keep their stored record (l.3637).
  - A changed implementation under equal facts keeps the instance; a `direct_dynamic` artifact is
    copied and verified again at its next attempt (RUN-1030).
  `engine.reconcile`; `docs/HOST-CONFIG.md`, "Instances and the configuration".
- **Status:** OPEN (Tier 4); reported as TF-08 in `claude-spec-comments-3.md` (logos-lips `68628d95`).
  Built in I82.
- **Amended 2026-11-16 (owner: "Start 4b-7", with batch F item 21 accepted 2026-11-15; I96):** the new
  instance id a changed module gets keeps the old instance's state through a `state_transfers` entry
  (G306): the old instance is retired and its directory becomes the new one's at the next start
  (`docs/HOST-CONFIG.md`, "State transfer to a replacement instance").

### G161 — The scope of "observation authority"
- **Kind:** GAP · **Specs:** RUNTIME l.3665 (a request omitting both selectors needs observation
  authority over the complete selection scope).
- **Description:** no RC scope or action is named for it.
- **Interim:** evaluate the requested method's RC scope with `modules: [name]` and no instances or
  providers.
- **Status:** OPEN (Tier 4); reported as TF-09 in `claude-spec-comments-3.md` (logos-lips `68628d95`), which adds the
  term's other uses (RUNTIME l.3157, l.3498, l.3594, l.1725; CA l.180-190, l.301-308).
- **Built 2026-11-11 (I81):** Runtime Control `get_readiness` uses this interim (`aaObserve` on the
  selected target).
- **Built 2026-11-12 (I86, step 7a), the interim extended (TF-09):** each observation method uses its
  own Runtime Control scope. `get_execution_summary` and `get_permission_settings` are decided for the
  target alone (`modules` and `instances`); `describe_provider` for `providers: [p]`, then one
  `discover` decision per contract (D5). A list method is decided once without a subject
  (`AuthzRequest.filters`, never treated as narrowed), and the allow is applied to each record, on
  every page, through the facts kept with it (G226): the record is shown when an allowed scope covers
  the method's scope with exactly that record's selectors. Event delivery is step 7b's.
- **Built 2026-11-13 (I86, step 7b), events:** a Runtime Control event's own scope is
  `{methods: [], events: [root]}` (new action `aaObserveEvent`; an empty method list permits no
  method, CA l.126). `subscribe` asks it once without a subject (`filters`); every entry is judged
  against it and the exact subject (G226) when the change is fanned out, and again just before its
  handler runs when the decision state changed since (a new binding generation, an invalidation, a
  passed `valid_until`), so every delivery is checked against a current decision (R l.3498) and a
  decision is reused only through the cache. A hint needs, besides, the list method's decision for
  at least one affected record (l.3419). Which authority an event needs (its own `events` entry or
  the module record's observation, R l.3510) stays open in TF-09.

### G162 — Lifecycle outcome of a start with missing configuration
- **Kind:** GAP · **Specs:** CONFIG l.125-126 (missing eligible configuration prevents initialization,
  gives `NOT_READY`, and does not cancel execution intent); RUNTIME l.3750-3762 (failure codes).
- **Description:** the resulting lifecycle state and failure classification are not stated.
- **Interim:** the instance stays unloaded, the intent stays requested, no `failure` is set, and the retry
  is left to orchestration.
- **Revised 2026-11-10:** the first interim had the next configuration update re-trigger the start. CONFIG
  l.213 says `update_configuration` invokes no lifecycle operation, so that re-trigger contradicted the
  text; nothing was built on it.
- **Status:** OPEN (Tier 4); reported as TF-10 in `claude-spec-comments-3.md` (logos-lips `68628d95`), which adds that
  nothing says what makes the retained intent take effect once a value arrives.
- **Built 2026-11-13 (I87, step 9a; interim re-approved by the owner 2026-11-13):** the check runs after
  the execution decision, so a denied start is G168's NOT_AUTHORISED. With no eligible record the start
  is NOT_READY: the state stays `unloaded` (or `error` with nothing to clean), intent is established or
  kept as `requested`, no failure is set, no attempt is accepted and nothing is published. A retained
  `authority-denied` or `authority-evaluation-failed` from an earlier refused decision is cleared, since
  the decision now allows. Start, recovery and bootstrap run the same selection
  (`engine.selectConfig`). No update starts anything (l.213); the retry is orchestration's, as
  HOST-CONFIG.md says.
- **Built 2026-11-13 (I94, part 4b-5b):** the retry is the reference module's probe, brought forward by
  `configuration_state_changed` for the instance (G288).

### G163 — Which system service a caller view names
- **Kind:** GAP (settled by INTERFACE l.2181-2186 at 6a4dfa28) · **Specs:** RUNTIME l.888 (an engine system-service binding identifies the invoking
  Runtime and the protected system-service kind); INTERFACE `logos_caller_view_t` l.3505-3523 (only
  `kind`, `runtime_instance_id`, `module_instance_id`).
- **Description:** the C caller view has no field for the system-service kind.
- **Interim:** `kind = LOGOS_CALLER_SYSTEM_SERVICE`, with the service identified by the binding the
  provider received.
- **Status:** OPEN (Tier 4) until the 2026-11-11 review, now settled by spec text (below); recorded as an ambiguity in the editorial item TF-06 of
  `claude-spec-comments-3.md` (logos-lips `68628d95`): "the protected system-service kind" may mean the two-valued
  caller `kind` the view already carries (INTERFACE l.3505-3506, l.3519-3523); under that reading the
  interim is the spec.
- **Settled 2026-11-11 (review against 6a4dfa28, item B10):** INTERFACE l.2183: "For
  `LOGOS_CALLER_SYSTEM_SERVICE`, the Runtime identifier identifies the invoking Runtime and the
  module-instance view is null with zero length", and the views create no other participant kind
  (l.2184). The view is complete as the interim has it, and RUNTIME l.888's "protected system-service kind"
  is the caller `kind`. Settled as the interim.

### G164 — Session reuse
- **Kind:** GAP (settled by RUNTIME l.2845-2848 at 6a4dfa28) · **Specs:** RUNTIME l.784 (materialization MAY reuse a live session bound to the same
  consumer, route, provider and contract); the NR-11 answer (no implicit sharing).
- **Description:** the two agree only if "same route" excludes sharing across routes.
- **Interim:** never reuse a session, which always conforms.
- **Status:** OPEN (Tier 4) until the 2026-11-11 review, now settled by spec text (below); covered by TS-04 in `claude-spec-comments-3.md` (logos-lips `68628d95`), which cites l.784;
  not raised separately.
- **Settled 2026-11-11 (review against 6a4dfa28, item B11):** RUNTIME l.2845-2848: Runtime binds an
  accepted session to exactly one route and selected provider, the session MUST NOT switch to another
  provider or route, and a caller that needs another MUST establish another session. Sharing across routes
  is excluded; reuse on the same route stays optional (l.784). "Never reuse" is our free choice and
  conforms.
- **Re-checked at 4b-2 (2026-11-13):** kept; one session per materialization, and a further handle on a
  transported route needs `renew_route` (G258). Built in I90 part 4b-2b: each handle has its own
  connection, and releasing one leaves the others working (`test_transported`).

### G168 — Lifecycle outcome of an execution-authorization denial after `start_module` is accepted
- **Kind:** GAP · **Specs:** RUNTIME l.3644-3647 (acceptance establishes `requested` intent before
  execution authorization; a later denial does not cancel it), l.3750-3756 (`authority-denied` is a
  failure classification), l.553-571 (the states: `error` is a realization, initialization, readiness,
  execution or cleanup failure, and the diagram has no unloaded→error edge).
- **Description:** nothing says whether a denied instance stays `unloaded` or enters `error`, whether its
  record carries `failure`, or whether `start_module` fails with NOT_AUTHORISED or succeeds reporting the
  resulting state.
- **Interim:** `start_module` fails with NOT_AUTHORISED; the instance stays `unloaded` with
  `failure = authority-denied`, and intent stays `requested` with its origin. Related to G162 (TF-10),
  where a missing configuration leaves no `failure`.
- **Status:** OPEN (Tier 4, Capability Authority integration); found 2026-11-11 while designing the first
  Tier 4 slice; reported 2026-11-11 as part of TF-10 (`claude-spec-comments-3.md`, logos-lips
  `d77cfa41`). The interim is built in the Runtime slice (I75), where the test authorizer denies (G52).
- **Built with the Capability Authority 2026-11-12 (step 8b-1, I85):** unchanged at start. A deny gives
  `authority-denied`; an evaluation failure gives `authority-evaluation-failed` (RUNTIME l.3753), both
  NOT_AUTHORISED with the instance `unloaded` and its intent and origin kept.
- **Extended to enforcement stops 2026-11-12 (step 8b-2, I85):** a running instance whose execution
  authorization ends (validity end, revoked or expired grant, a policy change that does not retain it, a
  denied or narrowed renewal, binding loss) is stopped at once with the stop deadline, and ends `unloaded`
  with `authority-expired`, `authority-revoked`, `authority-denied` or `authority-evaluation-failed`, its
  intent and origin kept. An overrun gives `cleanup-timeout` instead (TF-28). An explicit stop clears the
  classification (RUNTIME l.3757). If the owner answers TF-10 with `error`, both cases change together.
- **Built 2026-11-13 (I94, part 4b-5b):** the retry is the reference module's probe: an `unloaded` instance with
  `requested` intent, failure or not, is probed uncharged on the policy's spacing (G288).
- **Extended to a settings refusal 2026-11-14 (G284; I93):** a start or recovery the permission settings
  refuse before any decision has the same outcome, with `authority-denied` or
  `permission-enforcement-failed`.

### G169 — The code of an establishment that returns nothing for a reason other than authority
- **Kind:** GAP · **Specs:** RUNTIME l.3145-3146, l.1501-1502, l.3109-3112 (establishment fails),
  l.3157-3159 (NOT_AUTHORISED for an unknown, hidden or denied target, for a caller without discovery or
  observation authority), l.1908-1916 (the precondition table has no rows for establishment), l.660
  (NOT_READY only for Runtime-owned readiness), l.1500 (disclosure in a successful route record).
- **Description:** an allowed provider that is not ready, and an allowed `all-runtime-visible` discovery
  that finds no provider, both end in "establishment fails" with no code; whether a route allow alone
  makes a provider's readiness disclosable is not said.
- **Interim:** NOT_READY when the caller holds a route allow for a selected provider, or a `discover`
  allow for the contract and no provider offers it; NOT_AUTHORISED otherwise. For `single` with no
  candidate the `discover` decision is evaluated only to choose between the two; when every candidate is
  denied the answer is NOT_AUTHORISED. `engine.establish`.
- **Status:** OPEN (Tier 4); found 2026-11-11 building the Runtime slice step 3; reported 2026-11-11 by the Fable session, at the owner's request, as TF-16 in `claude-spec-comments-3.md` (logos-lips working tree, not yet committed). Built in I76.

### G170 — Route outcomes stated two ways or not at all
- **Kind:** CONTRA and GAP · **Specs:** RUNTIME l.624-626 (an authorized stop closes the consumer's
  routes, a failure fails them), l.2508 (`consumer-unavailable`: "has stopped or its realization has
  failed"), l.2520, l.2524 (`failed` and `revoked` records carry `failure`; a closure needs none),
  l.3486-3491 (`close_route` sets `closed` and reports the resulting state), l.1845-1846 (a terminal route
  is not revived), l.3183-3189 (renewal performs a new authority check); CA l.906-911 (a re-evaluation that
  denies makes a dependent route unusable).
- **Description:** a stopped consumer's routes are `closed` by l.624 and `failed` with
  `consumer-unavailable` by l.2508; the result of `close_route` on a `failed` or `revoked` route is not
  stated; nothing says what a denied renewal does to the route.
- **Interim:** a stopped consumer's routes close with no failure, a failed consumer's fail with
  `consumer-unavailable`; `close_route` on a terminal route succeeds and reports its state unchanged; a
  denied renewal revokes the route with `authority-denied` (`authority-evaluation-failed` for an evaluation
  failure), so calls through its handles are NOT_AUTHORISED and its observers get that code. The last is
  the conservative reading: no call is served under a decision a later check withdrew.
  `engine.routesFollow`, `engine.closeRoute`, `engine.renew`.
- **Status:** OPEN (Tier 4); found 2026-11-11 building the Runtime slice step 3; reported 2026-11-11 by the Fable session, at the owner's request, as TF-17 in `claude-spec-comments-3.md` (logos-lips working tree, not yet committed). Built in I76.
- **Extended 2026-11-12 (step 8b-2, I85):** a renewal, or the Runtime's re-authorization after a notice
  (G216), allowed narrower than the route's bound access revokes it with `authority-revoked`. For a
  route the authority decided, an evaluation failure in either leaves it `ready` and unusable until a
  later decision allows it (G216); a route under the internal policy's test rules is still revoked with
  `authority-evaluation-failed`. An enforcement-stopped consumer's routes are
  `closed`, or `failed` with `consumer-unavailable`, as for any stop or failure.

### G171 — The order of checks for one request
- **Kind:** GAP · **Specs:** INTERFACE l.3116-3124, l.3888-3890; RUNTIME l.1626, l.1823, l.1907-1908,
  l.630-632, l.1347, l.1732, l.852-853; TRANSPORT l.657-658.
- **Description:** four orders are open: a malformed Runtime Control request from a caller without
  authority for the method; an invalidated binding or stopping provider and a caller policy would deny; a
  route call that the per-call decision denies with an invalid payload; `materialize_route` for an owned
  route that is not ready, with a root that does not match.
- **Interim:** authorize what needs no payload, then validate the payload, then authorize the target, then
  check readiness, then compare roots. For Runtime Control: the caller's association (NOT_AUTHORISED),
  the method's authority where it names no target from the payload (`establish_route`,
  `shutdown_runtime`; a malformed request asks the Runtime thread for these two checks before it is
  answered INVALID_PARAMS), the payload, the target's authority, then readiness: whether the binding is
  still current and the Runtime not shutting down (`originReady`), then the targets' readiness. A request
  replayed by `request_key` checks readiness before it is answered. For a route call: method resolution,
  access scope and the per-call decision, then the payload (a call refused NOT_READY is validated first
  and answered INVALID_PARAMS when the payload is invalid), then readiness. For `materialize_route`: the
  schema response, ownership, the route decision, readiness, the root. Host `start` and `stop` look the
  target up before reporting a Runtime that is shutting down.
- **Status:** OPEN (Tier 4); found 2026-11-11 building the Runtime slice step 3; reported 2026-11-11 by the Fable session, at the owner's request, as TF-18 in `claude-spec-comments-3.md` (logos-lips working tree, not yet committed). Built in I76.
- **Extended 2026-11-13 (I87, step 9a; TF-18 point 5):** the five configuration methods take the method's
  authority for their target, then the payload, then origin readiness, then CONFIG's §5 table in row
  order (G21). `update_configuration` validates the value on the caller's thread and re-checks the
  first phase's decision before it commits. The missing-realization case of `apply_configuration`
  comes after the NOT_READY row (built in step 9b: `engine.applyRefusal`, with CONFIG §8's rows in
  table order).

### G172 — Status codes that provider code returns
- **Kind:** GAP · **Specs:** INTERFACE l.3315-3319, l.1802-1803 (NOT_READY is reserved for
  Runtime-owned readiness), l.3178-3180 (in direct mode the status "passes through unchanged"),
  l.3329-3331, l.3366-3367 (validate before forwarding); RUNTIME l.660, l.1343-1347.
- **Description:** nothing says which allocated codes provider code may return, so a consumer can read a
  Runtime meaning (NOT_READY, NOT_AUTHORISED) into a code the provider chose.
- **Interim:** a provider status that passes the INTERFACE l.3366 checks is forwarded unchanged, as
  l.3180 says; one that fails them is MODULE_ERROR. `bindings.providerCall`.
- **Status:** OPEN (Tier 4); found 2026-11-11 building the Runtime slice step 3; reported 2026-11-11 by the Fable session, at the owner's request, as TF-19 in `claude-spec-comments-3.md` (logos-lips working tree, not yet committed). Built in I76.

### G173 — When `start_module` and `stop_module` answer
- **Kind:** GAP · **Specs:** RUNTIME l.3649, l.3687 ("toward" `ready`, `stopping` or `unloaded`),
  l.3654, l.3693 (the resulting state), l.620-621, l.3609 and l.3697 (`report_failure` and
  `shutdown_runtime` answer without waiting).
- **Description:** the point at which each answers is open, and a module that stops itself cannot be
  answered after its own destruction, which waits for its in-flight calls, one of which is waiting for
  that answer.
- **Interim:** `start_module` answers at `ready` or with the failure (`error`, or `stopping` when a stop
  overtook it), as I75 built it; `stop_module` answers at `unloaded`, or with `stopping` once the stop
  deadline passes; it answers with `stopping` at once when the caller is the target or has a call in
  progress in the target. `engine.stop`, `engine.callsInto`.
- **Revised 2026-11-12 (I80):** once the stop deadline passes, the cleanup failure is recorded (G61 as
  re-decided under A18), so `stop_module` answers there with `error` and `cleanup-timeout`, not
  `stopping`; what the end of that cleanup does is G180. TF-20 as reported still says `stopping`.
- **Note 2026-11-12 (I82):** `recover_module` answers as `start_module` does: at `ready`, or with the
  failure state. The same question for one more method; no new report.
- **Status:** OPEN (Tier 4); found 2026-11-11 building the Runtime slice step 3; reported 2026-11-11 by the Fable session, at the owner's request, as TF-20 in `claude-spec-comments-3.md` (logos-lips working tree, not yet committed). Built in I76.

### G174 — An admitted call whose route ends
- **Kind:** FREE (what the call does) and GAP (its code) · **Specs:** RUNTIME l.3226-3227, l.3459,
  l.3490 (in-flight work on an ended route is left to policy), l.1292-1294 (a Response is committed
  only under current authority, ordered with revocation), l.3057-3058, l.1737-1738, l.1349 (§7.5 is about
  admission); INTERFACE l.2101-2102 (the invocation is marked cancelled), l.2065-2067 (only CANCELLED and
  TIMEOUT are assigned), l.1486-1490 (a handle's retained termination code); CA l.823, l.913-917.
- **Options offered (D2 of the step-4 plan):** (a) a call admitted before its route ended may complete
  with its result when the route was closed or failed; a revoked route ends it NOT_AUTHORISED without
  committing its result; either way the invocation is marked cancelled *(recommended)*; (b) keep I76:
  every admitted call completes with its result; (c) any end ends the call at once with the route's
  code. **Decision:** (a), with the Fable review's refinements (owner, 2026-11-11: "Approved").
- **Description of the gap:** no code is assigned to an admitted call that its route's end terminates;
  INTERFACE l.2065 names the binding's own failures and l.2067 codes only CANCELLED and TIMEOUT.
- **Interim:** the handle's retained termination code: NOT_AUTHORISED for a revoked route, NOT_READY
  otherwise. Such a NOT_AUTHORISED no longer means the provider did not run (RUNTIME l.1737-1738).
- **Built:** when a route ends, the Runtime thread records its end code in each admitted call's ticket
  under the ticket's lock and marks the invocation cancelled. A synchronous call reads the code under
  the same lock after its provider returns, so the commit is ordered with revocation: a revoked route
  returns NOT_AUTHORISED and the response is dropped. An asynchronous call through a revoked route
  completes NOT_AUTHORISED at once; through a closed or failed route it completes with its result, and
  at the latest NOT_READY when its provider's realization ends (RUNTIME l.1294).
  `engine.endRoute`, `engine.endServices`, `invoke.commitSync`, `asynccall.offerCommitted`.
- **Status:** OPEN (TF-23, logos-lips `a9fe9c66`); decided and built 2026-11-11 (I78).
- **Under the Capability Authority 2026-11-12 (step 8b-2, I85):** unchanged. A policy change or a
  grant's end reaches a route only as its re-authorization's outcome (G216), so a call in flight on a
  route that is kept commits its response, and one on a route that is revoked gets NOT_AUTHORISED with
  its invocation marked cancelled (CA l.823, l.917-918). The engine records the limitation as a
  diagnostic. Holding every commit on a route until its re-authorization completes would be stricter;
  it is not built.
- **Transported routes (owner, batch B 7, 2026-11-13; amends (a)):** at a revocation or expiry each
  in-flight Request of the route's sessions is answered NOT_AUTHORISED at once and its later result is
  not committed, then the sessions end (TRANSPORT l.987-991), as a direct call through a revoked route
  does. At a provider stop, a shutdown or `close_route` (and, `[IMPL]`, a consumer end or a provider
  failure) admitted calls drain within the stop deadline or the shutdown grace, then the session closes;
  a call still running then reaches its caller as TRANSPORT_ERROR (TRANSPORT l.543). The wait before
  `_MODULE_destroy` is mandatory either way (INTERFACE l.1997, l.1999). TRANSPORT l.995 governs only
  Requests left without a Response. Built for the provider side in I90 part 4b-2a (G260).

### G175 — Event authorization points
- **Kind:** FREE (decided) and GAP (activation) · **Specs:** RUNTIME l.1018-1020 (scope at
  activation), l.1229 (authorize each delivery), l.1720-1730 (names neither subscribing nor delivery);
  CA l.236-245, l.908, l.973-975.
- **Options offered (D3 of the step-4 plan):** (a) a `subscribe-event` decision when a subscription is
  activated and at each delivery, a `publish-event` decision at each delivery *(recommended)*; (b) at
  each delivery only. **Decision:** (a) (owner, 2026-11-11: "Approved").
- **Description of the gap:** whether `subscribe-event` is evaluated at activation is not stated.
- **Interim:** it is, and a denial is NOT_AUTHORISED, after the route's subscribe scope and before
  readiness. So no subscription is active that could never deliver.
- **Built:** `authz.AuthzAction` gains `aaPublishEvent` and `aaSubscribeEvent` (G52). Each delivery asks
  `publish-event` with the publisher as the consumer and the subscriber's route as target, then
  `subscribe-event` for the subscriber, on the Runtime thread, for that one handler invocation; a denial
  skips that subscriber. Through an invocation's context a denied `publish-event` ends the publication
  NOT_AUTHORISED and a denied `subscribe-event` skips the subscriber. `engine.subscribe`,
  `engine.deliver`.
- **Status:** OPEN (TF-24, logos-lips `a9fe9c66`); decided and built 2026-11-11 (I78).
- **Re-checked under the Capability Authority 2026-11-12 (step 8b-2, I85):** the same decision points,
  all through the decision cache. An explicit `subscribe-event` deny at delivery also deactivates the
  subscription, since continuing it would exceed current authority (CA l.913-915, CAP-0191); an
  evaluation failure skips that delivery only. Under an authority that issues only single-use
  decisions, each delivery costs two evaluations on the publishing thread (HOST-CONFIG).
- **Extended 2026-11-13 to Runtime Control subscriptions (I86, step 7b; TF-24's RC form):** a
  Runtime Control `subscribe` asks the event's own decision (`aaObserveEvent`, G161) after
  association and the name and before readiness; a denial is NOT_AUTHORISED and activates nothing. A
  narrowed allow activates the subscription and is applied per delivery. Each delivery is then judged
  as G161's 7b note says, on the Runtime thread, never on an event worker.
- **Over local transport 2026-11-13 (I90, part 4b-2c; plan Rev R9 (a)):** the provider's Runtime
  decides a session's Subscribe at activation in the same order (`engine.servedActivate`, on a call
  worker); an explicit deny is the SubscriptionResult NOT_AUTHORISED. Each ordinary publication asks
  both decisions per subscriber connection (`engine.deliverConn`); a subscriber's deny skips that
  Event for that connection with no signal, and its subscription stays: the provider side cannot end
  one subscription of a session (K40). A scoped publication over a session stops NOT_AUTHORISED on a
  denied `publish-event`, as on a direct route.

### G176 — Two publishers that deliver into each other's handlers
- **Kind:** CONTRA · **Specs:** INTERFACE l.1961-1967, IFC-0279, IFC-0280 (direct delivery runs on the
  publishing thread before publish returns), IFC-0182 (one thread at a time per subscription),
  l.1463-1464 (deactivation); RUNTIME l.1179-1182 (no event-delivery thread).
- **Description:** thread A, inside subscription S's handler, publishes to T while thread B, inside T's
  handler, publishes to S. Each waits for the other's handler to return; no behaviour meets both MUSTs.
- **Interim:** the publisher waits, the only choice that breaks neither MUST. The wait ends when the
  awaited subscription is deactivated, so unsubscribing, closing either route or stopping either module
  releases the cycle, and a wait longer than 2 s records a diagnostic. `events.enterGate`.
- **Status:** OPEN (TF-21, logos-lips `a9fe9c66`); built 2026-11-11 (I78).

### G177 — Invocation paths of direct route handles
- **Kind:** FREE · **Specs:** RUNTIME l.1254-1273, l.1266, l.1269 (separate materialization does not
  establish a shared path), l.784 (transported handles may share a session); INTERFACE l.2193-2196.
- **Options offered (D4 of the step-4 plan):** (a) each materialized handle is its own invocation-path
  generation, so scoped events reach only subscriptions made through the handle the call came through
  *(recommended)*; (b) every handle of a route shares one generation. **Decision:** (a) (owner,
  2026-11-11: "Approved"). It never over-delivers, and a consumer that relies on sharing fails here
  rather than only on another Runtime.
- **Built:** `materialize_route` gives each handle a fresh generation (`callside.nextGeneration`); its
  subscriptions, and the calls prepared through it, carry it. `engine.scoped`.
- **Re-checked at 4b-2 (2026-11-13):** kept; a transported handle has its own connection and generation
  (G258).
- **Status:** decided and built 2026-11-11 (I78).

### G178 — The thread of a Runtime Control subscription's handler
- **Kind:** GAP · **Specs:** INTERFACE l.1954-1956 (Runtime Control operations may run concurrently, so
  a handler may call Runtime Control), l.1961 (direct delivery is bound to a publish call); RUNTIME
  l.1182 (no Runtime event-delivery thread for direct callbacks), l.3419.
- **Description:** the Runtime itself publishes Runtime Control events, so there is no publish call
  whose thread the handler could run on, and running it on the Runtime thread would deadlock any
  handler that calls Runtime Control and let one observer block other modules' lifecycle.
- **Interim (step 7 plan, approved 2026-11-12 with the fixes B1, B2, C1, D2, D3):** handlers run on
  Runtime-owned event workers, one handler at a time per subscription, in committed order, after the
  change is exposed (so after its write), never inline in the committing operation and never on the
  Runtime thread. RUNTIME l.1182 (no Runtime event-delivery thread for direct callbacks) is knowingly
  not applied to these events: no module publishes them, so there is no publishing thread to run on.
  Only entries the subscriber may observe count toward its bound (D3); hints keep their affected
  facts (D2); at most 4 workers serve one subscriber at a time (C1). Overflow is G225.
- **Status:** OPEN (TF-22, logos-lips `a9fe9c66`); interim approved 2026-11-12, built 2026-11-13
  (I86, step 7b).
- **Built 2026-11-13 (I86, step 7b):** `runtime/rcevents.nim` and `engine.nim`. A subscription
  (`RcSub`, shared heap) holds the handler, its activation and `events.nim`'s gate; its queue, its
  unjudged list and its pending hints stay on the Runtime thread (`RcRec`). Changes are fanned out in
  `expose` (C19), at route ends and at route record changes (`publishRc`, `hintRc`; `publishRc` is the
  entry point step 9's configuration events use, C29). An entry whose decision needs an evaluation
  waits, in order, in the unjudged list (`rcUnjudged`, 256), judged one `decideDetached` at a time;
  the admitted ones join the queue (`rcQueue`, 256), a refused one is dropped. An `inventory_changed` subscription keeps one
  pending hint per collection with up to `rcHintFacts` (1024) distinct admitted subjects; past that it
  is marked overflowed. Drains go to a pool of up to 64 event workers (`MaxEventWorkers`, spawned on
  demand), at most `rcWorkersPerSubscriber` (4) per subscriber, each drain at most `rcDrainQuota` (16)
  entries before the subscription goes behind the others. Each entry is admitted by the Runtime
  thread just before its handler runs (`rqRcDeliver`): the subscription active, its binding current
  and `loaded` or `ready`, the decisions it was judged by unchanged or judged again (G161). The
  handler's return is posted (`mkRcHandled`) before the gate opens; the subscriber's realization is
  released and its context destroyed only once no handler of it runs (`rcHandlers`), and the engine
  closes only once no drain runs (`rcBusy`). A subscription ends at the commit that takes its
  subscriber out of `loaded`/`ready`, before that commit is exposed; its record goes with its binding
  (`endServices`) or with `unsubscribe`.

### G180 — The end of a cleanup that its stop deadline overran
- **Kind:** GAP · **Specs:** RUNTIME l.611 (completion of cleanup after a failure MUST NOT by itself
  change `error` to `unloaded`), l.612 (a completed explicit stop transitions the instance to
  `unloaded`), l.613 (`start` is NOT_READY in `error` while cleanup is unresolved), l.3757 (the
  classification is cleared when an explicit stop completes successfully), l.3835-3838 (drain deadlines;
  no force-release of a shared-process native realization), l.3873-3874, l.3530 (`realization` is
  `absent` once no cleanup ownership remains), l.1835.
- **Description:** past its deadline, a stop records the cleanup failure: the instance enters `error`
  with `cleanup-timeout` and the realization keeps its cleanup (G61, A18). When that cleanup ends later,
  l.611 read literally keeps `error`; read as the explicit stop completing late (l.612), it gives
  `unloaded` and clears the classification (l.3757). Each reading risks one MUST, and two Runtimes would
  differ visibly in state and `failure` after a slow stop. Not covered by TL-07, NL-06 or TF-20.
- **Options:** (a) the literal reading of l.611: the instance stays `error` with `cleanup-timeout`; a
  later stop then finds nothing to clean and gives `unloaded` at once, and a new accepted start leaves
  `error` *(recommended by the Fable session, 2026-11-12)*; (b) the late end completes the stop:
  `unloaded`, failure cleared.
- **Interim:** (a) (owner, 2026-11-12: "Commit as G180 interim (Recommended)"). A stop while that cleanup still runs is a new explicit stop: it starts no second
  destruction, the instance re-enters `stopping` with a new deadline (as I75 does for any `error` with
  cleanup pending), and the end of the cleanup within that deadline makes it `unloaded`. TF-28's
  reading answers that stop with the current state instead; the specs say nothing about it either
  way (TF-28 point 3), and the interim differs from that reading only here. Once the execution summary is built, its `realization` is `absent` when that
  cleanup has ended while the state is still `error` (l.3530). `engine.checkDeadlines`,
  `engine.finishAttempt`, `engine.stopInstance`.
- **Status:** OPEN (TF-28, logos-lips `235c22e6`); found 2026-11-12 building the step-3 leftovers;
  interim approved and built the same day (I80); reported by the Fable session at the owner's request.
  TF-28 also asks when `cleanup-timeout` is set and whether a record in `stopping` may carry it.
- **Built 2026-11-12 (I86):** while that cleanup runs, `get_execution_summary` reports `realization`
  `unknown`; when it ends, `absent`, and the change is a commit of its own (G227), so the revision
  advances while the state stays `error`.
- **Built 2026-11-13 (I94, part 4b-5b):** an enforcement stop that overran its deadline (`error` with
  `cleanup-timeout`, intent kept) is resumed by the reference module with uncharged probes, under every
  policy (G291).
- **Amended 2026-11-14 (owner, batch C 13; G269):** (a) holds for a hosted realization, whose cleanup
  now ends by a confirmed kill: at the stop deadline its Module Host is ended, the Loader's `release`
  then succeeds, `realization` is `absent` and the state stays `error`. Built in I91 (part 4b-3.1b).

### G190 — Where bootstrap ends, and what `logos_runtime_start` returns when it does not
- **Kind:** GAP · **Specs:** RUNTIME l.3967 (Start: "Complete bootstrap, then return"), l.3972-3973
  (successful startup establishes the initial system-service bindings and does not require every
  ordinary module to be ready), l.1640 (startup MUST establish the initial orchestration realization
  under bootstrap policy), l.4073 (CANCELLED "unless it has already completed"), l.4088 (otherwise the
  applicable shared code, or MODULE_ERROR), l.3806-3807 (an orchestration failure pauses startup and
  recovery, and does not stop the engine); INTERFACE l.2067 (TIMEOUT is a caller-selected duration).
- **Description:** open are whether "establish the realization" means `ready` or only `loaded`; which
  code `start` returns for an execution denial, an initialization failure and a startup-deadline expiry;
  and when bootstrap "has already completed" for RUN-0759. With an external Capability Authority a
  second part appears: orchestration establishes the CA binding after it is ready (l.1643), and whether
  `start` waits for that is not stated.
- **Interim:** bootstrap completes when the orchestration instance is `ready` (l.566: `loaded` is still
  performing checks). An execution denial under bootstrap policy is NOT_AUTHORISED (l.1737-1739); any
  other failure, `startup-timeout` included, is MODULE_ERROR with the l.3753 classification in the
  message, since the host has no observation channel; the code `_MODULE_init` returned is never
  forwarded, and a contract mismatch is never VERSION_MISMATCH, which §13 keeps for the ABI checks
  (l.3952). A shutdown accepted on the Runtime thread before `ready` is committed gives CANCELLED, and
  it stays CANCELLED if the initialization then fails or the deadline then passes. A failed start stops
  and destroys nothing (RUN-0737): the host requests shutdown, waits, then destroys. One proc,
  `engine.checkBootstrap`.
- **Status:** OPEN (TF-25, logos-lips `bf9b325f`); found 2026-11-11 planning the Runtime slice step 5;
  the Fable session judges it small and real, the deadline code being the one sub-point the owner may
  answer otherwise. TF-25 also asks whether `start` waits for the first authority binding (l.1643
  against l.3973). Interim accepted by the owner ("Yes to both") and built in I81.
- **Re-checked under the Capability Authority 2026-11-12 (step 8b-2, I85):** unchanged. `start` returns
  at orchestration `ready`; the orchestration instance then starts the authority under the derived
  rules, and until it is bound every authority-decided operation fails closed (RUNTIME l.1675). `start`
  does not wait for the binding. A failure to wire the authority after the engine exists is a failed
  start like the others: MODULE_ERROR, nothing stopped or destroyed.
- **Built 2026-11-13 (I87, step 9a; TF-25 point 4):** an orchestration instance with a configuration
  binding and no eligible value fails `start` with MODULE_ERROR, "the orchestration instance cannot
  start: …", before any module code runs; so does one whose revision cannot advance (G234).
- **Re-checked 2026-11-13 (I89, part 4b-1c):** unchanged in kind. A new case: a Module Loader that
  cannot be established, before any configured instance is realized, makes `start` MODULE_ERROR "the
  Module Loader cannot start: …" once what it started is released; nothing else is stopped or
  destroyed, and a shutdown request before that still gives CANCELLED (RUN-0759). Tested with a
  startup deadline that passes at once (`test_loader_engine`, I89 part 4b-1d).
- **Note 2026-11-14 (G61 amended):** the deadline that case expires is now the Loader's own
  (`loaderStartupDeadline`), from the open through its binding checks. A short startup deadline for the
  modules no longer fails the open. The codes are unchanged; the interim stays open with TF-25.

### G191 — The execution intent of the instance the bootstrap realizes
- **Kind:** GAP · **Specs:** RUNTIME l.3644 (the origin of `requested` intent is the authenticated
  requesting module), l.1667 (no fabricated consumer), l.2052-2056 (the execution state has no origin
  field), l.3500 (`uninitialized` means no execution choice yet), l.3538 (`recover_module` needs
  `requested`).
- **Description:** the bootstrap realizes the orchestration instance with no requesting module, and the
  text names no intent for it.
- **Interim:** `requested`, with an `intent_revision`, whose origin is the internal protected-input
  marker (I75's `Origin(host: true)`); with `uninitialized` a failed orchestration instance could never
  be recovered, only started anew. With persistence a second question appears (does startup
  re-establish an orchestration instance whose retained intent is `stopped`, l.1640 against l.1838 and
  l.3842); a later tier.
- **Second question, interim 2026-11-12 (owner's U2 for step 6; built in I82):** startup re-establishes
  the orchestration instance at every host start (l.1640; l.3808 names a host restart as the way back
  from a stopped orchestration). A retained `requested` intent whose origin is the host is resumed
  through the recovery path, keeping intent, intent revision and origin. Any other (`uninitialized`,
  `stopped`, or `requested` by a module) is replaced by an ordinary start with the host as origin, with
  a diagnostic ("startup re-established orchestration whose intent was stopped", or "…requested by
  X"). A module-origin intent is not resumed because recovery checks the retained origin's execution
  authority (l.3540), not bootstrap policy as l.1640 requires, and with an external authority that
  check cannot run before orchestration is up (l.1643); the Fable review added this case (its U2).
  Reported as TF-26's second question.
- **Status:** OPEN (TF-26, logos-lips `bf9b325f`); found 2026-11-11 by the Fable session reviewing the
  step 5 plan (its X1). Interim accepted by the owner and built in I81; the second question in I82.
- **Re-checked 2026-11-13 (I89, part 4b-1c):** the Module Loader instance's intent is treated exactly
  as orchestration's: `requested` with the host as origin, re-established at every start before
  orchestration, resumed through the recovery path when retained so, replaced with a diagnostic
  otherwise.
- **Built 2026-11-13 (I94, part 4b-5b):** the reference module leaves itself out; its own resumption is the
  engine's and is never counted.

### G192 — Host acceptance of a Runtime-generated identity
- **Kind:** GAP (low) · **Specs:** RUNTIME l.2665-2667 (a Runtime-generated id: "the runtime host MUST
  accept it before the id is used"); §13 has no operation that shows the id to the host.
- **Interim:** `docs/HOST-CONFIG.md` states that choosing `logos-core-nim.app-config.v1` is the host's
  acceptance of a fresh UUIDv4 per `start`. The format has no field for the id until persistence
  (l.3505-3506).
- **With persistence, interim 2026-11-12 (owner's U3 for step 6; built in I82):** an optional
  `runtime.runtime_instance_id`, host-assigned, allowed only with `runtime.store_dir`. With a store and
  no configured id, a lowercase UUIDv4 is generated when the store is created and kept in it; choosing
  a store without an id is the host's acceptance (TF-27's reading). A configured id that differs from
  the stored one makes `start` fail INVALID_PARAMS, writing nothing. A deleted, replaced or restored
  store under a host-assigned id needs a new id (`docs/HOST-CONFIG.md`, "Identity"). Without a store, a
  fresh id per start, as before. The remote profiles' l.2671 ("The runtime host or authorized
  provisioning system generates it once and preserves it") is not claimed to be met by a generated id:
  a remote profile, when built, requires the host-assigned field.
- **Status:** OPEN (TF-27, logos-lips `bf9b325f`); found 2026-11-11 by the Fable session (its X2).
  Interim accepted by the owner and built in I81; the persistence part in I82.

- **Amended 2026-11-15 (I95, part 4b-6a):** under logosd the id is host-assigned: `logosctl init`
  generates a lowercase UUIDv4 from the operating system's CSPRNG, writes it into daemon-config, binds
  the evidence key to it (G299's neighbour, batch E item 19) and keeps it for the session's life; logosd
  always configures it with a store (G294). The interim above applies to other hosts.
- **Amended 2026-11-15 (I95, part 4b-6c; the spec review of the 4b-6 plan):** `logosctl init` also makes
  the Runtime's store (`state/store/runtime-state.cbor`, holding the id and no instance), and logosd never
  makes one: a start whose store is missing is refused (exit 1, "the Runtime state store is missing …").
  Otherwise a lost `state/` (with the trust mark re-established) would start a new store under the
  session's fixed id, and the fixed system instance ids and the configured operator ids would name
  unrelated instances at old addresses (RUNTIME l.2630 "Equal identifier strings alone MUST NOT establish
  that continuity", l.2632). A restored backup of `state/` is a store, and starts. A lost one needs a new
  session (`init`), hence a new id and key.
### G193 — What a preserved instance is after the Runtime ended without completing shutdown
- **Kind:** GAP · **Specs:** RUNTIME l.562 (apart from a stop, `ready` is left only by an unexpected
  realization failure, to `error`), l.565 (`unloaded`: known, with no active local realization), l.570
  (`error`), l.611-612 and l.627 (cleanup completion), l.2634 (preservation across restart is not
  required), l.3505-3506 (persist before exposing; advance revisions after restart), l.3534 (retained
  selection is not a current realization merely because it survived a restart), l.3753 (the failure
  classifications), l.3775 (documentation must distinguish resumption after a Runtime restart from
  retries after execution failure), l.3783-3784 (a direct realization shares the process).
- **Description:** nothing says what an instance that was `loaded`, `ready` or `stopping` when the
  Runtime ended (a crash, a kill, a power loss) is after a restart, nor whether bringing it back is a
  retry.
- **Options offered (S6-1 of the step 6 plan):** (a) always `unloaded`, no failure; (b) `unloaded` after
  a clean end, `error` after an unclean end *(recommended, with `host-terminated`)*; (c) always `error`.
- **Interim (owner's U5 for step 6, 2026-11-12):** (b) with the classification `other`, not
  `host-terminated`. A clean end (a completed shutdown) already stores `unloaded`. A stored `loaded`,
  `ready` or `stopping` instance is restored as `error` with `other` and the reason "the Runtime ended
  without completing shutdown", with no realization; its intent, intent revision and origin are kept.
  An instance stored as `error` keeps its classification. No retry is charged: `docs/HOST-CONFIG.md`
  calls bringing an instance back after a restart, clean or not, a resumption (l.3775). A module that
  crashes the shared process is then visible as `error` to a restart policy. One proc,
  `engine.restore`.
- **Status:** OPEN (TF-29, logos-lips `9a8d4c14`); found 2026-11-12 planning the Runtime slice step 6.
  Built in I82.
- **Amended 2026-11-13 (owner, batch B 9; G289):** a first recovery with no open episode is a
  resumption; an open episode is charged across a Runtime end; under a `disabled` policy every
  `requested` instance in `error` is resumed once after the orchestration module starts. A hosted crash
  is a live failure and charged (K6). Built by the reference orchestration module (I94).
- **Amended 2026-11-14 (owner, batch C 11; G275):** a stored hosted instance is restored as above only
  once its restart lock can be taken; until then its `realization` is `unknown` and `start_module` and
  `recover_module` answer NOT_READY. Built in I91 (part 4b-3.1b).

### G194 — The code for a `retire_module` target owned by another Runtime
- **Kind:** GAP · **Specs:** RUNTIME l.3558 ("The target's `runtime_instance_id` MUST identify the
  Runtime exposing this contract"), l.3515, l.2611-2612, l.2579 (the same rule for other methods);
  against l.449 and l.3659 (a provider address on another Runtime: INVALID_PARAMS, without structured
  detail) and l.3662 (an unknown record: non-revealing NOT_AUTHORISED).
- **Description:** the rule names no code. INVALID_PARAMS follows by analogy with l.3659; the address
  also names no record this Runtime knows, which l.3662 answers NOT_AUTHORISED.
- **Interim (owner's U7 for step 6, 2026-11-12; S6-2 of the step 6 plan):** INVALID_PARAMS without
  detail, checked after the payload and before the target's authorization (G171), whether or not an
  instance of that id exists here. `engine.retire`.
- **Status:** OPEN (TF-30 point 1, logos-lips `9a8d4c14`); found 2026-11-12 planning the Runtime slice
  step 6. Built in I82.

### G195 — The code when `create_module` selects no declaration
- **Kind:** GAP · **Specs:** RUNTIME l.3614 ("Runtime MUST select one accepted declaration for `module`
  under active policy or fail the request"), l.3616-3619 (an unavailable or unacceptable selection
  fails without substitution; no selection fails without creating an instance), l.1371 and l.3439
  (unknown targets: non-revealing NOT_AUTHORISED), l.3442 (MODULE_ERROR where no code applies); G55
  ("fails without disclosure").
- **Description:** the request must fail and no code is named. NOT_AUTHORISED, INVALID_PARAMS and
  NOT_READY can each be argued, and they tell the caller different things about which modules this
  deployment can create.
- **Interim (owner's U7 for step 6, 2026-11-12; S6-4 of the step 6 plan):** the non-revealing
  NOT_AUTHORISED a denied `create_module` gets, with the same message; nothing is created and no key
  is kept. `engine.createModule`.
- **Status:** OPEN (TF-30 point 2, logos-lips `9a8d4c14`); found 2026-11-12 planning the Runtime slice
  step 6. Built in I82.

### G225 — A Runtime Control subscription that the Runtime ends gives its subscriber no signal
- **Kind:** GAP · **Specs:** INTERFACE l.1461-1465 (a subscription ends only with its route; a
  Runtime Control binding has none), l.1474-1476 (`observe_end` exists only on route handles), l.3837;
  RUNTIME l.3426 ("Connection or subscription loss requires resubscription and a fresh query"), l.3428
  (periodic resynchronization), l.3511, l.3732-3733; TRANSPORT l.801, l.812-815.
- **Description:** the Runtime can stop serving a Runtime Control subscription: events are committed
  faster than its handler returns until the Runtime's bound is reached. Nothing says what the Runtime
  may then do (end it, drop events, hold up the committing operation), and no operation, result or
  event tells a local subscriber that its subscription was lost; l.3426 says only what an observer
  does after a loss.
- **Options (step 7 plan S7-1):** (a) end it, record a diagnostic, document that observers
  resynchronize *(recommended)*; (b) keep it and drop events (a silent gap in a subscription that looks
  alive); (c) an unbounded queue; (d) block the commit (an observer stalls other modules' lifecycle,
  what G178 avoids); (e) a distinct code from a later `unsubscribe` (INTERFACE l.1446 wants LOGOS_OK
  once inactive, and the module may never call it).
- **Interim (approved 2026-11-12 with G178):** (a). One more admitted entry than `rcQueue` (256), or
  one more waiting for a decision than `rcUnjudged` (256), ends the subscription: deactivated, its
  entries discarded, the diagnostic "Runtime Control subscription <id> of <instance> lost: <why>
  (G225)" recorded, where <why> is "its handler fell behind", "the decisions on its events fell
  behind" or, for a hint that may be owed only for subjects it did not retain (G178's D2), "a hint it
  may be owed names only subjects it did not retain". `unsubscribe` of it is LOGOS_OK; it counts
  toward the subscription limits until then or until its binding ends. An `inventory_changed`
  subscription never overflows its queue (one pending hint per collection; `rcQueue` is at least 2).
  HOST-CONFIG.md tells observers to query and resubscribe, periodically when a loss cannot be ruled
  out. `engine.loseRc`.
- **Status:** OPEN (TF-35, logos-lips `9a8d4c14`, an addendum to TF-22); found 2026-11-12 planning the
  Runtime slice step 7; built 2026-11-13 (I86, step 7b).
- **Built 2026-11-13 (I94, part 4b-5b):** the reference module subscribes anew at every resync (`resync_ms`),
  before it drops its old subscriptions, and re-reads every instance.

### G226 — Which facts of an observation a Runtime Control selector is compared with
- **Kind:** GAP · **Specs:** CA l.301-308 (every present selector must match the attempted operation or
  returned observation, CAP-0055), l.554-567 (alternatives, never combined); RUNTIME l.3372-3376,
  l.3402, l.3420 (facts retained for later disclosure checks), l.3496 (an instance event carries no
  `provider`), l.2103-2112 (`route_record` with a required `consumer`).
- **Description:** a `module_record` or a `route_record` names several modules, instances and
  providers; nothing says which of them the scope's `modules`, `instances`, `providers` and `routes`
  are compared with, nor whether a `providers` selector matches an observation that carries no
  provider. A route record discloses its consumer whatever the scope says (TF-34).
- **Interim (step 7 plan S7-2, approved 2026-11-12):** (a) the observation's own subject facts: a
  module record's `module`, `instance` and, when the record carries it, `provider`; a route record's
  `route`, the provider `module`, the provider `instance` and `target_provider`, never the consumer;
  an instance event's `module` and `instance`; a route event's `route`, `module` and provider;
  `describe_provider`'s provider; a summary's or permission-settings target's `module` and `instance`.
  A selector naming a fact the observation lacks does not match it, so a `providers` selector never
  admits a record without a provider. An allow admits a subject when one allowed scope covers, whole,
  the scope of observing exactly that subject (`observe.methodScope`, `observe.admitsScope`); the
  internal policy, when its rules allow the request naming the subject (`Authorizer.permits`).
- **Status:** OPEN (TF-34, logos-lips `9a8d4c14`); found 2026-11-12 planning the Runtime slice step 7.
  Built in I86 (lists in 7a; events and hints in 7b).

### G227 — A realization change without a lifecycle transition
- **Kind:** GAP · **Specs:** RUNTIME l.3504-3509 (the revision advances when an attempt is accepted or
  the lifecycle state changes; `execution_state_changed_event` reports summary changes), l.3530-3534
  (`realization`), l.1833, l.1913 (a guarded request at a stale revision is INVALID_PARAMS).
- **Description:** `realization` can change with no lifecycle transition: a Loader bind returning, a
  cleanup past its deadline ending (G180). Nothing advances the revision for it, so an observer cannot
  tell the summaries apart and the event that is said to report it has nothing to report (TL-08). If
  it does advance the revision, a guarded request prepared before the change becomes stale.
- **Interim (step 7 plan, TL-08 extended, approved 2026-11-12):** the change is a commit: the revision
  advances, the change is written and exposed (and, from step 7b, gives `execution_state_changed_event`
  and a `modules` hint). A guarded `start_module`, `recover_module` or `retire_module` prepared with
  the revision read before it is INVALID_PARAMS; the caller reads the revision again (HOST-CONFIG
  "Observation"). Restart accounting is unaffected: step 6 counts accepted `recover_module` calls,
  never revision steps (I82). The Runtime compares each instance's realization after every step on
  its thread and commits those that moved without a commit of their own in that step
  (`engine.followRealizations`), so a dynamic start makes one commit more, at its bind's return.
- **Status:** OPEN (TL-08, extended in logos-lips `9a8d4c14`); found 2026-11-12 planning the Runtime
  slice step 7. Built in I86.
- **Built 2026-11-13 (I94, part 4b-5b):** the reference module never counts revisions: its accounting counts the
  `recover_module` calls it makes.

### G228 — The code for a `get_execution_summary` or permission-settings target owned by another Runtime
- **Kind:** GAP · **Specs:** RUNTIME l.3515 (the summary's target must belong to the Runtime exposing
  the contract), l.2578-2579 (the same for permission settings), against l.449 and l.3659
  (INVALID_PARAMS for a provider address on another Runtime) and l.3662.
- **Description:** as G194: the rule names no code (TF-30 point 1 covers every such target).
- **Interim (step 7 plan, approved 2026-11-12):** INVALID_PARAMS without detail, after the payload and
  before the target's authorization, as G194. `engine.localTarget`.
- **Status:** OPEN (TF-30 point 1, logos-lips `9a8d4c14`); found 2026-11-12 planning the Runtime slice
  step 7. Built in I86.
- **Extended 2026-11-13 (I87, step 9a):** to the five configuration operations: a target on another
  Runtime is INVALID_PARAMS without detail, after the method's authority and the payload.

### G229 — Permission settings in direct mode
- **Kind:** FREE (settled by spec text) · **Specs:** RUNTIME l.2526-2604: l.2541 (a new instance
  without accepted settings has revision 1, `[]`, `applied`, no failure), l.2536 (unknown definitions
  are INVALID_PARAMS without detail), l.2545, l.2584 (repeating the applied settings returns them),
  l.1622; SECURITY l.204 (direct modules are trusted in-process code); CA l.392.
- **Description:** the step 7 plan first read direct mode as having no permission settings at all
  (MODULE_ERROR, N2). The text gives them a constant form: no permission profile is selected, so no
  definition is known and only the initial value can ever be the current one.
- **Decision (step 7 plan corrections, approved 2026-11-12):** build that form. `get_permission_settings`
  answers revision 1, `[]`, `applied`, no failure for every local instance; `update_permission_settings`
  answers that state for `[]` at revision 1, INVALID_PARAMS without detail for any named permission and
  for any other revision, and changes nothing. Nothing is stored. `permission_settings_changed_event`
  is never produced. That `applied` with `[]` claims no containment goes to TF-06's editorial list.
  `engine.permissionSettings`.
- **Limited 2026-11-14 (owner decision 3, 2026-11-13; I93, part 4b-4b):** this is the form while no
  permission profile is selected, which stays the library's default; every constant-form test stands.
  With a profile (`app-config.v1` `permissions`, G279) each instance has its own saved settings, and
  `permission_settings_changed_event` follows each committed change (I93).
- **Status:** decided and built 2026-11-12 (I86); limited to "no profile selected" 2026-11-14.

### G230 — The implementation `selection` a summary reports for the in-process realizer
- **Kind:** GAP · **Specs:** RUNTIME l.3517-3528 (`selection`; "Other realization mechanisms MUST use
  `implementation-specific`"), l.3519 (`package` and `signer` only for a package-backed selection);
  LOADER §3 (the strategy names).
- **Description:** the in-process realizer is shaped like the Module Loader contract but is not a
  Loader instance; whether it may report a Loader strategy name (`direct_static`, `direct_dynamic`)
  and the Loader's error classifications is not stated (TF-36).
- **Interim (step 7 plan, Fable review §7.1, approved 2026-11-12):** `implementation-specific`, for
  every instance; no `package` or `signer` while no selection is package-backed. The `loader-` failure
  classifications stay as they are until step 11 decides them (S11-1).
- **Status:** OPEN (TF-36, logos-lips `9a8d4c14`); found 2026-11-12 in the Fable review of the step 7
  plan. Built in I86.
- **Read 2026-11-13 (step 11, S11-1 option (b), fable-review §7.1, approved by the owner):** the
  realizer is an implementation-local realization mechanism (RUNTIME l.212, l.38), not a Module Loader,
  so `implementation-specific` is what l.3528 asks for, not only an interim, and LOADER is
  `deferred:tier-4b` as a whole (LOADER l.23-26). The `loader-<code>` classifications are removed:
  l.3754 needs a typed Module Loader error. A realizer error other than a failed `_MODULE_init`
  (`initialization-failed`) is `other` (l.3757; l.2493 forbids `other` only where a defined code
  matches), and its message stays in the diagnostics (I88, part 11a). TF-36 stays the owner question;
  representing the realizer as a `logos_module_loader` instance (option (a)) is the first item of Tier 4b.
- **Built 2026-11-13 (I89, part 4b-1c):** the strings change back: a Loader-realized instance reports
  its strategy, the Loader itself `implementation-specific` (G57), and typed Loader errors are
  `loader-<code>` again. The question stays TF-36's.

### G233 — The code for a configuration state that would not fit the 16 MiB frame
- **Kind:** GAP · **Specs:** CONFIG l.108-115 (reject without mutation any source or state transition
  whose complete state would not fit; the in-flight rule); the §5 table (l.192-198) and the §8 table
  (l.292-296) have no row for it; RUNTIME l.2609 sends configuration invocations to those tables.
- **Description:** two values near 8,388,608 bytes cannot both be retained, so an ordinary
  `update_configuration` reaches the rule, and no code is assigned (TF-30 point 3).
- **Options offered:** (a) MODULE_ERROR without detail, as TRANSPORT l.385-386, RUNTIME l.3383 and
  INTERFACE l.1483 and l.2041 treat capacity *(recommended)*; (b) INVALID_PARAMS without detail; (c)
  NOT_READY, excluded by RUNTIME l.660 and l.3443.
- **Interim (step 9 plan S9-1, approved by the owner 2026-11-13):** (a), with no mutation. A mutation is
  admitted only if a maximal `get_configuration` response frame (128-byte identifiers, the 9-byte call
  id) fits, for (current, staged) and, during an attempt, for (attempted, staged). Revisions are
  measured at their 9-byte maximum encoding, so no promotion is ever refused for size; that
  over-rejects by at most 24 bytes at the edge. A provisioned value at host start that would not fit
  fails `start` with MODULE_ERROR naming the instance, before any module runs. `config.admissible`.
- **Status:** OPEN (TF-30 point 3, logos-lips `9a8d4c14`); found 2026-11-12 planning Tier 4 step 9.
  Built in I87.

### G234 — The code when the configuration-state revision cannot advance
- **Kind:** GAP · **Specs:** CONFIG l.99-101 (the revision does not wrap; a mutation past `uint64`'s
  maximum is rejected, and so is a startup or live-reconfiguration attempt before module behavior runs),
  l.234 and l.241 (the promotion of a successful attempt is mandatory); RUNTIME l.3442-3443, l.3507.
- **Description:** no code is given for `update_configuration`, `start_module` or `apply_configuration`
  (TF-30 point 4). A single check when an attempt starts is not enough: an update at the last revision
  during the attempt would make its mandatory promotion impossible.
- **Options offered:** (a) MODULE_ERROR, as RUNTIME l.3442 classes resource and internal failures
  *(recommended)*; (b) INVALID_PARAMS. NOT_READY is excluded (l.3443).
- **Interim (step 9 plan S9-2, approved by the owner 2026-11-13, with the headroom fix):** (a), with no
  mutation and no module behavior. While an attempt whose promotion would change the state is in
  flight, a concurrent mutation is admitted only if one revision step stays free for the promotion. A
  refused start is left as for G162: intent kept, no failure. `config.canMutate`, `config.canAdvance`.
- **Status:** OPEN (TF-30 point 4, logos-lips `9a8d4c14`); found 2026-11-12 planning Tier 4 step 9.
  Built in I87.

### G235 — A configuration summary for an instance without a binding
- **Kind:** GAP · **Specs:** CONFIG l.50, l.176-177 (`get_configuration_summary` for an instance
  without an accepted binding), l.329 (the summary type: `state_revision` is required).
- **Description:** what `state_revision` is when no configuration state exists (TL-09).
- **Interim (step 9 plan, approved by the owner 2026-11-13):** `{state_revision: 0}` with
  `schema_commitment`, `current` and `staged` omitted, as CFG-0107 omits them from the event. The four
  other configuration operations are INVALID_PARAMS without detail (l.194).
- **Status:** OPEN (TL-09, logos-lips `68628d95`). Built in I87.

### G236 — What `applied_value_revision` names
- **Kind:** GAP · **Specs:** RUNTIME l.2457 (`apply_configuration_response.applied_value_revision`);
  CONFIG l.119 (a promotion keeps the record's value revision).
- **Description:** no prose says which revision the field reports (TL-10).
- **Interim (step 9 plan, approved by the owner 2026-11-13):** the attempted record's value revision,
  which promotion leaves unchanged.
- **Status:** OPEN (TL-10, logos-lips `68628d95`). Built in I87 (step 9b): `engine.applied`.

### G237 — An application deadline that passes while the instance is stopping
- **Kind:** GAP · **Specs:** CONFIG l.269-274 (expiry without a valid result is indeterminate; an
  explicit stop may close admission while the hook runs but must not destroy the context; a stop alone
  does not make the outcome indeterminate), l.311-313 (an indeterminate outcome places the instance in
  `error`); RUNTIME l.611-612 (a completed explicit stop is `unloaded`; cleanup after a failure does not
  by itself leave `error`), l.3757 (a later cause replaces an earlier one).
- **Description:** when the application deadline passes while the instance is `stopping`, the outcome
  is indeterminate, so l.312 asks for `error`; the stop in progress then completes, and l.612 asks for
  `unloaded`. Which one the instance ends in, and when, is not stated (an addition to TF-28).
- **Interim (step 9 plan, TF-28 added, approved by the owner 2026-11-13):** at expiry the instance
  enters `error` with `configuration-indeterminate`, the caller gets MODULE_ERROR, and the stop's
  waiters keep waiting. When the hook returns the context is destroyed; if the stop completes within
  its own stop deadline, the instance becomes `unloaded` with the failure cleared, as any completed
  stop. If the stop deadline passes first, G180 applies: `cleanup-timeout`, the stop is answered, and the
  instance stays `error` when the late cleanup ends. A second stop meanwhile is answered with the state
  at once, as during `stopping`. Consistency item C34's alternative (the stop itself ends the
  application as indeterminate) is not built. `Inst.indeterminateStop` in `engine.nim`.
- **Status:** OPEN (in the comments document as part of TF-28; not sent to the spec owner); found 2026-11-13 in the review
  of the step 9 plan. Built in I87 (step 9b).

### G241 — One payload depth setting for the Runtime
- **Kind:** FREE · **Specs:** INTERFACE §4.5.1 l.3148-3152 (arrays and maps counted from the payload
  root; a documented, finite, configurable maximum of at least 128; internal structures MUST NOT reduce
  it); TRANSPORT §2.3 (the envelope's own levels); G59.
- **Description:** each layer had its own depth (the CBOR decoder's `maxDepth`, `ContractValidator.maxDepth`,
  `TransportLimits.payloadDepth`), all 1024 by default, and nothing a host could configure for the
  Runtime (IF-02; consistency item C36).
- **Decision (step 11 plan §2.8, fable-review §7.4, approved by the owner 2026-11-13):** one setting,
  `runtime.max_payload_depth` in `logos-core-nim.app-config.v1`, 128 to 1024, default 1024; out of range
  is INVALID_PARAMS at `create`. `EngineConfig.maxPayloadDepth` reaches every validator and decoder the
  engine builds: route requests and responses (synchronous and asynchronous), events, Runtime Control
  requests and responses, and configuration values (defaults, provisioned and updated). A transported
  route (10b) gives `TransportConfig`'s frame decoder this depth plus the envelope's levels (l.3148).
  Kits built by lcn-gen check their own inputs at 1024.
- **Status:** decided and built 2026-11-13 (I88, part 11a). `[IMPL-DECISION G241]` in `test_async`,
  `test_config` and `test_host`.
- **Wired to the transport 2026-11-13 (I90):** the engine's transport I/O thread decodes envelopes at
  the same depth (`TransportConfig.maxPayloadDepth`, whose decoder adds the envelope's own level).

### G242 — Asynchronous work nested deeper than the worker pools
- **Kind:** FREE · **Specs:** INTERFACE l.2040-2041 (unavailable local capacity is MODULE_ERROR),
  l.2051-2054 (every outcome after submission, local rejection included, reaches the one completion
  callback, which may begin on any thread); RUNTIME l.3442.
- **Description:** I78 left a deviation: asynchronous calls nested deeper than the 64 call workers, each
  waiting on the next, deadlock, and so do 64 lifecycle jobs (completion callbacks) that each wait for
  work queued behind them. A per-thread "nested" mark (step 11 plan §2.6) misses a call submitted from a
  module-owned thread.
- **Decision (fable-review §7.3, fix 5, and D-d; approved by the owner 2026-11-13):** starvation on both
  pools. A pool whose queue is not empty while every worker is busy and none of its jobs has finished
  for `EngineLimits.starvationDelay` (50 ms) spawns one overflow worker, up to `MaxNestedWorkers` and
  `MaxNestedCallWorkers` (64 each) beyond the cap. When the call pool stays starved for
  `EngineLimits.refuseDelay` (1 s) with all 128 call workers busy, the oldest queued call that has not
  started is decided MODULE_ERROR "no call worker is available" and reported through its completion
  callback on a lifecycle worker, never on the Runtime thread. The lifecycle pool never refuses: init,
  destroy, completion callbacks, `observe_end` handlers, apply hooks and `request_cancel` cannot be
  failed, so 128 lifecycle jobs that each wait for work queued behind them can still stall. Overflow
  workers are joined by `close` like the others.
- **Status:** decided and built 2026-11-13 (I88, part 11a). `[IMPL-DECISION G242]` in `test_async`.

### G243 — A static record that names a binding the host never registered
- **Kind:** FREE · **Specs:** RUNTIME §13 (static registration, `start`), l.3442.
- **Description:** a host configuration's `direct_static` record, or a declaration, names a binding that
  `logos_runtime_register_static` never received. Decided as the owner's S4 in the step 5 plan
  (I81; extended to declarations in I82) without a G row, so its tests carried `[IMPL-DECISION S4]`.
- **Decision (owner's S4, 2026-11-11):** `start` is INVALID_PARAMS naming the instance or the
  declaration, before any instance is created or any module code runs. A retained instance whose binding
  is no longer registered is not refused at `start`; its start or recovery fails in the realizer.
- **Status:** decided and built (I81, I82); given this row 2026-11-13 (I88, consistency item C41).

### G244 — The code when a route would carry a marked payload
- **Kind:** FREE (by analogy) · **Specs:** INTERFACE §1.4.1 l.381-389 (marked payloads are erased; l.388:
  no invocation path for a marked payload unless its implementations support these requirements;
  l.389: no silent downgrade); RUNTIME l.3197 (no handle when establishment fails), l.3442 (other
  internal failures are MODULE_ERROR).
- **Description:** Tier 4 does not erase marked payloads (D-c), so the Runtime must not establish a
  path for a contract that marks one, and no code is given for that refusal.
- **Decision (fable-review §7.4, D-c, approved by the owner 2026-11-13):** `establish_route` fails after
  the authority and contract checks and before readiness with MODULE_ERROR "marked payloads are not
  supported on this path (INTERFACE §1.4.1)", and no handle is returned: the request is valid and
  authorized, and the missing capability is the Runtime's own. 8b's retention refusal in `admit`
  (IFC-0581) stays as a second guard. Erasure (IFC-0575 to IFC-0577, IFC-0580, IFC-0581, SEC-0057) is
  Tier 4b.
- **Re-decided 2026-11-14 (owner, batch C 14; G277):** lifted for the participants the Runtime
  controls; each participant answers for its own copies (IF l.388, l.400-401); no global switch turns
  the refusal off. The refusal, with its code and message, stays for a path kind without erasure.
- **Status:** decided and built 2026-11-13 (I88, part 11a); re-decided 2026-11-14 as G277, built
  2026-11-15 (I92). `test_wipe_routes` W-10, `test_hosted_routes` C-10.

### G246 — One Module Loader instance per Runtime, and its reserved names
- **Kind:** GAP (K4; TF-45 point 4), decided by the owner (step 4b-1 plan, decision 5) · **Specs:** BOOTSTRAP
  l.287-290 (a bootstrap Loader; bootstrap is non-recursive); RUNTIME l.1635-1650 (the Loader
  binding), l.3813-3818 (an unavailable Loader); LOADER l.23, l.80 (LDR-0006).
- **Description:** the specs let a Runtime bind a Module Loader but say neither how many instances
  there are, who establishes them, nor how one comes back after it fails.
- **Decision:** one Loader instance per Runtime, `logos_module_loader` (instance id, module name and
  static binding id alike), established by the engine at every open through a bootstrap mechanism
  whose only registration is the Loader's, and never re-established within the process. Its names are
  reserved: host configuration (instances, declarations, `orchestration`), `create_module`, static
  registrations and `logos_runtime_register_binding` cannot use them (INVALID_PARAMS). The Loader has
  failed when its record is `error`; it is unavailable once stopped while owning nothing (RUNTIME
  l.3816-3817), after which every start is NOT_READY. A host restart is the way back.
- **Status:** decided and built 2026-11-13 (I89, parts 4b-1a, 4b-1c, 4b-1d). `test_loader_engine`,
  `test_host`.

### G247 — The lifecycle answers on the Module Loader instance
- **Kind:** GAP (K5, S4b1-5; TF-45 point 1), decision 5 plus the code choices · **Specs:** RUNTIME l.3563-3572
  (retirement of a live dependency), l.3683, l.3863; INTERFACE l.1997.
- **Description:** what `stop_module`, `start_module`, `recover_module` and `retire_module` do when
  they target the Loader instance.
- **Decision:** `stop_module` is NOT_READY while the Loader owns a realization (failed, unresolved and
  in-flight ones included); owning none it is accepted, its release waiting for the calls into it as
  any provider's does, and every later start of any instance is NOT_READY. Recovery and retirement are
  NOT_READY, and so is a start when it is not `ready`; a start of the ready Loader answers its state.
- **Status:** decided and built 2026-11-13 (I89, part 4b-1c). `test_loader_engine`.

### G248 — A direct-only Module Loader
- **Kind:** Reading (K10), decision 10 · **Specs:** LOADER l.252-259 (capabilities advertise what the
  Loader can satisfy), l.377 (`unsupported-strategy`).
- **Description:** whether a Loader that advertises no hosted strategy conforms, and what becomes of
  LOADER's hosted rules.
- **Decision:** it conforms: each capability field advertises what the Loader can satisfy, and
  anything not advertised is `unsupported-strategy`. LOADER is claimed for the direct strategies; the
  hosted units (§5.3, §5.4 and the hosted rules elsewhere) are `deferred:tier-4b` for the Module Host
  (4b-3), not `out-of-scope`. LOADER l.258 is a note for the spec owner if anything is reported.
- **Status:** decided and built 2026-11-13 (I89; `conformance/claims/LDR.toml`).

### G249 — Arranging termination of direct realizations after Loader loss
- **Kind:** GAP (new, S4b1-1) · **Specs:** RUNTIME l.3821-3823 (cleanup ownership is kept until the
  mechanism confirms the end; "arrange termination through protected host or deployment
  supervision"), l.3778, l.3782, l.3837-3839; RUNTIME §13 (no channel from the Runtime to the host
  besides `wait_for_shutdown`).
- **Description:** for a direct realization the execution envelope is the host's process. Only the
  host can end it, and the Host Embedding API gives the Runtime no way to ask.
- **Options offered:** (a) keep running; record "termination required"; call a Nim-level hook for
  in-process hosts; `wait_for_shutdown` MODULE_ERROR and `destroy` NOT_READY, so a C host learns at
  shutdown and must exit *(recommended)*; (b) the engine starts its own shutdown at once (l.3782);
  (c) the library aborts the process.
- **Decision (owner, batch A item 6, 2026-11-13):** (a). When a Loader that owned realizations fails,
  the Runtime writes the diagnostic "termination required: the host process must end to clean …"
  naming them, and calls `EngineConfig.onTerminationRequired` once (logosd's, 4b-6).
  `wait_for_shutdown` returns MODULE_ERROR with "; the Module Loader failed: the host process must
  end", and `destroy` is NOT_READY with that text. A Loader that fails owning nothing is released.
  Tests confirm the end with a test hook (`confirmTerminationForTests`) that stands in for the host's
  exit.
- **Status:** interim, built 2026-11-13 (I89, part 4b-1d). The question is a host-side signal in
  RUNTIME §13; in the comments document as TF-45; not sent to the spec owner. `test_loader_engine`.
- **Built 2026-11-15 (I95, part 4b-6b):** logosd is the supervision R l.3823 asks for (G302): it ends
  its process with exit 4, without destroy, after the Module Hosts are gone.

### G250 — The classification of a failed `_MODULE_init` behind the Loader
- **Kind:** Reading for the string (RUNTIME l.1568-1569, l.3752), Choice for the carrier (RUNTIME
  l.28-30; D14) (S4b1-2, K35; TF-49, and TF-29 as extended) · **Specs:** RUNTIME l.3752-3754; LOADER l.625, l.633-636.
- **Description:** the Runtime receives `realization-failed` from the Loader, and could tell that the
  module's init failed only by reading the message.
- **Options offered:** (a) `loader-realization-failed`; (b) `initialization-failed`, the Loader passing
  the failed phase through the side table.
- **Decision (owner, batch A item 3, 2026-11-13):** (b). The Loader records the failed phase in the
  attempt's inbound side-table entry; `realization-failed` with the phase `init` is
  `initialization-failed`, a failed or rejected init that wrote a context included (an error and no
  record: K35's conservative reading, so LDR-0125 waits for the hosted strategy);
  `loader-realization-failed` only when no phase is given. No failed realization is retained at
  `realize`.
- **Status:** decided and built 2026-11-13 (I89, parts 4b-1b, 4b-1c). `test_loader`, `test_engine`.

### G251 — Ordinary routes to the Module Loader
- **Kind:** Choice over a gap (S4b1-3) · **Specs:** RUNTIME l.168, l.209, l.1652-1655, l.1682, l.1688;
  CA l.343-345, l.354-358; LOADER l.80, l.426-427, l.505.
- **Description:** a module with a route to the Loader could release another instance's realization,
  or realize an instance the Runtime does not know, and nobody named could check the execution
  decision for it.
- **Options offered:** (a) refuse every ordinary route whose provider is the Loader, NOT_AUTHORISED,
  whatever the policy *(recommended)*; (b) allow `list_capabilities` and `get_status` under policy;
  (c) allow under policy.
- **Decision (owner, batch A item 4, 2026-11-13):** (a), as a fixed rule of this implementation, not
  rested on RUNTIME l.1682: `establish_route` whose contract or provider is the Loader's is
  NOT_AUTHORISED before any decision about it is asked. The Loader checks the caller too: every method
  serves only a SYSTEM_SERVICE caller and is NOT_AUTHORISED otherwise, changing nothing, after the
  kit's schema check (an undecodable request is INVALID_PARAMS first, INTERFACE l.3123-3124).
- **Status:** decided and built 2026-11-13 (I89, parts 4b-1b, 4b-1c). In the comments document as
  TF-37; not sent to the spec owner. `test_loader`, `test_loader_engine`.
- **Routing rules 2026-11-13 (I90, G254):** a routing rule naming the Module Loader, as caller or callee,
  is refused at decode; the Capability Authority may be a transported callee.

### G252 — When the Runtime decides the Module Loader has failed
- **Kind:** GAP (RT-05, the other half; S4b1-4; TF-45 point 3) · **Specs:** RUNTIME l.3793 (an ordinary invocation
  failure is not by itself a realization failure), l.3795, l.3823, l.3827; LOADER l.633-634.
- **Description:** RT-05's interim says what follows when the Loader has failed, not what makes the
  Runtime decide that it has.
- **Options offered:** (a) resolve lost answers with `get_status`; an invalid or unresolvable answer
  fails the Loader; (b) only the Loader's own report fails it.
- **Decision (owner, batch A item 5, 2026-11-13):** split. The Loader fails when it reports its
  failure or gives an invalid response (one that does not decode, or does not match the request). A
  `realize` or `release` whose invocation fails or whose reply is lost is resolved through
  `get_status`: no realization, and the start fails (`other`, "the realize call failed") or the stop
  completes; one found, and it is released (the start fails) or the stop is `cleanup-failed`. When
  `get_status` fails too, the instance stays `error` (`other`, "the Module Loader's answer was lost and
  could not be resolved") with its cleanup unresolved and its realization `unknown`; the Loader stays
  bound, and a stop of the instance is accepted.
- **Status:** decided and built 2026-11-13 (I89, part 4b-1d). `test_loader_engine`.

### G253 — Execution authority and permission settings of the Module Loader
- **Kind:** Reading (K36, C2; TF-46 point 1, TF-45 point 2) · **Specs:** CA l.343; RUNTIME l.2538, l.2543, l.2549.
- **Description:** whether the Loader instance, which the protected construction establishes, needs an
  execution decision, an `execute` check and permission settings like any other instance.
- **Decision:** no execution decision and no `execute` check: the protected construction authorizes it
  (CA l.343). It is not exempt from permission settings: the construction provisions them before the
  instance is exposed (`provisionBootstrapSettings`), the constant form under G229 until a profile
  exists. Step 4b-4 writes the selected profile's required list there and refuses settings updates
  aimed at the Loader (K37).
- **Status:** decided and built 2026-11-13 (I89, part 4b-1c). `test_loader_engine`. Its 4b-4 half
  built 2026-11-14 (I93, part 4b-4b): with a profile, `provisionBootstrapSettings` writes the minimum
  (revision 1, `applied`) before the Loader is exposed and installs it as its snapshot; an
  `update_permission_settings` aimed at the bound Loader is NOT_READY; a restored store without its
  record gets the minimum. `test_permissions`.

### G254 — Routing-selection input
- **Kind:** FREE (RUNTIME l.910-911 lets a host supply it) · **Specs:** RUNTIME §4.2 l.895-946 (the
  table at l.901-905), l.940 (renewal keeps the mode), l.3007; TRANSPORT §8.2.1.
- **Description:** RUNTIME says routing selection decides whether a route is direct or uses local
  transport, and that its policy MAY be internal or supplied by the host, but defines no input.
- **Decision (built in I90):** the host configuration's `lcn.app_config.routing` rules (caller module
  or any, callee module, mode). The rule naming the caller wins over the rule for any caller; with no
  matching rule a route is direct, so a configuration without rules behaves as before. The mode is
  fixed at `establish_route`; renewal never changes it. Refused at decode and at `newEngine`: two rules
  for one pair, an empty name, the reserved Module Loader as caller or callee (G251), Runtime Control
  as callee, and a `local-transport` rule where `logos.local.unix-stream` does not exist (Windows,
  §8.2.1). The Capability Authority may be a transported callee for ordinary consumers; the engine's
  own `evaluate` calls stay direct (G48(a)). Static in 4b-2; 4b-3 adds the hosted ends (a hosted end
  with no rule selects local transport, l.3007) in `routing.selectMode` alone.
- **Status:** decided and built 2026-11-13 (I90, part 4b-2a). `test_host`, `test_transported`.

### G255 — A replayed establish or renew answer and the ticket
- **Kind:** GAP (decided, owner decision 12; NA-04) · **Specs:** TRANSPORT l.1046-1047 (the same ticket
  is never reissued); RUNTIME l.3004 (`invocation` MUST be present when a ready transported route is
  returned by `establish_route` or `renew_route`), l.2845-2848 (request keys replay the retained answer).
- **Description:** a replay of an idempotent `establish_route` or `renew_route` must return the
  retained answer, which for a transported route would hold a ticket that was already issued: either
  the ticket is reissued, against TRANSPORT, or the replay lacks `invocation`, against RUNTIME l.3004.
- **Decision (owner, decision 12, 2026-11-13):** the replay returns the retained record, `ready`,
  without `invocation`; the consumer renews for a fresh ticket. The retained bytes never hold a ticket:
  the live answer goes to the consumer and to the call record, the redacted one is retained
  (`sessionauth.live`, `engine.establish`, `engine.renew`).
- **Status:** OPEN (NA-04 remark, not yet answered); interim decided and built 2026-11-13 (I90, part
  4b-2a). `test_transported`.

### G256 — A transported connection lost with no known cause
- **Kind:** GAP (decided, owner decision 12; TF-15) · **Specs:** RUNTIME l.3475; TRANSPORT l.541-547.
- **Description:** when a consumer's connection ends and the Runtime knows no authorization or
  readiness cause for it, neither spec says which code the handle and later operations get.
- **Decision (owner, decision 12, 2026-11-13):** TRANSPORT_ERROR for the handle's observer and its
  later operations; the route stays `ready`, and a new handle needs `renew_route` (G258).
- **Status:** OPEN (TF-15); interim decided and built 2026-11-13 (I90, part 4b-2b: `transported.closedCode`,
  `engine.linkClosed`). A prepared asynchronous call on such a handle completes with TRANSPORT_ERROR
  without dispatch, and the route's later end still decides new calls. `test_transported`, and the
  provider-stop cases of `test_routes_lt` and `test_async_lt` (a call still running past the stop
  deadline reaches its caller as TRANSPORT_ERROR, G260).

### G257 — The Runtime serves a direct provider over local transport
- **Kind:** READING plus a MAY (owner decision 6; K8; TF-38) · **Specs:** LOADER l.192-193 (the Runtime MAY
  expose a direct provider through a separate Transport invocation boundary); RUNTIME l.1514, §6.2
  l.1147-1175; TRANSPORT §3.1 l.451, §8.2.
- **Description:** a `local-transport` route to a provider realized in the Runtime's own process
  needs a Transport endpoint, which the Module Loader may not create for a direct realization.
- **Decision:** the Runtime serves it at an endpoint of its own under `runtime.endpoint_dir` (G58's
  layout), created the first time a transported route to that realization is established and removed
  when the realization leaves `ready` and its last session is gone. The record stays `direct`; RUNTIME
  l.1514 is read as the module's realization mode. Each Request runs on the engine's call workers as an
  asynchronous call with a session origin, admitted by the same `admit` as a direct call, and commits
  under its ticket's lock through the I/O thread's order. A ticket binds the provider as the flat module
  name the Hello carries (§3.1 l.451); the provider instance and its realization are bound by the
  endpoint, one per realization, and by the route. An endpoint that cannot be created fails the
  establishment MODULE_ERROR and makes no route.
- **Status:** decided and built 2026-11-13 (I90, part 4b-2a). `test_transported`.

### G258 — One session per materialization
- **Kind:** READING; no ticket reuse is a CHOICE (owner batch B 8; K11) · **Specs:** RUNTIME l.784,
  l.793; TRANSPORT l.1037-1047.
- **Description:** a ticket opens one session, and RUNTIME never says where a second handle on the same
  route gets one.
- **Decision (owner, batch B 8, 2026-11-13):** a materialization on a route whose ticket was used, is
  older than 60 s, or was never returned (a replay, G255) is NOT_AUTHORISED; a further handle needs
  `renew_route`. G164 and G177 are kept.
- **Built (I90, part 4b-2b):** the consumer's invocation material (the endpoint path and the ticket of
  the latest live answer) is kept on the Runtime thread by route, taken by move at materialization and
  zeroed wherever it goes; it is dropped when it expires, when the route ends, and when the consumer's
  attempt ends. A materialization whose connection fails has used it too (RUNTIME l.791: no replay, no
  implicit renewal). [IMPL] The NOT_AUTHORISED says "the route has no unused ticket; renew_route issues
  one".
- **Status:** decided and built 2026-11-13 (I90, part 4b-2b). `test_transported`, and the parity suites
  (`tests/support/routefixture.nim` renews once when a further handle needs a ticket).

### G259 — A peer-identity mismatch at materialization
- **Kind:** READING; the code a CHOICE (owner batch B 8; K12) · **Specs:** TRANSPORT l.1128-1132;
  RUNTIME l.789-791.
- **Decision (owner, batch B 8, 2026-11-13):** the route fails (`failed`, `transport-error`) with the
  diagnostic "peer identity mismatch"; its tickets are revoked; materialize returns TRANSPORT_ERROR. A
  consumer not on the Runtime thread (4b-3) reports it with `materializeFailed`.
- **Built (I90, part 4b-2b):** `transported.connectOutcome` maps the I/O thread's `ConnectFailure`: a
  Hello failure passes its code through (a received ProtocolError, or the local check's code, RUNTIME
  l.786-788), a loss or the Hello deadline is TRANSPORT_ERROR (l.789), a peer mismatch is TRANSPORT_ERROR
  and fails the route; `[IMPL]` local capacity, a construction input the I/O thread cannot rebuild and an
  unsupported profile are MODULE_ERROR, and a stopping I/O loop is NOT_READY. One process cannot present
  another uid, so the mismatch is driven by the test hook `failNextConnectForTests` (`-d:lcnTestHooks`);
  the I/O thread's own peer check is tested in `test_transport_io` (TRN-0188 to TRN-0190).
- **Status:** decided and built 2026-11-13 (I90, part 4b-2b). `test_transported`.

### G260 — The end of a transported route, at both ends
- **Kind:** READING for local routes (owner batch B 8; K13; TF-47 point 2) · **Specs:** TRANSPORT l.987-991 (an
  authority end: NOT_AUTHORISED to new Requests, then ProtocolError NOT_AUTHORISED and close), l.541-547;
  RUNTIME l.3226-3229, l.3459, l.3490, §10 l.3846-3849.
- **Decision (owner, batch B 7 and 8, 2026-11-13):** the consumer's Runtime records the handle's cause
  first, then orders the session's end. On the provider side every route end revokes the route's
  tickets, then by cause: a revocation or expiry answers each in-flight Request NOT_AUTHORISED, then
  sends ProtocolError NOT_AUTHORISED and closes; a transport failure closes at once; any readiness end
  (`close_route`, a provider stop, shutdown, and `[IMPL]` a consumer end or a provider failure)
  drains: nothing new is admitted (NOT_READY without dispatch), admitted Requests answer, and the
  session closes with no ProtocolError once they have, or at the end's bound (below), after which a
  call still running reaches its caller as TRANSPORT_ERROR (TRANSPORT l.543). A session also ends with
  the decision its ticket carried, even after a renewal moved the route's end (TRN-0317). The wait
  before `_MODULE_destroy` stays mandatory (G174). `ports.EndPolicies`, `engine.routeEnd`,
  `engine.endTransported`, `served.terminate`, `served.drain`, `served.close`.
- **Every end, one row each (`ports.EndPolicies`; re-checked 2026-11-13, Fable's reading):**

  | End | Order | Bound of a drain |
  |---|---|---|
  | revocation (also a G216 deny or narrowing, a failed evaluation), expiry | terminate | — |
  | a transport failure (a serve failure, K12); an establishment that issued no ticket | close at once | — |
  | `[4b-3]` the failed side's process or host is gone (TRANSPORT l.543) | close at once | — |
  | `close_route` | drain | `stop_deadline` from the end `[IMPL]` |
  | a provider stop (an execution-authority stop included) | drain | the provider's stop deadline |
  | shutdown | drain | the shutdown grace |
  | a consumer stop `[IMPL]` | drain | the consumer's stop deadline |
  | a consumer failure, a provider failure `[IMPL]` | drain | the drain deadline of the failed instance's cleanup release |

  Batch B 7 named the provider stop, shutdown and `close_route`. The consumer's stop and failure and
  the provider's failure drain too, by our choice within G174 (a), which the spec allows and does not
  settle (RUNTIME l.623, l.1065, l.3226-3227, l.3850). That needs no owner decision and no interim, but
  the owner sees the full list at the next approval: shown to the owner on 2026-11-15 (I90's drain
  list; I97, plan R15), recorded, nothing owed. Fable's three conditions hold for every drain:
  - it drains only while the session is intact;
  - each in-flight invocation is still marked cancelled at the route's end and its provider notified
    (INTERFACE l.2101: `endRoute` does it for every end), and a result within the bound is delivered;
  - nothing waits past the bound.

  Admission closes at once for every end (RUNTIME l.3224; l.621 for the consumer's new outbound
  calls). `[IMPL]` A failed instance's cleanup release has no deadline of its own here: a direct
  realization is never force-released (l.3838), and its `_MODULE_destroy` waits for its calls (l.623).
  Its drain deadline is therefore `stop_deadline` from the route's end.
- **Built at the consumer (I90, part 4b-2b):** the route's end sets every link's route cause and
  observed cause before the provider's side acts, so the handle's observer and its new operations get
  the route's code (closed or failed `NOT_READY`, revoked `NOT_AUTHORISED`); a synchronous or
  asynchronous call in flight gets what its session answers (NOT_AUTHORISED at a revocation, its result
  when the session drains). A connection whose route ended while it connected is closed and the
  materialization gets the route's code (K42). Asynchronous calls keep their link until they end; a
  released handle with none is closed at once (TRANSPORT l.596-598).
- **Status:** decided 2026-11-13; the provider side built in I90 part 4b-2a, the consumer side in part
  4b-2b, the table of ends in part 4b-2c. `test_transported`.

### G261 — Event output overflow on a transported subscriber
- **Kind:** FREE (TRANSPORT l.804-817 leaves the bound to the implementation; D3) · **Specs:** TRANSPORT
  §5.2 l.804-817; RUNTIME l.1225-1234.
- **Decision (owner, D3 (a), 2026-11-13):** the publish call waits for the shared output budget with no
  finite bound; a connection whose own output overflows is closed with TRANSPORT_ERROR, ending all its
  subscriptions.
- **Built 2026-11-13 (I90, part 4b-2c):** the publishing thread waits in `submitWait` for
  `maxPendingOutputBytes` with no deadline and holds no lock meanwhile; a subscriber that stops reading
  fills `callerUndeliveredBytes` at its end and then its connection's `connOutputBytes` at the
  provider's, which closes the connection with ProtocolError `TRANSPORT_ERROR` (`ccOverflow`); every
  subscription on it ends, and the other subscribers go on. `test_transported`.
- **Status:** decided and built 2026-11-13 (I90, part 4b-2c), documented in `docs/HOST-CONFIG.md`.

### G264 — The Module Host program
- **Kind:** FREE · **Specs:** LOADER §3 (`hosted_dynamic` and its placements), l.103-108 (the Loader
  manages hosts; the program is protected deployment input), l.105 (no restart); RUNTIME l.669,
  l.3823 (protected host supervision).
- **Description:** LOADER defines the hosted strategy and its placements, but what program runs a
  hosted module, how the Runtime finds it and what it inherits are the implementation's.
- **Decision:** `logos-module-host` (`src/logos_module_host.nim`, `src/logos_core/host/`), one process
  per hosted realization with placement `process`, under the daemon's user; built as a nimble
  `namedBin` and the Nix package `logos-module-host`, without test hooks. It is found only through
  `runtime.module_host`, an absolute path checked when the configuration is read (the last component
  not a symbolic link; a regular file owned by the Runtime's user or by root; no group or other
  write; owner-executable). Without it the Loader does not advertise `hosted_dynamic`, and a hosted
  module or declaration in the configuration is refused. `runtime.module_host_env` names the only
  variables a host gets, with the daemon's values at `start` (plan R4); `argv` is the bare program
  name, and nothing per instance is in either. The host ignores SIGPIPE; on Linux it dies with the
  supervision thread (`PR_SET_PDEATHSIG`); it requires fd 3 to be a connected local stream socket or
  exits 2; it keeps fds 4 and 5 (a provider's listener, the restart lock) from module children. Its
  main thread reads the carrier and runs no module code; a lifecycle thread runs the module's
  entries with the realizer's own phases (`mapStaged`, `probeCode`, `completeProbe`, `checkLive`,
  `initInputFor`, `initModule`, `checkInit`), so a hosted realization makes the direct one's checks
  with the direct one's errors (LOADER l.388-403). Exit statuses: 0 after `released` (or the
  carrier's end once stopping), 2 when not started by a Loader, 70 when the carrier breaks the
  protocol. On Windows the configuration refuses `module_host` and the program is a stub that exits 2.
- **Status:** decided and built 2026-11-14 (I91, part 4b-3.1a). `test_module_host`, `test_hosted`,
  `test_host`.

### G265 — Module Host supervision
- **Kind:** FREE · **Specs:** RUNTIME l.664-669, l.3818-3826 (the Runtime ends hosted work through
  protected supervision); LOADER l.105.
- **Description:** the specs require the Runtime to be able to end a host and to know it ended, but
  not how a host is started or watched.
- **Decision:** `runtime/hostsup.nim`, one `HostSupervisor` per engine when `module_host` is set; it
  outlives a failed Loader (D14). **Spawn** (`hostspawn.c`, `posix_spawn`, never `fork`): fd 0
  `/dev/null`, 1 and 2 inherited, 3 the carrier, 4 the listener and 5 the restart lock when given, no
  other descriptor (`POSIX_SPAWN_CLOEXEC_DEFAULT` on Darwin, `addclosefrom_np(6)` on glibc 2.34 and
  later, close-on-exec everywhere); a process group of its own; an empty signal mask and SIGPIPE,
  SIGTERM, SIGINT and SIGHUP at their defaults (C16). Spawns run on the supervision thread, since on
  Linux `PR_SET_PDEATHSIG` follows the thread that spawned the host. **Watching:** the supervision
  thread polls every carrier and a wake pipe, at most 50 ms apart, and calls `waitpid(pid, WNOHANG)`
  for each host it started; no SIGCHLD handler, never `waitpid(-1)`. **Ends** (plan R3): after every
  end, an orderly one too, the host's process group is killed with SIGKILL; the end is confirmed once
  the host is reaped and `kill(-pgid, 0)` is ESRCH. Termination is SIGKILL to the group; nothing
  restarts a host. Closing an engine is refused while module code still runs in a host; otherwise it
  ends every host.
- **Status:** decided and built 2026-11-14 (I91, part 4b-3.1a); what the Runtime does when a host
  ends by itself is G268, from part 4b-3.1b. `test_module_host` (H-14), `test_hosted`.

### G266 — The carrier between the Runtime and a Module Host
- **Kind:** FREE (K3; extends G108 (a)) · **Specs:** LOADER §5.2 (the private handoff); RUNTIME l.950,
  l.974 (the protected carrier; RUN-0812).
- **Decision:** a connected `AF_UNIX` stream socket pair the Runtime makes for each hosted attempt;
  the host's end becomes its fd 3. It is launch state, keyed by the attempt: every Runtime Control
  frame takes its consumer from the attempt the carrier was made for, and no message names a
  consumer, instance or ticket (RUN-0171, RUN-0172). A frame is a 4-byte big-endian length and one
  Logos deterministic-CBOR `lcn.carrier_message` (`runtime/carrier.cddl`,
  `logos-core-nim.carrier.v1`); its `kind` fixes its lane (0: the Loader's lifecycle; 1: Runtime
  Control; the boundary's lane comes with parts 4b-3.2 and 4b-3.3). The body limit is the Transport
  floor plus 64 KiB, so an 8 MiB call surface or configuration fits. A frame over the limit, one
  that does not decode, or one a side does not expect is terminal carrier loss: the host exits 70
  and the Runtime ends it (RUN-0812). The carrier and what it carries (paths, configuration input)
  are never in a record, a store or an error. Threads hand each other frame bytes, never decoded
  case objects (Nim 2.2.14's `=wasMoved`, as in `MsgKind`).
- **Status:** decided and built 2026-11-14 (I91, part 4b-3.1a). `test_carrier`, `test_module_host`.

### G267 — Authority with a hosted module
- **Kind:** FREE (K1, K2; owner decision 7) · **Specs:** RUNTIME §4.2.1 l.950-970; CA l.349-353.
- **Description:** a host shares an address space with module code, so what authority it may hold
  and who decides for its requests are the implementation's to fix.
- **Decision:** the host keeps no authority state. **Runtime Control (built):** each request from a
  host runs on a proxy worker (64 per Runtime) through the attempt's own direct binding, the same
  vtable a direct module calls, so values, errors, decisions and transitions are the direct ones
  (RUN-0180), decided against current Runtime state; a call from a thread the host runs module code
  on is marked so, as a direct one is. The host's own checks are the direct binding's local ones
  (names, sizes, options), with the same codes. `connect_remote` is NOT_AUTHORISED, as no remote
  enrollment exists.
  **Sessions and calls (parts 4b-3.2, 4b-3.3; the owner's direct layout, 2026-11-14):** payloads go
  between the consumer's process and the provider's host directly, and the Runtime stays on the
  control path. The host keeps only the session state the Runtime gave it (the selected contract and
  access of the Hello verdict, `valid_until`). For each Request its loop resolves the method and the
  route scope (plan R14), reports the call without its params (`io_dispatch`) and waits for the
  Runtime's verdict (`admit_verdict`), which the call worker takes from the same admission a direct
  route call runs (`rqAdmit`: the call decision, its retention capture, IFC-0581, readiness); only
  then does it check the payload, run the provider and commit the Response (G273). An invocation's
  scoped publication asks the call worker for each step (`scoped_check`, `scoped_admit`,
  `scoped_done`), and an ordinary publication asks the Runtime thread for its candidates and their
  admission (`rc_publish`, `rc_deliver`); every verdict is on names, roots and connection numbers.
  The host checks payloads with the Runtime's own code (`runtime/callcheck.nim`) on the same
  construction input (RUN-0815). Two payload-derived values cross, neither an authority input: a
  call's commitments when its capture retains them (G274), and the code of a delivery target the
  host dropped, for the Runtime's diagnostic (RUNTIME l.1226-1227). A CA's `authority_refusal` reads
  a refused payload, but a CA is `direct_static`, so no host publishes one.
  **The host's input and its own waits (the spec check, 2026-11-14):** every lane-1 frame is
  untrusted input of that host's instance: an `rc_delivered` acknowledgement of an entry not yet sent
  breaks the carrier (G178's order and G225's bound rest on it), and no carrier-loss diagnostic
  repeats a codec's text, whose path may hold a value from the frame (INTERFACE l.395). Before
  `_MODULE_destroy` the host waits for its Runtime Control callbacks in flight (event deliveries and
  completions) and, by running on one lifecycle thread, a pending `apply` hook, whatever the Runtime
  already waited for (INTERFACE l.1465, l.1503, l.1999).
  **Hosted consumers (part 4b-3.3; plan §2.8, R15, R18; the direct layout):** a hosted consumer's
  route handles and their connections are in its host, whose own transport loop connects to the
  provider's endpoint, so its payloads go directly too. The host keeps a route's invocation
  material from the `establish_route` and `renew_route` answers it passes on, and nothing else of
  them (RUN-0173-RUN-0175); the Runtime keeps none for a hosted consumer, and its `route_ended`
  wipes the host's. `materialize_route` runs the direct binding's local checks, then sends the
  exact route id, expected root and construction input (`rc_materialize`, RUN-0177, which also
  says whether the host holds material: none is NOT_AUTHORISED, K11); the Runtime rebuilds the
  contract from that input itself and makes its §4.1 checks against its current state. It names
  the handle (a hosted `Link`, which holds its pin) and the provider's peer identity and module
  (TRN-0187); the host connects, wiping the
  ticket as the command is built (R18), and the Runtime takes the outcome as a direct handle's
  (`rc_link_result`: a peer that is not the expected identity fails the route, K12, R15; a route
  that ended meanwhile gives its cause, K42). Each call, subscribe, unsubscribe and `observe_end`
  installation is admitted by the Runtime first (`rc_link_admit`), in a direct transported
  handle's order and with its codes, observer capacity included (I86). The host runs Events (one
  handler at a time per subscription, G178), end handlers and completions on its own workers and
  waits for them before `_MODULE_destroy`; a prepared call's timeout, cancellation and first
  terminal decision are kept as `asynccall.nim` keeps them. When a route the host's consumer holds
  ends, the Runtime sends `route_ended`: its code, whether it was revoked (which ends the calls
  still running, G174), and each handle's first terminal cause. A connection's own end is reported
  (`rc_link_closed`) and answered with the handle's first cause. **Deviation from plan R11:** its
  `route_ended_ack` and `route_cause` do not exist. The Runtime orders the route's cause and the
  connection's end itself and gives the first in either message, so it never waits for a host. No
  further payload-derived value crosses.
- **Status:** decided; Runtime Control built 2026-11-14 (I91, part 4b-3.1a); the host's input
  checks and own waits 2026-11-14; hosted consumers 2026-11-14 (part 4b-3.3). `test_hosted` (S-3),
  `test_hosted_routes` (C-1 to C-8, S-18).

### G268 — The end of a Module Host
- **Kind:** GAP (K6, S4b3-1; TF-29) · **Specs:** RUNTIME l.562 (`ready` is left by an unexpected
  realization failure, to `error`), l.974-976 (a carrier failure ends the hosted work; RUN-0812,
  RUN-0813), l.3753 (`host-terminated`), l.3786 (restart is orchestration's); LOADER l.105 (a host's
  end is the realization's end), l.497-499 (a record whose realization ended is `failed`).
- **Description:** the specs name `host-terminated` but not which ends it covers, nor how an end
  that follows a Loader answer, a deadline or carrier loss is classified.
- **Decision (plan R7):** supervision reports each confirmed end to the Runtime before the Loader's
  waits return (R27), so the Runtime has handled the end before any Loader answer it causes. (a) An
  end after a terminal lane-0 message (`init_failed`, `fatal`, `released`) is orderly: the Loader's
  typed error decides, through 4b-1's mapping. (b) An end the Runtime asked for (a deadline, its
  Loader's loss) keeps the classification already recorded. (c) An end while the Loader's `release`
  is outstanding belongs to that release. (d) Otherwise the instance enters `error` with
  `host-terminated`, the reason the carrier's failure ("the carrier to the Module Host failed:
  <why>") or "the Module Host ended unexpectedly", and a diagnostic names the instance and the exit
  status or signal. The Loader's record becomes `failed` and the Runtime releases it; the instance's
  routes fail as for any realization failure; intent is kept and nothing restarts the host. During
  `realize` the attempt fails with `host-terminated`; after `realize` and before `ready` is written
  it fails and is abandoned.
- **Status:** interim the owner decided (batch C, 2026-11-14), built 2026-11-14 (I91, part 4b-3.1b);
  in the comments document as TF-29; not sent to the spec owner. `test_hosted` (S-7, S-8).

### G269 — A Module Host ended at a deadline
- **Kind:** READING + GAP (batch C 13; TF-28) · **Specs:** RUNTIME l.611, l.666, l.668-669 (a startup
  past its deadline; the Runtime ends hosted work through protected supervision), l.1162-1164,
  l.3533 (`unknown`), l.3757, l.3835 (the escalation policy at a drain deadline), l.3860-3861
  (shutdown continues); LOADER l.573, l.590 (forced termination may stop destruction); CONFIG
  l.269-274 (the apply deadline; the context is not destroyed while the hook runs).
- **Description:** each of G61's four deadlines has a classification, but the specs do not say when a
  host still running module code past one is ended, nor what `realization` reports meanwhile.
- **Decision:** **startup** (a reading): at expiry the instance enters `error` with
  `startup-timeout` and, while `realize` is outstanding, its host is ended at once; `realization` is
  `unknown` until the end is confirmed, then `absent`, the state staying `error`. **Stop** (G180 (a)
  extended): at the stop deadline `cleanup-timeout` is recorded and the host ended; the Loader's
  `release` then succeeds and `realization` is `absent`. **Shutdown:** past the grace period every
  Module Host left is ended and shutdown continues. **Apply** (plan R9): at the apply deadline
  `configuration-indeterminate` is recorded as today; a hook still running a stop deadline later has
  its host ended (CONFIG l.272 forbids destroying the context, not ending the envelope). Each kill is
  the Runtime's own (`byRuntime`), so the deadline's classification stays (G268 (b)).
- **Status:** interim the owner decided (batch C 13, 2026-11-14), built 2026-11-14 (I91, part
  4b-3.1b); in the comments document as TF-28; not sent to the spec owner. `test_hosted` (S-9 to
  S-12).

### G270 — A live application whose Module Host ends
- **Kind:** GAP (K9; batch C 12) · **Specs:** CONFIG l.317-318 (MODULE_ERROR "otherwise"; the
  transition stays); LOADER l.497-499, l.541-542; RUNTIME l.955.
- **Description:** nothing says what the `apply_configuration` caller gets, nor what state the
  instance enters, when the host running the hook ends before it answers.
- **Decision (plan R8):** the Loader answers once the end is confirmed (G268's order); the caller gets
  MODULE_ERROR; the instance enters `error` with `host-terminated`, whether the host was killed, its
  carrier broke (which ends it too) or its module exited in the hook. `configuration-indeterminate`
  stays the apply deadline's (G269).
- **Status:** interim the owner decided (batch C 12, 2026-11-14), built 2026-11-14 (I91, part
  4b-3.1b); in the comments document as TF-40; not sent to the spec owner. `test_hosted` (S-13).

### G271 — Runtime Control events in a Module Host
- **Kind:** FREE · **Specs:** RUNTIME §9.3 events; G178, G225.
- **Description:** a hosted module's Runtime Control subscription has a handler in another process,
  and G178's order and one-at-a-time rule and G225's queue bound were written for handlers in the
  Runtime's.
- **Decision:** the direct handler of a hosted subscription forwards each entry to the host
  (`rc_event`, numbered) and returns only when the host's handler has returned (`rc_delivered`) or
  the host has ended. So G178's commitment order and one handler at a time hold unchanged, and G225's
  bound counts the entries waiting exactly as for a direct handler. The host runs handlers on up to
  4 event workers, one per subscription at a time. A handler that unsubscribes its own subscription
  (`in_handler`) is served beside the waiting delivery, so it does not wait for itself, as direct.
  **Deviation from plan §2.6:** there is no `rc_sub_ended`; a subscription G225 ends gives a hosted
  subscriber no signal, as it gives a direct one (TF-35), and unsubscribing it is LOGOS_OK.
- **Status:** decided and built 2026-11-14 (I91, part 4b-3.1a). `test_hosted` (S-5).

### G272 — A hosted instance's execution scope and route mode
- **Kind:** FREE · **Specs:** CA l.324-325, l.349-353 (an execution decision covers the selected
  hosted placement); RUNTIME l.3006-3007 (a hosted end is `local-transport`).
- **Decision:** an execution request for a hosted instance names the mode `local-transport` and the
  placement `process` (`authscopes.executionScope`), and `enforceable` accepts `local-transport` only
  with placements that are all `process`; a direct instance's request is unchanged. The permission
  scopes of an execution decision stay G217's, for 4b-4. **Route mode (plan R10):** with no matching
  rule, a route with an end in a Module Host is `local-transport` (a direct route needs one address
  space); a `direct` rule naming a module the configuration places `hosted_dynamic`, as callee or
  caller, is refused when the configuration is read ("routing: the direct routing rule ... names ...,
  which is hosted_dynamic"); at `establish_route` a `direct` rule meeting a hosted end that no
  configuration named (a `create_module` instance) is NOT_READY with that reason, omitted from an
  all-cardinality answer. The I/O thread starts at open whenever `module_host` is configured.
- **Status:** decided; the execution half built 2026-11-14 (I91, part 4b-3.1a); the route mode built
  2026-11-14 (part 4b-3.2). `test_hosted` (S-17), `test_hosted_routes` (R10), `test_host`. **Built
  for 4b-4c** (I93, 2026-11-14): under a selected profile the hosted request carries one permission
  scope per saved setting beside this execution scope, as a set (G217 amended), so CAP-0065 and
  CAP-0066 are claimed (`test_hosted_permissions` S-20, S-21).

### G273 — The Response commit at a hosted endpoint
- **Kind:** GAP (K38; TF-50), interim · **Specs:** TRANSPORT §6, §8.1 (a Response is committed into the
  session's output; terminate and close); RUNTIME l.1275-1281 (a scoped Event before the Response);
  CA l.1193 (the call record).
- **Description:** with a provider's endpoint in another process, the specs do not say whether the
  Runtime's record or the host's write decides what a call committed, nor when a Runtime order
  (terminate, close, drain) takes effect against Responses the host may already hold.
- **Decision (plan R16, Fable's conservative reading; TF-50's reading):** the host commits each Response into the
  session's output: a refused call's failure once the Runtime's verdict arrives (G171's payload check
  first for NOT_READY), an admitted call's result or failure once its provider answered and the
  invocation's scoped publications are applied (R19). A Runtime order takes effect when the host's
  loop processes it: a Request is answered once, by whichever of the host's commit and the
  Runtime's failure (`io_respond`, which carries no success) is submitted first, under one lock per
  Request; a session's end (stop, close, terminate) marks its Requests answered, so a provider result
  that comes later is not sent. The host then reports the call's end (`call_ended{call,
  succeeded}`), and the Runtime decides the call as committed only when the host's loop committed a
  success, so the record matches what the consumer saw. A connection that closed first loses what
  follows, as at the Runtime's own endpoint. The Runtime never sends a host a success, a payload or
  an introspection answer (`hostio.toMessage`), so lane 2 holds no output budget: the host's loop
  charges what it commits, as the Runtime's own loop does.
- **Status:** interim, built 2026-11-14 (I91, part 4b-3.2); in the comments document as TF-50
  (`claude-spec-comments-3.md` at logos-lips d064b6d8); not sent to the spec owner. `test_hosted_routes` (P-8, P-11 to P-13),
  `test_carrier`.

### G274 — The roots of a hosted provider's call record
- **Kind:** GAP (K44; TF-51), interim · **Specs:** CA l.1176-1177, l.1193; RUNTIME l.1149 (RUN-0815, the
  same selected-contract checks on either path); SEC l.205.
- **Description:** with the payloads in the provider's host, only that host computes a call's
  request and response commitments, and it shares an address space with module code.
- **Decision (plan R16, Fable's conservative reading; TF-51's first reading):** the host checks each Request before its
  provider runs and each response after it, with the Runtime's checks (`runtime/callcheck.nim`) on
  the same construction input (the module's call surface filtered to the selected root, at `init`'s
  payload depth); an invalid status or a response outside the schema is MODULE_ERROR (G172) before
  anything is committed, as direct. Its `call_ended` carries the commitments the capture retains and
  no others, and the record's roots are those: the provider host's verified roots.
  `docs/CONFORMANCE.md` states that they, like the Responses the consumer receives, rest on the
  host.
- **Status:** interim, built 2026-11-14 (I91, part 4b-3.2); in the comments document as TF-51
  (`claude-spec-comments-3.md` at logos-lips d064b6d8); not sent to the spec owner. `test_hosted_routes` (P-9, P-14).

### G275 — A Module Host of the previous run
- **Kind:** GAP (K33; batch C 11) · **Specs:** RUNTIME l.613 (`start` is NOT_READY while cleanup is
  unresolved), l.3533 (`unknown`), l.3821-3822, l.2634; G193.
- **Description:** after the Runtime ended uncleanly, a host it started may still run module code (a
  module that forked without exec keeps it alive), and a new realization of the same instance would
  run beside it.
- **Decision (plan R6):** a restart lock per instance, `<work_dir>/hosts/<blake3(id), 16 bytes in
  hex>.lock` (the directory 0700, the file 0600), taken with `flock` before each spawn and handed to
  the host as its fd 5; the Runtime closes its own copy after the spawn, so the lock lives as long as
  the host or anything it forked. At restore, a stored hosted instance whose lock cannot be taken is
  `unknown`; `start_module` and `recover_module` answer NOT_READY ("a Module Host of the previous run
  may still be running") and `remove_module` NOT_READY as for an instance with a realization; the
  Runtime retries the lock every second and, once it can take it, commits `absent`. A free lock gives G193 unchanged. A spawn whose lock is held fails
  the attempt. No host is ever adopted. Not on Windows, where no Module Host exists. **Amended for
  permission settings (4b-4c, I93; 4b-4 plan R26):** while the lock is held the instance's `pending`
  settings stay `pending`, at restore and for a replacement saved meanwhile, since the host of the
  previous run may still hold the old access (RUNTIME l.2600). Once the lock is taken they settle
  (`applied`, or `failed` for an inactive definition), written and published
  (`permission_settings_changed_event`) after the commit that makes the realization `absent`. With the
  lock free at open they settle at open, with no event, as G281 says.
- **Status:** interim the owner decided (batch C 11, 2026-11-14), built 2026-11-14 (I91, part
  4b-3.1b); in the comments document as TF-39; not sent to the spec owner. `test_hosted` (S-16). The settings half built 2026-11-14 (I93, part 4b-4c);
  `test_hosted_permissions` (S-26).

### G276 — Which buffers are wiped, and when (`G-wipe-scope`)
- **Kind:** FREE · **Specs:** INTERFACE §1.4.1 l.380-386 (each participating implementation zeroes
  its copies of a marked payload at last use, on failure and cancellation paths too), l.405 (it MAY
  erase more), l.2121 (a provider's request stays valid until execution is released).
- **Description:** the spec says what is erased, not which code can know that a buffer holds a marked
  payload: frames are read, and some trees decoded, before the method is resolved.
- **Decision:** three classes. **Byte buffers** of the Runtime, the transport and the Module Host that
  can hold a method payload (frame bodies, framed write copies, request and response copies,
  shared-heap copies, the caller's response copy, the kit's response blocks and call arenas) are
  zeroed unconditionally at last use (l.405). **Value trees, commitment intermediates and hasher
  states** are zeroed when the side is marked (the per-thread marked scope), and unconditionally where
  they exist before the method is resolved. **Generated code** wipes for marked declarations only, so
  unmarked kits and their golden files are unchanged; the kit runtime's shared pieces wipe always. A
  shared copy is released only once nothing holds it (l.2121). The primitives are `base/wipe.nim`'s:
  `secureZero` (`explicit_bzero`, `memset_s`, `SecureZeroMemory`), seqs and strings to their
  capacity, CBOR trees, BLAKE3 states, `freeWiped`; `encodeCbor` sizes its output once and
  `decodeCbor` pre-sizes, so no growth releases a partial copy. The carrier holds no method payload.
- **Channel messages** (Rev R19, 2026-11-15): under orc a channel moves a message's heap parts and
  copies its inline bytes into its queue slot, which is not cleared after `recv`; the queue is freed
  unerased when it grows and when it is closed. So no channel message type holds a payload's bytes or
  a payload value root inline: only contract and schema roots, the artifact's hash, configuration
  commitments and the invocation ticket, each listed in W-12, which fails on a new one. Plain values
  inside a shared object are released with it: `freeInv` zeroes `HostInv.requestRoot` and
  `.responseRoot`, retained or not (SECURITY-CONSIDERATIONS l.403).
- **Status:** decided and built 2026-11-15 (I92). `test_wipe` (W-12), `test_wipe_routes`.

### G277 — The paths a contract that marks a payload is routed on (`G-marked-paths`)
- **Kind:** READING, decided by the owner (S4b3b-1, batch C 14) · **Specs:** INTERFACE l.387-389
  (no path for a marked payload unless its participating implementations support erasure; no silent
  downgrade), l.400-401; RUNTIME l.3197.
- **Description:** whether "participating implementations support these requirements" (l.388) asks
  for the whole path to be vouched for or for each participant to answer for itself.
- **Decision:** each participant answers for its own copies. G244's refusal is lifted for the
  participants the Runtime controls (the Runtime, the endpoints it serves, the Module Host) on
  `direct` and `local-transport` paths, whoever the module at either end is. `establish_route` still
  refuses, with G244's code, message and place in the order of checks, on a path kind without
  erasure: a remote mode when Tier 5 adds one, and the modes the test hook `erasureMissing` names. No
  define, hook or configuration turns the refusal off. Re-decides G244.
- **Build condition** (spec-alignment check by the Fable session, 2026-11-15; IF l.388-389): a
  participant erases only in an orc or arc build. Under refc a channel deep-copies each message and
  frees the copy unerased, so a refc build carries no marked payload. One compile-time constant per
  binary says which (`base/wipe.ChannelsMove`). In a refc Runtime `erases` is false on every path
  kind: G244's refusal, with its code, message and place, for every marked contract. A refc Module
  Host refuses its own part where it first learns the contract: a provider that exposes a contract
  marking a payload fails `init` (realization-failed, bind phase, before `_MODULE_init`), and a hosted
  consumer's `materialize_route` of a route to one fails MODULE_ERROR before the Runtime is asked.
  Nothing goes on the carrier for this; there is no hook or configuration. Under refc, W-10 and C-10
  check the refusal on the product paths, without `erasureMissing` (IFC-0578, IFC-0579).
- **Status:** decided by the owner 2026-11-14; built 2026-11-15 (I92: direct and transported paths in
  part 4b-3b.1, hosted ends in 4b-3b.2, the build condition after the Fable check). The claim scope,
  orc builds only, accepted by the owner 2026-11-15 "for now" (R5); erasure under refc stays open and
  is not planned. `test_wipe_routes` W-10, `test_hosted_routes` C-10.

### G278 — What a diagnostic says of a marked payload (`G-marked-diagnostics`)
- **Kind:** FREE, with S4b3b-2 option (b) decided by the owner · **Specs:** INTERFACE l.395 (no marked
  value in a log, trace or diagnostic), §5.1 l.3357-3367 (a provider's failure goes to its caller);
  SECURITY-CONSIDERATIONS l.401-403.
- **Description:** an INVALID_PARAMS detail names a path, a path can end in a key taken from the
  payload, and generated messages quote the path.
- **Decision:** for a marked request the INVALID_PARAMS path stops before the first segment taken from
  the payload; the schema's field names and positions before it stay. Generated "not a X value"
  messages carry no path for a marked declaration. A provider's failure message and detail for a
  marked method are forwarded to the caller only, never copied into a diagnostic, a log or a record.
  No marked value and no value root of one reaches a diagnostic, an audit record, an observation
  result or the carrier: a call record keeps no root of a marked side, because IFC-0581 refuses its
  retention (`sensitive-retention`).
- **Status:** decided and built 2026-11-15 (I92). `test_wipe_routes` W-4 to W-7, W-9.

### G287 — Lifecycle ordering seen by orchestration
- **Kind:** Choice (K16) · **Specs:** RUNTIME l.746-748 (the ordering has no serialized form), l.750,
  l.3776 (reconciliation covers lifecycle ordering), l.3780 (dependent startup MUST be prevented);
  near NL-12 and TF-10.
- **Description:** the engine refuses a dependent's start until its prerequisites are ready, but
  orchestration cannot read the ordering, so it would keep asking for a start that the Runtime must
  refuse.
- **Options offered (K16 of the step 4b-5 plan):** (a) the engine keeps refusing with NOT_READY and the
  intent kept, and the module holds its own copy of the order *(recommended)*; (b) the engine waits;
  (c) the engine starts the prerequisite.
- **Decision:** (a). The engine is unchanged (I75). The deployment gives the module the same pairs in
  its `ordering` (4b-6 writes both from one source). The module issues a dependent's start (default or
  recovery) only when every prerequisite is `ready`; "ready" is runtime-ready only (NL-12). A ready
  prerequisite brings its dependents' decisions forward. Reverse order at shutdown stays the engine's.
  A drift between the two copies costs uncharged NOT_READY probes, never a wrong start.
- **Status:** decided and built 2026-11-13 (I94, part 4b-5a); a choice, not reported.
  `test_orch_policy`, `test_orchestration`.

### G288 — The signal that permissions or authority became available
- **Kind:** Choice (K17), decided by the owner (batch B 10) · **Specs:** RUNTIME l.3801-3804
  (orchestration resumes an instance once permissions or authority allow it again), l.1661-1668
  (`watch_changes`, `observed_change`).
- **Description:** RUNTIME l.3803 has orchestration resume an instance once what it lacked is
  available, and names no signal that says when.
- **Options offered:** (i) probes on the policy's spacing plus the Runtime Control hints, no Capability
  Authority route *(recommended)*; (ii) also a route to the authority's `watch_changes` where granted.
- **Decision (owner, batch B 10, 2026-11-13):** (i). An instance with `requested` intent that is not
  live (`unloaded`, or `error` with one of the four classifications G291 as amended reads as a
  resumption), and a start or stop default that was
  refused, is probed with uncharged calls: never exhausted, under every policy, spaced by the policy's
  backoff (`delay(n)` after the last uncharged call; the package default's under `disabled`). The
  authority's return to `ready` and a `configuration_state_changed` event naming the instance bring the
  next probe forward to `max(last call + initial_delay_ms, now)`, never sooner; the hint stays in force
  until that probe is made, so a decision taken before it is due does not spend it. Since part 4b-5c a
  `permission_settings_changed` event naming the instance does too: a settlement after a
  reconciliation stop, or a replacement that gives back what a refused start lacked (G284). No
  Capability Authority `watch_changes` route in Tier 4b.
- **Status:** decided and built 2026-11-13 (I94, part 4b-5a); the permission hint built 2026-11-14
  (part 4b-5c). Not reported. `test_orch_policy`, `test_orchestration`.

### G289 — Resumption against retry, as orchestration sees them
- **Kind:** GAP (S4b5-1, with K34), decided by the owner (batch B 9) · **Specs:** RUNTIME l.3774-3775
  (reconcile after a Runtime restart; documentation MUST distinguish resumption from retries),
  l.3788-3789 (accounting survives an orchestration restart), l.3804, l.3806-3808 (orchestration may be
  stopped and restored while the Runtime runs), l.3504-3506 (revisions only advance).
- **Description:** when the module starts and finds a `requested` instance in `error`, nothing it can
  observe says whether the Runtime restarted (a resumption, uncharged under G193) or only orchestration
  did while the Runtime kept running (a failure while it was down: a retry). Revisions are opaque and no
  method reports a Runtime start. K34 asks whether `disabled` also stops resumption.
- **Options offered (S4b5-1 of the step 4b-5 plan):** (a) the first recovery after the module starts,
  of an instance with no open episode, is a resumption; an open episode continues charged
  *(recommended)*; (b) read the Runtime start from the revision's high bits; (c) charge every `error`
  recovery; (d) ask the spec owner for an observable Runtime start marker.
- **Decision (owner, batch B 9, 2026-11-13):** (a), with the `disabled` hole closed. The module's first
  decision on an instance after it starts, finding it `unloaded`, or `error` with no open episode,
  resumes it uncharged under every policy; under `disabled` every `requested` instance in `error` is
  resumed once after the module starts, a stale entry dropped; an open episode under an enabled policy
  continues charged across any restart. Resumption is outside the restart policy (K34). A first
  decision that a prerequisite holds back, or that finds no free call slot, stays the first. **Amends
  G193.**
- **Status:** decided and built 2026-11-13 (I94, part 4b-5a). In the comments document as TF-41 (K34):
  point 2 is S4b5-1's question, and its suggested resolution is (d)'s start marker (corrected 2026-11-17,
  step 5-0: TF-41 carries it, not TF-29). Whether it goes to the spec owner is the owner's call; not sent
  to the spec owner. `test_orch_policy`, `test_orchestration`.

### G290 — Nothing tells orchestration that the authority binding exists
- **Kind:** GAP, low (K45; extends TF-25) · **Specs:** RUNTIME l.1643 (no module is reconciled before
  the authority is bound), l.1645-1650, l.2555 (`get_self` answers before any binding).
- **Description:** the module must not reconcile before the Runtime has bound its Capability
  Authority, and no call or event reports the binding.
- **Decision (owner, 2026-11-13: "Accept both", K45 as the Fable session reads it):** the
  binding is inferred from the first policy-decided call that succeeds: `list_modules {limit: 1}`,
  never `get_self`. Until it succeeds the module probes, from 50 ms doubling to 2 s. A later refusal
  of `list_modules` sends it back to the authority's bring-up when the configuration names an
  authority, and otherwise retries at the resync interval.
- **Status:** decided by the owner 2026-11-13 ("Accept both"), built 2026-11-13 (I94, part 4b-5a).
  In the comments document under TF-25; not sent to the spec owner. `test_orchestration`.

### G291 — An enforcement stop that overran its deadline: resumption or retry
- **Kind:** GAP (K46; extends TF-28 and G180) · **Specs:** RUNTIME l.3801, l.3803 (resume when allowed
  again), l.3786 (retries follow the restart policy), l.3757 (`cleanup-timeout`).
- **Description:** an enforcement stop (an authority denial or revocation) whose cleanup overruns its
  deadline leaves the instance `error` with `cleanup-timeout` and its intent kept. Read as a live
  failure it would be a charged retry, and under `disabled` never recovered, against l.3803's MUST.
- **Decision (owner, 2026-11-13: "Accept both", K46 as the Fable session reads it):** a
  resumption. `error` with `cleanup-timeout` and `requested` intent is probed uncharged under every
  policy (G288's spacing), never exhausted. `cleanup-timeout` is the one classification the module
  reads; every other classification decides alike (RUN-1055). The Opus session's reading, a charged
  retry under the restart policy documented with G180, was considered and not taken.
- **Amended (owner, 2026-11-14: "Do a, as Fable recommends"; I94, part 4b-5c):** the module reads a
  closed set of four `error` classifications as a resumption: `cleanup-timeout`,
  `permission-enforcement-failed`, `authority-denied` and `authority-evaluation-failed`, the last three
  being the set the engine already treats as one (G168 extended, G284). Why: after an overrun, a probe
  refused by the settings (G284) or denied by the authority (G168) replaces `cleanup-timeout` with one
  of the three, the state still `error`; read as a live failure the instance would be charged under
  `backoff`, its probes no longer brought forward, and never resumed under `disabled`, against l.3801
  and l.3803. Conditions (Fable): the set is closed, and every other classification, an unrecognized
  one included, stays a live failure (l.3756, RUN-1055); the engine sets the three only where it
  refuses or denies a start or recovery, settles settings `failed`, or stops for authority, never for a
  failure of an accepted attempt, and `test_orchestration` pins those routines; a probe accepted that
  then fails is a failed resumption under the restart policy, charged under `backoff` and not retried
  under `disabled` (l.3804), while a refused probe is not one; `disabled` resumes both causes end to
  end; `permission_settings_changed` brings a probe forward only to G288's floor (l.3789), and an
  explicit stop ends the probes (l.3790); HOST-CONFIG lists the four (l.3775). Not a new gap: the
  mechanism inside this decision (TF-28 and TF-41 are reported); nothing new is reported.
- **Status:** decided by the owner 2026-11-13 ("Accept both"), built 2026-11-13 (I94, part 4b-5a);
  amended by the owner 2026-11-14, built 2026-11-14 (part 4b-5c). In the comments document under
  TF-41, with TF-28; not sent to the spec owner. `test_orch_policy`, `test_orchestration`.

### G292 — Orchestration's coordinated shutdown
- **Kind:** Choice (K21) · **Specs:** RUNTIME l.71 (orchestration "requests coordinated shutdown"),
  l.3695-3698 (`shutdown_runtime` takes no argument), l.3841 (the procedure runs independently of
  orchestration), l.3872 (RUN-1079).
- **Description:** RUNTIME names coordinated shutdown as an orchestration duty and defines no rule
  behind it.
- **Options offered:** (a) the module only ever calls `shutdown_runtime` *(recommended)*; (b) the
  module stops dependents in reverse order first, then calls `shutdown_runtime`.
- **Decision:** (a), and in Tier 4b nothing triggers it: the reference module never sequences or
  requests a shutdown. (b) is wrong: an explicit stop cancels intent (l.1838), so the deployment would
  not resume after the restart. logosd's signals use the Host API, `logosctl` calls `shutdown_runtime`
  itself, and reverse order is the engine's, from the host configuration's `ordering`.
- **Status:** decided 2026-11-13 (I94, part 4b-5a); a choice, not reported. At shutdown the module
  cancels what it has in flight and calls nothing (`test_orchestration`).

### G305 — A replacement instance's state: a fresh assignment filled by migration
- **Kind:** GAP (K31; TF-42 in the Fable session's comments document) · **Specs:** RUNTIME l.94-95 and
  l.1448 (an assignment is abstract; its concrete storage is the deployment's), l.1446, l.1451-1453,
  l.2624, l.2637, l.3549-3550, l.3587; CA l.733.
- **Description:** whether a state assignment may pass to another instance. G92 as re-decided on
  2026-11-11 relied on it ("transfer of its assignment").
- **Decision (owner, batch F item 21, 2026-11-15):** no assignment identifier moves. The replacement
  gets a fresh assignment of its own (l.3549's rule), filled by the deployment's migration of the
  concrete directory (l.3550, l.1453): `copy`, or `move` by rename. The identifier stays reserved on the
  source's tombstone. For `copy` this is conformant under every answer to the question; `move` also
  rests on G307.
- **Status:** decided; in the comments document as TF-42 point 1; not sent to the spec owner. Built in
  I96 (`move` in part 7a, `copy` in part 7b).

### G306 — Who authorizes a state migration
- **Kind:** GAP (low; K32) · **Specs:** RUNTIME l.2639, l.1452-1454, l.3554; CA l.400; BCP l.380,
  l.385.
- **Description:** RUNTIME requires a migration to be separately authorized and names no contract or
  scope for it.
- **Interim (owner, batch F item 21, 2026-11-15; reading (a)):** protected host configuration is the
  authorization: a `state_transfers` entry in `app-config.v1` (and logosd's `daemon-config.v1`), applied
  once at `start` on the host's protected path, with no Capability Authority decision. It is recorded in
  the replacement's `xfer` side record (`store_dir`), kept with its tombstone when it is retired (owner's
  condition 4) and shown by `logosctl state list` (part 7c). The Runtime's diagnostic line is not the
  record: the diagnostics ring is lost at restart, and logosd's log, which carries the line since
  4b-6d's drain (I95), is the service manager's, kept or not by its own policy (corrected 2026-11-16
  after the Fable session's check; no spec line asks for a log record of a migration: RUNTIME l.2639,
  l.3548-3550; CA l.1167-1168 and l.1174 list no record kind for a deployment action). No Runtime
  Control method and no `logosctl` socket command performs one (decision 9; l.3554). The entry is also
  the explicit compatibility assertion (l.3551).
- **Status:** OPEN; in the comments document as TF-42 point 2, with G305; not sent to the spec owner.
  Built in I96.

### G307 — A migration that consumes the source's preserved storage
- **Kind:** GAP (low; S4b7-1) · **Specs:** RUNTIME l.3587-3588, l.3550, l.1453; BCP l.395.
- **Description:** retirement preserves the storage "for its separately authorized retention,
  disposal, or migration". Whether one authorized migration may also dispose of the source (a move), or
  the source must stay until a separate disposal.
- **Interim (owner, batch F item 21, 2026-11-15; reading (a)):** one explicit entry with `mode: move`
  authorizes both; `copy` keeps the source.
- **Status:** OPEN; attach to G305 if reported. Built in I96 (part 7a).

### G355 — The `failure` and `state` a facade's record reports (NL-07)
- **Kind:** GAP (NL-07, remarked in `claude-spec-comments-2.md`, "Remarks on the responses"), interim
  decided by the owner (Tier 5 batch B, B6) · **Specs:** RUNTIME l.2510-2515 (the `route_failure`
  codes), l.3299-3301 (a facade is ready only with compatible reflected state), l.3327-3332 (the
  classifications to keep apart), l.3678 (reflected readiness never overrides a local stop), l.3759
  (`remote-state-unknown`).
- **Description:** the `failure` values and the `state` a facade's record reports are not given, and the
  instance failure classes cannot express the seven distinctions of l.3329-3332.
- **Interim (owner, B6, 2026-11-17, approved as written):** `failure` is `remote-state-unknown` when
  current remote state cannot be established (l.3759), and `facade-failed`, `remote-unreachable`,
  `remote-not-ready`, `remote-stopped`, `remote-failed` or `contract-mismatch` for the known causes,
  spelled as `route_failure.code` spells them (l.2510-2515). `state` is `unloaded` when the facade is
  locally stopped or detached (l.3678), `loaded` when attached without fresh evidence, `ready` only with
  fresh compatible state (l.3299-3301), and `error` only for `facade-failed`. A facade is a provider
  record, never a module instance (owner decision B4).
- **Status:** decided 2026-11-17, which lifts the D9 stop it put on Tier 5 step 5-7b; recorded by step
  5-0; built in 5-7b.

### G356 — Continuations on a `connect_remote` binding (NR-04)
- **Kind:** GAP (NR-04, remarked in `claude-spec-comments-2.md`, "Remarks on the responses"), interim
  decided by the owner (Tier 5 batch B, B7) · **Specs:** RUNTIME l.235 (the owning Runtime connects for
  the same consumer), l.3124-3129 (a local module consumer gets resolved routes; inter-Runtime
  responses keep continuations), l.3144 (`partial`), l.3153 (the consumer's Runtime follows a
  continuation), l.3155 (resolution bounds); INTERFACE l.3840 (`connect_remote`).
- **Description:** the text does not say whether an `establish_route` answer reaching a module through
  its own `connect_remote` binding may carry continuations, which no module can follow, and `partial`
  has two meanings between Runtimes.
- **Interim (owner, B7, 2026-11-17: "resolve or fail"):** a local module consumer always gets resolved
  routes. Between Runtimes, `partial` follows l.3144 as sender and is recomputed after resolution as
  receiver. On a module's own `connect_remote` binding the consumer's own Runtime follows a continuation
  in an `establish_route` answer within the l.3155 bounds, or fails the request; no module ever
  receives a continuation (l.3125, l.3153, l.235).
- **Status:** decided 2026-11-17, which lifts the D9 stop it put on Tier 5 step 5-7b; recorded by step
  5-0; built in 5-7b. Until then `lcn_call` fails such a request (owner decision A3).

## 7. Capability Authority

### G46 — A running module loses its execution authorization
- **Kind:** GAP · **Specs:** CA §3.3 (execution authorization), §8 (terminate dependent sessions when
  continued use would exceed current authority; sessions MAY stay open but unusable while a fresh decision
  is fetched); RUNTIME §10.1 (a stop caused by permission withdrawal preserves intent; orchestration
  resumes via `recover_module` when permissions return).
- **Options offered:** (a) re-evaluate first; stop only on deny (intent preserved); on evaluation failure
  keep running but deny new decision-requiring operations *(recommended)*; (b) stop immediately.
- **Decision:** (b). Intent is preserved per RUNTIME §10.1, so the module resumes when allowed again.
- **Settled 2026-11-10 (6a4dfa28):** CA-01: when execution authorization ends, Runtime stops the instance (CA l.854-866). Matches (b).

### G47 — How an external CA learns consumer attributes
- **Kind:** GAP · **Specs:** CA §2 (Runtime supplies authenticated consumer context; no wire field for
  attributes); RUNTIME l.1528 (policy MAY use attributes derived from authenticated context).
- **Options offered:** (a) the CA observes them through its own Runtime Control binding (`list_modules`,
  `get_execution_summary`) under bootstrap grants *(recommended)*; (b) add an attributes field to
  `evaluate` (deviation). **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** CA-02: attribute sources plug in through a protected integration with ordering and freshness rules, and recursion into `evaluate` is forbidden (CA l.101-115). (a), Runtime Control visibility for the CA, is withdrawn.
- **Revised 2026-11-11 (review against 6a4dfa28, item A17):** the note above withdrew (a) and put nothing in its place. CA l.101-106 require a protected attribute-source integration for any fact beyond the contract's consumer and scopes, with named sources, binding, freshness and failure rules, and G140's default policy names consumers by module and targets by package signer, which are such facts (RUNTIME l.3523 for signer attributes). A replacement is needed before the CA integration, as G52 and G55 got one. **Needs an owner decision** (review item A17).
- **Re-decided 2026-11-11 (owner: "Accept all", after the Fable 5.2 session's review of the recommendations, item A17; the owner took the Fable session's wording over ours, which
  made deployment input the source of the facts):** deployment input holds the policy rules; it is not
  the source of the facts. A static table cannot name instances, since each gets a fresh identity
  (RUNTIME l.3623). The facts come from the engine's own registry: for the consumer and the target, the
  module name and the retained selection (package, version, exact signer). RUNTIME l.3523 supplies
  signer attributes "from accepted selection before admission". The in-process Capability Authority reads
  them over a protected in-process path, not through Runtime Control (CA l.104) and not through
  `evaluate` (l.105). Missing facts are an evaluation failure, not a deny (l.106). Freshness (l.108-112)
  is simple: name and selection are immutable for an instance's life (RUNTIME l.3546, l.3621), so the
  only transition is retirement. Rules name exact signer keys, not "an accepted anchor", so a trust
  change is a policy revision and needs no second invalidation channel. Documented under BCP l.368.

### G49 — Meaning of `publish_events` / `publish-event`
- **Kind:** GAP · **Specs:** CA §3.1 (`route_access.publish_events`, provider-access action
  `publish-event`); TRANSPORT §1.4 (only the callee sends Events; there is no consumer-to-provider event
  path).
- **Options offered:** (a) accept and commit them in grants, never enforce, ask the author
  *(recommended)*; (b) reject any grant or scope containing them.
- **Decision:** (a). **Status:** OPEN until `6a4dfa28` (answered there, below); the owner asked the
  spec author.
- **Revised 2026-11-10 (6a4dfa28):** CA-03: `publish-event` is kept and enforced: delivery needs the publisher's authority and each subscriber's (CA l.242-246; RUNTIME l.1229-1230). **Status:** answered; no longer open.

### G50 — Call-evidence proof arrays
- **Kind:** GAP (partly spec-resolved) · **Specs:** CA §9.1 (no rule on per-side ordering or duplicates),
  l.110-115 (CA's set-valued arrays are strictly ascending without duplicates), l.1049 ("If proofs is
  present, it MUST contain at least one request or response proof").
- **Options offered:** (a) empty lists allowed, ascending deterministic-CBOR order of semantic path,
  duplicates rejected *(recommended)*; (b) non-empty, in disclosure order.
- **Decision:** (a), aligned with l.1049 at the final review: `proofs` is omitted when there are none;
  when present it holds at least one proof in total, and one side may be empty.
- **Revised 2026-11-10 (6a4dfa28):** AP-5: an empty request or response side is omitted, never an empty array (CA l.1293). CA-04 confirms the order: deterministic-CBOR order of the semantic path (CA l.1295-1300).
- **Built 2026-11-12 (step 8b-3, I85):** `runtime/evidence.nim` rejects an empty side, a proof without a
  commitment on its side, and a side not strictly ascending by the encoded path; it never sorts or
  deduplicates. The Runtime's own containers carry no proofs in Tier 4.

### G51 — Ordering and cursors of `list_grants` and `query_audit`
- **Kind:** GAP · **Specs:** CA §6 (limit default 100, range 1-1000), §9 (at most the 1000 most recent
  visible records); ordering, cursor lifetime and since/until inclusivity unspecified.
- **Options offered:** (a) grants by grant-id bytes; audit newest first by record sequence; cursors pin a
  snapshot and expire after 10 minutes (then `invalid-request`); since inclusive, until exclusive
  *(recommended)*; (b) ask the spec author. **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** CA-05: `list_grants` continues live after the last returned id; audit is ordered by timestamp descending, ties in reverse recording order, `since` inclusive and `until` exclusive (CA l.705-713, l.1130-1133). Our snapshot expiry and record-sequence order are withdrawn.

### G52 — Call audit records under a route-level decision
- **Kind:** GAP · **Specs:** CA §9 (a call record requires `decision_id` and a scope); RUNTIME §9 (calls
  are authorized by their route's decision).
- **Options offered:** (a) the decision_id and provider_access_scope of the decision that established or
  last renewed the route *(recommended)*; (b) ask the spec author. **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** NX-03, CA-06: each provider-method call is an authorization point (RUNTIME l.1724, l.1732-1735); a cached call decision may satisfy it, and the audit record names the actual call decision (CA l.1176-1182). (a) is withdrawn.
- **Re-decided 2026-11-11 (owner: "Add the denying test authorizer, otherwise go with your recommendations"):** one authorizer interface in the engine, consulted at every point the
  spec names: Runtime Control methods outside the caller-bound ones (RUNTIME l.1626, l.1723), lifecycle
  requests (l.1726), execution authorization before realization (l.715), route establishment and renewal
  (l.983, l.3061), every provider-method call before dispatch (l.1732), every event delivery per
  subscriber route (l.1229) and discovery (l.439-442). Each answer is allow or deny with a decision id and
  the scope it covered, and the engine retains every answer (l.1756-1760). A call's audit names the
  decision that answered that call; a cached call decision names its own id (CA l.1176-1182). Until the
  Capability Authority is integrated the engine uses an allow-all authorizer, which RUNTIME permits as
  internal policy for a local trusted deployment (l.1633-1634), and which still records its answers. The
  tests also use an authorizer that denies by rule, so every NOT_AUTHORISED path and its precedence over
  NOT_READY (l.1342-1350) is tested before the Authority exists. The call-decision cache policy is decided
  with the Capability Authority integration. **Status:** decided.
- **Extended 2026-11-11 (G175):** event delivery is two decisions per subscriber route,
  `publish-event` (the publisher as consumer, the subscriber's route as target) and `subscribe-event`
  (the subscriber as consumer); `subscribe-event` is also decided when a subscription is activated.
- **Decided 2026-11-12 (step 8b-1, I85):** the call-decision cache left open above. Only an allow
  carrying `valid_until` is cached, keyed by the binding generation and the request's canonical bytes,
  at most 4096 entries with the least recently used dropped first. A deny, an evaluation failure, an
  allow without `valid_until`, `renew-route` and every `module_execution` decision are never cached. An
  entry is used only before both its `valid_until` on the wall clock and a monotonic deadline fixed when
  it was received, so a backward wall-clock step never extends it (RUN-0939). `policy_changed` clears
  every entry; a revoked or expired grant clears the entries whose decisions list it; a result made
  before a notice processed since its dispatch is evaluated again, never used or cached (CA l.857-867,
  l.884-903; CAP-0119, CAP-0120, CAP-0343). The internal policy caches nothing. `runtime/dcache.nim`.
- **Built 2026-11-12 (step 8b-3, I85):** the call record names the decision applied to that call,
  captured at admission with the enforced scope; a cached call decision names its own id, and a later
  renewal or revocation never replaces it (CAP-0388 to CAP-0392). `runtime/callaudit.nim`.

### G81 — Remote consumers in the daemon's CA
- **Kind:** GAP · **Specs:** CA §2 ("Every module-instance address named by this contract MUST resolve to
  one Runtime-known module instance"; every decision identifies its consumer) vs RUNTIME §9
  l.1603-1636 (the target Runtime authorizes operations "for the consumer" asserted by an enrolled source
  Runtime, whose instances the target does not own).
- **Description:** Read strictly, logosd's CA could neither record a decision nor issue a grant naming
  the CLI's address, which would make the remote forwarding RUNTIME §9 defines unusable.
- **Options offered (first):** (a) an authenticated remote consumer counts as known *(recommended)*;
  (b) policy names only the enrolled remote Runtime; (c) ask the spec author. The owner asked for a fuller
  explanation of the problem and the concepts; after it, the options were: (a) the daemon records every
  remote consumer accepted through an enrolled Hello and treats it as Runtime-known *(recommended)*;
  (b) rules only, no grants naming remote instances; (c) ask the spec author.
- **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** C-09: CA addresses may be remote or historical (CA l.77-81). Matches (a).
- **Revised 2026-11-11 (review against 6a4dfa28, item C4):** the row was written for the CLI as a forwarded remote consumer, which D13 removed; it stays relevant to real remote Runtimes. The note's citation covers only historical addresses (CA l.77-81); the remote half rests on RUNTIME l.1786-1794 (an enrolled source Runtime names a consumer it authenticated, and the target authorizes the operation for that consumer). What resolving means for a grant target owned by another Runtime is still open: remark on NF-06 in `claude-spec-comments-2.md` (logos-lips `68628d95`).
- **Revised 2026-11-17 (owner, Tier 5 batch B, B5, approved as written; recorded by step 5-0):** C-09 was
  declined at `6a4dfa28` (`claude-spec-comments-3.md` Appendix B), and NF-06 is unanswered. (a) is kept,
  narrowed: a consumer of another Runtime is known when that Runtime is actively enrolled; a grant to it
  needs an explicit policy rule and is refused otherwise. The policy subject for a forwarded consumer is
  added, and `unsupported-scope` is no longer answered when one is evaluated (CA l.77, l.461-462;
  RUNTIME l.1786-1794). Built in Tier 5 step 5-7a, whose authority part waited on this (a D9 stop).

### G82 — Default authority of the logosctl consumer on the daemon
- **Kind:** FREE · **Specs:** CA §5, §6, §10 l.1108-1110 (ordinary consumers MUST NOT gain direct
  authority to call `evaluate` merely because of other rights); RUNTIME §9 (every RC method needs an
  explicit allow).
- **Options offered:** (a) everything, through a CA policy rule, narrowable in the daemon config
  *(recommended)*; (b) read-only by default.
- **Decision:** (a). Made explicit at the final review: the rule names the host-ambient permission scope
  (otherwise no payload module could start, RUNTIME l.2240) and `evaluate` (for `logosctl authz check`).
- **Revised 2026-11-10 (6a4dfa28):** NX-01: CA §8.1 adds `watch_changes` and `observed_change`; `grant_changed` and `policy_changed` subscriptions are restricted (CA l.925-991; RUNTIME l.1661-1663). The logosctl consumer's default cannot include the restricted events.
- **Revised 2026-11-11 (review against 6a4dfa28, items A15, A16):** naming `evaluate` for `logosctl authz check` conflicts with the text. CA l.1373-1376: Runtime invokes `evaluate` through its protected system-service binding, and ordinary consumers MUST NOT gain direct authority to call it; SECURITY l.542 (new): administrative status does not replace that binding; CA l.88-89: Runtime populates or validates the request's `consumer` from the authenticated context, so a direct call could only ask about logosctl itself. `authz check` could be built from `list_grants` and `query_audit`, or dropped. The host-ambient part rests on RUNTIME l.2240, now l.2538; see G110. **Needs an owner decision** (review items A15, A16).
- **Re-decided 2026-11-11 (owner: "Accept all", after the Fable 5.2 session's review of the recommendations, item A15):** `logosctl authz check` is dropped, and the G82 rule no
  longer names `evaluate`. The text leaves no real choice: Runtime populates or validates the request's
  `consumer` from the authenticated context (CA l.88-89), so a direct `evaluate` could only ask about
  logosctl; see also CA l.1374-1376 and SECURITY l.542. An operator's views are `list_grants` and
  `query_audit`. The host-ambient part follows G110.

### G110 — The ambient permission's identifier and constraints
- **Kind:** FREE · **Specs:** CA §3.5 l.345 (a permission identifier must unambiguously identify its
  defining specification or profile; constraints follow its CDDL; the definition names its enforcer and
  revocation behaviour); PM §4 l.294-297 (`requested_permission` carries constraints).
- **Options offered:** (a) `logos-core-nim.host-ambient` *(recommended)*; (b) `host-ambient`.
- **Decision:** (a); constraints `lcn.host_ambient_constraints = {}`; enforced by Runtime + Loader
  (realize only if granted and set); revocation stops the module (G46).
- **Revised 2026-11-11 (review against 6a4dfa28, item A16):** nothing sets the permission. RUNTIME
  l.2541-2543: a new instance without accepted protected settings starts with revision 1 and an empty
  permission array; protected provisioning MAY supply independently authorized initial settings before the
  instance is exposed, but module declarations and `requested_permissions` alone MUST NOT; omitted
  permissions are denied (l.2538). With G140's grant, "realize only if granted and set" therefore denies
  every payload start until something places host-ambient in each new instance's settings, again for every
  replacement instance (G92). The setter is either protected provisioning from the daemon's deployment
  profile or an explicit `update_permission_settings` by an administrator. **Needs an owner decision**
  (review item A16).
- **Re-decided 2026-11-11 (owner: "Accept all", after the Fable 5.2 session's review of the recommendations, item A16):** protected provisioning from the deployment profile sets
  each instance's initial permission settings before the instance is exposed (RUNTIME l.2541-2543), for
  new and replacement instances alike. The protected input names the permissions per module itself;
  echoing a module's `requested_permissions` is what l.2543 forbids. A replacement gets its settings by
  fresh provisioning, never by copying the old instance's (l.2637-2639). Settings never authorize
  execution (l.2539, l.2545); the execution decision must cover each permission scope (CA l.345), so
  G140's policy also allows the host-ambient scope. An administrator may still change settings with
  `update_permission_settings`.
- **Revised 2026-11-13 (owner, batch A item 2; step 4b-1, I89):** the enforcer is Runtime admission,
  not "Runtime + Loader": the Runtime checks execution authority and settings before it asks the
  Module Loader to realize (CA l.343; RUNTIME l.2538), and the Loader, which receives no decision,
  grant or settings (inspection item CAP-0067), enforces nothing of its own. The rest stands; built
  with permission enforcement (4b-4).
- **Built 2026-11-14 (I93, part 4b-4a):** the definition, in the shipped profile
  `logos-core-nim.permission-profile.v1` (G279): constraints `lcn_permissions.host_ambient = {}`
  (`src/logos_core/permissions/host_ambient.cddl`; the constraints rule is named in the supporting
  schema's own namespace), containment by equality, enforcement component Runtime admission, refuse
  when unenforceable, stop when revoked; `docs/PERMISSIONS.md`. The Capability Authority's side
  (validation, containment, the policy pattern) is built; the Runtime's admission is part 4b-4b.
- **Built 2026-11-14 (I93, part 4b-4b):** the setter is protected provisioning, `app-config.v1`
  `permissions.initial` by instance or by module (never `requested_permissions`; RUNTIME l.2543), or an
  authorized `update_permission_settings`; `logosctl` never sets it (owner decision 9). Runtime
  admission enforces it: a start or recovery whose settings lack it is refused before any decision
  (G284), and otherwise the execution decision must allow it (G217 as amended). A revoked grant or
  policy covering it stops the instance (CAP-0192). The orchestration and authority instances must be
  provisioned with it (`create` checks).

### G115 — Exporting call evidence
- **Kind:** GAP · **Specs:** CA §9.1 l.988-990 (no query method or batch format; export only when policy
  requires), l.1072 (disclosure follows `query_audit` rules), l.1078 (the Runtime keeps containers).
- **Options offered:** (a) containers stay in the daemon's audit store; `logosctl audit evidence export`
  is an owner-only host action, documented; evidence and retain-root off by default, enabled by audit
  policy *(recommended)*; (b) nothing exported. **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** CA-07: no new method; export goes through a protected integration (CA l.1320-1325). Matches (a).
- **Built for the library 2026-11-12 (step 8b-3, I85):** the integration is in-process,
  `exportCallEvidence(rt, index)` over the retained ring; logosd's store and `logosctl audit evidence
  export` remain Tier 4b.
- **Built for logosd 2026-11-15 (I95, part 4b-6c; G301):** logosd's call-evidence store, off by
  default, and `logosctl audit evidence ls|export --seq N`, an owner-only offline action on the session's
  files; the I85 library integration is unchanged.

### G140 — Contents of the default CA policy
- **Kind:** FREE · **Specs:** CA §3.1 (route decisions per provider and scope), §3.3 (execution decisions
  MUST cover every required permission scope); RUNTIME l.2240 (omitted permissions are denied).
- **Description:** Without rules, the routes between payload modules (delivery -> rln/libp2p,
  rln -> lez_rln) and every payload start would be denied.
- **Options offered:** (a) ship rules in the default policy: those specific routes by contract, the
  host-ambient permission scope for modules from packages signed by an accepted anchor, orchestrator
  lifecycle rights, PM -> `lcn.storage_fetch`, CLI forwarding + the G82 rule; everything else denied
  *(recommended)*; (b) default deny; RUN-A-NODE issues grants after install. **Decision:** (a).
- **Revised 2026-11-11 (review against 6a4dfa28, item A17):** the policy as listed no longer works. Its
  subjects are attributes (module names, packages signed by an accepted anchor), which need G47's
  attribute source (CA l.101). Route rules alone let modules neither call nor deliver events: authority to
  establish or renew a route does not authorize a call (RUNTIME l.1732-1733), and delivery needs the
  publisher's `publish-event` and each subscriber's `subscribe-event` authority (CA l.242-245). "CLI
  forwarding" assumes the CLI Runtime D13 dropped. To be restated with `call`, `publish-event` and
  `subscribe-event` once G47 is decided. **Needs an owner decision** (review item A17).
- **Re-decided 2026-11-11 (owner: "Accept all", after the Fable 5.2 session's review of the recommendations, item A17):** the default policy is restated over the actions that
  authorize use: `call`, `publish-event` and `subscribe-event`, with `establish-route` (and `discover`
  where used) beside them (CA l.167-173, l.242-245; RUNTIME l.1732-1733). Its subjects are G47's facts:
  module names and exact signer keys. It allows the host-ambient scope for execution (G110). "CLI
  forwarding" is dropped (D13), and the logosctl consumer's rule follows G82 without `evaluate`. The
  concrete rule list is written with the CA integration.

### G149 — Call-evidence signing key
- **Kind:** FREE (the need is spec-forced) · **Specs:** CA §9.1 l.986 (every conforming Runtime MUST
  implement `logos.call-evidence.cose-sign1-ed25519`), l.1029-1033 (each kid maps to exactly one producer
  Runtime; the key MUST NOT be used for package signing or TLS); SECURITY §13.
- **Not offered as a question** (found at the final review; the shape follows from the spec):
  `logosctl init` generates a separate 0600 Ed25519 evidence key and kid mapped to logosd's runtime id;
  `trust evidence-keys ls|rotate`, applied at the next start.
- **Revised 2026-11-10 (6a4dfa28):** PM-06: the call-evidence key is SLH-DSA-SHA2-192s (CA §9.1 l.1217-1287, l.1265-1273). The implementation is R4.
- **Built for the library 2026-11-12 (step 8b-3, I85):** host config `call_audit.evidence` (kid and an
  absolute 0600 key file of the process user), read at `create`; `tools/evidence_keygen.nim` makes a key.
  `logosctl init` and `trust evidence-keys` remain Tier 4b.
- **Built for logosd 2026-11-15 (I95, parts 4b-6a to 4b-6c; batch E item 19):** `logosctl init` makes
  the key with the Runtime id; the kid is the first 16 bytes of BLAKE3-256 of the public key, and
  `keys/evidence-<kid>.cbor` binds kid, Runtime id and public key; logosd's start and every export check
  the configured key against it. `trust evidence-keys ls|rotate` (rotation retires the old binding and
  removes its secret half; it applies at the next start). An export signs with the current key, so a
  record stored under an older kid is re-signed (G301).

### G205 — The Capability Authority's error codes and the order of its outcomes
- **Kind:** GAP · **Specs:** CA l.767-776 and l.784-789 (16 codes, deny versus error), which assign 4
  of them in prose: `invalid-request` (l.714, l.1132), `grant-not-active` (l.745), `grant-not-found`
  (l.1390), `authority-unavailable` (l.1345); l.138 and l.392 (set order, unknown permissions);
  l.1386-1390 (visibility before `grant-not-found`); l.1455-1456 and RUNTIME l.3157-3158 (no existence
  oracle). No sentence orders validation, availability, visibility, policy and state for one request.
- **Description:** the other codes need a condition each, and the order decides what a refusal reveals:
  a revoke of an expired grant the caller may not see is `grant-not-found` (hidden) or
  `grant-not-active` (revealed) depending on it.
- **Interim (approved with the step 8a plan, §0.1 U3 and S8a-1 order (a)):** the table in
  `docs/AUTHORITY-POLICY.md`, "Error codes and the order of checks": caller, admission, form, locality,
  permission, availability, (for `issue_grant`, whether any `issue` rule's subject matches the caller,
  else deny `consumer-denied`, before anything it names is resolved), resolution, visibility, policy,
  state. Hiding wins over state. Unavailable facts are `authority-unavailable` for the read methods too
  (l.786-787). `revoke_grant` has no denial arm (l.1150): a refusal of a visible grant is the error
  `not-authorised`, recorded as a `revoke-grant` failure. `approval-required` and `invalid-constraints`
  are never produced. Every code used is one the CDDL admits, so the interim conforms whatever the answer.
  `authority/core.nim`; suites `cap.evaluate`, `cap.grants`, `cap.list`, `cap.audit`.
- **Status:** OPEN (TL-04, extended: TL-04 in `claude-spec-comments-3.md`, logos-lips `68628d95`; the
  S8a-1 addendum (the order of the checks, the record of a repeated revoke, the scopes one request may
  combine) is in TL-04 since logos-lips `9a8d4c14`); found 2026-11-12 planning step 8a. Built in I84.
- **Amended 2026-11-14 (I93, part 4b-4a):** with a permission profile selected (G279), the permission
  phase checks every permission name first (`unknown-permission`), then every constraints value
  (`invalid-constraints`, CA l.392), so an undefined name wins whatever the array order.
  `invalid-constraints` is now produced; `approval-required` still is not. A permission scope beside
  anything but a start is a form failure (G207 as amended), so `invalid-request` comes before both.
  `scopes.validateScopes`; suite `cap.permissions`.

### G206 — The audit record of a repeated revoke
- **Kind:** GAP · **Specs:** CA l.745 (revoking a revoked grant returns it unchanged), l.1167 (each
  successful call is recorded), CAP-0204.
- **Description:** an idempotent revoke changes nothing; whether it is a second success record or none
  is not said.
- **Interim (step 8a plan, approved):** a second `revoke-grant` success record, written behind like an
  evaluation's, since each successful call is recorded. `authority/core.nim` (`revokeEntry`); suite
  `cap.grants`.
- **Status:** OPEN (TL-04, extended at logos-lips `9a8d4c14`); found 2026-11-12 planning step 8a. Built
  in I84.

### G207 — Scope combinations in one `evaluate`
- **Kind:** GAP · **Specs:** CA l.486 (an evaluation is one operation; the CA may refuse a request it
  cannot show to be one), l.483-575.
- **Description:** which scope arrays are one operation is not listed.
- **Interim (step 8a plan, approved):** exactly one non-permission scope per `evaluate`, with one action;
  any second non-permission scope is `invalid-request`. Permission scopes are `unknown-permission`
  anyway (CA l.392). `call`, `publish-event` and `subscribe-event` need one route and exactly one root in
  the action's list; `publish-event` needs one provider, backed by the consumer (l.243).
  `authority/scopes.nim` (`checkEvaluateShape`); suite `cap.scopes`.
- **Status:** OPEN (TL-04, extended at logos-lips `9a8d4c14`); found 2026-11-12 planning step 8a. Built
  in I84.
- **Amended 2026-11-14 (owner, batch D 17; I93, part 4b-4a; K47 folded in):** permission scopes stand
  only beside one `module-execution` scope whose one action is `start` (CA l.345, l.351-353); a
  permission scope alone, beside a stop or beside any other operation is `invalid-request`, with and
  without a profile (a form rule, CA l.484-486). One allow rule, or one active grant, must cover every
  requested scope; any deny pattern containing any requested scope denies. Two rules or two grants
  that cover the request only together deny. A permission scope names no target (CA l.212-216) and is
  tied to the start only by standing beside its scope in one rule or grant (l.489): a rule allowing
  host-ambient on its own would otherwise lend it to every module its subject may start. Our choice
  under TL-04, not a new gap; `docs/AUTHORITY-POLICY.md` says it. `scopes.checkEvaluateShape`,
  `scopes.coversEach`, `policy.containsEach`, `core.doEvaluate`; suite `cap.permissions`.

### G215 — The code for a routed authority call that names another consumer or carries `execution_renewal`
- **Kind:** GAP · **Specs:** CA l.88 (the Runtime populates or validates `consumer` before dispatching a
  Capability Authority method), l.91, l.579 (`execution_renewal` from an ordinary caller, including a
  routed call, is rejected), l.1374-1376; RUNTIME l.1716-1718, l.1907-1916 (no precondition row);
  INTERFACE l.3116-3124.
- **Description:** both are refusals the Runtime must make after the call's own decision allowed it, and
  neither names a code: NOT_AUTHORISED, INVALID_PARAMS and "populate and dispatch" are all readings
  (TF-31).
- **Interim (step 8b plan S8b-1 (a), approved):** NOT_AUTHORISED with a message that reveals nothing,
  and no dispatch. It is retained as a refusal of its own kind (`azRefused`, source `psBoundary`), neither
  a deny nor an evaluation failure. `consumer` is validated, never replaced: a routed `evaluate` must
  name the caller too (our reading of RUNTIME l.1717). The check runs after the call's decision and the
  payload's schema check, in every policy mode; a request that does not decode is left to the schema
  check. `invoke.authorityRefusal`, `engine.refusal`.
- **Status:** OPEN (TF-31); found 2026-11-12 planning step 8b. Built in I85 (8b-2).

### G216 — How an established route is re-authorized after a policy change or a grant's end
- **Kind:** GAP · **Specs:** CA l.869-873, l.906-911 (re-evaluate dependent operations; make a route
  unusable when the new decision denies or narrows it), l.913-914, l.284-293; RUNTIME l.3183-3184
  (`renew_route` may extend `expires_at` and replace `decision_id`), l.2502-2505, l.1341-1343.
- **Description:** the authority requires a route decision the consumer did not ask for, without saying
  which action is evaluated, whether it may move `expires_at`, what an evaluation failure does, or
  whether it is eager (TF-33).
- **Interim (step 8b plan S8b-2 (a), approved, with the review's three changes):** after a
  `policy_changed`, or the revocation or expiry of a grant the route's decision listed, every
  authority-sourced route is re-authorized at once with `renew-route` for its id and bound access. While
  that is pending, its admissions wait for the answer. An allow keeps the route and replaces
  `decision_id`; `expires_at` becomes the earlier of the old and the new end, never later. A deny revokes
  it with `authority-denied`, an allow narrower than the bound access with `authority-revoked`. An
  evaluation failure leaves it `ready` and unusable (NOT_AUTHORISED) until a later decision allows it,
  whether that check is the Runtime's or the consumer's `renew_route`. The eager batch is bounded (64
  routes at a time) so it never fills the evaluation queue; a route that loses its binding meanwhile is
  re-authorized at its next use. Every allow that keeps a route carries `valid_until`.
  `engine.reauthRoutes`, `engine.reauthorized`, `engine.routeAuthorized`.
- **Status:** OPEN (TF-33); found 2026-11-12 planning step 8b. Built in I85 (8b-2).

### G217 — Which permission scopes an execution decision covers
- **Kind:** GAP · **Specs:** CA l.344-345 (the decision covers "the module execution operation and every
  required permission scope"), l.351-353, l.369-372, l.484-485, l.563; LOADER l.426; RUNTIME l.1439-1442
  (`requested_permissions` are policy inputs that grant nothing), l.2538-2539, l.2541.
- **Description:** nothing defines which permissions are required: the ones the module declares, or the
  instance's applied permission settings, which are empty for a new instance (TF-32).
- **Interim (step 8b plan, approved; Fable review §7.5):** the execution decision carries the
  `module_execution` scope alone, with no permission scope. A declared permission is a policy input the
  authority reads through its attribute source (G47); it grants nothing, and no permission is enforced
  yet. CAP-0063 is tagged for its module-execution half. `runtime/authscopes.nim`.
- **Amended 2026-11-14 (step 4b-4 plan, approved; I93, part 4b-4b):** with a permission profile
  selected, the required permission scopes are the instance's saved settings: the execution decision
  covers the `module_execution` scope and one `permission` scope per saved setting, its name and
  constraints, as one set in canonical order (CA l.345, l.364). Settings lacking the profile's minimum
  are refused before any decision (G284); a permission the module declares stays a policy input that
  grants nothing. Without a profile, unchanged: the `module_execution` scope alone. CAP-0063 is now
  tagged whole.
- **Status:** OPEN (TF-32); found 2026-11-12 planning step 8b. Built in I85; amended and built in I93.

### G218 — The state an expired route enters
- **Kind:** GAP · **Specs:** RUNTIME l.1845-1846 (the terminal set: close, failure, revocation), l.2504,
  l.3032 (`authority-expired`), l.2520, l.3188-3189, l.3476.
- **Description:** expiry has a failure code and no named state (TL-03).
- **Interim (step 8b plan, approved):** at `expires_at` the route becomes `revoked` with
  `authority-expired`: calls and observers get NOT_AUTHORISED, its subscriptions are deactivated as for
  any terminal route, and a later `renew_route` is NOT_AUTHORISED. `draining` stays unused. Expiry is
  checked whenever the route is used and by the engine's deadline timer (`engine.expireRoutes`).
- **Status:** OPEN (TL-03); recorded as a row 2026-11-12 planning step 8b. Built in I85.

### G279 — The permission profile
- **Kind:** FREE (G-P1 of the step 4b-4 plan) · **Specs:** CA l.387-392 (a permission names the
  specification or selected profile that defines it), l.394-407, l.392 and l.406 (the profile and its
  definitions are deployment documents); RUNTIME l.1595 (profile selection is a deployment or
  security-profile input), l.2538 (omitted permissions are denied); BCP l.364.
- **Description:** permissions exist only through a selected profile, and none is named.
- **Decision:** `logos-core-nim.permission-profile.v1`, a built-in profile the host selects in
  protected configuration (`app-config.v1` `permissions.profile`; owner decision 3, 2026-11-13: the
  library keeps G229's constant form when none is selected, and logosd always selects it, 4b-6). One
  definition, `logos-core-nim.host-ambient` (G110). Its **minimum**, the permissions every
  realization's settings must hold, is host-ambient; the Module Loader is constructed with it (G253).
  The minimum is not CA l.345's "every required permission scope", which under G217's interim is
  every saved setting. A profile is a value; it reaches each thread as a constructor, so no profile
  crosses a thread. `docs/PERMISSIONS.md`.
- **Status:** decided with the step 4b-4 plan; a free choice, not reported. Built 2026-11-14 (I93,
  part 4b-4a): `permissions.nim`; suite `perm.registry` in `tests/test_permissions.nim`.

### G280 — No Loader-enforced permission
- **Kind:** Choice (K24) · **Specs:** CA l.360-363 (the Module Loader and deployment controls enforce
  the constraints they own; decisions are not added to the realization descriptor), l.364, l.417;
  LOADER l.340-345 (`realize_request` has four fields), l.427.
- **Description:** a definition could name the Module Loader as its enforcement component, but no
  carrier takes an instance's constraints to the Loader.
- **Options offered (K24 of the step 4b-4 plan):** (a) a private handoff inside one implementation;
  (b) static deployment configuration, which cannot follow an update; (c) no Loader-enforced permission
  until a carrier exists *(recommended)*.
- **Decision:** (c), as `fable-review.md` §3 recommends and the owner follows. `epModuleLoader` (and the
  deployment-control and operating-system points) exist as names and are inactive: a settings
  replacement naming such a definition is `failed`, and an allow carrying one is an evaluation failure
  (CAP-0084). Only Runtime admission is active in Tier 4b.
- **Status:** decided 2026-11-14 (I93); a choice, not reported. Built in part 4b-4a
  (`PermissionDefinition.enforcement`, `active`); the Runtime's use in part 4b-4b.

### G281 — When a settings replacement is applied
- **Kind:** Reading (K25; TF-46 point 2), decided with the step 4b-4 plan · **Specs:** RUNTIME l.2541 (initial
  settings `applied`), l.2548-2550, l.2590-2601 (reconcile, stop and re-realize, `applied` only once
  enforced, `failed` on an enforcement failure), l.2593, l.2595; CA l.364, l.417 (a constraint that
  cannot be enforced fails the operation).
- **Description:** a direct module cannot have its access changed while it runs, and the spec leaves
  open when a replacement counts as enforced.
- **Options offered (K25):** (a) `applied` once nothing of the old realization is left, the new settings
  being enforced at the next admission; (b) `pending` until the instance runs again; (c) `failed` for a
  definition no active point enforces.
- **Decision:** (a) with (c). A replacement while a realization remains (an attempt, a realization or a
  teardown) is `pending`, and a running instance is stopped at once with no classification, intent and
  origin kept (RUN-0914); it settles when none remains: `applied`, or `failed` when a named definition is
  inactive (G280). With none remaining it is `applied` (or `failed`) at once. Provisioned initial
  settings are revision 1, `applied`. A `pending` record found at restore settles the same way, since no
  realization survives the process. Settlement runs from `releaseWaiters`, the one path every attempt,
  realization and teardown end passes through; a settlement whose write fails stays `pending` and is
  retried every second. A failed replacement of an `unloaded` instance gives it the classification
  `permission-enforcement-failed`.
- **Status:** decided 2026-11-14 (I93); a reading, in the comments document as TF-46 point 2 (corrected
  2026-11-17, step 5-0); not sent to the spec owner. Built in part 4b-4b
  (`runtime/settings.nim`, `engine.settleSettings`); `tests/test_permissions.nim`.

### G282 — The installed snapshot
- **Kind:** Gap, interim (K26 (a); TF-46 point 3) · **Specs:** RUNTIME l.2563-2576 (the snapshot installed for the
  current realization, from retained enforcement state, never from declarations, saved settings or a
  fresh evaluation; `unavailable` when none can be given); CA l.121, l.564 (an allowed scope may narrow
  a requested one).
- **Description:** what "installed" means when the only enforcement is admission.
- **Interim:** the permission scopes the admission's execution decision allowed, kept per realization:
  the saved settings when the decision's source does not narrow (the internal, bootstrap and recovery
  sources allow what was asked), or the narrower constraints a Capability Authority allowed. An allowed
  permission scope is accepted when its constraints are contained in the requested one's (by the
  definition's containment); broader, missing or unrequested is an evaluation failure (CA l.568-569). A
  renewal that narrows an installed permission ends the execution as a denial does. The Module Loader's
  is its construction's minimum. Without a profile, `unavailable`.
- **Status:** interim, decided 2026-11-14 (I93); built in part 4b-4b (`authscopes.installedOf`,
  `keepsInstalled`).

### G283 — One permission for every facility class
- **Kind:** Reading (K27), decided by the owner (batch D 16) · **Specs:** CA l.394-404 (a profile that
  permits operating-system or platform access defines names and constraints for every facility it
  exposes: the seven classes), l.366 (no containment claim against in-process code), l.408-409
  (per-module device restrictions).
- **Description:** host-ambient is one name with empty constraints; the seven list items each ask the
  profile to define what it exposes.
- **Options offered:** (a) one name with empty constraints stands for everything the host exposes
  (G110's shape); (b) a name per facility.
- **Decision (owner, batch D 16, 2026-11-14):** (a). host-ambient stands for all seven facility classes,
  with no per-class limit and no containment; CAP-0075 to CAP-0082 are claimed by one inspection item
  (it amends owner decision 3, which put CAP-0076 to CAP-0082 in Tier 5). CAP-0292 and CAP-0293 do not
  apply: the profile claims no per-module device restriction. CAP-0078's persistent state is part of
  what host-ambient stands for.
- **Status:** decided and built 2026-11-14 (I93, part 4b-4a); not reported. Inspection items in
  `conformance/inspection/CAP.toml`; test `[IMPL-DECISION G283]` in `tests/test_permissions.nim`.

### G284 — A start the permission settings refuse
- **Kind:** Gap, interim (S4b4-1; owner batch D 15; extends G168) · **Specs:** RUNTIME l.2538 (omitted
  permissions are denied), l.2591 (an enforcement failure leaves the module stopped), l.3644-3647,
  l.3752-3753; CA l.364.
- **Description:** what a start or recovery returns when the saved settings cannot be enforced or lack
  a permission every realization needs.
- **Interim (owner, batch D 15, 2026-11-14):** before any execution decision is asked, NOT_AUTHORISED
  "execution is not authorised", the instance unchanged (`unloaded` or `error`), intent and origin kept;
  `failure` is `permission-enforcement-failed` when the settings are `failed`, and `authority-denied`
  when `applied` settings lack the profile's minimum. No authority decision exists for it; a diagnostic
  names the missing permissions. `pending` settings cannot be met here, since the instance is stopping;
  a start then is NOT_READY. The Module Loader is never checked: its construction authorizes it (G253).
  The orchestration and authority instances must be provisioned with the minimum (`create` checks), so
  bring-up is not refused for a configuration error.
- **Status:** interim, decided 2026-11-14 (I93); built in part 4b-4b (`engine.settingsRefusal`).

### G285 — A reconciliation stop past its deadline
- **Kind:** Choice inside TF-28 (S4b4-2) · **Specs:** RUNTIME l.2591-2592 (`failed`, the module left
  stopped, revoked access never silently restored), l.2600-2601, l.3835-3838; G61, G180.
- **Description:** a direct realization whose stop passes its deadline may persist with its old access.
- **Options offered (S4b4-2):** (a) settings `failed` with `enforcement-failed`, the instance keeping
  `cleanup-timeout`; (b) `pending` until the late cleanup ends.
- **Decision:** (a). A replacement that arrives while such a realization may persist (`error` with
  `cleanup-timeout` or `cleanup-failed` and its teardown not ended, or a realization its Loader lost) is
  `failed` at once. The late end of the cleanup leaves the settings `failed` and the instance stopped;
  the next start is refused (G284, which then sets `permission-enforcement-failed`). Once nothing is left,
  a replacement is applied as G281 says, so an accepted retry recovers it (RUNTIME l.2585). **Hosted
  (part 4b-4c; 4b-4 plan R25):** a hosted realization whose Module Host the Runtime ends by force does
  not persist: past the stop deadline or the shutdown grace (`cleanup-timeout`, G269) and after its
  Loader's loss, the host is ended in the same engine turn, and its realization stays until that end is
  confirmed (RUNTIME l.669, l.3821; owner batch C 13). Its `pending` settings then stay `pending`, a
  replacement meanwhile is `pending` too, and they settle `applied` once the release completes; the
  instance stays `error`. Two hosted ends schedule no forced end, so the host may live on with its old
  access as a direct realization may, and each gives `failed` (RUNTIME l.2591, l.2600): a cleanup
  failure (`cleanup-failed`, a `release` that failed and `get_status` found), where the Loader still
  holds the realization and the Runtime never ends the host; and an orphan whose Loader stays bound (an
  answer lost), where the realization is lost but the Loader is not, so the Loader-loss path that ends
  every host never runs. Holding either `pending` would wait for an end that never comes and block the
  recovery of incomplete application (l.2590); `failed` keeps the saved settings, and an accepted retry
  recovers them.
- **Status:** decided 2026-11-14 (I93); a choice, not reported. Built in part 4b-4b (`engine.remainsOf`);
  the hosted half in part 4b-4c (`engine.forcedEnd`; `test_hosted_permissions` S-24, S-25).

### G286 — Permissions enforced by a module provider
- **Kind:** Reading (D-d) · **Specs:** CA l.419-422.
- **Description:** CA l.419-422 bind a permission whose enforcement component is a module provider.
- **Decision:** no shipped definition is enforced by a module provider (every one's component is
  Runtime admission, G280), so CAP-0294 to CAP-0297 do not apply; inspection items. CAP-0297 also holds
  under a broad reading: admission is decided from the saved settings and the execution decision only,
  never from grant inspection, grant ids or an instance address (RUNTIME l.2561).
- **Status:** decided 2026-11-14 (I93, part 4b-4a); not reported.

### G354 — A `call` record that cannot be built or stored after the call's outcome
- **Kind:** GAP, interim as built (a TF-06 remark, logos-lips `1bf903b9`) · **Specs:** RUNTIME l.1770
  (the Runtime produces the `call` record); CA l.1167-1169 (retention is deployment or audit-profile
  policy), l.1174-1175 (the record follows the enforcement outcome), l.1342, l.1345 (outcomes named for
  one other cause only); BCP l.553.
- **Description:** the record is produced after the outcome, so a Runtime that then cannot build or
  store it can no longer fail the call, and no rule says what follows: refusing later calls that need
  retention, or noting the loss.
- **Interim (as built in I85, with I95's diagnostics, 2026-11-16):** the call's outcome stands. A record
  that cannot be built is a `warn` diagnostic, "a call record could not be kept" (`runtime/invoke.nim`
  `record`), which logosd logs (`docs/DAEMON.md`, "The Runtime's diagnostics"); later calls are not
  refused. Retention is bounded, as CA l.1169 lets the deployment choose: the Runtime's ring keeps the
  latest `call_audit.call_records` and drops the oldest (I85), and logosd's call-evidence store writes a
  gap entry for each run of records it dropped (G301; `docs/DAEMON.md` §9).
- **Status:** interim, recorded 2026-11-17 by step 5-0 (no code change); in the comments document as a
  TF-06 remark; not sent to the spec owner.

---

## 8. Configuration

### G141 — First configuration of a module started by default
- **Kind:** FREE · **Specs:** CONFIG §4 (sources: retained record, package default only if none,
  `protected-provisioning`, Runtime Control update), §6 (startup delivery); no producer of
  protected-provisioning input is defined.
- **Description:** storage_module starts on the first logosd run; without a provisioning source it would
  start with its package default (ports, NAT, network preset, bootstrap peers).
- **Options offered:** (a) the daemon config carries `provisioned_configuration: {module => value}`,
  staged as `protected-provisioning` before startup defaults run; filled by `logosctl init
  --module-config` and `daemon config set` *(recommended)*; (b) start with the package default, change it
  later. **Decision:** (a).

- **Built for app-config v1 2026-11-13 (I87, step 9a; approved by the owner 2026-11-13):** per instance
  (CONFIG l.46): `modules[].provisioned_configuration`, beside the module's `configuration` declaration.
  It is an ordinary protected source (CONFIG l.130, l.142; SEC l.532), not gated by D27. At creation it
  is staged as `protected-provisioning` in place of the package default. At a later start it is staged
  again only when its value root differs from the last provisioned one, which the configuration record
  keeps; removing a value and adding the same one back stages nothing. HOST-CONFIG.md states this as
  the rule for when a replacement takes effect. The logosd daemon config and `logosctl` commands of (a)
  come with the CLI (D13).

(G19 and G21 cover configuration error codes; G76 covers the host configuration formats.)
- **Built 2026-11-15 (I95, part 4b-6b):** the daemon side: daemon-config's `provisioned_configuration`
  passes to the host configuration; `logosctl daemon config module-config INSTANCE @FILE` (or
  `--remove`) sets it offline, and `init --module-config INSTANCE=@FILE` at the start. It applies at the
  next start.

---

## 9. Package Manager, packages and distribution

### G5 — What the LGX `storage` and `object` fields contain
- **Kind:** GAP · **Specs:** PM §5 (`storage: tstr .size(1..128)`, `object: bstr .size(1..4096)`), §6
  l.786 (they "identify the Storage object containing the package archive"), §4.5 l.583 ("the Logos
  Storage provider named by `storage`"), §13; INTERFACE §1.1 l.115-119 (the storage examples are not the
  real Storage interface). No spec defines a Storage fetch method, what `storage` names, or how `object`
  is encoded.
- **Options offered:** (a) `storage` = the Storage provider's module_provider_id, `object` = binary CID
  *(recommended)*; (b) a flat module name + CID text bytes; (c) a deployment-local label + binary CID.
- **Owner's answer:** "Let's leave this open, I need to confirm with the specs author".
- **Status:** OPEN until `6a4dfa28` (the revision below closes it). Blocked the PM fetch mapping, the
  catalog locator shape, storage CID typing and every install; tests were to run against a fake Storage
  provider meanwhile (`provisional-G5`).
- **Revised 2026-11-10 (6a4dfa28):** PM-01, SO-02: `storage` selects a deployment-configured Storage binding; `object` and `provenance_object` are opaque byte locators read through that binding's documented retrieval API and encoding (PM §6 l.856-864, §13 l.1437-1438). No common fetch interface. **Status:** no longer open; we choose and document the locator encoding when fetch is built (Tier 5).

### G29 — Shared artifacts, ordering violations and check precedence
- **Kind:** CONTRA · **Specs:** PM §4 l.341 (declarations "MAY reference the same schema or default
  artifact") vs §8 (an artifact assigned to more than one declaration is `invalid-package`); §4 l.363
  (ordering violations, no value named); no check precedence defined.
- **Options offered:** (a) the specific MAY wins — shared schema/default artifacts allowed, shared
  implementation artifacts rejected; ordering violations `invalid-package`; precedence limits >
  structure > signature > commitment > schema > platform > artifact hashes *(recommended)*; (b) reject
  all sharing; (c) ask the spec author. **Decision:** (a); provenance inserted after commitment (G113).
- **Settled 2026-11-10 (6a4dfa28):** C-07: only implementation artifacts must be unique per declaration; ordering violations are `invalid-package`, and the first detected error may be returned (PM §4 l.334-335, l.358; §8 l.1070, l.1088). Matches.
- **Revised 2026-11-11 (review against 6a4dfa28, item A22):** the precedence needs one change. PM l.360: each referenced artifact is verified against its signed manifest hash before its content is parsed or validated, and l.1070 keeps "the validation-order requirements" in force when stopping at the first failure. With I37 reading the `schema` stage as the configuration schema artifacts, that stage moves after platform selection and after the hash check of every artifact it parses. Not built (Tier 4).

### G39 — Per-caller cursors without a caller identity
- **Kind:** GAP · **Specs:** PM §15 (cursors bound to "the authenticated caller", records filtered per
  caller); INTERFACE dispatch ABI (passes no caller to providers); no CA scope defines package-record
  visibility.
- **Options offered:** (a) cursors bound to the route/session by the host layer; anyone allowed the method
  sees all records; documented deviation *(recommended)*; (b) ask the spec author. **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** PM-03: queries need protected invocation integration and an observation policy; method permission alone does not imply record visibility (PM §15 l.1620-1633, l.1704-1708). (a) becomes an explicit observation-policy grant when the methods are built (Tier 5).
- **Revised 2026-11-11 (review against 6a4dfa28, item A11):** the premise "passes no caller to providers" is gone: the invocation context's `caller` supplies the authenticated origin (INTERFACE l.2181-2183). PM l.1625 binds each cursor to the original query and to "the ordinary route's authenticated consumer module-instance address or the exact Runtime-owned system-service binding", and l.1704 accounts retained snapshots to the same origin. So cursors and snapshot accounting are keyed on the caller taken from the invocation context, not on the route or session, and the documented deviation is no longer needed. Record visibility follows the observation policy of the note above.

### G40 — Paths longer than USTAR allows
- **Kind:** GAP · **Specs:** PM §7.1 (gzip USTAR; pax not mentioned); PM §4 (artifact paths up to 4096
  bytes).
- **Options offered:** (a) pax `path` records only, when needed *(recommended)*; (b) reject long paths.
- **Decision:** (b): over-limit paths make the package invalid; no pax headers.
- **Settled 2026-11-10 (6a4dfa28):** PM-04: full paths fit USTAR name/prefix at a slash split, in bytes, including the `variants/<id>/` prefix and a directory's trailing slash; no PAX or GNU long names (PM §7.1 l.920-924). Matches (b).

### G41 — Multi-member gzip and directory entries
- **Kind:** GAP · **Specs:** PM §7.1 ("Directory modes MUST be 0755" implies but does not require
  directory entries; RFC 1952 multi-member streams not addressed).
- **Options offered:** (a) reject multi-member; writer emits 0755 directory entries, reader accepts
  either *(recommended)*; (b) accept multi-member, require directory entries. **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** PM-05: exactly one gzip member with CRC32 and ISIZE checked; directory entries optional, explicit ones type `5` with size zero (PM §7.1 l.909-911, l.916-917, l.943-945). Matches (a). New: padding after the end blocks must be whole zero blocks (I49).

### G42 — Ed25519 verification strictness
- **Kind:** GAP · **Specs:** PM §4.3, CA §9.1 (RFC 8032; cofactored vs cofactorless and small-order or
  non-canonical points not pinned).
- **Options offered:** (a) libsodium semantics: cofactorless, reject non-canonical encodings and
  small-order A/R; small-order keys rejected when trust is loaded *(recommended)*; (b) RFC 8032 cofactored.
- **Decision:** (a). Implementation: G135.
- **Revised 2026-11-10 (6a4dfa28):** Superseded by PM-06: Ed25519 is gone from every 6a4dfa28 spec; package signatures and call evidence are pure FIPS 205 SLH-DSA-SHA2-192s with exact 48-byte keys and 16,224-byte signatures and no repair (PM §4.3 l.483-573). The small-order and canonical-S checks remain only until R4.
- **Removed 2026-11-10 (I68):** with the Ed25519 code; SLH-DSA keys have no point encoding to check, so trust input takes any 48 bytes and nothing else (PM §4.3 l.530).

### G43 — Equal identity and commitment from different sources
- **Kind:** GAP · **Specs:** PM §11, §15 (list order: name bytes, descending SemVer, deterministic-CBOR
  bytes of the source).
- **Options offered:** (a) record the first in list_packages order *(recommended)*; (b) first in catalog
  document order. **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** PM-07: equivalent sources are ordered by ascending bytewise det-CBOR source-record encoding (PM §11 l.1313-1316). Matches (a).

### G44 — A candidate cannot be fetched during resolution
- **Kind:** GAP · **Specs:** PM §11 (resolution deterministic; outcome must not depend on local resource
  thresholds).
- **Options offered:** (a) abort with `package-unavailable` *(recommended)*; (b) skip the candidate.
- **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** PM-08: unavailable material fails the root operation with `package-unavailable` and leaves state unchanged (PM §11 l.1294-1296). Matches (a).

### G45 — `manifest.json` inside a package
- **Kind:** GAP · **Specs:** PM §3 (the JSON rendering is diagnostic and must not override), §7.1 (allowed
  at the archive root); no JSON mapping exists to check it against.
- **Options offered:** (a) path-checked, never read or trusted *(recommended)*; (b) reject packages that
  contain it. **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** PM-09: `manifest.json` is removed from LGX; `manifest.cbor` is the only manifest representation (PM §3 l.196-216, §7.1 l.897-906). A root `manifest.json` is now outside the permitted root names, so `invalid-package`. Code changed (I49).

### G73 — LGX platform values and matching
- **Kind:** GAP · **Specs:** PM §7.1 l.1082 ("Platform profiles define the registered os, architecture,
  and abi values" — none exist), l.1083 (variant ids do not define compatibility), PM §3
  (`platform_constraint` is a closed map of three optional fields); BCP §5.2 (an undefined platform
  profile is deployment policy).
- **Options offered:** (a) os {linux, darwin, windows, android, ios}, architecture {x86_64, aarch64}, abi
  optional {gnu, musl, mingw, msvc}; exact byte match; case-insensitive path collisions on darwin/windows
  plus Windows reserved names; dev and release builds as separate packages *(recommended)*; (b) Rust target
  triples split into the three fields. **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** PM-10: platform values and matching rules come from the deployment profile for the target environment (PM §7.1 l.953-960; BCP §5.4); a value with no defined rule never matches; path collisions follow the installation filesystem and namespace, not the target OS (l.927). Our (a) values become that documented profile; code changed (I49).

### G74 — Protected catalog policy
- **Kind:** FREE · **Specs:** PM §11 l.1182-1184 (same package@version with different commitments:
  protected catalog policy selects one, or the operation fails with `dependency-unavailable`; no format).
- **Options offered:** (a) no policy at first; conflicts fail *(recommended)*; (b) a pin file now.
- **Decision:** (a).

### G75 — Concrete resource bounds
- **Kind:** FREE · **Specs:** BCP §5.4 (must be documented); PM §7.1 l.850-853 (five LGX bounds), §11
  l.1117-1153 (four resolver limits from protected policy; no built-in fallback); TRANSPORT §2.1 (frame
  maximum ≥ 16 MiB).
- **Options offered:** (a) a seeded table in the deployment profile, re-set to about 4x what the real
  packages need once measured *(recommended)*; (b) a tight table. **Decision:** (a).
- **Revised 2026-11-11 (review against 6a4dfa28, item B14):** 6a4dfa28 adds bounds the table must carry:
  PM l.667 (provenance envelope size, signature count, accepted keys, candidate-verification attempts),
  l.1704 (per-origin and aggregate snapshot limits), l.1744 (retained watches, queued observation work,
  in-flight publications). The installed-record admission bound of 16 MiB (l.826-832) is Core-owned and
  fixed: the "about 4x" rule does not apply to it, and larger Transport limits do not relax it (l.832).

### G90 — Catalog source of truth and format
- **Kind:** FREE · **Specs:** PM §6 (catalog entry `{identity, source}`, location data only), §4.2/§4.4
  (catalogs are untrusted discovery input; no signature required), §13; no catalog document or refresh is
  defined.
- **Options offered:** (a) the locator lives only in the daemon config; document = det-CBOR
  `{format, sequence: uint64, entries}`, unsigned; a lower sequence than the last seen is rejected
  *(recommended)*; (b) the same without the sequence. **Decision:** (a). Origin per D17.
- **Settled 2026-11-10 (6a4dfa28):** SO-01: catalog format, acquisition, refresh and policy are implementation-defined and must be documented (PM §6 l.836-837). (a) stands.

### G91 — How the Package Manager reads package objects from storage
- **Kind:** FREE · **Specs:** PM §13; INTERFACE §1.3 (reserved prefixes), §1.4 (`_implements`).
- **Options offered:** (a) a small interface contract owned by logos-core-nim (`lcn.storage_fetch`),
  implemented by storage_module: chunked `read_object{object, offset, length ≤ 1 MiB}` plus size; grants
  bind to its stable root *(recommended)*; (b) the PM calls storage's own download methods.
- **Decision:** (a). Depends on G5.
- **Settled 2026-11-10 (6a4dfa28):** SO-02: acquisition is an implementation choice with no common fetch interface (PM §6 l.856-860, §13 l.1437-1438). `lcn.storage_fetch` stands and must be documented.
- **Note 2026-11-17 (step 5-0; Tier 5 plan §8):** the contract as decided has `read_object` and the
  object's size only, no readiness signal, and G136 has the Package Manager wait on one. Tier 5 step
  5-3a defines the contract with a readiness signal (G136); storage_module serves it (N-4).

### G93 — How a module reaches its non-binary artifacts and native libraries
- **Kind:** GAP · **Specs:** PM §10, §12 (the handoff carries only the implementation artifact); LOADER §3,
  §5; INTERFACE §2.6 (init input has only state_dir and configuration).
- **Options offered:** (a) self-contained module binaries, raised upstream *(recommended)*; (b) declared
  resource artifacts passed through a deployment-specific channel; (c) ask the spec author.
- **Decision:** (c). **Status:** OPEN until `6a4dfa28` (answered there, below). Our payload modules are
  built self-contained meanwhile, which needs no answer.
- **Revised 2026-11-10 (6a4dfa28):** PM-11: installed paths are not module-visible; access follows a documented deployment convention, and native libraries go through the Loader's dynamic-linker integration (PM §10 l.1189-1193). Self-contained modules are such a convention. **Status:** answered; document it.

### G94 — Provenance-signing profile
- **Kind:** GAP · **Specs:** PM §4.5 l.611-615 (each provenance-signing profile must define its
  algorithms; none is defined); BCP §5.2.
- **Options offered:** (a) our own `logos-core-nim.provenance-signing.ed25519-dsse.v1`: Ed25519 keys in
  protected trust input, signer key id bound to builder ids *(recommended)*; (b) Sigstore keyless;
  (c) ask the spec author. **Decision:** (a), as deployment-profile material.
- **Revised 2026-11-10 (6a4dfa28):** PM-12: the spec defines `logos.provenance-signing.dsse-slh-dsa-sha2-192s` (PM §4.5 l.651-676), which replaces our Ed25519 DSSE profile when provenance is built.

### G95 — Scope of the Nix package profile
- **Kind:** FREE · **Specs:** PM §7.3 (package-controlled Nix evaluation only inside a pre-verification
  isolation boundary, unless protected input supplies the exact realized output).
- **Options offered:** (a) pre-resolved store paths first, isolation boundary later (rows scheduled)
  *(recommended)*; (b) build the isolation boundary now. **Decision:** (a).

### G96 — Do release deployments select SLSA provenance?
- **Kind:** FREE · **Specs:** PM §4.5; BCP §5.3 (optional profile; selection explicit, fails closed).
- **Options offered:** (a) yes, once the org provenance key exists *(recommended)*; (b) opt-in only.
- **Decision:** (b): implemented and tested; no default deployment selects it.
- **Revised 2026-11-11 (review against 6a4dfa28, item B13):** PM l.734-736: protected provenance
  configuration, "including the absence of a selected profile", MUST satisfy the §4.1 continuity rules
  (monotonic revision, persisted high-water mark, re-enabling or weakening only through a later state), so
  "no default deployment selects it" is itself protected state with continuity; l.737 allows a counter
  separate from package-signing trust. No row says where that state lives (G137's trust file is one
  place); to be designed with provenance (Tier 5).

### G113 — Error codes for provenance failures
- **Kind:** GAP · **Specs:** PM §4.5 vs §14 (closed error list without provenance codes).
- **Options offered:** (a) map onto existing codes — missing locator or failed retrieval
  `package-unavailable`; malformed DSSE/statement/JSON or wrong types `invalid-package`; no accepted
  signer-builder pair, subject mismatch, buildType/source failure `signature-verification-failed`;
  precedence … commitment > provenance > schema … *(recommended)*; (b) ask the spec author.
- **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** PM-13: PM §14 l.1487-1491 maps the failures as (a) did. Matches.
- **Revised 2026-11-11 (review against 6a4dfa28, item A5):** the note above is wrong for the missing locator. PM l.1487: with `logos.package-provenance.slsa-v1.2` selected, an absent required provenance locator, like a malformed or nonconforming envelope or Statement, is `invalid-package`; only failure to retrieve the identified object is `package-unavailable` (l.1488); signer-builder and binding failures are `signature-verification-failed` (l.1489); the first detected failure may be returned (l.1491). Settled differently for the missing locator; the rest matches (a). Not built (Tier 5).

### G114 — A Nix source while provenance is selected
- **Kind:** GAP · **Specs:** PM §4.5 l.582 (defines provenance for LGX sources only), l.680-689 (no
  weakening).
- **Options offered:** (a) reject as missing evidence (`package-unavailable`) *(recommended)*; (b) ask.
- **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** PM-14: a direct Nix root request under LGX-only provenance policy is `unsupported-source`, not `package-unavailable`; Nix-built LGX stays eligible (PM l.603-606, l.1475).

### G137 — Package-signing trust provisioning
- **Kind:** FREE · **Specs:** PM §4.1 l.404-419 (trust input maps each kid to one key and binds each signer
  to a non-empty set of exact package names; no wildcards; downloaded keys establish nothing), l.440-441;
  D18, D27.
- **Options offered:** (a) release builds trust only compiled-in org anchors (rotation = new release); dev
  builds trust the compiled-in dev anchor plus config anchors *(recommended)*; (b) release builds also
  accept operator anchors from the protected daemon config.
- **Decision:** (b). Completed at the final review per PM §4.1: org anchor(s) authorized for exactly the
  six payload package names; operator anchors carry explicit name sets; release builds refuse the
  published dev key (an implementation default reconciling this with D18).
- **Revised 2026-11-10 (6a4dfa28):** NP-10: signing trust needs protected continuity, a monotonic revision with a persistent high-water mark; withdrawal blocks new operations and handoffs (PM §4.1 l.395-405). Keys are 48-byte SLH-DSA keys. **Status:** the continuity design is open (how compiled-in anchors join the revision, where the mark persists).
- **Decided 2026-11-10 (owner: "proceed with your recommendations"):** one protected trust file with a monotonic revision and a compiled-in floor. The file (owner-only, in the daemon's protected configuration) holds a revision number, the profile and every anchor (kid, 48-byte key, exact package names), the operator's and the org's alike. A release binary embeds its org anchors and a floor revision: without a file, that embedded set is the trust input at the floor revision; a file below the floor, or one that omits an embedded org anchor, is refused (withdrawing an org anchor takes a release that raises the floor). The Package Manager persists the high-water revision with a digest of its contents in its protected state directory before using a new revision; an older revision, or different contents at the same revision, is refused, and an identical replay changes nothing (PM §4.1 l.395-401). Losing the mark needs protected re-establishment. Still to state in the deployment documentation (PM l.402): whether running modules depend on current signing trust. Built with the Package Manager (Tier 4/5).
- **Revised 2026-11-11 (review against 6a4dfa28, item A12):** the decision's "release builds refuse the published dev key" (and the same bullet in section 13) conflicts with D27's re-decision (a): one build serves development and production, and development trust is enabled only by a protected-configuration switch, never by the build mode (BCP l.400). Two questions follow. Does a release binary accept the dev anchor when the switch is on? And is the dev anchor an entry of the trust file? If the switch adds it, that changes the key mappings, which PM l.395-398 allow only through a newly authorized later revision. The note above's documentation citation is corrected from PM l.403 to l.402. See also D27 (BCP l.399; whether the dev key is published, A13). **Needs an owner decision** (review item A12).
- **Re-decided 2026-11-11 (owner: "Accept all", after the Fable 5.2 session's review of the recommendations, item A12):** "release builds refuse the published dev key" is
  withdrawn. The dev anchor is an entry of the trust file; the text settles that, since key mappings are
  under the revision (PM l.395-397) and a development anchor goes "through the same protected trust-input
  path" (l.443-444). The development switch, or a per-entry development marker, lives in the same file,
  so the effective key set is a function of one revisioned document. Turning it on or off is a later
  revision (l.397-398), and turning it off is a withdrawal (l.403) with the documentation duty of l.402.
  A release binary accepts the dev anchor only while that switch or marker is on (D27).

- **Amended 2026-11-15 (owner, "Accept, start 4b-6", U7):** for Tier 4b the high-water mark is kept
  by logosd in its own state directory (`state/trust-mark.cbor`, G299); whether the Package Manager keeps
  its own mark is Tier 5's. The carrier is built for D27's switch (I95, part 4b-6a); the anchors and
  PKG-0418–0424 come with the Package Manager.
- **Amended 2026-11-16 (owner: "Start 4b-8, claim 0422"; decision 11 (a) as amended):** PKG-0422, the
  documentation duty of PM l.402, is claimed in step 4b-8 with a true "no": continued execution does
  not depend on current package-signing trust acceptance, because the trust file holds no
  package-signing anchors, no instance has a signer or package fact (HOST-CONFIG's attribute-source
  statement widened from direct to every instance, hosted ones included), and a trust-file change
  takes effect only at the next start. Tier 5 is expected to change the answer
  (`docs/DEPLOYMENT.md` §1; inspection item `deploy-trust-dependence`; I97, part 4b-8b). PKG-0418 to
  PKG-0421, PKG-0423 and PKG-0424 stay with the Package Manager.
### G150 — `catalog set` and `catalog refresh`
- **Kind:** FREE · **Specs:** PM §15 (no refresh or catalog-configuration method); the PM receives its
  protected inputs at start.
- **Not offered as a question** (implementation default from the final review): `catalog set` writes the
  daemon config and restarts the PM instance so it receives a fresh handoff; `catalog refresh` restarts
  the PM instance, which re-fetches.

### G156 — An artifact without its hash
- **Kind:** CONTRA, **OPEN** (found while building; reported as NP-15 in `claude-spec-comments-2.md`,
  logos-lips `05b137a4`) · **Specs:** PM §4 l.322-327 (`manifest_artifact` requires
  `hash: bstr .size 32`), §8 l.971-974 (a manifest that does not validate against its schema is
  `invalid-package`) vs §8 l.996-1001 ("an artifact omits its required hash" is
  `artifact-integrity-failed`).
- **Description:** the manifest is the only place an artifact record lives, and its CDDL requires the
  hash, so a record without one fails l.974 before any artifact is read; l.1000 then names a second code
  for the same input.
- **Options:** (a) `invalid-package`: the schema check runs first, as in G29's order; (b)
  `artifact-integrity-failed`, by treating l.1000 as an exception to l.974; (c) ask the owner.
- **Interim (D9):** (a), in `package/manifest.nim` `decodeManifest`, test `[IMPL-DECISION G156]`;
  requirement unit PKG-0275 stays deferred. Error code only.
- **6a4dfa28:** not answered (NP-15). PM §8 l.1070 now lets an implementation stop at the first detected failure, so the interim `invalid-package` conforms.
- **Restated:** against 6a4dfa28 in `claude-spec-comments-2.md`, "Items without a response" (logos-lips
  `68628d95`).

### G166 — Key rotation leaves installed packages that cannot move to the new key
- **Kind:** GAP · **Specs:** PM §4.1 l.429-431 (rotation MAY overlap old and new identities; a removed or
  revoked anchor MUST NOT be used for a new resolution, installation, update or Runtime handoff),
  l.403-405 (withdrawal blocks handoffs; retained verification provenance MUST NOT substitute for current
  trust); §4.3 l.538-541 (the verified `package_signer` is retained with installed state and reported by a
  handoff); l.1667 (installing an installed identity with the same manifest commitment returns the
  current record and changes nothing); l.1672 (`remove_package` fails with `package-in-use` while another
  installed package depends on it); l.1680 (an update needs a strictly greater version).
- **Description:** once the overlap ends, an installed package whose only signature is from the removed
  anchor can no longer be handed off, and no operation replaces its retained signer: the same manifest
  re-signed with the new key installs as the old record, and an update needs a new version. What remains
  is `remove_package` then `install_package`, which l.1672 refuses while another installed package
  depends on it, or a re-release of every package signed with the old key.
- **Options:** (a) install or update re-verifies an installed identity with an unchanged manifest
  commitment under a new signature and replaces its retained signer *(recommended)*; (b) a dedicated
  re-verification operation; (c) the spec states that rotation means re-releasing every such package.
- **Interim:** none needed before installation is built (Tier 5); the text as written then applies: a
  package whose signer is no longer accepted is not handed off, and the operator removes and reinstalls
  it.
- **Status:** OPEN, found 2026-11-10; reported as TF-07 in `claude-spec-comments-3.md` (logos-lips `68628d95`).

### G167 — The recorded edges of an installed package reused as a dependency
- **Kind:** GAP · **Specs:** PM §11 l.1287-1293 (a dependency candidate is checked against the installed
  record of its exact identity; another commitment fails the operation), l.1292-1293 (an installed
  candidate with that identity and commitment MAY satisfy the dependency without being materialized
  again), l.1315 ("Source selection MUST preserve the recorded dependency edges of installed packages"),
  l.1324-1326 (catalog changes MUST NOT alter recorded edges; one closure selects one version per name);
  §15 l.1660-1661 (an installed package satisfies a selected dependency when its name, version and
  commitment match the recorded resolution), l.1672 (`remove_package` checks recorded dependency
  closures), l.1689-1690 (only for `update_package`'s root: an installed target's recorded edges must
  equal the newly selected ones, or `dependency-unavailable`).
- **Description:** nothing says how an installed package that the resolver reuses as a dependency brings
  its own recorded edges into the new closure. Example: B@1.0.0 was installed when C@1.0.0 was the newest
  C ^1.0.0, so its record holds the edge C@1.0.0; the catalog later gains C@1.1.0; installing R, which
  needs B ^1.0.0, reaches the installed B.
- **Options offered:** (a) the installed candidate's recorded edges are fixed exact identities and
  commitments, not resolved again; a clash with another requirement rejects that candidate and resolution
  backtracks *(recommended)*; (b) resolve its manifest requirements again and fail with
  `dependency-unavailable` when the new edges differ from the recorded ones, as l.1689-1690 do for an
  update's root; (c) resolve again and ignore the recorded edges, so R's recorded closure reaches both
  C@1.0.0 (through B) and C@1.1.0.
- **Independent opinion** (Fable 5.2 session, 2026-11-11, reading 6a4dfa28): (a) is the reading the text
  supports best. A candidate is "an installed package record" (l.1280) whose entries bind exact
  identities and commitments (l.1323), and the installed graph is the recorded one (l.1315, l.1324,
  l.1660-1661, l.1672). (b) applies a root rule (l.1689-1690, which l.1291 leaves to the operation) to
  dependencies: it fails while a closure exists, against l.1308-1309, and once C@1.1.0 is published no
  operation repairs it. (c) breaks l.1325-1326 when R also requires C directly, and preserves no recorded
  edge (l.1315). (a) still rests on reading a recorded edge as an accumulated requirement (l.1281), which
  the text never says. A fourth reading, (d), re-resolves B afresh and backtracks over C until the
  selected edges equal the record: same closures as (a), but C@1.1.0 counts as a consideration and an
  attempt (l.1254-1265, which l.1270-1271 forbid to depend on local choices), and an unobtainable C@1.1.0
  fails it with `package-unavailable` (l.1294) where (a) succeeds. So the spec must pick even between
  (a) and (d).
- **Decision:** (a) (owner, 2026-11-11: "I'm leaning towards A. Proceed with that option while we wait
  for Fable's opinion"; the opinion agrees). Stated as: an installed candidate contributes its recorded
  direct edges as exact requirements (identity and commitment), transitively; a version such an edge
  excludes is neither inspected, considered nor charged; a clash makes the installed candidate
  unsatisfiable and resolution backtracks. In the example, R installs with C@1.0.0. Implementation: I69.
- **Status:** decided, found 2026-11-11; not yet sent to the spec author when decided, since reported as
  TF-12 in `claude-spec-comments-3.md`, logos-lips `457527eb` (branch
  `draft/logos-core-module-specs-discussion`; review item C10).

### G351 — "Package-backed" is not defined; when the handoff is obtained again
- **Kind:** GAP (K28, K29; TF-44), open · **Specs:** RUNTIME l.1388-1391 (handoff facts are accepted
  evidence only from the authenticated Package Manager; other inputs MAY supply equivalent facts),
  l.3519 (`selection.signer` of a package-backed selection), l.3539 (recovery rechecks trust),
  l.3614-3616 (protected exact package pins for package-backed declarations), l.3637 (a start uses the
  retained declaration); PACKAGE MANAGER l.403 (withdrawal blocks later handoffs), l.1392 (no handoff
  for a package no longer accepted), l.1715 (the engine is not admitted to the watch).
- **Description:** rules attach to a "package-backed" selection or declaration, which is not defined,
  and whether the Runtime asks for a new handoff before each realization, and what a refusal or a
  changed handoff then does, is not stated.
- **Interim proposed (Tier 5 plan §6; owner decision D2, open):** an instance is package-backed when its
  declaration was taken from an authenticated handoff (l.1388). Host declarations and the provisioned
  Package Manager and Storage instances never are. A handoff is asked for before every realization. A
  refusal, or a handoff whose identity, commitment, signer, artifact hash or declaration differs from the
  retained selection, fails the start and keeps the intent (l.3637); `local_path` alone may change. The
  selection persists (l.3542). Orchestration starts the Package Manager before any package-backed
  instance (l.256). An instance pinned to an updated or removed package cannot start again until it is
  replaced, and the deployment document says so.
- **Status:** OPEN, a D9 stop for Tier 5 step 5-8 until D2 is decided. Nothing is package-backed at
  `3c6f3c3` (G55: host-configured declarations; `docs/DEPLOYMENT.md` row 10b). In the comments document
  as TF-44; not sent to the spec owner. Recorded 2026-11-17 by step 5-0.

### G353 — Installed records come only from installation (K30)
- **Kind:** spec-resolved (K30, partly PM-02, which `6a4dfa28` declined) · **Specs:** PACKAGE MANAGER
  l.831 (restoring installed state), l.1440-1442 ("Provisioning these inputs does not itself create
  installed package records or establish Package Manager verification").
- **Description:** whether anything other than `install_package` or `update_package` may create an
  installed record, for example the protected provisioning of the initial Package Manager and Storage
  providers.
- **Reading:** the text settles it: provisioning creates no installed record and establishes no Package
  Manager verification (l.1442), and restoring state restores the records installation made (l.831).
  Only installation creates them. Tier 5 step 5-5 builds installed records through install and update
  only; step 5-6a provisions the Package Manager and Storage instances without records (PKG-0513).
- **Status:** settled by spec text; no gap. Recorded 2026-11-17 by step 5-0.

---

## 10. logosctl, logosd and the session

These follow from D13 (loopback mTLS remote Runtime Control). The CLI process embeds its own small
Runtime, which connects to the daemon's Runtime as an enrolled remote Runtime.

**Revised 2026-11-11 (review against 6a4dfa28, item C2):** the paragraph above no longer holds. D13 was
re-decided on 2026-11-10 to (a): a persistent, consumer-only `logosctl` module instance inside the daemon,
reached from the shell over an owner-only local socket; the shell binary creates no Runtime. D13's note
says the rows here that assume loopback mTLS are to be redone with Tier 4b. The notes on G78, G79, G80,
G83, G84, G85, G86, G87 and G76 below say what each redo has to cover. G88, G89, G145 and G146 do not
depend on the CLI Runtime.

**Note 2026-11-15 (I95):** the redos are done: G293–G304 below, built in I95. The rows above them keep
their history.

### G78 — Authority inside the CLI's embedded Runtime
- **Kind:** FREE · **Specs:** RUNTIME §9 l.1490-1493 (internal policy allowed for local trusted
  deployments).
- **Options offered:** (a) internal protected policy; the CA module runs in the daemon only
  *(recommended)*; (b) the CA module in the CLI Runtime too. **Decision:** (a).
- **Revised 2026-11-11 (review against 6a4dfa28, item C2):** void since D13 was re-decided to (a): there
  is no CLI Runtime to hold internal policy. The persistent `logosctl` instance is an ordinary local
  consumer of the daemon's Runtime, authorized like any other (D15, G82). To be redone with Tier 4b.

- **Redone 2026-11-15 (I95, part 4b-6a):** G295. The authority instance is logosd's own; its policy is
  logosd's system rules S1–S5 merged with the operator's rules from daemon-config.
### G79 — Composition of the CLI Runtime
- **Kind:** FREE · **Specs:** BCP §5.1 l.249-250 (individual-spec conformance does not require the
  Loader); RUNTIME l.71 (a Runtime instance = engine + orchestration module), l.182 (deployment MUST bind
  the orchestration role to a local module instance), l.185 (the role needs no provider contract),
  l.1499.
- **Options offered:** (a) Loader + orchestrator + logosctl, claiming complete-system conformance
  *(recommended)*; (b) engine + logosctl only, claiming Runtime-only conformance.
- **Decision:** (b). Completed at the final review: the `logosctl` instance holds the orchestration role
  (no provider contract, no startup defaults, restart policy disabled).
- **Revised 2026-11-11 (review against 6a4dfa28, item C2):** void since D13 was re-decided to (a): the
  shell binary composes no Runtime. The `logosctl` instance lives in the daemon's Runtime, whose
  orchestration role is already bound, so it does not hold that role. To be redone with Tier 4b.

- **Redone 2026-11-15 (I95, part 4b-6a):** G294, logosd's composition: the Loader (the engine's),
  `orchestrator`, `logosctl`, `authority` and the operator's modules.
### G80 — Concurrent logosctl invocations
- **Kind:** FREE · **Specs:** RUNTIME §9 (two live Runtimes cannot share one identity), §9.3 l.2318
  (runtime ids are UUIDv4), l.2361-2370 (per-Runtime trust revision state).
- **Options offered:** (a) an identity pool: `init` provisions N enrolled CLI identities (default 4), each
  with its own lock *(recommended)*; (b) one invocation at a time. **Decision:** (a); each slot keeps its
  own trust state and revisions.
- **Revised 2026-11-11 (review against 6a4dfa28, item C2):** the identity pool is void since D13 was
  re-decided to (a). Concurrent shell commands now reach one persistent `logosctl` instance, so they share
  one authenticated consumer and one `request_key` scope: route-operation keys are scoped to the
  authenticated consumer and Runtime instance (RUNTIME l.3168), `create_module` keys to the method, the
  consumer and the Runtime instance (l.3627). The redo has to keep keys from concurrent shell commands
  apart. To be redone with Tier 4b.
- **Redone 2026-11-15 (I95, part 4b-6b):** G297. The shell generates a `create_module` key per
  command, so concurrent commands of the one instance never share a key unless the user names one.

### G83 — Terminal input and output for logosctl
- **Kind:** FREE · **Specs:** RUNTIME Abstract l.35-38 (implementation-local presentation mechanisms MAY
  be used if they create no participant and change no identity, lifecycle, routing, authority,
  observation or audit semantics), §11 (no separate presentation participant or authority path); BCP
  §5.3 l.305 (no presentation profile assigned), §5.4 (the deployment documents its choice); LOADER §5
  (handoffs are operational input, not authority, not in public records); INTERFACE l.2632-2642 (init
  input has no presentation field).
- **Options offered:** (a) an implementation-local handoff of argv, stdio and exit code to the logosctl
  instance at init, documented *(recommended)*; (b) ask the spec author.
- **Owner's question:** "IS the implementation-local handoff spec-compliant? would this restrict the
  logosctl modules from running in a separate process?" Answer given: compliant under the conditions
  above; not restricted — in-process today, and inherited file descriptors (like the LOADER §5.3 listener
  handoff) if logosctl were ever hosted.
- **Follow-up options:** (a) yes *(recommended)*; (b) ask the spec author. **Decision:** (a).
- **Note:** asked as a GAP; re-labelled FREE at the final review (RUNTIME Abstract delegates it).
- **Revised 2026-11-11 (review against 6a4dfa28, item C2):** AP-6 is answered (SPEC-STATUS: resolved in
  6a4dfa28): the RUNTIME Abstract text now sits at l.36-39 and still allows implementation-local
  mechanisms that create no participant and change no Runtime-owned semantics. The decision's "handoff of
  argv, stdio and exit code to the logosctl instance at init" cannot hold for the persistent instance of
  D13 (a), which is initialized once and serves many shell commands. The handoff becomes per-command
  activation over the owner-only socket, and BCP l.384 (new) requires the deployment to document five
  things: activation mechanism, admission policy, accepted application selection, presentation handoff
  and failure behavior. BCP l.389: arguments and presentation resources remain application input and do
  not establish consumer identity or Runtime authority. To be redone with Tier 4b.
- **Redone 2026-11-15 (I95, part 4b-6b):** G296. Per-command activation over the owner-only socket, the
  in-process presentation handoff at init; arguments are application input. DAEMON.md §7 documents BCP
  l.384's five items.

### G84 — Which providers the daemon exports
- **Kind:** FREE · **Specs:** RUNTIME §9.3 l.2473 (listeners and exports disabled unless explicitly
  enabled; package installation, realization and registration MUST NOT enable them).
- **Options offered:** (a) PM + CA exported at `init`; payload modules exported on `module load`
  *(recommended)*; (b) every ready provider exported automatically. **Decision:** (a).
- **Refined at the final review:** CA at `init`, PM once it exists (milestone M7); storage_module's
  export comes from the daemon config's deployment input because it is started by an orchestration
  default; `module load` issues an explicit `set_provider_export`; `call` never exports silently.
- **Revised 2026-11-11 (review against 6a4dfa28, item C2):** exporting PM and CA at `init` existed so the
  remote CLI Runtime could reach them. With D13 (a) the `logosctl` instance is local and needs no export.
  Remote listeners and provider exports MUST be disabled by default (RUNTIME l.2830-2831), and a secure
  deployment keeps them disabled until protected deployment input enables them (SECURITY l.524). To be
  redone with Tier 4b: exports only for real remote consumers, enabled by deployment input or authorized
  Runtime Control.

- **Redone 2026-11-15 (I95, part 4b-6a):** G298. logosd exports no provider and opens no listener in
  Tier 4b; the remote methods answer as K19's approved interim.
### G85 — The daemon's listener port
- **Kind:** FREE · **Specs:** RUNTIME §9.3 (listener records keyed by the full address; "When enabling a
  listener, Runtime MUST validate and activate its address … If activation fails, the method MUST fail
  without reporting the listener as enabled"; the same rules apply to deployment input).
- **Options offered:** (a) picked at init and pinned *(recommended)*; (b) a fixed default port.
- **Owner's answer:** "by default picked at init, also configurable. Also, what happens if the port gets
  taken during a restart?"
- **Follow-up options:** (a) `logosd` fails to start with a clear error naming the port; the operator
  changes it in the daemon config *(recommended)*; (b) re-pick a port and rewrite the config and endpoint
  file; (c) retry for about 30 s, then fail. **Decision:** (a). The CLI finds the port through the
  daemon's endpoint file, so a changed port needs no CLI change.
- **Revised 2026-11-11 (review against 6a4dfa28, item C2):** the CLI no longer uses the listener: with
  D13 (a) the shell reaches the `logosctl` instance over the owner-only socket. A remote listener is then
  needed only for real remote Runtimes, and it MUST be disabled by default (RUNTIME l.2830-2831; SECURITY
  l.524), so "picked at init" no longer applies to a default install. To be redone with Tier 4b; the
  socket path takes the endpoint file's place.
- **Redone 2026-11-15 (I95, part 4b-6b):** the socket part is G296 (`run/logosctl.sock`, or
  `ctl.socket_dir`); there is no listener (G298).

### G86 — Session mTLS trust
- **Kind:** FREE · **Specs:** TRANSPORT §8.4, §8.4.1 (mutual TLS 1.3; enrollment provisioned explicitly,
  no trust on first use); RUNTIME §9.3 l.2318-2370.
- **Options offered:** (a) an Ed25519 session CA (10-year validity) whose key is kept 0600 for rotation;
  enrollments pin exact SPKIs *(recommended)*; (b) no CA, self-signed identities pinned by SPKI.
- **Decision:** (a); runtime ids are UUIDv4.
- **Revised 2026-11-11 (review against 6a4dfa28, item A14):** superseded for the CLI, which no longer
  enrolls (D13 re-decided to (a)); the row is re-decided for real remote Runtimes only. For that, 6a4dfa28
  adds: certificate path validation per RFC 5280 §6.1 under the enrollment's trust anchor, plus the leaf's
  DER SPKI equal to an enrolled value (TRANSPORT l.1248-1250, l.1257); protected policy MUST define
  accepted revocation evidence for every non-anchor certificate, so (a)'s session-CA-issued leaves need one
  (l.1265); a directly provisioned anchor needs full DER equality, "an SPKI match alone does not establish
  that case", which rules out (b) as written (l.1260); and enrollment selects algorithms the intended
  peers support, P-256 ECDSA named as the common option (l.1238-1239), which an Ed25519 CA has to be
  checked against. **Needs an owner decision** (review item A14).
- **Re-decided 2026-11-11 (owner: "Accept all", after the Fable 5.2 session's review of the recommendations, item A14):** superseded for the CLI; re-decided for remote Runtimes at
  Tier 5, against the constraints the note above lists: RFC 5280 path validation plus an enrolled SPKI
  (TRANSPORT l.1248-1250, l.1257), DER equality for a directly provisioned anchor (l.1260), revocation
  evidence for every non-anchor certificate (l.1265), and algorithms the intended peers support, with
  P-256 ECDSA as the common option (l.1238-1239).
- **Re-decided 2026-11-17 (owner, Tier 5 batch B, B2, approved as written; recorded by step 5-0):** for
  real Runtimes, a long-term P-256 key and a self-signed certificate used as a direct anchor. The
  certificate is in a remote trust-anchor set with its own revision; the enrollment holds the anchor's
  identifier and the key (RUNTIME l.2680, l.2723). Key Usage digitalSignature; Extended Key Usage absent
  or both purposes. A long validity, or renewal by a new trust-anchor revision at every peer; rotation is
  a cutover. The key is used as owner decision B1 decides (a signing seam; logosd signs by default),
  differs from the evidence key (CA l.1268), and is made by a separate offline command, not at `init`. A
  configured Runtime id must be a lowercase UUIDv4 when remote is enabled. No certificate that is not
  itself an anchor is accepted, so no revocation evidence is needed (TRANSPORT l.1265). The verifier is
  step 5-2's (G324); the key, the command and the anchor set are step 5-7a's.

### G87 — When trust and enrollment changes apply
- **Kind:** FREE · **Specs:** RUNTIME §9.3 l.2333-2371 (revisions, revocation), TRANSPORT l.1061 (a
  revoked or conflicting enrollment closes connections).
- **Options offered:** (a) at the next daemon start; live-revocation rows claimed through the restart path
  *(recommended)*; (b) live. **Decision:** (a); `trust rotate` bumps the revision on the daemon and on
  every CLI slot.
- **Revised 2026-11-11 (review against 6a4dfa28, item C2):** "every CLI slot" is void with G80's pool.
  Trust and enrollment revisions now concern only real remote Runtimes, whose listeners are off by default
  (RUNTIME l.2830-2831). To be redone with Tier 4b.

- **Redone 2026-11-15 (I95, part 4b-6a):** G299. Trust-file revisions are written offline under the
  session lock and apply at logosd's next start; there is no enrollment in Tier 4b.
- **Redone 2026-11-17 for enrollment (owner, Tier 5 batch B, B3, approved as written; recorded by step
  5-0):** enrollment and remote trust-anchor changes are made offline, under the session lock, and apply
  at the next start, as the trust file does (G299). A revoked enrollment closes its connections by the
  restart (TRANSPORT l.1277). Built in Tier 5 step 5-7a.
### G88 — Binaries
- **Kind:** FREE · **Specs:** BCP §7 (informative).
- **Options offered:** (a) one `logosctl` for daemon and CLI plus a separate `logos_module_host`
  *(recommended)*; (b) a separate daemon binary.
- **Owner's question:** "I'd like to follow the docker model here. Do they use different binaries? I'm
  leaning towards one logosctl". Answer given: Docker ships `docker` (CLI) and `dockerd` (daemon) plus
  per-container shims; it was one binary until 1.11; Podman is one binary.
- **Follow-up options:** (a) one logosctl + module host *(recommended)*; (b) the Docker split
  `logosctl` + `logosd`; (c) one binary that also answers to `logosd`. **Decision:** (b).
- **Second follow-up:** (a) `logosd` directly, plus a `logosctl daemon start` convenience
  *(recommended)*; (b) `logosd` only. **Decision:** (b): logosd is started directly or by a service
  manager. Version 1.0.0; session `$HOME/.logos-core`, `$LOGOSCTL_SESSION_DIR`, `--session-dir`.
- **Built 2026-11-15 (I95, part 4b-6b):** `logosd` and `logosctl` (POSIX hosts; a Windows build of
  either exits 2), packaged by the flake and nimble `bin`; the version is the package's (G88's 1.0.0 at
  release).

### G89 — CLI output and exit codes
- **Kind:** FREE · **Specs:** none.
- **Options offered:** (a) JSON when stdout is not a TTY or with `--json` (`{status, module, method,
  result}`; bstr as lowercase hex; integers above 2^53 as decimal strings); exit 0 ok, 1 usage/host,
  2 daemon unreachable, 3 PM/CA domain-error arm, 4 `LOGOS_ERR_*` *(recommended)*; (b) always JSON.
- **Decision:** (a); exit 3 widened at the final review to any contract domain-error arm.
- **Built 2026-11-15 (I95, part 4b-6b):** each JSON envelope also carries `deployment` and, where one
  was used, `request_key` (G303). Exit 3 has no source in Tier 4b: no Runtime Control method has a
  domain-error arm. [IMPL] `--text` keeps text output when stdout is not a terminal; `--json` with
  `--text` is a usage error (exit 1).

### G76 — Host configuration formats
- **Kind:** FREE · **Specs:** RUNTIME §13.3 l.3421 (the implementation must document each supported
  `configuration_format` identifier and its semantics).
- **Options offered:** (a) deterministic CBOR with a published CDDL, id
  `logos-core-nim.daemon-config.v1`, JSON rendering via logosctl, unknown keys rejected *(recommended)*;
  (b) JSON; (c) TOML. **Decision:** (a); extended at the final review with `logos-core-nim.cli-config.v1`
  and `logos-core-nim.app-config.v1` (mobile host apps).
- **Revised 2026-11-11 (review against 6a4dfa28, item C3):** `logos-core-nim.cli-config.v1` is void: it
  configured the CLI's own Runtime (the Host Embedding API's `configuration_format`, now RUNTIME
  l.4034-4035; the row's l.3421 is the f4f83471 position), and since D13 was re-decided to (a) the shell
  binary creates no Runtime. `daemon-config.v1` and `app-config.v1` stay.
  Whatever the shell `logosctl` still reads (socket path, output defaults) is not a Runtime configuration
  format. To be redone with Tier 4b.
- **Revised 2026-11-11 (I81):** `logos-core-nim.app-config.v1` is built: one deterministic-CBOR value
  of `lcn.app_config` (`src/logos_core/runtime/host_config.cddl`, codecs generated into
  `host_config_types.nim`), documented with its semantics in `docs/HOST-CONFIG.md` (RUNTIME l.4033),
  and named by `LCN_RUNTIME_CONFIG_FORMAT_APP_V1` in `logos_runtime.h`. Unknown keys are rejected
  (closed maps). `daemon-config.v1` stays with Tier 4b.

- **Redone 2026-11-15 (I95, part 4b-6a):** `daemon-config.v1` is G293, logosd's own file, from which
  logosd derives one `app-config.v1` value; it is not a `configuration_format` of the library.
- **Re-decided 2026-11-15 (owner, "Accept, start 4b-6", U2):** every configuration-shaped value is
  written and read in CBOR diagnostic notation (`cbor/diag.nim`); command results stay JSON (G89), and
  JSON is output only: no value is read back from it (BCP l.392).
### G293 — logosd's `daemon-config.v1`
- **Kind:** Choice (U1, U2; G-dc) · **Specs:** BCP l.359 (the deployment documents its configuration),
  RUNTIME l.4033-4035 (each `configuration_format` documented; `app-config.v1` is the library's), l.2665
  (a host-assigned Runtime id).
- **Decision:** `logos-core-nim.daemon-config.v1` is logosd's own protected file, one deterministic-CBOR
  `lcn.daemon_config` in `<session>/daemon-config.cbor` (`src/logos_core/daemon/daemon_config.cddl`,
  codecs in `daemon_config_types.nim`), not a `configuration_format` of the library: logosd derives one
  `app-config.v1` value from it (G294). Where app-config has a rule it is reused (`lcn.app_*`, and the
  policy's `lcn.ap_*`, resolved in one document), so a field means the same in both; it adds `policy`
  (allow-all, or capability-authority with the operator's rules and options), `orchestration` (start
  list, restart, overrides, resync), `call_audit.store`, `permissions`, `ctl` and `test_hooks`. Every path
  is absolute. The session layout is fixed (`daemon/session.nim`: the lock, `keys/`, `state/`, `work/`,
  `run/`; directories 0700, files 0600, a link refused). The checks before anything starts (DAEMON.md
  §3), each failure naming the field: (1) one value within 64 MiB matching the schema; (2) the reserved
  instance ids (`orchestrator`, `authority`, `logosctl`, `logos_module_loader`) and module names, no
  `direct_static` operator module, ordering and the start list naming operator instances, overrides
  naming operator instances or `logosctl`/`authority`, initial settings never naming a system instance or
  module; (3) the development switch for allow-all and `test_hooks` (G300); (4) the evidence key against
  its binding (batch E item 19) and the store's bounds; (5) the derived app-config through the library's
  own checks. Configuration-shaped values are written and read in CBOR diagnostic notation (U2); JSON is
  output only. Supersedes G76's daemon part.
- **Status:** decided 2026-11-15 (owner, batch E item 18: U1, U2); built in I95, part 4b-6a
  (`daemon/config.nim`, `compose.prepareDaemon`; `test_daemon_config` dc.schema and dc.checks).

### G294 — logosd's composition and bootstrap
- **Kind:** Choice (G-compose; the G79 redo; decisions 3 and 8) · **Specs:** BCP l.287-291 (the Loader
  realizes every other instance), RUNTIME l.182-194 (the orchestration role), l.1499.
- **Decision:** `compose` is a pure function from a checked daemon-config to one app-config: the
  instances `orchestrator` (`lcn_orchestrator`, `direct_static`, state `orchestrator`, its value
  provisioned), `logosctl` (`direct_static` `logosctl`), `authority` (under capability-authority, state
  `authority`) and the operator's modules, in that order; no Loader record (the engine's, G246). The
  layout gives `work_dir`, `state_root`, `store_dir` and `endpoint_dir`; daemon-config gives the Runtime
  id. The orchestration value: the authority, then `defaults` = `logosctl` and the start list, the
  operator's `ordering` (in both places, G287), `restart`, `overrides`, `resync_ms`. Permissions: always
  the reference profile (decision 3); host-ambient for the three system instances; the operator's
  entries; and, for an operator module with no module entry, a module-level host-ambient, the minimum
  every realization needs (G280) `[IMPL]`. `module_host`: the configured one, else
  `<d>/../libexec/logos-core/logos-module-host`, else `<d>/logos-module-host`, where `<d>` is the
  directory of logosd's executable with its links resolved.
- **Status:** built 2026-11-15 (I95, part 4b-6a; `daemon/compose.nim`; dc.compose).

### G295 — logosd's system rules and default policy
- **Kind:** Choice (G-policy; the G78 redo; G82 and G140 made concrete for the system part) · **Specs:**
  BCP l.360; RUNTIME l.1490-1493, l.1676, l.3540, l.3807-3808; CA l.126 (an empty list permits none) and
  §3's containment.
- **Decision:** under capability-authority logosd merges its system rules with the operator's into one
  `lcn.authority_policy` (every array a set). They are derived from the reserved ids, not configurable,
  and listed in DAEMON.md §5. S1: the authority module publishes `observed_change`. S2: the orchestrator
  calls P5's methods plus `start_module` (and `stop_module` for `stop` defaults), subscribes to P5's
  events, and starts its origins with host-ambient. S3: `logosctl` calls the 17 shell methods (no
  `evaluate`, G82), subscribes to nothing, and starts and stops with host-ambient. S4: `logosctl` cannot
  start, stop, recover, retire or reconfigure the Loader, the authority or itself. S5: nor start, stop,
  retire or reconfigure the orchestrator, which it may only recover (l.3808). Deny overrides allow, so no
  operator rule widens S4 or S5. Three forms follow from the CA's matching, found by the decision table
  in `test_daemon_config`: a method request carries no event list, so a Runtime Control pattern that
  lists events never covers it, and S2 and S3 allow their methods without `events` and deny the events
  they do not subscribe to; a lifecycle request names its target's module, which only a modules-only
  `targets` subject contains, so S4 and S5's Runtime Control denies name the reserved modules (check 2
  keeps every instance of them a system one) while their execution denies name the instance ids; and an
  absent `modes` covers direct and hosted starts, so each start rule holds one execution scope with
  host-ambient (G207). `logosctl init`'s default is `{capability-authority, source "logosd-default",
  recovery: true, rules: []}`; an absent `recovery` is off (U8). allow-all needs the development switch.
- **Status:** decided 2026-11-15 (owner, batch E item 18: U8); built in I95, part 4b-6a
  (`compose.systemRules`, `mergedPolicy`; dc.policy evaluates the table with the authority's own
  evaluator).

### G296 — The logosctl instance and its socket
- **Kind:** Choice (G-ctl; K20, as approved: U4; D13(a) with its four conditions; decision 9; the G83
  redo and G85's socket part) · **Specs:** BCP l.382 (requester provenance), l.384-392 (activation and
  its five items; no command selects or grants; no dispatch before init returned; responses verbatim);
  RUNTIME l.36-39, l.1604-1606, l.2561, l.3365; THREAT l.1107.
- **Decision:** the `logosctl` module is consumer-only and persistent, linked into logosd (`direct_static`
  binding `logosctl`), realized by the Loader and started by the orchestrator after `authority`. Its
  instance serves `<session>/run/logosctl.sock` (or `ctl.socket_dir`): a 0700 directory, the socket 0600,
  backlog 64, the path checked against `sun_path`. The path and settings reach it at init through an
  in-process presentation handoff (path, workers, idle timeout, deployment, trust revision, version, start
  time); nothing that authenticates a caller crosses the handoff or the socket. Admission: a peer of
  another uid is closed with nothing written and logged (one line per second at most), and the shell
  checks the listener's uid before it sends. Workers: `ctl.workers` (1–32, default 4) commands in service;
  one more connection is answered `busy` as it is accepted, before anything is read. A command that
  arrives before init returned waits for it (BCP l.388). Each `rc` command is one Runtime Control call of
  the instance with the shell's request bytes, deadline `min(deadline_ms, 60 s)`, its response returned
  verbatim; the seventeen methods of `CtlMethods` are a closed choice. `daemon-info` is one `get_self`.
  The wire format `logos-core-nim.ctl.v1` (`ctl.cddl`): a 4-byte big-endian length and one
  deterministic-CBOR value, at most 32 MiB each way; every reply names the deployment; refusals
  `protocol`, `command`, `too-large`, `busy`, `closing`. No method payload or event is relayed. On stop:
  `closing`, the connections that are reading shut down, a call in flight answered or CANCELLED, the
  socket unlinked, every thread joined; a `shutdown_runtime` command is answered first. `[IMPL]` The
  shell retries a `busy` refusal, which ran nothing, until its `--timeout`. DAEMON.md §7 documents the
  five items of BCP l.384.
- **Status:** decided 2026-11-15 (owner, batch E item 18: U4); built in I95, part 4b-6b
  (`daemon/ctlmodule.nim`, `daemon/ctlwire.nim`; `test_ctl_module`, `test_logosd`).

### G297 — Request keys for `module create`
- **Kind:** Choice (G-keys; the G80 redo) · **Specs:** RUNTIME l.1823-1824, l.3627-3634.
- **Decision:** only `create_module` carries a request key in Tier 4b. The shell generates one per
  command: `lcli-` and 32 hex digits from the operating system's CSPRNG (128 bits), printed with the
  result, and on stderr when the outcome is unknown. `--request-key K` repeats one, so a create whose
  answer was lost can be retried, across a daemon restart too, and returns the same instance. Two
  concurrent commands share a key only when the user names the same one.
- **Status:** built 2026-11-15 (I95, part 4b-6b; `test_ctl_module` "create_module: 16 concurrent
  commands", `test_logosd` "kill -9, then a restart").

### G298 — No remote listener, export or enrollment in Tier 4b
- **Kind:** GAP interim (K19, as approved: U3; G-remote; the G84 and G85 redo) · **Specs:** RUNTIME
  l.1626 (authorize first), l.3365-3372 (the lists), l.3438 (an export names a listener record),
  l.3441-3442, l.2830-2831 (disabled by default); SECURITY l.524.
- **Decision:** the Runtime has no listener, export or enrollment. The four methods are authorized first
  (NOT_AUTHORISED when the decision denies); then `list_remote_listeners` and `list_provider_exports`
  answer an empty page (a cursor is INVALID_PARAMS, since none was issued); `set_provider_export` is
  INVALID_PARAMS (a provider of another Runtime, or no listener record to name); `set_remote_listener` is
  MODULE_ERROR "remote transport is not supported by this Runtime", the gap's interim. `connect_remote`
  is unchanged. logosd exports nothing and opens no listener; the shell reaches its instance over the
  socket (part 4b-6b).
- **Status:** decided 2026-11-15 (owner, batch E item 18: U3); built in I95, part 4b-6a, for every host
  (`test_runtime_authority` "remote listeners and exports without remote transport", `test_routes`).
- **Amended 2026-11-15 (I95, part 4b-6c; the spec review of the 4b-6 plan):** as the owner's U3 says,
  only *enabling* a listener is MODULE_ERROR. A `set_remote_listener` with `enabled: false` assigns the
  state every listener has by default (R l.2830, l.3431 "idempotently assigns the requested listener
  state") and succeeds with the requested record. `[IMPL]` No record is kept for the default state: the
  lists stay empty, `set_provider_export` naming that listener stays INVALID_PARAMS (l.3451), and no
  `inventory_changed` hint is sent, since no list result changed (l.3418). Considered and not taken: a
  stored record for the disabled listener (the Opus check's reading), which would need listener records,
  their persistence and exports for them while no transport exists. 4b-6a answered MODULE_ERROR for
  every request; `test_runtime_authority` now covers both. The `set_provider_export` answer carries no
  detail (l.3440), as built.
- **Revised 2026-11-17 (owner, Tier 5 batch B, B8, approved as written; recorded by step 5-0):** the
  answers stay for a remote profile the build lacks: QUIC until step 5-12, and for good if area E2 is
  dropped. *No record is kept* is re-decided when step 5-7a designs listener records. The answer to a
  listener enabled without remote transport is a TF-06 remark (K19); not sent to the spec owner.

### G299 — The trust file, its mark and the development switch
- **Kind:** Choice (G-trust; the G87 redo; G137 as amended by U7; D27; decision 11) · **Specs:** PACKAGE
  MANAGER l.395-400 (continuity), BCP l.359.
- **Decision:** `<session>/trust.cbor` is one `lcn.trust_file` (format, `revision`, `development`);
  without it the compiled-in floor applies (revision 1, switch off), and a file below the floor is
  refused. `state/trust-mark.cbor` keeps the highest revision used and the BLAKE3-256 of its bytes,
  written durably before that revision is used. At start: no mark, refused ("run `logosctl trust
  reestablish --revision N`"); a higher revision, the mark written, then used; the same revision and
  digest, accepted (identical replay); the same revision with other contents, refused; a lower revision,
  refused as a rollback. logosd never creates a mark: `logosctl init` writes the file and its mark
  (revision 1, or 2 with `--development`, so revision 1 keeps the floor's one content); `trust development
  on|off` writes the next revision (off is a withdrawal); `trust reestablish --revision N` writes the mark
  from the file when the owner names its revision (S4b6-1, a Choice). Every change is offline, under the
  session lock, and applies at the next start. Tier 5 adds the package-signing anchors and claims
  PKG-0418–0421, PKG-0423 and PKG-0424.
- **Status:** decided 2026-11-15 (owner, batch E item 18: U7); built in I95, part 4b-6a
  (`daemon/trustfile.nim`; dc.trust).
- **Amended 2026-11-16 (owner: "Start 4b-8, claim 0422"):** PKG-0422 is claimed in step 4b-8 with a
  true "no" (G137's amendment of the same date; `docs/DEPLOYMENT.md` §1): the file this row decides
  holds no anchors, and a change to it applies at the next start only, so nothing running depends on
  package-signing trust. Tier 5 is expected to change the answer.

### G300 — What the development switch gates, and how test hooks are selected
- **Kind:** Choice (G-nonprod; K23, U5; E2; D27 completed) · **Specs:** BCP l.399-400 (one build;
  development trust only through protected configuration).
- **Decision:** the switch is the trust file's `development` (G299). In Tier 4b it gates an allow-all
  policy and `test_hooks`. Hook code exists only in a build with `lcnTestHooks`, and no packaged
  executable is built with it (the flake check `no-test-hooks`). A packaged logosd refuses `test_hooks`
  ("this logosd has no test hooks"); a hook build accepts it only with the switch on. logosd reads the
  switch at start, then selects the hooks by in-process calls: never an environment variable, never the
  control socket. Where the switch shows (K23, U5): logosd's start log, every `logosctl` output, and
  `docs/DAEMON.md`.
- **Status:** the gate built 2026-11-15 (I95, part 4b-6a; `config.checkGates`, dc.checks); the
  selection, the banner and the packaging check with part 4b-6b.

### G301 — logosd's call-evidence store and its export
- **Kind:** Choice (G-evstore; U6, batch E item 20; G115, G143, G149 built) · **Specs:** CA l.1169
  (retention duration and storage are deployment policy), l.1265 and l.1290 (a kid names one producer),
  l.1316-1330 (the protected export integration; what an implementation documents), l.1322 (no proof
  retained for export); IF l.397, IFC-0581 (no marked side retained); SECURITY l.402.
- **Decision:** the store is off by default (G115): with `call_audit.store` absent nothing is persisted;
  `init` still makes the key, so turning it on is one `daemon config set`. When on, logosd opens it before
  `start` and sets it as the Runtime's call record sink (G304). `offer` copies each record into shared
  memory under a short lock and never waits for the disk; seq = the store's base at open + the ring index,
  so concurrent offers keep unique, ordered seqs; past `queue` seqs after the next one to write a record
  is dropped and its seq counted. One writer thread writes at most 256 entries a batch in seq order, a gap
  entry for each run of dropped seqs, flushes to the medium after each batch and logs drops once per
  batch. Segments `state/evidence/seg-<20-digit first seq>.lcr` (`evstore.cddl`): 4-byte length-prefixed
  deterministic-CBOR entries, the first a header with the producer, the kid configured at open and the
  open's number; each open starts a segment; rotation at 10,000 entries or 16 MiB. Bounds (G143): whole
  segments, oldest first, are reaped at open and at each rotation while the store spans more than
  `max_records` seqs (default 1,000,000; dropped seqs count) or the oldest was last written more than
  `max_age_days` ago (default 30; the file's modification time); the segment being written is never
  reaped. At open the newest segment's torn or undecodable tail is cut off; a failed write closes the
  segment, and a reader stops at a damaged end. Export, `logosctl audit evidence export --seq N`, offline
  and read-only: the current key (daemon-config's, checked against its binding) signs the complete
  record, with no proofs, for the Runtime its binding names; a segment another Runtime wrote is refused,
  a seq not stored is "not retained" (exit 1); the container goes to `--out` (created `O_EXCL`, 0600) or
  to stdout when it is not a terminal, never to a terminal. `audit evidence ls` lists the segments. No
  proof ever enters the store or an export; directory 0700, segments and `--out` 0600; plaintext at rest.
  The documented limits are DAEMON.md §9's.
- **Status:** built 2026-11-15 (I95, part 4b-6c; `daemon/evstore.nim`, `daemon/evexport.nim`,
  `runtime/callaudit.nim`'s sink; `test_evidence_store`, `test_host_authority`, `test_logosd`).

### G302 — logosd's process
- **Kind:** Choice (G-logosd; E1; G249) · **Specs:** RUNTIME l.3823-3824, l.3981-3989; BCP l.372; IF
  l.395, SECURITY l.403 (the logging rule).
- **Decision:** logosd takes the session lock; blocks SIGTERM, SIGINT, SIGHUP, SIGUSR1 and SIGUSR2 for a
  `sigwait` thread and ignores SIGPIPE; then assembles and starts (DAEMON.md §3-§6). The first TERM or INT
  requests shutdown, a second logs "shutdown in progress"; HUP is logged only. The signal thread holds a
  lock around each Host API call, and the main thread sets `destroying` under it before the first destroy
  attempt; the thread is then stopped with SIGUSR2 and joined. Destroy is retried on NOT_READY for at most
  `shutdown_grace_ms` plus 5 s. Exit codes: 0 clean, 1 refused, 2 create or start failed, 3 a shutdown
  error, 4 the Module Loader failed. The log is stderr, `logosd[<pid>]: <level>: <text>`, with no payload,
  value root, ticket, key, record content or marked failure text. A Loader loss: the termination hook
  (G304) copies the unresolved instances and raises SIGUSR1; the signal thread logs them and requests
  shutdown; after the wait logosd does not destroy the Runtime, waits up to 10 s for every Module Host's
  restart lock to be free, releases the session lock and exits 4, for the service manager to restart it.
- **Status:** built 2026-11-15 (I95, part 4b-6b; `src/logosd.nim`, `daemon/assemble.nim`,
  `daemon/supervise.nim`, `daemon/logging.nim`; `test_ctl_module` "a Loader loss", `test_logosd`).
- **Amended 2026-11-15 (I95, part 4b-6c; the spec review of the 4b-6 plan):** on a Loader loss logosd no
  longer releases the session lock before it exits 4. The lock is an `flock`, which the kernel drops once
  the process is gone. Released earlier, an offline writer or a second logosd could hold the session while
  the orphaned in-process code still runs (R l.3824, l.2641). The notification is process-directed,
  `kill(getpid(), SIGUSR1)`, so the signal thread's `sigwait` takes it whichever thread the hook ran on
  (as built in 4b-6b). The hook fires only when the failed Loader leaves in-process realizations
  (`engine.loaderLost`); under logosd that is always so, since `orchestrator`, `logosctl` and, under
  capability-authority, `authority` are `direct_static`. A later change that hosts them all would switch
  this supervision off. Without a service manager nothing restarts logosd after exit 4 (DAEMON.md §15).

### G303 — The logosctl command set in Tier 4b
- **Kind:** Choice (G-cli; G88, G89, U2; D26) · **Specs:** BCP l.380-392; RUNTIME l.2665.
- **Decision:** online, through the socket: `status`, `module ls|status|summary|create|start|stop|recover|
  retire`, `route ls`, `permissions get`, `config schema|summary|get|stage|discard|apply`, `daemon stop
  [--wait]`. Offline, on the session's files, the writers under the session lock: `init`, `daemon config
  get|check|set|module-config`, `trust show|development on|off|reestablish|evidence-keys ls|rotate`.
  Values are `@FILE`: `.cbor` (checked deterministic) or `.diag` (parsed, then encoded deterministically;
  U2). `config apply` names the revision and schema it expects (`--revision N --schema` with 128 hex
  digits, or both from `get_configuration_summary`). Output: G89, with `deployment` and, where one was
  used, `request_key` in each JSON envelope; `[IMPL]` `--text` keeps text output in a pipe. Exits 0, 1, 2
  and 4; 3 has no source in Tier 4b. The Runtime id is assigned by `init` and never changed: `daemon
  config set` refuses another. `[IMPL]` `daemon config check|set` leave the test-hook build check to
  logosd, which alone knows its build.
- **Status:** built 2026-11-15 (I95, part 4b-6b; `src/logosctl.nim`, `daemon/render.nim`; `test_logosd`).

### G304 — In-process Host API additions for logosd
- **Kind:** Choice (G-hostapi) · **Specs:** RUNTIME l.3823-3824 (the host ends its process when the
  Loader failed with in-process realizations left); G249.
- **Decision:** `runtimeSetTerminationHook(rt, hook, data)` and `runtimeSetCallRecordSink(rt, …)`, for
  in-process hosts only, with no C export (as `auditRecords`; I85's stance; G249's C path unchanged).
  Each is set before `start`: NOT_READY once a start was attempted; a nil handle or procedure is
  INVALID_PARAMS. The termination hook is called once, on a Runtime thread, with the instances left
  unresolved; it must not call into the Runtime (logosd, part 4b-6b, raises a signal and ends its
  process).
- **Status:** the termination hook built 2026-11-15 (I95, part 4b-6a; `test_host` "the termination
  hook"); the record sink built 2026-11-15 (I95, part 4b-6c): `runtimeSetCallRecordSink(rt, sink, data)`
  hands each record the engine retains, with its ring index, to `sink` on the appending thread after the
  ring holds it and outside the ring's lock; the sink must not block or call into the Runtime (logosd's
  store queues it, G301). `test_host_authority` "a call record sink".

### G145 — Release form
- **Kind:** FREE · **Options offered:** (a) relocatable archives per platform (tar.gz, notarized zip, zip)
  with `$ORIGIN`/`@loader_path` rpaths, a gate against leaked `/nix/store` paths, and an install test on a
  plain Ubuntu image; published as GitHub release assets *(recommended)*; (b) Nix-only installation.
- **Decision:** (a).

### G146 — Service management
- **Kind:** FREE · **Options offered:** (a) ship a systemd unit and a launchd plist; `logosd` gets a
  Windows service mode; module-host stderr forwarded into logosd's log; a systemd VM test
  *(recommended)*; (b) the same, but Windows via a wrapper such as NSSM. **Decision:** (a).
- **Built 2026-11-15 (I95, part 4b-6b):** `contrib/systemd/logosd.service` (a user unit) and
  `contrib/launchd/org.logos-core.logosd.plist` (a user agent) ship; both restart logosd after exit 4.
  Module Hosts inherit logosd's stderr, so their output is in its log. The systemd VM test and the
  Windows service mode come with the release work.

### G309 — How a BCP §5.4 unit is labelled from the deployment document
- **Kind:** Reading, then Choice (owner, batch G item 22) · **Specs:** BCP §5.4 l.355-356 ("A complete
  deployment MUST document every applicable choice that the Core specifications assign to deployment";
  "At minimum, that documentation MUST identify:"), l.358-401 (the items), l.403-405.
- **Description:** each §5.4 unit is a duty to document a choice. Where a deployment has no subject for
  an item (no Package Manager, no remote transport, no approval presentation), the true answer is *none*
  or *not supported*, and whether a true *none* meets the duty is not stated (TF-43 point 4).
- **Decision (owner, batch G item 22, 2026-11-15):** one rule for every BCP §5.4 unit. It is claimed by
  inspection when `docs/DEPLOYMENT.md` answers every part of its item truthfully, *none* included. The
  inspection reason lists the parts answered *none* or *not supported* and the tier expected to change
  them. The document's Verdict column (Supported, None, Not supported) describes the deployment and does
  not decide labels; its "Changes in" column names that tier. All 36 gated §5.4 units are claimed: 26 by
  step 4b-8, 10 by step 4b-6 (I95). An item answered by describing a mechanism is no *none*: BCP-0077 is
  answered by the attribute-source integration (G47).
- **Status:** decided 2026-11-15; recorded 2026-11-16 (I97, part 4b-8a) before `spectrace deploydoc`,
  which encodes it (part 4b-8b). Behind it is TF-43 point 4, in the comments document; not sent to the
  spec owner.

### G310 — Which deployments BCP §5.1 and §5.4 bind
- **Kind:** GAP, interim (S4b8-1, with K18 and K50) · **Specs:** BCP l.123, l.282-283, l.287-290, l.340,
  l.355-358; RUNTIME l.253, l.1378, l.1641.
- **Description:** what a complete Logos module system contains is not stated, nor whether BCP l.288-290
  binds only a deployment claiming complete-system conformance or every Runtime with a bound Module
  Loader, nor whether §5.4 binds a deployment that claims the lower specifications alone (TF-43 points
  1 to 3).
- **Decision (interim; owner decision 10 (a), 2026-11-13):** TF-43's reading. logosd makes no
  complete-system claim, since it deploys no Package Manager. It follows BCP l.288-290 because it binds
  a Module Loader, and it publishes the §5.4 document (`docs/DEPLOYMENT.md`) as a deployment that owes
  it would, answering an item with no subject *none* (G309). Units it meets are claimed one by one
  (I97's met-unit rule): BCP-0021 to BCP-0024. CONFORMANCE's "Properties not claimed" names the
  complete system.
- **Status:** interim, recorded 2026-11-16 (I97, part 4b-8a). TF-43 is in the comments document; not
  sent to the spec owner. If the answer limits l.288-290 or §5.4 to a claiming deployment, the units
  stay claimed: they are met.

### G311 — The reach of "for package-backed module creation" in BCP l.367
- **Kind:** Reading (S4b8-2; a TF-06 editorial entry) · **Specs:** BCP l.367 ("accepted-declaration
  selection and exact package/version pinning for package-backed module creation"); RUNTIME l.3614,
  l.3616.
- **Decision:** the qualifier binds pinning only. Accepted-declaration selection is documented for every
  module (DEPLOYMENT.md row 10a: G55's host-configured declarations); exact package/version pinning is
  answered *none*, since nothing creates a package-backed module before Tier 5 (row 10b).
- **Status:** decided 2026-11-16 (I97, part 4b-8a); the TF-06 entry is in the comments document; not
  sent to the spec owner. Either reading leaves BCP-0076 claimed under G309.

### G312 — Loader strategies and hosted placements are not Core profiles
- **Kind:** Reading (K49; a TF-06 editorial entry) · **Specs:** BCP l.296 (a named Core profile),
  l.310, l.344, l.420, §5.3's matrix; LOADER l.377 (`unsupported-strategy`), l.621, l.628.
- **Decision:** Loader strategies and hosted placements are not Core profiles: they are absent from
  §5.3's matrix and from the identifier list, and LOADER's own rules govern them: one that is not
  advertised is `unsupported-strategy` (L l.377), which permits the Runtime to select another advertised
  one (l.621; this Runtime never does, test S-6 [LDR-0067]), and one whose controls cannot be
  established is `realization-failed` (l.628). BCP-0028,
  BCP-0036 and BCP-0063 are evidenced by Core profile selections and identifiers (the local transport
  profile, the hash profile, call evidence); placement refusals support them by analogy only.
- **Status:** decided 2026-11-16 (I97, part 4b-8a); the TF-06 entry is in the comments document; not
  sent to the spec owner.

### G352 — BCP l.266 labels `tls-tcp` mandatory without the condition of l.336 (K22)
- **Kind:** Reading (K22; a TF-06 remark) · **Specs:** BCP l.266 (the identifier table: "Mandatory
  remote transport | `logos.remote.tls-tcp`"), l.336 ("Mandatory for an implementation supporting
  production remote Runtime transport").
- **Decision:** l.336 governs: `tls-tcp` binds an implementation that supports production remote
  Runtime transport. No claim made at `3c6f3c3` needs it, and logosd offers no remote transport (G298;
  `docs/DEPLOYMENT.md` row 4b). Remote transport is in Tier 5's scope by G125 (b) and the conformance
  goal (Tier 5 plan A1), not by l.266.
- **Status:** decided 2026-11-17 by step 5-0 (a reading; no code); in the comments document as a TF-06
  remark; not sent to the spec owner.

---

## 11. Payload and dependency modules

### G97 — Today's lifecycle and configuration methods
- **Kind:** FREE · **Specs:** INTERFACE §1.4 (contract content is the author's); CONFIG; RUNTIME §3.4.
- **Description:** With Core lifecycle and Core configuration (D21), methods such as storage
  init/start/stop, delivery createNode/start/stop and blockchain start/stop/generate_user_config overlap
  Core mechanisms.
- **Options offered:** (a) map them onto Core lifecycle/configuration and drop them; keep everything
  else 1:1 *(recommended)*; (b) keep everything 1:1. **Decision:** (b): they act on the module's inner
  node inside a ready instance; Core lifecycle stays authoritative; any state they write goes to
  state_dir. Methods depending on the inner node return a typed `not-started` arm before it starts
  (RUNTIME §3.4 l.618-633 forbids NOT_READY for application state).

### G98 — Delivery's RLN and service-discovery dependencies
- **Kind:** FREE · **Specs:** RUNTIME §7.5 (module-to-module calls only through Runtime routes).
- **Description:** Delivery reaches `liblogos_rln_module` and `libp2p_module` today through old-SDK
  clients, which is not a spec path.
- **Options offered:** (a) disable both in v1 *(recommended)*; (b) port both modules now as spec modules;
  (c) link them into delivery. **Decision:** (b).

### G101 — Location of the RLN modules
- **Kind:** FREE · **Options offered:** (a) fork `logos-co/logos-rln-modules` (Rust; no push access) as
  `dlipicar/logos-rln-modules` *(recommended)*; (b) fork vacp2p/zerokit. **Decision:** (a): Rust crates
  `lez_rln_module` (registry provider) and `rln_module` (membership) exporting the C ABI.

### G102 — Location of the libp2p module
- **Kind:** FREE · **Options offered:** (a) a fork of nim-libp2p (now iftech/nim-libp2p; no push access)
  *(recommended)*; (b) a branch of `logos-co/logos-libp2p-module`. **Decision:** (a): `dlipicar/nim-libp2p`.

### G103 — Platforms of the RLN and libp2p modules
- **Kind:** FREE · **Options offered:** (a) follow delivery's six platforms where feasible
  *(recommended)*; (b) Linux + macOS only. **Decision:** (b); delivery on Windows/Android/iOS runs without
  RLN and discovery.

### G104 — LEZ chain for RLN in CI
- **Kind:** FREE · **Options offered:** (a) a local LEZ sequencer in CI *(recommended)*; (b) a mocked
  registry. **Decision:** (a).

### G142 — Delivery's dependency packaging and start order
- **Kind:** FREE · **Specs:** PM Scope l.112 (no optional, alternative or feature-selected dependencies),
  §11 (dependencies apply to every platform variant); RUNTIME §3.7 (startup order never inferred from
  package dependencies; ordering constraints come from host/deployment).
- **Options offered:** (a) delivery_module declares no package dependencies; the dependency modules are
  installed explicitly on Linux/macOS; the daemon config carries ordering constraints lez_rln -> rln ->
  delivery and libp2p -> delivery (startup, resume, reverse at shutdown) *(recommended)*; (b) separate
  delivery packages per platform. **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** PM-15: dependencies are unconditional across variants (PM §11 l.1221-1223). Matches.
- **Built 2026-11-13 (I94, part 4b-5b):** the start order reaches orchestration as the reference module's
  `ordering`, the same pairs as the host configuration's (G287).

### G99 — Host paths in method arguments
- **Kind:** FREE · **Specs:** CONFIG §6 l.197 (no implementation-specific configuration-file path at the
  configuration boundary); RUNTIME §12 l.3304 (co-located modules may exchange paths); D21.
- **Options offered:** (a) absolute paths allowed; relative paths are a domain error; never resolved
  against cwd *(recommended)*; (b) bytes only. **Decision:** (a).
- **Revised 2026-11-11 (review against 6a4dfa28, item A9):** the cited RUNTIME l.3304 ("co-located
  modules may exchange paths") is gone. RUNTIME l.3910: a filesystem path does not grant access or
  guarantee visibility in another module's realization; l.3917-3918: "Co-location alone does not
  establish a shared filesystem namespace", and a contract accepting a path MUST define whose namespace it
  addresses and the failure when that namespace or access is unavailable; l.3919: no silent
  reinterpretation in another execution form. (a) defines neither the namespace nor the failure. It can
  stay only if every payload contract that takes a path states both, with a typed failure; otherwise (b)
  or the bounded-value, chunked or reference forms of l.3920 apply. **Needs an owner decision** (review
  item A9).
- **Re-decided 2026-11-11 (owner: "Accept all", after the Fable 5.2 session's review of the recommendations, item A9):** decided per contract when the payload modules are ported.
  Each payload contract that takes a path defines whose namespace it addresses and the typed failure when
  that namespace or access is unavailable (RUNTIME l.3917-3918), or it takes bytes or one of the
  bounded-value, chunked or reference forms (l.3920). (a) stands only where a contract states both.

### G100 — Methods that can exceed the 30 s call timeout
- **Kind:** FREE · **Specs:** G61.
- **Options offered:** (a) return `{session_id}` and finish with a `*_done_event`; all other methods have a
  module-side deadline and a typed `timed-out` outcome *(recommended)*; (b) synchronous with longer
  per-method timeouts. **Decision:** (a).
- **Revised 2026-11-11 (review against 6a4dfa28, item A10):** (a) follows the old TRANSPORT §5.3
  "Async Operations Pattern". §5.3 is now "Long-Running Operations": one delayed result is one Request
  and its eventual final Response, with no acknowledgement method, job identifier or event subscription
  needed (TRANSPORT l.841-843); a contract MUST NOT make a provider-generated identifier that is only in
  the final Response the sole means of recognizing an earlier event (l.848), and an event may arrive
  before the caller's submission returns (l.847); a contract may instead define a resource with start,
  inspect, read or cancel methods, whose later invocation-scoped events need another active invocation
  such as a watch (l.851-853); an event is not a substitute for a final Response (l.858). Callers choose
  their own per-call timeout, and without one the call has no caller-selected deadline (INTERFACE l.2059,
  l.2061). (a) breaches l.848 if a `*_done_event` keyed only by the returned `session_id` can precede
  that response. Choices: a delayed Response with invocation-scoped progress events, or (a) recast as a
  resource with a caller-chosen correlation value or a watch method. The "30 s call timeout" premise
  also depends on G61 (A18). **Needs an owner decision** (review item A10).
- **Re-decided 2026-11-11 (owner: "Accept all", after the Fable 5.2 session's review of the recommendations, item A10):** the default is a delayed Response: one Request and its
  eventual final Response (TRANSPORT l.841-843), with invocation-scoped progress events. An operation that
  should outlive the caller or the connection uses the resource shape of l.851-855 instead: its start
  method returns the id as its final Response, and a watch method carries the progress events. With it:
  the caller subscribes before submitting, through the same handle (RUNTIME l.1268); concurrent calls
  carry a caller-chosen correlation value in request and events (l.1271-1272); publisher and subscriber
  need event authority (l.1261-1263; G140); the provider holds a thread for the duration or exports
  `_MODULE_async_api` (INTERFACE l.2106), which the kit does not build yet; and a lost connection ends the
  call with TRANSPORT_ERROR and an unknown outcome (TRANSPORT l.995). The "30 s call timeout" premise is
  gone (G61).

### G111 — A second live instance in one process
- **Kind:** FREE · **Specs:** INTERFACE §2.6 l.1266-1268 (a binding MAY be initialized more than once;
  only successful inits are constrained), §2.8.
- **Options offered:** (a) refuse with LOGOS_ERR_MODULE, null context, no leak *(recommended)*; (b)
  support multiple instances. **Decision:** (a).

### G136 — Storage start blocking on DHT bootstrap
- **Kind:** FREE · **Description:** storage's `start()` awaits the network bootstrap (up to minutes),
  which would stall readiness and the Package Manager behind the ordering constraint.
- **Options offered:** (a) split start in our storage branch into a listening phase (`_init` returns) and
  a network phase (typed status) *(recommended)*; (b) accept a long init with a larger timeout.
- **Decision:** (a); the Package Manager waits on `dht_ready` over its `lcn.storage_fetch` route.
- **Note 2026-11-17 (step 5-0; Tier 5 plan §8):** G91's contract has no such signal yet; Tier 5 step
  5-3a adds one when it defines the contract, and N-4 builds the two phases in storage_module.

### G138 — Payload module names
- **Kind:** FREE · **Specs:** RUNTIME §1.3 (flat, unreserved names).
- **Options offered:** (a) keep `blockchain_module`, `storage_module`, `delivery_module`, `libp2p_module`,
  `rln_module`, `lez_rln_module` *(recommended)*; (b) drop the `_module` suffix. **Decision:** (a).

### G144 — Blockchain setup replacing peers.json and generate_user_config
- **Kind:** FREE · **Options offered:** (a) the keystore is created in state_dir at the first `_init` when
  absent and never overwritten; network, initial peers (package default = current testnet list), ports
  and a loopback API live in Core configuration; devnet genesis from an e2e fixture; keystore backup
  documented; `generate_user_config` kept as a method *(recommended)*; (b) keys only through the method.
- **Decision:** (a).

### G147 — Storage mix (private downloads)
- **Kind:** FREE · **Options offered:** (a) typed mix configuration (enabled, pool, SPRs inline);
  `toggle_private_queries` kept; a loopback mix private download in the offline e2e; the mix bootstrap
  data recorded as an external dependency *(recommended)*; (b) mix exercised only in the live run.
- **Decision:** (a).

### G148 — Exercising the dependency modules end to end
- **Kind:** FREE · **Options offered:** (a) offline on Linux/macOS: all six modules ready, delivery
  discovery through libp2p_module, an RLN-enabled round trip against the local LEZ sequencer; live:
  libp2p active, rln/lez_rln installed but idle under the logos.test preset *(recommended)*; (b) also
  enable RLN in the live run. **Decision:** (a).

---

## 12. Platforms, build, CI and tooling

### G105 — System modules and conformance on Android/iOS
- **Kind:** FREE · **Specs:** BCP §5.1; RUNTIME §5.2.
- **Options offered:** (a) the same set as desktop (Loader, orchestrator, CA, PM refusing executable
  installs) direct_static, complete-system claim *(recommended)*; (b) runtime + modules only, individual
  spec claims. **Decision:** (a).
- **Revised 2026-11-16 (Tier 5 plan A6, step 5-4):** moved to M12's plan, with the Android and iOS legs
  (R6). The decision stands for M12. Until then the complete-system claim is desktop only: Tier 5's E1
  claims it for logosd on Linux and macOS.

### G106 — Several Nim runtimes in one mobile app
- **Kind:** FREE · **Specs:** RUNTIME §2.3; SECURITY §11.4, §11.5 ("statically linked or bundled").
- **Options offered:** (a) each module bundled as its own `.so` / embedded `.framework`, registered as
  direct_static, with an early spike *(recommended)*; (b) prelinked static archives with localized
  symbols. **Decision:** (a).

### G125 — Remote transport on Android/iOS
- **Kind:** FREE · **Specs:** BCP §5.3.
- **Options offered:** (a) not claimed in v1; BoringSSL/lsquic compiled out on mobile *(recommended)*;
  (b) claimed on mobile too. **Decision:** (b).
- **Revised 2026-11-16 (Tier 5 plan A6, step 5-4):** the mobile half moves to M12's plan, with the
  Android and iOS legs (R6). The decision stands, and it remains one reason why remote transport (Tier 5
  area F) and the complete-system claim (E1) are in Tier 5's scope, beside the conformance goal (RUNTIME
  l.49-50; BCP l.336; INTERFACE l.24; Tier 5 plan A1). Tier 5 builds and claims them on the desktop legs;
  M12 adds mobile.

### G112 — macOS signing
- **Kind:** FREE · **Specs:** SECURITY §11.2 (the deployment states its posture).
- **Options offered:** (a) Developer ID + notarization, hardened runtime with `disable-library-validation`
  (Logos package signing is the admission control) *(recommended)*; (b) ad-hoc, dev only.
- **Decision:** (a). Needs an org Apple Developer ID.

### G109 — Prefix for our own CDDL rule names
- **Kind:** FREE · **Specs:** INTERFACE §1.3 (`logos.`, `logos-`, `logos_` reserved).
- **Options offered:** (a) `lcn.` *(recommended)*; (b) `core_nim.`; (c) ask for a reserved sub-namespace.
- **Decision:** (a); identifier strings use `logos-core-nim.`.

### G123 — CI blocking policy
- **Options offered:** (a) library suites block on all 6 platforms from the start; integration suites
  block on Linux/macOS from their milestone and on Windows/Android/iOS from the platform milestone
  *(recommended)*; (b) every suite blocks on every platform from its milestone. **Decision:** (a).
- **Revised 2026-11-16 (R6, step 5-4):** the library suites block on Linux, macOS and Windows, **orc only
  on Windows** (`nimble test`; refc runs on Linux and macOS in both jobs, G334). The Windows leg blocks
  once a run on master is green; until then its job has `continue-on-error`. The Android and iOS legs,
  and the integration suites on Windows, come with M12.

### G334 — The Windows CI leg
- **Kind:** FREE (Tier 5 plan A6, R6) · **Specs:** none for the leg; TRANSPORT §8.2.1 l.1170 for the
  probes' facts (G107).
- **Decision (step 5-4, under A6):** a third CI job, `windows`, on the Nimble path, since there is no Nix
  on Windows.
  - **Steps:** every step is `tools/ci/windows.ps1` (`toolchain`, `setup`, `test`, `probe`), the same under
    Windows PowerShell 5.1 and PowerShell 7, so a Windows machine runs the job's commands by hand and the
    repositories split from this one can reuse it.
  - **Toolchain:** nim-lang.org's `nim-2.2.14_x64.zip` (with nimble 0.26.2) and `mingw64.7z` (MinGW-w64
    gcc 11.1.0, the one choosenim installs), pinned by SHA-256 in the script and checked after a download
    and after a cache hit. No nasm: BLAKE3's assembly goes through gcc, and BoringSSL builds without
    assembly on Windows for now (step 5-2). The archives and the locked dependencies are cached, so the leg
    does not depend on a download.
  - **Coverage:** every library suite under orc on `windows-2025` (a pinned image), in four shards by
    `LCN_SHARD` (all 77 suites took 161 minutes on winvm.lan's two vCPUs, at most 48 per shard); the hosted and transport suites compile and skip (G107). refc stays on Linux and macOS.
  - **Probes** (`tools/winprobe`, G107): on the first shard and alone on `windows-2022`, never failing
    the job. Each run compares its facts with the committed ones for that build and reports a difference
    in the job summary, since a pinned image still takes servicing updates.
  - **Blocking:** the job has `continue-on-error` until a run on master is green; then it blocks for the
    library suites (G123 as revised).
- **Status:** built on branch `step5-4` and proven step by step on winvm.lan (I100). Trial run
  44077261405 (2026-11-17, `windows_only`, on `757dd39`): every job green; the four shards took 14 to 26
  minutes, the probes alone 1.5. Blocking after a green run on master (5-4c).

### G124 — Android aarch64
- **Options offered:** (a) tests on the x86_64 emulator, aarch64 built and statically checked
  *(recommended)*; (b) an external arm64 device service. **Decision:** (a).

### G126 — Windows ABI
- **Options offered:** (a) MinGW only, MSVC unclaimed *(recommended)*; (b) also test MSVC.
- **Owner's answer:** "mingw only, evaluate using https://github.com/mstorsjo/llvm-mingw/".
- **Decision:** MinGW only; llvm-mingw evaluated in the first milestone.

### G127 — Automation when the spec head moves
- **Options offered:** (a) a daily job opens or updates a triage issue; a working session commits as the
  project's author in a draft PR; no bot commits *(recommended)*; (b) the job opens a bot-authored draft
  PR. **Decision:** (a).

### G128 — Independent TLS/QUIC test peers
- **Options offered:** (a) pyOpenSSL + aioquic, test-only *(recommended)*; (b) test our stack against
  itself. **Decision:** (a).

### G129 — Peer-identity mismatch tests
- **Kind:** FREE · **Specs:** TRANSPORT §8.2.
- **Options offered:** (a) a privileged CI step creating a throwaway second OS user *(recommended)*;
  (b) unit-test the check with mocked credentials. **Decision:** (a).
- **Built (I83):** the `[TRN-0190] [G129]` test in `test_transport_io` (`tests/transport_io_body.nim` since I100), run by CI's
  `nimble` job on Linux in the step "Peer check against another user's listener (G129)"; skipped
  unless `LCN_PEER_USER` is set and `sudo` is installed.

### G130 — Where payload conformance runs
- **Options offered:** (a) logos-core-nim runs the artifact harness, cross-mode and schema suites against
  pinned library branches; each library repo keeps functional tests and runs the harness on its PRs
  *(recommended)*; (b) library repos only. **Decision:** (a).

### G131 — Relation to logos-workspace
- **Options offered:** (a) add all new repos as workspace submodules with a `core-nim` group
  *(recommended)*; (b) only logos-core-nim.
- **Owner's answer:** "no, let's drop logos-workspace, just do independent repos". **Decision:** all
  repos independent (revises D3).

### G132 — CI binary cache
- **Options offered:** (a) logos-co Attic via setup-nix-cache-action *(recommended)*; (b) Cachix;
  (c) GitHub Actions cache. **Decision:** (a); the owner adds the Attic tokens.

### G133 — Where bundles and the end-to-end tests are built
- **Options offered:** (a) an `e2e/` subflake in logos-core-nim (library repos depend on the core, so
  the root flake cannot depend on them) *(recommended)*; (b) a separate release repo. **Decision:** (a).

### G134 — Core technology stack
- **Options offered:** (a) Nim 2.2.x ORC; chronos; our own strict CBOR codec; BLAKE3 C from a pinned
  input; BoringSSL + lsquic; unittest2; nph; Results, no exceptions across the ABI *(recommended)*;
  (b) change something. **Decision:** (a); chronos forked for Windows AF_UNIX if needed (G107).

### G135 — Ed25519 implementation
- **Kind:** FREE · **Specs:** G42 (verification semantics).
- **Options offered (first):** (a) libsodium's Ed25519 sources from a pinned release compiled in
  *(recommended)*; (b) system libsodium per target; (c) BoringSSL + our own checks. The owner asked for
  the consequences of system vs compiled-in libsodium, then said: "I'm leaning towards BoringSSL, what are
  the canonical/small-order checks?" Answer given: S < L (already in BoringSSL, pinned by a test); A
  canonically encoded; A and R not small-order (libsodium's blocklist); cofactorless byte comparison.
- **Follow-up options:** (a) BoringSSL + those checks, validated with Wycheproof and the EdDSA edge-case
  suite, asserted equal to libsodium's verdicts *(recommended)*; (b) pinned libsodium compiled in.
- **Decision:** (a).
- **Revised 2026-11-10 (6a4dfa28):** Superseded by PM-06; nothing in 6a4dfa28 uses Ed25519. `crypto/ed25519.nim` stays only until R4 is decided, then goes with its tests, oracle files and the Android runner's vector push.
- **Removed 2026-11-10 (I68):** `crypto/ed25519.nim`, `tests/test_ed25519.nim`, `oracle/ed25519.py`, `oracle/gen_ed25519_vectors.py`, `tests/vectors/ed25519/` and the Android runner's BoringSSL vector push are gone.

### G116 — Live-acceptance host and persistent testnet seeder
- **Kind:** FREE · **Specs:** none (operational).
- **Description:** The live run needs a host with a public IPv4 address, an ADX-capable x86_64 CPU (the
  blockchain node dies with signal 4 without it) and open ports; publishing packages and the catalog to
  Logos Storage needs an always-on seeding node, since a CI runner's node disappears when the job ends.
- **Options offered:** (a) an org-provided VM, with the Storage team or infra running the seeder; owners
  and dates recorded as entry criteria *(recommended)*; (b) framework.lan, if it gets a public IP and port
  forwarding; (c) decide later.
### G340 — A library leaves its host's signal dispositions alone
- **Kind:** Choice [IMPL] · **Specs:** none; RUNTIME §13 (a host embeds `liblogos_runtime`) and
  INTERFACE §2.6 (a module library is loaded into a host's process).
- **Decision:** every library built here is compiled with `-d:noSignalHandler`: `liblogos_runtime`
  (a compile-time error without it; `nimble build_runtime_lib`, `tests/support/hostbuild.nim`) and the
  kit's module libraries (`tests/support/kitbuild.nim`); `base/libvisibility`, which both import, warns
  when a library is built without it. Otherwise a Nim library's `NimMain` sets handlers for SIGINT,
  SIGSEGV, SIGABRT, SIGFPE, SIGILL and SIGBUS and ignores SIGPIPE for the whole process when it is
  loaded (`system/excpt.nim`, `registerSignalHandler`), replacing the host's. chronos ignores SIGPIPE in
  its own module initializer (`asyncengine.globalInit`); `liblogos_runtime` imports `base/hostsignals`
  before anything that imports chronos, which records SIGPIPE's disposition, and restores it last in its
  initializer. The Runtime's socket writes do not need SIGPIPE ignored (`MSG_NOSIGNAL`, `SO_NOSIGPIPE`,
  `transport/io/sock.c`). A crash inside a library is the host's to report. The programs keep Nim's
  handlers and set their own dispositions: logosd (a signal thread over blocked SIGTERM, SIGINT,
  SIGHUP, SIGUSR1 and SIGUSR2; SIGPIPE ignored; `docs/DAEMON.md` §13), `logos-module-host` (SIGPIPE
  ignored, `host/main.nim`), logosctl, lcn-gen and lcn-pkg (Nim's handlers: a stack trace on a crash).
  A module repository builds its module library with the switch too (the kit's guide, TIER5-PLAN N-1).
- **Test:** `tests/test_host_dylib.nim` "[DECISIONS G340] loading the library leaves the host's SIGINT,
  SIGSEGV and SIGPIPE dispositions as they were": a sentinel handler on each before the load, compared
  after it. It fails without the switch (all three) and without the restore (SIGPIPE). POSIX only.
- **Status:** decided 2026-11-16 by the planning session (N-1 sub-part 1; I101); not a spec matter.

### G341 — The kit's toolchain range, switches, export lists and packaging
- **Kind:** Choice [IMPL] · **Specs:** INTERFACE §2.4, §2.6 (the symbols a module exports);
  TIER5-PLAN N-1.
- **Export lists.** `lcn-gen kit` also writes `<header>_kit.exports` (ld64 `-exported_symbols_list`)
  and `<header>_kit.map` (a GNU version script, `local: *`) from the template's own symbol table
  (`kitgen.kitSymbols`): `_MODULE_name`, `_init`, `_destroy`, `_apply_configuration` when live,
  `_call_surface`, `_free`, `_dispatch` and every typed `_CALL_` function. A library linked with them
  exports its ABI and nothing else: not its `NimMain`, not the C functions it carries that mark
  themselves for export (BLAKE3's here; BoringSSL's or a Rust staticlib's in a port), so two modules in
  one process cannot bind each other's copies. The lists of the meter, sensor, shapes and tuner kits are
  under `tests/generated/` (drift-checked by `test_nimgen`); `buildKitLibrary(…, exports = kit)` links
  with them and `test_kit_dylib` checks through `dlsym` that every listed symbol is found and the
  library's `NimMain` and BLAKE3's functions are not. A Windows DLL exports only what it marks; no list.
- **Toolchain range** (measured on the Mac, N-1 sub-part 1). Kit libraries built by Nim 2.2.4
  (nixpkgs at our pin, without the overlay) beside a 2.2.14 Runtime and Module Host: refc libraries pass
  `test_kit_dylib` and `run.mixed`; orc libraries pass `run.mixed` but crash in `test_kit_dylib`'s
  "calls from threads the library's runtime has not seen", where a context made on one foreign thread is
  destroyed on another after the first has exited. Before Nim 2.2.12 a chunk's owner is the allocating
  thread's thread-local region, which goes with that thread; 2.2.12 pools region handles (reproduced
  alone with a library of two procedures: 2.2.4 crashes, 2.2.14 does not; not a bug to report). And
  Nim#25992 (refc) reproduces on 2.2.4 with its own repro. So the floor is Nim 2.2.14 for refc kit
  libraries (2.2.6 to 2.2.12 not checked) and 2.2.12 for orc ones; `results` 0.5.x. The kit compiles
  under logos-storage-nim's switches (`--styleCheck:usages`, `--styleCheck:error`, `--fieldChecks:on`,
  `ProveField` as an error, `-d:nimTypeNames`, `-d:metrics`, `--tlsEmulation:off`, `-d:release`,
  `--legacy:procParamTypeBackendAliases` from 2.2.12) and logos-delivery's library switches
  (`--deepcopy:on`, `-d:nimOldCaseObjects`, `-d:nimTypeNames`, `-d:metrics`), with `--mm:refc` and
  `-d:noSignalHandler`, under 2.2.4 and 2.2.14. `base/perthread` wraps `GC_fullCollect` in
  `{.cast(raises: []).}`: 2.2.4 does not mark it `raises: []`. `LCN_KIT_NIM=<nim>` builds the test kit
  libraries with another compiler, under `build/kit-dylib/<mm>-nim<version>/`.
- **Packaging:** module repositories take the kit as a nimble dependency (owner, 2026-11-16); its
  package is shaped by the repository split plan.
- **Status:** export lists and the Mac toolchain probe built 2026-11-16 (I101, N-1 sub-part 1). Linux
  and the `kit-toolchains` check wait for framework.lan and the split plan.

### G342 — Modules built with the other memory manager
- **Kind:** Choice [IMPL] · **Specs:** INTERFACE §2.6-§2.8; TIER5-PLAN §7 A7.
- **Decision:** a module library may use either memory manager beside an orc or refc Runtime and Module
  Host: each library runs its own Nim runtime (`--nimMainPrefix`), and only C data crosses the ABI. A
  refc kit module without the confined mode keeps I71's limit (handlers on other threads must not store
  GC'd values). Measured by `test_hosted_routes`' `run.mixed` suite, whose libraries are built with the
  other manager than the suite (`kitbuild.otherMm`): M-1 a hosted meter (sessions, a held call, a
  caller, instance-wide and scoped events, an event published from a thread the module made, channel
  25), a hosted deferred provider, stop and restart; M-2 `direct_dynamic` in process, 8 threads × 50
  reads on their own handles, events delivered on the module's thread, a second instance; M-3 a hosted
  mixed consumer calling a hosted mixed provider.
- **Result:** passes on the Mac under orc (refc modules), refc (orc modules, the inverse pairing),
  orc-release, ASan and TSan, and in the orc and refc variants with modules built by Nim 2.2.4 (G341).
  A7's refc host flavour is not needed so far. Linux waits for framework.lan.
- **Limits** (accepted by the planning session, 2026-11-16): a refc library is built without the
  sanitizer, beside a sanitized host: refc's conservative stack scan does not see what AddressSanitizer
  moves to its fake stacks, and a refc build under `-d:asan` fails on its own (UBSan: a cell with no
  type in `gc_common.prepareDealloc`, with no other manager in the process). The mixed cases are
  skipped under MemorySanitizer, where the uninstrumented library's writes read as uninitialized (as
  I77's skip list; recorded beside it in `flake.nix`).
- **Status:** the reduced form built 2026-11-16 (I101, N-1 sub-part 1); the widened test (confined
  mode, logosd, foreign threads) follows with sub-parts 3 and 6.

- **Decision:** (c). **Status:** OPEN.

---

### G317 — The reverse mapper's input set
- **Kind:** IMPL (gaps Q1, Q4; reading Q6) · **Specs:** INTERFACE §3 · **Plan:** `tier5-plans/step5-1-reverse-mapper.md` §4.1. Section and Q numbers below are the plan's; `l.` cites are INTERFACE.
- **Decision.** Plan §3.2 and §3.3. `<stdbool.h>`, `<stddef.h>` and `<stdint.h>` are the only angle includes, the ones `logos_types.h` includes (IF l.3432-3434). `"logos_types.h"` is the only fixed include and is optional (Q6: l.2335, l.2217-2219, l.2640); redeclaring a fixed common type is rejected. An include cycle is rejected, which is stricter than l.2297. A file-level include guard may enclose declarations and the fixed and standard includes, never a contract-header include, a check or a document guard (l.2325). Comments-document remarks 1 (`65d614be`)
- **Status.** Built in 5-1a (`cinput.nim`, `cparse.nim`, `creject.nim`).

### G318 — The reverse mapper's groups and selection
- **Kind:** IMPL (gaps Q2, Q5) · **Specs:** INTERFACE §3 · **Plan:** `tier5-plans/step5-1-reverse-mapper.md` §4.1. Section and Q numbers below are the plan's; `l.` cites are INTERFACE.
- **Decision.** A group is complete within one header body (Q5; l.2303, l.2313). `--module` and `--subject` select. The reconstruction input is the subject's groups, the supporting groups it references and the groups reached through its contract-header includes; a group merely present is another document, validated only (Q2, l.2325, l.2970). IFC-0801/0802, 0828 and 0830 apply within the reconstruction input. Inference without a role constant needs the whole supplied set to hold one non-common group (l.2337). Comments-document remark 2 (`65d614be`, sharpened in `751b969b`). A header that holds two documents and a dependency include that only one of them references can be reconstructed as a module, or with the referencing document as the subject, and not with the other (l.2282, l.2385); the rejection names the document that references the group
- **Status.** Built in 5-1b (`rmap.nim`); the diagnostic in 5-1c.

### G319 — What "canonical" compares in the reverse direction
- **Kind:** IMPL (reading Q3) · **Specs:** INTERFACE §3 · **Plan:** `tier5-plans/step5-1-reverse-mapper.md` §4.1. Section and Q numbers below are the plan's; `l.` cites are INTERFACE.
- **Decision.** The §3.8 comparison: the allowed variations, including a forward typedef folded into its definition (l.892), identical repeats in one body (l.2376) and provider symbols on a non-provider; a metadata constant that `H'` lacks is rejected as `rkRestatedFact` (l.636, l.2214, l.2224); declare-before-use applied to input, as our choice (l.891, l.2208); "identical artifacts" read as model, canonical representation and CBOR, not CDDL text (Q3; l.23, l.31, l.2634)
- **Status.** Built in 5-1b (`rmap.nim`, `creject.nim`).

### G320 — CDDL emission
- **Kind:** IMPL · **Specs:** INTERFACE §3 · **Plan:** `tier5-plans/step5-1-reverse-mapper.md` §4.1. Section and Q numbers below are the plan's; `l.` cites are INTERFACE.
- **Decision.** Layout and file naming; RFC 8610 Appendix D and Logos prelude names and the value keywords as field names are quoted; other field names stay bare (built, `d8bcb89`)
- **Status.** Built (`cddl/emit.nim`, `d8bcb89`).

### G321 — `lcn-gen cddl`
- **Kind:** IMPL · **Specs:** INTERFACE §3 · **Plan:** `tier5-plans/step5-1-reverse-mapper.md` §4.1. Section and Q numbers below are the plan's; `l.` cites are INTERFACE.
- **Decision.** Usage, outputs, the binding summary, `--header`, nothing written on failure, and the limits of §3.10: 1 MiB per header, 8 MiB and 1,024 headers per input set, include depth 64, parenthesis depth 64 inside a literal, and the §5.3 limits on what is reconstructed. **Consequence of the 1 MiB limit:** these limits apply to the header, while §5.3 bounds the schema, so the header generated for a document within §5.3 can pass 1 MiB and is then refused explicitly (`rkLimit`; IF l.881-882). A map of 32,767 list fields is such a document (T9.5). The limit is a documented limit of the tool, not a bound on what the forward generator can write
- **Status.** Built: the input limits in 5-1a, the command in 5-1c (`src/lcn_gen.nim`; tests T9.1 to T9.5).

### G322 — A consistent lifecycle family
- **Kind:** IMPL (gap Q7) · **Specs:** INTERFACE §3 · **Plan:** `tier5-plans/step5-1-reverse-mapper.md` §4.1. Section and Q numbers below are the plan's; `l.` cites are INTERFACE.
- **Decision.** `name`, `init`, `destroy` required; `call_surface`, `free`, `dispatch` required for a provider (l.1547), accepted, type-checked and ignored on a non-provider (l.1566, l.2608); `apply_configuration` and `async_api` optional; exact types, free parameter names (§3.7). Comments-document remark 3 (`65d614be`)
- **Status.** Built in 5-1b (`rmap.nim`, `creject.nim`).

### G343 — The `lcn_call` instance
- **Kind:** Choice [IMPL] · **Plan:** `tier5-plans/stepN-2-cli.md` §8. Section and Q numbers below are the plan's.
- **Decision.** §3.1: hosted system instance; reserved names; the artifact: compiled hash, or the `cli.artifact` override, which is protected configuration (Q3); on-demand start, then resumed at every start until an explicit stop (R l.3774, l.1838), as DAEMON.md tells operators
- **Status.** N-2a built the contract, settings and kit (`lcn_call.cddl`, `settings.cddl`). The instance is N-2b.

### G344 — The launcher socket
- **Kind:** Choice [IMPL] · **Plan:** `tier5-plans/stepN-2-cli.md` §8. Section and Q numbers below are the plan's.
- **Decision.** §3.2, §3.3: `logos-core-nim.cli.v1` (frames, descriptors and roles, one command per connection, half-close cancels, replies carry status only, `target` optional with the default in `lcn_call`, the `rc` op reserved); BCP l.384's five items; activation through the logosctl instance; admission; limits
- **Status.** N-2a built the protocol and descriptor passing (`cli.cddl`, `wire.nim`, `cli/fdpass`). Activation and admission are N-2b.

### G345 — System rules S6–S8
- **Kind:** Choice [IMPL] · **Plan:** `tier5-plans/stepN-2-cli.md` §8. Section and Q numbers below are the plan's.
- **Decision.** §3.8: Runtime Control methods for `lcn_call`, every other one denied, `logosctl` barred from reconfiguring or retiring it; no provider access
- **Status.** Not built: N-2b.

### G346 — The CLI's events rule
- **Kind:** Choice [IMPL] · **Plan:** `tier5-plans/stepN-2-cli.md` §8. Section and Q numbers below are the plan's.
- **Decision.** §3.8 (Q1): a system rule allows `lcn_call` exactly `module_state_changed`, `execution_state_changed` and `inventory_changed`, for every instance (R l.3498); `route_state_changed` only by an operator rule
- **Status.** N-2a built the wire names (`cli.cddl`). The rule comes with N-2b and N-2c.

### G347 — The CLI's targets
- **Kind:** Choice [IMPL] · **Plan:** `tier5-plans/stepN-2-cli.md` §8. Section and Q numbers below are the plan's.
- **Decision.** §3.4: `--node`, `local`, the table, what 5-7a adds; continuation fails (A3)
- **Status.** N-2a built the target's wire form (`cli.cddl`, `wire.nim`). Resolving targets is N-2b.

### G348 — The CLI's routes
- **Kind:** Choice [IMPL] · **Plan:** `tier5-plans/stepN-2-cli.md` §8. Section and Q numbers below are the plan's.
- **Decision.** §3.5: reuse key, exact access, `describe_provider` all or nothing (R l.454), renewal onto a new handle (R l.3477-3478), a lock per handle (IF l.1980), buffers released before handles (IF l.3896), one retry, request keys
- **Status.** N-2a built the settings (`settings.cddl`). The routes are N-2b.

### G349 — The CLI's surface
- **Kind:** Choice [IMPL] · **Plan:** `tier5-plans/stepN-2-cli.md` §8. Section and Q numbers below are the plan's.
- **Decision.** §3.6, §3.7: D26 in detail with ambiguous unions refused in `key=value` and `--json` alike (BCP l.392), G89 output, exit codes 5, 6, 130, marked methods refused naming the method (Q2), logging; streams (bounded queue, end conditions); `module wait` by polling
- **Status.** N-2a built argument parsing and output (`args.nim`, `present.nim`). The commands are N-2b, streams N-2c.

### G350 — The CLI's idle policy
- **Kind:** Choice [IMPL] · **Plan:** `tier5-plans/stepN-2-cli.md` §8. Section and Q numbers below are the plan's.
- **Decision.** §3.1 (Q4): no self-exit (TF-20: R l.3687 against l.3697); routes close after `cli.route_idle_ms` (R l.3226); `module stop lcn_call` stays allowed
- **Status.** N-2a built the setting (`settings.cddl`). The policy is N-2b.

## 13. Implementation defaults chosen without a separate question

These were set while writing the plan, are not spec matters, and can be vetoed at any time:

- Tool and directory names: `lcn-gen` (generator), `lcn-pkg` (packaging), `lcn-conform` (artifact
  harness), `tools/spectrace` (requirements traceability), `kits/`, `vectors/{spec,self}`,
  `spec/mirrors/`, `contrib/`.
- Bootstrap input (the storage pin and the system-service registrations) compiled into the release
  binary; the Package Manager's protected inputs delivered by a Loader side-table handoff; the default CA
  policy document `lcn.ca_policy` in deterministic CBOR.
- Release builds refuse the published dev key at trust load (reconciles G137 with D18).
  - **Revised 2026-11-11 (review against 6a4dfa28, item A12):** conflicts with D27's re-decision: one
    build serves development and production, and development trust is enabled only by a protected
    configuration switch, never by the build mode (BCP l.400). See the A12 note on G137 and, on whether the
    key is "published", D18 and D27 (A13). **Needs an owner decision** (review item A12).
  - **Re-decided 2026-11-11 (owner: "Accept all", after the Fable 5.2 session's review of the recommendations, item A12):** withdrawn; development trust follows D27 and G137.
- Payload modules: one service thread and one publisher thread per context with a bounded queue (so
  direct publish never runs on a library's own thread); module state only under state_dir.
- Traceability: requirement IDs `TRN-0001`… with BLAKE3 fingerprints and sync rules across spec edits;
  test names carry IDs; decision tests are tagged `[IMPL-DECISION Gn]`.
- Library repos pin logos-core-nim by `git+https://…?rev=` and commit generated bindings with a drift
  check; the artifact harness measures thread baselines after the first init/destroy cycle.
- Offline end-to-end topology: a loopback storage seeder, a loopback delivery peer, a mock-node feature of
  the blockchain module on every PR and a 1-2 node devnet nightly, a local LEZ sequencer.
- The live run excludes mining, reward claims, Blend and transfers unless the owner asks.
- `catalog set` / `catalog refresh` mechanics (G150) and call-evidence key provisioning (G149).

---

## 14. Index

| ID | Topic | Kind | Section |
|---|---|---|---|
| D1–D31 | scope and process | SCOPE / FREE / GAP | 1 |
| G1 | alias chain value identity | GAP | 2 |
| G2 | schema root below imported references | GAP | 2 |
| G3 | unqualified common names | CONTRA | 2 |
| G4 | declarations deeper than the namespace | GAP | 2 |
| G5 | LGX `storage` / `object` | FREE (6a4dfa28) | 9 |
| G6 | referencing common callables | GAP | 2 |
| G7 | verified-view field/tuple disclosure | GAP | 2 |
| G8 | choice-arm segment | GAP | 2 |
| G9 | choice selection plan literals | GAP | 2 |
| G10–G16 | cdCDDLe details and vector format | GAP / FREE | 2 |
| G17 | independent oracle | FREE | 2 |
| G18–G28, G60 | error codes | GAP / CONTRA (most settled by 6a4dfa28 text, review 2026-11-11) | 4 |
| G29 | shared artifacts and precedence | CONTRA | 9 |
| G30–G37 | transport receiver behaviour | GAP | 5 |
| G38 | floats in opaque payloads | GAP | 3 |
| G39–G45 | Package Manager edge cases | GAP | 9 |
| G46–G52 | Capability Authority | GAP | 7 |
| G48 | engine-originated calls | GAP | 6 |
| G49 | `publish_events` | GAP (answered) | 7 |
| G53–G57 | names, list_modules, selection, Loader failure | GAP / spec-resolved | 6 |
| G58 | socket layout | CONTRA | 5 |
| G59 | nesting depth | GAP | 3 |
| G61 | timeouts | FREE | 6 |
| G62–G72 | C mapping and generator (G72 revised) | GAP / CONTRA | 3 |
| G73–G75 | platforms, catalog policy, bounds | GAP / FREE | 9 |
| G76 | host configuration formats | FREE | 10 |
| G77 | thread model | FREE | 6 |
| G78–G89 | CLI runtime, session, binaries, output | FREE / GAP (G78–G87 and G76 to be redone with D13 (a)) | 10 |
| G81, G82 | remote consumers; operator rule | GAP / FREE | 7 |
| G90, G91 | catalog format; PM storage fetch | FREE | 9 |
| G92 | storage pin vs installed package | GAP (revised) | 6 |
| G93 | module artifacts and native deps | GAP (answered) | 9 |
| G94–G96 | provenance and Nix profile | GAP / FREE | 9 |
| G97–G104 | payload contracts and dependency modules | FREE | 11 |
| G105, G106 | mobile composition and linking | FREE | 12 |
| G107, G108 | Windows transport; host channel | GAP / FREE | 5 |
| G109–G112 | prefix, permission, instances, macOS signing | FREE | 7, 11, 12 |
| G113, G114 | provenance errors; Nix + provenance | GAP | 9 |
| G115 | call-evidence export | GAP | 7 |
| G116 | live host and seeder | FREE, **OPEN** | open items |
| G117, G118 | what counts as normative | GAP | 3 |
| G119, G120, G122 | packing, verifier schema, schema.reference | GAP | 2 |
| G121 | singleton mode | FREE | 6 |
| G123–G135 | CI, platforms, build, stack | FREE | 12 |
| G136, G138 | storage start split; module names | FREE | 11 |
| G137 | package-signing trust | FREE | 9 |
| G139 | reverse mapper requirement | CONTRA | 3 |
| G140, G149 | default CA policy; evidence key | FREE | 7 |
| G141 | first module configuration | FREE | 8 |
| G142, G144, G147, G148 | delivery deps, blockchain setup, mix, deps e2e | FREE | 11 |
| G143 | state layout and retention | FREE | 6 |
| G145, G146 | release form; service management | FREE | 10 |
| G150 | catalog set/refresh | FREE | 9 |
| G151 | `.size` on a named target | GAP, **OPEN** | 2 |
| G152 | leaf-bodied declaration identity | GAP (settled) | 2 |
| G153 | local alias cycles | GAP, **OPEN** | 3 |
| G154 | forward typedefs for list targets on cycles | GAP (settled by spec text) | 3 |
| G155 | tie-breaking among type definitions | CONTRA (moot) | 3 |
| G156 | an artifact without its hash | CONTRA, **OPEN** | 9 |
| G157 | line break in a byte string | GAP, **OPEN** | 2 |
| G158 | common-name projection | GAP, **OPEN** | 3 |
| G159–G164 | Credential Store, static registration, observation scope, missing config, caller view, session reuse | GAP, **OPEN** (G163, G164 settled by spec text, review 2026-11-11) | 6 |
| G165 | oversized Event from the void publish callback | CONTRA, **OPEN**, interim (a) decided | 5 |
| G166 | key rotation and installed packages | GAP, **OPEN** | 9 |
| G167 | recorded edges of a reused installed package | GAP (decided; reported as TF-12) | 9 |
| G168 | execution-authorization denial after `start_module` | GAP, **OPEN** (TF-10) | 6 |
| G169 | the code of an establishment that returns nothing | GAP, **OPEN** (TF-16) | 6 |
| G170 | stopped consumer, closing a terminal route, denied renewal | CONTRA and GAP, **OPEN** (TF-17) | 6 |
| G171 | the order of checks for one request | GAP, **OPEN** (TF-18) | 6 |
| G172 | status codes that provider code returns | GAP, **OPEN** (TF-19) | 6 |
| G173 | when `start_module` and `stop_module` answer | GAP, **OPEN** (TF-20) | 6 |
| G174 | an admitted call whose route ends | FREE (decided) and GAP, **OPEN** (TF-23) | 6 |
| G175 | event authorization points | FREE (decided) and GAP, **OPEN** (TF-24) | 6 |
| G176 | two publishers that deliver into each other's handlers | CONTRA, **OPEN** (TF-21) | 6 |
| G177 | invocation paths of direct route handles | FREE | 6 |
| G178 | the thread of a Runtime Control subscription's handler | GAP, **OPEN** (TF-22) | 6 |
| G180 | the end of a cleanup that its stop deadline overran | GAP, **OPEN** (TF-28) | 6 |
| G190 | where bootstrap ends; `logos_runtime_start`'s failure codes | GAP, **OPEN** (TF-25) | 6 |
| G191 | the intent of the bootstrap-realized instance | GAP, **OPEN** (TF-26) | 6 |
| G192 | host acceptance of a Runtime-generated identity | GAP (low), **OPEN** (TF-27) | 6 |
| G193 | a preserved instance after an unclean end | GAP, **OPEN** (TF-29) | 6 |
| G194 | the code for a `retire_module` target on another Runtime | GAP, **OPEN** (TF-30) | 6 |
| G195 | the code when `create_module` selects no declaration | GAP, **OPEN** (TF-30) | 6 |
| G205 | the Capability Authority's error codes and order of outcomes | GAP, **OPEN** (TL-04, extended) | 7 |
| G206 | the audit record of a repeated revoke | GAP, **OPEN** (TL-04, extended) | 7 |
| G207 | scope combinations in one `evaluate` | GAP, **OPEN** (TL-04, extended) | 7 |
| G217 | the permission scopes of an execution decision | GAP, **OPEN** (TF-32) | 7 |
| G218 | the state an expired route enters | GAP, **OPEN** (TL-03) | 7 |
| G225 | a Runtime Control subscription ended without a signal | GAP, **OPEN** (TF-35) | 6 |
| G226 | the facts a Runtime Control selector is compared with | GAP, **OPEN** (TF-34) | 6 |
| G227 | a realization change without a lifecycle transition | GAP, **OPEN** (TL-08, extended) | 6 |
| G228 | the code for a summary or permission-settings target on another Runtime | GAP, **OPEN** (TF-30) | 6 |
| G229 | permission settings in direct mode | FREE (decided) | 6 |
| G230 | the `selection` of the in-process realizer | GAP, **OPEN** (TF-36) | 6 |
| G233 | the code for a configuration state too large for a frame | GAP, **OPEN** (TF-30) | 6 |
| G234 | the code when the configuration revision cannot advance | GAP, **OPEN** (TF-30) | 6 |
| G235 | a configuration summary without a binding | GAP, **OPEN** (TL-09) | 6 |
| G236 | what `applied_value_revision` names | GAP, **OPEN** (TL-10) | 6 |
| G237 | an application deadline that passes while stopping | GAP, **OPEN** (TF-28, added) | 6 |
| G241 | one payload depth setting | FREE (decided) | 6 |
| G242 | asynchronous work nested deeper than the worker pools | FREE (decided) | 6 |
| G243 | a static record naming an unregistered binding | FREE (decided) | 6 |
| G244 | the code for a route that would carry a marked payload | FREE (decided; re-decided as G277) | 6 |
| G246 | one Module Loader instance per Runtime; its reserved names | GAP (decided) | 6 |
| G247 | the lifecycle answers on the Module Loader instance | GAP (decided) | 6 |
| G248 | a direct-only Module Loader | Reading (decided) | 6 |
| G249 | termination of direct realizations after Loader loss | GAP, interim (not yet sent) | 6 |
| G250 | a failed `_MODULE_init` behind the Loader | Reading (decided) | 6 |
| G251 | ordinary routes to the Module Loader | Choice (decided) | 6 |
| G252 | when the Runtime decides the Loader has failed | GAP (decided) | 6 |
| G253 | execution authority and settings of the Module Loader | Reading (decided) | 6 |
| G254 | routing-selection input | FREE (decided) | 6 |
| G255 | a replayed establish or renew answer and the ticket | GAP (decided), interim | 6 |
| G256 | a transported connection lost with no known cause | GAP (decided), interim | 6 |
| G257 | the Runtime serves a direct provider over local transport | Reading (decided) | 6 |
| G258 | one session per materialization | Reading (decided) | 6 |
| G259 | a peer-identity mismatch at materialization | Reading (decided) | 6 |
| G260 | the end of a transported route, at both ends | Reading (decided) | 6 |
| G261 | Event output overflow on a transported subscriber | FREE (decided) | 6 |
| G264 | the Module Host program | FREE (decided) | 6 |
| G265 | Module Host supervision | FREE (decided) | 6 |
| G266 | the carrier between the Runtime and a Module Host | FREE (decided) | 6 |
| G267 | authority with a hosted module | FREE (decided) | 6 |
| G268 | the end of a Module Host | GAP, interim (not yet sent) | 6 |
| G269 | a Module Host ended at a deadline | READING + GAP, interim (not yet sent) | 6 |
| G270 | a live application whose Module Host ends | GAP, interim (not yet sent) | 6 |
| G271 | Runtime Control events in a Module Host | FREE (decided) | 6 |
| G272 | a hosted instance's execution scope and route mode | FREE (decided) | 6 |
| G273 | the Response commit at a hosted endpoint | GAP, interim (TF-50) | 6 |
| G274 | the roots of a hosted provider's call record | GAP, interim (TF-51) | 6 |
| G275 | a Module Host of the previous run | GAP, interim (not yet sent) | 6 |
| G276 | which buffers are wiped, and when | FREE (decided) | 6 |
| G277 | the paths a contract that marks a payload is routed on | READING (decided by the owner) | 6 |
| G278 | what a diagnostic says of a marked payload | FREE (decided) | 6 |
| G279 | the permission profile | FREE (decided) | 7 |
| G280 | no Loader-enforced permission | Choice (decided) | 7 |
| G281 | when a settings replacement is applied | Reading (decided) | 7 |
| G282 | the installed snapshot | GAP (decided), interim | 7 |
| G283 | one permission for every facility class | Reading (decided) | 7 |
| G284 | a start the permission settings refuse | GAP (decided), interim | 7 |
| G285 | a reconciliation stop past its deadline | Choice (decided) | 7 |
| G286 | permissions enforced by a module provider | Reading (decided) | 7 |
| G287 | lifecycle ordering seen by orchestration | Choice (decided) | 6 |
| G288 | the signal that permissions or authority became available | Choice (decided) | 6 |
| G289 | resumption against retry, as orchestration sees them | GAP (decided) | 6 |
| G290 | nothing tells orchestration that the authority binding exists | GAP (low) (decided) | 6 |
| G291 | an enforcement stop past its deadline: resumption or retry | GAP (decided) | 6 |
| G292 | orchestration's coordinated shutdown | Choice (decided) | 6 |
| G293 | logosd's `daemon-config.v1` | Choice (decided) | 10 |
| G294 | logosd's composition and bootstrap | Choice (decided) | 10 |
| G295 | logosd's system rules and default policy | Choice (decided) | 10 |
| G296 | the logosctl instance and its socket | Choice (decided) | 10 |
| G297 | request keys for `module create` | Choice (decided) | 10 |
| G298 | no remote listener, export or enrollment in Tier 4b | GAP, interim (K19) | 10 |
| G299 | the trust file, its mark and the development switch | Choice (decided) | 10 |
| G300 | what the development switch gates, and how test hooks are selected | Choice (decided) | 10 |
| G301 | logosd's call-evidence store and its export | Choice (decided) | 10 |
| G302 | logosd's process | Choice (decided) | 10 |
| G303 | the logosctl command set in Tier 4b | Choice (decided) | 10 |
| G304 | in-process Host API additions for logosd | Choice (decided) | 10 |
| G305 | a replacement instance's state: a fresh assignment filled by migration | GAP (decided) | 6 |
| G306 | who authorizes a state migration | GAP (low), interim (decided) | 6 |
| G307 | a migration that consumes the source's preserved storage | GAP (low), interim (decided) | 6 |
| G309 | how a BCP §5.4 unit is labelled from the deployment document | Reading, then Choice (decided) | 10 |
| G310 | which deployments BCP §5.1 and §5.4 bind | GAP, interim (TF-43) | 10 |
| G311 | the reach of "for package-backed module creation" in BCP l.367 | Reading | 10 |
| G312 | Loader strategies and hosted placements are not Core profiles | Reading | 10 |
| G317 | the reverse mapper's input set | IMPL (gaps Q1, Q4; reading Q6) | 12 |
| G318 | the reverse mapper's groups and selection | IMPL (gaps Q2, Q5) | 12 |
| G319 | what "canonical" compares in the reverse direction | IMPL (reading Q3) | 12 |
| G320 | CDDL emission | IMPL | 12 |
| G321 | `lcn-gen cddl` | IMPL | 12 |
| G322 | a consistent lifecycle family | IMPL (gap Q7) | 12 |
| G323 | the TLS signing seam: what a signer signs, and where that is checked | FREE (decided) | 5 |
| G324 | which certificates the tls-tcp verifier accepts | READING under B2 (decided) | 5 |
| G325 | accepted current time for the tls-tcp verifier | FREE (decided) | 5 |
| G326 | the tls-tcp carrier's TLS parameters | FREE (decided) | 5 |
| G327 | the TLS library's plaintext buffers | owner question (decided (b), an opt-in library option; built in 5-2d; G277's refusal stays until 5-7a) | 5 |
| G328 | when a TLS 1.3 peer has completed the mutual-authentication handshake | READING | 5 |
| G329 | the event loop for AF_UNIX on Windows | FREE | 5 |
| G330 | peer attribution and the expected process on Windows | FREE | 5 |
| G331 | listener transfer and handle hygiene on Windows | FREE | 5 |
| G332 | filesystem protection of Windows endpoints; T l.1156 for one user | Reading, FREE | 5 |
| G333 | the Windows builds the profile is offered on | Reading | 5 |
| G334 | the Windows CI leg | FREE | 12 |
| G340 | a library leaves its host's signal dispositions alone | Choice | 12 |
| G341 | the kit's toolchain range, switches, export lists and packaging | Choice | 12 |
| G342 | modules built with the other memory manager | Choice | 12 |
| G343 | the `lcn_call` instance | Choice | 12 |
| G344 | the launcher socket | Choice | 12 |
| G345 | system rules S6–S8 | Choice | 12 |
| G346 | the CLI's events rule | Choice | 12 |
| G347 | the CLI's targets | Choice | 12 |
| G348 | the CLI's routes | Choice | 12 |
| G349 | the CLI's surface | Choice | 12 |
| G350 | the CLI's idle policy | Choice | 12 |
| G351 | "package-backed" is not defined; when the handoff is obtained again | GAP (TF-44), open | 9 |
| G352 | BCP l.266 labels `tls-tcp` mandatory without l.336's condition | Reading | 10 |
| G353 | installed records come only from installation | spec-resolved | 9 |
| G354 | a `call` record that cannot be built or stored after the outcome | GAP, interim as built | 7 |
| G355 | the `failure` and `state` a facade's record reports | GAP, interim (B6, decided) | 6 |
| G356 | continuations on a `connect_remote` binding | GAP, interim (B7, decided) | 6 |

---

## 15. Revisions and implementation choices since work started

Work started on 2026-11-09 while the spec owner revises the specs after our issue reports. The order
of work follows the tiers in `docs/SPEC-STATUS.md`: most settled areas first.

| ID | Kind | Entry | Decision | Date |
|---|---|---|---|---|
| R1 | SCOPE (revises D12) | CI breadth while only Tiers 1–3 exist | Linux x86_64, Linux aarch64 and macOS arm64. Windows, Android and iOS legs join before Tier 4 work. Owner's answer. Revised by R6 (2026-11-16): Windows joined in Tier 5; Android and iOS join with M12. | 2026-11-09 |
| R2 | SCOPE (revises D31) | How Nim dependencies are declared | `logos_core.nimble` + `nimble.lock` are the only place versions are decided, and the project builds with plain `nimble`. Nix builds from the same lock: `nix/nimble-deps.json` adds a content hash per locked package (generated by `nix run .#update-nimble-deps`; Nimble's sha1 cannot verify a Nix fixed-output fetch) and each dependency is a `fetchgit` fixed-output derivation the binary cache can serve. Evaluation fails when the JSON and the lock disagree. Rejected: nim2nix and mkNimbleApp (one opaque whole-tree hash, patched nimble), nixpkgs `buildNimPackage` (a second lock that decides versions), eval-time `builtins.fetchGit` (not cacheable). Owner's request. | 2026-11-09 |
| R3 | SCOPE | Workspace layout | `logos-new-workspace/` is a plain folder; `logos-core-nim/` is its own git repository; module repos and forks are added next to it. Owner's answer. | 2026-11-09 |
| I1 | IMPL | BLAKE3 | Vendor the official BLAKE3 C sources 1.8.7 (commit `f3149ec5`) under `src/logos_core/crypto/blake3/` with our own binding, refreshed by `tools/update-blake3.sh`. nim-blake3-c cannot be used as a Nimble dependency: its `installFiles` list `src/…` paths while `srcDir = "src"`, so Nimble installs only the `.nimble` file. G134's "BLAKE3 C from a pinned input" is kept in spirit: the sources are pinned by commit. | 2026-11-09 |
| I2 | IMPL | Formatter | nph 0.7.0 from a second nixpkgs input (`f4a03c00`, nixos-unstable, cached). nixpkgs release-25.11 ships 0.6.1, which formats differently, and the 0.7.0 release binaries for arm64 are x86_64 builds. | 2026-11-09 |
| I3 | IMPL | nixpkgs pin | release-25.11 at `cd648d6e`, the commit logos-storage-nim uses, with its Nim overlay pattern updated to Nim 2.2.14 (2.2.10 has the refc heap bug Nim#25992). | 2026-11-09 |
| I4 | IMPL | Spec mirrors | `spec/mirrors.toml` names each mirrored block by spec file, section key, fence language and ordinal, so line shifts elsewhere in a spec do not matter. `spectrace mirror` fails on any difference from the pinned spec. | 2026-11-09 |
| I5 | IMPL | Pinned values | `spec/pins.toml` holds every pinned identifier, root, digest and vector length with the section it comes from, as plain `[name]` tables that both Python's tomllib and Nim's std/parsecfg read. `spectrace pins` checks each value still appears in its section; tests recompute roots and digests and compare. | 2026-11-09 |
| I6 | IMPL | Requirement units (G117, G118) | `spectrace` units: sentences, list items and table rows with an uppercase BCP 14 keyword (`kw`), with a lowercase must/shall/should (`lc`), one unit per CDDL rule, one per other fenced block, one per heading. A list item without a keyword inherits its keyword lead-in sentence. Abstracts count as normative: in LOADER, PM, CA, RUNTIME and INTERFACE they carry MUST text. Only References and Copyright are informative. IDs are kept across spec revisions by exact fingerprint, then by same-section similarity ≥ 0.8 (CDDL: same rule name); retired IDs are never reused. **Revised 2026-11-11 (G117, review item B1):** `lc` units are informative and no longer gated; they stay in the ledger, so tests may still cite them. | 2026-11-09 |
| I7 | IMPL | Tools language | `tools/spectrace` and `oracle/` are Python 3 using only the standard library plus `blake3` and `cbor2`, run from the dev shell and as flake checks. | 2026-11-09 |
| I8 | IMPL | Code conventions | Library code starts with `{.push raises: [].}` and returns `Result`; no implicit `result` variable (a named local is returned explicitly); every suite runs under `--mm:orc` and `--mm:refc`. | 2026-11-09 |
| I9 | IMPL | One CBOR codec | INTERFACE §4.4, cdCDDLe §9 and RFC 8949 §4.2.1 impose the same byte rules at `f4f83471`, so `src/logos_core/cbor` is one encoder and one strict decoder. What values a layer allows (no floats in contracts, cdCDDLe node shapes) is checked by that layer. **Revised 2026-11-11 (review against 6a4dfa28, item C8):** floats are no longer a layer's choice: INTERFACE l.3139 makes a floating-point item in `params`, `result` or `data` a Transport validation failure that MUST NOT be deferred to schema validation, and the decoder now rejects floats unless `allowFloats` asks for the generic data model (I48). | 2026-11-09 |
| I10 | IMPL | CBOR decoder errors | Four classes: `malformed` (not one well-formed item over the whole input, trailing bytes included), `non-deterministic`, `invalid-utf8` (INTERFACE §4.5 maps it to schema-mismatch) and `too-deep` (G59: every container counts, empty ones and tags included; cap 1024). Well-formedness is checked over the whole input before determinism. **Revised 2026-11-11 (review against 6a4dfa28, item C8):** the depth rule changed: payload depth counts array and map containers only, a root container is depth one and byte-string contents are not traversed (INTERFACE §4.5.1 l.3146-3148). `too-deep` now counts arrays and maps, and tags have their own `maxTagDepth` (I48). | 2026-11-09 |
| I11 | IMPL | Opaque text | `DecodeOptions.allowInvalidUtf8` keeps a text string that is not UTF-8 (marked `validUtf8 = false`, never returned by `getText`), for the transport, which forwards payloads it does not validate. | 2026-11-09 |
| I12 | IMPL | cdCDDLe lexical rules (RFC 8610 Appendix B, G11) | Whitespace is space and line feed (CRLF allowed); a tab or a bare CR is a syntax error, and a comment must end with a line break. Text escapes are exactly RFC 8259 §7's, and a byte string may also escape `'`. `h''` and `b64''` ignore spaces, line breaks and comments; `b64''` takes the RFC 4648 §4 or §5 alphabet (not both in one literal), optional but complete padding, and zero trailing bits. A line break inside an unprefixed `'…'` byte string is unsupported. Hex, binary and `-0` integers normalize; integers beyond 64 bits and floats are unsupported. **Revised 2026-11-11 (review against 6a4dfa28, item A30, A29):** range bounds must be integer literals written directly (cdCDDLe §5.1 l.181), so a parenthesized bound such as `(1)..(2)` or `.size ((1)..8)` is unsupported (it was accepted once §7.4 removed the parentheses). Comments follow RFC 8610's `PCHAR = %x20-7E / %x80-10FFFD`: the owner kept RFC 9682 §2 for string literals only (cdCDDLe §5 l.126-127), so a C1 control is admitted in a comment and rejected only in a text or byte string. U+10FFFE and U+10FFFF are rejected in both, as both RFCs stop at U+10FFFD. Vectors: `unsupported-range-parenthesized-bounds`, `unsupported-size-parenthesized-bound`, `presentation-comment-c1-control`, `syntax-noncharacter-in-{comment,text,bytes}`. | 2026-11-09 |
| I13 | IMPL | cdCDDLe names and error order | Of the RFC 8610 prelude, only `uint`, `bool`, `tstr`, `bstr` (primitives) and `true`/`false` (Boolean literals) are in the subset; a reference to another prelude name is unsupported and redefining any prelude name is a resolution error. Errors are reported by stage: the first syntax or unsupported construct in source order, then resolution (definitions, then references), then canonical-rule violations. Nesting is capped at 256 type levels (unsupported beyond). The decoder rejects rule and reference names equal to a primitive (§6) and accepts any text as a member key (§8 asks only for a `tstr` literal). An array group is fixed-length or exactly `[* T]` (§5.1 l.159 read with §8 l.507-508). **Known deviation (review against 6a4dfa28, item A31, 2026-11-11):** the 256-level cap counts every type expression the parser enters, parentheses included, while INTERFACE §5.3 l.3942-3950 counts only `schema-node` levels (at most 128, wrappers excluded) and requires support for every valid schema within its limits. The parser enters at most one level per `schema-node` level, so only a valid schema whose redundant parentheses take it past 256 levels is refused (as unsupported). The fix, when needed, is a type parser with an explicit stack. | 2026-11-09 |
| I14 | IMPL | cdCDDLe vectors (G16, G17) | `oracle/gen_cddl_vectors.py` writes `tests/vectors/cddl/vectors.cbor` (records exactly as §12). Expected models of source vectors are written by hand; decode vectors must agree with the independent checker `oracle/cdcddle.py`. The `oracle-selftest` flake check fails when the file is stale. | 2026-11-09 |
| I15 | IMPL | Layout input (HASH §4, §7.4; COMMITMENT §9.3) | `hash/layout` takes the §9.3 value tree (`commitment/value.nim`) plus two values the commitment layer derives from the list schema: the element schema identity (`list-payload` field 3, which an empty list cannot supply) and, for a homogeneous packable scalar list, its scalar kind. A list whose element schema is a reference, local or imported, is not packed, even when the reference resolves to a packable scalar: HASH §4 excludes reference lists and forbids packing across referenced-schema boundaries. Literal elements follow G119. | 2026-11-09 |
| I16 | IMPL | HASH verifier checks | `hash/check.nim` checks one payload at a time: exact key sets and types (HASH §7.3–§7.5), 32-byte digests, known node kinds and the kinds each parent may hold, labels, counts, chunk and byte ranges, and the one canonical branch tree (top-level branch size is the smallest 256^k leaving at most 256 branches). Errors are classed: malformed-cbor, non-canonical-cbor, malformed-hash-input, unknown profile/suite/model, domain-mismatch, digest-length, node-kind, layout-mismatch. Schema payloads (COMMITMENT §9.2) are the commitment layer's to check. A verifier policy that accepts another commitment-model revision is a `HashProfile` with that id. | 2026-11-09 |
| I17 | IMPL | HASH vectors (G17) | `oracle/hashlayout.py` is an independent layout written from the spec text; `oracle/gen_hash_vectors.py` writes `tests/vectors/hash/layout.cbor` (value trees in the §9.3 shape plus the I15 list annotations as keys 100 and 101, with their value roots). Trees too large to store (branches over branches, 1 MiB strings) are named by generator and size, and both sides expand them by the same rule. The oracle also reproduces HASH App A and B.1–B.3 from the pins. Every payload the Nim layout makes is checked against the mirrored HASH §7 CDDL and domain tables (`spec/mirrors/HSH/*.md`). | 2026-11-09 |
| I18 | IMPL | Schema-model construction (COMMITMENT §3.1, §5) | `commitment/construct.nim` builds one document's model from source text through cdCDDLe. A `SchemaContext` holds what a document may depend on: the pinned registry (`pins.nim`, the roots every common import carries), the pinned common document itself (`CommonSchemaDocument`, generated from its mirror; used only to follow references and checked at start-up to reproduce the registry), the supplied supporting schemas and the interface documents `_implements` names. Modules see common and supporting types; interfaces and supporting schemas see common types only. A dependency built under another commitment-model revision is rejected (no compatibility profile exists). INTERFACE §1.2's ascending `_implements` order and its unused-interface rule are enforced here; the rest of INTERFACE §1 waits for Tier 2. Errors are strings for now. **Revised 2026-11-10 (6a4dfa28):** ND-08 reverses the interface rule: interfaces may reference leaf supporting schemas (INTERFACE §1.1 l.100-113); `accept.supportingOf` collects them, and schema responses list each interface's `supporting_schemas` (§5.1 l.3279-3286). Tests `[IFC-0021] [IFC-0025] [IFC-0560]`, `[IFC-0449] [IFC-0458] [IFC-0459] [IFC-0930] [IFC-0931]`. | 2026-11-09 |
| I19 | IMPL | Choice selection plans (COMMITMENT §3.1) | `commitment/choice.nim`. An arm "proves" it rejects an outcome exactly for scalar values: bool, fixed-width integer ranges, and text (UTF-8, no NUL, `.size` byte length) or byte-string sizes; "any other value" counts what a primitive can hold (exact for bool, fixed-width integers and strings of at most one byte, unbounded otherwise). Scalar values are every CBOR item except arrays, maps and tags. References are followed with memoization keyed by (document, declaration, observation); one reached again for the same observation while it is being followed proves nothing (the arm stays a candidate). A plan node lists every outcome of its test, with no child where no arm remains; the same plans select arms when validating values (`validates`), which rebuilds them per call for now. | 2026-11-09 |
| I20 | IMPL | Value normalization (COMMITMENT §7, §8) | `commitment/normalize.nim`. A `Site` (document, nearest named declaration, path, node) names each schema position; its identity is `identityOf` (G152 at the empty path, a leaf hash at a leaf node, a structural root otherwise), cached per site within one normalization, as are choice selection plans. A map value has text keys only; each schema field is looked up by name and any other entry rejects the value; an absent optional field becomes an absent node carrying the field's identity. Local references are followed by `throughLocal` (G1), bounded so a reference cycle is an error; imported ones become reference-value nodes resolved through the schema set's import table. A list node gets its element identity and packability from `packKindOf` (G119, I15). Input is decoded Logos deterministic CBOR (`normalizeBytes` decodes first), so floats, tags and non-shortest forms never reach it; scalars are accepted by `primitiveAccepts`, shared with choice plans. `parseValueNode` and `parseValueRoot` read §9.3 objects strictly (exact key sets, ordering and coverage) without the I15 annotations: a parsed list takes its element identity from its first element and is never packed, so a verifier with a schema re-normalizes the plain value (`plainValue`) to recover them. Errors are strings for now. Single implementation: the oracle does not normalize. | 2026-11-09 |
| I21 | IMPL | Verified views (HASH §7.6, §8) | `hash/view.nim`. `viewOf` collects the complete payloads from the value root down the path and emits them disclosed-item first, value root last (App B.1/B.2's order); it refuses any path the verifier would reject. `verifyView` replays them from the value root down: each step must be in the domain of the record its parent selects, hash to that record's digest, repeat its schema identity and the current schema root in field 1 (the referenced root below a reference, G2), and every step must be used. Branches are entered by base-record index: the field's position in the schema map, the chunk, the tuple position or the byte chunk. A path crosses an imported reference without a segment and a choice only through its `choice-arm` segment (G8); a field or tuple position discloses the inner value (G7). An empty path discloses the `normalized-value-root` with no proof; any other path discloses a `value-node`, an absence marker or a string range. Seven error classes: `malformed-view`, `unknown-identifier`, `schema-mismatch`, `invalid-path`, `disclosed-mismatch`, `proof-mismatch`, `value-root-mismatch`. `verifyView` takes the schema (G120): every node's identity is recomputed and the disclosed value re-normalized. **Revised 2026-11-11 (review against 6a4dfa28, item A23):** HASH §8 l.1214-1215 requires the schema construction input, so it is no longer optional. The schema-less replay that App B.1-B.3's synthetic identities need is `verifyPhysicalProof`, which is not a §8 verification and cannot descend a branched map (the field index comes from the schema); TF-13 reports the App B gap. | 2026-11-09 |
| I22 | IMPL | Schema acceptance (INTERFACE §1, §5.3) | `iface/accept.nim` `acceptContractSet(primary, interfaces, supporting, opts)` takes document text only: file names, labels and aliases never reach it. Each document is built through COMMITMENT construction (I18); then come the metadata block, prelude and reserved names, naming rules (`iface/names.nim`), method and event limits, the supporting-schema suffix rule, the §5.3 limits (1 MiB per document, 8 MiB per set, 65,536 schema nodes, 128 nesting levels), the input-set rules, G69, G153 and the C mapping (I23). `AcceptOptions.system` admits the reserved `logos` names, for Logos-defined contracts only. `_module` values follow the RUNTIME §1.3 grammar (at most 64 bytes). Errors are strings that cite the section. **Revised 2026-11-11 (review against 6a4dfa28, item C7):** G69's reservations are gone at 6a4dfa28. What remains is INTERFACE l.261: `_module` values containing `_call_` or `_publish_` are invalid under the Runtime module-name grammar, rejected at acceptance by `checkModuleName` in `iface/names.nim`. `_sensitive` (INTERFACE §1.2.1 l.211-217: nonempty, sorted, distinct local request or response names; not in a supporting schema) is validated during construction, `sensitiveNames` in `commitment/construct.nim`. | 2026-11-10 |
| I23 | IMPL | C mapping at acceptance; NX-04 interim | INTERFACE §2.1 l.898 says an accepted set never derives two identical C identifiers or a namespace-projection collision, so acceptance runs the whole forward C type mapping (`iface/cmap.nim` `cDeclarations`) and keeps only the verdict [SPEC INTERFACE §2.1 l.898]. **Revised 2026-11-10 (6a4dfa28):** the NX-04 interim is withdrawn: capitalized stems already avoid the collision (`error.code` gives `logos_error_Code_t`), so `error.code`, `module.context` and `schema.commitment` are accepted and their headers compile next to `logos_types.h` (test `[IFC-0123]`, NX-04). | 2026-11-10 |
| I24 | IMPL | Call surface and `logos.schema` (INTERFACE §1.4, §1.5, §5.1) | `iface/surface.nim`. `callSurface` lists each method by bare wire name with its defining contract and each event by its qualified event id; a bare name implemented twice is rejected at acceptance. `schemaCommitment` builds `logos.schema_commitment` from the pinned commitment model, hash profile and suite (`spec/pins.toml`). `schemaResponse` builds the response for a selected root (the primary contract with its interfaces and supporting schemas, or one interface alone); `acceptSchemaResponse` checks one against an expected root, rebuilding every entry. **Revised 2026-11-11 (review against 6a4dfa28, item C8):** "or one interface alone" now has a fixed content: for a route selected through an implemented interface, the response holds that interface contract, an empty `interface_schemas` array and all and only the supporting schemas that interface needs, never the primary contract or another implemented interface (INTERFACE l.3282-3286). I18 carries the matching note. | 2026-11-10 |
| I25 | IMPL | Payload validation and outcomes (INTERFACE §4.1–§4.5, §5.1) | `iface/payload.nim`: a `ContractValidator` from an accepted set checks params, results and event data: deterministic CBOR first (malformed and non-deterministic input are `INVALID_PARAMS` with that reason; text that is not UTF-8 is a `schema-mismatch`; nesting past the G59 cap has no detail), then an unknown bare method is `METHOD_NOT_FOUND`, then a schema mismatch carries the path to the first offending item. `iface/outcome.nim`: `ErrorCode` 0–9 named as in `logos_types.h`; any other status from a provider is a module failure; messages of at most 512 UTF-8 bytes, never with `LOGOS_OK`; detail is one valid `logos.invalid_params_detail` of 1–4096 bytes, only with `INVALID_PARAMS`. §4.6 is left to Tier 3: it binds the provider and the Transport adapter. **Revised 2026-11-10 (6a4dfa28):** a float at any depth is `non-deterministic-cbor` before the schema check (G38, `[IFC-0919] [IFC-0920]`); tags, null, undefined and simple values stay schema mismatches. Depth is `ContractValidator.maxDepth` (default 1024; `validator(s, maxDepth)` refuses a value below 128); past it, `PayloadError` has no reason, so the failure is INVALID_PARAMS without detail (`[IFC-0923] [IFC-0926] [IFC-0928] [IFC-0929]`). `outcome.checkedProviderStatus` passes a valid status through and turns any other into MODULE_ERROR with neither message nor detail (§5.1 l.3364, `[IFC-0932] [IFC-0933]`). `configuration-schema-mismatch` keeps its path, rooted at the decoded configuration (`[IFC-0441]`); nothing produces it before CONFIG (Tier 4). | 2026-11-10 |
| I26 | IMPL | lcn-gen, C types (D29, INTERFACE §2.1–§2.3, §2.5, §5.2) | `lcn-gen logos-types` writes `logos_types.h`: the §5.2 fixed block (without its `<module-C>` placeholder lines), the §2.3 empty types and the common section (names per the G158 interim). **Revised 2026-11-10 (6a4dfa28), C mapping revision 3:** `lcn-gen types [--module:NAME] [PRIMARY]` writes `<module or ns-C>_types.h`. With `--module` it builds an explicit binding (§2 l.604-609): interface-only, an events-only interface, a types-only primary, or lifecycle-only with no documents (§3.9.2 l.2868-2875). The frame is: the include, the revision check `3u`, three context checks, the C++ linkage wrapper, shared constraint typedefs, then one group per document (supporting, interfaces, primary), each guarded by `LOGOS_DOCUMENT_<ns>_DEFINED` with its four ROOT macros checked before suppression, and the PRIMARY/IMPLEMENTS binding constants last and unguarded (§3.2 l.2300-2330). Every header is stamped `PROVISIONAL ABI (spec <revision>)`, taken from `pins.nim`. Tests compile every generated header with `cc -std=c11 -Wall -Wextra -Wpedantic -Werror` (and C++ and other modes for literals). Built by Nix (`packages.lcn-gen`) and by Nimble (`namedBin`; `nimble build --useSystemNim` on macOS). **Revised 2026-11-11 (review against 6a4dfa28, item C9):** "`cc -std=c11`" above is stale: INTERFACE l.2980 requires the common header and generated headers to compile as C17, C23, C++17, C++20 and C++23, and `tests/test_codegen.nim` compiles them in those five modes. | 2026-11-10 |
| I27 | IMPL | lcn-gen, Nim types (D29) | INTERFACE fixes only the C mapping; the Nim one follows it where Nim allows. **Revised 2026-11-10 (6a4dfa28):** names follow the revision-3 C stems and labels: type names are `pascal(stem)`; a choice's kind enum lists the C labels in C discriminant order (`Case<i>` in indexed form); arm fields are `arm_<label>`; the decoder maps the canonical arm index to that member (so `DemoEntryKind.Dir` = 0 and `.File` = 1 while the canonical arm order is file, dir). Unchanged: scalars map to `bool`, `uint8`…`int64`, `string`, `seq[byte]`; lists to `seq`; tuples to anonymous tuples; optional fields to `Opt`; a literal field defaults to its literal; a reference on a by-value cycle is a `ref`; decoders validate one deterministic-CBOR item against the embedded accepted schema (`codegen/nimrt.nim`) before converting; names Nim cannot tell apart are a generation error. `common_types.nim` and `tests/generated/` are committed output (`nimble regen`), starting with `#!fmt: off`. `lcn-gen nim` still needs a primary document; Nim output for interface-only and lifecycle-only bindings waits until something uses it. | 2026-11-10 |
| I28 | IMPL | Per-unit claims | `conformance/claims/<SPEC>.toml` gains `[units]`: one requirement unit's status, overriding its section's, so a claimed section can defer the few units that belong to a later tier (e.g. §1.2's full-ABI rule waits for the export-set gate) and a deferred section can claim the units built now (§2.5's event struct, §3.9.5's projection collision, §5.2's `logos_types.h`). Units addressed to authors, or permissions, are covered by `conformance/inspection/<SPEC>.toml` items with a reason. **Revised 2026-11-11 (review against 6a4dfa28, item C9):** the example "§3.9.5's projection collision" no longer exists: INTERFACE §3.9.5 (l.2938) is now "Required Rejections", whose cases include projection mismatches but no projection collision. The collision rule is §2.1 l.898. | 2026-11-10 |
| I29 | IMPL | Envelope CDDL reader (TRANSPORT §1.1, §1.3; G15) | `transport/protocddl.nim` reads the mirrored envelope blocks, which are outside the cdCDDLe subset, accepting exactly the constructs they use (integer map keys, `any`, an unsized `uint`, `lo..hi` ranges, `{ * tstr => any }`) and rejecting anything else, so a revision that adds a construct fails when the pinned documents load instead of being misread. Names outside the documents resolve to declarations of the pinned common schema, checked with the INTERFACE §5.1 model. `transport/envelope.nim` checks at load that its Nim view of the nine kinds equals the CDDL's kinds and closed field sets. | 2026-11-10 |
| I30 | IMPL | Opaque text inside payloads (TRANSPORT §2.3, §8.3; INTERFACE §4.5) | A frame body is decoded with I11's `allowInvalidUtf8`: the envelope check of a payload map is only "a map with text keys", and whether its text is UTF-8 is the schema-aware boundary's to judge, as a schema mismatch, the same as in direct mode. The envelope's own text fields must be UTF-8. `encodeMessage` runs the receive-side envelope checks on what it emits, so no invalid envelope is sent. | 2026-11-10 |
| I31 | IMPL | A provider result the envelope cannot carry (TRANSPORT §4.1, §6; INTERFACE §4.3) | `CalleeConn.respond`: a success response outside its schema, or a failure the envelope cannot carry (code 0, a message over 512 bytes, detail its code does not allow), is sent as `MODULE_ERROR`, as direct mode reports it. | 2026-11-10 |
| I32 | IMPL | Sans-I/O transport shape (TRANSPORT §2.1, §3, §6–§8) | Framing is a 4-byte big-endian length. The reader yields whole bodies from any byte chunks, refuses a frame over its configured maximum, which is at least 16 MiB (§2.1; a smaller configured limit is refused), and holds at most limit + 4 bytes. The sender checks that each body fits the peer maximum, 16 MiB unless established otherwise, before writing (I53). Each side's session is a state machine that turns a received frame into actions and a local operation into bytes or a typed failure, with no I/O and no clocks. Per-connection limits are `TransportLimits` (I52). The callee has a termination mode (G35, I57) and invocation-scoped publication (`publishScoped`, §6). The `random-256` ticket store takes the monotonic clock reading and, for tests, the random source (default `std/sysrand`); it is not thread-safe, and a Runtime serializes access, which makes `redeem` atomic. Sockets, peer authentication, route enforcement and aggregate limits are Tier 4. Revised at 6a4dfa28. | 2026-11-10 |
| I33 | IMPL | Ed25519 from BoringSSL (G42, G135) | `crypto/ed25519.nim` over nim-boringssl 0.0.14: `ED25519_verify` after our checks (S < L, A canonical and not small-order, R not small-order; cofactorless). The 7-encoding small-order blocklist is asserted equal to the one `oracle/ed25519.py` derives from the curve's torsion points. Tests: BoringSSL's own RFC 8032 and sign.input vectors, Wycheproof (150 cases), and 44 edge vectors from `oracle/gen_ed25519_vectors.py` with strict, lenient and cofactored verdicts (14 small-order keys and identity R separate strict from raw BoringSSL). nim-boringssl is not in the Nimble package list, so `logos_core.nimble` requires it by URL. | 2026-11-10 |
| I34 | IMPL | Deflate and gzip framing (PM §7.1, G41) | nim-zlib 0.3.0 for raw deflate and CRC-32 only; the gzip member around it is ours: the writer emits `1f8b0800 00000000 02ff` (no name, mtime 0, OS 255) and level-9 deflate; the reader takes exactly one member, accepts FEXTRA, FCOMMENT and FHCRC, refuses FNAME, a non-zero mtime, another OS byte, trailing data and a second member, and stops at the decompressed-size limit. | 2026-11-10 |
| I35 | IMPL | Dependency locks | New dependencies are locked with `nimble lock` on the Linux validation host (framework.lan) from a scratch git snapshot, so a dependency's NimScript never runs on the development machine; the lock is copied back and `nix run .#update-nimble-deps` regenerates `nix/nimble-deps.json`. Adding nim-boringssl and nim-zlib went this way. | 2026-11-10 |
| I36 | IMPL | The signed-claim schema (PM §4.3, §5) | `logos.package_manager.package_signature_claim` (§4.3) refers to `manifest_commitment`, which §5 defines. `package/signing.nim` accepts the §4.3 block with the `manifest_commitment` rule, found by parsing the §5 mirror (`parseSource`) and cut at its source span, as one supporting schema; the profile literal is read from that model, never typed. | 2026-11-10 |
| I37 | IMPL | PM error codes the specs leave open | Kind mismatch, a missing artifact and a path that escapes the variant are `artifact-integrity-failed` (§4 l.367, §8 l.998-999); an absolute path, a remote URL, a backslash or a `:` in the first segment are treated as escaping too. A limit exceeded, an archive structure, entry type, path or encoding outside §7.1, and paths that collide on the selected platform are `invalid-package` (§8 l.988). An unauthorized signer is `signature-verification-failed` (§8 l.1003). Check order, reading G29's stages: limits and structure (the archive, then `manifest.cbor` against its CDDL and the §4 and §8 rules, all `invalid-package`), signature, commitment, platform, then the selected variant's files (declared files, path collisions and the extracted-size limit, which depend on the selection) and artifact hashes. G29's `schema` stage is read as the configuration schema artifacts (tier 4): a commitment cannot be computed for a manifest outside its schema, so the manifest's own schema check comes first. **Revised 2026-11-11 (review against 6a4dfa28, item A22):** the configuration-schema stage moves after platform selection and after the hash check of each schema artifact it parses (PM l.360, l.1070); see the A22 note on G29. Not built. | 2026-11-10 |
| I38 | IMPL | Strict LGX reader (PM §7.1; G40, G41, G75) | `package/lgx.nim` accepts POSIX USTAR (`ustar\0` `00`) with valid checksums; types `0`/NUL (file) and `5` (directory) only; modes 0644/0755; uid, gid and mtime 0; empty uname, gname and linkname; device numbers 0; zero padding inside blocks; entries in strictly increasing path order (so no duplicates); after the two zero blocks only zeros (record padding to 10240 is fine). Paths: UTF-8, NFC, no empty, `.` or `..` segment, backslash or NUL, up to the USTAR prefix/name split (G40). The root holds only `manifest.cbor`, `manifest.cose`, `manifest.json` and `variants/`; directory entries are optional (G41). Limits are a seeded table (compressed 1 GiB, decompressed 4 GiB, 65 536 entries, entry 1 GiB, extracted 4 GiB) until real packages are measured (G75). | 2026-11-10 |
| I39 | IMPL | Unicode NFC (PM §7.1) | `base/nfc.nim` is UAX #15 composition with tables generated by `oracle/gen_nfc_tables.py` from Python's `unicodedata` (Unicode 15.1.0: 388 combining-class ranges, 2061 decompositions, 941 composition pairs; Hangul algorithmic), checked by `--check` and 958 vectors. Written here rather than adding a dependency. | 2026-11-10 |
| I40 | IMPL | Platform profile values (G73) | `hostPlatform` is the build's OS and architecture with `abi` gnu or musl on Linux, msvc or mingw on Windows, none elsewhere. A present constraint field must equal the platform's value byte for byte, so a platform without an ABI does not match a variant that names one. Path collisions: case folding over every path prefix (`unicode.toLower`) on darwin, ios and windows; on windows also reserved device names, the characters `<>:"\|?*` and control characters, and a trailing dot or space. | 2026-11-10 |
| I41 | IMPL | lcn-pkg file formats | A manifest source is CBOR diagnostic notation; `manifest build` fills each artifact `hash` from `DIR/<variant id>/<path>` and puts the canonical arrays in order (variants keep theirs). A seed file is 64 hex digits, written by `keygen` from the OS CSPRNG with mode 0600 and never overwritten. A trust file is JSON `{anchors: [{kid \| kid_hex, public_key, packages}]}`. A KID is text or `hex:<digits>`. `--emit-tbs` writes the Sig_structure bytes and `--attach-sig` takes a raw or hex 64-byte signature, giving the same object as `--key`. **Revised 2026-11-11 (review against 6a4dfa28, item C8):** the seed-file and 64-byte-signature formats above are Ed25519's and are superseded: PM l.530 maps each `kid` to a 48-byte SLH-DSA-SHA2-192s public key and l.555 fixes a signature at 16,224 bytes. The key file is now the 96-byte FIPS 205 secret key as 192 hex digits, and `--attach-sig` takes 16,224 bytes (I68). | 2026-11-10 |
| I42 | IMPL | Spec-mirror pins for PM | The §14 error-code block is mirrored and its document is a pin (`pkg-errors-document`); the `PackageErrorCode` enum is tested equal to its CDDL choice in order. The 4 MiB manifest bound is a pin read from §3. | 2026-11-10 |
| I43 | IMPL | PKG claims (Phase 3) | Claimed: §2, §3, §4, §4.1, §4.3, §5, §7.1, §8, §9, §16, plus the §11 manifest units and the §14 code enum. Unit deferrals: Nix, catalog and Storage metadata, verification caches, rotation and revocation, installed records, extraction and installation (tier 5); configuration schema validation and the §9 contract checks (tier 4); PKG-0275 (G156). PKG-0033 is out of scope (G45: manifest.json is never read). | 2026-11-10 |
| I44 | IMPL | Linking C++ dependencies | nixpkgs' Nim configuration sets `gcc.linkerexe = $CC` (and `clang.linkerexe`), so Nim's switch to the C++ driver for mixed C/C++ builds never happens under Nix, and on Linux BoringSSL's C++ objects lose libstdc++. `crypto/ed25519.nim`, the one module that imports BoringSSL, passes `-lstdc++` on Linux; outside Nix the C++ driver links and the flag is redundant. On macOS the same configuration links without it (the darwin checks pass), so the flag is Linux-only. A future C++ dependency needs the same. Dormant since I68: nothing links BoringSSL until TLS and QUIC (D28) do. **Corrected 2026-11-17 (step 5-0):** `crypto/ed25519.nim` was removed with I68, and the flag with it; `nim-boringssl` stays required in `logos_core.nimble` and imported by nothing at `3c6f3c3`, so the first module that imports it again (the `tls-tcp` carrier, Tier 5 step 5-2) brings back `-lstdc++` on Linux, and I46's static libc++ on Android. | 2026-11-10 |
| I45 | IMPL | Windows builds (G126) | The Nimble path builds and tests natively on Windows x86_64 with MinGW-w64 gcc and nasm on `PATH`. nim-boringssl assembles its Windows x86_64 sources with nasm while compiling; Windows keeps that assembly rather than BoringSSL's portable C (`-d:BORINGSSL_USE_ASM=false`), so all three desktop platforms test the same code and the TLS/QUIC modules get AES-GCM assembly later (owner's answer). `.gitattributes` stores and checks out text as LF on every platform: Git for Windows sets `core.autocrlf=true`, and mirrors, vectors and expected C headers are compared byte for byte. Tests use no `std/re`, which loads PCRE at run time and is missing from a Nim built from source. The C11 header test compiles with `$CC`, else the first of `cc`, `gcc`, `clang`. Nix does not build for Windows; llvm-mingw is not evaluated yet. Since I68 no binary compiles BoringSSL, so nasm is not needed until TLS and QUIC (D28) bring it back. | 2026-11-10 |
| I46 | IMPL | Android validation (G124) | The Android SDK is pinned in the flake from nixpkgs' androidenv; the owner chose this, which accepts the Android SDK license, and only `nix/android.nix` uses that package set: platform 35, NDK 29.0.14206865, emulator 36.3.10, the AOSP `default` x86_64 system image. Every suite is cross-compiled under orc, refc and orc+release for x86_64 and aarch64, for Android 10 (API 29) and later [IMPL]; each binary must be a PIE for its ABI that needs only libc, libm, libdl and liblog. `nix run .#test-android` (x86_64 Linux with KVM) boots a headless emulator, pushes the x86_64 suites, the repository and two nim-boringssl vector files, and runs each suite from the repository root; the aarch64 suites are built and checked, not run (G124). Nim's `linux` includes Android, so `crypto/ed25519.nim` links the NDK's libc++ statically (`-lc++_static -lc++abi`) there instead of I44's `-lstdc++`. Device runs need: tests that compile C report SKIPPED (no compiler on a device; their other checks run), `LCN_BORINGSSL_DIR` locates the Ed25519 vectors, and the PKG ownership scan reads `src/` relative to the repository root. Not part of `nix flake check`. Since I68 no binary links BoringSSL's C++, so the static libc++ flags left with `crypto/ed25519.nim`; TLS (D28) brings them back. | 2026-11-10 |
| I47 | IMPL | iOS validation | `nix run .#test-ios` (Apple silicon with Xcode and an iOS simulator runtime) builds every suite with Xcode's clang under orc, refc and orc+release for the arm64 iOS simulator, and under orc for arm64 iOS devices, for iOS 15 and later [IMPL]. Each binary must carry the right platform (7 simulator, 2 device). It creates a simulator on the newest iOS runtime, runs the simulator suites from the repository root through a launcher that changes directory (`simctl spawn` has no working directory), and deletes the simulator; device builds are not run. Xcode is the one input Nix does not pin (D31), so the build happens when the app runs, not in a derivation. The device-run test changes are I46's. | 2026-11-10 |
| R4 | SCOPE (revises D28, G135) | Spec revision 6a4dfa28 and the signature algorithm | The pin moved to `6a4dfa28` and every mirror, pin, vector and requirement ID was recomputed (pins as data: the new roots needed no code change beyond the model id). PM-06 replaced Ed25519 with SLH-DSA-SHA2-192s, which nim-boringssl 0.0.14 cannot provide. Options for the owner: (a) our own Nim FIPS 205 for SHA2-192s only, checked against NIST ACVP and a Python oracle; (b) vendor a portable C FIPS 205 implementation, as BLAKE3 is; (c) OpenSSL ≥ 3.5 beside BoringSSL; (d) liboqs. Fetching the ACVP vectors is a download. **Decided 2026-11-10 (owner: "proceed with your recommendations"):** (b). slhdsa-c (github.com/pq-code-package/slhdsa-c, commit `47451432bb04faf8217ffe8a961a75b542bf88e8`; Apache-2.0 OR ISC OR MIT; portable C90, all FIPS 205 parameter sets, passes the 1248 ACVP cases upstream) is vendored like BLAKE3, compiling only SHA2-192s and the pure and internal functions (no SHAKE, no HashSLH-DSA, which PM §4.3 forbids). Its README still calls it work in progress and not yet recommended for production; the ACVP SHA2-192s subset (ACVP-Server v1.1.0.43: 10 keyGen, 28 sigGen, 28 sigVer cases, every sigVer failure reason) is our independent check. Key generation and hedged signing take randomness from the OS CSPRNG and fail without it (PM §4.3). Ed25519 (I50) stays until the switch lands; the switch replaces the COSE profile, the trust input's 48-byte keys, `lcn-pkg` and the oracle vectors together. **Built 2026-11-10** (owner, asked whether the downloaded code may be compiled here: "You're allowed to compile the code"): see I68. | 2026-11-10 |
| I48 | IMPL | CBOR at 6a4dfa28 (G38, G59) | The decoder rejects floating-point items as `non-deterministic` unless `allowFloats` asks for the generic data model (diagnostics, the float encoder's tests). `maxDepth` counts arrays and maps only (INTERFACE §4.5.1: a root container is depth one); tags have their own `maxTagDepth` (default 1024) so they cannot nest without bound; indefinite strings add no level. `MinMaxDepth = 128`; the default stays 1024. The encoder is iterative, like the decoder, so encoding costs no call stack at any supported depth. The oracle and vectors record both classes (`expect` for Logos CBOR, `data_model` where floats differ). | 2026-11-10 |
| I49 | IMPL | LGX at 6a4dfa28 (G41, G45, G73) | A root `manifest.json` is `invalid-package`; `writeLgx` and `lcn-pkg lgx pack` no longer take one. After the two end blocks only whole zero blocks may follow. Collisions are checked with `PathRules` (ignore case; Windows names) describing the installation filesystem: `openLgx` takes them, defaulting to `hostPathRules()` (case-insensitive on darwin, ios and windows, Windows names on windows), and an installer passes its root's rules. Platform values outside `DefinedOs`, `DefinedArchitectures` and `DefinedAbis` never match, even themselves. | 2026-11-10 |
| I50 | IMPL | Package signing until R4 | **Superseded 2026-11-10 by I68:** Ed25519 is removed and packages are signed with SLH-DSA-SHA2-192s. Until then: the code still signs and verifies with Ed25519 (G42, G135) while `signingProfile()` reads the new SLH-DSA profile id from the mirror, so packages it makes conform to nothing. PKG §4.3 is claimed as `deferred:tier-3`; the Ed25519 tests are tagged as interim, without the retired requirement IDs. The oracle's COSE vectors (`tests/vectors/package/cose.json`) likewise carry the mirrored SLH-DSA profile id in the claim and an Ed25519 signature. | 2026-11-10 |
| I51 | IMPL | Payload depth in the commitment pipeline (INTERFACE §4.5.1, G59) | Validation (`choice.nim` `validateAt`), normalization (`normalize.nim` `value`), the value-tree check (`value.nim` `checkNode`) and the hash layout (`layout.nim` `layoutNode`) count maps, lists and tuples against `DefaultMaxDepth` (1024), not schema or value-tree nodes, so they support every P a binding or transport may configure. References, choice arms, fields and list or tuple elements add no level, and a reference or choice cycle with no container fails instead of looping. Each walk keeps its frames in a heap stack, visiting members depth first in the order the recursive form did (same errors, same `invalid_params` path), so native stack use does not grow with the payload depth: at P = 1024 the walks run in 32 KB. Revised 2026-11-10 after the Windows run: the first version recursed once per container and overflowed Windows' 1 MB main-thread stack under orc (debug); on macOS it needed more than 1 MB under orc and 1-2 MB under refc, more than a macOS or iOS secondary thread's 512 KB. What still grows with depth is the Nim runtime freeing a deep tree: under ORC each node's destructor frees its children recursively, about 224 KB at P = 1024 for the deepest test shape (`demo.single`) on arm64, debug or release; refc frees without recursion. That fits every common thread stack with at least 2x margin. Value objects (`parseNode`, used only by verified views) nest several CBOR containers per payload container and stay bounded by the decoder's 1024, so views of very deep values are refused; no payload path uses them. Test `[IFC-0925] [IFC-0927]`. | 2026-11-10 |
| I52 | IMPL | Per-connection transport limits (TRANSPORT §8.6, §3.4, §5.1) | `TransportLimits` is validated when made. `frameLimit` 16 MiB (over it: ProtocolError INVALID_PARAMS, close); `peerFrameLimit` 16 MiB (sender failures, I53); `payloadDepth` 1024 (I59; deeper: ProtocolError INVALID_PARAMS without detail, close); `maxInFlight` 1024 on the callee (`admitsInput` turns false for backpressure; a Request arriving anyway closes with ProtocolError TRANSPORT_ERROR, no new code per NR-08, as §8.6 l.1350 allows); `maxCalls` 1024 on the caller, abandoned calls included (a new call fails locally with MODULE_ERROR and nothing is sent, as INTERFACE l.2041 does for local capacity); `maxSubscriptionIds` 4096 on both sides (caller: local MODULE_ERROR; callee: closes with TRANSPORT_ERROR before it would forget an id). Retained correlation state is never dropped while the connection is open (§3.4 l.601-602). Documented in the `limits.nim` header. Aggregate limits are Tier 4. **Revised 2026-11-11 (review against 6a4dfa28, item A21):** at `maxInFlight` the carrier stops reading, so a Cancel or Unsubscribe for the admitted Requests stays unread. TRANSPORT l.887-888: the boundary MUST be able to process Cancel without the cancelled request's execution slot, and MUST retain bounded control capacity for cancellation or terminate the connection; l.1351: delayed admission observes cancellation. Against it, l.1357: resource bounds imply no maximum control-message latency. To decide before the Tier 4 carrier: keep reading control frames at the cap, or terminate the connection. **Needs an owner decision** (review item A21). **Re-decided 2026-11-11 (owner: "Accept all", after the Fable 5.2 session's review of the recommendations, item A21):** at `maxInFlight` the Tier 4 carrier keeps reading frames under a bounded budget, so Cancel and Unsubscribe are processed (l.887-888). Frames are one ordered stream, so the budget counts every frame read past the cap, in number and in bytes (a Request can be 16 MiB). An excess Request waits in a bounded delayed-admission queue, or the connection closes (l.1350); it is never answered with a response error, since there is no overload code (l.1357). A queued Request observes Cancel: it is treated as in flight for l.866-880 and commits CANCELLED without dispatch (l.1351). An in-flight slot stays reserved until its work ends, even after CANCELLED is committed (l.1349, l.889). The connection is terminated when the queue budget, or the output capacity needed to commit CANCELLED, is exhausted (l.888). Not built yet: `transport/session.nim` still stops reading at the cap (`admitsInput`) and closes the connection on a Request read past it; it changes with the Tier 4 carrier. **Built 2026-11-12 in I83 (step 10a part 2):** the session keeps reading at the cap, with the delayed-admission queue (`maxDelayedRequests`, `maxDelayedBytes`) and the past-cap budget (`maxPastCapFrames`, `maxPastCapBytes`) as new `TransportLimits`, and slots held until `workEnded`. | 2026-11-10 |
| I53 | IMPL | Sender size outcomes and scoped publication (TRANSPORT §2.1 l.383-393, §6) | A Request that does not fit the peer maximum is a `LocalFailure` MODULE_ERROR: no bytes are sent and no id is consumed. A success response that does not fit becomes response-err MODULE_ERROR without detail and the session stays. An Event that does not fit is not committed and `PublishError(peTooLarge)` is returned (what the void publish callback does is G165). Hello requests and responses must fit too; the callee encodes its Hello response before redeeming the ticket, so an unsendable response consumes nothing (`hrSend`, MODULE_ERROR). `publishScoped` (§6 l.882-889) goes, in subscription-id order, to every active subscription of the event on this connection, only while the request is in flight (refused once it is cancelled or its terminal Response is committed), and is all-or-none across one connection's subscriptions. | 2026-11-10 |
| I54 | IMPL | Local failure codes (TRANSPORT §2.1, §5.1, §7; INTERFACE §2.9.3) | `CallerConn.request`, `subscribe` and `unsubscribe` return `LocalFailure{code, msg}`: connection closed NOT_READY (G22); a cap reached MODULE_ERROR; a payload failing `checkPayload` (float or depth) or the schema INVALID_PARAMS; a commitment that cannot be computed MODULE_ERROR; an event outside the contract NOT_AUTHORISED; a subscription id already used INVALID_PARAMS; no larger Request id TRANSPORT_ERROR, and the connection closes. `CalleeConn.publish` and `publishScoped` return `PublishError`: closed TRANSPORT_ERROR; ended (termination, or the request no longer in flight) NOT_AUTHORISED; no destination NOT_READY; outside the contract NOT_AUTHORISED; invalid INVALID_PARAMS; too large MODULE_ERROR. **Revised 2026-11-11 (review against 6a4dfa28, items A19, A20):** the `publishScoped` mapping above is wrong for a request no longer in flight. INTERFACE l.2195: a known authority failure gives NOT_AUTHORISED, otherwise a closed invocation destination gives NOT_READY (RUNTIME l.1281-1282). So termination (`peEnded`, the route's access ended) is NOT_AUTHORISED and a request no longer in flight (`peNoDestination`) is NOT_READY, which is what `transport/session.nim` already returns. For callers, "connection closed NOT_READY" is the Tier 3 default: the classification depends on the cause, NOT_AUTHORISED takes precedence (RUNTIME l.1343-1347; TRANSPORT l.996), and the Tier 4 handle reclassifies a close whose cause it keeps (G22). | 2026-11-10 |
| I55 | IMPL | A commitment the receiver cannot compute (TRANSPORT §4.1, §8.3) | A failure inside the commitment layer is `RejectCause.rcResource`, never a root mismatch: a Request gets response-err MODULE_ERROR and the session stays; a response-ok or Event closes with ProtocolError MODULE_ERROR. Every `Reject` carries its cause: `rcUnknownTarget`, `rcScope`, `rcSubtreeRoot`, `rcSchema`, `rcValueRoot` or `rcResource`. Test `[TRN-0299]`. | 2026-11-10 |
| I56 | IMPL | Route access-scope hook (TRANSPORT §4.1, §5.1, §8.1) | `Boundary.withAccess(methods, events)` limits the method and event-subscription scope after names are resolved under the selected contract. A method outside it gets response-err NOT_AUTHORISED before any payload check; an event outside it gets a failed SubscriptionResult NOT_AUTHORISED. The Runtime supplies the scope in Tier 4. Tests `[TRN-0204] [TRN-0111] [TRN-0112]`. | 2026-11-10 |
| I57 | IMPL | Termination details (TRANSPORT §8.1 l.987-996, §5.1 l.725) | `beginTermination`: an outstanding Subscribe gets a failed result NOT_AUTHORISED and an outstanding Unsubscribe succeeds, so each operation still gets exactly one result; a new Subscribe gets a failed result NOT_AUTHORISED (l.989 names only Requests; the route's subscription access has ended, l.733-736) and its id is still recorded as used; in-flight Requests stay for the RUNTIME §9.3 policy and can still be answered or cancelled. `finishTermination` may be called at once; its ProtocolError carries neither message nor detail. | 2026-11-10 |
| I58 | IMPL | Sender-side payload check (INTERFACE §4.4, §4.5.1) | Before encoding, `encodeMessage` runs `checkPayload` on `params`, `result` or `data`: an iterative walk that refuses floats and nesting deeper than P, so this implementation never sends what its peer must reject. It is a local failure, never on the wire. | 2026-11-10 |
| I59 | IMPL | The P ceiling (INTERFACE §4.5.1) | `MaxPayloadDepth` = 1024 (`DefaultMaxDepth`), the depth the commitment pipeline supports without reduction (I51). P is configurable from 128 (`MinMaxDepth`) to that ceiling. | 2026-11-10 |
| I60 | IMPL | C mapping revision 3 readings (INTERFACE §2.1, §2.3) | Readings the text allows but does not spell out: (1) a byte string in a list element, choice arm or tuple position is a `_BSTR` aggregate holding `data` plus `len`, or `uint8_t data[N]` for an exact size N > 0 (§2.3 l.1033-1038 with l.931-957); `bstr .size 0` is the shared `logos_bstr_size_0_t`. (2) In a field-expanded inline tuple, a position needing an aggregate is `<owner>_<Field>_TU<i>`. (3) Union members follow discriminant order (ASCII label order in symbolic form, canonical order in indexed form); direct literal arms have no member, and a choice of only literals has no union (§2.3 l.1152-1215). (4) Reference labels to common types use ns-C `logos` (`logos_Schema_commitment`). (5) Shared constraint typedefs (`logos_tstr_size_1_64_t`, …) are emitted once per header outside the document guards, as identical redeclarations valid in C11 and C++, and never where `logos_types.h` declares one (`[IFC-0475]`). (6) Placement (§2.1 l.893, not canonical): groups supporting, interfaces, primary; within a group role constants, literal macros by name, forward typedefs by qualified name, definitions by dependency depth then qualified name (former G72, G155); binding constants last. | 2026-11-10 |
| I61 | IMPL | Payload depth in direct mode; §5.3 nesting (INTERFACE §4.5.1, §5.3) | `decodePayload(data, code, maxDepth)` raises a requested depth below 128 to 128; only `validator(s, maxDepth)` reports such a value as an error. Direct mode and transport mode (I52) take P from separate settings until Runtime configuration (Tier 4) supplies one. §5.3's schema nesting follows l.3946-3947 literally: a declaration body is level 1 and every contained child `schema-node` adds one, leaves included, so `[` × 127 around `uint64` is exactly 128 levels and is accepted, and one more list is rejected (`[IFC-0625] [IFC-0626]`); the earlier count left leaves out. | 2026-11-10 |
| I62 | IMPL | A module and an interface with one namespace (INTERFACE §2.1 l.898, §3.2 l.2302-2303) | A module document and an implemented interface or supporting schema with the same exact namespace are rejected as a namespace-projection collision. Both would emit the guard `LOGOS_DOCUMENT_<ns>_DEFINED` and the ROOT macros under one name with different values (two identical C identifiers, l.898), and reconstruction rejects conflicting groups for one namespace (l.2302-2303), so no valid header set exists for them. COMMITMENT l.361 and INTERFACE l.1731, l.3291 already require distinct namespaces among interfaces and among supporting schemas. | 2026-11-10 |
| I63 | IMPL | lcn-gen limits and reverse-mapper helpers (INTERFACE §3, §5.3) | Documented in lcn-gen's usage text and the `cmap.nim` module doc: no identifier-length limit, the §5.3 bounds, and a mapping-limit error past `UINT32_MAX` arms; on any failure nothing is written (inspection items IFC-0624, 0637, 0898, 0899). `names.decodeNamespace` (`_NS_` back to `.`) and `names.decodeModule` (`_U` back to `_`) require that re-projection reproduces the component, so `a_Ub` is rejected (`[IFC-0901]`); they exist for the Tier 5 reverse mapper. Link-time and `dlsym` checks of exported-function distinctions (IFC-0897) wait for generated functions (Tier 4). | 2026-11-10 |
| I64 | IMPL | Method parameters (INTERFACE §2.3 l.1059, §2.4 rules 2-10) | `iface/cmap.nim` derives a method half's parameters from the same members as its struct form (each member keeps its role and unescaped name), adds `in_`/`out_` once and then escapes (§2.1). Inputs keep the member type except struct representations, empty values included (`const T*`), and exact-size byte strings (`const uint8_t (*)[N]`); outputs point to it, except lists (`<element>**`, rule 9) and exact-size byte strings (`uint8_t (*)[N]`). Reading: rule 8 spells no output form for an unbounded byte string; §2.3 gives unbounded and ranged byte strings one representation and the ranged pointer is a `const uint8_t*` typedef, so the output is `const uint8_t**`. Worth an editorial note to the owner. Test `[IFC-0864] [IFC-0888]`. | 2026-11-10 |
| I65 | IMPL | Where method and module symbols go (INTERFACE §2.1 l.891-897, §2.4, §2.6) | Each document's `_FN_t` typedefs end its guarded group, so an interface header carries them without a provider; a module binding's `_CALL_` functions (primary, then implemented interfaces) and its `_MODULE_` symbols follow the binding constants, unguarded. Provider symbols (`call_surface`, `free`, `dispatch`) only when the primary or an implemented interface declares a method or event (§2.6 l.1545). The optional `_MODULE_apply_configuration` and `_MODULE_async_api` are not declared: the module author declares the ones it exports. Tests in the `ifc.c-abi` suite, including a C and C++ link of two 63-byte module names. | 2026-11-10 |
| I66 | IMPL | Native ABI check codes and order (INTERFACE §2.4, §2.6, §2.9, §5.2) | `abi/checks.nim` holds what each side checks before it uses what the other hands it. Where the spec fixes the code, it is used: VERSION_MISMATCH for an unsupported version or too small an extent (l.3805-3807, l.3819), MODULE_ERROR for a null vtable, state or required operation from the binding's producer (l.3820), INVALID_PARAMS for malformed callback or option input to `prepare_call` (l.3911), MODULE_ERROR for a result and output combination a dispatch or typed-call caller rejects (l.1343, l.1764). Where the spec requires only a nonzero code or says only "reject", the same split applies: in the initialization input a null input, `runtime_control`, `invocation_access` member or (with declared events) `publish` is MODULE_ERROR, malformed configuration bytes or a non-UTF-8 `state_dir` INVALID_PARAMS; a provider invocation or caller view that breaks its rules is MODULE_ERROR; a rejected Runtime Control or route `call` combination (l.3830) and `_MODULE_init` combination (l.1635) are MODULE_ERROR. A null options or callbacks pointer counts as malformed input, INVALID_PARAMS: the text does not say whether a null options pointer means defaults (worth an editorial note). A module caller's identifier views must be nonempty UTF-8. Order: null pointer, then version, then extent, then null members, then values; the first failure is reported, so a short vtable whose later operations are null is VERSION_MISMATCH. An invalid combination or status carries no diagnostics; a valid failure status keeps its message and detail, as `checkedProviderStatus` does. Tests: the `ifc.abi-*` suites in `tests/test_abi.nim`, which also compare every struct's size, alignment and field offsets with the generated `logos_types.h`. | 2026-11-10 |
| I67 | IMPL | Validating the provider call-surface descriptor (INTERFACE §2.6 l.1680-1746) | `iface/provider.nim` checks the limits, the closed maps (no CDDL wildcard), the field types and each entry's supporting order first. It then gathers every supporting entry once, rejecting a namespace whose entries differ in document or root. The primary document, the interface documents and those supporting documents go to `acceptBinding` as one construction input set, so every §1 and §5.3 rule applies: roles, `_module` against `_MODULE_name()`, `_implements` exactness, reserved and colliding bare method names, unused supporting schemas and the duplicate interface namespace (I62). Each claimed commitment and supporting namespace is compared with its recomputed value; each entry must list exactly the supporting schemas its document uses (the primary entry: all of them); interfaces must be in derived namespace order. Last, the bytes must equal the binding's own encoding, so a check missed above cannot let a non-canonical descriptor through. `matchesContracts` compares supplied contract references with the descriptor as an optional primary root plus a set of interface roots. Not built here: calling the symbol (non-null `out_len`, the same bytes on every call), which is Tier 4. Tests: `tests/test_call_surface.nim`. | 2026-11-10 |
| I68 | IMPL | SLH-DSA-SHA2-192s package signing (R4; PM §4.3) | `crypto/slhdsa.nim` wraps the vendored slhdsa-c (`src/logos_core/crypto/slhdsa/`, commit `47451432bb04faf8217ffe8a961a75b542bf88e8`, refreshed by `tools/update-slhdsa.sh`; four C files: SHA-256, SHA-512, the SHA2 instantiation and the FIPS 205 algorithms) and exposes only SHA2-192s: pure sign and verify with a context, the internal functions for ACVP, `keyPairFromSeeds`, `generateKeyPair`. Key generation and hedged signing take a `RandomSource` (default: `std/sysrand`) and fail when it cannot supply bytes. `tests/test_slhdsa.nim` runs the NIST ACVP-Server v1.1.0.43 SHA2-192s cases extracted by `tools/extract_acvp_slhdsa.py` (10 keyGen, all 28 sigVer, 2 sigGen per group in debug and all 28 in release). The profile (`package/signing.nim`): protected header exactly `{4: kid}`, any `alg` refused before the signature is checked, `external_aad` = the mirrored profile id, pure SLH-DSA with the empty context over the Sig_structure, 16,224-byte signatures and 48-byte keys taken as given (no other length repaired). `signManifest` signs hedged and checks the signature against the key's own public key before returning it. `signerRecord` derives the §4.3 `package_signer` record; retaining and reporting it is tier 5. `lcn-pkg`: the key file is the 96-byte FIPS 205 secret key as 192 hex digits, created owner-only before the key is written; `--attach-sig` takes 16,224 bytes. `oracle/slhdsa.py` is an independent FIPS 205 SHA2-192s in Python (checked by the oracle selftest against ACVP keyGen, every sigVer verdict and two sigGen cases); it signs `tests/vectors/package/cose.json` deterministically and the Nim side must reproduce those signatures byte for byte. Signing takes about 0.8 s with this portable code (verification 0.6 ms), so tests sign as little as they can. nim-boringssl stays locked for TLS and QUIC (D28) though nothing imports it now. slhdsa-c's README calls it work in progress, not yet for production; its exported names (`sha2_256_init`, `wots_sign`, ...) are unprefixed, and a clash with another C library would fail the link. | 2026-11-10 |
| I69 | IMPL | Catalog records and dependency resolution, sans-I/O (PM §5, §6, §11) | `package/records.nim` decodes and encodes `package_identity`, `package_source`, `package_catalog_entry`, `package_inspect_record` and `resolved_package_dependency` against the mirrored CDDL: one document headed by PM §15's `_module` rule with the §5, §4.3, §6 and §11 rules, and the §4 manifest as its supporting schema (a supporting schema may not reference another document, INTERFACE §1.1). Beyond the CDDL: identity versions are package versions, `provenance_object` differs from `object`, and an inspection record is built only from a `VerifiedPackage`; its decoder recomputes the manifest commitment. `package/resolver.nim` resolves one root over the installed records, the catalog entries and the protected limits; an `Inspector` answers eligible, ineligible or unavailable for a source record (`lgxInspector` wraps `openLgx`: a Nix source is `unsupported-source`, an archive `fetch` cannot return is unavailable). The search keeps its frames on the heap and logs nothing outside its counters. Readings of the text, none a gap: a name joins the partial closure when a candidate is bound to it, and the name limit is checked before that binding; a name's depth is the fewest edges from the root through bound packages when it is chosen, checked before any of its records is inspected; a candidate is one exact identity after eligibility and commitment selection, charged once per name and version, and an ineligible record is never charged; every catalog record of an identity is inspected, in ascending source encoding, when the identity is reached (also when it is installed, so a conflicting commitment is never skipped), and one that cannot be obtained fails the operation with `package-unavailable`; a record whose manifest names another identity than its catalog entry is ineligible (`invalid-package`); the installed-identity check follows the consideration charge and precedes the binding. The root is not a backtracking point: it counts as one name at depth 0, one consideration and one attempt, and its edges are always selected afresh (an installed root's conflict is the operation's rule); an explicit version reports its record's own error when none is eligible, an omitted one takes the highest eligible normal release, and a source whose manifest differs from the requested package or version is `invalid-request`. Installed dependencies keep their recorded edges as exact requirements, so a version they exclude is never inspected or charged (G167). Protected policy carries the limits as a map with exactly `assignment_attempts`, `candidates_per_name`, `dependency_depth` and `partial_closure_names`, each a positive integer (larger than int64 counts as int64's maximum); anything else is a configuration error. Not built: catalog documents and their refresh (G90), fetch and storage locators (G91), installation and the methods (tier 5). Tests: `tests/test_resolver.nim`; PKG §6 and §11 claimed. **Revised 2026-11-11 (review against 6a4dfa28, item A1):** a root source whose manifest declares another identity is `invalid-package` (PM §8 l.1074-1079), not `invalid-request`. | 2026-11-11 |
| I70 | IMPL | Schema tables per thread; gcsafe forward declarations | Tables built from the mirrors (the pinned schema context, the common schema model, the transport envelope, the manifest, claim and record schemas, every generated module's schema and every kit's validator) are per thread: `base/perthread.nim`'s `perThread(accessor, T, load)` keeps one copy per thread, built on that thread's first use. orc's reference counts are not atomic, so one global table read by several threads at once races on its counts, and the §2.8 entry points of a kit module run on any thread. Each module still builds its table at load (`discard accessor()`), so a mirror that no longer loads fails at start; a thread pays for its own copy once. The forward declarations of the recursive procs in `cddl/syntax.nim` and `iface/cmap.nim` say `{.gcsafe.}`: effect inference does not see through a forward declaration, so nothing that reached them was inferred gcsafe. Generated modules push `gcsafe` as well as `raises: []`. `cmap.cString` is now `cStringLiteral`: Nim ignores case after an identifier's first letter, so `cString` and the `cstring` type were one identifier wherever both were visible, which broke the generated kit template. Test: `tests/test_nimgen.nim` "concurrent use" (4 threads encode, decode and check details). | 2026-11-11 |
| I71 | IMPL | Nim module kit, part A: exported identity, lifecycle and provider symbols (INTERFACE §2.6–§2.8, App A.3, A.4) | `lcn-gen kit [--out:DIR] [--import-prefix:P] [--system] PRIMARY.cddl` (with the interface and supporting documents the other commands take) writes `<header>_types.nim` and `<header>_kit.nim` (`codegen/kitgen.nim`, runtime `codegen/kitrt.nim`). The author instantiates `export<Module>(T)` once with a `ref object` type `T` and defines `initModule(T, ModuleInit): Result[T, InvocationFailure]`, optionally `destroyModule(T)`, and one handler per exposed method named by its bare name (dots become underscores) taking and returning the generated request and response types; the kit adds `publish`/`publishScoped(ModuleServices, <Event>)` per declared event and `caller`/`isCancelled` from the invocation context (§2.9.3). Exported with C linkage: `_MODULE_name`, `_init`, `_destroy`, and for a provider `_call_surface` (the embedded descriptor), `_free` and `_dispatch`. Choices: init checks its input with `abi/checks` (VERSION_MISMATCH, MODULE_ERROR or INVALID_PARAMS as §5.2 maps them), copies the state directory and configuration, allocates the context before calling `initModule` and frees it if that fails; a module whose call surface declares events refuses a null publish callback, so the kit never holds one it could call (IFC-0220). Dispatch checks the request against the method's request schema (INVALID_PARAMS with its detail), answers METHOD_NOT_FOUND for `schema` and any unknown name (the kit is never told the route's selected contract, App A.3), encodes the response with the generated checked encoder (a response outside its schema is MODULE_ERROR) and returns it in a buffer that `_MODULE_free` releases on any thread. A failure's message is clipped to 512 bytes at a UTF-8 boundary; one that is not a valid status (code OK, a NUL, invalid UTF-8, detail its code does not allow) becomes MODULE_ERROR without diagnostics; message and detail live in thread-local buffers until the next kit call on that thread (§2.7). Every exported entry starts with `kitEnter` in its own frame: `setupForeignThreadGc`, and under refc `nimGC_setStackBottom` at that frame. A refc shared library's runtime starts in its load-time constructor, inside `dlopen`, and records the stack bottom there; calls from shallower frames were outside the scanned range and crashed (`setupForeignThreadGc` does nothing on the loading thread); `test_kit_dylib` found it. Contexts and response buffers come from the C allocator, not Nim's, since a context may be destroyed on another thread after the creating one exited (nim-ffi's `alloc.nim` makes the same choice). The instance is shared by all calls on its context and its handlers synchronize their own state. refc has one heap per thread: handlers on other threads may read what `initModule` stored but must not store GC'd values into the instance; the tests create and destroy contexts on other threads under orc only. A module ships as `--app:lib --nimMainPrefix:lib<name>`, so several Nim modules and a Nim host keep distinct `NimMain`s in one process (G106). Not built: the typed `_CALL_` functions (mandatory for a provider, §2.4; part B), `_MODULE_apply_configuration` and `_MODULE_async_api` (optional), typed call helpers (App A.5; part C), kits for an interface-only provider, and a thread-confined mode for refc and chronos modules that hands each call to the module's own thread (nim-ffi's model). Tests: `tests/test_kit.nim` (in process) and `tests/test_kit_dylib.nim` (both kits built as shared libraries and loaded with `dlopen`, called from the loading thread and from threads their runtimes have not seen); IFC §2.6–§2.8 module-side units claimed. Upstream (Nim): the refc reset-before-read that `failureResult` avoids is nim-lang/Nim#25993, fixed in 2.4.0 and devel but not in 2.2.14 or on the 2.2 branch; the refc `--app:lib` stack-bottom crash still happens on 2.4.0 and on devel `d61298c` (minimal repro kept for a report; nim-lang/Nim#6208, closed as stale, covered the foreign-thread case). **Revised 2026-11-11 (review against 6a4dfa28, item A2, A27):** Not built: the CONFIG l.228-230 initialization glue (embed the configuration-schema commitment, compare it with the delivered one, then decode and validate the whole value before module code runs) and `_MODULE_apply_configuration` (CONFIG l.303). Until then a kit module with a configuration binding checks its configuration in `initModule`, and the Runtime slice rejects records that declare configuration. Under refc a handler on a thread the module's runtime has not seen must not store GC'd values (INTERFACE l.1989-1992 fixes no calling thread), so the §2.6-§2.8 claims are unconditional for orc builds and carry that limit for refc builds. | 2026-11-11 |
| I72 | IMPL | Nim module kit, part B: typed provider functions (INTERFACE §2.3, §2.4, §2.7.1) | For a provider, the `export<Module>(T)` template now also defines one `logos_<module-C>_CALL_<namespace>_<Method>` per method of the primary and every implemented interface, with exactly the generated header's parameters, over the same handlers as `_MODULE_dispatch`. A typed call converts its C inputs to the request's CBOR value, checks it with the method's request validator exactly as dispatch does (the same INVALID_PARAMS outcomes, literals, UTF-8 and depth limit), runs the handler, checks the response against its schema (MODULE_ERROR otherwise) and converts it into the C outputs. Both conversions go through checked CBOR values rather than the Nim types, so one validator decides for C callers and dispatch alike. The converters are generated per kit (`codegen/cmirror.nim`, runtime `codegen/callrt.nim`) over Nim objects with the C layout of each §2.3 declaration ("mirrors", positional members); the common schema's mirrors are `codegen/common_mirrors.nim`, written by `nimble regen`. `tests/test_kit.nim` compiles a C program against the generated headers (now fixtures in `tests/generated/`) and checks every mirror's size, alignment and member offsets. A C discriminant maps to its canonical arm explicitly (`cmap` `caseArms`); one that names no arm is INVALID_PARAMS before any payload is read. Inputs: a null text, struct or array pointer, a null required recursive pointer, or a null byte-string or list pointer with a nonzero length or count is INVALID_PARAMS; a zero length or count may come with any pointer, null included; a value whose presence flag is false is never read; lengths and counts above 2^31−1 are refused; an empty value's `_empty` member is ignored on input and zero on output (IFC-0137). Converters stop at the payload depth limit (1024), which also ends a cyclic C value. Outputs: one `CallArena` per call, `calloc` blocks chained through a 16-byte header. On success the arena becomes the response owner: its state is the newest block, and its release frees the chain with the C allocator only, so any thread may clear it, and distinct owners concurrently. A response that allocated nothing gets the empty owner. Empty byte strings and lists point to static storage, never null. Outputs are built in locals and copied to the caller's objects only on success. On failure the arena is released and the owner and outputs stay as the caller initialized them. A response text containing U+0000 has no canonical C value: MODULE_ERROR. A null module, owner or output pointer is MODULE_ERROR before the handler runs; the spec assigns that misuse no code (l.1610). The response check and arm resolution use a per-thread schema copy (`kitSchema`, as in I70). Stack: the converters, like the Nim codecs dispatch uses, recursed once per nesting level, so a provider entry at the default limit needed up to 1 MiB of stack (measured on arm64 macOS: a valid call at depth 1024 needed 512–768 KiB debug, 384–512 KiB release); since I79 both keep their frames on the heap. Test hooks: `arenaBlocks()` counts live blocks across threads; `failArenaAllocation(n)` fails the n-th allocation on the calling thread. Not built: typed call helpers and §2.7.2 cleanup helpers (App A.5; part C), `_MODULE_apply_configuration` and `_MODULE_async_api`. Tests: `tests/kit/typed_harness.c` calls every typed function as a C caller does: inputs built in C, the owner and every output zeroed first, results and outputs read back as text. `shapes_module` covers every §2.3 shape: literals, exact, ranged and unbounded byte strings, lists, tuples, inline maps and choices, optionals, recursive trees and common types. In process (`test_kit`) the tests cover round trips, a failure at every allocation of a full response rolled back, invalid inputs that never reach the handler, the depth limit on a thread with 512 KiB of stack (1 MiB before I79), owners released on other threads, and concurrent calls. `test_kit_dylib` covers typed calls through `dlsym` under orc and refc. `tests/kit/typed_linked.c` assigns each declared provider symbol to its contract typedef, so a mismatch fails to compile. IFC §2.3/§2.4/§2.7.1 provider-side units claimed (gate 432/432). **Known deviation (review against 6a4dfa28, item A26, 2026-11-11), resolved the same day by I79:** a provider entry could need up to 1 MiB of stack at the kit's default depth, more than a secondary thread's default on macOS and iOS (512 KiB), while INTERFACE l.3154-3155 asks for bounded resources at every supported depth and l.1991 fixes no provider-call thread. The converters and codecs now keep their frames on the heap, and the depth tests pass on 512 KiB threads on macOS and Linux in every build (I79). | 2026-11-11 |
| I73 | IMPL | Nim module kit, part C: typed call helpers and their cleanup helpers (INTERFACE §2.1, §2.7.2, §5.2, App A.5) | `lcn-gen calls [--out:DIR] [--import-prefix:P] [--system] PRIMARY.cddl [--interface:…] [--supporting:…]` writes `<stem>_types.h`, `<stem>_types.nim`, `<stem>_calls.nim` and `<stem>_calls.h` for a provider's accepted set (a module document with its interfaces and supporting schemas, or a standalone interface document), all or nothing (`codegen/callsgen.nim`, runtime `codegen/invokert.nim`). Every method of the primary document and of each implemented interface gets helpers named by its defining contract's §2.1 component; the route decides which of them it accepts, and a helper neither selects a provider nor acquires a route (App A.5). Nim callers: `invoke(route, <Request>): Result[<Response>, InvocationFailure]`, overloaded on the request type. C callers: `lcn_invoke_<namespace>_<Method>(route, response_owner, in…, out…)`, with the provider function's parameters after the route, and `lcn_clear_<namespace>_<Method>(response_owner, out…)`, each with a `_fn` typedef. Names start with `lcn_`, not with `logos_` as App A.5's example does: the names are implementation-defined (§2.1 l.886, and App A is informative), and the `logos_` prefix belongs to the ABI (IFC-0057). `<stem>_calls.h` includes `<stem>_types.h` and is never part of the header set for reconstruction; generating it changes no header and no root (IFC-0627, IFC-0628). The C helpers are defined only where a Nim module instantiates `export<Stem>Calls()`. Exporting is opt-in because two sets that share an interface define the same names: `sensor_module` and `metrics_provider` both define `lcn_invoke_metrics_provider_Snapshot`. A call (`routeCall`): (1) checks the route handle as its consumer must (`checkRoute`: MODULE_ERROR or VERSION_MISMATCH); (2) encodes the request as deterministic CBOR and decodes those bytes strictly once more, so a request without one deterministic-CBOR item fails locally with INVALID_PARAMS and no detail before the route is called; such a request is text that is not UTF-8, nesting past the depth limit, or a C input the converters cannot read (a null text, an unknown discriminant, a cyclic value); (3) checks nothing else locally: the provider validates the request against its schema; (4) sets the outputs to null and zero (IFC-0489) and calls `call` with the bare method name; (5) checks the result and buffer together (`checkOutcome`). Any combination other than a valid failure without a buffer, or LOGOS_OK with a buffer, is MODULE_ERROR with the message `route call: <reason>`, and nothing is released (I66). A valid failure is returned with its code, message and detail; (6) after a success, decodes the buffer into Nim-owned memory and passes the exact pointer and length to `release_response` once (IFC-0491). It does so even when the bytes are not a response, since a success-shaped result has already transferred the buffer (compare IFC-0679); (7) checks the value against the response schema: a value that is not one deterministic item, or that the schema rejects, is MODULE_ERROR. The C helper then fills the outputs through one arena, as I72's typed provider functions do: outputs are built in locals and copied on success; on failure the arena is released and the owner and outputs stay untouched; a response that allocated nothing gets the empty owner. Decoded storage needs neither the route nor the module, and its release frees it with the C allocator only (IFC-0701, IFC-0704, IFC-0705). A null route, owner or output pointer is MODULE_ERROR before the route is called, as in I72. A result's message and detail stay in the calling thread's storage until its next helper or kit call (IFC-0260). Cleanup clears the owner, then zeroes each output object, never reading through them; a null owner or output is skipped, and a second call is harmless. Each calls module has its own per-thread schema copy (`callsSchema`) and its own mirrors and converters. Not built: helpers over the route's asynchronous operations or Runtime Control bindings, and event publication and subscription helpers. Tests: `tests/test_calls.nim` (22 tests) covers: Nim `invoke` through a direct route into each kit module; every typed-harness variant run again through the C helpers (`tests/kit/calls_shims.c`, `calls_linked.c`): round trips of every C shape, invalid inputs that never reach the route, an allocation failure at every point of a full response, the depth limit on 1 MiB of stack, owners that outlive the route and the module, and cleanup of real, zero-initialized and garbage output sets; routes that break their side of the contract: LOGOS_OK without a buffer, with an empty buffer or with a message, a failure with a buffer, an unallocated code, and a success whose bytes are not a response; four threads on distinct routes to shared contexts. Its test route (`tests/support/testroute.nim`) checks that each release names the exact buffer and length it handed out, and overwrites released buffers. `test_kit_dylib` loads the helpers from a library of their own and calls the module libraries through routes, including from threads none of the three runtimes has seen. `test_codegen` checks that each `_calls.h` declares exactly one invoke helper, one clear helper and their typedefs per exposed method, and no `logos_` symbol. It also compiles each header as C17, C23, C++17, C++20 and C++23, asserting that each helper has its typedef's type. Claimed: IFC §2.7.2 and IFC-0260, IFC-0489, IFC-0491, IFC-0627, IFC-0628 (gate 449/449). **Revised 2026-11-11 (review against 6a4dfa28, item A24, A25):** LOGOS_OK with a non-null buffer hands the buffer over even when `checkOutcome` rejects the result (a message on success, a zero length), so the helper releases it exactly once (`abi/checks` `transfersBuffer`; INTERFACE §5.1 l.3364-3368, §5.2 l.3831); a failure code never hands one over. The helpers' encoders write each required literal, whatever its C member holds (§2.3 l.1096); provider-side conversion still reads the member, so validation rejects another value. | 2026-11-11 |
| I74 | IMPL | Runtime slice step 1: the internal Module Loader for direct realization (RUNTIME §1.2, §2.1-§2.4, §3.6, §13.3; LOADER §3-§7, §9-§11) | `runtime/realizer.nim` is shaped like the Loader contract (realize, release, get_status, its descriptors, records and error codes) but is an in-process object owned by the Runtime thread, which serializes its calls (LOADER §11). It advertises `direct_static` and `direct_dynamic`; `hosted_dynamic` is `unsupported-strategy` before anything is read, and `force` is `invalid-request`. Static code: `runtime/native.nim` `checkStaticRegistration` applies §13.3 without running module code. A canonical name is `logos_<module-C>_MODULE_<suffix>` with one of the eight §2.6/§2.9 suffixes, or `logos_<module-C>_CALL_<component>` with a lower-case first letter and an underscore. One table holds one `<module-C>` family. An unknown binding identifier is `invalid-request` (a request no retry can satisfy); a registration for another module, or a `_CALL_` entry the call surface does not define, is `abi-invalid`. Binding (`bindNative`) reads provider-ness from the code: all of `_MODULE_call_surface`, `_MODULE_free` and `_MODULE_dispatch` or none, and some of them is `abi-invalid`. The Runtime compares the surface with the record's expected contracts (step 2). `_MODULE_async_api` is probed and validated for a provider; a consumer-only module's is never called, as it has no provider operations to invoke. Dynamic code: `runtime/artifact.nim` copies the library into a private `mkdtemp` directory (0700), makes the copy read-only, hashes the copy with BLAKE3 and maps it with `RTLD_NOW \| RTLD_LOCAL`. There is one binding per hash suite, digest and module for the realizer's lifetime, never unloaded (TF-03), and errors name no path (LOADER §10). Initialization: input v2 with the Runtime's services and the mapped state directory (`<state root>/<assignment>`, 0700, assignments limited to `[A-Za-z0-9._-]` [G143]); configuration is always absent (CONFIG is not built). Every result and context combination INTERFACE forbids is `realization-failed`. LOGOS_OK with a context but an invalid status first destroys that context once, as A24 releases a buffer. A failure that also returned a context leaks it, since destroy is only for a successful init. Every direct failure is cleaned before `realize` returns, so no failed realization is retained. Realization identifiers are `r-<16 random hex digits>-<counter>`. `realize` runs `_MODULE_init` on the calling thread through `initInstance`, which takes plain values only, so step 2 can run it on a Runtime thread of at least 1 MiB under the 120 s startup deadline. The kit's export template also defines `<module>StaticSymbols()`, its registration table. Tests: `tests/test_realizer.nim`. | 2026-11-11 |
| I75 | IMPL | Runtime slice step 2: the module-instance registry and lifecycle for direct realization (RUNTIME §3.3, §3.4, §3.6, §3.7, §8, §9, §9.1, §9.3 create, start, stop, report_failure, §10.2) | `runtime/engine.nim`, with `runtime/records.nim` (module-instance records), `runtime/authz.nim` (the authorizer, G52) and `runtime/bell.nim` (a wake-up with a deadline). **Threads.** One Runtime thread owns every record, the realizer and the authorizer and applies every mutation, so the mutations on one target have one total order: the order it takes them in (§9.1). Callers on any thread send value-only requests through a channel and wait for exactly one reply. Module code never runs on the Runtime thread: binding (the platform loader, `_MODULE_name`, `_MODULE_call_surface`, `_MODULE_async_api`), `_MODULE_init` and `_MODULE_destroy` run on up to 64 worker threads with Nim's default stack (2 MiB less 4 KiB on 64-bit, above I72's 1 MiB), so a module may call back into the Runtime from them, and a worker that never returns holds only its own thread. Workers hand back plain values: `native.nim` splits binding into `probeNative`, which runs module code and returns a `NativeProbe` without refs, and `completeNative`, which runs no module code and builds the schema graphs on the Runtime thread. ORC keeps cycle roots per thread, and a cyclic `ref SchemaNode` graph built on a worker and moved crashed in `unregisterCycle`. Reply channels come from a per-engine pool and are closed only by `close`. Nim's `Channel.send` signals after it releases the lock (2.2.14 and devel), so a channel freed after `recv` took the sender's late signal in freed memory, usually the next call's channel, and that call's wake-up was lost: the release build hung in about one run in ten. With the pool it ran 200 times without a stall. The bell allocates its mutex and condition variable with C's sizes, because std/posix on macOS declares both as `int`, so Nim's `sizeof` is 8 where C says 64 and 48. The three Nim findings are drafted, not filed. **Deadlines** (G61, re-decided 2026-11-11 under review item A18). The startup deadline is 120 s from the accepted execution attempt, through binding, `_MODULE_init` and the contract check. On expiry the instance enters `error` with `startup-timeout`; module code is not interrupted; a context it returns later is destroyed through the realizer; until then `start` is NOT_READY (cleanup pending, §3.4 l.585-588, l.664-669). A stop waits up to 10 s for `unloaded`, then replies with `stopping`. Shutdown waits up to 10 s, then records `cleanup-timeout` for every instance still loaded, ready or stopping, and releases nothing still in use (§10.2 l.3838). **Records.** `create` takes records from the host origin only (G55). `checkRecord` checks: the module name; a static binding of 1 to 128 bytes; a dynamic artifact's id, path and hash suite; hosted strategies rejected; unique implemented contracts; requested permissions (names of 1 to 128 bytes, unique; constraints of 1 byte to 1 MiB of deterministic CBOR; reasons of at most 512 bytes); a path-safe state assignment not shared with another instance (§8 l.1468); a record that declares configuration rejected (CONFIG is not built). Instance ids are 1 to 128 UTF-8 bytes; a missing one becomes `m-<random prefix>-<n>`. A new instance is `unloaded` with intent `uninitialized`. **Start.** A loaded or ready instance is returned unchanged (§9.1 l.1837); a stopping one, or one in `error` with cleanup pending, is NOT_READY. Acceptance sets intent `requested` with its origin and commits it (§9.3 l.3644-3647). A prerequisite that is not ready (§3.7, from the host's ordering input) gives NOT_READY and keeps the intent. Execution authorization (§3.6 step 3) comes next: a deny or an evaluation failure gives NOT_AUTHORISED, as G168's interim says. Then the instance is `loaded` and the engine binds, initializes and compares the contracts (§3.3): the expected primary root and every expected interface root must be on the validated call surface, and a record with no expected contract gets no provider record. Then `ready`. `start` replies with the outcome: `ready`, `error`, or `stopping` when a stop overtook it. `_MODULE_init` failing and a contract mismatch are `initialization-failed`; every other Loader error is `loader-<code>` (§9.3 l.3753-3754). A failed or expired attempt's context is destroyed, and other instances keep running. **Stop and report_failure.** An explicit stop sets intent `stopped`. A loaded attempt can no longer become ready. A ready instance is released through one `_MODULE_destroy` on a worker. `error` with nothing to clean becomes `unloaded` with its failure cleared. `report_failure` is bound to the attempt token (`a-<prefix>-<n>`): a token never issued for the instance is NOT_AUTHORISED; one that is not current, or an instance that is not loaded or ready, is NOT_READY; a report during initialization keeps that realization from becoming ready (l.3604). An expected execution revision is compared with acceptance; a mismatch is INVALID_PARAMS (§9.1 l.1832-1833). Every committed change advances the instance's execution revision and joins an ordered log of whole snapshots (4096 kept). **Authorization** (G52: one interface, allow-all plus test rules that deny or fail matching requests). A module origin's lifecycle request is authorized; for a module consumer an unknown target is NOT_AUTHORISED, like a refusal (§9.3 l.3661-3662), while for the host it is INVALID_PARAMS. Answers carry `d-<n>` decision ids and keep an evaluation failure apart from a deny; 4096 are kept. **Shutdown** (§10.2). Admission closes (create, start and stop are NOT_READY). Dependents are released before their prerequisites, otherwise in reverse creation order, and intent is kept. `shutdown` returns once everything is released or its `cleanup-timeout` is recorded. The Runtime thread keeps running after that and still destroys contexts that module code returns late. `close` stops it and frees the engine; it returns false and keeps the engine allocated while a worker is still inside module code. Not built: Runtime Control (step 3), routes and provider calls, events, the host API, `recover_module` and `retire_module`, persistence of execution state, CONFIG, and the Capability Authority. Tests: `tests/test_engine.nim` (20 tests in 5 suites, orc, refc and release), whose names carry the RUN requirement ids. | 2026-11-11 |
| I76 | IMPL | Runtime slice step 3: Runtime Control and direct routes (RUNTIME §3.4, §4.1-§4.3, §7.5, §9, §9.2, §9.3 get_self, get_execution_permissions, establish_route, renew_route, close_route, start_module, stop_module, report_failure, shutdown_runtime; INTERFACE §2.5, §2.9.3, §5.2) | `runtime/bindings.nim` (the C side: the Runtime Control binding, invocation access and route handles), `runtime/routes.nim` (route records, selected contracts, access checks, `request_key` retention), `runtime/plumbing.nim` (the messages, requests and replies, moved out of `engine.nim`) and `runtime/rc_types.nim` (generated by lcn-gen from the new RUNTIME and CONFIG mirrors, `spec/mirrors/RNT`, `spec/mirrors/CFG`, kept current by `nimble regen` and `test_nimgen`); lcn-gen's Nim output can export its per-thread schema (`schemaAccessor`), and `codegen/nimrt.commitment` and `iface/surface.acceptSchemaResponse(data, expected)` are added. **Identity.** The Runtime instance id is host-assigned (`EngineConfig.runtimeInstanceId`); `newRuntimeInstanceId` makes a lowercase UUID version 4 (l.2669), and `defaultConfig` makes a fresh one each time until execution state is persisted. **Runtime Control binding.** One per execution attempt (`AttemptServices`, on the shared heap), in the initialization input with the invocation access. Every request is checked on the caller's thread against the method's request schema and its commitment computed (l.225-230), and so is every successful response (l.3747); what depends on Runtime-owned state is one request to the Runtime thread. Performed: get_self and get_execution_permissions (caller-bound; `unavailable`, since no operating-system permission enforcement is installed), establish_route, renew_route, close_route, start_module and stop_module (selection by instance, by name after observation authority over the name, or by provider, which names a local implementation and is INVALID_PARAMS after authorization), report_failure, and shutdown_runtime (answered, then the shutdown starts). Other methods of the contract are MODULE_ERROR, as are subscribe, unsubscribe and prepare_call; connect_remote validates the endpoint and answers NOT_AUTHORISED, since no remote Runtime is enrolled. The order of checks is G171's interim. **Routes.** Candidates are the provider records whose module record expects the contract, in creation order. `single` selects first (the first ready candidate, else the first) and authorizes only that one (l.3093-3094); `all-runtime-visible` authorizes discovery and then each candidate, and is `partial` when one is omitted. Route ids (`route-<prefix>-<n>`) are allocated before the decision (l.3155). Only ready routes are returned (l.3145), with no invocation descriptor (l.3004). Access lists are checked against the selected contract. Successful results are kept for `request_key` replay, 4096 per consumer. An establishment that returns nothing is G169; renewal replaces the decision id, and a denied renewal revokes the route (G170); close_route is one decision on the route, for its consumer or any other. **Route handles.** `materialize_route` rebuilds the selected contract from a `logos.schema_response` on the caller's thread and then checks ownership, the route decision for `materialize_route` (l.982-984), readiness and the root (VERSION_MISMATCH). A handle keeps the schema documents; each thread loads its own validator, cached by root. A call is admitted on the Runtime thread and joins its provider's in-flight count; then, on the caller's thread, the request is validated and committed, `_MODULE_dispatch` runs with an invocation context current, the result is checked, validated and committed, copied, and the provider's buffer freed with `_MODULE_free`. `logos.schema` is answered by the boundary. `observe_end` callbacks run once, on a worker, with the first end code; `release` suppresses a scheduled callback or waits for a running one. **Invocation context.** One stack per thread; a nested entry restores the previous context (INTERFACE l.2169); `caller` names the consumer; `is_cancelled` reads a ticket the Runtime marks when the route ends (l.2101-2102). **Routes follow instances.** A provider that leaves `ready` fails its routes (`provider-unavailable`); a stopped consumer closes them and a failed one fails them (`consumer-unavailable`, G170); a binding that is invalidated releases its callers still waiting in start_module or stop_module with NOT_READY. A provider is destroyed only once its in-flight count is zero. Route records carry `failure` when `failed` or `revoked` (l.2520). **Known deviations.** Scoped publish through the invocation context is MODULE_ERROR until events (step 4); `observe_end` has no capacity limit; route records are never pruned; a call admitted before its route ended completes and sees `is_cancelled`; a stop that passes its deadline leaves the instance `stopping`. Not built: events and subscriptions, asynchronous and prepared calls, remote Runtimes, transported routes, continuations and expiry, the host API (step 5), and persistence. Tests: `tests/test_routes.nim` (31 tests in 5 suites, orc, refc and release), whose names carry the RUN and IFC requirement ids and G169–G173; the kit's meter gains channels 18 and 19 (the caller, the Runtime and cancellation; a call held at a gate). | 2026-11-11 |
| I77 | IMPL | Sanitizer builds, and what they found | **Builds.** `config.nims` turns `-d:asan` (AddressSanitizer with UndefinedBehaviorSanitizer; LeakSanitizer on Linux), `-d:tsan` and `-d:msan` (MemorySanitizer, clang on Linux) into `-fsanitize=…` with `-fno-sanitize-recover=all`, frame pointers, `-O1`, `--debugger:native`, `-d:useMalloc` (so the sanitizer sees every allocation) and a nimcache per sanitizer under `build/nimcache/`. `tests/support/sanitizers.c` is compiled into each of those programs and carries the runtimes' default options and the one suppression, so a plain run and a Nix check behave alike. `nimble test_asan`, `test_tsan` and `test_msan` run every suite under orc; the flake adds `<suite>-asan`, `-tsan` and `-msan` checks on Linux (GCC for the first two, clang for MSan, `_FORTIFY_SOURCE` off). macOS has no MemorySanitizer, and nixpkgs' clang 21 sanitizer runtimes hang (ASan) or crash (TSan) at startup on macOS 27, so the Mac builds them with the Xcode toolchain (`xcrun --find clang` without a Nix shell's `DEVELOPER_DIR`) through the nimble tasks, and the flake has no sanitizer checks on Darwin. Tests that check the depth limit on a 512 KiB stack (I79) get four times that under a sanitizer, whose frames are larger. **Findings.** (1) Nim 2.2.14's generated `=wasMoved` for a case object resets the active branch, sets the discriminator to its first value and resets that branch too, switching on discriminators nested in it that it never set; a constructor temporary leaves them as stack garbage, and the switch ends in `__builtin_unreachable()`. GCC `-O3` ran off the end of the hook on Linux (`Msg` with `Request.rc` first, `Job` with `BindSpec` first). `MsgKind` and `JobKind` now start with a kind without fields (`mkJobDone`, `jkQuit`); UBSan reports the old order at once on both systems. (2) A tuple copy of an `Opt` in `engine.lifecycleCall` reset a temporary it never initialized (UBSan, a `bool` holding 2); each value now has its own `if` expression. A scan of every suite's generated C found no other `=wasMoved` followed by `=copy` on a temporary. (3) A thread's `base/perthread` tables and ORC's per-thread cycle-root buffer leaked when the thread ended (LeakSanitizer). Every thread now releases them when it ends: a thread Nim started in an `onThreadDestruction` handler, while it still owns its allocator region; under ORC any other thread in a thread-exit hook (`base/thread_exit.c`: `__cxa_thread_atexit_impl`, Apple's `_tlv_atexit`, a Windows fiber-local slot's callback, or a POSIX key's destructor), which also collects cycles whether or not the thread loaded a table (any call that drops a possibly cyclic reference allocates the root buffer; the Linux `-asan` checks of the kit and the call helpers caught a harness thread that loaded none), frees the handler list Nim never frees and gives the thread's allocator region back (`tearDownForeignThreadGc`). The module kit's entries and the Runtime's bindings register it (`enterThread`, after `setupForeignThreadGc`); so does a thread's first table, and the route bindings' per-thread contract cache is released with the tables. The process's main thread keeps the tables it loaded while running the library's initialization (its hook would run during process exit); a library mapped on another thread registers that thread like any other (revised 2026-11-12, I81: the Runtime maps module libraries on its workers, whose initialization tables leaked when the workers ended, Linux `test_host-asan`), and under refc a C thread releases its own (`releasePerThread`). A test checks both kinds of thread. (4) Nim's `Channel` reads `cap` outside its lock (TSan): suppressed with `race_top` on `sendImpl` and `recvImpl`, so races on what a channel carries are still reported. (5) Two test faults: the route tests' client module returned from `_MODULE_destroy` while the test still held a response (INTERFACE l.1619, l.3831; its destroy now waits for calls in flight through its binding), and the typed harness read a result's message after the thread that returned it had ended (l.1826; the job thread copies it into the report). The realizer tests' fake module also recorded contexts it had freed, and the contexts of realizations the tests leave active are now freed after the last suite. (6) Under ORC, a `?` (an early `return`) inside a `ref` object constructor, or inside an object, tuple or array constructor passed to a `sink` parameter (`add`, `ok`), leaks what the constructor already built (LeakSanitizer; not refc). Every `?` that `tools/lint/ctortry.py` finds inside an object constructor, or after the first element of a tuple or array constructor, is now a `let` before it (about 80 sites, and lcn-gen's map encoders, regenerated); the flake's `lint-ctor-try` check keeps it so. (7) Under ORC, a C thread's first allocation crashes unless it has called `setupForeignThreadGc` (Nim gives each thread its own allocator region); the kit and the bindings already did, and `base/perthread` now says it holds under every memory manager. (8) MemorySanitizer cannot see what assembly or uninstrumented code writes, so under `-d:msan` BLAKE3 builds its portable C and BoringSSL builds with `BORINGSSL_USE_ASM=false`, and the libraries the tests build at run time (`tests/support/kitbuild.nim`) take the host's sanitizer; the `-msan` checks have `llvm-symbolizer`. With that, MemorySanitizer reports nothing on x86_64. On aarch64 a library loaded with `dlopen` reaches its thread-local variables through TLS descriptors, which bypass the `__tls_get_addr` interceptor MemorySanitizer relies on to see glibc initialize them, so Nim's start-up in every such library reads as uninitialized (CI, `test_kit_dylib-msan`); the four suites that load Nim libraries (`test_engine`, `test_kit_dylib`, `test_realizer`, `test_routes`) have no `-msan` check on aarch64 (corrected 2026-11-17, step 5-0: the list is the `-msan` variant's `skip` in `flake.nix`, fourteen suites at `3c6f3c3`, each later addition in its own row), and CI runs `nix flake check --keep-going` so one failing check no longer hides the rest. The portable BLAKE3 branch had never been compiled and failed Nim's style check (`passC`). Upstream drafts are in the local upstream notes, not filed: 6 for (1), 7 for (2), 8 for (4), 9 for (6), 10 and 11 for (3), 12 for (7). Drafts 9-12 also reproduce on Nim 2.4.0 and devel `d61298c`; (1) does not. The aarch64 list has grown since, each addition in its own row; `test_hosted_routes` joined after CI's run on 897216d (2026-11-15) reported the same use of an uninitialized value in a Nim library's start-up under `ld-linux`'s initializers, in a Module Host loading the meter kit (`h1.so`), with the value from a heap allocation in the host. `test_wipe_routes` joined after CI's run on eed9d58 (2026-11-15) reported the same in its hosted cases, in audit-build Module Hosts loading the vault and probe kits (`h1.so`, `h2.so`): each such host died at start, its instance ended in `error`, and the cases failed on the empty NOT_READY replies that followed (`malformed-cbor at 0`). `test_logosd` joined after CI's run on b3af640 (2026-11-16) reported the same in its hosted cases, in Module Hosts that logosd started for the chatter kit (`h1.so`): the host died at start, so `chatter-1` never initialized and never became ready. x86_64 still runs the whole suite under MemorySanitizer. | 2026-11-11 |
| I78 | IMPL | Runtime slice step 4: events and asynchronous calls (INTERFACE §2.5, §2.8, §2.9, §2.9.1-§2.9.3, §5.2; RUNTIME §4.4, §7.3, §7.3.1, §7.4, §7.5) | **Layout.** `bindings.nim` keeps the vtables; what they share moved to `runtime/callside.nim` (fixed-size text, failure statuses, the schema blob a handle shares with its subscriptions and calls, invocation state, the per-thread stack of provider entries), the call paths and Runtime Control requests to `runtime/invoke.nim`, events to `runtime/events.nim`, and asynchronous calls and deferred completion to `runtime/asynccall.nim`; `bell.timedWait` is added. The engine supplies the publish callback to every attempt, so `EngineConfig.services` is gone. **Subscriptions.** `subscribe` checks its input on the caller's thread. The Runtime thread then checks ownership, the event under the selected contract and the route's `subscribe_events`, a revoked route and the `subscribe-event` decision (NOT_AUTHORISED, G175), then the route's end code and the consumer's liveness (NOT_READY); it writes the id (a per-route counter) and activates the subscription. A subscription belongs to its handle's path generation: an id that names no active subscription of the handle is INVALID_PARAMS and changes nothing (the X3 reading; TRANSPORT l.748 through RUNTIME l.1012-1016). `unsubscribe` through an ended route returns the route's code first (RUNTIME l.1343-1344). A route's end deactivates its subscriptions; handle release deactivates the handle's and waits for their handlers on other threads. **Direct publication.** On the publishing thread (INTERFACE l.1961-1967). The Runtime thread names the active subscriptions to the event on the routes of the publisher's current, ready realization that have not ended, in route and then subscription creation order. The payload is validated and its commitment computed once per selected contract. Then, for each subscription: its gate (one thread at a time; the same thread may re-enter through nested publication), one admission round trip (G175), and the handler, behind a frame barrier so it sees no invocation context (INTERFACE l.2170). A publication that cannot be validated is dropped and recorded as a diagnostic (RUNTIME l.1227); the engine keeps the last 4096 (`Engine.diagnostics`). `unsubscribe` and release wait only for gates other threads hold (the N1 reading: a frame further down the caller's own stack is not waited for, INTERFACE l.1456-1458). A long gate wait is G176. **Scoped publication.** Through the invocation context, into the subscriptions on the call's route and path generation (G177), checked in this order (the N4 reading; the order of the last two is the G171 class): a malformed name or payload is INVALID_PARAMS; an event outside the selected contract or the route's `publish_events`, or a revoked route, NOT_AUTHORISED; a payload that is not a value of the event's type INVALID_PARAMS; a closed destination NOT_READY. Zero subscribers is OK. A denied `publish-event` stops the fan-out with NOT_AUTHORISED; a subscriber that the decisions or its own scope exclude is skipped; a destination that closes during the fan-out admits no later handler, and the publication reports NOT_READY (RUNTIME l.1275-1283). **Asynchronous calls.** `prepare_call` on a route handle or the Runtime Control binding copies the method, request, consumer, attempt, route, path generation and contract (RUNTIME l.880-884), checks options and callbacks, and runs nothing; 4096 calls may be outstanding per engine, then MODULE_ERROR. `submit` only posts. The Runtime thread registers the call and its deadline and hands it to a call worker (up to 64, apart from the lifecycle workers). The worker admits a route call as a synchronous call is admitted, so a route that ended answers its code without dispatch and a restarted provider is never substituted; a Runtime Control call runs the synchronous request, and `start_module` completes at `ready`. The first terminal decision wins: the result, a local rejection, `cancel`, `release`, the timeout (from submission; zero expires without dispatch), or G174. Each completion callback runs once, on a lifecycle worker and never inline, with an owner that frees a Runtime copy and outlives the call and the handle. `release` waits for a callback that has begun, never for the provider. A completion not begun when the consumer's realization ends is suppressed. A cancellation, a timeout or a route end marks the invocation cancelled. **Deferred providers.** When the provider exports a valid `_MODULE_async_api`, a route call is one provider invocation: `submit` with its context current, `complete` from any thread (checked, copied and validated as a synchronous result, with the owner released on every path), then `execution_release`. Admitted entries (`submit`, `request_cancel`, context operations, `complete`) are counted under one guard; the invocation leaves its provider's in-flight count, which `_MODULE_destroy` waits for, only after `execution_release` and its last entry. `request_cancel` runs once, after cancellation is known and `submit` returned and unless execution was released, on a worker with the context current; `release` does not wait for it. A second `complete` is ignored with a diagnostic; `execution_release` before any completion completes the call MODULE_ERROR. Synchronous calls still use `_MODULE_dispatch`. **Known deviations.** Runtime Control subscriptions are MODULE_ERROR (G178); every delivered handler costs one Runtime-thread round trip; asynchronous calls nested deeper than the call-worker cap, each waiting on the next, can still deadlock (narrowed 2026-11-13 by I88, G242: nested calls get overflow workers; 128 lifecycle jobs that each wait for work queued behind them can still stall). This supersedes I76's deviations on scoped publish and on calls admitted before their route ended. Tests: `tests/test_events.nim` (14 tests in 3 suites) and `tests/test_async.nim` (18 tests in 3 suites), whose names carry the IFC, RUN and CAP requirement ids and G174-G177; `tests/kit/deferred_adapter.nim` gives the meter a deferred surface that parks invocations for the test; the route tests' fixture moved to `tests/support/routefixture.nim`, which all three include. | 2026-11-11 |
| I79 | IMPL | Converter and codec frames on the heap (INTERFACE §4.5.1, l.3154-3155; review item A26) | The C-layout converters (`cmirror`) and the Nim codecs (`nimgen`) no longer recurse once per nesting level, so a typed call or a codec at the payload depth limit (1024) runs in a fixed native stack, as the commitment walkers do since I51. **Converters.** Each `cOut_<T>` and `cIn_<T>` is an entry over a step proc (`cOutStep_<T>`, `cInStep_<T>`) and a frame (`callrt.nim` `OutFrame`, `InFrame`: the value, the mirror, the depth, the block to resume at and the list in progress). A step runs until it reaches a nested aggregate (a struct member, a recursive target, a choice arm, a list element of aggregate type), sets that aggregate's frame as its child and returns; the drivers (`runOut`, `runIn`) keep the frames in a heap stack and resume the parent once the child is done. Members are still visited depth first in declaration order, so the first failure and its message are those of the recursive converters. A `cIn` child writes its value into a slot its parent made first (a map entry, or an item of an array allocated at its final length, `cbor/value.nim` `newCborArray`), so the entry order is unchanged. Method requests and responses are still straight code calling the entries. The generated C ABI and headers are unchanged. **Codecs.** The generated `toCbor` and `fromChecked` (infallible: the value was checked first) convert one object, or one alias with a container body, per step (`stepEnc<T>`, `stepDec<T>`). Every container is allocated at its final size before a nested value is handed on as a task (`nimrt.nim` `EncWork`, `DecWork`, `runEnc`, `runDec`), and nothing a task points to moves, so the tasks run from a heap list; the bytes produced are the same. Scalar aliases keep their expression form. **Measured** as the smallest thread stack (16 KiB steps) on which `test_kit`'s depth test passes, `test_calls` the same. arm64 macOS (clang): orc 576 → 96 KiB, refc 400 → 80 KiB, orc release 464 → 96 KiB; ASan and TSan 192 KiB. x86_64 Linux (GCC 14.3): orc 480 KiB, refc 112 KiB, orc release 144 KiB. What remains is not the converters (the cases without deep values run in 16 KiB on macOS, 48 KiB on Linux). It is ORC freeing a deep `CborValue` tree, or a typed value decoded from one, one native frame per level, and the C harness's own recursive `dump_tree`. The largest case is a cyclic C input. Each level of `shapes.Tree` is a map holding an array, so the converter builds about 2048 nested containers before its depth limit stops it, and ORC's recursive free of that partial tree needs 480 KiB under GCC without optimization (16 KiB under refc). A non-recursive destructor for `CborValue` would remove it; not done here. `test_nimgen`'s codec test (encode, decode and re-encode at 1024, reject 1025 both ways) passes at 48 KiB (orc) and 16 KiB (refc) on macOS. **Tests.** The depth tests in `test_kit`, `test_calls`, `test_kit_dylib` and `test_nimgen` run on a 512 KiB thread, the macOS and iOS secondary-thread default (four times that under a sanitizer, I77), started by `tests/support/cthread.c` `lcn_test_run_c_thread_on`. A first budget of 256 KiB passed on macOS and failed on Linux (orc, debug). The chain builder in `test_nimgen` met a Nim 2.2.14 refc bug: an object constructor assigned to a variable that a statement-list field value reads (results' `Opt.some` is one) is built in place before the value reads it. It now builds through a temporary. Upstream: draft 20 in the local upstream notes, not filed; fixed in 2.4.0 and devel `d61298c`, probably with nim-lang/Nim#25993. Resolves I72's known deviation (A26). | 2026-11-11 |
| I80 | IMPL | Runtime step-3 leftovers: ended route records and the stop deadline (RUNTIME §3.4 l.611-613, §7.5 l.1343-1346, §9.3 l.3157-3159, l.3175-3180, l.3188, l.3249, §10.2 l.3835-3838; INTERFACE l.2004-2006) | **Ended route records.** An ended route (closed, failed or revoked) keeps its record while anything can still reach it by its id: an unreleased handle of a live consumer attempt (RUNTIME l.1346; a handle stops counting once its attempt's context is destroyed, INTERFACE l.2004-2006), a handle observing its end, an admitted call, or a submitted asynchronous call still recorded. After that it is droppable, and each consumer keeps its newest `EngineConfig.endedRoutes` droppable records (4096 by default), dropping the oldest first; records that something reaches do not count. Retention selection is a deployment concern (l.3249) and needs no tombstone (l.3180). The count is per consumer so one consumer's establish/close churn cannot evict another's failed or revoked records (the Fable session's review, 2026-11-12, which found the rule consistent with the text and not worth a report). A dropped id is unknown: `renew_route`, `close_route` and `materialize_route` answer NOT_AUTHORISED with the text of an id that never existed (l.3157-3159, l.3188), where a kept record answers NOT_READY or its state; a `request_key` replay still returns its retained result, whose use stays subject to the current checks (l.3175-3176). Dropped records leave the creation-ordered table in batches, once they are an eighth of it, so a drop costs amortized constant time. `engine.settle`, `engine.compactRoutes`, `routes.reachable`. **Stop deadline.** An explicit stop's deadline (`EngineConfig.stopDeadline`, 10 s, G61) starts when the instance enters `stopping`. Past it the cleanup failure is recorded: the instance enters `error` with `cleanup-timeout`, and the stop's callers get that view (l.3835-3838, l.3873-3874). Nothing is force-released (l.3838): the destruction goes on, a call still inside the provider keeps it, and `start` is NOT_READY until it ends (l.613). Its end leaves the instance in `error` with its cause (G180's interim, the literal reading of l.611); a later stop then gives `unloaded` at once, and a stop while the cleanup still runs re-enters `stopping` and completes at its end. So `stop_module` answers `error` at the deadline (G173, revised). The shutdown grace is unchanged. `engine.checkDeadlines`, `engine.finishAttempt`. This supersedes I76's deviations on route records and on a stop past its deadline, and I75's reply of `stopping` at the stop deadline. **Known deviations.** A call prepared through a handle and submitted after the handle's release and the record's drop fails NOT_AUTHORISED, the route being unknown, where before the drop it fails with the route's end cause; §7.5 binds only unreleased handles (l.1343). A consumer that keeps handles on ended routes keeps one record per such route until it releases them or its attempt's context is destroyed. **Later.** Once Runtime Control subscriptions exist (G178), a drop decides each subscriber's `inventory_changed` hint before the record goes (l.3417-3421). Tests: `tests/test_routes.nim` (34 tests in 6 suites; the new suite on ended records has 3), `tests/test_engine.nim` (22 tests; RUN-0358 and RUN-0359 now expect `cleanup-timeout`, and two tests are new). The route tests that hold a client's destruction stop it from a thread under a 30 s deadline (`routefixture.stopping`). | 2026-11-12 |
| I81 | IMPL | Runtime slice step 5: the start path and the Host Embedding API (RUNTIME §13, §13.1-§13.4, l.1640; §9.3 `get_readiness`) | **Header and library.** `lcn-gen logos-runtime` writes `logos_runtime.h`: the §13 and §13.3 text as mirrored (`RuntimeHostHandle`, `RuntimeHostApi`), an include guard, `logos_types.h`, C++ linkage and `LCN_RUNTIME_CONFIG_FORMAT_APP_V1`; `test_codegen` compiles it as C17, C23, C++17, C++20 and C++23, and `test_abi` checks that `abi/host.nim` has its layout. It is also a fixture in `tests/generated/`. `src/liblogos_runtime.nim` exports the six functions over `runtime/host.nim`, built `--app:lib --nimMainPrefix:liblogos_runtime`; `nimble build_runtime_lib` puts library and header under `build/lib/`. **Configuration (G76, owner's S2).** `logos-core-nim.app-config.v1`, one deterministic-CBOR `lcn.app_config` (`runtime/host_config.cddl`, codecs generated into `host_config_types.nim`, documented in `docs/HOST-CONFIG.md`, whose copy of the schema a test compares). `create` checks, in order: the identifier; one deterministic-CBOR value (malformed or non-deterministic bytes carry a `logos.invalid_params_detail`); the schema (closed maps); absolute paths; deadlines of 1 ms to 1 h [IMPL]; present arrays non-empty (RUNTIME l.1428); each module's record (RUNTIME §8); unique instances and state assignments; an orchestration instance that is listed and whose module name is outside `logos_` (G53); ordering among listed instances, acyclic, with the orchestration instance never a dependent [IMPL]. Every failure is INVALID_PARAMS and leaves `*out` null; nothing is opened or started and no module code runs; 64 MiB at most [IMPL]. Owner's S5: the policy is `{kind: "allow-all"}`, written out; another kind is "not supported yet". Deny rules for tests are an in-process hook (`setPolicyForTests`) that neither C nor the configuration reaches (D27; SECURITY l.532). **Handle.** On the shared heap with plain values only: the configuration bytes and each registered table as copies, decoded and checked again on the thread that starts, the call-order flags, the stored shutdown result and the engine, so under refc no thread frees another's memory. Every function runs `bindingEnter`, then checks null pointers, version and size (VERSION_MISMATCH; nothing past version 1's fields is read), call order (NOT_READY), then content: the G171 class. A result's message and detail live in the calling thread's storage until its next call (RUN-0764), never in the handle; reading R4: thread exit ends them too. **Registration.** `checkStaticRegistration` on a copy, with no module code run; a duplicate identifier is INVALID_PARAMS; the copy is kept only on success; no instance is created; after a start attempt or a shutdown request NOT_READY; 65 536 symbols at most [IMPL]. A binding no record names is kept unused until `destroy`. **Start.** Once per handle. Owner's S4: a static record naming an unregistered binding is INVALID_PARAMS before anything runs. `work_dir` and `state_root` are made 0700 when missing (failure: MODULE_ERROR). The engine gets a fresh UUIDv4 (G192) and its bootstrap policy before its first request (RUN-0305). `rqBootstrap` creates every instance in configuration order with the host's origin and starts the orchestration instance through the ordinary start path (G48 (a)), so its intent is `requested` (G191); the answer is G190's. **Shutdown and destruction.** `rqRequestShutdown` accepts and answers at once; `rqAwaitShutdown` waits without initiating (RUN-0728); the result is G60's, computed once in `finishShutdown`. Before an engine exists a request completes shutdown at once. Reading R1: a request overlapping `start` is accepted and `start` returns CANCELLED (checked under the handle's lock before the engine exists, by the bootstrap after). Reading R3: a wait from a Runtime thread (`callside.markRuntimeThread` on the Runtime thread, lifecycle and call workers) or inside a module frame is NOT_READY. Reading R2: after a start attempt with no engine, `destroy` needs a completed shutdown. Otherwise `destroy` is `engine.tryClose`: NOT_READY with the handle valid while the Runtime has not shut down or module code still runs on a worker, else it joins every thread and frees (RUN-0733, RUN-0734, RUN-0761); `rqTerminate` no longer ends the loop when it refuses, and `close` retries for up to 10 s. **`get_readiness` (owner's S1).** Selection as for start and stop; observation authority by the G161 interim; state, execution, failure and reason from one snapshot (l.3494); both selectors INVALID_PARAMS; an unknown target NOT_AUTHORISED; through `rcRequest` and `rcInvoke`, so asynchronous calls have it too. Tests: `tests/test_host.nim` (35 tests in 5 suites, in process, with a Nim test orchestrator), `tests/test_host_dylib.nim` (7 tests: the library loaded with `dlopen` and driven from C threads by `tests/host/host_harness.c`; a C module linked into the test and registered statically, `tests/host/test_orchestrator.c`; the meter kit library registered with the addresses `dlsym` finds; the sensor kit library as a `direct_dynamic` record; `tests/host/embed_main.c` built as strict C11 against `logos_runtime.h` alone and run), the bootstrap suite of `test_engine` and the `get_readiness` suite of `test_routes`. Both host suites join the aarch64 MemorySanitizer skip list (I77). RUNTIME §13 claimed (RUN gate 49/49); host duties by inspection (`conformance/inspection/RUN.toml`). Not built: `daemon-config.v1`, persistence, the Loader and CA as modules, Windows runs. **Linux fixes (2026-11-12, CI on `194359d`).** Three checks failed on Linux only. (1) `test_host_dylib-refc`: a program linked against `liblogos_runtime` at load time puts the library's exports in the process's global scope, and Nim 2.2.14 exports its case-object tables (`NimDT_…`), so a module library the Runtime maps bound its references to the Runtime's copies and its start-up overwrote them; refc's channel copies then took the module's type information, and the Runtime's collector ran the module's markers (upstream draft 21; on 2.4 a second library's constructor also runs the first's `NimMain`). `base/libvisibility` compiles `liblogos_runtime` and every module-kit library with `-fvisibility=hidden` [IMPL], so each exports its `dynlib` procedures, `NimMain` and `NimDestroyGlobals`, the sanitizer hooks, and BLAKE3's functions (its C and assembly mark them for export; they keep no state), and none of Nim's own globals. (2) `test_host-asan`: a module library mapped on a Runtime worker kept the tables its initialization loaded on that thread, and they leaked when the worker ended; only the process's main thread keeps them now (`lcn_is_main_thread`; I77 (3)). (3) `test_host_dylib-tsan`: `embed_main` had none of the sanitizer runtimes' defaults and suppressions (the library's copy comes after the runtime's weak defaults in symbol lookup order), so it reported Nim's channel `cap` race (I77 (4)); it now compiles `tests/support/sanitizers.c` too. | 2026-11-11 |
| I82 | IMPL | Runtime slice step 6: persistent Runtime state and recovery (RUNTIME §8 l.1449-1466, §9.2 l.2623-2641, l.2659-2672, l.2869-2872, §9.3 l.3178-3181, l.3500-3507, `recover_module` l.3537-3544, §10.1 engine half l.3774-3810; LOADER §5.1; BCP l.359, l.366, l.394-396) | **6a: the store and restart.** **Files.** `src/logos_core/durable.nim` is the byte level, shared with later steps (8a's Capability Authority state, step 9's side records): atomic replace (temporary file, `fsync`, `F_FULLFSYNC` on Darwin, rename, directory `fsync`; `MoveFileExW` with write-through on Windows), a bounded read, an exclusive `flock` lock file held for the engine's life, a directory of mode 0700 and files of 0600, refused when group or other have access or another user owns them. `runtime/store.nim` keeps one deterministic-CBOR snapshot, `runtime-state.cbor` (`logos-core-nim.runtime-state.v1`; `store.cddl`, generated `store_types.nim`; at most 64 MiB [IMPL]), and side records `<kind>-<BLAKE3 of the instance id, hex>.cbor`, of which those naming no known instance are removed at open. The decoder checks the snapshot's invariants (one entry per instance id and per provider id, no revision past the stored epoch, distinct state assignments, keys naming known instances, an intent revision only with `requested`, `error` only with a failure, no declared configuration); a corrupt, newer-format or inconsistent store fails `start` with MODULE_ERROR and is left as it is. The stored record `lcn.rs_record` repeats `lcn.app_module` without `instance` (`test_nimgen` compares the rules) and, until step 9, refuses a configuration commitment; no Tier 4 step changes the format. **What persists.** The Runtime id and the revision epoch; per instance its id, provider id, accepted record, lifecycle state, failure, revision, intent, intent revision and origin; tombstones with the state assignment each reserves; `create_module` keys. Routes, attempts, request-key results, authorization answers and the change log are not persisted, so a route id from an earlier run is unknown. **Exposure (owner's U6, option (b); RUNTIME l.3505, l.3507).** Each instance keeps the view last written (`shown`), and observation reads it: `view`, `list`, the change log, `get_readiness` and the views in replies. Accepting commits (an intent, an accepted attempt, `create`, a refreshed record) write first; on failure they roll back from a copy taken before the change and answer MODULE_ERROR "the execution state could not be persisted" (TF-30 point 4's reading). `ready` is written first too: if that write fails the instance stays `loaded` (`apReadyPending`), the write is retried every second, and the startup deadline ends the attempt. Follow-on commits (`stopping`, `unloaded`, `error`, the authority-denied record) withdraw first (routes end, callers are released, destruction is scheduled), then write, then expose; a failed write exposes nothing, sets `storeFailed`, and a reply that would carry the new view is MODULE_ERROR. While `storeFailed` is set the write is retried at every commit, every second and before every lifecycle request; the first that succeeds exposes every instance whose view moved, with the diagnostic "the execution state is persisted again". `finishShutdown` tries once more; if it fails the shutdown result is MODULE_ERROR (G60 extended). A non-persistent engine writes nothing and exposes every commit at once, as before. **Cost.** Measured on APFS with `F_FULLFSYNC` for a 3195-byte snapshot: median 10.4 ms, p90 12.6 ms, maximum 63 ms per write, above the plan's 5 ms guide. Per-commit writes are kept: the plan's staging fallback would hold replies until a batched write and may not begin an attempt before its write. **Revisions (RUN-0631 to RUN-0633).** `epoch = max(stored + 1, unix seconds)`, at most 2^32 − 1, is written before any request is accepted. A restored instance's revision is `(epoch shl 32) + 1` and a new instance starts at `epoch shl 32`, so every value after a restart is past every value exposed before, unpersisted ones and those of a restored older store included, while the clock has not gone back (l.3506). An accepting commit is refused with MODULE_ERROR once the low 32 bits reach `EngineConfig.revisionBudget` (default 2^32 − 2^16; tests set it small); `ready` is exempt. Non-persistent engines keep epoch 0. **Identifiers (RUN-0922, RUN-0947, RUN-0949; l.2633, l.3178; CA l.548-550).** A 128-bit random prefix per open, as 32 hex digits, in instance, provider, attempt, route, state-assignment and decision ids (`d-<prefix>-<n>`); a generated id is checked against known and retired ids. Names in the Runtime's form (`m-`, `s-` or `p-`, 32 lowercase hex digits, `-`, digits) are refused in the host configuration, so tombstones are kept only for host-assigned ids and the assignments they reserve. **Restart.** Restored instances keep `unloaded` and `error`; `loaded`, `ready` and `stopping` become `error` with `other` (G193). The bootstrap reconciles the configuration before it changes anything (G160): a retired id, changed declaration facts, or a state assignment held by another instance or a retired one is INVALID_PARAMS naming the instance; equal facts with another `local_path` or `reason` refresh the record. Instances absent from the configuration stay known. The orchestration instance follows G191's second question, the identity G192's persistence part. A `direct_dynamic` artifact is copied and verified again at its next attempt (RUN-1030). **Engine.** `openEngine` opens a persistent engine (`newEngine` stays for non-persistent ones); `EngineConfig.storeDir` and `revisionBudget`; `engine.recover` and `beginAttempt`. Inside `start` and `recover` the order is: the intent commit (start only), the execution decision, the attempt-accept commit, then `beginAttempt` (token, services, realizer), where step 8b and step 9 attach. Nothing assumes a fixed number of revision steps per operation. The engine restarts nothing on its own (RUN-0697, RUN-0693). **Host.** `runtime.store_dir` (absolute, apart from `work_dir` and `state_root`) and `runtime.runtime_instance_id` (needs `store_dir`) in `logos-core-nim.app-config.v1`, documented in `docs/HOST-CONFIG.md`, "Persistent Runtime state", with what survives, resumption against retries (l.3775), persistence failures, backup and restore, retention and bounds. **Tests.** `test_store` (11), `test_persist` (16: engine restarts with static modules), the persistence suite of `test_host` (5), a crash test in `test_host_dylib` (`embed_main crash` ends with `_Exit` after `start`; the next start finds the store and resumes), `test_engine`'s `direct_dynamic` re-verification and `test_nimgen`'s store checks. RUN-0687 and RUN-0923 are not tagged: each binds more than this step builds (the orchestration half of l.3790; three of the six record kinds of l.2637); the tests of their engine part name them without brackets. LDR-0042 by inspection (`conformance/inspection/LDR.toml`). The Windows branches are type-checked with `nim check --os:windows`, not run. **6b: the Runtime Control methods.** `recover_module`, `retire_module` and `create_module` join `RcMethod`, `RcCall` and `invoke.nim`. **`recover_module`** goes to `engine.recover`, in G171 order: the caller's association, the payload (`expected_execution_revision` is required), `recover_module` authority on the target (an unknown or refused target is the same NOT_AUTHORISED), the module name, the revision (INVALID_PARAMS, nothing changed), readiness (an invalidated binding or a shutdown: NOT_READY), then intent `requested`, `unloaded` or `error`, and no attempt, destroy job or realization left (NOT_READY, l.3538); exhaustion is MODULE_ERROR. Then the start path from the prerequisites on: execution is authorized for the retained origin (l.3540; a denial records `authority-denied` and advances the revision, G168), the accepting write, a new token and realization (RUN-0691, RUN-0694). The answer comes as `start_module`'s (G173 note). Failed routes stay failed (RUN-0699). **Restart-policy proofs (the plan's C-9).** One revision value admits at most one accepted attempt: a replay or a concurrent recovery with it is INVALID_PARAMS; an answer the caller lost is resolved by `get_readiness`; a refused recovery advances the revision with no attempt, so a policy counts answered recoveries, never revision steps; after an explicit stop or during shutdown recovery is NOT_READY; nothing restarts on its own. **`retire_module`** (`engine.retire`, `retireInst`): another Runtime's target is INVALID_PARAMS without detail (G194); the method is authorized on its own (`deny` rules name it; l.3557); the revision; readiness; then NOT_READY while the instance is not `unloaded`/`error`, has an attempt, destroy job, realization, call in it, deferred or asynchronous call, or stop waiting (read from what the Runtime owns, not the state, l.3564), while its intent is `requested`, while another instance's `requested` intent names it as origin (a stopped or replaced intent does not count, l.3578), or while the host configuration names it (l.3581). One write before the answer removes the instance and its provider record, keeps a host-assigned id as a tombstone with the state assignment it reserves (a Runtime-assigned name needs none), and drops its `create_module` keys (RUN-1028, a MAY taken); a failed write changes nothing and answers MODULE_ERROR. Its change-log entries are dropped (RUN-1012). Nothing cascades, and state directories, packages, grants and history stay (RUN-1011, RUN-1021 by inspection, `conformance/inspection/RUN.toml`). **`create_module`** (`engine.createModule`): `create_module` authority with the module name; readiness; the key, scoped to the method, the consumer and this Runtime (a replay with the same module gives the original instance unchanged, another module is INVALID_PARAMS without detail; the Runtime thread serializes, so one key creates one instance); a module with no declaration is NOT_AUTHORISED as a denial is (G195); `MaxInstances` (1024 known instances [IMPL]) is MODULE_ERROR (l.3442-3443); then `createInst` with the key in the same write, a fresh `m-` id and, with `persistent_state`, a fresh `s-` assignment. Declarations come from the host configuration's `declarations` (G55), into `EngineConfig.declarations`; a static declaration names a registered binding or `start` is INVALID_PARAMS (S4 extended). **Tests (6b).** `test_recovery` (27 tests in three suites, through the route fixture's Runtime Control bindings, with `counter_module`), `test_host` (the declarations configuration test, a declaration naming a binding never registered, the restart test's recovery by the orchestrator, and a retained instance whose static binding is no longer registered: `start` is OK and its recovery gives a `loader-` classification). **Not built.** Restart policy and retry accounting, the orchestration module's (Tier 4b; D24); Loader loss (RUN-1067 to RUN-1071, hosted Loader, Tier 4b); permission withdrawal and resumption (RUN-1066, RUN-0696, step 8); observation of the execution summary (step 7); assignment transfer and purge (G92, G143); owner-only ACLs on Windows. | 2026-11-12 |
| I83 | IMPL | Transport step 10a: the unix-stream I/O layer (TRANSPORT §2.1, §3.1, §5.2, §6, §8.1, §8.2, §8.5, §8.6, §9.1; CA §11). Part 1: the I/O thread, endpoints, the peer check and the Hello. Part 2: calls, events, execution slots, access, the session's end, limits | **Dependency (U2, U3).** chronos 4.4.1, with stew 0.5.2, httputils 0.5.1 and bearssl 0.2.13 pinned by exact `requires` lines placed before it (nimble 0.20.1 caches a download under the version its first requirement names); locked on Linux and mirrored into `nix/nimble-deps.json` (I35). Only `chronos/[asyncloop, timer, threadsync]` are imported. **Thread (G77).** `startTransport` runs one I/O thread with its own chronos dispatcher; I75's Runtime thread is unchanged. Owners `submit` value-only `IoCommand`s (I75's compile-time check) through a `Channel` and a `ThreadSignalPtr`, in FIFO order, and the thread reports every `IoEvent`, in order and `evStopped` last, through a non-blocking `IoSink`. `stopTransport` is safe against a concurrent `submit`: a `stopping` flag and a count of submitters, and the signal is closed only once none holds it. Shutdown stops serving, closes connections in id order, then closes the dispatcher's selector (`getIoHandler(...).close2()`), resets the threadvar dispatcher and calls `releasePerThread`. Payloads cross threads as deterministic-CBOR bytes, and each thread rebuilds boundaries from `ContractInput`. Admission is a round trip: `evHello` carries the first frame, the owner runs `acceptHello` on its single-threaded ticket store and answers `cmdAdmit`: `avEstablished`, `avFailed`, or `avUnavailable` (ProtocolError `MODULE_ERROR`, close, the ticket stays live; TRN-0276). While the verdict is pending nothing more is read. **Endpoints (G58).** As `docs/CONFORMANCE.md` "Unix-stream endpoints and peer checks" says: base check, a fresh 0700 directory set with `fchmod`, `bind` that never unlinks, 0600, listen; validation of type, domain, listening state, name and dev/ino; removal of matching objects only; `adoptListener` is the serving side's only entry. Darwin's `bind` follows a dangling symbolic link, so the name is first checked with `AT_SYMLINK_NOFOLLOW` (TRN-0182); macOS has no `SO_ACCEPTCONN` through `getsockopt`, so the listening state comes from `proc_pidfdinfo` (`soi_options`), and other Apple systems fail validation. **Peer check.** `SO_PEERCRED` (Linux, Android), `getpeereid` with `LOCAL_PEERPID` (Darwin, iOS); the euid is compared before any byte. A mismatch or unreadable credentials: close, nothing sent, the ticket neither disclosed nor consumed, `evConnectFailed(cfPeerMismatch)` with `TRANSPORT_ERROR` and the observed identity. The caller's Hello is a secret frame, zeroed once written or dropped, and the command's ticket is zeroed after use. **I/O.** Own non-blocking syscalls on raw fds driven by chronos readiness (chronos's server unlinks paths and its writes assume SIGPIPE is ignored); `MSG_NOSIGNAL` or `SO_NOSIGPIPE`. A frame body is reserved before it is allocated, from the Hello pool before establishment and the input pool after, with waiters served in strict FIFO order; after establishment a frame waits at most `admissionTimeout`. Frames are read one at a time, the next only after the previous is handled. A write error during the caller's Hello keeps reading, so the peer's ProtocolError is still seen. The inbound and pending-Hello caps refuse with ProtocolError `MODULE_ERROR`; the whole Hello exchange is bounded by `helloTimeout` (G61). **Output.** A per-connection queue: data frames within `connOutputBytes - controlReserve` and the loop-wide `maxOutputBytes`, control frames may use the reserve, and the final ProtocolError slot is never refused. An ok-Response that does not fit waits uncommitted (a Cancel meanwhile discards it), bounded by the write-stall timeout. **Platforms.** Windows builds and fails closed (`cfUnsupported`, `eeUnsupported`; G107). **Sanitizers.** I77's finding (1), Nim 2.2.14's `=wasMoved` of a case object, hit `IoCommand` (UBSan: `Channel.send` of a `cmdCall` with `cmdServe` first). `IoCommandKind` and `AdmitVerdictKind` now start with a kind without fields, `CallOutcome` is a plain object (a `bool` discriminator cannot have a field-less first branch), and a queued ok-Response holds its value rather than an `Outcome`. **Tests.** `tests/test_transport_io.nim` (suites `trnio.thread`, `trnio.endpoint`, `trnio.peer`, `trnio.hello`, `trnio.close`) against a child-process peer (`tests/support/trnpeer.nim`, started with `posix_spawn` and built with the suite's memory manager and sanitizer); the owner side is `tests/support/trnowner.nim`. G129's other-user listener runs in CI's `nimble` job on Linux (the `nix` job's dev shell has no Nim dependencies); elsewhere it is skipped. **Claims.** TRANSPORT §8.2 (not §8.2.1, which stays tier 5) and §9, TRN-0069 and TRN-0276 (TRN gate 203/203). TRN-0184 to 0187, 0191 and 0195 are built or tagged and stay deferred to 10b and 4b; TRN-0346 and 0347 are out of scope (G58). **Part 2.** **Execution slots (I52 as revised by A21).** A dispatched Request holds one of its connection's `maxInFlight` slots and one of the loop's `maxTotalExecuting` until the owner reports that its work ended (`cmdWorkEnded`, or `cmdRespond` with `workEnded`), even after its Response, its CANCELLED or the connection's close; a closed connection that still holds slots is kept as a zombie until they are released. At either cap the connection keeps reading: an excess Request waits in the bounded delayed-admission queue (full: ProtocolError `TRANSPORT_ERROR`, close), and its bytes keep their input-pool reservation. The past-cap budget counts every frame read while at the cap and resets when a frame is read below it. A Cancel for a queued Request commits CANCELLED with no `evStop` and no slot; the end of a session answers queued Requests `NOT_AUTHORISED` and never dispatches them. Freed loop slots go to the waiting connections in turn, one Request each (`admitWaiting`, not reentrant). **Calls and events.** The callee's owner answers `evDispatch` with `cmdRespond`, and `evSubscribe` and `evUnsubscribe` with `cmdSubscriptionResult` (an Unsubscribe is answered by the owner too) `[IMPL]`. `cmdPublish` sends to every active subscription to the event on the endpoint's established connections, by connection id, then subscription id; `cmdPublishScoped` only on the invocation's connection while the request is executing. An Event is committed when it is appended, after the session's checks (active subscription, publish scope, executing request); one that does not fit overflows the connection: ProtocolError `TRANSPORT_ERROR` from the final slot, a flush bounded by `closeLinger`, close. A refused publication is reported as `evPublishFailed` once per connection `[IMPL]`; an Event over `peerFrameLimit` is never committed, and `TooLargeAction` chooses between reporting it and closing (G165, chosen by 10b). The caller's owner gets `evEvent` with a `credit`: the frame keeps its input-pool bytes and counts against `callerUndeliveredBytes` until `cmdRelease`, and reading pauses while that is full. Only Events take credit `[IMPL]`; Responses are bounded by `maxCalls` and `maxTotalCalls`. **Backpressure (F8).** `maxPendingOutputBytes` is an atomic charged at `submit` for an ok-Response's result and a publication's data, and released when the I/O thread commits or discards it. `submit` returns `sbBusy` when it is full. `submitWait` polls every 1 ms `[IMPL]`, up to an optional deadline, and returns `sbRefused` on the I/O thread or a thread registered with `registerOwnerThread`. A payload larger than the whole budget passes when nothing else is pending `[IMPL]`, so it never waits forever. **Aggregates.** `maxTotalCalls` (local `MODULE_ERROR`), `maxTotalSubscriptions` (a SubscriptionResult error `MODULE_ERROR`; the session stays) `[IMPL]` and `maxTotalSubscriptionIds` (callee: ProtocolError `TRANSPORT_ERROR`, close; caller: local `MODULE_ERROR`), counted per connection by `account`. Every limit is documented with its scope and exhaustion behaviour in `docs/CONFORMANCE.md` "Transport limits" and the `io/aggregate.nim` header; event output in "Event output overflow". **Access.** `RouteBinding` gains `access` (declaration roots for methods, published events and subscribed events), `decision`, `expires` and `validUntil`. `applyAccess` (`transport/access.nim`) resolves the roots under the selected contract: an absent list is the whole contract (with `logos.schema` for methods), an empty one nothing. A root that names nothing is left out, which narrows the scope, and is reported as `evLocalFailure` `[IMPL]`. A publication outside the publish scope fails with `peNotInContract`. **The session's end.** The verdict's `endsIn` arms a timer, and `cmdTerminate` ends a session at once (revocation): `beginTermination` (new and queued Requests `NOT_AUTHORISED`, subscriptions end), `terminationDrain` (default 0), then ProtocolError `NOT_AUTHORISED` and close. **Tests.** `test_transport_io` suites `trnio.calls`, `trnio.events`, `trnio.termination`, `trnio.limits`; `test_transport` suites `trn.cancel`, `trn.termination`, `trn.limits`, `trn.access`. In sanitizer builds the deadlines that only bound how long a test waits are multiplied by `Slow` (`tests/support/trnowner.nim`: 3, and 10 under tsan), since multi-MiB payloads move several times slower there. **Claims.** TRANSPORT §5.2, §8.5 (by inspection, `conformance/inspection/TRN.toml`) and §8.6; TRN-0267, TRN-0314, TRN-0315, TRN-0151, TRN-0158, TRN-0161, TRN-0162, TRN-0320 and TRN-0325; §8.1.2 and TRN-0312 out of scope; CAP-0253, CAP-0255 and CAP-0256 (TRN gate 232/232, CAP gate 3/3). TRN-0153, TRN-0317 and CAP-0254 are tagged and stay deferred to 10b, which supplies the decision, its expiry and revocation. **Fixed 2026-11-12 (CI on master `e3247b4`, the first run of `test_transport_io` on GitHub runners):** 300 Events published in a burst never reached the caller: the callee was closed as not writable before it had written a byte. `drain` handled every queued command in one go (the 300 publications took 0.5 to 0.8 s under load), and chronos moves expired timers to its callback queue before the writable callbacks of the same turn, so the write-stall timer fired first and judged the peer by the clock alone. Now `onStall` tries a write first and closes only when the socket accepts nothing `[IMPL]`, and the I/O thread handles commands in slices of 5 ms (`DrainSlice`, at least one command), serving the timers and sockets that became ready between slices `[IMPL]`. In the tests, the owner's waits are bounded by the clock rather than by counting `sleep(1)` (a loaded macOS runner oversleeps it about tenfold, which made a 100 ms probe last a second and a 5 s wait 50 s), waits on multi-MiB payloads use `BigWait` (20 s × `Slow`), the write-stall and termination tests send 2 MiB instead of 8, and the termination test starts its clock once the Event is committed. **Also fixed 2026-11-12 (the same class):** `helloTimeout` and `admissionTimeout` judged the peer by the clock alone too. Their timers now leave the verdict to the dispatcher's next turn (`helloVerdict`, `admitVerdict`), after the sockets that were ready in the turn the deadline expired in, and the verdict first handles the commands the owner queued by then, and only those (`Io.pumpCommands`) `[IMPL]`: a Hello response, room freed by another connection's frame, or the owner's admission that arrived in time counts. The deadlines themselves do not move (G61). Tests: suite `trnio.deadlines`, which holds the I/O thread at the gate across each deadline; each test fails without the change. The child peer is built under a lock on `build/peer/<variant>/build.lock` into a file of its own, then renamed into place, so test processes running at once no longer break each other's peer ("cannot execute binary file"). The caller-credits test (CI msan, run 43286865754: 3 of 4 Events within 60 s) was slow, not paused early: reading pauses only after the Event that reaches `callerUndeliveredBytes` `[IMPL]`, and a loaded msan runner took up to 20 s per 4 MiB Event. It now waits `4 × BigWait` for the 16 MiB before the pause, checks that rule exactly (the first three credits are below the limit, four reach it), and its last two Events are small, so a missed pause shows within the settle. **And under heavier load (framework.lan, every check with `--rebuild`, master `59c96b8`):** the write-stall check still blamed a reader on the I/O thread itself: when its write attempt found the socket full, it closed before the reader's callback of the same turn ran. Its verdict now waits one turn too (`stallVerdict`) `[IMPL]`; test `[TRN-0126] a write stall: a caller ready to read when the deadline is seen is not blamed` loses two Events without it. Test bounds: the 300-Event test (281 of 300 at its 15 s bound, about 12 s needed at that load) waits `BigWait` and checks that no connection closed, so a loss is told from lateness; the output-overflow test's `closeLinger` and `writeStallTimeout` are `2 × BigWait` (the callee's flush lasts until the paused caller has read 16 MiB; refc took longer than its 5 s linger); the pre-Hello pool test's margin between the stalled Hellos' deadlines and the caller's is `1 s × Slow` (500 ms did not cover the read, admission and answer under msan). The `trnio.deadlines` tests hold the I/O thread across a deadline, so each must set its scene before that deadline; under 48 extra CPU burners (load about 125 on 24 threads) the write-stall one took 964 ms to reach its gate against a 500 ms bound. A try that sets its scene late proves nothing either way: it is set again, up to three times, and the test is skipped if no try was in time (`sceneTest`). The write-stall scene is timed from when the sink forwarded the 4th Event (`Owner.lastEventAt`), not from when the test thread received it: under that load receiving 16 MiB took longer than the deadline, which runs from the callee's last write after that Event. In the same stressed build `[TRN-0162]` (asan) never connected: the test owner's default `helloTimeout` was 300 ms, about 15 x its idle Hello (20 ms under asan). `fastConfig` now gives `helloTimeout` and `admissionTimeout` `5 s × Slow`, which only bound how long a test's own Hellos and frames may take; the three tests about those deadlines set 300 ms. | 2026-11-12 |
| I84 | IMPL | Tier 4 step 8a: the Capability Authority (CA §2 l.77-113, §3 l.119-392, §4 l.450-478, §5 l.483-575, §6 l.614-761, §7 l.767-795, §8 l.800-923 CA side, §9 l.999-1171 and l.1335-1349, §10 l.1357-1392, §13 l.1452-1459; BCP l.359-360, l.368, l.394-395; G46, G47, G49, G51, G52, G82, G205–G207, NA-05, NA-08) | **8a.1: the core** (no module, no engine). **Generated.** `authority/logos_capability_authority_types.nim` and `_kit.nim` from the nine mirrored CA CDDL blocks (`spec/mirrors/CAP/`, CA l.143-1244) with RNT §9.2 supporting, named after the module rather than the plan's `ca_types`/`ca_kit`; `policy_types.nim` (`policy.cddl`) and `state_types.nim` (`state.cddl`); `test_nimgen` checks all four are current and stamped, and that the policy's `lcn.ap_commitment` takes and makes the same bytes as `logos.capability_authority.commitment_requirements`. Generating them found a Nim bug, a field default whose type is an alias declared later in the same type section (upstream draft 50); `nimgen` declares such a field with its literal's type. **Policy** (`authority/policy.nim`, `docs/AUTHORITY-POLICY.md`, BCP l.360). `logos-core-nim.authority-policy.v1`: allow, deny, issue, revoke and inspect rules over G47 facts (instance, module name, exact signer, package), every array a set, nothing sorted; declaration names only for the two symbolic contracts, resolved at load against roots recomputed from the mirrors; a rule naming `evaluate`, `grant_changed` or `policy_changed` is refused; `placements` need `modes` to be exactly `local-transport`; decision validity 1 s to 24 h (default 1 h), audit records 1,024 to 1,048,576 (default 65,536, one count across all consumers, U6). Deny overrides allow. **Facts** (`authority/facts.nim`, G47): `SharedFacts`, a locked det-CBOR table of instances (module name, retained selection) and providers that the engine feeds (8b); the CA thread keeps a view refreshed by version; a closed table is unavailable, and so `authority-unavailable`, never a deny. **Scopes** (`authority/scopes.nim`): form (sets, shapes), locality (another Runtime or enrollment is `unsupported-scope`), permission (`unknown-permission`, CA l.392; failure records omit `scopes`), containment without narrowing (U7), one non-permission scope per `evaluate` (G207). **Evaluate**: the TL-04 order (G205); restricted roots `scope-denied`; deny rules; allow rules (commitment the union of request, rules and grants); else the covering grant that lasts longest (no `expires_at` first, then the latest, then the lower id), its id listed and its end the decision's; `grant-revoked`, `grant-expired`, else `not-granted`. **Ids** (`authority/ids.nim`, NA-08): `d-`/`g-`, 32 hex digits of per-open entropy and a 64-bit counter, checked against retained ids; no entropy fails the open. **Grants** (`authority/grants.nim`, NA-05): issuer derived (the calling module, or `protected-policy` with a source for the host's `issueProtected`/`revokeProtected`, whose failures are not recorded since they have no consumer, and which refuse a restricted scope with `invalid-request`); expiry read at use and recorded by a timer at `expires_at`, emitted even when its record cannot be written yet; an expiry passed while the issue was being written is `invalid-request` with nothing kept; a repeated revoke returns the grant unchanged with a second success record (G206); 16,384 kept, the oldest terminal one dropped first. **Lists and audit** (`authority/cursor.nim`, `audit.nim`; G51): `list_grants` ascending, visibility before the limit, live continuation with a stateless keyed-BLAKE3 cursor bound to consumer and query, 600 s, dead at restart, cut to a 15 MiB budget; `query_audit` timestamp descending then recording order descending, `since` inclusive and `until` exclusive, at most 1,000, invisible records omitted whole. A record's subject is its consumer's facts; one made before or without them carries the instance id alone, which matches no subject naming modules, signers or packages. A caller the CA does not know is `not-authorised` for module methods, unrecorded. **Notification**: `grant_changed` and `policy_changed` go to an `AuthoritySink` inside the transition, after the state is active and before the reply; a failed notification makes every later evaluation `authority-unavailable`. **Persistence** (`authority/persist.nim`, on `durable.nim`, U1): the CA's own state directory: `meta.cbor` (format, Runtime id, contract root, policy digest, revision and time, audit floor, and the last 64 policy-change records, rather than the plan's `policy.cbor`), `grants/<id>.cbor` (the grant, its target's facts, its issue, revoke and expiry records; written before each change takes effect), `audit/<16 hex>.cbor` (256-record segments written within 1 s; a repeated revoke's record goes here). A failed grant or policy write fails the change closed with nothing applied; evaluation keeps answering; more than 4,096 unwritten records make evaluation `authority-unavailable`. A foreign Runtime id, another contract, an unknown format, an undecodable file or a held lock refuses the open with every file unchanged. The first open is revision 1 with no policy-change record; a later open with a changed digest is the next revision with one record; `replacePolicy` is the Nim-only live path, a no-op for an equal digest (U4). Tests inject write failures instead of changing permissions. **Clock** (`base/clock.nim`): wall and monotonic time, frozen and advanced by tests. **Tests.** `test_authority` (66 tests: `cap.scopes`, `cap.policy`, `cap.evaluate`, `cap.ids`, `cap.grants`, `cap.list`, `cap.audit`, `cap.notify`, `cap.persist`) and `test_nimgen`. CAP sections stay unclaimed until 8b wires the CA in; CAP-0307 to CAP-0321 do not apply (no protected-renewal profile). **8a.2: the module.** **Provider** (`authority/provider.nim`, CA l.143): the `direct_static` module `logos_capability_authority`, built with its kit over the core. `wireAuthority(stateDir, wiring)` records the policy bytes, Runtime id, `SharedFacts`, clock and limits for the instance with that state directory (embedded host wiring, RUNTIME l.1681, l.3075-3077); init without a state directory or wiring is MODULE_ERROR, and the wiring stays until `unwireAuthority`, so a later attempt starts again on the same state. The caller comes from the invocation context, never a payload (CAP-0146, CAP-0147). `grant_changed` and `policy_changed` go out through the instance's publish callback, which 8b intercepts; the kit refuses an instance without one, so the engine path always exists. **System registration** (INTERFACE §1.3, BCP §5): `StaticRegistration.system`, set only by `caStaticRegistration()`, lets the realizer accept a call surface with the reserved `logos` names; a host-built registration cannot claim it, and the realizer refuses such a call surface from any other (`abi-invalid`). **Watches** (`watch_changes`, CA §8.1, G82): a module watching as itself; each change, encoded once on the CA thread, is offered to every watch whose consumer may see it under the policy and facts at that change (a policy change only to `inspect.policy_changes`, without `affected_executions`), with identical bytes and no watch id; the body publishes in the invocation's scope with no CA lock held (CAP-0375) and polls cancellation every 50 ms whatever changes (CAP-0381); it ends with `{}` on cancellation, close or a lost destination, and with `authority-unavailable` 256 changes behind (CAP-0383); 64 watches, 8 per consumer. Offering never blocks the CA thread, and the engine sink gets every event whatever the watches do (CAP-0382, CAP-0385). A stopped CA's routes fail, which cancels its watches before its destroy runs. **Tests.** `test_authority` adds `cap.watch` and `cap.provider` (the module through a stand-in Runtime, `tests/support/cafake.nim`), 80 tests in all; `test_authority_module` (9 tests) runs the CA in the engine: a client module's routes to its contract, a scoped `observed_change` on the watching route only, async cancel, a stop with a watch running, a start without wiring, the system registration, and a restart on one store and state root. `conformance/inspection/CAP.toml` records CAP-0092, CAP-0161, CAP-0162, CAP-0164, CAP-0165, CAP-0195, CAP-0262 and CAP-0337 to CAP-0340. | 2026-11-12 |
| I85 | IMPL | Tier 4 step 8b: the Runtime side of authority (CA §1, §2, §3.1-§3.3, §5, §5.1, §7, §8, §9, §9.1; RUNTIME l.245-257, §3.6, §4.1, §9 l.1629-1772, §9.3 l.3157-3190, §10.1; INTERFACE §1.4.1; G50, G52, G115, G149, G168, G170, G174, G175, G190, G215-G218; TF-31, TF-32, TF-33, TL-03, TL-04) | **8b-1: binding and decisions.** **Policy sources** (`runtime/authz.nim`). Every authorization point builds an `AuthzRequest` as before; an answer now records its source (internal, bootstrap, recovery, authority), decision id, policy revision, grants, retention and the authority's denial or error code, which is retained and never branched on or shown to the caller (TL-04). Internal ids stay `d-<prefix>-<n>`. `EngineConfig.authority` selects the Capability Authority; tests set it directly. **Binding** (`runtime/authbinding.nim`, `engine.checkBinding`). When the configured instance commits `ready` the Runtime thread checks it (a local direct realization, the pinned CA contract recomputed from the mirrors, `evaluate` and both notice events resolvable) and binds it under a fresh generation before the start that readied it is answered. Its `grant_changed` and `policy_changed` reach the Runtime thread through the publish callback, in order with admissions; an ordinary subscription to them is NOT_AUTHORISED even with an unconstrained scope. Loss (the authority leaves `ready`, a notice that does not read or is dropped) closes admission under the old generation, answers its parked evaluations as failures and clears the cache; a new binding starts afresh whatever revision it reports, and the old realization is not released, so not recoverable, while an evaluation is still running in it. Shutdown is not loss: it closes admission and clears the cache, and parked operations answer NOT_READY. Repeated deadline expiry is not loss either. **Evaluation.** Never on the Runtime thread (I75): four workers and a queue of 256 call the authority's dispatch with a system-service caller view; the consumer is the requesting module, never the engine. The worker decodes and validates the decision (`runtime/authscopes.nim`: consumer, the requested scopes echoed, arms, coverage by 8a's containment, `valid_until` after `issued_at`, no placements or permission scopes) and posts the result. One request carries one non-permission scope (G207); `stop_module` sends its Runtime Control scope and its `module_execution{stop}` scope as two requests decided together. A handler that needs decisions parks: its operation is re-run from the top with the decisions so far, reserving route ids across passes, at most 8 passes, nothing mutated while parked; `decideDetached` continues an operation without a reply. The deadline (default 5 s, from queueing) fails closed and marks the invocation cancelled. A narrowed route allow gives the route the allowed access; an allow that excludes the operation is NOT_AUTHORISED and retained as `narrowed`, neither a deny nor a failure. Under the authority an unknown target is NOT_AUTHORISED without an evaluation. **Cache:** G52's open half, decided there. **Bootstrap and recovery** (RUNTIME l.1635-1650, l.1674-1680). While no binding exists, the orchestration instance may `start_module`, `stop_module` (with its execution `stop`), `recover_module` and observe the authority instance, which then executes with orchestration as origin; after a loss only with `recovery`. Host requests are protected input and need no evaluation. Everything else fails closed as an evaluation failure. Bootstrap refuses an orchestration instance that is the authority. **Execution** (§3.6). After `start_module` or `recover_module` is accepted (intent committed), a `PendingExec` decision for the retained origin precedes the attempt; the evaluation is recorded before the module's init. A second start joins it while it can still succeed; a deny or failure answers each joined request as its own acceptance; an explicit stop answers them with the stopped view. A deny or failure follows G168: NOT_AUTHORISED, `unloaded` with `authority-denied` or `authority-evaluation-failed`, intent kept. `recover_module` is decided for the requester, execution for the origin. No permission scope (G217). **Routes.** A route allow must carry `valid_until` (otherwise an evaluation failure); `expires_at` is it, at establishment and renewal; at expiry the route is `revoked` with `authority-expired` (G218). **Facts.** The engine keeps 8a's attribute source current at create, restore and retire. **Host config.** `lcn.app_policy` gains `capability-authority` (`authority`, `policy: lcn.authority_policy`, `evaluation_deadline_ms`, `recovery`) and `lcn.app_config` gains `call_audit`; the generator reads `host_config.cddl` followed by `authority/policy.cddl` as one document. `create` checks the authority instance (module name, pinned contract when given, state assignment), `store_dir`, the deadline (1..60000, below `startup_deadline_ms`), the policy as 8a loads it, and `call_audit`'s ranges and paths, then refuses both with "not supported yet" until 8b-2 and 8b-3 (`decodeHostConfig` runs the checks alone, for tests); `docs/HOST-CONFIG.md`. **Tests.** `test_runtime_authority` (26, threaded) over `tests/support/fakeca.nim`, the authority's real name, call surface and call symbols with a scripted `evaluate` (allow with validity, grants and narrowing, deny, error, hang, malformed decisions, bad status), stamping each decision with the revision of the last `policy_changed` it published. `test_routes_ca` and `test_events_ca` rerun those suites with a fake authority bound and allowing everything (`routefixture`'s `caParity`); a case that scripts the internal policy's denials keeps it. `test_engine` has no parity build: its operations come from the host, which the derived host rule answers without evaluating. `test_host` adds the policy and `call_audit` checks. **8b-2: authority over time.** **Execution** (`runtime/execauth.nim`, CA §5.1, §8 l.828-866). One record per running instance: source, binding generation, decision id, policy revision, `valid_until` and the same end on the monotonic clock fixed at receipt, the grants used and the request. Only an authority decision ends; internal, bootstrap and recovery authorizations have none. An allow without `valid_until` lasts until invalidated (plan §6.3). Renewal starts at the end minus min(30 s, a third of the lifetime), on a renewal lane of its own (one worker, `renewWorkerMain`) so it never queues behind ordinary evaluations; it asks the same request with `execution_renewal`, which only the Runtime sets. An allow replaces the record (never wider), a narrowed allow ends it as revoked, a deny as denied; an evaluation failure keeps it while it is valid and asks again after min(5 s, half of what is left). The end on either clock ends it as expired. `policy_changed` keeps an authorization decided at or after the new revision, or one whose binding, previous revision and a complete `affected_executions` that omits the instance all match (moved to the new revision); anything else ends as revoked. A revoked or expired grant it used ends it as revoked or expired. Binding loss ends every authority authorization as `authority-evaluation-failed` (our choice, plan §6.3). **Enforcement stop** (`stopForAuthority`, exported; G168 extended). The instance is stopped at once with intent and origin kept and the stop deadline applied; on reaching `unloaded` it carries the ending's classification. An overrun gives `cleanup-timeout`, which replaces it (TF-10, TF-28). An explicit stop clears the classification, also of an instance already `unloaded` (RUNTIME l.3757, l.3760). Orchestration resumes it with `recover_module`. RUN-0914 is deferred. **Routes** (G216 for the re-authorization, G170 extended): after `policy_changed` or the end of a listed grant, eager `renew-route` re-authorization, 64 at a time, admissions parked meanwhile; `expires_at` never later; a narrowed allow revokes with `authority-revoked`, a deny with `authority-denied`; an evaluation failure leaves the route `ready` and unusable until a later decision. Binding loss marks every authority route for re-authorization at its next use under a new binding; nothing is evaluated then. An operation that already waited for a failed re-authorization is NOT_AUTHORISED rather than waiting again. **In-flight calls** (G174 unchanged; CA l.917-918): provider code already running when its route is revoked cannot be interrupted; its invocation is marked cancelled, it commits no response (NOT_AUTHORISED under the ticket lock), and the engine records that limitation as a diagnostic. A policy change reaches a route only as its re-authorization's outcome (plan §6.3; the stricter hold-every-commit alternative is not built). **Events** (G175 re-checked): unchanged decision points, all through the cache; an explicit `subscribe-event` deny at delivery deactivates the subscription, an evaluation failure skips that delivery only. **Routed authority calls** (G215): after the call's own decision and schema check, a `consumer` other than the caller or an `execution_renewal` in a module's `evaluate` is NOT_AUTHORISED without dispatch, retained as `azRefused` from `psBoundary`, in every policy mode. **Notices.** An ordinary subscription to `grant_changed` or `policy_changed` on a route that selects the pinned authority contract is NOT_AUTHORISED in every policy mode, the instance bound or not (RUN-0856, RUN-0857). **Binding.** A record that names no `primary_contract` binds when the realization exposes the pinned contract (RUN-0316); one that names another never does. **Host** (`runtime/host.nim`, `host_config.nim`, C9). `capability-authority` is accepted. `liblogos_runtime` registers 8a's authority itself as binding `logos_capability_authority` (the only registration that may use the reserved names, I84), and a host binding with that id makes `start` INVALID_PARAMS. `create` also requires the authority to be that `direct_static` binding (a library loaded apart would not see the in-process wiring) and `state_root`. `start` creates the attribute source before the engine opens (restoring the store fills it), and after the engine opens wires the authority at `state_root/<state_assignment>` (the realizer's path) with the policy bytes, the identity the engine settled and the attribute source; a wiring failure is a failed start (G190). `destroy` unwires and frees it after the engine is closed. Bootstrap starts only the orchestration instance; it starts the authority under the derived rules (G190 re-checked, unchanged: `start` does not wait for the first binding). `docs/HOST-CONFIG.md` gains "Under `capability-authority`" (the authority's binding, the derived rules, fail-closed, loss and `recovery`, authority over time, time assurance, events, grants, the attribute source, the retained answers). **Tests.** `test_runtime_authority` (37: execution over time, route re-authorization, routed calls to the authority), `test_events` and `test_events_ca` (G175 under the authority), `test_host` (H1: the kind accepted, the binding and `state_root` checks), `test_host_authority` (H4: through the host API with 8a's authority, two protected grants, start, route, call, revocation of each, `recover_module`), and `test_authority_module`'s `[CAP-0178]` (no ordinary subscription, bound or not) and `[CAP-0248]` (a payload naming another consumer is refused before dispatch). **8b-3: call audit and evidence.** **Commitments, always** (RUN-0332, RUN-0333). Every route call and Runtime Control call keeps the request commitment the boundary computes once the request validates, and the response commitment once a response validates, in a `CallTrail` (`runtime/callaudit.nim`), retained or not; `logos.schema` commits under the pinned common schema (CA l.1203-1204). The deferred-provider path now validates and commits the request before `submit`, as the synchronous paths do (RUNTIME §4.1 l.833-841); it used to hand the provider unchecked bytes. **Capture at admission** (CAP-0389 to CAP-0392). When the allow applied to a call carries `commitment`, the Runtime thread captures its decision id, the enforced scope, the retained sides, the consumer and the Runtime id as one `CallCapture` that travels with the call (`Admission.capture`; in shared memory across a deferred provider's completion, `SharedCapture`). The enforced scope is the call's own request scope [IMPL]: it already names one route, one provider, the selected contract and one method (or, for Runtime Control, the Runtime, the contract, one method, the selectors the operation determines and no events, CAP-0209), so an allowed scope that covers it adds no narrowing (CA l.1178, l.1188); the plan's "selectors of the allowed scope" are therefore already there. A cached call decision is named as itself. A Runtime Control call's capture is kept on the Runtime thread by reply channel and attached to its reply, so it never outlives the call. Renewal and revocation never touch a capture. **The record after the outcome** (CA l.1172-1198; CAP-0205, CAP-0210 to CAP-0214, CAP-0388). Synchronous calls record on the caller's thread after the ticket commit, asynchronous ones after their outcome is delivered, deferred ones at completion or early release, and a Runtime Control call on every outcome including a refused precheck. A side appears only when it is retained and was committed; `success` only when the call succeeded and every retained side was committed, else `failure`, with `commitments` omitted when none was. A call that fails after every retained side was committed (a provider error after request-only retention) is `failure` with its request commitment: the spec does not say, a minor gap for the TF-06 editorial list (not sent). A revoked in-flight call (G174) is `failure` with both commitments when the response had validated before the revocation took effect. **`_sensitive`** (INTERFACE l.397; IFC-0581). A call whose decision retains a side its method marks is refused at admission before dispatch, per side, NOT_AUTHORISED, retained as `azRefused` from `psBoundary` with reason `sensitive-retention` [IMPL]; no call record (admission did not succeed). Retaining only the unmarked side is allowed. **Retention** (CA l.1169, l.1330; CAP-0244, CAP-0257, CAP-0264). `AuditLog`: a ring of encoded records in shared memory, one lock, appended from any thread, the oldest dropped first; `call_audit.call_records` (default 4096, 1 to 1,000,000). Each record gets an index counting every record appended since the engine opened, from 0; `records` lists the retained ones oldest first, `recordAt(i)` reads one while it is retained. In memory only, lost at exit [IMPL]; logosd persists them (G143). Records hold ids, a scope and roots only. **Evidence** (`runtime/evidence.nim`, CA §9.1; CAP-0216 to CAP-0240, CAP-0394 to CAP-0414). `crypto/cose.nim` holds the COSE_Sign1 structure package signing already used (the package vectors are unchanged). The producer checks the record and any proofs (`buildClaim`), signs hedged with the empty context over the Sig_structure whose external_aad is the profile id, fails without randomness, and checks the signature under its own public key. The Runtime retains no verified views in Tier 4, so its containers carry no proofs. The verifier (`verifyEvidence`) takes the profile, algorithm and aad from its own `EvidenceContext` (each kid bound once to one producer and one 48-byte key; a duplicate kid refused; `revoke`) and a `ContractResolver` the verifier supplies for the defining contract of the signed call scope's method (for `logos.schema`, the common schema); it checks structure, kid, signature, claim, profile, producer, record and proofs in that order, with no retry. **Key and export** (G149, G115). `call_audit.evidence` names a kid and an absolute path to the 96-byte FIPS 205 secret key: a regular file, not a link, owned by the process user, mode 0600 (POSIX; not checked on Windows), whose public half its seeds derive. `create` reads it into shared memory and answers INVALID_PARAMS `call_audit.evidence: …` otherwise; `destroy` clears it. The producer is the Runtime id the engine settles at `start`. `auditRecords(rt)` and `exportCallEvidence(rt, index)` (in-process; no C export in Tier 4) are the protected export integration: calling it is the host's authorization to disclose the complete record, and a record no longer retained cannot be exported (CAP-0415 to CAP-0418). `tools/evidence_keygen.nim` writes a fresh key (CAP-0402); an evidence key is never a package signing key (CAP-0401, a deployment duty documented in HOST-CONFIG). **Host config.** `call_audit` is accepted; `docs/HOST-CONFIG.md` "Call audit and call evidence". **Tests.** `test_audit` (7: no retention, each side, both on the synchronous, asynchronous and deferred paths, failures, the cached decision, renewal and revocation while a call runs, Runtime Control and its precheck, `logos.schema`, `_sensitive` per side, the ring) over `fakeca` with retention scripted and a hand-written `vault_module` with marked payloads; `test_evidence` (7: four signed containers, the structure, kid, profile and producer rejections, the proof rules and the defining-contract checks, the key file); `test_host` (the `call_audit` gate gone; key-file errors at `create`); `test_host_authority` (H5: a policy allow retaining both sides under 8a's authority, records read and one exported and verified). | 2026-11-12 |
| I86 | IMPL | Tier 4 step 7: observation, permission settings and Runtime Control events (RUNTIME §2.4 l.448-458, l.540-541, §9.1 l.1833, l.1901-1904, §9.3 `describe_provider`, `list_modules`, `list_routes`, `get_execution_summary`, `get_permission_settings`, `update_permission_settings`, l.2526-2604, l.3372-3413, l.3415-3428, l.3494-3535, l.3715-3735; INTERFACE §2.5, l.1483-1484, l.3837; CA l.126, l.247-257, l.301-308, l.554-567; G161, G175, G178, G180, G225-G230; TF-09, TF-22, TF-24, TF-30, TF-34, TF-35, TF-36, TL-08) | **7a: observation.** The six methods, MODULE_ERROR until now, are decoded (`invoke.rcRequest`) and answered on the Runtime thread (`engine.rc`). **Lists** (`runtime/inventory.nim`, `runtime/observe.nim`). The method's authority comes first: `aaObserve`, decided once without a subject (`AuthzRequest.filters`), its refusal NOT_AUTHORISED before the payload is judged, the precheck of an undecodable payload included (G171). Then the limit (absent: 100; otherwise 1 to 1000, else INVALID_PARAMS without detail), the cursor or a new snapshot, readiness. A snapshot holds each visible record's value from one committed view (`exposed`), its encoded size and the facts its disclosure is judged by (G226), in l.3407-3413's order: instance-keyed records by instance id, then provider-keyed ones (a local instance with a provider record, which carries both) by provider id; routes by route id, ended records still kept (I80) included, dropped ones not, never `invocation`. The filters are applied before visibility and grant nothing; `list_routes`' `provider` filter is normalized (an omitted Runtime id is this Runtime; another Runtime's matches nothing). Each page applies the method's current decision to each record (G161 extended): `next_cursor` exactly while a later admitted record remains; at most `limit` records and 4 MiB of record bytes; a first record that alone exceeds that is MODULE_ERROR. Only a first page that continues is retained. **Cursors.** 32 bytes from the system CSPRNG as unpadded base64url, one per page position, bound to the consumer instance, the method, the normalized filters and the effective limit; anything else, an expired and an evicted one are INVALID_PARAMS "the cursor is not valid" without detail. A retried cursor gives the same page and the same next cursor. **Limits** (`EngineLimits` in `EngineConfig.limits`, not in the host config; `docs/HOST-CONFIG.md` "Observation"): per consumer 8 snapshots and 8 MiB, its own least recently used evicted first; in all 256 and 64 MiB, past which, after expired ones are reclaimed, a new snapshot is MODULE_ERROR and no other consumer's is evicted; 10 minutes idle and 1 hour in all, reclaimed by the deadline timer and when the consumer's attempt ends. A later page refused MODULE_ERROR leaves its snapshot to expire. **Visibility** (`observe.nim`). Under the authority a record is shown when one allowed scope covers, whole, the method's scope with exactly that record's selectors and no event (`methodScope`, `admitsScope`; alternatives never combined, CAP-0117); under the internal policy when its rules allow the request naming the record (`Authorizer.permits`); a bootstrap or recovery answer admits every record. An allow for a request with `filters` is never treated as narrowed (`authscopes.narrowedFor`). **Summary.** The target's order is G194's (G228): another Runtime is INVALID_PARAMS without detail; an unknown target under the authority NOT_AUTHORISED before any decision; the target's own `aaObserve` decision (a refusal the same NOT_AUTHORISED); readiness. State, execution and failure come from the committed view; `selection` is `implementation-specific` with no `package` or `signer` (G230); `realization` is computed when asked (`engine.realizationStatus`): `unknown` while a Loader bind is unresolved, a bind or init has outlived its deadline, or a cleanup past its deadline runs (G180); `current` while an attempt, a realization or its teardown is owned; `absent` otherwise. **TL-08** (G227). After every step on the Runtime thread `engine.followRealizations` compares each instance's realization with the last one recorded; one that moved without a commit of that instance in the step is committed (revision, write, exposure). So a late cleanup or initialization ending and a dynamic bind returning each make a commit. Three tests follow it: `test_engine`'s stop past its deadline sees one more change, still `error`; `test_recovery` and `test_runtime_authority` read the revision again after a cleanup ends, and the latter checks that the one read before is INVALID_PARAMS. **`describe_provider`.** Another Runtime is INVALID_PARAMS; an unknown provider under the authority NOT_AUTHORISED; the provider's own `aaObserve` decision (`providers: [p]`); then one `discover` decision per contract, of the bound surface or, before any bind, the ones its record expects (D5; CA l.250-257): a deny, or an authority allow that does not disclose this provider, is NOT_AUTHORISED with the same message; then readiness; a provider never bound is NOT_READY. The validated surface bytes are kept from the bind (`Inst.surface`) across stops (l.540-541). **Permission settings** (G229): the constant form, nothing stored; each method decided for its target alone (`aaObserve` for get, `aaLifecycle` for update; RUN-0473). **Reasons** (`observe.disclosedReason`). A record's or readiness answer's `reason` is omitted for a Module Loader failure, whose message may name host paths; any other is the Runtime's or the module's text cut at 512 bytes at a character boundary. **`observe_end` capacity** (INTERFACE l.1483-1484). 1024 registrations per consumer instance and 16384 in all; past either the registration is MODULE_ERROR and retains nothing (IFC-0660); a registration counts until it fires or its handle is released. This removes I76's deviation "`observe_end` has no capacity limit". **Tests.** `test_observe` (27: lists, cursors, limits, visibility, reasons, summaries and TL-08, `describe_provider` with an 8 MiB surface through the response check `rcInvoke` applies, permission settings), `test_observe_ca` (30: the same with the fake authority bound, plus narrowed allows: alternatives never combined, a `providers` selector, a retired record judged by its kept facts on a later page, a route matched by its own facts and never its consumer); `fakeca` scripts narrowed Runtime Control scopes (`RcNarrow`); `test_routes` (`observe_end` capacity; `list_remote_listeners` is now the unsupported-method probe). **Known deviations (7a).** The remote-transport methods stay MODULE_ERROR; Runtime Control events and inventory hints are step 7b's. **7b: Runtime Control events** (`runtime/rcevents.nim`, `engine.nim`; G178 built). **Subscribing.** The binding's `subscribe` and `unsubscribe`, MODULE_ERROR until now, apply INTERFACE §2.5 (l.3837). A null name, handler or output, and a malformed name, are INVALID_PARAMS with `*out` untouched; then, on the Runtime thread: association; a name that is not one of the six events NOT_AUTHORISED; the event's own decision without a subject (`aaObserveEvent`, scope `{methods: [], events: [root]}`; G175 extended, G161), a denial NOT_AUTHORISED; readiness, NOT_READY once the subscriber leaves `loaded`/`ready`; capacity (`rcSubsPerSubscriber` 32 per instance, `rcSubsTotal` 1024 in all) MODULE_ERROR. Ids count from 1 per binding; the id is written before the subscription is active, and no handler runs on the subscribing thread. `unsubscribe` checks no authority or readiness: it is LOGOS_OK for a subscription the Runtime ended (lost, or its subscriber stopping), also inside `_MODULE_destroy`; an id the binding never gave or already unsubscribed is INVALID_PARAMS and changes nothing; it returns once no other thread runs the handler, and from inside the handler without waiting for its own frame. **Events.** One exposure of an instance (`expose`, so after its write, C19) gives, in order: `module_state_changed` when the state differs from the one last exposed (`instance` set, never `provider`, the new state's `failure` and its disclosed `reason`); `execution_state_changed`, TL-08's commits included (G227); a `modules` hint. Creation, the first exposure, gives only the hint (C7); an instance restored at startup counts as seen in its restored state. A route's end gives `route_state_changed` (closed, failed, revoked; never at establishment) with the route, the target module and provider, no `reason`, then a `routes` hint; establishment, a renewal or re-authorization that changes the record's `decision_id` or `expires_at` (l.3417; the plan's table named renewal only, re-authorization changes the same fields), retirement (a `modules` hint) and the drop of an ended route record (I80) give hints too; a replayed renewal gives none (RUN-0978). The subjects are G226's: an instance event's module and instance, a route event's route, module and provider, a hint's affected record as its list method judges it. **Judging and delivery** as G161's and G178's 7b notes say: judged at fan-out, in order behind any evaluation; queued only when admitted (D3); hints coalesced per collection with their admitted facts (D2); delivered on the event workers, each entry admitted again on the Runtime thread, re-judged when the decision state changed. `rcQueue` is at least 2, so an `inventory_changed` subscription never overflows. **Loss** (G225): past `rcQueue` or `rcUnjudged`, or for an overflowed hint none of whose retained subjects is still admitted, the subscription ends with the diagnostic "Runtime Control subscription <id> of <instance> lost: … (G225)". **Lifetime.** A subscription ends at the commit that takes its subscriber out of `loaded`/`ready`, before that commit is exposed, so the subscriber never gets the event of its own `stopping`; the subscriber's realization is released and its context destroyed only once no handler of it runs; its records are freed with its binding; shutdown and `tryClose` wait for running handlers and the event workers. Limits and the resynchronization advice are in `docs/HOST-CONFIG.md` "Runtime Control subscriptions". This removes I78's deviation "Runtime Control subscriptions are MODULE_ERROR (G178)". **Tests.** `test_rcevents` (24: subscribe and unsubscribe, eight threads churning, lifetime with a subscriber whose `_MODULE_destroy` unsubscribes, each event's payload and order, 200 transitions in commit order, deterministic CBOR of each payload, per-subject authority, inventory hints, delivery off the committing operation with a handler calling `get_readiness` and `stop_module`, loss and resubscription, a stalled hint handler, shutdown, TL-08), `test_rcevents_ca` (25: the same with the fake authority bound, plus a decision revoked mid-stream: queued entries judged again at delivery); `fakeca` names an event scope `rcev:<event>`. **Known deviations (7b).** A lost subscription gives its subscriber no signal (G225); `permission_settings_changed_event` and `configuration_state_changed_event` are accepted and never delivered (G229; configuration is step 9); RUNTIME l.1182 is not applied to these events (G178); each delivery costs a Runtime-thread round trip; two handlers unsubscribing each other's subscriptions deadlock, as for route subscriptions. **Nim finding.** Under refc a `let` copy of a seq field shares the field's buffer: the fan-out iterated `let subs = st.rcByEvent[event]`, a loss inside the loop removed from the field, and `items` asserted that the length changed (ORC copies, and passed). `publishRc` and `hintRc` iterate a `var` copy. Upstream draft 70 in the local upstream notes, not filed. | 2026-11-13 |
| I87 | IMPL | Tier 4 step 9: module configuration for direct mode (CONFIG §1-§9; RUNTIME §8 l.1386-1392, §8.1 l.1587-1592, §9.3 l.2394-2457, l.2606-2612; LOADER §5.2, §8, §11; INTERFACE §2.6, §5.2; G21, G61, G141, G162, G171, G190, G228, G233-G237; TF-10, TF-18, TF-25, TF-28, TF-30, TL-09, TL-10). Part 9a: state, operations and startup; part 9b: live reconfiguration | **Declarations.** `configcheck.acceptConfiguration` accepts a `configuration_declaration` on the thread that builds the record (the host's, or a test's): the document as a supporting schema against the pinned context alone (no I/O; INTERFACE §5.3 limits), the root a type it declares, both roots recomputed and equal to the declared ones, and the default and any provisioned value complete values of the root. The record carries the binding's digest (blake3 of the whole `schema_binding`, persisted as `configuration_commitment`); the `AcceptedConfiguration` travels beside it, and a record whose digest is not the accepted declaration's is INVALID_PARAMS (RUN-0259). Bytes live in refcounted shared blobs (`config.Blob`). **State.** One `ConfigState` per configurable instance, owned by the Runtime thread: the revision from 0, never wrapping, one step held back while a promotion is pending (G234); current, staged and the in-flight attempted record. A mutation is admitted only if a maximal `get_configuration` frame fits 16 MiB (G233). Every revision change is written to the instance's side record `cfg-<hash>.cbor` in `store_dir` (`LcnCfgRecord`: binding, state, last provisioned value root) before it is exposed, then published as `configuration_state_changed_event` with the summary and never a value (C2, C29). A creation writes the side record before the snapshot that names the instance; a retirement deletes it after the snapshot that drops it (C7). `load` restores every configurable instance's record; a missing or unreadable one fails the open with MODULE_ERROR naming the instance (CFG-0029: we do not invent revision 0 for a retained identity). **Sources.** At creation, the provisioned value (`protected-provisioning`; per instance, not gated by D27; G141), else the declaration's default (`package-default`, CFG-0046), else nothing. At a later bootstrap the provisioned value is staged again only when its value root changed (G141); a changed binding refuses the instance with INVALID_PARAMS naming it (CFG-0132; G160). **Operations.** `get_configuration_schema`, `get_configuration_summary`, `get_configuration` and `update_configuration` are authorized per method and target through step 8b's decisions; a target on another Runtime is INVALID_PARAMS (G228 extended); CONFIG §5's table is checked in row order (G21, G171). A summary without a binding is `{state_revision: 0}` (G235). `update_configuration` stages in two phases: the Runtime thread checks the request and the binding and answers with the retained state and its decisions; the caller's thread decodes the value, validates it and computes its value root with a per-thread validator (`configcheck.checkValue`, at most 16 per thread, released with the thread); the commit re-runs the checks, reuses the first phase's decisions only while no policy generation, invalidation or deadline has passed (C31), and compares-and-sets. The `configuration-schema-mismatch` detail goes only to a caller that also holds `get_configuration_schema` authority. **Startup.** `engine.selectConfig` runs in `executeDecided`, after the execution decision and before the attempt is accepted, for start, recovery and bootstrap alike (C6, C17): staged, else current. None or ineligible is NOT_READY, intent established or kept, a retained authority refusal cleared (G162); a revision that cannot advance is MODULE_ERROR (G234); for the orchestration instance either fails the bootstrap with MODULE_ERROR (G190). The selected record becomes the attempted one, and the realizer hands `_MODULE_init` one `configuration_input` (`ConfigurationHandoff`, part of the realization key, never in a record or message: LDR-0045, LDR-0149). A live declaration whose module exports no `_MODULE_apply_configuration` is `loader-abi-invalid` before init. Promotion is written before the `ready` commit (C3); a write that fails ends the attempt `error`/`other`, "the configuration state could not be persisted", and releases the realization. **Host config.** `modules[].configuration` (one deterministic-CBOR declaration) and `provisioned_configuration`; `declarations[].configuration` (never a provisioned value, RUN-0923); `docs/HOST-CONFIG.md` gains a "Module configuration" section (CFG-0129). **Kit.** `lcn-gen kit --configuration:FILE --configuration-root:NAME [--live-reconfiguration]` also writes `<module>_configuration_types.nim`; the kit embeds the document, the root and the commitment recomputed at generation time, and its `_MODULE_init` checks the `configuration_input` before any author code (a commitment other than its own VERSION_MISMATCH before the value is read, anything else INVALID_PARAMS), then calls `initModule(T, ModuleInit, <Root>)` with `ModuleInit.configurationRevision`. A live kit exports `_MODULE_apply_configuration` over `applyConfiguration(T, <Root>)` with the same checks. An unconfigured kit given a configuration, or a configured one given none, is INVALID_PARAMS before author code [IMPL]; the meter kit's tests moved to the state directory for their refusal. `kitrt.checkConfigurationInput` gives a handwritten module the same checks (CFG-0071). A Nim name shared by the module's and the configuration's types is a generator error. **Tests.** `test_config` (38: the pure state, selection, admission and encoding suites; startup with defaults, provisioned values, no value, a failed init and a live declaration without the hook; a generated kit bound statically; the operations and their authority, mismatch detail and G233; restarts: re-staging by value root, a changed binding, a lost record, G233 at bootstrap, G190, retirement, an unwritable store and G162's cleared refusal); `test_host` (the declaration and provisioned value in app-config v1); `test_rcevents` (the event, in revision order, without a value); `test_kit` (6: embedded commitment, init and apply glue, `checkConfigurationInput`, generator errors); `test_nimgen` (the CLI writes the committed fixtures); `test_kit_dylib` and `test_host_dylib` (the tuner kit as a library: init, apply, and a provisioned value reaching a `direct_dynamic` orchestration instance); `test_realizer` (the handoff); `test_abi` (IFC-0519 with a delivered input). Under refc a `let` copy of a local `var` seq shares its buffer, a wider case of I86's finding (upstream draft 80), so `test_kit` keeps its comparison copy in a `var`. New fixtures: `tests/kit/tuner_module.cddl`, `quiet_module.cddl`, `tuner_impl.nim`, `quiet_impl.nim` and their generated modules. **Live reconfiguration (9b).** `apply_configuration` is authorized as the other mutations are (`aaLifecycle`, its own method), then CONFIG §8's preconditions in table order (`engine.applyRefusal`): no binding, a stale revision, nothing staged and a startup-only binding are INVALID_PARAMS without detail (CFG-0090, CFG-0143); not `ready`, or another application in flight (CFG-0095), NOT_READY; then a realization without a live configuration binding INVALID_PARAMS (G171 extended); commitments that differ VERSION_MISMATCH (`config.commitmentsAgree`, unreachable under §7); a revision that cannot advance MODULE_ERROR (G234). The staged record becomes the attempted one, and its `configuration_input` goes to `_MODULE_apply_configuration` on a lifecycle worker (`jkApply`), under `apply_deadline_ms` (G61's fourth deadline, 120 s by default). The realizer marks the realization applying (`beginApply`), refuses its release meanwhile (LDR-0136), and classifies the result (`completeApply`): LOGOS_OK `succeeded`; a valid failure status `configuration-rejected`; anything else `realization-failed`, the realization `failed` and still owned. The engine defers every release of the instance until the hook returns. Success promotes the attempted record, written before it is exposed, with no lifecycle change and no `module_state_changed_event` (CFG-0103), and answers `{target, state_revision, applied_value_revision}`, the attempted record's value revision (G236); the staged record is cleared only when it still has that revision (CFG-0100). A promotion that cannot be written is MODULE_ERROR and puts the instance in `error` with `other`. A rejection is MODULE_ERROR and changes nothing, the hook's status not forwarded (CFG-0145, CFG-0146). An invalid result, or the deadline passing first, is indeterminate: MODULE_ERROR, `error` with `configuration-indeterminate`, provider work stopped, the realization released once the hook returns; a late result promotes nothing (CFG-0136 to CFG-0139). A stop or shutdown during an application closes admission and waits for the hook; a valid result is still applied, without readiness (CFG-0140). Expiry during a stop: G237. Provider calls keep running on the call workers during an application (IFC-0270, claimed). A `report_failure` during an application puts the instance in `error` at once; the release waits for the hook, whose valid result is still made current without restoring readiness [IMPL], as for a stop (CFG-0140). **Tests (9b).** `test_config` "cfg.apply" (15: success and its revisions, the preconditions in order, the commitment rule, authority, rejection, an invalid result, one at a time with an update during it, expiry, a stop, a reported failure, G237 both ways, shutdown, the generated kit, and its provider calls answered from the value in force while the hook is held); `test_realizer` (the Loader side: refusals, rejection, `realization-failed`, release excluded while applying); `test_host` (`apply_deadline_ms`). | 2026-11-13 |
| I88 | IMPL | Tier 4 step 11: deviations and claims, closing Tier 4 (INTERFACE §1.4.1 l.381-389, §2.9 l.2040-2054, §4.5.1 l.3148-3152; RUNTIME l.212, l.1572, l.1901-1904, l.3197, l.3442, l.3527-3528, l.3754-3757; LOADER l.23-26, l.622, l.628; G230, G241-G244; IF-02, C-08, TF-03, TF-36). Part 11a: code; part 11b: tooling and schema suites; part 11c: tags, inspection, claims and documents | **11a. S11-1 (b).** The in-process realizer is an implementation-local realization mechanism (RUNTIME l.212), not a Module Loader: summaries report `implementation-specific` (G230), and the `loader-<code>` classifications are gone (l.3754 needs a typed Module Loader error). `FailureKind.fkLoader`, `Failure.loader` and their branches in `classification` and `store.classificationOf` are removed. A realizer error other than a failed `_MODULE_init` (`initialization-failed`) is `other` with `Failure.internal` set: its message, which may name host paths, stays in the diagnostics and is neither disclosed (l.1901-1904) nor stored. LOADER stays `deferred:tier-4b` as a whole; the owner question is TF-36. (`fkLoader` returned with I89, part 4b-1c.) **Nested work (G242).** I78's deviation on nested asynchronous calls is fixed by starvation on both pools: `dispatch` and `dispatchCall` stamp when the last idle worker is taken, `checkStarvation` (from `checkDeadlines`, with `nextDeadline` waking for it) spawns one overflow worker per `starvationDelay` while a queue waits and nothing finishes, up to 64 beyond each cap, and at the call bound `refuseQueuedCall` decides the oldest queued call that has not started (`AsyncCall.started`, `refuseQueued`) MODULE_ERROR through `asyncTerminal`, so its callback runs on a lifecycle worker. `EngineLimits.starvationDelay` (50 ms) and `refuseDelay` (1 s). **C-08.** `artifact.stage` returns `sfControls`, mapped to `realization-failed` (LOADER l.628), when the private copy cannot be created, written, protected or hashed; a source that cannot be opened or read stays `artifact-unavailable` (l.622). **Payload depth (G241, IF-02).** `runtime.max_payload_depth` (128 to 1024, default 1024) becomes `EngineConfig.maxPayloadDepth` and `Shared.payloadDepth`; route, asynchronous, event and Runtime Control validators, `materialize_route`'s schema blobs (`SchemaBlob.depth`; the per-thread selected-contract cache is keyed by root and depth, so one thread may serve engines set apart) and `configcheck`'s declarations and values take it; `newEngine` and `openEngine` refuse a depth outside the range. **Marked payloads (G244, D-c).** `establish_route` refuses a selected contract that marks any payload with MODULE_ERROR after the authority and contract checks, before readiness (INTERFACE l.388); 8b's `vault_module` tests expect the refusal. **Small fixes.** The store reads and reaps only the side-record names it writes (`<kind>-<64 hex>.cbor`), so AppleDouble `._*` files on exFAT are left alone; `test_observe` uses `Slow`; the owner's S4 tests carry G243. **Deviations kept (fable-review §7.3).** Bindings are never unloaded (TF-03). A context returned with a failed init is not destroyed (INTERFACE l.1631-1635, l.1662), now tested. The Host Embedding API's `destroy` overlapping another call (RUNTIME l.4081-4082) and forged or stale handles (l.4065) are host preconditions. 128 lifecycle jobs that each wait for work queued behind them can still stall (G242). **Tests (11a).** `test_async` (`run.async: starvation`, 3: overflow for calls from call workers and from module-owned threads, the refusal past 128, completion callbacks deeper than 64; `run.depth`, 1: the configured depth and one deeper through synchronous and asynchronous calls and responses, events and Runtime Control), `test_config` (a configuration value at the depth), `test_host` (`max_payload_depth` bounds), `test_engine` (a failed init that writes a context), `test_realizer` (C-08; a changed digest pin is a fresh acceptance), `test_routes` (one lifecycle target per instance), `test_store` (2: names it did not write; a realizer's text is not stored), `test_observe` and `test_authority_module` (a realizer failure is `other`, its text neither disclosed nor stored), `test_audit` (the marked contract refused), `test_kit` (RUN-0074). With the starvation check disabled the three starvation tests fail. **11b. Spectrace.** The status grammar gains `deferred:tier-4b`; `gate --closed-tier N` (repeatable) fails on any default, section or unit status that defers to a closed tier, and the gate prints the deferred units per label. **Schema suites.** `tests/support/schemasuite.nim` builds, from the accepted model a generated module embeds (`rcDocuments`, `caDocuments`), each rule's smallest and largest value (required fields only and every optional field; minimal and maximal sizes, ranges and list lengths; each arm of a top-level choice), which must validate and round-trip byte for byte through the generated Nim codec, and values just outside the rule's bounds (a size, a range, a literal, a choice, an unknown field, a missing required field), which must be refused. The values come from the model and the verdicts from the schema, not from the code under test. `run.schema` (`tests/test_rc_schema.nim`, 111 tests) covers every rule of the Runtime Types and Runtime Control documents (RUNTIME §9.2, §9.3), the permission-settings rules among them (consistency item C28), and `cap.schema` (`tests/test_ca_schema.nim`, 51) every rule of the Capability Authority contract; each has one test per rule named by the rule's unit id and a coverage test that every rule of the document is listed and every map or variant rule has a codec. **11c. Tags, inspection, claims and docs.** Every claims file names `deferred:tier-4b` and none names `deferred:tier-4`. RUNTIME (for the Runtime engine; the host supplies the orchestration module, whose duties `docs/HOST-CONFIG.md` lists under "Orchestration duties"), CONFIG, the Capability Authority and TRANSPORT are claimed, with the Runtime's INTERFACE units; LOADER is `deferred:tier-4b` as a whole (S11-1 option (b)): its tests keep their `[LDR-…]` tags as evidence, and its one inspection item is withdrawn, the LDR-0042 finding kept as a comment for Tier 4b. SYSTEM BCP is Tier 4b by default, with BCP-0004, BCP-0073 and BCP-0098 claimed, the duties of specification authors (BCP-0026, BCP-0029, BCP-0052 to BCP-0060) out of scope and the QUIC and Package Manager realization profiles (BCP-0032 to BCP-0035) Tier 5; SECURITY CONSIDERATIONS is Tier 5 by default, with SEC-0021 claimed and SEC-0057 Tier 4b (G244). Closing the tiers found two stale labels, relabelled (the owner confirmed both on 2026-11-13): BCP §5 (`deferred:tier-1`; none of its units is a Tier 1 area, so it takes the Tier 4b default) and PKG-0275 (`deferred:tier-3`; G156 is open as NP-15, so `deferred:tier-5` while NP-15 is open). The flake's `spec-gate` runs `spectrace gate --closed-tier 1 --closed-tier 2 --closed-tier 3 --closed-tier 4`, and the gate also fails on an inspected unit that is not claimed. **Sweep.** Every claimed unit nothing referenced (RUN 237, IFC 89, CAP 31, CFG 9, BCP 2) was mapped to the test that shows it, an inspection item with its reason, or a new test: 96 existing tests gained tags (the CA policy test in `tests/test_host.nim` also checks the authority's contract, RUN-0018); inspection items RUN +41, IFC +13, CAP +6, CFG +3, BCP +2 (each under a `# <group> (DECISIONS I88)` comment); 19 new tests show what was built but not shown: IFC-0778 and IFC-0952 and an extended IFC-0780 (`tests/test_async.nim`), IFC-0249 (`tests/test_audit.nim`), CFG-0133/CFG-0135 and CFG-0149 (`tests/test_config.nim`), IFC-0774 and CAP-0376 (`tests/test_events.nim`), IFC-0204 (`tests/test_kit.nim`, with the events-only `beacon` kit fixture), CFG-0109 (`tests/test_rcevents.nim`), RUN-0293, RUN-0899/RUN-0903, RUN-0547/RUN-0548, CAP-0044, IFC-0942, IFC-0944, RUN-0087 and RUN-0155 (`tests/test_routes.nim`), RUN-0015/RUN-0016 and RUN-0855 (`tests/test_runtime_authority.nim`); IFC-0207 and IFC-0746 are out of scope (a hand-written module's duty; a provider exporting `_MODULE_async_api`). **Three holes found and fixed.** (1) A Capability Authority whose host record omitted `primary_contract` was bound with no provider record (RUNTIME l.165-173, l.1420-1421, l.1647): host configuration now sets the pinned contract on that record, and the engine never binds an authority instance without a provider record. (2) `execution_release` did not close admission while an entry admitted before it still held the invocation (INTERFACE l.2177): the entry guard now refuses once released. (3) `logos.schema` was answered from the consumer's construction input, through a per-thread cache keyed by root that the first `materialize_route` on the thread filled, so a copy of an interface document differing only in a comment was returned instead of the provider's (RUNTIME l.432-434, l.513-514): the engine now builds each contract's `logos.schema_response` from the provider's validated surface when it binds, and admission hands it to the boundary; the construction input only checks the request. [IMPL] A provider never bound has no surface, so `logos.schema` on a route to it is NOT_READY, as `describe_provider` is (l.660). **Docs.** `docs/CONFORMANCE.md` "What is claimed at the end of Tier 4"; `docs/HOST-CONFIG.md` "Orchestration duties", "Runtime limits", "Loaded code" and the authority record's contract; README; SPEC-STATUS closes Tier 4. The realizer's headers no longer call it a Module Loader. | 2026-11-13 |
| I89 | IMPL | Tier 4b step 4b-1: the Module Loader as a module (LOADER §1-§14; RUNTIME l.165-173, l.1635-1667, l.3527-3528, l.3754, l.3820-3825, l.3863-3864; BOOTSTRAP l.287-290; G48, G56, G57, G230, D14, C-10, K4, K5, K7, K10; G246-G253). Part 4b-1a: the contract; 4b-1b: the module; 4b-1c: the engine; 4b-1d: loss, claims, docs | **4b-1a. The contract.** LOADER §3-§10 and the Abstract's module block are mirrored under `spec/mirrors/LDR/` and accepted as a system contract (`AcceptOptions(system: true)`) with the Runtime Types and Configuration documents supporting; lcn-gen generates `loader/logos_module_loader_types.nim` and `…_kit.nim` (`nimble regen`, checked by `test_nimgen`). `loader/contract.nim` recomputes the pinned contract root and the five method roots from the mirrors (`loaderRoots`, `loaderContract`) and reserves `LoaderModuleName`, `LoaderInstanceId` and `LoaderBindingId`, each `logos_module_loader` (G246). `ldr.schema` (`tests/test_ldr_schema.nim`) covers every rule through `support/schemasuite`, plus the response arm selection and the descriptor arm by strategy. **4b-1b. The module.** `logos_module_loader` is a `direct_static` kit module whose state lives on one Loader thread (`loader/core.nim`: the realizer, plain values over channels, one FIFO per instance ordering realize, release and apply; status and capabilities never wait; closing answers what is queued). `runtime/sidetable.nim` is the private handoff (D14, C-10): inbound per instance (Runtime Control binding, publish, invocation access, and the failed phase the Loader writes back, G250), outbound per realization id (dispatch, free, asynchronous API, context, declared events), one lock, shared memory, plain pointers. `runtime/realizer.nim` gains strategy drivers (`capabilities` from them; a strategy without one is `unsupported-strategy`) and the checks a calling thread runs on what a hook returned (`admissible`, `checkInit`, `completeApplyChecked`); no failed realization is retained at `realize` (R2). `loader/provider.nim` holds the handlers: only a SYSTEM_SERVICE caller is served, NOT_AUTHORISED otherwise, after the kit's schema check (G251); bind and init run on the calling worker behind the invocation barrier, with a cancellation check before each; the protected wiring is keyed by the address of the Loader attempt's Runtime Control binding and refuses statics naming the Loader. `test_loader` realizes the Loader through a bootstrap realizer (`support/loaderharness`); the realize, live configuration and release suites move there from `test_realizer`. Nim 2.2.14's `=wasMoved` fault (upstream issue 6) is worked around in the Loader's request and reply types. **4b-1c. The engine.** At open, before the open is answered, a bootstrap realizer whose only registration is `loaderStaticRegistration()` realizes the instance `logos_module_loader` (host origin, the pinned contract as its primary contract; retained in the store and re-established at every open as G191 does for orchestration; no execution decision and no `execute` check, G253, the settings hook `provisionBootstrapSettings` empty under G229), then `checkLoader` binds it once it is `ready` with the pinned primary contract and `list_capabilities` names a strategy (RUNTIME l.1645-1650); the binding follows the instance (l.1657). Every other realization, release and live configuration is a `jkLoader` job: `systemCall` into the Loader's dispatch with a SYSTEM_SERVICE context; `runtime/loaderbinding.nim` encodes the requests and decodes and checks each reply on the worker; the call surface is accepted on the Runtime thread, as the bootstrap binding is (accepted contracts share references with the accepting thread's schema caches), and the Runtime thread applies every transition. `RealizationView` (`mechanism`, `id`, `issuer`, the outbound handoff, `unresolved`) replaces the realizer's record in `Inst`; a `realize` not yet answered is `unknown` (G227 follows it), and the startup deadline wakes the Runtime thread for it. Classifications: `fkLoader` returns (`loader-<code>`, RUN-1053), stored and read back; `realization-failed` with the failed phase `init` is `initialization-failed` (G250, R1); an invocation failure is `other`. Summaries report the strategy; the Loader itself `implementation-specific` (G57); G230's interim ends. The Loader instance: `stop` is NOT_READY while it owns a realization (K5), accepted otherwise (its release waits for calls into it, as any provider's, IF l.1997), after which every start is NOT_READY; start and recovery when it is not `ready`, and retirement, are NOT_READY (G247); routes whose contract or provider is the Loader's are NOT_AUTHORISED with no decision about them (G251); its id, module and binding are reserved in `create_module`, static registrations, `logos_runtime_register_binding` and the host configuration (instances, declarations, orchestration; G246). Shutdown releases every Loader-owned realization first and the Loader last, only once it owns nothing and runs no call (RUN-1075, R3). A duplicate static registration keeps the first, as before. The side table belongs to the engine handle (made before any thread, freed after all have left). **Test hooks (D27 revised 2026-11-13, R8).** `lcnTestHooks`, set only by `tests/config.nims`; `base/testhooks.testHooksMarker` puts a marker constant in each hook module's binary; the flake check `no-test-hooks` requires it in a probe and finds it in no deployment package or app; `host.setPolicyForTests` moves under the define; the first new hook is the Loader's request journal (`loaderJournalForTests`, kept in the side table). Tests: `test_loader_engine` (the instance, realization through the bound Loader, classifications, lifecycle and routes, shutdown order); the other suites see the extra instance through `support/withoutloader`; `test_recovery` waits for `unknown` where it waited for the end of a bind. **4b-1d. Loss, claims and documents.** Lost answers (G252): a `realize` or `release` whose invocation fails or whose reply is lost is followed by `get_status` (`lcStatus`, `resolve`), and one that cannot be resolved leaves the instance `error` with its realization unresolved (`LostAnswer`); `loaderFailure` is renamed `bootstrapFailure` and classifies only the bootstrap mechanism's errors. Loss (RUNTIME l.3813-3825; G246, G249): `loaderLost` marks the Loader `error`, invalidates its binding and sets `Shared.loaderLost`, so queued calls are answered without reaching it; every instance it owns becomes `error` (`other`, "its Module Loader failed") with its realization unresolved and lost (`RealizationView.lost`), its routes failed and its intent kept, and a reply that arrives later is recorded and never used (`lateReply`). Owning nothing, the Loader is released; owning something, `termination` names the instances, the diagnostic "termination required…" is written, `onTerminationRequired` is called once, `wait_for_shutdown` adds "; the Module Loader failed: the host process must end" and `tryClose` is NOT_READY with that text. A stop of an instance it owned is accepted (intent cancelled, still `error`; R4). **Test hooks (D27).** `LoaderFaults` in `runtime/plumbing.nim` (`reportFailure`, and per method `failInvocation`, `loseReply`, `garble`, `stall`, each taken by the next call of that method) through `setLoaderFaultsForTests`, `releaseLoaderStallForTests`, `clearLoaderFaultsForTests` and `stalledLoaderCallsForTests`; `confirmTerminationForTests` stands in for the protected mechanism's confirmation: it waits for the Loader's calls, looks up a realization whose id is unknown with `get_status`, releases what remains through the Loader (`confirming` calls, served after loss) and marks it absent, then releases a lost Loader. **Claims.** LOADER is claimed for the direct strategies (G248), with §5.3, §5.4 and the hosted units `deferred:tier-4b`; RUNTIME's Loader-conditional rules are claimed; the R-loader inspection items give way to tests, the other RUN, CAP, CFG and BCP reasons that named the realizer are rewritten, and `conformance/inspection/LDR.toml` covers LDR-0006, LDR-0010, LDR-0021, LDR-0022, LDR-0042, LDR-0088, LDR-0118 and LDR-0152. G110's enforcer is Runtime admission. Documents: HOST-CONFIG "The Module Loader", CONFORMANCE "What Tier 4b step 4b-1 changes" and "Test hooks", SPEC-STATUS, README. Tests: `test_loader_engine` (lost answers, loss, a release held past the shutdown grace, RUN-1076, and the realize request's encoding for LDR-0023 and LDR-0028); RUN-1001 in `test_routes`, RUN-0999 in `test_persist` and `test_host_dylib`; the tags of LDR-0061, LDR-0069, LDR-0070, LDR-0084, LDR-0085, LDR-0143 and LDR-0162 on the tests that show them. A fix on 4b-1b, in its own commit: the Loader's thread releases its per-thread state when it ends (LeakSanitizer found the cycle collector's root buffer left behind), and `test_loader` frees the contexts nothing may destroy. Plan R15 (the aarch64 MSan skip list) is not applied: neither `test_loader` nor `test_loader_engine` maps a dynamic library. A Tier 4 race closed: a realization that arrived after the startup deadline but before the Runtime thread's next deadline check still made the instance `ready`; `adoptRealization` now checks the deadline itself (RUNTIME l.664-669), which the G190 test below needs to be deterministic. G190's new case is tested by a startup deadline that passes at once: the open is MODULE_ERROR "the Module Loader cannot start: startup-timeout", and a new engine then opens on the same directories. After the merge, CI (refc) found an authority stop in `test_runtime_authority` past the route fixture's 300 ms stop deadline: a stop now releases through the Loader on a lifecycle worker, and a worker's first Loader call loads that thread's contract tables (about 40 ms under refc on an idle Mac; before 4b-1 such a stop took 0-4 ms). The same run found a provider stop in `test_routes` under ASan past it the same way (a release on a new worker took about 140 ms on an idle Mac). The route fixture's stop deadline is now 10 s × `Slow`. Only the cases that wait for the deadline to pass keep 300 ms × `Slow` (`PassingStop`): three in `test_async` (IFC-0768, IFC-0778, IFC-0780), one each in `test_observe` (RUN-0640), `test_rcevents` (RUN-0630) and `test_routes` (IFC-0740), and the second engine of `test_recovery`'s retirement case (RUN-1006). The same CI run found `test_loader` failing under TSan: the Loader's thread stored its live count after answering a mutation, so `liveCount` read right after a `release` could still count the released realization; the count is now stored before the answer. Only tests read that count: `get_status` goes through the same inbox and already saw the release. A later CI run (43589472593, refc) failed `test_engine`'s RUN-0796 case at the open itself: the case's 150 ms × `Slow` startup deadline also bounded the Loader's start. The Loader now has its own deadline (G61, amended 2026-11-14), from the open through its binding checks. | 2026-11-13 |
| I90 | IMPL | Tier 4b step 4b-2: transported local routes, the Runtime side of transport (RUNTIME l.51-53, l.161, §4.1 l.762-806, §4.2 l.895-946, §6.2 l.1147-1175, §7.5, §9.3 l.2073-2086, l.3004-3009, l.3086-3138, l.3466-3492, §10 l.3838-3866; TRANSPORT §3.1, §5.2, §6, §8.1, §8.1.1, §8.2; INTERFACE l.52-66, §2.5, §2.9; LOADER l.192-193; CA §11; G58, G164, G165, G174, G175, G177, G241, G251, G254-G261; NA-04, TF-15, TF-23; K8, K11, K12, K13). Part 4b-2a: plumbing, tickets and the Runtime-served endpoint; 4b-2b: the consumer's transported handle; 4b-2c: events and the publish adapter | **4b-2a. Routing** (`runtime/routing.nim`, G254): `lcn.app_config.routing` rules select `local-transport` per (caller, callee); default direct; refused for the Module Loader, Runtime Control as callee, and on Windows. The mode is fixed at establish. **Plumbing** (`runtime/tport.nim`): one transport I/O thread per engine, started at start only when a rule selects local transport; its sink posts `mkIo` to the Runtime inbox, so every I/O event is handled on the Runtime thread (I75); the Runtime thread submits only uncharged commands; a users guard orders `stopTransport` after every port call. `runtime.endpoint_dir` (default `<work_dir>/endpoints`, made 0700 and checked at start) and `lcn.app_transport` (the `TransportConfig` fields; the decoder depth is the engine's, G241). chronos sets SIGPIPE to SIG_IGN for the process when the library loads (documented in HOST-CONFIG). **Transport extensions** (10a code): E1 `cmdPublishConn` (an ordinary Event to one connection's subscriptions); E2 `evPublishResult` for every scoped publication; E3 `logos.schema` goes to the owner as an introspection dispatch and is answered with `cmdIntrospect`; E4 a `HelloCheck` the owner runs after the schema check and before redemption. **Tickets** (`runtime/sessionauth.nim`): a `TicketStore[RouteBinding]` on the Runtime thread, issued at establish and renew of a transported route (min(route end, 60 s) on the engine's monotonic clock); the live answer, with `invocation`, goes to the consumer and the call record; the retained answer is redacted, so a replay has no `invocation` (G255); every route end revokes; `checkDeadlines` sweeps. **Runtime-served endpoint** (`runtime/served.nim`, G257): one per provider realization, made at the first transported establish, stopped when it leaves `ready`, removed with its last session. The engine is its Session Authority: the Hello is judged by `acceptHello` with a state check (route ready and transported to this endpoint, provider realization current, consumer attempt current) before redemption; each Request is an `AsyncCall` with a session origin, admitted by `admit` and run on the call workers, committing under its ticket's lock (a busy budget is retried outside the locks); Cancel commits CANCELLED; a session past its ticket's decision terminates. **Route end** (G260; G174 amended): revocation or expiry answers in-flight Requests NOT_AUTHORISED and terminates; a transport failure closes; a readiness end drains to the stop deadline or shutdown grace. **Ports** (`runtime/ports.nim`): SessionAuthority, EndpointOrders, LinkOrders, `CallRef`, `sessionOrder`, for 4b-3. **Tests**: `test_transported`, `test_host`, `test_transport_io` (E1-E4), `test_transport` (E4), `test_rc_schema` (RUN-0501). **Claims**: RUN-0220, RUN-0226, RUN-0229, RUN-0230 (in §6.2), RUN-0501, RUN-0541, RUN-0543, RUN-0544, RUN-0623, TRN-0153, TRN-0195, TRN-0317, CAP-0254, LDR-0021 (out of inspection); RUN-0045, RUN-0552, IFC-0010 to tier 5; IFC-0524's inspection reason rewritten. **4b-2b. The consumer's transported handle** (`runtime/transported.nim`, engine "Transported route handles"; G164, G256, G258-G260): [IMPL; plan §2.6] the caller half runs on the Runtime thread, which receives every I/O event: one `Link` per materialized handle (one connection, one Hello with the route's one-time ticket, G177's generation), in an engine table by connection id; a materialization and each synchronous call park their reply on the link until its event answers (`rqLinkCall`); asynchronous calls are sent by the Runtime thread, and a prepared one holds its link (`aeLinkHold`, `aeLinkDrop`). The invocation material is kept with the links (G258). The handle has two codes, the route's end cause and the first observed one (G22 re-check); a lost connection is TRANSPORT_ERROR (G256). An asynchronous call cancelled or timed out sends Cancel (IFC-0729). `materialize_route` returns only once the provider holds the session (RUN-0800, RUN-0802). Validation that needs the construction input runs on the consumer's thread (`linkCall`), so a failure carries the same detail as on a direct route. Subscriptions through a transported handle are MODULE_ERROR until 4b-2c. Test hooks under `-d:lcnTestHooks`: `closeSessionsForTests`, `failNextConnectForTests`, `spoilNextTicketForTests`. **Parity suites**: `test_routes_lt`, `test_async_lt`, `test_routes_ca_lt` rerun `test_routes`, `test_async` and `test_routes_ca` with every route to the meter and sensor modules over local transport (unix-stream only); what differs is in `docs/CONFORMANCE.md` ("What 4b-2 changes"): the live answer carries `invocation` and a replay does not (G255); a further handle needs `renew_route` (G258; the fixture renews); the provider's deferred surface serves every Request (the wire does not carry the caller's mode); a call still running past a provider's stop deadline is TRANSPORT_ERROR (G260); events wait for 4b-2c (four cases skipped). **Claims**: RUN-0007, RUN-0008, RUN-0014, RUN-0800 to RUN-0806, TRN-0187, TRN-0191, TRN-0278, IFC-0729 and INTERFACE "Abstract/Execution-Boundary Invariance"; IFC-0480 and IFC-0948 move from inspection to tests. **4b-2c. Events** (engine "Transported events", `runtime/events.nim`, `transported.nim`; G165, G175, G261): [plan §2.7] **provider side**: a session's Subscribe is activated on a call worker (`cjActivate`, `rqActivate`) in a direct subscription's order, with the `subscribe-event` decision (an explicit deny is the SubscriptionResult NOT_AUTHORISED), and recorded on the session before the answer, so a publication that follows the caller's `LOGOS_OK` finds it (Rev R7); Unsubscribe removes it. **Caller side**: `subscribe` through a transported handle checks locally as a direct one does, registers an inactive `LinkSub`, sends Subscribe and returns only after the matching SubscriptionResult, writing the id then (RUN-0192); the Runtime thread activates the subscription before it wakes the subscriber, so an Event that follows is queued. Events are queued per subscription on the Runtime thread and handled by the G178 event workers (`rjLinkDrain`), one drain per subscription, in commitment order; each handled Event releases its credit (RUN-0234). Unsubscribe waits for the SubscriptionResult and for a handler that runs, except its own; the route's end or a release discards queued Events and releases their credits, and no handler starts afterwards (TRN-0290). **Publish adapter** (E1): an ordinary publication reaches direct subscribers first [IMPL], then sends each subscriber connection one Event for its matching subscriptions (RUN-0246), admitted per connection on the Runtime thread (`rqDeliverConn`: both decisions, G175; a subscriber's deny skips that Event only, K40) and submitted with `submitWait(cmdPublishConn, tlClose)` (G165 (a); D3 (a), G261). **Scoped publication over a session** (E2): checked as a direct one, then `cmdPublishScoped` with `tlReport`, and its verdict (`evPublishResult`) awaited: OK; NOT_READY after the Response or CANCELLED was committed or the connection closed; NOT_AUTHORISED after an authority end or a denied `publish-event`; MODULE_ERROR when too large. A new connection never inherits a destination (RUN-0832). **Shutdown** (plan §2.9): handles observe NOT_READY before any realization is destroyed; sessions drain within the grace; link subscriptions end with their links; a publication still waiting for a verdict is answered NOT_READY when the Runtime thread leaves. **The ends of a route, one row each** (`ports.EndPolicies`, `engine.routeEnd`; the table is in G260; G174 (a); owner batch B 7; RUNTIME l.621, l.623, l.1065, l.3224, l.3226-3227, l.3850; TRANSPORT l.543; INTERFACE l.2101): revocation and expiry terminate; a transport failure, a serve failure, K12 and an establishment that issued no ticket close at once, as will, in 4b-3, a side whose process or host is gone; the others drain, each to its own bound: `close_route` (`stop_deadline` from the end [IMPL]), a provider stop (the provider's stop deadline), shutdown (the grace), a consumer stop (the consumer's stop deadline), and a consumer or provider failure (the drain deadline of the failed instance's cleanup release, here `stop_deadline` from the end [IMPL]). Batch B 7 named only the provider stop, shutdown and `close_route`. The consumer's stop and failure and the provider's failure are our choice within G174 (a) (Fable, 2026-11-13): **listed for the owner's next approval**. At every end, admission closes at once, each in-flight invocation is marked cancelled and its provider notified, and nothing waits past the bound. **Tests**: `test_transported` (the 4b-2c cases, among them a consumer stop, a consumer failure and a provider failure that drain; the `bulk` kit module publishes an Event of any size), `test_events_lt`, `test_events_ca_lt`, and the event cases of `test_async_lt` turned on. Parity differences (CONFORMANCE): handlers run on event workers after the publication returned (two direct-only cases skipped in `test_events_lt` and `test_events_ca_lt`, two in `test_async_lt`); a subscriber's explicit deny at delivery keeps the subscription (K40). **Claims**: RUN-0192, RUN-0234, RUN-0246, RUN-0832, TRN-0290; G165 and G261 built | 2026-11-13 |
| I91 | IMPL | Tier 4b step 4b-3: the Module Host (LOADER §3, l.103-108, §5.2, §6, §9; RUNTIME §4.2.1 l.950-976, l.664-669, l.3006-3007, l.3818-3826; CA l.324-325, l.349-353; G178, G225, D14; G264-G275; K1, K2, K3). Part 4b-3.1a: the program, spawn and supervision, the carrier, lane 0 and Runtime Control; 4b-3.1b: ends, deadlines and the restart lock; 4b-3.2: hosted providers; 4b-3.3: hosted consumers; 4b-3.4: invariance, claims, docs | **4b-3.1a. The program** (`logos-module-host`, `src/logos_core/host/`, G264): found only through `runtime.module_host` (absolute, a regular executable not writable by others, checked when the configuration is read); `runtime.module_host_env` is its whole environment; one host per hosted realization; it runs the realizer's own phases on a lifecycle thread, so a hosted realization fails with the direct one's errors. **Supervision** (`runtime/hostsup.nim`, `hostspawn.c`, G265): `posix_spawn` on the supervision thread with fds 0-5 only, its own process group, an empty mask and default signals; `waitpid` per pid; every end kills the group and is confirmed by ESRCH; no restart. **The carrier** (`runtime/carrier.nim`, `carrier.cddl`, G266): a socket pair per attempt, length-prefixed deterministic CBOR, lanes 0 and 1, the Transport floor plus 64 KiB; anything unexpected is carrier loss (exit 70). **The Loader** advertises `hosted_dynamic` in a `process` placement only with a host program; sandbox and container stay unsupported; `lcn.app_config` accepts a hosted implementation only as an artifact (RUN-0284). **Runtime Control** (G267, G271): a host's requests run through the attempt's own direct binding on proxy workers; events wait for the host's handler, so G178 and G225 hold as direct. **Execution scope** (G272): `local-transport` with placement `process`. Fixed in passing: the execution summary's hosted placement. **Claims**: RUN-0169, RUN-0170, RUN-0171, RUN-0172, RUN-0180, RUN-0284; LDR-0034, LDR-0040. **4b-3.1b. Ends** (G268): supervision tells the Runtime of each confirmed end before the Loader's waits return; an end after the host's own terminal answer is the Loader's to classify, one the Runtime asked for keeps its classification, one during a release belongs to it, and any other is `error` with `host-terminated` (the carrier's failure as its reason when it broke), the routes failed, the Loader record `failed` (LOADER l.497-499) and released, intent kept, nothing restarted. **Deadlines** (G269): the startup deadline ends a host still in `realize` (`unknown` until confirmed); the stop deadline and the shutdown grace end the host after recording `cleanup-timeout`; a hook still running a stop deadline after its apply deadline has its host ended. **Live apply** (G270): the hook runs in the host; a host that ends meanwhile gives the caller MODULE_ERROR and `host-terminated`. **Loader loss**: each owned host is ended and its cleanup resolves when the end is confirmed; the Loader, then owning nothing, is released, and shutdown waits for that release as for any other (`shutdownComplete`); the Loader's thread ends leftover hosts as it stops. **Restart lock** (G275; `runtime/hostlock.nim`): `<work_dir>/hosts/<hash>.lock`, fd 5 of the host; a lock still held at restore keeps the instance `unknown` and its start NOT_READY until it can be taken. Test hooks: `moduleHostForTests`, `realizationForTests`. **Claims**: RUN-0227, RUN-0812, RUN-0813, RUN-0814. **Found by the Linux flake on the merged tip** (11894d1), both timing-dependent and fixed on 4b-3.1: the host's reply slots (`host/state.nim`) are reused and never closed, as the Runtime's, the Loader's and the Authority's are, because Nim 2.2.14's `send` signals a channel after releasing its lock, so a receiver whose `recv` has returned cannot tell when the sender is done with it, and `close` requires that no thread still accesses the channel (its doc comment): documented behaviour, not a Nim bug, and reuse is the [IMPL] answer (TSan on Linux saw a slot destroyed while the main thread still signalled it; the Mac runs, on the same Nim 2.2.14, did not hit that interleaving); and a shutdown requested while the lost Loader's own release still ran completed at once with MODULE_ERROR naming the Loader (MSan, S-14). **Found by the Linux flake on be985f6 and a785d36** (LeakSanitizer: `test_hosted-asan`, and on a785d36 also `test_hosted_routes-asan` and `test_boundary_invariance-asan`), both test-only and fixed after the merge: `modulehostbuild.hostPids` read each `/proc/<pid>/exe` with `expandSymlink`, which raises for a zombie after making its string result, and ARC/ORC never frees a raising proc's string result (Nim 2.2.14, upstream draft 13), so every host a test ended by force leaked one; it reads with `readlink` into a buffer now. And the probe module kept its memory after `_MODULE_destroy`, which in its direct runs (S-3, S-4 and S-5's reference runs, the route suites' direct placements) is the test process's; it frees it now when no handler is inside and no route callback holds one of its tags, and keeps the rest reachable from its library, which the Runtime never unloads. The same a785d36 flake failed `test_permissions_ca-refc` once: 1d1da85's RUN-0891 case (G281) lowered the engine-wide startup deadline to 300 ms × `Slow` before the parity pass's authority started, and that start overran it under refc on a loaded framework.lan; the case now lowers it only before the resumption it tests (`setStartupDeadlineForTests`, a test hook) [IMPL]. The Mac cannot see either: Apple clang's ASan on arm64 has no leak detection ("detect_leaks is not supported on this platform"). **Found by GitHub CI on 897216d** (2026-11-15), on runners five to eight times slower than framework.lan, which had passed the same checks; test-only, fixed after the merge [IMPL]. S-5 waited for all of a host's deliveries within one bound, and each crosses the carrier and two threads on each side, one at a time (G178; about 135 ms each on a loaded Mac), so `settled` bounds each line instead. S-9's next start had to finish within the deadline the case is about, which now binds only the first start (`setStartupDeadlineForTests`). C-8's call 2 timed out before the provider held it, at 1000 ms × `Slow` on 897216d and at 10 s under ASan on 19a6274 (CI on 19a6274, the same day; its way to the provider took 0.8-1.2 s under ASan on a loaded Mac): its timeout is five times call 1's round trip measured in the case, at least 10 s, and the case now checks that the provider held the call before the timeout passed. The invariance scripts' call 2, a timeout that must not pass, had an unscaled 5000 ms timeout; it is 60 000 ms × `Slow`, which costs nothing, the provider's failure answering first. In `test_boundary_invariance` a direct consumer's materialization failed, its cause unseen because the probe then called through the empty handle (UBSan under ASan; under TSan, Nim's signal handler in the probe library allocating, reported as a signal-unsafe call): the probe answers `no route` for such a handle now, and the deadlines a materialization waits on, the transport's Hello and admission ones, are × `Slow`. `test_hosted_routes` joined the aarch64 MSan skip list (I77). CI on eed9d58 (the same day) failed the x86_64 MSan shard that builds four suites at a time beside the hosted ones, on a slower runner: with a hosted consumer and a hosted provider, the probe's answers to a materialization and to each call that publishes an Event (three carrier round trips more; about 0.2 s each with orc on an idle Mac) came after their 30 s bound, so `test_boundary_invariance` read them as later commands' answers. In `test_hosted_routes`, P-11 and P-12 failed with their details lost when P-10 called through a route handle that had not materialized (a direct consumer's Hello with a host, bounded at 15 s). The waits for what comes in both suites are 60 s × `Slow` now, as are `test_hosted_routes`' Hello and admission deadlines, which no case there is about, and its `hear` answers NOT_READY for a handle that did not materialize; `test_async`'s depth case (G241) waits as long for a 1024-level payload's completion. The msan group runs as three CI shards (`flake.nix` `ciShardCount`; the owner chose split jobs over a longer limit on 2026-11-14): its second x86_64 shard of two passed the 90-minute limit, the first taking 52 minutes. CI on 5ddd886 (the same day) passed the limit in the second x86_64 asan shard of two (the first took 69 minutes; `test_boundary_invariance` alone took 31 minutes there), so asan runs as three shards too. Under aarch64 MSan, `test_async_lt` (`test_async` over local transport) found G242's oldest queued call not yet refused 30 s after the 128th call was held, with 128 held calls each polling their gate every millisecond. On an idle Mac the refusal comes one `refuseDelay` after (0.1 s with orc, 0.3 s with ASan, with or without transport), so that case waits 60 s × `Slow` for its completions; `test_async`'s `codeOf` is none before a completion, so a missing one fails a check instead of raising a defect. CI on b3af640 (2026-11-16): the second x86_64 msan shard of three was cancelled at 90 minutes, and the other two took 72 and 71 (38 to 46 on 5ddd886; aarch64 30 to 36). On two of the three runners the suites that ran on both days took a median 3.7 times as long, test_cddl (CPU only) 7.5 times, already from the first suite to finish. msan now runs as four shards. On the same runners P-5b's shutdown completed with an error after 32.9 s, and TRN-0381's connect failed after 13.3 s; neither case printed why. `test_hosted_routes` now bounds its hosts' graceful ends by a shutdown grace of 10 s × `Slow`, as `test_wipe_routes` does (P-5b's stop deadline already was; no case there is about the grace). P-5b prints the shutdown's error and the engine's diagnostics, and TRN-0381 prints the failed connect's code, cause and message. TRN-0381's margin is unchanged until a failure shows its cause. CI on 1ca4710 (2026-11-16): neither recurred, and the msan shards took 17 to 55 minutes. On macOS, H-5 (`test_module_host`) received the queued connection's Hello before `initialized`. The host's loop serves fd 4 before `initialized` is sent (`host/main.nim`), and the Runtime takes a Hello from a host with an endpoint whether or not `initialized` came first. So either order is correct, and the case now accepts both messages in either order. CI on 5887c5a (2026-11-16): x86_64 tsan's second shard of two took 81 minutes and asan's second of three 74, near the 90-minute limit. A shard's time was about 7 minutes plus its checks' build and test time over the runner's four parallel builds, and those two shards held the two heaviest suites (test_boundary_invariance 44 and 33 minutes, test_authority 23 and 12) with several of 12 to 17 minutes. The x86_64 msan shards of four took 55 to 68 minutes; however they were balanced, four would come to about 61. asan now runs as four shards, tsan as three and msan as five. Every group's parts are now dealt heaviest first, each check to the part with the least weight so far: `ciWeights` gives the ten heaviest suites their mean minutes in that run's x86_64 sanitizer jobs, and every other check a default of 5. On that run's times each asan, tsan and msan shard comes to about 45 to 55 minutes (round-robin: msan's five 36 to 63). A weight missing or gone stale only balances worse: every check is placed once, and evaluation fails if a group's parts do not hold its checks exactly once. CI on dc2e7ef (2026-11-16, x86_64 refc): in P-11, a hosted provider's in-flight Request was answered OK after its route was revoked. The order was the Runtime's: `endRoute` marked the route's calls cancelled before it queued their NOT_AUTHORISED answers (`asyncTerminal` and the session's termination), and the call worker wrote `call_cancel` to the carrier itself, while the answers waited for the host's sender. A cancel could therefore reach the host first. The meter returns on a cancel, and the host commits the first Response to reach its loop (G273), so its OK went out through a revoked route (CA l.917-918; TRANSPORT l.987-991). [IMPL] Now a route's end and a session call's terminal decision queue what the Runtime answers and orders before any call is marked cancelled, and `call_cancel` goes through the same sender behind them. The cancelled mark comes a few steps later in the same commit, which a provider in this process cannot tell apart. P-11b holds the Runtime thread right after the mark (`setCancelMarkDelayForTests`), so the cancel reaches the host long before the thread goes on; it failed with the same signature before the fix. CI on dc2e7ef (2026-11-16): the x86_64 sanitizer shards took 25 to 66 minutes (asan 42 to 64 on runners about 1.4 times slower, tsan 36 to 58, msan 25 to 66). `ciWeights` is now the mean of both runs' x86_64 sanitizer minutes for the twelve heaviest suites (test_host, test_orchestration, test_config and test_deployment in; test_hosted_permissions and test_observe_ca out), with a default of 6, and an orc-spec check, `<suite>-orc`, now weighs as its suite (it had found no weight). On either run's times the slowest x86_64 sanitizer shard comes to about 57 and 61 minutes, against 58 and 70 with the old weights. The jobs CI does not shard by weight came near the limit on the same run: the Linux Nimble test_refc shards of two took 66 and 69 minutes (77 suites; 68 on 19a6274, 2026-11-15), and macOS orc-spec, built whole, 73 (49 on 19a6274). Linux Nimble now runs three shards (`LCN_SHARD` k/3; on that run's suite times test_refc's come to about 36 to 43 minutes of suites, test's 22 to 28), macOS Nimble stays at two (44 and 46), and macOS orc-spec runs as `ciShards.orc-spec-1` and `-2`; macOS refc (52 to 60) and orc-release (49) stay whole. **4b-3.2. Hosted providers** (the owner's direct layout, 2026-11-14; plan §2.7 with R14-R16, R19): the Runtime makes the endpoint and hands its host the listener (fd 4); the host serves it with the Runtime's transport loop (`host/endpoint.nim`) and reports each session event and call without its payload on lane 2 (`runtime/hostio.nim`). The Runtime's provider half (`served.nim`) judges each Hello and keeps each session; a call worker admits each call with `rqAdmit` and sends the verdict (`admit_verdict`; `runtime/hostcall.nim`, `asynccall.nim` `runHostedRoute`). The host checks the payload with the Runtime's checks (`runtime/callcheck.nim`) on the contract it builds from the module's call surface (`host/selected.nim`), runs the provider on up to 64 workers, commits the Response (G273, the K38 interim) and reports the end with the commitments the capture retains (`call_ended`; G274, the K44 interim). Scoped publication asks the call worker (`scoped_check`, `scoped_admit`, `scoped_done`), ordinary publication the Runtime thread (`rc_publish`, `rc_deliver`; `events.nim` `hostedTargets`, `hostedDeliver`). `hostio.toMessage` sends a host no success, payload or introspection answer, so lane 2 has no output budget. Route mode: G272 (R10). Tests: `test_hosted_routes` P-1 to P-14 (P-13 traces every carrier frame for payload bytes, P-14 compares a hosted call record's roots with a direct one's), `test_carrier`. **4b-3.3. Hosted consumers** (the direct layout; plan §2.8 with R15, R18; G267): a hosted consumer's handles and connections are in its host (`host/consumer.nim`), which keeps each route's invocation material from the `establish_route` and `renew_route` answers it passes on and connects with its own transport loop to the peer identity and module the Runtime names. The Runtime keeps a hosted `Link` per handle (`transported.nim`: its pin, codes and observer registration, no connection) and admits each materialization, outcome, call, subscription change and observer installation (`rc_materialize`, `rc_link_result`, `rc_link_admit`; `engine.nim` `hostedMaterialize`, `hostedAdmit`); `rc_materialize` carries the module's construction input, from which the Runtime rebuilds the contract itself (RUN-0177; `hostsup.nim`). [IMPL] (planning session, 2026-11-14): the input is contract metadata, not a call or event value, and is sent once per handle on the control path, so the Runtime validates it and checks the reconstructed root in its own process (INTERFACE l.3878), never only in the process that runs the module; the frame is bounded by the carrier's frame limit (`CarrierFrameLimit`) and the input by 8 MiB (`MaxSchemaResponseBytes`). Route ends reach the host as `route_ended`, a connection's end the Runtime as `rc_link_closed`, and the handle's release as `rc_link_released`. Deviation from plan R11, recorded in G267: `route_ended_ack` and `route_cause` are replaced by the Runtime giving each handle's first cause. Every host gets the Transport limits (`init.transport`). Tests: `test_hosted_routes` C-1 to C-8 and S-18 (the probe kit's `serve` command thread), `test_carrier`. **4b-3.4. Invariance and claims**: `test_boundary_invariance` runs one case table (`tests/support/invariance.nim`: the meter kit's calls, introspection, validation, failures, events and asynchronous calls; the same through a deferred provider; every C shape of the shapes kit and the payload depth limit at the smallest `max_payload_depth`) from `probe_module` through one route handle in four placements, a direct or hosted consumer to a direct or hosted provider, and compares every answer (code, message, validation detail, response bytes), delivery and completion, and the selected contract, with the direct run; it found a hosted consumer's failures losing their detail, fixed in part 4b-3.3. The probe prints a result's detail. `carrier.cddl` drops `io_listening` and `io_serve_failed`, which no host sent (the host keeps its serve outcome and reports a listener it cannot serve as `init_failed`), so the Runtime no longer takes them from a host. `test_hosted_routes` adds C-1's check that the answers a hosted consumer gets carry `invocation`, C-9 (G261 for a hosted consumer whose route handler does not keep up) and C-10 (G244's refusal for a route with a hosted end); `test_module_host` H-5 and H-6 show the host's side of a provider's listener. **Claims**: RUNTIME §4.2.1 and §6.2, RUN-0200; LOADER §5.3 (LDR-0081 to LDR-0083, LDR-0101, LDR-0145 to LDR-0147); TRANSPORT TRN-0184 to TRN-0186; inspection items RUN-0173 and RUN-0179 (the host keeps no registry, selection or routing policy, only RUN-0174's invocation material; RUN-0179 holds by construction, every materialization being the Runtime's against current state) and LDR-0125 (a hosted cleanup returns only once the end is confirmed, so absence is always established); `out-of-scope` LOADER §5.4 (K3) and LDR-0163, LDR-0164 (K7). CAP-0065 and CAP-0066 stay with 4b-4 | 2026-11-14 |
| I92 | IMPL | Tier 4b step 4b-3b: erasure of marked payloads (INTERFACE §1.4.1 l.380-405, l.2121, §5.1 l.3357-3367; SECURITY-CONSIDERATIONS l.401-403; G244 re-decided as G277; G276, G278; S4b3b-1, S4b3b-2; K43). Part 4b-3b.1: the primitives, the Runtime, the transport and the host; 4b-3b.2: generated code, hosted ends, retention, claims and docs | **4b-3b.1. Primitives** (`base/wipe.nim`): `secureZero` (`explicit_bzero`, `memset_s`, `SecureZeroMemory`), wipes of seqs and strings to their capacity, CBOR value trees, BLAKE3 hasher states and payload commitments, `freeWiped` for shared-heap copies, and a per-thread marked scope that the commitment layer and the validators read. `encodeCbor` sizes its output once (`encodedSize`) and encodes each map key into an exact buffer, zeroed when the map closes (the output is byte-identical); `decodeCbor` pre-sizes containers, checks UTF-8 before it copies text and wipes its state on every error. **Scope** (G276): byte buffers of the Runtime, the transport and the Module Host wiped unconditionally at last use (l.405); trees, commitment intermediates and hashers when the side is marked, and unconditionally before the method is resolved. **Sites**: the ABI's exact message copies, size-headed `give` buffers and taken failures; the Runtime's route and asynchronous calls, completions, trails and retained roots; every transport frame body after its handler, partial bodies, framed copies once written or dropped, envelope commitments, delayed and cancelled params, outcomes and unqueued I/O commands; the host's endpoint and consumer records, outcomes and owners, events, and leftovers at a graceful release. A shared request copy is released only once execution is released and nothing holds it (IFC-0576). **Diagnostics** (G278): for a marked request the INVALID_PARAMS path stops before the first key taken from the payload (S4b3b-2 (b)). **4b-3b.2. Generated code** (marked declarations only; unmarked fixtures regenerate byte for byte): the kit's route wipes the checked tree, the typed request (`wipeTyped`, iterative, following a ref only when it is the sole owner) and the typed response and its encoding; `nimrt`'s checked encode and decode run in the marked scope and give a fixed message without a path; the typed C entries (`cmirror`) and the call helpers wipe their params, trees and staged mirrors; `kitFree` and `CallArena.releaseBlocks` keep each block's size and zero it whole (always); the kit's per-thread failure text is zeroed at the thread's next kit entry. **Found by the route tests and fixed**: `invokert.routeCall` dropped a provider failure's copy; `asynccall.ownedOf` and the caller's `session.onResponse` copied a result or a Response through `let`; `engine.linkDecide` dropped a late result; the host's `HostInv` kept its commitments when freed; the serving loop's `respondOutcome` dropped a late ok-Response's tree (CI on eed9d58, below). **IFC-0581** on direct, transported and hosted paths: a decision that retains a marked side refuses the call NOT_AUTHORISED before dispatch (`sensitive-retention`), in the one `admit` every path uses. **G244** (G277, owner 2026-11-14, batch C 14): lifted for the participants the Runtime controls, hosted ends included; refused only on a path kind without erasure (a remote mode; the `erasureMissing` test hook); no switch turns it off. **Free scan** (`base/wipeaudit`, `-d:lcnWipeAudit`, test builds only, under the test-hook rule): `free` and `realloc` renamed to a shim that searches each released block for registered patterns and records a backtrace (orc or arc with `-d:useMalloc`; not on Windows). An audit build of the Module Host is armed by the Runtime's `init` (`wipe_audit`, sent only after `setWipeAuditForTests`), arms on its main thread before the init goes on, and exits 97 at a graceful end that found a pattern; a host that is no audit build treats an `init` with `wipe_audit`, even an empty list, as carrier loss. **`wipe_audit`** (the Fable check, 2026-11-15): the field stays in every build's schema; `-d:lcnWipeAudit` without `-d:lcnTestHooks` is a compile error, so D27 stands as written and the existing `no-test-hooks` probe covers the scan (the separate wipe probe goes); only a test-hook Runtime writes the field (`loader/hosted`); the carrier trace exempts exactly `init.wipe_audit` (`hostsup.sendMsg`), so W-7 traces from before the hosts start; nothing under `logosd` calls `setWipeAuditForTests`. **refc** (G277's build condition): a refc Runtime refuses every marked route, a refc host fails a marked provider's `init` and a marked route's materialization; the owner accepted this orc-only claim scope 2026-11-15 (R5). **Non-claims** (CONFORMANCE): a host ended by force (K43); a refc build of the Runtime or the host, which never carries a marked payload; under refc, typed values reached through a ref in generated code; the kit's per-thread failure text until the thread's next kit call. **Tests**: `test_wipe` (W-1 to W-3, W-11, W-12 the channel messages' inline arrays), `test_wipe_routes` (the `vault_module` kit, whose contract marks `store`'s request, `fetch`'s response and both of `exchange`; W-3 in an audit host, W-4 direct, W-5 deferred with a cancel and a timeout, and the serving loop's late answer, W-6 transported, W-7 hosted provider and hosted consumer with audit hosts, the carrier trace and the hosts' stderr, W-8 generated entries and helpers, W-9 retention, W-10 the lift, and under refc the refusal, and a refc host under an orc Runtime), `test_audit` (the handwritten vault goes), `test_hosted_routes` C-10 (made, and refused with the hook; under refc refused), `test_module_host` H-15. The probe kit wipes its own request copies. The consumer's timer is joined at the release (`stopConsumerTimer`, after `_MODULE_destroy`): the last timer to return had ended unjoined (ThreadSanitizer "thread leak" on Linux). A test local declared without an initializer and first written in a branch leaked under ORC (LeakSanitizer on Linux, `test_wipe_routes`): Nim does not destroy it at its next write, nim-lang/Nim#26725 (reported upstream 2026-11-15 for a `ref`; a `seq`, a `try` body and `result` leak the same way, so no draft of ours). The local is initialized. `tools/lint/firstwrite.py` (the flake's `lint-first-write` check, beside I77's `lint-ctor-try`) rejects the pattern in `src` and `tests`, the generated kits included, and finds no other site: a value dropped that way is never destroyed, so never wiped. **AddressSanitizer** (test support, [IMPL]): an audit kit library keeps a file-local wipe registry (`-DLCN_WIPE_IN_LIBRARY`), since two images exporting `lcn_wipe_registry` are an ODR violation to Linux ASan; the refc-host W-10 case starts its hosts with `detect_stack_use_after_return=0`, since refc's stack scan cannot see ASan's fake stacks (nim-lang/Nim#26334, closed Won't Fix), and skips under gcc's ASan, where `nimbase.h` leaves the scan instrumented (`CLANG_NO_SANITIZE_ADDRESS` is clang-only; an upstream draft, not filed). **The free scan's attribution** (test support, [IMPL]; CI on eed9d58): the audit shim zeroes every block it releases, armed or not, and its `realloc` never releases part of a block by itself, so a hit is a copy the released block's owner held. On slow CI runners W-7 and W-9 had failed on hits in blocks whose owner never wrote a pattern: the symbolized x86 one was ORC's cycle-collector buffer (2304 entries of a cell pointer and a type, allocated uninitialized), released in `collectCycles` during a Loader call, holding all five patterns from memory a copy released earlier, while the scan was off, had left; the aarch64 W-7 block had a fresh such buffer's size (1024 entries). **The aarch64 W-5 hit was a real copy** (the canary alone, in a 40-byte block; symbolized against a cross build of eed9d58 with the same gcc 14.3.0, glibc 2.40 and hardening flags): the serving loop's `respondOutcome` discarded a provider's ok-Response to a request whose CANCELLED it had already committed without zeroing its decoded tree (`drainPending` and `CalleeConn.respond` zeroed theirs), and `callee.respond` released it on the I/O thread. Through a Runtime it is a race: the consumer's Runtime sends a Cancel at a timeout or a cancel, the serving loop commits CANCELLED, and an answer the provider's Runtime takes before it handles the Stop is still sent as `cmdRespond` (W-5's timeout step answers right after TIMEOUT). The discard now zeroes the tree (G276: whenever it is not sent). The other paths that drop a late, cancelled or unsent payload were checked against `drainPending` and `CalleeConn.respond`, and zero theirs: on the provider side `dropPending` (the connection closed), `callee.respond` (no tree before establishment; `handleIn` zeroes the command), `CalleeConn.onCancel`, `onRequest` and `close` (`dropParams`, marked), the Runtime's `sessionCommit` (the command, when the call is no longer submitted) and the host's `HostInv.respond` (answered already), whose loops end in `respondOutcome`; on the consumer side `CallerConn.onResponse` (a Response late after an abandon, for no request, or refused), `io/caller.callerEvents` (a marked tree, once re-encoded or not delivered), `io/caller.call` (a marked params tree, on every return), the Runtime's `linkResponse` and `linkDecide` (no call, or one a cancel or timeout decided) and the hosted consumer's `consumerEvent` (every event). W-5 adds the loop's case alone, `trnowner` standing in for both Runtimes (deterministic; before the fix it failed with the same signature), and a held `fetch` answered after its CANCELLED. The hosted cases' shutdown grace scales with `Slow`: an audit host's end under TSan on CI passed the 10 s default. **MemorySanitizer**: `lcn_secure_zero` marks what `explicit_bzero` zeroed as initialized, since MSan intercepts `memset` and `bzero` but not it (clang 21; test_wipe's W-1 read a wiped string's tail as uninitialized); the refc-host W-10 case skips under MSan, where refc's stack scan reads stack memory nothing initialized (its `registers` buffer, on x86_64 and aarch64); the aarch64 MSan checks skip `test_wipe_routes` (I77). **CI on 8522a1f** (x86_64 MSan, a loaded shard: the suites before it ran 8 to 20 times slower than on framework.lan): the hosted W-7 case from a hosted consumer failed, and the process then ended during the next case with nothing in the log, so the cause is not known. No free-scan report reached the log. The Runtime process's own would have, since it prints after fd 2 is back, but a host's report written after the case read its capture would not, so a missed wipe in a host is not ruled out. A hosted case sends the process's fd 2 to a file, and unittest2 prints a case's failed checks at the suite's end. Now a crash signal, a sanitizer's death and an exit while fd 2 is captured replay the capture first; `vaultHandle` raises on a failed route instead of returning an empty handle a call would crash on; and the cases read the capture after every host ended, so a host's report (exit 97) is always shown. **CI on 5887c5a** (x86_64 MSan 4/4) named the cause: `materialize_route` to the audit host answered TRANSPORT_ERROR in the first W-7 case and W-3, and the hosted consumer's route to it failed the same way; the hosted W-9 case passed. The 8522a1f end was most likely the same, a failed `materialize_route` in the hosted W-9 case followed by a call through the empty handle the old `vaultHandle` returned. A hosted provider's Hello crosses the carrier both ways, since the Runtime judges it: about 1 s under MSan on an idle framework.lan and 0.13 s under orc, where a transported route the Runtime serves takes 14 ms and 2 ms. That runner ran the suites 8 to 20 times slower, past `fastConfig`'s 15 s. A 200 ms deadline on an idle Mac fails the same cases the same way, with `ccHelloTimeout`, and the host side has no wait a missed wakeup could hold, so this is the deadline, not an ordering race. The hosted cases' Hello deadline is now 60 s times `Slow`: no case is about it. The Runtime's answer ends with the I/O thread's reason (the close cause or a system error), so a deadline and a loss differ; a hosted consumer's host reports only the failure's kind. `secretIn` reads only a successful answer (the hosted-consumer case stopped at a ValueError parsing an error's message as hex), and routefixture's `finish` keeps `live` until `close` returned, so `leftover` tries again. Of the other suites with a Module Host, only test_boundary_invariance makes a route to a hosted provider (test_hosted_routes' cases already wait 60 s times `Slow`; C-9's hosted consumer reaches a provider the Runtime serves, whose Hello the Runtime judges in its own process; test_hosted, test_hosted_permissions, test_logosd and test_deployment materialize no route): its Hello deadline, 10 s times `Slow`, is now the same 60 s times `Slow` | 2026-11-15 |
| I93 | IMPL | Tier 4b step 4b-4: permissions, the half the Runtime enforces (CA §3 l.121, l.129, §3.3 l.338-353, l.360-366, §3.5 l.387-422, §5 l.484-486, l.556-569, §8 l.915-916; RUNTIME l.1595, l.1677, §9.3 l.2348-2392, l.2526-2604, l.2637, l.3586, l.3753, §10.1 l.3801-3804; LOADER l.426-428; BCP l.360, l.364; D25, G110, G205, G207, G217, G229, G253, G272, G275, G279–G286; TF-32, TL-04, TF-10, TF-28). Parts 4b-4a (the registry and the Capability Authority), 4b-4b (the Runtime in direct mode), 4b-4c (hosted, after 4b-3) | **4b-4a. The registry and the authority.** `src/logos_core/permissions.nim`: a definition is a value (name; its constraint CDDL, a supporting schema, and root; containment; enforcement point; unenforceable and revoked behaviour; facility classes; whether it claims containment), a profile a value (definitions ascending by name, and its `minimum` settings), reaching each thread as a constructor (`ProfileSource`) whose value and constraint validators each thread builds and releases at its end. Settings checks (names strictly ascending by UTF-8 bytes, then defined and conforming: one deterministic-CBOR item, no trailing bytes, a value of the root). The shipped profile `logos-core-nim.permission-profile.v1` (G279) with `logos-core-nim.host-ambient` (`host_ambient.cddl`: `{}`; equality; Runtime admission; refuse; stop; all seven facility classes; no containment; G110, G283). The Capability Authority takes the profile through `AuthorityConfig.profile` and `AuthorityWiring.profile`: an undefined permission is `unknown-permission`, then constraints that do not conform `invalid-constraints` (G205 amended); a permission scope beside anything but one `start` is `invalid-request`, with and without a profile; one allow rule or one grant must cover every requested scope, and a deny pattern containing any requested scope denies (G207 amended, owner batch D 17); grants and the new policy pattern `lcn.ap_permission` contain permission scopes through the definition (CAP-0021); a policy naming an undefined permission or non-conforming constraints does not load; an active persisted grant naming a permission the selected profile does not define keeps the authority from opening (a terminal one stays as history). `docs/PERMISSIONS.md`, `docs/AUTHORITY-POLICY.md`. CA §3.5 claimed: CAP-0021, CAP-0083 by tests; CAP-0075 to CAP-0082 (G283), CAP-0292, CAP-0293 (not applicable, G283) and CAP-0294 to CAP-0297 (not applicable, G286) by inspection. Suites `cap.permissions` in `test_authority.nim` and `perm.registry` in `test_permissions.nim`. No test hook: tests hand the test profile to the configuration directly. Gate: CAP 382/382 (CAP-0065, CAP-0066 deferred to Tier 4b, CAP-0192 to Tier 5 until 4b-4b). **4b-4b. Direct mode.** `app-config.v1` `permissions` selects the profile (`EngineConfig.permissions`, `AuthorityWiring.profile`) and provisions new instances, by instance, else by module (G110); `create` refuses repeated entries, an entry naming the Module Loader or another module's instance, settings that are unordered, undefined, non-conforming or not enforced, and an orchestration or authority instance without the minimum. `runtime/settings.nim`: the state (revision, permissions, `pending`/`applied`/`failed`), a replacement's status and its settlement (G281, G285), and the `prm` side record (`store.cddl` `lcn.prm_record`), written for every instance before it is first committed and before each reply, deleted at retirement; at open the settings are restored, a `pending` one settled, and a store the selection cannot read refused. The Loader's settings are its construction's minimum, and an update aimed at it NOT_READY (G253). `get_permission_settings` and `update_permission_settings` with a profile: the target's authority, then the checks (INVALID_PARAMS without detail), a stale revision, a repeat, a new revision; a running instance is stopped at once with no classification, intent and origin kept (RUN-0914, RUN-1066); settlement runs from `releaseWaiters`, which `teardownDone`, `cleanupFailed` and the shutdown-grace path now pass through, and a failed settlement write is retried. Admission: `settingsRefusal` before any decision (G284); `AuthzRequest.permissions` carries the saved settings, one permission scope each beside the execution scope (G217 amended); decisions are read and fitted with the profile, an allowed permission scope accepted when the requested one contains it; `Inst.installed` keeps what was allowed, per realization, for `get_execution_permissions` (G282), a renewal that narrows it ends the execution, and a replacement while the decision is pending asks it again. `permission_settings_changed_event` on every committed change, delivered under the target's observation authority. The fake authority's rules can narrow, broaden or drop a permission scope. Docs: `docs/HOST-CONFIG.md` (`permissions`, settings with a profile, `prm`, the Loader, the event, orchestration duties), `docs/PERMISSIONS.md` (settings, admission and the snapshot, the trap, BCP l.360 and l.364). RUN-0914, RUN-1066, RUN-0923 and CAP-0192 claimed; the inspection items of G229's constant form replaced by tests; PKG-0335 moved to Tier 5. Suites `run.permissions` in `test_permissions.nim` and its parity pass `test_permissions_ca.nim`, and cases in `test_host` and `test_host_authority`. Gate: RUN 797/797, CAP 383/383 (CAP-0065, CAP-0066 deferred to Tier 4b). **4b-4c. Hosted instances** (`hosted_dynamic` in a `process`, after 4b-3; plan R24-R30). Already given by 4b-3: the hosted execution scope with `local-transport` and `process` beside the permission scopes (G272), `enforceable` for it (no sandbox or container in 4b), the precheck on every hosted start (`beginAttempt` is reached only after `settingsRefusal`, or for the Loader, which is never hosted), every Module Host end passing `releaseWaiters`, and `get_execution_permissions` from a host, which runs through its attempt's own binding, so `rc`'s caller-bound checks and the realization's snapshot apply as in process. Built here, in `engine.nim` only (nothing new crosses the carrier): `remainsOf` reads the state; a hosted realization whose host the Runtime ends by force (`forcedEnd`: `cleanup-timeout` from the stop deadline or the shutdown grace, or a lost realization after the Loader's loss) remains until that end is confirmed, so its `pending` settings settle `applied`, not `failed`, the instance keeping its classification; a hosted end that schedules no forced end (a cleanup failure, an answer lost while the Loader stays bound) keeps G285's `failed` (G285 amended); a hosted instance restored with its restart lock held keeps `pending` settings until `retryLocks` takes the lock, which then settles and publishes them (G275 amended). The events' order and content are unchanged (4b-5c resumes on them). Suite `test_hosted_permissions` (S-20 to S-27: the request's scopes, the refusals without host-ambient and for `failed` settings, the snapshot from a host, reconciliation, the forced end, the cleanup failure, the restart lock, revocation), POSIX only; it joins `test_hosted` in the flake's aarch64 MSan skip list, which grows by one (I77's sentence on "the four suites that load Nim libraries" is left as written; each row that grows the list says so). CAP-0065 and CAP-0066 claimed. Gate: CAP 385/385 (none deferred). | 2026-11-14 |
| I94 | IMPL | Tier 4b step 4b-5: the reference orchestration module (RUNTIME l.71-72, l.182-194, l.746-751, l.1640-1643, l.1674-1680, l.1832-1833, l.2247, l.2261, l.2553-2560, l.3425-3428, l.3511, l.3537-3544, l.3750-3762, l.3774-3790, l.3801-3808; CONFIG l.52-53, l.132, l.142; decision 8; G53, D24; G287–G292). Parts 4b-5a (module and engine tests), 4b-5b (host tests, documents, claims), 4b-5c (permission resumption, after 4b-4) | **4b-5a. Module.** `lcn_orchestrator`, a consumer-only kit module (`src/logos_core/orchestration/`, façade `orchestration.nim`), linked in and registered by a host as the `direct_static` binding `lcn_orchestrator` (`orchestratorStaticSymbols()`); the host's `orchestration` field gives it the role, its name confers nothing (G53, l.189-192). It calls only through its Runtime Control binding (l.184), with `kit/rcclient.nim` (typed synchronous calls, prepared asynchronous calls, subscriptions; responses copied to shared memory on the completing worker); nothing in it imports the engine, the host or the plumbing. **Configuration.** `lcn_orchestrator.config` (`orchestration/config.cddl`, generated through `nimble regen` like every kit): `authority`, `defaults` (start or stop), `ordering`, `restart` (`disabled` or `backoff`), per-instance `overrides`, `resync_ms`. No exclusion: its own instance and the Module Loader are always left out (G191, G246). Package default backoff 1 s × 2 up to 60 s, 8 attempts, stable after 60 s; resync 30 s; bounds checked by `settingsOf` (an invalid value fails `_MODULE_init` with MODULE_ERROR); startup-only. `orchestratorDeclaration()` gives a host the declaration, with the package default as `default_value`. **Accounting.** `orchestrator-state.cbor` in its state directory (`orchestration/state.cddl`, format `logos-core-nim.orchestrator-state.v1`): one open episode per instance and intent revision (attempts, calls, the last call's wall time, `pending`), written before each charged `recover_module`; a refusal refunds the attempt, an answer that never arrived is charged once and read again (C-9); another Runtime's file is discarded; a broken file or a failed write fails closed (no call is made); revisions are never counted (TL-08, G227). The directory is locked (`<dir>/lock`) while the instance lives; with no state directory it refuses to start unless every policy is `disabled`. **Behaviour.** One worker thread per instance (released per thread at its end). `get_self` first; the authority's bring-up when one is named (`start_module`, then polls, 100 ms doubling to 5 s); the binding inferred from the first `list_modules {limit: 1}` that succeeds (G290); then subscriptions to the module-state, execution-state, inventory and configuration-state events, a full traversal (`list_modules` pages of 256) and the first pass. Events are hints: handlers copy bytes into a 64-slot ring and the worker reads (`get_readiness`) before it decides; a full ring forces a resync. A periodic resync (`resync_ms`) subscribes anew before it unsubscribes the old ids and traverses everything (G225). Decisions (`orchestration/policy.nim`, pure) from lifecycle state, intent and the `cleanup-timeout` classification only (G291, RUN-1055): startup defaults are requests guarded by the revision read with `uninitialized` (K15, a Reading: l.194, l.2247, l.2261, l.1913); `stopped` closes the episode; a live `error` is recovered on the backoff, charged, up to `max_attempts`, then a diagnostic; `ready` for `stable_ms` closes the episode; a dependent waits until every prerequisite is `ready` (G287); probes and resumption per G288 and G289. Lifecycle calls are asynchronous, one per instance, 16 at most (G173). At shutdown the module unsubscribes, cancels and releases what is in flight, and calls nothing (G292). "Operational" is read as after the authority binding (S4b5-2, a Reading: l.1643 against l.3774). Diagnostics through `setOrchestratorDiagnostics`. The engine is unchanged. **Deviations from the plan.** The schemas use `uint32` and `uint64` where the plan wrote `uint` (lcn-gen maps no bare `uint`); the lock file is `<dir>/lock` (`durable.acquire`); `encodeSettings` and `orchestratorDeclaration` return a `Result`; an asynchronous call that cannot be prepared is a refusal (attempt refunded, retried after `initial_delay_ms`); past 4096 open episodes no new one is opened (a diagnostic, retried at the resync); after a dropped answer the restarted module's first read is its traversal. A hint brings the next probe forward and stays in force until that probe is made: a resync or another read before it was due used to spend it (found by `test_orchestration`, fixed in `policy.probeDue` and `noteProbe`, with a policy test). The needs a deployment must grant (P5, `orchestratorNeeds`) list methods, events and the instances whose origin it must act as; their scope names are left to 4b-6 and 4b-4. Nim 2.2.14: a parameter typed `type B` does not bind a generic `B` (upstream draft 145); `rcclient` uses `typedesc[B]`. **Test hooks (D27).** `orchestration/testhooks.nim`, only under `lcnTestHooks`: `dropNextAnswer` (the worker halts with `pending` written, as a crash), `failWrites`, `suppressHints`, `pauseBeforeRequest`, and a record of every call (method, target, monotonic time). **Tests.** `test_orch_policy` (20: backoff, the decision rules, configuration bounds and ordering, the state file, the clock clamp); `test_orchestration` (20, at engine level with the `flaky_module` test kit, whose initialization and cleanup each test steers per instance, and the scripted Capability Authority: the binding is its only way in and it never calls the Loader; startup defaults and the guarded-request race; backoff spacing, `max_attempts`, `disabled`, a stop that drops an armed recovery, a prompt shutdown; a lost answer charged once; an episode continued across an orchestration restart and a failure while it was down resumed once, uncharged; another consumer's instance keeps its origin; ordering; authority refusals of execution, `list_modules` and `start_module`; a refusal while cleanup is pending refunded; resync with every hint lost; a missing configuration's probe brought forward by staging; an enforcement stop past its deadline resumed under `disabled`). **4b-5b. Host level.** `test_orchestration_host` (8 cases through the Host Embedding API, with `store_dir` and `state_root`, the module registered as a host would): a clean restart resumes every `requested` instance once, uncharged; an unclean end (a stored snapshot that still shows instances `ready`, as `test_persist` writes it) resumes the survivors once, uncharged, while an episode open when the Runtime ended continues charged and ends at `max_attempts`; `disabled` is never retried and with no provisioned value the declaration's package default applies (the first recovery a second after the failure, "attempt 1 of 8"); with an external authority the module starts it under the derived rules, then its defaults, naming no other instance before; with `recovery: true` a failed authority is recovered and the instances its loss stopped are resumed by probes, intent and origin kept, uncharged; no state directory under an enabled policy and a corrupt state file fail the start (`LOGOS_ERR_MODULE`), the file left as it was and named; `disabled` with an unclean end resumes every survivor once, the authority included, and retries nothing after; HOST-CONFIG carries `config.cddl` verbatim. Module changes it found: a failed `_MODULE_init` is also a diagnostic ("cannot start: …"), since the Runtime does not disclose the module's text; a state file that cannot be decoded names the remedy (remove it to start with no open episode); a decision's note ("restart attempts exhausted …") is written after the accounting it reports, not before. A fourth, from the 200-run loop: the backoff ran from the write-ahead's moment, so a slow write followed by a fast one brought two `recover_module` calls closer than the delay (35 ms against 40); the in-memory anchor is now the call itself, the file keeping the write-ahead's time for a restart. The host tests retry destroy while a worker is still leaving module code after shutdown (RUN-0761), as `Engine.close` does; the G290 probe case counts from the first probe, which the authority's bring-up may delay, and bounds the count by the time since then, since the module's schedule is not scaled by `Slow`. **Documents.** `docs/HOST-CONFIG.md`: "Orchestration duties" opens with the claim (the engine with the reference module wherever a host names it; another module carries the duties), the new section "The reference orchestration module" (registration, the schema, the fields and bounds, what it decides from, hints and resync, recovery and accounting, resumption, probes, the authority's bring-up and binding, the state file and its remedy, what it never does, diagnostics, what its instance needs, limits), the "Persistent Runtime state" resumption item and "Who starts the authority" rewritten for it, and a row in "Runtime limits"; `docs/CONFORMANCE.md` "What Tier 4b step 4b-5 changes" and the module's test hooks; SPEC-STATUS; README; notes on D24 (its §10.1 citation l.3214 is l.3789), G53, G142, G162, G168, G180, G191, G225 and G227. **Claims.** RUN-0021, RUN-0025, RUN-0684 to RUN-0687, RUN-1063 and RUN-1065 are claimed; RUN-0696 stays `deferred:tier-4b` with a comment naming its authority-half tests; inspection R-m (RUN-1064) and R-q (RUN-0983, RUN-1055) name the module. Gate: RUN 771/771 (67 deferred to Tier 4b); merged with 4b-2a, RUN 780/780 (56). **4b-5c. Permission resumption** (2026-11-14, after 4b-4; RUNTIME l.2590-2604, l.3754-3756, l.3801-3804; G284, G288, G291 as amended). The module subscribes to `permission_settings_changed_event` (P5's events, now five) and takes it as a hint, like the configuration event: a change of an instance's settings brings its next probe forward to `max(last call + initial, now)`, never sooner. With 4b-4's admission, an instance a settings replacement stopped is `unloaded`, intent and origin kept (RUN-0914, RUN-1066); while its settings lack host-ambient each probe is refused NOT_AUTHORISED (`authority-denied`, G284), uncharged and never exhausted; once they settle `applied` with it, the event brings the recovery forward. A startup default the settings refuse leaves intent `requested` (G284), so it is resumed the same way. **G291 amended (owner, 2026-11-14, "Do a, as Fable recommends"):** rule 4g reads a closed set of four `error` classifications as a resumption (`ResumableFailures`, `resumable` in `policy.nim`): `cleanup-timeout`, `permission-enforcement-failed`, `authority-denied`, `authority-evaluation-failed`, so an overrun followed by a refused or denied probe stays a resumption, under `disabled` too. Every other classification, an unrecognized one included, is a live failure (l.3756). A resumption accepted that then fails is an execution failure under the restart policy (l.3804): charged under `backoff`, not retried under `disabled`. Found while building: a test that withdraws a permission right after the engine shows `ready` can race the module's own read, so the start still counts toward the probe spacing; the case waits for that read. CI on 5ddd886 (2026-11-15, x86_64 orc-release) found another race of that kind: a probe is counted when the module sends it, and four cases read the count, then replaced the settings while the last probe could still be in flight. Decided after the replacement, that probe is the resumption itself: the instance came back with no further probe, and `recovers == before + 1` failed (3 against 4; reproduced on a Mac by sending each recovery 300 ms after it is counted). In the same run the refused startup default came back only at its next scheduled probe, 12.85 s after the replacement, as if the settings hint had had no effect; that did not reproduce (with an answer or a hint 300 ms late the hint stays in force), so its cause is open. The four cases now wait until every counted probe is answered (`settled`, from the module's diagnostics) before they act, and the two resumption cases print the module's and the engine's diagnostics if a check fails. CI on b3af640 (2026-11-16, x86_64 orc) showed that cause: the module's own resync. A resync subscribed anew and then ended the old subscriptions. Ending a subscription discards what its queue holds (RUNTIME l.3426 asks only for resubscription and a fresh query), and the traversal after it decides from readings alone. So a settings event the Runtime had queued but not yet delivered was lost, and the probe it would have brought forward waited for its schedule (12.82 s; no subscription-loss diagnostic). It reproduced on a Mac with every event drain starting 150 ms late (resync 200 ms): both resumption cases failed in every run, at 12.8 s. Now [IMPL] a resync ends the generation before the current one and keeps the current one for one more interval. Meanwhile both generations deliver each event, and a hint is idempotent. A rescan that a hint asks for (an inventory event, a full ring) reads everything again without subscribing anew. An event is now lost only if its delivery takes longer than one resync interval. With the same delay, both cases pass; with only the rescan change, they still failed. A new case keeps a settings event queued across a resync by starting each drain half an interval late (`setRcDrainDelayForTests`, a Runtime test hook in `rcevents.nim`). **Tests:** `test_orchestration` suite "resumption when permissions become available" (ten cases: a settings event still queued when the module subscribes anew; a permission withdrawn and given back; a refused startup default resumed; a refused probe is not a failed resumption, an accepted one that fails is charged; under `disabled` it is not retried; `disabled` end to end after an overrun, for failed settings and for a denial; the hint's floor under a burst of settings events; an explicit stop ends the probes; the engine routines that set the three authority and permission kinds, pinned); `test_orch_policy` (the closed set). **Documents.** HOST-CONFIG ("What it decides from", "Events are hints", "Probes", "When permissions become available", the five events), CONFORMANCE, SPEC-STATUS, README, G288, G291, inspection R-q. **Claims.** RUN-0696. Gate: RUN 798/798 (164 deferred), CAP 383/383. | 2026-11-14 |
| I95 | IMPL | Tier 4b step 4b-6: logosd, the logosctl instance and shell, `daemon-config.v1` (BCP §5.1 l.287-291, §5.4 l.355-405; RUNTIME l.36-39, l.1604-1611, l.1626, l.2665, l.3365-3443, l.3540, l.3807-3808, l.3823-3824, l.4033-4035; SECURITY l.524; PACKAGE MANAGER l.395-400; CA l.126, l.1265, l.1290; D13, D27, G53, G76, G78–G89, G110, G115, G137, G140–G143, G146, G149, G192, G249; K19, K20, K23; G293–G304). Parts 4b-6a (configuration, trust, composition, the termination hook, K19), 4b-6b (logosd, the logosctl module and shell, packaging), 4b-6c (the evidence store and export, documents) | **4b-6a. Configuration, trust, composition.** `src/logos_core/daemon/`: `daemon_config.cddl` and `trust.cddl` (codecs generated by `nimble regen` into `daemon_config_types.nim` and `trust_types.nim`, checked current by `test_nimgen`); `session.nim` (the layout, `--session-dir`/`$LOGOSCTL_SESSION_DIR`/`$HOME/.logos-core`, the session lock, owner-only files read without following links, `run/` emptied without following links, `work/` kept); `config.nim` (DAEMON.md §3 checks 1-4: G293, G300); `trustfile.nim` (G299); `evkey.nim` (batch E item 19: the evidence key, its kid the first 16 bytes of BLAKE3-256 of the public key, the binding `keys/evidence-<kid>.cbor` to the Runtime id, checked at start and export; rotation marks the old binding retired, overwrites and removes its secret half); `compose.nim` (G294, G295, check 5 through `parseHostConfig`); `sessioninit.nim` (`logosctl init`'s library part: a UUIDv4 Runtime id from the operating system's CSPRNG, the key, trust revision 1 or 2, the default daemon-config checked as logosd checks it; nothing left behind on a failure, an operator's own empty directory emptied, not removed). `runtime/evidence.nim` gains `generateEvidenceKey`, `evidencePublicKey` and `writeEvidenceKeyFile` (`tools/evidence_keygen.nim` uses them). Host API: `runtimeSetTerminationHook` (G304). The development switch gates allow-all and `test_hooks` (G300). K19 for every host (G298): `RcMethod` gains the four remote methods; `list_remote_listeners`, MODULE_ERROR before, is an empty page. Tests: `test_daemon_config` (new: the schema rules, the checks in order, three compositions through the library's checks, the S1-S5 decision table through the authority's own evaluator, every row of the continuity table, keys, init), `test_host` (the hook), `test_runtime_authority` (K19), `test_routes`, `test_nimgen`. PKG-0418–0424 `deferred:tier-5` (the trust tests tag 0418-0421 as evidence). No binary yet. **4b-6b. logosd, the logosctl module and shell, packaging.** `src/logosd.nim` (G302: the session, its lock, the signal mask and a `sigwait` thread, the wait, exits 0-4) over `daemon/assemble.nim` (start steps 4-10, which `test_ctl_module` calls in-process); `daemon/supervise.nim` (the termination hook's supervisor: on a Loader loss logosd logs, requests shutdown, does not destroy, waits up to 10 s for the Module Hosts' restart locks and exits 4); `daemon/logging.nim` (G146: one stderr line per event; a Module Host inherits logosd's stderr, so a hosted module's lines reach the log unfiltered). The `logosctl` module (G296, D13(a)): `daemon/logosctl.cddl` (consumer-only, generated into `logosctl_types.nim` and `logosctl_kit.nim`), `daemon/ctlmodule.nim` (a `direct_static` instance serving the owner-only socket `run/logosctl.sock` or `ctl.socket_dir`, a worker pool whose busy refusal is written at accept, request keys G297, each command one Runtime Control call through the instance's own binding, no payload or event relayed), `daemon/ctl.cddl` with `ctl_types.nim` and `daemon/ctlwire.nim` (`logos-core-nim.ctl.v1`: length-prefixed deterministic-CBOR `lcn.ctl_message` and `lcn.ctl_reply`). The shell `src/logosctl.nim` (G303: `init`, `status`, `module`, `trust`, `daemon config get|check|set`, `daemon stop [--wait]`; offline writers take the session lock; a busy refusal is retried until the call's deadline) with `daemon/render.nim` (text and JSON with the deployment banner; G89) and `daemon/version.nim`. Packaging: the flake's `packages.logosd` (with `libexec/logos-core/logos-module-host`, the default `module_host`), `packages.logosctl`, both `apps`, and `checks.logosd-smoke`; nimble `bin` outside Windows; `contrib/systemd/logosd.service` and `contrib/launchd/org.logos-core.logosd.plist`; `docs/DAEMON.md`. On Windows both programs are stubs that exit 2. Void rows redone: G80, G83, G85, G88, G89, G146, D13, G141, G249; D27 and G53 built (each section's note). Runtime fix (4b-3's G273 check, found by `test_logosd`): a hosted provider's Loader record is compared with the endpoint path made for its attempt, not with that endpoint still serving, so a shutdown begun while `realize` ran (which stops every served endpoint first, RUNTIME l.3846-3849) is no longer taken for a Module Loader failure and logosd's exit 4; the attempt fails at adoption instead (`test_hosted_routes` P-5b). Tests: `test_ctl_module` (new), `test_logosd` (new: logosd and logosctl as processes, the hosted cases with `tests/kit/chatter_impl.nim`), `test_daemon_config` (DAEMON.md carries the schemas and system rules verbatim), `test_nimgen` (the three generated files), `test_hosted_routes` (P-5b). **4b-6c. The call-evidence store and export, documents.** `daemon/evstore.cddl` (generated into `evstore_types.nim`, checked current by `test_nimgen`) and `daemon/evstore.nim` (G301: the queue, the writer thread, segments, bounds, a torn tail cut at open, gaps for drops; readers `summarize` and `findRecord`); `daemon/evexport.nim` (the export: the current key checked against its binding, the producer check, the complete record with no proofs); `durable.nim` gains append-only files (created exclusively, 0600, the directory flushed; each append flushed to the medium). `runtime/callaudit.nim`: `AuditLog` gains the sink, called after the ring holds a record and outside its lock; Host API `runtimeSetCallRecordSink` (G304's second half) through `EngineConfig.callRecordSink`. logosd opens the store when `call_audit.store` is set, before `start`, and closes it after a successful destroy (written out without being freed otherwise, and before a Loader-loss exit). The shell: `logosctl audit evidence ls|export --seq N [--out FILE]`, offline and read-only. G115, G143, G149 built for logosd; G301 decided. Tests: `test_evidence_store` (new: concurrent offers, reopening and a torn tail, bounds by count and age, overflow gaps, the export), `test_host_authority` (the sink with records a Runtime retained), `test_logosd` (the evidence commands as processes), `test_nimgen`, `test_daemon_config` (DAEMON.md carries `evstore.cddl`); `tests/support/evfixture.nim`. **The spec review of the plan (2026-11-15).** `set_remote_listener` that disables a listener succeeds with the requested record and keeps none (G298 amended, as the owner's U3 says); `logosctl init` makes the Runtime's store and logosd refuses a start without one (G192 amended; RUNTIME l.2630-2632); on a Loader loss logosd keeps the session lock until the process is gone (G302 amended). The notice was already process-directed, and `set_provider_export` already carried no detail. `test_logosd`'s lock probe now uses `flock`, as the lock does (a `lockf` probe never saw it). Tests: `test_runtime_authority` (disabling), `test_daemon_config` (the store `init` makes), `test_logosd` (a lost `state/`). **Amended 2026-11-16 (owner, "Yes, add it now"): logosd logs the Runtime's diagnostics.** 4b-6b logged none of `Engine.diagnostics` (4b-7a found it); the handover said otherwise. **The cursor.** Each diagnostic gets a serial from 1 and a level (`plumbing.Diagnostic`); `rqDiagnostics` takes a cursor and answers the entries after it with the count overwritten since (`Engine.diagnosticsAfter`), and the Host API gains `runtimeDiagnosticsAfter` (in-process, like `auditRecords`; G304's pattern). The ring stays 4096 in memory. **The drain** (`daemon/diagdrain.nim`): logosd logs each as `runtime: <text>` once at start, after bootstrap (`startDaemon`, so a state transfer's line is in the start log), every 1 s on a thread of its own ([IMPL] `DrainPeriodMs`), and once after the Runtime's shutdown, before exit 0, 3 or 4; a failed start drains before it destroys. A wrap between two reads is one `warn` line, "N diagnostics dropped". `warn` for "a call record could not be kept" (`invoke.nim`, RUNTIME l.1770) and for state not persisted, `info` for the rest. No `logosctl diagnostics` command. **The text check** (IF l.395, SEC l.305-306, G278): no diagnostic site carries a payload, a value root, a ticket, a key, record content or a marked method's failure text; G278 already strips marked paths from validation messages. Nothing changed for it. **Text the Runtime did not write** (BCP l.551): a module's or the Loader's reported reason (`fkReportedByModule`, `fkInitializationFailed`, `fkLoader`), and a Module Host transport's `io_publish_failed` and `io_local_failure` text on a served connection, are quoted, cut to 256 bytes at a UTF-8 boundary (`base/logtext.nim`, `ForeignTextLimit`) and attributed: "(text from <instance>)", `logos_module_loader`, or "the transport serving <provider>". Every stored diagnostic, and every line `logging.nim` writes, has its control characters (C0, line breaks included, DEL, C1) replaced by a space, so no text forges a line. **Test hook** (D27, G300): `test_hooks.diagnostics` (`lcn.dc_test_diagnostics`: `text`, `count`) records `count` attributed diagnostics after the start's read (`assemble.diagnoseForTests`). **Docs.** DAEMON.md §3 (the schema, the field) and §12 (attribution, who can read the log, the logging and one-line rules, retention, delivery bounds, BCP l.550-552), CONFORMANCE (the hook). **Tests.** `test_persist` (the cursor: a newline, an escape and a C1 control made spaces, the cap and attribution, a wrap counted, serials; the `warn` level of not persisted), `test_loader_engine` (the Loader's reason attributed), `test_logosd` (the drain: a wrap of 4096 + 5 injected lines with a newline, each logged once as one attributed line, none forged, one dropped line; the Loader-loss line before exit 4; 4b-7a's state-transfer line at start), `test_daemon_config` (the rule, the hook selected). **CI on 1ca4710 (2026-11-16).** `test_logosd`'s Loader loss with a hosted module running failed in three sanitizer jobs: the hook's timer, counted from logosd's start, fired before `module start` of the hosted module had ended (x86_64 asan and msan; on aarch64 asan logosd had already exited 4). [IMPL] `test_hooks.loader_failure_on_file` (G300): the Loader reports its failure once the named file exists, or after `loader_failure_after_ms`, whichever comes first; the case makes the file after `module start` has answered. | 2026-11-15 |
| I96 | IMPL | Tier 4b step 4b-7: state transfer to a replacement instance (RUNTIME §8 l.1446-1454, §9.2 l.2637-2641, §9.3 l.3532, l.3546-3554, l.3563-3588; CONFIG l.251-265; CA l.400, l.733; BCP l.366, l.373, l.394-395, l.404-405; G92, G143, G160, G193, G275; G305–G307). Part 7a: `move`; part 7b: `copy`; part 7c: `logosctl state list` and `state purge` | **7a. `move`.** **Authorization (G306).** `host_config.cddl` gains `? state_transfers: [* lcn.app_state_transfer]` (`{from, to, mode: "move" / "copy", ? max_bytes}`; `mode` required), and `daemon_config.cddl` the same field, which `compose.nim` passes through unchanged. `parseHostConfig` checks what the configuration decides (a store and a state root; `to` listed with its own assignment, `from` not listed, so no chain; each instance once per side; never the Loader, a Runtime-form name or the authority instance; `max_bytes` with `copy` only, 1 to 2^40) and refuses `copy` until 7b; logosd's check 2 refuses a system instance on either side and a source in `orchestration.start`. `host.nim` passes the entries to `bootstrap*`, which gains `transfers`. **Procedure** (engine, inside `rqBootstrap`, after the Loader is established at open): `sweepTransfers` (a committed `move` whose target directory is missing and source present is renamed: "completed the state transfer to …"; neither present: a diagnostic), `reconcile`, `checkTransfers` (every entry before anything changes: INVALID_PARAMS for a target known without this transfer's record or retired, an unknown source or one without an assignment, a source with no directory, a target directory that exists; NOT_READY for a source with a realization or its cleanup (`ownsNothing`, `realization` `absent`), a hosted source whose restart lock file is missing (owner's condition 1) or held (`prevHost`, the message naming the file), and a source another instance's retained `requested` intent names as origin; an entry whose target's record names this source is satisfied and skipped), `reprovision`, then `applyTransfers` per entry: the target's `xfer` side record (`store.cddl`'s `lcn.xfer_record`: from, from_assignment, mode, bytes, files, epoch, at), one accepting write that creates the target (`createInst(retiring)`) and retires a live source (`retireMutation`, undone with the creation when the write fails, the record then deleted), `retireCommitted`, then `statexfer.moveDir` (`rename(2)` and a flush of `state_root`; `MoveFileExW` with write-through on Windows) and the diagnostic "state transfer: a (a-state) to b (b-state), move". **The four conditions** (owner, batch F item 21): 1 in `checkTransfers` (POSIX); 2 in `realizeThroughLoader` (`transferredMissing`: a target with an `xfer` record whose directory is missing fails its attempt, `other`, before the Loader is called, so `realizer.stateDirFor` never recreates it empty); 3 in part 7c's purge; 4 in `store.reapSides` (`retired`: a tombstone's `xfer` record is kept) and `retireCommitted` (which deletes no `xfer` record). **Refactors.** `ownsNothing` (from `retire`), `retireInst` split into `retireMutation`/`undoRetire` (var copies for refc) and `retireCommitted`, `createInst(retiring)`. `durable.syncDir`. **Docs.** HOST-CONFIG.md (the schema, the `state_transfers` field, "State transfer to a replacement instance", limits, the store's files), DAEMON.md (the schema, fields, check 2, §8, §11 "Replacing an instance"). **Tests.** `test_transfer` (new: 16 cases: move, the source's intent, nothing else passes, names transfer nothing, a dependent's intent, an unclean end, refusals, idempotence, a crash after and before the commit, a failed commit write, a retired source, a hosted source with its lock missing or held, a missing target directory, a retired target's record), `test_store` (the record, the reaping exemption), `test_host` (the field's refusals), `test_daemon_config` (check 2, the pass-through), `test_logosd` (a hosted operator module replaced across a daemon restart). **Claims.** RUN-0925 and RUN-0998 claimed; RUN-1000 `deferred:tier-5` (acceptance of the replacement's package). **Validation:** Mac: the touched suites under orc, refc, orc-release, ASan and TSan, the rest under orc, nph, the lints and the gate; framework.lan: the touched suites in the same five variants and MSan, one at a time, `no-test-hooks`, `lint-first-write`, nph, the logosd and logosctl packages and `logosd-smoke`; winvm: the new and changed tests compile, `move` runs. **7b. `copy`.** `parseHostConfig` and the engine accept `copy` (POSIX; on Windows the engine answers MODULE_ERROR "copy is not supported on this platform", nothing changed). `statexfer.nim` gains `measureTree` (`openat`/`fdopendir`/`fstatat(AT_SYMLINK_NOFOLLOW)`: a link at the root followed once, none inside; metadata only), `copyTree` (directories 0700, files `O_CREAT|O_EXCL|O_NOFOLLOW` with their permission bits, each re-checked with `fstat`, data through one 64 KiB buffer zeroed with `wipe.secureZero` on every path before it is freed (F1; erasure claimed for orc, R5), every file and directory flushed with `durable.syncFd`), `removeTree` (no link followed; a directory without the owner's access gets it first), `freeBytes` (`statvfs`), `stagingName` (`+transfer-` and 16 bytes of BLAKE3 of the target's assignment) and `isReserved` (`+transfer-`, `+purge-`; `+` is outside an assignment's alphabet). Check 10 in `checkTransfers`: an entry other than a directory or a regular file is INVALID_PARAMS naming its relative path; more than `max_bytes` (default `DefaultTransferBytes`, 1 GiB), `MaxTransferFiles` (1,000,000) entries or `MaxTransferDepth` (64) levels, or less free space on `state_root`'s file system than the entries' bytes and `FreeSpaceMargin` (64 MiB), is MODULE_ERROR; all measured before anything is written. `applyTransfers` copies into the staging directory (an earlier one removed first) and flushes `state_root` before the `xfer` record (bytes and files copied) and the commit; a failure before the commit removes the staging directory; after it the staging directory is renamed to the target's, with "state transfer: a (a-state) to b (b-state), copy, N bytes in K files". `sweepTransfers` completes a committed copy from its staging directory and then removes every other reserved name in `state_root` (an uncommitted copy's staging, part 7c's interrupted purge), with a diagnostic. **Docs.** HOST-CONFIG.md (`copy`: content, bounds, time, rollback, F1's statement, the refusals, limits), DAEMON.md §11 (F1's statement). **Tests.** `test_transfer` +4 (`copy` and rollback from the retired source, Windows MODULE_ERROR; refusals: a link and a FIFO inside, `max_bytes`, depth, nothing staged; an unreadable file: staging removed, nothing committed, applied once readable; crash completion and the sweep of reserved names), `test_host` and `test_daemon_config` (`copy` accepted and passed through). **Validation (7b):** as for 7a; winvm: `copy` answers MODULE_ERROR. **7c. `logosctl state list` and `state purge` (G143 re-decided).** `runtime/stateadmin.nim` (new): `listState(storeDir, stateRoot)` and `purgeState(storeDir, stateRoot, instance | assignment, configured)`, both opening the store with `openStore` (its lock; a missing store is not created) and never writing the snapshot. The list joins the snapshot's live instances and tombstones, the `xfer` records and the state root's names: holder (`live`, `retired`, `none`, `unfinished` for a reserved name), presence, a link, bytes and files (no link followed), and the provenance both ways. A purge is refused for a live instance, an unknown or assignment-less one, an assignment a live instance or tombstone holds (with `--assignment`), one outside the assignment alphabet, one the daemon configuration names, a symbolic link, and, NOT_READY, while an `xfer` record names it as `from_assignment` and its live target's directory is missing (owner's condition 3); it renames the directory to `+purge-` and 16 random bytes in hex (`moveDir`, flushing the state root), then `removeTree` (no link followed; a directory without the owner's access gets it first); a missing directory is "nothing to purge"; Windows: MODULE_ERROR. `logosctl state list|purge` (`--yes`, else a prompt on a terminal; offline, the session's lock then the store's; `state` in the offline commands). **Docs.** DAEMON.md (§2's lock, §8 "State disposal", §11 "Listing and purging state"), HOST-CONFIG.md (Retention); G306 corrected: the transfer's record is its `xfer` record, not a log line. **Tests.** `test_stateadmin` (new: the list, the locks, a purge and its tombstone, the refusals, condition 3, modes and links inside), `test_logosd` (the list and the purge refusals after the replacement). **Validation (7c):** as for 7a, with `test_stateadmin` among the touched suites; winvm: `test_stateadmin` runs, a purge answers MODULE_ERROR. | 2026-11-16 |
| I97 | IMPL | Tier 4b step 4b-8: claims and the deployment document, closing Tier 4b (BCP §5.1 l.287-290, §5.2 l.310, §5.3 l.344, §5.4 l.355-405, §5.5 l.420; RUNTIME l.1394, §9.3 l.3519-3546, l.3613-3617; PM l.360, l.402, l.1140-1149, §17; G309-G312; owner decisions 1 (a), 10 (a) and 11 (a) as amended 2026-11-16, batch G item 22). Part 4b-8a: labels, tags and inspection outside the deployment document; part 4b-8b: the document and its checks; part 4b-8c: closing the tier | **Rules.** *Met units:* a unit that is met is claimed whether or not the whole it belongs to is (BCP-0021 to BCP-0024 are claimed while no complete system is, G310). *Inspection or out of scope:* a conditional unit whose condition does not hold in any deployment built here is claimed by inspection, with the reason saying why and what would make it hold; a unit that binds only an option this implementation does not take is out of scope. *An alternative not built:* a claimed unit whose text allows several arms names the arm not built in CONFORMANCE. **8a.** G309 (item 22's label rule, before `spectrace deploydoc` exists), G310 (S4b8-1, K18, K50; TF-43's reading), G311 (S4b8-2), G312 (K49). Area 7 to Tier 5 (owner decision 1 (a)): RUN-0995 to RUN-0997, RUN-1023 to RUN-1025, PKG-0060, PKG-0287, PKG-0289 and PKG's `§17` key. RUN-0844 claimed by inspection (`logosd-no-signed-declarations`: no signed package declarations are retained). PKG-0288 claimed by tags (`test_engine` [RUN-0104], `test_hosted_routes` P-2). BCP-0021 to BCP-0024, BCP-0027, BCP-0028, BCP-0036, BCP-0049, BCP-0050, BCP-0061 to BCP-0063 and BCP-0081 claimed: tags [BCP-0028] (`test_transported`: a local-transport rule honoured for a pair in one process; P-4; `test_logosd`'s failed profile), [BCP-0036] [BCP-0049] [BCP-0050] (P-4), [BCP-0049] [BCP-0050] [BCP-0081] (C-08 in `test_realizer`), [BCP-0049] [BCP-0081] (`test_permissions` [CAP-0084]), [BCP-0081] (`test_hosted_permissions`: a sandbox or container placement has no enforcement point), [BCP-0063] (`test_call_surface` [IFC-0245], `test_transport` [TRN-0254], `test_evidence` [CAP-0397]); inspection items `bcp-fixed-profiles` (BCP-0027), `bcp-no-override` (BCP-0028, G312) and `bcp-profile-names` (BCP-0061, BCP-0062). Records audit items 3 (PKG-0069's comment), 4 (RUN-0552's reason) and 5 (the handoff's tier in PKG.toml, RUN.toml, SPEC-STATUS, G55 and CONFORMANCE). The inspection-reason audit re-read and rewrote BCP-0004, BCP-0098 (4b-6d's drain is a log sink), IFC-0215 (a Module Host is ended by force, G269), RUN's R-a (local transport mode is taken) and R-b (a hosted provider's transferred endpoint is a validated handoff), the CAP renewal and evidence-key items, LDR-0042 (the carrier's state directory) and TRN.toml's comment; `grep -rnE 'IMPL-DECISION (S4b[0-9]+-[0-9]+|K[0-9]+|G-)' tests` prints nothing. Gate after 8a: RUN 829/829 (133 Tier 5), PKG 211/211 (309 Tier 5), BCP 26/26 (23 still `deferred:tier-4b`, the §5.4 documentation units). **8b.** `docs/DEPLOYMENT.md`, logosd's §5.4 document (G310): an item table (items 0 to 23 in 35 rows, split where one part is supported and another is not; Verdict and "Changes in" per G309), a table of the other specifications' documentation duties (18 rows from a recorded search of the pinned specs; the Package Manager's own duties, PM l.836, l.859, l.934, l.1191 and l.1705, named in prose and left to Tier 5), 24 sections (the data path as built, R17: `direct_dynamic` in logosd, E3, G257, E2, F1 for `copy`, and the host-program trust of G273 and G274; `process` is not a sandbox, G265; orc builds and refc refusing every marked contract, G277; five deadlines and the forced end of a host; the restart lock and `unknown`; the diagnostics drain; state transfer, `state list`, `state purge` and the operator's backup as `move`'s rollback; SECURITY §13's defaults) and a `json deployment-facts` block. `spectrace deploydoc` encodes G309 (every gated §5.4 unit in an item row; each row's units claimed with evidence; a None or Not supported row's units carry its tier in their inspection reason; every duty row's units claimed and its citation named by an inspection item of BCP-0038; every in-page link resolves; the facts block parses), flake check `spec-deploydoc` (in `orc-spec`); `specSources` and `nimSources` gain the document. `tests/test_deployment.nim` (suite `bcp.deployment`, POSIX; on the aarch64 MSan skip list, I77) compares the facts block with the code: the Loader's capabilities through the harness wired as logosd wires it, and sandbox and container refused `unsupported-strategy` [BCP-0043]; the profile constant, the two route modes and a hosted provider's socket under `run/ep` [BCP-0041]; the permission registry [BCP-0044]; a Module Host's uid and process group [BCP-0045]; owner-only modes (directories 0700, files and sockets 0600, the Loader's artifact copies 0500, which the document's first draft missed) and the state directory kept after `retire_module` of an instance logosctl created, since one the host configuration names is not retirable (RUNTIME l.3581-3582) [BCP-0046] [BCP-0091] [BCP-0092]; the five deadline defaults [BCP-0078]; the evidence store's and the diagnostics' bounds [BCP-0047]; a hosted instance's execution summary with no signer or package [PKG-0422]. Inspection items in `conformance/inspection/BCP.toml`: `bcp-deploy-doc` (BCP-0038, BCP-0039; it names every duty row), seven `bcp-deploy-duty-*` items under BCP-0038 (review item 30: R l.3037, l.3394, l.3775, l.4035; T l.815-816, l.1343-1345; CA l.1320), and one `bcp-deploy-*` item per §5.4 documentation unit (BCP-0040 to BCP-0048, BCP-0074 to BCP-0080, BCP-0082, BCP-0083, BCP-0085, BCP-0091, BCP-0092); `deploy-trust-dependence` (PKG-0422) in `conformance/inspection/PKG.toml`. BCP's default becomes `claimed`; PKG-0422 leaves PKG's overrides (claimed through `§4.1`). HOST-CONFIG's attribute-source statement covers hosted instances (`engine.putFacts` records no selection for any instance). G137 and G299 amended (owner, 2026-11-16: "Start 4b-8, claim 0422"). Gate after 8b: PKG 212/212 (308 Tier 5), BCP 49/49 (4 Tier 5); no unit resolves to `deferred:tier-4b`. **8c. Tier 4b closed.** Every claims file's `deferred:tier-4b` line says the tier is closed and no unit may carry the status; the flake's `spec-gate` adds `--closed-tier 4b`. RUN.toml's header claims the Runtime instance logosd runs (the engine with the reference orchestration module, I94). CONFORMANCE: "What is claimed at the end of Tier 4b" and two non-claims (no complete Logos module system, K18 and decision 10 (a); no OS isolation of hosted modules, SEC l.207-209); SPEC-STATUS: the Tier 4b row closed with the gate's counts, and what Tier 5 takes over; README: the 4b-8 bullet and "Not yet: Tier 5". HOST-CONFIG: the transport aggregates' row (10b is built, I90) and the classifications 4b added. Plan R15: G249 (TF-45), G251 (TF-37), G268 (TF-29), G269 (TF-28), G270 (TF-40), G275 (TF-39), G289 (TF-41), G290 (TF-25) and G291 (TF-41, TF-28) say they are in the comments document and not sent to the spec owner; I90's drain list (G260) was shown to the owner on 2026-11-15, nothing owed. Records audit item 14: I96 is merged (924ab5c and 8522a1f are ancestors of master) and its row stays true. Gate at the close: RUN 829/829, LDR 131/131, CFG 122/122, CAP 385/385, TRN 242/242, IFC 624/624, PKG 212/212, BCP 49/49, SEC 2/2; Tier 5: RUN 133, TRN 58, IFC 172, PKG 308, BCP 4, SEC 1. **The load check after the close (2026-11-17).** The closing check's load run on c1f42f4 (all 473 checks rebuilt at `--max-jobs 24`, 8328 s) failed eight checks, each a test's wait or a test's own failure path; no `src` defect. test_boundary_invariance-asan: a hosted Hello past 10 s times `Slow`, fixed by dd35abe (I92). test_ctl_module-asan: BCP-0086's start did not reach logosctl's init within 20 s times `Slow`, the case connected to a socket that was not there, and the teardown, which only ended a daemon that was up, left the init hold on; the next case's logosctl init was held and every recovery found the first attempt's socket. The teardown now always turns the hooks off, joins a start a case left running and ends a daemon that was only assembled; BCP-0086 waits 60 s times `Slow` and checks nothing more when the start never got there. test_hosted_routes-asan P-2: `stalledStart` gave up (10 s times `Slow`) before the realize reached its stall, and the case's release, which found no call held, was lost, so the realize was held for good. A `releaseStall` with no call held is now kept for the next one (the Loader fault box, test-hook code only, D27); `stalledStart` waits `Answer`, and when the stall never comes it lets the start through and joins it, and P-2, P-5 and P-5b check nothing more. test_hosted_routes-msan P-11 `block closing`: channel 23 had not seen its invocation cancelled when the case opened it, after call 4's answer and 50 ms times `Slow`; the cancel crosses the carrier, behind what the Runtime ordered first since 4f7439f (I91). Channel 23 writes the file `cancelled` once it sees the cancel, and the case waits `Answer` for it before `open`. test_hosted_routes-tsan C-8: channel 22's hold, 60,000 sleeps of 1 ms, ended before call 2's timeout (five times a round trip above 12 s) and the provider answered OK. Channels 22 and 23 now hold for ten minutes of wall time, and C-8's timeout is at most five. test_logosd-refc (four cases) and -asan (one): logosd's socket or the hosted chatter's init line came after `ReadyMs`, 20 s times `Slow`; it only bounds waits for what comes and is now 120 s times `Slow`. `Slow` stays 1 under refc, since it also scales sleeps and command delays in every suite. test_transported-msan: SIGSEGV in the async cancel and timeout case; its second call's 50 ms timeout could pass before the call reached the provider, `takeHeld` returned nil and `settle` read it. As in C-8, the timeout is five times the first call's way to the provider, at least 1 s times `Slow`, the case checks the provider holds the call before it passes, and a nil call is checked, never used. The first load passes on these fixes (the five suites and test_loader_engine in six variants beside 96 CPU burners at `--max-jobs 24`, load average up to 422) found two more. test_ctl_module (refc, ASan): `boot`'s wait for "logosctl: serving" failed, and its `doAssert` left the started daemon outside the case's `Live`; the handoff is process-wide, so that daemon's late logosctl took the next case's socket path. `assembled` and `boot` now give the daemon to the teardown as soon as it exists, and `Patience` is 60 s times `Slow`. test_loader_engine-asan: the startup-deadline case's 1 s times `Slow` passed before the Loader reached the binding check the case is about; an attempt counts only when the call was held, and each further one, up to four, doubles the deadline. Round 2's load passes on 3c6f3c3 (load up to 403): test_ctl_module-asan's RUN-0347 clients were closed by the socket's idle timeout, 2 s times `Slow`, before they wrote their command; the sessions' timeout is now 60 s times `Slow` (at most 600,000 ms), and only the partial-frame case, which sets 300 ms, is about it. The other failure is open, not a test's: once, `shutdown_runtime` through the socket was answered CANCELLED, where DAEMON.md §7 says the command is answered before the instance stops. The Runtime answers before it begins shutdown (RUNTIME l.3695-3700), but the answer had not reached the logosctl worker's call when the instance's destroy set `closing`, and `rcCall` cancels a call still waiting then. CI on 8aac290 (2026-11-17, x86_64 msan): TRN-0381's connect failed with `ccHelloTimeout`, the cause I91 was waiting to see. Behind the eight stalled Hellos the caller had 1 s times `Slow` left of its own Hello deadline, and the loaded runner took longer to read, admit and answer it. The test now gives it four times that, and the stalled Hellos end 1 s times `Slow` after it connects, so the case still shows it waiting behind them; no code changed. The same run's `test_ctl_module` failure (`send: Broken pipe`) is the idle timeout fixed above. Its two Linux Nimble failures were a failed download of the Nim tarball. **Status:** complete 2026-11-16; the load fixes 2026-11-17. | 2026-11-16 |
| I98 | IMPL | Tier 5 step 5-1: the C->CDDL reverse mapper (INTERFACE §3; D30, G139; G317–G322; plan `tier5-plans/step5-1-reverse-mapper.md`; the build record below) | **Built:** 5-1a, the C front end (`iface/clex.nim`, `cliteral.nim`, `cparse.nim`, `cinput.nim`, `creject.nim`); the CDDL emitter (`cddl/emit.nim`); 5-1b, the reconstruction (`iface/rmap.nim`); 5-1c, the command `lcn-gen cddl` (G321). No preprocessor runs: includes resolve by logical name within the supplied set, each document is printed as CDDL and re-accepted through `acceptContractSet`, and the canonical header `H'` is regenerated and compared with the input (G319). **Claims:** 154 units, 143 in INTERFACE §3 and 11 in the Abstract, §1.3, §2 and §2.1 (IFC gate 776/776, 152 more claimed, 20 still deferred: IFC-0010 and the 19 remote-binding units of §5.2); IFC-0887 and IFC-0904 are re-evidenced in both directions. **Evidence:** `tests/test_rmap.nim`: the §3.8 round trips both ways over the spec mirrors, the forward fixtures and 17 system and tool contracts, the §3.9 cases and the 13 §3.9.5 rejections by reason code. A one-off harvest, not kept as a test, round-tripped all 532 document sets that `test_codegen`, `test_iface`, `test_nimgen`, `test_rmap`, `test_calls` and `test_kit` accept: 531 gave identical roots, module and header, and the other is the over-limit header G321 records. **Limit:** the common names hold under G158's interim (TL-01, open). **A leak LeakSanitizer found in `test_rmap-asan`:** under ARC/ORC Nim stores `return <expr>` into `result` without destroying the value `result` already holds (upstream draft 180), so `cparse.$(CType)` leaked the base spelling of each pointer-to-array type it rendered. `$` now appends to `result` and returns bare. | 2026-11-18 |
| R5 | SCOPE (G277; INTERFACE §1.4.1) | The claim scope of marked-payload erasure (IFC-0575) | Owner, 2026-11-15: "Let's do the recommended option for now" (the Fable session's recommendation, 4b-3b plan R25 item 7). IFC-0575 is claimed for orc builds of the Runtime and the Module Host, and for generated code under both memory managers. A refc build of the Runtime or the host never carries a marked payload: `ChannelsMove` is false, G244's refusal stands for every marked contract, and a refc host fails a marked provider's `init` and a marked route's materialization (G277's build condition). "For now": erasure in refc builds, which needs channels that carry no payload copies, stays open and is not planned. CONFORMANCE keeps the non-claim wording the Fable session gave. | 2026-11-15 |
| I99 | IMPL | Tier 5 step 5-2: the `logos.remote.tls-tcp` carrier's library (TRANSPORT §8.4 l.1200-1226, §8.4.1 l.1230-1298; RUNTIME l.1978-1984, l.2669-2706; INTERFACE l.381, l.388-393; CA l.1268; D28, G277; owner decision B1; G323–G328; plan `tier5-plans/step5-2-tls.md`, spike `tier5-plans/step5-2-spike.md`). Parts 5-2b (the connection, the signing seam, credentials), 5-2a (the trust snapshot and enrollment checks, after batch B's B2), 5-2c (pyOpenSSL peers, G128) | **5-2b** (built first: B2 does not gate it). A core-library API under `src/logos_core/transport/tls/`, face `transport/tls.nim`, not exported by `transport.nim`; the TLS processes that run it (facade and listener processes, logosd's signing service, the key holder) are 5-7a's and 5-7b's. `boring.nim` is the only module that imports nim-boringssl, so only the TLS suite and the TLS programs compile BoringSSL (spike §6: about 80 CPU-seconds per cold build); it links I44's `-lstdc++` on Linux and I46's static libc++ on Android, both live again. `params.nim`: the exporter label, `ecdsa_secp256r1_sha256`, the groups (G326), `TlsTcpAddress`, the SNI name check, and `TlsConfig` [IMPL]: handshake deadline 10 s (connect included), 64 handshakes at once per listener and 1024 connections held per listener (more closed at once, unread), 64 KiB of ciphertext taken but not consumed per connection, 16 MiB of ciphertext sealed but not sent per connection (a frame that would pass it while output waits is refused, nothing sealed), the frame limits of TRANSPORT §2.1, 2 s for teardown. `credential.nim`: a P-256 key from BoringSSL's CSPRNG, PKCS#8 in and out (nothing after the key; P-256 only), a self-signed X.509 v3 certificate (random 127-bit serial, one CN, validity and KU/EKU as asked, `ecdsa-with-SHA256`), the DER SPKI an enrollment holds, `signP256`. `signing.nim`: `Signer`, `SignResult`, `checkSignInput` (G323). `engine.nim`: one connection, sans-I/O, between two memory BIOs: `advance` (need input, need a signature, established, failed), the private-key method suspending the handshake until `answerSignature`, the peer's certificates checked inside the handshake by the `PeerCheck` the engine was given (a failure is a `bad_certificate` alert; 5-2a gives the enrollment checks), the RFC 9266 exporter, `close_notify` as a clean end and a transport end without it as a failure. `stream.nim`: the chronos driver (one reader per connection holding back at the bound; one flush routine a reader never waits for, writers waiting their turn; teardown closes the transport first; one acceptor per listening socket), `connect` (the host's addresses in resolver order while TCP connect fails; any TLS failure ends the attempt), `serve`, `TlsStream` (exists only once the handshake and the peer check passed; TRANSPORT §2.1 frames; the channel binding given once and wiped at close), `StreamRegistry.closePeer`. Test hooks (D27, with markers): `testsigner.keySigner` (the key in the process), `newTlsContextForTests` (TLS 1.2 allowed, no certificate), `abortForTests`. On Windows the test builds compile BoringSSL without assembly (`tests/config.nims`): the Windows leg has no nasm (planning, 2026-11-16, departing from I45 for the TLS suite; to revisit at M12 for real Windows deployments). Suite `test_remote_tls` (21 cases; the peer checks are a fixture that pins one SPKI per Runtime id). TRN-0219, TRN-0220, TRN-0228, TRN-0233 and TRN-0376 claimed; the suite also tags TRN-0221, TRN-0222 and TRN-0227 as evidence for 5-2a and 5-7a. **5-2a** (after B2 and B3, decided 2026-11-17). `trust.nim`: the trust snapshot, immutable once built from protected input (anchor identifiers to certificate DER at one anchor-set revision; each Runtime's current tls-tcp record, `active` with its anchor and one or two keys, `revoked`, or `conflicting` holding both records' keys), refusing malformed input, and `isRuntimeId` (lowercase UUIDv4). `x509.nim`: validity, Key Usage, Extended Key Usage, BoringSSL's unprocessed-critical flag and the SPKI of a DER certificate; extensions that do not parse are refused. `verify.nim`: `checkPeer`, G324's nine ordered checks, and the two `PeerCheck`s, `expectRuntime` (client) and `anyEnrolled` (server), with G325's `systemClock` and `TimeFloor`. B3 changes enrollments only at restart, so `closePeer` serves shutdown until something revokes live. A separate commit adds the macOS sanitizer fix to `boring.nim` (the Xcode SDK and libc++ for ASan and TSan; only builds that compile BoringSSL; planning, 2026-11-17). Suite `test_remote_tls`: 35 cases (14 new: the snapshot, the verifier's matrix and order, and enrollment handshakes). TRN-0216, TRN-0221, TRN-0223 to TRN-0226 and TRN-0370 to TRN-0375 claimed (TRN 259/259); TRN-0222 stays deferred until 5-7b, whose facade process passes the invocation's Runtime as the one expected. G327 re-decided by the owner (the library's zeroing as an option, off by default, `BORINGSSL_ZERO_RECORD_BUFFERS`: iftech/boringssl#13 and iftech/nim-boringssl#26; the buffer was never zeroed upstream, c0e15d1d having moved it to plain malloc/free when it introduced zeroing in `OPENSSL_free`). **5-2d** (G327's follow-up, after nim-boringssl 0.0.16). The pin moves to `https://github.com/iftech/nim-boringssl == 0.0.16` (`nimble.lock` from `nimble -y lock` in a clean copy; `nix/nimble-deps.json` from `nix/update-nimble-deps.sh`), which brings upstream BoringSSL `26584e7a`; only `boring.nim` imports it, and the TLS suite passes on it unchanged. `config.nims` turns the option on; `boring.recordBuffersErased`; `stream.carrierErases`, `requireErasure` and `TlsConfig.carriesMarked`; the stream's own plaintext copies erased (G327's entry). `readFrame` now hands over a `TlsFrame` reference and `writeFrame` takes an `openArray` and seals it at once. Test hook `stream.recordErasureMissingForTests` (it can only add the refusal). `test_remote_tls.nims`: `useMalloc` and the audit build (`base/wipeaudit`); three cases in suite `tls.erasure`. | 2026-11-17 |
| I100 | IMPL | Tier 5 step 5-4: the Windows spike and the Windows CI leg (TRANSPORT §8.2.1 l.1148-1172; Tier 5 plan A6, A8; G107, G123, G334, R6). Parts 5-4a (the probes), 5-4b (the leg), 5-4c (blocking) | **5-4a. The probes** (`[IMPL]` tools, never part of `nimble test`). `tools/winprobe/winprobe.c` measures what §8.2.1 makes Windows support depend on: AF_UNIX basics and paths, `SIO_AF_UNIX_GETPEERPID` attribution across listener creator and acceptor, listener transfer by handle list and by `WSADuplicateSocketW` and their hygiene, the held process reference, the access right `connect` needs, OWNER RIGHTS, DACLs and owners, the volume, the reparse-tag and file-id check, ancestors, the G108 carrier without `socketpair`, Job Objects, the logosctl socket's peer, and the build with its `afunix.sys`. It reruns itself under a filtered token when elevated. `tools/winprobe/loopprobe.nim` (with `loopprobe.c`) drives AF_UNIX sockets from chronos 4.4.1's Windows dispatcher four ways, through its exported API only, up to the documented connection limit: no chronos fork is needed (A8). The raw facts per build are committed in `tools/winprobe/facts/`, the machine part of account SIDs and the account name replaced: 10.0.26200.9974 (winvm.lan), and from the leg's trial run 10.0.26100.33674 (`windows-2025`, `afunix.sys` 6.2.26100.32684) and 10.0.20348.5870 (`windows-2022`, 6.2.20348.5866). The decisions they support are G329-G333 (G332's reading of T l.1156 and G333's key decided by the owner, 2026-11-17, items 6 and 7). **5-4b. The leg** (G334, R6): `tools/ci/windows.ps1` and the `windows` job; the ci.yml header names R6's legs, and `workflow_dispatch` gains a `windows_only` input for a trial of the leg alone. Guards: `test_transport_io`'s cases move to `tests/transport_io_body.nim`, included where unix-stream exists, else one skipped case; `test_host_authority` checks the evidence key's 0600 mode on POSIX only ([I85]). README's Windows paragraph: the toolchain and the script, no nasm. Revision notes on D12 (R6), G105, G123 and G125. **Found by the leg's first full run on winvm.lan** (every suite under orc, 161 minutes; the two below failed, the rest passed): (1) `artifact.privateDir` made one directory per process on Windows (`lcn-artifacts-<pid>`), so a second Realizer in the process staged `a1` over the first one's mapped copy, which Windows cannot replace or remove: `test_realizer` failed twice with `realization-failed` "cannot create the staged copy". [IMPL] It now makes a new directory per call, `lcn-artifacts-<pid>-<n>` created exclusively, as `mkdtemp` does on POSIX. (2) `test_orchestration` read the module's state file while the module replaced it, which on Windows can fail to open (two cases); the test's read is retried. **TRN-0352's Windows test** (TRANSPORT l.1152; Fable's conditions on the plan): `tests/test_windows_profile.nim`, suite `trn.windows`, Windows only (elsewhere one skipped case): the Loader is wired without a hosted placement (no Module Host supervisor exists on Windows) and advertises the direct strategies only; with a Module Host program configured in code, a `hosted_dynamic` request in each placement is refused `loader-unsupported-strategy`, the Loader's journal holds only `hosted_dynamic` realize requests for it (never a direct one), the marker library's load-time code never runs and no copy is staged; `checkEndpointBase` and `makeEndpointDir` fail `eeUnsupported` and leave the base empty, and a local-transport rule fails `openEngine` with INVALID_PARAMS. Tagged [TRN-0352]; the unit stays `deferred:tier-5` until 5-4c makes the leg block. **Status:** 5-4a and 5-4b built; a trial of the leg on GitHub waits for the owner's go-ahead; 5-4c after a green run on master: the job's `continue-on-error` goes and TRN-0352 is claimed, its reason saying the evidence runs on the Windows leg only. | 2026-11-16 |
| I101 | IMPL | Tier 5 step N-1: the module kit's gaps on the node track (INTERFACE §2.4, §2.6-§2.9; TIER5-PLAN N-1, §7 A7; plan `tier5-plans/stepN-1-kit.md`; G340-G342). Part N-1.1: pairing and toolchain | **N-1.1.** `run.mixed` in `test_hosted_routes`: modules built with the other memory manager in the Runtime and the Module Host (G342; passes on the Mac in orc, refc, orc-release, ASan and TSan). `lcn-gen kit` writes the library's export lists, and the test libraries link with them (G341). Kit libraries and `liblogos_runtime` are built with `-d:noSignalHandler`, and `liblogos_runtime` restores the SIGPIPE disposition chronos changes (G340). The Nim 2.2.4 probe and the libraries' switch sets (G341). Linux, sub-parts 2-6 and the kit's nimble package wait for framework.lan and the repository split plan. | 2026-11-16 |
| I102 | IMPL | Tier 5 step N-2: the CLI module `lcn_call` and its launcher (plan `tier5-plans/stepN-2-cli.md`; G343–G350). Parts N-2a to N-2d | **N-2a.** `src/logos_core/cli/`: the launcher protocol (`cli.cddl`, `wire.nim`), descriptor passing (`fdpass`), argument parsing (`args.nim`), output (`present.nim`), the contract, settings and kit (`lcn_call.cddl`, `settings.cddl`); `tests/test_cli.nim`. Nothing user-visible yet. **Held.** N-2b (the module, the launcher, `call`, `describe`, `module wait`), N-2c (streams) and N-2d (marked payloads, local targets only; owner, 2026-11-17) wait for the repository split plan. | 2026-11-16 |
| I103 | IMPL | Tier 5 step 5-0: records (TIER5-PLAN §5 row 5-0 and §8; `tier5-plans/evidence/A-remaining-work.md` §6; plan `tier5-plans/step5-0-records.md`; G351-G356) | **Records only:** no file under `src/` or `tests/` changes, and no unit changes status (gate unchanged: Tier 5 RUN 133, TRN 58, IFC 172, PKG 308, BCP 4, SEC 1). **DECISIONS.** D29 (no Rust output; A4 (a)), D30 and G139 (decided, not built; 5-1 builds and claims them, I98; G139's Specs line at `6a4dfa28`: IF l.22-31, §3.8 l.2610-2634, BCP l.442, l.482), G5, G49, G93 (OPEN until `6a4dfa28`), I44 (`crypto/ed25519.nim` left with I68), I77 (the aarch64 `-msan` skip list is `flake.nix`'s). "Open items": the TF items of the comments document from TF-37 on, with their rows, and "not sent" kept apart from "in the comments document"; status lines of G237 (TF-28), G273 (TF-50), G274 (TF-51), G281 (TF-46), G289 (TF-41), G305 and G306 (TF-42), and TF ids on G246, G247, G250, G252, G253, G257, G260, G282. The owner's Tier 5 batch B of 2026-11-16/17 where rows exist: G81 (B5), G86 (B2), G87 (B3), G298 (B8); G91 and G136 (no readiness signal yet; 5-3a). New: G351 (TF-44, open: D2, a D9 stop for 5-8), G352 (K22), G353 (K30, settled by PM l.1442), G354 (a call record that cannot be kept, as built), G355 (NL-07, B6), G356 (NR-04, B7). K18, S4b8-1 and S4b8-2 were already G310 and G311 (I97). **SPEC-STATUS.** The Tier 5 row rewritten to the Tier 5 plan, with a section of its own: areas, units by area and by step (the PKG recount by work: A1 78, A2 13, A3 63, A4 30, B 19 with RUN 7, C 75, D 30; sum 308), the open items with their interims and decisions, the inspection items that hold only while a feature is absent, and a log the steps add to; C-09 declined, not resolved; NL-07 and NR-04 interims. **Other documents.** README's Tier 5 bullet; `docs/DAEMON.md` §7 (provider calls from the command line are `lcn_call`'s, A3); sandbox, container and operating-system enforcement are outside Tier 5 (D16; plan §3, area K) in CONFORMANCE, DEPLOYMENT (rows 6b and 8b, `Changes in` `—`), PERMISSIONS and the BCP-0043 and BCP-0045 inspection reasons; PKG-0435's reason; tracking comments on CAP-0075 to CAP-0082, CAP-0292 to CAP-0297 and RUN-0488. **Left to other steps:** R1 and `ci.yml`'s header (A §6 item 11) and G105, G125 (item 15) to 5-4 (R6); D30 and G139's "implemented and claimed (I98)" to 5-1c; PKG-0275 to 5-5 (C10). | 2026-11-17 |
| R6 | SCOPE (revises R1; Tier 5 plan A6) | CI legs from Tier 5 | Linux x86_64, Linux aarch64 and macOS arm64 in the `nix` and `nimble` jobs; Windows x86_64 in the `windows` job, on the Nimble path with its own toolchain, the library suites under orc, blocking once a run on master is green (G123 as revised, G334). Android and iOS join with M12, with G105 and G125. Owner's approval of the Tier 5 plan, batch A (A6), 2026-11-16. | 2026-11-16 |
