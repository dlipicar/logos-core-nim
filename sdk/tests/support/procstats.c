/* The process's thread count and resident memory, for test_kit_dylib's
 * 200-cycle case (DECISIONS G439): -1 where neither is known. */

#if defined(__APPLE__)
#include <mach/mach.h>

long lcn_thread_count(void) {
  thread_act_array_t list;
  mach_msg_type_number_t n = 0;
  if (task_threads(mach_task_self(), &list, &n) != KERN_SUCCESS) {
    return -1;
  }
  for (mach_msg_type_number_t i = 0; i < n; i++) {
    mach_port_deallocate(mach_task_self(), list[i]);
  }
  vm_deallocate(mach_task_self(), (vm_address_t)list, n * sizeof(thread_act_t));
  return (long)n;
}

long lcn_resident_bytes(void) {
  struct mach_task_basic_info info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info,
                &count) != KERN_SUCCESS) {
    return -1;
  }
  return (long)info.resident_size;
}

#elif defined(__linux__)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

long lcn_thread_count(void) {
  FILE *f = fopen("/proc/self/status", "r");
  if (f == NULL) {
    return -1;
  }
  char line[256];
  long n = -1;
  while (fgets(line, sizeof line, f) != NULL) {
    if (strncmp(line, "Threads:", 8) == 0) {
      n = strtol(line + 8, NULL, 10);
      break;
    }
  }
  fclose(f);
  return n;
}

long lcn_resident_bytes(void) {
  FILE *f = fopen("/proc/self/statm", "r");
  if (f == NULL) {
    return -1;
  }
  long size = 0, resident = 0;
  int got = fscanf(f, "%ld %ld", &size, &resident);
  fclose(f);
  return got == 2 ? resident * sysconf(_SC_PAGESIZE) : -1;
}

#else
long lcn_thread_count(void) { return -1; }
long lcn_resident_bytes(void) { return -1; }
#endif
