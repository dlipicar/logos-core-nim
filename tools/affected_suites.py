#!/usr/bin/env python3
"""The test suites a change can reach (wave 2's merge rule 1) [IMPL].

    python3 -I tools/affected_suites.py BASE [TREE]
    python3 -I tools/affected_suites.py --root DIR --changed PATH...
    python3 -I tools/affected_suites.py --self-test [--root DIR]

With git revisions, the change is `git diff BASE TREE` (TREE defaults to HEAD), and the suites are
found in TREE's own files, read from git: give the merge base as BASE and the merged tree as TREE,
before or after the merge commit exists. `--root` reads a directory instead, and `--changed` names
the changed paths. `--variant V` prints each suite as its flake check, `<suite>-V`; `--why` prints,
for each suite, one chain from a changed file to it. Changed files that reach no suite are listed on
stderr: a tool, a document no test reads, or a flake check that is not a suite (the spec checks, the
lints, nph).

A suite is a `test_*.nim` file directly in `tests/` or `sdk/tests/` (flake.nix `testFiles`). From
each one the tool follows every file the suite builds or reads:

- `import`, `from` and `include`, through the layer lint's parser (tools/lint/layers.py), resolved
  against the importing file's directory and the search paths `src` and `sdk/src`, so test support
  modules count like any other module;
- each run of string literals and path constants joined by `/` or `&` (`root / "docs" /
  "DAEMON.md"`, `fixtureDir & "/ledger_module.cddl"`). A path constant is a name defined as such
  a run alone (`fixtureDir* = "sdk/..."`); it counts in the files that use it, not in the module
  that defines it. An identifier with no such definition splits the run. Each path is resolved
  against the file's directory, then the repository root, then as the end of a path
  (`"daemon/trust.cddl"`, a kit's `"meter_impl.nim"`). That covers `staticRead` and `slurp`
  inputs, documents and contracts read by path, `{.compile.}` sources and kit sources built at run
  time. A path naming a directory reaches every file under it, except the trees too broad to name
  a fixture (`BROAD`). A Nim or C file reached that way is followed in turn;
- `#include "..."` in C sources and headers;
- for each main module, a suite or a Nim source a suite builds at run time: `X.nims` beside it and
  each `config.nims` in its directory and the directories above.

A change to a build input (`EVERYTHING`: the Nimble files, the lock, the flake and the Nix
dependency files) reaches every suite. Paths inside comments do not count, so a doc comment that
names a document does not tie its suite to it. A path deleted by the change still matches the
literals that name it. What the tool cannot see: a path built at run time from parts that are not
literals or path constants. The result can be wider than what a suite reads: a module that uses a
directory, such as kitbuild's kit source directories, ties every suite that imports it to every
file there.
"""

import argparse
import collections
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lint"))
import layers  # noqa: E402 (tools/lint/layers.py: the tokenizer and the import parser)

SUITE_DIRS = ("tests", "sdk/tests")
SEARCH_PATHS = ("src", "sdk/src")
EVERYTHING = {
    "config.nims",
    "logos_core.nimble",
    "nimble.lock",
    "flake.nix",
    "flake.lock",
    "nix/nimble-deps.json",
    "nix/nimble-deps.nix",
    "nix/nim-derivation.nix",
    "nix/nim-overlay.nix",
}
# Directories a literal names without naming a fixture: `root / "src/logos_core" / name`.
BROAD = {
    "",
    "build",
    "contrib",
    "docs",
    "sdk",
    "sdk/src",
    "sdk/src/logos_sdk",
    "sdk/tests",
    "spec",
    "src",
    "src/logos_core",
    "tests",
    "tools",
}
NIM = (".nim", ".nims")
C = (".c", ".h", ".cc", ".cpp", ".hpp", ".m")
PATHLIKE = re.compile(r"^[A-Za-z0-9_.+/-]+$")
EXTENSION = re.compile(r"\.[A-Za-z0-9]+$")
C_INCLUDE = re.compile(r'^\s*#\s*(?:include|import)\s*"([^"]+)"', re.M)


class Tree:
    """The files of one tree: a directory, or a git tree read with `git cat-file`."""

    def __init__(self, files, reader):
        self.files = set(files)
        self._read = reader
        self._cache = {}
        self._parsed = {}
        self._named = {}
        self._exported = None

    @staticmethod
    def from_dir(root):
        files = []
        for directory, subdirs, names in os.walk(root):
            subdirs[:] = sorted(
                d for d in subdirs if not d.startswith(".") and d not in ("build", "nimbledeps", "nimcache")
            )
            rel = os.path.relpath(directory, root)
            for n in names:
                if not n.startswith("._") and not os.path.islink(os.path.join(directory, n)):
                    files.append(os.path.normpath(os.path.join(rel, n)))

        def read(path):
            with open(os.path.join(root, path), encoding="utf-8", errors="replace") as f:
                return f.read()

        return Tree(files, read)

    @staticmethod
    def from_git(repo, rev):
        out = git(repo, "ls-tree", "-r", "-z", "--name-only", rev)
        files = [f for f in out.split("\0") if f]
        wanted = [f for f in files if f.endswith(NIM + C)]
        texts = cat_files(repo, rev, wanted)
        return Tree(files, lambda path: texts.get(path, ""))

    def read(self, path):
        if path not in self._cache:
            self._cache[path] = self._read(path)
        return self._cache[path]

    def parsed(self, path):
        """A Nim file's `parse_nim`, once per tree."""
        if path not in self._parsed:
            self._parsed[path] = parse_nim(self.read(path))
        return self._parsed[path]

    def exported(self):
        """{name: [file]} for every exported path definition in the tree's Nim files."""
        if self._exported is None:
            self._exported = collections.defaultdict(list)
            for f in sorted(self.files):
                if f.endswith(".nim"):
                    for name, (exported, _) in self.parsed(f)[1].items():
                        if exported:
                            self._exported[name].append(f)
        return self._exported

    def value(self, name, where, busy=frozenset()):
        """The paths an identifier stands for in file `where`: its definition there, else every
        exported one of that name (an identifier with no path definition stands for nothing)."""
        owners = [where] if name in self.parsed(where)[1] else self.exported().get(name, [])
        out = set()
        for f in owners:
            if (f, name) in busy:
                continue
            out |= self.evaluate(self.parsed(f)[1][name][1], f, busy | {(f, name)})
        return out

    def evaluate(self, terms, where, busy=frozenset()):
        """The strings a run of terms makes. An identifier that stands for nothing splits the run,
        and each part counts alone: `repoDir / fixtureDir / "x.cddl"` gives fixtureDir's value
        joined with "x.cddl"."""
        out, acc, sep = set(), {""}, None
        for kind, text in terms + [("id", None)]:
            if kind == "sep":
                sep = text
                continue
            vals = {text} if kind == "str" else (self.value(text, where, busy) if text else set())
            if not vals:
                out |= {a for a in acc if a}
                acc, sep = {""}, None
                continue
            acc = {joined(a, v, sep) for a in acc for v in vals}
            if len(acc) > 256:
                acc = set(sorted(acc)[:256])
        return out

    def paths_named(self, path):
        """Every path-shaped string a Nim file's runs make, once per tree."""
        if path not in self._named:
            out = set()
            for terms in self.parsed(path)[2]:
                for text in self.evaluate(terms, path):
                    text = text.strip("/")
                    if len(text) <= 200 and PATHLIKE.match(text) and text.strip("./"):
                        out.add(text)
            self._named[path] = sorted(out)
        return self._named[path]


def git(repo, *args):
    run = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if run.returncode != 0:
        sys.exit(f"git {' '.join(args)}: {run.stderr.strip()}")
    return run.stdout


def cat_files(repo, rev, paths):
    """Each path's text at `rev`, through one `git cat-file --batch`."""
    request = "".join(f"{rev}:{p}\n" for p in paths).encode()
    run = subprocess.run(["git", "-C", repo, "cat-file", "--batch"], input=request, capture_output=True)
    if run.returncode != 0:
        sys.exit(f"git cat-file: {run.stderr.decode(errors='replace').strip()}")
    data, at, texts = run.stdout, 0, {}
    for p in paths:
        end = data.index(b"\n", at)
        header = data[at:end].split()
        at = end + 1
        if len(header) < 3 or header[1] != b"blob":
            continue
        size = int(header[2])
        texts[p] = data[at : at + size].decode("utf-8", errors="replace")
        at += size + 1
    return texts


SEPARATORS = ("&", "/")
DECLARATIONS = ("const", "let", "var")


def chain_at(toks, k):
    """The run of terms from token k, string literals and identifiers joined by `/` or `&`: a
    list of ("str", text), ("id", name) and ("sep", op), and the index after it. A run goes on
    past the end of a line that ends in a separator."""
    terms, n = [], len(toks)
    while k < n and toks[k][0] in ("str", "id"):
        terms.append(toks[k][:2])
        k += 1
        if k < n and toks[k][0] == "op" and toks[k][1] in SEPARATORS:
            terms.append(("sep", toks[k][1]))
            k += 1
            while k < n and toks[k][0] == "nl":
                k += 1
            continue
        break
    if terms and terms[-1][0] == "sep":
        terms.pop()
    return terms, k


def parse_nim(src):
    """A Nim file's imported module paths, its path definitions and its other runs of terms.

    A path definition is a statement `name = <run>` or `name* = <run>`, after `const`, `let` or
    `var` or not, whose right side is nothing but one run: {name: (exported, terms)}. Its run
    names a path only where `name` is used, so a module's directory constant does not tie every
    suite that imports the module to that directory."""
    toks = layers.tokenize(src)
    n = len(toks)
    defined, skip = {}, set()
    for i in range(n):
        if i and toks[i - 1][0] != "nl":
            continue
        j = i
        while j < n and toks[j][0] == "id" and toks[j][1] in DECLARATIONS:
            j += 1
        if j + 1 >= n or toks[j][0] != "id":
            continue
        k, exported = j + 1, False
        if toks[k][:2] == ("op", "*"):
            exported, k = True, k + 1
        if k < n and toks[k][:2] == ("op", "*="):
            exported, k = True, k + 1
        elif k < n and toks[k][:2] == ("op", "="):
            k += 1
        else:
            continue
        terms, end = chain_at(toks, k)
        if terms and (end >= n or toks[end][0] == "nl"):
            defined[toks[j][1]] = (exported, terms)
            skip.update(range(j, end))
    runs, i = [], 0
    while i < n:
        if i in skip or toks[i][0] not in ("str", "id"):
            i += 1
            continue
        terms, end = chain_at(toks, i)
        runs.append(terms)
        i = max(end, i + 1)
    return [p for p, _ in layers.imports_of(src)], defined, runs


def joined(left, right, sep):
    if not left:
        return right
    return left + right if sep == "&" else left.rstrip("/") + "/" + right.lstrip("/")


class Graph:
    def __init__(self, tree, changed):
        self.tree = tree
        self.known = tree.files | set(changed)
        self.dirs = collections.defaultdict(set)
        for f in self.known:
            d = os.path.dirname(f)
            while True:
                self.dirs[d].add(f)
                if not d:
                    break
                d = os.path.dirname(d)
        self.by_suffix = collections.defaultdict(set)
        for f in self.known:
            parts = f.split("/")
            for k in range(len(parts)):
                self.by_suffix["/".join(parts[k:])].add(f)
        self.dir_suffix = collections.defaultdict(set)
        for d in self.dirs:
            parts = d.split("/")
            for k in range(len(parts)):
                self.dir_suffix["/".join(parts[k:])].add(d)
        self._edges = {}

    def resolve_import(self, importer, path):
        if path.startswith(("std/", "pkg/")):
            return None
        name = path if path.endswith(".nim") else path + ".nim"
        bases = [os.path.dirname(importer)] + ([] if path.startswith(".") else list(SEARCH_PATHS))
        for base in bases:
            candidate = os.path.normpath(os.path.join(base, name))
            if candidate in self.known:
                return candidate
        return None

    def under(self, d):
        return set() if d in BROAD else self.dirs.get(d, set())

    def resolve_literal(self, importer, text):
        """The files a path-shaped literal names, and whether it named them by directory."""
        for base in (os.path.dirname(importer), ""):
            p = os.path.normpath(os.path.join(base, text))
            if p.startswith(".."):
                continue
            if p in self.known:
                return {p}
            # A bare word names a directory only by accident ("kit", "support", ".").
            if p in self.dirs and "/" in text:
                return self.under(p)
        tail = re.sub(r"^(?:\.\.?/)+", "", text)
        last = tail.rsplit("/", 1)[-1]
        if EXTENSION.search(last) and tail in self.by_suffix:
            return set(self.by_suffix[tail])
        if "/" in tail and tail in self.dir_suffix:
            return set().union(*(self.under(d) for d in self.dir_suffix[tail]))
        return set()

    def edges(self, f):
        if f in self._edges:
            return self._edges[f]
        out = set()
        if f in self.tree.files and f.endswith(NIM):
            for path in self.tree.parsed(f)[0]:
                target = self.resolve_import(f, path)
                if target:
                    out.add(target)
            for text in self.tree.paths_named(f):
                for target in self.resolve_literal(f, text):
                    out.add(target)
                    if target.endswith(".nim"):
                        out |= self.main_configs(target)
        elif f in self.tree.files and f.endswith(C):
            for name in C_INCLUDE.findall(self.tree.read(f)):
                p = os.path.normpath(os.path.join(os.path.dirname(f), name))
                if p in self.known:
                    out.add(p)
        out.discard(f)
        self._edges[f] = out
        return out

    def main_configs(self, main):
        """What configures a main module's build (a suite, or a kit source a suite builds at run
        time): `X.nims` beside it and each `config.nims` in its directory and those above."""
        out = {main[:-4] + ".nims"} & self.known
        d = os.path.dirname(main)
        while True:
            out |= {os.path.join(d, "config.nims")} & self.known
            if not d:
                return out
            d = os.path.dirname(d)

    def closure(self, start):
        """Every file reachable from suite `start`, each with the file that first reached it."""
        seen, queue = {start: None}, collections.deque([start])
        for cfg in sorted(self.main_configs(start)):
            seen[cfg] = start
        while queue:
            current = queue.popleft()
            for target in sorted(self.edges(current)):
                if target not in seen:
                    seen[target] = current
                    queue.append(target)
        return seen


def suites_of(tree):
    return sorted(
        f
        for f in tree.files
        if os.path.dirname(f) in SUITE_DIRS
        and os.path.basename(f).startswith("test_")
        and f.endswith(".nim")
    )


def affected(tree, changed):
    """{suite name: a chain from a changed file to the suite}, the changed files no suite
    reaches, and the number of suites."""
    changed = {os.path.normpath(c) for c in changed}
    graph = Graph(tree, changed)
    suites = suites_of(tree)
    result = {}
    everything = sorted(changed & EVERYTHING)
    used = set(everything)
    for suite in suites:
        name = os.path.basename(suite)[:-4]
        seen = graph.closure(suite)
        hits = sorted(changed & set(seen))
        if hits:
            used |= set(hits)
            chain = [hits[0]]
            while seen[chain[-1]] is not None:
                chain.append(seen[chain[-1]])
            result[name] = chain
        elif everything:
            result[name] = [everything[0], "(a build input of every suite)"]
    return result, sorted(changed - used), len(suites)


# --- self-test -------------------------------------------------------------------------------

SELF_TREE = {
    "config.nims": "",
    "tests/config.nims": "",
    "sdk/tests/config.nims": "",
    "src/logos_core/a.nim": "import logos_sdk/y\n",
    "src/logos_core/other.nim": "",
    "src/logos_core/daemon/trust.cddl": "",
    "sdk/src/logos_sdk/y.nim": "",
    "sdk/src/logos_sdk/z.nim": "",
    "sdk/tests/kit/k_impl.nim": "import logos_sdk/z\n",
    "sdk/tests/fx/a.json": "",
    "docs/B.md": "",
    "docs/C.md": "",
    "docs/D.md": "",
    "tests/support/x.nim": (
        "import logos_core/a\n"
        "const\n"
        '  fixtureDir* = "sdk/tests/fx"\n'
        '  docPath* = fixtureDir & "/b.cddl"\n'
    ),
    "sdk/tests/fx/b.cddl": "",
    "sdk/tests/fx/c.txt": "",
    "sdk/tests/test_f.nim": (
        "import ../../tests/support/x\n"
        'discard readFile(repoDir / fixtureDir / "a.json")\n'
        "discard readFile(docPath)\n"
    ),
    "sdk/tests/test_g.nim": "import ../../tests/support/x\nfor f in walkDir(fixtureDir): discard\n",
    "sdk/tests/test_h.nim": 'const\n  Guide = "docs/H.md"\nfor line in readFile(repoDir / Guide).splitLines: discard\n',
    "docs/H.md": "",
    "tests/support/s.nim": '{.compile: "sock.c".}\n',
    "tests/support/sock.c": '#include "sock.h"\n',
    "tests/support/sock.h": "",
    "tests/test_a.nim": "import support/x\n",
    "tests/test_b.nim": (
        "import std/os\n"
        "# docs/C.md is only named in a comment\n"
        'let doc = readFile(root / "docs" / "B.md")\n'
        'for n in ["daemon/trust.cddl"]: discard readFile(root / "src/logos_core" / n)\n'
        'discard "src"\n'
    ),
    "tests/test_c.nim": 'const d = staticRead("../docs/D.md")\nimport support/s\n',
    "tests/test_e.nim": 'discard readFile("docs/gone.md")\n',
    "tests/test_e.nims": "",
    "sdk/tests/test_d.nim": 'discard build("k_impl.nim")\n',
}

SELF_CASES = [
    (["sdk/src/logos_sdk/y.nim"], {"test_a", "test_f", "test_g"}),  # support module, then core
    (["docs/B.md"], {"test_b"}),  # literals joined by `/`
    (["docs/C.md"], set()),  # a comment is not a read
    (["src/logos_core/daemon/trust.cddl"], {"test_b"}),  # the end of a path
    (["src/logos_core/other.nim"], set()),  # `"src"` and `"src/logos_core"` are too broad
    (["docs/D.md"], {"test_c"}),  # staticRead, relative to the file
    (["sdk/src/logos_sdk/z.nim"], {"test_d"}),  # a kit source built at run time, followed
    # A path constant ties only the suites that use it: test_a imports x.nim and uses none.
    (["sdk/tests/fx/a.json"], {"test_f", "test_g"}),  # a constant joined with a literal; a directory
    (["sdk/tests/fx/b.cddl"], {"test_f", "test_g"}),  # a constant made with `&`
    (["sdk/tests/fx/c.txt"], {"test_g"}),  # only the suite that names the whole directory
    (["tests/support/sock.h"], {"test_c"}),  # {.compile.} and #include
    (["docs/H.md"], {"test_h"}),  # a local constant in a run of identifiers
    (["tests/test_e.nims"], {"test_e"}),
    (["docs/gone.md"], {"test_e"}),  # a deleted path still matches its literal
    # A directory's config.nims configures the suites there, not the modules they import from it.
    (["tests/config.nims"], {"test_a", "test_b", "test_c", "test_e"}),
    (["nimble.lock"], {"test_a", "test_b", "test_c", "test_d", "test_e", "test_f", "test_g", "test_h"}),
]

# On this repository's own tree (wave 2 plan §3, rule 1): (changed, suites that must be reached).
REPO_CASES = [
    (["sdk/tests/support/genfixtures.nim"], {"test_rmap"}),
    (["docs/DAEMON.md"], {"test_daemon_config"}),
]
NEARLY_ALL = "sdk/src/logos_sdk/commitment/choice.nim"


def self_test(root):
    failures = []
    with tempfile.TemporaryDirectory() as scratch:
        for path, text in SELF_TREE.items():
            os.makedirs(os.path.join(scratch, os.path.dirname(path)), exist_ok=True)
            with open(os.path.join(scratch, path), "w") as f:
                f.write(text)
        tree = Tree.from_dir(scratch)
        for changed, want in SELF_CASES:
            got = set(affected(tree, changed)[0])
            if got != want:
                failures.append(f"planted {changed}: got {sorted(got)}, want {sorted(want)}")
    if os.path.isfile(os.path.join(root, NEARLY_ALL)):
        tree = Tree.from_dir(root)
        for changed, want in REPO_CASES:
            got = set(affected(tree, changed)[0])
            if not want <= got:
                failures.append(f"{changed}: {sorted(want - got)} not reached")
        got, _, total = affected(tree, [NEARLY_ALL])
        if len(got) < 0.9 * total:
            failures.append(f"{NEARLY_ALL} reaches {len(got)} of {total} suites, under 90%")
    else:
        failures.append(f"{root} has no {NEARLY_ALL}: not this repository's tree")
    for f in failures:
        print(f"self-test: {f}", file=sys.stderr)
    print(f"self-test: {'failed' if failures else 'passed'}", file=sys.stderr)
    return 1 if failures else 0


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("base", nargs="?", help="the merge base (a git revision)")
    ap.add_argument("tree", nargs="?", default="HEAD", help="the merged tree (a git revision; HEAD)")
    ap.add_argument("--repo", default=here, help="the git repository (this one)")
    ap.add_argument("--root", help="read this directory instead of a git tree")
    ap.add_argument("--changed", nargs="+", help="the changed paths, with --root")
    ap.add_argument("--variant", help="print `<suite>-VARIANT`, the flake check")
    ap.add_argument("--why", action="store_true", help="print a chain from a changed file to each suite")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test(a.root or here)
    if a.root:
        if not a.changed or a.base:
            ap.error("--root takes --changed and no revisions")
        tree, changed = Tree.from_dir(a.root), a.changed
    else:
        if not a.base or a.changed:
            ap.error("give BASE [TREE], or --root with --changed")
        diff = git(a.repo, "diff", "--name-only", "--no-renames", "-z", a.base, a.tree)
        tree, changed = Tree.from_git(a.repo, a.tree), [f for f in diff.split("\0") if f]
    result, unmapped, total = affected(tree, changed)
    for name in sorted(result):
        line = f"{name}-{a.variant}" if a.variant else name
        print(f"{line}: {' <- '.join(result[name])}" if a.why else line)
    print(f"{len(result)} of {total} suites from {len(changed)} changed files", file=sys.stderr)
    if unmapped:
        print("reaching no suite: " + ", ".join(unmapped), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
