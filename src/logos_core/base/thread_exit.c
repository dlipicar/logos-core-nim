/* Calls a function when the calling thread exits [IMPL].
 *
 * For threads the Nim runtime did not start: a C host's threads call module
 * code too (INTERFACE §2.8), and Nim runs no handler when they end. The
 * function runs before the thread's thread-local storage is freed, on the same
 * mechanism C++ `thread_local` destructors use: `__cxa_thread_atexit_impl`
 * (glibc, bionic), `_tlv_atexit` (Apple), a fiber-local slot's callback
 * (Windows), or else a POSIX thread-specific key's destructor.
 *
 * Returns 0 when the function is registered.
 */

typedef void (*lcn_thread_exit_fn)(void);

static void lcn_call_exit_fn(void *fn) { ((lcn_thread_exit_fn)fn)(); }

#if defined(_WIN32)
#include <windows.h>

static INIT_ONCE lcn_exit_once = INIT_ONCE_STATIC_INIT;
static DWORD lcn_exit_slot = FLS_OUT_OF_INDEXES;

static VOID WINAPI lcn_on_fls_exit(PVOID fn) {
  if (fn != NULL) lcn_call_exit_fn(fn);
}

static BOOL CALLBACK lcn_alloc_exit_slot(PINIT_ONCE once, PVOID arg, PVOID *ctx) {
  (void)once;
  (void)arg;
  (void)ctx;
  lcn_exit_slot = FlsAlloc(lcn_on_fls_exit);
  return lcn_exit_slot != FLS_OUT_OF_INDEXES;
}

int lcn_on_thread_exit(lcn_thread_exit_fn fn) {
  if (!InitOnceExecuteOnce(&lcn_exit_once, lcn_alloc_exit_slot, NULL, NULL)) return -1;
  return FlsSetValue(lcn_exit_slot, (PVOID)fn) ? 0 : -1;
}

#elif defined(__APPLE__)

extern void _tlv_atexit(void (*fn)(void *), void *arg);

int lcn_on_thread_exit(lcn_thread_exit_fn fn) {
  _tlv_atexit(lcn_call_exit_fn, (void *)fn);
  return 0;
}

#else
#include <pthread.h>

extern int __cxa_thread_atexit_impl(void (*fn)(void *), void *arg, void *dso)
    __attribute__((weak));
extern void *__dso_handle __attribute__((visibility("hidden")));

static pthread_once_t lcn_exit_once = PTHREAD_ONCE_INIT;
static pthread_key_t lcn_exit_key;
static int lcn_have_exit_key;

static void lcn_make_exit_key(void) {
  lcn_have_exit_key = pthread_key_create(&lcn_exit_key, lcn_call_exit_fn) == 0;
}

int lcn_on_thread_exit(lcn_thread_exit_fn fn) {
  if (__cxa_thread_atexit_impl != NULL)
    return __cxa_thread_atexit_impl(lcn_call_exit_fn, (void *)fn, &__dso_handle);
  pthread_once(&lcn_exit_once, lcn_make_exit_key);
  if (!lcn_have_exit_key) return -1;
  return pthread_setspecific(lcn_exit_key, (void *)fn) == 0 ? 0 : -1;
}
#endif
