## A short private base directory for unix-stream endpoints (4b-2 plan §4.3):
## TMPDIR when the deepest path a suite makes fits `sun_path` and its
## filesystem holds sockets, else /tmp. Mode 0700, as `checkEndpointBase`
## requires. Used by `test_transport_io` and `test_transported`.

import std/[os, strutils]
import ../../src/logos_core/transport/io/sock
when defined(posix):
  import std/posix

proc holdsSockets(dir: string): bool =
  when unixStream:
    let fd = unixSocket()
    let path = dir / "probe.sock"
    result = sockBind(fd, cstring(path)) == 0
    discard fdClose(fd)
    discard unlink(cstring(path))
  else:
    false

proc makeShortBase*(
    prefix: string, deepest = "/12345678/logos_storage_module.sock"
): string =
  ## `<root>/<prefix>-<pid>`, made fresh. `deepest` is the longest path the
  ## caller puts under it.
  var root = getEnv("TMPDIR", "/tmp").strip(leading = false, chars = {'/'})
  let name = prefix & "-" & $getCurrentProcessId()
  if root.len == 0 or root.len + 1 + name.len + deepest.len + 1 > int(sunPathMax()):
    root = "/tmp"
  result = root / name
  removeDir(result)
  createDir(result)
  if not holdsSockets(result) and root != "/tmp":
    removeDir(result)
    result = "/tmp" / name
    removeDir(result)
    createDir(result)
  when defined(posix):
    doAssert chmod(cstring(result), 0o700) == 0
