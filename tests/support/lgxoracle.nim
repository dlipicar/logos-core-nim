## Today's LGX reader, kept as the oracle that the streaming reader (step 5-5-2b, DECISIONS G446,
## plan §4.3a) is compared against in `test_lgx_equiv`. It is used by tests only, never by `src`.
##
## The code is `package/lgx.nim`'s reading half at `step5-5` `d492df6` (master's reader), copied
## unchanged except for:
## - the names: `oracleReadLgx` and `oracleOpenLgx`;
## - **one fix**: `readTar` checks an entry's padding against the tar's length. Before, a tar that
##   ended inside an entry's padding indexed past its end (an `IndexDefect` on untrusted input);
##   such a tar is now "an entry's data is truncated", as the streaming reader reports it;
## - `SelectedArtifact.size` and `LgxPackage.archiveBytes`, which the streaming reader's types
##   gained, are filled in.
## A later step that changes the reader on purpose updates this oracle in the same commit, with the
## difference stated, or retires `test_lgx_equiv`.

{.push raises: [].}

import std/[algorithm, os, sets, strutils, tables]
import results
import zlib/zlib_api
import logos_sdk/base/hex
import logos_sdk/cbor
import logos_sdk/crypto/blake3
import logos_sdk/iface/accept
from logos_sdk/iface/surface import schemaCommitment
import ../../src/logos_core/package/lgx

export lgx

const
  BlockSize = 512
  NameLen = 100
  PrefixLen = 155

func invalid(msg: string): PackageError =
  packageError(pecInvalidPackage, msg)

func integrity(msg: string): PackageError =
  packageError(pecArtifactIntegrity, msg)

# Gzip (RFC 1952) -------------------------------------------------------------------

func le32(b: openArray[byte], at: int): uint32 =
  uint32(b[at]) or (uint32(b[at + 1]) shl 8) or (uint32(b[at + 2]) shl 16) or
    (uint32(b[at + 3]) shl 24)

proc gunzip*(data: openArray[byte], limit: int64): Result[seq[byte], string] =
  ## [SPEC PM §7.1] [IMPL-DECISION G41] Exactly one gzip member with no file
  ## name, modification time zero and OS byte 255, inflating to at most `limit`
  ## bytes, with nothing after its trailer.
  if data.len < 18:
    return err("too short for gzip")
  if data[0] != 0x1f or data[1] != 0x8b or data[2] != 8:
    return err("not a deflate gzip member")
  let flags = data[3]
  if (flags and 0xe0) != 0:
    return err("reserved gzip flags are set")
  if (flags and 0x08) != 0:
    return err("the gzip header names the original file")
  if le32(data, 4) != 0:
    return err("the gzip modification time is not zero")
  if data[9] != GzipOsUnknown:
    return err("the gzip OS byte is not 255")
  var pos = 10
  if (flags and 0x04) != 0: # FEXTRA
    if pos + 2 > data.len:
      return err("a truncated gzip extra field")
    pos += 2 + (int(data[pos]) or (int(data[pos + 1]) shl 8))
  if (flags and 0x10) != 0: # FCOMMENT
    while pos < data.len and data[pos] != 0:
      inc pos
    inc pos
  if (flags and 0x02) != 0: # FHCRC
    if pos + 2 > data.len:
      return err("a truncated gzip header CRC")
    let want = int(data[pos]) or (int(data[pos + 1]) shl 8)
    if int(uint32(crc32(data.toOpenArray(0, pos - 1))) and 0xffff) != want:
      return err("the gzip header CRC does not match")
    pos += 2
  if pos >= data.len:
    return err("a truncated gzip header")
  var zs: ZStream
  if inflateInit2(zs, Z_RAW_DEFLATE) != Z_OK:
    return err("inflateInit2 failed")
  var output: seq[byte]
  var chunk = newSeq[byte](1 shl 16)
  zs.next_in = cast[ptr uint8](unsafeAddr data[pos])
  zs.avail_in = cuint(data.len - pos)
  var rc = Z_OK
  while rc != Z_STREAM_END:
    zs.next_out = addr chunk[0]
    zs.avail_out = cuint(chunk.len)
    rc = inflate(zs, Z_NO_FLUSH)
    if rc != Z_OK and rc != Z_STREAM_END:
      discard inflateEnd(zs)
      return err("the deflate stream is corrupt or truncated")
    let n = chunk.len - int(zs.avail_out)
    if int64(output.len + n) > limit:
      discard inflateEnd(zs)
      return err("the archive inflates past the decompressed-size limit")
    output.add(chunk.toOpenArray(0, n - 1))
    if rc == Z_OK and n == 0 and zs.avail_in == 0:
      discard inflateEnd(zs)
      return err("the deflate stream is truncated")
  let consumed = int(zs.total_in)
  discard inflateEnd(zs)
  let trailer = pos + consumed
  if trailer + 8 > data.len:
    return err("the gzip trailer is truncated")
  if le32(data, trailer) != uint32(crc32(output)):
    return err("the gzip CRC-32 does not match")
  if le32(data, trailer + 4) != uint32(output.len and 0xffff_ffff):
    return err("the gzip size does not match")
  if trailer + 8 != data.len:
    return err("data follows the gzip member (another member or trailing bytes)")
  ok(output)

func splitPath(path: string): Result[(string, string), string] =
  ## [IMPL-DECISION G40] The USTAR (prefix, name) for `path`; a path that fits
  ## neither way is refused (no pax).
  if path.len <= NameLen:
    return ok(("", path))
  for i in countdown(min(path.len - 1, PrefixLen), 1):
    if path[i] == '/' and path.len - i - 1 <= NameLen and path.len - i - 1 > 0:
      return ok((path[0 ..< i], path[i + 1 .. ^1]))
  err("the path does not fit a USTAR header: " & path)

func octalField(h: openArray[byte], at, width: int): Result[uint64, string] =
  ## Octal digits, optionally space-padded in front, ended by NUL or space; an
  ## all-NUL field is zero. Base-256 numbers are refused.
  var i = at
  let stop = at + width
  if (h[at] and 0x80) != 0:
    return err("a base-256 number")
  while i < stop and h[i] == byte(' '):
    inc i
  var v = 0'u64
  var digits = 0
  while i < stop and h[i] in {byte('0') .. byte('7')}:
    v = v * 8 + uint64(h[i] - byte('0'))
    inc digits
    inc i
  while i < stop and (h[i] == 0 or h[i] == byte(' ')):
    inc i
  if i != stop:
    return err("a malformed number field")
  ok(v)

func textField(h: openArray[byte], at, width: int): Result[string, string] =
  ## A NUL-terminated field; bytes after the NUL must be NUL too.
  var s = ""
  var i = at
  while i < at + width and h[i] != 0:
    s.add(char(h[i]))
    inc i
  while i < at + width:
    if h[i] != 0:
      return err("a NUL inside a name field")
    inc i
  ok(s)

func isZeroBlock(b: openArray[byte], at: int): bool =
  for i in at ..< at + BlockSize:
    if b[i] != 0:
      return false
  true

proc readTar(tar: openArray[byte], limits: LgxLimits): Result[seq[LgxEntry], string] =
  ## [SPEC PM §7.1] [IMPL-DECISION G40, G41] POSIX USTAR entries: regular files
  ## (mode 0644) and directories (mode 0755) only, zero ids and times, empty
  ## user and group names, no link names, zero padding, and two zero blocks at
  ## the end followed only by complete zero-filled blocks.
  var entries: seq[LgxEntry]
  var pos = 0
  while true:
    if pos + BlockSize > tar.len:
      return err("the archive ends without its end-of-archive blocks")
    if isZeroBlock(tar, pos):
      if pos + 2 * BlockSize > tar.len or not isZeroBlock(tar, pos + BlockSize):
        return err("a zero block that is not the end of the archive")
      # [SPEC PM §7.1] any further padding is complete zero-filled blocks
      if (tar.len - pos - 2 * BlockSize) mod BlockSize != 0:
        return err("archive padding that is not a whole number of 512-byte blocks")
      for i in pos + 2 * BlockSize ..< tar.len:
        if tar[i] != 0:
          return err("data after the end of the archive")
      return ok(entries)
    if entries.len >= limits.entries:
      return err("more entries than the archive-entry limit")
    var h: array[BlockSize, byte]
    for i in 0 ..< BlockSize:
      h[i] = tar[pos + i]
    var sum = 0'u64
    for i, b in h:
      sum += (if i in 148 .. 155: uint64(' ') else: uint64(b))
    if ?octalField(h, 148, 8) != sum:
      return err("a header checksum does not match")
    if ?textField(h, 257, 6) != "ustar" or h[263] != byte('0') or h[264] != byte('0'):
      return err("not a POSIX ustar header")
    let name = ?textField(h, 0, NameLen)
    let prefix = ?textField(h, 345, PrefixLen)
    var path =
      if prefix.len > 0:
        prefix & "/" & name
      else:
        name
    let kind =
      case char(h[156])
      of '0', '\0':
        lekFile
      of '5':
        lekDir
      of '1':
        return err("a hard link: " & path)
      of '2':
        return err("a symbolic link: " & path)
      of 'x', 'g':
        return err("a pax header (G40: none are written or read): " & path)
      else:
        return err("a special file (type " & $char(h[156]) & "): " & path)
    if ?textField(h, 157, 100) != "":
      return err("a link name on " & path)
    if ?octalField(h, 108, 8) != 0 or ?octalField(h, 116, 8) != 0:
      return err("non-zero user or group id on " & path)
    if ?octalField(h, 136, 12) != 0:
      return err("a non-zero modification time on " & path)
    if ?textField(h, 265, 32) != "" or ?textField(h, 297, 32) != "":
      return err("a user or group name on " & path)
    if ?octalField(h, 329, 8) != 0 or ?octalField(h, 337, 8) != 0:
      return err("device numbers on " & path)
    let mode = ?octalField(h, 100, 8)
    let size = ?octalField(h, 124, 12)
    if kind == lekDir:
      if mode != DirMode:
        return err("directory mode " & toOct(BiggestInt(mode), 4) & " on " & path)
      if size != 0:
        return err("a directory with data: " & path)
      if path.endsWith("/"):
        path.setLen(path.len - 1)
    else:
      if mode != FileMode:
        return err("file mode " & toOct(BiggestInt(mode), 4) & " on " & path)
      if path.endsWith("/"):
        return err("a regular file named like a directory: " & path)
      if size > uint64(limits.entry):
        return err("an entry larger than the entry-size limit: " & path)
    pos += BlockSize
    let n = int(size)
    if pos + n > tar.len:
      return err("an entry's data is truncated: " & path)
    var e = LgxEntry(path: path, kind: kind)
    if kind == lekFile:
      e.data = @(tar.toOpenArray(pos, pos + n - 1))
    let padded = (n + BlockSize - 1) div BlockSize * BlockSize
    if pos + padded > tar.len: # the oracle's one fix (see above)
      return err("an entry's data is truncated: " & path)
    for i in pos + n ..< pos + padded:
      if tar[i] != 0:
        return err("non-zero padding after " & path)
    pos += padded
    entries.add(e)

# Archive structure -----------------------------------------------------------------

func checkStructure(entries: seq[LgxEntry]): Result[void, string] =
  ## [SPEC PM §7.1] Paths are valid, unique and in byte order; the root holds
  ## only the manifest files and `variants/`; `variants/` holds directories
  ## only, each a valid variant id.
  for i, e in entries:
    ?checkArchivePath(e.path)
    if i > 0 and not (entries[i - 1].path < e.path):
      return err(
        if entries[i - 1].path == e.path:
          "a duplicate path: " & e.path
        else:
          "entries are not in path byte order at " & e.path
      )
    let segs = e.path.split('/')
    case segs[0]
    of ManifestCborPath, ManifestCosePath:
      if segs.len != 1 or e.kind != lekFile:
        return err(segs[0] & " is not a regular file at the root")
    of VariantsDir:
      if segs.len == 1 and e.kind != lekDir:
        return err("variants is not a directory")
      if segs.len == 2 and e.kind != lekDir:
        return err("a file directly under variants/: " & e.path)
      if segs.len >= 2 and not isVariantId(segs[1]):
        return err("an invalid variant directory name: " & segs[1])
    else:
      return err("an entry outside the permitted root names: " & e.path)
  ok()

proc oracleReadLgx*(
    data: openArray[byte], limits = DefaultLgxLimits
): Result[LgxArchive, PackageError] =
  ## [SPEC PM §7.1, §8] The gzip, USTAR, path and root-structure rules, within
  ## the limits; every failure is `invalid-package`.
  if int64(data.len) > limits.compressed:
    return err(invalid("the archive is larger than the compressed-size limit"))
  let tar = gunzip(data, limits.decompressed).valueOr:
    return err(invalid(error))
  let entries = readTar(tar, limits).valueOr:
    return err(invalid(error))
  checkStructure(entries).isOkOr:
    return err(invalid(error))
  ok(LgxArchive(entries: entries))

# Contract documents ----------------------------------------------------------------

func documentText(data: seq[byte]): string =
  result = newString(data.len)
  for i, b in data:
    result[i] = char(b)

proc buildContracts(
    m: Manifest, bytes: Table[string, seq[byte]]
): Result[seq[ContractSet], PackageError] =
  ## [SPEC PM §4 l.356-359] Each `contract_documents` entry's contract,
  ## constructed from the selected variant's documents: its `schema_artifact`
  ## the contract document, its `input_artifacts` the interfaces (by their
  ## `_interface` metadata) and supporting schemas it needs. A document that
  ## cannot be constructed, an entry whose document is a supporting schema and
  ## a root that differs from the commitment are `invalid-package` (l.358;
  ## I37). [IMPL-DECISION G392] Each document is validated as Logos-defined or
  ## ordinary by its own contract name (l.359), and each supporting schema and
  ## each interface with one supporting set is accepted once per open.
  let opts = AcceptOptions(byOwnName: true)
  var supporting = initTable[string, Contract]()
  var interfaces = initTable[(string, seq[string]), Contract]()
  var built: seq[ContractSet]
  for c in m.contractDocuments:
    let what = "contract document " & c.schemaArtifact
    var ifaceIds, suppIds: seq[string]
    for id in c.inputArtifacts:
      if declaredRole(documentText(bytes.getOrDefault(id))) == srInterface:
        ifaceIds.add(id)
      else:
        suppIds.add(id)
    var supp: seq[Contract]
    for id in suppIds:
      if id notin supporting:
        let doc = acceptDocument(
          documentText(bytes.getOrDefault(id)), pinnedContext(), opts
        ).valueOr:
          return err(invalid(what & ": input " & id & ": " & error))
        if doc.model.role != srSupporting:
          return err(
            invalid(
              what & ": input " & id & " is a " & $doc.model.role &
                " schema, neither an interface nor a supporting schema"
            )
          )
        supporting[id] = doc
      supp.add(supporting.getOrDefault(id))
    var ifaces: seq[Contract]
    let suppKey = suppIds.sorted
    for id in ifaceIds:
      if (id, suppKey) notin interfaces:
        let doc = acceptDocument(
          documentText(bytes.getOrDefault(id)), dependencyContext(supp), opts
        ).valueOr:
          return err(invalid(what & ": input " & id & ": " & error))
        interfaces[(id, suppKey)] = doc
      ifaces.add(interfaces.getOrDefault((id, suppKey)))
    let set = acceptContractSetUsing(
      documentText(bytes.getOrDefault(c.schemaArtifact)), ifaces, supp, opts
    ).valueOr:
      return err(invalid(what & ": " & error))
    if set.primary.model.role notin {srModule, srInterface}:
      # [SPEC PM §4 l.356] the entry names a contract document
      return err(invalid(what & " is a supporting schema, not a contract"))
    if encodeCbor(schemaCommitment(set.primary.root)) != encodeCbor(c.commitment):
      return err(invalid(what & " does not construct the entry's commitment"))
    built.add(set)
  ok(built)

proc checkExtensions(m: Manifest, built: seq[ContractSet]): Result[void, PackageError] =
  ## [SPEC PM §4 l.360, §9 l.1141, l.1143] Each `extends` commitment with an
  ## entry, for every module declaration of the manifest, against the
  ## declaration's own contracts (`primary_contract` and `implements`) that
  ## have entries. [IMPL-DECISION G392] It holds when one of them extends it.
  ## It fails when every declared contract has an entry and none extends it,
  ## or when the declared contract of its namespace has an entry and does not
  ## extend it (another role included). Otherwise the Package Manager cannot
  ## construct the pair, and the Runtime validates the provider.
  var byCommitment = initTable[seq[byte], Contract]()
  for i, c in m.contractDocuments:
    byCommitment[encodeCbor(c.commitment)] = built[i].primary
  for d in m.modules:
    var declared = d.implements
    if d.primaryContract.isSome:
      declared.insert(d.primaryContract.get, 0)
    var have: seq[Contract]
    for c in declared:
      let k = encodeCbor(c)
      if k in byCommitment:
        have.add(byCommitment.getOrDefault(k))
    for e in d.extends:
      let k = encodeCbor(e)
      if k notin byCommitment:
        continue
      let a = byCommitment.getOrDefault(k)
      var holds = false
      for b in have:
        if extendsContract(b.model, a.model).isOk:
          holds = true
      if holds:
        continue
      if have.len == declared.len:
        return err(
          invalid(
            "module " & d.module & ": none of its contracts extends the extends entry " &
              a.model.namespace
          )
        )
      for b in have:
        if b.model.namespace == a.model.namespace:
          let why = extendsContract(b.model, a.model).error
          return err(
            invalid(
              "module " & d.module & ": its contract " & b.model.namespace & " " & why
            )
          )
  ok()

# Opening a package -----------------------------------------------------------------

proc oracleOpenLgx*(
    data: openArray[byte],
    trust: TrustInput,
    platform = hostPlatform(),
    limits = DefaultLgxLimits,
    pathRules = hostPathRules(),
): Result[LgxPackage, PackageError] =
  ## [SPEC PM §2, §3, §4, §7.1, §8] In order: the archive rules
  ## (`invalid-package`); `manifest.cbor` present (`invalid-package`) and
  ## `manifest.cose` present (`signature-verification-failed`); the signature,
  ## the claim and its manifest schema, then the manifest (`verifyPackage`);
  ## every variant's manifest paths under the LGX path rules
  ## (`invalid-package`, M24); one directory per manifest variant
  ## (`invalid-package`); the first compatible variant
  ## (`incompatible-platform`); in every variant, each declared file present
  ## (`artifact-integrity-failed`, M25) and each file declared exactly once
  ## (`invalid-package`); the selected variant's paths under the installation's
  ## rules (`invalid-package`); its artifacts within the extracted-size limit
  ## and matching their hashes (`artifact-integrity-failed`); each contract
  ## document constructing its commitment, and each `extends` entry extended
  ## by the declaration's contracts where both have entries (`invalid-package`,
  ## PM §4 l.358-360). The target platform comes from protected deployment
  ## policy (PM §7.1).
  let a = ?oracleReadLgx(data, limits)
  let manifestCbor = a.file(ManifestCborPath).valueOr:
    return err(invalid("the package has no manifest.cbor"))
  let manifestCose = a.file(ManifestCosePath).valueOr:
    return err(packageError(pecSignature, "the package has no manifest.cose"))
  let verified = ?verifyPackage(manifestCbor, manifestCose, trust)
  let m = verified.manifest

  # Variant directories and their files.
  var dirs = initHashSet[string]()
  var files = initTable[string, Table[string, seq[byte]]]()
  var subdirs = initTable[string, HashSet[string]]()
  for e in a.entries:
    let segs = e.path.split('/')
    if segs[0] != VariantsDir or segs.len < 2:
      continue
    dirs.incl(segs[1])
    if segs.len == 2:
      continue
    let rel = segs[2 .. ^1].join("/")
    if e.kind == lekFile:
      files.mgetOrPut(segs[1], initTable[string, seq[byte]]())[rel] = e.data
    else:
      subdirs.mgetOrPut(segs[1], initHashSet[string]()).incl(rel)
    for i in 3 ..< segs.len:
      subdirs.mgetOrPut(segs[1], initHashSet[string]()).incl(segs[2 ..< i].join("/"))
  var ids = initHashSet[string]()
  for v in m.variants:
    if not isVariantId(v.id):
      return err(invalid("variant id " & v.id & " is not a valid LGX variant id"))
    ids.incl(v.id)
  # [SPEC PM §7.1 l.913-921, §8 l.1082; M24] Every manifest path of every
  # variant, under its variant directory, keeps the LGX path rules and fits a
  # USTAR header; one that does not is `invalid-package` [IMPL; P7 Q5: every
  # variant, as PM l.965 judges every variant's files].
  for v in m.variants:
    for art in v.artifacts:
      let full = VariantsDir & "/" & v.id & "/" & art.path
      checkArchivePath(full).isOkOr:
        return err(invalid("variant " & v.id & ": artifact " & art.id & ": " & error))
      discard splitPath(full).valueOr:
        return err(invalid("variant " & v.id & ": artifact " & art.id & ": " & error))
  if dirs != ids:
    return
      err(invalid("variants/ does not hold exactly one directory per manifest variant"))

  let selected = ?selectVariant(m, platform)
  for v in m.variants:
    let have = files.getOrDefault(v.id)
    var declared = initHashSet[string]()
    for art in v.artifacts:
      if declared.containsOrIncl(art.path):
        return err(invalid("variant " & v.id & ": two artifacts declare " & art.path))
      if art.path notin have:
        # [SPEC PM §7.1 l.965, §8 l.1098; M25] in any variant
        return err(
          integrity(
            "variant " & v.id & ": artifact " & art.id & " is not a regular file"
          )
        )
    for path in have.keys:
      if path notin declared:
        return err(invalid("variant " & v.id & ": " & path & " is not declared"))

  let v = m.variants[selected]
  var paths: seq[string]
  for p in files.getOrDefault(v.id).keys:
    paths.add(p)
  for p in subdirs.getOrDefault(v.id):
    paths.add(p)
  paths.sort()
  checkInstallPaths(paths, pathRules).isOkOr:
    return err(invalid("variant " & v.id & ": " & error))

  var pkg = LgxPackage(
    verified: verified,
    signature: manifestCose,
    variant: v,
    archiveBytes: int64(data.len),
  )
  var total = 0'i64
  let content = files.getOrDefault(v.id)
  for art in v.artifacts:
    let bytes = content.getOrDefault(art.path)
    total += int64(bytes.len)
    if total > limits.extracted:
      return err(integrity("the selected variant exceeds the extracted-size limit"))
    if blake3(bytes) != art.hash:
      return err(
        integrity("artifact " & art.id & " does not match its hash " & art.hash.toHex)
      )
    pkg.artifacts.add(
      SelectedArtifact(artifact: art, size: int64(bytes.len), data: bytes)
    )
  var byId = initTable[string, seq[byte]]()
  for s in pkg.artifacts:
    byId[s.artifact.id] = s.data
  pkg.contracts = ?buildContracts(m, byId)
  ?checkExtensions(m, pkg.contracts)
  var present = initHashSet[string]()
  for art in v.artifacts:
    present.incl(art.id)
  for d in m.modules:
    if d.artifact in present:
      pkg.modules.add(d)
  ok(pkg)

# Comparing the readers (test_lgx_equiv, and test_lgx's last suite) ----------------------------

type
  Agreement* = enum
    ## How the streaming reader's result relates to the oracle's (G29's note, plan §4.3a).
    agSame ## the same result; on an error, the same code and message
    agFormat
      ## both fail a format check, `invalid-package`: the message can name another format check,
      ## or word the same one otherwise (cases 2 and 3: the checks now run in stream order)
    agBound
      ## `artifact-integrity-failed` both: the extracted bound named where the oracle names a hash
      ## (case 6)
    agDocument ## `invalid-package` both: N names another document (case 9)
    agSignatureSize
      ## `signature-verification-failed` both: the size of `manifest.cose` named first (case 10)

  MemorySink* = object ## `extractLgx`'s sink for the tests: each file's bytes, by path.
    files*: Table[string, seq[byte]]
    order*: seq[string]
    cur: string
    failAfter*: int ## refuse the write after this many bytes in all; -1: never
    written: int

func initMemorySink*(failAfter = -1): MemorySink =
  MemorySink(failAfter: failAfter)

proc sinkBegin*(k: var MemorySink, path: string): bool =
  k.cur = path
  k.files[path] = @[]
  k.order.add(path)
  true

proc sinkWrite*(k: var MemorySink, data: openArray[byte]): bool =
  if k.failAfter >= 0 and k.written + data.len > k.failAfter:
    return false
  k.written += data.len
  k.files.mgetOrPut(k.cur, @[]).add(data)
  true

proc sinkEnd*(k: var MemorySink): bool =
  true

proc sinkAbort*(k: var MemorySink) =
  k.files.del(k.cur)

func describe(r: Result[LgxPackage, PackageError]): string =
  if r.isOk:
    "ok"
  else:
    $r.error.code & ": " & r.error.msg

func samePackage*(a, b: LgxPackage, data: bool): Result[void, string] =
  ## The same verified manifest, signer, signature, variant, modules, contracts, artifact ids,
  ## paths, sizes and digests; with `data`, the same bytes.
  if a.verified.manifest.encoded != b.verified.manifest.encoded:
    return err("the verified manifests differ")
  if encodeCbor(a.verified.signerRecord) != encodeCbor(b.verified.signerRecord):
    return err("the signers differ")
  if a.signature != b.signature:
    return err("the signatures differ")
  if a.variant.id != b.variant.id:
    return err("the variants differ: " & a.variant.id & " and " & b.variant.id)
  if a.modules.len != b.modules.len:
    return err("the module counts differ")
  for i in 0 ..< a.modules.len:
    if a.modules[i].module != b.modules[i].module:
      return err("module " & $i & " differs")
  if a.contracts.len != b.contracts.len:
    return err("the contract counts differ")
  for i in 0 ..< a.contracts.len:
    if a.contracts[i].primary.root != b.contracts[i].primary.root:
      return err("contract " & $i & " differs")
  if a.artifacts.len != b.artifacts.len:
    return err("the artifact counts differ")
  for i in 0 ..< a.artifacts.len:
    let (x, y) = (a.artifacts[i], b.artifacts[i])
    if x.artifact.id != y.artifact.id or x.artifact.path != y.artifact.path or
        x.artifact.hash != y.artifact.hash or x.size != y.size:
      return err("artifact " & x.artifact.id & " differs")
    if data and x.data != y.data:
      return err("artifact " & x.artifact.id & "'s bytes differ")
  if a.archiveBytes != b.archiveBytes:
    return err("the archive sizes differ")
  ok()

proc agreement*(
    archive: openArray[byte],
    old, new: Result[LgxPackage, PackageError],
    limits = DefaultLgxLimits,
): Result[Agreement, string] =
  ## Whether `new` (the streaming reader's) is `old` (the oracle's) up to the four kinds of
  ## message G29's note allows; an error names the difference.
  let oldFormat = oracleReadLgx(archive, limits).isErr
  let newFormat = readLgx(archive, limits).isErr
  if oldFormat != newFormat:
    return err(
      "the format checks disagree: the oracle " & (if oldFormat: "fails" else: "passes") &
        " and the streaming reader " & (if newFormat: "fails" else: "passes")
    )
  if old.isOk != new.isOk:
    return err("oracle " & old.describe & ", streaming " & new.describe)
  if old.isOk:
    ?samePackage(old.get, new.get, data = true)
    return ok(agSame)
  let (o, n) = (old.error, new.error)
  if o.code != n.code:
    return err("oracle " & old.describe & ", streaming " & new.describe)
  if o.msg == n.msg:
    return ok(agSame)
  if oldFormat:
    if n.code == pecInvalidPackage:
      return ok(agFormat)
  elif n.code == pecArtifactIntegrity and
      n.msg == "the selected variant exceeds the extracted-size limit" and
      "does not match its hash" in o.msg:
    return ok(agBound)
  elif n.code == pecInvalidPackage and o.msg.startsWith("contract document ") and
      n.msg.startsWith("contract document "):
    return ok(agDocument)
  elif n.code == pecSignature and n.msg == "manifest.cose is larger than 1 MiB":
    return ok(agSignatureSize)
  err("the messages differ: oracle " & old.describe & ", streaming " & new.describe)

proc checkReaders*(
    archive: seq[byte],
    trust: TrustInput,
    host: Platform,
    limits: LgxLimits,
    rules: PathRules,
    scratch: string,
): Result[Agreement, string] =
  ## Every reading of `archive` (plan §4.3a's comparison): `openLgx` against the oracle; then
  ## `inspectLgx` over a file and over bytes against `openLgx`, with the same result and message
  ## and no artifact bytes kept; then, when it opens, the extraction pass from the file, whose
  ## files must be the oracle's bytes.
  let old = oracleOpenLgx(archive, trust, host, limits, rules)
  let mem = openLgx(archive, trust, host, limits, rules)
  let kind = ?agreement(archive, old, mem, limits)
  let path = scratch / "archive.lgx"
  block:
    # Not `writeFile`: it indexes the first byte, so an empty archive raises IndexDefect.
    var f: File
    if not open(f, path, fmWrite):
      return err("cannot write " & path)
    try:
      let n =
        if archive.len > 0:
          f.writeBytes(archive, 0, archive.len)
        else:
          0
      if n != archive.len:
        return err("cannot write " & path)
    except IOError as e:
      return err("cannot write " & path & ": " & e.msg)
    finally:
      f.close()
  let fromFile = inspectLgx(fileSource(path), trust, host, limits, rules)
  let fromBytes = inspectLgx(bytesSource(archive), trust, host, limits, rules)
  for (name, r) in [("the file source", fromFile), ("the bytes source", fromBytes)]:
    if r.isOk != mem.isOk:
      return err(name & ": " & r.describe & ", openLgx: " & mem.describe)
    if r.isErr:
      if r.error.code != mem.error.code or r.error.msg != mem.error.msg:
        return err(name & ": " & r.describe & ", openLgx: " & mem.describe)
    else:
      samePackage(mem.get, r.get, data = false).isOkOr:
        return err(name & ": " & error)
      for a in r.get.artifacts:
        if a.data.len != 0:
          return err(name & " kept artifact " & a.artifact.id & "'s bytes")
  if fromFile.isOk:
    var sink = initMemorySink()
    extractLgx(fileSource(path), fromFile.get, sink).isOkOr:
      return err("the extraction pass: " & $error.fault & ": " & error.detail)
    var paths = initHashSet[string]()
    for a in old.get.artifacts:
      paths.incl(a.artifact.path)
      if sink.files.getOrDefault(a.artifact.path) != a.data:
        return err("the extraction pass wrote other bytes for " & a.artifact.path)
    if sink.order.len != paths.len:
      return err("the extraction pass wrote " & $sink.order.len & " files")
  ok(kind)
