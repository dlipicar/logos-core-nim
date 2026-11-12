/* The POSIX system calls of the unix-stream transport (TRANSPORT §8.2), in C so
   that `struct sockaddr_un`, `struct ucred`, `struct stat` and the socket option
   constants have exactly the platform's layout. Every function returns a
   non-negative result or the negated errno; none keeps state. Every descriptor
   is created close-on-exec, and every socket non-blocking and, on Darwin and
   iOS, with SO_NOSIGPIPE: writes use MSG_NOSIGNAL elsewhere, so no write raises
   SIGPIPE whatever the process's disposition [IMPL]. */

#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#include <libproc.h>
#include <sys/proc_info.h>
#endif
#endif

typedef struct {
  uint64_t dev;
  uint64_t ino;
  uint32_t mode; /* type and permission bits */
  uint32_t uid;
} lcn_stat_t;

static int neg(void) { return errno > 0 ? -errno : -EIO; }

static void fill(lcn_stat_t *out, const struct stat *st) {
  out->dev = (uint64_t)st->st_dev;
  out->ino = (uint64_t)st->st_ino;
  out->mode = (uint32_t)st->st_mode;
  out->uid = (uint32_t)st->st_uid;
}

int lcn_sun_path_max(void) {
  /* The bytes of sun_path, its terminating NUL included. */
  return (int)sizeof(((struct sockaddr_un *)0)->sun_path);
}

static int set_flags(int fd) {
  int fl = fcntl(fd, F_GETFL, 0);
  if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0) return neg();
  int fdf = fcntl(fd, F_GETFD, 0);
  if (fdf < 0 || fcntl(fd, F_SETFD, fdf | FD_CLOEXEC) < 0) return neg();
#ifdef SO_NOSIGPIPE
  int one = 1;
  if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one) < 0) return neg();
#endif
  return 0;
}

int lcn_set_flags(int fd) { return set_flags(fd); }

int lcn_unix_socket(void) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return neg();
  int r = set_flags(fd);
  if (r < 0) {
    close(fd);
    return r;
  }
  return fd;
}

static int address(const char *path, struct sockaddr_un *a, socklen_t *len) {
  size_t n = strlen(path);
  if (n == 0 || n + 1 > sizeof a->sun_path) return -ENAMETOOLONG;
  memset(a, 0, sizeof *a);
  a->sun_family = AF_UNIX;
  memcpy(a->sun_path, path, n + 1);
  *len = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + n + 1);
#if defined(__APPLE__)
  a->sun_len = (unsigned char)*len;
#endif
  return 0;
}

int lcn_bind(int fd, const char *path) {
  /* bind(2) never replaces an existing object: any object at the path,
     a symbolic link included, gives EADDRINUSE (TRANSPORT §8.2). */
  struct sockaddr_un a;
  socklen_t len;
  int r = address(path, &a, &len);
  if (r < 0) return r;
  return bind(fd, (struct sockaddr *)&a, len) < 0 ? neg() : 0;
}

int lcn_listen(int fd, int backlog) { return listen(fd, backlog) < 0 ? neg() : 0; }

int lcn_connect(int fd, const char *path) {
  struct sockaddr_un a;
  socklen_t len;
  int r = address(path, &a, &len);
  if (r < 0) return r;
  for (;;) {
    if (connect(fd, (struct sockaddr *)&a, len) == 0) return 0;
    if (errno != EINTR) return neg();
  }
}

int lcn_connect_result(int fd) {
  /* The outcome of a connect that returned EINPROGRESS. */
  int e = 0;
  socklen_t n = sizeof e;
  if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &n) < 0) return neg();
  return -e;
}

int lcn_accept(int lfd) {
  for (;;) {
    int fd = accept(lfd, NULL, NULL);
    if (fd >= 0) {
      int r = set_flags(fd);
      if (r < 0) {
        close(fd);
        return r;
      }
      return fd;
    }
    if (errno != EINTR) return neg();
  }
}

long lcn_send(int fd, const void *p, size_t n) {
#ifdef MSG_NOSIGNAL
  const int flags = MSG_NOSIGNAL;
#else
  const int flags = 0; /* SO_NOSIGPIPE is set on the socket */
#endif
  for (;;) {
    ssize_t r = send(fd, p, n, flags);
    if (r >= 0) return (long)r;
    if (errno != EINTR) return neg();
  }
}

long lcn_recv(int fd, void *p, size_t n) {
  for (;;) {
    ssize_t r = recv(fd, p, n, 0);
    if (r >= 0) return (long)r;
    if (errno != EINTR) return neg();
  }
}

int lcn_shutdown_write(int fd) { return shutdown(fd, SHUT_WR) < 0 ? neg() : 0; }

int lcn_close(int fd) { return close(fd) < 0 ? neg() : 0; }

int lcn_peercred(int fd, uint32_t *uid, uint32_t *gid, int32_t *pid) {
  /* TRANSPORT §8.2: SO_PEERCRED or getpeereid(). The pid is for diagnostics
     only; -1 when the platform does not report it. */
  *pid = -1;
#if defined(__linux__)
  struct ucred c;
  socklen_t n = sizeof c;
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &c, &n) < 0) return neg();
  if (n != sizeof c) return -EINVAL;
  *uid = (uint32_t)c.uid;
  *gid = (uint32_t)c.gid;
  *pid = (int32_t)c.pid;
  return 0;
#elif defined(__APPLE__)
  uid_t u;
  gid_t g;
  if (getpeereid(fd, &u, &g) < 0) return neg();
  *uid = (uint32_t)u;
  *gid = (uint32_t)g;
#if defined(LOCAL_PEERPID) && defined(SOL_LOCAL)
  pid_t p = -1;
  socklen_t n = sizeof p;
  if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &p, &n) == 0 && n == sizeof p)
    *pid = (int32_t)p;
#endif
  return 0;
#else
  (void)fd;
  (void)uid;
  (void)gid;
  return -ENOSYS;
#endif
}

int lcn_sock_info(int fd, int *type, int *domain, int *listening) {
  /* SO_TYPE, the address family and SO_ACCEPTCONN of a socket. */
  socklen_t n = sizeof *type;
  if (getsockopt(fd, SOL_SOCKET, SO_TYPE, type, &n) < 0) return neg();
  struct sockaddr_storage ss;
  socklen_t sl = sizeof ss;
  memset(&ss, 0, sizeof ss);
  if (getsockname(fd, (struct sockaddr *)&ss, &sl) < 0) return neg();
  *domain = ss.ss_family;
#if defined(__APPLE__)
#if TARGET_OS_OSX
  /* Darwin's getsockopt has no SO_ACCEPTCONN; listen() sets that bit in the
     socket's options, which libproc reports. */
  struct socket_fdinfo si;
  memset(&si, 0, sizeof si);
  if (proc_pidfdinfo(getpid(), fd, PROC_PIDFDSOCKETINFO, &si, sizeof si) <
      (int)sizeof si)
    return neg();
  *listening = (si.psi.soi_options & SO_ACCEPTCONN) ? 1 : 0;
  return 0;
#else
  /* iOS (cross-built only, TRANSPORT §8.2.1 is Tier 5): no way to read the
     listening state, so validation fails closed. */
  *listening = 0;
  return -ENOSYS;
#endif
#else
  n = sizeof *listening;
  if (getsockopt(fd, SOL_SOCKET, SO_ACCEPTCONN, listening, &n) < 0) return neg();
  return 0;
#endif
}

int lcn_sock_name(int fd, char *buf, int cap) {
  /* The path a unix socket is bound to, NUL-terminated in buf; its length. */
  struct sockaddr_un a;
  socklen_t n = sizeof a;
  memset(&a, 0, sizeof a);
  if (getsockname(fd, (struct sockaddr *)&a, &n) < 0) return neg();
  if (a.sun_family != AF_UNIX) return -EAFNOSUPPORT;
  size_t len = strnlen(a.sun_path, sizeof a.sun_path);
  if ((int)len + 1 > cap) return -ENAMETOOLONG;
  memcpy(buf, a.sun_path, len);
  buf[len] = 0;
  return (int)len;
}

int lcn_set_nonblock(int fd) {
  int fl = fcntl(fd, F_GETFL, 0);
  if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0) return neg();
  return 0;
}

int lcn_is_nonblock(int fd) {
  int fl = fcntl(fd, F_GETFL, 0);
  if (fl < 0) return neg();
  return (fl & O_NONBLOCK) != 0;
}

int lcn_fd_open(int fd) { return fcntl(fd, F_GETFD, 0) < 0 ? neg() : 0; }

uint32_t lcn_geteuid(void) { return (uint32_t)geteuid(); }

int lcn_open_dir(int dfd, const char *path) {
  /* A directory, never through a symbolic link at its last component. */
  int fd = openat(dfd < 0 ? AT_FDCWD : dfd, path,
                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  return fd < 0 ? neg() : fd;
}

int lcn_mkdirat(int dfd, const char *name, int mode) {
  return mkdirat(dfd, name, (mode_t)mode) < 0 ? neg() : 0;
}

int lcn_fchmod(int fd, int mode) { return fchmod(fd, (mode_t)mode) < 0 ? neg() : 0; }

int lcn_fchmodat(int dfd, const char *name, int mode) {
  /* Linux rejects AT_SYMLINK_NOFOLLOW here; the caller checks the object's
     type and identity with lcn_fstatat afterwards. */
  return fchmodat(dfd, name, (mode_t)mode, 0) < 0 ? neg() : 0;
}

int lcn_fstat(int fd, lcn_stat_t *out) {
  struct stat st;
  if (fstat(fd, &st) < 0) return neg();
  fill(out, &st);
  return 0;
}

int lcn_lstat(const char *path, lcn_stat_t *out) {
  struct stat st;
  if (lstat(path, &st) < 0) return neg();
  fill(out, &st);
  return 0;
}

int lcn_fstatat(int dfd, const char *name, lcn_stat_t *out) {
  struct stat st;
  if (fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) < 0) return neg();
  fill(out, &st);
  return 0;
}

int lcn_unlinkat(int dfd, const char *name, int dir) {
  return unlinkat(dfd, name, dir ? AT_REMOVEDIR : 0) < 0 ? neg() : 0;
}

int lcn_socketpair(int *fds) {
  int r = socketpair(AF_UNIX, SOCK_STREAM, 0, fds);
  if (r < 0) return neg();
  for (int i = 0; i < 2; i++) {
    int fdf = fcntl(fds[i], F_GETFD, 0);
    if (fdf < 0 || fcntl(fds[i], F_SETFD, fdf | FD_CLOEXEC) < 0) return neg();
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fds[i], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
  }
  return 0;
}

/* Constants the Nim side compares against. */
int lcn_c_eagain(void) { return EAGAIN; }
int lcn_c_ewouldblock(void) { return EWOULDBLOCK; }
int lcn_c_einprogress(void) { return EINPROGRESS; }
int lcn_c_eaddrinuse(void) { return EADDRINUSE; }
int lcn_c_eexist(void) { return EEXIST; }
int lcn_c_enoent(void) { return ENOENT; }
int lcn_c_enametoolong(void) { return ENAMETOOLONG; }
int lcn_c_sock_stream(void) { return SOCK_STREAM; }
int lcn_c_af_unix(void) { return AF_UNIX; }
int lcn_c_s_ifmt(void) { return S_IFMT; }
int lcn_c_s_ifsock(void) { return S_IFSOCK; }
int lcn_c_s_ifdir(void) { return S_IFDIR; }
int lcn_c_s_iflnk(void) { return S_IFLNK; }
