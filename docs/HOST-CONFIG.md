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
; express (unique ids, ordering, the orchestration instance) are applied at
; logos_runtime_create (runtime/host_config.nim).

lcn.app_config = {
  runtime: lcn.app_runtime,
  policy: lcn.app_policy,
  orchestration: lcn.app_instance_id,
  modules: [* lcn.app_module],
  ? ordering: [* lcn.app_ordering],
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

lcn.app_policy = { kind: "allow-all" }

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
and observation requests, including those of the bootstrap. v1 has one kind:

- `allow-all`: every request a module makes through its Runtime Control binding is allowed. This is
  the internal policy RUNTIME l.1633 permits "for local trusted deployments": use it only when every
  configured module is code the host trusts with the whole Runtime. It must be written explicitly;
  nothing is allowed by default (RUNTIME l.1674, l.1682).

Other kinds are rejected with "this policy kind is not supported yet". An external
`logos_capability_authority` provider arrives with the Capability Authority module.

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
- **Retention.** Retiring an instance keeps its state directory and reserves its state assignment:
  retirement is not deletion (BCP l.395). No deletion operation exists yet (DECISIONS G143).
- **Bounds.** At most `MaxInstances` (1024) known instances, retained ones included, for
  `create_module`.
