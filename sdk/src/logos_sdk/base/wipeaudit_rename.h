/* Renames `free` and `realloc` for the audit build (wipeaudit.nim, wipeaudit.c;
 * DECISIONS I92) [IMPL]: force-included in everything that build compiles.
 *
 * C++ needs more than a macro. libstdc++'s <cstdlib> undefines `free` and
 * `realloc`, then names `::free`, which <stdlib.h> declared under the renamed
 * spelling. So <cstdlib> comes first, with the real names, and the renamed
 * functions are declared here, as glibc declares the originals. g++ predefines
 * _GNU_SOURCE, so the early include does not change what later headers see.
 *
 * C++ gets the variants that zero and release without scanning (DECISIONS
 * G276; re-pin P4 §4.2). The only C++ an audit build compiles is BoringSSL's
 * (nim-boringssl 0.0.16 builds C++ and assembly, no C), whose record buffers
 * keep the plaintext they carried, since the library no longer zeroes them
 * (G327). The scan covers the carrier's copies, which are C. */
#ifndef LCN_WIPEAUDIT_RENAME_H
#define LCN_WIPEAUDIT_RENAME_H

#ifdef __cplusplus
#include <cstddef>
#include <cstdlib>

extern "C" {
void lcn_wipe_free_cxx(void *p) noexcept;
void *lcn_wipe_realloc_cxx(void *p, std::size_t n) noexcept;
}

namespace std {
using ::lcn_wipe_free_cxx;
using ::lcn_wipe_realloc_cxx;
} // namespace std

#define free lcn_wipe_free_cxx
#define realloc lcn_wipe_realloc_cxx
#else
#define free lcn_wipe_free
#define realloc lcn_wipe_realloc
#endif

#endif
