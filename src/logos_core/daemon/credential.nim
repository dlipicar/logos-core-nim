## The Runtime's TLS credential for `logos.remote.tls-tcp` (Tier 5 step 5-7a-1;
## DECISIONS G409; owner decision B2; TRANSPORT l.1238-1248; RUNTIME
## l.2657-2664). docs/DAEMON.md §6b.
##
## `logosctl remote credential new` makes a P-256 key and a self-signed
## certificate for it: the direct anchor peers enroll this Runtime under
## (G324). The certificate's Key Usage permits digital signatures and it has no
## Extended Key Usage, so it serves and connects (T l.1246-1248); its subject
## is for people only (T l.1269). Its files, under the session's
## `remote/credential/`:
##
## - `key.p8`: the private key, PKCS#8 DER, mode 0600, written to a temporary
##   file in the same directory, flushed and renamed (`durable.writeAtomic`);
## - `cert.der`: the certificate;
## - `peer.cbor`: one `lcn.remote_peer` (remote_trust.cddl), the anchor and this
##   Runtime's `active` enrollment naming it and the one key, for the operator
##   to give each peer (`logosctl remote trust import @peer.cbor`).
##
## **Rotation is a cutover** (B2; G324 limit 1: an enrollment names one anchor,
## and a direct anchor has one key, so R l.2657-2659's overlap record cannot
## work here). `rotate` writes the next credential to `remote/credential-next/`
## with its enrollment at the next revision and the new key only. Each peer
## takes the new anchor and record offline; this logosd takes the new
## credential up at its next start with `remote.enabled`
## (`takeUpCredential`): `credential/` is renamed `credential-old/`,
## `credential-next/` is renamed `credential/`, and `credential-old/` is
## removed, each step durable, so a crash leaves one of the three states the
## next start finishes from. Connections fail in between (docs/REMOTE.md).
##
## **Key separation** (PKG-0435; CAP-0401; CA l.1312). The key has its own
## file and its own command. Only `loadCredentialKey` reads it, from this one
## path, and only logosd's signing service and the key holder call that; no
## package, provenance or evidence code reads it. A call-evidence key is 96
## bytes of SLH-DSA, never PKCS#8, and the evidence loader takes only that
## shape, so neither loader accepts the other's file.

{.push raises: [].}

import std/[os, strutils, times]
import results
import logos_sdk/base/wipe
import ../durable
import ../transport/tls/[p256, x509]
import ./[remote_trust_types, remotetrust, session]

when defined(posix):
  import std/posix

  var O_NOFOLLOW {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

export results

const
  CredentialName* = "credential"
  NextCredentialName* = "credential-next"
  OldCredentialName* = "credential-old"
  KeyName* = "key.p8"
  CertName* = "cert.der"
  PeerName* = "peer.cbor"
  PeerFormat* = "logos-core-nim.remote-peer.v1"
  DefaultValidityDays* = 3650 ## [IMPL; B2's "long validity"] ten years
  MaxValidityDays* = 36500
  ClockSkewSeconds* = 300
    ## [IMPL] notBefore is this much before now, so a peer whose clock is a
    ## little behind accepts a credential made just now
  MaxKeyBytes = 1024
  MaxCertBytes = 16384
  MaxPeerBytes = 65536
  KeyUsage = "critical,digitalSignature"
  CommonNamePrefix = "logos runtime "

type CredentialInfo* = object ## A credential's public parts.
  dir*: string
  certificate*: seq[byte]
  certificateSha256*: seq[byte]
  spki*: seq[byte]
  anchorId*: seq[byte]
  notBefore*: int64
  notAfter*: int64
  peer*: LcnRemotePeer
  peerFile*: string

func credentialDir*(s: Session): string =
  s.remoteDir / CredentialName

func nextCredentialDir*(s: Session): string =
  s.remoteDir / NextCredentialName

func oldCredentialDir(s: Session): string =
  s.remoteDir / OldCredentialName

func keyPath*(dir: string): string =
  dir / KeyName

func revisionOf*(c: CredentialInfo): uint64 =
  revisionOf(c.peer.enrollment)

proc present(dir: string): bool =
  try:
    dirExists(dir)
  except CatchableError:
    false

proc protectedFile(path: string): Result[bool, string] =
  ## Whether `path` is present, checked as `session.readSessionFile` checks a
  ## file (a regular file of this user, mode 0600, never a link) without
  ## opening it: logosd in key-holder mode never opens the key (G410).
  when defined(posix):
    var st: Stat
    if lstat(cstring(path), st) != 0:
      if errno == ENOENT:
        return ok(false)
      return err(path & " cannot be read: " & $strerror(errno))
    if not S_ISREG(st.st_mode):
      return err(path & " is not a regular file")
    if st.st_uid != getuid():
      return err(path & " is owned by another user")
    if (int(st.st_mode) and 0o077) != 0:
      return err(path & " is accessible to group or other")
    ok(true)
  else:
    try:
      ok(fileExists(path))
    except CatchableError as e:
      err(e.msg)

# Reading ---------------------------------------------------------------------------------

proc readCredential*(dir: string): Result[CredentialInfo, string] =
  ## The public parts of the credential in `dir`: the certificate, the peer
  ## file, and that they agree (the peer's anchor is this certificate, its
  ## enrollment `active` for this certificate's key alone). The key is not
  ## read; its file must be present and protected.
  let where = dir.extractFilename
  let cert = (?readSessionFile(dir / CertName, MaxCertBytes)).valueOr:
    return err("there is no " & where & "/" & CertName)
  let peerBytes = (?readSessionFile(dir / PeerName, MaxPeerBytes)).valueOr:
    return err("there is no " & where & "/" & PeerName)
  if not ?protectedFile(dir / KeyName):
    return err("there is no " & where & "/" & KeyName)
  let info = ?readCertificate(cert)
  let peer = ?decodePeer(peerBytes)
  let id = anchorIdOf(cert)
  if peer.anchor.id != id or peer.anchor.certificate != cert:
    return err(where & "/" & PeerName & " does not hold " & where & "/" & CertName)
  let r = peer.enrollment
  if not r.active or r.arm_Active.trust_anchor != id or keysOf(r) != @[info.spki]:
    return err(
      where & "/" & PeerName &
        " does not enroll the certificate's key alone under its anchor"
    )
  let digest = ?sha256Of(cert)
  ok(
    CredentialInfo(
      dir: dir,
      certificate: cert,
      certificateSha256: digest,
      spki: info.spki,
      anchorId: id,
      notBefore: info.notBefore,
      notAfter: info.notAfter,
      peer: peer,
      peerFile: dir / PeerName,
    )
  )

proc loadCredentialKey*(dir: string): Result[P256Key, string] =
  ## [G409, G410] The private key of the credential in `dir`, for logosd's
  ## signing service or the key holder: `key.p8`, a protected regular file
  ## (never a link), one PKCS#8 P-256 key, whose public key is the
  ## certificate's. The bytes read are wiped.
  let info = ?readCredential(dir)
  var bytes = (?readSessionFile(dir / KeyName, MaxKeyBytes)).valueOr:
    return err("there is no " & dir.extractFilename & "/" & KeyName)
  let key = fromPkcs8(bytes)
  wipe(bytes)
  let k = key.valueOr:
    return err(dir.extractFilename & "/" & KeyName & ": " & error)
  let spki = spkiDer(k).valueOr:
    k.free()
    return err(error)
  if spki != info.spki:
    k.free()
    return err(
      dir.extractFilename & "/" & KeyName & " is not the key of " & dir.extractFilename &
        "/" & CertName
    )
  ok(k)

proc currentCredential*(s: Session): Result[Opt[CredentialInfo], string] =
  ## The credential in use, none when the session has none.
  if not present(s.credentialDir):
    return ok(Opt.none(CredentialInfo))
  ok(Opt.some(?readCredential(s.credentialDir)))

proc pendingCredential*(s: Session): Result[Opt[CredentialInfo], string] =
  ## The credential a rotation wrote, taken up at the next start.
  if not present(s.nextCredentialDir):
    return ok(Opt.none(CredentialInfo))
  ok(Opt.some(?readCredential(s.nextCredentialDir)))

# Writing ---------------------------------------------------------------------------------

proc overwriteKey(key: string, n: int) =
  ## Zeros over the key's bytes, through a descriptor that cannot read them
  ## and follows no link: logosd takes a rotation up in key-holder mode too,
  ## where it never reads the key (G410).
  var zeros = newSeq[byte](n)
  when defined(posix):
    let fd = posix.open(cstring(key), O_WRONLY or O_NOFOLLOW or O_CLOEXEC)
    if fd >= 0:
      discard posix.write(fd, addr zeros[0], zeros.len)
      discard fsync(fd)
      discard posix.close(fd)
  else:
    # [IMPL] Best effort, as the POSIX branch's discards: a write or a flush that
    # fails still closes the file, and the key is removed after.
    var f: File
    if open(f, key, fmReadWriteExisting):
      try:
        discard writeBuffer(f, addr zeros[0], zeros.len)
        flushFile(f)
      except IOError:
        discard
      close(f)

proc removeCredentialDir(dir: string): Result[void, string] =
  ## The key overwritten and removed, then the other files and the directory.
  if not present(dir):
    return ok()
  let key = dir / KeyName
  try:
    if fileExists(key):
      let n = getFileSize(key)
      if n > 0 and n <= MaxKeyBytes:
        overwriteKey(key, int(n))
    for name in [
      KeyName,
      CertName,
      PeerName,
      KeyName & ".tmp",
      CertName & ".tmp",
      PeerName & ".tmp",
    ]:
      ?removeIfPresent(dir / name)
    removeDir(dir, checkDir = false)
  except CatchableError as e:
    return err("cannot remove " & dir & ": " & e.msg)
  syncDir(dir.parentDir)

proc writeCredential(
    dir, runtime: string, revision: uint64, days: int, now: int64
): Result[CredentialInfo, string] =
  if not isRuntimeIdV4(runtime):
    return err(
      "runtime.runtime_instance_id " & runtime.escape &
        " is not a lowercase UUID version 4, which the remote profiles need (RUNTIME l.2592)"
    )
  if days notin 1 .. MaxValidityDays:
    return err("the validity is 1 to " & $MaxValidityDays & " days")
  ?ensurePrivateDir(dir.parentDir)
  ?ensurePrivateDir(dir)
  let key = ?newP256Key()
  defer:
    key.free()
  let cert = ?selfSignedCertificate(
    key,
    CertificateOptions(
      commonName: CommonNamePrefix & runtime,
      notBefore: now - ClockSkewSeconds,
      notAfter: now + int64(days) * 86400,
      keyUsage: KeyUsage,
      extendedKeyUsage: "",
    ),
  )
  let spki = ?spkiDer(key)
  let id = anchorIdOf(cert)
  let record = ?activeRecord(runtime, TlsTcpProfile, revision, id, [spki])
  let peer = LcnRemotePeer(
    format: PeerFormat,
    anchor: LcnRemoteAnchor(id: id, certificate: cert),
    enrollment: record,
  )
  let peerBytes = ?peer.encode
  var pkcs8 = ?toPkcs8(key)
  let wrote = writeAtomic(dir, KeyName, pkcs8)
  wipe(pkcs8)
  ?wrote
  ?writeAtomic(dir, CertName, cert)
  ?writeAtomic(dir, PeerName, peerBytes)
  readCredential(dir)

proc nowSeconds(): int64 =
  getTime().toUnix

proc newCredential*(
    s: Session, runtime: string, days = DefaultValidityDays
): Result[CredentialInfo, string] =
  ## [G409] The session's first credential, enrolled at revision 1. Refused
  ## when it has one: `rotate` replaces a credential.
  if present(s.credentialDir) or present(s.nextCredentialDir) or
      present(s.oldCredentialDir):
    return err(
      "this session has a TLS credential: logosctl remote credential rotate makes the next one"
    )
  writeCredential(s.credentialDir, runtime, 1, days, nowSeconds())

proc rotateCredential*(
    s: Session, runtime: string, days = DefaultValidityDays
): Result[CredentialInfo, string] =
  ## [G409; B2] The next credential, in `credential-next/`, enrolled at the
  ## current record's revision + 1 with the new key alone. Refused while one
  ## is pending.
  let cur = (?currentCredential(s)).valueOr:
    return err(
      "this session has no TLS credential: logosctl remote credential new makes one"
    )
  if present(s.nextCredentialDir):
    return err(
      "a rotation is pending; logosd takes it up at its next start with remote.enabled"
    )
  if keyOf(cur.peer.enrollment).runtime != runtime:
    return err(
      "the credential enrolls Runtime " & keyOf(cur.peer.enrollment).runtime &
        ", not this session's " & runtime
    )
  let rev = cur.revisionOf
  if rev == high(uint64):
    return err("the enrollment revision cannot be raised")
  writeCredential(s.nextCredentialDir, runtime, rev + 1, days, nowSeconds())

proc rename(src, dst: string): Result[void, string] =
  try:
    moveDir(src, dst)
  except CatchableError as e:
    return err("cannot rename " & src & " to " & dst & ": " & e.msg)
  syncDir(dst.parentDir)

proc takeUpCredential*(s: Session): Result[bool, string] =
  ## [G409] At a start with `remote.enabled`: a pending rotation becomes the
  ## credential in use, finishing one a crash interrupted. True when the
  ## credential changed.
  let cur = s.credentialDir
  let next = s.nextCredentialDir
  let old = s.oldCredentialDir
  if not present(cur) and present(old):
    # Interrupted between the two renames.
    if not present(next):
      return err(
        "remote/" & OldCredentialName & " is left without remote/" & NextCredentialName &
          ": restore remote/" & CredentialName & " by hand"
      )
    discard ?readCredential(next)
    ?rename(next, cur)
    ?removeCredentialDir(old)
    return ok(true)
  if present(old):
    # Interrupted after the second rename.
    ?removeCredentialDir(old)
  if not present(next):
    return ok(false)
  discard ?readCredential(next)
  if present(cur):
    ?rename(cur, old)
  ?rename(next, cur)
  ?removeCredentialDir(old)
  ok(true)

{.pop.}
