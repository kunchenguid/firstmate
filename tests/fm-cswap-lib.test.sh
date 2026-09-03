#!/usr/bin/env bash
# Behavior tests for bin/fm-cswap-lib.sh's dispatch-time cswap account
# selection: the busy-worker guard, the no-op-on-already-active guard, post-
# switch verification, evidence recording, and the fail-open-on-absent-tool
# path. Hermetic - a fake `cswap` stub on PATH stands in for the real CLI; no
# real account is ever touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-cswap-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cswap-lib)

# fm_fake_cswap <fakebin> <active-marker> <switch-log>: a stub that serves
# `list --json` / `status --json` from a two-account fixture (5x-account 1 at
# risk, 20x-account 2 safe - the same shape as the captain's scenario) whose
# CURRENT active number lives in <active-marker>, and logs every `switch`
# invocation to <switch-log>. FAKE_CSWAP_BLOCK_SWITCH=1 makes `switch`
# report success without actually moving the active marker, simulating a
# switch that did not take effect (verification must then read verified=false).
fm_fake_cswap() {
  local fakebin=$1 marker=$2 log=$3
  cat > "$fakebin/cswap" <<SH
#!/usr/bin/env bash
set -eu
MARKER='$marker'
LOG='$log'
active=\$(cat "\$MARKER")
accounts_json() {
  cat <<JSON
[
  {"number":1,"email":"5x@example.com","disabled":false,"usageStatus":"ok","usageAgeSeconds":30,
   "usage":{"fiveHour":{"pct":10,"resetsAt":"2035-01-01T04:00:00Z"},
            "sevenDay":{"pct":36,"resetsAt":"2035-01-05T20:00:00Z","expectedPct":30.95,"aheadOfPace":false,
                        "projectedExhaustionAt":"2035-01-04T19:00:00Z","willLastToReset":false}}},
  {"number":2,"email":"20x@example.com","disabled":false,"usageStatus":"ok","usageAgeSeconds":30,
   "usage":{"fiveHour":{"pct":5,"resetsAt":"2035-01-01T04:00:00Z"},
            "sevenDay":{"pct":6,"resetsAt":"2035-01-05T04:00:00Z","expectedPct":40.4,"aheadOfPace":false,
                        "projectedExhaustionAt":"2035-02-14T04:00:00Z","willLastToReset":true}}}
]
JSON
}
case "\${1:-}" in
  list)
    printf '{"activeAccountNumber":%s,"accounts":' "\$active"
    accounts_json
    printf '}'
    ;;
  status)
    # FAKE_CSWAP_STATUS_FAIL=1 makes \`status\` fail with no output, simulating
    # the live active account being unconfirmable under the lock (a stale
    # decision must then fail closed, never fire the pre-lock target).
    if [ "\${FAKE_CSWAP_STATUS_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    # FAKE_CSWAP_STATUS_ACTIVE overrides the number reported by \`status\`
    # (but not \`list\`), simulating the live active account having moved out
    # from under a decision that was ranked against the \`list\` read.
    printf '{"active":{"number":%s}}' "\${FAKE_CSWAP_STATUS_ACTIVE:-\$active}"
    ;;
  switch)
    printf 'switch %s\n' "\$2" >> "\$LOG"
    if [ "\${FAKE_CSWAP_BLOCK_SWITCH:-0}" != 1 ]; then
      printf '%s' "\$2" > "\$MARKER"
    fi
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/cswap"
}

new_case() {  # <name> -> prints "<fakebin> <state> <marker> <log>"
  local d="$TMP_ROOT/$1" fakebin state marker log
  mkdir -p "$d"
  fakebin=$(fm_fakebin "$d")
  state="$d/state"
  mkdir -p "$state"
  marker="$d/active"
  printf '1' > "$marker"
  log="$d/switch.log"
  : > "$log"
  fm_fake_cswap "$fakebin" "$marker" "$log"
  printf '%s %s %s %s' "$fakebin" "$state" "$marker" "$log"
}

test_switches_and_verifies_when_target_differs() {
  local fakebin state marker log
  read -r fakebin state marker log <<< "$(new_case switch-verify)"
  PATH="$fakebin:$PATH" fm_cswap_dispatch_switch t1 "$state"
  [ "$(cat "$marker")" = 2 ] || fail "the active account should have moved to the chosen candidate (2)"
  [ "$(cat "$log")" = "switch 2" ] || fail "expected exactly one 'switch 2' call, got: $(cat "$log")"
  [ -f "$state/t1.cswap-select" ] || fail "evidence sidecar was not written"
  [ "$(jq -r .decision < "$state/t1.cswap-select")" = switch ] || fail "evidence must record decision=switch"
  [ "$(jq -r .chosen < "$state/t1.cswap-select")" = 2 ] || fail "evidence must record chosen=2"
  [ "$(jq -r .switched < "$state/t1.cswap-select")" = true ] || fail "evidence must record switched=true"
  [ "$(jq -r .verified < "$state/t1.cswap-select")" = true ] || fail "evidence must record verified=true after a confirmed switch"
  [ "$(jq -r '.candidates | length' < "$state/t1.cswap-select")" = 2 ] || fail "evidence must retain the full per-account input candidates"
  pass "a genuinely better account is switched to and the post-switch identity is verified"
}

test_switch_verification_failure_is_recorded_not_hidden() {
  local fakebin state marker log
  read -r fakebin state marker log <<< "$(new_case verify-fail)"
  FAKE_CSWAP_BLOCK_SWITCH=1 PATH="$fakebin:$PATH" fm_cswap_dispatch_switch t1 "$state"
  [ "$(cat "$marker")" = 1 ] || fail "the fake active marker should be unchanged since the switch was blocked"
  [ "$(cat "$log")" = "switch 2" ] || fail "the switch command must still have been attempted"
  [ "$(jq -r .switched < "$state/t1.cswap-select")" = true ] || fail "evidence must record that a switch was attempted"
  [ "$(jq -r .verified < "$state/t1.cswap-select")" = false ] || fail "an unconfirmed switch must never be reported as verified"
  pass "a switch that does not take effect is recorded as switched but NOT verified, never silently claimed successful"
}

test_noop_when_target_already_active() {
  local fakebin state marker log
  read -r fakebin state marker log <<< "$(new_case noop)"
  printf '2' > "$marker"
  PATH="$fakebin:$PATH" fm_cswap_dispatch_switch t1 "$state"
  [ -s "$log" ] && fail "no switch call should fire when the decision already resolves to keep-current"
  [ "$(jq -r .decision < "$state/t1.cswap-select")" = keep-current ] || fail "already-best active account must record keep-current"
  [ "$(jq -r .switched < "$state/t1.cswap-select")" = false ] || fail "keep-current must record switched=false"
  pass "no switch is attempted when the best candidate is already the active account"
}

test_skips_switch_when_active_moved_under_lock() {
  # The `list` read ranks a decision against active=1, but by the time the
  # switch lock is held the live active has moved to 3 (a concurrent spawn
  # switched). The chosen target (2) is now ranked against stale state, so
  # the switch must be skipped (fail-closed), never fired onto an obsolete
  # target.
  local fakebin state marker log
  read -r fakebin state marker log <<< "$(new_case stale-active)"
  FAKE_CSWAP_STATUS_ACTIVE=3 PATH="$fakebin:$PATH" fm_cswap_dispatch_switch t1 "$state"
  [ -s "$log" ] && fail "no switch may fire when the live active account moved under the lock, log: $(cat "$log")"
  [ "$(cat "$marker")" = 1 ] || fail "active marker must be unchanged when the switch is skipped as stale"
  [ "$(jq -r .switched < "$state/t1.cswap-select")" = false ] || fail "a stale-decision skip must record switched=false"
  [ "$(jq -r .verified < "$state/t1.cswap-select")" = false ] || fail "a skipped switch is never verified"
  case "$(jq -r .skippedReason < "$state/t1.cswap-select")" in
    *stale*|*changed*|*concurrent*) : ;;
    *) fail "skippedReason should explain the stale/concurrent-switch skip, got: $(jq -r .skippedReason < "$state/t1.cswap-select")" ;;
  esac
  pass "a decision ranked against a since-changed active account fails closed instead of executing an obsolete target"
}

test_skips_switch_when_active_cannot_be_confirmed_under_lock() {
  # `cswap status --json` fails to report the live active account while the
  # switch lock is held. The decision was ranked against the pre-lock `list`
  # read; without a fresh confirmation a concurrent switch cannot be ruled out,
  # so the switch must fail closed (keep-current) rather than fire the pre-lock
  # target - never substituting the stale list-time active as if it were still
  # the confirmed live one.
  local fakebin state marker log
  read -r fakebin state marker log <<< "$(new_case unconfirmed-active)"
  FAKE_CSWAP_STATUS_FAIL=1 PATH="$fakebin:$PATH" fm_cswap_dispatch_switch t1 "$state"
  [ -s "$log" ] && fail "no switch may fire when the live active account cannot be confirmed under the lock, log: $(cat "$log")"
  [ "$(cat "$marker")" = 1 ] || fail "active marker must be unchanged when the switch is skipped as unconfirmable"
  [ "$(jq -r .switched < "$state/t1.cswap-select")" = false ] || fail "an unconfirmable-active skip must record switched=false"
  [ "$(jq -r .verified < "$state/t1.cswap-select")" = false ] || fail "a skipped switch is never verified"
  case "$(jq -r .skippedReason < "$state/t1.cswap-select")" in
    *confirm*|*stale*) : ;;
    *) fail "skippedReason should explain the unconfirmable-active skip, got: $(jq -r .skippedReason < "$state/t1.cswap-select")" ;;
  esac
  pass "a switch whose live active account cannot be confirmed under the lock fails closed instead of firing a possibly-stale target"
}

test_skips_switch_when_another_claude_task_is_busy() {
  local fakebin state marker log
  read -r fakebin state marker log <<< "$(new_case busy-guard)"
  fm_write_meta "$state/other.meta" "window=firstmate:fm-other" "harness=claude" "endpoint_task_id=other"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" other >/dev/null
  PATH="$fakebin:$PATH" fm_cswap_dispatch_switch t1 "$state"
  [ -s "$log" ] && fail "switch must not fire while another claude-harness task is busy, log: $(cat "$log")"
  [ "$(cat "$marker")" = 1 ] || fail "active account must be unchanged while the guard is skipping the switch"
  [ "$(jq -r .switched < "$state/t1.cswap-select")" = false ] || fail "evidence must record switched=false under the busy guard"
  case "$(jq -r .skippedReason < "$state/t1.cswap-select")" in
    *busy*) : ;;
    *) fail "skippedReason should explain the busy-guard skip, got: $(jq -r .skippedReason < "$state/t1.cswap-select")" ;;
  esac
  pass "a currently-busy claude-harness task blocks the switch instead of interrupting it"
}

test_switches_when_other_claude_task_is_idle() {
  local fakebin state marker log
  read -r fakebin state marker log <<< "$(new_case idle-other)"
  fm_write_meta "$state/other.meta" "window=firstmate:fm-other" "harness=claude" "endpoint_task_id=other"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" other >/dev/null
  "$ROOT/bin/fm-busy-event.sh" apply "$state" other idle --current-gen --source fm-interrupt --event interrupt >/dev/null
  PATH="$fakebin:$PATH" fm_cswap_dispatch_switch t1 "$state"
  [ "$(cat "$log")" = "switch 2" ] || fail "an idle other claude task must not block a genuinely better switch"
  pass "an idle (not busy) other claude-harness task does not block the switch"
}

test_candidate_disabled_normalization_matches_cswap_contract() {
  # cswap's `list --json` omits `disabled` for an in-rotation account and emits
  # it as `true` only when the slot is held out of rotation
  # (claude_swap/json_output.py). fm_cswap_candidates must therefore normalize
  # an absent key to enabled (false) and a present `true` to disabled (true),
  # and must fail CLOSED on a present-but-null value (a partial/garbled read)
  # by normalizing it to disabled (true) rather than silently enabling it.
  local raw normalized
  raw='{"activeAccountNumber":1,"accounts":[
    {"number":1,"email":"enabled@example.com","usageStatus":"ok","usage":{"fiveHour":{"pct":1},"sevenDay":{"pct":1}}},
    {"number":2,"email":"held@example.com","disabled":true,"usageStatus":"ok","usage":{"fiveHour":{"pct":1},"sevenDay":{"pct":1}}},
    {"number":3,"email":"garbled@example.com","disabled":null,"usageStatus":"ok","usage":{"fiveHour":{"pct":1},"sevenDay":{"pct":1}}}
  ]}'
  normalized=$(fm_cswap_candidates "$raw") || fail "candidates must parse a real-shaped cswap payload"
  [ "$(printf '%s' "$normalized" | jq -r '.[0].disabled')" = false ] || fail "an account omitting disabled must normalize to enabled (false), got: $normalized"
  [ "$(printf '%s' "$normalized" | jq -r '.[1].disabled')" = true ] || fail "an account with disabled:true must normalize to disabled (true), got: $normalized"
  [ "$(printf '%s' "$normalized" | jq -r '.[2].disabled')" = true ] || fail "an account with a null (unconfirmed) disabled must fail closed to disabled (true), got: $normalized"
  pass "disabled normalization honors cswap's omit-when-enabled contract and fails closed on an unconfirmed value"
}

test_no_evidence_when_cswap_absent() {
  local d fakebin state
  d="$TMP_ROOT/absent"
  mkdir -p "$d"
  fakebin=$(fm_fakebin "$d")
  state="$d/state"
  mkdir -p "$state"
  # A minimal, real-cswap-free PATH: the fakebin (empty - no cswap stub here)
  # plus only the standard system directories, so a real cswap installed
  # elsewhere on this host (e.g. ~/.local/bin) cannot leak into the test.
  PATH="$fakebin:/usr/bin:/bin" fm_cswap_dispatch_switch t1 "$state" \
    || fail "dispatch must never fail even when cswap is absent"
  [ ! -e "$state/t1.cswap-select" ] || fail "no evidence should be written when cswap is not installed at all"
  pass "cswap being absent is an inert no-op: no evidence, no failure"
}

test_switches_and_verifies_when_target_differs
test_switch_verification_failure_is_recorded_not_hidden
test_noop_when_target_already_active
test_skips_switch_when_active_moved_under_lock
test_skips_switch_when_active_cannot_be_confirmed_under_lock
test_skips_switch_when_another_claude_task_is_busy
test_switches_when_other_claude_task_is_idle
test_candidate_disabled_normalization_matches_cswap_contract
test_no_evidence_when_cswap_absent

echo "all fm-cswap-lib tests passed"
