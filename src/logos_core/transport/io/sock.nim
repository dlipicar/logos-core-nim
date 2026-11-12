## TRANSPORT §8.2: the system calls of `logos.local.unix-stream`, bound from
## `sock.c` so that socket and stat structures have the platform's exact layout.
## Every call returns a non-negative result or a negated errno. Windows has no
## implementation: the profile is unsupported there until the G107 spike, so
## every call fails and nothing is opened [SPEC TRANSPORT §8.2.1].

{.push raises: [].}

import results

export results

const unixStream* = not defined(windows)
  ## Whether this platform builds the unix-stream profile.

type
  StatInfo* = object ## `struct stat`'s identity, type and owner
    dev*, ino*: uint64
    mode*, uid*: uint32

  OsError* = distinct cint ## a positive errno value

func `==`*(a, b: OsError): bool {.borrow.}

when unixStream:
  {.compile: "sock.c".}

  proc sunPathMax*(): cint {.importc: "lcn_sun_path_max", cdecl.}
  proc setFlags*(fd: cint): cint {.importc: "lcn_set_flags", cdecl.}
  proc unixSocket*(): cint {.importc: "lcn_unix_socket", cdecl.}
  proc sockBind*(fd: cint, path: cstring): cint {.importc: "lcn_bind", cdecl.}
  proc sockListen*(fd, backlog: cint): cint {.importc: "lcn_listen", cdecl.}
  proc sockConnect*(fd: cint, path: cstring): cint {.importc: "lcn_connect", cdecl.}
  proc connectResult*(fd: cint): cint {.importc: "lcn_connect_result", cdecl.}
  proc sockAccept*(fd: cint): cint {.importc: "lcn_accept", cdecl.}
  proc sockSend*(fd: cint, p: pointer, n: csize_t): clong {.importc: "lcn_send", cdecl.}
  proc sockRecv*(fd: cint, p: pointer, n: csize_t): clong {.importc: "lcn_recv", cdecl.}
  proc shutdownWrite*(fd: cint): cint {.importc: "lcn_shutdown_write", cdecl.}
  proc fdClose*(fd: cint): cint {.importc: "lcn_close", cdecl.}
  proc peerCredRaw*(
    fd: cint, uid, gid: ptr uint32, pid: ptr int32
  ): cint {.importc: "lcn_peercred", cdecl.}

  proc sockInfo*(
    fd: cint, typ, domain, listening: ptr cint
  ): cint {.importc: "lcn_sock_info", cdecl.}

  proc sockNameRaw(
    fd: cint, buf: ptr char, cap: cint
  ): cint {.importc: "lcn_sock_name", cdecl.}

  proc setNonblock*(fd: cint): cint {.importc: "lcn_set_nonblock", cdecl.}
  proc isNonblock*(fd: cint): cint {.importc: "lcn_is_nonblock", cdecl.}
  proc fdOpen*(fd: cint): cint {.importc: "lcn_fd_open", cdecl.}
  proc geteuid*(): uint32 {.importc: "lcn_geteuid", cdecl.}
  proc openDir*(dfd: cint, path: cstring): cint {.importc: "lcn_open_dir", cdecl.}
  proc mkdirAt*(
    dfd: cint, name: cstring, mode: cint
  ): cint {.importc: "lcn_mkdirat", cdecl.}

  proc fchmodFd*(fd, mode: cint): cint {.importc: "lcn_fchmod", cdecl.}
  proc fchmodAt*(
    dfd: cint, name: cstring, mode: cint
  ): cint {.importc: "lcn_fchmodat", cdecl.}

  proc fstatFd*(fd: cint, st: ptr StatInfo): cint {.importc: "lcn_fstat", cdecl.}
  proc lstatPath*(path: cstring, st: ptr StatInfo): cint {.importc: "lcn_lstat", cdecl.}
  proc fstatAt*(
    dfd: cint, name: cstring, st: ptr StatInfo
  ): cint {.importc: "lcn_fstatat", cdecl.}

  proc unlinkAt*(
    dfd: cint, name: cstring, dir: cint
  ): cint {.importc: "lcn_unlinkat", cdecl.}

  proc socketPair*(fds: ptr array[2, cint]): cint {.importc: "lcn_socketpair", cdecl.}

  proc cEagain(): cint {.importc: "lcn_c_eagain", cdecl.}
  proc cEwouldblock(): cint {.importc: "lcn_c_ewouldblock", cdecl.}
  proc cEinprogress(): cint {.importc: "lcn_c_einprogress", cdecl.}
  proc cEaddrinuse(): cint {.importc: "lcn_c_eaddrinuse", cdecl.}
  proc cEexist(): cint {.importc: "lcn_c_eexist", cdecl.}
  proc cEnoent(): cint {.importc: "lcn_c_enoent", cdecl.}
  proc cEnametoolong(): cint {.importc: "lcn_c_enametoolong", cdecl.}
  proc cSockStream(): cint {.importc: "lcn_c_sock_stream", cdecl.}
  proc cAfUnix(): cint {.importc: "lcn_c_af_unix", cdecl.}
  proc cIfmt(): cint {.importc: "lcn_c_s_ifmt", cdecl.}
  proc cIfsock(): cint {.importc: "lcn_c_s_ifsock", cdecl.}
  proc cIfdir(): cint {.importc: "lcn_c_s_ifdir", cdecl.}
  proc cIflnk(): cint {.importc: "lcn_c_s_iflnk", cdecl.}

  let
    EAGAIN* = cEagain()
    EWOULDBLOCK* = cEwouldblock()
    EINPROGRESS* = cEinprogress()
    EADDRINUSE* = cEaddrinuse()
    EEXIST* = cEexist()
    ENOENT* = cEnoent()
    ENAMETOOLONG* = cEnametoolong()
    SockStream* = cSockStream()
    AfUnix* = cAfUnix()
    SIfmt = uint32(cIfmt())
    SIfsock = uint32(cIfsock())
    SIfdir = uint32(cIfdir())
    SIflnk = uint32(cIflnk())

  proc wouldBlock*(r: SomeInteger): bool =
    ## A negated EAGAIN or EWOULDBLOCK.
    r < 0 and (cint(-r) == EAGAIN or cint(-r) == EWOULDBLOCK)

  proc isSocket*(s: StatInfo): bool =
    (s.mode and SIfmt) == SIfsock

  proc isDir*(s: StatInfo): bool =
    (s.mode and SIfmt) == SIfdir

  proc isLink*(s: StatInfo): bool =
    (s.mode and SIfmt) == SIflnk

  func perm*(s: StatInfo): uint32 =
    s.mode and 0o7777'u32

  proc sockName*(fd: cint): Result[string, cint] =
    var buf: array[256, char]
    let n = sockNameRaw(fd, addr buf[0], cint(buf.len))
    if n < 0:
      return err(-n)
    var s = newString(n)
    for i in 0 ..< n:
      s[i] = buf[i]
    ok(s)

  proc fitsSunPath*(path: string): bool =
    ## [SPEC RUNTIME §2.3; G58] The path and its NUL fit `sun_path`; a path that
    ## does not is never shortened or substituted.
    path.len > 0 and path.len + 1 <= int(sunPathMax())

  proc errText*(code: cint): string =
    ## `strerror` of a negated errno, for diagnostics.
    proc strerror(e: cint): cstring {.importc, header: "<string.h>".}
    $strerror(
      if code < 0:
        -code
      else:
        code
    )

else:
  proc sunPathMax*(): cint =
    0

  proc fdClose*(fd: cint): cint =
    0

  proc geteuid*(): uint32 =
    0

  proc fitsSunPath*(path: string): bool =
    false

  proc errText*(code: cint): string =
    "unsupported"
