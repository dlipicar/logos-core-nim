# logosd and logosctl

`logosd` hosts one Logos Runtime as a long-running process for one user; `logosctl` is its shell.
This page is the daemon's chapter of the deployment documentation (BOOTSTRAP-COMPOSITION-PROFILES,
BCP), and the documentation BCP l.359 asks for of `logos-core-nim.daemon-config.v1`, logosd's
deployment input. The host configuration logosd derives from it is documented in
[HOST-CONFIG.md](HOST-CONFIG.md); the authority policy in [AUTHORITY-POLICY.md](AUTHORITY-POLICY.md).
Decisions: DECISIONS I95, G293–G304.

| | |
|---|---|
| Programs | `logosd`, `logosctl` (POSIX hosts; on Windows each says "not supported on this platform" and exits 2) |
| Packages | `nix build .#logosd .#logosctl`; `nimble install` (POSIX) |
| Session | `--session-dir DIR`, else `$LOGOSCTL_SESSION_DIR`, else `$HOME/.logos-core` |
| Socket | `<session>/run/logosctl.sock` (or in `ctl.socket_dir`), owner-only |
| Wire format | `logos-core-nim.ctl.v1` (§7) |

```sh
logosctl init                 # the session: daemon-config, trust file, evidence key
logosd &                      # or under a service manager (§13)
logosctl status
logosctl module create my_module
logosctl daemon stop --wait
```

## 1. What logosd is

logosd is the host of one Runtime (RUNTIME §13: it calls the Host Embedding API like any embedding
host). It is not a participant: it has no module identity of its own and makes no call as one
(BCP l.100-104). What runs in its process:

- the Module Loader, `logos_module_loader`, established by the Runtime itself;
- the orchestration instance `orchestrator` (the reference module, `lcn_orchestrator`);
- under `capability-authority`, the Capability Authority instance `authority`;
- the `logosctl` instance, which serves the socket (§7);
- every operator module the configuration realizes as `direct_dynamic`.

A `hosted_dynamic` module (placement `process`) runs in its own `logos-module-host` process, which logosd
starts through the Runtime, under logosd's user ([HOST-CONFIG.md](HOST-CONFIG.md), "Module Hosts").

**`direct_dynamic` means this module's payloads are in the daemon's process** (R l.1609-1611): its
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
  trust.cbor               0600  lcn.trust_file (§6; absent: the compiled-in floor)
  keys/                    0700  evidence keys and their bindings (§9)
  state/                   0700  trust-mark.cbor, store/, modules/, evidence/
  work/                    0700  runtime.work_dir; never emptied (restart locks)
  run/                     0700  recreated at each start: logosctl.sock, ep/
```

- Every directory is owner-only. A session directory that group or other can access is refused, as is a
  path component that is a link where a directory is expected.
- `lock` is an advisory lock (`flock`). logosd holds it for its whole life. Every offline `logosctl`
  command that writes (`init`, `daemon config set`, `trust development`, `trust reestablish`,
  `trust evidence-keys rotate`) takes it, and is refused while logosd runs: "another logosd or an
  offline logosctl command holds this session" (exit 1). Offline reads take no lock.
- `run/` is emptied and recreated at each start while logosd holds the lock, so a socket left by a killed
  daemon never blocks a new one. The Runtime's transport endpoints are under `run/ep/`.
- `work/` is the Runtime's `work_dir`. It keeps the Module Hosts' restart locks (`work/hosts/`), so it is
  never emptied.
- `state/` holds the Runtime's persistent state (`state/store`, `state/modules`), the trust mark and the
  call-evidence store (`state/evidence/`, §9).
- **The store is made by `init`, never by logosd.** `logosctl init` writes `state/store/runtime-state.cbor`
  holding the session's Runtime id and no instance. A start that finds no such file is refused (exit 1):
  "the Runtime state store is missing …; restore state/ from a backup, or make a new session with
  logosctl init". The Runtime id is fixed for the session, and the system instance ids are fixed
  strings, so a new store under the old id would give the old instances' addresses to unrelated ones
  (RUNTIME l.2630-2632). A lost `state/` therefore needs a new session; a restored backup of it starts.

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
  ? permissions: lcn.dc_permissions,
  ? state_transfers: [* lcn.app_state_transfer],
  ? ctl: lcn.dc_ctl,
  ? test_hooks: lcn.dc_test_hooks,
}

; runtime_instance_id: assigned by logosctl init (RUNTIME l.2665) and fixed for
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

; Accepted only by a logosd built with lcnTestHooks, with the development
; switch on (G300); a packaged logosd refuses the field.
lcn.dc_test_hooks = {
  ? ctl_command_delay_ms: uint32,
  ? loader_failure_after_ms: uint32,
}
```

The rules named `lcn.app_*` and `lcn.ap_*` are the host configuration's and the authority policy's, with
the meaning those pages give them.

### Fields

| Field | Meaning |
|---|---|
| `runtime.runtime_instance_id` | The Runtime's id (RUNTIME l.2665). `init` assigns a random UUIDv4; it is fixed for the session's life, and `daemon config set` refuses a value that changes it. |
| `runtime.*_deadline_ms`, `shutdown_grace_ms`, `max_payload_depth` | As in the host configuration (§14). |
| `runtime.module_host` | The `logos-module-host` program. Default: `<d>/../libexec/logos-core/logos-module-host` if it exists, else `<d>/logos-module-host`, where `<d>` is the directory of logosd's executable with links resolved. |
| `runtime.module_host_env` | As in the host configuration. |
| `policy` | `allow-all`, which needs the development switch (§6), or `capability-authority`: `source`, the operator's `rules`, and the policy options; logosd adds the system rules (§5). `recovery` absent is off; `init` writes `true` (RUNTIME l.1676). |
| `modules` | Operator instances: `lcn.app_module` with `direct_dynamic` or `hosted_dynamic`. logosd registers no operator binding, so `direct_static` is refused. |
| `declarations` | Modules `module create` may instantiate (RUNTIME l.3614-3621), with the same strategies. |
| `ordering` | Start-order pairs between operator instances. |
| `orchestration` | `start`: the operator instances the orchestrator starts, in order; `restart`, `overrides`, `resync_ms`: its restart policy ([HOST-CONFIG.md](HOST-CONFIG.md), "The reference orchestration module"). An override may name `logosctl` or `authority`. |
| `call_audit` | `call_records` and `evidence` as in the host configuration; `store` (§9) needs `evidence`. |
| `routing`, `transport` | As in the host configuration. |
| `permissions` | `profile`: absent selects the reference profile `logos-core-nim.permission-profile.v1`, since logosd always selects one; `initial`: the operator instances' settings. An entry naming a system instance or module is refused: logosd provisions those itself (§5). |
| `state_transfers` | As in the host configuration: an operator instance's replacement continues from its state, applied once at the next start (§11, "Replacing an instance"). Neither side may be a system instance. |
| `ctl` | The socket (§7): `socket_dir` (absolute; default `<session>/run`), `workers` (1–32, default 4), `idle_timeout_ms` (100–600000, default 30000). |
| `test_hooks` | Refused by a packaged logosd (§6). |

### The checks

logosd and `logosctl daemon config check|set` run the same checks, in order; the first failure is
reported with the field it concerns, and logosd exits 1.

1. The bytes decode as one deterministic-CBOR `lcn.daemon_config`.
2. Names and strategies: no operator instance uses a reserved id (`orchestrator`, `authority`,
   `logosctl`, `logos_module_loader`) and no operator module a reserved name (`logos_module_loader`,
   `logos_capability_authority`, `logosctl`, `lcn_orchestrator`); no `direct_static`; `ordering` and
   `orchestration.start` name operator instances, each once; `permissions.initial` names no system one;
   `state_transfers` names no system instance on either side, and no `orchestration.start` entry is
   the source of a transfer (the transfer retires it).
3. The development switch: `allow-all` and `test_hooks` need it (§6).
4. `ctl`'s bounds; `call_audit.store` needs `call_audit.evidence`; the evidence key's file, its `kid`
   and its binding name this Runtime (§9).
5. The derived host configuration passes the library's own checks (`logos_runtime_create`'s), and the
   orchestrator's value passes the module's.

### The derived host configuration

logosd hands one `logos-core-nim.app-config.v1` value to `logos_runtime_create`. It supplies the bootstrap
inputs through it: `work_dir`, `state_root`, `store_dir` and `endpoint_dir` from the session layout, the
Runtime id, the instances of §4, the merged policy of §5, and the permission settings of §5. `routing`,
`transport`, `state_transfers` and `call_audit.call_records`/`evidence` pass through unchanged.

## 4. Composition and bootstrap

| Instance | Module | Implementation | State assignment |
|---|---|---|---|
| `logos_module_loader` | `logos_module_loader` | the Runtime's own | none |
| `orchestrator` | `lcn_orchestrator` | `direct_static` binding `lcn_orchestrator` | `orchestrator` |
| `authority` | `logos_capability_authority` | the library's static binding (capability-authority only) | `authority` |
| `logosctl` | `logosctl` | `direct_static` binding `logosctl` | none |
| operator | daemon-config `modules` | `direct_dynamic` or `hosted_dynamic` | as configured |

- The Module Loader is established first, by the Runtime, before anything else is realized; every other
  instance is realized through it, the system ones included (BCP l.287-291). logosd registers two native
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
default configuration they are, one per line:

```text
{"kind": "allow", "subject": {"modules": ["logos_capability_authority"]}, "scopes": [{"kind": "provider-access", "contract": "capability-authority", "actions": ["publish-event"], "access": {"publish_events": ["observed_change"]}}]}
{"kind": "allow", "subject": {"instances": ["orchestrator"]}, "scopes": [{"kind": "runtime-control", "methods": ["get_self", "list_modules", "get_readiness", "recover_module", "start_module"]}]}
{"kind": "deny", "subject": {"instances": ["orchestrator"]}, "scopes": [{"kind": "runtime-control", "methods": [], "events": ["route_state_changed"]}], "code": "target-denied"}
{"kind": "allow", "subject": {"instances": ["orchestrator"]}, "scopes": [{"kind": "module-execution", "targets": {"instances": ["authority", "logosctl"]}, "actions": ["start"]}, {"kind": "permission", "permission": "logos-core-nim.host-ambient"}]}
{"kind": "allow", "subject": {"instances": ["logosctl"]}, "scopes": [{"kind": "runtime-control", "methods": ["get_self", "list_modules", "list_routes", "get_readiness", "get_execution_summary", "get_permission_settings", "get_configuration_schema", "get_configuration_summary", "get_configuration", "update_configuration", "apply_configuration", "create_module", "start_module", "stop_module", "recover_module", "retire_module", "shutdown_runtime"]}]}
{"kind": "deny", "subject": {"instances": ["logosctl"]}, "scopes": [{"kind": "runtime-control", "methods": []}], "code": "target-denied"}
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
- **S5**: `logosctl` may restore the orchestrator only with `recover_module` (R l.3807-3808); it may not
  stop, retire or reconfigure it. The orchestrator is configured only by daemon-config.

The operator's rules follow, sorted and deduplicated with the system ones. An operator rule may grant
more to operator instances, and may grant the `logosctl` instance access to operator providers; it
cannot undo a system deny, since a deny wins ([AUTHORITY-POLICY.md](AUTHORITY-POLICY.md)).

**Permission settings.** The reference profile is always selected. logosd writes `host-ambient` (empty
constraints) for `orchestrator`, `logosctl` and `authority`, and the module entry `host-ambient` for each
operator module the operator gave no module entry: the minimum each realization needs. No module
administers the system instances' settings: `update_permission_settings` is not among `logosctl`'s
methods, and no system rule grants it (BCP l.364).

**allow-all** gives every operation to everyone (RUNTIME l.1633). logosd accepts it only with the
development switch on (§6).

**recovery** (RUNTIME l.1676): the derived rules also apply after a binding loss. Absent is off; `init`
writes `true`.

## 6. The trust file and the development switch

`<session>/trust.cbor` is the revisioned trust input (PACKAGE MANAGER l.395-400): a revision and the
development switch. Tier 5 adds the package-signing anchors. Without the file, the compiled-in floor
applies: revision 1, switch off. `state/trust-mark.cbor` records the highest revision used and the
BLAKE3-256 digest of its bytes, written durably before that revision is used.

```cddl
; logosd's trust input and its continuity record, and the binding of a
; call-evidence key (Tier 4b step 4b-6; DECISIONS I95, G297, G299). Each is one
; Logos deterministic-CBOR value in a file of its own; docs/DAEMON.md documents
; them.

; logos-core-nim.trust.v1, <session>/trust.cbor: the revisioned trust file
; (G137; PACKAGE MANAGER l.395-400). development is D27's switch. Tier 5 adds
; the package-signing anchors. Without the file the compiled-in floor applies:
; revision 1, development false.
lcn.trust_file = {
  format: "logos-core-nim.trust.v1",
  revision: uint64,
  development: bool,
}

; logos-core-nim.trust-mark.v1, <session>/state/trust-mark.cbor: the highest
; revision used and the digest of that revision's bytes (BLAKE3-256).
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

At each start logosd reads the file and the mark and decides:

| Mark | File | Decision |
|---|---|---|
| absent | any | refused: "trust continuity is not established" |
| revision r | revision > r | the mark is written, then the revision used |
| revision r | revision = r, same digest | accepted (an identical replay) |
| revision r | revision = r, other digest | refused: a changed file needs a higher revision |
| revision r | revision < r | refused: rollback |

A refusal is exit 1. logosd never creates a mark. `logosctl init` writes the file and its mark together;
`logosctl trust reestablish --revision N` writes a mark from the current file when the owner names its
revision (after the mark alone was lost, or `state/` was restored from a backup; a lost `state/` also
lost the Runtime's store and needs a new session, §2). The trust file is read twice during start, and a change
between the reads is refused.

**The development switch** (D27). `logosctl trust development on|off` writes the next revision with the
switch set or cleared; `init --development` starts at revision 2 with it on, so revision 1 keeps the
floor's content. With the switch on:

- `policy: allow-all` is accepted;
- `test_hooks` is accepted by a logosd built with test hooks (a test build). A packaged logosd has none
  and refuses the field whatever the switch says: "test_hooks: this logosd has no test hooks". The flake
  check `no-test-hooks` verifies no packaged output holds hook code;
- the deployment is **non-production**, and says so: a `NON-PRODUCTION` warning in the start log; every
  `logosctl` output, online and offline (`deployment: "non-production"` in JSON, a
  `NON-PRODUCTION deployment` line in text); every socket reply's `deployment`.

The switch weakens nothing else. Continuity still applies (a rollback is refused with the switch on), and
under capability-authority the system rules still deny, for example, `module stop logos_module_loader`.

## 7. The logosctl instance and its socket

The `logosctl` module is a consumer-only module linked into logosd (`direct_static`), realized by the
Loader like every instance, and persistent. Its instance serves the socket. Each command becomes one
Runtime Control call **by the instance**, through its own binding: the shell is never the consumer.

### Activation (BCP l.384)

The socket is external application activation, documented by the five items BCP l.384 lists:

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
   realization constraint (BCP l.386-387): the commands are the seventeen methods below, with the
   Runtime's own checks.
4. **Presentation handoff.** At initialization logosd hands the instance, in process: the socket path,
   the worker count and idle timeout, the deployment, the trust revision, logosd's version and start
   time. Nothing that authenticates a caller crosses it, or the socket: no binding, ticket or invocation
   descriptor. Addresses cross only as data, never as identity (R l.1606, l.2561).
5. **Failure behaviour.** The instance binds the socket during its initialization and serves only after
   initialization returned; a command that arrives earlier waits (BCP l.388). A bind failure fails the
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
shared operating-system user is not an isolation boundary (THREAT l.1107): run logosd under a user of
its own where that matters. The peer's uid and pid are kept with each command as requester provenance, in
the instance's log lines; they never reach a Runtime Control request and never stand for the consumer
(BCP l.382).

**No payload is relayed.** The seventeen methods are reads, lifecycle, configuration and shutdown. No
method payload of any operator module, and no event, crosses the socket or passes through the instance.
A later command that calls a provider would connect to the provider itself.

### The methods

`get_self`, `list_modules`, `list_routes`, `get_readiness`, `get_execution_summary`,
`get_permission_settings`, `get_configuration_schema`, `get_configuration_summary`, `get_configuration`,
`update_configuration`, `apply_configuration`, `create_module`, `start_module`, `stop_module`,
`recover_module`, `retire_module`, `shutdown_runtime`. Nothing else (`evaluate`, the permission and remote
methods) can be encoded. `list_routes` returns no invocation in any record (R l.3365).

`module create` carries a request key: `lcli-` and 32 random hex digits, generated by the shell for each
command and printed with the result. `--request-key K` repeats an earlier key, so a create whose answer
was lost can be retried, across a daemon restart too, and returns the same instance.

### The wire format `logos-core-nim.ctl.v1`

BCP l.390 assigns no encoding; this one is logos-core-nim's.

- A frame is a 4-byte big-endian length and one Logos deterministic-CBOR value, at most 32 MiB
  (33554432 bytes) each way.
- A connection carries any number of message and reply pairs, in sequence. It is closed after
  `idle_timeout_ms` without a complete message (a partial frame included), and after a refusal.
- A message is `lcn.ctl_message`; the reply `lcn.ctl_reply`, which always names the deployment.
- `rc` carries a method, the Runtime Control request bytes, and an optional deadline. The instance makes
  one Runtime Control call with those bytes, deadline `min(deadline_ms, 60 s)`, and returns the response
  bytes verbatim (BCP l.392), or the call's error code, message and detail. It does not decode `params`:
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
the instance stops.

## 8. Administration

There is no approval path and no client command that changes authority. The policy, its grants and the
trust input change only through the owner-only files, offline: `logosctl init`, `logosctl daemon config
set`, `logosctl trust …`, or the owner's own edits, each applying at the next start (BCP l.380-382).

- **Authentication** of that path is the operating system's: the files are the session owner's, mode
  0600 in 0700 directories, and logosd refuses a session others can access.
- **What it authorizes**: everything logosd does. Whoever can write the session can change the policy,
  the trust file and its switch, and the evidence key.
- An `issue` rule in the policy is protected input too. Under it a module may issue grants while the
  daemon runs (CA l.752), within what the rule allows; that is the only change of authority at run time.
- **State transfers** are the same kind of input (decision 9): an entry in `state_transfers`, set with
  `daemon config set` while logosd is stopped, authorizes one replacement instance to take another's
  state at the next start (§11). No socket command and no Runtime Control method moves state.

## 9. Call evidence

The Runtime's invocation boundary keeps a `call` record for each call whose applied decision retains a
commitment (CA l.1172-1198), in a ring of `call_audit.call_records` records, lost at exit (I85).
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

- **Bounds** (G143; CA l.1169). Whole segments, oldest first, are reaped when the store opens and at each
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
  record (CA l.1321, as I85 reads it; CAP-0416). There is no export through the socket and no client
  command.
- **What is exported.** A `logos.call-evidence.cose-sign1-slh-dsa-sha2-192s` container for the record as
  stored, complete and with no proofs (CA l.1322; as I85). It is signed with the current evidence key,
  the one daemon-config names, checked against its binding (§3, check 4), for the Runtime that binding
  names: a kid maps to one producer (CA l.1265, l.1290). Signing in the shell uses the Runtime's own key
  on the Runtime's behalf. A segment whose header names another Runtime is refused: "seg-… was written by
  Runtime X; the current evidence key belongs to Runtime Y". The container authorizes nothing (CAP-0256).
- **Not retained.** A seq that was reaped, dropped, cut off or never stored is refused: "seq N is not
  retained", exit 1 (CAP-0417).
- **Delivery.** `--out FILE` creates the file with `O_EXCL` and mode 0600; an existing file is refused.
  Without `--out` the container goes to stdout when stdout is not a terminal, and is never written to a
  terminal.
- **The key.** A rotated key (`trust evidence-keys rotate`) applies at the next start. Its binding stays,
  marked retired, with only the public half (CA l.1273). An export always signs with the current key, so a
  record stored under an older kid is re-signed; a verifier needs the current key's binding.

### Limits

These are what the store does and does not protect (CA l.1320; CAP-0415):
- **What a record holds**: the consumer's address, the decision id, one call scope, a timestamp, and for
  each retained side its schema subtree root and value root. No payload, proof or constraint value.
- **No marked side.** A call whose decision would retain a marked side's root is refused before dispatch
  (IF l.397, IFC-0581, G278), so no record holds one.
- **Guessable data.** A retained root of guessable data discloses it to whoever can read the store (SEC
  l.402).
- **Who can read it.** Other operating-system users are kept out by the modes; processes of the same user,
  backups and the disk are not. The store is plaintext at rest.
- **Integrity.** None beyond the file modes: whoever can write the session can change a record before it
  is exported, and the export signs what the store holds.
- **Load.** Under load records are dropped, as recorded gaps.
- **Rotation** re-signs with the current key (above).
- **Hosted providers.** A hosted provider's call roots are the ones its Module Host reports (G274);
  CONFORMANCE states the trust that rests on.

## 10. Remote surfaces

logosd has no remote transport, no listener and no provider export: nothing is reachable from another
host (SEC l.524; R l.2830). The Runtime Control's remote methods answer as
[HOST-CONFIG.md](HOST-CONFIG.md) says, after authorization (R l.1626): the two lists an empty page,
`set_provider_export` INVALID_PARAMS, `set_remote_listener` MODULE_ERROR for enabling a listener and
success for disabling one, with no record kept. `logosctl` calls none of them.

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
  is kept".
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
     directory under `state/modules` to `b`'s; afterwards `logosctl module ls` lists `b` and not `a`
     (the Runtime's own diagnostic is not printed in logosd's log). The orchestrator then starts `b` like any operator instance, under the policy's rules
     for `b`: a grant or rule naming `a` does not cover it.

  An applied entry changes nothing at later starts; remove it when convenient. A refused transfer
  fails the start with nothing changed, and the log names the reason ([HOST-CONFIG.md](HOST-CONFIG.md),
  "State transfer to a replacement instance"). `a` must have stopped cleanly or the daemon's last run
  must have ended: a hosted `a` whose Module Host of an earlier run still holds its restart lock is
  refused until that process is gone; find it with `lsof <file>` or `fuser <file>` on the file the
  message names, end it, and start again. A `move` reads nothing: the files are renamed in place.

## 12. Diagnostics

logosd logs to stderr, one line per event: `logosd[<pid>]: <level>: <text>`, levels `error`, `warn` and
`info` (`--log-level`, default `info`). A service manager collects it. The start log has the ready line
(§4), the `NON-PRODUCTION` warning when the switch is on, the call-evidence store's line when it is on
(§9), the orchestrator's lines, and one line per socket command (`logosctl: <method> from uid U pid P:
<code>`). The store warns when it drops records or cuts off a torn tail.

**The logging rule** (IF l.395, SEC l.403, G278): no log line holds a payload, a value root, a ticket, a
key, record content, or the failure text of a method with a marked field. Method names, schema roots,
codes and instance ids are metadata and may appear.

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

**Profiles** (BCP l.361). The local transport profile is `logos.local.unix-stream`, with endpoints under
`run/ep/`. No remote profile is enabled. The permission profile is `logos-core-nim.permission-profile.v1`.
A selected profile that cannot be used fails the start or the realization that needs it; nothing falls
back.

**Waits** (BCP l.372):

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
must end (R l.3823-3824). logosd:

1. receives the Runtime's termination notice (it names the instances left unresolved) and logs
   "the Module Loader failed; termination required for …". The notice comes through the Host API's
   termination hook on whichever thread the Runtime ran it, which signals the process
   (`kill(getpid(), SIGUSR1)`), so logosd's signal thread takes it;
2. requests shutdown; the wait returns with the loss;
3. does not destroy the Runtime. It writes out the call-evidence store (§9), waits up to 10 s for every
   Module Host to be gone (their restart locks under `work/hosts/`), logs "exiting with 4", and exits 4.
   It keeps the session lock to the end: the kernel drops it with the process, so no offline writer or
   second logosd holds the session while the orphaned in-process code still runs (R l.3824, l.2641).

The Runtime sends the notice only when the failed Loader leaves in-process realizations. Under logosd
that is always so: `orchestrator`, `logosctl` and, under capability-authority, `authority` are
`direct_static`.

A service manager restarts it (§13); the new process composes a new Runtime from the same session.
Run without one, logosd stays stopped after exit 4 until someone starts it.
