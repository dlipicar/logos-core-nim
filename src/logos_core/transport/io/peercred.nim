## TRANSPORT §8.2: the peer identity of a connected unix-stream socket, from
## `SO_PEERCRED` (Linux, Android) or `getpeereid` with `LOCAL_PEERPID` (Darwin,
## iOS). For a caller it names the process that created and bound the listener,
## which under §8.2 is the Runtime, not a Module Host serving the transferred
## descriptor (TRN-0183, TRN-0188). Windows: unsupported (§8.2.1).

{.push raises: [].}

import results
import ./[api, sock]

export results

proc peerCred*(fd: cint): Result[PeerCred, string] =
  ## The connected peer's credentials. A failure is never a match: a caller
  ## that cannot read them treats it as a mismatch [SPEC TRANSPORT §8.2].
  when unixStream:
    var uid, gid: uint32
    var pid: int32
    let r = peerCredRaw(fd, addr uid, addr gid, addr pid)
    if r < 0:
      return err("peer credentials unavailable: " & errText(r))
    let known =
      if pid >= 0:
        Opt.some(pid)
      else:
        Opt.none(int32)
    ok(PeerCred(uid: uid, gid: gid, pid: known))
  else:
    err("peer credentials are not supported on this platform (TRANSPORT §8.2.1)")

proc effectiveUid*(): uint32 =
  ## This process's effective uid: the identity of a Runtime that creates
  ## endpoints, and what its callers expect (G58).
  geteuid()
