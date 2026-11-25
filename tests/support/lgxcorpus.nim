## The LGX test corpus's builders (step 5-5-2b): `test_lgx`'s, moved here unchanged so that
## `test_lgx_equiv` compares the streaming reader with the oracle on every archive `test_lgx`
## builds. A package of two variants signed with a fixed test key, opened under a trust that
## accepts it for `logos.example`; a USTAR builder whose header fields can be set to anything;
## and contract-document packages.

import std/[algorithm, os, sequtils, strutils, tables]
import unittest2
import logos_sdk/base/hex
import logos_sdk/[cbor, pins]
import logos_sdk/crypto/blake3
import logos_sdk/iface/accept
from logos_sdk/iface/surface import schemaCommitment
import ../../src/logos_core/package/lgx

export lgx, cbor, blake3, accept, tables, schemaCommitment

# A package -------------------------------------------------------------------------

proc b*(s: string): seq[byte] =
  @(s.toOpenArrayByte(0, s.high))

type Files* = seq[(string, seq[byte])]

let linuxFiles*: Files = @[
  ("data/alpha.cbor", encodeCbor(cborMap())),
  ("lib/libalpha.so", b("ALPHA for linux")),
  ("lib/libbeta.so", b("BETA for linux")),
  ("schema/alpha.cddl", b("alpha_config = { level: uint }\n")),
]
let darwinFiles*: Files = @[
  ("data/alpha.cbor", encodeCbor(cborMap())),
  ("lib/libalpha.dylib", b("ALPHA for darwin")),
  ("schema/alpha.cddl", b("alpha_config = { level: uint }\n")),
]

proc content*(files: Files, path: string): seq[byte] =
  for (p, d) in files:
    if p == path:
      return d
  @[]

proc artifact*(id, kind, path: string, files: Files): CborValue =
  cborMap(
    (cbor("id"), cbor(id)),
    (cbor("kind"), cbor(kind)),
    (cbor("path"), cbor(path)),
    (cbor("hash"), cbor(blake3(files.content(path)))),
  )

proc manifestValue*(): CborValue =
  let commitment = cborMap(
    (cbor("commitment_model"), cbor(CommitmentModelId)),
    (cbor("schema_root"), cbor(newSeq[byte](32))),
    (cbor("hash_profile"), cbor(HashProfileId)),
    (cbor("hash_suite"), cbor(HashSuiteId)),
  )
  cborMap(
    (cbor("package"), cbor("logos.example")),
    (cbor("version"), cbor("1.0.0")),
    (
      cbor("modules"),
      cborArray(
        cborMap(
          (cbor("module"), cbor("alpha_module")),
          (cbor("artifact"), cbor("alpha")),
          (
            cbor("configuration"),
            cborMap(
              (cbor("schema_artifact"), cbor("alpha-config")),
              (cbor("root"), cbor("alpha_config")),
              (cbor("schema_commitment"), commitment),
              (cbor("default_artifact"), cbor("alpha-defaults")),
            ),
          ),
        ),
        cborMap((cbor("module"), cbor("beta_module")), (cbor("artifact"), cbor("beta"))),
      ),
    ),
    (
      cbor("variants"),
      cborArray(
        cborMap(
          (cbor("id"), cbor("linux-x86_64")),
          (
            cbor("platform"),
            cborMap(
              (cbor("os"), cbor("linux")),
              (cbor("architecture"), cbor("x86_64")),
              (cbor("abi"), cbor("gnu")),
            ),
          ),
          (
            cbor("artifacts"),
            cborArray(
              artifact("alpha", "module-binary", "lib/libalpha.so", linuxFiles),
              artifact("alpha-config", "schema", "schema/alpha.cddl", linuxFiles),
              artifact("alpha-defaults", "data", "data/alpha.cbor", linuxFiles),
              artifact("beta", "module-binary", "lib/libbeta.so", linuxFiles),
            ),
          ),
        ),
        cborMap(
          (cbor("id"), cbor("darwin-aarch64")),
          (
            cbor("platform"),
            cborMap(
              (cbor("os"), cbor("darwin")), (cbor("architecture"), cbor("aarch64"))
            ),
          ),
          (
            cbor("artifacts"),
            cborArray(
              artifact("alpha", "module-binary", "lib/libalpha.dylib", darwinFiles),
              artifact("alpha-config", "schema", "schema/alpha.cddl", darwinFiles),
              artifact("alpha-defaults", "data", "data/alpha.cbor", darwinFiles),
            ),
          ),
        ),
      ),
    ),
  )

proc testKey*(fill: byte): (SecretKey, PublicKey) =
  ## A fixed SLH-DSA-SHA2-192s key pair (FIPS 205 `slh_keygen_internal`).
  var a, b, c: Seed
  for i in 0 ..< N:
    a[i] = byte(i * 3) xor fill
    b[i] = byte(i * 5) xor fill
    c[i] = byte(i * 7) xor fill
  keyPairFromSeeds(a, b, c)

let keyPair = testKey(0)
let key* = keyPair[0]
let pub* = keyPair[1]
let kid* = b("lgx-test")
var trust*: TrustInput
doAssert trust.addAnchor(kid, pub, ["logos.example"]).isOk

let linuxHost* = Platform(os: "linux", architecture: "x86_64", abi: Opt.some("gnu"))
let darwinHost* = Platform(os: "darwin", architecture: "aarch64")
let windowsHost* =
  Platform(os: "windows", architecture: "x86_64", abi: Opt.some("msvc"))

type Built* = object
  ## An archive these builders made, or `opened` opened, with how it was opened.
  archive*: seq[byte]
  host*: Platform
  limits*: LgxLimits
  rules*: PathRules

var built*: seq[Built]
  ## Every archive built or opened through this module, for `test_lgx`'s last suite (step
  ## 5-5-2b), which compares the streaming reader with the oracle on each.

proc note*(
    a: seq[byte], host = linuxHost, limits = DefaultLgxLimits, rules = PathRules()
) =
  built.add(Built(archive: a, host: host, limits: limits, rules: rules))

var signatures*: Table[seq[byte], seq[byte]]
  ## One signature per distinct manifest: SLH-DSA-SHA2-192s signing takes most
  ## of a second, and most tests pack the same manifest.

proc fixedHedge*(dest: var openArray[byte]): bool =
  ## The corpus's hedge (DECISIONS G446's tests, CI run 1): the same bytes on every run, so
  ## a manifest's signature, and every archive built around it, is the same on every run and
  ## in every build. Only test support passes it; `signManifest` and `sign` keep the
  ## operating system's fresh bytes by default.
  for i in 0 ..< dest.len:
    dest[i] = byte(i)
  true

proc signed*(v: CborValue): (seq[byte], seq[byte]) =
  let m = decodeManifest(encodeCbor(v)).get
  if m.encoded notin signatures:
    signatures[m.encoded] = signManifest(m, kid, key, fixedHedge).get
  (m.encoded, signatures[m.encoded])

proc pack*(v = manifestValue(), linux = linuxFiles, darwin = darwinFiles): seq[byte] =
  let (cbor, cose) = signed(v)
  result =
    writeLgx(cbor, cose, @[("linux-x86_64", linux), ("darwin-aarch64", darwin)]).get
  note(result)

proc opened*(
    data: seq[byte],
    host = linuxHost,
    limits = DefaultLgxLimits,
    rules = PathRules(), # exact comparison, whatever filesystem the tests run on
): string =
  note(data, host, limits, rules)
  let r = openLgx(data, trust, host, limits, rules)
  if r.isOk:
    "ok"
  else:
    checkpoint r.error.msg
    if existsEnv("LCN_TEST_TRACE"):
      echo "    ", r.error.msg
    $r.error.code

# A USTAR builder with every field settable ------------------------------------------

type Raw* = object
  name*, prefix*: string
  typeflag*: char
  mode*, uid*, gid*, mtime*: int
  uname*, linkname*, magic*, version*: string
  data*: seq[byte]

proc raw*(path: string, dir = false, data: seq[byte] = @[]): Raw =
  Raw(
    name:
      if dir:
        path & "/"
      else:
        path,
    typeflag: if dir: '5' else: '0',
    mode: if dir: 0o755 else: 0o644,
    magic: "ustar\0",
    version: "00",
    data: data,
  )

proc header*(r: Raw): seq[byte] =
  var h = newSeq[byte](512)
  proc put(at: int, s: string) =
    for i, c in s:
      h[at + i] = byte(c)

  proc octal(at, width, v: int) =
    put(at, toOct(v, width - 1))

  put(0, r.name)
  octal(100, 8, r.mode)
  octal(108, 8, r.uid)
  octal(116, 8, r.gid)
  octal(124, 12, r.data.len)
  octal(136, 12, r.mtime)
  h[156] = byte(r.typeflag)
  put(157, r.linkname)
  put(257, r.magic)
  put(263, r.version)
  put(265, r.uname)
  put(345, r.prefix)
  put(148, "        ")
  var sum = 0
  for x in h:
    sum += int(x)
  put(148, toOct(sum, 6))
  h[154] = 0
  h

proc tar*(entries: seq[Raw], tail = 1024): seq[byte] =
  for e in entries:
    result.add(header(e))
    result.add(e.data)
    result.setLen(result.len + (512 - e.data.len mod 512) mod 512)
  result.setLen(result.len + tail)

proc gz*(t: seq[byte]): seq[byte] =
  result = gzipCompress(t).get
  note(result)

proc entriesOf*(archive: seq[byte]): seq[Raw] =
  ## The conforming entries of a package, as editable raw headers.
  for e in readLgx(archive).get.entries:
    result.add(raw(e.path, e.kind == lekDir, e.data))

proc variedArchive*(f: proc(es: var seq[Raw]), sort = false): seq[byte] =
  ## The package's entries changed by `f`; with `sort`, put back in path order
  ## so that only the rule under test can fail.
  var es = entriesOf(pack())
  f(es)
  if sort:
    es.sort(
      proc(a, b: Raw): int =
        cmp(
          a.prefix & a.name.strip(leading = false, chars = {'/'}),
          b.prefix & b.name.strip(leading = false, chars = {'/'}),
        )
    )
  gz(tar(es))

proc indexOf*(es: seq[Raw], name: string): int =
  for i, e in es:
    if e.name == name:
      return i
  raiseAssert "no entry " & name

# Contract documents ----------------------------------------------------------------

const
  unitsDoc* = "units.label = tstr\n"
  dialOld* =
    "_interface = \"dial\"\n\ndial.turn_request = {\n  by: units.label,\n}\n" &
    "dial.turn_response = {}\n"
  dialNew* = dialOld & "dial.reset_request = {}\ndial.reset_response = {}\n"
  gaugeDoc* =
    "_interface = \"gauge\"\n\ngauge.read_request = {}\ngauge.read_response = {}\n"

proc rootOf*(
    doc: string,
    ifaces: openArray[string] = [],
    supp: openArray[string] = [],
    opts = AcceptOptions(byOwnName: true),
): Digest =
  let r = acceptContractSet(doc, ifaces, supp, opts)
  if r.isErr:
    checkpoint r.error
  r.get.primary.root

proc implementing*(root: Digest): string =
  "_implements = [h'" & toHex(root) & "']\n"

let
  dialNewRoot* = rootOf(dialNew, [], [unitsDoc])
  alphaOld* =
    "_module = \"alpha_module\"\n" & implementing(dialNewRoot) &
    "\nalpha.ping_request = {}\nalpha.ping_response = {\n  n: units.label,\n}\n"
  alphaNew* = alphaOld & "alpha.pong_request = {}\nalpha.pong_response = {}\n"
  alphaChanged* =
    "_module = \"alpha_module\"\n" & implementing(dialNewRoot) &
    "\nalpha.ping_request = {}\nalpha.ping_response = {}\n"
  alphaIface* =
    "_interface = \"alpha\"\n\nalpha.ping_request = {}\nalpha.ping_response = {\n" &
    "  n: units.label,\n}\n"
  alphaNewC* = schemaCommitment(rootOf(alphaNew, [dialNew], [unitsDoc]))
  alphaOldC* = schemaCommitment(rootOf(alphaOld, [dialNew], [unitsDoc]))
  alphaChangedC* = schemaCommitment(rootOf(alphaChanged, [dialNew], [unitsDoc]))
  alphaIfaceC* = schemaCommitment(rootOf(alphaIface, [], [unitsDoc]))
  dialNewC* = schemaCommitment(dialNewRoot)
  dialOldC* = schemaCommitment(rootOf(dialOld, [], [unitsDoc]))
  gaugeC* = schemaCommitment(rootOf(gaugeDoc))
  unitsC* = schemaCommitment(rootOf(unitsDoc))
  docs* = @[
    ("c-alpha-changed", alphaChanged),
    ("c-alpha-iface", alphaIface),
    ("c-alpha-new", alphaNew),
    ("c-alpha-old", alphaOld),
    ("c-dial-new", dialNew),
    ("c-dial-old", dialOld),
    ("c-extra", "extra.n = uint64\n"),
    ("c-gauge", gaugeDoc),
    ("c-units", unitsDoc),
  ]

type Entry* = tuple[commitment: CborValue, schema: string, inputs: seq[string]]

let
  alphaNewE*: Entry = (alphaNewC, "c-alpha-new", @["c-dial-new", "c-units"])
  alphaOldE*: Entry = (alphaOldC, "c-alpha-old", @["c-dial-new", "c-units"])
  alphaChangedE*: Entry = (alphaChangedC, "c-alpha-changed", @["c-dial-new", "c-units"])
  alphaIfaceE*: Entry = (alphaIfaceC, "c-alpha-iface", @["c-units"])
  dialNewE*: Entry = (dialNewC, "c-dial-new", @["c-units"])
  dialOldE*: Entry = (dialOldC, "c-dial-old", @["c-units"])
  gaugeE*: Entry = (gaugeC, "c-gauge", newSeq[string]())
  everyEntry* = @[alphaNewE, alphaOldE, dialNewE, dialOldE]

proc byBytes*(xs: openArray[CborValue]): seq[CborValue] =
  result = @xs
  result.sort(
    proc(a, b: CborValue): int =
      cmpBytes(encodeCbor(a), encodeCbor(b))
  )

proc contractPackage*(
    entries: openArray[Entry],
    primary = Opt.some(alphaNewC),
    implements = @[dialNewC],
    extends = @[alphaOldC, dialOldC],
    documents = docs,
    module = 0,
): seq[byte] =
  ## The base package with these schema documents in both variants (as
  ## `schema/<id>.cddl`), these `contract_documents` entries, and these
  ## contracts on the module declaration `module`.
  var linux = linuxFiles
  var darwin = darwinFiles
  for (id, text) in documents:
    linux.add(("schema/" & id & ".cddl", b(text)))
    darwin.add(("schema/" & id & ".cddl", b(text)))
  let v = manifestValue()
  for (vi, files) in [(0, linux), (1, darwin)]:
    let arts = v.lookup("variants").get.items[vi].lookup("artifacts").get
    for (id, _) in documents:
      arts.items.add(artifact(id, "schema", "schema/" & id & ".cddl", files))
  var listed: seq[Entry] = @entries
  listed.sort(
    proc(a, b: Entry): int =
      cmpBytes(encodeCbor(a.commitment), encodeCbor(b.commitment))
  )
  var values: seq[CborValue]
  for e in listed:
    var fields =
      @[(cbor("commitment"), e.commitment), (cbor("schema_artifact"), cbor(e.schema))]
    if e.inputs.len > 0:
      fields.add((cbor("input_artifacts"), cborArray(e.inputs.mapIt(cbor(it)))))
    values.add(cborMap(fields))
  if values.len > 0:
    v.entries.add((cbor("contract_documents"), cborArray(values)))
  let d = v.lookup("modules").get.items[module]
  if primary.isSome:
    d.entries.add((cbor("primary_contract"), primary.get))
  if implements.len > 0:
    d.entries.add((cbor("implements"), cborArray(byBytes(implements))))
  if extends.len > 0:
    d.entries.add((cbor("extends"), cborArray(byBytes(extends))))
  pack(v, linux, darwin)
