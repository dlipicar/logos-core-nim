/* Descriptor passing for the CLI's launcher socket (Tier 5 step N-2;
   DECISIONS G344): SCM_RIGHTS on a unix-stream socket. At most
   LCN_CLI_MAX_FDS ride on one message. Every function returns a non-negative
   result or the negated errno, as transport/io/sock.c's do; this file is the
   CLI's own, so the core library's socket layer is unchanged. */

#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>

#define LCN_CLI_MAX_FDS 16

static int neg(void) { return errno > 0 ? -errno : -EIO; }

int lcn_cli_max_fds(void) { return LCN_CLI_MAX_FDS; }

long lcn_cli_send_fds(int fd, const void *p, size_t n, const int *fds, int nfds) {
  /* Sends up to n bytes with nfds descriptors attached to the first byte. A
     short count means the descriptors went with the bytes that were sent. */
  if (n == 0 || nfds < 0 || nfds > LCN_CLI_MAX_FDS) return -EINVAL;
  struct iovec iov;
  iov.iov_base = (void *)p;
  iov.iov_len = n;
  struct msghdr m;
  memset(&m, 0, sizeof m);
  m.msg_iov = &iov;
  m.msg_iovlen = 1;
  union {
    char buf[CMSG_SPACE(sizeof(int) * LCN_CLI_MAX_FDS)];
    struct cmsghdr align;
  } u;
  if (nfds > 0) {
    memset(&u, 0, sizeof u);
    m.msg_control = u.buf;
    m.msg_controllen = CMSG_SPACE(sizeof(int) * (size_t)nfds);
    struct cmsghdr *c = CMSG_FIRSTHDR(&m);
    c->cmsg_level = SOL_SOCKET;
    c->cmsg_type = SCM_RIGHTS;
    c->cmsg_len = CMSG_LEN(sizeof(int) * (size_t)nfds);
    memcpy(CMSG_DATA(c), fds, sizeof(int) * (size_t)nfds);
  }
#ifdef MSG_NOSIGNAL
  const int flags = MSG_NOSIGNAL;
#else
  const int flags = 0; /* SO_NOSIGPIPE is set on the socket */
#endif
  for (;;) {
    ssize_t r = sendmsg(fd, &m, flags);
    if (r >= 0) return (long)r;
    if (errno != EINTR) return neg();
  }
}

long lcn_cli_recv_fds(int fd, void *p, size_t n, int *fds, int cap, int *nfds,
                  int *dropped) {
  /* Receives up to n bytes and the descriptors that came with them,
     close-on-exec, into fds[0..*nfds). Descriptors beyond cap, and a
     truncated control message, are closed here and counted in *dropped, so
     none is ever left open unseen. */
  *nfds = 0;
  *dropped = 0;
  if (cap < 0 || cap > LCN_CLI_MAX_FDS) return -EINVAL;
  struct iovec iov;
  iov.iov_base = p;
  iov.iov_len = n;
  struct msghdr m;
  union {
    char buf[CMSG_SPACE(sizeof(int) * LCN_CLI_MAX_FDS)];
    struct cmsghdr align;
  } u;
#ifdef MSG_CMSG_CLOEXEC
  const int flags = MSG_CMSG_CLOEXEC;
#else
  const int flags = 0; /* FD_CLOEXEC is set below */
#endif
  ssize_t r;
  for (;;) {
    memset(&m, 0, sizeof m);
    memset(&u, 0, sizeof u);
    m.msg_iov = &iov;
    m.msg_iovlen = 1;
    m.msg_control = u.buf;
    m.msg_controllen = sizeof u.buf;
    r = recvmsg(fd, &m, flags);
    if (r >= 0) break;
    if (errno != EINTR) return neg();
  }
  for (struct cmsghdr *c = CMSG_FIRSTHDR(&m); c != NULL; c = CMSG_NXTHDR(&m, c)) {
    if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS) continue;
    size_t k = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
    const unsigned char *d = CMSG_DATA(c);
    for (size_t i = 0; i < k; i++) {
      int got;
      memcpy(&got, d + i * sizeof(int), sizeof got);
#ifndef MSG_CMSG_CLOEXEC
      int fdf = fcntl(got, F_GETFD, 0);
      if (fdf >= 0) (void)fcntl(got, F_SETFD, fdf | FD_CLOEXEC);
#endif
      if (*nfds < cap) {
        fds[(*nfds)++] = got;
      } else {
        close(got);
        (*dropped)++;
      }
    }
  }
  if (m.msg_flags & MSG_CTRUNC) (*dropped)++;
  return (long)r;
}
