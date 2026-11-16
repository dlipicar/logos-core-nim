## The export of a stored call record as call evidence: the library part of
## `logosctl audit evidence export` (Tier 4b step 4b-6; DECISIONS G301, G149,
## I85; CAPABILITY AUTHORITY l.1265, l.1290, l.1316-1328). docs/DAEMON.md §9.
##
## The record is read from the session's call-evidence store, and signed with
## the session's current evidence key (the one daemon-config names, checked
## against its binding, batch E 19) for the Runtime that binding names: the
## complete record, with no proofs (CAP-0416, as I85). A seq the store no
## longer holds is refused (CAP-0417), and so is a segment some other Runtime
## wrote: a kid maps to one producer (CA l.1265, l.1290). The owner's command,
## on the owner's own files, is the protected integration's authorization to
## disclose the complete record (I85's reading of CA l.1321). The container
## authorizes nothing (CAP-0256).

{.push raises: [].}

import std/os
import results
import ../runtime/evidence
import ./[config, evkey, evstore, session]

export results

type ExportFailure* = object
  notRetained*: bool ## the seq is not in the store
  message*: string

func failure(message: string, notRetained = false): ExportFailure =
  ExportFailure(notRetained: notRetained, message: message)

proc exportStored*(s: Session, seqNo: uint64): Result[seq[byte], ExportFailure] =
  ## A call-evidence container for the record stored as `seqNo` in `s`.
  let (dc, _) = readDaemonConfig(s).valueOr:
    return err(failure(error))
  if dc.call_audit.isNone or dc.call_audit.get.evidence.isNone:
    return err(failure("call_audit.evidence is not configured"))
  let ev = dc.call_audit.get.evidence.get
  checkEvidenceKey(ev.secret_key_file, ev.kid, dc.runtime.runtime_instance_id).isOkOr:
    return err(failure("call_audit.evidence: " & error))
  let binding = readBinding(s.keysDir / bindingFileName(ev.kid)).valueOr:
    return err(failure(error))
  let found = findRecord(s.evidenceDir, seqNo).valueOr:
    return err(failure(error))
  if found.isNone:
    return err(failure("seq " & $seqNo & " is not retained", notRetained = true))
  let producer = found.get.header.producer
  if producer != binding.runtime_instance_id:
    return err(
      failure(
        found.get.segment & " was written by Runtime " & producer &
          "; the current evidence key belongs to Runtime " & binding.runtime_instance_id
      )
    )
  var key = loadEvidenceKey(ev.secret_key_file).valueOr:
    return err(failure(error))
  var signer = newEvidenceSigner(ev.kid, binding.runtime_instance_id, key).valueOr:
    key.clear()
    return err(failure(error))
  key.clear()
  let container = signer.exportRecord(found.get.record.record)
  signer.clear()
  if container.isErr:
    return err(failure(container.error))
  ok(container.get)

{.pop.}
