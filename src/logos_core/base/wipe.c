/* Erasure that the compiler cannot remove (src/logos_core/base/wipe.nim;
 * INTERFACE l.381; Tier 4b step 4b-3b, DECISIONS G276) [IMPL]. `memset`, and
 * so Nim's `zeroMem`, may be elided when the buffer is not read again before
 * it is freed. */
#if defined(__APPLE__)
#define __STDC_WANT_LIB_EXT1__ 1
#endif
#include <stddef.h>
#include <string.h>
#if defined(_WIN32)
#include <windows.h>
#endif
#if defined(__has_feature)
#if __has_feature(memory_sanitizer)
#include <sanitizer/msan_interface.h>
#define LCN_ZEROED(p, n) __msan_unpoison((p), (n))
#endif
#endif
#ifndef LCN_ZEROED
#define LCN_ZEROED(p, n) ((void)0)
#endif

void lcn_secure_zero(void *p, size_t n) {
  if (p == NULL || n == 0)
    return;
#if defined(_WIN32)
  SecureZeroMemory(p, n);
#elif defined(__APPLE__)
  memset_s(p, n, 0, n);
#elif (defined(__GLIBC__) && !defined(__ANDROID__)) || defined(__FreeBSD__) || \
    defined(__OpenBSD__)
  explicit_bzero(p, n);
  /* MemorySanitizer intercepts memset and bzero but not explicit_bzero (clang
   * 21): the bytes it zeroed would still read as uninitialized where the
   * allocation left them so (CI on eed9d58, test_wipe's W-1). */
  LCN_ZEROED(p, n);
#else
  volatile unsigned char *q = (volatile unsigned char *)p;
  while (n--)
    *q++ = 0;
#endif
}
