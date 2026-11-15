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
#else
  volatile unsigned char *q = (volatile unsigned char *)p;
  while (n--)
    *q++ = 0;
#endif
}
