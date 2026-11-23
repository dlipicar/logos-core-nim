/* The fresh threads of logos_sdk/testing/freshthread (DECISIONS G466) [IMPL]:
 * a thread no Nim runtime started runs one call, then reads the probe. */

#include <pthread.h>
#include <signal.h>

typedef void (*lcn_fresh_fn)(void *);
typedef int (*lcn_fresh_probe)(void);

typedef struct {
  lcn_fresh_fn fn;
  void *arg;
  lcn_fresh_probe probe;
  int entered;
} lcn_fresh_job;

static void *lcn_fresh_main(void *p) {
  lcn_fresh_job *j = (lcn_fresh_job *)p;
  j->fn(j->arg);
  j->entered = j->probe();
  return NULL;
}

/* Runs fn(arg) on a new thread, then probe() on it; joins it. 0, or the
 * pthread error that kept the thread from starting or being joined. */
int lcn_fresh_run(lcn_fresh_fn fn, void *arg, lcn_fresh_probe probe,
                  int *entered) {
  lcn_fresh_job j = {fn, arg, probe, -1};
  pthread_attr_t a;
  pthread_t t;
  int rc = pthread_attr_init(&a);
  if (rc != 0)
    return rc;
  /* Nim frames are deep in debug builds: as a Nim thread's default. */
  pthread_attr_setstacksize(&a, (size_t)8 << 20);
  rc = pthread_create(&t, &a, lcn_fresh_main, &j);
  pthread_attr_destroy(&a);
  if (rc != 0)
    return rc;
  rc = pthread_join(t, NULL);
  if (rc != 0)
    return rc;
  *entered = j.entered;
  return 0;
}

/* A child process that must die by a fault or an abort: the default actions,
 * so that neither Nim's handler (which allocates on that thread and hangs,
 * upstream drafts 12 and 190) nor anything else runs. */
void lcn_fresh_default_signals(void) {
  signal(SIGSEGV, SIG_DFL);
  signal(SIGBUS, SIG_DFL);
  signal(SIGABRT, SIG_DFL);
}
