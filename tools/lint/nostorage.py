"""No storage library: the dependency lists and the Package Manager's link inputs name none.

DECISIONS G406; docs/PACKAGE-MANAGER.md §1. The Package Manager reaches Logos Storage only
through `lcn.storage_fetch`, which storage_module provides (owner, 2026-11-20). This check reads:

- every nimble file's `requires`, `nimble.lock`'s package names and URLs, and the generated
  `nix/nimble-deps.json`;
- `flake.nix`'s inputs (comments aside) and every node of `flake.lock`;
- link and build pragmas (`passL`, `passC`, `link`, `compile`, `dynlib`, `header`) in the
  sources under `roots` and their in-repository import closure, and the same switches in every
  nimble file and `config.nims`.

None may name an entry of the deny list (`nostorage.toml`), without case. The layer rule
(`layers.toml`'s `pm_external_allowlist`) catches a storage library under a name this list does
not know. `--self-test` plants one violation of each kind in a clean tree and checks it fails.
"""

import argparse
import importlib.util
import json
import os
import re
import sys
import tempfile
import tomllib

HERE = os.path.dirname(os.path.abspath(__file__))
SKIPPED_DIRS = {"build", "nimbledeps", ".git", "result"}
PRAGMA_KEYS = ("passL", "passC", "link", "compile", "dynlib", "header")
SWITCH = re.compile(r"\b(passL|passC|passl|passc|link|compile|dynlib|clib|clibdir|cincludes)\b")


def load_layers():
    spec = importlib.util.spec_from_file_location("layers", os.path.join(HERE, "layers.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def denied(text, deny):
    low = text.lower()
    return [d for d in deny if d.lower() in low]


def files_named(root, predicate):
    out = []
    for directory, subdirs, files in os.walk(root):
        subdirs[:] = sorted(d for d in subdirs if d not in SKIPPED_DIRS and not d.startswith("."))
        for f in sorted(files):
            if predicate(f):
                out.append(os.path.relpath(os.path.join(directory, f), root))
    return out


def read(root, path):
    with open(os.path.join(root, path), encoding="utf-8") as f:
        return f.read()


def strip_comments(text, marker):
    """Text without `marker`-to-end-of-line comments outside double-quoted strings."""
    out = []
    for line in text.splitlines():
        in_string = False
        cut = len(line)
        i = 0
        while i < len(line):
            c = line[i]
            if c == "\\" and in_string:
                i += 2
                continue
            if c == '"':
                in_string = not in_string
            elif c == marker and not in_string:
                cut = i
                break
            i += 1
        out.append(line[:cut])
    return "\n".join(out)


def strings_of(value):
    """Every key and string value of a JSON value."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for k, v in value.items():
            yield k
            yield from strings_of(v)
    elif isinstance(value, list):
        for v in value:
            yield from strings_of(v)


def requires_of(text):
    """The strings of every `requires` statement of a nimble file, comments aside."""
    out = []
    for line in strip_comments(text, "#").splitlines():
        stripped = line.strip()
        if re.match(r"requires\b", stripped):
            out += re.findall(r'"([^"]*)"', stripped)
    return out


def flake_inputs(text):
    """The `inputs` attribute of flake.nix, comments aside."""
    clean = strip_comments(text, "#")
    m = re.search(r"\binputs\b", clean)
    if not m:
        return ""
    end = clean.find("outputs", m.end())
    return clean[m.start() : end if end >= 0 else len(clean)]


def pragmas_of(text):
    """Every `{. ... .}` pragma that names a link or build key, with its line."""
    out = []
    for m in re.finditer(r"\{\.(.*?)\.\}", text, re.S):
        body = m.group(1)
        if any(re.search(r"\b" + k + r"\s*:", body) for k in PRAGMA_KEYS):
            out.append((text.count("\n", 0, m.start()) + 1, body))
    return out


def check(root, config):
    deny = config["deny"]
    findings = []

    def flag(path, line, what, text):
        for d in denied(text, deny):
            findings.append((path, line, what, f"names {d!r}: {text.strip()[:120]}"))

    nimbles = files_named(root, lambda f: f.endswith(".nimble"))
    for path in nimbles:
        text = read(root, path)
        for r in requires_of(text):
            flag(path, 0, "requires", r)
        for n, line in enumerate(strip_comments(text, "#").splitlines(), 1):
            if SWITCH.search(line):
                flag(path, n, "switch", line)
    for path in files_named(root, lambda f: f == "config.nims"):
        for n, line in enumerate(strip_comments(read(root, path), "#").splitlines(), 1):
            if SWITCH.search(line):
                flag(path, n, "switch", line)
    for path in files_named(root, lambda f: f == "nimble.lock"):
        lock = json.loads(read(root, path))
        for name, entry in lock.get("packages", {}).items():
            flag(path, 0, "lock", name)
            for s in strings_of(entry):
                if s.startswith(("http", "git", "file", "ssh")) or "/" in s:
                    flag(path, 0, "lock", s)
    deps = os.path.join("nix", "nimble-deps.json")
    if os.path.isfile(os.path.join(root, deps)):
        for s in strings_of(json.loads(read(root, deps))):
            flag(deps, 0, "nimble-deps", s)
    if os.path.isfile(os.path.join(root, "flake.nix")):
        flag("flake.nix", 0, "flake-input", flake_inputs(read(root, "flake.nix")))
    if os.path.isfile(os.path.join(root, "flake.lock")):
        lock = json.loads(read(root, "flake.lock"))
        for name, node in lock.get("nodes", {}).items():
            flag("flake.lock", 0, "flake-lock", name)
            for s in strings_of(node):
                flag("flake.lock", 0, "flake-lock", s)

    layers = load_layers()
    files = layers.nim_files(root)
    edges = {}
    for path in files:
        edges[path] = []
        for module, _ in layers.imports_of(read(root, path)):
            target = layers.resolve(root, path, module)
            if target and target != "?":
                edges[path].append((target, 0))
    starts = [p for p in files if any(layers.covers(r, p) for r in config["roots"])]
    if not starts:
        findings.append(("tools/lint/nostorage.toml", 0, "roots", "the roots name no source"))
    for path in sorted(layers.closure(starts, edges)):
        if not os.path.isfile(os.path.join(root, path)):
            continue
        for line, body in pragmas_of(read(root, path)):
            flag(path, line, "pragma", body)
    return sorted(set(findings)), (len(nimbles), len(starts), len(layers.closure(starts, edges)))


# The self-test: a clean tree, then one planted violation of each kind.

SELF_CONFIG = {
    "deny": ["libstorage", "logos-storage", "logos_storage", "codex"],
    "roots": ["src/logos_core/pm/"],
}

CLEAN = {
    "logos_core.nimble": 'version = "0.1.0"\nrequires "nim >= 2.2.4"\nrequires "results"\n'
    '# a comment naming libstorage does not count\nswitch("passL", "-lz")\n',
    "config.nims": 'switch("passC", "-O2")\n# libstorage in a comment\n',
    "nimble.lock": json.dumps(
        {"packages": {"results": {"url": "https://github.com/arnetheduck/nim-results"}}}
    ),
    "nix/nimble-deps.json": json.dumps({"results": {"url": "https://github.com/arnetheduck/nim-results"}}),
    "flake.nix": "{\n  inputs = {\n    # the commit logos-storage-nim pins\n"
    '    nixpkgs.url = "github:NixOS/nixpkgs/abc";\n  };\n  outputs = { self }: { };\n}\n',
    "flake.lock": json.dumps(
        {"nodes": {"nixpkgs": {"locked": {"owner": "NixOS", "repo": "nixpkgs"}}, "root": {}}}
    ),
    "src/logos_core/pm/engine.nim": "import ../package/lgx\n",
    "src/logos_core/package/lgx.nim": '{.passL: "-lz".}\n{.compile: "blake3.c".}\n',
    # Outside the closure: not the Package Manager's.
    "src/logos_core/runtime/other.nim": '{.passL: "-L/opt/libstorage".}\n',
}

PLANTS = [
    ("requires", "logos_core.nimble", 'requires "libstorage >= 0.1"\n'),
    ("requires", "sdk/logos_sdk.nimble", 'requires "results", "https://github.com/logos-storage/x"\n'),
    ("lock", "nimble.lock", json.dumps({"packages": {"logos_storage": {"url": "https://example.org/x"}}})),
    (
        "lock",
        "nimble.lock",
        json.dumps({"packages": {"x": {"url": "https://github.com/logos-storage/logos-storage-nim"}}}),
    ),
    ("nimble-deps", "nix/nimble-deps.json", json.dumps({"nim-codex": {"url": "https://example.org"}})),
    (
        "flake-input",
        "flake.nix",
        '{\n  inputs.storage.url = "github:logos-storage/logos-storage-nim";\n  outputs = _: { };\n}\n',
    ),
    ("flake-lock", "flake.lock", json.dumps({"nodes": {"codex": {"locked": {}}, "root": {}}})),
    ("switch", "config.nims", 'switch("passL", "-L/opt/libstorage/lib")\n'),
    ("switch", "logos_core.nimble", 'requires "results"\nswitch("passL", "-lcodex")\n'),
    ("pragma", "src/logos_core/pm/engine.nim", '{.passL: "-L/opt/libstorage/lib".}\n'),
    ("pragma", "src/logos_core/package/lgx.nim", '{.link: "libcodex.a".}\n'),
    ("pragma", "src/logos_core/package/lgx.nim", 'proc f() {.importc, header: "libstorage.h".}\n'),
    ("pragma", "src/logos_core/package/lgx.nim", 'proc f() {.importc, dynlib: "libstorage.so".}\n'),
]


def self_test():
    failures = []

    def run(tree):
        with tempfile.TemporaryDirectory() as root:
            for path, text in tree.items():
                full = os.path.join(root, path)
                os.makedirs(os.path.dirname(full), exist_ok=True)
                with open(full, "w", encoding="utf-8") as f:
                    f.write(text)
            return check(root, SELF_CONFIG)[0]

    clean = run(CLEAN)
    if clean:
        failures.append(f"the clean tree fails: {clean}")
    for what, path, text in PLANTS:
        found = {f[2] for f in run(dict(CLEAN, **{path: text}))}
        if what not in found:
            failures.append(f"{what} did not fire on {path}: {text!r} (found {found})")
    no_roots = {k: v for k, v in CLEAN.items() if not k.startswith("src/logos_core/pm/")}
    if not any(f[2] == "roots" for f in run(no_roots)):
        failures.append("roots that name no source were accepted")
    for failure in failures:
        print("self-test:", failure)
    if failures:
        return 1
    print(f"nostorage self-test: {len(PLANTS)} planted violations caught")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", default=os.path.join(HERE, "nostorage.toml"))
    parser.add_argument("--root", default=".")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    with open(args.config, "rb") as f:
        config = tomllib.load(f)
    findings, (nimbles, starts, closure) = check(args.root, config)
    for path, line, what, message in findings:
        print(f"{path}:{line}: {what}: {message}")
    print(
        f"nostorage: {nimbles} nimble files, {starts} Package Manager sources, "
        f"{closure} files in their import closure"
    )
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
