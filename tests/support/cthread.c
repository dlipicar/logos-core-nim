/* Runs a function on a thread the Nim runtime did not start, and waits for it
 * to end (tests of `base/perthread`). Returns 0 when the thread ran. */

typedef void (*lcn_test_fn)(void);

#if defined(_WIN32)
#include <windows.h>

static DWORD WINAPI lcn_test_thread_main(LPVOID fn) {
  ((lcn_test_fn)fn)();
  return 0;
}

int lcn_test_run_c_thread(lcn_test_fn fn) {
  HANDLE t = CreateThread(NULL, 0, lcn_test_thread_main, (LPVOID)fn, 0, NULL);
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

int lcn_test_run_c_thread(lcn_test_fn fn) {
  pthread_t t;
  if (pthread_create(&t, NULL, lcn_test_thread_main, (void *)fn) != 0) return -1;
  return pthread_join(t, NULL) == 0 ? 0 : -1;
}
#endif
