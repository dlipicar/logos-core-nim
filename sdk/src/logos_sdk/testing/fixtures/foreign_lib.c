/* A stand-in for a Rust staticlib linked into a confined module library
 * (DECISIONS G335; N-3's logos-blockchain-c): threads the Nim runtime never
 * saw, which call back into the module through lcn_kit_post. */

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>

void lcn_kit_post(void *poster, void (*fn)(void *), void *payload);

typedef struct {
  void *poster;
  void (*fn)(void *);
  int count;
  int first;
} lcn_foreign_job;

static void *lcn_foreign_run(void *arg) {
  lcn_foreign_job *job = (lcn_foreign_job *)arg;
  for (int i = 0; i < job->count; i++) {
    lcn_kit_post(job->poster, job->fn, (void *)(intptr_t)(job->first + i));
  }
  return NULL;
}

/* Starts `threads` threads that each post `count` callbacks, numbered from 0,
 * and joins them. Returns 0, or -1 when a thread could not start. */
int lcn_foreign_post(void *poster, void (*fn)(void *), int threads, int count) {
  if (threads <= 0 || threads > 64) {
    return -1;
  }
  pthread_t ids[64];
  lcn_foreign_job jobs[64];
  int started = 0;
  int rc = 0;
  for (int t = 0; t < threads; t++) {
    jobs[t].poster = poster;
    jobs[t].fn = fn;
    jobs[t].count = count;
    jobs[t].first = t * count;
    if (pthread_create(&ids[t], NULL, lcn_foreign_run, &jobs[t]) != 0) {
      rc = -1;
      break;
    }
    started++;
  }
  for (int t = 0; t < started; t++) {
    pthread_join(ids[t], NULL);
  }
  return rc;
}
