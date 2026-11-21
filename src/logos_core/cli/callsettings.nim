## The lcn_call instance's configuration, for the host that composes it
## (Tier 5 step N-2; DECISIONS G343, G344). docs/DAEMON.md §7a.
##
## The value is `lcn_call.settings` (`settings.cddl`): logosd provisions it at
## every start (`provisioned_configuration`, G141) from daemon-config `cli`
## and the trust file; the instance reads it once, at initialization. The
## declaration has no package default: a host that composes lcn_call always
## provisions its value.

{.push raises: [], gcsafe.}

import results
import logos_sdk/kit/rc_types
import ./lcn_call_kit

export results, lcn_call_configuration_types

const
  LcnCallArtifactId* = "lcn_call" ## [G343] the companion library's artifact id
  CliSocketName* = "lcn_call.sock" ## [G344] in `run/`, or in `cli.socket_dir`
  SettingsDocument* = staticRead("settings.cddl")
    ## the schema text, the same bytes the kit's roots were recomputed from
  SettingsRoot* = "lcn_call.settings"

proc encodeSettings*(s: LcnCallSettings): Result[seq[byte], string] =
  ## The value's deterministic CBOR, checked against the schema, for
  ## `provisioned_configuration`.
  encode(s)

proc lcnCallDeclaration*(): Result[seq[byte], string] =
  ## [SPEC CONFIGURATION §2] The `configuration_declaration` of the instance:
  ## the schema binding of `settings.cddl` (its roots recomputed by lcn-gen
  ## from the text), no package default.
  encode(
    LogosNSModuleConfigurationConfigurationDeclaration(
      schema: LogosNSModuleConfigurationSchemaBinding(
        document: SettingsDocument,
        root: SettingsRoot,
        schema_commitment: LogosNSModuleConfigurationSchemaCommitment(
          schema_root: @(configurationRoots.schemaRoot),
          schema_subtree_root: @(configurationRoots.subtreeRoot),
        ),
      )
    )
  )

{.pop.}
