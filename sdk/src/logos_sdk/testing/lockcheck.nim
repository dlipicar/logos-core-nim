## Whether each install Nimble chose carries the checksum a lock records [IMPL] (DECISIONS G436):
## a check for mismatches, not evidence against tampering.
##
## Nimble 0.26.2 never compares a lock's checksums with what it installs: it takes an install by
## name, version and revision (draft #191). Nimble names the directory it installs a package into
## `<name>-<version>-<sha1>`, after the checksum it computed over the package's tracked files at
## install, and `nimble.paths` names those directories. So comparing each one's suffix with the
## lock's `checksums.sha1` shows whether every install was made from content with the lock's
## checksum: one made from other content, a renamed directory, a lock moved since setup and a second
## install of one version all show.
##
## What the suffix does not show: an edit to an installed file after the install, since the
## directory keeps its name and passes; a directory
## copied in, or left from before, under the right name; untracked files in the tree it was
## installed from; and a package's git submodules, which Nimble's checksum leaves out.
##
## `lockMismatches` takes the two files' text and does no I/O, so it runs in Nim's VM too (a
## `const`, a `static` block). `installMismatches` reads them from a project's root. Both return
## one line per finding, empty when everything matches. Only the standard library is imported: a
## checker built from the installs it judges would prove nothing.

import std/[json, os, strutils]

type Install* = object ## an install directory `nimble.paths` names
  dir*: string ## the path as `nimble.paths` gives it
  name*, version*, checksum*: string

const setupHint* = "run `nimble --useSystemNim setup -l`"

proc nimblePaths*(text: string): seq[string] =
  ## The directories a `nimble.paths` file adds to the search path. Nimble writes each as a Nim
  ## string literal, so on Windows its `\` comes doubled.
  for line in text.splitLines:
    let entry = line.strip
    if entry.startsWith("--path:\""):
      try:
        result.add unescape(entry["--path:".len .. ^1])
      except ValueError:
        result.add entry["--path:".len .. ^1]

proc isSha1(s: string): bool =
  s.len == 40 and s.allCharsInSet(HexDigits)

proc components(path: string): seq[string] =
  for part in path.split({'/', '\\'}):
    if part.len > 0:
      result.add(when defined(windows): part.toLowerAscii else: part)

proc installOf*(path: string, install: var Install): bool =
  ## Whether `path` lies in a `pkgs2/<name>-<version>-<sha1>` install directory (possibly a
  ## subdirectory of it, the package's `srcDir`), and which. The name is read from the right:
  ## the checksum, then the version, and the rest, dashes included, is the name.
  let parts = path.split({'/', '\\'})
  for i in 1 ..< parts.len:
    let part = parts[i]
    if parts[i - 1] != "pkgs2" or part.len < 44 or part[^41] != '-' or
        not isSha1(part[^40 .. ^1]):
      continue
    let rest = part[0 ..< part.len - 41]
    let dash = rest.rfind('-')
    if dash <= 0 or dash == rest.high:
      continue
    install = Install(
      dir: path,
      name: rest[0 ..< dash],
      version: rest[dash + 1 .. ^1],
      checksum: part[^40 .. ^1],
    )
    return true
  false

proc samePath(a, b: string): bool =
  b.len > 0 and components(a) == components(b)

proc lockMismatches*(
    lockText, pathsText: string,
    developLinks: openArray[string] = [],
    ownDir = "",
    linkNames: openArray[(string, string)] = [],
): seq[string] =
  ## Every locked package but `nim` (never installed: every command passes `--useSystemNim`) has
  ## a checksum in the lock and exactly one install, whose checksum is the lock's, and whose
  ## version is the lock's when that is a plain version (a `#commit` entry installs under the
  ## package's declared version). No install is of a package the lock lacks.
  ##
  ## Every other directory `nimble.paths` names is either `ownDir`, the project's own source
  ## directory (its root joined with its `srcDir`, which Nimble lists too), or a `nimble develop`
  ## link of a package `developLinks` names. `linkNames` gives the package each such directory
  ## holds, as (path, name); the caller writes `developLinks` in its own code, never from the
  ## environment.
  var lock: JsonNode
  try:
    lock = parseJson(lockText)
  except CatchableError as e:
    return @["nimble.lock is not JSON: " & e.msg]
  if lock.kind != JObject or lock{"packages"}.isNil or lock["packages"].kind != JObject:
    return @["nimble.lock has no `packages` object"]
  let packages = lock["packages"]
  var
    installs: seq[Install]
    linked: seq[string]
  for path in nimblePaths(pathsText):
    var install: Install
    if installOf(path, install):
      installs.add install
    elif not samePath(path, ownDir):
      var name = ""
      for (dir, linkName) in linkNames:
        if dir == path:
          name = linkName
      if name.len > 0 and name in developLinks:
        linked.add name
      else:
        result.add path &
          ": nimble.paths names a directory that is neither a Nimble install " &
          "(`pkgs2/<name>-<version>-<sha1>`) nor this project's own" & (
          if name.len > 0:
          ", a develop link of " & name & ", which is not listed as one"
          else: ""
        )
  for link in developLinks:
    if not packages.hasKey(link):
      result.add link & ": listed as a develop link, but nimble.lock has no such package"
  for name, entry in packages:
    if name == "nim":
      continue
    let want = entry{"checksums", "sha1"}.getStr
    if not isSha1(want):
      result.add name & ": nimble.lock records no SHA-1 checksum for it (" &
        (if want.len == 0: "none" else: want) & ")"
      continue
    var mine: seq[Install]
    for install in installs:
      if install.name == name:
        mine.add install
    if mine.len == 0:
      if name notin linked:
        result.add name & ": in nimble.lock, but nimble.paths names no install of it" &
          (if name in developLinks: " nor a develop link" else: "") & "; " & setupHint
      continue
    if mine.len > 1:
      var dirs: seq[string]
      for install in mine:
        dirs.add install.dir
      result.add name & ": nimble.paths names " & $mine.len & " installs of it: " &
        dirs.join(", ")
      continue
    if mine[0].checksum != want:
      result.add name & ": nimble.paths names " & mine[0].dir &
        ", but nimble.lock records checksum " & want &
        "; if nimble.lock changed since setup ran, " & setupHint
    let version = entry{"version"}.getStr
    if not version.startsWith("#") and mine[0].version != version:
      result.add name & ": nimble.paths names version " & mine[0].version &
        ", but nimble.lock has " & version & "; if nimble.lock changed since setup ran, " &
        setupHint
  for install in installs:
    if not packages.hasKey(install.name):
      result.add install.dir &
        ": nimble.paths names an install nimble.lock does not have; " &
        "if nimble.lock changed since setup ran, " & setupHint

proc srcDirOf(root: string): string =
  ## `root` joined with the `srcDir` its one nimble file declares, or `root` itself.
  var found: seq[string]
  for file in walkFiles(root / "*.nimble"):
    found.add file
  if found.len == 1:
    for line in readFile(found[0]).splitLines:
      let entry = line.strip
      if entry.startsWith("srcDir") and '=' in entry:
        let value = entry[entry.find('=') + 1 .. ^1].strip
        if value.len >= 2 and value[0] == '"' and value[^1] == '"':
          return root / value[1 ..< value.high]
  root

proc nimbleNameAt(dir: string): string =
  ## The package a develop link's directory holds: the one nimble file in it or in one of its two
  ## parents (a `srcDir` such as `src` or `src/x`).
  var at = dir
  for _ in 0 .. 2:
    var found: seq[string]
    for file in walkFiles(at / "*.nimble"):
      found.add file
    if found.len == 1:
      return found[0].splitFile.name
    if found.len > 1:
      return ""
    let parent = at.parentDir
    if parent.len == 0 or parent == at:
      return ""
    at = parent
  ""

proc installMismatches*(
    root: string, developLinks: openArray[string] = []
): seq[string] =
  ## `lockMismatches` over `root`'s `nimble.lock` and `nimble.paths`, with `root`'s `srcDir` as the
  ## project's own directory and each other directory's package read from the nimble file in it or
  ## above it. A missing `nimble.paths`, or one whose install directories are gone, is one finding:
  ## Nimble's setup has not run there.
  let
    lockPath = root / "nimble.lock"
    pathsPath = root / "nimble.paths"
  if not fileExists(lockPath):
    return @[lockPath & " is missing"]
  if not fileExists(pathsPath):
    return
      @[pathsPath & " is missing, so Nimble's setup has not run here; " & setupHint]
  let
    pathsText = readFile(pathsPath)
    ownDir = srcDirOf(root)
  var
    gone: seq[string]
    linkNames: seq[(string, string)]
  for path in nimblePaths(pathsText):
    var install: Install
    if installOf(path, install):
      if not dirExists(path):
        gone.add path
    elif not samePath(path, ownDir) and dirExists(path):
      linkNames.add (path, nimbleNameAt(path))
  if gone.len > 0:
    let what =
      if gone.len == 1:
        "an install directory that does not exist, " & gone[0]
      else:
        $gone.len & " install directories that do not exist (the first: " & gone[0] & ")"
    return @[
      pathsPath & " names " & what &
        ", so Nimble's setup has not run here or its installs were removed; " & setupHint
    ]
  lockMismatches(readFile(lockPath), pathsText, developLinks, ownDir, linkNames)
