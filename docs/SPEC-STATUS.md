# Spec status: what is built against which open item

The specs are logos-lips `draft/logos-core-module-specs` at `f4f83471` (the `logos-lips` flake input).
The spec owner is revising them after four reports in `docs/logos-core/discussion/` of logos-lips:
`claude-spec-comments.md` (C-, CM-, IF-, EC-, TR-, RT-, CA-, PM-, SO-), `human-spec-comments.md`
(HC-), `claude-spec-comments-2.md` (NX-, NE-, NI-, NL-, NA-, NR-, ND-, NP-, NC-, NS-, NO-, NF-) and
`module-port-gaps.md`. Work is ordered so the parts least likely to change are built first.

## Tiers

| Tier | Area | Verdict |
|---|---|---|
| 1 — build now | Deterministic CBOR (INTERFACE §4.1–4.4, cdCDDLe §9), BLAKE3, cdCDDLe, HASH layout and payloads, COMMITMENT schema model and identity | Safe. No item changes det-CBOR rules or cdCDDLe bytes of existing constructs, and no normative vector is reported wrong. The risky rules (CM-01/G1, CM-02/G2, CM-04/G7, CM-05/G8, CM-07, G9) each live in one named proc with an `[IMPL-DECISION]` test. |
| 2 — build now, types only | INTERFACE §1 schema conventions, §4.5/§5.3 validation, §4.6 outcomes, §5.1 common schema, call surface; C type mapping §2.1–2.3, §2.5, §2.7, §3.9 forward cases | Safe for schema handling. Generated C is stamped provisional; no `_dispatch`/`_destroy`/export set. |
| 3 — build now, sans-I/O | TRANSPORT §1, §2, §4.1, §6, §7, §8.1, §8.3; PM §4 manifest, §4.1 trust input, §4.3 COSE_Sign1/Ed25519, §7.1 LGX | Codecs and state machines are safe when generated from the mirrored CDDL. No sockets, fetch or catalog. |
| 4 — after the revision | RUNTIME engine, RC, stop/shutdown; LOADER; CONFIG; CA | Registry, persistence, workers and direct routes are stable; the stop sequence, authorization point and handle-to-session model are likely redesigned. |
| 5 — blocked | PM fetch/catalog/storage role; logosctl/logosd; payload modules; module host; reverse mapper; QUIC/Nix/SLSA; mobile/Windows | Wait for the revision. |

Three spec facts drive the order:

1. Pinned values ripple. Every imported reference commits to the whole common-schema root
   (COMMITMENT l.657, l.705), and the hash-profile and commitment-model ids are literals inside
   `logos.schema_commitment` (INTERFACE l.2401-2406). Any common-type addition, error-code value or
   profile bump changes the common root, the nine subtree roots in COMMITMENT §5, both PM manifest roots
   and every contract root that imports a common type. So every pinned value lives in
   `spec/pins.toml` and is recomputed from `spec/mirrors/`, never typed into code.
2. The init struct and both vtables are append-only (INTERFACE l.2769, l.2780-2784), so many fixes are
   additive. `_dispatch`, typed method functions, `_destroy` and `logos_publish_fn` are not versioned,
   and several reports target exactly those.
3. Transport envelope maps are closed (TRANSPORT l.124-126, l.1167): any field addition breaks old
   peers, so the envelope codec is generated from the mirrored CDDL.

## When a spec revision lands

1. Bump the `logos-lips` input (`nix flake update logos-lips`), or point it at a revision.
2. `spectrace sync --specs <raw dir>` lists added, changed and retired requirement IDs per section.
3. `spectrace mirror` and `spectrace pins` fail where CDDL or pinned values changed; review the diff,
   run `spectrace mirror --write`, re-copy the pins, and let the recompute tests confirm.
4. Walk the rows below (settled / changed / still open) and update `docs/DECISIONS.md`.
5. Re-tier what is left and report before continuing.

## Columns

- **Milestones** are those of the original full plan (M0 foundations … M13 live acceptance). The tier is
  the earliest tier any of them falls in (M1 → 1, M2 → 2, M5/M7 → 3, M3/M4 → 4, later → 5); an item
  can also matter to later tiers.
- **Risk** rates what changes if the owner settles the item differently from our interim choice:
  HIGH = bytes, roots, the C ABI or a core rule; `-n` = small blast radius; `-c` = only if another fix
  lands. "=s" in the note means our interim choice already equals the suggested fix.
- **Code / test** points at the isolated rule once it exists.
- **Status**: `open`, `settled by spec text (…)`, `resolved in <rev>`, or `changed in <rev>`.

## Counts

| Tier | Items | HIGH |
|---|---|---|
| 0 | 4 | 0 |
| 1 | 34 | 15 |
| 2 | 41 | 12 |
| 3 | 62 | 6 |
| 4 | 58 | 1 |
| 5 | 18 | 2 |
| all | 217 | 36 |

## Tier 0 — foundations

| ID | Report | Spec §§ | Milestones | Risk | Likely fix, interim choice | Code / test | Status |
|---|---|---|---|---|---|---|---|
| C-12 | claude-spec-comments | BCP §1 vs §5.3; RUNTIME §9 | M0,M3,M4 | MED | If audit/evidence types move namespace, their roots and evidence bytes change. | — | open |
| GN-01 | claude-spec-comments | all | M0 (all) | LOW | Editorial. | — | open |
| NX-05 | claude-spec-comments-2 | RUNTIME References; BCP §1 | M0, M3 | LOW | Additive: Y. Add normative references. The "move shared records into RUNTIME" option would rename them, changing their C names and roots. | — | open |
| SO-10 | claude-spec-comments | mirrors; cdCDDLe §12 | M0,M1 | LOW | Published vectors would expose any CM-xx divergence. | — | open |

## Tier 1 — encoding, hashing, commitments

| ID | Report | Spec §§ | Milestones | Risk | Likely fix, interim choice | Code / test | Status |
|---|---|---|---|---|---|---|---|
| NC-05 | claude-spec-comments-2 | HASH §5, §6.1 l.506-509; cdCDDLe §5.1; CA §4, §9, §13 | M1, M2, M4 | HIGH | Additive: P [REV]. `sensitive` marker with salted commitments and zeroization (touches the HASH algorithm and the model). The per-method no-retain option would be LOW. | — | open |
| ND-01 | claude-spec-comments-2 | INTERFACE §1.7, §5.1; BCP §5.3 | M1, M2, M8 | HIGH | Additive: Y [CR]. `logos.uint256` or `logos.decimal_uint` common type. A native scalar kind would be [REV]. | — | open |
| ND-04 | claude-spec-comments-2 | cdCDDLe §5.1, §9; COMMITMENT l.1295-1296 | M1, M2 | HIGH | Additive: Y [REV?]. Bounded arrays `[n*m T]`. The cdCDDLe occurrence node already carries min/max (cdCDDLe l.496-500). | — | open |
| ND-05 | claude-spec-comments-2 | cdCDDLe l.171; COMMITMENT; HASH §5 | M1, M2, M10 | HIGH | Additive: Y [REV]. Typed `{*K=&gt;V}` maps: new model kind and a keyed HASH layout. The association-list option only adds a validator rule. | — | open |
| ND-06 | claude-spec-comments-2 | INTERFACE l.425, §5.1; HASH §4 | M1, M2 | HIGH | Additive: Y [CR]/[REV]. `bstr .cbor T` and/or `logos.json_text`. | — | open |
| ND-08 | claude-spec-comments-2 | INTERFACE l.97, l.111-112; COMMITMENT l.352-353 | M1, M2, M8, M10 | HIGH | Additive: Y [REV?]. New import forms between contracts; existing schemas are unchanged. COMMITMENT l.745 names "add import forms" as a revision trigger. | — | open |
| NR-08 | claude-spec-comments-2 | TRANSPORT §2, §5, §7, §8.4.2; INTERFACE §5.1 l.2479-2484 | M1, M2, M5, M11 | HIGH | Additive: N [CR]. New value in the closed error-code set; overload rejection without closing the connection; limits; second QUIC stream. | — | open |
| C-01 | claude-spec-comments | COMMITMENT §5 l.697 vs INTERFACE §1.1/§5.3, BCP §6.1 | M1,M2 | LOW | Only changes what the parser accepts; roots unaffected. =s | — | open, narrowed (NF-01) |
| C-02 | claude-spec-comments | COMMITMENT §3.1 vs INTERFACE §2, §3.8 | M1,M2,M10 | LOW | Affects only names we already reject. =s | — | open |
| CM-01 | claude-spec-comments | COMMITMENT §8, §9.2; HASH §7.3 | M1 | **HIGH** | Value roots through alias chains. poc2 does the opposite (outermost). cl l.183-188 | `commitment/normalize.nim` `throughLocal`; test `[IMPL-DECISION G1]` | open |
| CM-02 | claude-spec-comments | COMMITMENT §8, §9.3; HASH §5, §7.4 | M1 (values in M3/M5) | **HIGH** | Field 1 under reference-value nodes, for every value with common or Runtime Control types. poc2 does the opposite. cl l.190-197 | `hash/layout.nim` `rootBelowReference`, `hash/view.nim` `verifyView` (reference step); tests `[IMPL-DECISION G2]` (layout and values); oracle vectors `reference value …` | settled for common-schema refs (NF-07); vector request open |
| CM-03 | claude-spec-comments | INTERFACE §1.1/§1.7; COMMITMENT §5 | M1,M2 | LOW | Acceptance only. =s | — | open, interim supported (NF-08) |
| CM-04 | claude-spec-comments | COMMITMENT §9.4; HASH §8 | M1,M4 | **HIGH-n** | What a view discloses; changes view and evidence bytes, not roots. cl l.205-209 | `hash/view.nim` `viewOf` / `verifyView` (field and tuple-position segments); test `[IMPL-DECISION G7]` | open |
| CM-05 | claude-spec-comments | COMMITMENT §9.4 | M1,M4 | **HIGH-n** | Bytes of semantic paths in views and evidence. cl l.211-214 | `hash/view.nim` `verifyView` (choice step); test `[IMPL-DECISION G8]` | open |
| CM-06 | claude-spec-comments | COMMITMENT §3.1 l.490-503 | M1 | MED | Changes which schemas are accepted, not the roots of accepted ones. | — | settled by spec text (NF-09) |
| CM-07 | claude-spec-comments | HASH §4 l.162-165 | M1 | **HIGH-n** | Packing of literal-element lists, and so their value roots. cl l.223-227 | `commitment/normalize.nim` `packKindOf` (G119); test `[IMPL-DECISION G119] [IMPL-DECISION CM-07]` | open |
| CM-08 | claude-spec-comments | HASH §8, §9 | M1 | LOW | An input of the verifier API. | `hash/view.nim` `ViewSchema`, `verifyView(schema)` (G120); test `[IMPL-DECISION G120]` | open |
| CM-09 | claude-spec-comments | COMMITMENT §6; HASH §7.2 | M1 | MED | "Remove it" drops a domain tag → new profile id → every pinned root changes. | — | open |
| CM-10 | claude-spec-comments | cdCDDLe §5.1 l.172 | M1 | LOW | Acceptance. =s | `cddl/syntax.nim` `parseMember`; test `[IMPL-DECISION G10]` | open (NF-10) |
| CM-11 | claude-spec-comments | cdCDDLe §5 l.125/455 | M1 | LOW | Escape spelling is not kept in canonical form. | `cddl/syntax.nim` `readEscape`; test `[IMPL-DECISION G11]` | open |
| CM-12 | claude-spec-comments | cdCDDLe §5.1 l.163 | M1 | LOW | Acceptance. | `cddl/syntax.nim` `checkRangeBound`; test `[IMPL-DECISION G12]` | settled by spec text (NF-11) |
| CM-13 | claude-spec-comments | cdCDDLe §7.4 (doc says "§7.2 / l.332"), §10 | M1 | LOW | Decoder rejection list. =s | `cddl/codec.nim` `decodeType`; test `[IMPL-DECISION G13]` | open |
| CM-14 | claude-spec-comments | cdCDDLe §8; COMMITMENT §5 | M1 | MED | Changes cdCDDLe document content only; no root or vector impact. | `cddl/canon.nim` `canonicalize(scope)`; test `[IMPL-DECISION G14]` | open |
| HC-11 | human-spec-comments | INTERFACE §2.1/§2.3; COMMITMENT §9.1 l.1288 | M1,M2,M10 | **HIGH-c** | Only if fixing HC-04 needs an ordering that stays stable when fields are added: struct layout, `_ARM_&lt;i&gt;` values, choice-index hashing. hc l.239-252 | — | open |
| IF-01 | claude-spec-comments | INTERFACE §4.4/§4.5; TRANSPORT §2.3 | M1,M5 | MED | Which layer rejects floats; the encoder is unchanged. | `cbor/decode.nim`; test `[IMPL-DECISION G38]` | open |
| IF-02 | claude-spec-comments | INTERFACE §4.5/§5.1 | M1,M2 (+ripple) | **HIGH** | The suggested new reason value edits the common schema → every pinned root changes. cl l.284-290 | — | open |
| NA-01 | claude-spec-comments-2 | CA §5, §7; INTERFACE §5.1 l.2503-2506; RUNTIME §9.3 | M1, M2, M3, M4 | MED | Additive: P [CR]. Detail allowed under NOT_AUTHORISED (N, changes the detail table) or a consumer-scoped pending event (Y). | — | open |
| NC-03 | claude-spec-comments-2 | INTERFACE §5.1; CONFIG §5; RUNTIME §9.3 | M1, M2, M4 | MED | Additive: N [CR]. New value in the closed `invalid_params_reason` set, or typed failure arms. | — | open |
| ND-02 | claude-spec-comments-2 | INTERFACE §5.1 | M1, M2, M3, M4 | LOW | Additive: Y [CR]. Timestamp and duration common types. | — | open |
| ND-07 | claude-spec-comments-2 | INTERFACE §1.4, §5.1; PM §15; CA; LOADER | M1, M2, M4, M7, M8 | MED | Additive: P [CR]. `logos.domain_error`; PM, CA and LOADER switching to it changes their schemas and generated names. | — | open |
| NX-02 | claude-spec-comments-2 | TRANSPORT §5.1; INTERFACE §2.6, §5.1 | M1, M2, M5 | LOW | Additive: Y [CR]. Restrict the snapshot-event model to Runtime contracts (editorial). Add `logos.revision`. Optional on-subscription hook. | — | open |
| G151 | claude-spec-comments-2 (ND-10) | cdCDDLe §5.1 l.164 vs §8 l.530, l.537 | M1 | LOW | §5.1 allows `.size` on any target; the §8 node holds only a primitive. Interim: `x .size n` with `x` a rule name is rejected as unsupported, so no bytes are committed to. | `cddl/syntax.nim` `checkSize`; vector `unsupported-size-named-target` | reported as ND-10 (logos-lips `e7c53b7b`); open |
| G152 | claude-spec-comments-2 (ND-11) | COMMITMENT §4 l.560-562 vs §8 l.1101 | M1 | **HIGH-n** | A leaf-bodied declaration's own node gets two identities (subtree root, leaf hash at `[]`); decides the schema identity in value nodes typed by it, so value roots. Interim: the subtree root. | `commitment/schema.nim` `nodeIdentity`, `commitment/normalize.nim` `identityOf`; tests `[IMPL-DECISION G152]` | reported as ND-11 (logos-lips `e7c53b7b`); open |
| PM-06 | claude-spec-comments | PM §4.3; CA §9.1 | M1,M7 | MED | Signature edge cases; no byte change. | `crypto/ed25519.nim` `verify`, `checkPublicKey` (G135); `tests/test_ed25519.nim` (RFC 8032, Wycheproof, edge vectors from `oracle/gen_ed25519_vectors.py`); test `[IMPL-DECISION G42]` | open |

## Tier 2 — schema surface and C types

| ID | Report | Spec §§ | Milestones | Risk | Likely fix, interim choice | Code / test | Status |
|---|---|---|---|---|---|---|---|
| NL-01 | claude-spec-comments-2 | RUNTIME §3.4, §10.2; INTERFACE §2.6, §2.8; LOADER §9; PM §4; BCP §5.4 | M2, M3, M4, M5, M7, M9 | HIGH | Additive: P. Declared stop budget [MR] plus a deadline handed to the module: either a `prepare_stop` hook (Y) or a `_destroy` parameter (N, changes the ABI). | — | open |
| NL-02 | claude-spec-comments-2 | RUNTIME §3.4 l.592-600, §10.2 l.3253-3261, §3.7 | M2, M3, M4 | HIGH | Additive: N. Rewrites the stop sequence: consumer routes stay open during a pre-stop phase, and admission closes per instance in reverse order. | — | open |
| NL-03 | claude-spec-comments-2 | INTERFACE §2.6; RUNTIME §3.4, §10.2 | M2, M3 | HIGH | Additive: P. `_destroy` returns `logos_result_t` (N) or a `report_cleanup` call is appended to the vtable (Y). | — | open |
| NR-11 | claude-spec-comments-2 | INTERFACE §2.8, §5.2; RUNTIME §4.1 | M2, M3, M5 | HIGH | Additive: Y. Async call appended to the route vtable, or several handles sharing one session (the handle-to-session model goes N:1). | — | open |
| AP-9 | claude-spec-comments | INTERFACE §1.1/§1.8 | M2 | LOW | Answered. | — | open |
| C-04 | claude-spec-comments | INTERFACE §2.3 vs §2 intro | M2 | LOW | Both suggested fixes accept "always emit the tag". =s | G64: `iface/cmap.nim` `choiceDef` always emits `kind`; test `[IFC-0148]` (tagged map union) | open |
| C-05 | claude-spec-comments | INTERFACE A.4/A.5 vs RUNTIME §4.1 | M2,M3 | LOW | Helper names that are never exported. =s | — | open |
| C-06 | claude-spec-comments | RUNTIME §1.3 vs TRANSPORT §8.2 | M2,M5 | LOW | Socket path layout. =s | — | settled by spec text except the 4096-byte path vs sun_path residue (NF-03) |
| C-11 | claude-spec-comments | INTERFACE A.3; SECURITY l.230/441 | M2,M9 | LOW | Editorial. | — | open |
| HC-02 | human-spec-comments | LOADER §1/§3/§6; RUNTIME §5.2/5.3/7.5; TRANSPORT §1.3/§5 | M2,M5,M8 | **HIGH** | Subscribe `{0,id,event}` (l.193) gains a filter; one host per instance is broken. hc l.57-76 | — | open |
| HC-03 | human-spec-comments | INTERFACE §2.4/§2.6; CA §2/§3.1; PM §15 | M2,M3,M4,M7,M8 | **HIGH** | Consumer passed into the unversioned `_dispatch` and typed signatures. hc l.80-98 | — | open |
| HC-04 | human-spec-comments | INTERFACE §1.2/1.4; TRANSPORT §3.1/§8.3/§10; CA §3.1; PM §4 | M2,M4,M5,M7 | **HIGH** | Exact-root identity, Hello equality, bare-name rule. hc l.102-122 | — | partly settled; `_dispatch` ABI risk (NF-23) |
| HC-05 | human-spec-comments | INTERFACE §2.8/§5.2; TRANSPORT §5.3 | M2,M3 | MED | An async op can be appended to the vtable. | — | open |
| HC-06 | human-spec-comments | INTERFACE §5.1/§5.2; TRANSPORT §6 | M2,M3,M5 | MED | Cancel can be appended; HIGH if `call` gains a timeout parameter. | — | open |
| HC-07 | human-spec-comments | INTERFACE §2.6/§2.8/A.3; BCP §6.1 | M2,M8 | **HIGH** | The mandatory export set would change. hc l.166-182 | — | open |
| HC-10 | human-spec-comments | INTERFACE §5.2 l.2626, A.4; RUNTIME §7.3 | M2,M3,M8 | **HIGH** | `logos_publish_fn` return type and the publish helpers. hc l.221-237 | — | open |
| IF-03 | claude-spec-comments | INTERFACE §2.3; RUNTIME l.1814; CA l.1001 | M2,M3,M4 | **HIGH** | C names and struct shape for tuple arms and list items. cl l.293-298 | G62: `iface/cmap.nim` synthetic `_list_t`/`_tuple_t`/`_bstr_t` aggregates; test `G62` | open |
| IF-04 | claude-spec-comments | INTERFACE §1.5 vs §2.5 | M2 | **HIGH-n** | C form of choice-of-maps events. cl l.300-303 | G63: `iface/cmap.nim` `choiceDef` (event tag); test `G63` | open |
| IF-05 | claude-spec-comments | INTERFACE §2.3, §3.5 | M2,M10 | LOW | Header text, not ABI. | — | open |
| IF-06 | claude-spec-comments | INTERFACE §3.4 | M2,M10 | **HIGH-n** | Position of the `has_` flag is struct layout. =s. cl l.311-314 | G66: `iface/cmap.nim` `fieldMembers`; test `G66` | open |
| IF-07 | claude-spec-comments | INTERFACE §2.7 | M2 | MED | Allocation unit and free order. | — | open |
| IF-08 | claude-spec-comments | INTERFACE §2.7, A.5 | M2 | MED | Name of a non-exported free helper. | — | open |
| IF-09 | claude-spec-comments | INTERFACE §1.3/§2.1; RUNTIME §1.3 | M2 | LOW | Name reservation; HIGH only if the symbol-derivation scheme changes. =s | — | open |
| IF-10 | claude-spec-comments | INTERFACE §5.2; RUNTIME §4.2 | M2,M6 | LOW | Editorial. | — | open |
| IF-11 | claude-spec-comments | INTERFACE §2.1 | M2 | LOW | Header order, not ABI. | G72 (revised), G155: `iface/cmap.nim` `emit`, `ordered`; tests `G72`, `[IFC-0384]` | open |
| NA-06 | claude-spec-comments-2 | CA §3.5, §10, §12; INTERFACE §2.6 | M2, M4 | MED | Additive: P. Scoped CA check method for providers (Y), or the allowed scope delivered with each dispatch (N, changes `_dispatch`). Depends on HC-03. | — | open |
| NC-01 | claude-spec-comments-2 | CONFIG §3, §4, §7; INTERFACE §2.6 | M2, M4, M7 | MED | Additive: Y. Optional migration hook; MAY→MUST on retaining configuration. | — | open |
| ND-03 | claude-spec-comments-2 | TRANSPORT §2.1, §3.1; INTERFACE §4.6 | M2, M3, M5 | MED | Additive: N. Sender-side size check with a named reason (maybe [CR]); Hello maximum would be [W]. | — | open |
| ND-09 | claude-spec-comments-2 | INTERFACE §1.2, §5.3; cdCDDLe §7 | M2 | LOW | Additive: Y. Doc-comment convention; comments are still stripped before hashing. | — | open |
| NE-03 | claude-spec-comments-2 | INTERFACE §5.2; RUNTIME §4.4, §7.5, §9.3; CA §3 | M2, M3, M4 | MED | Additive: P. An ended-callback on subscribe is N if the `subscribe` signature changes and Y if it is appended. Default own-route observation plus a `consumers` scope selector is Y. | — | open |
| NE-04 | claude-spec-comments-2 | INTERFACE §2.6; RUNTIME §9.3 | M2, M3 | LOW | Additive: Y. Provider session-end notification; `consumer` on `route_state_changed_event`. | — | open |
| NI-01 | claude-spec-comments-2 | INTERFACE §5.2; RUNTIME §9.3 | M2, M3 | LOW | Additive: Y. Append the ids to `logos_module_init_input_t` (l.2769), or add `describe_self`. | — | open |
| NL-05 | claude-spec-comments-2 | RUNTIME §3.4, §13; INTERFACE §2.6; SECURITY §11.5 | M2, M3, M12 | MED | Additive: Y. Suspend/resume host operations plus an optional hook; no new state proposed. The engine needs a quiesce-without-destroy path. | — | open |
| NL-09 | claude-spec-comments-2 | INTERFACE (new profile); TRANSPORT §3.2, §5.1 | M2, M8 | LOW | Additive: Y. Long-running-operation conventions. | — | open |
| NR-12 | claude-spec-comments-2 | INTERFACE §2.6; TRANSPORT §6 | M2, M5 | MED | Additive: P. Statement or optional `_cancel` (Y). Its token needs a `_dispatch` change (N) or an appended getter (Y). | — | open |
| NX-04 | claude-spec-comments-2 | INTERFACE §2, §2.1, §3.9.5 | M2, M10 | MED | Additive: N (narrowing). Acceptance rule that rejects derived C names equal to `logos_types.h` names, or reserved namespaces. No accepted schema's generated name changes. It becomes HIGH only if the owner re-prefixes the common types instead. | `iface/cmap.nim` `cDeclarations` rejects identifiers `logos_types.h` declares, at acceptance (I23); test `[IFC-0475] NX-04 interim` | open |
| PM-11 | claude-spec-comments | PM §10/§12; LOADER §3/§5; INTERFACE §2.6 | M2,M4,M7,M8 | MED | OPEN; the init input can grow compatibly. | — | open |
| SO-07 | claude-spec-comments | INTERFACE §1.3 | M2,M7,M8 | MED | Renaming `lcn.` changes our own roots and C symbols. | — | open |
| G153 | claude-spec-comments-2 (ND-12) | INTERFACE §2, §2.1, §5.3 | M2 | LOW | A cycle of local aliases (`a = b`, `b = a`) resolves and has a root but no value and no C form. Interim: rejected at acceptance; cycles through a structure are recursion and stay. Narrowing only. | `iface/accept.nim` `checkAliasCycles`; test `[IMPL-DECISION G153]` | reported as ND-12 (logos-lips `2f6cbcb0`); open |
| G154 | claude-spec-comments-2 (ND-13) | INTERFACE §2.1, §2.3 | M2 | LOW | §2.3 forward-declares only targets of recursive by-value edges, so `{ kids: [* demo.node] }` inside `demo.node` does not compile. Interim: a list target on a cycle of by-value and list edges also gets a forward typedef. Header text only. | `iface/cmap.nim` `resolveGraph`; test `G154` | reported as ND-13 (logos-lips `2f6cbcb0`); open |
| G155 | claude-spec-comments-2 (ND-14) | INTERFACE §2.1 l.676-679 vs §3.9.3 | M2 | LOW | CONTRA: least-name topological order gives `left, node, branch, right`; the required §3.9.3 header has `left, node, right, branch`. Interim: dependency depth, then qualified name, which reproduces §3.9.3. Header order only. | `iface/cmap.nim` `ordered`; test `[IFC-0384]` | reported as ND-14 (logos-lips `2f6cbcb0`); open |

## Tier 3 — sans-I/O transport codecs, PM artifacts

| ID | Report | Spec §§ | Milestones | Risk | Likely fix, interim choice | Code / test | Status |
|---|---|---|---|---|---|---|---|
| NE-05 | claude-spec-comments-2 | TRANSPORT §5.2, §1.3; INTERFACE §2.8, §5.2; BCP §5.4 | M5 | HIGH | Additive: N [W]. Per-subscription buffering, a lag marker or closing one subscription, a coalesce hint on Subscribe. This replaces "close the connection" and needs new fields in closed envelope maps. | — | open |
| NP-02 | claude-spec-comments-2 | PM §4, §7.1 l.837/846, §10; LOADER §3 | M5, M7, M12 | HIGH | Additive: Y [MR]. Executable artifact kind (0755, symlinks) plus a new realization strategy where the signed executable acts as the Module Host. | — | open |
| NR-14 | claude-spec-comments-2 | TRANSPORT §8.2 l.951-967; SECURITY §11 | M5, M9 | HIGH | Additive: N. Security fix: a per-route socketpair or nonce instead of a socket path changes the endpoint model. Only MED if the owner picks uid+pid checks instead. | — | open |
| AP-7 (G108) | claude-spec-comments | LOADER l.330 | M5 | LOW | Answered. | — | open |
| C-07 | claude-spec-comments | PM §4 l.341/363 vs §8 | M7 | MED | Validation rule, error value, check precedence. =s | `package/manifest.nim` `checkManifest` (shared schema/default artifacts allowed, one implementation artifact per module), `package/lgx.nim` `openLgx` (G29 check order); tests `[PKG-0053] [PKG-0054]`, `[PKG-0267]` | error value settled (NF-04); rest open |
| C-08 | claude-spec-comments | LOADER §6, §10 l.612 | M4,M5 | MED | Meaning of an error value; a new value would change the Loader root. =s | — | contradiction settled (NF-05); one code row open |
| C-10 | claude-spec-comments | RUNTIME Abs vs LOADER §5, §5.4 | M4,M5 | LOW | An in-process Loader fits both suggested fixes. =s | — | open |
| EC-05 | claude-spec-comments | RUNTIME §4.1; INTERFACE §5.2 | M3,M5 | MED | Error code. | — | open |
| EC-06 | claude-spec-comments | RUNTIME §3.4 | M3,M5 | MED | Error code. | — | open |
| HC-01 | human-spec-comments | INTERFACE §1.2/1.3; RUNTIME §9.3; PM §4.1; CA §3.1/3.3 | M4,M6,M7 | MED | Fields for publisher selection. | — | open |
| NC-04 | claude-spec-comments-2 | RUNTIME §8, §9.3; PM §4 | M3, M4, M7 | LOW | Additive: Y [MR]. Persistent-state declaration. | — | open |
| NC-06 | claude-spec-comments-2 | TRANSPORT §8.2; SECURITY §11 | M5, M12 | LOW | Additive: Y. Likely a "files travel as bytes" statement. | — | open |
| NE-01 | claude-spec-comments-2 | TRANSPORT §5.2-5.3; INTERFACE §1.5, §5.2; RUNTIME §7.3 | M5, M8 | LOW | Additive: Y. State the notify-then-fetch rule; optional targeted publish. | — | open |
| NE-02 | claude-spec-comments-2 | TRANSPORT §5.3, §6, §7; RUNTIME §6.4, §7.2; INTERFACE §2.8 | M3, M5 | MED | Additive: N. Events caused by a call are delivered after its Response, so publishing inside direct-mode dispatch must be deferred. HIGH [W] if a correlation field is added to Event instead. | — | open |
| NI-04 | claude-spec-comments-2 | RUNTIME §9.3; PM §15 | M3, M4, M7 | MED | Additive: P. New `destroy_module` (Y). `remove_package` fails with `package-in-use` (N for PM). | — | open |
| NI-06 | claude-spec-comments-2 | PM §5, §6, §12; CA §3.3 | M3, M4, M7 | LOW | Additive: Y. Add `signer` to PM records and the handoff; optional signer constraint in scopes. | — | open |
| NL-04 | claude-spec-comments-2 | RUNTIME §6.2, §10.1; LOADER §6, §9, §11 | M4, M5 | MED | Additive: N. Source of the startup timeout, overrun behaviour, recovery carve-out. | — | open |
| NL-07 | claude-spec-comments-2 | RUNTIME §9.3; LOADER §10; CONFIG §8 | M3, M4, M5, M6 | MED | Additive: P. `? failure` field (Y). A facade `unknown` state extends the closed `state` enum (N). | — | open |
| NL-08 | claude-spec-comments-2 | LOADER §7; RUNTIME §10.1 | M4, M5 | LOW | Additive: Y. Optional liveness probe. | — | open |
| NO-03 | claude-spec-comments-2 | RUNTIME §9.3; PM §4 | M3, M4, M7 | LOW | Additive: Y [MR]. Usage method; footprint field. | — | open |
| NP-01 | claude-spec-comments-2 | PM §4, §6; RUNTIME §9.3 | M3, M7 | LOW | Additive: Y [MR]. Optional signed metadata; operator label. | — | open |
| NP-03 | claude-spec-comments-2 | PM §4, §9; LOADER §3; BCP §5.3 | M3, M4, M7, M12 | MED | Additive: P [MR]. `module-binary` no longer mandatory (code that assumes a binary must handle its absence). | — | open |
| NP-04 | claude-spec-comments-2 | PM §4, §12; RUNTIME §13.3 | M4, M7, M12 | MED | Additive: P [MR]. `runtime_handoff.artifact` becomes optional. | — | open |
| NP-05 | claude-spec-comments-2 | PM §4, §10 | M7 | LOW | Additive: Y [MR]. Licence metadata. | — | open |
| NP-06 | claude-spec-comments-2 | PM §4, §7.1 | M7 | LOW | Additive: Y [MR]. `requires_runtime`. | — | open |
| NP-07 | claude-spec-comments-2 | PM §7.1; BCP §5.4 | M7, M9 | LOW | Additive: Y. Define the installation root. | — | open |
| NP-08 | claude-spec-comments-2 | PM §15; RUNTIME §9.3 | M3, M7 | LOW | Additive: Y. PM events; record-created event. | — | open |
| NP-09 | claude-spec-comments-2 | PM; CA §3.5; SECURITY | M7, M9, M12 | LOW | Additive: Y [MR]. Platform-integration artifact. | — | open |
| NP-10 | claude-spec-comments-2 | PM §4.1; CA §8 | M4, M7 | MED | Additive: N. Anti-rollback for trust input; withdrawn-signer default. | — | open |
| NP-11 | claude-spec-comments-2 | PM §7.1, §10 | M7 | MED | Additive: Y [MR]. LGX `common/` directory. | — | open |
| NP-12 | claude-spec-comments-2 | PM §4.5, §5, §6 | M7, M11 | MED | Additive: P. Several manifests per identity, or a split distribution form. | — | open |
| NR-06 | claude-spec-comments-2 | TRANSPORT §8.1 | M5, M6 | LOW | Additive: Y. Clarify that renewal rebinds live sessions. | — | open |
| NR-13 | claude-spec-comments-2 | TRANSPORT §3.1, §8.2; RUNTIME App B.1 | M5, M6 | LOW | Additive: P. Define a local control profile or delete the unused variant. | — | open |
| NS-01 | claude-spec-comments-2 | SECURITY §11; LOADER §1, §3 | M5, M9, M12 | LOW | Additive: Y. Statement plus placement profile. | — | open |
| NS-02 | claude-spec-comments-2 | RUNTIME §4.2.1, §10.1; LOADER §7 | M5 | MED | Additive: N. Module Host stops and exits when it loses its Runtime connection. | — | open |
| PM-01 | claude-spec-comments | PM §4.5/§5/§6/§13 | M7,M8 | **HIGH** | OPEN; locator encoding and fetch contract are undefined. cl l.546-553 | — | open |
| PM-02 | claude-spec-comments | PM §5/§7/§13 | M7,M9 | MED | Additive source kind. | — | open |
| PM-03 | claude-spec-comments | PM §15 | M7 | MED | Follows HC-03. | — | open |
| PM-04 | claude-spec-comments | PM §4, §7.1 | M7 | MED | Pax touches only the reader; shrinking the path limit changes manifest roots. | `package/lgx.nim` `splitPath`; test `[IMPL-DECISION G40]` | open |
| PM-05 | claude-spec-comments | PM §7.1 | M7 | MED | Archive acceptance. | `package/lgx.nim` `gunzip`, `writeLgx`, `checkStructure`; tests `[IMPL-DECISION G41]` | open |
| PM-07 | claude-spec-comments | PM §11/§15 | M7 | MED | Tie-break. | — | open |
| PM-08 | claude-spec-comments | PM §11 | M7 | MED | Error. | — | open |
| PM-09 | claude-spec-comments | PM §3, §7.1 | M7 | LOW | Diagnostic file. | `package/lgx.nim` `openLgx` (path-checked, never read); test `[IMPL-DECISION G45]` | open |
| PM-10 | claude-spec-comments | PM §10 l.1082 (doc says §7.1), §4 l.316 | M7,M9,M12 | MED | Platform strings; turning them into an enum would change manifest roots. | `package/lgx.nim` `compatible`, `checkPlatformPaths`, `hostPlatform`; tests `[IMPL-DECISION G73]` | open |
| PM-15 | claude-spec-comments | PM Scope/§11 | M7 | MED | Manifest field → manifest roots change. | — | open |
| RT-04 | claude-spec-comments | RUNTIME §9.3; PM §5/§11; CA §3.3 | M3,M4,M7 | MED | Possible new `create_module` field. | — | open |
| RT-05 | claude-spec-comments | LOADER §7; RUNTIME §10 | M4,M5 | MED | Adopt-or-terminate rule. | — | open |
| RT-06 | claude-spec-comments | RUNTIME §9.3 | M3,M4,M7 | MED | New Runtime Control op (additive). | — | open |
| SO-01 | claude-spec-comments | PM §4.2/§4.4/§6/§11/§13/§15 | M7,M9,M13 | **HIGH** | Our catalog document would be replaced. cl l.657-670 | — | open |
| SO-02 | claude-spec-comments | PM §4.5/§6/§13 | M7,M8 | **HIGH** | `lcn.storage_fetch` would become a spec contract. cl l.672-679 | — | open |
| SO-05 | claude-spec-comments | CA §3.5; PM §4 | M4,M7,M8 | MED | Permission names. | — | open |
| SO-09 | claude-spec-comments | RUNTIME §12; TRANSPORT §2.1 | M8 (M5) | MED | The spec calls streaming "future". | — | open, narrowed (NF-20) |
| TR-01 | claude-spec-comments | TRANSPORT §1.2/§1.4/§2.3/§3.3 | M5 | MED | Receiver rule. | `transport/session.nim` `receive` (both sides), `transport/hello.nim`; tests `[IMPL-DECISION G30]` | open |
| TR-02 | claude-spec-comments | §1.4, §5.1, §6 | M5 | MED | Receiver rule. | `transport/session.nim` `receive`; tests `[IMPL-DECISION G31]` | open |
| TR-03 | claude-spec-comments | §5.1 | M5 | MED | Error code. | `transport/session.nim` `subscribe`, `unsubscribe`; test `[IMPL-DECISION G32]` | open |
| TR-04 | claude-spec-comments | §3.1 | M5 | MED | Error code. | `transport/hello.nim` `acceptHelloResponse`; test `[TRN-0076] [TRN-0070]` (its `[IMPL-DECISION G33]` case) | open |
| TR-05 | claude-spec-comments | §3.1/§3.2/§8.1.1; INTERFACE §4.6 | M5,M6 | MED | When the Hello happens. | `transport/hello.nim` `acceptHelloResponse` (the callee's ProtocolError code is the outcome); test `[TRN-0076] [TRN-0070]` (its `[IMPL-DECISION G34]` case). When the Hello runs is tier 4 | open |
| TR-06 | claude-spec-comments | §8.1; CA §8 | M4,M5 | MED | HIGH only if a new message kind is added. | — | open |
| TR-07 | claude-spec-comments | §4.1 | M5 | MED | Close vs error response. | `transport/boundary.nim` `acceptResponse`, `acceptEvent`; test `[IMPL-DECISION G36]` | open |
| TR-08 | claude-spec-comments | §4.1 | M5 | MED | Check precedence. | `transport/boundary.nim` `acceptRequest`; test `[IMPL-DECISION G37]` | open |
| TR-09 | claude-spec-comments | §8.2, §9.1 | M5,M12 | MED | Windows mechanism. | — | open |
| G156 | claude-spec-comments-2 (NP-15) | PM §8 l.1000 vs §4 l.326 and §8 l.974 | M7 | LOW | An artifact without its `hash` is named `artifact-integrity-failed` by §8 l.1000, but the §4 CDDL requires the field, so the manifest fails validation, which l.974 makes `invalid-package`. Error code only; no bytes change. Interim: `invalid-package` (the schema check runs first, G29). | `package/manifest.nim` `decodeManifest`; test `[IMPL-DECISION G156]`; unit PKG-0275 deferred | reported as NP-15 (logos-lips `05b137a4`); open |

## Tier 4 — runtime, Loader, CONFIG, CA

| ID | Report | Spec §§ | Milestones | Risk | Likely fix, interim choice | Code / test | Status |
|---|---|---|---|---|---|---|---|
| NX-03 | claude-spec-comments-2 | CA §3, §3.1, §5, §8, §9, §9.1; RUNTIME §4.1, §4.3, §9; TRANSPORT §8.1 | M3, M4 | HIGH | Additive: P. Core rule: whether each call is an authorization decision point. Either per-call evaluation is added on the call path, or the CA `call` action is dropped. Call audit and evidence records change either way. | — | open |
| AP-1 (G54) | claude-spec-comments | RUNTIME l.164 | M3 | LOW | Answered. | — | open |
| AP-2 (G57) | claude-spec-comments | RUNTIME l.3060 | M4 | LOW | Answered. | — | open |
| AP-4 (G60) | claude-spec-comments | RUNTIME §13.3/13.4 | M3 | LOW | Answered. | — | open |
| AP-5 (G50) | claude-spec-comments | CA l.1049 | M4 | LOW | Answered. | — | open |
| AP-8 | claude-spec-comments | RUNTIME §4.2 | M3,M8 | LOW | Answered. | — | open |
| C-09 | claude-spec-comments | CA §2 vs RUNTIME §9 | M4,M6 | MED | Policy rule. =s | — | mostly settled (NF-06); "resolve" open |
| CA-01 | claude-spec-comments | CA §3.3, §8 | M4 | MED | Rule. | — | open |
| CA-02 | claude-spec-comments | CA §2 | M4 | MED | Possible new field on `evaluate`. | — | open |
| CA-03 | claude-spec-comments | CA §3.1 | M4 | MED | OPEN; removing it changes a CA schema; tied to HC-02. | — | open |
| CA-04 | claude-spec-comments | CA §9.1 | M4 | MED | Array order is bytes, but CA l.110-115 already points to our choice. | — | open |
| CA-05 | claude-spec-comments | CA §6, §9 | M4 | MED | Ordering and cursors. | — | settled: drop the snapshot cursor (NF-14) |
| CA-06 | claude-spec-comments | CA §9 | M3,M4 | MED | Which `decision_id`. | — | open |
| CA-07 | claude-spec-comments | CA §9.1 | M4 | MED | Additive method. | — | open |
| EC-01 | claude-spec-comments | RUNTIME §9.3 | M3 | MED | Error code. | — | open |
| EC-02 | claude-spec-comments | RUNTIME §9.1/§9.3; CONFIG §3 | M3,M4 | MED | Error code. | — | open |
| EC-03 | claude-spec-comments | RUNTIME §9.3 | M3 | MED | Error code. | — | open |
| EC-04 | claude-spec-comments | CONFIG §8; RUNTIME §9.3 | M4 | MED | Error code; a failure arm would change the Runtime Control root. | — | open |
| EC-07 | claude-spec-comments | RUNTIME Sys. Svc Availability | M3,M4 | MED | Error code. | — | open |
| EC-08 | claude-spec-comments | INTERFACE §5.2 | M3,M6 | MED | Error code. | — | open |
| EC-10 | claude-spec-comments | RUNTIME §9.3 | M3,M4,M6 | MED | Free text becomes an enum → Runtime Control root changes. | — | open |
| EC-11 | claude-spec-comments | RUNTIME §13.3/§13.4 | M3 | MED | Error code. (For all EC items: allocating *new* codes instead would cause the common-schema ripple.) | — | settled: LOADER `abi-invalid` (NF-13) |
| HC-08 | human-spec-comments | INTERFACE Invariance; RUNTIME §12; CONFIG §1/§6 | M3,M8 | MED | Affects our methods that take host paths (G99). | — | open |
| HC-09 | human-spec-comments | CA §9; RUNTIME | M3,M4 | MED | Additive. | — | open |
| HC-12 | human-spec-comments | RUNTIME §9.2/§9.3 | M3 | MED | Field (changes the Runtime Control root). | — | open |
| HC-13 | human-spec-comments | CA §5/§8; RUNTIME §4.3/§9 | M4 | MED | Pending-decision state. | — | open |
| NA-02 | claude-spec-comments-2 | CA §8, §9; RUNTIME §2.4 | M4 | LOW | Additive: Y. Pending-approval event; approver role. | — | open |
| NA-03 | claude-spec-comments-2 | RUNTIME §9.3 | M3 | LOW | Additive: Y. Always set `expires_at`. | — | open |
| NA-04 | claude-spec-comments-2 | RUNTIME §9.3 | M3, M4 | MED | Additive: N. `request_key` retains only successful results. | — | open |
| NA-05 | claude-spec-comments-2 | CA §6, §9 | M4 | LOW | Additive: Y. `issuer`, `decision_id` on grants. | — | open |
| NA-07 | claude-spec-comments-2 | CA §8; RUNTIME §4.4, §9.3 | M3, M4 | MED | Additive: N. Eager re-evaluation of live routes on policy change. | — | open |
| NA-08 | claude-spec-comments-2 | CA §3, §5, §9 | M4 | LOW | Additive: Y. Unique `decision_id` (random 128-bit ids satisfy it now). | — | open |
| NA-09 | claude-spec-comments-2 | RUNTIME §7.5; CA §5, §6; BCP §2 | M3, M4 | MED | Additive: Y. Optional `on_behalf_of`; the specs defer delegation by design. | — | open |
| NA-10 | claude-spec-comments-2 | CA §9, §9.1 | M4 | LOW | Additive: Y. Redacted scope form. | — | open |
| NA-11 | claude-spec-comments-2 | RUNTIME §9, §10.1; CA §1, §8 | M4 | MED | Additive: N. Bootstrap versus CA precedence rule. | — | open |
| NC-02 | claude-spec-comments-2 | CONFIG §4; RUNTIME §9.3 | M4 | MED | Additive: P. Package-default acceptance MAY→MUST; reset action; refusal code. | — | open |
| NE-06 | claude-spec-comments-2 | RUNTIME §3.4, §9.3, §10.2 | M3 | MED | Additive: N. One ordering rule within `stopping`. | — | open |
| NI-02 | claude-spec-comments-2 | RUNTIME §9.3, §2.4, §10.1; CA §3.1 | M3, M4, M6 | MED | Additive: N. Provider id bound to the instance for its whole life, so it must be persisted. | — | open |
| NI-03 | claude-spec-comments-2 | RUNTIME Term., §9.3; CONFIG §3; CA §6 | M3, M4 | MED | Additive: N. Persist both ids in every profile; define what happens to records that name a lost identity. | — | open |
| NI-05 | claude-spec-comments-2 | RUNTIME §9.3 | M3 | MED | Additive: N. `instance` becomes mandatory on events and the stop response; ambiguity error code. | — | open |
| NI-07 | claude-spec-comments-2 | CA §6; RUNTIME §9.3 | M3, M4 | MED | Additive: P. New `orphaned` grant status (the closed enum grows) or a stable-selector target. | — | open |
| NL-06 | claude-spec-comments-2 | RUNTIME §3.4, §9.3 | M3, M4 | MED | Additive: N. `error` persists until an explicit start, recover or stop; align `start_module`. | — | open |
| NL-10 | claude-spec-comments-2 | RUNTIME §10.1, §9.3 | M3, M4 | LOW | Additive: Y. MUST resume retained intent (matches the plan's decision D24); `restart_module`. | — | open |
| NL-11 | claude-spec-comments-2 | CONFIG §8; RUNTIME §9.1 | M4 | MED | Additive: N. Mandatory deadline for `apply_configuration`. | — | open |
| NO-01 | claude-spec-comments-2 | RUNTIME §9.3 | M3, M6 | LOW | Additive: Y. Cursors on list methods. | — | open |
| NO-02 | claude-spec-comments-2 | RUNTIME §9.3 | M3, M6 | MED | Additive: P. New fields and events (Y); `instance` mandatory (N). | — | open |
| NO-04 | claude-spec-comments-2 | RUNTIME §9.3 | M3 | LOW | Additive: Y. `describe_runtime`. | — | open |
| NO-05 | claude-spec-comments-2 | RUNTIME §9.3 l.2243 | M3, M4 | MED | Additive: N. Initial permission-settings state. | — | open |
| NO-06 | claude-spec-comments-2 | RUNTIME §9.3, §10.1 | M4 | MED | Additive: N. Effect of widening a running instance's permissions. | — | open |
| NO-07 | claude-spec-comments-2 | CA §3.3; RUNTIME §9.3 | M3, M4 | MED | Additive: N. Table mapping lifecycle methods to CA actions; `load`/`unload` may be dropped. | — | open |
| NR-04 | claude-spec-comments-2 | RUNTIME §9.3; INTERFACE §5.2 | M3, M6 | MED | Additive: P. Drop `continuations` from the module-facing response (N) or define a follow-up call (Y). | — | open |
| NX-01 | claude-spec-comments-2 | CA §8, §10; RUNTIME §7.3, §9.3; INTERFACE §2.5 | M3, M4 | MED | Additive: P. Likely: `grant_changed` carries only a revision and subscribers fetch the grant (N for the CA contract). Alternatives: the Runtime filters by target (Y), or a provider admission hook plus targeted publish (Y, new ABI). | — | open |
| NX-06 | claude-spec-comments-2 | RUNTIME §9.3 | M3 | LOW | Additive: Y. Content rule for `reason`; Runtime MAY withhold module text. | — | open |
| RT-02 | claude-spec-comments | RUNTIME §9, §10.2 | M3,M4 | MED | Authority basis for engine calls. =s | — | open |
| RT-03 | claude-spec-comments | RUNTIME §1.3 | M4 | LOW | A name. | — | open |
| SO-03 | claude-spec-comments | RUNTIME §3.6/§3.7/§8/§9.3/§10.1/§13.3; PM; CONFIG §4; CA §9.1 | M4,M6,M9 | MED | Config file format. | — | open |
| SO-04 | claude-spec-comments | RUNTIME §9; CA §1/§6 | M4 | MED | Policy format. | — | open |
| SO-06 | claude-spec-comments | BCP §2; SECURITY §13/§14; CA §10 | M4,M6 | MED | HIGH if the CA gains a human principal. | — | open |

## Tier 5 — blocked or later milestones

| ID | Report | Spec §§ | Milestones | Risk | Likely fix, interim choice | Code / test | Status |
|---|---|---|---|---|---|---|---|
| NR-01 | claude-spec-comments-2 | TRANSPORT §3.1 l.422, §8.4; RUNTIME §9.3 | M6, M11, M12 | HIGH | Additive: Y. New provider-initiated or relayed carrier and address kind; reverses "caller opens the connection" for that profile only. Existing tls-tcp code is untouched. | — | open |
| AP-3 (G26) | claude-spec-comments | RUNTIME l.433 | M6 | LOW | Answered. | — | open |
| AP-6 (G83) | claude-spec-comments | RUNTIME l.35-38 | M6 | LOW | Answered. | — | open |
| C-03 | claude-spec-comments | INTERFACE Abs/§3/§3.8/§3.9 vs BCP §6.1 | M10 | LOW | Wording about conformance classes; decides whether M10 is mandatory. | — | open, narrowed (NF-02) |
| EC-09 | claude-spec-comments | RUNTIME §9.3 l.2991-3017 | M6 | MED | Error code. | — | enrollment part settled (NF-12) |
| NP-13 | claude-spec-comments-2 | PM §4.5 | M11 | MED | Additive: P. Per-variant provenance. | — | open |
| NR-02 | claude-spec-comments-2 | RUNTIME §9.3; CA §3.4 | M6 | LOW | Additive: Y. Pairing bundle plus provisioning method (large, but new). | — | open |
| NR-03 | claude-spec-comments-2 | RUNTIME §9.3 | M6 | LOW | Additive: Y. Facade set/remove methods. | — | open |
| NR-05 | claude-spec-comments-2 | RUNTIME §9.3; TRANSPORT §3.2 | M6 | MED | Additive: N. Define "remote runtime disconnect". | — | open |
| NR-07 | claude-spec-comments-2 | TRANSPORT §8.4.1-2 | M6, M11 | LOW | Additive: Y. TCP keepalive / QUIC PING; no envelope change. | — | open |
| NR-09 | claude-spec-comments-2 | RUNTIME §9.3; TRANSPORT §8.4.1 | M6 | MED | Additive: P. Provider's clock governs expiry, or a relative `expires_in_ms`. | — | open |
| NR-10 | claude-spec-comments-2 | TRANSPORT §8.4.1 | M6 | LOW | Additive: Y. Clarify SPKI pinning, no host-name check, SNI only. | — | open |
| NS-03 | claude-spec-comments-2 | SECURITY §11; BCP §5.4 | M9, M12 | LOW | Additive: Y. Checklist items. | — | open |
| PM-12 | claude-spec-comments | PM §4.5 | M11 | MED | Profile. | — | open |
| PM-13 | claude-spec-comments | PM §4.5/§14 | M11 | MED | Error mapping. | — | open |
| PM-14 | claude-spec-comments | PM §4.5 | M11 | MED | Rule. | — | open |
| RT-01 | claude-spec-comments | RUNTIME Term/§9/§9.3; BCP §2/§5.1/§7 | M6,M9 | **HIGH** | A local activation profile would replace the logosctl design (D13). cl l.441-452 | — | open |
| SO-08 | claude-spec-comments | SECURITY §13 etc. | M9 | LOW | Additive. | — | open |
