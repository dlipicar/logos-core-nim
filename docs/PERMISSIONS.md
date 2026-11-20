# Permissions: the profile, its definition, and what is enforced

A module instance reaches operating-system and platform access only through permissions. A
permission is a name that a selected **permission profile** defines, with one deterministic-CBOR
**constraints** value its definition's CDDL admits (CA §3.5 l.383-388). This page is the
deployment document for the profile this repository ships (CA l.388, l.404; BCP l.369), and for how
the Runtime applies an instance's permission settings (RUNTIME §9.3 l.2450-2532). DECISIONS I93
records how it is built; G110, G279, G280 and G283 record the choices.

## The profile

| | |
|---|---|
| Identifier | `logos-core-nim.permission-profile.v1` (G279) |
| Selected by | the host, in protected configuration: `app-config.v1` `permissions.profile` (`docs/HOST-CONFIG.md`, `permissions`); logosd always selects it (step 4b-6) |
| Definitions | one: `logos-core-nim.host-ambient` |
| Minimum | `logos-core-nim.host-ambient`: every realization's settings must hold it (G110) |

With no profile selected, no permission is defined: the Capability Authority answers every
permission scope `unknown-permission`, and the Runtime keeps the constant form of permission settings
(`docs/HOST-CONFIG.md`, "Permission settings in direct mode"; G229).

The minimum is not CA l.341's "every required permission scope": under the interim of G217 an
execution decision covers every permission the instance's saved settings name, and the minimum is
what the settings themselves must hold before the Runtime asks for that decision.

## `logos-core-nim.host-ambient`

| | |
|---|---|
| Name | `logos-core-nim.host-ambient` (D25, G110) |
| Constraints | the empty map, `lcn_permissions.host_ambient = {}` (`src/logos_core/permissions/host_ambient.cddl`, a supporting schema); its only value encodes as `0xa0` |
| Containment (CA l.132) | equality of the decoded value: `0xa0` contains `0xa0` |
| Facility classes (CA l.396-402) | all seven: network, filesystem, persistent state, process, device, resources, placement |
| Enforcement component (CA l.404) | Runtime admission: the Runtime refuses to ask the Module Loader to realize an instance whose settings lack it, or whose execution decision does not allow it (G110, as revised 2026-11-13) |
| When it cannot be enforced (CA l.360, l.415) | the operation fails: the start or recovery is refused |
| When it is revoked (CA l.945-946) | the Runtime stops the execution form; intent and its origin are kept (RUNTIME l.3663) |
| Containment claim (CA l.362) | none |

**What it means.** host-ambient stands for the access an in-process module has anyway: whatever the
host process may do. Granting it grants all of it. No per-class limit can be expressed: the
constraints are the empty map, so a profile entry for "network only" or "this directory only" does
not exist here (G283). A module in a direct implementation runs in the host's address space, so
nothing between the module and the host's facilities could hold such a limit (SECURITY l.203-205).

**What is not enforced.**
- No per-class or per-resource limit, no sandbox, container or operating-system enforcement (outside Tier 5:
  DECISIONS D16).
- No per-module device restriction: the profile claims none, so CA l.406-407 do not apply (CAP-0292,
  CAP-0293).
- No permission is enforced by a module provider (CA l.417-420 do not apply, G286).
- The Module Loader enforces nothing of its own (G280): it receives no decision, grant or settings.

## In policy

The Capability Authority gets the same profile through its wiring. A policy rule names a permission
with a `permission` pattern (`docs/AUTHORITY-POLICY.md`, "Scope patterns"), and a start is allowed only
by one rule, or one grant, holding its execution scope and every permission scope (G207, amended
2026-11-14). An undefined name or constraints that do not conform refuse the policy; in a request
they are `unknown-permission` and `invalid-constraints`. A grant naming a permission the selected
profile no longer defines, while it is active, keeps the authority from opening (fail closed).

## An instance's settings

While a profile is selected every module instance has its own **permission settings**: a complete,
ascending array of permissions with their constraints, a positive `revision`, and an application
status, `pending`, `applied` or `failed` (RUNTIME §9.3 l.2450-2532; DECISIONS I93). They are saved in
the instance's `prm` side record before any reply that reports them, and survive restarts. What the
host sees of them is in `docs/HOST-CONFIG.md`, "Permission settings with a profile"; the rules are:

- **Initial settings** (l.2468-2470; G110). The host provisions them in `permissions.initial`, by
  instance or by module; otherwise an instance starts with none (revision 1, `[]`, `applied`). A
  module's declaration (`requested_permissions`) never supplies them: it is what the module asks for,
  not what it is given. The Module Loader's settings are its construction's: the profile's minimum
  (G253).
- **Replacement** (l.2510-2516). `update_permission_settings` replaces the whole array at the expected
  revision. It is checked first (ascending, defined, conforming; RUN-0892), then saved, then
  reconciled. Settings authority is its own: it starts nothing and changes no intent (l.2508,
  l.2521).
- **Reconciliation: stop, then recovery** (l.2518-2529; G281). A direct module runs in the host
  process, so its access cannot be changed while it runs: every replacement of a running instance,
  widening or narrowing, stops it, keeping its execution intent and origin and with no failure
  classification (RUN-0914, RUN-1066). The settings are `pending` until nothing of the realization
  is left, then `applied`; the next admission enforces them, and orchestration resumes the instance
  by `recover_module`, decided for its retained origin with the new settings (l.2524, l.2526). An
  instance that is not running applies a replacement at once.
- **`failed`** (l.2519-2520; G281, G285). The settings are `failed`, with `failure:
  "enforcement-failed"`, when the stop passes its deadline (the old realization may persist with the
  old access), when a replacement arrives while such a realization may persist, and when a named
  permission is one no active point enforces (G280). The instance stays stopped: admission refuses it
  until a replacement is accepted, and the late end of the old cleanup restores nothing.
- **Restart** (l.2471, l.2518). Settings come back with their revision and status. No realization
  survives the process, so `pending` settles as the Runtime opens. A hosted instance whose Module
  Host of the previous run may still be running (its restart lock is held, G275) is the exception:
  its `pending` settings stay `pending` until the lock is taken, and then settle and are published. A
  store whose settings the selected profile cannot read (no profile, or an undefined permission) is
  refused: accepted settings are never dropped silently.

## Admission and the snapshot

The Runtime enforces host-ambient at admission, the one point it controls (G110, G284):

1. **Before any decision**, a start or recovery is refused `NOT_AUTHORISED` when the instance's
   settings are `failed` (classification `permission-enforcement-failed`) or lack the profile's minimum
   (`authority-denied`; l.2465). No authority is asked; a diagnostic names what is lacking.
2. **The execution decision** covers the execution scope and one permission scope per saved setting,
   as one set (CA l.339-341; G217). Under `capability-authority` one allow rule or one grant must hold
   all of them (G207). An allowed permission scope may be narrower than the one asked for; one
   broader, missing, or not asked for is an evaluation failure (CA l.560-561; CAP-0068, CAP-0084).
3. **The snapshot.** What the decision allowed is installed for that realization, and
   `get_execution_permissions` answers it (RUNTIME l.2491-2504; G282): the saved settings, or the
   narrower constraints the authority allowed, never the declaration. A replacement does not touch a
   running realization's snapshot (it stops the realization); a renewal that narrows an installed
   permission ends the execution like a denial.
4. **Revocation** (CA l.945-946). A revoked grant or a policy change that ends the execution
   authorization stops the instance (`authority-revoked`), intent and origin kept (CAP-0192,
   RUN-1066). `pending` is no grace period (RUNTIME l.2529).

Without a profile none of this runs: the decision carries the execution scope alone, and
`get_execution_permissions` is `unavailable`.

## Hosted instances

A `hosted_dynamic` instance runs in a Module Host process of its own (`docs/HOST-CONFIG.md`,
`module_host`; DECISIONS G264), and the same rules hold, with the Runtime still enforcing at
admission (DECISIONS I93, part 4b-4c):

- **Admission** (CA l.345-349; CAP-0065, CAP-0066). The Runtime refuses a start before the Loader is
  asked to realize the host's process, exactly as above. The execution decision's execution scope
  names the mode `local-transport` and the placement `process` (G272), beside the permission scopes.
  `process` is the only placement in 4b; a decision allowing a sandbox or a container is an
  evaluation failure.
- **The snapshot.** A module in a host calls `get_execution_permissions` through its own Runtime
  Control binding and gets its realization's snapshot, as in process.
- **Reconciliation.** A replacement stops the hosted instance; its host is released and ends, then
  the settings are `applied`.
- **A stop past its deadline** (G269, G285). The Runtime ends the host by force: `cleanup-timeout`
  is recorded and the host's process group is killed. The old access ends with the process, so the
  settings stay `pending` until that end is confirmed and then become `applied`. The instance stays
  `error` (owner batch C 13), and orchestration resumes it on the settings event. The same holds at
  the shutdown grace and after the Module Loader's loss.
- **A host nothing ends.** When a release fails and the Loader still holds the realization
  (`cleanup-failed`), or an answer is lost while the Loader stays bound, the host may live on with its
  old access, as a direct realization may. The settings are then `failed`.
- **Not enforced in 4b.** The host is a separate address space, not a sandbox: it gets the same
  operating-system access as any process of the Runtime's user, so host-ambient means the same thing
  there (SECURITY l.207-210). No constraint crosses to the Loader or the host (G280). Sandbox,
  container and operating-system enforcement are outside Tier 5 (DECISIONS D16).

## A trap

An authorized `update_permission_settings` that removes host-ambient from the orchestration or the
authority instance stops it, and every later bring-up then fails `NOT_AUTHORISED` until the settings
are replaced. The library leaves this to the host's policy: grant no module the administration of
system instances' settings. logosd's default policy will not (step 4b-6).

## What BCP asks to be documented

- *The explicit permissions needed by deployed bootstrap and system-service integrations* (BCP
  l.365): host-ambient, for the orchestration instance and, under `capability-authority`, the
  authority instance; `create` refuses a configuration that does not provision them
  (`docs/HOST-CONFIG.md`, `permissions`). The Module Loader holds it by construction.
- *Permission definitions, constraint mappings, and the component that enforces each constraint*
  (BCP l.369): the table above; host-ambient's constraints are the empty map, and Runtime admission
  enforces it.
