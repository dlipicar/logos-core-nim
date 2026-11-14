## TRANSPORT §8.2, §9.1; RUNTIME §2.3, §6.2; G58: the endpoints of
## `logos.local.unix-stream`.
##
## `createEndpoint` makes `<base>/<8 hex>/logos_<module>.sock`: a fresh directory,
## mode 0700 and owned by the effective uid whatever the umask; a socket bound
## there without ever following, removing or replacing an existing object; mode
## 0600; listening before any handoff. The Runtime keeps its own listener and
## directory descriptors and the dev/ino of both objects, so `validateEndpoint`
## can tell a swapped directory, a symbolic link or a rebound socket from the
## endpoint it made, and `removeEndpoint` removes only those objects.
## `adoptListener` is the serving side's only entry: a Module Host serves the
## descriptor it was given and has no bind path (TRN-0184).

{.push raises: [].}

import results
import ../../base/hex
import ../ticket
import ./sock

export results

type
  EndpointErrorKind* = enum
    eeBase ## the base directory is unsafe or missing
    eeTooLong ## the path does not fit `sun_path`: the placement fails (G58)
    eeExists ## an object already exists at the path; it is left untouched
    eeCreate ## a system call failed
    eeInvalid ## validation failed: the endpoint is not the one created
    eeReplaced ## removal left an object that is no longer the endpoint's
    eeUnsupported ## no unix-stream profile on this platform (§8.2.1)

  EndpointError* = object
    kind*: EndpointErrorKind
    msg*: string ## paths and errno text only; never a ticket

  EndpointDir* = object ## A fresh per-instance directory, held open.
    base*, path*, name*: string ## `name` is the 8-hex component
    baseFd*, fd*: cint
    dev*, ino*: uint64

  Endpoint* = object
    dir*: EndpointDir
    path*: string ## the socket path the descriptor carries
    sockName*: string ## `logos_<module>.sock`
    listener*: cint ## the Runtime's own copy, kept until removal
    dev*, ino*: uint64 ## the socket object's identity

const
  DirMode = 0o700'u32
  SockMode = 0o600'u32
  SockPrefix* = "logos_"
  SockSuffix* = ".sock"

func fail(k: EndpointErrorKind, msg: string): EndpointError =
  EndpointError(kind: k, msg: msg)

func socketName*(moduleName: string): string =
  ## [G58] The socket's file name for a flat runtime module name.
  SockPrefix & moduleName & SockSuffix

when unixStream:
  proc stat(fd: cint): Result[StatInfo, cint] =
    var st: StatInfo
    let r = fstatFd(fd, addr st)
    if r < 0:
      return err(r)
    ok(st)

  proc lstat(path: string): Result[StatInfo, cint] =
    var st: StatInfo
    let r = lstatPath(cstring(path), addr st)
    if r < 0:
      return err(r)
    ok(st)

  proc statAt(dfd: cint, name: string): Result[StatInfo, cint] =
    var st: StatInfo
    let r = fstatAt(dfd, cstring(name), addr st)
    if r < 0:
      return err(r)
    ok(st)

  proc checkBase(base: string): Result[void, EndpointError] =
    ## [IMPL] The base is a real directory (not a symbolic link) that only this
    ## uid can write to, or root's sticky directory such as `/tmp`.
    let st = lstat(base).valueOr:
      return err(fail(eeBase, base & ": " & errText(error)))
    if not st.isDir:
      return err(fail(eeBase, base & " is not a directory (or is a symbolic link)"))
    let euid = geteuid()
    let ownSafe = st.uid == euid and (st.perm and 0o022'u32) == 0
    let rootSticky = st.uid == 0 and (st.perm and 0o1000'u32) != 0
    if not (ownSafe or rootSticky):
      return err(
        fail(
          eeBase,
          base & " is writable by others and is not a root-owned sticky directory",
        )
      )
    ok()

proc checkEndpointBase*(base: string): Result[void, EndpointError] =
  ## [IMPL] The base check `makeEndpointDir` runs, for an owner that wants
  ## its configuration refused early (the Runtime at open, I90).
  when unixStream:
    checkBase(base)
  else:
    err(fail(eeUnsupported, "unix-stream endpoints are not supported (§8.2.1)"))

proc makeEndpointDir*(base: string): Result[EndpointDir, EndpointError] =
  ## [SPEC TRANSPORT §8.2; G58] A new directory `<base>/<8 hex>`, mode 0700 and
  ## owned by the effective uid. Its name is random and never reused, so a
  ## directory a crash left behind is never adopted [IMPL].
  when unixStream:
    ?checkBase(base)
    let baseFd = openDir(-1, cstring(base))
    if baseFd < 0:
      return err(fail(eeBase, base & ": " & errText(baseFd)))
    var name = ""
    for attempt in 0 ..< 8:
      var r: array[4, byte]
      if not osRandom(r):
        discard fdClose(baseFd)
        return err(fail(eeCreate, "the random source failed"))
      let candidate = hex.toHex(r)
      let m = mkdirAt(baseFd, cstring(candidate), cint(DirMode))
      if m == 0:
        name = candidate
        break
      if -m != EEXIST:
        discard fdClose(baseFd)
        return err(fail(eeCreate, base & "/" & candidate & ": " & errText(m)))
    if name.len == 0:
      discard fdClose(baseFd)
      return err(fail(eeCreate, "eight random directory names already existed"))
    let path = base & "/" & name
    proc undo(dfd: cint) =
      if dfd >= 0:
        discard fdClose(dfd)
      discard unlinkAt(baseFd, cstring(name), 1)
      discard fdClose(baseFd)

    let fd = openDir(baseFd, cstring(name))
    if fd < 0:
      undo(-1)
      return err(fail(eeCreate, path & ": " & errText(fd)))
    # mkdir applied the umask; the mode is set explicitly [SPEC TRANSPORT §8.2].
    let c = fchmodFd(fd, cint(DirMode))
    if c < 0:
      undo(fd)
      return err(fail(eeCreate, path & ": " & errText(c)))
    let st = stat(fd).valueOr:
      undo(fd)
      return err(fail(eeCreate, path & ": " & errText(error)))
    if not st.isDir or st.uid != geteuid() or st.perm != DirMode:
      undo(fd)
      return err(fail(eeCreate, path & " is not a 0700 directory of this uid"))
    ok(
      EndpointDir(
        base: base,
        path: path,
        name: name,
        baseFd: baseFd,
        fd: fd,
        dev: st.dev,
        ino: st.ino,
      )
    )
  else:
    err(fail(eeUnsupported, "unix-stream endpoints are not supported (§8.2.1)"))

proc closeDir*(d: EndpointDir) =
  ## Closes the directory's descriptors without removing anything.
  when unixStream:
    if d.fd >= 0:
      discard fdClose(d.fd)
    if d.baseFd >= 0:
      discard fdClose(d.baseFd)

proc removeDir*(d: EndpointDir): Result[void, EndpointError] =
  ## Removes the directory if it is still the one made and is empty, then
  ## closes its descriptors.
  when unixStream:
    var res: Result[void, EndpointError] = ok()
    let st = statAt(d.baseFd, d.name)
    if st.isOk and st.get.isDir and st.get.dev == d.dev and st.get.ino == d.ino:
      let r = unlinkAt(d.baseFd, cstring(d.name), 1)
      if r < 0:
        res = err(fail(eeReplaced, d.path & " was not removed: " & errText(r)))
    elif st.isOk:
      res = err(fail(eeReplaced, d.path & " is no longer the endpoint directory"))
    closeDir(d)
    res
  else:
    err(fail(eeUnsupported, "unix-stream endpoints are not supported (§8.2.1)"))

proc validateEndpoint*(ep: Endpoint): Result[void, EndpointError] {.gcsafe.}

proc bindEndpoint*(
    d: EndpointDir, moduleName: string, backlog = 128
): Result[Endpoint, EndpointError] =
  ## [SPEC TRANSPORT §8.2] Binds and listens on `<dir>/logos_<module>.sock`.
  ## Any object already at the path, a symbolic link included, makes `bind`
  ## fail; it is never followed, removed or replaced (`eeExists`). A path that
  ## does not fit `sun_path` is `eeTooLong` and nothing is created (G58).
  when unixStream:
    if moduleName.len == 0 or '/' in moduleName or '\0' in moduleName:
      return err(fail(eeCreate, "not a flat module name: " & moduleName))
    let name = socketName(moduleName)
    let path = d.path & "/" & name
    if not fitsSunPath(path):
      return err(
        fail(
          eeTooLong, path & " does not fit sun_path (" & $(sunPathMax() - 1) & " bytes)"
        )
      )
    # Darwin's bind follows a dangling symbolic link and creates the socket at
    # its target; Linux refuses. So anything at the path, looked up without
    # following, is refused first. Only this uid can write in the fresh 0700
    # directory, and the check after bind catches a race [IMPL].
    if statAt(d.fd, name).isOk:
      return err(fail(eeExists, path & " already exists; it was left untouched"))
    let fd = unixSocket()
    if fd < 0:
      return err(fail(eeCreate, "socket: " & errText(fd)))
    let b = sockBind(fd, cstring(path))
    if b < 0:
      discard fdClose(fd)
      # Whatever errno the platform gives (EADDRINUSE; Darwin may give another
      # for a directory), an object at the path is a pre-existing path.
      if -b == EADDRINUSE or -b == EEXIST or statAt(d.fd, name).isOk:
        return err(fail(eeExists, path & " already exists; it was left untouched"))
      return err(fail(eeCreate, path & ": bind: " & errText(b)))
    proc undo() =
      let st = statAt(d.fd, name)
      if st.isOk and st.get.isSocket and st.get.uid == geteuid():
        discard unlinkAt(d.fd, cstring(name), 0)
      discard fdClose(fd)

    let st = statAt(d.fd, name).valueOr:
      undo()
      return err(fail(eeCreate, path & ": " & errText(error)))
    if not st.isSocket:
      undo()
      return err(fail(eeCreate, path & " is not the socket just bound"))
    let c = fchmodAt(d.fd, cstring(name), cint(SockMode))
    if c < 0:
      undo()
      return err(fail(eeCreate, path & ": chmod: " & errText(c)))
    # [SPEC TRANSPORT §8.2] Listening before the descriptor is handed off.
    let l = sockListen(fd, cint(backlog))
    if l < 0:
      undo()
      return err(fail(eeCreate, path & ": listen: " & errText(l)))
    let ep = Endpoint(
      dir: d, path: path, sockName: name, listener: fd, dev: st.dev, ino: st.ino
    )
    let v = validateEndpoint(ep)
    if v.isErr:
      undo()
      return err(v.error)
    ok(ep)
  else:
    err(fail(eeUnsupported, "unix-stream endpoints are not supported (§8.2.1)"))

proc createEndpoint*(
    base, moduleName: string, backlog = 128
): Result[Endpoint, EndpointError] =
  ## [SPEC TRANSPORT §8.2; RUNTIME §2.3; G58] A new endpoint under `base`. On
  ## any failure only what this call created is undone.
  let d = ?makeEndpointDir(base)
  let ep = bindEndpoint(d, moduleName, backlog).valueOr:
    discard removeDir(d)
    return err(error)
  ok(ep)

proc validateEndpoint*(ep: Endpoint): Result[void, EndpointError] {.gcsafe.} =
  ## [SPEC TRANSPORT §8.2] The listener is a listening AF_UNIX stream socket
  ## bound to `path`; the directory is still the 0700 directory of this uid that
  ## was made, at its path, not a symbolic link; the socket path is still the
  ## socket that was bound, owned by this uid. Run after creation, after the
  ## transfer and before the provider is marked ready (10b, 4b).
  when unixStream:
    template bad(msg: string): untyped =
      return err(fail(eeInvalid, msg))

    let ls = stat(ep.listener).valueOr:
      bad("the listener descriptor: " & errText(error))
    if not ls.isSocket:
      bad("the listener descriptor is not a socket")
    var typ, domain, listening: cint
    let i = sockInfo(ep.listener, addr typ, addr domain, addr listening)
    if i < 0:
      bad("the listener descriptor: " & errText(i))
    if typ != SockStream or domain != AfUnix:
      bad("the listener is not an AF_UNIX stream socket")
    if listening != 1:
      bad("the listener is not listening")
    let name = sockName(ep.listener).valueOr:
      bad("the listener's address: " & errText(error))
    if name != ep.path:
      bad("the listener is bound to another path")
    let euid = geteuid()
    let ds = stat(ep.dir.fd).valueOr:
      bad("the directory descriptor: " & errText(error))
    if not ds.isDir or ds.uid != euid or ds.perm != DirMode or ds.dev != ep.dir.dev or
        ds.ino != ep.dir.ino:
      bad(ep.dir.path & " is not the 0700 directory that was made")
    let dp = lstat(ep.dir.path).valueOr:
      bad(ep.dir.path & ": " & errText(error))
    if not dp.isDir or dp.dev != ep.dir.dev or dp.ino != ep.dir.ino:
      bad(ep.dir.path & " was replaced (or is a symbolic link)")
    let ss = statAt(ep.dir.fd, ep.sockName).valueOr:
      bad(ep.path & ": " & errText(error))
    if not ss.isSocket or ss.uid != euid or ss.dev != ep.dev or ss.ino != ep.ino:
      bad(ep.path & " is not the socket that was bound")
    ok()
  else:
    err(fail(eeUnsupported, "unix-stream endpoints are not supported (§8.2.1)"))

proc adoptListener*(fd: cint): Result[void, EndpointError] =
  ## [SPEC TRANSPORT §8.2] The serving side's entry: `fd` must be a listening
  ## AF_UNIX stream socket (the transferred listener). It becomes non-blocking.
  ## Nothing here binds or creates an endpoint.
  when unixStream:
    let st = stat(fd).valueOr:
      return err(fail(eeInvalid, "the inherited descriptor: " & errText(error)))
    if not st.isSocket:
      return err(fail(eeInvalid, "the inherited descriptor is not a socket"))
    var typ, domain, listening: cint
    let i = sockInfo(fd, addr typ, addr domain, addr listening)
    if i < 0:
      return err(fail(eeInvalid, "the inherited descriptor: " & errText(i)))
    if typ != SockStream or domain != AfUnix or listening != 1:
      return
        err(fail(eeInvalid, "the inherited descriptor is not a listening unix socket"))
    let n = setFlags(fd)
    if n < 0:
      return err(fail(eeCreate, "the inherited descriptor: " & errText(n)))
    ok()
  else:
    err(fail(eeUnsupported, "unix-stream endpoints are not supported (§8.2.1)"))

proc removeEndpoint*(ep: Endpoint): Result[void, EndpointError] =
  ## [RUNTIME §6.2] Unlinks the socket only while it is still the object bound,
  ## removes the directory only while it is the one made and empty, then closes
  ## the Runtime's listener and directory descriptors. A replaced object is left
  ## alone and reported (`eeReplaced`).
  when unixStream:
    var res: Result[void, EndpointError] = ok()
    let ss = statAt(ep.dir.fd, ep.sockName)
    if ss.isOk:
      if ss.get.isSocket and ss.get.dev == ep.dev and ss.get.ino == ep.ino:
        let r = unlinkAt(ep.dir.fd, cstring(ep.sockName), 0)
        if r < 0:
          res = err(fail(eeReplaced, ep.path & " was not removed: " & errText(r)))
      else:
        res = err(fail(eeReplaced, ep.path & " is no longer the endpoint's socket"))
    discard fdClose(ep.listener)
    let d = removeDir(ep.dir)
    if res.isOk and d.isErr:
      res = d
    res
  else:
    err(fail(eeUnsupported, "unix-stream endpoints are not supported (§8.2.1)"))
