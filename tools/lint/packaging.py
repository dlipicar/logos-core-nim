#!/usr/bin/env python3
"""Keeps the monorepo's two Nimble packages honest (DECISIONS G433-G436).

[IMPL] The SDK (`sdk/logos_sdk.nimble`) and core (`logos_core.nimble`) are installed by Nimble from
this repository. Core does not require the SDK (G434): its exact pins hold every SDK requirement, and
this lint checks that they do. The rules:

  install-list     every file under a package's srcDir is one its install list installs, by Nimble
                   0.26.2's whitelist rules: `installFiles` and `installDirs` relative to srcDir, then
                   any file whose extension, compared case-sensitively, is in `installExt`;
                   `skipDirs` and `skipFiles` do not apply in that mode (packageinfo.nim:499-603).
                   A listed file or directory that is missing fails too
  task-requires    no nimble file uses `taskRequires` (Nix's lock reader drops task requirements)
  own-requirement  no nimble file here requires one of our packages: not by name, not by URL, not by
                   `#commit` or `file://` (G434)
  nim-exact        core's `nim` requirement is exact (the flake reads it)
  nim-windows      `tools/ci/windows.ps1`'s `$NimVersion` is core's pin: Nimble never compares the
                   compiler with the requirement, and on Windows nothing else does
  lock-in-range    each version `nimble.lock` holds for a package the SDK requires lies inside the
                   SDK's range; for `nim`, which the lock does not hold, core's pin does
  lock-complete    no `nimble.lock` entry has an empty `url` or `vcsRevision`, and each has a SHA-1
                   checksum: `tools/check_installs.nim` compares the installs with it (G436)
  lock-nim         `nimble.lock` has no `nim` entry: one means a lock made without `--useSystemNim`
  system-nim       every Nimble command in CI's files, README.md and the module guide carries
                   `--useSystemNim` (off while SYSTEM_NIM_PENDING, which fails once it is stale)
  sdk-imports      every package `sdk/src` imports that the lock holds is one the SDK requires: core
                   requires it otherwise, and a module repository would not have it
  version          the daemon's fallback version is core's with `-dev`, and `flake.nix` writes no
                   version for one of our packages (a `nimDerivation`, or `daemonVersion`,
                   `coreVersion`, `sdkVersion`): it reads the nimble files. A line ending in
                   `# lint-packaging: not ours` is skipped
  nimble-guard     each nimble file stops a Nimble older than 0.26, except those in UNGUARDED (which
                   must not have it, so the list cannot go stale)
  address          no address of one of our repositories (the account followed by a slash, in any
                   spelling; a local path through a home directory of that name matches too, and a
                   tracked file names no local path either) outside a nimble file's `requires` line,
                   a `flake.nix` input's `url`, the tool-written `nimble.lock`, `flake.lock` and
                   `nix/nimble-deps.json`, and the decision record
  address-form     an address in a `requires` line or a flake input has the one spelling:
                   `https://github.com/<account>/<repo>` or `github:<account>/<repo>`, lower case,
                   no suffix, no query (Nimble keys its download cache by the URL)

  python3 tools/lint/packaging.py [--root DIR]
  python3 tools/lint/packaging.py --self-test

Prints `file:line: rule: ...` for each finding and exits 1 if there is any. A root that is not a
directory, or one with no nimble file, exits 2: the lint was run from the wrong folder. In a git
checkout the install-list rule reads `git ls-files`; elsewhere (a Nix source) it walks the tree.
"""

import argparse
import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile

OUR_NAMES = {"logos_sdk", "logos_core", "logos_daemon"}
# Our repositories' owner on GitHub, assembled so this file is not itself a hit. Every spelling of
# one of our repositories has the account followed by a slash: https, SSH, a flake input, the bare
# `account/repository`.
OWNER = "dlipi" + "car"
ADDRESS = re.compile(r"(?<![\w.-])" + OWNER + r"/", re.IGNORECASE)
CANONICAL_NIMBLE = re.compile(r"^https://github\.com/" + OWNER + r"/[a-z0-9][a-z0-9-]*$")
CANONICAL_FLAKE = re.compile(r"^github:" + OWNER + r"/[a-z0-9][a-z0-9-]*$")
SDK_NIMBLE = os.path.join("sdk", "logos_sdk.nimble")
CORE_NIMBLE = "logos_core.nimble"
LOCK = "nimble.lock"
# Nimble files allowed without the guard: none since W2-P.1 (G436). A file listed here must not have it.
UNGUARDED = set()
GUARD = re.compile(
    r"^when\s*\(\s*NimbleMajor\s*,\s*NimbleMinor\s*\)\s*<\s*\(\s*0\s*,\s*26\s*\)\s*:\s*\n"
    r"\s+\{\.\s*error\s*:",
    re.MULTILINE,
)
SKIPPED_DIRS = {".git", "build", "nimbledeps", "nimcache", "node_modules", "result"}
TOOL_WRITTEN = {LOCK, "flake.lock", os.path.join("nix", "nimble-deps.json")}
# The decision record keeps the addresses G434 chose as they were written.
RECORDS = {os.path.join("docs", "DECISIONS.md")}
WINDOWS_CI = os.path.join("tools", "ci", "windows.ps1")
VERSION_NIM = os.path.join("src", "logos_core", "daemon", "version.nim")
# Where Nimble commands are written for CI and for people.
NIMBLE_COMMAND_FILES = [
    os.path.join(".github", "workflows", "ci.yml"),
    WINDOWS_CI,
    "README.md",
    os.path.join("sdk", "docs", "MODULE-KIT.md"),
]
# Every Nimble command carries `--useSystemNim` since W2-P.1 (G436). The switch stays for the
# self-test, which checks both states.
SYSTEM_NIM_PENDING = False
NIMBLE_COMMAND = re.compile(r"(?<![\w./'-])nimble\s+(?!-v\b|--version\b)[-\w\"$]")


def kept_dirs(dirnames):
    return sorted(d for d in dirnames if d not in SKIPPED_DIRS and not d.startswith("result"))


def nimble_files(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = kept_dirs(dirnames)
        names = [f for f in sorted(filenames) if f.endswith(".nimble")]
        out += [os.path.relpath(os.path.join(dirpath, f), root) for f in names]
    return out


def string_list(text, key):
    """The strings of `key = @[...]` (one or more lines), or None if the key is absent."""
    m = re.search(r"^" + key + r"\s*=\s*@\[(.*?)\]", text, re.MULTILINE | re.DOTALL)
    return re.findall(r'"([^"]*)"', m.group(1)) if m else None


def string_value(text, key, default):
    m = re.search(r"^" + key + r'\s*=\s*"([^"]*)"', text, re.MULTILINE)
    return m.group(1) if m else default


def requirements(text):
    """(line, requirement) for each string of each `requires` statement."""
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        code = line.split("#", 1)[0] if not re.search(r'"[^"]*#', line) else line
        if re.match(r"^\s*requires\b", code):
            out += [(n, s) for s in re.findall(r'"([^"]*)"', line)]
    return out


def split_requirement(req):
    """(name or URL, constraint text)."""
    req = req.strip()
    if "://" in req:
        m = re.match(r"^(\S+)\s*(.*)$", req)
    else:
        m = re.match(r"^(\S+?)\s*((?:[<>=^~]|any\b).*)?$", req)
    return (m.group(1), (m.group(2) or "").strip()) if m else (req, "")


def version_tuple(v):
    parts = re.findall(r"\d+", v)
    return tuple(int(p) for p in parts) if parts else None


def satisfies(version, constraint):
    """Nimble's ranges: `==`, `>=`, `>`, `<=`, `<`, `^=`, `~=` joined by `&`; empty or `any version`."""
    v = version_tuple(version)
    if v is None:
        return False
    if constraint in ("", "any version"):
        return True

    def pad(t, n=4):
        return t + (0,) * (n - len(t))

    v = pad(v)
    for part in constraint.split("&"):
        m = re.match(r"^\s*(==|>=|<=|>|<|\^=|~=)\s*(\S+)\s*$", part)
        if not m or version_tuple(m.group(2)) is None:
            return False
        op, bound = m.group(1), pad(version_tuple(m.group(2)))
        if op == "^=":
            i = next((k for k, x in enumerate(bound) if x != 0), len(bound) - 1)
            upper = bound[:i] + (bound[i] + 1,) + (0,) * (len(bound) - i - 1)
            ok = bound <= v < upper
        elif op == "~=":
            given = len(version_tuple(m.group(2)))
            i = max(given - 2, 0)
            upper = pad(bound[:i] + (bound[i] + 1,))
            ok = bound <= v < upper
        else:
            ok = {
                "==": v == bound,
                ">=": v >= bound,
                "<=": v <= bound,
                ">": v > bound,
                "<": v < bound,
            }[op]
        if not ok:
            return False
    return True


def is_ours(name):
    low = name.lower()
    if low.startswith("file://") or ADDRESS.search(low):
        return True
    return low.split("#", 1)[0].split("@", 1)[0] in OUR_NAMES


def strip_comment(line):
    """The line up to a `#` outside a string literal."""
    quoted = False
    for i, ch in enumerate(line):
        if ch == '"':
            quoted = not quoted
        elif ch == "#" and not quoted:
            return line[:i]
    return line


def nim_imports(text):
    """(line, module path) for each module an `import`, `from` or `include` statement names."""
    text = re.sub(r"#\[.*?\]#", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.DOTALL)
    lines = text.splitlines()
    out = []
    i = 0
    while i < len(lines):
        m = re.match(r"^\s*(import|from|include)\b(.*)$", strip_comment(lines[i]))
        i += 1
        if not m:
            continue
        start, stmt = i, m.group(2)
        while i < len(lines) and (
            stmt.count("[") > stmt.count("]") or stmt.rstrip().endswith(",") or not stmt.strip()
        ):
            stmt += " " + strip_comment(lines[i])
            i += 1
        if m.group(1) == "from":
            out += [(start, w) for w in stmt.split()[:1]]
            continue
        depth, item, items = 0, "", []
        for ch in re.split(r"\bexcept\b", stmt)[0]:
            depth += {"[": 1, "]": -1}.get(ch, 0)
            if ch == "," and depth == 0:
                items.append(item)
                item = ""
            else:
                item += ch
        items.append(item)
        for it in items:
            it = re.split(r"\s+as\s+", it.strip())[0].split("[")[0].strip().strip('"')
            if it:
                out.append((start, it))
    return out


def import_root(path):
    """The package a module path starts with, or None for a relative path."""
    if path.startswith((".", "/")):
        return None
    parts = [p for p in path.split("/") if p]
    if parts and parts[0] == "pkg":
        parts = parts[1:]
    return parts[0] if parts else None


def nimble_commands(rel, text):
    """(line, number of Nimble commands, number of `--useSystemNim`) for each line with a command:
    code lines of CI's files, and the lines of a Markdown file's fenced blocks."""
    out, fenced = [], False
    for n, line in enumerate(text.splitlines(), 1):
        if rel.endswith(".md"):
            if line.lstrip().startswith("```"):
                fenced = not fenced
                continue
            if not fenced:
                continue
        elif line.lstrip().startswith("#") or re.match(r"^\s*-?\s*name:", line):
            continue
        commands = len(NIMBLE_COMMAND.findall(line))
        if commands:
            out.append((n, commands, line.count("--useSystemNim")))
    return out


def git_files(root, subdir):
    """git's list of the files under `subdir`, relative to it, or None outside a checkout."""
    try:
        if subprocess.run(["git", "-C", root, "rev-parse"], capture_output=True).returncode != 0:
            return None
        out = subprocess.run(
            ["git", "-C", root, "ls-files", "-z", "--", subdir],
            capture_output=True, check=True, text=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return sorted(os.path.relpath(p, subdir) for p in out.split("\0") if p)


def tracked_files(root, subdir):
    """Files under `subdir`, relative to it: git's list in a checkout, else a walk."""
    listed = git_files(root, subdir)
    if listed is not None:
        return listed
    found = []
    for dirpath, dirnames, filenames in os.walk(os.path.join(root, subdir)):
        dirnames.sort()
        base = os.path.join(root, subdir)
        found += [os.path.relpath(os.path.join(dirpath, f), base) for f in filenames]
    return sorted(found)


def scanned_files(root):
    """Every file the address rule reads: git's list in a checkout (so no build output, and no
    untracked file such as `nimble.paths`, whose paths may hold the account's name), else a walk
    without build output."""
    listed = git_files(root, ".")
    if listed is not None:
        return listed
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = kept_dirs(dirnames)
        found += [os.path.relpath(os.path.join(dirpath, f), root) for f in sorted(filenames)]
    return found


def check_install_list(root, nimble, text, findings):
    src = os.path.join(os.path.dirname(nimble), string_value(text, "srcDir", ""))
    exts = string_list(text, "installExt") or []
    files = string_list(text, "installFiles") or []
    dirs = string_list(text, "installDirs") or []
    if not (exts or files or dirs):
        message = "no installExt, installFiles or installDirs: Nimble would install everything"
        findings.append((nimble, 1, "install-list", message))
        return 0
    for f in files:
        if not os.path.isfile(os.path.join(root, src, f)):
            findings.append((nimble, 1, "install-list", f"installFiles names a missing file: {f}"))
    for d in dirs:
        if not os.path.isdir(os.path.join(root, src, d)):
            findings.append((nimble, 1, "install-list", f"installDirs names a missing directory: {d}"))
    tracked = tracked_files(root, src)
    for rel in tracked:
        posix = rel.replace(os.sep, "/")
        ext = os.path.splitext(os.path.basename(rel))[1][1:]
        if posix in files or any(posix.startswith(d.rstrip("/") + "/") for d in dirs) or ext in exts:
            continue
        message = f"{nimble} would not install this file"
        findings.append((os.path.join(src, rel), 1, "install-list", message))
    return len(tracked)


OUR_VERSION_NAMES = r'\b(?:daemon|core|sdk)Version\s*=\s*"\d'
NOT_OURS = "# lint-packaging: not ours"


def ours_in_flake(text):
    """(line number, line) for each line of `flake.nix` that belongs to one of our packages: the
    lines of a `nimDerivation` call, from its line to the brace that closes its attribute set, and
    every other line, where only the version names of ours are looked for. A line ending in
    NOT_OURS is left out."""
    out, depth, inside, opened = [], 0, False, False
    for n, line in enumerate(text.splitlines(), 1):
        if not inside and re.search(r"\bnimDerivation\b", line):
            inside, depth, opened = True, 0, False
        if inside:
            for ch in line:
                if ch == "{":
                    depth += 1
                    opened = True
                elif ch == "}":
                    depth -= 1
        if not line.rstrip().endswith(NOT_OURS):
            if inside or re.search(OUR_VERSION_NAMES, line):
                out.append((n, line))
        if inside and opened and depth <= 0:
            inside = False
    return out


def read_text(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8") as f:
        return f.read()


def check(root, system_nim_pending=SYSTEM_NIM_PENDING, unguarded=None):
    unguarded = UNGUARDED if unguarded is None else unguarded
    findings = []
    nimbles = nimble_files(root)
    texts = {}
    for nimble in nimbles:
        with open(os.path.join(root, nimble), encoding="utf-8") as f:
            texts[nimble] = f.read()
    installed = 0
    for nimble in (SDK_NIMBLE, CORE_NIMBLE):
        if nimble not in texts:
            findings.append((nimble, 1, "install-list", "the package's nimble file is missing"))
            continue
        installed += check_install_list(root, nimble, texts[nimble], findings)

    for nimble, text in texts.items():
        for n, line in enumerate(text.splitlines(), 1):
            if re.match(r"^\s*taskRequires\b", line):
                findings.append((nimble, n, "task-requires", "taskRequires is not allowed"))
        for n, req in requirements(text):
            name, _ = split_requirement(req)
            if is_ours(name):
                findings.append((nimble, n, "own-requirement", f"requires one of our packages: {req!r}"))
        guarded = bool(GUARD.search(text))
        if nimble in unguarded and guarded:
            message = "has the guard but is still listed in UNGUARDED"
            findings.append((nimble, 1, "nimble-guard", message))
        elif nimble not in unguarded and not guarded:
            message = "no `when (NimbleMajor, NimbleMinor) < (0, 26): {.error.}` guard"
            findings.append((nimble, 1, "nimble-guard", message))

    core_nim = None
    if CORE_NIMBLE in texts:
        for n, req in requirements(texts[CORE_NIMBLE]):
            name, constraint = split_requirement(req)
            if name == "nim":
                if not re.match(r"^==\s*\d+\.\d+\.\d+$", constraint):
                    message = f"core's nim requirement is not exact: {req!r}"
                    findings.append((CORE_NIMBLE, n, "nim-exact", message))
                else:
                    core_nim = constraint[2:].strip()
    if core_nim and os.path.isfile(os.path.join(root, WINDOWS_CI)):
        m = re.search(r"^\$NimVersion\s*=\s*'([^']*)'", read_text(root, WINDOWS_CI), re.MULTILINE)
        if not m:
            findings.append((WINDOWS_CI, 1, "nim-windows", "no `$NimVersion = '...'` line"))
        elif m.group(1) != core_nim:
            line = read_text(root, WINDOWS_CI)[: m.start()].count("\n") + 1
            message = f"$NimVersion is {m.group(1)}, but core pins Nim {core_nim}"
            findings.append((WINDOWS_CI, line, "nim-windows", message))

    lock_path = os.path.join(root, LOCK)
    lock = {}
    if os.path.isfile(lock_path):
        with open(lock_path, encoding="utf-8") as f:
            lock = json.load(f).get("packages", {})
        if "nim" in lock:
            message = "a `nim` entry: the lock was made without --useSystemNim; lock again with it"
            findings.append((LOCK, 1, "lock-nim", message))
        for name, entry in lock.items():
            if name == "nim":
                continue
            for key in ("url", "vcsRevision"):
                if not entry.get(key):
                    findings.append((LOCK, 1, "lock-complete", f"{name}: empty {key}"))
            sha1 = (entry.get("checksums") or {}).get("sha1") or ""
            if not re.fullmatch(r"[0-9a-f]{40}", sha1):
                message = f"{name}: no SHA-1 checksum ({sha1 or 'none'})"
                findings.append((LOCK, 1, "lock-complete", message))
    else:
        findings.append((LOCK, 1, "lock-in-range", "no nimble.lock"))
    if SDK_NIMBLE in texts:
        for n, req in requirements(texts[SDK_NIMBLE]):
            name, constraint = split_requirement(req)
            if is_ours(name):
                continue
            held = core_nim if name == "nim" else lock.get(name, {}).get("version")
            where = "core's nim pin" if name == "nim" else "nimble.lock"
            if held is None:
                findings.append((SDK_NIMBLE, n, "lock-in-range", f"{name} is not in {where}"))
            elif not satisfies(held, constraint):
                message = f"{where} holds {name} {held}, outside {constraint!r}"
                findings.append((SDK_NIMBLE, n, "lock-in-range", message))

    sdk_requires = set()
    if SDK_NIMBLE in texts:
        sdk_requires = {split_requirement(r)[0].lower() for _, r in requirements(texts[SDK_NIMBLE])}
    sdk_src = os.path.join("sdk", string_value(texts.get(SDK_NIMBLE, ""), "srcDir", ""))
    for rel in tracked_files(root, sdk_src) if os.path.isdir(os.path.join(root, sdk_src)) else []:
        if not rel.endswith(".nim"):
            continue
        path = os.path.join(sdk_src, rel)
        for n, module in nim_imports(read_text(root, path)):
            package = (import_root(module) or "").lower()
            if package in lock and package != "nim" and package not in sdk_requires:
                message = f"imports {module}, but {SDK_NIMBLE} does not require {package}"
                findings.append((path, n, "sdk-imports", message))

    commands = []
    for rel in NIMBLE_COMMAND_FILES:
        if os.path.isfile(os.path.join(root, rel)):
            commands += [(rel, n, c, f) for n, c, f in nimble_commands(rel, read_text(root, rel))]
    missing = [(rel, n) for rel, n, c, f in commands if f < c]
    if not system_nim_pending:
        for rel, n in missing:
            findings.append((rel, n, "system-nim", "a Nimble command without --useSystemNim"))
    elif commands and not missing:
        message = "every Nimble command has --useSystemNim: set SYSTEM_NIM_PENDING to False"
        findings.append(("tools/lint/packaging.py", 1, "system-nim", message))

    core_version = string_value(texts.get(CORE_NIMBLE, ""), "version", "")
    if core_version and os.path.isfile(os.path.join(root, VERSION_NIM)):
        text = read_text(root, VERSION_NIM)
        m = re.search(r'\belse:\s*"([^"]*)"', text)
        want = core_version + "-dev"
        if not m or m.group(1) != want:
            line = text[: m.start()].count("\n") + 1 if m else 1
            message = f"the fallback version is {m.group(1) if m else None!r}, not {want!r}"
            findings.append((VERSION_NIM, line, "version", message))
    if os.path.isfile(os.path.join(root, "flake.nix")):
        for n, line in ours_in_flake(read_text(root, "flake.nix")):
            if re.search(r'\bversion\s*=\s*"\d', line) or re.search(OUR_VERSION_NAMES, line):
                message = (
                    "a version of one of our packages written here: read it from its nimble file"
                    " (versionOf); a third-party package's line ends in `# lint-packaging: not ours`"
                )
                findings.append(("flake.nix", n, "version", message))

    scanned = 0
    for rel in scanned_files(root):
        if rel in TOOL_WRITTEN or rel in RECORDS:
            continue
        try:
            with open(os.path.join(root, rel), encoding="utf-8") as f:
                lines = f.read().splitlines()
        except (UnicodeDecodeError, OSError):
            continue
        scanned += 1
        for n, line in enumerate(lines, 1):
            if not ADDRESS.search(line):
                continue
            spellings = []
            if rel.endswith(".nimble") and re.match(r"^\s*requires\b", line):
                names = [split_requirement(r)[0] for r in re.findall(r'"([^"]*)"', line)]
                spellings = [(x, CANONICAL_NIMBLE) for x in names if ADDRESS.search(x)]
            elif rel == "flake.nix" and re.search(r'\burl\s*=\s*"', line):
                urls = re.findall(r'\burl\s*=\s*"([^"]*)"', line)
                spellings = [(x, CANONICAL_FLAKE) for x in urls if ADDRESS.search(x)]
            if spellings:
                for spelling, canonical in spellings:
                    if not canonical.match(spelling):
                        message = f"not the one spelling of the address: {spelling!r}"
                        findings.append((rel, n, "address-form", message))
                continue
            message = (
                "an address of one of our repositories outside the places G434 allows (or a local"
                " path through a home directory of the account's name: no tracked file names one)"
            )
            findings.append((rel, n, "address", message))
    return findings, (len(nimbles), installed, scanned)


# Self-test --------------------------------------------------------------------

GUARD_TEXT = """when (NimbleMajor, NimbleMinor) < (0, 26):
  {.error: "this package needs Nimble >= 0.26".}
"""
GOOD_SDK = """version = "0.1.0"
srcDir = "src"
installExt = @["nim", "cddl"]
installFiles = @[
  "logos_sdk/LICENSE",
]
""" + GUARD_TEXT + """requires "nim >= 2.2.14 & < 2.3.0"
requires "results >= 0.5.0 & < 0.6.0"
requires "chronos >= 4.4.0 & < 4.5.0"
"""
GOOD_CORE = (
    """version = "0.1.0"
srcDir = "src"
installExt = @["nim"]
requires "nim == 2.2.14"
requires "chronos == 4.4.1"
"""
    + GUARD_TEXT
)


def lock_entry(version, url):
    return {"version": version, "vcsRevision": "40f8087c", "url": url, "downloadMethod": "git",
            "dependencies": [], "checksums": {"sha1": "38d45a837f3a9d51e5851615322bf48c90f7ac69"}}


LOCK_PACKAGES = {
    "chronos": lock_entry("4.4.1", "https://github.com/status-im/nim-chronos"),
    "results": lock_entry("0.5.1", "https://github.com/arnetheduck/nim-results"),
    "stew": lock_entry("0.5.2", "https://github.com/status-im/nim-stew"),
}
GOOD_LOCK = json.dumps({"version": 2, "packages": LOCK_PACKAGES})
URL = "https://github.com/" + OWNER + "/logos-sdk-nim"
CLEAN_TREE = {
    "logos_core.nimble": GOOD_CORE,
    "nimble.lock": GOOD_LOCK,
    "src/logos_core.nim": "",
    "src/logos_core/a.nim": "",
    "src/logos_core/daemon/version.nim": 'const v* = if false: "" else: "0.1.0-dev"\n',
    "sdk/logos_sdk.nimble": GOOD_SDK,
    "sdk/src/logos_sdk.nim": (
        "import std/[os, strutils]\n"
        "import\n  chronos/[asyncloop, timer], # stew/byteutils in a comment\n  ./logos_sdk/b\n"
        "from results import Result\n"
        "#[ import stew/endians2 ]#\n"
        'const s = "import stew"\n'
    ),
    "sdk/src/logos_sdk/b.nim": "include stew_like_local\n",
    "sdk/src/logos_sdk/LICENSE": "",
    "sdk/src/logos_sdk/c.cddl": "",
    "README.md": (
        "Run `nimble test` by hand.\n\n```bash\nnimble --useSystemNim setup -l\n"
        "rm nimble.lock && nimble --useSystemNim -y lock\n```\n"
    ),
    "tools/ci/windows.ps1": (
        "# `nimble test`\n$NimVersion = '2.2.14'\n"
        "Invoke-Native 'nimble -v' { nimble -v }\n"
        "Invoke-Native 'nimble setup -l' { nimble --useSystemNim -y setup -l }\n"
    ),
    "docs/DECISIONS.md": "**Decision:** `" + OWNER + "/logos-core-nim`, transferred later.\n",
    "flake.nix": (
        '{ inputs.sdk.url = "github:' + OWNER + '/logos-sdk-nim";\n'
        '  tool = pkgs.stdenv.mkDerivation { pname = "tool"; version = "1.2"; };\n'
        '  other = nimDerivation {\n    pname = "other";\n'
        '    version = "3.0"; # lint-packaging: not ours\n  };\n'
        '  lcnGen = nimDerivation { pname = "lcn-gen"; version = sdkVersion; };\n}\n'
    ),
    "flake.lock": '{ "owner": "' + OWNER + '", "url": "https://github.com/' + OWNER + '/x" }\n',
}
NIM_LOCK = json.dumps({"version": 2, "packages": dict(LOCK_PACKAGES, nim=lock_entry("2.2.14", "x"))})
PLANTS = [
    ("install-list", "sdk/src/logos_sdk/x.c", ""),
    ("install-list", "sdk/src/logos_sdk/k.CDDL", ""),
    ("install-list", "src/logos_core/LICENSE", ""),
    ("install-list", "sdk/logos_sdk.nimble", GOOD_SDK.replace("LICENSE", "MISSING")),
    ("task-requires", "sdk/logos_sdk.nimble", GOOD_SDK + 'taskRequires "test", "unittest2"\n'),
    ("own-requirement", "logos_core.nimble", GOOD_CORE + 'requires "logos_sdk >= 0.1.0 & < 0.2.0"\n'),
    ("own-requirement", "logos_core.nimble", GOOD_CORE + 'requires "file://./sdk"\n'),
    ("own-requirement", "logos_core.nimble", GOOD_CORE + 'requires "logos_sdk#abc123"\n'),
    ("own-requirement", "tools/x/x.nimble", 'requires "' + URL + '?subdir=sdk >= 0.1.0"\n'),
    ("nim-exact", "logos_core.nimble", GOOD_CORE.replace("nim == 2.2.14", "nim >= 2.2.14")),
    ("lock-in-range", "logos_core.nimble", GOOD_CORE.replace("nim == 2.2.14", "nim == 2.3.0")),
    ("lock-in-range", "nimble.lock", GOOD_LOCK.replace('"4.4.1"', '"4.5.0"')),
    ("lock-in-range", "sdk/logos_sdk.nimble", GOOD_SDK + 'requires "bearssl >= 0.2.0"\n'),
    ("lock-complete", "nimble.lock", GOOD_LOCK.replace('"40f8087c"', '""')),
    ("lock-complete", "nimble.lock", GOOD_LOCK.replace("https://github.com/status-im/nim-chronos", "")),
    ("lock-complete", "nimble.lock", GOOD_LOCK.replace("38d45a837f3a9d51e5851615322bf48c90f7ac69", "")),
    ("lock-complete", "nimble.lock", GOOD_LOCK.replace("38d45a837f3a9d51e5851615322bf48c90f7ac69", "38d45a83")),
    ("nimble-guard", "sdk/logos_sdk.nimble", GOOD_SDK.replace("when (NimbleMajor", "when (NimbleMinor")),
    ("nimble-guard", "logos_core.nimble", GOOD_CORE.replace(GUARD_TEXT, "")),
    ("address", "README.md", "See " + URL + ".\n"),
    ("address", "docs/x.md", "git@github.com:" + OWNER + "/logos-core-nim.git\n"),
    ("address", "flake.nix", '{ description = "' + URL + '"; }\n'),
    ("address", "docs/y.md", "It moves to " + OWNER + "/logos-sdk-nim later.\n"),
    ("address-form", "flake.nix", '{ inputs.sdk.url = "git+https://github.com/' + OWNER + '/x"; }\n'),
    ("address-form", "flake.nix", '{ inputs.sdk.url = "github:' + OWNER + '/Logos-SDK-nim"; }\n'),
    ("address-form", "tools/x/x.nimble", 'requires "' + URL + '.git >= 0.1.0"\n'),
    ("nim-windows", "tools/ci/windows.ps1", "$NimVersion = '2.2.12'\n"),
    ("nim-windows", "tools/ci/windows.ps1", "$Nim = '2.2.14'\n"),
    ("lock-nim", "nimble.lock", NIM_LOCK),
    ("system-nim", "README.md", "```bash\nnimble test && nimble --useSystemNim test_refc\n```\n"),
    ("system-nim", "tools/ci/windows.ps1", "$NimVersion = '2.2.14'\n{ nimble -y setup -l }\n"),
    ("system-nim", ".github/workflows/ci.yml", "      - run: nix develop -c nimble \"$TASK\"\n"),
    ("sdk-imports", "sdk/src/logos_sdk/b.nim", "import stew/byteutils\n"),
    ("sdk-imports", "sdk/src/logos_sdk/b.nim", "import\n  std/os,\n  pkg/stew/[endians2, objects]\n"),
    ("sdk-imports", "sdk/src/logos_sdk/b.nim", "from stew/objects import nil\n"),
    ("version", "src/logos_core/daemon/version.nim", 'const v* = if false: "" else: "0.0.1-dev"\n'),
    ("version", "flake.nix", '{ x = nimDerivation { pname = "lcn-gen"; version = "0.0.1"; }; }\n'),
    ("version", "flake.nix", '{ x = nimDerivation (\n  {\n    pname = "y";\n    version = "0.1";\n  }\n); }\n'),
    ("version", "flake.nix", '{ daemonVersion = "0.1.0"; }\n'),
]
SATISFIES = [
    ("4.4.1", ">= 4.4.0 & < 4.5.0", True), ("4.5.0", ">= 4.4.0 & < 4.5.0", False),
    ("2.2.14", "== 2.2.14", True), ("0.5.1", "^= 0.5.0", True), ("0.6.0", "^= 0.5.0", False),
    ("1.2.9", "~= 1.2.3", True), ("1.3.0", "~= 1.2.3", False), ("0.1.0", "", True), ("x", "", False),
]


def plant_tree(root, tree):
    for path, text in tree.items():
        full = os.path.join(root, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as f:
            f.write(text)


def self_test():
    failures = []
    for version, constraint, want in SATISFIES:
        if satisfies(version, constraint) != want:
            failures.append(f"satisfies({version!r}, {constraint!r}) is not {want}")

    def run(tree, pending=False, unguarded=None):
        with tempfile.TemporaryDirectory() as root:
            plant_tree(root, tree)
            return check(root, system_nim_pending=pending, unguarded=unguarded)[0]

    clean = run(CLEAN_TREE)
    if clean:
        failures.append(f"the clean tree fails: {clean}")
    stale = run(CLEAN_TREE, pending=True)
    if [f[2] for f in stale] != ["system-nim"]:
        failures.append(f"a pending system-nim rule over a tree that passes it is not reported: {stale}")
    waiting = run(dict(CLEAN_TREE, **{"README.md": "```\nnimble test\n```\n"}), pending=True)
    if waiting:
        failures.append(f"a pending system-nim rule reports: {waiting}")
    listed = run(CLEAN_TREE, unguarded={CORE_NIMBLE})
    if [f[2] for f in listed] != ["nimble-guard"]:
        failures.append(f"a guarded file still listed in UNGUARDED is not reported: {listed}")
    for rule, path, text in PLANTS:
        found = {f[2] for f in run(dict(CLEAN_TREE, **{path: text}))}
        if rule not in found:
            failures.append(f"{rule} did not fire on {path}: {text!r} (found {found})")
    # The two runs that check nothing, and the clean tree through the same entry.
    def status(root):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return lint(root, system_nim_pending=False)

    with tempfile.TemporaryDirectory() as root:
        if status(os.path.join(root, "missing")) != 2:
            failures.append("a missing root did not exit 2")
        if status(root) != 2:
            failures.append("an empty root did not exit 2")
        plant_tree(root, CLEAN_TREE)
        if status(root) != 0:
            failures.append("the clean tree did not exit 0 through lint")
    for failure in failures:
        print("self-test:", failure)
    if failures:
        return 1
    print(
        f"packaging self-test: {len(SATISFIES)} ranges, {len(PLANTS)} planted violations caught,"
        " the pending switch's two states, a stale UNGUARDED, and a missing and an empty root refused"
    )
    return 0


def lint(root, **kw):
    """The exit status over `root`: 0 clean, 1 a finding, 2 nothing to check."""
    if not os.path.isdir(root):
        print(f"packaging: {root}: not a directory", file=sys.stderr)
        return 2
    findings, (nimbles, installed, scanned) = check(root, **kw)
    if not nimbles:
        print(f"packaging: no nimble file under {root}", file=sys.stderr)
        return 2
    for path, line, rule, message in findings:
        print(f"{path}:{line}: {rule}: {message}")
    print(
        f"packaging: {nimbles} nimble files, {installed} package files checked,"
        f" {scanned} files scanned for addresses"
    )
    return 1 if findings else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=".")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    return lint(args.root)


if __name__ == "__main__":
    sys.exit(main())
