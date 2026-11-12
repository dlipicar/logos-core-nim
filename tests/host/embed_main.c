/* A host program that knows only logos_runtime.h (RUNTIME §13), linked against
 * liblogos_runtime: it reads a logos-core-nim.app-config.v1 configuration from
 * the file argv[1], then creates, starts, shuts down, waits and destroys.
 * Prints "ok" and exits 0 when every call returned LOGOS_OK. With argv[2]
 * "crash" it ends the process with _Exit(3) as soon as start returned OK, as a
 * crash would: no shutdown, no exit handlers. Built by
 * tests/support/hostbuild.nim as strict C11 with warnings as errors. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "logos_runtime.h"

static int failed(const char *what, logos_result_t r) {
  if (r.code == LOGOS_OK) return 0;
  fprintf(stderr, "%s: %d %s\n", what, (int)r.code,
          r.message != NULL ? r.message : "");
  return 1;
}

int main(int argc, char **argv) {
  if (argc != 2 && !(argc == 3 && strcmp(argv[2], "crash") == 0)) return 2;
  FILE *f = fopen(argv[1], "rb");
  if (f == NULL) return 2;
  uint8_t buf[65536];
  size_t len = fread(buf, 1, sizeof buf, f);
  fclose(f);

  logos_runtime_config_t config = {LOGOS_RUNTIME_HOST_ABI_VERSION, sizeof config,
                                   LCN_RUNTIME_CONFIG_FORMAT_APP_V1, buf, len};
  logos_runtime_t *runtime = NULL;
  if (failed("create", logos_runtime_create(&config, &runtime))) return 1;
  if (failed("start", logos_runtime_start(runtime))) return 1;
  if (argc == 3) _Exit(3);
  if (failed("request_shutdown", logos_runtime_request_shutdown(runtime))) return 1;
  if (failed("wait_for_shutdown", logos_runtime_wait_for_shutdown(runtime))) return 1;
  if (failed("destroy", logos_runtime_destroy(runtime))) return 1;
  puts("ok");
  return 0;
}
