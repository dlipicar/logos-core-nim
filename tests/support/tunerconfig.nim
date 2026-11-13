## The tuner configuration fixture (DECISIONS I87): the configuration schema
## `tests/kit/tuner_config.cddl`, its binding, declaration and values, shared
## by the configuration, host-config and kit tests. Commitments are recomputed
## from the schema text, never typed in.

import std/os
import results
import ../../src/logos_core/cbor
import ../../src/logos_core/commitment
import ../../src/logos_core/iface/accept
import ../../src/logos_core/runtime/[configcheck, rc_types]

export results

const TunerRoot* = "tuner.config"

let tunerDocument* =
  readFile(currentSourcePath().parentDir.parentDir / "kit" / "tuner_config.cddl")

proc rootsOf*(document, root: string): (seq[byte], seq[byte]) =
  ## The schema root and the root's subtree root, recomputed from the text.
  let set = acceptContractSet(document).tryGet
  let m = set.primary.model
  (@(schemaRoot(m)), @(declarationRoot(m, m.find(root).get)))

proc tunerCommitment*(): LogosNSModuleConfigurationSchemaCommitment =
  let (s, sub) = rootsOf(tunerDocument, TunerRoot)
  LogosNSModuleConfigurationSchemaCommitment(schema_root: s, schema_subtree_root: sub)

proc tunerBinding*(live = false): LogosNSModuleConfigurationSchemaBinding =
  LogosNSModuleConfigurationSchemaBinding(
    document: tunerDocument,
    root: TunerRoot,
    schema_commitment: tunerCommitment(),
    live_reconfiguration: (if live: Opt.some(true) else: Opt.none(bool)),
  )

proc tunerValue*(station = "radio-1", volume = 5'u64, pad = 0): seq[byte] =
  ## One deterministic `tuner.config`; `pad` bytes make it as large as needed.
  var entries = @[(cbor("station"), cbor(station)), (cbor("volume"), cbor(volume))]
  if pad > 0:
    entries.add((cbor("pad"), cbor(newSeq[byte](pad))))
  encodeCbor(cborMap(entries))

proc tunerDecl*(
    default = Opt.none(seq[byte]), live = false
): LogosNSModuleConfigurationConfigurationDeclaration =
  LogosNSModuleConfigurationConfigurationDeclaration(
    schema: tunerBinding(live), default_value: default
  )

proc tunerDeclBytes*(default = Opt.none(seq[byte]), live = false): seq[byte] =
  ## The declaration as a host configuration carries it.
  encode(tunerDecl(default, live)).tryGet

proc tunerAccepted*(
    default = Opt.none(seq[byte]), provisioned = Opt.none(seq[byte]), live = false
): AcceptedConfiguration =
  acceptConfiguration(tunerDecl(default, live), provisioned).tryGet

proc tunerInput*(value: seq[byte], revision = 1'u64): seq[byte] =
  ## One `configuration_input` of `value` under the tuner schema, as a
  ## Runtime delivers it.
  encode(
    LogosNSModuleConfigurationConfigurationInput(
      schema_commitment: tunerCommitment(), value: value, value_revision: revision
    )
  ).tryGet
