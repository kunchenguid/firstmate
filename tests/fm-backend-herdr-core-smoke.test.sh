#!/usr/bin/env bash
# tests/fm-backend-herdr-core-smoke.test.sh - real-hc smoke for the herdr-core
# session-provider adapter (bin/backends/herdr-core.sh), the gated counterpart
# of the fake-CLI suite in tests/fm-backend-herdr-core.test.sh. Provisioned by
# bin/fm-herdr-core-lab.sh, which pins an fm-hclab- core session to a scratch
# socket and refuses the user's own sessions; cleanup goes through
# tests/herdr-core-test-safety.sh so an unsafe target fails the run instead of
# tearing anything down. Skips when no hc binary is installed (optional-binary
# gate, same posture as fm-backend-tern-smoke.test.sh); to pin a specific
# binary run `FM_HC_BIN=/path/to/hc bash tests/fm-backend-herdr-core-smoke.test.sh`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HC_BIN=${FM_HC_BIN:-}
if [ -z "$HC_BIN" ] && [ -x "$HOME/.local/bin/hc" ]; then
  HC_BIN=$HOME/.local/bin/hc
fi
if [ -z "$HC_BIN" ] && command -v hc >/dev/null 2>&1; then
  HC_BIN=$(command -v hc)
fi
if [ -z "$HC_BIN" ] || [ ! -x "$HC_BIN" ]; then
  echo "skip: no hc binary found (set FM_HC_BIN or install via bin/fm-install-herdr-core.sh)"
  exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr-core adapter)"; exit 0; }

# shellcheck source=tests/herdr-core-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-core-test-safety.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-core-smoke)

# Provision an isolated lab session. `name` mints an fm-hclab- name; the
# helper refuses the default/real core state and records a fleet tripwire.
HC_TEST_SES=$("$ROOT/bin/fm-herdr-core-lab.sh" name smoke)
"$ROOT/bin/fm-herdr-core-lab.sh" provision "$HC_TEST_SES" 2>"$TMP_ROOT/lab-provision.log" || {
  echo "skip: herdr-core lab could not provision $(tail -3 "$TMP_ROOT/lab-provision.log" 2>/dev/null)"
  exit 0
}
K=$("$ROOT/bin/fm-herdr-core-lab.sh" socket "$HC_TEST_SES")
[ -n "$HC_TEST_SES" ] && [ -n "$K" ] || { echo "skip: herdr-core lab provisioned without a session/socket"; exit 0; }
HC_TEST_SOCK=$K

# shellcheck disable=SC2329 # invoked indirectly through the EXIT trap below.
cleanup_lab() {
  hc_test_safe_teardown "$ROOT" "$HC_TEST_SES" || {
    echo "FAIL: lab teardown guard refused session '$HC_TEST_SES' - leaving it for inspection" >&2
    return
  }
}
trap cleanup_lab EXIT

hc_test_refuse_if_unsafe "$HC_TEST_SES" || {
  echo "skip: provisioned session '$HC_TEST_SES' does not satisfy the lab safety contract"
  exit 0
}

run_adapter() {  # <snippet>: run a bash snippet against the adapter pinned to the lab session
  env -i PATH="$PATH" HOME="$HOME" \
    FM_HC_BIN="$HC_BIN" FM_HC_SESSION="$HC_TEST_SES" FM_HC_SOCKET="$HC_TEST_SOCK" \
    FM_STATE_OVERRIDE="$TMP_ROOT/state" FM_HOME="$TMP_ROOT/home" \
    bash -c ". \"$ROOT/bin/backends/herdr-core.sh\"; $1"
}

fail_count=0
check() {  # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 (want $2, got $3)" >&2
    fail_count=$((fail_count + 1))
  fi
}

check "provisioned session carries the fm-hclab- prefix" 0 "$(
  case $HC_TEST_SES in fm-hclab-*) echo 0 ;; *) echo 1 ;; esac
)"

out=$(run_adapter 'fm_backend_herdr_core_container_ensure')
check "container_ensure echoes the lab session" "$HC_TEST_SES" "$out"

addr=$(run_adapter "fm_backend_herdr_core_create_task fm-smokelab1 $TMP_ROOT") || addr=
case "$addr" in t[0-9]*) echo "PASS: create_task returned terminal address $addr" ;; *)
  echo "FAIL: create_task returned '$addr'" >&2; fail_count=$((fail_count+1)); addr= ;;
esac

if [ -n "$addr" ]; then
  T=$HC_TEST_SES:$addr
  if run_adapter "fm_backend_herdr_core_target_ready $T fm-smokelab1"; then
    echo "PASS: target_ready on the created terminal"
  else
    echo "FAIL: target_ready on the created terminal" >&2
    fail_count=$((fail_count+1))
  fi

  if run_adapter "fm_backend_herdr_core_send_literal $T 'echo smoke_a_b:c' fm-smokelab1" \
    && run_adapter "fm_backend_herdr_core_send_key $T Enter fm-smokelab1"; then
    echo "PASS: pending literal + Enter"
  else
    echo "FAIL: pending literal + Enter" >&2
    fail_count=$((fail_count+1))
  fi
  sleep 0.5
  cap=$(run_adapter "fm_backend_herdr_core_capture $T 20 fm-smokelab1")
  case "$cap" in *smoke_a_b:c*) echo "PASS: capture shows the literal text with shifted punctuation" ;; *)
    echo "FAIL: capture missed the literal text: $cap" >&2; fail_count=$((fail_count+1)) ;;
  esac

  out=$(run_adapter 'fm_backend_herdr_core_list_live')
  case "$out" in *"$T"*"fm-smokelab1"*) echo "PASS: list_live reports $T fm-smokelab1" ;; *)
    echo "FAIL: list_live reported '$out'" >&2; fail_count=$((fail_count+1)) ;;
  esac

  st=$(run_adapter "fm_backend_herdr_core_agent_state $T")
  case "$st" in alive|dead|unknown|unreadable) echo "PASS: agent_state vocabulary: $st" ;; *)
    echo "FAIL: agent_state returned '$st'" >&2; fail_count=$((fail_count+1)) ;;
  esac

  out=$(run_adapter "fm_backend_herdr_core_kill $T")
  check "kill on a live terminal" 0 "$?"
  out=$(run_adapter "fm_backend_herdr_core_kill $T" 2>/dev/null)
  check "kill on the removed terminal" 0 "$?"
fi

if [ "$fail_count" -eq 0 ]; then
  echo "herdr-core smoke: all checks passed (session $HC_TEST_SES)"
else
  echo "herdr-core smoke: $fail_count check(s) failed" >&2
fi
exit "$fail_count"
