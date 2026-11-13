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
}

lcn.app_runtime = {
  work_dir: lcn.app_path,
  ? state_root: lcn.app_path,
  ? store_dir: lcn.app_path,
  ? runtime_instance_id: tstr .size (1..128),
  ? startup_deadline_ms: uint32,
  ? stop_deadline_ms: uint32,
  ? shutdown_grace_ms: uint32,
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
  contract (otherwise the realized one is checked when the instance is bound); it has a
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
- **Size.** A state whose maximal `get_configuration` response would not fit a 16 MiB frame is refused
  with `LOGOS_ERR_MODULE` and nothing changes: two values near 8 MiB cannot both be kept (DECISIONS
  G233, interim). The state revision never wraps; one step is kept free while a start's promotion is
  pending (DECISIONS G234, interim).
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
- **What `start` waits for.** `start` returns once the orchestration instance is `ready` (DECISIONS
  G190, interim). Other modules need not be ready (RUNTIME l.3973-3974), and their later failures do
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
- **Results.** A result's message and detail stay in the calling thread's storage until that
  thread's next call into the library, or until the thread exits (our reading where RUNTIME l.4086
  is silent); `LOGOS_OK` carries neither.

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
  the two never decide the same operation. The authority does not start itself.
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
  - *Resumption.* At every `start`, the Runtime re-establishes the orchestration instance: a retained
    `requested` intent whose origin is the host is resumed, with its revision and origin kept;
    otherwise (never started, explicitly stopped, or requested by a module) the orchestration
    instance is started anew with the host as origin, and a diagnostic says so (DECISIONS G191,
    interim). The Runtime starts nothing else. Any other instance's retained `requested` intent is
    acted on only if the orchestration module resumes it, by `recover_module` (RUNTIME l.3774).
  - *How instances come back.* An instance that was running when the Runtime ended cleanly comes back
    `unloaded`, with its intent. One that was running when the Runtime ended without completing
    shutdown (a crash, a kill) comes back `error` with the classification `other` and the reason "the
    Runtime ended without completing shutdown" (DECISIONS G193, interim). An instance that was already
    `error` keeps its classification.
  - *Resuming is not a retry.* Bringing an instance back after a restart, clean or not, is a
    resumption: it counts as no restart attempt against any restart policy. A restart policy counts
    the `recover_module` calls made after the instance failed while the Runtime was running.
  - *No policy in the Runtime.* The Runtime itself never restarts anything, and logos-core-nim ships
    no orchestration module that does yet.
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
- **Execution summary.** `get_execution_summary` reports `selection.implementation` as
  `implementation-specific`: the in-process realizer is not a Module Loader instance (RUNTIME
  l.3527-3528; DECISIONS G230, interim), and no selection carries `package` or `signer` yet.
  `realization` is `current` while the Runtime owns a realization for the instance, a cleanup still
  within its deadline included; `unknown` while a Module Loader bind is unresolved or a bind,
  initialization or cleanup has outlived its deadline (DECISIONS G180); `absent` otherwise.
- **A realization change is a commit.** When `realization` changes without a lifecycle transition (a
  late cleanup ending, a dynamic bind returning), the instance's execution revision advances and the
  change is persisted (DECISIONS G227, interim). A guarded `start_module`, `recover_module` or
  `retire_module` prepared with the revision read before it is `LOGOS_ERR_INVALID_PARAMS`: read the
  revision again (`get_readiness`, `get_execution_summary`) and retry.
- **Failure text.** A module record carries the failure classification. Its `reason` is the
  Runtime's or the module's own text, cut to 512 bytes; a Module Loader failure carries none, since
  its message may name host paths (RUNTIME l.1901-1904).
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
