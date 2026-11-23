## Packages with modules and configuration for the installation suites (Tier 5 step 5-5).
## `pmfixture`'s packages carry no module, and every suite 5-3c validates reaches it, so these
## live apart.
##
## A package has one module, `alpha_module`, with every declaration field and, by default, a
## configuration whose schema is the tuner fixture's (`tuner.config`) and whose default is one
## tuner value. Its variants are `linux-x86_64` and `darwin-aarch64`; `beta_module` has its
## artifact in the darwin variant only, so on linux it is not selected. The declared schema
## commitment is recomputed from the schema text unless a test sets it. `withFiles` adds data
## artifacts to one variant, for the store's extraction cases (5-5-2).

import std/[algorithm, sequtils, strutils]
import logos_sdk/pins as sdk_pins
import logos_sdk/testing/tunerconfig
import ./pmfixture

export pmfixture, tunerconfig, sdk_pins

type
  ConfigSpec* = object
    schema*: string ## the schema artifact's text
    root*: string
    schemaRoot*: Opt[seq[byte]] ## the declared root; none: recomputed from `schema`
    default*: Opt[seq[byte]] ## the default artifact's bytes; none: no default declared
    live*: bool

  ModulePackage* = object
    manifest*: CborValue
    files*: seq[(string, seq[(string, seq[byte])])]
      ## each variant's files, by variant id

proc tunerSpec*(default = Opt.some(tunerValue()), live = false): ConfigSpec =
  ConfigSpec(schema: tunerDocument, root: TunerRoot, default: default, live: live)

proc withRoot*(c: ConfigSpec, root: Opt[seq[byte]]): ConfigSpec =
  ## `c` declaring schema root `root` instead of the one its text gives.
  result = c
  result.schemaRoot = root

proc commitmentValue*(root: openArray[byte]): CborValue =
  ## A `logos.schema_commitment` with schema root `root`.
  cborMap(
    (cbor("commitment_model"), cbor(CommitmentModelId)),
    (cbor("schema_root"), cbor(root)),
    (cbor("hash_profile"), cbor(HashProfileId)),
    (cbor("hash_suite"), cbor(HashSuiteId)),
  )

proc commitmentValue*(fill: byte): CborValue =
  commitmentValue(newSeqWith(32, fill))

proc byBytes(vs: seq[CborValue]): seq[CborValue] =
  ## [SPEC PM §4] canonical order: deterministic-CBOR bytes
  result = vs
  result.sort(
    proc(a, b: CborValue): int =
      cmpBytes(encodeCbor(a), encodeCbor(b))
  )

proc artifactValue(id, kind, path: string, data: openArray[byte]): CborValue =
  cborMap(
    (cbor("id"), cbor(id)),
    (cbor("kind"), cbor(kind)),
    (cbor("path"), cbor(path)),
    (cbor("hash"), cbor(blake3(data))),
  )

proc alphaDeclaration(config: Opt[ConfigSpec], contracts: bool): CborValue =
  var e = @[(cbor("module"), cbor("alpha_module")), (cbor("artifact"), cbor("alpha"))]
  if contracts:
    e.add((cbor("primary_contract"), commitmentValue(1)))
    e.add(
      (
        cbor("implements"),
        cborArray(byBytes(@[commitmentValue(2), commitmentValue(3)])),
      )
    )
    e.add(
      (cbor("extends"), cborArray(byBytes(@[commitmentValue(6), commitmentValue(7)])))
    )
    e.add(
      (
        cbor("requires"),
        cborArray(
          cborMap(
            (cbor("contract"), commitmentValue(4)),
            (cbor("cardinality"), cbor("single")),
          )
        ),
      )
    )
    e.add(
      (
        cbor("requested_permissions"),
        cborArray(
          cborMap(
            (cbor("permission"), cbor("logos.storage.read")),
            (cbor("constraints"), cbor(encodeCbor(cborMap()))),
            (cbor("reason"), cbor("caches blocks")),
          )
        ),
      )
    )
  if config.isSome:
    let c = config.get
    let root =
      if c.schemaRoot.isSome:
        c.schemaRoot.get
      else:
        rootsOf(c.schema, c.root)[0]
    var ce = @[
      (cbor("schema_artifact"), cbor("alpha-config")),
      (cbor("root"), cbor(c.root)),
      (cbor("schema_commitment"), commitmentValue(root)),
    ]
    if c.default.isSome:
      ce.add((cbor("default_artifact"), cbor("alpha-defaults")))
    if c.live:
      ce.add((cbor("live_reconfiguration"), cbor(true)))
    e.add((cbor("configuration"), cborMap(ce)))
  cborMap(e)

proc modulePackage*(
    name = "logos.example",
    version = "1.0.0",
    config = Opt.some(tunerSpec()),
    contracts = true,
    deps: openArray[(string, string)] = [],
    allHosts = false,
): ModulePackage =
  ## The package described above; `deps` as `compatible` requirements. With `allHosts`, also
  ## `linux-aarch64` and `darwin-x86_64`, each with its OS's files, so that a hosted suite
  ## selects a variant on every host it runs on.
  var linuxFiles = @[("lib/libalpha.so", bytesOf("ALPHA " & name & "@" & version))]
  var darwinFiles = @[
    ("lib/libalpha.dylib", bytesOf("ALPHA darwin " & name & "@" & version)),
    ("lib/libbeta.dylib", bytesOf("BETA darwin " & name & "@" & version)),
  ]
  var linuxArts =
    @[artifactValue("alpha", "module-binary", "lib/libalpha.so", linuxFiles[0][1])]
  var darwinArts =
    @[artifactValue("alpha", "module-binary", "lib/libalpha.dylib", darwinFiles[0][1])]
  if config.isSome:
    let c = config.get
    let schema = bytesOf(c.schema)
    for (files, arts) in [
      (addr linuxFiles, addr linuxArts), (addr darwinFiles, addr darwinArts)
    ]:
      files[].add(("schema/alpha.cddl", schema))
      arts[].add(artifactValue("alpha-config", "schema", "schema/alpha.cddl", schema))
      if c.default.isSome:
        files[].add(("data/alpha.cbor", c.default.get))
        arts[].add(
          artifactValue("alpha-defaults", "data", "data/alpha.cbor", c.default.get)
        )
  darwinArts.add(
    artifactValue("beta", "module-binary", "lib/libbeta.dylib", darwinFiles[1][1])
  )
  let beta =
    cborMap((cbor("module"), cbor("beta_module")), (cbor("artifact"), cbor("beta")))
  var entries = @[
    (cbor("package"), cbor(name)),
    (cbor("version"), cbor(version)),
    (cbor("modules"), cborArray(alphaDeclaration(config, contracts), beta)),
    (
      cbor("variants"),
      cborArray(
        cborMap(
          (cbor("id"), cbor("linux-x86_64")),
          (
            cbor("platform"),
            cborMap((cbor("os"), cbor("linux")), (cbor("architecture"), cbor("x86_64"))),
          ),
          (cbor("artifacts"), cborArray(linuxArts)),
        ),
        cborMap(
          (cbor("id"), cbor("darwin-aarch64")),
          (
            cbor("platform"),
            cborMap(
              (cbor("os"), cbor("darwin")), (cbor("architecture"), cbor("aarch64"))
            ),
          ),
          (cbor("artifacts"), cborArray(darwinArts)),
        ),
      ),
    ),
  ]
  var ds: seq[CborValue]
  for (dep, at) in deps:
    ds.add(
      cborMap(
        (cbor("package"), cbor(dep)),
        (
          cbor("requirement"),
          cborMap((cbor("kind"), cbor("compatible")), (cbor("version"), cbor(at))),
        ),
      )
    )
  if ds.len > 0:
    entries.add((cbor("dependencies"), cborArray(ds)))
  var files = @[("linux-x86_64", linuxFiles), ("darwin-aarch64", darwinFiles)]
  if allHosts:
    for e in entries.mitems:
      if e[0].getText == Opt.some("variants"):
        for (id, os, arch, arts) in [
          ("linux-aarch64", "linux", "aarch64", linuxArts),
          ("darwin-x86_64", "darwin", "x86_64", darwinArts),
        ]:
          e[1].items.add(
            cborMap(
              (cbor("id"), cbor(id)),
              (
                cbor("platform"),
                cborMap((cbor("os"), cbor(os)), (cbor("architecture"), cbor(arch))),
              ),
              (cbor("artifacts"), cborArray(arts)),
            )
          )
    files.add(("linux-aarch64", linuxFiles))
    files.add(("darwin-x86_64", darwinFiles))
  ModulePackage(manifest: cborMap(entries), files: files)

proc withFiles*(
    p: ModulePackage, variant: string, files: openArray[(string, seq[byte])]
): ModulePackage =
  ## `p` with `files` added to `variant` as `data` artifacts `extra-<n>`, `n` zero-padded so
  ## that they follow the module's own in id order, as a manifest lists them.
  result = p
  for e in result.manifest.entries.mitems:
    if e.key.getText == Opt.some("variants"):
      for v in e.value.items.mitems:
        if v.lookup("id").get.getText == Opt.some(variant):
          for f in v.entries.mitems:
            if f.key.getText == Opt.some("artifacts"):
              for i, (path, data) in files:
                f.value.items.add(
                  artifactValue("extra-" & align($i, 5, '0'), "data", path, data)
                )
  for f in result.files.mitems:
    if f[0] == variant:
      for x in files:
        f[1].add(x)

proc decoded*(p: ModulePackage): Manifest =
  decodeManifest(encodeCbor(p.manifest)).get

proc fileOf*(p: ModulePackage, variant, path: string): seq[byte] =
  for (id, files) in p.files:
    if id == variant:
      for (q, data) in files:
        if q == path:
          return data
  doAssert false, "no file " & path & " in variant " & variant

proc packed*(p: ModulePackage, kid: string, key: SecretKey): seq[byte] =
  ## The signed archive. Signing takes about a second, so suites build archives once.
  let m = p.decoded
  let cose = signManifest(m, bytesOf(kid), key).get
  writeLgx(m.encoded, cose, p.files).get
