#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Deterministic coverage for final-refresh repository and endpoint custody.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HANDOFF=${FM_TEST_HANDOFF_COMMAND:-$ROOT/bin/fm-handoff.sh}
export FM_BACKEND_HERDR_TEST_LAB=firstmate-herdr-test-lab-v1
fm_test_tmproot_into TMP_ROOT fm-handoff

make_fakebin() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
state=$(cat "$FM_FAKE_ENDPOINT_STATE_FILE" 2>/dev/null || printf unknown)
process=$(cat "$FM_FAKE_PROCESS_STATE_FILE" 2>/dev/null || printf node)
case "${1:-}" in
  has-session) [ "$state" = present ] ;;
  list-windows)
    case "$state" in
      present) printf '%s\n' "fm-$FM_FAKE_TASK_ID" ;;
      absent) printf '%s\n' other-window ;;
      *) exit 1 ;;
    esac
    ;;
  display-message)
    case "${!#}" in
      '#{session_name}') printf '%s\n' firstmate ;;
      '#{window_name}') printf '%s\n' "fm-$FM_FAKE_TASK_ID" ;;
      '#{pane_current_command}') printf '%s\n' "$process" ;;
      *) printf '%s\n' unknown ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/tmux"
}

make_case() {
  local name=$1
  CASE_DIR=$TMP_ROOT/$name
  HOME_DIR=$CASE_DIR/home
  REPO_DIR=$CASE_DIR/repo
  FAKEBIN=$CASE_DIR/fakebin
  ID=handoff-$name
  ENDPOINT_STATE=$CASE_DIR/endpoint.state
  PROCESS_STATE=$CASE_DIR/process.state
  ARTIFACT=$HOME_DIR/data/$ID/handoff.md
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$ID" "$REPO_DIR"
  make_fakebin "$FAKEBIN"

  git -C "$REPO_DIR" init -q -b main
  git -C "$REPO_DIR" config user.name 'Firstmate Handoff Test'
  git -C "$REPO_DIR" config user.email 'handoff-test@example.invalid'
  printf 'base\n' > "$REPO_DIR/work.txt"
  git -C "$REPO_DIR" add work.txt
  git -C "$REPO_DIR" commit -qm base
  git -C "$REPO_DIR" update-ref refs/remotes/origin/main HEAD
  git -C "$REPO_DIR" checkout -qb "fm/$ID"
  printf 'unpublished %s\n' "$name" >> "$REPO_DIR/work.txt"
  git -C "$REPO_DIR" commit -qam "unpublished $name"
  WORK_HEAD=$(git -C "$REPO_DIR" rev-parse HEAD)
  printf 'absent\n' > "$ENDPOINT_STATE"
  printf 'zsh\n' > "$PROCESS_STATE"
  cat > "$HOME_DIR/state/$ID.meta" <<EOF
window=firstmate:fm-$ID
tmux_session_target=firstmate:fm-$ID
worktree=$REPO_DIR
project=$REPO_DIR
harness=claude
kind=ship
mode=direct-PR
yolo=off
EOF
  cat > "$ARTIFACT" <<EOF
# Handoff: $ID

## Objective

Preserve this human-written intent across every custody refresh.
EOF
}

handoff_env() {
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_FAKE_ENDPOINT_STATE_FILE="$ENDPOINT_STATE" \
  FM_FAKE_PROCESS_STATE_FILE="$PROCESS_STATE" \
  FM_FAKE_TASK_ID="$ID" \
  PATH="$FAKEBIN:$PATH" \
    "$HANDOFF" "$ID" "$ARTIFACT"
}

run_gated_handoff() {
  local output=$1 ready=$2 proceed=$3
  FM_HANDOFF_TEST_FINAL_RECHECK_READY="$ready" \
  FM_HANDOFF_TEST_FINAL_RECHECK_PROCEED="$proceed" \
    handoff_env > "$output" 2>&1 &
  GATED_PID=$!
}

assert_free_edit() {
  local file=$1 label=$2
  assert_grep 'Active mutation owner: **none**' "$file" "$label did not name the absence of an owner"
  assert_grep "\`may mutate now\`: **yes**" "$file" "$label did not grant exact-generation mutation"
  assert_grep "\`supervise only\`: **no**" "$file" "$label retained supervise-only custody"
}

assert_supervise_only() {
  local file=$1 label=$2
  assert_grep "\`may mutate now\`: **no**" "$file" "$label granted mutation custody"
  assert_grep "\`supervise only\`: **yes**" "$file" "$label did not require supervision"
}

test_no_active_owner_is_free_edit_and_idempotent() {
  local out count
  make_case no-owner
  out=$CASE_DIR/out
  handoff_env > "$out" || fail "no-owner handoff failed"
  assert_free_edit "$out" "no-owner handoff"
  assert_grep "HEAD: \`$WORK_HEAD\`" "$out" "no-owner handoff lost the exact HEAD"
  assert_grep 'Preserve this human-written intent' "$out" "no-owner refresh lost human intent"
  handoff_env > "$out" || fail "idempotent no-owner handoff rerun failed"
  count=$(grep -cF '<!-- firstmate-live-mutation-custody:start -->' "$ARTIFACT")
  [ "$count" -eq 1 ] || fail "handoff rerun duplicated the live-custody block"
  pass "handoff with no active owner grants one idempotent exact-generation takeover"
}

test_active_crewmate_owner_is_supervise_only() {
  local out
  make_case active-worker
  printf 'present\n' > "$ENDPOINT_STATE"
  printf 'claude\n' > "$PROCESS_STATE"
  out=$CASE_DIR/out
  handoff_env > "$out" || fail "active-worker handoff failed"
  assert_supervise_only "$out" "active crewmate handoff"
  assert_grep "Active mutation owner: **crewmate endpoint firstmate:fm-$ID**" "$out" \
    "active crewmate handoff did not name its endpoint owner"
  pass "active crewmate custody converts takeover to supervise-only"
}

test_unknown_process_liveness_is_supervise_only() {
  local out
  make_case unknown-liveness
  printf 'present\n' > "$ENDPOINT_STATE"
  printf 'node\n' > "$PROCESS_STATE"
  out=$CASE_DIR/out
  handoff_env > "$out" || fail "unknown-liveness handoff failed"
  assert_supervise_only "$out" "unknown-liveness handoff"
  assert_grep 'Active mutation owner: **unknown (endpoint/process liveness is unproved' "$out" \
    "unknown-liveness handoff did not name its uncertainty"
  pass "unknown endpoint process liveness never grants mutation custody"
}

test_retired_mode_is_supervise_only() {
  local out
  make_case retired-mode
  sed -i.bak 's/^mode=direct-PR$/mode=no-mistakes/' "$HOME_DIR/state/$ID.meta"
  rm -f "$HOME_DIR/state/$ID.meta.bak"
  out=$CASE_DIR/out
  handoff_env > "$out" || fail "retired-mode handoff failed"
  assert_supervise_only "$out" "retired-mode handoff"
  assert_grep 'retired no-mistakes task custody requires explicit operator recovery' "$out" \
    "retired-mode handoff did not preserve ambiguous mutation custody"
  pass "pre-upgrade review custody cannot grant a concurrent editor"
}

test_owner_termination_after_capture_refreshes_to_free_edit() {
  local out ready proceed
  make_case owner-terminates
  printf 'present\n' > "$ENDPOINT_STATE"
  printf 'claude\n' > "$PROCESS_STATE"
  out=$CASE_DIR/out
  ready=$CASE_DIR/recheck.ready
  proceed=$CASE_DIR/recheck.proceed
  run_gated_handoff "$out" "$ready" "$proceed"
  fm_test_wait_for_file "$ready" "$GATED_PID" || fail "owner-termination final-recheck gate did not open"
  printf 'absent\n' > "$ENDPOINT_STATE"
  touch "$proceed"
  wait "$GATED_PID" || fail "owner-termination handoff did not refresh"
  assert_free_edit "$out" "owner-termination refresh"
  pass "an owner that terminates after capture is refreshed before presentation"
}

test_head_change_after_capture_refreshes_exact_generation() {
  local out ready proceed new_head
  make_case head-changes
  out=$CASE_DIR/out
  ready=$CASE_DIR/recheck.ready
  proceed=$CASE_DIR/recheck.proceed
  run_gated_handoff "$out" "$ready" "$proceed"
  fm_test_wait_for_file "$ready" "$GATED_PID" || fail "head-change final-recheck gate did not open"
  printf 'later generation\n' >> "$REPO_DIR/work.txt"
  git -C "$REPO_DIR" commit -qam 'later unpublished generation'
  new_head=$(git -C "$REPO_DIR" rev-parse HEAD)
  touch "$proceed"
  wait "$GATED_PID" || fail "head-change handoff did not refresh"
  assert_free_edit "$out" "head-change refresh"
  assert_grep "HEAD: \`$new_head\`" "$out" "head-change refresh presented the stale HEAD"
  pass "a HEAD change after capture is refreshed before presentation"
}

test_verified_successor_is_not_competing_owner() {
  local out
  make_case successor
  out=$CASE_DIR/out
  printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$ROOT/tests/herdr-custody-fixture.py" > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"
  printf '%s\n' window=default:pane-custody backend=herdr herdr_session=default \
    herdr_workspace_id=ws-custody herdr_tab_id=tab-custody herdr_pane_id=pane-custody \
    >> "$HOME_DIR/state/$ID.meta"
  export FM_FAKE_ENDPOINT_FILE="$CASE_DIR/live" FM_FAKE_TMUX_LABEL_FILE="$CASE_DIR/label"
  touch "$FM_FAKE_ENDPOINT_FILE"
  printf 'fm-%s\n' "$ID" > "$FM_FAKE_TMUX_LABEL_FILE"
  handoff_env > "$out" || fail "Herdr owner capture failed"
  assert_supervise_only "$out" "unexcluded Herdr owner"
  FM_HANDOFF_SUCCESSOR_BACKEND=herdr FM_HANDOFF_SUCCESSOR_TARGET=default:pane-custody \
    handoff_env > "$out" || fail "successor refresh failed"
  assert_free_edit "$out" "verified successor"
  pass "exact Herdr successor exclusion preserves custody"
}

test_no_active_owner_is_free_edit_and_idempotent
test_active_crewmate_owner_is_supervise_only
test_unknown_process_liveness_is_supervise_only
test_retired_mode_is_supervise_only
test_owner_termination_after_capture_refreshes_to_free_edit
test_head_change_after_capture_refreshes_exact_generation
test_verified_successor_is_not_competing_owner
