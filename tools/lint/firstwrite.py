#!/usr/bin/env python3
"""Flags a local whose value Nim drops without destroying it at its next write.

[IMPL] Nim 2.2.14 under ORC (DECISIONS I92; nim-lang/Nim#26725, also on devel): a local
declared without an initializer (`var x: T`, a `var` section entry, or `result`) and
first written inside a branch, a loop or a `try` body is written again at its own
level with a plain store: the value the branch gave it is never destroyed, so it is
never wiped either. Giving the local an initializer (`var x: T = default(T)`, or
`result = ...` before the branch) makes the later write destroy the old value.

  python3 tools/lint/firstwrite.py [root ...]   (default: src sdk/src sdk/tests tests)
  python3 tools/lint/firstwrite.py --self-test

The same holds for a local first written inside a `for` or `while` loop and written
again in a branch after that loop, whether the later value is `nil`, `""`, `@[]`,
`default(T)` or a fresh one (run1-san-remote: `describeProvider`'s `owner`, written in
the loop over the instances and then `nil` in an `if`, kept the instance it held). A
later write inside another loop leaves no value behind in 2.2.14 and is not flagged.

A write in a local `template`'s body counts where the template is called: at the call's
level when the write is at the body's top level, nested when it is inside a branch of the
body (run1-san-remote: `genfixtures_core.cddlRules`' `flush()` after its loop reset `text`
at the declaring level and dropped the loop's buffer).

Prints `file:line: ...` for each such local and exits 1 if there is any. A heuristic
over the source text: scalar types are skipped, a write in a `when` branch counts at
the `when`'s level, and a branch that ends in `return`, `raise` or `quit` is left out.
A root that is not a directory, or a run that finds no `.nim` file at all, exits 2: run
from the wrong folder or with a mistyped path, the lint would otherwise check nothing
and pass.
"""

import contextlib
import io
import os
import re
import sys
import tempfile

SCALAR = re.compile(
    r"^(u?int(8|16|32|64)?|float(32|64)?|bool|char|byte|Natural|Positive|csize_t|"
    r"c[a-z]+|pointer|ptr\b.*|Duration|MonoTime|Time)$"
)
EXIT = re.compile(r"^\s*(return|raise|quit)\b")
ONE_LINE = r"^\s*(if|elif|else|of|except|while|for|try|finally)\b[^#]*:\s*{}\s*=[^=]"
OPENER = re.compile(r"^\s*(when|if|case|try|elif|else|of|except|finally)\b")
LOOP = re.compile(r"^\s*(for|while)\b")
TEMPLATE = re.compile(r"^(\s*)template\s+([A-Za-z_]\w*)\*?\s*[(\[:=]")
NO_TEMPLATES = (frozenset(), {})
ROUTINE = re.compile(r"^(\s*)(proc|func|method|converter)\s")


def blank_strings(src):
    """The source with triple-quoted string contents blanked, line count kept."""
    out, i = [], 0
    while True:
        j = src.find('"""', i)
        if j < 0:
            out.append(src[i:])
            return "".join(out)
        k = src.find('"""', j + 3)
        if k < 0:
            out.append(src[i:])
            return "".join(out)
        out.append(src[i:j + 3])
        out.append("\n" * src[j + 3:k].count("\n"))
        out.append('"""')
        i = k + 3


def indent(line):
    return len(line) - len(line.lstrip())


def is_code(line):
    s = line.strip()
    return s != "" and not s.startswith("#")


def opener(lines, j):
    """The index of the line that opens the block holding line `j`, or None."""
    li = indent(lines[j])
    for k in range(j - 1, -1, -1):
        if is_code(lines[k]) and indent(lines[k]) < li:
            return k
    return None


def chain_head(lines, k):
    """For an `elif`/`else`/`of` line, the `when`/`if`/`case`/`try` it continues."""
    ki = indent(lines[k])
    while k is not None and re.match(r"^\s*(elif|else|of|except|finally)\b", lines[k]):
        k = next((m for m in range(k - 1, -1, -1)
                  if is_code(lines[m]) and indent(lines[m]) <= ki), None)
        if k is not None and indent(lines[k]) < ki:
            return None
    return k


def level(lines, j):
    """The indent at which line `j` runs: a `when` branch counts at the `when`'s level."""
    li = indent(lines[j])
    k = opener(lines, j)
    while k is not None and OPENER.match(lines[k]):
        head = chain_head(lines, k)
        if head is None or not re.match(r"^\s*when\b", lines[head]):
            break
        li = indent(lines[head])
        k = opener(lines, head)
    return li


def exits(lines, j):
    """Whether the block holding the write on line `j` leaves before falling through."""
    li = indent(lines[j])
    for k in range(j + 1, len(lines)):
        if not is_code(lines[k]):
            continue
        if indent(lines[k]) < li:
            return False
        if indent(lines[k]) == li and EXIT.match(lines[k]):
            return True
    return False


def templates(lines):
    """(the lines of every template body, each template's writes: name -> at its top level)."""
    body, writes = set(), {}
    for i, line in enumerate(lines):
        m = TEMPLATE.match(line)
        if not m:
            continue
        ti, top, names = len(m.group(1)), None, {}
        for k in range(i + 1, len(lines)):
            if not is_code(lines[k]):
                continue
            if indent(lines[k]) <= ti:
                break
            body.add(k)
            if top is None:
                top = indent(lines[k])
            w = re.match(r"^\s*([A-Za-z_]\w*)\s*=[^=]", lines[k])
            if w:
                names[w.group(1)] = names.get(w.group(1), False) or indent(lines[k]) == top
                continue
            w = re.match(ONE_LINE.format(r"([A-Za-z_]\w*)"), lines[k])
            if w:
                names.setdefault(w.group(2), False)
        writes[m.group(2)] = names
    return body, writes


def called(line, tmpl, name):
    """How a statement that only calls a local template writes `name`: "top", "nested" or None."""
    m = re.match(r"^\s*([A-Za-z_]\w*)\s*(\(.*\))?\s*(#.*)?$", line)
    if not m or name not in tmpl[1].get(m.group(1), {}):
        return None
    return "top" if tmpl[1][m.group(1)][name] else "nested"


def check(lines, start, dind, name, tmpl=NO_TEMPLATES):
    """(first write in a branch, later write) for `name` declared at `dind`, or None."""
    plain = re.compile(r"^\s*" + re.escape(name) + r"\s*=[^=]")
    one = re.compile(ONE_LINE.format(re.escape(name)))
    nested = None
    for j in range(start, len(lines)):
        line = lines[j]
        if not is_code(line):
            continue
        if indent(line) < dind:
            return None
        if j in tmpl[0]:
            continue  # a template's body runs where it is called
        call = called(line, tmpl, name)
        if call == "nested" or (one.match(line) and not re.search(r"\b(return|raise)\b", line)):
            if nested is None and not re.match(r"^\s*when\b", line):
                nested = j
            continue
        if plain.match(line) or call == "top":
            if level(lines, j) > dind:
                if nested is None and not exits(lines, j):
                    nested = j
            elif nested is not None:
                return (nested, j)
            else:
                return None
    return None


def enclosing(lines, j, dind):
    """The lines opening the blocks that hold line `j` down to `dind`, innermost first."""
    chain = []
    k = opener(lines, j)
    while k is not None and indent(lines[k]) >= dind:
        chain.append(k)
        k = opener(lines, k)
    return chain


def check_loop(lines, start, dind, name, tmpl=NO_TEMPLATES):
    """(first write inside a loop, later write in a branch after it) for `name`, or None."""
    plain = re.compile(r"^\s*" + re.escape(name) + r"\s*=[^=]")
    one = re.compile(ONE_LINE.format(re.escape(name)))
    held = None  # (the outermost loop holding the first write, that write's line)
    for j in range(start, len(lines)):
        line = lines[j]
        if not is_code(line):
            continue
        if indent(line) < dind:
            return None
        if j in tmpl[0]:
            continue  # a template's body runs where it is called
        call = called(line, tmpl, name)
        if call == "nested":
            chain = enclosing(lines, j, dind)
            nested = True
        elif one.match(line):
            if re.search(r"\b(return|raise)\b", line) or re.match(r"^\s*when\b", line):
                continue
            chain = [j] + enclosing(lines, j, dind)
            nested = True
        elif plain.match(line) or call == "top":
            chain = enclosing(lines, j, dind)
            nested = level(lines, j) > dind
        else:
            continue
        if not nested:
            return None  # written on every path from here on (the other check's form)
        loops = [k for k in chain if LOOP.match(lines[k])]
        if held is None:
            if loops and not ((plain.match(line) or call == "top") and exits(lines, j)):
                held = (loops[-1], j)
            continue
        if held[0] in chain or loops:
            continue
        return (held[1], j)
    return None


def declarations(lines):
    """(line index, declaring indent, name, type) for each local without an initializer."""
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)var\s+([A-Za-z_][\w, ]*?)\s*:\s*([^=#]+?)\s*(#.*)?$", line)
        if m:
            for name in m.group(2).split(","):
                yield i, len(m.group(1)), name.strip(), m.group(3)
            continue
        if re.match(r"^\s*var\s*(#.*)?$", line):
            vi = indent(line)
            for k in range(i + 1, len(lines)):
                if is_code(lines[k]) and indent(lines[k]) <= vi:
                    break
                e = re.match(r"^\s*([A-Za-z_][\w, ]*?)\s*:\s*([^=#]+?)\s*(#.*)?$", lines[k])
                if e and is_code(lines[k]):
                    for name in e.group(1).split(","):
                        yield k, vi, name.strip(), e.group(2)
            continue
        m = ROUTINE.match(line)
        if m:
            sig, k = line, i
            while not re.search(r"=\s*(#.*)?$", lines[k]):
                if k + 1 >= len(lines) or k - i >= 12 or indent(lines[k + 1]) <= len(m.group(1)):
                    break  # a one-line routine, or a signature without a body
                k += 1
                sig += " " + lines[k].strip()
            if not re.search(r"=\s*(#.*)?$", lines[k]):
                continue
            r = re.search(r"[)\]]\s*:\s*([^={]+?)\s*(\{\..*\.\})?\s*=\s*(#.*)?$", sig)
            if not r:
                continue
            b = next((n for n in range(k + 1, len(lines)) if is_code(lines[n])), None)
            if b is not None and indent(lines[b]) > len(m.group(1)):
                yield b - 1, indent(lines[b]), "result", r.group(1)


def findings(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = blank_strings(f.read()).split("\n")
    tmpl = templates(lines)
    for i, dind, name, typ in declarations(lines):
        if SCALAR.match(typ.strip()):
            continue
        hit = check(lines, i + 1, dind, name, tmpl)
        if hit:
            yield i + 1, name, hit[0] + 1, hit[1] + 1, "branch"
            continue
        hit = check_loop(lines, i + 1, dind, name, tmpl)
        if hit:
            yield i + 1, name, hit[0] + 1, hit[1] + 1, "loop"


def lint(roots):
    """The exit status over `roots`: 0 clean, 1 a finding, 2 nothing to check."""
    for root in roots:
        if not os.path.isdir(root):
            print(f"firstwrite: {root}: not a directory", file=sys.stderr)
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
                    for line, local, first, later, kind in findings(path):
                        if kind == "loop":
                            print(f"{path}:{line}: `{local}` is first written in a loop (line {first}) "
                                  f"and written again in a branch after it at line {later}, which "
                                  f"drops that value; give it an initializer")
                        else:
                            print(f"{path}:{line}: `{local}` is first written in a branch (line {first}) "
                                  f"and written again at line {later}, which drops that value; "
                                  f"give it an initializer")
                        count += 1
    if not scanned:
        print(f"firstwrite: no .nim file under {' '.join(roots)}", file=sys.stderr)
        return 2
    return 1 if count else 0


# The self-test: the two runs that check nothing, a planted local and its initialized form.
PLANTED = 'proc f(c: bool): string =\n  var x: string\n  if c:\n    x = "a"\n  x = "b"\n  x\n'
INITIALIZED = 'proc f(c: bool): string =\n  var x: string = ""\n  if c:\n    x = "a"\n  x = "b"\n  x\n'
# ifleak/loopnil.nim's leaking shape (upstream ISSUES.md 131), its initialized form, and the
# forms 2.2.14 does not leak: the later write inside another loop or inside the same loop.
LOOPNIL = ('proc f(xs: seq[Inst], c: bool): bool =\n  var x: Inst\n  for y in xs:\n'
           '    if y.id.len > 0:\n      x = y\n  if c:\n    x = nil\n  x.isNil\n')
LOOPNIL_INITIALIZED = LOOPNIL.replace("var x: Inst\n", "var x: Inst = nil\n")
LOOPNIL_LATER_LOOP = LOOPNIL.replace("  if c:\n    x = nil\n", "  for z in xs:\n    if c:\n      x = nil\n")
# genfixtures_core.cddlRules' shape: the reset after the loop is a local template's call.
TEMPLATE_RESET = ('func f(doc: seq[string]): seq[string] =\n  var text: seq[string]\n'
                  '  template flush() =\n    if text.len > 0:\n      result.add(text[0])\n'
                  '    text = @[]\n  for line in doc:\n    if line.len == 0:\n      flush()\n'
                  '    else:\n      text.add(line)\n  flush()\n')
TEMPLATE_RESET_INITIALIZED = TEMPLATE_RESET.replace("var text: seq[string]\n", "var text: seq[string] = @[]\n")
LOOPNIL_SAME_LOOP = ('proc f(xs: seq[Inst], c: bool): bool =\n  var x: Inst\n  for y in xs:\n'
                     '    if y.id.len > 0:\n      x = y\n    elif c:\n      x = nil\n  x.isNil\n')


def self_test():
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        dirs = {}
        for name, text in (("empty", None), ("planted", PLANTED), ("initialized", INITIALIZED),
                           ("loopnil", LOOPNIL), ("loopnil-initialized", LOOPNIL_INITIALIZED),
                           ("loopnil-later-loop", LOOPNIL_LATER_LOOP),
                           ("loopnil-same-loop", LOOPNIL_SAME_LOOP),
                           ("template-reset", TEMPLATE_RESET),
                           ("template-reset-initialized", TEMPLATE_RESET_INITIALIZED)):
            dirs[name] = os.path.join(tmp, name)
            os.mkdir(dirs[name])
            if text is not None:
                with open(os.path.join(dirs[name], "a.nim"), "w", encoding="utf-8") as f:
                    f.write(text)
        # its initialized form, beside an AppleDouble file whose bytes would be a finding.
        dirs["appledouble"] = os.path.join(tmp, "appledouble")
        os.mkdir(dirs["appledouble"])
        with open(os.path.join(dirs["appledouble"], "a.nim"), "w", encoding="utf-8") as f:
            f.write(INITIALIZED)
        with open(os.path.join(dirs["appledouble"], "._a.nim"), "wb") as f:
            f.write(b"\x00\x05\x16\x07" + PLANTED.encode())
        missing = os.path.join(tmp, "missing")
        cases = [
            ("a missing root", [missing], 2),
            ("a missing root beside a good one", [dirs["initialized"], missing], 2),
            ("an empty root", [dirs["empty"]], 2),
            ("a planted local", [dirs["planted"]], 1),
            ("its initialized form", [dirs["initialized"]], 0),
            ("its initialized form beside a `._` file", [dirs["appledouble"]], 0),
            ("a local written in a loop, then nil in a branch", [dirs["loopnil"]], 1),
            ("its initialized form", [dirs["loopnil-initialized"]], 0),
            ("the nil in a later loop", [dirs["loopnil-later-loop"]], 0),
            ("the nil in the same loop", [dirs["loopnil-same-loop"]], 0),
            ("a reset by a local template's call after the loop", [dirs["template-reset"]], 1),
            ("its initialized form", [dirs["template-reset-initialized"]], 0),
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
    print(f"firstwrite self-test: {len(cases)} cases")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    sys.exit(lint(sys.argv[1:] or ["src", "sdk/src", "sdk/tests", "tests"]))
