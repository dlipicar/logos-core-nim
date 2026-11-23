# The Package Manager: catalog, retrieval and trust in use

What this implementation chooses where PACKAGE MANAGER leaves the choice to it: the catalog
document, how it is acquired and refreshed, catalog policy (PKG-0472, PM l.834-835), the Storage
bindings and retrieval, and how trust is applied when a package is inspected. Each choice keeps the
verification of PM §4.1 to §4.4 (PKG-0473): nothing here replaces a package's own signature, adds
trust or claims freshness. The decisions are DECISIONS G399 to G406 and, for installation, G444 to
G447 and G450 to G453; the code is `src/logos_core/pm/`.

Tier 5 step 5-3b builds the engine (5-3b-1) and the module that hosts it (5-3b-2). Step 5-5 builds
installation: 5-5-1 the installed records, the responses, the handoff's construction and the admission
bound (§8, §12, §13); 5-5-2 the store's root and extraction (§8, §9); 5-5-3 the worker and the spool
(§10); the operations (§11) follow. Step 5-6a-1 makes it the module `logos_package_manager`, which
logosd composes as the reserved instance `package_manager` (§14); 5-6a-2 serves the system callers'
methods, and 5-6b `list_packages`.

## 1. Placement and the data path

- **The engine** (`pm/`: input, catalog, fetcher, verification cache, resolution driver, engine) is
  core's, beside `package/`, the Capability Authority and the Loader. It does no I/O: it is a state
  machine over commands (calls, route operations, timers, the kept-catalog write, replies, log lines)
  and events. The module shell (`pm/shell.nim`, G405) carries them out through the module kit: it
  runs on the instance's module thread under chronos (G335), holds one route per binding through its
  Runtime Control binding, and queues the engine's events, so no engine step runs inside a kit
  callback. The module `logos_package_manager` (§14) wraps it; the test module `pmtest_module` keeps
  `status`, `resolve`, `install` and `handoff` for the suites (G496).
- **Payloads go between module processes.** The Package Manager's Module Host establishes its own
  routes to its Storage providers through its Runtime Control binding, as any consumer does, and the
  catalog and archives travel over those routes from the provider's process to the Package Manager's.
  logosd issues the routes and decides their Hello; it never carries a catalog, an archive or the
  trust input.
- **No storage library** (G406). The Package Manager reaches Logos Storage only through
  `lcn.storage_fetch` (STORAGE-FETCH; DECISIONS G395), which storage_module provides. No storage
  library is a dependency of this repository or linked into the Package Manager:
  `tools/lint/nostorage.py` (the flake check `lint-nostorage`) refuses one in any nimble file's
  `requires`, `nimble.lock`, `nix/nimble-deps.json`, `flake.nix`'s inputs, `flake.lock`, and the link
  and build pragmas of `pm/`, `package/` and their import closure; its deny list is
  `tools/lint/nostorage.toml`. `layers.toml`'s `pm_external_allowlist` names the external packages that
  closure may reach (`results`, `zlib`), so a storage library under another name fails too.

## 2. The protected input

The Package Manager's configuration is protected deployment input (G399). It has no module
configuration: configuration must not carry protected trust input (CONFIGURATION l.58). It receives
one Logos deterministic-CBOR value, `lcn.pm_input` (`src/logos_core/pm/input.cddl`), closed:

| Field | What |
|---|---|
| `format` | `"logos-core-nim.pm-input.v1"` |
| `trust` | the package trust file's accepted bytes (DAEMON.md §6), 1 byte to 1 MiB |
| `storage` | the Storage bindings, at least one: `{binding, instance}`, names unique |
| `catalog` | the protected catalog: `{storage, object, digest}` (§3) |
| `resolver_limits` | the four resolver limits (PM §11), required: the Package Manager has no default |
| `limits` | optional bounds, below |

The Package Manager checks the input itself, whoever wrote it, and refuses all of it on the first
failure: the format, an empty `storage`, a binding named twice, a `catalog.storage` that is no
binding, a bound or a resolver limit out of range (CONFORMANCE, "Resolver limits"), and trust bytes
that `trustdoc` refuses. A trust file that selects a
catalog or a provenance profile is refused here as at logosd's start (G398, G404), so the Package
Manager does not start with one.

| Bound | Range | Default | What it bounds |
|---|---|---|---|
| `archive_bytes` | 1 to 1,073,741,824 | 1 GiB | one archive, spooled to the state directory and read in pieces, never held in memory (§10); the other LGX bounds keep G75's proportions to it (G453) |
| `catalog_bytes` | 1 to 4,194,304 | 4 MiB | the catalog document |
| `catalog_entries` | 1 to 65,536 | 65,536 | the catalog's entries |
| `cache_entries` | 1 to 4,096 | 256 | the verification cache (§5) |
| `read_deadline_ms` | 1 to 86,400,000 | 300,000 | one call, and the wait for `ready` after `not-ready` (§4) |
| `operation_entries` | 1 to 16,777,216 | 262,144 | the records, dependency entries and contracts one root operation reads (§4, G477) |
| `operation_deadline_ms` | 1 to 86,400,000 | 3,600,000 | one root operation, from taking its slot (G449; checked from 5-5-4) |

**The channel** (G400). The value is the instance's protected realization input: the host
configuration's `protected_inputs` names the instance and carries the bytes, and the Module Loader
writes them to `<state_dir>/.lcn-protected-input` before each realization attempt's initialization and
removes the file when it returns ([HOST-CONFIG.md](HOST-CONFIG.md), `protected_inputs`). The Package
Manager reads the file once, during `_MODULE_init`, and keeps no copy of it. It is not configuration:
no Runtime Control method reads or changes it. Without a state directory or without the file,
initialization fails. A refused input fails `_MODULE_init` with `MODULE_ERROR`; the Runtime records
only that code, and the Package Manager's log line names the field ("package-manager: initialization
failed: lcn.pm_input is refused: …").

**In logosd** the value comes from daemon-config's `package_manager` section ([DAEMON.md](DAEMON.md)
§3; G399): the bindings, the catalog and the bounds as the operator wrote them, the resolver limits
it names or logosd's preset, and the trust file's bytes as that start accepted them. logosd runs the
Package Manager's own decoder on the value before it starts anything, so the instance's check is the
second one. A trust change therefore reaches the Package Manager at the next start.

## 3. The catalog

### The document

A catalog document (G401) is one Logos deterministic-CBOR value, unsigned, `lcn.package_catalog`
(`src/logos_core/pm/catalog.cddl`):

```cddl
lcn.package_catalog = {
  format: "logos-core-nim.catalog.v1",
  sequence: uint64,
  entries: [* logos.package_manager.package_catalog_entry],
}
```

- **Entries** are PM §6's catalog entries, `{identity, source}`: location data only (PKG-0115). The
  entry rule is the pinned one, so an entry with any other field (a signer, a key, a hash) is refused.
  A candidate reached through an entry is judged by its own manifest, signature and artifacts, and a
  catalog entry, Storage metadata or a locator that disagrees with the manifest never overrides it
  (PKG-0019, PKG-0069).
- **Order:** entries are in canonical order: package-name UTF-8 bytes ascending, then SemVer
  precedence descending (the order of PM l.1657), then the source record's deterministic-CBOR bytes
  ascending. Each `{identity, source}` appears once. One identity may have several sources (PM
  l.1329-1330), each judged on its own.
- **Bounds:** at most `catalog_bytes` and `catalog_entries`. The size `stat_object` states is checked
  before any byte is read.
- **Refusals** refuse the whole document and change nothing: a digest other than the pinned one,
  bytes that are not deterministic CBOR, an unknown or missing field, another `format`, an entry the
  PM §6 rule refuses, a break of the order, a repeated entry, a bound.
- **Kinds:** an `lgx` entry names a binding (`storage`) and a locator (`object`). A `nix` entry is
  kept in the document and never used: no Nix realization profile is built (PM l.886-887), so an LGX
  operation finds it `unsupported-source`.

`lcn-pkg catalog SOURCE.edn --sequence:N [--out:catalog.cbor]` writes the canonical document of the
entries in SOURCE (CBOR diagnostic notation, any order), refuses a repeated entry and any document the
Package Manager would refuse, and prints the document's BLAKE3-256 digest. It signs nothing.

### The protected catalog, and catalog policy

The protected catalog (PM l.1328, l.1331) is the document the protected input names by binding,
locator **and BLAKE3-256 digest**. Bytes whose digest is not the pinned one are refused before they
are decoded. The digest makes the document exactly the operator's choice whatever a provider serves:
a provider that substituted another document could otherwise steer resolution to an older version that
an accepted anchor still signs, which the baseline cannot detect (PM l.467-469).

Catalog policy (PM l.834, l.1328): none. Two acceptable manifests for one identity with different
commitments fail `dependency-unavailable`, as PM §11 resolution does.

### Acquisition, and no refresh

- The catalog is read once its binding's provider reports `ready`: `stat_object`, then `read_object`
  in steps (§4). A read that fails is tried again on the provider's next `ready`, and after a back-off
  (1 s, doubling to 60 s) while the provider stays `ready`. One accepted or refused document ends
  acquisition for that start.
- **There is no refresh.** A locator names the same bytes for one provider (STORAGE-FETCH §3), and the
  digest pins them, so reading the configured locator again can never give a newer document.
- **A new catalog is a new locator and digest.** Publish the document to Storage, set the locator and
  the digest `lcn-pkg catalog` printed in the daemon configuration, offline, and restart logosd: a new
  catalog applies at logosd's next start, as every protected input does (DEPLOYMENT §2).
- **The cost:** a new package version needs a new catalog, and a new catalog restarts every module of
  the node.
- At start the Package Manager never waits on Storage. Until a catalog is in use, an operation that
  needs one fails `package-unavailable`, never as if the catalog were empty (PM l.1308-1309), and
  nothing installed is invalidated (PM l.480).

### The kept catalog, and the sequence

- **The last accepted document is kept** in the Package Manager's state directory, `catalog.kept`
  (`lcn.pm_catalog_kept`: format, binding, locator, digest and the document), written by sync and
  rename. The catalog is in use whether or not that write succeeds.
- **At start**, the kept document is in use only while its locator and digest equal the configured
  ones. Otherwise there is no catalog until the configured document is read: a kept catalog never
  stands in for another configured one. A kept file that does not decode is set aside and logged.
- **The sequence orders documents. It claims no freshness** (C9; PKG-0112). A document read is
  accepted when its sequence is greater than the kept one's, or equal with equal bytes. A lower
  sequence, or an equal one with other bytes, is refused and logged, and there is no catalog until the
  configuration names an acceptable document. This protects against a mistyped or restored
  configuration and nothing more: no field, result or log line calls a sequence, a document or a
  signature fresh, newest or unrevoked.
- **A deliberate rollback:** a lower sequence is refused even for a document pinned on purpose. To go
  back to older entries, publish them in a new document under a higher sequence and pin that one. Do
  not delete `catalog.kept` to get there.
- **After the state directory is lost**, the first document read is accepted: no freshness is
  claimed, so none needs to be re-established (PM l.478; PKG-0091, PKG-0092).

## 4. Bindings, retrieval and locators

**A binding** is a name and an `lcn.storage_fetch` provider instance (§2). An LGX source's `storage`
names a binding, and its `object` is a locator that binding's provider reads (PM l.854-857). A source
naming no configured binding has material that cannot be located: the candidate is unavailable, and
the name is logged once per start. Reusing a source in another deployment needs the same binding names
and providers that read its locators the same way (PM l.858).

**Routes** (G402). At start, the Package Manager establishes one route per binding to the binding's
provider, then subscribes to `fetch_readiness_changed_event` and calls `fetch_readiness`. A route
names a provider record, whose id the Runtime assigns, so before each establishment it looks up the
binding's instance with `list_modules` and takes that record's provider.
- **Every establishment has a new request key**, 128 random bits. A replay returns the retained result
  and revives nothing (R l.3072-3082), so a fixed key would hand a lost route's record back. A key is
  reused only to retry an establishment whose response was lost (at most three times).
- **A lost route** (its `onRouteEnd`, or a call that finds the route unusable) is renewed under a new
  key (`renew_route`, then `materialize`). A renewal refused as unknown, closed, failed or revoked
  releases the route and establishes a new one.
- **A refused establishment** is tried again after a back-off: 1 s, doubling to 60 s. Until a route is
  ready, the binding's material is unavailable.
- Route upkeep stops when `_MODULE_destroy` begins (G437).

**Retrieving one object** (the catalog or an archive), one object at a time per binding:
1. `stat_object`. A size over the bound (`catalog_bytes` or `archive_bytes`) is refused before any
   read. **`unavailable` is not retried**: the provider has spent its whole lookup bound on that call.
2. `read_object` in 1 MiB steps, one after another. The catalog is kept in memory and its BLAKE3-256
   digest computed while reading; an archive's pieces go to the worker, which appends them to the
   archive's spool file and hashes them (§10).
3. `unavailable` from a `read_object` after a successful `stat_object`: the same offset again after a
   back-off of 1, 2 and 4 s, at most three times in a row. A locator names fixed bytes, so a read
   resumes from its offset.
4. `not-ready`, or a route lost during a call: the same call once the provider reports `ready` or the
   route is back, the wait bounded by `read_deadline_ms`.
5. Anything else ends the retrieval as unavailable: `invalid-locator`, `out-of-range`,
   `invalid-length`, an invocation error, a call past its deadline, or data other than
   `min(length, size - offset)` bytes. The provider's `detail` is logged as foreign text.
6. The bytes are untrusted until verified: the catalog by its pinned digest and decoding, an archive
   by the inspection pass over its spool file (§10; PM l.389, l.397, l.443-444).

**The deadline,** `read_deadline_ms`, 300,000 ms by default, bounds one call (`stat_object`,
`read_object` or `fetch_readiness`) and the wait for `ready` after `not-ready`. A single `read_object`
against storage_module can take its lookup bound plus the wait for blocks: 120 s for a direct
retrieval and 180 s for a private one at its defaults. So 300 s is above one call's longest time,
and above its 120 s network phase for the wait after `not-ready`. The deadline catches a provider that
broke its own bound: availability comes from `unavailable`, never from the deadline. A deployment that
raises a provider's bounds raises this one too.

**`provenance_object` is never read** (PKG-0167; until step 5-11). A source with one inspects and
resolves exactly as the same source without it, and no call names its locator.

**Resolution over retrieval** (G405, G455). A root operation's resolution is a resumable run that the
driver holds for the operation's life, on the module thread:
- **A turn** of the run ends where it needs a candidate's inspection, which the engine retrieves as
  above and supplies; where it needs an installed record's retained-bytes answer (5-5); or once
  `ResolverTurnWork` units of work are spent. The run's first turns are its setup over the catalog.
  After a spent turn the engine issues `cmContinue`, and the shell runs the next turn from a
  `callSoon` of its own, one event-loop poll later. So route answers, timers, readiness events and
  other operations go between two turns, and two operations take turns one after the other.
- **Nothing is rerun** from the root. The candidates retrieved are exactly those one synchronous
  resolution reaches, in its order (PM l.1294-1295, l.1310), and the budget changes no outcome or
  counter (l.1279-1280).
- **After the reply** the run's state is freed a turn at a time, by continues of their own.
- **A caller that gives its operation up** (its future cancelled) cancels it: it takes no more turns,
  its queued retrieval is dropped, and nothing answers it. A continue that arrives for it is ignored.
- At `_MODULE_destroy` each operation still running is answered `package-unavailable`.
- **The operation bound** (G477): the run counts the inputs it reads, a unit for each record read
  (inspected or installed), for each of its dependency entries, for each contract an entry lists and
  for each contract it provides, each record once (one walk, `inputUnits`). A count equal to the bound
  goes on; the read that takes it over ends the operation with `package-unavailable` (PM l.1308-1309),
  and the caller's message does not state the bound. The four resolver limits and their counters are
  untouched. The bound is `operation_entries` (§2), passed to every root operation; when it ends one,
  the operator's log names the key and its value.

The locator encodings of each provider are STORAGE-FETCH §5's table. In logosd the bindings are
`package_manager.storage` ([DAEMON.md](DAEMON.md) §3), each naming a `hosted_dynamic` instance that
provides `lcn.storage_fetch`; the system rules S9 to S11 grant the routes to those instances, the
three calls and the event, and `list_modules`, which is not narrowed to them (DAEMON.md §5).

## 5. Trust in use, and the verification cache

- **The trust input** is the package trust file's accepted signing anchors, fixed for one start. A
  candidate is eligible only when its own `manifest.cose` verifies under an anchor in force that
  authorizes its exact package name (PM §4.1, §4.3). Nothing a catalog, an archive or a Storage object
  holds adds, replaces or reactivates an anchor (PKG-0081, PKG-0082), and a detached signature beside
  an archive verifies nothing (PKG-0114).
- **The verification cache** (G403; PKG-0076) holds one entry per verified archive, keyed by the
  BLAKE3-256 of its bytes: the signer (profile, kid and key), the identity, the manifest commitment,
  the selected variant and the resolver's inspection. It is in memory only, at most `cache_entries`,
  least recently used first out. Only an archive that verified is cached. Archive bytes are not
  cached: each candidate reached is retrieved again, and a hit spares only its verification.
- **Its byte bound** (G447): an inspection over 256 KiB by its estimate answers its call and is not
  cached (the counter `uncached`), so the cache holds at most `cache_entries` × 256 KiB, 64 MiB at the
  default. The estimate is fixed by rule over the resolver's walk (G477), a constant for each record,
  dependency entry and contract plus the bytes of its strings and encodings, so the same archive is
  cached, or not, on every machine. No honest manifest comes near it.
- **Every hit is judged again** (PKG-0077): the entry stands only while the trust input in use has an
  anchor with the same kid, holding the same key, under the same profile, authorizing the exact
  package name. Otherwise it is dropped and the archive is opened again, which then fails
  `signature-verification-failed`. Removal, revocation, a withdrawn name, a withdrawn development
  anchor and a new key for the same kid each drop the entries they affect, and only those.
- **Rotation** (PKG-0079): two anchors authorizing one name are both in force while the trust file
  lists both, so an archive signed by either verifies. The operator ends the overlap by removing the
  old anchor in a later revision (`logosctl trust anchor remove`); after that only the new one
  verifies. A removed anchor is not used, cached or not (PKG-0080's inspection half).

## 6. The baseline, and what it does not provide

This implementation applies the mandatory package-signature and artifact-verification baseline
(PM §4.1, §4.3, §4.4) and selects no catalog profile (§4.2) and no provenance profile (§4.5) (G404):

- it provides **no authenticated catalog ordering, freshness or external anchoring** (PKG-0449,
  PKG-0085). The catalog is unsigned; its sequence orders documents and claims nothing more;
- it claims **no package provenance** (PKG-0167);
- a trust file that selects either profile is refused, at logosd's start and by the Package Manager
  (PKG-0086, PKG-0087, PKG-0090). No catalog field can carry a profile, key, log, checkpoint or minimum
  version: the document is closed;
- no revocation list, minimum version or freshness evidence can be required, so none is enforced,
  kept or re-established (PKG-0089, PKG-0091, PKG-0092). Signer state is the trust file's revision,
  which is continuity, not freshness;
- a failed catalog read keeps the catalog in use and invalidates nothing (PKG-0093). The only active
  trust requirement is the signature under the accepted anchors, checked on every use (§5).

## 7. Failures

| Situation | Outcome |
|---|---|
| no catalog in use | `package-unavailable` (PM l.1308-1309) |
| a source names no configured binding | the candidate is unavailable; logged once per start |
| a route not established, or refused | the binding's material is unavailable |
| `stat_object` answers `unavailable` | the candidate is unavailable, after one call |
| `read_object` answers `unavailable` four times in a row | the candidate is unavailable |
| a size over its bound, any other failure of §4's step 5 | the candidate is unavailable |
| an archive that does not verify | the candidate is ineligible, with its error |
| a selected module's configuration declaration that does not resolve | the candidate is ineligible: `invalid-package` (PKG-0060, §13) |
| every candidate of a root unavailable | `package-unavailable`, never proof that a candidate is invalid |
| a `nix` source in an LGX operation | `unsupported-source` |
| a catalog document refused | logged; the catalog in use, if any, stays; no catalog otherwise |
| `catalog.kept` that does not decode | set aside and logged; no catalog until one is read |
| a trust file that selects a profile | the Package Manager does not start: `_MODULE_init` fails, and its log names the field |
| no protected input, or no state directory | the Package Manager does not start |

## 8. Installed state

- **An installed record** is PM §5's `installed_package_record`: the retained signer, the identity,
  the source, the selected variant, the manifest commitment, the selected module declarations in
  manifest order (PM l.814-816), the selected variant's artifacts (l.1172) and one recorded edge per
  direct dependency, in declaration order (l.1337-1341). It is built from a verified package only.
- **`local_path`** is one artifact file's absolute location, `<record's a/ directory>/<path>`, where
  `path` is the artifact's path in its variant. The record file keeps the relative paths, and the
  absolute ones are rebuilt from the current state directory at each start.
- **The record file** (`pm/installed.cddl`, `lcn.pm_installed_record`) holds `format: 1`, the record
  as its deterministic-CBOR bytes, its generation (from 1; a signer replacement writes the next) and
  the BLAKE3-256 of the archive it came from, for diagnostics. `installed.cddl` stands alone in the
  `lcn` namespace, and App A's types are checked apart (BCP-0104). **Every load checks it** against
  that text, its record against App A's record rule, then against its signed manifest: the same
  identity and commitment, the variant's artifacts exactly as signed, the selected declarations
  unchanged and in order, one edge per dependency (G445).
- **The index** (`lcn.pm_installed_index`) names the committed records: `format: 1`, the count of
  commits, and `{rid, generation, package, version}` per record, sorted by package name bytes, then
  version text bytes, each identity and each rid once. It is read within 64 MiB, at least 200,000
  records at the longest identities.

### The root and the store (5-5-2; `pm/store.nim`)

- **The root** is `<state_dir>/install/`, in the instance's own state directory (G444; its scope is
  the owner's Q5 (a)). `lock` is held for the store's life, so a second instance on the
  same root does not start (PKG-0487). `index` is the committed set. `r/<rid>/` is one record:
  `a/<path>`, the selected variant's files; `m/manifest.cbor` and `m/manifest.cose`, the signed bytes;
  `m/record.<g>`. `spool/` holds the archives being retrieved and judged (§10). `rid` is 128 random
  bits, never reused.
  Directories are 0700 and files 0400; nothing is made executable or rewritten.
- **Path rules:** the host's, made case-insensitive when a probe in the root finds the filesystem
  folds case (PKG-0489). Every path of the variant, and every directory prefix, is checked under them
  before anything is written.
- **Staging** writes a record's directory in full and syncs it while nothing names it: the paths and
  the admission bound first, then the files (§9), the signed manifest and `m/record.1`. A signer
  replacement writes `m/record.<g+1>` beside the committed one.
- **The commit** is one `writeAtomic` of the index (PKG-0610). Before it, the staged files are on the
  medium: on Linux from 5.8 on ext4, one `syncfs` on the `install/r/` descriptor held since the start;
  elsewhere a plain `fsync` of each file and directory, ending at `r/`, and on Darwin the drive flush
  is the index's own `F_FULLFSYNC`. An identity is installed once (PKG-0182). A crash before the rename
  leaves the old state, after it the new one (PKG-0611).
- **The start** runs at `_MODULE_init`, before the worker starts; a root that cannot be opened fails
  initialization. The lock, the probe, then the index. No index and an empty `r/` is a fresh root; no
  index while `r/` holds entries stops the start and deletes nothing. Each named record is loaded,
  checked against its signed manifest and its admission bound at the current path (PKG-0471); a
  failure stops the start and names the identity. Then what no record names is deleted.
- **Retirement:** what a commit stops naming is deleted once no holder of an older snapshot that reads
  files remains: the engine sends the collect to the worker (§11), which refuses a directory its index
  still names.
- **The retained hash** (`checkRetained`; PKG-0181, PKG-0293): each artifact file, opened below `a/`
  with no link followed, against its signed digest. A packaged native library is one of them.
- **A damaged record** fails every operation that reaches it with `artifact-integrity-failed`; the
  repair is to remove its dependents and it, then install them again (DEPLOYMENT §19).

## 9. Extraction

Part 5-5-2 builds the writing, part 5-5-2b the reader and part 5-5-3 the spool it reads from (§10).

- **Descriptor-relative** (`pm/extract.nim`; PKG-0204, PKG-0274): the record directory is made with
  `mkdirat` under the `install/r/` descriptor; each directory below it with `mkdirat` and opened
  `O_DIRECTORY | O_NOFOLLOW` relative to its parent; each file created `O_EXCL | O_NOFOLLOW`, 0400, and
  written in 1 MiB chunks. No link is followed, nothing outside the record's directory is named, and the
  destination stays within the root by construction.
- **An existing name or a planted link** fails: `artifact-integrity-failed`, "escaped their
  realization root". A write that fails for room or I/O is `package-unavailable` (PM l.1094). Either
  way the directory is deleted, at once or at the next start.
- **What is written** is the selected variant's declared artifacts, every regular file of it (l.963):
  no other variant, nothing executed, built or scripted (PKG-0499). Nothing names the directory until
  the commit (PKG-0219, PKG-0292).
- **The stop flag** is checked between chunks and between files.
- **Reads below a record** (the retained hash, the handoff's schema and default) open each component
  with `O_NOFOLLOW` and require a regular file at the end.

**The reader** (`package/lgx.nim`; 5-5-2b, G446). An archive is read in one pass of 1 MiB pieces, from
a file or from bytes, and never inflated whole:
- **Inspection** (`inspectLgx`) keeps the two manifest files, each entry's path, kind and size, the
  digest of each of the selected variant's files and that variant's contract and configuration
  documents, and no artifact's bytes. So its memory does not grow with the archive: 11 to 13 MiB for an
  archive of 1 GiB (CONFORMANCE). The format checks run in stream order, the content checks after them
  in the order DECISIONS G29 states, and every result is the earlier reader's but one: the documents'
  total below. Four kinds of message can differ (G29).
- **The documents' total:** the selected variant's kept contract and configuration documents are at
  most 64 MiB in all, a fixed bound of the LGX table (G75), not derived from `archive_bytes`. Past it
  the package is `invalid-package`; nothing over the bound is read into memory. A contract document is a
  few kilobytes.
- **Extraction** (`extractLgx`) reads the same source again with the same checks, writes each of the
  selected variant's files as it is inflated, and checks each against its signed hash at its end. The
  record's manifest, signature and fields come from the inspection, not from the file. A source that no
  longer gives the judged package (another file, a changed byte, a truncation) fails the staging, and
  its directory is removed; the operation will answer `package-unavailable` (5-5-4).
- **Where it reads from:** the worker runs the inspection pass over the archive's spool file (§10), so
  no archive is held in memory. `openLgx` over bytes in memory stays for tools and tests.

## 10. The worker and the spool

Part 5-5-3 (DECISIONS G446's spool half, G447; `pm/worker.nim`, `pm/jobs.nim`, `pm/spool.nim`).

- **One worker thread per instance** reads and writes archives, so none is written, read or judged on
  the module thread. It starts at `_MODULE_init`, after the store's start, with its own copy of the
  trust input, the platform, the LGX limits and the path rules for that start; a thread that cannot be
  created fails initialization. Its jobs run one at a time, in order. Its answers reach the module
  thread through the kit's `post`, one drain at a time; it never calls the kit otherwise.
- **Nothing that crosses holds a reference** (checked at compile time). A judgment crosses with its
  contracts as their deterministic encodings and is decoded on the module thread at most 1,024
  dependency entries and contracts a turn, between other events, so a 4 MiB manifest never takes one
  long step. Under orc a message is moved; under refc it is copied, up to about 23 ms for an
  80,000-entry judgment (CONFORMANCE).
- **The spool** is `<state_dir>/install/spool/`, 0700, emptied by the store's start. Each archive
  retrieved goes to its own file there, `<request>-<n>.lgx`, created 0600 and exclusively, never
  following a link. The fetcher hands each 1 MiB answer to the worker, which appends and hashes it; at
  most four pieces of one retrieval are unwritten, then the next read waits. At the end the digest is
  looked up in the verification cache: a hit answers at once, a miss has the worker judge the file.
  Either way the file is deleted. Nothing in the spool is executed, mapped or synced.
- **Its share:** the archives spooled at once are at most 4 × `archive_bytes` in all, 4 GiB at the
  default. A retrieval whose archive would pass it waits, first in, first out, until a file is deleted;
  the first always fits. A mutation keeps its selected archives for extraction under a budget of its
  own (§11), so the host's spool is at most 8 × `archive_bytes` ([DEPLOYMENT.md](DEPLOYMENT.md) §12).
- **A full disk:** a spool write that fails makes the archive unavailable, as a failed read does (PM
  l.1094), so its operation fails `package-unavailable`; the operator's log names the state directory's
  file system and the cause. It is not resource exhaustion.
- **At `_MODULE_destroy`** the worker stops after its current piece or header, deletes its spool files
  and is joined before the instance's state is freed. The destroy comes once the instance's calls have
  ended; an operation's call ends at a stop through the Runtime's cancel (§11), so a stop takes the
  cancel, the destroy, then one piece.

## 11. The operations

Part 5-5-4 (DECISIONS G448, G449; `pm/slots.nim`, `pm/engine.nim`). They are reached through the
module's methods (§14), whose kit has the asynchronous provider API, so that a caller's cancel and a
stop reach the operation.

- **Two slots:** one installed-state mutation at a time (`install_package`, `remove_package`,
  `update_package`) and, beside it, one `inspect_package`; neither waits for the other. Each runs first
  in, first out, and holds at most 16 waiting requests: the 17th is refused at once with the
  invocation error `MODULE_ERROR` (PM l.1516-1517), before any work. A waiting request that is
  cancelled, or whose caller's route ends, never runs.
- **A snapshot** of the installed state replaces the last after each commit, and nothing reads a
  partial one (PKG-0410). An operation reads the one current when it takes its slot, until it ends; a
  directory a later commit retired stays while a snapshot that names it is held.
- **`inspect_package`** resolves the complete closure against the snapshot and writes nothing. Its
  root's record is the one the worker judged, with the signer its verification established.
- **`install_package`** installs each missing package of the closure, dependencies first, each
  extracted and committed on its own, the root last. A failure stops there: the dependencies committed
  before it stay, and the root is not installed. The root installed with the same commitment answers
  its record; if the selected source verifies under another accepted signer, only the record's signer
  is replaced (PKG-0608). Installed with another commitment, it is `package-conflict`.
- **`remove_package`** removes one record in one commit, unless another record's recorded closure
  holds it (`package-in-use`). An absent identity succeeds; no dependency is removed.
- **`update_package`** checks `package-in-use` before resolving, answers the current record when no
  newer version applies, and otherwise swaps the current root for the target in one commit after its
  dependencies are installed. A target already installed with the same commitment and the same
  recorded edges replaces the current root in one commit; with other edges it is
  `dependency-unavailable`, and with another commitment `package-conflict`. A failure keeps the current
  root.
- **`get_runtime_handoff`** is a query: it takes no slot, and the worker builds the handoff from the
  record's directory (§13).
- **The retained check:** an installed record an operation examines is hashed again on the worker
  against its signed digests; a changed or missing file is `artifact-integrity-failed` (G448).
- **Each archive an install or update selects** stays in the spool until its package is committed,
  within 4 × `archive_bytes` for the operation; past that the oldest go, never the root's, and one that
  is needed again is fetched again by digest.
- **The operation deadline:** `operation_deadline_ms` (1 h by default) from taking the slot; past it
  the operation ends `package-unavailable`, its retrieval call cancelled and its slot passed on. Once
  an operation's last commit has begun, neither the deadline nor a cancel applies, and its answer is
  the commit's.
- **Faults:** a staging that fails for room, I/O or a changed source is `package-unavailable`; files
  that escape or do not match their digests are `artifact-integrity-failed`; paths that collide under
  the root's rules are `invalid-package`; an admission bound, the index's bound, a damaged state or a
  commit that cannot be written are `MODULE_ERROR`, with nothing committed. Details go to the
  operator's log, never to the caller (§12).
- **The operator's log** has each operation's end: its method, its time, the archive bytes it
  retrieved and its outcome.
- **At a stop** every operation, running or waiting, is answered `package-unavailable`.
- **Limits** (G449): an operation that ends by its deadline or its caller's cancel leaves its worker
  job to finish for nobody (at most one more extraction of the largest archive); a call cancelled after
  its last commit began ends cancelled while the commit completes, so its caller may find the package
  installed (cancellation promises no rollback); a worker that hangs in a write or a sync makes a stop
  end at the stop deadline.

## 12. Responses, messages and the admission bound

- **Responses** (G450): one encoder per §15 response variant (`pm/responses.nim`): `{installed}` for
  install and update, `{}` for remove, `{inspection}`, `{handoff}`, the installed-list page
  `{packages, ?next_cursor}`, and `{error: package_error}`. A success variant holds no error; an error
  variant holds exactly one package error (PKG-0356).
- **Messages** (PKG-0360) are diagnostic text only, at most 512 bytes, cut at a character boundary.
  They name the request's own fields, the identities and versions the caller named or may observe, and
  a fixed cause. They never name a state directory, `local_path`, binding or storage name, locator,
  trust content or limit value; those go to the operator's log.
- **Package errors and invocation failures** (PKG-0361, PKG-0362): a package error is an operational
  result, carried in a successful response, and never an authorization decision. What prevents a
  valid response (the admission bound, a damaged installed state, a worker failure, a stop) is
  `MODULE_ERROR` with no message or detail. `invalid-request` is used only for a request that would
  fail unchanged again (PKG-0359).
- **The admission bound** (G452; PM l.824-830): before a record is committed, and for every record at
  start, each required result is encoded in its real Transport response envelope and must fit the
  Core-owned 16 MiB body, whatever limit the deployment configures. The results are the install and
  update result `{installed: R}`, a one-record page with a 512-byte cursor, and each selected module's
  handoff with its configuration. Each envelope has the largest call id and a payload commitment, so
  134 bytes surround the result. A failure is `MODULE_ERROR` with no detail; the operator's log names
  the result that did not fit. A handoff from a legal package stays under 14 MiB (a manifest is at most
  4 MiB, a schema document 1 MiB, a default 8 MiB), so in practice the record's artifacts and edges
  are what reach the bound.

## 13. The handoff's construction

`get_runtime_handoff`'s record (G451; PM §12), built for one selected module of an installed record:

- the retained signer (PKG-0438), the flat module name (PKG-0348), the record's identity, and the
  implementation artifact's id and `local_path` (PKG-0340);
- the artifact's hash as the manifest signs it, never read from the file (PKG-0341): the Loader
  hashes its own copy against it;
- the exact manifest commitment (PKG-0339);
- `primary_contract`, `implements`, `extends`, `requires` and `requested_permissions`, copied from
  the signed declaration when it has them, and never added or widened;
- when the declaration has `configuration`, the configuration-owned declaration (PKG-0342 to
  PKG-0344): the schema artifact's text, the root and live support copied, the declared commitment
  with the subtree root derived for that root, and the default value when a default artifact is
  declared. Both artifacts are checked against their signed digests before anything parses them, and
  the result must pass the Runtime's own configuration acceptance. No artifact id or path is carried.

The worker builds it from the record's directory (`wjHandoff`), so the module thread reads no file.
It is refused, by cause: the package not installed (`package-not-installed`); a module the record does
not select (`invalid-request`); the retained signer no longer accepted by the active trust
(`signature-verification-failed`, PKG-0341, PKG-0080); a schema or default artifact absent or changed
(`artifact-integrity-failed`); the configuration not accepted (`invalid-package`); a record that no
longer matches its signed manifest (`MODULE_ERROR`).

A returned handoff holds no files. The Loader reads `local_path` later, in logosd; a remove or an update
that commits first can delete the directory. That load fails, and a new handoff succeeds: a race, not
damage.

**At inspection** (PKG-0060): the same declaration is built from the archive's verified entries for
each selected module of the selected variant, after every other check. Invalid CDDL, a document
commitment mismatch, an absent or invalid root, an unresolved non-common reference and an invalid
default are each `invalid-package`, so such a package is never installed.

## 14. The module and its instance

Step 5-6a-1 (DECISIONS G490, G491, G494, G495, G500; the owner's Q2, Q7 (b), Q11).

- **The module** `logos_package_manager` (`src/logos_package_manager.nim`) is a library on a kit that
  lcn-gen generates from the pinned Package Manager contract (`pm/logos_package_manager_kit.nim` and its
  types; the `.exports` and `.map` files keep the library's symbols to the kit's). `pm/requests.nim`
  turns each request into the engine's operation; `pm/facade.nim` answers. Its responses are encoded
  once by `pm/responses.nim` (§12) and handed to the kit as they are (G494), and the kit's boundary
  still checks them against the contract before they leave.
- **Who runs it** (G491). logosd composes it from its configuration's `package_manager` section
  ([DAEMON.md](DAEMON.md) §3): the reserved instance `package_manager`, `hosted_dynamic` in its own
  Module Host, with the state assignment `package_manager.state`, and starts it after the operator's
  start list. The library is the one installed with logosd (`lib/logos-core/`), checked against the
  hash logosd is built with, or `package_manager.artifact` for development. An operator cannot list,
  retire or reconfigure it (S12); `logosctl` may start, stop and recover it.
- **The mark** (G490). The host configuration's top-level `package_manager` names the instance
  ([HOST-CONFIG.md](HOST-CONFIG.md)); only that instance's Module Host accepts the reserved name and
  the `logos.` rules of its contracts, and the Runtime binds it as a system service. It never runs in
  logosd's process or the Runtime's (PKG-0005, PKG-0006).
- **What each caller reaches.** Any caller with a route may call `inspect_package`,
  `install_package`, `remove_package` and `update_package`, subject to the authority policy.
  `get_runtime_handoff` is for a SYSTEM_SERVICE caller, the Runtime's own binding (5-6a-2), and the
  observation methods (`list_packages`, `list_installed_packages`, `watch_installed_packages`) for
  readers (Q7 (b); 5-6b). Until then they, and an ordinary caller's `get_runtime_handoff`, are
  answered `MODULE_ERROR` with no message or detail, the only refusal a provider may answer
  (INTERFACE l.3308-3311); the operator's log has "package-manager: <method> refused for <caller>:
  not a reader" (G495).
- **`list_packages`** (G500; `pm/listing.nim`): the `lgx` entries of the catalog in use, in its
  canonical order, optionally one package's; 5-6b serves the method.
