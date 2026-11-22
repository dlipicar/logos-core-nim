## Step 5-5-2b (DECISIONS G446; plan §4.3a, "The peak test"): one inspection's peak resident size
## does not grow with the archive. Each case runs in a child process (this program, run again
## with `--peak-child`), which reads its own maximum resident size with `getrusage`: bytes on
## macOS, kilobytes on Linux. The parent writes each archive to disk as a stream, its content
## from a seeded generator that does not compress, so the archive is as large as its content and
## the reader's 1 MiB input pieces are all used; the child only reads it.
## - **The slope** (the claim): the streaming reader's peaks at 64 MiB and at 256 MiB
##   decompressed differ by at most 8 MiB [IMPL].
## - **The control**: the oracle, the in-memory reader, on the 64 MiB archive in another child;
##   its peak must pass the ceiling the streaming reader stays under, so the measure can fail.
## - The suite skips under the sanitizers, whose shadow memory dominates the figure.
## - With `LCN_LGX_PEAK_GIB=1` it also measures the largest archive the default 1 GiB
##   compressed-size limit admits (1008 MiB of content) and prints the figures, for CONFORMANCE:
##   a measurement run by hand.

import std/[algorithm, os, osproc, strutils]
import unittest2
import zlib/zlib_api
import ./support/[lgxcorpus, lgxoracle]

when defined(posix):
  import std/posix

const
  MiB = 1024 * 1024
  BlobBytes = 16 * MiB ## one data file
  Ceiling = 96 * MiB ## [IMPL] the streaming reader stays under it; the oracle passes it
  Slope = 8 * MiB ## [IMPL] plan §4.3a

proc maxResident(): int64 =
  ## This process's peak resident size, in bytes.
  when defined(posix):
    var ru: Rusage
    doAssert getrusage(RUSAGE_SELF, addr ru) == 0
    when defined(macosx):
      int64(ru.ru_maxrss)
    else:
      int64(ru.ru_maxrss) * 1024
  else:
    0

# The child -------------------------------------------------------------------------------

if paramCount() == 3 and paramStr(1) == "--peak-child":
  let path = paramStr(3)
  let r =
    if paramStr(2) == "oracle":
      let s = readFile(path)
      oracleOpenLgx(
        @(s.toOpenArrayByte(0, s.high)), trust, linuxHost, DefaultLgxLimits, PathRules()
      )
    else:
      inspectLgx(fileSource(path), trust, linuxHost, DefaultLgxLimits, PathRules())
  if r.isErr:
    echo "error ", r.error.msg
    quit(1)
  echo "peak ", maxResident()
  quit(0)

# Writing an archive as a stream ----------------------------------------------------------

type Content = object ## A seeded xorshift stream: bytes that do not compress.
  state: uint64

proc fill(c: var Content, buf: var seq[byte]) =
  var i = 0
  while i + 8 <= buf.len:
    c.state = c.state xor (c.state shl 13)
    c.state = c.state xor (c.state shr 7)
    c.state = c.state xor (c.state shl 17)
    copyMem(addr buf[i], addr c.state, 8)
    i += 8

proc blobDigest(seed: uint64, size: int): Blake3Digest =
  var c = Content(state: seed)
  var h: Blake3Hasher
  h.init()
  var buf = newSeq[byte](MiB)
  for _ in 0 ..< size div MiB:
    c.fill(buf)
    h.update(buf)
  h.finish()

type GzWriter = object
  f: File
  zs: ZStream
  crc: culong
  size: uint32
  outBuf: seq[byte]

proc open(w: var GzWriter, path: string) =
  doAssert open(w.f, path, fmWrite)
  let head = [0x1f'u8, 0x8b, 8, 0, 0, 0, 0, 0, 0, GzipOsUnknown]
  doAssert w.f.writeBytes(head, 0, head.len) == head.len
  doAssert deflateInit2(
    w.zs, Z_BEST_SPEED, Z_DEFLATED, Z_RAW_DEFLATE, Z_MEM_8, Z_DEFAULT_STRATEGY
  ) == Z_OK
  w.outBuf = newSeq[byte](2 * MiB)

proc deflateSome(w: var GzWriter, data: openArray[byte], flush: ZFlush) =
  w.zs.next_in =
    if data.len > 0:
      cast[ptr uint8](unsafeAddr data[0])
    else:
      nil
  w.zs.avail_in = cuint(data.len)
  while true:
    w.zs.next_out = addr w.outBuf[0]
    w.zs.avail_out = cuint(w.outBuf.len)
    let rc = deflate(w.zs, flush)
    doAssert rc in [Z_OK, Z_STREAM_END, Z_BUF_ERROR]
    let n = w.outBuf.len - int(w.zs.avail_out)
    doAssert w.f.writeBytes(w.outBuf, 0, n) == n
    if flush == Z_FINISH:
      if rc == Z_STREAM_END:
        break
    elif w.zs.avail_in == 0 and w.zs.avail_out != 0:
      break

proc write(w: var GzWriter, data: openArray[byte]) =
  if data.len == 0:
    return
  w.crc = crc32(w.crc, cast[ptr uint8](unsafeAddr data[0]), cuint(data.len))
  w.size += uint32(data.len and 0xffff_ffff)
  w.deflateSome(data, Z_NO_FLUSH)

proc close(w: var GzWriter) =
  w.deflateSome([], Z_FINISH)
  discard deflateEnd(w.zs)
  var tail: array[8, byte]
  for i in 0 .. 3:
    tail[i] = byte((uint32(w.crc) shr (8 * i)) and 0xff)
    tail[4 + i] = byte((w.size shr (8 * i)) and 0xff)
  doAssert w.f.writeBytes(tail, 0, 8) == 8
  w.f.close()

proc entry(w: var GzWriter, path: string, dir: bool, size: int) =
  ## A header from `lgxcorpus`'s builder, with the size set.
  var r = raw(path, dir, newSeq[byte](0))
  var h = header(r)
  let s = toOct(size, 11)
  for i, c in s:
    h[124 + i] = byte(c)
  for i in 148 ..< 156:
    h[i] = byte(' ')
  var sum = 0
  for x in h:
    sum += int(x)
  let cs = toOct(sum, 6)
  for i, c in cs:
    h[148 + i] = byte(c)
  h[154] = 0
  h[155] = byte(' ')
  w.write(h)

proc pad(w: var GzWriter, size: int) =
  let n = (512 - size mod 512) mod 512
  if n > 0:
    w.write(newSeq[byte](n))

proc writeArchive(path: string, total: int) =
  ## A package of one variant whose data files hold `total` bytes in all, written as a stream.
  let blobs = total div BlobBytes
  var v = manifestValue()
  let vs = v.lookup("variants").get
  vs.items.setLen(1)
  let arts = vs.items[0].lookup("artifacts").get
  for i in 0 ..< blobs:
    arts.items.add(
      cborMap(
        (cbor("id"), cbor("blob-" & align($i, 3, '0'))),
        (cbor("kind"), cbor("data")),
        (cbor("path"), cbor("blob/" & align($i, 3, '0'))),
        (
          cbor("hash"),
          cbor(blobDigest(uint64(i + 1) * 0x9e3779b97f4a7c15'u64, BlobBytes)),
        ),
      )
    )
  let (mc, ms) = signed(v)
  var w: GzWriter
  w.open(path)
  w.entry(ManifestCborPath, false, mc.len)
  w.write(mc)
  w.pad(mc.len)
  w.entry(ManifestCosePath, false, ms.len)
  w.write(ms)
  w.pad(ms.len)
  w.entry("variants", true, 0)
  w.entry("variants/linux-x86_64", true, 0)
  var files: seq[(string, int, int)] # path, size, blob index (-1: a fixed file)
  for (p, d) in linuxFiles:
    files.add((p, d.len, -1))
  for i in 0 ..< blobs:
    files.add(("blob/" & align($i, 3, '0'), BlobBytes, i))
  var dirs: seq[string]
  for (p, _, _) in files:
    let segs = p.split('/')
    for k in 1 ..< segs.len:
      let d = segs[0 ..< k].join("/")
      if d notin dirs:
        dirs.add(d)
  var entries: seq[(string, bool, int, int)]
  for d in dirs:
    entries.add(("variants/linux-x86_64/" & d, true, 0, -2))
  for (p, size, blob) in files:
    entries.add(("variants/linux-x86_64/" & p, false, size, blob))
  entries.sort(
    proc(a, b: (string, bool, int, int)): int =
      cmp(a[0], b[0])
  )
  var buf = newSeq[byte](MiB)
  for (p, dir, size, blob) in entries:
    w.entry(p, dir, size)
    if dir:
      continue
    if blob < 0:
      for (fp, d) in linuxFiles:
        if "variants/linux-x86_64/" & fp == p:
          w.write(d)
    else:
      var c = Content(state: uint64(blob + 1) * 0x9e3779b97f4a7c15'u64)
      for _ in 0 ..< size div MiB:
        c.fill(buf)
        w.write(buf)
    w.pad(size)
  w.write(newSeq[byte](1024))
  w.close()

proc peak(mode, path: string): int64 =
  ## The peak resident size of one inspection of `path` in a child.
  let (output, code) =
    execCmdEx(quoteShellCommand([getAppFilename(), "--peak-child", mode, path]))
  checkpoint output
  doAssert code == 0, output
  for line in output.splitLines:
    if line.startsWith("peak "):
      return parseBiggestInt(line[5 .. ^1])
  raiseAssert "no peak in " & output

# Suites -----------------------------------------------------------------------------------

suite "pkg.lgx streaming: one inspection's peak does not grow with the archive (step 5-5-2b)":
  let dir = getTempDir() / "lcn-test-lgx-peak-" & $getCurrentProcessId()
  createDir(dir)

  test "[IMPL-DECISION G446] the peaks at 64 MiB and 256 MiB differ by at most 8 MiB; the in-memory reader's passes the ceiling":
    when defined(asan) or defined(tsan) or defined(msan) or not defined(posix):
      skip() # shadow memory dominates the figure under the sanitizers
    else:
      let small = dir / "64.lgx"
      let large = dir / "256.lgx"
      writeArchive(small, 64 * MiB)
      writeArchive(large, 256 * MiB)
      check getFileSize(large) > 256 * MiB # it did not compress
      let p64 = peak("stream", small)
      let p256 = peak("stream", large)
      let control = peak("oracle", small)
      let figures =
        "streaming 64 MiB: " & $(p64 div 1024) & " KiB, 256 MiB: " & $(p256 div 1024) &
        " KiB; oracle 64 MiB: " & $(control div 1024) & " KiB"
      checkpoint figures
      echo "    ", figures # a measurement: the figures go to the log on every platform
      check abs(p256 - p64) <= Slope
      check p64 < Ceiling and p256 < Ceiling
      check control > Ceiling
      if getEnv("LCN_LGX_PEAK_GIB") == "1":
        # The largest archive the default 1 GiB compressed-size limit admits: one blob less.
        let gib = dir / "1008.lgx"
        writeArchive(gib, 1024 * MiB - BlobBytes)
        echo "    streaming, an archive of ",
          getFileSize(gib), " bytes: ", peak("stream", gib) div 1024, " KiB"
        echo "    oracle 256 MiB: ", peak("oracle", large) div 1024, " KiB"
        removeFile(gib)

  removeDir(dir)
