# The Package Manager: catalog, retrieval and trust in use

What this implementation chooses where PACKAGE MANAGER leaves the choice to it: the catalog
document, how it is acquired and refreshed, catalog policy (PKG-0472, PM l.834-835), the Storage
bindings and retrieval, and how trust is applied when a package is inspected. Each choice keeps the
verification of PM §4.1 to §4.4 (PKG-0473): nothing here replaces a package's own signature, adds
trust or claims freshness. The decisions are DECISIONS G399 to G406; the code is
`src/logos_core/pm/`.

Tier 5 step 5-3b builds the engine (5-3b-1) and the module that hosts it (5-3b-2). Until 5-6a, the
Package Manager runs under a test name (`pmtest_module`); `list_packages`, installation and the
§15 methods come in later steps (5-5, 5-6a, 5-6b).

## 1. Placement and the data path

- **The engine** (`pm/`: input, catalog, fetcher, verification cache, resolution driver, engine) is
  core's, beside `package/`, the Capability Authority and the Loader. It does no I/O: it is a state
  machine over commands (calls, route operations, timers, the kept-catalog write, replies, log lines)
  and events. The module shell (`pm/shell.nim`, G405) carries them out through the module kit: it
  runs on the instance's module thread under chronos (G335), holds one route per binding through its
  Runtime Control binding, and queues the engine's events, so no engine step runs inside a kit
  callback. A test module (`pmtest_module`) wraps it with `status` and `resolve`.
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
| `archive_bytes` | 1 to 1,073,741,824 | 1 GiB | one archive, held in memory while it is inspected |
| `catalog_bytes` | 1 to 4,194,304 | 4 MiB | the catalog document |
| `catalog_entries` | 1 to 65,536 | 65,536 | the catalog's entries |
| `cache_entries` | 1 to 4,096 | 256 | the verification cache (§5) |
| `read_deadline_ms` | 1 to 86,400,000 | 300,000 | one call, and the wait for `ready` after `not-ready` (§4) |

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
2. `read_object` in 1 MiB steps, one after another; the BLAKE3-256 digest is computed while reading.
3. `unavailable` from a `read_object` after a successful `stat_object`: the same offset again after a
   back-off of 1, 2 and 4 s, at most three times in a row. A locator names fixed bytes, so a read
   resumes from its offset.
4. `not-ready`, or a route lost during a call: the same call once the provider reports `ready` or the
   route is back, the wait bounded by `read_deadline_ms`.
5. Anything else ends the retrieval as unavailable: `invalid-locator`, `out-of-range`,
   `invalid-length`, an invocation error, a call past its deadline, or data other than
   `min(length, size - offset)` bytes. The provider's `detail` is logged as foreign text.
6. The bytes are untrusted until verified: the catalog by its pinned digest and decoding, an archive
   by `openLgx` (PM l.389, l.397, l.443-444).

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
  untouched. The resolver half is built; the protected key `operation_entries` in `lcn.pm_limits`
  comes with 5-5-3, and until then the driver runs with no bound.

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
| every candidate of a root unavailable | `package-unavailable`, never proof that a candidate is invalid |
| a `nix` source in an LGX operation | `unsupported-source` |
| a catalog document refused | logged; the catalog in use, if any, stays; no catalog otherwise |
| `catalog.kept` that does not decode | set aside and logged; no catalog until one is read |
| a trust file that selects a profile | the Package Manager does not start: `_MODULE_init` fails, and its log names the field |
| no protected input, or no state directory | the Package Manager does not start |
