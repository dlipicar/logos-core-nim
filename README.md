# logos-core-nim

A Nim implementation of the Logos Core module specs: logos-lips, branch
`draft/logos-core-module-specs`, files `docs/logos-core/raw/spec-*.md`, pinned at `6cac8335` (since the re-pin,
2026-11-18 to 2026-11-20; `6a4dfa28` from 2026-11-10, and the work before that was built against `f4f83471`).

The specs are being revised, so the work is ordered by how settled each area is
([docs/SPEC-STATUS.md](docs/SPEC-STATUS.md)). Built so far:

- Tier 1: deterministic CBOR, BLAKE3, cdCDDLe, the hash profile and the commitment model.
- Tier 2: INTERFACE schema acceptance, call surfaces, payload validation and outcomes, the common
  schema, and `lcn-gen`, which generates C headers (C mapping revision 4: types, method typedefs and, for a module
  binding, its provider functions and module symbols) and Nim types with codecs. `lcn-gen cddl` goes the other way, from an explicit C header set back to its CDDL documents
  and module binding (Tier 5 step 5-1).
- Tier 3, without I/O: the TRANSPORT envelope, framing, Hello and route tickets, payload
  commitments, cancellation and multiplexing as codecs and state machines; and the Package Manager's
  package artifacts: the manifest and its commitment, package-signing trust input, COSE_Sign1, LGX
  archives, and `lcn-pkg`, the producer tools. Sockets, fetch, catalogs, installation and the
  resolver come later. Packages are signed with SLH-DSA-SHA2-192s (PM §4.3, FIPS 205) over the
  vendored slhdsa-c, checked against the NIST ACVP vectors (DECISIONS R4, I68).
- Tier 4: the direct-mode Runtime engine. The Nim module kit (`lcn-gen kit` and `lcn-gen calls`:
  exported module symbols and typed provider functions over handlers written in Nim, and typed call
  helpers over a route handle; I70–I73); a LOADER-shaped internal realizer for `direct_static` and
  `direct_dynamic` code; the module-instance lifecycle with persistent state and recovery; Runtime
  Control (observation, lifecycle and configuration methods, and events); direct routes, events and
  asynchronous calls; the Capability Authority as a `direct_static` module with its policy format
  (`docs/AUTHORITY-POLICY.md`), and the Runtime's authorization, call records and evidence; module
  configuration; the unix-stream transport I/O layer; and the Host Embedding API, `liblogos_runtime`
  (I74–I88). RUNTIME (for the engine; the host supplies the orchestration module), CONFIG, the
  Capability Authority and TRANSPORT are claimed in `conformance/claims/`
  ([docs/CONFORMANCE.md](docs/CONFORMANCE.md)).
- Tier 4b, step 4b-1: the Module Loader as a module. `logos_module_loader`, a `direct_static` module
  built into the library, is established and bound at every `start`, and the Runtime realizes,
  releases and configures every other instance through its contract; lost Loader answers are
  resolved with `get_status`, and a failed Loader leaves its instances `error` and asks the host to
  end its process (I89). LOADER is claimed for the direct strategies.
- Tier 4b, step 4b-2: transported local routes. A host routing rule selects `local-transport` for a
  route; the Runtime runs the transport I/O thread, issues one-time tickets at establish and renew,
  and serves a direct provider at an endpoint of its own (part 4b-2a, I90); a consumer's handle on
  such a route calls its provider over a socket (part 4b-2b) and subscribes to its events, which
  reach the handlers on the Runtime's event workers (part 4b-2c). The route, asynchronous-call and
  event suites rerun over local transport.
- Tier 4b, step 4b-4: permissions. The permission profile `logos-core-nim.permission-profile.v1`
  and its one definition, `logos-core-nim.host-ambient` ([docs/PERMISSIONS.md](docs/PERMISSIONS.md)),
  and the Capability Authority's side: permission validation and containment, permission patterns in
  policy, and one rule or grant for a whole start (part 4b-4a, I93). The Capability Authority's §3.5 is
  claimed. In direct mode (part 4b-4b), a host that selects the profile provisions each instance's
  permission settings; the Runtime saves them, reconciles a replacement by stopping the instance,
  refuses a start whose settings lack host-ambient, asks the authority for every saved permission, and
  tells each realization what it was given. The same holds for hosted instances (part 4b-4c): their
  execution decisions name `local-transport` in a `process`, a stop past its deadline settles once the
  Module Host's forced end is confirmed, and a host of the previous run holds settings back until its
  restart lock is free.
- Tier 4b, step 4b-5: the reference orchestration module. `lcn_orchestrator`, a module a host links
  in and names as its orchestration instance, applies startup defaults, reconciles after restarts,
  recovers failures under a configured restart policy with retry accounting that survives restarts,
  and resumes what authority or permissions held back (I94); `docs/HOST-CONFIG.md` documents its
  configuration. RUNTIME is claimed for the engine with this module.
- Tier 4b, step 4b-3: the Module Host. With `runtime.module_host` set, a
  `hosted_dynamic` module runs in a `logos-module-host` process of its own that the Runtime starts,
  supervises and ends; its Runtime Control calls, events and asynchronous calls cross a private
  carrier and are answered as a direct module's are (part 4b-3.1a, I91: consumer-only modules,
  start and stop). A host that ends by itself, a broken carrier, a deadline and the Module Loader's
  loss end the instance's realization (`error`, with the deadline's classification or
  `host-terminated`); a restart lock keeps a host of an earlier run from being joined by a new one
  (part 4b-3.1b). A hosted provider serves the endpoint the Runtime made for it: payloads go
  between the consumer's process and the host directly, the Runtime admits every Hello, call,
  subscription and delivery, and the host checks payloads, runs the provider and commits each
  Response (part 4b-3.2). A hosted consumer's route handles are in its host, which connects to the
  provider itself while the Runtime decides each materialization, call, subscription and end
  observer, so its codes and route ends are a direct consumer's (part 4b-3.3). One case table run
  from a consumer through a route in the four placements, either end direct or hosted, gives the
  same answers, deliveries and completions (part 4b-3.4); RUNTIME §4.2.1 and §6.2 and LOADER §5.3
  are claimed.
- Tier 4b, step 4b-3b: erasure of marked payloads. The Runtime, its served endpoints, the Module Host
  and the code lcn-gen generates zero their copies of a payload the contract marks `_sensitive`, keep
  it and its value roots out of diagnostics, records and the carrier, and refuse a call whose
  decision would retain one; a contract that marks a payload is routed on every local path, hosted
  ends included, in an orc build (I92). A refc build of the Runtime or the host refuses it instead.
  INTERFACE §1.4.1 is claimed for orc builds, with the non-claims in
  [docs/CONFORMANCE.md](docs/CONFORMANCE.md).
- Tier 4b, step 4b-6: `logosd` and `logosctl`. `logosd` hosts one Runtime for a session directory
  (`$HOME/.logos-core` by default): it checks `daemon-config.v1` and the trust file, composes the
  host configuration with the orchestrator, the Capability Authority and the `logosctl` instance, and
  ends on SIGTERM or `logosctl daemon stop`. The `logosctl` instance serves an owner-only socket;
  each shell command is one Runtime Control call it makes through its own binding, and no module
  payload passes through it. The development switch in the trust file gates allow-all and test
  hooks, and marks every output `NON-PRODUCTION`. An optional call-evidence store keeps the call
  records the Runtime retains on disk, and `logosctl audit evidence export` signs one as call
  evidence. [docs/DAEMON.md](docs/DAEMON.md).
- Tier 5, step N-2b: provider calls from the shell. `logosctl call MODULE METHOD NAME=VALUE …`
  (or `--request` with the whole request as JSON), `logosctl describe MODULE` and `logosctl module
  wait` go through `lcn_call`, a hosted CLI instance logosd starts on first use through the logosctl
  instance; it holds the routes and writes results straight to the terminal, and logosd sees only the
  route's control. Operator rules grant `lcn_call` the providers it may call.
  [docs/DAEMON.md](docs/DAEMON.md) §7a.
- Tier 5, step N-2c: event streams from the shell. `logosctl subscribe MODULE EVENT` follows one
  provider event and `logosctl events` this Runtime's module, execution and inventory events, one
  line per event, until `--count`, `--for` or Ctrl-C (0, 130); a stream the route, its session or
  the authority ends, or a terminal that does not keep up, exits 6. The events go from the
  provider's host to `lcn_call`'s. [docs/DAEMON.md](docs/DAEMON.md) §7a, "Streams".
- Tier 4b, step 4b-7: state transfer to a replacement instance. A `state_transfers` entry in the
  host configuration (or logosd's daemon-config) gives a new instance, under its own state
  assignment, the state directory of the instance it replaces: at the next start the old instance
  is retired and its directory renamed (`move`) or copied, leaving it as the rollback (`copy`, not
  on Windows). `logosctl state list` shows where state is and came from; `logosctl state purge`
  removes a retired instance's state for good. [docs/HOST-CONFIG.md](docs/HOST-CONFIG.md),
  "State transfer to a replacement instance".
- Tier 4b, step 4b-8: claims and the deployment document. `logosd` publishes BCP §5.4's deployment
  profile, checked against the code by `spectrace deploydoc` and a test, and Tier 4b is closed:
  RUNTIME is claimed for the Runtime instance `logosd` runs (the engine with the reference
  orchestration module, direct and local transport, hosted modules in a Module Host), LOADER for
  `direct_static`, `direct_dynamic` and `hosted_dynamic` in a `process`. No complete Logos module
  system is claimed: there is no Package Manager yet (I97). [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md),
  [docs/CONFORMANCE.md](docs/CONFORMANCE.md).
- Not yet, Tier 5 ([docs/SPEC-STATUS.md](docs/SPEC-STATUS.md), "The Tier 5 plan"): the Package
  Manager (package trust, sources and the catalog, installation, its service and package-backed
  selection; SLSA provenance and the Nix profile if kept), remote Runtimes over `tls-tcp` (QUIC if
  kept), and the Windows local transport if its spike allows. Outside
  Tier 5: sandbox and container placements and operating-system enforcement of permissions
  (DECISIONS D16).

Decisions the specs leave open are recorded in [docs/DECISIONS.md](docs/DECISIONS.md).

## Building and testing

Dependencies are declared once, in `logos_core.nimble` and `nimble.lock`. Both paths below use them.

With Nimble (Nim 2.2.14 and Nimble 0.26.2 or later on `PATH`; the dev shell has both). Every
Nimble command passes `--useSystemNim`, so Nimble uses the Nim on `PATH` and never installs or locks
one; that Nim must be `logos_core.nimble`'s pin (DECISIONS G436). Remove any `nim-*` tree that
Nimble 0.20.1 left in `nimbledeps/pkgs2/`: a command without the flag would compile with it instead.

```bash
nimble --useSystemNim setup -l
```

```bash
nimble --useSystemNim test && nimble --useSystemNim test_refc
```

Nimble checks none of the lock's checksums, so every `nimble test*` task, `build_runtime_lib` and
`nimble build` first run `tools/check_installs.nim`, which stops them unless each install in
`nimble.paths` carries the checksum `nimble.lock` records (DECISIONS G436).

Under the sanitizers (DECISIONS I77): AddressSanitizer with UndefinedBehaviorSanitizer,
ThreadSanitizer, and on Linux with clang MemorySanitizer. On macOS they build with the Xcode
toolchain; on Linux `nix flake check` runs all three:

```bash
nimble --useSystemNim test_asan && nimble --useSystemNim test_tsan
```

Each sanitizer suite runs through `tools/sanitizer/reports.sh` (DECISIONS G442): every report,
the suite's own and any process's it starts, a Module Host's included, goes to a file under
`build/tests/<sanitizer>/sanitizer-reports/<suite>/` (in the flake, the check's own directory),
and the suite fails on any and prints them. A test that gives a Module Host its environment names
`SanitizerEnv` (`tests/support/sanitizerenv.nim`); the flake's `lint-sanitizer-env` check
rejects one that does not. To run the script's own checks and the lint by hand:

```bash
bash tools/sanitizer/reports.sh self-test
```

```bash
python3 tools/lint/sanitizerenv.py tests sdk/tests
```

A `?` inside a half-built constructor leaks under ORC on Nim 2.2.14 (I77). The flake's
`lint-ctor-try` check rejects it; to run it by hand, from the repository root (its default roots
are the flake's: `src`, `sdk/src`, `sdk/tests` and `tests`; a missing root, or no `.nim` file at all,
exits 2):

```bash
python3 tools/lint/ctortry.py
```

A local declared without an initializer, first written in a branch and written again after it,
loses the branch's value undestroyed under ORC (I92, nim-lang/Nim#26725). The flake's
`lint-first-write` check rejects it; to run it by hand, from the repository root (the same
default roots and exit status 2):

```bash
python3 tools/lint/firstwrite.py
```

A C-callable procedure that runs on a thread its library's Nim runtime never started must register
that thread first: under ORC its first allocation faults otherwise (G464-G467). The flake's
`lint-callbacks` check rejects one that neither registers nor says why it need not; to run it by hand,
with `lcn-gen` built:

```bash
lcn-gen lint-callbacks --self-test sdk/src src tests/kit
```

Core's programs (`lcn-pkg`, `logos-module-host`, and `logosd` and `logosctl` on POSIX hosts):

```bash
nimble build --useSystemNim
```

`lcn-gen` is the SDK's program (`sdk/logos_sdk.nimble`, DECISIONS G433), and that file needs Nimble
0.26. In this checkout, build it with Nim, or take the flake package below:

```bash
nim c -o:build/lcn-gen sdk/src/lcn_gen.nim
```

On Windows (x86_64, MinGW-w64; DECISIONS G126, G334), the same two commands run from `cmd` or
PowerShell. `PATH` needs Nim 2.2.14 with its MinGW gcc, and Git. No nasm: BLAKE3's assembly goes
through gcc, and nothing on Windows assembles BoringSSL. `.gitattributes` keeps every checkout LF,
whatever `core.autocrlf` says, because the spec mirrors and test vectors are compared byte for byte.
Nix does not build for Windows. CI's Windows job is `tools/ci/windows.ps1`, which runs the same by
hand: `toolchain -ToolDir <dir>` fetches nim-lang.org's Nim 2.2.14 and MinGW-w64 gcc 11.1.0, checks
their SHA-256 and puts both first on `PATH`; `setup`, `test` and `probe` are the job's other steps
(`probe` runs `tools/winprobe`, the measurements behind G107, and compares them with the committed
facts for the build):

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\windows.ps1 toolchain -ToolDir C:\lcn-tools
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\windows.ps1 setup -ToolDir C:\lcn-tools
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\windows.ps1 test -ToolDir C:\lcn-tools
```

On Android (DECISIONS I46), an x86_64 Linux host with KVM runs every suite on an emulator. The flake
pins the SDK, NDK, emulator and system image, cross-compiles the suites for x86_64 and aarch64, boots
a headless emulator and runs the x86_64 ones; the aarch64 ones are built and checked, not run. This
is not part of `nix flake check`:

```bash
nix run .#test-android
```

On iOS (DECISIONS I47), a Mac with Xcode and an iOS simulator runtime builds every suite with Xcode's
clang for the simulator and for devices, then runs the simulator ones on a simulator it creates and
deletes. Xcode is not pinned by Nix, so this also runs outside `nix flake check`:

```bash
nix run .#test-ios
```

With Nix, which also runs nph and the spec checks:

```bash
nix flake check -L
```

CI splits the checks into groups: `orc-spec` (orc, nph, lint and the spec checks), `refc`,
`orc-release`, and on Linux `asan`, `tsan` and `msan`. On macOS `refc` and `orc-release` are one job
each and `orc-spec` runs as two shards; on Linux `orc-spec` runs as four shards, `ciShards.orc-spec-1`
to `orc-spec-4`, `refc` as three, `orc-release` as two, `asan` and `tsan` as four and `msan` as five.
Each check's minutes in a saved CI run (`nix/ci-weights.json`, written by `tools/ci_weights.py`)
balance the shards, and a Linux shard whose heaviest check takes 25 minutes or more builds it as its
head (`ciShardHeads.<shard>`) beside the rest (`ciShardTails.<shard>`); `ciLayout` shows the split as
data. The Nimble tasks run as three shards on Linux and two on macOS (`LCN_SHARD`). A third job runs
the Nimble path on Windows (`windows-2025`, four shards of `nimble test` under orc, and the Windows
probes; DECISIONS G334). One group or one shard builds alone with:

```bash
nix build -L --keep-going .#ciGroups.asan
```

```bash
nix build -L --keep-going .#ciShards.asan-1
```

The suites a change can reach, from its merge base to the merged tree: imports followed
transitively, test support modules included, and the documents, contracts, fixtures and kit
sources the suites name by path (`--why` prints how each suite is reached, `--variant orc` the
flake checks):

```bash
python3 -I tools/affected_suites.py "$(git merge-base master HEAD)" HEAD
```

Known limits of the test suites:

- **Module Host counts are system-wide.** After each case, a hosted suite checks that no Module Host is
  left (`hostPids`, `tests/support/modulehostbuild.nim`). It counts every live process of the checkout's
  `build/module-host/<variant>/logos-module-host`, whoever started it. So run one hosted suite at a time
  per checkout. Two at once fail each other's checks, and hosts a crashed suite left behind (its
  orphaned logosd respawns them) fail the next suites of that checkout and variant. A per-suite count
  is not built. A parent-PID filter would hide the leaks the check is for: hosts run in their own
  process groups, and a stopped logosd's leftover hosts are reparented to launchd or init. The way
  out is the `--parent=<pid>` argument each host is started with (DECISIONS G264): count only the
  hosts whose `--parent` is the suite's own process or a child it started (`spawnChild` in
  `tests/support/daemonproc.nim` would record each pid), reading argv through `KERN_PROCARGS2` on
  macOS and `/proc/<pid>/cmdline` on Linux.
- **Backlog: `startClient`'s binding** (`tests/support/routefixture.nim`). It returns the Runtime
  Control binding from the slot the last client `init` filled. When the client does not come up, that
  slot still holds an earlier client's binding, which may be freed, or nil. A call through it crashes
  the suite instead of failing the case. The fix is to fail and stop the case there, as `liveHostOf`
  does in `tests/test_hosted.nim`.

```bash
nix develop
```

The dev shell has nim, nimble, nph, `spectrace`, and Python with cbor2 and blake3. `lcn-gen` is
also a flake package:

```bash
nix run .#lcn-gen -- types --out:include module.cddl
```

So is `lcn-pkg`, which builds, signs, packs and checks packages (`lcn-pkg --help`):

```bash
nix run .#lcn-pkg -- verify example.lgx --trust:trust.json
```

The generated Nim modules (`sdk/src/logos_sdk/codegen/common_types.nim`,
`sdk/src/logos_sdk/testing/generated/`, `sdk/tests/generated/`, `tests/generated/`) are committed, and a test fails when they are stale. To rewrite them:

```bash
nimble --useSystemNim regen
```

After changing a requirement in `logos_core.nimble`, regenerate the lock from scratch, as CI's
check does. The lock has no `nim` entry (G436). Locking runs each dependency's `.nimble` script, so
we lock on a separate Linux host (DECISIONS I35).

```bash
rm nimble.lock && nimble --useSystemNim -y lock
```

Then:

```bash
nix run .#update-nimble-deps
```

That command regenerates `nix/nimble-deps.json`, the per-package content hashes Nix fetches with.
Evaluation fails while the JSON and `nimble.lock` disagree.

## Host embedding API

`liblogos_runtime` is the Runtime as a C library (RUNTIME §13): a host creates a Runtime from one
configuration, registers its static module bindings, starts it, and later requests shutdown, waits
and destroys it. The configuration format, `logos-core-nim.app-config.v1`, and what a host can expect
are in [docs/HOST-CONFIG.md](docs/HOST-CONFIG.md). To build the library and `logos_runtime.h` under
`build/lib/`:

```bash
nimble --useSystemNim build_runtime_lib
```

## Running logosd

On Linux and macOS (`logosd` and `logosctl` are POSIX programs; on Windows both exit 2):

```bash
nix build .#logosd .#logosctl
```

```bash
logosctl init
```

```bash
logosd
```

```bash
logosctl status
```

`init` makes the session directory, a Runtime id, the evidence key and the default daemon-config;
`logosd` logs to stderr and prints a `ready` line once the Runtime has started; `logosctl` prints text
on a terminal and JSON otherwise. `contrib/` has a systemd user unit and a launchd agent. The
session layout, the daemon-config fields, the default policy and every command are in
[docs/DAEMON.md](docs/DAEMON.md).

## Layout

The implementation has two layers. `sdk/` is the package `logos_sdk`, layer 1: the base set (CBOR,
cdCDDLe, hashing, commitments and INTERFACE), the generators, the module kit and the helpers module
tests share (`logos_sdk/testing`). Core, under `src/logos_core/`, is built on it, and the daemon and
the CLI on core. `tools/lint/layers.py` holds that direction: nothing in `sdk/` imports core.

Each layer is a nimble package: `sdk/logos_sdk.nimble` (`logos_sdk`) and `logos_core.nimble`
(`logos_core`), both at `0.1.0` (DECISIONS G433). Inside this repository core does not require the SDK:
its exact pins hold every SDK requirement, and `tools/lint/packaging.py` (the `lint-packaging` check)
keeps the SDK's ranges, install lists and versions in step with them (G434, G435). A module repository
requires the SDK by name ([sdk/docs/MODULE-KIT.md](sdk/docs/MODULE-KIT.md) §9).

| Path | What |
|---|---|
| `src/logos_core/` | The library, on `logos_sdk`. The slhdsa-c (FIPS 205) C sources are vendored under `crypto/slhdsa/` (`tools/update-slhdsa.sh`), and the BLAKE3 ones under `sdk/src/logos_sdk/crypto/blake3/` (`tools/update-blake3.sh`). |
| `sdk/src/logos_sdk/iface/` | INTERFACE: acceptance, names, the C type mapping and its reverse (`clex`, `cliteral`, `cparse`, `cinput`, `creject`, `rmap`), call surfaces and the provider call-surface descriptor, payloads, outcomes. |
| `sdk/src/logos_sdk/abi/` | The INTERFACE §5.2 native ABI structs as Nim types (layout checked against `logos_types.h`) and the checks each side applies to the other's structs, results and outputs. |
| `sdk/src/logos_sdk/codegen/`, `sdk/src/lcn_gen.nim` | The Nim type generator (`nimgen`), the module kit generator (`kitgen`), the typed call helper generator (`callsgen`) and their C converter generator (`cmirror`), with their runtimes (`nimrt`, `kitrt`, `callrt`, `invokert`) and the common schema's generated mirrors (`common_mirrors`); the `lcn-gen` CLI. |
| `src/logos_core/runtime/`, `src/liblogos_runtime.nim` | The Runtime: the Loader, the engine (instances, lifecycle, Runtime Control, routes, events, asynchronous calls), transported routes (`routing`, `tport`, `sessionauth`, `served`, `ports`), the host configuration and the Host Embedding API; the `liblogos_runtime` exports. |
| `src/logos_core/daemon/`, `src/logosd.nim`, `src/logosctl.nim` | logosd and logosctl: `daemon-config.v1` and its checks, the session and trust file, the composition, the `logosctl` instance and its socket protocol, the call-evidence store and its export, the shell's output. |
| `src/logos_core/cli/`, `src/lcn_call.nim` | The CLI module `lcn_call` (`liblcn_call`, hosted): the launcher protocol `cli.v1` and descriptor passing, arguments typed from the request rule, output, routes, the commands and the launcher `logosctl` runs. |
| `src/logos_core/orchestration/`, `src/logos_core/orchestration.nim` | The reference orchestration module `lcn_orchestrator`: its configuration (`config.cddl`), decisions (`policy.nim`), retry accounting (`accounting.nim`) and worker; `sdk/src/logos_sdk/kit/rcclient.nim` is the typed Runtime Control client it calls through. |
| `src/logos_core/transport/` | TRANSPORT: envelope codec, framing, Hello, tickets, sessions, the schema boundary; `io/`, the unix-stream I/O thread. |
| `src/logos_core/package/`, `src/lcn_pkg.nim` | Package Manager artifacts: manifest, trust input, COSE_Sign1 signing, LGX; catalog and inspection records (`records.nim`) and the sans-I/O dependency resolver (`resolver.nim`); the `lcn-pkg` CLI. |
| `src/logos_core/crypto/slhdsa.nim`, `sdk/src/logos_sdk/base/nfc.nim` | SLH-DSA-SHA2-192s over slhdsa-c (pure and internal functions only); Unicode NFC for LGX paths. |
| `sdk/tests/`, `tests/` | unittest2 suites of the SDK and of core; each one runs under `--mm:orc` and `--mm:refc`. `sdk/src/logos_sdk/testing/` holds the helpers, kit fixtures and `lcn-gen` output both use, and `sdk/tests/kit/` the C harness that calls the kit's typed functions directly or through the typed call helpers (`test_calls`). `tests/host/` drives `liblogos_runtime` from C (`test_host_dylib`). |
| `spec/mirrors/`, `spec/mirrors.toml` | Verbatim copies of the spec blocks the code and tests are built from. |
| `spec/pins.toml` | Every identifier, root and digest the specs pin, with the section it comes from. |
| `conformance/`, `sdk/conformance/` | Requirement ledgers and per-section claims of core and of the SDK; see [docs/CONFORMANCE.md](docs/CONFORMANCE.md). |
| `tools/spectrace/` | Requirement extraction, mirror and pin checks, coverage gate. |
| `oracle/` | An independent Python reference for deterministic CBOR, hashing, SLH-DSA-SHA2-192s (FIPS 205) and COSE vectors, and the NFC tables. |
| `nix/` | Nim overlay, Nimble dependency fetching, the shared derivation helper, the Android and iOS runners. |

## Following the specs

Pinned values are data. Code never carries a root, digest or profile id as a literal: tests read
`spec/pins.toml` and recompute each value from `spec/mirrors/`. When a new spec revision lands, the
steps are in [docs/SPEC-STATUS.md](docs/SPEC-STATUS.md#when-a-spec-revision-lands).

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE-v2) or [MIT license](LICENSE-MIT),
at your option.
