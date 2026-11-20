## Permission definitions and profiles (CA §3.5 l.387-422; RUNTIME §9.3
## l.2526-2604; DECISIONS D25, G110, G279, G280, G283, G286, I93;
## docs/PERMISSIONS.md).
##
## A definition is a value: its name, its constraint CDDL (a supporting schema)
## and root, its containment, the component that enforces it and what happens
## when that component cannot enforce it or the permission is revoked
## (CAP-0021, CAP-0083). A profile is the set of definitions a host selects in
## protected configuration, and the `minimum` every realization's settings
## must hold (G110, G279).
##
## A profile reaches a thread as a `ProfileSource`, a constructor; each thread
## builds its own value and its own constraint validators, released when the
## thread ends. Only a code pointer crosses threads.
##
## The empty profile (`NoProfile`) defines nothing: every permission is
## unknown, and nothing contains anything (the constant form, G229).

{.push raises: [], gcsafe.}

import std/tables
import results
import logos_sdk/base/perthread
import logos_sdk/cbor
import logos_sdk/codegen/nimrt
import logos_sdk/iface/accept

export results

type
  Facility* = enum
    ## [SPEC CA l.398-404] The classes of operating-system or platform access
    ## a profile may expose.
    fcNetwork
    fcFilesystem
    fcPersistentState
    fcProcess
    fcDevice
    fcResources
    fcPlacement

  EnforcementPoint* = enum
    ## [SPEC CA l.406, l.413-416] The component that enforces a definition.
    epRuntimeAdmission
      ## Runtime refuses a realization whose settings or decision lack the
      ## permission: the one active point in Tier 4b (G110)
    epModuleLoader ## named, inactive: no Loader-enforced permission (G280)
    epDeploymentControl ## named, inactive
    epOperatingSystem ## named, inactive

  Unenforceable* = enum
    ## [SPEC CA l.364, l.417] When the enforcement point cannot enforce it.
    ueFailOperation ## the operation fails (CAP-0084)

  Revoked* = enum
    ## [SPEC CA l.915-916] When a required permission is revoked.
    rvStopExecution ## Runtime stops the execution form (CAP-0192)

  Containment* =
    proc(narrow, broad: openArray[byte]): bool {.nimcall, gcsafe, raises: [].}
    ## Whether `narrow` is equal to or narrower than `broad`; both are
    ## conforming constraints values of the definition (CAP-0021).

  PermissionSetting* = object
    ## `logos.runtime_control.permission_setting` (RUNTIME l.2348-2351).
    permission*: string
    constraints*: seq[byte]

  PermissionDefinition* = object
    name*: string ## 1..128 bytes
    schema*: string ## the constraints' CDDL: a supporting schema
    root*: string ## its root type
    contains*: Containment
    enforcement*: EnforcementPoint
    unenforceable*: Unenforceable
    revoked*: Revoked
    facilities*: set[Facility]
    containment*: bool
      ## whether the definition claims containment of the access it allows
      ## (CA l.366); false for every shipped definition

  PermissionProfile* = object
    name*: string ## empty: no profile
    definitions*: seq[PermissionDefinition] ## ascending by name bytes
    minimum*: seq[PermissionSetting]
      ## [G110, G279] the permissions every realization's settings must hold
      ## (by name), and the value a Module Loader is constructed with (G253).
      ## Not CA l.345's "required permission scope", which is every saved
      ## setting (TF-32 interim, G217)

  ProfileSource* = proc(): PermissionProfile {.nimcall, gcsafe, raises: [].}
    ## A profile's constructor: what crosses threads.

  PermissionError* = enum
    peUnknown ## not a definition of the profile
    peInvalid ## constraints that are not one conforming deterministic-CBOR value
    peUnordered ## names not strictly ascending by UTF-8 bytes

const
  ProfileV1* = "logos-core-nim.permission-profile.v1" ## [G279]
  HostAmbient* = "logos-core-nim.host-ambient" ## [D25, G110]
  HostAmbientConstraints* = @[0xa0'u8] ## the empty map, its only value
  HostAmbientDocument* = staticRead("permissions/host_ambient.cddl")
  HostAmbientRoot* = "lcn_permissions.host_ambient"
  MaxPermissionName* = 128
  MaxConstraintsBytes* = 1_048_576

func selected*(p: PermissionProfile): bool =
  ## Whether `p` is a profile at all (`NoProfile` is not).
  p.name.len > 0

func index*(p: PermissionProfile, name: string): int =
  ## The definition named `name`, or -1.
  for i, d in p.definitions:
    if d.name == name:
      return i
  -1

func defines*(p: PermissionProfile, name: string): bool =
  p.index(name) >= 0

func active*(d: PermissionDefinition): bool =
  ## [SPEC CA l.362-364, l.417] Whether its enforcement point exists here.
  d.enforcement == epRuntimeAdmission

func activeIn*(p: PermissionProfile, name: string): bool =
  let i = p.index(name)
  i >= 0 and p.definitions[i].active

# Constraint validators, one per schema document and thread -------------------------

var
  validators {.threadvar.}: Table[string, GeneratedSchema]
  validatorsHooked {.threadvar.}: bool

proc dropValidators() {.nimcall, gcsafe, raises: [].} =
  validators = default(Table[string, GeneratedSchema])
  validatorsHooked = false

proc schemaOf(document: string): Result[GeneratedSchema, string] =
  let set = acceptContractSet(document, [], [], AcceptOptions()).valueOr:
    return err("the constraints schema is not accepted: " & error)
  if set.primary.model.role != srSupporting:
    return err("the constraints schema is not a supporting schema")
  ok(loadSchemaSet(set))

proc validator(document: string): Result[GeneratedSchema, string] =
  if not validatorsHooked:
    validatorsHooked = true
    onThreadRelease(dropValidators)
  if document notin validators:
    validators[document] = ?schemaOf(document)
  try:
    ok(validators[document])
  except KeyError:
    err("no validator")

proc conforms*(d: PermissionDefinition, constraints: openArray[byte]): bool =
  ## [SPEC RUNTIME l.2535; CA l.390-392] `constraints` is exactly one Logos
  ## deterministic-CBOR item (D29), with no trailing bytes, that is a value of
  ## the definition's root.
  if constraints.len < 1 or constraints.len > MaxConstraintsBytes:
    return false
  let v = decodeCbor(constraints).valueOr:
    return false
  let g = validator(d.schema).valueOr:
    return false
  g.checkPath(d.root, v).isOk

proc validate*(
    p: PermissionProfile, name: string, constraints: openArray[byte]
): Result[void, PermissionError] =
  ## A defined name, then conforming constraints: an unknown name wins.
  let i = p.index(name)
  if i < 0:
    return err(peUnknown)
  if not p.definitions[i].conforms(constraints):
    return err(peInvalid)
  ok()

proc validate*(
    p: PermissionProfile, s: PermissionSetting
): Result[void, PermissionError] =
  p.validate(s.permission, s.constraints)

func checkOrder*(xs: openArray[PermissionSetting]): Result[void, PermissionError] =
  ## [SPEC RUNTIME l.2461, l.2535] Names unique and ordered by their UTF-8
  ## bytes: the request's own validity, checked before its target (l.1828;
  ## re-pin P4 R3).
  for i in 1 ..< xs.len:
    if not (xs[i - 1].permission < xs[i].permission):
      return err(peUnordered)
  ok()

proc checkDefined*(
    p: PermissionProfile, xs: openArray[PermissionSetting]
): Result[void, PermissionError] =
  ## [SPEC RUNTIME l.2462, l.2536-2537] Every setting defined by the profile
  ## and conforming.
  for s in xs:
    ?p.validate(s)
  ok()

proc checkSettings*(
    p: PermissionProfile, xs: openArray[PermissionSetting]
): Result[void, PermissionError] =
  ## [SPEC RUNTIME l.2535-2537] Names unique and ordered by their UTF-8 bytes,
  ## then every setting defined and conforming.
  ?checkOrder(xs)
  p.checkDefined(xs)

proc contained*(
    p: PermissionProfile, name: string, narrow, broad: openArray[byte]
): bool =
  ## [SPEC CA l.129; CAP-0021] Whether constraints `narrow` are equal to or
  ## narrower than `broad` under the definition `name`. False for an unknown
  ## name or a value that does not conform.
  let i = p.index(name)
  if i < 0:
    return false
  let d = p.definitions[i]
  d.conforms(narrow) and d.conforms(broad) and d.contains(narrow, broad)

func missing*(p: PermissionProfile, xs: openArray[PermissionSetting]): seq[string] =
  ## The `minimum` permissions `xs` does not name.
  for m in p.minimum:
    var found = false
    for s in xs:
      if s.permission == m.permission:
        found = true
        break
    if not found:
      result.add m.permission

proc checkProfile*(p: PermissionProfile): Result[void, string] =
  ## The rules a profile meets: definitions ascending and unique by name, each
  ## schema a supporting schema declaring its root, the minimum ascending,
  ## defined and active.
  if not p.selected:
    return err("a profile has a name")
  for i, d in p.definitions:
    if d.name.len < 1 or d.name.len > MaxPermissionName:
      return err("a definition name has 1 to 128 bytes")
    if i > 0 and not (p.definitions[i - 1].name < d.name):
      return err("definitions are not ascending by name")
    if d.contains == nil:
      return err(d.name & " has no containment")
    let g = ?validator(d.schema)
    if not g.declares(d.root):
      return err(d.name & ": the schema does not declare " & d.root)
  p.checkSettings(p.minimum).isOkOr:
    return err("the minimum is not a valid settings array: " & $error)
  for m in p.minimum:
    if not p.activeIn(m.permission):
      return err("the minimum names " & m.permission & ", which is not active")
  ok()

# The shipped profile (G279) ---------------------------------------------------------

proc sameValue(narrow, broad: openArray[byte]): bool {.nimcall, gcsafe, raises: [].} =
  ## [CAP-0021] Equality of the decoded value: deterministic encodings are
  ## equal exactly when the values are.
  @narrow == @broad

proc hostAmbient*(): PermissionDefinition =
  ## [SPEC CA l.394-407; D25, G110, G283] `logos-core-nim.host-ambient`: every
  ## facility class the host exposes, under one name, with no per-class limit
  ## and no containment; enforced by Runtime admission.
  PermissionDefinition(
    name: HostAmbient,
    schema: HostAmbientDocument,
    root: HostAmbientRoot,
    contains: sameValue,
    enforcement: epRuntimeAdmission,
    unenforceable: ueFailOperation,
    revoked: rvStopExecution,
    facilities: {low(Facility) .. high(Facility)},
    containment: false,
  )

proc profileV1*(): PermissionProfile {.nimcall, gcsafe, raises: [].} =
  ## [G279] `logos-core-nim.permission-profile.v1`.
  PermissionProfile(
    name: ProfileV1,
    definitions: @[hostAmbient()],
    minimum:
      @[PermissionSetting(permission: HostAmbient, constraints: HostAmbientConstraints)],
  )

func builtinProfile*(name: string): Opt[ProfileSource] =
  ## The built-in profile a host configuration may name.
  if name == ProfileV1:
    Opt.some(ProfileSource(profileV1))
  else:
    Opt.none(ProfileSource)

proc build*(source: ProfileSource): PermissionProfile =
  ## This thread's value of `source`; `NoProfile` for nil.
  if source == nil:
    PermissionProfile()
  else:
    source()

const NoProfile* = PermissionProfile()
