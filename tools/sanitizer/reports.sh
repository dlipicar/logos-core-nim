#!/usr/bin/env bash
# [DECISIONS G442] Sanitizer reports from a suite and from every process it starts.
#
# A child's report reaches only its own stderr and exit status, which hosted suites do not read
# (a Module Host's end is `host-terminated` whatever its status). So a sanitizer check sends
# every report to a file of its own and fails on any:
#
#   reports.sh run --suite NAME --dir DIR -- COMMAND...
#     Empties DIR (a path with a `sanitizer-reports` component), writes the marker file in it,
#     appends `log_path=DIR/report:log_exe_name=1` to ASAN_OPTIONS, LSAN_OPTIONS, MSAN_OPTIONS,
#     TSAN_OPTIONS and UBSAN_OPTIONS (and `external_symbolizer_path` to MSAN_OPTIONS when
#     llvm-symbolizer is on PATH: a host's environment has no PATH), runs COMMAND, then `check`
#     with its status. Exits non-zero if the check fails, whatever COMMAND's status was.
#   reports.sh check --suite NAME --dir DIR [--status N]
#     The first line names every cause of a failure: the suite failed (N is not 0), reports were
#     found, the marker is gone (DIR was removed: on Linux each instrumented process re-creates
#     it, on macOS reports into a missing directory are dropped), or a canary is missing. Then
#     each distinct `SUMMARY:` line with its count, then one file in full for each, up to 10
#     (64 KiB each). Every file but the marker counts, an empty one included.
#   reports.sh self-test
#     The cases above over made-up directories and stub suites, without a sanitizer.
#
# DIR, and for the self-test TMPDIR, must not be on a FAT or exFAT volume: macOS writes a `._name`
# AppleDouble file beside each file there, and each counts as a report. That fails closed, never
# passing over one. On the Mac, give the self-test a TMPDIR on APFS; a suite's DIR is under the
# checkout's build/.
#
# Canaries: the suites in CANARY_SUITES each have a case whose child writes one stack trace with
# `__sanitizer_print_stack_trace()` and that moves the child's file into DIR/canary/ once the
# child is reaped (tests/support/sanitizerenv.nim). A sanitizer check of such a suite needs at
# least one file there, each nothing but the frames of one trace; a canary that never ran fails.

set -u

CANARY_SUITES="test_hosted test_module_host test_logosd"
MARKER="lcn-sanitizer-reports.marker"
VARIABLES="ASAN_OPTIONS LSAN_OPTIONS MSAN_OPTIONS TSAN_OPTIONS UBSAN_OPTIONS"
MAX_FULL=10
MAX_BYTES=65536

say() { printf '%s\n' "$*" >&2; }

usage() {
  say "usage: reports.sh run --suite NAME --dir DIR -- COMMAND... | check --suite NAME --dir DIR [--status N] | self-test"
  exit 2
}

# True when the file is nothing but the frames of one stack trace: lines `#0`, `#1`, ... in
# order, blank lines aside.
one_trace() {
  awk '
    /^[ \t]*$/ { next }
    {
      if (match($0, /^[ \t]*#[0-9]+[ \t]/) == 0) { bad = 1; exit }
      s = $0; sub(/^[ \t]*#/, "", s); sub(/[ \t].*$/, "", s)
      if (s + 0 != n) { bad = 1; exit }
      n++
    }
    END { exit (bad || n == 0) ? 1 : 0 }
  ' "$1"
}

is_canary_suite() {
  case " $CANARY_SUITES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# The summary a report is grouped by: its first `SUMMARY:` line.
summary_of() {
  if [ ! -s "$1" ]; then
    printf '(an empty file)\n'
    return
  fi
  local line
  line=$(grep -m 1 -E '^[[:space:]]*SUMMARY:' "$1" | sed -E 's/^[[:space:]]+//' | cut -c 1-300)
  if [ -n "$line" ]; then
    printf '%s\n' "$line"
  else
    printf '(no SUMMARY line) %s\n' "$(grep -m 1 -v -E '^[[:space:]]*$' "$1" | cut -c 1-200)"
  fi
}

check() {
  local suite="" dir="" status=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --suite) suite=$2; shift 2 ;;
      --dir) dir=$2; shift 2 ;;
      --status) status=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$suite" ] && [ -n "$dir" ] || usage
  local IFS=$'\n' # file names, one per line
  local causes="" reports="" canaries=0 bad_canaries=""
  [ "$status" = 0 ] || causes="${causes:+$causes; }the suite failed (exit $status)"
  if [ ! -f "$dir/$MARKER" ]; then
    causes="${causes:+$causes; }the marker is gone (the report directory was removed; reports may be lost)"
  fi
  if [ -d "$dir" ]; then
    reports=$(find "$dir" -type f ! -path "$dir/$MARKER" ! -path "$dir/canary/*" | LC_ALL=C sort)
    if [ -d "$dir/canary" ]; then
      local f
      for f in $(find "$dir/canary" -type f | LC_ALL=C sort); do
        if one_trace "$f"; then
          canaries=$((canaries + 1))
        else
          bad_canaries=$(printf '%s\n%s' "$bad_canaries" "$f")
        fi
      done
    fi
  fi
  # A canary file that is more than one trace is a report.
  local f
  for f in $bad_canaries; do
    reports=$(printf '%s\n%s\n' "$reports" "$f" | grep -v '^$' | LC_ALL=C sort)
  done
  local count=0
  [ -n "$reports" ] && count=$(printf '%s\n' "$reports" | wc -l | tr -d ' ')
  local distinct=0 table=""
  if [ "$count" -gt 0 ]; then
    table=$(for f in $reports; do summary_of "$f"; done | LC_ALL=C sort | uniq -c | LC_ALL=C sort -k1,1nr -k2)
    distinct=$(printf '%s\n' "$table" | wc -l | tr -d ' ')
    causes="${causes:+$causes; }reports found ($count file(s), $distinct distinct)"
  fi
  if is_canary_suite "$suite" && [ "$canaries" -eq 0 ]; then
    causes="${causes:+$causes; }no canary (the suite's canary case did not run or did not move its file)"
  fi
  if [ -z "$causes" ]; then
    if [ "$canaries" -gt 0 ]; then
      say "sanitizer check ($suite): passed: no reports, $canaries canary file(s)"
    else
      say "sanitizer check ($suite): passed: no reports"
    fi
    return 0
  fi
  say "sanitizer check ($suite): FAILED: $causes"
  if [ "$count" -gt 0 ]; then
    say "Distinct reports, by count:"
    printf '%s\n' "$table" | sed 's/^/  /' >&2
    local shown=0 line want
    while IFS= read -r line; do
      want=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*[0-9]+ //')
      if [ "$shown" -ge "$MAX_FULL" ]; then
        say "($((distinct - shown)) more distinct report(s) not printed in full)"
        break
      fi
      for f in $reports; do
        if [ "$(summary_of "$f")" = "$want" ]; then
          local size
          size=$(wc -c < "$f" | tr -d ' ')
          say "==== $(basename "$f") ($size bytes): $want"
          if [ "$size" -gt "$MAX_BYTES" ]; then
            head -c "$MAX_BYTES" "$f" >&2
            say ""
            say "(cut at $MAX_BYTES of $size bytes)"
          else
            cat "$f" >&2
          fi
          break
        fi
      done
      shown=$((shown + 1))
    done <<EOF
$table
EOF
  fi
  return 1
}

run() {
  local suite="" dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --suite) suite=$2; shift 2 ;;
      --dir) dir=$2; shift 2 ;;
      --) shift; break ;;
      *) usage ;;
    esac
  done
  [ -n "$suite" ] && [ -n "$dir" ] && [ $# -gt 0 ] || usage
  case "/$dir/" in
    */sanitizer-reports/*) ;;
    *) say "reports.sh: refusing to empty $dir: no sanitizer-reports component"; exit 2 ;;
  esac
  rm -rf "$dir"
  mkdir -p "$dir" || exit 2
  dir=$(cd "$dir" && pwd -P) || exit 2
  printf 'G442: this directory receives every sanitizer report of %s\n' "$suite" > "$dir/$MARKER"
  local v value symbolizer
  symbolizer=$(command -v llvm-symbolizer 2> /dev/null || true)
  for v in $VARIABLES; do
    value=$(printenv "$v" || true)
    value="${value:+$value:}log_path=$dir/report:log_exe_name=1"
    if [ "$v" = MSAN_OPTIONS ] && [ -n "$symbolizer" ]; then
      value="$value:external_symbolizer_path=$symbolizer"
    fi
    export "$v=$value"
  done
  local status=0
  "$@" || status=$?
  if check --suite "$suite" --dir "$dir" --status "$status"; then
    return 0
  fi
  [ "$status" -ne 0 ] && return "$status"
  return 1
}

# Self-test ----------------------------------------------------------------------------------

self_test() {
  local self="$0" t fails=0
  t=$(mktemp -d "${TMPDIR:-/tmp}/sanitizer-reports-test.XXXXXX") || exit 2
  local out="$t/out"

  expect() { # name, expected status (0 or 1+), first-line pattern, then the command
    local name=$1 want=$2 pattern=$3
    shift 3
    "$@" > /dev/null 2> "$out"
    local got=$?
    local first
    first=$(head -n 1 "$out")
    if { [ "$want" = 0 ] && [ "$got" -ne 0 ]; } || { [ "$want" != 0 ] && [ "$got" -eq 0 ]; }; then
      say "FAIL $name: exit $got, wanted $want; first line: $first"
      fails=$((fails + 1))
    elif ! printf '%s\n' "$first" | grep -q -E -- "$pattern"; then
      say "FAIL $name: first line: $first; wanted /$pattern/"
      fails=$((fails + 1))
    else
      say "ok   $name"
    fi
  }
  printed() { # name, pattern: the last command's output holds it
    if grep -q -E -- "$2" "$out"; then
      say "ok   $1"
    else
      say "FAIL $1: no /$2/ in:"
      sed 's/^/       /' "$out" >&2
      fails=$((fails + 1))
    fi
  }
  fresh() { # a report directory with its marker
    rm -rf "$t/sanitizer-reports"
    mkdir -p "$t/sanitizer-reports"
    printf 'marker\n' > "$t/sanitizer-reports/$MARKER"
  }
  local d="$t/sanitizer-reports"
  local trace='    #0 0x1 in __sanitizer_print_stack_trace
    #1 0x2 in probe_impl::sanitizerTrace
    #2 0x3 in main

'

  # `check` over made-up directories.
  fresh
  expect "empty directory passes" 0 "passed: no reports" bash "$self" check --suite test_x --dir "$d"
  fresh
  printf 'WARNING: ThreadSanitizer: data race\n    #0 f\nSUMMARY: ThreadSanitizer: data race a.nim:1 in f\n' > "$d/report.h.11"
  expect "one report fails" 1 "FAILED: reports found \(1 file\(s\), 1 distinct\)" bash "$self" check --suite test_x --dir "$d"
  printed "the report is printed" "^==== report.h.11 .*SUMMARY: ThreadSanitizer: data race a.nim:1 in f"
  printed "its text follows" "^WARNING: ThreadSanitizer: data race"
  fresh
  : > "$d/report.h.12"
  expect "an empty file fails" 1 "reports found \(1 file" bash "$self" check --suite test_x --dir "$d"
  printed "an empty file is named so" "\(an empty file\)"
  fresh
  printf 'no summary here\n' > "$d/stray"
  expect "a file without SUMMARY fails" 1 "reports found" bash "$self" check --suite test_x --dir "$d"
  printed "its first line stands in" "\(no SUMMARY line\) no summary here"
  fresh
  rm "$d/$MARKER"
  expect "no marker fails" 1 "FAILED: the marker is gone" bash "$self" check --suite test_x --dir "$d"
  rm -rf "$d"
  expect "no directory fails" 1 "FAILED: the marker is gone" bash "$self" check --suite test_x --dir "$d"
  fresh
  expect "a suite that failed fails" 1 "FAILED: the suite failed \(exit 3\)$" bash "$self" check --suite test_x --dir "$d" --status 3
  fresh
  : > "$d/report.h.13"
  rm "$d/$MARKER"
  expect "every cause on the first line" 1 "the suite failed \(exit 1\); the marker is gone .*; reports found \(1 file" \
    bash "$self" check --suite test_x --dir "$d" --status 1

  # Distinct reports, the cap and the cut.
  fresh
  local i
  for i in 1 2 3; do
    printf 'x\nSUMMARY: ThreadSanitizer: data race same.nim:1\n' > "$d/report.h.2$i"
  done
  for i in $(seq 1 12); do
    printf 'y\nSUMMARY: AddressSanitizer: other-%02d\n' "$i" > "$d/report.h.3$i"
  done
  expect "15 files, 13 distinct" 1 "reports found \(15 file\(s\), 13 distinct\)" bash "$self" check --suite test_x --dir "$d"
  printed "each distinct SUMMARY line with its count" "^  +3 SUMMARY: ThreadSanitizer: data race same.nim:1"
  printed "past ten, the rest are named only" "\(3 more distinct report\(s\) not printed in full\)"
  if [ "$(grep -c '^==== ' "$out")" -eq "$MAX_FULL" ]; then say "ok   ten printed in full"; else
    say "FAIL ten printed in full: $(grep -c '^==== ' "$out")"; fails=$((fails + 1)); fi
  fresh
  { printf 'SUMMARY: AddressSanitizer: big\n'; head -c 70000 /dev/zero | tr '\0' 'z'; } > "$d/report.h.41"
  expect "a big report fails" 1 "reports found" bash "$self" check --suite test_x --dir "$d"
  printed "and is cut" "\(cut at $MAX_BYTES of [0-9]+ bytes\)"

  # Canaries.
  fresh
  expect "a canary suite without its canary fails" 1 "FAILED: no canary" bash "$self" check --suite test_hosted --dir "$d"
  mkdir -p "$d/canary"
  printf '%s' "$trace" > "$d/canary/report.h.51"
  expect "with one canary file it passes" 0 "passed: no reports, 1 canary file" bash "$self" check --suite test_hosted --dir "$d"
  printf '%s%s' "$trace" "$trace" > "$d/canary/report.h.52"
  expect "a canary file of two traces is a report" 1 "reports found \(1 file" bash "$self" check --suite test_hosted --dir "$d"
  rm "$d/canary/report.h.52"
  printf '%sSUMMARY: AddressSanitizer: heap-use-after-free\n' "$trace" > "$d/canary/report.h.53"
  expect "a canary file with a report in it is a report" 1 "reports found" bash "$self" check --suite test_hosted --dir "$d"
  printed "and is printed" "heap-use-after-free"
  rm "$d/canary/report.h.53"
  printf '    #1 0x2 in f\n' > "$d/canary/report.h.54"
  expect "frames not from #0 are not one trace" 1 "reports found" bash "$self" check --suite test_module_host --dir "$d"

  # `run` with stub suites in place of the suite.
  local stub="$t/stub.sh"
  # Run as a suite's binary is, through its own first line: the bash running this, since a Nix
  # build's sandbox has no /usr/bin/env.
  printf '#!%s\n' "$BASH" > "$stub"
  cat >> "$stub" << 'STUB'
# A stand-in suite: $1 is what it does.
path=${TSAN_OPTIONS##*log_path=}
path=${path%%:*}
case "$1" in
  pass) exit 0 ;;
  fail) exit 3 ;;
  report) printf 'SUMMARY: ThreadSanitizer: data race stub\n' > "$path.stub.$$"; exit 0 ;;
  report-fail) printf 'SUMMARY: ThreadSanitizer: data race stub\n' > "$path.stub.$$"; exit 66 ;;
  unmark) rm -f "$(dirname "$path")/lcn-sanitizer-reports.marker"; exit 0 ;;
  env)
    for v in ASAN_OPTIONS LSAN_OPTIONS MSAN_OPTIONS TSAN_OPTIONS UBSAN_OPTIONS; do
      printf '%s=%s\n' "$v" "$(printenv "$v")"
    done > "$(dirname "$path")/../env.txt"
    exit 0 ;;
esac
exit 9
STUB
  chmod +x "$stub"
  expect "run: a suite that passes with no file passes" 0 "passed: no reports" \
    bash "$self" run --suite test_x --dir "$d" -- "$stub" pass
  expect "run: a suite that passes with a file fails" 1 "FAILED: reports found \(1 file" \
    bash "$self" run --suite test_x --dir "$d" -- "$stub" report
  printed "run: its report is printed before the exit" "^==== report.stub.[0-9]+ "
  expect "run: a suite that fails with no file fails" 1 "FAILED: the suite failed \(exit 3\)$" \
    bash "$self" run --suite test_x --dir "$d" -- "$stub" fail
  bash "$self" run --suite test_x --dir "$d" -- "$stub" report-fail > /dev/null 2>&1
  if [ $? -eq 66 ]; then say "ok   run: the suite's own status when both fail"; else
    say "FAIL run: the suite's own status when both fail"; fails=$((fails + 1)); fi
  expect "run: the marker gone fails" 1 "FAILED: the marker is gone" \
    bash "$self" run --suite test_x --dir "$d" -- "$stub" unmark
  printf 'old\n' > "$d/report.old.1"
  expect "run: starts from an empty directory" 0 "passed" bash "$self" run --suite test_x --dir "$d" -- "$stub" pass
  expect "run: refuses a directory without sanitizer-reports" 2 "refusing to empty" \
    bash "$self" run --suite test_x --dir "$t/other" -- "$stub" pass
  mkdir -p "$t/bin"
  printf '#!/bin/sh\nexit 0\n' > "$t/bin/llvm-symbolizer"
  chmod +x "$t/bin/llvm-symbolizer"
  PATH="$t/bin:$PATH" TSAN_OPTIONS="halt_on_error=1" bash "$self" run --suite test_x --dir "$d" -- "$stub" env 2> /dev/null
  local abs
  abs=$(cd "$d" && pwd -P)
  local v ok=1
  for v in ASAN_OPTIONS LSAN_OPTIONS MSAN_OPTIONS TSAN_OPTIONS UBSAN_OPTIONS; do
    grep -q -F "$v=" "$t/env.txt" && grep "^$v=" "$t/env.txt" | grep -q -F "log_path=$abs/report:log_exe_name=1" || ok=0
  done
  grep -q -F "TSAN_OPTIONS=halt_on_error=1:log_path=" "$t/env.txt" || ok=0
  grep "^MSAN_OPTIONS=" "$t/env.txt" | grep -q -F "external_symbolizer_path=$t/bin/llvm-symbolizer" || ok=0
  grep "^ASAN_OPTIONS=" "$t/env.txt" | grep -q -F "external_symbolizer_path" && ok=0
  if [ "$ok" = 1 ]; then say "ok   run: all five set, appended, absolute; the symbolizer in MSAN_OPTIONS only"; else
    say "FAIL run: the variables:"; sed 's/^/       /' "$t/env.txt" >&2; fails=$((fails + 1)); fi

  rm -rf "$t"
  if [ "$fails" -gt 0 ]; then
    say "reports.sh self-test: $fails failure(s)"
    return 1
  fi
  say "reports.sh self-test: all passed"
}

case "${1:-}" in
  run) shift; run "$@" ;;
  check) shift; check "$@" ;;
  self-test) self_test ;;
  *) usage ;;
esac
