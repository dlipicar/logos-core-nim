## COMMITMENT §9.1: contract extension, the relation in which a contract B
## extends an earlier contract A.
##
## The relation is judged on the canonical models of two constructed documents. A
## verifier establishes it by constructing both schema roots from their explicitly
## supplied documents; a declared claim does not establish it [SPEC COMMITMENT
## §9.1 l.974]. A `SchemaModel` with a commitment-model revision comes only from
## `buildSchema`, so a commitment alone cannot reach this check.

{.push raises: [].}

import std/sets
import ../cbor
import ../base/hex
import ../hash/hashinput
import ./schema

func extendsContract*(b, a: SchemaModel): Result[void, string] =
  ## [SPEC COMMITMENT §9.1 l.966-976] Whether `b` extends `a`, the earlier
  ## contract. The error names the first condition that fails, in the order
  ## the text lists them. [IMPL-DECISION G392] `_module` is compared as the
  ## supplied documents write it (TF-55), and `b` may implement more interfaces
  ## than `a` (l.972).
  const no = "does not extend: "
  if not a.modelId.isCommitmentModelRevision or not b.modelId.isCommitmentModelRevision:
    # [SPEC COMMITMENT §9.1 l.974] no model built from a document
    return err(no & "a model was not constructed from a document")
  if a.modelId != b.modelId:
    return err(no & "commitment-model revision " & b.modelId & " is not " & a.modelId)
  if a.namespace != b.namespace:
    return err(no & "namespace " & b.namespace & " is not " & a.namespace)
  case a.role
  of srModule:
    if b.role != srModule:
      return
        err(no & "only a concrete module contract extends a concrete module contract")
    if a.moduleName.isNone or a.moduleName != b.moduleName:
      return err(no & "the two concrete contracts have different _module values")
  of srInterface:
    if b.role != srInterface:
      return err(no & "only an interface contract extends an interface contract")
  of srSupporting, srCommon:
    return err(no & "a " & $a.role & " schema is not a contract")
  for d in a.declarations:
    # [SPEC COMMITMENT §9.1 l.971] Identical kind, qualified name and body; a
    # method's body carries its sensitivity fields (l.995-1010).
    let x = b.find(d.name).valueOr:
      return err(no & "it omits the declaration " & d.name)
    if x.kind != d.kind:
      return
        err(no & "declaration " & d.name & " is a " & $x.kind & ", not a " & $d.kind)
    if encodeCbor(bodyCbor(x)) != encodeCbor(bodyCbor(d)):
      return err(no & "declaration " & d.name & " has another body")
  let implemented = b.implemented.toHashSet
  for r in a.implemented:
    if r notin implemented:
      return err(no & "it does not implement the interface " & toHex(r))
  ok()
