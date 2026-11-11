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
| G165 | An oversized Event from the void `logos_publish_fn`: close the subscriber's connection (TRANSPORT §2.1) or drop it (RUNTIME §7.3) (a TF-06 note, which reads it as close) | the Tier 4 publish adapter only; Tier 3 returns a typed error |
| G166 | Key rotation: no operation moves an installed package to the new key, so it must be removed and reinstalled or re-released (TF-07) | installation and Runtime handoff (Tier 5) |
| G167 | How an installed package reused as a dependency brings its recorded edges into a new closure; decided (a), fixed exact pins (the Fable 5.2 opinion agrees and names a fourth reading, (d), with other counters); reported as TF-12 in `claude-spec-comments-3.md`, logos-lips `457527eb` | nothing: the resolver follows (a) (I69) |
| G168 | Whether an instance denied execution after `start_module` was accepted stays `unloaded` or enters `error`, and what `start_module` returns; not yet reported | the Capability Authority integration; interim: NOT_AUTHORISED, `unloaded` with `failure = authority-denied` |
| G116 | Who provides the live-acceptance host and the persistent testnet seeder | the live testnet run |
| G151, G153, G156 | Gaps found while building Tiers 1–3, sent as ND-10, ND-12 and NP-15; not answered in 6a4dfa28, restated in `claude-spec-comments-2.md` | nothing yet: each has an interim choice in one named proc with a test |
| Review 2026-11-11 | Rows the 6a4dfa28 text contradicts and that need an owner decision: G92 and G143, with G55 (A6, A7); G99 (A9); G100 (A10); G137, D27 and the section 13 dev-key bullet (A12); D18 and D27, the published dev key (A13); G86 (A14); G82 (A15); G110 with G82 (A16); G47 and G140 (A17); G61 (A18); I52 (A21); G117, lowercase half (B1) | G92, G143: `module upgrade` and the state layout (Tier 4b); G99, G100: payload methods that take paths or run long; A12, A13: development trust in release binaries and the dev signing key (Tier 4b, PM); G86: remote TLS (Tier 5); G82: `logosctl authz check` (Tier 4b); G110: every payload start (Tier 4); G47, G140: the default CA policy (CA integration); G61: Runtime deadlines and call timeouts (Tier 4); I52: the Tier 4 carrier; G117: I6's lowercase units |

IDs in parentheses are where each item was reported: `claude-spec-comments-3.md` at logos-lips `68628d95`
(branch `draft/logos-core-module-specs-discussion`), except TF-12 (G167), added at `457527eb`. That report
names no DECISIONS IDs. Review items (A3, B1, …) are those of the 2026-11-11 review of this file against
the 6a4dfa28 text.

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
| Re-decided 2026-11-11 | G52, G53, G55 (for the first Tier 4 slice) |
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
15. Revisions and implementation choices since work started (R1–R4, I1–I73)

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

### D15 — Where authority policy lives
- **Kind:** FREE · **Specs:** RUNTIME §9 l.1490-1521 (default-deny policy mandatory; internal policy
  allowed "for local trusted deployments"), CA §1, §12; BCP §5.3 (call evidence mandatory for every
  Runtime).
- **Options offered:** (a) internal policy emitting CA-shaped records, CA module later *(recommended)*;
  (b) `logos_capability_authority` module from the start; (c) internal only.
- **Decision:** (b) in the node daemon. The CLI's embedded Runtime uses internal policy (G78).
- **Revised 2026-11-11 (review against 6a4dfa28, item C1):** the last sentence has no subject any more. D13's re-decision (a) dropped the CLI's embedded Runtime: there is one Runtime, the daemon's, and logosctl is a module instance in it under the daemon's Capability Authority. G78 goes with the section 10 redo.

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

### D25 — Module permissions
- **Kind:** FREE (with a CA §3.5 reading) · **Specs:** CA §3.5 ("a profile that permits operating-system
  or platform access MUST define permission names and constraints for every facility it exposes");
  BCP §5.4; RUNTIME l.2240 (omitted permissions are denied).
- **Options offered:** (a) one coarse ambient permission *(recommended)*; (b) zero permissions; (c)
  fine-grained net/fs permissions failing closed where unenforceable.
- **Decision:** (a). Identifier and constraints: G110.

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

### D30 — C->CDDL reverse mapper
- See **G139**. **Decision:** implemented and claimed.

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
- **Kind:** CONTRA · **Specs:** INTERFACE Abstract l.22-30 (the mapping is total; a conforming
  implementation MUST recover the same model from either representation), §3, §3.8 l.1876-1891, §3.9
  (normative cases, 13 named rejection cases) vs BCP §6.1 l.372 ("Code generation is an implementation
  technique rather than a conformance requirement"), l.412.
- **Options offered:** (a) implement it, every spec piece tested, raise the contradiction
  *(recommended)*; (b) defer and mark unclaimed; (c) ask the spec author first.
- **Decision:** (a) implemented and claimed (D30).
- **Revised 2026-11-10 (6a4dfa28):** C-03: an implementation of the bidirectional mapping supports both directions; a module need not implement authoring tools (INTERFACE abstract l.23-24). (a) stands: the reverse mapper is mandatory because lcn-gen claims mapping conformance.

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

### G22 — Calls on a dead route handle
- **Kind:** GAP (settled by RUNTIME l.1341-1350 at 6a4dfa28) · **Specs:** RUNTIME §4.1 (calls on closed, failed, revoked or expired handles MUST
  fail), INTERFACE §5.2; TRANSPORT §3.2 (connection close gives TRANSPORT_ERROR).
- **Options offered:** (a) closed/failed NOT_READY, revoked/expired NOT_AUTHORISED, checked at the
  Runtime boundary so every mode agrees *(recommended)*; (b) all NOT_AUTHORISED; (c) all TRANSPORT_ERROR.
- **Decision:** (a).
- **Settled 2026-11-11 (review against 6a4dfa28, items B3, A20):** RUNTIME l.1343-1347 classify a new operation through the handle by cause, not by the route-state label (l.1345): `NOT_AUTHORISED` when route authority was withdrawn, has expired or cannot be established; otherwise explicit closure or lost readiness is `NOT_READY`; `NOT_AUTHORISED` wins when both are known (l.1347); a transport failure that prevents a result stays `TRANSPORT_ERROR` (l.1350). (a)'s shape stands with that refinement. TRANSPORT l.996 adds that a known authorization failure governs later new local operations. The rule applies at the boundary that decides whether to admit a new operation (l.1349), so the Tier 4 route handle classifies and must keep the close cause (l.1346). I54's `NOT_READY` for every closed `CallerConn` is the Tier 3 default, which the handle overrides when the cause is a known authorization failure, such as a received ProtocolError `NOT_AUTHORISED` after termination (TRANSPORT l.991).

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

### G108 — Private channel between the daemon and a module host
- **Kind:** FREE · **Specs:** LOADER §5.4 l.330 ("Channel setup and descriptor transfer are determined by
  the implementation"); RUNTIME §4.2.1 l.880-888 (the hosted module's RC binding travels over a
  realization-internal protected carrier; the consumer comes from protected launch state).
- **Options offered:** (a) one inherited socketpair per host (an AF_UNIX pair / duplicated socket on
  Windows) carrying RC in Transport-envelope form and Loader control in a separate CBOR framing; no
  ticket; never in public records *(recommended)*; (b) a second per-instance unix socket with its own
  ticket. **Decision:** (a).
- **Note:** asked as a GAP; re-labelled FREE at the final review because LOADER §5.4 delegates it.

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
- **Decision:** open (6a4dfa28), for the owner. Tier 3 builds only the typed `PublishError(peTooLarge)`;
  the Tier 4 `logos_publish_fn` adapter is the only code that depends on the answer, so nothing is
  blocked now.
- **Reported:** as a note in the editorial item TF-06 of `claude-spec-comments-3.md` (logos-lips `68628d95`), not
  as a contradiction: it reads RUNTIME l.1225-1227 as covering events that fail validation and TRANSPORT
  l.388-389 as governing size, which is option (a), and asks RUNTIME to say that its drop covers
  validation failures only.

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

### G56 — Module hosts orphaned by a failed Loader
- **Kind:** GAP · **Specs:** LOADER §7 (realization ids are scoped to the issuing provider; no adoption
  rule); RUNTIME §10.1 (a module failure does not terminate the Runtime), §10.2 step 5 (forced cleanup by
  the Runtime host or deployment mechanism).
- **Options offered:** (a) the daemon kills the orphaned hosts, their instances become `error`, the
  orchestrator recovers them through the new Loader *(recommended)*; (b) ask the spec author.
- **Decision:** (a).
- **Settled 2026-11-11 (review against 6a4dfa28, item B12):** RUNTIME l.3820-3825: Loader loss is not a release; when the owning Loader has failed and control cannot be kept, Runtime marks the instances `error`, fails their routes, preserves intent and arranges termination through protected supervision (l.3823), and rebinding transfers nothing (l.3825; LOADER l.476-477). Settled as (a) chose, with two conditions: no replacement is realized until the deployment mechanism confirms that the old execution envelope and its state access have ended (l.3821-3822, l.3824); and temporary unavailability of the Loader is not failure, so it does not change healthy instances' state (l.3816-3818, l.3827). The remark on RT-05 in `claude-spec-comments.md` (logos-lips `68628d95`) asks what tells the two cases apart.

### G57 — How the bootstrap Loader reports its own realization
- **Kind:** spec-resolved · **Specs:** RUNTIME l.3060-3061 ("Other realization mechanisms MUST use
  implementation-specific").
- **Options offered:** (a) `implementation-specific` *(recommended)*; (b) `direct_static`.
- **Decision:** (a).
- **Settled 2026-11-11 (review against 6a4dfa28, item B12):** RUNTIME l.3527-3528: the implementation record reports the Loader strategy and hosted placement, and "Other realization mechanisms MUST use `implementation-specific`". Settled as (a) chose.

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

---

### G159 — Credential Store references without a definition
- **Kind:** GAP · **Specs:** BCP l.23, l.52, l.199-209, l.276, l.282-285; SECURITY l.528-529.
- **Description:** BCP and SECURITY refer to an optional Credential Store that no spec defines.
- **Interim:** none needed: it is optional and we build none. **Status:** OPEN, found 2026-11-10; reported
  as TL-02 in `claude-spec-comments-3.md` (logos-lips `68628d95`): publish it or drop the references.

### G160 — Static registration across a host binary upgrade
- **Kind:** GAP · **Specs:** RUNTIME l.1395 (retained declarations bound to the linked implementation
  through protected registration), l.3637 (start uses the retained declaration, never a replacement).
- **Description:** relinking a host that statically links a module (D14) replaces the implementation;
  the spec does not say whether the instance survives.
- **Interim:** keep the instance only when the declaration facts are byte-identical; otherwise allocate a
  fresh instance (l.2629-2635 allows a fresh address when continuity is lost).
- **Status:** OPEN (Tier 4); reported as TF-08 in `claude-spec-comments-3.md` (logos-lips `68628d95`).

### G161 — The scope of "observation authority"
- **Kind:** GAP · **Specs:** RUNTIME l.3665 (a request omitting both selectors needs observation
  authority over the complete selection scope).
- **Description:** no RC scope or action is named for it.
- **Interim:** evaluate the requested method's RC scope with `modules: [name]` and no instances or
  providers.
- **Status:** OPEN (Tier 4); reported as TF-09 in `claude-spec-comments-3.md` (logos-lips `68628d95`), which adds the
  term's other uses (RUNTIME l.3157, l.3498, l.3594, l.1725; CA l.180-190, l.301-308).

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
- **Status:** OPEN (Tier 4, Capability Authority integration; the first slice's allow-all authorizer never
  denies execution); found 2026-11-11 while designing the first Tier 4 slice, not yet reported.

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

### G49 — Meaning of `publish_events` / `publish-event`
- **Kind:** GAP · **Specs:** CA §3.1 (`route_access.publish_events`, provider-access action
  `publish-event`); TRANSPORT §1.4 (only the callee sends Events; there is no consumer-to-provider event
  path).
- **Options offered:** (a) accept and commit them in grants, never enforce, ask the author
  *(recommended)*; (b) reject any grant or scope containing them.
- **Decision:** (a). **Status:** OPEN — the owner is asking the spec author.
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

### G115 — Exporting call evidence
- **Kind:** GAP · **Specs:** CA §9.1 l.988-990 (no query method or batch format; export only when policy
  requires), l.1072 (disclosure follows `query_audit` rules), l.1078 (the Runtime keeps containers).
- **Options offered:** (a) containers stay in the daemon's audit store; `logosctl audit evidence export`
  is an owner-only host action, documented; evidence and retain-root off by default, enabled by audit
  policy *(recommended)*; (b) nothing exported. **Decision:** (a).
- **Settled 2026-11-10 (6a4dfa28):** CA-07: no new method; export goes through a protected integration (CA l.1320-1325). Matches (a).

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

### G149 — Call-evidence signing key
- **Kind:** FREE (the need is spec-forced) · **Specs:** CA §9.1 l.986 (every conforming Runtime MUST
  implement `logos.call-evidence.cose-sign1-ed25519`), l.1029-1033 (each kid maps to exactly one producer
  Runtime; the key MUST NOT be used for package signing or TLS); SECURITY §13.
- **Not offered as a question** (found at the final review; the shape follows from the spec):
  `logosctl init` generates a separate 0600 Ed25519 evidence key and kid mapped to logosd's runtime id;
  `trust evidence-keys ls|rotate`, applied at the next start.
- **Revised 2026-11-10 (6a4dfa28):** PM-06: the call-evidence key is SLH-DSA-SHA2-192s (CA §9.1 l.1217-1287, l.1265-1273). The implementation is R4.

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

(G19 and G21 cover configuration error codes; G76 covers the host configuration formats.)

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
- **Status:** OPEN. Blocks the PM fetch mapping, the catalog locator shape, storage CID typing and every
  install; tests run against a fake Storage provider meanwhile (`provisional-G5`).
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

### G93 — How a module reaches its non-binary artifacts and native libraries
- **Kind:** GAP · **Specs:** PM §10, §12 (the handoff carries only the implementation artifact); LOADER §3,
  §5; INTERFACE §2.6 (init input has only state_dir and configuration).
- **Options offered:** (a) self-contained module binaries, raised upstream *(recommended)*; (b) declared
  resource artifacts passed through a deployment-specific channel; (c) ask the spec author.
- **Decision:** (c). **Status:** OPEN. Our payload modules are built self-contained meanwhile, which needs
  no answer.
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

### G78 — Authority inside the CLI's embedded Runtime
- **Kind:** FREE · **Specs:** RUNTIME §9 l.1490-1493 (internal policy allowed for local trusted
  deployments).
- **Options offered:** (a) internal protected policy; the CA module runs in the daemon only
  *(recommended)*; (b) the CA module in the CLI Runtime too. **Decision:** (a).
- **Revised 2026-11-11 (review against 6a4dfa28, item C2):** void since D13 was re-decided to (a): there
  is no CLI Runtime to hold internal policy. The persistent `logosctl` instance is an ordinary local
  consumer of the daemon's Runtime, authorized like any other (D15, G82). To be redone with Tier 4b.

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

### G87 — When trust and enrollment changes apply
- **Kind:** FREE · **Specs:** RUNTIME §9.3 l.2333-2371 (revisions, revocation), TRANSPORT l.1061 (a
  revoked or conflicting enrollment closes connections).
- **Options offered:** (a) at the next daemon start; live-revocation rows claimed through the restart path
  *(recommended)*; (b) live. **Decision:** (a); `trust rotate` bumps the revision on the daemon and on
  every CLI slot.
- **Revised 2026-11-11 (review against 6a4dfa28, item C2):** "every CLI slot" is void with G80's pool.
  Trust and enrollment revisions now concern only real remote Runtimes, whose listeners are off by default
  (RUNTIME l.2830-2831). To be redone with Tier 4b.

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

### G89 — CLI output and exit codes
- **Kind:** FREE · **Specs:** none.
- **Options offered:** (a) JSON when stdout is not a TTY or with `--json` (`{status, module, method,
  result}`; bstr as lowercase hex; integers above 2^53 as decimal strings); exit 0 ok, 1 usage/host,
  2 daemon unreachable, 3 PM/CA domain-error arm, 4 `LOGOS_ERR_*` *(recommended)*; (b) always JSON.
- **Decision:** (a); exit 3 widened at the final review to any contract domain-error arm.

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

### G145 — Release form
- **Kind:** FREE · **Options offered:** (a) relocatable archives per platform (tar.gz, notarized zip, zip)
  with `$ORIGIN`/`@loader_path` rpaths, a gate against leaked `/nix/store` paths, and an install test on a
  plain Ubuntu image; published as GitHub release assets *(recommended)*; (b) Nix-only installation.
- **Decision:** (a).

### G146 — Service management
- **Kind:** FREE · **Options offered:** (a) ship a systemd unit and a launchd plist; `logosd` gets a
  Windows service mode; module-host stderr forwarded into logosd's log; a systemd VM test
  *(recommended)*; (b) the same, but Windows via a wrapper such as NSSM. **Decision:** (a).

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

### G106 — Several Nim runtimes in one mobile app
- **Kind:** FREE · **Specs:** RUNTIME §2.3; SECURITY §11.4, §11.5 ("statically linked or bundled").
- **Options offered:** (a) each module bundled as its own `.so` / embedded `.framework`, registered as
  direct_static, with an early spike *(recommended)*; (b) prelinked static archives with localized
  symbols. **Decision:** (a).

### G125 — Remote transport on Android/iOS
- **Kind:** FREE · **Specs:** BCP §5.3.
- **Options offered:** (a) not claimed in v1; BoringSSL/lsquic compiled out on mobile *(recommended)*;
  (b) claimed on mobile too. **Decision:** (b).

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
- **Decision:** (c). **Status:** OPEN.

---

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
| G165 | oversized Event from the void publish callback | CONTRA, **OPEN** | 5 |
| G166 | key rotation and installed packages | GAP, **OPEN** | 9 |
| G167 | recorded edges of a reused installed package | GAP (decided; reported as TF-12) | 9 |
| G168 | execution-authorization denial after `start_module` | GAP, **OPEN** | 6 |

---

## 15. Revisions and implementation choices since work started

Work started on 2026-11-09 while the spec owner revises the specs after our issue reports. The order
of work follows the tiers in `docs/SPEC-STATUS.md`: most settled areas first.

| ID | Kind | Entry | Decision | Date |
|---|---|---|---|---|
| R1 | SCOPE (revises D12) | CI breadth while only Tiers 1–3 exist | Linux x86_64, Linux aarch64 and macOS arm64. Windows, Android and iOS legs join before Tier 4 work. Owner's answer. | 2026-11-09 |
| R2 | SCOPE (revises D31) | How Nim dependencies are declared | `logos_core.nimble` + `nimble.lock` are the only place versions are decided, and the project builds with plain `nimble`. Nix builds from the same lock: `nix/nimble-deps.json` adds a content hash per locked package (generated by `nix run .#update-nimble-deps`; Nimble's sha1 cannot verify a Nix fixed-output fetch) and each dependency is a `fetchgit` fixed-output derivation the binary cache can serve. Evaluation fails when the JSON and the lock disagree. Rejected: nim2nix and mkNimbleApp (one opaque whole-tree hash, patched nimble), nixpkgs `buildNimPackage` (a second lock that decides versions), eval-time `builtins.fetchGit` (not cacheable). Owner's request. | 2026-11-09 |
| R3 | SCOPE | Workspace layout | `logos-new-workspace/` is a plain folder; `logos-core-nim/` is its own git repository; module repos and forks are added next to it. Owner's answer. | 2026-11-09 |
| I1 | IMPL | BLAKE3 | Vendor the official BLAKE3 C sources 1.8.7 (commit `f3149ec5`) under `src/logos_core/crypto/blake3/` with our own binding, refreshed by `tools/update-blake3.sh`. nim-blake3-c cannot be used as a Nimble dependency: its `installFiles` list `src/…` paths while `srcDir = "src"`, so Nimble installs only the `.nimble` file. G134's "BLAKE3 C from a pinned input" is kept in spirit: the sources are pinned by commit. | 2026-11-09 |
| I2 | IMPL | Formatter | nph 0.7.0 from a second nixpkgs input (`f4a03c00`, nixos-unstable, cached). nixpkgs release-25.11 ships 0.6.1, which formats differently, and the 0.7.0 release binaries for arm64 are x86_64 builds. | 2026-11-09 |
| I3 | IMPL | nixpkgs pin | release-25.11 at `cd648d6e`, the commit logos-storage-nim uses, with its Nim overlay pattern updated to Nim 2.2.14 (2.2.10 has the refc heap bug Nim#25992). | 2026-11-09 |
| I4 | IMPL | Spec mirrors | `spec/mirrors.toml` names each mirrored block by spec file, section key, fence language and ordinal, so line shifts elsewhere in a spec do not matter. `spectrace mirror` fails on any difference from the pinned spec. | 2026-11-09 |
| I5 | IMPL | Pinned values | `spec/pins.toml` holds every pinned identifier, root, digest and vector length with the section it comes from, as plain `[name]` tables that both Python's tomllib and Nim's std/parsecfg read. `spectrace pins` checks each value still appears in its section; tests recompute roots and digests and compare. | 2026-11-09 |
| I6 | IMPL | Requirement units (G117, G118) | `spectrace` units: sentences, list items and table rows with an uppercase BCP 14 keyword (`kw`), with a lowercase must/shall/should (`lc`), one unit per CDDL rule, one per other fenced block, one per heading. A list item without a keyword inherits its keyword lead-in sentence. Abstracts count as normative: in LOADER, PM, CA, RUNTIME and INTERFACE they carry MUST text. Only References and Copyright are informative. IDs are kept across spec revisions by exact fingerprint, then by same-section similarity ≥ 0.8 (CDDL: same rule name); retired IDs are never reused. | 2026-11-09 |
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
| I44 | IMPL | Linking C++ dependencies | nixpkgs' Nim configuration sets `gcc.linkerexe = $CC` (and `clang.linkerexe`), so Nim's switch to the C++ driver for mixed C/C++ builds never happens under Nix, and on Linux BoringSSL's C++ objects lose libstdc++. `crypto/ed25519.nim`, the one module that imports BoringSSL, passes `-lstdc++` on Linux; outside Nix the C++ driver links and the flag is redundant. On macOS the same configuration links without it (the darwin checks pass), so the flag is Linux-only. A future C++ dependency needs the same. Dormant since I68: nothing links BoringSSL until TLS and QUIC (D28) do. | 2026-11-10 |
| I45 | IMPL | Windows builds (G126) | The Nimble path builds and tests natively on Windows x86_64 with MinGW-w64 gcc and nasm on `PATH`. nim-boringssl assembles its Windows x86_64 sources with nasm while compiling; Windows keeps that assembly rather than BoringSSL's portable C (`-d:BORINGSSL_USE_ASM=false`), so all three desktop platforms test the same code and the TLS/QUIC modules get AES-GCM assembly later (owner's answer). `.gitattributes` stores and checks out text as LF on every platform: Git for Windows sets `core.autocrlf=true`, and mirrors, vectors and expected C headers are compared byte for byte. Tests use no `std/re`, which loads PCRE at run time and is missing from a Nim built from source. The C11 header test compiles with `$CC`, else the first of `cc`, `gcc`, `clang`. Nix does not build for Windows; llvm-mingw is not evaluated yet. Since I68 no binary compiles BoringSSL, so nasm is not needed until TLS and QUIC (D28) bring it back. | 2026-11-10 |
| I46 | IMPL | Android validation (G124) | The Android SDK is pinned in the flake from nixpkgs' androidenv; the owner chose this, which accepts the Android SDK license, and only `nix/android.nix` uses that package set: platform 35, NDK 29.0.14206865, emulator 36.3.10, the AOSP `default` x86_64 system image. Every suite is cross-compiled under orc, refc and orc+release for x86_64 and aarch64, for Android 10 (API 29) and later [IMPL]; each binary must be a PIE for its ABI that needs only libc, libm, libdl and liblog. `nix run .#test-android` (x86_64 Linux with KVM) boots a headless emulator, pushes the x86_64 suites, the repository and two nim-boringssl vector files, and runs each suite from the repository root; the aarch64 suites are built and checked, not run (G124). Nim's `linux` includes Android, so `crypto/ed25519.nim` links the NDK's libc++ statically (`-lc++_static -lc++abi`) there instead of I44's `-lstdc++`. Device runs need: tests that compile C report SKIPPED (no compiler on a device; their other checks run), `LCN_BORINGSSL_DIR` locates the Ed25519 vectors, and the PKG ownership scan reads `src/` relative to the repository root. Not part of `nix flake check`. Since I68 no binary links BoringSSL's C++, so the static libc++ flags left with `crypto/ed25519.nim`; TLS (D28) brings them back. | 2026-11-10 |
| I47 | IMPL | iOS validation | `nix run .#test-ios` (Apple silicon with Xcode and an iOS simulator runtime) builds every suite with Xcode's clang under orc, refc and orc+release for the arm64 iOS simulator, and under orc for arm64 iOS devices, for iOS 15 and later [IMPL]. Each binary must carry the right platform (7 simulator, 2 device). It creates a simulator on the newest iOS runtime, runs the simulator suites from the repository root through a launcher that changes directory (`simctl spawn` has no working directory), and deletes the simulator; device builds are not run. Xcode is the one input Nix does not pin (D31), so the build happens when the app runs, not in a derivation. The device-run test changes are I46's. | 2026-11-10 |
| R4 | SCOPE (revises D28, G135) | Spec revision 6a4dfa28 and the signature algorithm | The pin moved to `6a4dfa28` and every mirror, pin, vector and requirement ID was recomputed (pins as data: the new roots needed no code change beyond the model id). PM-06 replaced Ed25519 with SLH-DSA-SHA2-192s, which nim-boringssl 0.0.14 cannot provide. Options for the owner: (a) our own Nim FIPS 205 for SHA2-192s only, checked against NIST ACVP and a Python oracle; (b) vendor a portable C FIPS 205 implementation, as BLAKE3 is; (c) OpenSSL ≥ 3.5 beside BoringSSL; (d) liboqs. Fetching the ACVP vectors is a download. **Decided 2026-11-10 (owner: "proceed with your recommendations"):** (b). slhdsa-c (github.com/pq-code-package/slhdsa-c, commit `47451432bb04faf8217ffe8a961a75b542bf88e8`; Apache-2.0 OR ISC OR MIT; portable C90, all FIPS 205 parameter sets, passes the 1248 ACVP cases upstream) is vendored like BLAKE3, compiling only SHA2-192s and the pure and internal functions (no SHAKE, no HashSLH-DSA, which PM §4.3 forbids). Its README still calls it work in progress and not yet recommended for production; the ACVP SHA2-192s subset (ACVP-Server v1.1.0.43: 10 keyGen, 28 sigGen, 28 sigVer cases, every sigVer failure reason) is our independent check. Key generation and hedged signing take randomness from the OS CSPRNG and fail without it (PM §4.3). Ed25519 (I50) stays until the switch lands; the switch replaces the COSE profile, the trust input's 48-byte keys, `lcn-pkg` and the oracle vectors together. **Built 2026-11-10** (owner, asked whether the downloaded code may be compiled here: "You're allowed to compile the code"): see I68. | 2026-11-10 |
| I48 | IMPL | CBOR at 6a4dfa28 (G38, G59) | The decoder rejects floating-point items as `non-deterministic` unless `allowFloats` asks for the generic data model (diagnostics, the float encoder's tests). `maxDepth` counts arrays and maps only (INTERFACE §4.5.1: a root container is depth one); tags have their own `maxTagDepth` (default 1024) so they cannot nest without bound; indefinite strings add no level. `MinMaxDepth = 128`; the default stays 1024. The encoder is iterative, like the decoder, so encoding costs no call stack at any supported depth. The oracle and vectors record both classes (`expect` for Logos CBOR, `data_model` where floats differ). | 2026-11-10 |
| I49 | IMPL | LGX at 6a4dfa28 (G41, G45, G73) | A root `manifest.json` is `invalid-package`; `writeLgx` and `lcn-pkg lgx pack` no longer take one. After the two end blocks only whole zero blocks may follow. Collisions are checked with `PathRules` (ignore case; Windows names) describing the installation filesystem: `openLgx` takes them, defaulting to `hostPathRules()` (case-insensitive on darwin, ios and windows, Windows names on windows), and an installer passes its root's rules. Platform values outside `DefinedOs`, `DefinedArchitectures` and `DefinedAbis` never match, even themselves. | 2026-11-10 |
| I50 | IMPL | Package signing until R4 | **Superseded 2026-11-10 by I68:** Ed25519 is removed and packages are signed with SLH-DSA-SHA2-192s. Until then: the code still signs and verifies with Ed25519 (G42, G135) while `signingProfile()` reads the new SLH-DSA profile id from the mirror, so packages it makes conform to nothing. PKG §4.3 is claimed as `deferred:tier-3`; the Ed25519 tests are tagged as interim, without the retired requirement IDs. The oracle's COSE vectors (`tests/vectors/package/cose.json`) likewise carry the mirrored SLH-DSA profile id in the claim and an Ed25519 signature. | 2026-11-10 |
| I51 | IMPL | Payload depth in the commitment pipeline (INTERFACE §4.5.1, G59) | Validation (`choice.nim` `validateAt`), normalization (`normalize.nim` `value`), the value-tree check (`value.nim` `checkNode`) and the hash layout (`layout.nim` `layoutNode`) count maps, lists and tuples against `DefaultMaxDepth` (1024), not schema or value-tree nodes, so they support every P a binding or transport may configure. References, choice arms, fields and list or tuple elements add no level, and a reference or choice cycle with no container fails instead of looping. Each walk keeps its frames in a heap stack, visiting members depth first in the order the recursive form did (same errors, same `invalid_params` path), so native stack use does not grow with the payload depth: at P = 1024 the walks run in 32 KB. Revised 2026-11-10 after the Windows run: the first version recursed once per container and overflowed Windows' 1 MB main-thread stack under orc (debug); on macOS it needed more than 1 MB under orc and 1-2 MB under refc, more than a macOS or iOS secondary thread's 512 KB. What still grows with depth is the Nim runtime freeing a deep tree: under ORC each node's destructor frees its children recursively, about 224 KB at P = 1024 for the deepest test shape (`demo.single`) on arm64, debug or release; refc frees without recursion. That fits every common thread stack with at least 2x margin. Value objects (`parseNode`, used only by verified views) nest several CBOR containers per payload container and stay bounded by the decoder's 1024, so views of very deep values are refused; no payload path uses them. Test `[IFC-0925] [IFC-0927]`. | 2026-11-10 |
| I52 | IMPL | Per-connection transport limits (TRANSPORT §8.6, §3.4, §5.1) | `TransportLimits` is validated when made. `frameLimit` 16 MiB (over it: ProtocolError INVALID_PARAMS, close); `peerFrameLimit` 16 MiB (sender failures, I53); `payloadDepth` 1024 (I59; deeper: ProtocolError INVALID_PARAMS without detail, close); `maxInFlight` 1024 on the callee (`admitsInput` turns false for backpressure; a Request arriving anyway closes with ProtocolError TRANSPORT_ERROR, no new code per NR-08, as §8.6 l.1350 allows); `maxCalls` 1024 on the caller, abandoned calls included (a new call fails locally with MODULE_ERROR and nothing is sent, as INTERFACE l.2041 does for local capacity); `maxSubscriptionIds` 4096 on both sides (caller: local MODULE_ERROR; callee: closes with TRANSPORT_ERROR before it would forget an id). Retained correlation state is never dropped while the connection is open (§3.4 l.601-602). Documented in the `limits.nim` header. Aggregate limits are Tier 4. **Revised 2026-11-11 (review against 6a4dfa28, item A21):** at `maxInFlight` the carrier stops reading, so a Cancel or Unsubscribe for the admitted Requests stays unread. TRANSPORT l.887-888: the boundary MUST be able to process Cancel without the cancelled request's execution slot, and MUST retain bounded control capacity for cancellation or terminate the connection; l.1351: delayed admission observes cancellation. Against it, l.1357: resource bounds imply no maximum control-message latency. To decide before the Tier 4 carrier: keep reading control frames at the cap, or terminate the connection. **Needs an owner decision** (review item A21). | 2026-11-10 |
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
| I72 | IMPL | Nim module kit, part B: typed provider functions (INTERFACE §2.3, §2.4, §2.7.1) | For a provider, the `export<Module>(T)` template now also defines one `logos_<module-C>_CALL_<namespace>_<Method>` per method of the primary and every implemented interface, with exactly the generated header's parameters, over the same handlers as `_MODULE_dispatch`. A typed call converts its C inputs to the request's CBOR value, checks it with the method's request validator exactly as dispatch does (the same INVALID_PARAMS outcomes, literals, UTF-8 and depth limit), runs the handler, checks the response against its schema (MODULE_ERROR otherwise) and converts it into the C outputs. Both conversions go through checked CBOR values rather than the Nim types, so one validator decides for C callers and dispatch alike. The converters are generated per kit (`codegen/cmirror.nim`, runtime `codegen/callrt.nim`) over Nim objects with the C layout of each §2.3 declaration ("mirrors", positional members); the common schema's mirrors are `codegen/common_mirrors.nim`, written by `nimble regen`. `tests/test_kit.nim` compiles a C program against the generated headers (now fixtures in `tests/generated/`) and checks every mirror's size, alignment and member offsets. A C discriminant maps to its canonical arm explicitly (`cmap` `caseArms`); one that names no arm is INVALID_PARAMS before any payload is read. Inputs: a null text, struct or array pointer, a null required recursive pointer, or a null byte-string or list pointer with a nonzero length or count is INVALID_PARAMS; a zero length or count may come with any pointer, null included; a value whose presence flag is false is never read; lengths and counts above 2^31−1 are refused; an empty value's `_empty` member is ignored on input and zero on output (IFC-0137). Converters stop at the payload depth limit (1024), which also ends a cyclic C value. Outputs: one `CallArena` per call, `calloc` blocks chained through a 16-byte header. On success the arena becomes the response owner: its state is the newest block, and its release frees the chain with the C allocator only, so any thread may clear it, and distinct owners concurrently. A response that allocated nothing gets the empty owner. Empty byte strings and lists point to static storage, never null. Outputs are built in locals and copied to the caller's objects only on success. On failure the arena is released and the owner and outputs stay as the caller initialized them. A response text containing U+0000 has no canonical C value: MODULE_ERROR. A null module, owner or output pointer is MODULE_ERROR before the handler runs; the spec assigns that misuse no code (l.1610). The response check and arm resolution use a per-thread schema copy (`kitSchema`, as in I70). Stack: the converters, like the Nim codecs dispatch uses, recurse once per nesting level, so a provider entry at the default limit needs up to 1 MiB of stack, and threads that call providers need that much. Measured on arm64 macOS: a valid call at depth 1024 needs 512–768 KiB (debug) or 384–512 KiB (release); rejecting depth 1025 needs 384–512 KiB (debug). macOS and iOS secondary threads default to 512 KiB. Keeping the codecs' frames on the heap, as I51 did for the commitment walkers, would remove the requirement; not done. Test hooks: `arenaBlocks()` counts live blocks across threads; `failArenaAllocation(n)` fails the n-th allocation on the calling thread. Not built: typed call helpers and §2.7.2 cleanup helpers (App A.5; part C), `_MODULE_apply_configuration` and `_MODULE_async_api`. Tests: `tests/kit/typed_harness.c` calls every typed function as a C caller does: inputs built in C, the owner and every output zeroed first, results and outputs read back as text. `shapes_module` covers every §2.3 shape: literals, exact, ranged and unbounded byte strings, lists, tuples, inline maps and choices, optionals, recursive trees and common types. In process (`test_kit`) the tests cover round trips, a failure at every allocation of a full response rolled back, invalid inputs that never reach the handler, the depth limit on a thread with exactly 1 MiB of stack, owners released on other threads, and concurrent calls. `test_kit_dylib` covers typed calls through `dlsym` under orc and refc. `tests/kit/typed_linked.c` assigns each declared provider symbol to its contract typedef, so a mismatch fails to compile. IFC §2.3/§2.4/§2.7.1 provider-side units claimed (gate 432/432). **Known deviation (review against 6a4dfa28, item A26, 2026-11-11):** a provider entry can need up to 1 MiB of stack at the kit's default depth, more than a secondary thread's default on macOS and iOS (512 KiB), while INTERFACE l.3154-3155 asks for bounded resources at every supported depth and l.1991 fixes no provider-call thread. The Runtime runs provider entries on threads of at least 1 MiB; a host calling a kit module directly must do the same. Moving the frames to the heap, as I51 did, removes the limit. | 2026-11-11 |
| I73 | IMPL | Nim module kit, part C: typed call helpers and their cleanup helpers (INTERFACE §2.1, §2.7.2, §5.2, App A.5) | `lcn-gen calls [--out:DIR] [--import-prefix:P] [--system] PRIMARY.cddl [--interface:…] [--supporting:…]` writes `<stem>_types.h`, `<stem>_types.nim`, `<stem>_calls.nim` and `<stem>_calls.h` for a provider's accepted set (a module document with its interfaces and supporting schemas, or a standalone interface document), all or nothing (`codegen/callsgen.nim`, runtime `codegen/invokert.nim`). Every method of the primary document and of each implemented interface gets helpers named by its defining contract's §2.1 component; the route decides which of them it accepts, and a helper neither selects a provider nor acquires a route (App A.5). Nim callers: `invoke(route, <Request>): Result[<Response>, InvocationFailure]`, overloaded on the request type. C callers: `lcn_invoke_<namespace>_<Method>(route, response_owner, in…, out…)`, with the provider function's parameters after the route, and `lcn_clear_<namespace>_<Method>(response_owner, out…)`, each with a `_fn` typedef. Names start with `lcn_`, not with `logos_` as App A.5's example does: the names are implementation-defined (§2.1 l.886, and App A is informative), and the `logos_` prefix belongs to the ABI (IFC-0057). `<stem>_calls.h` includes `<stem>_types.h` and is never part of the header set for reconstruction; generating it changes no header and no root (IFC-0627, IFC-0628). The C helpers are defined only where a Nim module instantiates `export<Stem>Calls()`. Exporting is opt-in because two sets that share an interface define the same names: `sensor_module` and `metrics_provider` both define `lcn_invoke_metrics_provider_Snapshot`. A call (`routeCall`): (1) checks the route handle as its consumer must (`checkRoute`: MODULE_ERROR or VERSION_MISMATCH); (2) encodes the request as deterministic CBOR and decodes those bytes strictly once more, so a request without one deterministic-CBOR item fails locally with INVALID_PARAMS and no detail before the route is called; such a request is text that is not UTF-8, nesting past the depth limit, or a C input the converters cannot read (a null text, an unknown discriminant, a cyclic value); (3) checks nothing else locally: the provider validates the request against its schema; (4) sets the outputs to null and zero (IFC-0489) and calls `call` with the bare method name; (5) checks the result and buffer together (`checkOutcome`). Any combination other than a valid failure without a buffer, or LOGOS_OK with a buffer, is MODULE_ERROR with the message `route call: <reason>`, and nothing is released (I66). A valid failure is returned with its code, message and detail; (6) after a success, decodes the buffer into Nim-owned memory and passes the exact pointer and length to `release_response` once (IFC-0491). It does so even when the bytes are not a response, since a success-shaped result has already transferred the buffer (compare IFC-0679); (7) checks the value against the response schema: a value that is not one deterministic item, or that the schema rejects, is MODULE_ERROR. The C helper then fills the outputs through one arena, as I72's typed provider functions do: outputs are built in locals and copied on success; on failure the arena is released and the owner and outputs stay untouched; a response that allocated nothing gets the empty owner. Decoded storage needs neither the route nor the module, and its release frees it with the C allocator only (IFC-0701, IFC-0704, IFC-0705). A null route, owner or output pointer is MODULE_ERROR before the route is called, as in I72. A result's message and detail stay in the calling thread's storage until its next helper or kit call (IFC-0260). Cleanup clears the owner, then zeroes each output object, never reading through them; a null owner or output is skipped, and a second call is harmless. Each calls module has its own per-thread schema copy (`callsSchema`) and its own mirrors and converters. Not built: helpers over the route's asynchronous operations or Runtime Control bindings, and event publication and subscription helpers. Tests: `tests/test_calls.nim` (22 tests) covers: Nim `invoke` through a direct route into each kit module; every typed-harness variant run again through the C helpers (`tests/kit/calls_shims.c`, `calls_linked.c`): round trips of every C shape, invalid inputs that never reach the route, an allocation failure at every point of a full response, the depth limit on 1 MiB of stack, owners that outlive the route and the module, and cleanup of real, zero-initialized and garbage output sets; routes that break their side of the contract: LOGOS_OK without a buffer, with an empty buffer or with a message, a failure with a buffer, an unallocated code, and a success whose bytes are not a response; four threads on distinct routes to shared contexts. Its test route (`tests/support/testroute.nim`) checks that each release names the exact buffer and length it handed out, and overwrites released buffers. `test_kit_dylib` loads the helpers from a library of their own and calls the module libraries through routes, including from threads none of the three runtimes has seen. `test_codegen` checks that each `_calls.h` declares exactly one invoke helper, one clear helper and their typedefs per exposed method, and no `logos_` symbol. It also compiles each header as C17, C23, C++17, C++20 and C++23, asserting that each helper has its typedef's type. Claimed: IFC §2.7.2 and IFC-0260, IFC-0489, IFC-0491, IFC-0627, IFC-0628 (gate 449/449). **Revised 2026-11-11 (review against 6a4dfa28, item A24, A25):** LOGOS_OK with a non-null buffer hands the buffer over even when `checkOutcome` rejects the result (a message on success, a zero length), so the helper releases it exactly once (`abi/checks` `transfersBuffer`; INTERFACE §5.1 l.3364-3368, §5.2 l.3831); a failure code never hands one over. The helpers' encoders write each required literal, whatever its C member holds (§2.3 l.1096); provider-side conversion still reads the member, so validation rejects another value. | 2026-11-11 |
| I74 | IMPL | Runtime slice step 1: the internal Module Loader for direct realization (RUNTIME §1.2, §2.1-§2.4, §3.6, §13.3; LOADER §3-§7, §9-§11) | `runtime/realizer.nim` is shaped like the Loader contract (realize, release, get_status, its descriptors, records and error codes) but is an in-process object owned by the Runtime thread, which serializes its calls (LOADER §11). It advertises `direct_static` and `direct_dynamic`; `hosted_dynamic` is `unsupported-strategy` before anything is read, and `force` is `invalid-request`. Static code: `runtime/native.nim` `checkStaticRegistration` applies §13.3 without running module code. A canonical name is `logos_<module-C>_MODULE_<suffix>` with one of the eight §2.6/§2.9 suffixes, or `logos_<module-C>_CALL_<component>` with a lower-case first letter and an underscore. One table holds one `<module-C>` family. An unknown binding identifier is `invalid-request` (a request no retry can satisfy); a registration for another module, or a `_CALL_` entry the call surface does not define, is `abi-invalid`. Binding (`bindNative`) reads provider-ness from the code: all of `_MODULE_call_surface`, `_MODULE_free` and `_MODULE_dispatch` or none, and some of them is `abi-invalid`. The Runtime compares the surface with the record's expected contracts (step 2). `_MODULE_async_api` is probed and validated for a provider; a consumer-only module's is never called, as it has no provider operations to invoke. Dynamic code: `runtime/artifact.nim` copies the library into a private `mkdtemp` directory (0700), makes the copy read-only, hashes the copy with BLAKE3 and maps it with `RTLD_NOW \| RTLD_LOCAL`. There is one binding per hash suite, digest and module for the realizer's lifetime, never unloaded (TF-03), and errors name no path (LOADER §10). Initialization: input v2 with the Runtime's services and the mapped state directory (`<state root>/<assignment>`, 0700, assignments limited to `[A-Za-z0-9._-]` [G143]); configuration is always absent (CONFIG is not built). Every result and context combination INTERFACE forbids is `realization-failed`. LOGOS_OK with a context but an invalid status first destroys that context once, as A24 releases a buffer. A failure that also returned a context leaks it, since destroy is only for a successful init. Every direct failure is cleaned before `realize` returns, so no failed realization is retained. Realization identifiers are `r-<16 random hex digits>-<counter>`. `realize` runs `_MODULE_init` on the calling thread through `initInstance`, which takes plain values only, so step 2 can run it on a Runtime thread of at least 1 MiB under the 120 s startup deadline. The kit's export template also defines `<module>StaticSymbols()`, its registration table. Tests: `tests/test_realizer.nim`. | 2026-11-11 |
