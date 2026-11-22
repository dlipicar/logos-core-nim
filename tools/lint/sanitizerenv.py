#!/usr/bin/env python3
"""Every environment a test gives a Module Host names the sanitizer variables.

[DECISIONS G442] A sanitizer check sends every report, a child's included, to its own
directory (`tools/sanitizer/reports.sh`): the five variables carry `log_path`. A Module Host gets
only the environment its spawn names (`runtime.module_host_env`, I91), so a test that starts
hosts with a list that leaves them out gets hosts that report to stderr, and the check passes
over their reports. The list is `SanitizerEnv` in `tests/support/sanitizerenv.nim`, and only
there. In the test trees:

  one-list   no other definition of `SanitizerEnv`
  host-env   each `moduleHostEnv =`, `module_host_env =`, `newSupervisor(` and `spawnProcess(`
             statement names `SanitizerEnv`
  opt-out    each `startHost(` with `sanitizerEnv = false` is marked

A statement that rightly does neither carries `# [G442] sanitizer-env: <why>` on one of its
lines or on the comment line just above it (a configuration that is only parsed, the helper that
adds the settings itself, a control case).

  python3 tools/lint/sanitizerenv.py tests sdk/tests
  python3 tools/lint/sanitizerenv.py --self-test

Prints `file:line: rule: ...` for each and exits 1 if there is any. A heuristic over the source
text: comment lines and string contents are ignored, and a statement runs on while its brackets
are open (at most 30 lines).
"""

import os
import re
import sys
import tempfile

HOME = os.path.join("tests", "support", "sanitizerenv.nim")
MARKER = re.compile(r"#.*\[G442\] sanitizer-env:\s*\S")
DEFINITION = re.compile(r"^\s*((const|let|var)\s+)?SanitizerEnv\*?\s*(:[^=]*)?=(?!=)")
HOST_ENV = re.compile(r"\b(moduleHostEnv|module_host_env)\s*=(?!=)|\b(newSupervisor|spawnProcess)\(")
OPT_OUT = re.compile(r"\bstartHost\(")
STRING = re.compile(r'"(?:[^"\\]|\\.)*"')


def code_of(line):
    """The line without string contents and without a trailing comment."""
    s = STRING.sub('""', line)
    at = s.find("#")
    return s if at < 0 else s[:at]


def statement(lines, i, start):
    """The text of the statement from line i, column start, while its brackets stay open."""
    depth, text = 0, []
    for j in range(i, min(i + 30, len(lines))):
        part = code_of(lines[j])[start if j == i else 0 :]
        text.append(part)
        for ch in part:
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
        if depth <= 0 and j >= i:
            stripped = part.rstrip()
            # `x =` or `x = Opt.some(` on its own line: the value follows.
            if not stripped.endswith(("=", ",", "(", "[", "&")):
                return "\n".join(text), j
    return "\n".join(text), min(i + 29, len(lines) - 1)


def marked(lines, i, last):
    """The marker on one of the statement's lines, or on a comment line just above it."""
    if i > 0 and lines[i - 1].lstrip().startswith("#") and MARKER.search(lines[i - 1]):
        return True
    return any(MARKER.search(lines[k]) for k in range(i, last + 1))


def check_file(path, rel, out):
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    home = rel.replace(os.sep, "/") == HOME.replace(os.sep, "/")
    for i, line in enumerate(lines):
        if line.lstrip().startswith("#"):
            continue
        code = code_of(line)
        if not home and DEFINITION.search(code):
            out.append(f"{rel}:{i + 1}: one-list: a list of its own; import tests/support/sanitizerenv")
        m = HOST_ENV.search(code)
        if m:
            text, last = statement(lines, i, m.start())
            if "SanitizerEnv" not in text and not marked(lines, i, last):
                what = m.group(1) or m.group(2)
                out.append(f"{rel}:{i + 1}: host-env: `{what}` without SanitizerEnv")
        m = OPT_OUT.search(code)
        if m:
            text, last = statement(lines, i, m.start())
            if re.search(r"\bsanitizerEnv\s*=\s*false\b", text):
                if not marked(lines, i, last):
                    out.append(f"{rel}:{i + 1}: opt-out: a host without the sanitizer settings, unmarked")


def run(roots, base="."):
    out = []
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(os.path.join(base, root)):
            dirnames[:] = sorted(d for d in dirnames if d not in ("build", "nimcache", "nimbledeps"))
            for name in sorted(filenames):
                # `._x.nim`: the metadata file macOS writes beside each file on a FAT or exFAT volume
                # (the self-test's temporary directory under the Mac's dev environment), not source.
                if name.endswith(".nim") and not name.startswith("._"):
                    path = os.path.join(dirpath, name)
                    check_file(path, os.path.relpath(path, base), out)
    return out


CLEAN = {
    "tests/support/sanitizerenv.nim": 'const SanitizerEnv* = ["ASAN_OPTIONS"]\n',
    "tests/test_clean.nim": """
import ./support/sanitizerenv
proc config(): EngineConfig =
  result.moduleHostEnv = @SanitizerEnv
  dc.runtime.module_host_env = Opt.some(@SanitizerEnv & hostEnv)
  dc.runtime.module_host_env =
    Opt.some(
      @SanitizerEnv
    )
  check parse(c).get.moduleHostEnv == @["TSAN_OPTIONS"]
  check parse(c).rejects("module_host_env = nothing")
  # cfg.moduleHostEnv = @[] in a comment
  c.runtime.module_host_env = Opt.some(@["A=B"]) # [G442] sanitizer-env: parsed only
  let s = newSupervisor(program, @["LCN_X"] & @SanitizerEnv)
  let r = startHost(host, sanitizerEnv = false) # [G442] sanitizer-env: the control
  let q = startHost(host, env = @["X=1"])
  let p = spawnProcess(program, whole, fd) # [G442] sanitizer-env: added above
  # [G442] sanitizer-env: Windows, nothing started
  check newSupervisor(getAppFilename(), []).isNil
""",
}
PLANTS = [
    ("one-list", "tests/test_a.nim", "const\n  SanitizerEnv = [\"ASAN_OPTIONS\"]\n"),
    ("one-list", "sdk/tests/test_b.nim", "let SanitizerEnv*: seq[string] = @[]\n"),
    ("host-env", "tests/test_c.nim", "  result.moduleHostEnv = @[\"TSAN_OPTIONS\"]\n"),
    ("host-env", "tests/test_d.nim", "  dc.runtime.module_host_env =\n    Opt.some(@[\"X\"])\n  let y = 1\n"),
    ("host-env", "tests/test_e.nim", "  let s = newSupervisor(program, [\"LCN_SPAWN_PASSED\"])\n"),
    ("host-env", "tests/test_f.nim", "  let p = spawnProcess(\n    program, env, fd\n  )\n"),
    ("opt-out", "tests/test_g.nim", "  var r = startHost(\n    host, sanitizerEnv = false\n  )\n"),
    ("host-env", "tests/test_h.nim", "  # [G442] sanitizer-env: the line above only\n  let x = 1\n  let s = newSupervisor(p, [])\n"),
]


def self_test():
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        for rel, text in CLEAN.items():
            os.makedirs(os.path.dirname(os.path.join(tmp, rel)), exist_ok=True)
            with open(os.path.join(tmp, rel), "w", encoding="utf-8") as f:
                f.write(text)
        found = run(["tests", "sdk/tests"], tmp)
        if found:
            failures.append(f"the clean tree reports {found}")
        for rule, rel, text in PLANTS:
            path = os.path.join(tmp, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
            found = run(["tests", "sdk/tests"], tmp)
            if not any(f": {rule}: " in x and x.startswith(rel) for x in found):
                failures.append(f"{rule} not caught in {rel}: {found}")
            elif len(found) != 1:
                failures.append(f"{rel}: wanted one finding, got {found}")
            os.remove(path)
    for failure in failures:
        print("self-test:", failure)
    if failures:
        return 1
    print(f"sanitizerenv self-test: a clean tree and {len(PLANTS)} planted findings caught")
    return 0


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    if not argv:
        print(__doc__)
        return 2
    found = run(argv)
    for x in found:
        print(x)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
