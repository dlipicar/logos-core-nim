/* liblogos_runtime driven from C, for tests/test_host_dylib.nim (RUNTIME §13).
 *
 * hh_load resolves the six functions with dlopen and dlsym (LoadLibrary on
 * Windows). Every hh_ call copies the result, message and detail into an
 * hh_result_t before the calling thread makes another call (§13.4). Waits and
 * the diagnostics check run on threads that no Nim runtime started. */

#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#include <pthread.h>
#endif

#include "../generated/logos_runtime.h"

typedef struct {
  int32_t code;
  int32_t has_message;
  char message[LOGOS_ERROR_MESSAGE_MAX_LEN + 1];
  size_t detail_len;
  uint8_t detail[LOGOS_ERROR_DETAIL_MAX_LEN];
} hh_result_t;

typedef logos_result_t (*hh_create_fn)(const logos_runtime_config_t *, logos_runtime_t **);
typedef logos_result_t (*hh_register_fn)(logos_runtime_t *,
                                         const logos_runtime_native_binding_t *);
typedef logos_result_t (*hh_handle_fn)(logos_runtime_t *);

static struct {
  hh_create_fn create;
  hh_register_fn register_binding;
  hh_handle_fn start, request_shutdown, wait_for_shutdown, destroy;
} api;

static void *hh_open(const char *path) {
#ifdef _WIN32
  return (void *)LoadLibraryA(path);
#else
  return dlopen(path, RTLD_NOW | RTLD_LOCAL);
#endif
}

static void *hh_symbol(void *lib, const char *name) {
#ifdef _WIN32
  return (void *)GetProcAddress((HMODULE)lib, name);
#else
  return dlsym(lib, name);
#endif
}

/* 0 once all six are resolved. */
int hh_load(const char *path) {
  void *lib = hh_open(path);
  if (lib == NULL) return -1;
  api.create = (hh_create_fn)hh_symbol(lib, "logos_runtime_create");
  api.register_binding = (hh_register_fn)hh_symbol(lib, "logos_runtime_register_binding");
  api.start = (hh_handle_fn)hh_symbol(lib, "logos_runtime_start");
  api.request_shutdown = (hh_handle_fn)hh_symbol(lib, "logos_runtime_request_shutdown");
  api.wait_for_shutdown = (hh_handle_fn)hh_symbol(lib, "logos_runtime_wait_for_shutdown");
  api.destroy = (hh_handle_fn)hh_symbol(lib, "logos_runtime_destroy");
  if (!api.create || !api.register_binding || !api.start || !api.request_shutdown ||
      !api.wait_for_shutdown || !api.destroy)
    return -2;
  return 0;
}

hh_handle_fn hh_wait_function(void) { return api.wait_for_shutdown; }

static void hh_keep(logos_result_t r, hh_result_t *out) {
  memset(out, 0, sizeof *out);
  out->code = (int32_t)r.code;
  if (r.message != NULL) {
    out->has_message = 1;
    strncpy(out->message, r.message, LOGOS_ERROR_MESSAGE_MAX_LEN);
  }
  if (r.detail != NULL && r.detail_len <= LOGOS_ERROR_DETAIL_MAX_LEN) {
    out->detail_len = r.detail_len;
    memcpy(out->detail, r.detail, r.detail_len);
  }
}

void hh_create(uint32_t abi_version, const char *format, const uint8_t *bytes,
               size_t len, logos_runtime_t **out, hh_result_t *r) {
  logos_runtime_config_t config = {abi_version, sizeof config, format, bytes, len};
  hh_keep(api.create(&config, out), r);
}

/* The C module linked into this test, as a static binding. */
size_t tor_symbols(const char **names, logos_runtime_symbol_address_t *addresses);

void hh_register_orchestrator(logos_runtime_t *rt, const char *binding_id,
                              hh_result_t *r) {
  const char *names[3];
  logos_runtime_symbol_address_t addresses[3];
  logos_runtime_native_symbol_t symbols[3];
  size_t n = tor_symbols(names, addresses);
  for (size_t i = 0; i < n; i++) {
    symbols[i].name = names[i];
    symbols[i].address = addresses[i];
  }
  logos_runtime_native_binding_t b = {LOGOS_RUNTIME_HOST_ABI_VERSION, sizeof b,
                                      binding_id, symbols, n};
  hh_keep(api.register_binding(rt, &b), r);
  /* The table was copied: this storage may change now (RUN-0749). */
  memset(symbols, 0, sizeof symbols);
}

/* A static binding of addresses dlsym finds in a module library. Returns the
 * number of names it could not resolve; registers nothing then. */
size_t hh_register_library(logos_runtime_t *rt, const char *binding_id,
                           const char *path, const char *const *names, size_t n,
                           hh_result_t *r) {
  void *lib = hh_open(path);
  size_t missing = 0;
  logos_runtime_native_symbol_t *symbols = calloc(n, sizeof *symbols);
  for (size_t i = 0; i < n; i++) {
    void *p = lib != NULL ? hh_symbol(lib, names[i]) : NULL;
    if (p == NULL) missing++;
    symbols[i].name = names[i];
    /* POSIX: a data pointer from dlsym converts to a function pointer. */
    memcpy(&symbols[i].address, &p, sizeof p);
  }
  if (missing == 0) {
    logos_runtime_native_binding_t b = {LOGOS_RUNTIME_HOST_ABI_VERSION, sizeof b,
                                        binding_id, symbols, n};
    hh_keep(api.register_binding(rt, &b), r);
  }
  free(symbols);
  return missing;
}

void hh_start(logos_runtime_t *rt, hh_result_t *r) { hh_keep(api.start(rt), r); }
void hh_request_shutdown(logos_runtime_t *rt, hh_result_t *r) {
  hh_keep(api.request_shutdown(rt), r);
}
void hh_wait_for_shutdown(logos_runtime_t *rt, hh_result_t *r) {
  hh_keep(api.wait_for_shutdown(rt), r);
}
void hh_destroy(logos_runtime_t *rt, hh_result_t *r) { hh_keep(api.destroy(rt), r); }

/* Threads no Nim runtime started --------------------------------------------- */

typedef void *(*hh_thread_fn)(void *);

#ifdef _WIN32
typedef HANDLE hh_thread_t;
typedef struct {
  hh_thread_fn fn;
  void *arg;
} hh_trampoline_t;
static DWORD WINAPI hh_trampoline(LPVOID p) {
  hh_trampoline_t t = *(hh_trampoline_t *)p;
  free(p);
  t.fn(t.arg);
  return 0;
}
static int hh_spawn(hh_thread_t *t, hh_thread_fn fn, void *arg) {
  hh_trampoline_t *p = malloc(sizeof *p);
  p->fn = fn;
  p->arg = arg;
  *t = CreateThread(NULL, 0, hh_trampoline, p, 0, NULL);
  return *t != NULL ? 0 : -1;
}
static void hh_join(hh_thread_t t) {
  WaitForSingleObject(t, INFINITE);
  CloseHandle(t);
}
#else
typedef pthread_t hh_thread_t;
static int hh_spawn(hh_thread_t *t, hh_thread_fn fn, void *arg) {
  return pthread_create(t, NULL, fn, arg);
}
static void hh_join(hh_thread_t t) { pthread_join(t, NULL); }
#endif

static struct {
  hh_thread_t thread;
  logos_runtime_t *rt;
  hh_result_t result;
  atomic_int done;
} waiter;

static void *hh_wait_main(void *arg) {
  (void)arg;
  hh_keep(api.wait_for_shutdown(waiter.rt), &waiter.result);
  atomic_store(&waiter.done, 1);
  return NULL;
}

/* A wait on a new C thread; hh_wait_end joins it and copies its result. */
int hh_wait_begin(logos_runtime_t *rt) {
  waiter.rt = rt;
  atomic_store(&waiter.done, 0);
  return hh_spawn(&waiter.thread, hh_wait_main, NULL);
}

int hh_wait_finished(void) { return atomic_load(&waiter.done); }

void hh_wait_end(hh_result_t *r) {
  hh_join(waiter.thread);
  *r = waiter.result;
}

/* [RUN-0764] On one C thread a result's message stays at its address until
 * that thread's next call, whatever other threads call meanwhile; OK carries
 * none. 0 when every step holds, else the failing step. */

static atomic_int diag_failed;
static const char *diag_other;

static void *hh_diag_other(void *arg) {
  (void)arg;
  logos_result_t r = api.start(NULL);
  if (r.code != LOGOS_ERR_INVALID_PARAMS || r.message == NULL) atomic_store(&diag_failed, 10);
  diag_other = r.message;
  return NULL;
}

static void *hh_diag_main(void *arg) {
  (void)arg;
  logos_runtime_t *out = (logos_runtime_t *)&out;
  logos_result_t r = api.create(NULL, &out);
  if (r.code != LOGOS_ERR_INVALID_PARAMS || out != NULL) {
    atomic_store(&diag_failed, 1);
    return NULL;
  }
  const char *mine = r.message;
  if (mine == NULL || strcmp(mine, "config is null") != 0) {
    atomic_store(&diag_failed, 2);
    return NULL;
  }
  hh_thread_t other;
  if (hh_spawn(&other, hh_diag_other, NULL) != 0) {
    atomic_store(&diag_failed, 3);
    return NULL;
  }
  hh_join(other);
  if (strcmp(mine, "config is null") != 0) atomic_store(&diag_failed, 4);
  else if (diag_other == mine) atomic_store(&diag_failed, 5);
  return NULL;
}

int hh_diagnostics_check(void) {
  atomic_store(&diag_failed, 0);
  hh_thread_t t;
  if (hh_spawn(&t, hh_diag_main, NULL) != 0) return -1;
  hh_join(t);
  return atomic_load(&diag_failed);
}
