/* The Module Host spawn's prototype (hostspawn.c; DECISIONS G264, G492, I147).

   hostspawn.c includes it, so the definition is checked against it, and
   hostsup.nim's one declaration takes it with `header:`, so every Nim call is
   compiled against this prototype instead of one Nim writes for itself. A call
   with the wrong arguments then fails to compile. */

#ifndef LCN_HOSTSPAWN_H
#define LCN_HOSTSPAWN_H

/* Starts `path` with `argv` and `envp`: `carrier` on fd 3, and `listener`,
   `lock` and `system` on fds 4, 5 and 6 when >= 0. On success it returns 0
   and writes the child's pid, also its process group, to `*pid_out`. On
   failure it returns a negated errno. */
int lcn_host_spawn(const char *path, char *const argv[], char *const envp[],
                   int carrier, int listener, int lock, int system,
                   int *pid_out);

#endif
