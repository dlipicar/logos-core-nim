## The Capability Authority contract (CAPABILITY AUTHORITY §3-§9), rule by
## rule (DECISIONS I88, W2): values built from the accepted model validate and
## round-trip byte for byte through
## `authority/logos_capability_authority_types.nim`; values outside a bound are
## refused (`support/schemasuite`). One test per rule, named by its requirement
## id.

import unittest2
import ../src/logos_core/authority/logos_capability_authority_types
import ./support/schemasuite

const Rules = [
  "logos.capability_authority.decision_id", "logos.capability_authority.route_access",
  "logos.capability_authority.execution_mode",
  "logos.capability_authority.hosted_placement",
  "logos.capability_authority.artifact_id",
  "logos.capability_authority.provider_access_scope",
  "logos.capability_authority.runtime_control_scope",
  "logos.capability_authority.module_execution_scope",
  "logos.capability_authority.remote_enrollment_scope",
  "logos.capability_authority.permission_scope", "logos.capability_authority.scope",
  "logos.capability_authority.commitment_retention",
  "logos.capability_authority.commitment_requirements",
  "logos.capability_authority.timestamp", "logos.capability_authority.grant_id",
  "logos.capability_authority.cursor", "logos.capability_authority.decision_result",
  "logos.capability_authority.denial_code", "logos.capability_authority.denial",
  "logos.capability_authority.evaluate_request", "logos.capability_authority.decision",
  "logos.capability_authority.evaluate_response",
  "logos.capability_authority.grant_status", "logos.capability_authority.grant",
  "logos.capability_authority.issue_grant_request",
  "logos.capability_authority.issue_grant_response",
  "logos.capability_authority.revoke_grant_request",
  "logos.capability_authority.revoke_grant_response",
  "logos.capability_authority.get_grant_request",
  "logos.capability_authority.get_grant_response",
  "logos.capability_authority.list_grants_request",
  "logos.capability_authority.list_grants_response",
  "logos.capability_authority.error_code", "logos.capability_authority.error",
  "logos.capability_authority.grant_changed_event",
  "logos.capability_authority.policy_changed_event",
  "logos.capability_authority.audit_value_commitment",
  "logos.capability_authority.call_commitments",
  "logos.capability_authority.audit_record",
  "logos.capability_authority.query_audit_request",
  "logos.capability_authority.query_audit_response",
  "logos.capability_authority.call_evidence_profile",
  "logos.capability_authority.evidence_key_id",
  "logos.capability_authority.call_evidence_proofs",
  "logos.capability_authority.call_evidence_claim",
  "logos.capability_authority.grant_issuer",
  "logos.capability_authority.watch_changes_request",
  "logos.capability_authority.watch_changes_response",
  "logos.capability_authority.observed_change_event",
]

let
  model = ruleModel(caDocuments())
  codec = codecTable("LogosNS", Rules)

template holds(name: string) =
  let problems = model.checkRule(name, codec)
  for p in problems:
    checkpoint name & ": " & p
  check problems.len == 0

suite "cap.schema: the Capability Authority contract (CAPABILITY AUTHORITY §3-§9)":
  test "every rule of the contract has its test here":
    for r in model.names:
      checkpoint r
      check r in Rules
    # The codec half is exercised: every map or choice rule declared by
    # this contract has a generated type that round-trips.
    var objects = 0
    for r in Rules:
      if r in model.names and model.composite(r):
        checkpoint r
        check codec(r, model.samples(r)[0]).isSome
        inc objects
    check objects > 0

  test "[CAP-0026] the contract is the logos_capability_authority module (§3 l.143)":
    check model.moduleName == "logos_capability_authority"

  test "[CAP-0027] logos.capability_authority.decision_id (§3 l.145)":
    holds "logos.capability_authority.decision_id"

  test "[CAP-0028] logos.capability_authority.route_access (§3 l.147)":
    holds "logos.capability_authority.route_access"

  test "[CAP-0029] logos.capability_authority.execution_mode (§3 l.153)":
    holds "logos.capability_authority.execution_mode"

  test "[CAP-0030] logos.capability_authority.hosted_placement (§3 l.157)":
    holds "logos.capability_authority.hosted_placement"

  test "[CAP-0031] logos.capability_authority.artifact_id (§3 l.162)":
    holds "logos.capability_authority.artifact_id"

  test "[CAP-0032] logos.capability_authority.provider_access_scope (§3 l.164)":
    holds "logos.capability_authority.provider_access_scope"

  test "[CAP-0033] logos.capability_authority.runtime_control_scope (§3 l.180)":
    holds "logos.capability_authority.runtime_control_scope"

  test "[CAP-0034] logos.capability_authority.module_execution_scope (§3 l.192)":
    holds "logos.capability_authority.module_execution_scope"

  test "[CAP-0035] logos.capability_authority.remote_enrollment_scope (§3 l.205)":
    holds "logos.capability_authority.remote_enrollment_scope"

  test "[CAP-0036] logos.capability_authority.permission_scope (§3 l.212)":
    holds "logos.capability_authority.permission_scope"

  test "[CAP-0037] logos.capability_authority.scope (§3 l.218)":
    holds "logos.capability_authority.scope"

  test "[CAP-0087] logos.capability_authority.commitment_retention (§4 l.433)":
    holds "logos.capability_authority.commitment_retention"

  test "[CAP-0088] logos.capability_authority.commitment_requirements (§4 l.435)":
    holds "logos.capability_authority.commitment_requirements"

  test "[CAP-0099] logos.capability_authority.timestamp (§5 l.499)":
    holds "logos.capability_authority.timestamp"

  test "[CAP-0100] logos.capability_authority.grant_id (§5 l.500)":
    holds "logos.capability_authority.grant_id"

  test "[CAP-0101] logos.capability_authority.cursor (§5 l.501)":
    holds "logos.capability_authority.cursor"

  test "[CAP-0102] logos.capability_authority.decision_result (§5 l.503)":
    holds "logos.capability_authority.decision_result"

  test "[CAP-0103] logos.capability_authority.denial_code (§5 l.505)":
    holds "logos.capability_authority.denial_code"

  test "[CAP-0104] logos.capability_authority.denial (§5 l.514)":
    holds "logos.capability_authority.denial"

  test "[CAP-0105] logos.capability_authority.evaluate_request (§5 l.519)":
    holds "logos.capability_authority.evaluate_request"

  test "[CAP-0106] logos.capability_authority.decision (§5 l.526)":
    holds "logos.capability_authority.decision"

  test "[CAP-0107] logos.capability_authority.evaluate_response (§5 l.540)":
    holds "logos.capability_authority.evaluate_response"

  test "[CAP-0123] logos.capability_authority.grant_status (§6 l.618)":
    holds "logos.capability_authority.grant_status"

  test "[CAP-0124] logos.capability_authority.grant (§6 l.630)":
    holds "logos.capability_authority.grant"

  test "[CAP-0125] logos.capability_authority.issue_grant_request (§6 l.643)":
    holds "logos.capability_authority.issue_grant_request"

  test "[CAP-0126] logos.capability_authority.issue_grant_response (§6 l.651)":
    holds "logos.capability_authority.issue_grant_response"

  test "[CAP-0127] logos.capability_authority.revoke_grant_request (§6 l.656)":
    holds "logos.capability_authority.revoke_grant_request"

  test "[CAP-0128] logos.capability_authority.revoke_grant_response (§6 l.662)":
    holds "logos.capability_authority.revoke_grant_response"

  test "[CAP-0129] logos.capability_authority.get_grant_request (§6 l.666)":
    holds "logos.capability_authority.get_grant_request"

  test "[CAP-0130] logos.capability_authority.get_grant_response (§6 l.671)":
    holds "logos.capability_authority.get_grant_response"

  test "[CAP-0131] logos.capability_authority.list_grants_request (§6 l.675)":
    holds "logos.capability_authority.list_grants_request"

  test "[CAP-0132] logos.capability_authority.list_grants_response (§6 l.683)":
    holds "logos.capability_authority.list_grants_response"

  test "[CAP-0150] logos.capability_authority.error_code (§7 l.767)":
    holds "logos.capability_authority.error_code"

  test "[CAP-0151] logos.capability_authority.error (§7 l.778)":
    holds "logos.capability_authority.error"

  test "[CAP-0158] logos.capability_authority.grant_changed_event (§8 l.800)":
    holds "logos.capability_authority.grant_changed_event"

  test "[CAP-0159] logos.capability_authority.policy_changed_event (§8 l.804)":
    holds "logos.capability_authority.policy_changed_event"

  test "[CAP-0197] logos.capability_authority.audit_value_commitment (§9 l.999)":
    holds "logos.capability_authority.audit_value_commitment"

  test "[CAP-0198] logos.capability_authority.call_commitments (§9 l.1004)":
    holds "logos.capability_authority.call_commitments"

  test "[CAP-0199] logos.capability_authority.audit_record (§9 l.1011)":
    holds "logos.capability_authority.audit_record"

  test "[CAP-0200] logos.capability_authority.query_audit_request (§9 l.1112)":
    holds "logos.capability_authority.query_audit_request"

  test "[CAP-0201] logos.capability_authority.query_audit_response (§9 l.1122)":
    holds "logos.capability_authority.query_audit_response"

  test "[CAP-0217] logos.capability_authority.call_evidence_profile (§9.1 l.1228)":
    holds "logos.capability_authority.call_evidence_profile"

  test "[CAP-0218] logos.capability_authority.evidence_key_id (§9.1 l.1231)":
    holds "logos.capability_authority.evidence_key_id"

  test "[CAP-0219] logos.capability_authority.call_evidence_proofs (§9.1 l.1233)":
    holds "logos.capability_authority.call_evidence_proofs"

  test "[CAP-0220] logos.capability_authority.call_evidence_claim (§9.1 l.1238)":
    holds "logos.capability_authority.call_evidence_claim"

  test "[CAP-0322] logos.capability_authority.grant_issuer (§6 l.620)":
    holds "logos.capability_authority.grant_issuer"

  test "[CAP-0361] logos.capability_authority.watch_changes_request (§8.1 l.928)":
    holds "logos.capability_authority.watch_changes_request"

  test "[CAP-0362] logos.capability_authority.watch_changes_response (§8.1 l.932)":
    holds "logos.capability_authority.watch_changes_response"

  test "[CAP-0363] logos.capability_authority.observed_change_event (§8.1 l.936)":
    holds "logos.capability_authority.observed_change_event"
