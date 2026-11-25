# Host configuration: `logos-core-nim.app-config.v1`

The Host Embedding API (RUNTIME §13) takes one configuration at `logos_runtime_create`, in a format
the implementation names and documents (RUNTIME §13.3: "The implementation MUST document each
supported identifier and its configuration semantics"). logos-core-nim supports one format, chosen
in DECISIONS G76 for any embedding host:

| | |
|---|---|
| Identifier | `logos-core-nim.app-config.v1` (`LCN_RUNTIME_CONFIG_FORMAT_APP_V1` in `logos_runtime.h`) |
| Encoding | one Logos deterministic-CBOR value (INTERFACE §4.4), nothing after it |
| Schema | `lcn.app_config`, below (`src/logos_core/runtime/host_config.cddl`) |

```c
logos_runtime_config_t config = {
    .abi_version = LOGOS_RUNTIME_HOST_ABI_VERSION,
    .struct_size = sizeof config,
    .configuration_format = LCN_RUNTIME_CONFIG_FORMAT_APP_V1,
    .configuration = bytes,          /* the encoded lcn.app_config */
    .configuration_len = bytes_len,
};
logos_runtime_t* runtime;
logos_result_t r = logos_runtime_create(&config, &runtime);
```

Any other identifier, and any configuration this page does not allow, is rejected with
`LOGOS_ERR_INVALID_PARAMS` and a message. Only undecodable bytes carry a `logos.invalid_params_detail`
(`malformed-cbor` or `non-deterministic-cbor`). The configuration is borrowed for the call: the Runtime
keeps a copy. `create` opens no file, starts no thread and runs no module code.

The whole configuration is protected bootstrap and deployment input in the sense of RUNTIME §8
l.1313-1314: whoever can write it decides which code runs and under which authority policy. Supply it
from a source only the host's owner can change.

## Schema

```cddl
; logos-core-nim.app-config.v1: the Host Embedding API configuration (RUNTIME
; §13.3 configuration_format; decision G76). One Logos deterministic-CBOR
; lcn.app_config value. docs/HOST-CONFIG.md documents each field.
;
; An array that is present is non-empty, and the checks the schema cannot
; express (unique ids, ordering, the orchestration instance, the authority
; instance, the package manager instance, the artifact adoption list) are
; applied at logos_runtime_create (runtime/host_config.nim).
; lcn.authority_policy is the Capability Authority's policy input,
; authority/policy.cddl (docs/AUTHORITY-POLICY.md).

lcn.app_config = {
  runtime: lcn.app_runtime,
  policy: lcn.app_policy,
  orchestration: lcn.app_instance_id,
  modules: [* lcn.app_module],
  ? ordering: [* lcn.app_ordering],
  ? declarations: [* lcn.app_declaration],
  ? call_audit: lcn.app_call_audit,
  ? routing: [* lcn.app_routing_rule],
  ? transport: lcn.app_transport,
  ? remote: lcn.app_remote,
  ? permissions: lcn.app_permissions,
  ? state_transfers: [* lcn.app_state_transfer],
  ? protected_inputs: [* lcn.app_protected_input],
  ; [G490] The instance that holds the Package Manager responsibility (RUNTIME
  ; l.293): the hosted_dynamic logos_package_manager, the one hosted module
  ; whose reserved name the Module Host accepts.
  ? package_manager: lcn.app_instance_id,
  ; [G505] Instances whose retained record may take a new artifact hash at a
  ; start, all other facts equal: the host's assertion that the instance keeps
  ; its state, grants and settings across a new library. logosd lists its own
  ; composed instances (package_manager, lcn_call), never an operator's.
  ? artifact_adoption: [* lcn.app_instance_id],
}

lcn.app_runtime = {
  work_dir: lcn.app_path,
  ? state_root: lcn.app_path,
  ? store_dir: lcn.app_path,
  ? runtime_instance_id: tstr .size (1..128),
  ? startup_deadline_ms: uint32,
  ? stop_deadline_ms: uint32,
  ? shutdown_grace_ms: uint32,
  ? apply_deadline_ms: uint32,
  ? max_payload_depth: uint16,
  ? endpoint_dir: lcn.app_path,
  ? module_host: lcn.app_path,
  ? module_host_env: [* lcn.app_env_name],
  ? remote_program: lcn.app_path,
}

; module_host: the logos-module-host program, an absolute path (Tier 4b step
; 4b-3); without it hosted_dynamic is refused. module_host_env: the names of
; the variables every Module Host gets from the daemon's environment.
; remote_program: the logos_remote program, an absolute path (Tier 5 step
; 5-7a-2; DECISIONS G411); without it no remote profile is enabled here, and
; enabling a remote listener is MODULE_ERROR (G412).
lcn.app_env_name = tstr .size (1..128)

lcn.app_path = tstr .size (1..4096)

; allow-all: every operation is allowed (RUNTIME l.1633-1634).
; capability-authority: the named logos_capability_authority instance decides
; (RUNTIME §9; DECISIONS I85). evaluation_deadline_ms: 1..60000, default 5000;
; recovery: the derived rules also apply after a binding loss (RUN-0860).
lcn.app_policy =
  { kind: "allow-all" } /
  {
    kind: "capability-authority",
    authority: lcn.app_instance_id,
    policy: lcn.authority_policy,
    ? evaluation_deadline_ms: uint32,
    ? recovery: bool,
  }

; Call audit (CA §9, §9.1): call_records is the in-memory ring's capacity,
; 1..1000000, default 4096; evidence the call-evidence signing key.
lcn.app_call_audit = {
  ? call_records: uint32,
  ? evidence: lcn.app_evidence_key,
}

; kid: the logos.capability_authority.evidence_key_id verifiers map to this
; Runtime; secret_key_file: a 96-byte SLH-DSA-SHA2-192s secret key, mode 0600.
lcn.app_evidence_key = {
  kid: bstr .size (1..128),
  secret_key_file: lcn.app_path,
}

; Routing selection (RUNTIME l.901-911; DECISIONS I90, G254): a route
; from a module named caller (absent: any) to the module named callee is
; direct or uses local transport. The rule naming the caller wins; with no
; rule a route is direct. No rule names logos_module_loader, no callee is
; logos_runtime_control, and local-transport is refused where the platform
; has no unix-stream profile (TRANSPORT §8.2.1).
lcn.app_routing_rule = {
  ? caller: tstr .size (1..64),
  callee: tstr .size (1..64),
  mode: "direct" / "local-transport",
}

; The transport I/O thread's limits (TRANSPORT §5.2, §8.6; DECISIONS I90);
; an absent field keeps its default. docs/HOST-CONFIG.md lists every limit.
; frame_limit is at least 16 MiB (TRANSPORT l.380).
lcn.app_transport = {
  ? frame_limit: uint32,
  ? hello_timeout_ms: uint32,
  ? write_stall_timeout_ms: uint32,
  ? max_pending_output_bytes: uint64,
  ? conn_output_bytes: uint32,
  ? caller_undelivered_bytes: uint32,
  ? max_inbound: uint16,
  ? max_outbound: uint16,
  ? max_calls: uint32,
  ? max_in_flight: uint32,
}

; Remote transport (RUNTIME §9.3.9; Tier 5 step 5-7a-2; DECISIONS G408, G412,
; G415; docs/REMOTE.md). Only the embedding host sets it (logosd's compose).
; snapshot: this start's trust snapshot, one deterministic-CBOR lcn.rch_snapshot
; (remote/carrier.cddl); its Runtimes with an active record are the enrolled
; ones. listeners and exports: the deployment's records (RUNTIME l.3319-3321),
; held as Runtime Control holds them (lcn.rc_x is logos.runtime_control.x and
; lcn.rt_x is logos.runtime.x, generated from the mirrored contract), each
; address at most once and each export naming a listener here, validated as
; Runtime Control validates them.
lcn.app_remote = {
  snapshot: bstr .size (1..16842752),
  ? listeners: [* lcn.rc_remote_listener_record],
  ? exports: [* lcn.rc_provider_export_record],
}

; The permission profile (RUNTIME l.1595, l.2526-2604; DECISIONS G110, G279,
; I93; docs/PERMISSIONS.md). Absent: no profile is selected and permission
; settings have the constant form (G229). profile names a profile this library
; ships. initial is the protected provisioning of a new instance's settings
; (RUNTIME l.2543): the entry naming the instance, else its module's entry,
; else revision 1 with no permission (l.2541). It never names the Module
; Loader, whose settings are its construction's (G253). Each permissions array
; is ascending by permission name and names only defined permissions the
; Runtime enforces; it may be empty.
lcn.app_permissions = {
  profile: "logos-core-nim.permission-profile.v1",
  ? initial: [* lcn.app_initial_settings],
}

lcn.app_initial_settings = {
  module: tstr .size (1..64),
  ? instance: lcn.app_instance_id,
  permissions: [* lcn.app_permission_setting],
}

; logos.runtime_control.permission_setting (RUNTIME l.2348-2351)
lcn.app_permission_setting = {
  permission: tstr .size (1..128),
  constraints: bstr .size (1..1048576),
}

; One state transfer (RUNTIME l.3546-3553; DECISIONS I96, G305-G307),
; applied once, when start bootstraps, before anything starts. to is a listed
; instance new to the Runtime with its own state_assignment; from is an
; instance the Runtime retains or retired, not listed in modules. from is
; stopped and retired in the same write that creates to, which then gets
; from's state: move renames from's state directory to to's; copy copies it
; (at most max_bytes, default 1 GiB) and leaves it as it was. The entry is the
; deployment's assertion that to can use that state: the Runtime infers none
; from names, versions or contracts (RUN-0999). docs/HOST-CONFIG.md, "State
; transfer".
lcn.app_state_transfer = {
  from: lcn.app_instance_id,
  to: lcn.app_instance_id,
  mode: "move" / "copy",
  ? max_bytes: uint64,
}

; logos.runtime.module_instance_id (RUNTIME §9.2)
lcn.app_instance_id = tstr .size (1..128)

lcn.app_module = {
  instance: lcn.app_instance_id,
  module: tstr .size (1..64),
  implementation: lcn.app_implementation,
  ? primary_contract: logos.schema_commitment,
  ? implements: [* logos.schema_commitment],
  ? extends: [* logos.schema_commitment],
  ? requires: [* lcn.app_requirement],
  ? requested_permissions: [* lcn.app_permission],
  ? state_assignment: tstr .size (1..128),
  ? configuration: lcn.app_configuration,
  ? provisioned_configuration: bstr .size (1..8388608),
}

; One deterministic-CBOR logos.module_configuration.configuration_declaration
; (CONFIG §2): the module's schema binding and its optional package default.
; provisioned_configuration is this instance's protected value (CONFIG l.142;
; decision G141), a complete value of the binding's root; it needs
; configuration. docs/HOST-CONFIG.md says when a changed value takes effect.
lcn.app_configuration = bstr .size (1..16777216)

; logos.module_loader.direct_static, direct_dynamic and hosted_dynamic with
; the process placement (LOADER §3)
lcn.app_implementation =
  { strategy: "direct_static", binding: tstr .size (1..128) } /
  { strategy: "direct_dynamic", artifact: lcn.app_artifact } /
  { strategy: "hosted_dynamic", placement: "process", artifact: lcn.app_artifact }

; logos.module_loader.artifact (LOADER §3)
lcn.app_artifact = {
  id: tstr .size (1..128),
  local_path: lcn.app_path,
  hash: bstr .size 32,
  hash_suite: "logos.hash-suite.blake3-256",
}

; logos.package_manifest.provider_requirement (PACKAGE MANAGER §4)
lcn.app_requirement = {
  contract: logos.schema_commitment,
  cardinality: "single" / "all-runtime-visible",
}

; logos.package_manifest.requested_permission (PACKAGE MANAGER §4)
lcn.app_permission = {
  permission: tstr .size (1..128),
  constraints: bstr .size (1..1048576),
  ? reason: tstr .size (1..512),
}

; one lifecycle-ordering constraint (RUNTIME §3.7)
lcn.app_ordering = {
  prerequisite: lcn.app_instance_id,
  dependent: lcn.app_instance_id,
}

; One accepted declaration per module name, for create_module (decision G55;
; RUNTIME l.3614-3621): lcn.app_module without instance, state_assignment and
; provisioned_configuration (a provisioned value belongs to an instance, never
; to a module name: RUN-0923). With persistent_state, each created instance
; gets a fresh state assignment.
lcn.app_declaration = {
  module: tstr .size (1..64),
  implementation: lcn.app_implementation,
  ? primary_contract: logos.schema_commitment,
  ? implements: [* logos.schema_commitment],
  ? extends: [* logos.schema_commitment],
  ? requires: [* lcn.app_requirement],
  ? requested_permissions: [* lcn.app_permission],
  ? persistent_state: true,
  ? configuration: lcn.app_configuration,
}

; The protected realization input of one instance (decision G400): protected
; construction input (RUNTIME l.1600-1601) that only the embedding host sets.
; At each realization attempt the Module Loader writes `input` to
; `<state_dir>/.lcn-protected-input`, and removes it when initialization
; returns, at release and at retirement (docs/HOST-CONFIG.md). The instance is
; listed in `modules`, has a state_assignment, and has at most one entry. Not
; for secrets: the file passes through a directory that backups and state
; copies may read.
lcn.app_protected_input = {
  instance: lcn.app_instance_id,
  input: bstr .size (1..16777216),
}
```

Maps are closed: an unknown key anywhere is rejected. An array that is present must be non-empty
(RUNTIME §8 l.1357), even where the CDDL writes `[*`; the CDDL tooling has no `+` occurrence yet. The
one exception is the `permissions` array of a `permissions.initial` entry, which may be empty.

## Fields

### `runtime`

| Field | Meaning |
|---|---|
| `work_dir` | Absolute path of a directory the Runtime owns. `direct_dynamic` artifacts are copied into private subdirectories here, verified and mapped from the copy (LOADER §3; DECISIONS I74). Created with mode 0700 at `logos_runtime_start` if missing. |
| `state_root` | Optional absolute path under which module state directories are assigned (G143). Created with mode 0700 at `start` if missing. |
| `store_dir` | Optional absolute path of the directory that holds the Runtime's persistent state (below, "Persistent Runtime state"). It must be apart from `work_dir` and `state_root`: neither inside the other nor equal. [IMPL] The comparison is by path text and case-sensitive, so on a case-insensitive filesystem (Windows, and macOS by default) paths that differ only in case are not detected. Without it nothing persists. |
| `runtime_instance_id` | Optional `runtime_instance_id` for the Runtime, 1 to 128 bytes of text; only with `store_dir`. Without it, the identity is generated when the store is created and kept with it. |
| `startup_deadline_ms` | How long one module realization may take from authorization to `ready`, including its `_MODULE_init` (RUNTIME §3.4; G61). Default 120000. It does not bound the Module Loader's start, which has its own deadline (below, "The Module Loader"). |
| `stop_deadline_ms` | How long a stop may take. Past it the instance stays `stopping` and reports `cleanup-timeout` until its cleanup ends, which completes the stop (RUNTIME l.575-577; DECISIONS G180); a Module Host is ended then. Default 10000. |
| `shutdown_grace_ms` | How long shutdown waits for in-flight work before cleanup is left unresolved (RUNTIME §10.2). Default 10000. |
| `apply_deadline_ms` | How long a live configuration application (`apply_configuration`) may take, from its acceptance to the module's answer (CONFIG §8; DECISIONS G61, I87). When it passes, the outcome is unknown and the instance enters `error` with `configuration-indeterminate` (one already `stopping` stays `stopping`, CONFIG l.328), so the default is long: 120000. |
| `max_payload_depth` | The Runtime's one payload depth limit (INTERFACE §4.5.1 l.3104; DECISIONS G241, I88): how many arrays and maps may nest on any path of a payload, counted from the payload's own root (the root map is depth 1; byte-string contents are not traversed). It applies to every payload the Runtime decodes or validates: route call requests and responses, asynchronous calls, events, Runtime Control requests and responses, and configuration values (defaults, provisioned and updated). A payload one level deeper is refused before it is dispatched, accepted or delivered, with `LOGOS_ERR_INVALID_PARAMS` and no detail for a request (a provider's too-deep response or event is a `LOGOS_ERR_MODULE` failure or a dropped publication). 128 to 1024; default 1024. A transported route (Tier 4b) gives its frame decoder this limit plus the envelope's own levels. Modules built with lcn-gen's kit check their own inputs at 1024. |
| `endpoint_dir` | Absolute path of the directory under which the Runtime creates the endpoints of transported routes (TRANSPORT §8.2; DECISIONS G58, I90): one fresh `<8 hex>` directory of mode 0700 per served provider, holding the socket `logos_<module>.sock`. Default `<work_dir>/endpoints`. Used only when a `routing` rule selects `local-transport`: then it is created with mode 0700 at `start` if missing, and it must be a real directory of the Runtime's user that no one else can write to, or a root-owned sticky directory such as `/tmp`. Keep it short: the socket's name is shortened when the path would not fit the platform's `sun_path` (104 bytes on macOS, 108 on Linux, its NUL included), down to `logos_.sock` (DECISIONS G58, amended 2026-11-21); a directory that leaves no room for `<endpoint_dir>/<8 hex>/logos_.sock` cannot hold an endpoint, and `start` fails, as it does for a base that is not such a directory. Directories a crashed Runtime left behind are not removed. |

| `module_host` | Absolute path of the `logos-module-host` program (DECISIONS G264, I91), which runs each `hosted_dynamic` instance in a process of its own (below, "Module Hosts"). It is protected deployment input like the rest of this file (LOADER l.107-108), and is checked when the configuration is read: the path's last component is not a symbolic link, it is a regular file owned by the Runtime's user or by root, writable by its owner only, and executable by its owner. Its directories are the deployment's to protect. Without it the Module Loader does not advertise `hosted_dynamic` and a `hosted_dynamic` module or declaration is refused ("hosted_dynamic needs module_host"). Not supported on Windows. |
| `module_host_env` | The names of the environment variables every Module Host gets, each with the value the Runtime's own process has when `start` runs (a name it does not have is left out). Each name is 1 to 128 bytes, without `=`, listed once; the list is not empty when present. Nothing else of the Runtime's environment reaches a host, not even `PATH`. Typical entries are a sanitizer's options or `TZ`. |

Each deadline is 1 to 3600000 milliseconds. Paths must be absolute, so their meaning does not depend
on the host's working directory.

### `policy`

The Runtime's authority policy (RUNTIME §9 l.1545-1547): it decides Runtime Control, lifecycle, route
and observation requests, including those of the bootstrap. Two kinds:

- `allow-all`: every request a module makes through its Runtime Control binding is allowed. This is
  the internal policy RUNTIME l.1547 permits "for local trusted deployments": use it only when every
  configured module is code the host trusts with the whole Runtime. It must be written explicitly;
  nothing is allowed by default (RUNTIME l.1590, l.1598).
- `capability-authority`: the listed instance `authority` of the Capability Authority module decides
  (RUNTIME §9; CA; DECISIONS I85), from `policy`, an `lcn.authority_policy` value
  (`docs/AUTHORITY-POLICY.md`). `evaluation_deadline_ms` bounds how long a request waits for its
  decisions, from when it is queued for evaluation: 1 to 60000, default 5000, and below
  `startup_deadline_ms`. With `recovery: true` the bootstrap rules apply again after the authority is
  lost, so the orchestration instance can recover it (RUNTIME l.1590-1596); default false.

  Checked at `create`: `authority` names a listed instance whose `module` is
  `logos_capability_authority` and whose implementation is the `direct_static` binding
  `logos_capability_authority`; its `primary_contract`, when given, is the pinned Capability Authority
  contract, and when absent it is set to that contract, so the authority instance has a provider
  record like any provider (RUNTIME l.156-164, l.1349-1350, l.1563; DECISIONS I88; the realized
  contract is checked again when the instance is bound, and the Runtime never binds an authority
  instance without a provider record); it has a
  `state_assignment`; `runtime.store_dir` and `runtime.state_root` are set; and `policy` loads as the
  authority will load it. The orchestration instance cannot be the authority, since its module name
  is outside the reserved prefix. What the host can expect under this kind is below ("Under
  `capability-authority`").

Any other kind is rejected with "this policy kind is not supported yet".

### `permissions`

The permission profile and the protected provisioning of new instances' permission settings (RUNTIME
l.1511, l.2450-2532; DECISIONS I93, G110, G279; `docs/PERMISSIONS.md`). Absent: no profile is selected,
and every instance has the constant settings of "Permission settings in direct mode" below (DECISIONS
G229). Present:

| Field | Meaning |
|---|---|
| `profile` | The profile this library ships, `logos-core-nim.permission-profile.v1`: one permission, `logos-core-nim.host-ambient`, which every realization must hold. Under `capability-authority` the authority gets the same profile, so a policy can name permissions (`docs/AUTHORITY-POLICY.md`). |
| `initial` | The settings a new instance is created with (RUNTIME l.2470): the entry naming its `instance`, else the entry for its `module` without `instance`, else revision 1 with no permission (l.2468). Never its `requested_permissions` or a declaration (RUNTIME l.2470). Each entry's `permissions` is ascending by permission name, names only permissions the profile defines and the Runtime enforces, with constraints the definition admits, and may be empty, so an instance entry can withdraw what its module's entry gives. |

Checked at `create`, each failure `LOGOS_ERR_INVALID_PARAMS` naming the entry: entries are unique by
module and instance; an `instance` names a listed instance of that `module`; no entry names the Module
Loader's module or instance, whose settings are its construction's (DECISIONS G253); and the
orchestration instance, and under `capability-authority` the authority instance, are provisioned with
host-ambient, since bring-up starts them through the same admission as any instance (DECISIONS G284).
These entries apply only when an instance is created: an instance the store already holds keeps its
saved settings ("Persistent Runtime state").

**A trap.** An authorized `update_permission_settings` that removes host-ambient from the orchestration
or the authority instance stops it at once (reconciliation), and makes every later bring-up fail with
`LOGOS_ERR_NOT_AUTHORISED` until the settings are replaced. The library leaves that to the host's
policy: do not grant settings administration of system instances (logosd's system rules do not:
docs/DAEMON.md §5).

### `orchestration`

The `instance` of the one listed module that holds the orchestration role (RUNTIME l.178-183;
DECISIONS G53). The role follows this field only: no module name confers it (RUN-0785), and the
module's name must not start with the reserved `logos_` prefix. The orchestration instance may not be
an ordering `dependent`, since nothing starts its prerequisites before bootstrap.

### `modules`

Each entry is one module instance and the resolved module facts it is created from (RUNTIME §8). All
are created at `start`, in this order, as `unloaded` with execution intent `uninitialized`; only the
orchestration instance is started by the Runtime. With a `store_dir`, an instance the store already
holds is not created again: it keeps its state and intent (below).

| Field | Meaning |
|---|---|
| `instance` | The instance's protected `module_instance_id`, unique in the configuration. Names of the form the Runtime gives what it creates (`m-`, `s-` or `p-`, 32 lowercase hexadecimal digits, `-`, a decimal number) are refused, here and as `state_assignment`. |
| `module` | The flat runtime module name (RUNTIME §1.3). |
| `implementation` | `direct_static` with a `binding` identifier the host registers with `logos_runtime_register_binding` before `start`; `direct_dynamic` with an `artifact` (`id`, absolute `local_path`, BLAKE3-256 `hash`), verified against the exact bytes before mapping; or `hosted_dynamic` with `placement: "process"` and an `artifact`, verified the same way and mapped in a Module Host process of its own (needs `runtime.module_host`; below, "Module Hosts"). A static binding no entry names is kept until `destroy`; one a new instance names but never registered makes `start` fail with `LOGOS_ERR_INVALID_PARAMS` before anything runs, and a retained instance whose binding is no longer registered starts up mismatched (below, *Instances and the configuration*). A hosted implementation never names a static binding (RUNTIME l.1440-1441), and `sandbox` and `container` placements are not offered. |
| `primary_contract`, `implements`, `extends` | Expected contract commitments: the primary concrete contract, the implemented interfaces, and the earlier contracts that the module's contracts extend (COMMITMENT §9.1). They are checked against the call-surface descriptor the implementation reports at binding and prove nothing on their own (RUNTIME §8 l.1340-1343). Once one is stated, an omitted `primary_contract` means none and an omitted `implements` or `extends` means empty, and all three must equal the descriptor's exactly, so a module that implements an interface or extends a contract needs every one listed (INTERFACE l.1717; DECISIONS G393). With neither `primary_contract` nor `implements` the instance declares no contract and has no provider record. Implemented and extended commitments are unique over both arrays, and `extends` needs `primary_contract` or `implements` (DECISIONS G394). |
| `requires` | Provider requirements: a contract and a cardinality, each entry naming a distinct contract. They select and grant nothing. |
| `requested_permissions` | Module-declared policy inputs, as in a package manifest (PM §4): names unique, `constraints` one deterministic-CBOR value. They grant nothing. |
| `state_assignment` | The instance's state assignment id, `[A-Za-z0-9._-]`; no two instances share one (RUNTIME §8 l.1383). |
| `configuration` | The module's configuration declaration (CONFIG §2): one deterministic-CBOR `logos.module_configuration.configuration_declaration`, its schema binding and an optional package default. See *Module configuration* below. |
| `provisioned_configuration` | This instance's protected configuration value (CONFIG l.142; DECISIONS G141): one complete value of the binding's root, at most 8 MiB. It needs `configuration`. |


### `ordering`

Lifecycle-ordering constraints (RUNTIME §3.7): a `dependent` starts only once its `prerequisite` is
`ready`. Both must be listed instances; a constraint may not name one instance twice, and the
constraints may not form a cycle. A start or recovery of a dependent whose prerequisite is not `ready`
returns `LOGOS_ERR_NOT_READY`. When the prerequisite is not in an accepted start either (it is
`unloaded`, `stopping` or `error`), an `unloaded` dependent reports `prerequisite-unavailable`
(RUNTIME l.3613), and the Runtime marks every `unloaded` dependent with `requested` intent so as soon
as a change leaves its prerequisite in that condition. A prerequisite in an accepted start (`loaded`)
makes the dependent wait without a failure. The classification stays until the dependent's next
accepted start or its explicit stop (DECISIONS G359, interim).

### `declarations`

What a module may create at run time with Runtime Control `create_module` (RUNTIME l.3480-3503;
DECISIONS G55): for each module name, the one accepted declaration, with the fields of a `modules`
entry except `instance`, `state_assignment` and `provisioned_configuration` (a provisioned value
belongs to one instance, never to a module name: RUN-0923). No two declarations name one module. A
`direct_static` declaration names a binding the host registers, or `start` returns
`LOGOS_ERR_INVALID_PARAMS`: a declaration is input for new instances, so it must be edited when a
build drops its binding, while a retained instance on that binding starts up mismatched (DECISIONS
G243 as changed). With `persistent_state: true` each created instance gets a fresh state
assignment of its own (`s-…`), which needs `state_root`.

- `create_module` for a module with no declaration is refused exactly as a denied request is
  (`LOGOS_ERR_NOT_AUTHORISED`), and creates nothing (DECISIONS G195, interim).
- A created instance is new each time: a fresh id (`m-…`), `unloaded`, intent `uninitialized`. It
  keeps the declaration it was created from. Changing a declaration in a later configuration changes
  later creations only (RUNTIME l.3490).
- The request key belongs to the requesting module: the same key and module give the same instance
  again, for as long as that instance is known (across restarts too); the same key with another
  module is `LOGOS_ERR_INVALID_PARAMS`. Retiring the instance frees the key.
- Creating grants nothing: the new instance is started with its own `start_module` authorization.

### `call_audit`

Call audit (CA §9, §9.1; DECISIONS I85): `call_records` is the capacity of the in-memory ring of call
records, 1 to 1000000, default 4096; `evidence` names the call-evidence signing key, a `kid` of 1 to
128 bytes and the absolute path of its secret key file. `evidence` needs `runtime.store_dir`, so the
evidence names the same Runtime across starts.

- **What is recorded.** Under `capability-authority`, a policy `allow` with `commitment`
  (`docs/AUTHORITY-POLICY.md`) makes each call it authorizes leave one `call` record after its
  outcome: the decision applied to that call, the consumer, the call scope and the retained request
  and response commitments, computed by the Runtime from the typed values (CA §9). The other policy
  kinds retain nothing, so they leave no records.
- **Retention.** The newest `call_records` records, in memory, the oldest dropped first, lost at
  exit; the authority's own audit is separate. An in-process host reads them with `auditRecords(rt)`,
  each with its index, which counts the records appended since `start`, from 0.
- **Keeping them elsewhere.** An in-process Nim host can also be handed each record as it is retained:
  `runtimeSetCallRecordSink(rt, sink, data)`, set before `start` (`LOGOS_ERR_NOT_READY` once a start was
  attempted; `LOGOS_ERR_INVALID_PARAMS` for a nil handle or sink), calls `sink(data, index, bytes)` on
  the thread that appended the record, after the ring holds it and outside the ring's lock. The sink
  must return at once and never call into the Runtime; `bytes` is valid during the call only. It has no
  C export (DECISIONS G304). logosd's call-evidence store is one (`docs/DAEMON.md` §9).
- **Marked payloads.** A `_sensitive` payload is never retained: a call whose decision would retain one
  is refused with `LOGOS_ERR_NOT_AUTHORISED` before dispatch (INTERFACE l.377). Write `commitment`
  rules that do not cover such methods, or that retain only their unmarked side.
- **Exporting evidence.** `exportCallEvidence(rt, index)` signs one retained record as a
  `logos.call-evidence.cose-sign1-slh-dsa-sha2-192s` container (CA §9.1): the complete record, no
  proofs, this Runtime's `runtime_instance_id` as producer. It is the protected export integration
  (CA l.1360-1372): calling it is the host's decision to disclose that complete record to whoever
  receives the container, and which records, how many and to whom are the host's to decide. A record
  no longer retained cannot be exported. A container is a signed statement, never authorization
  (CAP-0256). There is no C export yet.
- **The key.** `nim c -r tools/evidence_keygen.nim /abs/path/evidence.key` writes a fresh key (FIPS
  205 key generation): a new 96-byte file of the current user, mode 0600 before the key is written,
  never overwriting one; it prints the 48-byte public key in hex. `create` reads the key file: an
  absolute path to a regular file (not a symbolic link) owned by the process user with mode 0600,
  exactly 96 bytes, whose public half its seeds derive (owner and mode are not checked on Windows);
  otherwise `LOGOS_ERR_INVALID_PARAMS` with "call_audit.evidence: …". The key is held in memory until
  `destroy` overwrites it and is never logged. Use it for call evidence only, never as a package
  signing key (`lcn-pkg keygen` makes those), a TLS key or a key of another algorithm (CAP-0401).
- **Verifiers.** Give each verifier the `kid`, this Runtime's `runtime_instance_id` and the public key
  as protected trust input: a kid names one Runtime and one key, and two keys never share a kid
  (CAP-0226 to CAP-0229). In process, `verifyEvidence` with an `EvidenceContext`
  (`runtime/evidence.nim`) verifies a container.
- **Rotation.** Generate a key under a new `kid`, give verifiers the new mapping, change
  `call_audit.evidence` and restart. Containers already exported verify while a verifier keeps the
  old kid; revoking it there rejects all of them (CAP-0231).

### `routing`

Routing selection (RUNTIME §4.2 l.842-881; DECISIONS I90, G254): whether a route between two
modules of this Runtime is direct or uses local transport. Each rule names a `callee` (the provider's
module name), a `mode` (`direct` or `local-transport`), and optionally a `caller` (the consumer's module
name; absent: any consumer). For a route, the rule naming both its consumer and its provider wins, then
the rule for any consumer; with no matching rule the route is direct, as in every configuration without
`routing`, unless one of its ends runs in a Module Host: then it is `local-transport` (RUNTIME
l.2916; DECISIONS G272). The mode is fixed when the route is established: `renew_route` keeps it,
and routes already established are never moved (RUNTIME l.879).

- Events on a direct route (INTERFACE §2.5, §2.8; DECISIONS G176): a provider's `publish` runs each
  subscriber's handler on the publishing thread before it returns. When another thread is running a
  subscription's handler, the delivery is not waited for: a copy of the event is queued, and that
  thread runs the queued deliveries in publication order before it lets the subscription go, each
  decided afresh (a scoped event whose call has returned by then is not delivered). A handler that
  publishes into its own subscription while deliveries wait for it takes its place behind them: its
  publish runs them and then its own delivery before it returns. Each subscription
  queues at most 1,024 deliveries or 16 MiB of event data, whichever comes first (its first queued
  delivery is taken whatever its size); one more ends the subscription at once, so nothing published
  after it reaches the handler: its queue is discarded, the
  Runtime records the diagnostic "subscription *id* to *event* on route *route* ended: its delivery
  queue reached ...", and the handle reports the end with `LOGOS_ERR_MODULE` to the handler registered
  with `observe_subscription_end`, once, on an event worker (INTERFACE l.1469-1481). The bound limits
  the queue, not how long the thread that holds it spends running it: a publication that reaches a
  handler which itself publishes into busy handlers may run many deliveries before it returns.
- Two rules for the same `caller` and `callee` are refused, as is a rule naming the Module Loader
  (`logos_module_loader`) as caller or callee (every route to the Loader is refused, G251) and a rule
  whose callee is `logos_runtime_control`, which is not a provider.
- A `local-transport` rule whose callee is `logos_capability_authority` is allowed: an ordinary
  consumer's route to the authority is then served over a socket like any provider's. The Runtime's own
  policy evaluations stay direct.
- `local-transport` is refused on platforms without the `logos.local.unix-stream` profile (Windows,
  TRANSPORT §8.2.1).
- A `direct` rule naming, as callee or as caller, a module this file places `hosted_dynamic` is
  refused ("routing: the direct routing rule ... names ..., which is hosted_dynamic"): a direct route
  needs one address space. For a hosted instance no configuration named (a `create_module` one),
  `establish_route` under such a rule is `LOGOS_ERR_NOT_READY` with that reason (DECISIONS G272).
- A transported route to a provider has the Runtime serve that provider at an endpoint under
  `runtime.endpoint_dir`, created when the first such route to its realization is established; the
  provider's code still runs in the Runtime's process (DECISIONS G257). The consumer's
  `establish_route` and `renew_route` answers carry the route's `invocation` descriptor with a one-time
  ticket; no other answer, list, event, record or diagnostic does. A replay of the same request key
  returns the route without `invocation`: renew it for a new ticket (DECISIONS G255).
- When such a route ends, its unused tickets die with it, and its sessions end by cause (DECISIONS
  G260): a revocation or expiry answers each call in flight `NOT_AUTHORISED`, then the session closes
  with ProtocolError `NOT_AUTHORISED`; `close_route`, a provider stop or shutdown refuses new calls
  `NOT_READY`, lets calls in flight finish within `stop_deadline_ms` (or the shutdown grace), then
  closes with ProtocolError `NOT_READY` (TRANSPORT l.977). A consumer whose provider ends a session
  that way sees `NOT_READY` on its handle.
- A consumer's `materialize_route` on such a route connects to the endpoint with the route's ticket
  and returns once the provider holds the session. One ticket opens one handle: a further handle on the
  same route needs `renew_route` first, and a handle whose connection failed is not retried
  (DECISIONS G258). A handle whose connection is lost while its route lives gives `LOGOS_ERR_TRANSPORT`
  until it is released (G256); the route stays ready.
- Events through such a handle (DECISIONS I90, part 4b-2c): `subscribe` returns once the provider's
  Runtime activated the subscription, and a handler runs on one of the Runtime's event workers after
  its Event arrives, not on the publishing thread, one at a time per subscription and in the order
  the Events were published. A provider's `publish` returns once each subscriber connection has its
  Event, not once the handlers ran. What happens when a subscriber does not keep up, or an Event is
  too large for it, is under "Event output" below. A subscription the provider ends (its authority
  to receive ended) is reported once through the handle's `observe_subscription_end`, on an event
  worker, when a handler is registered at that moment; release of the handle suppresses a report not
  yet begun and waits for one that runs (DECISIONS G225).

#### Event output

A provider's publish callback returns only the publisher-side result: `LOGOS_OK` for an event its
own contracts declare with a payload of that event's type, `LOGOS_ERR_INVALID_PARAMS` otherwise,
decided before any subscriber is tried; a failure for one subscriber route does not change it
(INTERFACE §5.2 l.3351; RUNTIME §7.3 l.1148-1149; DECISIONS I106). So a transported subscriber that
cannot take an Event is handled at its connection (TRANSPORT §5.2 l.792-805, §2.1 l.382-385; RUNTIME
l.1150; DECISIONS D3 (a), G165, G261):

| Condition | Action |
|---|---|
| The Runtime's pending output, Response and Event payloads not yet written across all connections, is at `transport.max_pending_output_bytes` | The publishing thread waits until there is room, with no finite bound and no lock held. A payload larger than the whole budget passes once the budget is empty. |
| One subscriber connection's output is at `transport.conn_output_bytes` because its subscriber does not read: its handlers hold `transport.caller_undelivered_bytes` of Events undelivered, so its Runtime stops reading | That connection is closed with ProtocolError `TRANSPORT_ERROR`. Every subscription on it ends; the handle reports `LOGOS_ERR_TRANSPORT` and its route stays ready (renew it for a new handle). Other subscribers still get every Event. |
| An Event is larger than the subscriber's frame limit (`transport.frame_limit`) | Nothing of it is written there; that connection is closed with ProtocolError `TRANSPORT_ERROR`, as above. Other subscribers, direct or transported, get it. Through an invocation's scoped `publish`, which has a result, it is `LOGOS_ERR_MODULE` instead and the connection stays. |

No committed Event is discarded silently: an Event is either written to the connection or the
connection is closed.

### `transport`

The limits of the transport I/O thread (TRANSPORT §5.2, §8.6; DECISIONS I90), which runs only when a
`routing` rule selects `local-transport`. Every field is optional; an absent one keeps its default.

| Field | Meaning | Default |
|---|---|---|
| `frame_limit` | The largest frame this side accepts and the largest it assumes the peer accepts, in bytes; at least 16777216 (TRANSPORT l.371). Raising it raises the buffers below that must hold one maximal frame, unless they are given too. | 16777216 |
| `hello_timeout_ms` | How long a whole Hello exchange may take (1 to 3600000). | 10000 |
| `write_stall_timeout_ms` | How long a connection may have output pending with no byte written before it is closed (1 to 3600000). | 30000 |
| `max_pending_output_bytes` | Response and Event payload bytes submitted by provider code and not yet written, across all connections: a publisher past it waits (TRANSPORT §5.2). | 67108864 |
| `conn_output_bytes` | One connection's committed output, in bytes. | 2 × `frame_limit` + 65536 |
| `caller_undelivered_bytes` | Per connection, Event bytes received and not yet delivered to the subscriber. | 33554432 |
| `max_inbound` | Accepted connections, pending Hellos included. | 1024 |
| `max_outbound` | Outbound connections. | 1024 |
| `max_calls` | Per connection, calls a consumer may have outstanding. | 1024 |
| `max_in_flight` | Per connection, Requests a provider may be executing. | 1024 |

A value the I/O thread cannot run with is refused with `LOGOS_ERR_INVALID_PARAMS` and "transport: …"
naming the limit. The payload depth is `runtime.max_payload_depth`; there is no separate one.

### `state_transfers`

A replacement instance's state, taken from the instance it replaces at the next `start` (DECISIONS
G92 as re-decided 2026-11-15, I96, G306; RUNTIME l.3411-3418). Each entry is one authorization,
applied once; below, "State transfer to a replacement instance", says what happens. Optional; when
present, not empty, and only with `store_dir` and `state_root`.

| Field | Meaning |
|---|---|
| `from` | The instance replaced: one the store knows, running or retired, and not listed in `modules` (RUNTIME l.3446). |
| `to` | The replacement: listed in `modules` with its own `state_assignment`, and new to the store. |
| `mode` | `move` (the source's directory becomes the replacement's) or `copy` (the replacement gets a copy and the source's directory stays as it was; not on Windows). Required: there is no default. |
| `max_bytes` | `copy` only: the most the copied tree's files may hold, 1 to 2^40; 1 GiB when absent. |

An instance is the `from` of one entry at most and the `to` of one entry at most. Neither side may be
the Module Loader's instance, a Runtime-assigned name, or the Capability Authority instance. Anything
else is refused at `create` with `LOGOS_ERR_INVALID_PARAMS` and "state_transfers: …".

### `package_manager`

The instance that holds the Package Manager responsibility (RUNTIME l.293; DECISIONS G490), named
as `orchestration` and `policy.authority` name theirs. Optional. It must be a listed instance of the
module `logos_package_manager`, `hosted_dynamic` with placement `process` (a direct one would share
the Runtime's process, PKG-0006), and neither the orchestration nor the authority instance; otherwise
`create` refuses with "package_manager names no instance in modules", "package_manager's module is
not logos_package_manager", "package_manager must be a hosted_dynamic instance with placement
process", or "package_manager names the orchestration instance" / "… the authority instance".

The mark is the only way a hosted module gets the reserved `logos_` prefix: the Runtime tells that
instance's Module Host (the carrier's `init` has `system: true`), the host accepts its name and the
`logos.` rules of its contracts, and the Runtime completes its probe as a system binding, which
accepts the reserved call surface. Without the mark a hosted module with a reserved name is refused
by its host, as before. logosd writes the mark for the instance it composes ([DAEMON.md](DAEMON.md)
§3, "The derived host configuration").

### `artifact_adoption`

The instances whose retained record may take a new artifact hash at a `start` (DECISIONS G505).
Optional; when present, not empty. Each id is listed once and names a `direct_dynamic` or
`hosted_dynamic` instance in `modules` that is neither the orchestration nor the authority
instance; otherwise `create` refuses with "artifact_adoption is present but empty", "artifact_adoption
names … twice", "… which is not in modules", "… which is not a dynamic instance", or
"artifact_adoption names the orchestration instance" / "… the authority instance".

Listing an instance is the host's assertion that a new library under the same artifact id keeps that
instance's state, grants and settings: any embedding host may make it, not only logosd. At `start`,
a listed instance whose retained declaration differs from the configured one only in the artifact's
`hash` keeps its id, state assignment, state, settings and grants; its record takes the new hash
(and, as for any instance, the configured `local_path` and permission reasons) in one durable write
before anything runs, and a diagnostic names the instance, the artifact id and both digests. The
Module Loader then checks the bytes against the new hash at each realization, as for any artifact.
Every other fact still has to be equal: a changed artifact id, `hash_suite`, strategy, placement,
contract, `requires`, permission or configuration declaration is refused as for an unlisted instance
("Persistent Runtime state", below), with "the configured artifact id is …, the retained one …" or
"… this session cannot be upgraded in place (G505)". logosd lists the instances it composes itself,
`lcn_call` and `package_manager`, and never an operator's ([DAEMON.md](DAEMON.md) §3).

### `protected_inputs`

Protected construction input for one instance (DECISIONS G400; RUNTIME l.1600-1601): bytes only the
embedding host sets, which the instance reads at its initialization. logosd uses it to hand the
Package Manager its `lcn.pm_input` ([DAEMON.md](DAEMON.md) §3). Optional; when present, not empty.

| Field | Meaning |
|---|---|
| `instance` | An instance listed in `modules`, with a `state_assignment`. At most one entry per instance. |
| `input` | 1 byte to 16 MiB, passed as they are. |

At each realization attempt the Module Loader writes `input` to `<state_dir>/.lcn-protected-input`
(below, "The Module Loader"); the module reads it during `_MODULE_init`. It is not configuration: no
Runtime Control method reads, replaces or applies it, `create_module` cannot carry it, and it is never
in a record, an error, a log line, an event or a carrier frame. A refused entry is `LOGOS_ERR_INVALID_PARAMS`
at `create`, with "protected_inputs: <instance> is not listed in modules", "… has no
state_assignment" or "… has two entries"; the message names the instance, never the bytes.

**Not for secrets.** The bytes pass through a file in the instance's state directory, which backups
and state copies may read while it exists, and which any process of the Runtime's user can read or
replace. Use it for input that must not be changed by a module or a Runtime Control caller, not for
input that must stay unread.

## Module configuration

A module that takes configuration declares it (CONFIG; DECISIONS I87): in `configuration`, a schema
binding (`document`, a supporting CDDL schema of at most 1 MiB; `root`, a type it declares; the
`schema_commitment` of both; and `live_reconfiguration`, present and `true` only for a module that
can apply a new value while it runs) and, optionally, a package `default_value`.

- **Acceptance at `create`.** The schema is accepted on its own against the pinned common schema
  (nothing is fetched or read), its root must be a type it declares, and both roots of the declared
  commitment are computed again and must match. The default and the provisioned value must each be a
  complete value of the root. Any failure is `LOGOS_ERR_INVALID_PARAMS` naming the module instance
  or declaration (RUN-0741). Generate the declaration with `lcn-gen` from the module's
  configuration schema rather than by hand: the commitment is data computed from the text.
- **The first value.** A new instance starts at state revision 1 with the provisioned value staged
  (`protected-provisioning`), else the default staged (`package-default`; app-config v1 accepts
  package defaults), else at revision 0 with nothing: such a module cannot start until a value is
  staged through Runtime Control `update_configuration`. Its first start promotes the staged value to
  current.
- **Starting without a value.** `start_module`, `recover_module`, and the bootstrap start of the
  orchestration instance, need an eligible value. Without one the start is `LOGOS_ERR_NOT_READY`, the
  instance reports `configuration-missing` (`unloaded`, or `error` whose cause it replaces; RUNTIME
  l.3611-3613), the intent stays `requested`, nothing runs, and a later update does not start the
  module. The reference orchestration module probes it and resumes it once a value is eligible (RUNTIME
  l.3665; DECISIONS G162, settled); a host without it starts it again. For the orchestration instance,
  `start` returns `LOGOS_ERR_MODULE` at once: a startup failure other than one before `ready`
  (RUNTIME l.3955).
- **Replacing the provisioned value.** On each `start` with a `store_dir`, a provisioned value whose
  value root differs from the last one accepted for that instance is staged again as
  `protected-provisioning`; an equal one is not. Removing `provisioned_configuration` leaves the last
  accepted root as it is, so adding the same value back later stages nothing. To force a value back,
  stage it through Runtime Control. A staged value takes effect at the module's next start or live
  apply. Provisioning is per instance and is not turned off by anything else in this format
  (DECISIONS G141).
- **A changed declaration.** The binding is fixed for an instance's life (CONFIG §7): a retained
  instance whose configured declaration differs from its stored one, live flag included, makes
  `start` return `LOGOS_ERR_INVALID_PARAMS` naming it, before anything runs. Give the module a new
  instance id.
- **Applying a staged value live.** For a module whose binding declares `live_reconfiguration`,
  Runtime Control `apply_configuration` hands the staged value to the running module's
  `_MODULE_apply_configuration` while it stays `ready`. The call returns once the module has answered:
  on success the value is current; a refusal changes nothing and the call succeeds with the
  `configuration-rejected` error arm (logosctl exits 4 naming it). If the module
  gives no valid answer within `apply_deadline_ms` (above; 120 s by default), its configuration is
  unknown: the call returns `LOGOS_ERR_MODULE` and the instance enters `error` with
  `configuration-indeterminate`, and is released once the module's hook returns. Start it again to
  continue; the staged value is still there. A stop or shutdown during an application waits for the
  module's answer; if the deadline passes during a stop, the instance stays `stopping`, only the caller
  gets `LOGOS_ERR_MODULE`, and the stop goes on (CONFIG l.328-329). One application runs per instance
  at a time.
- **Size.** A state whose maximal `get_configuration` response would not fit a 16 MiB frame is refused
  and nothing changes: two values near 8 MiB cannot both be kept. Through Runtime Control it is
  `LOGOS_ERR_INVALID_PARAMS` without detail (CONFIG l.198); a provisioned value at creation or at a
  host start is `LOGOS_ERR_MODULE` (DECISIONS G233). The state revision never wraps; one step is kept
  free while a start's or an application's promotion is pending (RUNTIME l.1812; DECISIONS G234).
- **Persistence.** Each configurable instance's binding and state are kept in their own record in
  `store_dir` (below), written before any change is visible. A configuration write that fails is
  `LOGOS_ERR_MODULE` and changes nothing; at a start, the attempt fails with `other`.
- **What a value must not hold.** Configuration is not a channel for authority or secrets
  (CONFIG §1): no requested permissions, grants, authority state, credentials or protected trust
  input. The Runtime checks a value's shape, never its meaning, so this rule is the module author's
  and the deployer's. Credentials and keys a module needs live in its state directory (DECISIONS
  D21); authority comes from the `capability-authority` policy.
- **Package defaults and reset.** This format accepts package defaults: a declaration's
  `default_value` is staged for a new instance that has no provisioned value. No Runtime Control
  method returns the default. An application that offers a reset takes the default from the same
  declaration the host configured (the package's own), checks that its `schema_commitment` is the one
  `get_configuration_schema` reports for the instance, and stages it with `update_configuration`; the
  Runtime validates it as a complete value under the accepted schema before it changes anything, and
  the value takes effect at the next start or live apply.
- **Keeping a configuration across an upgrade.** The binding is fixed for an instance, so an upgrade
  that keeps the configuration is a new instance id (CONFIG §7). The workflow is: read the old
  instance's value with Runtime Control `get_configuration`; turn it into a complete value under the
  new instance's schema outside Core (Core never transforms a value); then either provision it for
  the new instance (`provisioned_configuration`) or stage it with `update_configuration` before the
  new instance's first start. Retire the old instance afterwards. To keep its module state too, give
  the new instance a `state_transfers` entry, which retires the old one ("State transfer to a
  replacement instance", below).

## What the host can expect

- **Runtime identity.** Without `store_dir`, each `logos_runtime_start` gives the Runtime a fresh
  lowercase UUIDv4 as its `runtime_instance_id`. With `store_dir`, the identity is
  `runtime_instance_id` if given, or a UUIDv4 generated when the store is created, kept with the
  store. The Runtime generates the id only because this protected configuration permits it, and
  choosing this format, or a store without `runtime_instance_id`, is the host's acceptance (RUNTIME
  l.2587; DECISIONS G192, settled). The Host Embedding API discloses no generated id (l.2588).
- **What `start` waits for.** `start` returns once the Module Loader is bound and then the
  orchestration instance is `ready` (RUNTIME l.3838; "The Module Loader"). Other modules need not be
  ready (RUNTIME l.3837), and their later failures do not affect it. `start` decides its
  result once (l.3940) and only from what happens in this start, never from a failure a store kept:
  - `LOGOS_ERR_CANCELLED` if a Runtime Control `shutdown_runtime` was accepted first (RUN-0759);
  - `LOGOS_ERR_TIMEOUT` if the orchestration instance's startup deadline, or the Module Loader's,
    passed (l.3939, l.3955);
  - `LOGOS_ERR_NOT_AUTHORISED` if starting the orchestration instance is denied, its evaluation
    fails, or its permission settings refuse it (l.3955);
  - `LOGOS_ERR_NOT_READY` if its start is refused at once without a failure being recorded: a held
    restart lock, permission settings still being reconciled, or a prerequisite in the ordering
    that is not ready while the instance is `error` (l.3955);
  - `LOGOS_ERR_MODULE` for any other failure, a missing configuration value or a static binding
    mismatch included, with the failure classification in the message (l.3939, l.3955).

  A failed `start` stops and destroys nothing: request shutdown, wait for it, then destroy (RUNTIME
  l.3942, l.3945).
- **The host cannot interrupt `start`.** Only `request_shutdown` and `wait_for_shutdown` may overlap
  on one handle (RUNTIME l.3949), so a host serializes `start` against both. What bounds `start` is
  the Module Loader's startup deadline, then the orchestration instance's. (A `request_shutdown` that overlaps anyway is accepted and `start` returns
  `LOGOS_ERR_CANCELLED`.)
- **Startup defaults belong to the orchestration module.** It applies them only while an instance's
  intent is `uninitialized`, by a conditional `start_module` carrying the `expected_execution_revision`
  that `get_readiness` reports (RUNTIME l.185). It should do so after its `_MODULE_init` returns:
  starting other modules from inside its own init spends its startup deadline on each of them, so one
  slow module could fail `start`. The orchestration instance's own intent is `requested` once the
  bootstrap starts it (DECISIONS G191, interim).
- **Shutdown.** `logos_runtime_request_shutdown` accepts and returns; `logos_runtime_wait_for_shutdown`
  returns `LOGOS_OK`, or `LOGOS_ERR_MODULE` when some realization's cleanup was unresolved or failed
  (DECISIONS G60). Execution intent is kept (RUNTIME §10.2).
- **Static bindings.** `logos_runtime_register_binding` copies the table, so its memory is the host's
  again when the call returns; the code at those addresses must stay loaded, with the signatures
  INTERFACE requires, until `logos_runtime_destroy` succeeds (RUNTIME l.3908, l.3919-3923).
  Registration is closed by the first `start`, even one that fails, and by a shutdown request. A
  binding that no module names is kept, unused, until `destroy`. A new configured instance and every
  declaration must name a registered binding, or `start` returns `LOGOS_ERR_INVALID_PARAMS` before
  anything runs; a retained instance whose binding is gone starts up mismatched ("Instances and the
  configuration", below).
- **Calls on one handle.** The host serializes every call on a handle except `request_shutdown` and
  `wait_for_shutdown`, and never overlaps `destroy` with another call (RUNTIME l.3848, l.3949).
  `wait_for_shutdown` from a module callback or a Runtime thread returns `LOGOS_ERR_NOT_READY`
  instead of blocking (RUNTIME l.3950 forbids it; the check is ours).
- **Destruction.** `destroy` succeeds before the first `start`, or once shutdown completed and no
  module code is still running on a Runtime thread; otherwise it returns `LOGOS_ERR_NOT_READY` and
  the handle stays valid, so the host retries. After a `start` that failed, shutdown is requested
  and waited for first.
- **Signals** (DECISIONS G340). Loading `liblogos_runtime` leaves every signal disposition of the host
  as it was. The library is built with `-d:noSignalHandler`, so its Nim runtime installs no handler
  for SIGINT, SIGSEGV, SIGABRT, SIGFPE, SIGILL, SIGBUS or SIGPIPE; a crash inside it is the host's to
  report. The transport code (chronos 4.4.1, `asyncengine.globalInit`) sets `SIGPIPE` to ignored in its
  module initializer; the library records the disposition before that and puts it back at the end of
  its load-time constructor. The Runtime's own socket writes never raise `SIGPIPE` (`MSG_NOSIGNAL`,
  `SO_NOSIGPIPE`), so it does not need the signal ignored. logosd and the Module Host are programs and
  set their own dispositions (`docs/DAEMON.md` §13; below).
- **Threads.** With a `local-transport` rule, or with `runtime.module_host` set, the Runtime starts
  one more thread at `start`, the transport I/O thread, and stops it at `destroy`. Without either, no
  such thread exists.
- **Remote listeners and provider exports** (DECISIONS G298, K19's interim). This Runtime has no
  remote transport, so no listener, export or enrollment exists. Each of the four methods is
  authorized first (`LOGOS_ERR_NOT_AUTHORISED` when the decision denies); then
  `list_remote_listeners` and `list_provider_exports` answer an empty page (a cursor is
  `LOGOS_ERR_INVALID_PARAMS`, none having been issued), `set_provider_export` is
  `LOGOS_ERR_INVALID_PARAMS` (it names no listener record), and `set_remote_listener` that enables a
  listener is `LOGOS_ERR_MODULE`, "remote transport is not supported by this Runtime". One that
  disables a listener assigns the state every listener has by default (RUNTIME l.2769): it succeeds
  with the requested record. This Runtime keeps a listener record only for a state other than the
  default, so the lists stay empty, an export naming that listener still finds no record, and no
  `inventory_changed` hint is sent.
- **Results.** A result's message and detail stay in the calling thread's storage until that
  thread's next call into the library, or until the thread exits (our reading where RUNTIME l.3953
  is silent); `LOGOS_OK` carries neither.
- **Test hooks** (DECISIONS D27). The library has none: `build_runtime_lib` builds it without
  `lcnTestHooks`, and none of its six functions selects a hook. A Nim host built with the define
  selects one by an in-process call ([CONFORMANCE.md](CONFORMANCE.md), "Test hooks"); that call is its
  Runtime's protected input, and a host that makes it is a non-production deployment and owes the
  designation of BCP l.404 in its documentation and its operator-facing diagnostics.

## Orchestration duties

RUNTIME l.66 defines a Runtime instance as the Runtime engine plus an orchestration module, and a
RUNTIME claim covers both (BCP l.286). RUNTIME is claimed for the engine with the reference
orchestration module, `lcn_orchestrator`, wherever a host names it (logosd does: docs/DAEMON.md §4;
"The reference orchestration module" below; DECISIONS I94, docs/CONFORMANCE.md "Claims"). A host
that names another module in `orchestration` claims jointly with that module, which carries these
duties itself; the engine does not do them for it:

- **Startup defaults** (RUNTIME l.185). Apply deployment startup defaults only while an instance's
  intent is `uninitialized`, by conditional `start_module` or `stop_module` requests carrying the
  `expected_execution_revision` that `get_readiness` reports.
- **Reconciliation** (l.3631-3633). When it becomes operational, including after a Runtime restart,
  reconcile the retained `requested` intents and schedule the recoveries active policy permits,
  preserving retained origin, retry accounting, lifecycle ordering, current authority and unresolved
  cleanup obligations. The engine resumes nothing on its own ("Persistent Runtime state",
  Resumption).
- **Restart policy** (l.3648-3652). Evaluate the active restart policy and schedule permitted
  recovery through `recover_module`. Disabling automatic restart is a valid policy; an enabled policy
  bounds retry frequency, and its retry accounting survives an orchestration restart and lost
  responses (a lost `recover_module` answer is settled by reading `get_readiness`). An explicit stop
  or a shutdown cancels pending automatic recovery; the engine refuses a recovery prepared before
  either, by the revision guard.
- **Resumption after a permission or authority stop** (l.3663-3666, l.2526-2527). When required
  permissions or authority become available again, request resumption of the retained intent through
  `recover_module`; a failed resumption is subject to the restart policy. A permission settings
  replacement stops a running instance with no failure classification: the settings' `applied`
  (`permission_settings_changed_event`) is the moment to recover it, and its recovery is decided for
  the retained origin with the new settings.
- **Failure classifications** (l.3610). Treat a classification it does not recognize as an
  unspecified failure, and never derive a restart policy from its spelling.

Stopping or failure of the orchestration module pauses automatic startup and recovery (l.3668).

## The reference orchestration module

`lcn_orchestrator` (`src/logos_core/orchestration/`; DECISIONS I94) is a consumer-only module, linked
into the host, that carries the duties above. Holding the role is the host configuration's doing: its
name confers nothing (RUNTIME l.180-183, DECISIONS G53). It calls only through the Runtime Control
binding it receives at initialization (l.175), never the Module Loader, and runs one thread of its
own per instance.

- **Registration.** The host registers the static binding `lcn_orchestrator` with
  `logos_runtime_register_binding` (in Nim: `orchestratorStaticSymbols()`), and lists one instance:
  `{instance, module: "lcn_orchestrator", implementation: {strategy: "direct_static", binding:
  "lcn_orchestrator"}, state_assignment, configuration, provisioned_configuration}`, with
  `orchestration` naming that instance. `configuration` is the module's declaration
  (`orchestratorDeclaration()`: the schema below, with the package default as its `default_value`);
  `provisioned_configuration` is the deployment's value (`encodeSettings`), and without one the
  package default applies. The value is read only at the module's start (`_MODULE_init`); a change
  takes effect at the next start. With `ordering` in its value, give the host configuration's
  `ordering` the same pairs (DECISIONS G287).
- **Schema** (`src/logos_core/orchestration/config.cddl`):

```cddl
; lcn_orchestrator configuration (DECISIONS I94): the reference orchestration
; module's start list, lifecycle ordering and restart policy (RUNTIME l.183,
; l.194, l.746-751, l.3786-3790). A supporting schema, resolved against itself
; and the common schema only.

lcn_orchestrator.config = {
  ? authority: lcn_orchestrator.target,
  ? defaults: [* lcn_orchestrator.default],
  ? ordering: [* lcn_orchestrator.order],
  ? restart: lcn_orchestrator.restart,
  ? overrides: [* lcn_orchestrator.override],
  ? resync_ms: uint32,
}

lcn_orchestrator.instance = tstr .size (1..128)
lcn_orchestrator.module = tstr .size (1..64)

lcn_orchestrator.target = {
  module: lcn_orchestrator.module,
  instance: lcn_orchestrator.instance,
}

lcn_orchestrator.default = {
  module: lcn_orchestrator.module,
  instance: lcn_orchestrator.instance,
  ? action: "start" / "stop",
}

lcn_orchestrator.order = {
  dependent: lcn_orchestrator.instance,
  prerequisite: lcn_orchestrator.instance,
}

lcn_orchestrator.restart =
  { kind: "disabled" } /
  {
    kind: "backoff",
    initial_delay_ms: uint32,
    max_delay_ms: uint32,
    multiplier: uint32,
    ? max_attempts: uint32,
    stable_ms: uint32,
  }

lcn_orchestrator.override = {
  instance: lcn_orchestrator.instance,
  restart: lcn_orchestrator.restart,
}
```

- **Fields.** Every array is a set of distinct entries; an instance id is 1 to 128 bytes, a module name
  1 to 64.
  - `authority`: the Capability Authority instance under `capability-authority`, which the module
    starts itself under the derived rules ("Under `capability-authority`") before anything else. Not
    the module's own instance, and not the Module Loader.
  - `defaults` (at most 4096): startup defaults, `start` when `action` is absent. Applied only while
    the instance's intent is `uninitialized`, by a conditional request carrying the revision it just
    read (RUNTIME l.185, l.2156, l.2172): an operator's `stop` between the read and the request wins
    (`LOGOS_ERR_INVALID_PARAMS`, and the module reads again). A default that contradicts `authority`
    is refused. An instance not listed is never started by the module.
  - `ordering` (at most 16384 pairs): a dependent's start, by default or by recovery, is issued only
    once every prerequisite is `ready` (DECISIONS G287); no cycle, no self-pair, no duplicate.
  - `restart`: `disabled`, or `backoff` with `initial_delay_ms` (1 to 3,600,000), `max_delay_ms`
    (`initial_delay_ms` to 86,400,000), `multiplier` (1 to 16), `max_attempts` (1 to 1,000,000; absent:
    no limit) and `stable_ms` (0 to 86,400,000). An episode's first recovery comes `initial_delay_ms`
    after the failure was seen; after its *k*-th the next waits `min(initial × multiplier^(k−1),
    max)`. Absent: the package default, 1 s doubling to 60 s, 8 attempts, stable after 60 s.
  - `overrides` (at most 4096): a `restart` for one instance.
  - `resync_ms` (10 to 3,600,000; default 30,000): the full re-read (below).
  An invalid value fails the module's start with `LOGOS_ERR_MODULE`, and the diagnostic says which
  field.
- **What it decides from.** Each instance's lifecycle state and intent, read with `list_modules` and
  `get_readiness`. From a failure classification it reads only whether it is one of six that make an
  `error` a resumption, not a live failure (RUNTIME l.3632, l.3663-3666; DECISIONS G291 as amended):
  `cleanup-timeout` (an enforcement stop overran its deadline, in a record an earlier build stored: an
  overrun now stays `stopping` and completes `unloaded`, RUNTIME l.575-576),
  `permission-enforcement-failed`, `authority-denied` and `authority-evaluation-failed` (a start or
  recovery the permission settings refused or the authority denied), `configuration-missing` and
  `static-binding-mismatch` (a start or recovery refused for want of configuration or for a static
  binding mismatch, which replaces an `error` instance's cause; RUNTIME l.3611-3613). The engine sets
  the last five only for such refusals and denials, settings that failed, and stops for authority,
  never for a failure of an accepted attempt. A static binding mismatch cannot end within a run, so its
  probes are refused, changing nothing, until the next `start`. Every other classification, known or not, is a live failure, and no
  restart policy is derived from its spelling (RUNTIME l.3610). Its own instance and the Module
  Loader are always left out; every other instance with `requested` intent is the module's, whoever
  its origin is, and keeps that origin (l.3631).
- **Events are hints.** It subscribes to the module-state, execution-state, inventory,
  configuration-state and permission-settings events and re-reads what they name before it decides
  (l.3285). Every
  `resync_ms` it subscribes anew, drops the subscriptions made the time before and re-reads every
  instance (l.3286; DECISIONS G225), so a lost event delays a decision by at most that long. It
  keeps each generation of subscriptions for one more interval, because dropping a subscription
  discards the events still queued for it (DECISIONS I94). A full ring of hints, or an inventory
  event, makes it re-read everything at once, without subscribing anew.
- **Recovery and its accounting** (l.3648-3652). A failure seen while the module runs (`error` with
  `requested` intent) starts an episode: recoveries on the backoff, each charged, up to
  `max_attempts`, then the diagnostic "restart attempts exhausted after *n* of *m*" and no more. The
  episode closes once the instance has been `ready` for `stable_ms`, or when its intent changes (a
  stop, a new start). A refused recovery is not an attempt (the next is still spaced); a recovery whose
  answer never arrived is one, counted once, and the module reads before it decides again. Under
  `disabled` a failure is never recovered, and the diagnostic says so once.
- **Resumption is not a retry** (l.3632; DECISIONS G289, amending G193). The module's first decision
  on an instance after it starts resumes it once, uncharged, when it finds it `unloaded`, or `error`
  with no open episode: after a Runtime restart, clean or not, or after a failure while the
  orchestration module was down. An episode still open continues charged, across any restart. Under
  `disabled` every `requested` instance in `error`, the authority included, is resumed once after the
  module starts, and not again.
- **Probes** (l.3663-3666; DECISIONS G288). An instance with `requested` intent that is `unloaded`
  (its start was refused for authority or by its permission settings, a settings replacement stopped
  it, a configuration is missing, or a prerequisite was not ready) or `error` with one of the six
  classifications above (an enforcement stop that overran its deadline, then perhaps a probe refused
  or denied, G291), and a start or stop default that was refused, is retried by uncharged probes on the policy's spacing (`delay(n)` after the last probe;
  the package default's under `disabled`), never exhausted. The authority's return to `ready`, and a
  `configuration_state_changed` or `permission_settings_changed` event for the instance, bring the
  next probe forward, never closer than `initial_delay_ms` after the last.
- **When permissions become available** (l.3665-3666; DECISIONS G288, G284). The module never learns
  the moment from the permission profile or the authority; the settings event is its hint. An instance
  a settings replacement stopped is recovered once its settings settle `applied`; one whose start or
  recovery the settings refused (`LOGOS_ERR_NOT_AUTHORISED`, `authority-denied`: they lack
  host-ambient) is recovered once a replacement gives it back, a startup default that was refused
  included, since the refused start already made its intent `requested`. Each probe is decided for the
  instance's retained origin with its current settings, so a probe made while they still lack what it
  needs is refused again and costs nothing. When a reconciliation stop overruns its deadline the
  settings are `failed` and the instance `error`: its probes are refused
  (`permission-enforcement-failed`) until, once the late cleanup has ended, an accepted replacement
  applies, and then it is resumed, under `disabled` too. A refused probe is not a failed resumption. A
  resumption the Runtime accepts and that then fails is an execution failure: under `backoff` it opens
  an episode, charged; under `disabled` it is not retried (l.3666). An explicit stop ends the probes.
- **Under `capability-authority`.** With `authority` set, the module first brings the authority up
  under the derived rules (polling it from 100 ms, doubling to 5 s), then waits for the binding, which
  it infers from the first `list_modules` that succeeds (probing from 50 ms, doubling to 2 s;
  DECISIONS G290), then subscribes and reconciles. If `list_modules` is refused later, the binding was
  lost: with `recovery: true` it brings the authority back the same way, and the instances the loss
  stopped are then resumed by probes, intent and origin kept. It never routes to the authority's
  `watch_changes`.
- **The state file.** The retry accounting is `orchestrator-state.cbor` in the module's state
  directory (format `logos-core-nim.orchestrator-state.v1`, at most 1 MiB, at most 4096 open episodes),
  locked while the instance runs. Each charged recovery is written before it is made; a write that
  fails makes no call. Under any enabled policy a state directory is required: without
  `state_assignment` the start fails with `LOGOS_ERR_MODULE`. A file that cannot be read fails the
  start too, and is left as it is: the diagnostic names it; removing it starts again with no open
  episode. A file another Runtime instance wrote is discarded.
- **What it never does.** It never sequences or requests a shutdown (DECISIONS G292): logosd's signals
  use the Host API, and `shutdown_runtime` is the one defined means. At shutdown it cancels the calls
  it has in flight and calls nothing more. It never stops an instance except by a `stop` default, and
  has no list of excluded instances.
- **Diagnostics.** Lines start with `lcn_orchestrator:` and go where the host points them
  (`setOrchestratorDiagnostics` in Nim): each recovery and its attempt, each answer, a refused or
  invalid value, a failed start's reason, exhausted attempts. Repeated conditions are written at most
  every 30 s.
- **What its instance needs from the policy** (`orchestratorNeeds`). `list_modules`,
  `get_readiness` and `recover_module` on every instance, the five events above, and `start_module`
  or `stop_module` with the module as origin for the authority and each default, with those
  instances' execution. `get_self` needs nothing (RUNTIME l.2483).
- **Limits.**
  | Limit | Value |
  |---|---|
  | lifecycle calls in flight | 16, one per instance |
  | hints waiting for the module's thread | 64 events of at most 1 KiB; past either, a full re-read |
  | instances per `list_modules` page | 256 |
  | open episodes | 4096; past it no new one is opened, with a diagnostic |
  | the state file | 1 MiB |
  | authority bring-up polls | 100 ms doubling to 5 s |
  | binding probes | 50 ms doubling to 2 s |
  | a repeated diagnostic | once per 30 s |

## The Module Loader

Every module instance but one is realized and released through a Module Loader that the Runtime
binds as a system service (RUNTIME l.1548-1583; DECISIONS I89). The Loader is the module
`logos_module_loader`, built into the library as a `direct_static` binding. It advertises the two
direct strategies, and `hosted_dynamic` with the `process` placement when `runtime.module_host` is set
(LOADER §4; DECISIONS G264). It never advertises `force_release`. A strategy or placement it does not
advertise is refused with `unsupported-strategy` before any artifact is read (LOADER l.377).

- **Built in, never configured** (BCP l.292; DECISIONS G246, G253). The Runtime's construction
  always establishes, authorizes and binds the Loader, before anything else. Its instance id, module
  name and static binding are all `logos_module_loader`, and they are reserved: a `modules` entry,
  a declaration or `orchestration` that names them makes `create` return `LOGOS_ERR_INVALID_PARAMS`, and so does
  `logos_runtime_register_binding` with that binding id. No configuration, registration or module can
  replace or configure the Loader. The policy is not asked about it: no execution decision and no
  `execute` check is made for it (CAPABILITY AUTHORITY l.339). Its permission settings are its
  construction's: with a profile selected, the profile's minimum (host-ambient), revision 1,
  `applied`, written before the Loader is first exposed; an `update_permission_settings` aimed at it
  is `LOGOS_ERR_NOT_READY` (DECISIONS G253, I93). Without a profile they are the constant form every
  instance has.
- **Established first at `start`.** `start` realizes the Loader, checks that its primary contract is
  the pinned Module Loader contract and binds it, and only then realizes the orchestration instance
  through it. A Loader that cannot be established makes `start` return `LOGOS_ERR_MODULE` "the Module
  Loader cannot start: …", after whatever it started has been released.
- **Its own startup deadline** (RUNTIME l.628; DECISIONS G61, amended 2026-11-14). The Loader's start
  has a deadline of its own: 120 s, which `startup_deadline_ms` does not change, and which this format
  has no field for.
  - It starts when `start` begins.
  - It covers the Loader's binding, its `_MODULE_init` and readiness checks through `ready`, and the
    binding checks that follow: the pinned contract, then a `list_capabilities` call that must name a
    strategy.
  - When it passes in any of these phases, the Loader's record is `error` with `startup-timeout`, and
    the Loader never becomes `ready` or bound. Nothing is destroyed while its `_MODULE_init` still runs,
    and a call already inside it returns first. Then `start` returns `LOGOS_ERR_MODULE` "the Module
    Loader cannot start: startup-timeout: the startup deadline passed".
  - Only a new Runtime tries again.
- **Its own lifecycle** (DECISIONS G246). `stop_module` of the Loader is `LOGOS_ERR_NOT_READY` while
  it owns a realization; owning none, it stops, and every later start of any instance is
  `LOGOS_ERR_NOT_READY`. `recover_module` and `retire_module` of the Loader are `LOGOS_ERR_NOT_READY`.
  Every route to it is `LOGOS_ERR_NOT_AUTHORISED`, and the Loader serves only the Runtime's own call
  (DECISIONS G251), so no module can call it.
- **Answers that are lost** (DECISIONS G252). When a `realize` or `release` call fails or its answer
  is lost, the Runtime asks the Loader's `get_status` whether the realization exists, and releases it
  or completes the stop accordingly. If that answer is lost too, the instance becomes `error`
  (`other`, "the Module Loader's answer was lost and could not be resolved") with its realization
  `unknown`; a stop of it is accepted. An answer that breaks the contract is diagnosed and taken as a
  failed call: the Loader stays `ready` (RUNTIME l.3687; DECISIONS G360).
- **Loader loss** (RUNTIME l.3675-3689; DECISIONS G249, G360). When the Loader fails (its instance
  leaves `ready` because its realization ended or failed, or an authority ending reaches it while it
  owns a realization), every instance it realized becomes `error` with the classification
  `other` and the reason "its Module Loader failed", its realization `unknown` and its routes failed;
  execution intent is kept, and a `stop_module` of such an instance is accepted (intent cancelled,
  still `error`). Nothing starts again in this Runtime: every start and recovery is
  `LOGOS_ERR_NOT_READY`. The Runtime cannot release what the failed Loader owns, so when it owned
  anything **the host must end its process**: the Runtime writes a diagnostic "termination
  required…", `logos_runtime_wait_for_shutdown` returns `LOGOS_ERR_MODULE` with a message ending "the
  Module Loader failed: the host process must end", and `logos_runtime_destroy` returns
  `LOGOS_ERR_NOT_READY` with the same text. A Loader that fails owning nothing is released, and only
  starts are refused. An in-process Nim host can learn of it at once: `runtimeSetTerminationHook(rt,
  hook, data)`, set before `start` (`LOGOS_ERR_NOT_READY` once a start was attempted;
  `LOGOS_ERR_INVALID_PARAMS` for a nil handle or hook), is called once, on a Runtime thread, with the
  instances left unresolved; it must not call into the Runtime. It has no C export (DECISIONS G304).
  logosd uses it to end its process (`docs/DAEMON.md`).
- **Shutdown** (RUNTIME l.3714-3730). Every instance the Loader realized is released before the
  Loader. A release still running when the shutdown grace ends makes shutdown complete with
  `LOGOS_ERR_MODULE`; the Loader stays, asked only to release, until that release returns, and
  `destroy` is `LOGOS_ERR_NOT_READY` until then. Keeping the Loader delays no withdrawal: each
  instance's routes and Runtime Control binding end when its stop begins.
- **The protected realization input** (G400; `protected_inputs` above). The name
  `.lcn-protected-input` is reserved in every state directory, with the temporary names
  `.lcn-protected-input.<32 hex>`. Once an attempt's state directory is established, before
  `_MODULE_init` or before its Module Host starts, the Loader writes the instance's bytes there: to a
  new temporary file (`O_EXCL`, `O_NOFOLLOW`, mode 0600; a name that exists is never opened), flushed
  and renamed onto the reserved name, with every step relative to the directory and following no link.
  Whatever is at the reserved name first is removed without following it (a symbolic link goes, its
  target stays); a directory there fails the attempt `realization-failed`, as does a write that
  fails. An attempt for an instance without protected input removes a leftover first, so a module
  never reads a file not written for its attempt. The file is removed when `_MODULE_init` returns,
  success or failure, again at release, and when the instance is retired; its directory stays. The
  bytes' digest is part of the realization request's key (LOADER l.368-370), so a changed input is a
  new request.

## Module Hosts

With `runtime.module_host` set, a `hosted_dynamic` instance runs in a `logos-module-host` process
of its own, one per realization (DECISIONS G264-G267, I91; LOADER §3-§9). The Runtime starts and
ends it for the Module Loader; nothing restarts it (LOADER l.105). The packaged runtime library and
`logos-module-host` are orc builds (DECISIONS G277).

- **What the module sees.** The same entry points, initialization input and Runtime Control binding
  as in process (RUNTIME §4.2.1): every Runtime Control call, subscription and asynchronous call
  crosses to the Runtime and is answered through the instance's own binding, so values, errors,
  authority decisions and state transitions are those a direct module gets (RUNTIME l.905). The
  module's `state_dir` is the same directory. Its environment is only `module_host_env`, its
  working directory the Runtime's, and its standard output and error are the Runtime's.
- **The process.** Started with `posix_spawn`, never `fork`: standard input from `/dev/null`;
  descriptor 3 the private carrier to the Runtime (a socket pair the Runtime makes; DECISIONS G266);
  descriptor 4 a provider's listener (below); descriptor 5 the instance's restart lock (below); no
  other descriptor of the Runtime; a process group of its own; an empty signal mask, and SIGPIPE,
  SIGTERM, SIGINT and SIGHUP at their default actions. `argv` is the program's name and
  `--parent=<pid>`, the Runtime's process id: nothing about the instance is in its command line or
  environment. Before anything else the host binds itself to that process (DECISIONS G264, amended
  2026-11-21): on Linux it sets `PR_SET_PDEATHSIG`, so it is killed when the Runtime's supervision
  thread ends, and then, on Linux and macOS, it checks that its parent is still that pid. A host whose
  Runtime ended before that check has been adopted and exits 70; one started without a valid
  `--parent` exits 2. It runs as the Runtime's user: placement `process` is a separate address
  space, not a sandbox (LOADER §3).
- **Supervision** (DECISIONS G265). One supervision thread per Runtime, started with the first host,
  watches every carrier and reaps each host it started (`waitpid` on its own pids, never on any
  child). After every end, an orderly one too, the host's whole process group is killed, and the
  end counts only once the host is reaped and the group is gone. A process the module moved out of
  the group is not covered.
- **Start and stop.** The Loader stages and verifies the artifact as for `direct_dynamic`, starts
  the host, and has it map the staged copy and run the module's checks and `_MODULE_init`; the same
  failures give the same Loader errors (LOADER l.388-403). A stop has the host call
  `_MODULE_destroy` once; the host then exits.
- **A host that ends by itself** (its module exits or crashes, it is killed from outside, or its
  carrier breaks; DECISIONS G268): the instance enters `error` with `host-terminated` and a
  diagnostic names it with the exit status, the signal or the carrier's failure; its routes fail, its
  Loader record is released, its intent is kept and nothing restarts it. A restart policy sees a live
  failure (G289). An end that follows the host's own answer (a failed `_MODULE_init`, a release) is
  classified by the Loader's answer, as for a direct module.
- **Deadlines** (DECISIONS G269). Past the startup deadline the instance enters `error` with
  `startup-timeout` and a host still in `_MODULE_init` is ended; `realization` is `unknown` until
  its end is confirmed, then `absent`. Past the stop deadline and the shutdown grace period, the
  instance stays `stopping` with `cleanup-timeout`, the host is ended, and its release completes the
  stop (`unloaded`; RUNTIME l.575-576, l.3732). Past the apply deadline
  (`configuration-indeterminate`), a hook that still has not returned one stop deadline later has
  its host ended. Past the startup and apply deadlines the state stays `error` with the deadline's
  classification.
- **Live configuration** runs `_MODULE_apply_configuration` in the host. A host that ends while it
  runs answers the `apply_configuration` caller `LOGOS_ERR_MODULE` and leaves the instance `error`
  with `host-terminated` (DECISIONS G270).
- **The Module Loader's loss** ends every host it owned; each instance's cleanup resolves when its
  host's end is confirmed, and nothing is realized again until the Runtime restarts.
- **The restart lock** (DECISIONS G275): `<work_dir>/hosts/` (made 0700) holds one lock file per
  hosted instance, named by a hash of its id. The Runtime takes the lock before it starts a host and
  hands it to the host, so it is held while the host, or anything the module forked, runs. After
  the Runtime ended without completing shutdown, a stored hosted instance whose lock is still held
  reports `realization` `unknown`, and `start_module` and `recover_module` answer
  `LOGOS_ERR_NOT_READY` ("a Module Host of the previous run may still be running"); the Runtime
  tries the lock again every second and the instance is restored as any other (`error`,
  `host-terminated`) once it can take it. After a completed shutdown that left it `stopping`
  (DECISIONS G357) it stays `stopping`, `unknown`, until the lock is free, then completes its stop. Nothing ever connects to a host of an earlier run. The files are not removed;
  they hold no data.
- **A hosted provider** (an instance whose record names a contract; DECISIONS G267, G273, G274):
  before its host starts, the Runtime creates its endpoint under `runtime.endpoint_dir` exactly as
  for a direct provider served over local transport, and hands the host the listening socket as
  descriptor 4. The host serves it with the Runtime's transport code before it reports the module
  initialized, and the Runtime checks the socket is still the one it made before the instance is
  `ready`; a listener that does not reach the host, or a path replaced meanwhile, fails the start and
  nothing is served. Every route to it is `local-transport` (above, `routing`). Payloads go between
  the consumer's process and the host directly; the Runtime stays on the control path. It judges
  each Hello, admits each call, subscription and delivery and keeps each session from what the host
  reports without payloads, so tickets, access, revocation and the call records' outcomes are
  exactly those of a direct provider's transported routes. The host checks each payload against the
  selected contract with the Runtime's own checks, runs the provider's code for each admitted call
  (synchronous or deferred, up to 64 at once), commits the Response and reports the commitments a
  call record retains; those roots, and what the host sends a consumer, rest on the host
  (docs/CONFORMANCE.md, DECISIONS G273, G274). The endpoint goes with the realization, as a direct
  provider's does.
- **A hosted consumer** (DECISIONS G267): its route handles and their connections are in its host,
  which connects to the provider's endpoint itself, so payloads go between the two directly. The
  host keeps a route's ticket and endpoint path from the `establish_route` or `renew_route` answer
  it passes on to the module, until the route's handle is materialized or the route ends; the
  Runtime makes every decision of `materialize_route` and of each call, subscription and end
  observer through the handle, as for a direct consumer, so codes, ends and their order are a direct
  consumer's. Every host receives the Runtime's Transport limits, which its own connections use.
- **The Package Manager and its Storage provider** stay `hosted_dynamic` (C1; DECISIONS G395): their
  `lcn.storage_fetch` reads then go between the two hosts directly, and a `direct_*` placement of either
  would put package archives into the Runtime's process (`sdk/docs/STORAGE-FETCH.md` §8).
- **Exit statuses** of the program, for a log: 0 after an orderly release; 2 when it was not started
  by a Runtime (descriptor 3 is not a connected local stream socket); 70 when its carrier broke the
  protocol or closed unexpectedly. The Windows build is a stub that exits 2.

## Runtime limits

Every limit of the engine in one place (RUNTIME l.3252-3254 and BCP l.375 ask for them to be
documented; DECISIONS I88). Only the ones marked "here" are set in
this file; the others are fixed (tests set the engine limits smaller).

| Limit | Value | Set |
|---|---|---|
| known module instances, retained ones included (`MaxInstances`) | 1024, the Module Loader instance among them; past it `create_module` is `LOGOS_ERR_MODULE` | fixed |
| the Module Loader | one instance, with one thread of its own; its calls run on the lifecycle workers | fixed |
| the persistent store's snapshot (`MaxStoreBytes`) | 64 MiB | fixed |
| lifecycle workers (`MaxWorkers`): bind, init, destroy, completion callbacks, `observe_end` handlers, apply hooks | 64, started on demand | fixed |
| overflow lifecycle workers (`MaxNestedWorkers`) | 64 more, one per `starvationDelay` (50 ms) while jobs wait behind 64 busy workers and none finishes; nothing is ever refused (DECISIONS G242) | fixed |
| call workers for asynchronous calls (`MaxCallWorkers`) | 64, started on demand | fixed |
| overflow call workers (`MaxNestedCallWorkers`) | 64 more, the same way; when calls still wait for `refuseDelay` (1 s) with all 128 busy, the oldest call that has not started completes `LOGOS_ERR_MODULE` "no call worker is available" through its callback (G242). For a refusal, a call worker is busy while it runs a job: one started but not yet running one is not. If no call worker takes or finishes a job for 10 × `refuseDelay` (10 s) while calls wait at the bound, the oldest is refused anyway, one each such period | fixed |
| asynchronous calls prepared and not released (`MaxAsyncCalls`) | 4096; one more is `LOGOS_ERR_MODULE` (INTERFACE l.1998) | fixed |
| evaluation workers and queue (`EvalWorkers`, `EvalQueue`) | 4 threads, 256 waiting | fixed |
| handler passes per operation (`MaxPasses`) | 8; more is an evaluation failure | fixed |
| Runtime Control event workers (`MaxEventWorkers`) | 64 | fixed |
| observation: pages, snapshots, `observe_end` registrations | "Observation", Limits | fixed |
| Runtime Control subscriptions and their queues | "Runtime Control subscriptions", Limits | fixed |
| direct event deliveries queued for one subscription while another thread runs its handler (`eventQueue`, `eventQueueBytes`) | 1,024 deliveries or 16 MiB of event data; one more ends the subscription with `LOGOS_ERR_MODULE` (`routing`, "Events on a direct route"; DECISIONS G176) | fixed |
| ended route records kept per consumer | 4096 | fixed |
| committed changes and diagnostics kept for observation | 4096 each | fixed |
| payload depth (`max_payload_depth`) | 128 to 1024, default 1024 | here |
| call records in memory (`call_audit.call_records`) | 1 to 1,000,000, default 4096 | here |
| the Capability Authority's audit records (`audit.records`) | docs/AUTHORITY-POLICY.md | in the policy |
| deadlines | `runtime` (Fields) | here |
| transport aggregates | docs/CONFORMANCE.md, "Transport limits", on the Runtime's transport I/O thread (DECISIONS I90); the ones `transport` names are set here (next row) | fixed |
| transported routes: I/O thread limits and Event output | `transport` (Fields) and "Event output" under `routing` | here |
| the reference orchestration module | "The reference orchestration module", Limits; `resync_ms` in its value | fixed |
| Module Hosts | one process per `hosted_dynamic` realization; their Runtime Control requests run on 64 proxy workers per Runtime, started on demand; a carrier frame is at most 16 MiB + 64 KiB | fixed |
| state transfers | one entry per instance on each side; `move` is one rename and copies nothing; `copy` at most `max_bytes` (1 GiB by default, at most 2^40), 1,000,000 entries (`MaxTransferFiles`), 64 directory levels (`MaxTransferDepth`), and 64 MiB left free on `state_root`'s file system | here |

## Loaded code

The Module Loader is the ABI caller for every instance but its own: it binds, initializes and
destroys module code (LOADER §6), and the Runtime's bootstrap mechanism does so only for the Loader.
A `direct_dynamic` library, once mapped, stays mapped for the Runtime's life, and a static binding
stays registered until `logos_runtime_destroy`: bindings are never unloaded (DECISIONS I88, deviation
1; TF-03). RUNTIME l.368 requires only that a binding be kept until every context made from it has
been destroyed, and unloading code that a module's own threads or registrations may still reach
would crash the process (l.3705). The cost is one mapping per (hash suite, digest, module) for the
Runtime's life: a host that cycles many distinct artifacts through one Runtime should restart it.

## Under `capability-authority`

- **The authority is part of the library.** `liblogos_runtime` links the Capability Authority (CA
  §1, l.145) and registers its symbol table itself, as binding `logos_capability_authority`: it is a
  Logos-defined system module whose call surface uses reserved names, which a host-registered table
  cannot (DECISIONS I84). A host that registers a binding with that identifier anyway gets
  `LOGOS_ERR_INVALID_PARAMS` from `start`. The Runtime hands the instance its inputs in process
  (RUNTIME l.1597): `policy`, the Runtime identity, the attribute source and the wall clock, keyed by
  its state directory `state_root/<state_assignment>`. The authority keeps its grants, audit and
  policy revision there; the Runtime keeps its identity in `store_dir`, so both name the same Runtime
  across starts.
- **Who starts the authority.** The bootstrap starts the orchestration instance only. Until an
  authority instance is bound, the Runtime answers from rules derived from this configuration, never
  configurable (BCP l.365; RUNTIME l.1548-1566, RUN-0305, RUN-0306, RUN-0311). They name the
  orchestration instance as the only consumer and the authority instance as the only target, and allow:
  - Runtime Control `start_module`, `recover_module` and `get_readiness`;
  - `module_execution` `start` in `direct` mode, with the orchestration instance as origin.

  Nothing else is allowed before the binding. Once the authority is `ready` and passes the binding
  checks (RUNTIME l.1568-1583), every module operation is decided by it, and the derived rules lapse:
  the two never decide the same operation. The authority does not start itself: the reference
  orchestration module starts it when its value names it in `authority` ("The reference
  orchestration module").
- **Fail closed.** While no binding exists, every operation the authority would decide is refused
  with `LOGOS_ERR_NOT_AUTHORISED`, classified as an evaluation failure; nothing falls back to a less
  constrained policy (RUNTIME l.1646-1653, RUN-0050). An evaluation that takes longer than
  `evaluation_deadline_ms` is an evaluation failure too, never a deny.
- **Losing the authority.** When the bound instance stops, fails or loses its notification path, every
  execution it authorized ends (CA l.854): those modules stop, classified as an authority ending,
  with their intent kept. The orchestration and authority instances, authorized by the derived rules,
  keep running. With `recovery: true` the derived rules apply again, so the orchestration instance can
  recover the authority and then the stopped modules (RUNTIME l.1590-1596). With `recovery: false`
  (the default) only a host restart restores the deployment.
- **Authority over time.** A module's execution authorization is renewed before its decision's
  `valid_until`, on a lane of its own; one that is not renewed, or whose grant is revoked or expires,
  or that a policy change no longer allows, stops the module (CA §5.1, §8). A route is re-authorized
  when a grant or policy change affects it: a deny or a narrower allow revokes it; an evaluation
  failure leaves it `ready` but refuses its calls until a later decision allows it again. A route's
  `expires_at` is never extended (DECISIONS G170).
- **Time assurance** (RUN-0940). The host's wall clock is trusted for `valid_until`. Each validity is
  also held on a monotonic clock fixed when the decision is received, so a backward step of the wall
  clock never extends authority and a forward step ends it early. There is no skew tolerance.
- **Events.** A subscription is decided when it is activated and again at each delivery, and a
  publication at each delivery (DECISIONS G175). Under an authority that issues only single-use
  decisions, every delivery costs two evaluations on the publishing thread. A subscription whose
  delivery decision does not allow it (a deny, or an evaluation that fails) ends, on a direct route
  and over local transport alike; its handle reports the end with `LOGOS_ERR_NOT_AUTHORISED` through
  `observe_subscription_end`, and its `unsubscribe` returns `LOGOS_OK` once. An idle subscription
  learns that its authority ended at its next event, not when the policy changes (DECISIONS G175).
- **Grants.** A grant comes from a module that a policy `issue` rule allows, or from the embedding
  host through the authority's protected path. An in-process host reaches the authority with
  `authorityFor(state_root/<state_assignment>)` and calls `issueProtected` and `revokeProtected`
  (`docs/AUTHORITY-POLICY.md`, "Grants"); there is no C export.
- **The attribute source** (BCP l.373). The authority matches policy subjects against facts the
  Runtime keeps for each instance: its id and module name. No instance has a signer or package
  fact, direct or hosted: the Runtime records the module name and no selection for every
  instance, whatever its strategy (DECISIONS I97), so rules naming those match none of them. A
  host does not supply the facts. logosd's deployment document states it
  ([DEPLOYMENT.md](DEPLOYMENT.md) §11).
- **What the Runtime retains about decisions** (RUNTIME l.1661-1663, RUN-0330). The last 4096
  authorization answers, in memory: for each, the consumer, operation, target, decision id, source,
  outcome and the grants it used. They are lost at exit; the authority's own audit is what persists.

## Persistent Runtime state

With `runtime.store_dir`, the Runtime keeps its own persistent state there (DECISIONS I82; RUNTIME
l.3364-3371, l.3632). Without it nothing persists: every `start` is a new Runtime with a fresh
identity, and every configured instance is new.

- **Where it is.** `store_dir` holds `runtime-state.cbor` (one deterministic-CBOR value, format
  `logos-core-nim.runtime-state.v2`, which a build older than the re-pin's P5a cannot read; a v1 store
  is read as one written by a run that did not complete shutdown), one `cfg-<hash>.cbor` side record per configurable instance
  (its configuration binding and state, up to about 17 MiB), while a permission profile is selected
  one `prm-<hash>.cbor` side record per instance (its permission settings: revision, permissions and
  status, `store.cddl`'s `lcn.prm_record`; DECISIONS I93), one `xfer-<hash>.cbor` side record per
  instance a state transfer populated (below), and `lock`. The directory is
  created with mode 0700 and refused at `start` (`LOGOS_ERR_MODULE`) if group or other may access it
  or another user owns it; the files are created 0600. Each change is written to a temporary file,
  flushed to the medium (`F_FULLFSYNC` on macOS), renamed over the old file and the directory flushed,
  so after a crash the file holds either the old state or the new one. On Windows the store inherits
  the directory's ACL: give the directory an owner-only ACL yourself. The state is at most
  `MaxStoreBytes` (64 MiB); a change that would exceed it fails like a write.
- **One Runtime per store.** The Runtime holds an exclusive lock on `lock` from `start` until
  `destroy`. A second `start` on the same store, in this process or another, returns
  `LOGOS_ERR_MODULE` ("the state store is in use"). Taking the lock is how the Runtime knows that the
  previous process has ended, and with it every realization it ran in that process (direct mode,
  RUNTIME l.3645). Processes a module started on its own are outside this evidence.
- **Identity.** A configuration whose `runtime_instance_id` differs from the store's makes `start`
  return `LOGOS_ERR_INVALID_PARAMS`, and nothing is written. A store that is deleted, or replaced by
  another, under a host-chosen `runtime_instance_id` needs a new `runtime_instance_id`: addresses and
  revisions under the old one may already be known elsewhere (DECISIONS G192).
- **What survives a restart.** For each instance: its id, its provider id, the record it was created
  from, its lifecycle state, its failure classification and reason, its execution intent, the
  intent's revision and its origin; for a configurable instance, its configuration binding, state
  revision, current and staged values and their provenance; with a profile selected, its permission
  settings, revision and status kept. Settings that were `pending` when the Runtime ended settle as
  it opens, at the same revision: `applied`, or `failed` for a permission no active point enforces
  (no realization survives the process; RUNTIME l.2518). An instance with no settings record (created
  while no profile was selected) gets revision 1 with no permission. The store must agree with the
  selection: settings saved while a profile was selected make `start` return `LOGOS_ERR_MODULE` when
  no profile is selected, or when they name a permission the selected profile does not define,
  naming the instance; accepted settings are never dropped silently (RUNTIME l.2471). Also the ids of retired instances with
  the state assignments they keep, and `create_module` keys. A configurable instance whose side
  record is missing or does not hold the binding its record names makes `start` return
  `LOGOS_ERR_MODULE` naming it, and nothing is written. Not kept: routes and their keys (a route id from an earlier run is
  unknown), realizations, authorization answers and the change log. Every execution revision after a
  restart is larger than any the Runtime exposed before (RUNTIME l.3370).
- **Instances and the configuration** (RUNTIME l.1316-1322; DECISIONS G160 as changed, G243 as changed).
  - A configured instance the store holds is the same instance while its declaration facts are
    equal: its record, leaving out the artifact's `local_path` and the permissions' `reason` texts,
    which it takes from the configuration.
  - *A static binding mismatch.* A retained `direct_static` instance is mismatched for the run when
    its facts differ from the configured ones, when its binding is not registered for its module, or
    when nothing supplies its facts (a configured instance the configuration no longer names). An
    instance `create_module` made is compared with its module's declaration, with its own state
    assignment. A mismatched instance keeps its retained record and state, is not realized, and
    `start` does not fail: an `unloaded` one with `requested` intent reports
    `static-binding-mismatch`, and `start_module` or `recover_module` on it returns
    `LOGOS_ERR_NOT_READY` with that classification, before any module code or Module Loader call. An
    instance restored as `error` keeps its classification until such a refusal replaces it. A later
    `start` with the same facts and binding makes it realizable again. Supplying the same binding
    identifier asserts implementation continuity: a build whose implementation is not compatible with
    the retained state registers it under a different binding identifier and configures a replacement
    instance (RUNTIME l.1320), which can take the old one's state through `state_transfers` (above).
  - For a `direct_dynamic` or `hosted_dynamic` instance, different facts still make `start` return
    `LOGOS_ERR_INVALID_PARAMS` naming the instance, before anything runs (DECISIONS G160, interim):
    give the changed module a new instance id, and retire the old one once it is no longer configured.
    The one exception is an instance the host lists in `artifact_adoption` whose facts differ only
    in the artifact's hash: its record takes the new hash (DECISIONS G505; above).
  - An id that was retired cannot be configured again, and a state assignment a retired instance
    keeps cannot be given to another instance (`LOGOS_ERR_INVALID_PARAMS`).
  - An instance dropped from the configuration stays known, with its state, until it is retired.
- **Resumption after a restart, and retries after a failure** (RUNTIME l.3632).
  - *Resumption.* At every `start`, the Runtime re-establishes the Module Loader instance and then
    the orchestration instance, each the same way: a retained `requested` intent whose origin is the
    host is resumed, with its revision and origin kept; otherwise (never started, explicitly
    stopped, or requested by a module) the instance is started anew with the host as origin, and a
    diagnostic says so (DECISIONS G191, interim; I89). The Runtime starts nothing else. Any other instance's retained `requested` intent is
    acted on only if the orchestration module resumes it, by `recover_module` (RUNTIME l.3631).
  - *How instances come back.* An instance that was running when the Runtime ended cleanly comes back
    `unloaded`, with its intent. One that was `loaded`, `ready` or `stopping` when the Runtime ended
    without completing shutdown (a crash, a kill) comes back `error` with the classification
    `host-terminated` (RUNTIME l.3634; DECISIONS G193). An instance that was already `error` keeps its
    classification. A completed shutdown marks its last record (DECISIONS G357): an instance it left
    `stopping` past the grace period completes its stop at the next `start` (`unloaded`, with an
    enforcement classification it kept), or, if hosted with its restart lock still held, once the lock
    is free. The next write removes the mark.
  - *Resuming is not a retry.* Bringing an instance back after a restart, clean or not, is a
    resumption: it counts as no restart attempt against any restart policy. A restart policy counts
    the `recover_module` calls made after the instance failed while the Runtime was running, and an
    episode of them still open when the Runtime ended continues, charged, after the restart
    (DECISIONS G193 as amended, G289).
  - *No policy in the Runtime.* The Runtime itself never restarts anything. The reference
    orchestration module does: "The reference orchestration module", above.
- **Persistence failures.** When the state cannot be written, nothing new starts: `start_module`,
  `recover_module`, `create_module` and `retire_module` return `LOGOS_ERR_MODULE`. Stops and failures
  still take effect at once (routes end, realizations are released), but observers keep seeing the
  last state written, and a reply that would carry the new state is `LOGOS_ERR_MODULE`. The write is
  retried every second; the first that succeeds makes everything visible. `wait_for_shutdown` returns
  `LOGOS_ERR_MODULE` if the final state could not be written. A store that cannot be read at `start`
  (corrupt, from a newer format, or failing its consistency checks) makes `start` return
  `LOGOS_ERR_MODULE`, and the file is left as it is.
- **Backup, restore and rollback.** Back up `store_dir` and `state_root` together, with the Runtime
  stopped. Restoring an older store brings back the instances, intents and keys it lists, including
  instances retired since: avoid it after retirements. Revisions stay safe after a restore while the
  system clock has not gone back: the Runtime takes its revision epoch from the clock, so restore no
  sooner than a second after the newest run started.
- **Protection at rest.** The state is not encrypted; the operating-system user is the boundary.
- **Recovery and retirement** (RUNTIME §9.3). `recover_module` starts a new attempt for an instance
  whose intent is still `requested` and that is `unloaded` or `error` with its cleanup complete,
  given the `expected_execution_revision` the caller read. It keeps the intent, its origin and the
  record, and execution is authorized for that retained origin, not for the caller (l.3405). One
  revision value admits at most one attempt: a repeated or concurrent recovery with it is
  `LOGOS_ERR_INVALID_PARAMS`, so a restart policy counts the recoveries it was answered, or reads
  `get_readiness` when an answer was lost. After an explicit stop, and during shutdown, recovery is
  `LOGOS_ERR_NOT_READY`. `retire_module` removes an instance for good once it is `unloaded` or
  `error`, its intent is not `requested`, nothing of a realization or its cleanup is left, no other
  instance's `requested` intent names it as origin, and the configuration no longer lists it
  (`LOGOS_ERR_NOT_READY` otherwise). A target on another Runtime is `LOGOS_ERR_INVALID_PARAMS`
  (DECISIONS G194, interim). The removal is written before the answer. The instance's permission
  settings go with it: they stay attributed to its address and pass to no other (RUNTIME l.2564), so a
  new instance of the same module is provisioned afresh.
- **Retention.** Retiring an instance keeps its state directory and reserves its state assignment:
  retirement is not deletion (BCP l.400). The library deletes no state directory. A host removes a
  retired instance's directory offline, with the Runtime stopped (logosd's `logosctl state purge`,
  [DAEMON.md](DAEMON.md) §11; DECISIONS G143), and never one a state transfer still owes (its
  replacement's directory missing: start the Runtime once first). The tombstone keeps the
  assignment reserved, so it is never reused. A name in `state_root` starting with `+` is the
  Runtime's (an unfinished copy or purge) and is removed at the next start. A replacement
  instance gets a retired or replaced instance's state only through `state_transfers` (below).
- **Bounds.** At most `MaxInstances` (1024) known instances, retained ones included, for
  `create_module`.

## State transfer to a replacement instance

An instance's module state stays with its state assignment: a new instance, even of the same module,
starts with its own empty directory (RUNTIME l.3446, l.2565). To replace instance `a` by a new
instance `b` that continues from `a`'s state (an upgrade under a new id, a changed declaration),
give `b` its own `state_assignment` in `modules` and add `{from: a, to: b, mode: move}` (or
`mode: copy`) to `state_transfers`, with the Runtime stopped. The entry is the authorization (DECISIONS G306): no
Runtime Control method moves state.

At the next `start`, before the orchestration instance or anything else starts (DECISIONS I96):

1. Every entry is checked, and a refused one fails the start with nothing changed (table below).
2. For each entry, in order: for `copy`, `state_root/<a's assignment>` is copied into a staging
   directory `state_root/+transfer-<hash of b's assignment>` and flushed; `b`'s transfer record is
   written; then one write creates `b` (`unloaded`, intent `uninitialized`, its own assignment) and
   retires `a` if it is still known (RUNTIME l.3413: the deployment's stop; its intent ends with it);
   then `state_root/<a's assignment>` (`move`) or the staging directory (`copy`) is renamed to
   `state_root/<b's assignment>` and `state_root` flushed. A diagnostic says "state transfer: a
   (a-state) to b (b-state), move", or "…, copy, N bytes in K files".
3. `b` starts only the ordinary way (the orchestration module or a Runtime Control `start_module`;
   the bootstrap itself when `b` is the orchestration instance), with its own authorization,
   initialization and readiness (RUNTIME l.3418).

`a`'s id and its assignment stay reserved on its tombstone, as for any retirement. After `move` its
directory name is gone; after `copy` its directory stays as it was, for a later rollback or a purge.
An applied entry is satisfied: left in the configuration, it changes nothing at later starts, and can
be removed whenever convenient.

A `copy` skips the protected realization input's reserved name and its temporary names at the top of
the source (G400): one instance's input never reaches another's directory, and is not counted against
`max_bytes`. A `move` takes the directory as it is; the replacement's first attempt replaces or
removes the file before its initialization.

- **What `b` gets.** The files only. Its configuration comes from its own entry (CONFIG l.255-261),
  its permission settings from its own provisioning, and its grants from the policy; `a`'s
  configuration and settings records are deleted with its retirement, and its grants name `a` and
  pass to no other instance (CA l.725). No route survives a restart. Read `a`'s configuration while
  it is still known ("Keeping a configuration across an upgrade", above).
- **No snapshot for `move`.** `move` is one rename on one file system and reads nothing. Back up
  `store_dir` and `state_root` together before a start that applies an entry: the backup is the
  rollback (RUNTIME l.3414-3415, l.3419; BCP l.399).
- **`copy`.** The source's directory stays as it was, so it is the rollback: a later entry
  `{from: a, to: c, mode: copy}` gives a new `c` `a`'s state as it was at the transfer (RUNTIME
  l.3453: `a`'s tombstone keeps its assignment). What is copied:
  - directories and regular files only. Any other entry (a symbolic link, a socket, a FIFO, a
    device) refuses the transfer, naming its path. A link at the root of `a`'s directory is followed;
    inside, none is. Hard links become separate files. Each file keeps its permission bits;
    directories are made 0700; owners, times, extended attributes and ACLs are not kept;
  - at most `max_bytes` of file content (1 GiB by default), 1,000,000 entries and 64 levels of
    directories, with that many bytes and 64 MiB more free on `state_root`'s file system. All of
    it is measured, reading metadata only, before anything is written;
  - every file and directory is flushed before the commit. A large copy lengthens the start: there
    is no deadline.
- **`copy` reads the state in the Runtime's process** (in logosd, the daemon's). The Runtime
  thread reads and writes every byte of `a`'s files through one 64 KiB buffer, zeroed after the copy
  and on every error before it is freed (in orc builds; DECISIONS R5); nothing else of the content is
  kept, logged or recorded. `move` reads nothing. Apart from `copy`, no module state passes through
  the Runtime or logosd.
- **Quiescence.** The source must have nothing of a realization left (RUNTIME l.3413, l.3428): its
  realization is `absent`, and nothing it owned is pending. A direct instance of an earlier run
  qualifies once the Runtime holds the store lock, after a clean end or not. For a `hosted_dynamic`
  source the restart lock is the evidence ("Module Hosts", above): it must exist and be free.
  Processes a module started on its own are outside this evidence, as for a restart.
- **Interrupted transfers.** A crash before `b` is written leaves nothing: the transfer record is
  removed at the next start, and so is an unfinished staging directory (every `+transfer-…` and
  `+purge-…` name in `state_root` that no committed transfer owes is removed, with a diagnostic;
  `+` is outside an assignment's characters, so no instance owns such a name). A crash after it is
  completed at the next start, before anything runs: the directory (or the whole staging copy) is
  renamed and a diagnostic says "completed the state transfer to b". If neither
  directory is there any more (deleted by hand), a diagnostic says "the state directory of b is
  missing", and every start of `b` fails (`error`, `other`, "the state transferred to b is
  missing") without creating an empty directory, until the directory is restored from the backup or
  made empty on purpose.
- **The record.** `xfer-<hash>.cbor` in `store_dir` (`store.cddl`'s `lcn.xfer_record`): the source,
  its assignment, the mode, the bytes and files copied (0 for `move`), the Runtime epoch and the time
  of the transfer. It stays when `b` is retired: retirement keeps audit history (RUNTIME l.3453).
- **Windows.** `move` renames with `MoveFileExW` (write-through, never replacing). `copy` is not
  supported there: `LOGOS_ERR_MODULE`, nothing changed.

| Refusal at `start` | Code |
|---|---|
| `b` is known to the store without a record of this transfer ("a transfer populates only a new instance"), or was retired | `LOGOS_ERR_INVALID_PARAMS` |
| `a` is unknown, or kept no state assignment ("the transfer source is unknown or kept no state assignment") | `LOGOS_ERR_INVALID_PARAMS` |
| `state_root/<a's assignment>` is not a directory, or a link to one ("the transfer source has no state directory") | `LOGOS_ERR_INVALID_PARAMS` |
| `state_root/<b's assignment>` exists ("the replacement's state directory already exists"): nothing is merged | `LOGOS_ERR_INVALID_PARAMS` |
| `a` still has a realization or its cleanup | `LOGOS_ERR_NOT_READY` |
| `a` is `hosted_dynamic` and its restart lock file is missing: an edited `work_dir` or a cleaned `hosts/` is no evidence that its host ended | `LOGOS_ERR_NOT_READY`, naming the file |
| A Module Host of an earlier run may still hold `a`'s state: its restart lock is held | `LOGOS_ERR_NOT_READY`, naming the file |
| Another instance's retained `requested` intent names `a` as its origin (RUNTIME l.3433-3435) | `LOGOS_ERR_NOT_READY` |
| `copy`: `a`'s directory holds an entry other than a directory or a regular file ("…: sub/link") | `LOGOS_ERR_INVALID_PARAMS` |
| `copy`: more than `max_bytes`, 1,000,000 entries or 64 levels, or too little free space | `LOGOS_ERR_MODULE` |
| `copy` on Windows | `LOGOS_ERR_MODULE` |
| The store cannot be written, a `copy` cannot read or write a file (the staging directory is removed), or the rename fails | `LOGOS_ERR_MODULE` |

A held restart lock stays refused until the process holding it is gone: nothing ends a host of an
earlier run. Find it with `lsof <file>` or `fuser <file>`, end it, and start again (RUNTIME l.2568,
l.912). For an intent that names `a`, stop or retire that instance while the Runtime runs, then
start again. A refused start runs nothing (RUNTIME l.3955) and leaves the store and both directories
as they were; a `LOGOS_ERR_MODULE` after the write leaves the rename to the next start.

## Observation

What a module sees through Runtime Control's observation methods (DECISIONS I86; RUNTIME §9.3). None
of it is configurable in this file; the limits below are the Runtime's (RUNTIME l.3252-3254 asks for
them to be documented).

- **Lists.** `list_modules` and `list_routes` answer from one snapshot made when the first page is
  asked for, after the method's authority, the filters and each record's visibility; later pages
  come from that snapshot, so an instance created after it does not appear and nothing is reordered
  (l.3262-3271). Every page applies the caller's current authority again: a record it may no longer
  observe is left out, and a continuation is given only while a record it may observe remains. A
  route is listed while its record is kept, its ended state included.
- **Cursors.** A `next_cursor` is a random 43-character token that continues only the query that
  made it: the same consumer instance, method, filters and limit (a `provider` filter without
  `runtime_instance_id` is the same as one naming this Runtime). Anything else, an expired cursor
  and one whose snapshot was reclaimed are `LOGOS_ERR_INVALID_PARAMS` without detail.
- **Limits.**

  | Limit | Value |
  |---|---|
  | records per page, when `limit` is absent | 100 (1 to 1000 when present) |
  | bytes of records in one page | 4 MiB |
  | retained snapshots per consumer instance | 8, and 8 MiB |
  | retained snapshots in all | 256, and 64 MiB |
  | a snapshot not paged for | 10 minutes, then it expires |
  | a snapshot's life | 1 hour, then it expires |
  | `observe_end` registrations per consumer instance | 1024 |
  | `observe_end` registrations in all | 16384 |

  A first page that needs a continuation is retained; past a consumer's own allowance its least
  recently used snapshot is dropped to make room (its cursors become invalid); past the allowance in
  all, after expired snapshots are reclaimed, the request is `LOGOS_ERR_MODULE` and no other
  consumer's snapshot is touched. A page whose first record alone exceeds the page bytes is
  `LOGOS_ERR_MODULE`. A consumer's snapshots end with its execution attempt (a stop, a failure, a
  restart). Past an `observe_end` limit the registration is `LOGOS_ERR_MODULE` and changes nothing
  (INTERFACE l.1451-1452). Nothing here is persisted.
- **Execution summary.** `get_execution_summary` reports `selection.implementation` as the
  strategy the Module Loader realizes the instance with, `direct_static` or `direct_dynamic`. The
  Loader instance itself, which the Runtime's bootstrap mechanism realizes, reports
  `implementation-specific` (RUNTIME l.203, l.3388-3393; DECISIONS G57, I89). No selection carries
  `package` or `signer` yet.
  `realization` is `current` while the Runtime owns a realization for the instance, a cleanup still
  within its deadline included; `unknown` while a `realize` has not been answered, a bind,
  initialization or cleanup has outlived its deadline (DECISIONS G180), or the Loader's answer about
  the realization was lost or its Loader failed (DECISIONS G246, G252); `absent` otherwise.
- **A realization change is a commit.** When `realization` changes without a lifecycle transition (the
  late end of a startup past its deadline, a dynamic bind returning), the instance's execution revision advances and the
  change is persisted (DECISIONS G227, interim). A guarded `start_module`, `recover_module` or
  `retire_module` prepared with the revision read before it is `LOGOS_ERR_INVALID_PARAMS`: read the
  revision again (`get_readiness`, `get_execution_summary`) and retry.
- **Failure text.** A module record carries the failure classification. Its `reason` is the
  Runtime's or the module's own text, cut to 512 bytes. A typed Module Loader error is classified
  `loader-<code>`, `loader-artifact-unavailable` for instance (RUNTIME l.3607), except a failed
  `_MODULE_init`, which is `initialization-failed`; neither carries a `reason`, since the Loader's
  message may name host paths (RUNTIME l.1793-1796). The message stays in the Runtime's diagnostics
  and is not persisted. A failure of the bootstrap mechanism while it realizes the Loader itself is
  `other` (DECISIONS G57). A consumer of
  module records, readiness results, module-state events or execution summaries must treat a
  classification it does not recognize as an unspecified failure and never derive a restart policy
  from its spelling (RUNTIME l.3610): later specs may add classifications, as Tier 4b added
  `host-terminated` (DECISIONS G268).
- **`describe_provider`** returns the call surface validated when the provider was last bound, kept
  after it stops (RUNTIME l.505); before any bind it is `LOGOS_ERR_NOT_READY`, once the caller
  holds a `discover` allow for each contract the record expects (otherwise `LOGOS_ERR_NOT_AUTHORISED`,
  which does not say whether it was bound).
- **Permission settings in direct mode, without a profile.** Every instance has permission settings at
  revision 1, with no permission, `applied` (RUNTIME l.2468): no permission profile is selected, so a
  replacement that names a permission is `LOGOS_ERR_INVALID_PARAMS` (l.2462) and one with `[]` at
  revision 1 changes nothing (DECISIONS G229). `applied` with `[]` claims no containment: direct
  modules are trusted in-process code (SECURITY l.204; RUNTIME l.1536, l.2472).
  `get_execution_permissions` is `unavailable`. A target on another Runtime is
  `LOGOS_ERR_INVALID_PARAMS` (DECISIONS G228, interim).
- **Permission settings with a profile** (RUNTIME l.2450-2532; DECISIONS I93, G281-G285;
  `docs/PERMISSIONS.md`). Each instance's settings are its own, saved before any reply.
  - *Replacement.* `update_permission_settings` with an array that is not ascending, repeats a name,
    names a permission the profile does not define or has constraints its definition does not admit,
    is `LOGOS_ERR_INVALID_PARAMS` without detail and saves nothing. One with a stale
    `expected_revision` is answered with the response's error arm, `stale-revision` with the current
    revision (RUNTIME l.1818-1822; DECISIONS I108), and saves nothing. Repeating the saved `pending` or `applied` array returns the state unchanged. Anything
    else is a new revision, and its status follows what is left of the instance's realization: none
    (`unloaded`, or `error` with its cleanup complete) `applied` at once, to be enforced at the next
    start; `loaded` or `ready` `pending`, and the instance is stopped at once, keeping its intent and
    origin, with no failure classification; `stopping`, or `error` with its cleanup running,
    `pending` until that stop or cleanup ends; `stopping` past its stop deadline (`cleanup-timeout`)
    or `error` with `cleanup-failed` `failed` at once. Widening and narrowing alike stop the instance. The engine never restarts it:
    resumption is `recover_module` by orchestration ("Orchestration duties").
  - *Settlement.* `pending` becomes `applied` once nothing of the realization is left, and `failed`
    (with `failure: "enforcement-failed"`) when its stop passes the stop deadline: the old
    realization may persist with its old access, so the late end of its cleanup completes the stop,
    `unloaded` with `permission-enforcement-failed`, and restores nothing. A permission no active point enforces makes the settings `failed`
    once nothing is left. `failed` stays until a replacement is accepted; an `unloaded` instance whose
    settings fail gets the classification `permission-enforcement-failed`.
  - *Hosted instances* (DECISIONS G285, G275; part 4b-4c). A `hosted_dynamic` instance whose stop
    passes its deadline has its Module Host ended by force. Its realization stays until that end is
    confirmed, so a replacement meanwhile is `pending`, and the settings become `applied`, not
    `failed`, once the release completes. The same holds at the shutdown grace and after the Module
    Loader's loss. Past a deadline the instance is `stopping` with `cleanup-timeout` until then, and
    `unloaded` after. When a hosted release fails and nothing ends
    its host (`cleanup-failed`), the settings are `failed` as for a direct one. A hosted instance
    restored with its restart lock held keeps `pending` settings until the lock is taken; they settle
    then and the event is published.
  - *Admission.* A start or recovery of an instance whose settings are `failed` is
    `LOGOS_ERR_NOT_AUTHORISED` with the classification `permission-enforcement-failed`, and of one
    whose settings lack host-ambient `LOGOS_ERR_NOT_AUTHORISED` with `authority-denied`, before any
    authority is asked; the instance stays `unloaded` (or `error`), its intent kept, and a diagnostic
    names what is lacking. Otherwise the execution decision covers the execution scope and one
    permission scope per saved setting (DECISIONS G217): under `capability-authority`, one rule or one
    grant must allow all of them (G207).
  - *The snapshot.* `get_execution_permissions` answers each realization with the permissions its
    admission installed: the saved settings at that admission, or the narrower constraints the
    authority allowed (DECISIONS G282). A replacement does not change a running realization's
    snapshot; it stops the realization. An authority renewal that narrows an installed permission
    ends the execution like a denial.
  - *Revocation.* A grant or policy change that ends the execution authorization stops the instance
    (`authority-revoked`), whatever its settings' status; `pending` is no grace period (l.2529).
  - *Authority.* Each method is authorized for its target, as a lifecycle request for an update and
    an observation for a read (l.2508); settings authority grants no start, and changes no
    intent. A target on another Runtime is `LOGOS_ERR_INVALID_PARAMS`.

### Runtime Control subscriptions

A module subscribes to the Runtime Control events through the binding it received at initialization
(INTERFACE §2.5, applied by l.3868; DECISIONS I86, part 7b). The six event names are accepted.
`permission_settings_changed_event` follows every committed change of an instance's saved settings or
their status, in commit order, while a profile is selected (RUNTIME l.2531-2532; DECISIONS I93);
without one it is never produced, the settings being constant (DECISIONS G229).
`configuration_state_changed_event` follows every committed configuration revision, with the state's
summary and never a value.

- **Activation.** `subscribe` asks the event's own decision first, without a subject: a denial is
  `LOGOS_ERR_NOT_AUTHORISED`, as is a name that is not a Runtime Control event. A narrowed allow
  activates the subscription and filters what it receives.
- **What is delivered** (RUNTIME l.3362, l.3589-3591; DECISIONS G161, G226). An event reaches a
  subscriber only while the subscriber may observe its exact subject: an instance event's module and
  instance, a route event's route, provider module and provider. An `inventory_changed` hint also
  needs the matching list method's authority for at least one affected record (l.3277), and carries
  only the collection. Each event is judged when the change is committed and again just before its
  handler runs if the decisions changed meanwhile (a new policy, a revocation, an expiry), so a
  revoked subscriber gets nothing more. Under an authority that issues only single-use decisions, each
  delivery costs an evaluation.
- **When and where handlers run** (DECISIONS G178, interim). After the change is committed and
  persisted, never inside the operation that made it and never on the Runtime thread, so a handler may
  call Runtime Control. The Runtime runs handlers on its own pool of event workers (up to 64 threads,
  started on demand), one handler at a time per subscription, in commit order. Several hints of one
  collection waiting for a busy handler become one.
- **A handler that falls behind loses its subscription** (DECISIONS G225). Each subscription
  queues at most 256 events for its handler (and 256 waiting for an authority's decision); one more
  ends the subscription: its queued events are discarded, nothing more is delivered, and the Runtime
  records the diagnostic "Runtime Control subscription *id* of *instance* lost: its handler fell
  behind (G225)". The binding reports the end with `MODULE_ERROR` to the handler registered with
  `observe_subscription_end`, once, on an event worker (INTERFACE l.1472-1481); `unsubscribe` of it is
  `LOGOS_OK` once. An event decision that no longer allows the event at all (a deny, a refusal, a
  failed evaluation) ends the subscription the same way with `NOT_AUTHORISED`; one that allows only
  some subjects filters them. A Module Host reports the end in the host, as in process. An observer
  that lost a subscription, or cannot be sure it saw every event, must query (`list_modules`,
  `list_routes`, `get_execution_summary`) and resubscribe, periodically when it cannot rule out a
  loss (RUNTIME l.3283-3286). An `inventory_changed` subscription holds at most one pending hint per collection, so a
  slow handler alone never loses it; past 1024 distinct affected records behind one pending hint the
  hint is still delivered while one of them stays visible, and the subscription is lost when none is.
- **Limits.**

  | Limit | Value |
  |---|---|
  | subscriptions per module instance | 32 |
  | subscriptions in all | 1024 |
  | events queued for one subscription's handler | 256 |
  | events of one subscription waiting for a decision | 256 |
  | distinct affected records behind one pending hint | 1024 |
  | event workers in all | 64 |
  | event workers running one subscriber's handlers at once | 4 |
  | events one subscription delivers before others get a turn | 16 |

  Past a subscription limit `subscribe` is `LOGOS_ERR_MODULE`; a subscription the Runtime ended still
  counts until it is unsubscribed or its subscriber's execution attempt ends.
- **Lifetime.** A subscription ends when its subscriber leaves `loaded` or `ready`, before that change
  is observable, so a module never receives the event of its own stop; `unsubscribe` of it stays
  `LOGOS_OK`, also inside `_MODULE_destroy`. The Runtime waits for a running handler before it calls
  the subscriber's `_MODULE_destroy` and before it shuts down; that wait counts toward the stop's
  deadline, so a handler that does not return in time leaves the stop `stopping` with
  `cleanup-timeout` until it returns, as a call still running does (DECISIONS G180). A subscription never
  unsubscribed is freed when its subscriber's execution attempt ends. Nothing here is persisted.
