## D28, I99: the only module that imports the pinned BoringSSL binding
## (nim-boringssl 0.0.14). Each test suite and program that imports it compiles
## all of BoringSSL, so it is imported only under `transport/tls/`, and no module
## outside that tree imports `tls` except the TLS programs and their one suite.

{.push raises: [].}

import boringssl

export boringssl

# BoringSSL is C++. Nim links a mixed C/C++ build through the C++ driver, which
# brings the C++ runtime in, unless the configuration pins the linker: nixpkgs'
# Nim sets `gcc.linkerexe = $CC`, so on Linux the C driver links and the runtime
# must be named. macOS builds link without it. Nim's `linux` includes Android,
# whose NDK has only libc++; it is linked statically, so a binary needs no
# libc++_shared.so beside it (DECISIONS I44, I46).
when defined(android):
  {.passl: "-lc++_static -lc++abi".}
elif defined(linux):
  {.passl: "-lstdc++".}

# macOS sanitizer builds compile with Xcode's clang (`config.nims`), but the Nix shell's SDKROOT
# is nixpkgs' apple-sdk, which has no libc++ headers, and that clang links no C++ runtime by
# itself. Only builds that compile BoringSSL's C++ need the Xcode SDK and libc++ [IMPL].
when defined(macosx) and (defined(asan) or defined(tsan)):
  const xcodeSdk =
    staticExec("env -u DEVELOPER_DIR -u SDKROOT /usr/bin/xcrun --show-sdk-path")
  {.passc: "-isysroot " & xcodeSdk.}
  {.passl: "-isysroot " & xcodeSdk & " -lc++".}

const
  recordBuffersErased* =
    when declared(boringsslZeroRecordBuffers): boringsslZeroRecordBuffers else: false
    ## [DECISIONS G327] Whether this build's BoringSSL zeroes its TLS record
    ## buffers before freeing them: nim-boringssl's BORINGSSL_ZERO_RECORD_BUFFERS
    ## (0.0.16 on), which `config.nims` turns on. False for a build without it,
    ## or with a binding that does not declare it.
  KuDigitalSignature* = 0x0080'u32 ## `KU_DIGITAL_SIGNATURE` (not in the binding)
  MbstringAsc* = 0x1001.cint ## `MBSTRING_ASC` (not in the binding)
  TlsextNametypeHostName* = 0.cint ## `TLSEXT_NAMETYPE_host_name`
  AlertBadCertificate* = 42'u8
  AlertInternalError* = 80'u8

proc sslErrors*(): string =
  ## The thread's queued BoringSSL errors as text, oldest first; the queue is
  ## emptied.
  result = ""
  while true:
    let e = ERR_get_error()
    if e == 0:
      break
    var buf: array[256, char]
    discard ERR_error_string_n(e, cast[cstring](addr buf[0]), csize_t(buf.len))
    if result.len > 0:
      result.add("; ")
    result.add($cast[cstring](addr buf[0]))

proc copyBytes*(p: ptr uint8, n: int): seq[byte] =
  ## `n` bytes at `p` as a new sequence.
  result = newSeq[byte](n)
  if n > 0:
    copyMem(addr result[0], p, n)

{.pop.}
