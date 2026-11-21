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

/* [DECISIONS G437] Two shapes a destroyModule meets: one callback a foreign
 * thread posts a little later (a thread the module joins), and a stream that
 * posts until the module stops it. */

#include <stdatomic.h>
#ifdef _WIN32
#include <windows.h>
static void lcn_foreign_sleep_us(long us) { Sleep((DWORD)((us + 999) / 1000)); }
#else
#include <time.h>
static void lcn_foreign_sleep_us(long us) {
  struct timespec ts;
  ts.tv_sec = us / 1000000;
  ts.tv_nsec = (us % 1000000) * 1000;
  nanosleep(&ts, NULL);
}
#endif

typedef struct {
  pthread_t id;
  void *poster;
  void (*fn)(void *);
  void *payload;
  int delay_ms;
} lcn_foreign_later;

static void *lcn_foreign_later_run(void *arg) {
  lcn_foreign_later *job = (lcn_foreign_later *)arg;
  lcn_foreign_sleep_us((long)job->delay_ms * 1000);
  lcn_kit_post(job->poster, job->fn, job->payload);
  return NULL;
}

/* One post of `fn(payload)` from a new thread, `delay_ms` from now. Returns
 * the job for lcn_foreign_later_join, or NULL when the thread did not start. */
void *lcn_foreign_post_later(void *poster, void (*fn)(void *), void *payload,
                             int delay_ms) {
  lcn_foreign_later *job = malloc(sizeof(lcn_foreign_later));
  if (job == NULL) {
    return NULL;
  }
  job->poster = poster;
  job->fn = fn;
  job->payload = payload;
  job->delay_ms = delay_ms;
  if (pthread_create(&job->id, NULL, lcn_foreign_later_run, job) != 0) {
    free(job);
    return NULL;
  }
  return job;
}

void lcn_foreign_later_join(void *later) {
  lcn_foreign_later *job = (lcn_foreign_later *)later;
  pthread_join(job->id, NULL);
  free(job);
}

typedef struct {
  pthread_t id;
  void *poster;
  void (*fn)(void *);
  void *payload;
  atomic_int stop;
  long posted;
} lcn_foreign_stream;

static void *lcn_foreign_stream_run(void *arg) {
  lcn_foreign_stream *s = (lcn_foreign_stream *)arg;
  while (!atomic_load(&s->stop)) {
    lcn_kit_post(s->poster, s->fn, s->payload);
    s->posted++;
    lcn_foreign_sleep_us(200); /* keeps the module's queue short */
  }
  return NULL;
}

/* A thread that posts `fn(payload)` every 0.2 ms until stopped. Returns the
 * stream for lcn_foreign_stream_stop, or NULL when the thread did not start. */
void *lcn_foreign_stream_start(void *poster, void (*fn)(void *), void *payload) {
  lcn_foreign_stream *s = malloc(sizeof(lcn_foreign_stream));
  if (s == NULL) {
    return NULL;
  }
  s->poster = poster;
  s->fn = fn;
  s->payload = payload;
  atomic_init(&s->stop, 0);
  s->posted = 0;
  if (pthread_create(&s->id, NULL, lcn_foreign_stream_run, s) != 0) {
    free(s);
    return NULL;
  }
  return s;
}

/* Stops the stream and joins its thread; returns how many it posted. */
long lcn_foreign_stream_stop(void *stream) {
  lcn_foreign_stream *s = (lcn_foreign_stream *)stream;
  atomic_store(&s->stop, 1);
  pthread_join(s->id, NULL);
  long posted = s->posted;
  free(s);
  return posted;
}
