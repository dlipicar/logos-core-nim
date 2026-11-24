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
  realizes every other instance through it (BCP l.292-296). It claims no complete Logos module system
  (owner decision 10 (a); DECISIONS G310; CONFORMANCE, "Properties not claimed"): with a
  `package_manager` section it runs the Package Manager, which installs packages, but nothing selects
  an installed package for execution. It still answers every §5.4 item, as a deployment that owes this document would. Its
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
| 1 | l.363 | Package Manager source kinds; provenance profiles | None | Tier 5 | the Package Manager logosd composes with a `package_manager` section (step 5-6a-1) runs hosted; it realizes `lgx` sources and answers `nix` `unsupported-source`; no source kind for package-backed creation, no provenance profile | [§1](#1-package-manager) | BCP-0040 |
| 2 | l.364 | protected inputs: representations, provisioning, validation, replacement, revocation | Supported | — | owner-only session files, checked at start, replaced offline for the next start | [§2](#2-protected-inputs) | BCP-0074 |
| 3 | l.365 | authority-policy format, administration, permissions of bootstrap and system instances | Supported | — | `authority-policy.v1` in daemon-config; system rules S1–S5, and S6–S8 with the CLI module; host-ambient for system instances | [§3](#3-authority-policy) | BCP-0075 |
| 4a | l.366 | local transport profile | Supported | — | `logos.local.unix-stream` | [§4](#4-transport) | BCP-0041 |
| 4b | l.366 | remote transport profiles | None | Tier 5 | none enabled; no listener, no export; the enrollment trust (5d) is not yet used | [§4](#4-transport) | BCP-0041 |
| 5a | l.367 | call-evidence signing trust | Supported | — | one evidence key per session, bound to the Runtime, rotated offline | [§5](#5-trust-inputs) | BCP-0042 |
| 5b | l.367 | package-signing trust | Supported | — | the package trust file: anchors with exact names under one revision, administered offline by `logosctl trust` | [§5](#5-trust-inputs) | BCP-0042 |
| 5c | l.367 | package-provenance and source-evidence requirements | None | Tier 5 | none selected; a selection is refused until step 5-11 | [§5](#5-trust-inputs) | BCP-0042 |
| 5d | l.367 | remote Runtime enrollment | Supported | — | the remote trust input: anchors and enrollment records under one revision with its mark, administered offline by `logosctl remote trust`, applied at the next start | [§5](#5-trust-inputs) | BCP-0042 |
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
| 12b | l.375 | Package Manager bounds, dependency resolution | None | Tier 5 | the Package Manager logosd composes with a `package_manager` section (step 5-6a-1) runs hosted; its bounds, resolver limits, queues, operation deadline and budget are listed | [§12](#12-resource-bounds) | BCP-0047 |
| 13 | l.376 | deadlines: start points, phases, effects, escalation, shared-process limits | Supported | — | five deadlines; a Module Host may be ended by force; a direct realization never | [§13](#13-deadlines) | BCP-0078 |
| 14 | l.377 | configuration-preserving upgrade; verified defaults | Supported | — | the operator carries configuration; defaults come from accepted declarations | [§14](#14-upgrade-and-verified-defaults) | BCP-0079 |
| 15 | l.378 | presentation profile | None | — | none selected (BCP l.346); the CLI writes to the launcher's terminal, which is not a presentation profile | [§15](#15-presentation) | BCP-0048 |
| 16a | l.380 | Package Manager installation, inventory, shared state | None | Tier 5 | the Package Manager logosd composes with a `package_manager` section (step 5-6a-1) runs hosted; it installs into its own instance's state directory, one inventory per instance, never shared | [§1](#1-package-manager) | BCP-0080 |
| 16b | l.380 | operating-system integration material | Supported | — | a systemd user unit and a launchd agent, owner-installed | [§16](#16-facilities-that-cannot-be-supplied) | BCP-0080 |
| 17 | l.380-382 | a facility or constraint that cannot be supplied fails | Supported | — | the dependent realization fails; nothing falls back | [§16](#16-facilities-that-cannot-be-supplied) | BCP-0081 |
| 25 | l.383 | each finite admission pool shared by consumers or providers: whether a per-consumer or per-provider limit applies | Supported | — | each pool with its total and its per-consumer or per-provider limit, or none | [§12](#admission-pools) | BCP-0102 |
| 18a | l.385 | the administrative path and its authentication | Supported | — | offline edits of owner-only files; the OS authenticates | [§17](#17-approval-and-activation) | BCP-0082 |
| 18b | l.385-386 | approval presentation | None | — | no user-facing approval | [§17](#17-approval-and-activation) | BCP-0083 |
| 18c | l.387 | requester provenance kept apart | Supported | — | peer uid and pid logged, never the consumer, on both sockets | [§17](#17-approval-and-activation) | BCP-0084 |
| 19 | l.389-395 | activation: mechanism, admission, selection, presentation handoff, failure | Supported | — | the `logosctl` socket and its instance; the `lcn_call` socket and its instance, started through the first | [§17](#17-approval-and-activation) | BCP-0085, BCP-0086, BCP-0087, BCP-0088, BCP-0089 |
| 20 | l.397 | deployment representations keep Core meaning | Supported | — | the ctl wire, the CLI wire and the CLI carry Core values unchanged | [§18](#18-deployment-representations) | BCP-0090 |
| 21 | l.399-401 | state at rest, principals, secrets, backup, restore and rollback, retention and deletion | Supported | — | file modes only; no secret store; `state purge` is the deletion | [§19](#19-state-at-rest) | BCP-0091, BCP-0092 |
| 22 | l.403-406 | non-production mechanisms: development trust anchors, relaxed debugging entitlements, Transport test hooks, unknown-artifact analysis | Supported | — | development anchors are in force only with the trust file's development switch on, and the other three are not in a deployed logosd; what the switch gates is announced everywhere | [§20](#20-non-production) | BCP-0103, BCP-0094, BCP-0095, BCP-0096 |
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
| PM | l.926-931 | the installation and inventory scope, shared state, and the root's path-comparison rules | the instance's own `install/`, never shared, its rules found at each start ([§1](#1-package-manager)) | PKG-0487, PKG-0488, PKG-0489 |
| PM | l.950 | the supported `os`, `architecture` and `abi` values and their matching rules | the host's platform, G73's values and rules ([§1](#1-package-manager)) | PKG-0493 |
| PM | l.1181-1183 | how a module reaches its packaged resources and data | through its schema-typed configuration only ([§1](#1-package-manager)) | PKG-0498 |
| PM | l.1721-1727 | the storage failure model under which installed state is committed | a write is complete once synced; the index replaced atomically ([§19](#19-state-at-rest)) | PKG-0610 |

The Package Manager's catalogs (PM l.834) and its bindings' retrieval and locators (PM l.854-857) are
documented in [PACKAGE-MANAGER.md](PACKAGE-MANAGER.md) §3 and §4, with the locator encodings in
`sdk/docs/STORAGE-FETCH.md` §5. Its duties of l.926-931 (installation scope), l.950 (the platform profile),
l.1183 (resource access) and l.1727 (the storage failure model) are rows of this table since step 5-5-4,
when installation runs. l.1731 (the retention policy of installed-state snapshots) comes with step 5-6b. The Credential
Store's (CS l.319, l.370, l.476) belong to a Credential Store, which it does not have either (§25).
The other hits of the search are duties of a specification, a record or a message (for example HASH
l.35, R l.3265, T l.564), not choices of a deployment.

## 1. Package Manager

Items 1, 5b, 5c, 10b, 12b and 16a.

- **Hosted, when configured.** With a `package_manager` section in daemon-config ([DAEMON.md](DAEMON.md)
  §3; DECISIONS G399, G491), logosd composes the reserved instance `package_manager` of the module
  `logos_package_manager`, `hosted_dynamic`, from the library installed beside it (or
  `package_manager.artifact`), and hands it its `lcn.pm_input` as protected realization input (G400):
  the bindings to its Storage providers, the protected catalog, the resolver limits and a copy of the
  trust file the start accepted. It acquires the catalog over its own routes (G401, G402) and inspects,
  installs, removes and updates packages against it ([PACKAGE-MANAGER.md](PACKAGE-MANAGER.md) §11, §14;
  DECISIONS G449). No package is selected for execution: there is no package-backed creation, and
  nothing reads the inventory but the Package Manager.
- **Moving from an operator entry** (5-6a-1). Before 5-6a-1 the section named an operator instance
  (`package_manager.instance`); that field is now refused, naming `state` and `artifact`. The old
  installed state is not carried: the old instance's record (live, or a tombstone once it is removed from
  `modules`) keeps its state assignment, so the reserved instance starts on the new `state`, empty, and
  the operator installs again. The old state directory is the operator's to keep or delete. There is no
  migration code. A module still comes from daemon-config as an artifact path with
  its digest (§10). `lcn-pkg`, the LGX parser and the resolver are also tools (DECISIONS I49, I69).
- **Source kinds** (BCP l.343-349): `lgx` is realized, from a Storage binding's object (PM §7.1, §13);
  `nix` is not, and a request that selects it is answered `unsupported-source` (PKG-0190). No
  provenance profile is selected (below).
- **The target platform** (PM l.950; DECISIONS G453, G73). The Package Manager installs for the host it
  runs on, since the Loader that uses the artifacts runs there too. The values: `os` `linux` or
  `darwin`, `architecture` `x86_64` or `aarch64`, `abi` `gnu` or `musl` on Linux (as the build) and
  none on Darwin. The values the profile defines are those and `windows`, `android`, `ios`, `mingw`
  and `msvc`. The rules: each field a variant names matches a defined value byte for byte, a value with
  no defined rule never matches, a field it leaves out constrains nothing, and the first compatible
  variant in declared order is selected; with none, `incompatible-platform`.
- **The installation root** (PM l.924-934; DECISIONS G444). Step 5-5-2 builds it and step 5-5-4's
  operations install into it. Its scope is choice (a) of the owner's question Q5, answered on
  2026-11-22.
  - **Place and scope:** `install/` in the Package Manager instance's own state directory
    (`state/modules/<assignment>/install/`, [§9](#9-directories-and-state)). The inventory is the service
    instance's (PM l.927): one per Package Manager instance, and two instances never share one, since
    each has its own state assignment. No setting names another root or a shared store, so there is no
    shared mutable installation state and no shared artifact storage (l.929-931). A second writer on the
    same root is refused by the root's lock (`install/lock`), and that instance does not start.
  - **Layout:** `index`, the committed set; `r/<rid>/`, one installed record in a directory of 128 random
    bits (`a/` the selected variant's files, `m/` the signed manifest, its signature and the record);
    `spool/`, the archives of running operations; `lock`. Directories are 0700 and files 0400, and
    nothing in it is made executable.
  - **Path-comparison rules** (l.924): those of the filesystem holding the root, found at each start, not
    from the operating system's name alone (l.932). They are case-insensitive on Darwin, and on Linux
    when a probe in the root finds that the filesystem folds case (a casefold directory, vfat, exFAT).
    LGX paths are NFC, so no normalization differs. A selected variant whose paths or directory prefixes
    collide under these rules is refused before anything is written. The root is built for POSIX
    systems (Linux and Darwin), as the hosted Package Manager is.
  - **Inside the root** (l.933-934): every entry is created relative to a directory the extraction opened,
    never following a link, so no destination can leave the root; an existing name or a planted link
    fails the installation with `artifact-integrity-failed`.
- **Resource access** (PM l.1180-1185; DECISIONS G93, G444). A module reaches its packaged resources and
  data only through its schema-typed configuration: a deployment that wants a module to read a file
  gives its location in that module's configuration. `local_path` is the Loader's installation location,
  not a path a module is told of, and the Runtime handoff gives no package root and no artifact table. A
  module is one self-contained library: the system linker uses no search path of ours, and a library
  shipped beside a module is installed and bound to its verified bytes ([§19](#19-state-at-rest)) but not
  loaded.
- **The baseline only** (G404). The Package Manager applies the package-signature and
  artifact-verification baseline (PM §4.1, §4.3, §4.4) and selects no catalog or provenance profile: it
  provides no authenticated catalog ordering, freshness or external anchoring, and claims no package
  provenance ([PACKAGE-MANAGER.md](PACKAGE-MANAGER.md) §6).
- **Does continued execution depend on current package-signing trust acceptance** (PM l.408)? **No.**
  1. No instance runs from a package. The trust file's anchors ([DAEMON.md](DAEMON.md) §6; DECISIONS
     G396) are used by the Package Manager to verify the packages it inspects, and by nothing that
     decides whether a module runs.
  2. No instance has a signer or package fact, direct or hosted: the Runtime's registry, the only
     source of the facts the authority reads, records an instance's id and module name and no
     selection (§11). A policy rule naming a signer or package matches nothing, and no execution
     decision depends on one.
  3. A change of the trust file takes effect only at the next start ([DAEMON.md](DAEMON.md) §6), the
     Package Manager's copy included, so nothing running is affected by one.
  4. Package-backed selection (Tier 5) is expected to change this answer (DECISIONS G137, amended
     2026-11-16).

## 2. Protected inputs

Item 2. Each is a file of the session, owned by its user, mode 0600 in 0700 directories
([DAEMON.md](DAEMON.md) §2); a session others can access is refused.

| Input | Representation | Written by | Validated | Replaced |
|---|---|---|---|---|
| daemon-config, the authority policy in it, module configuration values, `state_transfers` | one deterministic-CBOR `lcn.daemon_config` ([DAEMON.md](DAEMON.md) §3) | `logosctl init`, `daemon config set` | the five checks of DAEMON.md §3, at `set` and at every start | at the next start |
| the package trust file and its mark | `lcn.package_trust` (a Tier 4b `lcn.trust_file` is still read), `lcn.trust_mark` (§6 there) | `init`, `trust anchor …`, `trust development`, `trust reestablish` | at every start, and by every writer before it writes: the schema and its 1 MiB bound, the rules (canonical order, exact names, nothing selected), key separation from the evidence keys; at start, revision continuity: rollback and changed contents refused | at the next start |
| the evidence key and its binding | `lcn.ev_key_binding` (§6 there) | `init`, `trust evidence-keys rotate` | the binding names this Runtime (§3 check 4) | at the next start |
| the remote trust input and its mark (with `remote.enabled`) | `lcn.remote_trust`, its records RUNTIME's `logos.runtime_enrollment` unchanged; `lcn.remote_trust_mark` (§6a there) | `remote trust init`, `reestablish`, `anchor …`, `enroll …`, `import` | at every start, and by every writer before it writes: the schema and its 16 MiB bound, the rules, the loader report; at start, revision continuity (rollback and changed contents refused) and the enrollment rules per key (a stale or omitted record refused) | at the next start |
| the TLS credential (with `remote.enabled`) | `key.p8` (PKCS#8 P-256), `cert.der`, `peer.cbor` (§6b there) | `remote credential new`, `rotate` | at every start: present, the key the certificate's, the peer file naming both; a pending rotation taken up | at the next start (a rotation is a cutover) |

**Revocation.** A grant's end, its expiry and a policy decision that no longer allows an execution or
route take effect at once, while logosd runs (CA §8; [HOST-CONFIG.md](HOST-CONFIG.md), "Under
`capability-authority`", Authority over time). A withdrawn development switch, a removed trust anchor or
package name, a rotated evidence key and a changed policy take effect at the next start, since every
input is read once. A removal that names an anchor or package name the file does not hold withdraws
nothing and is refused, so a mistyped revocation is reported, not taken for one (BCP l.364). An
enrollment's revocation (`remote trust enroll revoke`) and a withdrawn remote trust anchor apply at the
next start too, by the restart that also ends every connection of that run (DECISIONS G87, G408); the
command says so.

## 3. Authority policy

Item 3. The format is `logos-core-nim.authority-policy.v1` ([AUTHORITY-POLICY.md](AUTHORITY-POLICY.md)).
logosd merges the operator's rules with its system rules S1–S5, S6–S8 when it composes the CLI
module `lcn_call`, and S9–S12 with a `package_manager` section (the Package Manager's routes to its
Storage providers, and what `logosctl` may not do to it), which are derived and not configurable ([DAEMON.md](DAEMON.md) §5). Administration is
the offline path of §17. The explicit permissions of the bootstrap and system instances: host-ambient for
`orchestrator`, `logosctl`, `authority` and `lcn_call`, written by logosd; the Module Loader holds it by construction ([PERMISSIONS.md](PERMISSIONS.md), "What BCP asks to
be documented"). `allow-all` is accepted only with the development switch on (§20).

## 4. Transport

Items 4a and 4b.

- **Local:** `logos.local.unix-stream`, the only local profile, with endpoints under `<session>/run/ep/`
  ([CONFORMANCE.md](CONFORMANCE.md), "Unix-stream endpoints and peer checks").
- **Remote:** `logos.remote.tls-tcp`, with `remote.enabled` and `runtime.remote_program` (the
  `logos_remote` program). Remote listeners and provider exports are disabled by default; the
  deployment's records are `remote.listeners` and `remote.exports` in the daemon configuration,
  validated as Runtime Control validates the same records, a bad one refusing the start (RUNTIME
  l.3319-3321; DECISIONS G412). Each enabled listener is one `logos_remote` process that logosd spawns,
  supervises and ends with itself ([REMOTE.md](REMOTE.md), "The listener process and its end"; G411).
  A listener with `runtime_control_enabled` serves Runtime Control to enrolled Runtimes' consumers, as
  a capability-authority policy with `runtimes` rules allows (G413, G415); `policy: allow-all` with
  `remote.enabled` refuses the start. **Which changes last** (Q4): a listener's `enabled` or
  `runtime_control_enabled`, or an export's `enabled`, turned off through Runtime Control stays off
  across restarts and crashes until its configuration entry changes, Runtime Control enables it, or
  `logosctl remote exposure reset` removes it; an enable through Runtime Control lasts for the run
  ([DAEMON.md](DAEMON.md) §6c). Remote routes and the source side come with steps 5-7a-3 and 5-7a-4:
  until then no provider session is served to another Runtime, and `establish_route` from a forwarded
  consumer is MODULE_ERROR. `quic` records are kept, and enabling one is MODULE_ERROR (step 5-12).

## 5. Trust inputs

Items 5a–5d.

- **Call-evidence signing** (5a): one evidence key per session, made by `logosctl init`, bound to the
  Runtime id and rotated offline (DECISIONS G149; [DAEMON.md](DAEMON.md) §9). A rotation applies at
  the next start; the retired key keeps its binding and loses its secret half.
- **Package signing** (5b): the package trust file, `<session>/trust.cbor` (`lcn.package_trust`;
  [DAEMON.md](DAEMON.md) §6; DECISIONS G396, G397): the baseline profile
  `logos.package-signing.cose-sign1-slh-dsa-sha2-192s` and each anchor's kid, 48-byte key, exact package
  names and development marker, all under one revision with its continuity mark. It is written offline
  by `logosctl trust anchor …`, checked at every start and by every writer, and replaced at the next
  start. No anchor may use a call-evidence key. The Package Manager receives a copy at every start (§1;
  [DAEMON.md](DAEMON.md) §6), so a change applies to it at the next start.
- **Package provenance and source evidence** (5c): none selected. The trust file's `provenance` section
  is empty, and a file that selects a profile is refused until step 5-11 (DECISIONS G398). Tier 5.
- **Remote Runtime enrollment** (5d): the remote trust input, `<session>/remote/trust.cbor`
  (`lcn.remote_trust`; [DAEMON.md](DAEMON.md) §6a; DECISIONS G408): the complete remote trust-anchor set
  and the enrollment records in RUNTIME's published schema, under one revision of its own with its own
  continuity mark, apart from the package trust file. It is written offline by `logosctl remote trust`,
  checked at every start with `remote.enabled` and by every writer, and replaced at the next start. Each
  anchor is a direct anchor, a peer's own self-signed certificate (G324); the Runtime's own credential
  is `logosctl remote credential`'s (§6b there; G409), its key apart from every other key.
  **Interoperation** (TRANSPORT l.1245): this implementation accepts only direct anchors, so a peer of
  another implementation must support the direct-anchor case to enroll this Runtime's certificate, and
  must present a certificate DER-equal to an anchor this Runtime holds. Two Runtimes of this
  implementation interoperate. The listener processes use it (§4).

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
The Package Manager and its Storage providers are such modules too: logosd composes the Package Manager
`hosted_dynamic` and refuses a `package_manager` section whose Storage instances are not (DECISIONS
G399, G491), so no archive enters logosd's process.

**Not supported (8b).** Placement `process` is a separate address space, **not a sandbox** (DECISIONS
G265): a hosted module has the filesystem, network, device, process and credential access of logosd's
user, and no operating-system resource control is applied. A process the module moves out of its
group or session outlives the host. Processes of the same user can reach each other's sockets and
files (CONFORMANCE, "Properties not claimed"). So it is with the Package Manager's protected input: its
file is written by logosd's Runtime, owner-only, which keeps other users out; any process of logosd's
user can replace it between the write and the Package Manager's read ([HOST-CONFIG.md](HOST-CONFIG.md),
`protected_inputs`). Outside Tier 5: DECISIONS D16 leaves sandbox and container
placements and their controls out, and so does the Tier 5 plan (its area K). A payload module's own
network behaviour, beside its peers, is in §26.

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
- **The Package Manager's data path** (G402): the catalog and the archives travel over its own routes
  from the Storage provider's process to the Package Manager's; logosd issues the routes and decides
  their Hello, and never carries a catalog, an archive or the trust input.
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
- **Reserved names.** `.lcn-protected-input` and its temporary names `.lcn-protected-input.<32 hex>`
  are reserved in every state directory (DECISIONS G400): the protected realization input's file,
  written before each realization attempt's initialization and removed when it returns, at release
  and at retirement. A state transfer by `copy` skips them; a backup of the state directory does
  not, so it may hold the input while an attempt runs ([HOST-CONFIG.md](HOST-CONFIG.md)). The Package
  Manager's own state is `catalog.kept`, the last catalog it accepted, and `install/`, its installation
  root ([§1](#1-package-manager)), both under its state assignment ([PACKAGE-MANAGER.md](PACKAGE-MANAGER.md)
  §3, §8). `install/` is reserved in the Package Manager's state directory; nothing else writes in it,
  and its own start deletes what its index does not name (DECISIONS G445).
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
  policy supplies the values; these are their maxima). logosd supplies `package_manager.resolver_limits`,
  or its preset when the section names none ([DAEMON.md](DAEMON.md) §3; DECISIONS G443: 256 names,
  depth 32, 256 candidates per name, 1,024 attempts). A new preset changes the results of a
  configuration that names no limits, so an operator who needs results fixed across upgrades writes the
  four values. A limit that ends an operation answers `dependency-unavailable`, as a missing dependency
  does; the Package Manager's log names the limit;
  - **What raising a limit costs.** Nothing but the limits ends a resolution (PM l.1279-1280). Since
    5-3c-2 (DECISIONS G455) a resolution is one run that holds the Package Manager's module thread a
    turn at a time and is never rerun: a turn ends at each inspection or after a fixed count of work,
    and route answers, timers and other operations go between two turns. At the preset and at the
    maxima the longest turn measured is under 11 ms on the Mac and under 9 ms on Linux, a package
    with a maximum-size manifest (4 MiB, about 80,000 dependency entries) in the closure included,
    and most turns take 1 to 3 ms. Before 5-3c-1 and 5-3c-2 one step at the preset held the thread about 56 s
    on the Mac. So a raised limit no longer lengthens a hold; it costs time and memory in all. A dense
    closure of 4,096 names takes about 4 to 6 s of the thread in about 940 turns and 6.5 GiB of memory
    at peak; the maximum `assignment_attempts` with such a manifest in the closure about 1.8 s in
    about 1,340 turns. The resolution's setup over the catalog and the release of its state are turns
    too. CONFORMANCE "Resolver limits" gives the measured figures on both machines, before and after.
    Any accepted signer with a package in the closure can bring these costs, not only the root's, so
    a raised limit is the operator's choice for every package its trust admits;
- the Package Manager's own bounds, `package_manager.limits` ([PACKAGE-MANAGER.md](PACKAGE-MANAGER.md)
  §2): one archive (`archive_bytes`, 1 GiB by default, spooled to the instance's state directory and
  judged by the worker thread, never held in memory: the budget below), the catalog document (4 MiB) and
  its entries (65,536), the verification cache (256 entries, each at most 256 KiB by its estimate),
  the records, entries and contracts one operation reads (`operation_entries`, 262,144) and one
  operation's time (`operation_deadline_ms`, 1 h, from taking its slot). A larger archive leaves its
  candidate unavailable; a larger catalog is refused and the one in use stays; the cache drops its
  least recently used entry, and keeps no inspection over its estimate's bound; an operation past
  `operation_entries` ends `package-unavailable`, and the log names the key; one past
  `operation_deadline_ms` ends `package-unavailable` too, its retrieval cancelled, unless its last
  commit has begun. Each slot queues at most 16 requests, and the next is refused with `MODULE_ERROR`
  at once (DECISIONS G449);
- the LGX reader's table (DECISIONS G75, `DefaultLgxLimits`): compressed 1 GiB, decompressed 4 GiB,
  65,536 entries, one entry 1 GiB, the selected variant's files 4 GiB, and its kept contract and
  configuration documents 64 MiB in all (fixed, not derived from `archive_bytes`; G446). The table is
  the cap: an `archive_bytes` below 1 GiB lowers decompressed and extracted in the table's proportion,
  today four times `archive_bytes`, and one entry to the decompressed bound (DECISIONS G453). A package
  past any of them is `invalid-package`. The reader reads an archive in 1 MiB pieces, so its memory does
  not grow with the archive: 11 to 13 MiB at 1 GiB (CONFORMANCE, "The streaming reader").

### The Package Manager's budget

What one Package Manager instance holds, by part (DECISIONS G446, G447, G449, G477; plan 5-5 §4.13).
The module's operations run in the slots; only the test module `pmtest_module`'s `resolve`, a 5-3b
test method outside them, runs any number of resolutions at once.

| Part | Resource | Lives for | Bound |
|---|---|---|---|
| The spool | disk, the state directory's file system | an archive's judgment; a mutation's selected archives until their commits | the inspections' archives spooled at once are at most 4 × `archive_bytes`, 4 GiB at the default; a retrieval that would pass it waits. A mutation keeps its selected archives under 4 × `archive_bytes` of its own, the oldest deleted past it and fetched again by digest when needed, so the host's spool is at most 8 × `archive_bytes`, 8 GiB. Not synced; the start empties it |
| The reader's working set | worker memory | one inspection | 1 MiB pieces, a 4 MiB manifest, at most 64 MiB of documents: 10.6 MiB measured at 1 GiB under orc, 13.2 MiB under refc. One worker per instance, one job at a time; the benchmark's whole process, both sides, peaked at 13.8 MiB under orc judging 1 GiB (CONFORMANCE "The worker and the spool") |
| The resolver's state | module thread memory | an operation | `operation_entries` × the bytes a unit takes: at the default at most about 460 MiB (1.8 KiB a unit, the worst measured, with the corrected unit); at the maximum, 2^24, about 29 GiB for one operation (DECISIONS G477). With the two slots, two in flight per instance, about 0.9 GiB at the default. Each takes a copy of the installed records it resolves against: 147 MiB under orc and 261 MiB under refc at the index's bound (200,000 records) |
| The verification cache | module thread memory | the instance | `cache_entries` × 256 KiB by the estimate: 64 MiB at the default, 1 GiB at the maximum |
| The catalog | module thread memory | the instance, and a copy for each operation | the catalog in use, from at most `catalog_bytes` (4 MiB): about 43 MiB under orc and 66 MiB under refc for the most entries 4 MiB holds (49,930 short ones), its document's bytes included. Each running operation's resolver takes its own copy of the entries (`pm/driver.nim` `initDriver`), about 20 MiB under orc at that size |
| A judgment in flight | both threads | one hand-over, then its decoding turns | one encoded judgment, at most the manifest's 4 MiB of bytes, moved under orc and copied under refc (up to about 23 ms of the module thread for 80,000 entries), then decoded at most 1,024 entries and contracts a turn; one whose operation went is freed at the same rate |
| An archive's pieces in flight | memory, the worker's queue | one retrieval | at most 4 pieces of 1 MiB (`SpoolLag`) per retrieval, one retrieval at a time per binding |
| The installed-state snapshots | module thread memory | an operation | each running operation and query holds the snapshot current when it began, so with two slots and queries up to a few are alive; they share every record they have in common, so a commit adds one record's size. One snapshot at the index's bound (`MaxIndexBytes`, 64 MiB encoded; 200,000 records at the longest identities) is 188 MiB under orc and 259 MiB under refc |
| The installed state's start | time, inside `_MODULE_init` | each start | every record read, decoded and checked against its manifest (PKG-0471): about 1 ms of CPU a record under orc on the Mac, half of it the manifest's commitment, and 1.5 ms under refc (CONFORMANCE, "The operations"). 50 s at 50,000 records under orc, so the default startup deadline (120 s, item 13) holds about 120,000 records under orc and 80,000 under refc, below the index's bound of 200,000; a larger installed state needs a larger `runtime.startup_deadline_ms` (DECISIONS G445) |
| A module declaration being decoded | module thread | one turn | one selected module's declaration a turn: 21 ms under orc and 38 ms under refc for a 4 MiB module of 22,076 commitments |
| A response being built | module thread memory | one call | within the 16 MiB body (PM l.824, the admission bound), one for each running call; the root's `{installed}` and an inspection's `{inspection}` are encoded on the worker. On its way out a reply holds threads by its nodes, not its bytes: a maximal `{installed}` (65,536 artifacts) holds the module thread 5.4 s under orc and 10.5 s under refc on the Mac, 13.4 s and 24.9 s on server.lan (medians), then its host's I/O thread about as long ("A large reply's passes", below; DECISIONS G447's exception, G497) |
| Retired directories | disk, the installation root | while a snapshot older than their retirement is held | a removed or replaced package's directory, each within the extracted bound, 4 GiB at the default |
| The queues | module thread memory | while waiting | 2 × 16 decoded requests; the 17th in a slot is refused with `MODULE_ERROR` |
| A request's wait | time | while queued | 16 × `operation_deadline_ms`, 16 h at the defaults, for a caller with no deadline of its own; in work, 16 operations each within `operation_entries` |
| An operation | time | from taking its slot | `operation_deadline_ms`, 1 h at the default; then `package-unavailable`, unless its last commit has begun. A worker job it leaves runs to its end: at most one more extraction of the largest archive (DECISIONS G449) |


### A large reply's passes

DECISIONS G447's exception and G497; the owner's choice of 2026-11-24, "Merge, state the limit".

**The cost of a reply's way out follows its nodes, not its bytes** [SPEC TRANSPORT §4.1]: every map, field, leaf
and choice is validated and hashed as an object of its own, at both ends. A confined kit module's reply makes three
passes, each over the whole value:
- **the sender's module thread:** the Module Host's `checkResponse`, the schema check and the value root;
- **the sender's host I/O thread:** the transport's commitment, computed again at `respond`;
- **the receiver's I/O thread:** `acceptResponse`'s check and value root.

Each pass holds its thread for its whole length.

**Measured.** `tools/pmbench.nim reply facade`: the Package Manager's `{installed}`, checked against PACKAGE MANAGER
App A. CPU time, best / median / max of 15 samples. The Mac is an M1 Max; server.lan is a Ryzen 5 4500U. The raw
figures are in `tier5-plans/evidence/step5-6a-1/`.

| Reply | Host | The module thread (the check) | The host's I/O thread (the commitment) |
|---|---|---|---|
| a maximal `{installed}`: 65,536 artifacts, 16.0 MiB, 327,703 values | the Mac, orc | 5.3 / 5.4 / 5.7 s | 4.8 / 4.8 / 4.9 s |
| | the Mac, refc | 10.1 / 10.5 / 11.6 s | 9.2 / 9.7 / 10.0 s |
| | server.lan, orc | 13.3 / 13.4 / 14.2 s | 12.3 / 12.3 / 12.4 s |
| | server.lan, refc | 24.6 / 24.9 / 28.8 s | 22.6 / 23.7 / 24.5 s |
| one module's declaration: 4 MiB, 110,412 values | the Mac, orc | 1.29 / 1.32 / 1.34 s | 1.29 / 1.31 / 1.33 s |
| | the Mac, refc | 2.35 / 2.46 / 2.55 s | 2.64 / 2.76 / 2.91 s |
| | server.lan, orc | 3.23 / 3.31 / 3.37 s | 3.24 / 3.31 / 3.36 s |
| | server.lan, refc | 5.75 / 5.87 / 5.98 s | 6.43 / 6.69 / 6.93 s |

- **The receiver's pass:** about the module thread's. This is estimated from the check, not measured through the
  transport.
- **Per value:** 12–14 µs on the Mac under orc and 21–26 µs under refc; 29–37 µs on server.lan under orc and
  50–63 µs under refc.
- **The one-string case:** a reply of the same bytes in a few strings is cheap. 5-5-4 measured that case with
  pmtest's `{response: bstr}`: about 99 ms and 175 ms on the Mac, 200 ms and 390 ms on server.lan, for 16 MiB.
  Those figures stay as measured, named as the one-string case. pmtest's `install` went in 5-6a-2 (G496), so they
  can no longer be rerun from `tools/pmbench.nim`.

**Limits, stated.** The fix is the core item "large-response completion": held until after the pause, and needed
before a release.
- **A Hello times out during a pass.**
  - While the Package Manager's host I/O thread or the receiver's I/O thread holds, it reads nothing.
  - A connection opened to that host then fails its Hello at `hello_timeout_ms` (10 s), with `TRANSPORT_ERROR` on
    the caller's side.
  - A maximal reply already passes 10 s on server.lan under orc (the host's I/O thread 12.3 s, the check 13.4 s),
    and under refc (23.7 s and 24.9 s).
  - On the Mac under refc it is the receiver's check that passes it (10.0–11.5 s).
- **The Package Manager answers nothing else during a pass.**
  - Its module thread and its host's I/O thread serve all its sessions: the CLI's routes, the system binding,
    every other consumer, and its own retrievals from Storage.
  - So other operations' turns, queries, handoffs and the shell's timers wait. For a maximal reply that is 5.4 s
    to 24.9 s on the module thread, then 4.8 s to 23.7 s on the I/O thread.
  - A Storage read whose answer arrived during the hold may be judged late against `read_deadline_ms`.
- **A stop waits for the pass.**
  - The cancel is seen only when the module thread returns.
  - With the stop deadline at 10 s (§13), a stop during a maximal reply ends in `cleanup-timeout` on server.lan
    (13.4 s under orc, 24.9 s under refc).
- **The receiver's I/O thread stalls for its own pass, and with it every session of the receiver's host.**
  - For `logosctl` the receiver is the `lcn_call` instance's Module Host, so every concurrent CLI call waits.
  - That is 5.4 s on the Mac under orc, up to about 25 s on server.lan under refc (28.6 s at the worst sample).
- **`logosctl`'s default `--timeout` (65 s) is missed by a maximal install or update on every host.**
  - Extraction alone is about 100 s on the Mac. This is 5-5's 20,000-artifact figures scaled to 65,536, not
    measured at that size.
  - On server.lan under refc, the reply's way out alone is 74–82 s: the three passes, after the worker's answer.
  - An operator installing packages of tens of thousands of files passes a larger `--timeout`. The largest
    allowed is 3,600,000 ms.
  - By this arithmetic, 1,800,000 ms (30 min) covers the largest legal package on both hosts with margin.
  - On a client `TIMEOUT` the outcome is unknown (exit 2). The operation goes on under its own deadline and may
    still commit.
- **`write_stall_timeout_ms` (30 s) is close on server.lan under refc.**
  - A writer whose output to a host waits through that host's pass has no byte written for that whole time. At
    the worst samples that is the receiver's check, 28.6 s, and the host's I/O thread, 24.5 s.
  - Any further load on such a host crosses 30 s. The writer then closes the connection, and every call in flight
    on it ends `TRANSPORT_ERROR`.
- **Other modules' hosts are not affected.** Each has its own loop, and their Hellos and admissions reach the
  Runtime by the supervision thread.

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
- **The Package Manager** has no pool: its bounds (above) are its own, and it reaches its providers
  as one consumer, through the routes and Transport totals above.

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
- **The Package Manager's read deadline** (`package_manager.limits.read_deadline_ms`, 300000 by
  default, 1 to 86400000): it bounds one call to a Storage provider (`stat_object`, `read_object`,
  `fetch_readiness`) and the wait for `ready` after `not-ready`. It sits above the provider's own bound
  for one call (storage_module's longest is 180 s at its defaults), so it catches a provider that broke
  its bound; availability comes from the provider's `unavailable`, never from the deadline
  ([PACKAGE-MANAGER.md](PACKAGE-MANAGER.md) §4).
- **A payload module's figures** (its stop time, the shutdown grace its profile sets) are in §26.
- **Large packages and `logosctl --timeout`:** a maximal install or update passes the default 65 s on every host,
  and its client `TIMEOUT` leaves the outcome unknown (§12, "A large reply's passes").

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
  of the session holds everything, the evidence key's secret half included, and a payload module's
  keys (§26).
- **Restore:** a restored older `trust.cbor` is refused by continuity; a restored `state/` without its
  mark needs `logosctl trust reestablish`; a lost `state/` needs a new session ([DAEMON.md](DAEMON.md)
  §2, §6, §11).
- **Rollback of a state transfer:** a `move` takes no snapshot, so the operator's backup of `state/`,
  made with logosd stopped, is the rollback; a `copy` leaves the source in place.
- **Retention and deletion:** retirement keeps the state directory and is not deletion. The separately
  authorized deletion is `logosctl state purge`, offline; `logosctl state list` shows what is kept and
  where it came from ([DAEMON.md](DAEMON.md) §11). Physical erasure from storage media, snapshots or
  backups is not claimed (BCP l.401).
- **The storage failure model** (PM l.1725-1728; DECISIONS G445). A write is complete when it is synced
  and renamed into place, and a crash leaves either the old state or the new one. For the installation
  root ([§1](#1-package-manager)), an installed-state mutation is complete when its new `install/index`
  is in place:
  1. the new record's directory is written in full while nothing names it, and synced: on Linux from
     5.8 on ext4, one `syncfs` of the root's filesystem through a descriptor held since the start;
     elsewhere, a `fsync` of each file and each directory;
  2. the new index is written to a temporary file, synced (on Darwin with `F_FULLFSYNC`, which also
     flushes the drive's cache for every file synced before it) and renamed over the old one, and the
     directory holding it is synced.

  A crash before the rename leaves the old installed state; after it, the new one. The next start
  exposes only what the index names and deletes the rest. Where a filesystem refuses `F_FULLFSYNC`
  (some network and external filesystems), a commit is as durable as `fsync` makes it: the data has
  reached the drive, which may still lose its cache on power loss. Under `syncfs`, a write error
  anywhere on the same filesystem since the last commit, another module's included, fails the commit:
  that is the safe direction, and the installation can be tried again.
- **Verified-byte binding** (PM l.1176, l.1185): installed bytes stay while their record is named; the
  files are 0400 in 0700 directories, nothing in the Package Manager rewrites one, and a replacement is
  always a new directory. A process of the same user can still change them. Each use hashes a record's
  artifacts again, and the Loader hashes its own copy, so a change is caught, not prevented.
- **Repair of a changed record:** once an installed file no longer matches its signed digest, every
  operation that reaches the record fails `artifact-integrity-failed` and changes nothing, an install
  of the same package included. The repair is to remove the packages that depend on it, then the package
  itself, then install them again.

## 20. Non-production

Item 22 (BCP l.403-406; DECISIONS D27, G299). BCP l.403 names four non-production mechanisms. A
production logosd has none of them in force:

- **Development trust anchors:** an anchor of the trust file marked `development` is in force only while
  the switch below is on, and turning the switch off withdraws it at the next start (§5; DECISIONS G137).
  With the switch off, which a production deployment has, none is in force.
- **Relaxed debugging entitlements:** none exist.
- **Transport test hooks** (TRANSPORT §8.5): hook code exists only in test builds (the `lcnTestHooks`
  define; the flake check `no-test-hooks` searches every packaged binary for its marker), and a hook
  stays inert until its Runtime's host selects it by an in-process call ([CONFORMANCE.md](CONFORMANCE.md),
  "Test hooks").
- **Unknown-artifact analysis:** none: an artifact is loaded only with its daemon-config digest.

What the trust file's development switch gates are held to the same rule: development anchors, and two
mechanisms of this implementation, `policy: allow-all` and `test_hooks` in a test build of logosd. The
switch is protected
input, set offline with `logosctl trust development on`. With it on this deployment is
**non-production**: logosd's start log warns `NON-PRODUCTION`, and every `logosctl` output and socket
reply says so. The build mode enables nothing (BCP l.405): a packaged logosd has no test hooks and
refuses `test_hooks`, and a test build selects one only with the switch on. The switch weakens nothing
else (BCP l.406): continuity, the other anchors and the trust file's rules apply as with it off.

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
kit warns without it), and link it with its kit's export list (G341). A refc module whose handlers keep
GC'd values in the instance must be generated with `lcn-gen kit --confined`, which runs each instance
on a thread of its own (G335; measured in logosd too, both placements, `tests/test_logosd.nim`); in a
refc module without it, handlers on threads other than the loading one must not store GC'd values
(DECISIONS I71). The author's guide is [sdk/docs/MODULE-KIT.md](../sdk/docs/MODULE-KIT.md).

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
| trust configured separately by purpose | evidence key and package trust file apart, and no anchor's key an evidence key; no enrollment trust yet |
| direct loading only for trusted code | `init` writes `hosted_dynamic`; `direct_dynamic` is the operator's explicit choice (§8) |
| third-party native code behind a process or application isolation profile | `process` only, not a sandbox (§8); no profile with stronger controls yet |
| permissions denied unless allowed and enforceable | host-ambient only, enforced at admission; the policy decides (§7) |
| remote surfaces disabled | none exists (§4) |
| no fallback from a remote profile | no remote profile |
| only what the consumer may see is exposed | the Runtime's visibility rules |
| tickets, keys and credentials out of logs and messages | the logging rule (§23) |
| a launch fails rather than weaken isolation | §16 |
| cached results invalidated when their basis changes | grants and policy re-evaluated; the trust file, anchors included, read once per start |
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
  Logos-defined modules (RUNTIME l.292). logosd's composition holds no such module, and since 5-6a-1
  logosd refuses an operator module or declaration whose name begins with `logos_` ("modules: instance
  X uses the reserved module-name prefix logos_"; DECISIONS G490; [DAEMON.md](DAEMON.md) §3). A host
  that configures one anyway still cannot start it: a provider is bound only once its call surface is
  accepted, a `logos_` module name is accepted only for a Logos system module, and the Runtime treats as
  one only its own static registrations (the Module Loader's and the authority's) and the instance the
  host configuration's `package_manager` marks. A Module Host, and the realizer of a `direct_dynamic`
  artifact, bind without that option, so the start fails `abi-invalid`: the name "is reserved for Logos
  system modules".
- **What is not refused** by the Runtime: a module that provides no contract has no call surface to
  accept, so one named `logos_credential_store` binds under a host other than logosd. It serves no
  Credential Store operation, so it is no Credential Store.
- `tests/test_deployment.nim` checks the facts' `credential_store`, the default composition, logosd's
  refusal of the operator module and the refusal at binding.

## 26. Payload modules

Not an item of its own. What items 6a, 8, 9 and 13 answer for logosd holds for every operator module; a
payload module built on the kit adds where it may be placed, what it takes from its realization, its
state, its stop figure and its network behaviour apart from its peers (BCP l.370). The module's README
gives the same answers. Nothing here changes a row of the item table.

### blockchain_module

The Logos blockchain node as a module (DECISIONS G419–G424; contract v2, frozen, G469–G476, G479 and G481; the
library's `logos_module/README.md`).

- **Placement** (DECISIONS G421): `hosted_dynamic` with placement `process` only, one node per
  process. The library's threads outlive `_MODULE_destroy`, so a host must never unload the library and
  must end with `_exit` after the release; logosd's Module Host does both. Run it `hosted_dynamic`: in an
  embedder's own process the library's signal handling, its HTTP API and any fault of the library all
  belong to the embedder (below), and `direct_dynamic` would leave the library's threads in logosd's
  process. Under an embedder with an ordinary SIGINT handler, the library's handler replaces it. Nothing
  refuses another placement while NP-14 is open (a module cannot declare the placements it supports, and
  its init is not told its placement): the operator's daemon-config decides, and the node profile (Tier 5
  step N-6a) sets `hosted_dynamic`.
- **Signals.** The node is started with the library's stock start, whose `SystemSig` service takes the
  process's SIGINT at the start and keeps it: a SIGINT to the node's Module Host stops the node, and the
  instance goes to `error` (`reported-by-module`) as for any stop of the inner node. It takes no other
  signal. logosd ends a Module Host with SIGKILL, which no handler sees.
- **The HTTP API.** The stock start always starts the library's HTTP API, and the module puts it on
  `127.0.0.1` at a port the system picks at each start; no setting moves it or turns it off. The API has
  no authentication. Any local process of any user, other modules' hosts included, that finds the port
  can spend from the node's wallet, sign any payload (`/wallet/sign/ed25519`, `/wallet/sign/zk`), claim,
  post SDP declarations, add transactions, start and stop PoW mining and auto-claim, change the log
  filter and dial peers. None of that passes the Runtime, the policy classes or the Capability Authority.
  The API refuses web pages by their `Origin` and `Host`, not local programs. The module's README lists
  every route. Run the node only on a machine where every local user is trusted.
- **Resources** (D5 for blockchain, DECISIONS G422): the module takes only its typed configuration
  (`blockchain_config.cddl`, delivered at init), and no home directory. The library reads 24 environment
  variables of its own in place of that configuration (the README names them), so init refuses to start
  while any of them is set, empty or not, naming it: `runtime.module_host_env` must not list them. The
  chain's deployment is built in, or a read-only file the configuration names, with an optional SHA-256
  that init checks (DECISIONS G441). Its circuits are compiled in, and it logs to standard error, which
  its Module Host inherits (§23). It runs one tokio worker per CPU; `TOKIO_WORKER_THREADS` in
  `runtime.module_host_env` sets fewer. Mining and auto-claim are configuration (`pow`), applied at
  start: turning mining on or off is a new value and a restart (DECISIONS G474). On Linux its prover
  (rapidsnark, as the circuits' prebuilt archive ships it) also logs each proof, about 1.4 KB of phase
  names, to `MyLogFile.log` in the working directory. While the node runs, the module's process works
  in its state directory's `prover/`, and the module empties that file in place past 1 MiB (DECISIONS
  G421, G422). Its permission settings must
  hold `logos-core-nim.host-ambient` (§7; [DAEMON.md](DAEMON.md), "Grants"); with it, its host has the
  access of logosd's user (§8, 8b).
- **State** (§9): its state directory `state/modules/<assignment>/` holds `keystore.yaml` (0600: the
  node's keys, which the library makes at the first start, or placed before it; rewritten only by the
  key methods, through a synced copy, `keystore.yaml.tmp`, renamed over it, DECISIONS G473),
  `key-import` (a key the operator placed, until `add_placed_key` takes it), `spends.cbor` (0600: the
  spend records, kept at least ten minutes each, 1024 at most, rewritten through `spends.cbor.tmp`;
  DECISIONS G472), `node/` (the library's database), `run/` (the configuration rendered for the library,
  rewritten at each start, no secret) and `prover/` (the process's working directory; on Linux, the
  prover's log). The keystore is the node's identity and the key to its funds, protected by its
  mode only (§19). Each key method leaves the old keystore's blocks free but not erased, and the
  overwrite of `key-import` is best effort: an operator who needs more puts the state directory on an
  encrypted volume. A `state_transfers` entry with `copy` clones it: two instances then hold one identity
  and spend the same funds. `move` hands it over. The key methods change the keystore the node reads at
  its next start, never the running node; they and the spends are local only (the `keys` and `spend`
  classes, `remote: never`, DECISIONS G476).
- **Stop figure** (DECISIONS G423): `_MODULE_init` starts the node and `_MODULE_destroy` stops it,
  joins its work before returning and awaits no posted callback. Measured unprepared destroys: 1.2 ms on
  macOS and 1.3 ms on Linux for an idle node, 0.5 to 670 ms under logosd in a Module Host. A library call
  in flight holds destroy until it returns. Destroy starts no new spend, records the queued ones
  cancelled, and waits for the running one and the spend records' writes (DECISIONS G471); the slowest
  spend measured took 425 ms (G475), and a spend cut by a kill reads `interrupted`, its outcome
  unknown until the chain is read (G472). The default `runtime.stop_deadline_ms` (10000) holds. A
  daemon-config that runs the node sets `runtime.shutdown_grace_ms` to 20000, the node's figure (§13);
  the node profile (Tier 5 step N-6a) will. An inner node that stops by itself makes
  every method answer `unavailable` (`node-stopped`) and reports one failure: the instance is `error`
  (`reported-by-module`) and a restart policy recovers it.
- **Network behaviour apart from its peers** (BCP l.370):
  - **Time.** The node asks the NTP server `time.ntp_server` at start and every `time.update_interval`
    (15 s when absent), one request to each address the name resolves to. An unreachable server leaves
    the slot timer on the local clock, with one warning each interval. `127.0.0.1:9` is the offline
    value: an IP literal, so no resolver is asked, and nothing answers.
  - **NAT.** With `network.nat` `static` the node sends nothing to the network's gateway. `traversal`
    turns on the library's NAT behaviour: a gateway lookup, autonat, and port mapping through PCP,
    NAT-PMP and UPnP.
  - It listens on `network.listen_host` and `network.port`, and on `blend.port` once the blend
    membership reaches the era's minimum size; it dials `network.initial_peers`. Its HTTP API listens on
    a TCP port on `127.0.0.1` (above).
- **Bootstrap period.** With `cryptarchia.prolonged_bootstrap_period` absent, the library's hour
  applies: for that hour a fresh node's `mode` is `bootstrapping` and it does not lead. A value set is
  logged once at start.

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
