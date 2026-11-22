## PM §2, §3, §7.1, §8: the LGX realization profile. An LGX package is a gzip
## (RFC 1952) USTAR archive holding `manifest.cbor`, `manifest.cose` and one
## directory per manifest variant under `variants/`; nothing else may sit at
## the root. This module writes such archives, reads them with every §7.1
## structure, path and encoding rule checked, verifies the signature, selects
## the first compatible variant and checks its artifacts.
##
## **Reading is one streaming pass** (step 5-5-2b; DECISIONS G446, G29's note; plan §4.3a). The
## archive is read from its source (a file, such as a spool file, or bytes in memory) in 1 MiB
## pieces and inflated into 1 MiB pieces. A tar cursor checks each header and its path as the
## entry arrives and hands its data to a consumer. Only buffers, the bounded manifest files, the
## path table, the selected variant's digests and its kept documents stay in memory, so the peak
## is a constant, whatever the archive's size (`inspectLgx`). `openLgx` is the same pass over bytes
## that also keeps every selected artifact's bytes, and `readLgx` keeps every entry.
## - **The format checks** A to F (the compressed size; the gzip header; the inflate and the
##   decompressed size; the tar's headers, entry count and entry sizes, with each path's rules and
##   order; the tar's end; the trailer and the member's end) run in that stream order, and the
##   first failure is the result. Every one is `invalid-package`.
## - **The content checks** G to N (the manifest files; the signature; the variants; the platform;
##   each variant's files; the installation's path rules; the extracted size and the hashes; the
##   documents' total and the contracts) run after the whole stream has passed, in the order the
##   in-memory reader used, from what the pass recorded. `verifyPackage` runs as soon as
##   `manifest.cose` has arrived, so that the selected variant's files can be hashed as they pass,
##   and its result is held until then.
## - **The extraction pass** (`extractLgx`) reads the same source again and writes the selected
##   variant's files through a sink, each checked against its signed hash.
## It extracts nothing on its own: installation (§7.1 extraction, PKG-0204/0219) belongs to the
## Package Manager.

{.push raises: [].}

import std/[algorithm, atomics, sets, strutils, tables, unicode]
import results
import zlib/zlib_api
import logos_sdk/base/[hex, nfc]
import logos_sdk/cbor/utf8
import logos_sdk/cbor
import logos_sdk/crypto/blake3
import logos_sdk/iface/accept
from logos_sdk/iface/surface import schemaCommitment
import ./[errors, manifest, signing]

when defined(posix):
  import std/posix

export results, errors, manifest, signing

const
  ManifestCborPath* = "manifest.cbor" ## [SPEC PM §3]
  ManifestCosePath* = "manifest.cose" ## [SPEC PM §3]
  VariantsDir* = "variants" ## [SPEC PM §7.1]
  FileMode* = 0o644 ## [SPEC PM §7.1]
  DirMode* = 0o755 ## [SPEC PM §7.1]
  GzipOsUnknown* = 255'u8 ## [SPEC PM §7.1] RFC 1952 OS byte
  PieceBytes* = 1 shl 20
    ## [IMPL-DECISION G446] one read of an archive's source, and one inflated piece
  MaxSignatureBytes* = 1024 * 1024
    ## [IMPL-DECISION G446] the largest `manifest.cose` kept; a larger one fails verification
    ## (one that verifies is under 17 KiB)
  MaxKeptDocumentBytes* = 8 * 1024 * 1024 + 1
    ## [IMPL-DECISION G446] the most of one document a reading keeps: the largest bound any check
    ## applies to one (a configuration value's 8 MiB, CONFIGURATION §2) and one byte, so a larger
    ## document fails each size check as its whole bytes would
  BlockSize = 512
  NameLen = 100
  PrefixLen = 155

type
  LgxLimits* = object
    ## [SPEC PM §7.1] [IMPL-DECISION G75] Bounds applied before untrusted input
    ## is processed further; the deployment profile sets them.
    compressed*: int64 ## the `.lgx` bytes
    decompressed*: int64 ## the tar stream
    entries*: int ## archive entries, directories included
    entry*: int64 ## one regular file
    extracted*: int64 ## the selected variant's artifact bytes
    documents*: int64
      ## the selected variant's kept contract and configuration documents, in all (G75's sixth
      ## row, G446): each is counted as kept, at most `MaxKeptDocumentBytes`

  Platform* = object
    ## [IMPL-DECISION G73] What the selected platform profile supplies; an
    ## absent `abi` matches only variants that leave it unconstrained.
    os*: string
    architecture*: string
    abi*: Opt[string]

  LgxEntryKind* = enum
    lekFile
    lekDir

  LgxEntry* = object
    path*: string ## normalized: no trailing slash
    kind*: LgxEntryKind
    data*: seq[byte]

  LgxArchive* = object
    ## An archive whose gzip, USTAR, path and root-structure rules hold.
    entries*: seq[LgxEntry] ## in archive (byte) order

  SelectedArtifact* = object
    artifact*: ManifestArtifact
    size*: int64 ## the file's size; its bytes matched `artifact.hash`
    data*: seq[byte] ## the bytes, from `openLgx` only; `inspectLgx` keeps none

  LgxPackage* = object
    verified*: VerifiedPackage
    signature*: seq[byte]
      ## `manifest.cose`'s bytes, as verified; the installed-state store keeps them with
      ## `manifest.cbor` (step 5-5-2, G444)
    variant*: PackageVariant ## the selected variant
    artifacts*: seq[SelectedArtifact] ## the selected variant's, in manifest order
    modules*: seq[ModuleDeclaration]
      ## [SPEC PM §5, §7.1] the selected module declarations, in manifest order
    contracts*: seq[ContractSet]
      ## [SPEC PM §4 l.355-359] each `contract_documents` entry's contract,
      ## constructed from the selected variant's documents, in manifest order.
      ## Carrying one grants no authority to provide it (l.359).
    documents*: Table[string, seq[byte]]
      ## [IMPL-DECISION G446] the selected variant's documents, by artifact id: each contract
      ## entry's schema and input artifacts, and each selected module's configuration schema and
      ## default (PKG-0060, G451; the store's admission check, G452)
    archiveBytes*: int64
      ## the archive's size as judged; `extractLgx` checks its source against it
    limits*: LgxLimits
      ## the limits it was judged under; `extractLgx` reads it again under them

  LgxStop* = ptr Atomic[bool]
    ## a stop flag (5-5's W2), checked once per piece and between entries; nil: never stopped

  LgxSourceKind* = enum
    lsFile
      ## a file, such as a spool file: opened `O_NOFOLLOW`, a regular file, read in pieces
    lsBytes ## bytes in memory

  LgxSource* = object ## [IMPL-DECISION G446] Where an archive is read from.
    case kind*: LgxSourceKind
    of lsFile:
      path*: string
    of lsBytes:
      bytes*: seq[byte]

const DefaultLgxLimits* = LgxLimits(
  compressed: 1 shl 30,
  decompressed: 4 shl 30,
  entries: 65_536,
  entry: 1 shl 30,
  extracted: 4 shl 30,
  documents: 64 shl 20,
) ## [IMPL-DECISION G75] Seed values until real packages are measured.

func fileSource*(path: string): LgxSource =
  LgxSource(kind: lsFile, path: path)

func bytesSource*(bytes: sink seq[byte]): LgxSource =
  LgxSource(kind: lsBytes, bytes: bytes)

func invalid(msg: string): PackageError =
  packageError(pecInvalidPackage, msg)

func integrity(msg: string): PackageError =
  packageError(pecArtifactIntegrity, msg)

# Gzip (RFC 1952) -------------------------------------------------------------------

func le32(b: openArray[byte], at: int): uint32 =
  uint32(b[at]) or (uint32(b[at + 1]) shl 8) or (uint32(b[at + 2]) shl 16) or
    (uint32(b[at + 3]) shl 24)

func addLe32(s: var seq[byte], v: uint32) =
  for i in 0 .. 3:
    s.add(byte((v shr (8 * i)) and 0xff))

proc gzipCompress*(data: openArray[byte]): Result[seq[byte], string] =
  ## [SPEC PM §7.1] One gzip member: no file name, modification time zero, OS
  ## byte 255, maximum compression.
  var output = @[0x1f'u8, 0x8b, 8, 0, 0, 0, 0, 0, 2, GzipOsUnknown]
  var zs: ZStream
  if deflateInit2(
    zs, Z_BEST_COMPRESSION, Z_DEFLATED, Z_RAW_DEFLATE, Z_MEM_8, Z_DEFAULT_STRATEGY
  ) != Z_OK:
    return err("deflateInit2 failed")
  let bound = int(deflateBound(zs, culong(data.len)))
  var buf = newSeq[byte](bound + 64)
  zs.next_in =
    if data.len == 0:
      nil
    else:
      cast[ptr uint8](unsafeAddr data[0])
  zs.avail_in = cuint(data.len)
  zs.next_out = addr buf[0]
  zs.avail_out = cuint(buf.len)
  let rc = deflate(zs, Z_FINISH)
  let produced = int(zs.total_out)
  discard deflateEnd(zs)
  if rc != Z_STREAM_END:
    return err("deflate did not finish")
  output.add(buf.toOpenArray(0, produced - 1))
  output.addLe32(uint32(crc32(data)))
  output.addLe32(uint32(data.len and 0xffff_ffff))
  ok(output)

# Paths -----------------------------------------------------------------------------

func checkArchivePath*(path: string): Result[void, string] =
  ## [SPEC PM §7.1] Relative, UTF-8, NFC; no empty, `.` or `..` segment, no
  ## backslash, no NUL.
  if path.len == 0:
    return err("an empty path")
  if not isValidUtf8(path):
    return err("a path that is not UTF-8")
  if '\0' in path:
    return err("a NUL byte in a path")
  if '\\' in path:
    return err("a backslash in " & path)
  if path[0] == '/':
    return err("an absolute path " & path)
  for seg in path.split('/'):
    if seg.len == 0 or seg == "." or seg == "..":
      return err("an empty, . or .. segment in " & path)
  if not isNfc(path):
    return err("a path that is not NFC-normalized: " & path)
  ok()

func isVariantId*(id: string): bool =
  ## [SPEC PM §7.1] Lowercase ASCII letters, digits, `.`, `_` and `-`, forming
  ## one non-empty path segment (so not `.` or `..`).
  if id.len == 0 or id == "." or id == "..":
    return false
  for c in id:
    if c notin {'a' .. 'z', '0' .. '9', '.', '_', '-'}:
      return false
  true

# USTAR -----------------------------------------------------------------------------

func putOctal(h: var array[BlockSize, byte], at, width: int, v: uint64) =
  ## `width - 1` zero-padded octal digits and a NUL.
  var s = toOct(BiggestInt(v), width - 1)
  for i, c in s:
    h[at + i] = byte(c)
  h[at + width - 1] = 0

func putText(h: var array[BlockSize, byte], at: int, s: string) =
  for i, c in s:
    h[at + i] = byte(c)

func splitPath(path: string): Result[(string, string), string] =
  ## [IMPL-DECISION G40] The USTAR (prefix, name) for `path`; a path that fits
  ## neither way is refused (no pax).
  if path.len <= NameLen:
    return ok(("", path))
  for i in countdown(min(path.len - 1, PrefixLen), 1):
    if path[i] == '/' and path.len - i - 1 <= NameLen and path.len - i - 1 > 0:
      return ok((path[0 ..< i], path[i + 1 .. ^1]))
  err("the path does not fit a USTAR header: " & path)

func header(e: LgxEntry): Result[array[BlockSize, byte], string] =
  var h: array[BlockSize, byte]
  let name =
    if e.kind == lekDir:
      e.path & "/"
    else:
      e.path
  let (prefix, rest) = ?splitPath(name)
  h.putText(0, rest)
  h.putOctal(100, 8, uint64(if e.kind == lekDir: DirMode else: FileMode))
  h.putOctal(108, 8, 0)
  h.putOctal(116, 8, 0)
  h.putOctal(124, 12, uint64(if e.kind == lekDir: 0 else: e.data.len))
  h.putOctal(136, 12, 0)
  h[156] = byte(if e.kind == lekDir: '5' else: '0')
  h.putText(257, "ustar")
  h.putText(263, "00")
  h.putOctal(329, 8, 0)
  h.putOctal(337, 8, 0)
  h.putText(345, prefix)
  for i in 148 ..< 156:
    h[i] = byte(' ')
  var sum = 0'u64
  for b in h:
    sum += uint64(b)
  h.putOctal(148, 7, sum)
  h[155] = byte(' ')
  ok(h)

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

proc writeTar(entries: seq[LgxEntry]): Result[seq[byte], string] =
  var output: seq[byte]
  for e in entries:
    let h = ?header(e)
    output.add(h)
    if e.kind == lekFile:
      output.add(e.data)
      let pad = (BlockSize - e.data.len mod BlockSize) mod BlockSize
      output.setLen(output.len + pad)
  output.setLen(output.len + 2 * BlockSize)
  ok(output)

func parseHeader(
    h: array[BlockSize, byte], limits: LgxLimits
): Result[(string, LgxEntryKind, uint64), string] =
  ## [SPEC PM §7.1] [IMPL-DECISION G40, G41] One POSIX USTAR header: a regular
  ## file (mode 0644) or a directory (mode 0755), zero ids and times, empty user
  ## and group names, no link name; a file within the entry-size limit. The path
  ## (a directory's without its slash), the kind and the data's size.
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
  ok((path, kind, size))

# Archive structure -----------------------------------------------------------------

func checkEntry(
    prev: string, first: bool, path: string, kind: LgxEntryKind
): Result[void, string] =
  ## [SPEC PM §7.1] One entry after `prev` (none when `first`): its path valid,
  ## and greater than the one before; the root holds only the manifest files and
  ## `variants/`; `variants/` holds directories only, each a valid variant id.
  ?checkArchivePath(path)
  if not first and not (prev < path):
    return err(
      if prev == path:
        "a duplicate path: " & path
      else:
        "entries are not in path byte order at " & path
    )
  let segs = path.split('/')
  case segs[0]
  of ManifestCborPath, ManifestCosePath:
    if segs.len != 1 or kind != lekFile:
      return err(segs[0] & " is not a regular file at the root")
  of VariantsDir:
    if segs.len == 1 and kind != lekDir:
      return err("variants is not a directory")
    if segs.len == 2 and kind != lekDir:
      return err("a file directly under variants/: " & path)
    if segs.len >= 2 and not isVariantId(segs[1]):
      return err("an invalid variant directory name: " & segs[1])
  else:
    return err("an entry outside the permitted root names: " & path)
  ok()

func checkStructure(entries: seq[LgxEntry]): Result[void, string] =
  ## [SPEC PM §7.1] Paths are valid, unique and in byte order; the root holds
  ## only the manifest files and `variants/`; `variants/` holds directories
  ## only, each a valid variant id.
  for i, e in entries:
    ?checkEntry(
      if i > 0:
        entries[i - 1].path
      else:
        "",
      i == 0,
      e.path,
      e.kind,
    )
  ok()

func file*(a: LgxArchive, path: string): Opt[seq[byte]] =
  for e in a.entries:
    if e.path == path and e.kind == lekFile:
      return Opt.some(e.data)
  Opt.none(seq[byte])

# Writing ---------------------------------------------------------------------------

proc writeLgx*(
    manifestCbor, manifestCose: seq[byte],
    variants: seq[(string, seq[(string, seq[byte])])],
): Result[seq[byte], string] =
  ## [SPEC PM §7.1] [IMPL-DECISION G40, G41] An LGX archive: entries in path
  ## byte order, a 0755 directory entry for every directory, 0644 files, zero
  ## ids and times, empty names, no pax headers. `variants` maps each variant id
  ## to its files, by path relative to the variant directory.
  var files = @[(ManifestCborPath, manifestCbor), (ManifestCosePath, manifestCose)]
  var dirs = initHashSet[string]()
  dirs.incl(VariantsDir)
  for (id, content) in variants:
    if not isVariantId(id):
      return err("an invalid variant id: " & id)
    dirs.incl(VariantsDir & "/" & id)
    for (rel, bytes) in content:
      let path = VariantsDir & "/" & id & "/" & rel
      files.add((path, bytes))
      let segs = path.split('/')
      for i in 3 ..< segs.len:
        dirs.incl(segs[0 ..< i].join("/"))
  var entries: seq[LgxEntry]
  for d in dirs:
    entries.add(LgxEntry(path: d, kind: lekDir))
  for (p, b) in files:
    entries.add(LgxEntry(path: p, kind: lekFile, data: b))
  entries.sort(
    proc(a, b: LgxEntry): int =
      cmp(a.path, b.path)
  )
  ?checkStructure(entries)
  gzipCompress(?writeTar(entries))

# Platforms -------------------------------------------------------------------------

const
  DefinedOs* = ["android", "darwin", "ios", "linux", "windows"]
    ## [IMPL-DECISION G73] the `os` values our deployment profile defines
    ## (PM §7.1, BCP §5.4)
  DefinedArchitectures* = ["aarch64", "x86_64"] ## [IMPL-DECISION G73]
  DefinedAbis* = ["gnu", "mingw", "msvc", "musl"] ## [IMPL-DECISION G73]

func hostPlatform*(): Platform =
  ## [IMPL-DECISION G73] The platform this build runs on.
  let os =
    when defined(android):
      "android"
    elif defined(ios):
      "ios"
    elif defined(macosx):
      "darwin"
    elif defined(windows):
      "windows"
    else:
      "linux"
  let arch = when defined(arm64): "aarch64" else: "x86_64"
  let abi =
    when defined(windows):
      Opt.some(when defined(vcc): "msvc" else: "mingw")
    elif defined(linux) and not defined(android):
      Opt.some(when defined(musl): "musl" else: "gnu")
    else:
      Opt.none(string)
  Platform(os: os, architecture: arch, abi: abi)

func matches(want: string, have: Opt[string], defined: openArray[string]): bool =
  ## [SPEC PM §7.1] A value with no defined matching rule never matches.
  ## [IMPL-DECISION G73] A defined value matches itself byte for byte.
  want in defined and have.isSome and have.get == want

func compatible*(c: PlatformConstraint, p: Platform): bool =
  ## [SPEC PM §7.1] [IMPL-DECISION G73] Each present field matches the
  ## platform's value under the profile's rules; an absent field constrains
  ## nothing.
  (c.os.isNone or c.os.get.matches(Opt.some(p.os), DefinedOs)) and (
    c.architecture.isNone or
    c.architecture.get.matches(Opt.some(p.architecture), DefinedArchitectures)
  ) and (c.abi.isNone or c.abi.get.matches(p.abi, DefinedAbis))

func selectVariant*(m: Manifest, p: Platform): Result[int, PackageError] =
  ## [SPEC PM §7.1] The first compatible variant in declared order.
  for i, v in m.variants:
    if v.platform.compatible(p):
      return ok(i)
  err(
    packageError(
      pecIncompatiblePlatform,
      "no variant is compatible with " & p.os & "/" & p.architecture,
    )
  )

const WindowsReserved = [
  "con", "prn", "aux", "nul", "com0", "com1", "com2", "com3", "com4", "com5", "com6",
  "com7", "com8", "com9", "lpt0", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6",
  "lpt7", "lpt8", "lpt9",
]

type PathRules* = object
  ## [SPEC PM §7.1] The path-comparison rules of the filesystem and namespace
  ## used for installation, which the deployment documents (PKG-0486).
  ignoreCase*: bool ## paths that differ only in case name one entry
  windowsNames*: bool
    ## reserved device names, `<>:"|?*`, control characters and segments
    ## ending in `.` or space are refused

func hostPathRules*(): PathRules =
  ## [IMPL-DECISION G73] The conservative rules for this build's own default
  ## filesystems: case-insensitive on darwin, ios and windows, plus the Windows
  ## naming rules on windows. An installer passes its real root's rules.
  when defined(windows):
    PathRules(ignoreCase: true, windowsNames: true)
  elif defined(macosx) or defined(ios):
    PathRules(ignoreCase: true)
  else:
    PathRules()

func checkInstallPaths*(
    paths: openArray[string], rules: PathRules
): Result[void, string] =
  ## [SPEC PM §7.1] [IMPL-DECISION G73] The selected variant's paths, and their
  ## directories, under the installation's rules: under `ignoreCase`, two that
  ## differ only in case (`unicode.toLower` over every prefix) collide.
  if not rules.ignoreCase and not rules.windowsNames:
    return ok()
  var seen = initTable[string, string]()
  for p in paths:
    let segs = p.split('/')
    for i in 1 .. segs.len:
      if not rules.ignoreCase:
        break
      let prefix = segs[0 ..< i].join("/")
      let folded = unicode.toLower(prefix)
      let other = seen.getOrDefault(folded, prefix)
      if other != prefix:
        return err("paths collide when case is ignored: " & other & " and " & prefix)
      seen[folded] = prefix
    if rules.windowsNames:
      for seg in segs:
        let stem = unicode.toLower(seg.split('.')[0])
        if stem in WindowsReserved:
          return err("a reserved Windows device name: " & p)
        if seg.endsWith(".") or seg.endsWith(" "):
          return err("a segment ending in a dot or space: " & p)
        for c in seg:
          if c in {'<', '>', ':', '"', '|', '?', '*'} or ord(c) < 32:
            return err("a character Windows does not allow in " & p)
  ok()

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

# Reading: one streaming pass (step 5-5-2b; G446; plan §4.3a) -------------------------

type
  FaultKind = enum
    fkFormat ## a format check, A to F: `invalid-package`
    fkRead ## the source cannot be read: the package is unavailable from it
    fkDiffers ## the extraction pass: the archive is not the judged one
    fkSink ## the extraction pass: the sink refused a write
    fkStopped

  Fault = object
    kind: FaultKind
    msg: string

func formatFault(msg: string): Fault =
  Fault(kind: fkFormat, msg: msg)

func readFault(msg: string): Fault =
  Fault(kind: fkRead, msg: msg)

func stopRequested(f: LgxStop): bool =
  not f.isNil and f[].load(moRelaxed)

func toPackageError(f: Fault): PackageError =
  ## A format failure is `invalid-package`; a source that cannot be read, or a stopped read,
  ## leaves the package unavailable (PM §8 l.1094).
  case f.kind
  of fkFormat:
    invalid(f.msg)
  of fkStopped:
    packageError(pecPackageUnavailable, "the archive's reading was stopped")
  of fkRead, fkDiffers, fkSink:
    packageError(pecPackageUnavailable, f.msg)

# The source ----------------------------------------------------------------------------

when defined(posix):
  var O_NOFOLLOW {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

type Input = object
  ## The archive's bytes, one piece (`win`, at most `PieceBytes`) at a time.
  size: int64 ## the archive's size: the file's at its open, or the bytes'
  off: int64 ## the archive offset of `win[0]`
  win: ptr UncheckedArray[byte]
  len: int ## bytes in `win`
  at: int ## bytes of `win` consumed
  mem: ptr UncheckedArray[byte] ## bytes in memory; nil for a file
  when defined(posix):
    fd: cint
  else:
    file: File
  isOpen: bool
  buf: seq[byte]
  path: string
  stop: LgxStop

proc memoryInput(data: openArray[byte], stop: LgxStop): Input =
  result = Input(size: int64(data.len), stop: stop, path: "the archive")
  if data.len > 0:
    result.mem = cast[ptr UncheckedArray[byte]](unsafeAddr data[0])

proc fileInput(path: string, stop: LgxStop): Result[Input, Fault] =
  ## [IMPL-DECISION G446] The file `path`, opened without following a link, which must be a
  ## regular file; its size is taken once, here.
  when defined(posix):
    let fd = posix.open(cstring(path), O_RDONLY or O_NOFOLLOW or O_CLOEXEC)
    if fd < 0:
      return err(readFault("cannot open the archive " & path & ": " & $strerror(errno)))
    var st: Stat
    if fstat(fd, st) != 0:
      let e = errno
      discard posix.close(fd)
      return err(readFault("cannot stat the archive " & path & ": " & $strerror(e)))
    if not S_ISREG(st.st_mode):
      discard posix.close(fd)
      return err(readFault("the archive " & path & " is not a regular file"))
    ok(
      Input(
        size: int64(st.st_size),
        fd: fd,
        isOpen: true,
        buf: newSeq[byte](PieceBytes),
        path: path,
        stop: stop,
      )
    )
  else:
    var f: File
    if not open(f, path, fmRead):
      return err(readFault("cannot open the archive " & path))
    var size = 0'i64
    try:
      size = getFileSize(f)
    except IOError as e:
      close(f)
      return err(readFault("cannot size the archive " & path & ": " & e.msg))
    ok(
      Input(
        size: size,
        file: f,
        isOpen: true,
        buf: newSeq[byte](PieceBytes),
        path: path,
        stop: stop,
      )
    )

proc release(inp: var Input) =
  if inp.isOpen:
    when defined(posix):
      discard posix.close(inp.fd)
    else:
      close(inp.file)
    inp.isOpen = false

func consumedAll(inp: Input): bool =
  inp.off + int64(inp.at) == inp.size

proc refill(inp: var Input): Result[void, Fault] =
  ## The next piece once this one is consumed; past the archive's end, an empty one. The stop
  ## flag is checked once per piece (W2).
  if inp.at < inp.len:
    return ok()
  if inp.stop.stopRequested:
    return err(Fault(kind: fkStopped, msg: "stopped"))
  inp.off += int64(inp.len)
  inp.at = 0
  inp.len = 0
  let want = int(min(int64(PieceBytes), inp.size - inp.off))
  if want <= 0:
    return ok()
  if not inp.mem.isNil:
    inp.win = cast[ptr UncheckedArray[byte]](addr inp.mem[int(inp.off)])
    inp.len = want
    return ok()
  var got = 0
  while got < want:
    var n = 0
    when defined(posix):
      n = posix.read(inp.fd, addr inp.buf[got], want - got)
      if n < 0:
        if errno == EINTR:
          continue
        return err(
          readFault("cannot read the archive " & inp.path & ": " & $strerror(errno))
        )
    else:
      try:
        n = readBuffer(inp.file, addr inp.buf[got], want - got)
      except IOError as e:
        return err(readFault("cannot read the archive " & inp.path & ": " & e.msg))
    if n == 0:
      return err(readFault("the archive " & inp.path & " ends before its size"))
    got += n
  inp.win = cast[ptr UncheckedArray[byte]](addr inp.buf[0])
  inp.len = want
  ok()

proc takeByte(inp: var Input): Result[byte, Fault] =
  ?inp.refill()
  if inp.at >= inp.len:
    return err(readFault("the archive " & inp.path & " ends before its size"))
  let b = inp.win[inp.at]
  inc inp.at
  ok(b)

proc consume(inp: var Input, n: int64, crc: var culong): Result[void, Fault] =
  ## `n` bytes, which the caller knows are there, into `crc`.
  var left = n
  while left > 0:
    ?inp.refill()
    if inp.at >= inp.len:
      return err(readFault("the archive " & inp.path & " ends before its size"))
    let k = int(min(left, int64(inp.len - inp.at)))
    crc = crc32(crc, cast[ptr uint8](addr inp.win[inp.at]), cuint(k))
    inp.at += k
    left -= k
  ok()

# B: the gzip header ----------------------------------------------------------------------

proc readGzipHeader(inp: var Input): Result[void, Fault] =
  ## [SPEC PM §7.1] [IMPL-DECISION G41] B, before anything is inflated: one gzip member with no
  ## file name, modification time zero and OS byte 255. The checks and messages are those the
  ## in-memory reader made, in its order. A position past the archive's end is kept as a
  ## number, as it was, so that the same check fails; the bytes before it are read, for the
  ## header CRC.
  let size = inp.size
  if size < 18:
    return err(formatFault("too short for gzip"))
  var h: array[10, byte]
  for i in 0 ..< h.len:
    h[i] = ?inp.takeByte()
  var crc = crc32(0, addr h[0], cuint(h.len))
  if h[0] != 0x1f or h[1] != 0x8b or h[2] != 8:
    return err(formatFault("not a deflate gzip member"))
  let flags = h[3]
  if (flags and 0xe0) != 0:
    return err(formatFault("reserved gzip flags are set"))
  if (flags and 0x08) != 0:
    return err(formatFault("the gzip header names the original file"))
  if le32(h, 4) != 0:
    return err(formatFault("the gzip modification time is not zero"))
  if h[9] != GzipOsUnknown:
    return err(formatFault("the gzip OS byte is not 255"))
  var pos = 10'i64
  if (flags and 0x04) != 0: # FEXTRA
    if pos + 2 > size:
      return err(formatFault("a truncated gzip extra field"))
    var x: array[2, byte]
    x[0] = ?inp.takeByte()
    x[1] = ?inp.takeByte()
    crc = crc32(crc, addr x[0], 2)
    let xlen = int64(x[0]) or (int64(x[1]) shl 8)
    pos += 2
    ?inp.consume(min(xlen, size - pos), crc)
    pos += xlen
  if (flags and 0x10) != 0: # FCOMMENT: up to and past its NUL
    while pos < size:
      ?inp.refill()
      let start = inp.at
      var i = start
      while i < inp.len and inp.win[i] != 0:
        inc i
      let nul = i < inp.len
      let n = i - start + (if nul: 1 else: 0)
      crc = crc32(crc, cast[ptr uint8](addr inp.win[start]), cuint(n))
      inp.at = start + n
      pos += int64(i - start)
      if nul:
        break
    pos += 1
  if (flags and 0x02) != 0: # FHCRC
    if pos + 2 > size:
      return err(formatFault("a truncated gzip header CRC"))
    let lo = ?inp.takeByte()
    let hi = ?inp.takeByte()
    if int(uint32(crc) and 0xffff) != (int(lo) or (int(hi) shl 8)):
      return err(formatFault("the gzip header CRC does not match"))
    pos += 2
  if pos >= size:
    return err(formatFault("a truncated gzip header"))
  ok()

# The extraction pass's consumer (before the tar cursor, whose generic procs call it) ----------
#
# Its procs must come first: `extractLgx` is generic and instantiated in another module, and Nim
# then finds the tar cursor's `mixin` symbols only where the cursor is defined and in that module,
# not here (Nim 2.2.14). `Keep` and `Inspect` are used from plain procs here, so they can follow.

type
  LgxExtractFault* = enum
    xfDiffers = "the archive is not the judged package"
    xfSink = "an artifact could not be written"
    xfStopped = "stopped"

  LgxExtractError* = object
    fault*: LgxExtractFault
    detail*: string ## for the operator's log

  Extract[S] = object
    sink: ptr S
    pkg: ptr LgxPackage
    prefix: string ## the selected variant's directory
    want: Table[string, int] ## path in the variant, to its artifact
    written: seq[bool]
    cur: int ## the artifact being written; -1: none
    hasher: Blake3Hasher

func differs(msg: string): Fault =
  Fault(kind: fkDiffers, msg: msg)

func toExtract(f: Fault): LgxExtractError =
  case f.kind
  of fkSink:
    LgxExtractError(fault: xfSink, detail: f.msg)
  of fkStopped:
    LgxExtractError(fault: xfStopped, detail: f.msg)
  of fkFormat, fkRead, fkDiffers:
    LgxExtractError(fault: xfDiffers, detail: f.msg)

proc onEntry[S](
    x: var Extract[S], path: string, kind: LgxEntryKind, size: int64
): Result[void, Fault] =
  mixin sinkBegin
  x.cur = -1
  if kind != lekFile or not path.startsWith(x.prefix):
    return ok()
  let rel = path[x.prefix.len .. ^1]
  let i = x.want.getOrDefault(rel, -1)
  if i < 0:
    return err(differs("a file the judged variant does not declare: " & path))
  if x.written[i]:
    return err(differs("a file written twice: " & path))
  if size != x.pkg[].artifacts[i].size:
    return err(differs("a size other than the judged one: " & path))
  if not x.sink[].sinkBegin(rel):
    return err(Fault(kind: fkSink, msg: path))
  x.cur = i
  x.hasher.init()
  ok()

proc onData[S](x: var Extract[S], b: openArray[byte]): Result[void, Fault] =
  mixin sinkWrite
  if x.cur >= 0:
    x.hasher.update(b)
    if not x.sink[].sinkWrite(b):
      return err(Fault(kind: fkSink, msg: x.pkg[].artifacts[x.cur].artifact.path))
  ok()

proc onEnd[S](x: var Extract[S]): Result[void, Fault] =
  mixin sinkEnd
  if x.cur < 0:
    return ok()
  let i = x.cur
  x.cur = -1
  let art = x.pkg[].artifacts[i].artifact
  if not x.sink[].sinkEnd():
    return err(Fault(kind: fkSink, msg: art.path))
  if x.hasher.finish() != art.hash:
    return err(differs("artifact " & art.id & " does not match its hash"))
  x.written[i] = true
  ok()

# E and F: the tar cursor ------------------------------------------------------------------

type
  TarState = enum
    tsHeader ## collecting a header block
    tsData ## an entry's data
    tsPad ## the zero padding after it
    tsSecondZero ## the block after a zero block, which must be zero too
    tsEnd ## after the end blocks: complete zero blocks only

  Tar = object
    ## [SPEC PM §7.1] [IMPL-DECISION G40, G41] The tar stream as it is inflated: each header's
    ## checks (`parseHeader`) and its path's (`checkEntry`) before its data is read, its data
    ## handed to a consumer, its padding, then the end blocks and the zero blocks after them.
    state: TarState
    hdr: array[BlockSize, byte]
    have: int ## bytes of `hdr` collected
    entries: int
    path: string ## the current entry's, then the previous one's
    size: int64
    left: int64 ## the current entry's data still to come
    pad: int ## its padding still to come
    pos: int64 ## tar bytes consumed
    endAt: int64 ## the tar offset after the end blocks
    trailing: bool ## a byte after the end blocks that is not zero
    stop: LgxStop

proc entryDone[C](t: var Tar, c: var C): Result[void, Fault] =
  mixin onEnd
  ?c.onEnd()
  t.pad = int((BlockSize - t.size mod BlockSize) mod BlockSize)
  t.state = if t.pad > 0: tsPad else: tsHeader
  ok()

proc header[C](t: var Tar, c: var C, limits: LgxLimits): Result[void, Fault] =
  mixin onEntry
  if t.stop.stopRequested:
    return err(Fault(kind: fkStopped, msg: "stopped"))
  if t.entries >= limits.entries:
    return err(formatFault("more entries than the archive-entry limit"))
  let (path, kind, size) = parseHeader(t.hdr, limits).valueOr:
    return err(formatFault(error))
  checkEntry(t.path, t.entries == 0, path, kind).isOkOr:
    return err(formatFault(error))
  inc t.entries
  t.path = path
  t.size = int64(size)
  ?c.onEntry(path, kind, t.size)
  if t.size == 0:
    return t.entryDone(c)
  t.state = tsData
  t.left = t.size
  ok()

proc feed[C](
    t: var Tar, c: var C, limits: LgxLimits, p: openArray[byte]
): Result[void, Fault] =
  ## One inflated piece.
  mixin onData
  var i = 0
  while i < p.len:
    case t.state
    of tsHeader, tsSecondZero:
      let n = min(BlockSize - t.have, p.len - i)
      copyMem(addr t.hdr[t.have], unsafeAddr p[i], n)
      t.have += n
      i += n
      if t.have == BlockSize:
        t.have = 0
        if t.state == tsSecondZero:
          if not isZeroBlock(t.hdr, 0):
            return err(formatFault("a zero block that is not the end of the archive"))
          t.state = tsEnd
          t.endAt = t.pos + int64(i)
        elif isZeroBlock(t.hdr, 0):
          t.state = tsSecondZero
        else:
          ?t.header(c, limits)
    of tsData:
      let n = int(min(t.left, int64(p.len - i)))
      ?c.onData(p.toOpenArray(i, i + n - 1))
      t.left -= int64(n)
      i += n
      if t.left == 0:
        ?t.entryDone(c)
    of tsPad:
      let n = min(t.pad, p.len - i)
      for j in i ..< i + n:
        if p[j] != 0:
          return err(formatFault("non-zero padding after " & t.path))
      t.pad -= n
      i += n
      if t.pad == 0:
        t.state = tsHeader
    of tsEnd:
      if not t.trailing:
        for j in i ..< p.len:
          if p[j] != 0:
            t.trailing = true
            break
      i = p.len
  t.pos += int64(p.len)
  ok()

func finish(t: Tar): Result[void, Fault] =
  ## The tar's end, once the inflated stream has ended: two zero blocks, then only complete
  ## zero blocks.
  case t.state
  of tsHeader:
    err(formatFault("the archive ends without its end-of-archive blocks"))
  of tsSecondZero:
    err(formatFault("a zero block that is not the end of the archive"))
  of tsData, tsPad:
    err(formatFault("an entry's data is truncated: " & t.path))
  of tsEnd:
    if (t.pos - t.endAt) mod BlockSize != 0:
      err(formatFault("archive padding that is not a whole number of 512-byte blocks"))
    elif t.trailing:
      err(formatFault("data after the end of the archive"))
    else:
      ok()

# The pass ------------------------------------------------------------------------------------

proc streamPass[C](inp: var Input, limits: LgxLimits, c: var C): Result[void, Fault] =
  ## [SPEC PM §7.1, §8] The format checks A to F over `inp`, in stream order, each entry handed
  ## to `c` (`onEntry`, `onData`, `onEnd`): the compressed size (A), before anything is read;
  ## the gzip header (B); the inflate (C), each piece within the decompressed-size limit before
  ## it is used; the tar (E, F) as the pieces arrive; at the stream's end, the tar's end, then
  ## the trailer's CRC-32 and size (D), then nothing after the member.
  if inp.size > limits.compressed:
    return err(formatFault("the archive is larger than the compressed-size limit"))
  ?inp.readGzipHeader()
  var zs: ZStream
  if inflateInit2(zs, Z_RAW_DEFLATE) != Z_OK:
    return err(readFault("inflateInit2 failed"))
  defer:
    discard inflateEnd(zs)
  var output = newSeq[byte](PieceBytes)
  var total = 0'i64
  var crc: culong = 0
  var t = Tar(stop: inp.stop)
  var rc = Z_OK
  while rc != Z_STREAM_END:
    ?inp.refill()
    let avail = inp.len - inp.at
    zs.next_in =
      if avail > 0:
        cast[ptr uint8](addr inp.win[inp.at])
      else:
        nil
    zs.avail_in = cuint(avail)
    zs.next_out = addr output[0]
    zs.avail_out = cuint(output.len)
    rc = inflate(zs, Z_NO_FLUSH)
    inp.at += avail - int(zs.avail_in)
    if rc != Z_OK and rc != Z_STREAM_END:
      return err(formatFault("the deflate stream is corrupt or truncated"))
    let n = output.len - int(zs.avail_out)
    if total + int64(n) > limits.decompressed:
      return err(formatFault("the archive inflates past the decompressed-size limit"))
    if n > 0:
      crc = crc32(crc, addr output[0], cuint(n))
      total += int64(n)
      ?t.feed(c, limits, output.toOpenArray(0, n - 1))
    if rc == Z_OK and n == 0 and zs.avail_in == 0 and inp.consumedAll:
      return err(formatFault("the deflate stream is truncated"))
  ?t.finish()
  let trailer = inp.off + int64(inp.at)
  if trailer + 8 > inp.size:
    return err(formatFault("the gzip trailer is truncated"))
  var tail: array[8, byte]
  for i in 0 ..< tail.len:
    tail[i] = ?inp.takeByte()
  if le32(tail, 0) != uint32(crc):
    return err(formatFault("the gzip CRC-32 does not match"))
  if le32(tail, 4) != uint32(total and 0xffff_ffff):
    return err(formatFault("the gzip size does not match"))
  if trailer + 8 != inp.size:
    return err(
      formatFault("data follows the gzip member (another member or trailing bytes)")
    )
  ok()

# readLgx: every entry kept ---------------------------------------------------------------

type Keep = object
  entries: seq[LgxEntry]

proc onEntry(
    k: var Keep, path: string, kind: LgxEntryKind, size: int64
): Result[void, Fault] =
  k.entries.add(LgxEntry(path: path, kind: kind))
  ok()

proc onData(k: var Keep, b: openArray[byte]): Result[void, Fault] =
  k.entries[^1].data.add(b)
  ok()

proc onEnd(k: var Keep): Result[void, Fault] =
  ok()

proc readLgx*(
    data: openArray[byte], limits = DefaultLgxLimits
): Result[LgxArchive, PackageError] =
  ## [SPEC PM §7.1, §8] The gzip, USTAR, path and root-structure rules, within
  ## the limits; every failure is `invalid-package`. Every entry is kept.
  var inp = memoryInput(data, nil)
  var k = Keep()
  streamPass(inp, limits, k).isOkOr:
    return err(error.toPackageError)
  ok(LgxArchive(entries: move k.entries))

# Opening a package -----------------------------------------------------------------

type
  Current = enum
    curNone
    curCbor
    curCose
    curSlot

  Slot = object ## One file of the selected variant.
    digest: Opt[Blake3Digest] ## none: not hashed, as past the extracted-size limit
    data: seq[byte] ## `openLgx` keeps every hashed file
    document: seq[byte] ## kept when the file is a document

  Inspect = object ## What the pass records for the content checks G to N.
    trust: ptr TrustInput
    platform: Platform
    limits: LgxLimits
    keepAll: bool
    cbor, cose: seq[byte]
    cborSeen, coseSeen, coseOversize: bool
    cborLeft: int64
    verifyRan: bool
    verified: Result[VerifiedPackage, PackageError] ## H's result, held
    selected: Result[int, PackageError] ## J's, held
    want: Table[string, int]
      ## the selected variant's files, by archive path, to their slot
    slots: seq[Slot]
    documentPaths: HashSet[string]
    hashed: int64 ## the selected variant's file sizes so far, in archive order
    hashStopped: bool
    documentsKept: int64
    documentsExcess: bool
    documentLeft: int64
    hasher: Blake3Hasher
    cur: Current
    slot: int
    # The path table, as the in-memory reader built it from its entries, in archive order.
    dirs: HashSet[string]
    files: Table[string, Table[string, int64]] ## variant, path, size
    subdirs: Table[string, HashSet[string]]

proc verifyEarly(c: var Inspect) =
  ## Step 6 (plan §4.3a): `manifest.cose` has arrived, after `manifest.cbor`. H runs now, and
  ## with a verified manifest J's selection, so that the selected variant's files are hashed
  ## and its documents kept as they pass. Both results are held for step 8. A `manifest.cose`
  ## over `MaxSignatureBytes` fails H's first check.
  if not c.cborSeen:
    return # G fails at step 8
  c.verifyRan = true
  c.verified =
    if c.coseOversize:
      Result[VerifiedPackage, PackageError].err(
        packageError(pecSignature, "manifest.cose is larger than 1 MiB")
      )
    else:
      verifyPackage(c.cbor, c.cose, c.trust[])
  if c.verified.isErr:
    return
  let m = c.verified.get.manifest
  c.selected = selectVariant(m, c.platform)
  if c.selected.isErr:
    return
  let v = m.variants[c.selected.get]
  var documentIds = initHashSet[string]()
  for d in m.contractDocuments:
    documentIds.incl(d.schemaArtifact)
    for id in d.inputArtifacts:
      documentIds.incl(id)
  var present = initHashSet[string]()
  for art in v.artifacts:
    present.incl(art.id)
  for d in m.modules:
    if d.artifact in present and d.configuration.isSome:
      let cfg = d.configuration.get
      documentIds.incl(cfg.schemaArtifact)
      if cfg.defaultArtifact.isSome:
        documentIds.incl(cfg.defaultArtifact.get)
  for art in v.artifacts:
    let full = VariantsDir & "/" & v.id & "/" & art.path
    if full notin c.want:
      c.want[full] = c.slots.len
      c.slots.add(Slot())
    if art.id in documentIds:
      c.documentPaths.incl(full)

proc onEntry(
    c: var Inspect, path: string, kind: LgxEntryKind, size: int64
): Result[void, Fault] =
  c.cur = curNone
  let segs = path.split('/')
  if segs[0] == VariantsDir:
    if segs.len >= 2:
      c.dirs.incl(segs[1])
      if segs.len > 2:
        let rel = segs[2 .. ^1].join("/")
        if kind == lekFile:
          c.files.mgetOrPut(segs[1], initTable[string, int64]())[rel] = size
        else:
          c.subdirs.mgetOrPut(segs[1], initHashSet[string]()).incl(rel)
        for i in 3 ..< segs.len:
          c.subdirs.mgetOrPut(segs[1], initHashSet[string]()).incl(
            segs[2 ..< i].join("/")
          )
    let s = c.want.getOrDefault(path, -1)
    if kind == lekFile and s >= 0 and not c.hashStopped:
      # [SPEC PM §7.1 l.945] the extracted-size bound, before the file is processed
      c.hashed += size
      if c.hashed > c.limits.extracted:
        c.hashStopped = true
        return ok()
      c.cur = curSlot
      c.slot = s
      c.hasher.init()
      if c.keepAll:
        c.slots[s].data = newSeqOfCap[byte](int(size))
      c.documentLeft = 0
      if path in c.documentPaths and not c.documentsExcess:
        # [G75's sixth row] the documents' total, before the document's data is read
        let keep = min(size, MaxKeptDocumentBytes)
        if c.documentsKept + keep > c.limits.documents:
          c.documentsExcess = true
        else:
          c.documentsKept += keep
          c.documentLeft = keep
  elif path == ManifestCborPath:
    # [SPEC PM §3] one byte past 4 MiB is enough for `decodeManifest` to refuse it
    c.cborSeen = true
    c.cborLeft = min(size, MaxManifestBytes + 1)
    c.cur = curCbor
  elif path == ManifestCosePath:
    c.coseSeen = true
    c.coseOversize = size > MaxSignatureBytes
    c.cur = curCose
  ok()

proc onData(c: var Inspect, b: openArray[byte]): Result[void, Fault] =
  case c.cur
  of curNone:
    discard
  of curCbor:
    let n = int(min(c.cborLeft, int64(b.len)))
    if n > 0:
      c.cbor.add(b.toOpenArray(0, n - 1))
      c.cborLeft -= int64(n)
  of curCose:
    if not c.coseOversize:
      c.cose.add(b)
  of curSlot:
    c.hasher.update(b)
    if c.keepAll:
      c.slots[c.slot].data.add(b)
    if c.documentLeft > 0:
      let n = int(min(c.documentLeft, int64(b.len)))
      c.slots[c.slot].document.add(b.toOpenArray(0, n - 1))
      c.documentLeft -= int64(n)
  ok()

proc onEnd(c: var Inspect): Result[void, Fault] =
  case c.cur
  of curSlot:
    c.slots[c.slot].digest = Opt.some(c.hasher.finish())
  of curCose:
    c.verifyEarly()
  of curNone, curCbor:
    discard
  c.cur = curNone
  ok()

proc judge(
    c: var Inspect, pathRules: PathRules, archiveBytes: int64
): Result[LgxPackage, PackageError] =
  ## Step 8: the content checks G to N, after the stream has passed A to F, in the order and with
  ## the messages of the in-memory reader, from what the pass recorded (G29's note).
  if not c.cborSeen:
    return err(invalid("the package has no manifest.cbor"))
  if not c.coseSeen:
    return err(packageError(pecSignature, "the package has no manifest.cose"))
  if not c.verifyRan: # unreachable: manifest.cbor sorts before manifest.cose
    return err(invalid("the package's manifest files are out of order"))
  let verified = ?c.verified
  let m = verified.manifest

  # Variant directories and their files.
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
  if c.dirs != ids:
    return
      err(invalid("variants/ does not hold exactly one directory per manifest variant"))

  let selected = ?c.selected
  for v in m.variants:
    let have = c.files.getOrDefault(v.id)
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
  for p in c.files.getOrDefault(v.id).keys:
    paths.add(p)
  for p in c.subdirs.getOrDefault(v.id):
    paths.add(p)
  paths.sort()
  checkInstallPaths(paths, pathRules).isOkOr:
    return err(invalid("variant " & v.id & ": " & error))

  var pkg = LgxPackage(
    verified: verified,
    signature: c.cose,
    variant: v,
    archiveBytes: archiveBytes,
    limits: c.limits,
  )
  var total = 0'i64
  let sizes = c.files.getOrDefault(v.id)
  for art in v.artifacts:
    let size = sizes.getOrDefault(art.path)
    total += size
    if total > c.limits.extracted:
      return err(integrity("the selected variant exceeds the extracted-size limit"))
    let s = c.want.getOrDefault(VariantsDir & "/" & v.id & "/" & art.path, -1)
    if s < 0 or c.slots[s].digest.isNone:
      # Not hashed: the archive-order total of the variant's files passed the limit, so the
      # manifest-order total does by its end (G29's note, case 6).
      return err(integrity("the selected variant exceeds the extracted-size limit"))
    if c.slots[s].digest.get != art.hash:
      return err(
        integrity("artifact " & art.id & " does not match its hash " & art.hash.toHex)
      )
    pkg.artifacts.add(
      SelectedArtifact(artifact: art, size: size, data: move c.slots[s].data)
    )
  # [G75's sixth row, G446] the one refusal the in-memory reader did not make
  if c.documentsExcess:
    return err(
      invalid(
        "the selected variant's contract and configuration documents pass the documents-size limit"
      )
    )
  for art in v.artifacts:
    let full = VariantsDir & "/" & v.id & "/" & art.path
    if full in c.documentPaths:
      pkg.documents[art.id] = c.slots[c.want.getOrDefault(full)].document
  pkg.contracts = ?buildContracts(m, pkg.documents)
  ?checkExtensions(m, pkg.contracts)
  var present = initHashSet[string]()
  for art in v.artifacts:
    present.incl(art.id)
  for d in m.modules:
    if d.artifact in present:
      pkg.modules.add(d)
  ok(pkg)

proc inspect(
    inp: var Input,
    trust: TrustInput,
    platform: Platform,
    limits: LgxLimits,
    pathRules: PathRules,
    keepAll: bool,
): Result[LgxPackage, PackageError] =
  var c = Inspect(
    trust: unsafeAddr trust, platform: platform, limits: limits, keepAll: keepAll
  )
  streamPass(inp, limits, c).isOkOr:
    return err(error.toPackageError)
  c.judge(pathRules, inp.size)

proc inspectLgx*(
    source: LgxSource,
    trust: TrustInput,
    platform = hostPlatform(),
    limits = DefaultLgxLimits,
    pathRules = hostPathRules(),
    stop: LgxStop = nil,
): Result[LgxPackage, PackageError] =
  ## [SPEC PM §2, §3, §4, §7.1, §8] [IMPL-DECISION G446] `openLgx`'s judgment, in one pass
  ## over `source` that keeps no artifact's bytes: each selected artifact carries its size, and
  ## its hash was checked as it passed. The selected variant's documents are kept, within
  ## `limits.documents`. A source that cannot be read, or a stop, is `package-unavailable`.
  case source.kind
  of lsFile:
    var inp = fileInput(source.path, stop).valueOr:
      return err(error.toPackageError)
    defer:
      inp.release()
    inspect(inp, trust, platform, limits, pathRules, keepAll = false)
  of lsBytes:
    var inp = memoryInput(source.bytes, stop)
    inspect(inp, trust, platform, limits, pathRules, keepAll = false)

proc openLgx*(
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
  ## and matching their hashes (`artifact-integrity-failed`); its documents
  ## within the documents-size limit (`invalid-package`, G446); each contract
  ## document constructing its commitment, and each `extends` entry extended
  ## by the declaration's contracts where both have entries (`invalid-package`,
  ## PM §4 l.358-360). The target platform comes from protected deployment
  ## policy (PM §7.1). The format checks run in stream order and the content
  ## checks after them (G29's note). Every selected artifact's bytes are kept.
  var inp = memoryInput(data, nil)
  inspect(inp, trust, platform, limits, pathRules, keepAll = true)

# Extracting a judged package -----------------------------------------------------------------

proc extractLgx*[S](
    source: LgxSource, pkg: LgxPackage, sink: var S, stop: LgxStop = nil
): Result[void, LgxExtractError] =
  ## [SPEC PM §7.1 l.926-933, l.963] [IMPL-DECISION G446] The extraction pass: `source` read
  ## again, under `pkg.limits` and with the same format checks, its size first checked against
  ## the judged one. Each regular file of the selected variant must be one of `pkg.artifacts`,
  ## by path and size, and goes to `sink` as it is inflated (`sinkBegin(path)`, `sinkWrite`
  ## per piece, `sinkEnd`; `sinkAbort` when the pass fails inside a file), hashed as it goes. At
  ## its end its digest must be the signed hash, so a file with wrong bytes stays in the sink
  ## only until then. Every artifact must have been written once; other variants' entries are
  ## inflated and dropped. Any difference from the judged package is `xfDiffers`.
  mixin sinkAbort
  var x = Extract[S](
    sink: addr sink,
    pkg: unsafeAddr pkg,
    prefix: VariantsDir & "/" & pkg.variant.id & "/",
    written: newSeq[bool](pkg.artifacts.len),
    cur: -1,
  )
  for i, a in pkg.artifacts:
    x.want[a.artifact.path] = i
  var inp: Input
  case source.kind
  of lsFile:
    inp = fileInput(source.path, stop).valueOr:
      return err(error.toExtract)
  of lsBytes:
    inp = memoryInput(source.bytes, stop)
  defer:
    inp.release()
  if inp.size != pkg.archiveBytes:
    return err(
      LgxExtractError(
        fault: xfDiffers, detail: "the archive's size is not the judged size"
      )
    )
  let r = streamPass(inp, pkg.limits, x)
  if r.isErr:
    if x.cur >= 0:
      x.sink[].sinkAbort()
    return err(r.error.toExtract)
  for i, w in x.written:
    if not w:
      return err(
        LgxExtractError(
          fault: xfDiffers,
          detail: "artifact " & pkg.artifacts[i].artifact.id & " is not in the archive",
        )
      )
  ok()
