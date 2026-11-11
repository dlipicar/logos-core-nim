# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

switch("styleCheck", "usages")
switch("styleCheck", "error")
switch("hint", "XDeclaredButNotUsed:off")

# Sanitizer builds [IMPL]: -d:asan (AddressSanitizer with UndefinedBehaviorSanitizer),
# -d:tsan (ThreadSanitizer), -d:msan (MemorySanitizer, clang on Linux only). Nim's allocator
# gives way to malloc so the sanitizer sees every allocation, the first finding aborts, and
# frame pointers and debug info keep the reports readable.
when defined(asan) or defined(tsan) or defined(msan):
  let sanitizer =
    if defined(asan):
      "-fsanitize=address,undefined"
    elif defined(tsan):
      "-fsanitize=thread"
    else:
      "-fsanitize=memory -fsanitize-memory-track-origins=2"
  let flags = sanitizer & " -fno-sanitize-recover=all -fno-omit-frame-pointer -O1"
  let kind =
    if defined(asan):
      "asan"
    elif defined(tsan):
      "tsan"
    else:
      "msan"
  # Objects built for another sanitizer or none are not reused. A `--nimcache` on the
  # command line (the test libraries' builds) wins, but `sanitizers.c` below is placed
  # here before it does, so the directory must exist either way.
  let cache = thisDir() & "/build/nimcache/" & projectName() & "_" & kind
  mkDir(cache)
  switch("nimcache", cache)
  switch("define", "useMalloc")
  switch("debugger", "native")
  switch("compile", thisDir() & "/tests/support/sanitizers.c")
  switch("passC", flags)
  switch("passL", flags)
  when defined(msan):
    switch("cc", "clang")
    # MemorySanitizer cannot see what assembly writes: BoringSSL's portable C instead
    # (BLAKE3 too, in crypto/blake3.nim).
    switch("define", "BORINGSSL_USE_ASM=false")
  when defined(macosx):
    # The Xcode toolchain's runtimes match the OS; nixpkgs' clang 21 sanitizer runtimes
    # hang or crash at startup on macOS 27. A Nix shell's DEVELOPER_DIR points `xcrun`
    # and PATH its own xcrun, so the system one runs without it.
    let (appleClang, code) = gorgeEx("env -u DEVELOPER_DIR /usr/bin/xcrun --find clang")
    if code != 0:
      raise newException(
        OSError, "sanitizer builds on macOS need Xcode or its command line tools"
      )
    switch("cc", "clang")
    switch("clang.exe", appleClang)
    switch("clang.linkerexe", appleClang)
