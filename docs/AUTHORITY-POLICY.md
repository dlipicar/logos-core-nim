# Capability Authority policy: `logos-core-nim.authority-policy.v1`

The Capability Authority (CA §1-§11) decides route, call and grant requests for the Runtime. Its rules
are deployment input (BCP l.360): this page is the format, what each rule means, and how a deployment
runs the authority (BCP l.359, l.368, l.380, l.394-395). The authority is built as the `direct_static`
module `logos_capability_authority` (DECISIONS I84). The host configuration kind that selects it comes
with step 8b; until then the host configuration's `policy` is `allow-all` only (HOST-CONFIG.md).

| | |
|---|---|
| Identifier | `logos-core-nim.authority-policy.v1` |
| Encoding | one Logos deterministic-CBOR value (INTERFACE §4.4), nothing after it |
| Schema | `lcn.authority_policy`, below (`src/logos_core/authority/policy.cddl`) |
| Digest | BLAKE3 of the bytes: a changed digest is a new policy revision |

A policy that does not decode, is not canonical, breaks a rule below or names something that does not
resolve is refused whole: the authority does not start with it, and `replacePolicy` keeps the policy
it has.

## The format

```cddl
; logos-core-nim.authority-policy.v1: the Capability Authority's policy input
; (BCP l.360; DECISIONS I84). One Logos deterministic-CBOR lcn.authority_policy
; value. docs/AUTHORITY-POLICY.md documents each rule.
;
; Every array is a set: strictly ascending by its elements' deterministic-CBOR
; bytes, with no duplicates (CA l.130-138 applied to this input), and non-empty,
; except a method or event list, which permits none of that kind when empty
; (CA l.126). The checks the schema cannot express (order, non-empty arrays, the
; source pattern, bounds, names that resolve, restricted declarations) are
; applied when the policy is loaded (authority/policy.nim).

lcn.authority_policy = {
  format: "logos-core-nim.authority-policy.v1",
  source: tstr .size (1..128),
  ? decision_validity_ms: uint64,
  ? audit: { ? records: uint64 },
  rules: [* lcn.ap_rule],
}

lcn.ap_rule = lcn.ap_allow / lcn.ap_deny / lcn.ap_issue / lcn.ap_revoke / lcn.ap_inspect

lcn.ap_allow = {
  kind: "allow",
  subject: lcn.ap_subject,
  scopes: [* lcn.ap_scope],
  ? commitment: lcn.ap_commitment,
}

lcn.ap_deny = {
  kind: "deny",
  subject: lcn.ap_subject,
  scopes: [* lcn.ap_scope],
  ? code: "scope-denied" / "consumer-denied" / "target-denied",
}

lcn.ap_issue = {
  kind: "issue",
  subject: lcn.ap_subject,
  targets: lcn.ap_target,
  scopes: [* lcn.ap_scope],
  ? max_validity_ms: uint64,
}

lcn.ap_revoke = {
  kind: "revoke",
  subject: lcn.ap_subject,
  targets: lcn.ap_target,
}

lcn.ap_inspect = {
  kind: "inspect",
  subject: lcn.ap_subject,
  ? grants: lcn.ap_target,
  ? audit: lcn.ap_target,
  ? policy_changes: true,
}

; G47 facts. Fields AND, list entries OR; {} matches any Runtime-known instance.
lcn.ap_subject = {
  ? instances: [* tstr .size (1..128)],
  ? modules: [* tstr .size (1..64)],
  ? signers: [* bstr .size 48],
  ? packages: [* tstr .size (1..128)],
}

lcn.ap_target = lcn.ap_subject / "self" / "issued"

lcn.ap_scope = lcn.ap_provider_access / lcn.ap_runtime_control / lcn.ap_module_execution

lcn.ap_provider_access = {
  kind: "provider-access",
  contract: logos.schema_commitment / "capability-authority" / "runtime-control",
  actions: [* lcn.ap_action],
  ? providers: lcn.ap_subject,
  ? access: lcn.ap_access,
}

lcn.ap_action =
  "discover" / "establish-route" / "renew-route" / "call" / "publish-event" /
  "subscribe-event"

lcn.ap_access = {
  ? methods: [* lcn.ap_decl],
  ? publish_events: [* lcn.ap_decl],
  ? subscribe_events: [* lcn.ap_decl],
}

lcn.ap_runtime_control = {
  kind: "runtime-control",
  ? methods: [* lcn.ap_decl],
  ? events: [* lcn.ap_decl],
  ? targets: lcn.ap_subject,
}

lcn.ap_module_execution = {
  kind: "module-execution",
  targets: lcn.ap_subject,
  actions: [* ("start" / "stop")],
  ? modes: [* ("direct" / "local-transport")],
  ? placements: [* ("process" / "sandbox" / "container")],
}

; a declaration root, or a name the contract's pinned schema resolves (only with
; "capability-authority" or "runtime-control")
lcn.ap_decl = bstr .size 32 / tstr .size (1..128)

; logos.capability_authority.commitment_requirements, repeated (test_nimgen)
lcn.ap_commitment = {
  ? request: "retain-root",
  ? response: "retain-root",
}
```

Rules have no order, and every array is a set: the authority sorts nothing it receives. Write each
array in ascending order of its elements' deterministic-CBOR bytes, with no duplicates. The policy is
refused otherwise ("not a set").

| Field | Meaning |
|---|---|
| `source` | `[a-z0-9][a-z0-9._-]{0,127}`. Names the policy in logs; not used for decisions. |
| `decision_validity_ms` | How long an allow from a rule stays valid: 1,000 to 86,400,000 ms, default 3,600,000. An allow from a grant ends at the earlier of this and the grant's `expires_at`. |
| `audit.records` | How many audit records are kept: 1,024 to 1,048,576, default 65,536 (below, "Retention"). |
| `rules` | At least one rule. |

## Rules

**`allow`.** A consumer matching `subject` may do what any of `scopes` covers. An `evaluate` the rule
covers is allowed with `requested_scopes` as `allowed_scopes` and `valid_until` = now +
`decision_validity_ms`. `commitment` adds call-record retention requirements to the decision (the
Runtime's call records, `docs/HOST-CONFIG.md` `call_audit`); the decision's commitment is the union of
the request's, every covering rule's and every supporting grant's.

**`deny`.** A consumer matching `subject` is refused what any of `scopes` covers, with `code` (default
`scope-denied`). Deny overrides allow and every grant: rules have no order, and one matching deny
decides. A deny names no grant and no validity.

**`issue`.** A module matching `subject` may issue grants to targets matching `targets`, for scopes
that some of `scopes` covers, valid for at most `max_validity_ms` (a grant without `expires_at` needs
a rule without `max_validity_ms`). `targets` is a subject or `"self"` (the issuer itself). A caller no
`issue` rule matches is denied `consumer-denied` before anything it names is looked up, so issuance
reveals nothing about other instances (CAP-0262, CAP-0263).

**`revoke`.** A module matching `subject` may revoke grants whose target matches `targets`: a subject,
`"self"` (grants targeting the caller) or `"issued"` (grants the caller issued). A module may always see
the grants it may revoke.

**`inspect`.** A module matching `subject` may read:
- `grants`: grants whose target matches (`get_grant`, `list_grants`), and `"self"` or `"issued"` as for
  `revoke`;
- `audit`: records whose subject matches (`query_audit`); `"self"` is a record whose consumer or
  target is the caller, `"issued"` a record of a grant the caller issued;
- `policy_changes: true`: the policy-change records.

A module no rule lets see something gets `grant-not-found` for it, or an empty result, never an error
that tells it the thing exists.

### Subjects and facts (G47)

A subject is a set of facts that must all match; within one field, any entry matches. `{}` matches
every Runtime-known instance.

| Field | Matches |
|---|---|
| `instances` | the instance id |
| `modules` | the module name |
| `signers` | the exact 48-byte signer public key of the instance's accepted selection |
| `packages` | the package name of the instance's accepted selection |

The facts come from the engine's own registry, not from deployment input and never from a request's
fields: for the consumer, the target, and the instance backing each provider, the module name and the
retained selection (RUNTIME l.3523). The authority reads them over a protected in-process path, not
through Runtime Control (CA l.104) and not through `evaluate` (l.105).

- **Freshness.** Name and selection are fixed for an instance's life (RUNTIME l.3546, l.3621). The
  only change is retirement, which every later evaluation sees: a retired instance is unknown, and a
  request naming it is `invalid-request`.
- **Failure.** When the facts cannot be read, `evaluate` fails `authority-unavailable`; it is never
  a deny (CA l.106).
- **Tier 4.** Direct implementations have no signer or package, so only `instances` and `modules` can
  match them. A rule with `signers` or `packages` matches no direct instance; that is a known absence,
  not a missing fact.
- **Trust.** Rules name exact signer keys, not trust anchors. Changing who is trusted is a policy
  revision, with its own `policy_changed` event.
- **History.** A grant's target and an audit record's subject are matched with the facts as they were
  when the grant or record was made, so a retired address can still be filtered (CA l.78-79). These
  snapshots never authenticate anything (l.80). A failure recorded before the consumer's facts could be
  read carries its instance id alone, which matches no subject naming modules, signers or packages.

### Scope patterns

A pattern covers a requested scope when everything the scope asks for is inside the pattern:

- **`provider-access`.** `contract` is a schema commitment or one of the two symbolic contracts,
  `"capability-authority"` and `"runtime-control"`, resolved to the pinned roots of their mirrored
  schemas. `actions` must hold the requested action. `providers`, when present, must match the
  instance backing the requested provider. `access`, when present, must hold every requested method
  and event root; when absent, any.
- **`runtime-control`.** Runtime Control methods and events, and the instances they target. An absent
  list is any; an empty list is none.
- **`module-execution`.** Starting or stopping instances matching `targets`. `modes` and `placements`
  restrict how; `placements` needs `modes` to be exactly `["local-transport"]`.

**Names and roots.** A method or event is named by its 32-byte declaration root, or by its name for the
two symbolic contracts only. Names resolve when the policy is loaded; an unknown name refuses the
policy. Event names may omit the `_event` suffix.

**Never narrowing.** The authority allows what was asked or nothing; it never answers with less (CA
l.214). As modules see it:
- an `all-runtime-visible` discovery is all or nothing per contract;
- a route asked for with unconstrained `access` is refused whenever the covering rule or grant
  constrains methods or events. Ask for the methods and events you need.

**Restricted declarations** (CA l.898, l.1375-1376; RUNTIME l.1662). Whatever the rules say:
- a `subscribe-event` naming `grant_changed` or `policy_changed` on the authority's contract is
  denied `scope-denied`: those events go only to the Runtime;
- a `call` naming `evaluate` is denied `scope-denied`: only the Runtime evaluates;
- a policy rule naming any of the three is refused at load, and so is a grant scope naming one.

Routes, `discover` and `renew-route` to the authority with unconstrained `access` are ordinary scopes.

**Permission scopes** (CA l.392). No permission profile is selected, so every `permission` scope in
`evaluate` or `issue_grant` fails `unknown-permission`, and its failure record has no `scopes`. Format 1
has no permission patterns: a rule with one does not decode. Tier 4 sends none (permission settings are
empty, RUNTIME l.2541-2543).

## Grants

- **Issuer.** `issuer` is never taken from a request: it is the calling module, or `protected-policy`
  with the `source` the protected issuance gives. Protected issuance and revocation are a Nim call for
  the embedding host (`issueProtected`, `revokeProtected`); their records have no consumer.
- **Validity.** `expires_at` must be in the future. An expired grant supports nothing. The expiry is
  recorded once, at `expires_at`, even when the authority was down then.
- **Revocation** keeps the time and reason. Revoking a revoked grant returns it unchanged and records
  another success. Revoking an expired grant is `grant-not-active`.
- **Use.** A grant supports an evaluation when its target is the consumer, it is active, and one of its
  scopes covers the request. When several do, the decision names the one that lasts longest (no
  `expires_at` first, then the latest, then the lower id) and ends with it. Without a supporting grant
  the deny is `grant-revoked` or `grant-expired` when such a grant would have covered it, else
  `not-granted`.
- **Ids.** `d-` and `g-` ids carry a random prefix drawn at every start, so ids never repeat, even for a
  copied state directory.

## Error codes and the order of checks (TL-04, extended)

The specification assigns 4 of the 16 codes. This order assigns the rest; the first that applies
wins.

| Step | Condition | `evaluate` | `issue_grant` | `revoke_grant` | `get_grant` | `list_grants` | `query_audit` |
|---|---|---|---|---|---|---|---|
| 1 | Wrong caller kind, or `consumer` is not the caller | `not-authorised` | same | same | same | same | same |
| 2 | Queue full, timed out before it ran, or authority closed | `authority-unavailable` | same | same | same | same | same |
| 3 | Form: set order or duplicates, shape, `expires_at` not in the future, limit, cursor, `since > until` | `invalid-request` | `invalid-request` | | | `invalid-request` | `invalid-request` |
| 4 | Another Runtime, or `remote-enrollment` | `unsupported-scope` | same | | | | |
| 5 | A permission scope | `unknown-permission` | same | | | | |
| 6 | Facts unavailable, writes failing, out of ids or room, notification lost | `authority-unavailable` | same | same | same | same | same |
| 6a | No `issue` rule matches the caller | | deny `consumer-denied` | | | | |
| 6b | An unknown consumer, target, instance or provider; package facts that differ | `invalid-request` | same | | | | |
| 7 | Grant unknown or hidden | | | `grant-not-found` | `grant-not-found` | omitted | omitted |
| 8 | Policy refuses | deny: `scope-denied` (restricted), the rule's code, `grant-revoked`, `grant-expired`, `not-granted` | deny: `target-denied` or `scope-denied` | `not-authorised` | | | |
| 9 | State | | | `grant-not-active` | | | |

- A caller the authority does not know (retired) is `not-authorised` for every module method, and
  nothing is recorded.
- `invalid-constraints` is never produced: no permission is known, so constraints are never read.
- Each code and denial has one fixed message, with no ids, paths or policy text.
- Steps 6a and 8 are recorded as denials. Steps 3 to 7 and 9, and step 8 of `revoke_grant`, are
  recorded as failures. Steps 1 and 2 are not recorded.

## Explicit permissions for bootstrap and system services (BCP l.360)

Nothing is allowed by default. A deployment needs at least:

- **The authority's own notifications.** `watch_changes` delivers `observed_change` events from the
  authority instance, so it needs `publish-event` for `observed_change` on its own contract.
- **Module consumers of the authority.** Routes to the authority and calls to the methods each module
  uses. `evaluate`, `grant_changed` and `policy_changed` cannot be granted (above).
- **The orchestration instance.** Runtime Control and module execution for the instance named by the
  host configuration's `orchestration`. Step 8b states the exact rules when the binding lands.

The example below has them, plus an administration console that issues, revokes and inspects, a module
that is refused the authority altogether, and the rule that lets every module see its own grants and
records. It is a test input (`tests/test_authority.nim`): it loads as written.

```cbor-diag
{
  "audit": {"records": 65536},
  "rules": [
    {
      "kind": "allow",
      "scopes": [
        {
          "kind": "provider-access",
          "access": {"publish_events": ["observed_change"]},
          "actions": ["publish-event"],
          "contract": "capability-authority"
        }
      ],
      "subject": {"modules": ["logos_capability_authority"]}
    },
    {
      "kind": "allow",
      "scopes": [
        {
          "kind": "provider-access",
          "access": {
            "methods": [
              "get_grant",
              "issue_grant",
              "list_grants",
              "query_audit",
              "revoke_grant",
              "watch_changes"
            ],
            "subscribe_events": ["observed_change"]
          },
          "actions": ["call", "discover", "renew-route", "establish-route", "subscribe-event"],
          "contract": "capability-authority"
        }
      ],
      "subject": {}
    },
    {
      "kind": "allow",
      "scopes": [
        {"kind": "runtime-control"},
        {
          "kind": "module-execution",
          "actions": ["stop", "start"],
          "targets": {}
        }
      ],
      "subject": {"instances": ["orchestrator"]}
    },
    {
      "kind": "revoke",
      "subject": {"modules": ["admin_console"]},
      "targets": {}
    },
    {
      "code": "consumer-denied",
      "kind": "deny",
      "scopes": [
        {
          "kind": "provider-access",
          "actions": ["call", "discover", "renew-route", "establish-route", "subscribe-event"],
          "contract": "capability-authority"
        }
      ],
      "subject": {"modules": ["untrusted_tool"]}
    },
    {
      "kind": "inspect",
      "audit": "self",
      "grants": "self",
      "subject": {}
    },
    {
      "kind": "issue",
      "scopes": [
        {
          "kind": "module-execution",
          "actions": ["stop", "start"],
          "targets": {}
        }
      ],
      "subject": {"modules": ["admin_console"]},
      "targets": {},
      "max_validity_ms": 86400000
    },
    {
      "kind": "inspect",
      "audit": {},
      "grants": {},
      "subject": {"modules": ["admin_console"]},
      "policy_changes": true
    }
  ],
  "format": "logos-core-nim.authority-policy.v1",
  "source": "example.policy",
  "decision_validity_ms": 3600000
}
```

## Administration

- **Fixed per start.** The policy is read when the authority starts. Starting with a changed digest is
  the next revision, recorded as one policy-change record at that time; the same digest keeps the
  revision.
- **Live replacement.** `replacePolicy` is the only live path, a Nim call for the embedding host. A
  replacement with the same digest changes nothing. Otherwise the revision goes up, the change is
  recorded and made durable, and one `policy_changed` goes to the Runtime.
- **No approval step.** There is no user-facing approval (BCP l.380 does not apply): whoever writes the
  policy decides.

## Limits (BCP l.369)

| Limit | Value |
|---|---|
| Scopes per request | 64 |
| Queued module requests | 1,024; a request not started within 30 s is withdrawn (`authority-unavailable`) |
| Grants kept | 16,384; past it the oldest revoked or expired grant goes, and with all active, issuance is `authority-unavailable` |
| Audit records kept | `audit.records` (default 65,536) |
| Unwritten audit records | 4,096; past it evaluations are `authority-unavailable` until the backlog is written |
| Watches | 64, 8 per consumer, 256 queued notifications each |
| `list_grants` | default 100, at most 1,000 per page; a cursor lives 600 s and dies at restart |
| `query_audit` | at most 1,000 records |
| A response | at most 15 MiB; a longer list is cut, with a cursor |

## State

**Where it lives.** The authority's state is its instance's state assignment (under the host's
`state_root`), not the Runtime store. A replacement authority instance gets a fresh assignment and
starts with no grants (RUNTIME l.3549).

| File | Content | Written |
|---|---|---|
| `lock` | held while the authority runs: a second authority on the directory does not start | at start |
| `meta.cbor` | format, Runtime id, authority contract root, policy digest, revision and time, the audit floor, the last 64 policy-change records | at start, at a policy change, when a segment is dropped |
| `grants/<grant id>.cbor` | the grant, its target's facts, and its issue, revoke and expiry records | before each change takes effect |
| `audit/<16 hex>.cbor` | up to 256 other records, from the named sequence number | within a second |

- **Durability.** A grant change or policy change is on disk before it takes effect, before its event
  and before the reply. Evaluation records are written within a second, so a crash can lose up to a
  second of them (CA l.1169: storage is deployment policy).
- **A failed write** fails the change with `authority-unavailable` and nothing applied; evaluation keeps
  answering. The next change tries again.
- **Protection at rest.** Owner-only directories (0700) and files (0600); no encryption. A directory
  others can read refuses to start.
- **Refusal to start**, with every file left as it is: state from another Runtime, written under
  another authority contract, in an unknown format, or a file that does not decode.
- **Contract replacement** (CA l.757-761). State carries the contract root it was written under. A
  different contract does not start, and Tier 4 has no migration: keep the old directory for its
  records.
- **Backup and rollback** (BCP l.394). Back up `state_root` and the Runtime store together, with the
  Runtime stopped. Restoring an older directory brings back every grant revoked since the backup, so
  never restore across a revocation.
- **Retention is one count** (U6). `audit.records` bounds all consumers together, and the oldest go
  first, in whole segments: one consumer's evaluations can push others' evaluation records out (CA
  l.1352 assumes otherwise). Grant records stay with their grant until the grant itself goes.
- **Retirement is not deletion** (BCP l.395). A retired instance's grants and records stay until
  retention removes them, and queries can still name its address.

**Call records** are made and kept by the Runtime, not the authority (CA l.1329-1330): `query_audit`
returns only the authority's records. Step 8b says where call records are read.

## `watch_changes`

- **Who.** A module, watching as itself: `consumer` is its own address. A `SYSTEM_SERVICE` caller, or
  a `consumer` naming another instance, is `not-authorised`. A watch is not audited: it changes
  nothing.
- **How to call it.** Asynchronously, and cancel it to end it: a synchronous call blocks the calling
  thread until the watch ends. Activate the `observed_change` subscription on the same route first. A
  change before the watch is registered is not delivered.
- **What arrives.** One `observed_change` per change the watcher may see under the policy and facts at
  that change: a grant it may inspect (an `inspect.grants` rule, or a `revoke` rule for the grants it
  issued), whole; a policy change only with `inspect.policy_changes`, with `changed_at` and both
  revisions and never `affected_executions`. It is published in the watch's invocation scope, so only
  the route the watch was called through receives it. Two equivalent watches get the same bytes; there
  is no watch id.
- **No snapshot.** There is no readiness signal: read the current state with `list_grants` and
  `query_audit` after the watch starts.
- **How it ends.** Cancellation (seen within 50 ms, with or without changes), the authority stopping,
  or its route ending gives `{}`. A watch that falls 256 changes behind ends with
  `authority-unavailable`; what it already delivered stays delivered. Ending a watch revokes nothing.
- **Limits.** 64 watches, 8 per consumer: past either, `watch_changes` answers `authority-unavailable`
  at once. A watch never holds up evaluation or the engine's notifications.

## Running the authority

The module is `logos_capability_authority`, a `direct_static` binding of the same name
(`caStaticRegistration()`), with a state assignment. The embedding host wires each instance before
starting it (RUNTIME l.1681, l.3075-3077): `wireAuthority(stateDir, wiring)` with the policy bytes, the
Runtime id, the facts table, the clock and the limits, keyed by the instance's state directory. An
instance without wiring does not start (MODULE_ERROR). The wiring stays until `unwireAuthority`, so a
stopped instance starts again on the same state. Step 8b does this from the host configuration.
