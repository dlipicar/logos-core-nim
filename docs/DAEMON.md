# logosd and logosctl

`logosd` hosts one Logos Runtime as a long-running process for one user; `logosctl` is its shell.
This page is the daemon's chapter of the deployment documentation (BOOTSTRAP-COMPOSITION-PROFILES,
BCP), and the documentation BCP l.364 asks for of `logos-core-nim.daemon-config.v1`, logosd's
deployment input. The host configuration logosd derives from it is documented in
[HOST-CONFIG.md](HOST-CONFIG.md); the authority policy in [AUTHORITY-POLICY.md](AUTHORITY-POLICY.md).
Decisions: DECISIONS I95, G293–G304; the CLI module `lcn_call`, I102 and G343–G350.

| | |
|---|---|
| Programs | `logosd`, `logosctl` (POSIX hosts; on Windows each says "not supported on this platform" and exits 2) |
| Packages | `nix build .#logosd .#logosctl`; `nimble install` (POSIX) |
| Session | `--session-dir DIR`, else `$LOGOSCTL_SESSION_DIR`, else `$HOME/.logos-core` |
| Socket | `<session>/run/logosctl.sock` (or in `ctl.socket_dir`), owner-only |
| Wire format | `logos-core-nim.ctl.v1` (§7) |
| CLI module | `lcn_call`, from `liblcn_call` installed with logosd; socket `<session>/run/lcn_call.sock` (or in `cli.socket_dir`), wire format `logos-core-nim.cli.v1` (§7a) |

```sh
logosctl init                 # the session: daemon-config, trust file, evidence key
logosd &                      # or under a service manager (§13)
logosctl status
logosctl module create my_module
logosctl call my_module ping       # through the CLI module, lcn_call (§7a)
logosctl daemon stop --wait
```

## 1. What logosd is

logosd is the host of one Runtime (RUNTIME §13: it calls the Host Embedding API like any embedding
host). It is not a participant: it has no module identity of its own and makes no call as one
(BCP l.102-106). What runs in its process:

- the Module Loader, `logos_module_loader`, established by the Runtime itself;
- the orchestration instance `orchestrator` (the reference module, `lcn_orchestrator`);
- under `capability-authority`, the Capability Authority instance `authority`;
- the `logosctl` instance, which serves the socket (§7);
- every operator module the configuration realizes as `direct_dynamic`.

A `hosted_dynamic` module (placement `process`) runs in its own `logos-module-host` process, which logosd
starts through the Runtime, under logosd's user ([HOST-CONFIG.md](HOST-CONFIG.md), "Module Hosts"). So does
the CLI module `lcn_call` once a CLI command has started it (§7a).

**`direct_dynamic` means this module's payloads are in the daemon's process** (R l.1525-1527): its
method payloads and events pass through logosd's memory, as any in-process module's do. Choose
`hosted_dynamic` for a module whose data should stay out of logosd's process. logosd itself relays no
payload and no event: nothing in its own code, the `logosctl` instance included, carries one.

The packaged logosd is an orc build (`--mm:orc -d:release`). A refc build refuses every contract with a
marked field, as the library does (G277).

## 2. The session directory

```text
<session>/                 0700  $HOME/.logos-core by default
  lock                           held by logosd while it runs, and by offline writers
  daemon-config.cbor       0600  lcn.daemon_config (§3)
  trust.cbor               0600  lcn.package_trust (§6; absent: the compiled-in floor)
  keys/                    0700  evidence keys and their bindings (§9)
  remote/                  0700  with remote.enabled: trust.cbor, lcn.remote_trust (§6a)
    credential/            0700  the TLS credential: key.p8 0600, cert.der, peer.cbor (§6b)
    credential-next/       0700  a rotation not yet taken up (§6b)
    keyholder.count        0600  the key holder's own count (§6b; key-holder mode)
  state/                   0700  trust-mark.cbor, remote-trust-mark.cbor, remote-exposure.cbor (§6c),
                                 store/, modules/, evidence/
  work/                    0700  runtime.work_dir; never emptied (restart locks; remote/ the
                                 listener processes' locks, §10)
  run/                     0700  recreated at each start: logosctl.sock, lcn_call.sock, ep/
```

- Every directory is owner-only. A session directory that group or other can access is refused, as is a
  path component that is a link where a directory is expected.
- `lock` is an advisory lock (`flock`). logosd holds it for its whole life. Every offline `logosctl`
  command that writes (`init`, `daemon config set`, `trust anchor …`, `trust development`,
  `trust reestablish`, `trust evidence-keys rotate`, `remote trust …` and `remote credential …` except
  `show`, `remote exposure reset`, `state purge`), and
  `state list`, which reads the
  Runtime's store under the store's own lock, takes it, and is refused while logosd runs: "another logosd
  or an offline logosctl command holds this session" (exit 1). Other offline reads take no lock.
- `run/` is emptied and recreated at each start while logosd holds the lock, so a socket left by a killed
  daemon never blocks a new one. The Runtime's transport endpoints are under `run/ep/`. Each is
  `run/ep/<8 hex>/logos_<module>.sock`, the module's name cut when the path would not fit `sun_path`
  (DECISIONS G58, amended 2026-11-21). A session directory that leaves no room even for
  `run/ep/<8 hex>/logos_.sock` (the session path plus 28 bytes) fails the start (exit 2) when the
  Runtime serves endpoints, as it does with a Module Host: "start: the endpoint directory: … does not
  fit sun_path …: the base leaves no room for an endpoint". So the session directory's path may be at
  most 75 bytes on macOS and 79 on Linux (`sun_path` is 104 and 108 bytes, its NUL included); the next
  tightest bound is the control socket, `run/logosctl.sock`, at plus 18 (85 and 89) unless `ctl.socket_dir`
  moves it. logosd always
  sets the endpoint directory itself; there is no setting for it.
- `work/` is the Runtime's `work_dir`. It keeps the Module Hosts' restart locks (`work/hosts/`), so it is
  never emptied.
- `state/` holds the Runtime's persistent state (`state/store`, `state/modules`), the trust mark, the
  remote trust mark (§6a) and the call-evidence store (`state/evidence/`, §9).
- **The store is made by `init`, never by logosd.** `logosctl init` writes `state/store/runtime-state.cbor`
  holding the session's Runtime id and no instance. A start that finds no such file is refused (exit 1):
  "the Runtime state store is missing …; restore state/ from a backup, or make a new session with
  logosctl init". The Runtime id is fixed for the session, and the system instance ids are fixed
  strings, so a new store under the old id would give the old instances' addresses to unrelated ones
  (RUNTIME l.2557-2559). A lost `state/` therefore needs a new session; a restored backup of it starts.

## 3. `logos-core-nim.daemon-config.v1`

`<session>/daemon-config.cbor` holds one Logos deterministic-CBOR `lcn.daemon_config` value, at most
64 MiB. It is a protected input: the session's owner writes it, offline (§8). `logosctl init` writes the
first one; `logosctl daemon config get|check|set` read, check and replace it. A change applies at the
next start; logosd reads the file once (SIGHUP is only logged).

```cddl
; logos-core-nim.daemon-config.v1: logosd's protected deployment input (Tier 4b
; step 4b-6; DECISIONS I95, G293). One Logos deterministic-CBOR
; lcn.daemon_config value in <session>/daemon-config.cbor. docs/DAEMON.md
; documents each field (BCP l.359).
;
; logosd derives one logos-core-nim.app-config.v1 value from it
; (daemon/compose.nim, G294) and hands that to logos_runtime_create; it is not a
; configuration_format of the library. Where the host configuration has a rule,
; this format uses it, so a field means the same in both: the rules named
; lcn.app_* and lcn.ap_* are host_config.cddl's and policy.cddl's, resolved in
; one document with this one. Every path is absolute. The checks the schema
; cannot express (reserved names, the strategies an operator may use, the
; development switch, the evidence key's binding) are applied by
; daemon/config.nim before anything starts.

lcn.daemon_config = {
  format: "logos-core-nim.daemon-config.v1",
  runtime: lcn.dc_runtime,
  policy: lcn.dc_policy,
  ? modules: [* lcn.app_module],
  ? declarations: [* lcn.app_declaration],
  ? ordering: [* lcn.app_ordering],
  ? orchestration: lcn.dc_orchestration,
  ? call_audit: lcn.dc_call_audit,
  ? routing: [* lcn.app_routing_rule],
  ? transport: lcn.app_transport,
  ? remote: lcn.dc_remote,
  ? permissions: lcn.dc_permissions,
  ? state_transfers: [* lcn.app_state_transfer],
  ? ctl: lcn.dc_ctl,
  ? cli: lcn.dc_cli,
  ? package_manager: lcn.dc_package_manager,
  ? test_hooks: lcn.dc_test_hooks,
}

; runtime_instance_id: assigned by logosctl init (RUNTIME l.2586) and fixed for
; the session's life. The directories come from the session layout.
lcn.dc_runtime = {
  runtime_instance_id: tstr .size (1..128),
  ? startup_deadline_ms: uint32,
  ? stop_deadline_ms: uint32,
  ? shutdown_grace_ms: uint32,
  ? apply_deadline_ms: uint32,
  ? max_payload_depth: uint16,
  ? module_host: lcn.app_path,
  ? module_host_env: [* lcn.app_env_name],
  ? remote_program: lcn.app_path,
}

; allow-all needs the development switch in the trust file (decision 11).
; capability-authority: the authority instance is logosd's own; rules are the
; operator's, and logosd adds the system rules (DAEMON.md §5). recovery: absent
; is off; logosctl init writes true (RUNTIME l.1676).
lcn.dc_policy =
  { kind: "allow-all" } /
  {
    kind: "capability-authority",
    source: tstr .size (1..128),
    ? decision_validity_ms: uint64,
    ? audit: { ? records: uint64 },
    ? evaluation_deadline_ms: uint32,
    ? recovery: bool,
    rules: [* lcn.ap_rule],
  }

; The orchestration module's value (decision 8): the operator instances it
; starts, and its restart policy. lcn.dc_restart and lcn.dc_override repeat
; lcn_orchestrator.restart and lcn_orchestrator.override (config.cddl).
lcn.dc_orchestration = {
  ? start: [* lcn.app_instance_id],
  ? restart: lcn.dc_restart,
  ? overrides: [* lcn.dc_override],
  ? resync_ms: uint32,
}

lcn.dc_restart =
  { kind: "disabled" } /
  {
    kind: "backoff",
    initial_delay_ms: uint32,
    max_delay_ms: uint32,
    multiplier: uint32,
    ? max_attempts: uint32,
    stable_ms: uint32,
  }

lcn.dc_override = {
  instance: lcn.app_instance_id,
  restart: lcn.dc_restart,
}

; call_records and evidence as in the host configuration; store: logosd's
; call-evidence store (G301), which needs evidence.
lcn.dc_call_audit = {
  ? call_records: uint32,
  ? evidence: lcn.app_evidence_key,
  ? store: lcn.dc_evidence_store,
}

lcn.dc_evidence_store = {
  ? max_records: uint32,
  ? max_age_days: uint16,
  ? queue: uint32,
}

; profile: absent selects the reference profile, since logosd always selects
; one (decision 3). initial: the operator instances' settings; logosd adds the
; system instances' host-ambient settings.
lcn.dc_permissions = {
  ? profile: "logos-core-nim.permission-profile.v1",
  ? initial: [* lcn.app_initial_settings],
}

; The logosctl instance's socket (G296).
lcn.dc_ctl = {
  ? socket_dir: lcn.app_path,
  ? workers: uint8,
  ? idle_timeout_ms: uint32,
}

; The lcn_call instance, the CLI module (DECISIONS G343, G344; DAEMON.md
; §7a). artifact replaces the library installed with logosd; socket_dir must
; be owner-only, as ctl.socket_dir; workers 1-32 (default 8), streams 1-64
; (default 8), idle_timeout_ms 100-600000 (default 30000), route_idle_ms
; 1000-86400000 (default 600000).
lcn.dc_cli = {
  ? artifact: lcn.app_artifact,
  ? socket_dir: lcn.app_path,
  ? workers: uint8,
  ? streams: uint8,
  ? idle_timeout_ms: uint32,
  ? route_idle_ms: uint32,
}

; The Package Manager (DECISIONS G399; DAEMON.md §3; docs/PACKAGE-MANAGER.md):
; instance names an operator entry of modules, hosted_dynamic with placement
; process, with a state_assignment and no configuration; storage holds at
; least one binding, each naming another hosted_dynamic entry, with unique
; names; catalog.storage names one of them. resolver_limits, when present,
; holds all four limits; absent, logosd's preset applies (DAEMON.md §3). The
; lcn.pm_* rules are pm/input.cddl's, resolved in one document as lcn.app_*
; are. logosd composes the instance's lcn.pm_input from this section and the
; trust file the start accepted.
lcn.dc_package_manager = {
  instance: lcn.app_instance_id,
  storage: [* lcn.pm_binding],
  catalog: lcn.pm_catalog_ref,
  ? resolver_limits: lcn.pm_resolver_limits,
  ? limits: lcn.pm_limits,
}

; Accepted only by a logosd built with lcnTestHooks, with the development
; switch on (G300); a packaged logosd refuses the field. The Module Loader
; reports its failure loader_failure_after_ms after the start, or once the
; file loader_failure_on_file names exists, whichever comes first.
lcn.dc_test_hooks = {
  ? ctl_command_delay_ms: uint32,
  ? loader_failure_after_ms: uint32,
  ? loader_failure_on_file: lcn.app_path,
  ? diagnostics: lcn.dc_test_diagnostics,
}

; count diagnostics holding text, recorded as text the Runtime did not write
; once the start's own diagnostics are logged (I95, amended 2026-11-16).
lcn.dc_test_diagnostics = {
  text: tstr .size (1..1024),
  count: uint32,
}

; remote: the remote profile logos.remote.tls-tcp (G407-G410; REMOTE.md).
; enabled: logosd starts its remote side, which needs runtime_instance_id to be
; a lowercase UUID version 4 (RUNTIME l.2592-2593) and the remote trust input
; (section 6a), and refuses policy allow-all (G415). signing: what signs the
; TLS handshakes with the Runtime's key; absent is "logosd". key-holder needs
; key_holder, the logos_keyholder program, and key_holder needs key-holder;
; "process-copy" is accepted only by a logosd built with -d:logosTestSigning.
; listeners and exports (G412; RUNTIME §9.3.9): the deployment's remote
; listener and provider export records, as Runtime Control holds them, only
; with enabled; validated as Runtime Control validates them (l.3319-3321).
lcn.dc_remote = {
  enabled: bool,
  ? signing: lcn.dc_remote_signing,
  ? key_holder: lcn.app_path,
  ? listeners: [* lcn.rc_remote_listener_record],
  ? exports: [* lcn.rc_provider_export_record],
}

lcn.dc_remote_signing = "logosd" / "key-holder" / "process-copy"
```

The rules named `lcn.app_*` and `lcn.ap_*` are the host configuration's and the authority policy's, and
those named `lcn.pm_*` the Package Manager's input's (`pm/input.cddl`), with the meaning those pages give
them ([PACKAGE-MANAGER.md](PACKAGE-MANAGER.md) for the last).

### Fields

| Field | Meaning |
|---|---|
| `runtime.runtime_instance_id` | The Runtime's id (RUNTIME l.2586). `init` assigns a random UUIDv4; it is fixed for the session's life, and `daemon config set` refuses a value that changes it. |
| `runtime.*_deadline_ms`, `shutdown_grace_ms`, `max_payload_depth` | As in the host configuration (§14). |
| `runtime.module_host` | The `logos-module-host` program. Default: `<d>/../libexec/logos-core/logos-module-host` if it exists, else `<d>/logos-module-host`, where `<d>` is the directory of logosd's executable with links resolved. |
| `runtime.module_host_env` | As in the host configuration. |
| `policy` | `allow-all`, which needs the development switch (§6), or `capability-authority`: `source`, the operator's `rules`, and the policy options; logosd adds the system rules (§5). `recovery` absent is off; `init` writes `true` (RUNTIME l.1592). |
| `modules` | Operator instances: `lcn.app_module` with `direct_dynamic` or `hosted_dynamic`. logosd registers no operator binding, so `direct_static` is refused. |
| `declarations` | Modules `module create` may instantiate (RUNTIME l.3481-3490), with the same strategies. |
| `ordering` | Start-order pairs between operator instances. |
| `orchestration` | `start`: the operator instances the orchestrator starts, in order; `restart`, `overrides`, `resync_ms`: its restart policy ([HOST-CONFIG.md](HOST-CONFIG.md), "The reference orchestration module"). An override may name `logosctl` or `authority`. |
| `call_audit` | `call_records` and `evidence` as in the host configuration; `store` (§9) needs `evidence`. |
| `routing`, `transport` | As in the host configuration. |
| `remote` | The remote profile `logos.remote.tls-tcp` ([REMOTE.md](REMOTE.md); DECISIONS G407-G410). `enabled`: logosd starts its remote side, which reads the remote trust input (§6a) and needs `runtime.runtime_instance_id` to be a lowercase UUID version 4 (RUNTIME l.2592-2593). `signing`: what signs the TLS handshakes with the Runtime's key, `logosd` (the default) or `key-holder`, the `logos_keyholder` program at `key_holder` (an absolute path, checked as `runtime.module_host` is); `process-copy` is refused except by a logosd built for tests. |
| `permissions` | `profile`: absent selects the reference profile `logos-core-nim.permission-profile.v1`, since logosd always selects one; `initial`: the operator instances' settings. An entry naming a system instance or module is refused: logosd provisions those itself (§5). |
| `state_transfers` | As in the host configuration: an operator instance's replacement continues from its state, applied once at the next start (§11, "Replacing an instance"). Neither side may be a system instance. |
| `ctl` | The socket (§7): `socket_dir` (absolute; default `<session>/run`), `workers` (1–32, default 4), `idle_timeout_ms` (100–600000, default 30000). |
| `cli` | The CLI module (§7a): `artifact` (`lcn.app_artifact`, an absolute path; default the library installed with logosd, with the hash compiled into logosd), `socket_dir` (absolute, owner-only; default `<session>/run`), `workers` (1–32, default 8), `streams` (1–64, default 8), `idle_timeout_ms` (100–600000, default 30000), `route_idle_ms` (1000–86400000, default 600000). |
| `package_manager` | The Package Manager (DECISIONS G399; [PACKAGE-MANAGER.md](PACKAGE-MANAGER.md)): `instance`, the operator instance that runs it; `storage`, its bindings, each a name and the operator instance that provides `lcn.storage_fetch` under it; `catalog`, the binding, object locator and BLAKE3-256 digest of the catalog it acquires; `resolver_limits`, all four limits or none; `limits`, its bounds. Absent `resolver_limits` is logosd's preset (DECISIONS G443): `partial_closure_names` 256, `dependency_depth` 32, `candidates_per_name` 256 and `assignment_attempts` 1024, the same on every platform and build and never computed from the machine (PM l.1279-1280). An operator may write up to the maxima ([CONFORMANCE.md](CONFORMANCE.md), "Resolver limits"), at the cost [DEPLOYMENT.md](DEPLOYMENT.md) §12 states. A changed preset changes the results of an unchanged configuration (PM l.1314-1315), so it comes with a recorded decision and a release note. Each start logs the limits it composed and their origin, as `package_manager: <instance> gets resolver limits partial_closure_names N, dependency_depth N, candidates_per_name N, assignment_attempts N (logosd's preset)`, or `(package_manager.resolver_limits)` when the section names them. |
| `test_hooks` | Refused by a packaged logosd (§6). `ctl_command_delay_ms` holds each socket command; `loader_failure_after_ms` has the Module Loader report its failure that long after the start, and `loader_failure_on_file` once the file it names exists, whichever comes first; `diagnostics` has the Runtime record `count` diagnostics holding `text`, as text it did not write, after the start's own are logged (§12). |

### The checks

logosd and `logosctl daemon config check|set` run the same checks, in order; the first failure is
reported with the field it concerns, and logosd exits 1.

1. The bytes decode as one deterministic-CBOR `lcn.daemon_config`.
2. Names and strategies: no operator instance uses a reserved id (`orchestrator`, `authority`,
   `logosctl`, `lcn_call`, `logos_module_loader`) and no operator module a reserved name
   (`logos_module_loader`, `logos_capability_authority`, `logosctl`, `lcn_call`, `lcn_orchestrator`); no `direct_static`; `ordering` and
   `orchestration.start` name operator instances, each once; `permissions.initial` names no system one;
   `state_transfers` names no system instance on either side, and no `orchestration.start` entry is
   the source of a transfer (the transfer retires it).
   With `package_manager`: its `instance` is an operator entry of `modules`, `hosted_dynamic` (no
   archive enters logosd's process), with a `state_assignment` and no configuration; `storage` holds
   at least one binding, each name once, each naming another `hosted_dynamic` operator entry; and
   `catalog.storage` names one of them. Then the `lcn.pm_input` composed from the section, the
   resolver limits and the trust file passes the Package Manager's own decoder, which the instance
   runs again at its initialization. A refusal names the field and quotes no bytes.
3. The development switch: `allow-all` and `test_hooks` need it (§6).
4. `ctl`'s and `cli`'s bounds and absolute paths; `call_audit.store` needs `call_audit.evidence`; the evidence key's file, its `kid`
   and its binding name this Runtime (§9).
   `remote`: `key_holder` with `signing` `key-holder` only, and the reverse; `process-copy` only in a
   test build; with `enabled`, the Runtime id is a lowercase UUID version 4.
5. The derived host configuration passes the library's own checks (`logos_runtime_create`'s), and the
   orchestrator's value passes the module's.

### The derived host configuration

With `package_manager`, the value also carries one `protected_inputs` entry: the Package Manager's
instance and its `lcn.pm_input`, its protected realization input (G400; [HOST-CONFIG.md](HOST-CONFIG.md)).
No other instance gets one.

logosd hands one `logos-core-nim.app-config.v1` value to `logos_runtime_create`. It supplies the bootstrap
inputs through it: `work_dir`, `state_root`, `store_dir` and `endpoint_dir` from the session layout, the
Runtime id, the instances of §4, the merged policy of §5, and the permission settings of §5. `routing`,
`transport`, `state_transfers` and `call_audit.call_records`/`evidence` pass through unchanged.

`endpoint_dir` is always `<session>/run/ep`; the daemon configuration has no field for it. Since an endpoint
needs `<endpoint_dir>/<8 hex>/logos_.sock` to fit `sun_path` (DECISIONS G58, amended 2026-11-21), the session
directory's path may be at most **75 bytes on macOS and 79 on Linux**; a longer one fails the start (exit 2)
with "the endpoint directory: … does not fit sun_path …: the base leaves no room for an endpoint" (§2). Before
the amendment the tightest limit was the control socket's, 85 and 89 bytes. The check is the Runtime's at
open, not logosd's at assembly.

## 4. Composition and bootstrap

| Instance | Module | Implementation | State assignment |
|---|---|---|---|
| `logos_module_loader` | `logos_module_loader` | the Runtime's own | none |
| `orchestrator` | `lcn_orchestrator` | `direct_static` binding `lcn_orchestrator` | `orchestrator` |
| `authority` | `logos_capability_authority` | the library's static binding (capability-authority only) | `authority` |
| `logosctl` | `logosctl` | `direct_static` binding `logosctl` | none |
| `lcn_call` | `lcn_call` | `hosted_dynamic`, the companion library or `cli.artifact` (§7a); not started at boot | none |
| operator | daemon-config `modules` | `direct_dynamic` or `hosted_dynamic` | as configured |

- The Module Loader is established first, by the Runtime, before anything else is realized; every other
  instance is realized through it, the system ones included (BCP l.292-296). logosd registers two native
  bindings before start (`lcn_orchestrator`, `logosctl`) and selects nothing else: no instance, binding,
  artifact or profile is substituted for one the configuration names.
- `runtimeStart` returns when the orchestrator is ready. logosd then logs
  `ready: runtime <id>, socket <path>, trust revision N, production|NON-PRODUCTION`.
- The orchestrator starts, in order: `authority` (under capability-authority), `logosctl`, then
  `orchestration.start`, with `ordering` applied. The socket appears when the Loader realizes `logosctl`,
  just after the ready line; a client that finds no socket yet retries. A failure is the
  orchestrator's to report: it logs it (`orchestrator: …` lines) and `logosctl status` shows it.
- A failure before the orchestrator is ready, the Loader's included, ends logosd with exit 2 after the
  host sequence (request shutdown, wait, destroy).

## 5. Authority policy

Under `capability-authority`, logosd merges the operator's rules with its own system rules into one
`logos-core-nim.authority-policy.v1` value for the `authority` instance. The system rules are derived
from the reserved ids and the orchestrator's start list; they are not configurable. With `init`'s
default configuration they are, one per line (S1–S5; S6–S8 below come with `lcn_call`; S9–S11 with
`package_manager`):

```text
{"kind": "allow", "subject": {"modules": ["logos_capability_authority"]}, "scopes": [{"kind": "provider-access", "contract": "capability-authority", "actions": ["publish-event"], "access": {"publish_events": ["observed_change"]}}]}
{"kind": "allow", "subject": {"instances": ["orchestrator"]}, "scopes": [{"kind": "runtime-control", "methods": ["get_self", "list_modules", "get_readiness", "recover_module", "start_module"]}]}
{"kind": "deny", "subject": {"instances": ["orchestrator"]}, "scopes": [{"kind": "runtime-control", "methods": [], "events": ["route_state_changed"]}], "code": "consumer-denied"}
{"kind": "allow", "subject": {"instances": ["orchestrator"]}, "scopes": [{"kind": "module-execution", "targets": {"instances": ["authority", "logosctl"]}, "actions": ["start"]}, {"kind": "permission", "permission": "logos-core-nim.host-ambient"}]}
{"kind": "allow", "subject": {"instances": ["logosctl"]}, "scopes": [{"kind": "runtime-control", "methods": ["get_self", "list_modules", "list_routes", "get_readiness", "get_execution_summary", "get_permission_settings", "get_configuration_schema", "get_configuration_summary", "get_configuration", "update_configuration", "apply_configuration", "create_module", "start_module", "stop_module", "recover_module", "retire_module", "shutdown_runtime"]}]}
{"kind": "deny", "subject": {"instances": ["logosctl"]}, "scopes": [{"kind": "runtime-control", "methods": []}], "code": "consumer-denied"}
{"kind": "allow", "subject": {"instances": ["logosctl"]}, "scopes": [{"kind": "module-execution", "targets": {}, "actions": ["start", "stop"]}, {"kind": "permission", "permission": "logos-core-nim.host-ambient"}]}
{"kind": "deny", "subject": {"instances": ["logosctl"]}, "scopes": [{"kind": "runtime-control", "methods": ["start_module", "stop_module", "recover_module", "retire_module", "update_configuration", "apply_configuration"], "targets": {"modules": ["logos_module_loader", "logos_capability_authority", "logosctl"]}}, {"kind": "module-execution", "targets": {"instances": ["logos_module_loader", "authority", "logosctl"]}, "actions": ["start", "stop"]}], "code": "target-denied"}
{"kind": "deny", "subject": {"instances": ["logosctl"]}, "scopes": [{"kind": "runtime-control", "methods": ["start_module", "stop_module", "retire_module", "update_configuration", "apply_configuration"], "targets": {"modules": ["lcn_orchestrator"]}}, {"kind": "module-execution", "targets": {"instances": ["orchestrator"]}, "actions": ["stop"]}], "code": "target-denied"}
```

- **S1** (the first rule): the Capability Authority may publish its `observed_change` event.
- **S2** (the next three): the orchestrator may call the Runtime Control methods it needs, subscribes to
  no event it does not use, and may start the instances in its start list (here `authority` and
  `logosctl`; an operator `orchestration.start` adds its instances, and an enabled restart policy adds
  `stop`), with `logos-core-nim.host-ambient`.
- **S3** (the next three): the `logosctl` instance may call its seventeen Runtime Control methods (§7),
  subscribes to no event, and may start and stop instances, with `host-ambient`.
- **S4**: `logosctl` may not start, stop, recover, retire or reconfigure the Module Loader, the
  Capability Authority or itself.
- **S5**: `logosctl` may restore the orchestrator only with `recover_module` (R l.3669-3670); it may not
  stop, retire or reconfigure it. The orchestrator is configured only by daemon-config.
- **Codes** (CA l.783-784; DECISIONS G377): the event denials of S2 and S3 deny the consumer an action,
  so they answer `consumer-denied`; S4 and S5 protect the targets they name, so they answer
  `target-denied`.

When logosd composes the CLI module `lcn_call` (§7a), it adds four more:

```text
{"kind": "allow", "subject": {"instances": ["lcn_call"]}, "scopes": [{"kind": "runtime-control", "methods": ["get_self", "list_modules", "describe_provider", "establish_route", "renew_route", "close_route"]}]}
{"kind": "deny", "subject": {"instances": ["lcn_call"]}, "scopes": [{"kind": "runtime-control", "methods": [], "events": ["configuration_state_changed", "permission_settings_changed", "route_state_changed"]}], "code": "consumer-denied"}
{"kind": "deny", "subject": {"instances": ["lcn_call"]}, "scopes": [{"kind": "module-execution", "targets": {}, "actions": ["start", "stop"]}], "code": "consumer-denied"}
{"kind": "deny", "subject": {"instances": ["logosctl"]}, "scopes": [{"kind": "runtime-control", "methods": ["retire_module", "update_configuration", "apply_configuration"], "targets": {"modules": ["lcn_call"]}}], "code": "target-denied"}
```

- **S6**: `lcn_call` may call the six Runtime Control methods a consumer needs to discover providers
  and hold routes (`materialize_route` and `connect_remote` are operations of its binding, not methods).
  A method list with no event list also covers every subscription.
- **S7** (the next two) and **the events rule** (G346): of the Runtime Control events, `lcn_call` may
  follow only `module_state_changed`, `execution_state_changed` and `inventory_changed`, the read-only
  three `logosctl events` follows; each is checked per observed instance before delivery (R l.3362).
  S7's event deny is needed because S6, a method list with no event list, would otherwise allow every
  subscription. It may originate no execution, start or stop, on any target.
- **S8**: `logosctl` may not retire or reconfigure `lcn_call`, whose configuration is daemon-config's; it
  may start, stop and recover it, which is the launcher's activation (§7a).
- **What an operator rule can add.** The system rules give `lcn_call` no provider access: operator rules
  grant it, provider by provider (§7a, "Grants"). An operator rule may also grant it more Runtime Control
  methods, but no rule can let it start or stop an instance, itself included: a start or stop also needs
  an execution decision for the requester, which S7 denies (so `lcn_call` never stops itself, G350). Nor
  can a rule give it another Runtime Control event: S7 denies `configuration_state_changed`,
  `permission_settings_changed` and `route_state_changed`, and a deny wins over any allow (G346). A
  granted `recover_module` would take effect, since a recovery is decided on the authority of the
  instance's original starter (its execution decision is for the retained origin); `lcn_call` never
  calls it. A deny over every other method cannot be written: in this policy language a deny that
  covers a method request covers every event subscription too, which would remove the events rule.
  S3 has the same shape: an operator rule may grant the `logosctl` instance methods beyond its
  seventeen, and only S3's event deny keeps it from every subscription. These limits bind under the
  `capability-authority` policy; under the development switch (allow-all) nothing is denied to any
  module, and neither `lcn_call` nor the `logosctl` instance calls a method outside its list.
- **Codes:** S7 denies the consumer (`consumer-denied`), S8 protects its target (`target-denied`).

With a `package_manager` section (§3), logosd adds five more, here for the instance `package_manager`
with one binding to the instance `storage` (G402):

```text
{"kind": "allow", "subject": {"instances": ["package_manager"]}, "scopes": [{"kind": "runtime-control", "methods": ["close_route", "establish_route", "list_modules", "renew_route"]}]}
{"kind": "deny", "subject": {"instances": ["package_manager"]}, "scopes": [{"kind": "runtime-control", "methods": []}], "code": "consumer-denied"}
{"kind": "allow", "subject": {"instances": ["package_manager"]}, "scopes": [{"kind": "provider-access", "contract": {"commitment_model": "logos.commitment-model.2026-10", "schema_root": h'09f784c92559ee90dcbf3a47248fdaaf64abbfc29b766dc511edbd9587e72429', "hash_profile": "logos.hash-profile.2026-08.choice-index", "hash_suite": "logos.hash-suite.blake3-256"}, "actions": ["call", "establish-route", "renew-route"], "providers": {"instances": ["storage"]}, "access": {"methods": [h'418d34e832ad67e1cd8d7005849c23c7d999bbe7fed23bcb21699af2f5eea306', h'57c99cdac774cfd30bdd6b4b660accab99880c88f92cadbcbfeabd176ae117bc', h'cc09befbc412829dec5ec07657e71a51de1cf8497daafb99bec73568550d95b6']}}]}
{"kind": "allow", "subject": {"instances": ["package_manager"]}, "scopes": [{"kind": "provider-access", "contract": {"commitment_model": "logos.commitment-model.2026-10", "schema_root": h'09f784c92559ee90dcbf3a47248fdaaf64abbfc29b766dc511edbd9587e72429', "hash_profile": "logos.hash-profile.2026-08.choice-index", "hash_suite": "logos.hash-suite.blake3-256"}, "actions": ["subscribe-event"], "providers": {"instances": ["storage"]}, "access": {"subscribe_events": [h'41073cd8d01b1dc9f3a6eca873f2b9e41969984b89163e2f5761d538435f3389']}}]}
{"kind": "allow", "subject": {"instances": ["storage"]}, "scopes": [{"kind": "provider-access", "contract": {"commitment_model": "logos.commitment-model.2026-10", "schema_root": h'09f784c92559ee90dcbf3a47248fdaaf64abbfc29b766dc511edbd9587e72429', "hash_profile": "logos.hash-profile.2026-08.choice-index", "hash_suite": "logos.hash-suite.blake3-256"}, "actions": ["publish-event"], "access": {"publish_events": [h'41073cd8d01b1dc9f3a6eca873f2b9e41969984b89163e2f5761d538435f3389']}}]}
```

- **S9** (the first three): the Package Manager may call the three Runtime Control methods that hold
  a route, and `list_modules`. A route names a provider record, whose id the Runtime assigns, so the
  Package Manager looks up its binding's instance before each establishment: one `list_modules` with
  an `instance` filter per binding. It subscribes to no Runtime Control event (as S3). It may establish
  and renew routes to `lcn.storage_fetch` at its providers and call the contract's three methods
  (`stat_object`, `read_object`, `fetch_readiness`; their roots, in byte order).
- **What S9 does not narrow** (DECISIONS G402). Its Runtime Control rule names no `targets`:
  `establish_route` and a list are decided with no target, `renew_route` and `close_route` name a
  route, and the Capability Authority never narrows an allow ([AUTHORITY-POLICY.md](AUTHORITY-POLICY.md);
  CA l.124 permits narrowing and does not require it), so a rule with `targets` would allow none of
  them. So the Package Manager can read every module record of the Runtime: module names, instances,
  provider addresses, states, contracts, and failure classes with their reasons. Listing a provider
  grants no authority to call it (RUNTIME l.3217); the provider-access rule names the providers.
- **S10**: it may subscribe to `fetch_readiness_changed` on those routes.
- **S11**: the providers may publish that event (STORAGE-FETCH §8).
- **The providers** are the bindings' instances, each once and in byte order, in S9's and S10's
  `providers` and S11's subject; the contract is `lcn.storage_fetch`'s pinned
  commitment.
- **Codes:** S9's event deny denies the consumer (`consumer-denied`). A rule cannot give the Package
  Manager a Runtime Control event, since a deny wins; it needs no other method.

The operator's rules follow, sorted and deduplicated with the system ones. An operator rule may grant
more to operator instances, and may grant the `logosctl` instance access to operator providers; it
cannot undo a system deny, since a deny wins ([AUTHORITY-POLICY.md](AUTHORITY-POLICY.md)).

**Permission settings.** The reference profile is always selected. logosd writes `host-ambient` (empty
constraints) for `orchestrator`, `logosctl`, `authority` and, when composed, `lcn_call`, and the module entry `host-ambient` for each
operator module the operator gave no module entry: the minimum each realization needs. No module
administers the system instances' settings: `update_permission_settings` is not among `logosctl`'s
methods, and no system rule grants it (BCP l.369).

**allow-all** gives every operation to everyone (RUNTIME l.1547). logosd accepts it only with the
development switch on (§6).

**recovery** (RUNTIME l.1592): the derived rules also apply after a binding loss. Absent is off; `init`
writes `true`.

## 6. The trust file and the development switch

`<session>/trust.cbor` is the package trust file (PACKAGE MANAGER l.401-449, l.733-745): one revision
covering the development switch, the package-signing profile and anchors, and the catalog and provenance
selections (DECISIONS G396, G398). Its schema is core's, `src/logos_core/package/trustdoc.cddl`, since the
Package Manager reads the same document. Without the file, the compiled-in floor applies: revision 1,
switch off, no anchor, nothing selected. `state/trust-mark.cbor` records the highest revision used and
the BLAKE3-256 digest of its bytes, written durably before that revision is used.

```cddl
; The package trust file, and the Tier 4b trust file it replaces (Tier 5 step
; 5-3a-2; DECISIONS G137, G299, G396, G398; C2, C3). Each is one Logos
; deterministic-CBOR value; docs/DAEMON.md §6 documents them.

; logos-core-nim.trust.v2, <session>/trust.cbor: the package trust file
; (PACKAGE MANAGER l.401-449, l.733-745). One revision covers every field.
; Closed: an unknown field is refused. development is D27's switch.
lcn.package_trust = {
  format: "logos-core-nim.trust.v2",
  revision: uint64,
  development: bool,
  signing: lcn.trust_signing,
  catalog: lcn.trust_selection,
  provenance: lcn.trust_selection,
}

; The baseline package-signing profile (PACKAGE MANAGER l.485-488) and every
; anchor, in strictly ascending kid byte order (by rule).
lcn.trust_signing = {
  profile: "logos.package-signing.cose-sign1-slh-dsa-sha2-192s",
  anchors: [* lcn.trust_anchor],
}

; One signer: its kid, its key, the exact names it may sign (non-empty and in
; strictly ascending UTF-8 byte order, by rule), and whether it is a
; development anchor, in force only while `development` is on (G137).
lcn.trust_anchor = {
  kid: bstr .size (1..128),
  public_key: bstr .size 48,
  packages: [* tstr .size (1..128)],
  development: bool,
}

; A profile selection. An empty section selects none (PACKAGE MANAGER l.736). A
; selected profile this build does not support is refused (l.745; C3, C9).
lcn.trust_selection = {
  ? selected: tstr .size (1..128),
}

; logos-core-nim.trust.v1: the Tier 4b trust file (G299). Still read, as the
; v2 content with no anchor and nothing selected; never written.
lcn.trust_file = {
  format: "logos-core-nim.trust.v1",
  revision: uint64,
  development: bool,
}
```

```cddl
; logosd's trust continuity record and the binding of a call-evidence key
; (Tier 4b step 4b-6; DECISIONS I95, G297, G299). Each is one Logos
; deterministic-CBOR value in a file of its own; docs/DAEMON.md documents
; them. The trust file itself, lcn.package_trust, is package/trustdoc.cddl
; (G396).

; logos-core-nim.trust-mark.v1, <session>/state/trust-mark.cbor: the highest
; revision of the trust file used and the digest of that revision's bytes
; (BLAKE3-256; PACKAGE MANAGER l.401-406).
lcn.trust_mark = {
  format: "logos-core-nim.trust-mark.v1",
  revision: uint64,
  digest: bstr .size 32,
}

; logos-core-nim.evidence-key.v1, <session>/keys/evidence-<kid>.cbor: the
; call-evidence key a kid names, and the one Runtime it signs for (CAPABILITY
; AUTHORITY l.1265, l.1290). kid is the first 16 bytes of BLAKE3-256 of the
; public key. A retired key keeps its binding, with retired_ms, and loses its
; secret half.
lcn.ev_key_binding = {
  format: "logos-core-nim.evidence-key.v1",
  kid: bstr .size 16,
  runtime_instance_id: tstr .size (1..128),
  public_key: bstr .size 48,
  created_ms: uint64,
  ? retired_ms: uint64,
}
```

What the schema does not say (`package/trustdoc.nim`; key separation is `daemon/trustfile.nim`'s):

- **Canonical form.** Anchors in strictly ascending `kid` byte order, so no two share a kid; each
  anchor's `packages` non-empty and in strictly ascending UTF-8 byte order, so each name once. One
  content has one encoding, so the mark's digest names contents, not spellings.
- **Names are exact.** Compared byte for byte, never folded or normalized; no name is special (`*`
  authorizes only a package named `*`).
- **Keys** are any 48 bytes; two kids may share a key. No anchor may use a call-evidence key of the
  session, retired ones included (§9). A start reads the bindings for this only when the file names an
  anchor, and a binding it cannot read then refuses the start.
- **Bounds.** The file is at most 1 MiB; that is its only bound beyond the schema's.
- **Revision.** Not below the floor's, 1.
- **Development anchors** (`development: true`) are in force only while the file's `development` switch
  is on: turning the switch off withdraws them in the same revision.
- **Selections.** No catalog profile is built, and no provenance profile until Tier 5 step 5-11: a file
  that selects either is refused, naming the profile, before continuity, so a refused revision never moves
  the mark.
- **Format v1** (`logos-core-nim.trust.v1`, Tier 4b) is still read, as the v2 content with no anchor and
  nothing selected, with the digest of its own bytes, so a Tier 4b session keeps its continuity. Every
  writer writes v2.

At each start logosd reads and decodes the file, applies the rules, refuses an anchor whose key is an
evidence key, builds the package-signing trust input from the anchors in force, and only then reads the
mark and decides, so nothing is refused after the mark moved:

| Mark | File | Decision |
|---|---|---|
| absent | any | refused: "trust continuity is not established" |
| revision r | revision > r | the mark is written, then the revision used |
| revision r | revision = r, same digest | accepted (an identical replay) |
| revision r | revision = r, other digest | refused: a changed file needs a higher revision |
| revision r | revision < r | refused: rollback |

A session without `trust.cbor` reads the v2 floor, whose digest is not the Tier 4b floor's: when its mark
holds revision 1 with the v1 floor's digest, the refusal names the fix, `logosctl trust reestablish
--revision 1`.

A refusal is exit 1. logosd never creates a mark. `logosctl init` writes the file and its mark together;
`logosctl trust reestablish --revision N` writes a mark from the current file when the owner names its
revision (after the mark alone was lost, or `state/` was restored from a backup; a lost `state/` also
lost the Runtime's store and needs a new session, §2). It first applies everything a start applies before
continuity (the schema and bound, the rules, key separation, the conversion), so the mark never names a
revision logosd refuses; a file that fails is refused and no mark is written. The trust file is read twice
during start, and a change between the reads is refused.

**The development switch** (D27). `logosctl trust development on|off` writes the next revision with the
switch set or cleared, and nothing when it is already so; `init --development` starts at revision 2 with it
on, so revision 1 keeps the floor's content. With the switch on:

- `policy: allow-all` is accepted;
- `test_hooks` is accepted by a logosd built with test hooks (a test build). A packaged logosd has none
  and refuses the field whatever the switch says: "test_hooks: this logosd has no test hooks". The flake
  check `no-test-hooks` verifies no packaged output holds hook code;
- development anchors (`development: true`) are in force, so packages they sign verify;
- the deployment is **non-production**, and says so: a `NON-PRODUCTION` warning in the start log; every
  `logosctl` output, online and offline (`deployment: "non-production"` in JSON, a
  `NON-PRODUCTION deployment` line in text); every socket reply's `deployment`.

The switch weakens nothing else. Continuity still applies (a rollback is refused with the switch on), the
other anchors and every rule of the file are unchanged, and under capability-authority the system rules still
deny, for example, `module stop logos_module_loader`.

**The Package Manager's copy** (G399, G400). With `package_manager` (§3), each start puts the trust state
it accepted, as the trust file's deterministic bytes, into the Package Manager's `lcn.pm_input`. The
instance reads its copy once, at initialization, and checks it again. A trust command therefore applies
to it at the next start, never to a running instance. The copy is protected input, not configuration
(CONFIGURATION l.58): no Runtime Control method reads or changes it.

### The trust commands

`logosctl trust` administers the file offline, under the session lock (DECISIONS G397). Every change
applies at the next start, when logosd reads the file again (BCP l.364): a removed anchor or name, or the
switch turned off, is withdrawn from that start on, and nothing running is affected before it.

| Command | What it does |
|---|---|
| `trust show` | the revision, the switch, the profile, the selections, the mark and what continuity would decide; each anchor with its kid (in hex, and as text when `--kid` would read that text back as the same kid), its names, its key, its development marker and whether the file puts it in force. The file is decoded without the rules, so a file logosd refuses is shown, with the reason; continuity is then "not reached", since a start applies the rules first |
| `trust anchor add --kid KID --key HEX [--development] NAME…` | a new anchor authorizing the names. A kid already present is refused (`add-names` adds names to it) |
| `trust anchor remove --kid KID` | removes the anchor: a withdrawal (PACKAGE MANAGER l.436-437). A kid that names no anchor is refused |
| `trust anchor add-names --kid KID NAME…` | adds names; one added name is a new revision (PACKAGE MANAGER l.420) |
| `trust anchor remove-names --kid KID NAME…` | removes names, all or nothing: a name the anchor does not authorize is refused, naming every such name, and none is removed; leaving the anchor none is refused (remove the anchor instead) |
| `trust development on\|off` | the switch, and how many development anchors enter or leave force with it |
| `trust reestablish --revision N` | the mark, as above |
| `trust evidence-keys ls\|rotate` | the call-evidence keys (§9) |

- `KID` is text, or `hex:` and hex digits, as `lcn-pkg sign --kid` takes it, so the operator passes the
  value the producer signed with. `HEX` is the public key's 96 hex digits, or `@FILE` holding them alone
  or as the `public key: <hex>` line `lcn-pkg keygen` prints; surrounding whitespace is ignored. A name is
  taken as given, 1 to 128 bytes; the file keeps names and anchors in canonical order whatever order they
  are given in.
- **Every writer** reads the current file, makes its one change, and checks the result as a start would
  (schema and bound, the rules, key separation against every evidence key of the session, the conversion),
  so it never writes a file logosd refuses. The result is written as the next revision, in format v2, and
  the command says "it applies at the next start". A Tier 4b v1 file becomes v2 with its first change,
  without re-establishment.
- **A command that adds or sets what is already so writes nothing**: names already present, the same
  anchor added again, the switch set as it is. The command exits 0 and says "unchanged" (`"changed":
  false` in JSON), so scripts can repeat it and no revision is spent on nothing.
- **A command that withdraws what is not there is refused** (exit 1, nothing written): `anchor remove`
  of a kid that names no anchor ("no anchor has kid HEX"), and `anchor remove-names` with a name the
  anchor does not authorize. Names match byte for byte (PACKAGE MANAGER l.418-419), so a name in another
  case or normalization form is not there. A mistyped withdrawal then fails instead of passing for one
  while the key or name it meant stays in force. `add-names` and `remove-names` refuse a kid that names no
  anchor too.
- **A file logosd refuses** is refused by every writer, a change that changes nothing included, and the
  refusal ends "correct trust.cbor by hand, then run a trust change or logosctl trust reestablish
  --revision N". A selection written by hand is one such file: no command selects a catalog or provenance
  profile, since none can be selected. A change that removes what is refused (for example, removing an
  anchor whose key is an evidence key) is written.
- JSON follows §7's envelope with `deployment` (DECISIONS G89). `trust show`'s result carries the file's
  fields (`revision`, `development`, `signing` with `profile` and `anchors`, `catalog`, `provenance`; keys
  and kids in hex), `file`, `mark`, `continuity` and, for a file logosd refuses, `refusal`, the reason a
  start would give. Each anchor also carries `in_force`, what the file says (its switch and the anchor's
  marker), not what a running logosd uses, which is the revision it started with; and `kid_text`, the kid
  as text, only when it is printable ASCII and does not begin `hex:` (`--kid` would read such a text as hex
  digits, another kid). A writer's result carries `revision` and `changed`, an anchor command's `kid`, and
  `trust development`'s `development` and `development_anchors`, the number of anchors the file marks
  `development`, whether or not anything changed.

## 6a. The remote trust input

With `remote.enabled` (§3), `<session>/remote/trust.cbor` is the remote trust input (RUNTIME §9.3.7,
l.2590-2682; DECISIONS G408): the complete remote trust-anchor set and the enrollment records, under one
revision of its own, apart from the package trust file. `state/remote-trust-mark.cbor` records the highest
revision used, the BLAKE3-256 digest of that file's bytes, its anchor set, and for each enrollment key
(`runtime_instance_id`, `profile`) the record accepted, or every record of a conflict. Without
`remote.enabled` logosd reads neither file, so a session that never enables it needs neither.

The enrollment records are RUNTIME's published supporting schema, `logos.runtime_enrollment`
(l.2599-2632), held unchanged: a record another implementation writes reads as it is. A supporting schema
imports nothing (COMMITMENT §3.1 step 6), so lcn-gen appends the mirrored rules
(`spec/mirrors/RNT/9.3.7.runtime-enrollment.cddl`) to the document below, each name
`logos.runtime_enrollment.x` renamed `lcn.enrollment_x`; nothing else changes, and CBOR carries no rule
name. Each anchor is a direct anchor (G324): the DER certificate the Runtime enrolled under it presents.
The peer file is what `logosctl remote credential` writes for each peer and `remote trust import`
reads.

```cddl
; logosd's remote trust input and its continuity mark (Tier 5 step 5-7a-1;
; DECISIONS G408; RUNTIME §9.3.7, l.2590-2682). Each is one Logos
; deterministic-CBOR value in a file of its own; docs/DAEMON.md §6a documents
; them. The enrollment records are RUNTIME's published supporting schema,
; logos.runtime_enrollment (l.2599-2632), held unchanged: lcn-gen appends the
; mirrored rules (spec/mirrors/RNT/9.3.7.runtime-enrollment.cddl) to this
; document, each name logos.runtime_enrollment.x renamed lcn.enrollment_x, since
; a supporting document imports nothing (COMMITMENT §3.1 step 6). The names
; below that start lcn.enrollment_ are those rules.

; logos-core-nim.remote-trust.v1, <session>/remote/trust.cbor: the complete
; trust-anchor set and the enrollment records, under one revision (l.2673)
; that every offline change raises by one. Each anchor is a direct anchor
; (owner decision B2; G324): the DER certificate the Runtime enrolled under it
; presents.
lcn.remote_trust = {
  format: "logos-core-nim.remote-trust.v1",
  revision: uint64,
  anchors: [* lcn.remote_anchor],
  enrollments: [* lcn.enrollment_remote_runtime_enrollment],
}

lcn.remote_anchor = {
  id: lcn.enrollment_trust_anchor_id,
  certificate: bstr .size (1..16384),
}

; logos-core-nim.remote-trust-mark.v1, <session>/state/remote-trust-mark.cbor:
; the highest revision used, the BLAKE3-256 of that file's bytes, its anchor
; set, and for each enrollment key (runtime_instance_id, profile) the newest
; record accepted, or every record of a conflict at that revision (l.2650-2654,
; l.2664, l.2674).
lcn.remote_trust_mark = {
  format: "logos-core-nim.remote-trust-mark.v1",
  revision: uint64,
  digest: bstr .size 32,
  anchors: [* lcn.remote_anchor],
  enrollments: [* lcn.enrollment_remote_runtime_enrollment],
}

; logos-core-nim.remote-peer.v1: what logosctl remote credential writes for the
; operator to give each peer, and logosctl remote trust import reads there:
; one Runtime's anchor and its enrollment record, which names that anchor.
lcn.remote_peer = {
  format: "logos-core-nim.remote-peer.v1",
  anchor: lcn.remote_anchor,
  enrollment: lcn.enrollment_remote_runtime_enrollment,
}
```

**At start**, before any remote process starts, logosd applies the input's rules (schema and the 16 MiB
bound; anchor ids distinct; each enrollment key once; each Runtime id a lowercase UUID version 4,
l.2592; an active record's keys distinct), reads it twice as the package trust file is read (a change in
between refuses the start), and decides against the mark:

| Mark | File | Decision |
|---|---|---|
| absent | any | refused: re-establish (l.2680-2682) |
| revision r | revision > r, the enrollment rules pass | mark written, then used |
| revision r | revision = r, same digest | accepted (identical replay; l.2676) |
| revision r | revision = r, other digest | refused (l.2675) |
| revision r | revision < r | refused (l.2675) |

- **The enrollment rules**, for a file above the mark, key by key against the mark's record
  (l.2650-2656): a higher revision replaces it; the same record keeps it; a different record at the same
  revision is a **conflict**: logosd starts, that identity is rejected (G324: the verifier holds it as
  conflicting, with every key either record names) until a later file carries a higher revision for the
  key, and the start logs `remote-trust-report: Runtime … has 2 conflicting records …`. A `revoked`
  record supersedes lower revisions and admits no session (l.2655), from the next start (B3).
- **Two rules are stricter than the text** (G408): a **stale record** (a lower revision than the mark's
  for its key) refuses the whole start, not only that peer, since the file as a whole is then older than
  what this node accepted; and a **key the mark holds that the file omits** refuses the start, since the
  text has no deletion, only revocation, so records are kept for good. REMOTE.md gives their cost.
- **Refused** means logosd does not start (exit 1) and names the cause; the mark is unchanged. Both
  inputs' checks are done before either mark moves, so nothing is refused after a mark moved except a
  failed write (G299).
- **The loader report** (G324 extended): the start logs `remote-trust-report:` lines, and the offline
  commands print the same, for (1) an active `tls-tcp` record whose anchor is not in the set, or whose
  anchor's key is not among its keys; (2) a record's key no anchor can match (under a direct anchor only
  the anchor certificate's key can); (3) an anchor that cannot be a direct anchor (not a self-issued
  P-256 certificate signed by its own key; a CA; Key Usage without digitalSignature; Extended Key Usage
  without both serverAuth and clientAuth, since a Runtime is both; a critical extension validation does
  not process) or that no active record names. Records stay unchanged and fail closed in the verifier;
  `anchor add` refuses (3) up front. A record whose anchor was withdrawn stays in force as data and fails
  every handshake at the anchor check.
- **The snapshot** the remote processes take at spawn (`transport/tls/trustsnap.nim`): every anchor by its
  id in lowercase hex at the input's revision, and the current record of each `logos.remote.tls-tcp`
  key. Records of `logos.remote.quic` are held and unused.

### The remote trust commands

Every command is offline; every writer holds the session lock and is refused while logosd runs. Every
change applies at the next start of logosd (B3), and the command says so.

| Command | What it does |
|---|---|
| `remote trust init` | an empty input at revision 1 and its mark. Refused where either exists, which would roll back |
| `remote trust show` | the revision, the mark, what continuity would decide (or the refusal a start would give), each anchor with its check, each record, and the report |
| `remote trust reestablish --revision N` | after loss of the mark: a new one from the current file, when N is the file's revision and the file passes the start's rules. A conflict the lost mark held is gone (l.2680-2682) |
| `remote trust anchor add CERT [--id HEX]` | a direct anchor from a DER certificate file, its id the certificate's BLAKE3-256 unless `--id` names one. The same anchor again changes nothing; the same id with another certificate is refused |
| `remote trust anchor remove --id HEX` | a withdrawal (l.2677). Records that name the anchor stay, and fail closed |
| `remote trust enroll add @RECORD` | one record, `.cbor` or `.diag`, in the published schema: a new key, or a higher revision than the record held. The same record changes nothing; a lower revision, or another record at the same revision, is refused, so no command makes a stale record or a conflict |
| `remote trust enroll revoke RUNTIME [--profile tls-tcp\|quic]` | a `revoked` record one revision above the record held; it adds that the restart is what closes that Runtime's connections |
| `remote trust import @PEER` | a peer file's anchor and record as one change; the record must name that anchor. `--node` and `--address`, which add the peer to `lcn_call`'s nodes, come with the nodes (5-7a-4) |

- **Every writer** builds the next file with one edit and checks it as a start would, against the mark
  when there is one, so it never writes a file logosd refuses. It writes revision + 1, or nothing when the
  edit changes nothing ("unchanged", `"changed": false`).
- Provisioning errors are printed locally, exit 1; no command reports through the Logos error registry
  (RUNTIME l.2646-2649).
- JSON: `remote trust show`'s result carries `file`, `revision`, `digest`, `mark`, `continuity`,
  `refusal`, `anchors` (`id`, `certificate_bytes`, `problems`), `enrollments` (`runtime`, `profile`,
  `revision`, `status`, and for an active one `anchor` and `keys`, in hex), `report` and `conflicts`. A
  writer's result carries `revision`, `changed`, `report` and `conflicts`.

## 6b. The TLS credential

With `remote.enabled`, logosd authenticates to other Runtimes with one long-term P-256 key and a
self-signed certificate that each peer holds as a direct anchor (owner decision B2; DECISIONS G409,
G324). Both are in `<session>/remote/credential/`:

| File | What |
|---|---|
| `key.p8` | the private key, PKCS#8, mode 0600, never a link |
| `cert.der` | the certificate: ecdsa-with-SHA256, signed by its own key; Key Usage critical digitalSignature; no Extended Key Usage; subject `CN=logos runtime <id>`, which no verifier uses; valid from 300 s before it was made |
| `peer.cbor` | `lcn.remote_peer` (§6a): the anchor (its id the certificate's BLAKE3-256) and this Runtime's enrollment record naming it with the one key, for each peer to import |

- **A start with `remote.enabled` and no credential is refused** (exit 1): "remote.enabled needs a TLS
  credential: logosctl remote credential new makes one". A start logs the certificate's SHA-256, the
  enrollment revision and who signs.
- **The key is separate from every other key** (PKG-0435; CA l.1312): its own command, file and
  algorithm. The call-evidence key loader refuses `key.p8` and the TLS loader refuses an evidence key,
  by shape and by path.

| Command | What it does |
|---|---|
| `remote credential new [--days N]` | the session's first credential, valid N days (default 3650, at most 36500), its record at revision 1. Refused when one exists |
| `remote credential show` | the credential, a pending rotation, and the key holder's count, without the key |
| `remote credential rotate [--days N]` | the next credential in `remote/credential-next/`, its record at the current revision + 1 with the new key alone. Refused while one is pending |

- `new` and `rotate` hold the session lock and are refused while logosd runs. Each prints the
  certificate's SHA-256, the anchor id, the key and the peer file to give each peer (`logosctl remote
  trust import @peer.cbor` there).
- **Rotation is a cutover** (G324 limit 1): an enrollment names one anchor and a direct anchor has one
  key, so old and new keys cannot overlap. Each peer imports the new peer file; this node takes the
  rotation up at its next start with `remote.enabled`. It renames `credential` to `credential-old`, then
  `credential-next` to `credential`, and removes `credential-old`, overwriting its key first. A start
  interrupted between or after the renames finishes them. Connections with a peer fail from the first of
  the two restarts until both hold the new credential. REMOTE.md gives the order of steps.
- JSON: `credential` (and `pending`) carry `runtime`, `revision`, `certificate_sha256`, `anchor_id`,
  `spki`, `certificate` (hex), `not_before`, `not_after` (UTC) and `peer_file`; `show` adds
  `key_holder` (`signed`, `refused`) once the holder has written its count.

**Who signs** (`remote.signing`, §3; owner decision B1; G410). The TLS processes hold no key: each sends
its handshake's CertificateVerify input over its control channel, and the answer is a signature or a
refusal, which fails that handshake.

| `remote.signing` | Who holds the key |
|---|---|
| absent or `logosd` | logosd's signing service, which loads `key.p8` at start |
| `key-holder` | `logos_keyholder` (the program `remote.key_holder` names), which loads `key.p8` itself. logosd never opens it: it checks the credential at start without reading the key, and relays each request to the holder |
| `process-copy` | each TLS process, sent the key at spawn; accepted only by a logosd built with `-d:logosTestSigning` (tests) |

- Each request is checked where it is signed, and in key-holder mode by logosd too: a TLS 1.3
  CertificateVerify input for the role logosd fixed for that process (a request names none), ECDSA
  P-256 with SHA-256 only, at most 100 a second with bursts of 200 for each process at logosd and for
  the holder as a whole [IMPL].
- The key holder takes `--session=<dir> --parent=<logosd's pid>` and its channel as descriptor 3. It
  binds itself to logosd first and exits once logosd is gone (its channel ends, or its parent changes).
  It keeps its own count in `remote/keyholder.count` (two lines, `signed N` and `refused N`, carried
  across its runs, written every 60 s while it changes and at its exit), which logosd neither writes nor
  reads. logosd starts the holder at its start in key-holder mode, before any listener process.

**logosd holds no TLS code** (G409). It signs through BoringSSL's libcrypto
(`transport/tls/p256.nim`) and imports no libssl binding (lint `daemon-no-ssl`). The binding compiles
libssl's sources into every program that imports it. logosd's link drops them by dead stripping, and
the binary is checked to hold none of their symbols: `test_logosd` checks plain builds, and the flake
check `logosd-no-ssl` checks the deployed logosd. The link line still names libssl's objects.

## 6c. Durable remote disables

A listener's `enabled` or `runtime_control_enabled`, or an export's `enabled`, turned off through
Runtime Control stays off across restarts and crashes; an enable through Runtime Control lasts for the
run (Q4 as planning ruled; DECISIONS G412; RUNTIME leaves it open, l.3289, l.3319-3321). The fields
turned off are kept in `state/remote-exposure.cbor` (`daemon/remote_exposure.cddl`,
`logos-core-nim.remote-exposure.v1`), one entry per listener address or per export (the listener
address and the provider id), with the fields off, the consumer that turned them off and when, and the
BLAKE3-256 digest of the configuration's entry for that key as that run started.

- **A disable** turns the exposure off for the run first (new connections stop, Runtime Control
  sessions end where Runtime Control was turned off), then writes the entry. A failed write fails the
  call with MODULE_ERROR "disabled for this run; not recorded, so the next start applies the
  configuration: <cause>", the exposure still off; a repeat once the write can succeed records it.
- **An enable** removes the entry first, then turns the exposure on; a failed removal fails the call
  and the exposure stays off.
- **At start** each entry whose digest matches its configuration entry is applied, so the record starts
  with those fields off, logged as `remote exposure: kept disabled: …`; any other entry (its
  configuration entry changed or gone, or a record Runtime Control made) is dropped, logged as `remote
  exposure: dropped, …`, and the file rewritten.
  So changing a listener's or export's configuration entry (`daemon config set`) re-enables it.
- **Offline:** `logosctl remote exposure list` prints the entries (a reader: no lock). `logosctl remote
  exposure reset (--listener ADDR [--provider ID] | --all)` removes entries under the session lock,
  applying at the next start; ADDR is the address as `list` prints it (`tls-tcp HOST:PORT` and any
  optional field as ` name=value`).

## 7. The logosctl instance and its socket

The `logosctl` module is a consumer-only module linked into logosd (`direct_static`), realized by the
Loader like every instance, and persistent. Its instance serves the socket. Each command becomes one
Runtime Control call **by the instance**, through its own binding: the shell is never the consumer.

### Activation (BCP l.389)

The socket is external application activation, documented by the five items BCP l.389 lists:

1. **Mechanism.** A Unix stream socket at `<session>/run/logosctl.sock` (or `ctl.socket_dir`), in a
   directory owned by logosd's user with mode 0700, the socket itself 0600. The path is handed to the
   instance at initialization (the presentation handoff, item 4) and must fit `sun_path`; a longer path,
   or a `ctl.socket_dir` that group or other can access, is exit 1 naming `ctl.socket_dir`.
2. **Admission.** Each connection's peer credentials are read on accept. A peer of another uid is closed
   with nothing written, and logged ("refused a connection from uid U pid P", at most one line per
   second). The shell does the converse: before it sends anything it checks that the listener runs as its
   own uid, and refuses otherwise ("nothing was sent").
3. **Selection.** The socket reaches exactly one instance, `logosctl`, accepted and realized by the
   Loader. No command selects an artifact, chooses an instance id, grants anything or bypasses a
   realization constraint (BCP l.391-392): the commands are the seventeen methods below, with the
   Runtime's own checks.
4. **Presentation handoff.** At initialization logosd hands the instance, in process: the socket path,
   the worker count and idle timeout, the deployment, the trust revision, logosd's version and start
   time. Nothing that authenticates a caller crosses it, or the socket: no binding, ticket or invocation
   descriptor. Addresses cross only as data, never as identity (R l.1522, l.2489).
5. **Failure behaviour.** The instance binds the socket during its initialization and serves only after
   initialization returned; a command that arrives earlier waits (BCP l.393). A bind failure fails the
   initialization; the orchestrator reports it and there is no socket. What the shell sees:

| Situation | `logosctl` |
|---|---|
| No daemon, or no socket yet | exit 2, "no daemon" |
| Busy | retried until `--timeout`, then exit 2 |
| A listener of another uid | nothing sent; exit 2 |
| A frame the instance refuses | `refused` with its reason; exit 1 |
| A Runtime Control failure | exit 4, with the code and message |
| The reply lost after the command was sent | exit 2; the outcome is unknown (`module create` prints its request key) |

**Same user, same authority.** The peer check admits every process of logosd's user. Each of them can
drive the instance with all of its grants, so the grants are the least the commands need (S3–S5). A
shared operating-system user is not an isolation boundary (TRANSPORT l.1088): run logosd under a user of
its own where that matters. The peer's uid and pid are kept with each command as requester provenance, in
the instance's log lines; they never reach a Runtime Control request and never stand for the consumer
(BCP l.387).

**No payload is relayed.** The seventeen methods are reads, lifecycle, configuration and shutdown. No
method payload of any operator module, and no event, crosses the socket or passes through the instance.
Calls to providers from the command line go through the CLI module `lcn_call` (§7a), a module instance
of its own whose routes carry the payloads between module processes; neither this instance nor logosd
relays them. The shell never holds a route, ticket or endpoint: for `call` and `describe` it is only
`lcn_call`'s launcher.

### The methods

`get_self`, `list_modules`, `list_routes`, `get_readiness`, `get_execution_summary`,
`get_permission_settings`, `get_configuration_schema`, `get_configuration_summary`, `get_configuration`,
`update_configuration`, `apply_configuration`, `create_module`, `start_module`, `stop_module`,
`recover_module`, `retire_module`, `shutdown_runtime`. Nothing else (`evaluate`, the permission and remote
methods) can be encoded. `list_routes` returns no invocation in any record (R l.3223).

`module create` carries a request key: `lcli-` and 32 random hex digits, generated by the shell for each
command and printed with the result. `--request-key K` repeats an earlier key, so a create whose answer
was lost can be retried, across a daemon restart too, and returns the same instance.

### The wire format `logos-core-nim.ctl.v1`

BCP l.395 assigns no encoding; this one is logos-core-nim's.

- A frame is a 4-byte big-endian length and one Logos deterministic-CBOR value, at most 32 MiB
  (33554432 bytes) each way.
- A connection carries any number of message and reply pairs, in sequence. It is closed after
  `idle_timeout_ms` without a complete message (a partial frame included), and after a refusal.
- A message is `lcn.ctl_message`; the reply `lcn.ctl_reply`, which always names the deployment.
- `rc` carries a method, the Runtime Control request bytes, and an optional deadline. The instance makes
  one Runtime Control call with those bytes, deadline `min(deadline_ms, 60 s)`, and returns the response
  bytes verbatim (BCP l.397), or the call's error code, message and detail. It does not decode `params`:
  the Runtime validates them as for any consumer.
- `daemon-info` returns `lcn.ctl_daemon_info` (one `get_self` call for the Runtime id).
- A refusal names its reason: `protocol` (not one deterministic-CBOR map of this protocol), `command`
  (not a valid command), `too-large`, `busy` (every worker taken; sent as the connection is accepted, and
  nothing ran) or `closing`.

```cddl
; logos-core-nim.ctl.v1: the protocol between the logosctl shell and the
; logosctl instance's socket (Tier 4b step 4b-6; DECISIONS G296; BOOTSTRAP
; l.384-390). BOOTSTRAP assigns no interoperable encoding, so this one is the
; implementation's own; docs/DAEMON.md §7 documents it.
;
; A frame is a 4-byte big-endian length, then one Logos deterministic-CBOR
; value of at most 33554432 bytes. One connection carries any number of
; request and response pairs, in sequence: an lcn.ctl_message from the shell,
; then an lcn.ctl_reply from the module. (Names ending in _request or
; _response are callable rules, INTERFACE §1.3, so these are not.)

lcn.ctl_message = {
  protocol: "logos-core-nim.ctl.v1",
  command: lcn.ctl_command,
}

; daemon-info: the presentation logosd handed to the module, and the Runtime's
; id. rc: one Runtime Control call by the logosctl instance, with these
; request bytes; the response bytes come back verbatim.
lcn.ctl_command = lcn.ctl_info_command / lcn.ctl_rc_command

lcn.ctl_info_command = { op: "daemon-info" }

lcn.ctl_rc_command = {
  op: "rc",
  method: lcn.ctl_method,
  params: bstr .size (0..33554432),
  ? deadline_ms: uint32,
}

lcn.ctl_method = "get_self" / "list_modules" / "list_routes" / "get_readiness" /
  "get_execution_summary" / "get_permission_settings" /
  "get_configuration_schema" / "get_configuration_summary" /
  "get_configuration" / "update_configuration" / "apply_configuration" /
  "create_module" / "start_module" / "stop_module" / "recover_module" /
  "retire_module" / "shutdown_runtime"

lcn.ctl_reply = {
  protocol: "logos-core-nim.ctl.v1",
  deployment: lcn.ctl_deployment,
  outcome: lcn.ctl_outcome,
}

lcn.ctl_deployment = "production" / "non-production"

lcn.ctl_outcome = lcn.ctl_ok / lcn.ctl_rc_error / lcn.ctl_refused

; result: the Runtime Control response, or for daemon-info an
; lcn.ctl_daemon_info value.
lcn.ctl_ok = { status: "ok", ? result: bstr }

; The shared error channel's values (INTERFACE §5.1, §5.2): the code, and
; the message and detail the Runtime forwarded.
lcn.ctl_rc_error = {
  status: "rc-error",
  code: uint8,
  ? message: tstr .size (0..512),
  ? detail: bstr .size (0..4096),
}

; A frame or a command the module refuses; the connection is closed after it.
lcn.ctl_refused = {
  status: "refused",
  reason: "protocol" / "command" / "too-large" / "busy" / "closing",
  ? message: tstr,
}

lcn.ctl_daemon_info = {
  version: tstr,
  runtime_instance_id: tstr,
  trust_revision: uint64,
  started_at_ms: uint64,
  socket: tstr,
}
```

The module's own contract (consumer-only, no configuration):

```cddl
; -- metadata --
_module = "logosctl"

; The logosctl module (Tier 4b step 4b-6; DECISIONS G296; D13(a); BOOTSTRAP
; l.384-390): a consumer-only module with no method, no event and no
; configuration. Its instance serves the owner's socket and makes each
; command's Runtime Control call through its own binding (RUNTIME
; l.182-184); logosd hands it the socket path before start. ctl.cddl is the
; socket's protocol.

; A module document declares at least one type: the module's name.
logosctl.name = "logosctl"
```

### Limits

| | |
|---|---|
| Workers | `ctl.workers`, default 4: commands in service at once; one more connection is answered `busy` |
| Idle timeout | `ctl.idle_timeout_ms`, default 30 s |
| Frame | 32 MiB each way |
| Call deadline | the shell's `--timeout` (default 65 s), at most 60 s per call |
| Listen backlog | 64 |

When the instance stops (shutdown, or a stop by the orchestrator), it stops accepting, ends the
connections that are reading, lets a command in a call get the Runtime's answer (its result, or
CANCELLED), unlinks its socket and joins its threads. A `shutdown_runtime` command is answered before
the instance stops, with the Runtime's own outcome: its call is the one call the closing does not cancel,
so the wait for it ends with that outcome or the command's deadline (I97).

## 7a. The `lcn_call` instance and its socket

`logosctl call`, `describe`, `subscribe` and `events` are not logosctl instance commands. They go to `lcn_call`, the CLI module: a consumer-only system instance,
`hosted_dynamic` in a Module Host of its own, that makes the calls through its own binding and routes
and writes the result to the user's terminal itself (DECISIONS G343–G350; Tier 5 plan A3, design (f)).
The shell is its launcher: it hands over its stdout, stderr and each `@FILE`, names the command, and waits
for an exit status. The data path is provider host ⇄ `lcn_call`'s host (the route's session) ⇄ the
terminal; logosd issues the routes and decides each Hello as for any consumer, and no argument, response
or event passes through logosd or the logosctl instance. Argument values pass through the launcher only
because the user typed them there.

```sh
logosctl describe shapes_module
logosctl call shapes_module reflect n=3 label=@label.txt
logosctl call shapes_module reflect --request '{"n": 3, "label": "x"}' --text
logosctl module wait shapes_module --state ready
logosctl subscribe meter_module changed --count 3
logosctl events --for 30s
```

### Composition and lifetime

- **The instance.** `lcn_call` (module `lcn_call`, both names reserved, §3), `hosted_dynamic` with
  placement `process`, no state assignment, `host-ambient` with empty constraints (§5).
- **The artifact.** The library installed with logosd, `<d>/../lib/logos-core/liblcn_call.{so,dylib}`
  (`<d>` as for the Module Host, §3), whose BLAKE3-256 is compiled into logosd at build time: a protected
  bootstrap digest (SEC l.519). `cli.artifact` overrides it; it is protected configuration like every
  other field of this file. A logosd built without the hash and given no `cli.artifact` composes no
  `lcn_call`: `logosctl call` then exits 2, "this logosd has no CLI module (lcn_call)". A missing or
  altered file fails the start with `loader-artifact-unavailable` or `loader-artifact-integrity-failed`,
  which the launcher prints. The start log names the source logosd used.
- **When it runs.** `lcn_call` is not started with logosd. The first `logosctl call`, `describe`,
  `subscribe` or `events` starts it. From then on it is resumed at every start of logosd, like any
  instance with requested intent, until `logosctl module stop lcn_call` cancels that intent; the next CLI
  command starts it again. Stopping it ends no other instance and drops its routes.
- **Idle.** It does not stop itself (an [IMPL] choice, G350: a self-stop would cancel the retained intent,
  R l.1735). What expires is routes: each closes after `cli.route_idle_ms` without a call (R l.3123).
- **After a crash.** The Module Host exits when its carrier to logosd closes, so a killed logosd leaves no
  live `lcn_call` socket. The next start empties `run/` and restores `lcn_call` as `error`
  `host-terminated` (R l.3634) with its requested intent: the orchestrator's first pass resumes it, as it
  does any such instance (G289), and a command that comes first recovers it itself (Activation, below).
- **Configuration.** `lcn_call.settings`, provisioned by logosd at every start from `cli` and the trust
  file (socket, workers, streams, idle timeouts, deployment). The logosctl instance may not stage, apply
  or retire it (S8, §5).

### Activation (BCP l.389)

1. **Mechanism.** A Unix stream socket at `<session>/run/lcn_call.sock` (or in `cli.socket_dir`, owner-only
   as `ctl.socket_dir` is), 0600, bound in the instance's initialization and served only after the
   initialization returned (BCP l.393). When the socket is absent or refuses, the launcher starts
   `lcn_call` through the logosctl instance (§7): it reads the instance's record with `list_modules`, and
   - `unloaded` → `start_module`;
   - `error` with `requested` intent (`host-terminated` after an unclean end included) →
     `recover_module` at the record's execution revision; `error` with any other intent →
     `start_module` (R l.3512; recovery would be refused, R l.3403);
   - `loaded` or `stopping` → wait; `ready` → the socket again;
   - `NOT_READY` (a cleanup not yet resolved, R l.578) or the error arm `stale-revision` (R l.1819) → read
     again; any other error → exit 4;
   - an attempt the launcher's own request began that ended in `error` → exit 4 with its classification.

   It backs off from 20 to 500 ms, acting again whenever the record is `unloaded` or `error` again, until
   `--timeout`, then exits 2 naming the last state it read. It does not depend on when `start_module`
   answers: it waits for the socket.
2. **Admission.** As §7: the peer's uid on accept, another uid closed with nothing written and logged at
   most once a second; the launcher checks the listener's uid before it sends anything, descriptors
   included.
3. **Selection.** The socket reaches exactly one instance, `lcn_call`, fixed by composition. The launcher
   selects nothing: the start and recovery run under the logosctl instance's own authority (S3) and name
   the exact instance (BCP l.391-392).
4. **Presentation handoff.** At initialization, the settings above. Per command, the terminal's
   descriptors and the output format (BCP l.524-526). Nothing that authenticates crosses: no binding,
   ticket or Runtime descriptor. The peer's uid and pid are requester provenance, in `lcn_call`'s log line
   only (BCP l.387).
5. **Failure behaviour.** The exit codes below.

### The wire format `logos-core-nim.cli.v1`

BCP l.395 assigns no encoding; this one is logos-core-nim's, in `src/logos_core/cli/cli.cddl`. Frames are
§7's: a 4-byte big-endian length, one deterministic-CBOR value. A connection carries one command.

```cddl
; logos-core-nim.cli.v1: the protocol between the logosctl launcher and the
; lcn_call instance's socket (Tier 5 step N-2; DECISIONS G344; BOOTSTRAP
; l.384-390). BOOTSTRAP assigns no interoperable activation encoding or
; terminal protocol, so this one is the implementation's own; docs/DAEMON.md
; §7a documents it.
;
; A frame is a 4-byte big-endian length, then one Logos deterministic-CBOR
; value. A connection carries one command: the launcher sends one
; lcn.cli_request, with its descriptors attached to the frame's first byte as
; SCM_RIGHTS ancillary data, in the order its fds list names them; lcn_call
; answers accepted once it has taken the command, then done with the exit
; status, or refused instead of both. lcn_call writes everything the user reads
; to the passed descriptors itself; a reply carries no payload, argument or
; provider text. The launcher cancels by shutting down its write side. (Names
; ending in _request or _response are callable rules, INTERFACE §1.3; the
; request here is lcn.cli_message.)

; Lists are [* ...] (G10: no other occurrence); lcn_call checks the limits the
; comments give.
lcn.cli_message = {
  protocol: "logos-core-nim.cli.v1",
  ? target: lcn.cli_node_name,
  output: lcn.cli_output,
  fds: [* lcn.cli_fd_role],
  ? deadline_ms: uint32,
  command: lcn.cli_command,
}

; The target node's name: "local" is this Runtime (G347); absent, lcn_call's
; default, "local" in N-2. lcn_call checks the name's syntax,
; [a-z][a-z0-9_-]*.
lcn.cli_node_name = tstr .size (1..63)

lcn.cli_output = "json" / "text"

; 2 to 16 descriptors: the first two are always stdout and stderr; each file is
; the content of one @FILE argument (@- passes the launcher's stdin).
lcn.cli_fd_role = "stdout" / "stderr" / "file"

lcn.cli_command =
  lcn.cli_call_command / lcn.cli_describe_command /
  lcn.cli_subscribe_command / lcn.cli_events_command / lcn.cli_rc_command

; A provider: the instance of a module, and the contract to use, an
; implemented interface by its root; absent, the primary contract.
lcn.cli_provider = {
  module: tstr .size (1..64),
  ? instance: tstr .size (1..128),
  ? contract: bstr .size 32,
}

; One call (D26: named arguments only). args (at most 256) and json are
; exclusive; json is one JSON object, the whole request.
lcn.cli_call_command = {
  op: "call",
  provider: lcn.cli_provider,
  method: tstr .size (1..128),
  ? args: [* lcn.cli_arg],
  ? json: tstr .size (1..1048576),
}

; key=value, or key=@FILE: fd indexes the message's fds, a "file" role.
lcn.cli_arg = lcn.cli_text_arg / lcn.cli_file_arg

lcn.cli_text_arg = {
  kind: "text",
  name: tstr .size (1..128),
  value: tstr .size (0..65536),
}

lcn.cli_file_arg = {
  kind: "file",
  name: tstr .size (1..128),
  fd: uint8,
}

lcn.cli_describe_command = {
  op: "describe",
  provider: lcn.cli_provider,
}

; A stream ends at count events, after for_ms, at the launcher's EOF, or when
; lcn_call ends it (G349).
lcn.cli_subscribe_command = {
  op: "subscribe",
  provider: lcn.cli_provider,
  event: tstr .size (1..128),
  ? count: uint32,
  ? for_ms: uint32,
}

; The target Runtime's own Runtime Control events; names (1 to 16) absent:
; the default set, the three the events rule grants (G346).
lcn.cli_events_command = {
  op: "events",
  ? names: [* tstr .size (1..128)],
  ? count: uint32,
  ? for_ms: uint32,
}

; Runtime Control at a named node, through lcn_call's binding for it (RUNTIME
; l.238; G347): reserved for Tier 5 step 5-7a, refused until then. params is
; the method's deterministic-CBOR request.
lcn.cli_rc_command = {
  op: "rc",
  method: tstr .size (1..64),
  params: bstr .size (0..1048576),
}

lcn.cli_reply = {
  protocol: "logos-core-nim.cli.v1",
  outcome: lcn.cli_outcome,
}

lcn.cli_outcome = lcn.cli_accepted / lcn.cli_done / lcn.cli_refused

lcn.cli_accepted = { status: "accepted" }

; The launcher's exit status (G349).
lcn.cli_done = { status: "done", exit: uint8 }

; A frame or a command lcn_call refuses before taking it; the connection is
; closed after it and every descriptor that arrived is closed.
lcn.cli_refused = {
  status: "refused",
  reason: "protocol" / "too-large" / "busy" / "closing",
  ? message: tstr .size (0..512),
}
```


- The launcher sends one `lcn.cli_message`: `protocol`, an optional `target` node (absent: `local`, this
  Runtime), `output` (`json` or `text`), `fds` naming each descriptor's role (`stdout`, `stderr`, then one
  `file` per `@FILE`), an optional `deadline_ms`, and the `command`: `call` (provider, method, `args` or
  `json`), `describe` (provider), `subscribe` and `events` (Streams, below), or `rc` (reserved for
  remote nodes, refused). A provider is a module, an optional instance, and an optional `contract` root
  that selects any of its exact contract views (primary, implemented interface or extended view;
  absent: primary).
- The descriptors travel as `SCM_RIGHTS` on the frame's first byte, at most 16. `lcn_call` makes them
  close-on-exec at once, closes every one it received when it refuses a frame, and closes them all when
  the command ends, before it answers, so a reader of a pipe sees its end.
- `lcn_call` answers `accepted` once it has taken the command, then one `done` with the exit status; or
  `refused` (`protocol`, `too-large`, `busy` or `closing`, with a message) instead of both. A reply
  carries no payload, argument or provider text.
- **Cancel = half-close.** On SIGINT or SIGTERM the launcher shuts down its write side; `lcn_call` cancels
  the call in flight, writes nothing more and answers `done` with 130. A second signal ends the launcher
  at once. A launcher that disappears is the same end of input.

### Arguments and output (G349)

- **Arguments** are named only (D26): `NAME=VALUE` for a scalar field of the request, `NAME=@FILE` (or
  `@-` for stdin) for one read from the passed descriptor, or `--request '{…}'` for the whole request as
  JSON (structured fields, unions, arrays). Values are typed from the method's request rule: integers in
  decimal, `true`/`false`, text as given, byte strings as hex, a text-literal choice as its text. From
  `@FILE`, a text or byte string is the file's bytes as they are (text must be UTF-8), and any other kind
  is the file's text less exactly one trailing newline (`echo 3 > n`); in a union each alternative reads
  the file by its own rule, so `12` and a newline is refused for `uint32 / tstr` as ambiguous. A file is
  read up to 16 MiB, or up to its field's `.size` bound and one byte more, and refused past either. An unknown field, a structured field
  given as `NAME=VALUE`, a value that a union's alternatives read differently, and a float are refused
  (exit 1) with the field's name and the request's fields. The value is checked against the request rule
  before it is sent; the provider's host checks it again.
- **Output** follows §7's rule (JSON when stdout is not a terminal; `--json`, `--text`): the logosctl
  envelope with the response rendered as G89 writes values, or the response in diagnostic notation. Text
  a provider supplied (an error message or detail) is labelled "(declared)" and has control characters
  replaced. Every output carries the `NON-PRODUCTION deployment` line when the switch is on.
- **Marked methods** (a request or response with a marked field; G349's N-2d amendment, INTERFACE §1.4.1)
  are called on the local node only. A marked request takes each field from a file, `NAME=@FILE` or
  `NAME=@-`: a `NAME=VALUE` or `--request` for one is refused before anything is read (exit 1), since a
  value on the command line is in the shell's history and in the process's arguments, which nothing
  erases; do not type a secret there even so. A structured field of a marked request cannot be given
  yet (there is no `--request @FILE`). A marked response is written to stdout only, as any response, and
  never to a failure or the log. The launcher and `lcn_call` erase every copy they make of a marked
  request or response, whatever the outcome: a refusal, a provider's failure, a cancel, a reader that
  closed stdout. Their messages name the field and the request's fields, never a value: a type error
  says the file does not read as the field's type, and a size error states the length. A marked method
  is refused (exit 1) on another node (a remote path has no erasure promise, INTERFACE l.373) and by a
  refc build of `lcn_call` (G277). `@-` on a terminal echoes what is typed, and the newline that ends it
  is part of a text or byte value (use `printf %s`, or a file without one). Text a provider puts in its
  own failure is its own and is shown "(declared)": a provider that quotes a secret there discloses it
  (CONFORMANCE.md).
- **`describe`** lists the provider's contract views (primary, interfaces, extended views) with their
  roots, the roots its module record carries, and the selected contract's methods (request fields and
  response rule) and events.
- **`module wait MODULE [--instance I] [--state S]`** is a logosctl instance command: it polls
  `get_readiness` (100 ms, backing off to 1 s) until the state is `S` (default `ready`; exit 0), the
  instance is in `error` (exit 4, with its failure), or `--timeout` (exit 2, naming the last state).

### Exit codes

| Exit | Meaning |
|---|---|
| 0 | done |
| 1 | refused before anything was called: usage, an unknown node, module, method or event, invalid arguments, a marked value on the command line, a marked method on another node, a refused frame |
| 2 | no daemon, `lcn_call` not reachable or not started before `--timeout`, busy or closing past it, or **the outcome unknown**: a `TRANSPORT_ERROR`, `TIMEOUT` or a `CANCELLED` nobody asked for after the call was sent, or a lost `done`. The provider may have run the call. |
| 4 | a Runtime Control failure: `NOT_AUTHORISED`, `NOT_READY`, an error arm, a continuation fault, with code and message |
| 5 | the provider's error channel answered the call (`METHOD_NOT_FOUND`, `INVALID_PARAMS`, `MODULE_ERROR`): the code and the provider's declared text |
| 6 | a stream `lcn_call` or the Runtime ended: the route, its session or the subscription ended, the terminal did not keep up, or `lcn_call` is stopping (Streams, below) |
| 130 | interrupted |

**One retry.** A call whose `prepare_call` failed (nothing was submitted), or that completed `NOT_READY`
or `NOT_AUTHORISED` (refused before the provider ran it), is retried once on a new route, within what
remains of the deadline. A `TRANSPORT_ERROR`, `TIMEOUT` or `CANCELLED` after submission is never retried:
the call may have run. A route whose handle has ended is never used again.

### Grants

The system rules give `lcn_call` the Runtime Control methods it needs and the three events `events`
follows (S6, the events rule, §5); they give it no provider access. To call a provider, an operator rule
allows `discover` on **every exact contract view** of that provider (`describe_provider` answers all of
them or nothing; R l.413-416, l.428, l.90-91), and `establish-route`, `renew-route` and `call` (or
`subscribe-event`) on the contract called (R l.1642):

```cbor-diag
{
  "kind": "allow",
  "subject": {"instances": ["lcn_call"]},
  "scopes": [
    {
      "kind": "provider-access",
      "contract": {
        "commitment_model": "logos.commitment-model.2026-10",
        "schema_root": h'<the root logosctl describe prints>',
        "hash_profile": "logos.hash-profile.2026-08.choice-index",
        "hash_suite": "logos.hash-suite.blake3-256"
      },
      "actions": ["discover", "establish-route", "renew-route", "call"]
    }
  ]
}
```

with one more `discover` scope for each other contract view of the provider; `logosctl describe`
prints the roots. Where the Runtime answers `NOT_AUTHORISED`, the launcher prints that code and the
Runtime's message; it guesses no reason. Every process of logosd's user can use `lcn_call` with all of
these grants, as with the logosctl instance (§7): grant it what the session's user may call.

**Example: a payload module** (`blockchain_module`; [DEPLOYMENT.md](DEPLOYMENT.md) §26; DECISIONS
G424, G469, G476). It calls no other module, and `report_failure` needs no grant. Its module record
names contract v2's root as `primary_contract` and v1's under `extends` (G393); without v1's the start
ends `initialization-failed`. Three rules are all it needs. The first two are the rule above for
`lcn_call`, with `subscribe-event` added, once on v2's root and once on v1's: the Runtime describes a
provider only if each of its contracts may be discovered, so without v1's rule every call is
`NOT_AUTHORISED`. With them `logosctl call`, `describe` and `subscribe` reach it. A rule that narrows
`access.methods` names the methods of the module's policy classes the session's user may call (the
module's `policy-classes.json`); its `spend` and `keys` classes are for local subjects only. The third
allows the `blockchain_module` instance its own `publish-event` on v2's root; without it every
`chain_progress_event`, `new_block_event` and `lib_event` is skipped (Streams). Its permission
settings must hold the profile's minimum, `logos-core-nim.host-ambient` with the empty constraints. With
no `permissions.initial` entry for the module, logosd writes that entry itself ("Permission settings"
above; G294), so the entry is optional. An entry that is present but lacks host-ambient refuses the start
`NOT_AUTHORISED` (`authority-denied`; DECISIONS G110; [PERMISSIONS.md](PERMISSIONS.md), "Admission and
the snapshot").

### Streams (G349)

- **`subscribe MODULE EVENT [--count N] [--for DURATION] [--instance I] [--contract ROOT]`**: one event
  the provider declares, named by its identifier (`meter.changed_event`), without its namespace
  (`changed_event`), or without the `_event` suffix too (`changed`); an unknown or ambiguous name is
  refused (1) with the provider's events. `lcn_call` establishes a route whose access names that event
  only (`subscribe_events: [root]`), so the grant needs `establish-route` and `subscribe-event` on the
  contract (Grants), then subscribes on it. A refused subscription writes nothing but the failure (4).
  Each delivery also needs the provider's own `publish-event` on that contract (CA l.244-247), an
  operator rule naming the provider's instance, as S1 does for the Capability Authority. Without it
  every publication is skipped: the stream stays open and sees nothing.
- **`events [NAME]... [--count N] [--for DURATION]`**: this Runtime's Runtime Control events, on
  `lcn_call`'s own binding. NAME as above (`module_state_changed`,
  `logos.runtime_control.module_state_changed_event`), at most 16; none names the events rule's three
  (§5). Another Runtime Control event is `NOT_AUTHORISED` (4): S7 denies it, and a deny wins over any
  operator rule.
- **Output.** One line per event, written as it arrives: JSON `{"event": ID, "data": VALUE}`, VALUE as
  G89 renders a response, or with `--text` `ID VALUE` in diagnostic notation. A stream that fails after
  its events adds the failure: one envelope line on stdout in JSON, `logosctl: CODE: message` on stderr
  in text.
- **Its end.** `--count` events written, or `--for` elapsed (milliseconds, or a number with `ms`, `s`, `m`
  or `h`; 1 ms to 49 days): 0. The launcher's EOF, at SIGINT or SIGTERM: 130. Exit 6, after the events it
  had, when `lcn_call` or the Runtime ends it:
  - "the route ended: the provider is not ready" (`NOT_READY`): the provider stopped, or `lcn_call`
    is stopping and the Runtime ended its routes before `lcn_call` ended the stream itself;
  - "the route's session ended; run the command again" (`NOT_AUTHORISED`): below;
  - "the subscription ended: authority to receive the event ended" (`NOT_AUTHORISED`): the authority
    no longer allows a delivery, such as after a revoked grant (T l.753; IF l.1472-1485);
  - "the terminal did not keep up; the stream ended": below;
  - "lcn_call is stopping; the stream ended": `module stop lcn_call`, or logosd's stop, for an `events`
    stream, or a `subscribe` stream whose route had not ended yet.
- **One route session.** A subscription stays on the route it was made on and ends with that route's
  session: the decision's validity, one hour by default ([AUTHORITY-POLICY.md](AUTHORITY-POLICY.md)). A
  renewal does not extend a session (R l.3337-3338).
- **A terminal that does not keep up.** `lcn_call` copies each event into a queue of 1024 events or 16
  MiB; when it is full, the stream ends (6) rather than lose events silently. The message goes to stderr
  whatever the output (in JSON, its envelope), since stdout waits for the same reader; `lcn_call` waits
  at most a second for room there.

### Limits

| | |
|---|---|
| Workers | `cli.workers` (1–32, default 8): one-shot commands in service at once; one more is refused `busy` and retried until `--timeout` |
| Streams | `cli.streams` (1–64, default 8): subscriptions and event streams at once |
| Stream queue | 1024 events or 16 MiB per stream; `events` names at most 16 |
| Idle timeout | `cli.idle_timeout_ms` (100–600000, default 30 s): a connection without a complete request |
| Route idle | `cli.route_idle_ms` (1000–86400000, default 10 min) |
| Request frame | 1 MiB of argument text and 128 KiB for the rest; larger values as `@FILE` |
| Descriptors | 16: stdout, stderr and 14 `@FILE` |
| Call deadline | the shell's `--timeout` (default 65 s), what remains of it after activation |
| Hops | 4 continuations on one call (remote nodes, Tier 5 step 5-7a) |
| Listen backlog | 64 |

## 8. Administration

There is no approval path and no client command that changes authority. The policy, its grants and the
trust input change only through the owner-only files, offline: `logosctl init`, `logosctl daemon config
set`, `logosctl trust …`, or the owner's own edits, each applying at the next start (BCP l.385-387).

- **Authentication** of that path is the operating system's: the files are the session owner's, mode
  0600 in 0700 directories, and logosd refuses a session others can access.
- **What it authorizes**: everything logosd does. Whoever can write the session can change the policy,
  the trust file with its anchors and switch, and the evidence key.
- An `issue` rule in the policy is protected input too. Under it a module may issue grants while the
  daemon runs (CA l.744), within what the rule allows; that is the only change of authority at run time.
- **State transfers** are the same kind of input (decision 9): an entry in `state_transfers`, set with
  `daemon config set` while logosd is stopped, authorizes one replacement instance to take another's
  state at the next start (§11). No socket command and no Runtime Control method moves state.
- **Grants to `lcn_call`** for operator providers are ordinary policy rules in the same file (§7a,
  "Grants"); the system rules give it none.
- **State disposal** is offline too: `logosctl state purge`, with logosd stopped, removes a retired
  instance's preserved state directory, the separately authorized deletion of BCP l.400;
  `logosctl state list` shows what is kept and where it came from (§11). No socket command and no
  Runtime Control method deletes module state.

## 9. Call evidence

The Runtime's invocation boundary keeps a `call` record for each call whose applied decision retains a
commitment (CA l.1215-1243), in a ring of `call_audit.call_records` records, lost at exit (I85).
logosd can also keep them on disk, so the owner can later export one as call evidence (G301; G115,
G143, G149).

### The store

- **Off by default** (G115). Without `call_audit.store` nothing is persisted. `logosctl init` makes the
  evidence key anyway (G149), so turning the store on is one change: `call_audit.evidence` (the kid and
  key file `trust evidence-keys ls` shows) and `call_audit.store` (`{}` for the defaults), then a
  `daemon config set` and a restart. The store needs the key (§3, check 4).
- **Where.** `state/evidence/` (0700), segments `seg-<first seq, 20 digits>.lcr` (0600). logosd logs
  `call-evidence store: boot N, next seq S in DIR` when it opens it.
- **How a record gets there.** logosd sets the store as the Runtime's call record sink (G304). Each
  record the ring takes is offered at once, on the thread that made it: copied into memory and queued
  under a short lock, never waiting for the disk. A record's seq is the store's base (the seq after the
  last one stored when it opened) plus the ring's index, so records from concurrent calls keep unique,
  ordered seqs. One writer thread writes up to 256 entries at a time in seq order and flushes the segment
  to the medium after each batch.
- **Drops.** At most `queue` records wait (default 4096). A record past that window is dropped; the
  writer writes a gap entry for each run of dropped seqs and logs the drops once per batch. Drops are
  recorded, never silent.
- **Format** (`evstore.cddl`). Each entry is a 4-byte big-endian length, then one deterministic-CBOR
  `lcn.ev_entry`. A segment's first entry is its header: the producer (the Runtime id), the kid
  configured when the store opened, and the open's number (`boot`, from 1). Each open starts a segment;
  a segment is rotated at 10,000 entries or 16 MiB.

```cddl
; logos-core-nim.evidence-store.v1: logosd's call-evidence store (Tier 4b step
; 4b-6; DECISIONS G301). <session>/state/evidence/ holds segments named
; seg-<the first seq, 20 digits>.lcr. A segment is a sequence of entries, each
; a 4-byte big-endian length, then one Logos deterministic-CBOR lcn.ev_entry.
; Its first entry is its header; then records and gaps, in seq order.
; docs/DAEMON.md §9.
lcn.ev_entry = lcn.ev_header / lcn.ev_record / lcn.ev_gap

; Who wrote the segment: the Runtime whose invocation boundary made its
; records, the kid of the evidence key configured when the store opened, and
; that open's number, counted from 1.
lcn.ev_header = {
  format: "logos-core-nim.evidence-store.v1",
  producer: tstr .size (1..128),
  kid: bstr .size 16,
  boot: uint64,
}

; One call record as the Runtime retained it (a CAPABILITY AUTHORITY
; audit_record in deterministic CBOR), and when the store was handed it.
lcn.ev_record = {
  seq: uint64,
  at_ms: uint64,
  record: bstr .size (1..1048576),
}

; Records the store dropped because its queue was full: count seqs from first.
lcn.ev_gap = {
  gap: { first: uint64, count: uint64 },
}
```

- **Bounds** (G143; CA l.1202). Whole segments, oldest first, are reaped when the store opens and at each
  rotation, while the store spans more than `max_records` seqs (default 1,000,000; dropped seqs count,
  as if stored) or while the oldest segment was last written more than `max_age_days` ago (default 30;
  the file's modification time, so a restore that resets it keeps a segment longer). The segment being
  written is never reaped.
- **Crash.** Segments are only appended to. At open, a torn or undecodable tail of the newest segment is
  cut off and logged. A failed write closes the segment and the next batch starts another, so damage
  stays at a segment's end; readers stop there.

### Export

```sh
logosctl audit evidence ls
logosctl audit evidence export --seq N --out FILE      # or: … --seq N > FILE
```

- **Selection.** `ls` lists the segments: first and end seq, records, dropped seqs, producer, kid and
  boot. `export` takes one seq.
- **Authorization.** Both are offline and read-only, and work while logosd runs. The owner's command on
  the owner-only session files is the protected integration's authorization to disclose the complete
  record (CA l.1365, as I85 reads it; CAP-0416). There is no export through the socket and no client
  command.
- **What is exported.** A `logos.call-evidence.cose-sign1-slh-dsa-sha2-192s` container for the record as
  stored, complete and with no proofs (CA l.1366; as I85). It is signed with the current evidence key,
  the one daemon-config names, checked against its binding (§3, check 4), for the Runtime that binding
  names: a kid maps to one producer (CA l.1309, l.1334). Signing in the shell uses the Runtime's own key
  on the Runtime's behalf. A segment whose header names another Runtime is refused: "seg-… was written by
  Runtime X; the current evidence key belongs to Runtime Y". The container authorizes nothing (CAP-0256).
- **Not retained.** A seq that was reaped, dropped, cut off or never stored is refused: "seq N is not
  retained", exit 1 (CAP-0417).
- **Delivery.** `--out FILE` creates the file with `O_EXCL` and mode 0600; an existing file is refused.
  Without `--out` the container goes to stdout when stdout is not a terminal, and is never written to a
  terminal.
- **The key.** A rotated key (`trust evidence-keys rotate`) applies at the next start. Its binding stays,
  marked retired, with only the public half (CA l.1317). An export always signs with the current key, so a
  record stored under an older kid is re-signed; a verifier needs the current key's binding.

### Limits

These are what the store does and does not protect (CA l.1364; CAP-0415):
- **What a record holds**: the consumer's address, the decision id, one call scope, a timestamp, and for
  each retained side its schema subtree root and value root. No payload, proof or constraint value.
- **No marked side.** A call whose decision would retain a marked side's root is refused before dispatch
  (IF l.377, IFC-0581, G278), so no record holds one.
- **Guessable data.** A retained root of guessable data discloses it to whoever can read the store (SEC
  l.403).
- **Who can read it.** Other operating-system users are kept out by the modes; processes of the same user,
  backups and the disk are not. The store is plaintext at rest.
- **Integrity.** None beyond the file modes: whoever can write the session can change a record before it
  is exported, and the export signs what the store holds.
- **Load.** Under load records are dropped, as recorded gaps.
- **Rotation** re-signs with the current key (above).
- **Hosted providers.** A hosted provider's call roots are the ones its Module Host reports (G274);
  CONFORMANCE states the trust that rests on.

## 10. Remote surfaces

Without `remote.enabled` nothing is reachable from another host (SEC l.525; R l.2769). With it, each
enabled listener record (`remote.listeners`, or one Runtime Control enabled) is one `logos_remote`
process (DECISIONS G411; [REMOTE.md](REMOTE.md)): logosd binds the address, takes the restart lock
`work/remote/listener-<hash>.lock` and spawns the program (`runtime.remote_program`) with the socket;
the record is enabled once the process listens. The process authenticates each peer against this
start's trust snapshot, with logosd's certificate and signer (§6b), and relays what Runtime Control
needs to logosd: no module payload crosses logosd. It ends with logosd however logosd ends (a SIGKILL
included), and a lock another process holds refuses the start, naming the pid written in it.

- **Runtime Control to another Runtime** (G413): a listener with `runtime_control_enabled` serves the
  `logos_runtime_control` endpoint to enrolled Runtimes' consumers. Each call is judged by the
  capability-authority policy for that forwarded consumer, which only a subject naming its Runtime
  matches ([AUTHORITY-POLICY.md](AUTHORITY-POLICY.md), subjects; G415); `policy: allow-all` with
  `remote.enabled` refuses the start.
- **Records:** the four methods hold real records (G412): a disabled record for any valid address,
  enabling a `quic` one or any one without `runtime.remote_program` MODULE_ERROR, a bind failure
  TRANSPORT_ERROR. The disables they make last (§6c). `logosctl` calls none of them.
- **Not yet:** provider sessions to another Runtime (remote routes, step 5-7a-3), and this Runtime as
  a source (step 5-7a-4).

## 11. State protection

- **At rest**, the session is protected by file modes only: 0700 directories, 0600 files. There is no
  secret store and no encryption. Backups see everything, the evidence key's secret half included.
- **Same-uid processes** can read everything, and write the policy, the trust file with its switch, and
  the evidence key (§8).
- **Restore and rollback.** A restored older `trust.cbor` is refused by continuity (§6); a restored
  `state/` without its mark needs `trust reestablish`. A restored `state/` keeps the Runtime id, which is
  in `daemon-config.cbor`. A lost `state/` is not recreated: logosd refuses to start without the store
  (§2), and the owner makes a new session with `logosctl init`.
- **Retirement** (`module retire`) keeps the instance's state directory: "retired; its state directory
  is kept". Only `logosctl state purge`, below, removes it.
- **Replacing an instance** (an upgrade under a new instance id; DECISIONS G92 as re-decided
  2026-11-15, I96). An operator instance's state stays with its state assignment, and a new instance
  starts empty. To carry `a`'s state over to a new instance `b`:
  1. While logosd runs, read `a`'s configuration (`logosctl config get a`) if `b` should keep it, and
     turn it into `b`'s `provisioned_configuration` outside Core: the transfer discards `a`'s
     ([HOST-CONFIG.md](HOST-CONFIG.md), "Keeping a configuration across an upgrade"). Then stop
     logosd, and back up `state/` (`state/store` and `state/modules` together). `move` takes no
     snapshot: the backup is the rollback.
  2. With `daemon config get`, edit the configuration: add `b` to `modules` with its own
     `state_assignment`; remove `a` from `modules`, from `orchestration.start` and from anything
     else naming it; add `{from: "a", to: "b", mode: "move"}` to `state_transfers`; name `b` where
     `a` was. Set it with `daemon config set`.
  3. Start logosd. Before anything starts, the Runtime retires `a`, creates `b` and renames `a`'s
     directory under `state/modules` to `b`'s; afterwards `logosctl module ls` lists `b` and not `a`.
     The orchestrator then starts `b` like any operator instance, under the policy's rules for `b`: a
     grant or rule naming `a` does not cover it. The transfer's record is `b`'s transfer record in
     `state/store`, kept even after `b` is retired: with logosd stopped, `logosctl state list` shows
     `b`'s assignment "from a (a-state), move" and `a`'s "to b, move".

  `mode: "copy"` instead leaves `a`'s directory as it was (not on Windows): the copy is the
  rollback, and a later `{from: "a", to: "c", mode: "copy"}` gives a new `c` `a`'s state again.
  **A `copy` reads `a`'s state in logosd's process**: the Runtime thread reads and writes every
  byte through one 64 KiB buffer, zeroed before it is freed, and keeps, logs and records nothing
  of it ([HOST-CONFIG.md](HOST-CONFIG.md), "State transfer to a replacement instance"). It is
  the one place module state passes through logosd.

  An applied entry changes nothing at later starts; remove it when convenient. A refused transfer
  fails the start with nothing changed, and the log names the reason ([HOST-CONFIG.md](HOST-CONFIG.md),
  "State transfer to a replacement instance"). `a` must have stopped cleanly or the daemon's last run
  must have ended: a hosted `a` whose Module Host of an earlier run still holds its restart lock is
  refused until that process is gone; find it with `lsof <file>` or `fuser <file>` on the file the
  message names, end it, and start again. A `move` reads nothing: the files are renamed in place.
- **Listing and purging state** (DECISIONS G143 as re-decided 2026-11-15, I96). Offline, with logosd
  stopped; each takes the session's lock, then the store's, and neither writes the Runtime's store.
  - `logosctl state list`: one line per state assignment the store names and per directory in
    `state/modules`: its holder (`live <id>`, `retired <id>`, `none`, or `unfinished` for a
    `+transfer-…` or `+purge-…` name the next start removes), its size, and its transfer history
    ("from a (a-state), move" on the replacement, "to b, move" on the source).
  - `logosctl state purge INSTANCE` removes a retired instance's preserved state directory, for
    good (the separately authorized disposal of RUNTIME l.3452-3453; BCP l.399-400). The
    tombstone keeps the assignment reserved: it is never reused. `--assignment A` removes a
    directory no instance and no tombstone names. It asks first; `--yes` confirms (needed when
    stdin is not a terminal). Refused: a live instance ("retire it first"), an assignment the
    configuration names, a symbolic link (the target is yours to remove), and, with
    `LOGOS_ERR_NOT_READY`, an assignment a state transfer still owes to its replacement (start
    logosd once to complete it). The directory is renamed to `+purge-<random>` first, so an
    interrupted purge leaves only a name the next start removes. No link inside is followed.

## 12. Diagnostics

logosd logs to stderr, one line per event: `logosd[<pid>]: <level>: <text>`, levels `error`, `warn` and
`info` (`--log-level`, default `info`). A service manager collects it. The start log has the ready line
(§4), the `NON-PRODUCTION` warning when the switch is on, the call-evidence store's line when it is on
(§9), the orchestrator's lines, the Runtime's diagnostics (below), and one line per socket command
(`logosctl: <method> from uid U pid P: <code>`). The `lcn_call` instance's Module Host writes to the same
stream: `lcn_call: serving <socket>` when it starts, and one line per CLI command
(`lcn_call: <command> node <name> from uid U pid P: exit N [code]`), never an argument or a result. The store warns when it drops records or cuts off a torn
tail.

**The logging rule** (IF l.375, SEC l.305-306, l.404, G278): no log line holds a payload, a value root, a
ticket, a key, record content, or the failure text of a method with a marked field. Method names, schema
roots, codes and instance ids are metadata and may appear. **Every line is one line:** logosd replaces each
control character (a line break, an escape, a C1 control) with a space before it writes, so no text in a
line, whoever wrote it, ends it, starts another or moves a terminal's cursor.

### The Runtime's diagnostics

The Runtime keeps a diagnostic for what it reports to no caller: a publication it could not deliver
(RUNTIME l.1149), a call record it could not keep (RUNTIME l.1672), state it could not persist, a state
transfer (§11), a module's or the Module Loader's reported failure, and the like. logosd logs each as
`runtime: <text>`, at `warn` for a call record not kept and for state not persisted, at `info` otherwise.
This is the logging integration BCP l.557-559 describes, and it states what that asks:

- **Attribution.** Text the Runtime did not write is quoted, cut to 256 bytes (`...` marks a cut) and
  followed by `(text from <who>)`: the instance whose reported failure it is, `logos_module_loader` for
  the Loader's, or `the transport serving <provider>` for a publication or link failure a Module Host
  reported. It is that supplier's word and no evidence of another module's identity (BCP l.558).
  Everything else in a `runtime:` line is the Runtime's.
- **Who can read it.** The log is logosd's stderr, which only the service manager receives: the owner's
  user journal under systemd (`journalctl --user -u logosd`), `~/Library/Logs/logosd.log` under launchd
  (§13). The session owner and whoever the host lets read that journal or file can read it; logosd serves
  it to no one, and `logosctl` has no command for it.
- **Sensitive data.** The logging rule above. No diagnostic carries a payload, a value root, a ticket, a
  key, record content or a marked method's failure text; a validation failure's message names no marked
  path (G278).
- **Retention.** The Runtime holds the latest 4096 in memory only. Those not yet logged are lost when the
  process ends; nothing in the session keeps them.
- **Delivery bounds.** logosd reads them once at start, after bootstrap, so a state transfer's line is in
  the start log; every second while it runs; and once after the Runtime's shutdown, before it exits 0, 3
  or 4 (§15). A failed start logs them before it exits 2. When more than 4096 arrive between two reads,
  the oldest are lost and the next read logs one warning, `runtime: N diagnostics dropped`. If the
  periodic read cannot start, logosd logs an error and runs on with the start and final reads. Required
  audit does not depend on this log (BCP l.559): call records and the evidence store (§9) are kept as
  before.

Hosted modules' stdout and stderr are inherited and pass through unfiltered: a module that logs its own
data puts it in logosd's log.

| Exit | logosd |
|---|---|
| 0 | stopped cleanly |
| 1 | refused: arguments, session, lock, a missing Runtime store, daemon-config, trust file, socket path, the call-evidence store |
| 2 | the Runtime could not be created or started |
| 3 | shutdown ended with an error |
| 4 | the Module Loader failed (§15) |

| Exit | logosctl |
|---|---|
| 0 | done |
| 1 | usage, a refused value or frame, an offline check or export (§9) |
| 2 | no daemon, busy, or the outcome unknown |
| 4 | the Runtime Control call failed (code and message on stderr) |

`--json` prints one envelope per command: `deployment`, `command`, `status` (`ok` or `error`), and
`result`, or `code` and `message`. Bytes are hex; integers beyond 2^53 are strings.

## 13. Signals and service managers

| Signal | logosd |
|---|---|
| SIGTERM, SIGINT | the first requests shutdown; a second logs "shutdown in progress" |
| SIGHUP | logged: "configuration changes apply at the next start" |
| SIGPIPE | ignored |
| SIGUSR1, SIGUSR2 | internal (the Loader-loss notice; stopping the signal thread) |

Shutdown requests the Runtime's shutdown, waits for it, then destroys the Runtime, retrying while module
code still runs for at most `shutdown_grace_ms` plus 5 s; then it removes the socket and releases the
lock.

`contrib/` has a systemd user unit (`contrib/systemd/logosd.service`) and a launchd agent
(`contrib/launchd/org.logos-core.logosd.plist`). Both run one logosd per user session, never as root, and
restart it after a failure exit, exit 4 included; the systemd unit does not restart after exit 1, which a
restart would repeat. Their stop timeouts (90 s) are above the shutdown logosd waits for with the default
deadlines.

## 14. Profiles and waits

**Profiles** (BCP l.366). The local transport profile is `logos.local.unix-stream`, with endpoints under
`run/ep/`. No remote profile is enabled. The permission profile is `logos-core-nim.permission-profile.v1`.
A selected profile that cannot be used fails the start or the realization that needs it; nothing falls
back.

**Waits** (BCP l.376):

| Wait | Value |
|---|---|
| The Module Loader's startup | 120 s, fixed |
| An instance's start, stop, the shutdown grace, a configuration apply | `runtime.startup_deadline_ms`, `stop_deadline_ms`, `shutdown_grace_ms`, `apply_deadline_ms` ([HOST-CONFIG.md](HOST-CONFIG.md)) |
| Destroy retries | `shutdown_grace_ms` plus 5 s |
| Module Hosts gone after a Loader loss | 10 s |
| A socket connection without a complete message | `ctl.idle_timeout_ms` |
| One Runtime Control call through the socket | at most 60 s |
| A service manager's stop | `TimeoutStopSec`, `ExitTimeOut`: 90 s |

## 15. Loader loss

If the Module Loader fails, the Runtime cannot realize anything again, and the process that hosts it
must end (R l.3685-3688). logosd:

1. receives the Runtime's termination notice (it names the instances left unresolved) and logs
   "the Module Loader failed; termination required for …". The notice comes through the Host API's
   termination hook on whichever thread the Runtime ran it, which signals the process
   (`kill(getpid(), SIGUSR1)`), so logosd's signal thread takes it;
2. requests shutdown; the wait returns with the loss;
3. does not destroy the Runtime. It writes out the call-evidence store (§9), waits up to 10 s for every
   Module Host to be gone (their restart locks under `work/hosts/`), logs "exiting with 4", and exits 4.
   It keeps the session lock to the end: the kernel drops it with the process, so no offline writer or
   second logosd holds the session while the orphaned in-process code still runs (R l.3688, l.2568).

The Runtime sends the notice only when the failed Loader leaves in-process realizations. Under logosd
that is always so: `orchestrator`, `logosctl` and, under capability-authority, `authority` are
`direct_static`.

A service manager restarts it (§13); the new process composes a new Runtime from the same session.
Run without one, logosd stays stopped after exit 4 until someone starts it.
