# logos-core-nim

A Nim implementation of the Logos Core module specs: logos-lips, branch
`draft/logos-core-module-specs`, files `docs/logos-core/raw/spec-*.md`, pinned at `f4f83471`.

The specs are being revised, so the work is ordered by how settled each area is
([docs/SPEC-STATUS.md](docs/SPEC-STATUS.md)). Tier 1 comes first: deterministic CBOR, BLAKE3, cdCDDLe,
the hash profile and the commitment model. Decisions the specs leave open are recorded in
[docs/DECISIONS.md](docs/DECISIONS.md).

## Building and testing

Dependencies are declared once, in `logos_core.nimble` and `nimble.lock`. Both paths below use them.

With Nimble (Nim 2.2.14 and nimble ≥ 0.20 on `PATH`):

```bash
nimble setup -l
```

```bash
nimble test && nimble test_refc
```

With Nix, which also runs nph and the spec checks:

```bash
nix flake check -L
```

```bash
nix develop
```

The dev shell has nim, nimble, nph, `spectrace`, and Python with cbor2 and blake3.

After changing a requirement in `logos_core.nimble`, regenerate the lock from scratch. With nimble
0.20.1, `nimble lock` over an existing lock empties its package list or crashes.

```bash
rm nimble.lock && nimble -y lock
```

Then:

```bash
nix run .#update-nimble-deps
```

That command regenerates `nix/nimble-deps.json`, the per-package content hashes Nix fetches with.
Evaluation fails while the JSON and `nimble.lock` disagree.

## Layout

| Path | What |
|---|---|
| `src/logos_core/` | The library. BLAKE3 C sources are vendored under `crypto/blake3/` (`tools/update-blake3.sh`). |
| `tests/` | unittest2 suites; each one runs under `--mm:orc` and `--mm:refc`. |
| `spec/mirrors/`, `spec/mirrors.toml` | Verbatim copies of the spec blocks the code and tests are built from. |
| `spec/pins.toml` | Every identifier, root and digest the specs pin, with the section it comes from. |
| `conformance/` | Requirement ledger and per-section claims; see [docs/CONFORMANCE.md](docs/CONFORMANCE.md). |
| `tools/spectrace/` | Requirement extraction, mirror and pin checks, coverage gate. |
| `oracle/` | An independent Python reference for deterministic CBOR and hashing. |
| `nix/` | Nim overlay, Nimble dependency fetching, the shared derivation helper. |

## Following the specs

Pinned values are data. Code never carries a root, digest or profile id as a literal: tests read
`spec/pins.toml` and recompute each value from `spec/mirrors/`. When a new spec revision lands, the
steps are in [docs/SPEC-STATUS.md](docs/SPEC-STATUS.md#when-a-spec-revision-lands).

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE-v2) or [MIT license](LICENSE-MIT),
at your option.
