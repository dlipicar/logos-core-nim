## TRANSPORT §8.4.1 l.1258-1264; I99: what the tls-tcp verifier reads from a
## DER certificate: its validity period, Key Usage, Extended Key Usage, the
## critical extensions BoringSSL's path validation would not process, and the
## `SubjectPublicKeyInfo`.

{.push raises: [].}

import results
import ./p256

export results

type CertInfo* = object
  notBefore*: int64 ## POSIX seconds
  notAfter*: int64 ## POSIX seconds
  hasKeyUsage*: bool
  digitalSignature*: bool ## KU permits digital signatures (when present)
  hasExtKeyUsage*: bool
  clientAuth*: bool ## EKU names `id-kp-clientAuth` (when present)
  serverAuth*: bool ## EKU names `id-kp-serverAuth` (when present)
  unhandledCritical*: bool
    ## a critical extension outside BoringSSL's processed set (KU, EKU,
    ## basicConstraints, subjectAltName, the policy extensions, name
    ## constraints): RFC 5280 §4.2 has validation reject it
  spki*: seq[byte] ## DER `SubjectPublicKeyInfo`

proc posixOf(t: ptr ASN1_TIME, what: string): Result[int64, string] =
  var v: int64 = 0
  if t == nil or ASN1_TIME_to_posix(t, addr v) != 1:
    return err("unreadable " & what)
  ok(v)

proc readCertificate*(der: openArray[byte]): Result[CertInfo, string] =
  ## A DER certificate's fields the verifier checks. A certificate whose
  ## extensions do not parse is refused.
  let x = ?parseCertificate(der)
  defer:
    X509_free(x)
  let flags = X509_get_extension_flags(x)
  if (flags and EXFLAG_INVALID.uint32) != 0:
    return err("the certificate's extensions do not parse")
  let notBefore = ?posixOf(X509_get0_notBefore(x), "notBefore")
  let notAfter = ?posixOf(X509_get0_notAfter(x), "notAfter")
  let hasKu = (flags and EXFLAG_KUSAGE.uint32) != 0
  let hasEku = (flags and EXFLAG_XKUSAGE.uint32) != 0
  let eku = X509_get_extended_key_usage(x)
  let pk = X509_get_X509_PUBKEY(x)
  let n = i2d_X509_PUBKEY(pk, nil)
  if n <= 0:
    return err("cannot encode the certificate's public key")
  var spki = newSeq[byte](n)
  var p = addr spki[0]
  if i2d_X509_PUBKEY(pk, addr p) != n:
    return err("cannot encode the certificate's public key")
  ok(
    CertInfo(
      notBefore: notBefore,
      notAfter: notAfter,
      hasKeyUsage: hasKu,
      digitalSignature: hasKu and (X509_get_key_usage(x) and KuDigitalSignature) != 0,
      hasExtKeyUsage: hasEku,
      clientAuth: hasEku and (eku and XKU_SSL_CLIENT.uint32) != 0,
      serverAuth: hasEku and (eku and XKU_SSL_SERVER.uint32) != 0,
      unhandledCritical: (flags and EXFLAG_CRITICAL.uint32) != 0,
      spki: spki,
    )
  )

proc directAnchorProblems*(der: openArray[byte]): seq[string] =
  ## [G324; TRANSPORT l.1244-1248; Tier 5 step 5-7a-1, G408] Why `der` cannot
  ## be a direct anchor of this implementation, which accepts only an anchor
  ## that is the peer's own certificate: a P-256 key; self-issued and signed
  ## by that key; not a CA; Key Usage, if present, permitting digital
  ## signatures; Extended Key Usage, if present, naming both `serverAuth` and
  ## `clientAuth`, since a Runtime is a TLS server and a TLS client; no
  ## critical extension that validation would not process. Empty when it can.
  let x = parseCertificate(der).valueOr:
    return @[error]
  defer:
    X509_free(x)
  var problems: seq[string]
  let flags = X509_get_extension_flags(x)
  if (flags and EXFLAG_INVALID.uint32) != 0:
    return @["its extensions do not parse"]
  let key = X509_get0_pubkey(x)
  if not isP256(key):
    problems.add("its key is not a P-256 key")
  if X509_NAME_cmp(X509_get_subject_name(x), X509_get_issuer_name(x)) != 0 or key == nil or
      X509_verify(x, key) != 1:
    problems.add("it is not self-signed")
    discard sslErrors()
  if (flags and EXFLAG_CA.uint32) != 0:
    problems.add("it is a CA certificate, not an end-entity one")
  if (flags and EXFLAG_KUSAGE.uint32) != 0 and
      (X509_get_key_usage(x) and KuDigitalSignature) == 0:
    problems.add("its Key Usage does not permit digital signatures")
  if (flags and EXFLAG_XKUSAGE.uint32) != 0:
    let eku = X509_get_extended_key_usage(x)
    if (eku and XKU_SSL_SERVER.uint32) == 0:
      problems.add("its Extended Key Usage lacks serverAuth, so it cannot serve")
    if (eku and XKU_SSL_CLIENT.uint32) == 0:
      problems.add("its Extended Key Usage lacks clientAuth, so it cannot connect")
  if (flags and EXFLAG_CRITICAL.uint32) != 0:
    problems.add("it has a critical extension that validation does not process")
  problems

{.pop.}
