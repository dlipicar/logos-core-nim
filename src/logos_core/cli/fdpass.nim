## Descriptor passing on the launcher socket (Tier 5 step N-2; DECISIONS
## G344), bound from `fdpass.c`: SCM_RIGHTS on a unix-stream socket. Every call
## returns a non-negative result or a negated errno.

{.push raises: [].}

when not defined(windows):
  {.compile: "fdpass.c".}

  proc maxFds*(): cint {.importc: "lcn_cli_max_fds", cdecl.}
    ## [G344] The most descriptors one message carries.

  proc sendFds*(
    fd: cint, p: pointer, n: csize_t, fds: ptr cint, nfds: cint
  ): clong {.importc: "lcn_cli_send_fds", cdecl.}
    ## [G344] Up to `n` bytes with `nfds` descriptors on the first byte.

  proc recvFds*(
    fd: cint, p: pointer, n: csize_t, fds: ptr cint, cap: cint, nfds, dropped: ptr cint
  ): clong {.importc: "lcn_cli_recv_fds", cdecl.}
    ## [G344] Up to `n` bytes and their descriptors (close-on-exec); any beyond
    ## `cap`, or cut off, are closed and counted in `dropped`.
