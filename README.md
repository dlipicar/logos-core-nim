# logos-core-nim

A Nim implementation of the Logos Core module specs: logos-lips, branch
`draft/logos-core-module-specs`, files `docs/logos-core/raw/spec-*.md`, pinned at `6a4dfa28` (since 2026-11-10; the work
before that was built against `f4f83471`).

The specs are being revised, so the work is ordered by how settled each area is
([docs/SPEC-STATUS.md](docs/SPEC-STATUS.md)). Built so far:

- Tier 1: deterministic CBOR, BLAKE3, cdCDDLe, the hash profile and the commitment model.
- Tier 2: INTERFACE schema acceptance, call surfaces, payload validation and outcomes, the common
  schema, and `lcn-gen`, which generates C headers (C mapping revision 3: types, method typedefs and, for a module
  binding, its provider functions and module symbols) and Nim types with codecs. Generated C headers are stamped
  `PROVISIONAL ABI`.
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
- Not yet: the rest of Tier 4b (the Module Host and the hosted strategy, transported routes, `logosd`
  and `logosctl`, the default orchestration module, package installation into the Runtime) and Tier 5 (remote Runtimes, platform permissions, Windows local transport).

Decisions the specs leave open are recorded in [docs/DECISIONS.md](docs/DECISIONS.md).

## Building and testing

Dependencies are declared once, in `logos_core.nimble` and `nimble.lock`. Both paths below use them.

With Nimble (Nim 2.2.14 and nimble ≥ 0.20 on `PATH`):

```bash
nimble setup -l
```

```bash
nimble test && nimble test_refc
```

Under the sanitizers (DECISIONS I77): AddressSanitizer with UndefinedBehaviorSanitizer,
ThreadSanitizer, and on Linux with clang MemorySanitizer. On macOS they build with the Xcode
toolchain; on Linux `nix flake check` runs all three:

```bash
nimble test_asan && nimble test_tsan
```

A `?` inside a half-built constructor leaks under ORC on Nim 2.2.14 (I77). The flake's
`lint-ctor-try` check rejects it; to run it by hand:

```bash
python3 tools/lint/ctortry.py src tests
```

`lcn-gen` and `lcn-pkg` build with `--useSystemNim`. On macOS, nimble 0.20.1 crashes without it
while looking up the Nim that `nimble.lock` names; on Linux the flag changes nothing:

```bash
nimble build --useSystemNim
```

On Windows (x86_64, MinGW-w64; DECISIONS G126, I45), the same two commands run from `cmd` or
PowerShell. `PATH` needs Nim 2.2.14 with its MinGW gcc, Git, and `nasm`: nim-boringssl assembles
its Windows sources with nasm while compiling. `.gitattributes` keeps every checkout LF, whatever
`core.autocrlf` says, because the spec mirrors and test vectors are compared byte for byte. Nix
does not build for Windows.

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

CI splits the checks into groups and builds each group in its own job: `orc-spec` (orc, nph, lint
and the spec checks), `refc`, `orc-release`, and on Linux `asan`, `tsan` and `msan`. One group builds
alone with:

```bash
nix build -L --keep-going .#ciGroups.asan
```

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

The generated Nim modules (`src/logos_core/iface/common_types.nim`, `tests/generated/`) are
committed, and a test fails when they are stale. To rewrite them:

```bash
nimble regen
```

After changing a requirement in `logos_core.nimble`, regenerate the lock from scratch. With nimble
0.20.1, `nimble lock` over an existing lock empties its package list or crashes. Locking runs each
dependency's `.nimble` script, so we lock on a separate Linux host (DECISIONS I35).

```bash
rm nimble.lock && nimble -y lock
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
nimble build_runtime_lib
```

## Layout

| Path | What |
|---|---|
| `src/logos_core/` | The library. BLAKE3 and slhdsa-c (FIPS 205) C sources are vendored under `crypto/blake3/` and `crypto/slhdsa/` (`tools/update-blake3.sh`, `tools/update-slhdsa.sh`). |
| `src/logos_core/iface/` | INTERFACE: acceptance, names, the C type mapping, call surfaces and the provider call-surface descriptor, payloads, outcomes. |
| `src/logos_core/abi/` | The INTERFACE §5.2 native ABI structs as Nim types (layout checked against `logos_types.h`) and the checks each side applies to the other's structs, results and outputs. |
| `src/logos_core/codegen/`, `src/lcn_gen.nim` | The Nim type generator (`nimgen`), the module kit generator (`kitgen`), the typed call helper generator (`callsgen`) and their C converter generator (`cmirror`), with their runtimes (`nimrt`, `kitrt`, `callrt`, `invokert`) and the common schema's generated mirrors (`common_mirrors`); the `lcn-gen` CLI. |
| `src/logos_core/runtime/`, `src/liblogos_runtime.nim` | The direct-mode Runtime: the Loader, the engine (instances, lifecycle, Runtime Control, routes, events, asynchronous calls), the host configuration and the Host Embedding API; the `liblogos_runtime` exports. |
| `src/logos_core/transport/` | TRANSPORT without I/O: envelope codec, framing, Hello, tickets, sessions, the schema boundary. |
| `src/logos_core/package/`, `src/lcn_pkg.nim` | Package Manager artifacts: manifest, trust input, COSE_Sign1 signing, LGX; catalog and inspection records (`records.nim`) and the sans-I/O dependency resolver (`resolver.nim`); the `lcn-pkg` CLI. |
| `src/logos_core/crypto/slhdsa.nim`, `src/logos_core/base/nfc.nim` | SLH-DSA-SHA2-192s over slhdsa-c (pure and internal functions only); Unicode NFC for LGX paths. |
| `tests/` | unittest2 suites; each one runs under `--mm:orc` and `--mm:refc`. `tests/generated/` is `lcn-gen` output; `tests/kit/` holds three modules written with the kit, which `test_kit_dylib` also builds as shared libraries, and the C harness that calls their typed functions directly or through the typed call helpers (`test_calls`). `tests/host/` drives `liblogos_runtime` from C (`test_host_dylib`). |
| `spec/mirrors/`, `spec/mirrors.toml` | Verbatim copies of the spec blocks the code and tests are built from. |
| `spec/pins.toml` | Every identifier, root and digest the specs pin, with the section it comes from. |
| `conformance/` | Requirement ledger and per-section claims; see [docs/CONFORMANCE.md](docs/CONFORMANCE.md). |
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
