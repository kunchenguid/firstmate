#!/usr/bin/env bash
# tests/fm-backend-adapter-source.test.sh - fm_backend_source's refusal contract
# when a backend adapter file is missing or unreadable.
#
# A missing or unreadable adapter must make fm_backend_source RETURN non-zero,
# so a caller's refusal branch actually runs. Under `set -e`, bash 3.2 aborts
# the entire shell when the `.` builtin cannot open its file - the trailing
# `|| return 1` never executes - and an EXIT trap in the caller can then publish
# that abort as exit 0, reporting success for work that never happened.
# bin/fm-teardown.sh's herdr preflight is one such caller: it exited 0 in
# silence with bin/backends/herdr.sh absent, telling the caller cleanup had
# succeeded while the isolated copy, task branch, and durable records remained.
#
# THIS FILE IS DELIBERATELY DEPENDENCY-FREE. The defect only manifests on stock
# macOS bash 3.2, so the ci.yml `macos-stock-bash` job is the only lane that can
# catch it, and that job checks out shallow with a minimal PATH. Everything here
# therefore relies on nothing but the repo tree, coreutils, and bash: no git
# history (tests/fm-backend.test.sh's old-vs-new baseline needs a resolvable
# `main`), no tasks-axi, no tmux, no herdr. Keep it that way, or the lane that
# makes this coverage meaningful can no longer run it.
#
# On a modern bash this test passes with the guard REMOVED - execution simply
# continues past the failed source - so running it only on bash 5 is vacuous.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-adapter-source-tests)

# Run fm_backend_source against a fixture root under `set -e` with a
# conditional caller, which is exactly bin/fm-teardown.sh's shape. Echoes
# REFUSED when the call returned non-zero and REACHED_CALLER when the caller
# survived to its next statement; an aborted shell prints neither. The probe
# uses "$BASH" rather than a PATH-resolved `bash` so it always exercises the
# same interpreter running this suite - on the stock macOS lane, 3.2.
backend_source_refusal_probe() {  # <fixture-root> <backend>
  # shellcheck disable=SC2016 # The single-quoted body expands inside the child shell.
  "$BASH" -c '
    set -eu
    . "$1/bin/fm-backend.sh"
    if ! fm_backend_source "$2"; then printf "REFUSED\n"; fi
    printf "REACHED_CALLER\n"
  ' _ "$1" "$2" 2>/dev/null
}

# Every adapter arm shares one code shape, so every adapter is pinned here
# rather than only herdr, whose caller happened to expose the defect.
test_backend_source_missing_adapter_refuses() {
  local fixture backend out
  fixture=$TMP_ROOT/missing-adapter
  for backend in tmux herdr zellij orca cmux; do
    rm -rf "$fixture"
    mkdir -p "$fixture/bin/backends"
    cp "$ROOT/bin/fm-backend.sh" "$fixture/bin/fm-backend.sh"
    cp "$ROOT"/bin/backends/*.sh "$fixture/bin/backends/"

    rm -f "$fixture/bin/backends/$backend.sh"
    out=$(backend_source_refusal_probe "$fixture" "$backend") \
      || fail "$backend: a missing adapter aborted the caller instead of returning non-zero"
    assert_contains "$out" "REFUSED" \
      "$backend: fm_backend_source did not report failure for a missing adapter"
    assert_contains "$out" "REACHED_CALLER" \
      "$backend: a missing adapter killed the caller before its refusal branch"

    # Present but unreadable must refuse the same way rather than abort.
    : > "$fixture/bin/backends/$backend.sh"
    chmod 000 "$fixture/bin/backends/$backend.sh"
    if [ ! -r "$fixture/bin/backends/$backend.sh" ]; then
      out=$(backend_source_refusal_probe "$fixture" "$backend") \
        || fail "$backend: an unreadable adapter aborted the caller instead of returning non-zero"
      assert_contains "$out" "REFUSED" \
        "$backend: fm_backend_source did not report failure for an unreadable adapter"
      assert_contains "$out" "REACHED_CALLER" \
        "$backend: an unreadable adapter killed the caller before its refusal branch"
    fi
    chmod 644 "$fixture/bin/backends/$backend.sh"
  done
  rm -rf "$fixture"
  pass "fm_backend_source: a missing or unreadable adapter refuses without aborting the caller"
}

# The suite is only meaningful on the interpreter where a failed `.` aborts, so
# record which bash actually ran it. Not an assertion: bash 5 lanes legitimately
# run this file too, they just cannot reproduce the abort.
test_report_probe_interpreter() {
  pass "fm_backend_source refusal probe ran under ${BASH_VERSION:-unknown}"
}

test_backend_source_missing_adapter_refuses
test_report_probe_interpreter
