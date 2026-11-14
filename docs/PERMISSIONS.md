# Permissions: the profile, its definition, and what is enforced

A module instance reaches operating-system and platform access only through permissions. A
permission is a name that a selected **permission profile** defines, with one deterministic-CBOR
**constraints** value its definition's CDDL admits (CA §3.5 l.387-392). This page is the
deployment document for the profile this repository ships (CA l.392, l.406; BCP l.364), and for how
the Runtime applies an instance's permission settings (RUNTIME §9.3 l.2526-2604). DECISIONS I93
records how it is built; G110, G279, G280 and G283 record the choices.

## The profile

| | |
|---|---|
| Identifier | `logos-core-nim.permission-profile.v1` (G279) |
| Selected by | the host, in protected configuration: `app-config.v1` `permissions.profile` (`docs/HOST-CONFIG.md`); logosd always selects it (step 4b-6) |
| Definitions | one: `logos-core-nim.host-ambient` |
| Minimum | `logos-core-nim.host-ambient`: every realization's settings must hold it (G110) |

With no profile selected, no permission is defined: the Capability Authority answers every
permission scope `unknown-permission`, and the Runtime keeps the constant form of permission settings
(`docs/HOST-CONFIG.md`, "Permission settings in direct mode"; G229).

The minimum is not CA l.345's "every required permission scope": under the interim of G217 an
execution decision covers every permission the instance's saved settings name, and the minimum is
what the settings themselves must hold before the Runtime asks for that decision.

## `logos-core-nim.host-ambient`

| | |
|---|---|
| Name | `logos-core-nim.host-ambient` (D25, G110) |
| Constraints | the empty map, `lcn_permissions.host_ambient = {}` (`src/logos_core/permissions/host_ambient.cddl`, a supporting schema); its only value encodes as `0xa0` |
| Containment (CA l.129) | equality of the decoded value: `0xa0` contains `0xa0` |
| Facility classes (CA l.398-404) | all seven: network, filesystem, persistent state, process, device, resources, placement |
| Enforcement component (CA l.406) | Runtime admission: the Runtime refuses to ask the Module Loader to realize an instance whose settings lack it, or whose execution decision does not allow it (G110, as revised 2026-11-13) |
| When it cannot be enforced (CA l.364, l.417) | the operation fails: the start or recovery is refused |
| When it is revoked (CA l.915-916) | the Runtime stops the execution form; intent and its origin are kept (RUNTIME l.3801) |
| Containment claim (CA l.366) | none |

**What it means.** host-ambient stands for the access an in-process module has anyway: whatever the
host process may do. Granting it grants all of it. No per-class limit can be expressed: the
constraints are the empty map, so a profile entry for "network only" or "this directory only" does
not exist here (G283). A module in a direct implementation runs in the host's address space, so
nothing between the module and the host's facilities could hold such a limit (SECURITY l.203-205).

**What is not enforced.**
- No per-class or per-resource limit, no sandbox, container or operating-system enforcement (Tier 5).
- No per-module device restriction: the profile claims none, so CA l.408-409 do not apply (CAP-0292,
  CAP-0293).
- No permission is enforced by a module provider (CA l.419-422 do not apply, G286).
- The Module Loader enforces nothing of its own (G280): it receives no decision, grant or settings.

## In policy

The Capability Authority gets the same profile through its wiring. A policy rule names a permission
with a `permission` pattern (`docs/AUTHORITY-POLICY.md`, "Scope patterns"), and a start is allowed only
by one rule, or one grant, holding its execution scope and every permission scope (G207, amended
2026-11-14). An undefined name or constraints that do not conform refuse the policy; in a request
they are `unknown-permission` and `invalid-constraints`. A grant naming a permission the selected
profile no longer defines, while it is active, keeps the authority from opening (fail closed).
