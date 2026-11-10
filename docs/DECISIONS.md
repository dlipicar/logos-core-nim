# logos-core-nim — Decisions the Logos Core specs do not make

This is the repository copy of the decision record (the planning copy lived outside the repo and is
now frozen). New decisions are added here.

**Spec under implementation:** logos-lips, branch `draft/logos-core-module-specs`, commit `f4f83471`
(2026-10-03; still the branch head on 2026-10-21), files `docs/logos-core/raw/spec-*.md`.
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

Line numbers (`l.N`) refer to those files at `f4f83471`.

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
| G5 | What the LGX package source fields `storage` and `object` contain | PM fetch path, catalog locator shape, storage CID typing, every package install |
| G49 | What CA `publish_events` / `publish-event` mean | the final form of one CA test |
| G93 | How a module reaches its own non-binary artifacts and native libraries | general support; our modules are self-contained meanwhile |
| G116 | Who provides the live-acceptance host and the persistent testnet seeder | the live testnet run |

External dependencies (not spec questions): an org-owned package-signing key (and a provenance key),
an org Apple Developer ID, and the storage mix bootstrap data (mix pool and SPRs) for testnet.

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
15. Revisions and implementation choices since work started (R1–R3, I1–I21)

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

### D14 — Module Loader construction
- **Kind:** CONTRA/FREE · **Specs:** BCP §5.1 (bootstrap Loader, then orchestration, then every module
  via the Loader); LOADER §3 (`direct_static`), §5 (handoffs); RUNTIME §13.3 (static registration).
- **Description:** Private handoffs (file descriptors, process-local bindings) cannot travel over the
  Loader's CBOR contract, which conflicts with Runtime and Loader being allowed in different processes.
- **Options offered:** (a) Loader statically linked in the daemon, registered via the Host Embedding API,
  private handoffs through an in-process side table *(recommended)*; (b) out-of-process Loader with an
  SCM_RIGHTS side channel; (c) no Loader at first (Runtime-only claim).
- **Decision:** (a). Loader failure follows the spec path (G56).

### D15 — Where authority policy lives
- **Kind:** FREE · **Specs:** RUNTIME §9 l.1490-1521 (default-deny policy mandatory; internal policy
  allowed "for local trusted deployments"), CA §1, §12; BCP §5.3 (call evidence mandatory for every
  Runtime).
- **Options offered:** (a) internal policy emitting CA-shaped records, CA module later *(recommended)*;
  (b) `logos_capability_authority` module from the start; (c) internal only.
- **Decision:** (b) in the node daemon. The CLI's embedded Runtime uses internal policy (G78).

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

### D18 — Who signs packages
- **Kind:** FREE · **Specs:** PM §2, §4, §4.1 l.440-441 (a local development deployment MAY configure its
  own anchor through the same protected trust-input path), §4.3 (mandatory COSE_Sign1 Ed25519 profile);
  SECURITY §13 (no unsigned compatibility path); BCP §5.2-§5.3.
- **Description:** Today's `.lgx` packages (manifest.json, did:jwk signature, SHA-256 root hash) cannot
  pass spec verification, and there is no unsigned or legacy import path.
- **Options offered:** (a) dev anchor now, org key later *(recommended)*; (b) org key before testnet.
- **Decision:** (b). A dev anchor is used only for CI and local work. Provisioning: G137.

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

### D28 — TLS and QUIC stack
- **Kind:** FREE · **Specs:** TRANSPORT §8.4.1 (TLS 1.3 only, mutual TLS, RFC 9266 tls-exporter, no
  resumption or 0-RTT), §8.4.2 (QUIC v1, ALPN `logos.remote.quic`).
- **Description:** chronos' built-in TLS is BearSSL, which lacks TLS 1.3.
- **Options offered:** (a) BoringSSL + lsquic, as nim-libp2p and delivery use *(recommended)*;
  (b) OpenSSL 3.5 for both; (c) OpenSSL 3 + ngtcp2.
- **Decision:** (a), statically linked with hidden symbols.

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

### G1 — Value identity under alias chains
- **Kind:** GAP · **Specs:** COMMITMENT §8 (value tree, local references), §9.2; HASH §7.3 (a child
  record's identity must equal field 2 of the child payload).
- **Description:** COMMITMENT §8 gives a one-hop rule: a local reference never inlines its target and
  adds no node; the containing node keeps the referring location's identity and the child carries the
  referenced declaration's identity. It never addresses chains such as `a.x = a.y` with `a.y = tstr`.
- **Options offered:** (a) the innermost declaration `a.y` — the one-hop rule applied at each step
  *(recommended)*; (b) the outermost declaration `a.x` (what poc2 does); (c) ask the spec author.
- **Decision:** (a).

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

### G3 — Unqualified common names
- **Kind:** CONTRA · **Specs:** COMMITMENT §5 l.697-698 (unqualified common names are "interpreted as
  names in that namespace") vs INTERFACE §1.1, §5.3 and BCP §6.1 l.388-390 (interoperability requires
  complete documents with explicit qualified names).
- **Description:** Whether a module schema may write `error_code` to mean `logos.error_code`.
- **Options offered:** (a) reject, raise upstream *(recommended)*; (b) accept per COMMITMENT §5;
  (c) ask the spec author.
- **Decision:** (a). Only `logos.`-qualified common names are accepted.

### G4 — Declarations nested deeper than the namespace
- **Kind:** GAP · **Specs:** COMMITMENT §3.1 step 2 (the namespace must be a proper prefix of every name;
  nothing forbids extra segments) vs INTERFACE §2 l.537 (every accepted schema set MUST be representable
  in both forms) and §3.8 (CDDL -> C -> CDDL MUST reproduce the same model).
- **Description:** `storage.sub.thing` next to `storage.x` projects to `logos_storage_sub_thing_t`, which
  maps back to `storage.sub_thing`; a bare method name `sub.read` would contain a dot.
- **Options offered:** (a) reject *(recommended)*; (b) accept; (c) ask the spec author.
- **Decision:** (a), derived from the §3.8 round-trip requirement.

### G6 — Referencing a common callable declaration
- **Kind:** GAP · **Specs:** INTERFACE §1.1, §1.7 (imply types only); COMMITMENT §5 (silent).
- **Description:** Whether a schema node may reference `logos.schema_request` / `logos.schema_response`
  (callables) or only common named types.
- **Options offered:** (a) named types only *(recommended)*; (b) callables too; (c) ask the spec author.
- **Decision:** (a).

### G7 — What a verified-view path ending in a field or tuple position discloses
- **Kind:** GAP · **Specs:** COMMITMENT §9.4 (semantic paths); HASH §8 (verified views), App B.1 (list
  elements disclose the inner value); an empty path discloses the whole value.
- **Options offered:** (a) the inner value node, as for list elements *(recommended)*; (b) the wrapper
  node (label + child record); (c) ask the spec author.
- **Decision:** (a).

### G8 — Choice-arm segment when crossing a choice
- **Kind:** GAP · **Specs:** COMMITMENT §9.4 (defines `choice-arm-segment`; never states it is required).
- **Options offered:** (a) required *(recommended)*; (b) optional (implied by the value).
- **Decision:** (a).

### G9 — Literal outcomes in the choice selection plan
- **Kind:** GAP · **Specs:** COMMITMENT §3.1 (choice selection plan; the normative plan table l.490-503
  now names a "map-field-literal test").
- **Description:** When checking that a choice's arms are distinguishable, which literals count.
- **Options offered:** (a) only literal constraints on the arm's top-level observed value, following
  references and nested choices *(recommended)*; (b) every literal reachable in an arm; (c) ask.
- **Decision:** (a).

### G119 — Are literal-element lists packable?
- **Kind:** GAP · **Specs:** HASH §4 l.162-165 (packable scalar kinds: bool, uint8..uint64, int8..int64;
  lists of tstr, bstr, reference, choice or composite values are not packable).
- **Description:** Lists such as `[* true]` or `[* 5]` have a literal element schema; literals appear in
  neither list.
- **Options offered:** (a) packable — a literal's scalar kind is bool/uint64 *(recommended)*; (b) not
  packable; (c) ask the spec author.
- **Decision:** (a).

### G120 — Where the verified-view verifier gets the schema
- **Kind:** GAP · **Specs:** HASH §8, §9; INTERFACE §5.3 (schema text is untrusted input).
- **Options offered:** (a) caller-supplied; the verifier recomputes its root and rejects a mismatch with
  the view's root *(recommended)*; (b) only schemas already known by root in a pinned registry.
- **Decision:** (a).

### G122 — `logos.schema.reference`
- **Kind:** GAP · **Specs:** COMMITMENT §6; HASH §7.2 (define the domain); no spec object produces it.
- **Options offered:** (a) implement it, unit tests only *(recommended)*; (b) leave it unclaimed.
- **Decision:** (a).

### G10 — `0*` and `*1` occurrence spellings
- **Kind:** GAP · **Specs:** cdCDDLe §5.1 l.172 ("occurrences other than the supported `?` map-member and
  `*` array-member forms" are unsupported).
- **Description:** `[0* T]` means `[* T]` and `*1` means `?`, but they are other spellings.
- **Options offered:** (a) reject *(recommended)*; (b) normalize. **Decision:** (a).

### G11 — String-escape grammar
- **Kind:** GAP · **Specs:** cdCDDLe §5 l.125 (parse and resolve follow RFC 8610), l.455 (escape spelling
  is not preserved). RFC 9682 later updated CDDL's escape syntax.
- **Options offered:** (a) RFC 8610, as cited *(recommended)*; (b) RFC 9682 (documented deviation).
- **Decision:** (a).

### G12 — Named range bounds
- **Kind:** GAP · **Specs:** cdCDDLe §5.1 l.163 ("inclusive integer ranges written with `..`"; RFC 8610
  allows value names as bounds).
- **Options offered:** (a) reject; integer-literal bounds only *(recommended)*; (b) resolve names to
  literals. **Decision:** (a).

### G13 — Non-flattened nested choices
- **Kind:** GAP · **Specs:** cdCDDLe §7.2 / l.332 (canonicalization MUST flatten nested type choices),
  §10 (decoder rejections; this case not named).
- **Options offered:** (a) the decoder rejects it *(recommended)*; (b) only the checker flags it.
- **Decision:** (a).

### G14 — Scope of the cdCDDLe document built for a Logos schema
- **Kind:** GAP · **Specs:** cdCDDLe §8 (schema-as-data); COMMITMENT §5 (prelude, common and supporting
  schemas).
- **Options offered:** (a) authored rules only; prelude, common and supporting names stay type-reference
  nodes resolved against an explicit external scope *(recommended)*; (b) merge the resolved graph, then
  filter by origin. **Decision:** (a).

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
- **Kind:** GAP, **OPEN** (found while building; not yet reported) · **Specs:** cdCDDLe §5.1 l.164 (the
  `.size` control is supported, with no limit on its target), §6 l.227 (every graph in the subset has a
  model), §8 l.530 and l.537 (the node's target is a `primitive`, one of `uint`, `tstr`, `bstr`).
- **Description:** `b = tstr` and `a = b .size 3` is inside §5.1, but §8 has no node for it.
- **Options:** (a) keep rejecting it as unsupported until the owner answers; (b) allow a reference target
  in the `.size` node; (c) state in §5.1 that the target is written as a primitive.
- **Interim (D9):** (a). No mirrored schema uses it: every `.size` in the specs is on `uint`, `tstr` or
  `bstr` directly.

### G152 — Identity of a leaf-bodied declaration's own node
- **Kind:** GAP, **OPEN** (found while building; not yet reported) · **Specs:** COMMITMENT §4 l.560-562
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

### G17 — Independent oracle for self-written vectors
- **Kind:** FREE · **Specs:** none (most specs ship no vectors; see the background above).
- **Options offered:** (a) an independent Python reference (cbor2 + blake3) written from the spec text
  *(recommended)*; (b) the Python reference plus poc2 where its rules match; (c) no oracle.
- **Decision:** (a). Disagreements block.

---

## 3. Interface: schemas, C mapping, code generation

### G117 — What counts as normative text
- **Kind:** GAP · **Specs:** only cdCDDLe §4 l.87-88 cites BCP 14 (RFC 2119/8174); the other eleven
  specs use uppercase MUST/SHOULD/MAY without the boilerplate, and 55 lines use lowercase must/should.
- **Options offered:** (a) uppercase keywords are BCP 14 everywhere; every lowercase modal becomes a
  traceability row needing a test or a written triage reason *(recommended)*; (b) uppercase only.
- **Decision:** (a).

### G118 — Uppercase keywords inside informative sections
- **Kind:** GAP · **Specs:** INTERFACE App A.3 l.2934-2981 (MUSTs under a section titled
  "Informative"); SECURITY (category Informational) l.230, l.441.
- **Options offered:** (a) claim and test them as normative, raise the inconsistency upstream
  *(recommended)*; (b) exclude them. **Decision:** (a).
- **Note:** the question originally also cited RUNTIME App A and BCP §6-§8; the final review found those
  contain only MAYs and lowercase modals (covered by G117), so the citation was narrowed.

### G139 — Is the C->CDDL reverse mapper a conformance requirement?
- **Kind:** CONTRA · **Specs:** INTERFACE Abstract l.22-30 (the mapping is total; a conforming
  implementation MUST recover the same model from either representation), §3, §3.8 l.1876-1891, §3.9
  (normative cases, 13 named rejection cases) vs BCP §6.1 l.372 ("Code generation is an implementation
  technique rather than a conformance requirement"), l.412.
- **Options offered:** (a) implement it, every spec piece tested, raise the contradiction
  *(recommended)*; (b) defer and mark unclaimed; (c) ask the spec author first.
- **Decision:** (a) implemented and claimed (D30).

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

### G59 — Value nesting depth
- **Kind:** GAP · **Specs:** INTERFACE §2.3, §3.9.3 and COMMITMENT l.427-428 (recursive types are legal);
  INTERFACE §4.4-§4.5, HASH (no depth bound); SECURITY §10 l.367 (frame limits not bounding other state
  is a residual risk); INTERFACE §4.5 (closed `invalid_params_reason` list).
- **Description:** A 16 MiB frame can nest about 16 million levels. No spec caps depth, and a schema-valid
  value rejected for depth has no matching INVALID_PARAMS reason.
- **Options offered:** (a) iterative processing plus a configurable cap (default 1024), over-cap =
  INVALID_PARAMS without detail, raised upstream *(recommended)*; (b) iterative, no cap.
- **Decision:** (a).

Background for G62-G72: INTERFACE §2 requires any two implementations to produce identical C header sets
"modulo whitespace, comments, include layout, and include guards", and §2.4 makes the exported per-method
signatures mandatory, so these are not cosmetic. Runtime Control itself (RUNTIME l.1814, a tuple-arm
choice) and the CA (l.1001, `[* bstr]` in a list position) use shapes the C mapping does not define.

### G62 — C form of inline tuples, lists or unbounded bstr as choice arms or list elements
- **Kind:** GAP · **Specs:** INTERFACE §2.3 (defines inline tuples only as fields or named tuples; lists
  and bstr as adjacent pairs; inline composites path-named `list_item`, `tuple_<i>`, `arm_<i>`);
  COMMITMENT l.496 (declares `[uint64] / [uint64, uint64]` valid).
- **Options offered:** (a) path-named synthetic types extending the spec's naming: a tuple arm is a struct
  with `item_<i>` fields, a list/bstr becomes an adjacent ptr+len pair inside it; raised upstream
  *(recommended)*; (b) reject in the C mapping (no typed C bindings for Runtime Control and CA).
- **Decision:** (a).

### G63 — Choice-of-maps event bodies in C
- **Kind:** GAP · **Specs:** INTERFACE §1.5 (allows choice-of-maps events) vs §2.5 (maps only map-bodied
  events).
- **Options offered:** (a) mirror the method rule: a wrapper struct with a kind tag and a union of arm
  structs, as §2.4 rules 4-5 do for requests *(recommended)*; (b) reject them. **Decision:** (a).

### G64 — Tagged-choice tag member
- **Kind:** CONTRA · **Specs:** INTERFACE §2.3 (a generator MAY omit the tag member) vs §2 (headers must
  be identical across implementations).
- **Options offered:** (a) always emit it *(recommended)*; (b) always omit it. **Decision:** (a).

### G65 — Literal macro spelling
- **Kind:** GAP · **Specs:** INTERFACE §2.3 (macro holds "the exact C scalar literal"), §3.5 (reverse
  mapper checks the macro).
- **Options offered:** (a) stdint macros: `UINT64_C(7)`, `INT64_C(-5)`, INT64_MIN as
  `(-INT64_C(9223372036854775807) - 1)`, `true`/`false`, C strings with `\xNN` escapes *(recommended)*;
  (b) plain suffixes (`7u`, `7ull`, `-5ll`, `1`/`0`). **Decision:** (a).

### G66 — Optional inline tuple vs the `has_` adjacency rule
- **Kind:** GAP · **Specs:** INTERFACE §3.4 (a `has_` flag sits adjacent to the member it guards); an
  inline tuple expands into several members.
- **Options offered:** (a) `has_<f>` immediately before the first expanded member *(recommended)*;
  (b) reject optional inline tuples. **Decision:** (a).

### G67 — Allocation and free order of recursive typed outputs
- **Kind:** GAP · **Specs:** INTERFACE §2.7 (callers free each dynamic output with `_free`; recursive
  `const B*` edges not addressed).
- **Options offered:** (a) one provider allocation per node, freed children first *(recommended)*; (b) one
  block per output tree. **Decision:** (a).

### G68 — Freeing typed route-helper outputs
- **Kind:** GAP · **Specs:** INTERFACE §2.7 ("the side that decodes … owns and frees its own decoded
  allocations"), App A.5; no API named.
- **Options offered:** (a) generated consumer-side free helpers, never the provider's `_free`
  *(recommended)*; (b) helpers take an allocator parameter. **Decision:** (a).

### G69 — Static-link symbol collisions
- **Kind:** GAP · **Specs:** INTERFACE §1.3, §2.1 (a schema set deriving the same C identifier twice is
  invalid); RUNTIME §1.3 (`_call_` / `_publish_` reserved in module names).
- **Description:** Module `foo` with namespace `call` and method `surface` derives
  `logos_foo_call_call_surface`, which module `foo_call` also exports; names ending in `_call`/`_publish`
  are not covered.
- **Options offered:** (a) reject module names ending `_call`/`_publish` and namespaces named
  `call`/`publish`, raised upstream *(recommended)*; (b) detect only at registration.
- **Decision:** (a).

### G70 — Source of `schema_cbor` for `materialize_route`
- **Kind:** GAP · **Specs:** INTERFACE §5.2 (one `logos.schema_response`, 1 B-8 MiB, validated against
  `expected_contract_root`); RUNTIME §4.2 ("Generated typed helpers can carry this expectation by
  construction"); `route_record` carries only the commitment.
- **Options offered:** (a) generated bindings embed it at build; generic clients (logosctl) use
  `describe_provider` *(recommended)*; (b) always fetch at run time. **Decision:** (a).

### G71 — Generated helper names
- **Kind:** CONTRA (both informative) · **Specs:** INTERFACE App A.4/A.5 (`logos_<module>_publish_<ns>_<event>`,
  `logos_<ns>_invoke_<method>(route, …)`) vs RUNTIME §4.1 (`logos_storage_exists(h, …)`).
- **Options offered:** (a) INTERFACE A.4/A.5 — matches the reserved `_publish_` infix and cannot collide
  with provider symbols *(recommended)*; (b) RUNTIME §4.1 style. **Decision:** (a); helpers are never
  exported from module artifacts (INTERFACE l.235-238).

### G72 — Header declaration order
- **Kind:** GAP · **Specs:** INTERFACE §2.1 (orders forward declarations, type definitions, fields, choice
  arms; not macros, lifecycle symbols and typedefs relative to provider declarations).
- **Options offered:** (a) forward declarations, type definitions (spec order), literal macros by name,
  provider functions by qualified name, lifecycle symbols; raised upstream *(recommended)*; (b) ask the
  spec author. **Decision:** (a).

---

## 4. Error codes the specs require but do not assign

Background: INTERFACE §5.1 fixes a closed registry (0 OK, 1 METHOD_NOT_FOUND, 2 INVALID_PARAMS,
3 MODULE_ERROR, 4 NOT_AUTHORISED, 5 TRANSPORT_ERROR, 6 TIMEOUT, 7 VERSION_MISMATCH, 8 NOT_READY,
9 CANCELLED); only INVALID_PARAMS may carry detail, and only with reason malformed-cbor,
non-deterministic-cbor or schema-mismatch. Expected domain failures must be LOGOS_OK with a typed
response (INTERFACE §4.6). RUNTIME §3.4 l.633 reserves NOT_READY for "Runtime-owned lifecycle, provider,
or route readiness". Execution-boundary invariance (INTERFACE intro, RUNTIME l.40-64) requires the same
code in direct, local and remote mode. Many MUST-reject rules name no code; these entries fix them so
tests can assert exact values.

### G18 — `request_key` reused with different fields
- **Kind:** GAP · **Specs:** RUNTIME §9.3 (create_module / establish_route idempotency).
- **Options offered:** (a) INVALID_PARAMS without detail *(recommended)*; (b) MODULE_ERROR.
- **Decision:** (a).

### G19 — Stale expected revision on a compare-and-set request
- **Kind:** CONTRA · **Specs:** RUNTIME §9.1, §9.3 (expected execution / permission revisions), CONFIG
  (expected configuration revision) vs RUNTIME l.633.
- **Options offered (first):** (a) NOT_READY *(recommended)*; (b) INVALID_PARAMS. **First decision:** (a).
- **Re-check (final review):** l.633 limits NOT_READY to readiness, and a stale revision is not readiness.
  Options: (a) split — readiness preconditions keep NOT_READY, stale revisions become INVALID_PARAMS
  without detail *(recommended)*; (b) keep NOT_READY and record a CONTRA.
- **Decision:** INVALID_PARAMS without detail. **Status:** revised.

### G20 — Lifecycle preconditions not met
- **Kind:** GAP · **Specs:** RUNTIME §9.3 (start_module while stopping, recover_module outside allowed
  states, renew_route on a closed or failed route the caller may observe).
- **Options offered:** (a) NOT_READY *(recommended)*; (b) INVALID_PARAMS. **Decision:** (a) (these are
  Runtime-owned lifecycle/route readiness, within l.633).

### G21 — `apply_configuration` failures
- **Kind:** CONTRA · **Specs:** CONFIG §8 (live reconfiguration), RUNTIME §9.3 (the response has no
  failure variant) vs RUNTIME l.633.
- **Options offered (first):** (a) preconditions NOT_READY / module rejects MODULE_ERROR / indeterminate
  MODULE_ERROR *(recommended)*; (b) all MODULE_ERROR. **First decision:** (a).
- **Re-check:** "no staged record" and "binding not live-reconfigurable" are not readiness. Same split as
  G19 *(recommended)* vs keep.
- **Decision:** readiness preconditions NOT_READY; no staged record or non-live binding INVALID_PARAMS;
  module rejection and indeterminate outcome MODULE_ERROR. **Status:** revised.

### G22 — Calls on a dead route handle
- **Kind:** GAP · **Specs:** RUNTIME §4.1 (calls on closed, failed, revoked or expired handles MUST
  fail), INTERFACE §5.2; TRANSPORT §3.2 (connection close gives TRANSPORT_ERROR).
- **Options offered:** (a) closed/failed NOT_READY, revoked/expired NOT_AUTHORISED, checked at the
  Runtime boundary so every mode agrees *(recommended)*; (b) all NOT_AUTHORISED; (c) all TRANSPORT_ERROR.
- **Decision:** (a).

### G23 — Calls into a stopping provider; calls on an invalidated Runtime Control binding
- **Kind:** GAP · **Specs:** RUNTIME §3.4 (stopping invalidates the instance's RC bindings); TRANSPORT
  (in-flight calls get TRANSPORT_ERROR when the connection closes; CANCELLED only for processed Cancels).
- **Options offered:** (a) NOT_READY for both *(recommended)*; (b) CANCELLED. **Decision:** (a); in-flight
  transport calls keep the mandated TRANSPORT_ERROR.

### G24 — A required system service other than the CA is unavailable
- **Kind:** GAP · **Specs:** RUNTIME "System Service Availability" (fail the dependent operation), l.1516
  (an unavailable external CA means deny, hence NOT_AUTHORISED).
- **Options offered:** (a) NOT_READY for Loader / Package Manager *(recommended)*; (b) MODULE_ERROR.
- **Decision:** (a).

### G25 — Native binding failures
- **Kind:** GAP · **Specs:** INTERFACE §5.2 (a vtable failing its checks MUST be rejected; failed
  `materialize_route` / `connect_remote` leave outputs null; no codes named; `connect_remote` through a
  remote binding is INVALID_PARAMS).
- **Options offered:** (a) vtable VERSION_MISMATCH (like `_init`'s version check) / materialize_route
  returns the route-establishment failure's code / non-remote endpoint INVALID_PARAMS *(recommended)*;
  (b) all INVALID_PARAMS. **Decision:** (a).

### G26 — Listener, export and enrollment rejections
- **Kind:** GAP (partly spec-resolved) · **Specs:** RUNTIME §9.3 l.2991-3017; l.433 and l.2774-2776
  (unknown or hidden targets give a non-revealing NOT_AUTHORISED — already mandated).
- **Options offered:** (a) malformed or unsupported profile INVALID_PARAMS; unknown/hidden NOT_AUTHORISED
  *(recommended)*; (b) all NOT_AUTHORISED. **Decision:** (a).

### G27 — Vocabulary of `route_failure.code` and `permission_settings_state.failure`
- **Kind:** GAP · **Specs:** RUNTIME §9.3 (both `tstr .size(1..64)` with no value list, yet l.2864-2871 and
  l.2937-2943 require distinguishing facade failure, remote unreachable / not ready / stopped / failed,
  denial vs evaluation failure, contract mismatch, enrollment/listener/export defects, ticket defects,
  expiry, revocation, connection loss).
- **Options offered:** (a) a fixed, documented kebab-case list with one value per class *(recommended)*;
  (b) free text. **Decision:** (a).

### G28 — Loader values for weaker-substitute refusal and disallowed init results
- **Kind:** CONTRA · **Specs:** LOADER §6 l.395-396, l.423, §10 l.612 (`unsupported-strategy` lets
  Runtime choose another strategy or placement), l.615-616 (initialization failures are
  `realization-failed`); TRANSPORT l.960 (no isolation downgrade).
- **Options offered (first):** (a) `unsupported-strategy` / `abi-invalid` *(recommended)*;
  (b) `unsupported-strategy` / `realization-failed`. **First decision:** (a).
- **Re-check:** (a) follow LOADER's own definitions — refusal = `unsupported-strategy`, but Runtime never
  reselects a weaker strategy or placement and fails the request; disallowed init result =
  `realization-failed` *(recommended)*; (b) keep the first answer as a documented deviation.
- **Decision:** re-check (a). **Status:** revised.

### G60 — Host Embedding API edge cases
- **Kind:** GAP (partly spec-resolved) · **Specs:** RUNTIME §13.3 l.3436 (listed binding defects =
  INVALID_PARAMS), §13.4 l.3470 (otherwise the applicable shared code, else MODULE_ERROR).
- **Options offered:** (a) `wait_for_shutdown` returns MODULE_ERROR when cleanup failures were recorded;
  bad bindings rejected at `register_binding` with INVALID_PARAMS *(recommended)*; (b) LOGOS_OK with
  failures only logged; rejection at realization.
- **Decision:** (a). Symbol defects beyond the l.3436 list are the remaining gap.

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

### G31 — Uncorrelated Response, SubscriptionResult or Event
- **Kind:** GAP · **Specs:** TRANSPORT §1.4 (exactly one Response per Request id), §6, §5.1; RUNTIME §9.3
  (timeout policy is the implementation's, so a late Response to a call the caller abandoned after its
  own timeout is legitimate).
- **Options offered:** (a) tombstones — replies to ids the caller abandoned are dropped silently;
  never-sent or duplicate ids get ProtocolError INVALID_PARAMS + close *(recommended)*; (b) always close;
  (c) always drop. **Decision:** (a).

### G32 — Subscription id misuse
- **Kind:** GAP · **Specs:** TRANSPORT §5.1 (caller ids unique per connection; at most one outstanding
  control operation per id; exactly one SubscriptionResult per syntactically valid Subscribe/Unsubscribe;
  no code named for reused or unknown ids).
- **Options offered:** (a) a failed SubscriptionResult with INVALID_PARAMS for reuse, unknown id and
  overlap, state unchanged *(recommended)*; (b) failed result for reuse/unknown, ProtocolError + close
  for overlap. **Decision:** (a).

### G33 — Non-empty Hello response token
- **Kind:** GAP · **Specs:** TRANSPORT §3.1 (caller validates the token "under the profile's response
  rules", no code), §8.1, §8.2; RUNTIME §9 (every defined profile requires an empty response token).
- **Options offered:** (a) ProtocolError NOT_AUTHORISED + close *(recommended)*; (b) INVALID_PARAMS.
- **Decision:** (a).

### G34 — When the provider Hello runs and what the consumer sees when it fails
- **Kind:** GAP · **Specs:** TRANSPORT §3.1, §3.2 (synthetic TRANSPORT_ERROR on close), §8.1.1 (tickets
  live at most 60 s); INTERFACE §4.6; RUNTIME §4.1, §9 (Hello authorization failure = NOT_AUTHORISED).
- **Options offered:** (a) the Hello runs inside `materialize_route`, which returns the peer's code
  (NOT_AUTHORISED, VERSION_MISMATCH) *(recommended)*; (b) lazy connect on first call, failures surface as
  TRANSPORT_ERROR. **Decision:** (a).

### G35 — Route expiry or revocation on a live session
- **Kind:** GAP · **Specs:** TRANSPORT §8.1 (reject new operations, then end subscriptions and the
  session), §8.2, §8.4.1 (one session per connection); CA §8 (sessions may stay open but unusable while a
  fresh decision is fetched); RUNTIME §9.3 (audit distinguishes expiry, revocation, connection loss). The
  on-wire signal is unspecified.
- **Options offered:** (a) new Requests in the window get NOT_AUTHORISED; then ProtocolError
  NOT_AUTHORISED + close *(recommended)*; (b) silent close. **Decision:** (a).

### G36 — Schema-invalid response-ok or Event
- **Kind:** GAP · **Specs:** TRANSPORT §4.1 (receiver validates against the declared type and compares
  roots; a mismatch is ProtocolError + close); SECURITY §8 (fail closed).
- **Options offered:** (a) fail closed: ProtocolError INVALID_PARAMS, close the provider session, the
  waiting caller gets TRANSPORT_ERROR *(recommended)*; (b) reject only that message.
- **Decision:** (a).

### G37 — Schema check vs commitment check on a Request
- **Kind:** GAP · **Specs:** TRANSPORT §4.1 (sentence order: validate, recompute, compare; no explicit
  precedence, unlike §8.3 for Hello); RUNTIME §4.1 (validation and hashing may be combined).
- **Description:** A Request that is schema-invalid and whose subtree root is also wrong could get
  response-err INVALID_PARAMS (session kept) or ProtocolError + close.
- **Options offered:** (a) schema first *(recommended)*; (b) commitment first.
- **Decision:** (b) commitment first: any root mismatch closes the session.

### G58 — Socket layout
- **Kind:** CONTRA · **Specs:** RUNTIME §1.3 (the module name drives `<runtime-dir>/logos_<name>.sock`) vs
  TRANSPORT §8.2 (Runtime creates a 0700 directory per instance, binds and listens, transfers the
  listener; callers check the peer's OS identity before sending the ticket); sun_path limits (104 bytes
  on macOS, 108 on Linux).
- **Options offered:** (a) a per-instance 0700 directory containing the §1.3 name:
  `<short base>/<8-hex>/logos_<name>.sock`, placement fails if the path doesn't fit, peer check by euid,
  Module Hosts run as the daemon's uid *(recommended)*; (b) RUNTIME §1.3 literally, one hosted instance per
  name. **Decision:** (a).

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

### G53 — Names of the orchestration and CLI modules
- **Kind:** GAP · **Specs:** RUNTIME §1.3, INTERFACE §1.3 (`logos_` reserved for Logos-defined runtime
  and system modules); BCP §5 (assigns names to PM, Loader, CA, Runtime Control only).
- **Options offered:** (a) `orchestrator` + `logosctl`, asking the author whether orchestration should get
  a `logos_` name *(recommended)*; (b) `logos_orchestrator` + `logosctl`. **Decision:** (b).

### G54 — What `list_modules` shows
- **Kind:** spec-resolved · **Specs:** RUNTIME l.164 (system services are ordinary records), l.2963-2964
  (what list_modules returns); Runtime Control is intrinsic, not a module instance.
- **Options offered:** (a) Runtime Control never listed; system instances listed under observation policy
  *(recommended)*; (b) Runtime Control as a synthetic record. **Decision:** (a).

### G55 — Choosing the installed package for a module name
- **Kind:** GAP · **Specs:** RUNTIME §9.3 (`create_module_request = {request_key, module}` is closed;
  "Runtime MUST select one accepted declaration … under active policy or fail"; the selection is retained
  and never re-inferred from inventory or newer packages); PM §5, §11 (several versions may be installed;
  nothing forbids two packages declaring one module); CA §3.3 (module_execution_scope may carry
  package/version).
- **Options offered:** (a) highest installed normal release; two different packages declaring the module
  fail without disclosure; an explicit pin is a CA module_execution_scope grant *(recommended)*; (b) highest
  release, no pinning. **Decision:** (a). The bootstrap pin counts as one candidate (G92).

### G56 — Module hosts orphaned by a failed Loader
- **Kind:** GAP · **Specs:** LOADER §7 (realization ids are scoped to the issuing provider; no adoption
  rule); RUNTIME §10.1 (a module failure does not terminate the Runtime), §10.2 step 5 (forced cleanup by
  the Runtime host or deployment mechanism).
- **Options offered:** (a) the daemon kills the orphaned hosts, their instances become `error`, the
  orchestrator recovers them through the new Loader *(recommended)*; (b) ask the spec author.
- **Decision:** (a).

### G57 — How the bootstrap Loader reports its own realization
- **Kind:** spec-resolved · **Specs:** RUNTIME l.3060-3061 ("Other realization mechanisms MUST use
  implementation-specific").
- **Options offered:** (a) `implementation-specific` *(recommended)*; (b) `direct_static`.
- **Decision:** (a).

### G61 — Timeout defaults
- **Kind:** FREE · **Specs:** TRANSPORT §8.1.1 (tickets ≤ 60 s), §6 (a timeout can only send Cancel and
  accept the single committed response); RUNTIME §6.2 (a hosted startup timeout is mandatory, value
  free), §9.3, §10.2, §13.2.
- **Options offered:** (a) Hello 10 s; route call 30 s then Cancel and TIMEOUT; hosted startup 120 s; stop
  drain 10 s; shutdown grace 10 s per realization then force-release; Ctrl-C during start queued until start
  returns *(recommended)*; (b) the same without a default call timeout. **Decision:** (a), all in the
  deployment profile and overridable.

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

### G143 — State layout, retention and audit retention
- **Kind:** FREE · **Specs:** RUNTIME §8, l.1317 (allocation, reuse, retention, deletion, migration of
  concrete state are policy decisions); LOADER §5.1; BCP §5.4 (the deployment must document directories,
  state realization, retention, cleanup, recovery); CA l.941 (audit retention is deployment policy).
- **Options offered:** (a) `<session>/state/<module_instance_id>/` (0700); identity and state survive
  package update and `module upgrade`; state kept after `package rm` until `logosctl state purge` with
  logosd stopped; audit store bounded by count and age *(recommended)*; (b) `package rm` deletes the
  instances' state. **Decision:** (a).

---

## 7. Capability Authority

### G46 — A running module loses its execution authorization
- **Kind:** GAP · **Specs:** CA §3.3 (execution authorization), §8 (terminate dependent sessions when
  continued use would exceed current authority; sessions MAY stay open but unusable while a fresh decision
  is fetched); RUNTIME §10.1 (a stop caused by permission withdrawal preserves intent; orchestration
  resumes via `recover_module` when permissions return).
- **Options offered:** (a) re-evaluate first; stop only on deny (intent preserved); on evaluation failure
  keep running but deny new decision-requiring operations *(recommended)*; (b) stop immediately.
- **Decision:** (b). Intent is preserved per RUNTIME §10.1, so the module resumes when allowed again.

### G47 — How an external CA learns consumer attributes
- **Kind:** GAP · **Specs:** CA §2 (Runtime supplies authenticated consumer context; no wire field for
  attributes); RUNTIME l.1528 (policy MAY use attributes derived from authenticated context).
- **Options offered:** (a) the CA observes them through its own Runtime Control binding (`list_modules`,
  `get_execution_summary`) under bootstrap grants *(recommended)*; (b) add an attributes field to
  `evaluate` (deviation). **Decision:** (a).

### G49 — Meaning of `publish_events` / `publish-event`
- **Kind:** GAP · **Specs:** CA §3.1 (`route_access.publish_events`, provider-access action
  `publish-event`); TRANSPORT §1.4 (only the callee sends Events; there is no consumer-to-provider event
  path).
- **Options offered:** (a) accept and commit them in grants, never enforce, ask the author
  *(recommended)*; (b) reject any grant or scope containing them.
- **Decision:** (a). **Status:** OPEN — the owner is asking the spec author.

### G50 — Call-evidence proof arrays
- **Kind:** GAP (partly spec-resolved) · **Specs:** CA §9.1 (no rule on per-side ordering or duplicates),
  l.110-115 (CA's set-valued arrays are strictly ascending without duplicates), l.1049 ("If proofs is
  present, it MUST contain at least one request or response proof").
- **Options offered:** (a) empty lists allowed, ascending deterministic-CBOR order of semantic path,
  duplicates rejected *(recommended)*; (b) non-empty, in disclosure order.
- **Decision:** (a), aligned with l.1049 at the final review: `proofs` is omitted when there are none;
  when present it holds at least one proof in total, and one side may be empty.

### G51 — Ordering and cursors of `list_grants` and `query_audit`
- **Kind:** GAP · **Specs:** CA §6 (limit default 100, range 1-1000), §9 (at most the 1000 most recent
  visible records); ordering, cursor lifetime and since/until inclusivity unspecified.
- **Options offered:** (a) grants by grant-id bytes; audit newest first by record sequence; cursors pin a
  snapshot and expire after 10 minutes (then `invalid-request`); since inclusive, until exclusive
  *(recommended)*; (b) ask the spec author. **Decision:** (a).

### G52 — Call audit records under a route-level decision
- **Kind:** GAP · **Specs:** CA §9 (a call record requires `decision_id` and a scope); RUNTIME §9 (calls
  are authorized by their route's decision).
- **Options offered:** (a) the decision_id and provider_access_scope of the decision that established or
  last renewed the route *(recommended)*; (b) ask the spec author. **Decision:** (a).

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

### G82 — Default authority of the logosctl consumer on the daemon
- **Kind:** FREE · **Specs:** CA §5, §6, §10 l.1108-1110 (ordinary consumers MUST NOT gain direct
  authority to call `evaluate` merely because of other rights); RUNTIME §9 (every RC method needs an
  explicit allow).
- **Options offered:** (a) everything, through a CA policy rule, narrowable in the daemon config
  *(recommended)*; (b) read-only by default.
- **Decision:** (a). Made explicit at the final review: the rule names the host-ambient permission scope
  (otherwise no payload module could start, RUNTIME l.2240) and `evaluate` (for `logosctl authz check`).

### G110 — The ambient permission's identifier and constraints
- **Kind:** FREE · **Specs:** CA §3.5 l.345 (a permission identifier must unambiguously identify its
  defining specification or profile; constraints follow its CDDL; the definition names its enforcer and
  revocation behaviour); PM §4 l.294-297 (`requested_permission` carries constraints).
- **Options offered:** (a) `logos-core-nim.host-ambient` *(recommended)*; (b) `host-ambient`.
- **Decision:** (a); constraints `lcn.host_ambient_constraints = {}`; enforced by Runtime + Loader
  (realize only if granted and set); revocation stops the module (G46).

### G115 — Exporting call evidence
- **Kind:** GAP · **Specs:** CA §9.1 l.988-990 (no query method or batch format; export only when policy
  requires), l.1072 (disclosure follows `query_audit` rules), l.1078 (the Runtime keeps containers).
- **Options offered:** (a) containers stay in the daemon's audit store; `logosctl audit evidence export`
  is an owner-only host action, documented; evidence and retain-root off by default, enabled by audit
  policy *(recommended)*; (b) nothing exported. **Decision:** (a).

### G140 — Contents of the default CA policy
- **Kind:** FREE · **Specs:** CA §3.1 (route decisions per provider and scope), §3.3 (execution decisions
  MUST cover every required permission scope); RUNTIME l.2240 (omitted permissions are denied).
- **Description:** Without rules, the routes between payload modules (delivery -> rln/libp2p,
  rln -> lez_rln) and every payload start would be denied.
- **Options offered:** (a) ship rules in the default policy: those specific routes by contract, the
  host-ambient permission scope for modules from packages signed by an accepted anchor, orchestrator
  lifecycle rights, PM -> `lcn.storage_fetch`, CLI forwarding + the G82 rule; everything else denied
  *(recommended)*; (b) default deny; RUN-A-NODE issues grants after install. **Decision:** (a).

### G149 — Call-evidence signing key
- **Kind:** FREE (the need is spec-forced) · **Specs:** CA §9.1 l.986 (every conforming Runtime MUST
  implement `logos.call-evidence.cose-sign1-ed25519`), l.1029-1033 (each kid maps to exactly one producer
  Runtime; the key MUST NOT be used for package signing or TLS); SECURITY §13.
- **Not offered as a question** (found at the final review; the shape follows from the spec):
  `logosctl init` generates a separate 0600 Ed25519 evidence key and kid mapped to logosd's runtime id;
  `trust evidence-keys ls|rotate`, applied at the next start.

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

### G29 — Shared artifacts, ordering violations and check precedence
- **Kind:** CONTRA · **Specs:** PM §4 l.341 (declarations "MAY reference the same schema or default
  artifact") vs §8 (an artifact assigned to more than one declaration is `invalid-package`); §4 l.363
  (ordering violations, no value named); no check precedence defined.
- **Options offered:** (a) the specific MAY wins — shared schema/default artifacts allowed, shared
  implementation artifacts rejected; ordering violations `invalid-package`; precedence limits >
  structure > signature > commitment > schema > platform > artifact hashes *(recommended)*; (b) reject
  all sharing; (c) ask the spec author. **Decision:** (a); provenance inserted after commitment (G113).

### G39 — Per-caller cursors without a caller identity
- **Kind:** GAP · **Specs:** PM §15 (cursors bound to "the authenticated caller", records filtered per
  caller); INTERFACE dispatch ABI (passes no caller to providers); no CA scope defines package-record
  visibility.
- **Options offered:** (a) cursors bound to the route/session by the host layer; anyone allowed the method
  sees all records; documented deviation *(recommended)*; (b) ask the spec author. **Decision:** (a).

### G40 — Paths longer than USTAR allows
- **Kind:** GAP · **Specs:** PM §7.1 (gzip USTAR; pax not mentioned); PM §4 (artifact paths up to 4096
  bytes).
- **Options offered:** (a) pax `path` records only, when needed *(recommended)*; (b) reject long paths.
- **Decision:** (b): over-limit paths make the package invalid; no pax headers.

### G41 — Multi-member gzip and directory entries
- **Kind:** GAP · **Specs:** PM §7.1 ("Directory modes MUST be 0755" implies but does not require
  directory entries; RFC 1952 multi-member streams not addressed).
- **Options offered:** (a) reject multi-member; writer emits 0755 directory entries, reader accepts
  either *(recommended)*; (b) accept multi-member, require directory entries. **Decision:** (a).

### G42 — Ed25519 verification strictness
- **Kind:** GAP · **Specs:** PM §4.3, CA §9.1 (RFC 8032; cofactored vs cofactorless and small-order or
  non-canonical points not pinned).
- **Options offered:** (a) libsodium semantics: cofactorless, reject non-canonical encodings and
  small-order A/R; small-order keys rejected when trust is loaded *(recommended)*; (b) RFC 8032 cofactored.
- **Decision:** (a). Implementation: G135.

### G43 — Equal identity and commitment from different sources
- **Kind:** GAP · **Specs:** PM §11, §15 (list order: name bytes, descending SemVer, deterministic-CBOR
  bytes of the source).
- **Options offered:** (a) record the first in list_packages order *(recommended)*; (b) first in catalog
  document order. **Decision:** (a).

### G44 — A candidate cannot be fetched during resolution
- **Kind:** GAP · **Specs:** PM §11 (resolution deterministic; outcome must not depend on local resource
  thresholds).
- **Options offered:** (a) abort with `package-unavailable` *(recommended)*; (b) skip the candidate.
- **Decision:** (a).

### G45 — `manifest.json` inside a package
- **Kind:** GAP · **Specs:** PM §3 (the JSON rendering is diagnostic and must not override), §7.1 (allowed
  at the archive root); no JSON mapping exists to check it against.
- **Options offered:** (a) path-checked, never read or trusted *(recommended)*; (b) reject packages that
  contain it. **Decision:** (a).

### G73 — LGX platform values and matching
- **Kind:** GAP · **Specs:** PM §7.1 l.1082 ("Platform profiles define the registered os, architecture,
  and abi values" — none exist), l.1083 (variant ids do not define compatibility), PM §3
  (`platform_constraint` is a closed map of three optional fields); BCP §5.2 (an undefined platform
  profile is deployment policy).
- **Options offered:** (a) os {linux, darwin, windows, android, ios}, architecture {x86_64, aarch64}, abi
  optional {gnu, musl, mingw, msvc}; exact byte match; case-insensitive path collisions on darwin/windows
  plus Windows reserved names; dev and release builds as separate packages *(recommended)*; (b) Rust target
  triples split into the three fields. **Decision:** (a).

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

### G90 — Catalog source of truth and format
- **Kind:** FREE · **Specs:** PM §6 (catalog entry `{identity, source}`, location data only), §4.2/§4.4
  (catalogs are untrusted discovery input; no signature required), §13; no catalog document or refresh is
  defined.
- **Options offered:** (a) the locator lives only in the daemon config; document = det-CBOR
  `{format, sequence: uint64, entries}`, unsigned; a lower sequence than the last seen is rejected
  *(recommended)*; (b) the same without the sequence. **Decision:** (a). Origin per D17.

### G91 — How the Package Manager reads package objects from storage
- **Kind:** FREE · **Specs:** PM §13; INTERFACE §1.3 (reserved prefixes), §1.4 (`_implements`).
- **Options offered:** (a) a small interface contract owned by logos-core-nim (`lcn.storage_fetch`),
  implemented by storage_module: chunked `read_object{object, offset, length ≤ 1 MiB}` plus size; grants
  bind to its stable root *(recommended)*; (b) the PM calls storage's own download methods.
- **Decision:** (a). Depends on G5.

### G93 — How a module reaches its non-binary artifacts and native libraries
- **Kind:** GAP · **Specs:** PM §10, §12 (the handoff carries only the implementation artifact); LOADER §3,
  §5; INTERFACE §2.6 (init input has only state_dir and configuration).
- **Options offered:** (a) self-contained module binaries, raised upstream *(recommended)*; (b) declared
  resource artifacts passed through a deployment-specific channel; (c) ask the spec author.
- **Decision:** (c). **Status:** OPEN. Our payload modules are built self-contained meanwhile, which needs
  no answer.

### G94 — Provenance-signing profile
- **Kind:** GAP · **Specs:** PM §4.5 l.611-615 (each provenance-signing profile must define its
  algorithms; none is defined); BCP §5.2.
- **Options offered:** (a) our own `logos-core-nim.provenance-signing.ed25519-dsse.v1`: Ed25519 keys in
  protected trust input, signer key id bound to builder ids *(recommended)*; (b) Sigstore keyless;
  (c) ask the spec author. **Decision:** (a), as deployment-profile material.

### G95 — Scope of the Nix package profile
- **Kind:** FREE · **Specs:** PM §7.3 (package-controlled Nix evaluation only inside a pre-verification
  isolation boundary, unless protected input supplies the exact realized output).
- **Options offered:** (a) pre-resolved store paths first, isolation boundary later (rows scheduled)
  *(recommended)*; (b) build the isolation boundary now. **Decision:** (a).

### G96 — Do release deployments select SLSA provenance?
- **Kind:** FREE · **Specs:** PM §4.5; BCP §5.3 (optional profile; selection explicit, fails closed).
- **Options offered:** (a) yes, once the org provenance key exists *(recommended)*; (b) opt-in only.
- **Decision:** (b): implemented and tested; no default deployment selects it.

### G113 — Error codes for provenance failures
- **Kind:** GAP · **Specs:** PM §4.5 vs §14 (closed error list without provenance codes).
- **Options offered:** (a) map onto existing codes — missing locator or failed retrieval
  `package-unavailable`; malformed DSSE/statement/JSON or wrong types `invalid-package`; no accepted
  signer-builder pair, subject mismatch, buildType/source failure `signature-verification-failed`;
  precedence … commitment > provenance > schema … *(recommended)*; (b) ask the spec author.
- **Decision:** (a).

### G114 — A Nix source while provenance is selected
- **Kind:** GAP · **Specs:** PM §4.5 l.582 (defines provenance for LGX sources only), l.680-689 (no
  weakening).
- **Options offered:** (a) reject as missing evidence (`package-unavailable`) *(recommended)*; (b) ask.
- **Decision:** (a).

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

### G150 — `catalog set` and `catalog refresh`
- **Kind:** FREE · **Specs:** PM §15 (no refresh or catalog-configuration method); the PM receives its
  protected inputs at start.
- **Not offered as a question** (implementation default from the final review): `catalog set` writes the
  daemon config and restarts the PM instance so it receives a fresh handoff; `catalog refresh` restarts
  the PM instance, which re-fetches.

---

## 10. logosctl, logosd and the session

These follow from D13 (loopback mTLS remote Runtime Control). The CLI process embeds its own small
Runtime, which connects to the daemon's Runtime as an enrolled remote Runtime.

### G78 — Authority inside the CLI's embedded Runtime
- **Kind:** FREE · **Specs:** RUNTIME §9 l.1490-1493 (internal policy allowed for local trusted
  deployments).
- **Options offered:** (a) internal protected policy; the CA module runs in the daemon only
  *(recommended)*; (b) the CA module in the CLI Runtime too. **Decision:** (a).

### G79 — Composition of the CLI Runtime
- **Kind:** FREE · **Specs:** BCP §5.1 l.249-250 (individual-spec conformance does not require the
  Loader); RUNTIME l.71 (a Runtime instance = engine + orchestration module), l.182 (deployment MUST bind
  the orchestration role to a local module instance), l.185 (the role needs no provider contract),
  l.1499.
- **Options offered:** (a) Loader + orchestrator + logosctl, claiming complete-system conformance
  *(recommended)*; (b) engine + logosctl only, claiming Runtime-only conformance.
- **Decision:** (b). Completed at the final review: the `logosctl` instance holds the orchestration role
  (no provider contract, no startup defaults, restart policy disabled).

### G80 — Concurrent logosctl invocations
- **Kind:** FREE · **Specs:** RUNTIME §9 (two live Runtimes cannot share one identity), §9.3 l.2318
  (runtime ids are UUIDv4), l.2361-2370 (per-Runtime trust revision state).
- **Options offered:** (a) an identity pool: `init` provisions N enrolled CLI identities (default 4), each
  with its own lock *(recommended)*; (b) one invocation at a time. **Decision:** (a); each slot keeps its
  own trust state and revisions.

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

### G84 — Which providers the daemon exports
- **Kind:** FREE · **Specs:** RUNTIME §9.3 l.2473 (listeners and exports disabled unless explicitly
  enabled; package installation, realization and registration MUST NOT enable them).
- **Options offered:** (a) PM + CA exported at `init`; payload modules exported on `module load`
  *(recommended)*; (b) every ready provider exported automatically. **Decision:** (a).
- **Refined at the final review:** CA at `init`, PM once it exists (milestone M7); storage_module's
  export comes from the daemon config's deployment input because it is started by an orchestration
  default; `module load` issues an explicit `set_provider_export`; `call` never exports silently.

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

### G86 — Session mTLS trust
- **Kind:** FREE · **Specs:** TRANSPORT §8.4, §8.4.1 (mutual TLS 1.3; enrollment provisioned explicitly,
  no trust on first use); RUNTIME §9.3 l.2318-2370.
- **Options offered:** (a) an Ed25519 session CA (10-year validity) whose key is kept 0600 for rotation;
  enrollments pin exact SPKIs *(recommended)*; (b) no CA, self-signed identities pinned by SPKI.
- **Decision:** (a); runtime ids are UUIDv4.

### G87 — When trust and enrollment changes apply
- **Kind:** FREE · **Specs:** RUNTIME §9.3 l.2333-2371 (revisions, revocation), TRANSPORT l.1061 (a
  revoked or conflicting enrollment closes connections).
- **Options offered:** (a) at the next daemon start; live-revocation rows claimed through the restart path
  *(recommended)*; (b) live. **Decision:** (a); `trust rotate` bumps the revision on the daemon and on
  every CLI slot.

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

### G99 — Host paths in method arguments
- **Kind:** FREE · **Specs:** CONFIG §6 l.197 (no implementation-specific configuration-file path at the
  configuration boundary); RUNTIME §12 l.3304 (co-located modules may exchange paths); D21.
- **Options offered:** (a) absolute paths allowed; relative paths are a domain error; never resolved
  against cwd *(recommended)*; (b) bytes only. **Decision:** (a).

### G100 — Methods that can exceed the 30 s call timeout
- **Kind:** FREE · **Specs:** G61.
- **Options offered:** (a) return `{session_id}` and finish with a `*_done_event`; all other methods have a
  module-side deadline and a typed `timed-out` outcome *(recommended)*; (b) synchronous with longer
  per-method timeouts. **Decision:** (a).

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
| G5 | LGX `storage` / `object` | GAP, **OPEN** | 9 |
| G6 | referencing common callables | GAP | 2 |
| G7 | verified-view field/tuple disclosure | GAP | 2 |
| G8 | choice-arm segment | GAP | 2 |
| G9 | choice selection plan literals | GAP | 2 |
| G10–G16 | cdCDDLe details and vector format | GAP / FREE | 2 |
| G17 | independent oracle | FREE | 2 |
| G151 | `.size` on a named target | GAP, **OPEN** | 2 |
| G152 | leaf-bodied declaration identity | GAP, **OPEN** | 2 |
| G18–G28, G60 | error codes | GAP / CONTRA | 4 |
| G29 | shared artifacts and precedence | CONTRA | 9 |
| G30–G37 | transport receiver behaviour | GAP | 5 |
| G38 | floats in opaque payloads | GAP | 3 |
| G39–G45 | Package Manager edge cases | GAP | 9 |
| G46–G52 | Capability Authority | GAP | 7 |
| G48 | engine-originated calls | GAP | 6 |
| G49 | `publish_events` | GAP, **OPEN** | 7 |
| G53–G57 | names, list_modules, selection, Loader failure | GAP / spec-resolved | 6 |
| G58 | socket layout | CONTRA | 5 |
| G59 | nesting depth | GAP | 3 |
| G61 | timeouts | FREE | 6 |
| G62–G72 | C mapping and generator | GAP / CONTRA | 3 |
| G73–G75 | platforms, catalog policy, bounds | GAP / FREE | 9 |
| G76 | host configuration formats | FREE | 10 |
| G77 | thread model | FREE | 6 |
| G78–G89 | CLI runtime, session, binaries, output | FREE / GAP | 10 |
| G81, G82 | remote consumers; operator rule | GAP / FREE | 7 |
| G90, G91 | catalog format; PM storage fetch | FREE | 9 |
| G92 | storage pin vs installed package | GAP (revised) | 6 |
| G93 | module artifacts and native deps | GAP, **OPEN** | 9 |
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
| I9 | IMPL | One CBOR codec | INTERFACE §4.4, cdCDDLe §9 and RFC 8949 §4.2.1 impose the same byte rules at `f4f83471`, so `src/logos_core/cbor` is one encoder and one strict decoder. What values a layer allows (no floats in contracts, cdCDDLe node shapes) is checked by that layer. | 2026-11-09 |
| I10 | IMPL | CBOR decoder errors | Four classes: `malformed` (not one well-formed item over the whole input, trailing bytes included), `non-deterministic`, `invalid-utf8` (INTERFACE §4.5 maps it to schema-mismatch) and `too-deep` (G59: every container counts, empty ones and tags included; cap 1024). Well-formedness is checked over the whole input before determinism. | 2026-11-09 |
| I11 | IMPL | Opaque text | `DecodeOptions.allowInvalidUtf8` keeps a text string that is not UTF-8 (marked `validUtf8 = false`, never returned by `getText`), for the transport, which forwards payloads it does not validate. | 2026-11-09 |
| I12 | IMPL | cdCDDLe lexical rules (RFC 8610 Appendix B, G11) | Whitespace is space and line feed (CRLF allowed); a tab or a bare CR is a syntax error, and a comment must end with a line break. Text escapes are exactly RFC 8259 §7's, and a byte string may also escape `'`. `h''` and `b64''` ignore spaces, line breaks and comments; `b64''` takes the RFC 4648 §4 or §5 alphabet (not both in one literal), optional but complete padding, and zero trailing bits. A line break inside an unprefixed `'…'` byte string is unsupported. Hex, binary and `-0` integers normalize; integers beyond 64 bits and floats are unsupported. Parenthesized range bounds such as `(1)..(2)` are integer literals once §7.4 removes the parentheses. | 2026-11-09 |
| I13 | IMPL | cdCDDLe names and error order | Of the RFC 8610 prelude, only `uint`, `bool`, `tstr`, `bstr` (primitives) and `true`/`false` (Boolean literals) are in the subset; a reference to another prelude name is unsupported and redefining any prelude name is a resolution error. Errors are reported by stage: the first syntax or unsupported construct in source order, then resolution (definitions, then references), then canonical-rule violations. Nesting is capped at 256 type levels (unsupported beyond). The decoder rejects rule and reference names equal to a primitive (§6) and accepts any text as a member key (§8 asks only for a `tstr` literal). An array group is fixed-length or exactly `[* T]` (§5.1 l.159 read with §8 l.507-508). | 2026-11-09 |
| I14 | IMPL | cdCDDLe vectors (G16, G17) | `oracle/gen_cddl_vectors.py` writes `tests/vectors/cddl/vectors.cbor` (records exactly as §12). Expected models of source vectors are written by hand; decode vectors must agree with the independent checker `oracle/cdcddle.py`. The `oracle-selftest` flake check fails when the file is stale. | 2026-11-09 |
| I15 | IMPL | Layout input (HASH §4, §7.4; COMMITMENT §9.3) | `hash/layout` takes the §9.3 value tree (`commitment/value.nim`) plus two values the commitment layer derives from the list schema: the element schema identity (`list-payload` field 3, which an empty list cannot supply) and, for a homogeneous packable scalar list, its scalar kind. A list whose element schema is a reference, local or imported, is not packed, even when the reference resolves to a packable scalar: HASH §4 excludes reference lists and forbids packing across referenced-schema boundaries. Literal elements follow G119. | 2026-11-09 |
| I16 | IMPL | HASH verifier checks | `hash/check.nim` checks one payload at a time: exact key sets and types (HASH §7.3–§7.5), 32-byte digests, known node kinds and the kinds each parent may hold, labels, counts, chunk and byte ranges, and the one canonical branch tree (top-level branch size is the smallest 256^k leaving at most 256 branches). Errors are classed: malformed-cbor, non-canonical-cbor, malformed-hash-input, unknown profile/suite/model, domain-mismatch, digest-length, node-kind, layout-mismatch. Schema payloads (COMMITMENT §9.2) are the commitment layer's to check. A verifier policy that accepts another commitment-model revision is a `HashProfile` with that id. | 2026-11-09 |
| I17 | IMPL | HASH vectors (G17) | `oracle/hashlayout.py` is an independent layout written from the spec text; `oracle/gen_hash_vectors.py` writes `tests/vectors/hash/layout.cbor` (value trees in the §9.3 shape plus the I15 list annotations as keys 100 and 101, with their value roots). Trees too large to store (branches over branches, 1 MiB strings) are named by generator and size, and both sides expand them by the same rule. The oracle also reproduces HASH App A and B.1–B.3 from the pins. Every payload the Nim layout makes is checked against the mirrored HASH §7 CDDL and domain tables (`spec/mirrors/HSH/*.md`). | 2026-11-09 |
| I18 | IMPL | Schema-model construction (COMMITMENT §3.1, §5) | `commitment/construct.nim` builds one document's model from source text through cdCDDLe. A `SchemaContext` holds what a document may depend on: the pinned registry (`pins.nim`, the roots every common import carries), the pinned common document itself (`CommonSchemaDocument`, generated from its mirror; used only to follow references and checked at start-up to reproduce the registry), the supplied supporting schemas and the interface documents `_implements` names. Modules see common and supporting types; interfaces and supporting schemas see common types only. A dependency built under another commitment-model revision is rejected (no compatibility profile exists). INTERFACE §1.2's ascending `_implements` order and its unused-interface rule are enforced here; the rest of INTERFACE §1 waits for Tier 2. Errors are strings for now. | 2026-11-09 |
| I19 | IMPL | Choice selection plans (COMMITMENT §3.1) | `commitment/choice.nim`. An arm "proves" it rejects an outcome exactly for scalar values: bool, fixed-width integer ranges, and text (UTF-8, no NUL, `.size` byte length) or byte-string sizes; "any other value" counts what a primitive can hold (exact for bool, fixed-width integers and strings of at most one byte, unbounded otherwise). Scalar values are every CBOR item except arrays, maps and tags. References are followed with memoization keyed by (document, declaration, observation); one reached again for the same observation while it is being followed proves nothing (the arm stays a candidate). A plan node lists every outcome of its test, with no child where no arm remains; the same plans select arms when validating values (`validates`), which rebuilds them per call for now. | 2026-11-09 |
| I20 | IMPL | Value normalization (COMMITMENT §7, §8) | `commitment/normalize.nim`. A `Site` (document, nearest named declaration, path, node) names each schema position; its identity is `identityOf` (G152 at the empty path, a leaf hash at a leaf node, a structural root otherwise), cached per site within one normalization, as are choice selection plans. A map value has text keys only; each schema field is looked up by name and any other entry rejects the value; an absent optional field becomes an absent node carrying the field's identity. Local references are followed by `throughLocal` (G1), bounded so a reference cycle is an error; imported ones become reference-value nodes resolved through the schema set's import table. A list node gets its element identity and packability from `packKindOf` (G119, I15). Input is decoded Logos deterministic CBOR (`normalizeBytes` decodes first), so floats, tags and non-shortest forms never reach it; scalars are accepted by `primitiveAccepts`, shared with choice plans. `parseValueNode` and `parseValueRoot` read §9.3 objects strictly (exact key sets, ordering and coverage) without the I15 annotations: a parsed list takes its element identity from its first element and is never packed, so a verifier with a schema re-normalizes the plain value (`plainValue`) to recover them. Errors are strings for now. Single implementation: the oracle does not normalize. | 2026-11-09 |
| I21 | IMPL | Verified views (HASH §7.6, §8) | `hash/view.nim`. `viewOf` collects the complete payloads from the value root down the path and emits them disclosed-item first, value root last (App B.1/B.2's order); it refuses any path the verifier would reject. `verifyView` replays them from the value root down: each step must be in the domain of the record its parent selects, hash to that record's digest, repeat its schema identity and the current schema root in field 1 (the referenced root below a reference, G2), and every step must be used. Branches are entered by base-record index: the field's position in the schema map, the chunk, the tuple position or the byte chunk. A path crosses an imported reference without a segment and a choice only through its `choice-arm` segment (G8); a field or tuple position discloses the inner value (G7). An empty path discloses the `normalized-value-root` with no proof; any other path discloses a `value-node`, an absence marker or a string range. Seven error classes: `malformed-view`, `unknown-identifier`, `schema-mismatch`, `invalid-path`, `disclosed-mismatch`, `proof-mismatch`, `value-root-mismatch`. With a schema (G120) every node's identity is recomputed and the disclosed value re-normalized; without one only the physical proof is checked (enough for App B's synthetic identities), and a branched map cannot be descended because the field index comes from the schema. | 2026-11-09 |
