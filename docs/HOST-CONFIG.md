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
}

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
; RUNTIME l.3614-3621): lcn.app_module without instance and state_assignment.
; With persistent_state, each created instance gets a fresh state assignment.
lcn.app_declaration = {
  module: tstr .size (1..64),
  implementation: lcn.app_implementation,
  ? primary_contract: logos.schema_commitment,
  ? implements: [* logos.schema_commitment],
  ? requires: [* lcn.app_requirement],
  ? requested_permissions: [* lcn.app_permission],
  ? persistent_state: true,
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

`hosted_dynamic` realization and records that declare module configuration (CONFIG) cannot be
expressed in v1.

### `ordering`

Lifecycle-ordering constraints (RUNTIME §3.7): a `dependent` starts only once its `prerequisite` is
`ready`. Both must be listed instances; a constraint may not name one instance twice, and the
constraints may not form a cycle.

### `declarations`

What a module may create at run time with Runtime Control `create_module` (RUNTIME l.3613-3634;
DECISIONS G55): for each module name, the one accepted declaration, with the fields of a `modules`
entry except `instance` and `state_assignment`. No two declarations name one module. A
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
  `logos-core-nim.runtime-state.v1`), side records later steps add, and `lock`. The directory is
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
  intent's revision and its origin. Also the ids of retired instances with the state assignments they
  keep, and `create_module` keys. Not kept: routes and their keys (a route id from an earlier run is
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
