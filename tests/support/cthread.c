/* Runs a function on a thread the Nim runtime did not start, and waits for it
 * to end (tests of `base/perthread`), on the platform's default stack or on
 * exactly `stack` bytes (the generated codecs' depth tests). Returns 0 when the
 * thread ran. */

#include <stddef.h>

typedef void (*lcn_test_fn)(void);

#if defined(_WIN32)
#include <windows.h>

static DWORD WINAPI lcn_test_thread_main(LPVOID fn) {
  ((lcn_test_fn)fn)();
  return 0;
}

int lcn_test_run_c_thread_on(lcn_test_fn fn, size_t stack) {
  HANDLE t = CreateThread(NULL, stack, lcn_test_thread_main, (LPVOID)fn,
                          stack ? STACK_SIZE_PARAM_IS_A_RESERVATION : 0, NULL);
  if (t == NULL) return -1;
  WaitForSingleObject(t, INFINITE);
  CloseHandle(t);
  return 0;
}

#else
#include <pthread.h>

static void *lcn_test_thread_main(void *fn) {
  ((lcn_test_fn)fn)();
  return NULL;
}

int lcn_test_run_c_thread_on(lcn_test_fn fn, size_t stack) {
  pthread_attr_t a;
  pthread_t t;
  if (pthread_attr_init(&a) != 0) return -1;
  int bad = (stack && pthread_attr_setstacksize(&a, stack) != 0) ||
            pthread_create(&t, &a, lcn_test_thread_main, (void *)fn) != 0;
  pthread_attr_destroy(&a);
  if (bad) return -1;
  return pthread_join(t, NULL) == 0 ? 0 : -1;
}
#endif

int lcn_test_run_c_thread(lcn_test_fn fn) { return lcn_test_run_c_thread_on(fn, 0); }
