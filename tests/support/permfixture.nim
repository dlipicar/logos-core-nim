## The test permission profile (DECISIONS I93): host-ambient, a quota with
## containment, and a definition no active point enforces. Tests hand
## `testProfile` to `EngineConfig` and `AuthorityWiring` directly (protected
## input); host configuration can only name the shipped profile.

{.push raises: [], gcsafe.}

import results
import logos_sdk/cbor
import ../../src/logos_core/permissions

export permissions

const
  TestProfileName* = "lcn-test.profile.v1"
  Quota* = "lcn-test.quota"
  Unenforced* = "lcn-test.unenforced"
  QuotaDocument = """
; lcn-test.quota's constraints: at most `limit` units.
lcn_test_permissions.quota = { limit: uint64 }
"""
  UnenforcedDocument = """
; lcn-test.unenforced's constraints: none.
lcn_test_permissions.unenforced = {}
"""

proc quota*(limit: uint64): seq[byte] =
  ## The constraints `{limit: limit}`.
  encodeCbor(cborMap((cbor("limit"), cbor(limit))))

proc limitOf(b: openArray[byte]): Opt[uint64] =
  let v = decodeCbor(b).valueOr:
    return Opt.none(uint64)
  if v.kind != ckMap:
    return Opt.none(uint64)
  for (k, x) in v.entries:
    if k.kind == ckText and k.text == "limit" and x.kind == ckUint:
      return Opt.some(x.uint)
  Opt.none(uint64)

proc quotaWithin(narrow, broad: openArray[byte]): bool {.nimcall, gcsafe, raises: [].} =
  let n = limitOf(narrow)
  let b = limitOf(broad)
  n.isSome and b.isSome and n.get <= b.get

proc sameValue(narrow, broad: openArray[byte]): bool {.nimcall, gcsafe, raises: [].} =
  @narrow == @broad

proc testProfile*(): PermissionProfile {.nimcall, gcsafe, raises: [].} =
  ## `lcn-test.profile.v1`: `lcn-test.quota` (`{limit: uint64}`, narrow <= broad,
  ## Runtime admission), `lcn-test.unenforced` (`{}`, the inactive Loader
  ## point) and host-ambient, ascending by name; minimum host-ambient.
  PermissionProfile(
    name: TestProfileName,
    definitions: @[
      PermissionDefinition(
        name: Quota,
        schema: QuotaDocument,
        root: "lcn_test_permissions.quota",
        contains: quotaWithin,
        enforcement: epRuntimeAdmission,
        unenforceable: ueFailOperation,
        revoked: rvStopExecution,
        facilities: {fcResources},
      ),
      PermissionDefinition(
        name: Unenforced,
        schema: UnenforcedDocument,
        root: "lcn_test_permissions.unenforced",
        contains: sameValue,
        enforcement: epModuleLoader,
        unenforceable: ueFailOperation,
        revoked: rvStopExecution,
        facilities: {fcDevice},
      ),
      hostAmbient(),
    ],
    minimum:
      @[PermissionSetting(permission: HostAmbient, constraints: HostAmbientConstraints)],
  )

func setting*(name: string, constraints: seq[byte]): PermissionSetting =
  PermissionSetting(permission: name, constraints: constraints)

func ambient*(): PermissionSetting =
  setting(HostAmbient, HostAmbientConstraints)

func unenforced*(): PermissionSetting =
  setting(Unenforced, @[0xa0'u8])
