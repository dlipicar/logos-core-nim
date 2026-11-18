/* Renames `free` and `realloc` for the audit build (wipeaudit.nim, wipeaudit.c;
 * DECISIONS I92) [IMPL]: force-included in everything that build compiles.
 *
 * C++ needs more than a macro. libstdc++'s <cstdlib> undefines `free` and
 * `realloc`, then names `::free`, which <stdlib.h> declared under the renamed
 * spelling. So <cstdlib> comes first, with the real names, and the renamed
 * functions are declared here, as glibc declares the originals. g++ predefines
 * _GNU_SOURCE, so the early include does not change what later headers see. */
#ifndef LCN_WIPEAUDIT_RENAME_H
#define LCN_WIPEAUDIT_RENAME_H

#ifdef __cplusplus
#include <cstddef>
#include <cstdlib>

extern "C" {
void lcn_wipe_free(void *p) noexcept;
void *lcn_wipe_realloc(void *p, std::size_t n) noexcept;
}

namespace std {
using ::lcn_wipe_free;
using ::lcn_wipe_realloc;
} // namespace std
#endif

#define free lcn_wipe_free
#define realloc lcn_wipe_realloc

#endif
