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
l.1391-1392: whoever can write it decides which code runs and under which authority policy. Supply it
from a source only the host's owner can change.

## Schema

```cddl
; logos-core-nim.app-config.v1: the Host Embedding API configuration (RUNTIME
; §13.3 configuration_format; decision G76). One Logos deterministic-CBOR
; lcn.app_config value. docs/HOST-CONFIG.md documents each field.
;
; An array that is present is non-empty, and the checks the schema cannot
; express (unique ids, ordering, the orchestration instance, the authority
; instance) are applied at logos_runtime_create (runtime/host_config.nim).
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
}

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

; logos.runtime.module_instance_id (RUNTIME §9.2)
lcn.app_instance_id = tstr .size (1..128)

lcn.app_module = {
  instance: lcn.app_instance_id,
  module: tstr .size (1..64),
  implementation: lcn.app_implementation,
  ? primary_contract: logos.schema_commitment,
  ? implements: [* logos.schema_commitment],
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

; logos.module_loader.direct_static and direct_dynamic (LOADER §3)
lcn.app_implementation =
  { strategy: "direct_static", binding: tstr .size (1..128) } /
  { strategy: "direct_dynamic", artifact: lcn.app_artifact }

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
  ? requires: [* lcn.app_requirement],
  ? requested_permissions: [* lcn.app_permission],
  ? persistent_state: true,
  ? configuration: lcn.app_configuration,
}
```

Maps are closed: an unknown key anywhere is rejected. An array that is present must be non-empty
(RUNTIME §8 l.1428), even where the CDDL writes `[*`; the CDDL tooling has no `+` occurrence yet.

## Fields

### `runtime`

| Field | Meaning |
|---|---|
| `work_dir` | Absolute path of a directory the Runtime owns. `direct_dynamic` artifacts are copied into private subdirectories here, verified and mapped from the copy (LOADER §3; DECISIONS I74). Created with mode 0700 at `logos_runtime_start` if missing. |
| `state_root` | Optional absolute path under which module state directories are assigned (G143). Created with mode 0700 at `start` if missing. |
| `store_dir` | Optional absolute path of the directory that holds the Runtime's persistent state (below, "Persistent Runtime state"). It must be apart from `work_dir` and `state_root`: neither inside the other nor equal. Without it nothing persists. |
| `runtime_instance_id` | Optional `runtime_instance_id` for the Runtime, 1 to 128 bytes of text; only with `store_dir`. Without it, the identity is generated when the store is created and kept with it. |
| `startup_deadline_ms` | How long one module realization may take from authorization to `ready`, including its `_MODULE_init` (RUNTIME §3.4; G61). Default 120000. |
| `stop_deadline_ms` | How long a stop may take before the realization is abandoned. Default 10000. |
| `shutdown_grace_ms` | How long shutdown waits for in-flight work before cleanup is left unresolved (RUNTIME §10.2). Default 10000. |
| `apply_deadline_ms` | How long a live configuration application (`apply_configuration`) may take, from its acceptance to the module's answer (CONFIG §8; DECISIONS G61, I87). When it passes, the outcome is unknown and the instance enters `error` with `configuration-indeterminate`, so the default is long: 120000. |
| `max_payload_depth` | The Runtime's one payload depth limit (INTERFACE §4.5.1 l.3150; DECISIONS G241, I88): how many arrays and maps may nest on any path of a payload, counted from the payload's own root (the root map is depth 1; byte-string contents are not traversed). It applies to every payload the Runtime decodes or validates: route call requests and responses, asynchronous calls, events, Runtime Control requests and responses, and configuration values (defaults, provisioned and updated). A payload one level deeper is refused before it is dispatched, accepted or delivered, with `LOGOS_ERR_INVALID_PARAMS` and no detail for a request (a provider's too-deep response or event is a `LOGOS_ERR_MODULE` failure or a dropped publication). 128 to 1024; default 1024. A transported route (Tier 4b) gives its frame decoder this limit plus the envelope's own levels. Modules built with lcn-gen's kit check their own inputs at 1024. |
| `endpoint_dir` | Absolute path of the directory under which the Runtime creates the endpoints of transported routes (TRANSPORT §8.2; DECISIONS G58, I90): one fresh `<8 hex>` directory of mode 0700 per served provider, holding the socket `logos_<module>.sock`. Default `<work_dir>/endpoints`. Used only when a `routing` rule selects `local-transport`: then it is created with mode 0700 at `start` if missing, and it must be a real directory of the Runtime's user that no one else can write to, or a root-owned sticky directory such as `/tmp`. Keep it short: a socket path longer than the platform's `sun_path` (104 bytes on macOS, 108 on Linux) cannot be created, and the route that needed it fails with `LOGOS_ERR_MODULE`. Directories a crashed Runtime left behind are not removed. |

Each deadline is 1 to 3600000 milliseconds. Paths must be absolute, so their meaning does not depend
on the host's working directory.

### `policy`

The Runtime's authority policy (RUNTIME §9 l.1629-1633): it decides Runtime Control, lifecycle, route
and observation requests, including those of the bootstrap. Two kinds:

- `allow-all`: every request a module makes through its Runtime Control binding is allowed. This is
  the internal policy RUNTIME l.1633 permits "for local trusted deployments": use it only when every
  configured module is code the host trusts with the whole Runtime. It must be written explicitly;
  nothing is allowed by default (RUNTIME l.1674, l.1682).
- `capability-authority`: the listed instance `authority` of the Capability Authority module decides
  (RUNTIME §9; CA; DECISIONS I85), from `policy`, an `lcn.authority_policy` value
  (`docs/AUTHORITY-POLICY.md`). `evaluation_deadline_ms` bounds how long a request waits for its
  decisions, from when it is queued for evaluation: 1 to 60000, default 5000, and below
  `startup_deadline_ms`. With `recovery: true` the bootstrap rules apply again after the authority is
  lost, so the orchestration instance can recover it (RUNTIME l.1674-1680); default false.

  Checked at `create`: `authority` names a listed instance whose `module` is
  `logos_capability_authority` and whose implementation is the `direct_static` binding
  `logos_capability_authority`; its `primary_contract`, when given, is the pinned Capability Authority
  contract, and when absent it is set to that contract, so the authority instance has a provider
  record like any provider (RUNTIME l.165-173, l.1420-1421, l.1647; DECISIONS I88; the realized
  contract is checked again when the instance is bound, and the Runtime never binds an authority
  instance without a provider record); it has a
  `state_assignment`; `runtime.store_dir` and `runtime.state_root` are set; and `policy` loads as the
  authority will load it. The orchestration instance cannot be the authority, since its module name
  is outside the reserved prefix. What the host can expect under this kind is below ("Under
  `capability-authority`").

Any other kind is rejected with "this policy kind is not supported yet".

### `orchestration`

The `instance` of the one listed module that holds the orchestration role (RUNTIME l.187-192;
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
| `implementation` | `direct_static` with a `binding` identifier the host registers with `logos_runtime_register_binding` before `start`; or `direct_dynamic` with an `artifact` (`id`, absolute `local_path`, BLAKE3-256 `hash`), verified against the exact bytes before mapping. A static binding no entry names is kept until `destroy`; one named but never registered makes `start` fail with `LOGOS_ERR_INVALID_PARAMS` before anything runs. |
| `primary_contract`, `implements` | Expected contract commitments. They are checked against what the implementation reports at binding; they prove nothing on their own (RUNTIME §8 l.1414-1418). Implemented commitments must be unique. |
| `requires` | Provider requirements: a contract and a cardinality. They select and grant nothing. |
| `requested_permissions` | Module-declared policy inputs, as in a package manifest (PM §4): names unique, `constraints` one deterministic-CBOR value. They grant nothing. |
| `state_assignment` | The instance's state assignment id, `[A-Za-z0-9._-]`; no two instances share one (RUNTIME §8 l.1451). |
| `configuration` | The module's configuration declaration (CONFIG §2): one deterministic-CBOR `logos.module_configuration.configuration_declaration`, its schema binding and an optional package default. See *Module configuration* below. |
| `provisioned_configuration` | This instance's protected configuration value (CONFIG l.142; DECISIONS G141): one complete value of the binding's root, at most 8 MiB. It needs `configuration`. |

`hosted_dynamic` realization cannot be expressed in v1.

### `ordering`

Lifecycle-ordering constraints (RUNTIME §3.7): a `dependent` starts only once its `prerequisite` is
`ready`. Both must be listed instances; a constraint may not name one instance twice, and the
constraints may not form a cycle.

### `declarations`

What a module may create at run time with Runtime Control `create_module` (RUNTIME l.3613-3634;
DECISIONS G55): for each module name, the one accepted declaration, with the fields of a `modules`
entry except `instance`, `state_assignment` and `provisioned_configuration` (a provisioned value
belongs to one instance, never to a module name: RUN-0923). No two declarations name one module. A
`direct_static` declaration names a binding the host registers, or `start` returns
`LOGOS_ERR_INVALID_PARAMS`. With `persistent_state: true` each created instance gets a fresh state
assignment of its own (`s-…`), which needs `state_root`.

- `create_module` for a module with no declaration is refused exactly as a denied request is
  (`LOGOS_ERR_NOT_AUTHORISED`), and creates nothing (DECISIONS G195, interim).
- A created instance is new each time: a fresh id (`m-…`), `unloaded`, intent `uninitialized`. It
  keeps the declaration it was created from. Changing a declaration in a later configuration changes
  later creations only (RUNTIME l.3621).
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
- **Marked payloads.** A `_sensitive` payload is never retained: a call whose decision would retain one
  is refused with `LOGOS_ERR_NOT_AUTHORISED` before dispatch (INTERFACE l.397). Write `commitment`
  rules that do not cover such methods, or that retain only their unmarked side.
- **Exporting evidence.** `exportCallEvidence(rt, index)` signs one retained record as a
  `logos.call-evidence.cose-sign1-slh-dsa-sha2-192s` container (CA §9.1): the complete record, no
  proofs, this Runtime's `runtime_instance_id` as producer. It is the protected export integration
  (CA l.1316-1328): calling it is the host's decision to disclose that complete record to whoever
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

Routing selection (RUNTIME §4.2 l.895-946; DECISIONS I90, G254): whether a route between two
modules of this Runtime is direct or uses local transport. Each rule names a `callee` (the provider's
module name), a `mode` (`direct` or `local-transport`), and optionally a `caller` (the consumer's module
name; absent: any consumer). For a route, the rule naming both its consumer and its provider wins, then
the rule for any consumer; with no matching rule the route is direct, as in every configuration without
`routing`. The mode is fixed when the route is established: `renew_route` keeps it, and routes already
established are never moved (RUNTIME l.940).

- Two rules for the same `caller` and `callee` are refused, as is a rule naming the Module Loader
  (`logos_module_loader`) as caller or callee (every route to the Loader is refused, G251) and a rule
  whose callee is `logos_runtime_control`, which is not a provider.
- A `local-transport` rule whose callee is `logos_capability_authority` is allowed: an ordinary
  consumer's route to the authority is then served over a socket like any provider's. The Runtime's own
  policy evaluations stay direct.
- `local-transport` is refused on platforms without the `logos.local.unix-stream` profile (Windows,
  TRANSPORT §8.2.1).
- A transported route to a provider has the Runtime serve that provider at an endpoint under
  `runtime.endpoint_dir`, created when the first such route to its realization is established; the
  provider's code still runs in the Runtime's process (DECISIONS G257). The consumer's
  `establish_route` and `renew_route` answers carry the route's `invocation` descriptor with a one-time
  ticket; no other answer, list, event, record or diagnostic does. A replay of the same request key
  returns the route without `invocation`: renew it for a new ticket (DECISIONS G255).
- When such a route ends, its unused tickets die with it, and its sessions end by cause (DECISIONS
  G260): a revocation or expiry answers each call in flight `NOT_AUTHORISED`; `close_route`, a
  provider stop or shutdown lets calls in flight finish within `stop_deadline_ms` (or the shutdown
  grace), then closes.
- **Built so far (step 4b-2a).** Transported routes are established, renewed and served, but the
  consumer side is not built yet: `materialize` of a transported route fails with `LOGOS_ERR_MODULE`
  ("local transport handles are not built yet"). Use transported routes only for testing until 4b-2b.

### `transport`

The limits of the transport I/O thread (TRANSPORT §5.2, §8.6; DECISIONS I90), which runs only when a
`routing` rule selects `local-transport`. Every field is optional; an absent one keeps its default.

| Field | Meaning | Default |
|---|---|---|
| `frame_limit` | The largest frame this side accepts and the largest it assumes the peer accepts, in bytes; at least 16777216 (TRANSPORT l.380). Raising it raises the buffers below that must hold one maximal frame, unless they are given too. | 16777216 |
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
  intent stays `requested`, nothing runs, and a later update does not start the module: start it
  again (DECISIONS G162, interim). For the orchestration instance, `start` returns `LOGOS_ERR_MODULE`
  (DECISIONS G190, interim).
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
  on success the value is current; a refusal changes nothing and is `LOGOS_ERR_MODULE`. If the module
  gives no valid answer within `apply_deadline_ms` (above; 120 s by default), its configuration is
  unknown: the call returns `LOGOS_ERR_MODULE` and the instance enters `error` with
  `configuration-indeterminate`, and is released once the module's hook returns. Start it again to
  continue; the staged value is still there. A stop or shutdown during an application waits for the
  module's answer. One application runs per instance at a time.
- **Size.** A state whose maximal `get_configuration` response would not fit a 16 MiB frame is refused
  with `LOGOS_ERR_MODULE` and nothing changes: two values near 8 MiB cannot both be kept (DECISIONS
  G233, interim). The state revision never wraps; one step is kept free while a start's or an
  application's promotion is pending (DECISIONS G234, interim).
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
  new instance's first start. Retire the old instance afterwards.

## What the host can expect

- **Runtime identity.** Without `store_dir`, each `logos_runtime_start` gives the Runtime a fresh
  lowercase UUIDv4 as its `runtime_instance_id`. With `store_dir`, the identity is
  `runtime_instance_id` if given, or a UUIDv4 generated when the store is created, kept with the
  store. RUNTIME l.2666-2667 require the host to accept a Runtime-generated id before it is used:
  choosing this format, or a store without `runtime_instance_id`, is that acceptance (DECISIONS G192,
  interim).
- **What `start` waits for.** `start` returns once the Module Loader is bound and then the
  orchestration instance is `ready` (DECISIONS G190, interim; "The Module Loader"). Other modules need not be ready (RUNTIME l.3973-3974), and their later failures do
  not affect it. `start` returns `LOGOS_ERR_NOT_AUTHORISED` if the policy denies starting the
  orchestration instance, `LOGOS_ERR_CANCELLED` if a Runtime Control `shutdown_runtime` was accepted
  first (RUN-0759), and `LOGOS_ERR_MODULE` for any other failure, the startup deadline included, with
  the failure classification in the message. A failed `start` stops and destroys nothing: request
  shutdown, wait for it, then destroy (RUNTIME l.4075-4079).
- **The host cannot interrupt `start`.** Only `request_shutdown` and `wait_for_shutdown` may overlap
  on one handle (RUNTIME l.4082), so a host serializes `start` against both; the startup deadline is
  what bounds `start`. (A `request_shutdown` that overlaps anyway is accepted and `start` returns
  `LOGOS_ERR_CANCELLED`.)
- **Startup defaults belong to the orchestration module.** It applies them only while an instance's
  intent is `uninitialized`, by a conditional `start_module` carrying the `expected_execution_revision`
  that `get_readiness` reports (RUNTIME l.194). It should do so after its `_MODULE_init` returns:
  starting other modules from inside its own init spends its startup deadline on each of them, so one
  slow module could fail `start`. The orchestration instance's own intent is `requested` once the
  bootstrap starts it (DECISIONS G191, interim).
- **Shutdown.** `logos_runtime_request_shutdown` accepts and returns; `logos_runtime_wait_for_shutdown`
  returns `LOGOS_OK`, or `LOGOS_ERR_MODULE` when some realization's cleanup was unresolved or failed
  (DECISIONS G60). Execution intent is kept (RUNTIME §10.2).
- **Static bindings.** `logos_runtime_register_binding` copies the table, so its memory is the host's
  again when the call returns; the code at those addresses must stay loaded, with the signatures
  INTERFACE requires, until `logos_runtime_destroy` succeeds (RUNTIME l.4043, l.4054-4058).
  Registration is closed by the first `start`, even one that fails, and by a shutdown request. A
  binding that no module names is kept, unused, until `destroy`. Every static record must name a
  registered binding, or `start` returns `LOGOS_ERR_INVALID_PARAMS` before anything runs.
- **Calls on one handle.** The host serializes every call on a handle except `request_shutdown` and
  `wait_for_shutdown`, and never overlaps `destroy` with another call (RUNTIME l.3983, l.4082).
  `wait_for_shutdown` from a module callback or a Runtime thread returns `LOGOS_ERR_NOT_READY`
  instead of blocking (RUNTIME l.4083 forbids it; the check is ours).
- **Destruction.** `destroy` succeeds before the first `start`, or once shutdown completed and no
  module code is still running on a Runtime thread; otherwise it returns `LOGOS_ERR_NOT_READY` and
  the handle stays valid, so the host retries. After a `start` that failed, shutdown is requested
  and waited for first.
- **SIGPIPE.** The transport code (chronos 4.4.1, `asyncengine.globalInit`) sets `SIGPIPE` to ignored,
  process-wide, in its module initializer: `liblogos_runtime` runs it in its load-time constructor,
  whether or not any route is ever transported, so every host that loads the library gets it. The
  Runtime's own socket writes never raise `SIGPIPE` either way (`MSG_NOSIGNAL`, `SO_NOSIGPIPE`). A host
  that relies on `SIGPIPE` for its own pipes restores its disposition after loading the library.
- **Threads.** With a `local-transport` rule, the Runtime starts one more thread at `start`, the
  transport I/O thread, and stops it at `destroy`. Without one, no such thread exists.
- **Results.** A result's message and detail stay in the calling thread's storage until that
  thread's next call into the library, or until the thread exits (our reading where RUNTIME l.4086
  is silent); `LOGOS_OK` carries neither.

## Orchestration duties

RUNTIME l.72 defines a Runtime instance as the Runtime engine plus an orchestration module. RUNTIME
is claimed for the engine with the reference orchestration module, `lcn_orchestrator`, wherever a
host names it (logosd will, from Tier 4b step 4b-6; "The reference orchestration module" below;
DECISIONS I94, docs/CONFORMANCE.md). A host that names another module in `orchestration` carries
these duties itself, and the engine does not do them for it:

- **Startup defaults** (RUNTIME l.194). Apply deployment startup defaults only while an instance's
  intent is `uninitialized`, by conditional `start_module` or `stop_module` requests carrying the
  `expected_execution_revision` that `get_readiness` reports.
- **Reconciliation** (l.3774-3776). When it becomes operational, including after a Runtime restart,
  reconcile the retained `requested` intents and schedule the recoveries active policy permits,
  preserving retained origin, retry accounting, lifecycle ordering, current authority and unresolved
  cleanup obligations. The engine resumes nothing on its own ("Persistent Runtime state",
  Resumption).
- **Restart policy** (l.3786-3790). Evaluate the active restart policy and schedule permitted
  recovery through `recover_module`. Disabling automatic restart is a valid policy; an enabled policy
  bounds retry frequency, and its retry accounting survives an orchestration restart and lost
  responses (a lost `recover_module` answer is settled by reading `get_readiness`). An explicit stop
  or a shutdown cancels pending automatic recovery; the engine refuses a recovery prepared before
  either, by the revision guard.
- **Resumption after a permission or authority stop** (l.3801-3804). When required permissions or
  authority become available again, request resumption of the retained intent through
  `recover_module`; a failed resumption is subject to the restart policy.
- **Failure classifications** (l.3756). Treat a classification it does not recognize as an
  unspecified failure, and never derive a restart policy from its spelling.

Stopping or failure of the orchestration module pauses automatic startup and recovery (l.3806).

## The reference orchestration module

`lcn_orchestrator` (`src/logos_core/orchestration/`; DECISIONS I94) is a consumer-only module, linked
into the host, that carries the duties above. Holding the role is the host configuration's doing: its
name confers nothing (RUNTIME l.189-192, DECISIONS G53). It calls only through the Runtime Control
binding it receives at initialization (l.184), never the Module Loader, and runs one thread of its
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
    read (RUNTIME l.194, l.2247, l.2261): an operator's `stop` between the read and the request wins
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
  `get_readiness`; from a failure classification only `cleanup-timeout` (DECISIONS G291), so every
  other classification, known or not, decides alike (RUNTIME l.3756). Its own instance and the Module
  Loader are always left out; every other instance with `requested` intent is the module's, whoever
  its origin is, and keeps that origin (l.3774).
- **Events are hints.** It subscribes to the module-state, execution-state, inventory and
  configuration-state events and re-reads what they name before it decides (l.3427). Every
  `resync_ms` it subscribes anew, drops the old subscriptions and re-reads every instance (l.3428;
  DECISIONS G225), so a lost event delays a decision by at most that long.
- **Recovery and its accounting** (l.3786-3790). A failure seen while the module runs (`error` with
  `requested` intent) starts an episode: recoveries on the backoff, each charged, up to
  `max_attempts`, then the diagnostic "restart attempts exhausted after *n* of *m*" and no more. The
  episode closes once the instance has been `ready` for `stable_ms`, or when its intent changes (a
  stop, a new start). A refused recovery is not an attempt (the next is still spaced); a recovery whose
  answer never arrived is one, counted once, and the module reads before it decides again. Under
  `disabled` a failure is never recovered, and the diagnostic says so once.
- **Resumption is not a retry** (l.3775; DECISIONS G289, amending G193). The module's first decision
  on an instance after it starts resumes it once, uncharged, when it finds it `unloaded`, or `error`
  with no open episode: after a Runtime restart, clean or not, or after a failure while the
  orchestration module was down. An episode still open continues charged, across any restart. Under
  `disabled` every `requested` instance in `error`, the authority included, is resumed once after the
  module starts, and not again.
- **Probes** (l.3801-3804; DECISIONS G288). An instance with `requested` intent that is `unloaded`
  (its start was refused for authority, or a configuration is missing, or a prerequisite was not
  ready) or `error` with `cleanup-timeout` (an enforcement stop that overran its deadline, G291), and a
  start or stop default that was refused, is retried by uncharged probes on the policy's spacing
  (`delay(n)` after the last probe; the package default's under `disabled`), never exhausted. The
  authority's return to `ready` and a `configuration_state_changed` event for the instance bring the
  next probe forward, never closer than `initial_delay_ms` after the last.
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
  `get_readiness` and `recover_module` on every instance, the four events above, and `start_module`
  or `stop_module` with the module as origin for the authority and each default, with those
  instances' execution. `get_self` needs nothing (RUNTIME l.2555).
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
binds as a system service (RUNTIME l.1635-1667; DECISIONS I89). The Loader is the module
`logos_module_loader`, built into the library as a `direct_static` binding. It advertises the two
direct strategies only; a `hosted_dynamic` record is refused with `unsupported-strategy` until the
Module Host exists.

- **Built in, never configured** (BOOTSTRAP l.287; DECISIONS G246, G253). The Runtime's construction
  always establishes, authorizes and binds the Loader, before anything else. Its instance id, module
  name and static binding are all `logos_module_loader`, and they are reserved: a `modules` entry,
  a declaration or `orchestration` that names them makes `create` return `LOGOS_ERR_INVALID_PARAMS`, and so does
  `logos_runtime_register_binding` with that binding id. No configuration, registration or module can
  replace or configure the Loader. The policy is not asked about it: no execution decision and no
  `execute` check is made for it (CAPABILITY AUTHORITY l.343), and its permission settings are the
  constant form every instance has until permission profiles exist.
- **Established first at `start`.** `start` realizes the Loader, checks that its primary contract is
  the pinned Module Loader contract and binds it, and only then realizes the orchestration instance
  through it. A Loader that cannot be established makes `start` return `LOGOS_ERR_MODULE` "the Module
  Loader cannot start: …", after whatever it started has been released.
- **Its own lifecycle** (DECISIONS G246). `stop_module` of the Loader is `LOGOS_ERR_NOT_READY` while
  it owns a realization; owning none, it stops, and every later start of any instance is
  `LOGOS_ERR_NOT_READY`. `recover_module` and `retire_module` of the Loader are `LOGOS_ERR_NOT_READY`.
  Every route to it is `LOGOS_ERR_NOT_AUTHORISED`, and the Loader serves only the Runtime's own call
  (DECISIONS G251), so no module can call it.
- **Answers that are lost** (DECISIONS G252). When a `realize` or `release` call fails or its answer
  is lost, the Runtime asks the Loader's `get_status` whether the realization exists, and releases it
  or completes the stop accordingly. If that answer is lost too, the instance becomes `error`
  (`other`, "the Module Loader's answer was lost and could not be resolved") with its realization
  `unknown`; a stop of it is accepted. An answer that breaks the contract fails the Loader.
- **Loader loss** (RUNTIME l.3813-3825; DECISIONS G249). When the Loader fails (it reports its own
  failure, or answers invalidly), every instance it realized becomes `error` with the classification
  `other` and the reason "its Module Loader failed", its realization `unknown` and its routes failed;
  execution intent is kept, and a `stop_module` of such an instance is accepted (intent cancelled,
  still `error`). Nothing starts again in this Runtime: every start and recovery is
  `LOGOS_ERR_NOT_READY`. The Runtime cannot release what the failed Loader owns, so when it owned
  anything **the host must end its process**: the Runtime writes a diagnostic "termination
  required…", `logos_runtime_wait_for_shutdown` returns `LOGOS_ERR_MODULE` with a message ending "the
  Module Loader failed: the host process must end", and `logos_runtime_destroy` returns
  `LOGOS_ERR_NOT_READY` with the same text. A Loader that fails owning nothing is released, and only
  starts are refused.
- **Shutdown** (RUNTIME l.3847-3864). Every instance the Loader realized is released before the
  Loader. A release still running when the shutdown grace ends makes shutdown complete with
  `LOGOS_ERR_MODULE`; the Loader stays, asked only to release, until that release returns, and
  `destroy` is `LOGOS_ERR_NOT_READY` until then. Keeping the Loader delays no withdrawal: each
  instance's routes and Runtime Control binding end when its stop begins.

## Runtime limits

Every limit of the engine in one place (RUNTIME l.3394-3396 and BCP l.369-370 ask for them to be
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
| overflow call workers (`MaxNestedCallWorkers`) | 64 more, the same way; when calls still wait for `refuseDelay` (1 s) with all 128 busy, the oldest call that has not started completes `LOGOS_ERR_MODULE` "no call worker is available" through its callback (G242) | fixed |
| asynchronous calls prepared and not released (`MaxAsyncCalls`) | 4096; one more is `LOGOS_ERR_MODULE` (INTERFACE l.2041) | fixed |
| evaluation workers and queue (`EvalWorkers`, `EvalQueue`) | 4 threads, 256 waiting | fixed |
| handler passes per operation (`MaxPasses`) | 8; more is an evaluation failure | fixed |
| Runtime Control event workers (`MaxEventWorkers`) | 64 | fixed |
| observation: pages, snapshots, `observe_end` registrations | "Observation", Limits | fixed |
| Runtime Control subscriptions and their queues | "Runtime Control subscriptions", Limits | fixed |
| ended route records kept per consumer | 4096 | fixed |
| committed changes and diagnostics kept for observation | 4096 each | fixed |
| payload depth (`max_payload_depth`) | 128 to 1024, default 1024 | here |
| call records in memory (`call_audit.call_records`) | 1 to 1,000,000, default 4096 | here |
| the Capability Authority's audit records (`audit.records`) | docs/AUTHORITY-POLICY.md | in the policy |
| deadlines | `runtime` (Fields) | here |
| transport aggregates | docs/CONFORMANCE.md, "Transport limits"; set by the Runtime with 10b | fixed |
| the reference orchestration module | "The reference orchestration module", Limits; `resync_ms` in its value | fixed |

## Loaded code

The Module Loader is the ABI caller for every instance but its own: it binds, initializes and
destroys module code (LOADER §6), and the Runtime's bootstrap mechanism does so only for the Loader.
A `direct_dynamic` library, once mapped, stays mapped for the Runtime's life, and a static binding
stays registered until `logos_runtime_destroy`: bindings are never unloaded (DECISIONS I88, deviation
1; TF-03). RUNTIME l.387 requires only that a binding be kept until every context made from it has
been destroyed, and unloading code that a module's own threads or registrations may still reach
would crash the process (l.3838). The cost is one mapping per (hash suite, digest, module) for the
Runtime's life: a host that cycles many distinct artifacts through one Runtime should restart it.

## Under `capability-authority`

- **The authority is part of the library.** `liblogos_runtime` links the Capability Authority (CA
  §1, l.143) and registers its symbol table itself, as binding `logos_capability_authority`: it is a
  Logos-defined system module whose call surface uses reserved names, which a host-registered table
  cannot (DECISIONS I84). A host that registers a binding with that identifier anyway gets
  `LOGOS_ERR_INVALID_PARAMS` from `start`. The Runtime hands the instance its inputs in process
  (RUNTIME l.1681): `policy`, the Runtime identity, the attribute source and the wall clock, keyed by
  its state directory `state_root/<state_assignment>`. The authority keeps its grants, audit and
  policy revision there; the Runtime keeps its identity in `store_dir`, so both name the same Runtime
  across starts.
- **Who starts the authority.** The bootstrap starts the orchestration instance only. Until an
  authority instance is bound, the Runtime answers from rules derived from this configuration, never
  configurable (BCP l.360; RUNTIME l.1635-1650, RUN-0305, RUN-0306, RUN-0311). They name the
  orchestration instance as the only consumer and the authority instance as the only target, and allow:
  - Runtime Control `start_module`, `recover_module` and `get_readiness`;
  - `module_execution` `start` in `direct` mode, with the orchestration instance as origin.

  Nothing else is allowed before the binding. Once the authority is `ready` and passes the binding
  checks (RUNTIME l.1652-1667), every module operation is decided by it, and the derived rules lapse:
  the two never decide the same operation. The authority does not start itself: the reference
  orchestration module starts it when its value names it in `authority` ("The reference
  orchestration module").
- **Fail closed.** While no binding exists, every operation the authority would decide is refused
  with `LOGOS_ERR_NOT_AUTHORISED`, classified as an evaluation failure; nothing falls back to a less
  constrained policy (RUNTIME l.1737-1748, RUN-0050). An evaluation that takes longer than
  `evaluation_deadline_ms` is an evaluation failure too, never a deny.
- **Losing the authority.** When the bound instance stops, fails or loses its notification path, every
  execution it authorized ends (CA l.828): those modules stop, classified as an authority ending,
  with their intent kept. The orchestration and authority instances, authorized by the derived rules,
  keep running. With `recovery: true` the derived rules apply again, so the orchestration instance can
  recover the authority and then the stopped modules (RUNTIME l.1674-1680). With `recovery: false`
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
  decisions, every delivery costs two evaluations on the publishing thread. An explicit deny of a
  subscription at delivery ends it.
- **Grants.** A grant comes from a module that a policy `issue` rule allows, or from the embedding
  host through the authority's protected path. An in-process host reaches the authority with
  `authorityFor(state_root/<state_assignment>)` and calls `issueProtected` and `revokeProtected`
  (`docs/AUTHORITY-POLICY.md`, "Grants"); there is no C export.
- **The attribute source** (BCP l.368). The authority matches policy subjects against facts the
  Runtime keeps for each instance: its id and module name. Direct instances have no signer or
  package, so rules naming those match none of them. A host does not supply the facts.
- **What the Runtime retains about decisions** (RUNTIME l.1756-1760, RUN-0330). The last 4096
  authorization answers, in memory: for each, the consumer, operation, target, decision id, source,
  outcome and the grants it used. They are lost at exit; the authority's own audit is what persists.

## Persistent Runtime state

With `runtime.store_dir`, the Runtime keeps its own persistent state there (DECISIONS I82; RUNTIME
l.3500-3507, l.3775). Without it nothing persists: every `start` is a new Runtime with a fresh
identity, and every configured instance is new.

- **Where it is.** `store_dir` holds `runtime-state.cbor` (one deterministic-CBOR value, format
  `logos-core-nim.runtime-state.v1`), one `cfg-<hash>.cbor` side record per configurable instance
  (its configuration binding and state, up to about 17 MiB), and `lock`. The directory is
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
  RUNTIME l.3783). Processes a module started on its own are outside this evidence.
- **Identity.** A configuration whose `runtime_instance_id` differs from the store's makes `start`
  return `LOGOS_ERR_INVALID_PARAMS`, and nothing is written. A store that is deleted, or replaced by
  another, under a host-chosen `runtime_instance_id` needs a new `runtime_instance_id`: addresses and
  revisions under the old one may already be known elsewhere (DECISIONS G192, interim).
- **What survives a restart.** For each instance: its id, its provider id, the record it was created
  from, its lifecycle state, its failure classification and reason, its execution intent, the
  intent's revision and its origin; for a configurable instance, its configuration binding, state
  revision, current and staged values and their provenance. Also the ids of retired instances with
  the state assignments they keep, and `create_module` keys. A configurable instance whose side
  record is missing or does not hold the binding its record names makes `start` return
  `LOGOS_ERR_MODULE` naming it, and nothing is written. Not kept: routes and their keys (a route id from an earlier run is
  unknown), realizations, authorization answers and the change log. Every execution revision after a
  restart is larger than any the Runtime exposed before (RUNTIME l.3506).
- **Instances and the configuration** (DECISIONS G160, interim).
  - A configured instance the store holds is the same instance while its declaration facts are
    equal: its record, leaving out the artifact's `local_path` and the permissions' `reason` texts,
    which it takes from the configuration. If other facts differ, `start` returns
    `LOGOS_ERR_INVALID_PARAMS` naming the instance, before anything runs: give the changed module a new
    instance id, and retire the old one once it is no longer configured.
  - An id that was retired cannot be configured again, and a state assignment a retired instance
    keeps cannot be given to another instance (`LOGOS_ERR_INVALID_PARAMS`).
  - An instance dropped from the configuration stays known, with its state, until it is retired.
- **Resumption after a restart, and retries after a failure** (RUNTIME l.3775).
  - *Resumption.* At every `start`, the Runtime re-establishes the Module Loader instance and then
    the orchestration instance, each the same way: a retained `requested` intent whose origin is the
    host is resumed, with its revision and origin kept; otherwise (never started, explicitly
    stopped, or requested by a module) the instance is started anew with the host as origin, and a
    diagnostic says so (DECISIONS G191, interim; I89). The Runtime starts nothing else. Any other instance's retained `requested` intent is
    acted on only if the orchestration module resumes it, by `recover_module` (RUNTIME l.3774).
  - *How instances come back.* An instance that was running when the Runtime ended cleanly comes back
    `unloaded`, with its intent. One that was running when the Runtime ended without completing
    shutdown (a crash, a kill) comes back `error` with the classification `other` and the reason "the
    Runtime ended without completing shutdown" (DECISIONS G193, interim). An instance that was already
    `error` keeps its classification.
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
  record, and execution is authorized for that retained origin, not for the caller (l.3540). One
  revision value admits at most one attempt: a repeated or concurrent recovery with it is
  `LOGOS_ERR_INVALID_PARAMS`, so a restart policy counts the recoveries it was answered, or reads
  `get_readiness` when an answer was lost. After an explicit stop, and during shutdown, recovery is
  `LOGOS_ERR_NOT_READY`. `retire_module` removes an instance for good once it is `unloaded` or
  `error`, its intent is not `requested`, nothing of a realization or its cleanup is left, no other
  instance's `requested` intent names it as origin, and the configuration no longer lists it
  (`LOGOS_ERR_NOT_READY` otherwise). A target on another Runtime is `LOGOS_ERR_INVALID_PARAMS`
  (DECISIONS G194, interim). The removal is written before the answer.
- **Retention.** Retiring an instance keeps its state directory and reserves its state assignment:
  retirement is not deletion (BCP l.395). No deletion operation exists yet (DECISIONS G143).
- **Bounds.** At most `MaxInstances` (1024) known instances, retained ones included, for
  `create_module`.

## Observation

What a module sees through Runtime Control's observation methods (DECISIONS I86; RUNTIME §9.3). None
of it is configurable in this file; the limits below are the Runtime's (RUNTIME l.3394-3396 asks for
them to be documented).

- **Lists.** `list_modules` and `list_routes` answer from one snapshot made when the first page is
  asked for, after the method's authority, the filters and each record's visibility; later pages
  come from that snapshot, so an instance created after it does not appear and nothing is reordered
  (l.3404-3413). Every page applies the caller's current authority again: a record it may no longer
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
  (INTERFACE l.1483-1484). Nothing here is persisted.
- **Execution summary.** `get_execution_summary` reports `selection.implementation` as the
  strategy the Module Loader realizes the instance with, `direct_static` or `direct_dynamic`. The
  Loader instance itself, which the Runtime's bootstrap mechanism realizes, reports
  `implementation-specific` (RUNTIME l.212, l.3523-3528; DECISIONS G57, I89). No selection carries
  `package` or `signer` yet.
  `realization` is `current` while the Runtime owns a realization for the instance, a cleanup still
  within its deadline included; `unknown` while a `realize` has not been answered, a bind,
  initialization or cleanup has outlived its deadline (DECISIONS G180), or the Loader's answer about
  the realization was lost or its Loader failed (DECISIONS G246, G252); `absent` otherwise.
- **A realization change is a commit.** When `realization` changes without a lifecycle transition (a
  late cleanup ending, a dynamic bind returning), the instance's execution revision advances and the
  change is persisted (DECISIONS G227, interim). A guarded `start_module`, `recover_module` or
  `retire_module` prepared with the revision read before it is `LOGOS_ERR_INVALID_PARAMS`: read the
  revision again (`get_readiness`, `get_execution_summary`) and retry.
- **Failure text.** A module record carries the failure classification. Its `reason` is the
  Runtime's or the module's own text, cut to 512 bytes. A typed Module Loader error is classified
  `loader-<code>`, `loader-artifact-unavailable` for instance (RUNTIME l.3754), except a failed
  `_MODULE_init`, which is `initialization-failed`; neither carries a `reason`, since the Loader's
  message may name host paths (RUNTIME l.1901-1904). The message stays in the Runtime's diagnostics
  and is not persisted. A failure of the bootstrap mechanism while it realizes the Loader itself is
  `other` (DECISIONS G57). A consumer of
  module records, readiness results, module-state events or execution summaries must treat a
  classification it does not recognize as an unspecified failure and never derive a restart policy
  from its spelling (RUNTIME l.3756): later specs and Tier 4b add classifications.
- **`describe_provider`** returns the call surface validated when the provider was last bound, kept
  after it stops (RUNTIME l.540-541); before any bind it is `LOGOS_ERR_NOT_READY`, once the caller
  holds a `discover` allow for each contract the record expects (otherwise `LOGOS_ERR_NOT_AUTHORISED`,
  which does not say whether it was bound).
- **Permission settings in direct mode.** Every instance has permission settings at revision 1, with
  no permission, `applied` (RUNTIME l.2541): no permission profile is selected, so a replacement that
  names a permission is `LOGOS_ERR_INVALID_PARAMS` (l.2536) and one with `[]` at revision 1 changes
  nothing (DECISIONS G229). `applied` with `[]` claims no containment: direct modules are trusted
  in-process code (SECURITY l.204; RUNTIME l.1622, l.2545). A target on another Runtime is
  `LOGOS_ERR_INVALID_PARAMS` (DECISIONS G228, interim).

### Runtime Control subscriptions

A module subscribes to the Runtime Control events through the binding it received at initialization
(INTERFACE §2.5, applied by l.3837; DECISIONS I86, part 7b). The six event names are accepted;
`permission_settings_changed_event` is never produced (direct mode has constant permission settings,
DECISIONS G229). `configuration_state_changed_event` follows every committed configuration revision,
with the state's summary and never a value.

- **Activation.** `subscribe` asks the event's own decision first, without a subject: a denial is
  `LOGOS_ERR_NOT_AUTHORISED`, as is a name that is not a Runtime Control event. A narrowed allow
  activates the subscription and filters what it receives.
- **What is delivered** (RUNTIME l.3498, l.3732-3735; DECISIONS G161, G226). An event reaches a
  subscriber only while the subscriber may observe its exact subject: an instance event's module and
  instance, a route event's route, provider module and provider. An `inventory_changed` hint also
  needs the matching list method's authority for at least one affected record (l.3419), and carries
  only the collection. Each event is judged when the change is committed and again just before its
  handler runs if the decisions changed meanwhile (a new policy, a revocation, an expiry), so a
  revoked subscriber gets nothing more. Under an authority that issues only single-use decisions, each
  delivery costs an evaluation.
- **When and where handlers run** (DECISIONS G178, interim). After the change is committed and
  persisted, never inside the operation that made it and never on the Runtime thread, so a handler may
  call Runtime Control. The Runtime runs handlers on its own pool of event workers (up to 64 threads,
  started on demand), one handler at a time per subscription, in commit order. Several hints of one
  collection waiting for a busy handler become one.
- **A handler that falls behind loses its subscription** (DECISIONS G225, interim). Each subscription
  queues at most 256 events for its handler (and 256 waiting for an authority's decision); one more
  ends the subscription: its queued events are discarded, nothing more is delivered, and the Runtime
  records the diagnostic "Runtime Control subscription *id* of *instance* lost: its handler fell
  behind (G225)". The subscriber gets no signal: `unsubscribe` of it is `LOGOS_OK`. An observer that
  cannot be sure it saw every event must query (`list_modules`, `list_routes`,
  `get_execution_summary`) and resubscribe, periodically when it cannot rule out a loss (RUNTIME
  l.3425-3428). An `inventory_changed` subscription holds at most one pending hint per collection, so a
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
  deadline, so a handler that does not return in time ends the stop in `error` with
  `cleanup-timeout`, as a call still running does (DECISIONS G180). A subscription never
  unsubscribed is freed when its subscriber's execution attempt ends. Nothing here is persisted.
