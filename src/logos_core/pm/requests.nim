## The Package Manager module's requests as the engine takes them (Tier 5 step 5-6a-1;
## DECISIONS G449, G494): the kit's checked request types (PM App A) mapped onto the
## engine's `OperationRequest`s, as `pmtest_module` mapped them (G449). `facade.nim`
## calls these; `test_pm_module` checks them without linking the kit's exports.
##
## - A typed `package_source` goes through `sourceOf`: the kit checked it against the
##   schema, and the rule the schema cannot state (a provenance locator differs from the
##   archive locator) is `decodeSource`'s, applied here too. A refused one is
##   INVALID_PARAMS.
## - `update_package`'s `current` is the root's `newerThan`; its package is the root's.
## - A `progress_key` is accepted; nothing is published for it in 5-6a.

{.push raises: [], gcsafe.}

import results
import logos_sdk/iface/outcome
import ../package/[records, resolver]
import ./[engine, logos_package_manager_types]

export results, outcome

func identityOf*(i: LogosNSPackageManagerPackageIdentity): PackageIdentity =
  PackageIdentity(package: i.package, version: i.version)

func sourceOf*(s: LogosNSPackageManagerPackageSource): Result[PackageSource, string] =
  ## [SPEC PM §5, §6] A checked request's `package_source` as the engine takes it.
  type K = LogosNSPackageManagerPackageSourceKind
  let source =
    case s.kind
    of K.Lgx:
      PackageSource(
        kind: skLgx,
        storage: s.arm_Lgx.storage,
        objectLocator: s.arm_Lgx.`object`,
        provenanceLocator: s.arm_Lgx.provenance_object,
      )
    of K.Nix:
      PackageSource(
        kind: skNix,
        flakeRef: s.arm_Nix.flake_ref,
        attr: s.arm_Nix.attr,
        lockedRef: s.arm_Nix.locked_ref,
      )
  ?checkSource(source)
  ok(source)

func optSource(
    s: Opt[LogosNSPackageManagerPackageSource]
): Result[Opt[PackageSource], InvocationFailure] =
  if s.isNone:
    return ok(Opt.none(PackageSource))
  let source = sourceOf(s.get).valueOr:
    return err(
      InvocationFailure(code: ecInvalidParams, message: Opt.some("source: " & error))
    )
  ok(Opt.some(source))

func inspectOp*(
    r: LogosNSPackageManagerInspectPackageRequest
): Result[OperationRequest, InvocationFailure] =
  ## [SPEC PM §15 l.1667-1673]
  let source = ?optSource(r.source)
  ok(
    OperationRequest(
      kind: opInspect,
      root: RootReference(package: r.package, version: r.version, source: source),
    )
  )

func installOp*(
    r: LogosNSPackageManagerInstallPackageRequest
): Result[OperationRequest, InvocationFailure] =
  ## [SPEC PM §15 l.1675-1690]
  let source = ?optSource(r.source)
  ok(
    OperationRequest(
      kind: opInstall,
      root:
        RootReference(package: Opt.some(r.package), version: r.version, source: source),
    )
  )

func removeOp*(r: LogosNSPackageManagerRemovePackageRequest): OperationRequest =
  ## [SPEC PM §15 l.1692-1699]
  OperationRequest(kind: opRemove, identity: identityOf(r.identity))

func updateOp*(
    r: LogosNSPackageManagerUpdatePackageRequest
): Result[OperationRequest, InvocationFailure] =
  ## [SPEC PM §15 l.1701-1707] The root is a version of `current`'s package strictly
  ## greater than `current`.
  let source = ?optSource(r.source)
  ok(
    OperationRequest(
      kind: opUpdate,
      root: RootReference(
        package: Opt.some(r.current.package),
        version: r.target_version,
        source: source,
        newerThan: Opt.some(identityOf(r.current)),
      ),
    )
  )
