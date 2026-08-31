#!/usr/bin/env bash
# run-all.sh - run every tests/*.test.sh, skipping only declared-red gates.
#
# CI runs the whole suite, so a gate that is deliberately red - an accepted
# baseline, or one whose other half lives in another repo - would fail the job
# forever. The wrong fix is to make such a test pass: that is a false green, and
# the gate ledger exists precisely to prevent those. So the runner skips it, out
# loud, and the ledger stays the honest record of what is red.
#
# WHICH REDS ARE EXCUSED IS NOT DECIDED HERE. That rule has exactly one
# implementation - fm_gates_classify in bin/fm-gates-lib.sh - and this runner is
# one of its two callers (bin/fm-verify.sh is the other). The rule's prose lives
# in gates/accepted-red.md. Restating it here would make this the second copy,
# which is how the verifier and the runner came to disagree in the first place.
# What IS this runner's own decision is the policy below: what to do with the
# classifier's answer, which is to skip that gate's test and say so out loud.
#
# NO SKIP IS SILENT. Each one prints a line naming the gate, the test, and the
# reason, and the summary reports the counts. A reader of the CI log can always
# see exactly what did not run and why.
#
# FAIL CLOSED. If the ledger is missing, unparseable, or unreadable, nothing is
# skipped at all and the runner says so. The safe direction is running a test
# that might fail, never silently not running one.
#
# Usage: tests/run-all.sh                 (from anywhere; resolves its own root)
#        FM_SUITE_ROOT=<dir> tests/run-all.sh    (test seam: run a fixture tree)
# Exit 0 only if every test that ran passed.
set -u

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_SUITE_ROOT:-$(cd "$SUITE_DIR/.." && pwd)}"
LEDGER="$ROOT/gates/ledger.json"
ACCEPTED="$ROOT/gates/accepted-red.md"

# GitHub Actions renders ::notice:: and ::warning:: in the run summary; outside
# CI they are just prefixed lines, which is why each also prints plainly.
annotate() {
  [ -n "${GITHUB_ACTIONS:-}" ] && printf '::%s::%s\n' "$1" "$2"
  return 0
}

# --- resolve which test files may be skipped ----------------------------------
#
# Delegates classification to bin/fm-gates-lib.sh and keeps only the policy:
# a test is skippable when the classifier says the gate's red is acceptable AND
# the gate is actually red today AND it names a test file. Emits
# "<test-path>\t<gate-id>\t<reason>", or one of the sentinels handled below.
#
# The library is loaded from THIS runner's repo (via SUITE_DIR), never from
# $ROOT: FM_SUITE_ROOT points at a fixture tree that has no bin/ of its own, and
# a fixture that could supply its own classifier could authorise its own skips.
# shellcheck source=bin/fm-gates-lib.sh
. "$SUITE_DIR/../bin/fm-gates-lib.sh"

skippable() {
  local raw
  raw=$(fm_gates_classify "$ROOT")
  case "$(printf '%s\n' "$raw" | head -1)" in
    # No gates dir and no ledger are the same fact to this runner: there is
    # nothing to read, so nothing may be skipped.
    NOGATES|NOLEDGER) echo NOLEDGER; return 0 ;;
    NOACCEPTED)       echo NOACCEPTED; return 0 ;;
    BADLEDGER)        echo BADLEDGER; return 0 ;;
  esac
  printf '%s\n' "$raw" | tail -n +2 | awk -F'\t' '
    $1 == "ok" && $3 == "red" && $4 != "" { print $4 "\t" $2 "\t" $5 }'
}

SKIP_RAW="$(skippable)"

case "$SKIP_RAW" in
  NOLEDGER)
    annotate warning "no gates/ledger.json - running every test, skipping none"
    echo "WARN: no gates/ledger.json at $LEDGER - nothing will be skipped."
    SKIP_RAW="" ;;
  NOACCEPTED)
    annotate warning "no gates/accepted-red.md - running every test, skipping none"
    echo "WARN: no gates/accepted-red.md at $ACCEPTED - nothing will be skipped."
    SKIP_RAW="" ;;
  BADLEDGER)
    annotate warning "gates/ledger.json unreadable - running every test, skipping none"
    echo "WARN: could not read $LEDGER - nothing will be skipped."
    SKIP_RAW="" ;;
esac

# --- run ---------------------------------------------------------------------

# A test claiming a prerequisite skip must print this. Inferring a skip from the
# exit code alone let a syntax error pass for one.
PREREQ_MARKER="PREREQUISITE MISSING:"

ran=0; skipped=0; failed=0
FAILED_LIST=""

for test_script in "$ROOT"/tests/*.test.sh; do
  [ -e "$test_script" ] || continue
  name="$(basename "$test_script")"

  match="$(printf '%s\n' "$SKIP_RAW" | awk -F'\t' -v n="$name" '
    $1 != "" { split($1, p, "/"); if (p[length(p)] == n) { print $2 "\t" $3; exit } }')"

  if [ -n "$match" ]; then
    gate="${match%%$'\t'*}"
    reason="${match#*$'\t'}"
    skipped=$((skipped + 1))
    # Clipped so one entry cannot flood the log; the full reason is in the file.
    [ "${#reason}" -le 160 ] || reason="${reason:0:157}..."
    echo "SKIP $name - gate $gate is declared red in gates/accepted-red.md"
    echo "     reason: $reason"
    annotate notice "SKIP $name (gate $gate declared red)"
    continue
  fi

  # Syntax-check before executing. A test that cannot even be parsed is a hard
  # failure, never a skip, and catching it here means the exit-code handling
  # below never has to guess what an exit 2 meant.
  if ! syntax_err=$(bash -n "$test_script" 2>&1); then
    failed=$((failed + 1))
    FAILED_LIST="$FAILED_LIST $name"
    echo "FAIL $name - does not parse; this is a broken test, not a skip."
    printf '%s\n' "$syntax_err" | sed 's/^/     /'
    annotate error "$name has a syntax error"
    continue
  fi

  ran=$((ran + 1))
  out="$("$test_script" 2>&1)"; code=$?
  case "$code" in
    0)
      printf '%s\n' "$out" ;;
    2)
      # Exit 2 is this repo's convention for "a prerequisite tool is missing",
      # used by fm-loop-l2 (loop-audit) and fm-boot-m0 (ledger), neither of
      # which CI installs. Treating that as failure made those tests fail the
      # job for a reason that says nothing about the code.
      #
      # But bash ALSO exits 2 on a syntax error, so accepting a bare exit 2 as a
      # skip laundered a broken test into a green build - verified: a test whose
      # entire body was `fi` was reported "SKIP ... prerequisite missing" and the
      # suite exited 0. That is a fail-open in the one place this runner
      # promises to fail closed, and it is worse than the problem it solved: a
      # test that cannot run at all is exactly what CI exists to catch.
      #
      # A skip therefore has to be CLAIMED, not inferred. The test must say so
      # in its output with the marker below; anything else exiting 2 is a
      # failure. The syntax pre-check above catches the broken-test case even
      # when the marker is somehow present.
      if printf '%s' "$out" | grep -q "$PREREQ_MARKER"; then
        ran=$((ran - 1))
        skipped=$((skipped + 1))
        echo "SKIP $name - prerequisite missing (declared)"
        printf '%s\n' "$out" | sed 's/^/     /'
        annotate notice "SKIP $name (prerequisite missing)"
      else
        failed=$((failed + 1))
        FAILED_LIST="$FAILED_LIST $name"
        echo "FAIL $name - exited 2 without declaring a missing prerequisite."
        echo "     An exit 2 is only a skip when the test prints '$PREREQ_MARKER'."
        echo "     A bash SYNTAX ERROR also exits 2, and must never be a skip."
        printf '%s\n' "$out" | sed 's/^/     /'
        annotate error "$name exited 2 without a prerequisite marker"
      fi ;;
    *)
      failed=$((failed + 1))
      FAILED_LIST="$FAILED_LIST $name"
      printf '%s\n' "$out"
      annotate error "$name failed" ;;
  esac
done

echo
echo "suite: $ran ran, $skipped skipped, $failed failed"
if [ "$failed" -ne 0 ]; then
  echo "failing:$FAILED_LIST" >&2
  exit 1
fi
exit 0
