#!/usr/bin/env python3
"""Refuses a second Nim `importc` of a function our own C sources define.

[DECISIONS I147] Without `header:`, each Nim `importc` writes its own C prototype into the
module that declares it, and the C compiler checks every call against that copy only. A second
declaration of one of our functions therefore falls behind silently when the function's
parameters change: G492 added `system` to `hostspawn.c`'s spawn, two copies kept the old list,
their calls left the pid at -1, and the signal that followed (`kill(-1)`) reached every process
the user owns. Each function our C files define is declared once, in the module that compiles
its file (and, where its header exists, with `header:`); other modules import that declaration.

  python3 tools/lint/cimports.py [root ...]   (default: src sdk/src sdk/tests tests)
  python3 tools/lint/cimports.py --self-test

The functions are the non-static definitions in the roots' `.c` files; the declarations, every
`importc` pragma in their `.nim` files, named by `importc: "name"` or, bare, by the Nim name it
is attached to. Prints `file:line: ...` for each declaration of a function declared more than
once and exits 1 if there is any. A root that is not a directory, or a run that finds no `.c` or
no `.nim` file, exits 2: run from the wrong folder or with a mistyped path, the lint would
otherwise check nothing and pass.
"""

import contextlib
import io
import os
import re
import sys
import tempfile

C_KEYWORDS = {
    "if", "for", "while", "switch", "return", "sizeof", "do", "else", "case",
    "__attribute__", "__declspec", "_Alignas", "alignas", "__asm__", "asm",
    "defined", "_Static_assert", "static_assert",
}
IDENT_BEFORE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*$")
NIM_DECL = re.compile(r"(?m)^[ \t]*(?:proc|func)[ \t]+(`[^`\n]+`|[A-Za-z_][A-Za-z0-9_]*)")
NIM_VARIABLE = re.compile(r"[ \t]*(?:(?:var|let)[ \t]+)?(`[^`\n]+`|[A-Za-z_][A-Za-z0-9_]*)\*?[ \t]*$")
IMPORTC = re.compile(r"\bimportc\b")
IMPORTC_NAME = re.compile(r'\bimportc\s*:\s*"([^"]*)"')
WINDOW = 4000  # how far back a pragma's declaration may start


def strip_c(src):
    """`src` with comments, string and character literals and preprocessor lines blanked;
    newlines kept, so offsets keep their line numbers."""
    out = []
    i, n = 0, len(src)
    at_line_start = True
    while i < n:
        c = src[i]
        if at_line_start and c in " \t":
            out.append(c)
            i += 1
            continue
        if at_line_start and c == "#":
            # A directive, with its continuation lines.
            while i < n and src[i] != "\n":
                if src[i] == "\\" and i + 1 < n and src[i + 1] == "\n":
                    out.append(" \n")
                    i += 2
                    continue
                out.append(" ")
                i += 1
            continue
        at_line_start = False
        if c == "\n":
            out.append(c)
            at_line_start = True
            i += 1
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join(ch if ch == "\n" else " " for ch in src[i:j]))
            i = j
        elif src.startswith("//", i):
            while i < n and src[i] != "\n":
                out.append(" ")
                i += 1
        elif c in "\"'":
            j = i + 1
            while j < n and src[j] != c and src[j] != "\n":
                j += 2 if src[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(" " * (j - i))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def c_definitions(path):
    """The non-static functions `path` defines: a name, then its parameters, then a body, at
    the file's top level."""
    src = strip_c(open(path, encoding="utf-8", errors="replace").read())
    found = []
    depth = 0
    decl_start = 0  # where the current top-level declaration began
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                decl_start = i + 1
        elif c == ";" and depth == 0:
            decl_start = i + 1
        elif c == "(" and depth == 0:
            m = IDENT_BEFORE.search(src[max(decl_start, i - 200) : i])
            # Its parameters, to the matching parenthesis.
            j, level = i, 0
            while j < n:
                if src[j] == "(":
                    level += 1
                elif src[j] == ")":
                    level -= 1
                    if level == 0:
                        break
                j += 1
            k = j + 1
            while k < n and src[k] in " \t\r\n":
                k += 1
            if m and m.group(1) not in C_KEYWORDS and k < n and src[k] == "{":
                specifiers = src[decl_start : i]
                if not re.search(r"\bstatic\b", specifiers):
                    found.append(m.group(1))
            i = j + 1
            continue
        i += 1
    return found


def strip_nim(src):
    """`src` with comments and string contents blanked, but for the strings of `importc:`,
    which name the function; newlines kept."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "#":
            if src.startswith("#[", i) or src.startswith("##[", i):
                depth, j = 1, i + (3 if src.startswith("##[", i) else 2)
                while j < n and depth:
                    if src.startswith("]#", j):
                        depth, j = depth - 1, j + 2
                        continue
                    if src.startswith("#[", j):
                        depth, j = depth + 1, j + 2
                        continue
                    j += 1
            else:
                j = src.find("\n", i)
                j = n if j < 0 else j
            out.append("".join(ch if ch == "\n" else " " for ch in src[i:j]))
            i = j
        elif c == '"':
            if src.startswith('"""', i):
                j = src.find('"""', i + 3)
                j = n if j < 0 else j + 3
            else:
                raw = i > 0 and (src[i - 1].isalnum() or src[i - 1] == "_")
                j = i + 1
                while j < n and src[j] != '"' and src[j] != "\n":
                    j += 2 if (src[j] == "\\" and not raw) else 1
                j = min(j + 1, n)
            if re.search(r"\bimportc\s*:\s*$", "".join(out[-40:])):
                out.append(src[i:j])
            else:
                out.append('"' + "".join(ch if ch == "\n" else " " for ch in src[i + 1 : j - 1]) + '"')
            i = j
        elif c == "'":
            m = re.match(r"'(\\.|[^\\'\n])+'", src[i:i + 8])
            j = i + (len(m.group(0)) if m and len(m.group(0)) <= 6 else 1)
            out.append(" " * (j - i))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def nim_imports(path):
    """(line, C name) for each `importc` pragma in `path`."""
    src = strip_nim(open(path, encoding="utf-8", errors="replace").read())
    found = []
    pos = 0
    while True:
        start = src.find("{.", pos)
        if start < 0:
            break
        end = src.find(".}", start + 2)
        if end < 0:
            break
        body = src[start + 2 : end]
        pos = end + 2
        if not IMPORTC.search(body):
            continue
        named = IMPORTC_NAME.search(body)
        head = src[src.rfind("\n", 0, start) + 1 : start]
        variable = NIM_VARIABLE.match(head)
        if named:
            name = named.group(1)
        elif variable:
            # `var x {.importc.}: T`, or `x {.importc.}: T` in a var section.
            name = variable.group(1).strip("`")
        else:
            decls = list(NIM_DECL.finditer(src, max(0, start - WINDOW), start))
            name = decls[-1].group(1).strip("`") if decls else ""
        if name:
            found.append((src.count("\n", 0, start) + 1, name))
    return found


def walk(roots, suffix):
    for root in roots:
        for d, _, files in os.walk(root):
            for name in sorted(files):
                # Not exFAT's AppleDouble `._x`, which holds no source.
                if name.endswith(suffix) and not name.startswith("._"):
                    yield os.path.join(d, name)


def lint(roots):
    """The exit status over `roots`: 0 clean, 1 a finding, 2 nothing to check."""
    for root in roots:
        if not os.path.isdir(root):
            print(f"cimports: {root}: not a directory", file=sys.stderr)
            return 2
    defined = {}
    for path in walk(roots, ".c"):
        for name in c_definitions(path):
            defined.setdefault(name, path)
    nim_files = list(walk(roots, ".nim"))
    if not defined or not nim_files:
        print(f"cimports: no .c or no .nim file under {' '.join(roots)}", file=sys.stderr)
        return 2
    declared = {}
    for path in nim_files:
        for line, name in nim_imports(path):
            if name in defined:
                declared.setdefault(name, []).append((path, line))
    count = 0
    for name in sorted(declared):
        sites = declared[name]
        if len(sites) > 1:
            count += 1
            first = f"{sites[0][0]}:{sites[0][1]}"
            for path, line in sites[1:]:
                print(
                    f"{path}:{line}: a second importc of {name} ({defined[name]}), first at "
                    f"{first}; import that declaration instead"
                )
    print(
        f"cimports: {len(defined)} functions in our C sources, {len(declared)} imported, "
        f"{count} more than once"
    )
    return 1 if count else 0


# The self-test: the runs that check nothing, a planted second declaration in both forms, the
# single declaration, a static function's name and a C library function's, both declared
# twice, and an AppleDouble copy of a declaration.
C_FILE = """\
#include <stdio.h>
/* int lcn_commented(int a) { return a; } */
#define LCN_MACRO(a) { (a); }
static int lcn_helper(int a) { return a; }
int lcn_spawn(const char *path,
              int fd)
{
  return lcn_helper(fd) + (path != 0);
}
int lcn_proto(int a);
"""
ONE = 'proc spawn*(path: cstring, fd: cint): cint {.importc: "lcn_spawn", header: "x.h".}\n'
NAMED_AGAIN = 'proc spawnCopy(path: cstring, fd: cint): cint {.importc: "lcn_spawn".}\n'
BARE_AGAIN = 'proc lcn_spawn(\n    path: cstring,\n    fd: cint,\n): cint {.\n  importc, cdecl\n.}\n'
NOT_OURS = (
    'proc lcn_helper(a: cint): cint {.importc.}\n'
    'proc lcn_proto(a: cint): cint {.importc.}\n'
    'proc close(fd: cint): cint {.importc, header: "<unistd.h>".}\n'
    '## {.importc: "lcn_spawn".} in a comment\n'
    'const text = "{.importc: \\"lcn_spawn\\".}"\n'
)


def self_test():
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        def tree(name, files):
            d = os.path.join(tmp, name)
            os.mkdir(d)
            for fname, text in files.items():
                mode = "wb" if isinstance(text, bytes) else "w"
                with open(os.path.join(d, fname), mode) as f:
                    f.write(text)
            return d

        empty = tree("empty", {})
        no_c = tree("no_c", {"a.nim": ONE})
        named = tree("named", {"x.c": C_FILE, "a.nim": ONE, "b.nim": NAMED_AGAIN})
        bare = tree("bare", {"x.c": C_FILE, "a.nim": ONE, "b.nim": BARE_AGAIN})
        single = tree("single", {"x.c": C_FILE, "a.nim": ONE, "b.nim": NOT_OURS, "c.nim": NOT_OURS})
        apple = tree("apple", {"x.c": C_FILE, "a.nim": ONE, "._b.nim": b"\x00\x05\x16\x07" + NAMED_AGAIN.encode()})
        missing = os.path.join(tmp, "missing")
        cases = [
            ("a missing root", [missing], 2),
            ("a missing root beside a good one", [single, missing], 2),
            ("an empty root", [empty], 2),
            ("no C file", [no_c], 2),
            ("a second declaration by `importc: \"name\"`", [named], 1),
            ("a second declaration by a bare `importc` over lines", [bare], 1),
            ("one declaration, with static, prototype-only, libc, comment and string names twice", [single], 0),
            ("one declaration beside a `._` file", [apple], 0),
        ]
        for what, roots, want in cases:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                got = lint(roots)
            if got != want:
                failures.append(f"{what}: exit {got}, want {want}")
        defs = c_definitions(os.path.join(single, "x.c"))
        if defs != ["lcn_spawn"]:
            failures.append(f"the C definitions found: {defs}, want ['lcn_spawn']")
    for failure in failures:
        print("self-test:", failure)
    if failures:
        return 1
    print(f"cimports self-test: {len(cases) + 1} cases")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    sys.exit(lint(sys.argv[1:] or ["src", "sdk/src", "sdk/tests", "tests"]))
