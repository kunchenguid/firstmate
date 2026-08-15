#!/usr/bin/env bash
# Behavioral coverage for routine completion after the verification gate.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTINE="$ROOT/bin/fm-routine-complete.sh"
TMP_ROOT=$(fm_test_tmproot fm-routine-complete)

write_crew_state_reader() {  # <directory> <state-line>
  local directory=$1 state_line=$2
  mkdir -p "$directory"
  cat > "$directory/fm-crew-state.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$state_line'
EOF
  chmod +x "$directory/fm-crew-state.sh"
  printf '%s\n' "$directory/fm-crew-state.sh"
}

test_verify_accepts_current_done_run_step_with_pr() {
  local home id reader
  home="$TMP_ROOT/verify-home"
  id=sample-routine-ship
  mkdir -p "$home/state"
  fm_write_meta "$home/state/$id.meta" \
    "kind=ship" \
    "pr=https://github.com/example/sample/pull/1"
  printf 'done: PR https://github.com/example/sample/pull/1 checks green\n' \
    > "$home/state/$id.status"
  reader=$(write_crew_state_reader "$home/fakebin" 'state: done · source: run-step · checks green')
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" FM_CREW_STATE_BIN="$reader" \
    "$ROUTINE" verify "$id" >/dev/null || fail "verify rejected an eligible routine ship task"
  pass "verify accepts a current done run-step with recorded PR metadata"
}

test_verify_rejects_stale_green_status_when_run_is_working() {
  local home id reader rc
  home="$TMP_ROOT/stale-green"
  id=sample-stale-ship
  mkdir -p "$home/state"
  fm_write_meta "$home/state/$id.meta" \
    "kind=ship" \
    "pr=https://github.com/example/sample/pull/3"
  printf 'done: PR https://github.com/example/sample/pull/3 checks green\n' \
    > "$home/state/$id.status"
  reader=$(write_crew_state_reader "$home/fakebin" 'state: working · source: run-step · fixing')
  set +e
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" FM_CREW_STATE_BIN="$reader" \
    "$ROUTINE" verify "$id" >/dev/null 2>&1
  rc=$?
  set -u
  [ "$rc" -ne 0 ] || fail "verify accepted stale green status while current run was working"
  pass "verify refuses stale green status when current run-step is working"
}

test_verify_rejects_open_status_decision() {
  local home id reader rc
  home="$TMP_ROOT/open-decision"
  id=sample-blocked-ship
  mkdir -p "$home/state"
  fm_write_meta "$home/state/$id.meta" \
    "kind=ship" \
    "pr=https://github.com/example/sample/pull/2"
  cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=api-shape]: choose response format
done: PR https://github.com/example/sample/pull/2 checks green
EOF
  reader=$(write_crew_state_reader "$home/fakebin" 'state: done · source: run-step · checks green')
  set +e
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" FM_CREW_STATE_BIN="$reader" \
    "$ROUTINE" verify "$id" >/dev/null 2>&1
  rc=$?
  set -u
  [ "$rc" -ne 0 ] || fail "verify accepted a task with an open keyed decision"
  pass "verify refuses routine completion while a keyed decision remains open"
}

test_verify_accepts_current_done_run_step_with_pr
test_verify_rejects_stale_green_status_when_run_is_working
test_verify_rejects_open_status_decision

echo "all routine completion tests passed"
