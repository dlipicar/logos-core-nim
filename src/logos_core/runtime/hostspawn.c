/* The Module Host spawn (Tier 4b step 4b-3; DECISIONS G264, G265; plan §2.3),
   in C so the spawn attributes and file actions have the platform's exact
   layout. posix_spawn only, never fork: ThreadSanitizer does not support fork
   in a threaded process, and the daemon is one.

   The child gets:
   - fd 0 from /dev/null; fds 1 and 2 inherited, so its diagnostics (and a
     sanitizer's reports) reach the daemon's log;
   - fd 3 the carrier, fd 4 the transferred listener, fd 5 the restart lock
     and fd 6 the system endpoint's listener (step 5-6a-2; DECISIONS G492),
     each only when given (>= 0);
   - no other descriptor: POSIX_SPAWN_CLOEXEC_DEFAULT on Darwin only,
     posix_spawn_file_actions_addclosefrom_np(7) on glibc 2.34 and later, and
     everywhere the daemon's own close-on-exec descriptors;
   - a process group of its own (its pid), so ending the group reaches what
     the module itself spawned;
   - an empty signal mask and the default action for SIGPIPE, SIGTERM, SIGINT
     and SIGHUP, whatever the daemon's threads had (C16). */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#if defined(__GLIBC__) && (__GLIBC__ > 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 34))
#define LCN_HAVE_CLOSEFROM 1
#endif

/* Darwin's flag closes every descriptor no file action names, so fds 1 and 2
   are named with posix_spawn_file_actions_addinherit_np. Bionic defines a flag
   of the same name with other semantics and has no addinherit_np: Android
   takes the close-on-exec path. */
#if defined(__APPLE__) && defined(POSIX_SPAWN_CLOEXEC_DEFAULT)
#define LCN_HAVE_CLOEXEC_DEFAULT 1
#endif

/* A close-on-exec copy above every fd the child is given, so dup2 onto 3, 4,
   5 or 6 never meets itself (a dup2 onto itself would keep close-on-exec). */
static int lcn_high(int fd) {
  if (fd < 0) return -1;
  return fcntl(fd, F_DUPFD_CLOEXEC, 64);
}

int lcn_host_spawn(const char *path, char *const argv[], char *const envp[],
                   int carrier, int listener, int lock, int system,
                   int *pid_out) {
  int c = lcn_high(carrier), l = lcn_high(listener), k = lcn_high(lock),
      y = lcn_high(system);
  int r = 0;
  if (c < 0 || (listener >= 0 && l < 0) || (lock >= 0 && k < 0) ||
      (system >= 0 && y < 0)) {
    r = errno ? errno : EBADF;
    goto out;
  }
  posix_spawn_file_actions_t fa;
  posix_spawnattr_t at;
  if ((r = posix_spawn_file_actions_init(&fa)) != 0) goto out;
  if ((r = posix_spawnattr_init(&at)) != 0) {
    posix_spawn_file_actions_destroy(&fa);
    goto out;
  }
  short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
#ifdef LCN_HAVE_CLOEXEC_DEFAULT
  flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
  sigset_t empty, dflt;
  sigemptyset(&empty);
  sigemptyset(&dflt);
  sigaddset(&dflt, SIGPIPE);
  sigaddset(&dflt, SIGTERM);
  sigaddset(&dflt, SIGINT);
  sigaddset(&dflt, SIGHUP);
  if ((r = posix_spawnattr_setflags(&at, flags)) != 0) goto done;
  if ((r = posix_spawnattr_setpgroup(&at, 0)) != 0) goto done;
  if ((r = posix_spawnattr_setsigmask(&at, &empty)) != 0) goto done;
  if ((r = posix_spawnattr_setsigdefault(&at, &dflt)) != 0) goto done;
  if ((r = posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)) != 0)
    goto done;
#ifdef LCN_HAVE_CLOEXEC_DEFAULT
  if ((r = posix_spawn_file_actions_addinherit_np(&fa, 1)) != 0) goto done;
  if ((r = posix_spawn_file_actions_addinherit_np(&fa, 2)) != 0) goto done;
#endif
  if ((r = posix_spawn_file_actions_adddup2(&fa, c, 3)) != 0) goto done;
  if (l >= 0 && (r = posix_spawn_file_actions_adddup2(&fa, l, 4)) != 0) goto done;
  if (k >= 0 && (r = posix_spawn_file_actions_adddup2(&fa, k, 5)) != 0) goto done;
  if (y >= 0 && (r = posix_spawn_file_actions_adddup2(&fa, y, 6)) != 0) goto done;
#ifdef LCN_HAVE_CLOSEFROM
  if ((r = posix_spawn_file_actions_addclosefrom_np(&fa, 7)) != 0) goto done;
#endif
  pid_t pid = 0;
  r = posix_spawn(&pid, path, &fa, &at, argv, envp);
  if (r == 0) *pid_out = (int)pid;
done:
  posix_spawn_file_actions_destroy(&fa);
  posix_spawnattr_destroy(&at);
out:
  if (c >= 0) close(c);
  if (l >= 0) close(l);
  if (k >= 0) close(k);
  if (y >= 0) close(y);
  return r == 0 ? 0 : -r;
}
