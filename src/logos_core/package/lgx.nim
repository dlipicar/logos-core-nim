## PM §2, §3, §7.1, §8: the LGX realization profile. An LGX package is a gzip
## (RFC 1952) USTAR archive holding `manifest.cbor`, `manifest.cose` and one
## directory per manifest variant under `variants/`; nothing else may sit at
## the root. This module writes such archives, reads them with every §7.1
## structure, path and encoding rule checked, verifies the signature, selects
## the first compatible variant and checks its artifacts. It extracts nothing:
## installation (§7.1 extraction, PKG-0204/0219) belongs to the Package Manager.

{.push raises: [].}

import std/[algorithm, sets, strutils, tables, unicode]
import results
import zlib/zlib_api
import ../base/[hex, nfc]
import ../cbor/utf8
import ../crypto/blake3
import ./[errors, manifest, signing]

export results, errors, manifest, signing

const
  ManifestCborPath* = "manifest.cbor" ## [SPEC PM §3]
  ManifestCosePath* = "manifest.cose" ## [SPEC PM §3]
  VariantsDir* = "variants" ## [SPEC PM §7.1]
  FileMode* = 0o644 ## [SPEC PM §7.1]
  DirMode* = 0o755 ## [SPEC PM §7.1]
  GzipOsUnknown* = 255'u8 ## [SPEC PM §7.1] RFC 1952 OS byte
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
    data*: seq[byte] ## verified against `artifact.hash`

  LgxPackage* = object
    verified*: VerifiedPackage
    variant*: PackageVariant ## the selected variant
    artifacts*: seq[SelectedArtifact] ## the selected variant's, in manifest order
    modules*: seq[ModuleDeclaration]
      ## [SPEC PM §5, §7.1] the selected module declarations, in manifest order

const DefaultLgxLimits* = LgxLimits(
  compressed: 1 shl 30,
  decompressed: 4 shl 30,
  entries: 65_536,
  entry: 1 shl 30,
  extracted: 4 shl 30,
) ## [IMPL-DECISION G75] Seed values until real packages are measured.

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

proc readLgx*(
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

# Opening a package -----------------------------------------------------------------

proc openLgx*(
    data: openArray[byte],
    trust: TrustInput,
    platform = hostPlatform(),
    limits = DefaultLgxLimits,
    pathRules = hostPathRules(),
): Result[LgxPackage, PackageError] =
  ## [SPEC PM §2, §3, §4, §7.1, §8] In order: the archive rules
  ## (`invalid-package`); `manifest.cbor` present (`invalid-package`) and
  ## `manifest.cose` present (`signature-verification-failed`); the manifest and
  ## its signature (`verifyPackage`); one directory per manifest variant
  ## (`invalid-package`); each variant's files declared exactly once
  ## (`invalid-package`); the first compatible variant
  ## (`incompatible-platform`); its paths under the installation's rules
  ## (`invalid-package`); its artifacts present, within the extracted-size
  ## limit and matching their hashes (`artifact-integrity-failed`). The
  ## target platform comes from protected deployment policy (PM §7.1).
  let a = ?readLgx(data, limits)
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
  if dirs != ids:
    return
      err(invalid("variants/ does not hold exactly one directory per manifest variant"))

  let selected = ?selectVariant(m, platform)
  for vi, v in m.variants:
    let have = files.getOrDefault(v.id)
    var declared = initHashSet[string]()
    for art in v.artifacts:
      if declared.containsOrIncl(art.path):
        return err(invalid("variant " & v.id & ": two artifacts declare " & art.path))
      if art.path notin have:
        let msg = "variant " & v.id & ": artifact " & art.id & " is not a regular file"
        return err(
          if vi == selected:
            integrity(msg)
          else:
            invalid(msg)
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

  var pkg = LgxPackage(verified: verified, variant: v)
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
    pkg.artifacts.add(SelectedArtifact(artifact: art, data: bytes))
  var present = initHashSet[string]()
  for art in v.artifacts:
    present.incl(art.id)
  for d in m.modules:
    if d.artifact in present:
      pkg.modules.add(d)
  ok(pkg)
