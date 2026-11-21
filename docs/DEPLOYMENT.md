# logosd deployment profile (BCP §5.4)

This page is the deployment document BOOTSTRAP-COMPOSITION-PROFILES (BCP) §5.4 asks for, for the
deployment that `logosd` is with its documented defaults: one Runtime per user session, composed and
started by logosd, on Linux and macOS. A host that embeds `liblogos_runtime` itself is a different
deployment and writes its own. On Windows logosd and logosctl are stubs that exit 2 (DECISIONS G107),
so there is no Windows deployment to document.

It indexes choices; it does not restate formats. Formats and procedures are in
[DAEMON.md](DAEMON.md) (the daemon's chapter), [HOST-CONFIG.md](HOST-CONFIG.md) (the host
configuration logosd derives), [AUTHORITY-POLICY.md](AUTHORITY-POLICY.md),
[PERMISSIONS.md](PERMISSIONS.md) and [CONFORMANCE.md](CONFORMANCE.md). Requirement-level claims are in
CONFORMANCE and `conformance/`.

## 0. This document

- **What logosd claims.** logosd follows BCP §5.1's bootstrap: it binds a Module Loader first and
  realizes every other instance through it (BCP l.292-296). It claims no complete Logos module system:
  it deploys no Package Manager (owner decision 10 (a); DECISIONS G310; CONFORMANCE, "Properties not
  claimed"). It still answers every §5.4 item, as a deployment that owes this document would. Its
  RUNTIME claim covers its Runtime instance, the engine with the reference orchestration module
  `lcn_orchestrator` as instance `orchestrator` (BCP l.286; CONFORMANCE, "Claims"; facts
  `runtime_claim`).
- **The item table** has one row per §5.4 item, split where one part is supported and another is not.
  *Verdict* says what this deployment does: `Supported` (it makes the choice and implements it), `None`
  (it has no subject for the item), `Not supported` (it offers nothing, and an operation that needs it
  fails, BCP l.408-410). *Changes in* names the tier expected to change a `None` or `Not supported`
  answer, `—` when none is expected. *Units* are the BCP requirement units the row answers. Rows 24
  and 25 answer the items added at logos-lips `6cac8335`; they keep the next free numbers and sit in
  BCP-line order, so a row's number is not its section's.
- **The label rule** (DECISIONS G309): a §5.4 unit is claimed by inspection when this document
  answers every part of its item truthfully, *none* included; its inspection reason lists the *none*
  and *not supported* parts and the tier that changes them. The Verdict does not decide a label.
- **Kept honest.** `spectrace deploydoc` (flake check `spec-deploydoc`) checks that every gated §5.4
  unit is in a row, that each row's units are claimed with their evidence, that a `None` or `Not
  supported` row's units carry that tier in their inspection reason, that every Section link resolves,
  and that the facts block parses. `tests/test_deployment.nim` (suite `bcp.deployment`) compares the
  facts block with the running code.

### The item table

| Item | BCP | Part | Verdict | Changes in | Answer | Section | Units |
|---|---|---|---|---|---|---|---|
| 0 | l.360-361 | this document, its two tables, every applicable choice indexed | Supported | — | this page; the second table sweeps the other specifications | [§0](#0-this-document) | BCP-0038, BCP-0039 |
| 1 | l.363 | Package Manager source kinds; provenance profiles | None | Tier 5 | no Package Manager is deployed; no source kind, no provenance profile | [§1](#1-package-manager) | BCP-0040 |
| 2 | l.364 | protected inputs: representations, provisioning, validation, replacement, revocation | Supported | — | owner-only session files, checked at start, replaced offline for the next start | [§2](#2-protected-inputs) | BCP-0074 |
| 3 | l.365 | authority-policy format, administration, permissions of bootstrap and system instances | Supported | — | `authority-policy.v1` in daemon-config; system rules S1–S5, and S6–S8 with the CLI module; host-ambient for system instances | [§3](#3-authority-policy) | BCP-0075 |
| 4a | l.366 | local transport profile | Supported | — | `logos.local.unix-stream` | [§4](#4-transport) | BCP-0041 |
| 4b | l.366 | remote transport profiles | None | Tier 5 | none enabled; no listener, no export, no enrollment | [§4](#4-transport) | BCP-0041 |
| 5a | l.367 | call-evidence signing trust | Supported | — | one evidence key per session, bound to the Runtime, rotated offline | [§5](#5-trust-inputs) | BCP-0042 |
| 5b | l.367 | package-signing trust | None | Tier 5 | the revisioned trust file exists and holds no anchors | [§5](#5-trust-inputs) | BCP-0042 |
| 5c | l.367 | package-provenance and source-evidence requirements | None | Tier 5 | none selected | [§5](#5-trust-inputs) | BCP-0042 |
| 5d | l.367 | remote Runtime enrollment | None | Tier 5 | no enrollment trust | [§5](#5-trust-inputs) | BCP-0042 |
| 6a | l.368 | Module Loader mappings; the `process` mechanism | Supported | — | `direct_static`, `direct_dynamic`, `hosted_dynamic` with placement `process`; the CLI module `lcn_call` hosted | [§6](#6-module-loader-mappings) | BCP-0043 |
| 6b | l.368 | `sandbox` and `container` mechanisms | Not supported | — | not advertised; a request for one is `unsupported-strategy`; outside Tier 5 (D16) | [§6](#6-module-loader-mappings) | BCP-0043 |
| 7 | l.369 | permission definitions, constraint mappings, enforcers | Supported | — | one definition, host-ambient, empty constraints, enforced by Runtime admission | [§7](#7-permission-definitions) | BCP-0044 |
| 8a | l.370 | isolation and process behaviour | Supported | — | separate address spaces for hosted modules, the CLI module included; one OS user, a process group per host | [§8](#8-isolation-and-the-data-path) | BCP-0045 |
| 8b | l.370 | filesystem, network, device, credential and resource controls | Not supported | — | none: a module has its OS user's access; outside Tier 5 (D16) | [§8](#8-isolation-and-the-data-path) | BCP-0045 |
| 9 | l.371 | directories, state, retention, cleanup, recovery, migration | Supported | — | the session tree (`run/lcn_call.sock` included); state kept after retirement; restart lock; `state_transfers` | [§9](#9-directories-and-state) | BCP-0046 |
| 10a | l.372 | accepted-declaration selection | Supported | — | daemon-config `modules` and `declarations`, one declaration per module name | [§10](#10-declaration-selection) | BCP-0076 |
| 10b | l.372 | exact package/version pinning | None | Tier 5 | no package-backed creation | [§10](#10-declaration-selection) | BCP-0076 |
| 11 | l.373 | attribute-source integration | Supported | — | the Runtime's registry, in process: instance id and module name | [§11](#11-the-attribute-source) | BCP-0077 |
| 24 | l.374 | Credential Store: credential, format and sealing profiles; backend durability and recovery; operation-record retention; protected delivery and activation | None | — | no Credential Store is deployed or claimed | [§25](#25-credential-store) | BCP-0101 |
| 12a | l.375 | bounds of the Runtime, Transport, Module Loader and schema processing | Supported | — | finite, listed with their scope and exhaustion behaviour; the CLI module's in DAEMON.md §7a | [§12](#12-resource-bounds) | BCP-0047 |
| 12b | l.375 | Package Manager bounds, dependency resolution | None | Tier 5 | no Package Manager | [§12](#12-resource-bounds) | BCP-0047 |
| 13 | l.376 | deadlines: start points, phases, effects, escalation, shared-process limits | Supported | — | five deadlines; a Module Host may be ended by force; a direct realization never | [§13](#13-deadlines) | BCP-0078 |
| 14 | l.377 | configuration-preserving upgrade; verified defaults | Supported | — | the operator carries configuration; defaults come from accepted declarations | [§14](#14-upgrade-and-verified-defaults) | BCP-0079 |
| 15 | l.378 | presentation profile | None | — | none selected (BCP l.346); the CLI writes to the launcher's terminal, which is not a presentation profile | [§15](#15-presentation) | BCP-0048 |
| 16a | l.380 | Package Manager installation, inventory, shared state | None | Tier 5 | no Package Manager | [§1](#1-package-manager) | BCP-0080 |
| 16b | l.380 | operating-system integration material | Supported | — | a systemd user unit and a launchd agent, owner-installed | [§16](#16-facilities-that-cannot-be-supplied) | BCP-0080 |
| 17 | l.380-382 | a facility or constraint that cannot be supplied fails | Supported | — | the dependent realization fails; nothing falls back | [§16](#16-facilities-that-cannot-be-supplied) | BCP-0081 |
| 25 | l.383 | each finite admission pool shared by consumers or providers: whether a per-consumer or per-provider limit applies | Supported | — | each pool with its total and its per-consumer or per-provider limit, or none | [§12](#admission-pools) | BCP-0102 |
| 18a | l.385 | the administrative path and its authentication | Supported | — | offline edits of owner-only files; the OS authenticates | [§17](#17-approval-and-activation) | BCP-0082 |
| 18b | l.385-386 | approval presentation | None | — | no user-facing approval | [§17](#17-approval-and-activation) | BCP-0083 |
| 18c | l.387 | requester provenance kept apart | Supported | — | peer uid and pid logged, never the consumer, on both sockets | [§17](#17-approval-and-activation) | BCP-0084 |
| 19 | l.389-395 | activation: mechanism, admission, selection, presentation handoff, failure | Supported | — | the `logosctl` socket and its instance; the `lcn_call` socket and its instance, started through the first | [§17](#17-approval-and-activation) | BCP-0085, BCP-0086, BCP-0087, BCP-0088, BCP-0089 |
| 20 | l.397 | deployment representations keep Core meaning | Supported | — | the ctl wire, the CLI wire and the CLI carry Core values unchanged | [§18](#18-deployment-representations) | BCP-0090 |
| 21 | l.399-401 | state at rest, principals, secrets, backup, restore and rollback, retention and deletion | Supported | — | file modes only; no secret store; `state purge` is the deletion | [§19](#19-state-at-rest) | BCP-0091, BCP-0092 |
| 22 | l.403-406 | non-production mechanisms: development trust anchors, relaxed debugging entitlements, Transport test hooks, unknown-artifact analysis | Supported | — | none of the four in a deployed logosd; what the trust file's development switch gates is announced everywhere | [§20](#20-non-production) | BCP-0103, BCP-0094, BCP-0095, BCP-0096 |
| 23 | l.408-410 | fail closed, no weaker mechanism | Supported | — | every refusal below; no fallback anywhere | [§21](#21-failing-closed) | BCP-0049, BCP-0050 |

### Choices the other specifications assign to deployment

BCP l.360 asks for *every* applicable choice. This table is the result of a search of the pinned
specifications (logos-lips `6cac8335`) for `MUST document`, `MUST be documented`, `documentation MUST`,
`MUST identify`, `MUST state`, `MUST describe` and `documented`, read hit by hit; the hits that assign
a choice to a deployment or an implementation are rows. R is RUNTIME, T TRANSPORT, CA CAPABILITY
AUTHORITY, IF INTERFACE, CFG CONFIGURATION, PM PACKAGE MANAGER. At `6cac8335` the search was run again
over the lines the revision changed: it added IF l.1473 and PM l.1727, the Credential Store's duties
(below) and BCP l.374 and l.383 (rows 24 and 25).

| Spec | Line | Duty | Answer | Units |
|---|---|---|---|---|
| R | l.178, l.182 | bind the orchestration role to a local instance and identify it | instance `orchestrator`, module `lcn_orchestrator`, `direct_static` in logosd ([DAEMON.md](DAEMON.md) §4) | RUN-0023, RUN-0784 |
| R | l.1317 | verify retained signed package declarations of a static module | none retained: logosd registers two native bindings and keeps no package declaration ([§10](#10-declaration-selection)) | RUN-0844 |
| R | l.2946 | the time assurance authority and certificate policies need | the host's wall clock, each validity also held on a monotonic clock, no skew tolerance; no certificate policy ([HOST-CONFIG.md](HOST-CONFIG.md), "Under `capability-authority`") | RUN-0940 |
| R | l.3252, l.3255 | snapshot capacity, retention, reclamation and overload | [HOST-CONFIG.md](HOST-CONFIG.md), "Observation", Limits | RUN-0965, RUN-0967 |
| R | l.3632 | resumption after a restart apart from retries after a failure | [§9](#9-directories-and-state), recovery; [HOST-CONFIG.md](HOST-CONFIG.md), "The reference orchestration module" | RUN-1064 |
| R | l.3900 | each configuration format and how protected inputs are supplied | `logos-core-nim.app-config.v1` ([HOST-CONFIG.md](HOST-CONFIG.md)); logosd derives it from `daemon-config.v1` ([DAEMON.md](DAEMON.md) §3) | RUN-0740 |
| IF | l.853 | code-generation tooling's identifier-length and resource limits | lcn-gen's usage text, `Limits`, for both directions (`lcn-gen cddl` included) | IFC-0624 |
| IF | l.1473 | the bound on a subscription's pending deliveries at which a binding ends it | a direct route's subscription: `eventQueue`, 1,024 deliveries or 16 MiB, then it ends with `LOGOS_ERR_MODULE` ([HOST-CONFIG.md](HOST-CONFIG.md), "Runtime limits"; DECISIONS G176); a Runtime Control subscription: 256 queued events ("Runtime Control subscriptions", Limits; G178, G225) | IFC-0964 |
| IF | l.3104 | a documented, finite, configurable payload depth | `max_payload_depth`, 128 to 1024, default 1024 ([§12](#12-resource-bounds)) | IFC-0923, IFC-0924, IFC-0925 |
| CA | l.104-106 | a protected attribute-source integration | [§11](#11-the-attribute-source) | CAP-0274, CAP-0275, CAP-0276, CAP-0277, CAP-0278 |
| CA | l.404-405 | each permission's enforcement component and behaviour | [§7](#7-permission-definitions) | CAP-0083 |
| CA | l.406 | the consent principal of a profile claiming per-module device restrictions | no such claim ([PERMISSIONS.md](PERMISSIONS.md)) | CAP-0292, CAP-0293 |
| CA | l.752 | historical retention when the Authority contract is replaced | a different contract refuses to start ([AUTHORITY-POLICY.md](AUTHORITY-POLICY.md), "State") | CAP-0339 |
| CA | l.1207-1208 | the point at which an evaluation audit record counts as retained | at its append in memory under the backlog bound, with no audit write failing ([AUTHORITY-POLICY.md](AUTHORITY-POLICY.md), "Audit retention") | CAP-0439 |
| CA | l.1364 | evidence export: selection, authorization, limits, delivery | [DAEMON.md](DAEMON.md) §9, "Export" and "Limits" | CAP-0415 |
| T | l.803-804 | event output overflow actions, waits, closure | [CONFORMANCE.md](CONFORMANCE.md), "Event output overflow" | TRN-0309, TRN-0310 |
| T | l.1329-1331 | finite Transport limits, their scope and exhaustion | [CONFORMANCE.md](CONFORMANCE.md), "Transport limits" | TRN-0378, TRN-0379, TRN-0380 |
| CFG | l.134 | whether package defaults are accepted; a verified default for reset | [§14](#14-upgrade-and-verified-defaults) | CFG-0129 |
| PM | l.1252 | the maximum value supported for each resolver limit | [CONFORMANCE.md](CONFORMANCE.md), "Resolver limits" | PKG-0597 |
| CFG | l.266 | the configuration-preserving upgrade workflow | [§14](#14-upgrade-and-verified-defaults) | CFG-0134, CFG-0135 |
| PM | l.408 | whether continued execution depends on current package-signing trust | no ([§1](#1-package-manager)) | PKG-0422 |

The Package Manager's own documentation duties (PM l.834 catalogs, l.857 retrieval, l.931
installation scope, l.1183 resource access, l.1727 the storage failure model, l.1731 retention) belong
to a Package Manager, which this deployment does not have; they come with it in Tier 5. The Credential
Store's (CS l.319, l.370, l.476) belong to a Credential Store, which it does not have either (§25).
The other hits of the search are duties of a specification, a record or a message (for example HASH
l.35, R l.3265, T l.564), not choices of a deployment.

## 1. Package Manager

Items 1, 5b, 5c, 10b, 12b and 16a.

- **None is deployed.** `lcn-pkg`, the LGX parser and the dependency resolver are tools (DECISIONS
  I49, I69): nothing in logosd installs, inventories or selects a package. There is no source kind, no
  provenance profile, no installation scope, no inventory and no shared package state. A module comes
  from daemon-config as an artifact path with its digest (§10); no package-backed creation exists.
- **Does continued execution depend on current package-signing trust acceptance** (PM l.408)? **No.**
  1. The trust file holds no package-signing anchors: only its revision and the development switch
     ([DAEMON.md](DAEMON.md) §6; DECISIONS G299).
  2. No instance has a signer or package fact, direct or hosted: the Runtime's registry, the only
     source of the facts the authority reads, records an instance's id and module name and no
     selection (§11). A policy rule naming a signer or package matches nothing, and no execution
     decision depends on one.
  3. A change of the trust file takes effect only at the next start ([DAEMON.md](DAEMON.md) §6), so
     nothing running is affected by one.
  4. Tier 5 (the Package Manager, its anchors and package-backed selection) is expected to change
     this answer (DECISIONS G137, amended 2026-11-16).

## 2. Protected inputs

Item 2. Each is a file of the session, owned by its user, mode 0600 in 0700 directories
([DAEMON.md](DAEMON.md) §2); a session others can access is refused.

| Input | Representation | Written by | Validated | Replaced |
|---|---|---|---|---|
| daemon-config, the authority policy in it, module configuration values, `state_transfers` | one deterministic-CBOR `lcn.daemon_config` ([DAEMON.md](DAEMON.md) §3) | `logosctl init`, `daemon config set` | the five checks of DAEMON.md §3, at `set` and at every start | at the next start |
| the trust file and its mark | `lcn.trust_file`, `lcn.trust_mark` (§6 there) | `init`, `trust development`, `trust reestablish` | revision continuity at start: rollback and changed contents refused | at the next start |
| the evidence key and its binding | `lcn.ev_key_binding` (§6 there) | `init`, `trust evidence-keys rotate` | the binding names this Runtime (§3 check 4) | at the next start |

**Revocation.** A grant's end, its expiry and a policy decision that no longer allows an execution or
route take effect at once, while logosd runs (CA §8; [HOST-CONFIG.md](HOST-CONFIG.md), "Under
`capability-authority`", Authority over time). A withdrawn development switch, a rotated evidence key
and a changed policy take effect at the next start, since every input is read once.

## 3. Authority policy

Item 3. The format is `logos-core-nim.authority-policy.v1` ([AUTHORITY-POLICY.md](AUTHORITY-POLICY.md)).
logosd merges the operator's rules with its system rules S1–S5, and S6–S8 when it composes the CLI
module `lcn_call`, which are derived and not configurable ([DAEMON.md](DAEMON.md) §5). Administration is
the offline path of §17. The explicit permissions of the bootstrap and system instances: host-ambient for
`orchestrator`, `logosctl`, `authority` and `lcn_call`, written by logosd; the Module Loader holds it by construction ([PERMISSIONS.md](PERMISSIONS.md), "What BCP asks to
be documented"). `allow-all` is accepted only with the development switch on (§20).

## 4. Transport

Items 4a and 4b.

- **Local:** `logos.local.unix-stream`, the only local profile, with endpoints under `<session>/run/ep/`
  ([CONFORMANCE.md](CONFORMANCE.md), "Unix-stream endpoints and peer checks").
- **Remote:** none enabled. logosd has no remote transport, no listener, no provider export and no
  enrollment. The remote Runtime Control methods answer after authorization: the two lists an empty
  page, `set_provider_export` INVALID_PARAMS, enabling a listener MODULE_ERROR (DECISIONS G298;
  [DAEMON.md](DAEMON.md) §10). Expected to change in Tier 5.

## 5. Trust inputs

Items 5a–5d.

- **Call-evidence signing** (5a): one evidence key per session, made by `logosctl init`, bound to the
  Runtime id and rotated offline (DECISIONS G149; [DAEMON.md](DAEMON.md) §9). A rotation applies at
  the next start; the retired key keeps its binding and loses its secret half.
- **Package signing** (5b): the carrier exists, `<session>/trust.cbor` with its revision, its
  continuity mark and the development switch (DECISIONS G299). It holds no anchors. Tier 5 adds them.
- **Package provenance and source evidence** (5c): none selected. Tier 5.
- **Remote Runtime enrollment** (5d): none. Tier 5.

Each trust input has its own file and purpose (SEC l.521).

## 6. Module Loader mappings

Items 6a and 6b. The Loader is built in, `direct_static`, bound first, never configured
([HOST-CONFIG.md](HOST-CONFIG.md), "The Module Loader").

| Strategy | Where the module runs | Selected by |
|---|---|---|
| `direct_static` | in logosd | logosd's own two bindings, `lcn_orchestrator` and `logosctl`, and the library's `logos_capability_authority`; an operator `direct_static` module is refused |
| `direct_dynamic` | in logosd: a verified copy of the artifact under `work/`, mapped | a `modules` or `declarations` entry |
| `hosted_dynamic`, placement `process` | in a `logos-module-host` process of its own, under logosd's user | the same, with `runtime.module_host` set (logosd's default sets it); the CLI module `lcn_call`, from the library installed with logosd or `cli.artifact` ([DAEMON.md](DAEMON.md) §7a) |

- `sandbox` and `container` are not advertised. A descriptor naming one is refused with
  `unsupported-strategy` before any artifact is read (L l.377); this Runtime never selects another
  strategy in its place. Outside Tier 5: DECISIONS D16 leaves sandbox and container placements out,
  and the Tier 5 plan keeps them out (its area K).
- `force_release` is never advertised.
- The strategy is required in every entry: logosd chooses none. `logosctl init --print-template`
  writes `hosted_dynamic` with placement `process` for operator modules.

## 7. Permission definitions

Item 7. The profile `logos-core-nim.permission-profile.v1` is always selected. It defines one
permission, `logos-core-nim.host-ambient` (DECISIONS G110, G279, G283):

| Permission | Constraints | Facility classes | Enforced by | When it cannot be enforced | When revoked |
|---|---|---|---|---|---|
| `logos-core-nim.host-ambient` | the empty map | all seven (CA l.396-402) | Runtime admission | the start or recovery is refused | the Runtime stops the execution form; intent is kept |

An unknown permission and one that cannot be enforced are refused (CAP-0074, CAP-0084). No per-class or
per-resource limit can be expressed. Details: [PERMISSIONS.md](PERMISSIONS.md).

## 8. Isolation and the data path

Items 8a and 8b.

**Isolation (8a).** A `direct_*` module shares logosd's address space. A `hosted_dynamic` module runs in
a separate process: its own address space, a process group of its own that is killed after every end
of the host, an environment of only `module_host_env`, and the descriptors listed in
[HOST-CONFIG.md](HOST-CONFIG.md), "Module Hosts". Every process runs as logosd's user. The CLI module
`lcn_call` is such a module; the terminal descriptors a launcher hands it are its own for the command.

**Not supported (8b).** Placement `process` is a separate address space, **not a sandbox** (DECISIONS
G265): a hosted module has the filesystem, network, device, process and credential access of logosd's
user, and no operating-system resource control is applied. A process the module moves out of its
group or session outlives the host. Processes of the same user can reach each other's sockets and
files (CONFORMANCE, "Properties not claimed"). Outside Tier 5: DECISIONS D16 leaves sandbox and container
placements and their controls out, and so does the Tier 5 plan (its area K).

**The data path.**

- A module placed `direct_dynamic` runs inside logosd, and so do its payloads; `init` writes
  `hosted_dynamic` for operator modules, and `strategy` stays required.
- A hosted consumer of a provider in logosd's process (a `direct_dynamic` module, or the Capability
  Authority) is served at an endpoint in logosd (DECISIONS G257).
- Otherwise no method payload and no event data goes through logosd or `logosctl`: hosted consumers
  and providers exchange payloads over the route's socket; the Runtime decides the Hello, each call
  and delivery from names, roots and connection numbers.
- **Calls from the command line** (`logosctl call`, `describe`) take the same path: provider host ⇄
  `lcn_call`'s host ⇄ the terminal. `lcn_call` is the consumer and writes the result to the descriptors
  the launcher passed it; the launcher sees only an exit status, and logosd only the route's control
  ([DAEMON.md](DAEMON.md) §7a). Argument values pass through the launcher because the user typed them.
- A state transfer by `copy` passes the module's state through logosd's Runtime thread in one 64 KiB
  buffer, zeroed after use; `move` reads nothing.
- What does cross logosd (control path, not payloads): Runtime Control requests, responses and events,
  module configuration values (stored by the Runtime, handed to a host at init and apply), a provider's
  call surface, call-record roots, and reported failure text in diagnostics (attributed, §23). A Module
  Host's stdout and stderr are inherited descriptors and do not pass through logosd's memory.
- **The trust in the host program** (DECISIONS G273, G274): a hosted provider's host checks and
  commits its calls and reports its call records' roots; what it sends a consumer and those roots rest
  on the host program. CONFORMANCE, "Properties not claimed", says so.

## 9. Directories and state

Item 9.

- **Directories.** The session tree of [DAEMON.md](DAEMON.md) §2: every directory 0700, every file
  and socket 0600, owned by logosd's user. The one exception is the Loader's copy of a dynamic
  artifact, `work/lcn-artifacts-…/`, made 0500 before it is hashed and mapped, so that the bytes
  mapped are the bytes verified. `run/` is recreated at each start; `work/` is never emptied.
- **State realization.** An instance with persistent state gets `state/modules/<assignment>`, keyed by
  its state assignment, not its instance id (DECISIONS G143).
- **Retention.** Retiring an instance keeps its state directory ("retired; its state directory is
  kept"). Nothing removes it but `logosctl state purge` (§19).
- **Cleanup.** At start the Runtime removes the `+transfer-…` and `+purge-…` names an interrupted
  transfer or purge left. Restart-lock files under `work/hosts/` hold no data and stay.
- **Recovery.** After a run that did not complete shutdown, each stored instance that was `loaded`,
  `ready` or `stopping` is restored as `error` (`host-terminated`; RUNTIME l.3634); bringing it back is a
  resumption, not a retry, and is not charged to the restart policy (DECISIONS G193, G289; RUNTIME
  l.3638). After a completed shutdown that left an instance `stopping` past the shutdown grace, a direct
  one completes its stop at the next start and a hosted one completes it once its restart lock is free
  (DECISIONS G357). A hosted instance whose Module Host of the previous
  run may still be alive keeps `realization` `unknown`, and its start and recovery answer NOT_READY,
  until its restart lock can be taken (DECISIONS G275). After a Module Loader loss logosd exits 4 and a
  service manager starts it again ([DAEMON.md](DAEMON.md) §15).
- **Migration.** `state_transfers` gives a replacement instance another's state at the next start,
  by `move` (a rename) or `copy` ([DAEMON.md](DAEMON.md) §11; DECISIONS G92, G143, I96). No socket
  command moves state.

## 10. Declaration selection

Items 10a and 10b (DECISIONS G55, G311).

- **10a.** The accepted declarations are daemon-config's `modules` (the configured instances) and
  `declarations` (what `logosctl module create` may instantiate): one declaration per module name,
  protected input. `create_module` for a name with no declaration is refused as a denied request; a
  created instance keeps the declaration it was created from. logosd links two bindings and keeps no
  signed package declaration for them (R l.1317).
- **10b.** No exact package/version pinning: nothing creates a package-backed module. Tier 5.

## 11. The attribute source

Item 11 (CA l.104-106; DECISIONS G47).

- **Source.** The Runtime's own registry, read by the in-process Capability Authority over a protected
  in-process path; not Runtime Control, not `evaluate`, not deployment input.
- **Facts and binding.** For the consumer and the target: the instance id and the module name. No
  instance has a signer or package fact, direct or hosted; a rule naming one matches nothing.
- **Freshness.** Both facts are fixed for an instance's life; the only transition is retirement.
- **Failure.** A fact that is missing is an evaluation failure, never an allow or an invented deny.
- **Disclosure.** The facts go to the authority only.

## 12. Resource bounds

Items 12a, 12b and 25. Every bound is finite and listed with its scope and what happens when it is
reached:

- the Runtime: [HOST-CONFIG.md](HOST-CONFIG.md), "Runtime limits" (instances, workers, store snapshot,
  asynchronous calls, Module Hosts, state transfers, payload depth `max_payload_depth` 128 to 1024,
  default 1024, DECISIONS G241);
- the Transport: [CONFORMANCE.md](CONFORMANCE.md), "Transport limits";
- the Module Loader: one instance with one thread; its calls run on the lifecycle workers (same table);
- schema processing: the INTERFACE §5.3 limits (`MaxSchemaNodes` and the others in `iface/accept.nim`);
- the daemon: [DAEMON.md](DAEMON.md) §7 "Limits" and §9 "Limits";
- the Package Manager's resolver: [CONFORMANCE.md](CONFORMANCE.md), "Resolver limits" (the protected
  policy supplies the values; these are their maxima).

### Admission pools

Item 25 (BCP l.383). A pool counts here when it is finite, shared by more than one consumer or
provider, and its exhaustion refuses or ends a request (DECISIONS G309). SECURITY l.394 names seven
examples; each is answered first, a "no pool" included. No pool has a per-provider limit. The facts
block lists each pool's total and per-consumer limit (`admission_pools`; the audit storage's under
`authority_audit`), and a test compares them with the code.

| Pool | Total | Per consumer or provider | When it is exhausted |
|---|---|---|---|
| prepared calls: asynchronous calls prepared and not released (`MaxAsyncCalls`) | 4,096 per Runtime | none | preparing one more is `LOGOS_ERR_MODULE` |
| native borrows | no pool: a borrow lasts for the one call or callback that lends it | — | — |
| sessions: Transport connections | per I/O loop: 1,024 accepted, at most 64 of them before their Hello completes; 1,024 outbound | none; each connection has its own limits | below, Transport |
| routes | no pool: routes are not counted; a transported route's session takes the Transport totals | — | — |
| route tickets | no pool: tickets are not counted; each expires within 60 s of its issue (`MaxTicketLifetime`), sooner if its route's authorization ends | — | — |
| grants | 16,384 kept | none | the oldest revoked or expired grant goes; with all active, issuance is `authority-unavailable` |
| audit storage: unwritten evaluation records | 4,096 | none | evaluations fail closed, `authority-unavailable` ([AUTHORITY-POLICY.md](AUTHORITY-POLICY.md), "Audit retention") |
| audit storage: retained records (`audit.records`) | 65,536 by default | none | no pool: the oldest written records go and nothing is refused, so one consumer's evaluations can push out others' records ([AUTHORITY-POLICY.md](AUTHORITY-POLICY.md), "State") |
| module instances, retained ones included (`MaxInstances`) | 1,024 | none | `create_module` is `LOGOS_ERR_MODULE` |
| call workers for asynchronous calls | 64, then 64 more | none | with all 128 busy for 1 s, the oldest call not started completes `LOGOS_ERR_MODULE` |
| evaluations waiting for an evaluation worker (`EvalQueue`) | 256, behind 4 workers | none | one more is an evaluation failure at once |
| observation snapshots | 256 and 64 MiB | 8 and 8 MiB per consumer | past the total, `LOGOS_ERR_MODULE`; past a consumer's own, its oldest snapshot goes |
| `observe_end` registrations | 16,384 | 1,024 per consumer | `LOGOS_ERR_MODULE` |
| Runtime Control subscriptions | 1,024 | 32 per module instance | `subscribe` is `LOGOS_ERR_MODULE` |
| the Runtime store's snapshot (`MaxStoreBytes`) | 64 MiB | none | a change that would pass it fails |
| the authority's queued module requests | 1,024 | none | `authority-unavailable` |
| the authority's watches | 64 | 8 per consumer | `watch_changes` is `authority-unavailable` |
| Transport, per I/O loop (the Runtime's, and each hosted provider's Module Host) | the connections above; 16,384 outbound calls, 16,384 callee subscriptions, 65,536 subscription ids; 32 MiB of frames before a Hello completes, 256 MiB held after, 256 MiB of committed output, 64 MiB of output not yet committed | none; each connection has its own limits | [CONFORMANCE.md](CONFORMANCE.md), "Transport limits" |
| the reference orchestrator's open restart episodes | 4,096 | none (one per instance) | no new retry is made, with a diagnostic ([HOST-CONFIG.md](HOST-CONFIG.md), "The reference orchestration module", Limits) |

- **Not pools:** they queue, evict or drop, and refuse nothing: the lifecycle workers (G242), the
  Module Host proxy workers, the Transport's execution slots, the ended route records kept per
  consumer, the call records and diagnostics kept in memory, and the call-evidence store's queue (off
  by default). A subscription's own event queue is not shared.
- **The `logosctl` socket's workers** (`ctl.workers`, [DAEMON.md](DAEMON.md) §7) serve shell clients,
  which reach the Runtime as one consumer, the `logosctl` instance.
- **No Package Manager** is deployed, so it has no pool.

## 13. Deadlines

Item 13. Five deadlines, in milliseconds, each 1 to 3,600,000 where configurable:

| Deadline | Default | Set by | Starts | Covers | When it passes |
|---|---|---|---|---|---|
| The Module Loader's startup | 120000 | fixed | when `start` begins | binding, `_MODULE_init`, readiness, the contract and capability checks | the Loader is `error` `startup-timeout`; logosd exits 2 |
| Startup | 120000 | `runtime.startup_deadline_ms` | when the execution attempt is accepted, after its ordering prerequisites | binding, `_MODULE_init`, readiness | `error` `startup-timeout` |
| Application | 120000 | `runtime.apply_deadline_ms` | when `apply_configuration` is accepted | until the module answers | the outcome is unknown: `error` `configuration-indeterminate`; an instance already `stopping` stays `stopping` (CONFIG l.328) |
| Stop (drain) | 10000 | `runtime.stop_deadline_ms` | when the stop begins | the stop, through the module's `_MODULE_destroy` and its release | `stopping` with `cleanup-timeout` until the cleanup ends, then `unloaded` (RUNTIME l.575-576; DECISIONS G180) |
| Shutdown grace (cleanup) | 10000 | `runtime.shutdown_grace_ms` | when shutdown begins | in-flight work and every release | an instance still `stopping` reports `cleanup-timeout`; shutdown completes with an error; logosd exits 3 |

- **Escalation.** A Module Host still running past its startup, stop or shutdown deadline is ended by
  force: SIGKILL to its process group (DECISIONS G269). Past the application deadline, a host whose hook
  has not returned one stop deadline later is ended the same way. Past the startup or application
  deadline the state stays `error` with the deadline's classification; past the stop or shutdown
  deadline it stays `stopping` with `cleanup-timeout`, and the confirmed end completes the stop
  (`unloaded`). `realization` is `unknown` until the end is confirmed.
- **Shared-process limitation.** A direct realization is never ended by force: its code shares
  logosd's process, so past a deadline the failure is recorded and its code may run on (DECISIONS G61,
  G173). A shutdown that leaves one `stopping` says so in its result ("forced cleanup of … is requested:
  the host process must end"). At shutdown logosd retries the Runtime's destruction for `shutdown_grace_ms` plus 5 s; ending
  the process is the remaining escalation, which a service manager's stop timeout (90 s) performs.
- **Loader loss** ends logosd with exit 4 ([DAEMON.md](DAEMON.md) §15).

## 14. Upgrade and verified defaults

Item 14 (CFG l.134, l.266).

- **Configuration-preserving upgrade** is the operator's: read the old instance's configuration with
  `logosctl config get`, turn it into the replacement's `provisioned_configuration` under the new
  schema, and name the replacement in daemon-config ([DAEMON.md](DAEMON.md) §11, step 1). The state
  transfer moves state only; configuration and authority never follow a module name.
- **Package defaults are accepted.** A declaration's `default_value` (in daemon-config's `modules` or
  `declarations`) is staged for a new instance that has no provisioned value, after the Runtime
  checked it as a complete value of the accepted schema ([HOST-CONFIG.md](HOST-CONFIG.md), "Module
  configuration"; DECISIONS I87). With no Package Manager, "the package's default" is the
  declaration's own.
- **A verified complete default for a reset.** No Runtime Control method returns the default. An
  application offering a reset takes it from the same declaration, checks its `schema_commitment`
  against the one `get_configuration_schema` reports for the instance, and stages it with
  `update_configuration`, which validates it as a complete value before anything changes
  ([HOST-CONFIG.md](HOST-CONFIG.md), "Package defaults and reset").

## 15. Presentation

Item 15. No presentation profile is selected and none is assigned (BCP l.346). logosctl is a terminal
command, not a presentation profile; neither is the CLI module, which writes a command's result to the
terminal descriptors its launcher handed it ([DAEMON.md](DAEMON.md) §7a).

## 16. Facilities that cannot be supplied

Items 16b and 17.

- **Operating-system integration material** (16b): `contrib/systemd/logosd.service` (a user unit) and
  `contrib/launchd/org.logos-core.logosd.plist` (a user agent), installed by the owner, never as root
  (DECISIONS G146; [DAEMON.md](DAEMON.md) §13). Nothing installs or changes them at run time.
- **A facility or constraint that cannot be supplied** (17) fails the dependent realization: a strategy
  or placement the Loader does not advertise (`unsupported-strategy`), a missing `module_host`
  ("hosted_dynamic needs module_host"), a permission that cannot be enforced (the start refused), a
  socket path that does not fit (the route or the start fails). Nothing is substituted.

## 17. Approval and activation

Items 18a–18c and 19.

- **The administrative path** (18a): there is no approval path and no client command that changes
  authority. The policy (its `issue` rules included), the trust file and the evidence key change only
  through the owner-only files, offline, applying at the next start; the operating system
  authenticates the owner ([DAEMON.md](DAEMON.md) §8). Whoever can write the session can change
  everything logosd does. Under an `issue` rule a module may issue grants while logosd runs, within
  what the rule allows: the only change of authority at run time.
- **Approval presentation** (18b): none; nothing asks a user to approve anything.
- **Requester provenance** (18c): the peer uid and pid of each socket command, on the logosctl socket
  and on `lcn_call`'s, are logged with it and never reach a Runtime Control request or stand for the
  consumer.
- **Activation** (19): the `logosctl` socket and instance, with BCP l.389's five items, are documented
  in [DAEMON.md](DAEMON.md) §7, "Activation": mechanism, admission (peer uid), selection (one instance,
  seventeen methods), presentation handoff (socket path, worker count, idle timeout, deployment, trust
  revision, version, start time; nothing that authenticates), failure behaviour. The CLI module's socket
  is a second activation surface, documented with the same five items in [DAEMON.md](DAEMON.md) §7a:
  `lcn_call`'s socket, which the launcher activates through the logosctl instance (`start_module` or
  `recover_module` under that instance's authority, never the launcher's), admission by peer uid,
  selection of one instance fixed by composition, a handoff of settings at initialization and terminal
  descriptors per command, and its exit codes.

## 18. Deployment representations

Item 20. The ctl wire `logos-core-nim.ctl.v1`, the CLI's arguments and its `--json` output carry Core
values unchanged: each command is one Runtime Control call whose request and answer are the
contract's values, validated by the Runtime as any module's are; the text and JSON forms only display
them ([DAEMON.md](DAEMON.md) §7, §12; DECISIONS G89, D26). The CLI wire `logos-core-nim.cli.v1` carries
a provider call's arguments as the user typed them; `lcn_call` types them from the method's request rule,
refuses an ambiguous value rather than choose a reading (BCP l.397), and checks the assembled value
against the rule before the call, which the provider's host checks again ([DAEMON.md](DAEMON.md) §7a,
DECISIONS G349).

## 19. State at rest

Item 21.

- **Protection at rest:** file modes only: 0700, 0600, and 0500 for the artifact copies (§9). No
  encryption, no secret store.
- **Other principals:** other operating-system users are kept out by the modes. Processes of the same
  user can read everything, and write the policy, the trust file and the evidence key.
- **Backup and synchronization:** no synchronization facility exists. A backup or a synchronized copy
  of the session holds everything, the evidence key's secret half included.
- **Restore:** a restored older `trust.cbor` is refused by continuity; a restored `state/` without its
  mark needs `logosctl trust reestablish`; a lost `state/` needs a new session ([DAEMON.md](DAEMON.md)
  §2, §6, §11).
- **Rollback of a state transfer:** a `move` takes no snapshot, so the operator's backup of `state/`,
  made with logosd stopped, is the rollback; a `copy` leaves the source in place.
- **Retention and deletion:** retirement keeps the state directory and is not deletion. The separately
  authorized deletion is `logosctl state purge`, offline; `logosctl state list` shows what is kept and
  where it came from ([DAEMON.md](DAEMON.md) §11). Physical erasure from storage media, snapshots or
  backups is not claimed (BCP l.401).

## 20. Non-production

Item 22 (BCP l.403-406; DECISIONS D27, G299). BCP l.403 names four non-production mechanisms. A
deployed logosd has none of them:

- **Development trust anchors:** the trust file holds no anchors (§5). When Tier 5 adds package-signing
  anchors, a development one is accepted only with the switch below on (D27).
- **Relaxed debugging entitlements:** none exist.
- **Transport test hooks** (TRANSPORT §8.5): hook code exists only in test builds (the `lcnTestHooks`
  define; the flake check `no-test-hooks` searches every packaged binary for its marker), and a hook
  stays inert until its Runtime's host selects it by an in-process call ([CONFORMANCE.md](CONFORMANCE.md),
  "Test hooks").
- **Unknown-artifact analysis:** none: an artifact is loaded only with its daemon-config digest.

What the trust file's development switch gates are mechanisms of this implementation, held to the
same rule: `policy: allow-all`, and `test_hooks` in a test build of logosd. The switch is protected
input, set offline with `logosctl trust development on`. With it on this deployment is
**non-production**: logosd's start log warns `NON-PRODUCTION`, and every `logosctl` output and socket
reply says so. The build mode enables nothing (BCP l.405): a packaged logosd has no test hooks and
refuses `test_hooks`, and a test build selects one only with the switch on. The switch weakens nothing
else (BCP l.406).

## 21. Failing closed

Item 23. Every refusal in §16, plus: a protected input that fails its checks ends the start (exit 1);
an evaluation that cannot be made is an evaluation failure, never an allow; while no authority is bound
every decision it would make is refused; a peer of another uid gets nothing. No profile, strategy,
permission or carrier falls back to a weaker one.

## 22. Builds

The packaged `logosd`, `logosctl` and `logos-module-host` are orc builds (`--mm:orc -d:release`) without
test hooks (flake check `no-test-hooks`). A refc build of the Runtime or the Module Host refuses every
contract with a marked field (DECISIONS G277): under refc a channel message's copy is freed unerased.
The erasure claim and its five non-claims are in CONFORMANCE, "Properties not claimed". The
`logos.remote.tls-tcp` carrier is built on upstream BoringSSL, which frees decrypted TLS records unerased:
`tls-tcp` gives no erasure and carries no marked payload, and a route on it or on `quic` whose permitted
methods include a marked one is refused (RUNTIME l.1808; DECISIONS G277, G327).

A module library logosd maps (`direct_dynamic`) or a Module Host loads may be built with either memory
manager (DECISIONS G342; measured with the Runtime and the Module Host on macOS and x86_64 Linux). Build
it with `-d:noSignalHandler`, so that loading it leaves the process's signal handlers alone (G340; the
kit warns without it), and link it with its kit's export list (G341). In a refc module written with
today's kit, handlers on threads other than the loading one must not store GC'd values (DECISIONS I71).

## 23. Diagnostics and logs

[DAEMON.md](DAEMON.md) §12: logosd logs to stderr, one line per event, collected by the service
manager. The Runtime's diagnostics are drained into it at start, every second and at the end; text the
Runtime did not write is quoted, cut to 256 bytes and attributed; the latest 4096 are kept in memory
only. No line holds a payload, a value root, a ticket, a key, record content or a marked method's
failure text (DECISIONS G278). A Module Host's own output is inherited and unfiltered.

## 24. Safe deployment defaults

SECURITY §13 (l.517-533) lists defaults a production deployment should begin from. Informative:

| Default | logosd |
|---|---|
| unverified dynamic code and unregistered static binding refused | a `direct_dynamic` or `hosted_dynamic` artifact is loaded only with its daemon-config digest; static bindings are logosd's two and the authority's |
| trust configured separately by purpose | evidence key and trust file apart; no package or enrollment trust yet |
| direct loading only for trusted code | `init` writes `hosted_dynamic`; `direct_dynamic` is the operator's explicit choice (§8) |
| third-party native code behind a process or application isolation profile | `process` only, not a sandbox (§8); no profile with stronger controls yet |
| permissions denied unless allowed and enforceable | host-ambient only, enforced at admission; the policy decides (§7) |
| remote surfaces disabled | none exists (§4) |
| no fallback from a remote profile | no remote profile |
| only what the consumer may see is exposed | the Runtime's visibility rules |
| tickets, keys and credentials out of logs and messages | the logging rule (§23) |
| a launch fails rather than weaken isolation | §16 |
| cached results invalidated when their basis changes | grants and policy re-evaluated; trust read once per start |
| development trust and test hooks explicit non-production configuration | §20 |

## 25. Credential Store

Item 24 (BCP l.374; DECISIONS G159). The Credential Store is optional to implement and deploy, and
neither lower-layer nor complete-system conformance requires it (BCP l.287-288). This deployment
deploys none and claims no conformance to the CREDENTIAL STORE specification, so no part of the item
has a subject: no credential, format or sealing profile, no backend to state the durability and
recovery of, no operation records, no protected delivery or activation. The Runtime and the authority
start without one (BCP l.290). A Credential Store's own documentation duties (CS l.319, l.370, l.476)
would come with one.

- **None by construction.** The Credential Store contract fixes its provider's module name,
  `logos_credential_store` (CS l.162; BCP l.280), and names beginning with `logos_` are reserved for
  Logos-defined modules (RUNTIME l.292). logosd's composition holds no such module. logosd does not
  refuse an operator's module of that name: it refuses only its own instances' names and an operator
  `direct_static` ([DAEMON.md](DAEMON.md) §3). The module fails at its start instead: a provider is
  bound only once its call surface is accepted, a `logos_` module name is accepted only for a Logos
  system module, and the Runtime treats as one only its own static registrations (the Module Loader's
  and the authority's). A Module Host, and the realizer of a `direct_dynamic` artifact, bind without
  that option, so the start fails `abi-invalid`: the name "is reserved for Logos system modules".
- **What is not refused.** A module that provides no contract has no call surface to accept, so one
  named `logos_credential_store` binds. It serves no Credential Store operation, so it is no Credential
  Store.
- `tests/test_deployment.nim` checks the facts' `credential_store`, the default composition, logosd's
  acceptance of the operator module and its refusal at binding.

## Facts

The values `tests/test_deployment.nim` checks against the code. Times are milliseconds, modes octal.

```json deployment-facts
{
  "loader": {
    "strategies": ["direct_static", "direct_dynamic", "hosted_dynamic"],
    "hosted_placements": ["process"],
    "unsupported_placements": ["sandbox", "container"],
    "force_release": false
  },
  "transport": {
    "local_profile": "logos.local.unix-stream",
    "remote_profiles": []
  },
  "permissions": {
    "profile": "logos-core-nim.permission-profile.v1",
    "definitions": [
      {"name": "logos-core-nim.host-ambient", "constraints": "a0", "enforcer": "Runtime admission"}
    ]
  },
  "deadlines": {
    "loader_startup": 120000,
    "startup": 120000,
    "apply": 120000,
    "stop": 10000,
    "shutdown_grace": 10000
  },
  "modes": {"directory": "0700", "file": "0600", "artifact_copy": "0500"},
  "hosts_run_as": "the daemon's user",
  "state_after_retire": "kept",
  "evidence_store": {
    "default": "off",
    "queue": 4096,
    "max_records": 1000000,
    "max_age_days": 30,
    "segment_entries": 10000,
    "segment_bytes": 16777216
  },
  "diagnostics_retained": 4096,
  "memory_manager": "orc",
  "admission_pools": {
    "prepared_calls": {"total": 4096, "per_consumer": null},
    "module_instances": {"total": 1024, "per_consumer": null},
    "call_workers": {"total": 128, "per_consumer": null},
    "evaluation_queue": {"total": 256, "per_consumer": null},
    "observation_snapshots": {"total": 256, "per_consumer": 8},
    "observation_snapshot_bytes": {"total": 67108864, "per_consumer": 8388608},
    "observe_end_registrations": {"total": 16384, "per_consumer": 1024},
    "runtime_control_subscriptions": {"total": 1024, "per_consumer": 32},
    "store_snapshot_bytes": {"total": 67108864, "per_consumer": null},
    "authority_queued_requests": {"total": 1024, "per_consumer": null},
    "authority_grants": {"total": 16384, "per_consumer": null},
    "authority_watches": {"total": 64, "per_consumer": 8},
    "transport_inbound": {"total": 1024, "per_consumer": null},
    "transport_pending_hellos": {"total": 64, "per_consumer": null},
    "transport_outbound": {"total": 1024, "per_consumer": null},
    "transport_calls": {"total": 16384, "per_consumer": null},
    "transport_subscriptions": {"total": 16384, "per_consumer": null},
    "transport_subscription_ids": {"total": 65536, "per_consumer": null},
    "transport_hello_input_bytes": {"total": 33554432, "per_consumer": null},
    "transport_input_bytes": {"total": 268435456, "per_consumer": null},
    "transport_output_bytes": {"total": 268435456, "per_consumer": null},
    "transport_pending_output_bytes": {"total": 67108864, "per_consumer": null},
    "orchestrator_open_episodes": {"total": 4096, "per_consumer": null}
  },
  "authority_audit": {"acknowledged": "append", "unwritten_bound": 4096, "retained_records": 65536},
  "credential_store": "none",
  "runtime_claim": {"orchestration_module": "lcn_orchestrator", "orchestration_instance": "orchestrator"},
  "cli": {
    "instance": "lcn_call",
    "placement": "process",
    "started_at_boot": false,
    "socket": "run/lcn_call.sock",
    "workers": 8,
    "streams": 8,
    "idle_timeout": 30000,
    "route_idle": 600000,
    "events": ["execution_state_changed", "inventory_changed", "module_state_changed"],
    "max_hops": 4
  }
}
```
