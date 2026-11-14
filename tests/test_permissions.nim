## Permissions (Tier 4b step 4b-4; DECISIONS I93, G279-G286): the registry
## and the shipped profile. The Capability Authority's side is the
## `cap.permissions` suite of `test_authority.nim`.

import unittest2
import ../src/logos_core/cbor
import ./support/permfixture

suite "perm.registry: definitions and the shipped profile":
  test "[CAP-0083] [IMPL-DECISION G279] every shipped definition names its enforcement component and what happens when it cannot enforce or is revoked":
    let p = profileV1()
    check p.name == ProfileV1
    check checkProfile(p).isOk
    check p.definitions.len == 1
    let d = p.definitions[0]
    check d.name == HostAmbient
    check d.enforcement == epRuntimeAdmission and d.active
    check d.unenforceable == ueFailOperation
    check d.revoked == rvStopExecution
    check d.root == HostAmbientRoot and d.schema == HostAmbientDocument
    check p.minimum == @[ambient()]
    check builtinProfile(ProfileV1).isSome
    check builtinProfile(TestProfileName).isNone
    check builtinProfile("").isNone

  test "[IMPL-DECISION G283] host-ambient stands for every facility class, claims no containment, and its only constraints value is the empty map":
    let p = profileV1()
    let d = p.definitions[0]
    check d.facilities == {
      fcNetwork, fcFilesystem, fcPersistentState, fcProcess, fcDevice, fcResources,
      fcPlacement,
    }
    check not d.containment
    check HostAmbientConstraints == encodeCbor(cborMap())
    check p.validate(HostAmbient, HostAmbientConstraints).isOk
    check p.validate(HostAmbient, encodeCbor(cborMap((cbor("a"), cbor(1))))).error ==
      peInvalid
    check p.validate(HostAmbient, encodeCbor(cbor(0))).error == peInvalid
    check p.validate(HostAmbient, @[0xa0'u8, 0xa0]).error == peInvalid
    check p.validate(HostAmbient, newSeq[byte]()).error == peInvalid

  test "[CAP-0021] containment is the definition's: host-ambient by equality, a quota within a larger one, nothing for an unknown name":
    let t = testProfile()
    check checkProfile(t).isOk
    check t.contained(HostAmbient, HostAmbientConstraints, HostAmbientConstraints)
    check t.contained(Quota, quota(5), quota(10))
    check t.contained(Quota, quota(10), quota(10))
    check not t.contained(Quota, quota(11), quota(10))
    check not t.contained(Quota, @[0xa0'u8], quota(10))
    check not t.contained("lcn-test.other", @[0xa0'u8], @[0xa0'u8])
    check not NoProfile.contained(
      HostAmbient, HostAmbientConstraints, HostAmbientConstraints
    )

  test "[IMPL-DECISION G280] a definition the Module Loader would enforce is inactive; only Runtime admission is active":
    let t = testProfile()
    check t.activeIn(Quota)
    check t.activeIn(HostAmbient)
    check not t.activeIn(Unenforced)
    check not t.activeIn("lcn-test.other")
    check t.defines(Unenforced)

  test "[IMPL] settings: names strictly ascending by UTF-8 bytes, then every name defined and every value conforming":
    let t = testProfile()
    check t.checkSettings(newSeq[PermissionSetting]()).isOk
    check t.checkSettings(@[setting(Quota, quota(1)), ambient()]).isOk
    check t.checkSettings(@[ambient(), setting(Quota, quota(1))]).error == peUnordered
    check t.checkSettings(@[ambient(), ambient()]).error == peUnordered
    check t.checkSettings(@[setting("lcn-test.other", @[0xa0'u8])]).error == peUnknown
    check t.checkSettings(@[setting(Quota, @[0xa0'u8])]).error == peInvalid
    check t.missing(@[setting(Quota, quota(1))]) == @[HostAmbient]
    check t.missing(@[ambient()]).len == 0
    check NoProfile.checkSettings(@[ambient()]).error == peUnknown
    check not NoProfile.selected

  test "[IMPL] a profile breaking its rules is refused":
    var p = testProfile()
    p.definitions = @[p.definitions[2], p.definitions[0]]
    check checkProfile(p).isErr
    p = testProfile()
    p.minimum = @[unenforced()]
    check checkProfile(p).isErr
    p = testProfile()
    p.definitions[0].root = "lcn_test_permissions.nothing"
    check checkProfile(p).isErr
    p = testProfile()
    p.name = ""
    check checkProfile(p).isErr
