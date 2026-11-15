## The session directory of one logosd (Tier 4b step 4b-6; DECISIONS G88,
## G293): where it is, its fixed layout, and its lock. docs/DAEMON.md §2.
##
##   <session>/                 0700  $HOME/.logos-core by default
##     lock                           held by logosd while it runs, and by offline writers
##     daemon-config.cbor       0600  lcn.daemon_config
##     trust.cbor               0600  lcn.trust_file (absent: the compiled-in floor)
##     keys/                    0700  evidence keys and their bindings
##     state/                   0700  trust-mark.cbor, store/, modules/, evidence/
##     work/                    0700  runtime.work_dir; never emptied (restart locks)
##     run/                     0700  recreated at each start: logosctl.sock, ep/
##
## Every directory is owner-only (`durable.ensurePrivateDir`); a session that
## group or other may access is refused. Not for Windows: logosd and logosctl
## run on POSIX hosts only (DAEMON.md).

{.push raises: [].}

import std/[os, strutils]
import results
import ../durable

when defined(posix):
  import std/posix

export results

const
  SessionEnv* = "LOGOSCTL_SESSION_DIR" ## [G88]
  DefaultSessionName* = ".logos-core" ## [G88] under `$HOME`
  DaemonConfigName* = "daemon-config.cbor"
  TrustName* = "trust.cbor"
  TrustMarkName* = "trust-mark.cbor"
  KeysName* = "keys"
  StateName* = "state"
  StoreName* = "store"
  ModulesName* = "modules"
  EvidenceName* = "evidence"
  WorkName* = "work"
  RunName* = "run"
  SocketName* = "logosctl.sock"
  EndpointName* = "ep"
  MaxConfigBytes* = 64 * 1024 * 1024 ## [IMPL] daemon-config.cbor's bound
  SessionBusy* = "another logosd or an offline logosctl command holds this session"

type Session* = object ## A session directory, resolved to an absolute path.
  dir*: string

func configPath*(s: Session): string =
  s.dir / DaemonConfigName

func trustPath*(s: Session): string =
  s.dir / TrustName

func keysDir*(s: Session): string =
  s.dir / KeysName

func stateDir*(s: Session): string =
  s.dir / StateName

func storeDir*(s: Session): string =
  s.dir / StateName / StoreName

func modulesDir*(s: Session): string =
  s.dir / StateName / ModulesName

func evidenceDir*(s: Session): string =
  s.dir / StateName / EvidenceName

func workDir*(s: Session): string =
  s.dir / WorkName

func runDir*(s: Session): string =
  s.dir / RunName

func endpointDir*(s: Session): string =
  s.dir / RunName / EndpointName

func socketPath*(s: Session, socketDir = ""): string =
  ## The logosctl instance's socket: `run/logosctl.sock`, or in `ctl.socket_dir`.
  (if socketDir.len > 0: socketDir else: s.runDir) / SocketName

proc entryExists*(path: string): bool =
  ## Whether `path` names any directory entry, a socket or a dangling link
  ## included (`fileExists` is true only for regular files).
  when defined(posix):
    var st: Stat
    lstat(cstring(path), st) == 0
  else:
    fileExists(path) or dirExists(path) or symlinkExists(path)

proc resolveSession*(flag = ""): Result[Session, string] =
  ## [G88] `--session-dir`, else `$LOGOSCTL_SESSION_DIR`, else
  ## `$HOME/.logos-core`; relative paths are taken from the working directory.
  var dir = flag
  if dir.len == 0:
    dir = getEnv(SessionEnv)
  if dir.len == 0:
    let home = getEnv("HOME")
    if home.len == 0:
      return err("no session directory: set --session-dir, " & SessionEnv & " or HOME")
    dir = home / DefaultSessionName
  try:
    dir = absolutePath(dir).normalizedPath
  except CatchableError as e:
    return err("the session directory cannot be resolved: " & e.msg)
  ok(Session(dir: dir))

proc privateDirs(s: Session): seq[string] =
  @[s.dir, s.keysDir, s.stateDir, s.storeDir, s.modulesDir, s.evidenceDir, s.workDir]

proc createLayout*(s: Session): Result[void, string] =
  ## [IMPL] Every directory of the layout, 0700, except `run/` (made at start).
  for d in s.privateDirs:
    ensurePrivateDir(d).isOkOr:
      return err("the session directory is not usable: " & error)
  ok()

proc checkSession*(s: Session): Result[void, string] =
  ## [IMPL] The session exists, holds a daemon-config, and every directory of
  ## the layout is owner-only (created when missing, below the root).
  if not dirExists(s.dir):
    return err(s.dir & " is not a session: run logosctl init")
  ensurePrivateDir(s.dir).isOkOr:
    return err("the session directory is not usable: " & error)
  if not fileExists(s.configPath):
    return err(s.dir & " has no " & DaemonConfigName & ": run logosctl init")
  createLayout(s)

proc lockSession*(s: Session): Result[DurableLock, string] =
  ## The session's lock, held until released: logosd while it runs, an
  ## offline writer while it writes.
  acquire(s.dir).mapErr(
    proc(e: string): string =
      if "in use" in e: SessionBusy else: e
  )

proc readSessionFile*(
    path: string, maxBytes = MaxConfigBytes
): Result[Opt[seq[byte]], string] =
  ## [IMPL] A session file, refused when it is not a regular file owned by
  ## this user with mode 0600 (a link is refused, never followed). None when
  ## the file is absent.
  when defined(posix):
    var st: Stat
    if lstat(cstring(path), st) != 0:
      if errno == ENOENT:
        return ok(Opt.none(seq[byte]))
      return err(path & " cannot be read: " & $strerror(errno))
    if not S_ISREG(st.st_mode):
      return err(path & " is not a regular file")
    if st.st_uid != getuid():
      return err(path & " is owned by another user")
    if (int(st.st_mode) and 0o077) != 0:
      return err(path & " is accessible to group or other")
  readBounded(path, maxBytes)

when defined(posix):
  proc removeTree(path: string): Result[void, string] =
    ## Removes `path` without following any link: a link is unlinked, a real
    ## directory emptied the same way, then removed.
    var st: Stat
    if lstat(cstring(path), st) != 0:
      if errno == ENOENT:
        return ok()
      return err("cannot inspect " & path & ": " & $strerror(errno))
    if not S_ISDIR(st.st_mode):
      if unlink(cstring(path)) != 0 and errno != ENOENT:
        return err("cannot remove " & path & ": " & $strerror(errno))
      return ok()
    var names: seq[string]
    try:
      for kind, p in walkDir(path, relative = true, checkDir = true):
        names.add(p)
    except OSError as e:
      return err("cannot list " & path & ": " & e.msg)
    for n in names:
      ?removeTree(path / n)
    if rmdir(cstring(path)) != 0 and errno != ENOENT:
      return err("cannot remove " & path & ": " & $strerror(errno))
    ok()

proc resetRunDir*(s: Session): Result[void, string] =
  ## [IMPL] `run/` emptied and made again, 0700, while logosd holds the lock
  ## and before the Runtime exists (TRANSPORT l.1120), so a socket left by a
  ## killed daemon never blocks a restart. No link is followed. `work/` is
  ## never emptied: it holds the Module Hosts' restart locks (G275).
  when defined(posix):
    ?removeTree(s.runDir)
  ensurePrivateDir(s.runDir).isOkOr:
    return err(error)
  ensurePrivateDir(s.endpointDir).isOkOr:
    return err(error)
  ok()

{.pop.}
