# Conformance and traceability

Every normative unit of the twelve specs has a stable ID. A section we claim must have a test for each
of its units. `tools/spectrace/spectrace.py` does the bookkeeping. In the dev shell it is `spectrace`;
`nix run .#spectrace -- <command>` also works. By default it reads the pinned specs from the
`logos-lips` flake input.

## Requirement ledger

`conformance/requirements/<PFX>.jsonl` holds one line per unit. The first line records the spec file,
the spec revision and the next free ID.

| Prefix | Spec | Prefix | Spec |
|---|---|---|---|
| TRN | transport | PKG | package-manager |
| IFC | interface | CAP | capability-authority |
| RUN | runtime | SEC | security-considerations |
| CFG | configuration | BCP | system-bcp |
| LDR | loader | CMT | commitment-model |
| HSH | hash-profile | CDE | cdcddle |

Unit kinds (G117, G118, I6):

| Kind | Unit |
|---|---|
| `kw` | A sentence, list item or table row with an uppercase BCP 14 keyword. A list item with no keyword inherits its keyword lead-in. |
| `lc` | The same, with a lowercase must, shall or should. Informative: every spec says lowercase forms keep their ordinary meaning, so no claim needs them tested (G117, review item B1). |
| `cddl` | One CDDL rule, identified by its rule name. |
| `block` | Any other fenced block: vectors, C declarations, examples. |
| `heading` | A section heading. |

IDs survive spec revisions. Matching tries an exact fingerprint first (BLAKE3 over kind and
whitespace-normalized text), then the most similar unit of the same kind in the same section
(similarity ≥ 0.8; a CDDL rule matches the rule of the same name, whatever changed). A unit with no match gets a new ID. A unit that
disappears is kept, marked `retired`, and its ID is never reused.

```bash
spectrace sync --specs ~/repos/logos-lips/docs/logos-core/raw --rev <commit>
```

`sync` rewrites the ledger and prints the added, changed, retired and moved IDs per spec; review
that output against the spec diff. `spectrace check` (a flake check) fails while the ledger does not
match the pinned specs.

## Claims

`conformance/claims/<PFX>.toml` gives each section a status. The longest matching section key wins,
and `default` covers the rest. Section keys are `§4.4`, `App B.1`, or `§1/Heading` for an unnumbered
heading under a numbered one.

| Status | Meaning |
|---|---|
| `claimed` | Built. Every live `kw`, `cddl` and `block` unit in the section must be referenced by a test. |
| `deferred:tier-N` | Not built yet; N is the tier in `docs/SPEC-STATUS.md`. |
| `informative` | Nothing to test (only References and Copyright). |
| `out-of-scope:<why>` | Normative, but not this repository's to implement. |

## Properties not claimed

- Protection between processes of the same OS identity (TRANSPORT §8.2 l.1107-1111): Module Hosts
  run as the daemon's user, so a process running as that user can replace a socket pathname or
  impersonate an endpoint. Deployments that need that protection must run hosts under distinct OS
  identities, which this implementation does not set up (DECISIONS G58).

## Unix-stream endpoints and peer checks

TRANSPORT §8.2 and §9.1 as built in `src/logos_core/transport/io/` (DECISIONS G58, I82):

- **Layout.** `<base>/<8 hex>/logos_<module>.sock`. The base is a real directory that only the
  effective uid can write to, or a root-owned sticky directory such as `/tmp` `[IMPL]`. The
  per-instance directory is new (a random name, never reused), owned by the effective uid and set
  to 0700 with `fchmod` whatever the umask. `bind` never follows, removes or replaces an existing
  object; the socket is set to 0600 and listens before any handoff. A path that does not fit
  `sun_path` fails the placement; nothing is shortened.
- **macOS `bind`.** Darwin's `bind` follows a dangling symbolic link at the socket name and creates
  the socket at its target. `bindEndpoint` therefore looks at the name with
  `fstatat(AT_SYMLINK_NOFOLLOW)` first and refuses anything there (TRN-0182). The name is inside
  the Runtime's fresh 0700 directory, so only processes of the Runtime's own identity can race that
  check, which the non-claim above already covers.
- **Listener validation** (`validateEndpoint`): socket type and domain, the listening state, the
  bound name, and the directory's and socket's dev/ino against those recorded at creation. Linux
  reads the listening state with `SO_ACCEPTCONN`. macOS does not answer that `getsockopt`, so it
  reads `soi_options` from `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`. Other Apple systems have
  neither, so validation reports the state as unsupported and fails.
- **Peer check.** `SO_PEERCRED` on Linux and Android; `getpeereid` with `LOCAL_PEERPID` on Darwin
  and iOS. The caller compares the peer's effective uid with the expected identity before it writes
  any byte, and credentials it cannot read count as a mismatch. On a mismatch it closes without
  sending anything, so the ticket is neither disclosed nor consumed, and reports `TRANSPORT_ERROR`.
  The uid is what is checked; a pid is diagnostic only. What a caller sees names the process that
  created and bound the listener (the Runtime, under §8.2), not a Module Host serving the
  transferred descriptor.
- **Paths.** `connect` uses the exact path it is given and derives nothing from a module name.
- **Other-identity test (G129).** A listener created by a different OS user is tested in CI, where
  the job creates a throwaway user (`LCN_PEER_USER`); elsewhere that test is skipped, and a test that
  expects a different uid from a same-uid listener covers the same path.

## Tagging tests

A test covers a unit by carrying its ID in brackets anywhere in the test file, normally in the test
name:

```nim
test "[CDE-0042] map keys sort by encoded bytes":
```

A test of an interim choice for an open item also carries `[IMPL-DECISION Gn]`.

A unit that cannot be tested (pure prose, a rule about other implementations) is covered by an item
in `conformance/inspection/<PFX>.toml` that states why:

```toml
[[item]]
ids = ["HSH-0004"]
reason = "Statement about what a profile document must contain; satisfied by HASH itself."
```

`spectrace gate` (a flake check) fails when a claimed unit has no test or inspection item, when a
test names an unknown or retired ID, or when a claims file has an invalid status.

## Mirrors and pins

`spectrace mirror` checks every file in `spec/mirrors/` against its block in the spec (see
`spec/mirrors.toml`); `--write` refreshes them. `spectrace pins` checks that every value in
`spec/pins.toml` still appears in the section it is pinned from. The tests recompute those values from
the mirrors. `oracle/selftest.py` cross-checks the vectors with an independent implementation.
