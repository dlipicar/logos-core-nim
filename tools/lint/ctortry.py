#!/usr/bin/env python3
"""Flags a `?` evaluated while an object, tuple or array constructor is half built.

[IMPL] Nim 2.2.14 under ORC (DECISIONS I77): when a `?` returns early from inside a
constructor, what the constructor already holds is never destroyed. A ref object
is allocated before its fields, so any `?` among them leaks it; a value object,
tuple or array leaks the owned elements built before the `?`. Calls are not
affected: their argument temporaries are destroyed. So every `?` that is inside
an object constructor, or inside a tuple or array constructor after its first
element, must be hoisted into a `let` before the constructor.

  python3 tools/lint/ctortry.py [root ...]   (default: src sdk/src sdk/tests tests)
  python3 tools/lint/ctortry.py --self-test

Prints `file:line: ...` for each such `?` and exits 1 if there is any. A root that is not a
directory, or a run that finds no `.nim` file at all, exits 2: run from the wrong folder or with a
mistyped path, the lint would otherwise check nothing and pass.
"""

import contextlib
import io
import os
import re
import sys
import tempfile

KEYWORDS = {
    "and", "or", "not", "xor", "if", "elif", "when", "case", "of", "return",
    "discard", "in", "notin", "is", "isnot", "div", "mod", "shl", "shr", "while",
    "yield", "raise", "echo",
}
IDENT_AT_END = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*$")


class Frame:
    def __init__(self, kind, name):
        self.kind = kind  # "ctor", "call", "group" (tuple or parentheses), "literal", "index"
        self.name = name
        self.comma = False


def frame_for(src, i):
    """The frame an opening bracket at `src[i]` starts."""
    c = src[i]
    before = src[max(0, i - 80) : i]
    if c == "(":
        m = IDENT_AT_END.search(before)
        if m and before.endswith(m.group(1)) and m.group(1) not in KEYWORDS:
            name = m.group(1)
            return Frame("ctor" if name[0].isupper() else "call", name)
        return Frame("group", "(")
    if c == "[":
        last = before.rstrip()[-1:] if before.rstrip() else ""
        if before.endswith("@") or not (last.isalnum() or last in "_])`"):
            return Frame("literal", "[")
        return Frame("index", "[")
    return Frame("literal", "{")


def skip_string(src, i):
    """The index after a string literal starting at `src[i]`."""
    if src.startswith('"""', i):
        return src.index('"""', i + 3) + 3
    raw = i > 0 and (src[i - 1].isalnum() or src[i - 1] == "_")
    i += 1
    while i < len(src) and src[i] != '"':
        if src[i] == "\\" and not raw:
            i += 1
        i += 1
    return i + 1


def findings(path):
    src = open(path, encoding="utf-8").read()
    out = []
    stack = []
    i, n, line = 0, len(src), 1
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c == "#":
            if src.startswith("#[", i) or src.startswith("##[", i):
                depth, i = 1, i + 2
                while i < n and depth:
                    if src.startswith("]#", i):
                        depth, i = depth - 1, i + 2
                        continue
                    if src.startswith("#[", i):
                        depth, i = depth + 1, i + 2
                        continue
                    line += src[i] == "\n"
                    i += 1
                continue
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == '"':
            j = skip_string(src, i)
            line += src[i:j].count("\n")
            i = j
            continue
        if c == "'":
            m = re.match(r"'(\\.|[^\\'])+'", src[i:])
            i += len(m.group(0)) if m and len(m.group(0)) <= 6 else 1
            continue
        if c in "([{":
            stack.append(frame_for(src, i))
        elif c in ")]}":
            if stack:
                stack.pop()
        elif c == "," and stack:
            stack[-1].comma = True
        elif c == "?" and stack:
            prev = src[i - 1] if i else " "
            nxt = src[i + 1] if i + 1 < n else " "
            if prev in " \t\n(,:=[{" and (nxt.isalpha() or nxt in "(_"):
                for f in stack:
                    if f.kind == "ctor":
                        out.append((line, f"`?` inside the constructor {f.name}(...)"))
                        break
                    if f.kind in ("group", "literal") and f.comma:
                        out.append((line, "`?` after the first element of a tuple or array"))
                        break
        i += 1
    return out


def lint(roots):
    """The exit status over `roots`: 0 clean, 1 a finding, 2 nothing to check."""
    for root in roots:
        if not os.path.isdir(root):
            print(f"ctortry: {root}: not a directory", file=sys.stderr)
            return 2
    count = scanned = 0
    for root in roots:
        for d, _, files in os.walk(root):
            for name in sorted(files):
                # Not exFAT's AppleDouble `._x.nim`, which holds no Nim (a TMPDIR or a
                # checkout on /Volumes/macOS_ext).
                if name.endswith(".nim") and not name.startswith("._"):
                    scanned += 1
                    path = os.path.join(d, name)
                    for line, what in findings(path):
                        print(f"{path}:{line}: {what}; hoist it into a let")
                        count += 1
    if not scanned:
        print(f"ctortry: no .nim file under {' '.join(roots)}", file=sys.stderr)
        return 2
    return 1 if count else 0


# The self-test: the two runs that check nothing, a planted `?` and its hoisted form.
PLANTED = "proc f(): Result[Foo, string] =\n  ok(Foo(a: ?g()))\n"
HOISTED = "proc f(): Result[Foo, string] =\n  let a = ?g()\n  ok(Foo(a: a))\n"


def self_test():
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        dirs = {}
        for name, text in (("empty", None), ("planted", PLANTED), ("hoisted", HOISTED)):
            dirs[name] = os.path.join(tmp, name)
            os.mkdir(dirs[name])
            if text is not None:
                with open(os.path.join(dirs[name], "a.nim"), "w", encoding="utf-8") as f:
                    f.write(text)
        # its hoisted form, beside an AppleDouble file whose bytes would be a finding.
        dirs["appledouble"] = os.path.join(tmp, "appledouble")
        os.mkdir(dirs["appledouble"])
        with open(os.path.join(dirs["appledouble"], "a.nim"), "w", encoding="utf-8") as f:
            f.write(HOISTED)
        with open(os.path.join(dirs["appledouble"], "._a.nim"), "wb") as f:
            f.write(b"\x00\x05\x16\x07" + PLANTED.encode())
        missing = os.path.join(tmp, "missing")
        cases = [
            ("a missing root", [missing], 2),
            ("a missing root beside a good one", [dirs["hoisted"], missing], 2),
            ("an empty root", [dirs["empty"]], 2),
            ("a planted `?`", [dirs["planted"]], 1),
            ("its hoisted form", [dirs["hoisted"]], 0),
            ("its hoisted form beside a `._` file", [dirs["appledouble"]], 0),
        ]
        for what, roots, want in cases:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                got = lint(roots)
            if got != want:
                failures.append(f"{what}: exit {got}, want {want}")
    for failure in failures:
        print("self-test:", failure)
    if failures:
        return 1
    print(f"ctortry self-test: {len(cases)} cases")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    sys.exit(lint(sys.argv[1:] or ["src", "sdk/src", "sdk/tests", "tests"]))
