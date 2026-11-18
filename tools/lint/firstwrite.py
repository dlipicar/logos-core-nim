#!/usr/bin/env python3
"""Flags a local whose value Nim drops without destroying it at its next write.

[IMPL] Nim 2.2.14 under ORC (DECISIONS I92; nim-lang/Nim#26725, also on devel): a local
declared without an initializer (`var x: T`, a `var` section entry, or `result`) and
first written inside a branch, a loop or a `try` body is written again at its own
level with a plain store: the value the branch gave it is never destroyed, so it is
never wiped either. Giving the local an initializer (`var x: T = default(T)`, or
`result = ...` before the branch) makes the later write destroy the old value.

  python3 tools/lint/firstwrite.py src tests

Prints `file:line: ...` for each such local and exits 1 if there is any. A heuristic
over the source text: scalar types are skipped, a write in a `when` branch counts at
the `when`'s level, and a branch that ends in `return`, `raise` or `quit` is left out.
"""

import os
import re
import sys

SCALAR = re.compile(
    r"^(u?int(8|16|32|64)?|float(32|64)?|bool|char|byte|Natural|Positive|csize_t|"
    r"c[a-z]+|pointer|ptr\b.*|Duration|MonoTime|Time)$"
)
EXIT = re.compile(r"^\s*(return|raise|quit)\b")
ONE_LINE = r"^\s*(if|elif|else|of|except|while|for|try|finally)\b[^#]*:\s*{}\s*=[^=]"
OPENER = re.compile(r"^\s*(when|if|case|try|elif|else|of|except|finally)\b")
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


def check(lines, start, dind, name):
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
        if one.match(line) and not re.search(r"\b(return|raise)\b", line):
            if nested is None and not re.match(r"^\s*when\b", line):
                nested = j
            continue
        if plain.match(line):
            if level(lines, j) > dind:
                if nested is None and not exits(lines, j):
                    nested = j
            elif nested is not None:
                return (nested, j)
            else:
                return None
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
    for i, dind, name, typ in declarations(lines):
        if SCALAR.match(typ.strip()):
            continue
        hit = check(lines, i + 1, dind, name)
        if hit:
            yield i + 1, name, hit[0] + 1, hit[1] + 1


def main(roots):
    count = 0
    for root in roots:
        for d, _, files in os.walk(root):
            for name in sorted(files):
                if name.endswith(".nim"):
                    path = os.path.join(d, name)
                    for line, local, first, later in findings(path):
                        print(f"{path}:{line}: `{local}` is first written in a branch (line {first}) "
                              f"and written again at line {later}, which drops that value; "
                              f"give it an initializer")
                        count += 1
    return 1 if count else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["src", "sdk/src", "sdk/tests", "tests"]))
