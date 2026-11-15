/* Free scanner for the erasure tests (src/logos_core/base/wipeaudit.nim; Tier
 * 4b step 4b-3b plan §4.1; DECISIONS I92) [IMPL]. Test support: compiled only
 * under -d:lcnWipeAudit, which only test builds set.
 *
 * The audit build renames every `free` and `realloc` in the C it compiles to
 * the functions below (-Dfree=lcn_wipe_free -Drealloc=lcn_wipe_realloc), so
 * with -d:useMalloc the Nim heap releases through here. Once armed with
 * patterns, each block is searched for them before it is released; a hit
 * records a backtrace. `realloc` is malloc, copy, scan, free, so growth is
 * scanned too. One registry serves every image: the shim in a dlopened kit
 * finds the executable's with dlsym(RTLD_DEFAULT) when it loads.
 *
 * Not on Windows: the scanner stays off there (`lcn_wipe_supported`). */
#undef free
#undef realloc

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#if !defined(_WIN32)
#define LCN_WIPE_SCAN 1
#include <dlfcn.h>
#include <execinfo.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <malloc/malloc.h>
#define lcn_block_size(p) malloc_size(p)
#else
#include <malloc.h>
#define lcn_block_size(p) malloc_usable_size(p)
#endif
#endif

#if defined(__has_feature)
#if __has_feature(memory_sanitizer)
#include <sanitizer/msan_interface.h>
#define LCN_UNPOISON(p, n) __msan_unpoison((p), (n))
#endif
#endif
#ifndef LCN_UNPOISON
#define LCN_UNPOISON(p, n) ((void)0)
#endif

#define LCN_WIPE_PATTERNS 8
#define LCN_WIPE_PATTERN_MAX 64
#define LCN_WIPE_TRACES 16
#define LCN_WIPE_DEPTH 32

typedef struct {
  int armed;
  int count;
  size_t len[LCN_WIPE_PATTERNS];
  unsigned char pattern[LCN_WIPE_PATTERNS][LCN_WIPE_PATTERN_MAX];
  long hits;
  int traces;
  int traceLen[LCN_WIPE_TRACES];
  int tracePattern[LCN_WIPE_TRACES];
  size_t traceBlock[LCN_WIPE_TRACES];
  void *trace[LCN_WIPE_TRACES][LCN_WIPE_DEPTH];
} LcnWipeRegistry;

__attribute__((visibility("default"))) LcnWipeRegistry lcn_wipe_registry;

#if defined(LCN_WIPE_SCAN)

static LcnWipeRegistry *lcn_registry_ptr = NULL;
static __thread int lcn_in_scan = 0;

/* Run when the image loads: the executable's registry when it exports one,
 * this image's otherwise. Frees before this runs are not scanned. */
__attribute__((constructor)) static void lcn_wipe_attach(void) {
  LcnWipeRegistry *r =
      (LcnWipeRegistry *)dlsym(RTLD_DEFAULT, "lcn_wipe_registry");
  if (r == NULL)
    r = &lcn_wipe_registry;
  __atomic_store_n(&lcn_registry_ptr, r, __ATOMIC_RELEASE);
}

static LcnWipeRegistry *lcn_armed_registry(void) {
  LcnWipeRegistry *r = __atomic_load_n(&lcn_registry_ptr, __ATOMIC_ACQUIRE);
  if (r == NULL || !__atomic_load_n(&r->armed, __ATOMIC_ACQUIRE))
    return NULL;
  return r;
}

static int lcn_find(const unsigned char *b, size_t n, const unsigned char *pat,
                    size_t m) {
  if (m == 0 || n < m)
    return 0;
  const unsigned char *end = b + (n - m) + 1;
  const unsigned char *at = b;
  while (at < end) {
    at = memchr(at, pat[0], (size_t)(end - at));
    if (at == NULL)
      return 0;
    if (memcmp(at, pat, m) == 0)
      return 1;
    at++;
  }
  return 0;
}

/* Patterns found in `n` bytes at `p`; a hit records a backtrace. */
static int lcn_scan(LcnWipeRegistry *r, const void *p, size_t n) {
  int found = 0;
  LCN_UNPOISON(p, n);
  for (int i = 0; i < r->count; i++) {
    if (lcn_find((const unsigned char *)p, n, r->pattern[i], r->len[i])) {
      found++;
      __atomic_add_fetch(&r->hits, 1, __ATOMIC_RELAXED);
      int slot = __atomic_fetch_add(&r->traces, 1, __ATOMIC_RELAXED);
      if (slot < LCN_WIPE_TRACES) {
        r->tracePattern[slot] = i;
        r->traceBlock[slot] = n;
        r->traceLen[slot] = backtrace(r->trace[slot], LCN_WIPE_DEPTH);
      }
    }
  }
  return found;
}

static void lcn_scan_block(void *p) {
  LcnWipeRegistry *r = lcn_armed_registry();
  if (r == NULL || p == NULL || lcn_in_scan)
    return;
  lcn_in_scan = 1;
  lcn_scan(r, p, lcn_block_size(p));
  lcn_in_scan = 0;
}

void lcn_wipe_free(void *p) {
  lcn_scan_block(p);
  free(p);
}

void *lcn_wipe_realloc(void *p, size_t n) {
  if (p == NULL || n == 0 || lcn_armed_registry() == NULL)
    return realloc(p, n);
  void *q = malloc(n);
  if (q == NULL)
    return NULL;
  size_t old = lcn_block_size(p);
  memcpy(q, p, old < n ? old : n);
  lcn_scan_block(p);
  free(p);
  return q;
}

int lcn_wipe_supported(void) { return 1; }

void lcn_wipe_arm(const unsigned char *patterns, const size_t *lens,
                  int count) {
  LcnWipeRegistry *r = __atomic_load_n(&lcn_registry_ptr, __ATOMIC_ACQUIRE);
  if (r == NULL)
    return;
  __atomic_store_n(&r->armed, 0, __ATOMIC_RELEASE);
  if (count > LCN_WIPE_PATTERNS)
    count = LCN_WIPE_PATTERNS;
  size_t at = 0;
  for (int i = 0; i < count; i++) {
    size_t m = lens[i] > LCN_WIPE_PATTERN_MAX ? LCN_WIPE_PATTERN_MAX : lens[i];
    memcpy(r->pattern[i], patterns + at, m);
    r->len[i] = m;
    at += lens[i];
  }
  r->count = count;
  __atomic_store_n(&r->hits, 0, __ATOMIC_RELAXED);
  __atomic_store_n(&r->traces, 0, __ATOMIC_RELAXED);
  /* glibc loads its unwinder on the first backtrace: not inside a free. */
  void *warm[2];
  (void)backtrace(warm, 2);
  __atomic_store_n(&r->armed, 1, __ATOMIC_RELEASE);
}

void lcn_wipe_disarm(void) {
  LcnWipeRegistry *r = __atomic_load_n(&lcn_registry_ptr, __ATOMIC_ACQUIRE);
  if (r != NULL)
    __atomic_store_n(&r->armed, 0, __ATOMIC_RELEASE);
}

long lcn_wipe_hits(void) {
  LcnWipeRegistry *r = __atomic_load_n(&lcn_registry_ptr, __ATOMIC_ACQUIRE);
  return r == NULL ? 0 : __atomic_load_n(&r->hits, __ATOMIC_RELAXED);
}

/* Patterns found in a live region: for buffers a test reads before release. */
int lcn_wipe_scan(const void *p, size_t n) {
  LcnWipeRegistry *r = __atomic_load_n(&lcn_registry_ptr, __ATOMIC_ACQUIRE);
  if (r == NULL || p == NULL)
    return 0;
  int found = 0;
  for (int i = 0; i < r->count; i++)
    found += lcn_find((const unsigned char *)p, n, r->pattern[i], r->len[i]);
  return found;
}

static void lcn_put(int fd, const char *s) {
  ssize_t ignored = write(fd, s, strlen(s));
  (void)ignored;
}

void lcn_wipe_report(int fd) {
  LcnWipeRegistry *r = __atomic_load_n(&lcn_registry_ptr, __ATOMIC_ACQUIRE);
  if (r == NULL)
    return;
  int n = __atomic_load_n(&r->traces, __ATOMIC_RELAXED);
  if (n > LCN_WIPE_TRACES)
    n = LCN_WIPE_TRACES;
  for (int i = 0; i < n; i++) {
    char line[96];
    char *at = line;
    const char *head = "wipe audit: pattern ";
    memcpy(at, head, strlen(head));
    at += strlen(head);
    *at++ = (char)('0' + r->tracePattern[i] % 10);
    const char *mid = " in a released block of ";
    memcpy(at, mid, strlen(mid));
    at += strlen(mid);
    char digits[24];
    int d = 0;
    size_t v = r->traceBlock[i];
    do {
      digits[d++] = (char)('0' + v % 10);
      v /= 10;
    } while (v != 0 && d < (int)sizeof digits);
    while (d > 0)
      *at++ = digits[--d];
    const char *tail = " bytes\n";
    memcpy(at, tail, strlen(tail) + 1);
    lcn_put(fd, line);
    backtrace_symbols_fd(r->trace[i], r->traceLen[i], fd);
  }
}

#else /* _WIN32: the scanner is off. */

void lcn_wipe_free(void *p) { free(p); }
void *lcn_wipe_realloc(void *p, size_t n) { return realloc(p, n); }
int lcn_wipe_supported(void) { return 0; }
void lcn_wipe_arm(const unsigned char *patterns, const size_t *lens,
                  int count) {
  (void)patterns;
  (void)lens;
  (void)count;
}
void lcn_wipe_disarm(void) {}
long lcn_wipe_hits(void) { return 0; }
int lcn_wipe_scan(const void *p, size_t n) {
  (void)p;
  (void)n;
  return 0;
}
void lcn_wipe_report(int fd) { (void)fd; }

#endif
