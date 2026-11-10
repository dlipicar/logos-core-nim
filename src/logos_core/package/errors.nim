## PM §14: the package error codes, as the package/ modules report them.

{.push raises: [].}

type
  PackageErrorCode* = enum
    ## [SPEC PM §14] `logos.package_manager.package_error_code`, in CDDL order
    ## (a test checks it against the mirrored block).
    pecInvalidRequest = "invalid-request"
    pecUnsupportedSource = "unsupported-source"
    pecPackageUnavailable = "package-unavailable"
    pecPackageNotInstalled = "package-not-installed"
    pecPackageConflict = "package-conflict"
    pecPackageInUse = "package-in-use"
    pecInvalidPackage = "invalid-package"
    pecIncompatiblePlatform = "incompatible-platform"
    pecDependencyUnavailable = "dependency-unavailable"
    pecArtifactIntegrity = "artifact-integrity-failed"
    pecSignature = "signature-verification-failed"

  PackageError* = object
    code*: PackageErrorCode
    msg*: string
      ## local diagnostic; a Package Manager response carries at most 512 bytes
      ## of it and never host paths or protected input (§14)

func packageError*(code: PackageErrorCode, msg: string): PackageError =
  PackageError(code: code, msg: msg)

func `$`*(e: PackageError): string =
  $e.code & ": " & e.msg
