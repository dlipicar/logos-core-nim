## The call-evidence key under logosd and its binding to one Runtime (Tier 4b
## step 4b-6; DECISIONS G149, G301; batch E item 19). docs/DAEMON.md §9.
##
## `logosctl init` assigns the Runtime id and makes the key and its kid
## together. The kid is derived from the public key (the first 16 bytes of its
## BLAKE3-256), and `keys/evidence-<kid hex>.cbor` binds kid, Runtime id and
## public key (CA l.1265, l.1269, l.1290). logosd refuses to start, and an
## export is refused, when the configured key, its kid and the Runtime id do
## not match the binding. A rotated key keeps its binding, marked retired,
## and loses its secret half (CA l.1273).

{.push raises: [].}

import std/[os, strutils, times]
import results
import logos_sdk/base/hex
import logos_sdk/crypto/blake3, ../crypto/slhdsa
import ../durable
import ../runtime/evidence
import ./trust_types

export results, trust_types

const
  KidBytes* = 16 ## [IMPL] the kid's length
  BindingFormat* = "logos-core-nim.evidence-key.v1"
  KeyPrefix* = "evidence-"
  KeySuffix* = ".key"
  BindingSuffix* = ".cbor"
  MaxBindingBytes = 4096

type EvidenceKeyInfo* = object ## A binding, with where its secret half is.
  binding*: LcnEvKeyBinding
  keyFile*: string ## empty for a retired key

func kidOf*(pk: PublicKey): seq[byte] =
  ## [IMPL; batch E 19] The first 16 bytes of BLAKE3-256 of the public key.
  let d = blake3(pk)
  @(d.toOpenArray(0, KidBytes - 1))

func keyFileName*(kid: openArray[byte]): string =
  KeyPrefix & kid.toHex & KeySuffix

func bindingFileName*(kid: openArray[byte]): string =
  KeyPrefix & kid.toHex & BindingSuffix

proc nowMs*(): uint64 =
  let t = getTime()
  uint64(t.toUnix) * 1000 + uint64(t.nanosecond div 1_000_000)

proc readBinding*(path: string): Result[LcnEvKeyBinding, string] =
  ## The binding in `path`: one deterministic-CBOR `lcn.ev_key_binding`.
  let bytes = readBounded(path, MaxBindingBytes).valueOr:
    return err(error)
  if bytes.isNone:
    return err("the evidence key has no binding file " & path.extractFilename)
  let b = LcnEvKeyBinding.decode(bytes.get).valueOr:
    return err(path.extractFilename & " is not an evidence key binding: " & error)
  ok(b)

proc writeBinding(dir: string, b: LcnEvKeyBinding): Result[void, string] =
  let bytes = b.encode.valueOr:
    return err(error)
  writeAtomic(dir, bindingFileName(b.kid), bytes)

proc createEvidenceKey*(keysDir, runtimeId: string): Result[EvidenceKeyInfo, string] =
  ## [G149; batch E 19] A new key in `keysDir`, bound to `runtimeId`: the
  ## secret key file (0600, created exclusively), then its binding.
  var (sk, pk) = generateEvidenceKey().valueOr:
    return err(error)
  defer:
    sk.clear()
  let kid = kidOf(pk)
  let keyFile = keysDir / keyFileName(kid)
  ?writeEvidenceKeyFile(keyFile, sk)
  let b = LcnEvKeyBinding(
    kid: kid, runtime_instance_id: runtimeId, public_key: @pk, created_ms: nowMs()
  )
  writeBinding(keysDir, b).isOkOr:
    discard tryRemoveFile(keyFile)
    return err(error)
  ok(EvidenceKeyInfo(binding: b, keyFile: keyFile))

proc checkEvidenceKey*(
    keyFile: string, kid: openArray[byte], runtimeId: string
): Result[void, string] =
  ## [batch E 19] The configured key file, the configured kid and the Runtime
  ## id agree with the binding beside the key file: the kid derives from the
  ## key's public half, the binding names that kid, that public key and that
  ## Runtime, and the key is not retired.
  var sk = loadEvidenceKey(keyFile).valueOr:
    return err(error)
  let pk = evidencePublicKey(sk)
  sk.clear()
  if kidOf(pk) != @kid:
    return err("call_audit.evidence.kid does not match the evidence key")
  let b = ?readBinding(keyFile.parentDir / bindingFileName(kid))
  if b.kid != @kid or b.public_key != @pk:
    return err("the evidence key does not match its binding")
  if b.retired_ms.isSome:
    return err("the evidence key is retired")
  if b.runtime_instance_id != runtimeId:
    return err(
      "the evidence key belongs to Runtime " & b.runtime_instance_id &
        ", not to Runtime " & runtimeId
    )
  ok()

proc listEvidenceKeys*(keysDir: string): Result[seq[EvidenceKeyInfo], string] =
  ## Every binding in `keysDir`, oldest first.
  var xs: seq[EvidenceKeyInfo]
  for name in fileNames(keysDir):
    if name.startsWith(KeyPrefix) and name.endsWith(BindingSuffix):
      let b = ?readBinding(keysDir / name)
      let keyFile = keysDir / keyFileName(b.kid)
      xs.add(
        EvidenceKeyInfo(binding: b, keyFile: (if fileExists(keyFile): keyFile else: ""))
      )
  for i in 1 ..< xs.len:
    var j = i
    while j > 0 and xs[j - 1].binding.created_ms > xs[j].binding.created_ms:
      swap(xs[j - 1], xs[j])
      dec j
  ok(xs)

proc overwriteAndRemove(path: string): Result[void, string] =
  ## The secret key's bytes overwritten with zeros, flushed, then unlinked.
  try:
    var f: File
    if open(f, path, fmReadWriteExisting):
      var zeros: array[SecretKeyBytes, byte]
      discard writeBuffer(f, addr zeros[0], zeros.len)
      flushFile(f)
      close(f)
  except IOError as e:
    return err("the old evidence key could not be overwritten: " & e.msg)
  removeDurably(path.parentDir, path.extractFilename)

proc rotateEvidenceKey*(
    keysDir: string, oldKid: openArray[byte], runtimeId: string
): Result[EvidenceKeyInfo, string] =
  ## [G149; batch E 19] A new key and kid bound to the same Runtime; the old
  ## binding is marked retired and keeps only the public half (P6-29). The
  ## caller points daemon-config at the new key; it applies at the next start.
  var old = ?readBinding(keysDir / bindingFileName(oldKid))
  if old.runtime_instance_id != runtimeId:
    return err("the current evidence key belongs to Runtime " & old.runtime_instance_id)
  let fresh = ?createEvidenceKey(keysDir, runtimeId)
  old.retired_ms = Opt.some(nowMs())
  ?writeBinding(keysDir, old)
  let oldKey = keysDir / keyFileName(oldKid)
  if fileExists(oldKey):
    ?overwriteAndRemove(oldKey)
  ok(fresh)

{.pop.}
