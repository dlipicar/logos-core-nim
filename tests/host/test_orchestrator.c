/* A consumer-only module written in C, for the orchestration role in
 * tests/test_host_dylib.nim. It is linked into the test and registered with
 * logos_runtime_register_binding as a true static binding (RUNTIME §13.3).
 *
 * Its initialization keeps the Runtime Control binding, then acts by mode:
 * - TOR_PLAIN: returns LOGOS_OK;
 * - TOR_SHUTDOWN: calls shutdown_runtime first (the start is then CANCELLED);
 * - TOR_WAIT_PROBE: calls logos_runtime_wait_for_shutdown on the handle it is
 *   given (Runtime-owned code: NOT_READY);
 * - TOR_AUTOSTART: starts a thread of its own that calls start_module for
 *   meter-1 and sensor-1, as an orchestrator does after its own start.
 * Its destroy waits while the destroy gate is closed, then joins that thread. */

#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#include <time.h>
#endif

#include "../generated/logos_runtime.h"

enum { TOR_PLAIN = 0, TOR_SHUTDOWN = 1, TOR_WAIT_PROBE = 2, TOR_AUTOSTART = 3 };

typedef logos_result_t (*tor_wait_fn)(logos_runtime_t *runtime);

static atomic_int tor_mode;
static atomic_int tor_destroy_gate; /* 1 while closed */
static atomic_int tor_inits, tor_destroys;
static atomic_int tor_init_code = -1;
static atomic_int tor_started[2] = {-1, -1};
static atomic_int tor_thread_done;
/* Calls through its binding not yet past release_response, the test's own
 * included: a module releases every response before its destroy returns. */
static atomic_int tor_calls;
static _Atomic(const logos_runtime_control_binding_t *) tor_rc;
static tor_wait_fn tor_wait;
static logos_runtime_t *tor_handle;
static int tor_thread_live;
#ifdef _WIN32
static HANDLE tor_thread;
#else
static pthread_t tor_thread;
#endif

static void tor_pause(void) {
#ifdef _WIN32
  Sleep(1);
#else
  struct timespec ts = {0, 1000000};
  nanosleep(&ts, NULL);
#endif
}

/* One CBOR text string of fewer than 24 bytes. */
static size_t tor_text(uint8_t *p, const char *s) {
  size_t n = strlen(s);
  p[0] = (uint8_t)(0x60u | n);
  memcpy(p + 1, s, n);
  return n + 1;
}

static logos_error_code_t tor_call(const logos_runtime_control_binding_t *rc,
                                   const char *method, const uint8_t *params,
                                   size_t len) {
  uint8_t *response = NULL;
  size_t response_len = 0;
  atomic_fetch_add(&tor_calls, 1);
  logos_result_t r = rc->vtable->call(rc, method, params, len, &response,
                                      &response_len);
  if (response != NULL) rc->vtable->release_response(rc, response, response_len);
  atomic_fetch_sub(&tor_calls, 1);
  return r.code;
}

/* start_module {"module": m, "instance": i}: deterministic key order. */
static logos_error_code_t tor_start(const logos_runtime_control_binding_t *rc,
                                    const char *module, const char *instance) {
  uint8_t p[64];
  size_t n = 0;
  p[n++] = 0xA2;
  n += tor_text(p + n, "module");
  n += tor_text(p + n, module);
  n += tor_text(p + n, "instance");
  n += tor_text(p + n, instance);
  return tor_call(rc, "start_module", p, n);
}

#ifdef _WIN32
static DWORD WINAPI tor_orchestrate(LPVOID arg) {
#else
static void *tor_orchestrate(void *arg) {
#endif
  const logos_runtime_control_binding_t *rc = arg;
  atomic_store(&tor_started[0], (int)tor_start(rc, "meter_module", "meter-1"));
  atomic_store(&tor_started[1], (int)tor_start(rc, "sensor_module", "sensor-1"));
  atomic_store(&tor_thread_done, 1);
#ifdef _WIN32
  return 0;
#else
  return NULL;
#endif
}

const char *logos_test_orchestrator_MODULE_name(void) { return "test_orchestrator"; }

logos_result_t logos_test_orchestrator_MODULE_init(
    const logos_module_init_input_t *input, logos_module_context_t **out_context) {
  logos_result_t r = {LOGOS_OK, NULL, NULL, 0};
  atomic_fetch_add(&tor_inits, 1);
  atomic_store(&tor_rc, input->runtime_control);
  switch (atomic_load(&tor_mode)) {
  case TOR_SHUTDOWN: {
    const uint8_t empty[1] = {0xA0};
    atomic_store(&tor_init_code,
                 (int)tor_call(input->runtime_control, "shutdown_runtime", empty, 1));
    break;
  }
  case TOR_WAIT_PROBE:
    atomic_store(&tor_init_code, (int)tor_wait(tor_handle).code);
    break;
  case TOR_AUTOSTART:
#ifdef _WIN32
    tor_thread = CreateThread(NULL, 0, tor_orchestrate,
                              (LPVOID)input->runtime_control, 0, NULL);
    tor_thread_live = tor_thread != NULL;
#else
    tor_thread_live = pthread_create(&tor_thread, NULL, tor_orchestrate,
                                     (void *)input->runtime_control) == 0;
#endif
    break;
  default:
    break;
  }
  *out_context = (logos_module_context_t *)calloc(1, 16);
  return r;
}

void logos_test_orchestrator_MODULE_destroy(logos_module_context_t *module) {
  while (atomic_load(&tor_destroy_gate)) tor_pause();
  if (tor_thread_live) {
#ifdef _WIN32
    WaitForSingleObject(tor_thread, INFINITE);
    CloseHandle(tor_thread);
#else
    pthread_join(tor_thread, NULL);
#endif
    tor_thread_live = 0;
  }
  while (atomic_load(&tor_calls) > 0) tor_pause();
  free(module);
  atomic_fetch_add(&tor_destroys, 1);
}

/* For the test. */

void tor_reset(int mode) {
  atomic_store(&tor_mode, mode);
  atomic_store(&tor_destroy_gate, 0);
  atomic_store(&tor_inits, 0);
  atomic_store(&tor_destroys, 0);
  atomic_store(&tor_init_code, -1);
  atomic_store(&tor_started[0], -1);
  atomic_store(&tor_started[1], -1);
  atomic_store(&tor_thread_done, 0);
  atomic_store(&tor_rc, NULL);
}

void tor_set_wait(tor_wait_fn wait, logos_runtime_t *handle) {
  tor_wait = wait;
  tor_handle = handle;
}

void tor_set_destroy_gate(int closed) { atomic_store(&tor_destroy_gate, closed); }
int tor_init_result(void) { return atomic_load(&tor_init_code); }
int tor_inits_seen(void) { return atomic_load(&tor_inits); }
int tor_destroys_seen(void) { return atomic_load(&tor_destroys); }
int tor_autostart_done(void) { return atomic_load(&tor_thread_done); }
int tor_started_code(int i) { return atomic_load(&tor_started[i]); }

/* shutdown_runtime through the latest initialization's binding. */
int tor_shutdown_runtime(void) {
  const uint8_t empty[1] = {0xA0};
  return (int)tor_call(atomic_load(&tor_rc), "shutdown_runtime", empty, 1);
}

/* The module's symbol table, for logos_runtime_register_binding. */
size_t tor_symbols(const char **names, logos_runtime_symbol_address_t *addresses) {
  names[0] = "logos_test_orchestrator_MODULE_name";
  addresses[0] = (logos_runtime_symbol_address_t)logos_test_orchestrator_MODULE_name;
  names[1] = "logos_test_orchestrator_MODULE_init";
  addresses[1] = (logos_runtime_symbol_address_t)logos_test_orchestrator_MODULE_init;
  names[2] = "logos_test_orchestrator_MODULE_destroy";
  addresses[2] = (logos_runtime_symbol_address_t)logos_test_orchestrator_MODULE_destroy;
  return 3;
}
