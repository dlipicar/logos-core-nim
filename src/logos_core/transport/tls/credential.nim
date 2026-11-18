## TRANSPORT §8.4.1 l.1238-1239; RUNTIME l.2682-2683; I99: the P-256
## credential of `logos.remote.tls-tcp`: a key, its PKCS#8 form, a self-signed
## X.509 v3 certificate, the DER `SubjectPublicKeyInfo` an enrollment holds, and
## `ecdsa_secp256r1_sha256` signing for whoever holds the key (the signing
## service of 5-7a; tests). B2's offline command (5-7a) decides validity, usage
## and where the files live; nothing here writes a file.

{.push raises: [].}

import results
import logos_sdk/base/wipe
import ./boring

export results

type
  P256Key* = ref object
    ## A P-256 key pair in BoringSSL's memory, which zeroes it when freed. Free
    ## it with `free`.
    pkey: ptr EVP_PKEY

  CertificateOptions* = object
    ## The certificate `selfSignedCertificate` makes. `keyUsage` and
    ## `extendedKeyUsage` are X.509 v3 configuration values ("" leaves the
    ## extension out).
    commonName*: string ## for people only: identity comes from enrollment (T l.1269)
    notBefore*: int64 ## POSIX seconds
    notAfter*: int64 ## POSIX seconds
    keyUsage*: string ## e.g. "critical,digitalSignature"
    extendedKeyUsage*: string ## e.g. "clientAuth,serverAuth"

proc free*(k: P256Key) =
  if k != nil and k.pkey != nil:
    EVP_PKEY_free(k.pkey)
    k.pkey = nil

proc raw*(k: P256Key): ptr EVP_PKEY =
  ## The key for BoringSSL calls in this tree; nil once freed.
  k.pkey

proc isP256(pkey: ptr EVP_PKEY): bool =
  if pkey == nil or EVP_PKEY_id(pkey) != EVP_PKEY_EC.cint:
    return false
  let ec = EVP_PKEY_get0_EC_KEY(pkey)
  ec != nil and EC_GROUP_get_curve_name(EC_KEY_get0_group(ec)) == NID_X9_62_prime256v1

proc newP256Key*(): Result[P256Key, string] =
  ## A new key from BoringSSL's CSPRNG.
  let pctx = EVP_PKEY_CTX_new_id(EVP_PKEY_EC.cint, nil)
  if pctx == nil:
    return err("cannot make a key context: " & sslErrors())
  var pkey: ptr EVP_PKEY = nil
  let made =
    EVP_PKEY_keygen_init(pctx) == 1 and
    EVP_PKEY_CTX_set_ec_paramgen_curve_nid(pctx, NID_X9_62_prime256v1) == 1 and
    EVP_PKEY_keygen(pctx, addr pkey) == 1
  EVP_PKEY_CTX_free(pctx)
  if not made or pkey == nil:
    return err("cannot make a P-256 key: " & sslErrors())
  ok(P256Key(pkey: pkey))

proc finishCbb(cbb: var CBB): Result[seq[byte], string] =
  var p: ptr uint8 = nil
  var n: csize_t = 0
  if CBB_finish(addr cbb, addr p, addr n) != 1:
    CBB_cleanup(addr cbb)
    return err("cannot encode: " & sslErrors())
  let bytes = copyBytes(p, int(n))
  OPENSSL_free(p) # OPENSSL_free zeroes what it frees
  ok(bytes)

proc toPkcs8*(k: P256Key): Result[seq[byte], string] =
  ## The private key as unencrypted PKCS#8 DER. The caller wipes it.
  if k == nil or k.pkey == nil:
    return err("no key")
  var cbb: CBB
  if CBB_init(addr cbb, 128) != 1:
    return err("cannot encode: " & sslErrors())
  if EVP_marshal_private_key(addr cbb, k.pkey) != 1:
    CBB_cleanup(addr cbb)
    return err("cannot encode the key: " & sslErrors())
  finishCbb(cbb)

proc fromPkcs8*(der: openArray[byte]): Result[P256Key, string] =
  ## A P-256 key from PKCS#8 DER, with nothing after it. The caller wipes `der`.
  if der.len == 0:
    return err("empty key")
  var cbs = CBS(data: unsafeAddr der[0], len: csize_t(der.len))
  let pkey = EVP_parse_private_key(addr cbs)
  if pkey == nil:
    return err("not a PKCS#8 private key: " & sslErrors())
  if cbs.len != 0:
    EVP_PKEY_free(pkey)
    return err("bytes after the PKCS#8 private key")
  if not isP256(pkey):
    EVP_PKEY_free(pkey)
    return err("not a P-256 key")
  ok(P256Key(pkey: pkey))

proc spkiDer*(k: P256Key): Result[seq[byte], string] =
  ## [SPEC RUNTIME l.2682-2683] the DER `SubjectPublicKeyInfo` an enrollment's
  ## `subject_public_keys` holds.
  if k == nil or k.pkey == nil:
    return err("no key")
  var cbb: CBB
  if CBB_init(addr cbb, 128) != 1:
    return err("cannot encode: " & sslErrors())
  if EVP_marshal_public_key(addr cbb, k.pkey) != 1:
    CBB_cleanup(addr cbb)
    return err("cannot encode the public key: " & sslErrors())
  finishCbb(cbb)

proc parseCertificate*(der: openArray[byte]): Result[ptr X509, string] =
  ## A DER certificate, with nothing after it. The caller frees it with
  ## `X509_free`.
  if der.len == 0:
    return err("empty certificate")
  var p = unsafeAddr der[0]
  let x = d2i_X509(nil, addr p, clong(der.len))
  if x == nil:
    return err("not a DER certificate: " & sslErrors())
  if cast[uint](p) - cast[uint](unsafeAddr der[0]) != uint(der.len):
    X509_free(x)
    return err("bytes after the certificate")
  ok(x)

proc certificateSpki*(der: openArray[byte]): Result[seq[byte], string] =
  ## The DER `SubjectPublicKeyInfo` of a DER certificate.
  let x = ?parseCertificate(der)
  let pk = X509_get_X509_PUBKEY(x)
  let n = i2d_X509_PUBKEY(pk, nil)
  if n <= 0:
    X509_free(x)
    return err("cannot encode the certificate's public key")
  var spki = newSeq[byte](n)
  var p = addr spki[0]
  let written = i2d_X509_PUBKEY(pk, addr p)
  X509_free(x)
  if written != n:
    return err("cannot encode the certificate's public key")
  ok(spki)

proc addExtension(x: ptr X509, nid: cint, value: string): Result[void, string] =
  if value.len == 0:
    return ok()
  let ext = X509V3_EXT_nconf_nid(nil, nil, nid, value.cstring)
  if ext == nil:
    return err("bad extension value " & value & ": " & sslErrors())
  let added = X509_add_ext(x, ext, -1) == 1
  X509_EXTENSION_free(ext)
  if not added:
    return err("cannot add an extension: " & sslErrors())
  ok()

proc fillCertificate(
    x: ptr X509, k: P256Key, o: CertificateOptions
): Result[void, string] =
  if X509_set_version(x, X509_VERSION_3) != 1:
    return err("cannot set the version")
  let bn = BN_new()
  if bn == nil:
    return err("out of memory")
  # A positive serial of at most 127 bits, from the CSPRNG (RFC 5280 §4.1.2.2).
  let serialSet =
    BN_rand(bn, 127, -1, 0) == 1 and
    BN_to_ASN1_INTEGER(bn, X509_get_serialNumber(x)) != nil
  BN_free(bn)
  if not serialSet:
    return err("cannot set the serial number: " & sslErrors())
  if ASN1_TIME_set_posix(X509_getm_notBefore(x), o.notBefore) == nil or
      ASN1_TIME_set_posix(X509_getm_notAfter(x), o.notAfter) == nil:
    return err("cannot set the validity: " & sslErrors())
  let name = X509_get_subject_name(x)
  if X509_NAME_add_entry_by_NID(
    name,
    NID_commonName,
    MbstringAsc,
    cast[ptr uint8](o.commonName.cstring),
    cint(o.commonName.len),
    -1,
    0,
  ) != 1:
    return err("cannot set the common name: " & sslErrors())
  if X509_set_issuer_name(x, name) != 1 or X509_set_pubkey(x, k.pkey) != 1:
    return err("cannot set the issuer or key: " & sslErrors())
  ?addExtension(x, NID_key_usage.cint, o.keyUsage)
  ?addExtension(x, NID_ext_key_usage.cint, o.extendedKeyUsage)
  if X509_sign(x, k.pkey, EVP_sha256()) <= 0:
    return err("cannot sign the certificate: " & sslErrors())
  ok()

proc selfSignedCertificate*(
    k: P256Key, o: CertificateOptions
): Result[seq[byte], string] =
  ## A self-signed X.509 v3 certificate for `k` as DER: subject and issuer one
  ## common name, a random serial, `o`'s validity and extensions, signed with
  ## `ecdsa-with-SHA256`.
  if k == nil or k.pkey == nil:
    return err("no key")
  if o.commonName.len == 0 or o.commonName.len > 64:
    return err("the common name must be 1 to 64 octets")
  if o.notAfter < o.notBefore:
    return err("notAfter is before notBefore")
  let x = X509_new()
  if x == nil:
    return err("out of memory")
  let filled = fillCertificate(x, k, o)
  if filled.isErr:
    X509_free(x)
    return err(filled.error)
  let n = i2d_X509(x, nil)
  if n <= 0:
    X509_free(x)
    return err("cannot encode the certificate")
  var der = newSeq[byte](n)
  var p = addr der[0]
  let written = i2d_X509(x, addr p)
  X509_free(x)
  if written != n:
    return err("cannot encode the certificate")
  ok(der)

proc signP256*(k: P256Key, input: openArray[byte]): Result[seq[byte], string] =
  ## `ecdsa_secp256r1_sha256` over `input`: a DER ECDSA signature. The signer
  ## checks the input first (`signing.checkSignInput`).
  if k == nil or k.pkey == nil:
    return err("no key")
  let md = EVP_MD_CTX_new()
  if md == nil:
    return err("out of memory")
  var n = csize_t(EVP_PKEY_size(k.pkey))
  var sig = newSeq[byte](int(n))
  let done =
    EVP_DigestSignInit(md, nil, EVP_sha256(), nil, k.pkey) == 1 and
    EVP_DigestSign(
      md,
      addr sig[0],
      addr n,
      if input.len > 0:
        unsafeAddr input[0]
      else:
        nil,
      csize_t(input.len),
    ) == 1
  EVP_MD_CTX_free(md)
  if not done:
    wipe(sig)
    return err("cannot sign: " & sslErrors())
  sig.setLen(int(n))
  ok(sig)

{.pop.}
