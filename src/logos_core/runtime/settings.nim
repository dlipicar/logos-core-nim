## RUNTIME §9.3 l.2526-2604; DECISIONS I93 (part b), G281, G285: one module
## instance's permission settings while a permission profile is selected. The
## pure parts: the state, what a replacement or a settlement makes of it, and
## the `prm` side record's codec. The engine (`engine.nim`) holds the glue:
## when to write, publish and stop.
##
## Without a profile none of this is used: every instance has the constant
## form of G229 (`engine.permissionSettings`).

{.push raises: [], gcsafe.}

import results
import ../permissions
import ../kit/rc_types, ./store_types

export results

const PrmSide* = "prm" ## [I93] the side-record kind of an instance's settings

type
  SettingsApplication* = enum
    ## [SPEC RUNTIME l.2591-2601] `permission_settings_state.application`.
    saPending = "pending" ## the saved settings are being reconciled
    saApplied = "applied" ## the saved settings are enforced
    saFailed = "failed" ## enforcement failed: `failure` is `enforcement-failed`

  SettingsState* = object
    ## One instance's saved settings and their application status. `failure`
    ## is implied: `enforcement-failed` exactly when `saFailed` (R l.2549).
    revision*: uint64 ## positive; advanced per accepted replacement (l.2584)
    permissions*: seq[PermissionSetting] ## ascending by name, unique (l.2537)
    application*: SettingsApplication

  Remains* = enum
    ## [G281, G285] What is left of the instance's realization when a
    ## replacement arrives or a settlement is due.
    rmNone ## no attempt, realization or teardown remains
    rmRunning
      ## one remains and its stop or cleanup can still establish absence:
      ## `loaded`, `ready`, `stopping`, or `error` with ordinary cleanup
    rmOverrun
      ## one may persist with the old access: `error` with `cleanup-timeout`
      ## or `cleanup-failed`, or a realization its Loader lost

const EnforcementFailed* = "enforcement-failed"
  ## [SPEC RUNTIME l.2549] the one defined `failure` value

func initialSettings*(permissions: seq[PermissionSetting]): SettingsState =
  ## [SPEC RUNTIME l.2541-2543; G281 (K25 (a))] A new instance's settings:
  ## revision 1, `applied`; empty unless protected provisioning supplies
  ## them.
  SettingsState(revision: 1, permissions: permissions, application: saApplied)

func inactive*(p: PermissionProfile, xs: openArray[PermissionSetting]): bool =
  ## [IMPL-DECISION G280] Some setting names a definition no active point
  ## enforces: it cannot be applied (K25 (c)).
  for s in xs:
    if not p.activeIn(s.permission):
      return true
  false

func sameArray*(a, b: openArray[PermissionSetting]): bool =
  ## The same complete array: the same names and constraints, in order.
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i].permission != b[i].permission or a[i].constraints != b[i].constraints:
      return false
  true

func repeats*(s: SettingsState, xs: openArray[PermissionSetting]): bool =
  ## [SPEC RUNTIME l.2584; RUN-0475] Repeating `pending` or `applied`
  ## settings at the current revision returns the existing state: no update
  ## and no restart. A repeat of `failed` settings is a new replacement
  ## (l.2585).
  s.application != saFailed and s.permissions.sameArray(xs)

func replaced*(
    s: SettingsState,
    xs: seq[PermissionSetting],
    remains: Remains,
    profile: PermissionProfile,
): SettingsState =
  ## [SPEC RUNTIME l.2583-2601; G281, G285] A new replacement: the next
  ## revision, and its application status. While a realization remains it is
  ## `pending`, to be reconciled by stopping it; when one may persist with
  ## the old access it is `failed` at once; with none it is `applied`, to be
  ## enforced at the next admission, or `failed` when a named definition is
  ## inactive.
  result = SettingsState(revision: s.revision + 1, permissions: xs)
  result.application =
    case remains
    of rmRunning:
      saPending
    of rmOverrun:
      saFailed
    of rmNone:
      if profile.inactive(xs): saFailed else: saApplied

func settled*(
    s: SettingsState, remains: Remains, profile: PermissionProfile
): Opt[SettingsApplication] =
  ## [SPEC RUNTIME l.2591, l.2600; G281, G285] The status `pending` settings
  ## settle to now, if they settle: `applied` once no realization remains
  ## (`failed` for an inactive definition), `failed` once one may persist past
  ## its stop deadline; none while a stop or cleanup can still complete.
  if s.application != saPending:
    return Opt.none(SettingsApplication)
  case remains
  of rmRunning:
    Opt.none(SettingsApplication)
  of rmOverrun:
    Opt.some(saFailed)
  of rmNone:
    Opt.some(if profile.inactive(s.permissions): saFailed else: saApplied)

# Runtime Control values ----------------------------------------------------------------

func toRc*(
    xs: openArray[PermissionSetting]
): seq[LogosNSRuntimeControlPermissionSetting] =
  for s in xs:
    result.add(
      LogosNSRuntimeControlPermissionSetting(
        permission: s.permission, constraints: s.constraints
      )
    )

func fromRc*(
    xs: openArray[LogosNSRuntimeControlPermissionSetting]
): seq[PermissionSetting] =
  for s in xs:
    result.add(PermissionSetting(permission: s.permission, constraints: s.constraints))

func toRc*(s: SettingsState): LogosNSRuntimeControlPermissionSettingsState =
  ## [SPEC RUNTIME l.2362-2367, l.2549] The reported state.
  type
    K = LogosNSRuntimeControlPermissionSettingsStateApplicationChoiceKind
    C = LogosNSRuntimeControlPermissionSettingsStateApplicationChoice

  result = LogosNSRuntimeControlPermissionSettingsState(
    revision: s.revision,
    permissions: s.permissions.toRc,
    application:
      case s.application
      of saPending:
        C(kind: K.Pending)
      of saApplied:
        C(kind: K.Applied)
      of saFailed:
        C(kind: K.Failed),
  )
  if s.application == saFailed:
    result.failure = Opt.some(EnforcementFailed)

# The `prm` side record ----------------------------------------------------------------

proc prmBytes*(s: SettingsState): Result[seq[byte], string] =
  ## [I93] The `prm` side record of one instance (`store.cddl`).
  type K = LcnPrmRecordApplicationChoiceKind
  var r = LcnPrmRecord(revision: s.revision)
  for x in s.permissions:
    r.permissions.add(
      LcnRsPermissionSetting(permission: x.permission, constraints: x.constraints)
    )
  r.application = LcnPrmRecordApplicationChoice(
    kind:
      case s.application
      of saPending: K.Pending
      of saApplied: K.Applied
      of saFailed: K.Failed
  )
  if s.application == saFailed:
    r.failure = Opt.some(EnforcementFailed)
  encode(r)

proc settingsOf*(data: openArray[byte]): Result[SettingsState, string] =
  ## A `prm` side record read back: its revision positive and `failure`
  ## present exactly with `failed` (l.2549, l.2583). Its names and
  ## constraints are checked against the selected profile by the caller.
  type K = LcnPrmRecordApplicationChoiceKind
  let r = ?LcnPrmRecord.decode(data)
  if r.revision == 0:
    return err("the settings revision is 0")
  var s = SettingsState(revision: r.revision)
  for x in r.permissions:
    s.permissions.add(
      PermissionSetting(permission: x.permission, constraints: x.constraints)
    )
  s.application =
    case r.application.kind
    of K.Pending: saPending
    of K.Applied: saApplied
    of K.Failed: saFailed
  if (s.application == saFailed) != r.failure.isSome:
    return err("failure is present exactly with failed settings")
  if r.failure.isSome and r.failure.get != EnforcementFailed:
    return err("the settings failure is not " & EnforcementFailed)
  ok(s)
