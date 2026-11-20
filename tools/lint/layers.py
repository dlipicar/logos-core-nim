#!/usr/bin/env python3
"""Holds the import direction between the SDK, core, the daemon and the CLI.

[IMPL] The base set, the generators and the kit sit below core, and the daemon and the CLI
sit above it. Seven rules keep that shape:

  sdk-closed          the SDK imports nothing outside the SDK
  base-below-binding  the SDK's base imports neither `codegen`, `kit` nor `testing`
  kit-facade          what generated kits and calls import (each `kit_facade` root) never
                      reaches `rcclient` or `rc_types`
  core-below-daemon   core imports nothing from the daemon or the CLI
  daemon-no-tls       the daemon's and CLI's closure reaches no TLS engine (owner: no TLS in logosd)
  daemon-allowlist    the daemon and the CLI import only the reviewed core modules
  testing-test-only   only test code imports `logos_sdk/testing`

  python3 tools/lint/layers.py [--config tools/lint/layers.toml]
  python3 tools/lint/layers.py --self-test

Prints `file:line: rule: ...` for each violation and exits 1 if there is any. The layer map,
the allowlist and the recorded exceptions are in `layers.toml`. An exception or an allowlist
entry that no import needs any more is itself a failure, so neither can go stale. With
`strict = true` no exception is accepted and every layer must exist.

Imports are read by a small Nim tokenizer, not by line patterns: comments and string contents
are dropped, and `import`, `from` and `include` count at any indentation, in `when` branches,
with bracket lists on later lines and with the prefix on the line before its bracket.
"""

import argparse
import os
import re
import sys
import tempfile
import tomllib

SCANNED = ("src", "tests", "tools", "sdk")
SEARCH_PATHS = ("src", os.path.join("sdk", "src"))
PATH_OP = re.compile(r"^[./]+$")
OP_CHARS = set("=+-*/<>@$~&%|!?^.:\\")


def tokenize(src):
    """(kind, text, line, start, end) per token: `id`, `str`, `op`, `nl`; no comments."""
    out, i, line, n = [], 0, 1, len(src)

    def skip_block(j, doc):
        nonlocal line
        depth = 1
        while j < n:
            if src[j] == "\n":
                line += 1
            if src.startswith("#[", j):
                depth += 1
                j += 2
            elif src.startswith("]#", j) and (not doc or src.startswith("]##", j)):
                depth -= 1
                j += 3 if doc else 2
                if depth == 0:
                    return j
            else:
                j += 1
        return n

    while i < n:
        c = src[i]
        if c == "\n":
            out.append(("nl", "\n", line, i, i + 1))
            line += 1
            i += 1
        elif c in " \t\r":
            i += 1
        elif c == "#":
            if src.startswith("##[", i):
                i = skip_block(i + 3, True)
            elif src.startswith("#[", i):
                i = skip_block(i + 2, False)
            else:
                while i < n and src[i] != "\n":
                    i += 1
        elif src.startswith('"""', i):
            j = src.find('"""', i + 3)
            j = n if j < 0 else j + 3
            while j < n and src[j] == '"':
                j += 1
            text = src[i + 3 : j - 3]
            out.append(("str", text, line, i, j))
            line += src.count("\n", i, j)
            i = j
        elif c == '"':
            raw = i > 0 and (src[i - 1].isalnum() or src[i - 1] == "_")
            j, text = i + 1, []
            while j < n and src[j] != "\n":
                if not raw and src[j] == "\\":
                    text.append(src[j : j + 2])
                    j += 2
                elif src[j] == '"':
                    if raw and src.startswith('""', j):
                        text.append('"')
                        j += 2
                    else:
                        break
                else:
                    text.append(src[j])
                    j += 1
            out.append(("str", "".join(text), line, i, j + 1))
            i = j + 1
        elif c == "'":
            if i > 0 and (src[i - 1].isalnum() or src[i - 1] == "_"):
                i += 1  # a numeric suffix such as 1'u8
            elif src.startswith("\\", i + 1):
                j = src.find("'", i + 3)
                i = i + 1 if j < 0 or j > i + 6 else j + 1
            elif src.startswith("'", i + 2):
                i += 3
            else:
                i += 1
        elif c == "`":
            j = src.find("`", i + 1)
            j = n if j < 0 else j + 1
            out.append(("op", "`", line, i, j))
            i = j
        elif c.isalnum() or c == "_" or ord(c) >= 0x80:
            j = i
            while j < n and (src[j].isalnum() or src[j] == "_" or ord(src[j]) >= 0x80):
                j += 1
            out.append(("id", src[i:j], line, i, j))
            i = j
        elif c in OP_CHARS:
            j = i
            while j < n and src[j] in OP_CHARS:
                j += 1
            out.append(("op", src[i:j], line, i, j))
            i = j
        else:
            out.append(("op", c, line, i, i + 1))
            i += 1
    return out


def statements(src):
    """Every `import`, `from` and `include` statement, as a list of its items.

    An item is a dict: `path` and its source range `start`, `end`; for a bracket group `path` is
    the prefix, `prefix_end` where the prefix ends, and `members` the (path, start, end, alias)
    of each entry.
    """
    toks = tokenize(src)
    found = []
    n = len(toks)

    def skip_nl(i):
        while i < n and toks[i][0] == "nl":
            i += 1
        return i

    def item(i):
        """One path expression from token i: the item, and the next index."""
        prefix, wants_part = "", True
        start = toks[i][3] if i < n else 0
        end = start
        while i < n:
            kind, text, _, _, tok_end = toks[i]
            if kind == "op" and PATH_OP.match(text):
                prefix += text
                wants_part = text.endswith("/")
                end = tok_end
                i += 1
                if wants_part:
                    i = skip_nl(i)
            elif kind in ("id", "str") and wants_part:
                prefix += text
                wants_part = False
                end = tok_end
                i += 1
            elif kind == "op" and text == "[" and wants_part:
                prefix_end = end
                i = skip_nl(i + 1)
                members = []
                while i < n and toks[i][1] != "]":
                    sub, i = item(i)
                    alias = None
                    i = skip_nl(i)
                    if i < n and toks[i][1] == "as":
                        alias = toks[i + 1][1]
                        i = skip_nl(i + 2)
                    if sub:
                        members.append((sub["path"], sub["start"], sub["end"], alias))
                    if i < n and toks[i][1] == ",":
                        i = skip_nl(i + 1)
                close = toks[i][4] if i < n else end
                return {
                    "path": prefix,
                    "start": start,
                    "end": close,
                    "prefix_end": prefix_end,
                    "members": members,
                }, i + 1
            else:
                break
        return ({"path": prefix, "start": start, "end": end} if prefix else None), i

    def rest_of_statement(i):
        while i < n and not (toks[i][0] == "nl" and toks[i - 1][1] not in (",", "(")):
            i += 1
        return i

    i, previous = 0, None
    while i < n:
        kind, text, line, _, _ = toks[i]
        at_start = previous is None or previous[0] == "nl" or previous[1] in (":", ";")
        if kind == "id" and text in ("import", "include", "from") and at_start:
            i = skip_nl(i + 1)
            items = []
            while i < n:
                entry, i = item(i)
                if entry:
                    entry["line"] = line
                    items.append(entry)
                if text == "from":
                    i = rest_of_statement(i)
                    break
                if i < n and toks[i][1] == "as":
                    i += 2
                if i < n and toks[i][1] == "except":
                    i = rest_of_statement(i)
                    break
                if i < n and toks[i][1] == ",":
                    i = skip_nl(i + 1)
                    continue
                break
            found.append({"kind": text, "items": items})
            previous = ("nl", "\n", line, 0, 0)
            continue
        previous = toks[i]
        i += 1
    return found


def imports_of(src):
    """Every (module path, line) named by an `import`, `from` or `include` statement."""
    out = []
    for statement in statements(src):
        for entry in statement["items"]:
            if "members" in entry:
                out += [(entry["path"] + m[0], entry["line"]) for m in entry["members"]]
            else:
                out.append((entry["path"], entry["line"]))
    return out


def nim_files(root):
    """Every `.nim` file of the scanned trees, as a path relative to `root`."""
    out = []
    for top in SCANNED:
        for directory, subdirs, files in os.walk(os.path.join(root, top)):
            subdirs[:] = sorted(d for d in subdirs if d != "build")
            out += [
                os.path.relpath(os.path.join(directory, f), root)
                for f in sorted(files)
                if f.endswith(".nim") and not f.startswith("._")
            ]
    return out


def resolve(root, importer, path):
    """The project file a module path names, None for a package, or `?` if it names nothing."""
    if path.startswith(("std/", "pkg/")):
        return None
    name = path if path.endswith(".nim") else path + ".nim"
    bases = [os.path.dirname(importer)]
    if not path.startswith("."):
        bases += SEARCH_PATHS
    for base in bases:
        candidate = os.path.normpath(os.path.join(base, name))
        if os.path.isfile(os.path.join(root, candidate)):
            return candidate
    return "?" if path.startswith(".") else None


def covers(entry, path):
    return path.startswith(entry) if entry.endswith("/") else path == entry


def place_of(path, layers):
    """The layer a file belongs to: the most specific entry wins."""
    best, where = -1, None
    for layer, entries in layers.items():
        for entry in entries:
            if covers(entry, path) and len(entry) > best:
                best, where = len(entry), layer
    if where:
        return where
    top = path.split(os.sep)[0]
    return "core" if top == "src" else top


def closure(starts, edges):
    """Every file reachable from `starts`, each with the file that first reached it."""
    seen = {s: None for s in starts}
    queue = list(starts)
    while queue:
        current = queue.pop()
        for target, _ in edges.get(current, ()):
            if target not in seen:
                seen[target] = current
                queue.append(target)
    return seen


def chain(seen, target):
    path = [target]
    while seen[path[-1]] is not None:
        path.append(seen[path[-1]])
    return " <- ".join(path)


def check(root, config):
    """All findings as (file, line, rule, message), and the coverage counts."""
    layers = config["layers"]
    strict = config.get("strict", False)
    files = nim_files(root)
    edges, findings = {}, []
    for path in files:
        with open(os.path.join(root, path), encoding="utf-8") as f:
            source = f.read()
        edges[path] = []
        for module, line in imports_of(source):
            target = resolve(root, path, module)
            if target == "?":
                findings.append((path, line, "unresolved", f"`{module}` names no file"))
            elif target:
                edges[path].append((target, line))
    place = {p: place_of(p, layers) for p in set(files) | {t for e in edges.values() for t, _ in e}}

    sdk = {"sdk_base", "sdk_binding", "sdk_testing", "sdk_tests"}
    allowed = {f"src/logos_core/{m}.nim" for m in config["daemon_allowlist"]}
    testing_importers = set(config.get("testing_importers", []))
    used_allowlist = set()
    for path, targets in edges.items():
        here = place[path]
        for target, line in targets:
            there = place[target]
            if here in sdk and there not in sdk:
                findings.append((path, line, "sdk-closed", f"the SDK imports {target}"))
            if here == "sdk_base" and there in ("sdk_binding", "sdk_testing"):
                findings.append((path, line, "base-below-binding", f"the base imports {target}"))
            if (here == "core" or here in sdk) and there == "daemon_cli":
                findings.append((path, line, "core-below-daemon", f"imports {target}"))
            if here == "daemon_cli" and there == "core":
                if target in allowed:
                    used_allowlist.add(target)
                else:
                    findings.append(
                        (path, line, "daemon-allowlist", f"{target} is not on the allowlist")
                    )
            if (
                there == "sdk_testing"
                and here not in ("tests", "sdk_tests", "sdk_testing")
                and path not in testing_importers
            ):
                findings.append((path, line, "testing-test-only", f"imports {target}"))

    for target in sorted(allowed - used_allowlist):
        findings.append(
            ("tools/lint/layers.toml", 0, "daemon-allowlist", f"stale entry: nothing imports {target}")
        )

    roots = config["kit_facade"]
    if isinstance(roots, str):
        roots = [roots]
    for facade in roots:
        if facade in edges:
            seen = closure([facade], edges)
            for target in config["kit_forbidden"]:
                if target in seen:
                    findings.append((facade, 1, "kit-facade", f"reaches {chain(seen, target)}"))
        elif strict:
            findings.append((facade, 0, "kit-facade", "the facade does not exist"))

    seen = closure([p for p in files if place[p] == "daemon_cli"], edges)
    for target in config["daemon_tls_forbidden"]:
        if target in seen:
            findings.append((target, 0, "daemon-no-tls", f"reached by {chain(seen, target)}"))

    if strict:
        for layer in sorted(sdk):
            if not any(place[p] == layer for p in files):
                findings.append(("tools/lint/layers.toml", 0, "layers", f"layer {layer} is empty"))

    # A recorded exception is one exact import; one that matches nothing has gone stale.
    exceptions = config.get("exception", [])
    if strict and exceptions:
        findings.append(("tools/lint/layers.toml", 0, "exceptions", "strict: none may be recorded"))
    kept = []
    used = set()
    for finding in findings:
        path, _, rule, message = finding
        match = next(
            (
                k
                for k, e in enumerate(exceptions)
                if e["rule"] == rule and e["file"] == path and e["imports"] in message
            ),
            None,
        )
        if match is None:
            kept.append(finding)
        else:
            used.add(match)
    for k, e in enumerate(exceptions):
        if k not in used:
            kept.append(
                ("tools/lint/layers.toml", 0, "exceptions", f"stale: {e['file']} -> {e['imports']}")
            )
    stats = (len(files), sum(len(t) for t in edges.values()), len(used))
    return sorted(set(kept)), stats


# The self-test: one clean tree, then one planted violation for each rule.

SELF_CONFIG = {
    "strict": False,
    "kit_facade": [
        "sdk/src/logos_sdk/kit.nim",
        "sdk/src/logos_sdk/codegen/invokert.nim",
        "sdk/src/logos_sdk/codegen/consumert.nim",
    ],
    "kit_forbidden": ["sdk/src/logos_sdk/kit/rcclient.nim", "sdk/src/logos_sdk/kit/rc_types.nim"],
    "daemon_tls_forbidden": [
        "src/logos_core/transport/tls/boring.nim",
        "src/logos_core/transport/tls/engine.nim",
    ],
    "daemon_allowlist": ["runtime/host"],
    "testing_importers": [],
    "layers": {
        "sdk_base": ["sdk/src/logos_sdk/"],
        "sdk_binding": [
            "sdk/src/logos_sdk.nim",
            "sdk/src/logos_sdk/kit.nim",
            "sdk/src/logos_sdk/codegen/",
            "sdk/src/logos_sdk/kit/",
        ],
        "sdk_testing": ["sdk/src/logos_sdk/testing/"],
        "sdk_tests": ["sdk/tests/"],
        "daemon_cli": ["src/logos_core/daemon/", "src/logos_core/cli/", "src/logosd.nim"],
    },
}

CLEAN_TREE = {
    "sdk/src/logos_sdk/base/hex.nim": "import std/strutils\n",
    "sdk/src/logos_sdk/codegen/kitrt.nim": "import ../base/hex\n",
    "sdk/src/logos_sdk/codegen/invokert.nim": "import ./kitrt\n",
    "sdk/src/logos_sdk/codegen/consumert.nim": "import ./kitrt\n",
    "sdk/src/logos_sdk/kit/rc_types.nim": "import ../codegen/kitrt\n",
    "sdk/src/logos_sdk/kit/rcclient.nim": "import ./rc_types\n",
    "sdk/src/logos_sdk/kit.nim": "import ./codegen/kitrt\nexport kitrt\n",
    "sdk/src/logos_sdk/testing/helper.nim": "import ../base/hex\n",
    "sdk/tests/test_hex.nim": "import logos_sdk/base/hex\nimport logos_sdk/testing/helper\n",
    "src/logos_core/runtime/host.nim": "import logos_sdk/kit/rcclient\n",
    "src/logos_core/runtime/engine.nim": "import ./host\n",
    "src/logos_core/transport/tls/boring.nim": "discard\n",
    "src/logos_core/transport/tls/engine.nim": "import ./boring\n",
    "src/logos_core/transport/tls/signing.nim": "discard\n",
    "src/logos_core/daemon/main.nim": "import ../runtime/host\n",
    "src/logos_core/cli/main.nim": "import ../daemon/main\n",
    "src/logosd.nim": "import ./logos_core/daemon/main\n",
    "tests/test_engine.nim": "import ../src/logos_core/daemon/main\nimport logos_sdk/testing/helper\n",
}

PLANTS = [
    ("sdk-closed", "sdk/src/logos_sdk/base/bad.nim", "import ../../../../src/logos_core/runtime/host\n"),
    ("sdk-closed", "sdk/tests/test_bad.nim", "import ../../src/logos_core/runtime/host\n"),
    ("base-below-binding", "sdk/src/logos_sdk/base/bad.nim", "import ../codegen/kitrt\n"),
    ("base-below-binding", "sdk/src/logos_sdk/base/bad.nim", "import ../kit/rcclient\n"),
    ("base-below-binding", "sdk/src/logos_sdk/base/bad.nim", "import ../testing/helper\n"),
    ("kit-facade", "sdk/src/logos_sdk/kit.nim", "import ./kit/rcclient\n"),
    ("kit-facade", "sdk/src/logos_sdk/codegen/kitrt.nim", "import ../kit/rc_types\n"),
    ("kit-facade", "sdk/src/logos_sdk/codegen/invokert.nim", "import ../kit/rc_types\n"),
    ("kit-facade", "sdk/src/logos_sdk/codegen/consumert.nim", "import ../kit/rcclient\n"),
    ("core-below-daemon", "src/logos_core/runtime/bad.nim", "import ../daemon/main\n"),
    ("core-below-daemon", "src/logos_core/runtime/bad.nim", "import ../../logosd\n"),
    ("daemon-no-tls", "src/logos_core/runtime/host.nim", "import ../transport/tls/boring\n"),
    ("daemon-no-tls", "src/logos_core/runtime/host.nim", "import ../transport/tls/engine\n"),
    ("daemon-allowlist", "src/logos_core/daemon/bad.nim", "import ../runtime/engine\n"),
    ("daemon-allowlist", "src/logos_core/cli/bad.nim", "import ../runtime/engine\n"),
    ("testing-test-only", "src/logos_core/runtime/bad.nim", "import logos_sdk/testing/helper\n"),
    ("testing-test-only", "sdk/src/logos_sdk/kit/bad.nim", "import ../testing/helper\n"),
    ("unresolved", "src/logos_core/runtime/bad.nim", "import ../no/such/module\n"),
]

PARSED = [
    ("import a/b", ["a/b"]),
    ("import a/[b, c as d]", ["a/b", "a/c"]),
    ("import ../a/[\n  b,\n  c,\n]\n", ["../a/b", "../a/c"]),
    ("import\n  ./a/[\n    b, c\n  ],\n  ./d\n", ["./a/b", "./a/c", "./d"]),
    ("import ../a/\n  [b, c]\n", ["../a/b", "../a/c"]),
    ("import\n  ../a/\n    [b]\n", ["../a/b"]),
    ("when defined(posix):\n  import ./a\n", ["./a"]),
    ("when x: import ./a\n", ["./a"]),
    ("from ../a import b, c\nimport ./d\n", ["../a", "./d"]),
    ("from ../a import\n  b,\n  c\nimport ./d\n", ["../a", "./d"]),
    ("include ./a\n", ["./a"]),
    ('include "./a.nim"\n', ["./a.nim"]),
    ('import "../a/b"\n', ["../a/b"]),
    ("import ./a except b, c\nimport ./d\n", ["./a", "./d"]),
    ("import ./a as b, ./c\n", ["./a", "./c"]),
    ("import a; import b\n", ["a", "b"]),
    ("# import ./a\n", []),
    ("#[ import ./a\n#[ import ./b ]#\nimport ./c ]#\nimport ./d\n", ["./d"]),
    ('let s = """\nimport ./a\n"""\nimport ./b\n', ["./b"]),
    ('let s = "import ./a"\n', []),
    ('let s = r"\\"\nimport ./a\n', ["./a"]),
    ("let c = '\"'\nimport ./a\n", ["./a"]),
    ("proc importc() = discard\n", []),
    ("let x = 1'u8\nimport ./a\n", ["./a"]),
]


def plant_tree(root, tree):
    for path, text in tree.items():
        full = os.path.join(root, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as f:
            f.write(text)


def self_test():
    failures = []
    for source, want in PARSED:
        got = [p for p, _ in imports_of(source)]
        if got != want:
            failures.append(f"parse {source!r}: got {got}, want {want}")

    def run(tree, config):
        with tempfile.TemporaryDirectory() as root:
            plant_tree(root, tree)
            return check(root, config)[0]

    clean = run(CLEAN_TREE, SELF_CONFIG)
    if clean:
        failures.append(f"the clean tree fails: {clean}")
    strict = dict(SELF_CONFIG, strict=True)
    if run(CLEAN_TREE, strict):
        failures.append("the clean tree fails under strict")

    for rule, path, text in PLANTS:
        found = {f[2] for f in run(dict(CLEAN_TREE, **{path: text}), SELF_CONFIG)}
        if rule not in found:
            failures.append(f"{rule} did not fire on {path}: {text!r} (found {found})")

    bad = "src/logos_core/runtime/bad.nim"
    tree = dict(CLEAN_TREE, **{bad: "import ../daemon/main\n"})
    exception = {"rule": "core-below-daemon", "file": bad, "imports": "src/logos_core/daemon/main.nim"}
    excused = dict(SELF_CONFIG, exception=[exception])
    if run(tree, excused):
        failures.append("a recorded exception did not excuse its import")
    if not any(f[2] == "exceptions" for f in run(CLEAN_TREE, excused)):
        failures.append("a stale exception was accepted")
    if not any(f[2] == "exceptions" for f in run(tree, dict(excused, strict=True))):
        failures.append("strict accepted an exception")

    stale = dict(SELF_CONFIG, daemon_allowlist=["runtime/host", "runtime/engine"])
    if not any("stale entry" in f[3] for f in run(CLEAN_TREE, stale)):
        failures.append("a stale allowlist entry was accepted")

    for root in SELF_CONFIG["kit_facade"]:
        no_facade = {k: v for k, v in CLEAN_TREE.items() if k != root}
        if run(no_facade, SELF_CONFIG):
            failures.append(f"a missing facade root failed outside strict: {root}")
        if not any(f[2] == "kit-facade" for f in run(no_facade, strict)):
            failures.append(f"strict accepted a missing facade root: {root}")

    for failure in failures:
        print("self-test:", failure)
    if failures:
        return 1
    print(f"layers self-test: {len(PARSED)} parses and {len(PLANTS)} planted violations caught")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", default=os.path.join(os.path.dirname(__file__), "layers.toml"))
    parser.add_argument("--root", default=".")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    with open(args.config, "rb") as f:
        config = tomllib.load(f)
    findings, (files, edges, excused) = check(args.root, config)
    for path, line, rule, message in findings:
        print(f"{path}:{line}: {rule}: {message}")
    print(f"layers: {files} files, {edges} project imports, {excused} recorded exceptions")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
