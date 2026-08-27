#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Deterministic coverage for final-refresh mutation custody in task handoffs.
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
  has-session)
    [ "$state" = present ]
    ;;
  list-windows)
    case "$state" in
      present) printf '%s\n' "fm-$FM_FAKE_TASK_ID" ;;
      absent) printf '%s\n' other-window ;;
      *) printf '%s\n' 'control socket unreadable' >&2; exit 1 ;;
    esac
    ;;
  display-message)
    format=${!#}
    case "$format" in
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

  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
mode=$(cat "$FM_FAKE_NM_STATE_FILE" 2>/dev/null || printf unknown)
branch=$(cat "$FM_FAKE_BRANCH_FILE" 2>/dev/null || printf unknown)
head=$(cat "$FM_FAKE_PIPELINE_HEAD_FILE" 2>/dev/null || printf unknown)
case "${1:-}:${2:-}" in
  axi:status)
    if [ -n "${FM_FAKE_CAPTURE_GATE:-}" ]; then
      count=$(cat "$FM_FAKE_CAPTURE_GATE.count" 2>/dev/null || printf 0)
      count=$((count + 1))
      printf '%s\n' "$count" > "$FM_FAKE_CAPTURE_GATE.count"
      if [ "$count" -eq 3 ]; then
        touch "$FM_FAKE_CAPTURE_GATE.ready"
        for ((attempt=0; attempt<2000; attempt++)); do
          [ ! -e "$FM_FAKE_CAPTURE_GATE.proceed" ] || break
          sleep 0.01
        done
        [ -e "$FM_FAKE_CAPTURE_GATE.proceed" ] || exit 70
      fi
    fi
    case "$mode" in
      active)
        cat <<EOF
run:
  id: "run-live-1"
  branch: "$branch"
  status: running
  head: $head
  steps[2]{step,status,findings,duration_ms}:
    review,completed,0,1
    fix,fixing,0,0
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    fix,fixing,1s,"now",321,1
EOF
        ;;
      parked)
        cat <<EOF
run:
  id: "run-parked-1"
  branch: "$branch"
  status: awaiting_approval
  head: $head
  active_steps[0]{step,status,active_for,last_activity,agent_pid,round}:
EOF
        ;;
      terminal|stale-terminal|terminal-unavailable)
        cat <<EOF
run:
  id: "run-done-1"
  branch: "$branch"
  status: completed
  head: $head
  outcome: passed
  active_steps[0]{step,status,active_for,last_activity,agent_pid,round}:
EOF
        ;;
      none) exit 1 ;;
      *) printf 'status unavailable\n' >&2; exit 70 ;;
    esac
    ;;
  runs:--limit)
    case "$mode" in
      active) printf '  running      %s %s  2026-08-26 00:00\n' "$branch" "$head" ;;
      parked) printf '  running      %s %s  2026-08-26 00:00\n' "$branch" "$head" ;;
      stale-terminal) printf '  running      %s %s  2026-08-26 00:00\n' "$branch" "$head" ;;
      terminal) printf '  completed    %s %s  2026-08-26 00:00\n' "$branch" "$head" ;;
      none) ;;
      *) printf 'runs unavailable\n' >&2; exit 70 ;;
    esac
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
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
  NM_STATE=$CASE_DIR/nm.state
  BRANCH_FILE=$CASE_DIR/branch
  PIPELINE_HEAD=$CASE_DIR/pipeline-head
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
  printf '%s\n' "fm/$ID" > "$BRANCH_FILE"
  printf '%s\n' "$WORK_HEAD" > "$PIPELINE_HEAD"
  printf 'absent\n' > "$ENDPOINT_STATE"
  printf 'zsh\n' > "$PROCESS_STATE"
  printf 'none\n' > "$NM_STATE"
  cat > "$HOME_DIR/state/$ID.meta" <<EOF
window=firstmate:fm-$ID
tmux_session_target=firstmate:fm-$ID
worktree=$REPO_DIR
project=$REPO_DIR
harness=claude
kind=ship
mode=no-mistakes
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
  FM_FAKE_NM_STATE_FILE="$NM_STATE" \
  FM_FAKE_BRANCH_FILE="$BRANCH_FILE" \
  FM_FAKE_PIPELINE_HEAD_FILE="$PIPELINE_HEAD" \
  FM_FAKE_TASK_ID="$ID" \
  PATH="$FAKEBIN:$PATH" \
    "$HANDOFF" "$ID" "$ARTIFACT"
}

run_gated_handoff() {
  local output=$1 ready=$2 proceed=$3
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_FAKE_ENDPOINT_STATE_FILE="$ENDPOINT_STATE" \
  FM_FAKE_PROCESS_STATE_FILE="$PROCESS_STATE" \
  FM_FAKE_NM_STATE_FILE="$NM_STATE" \
  FM_FAKE_BRANCH_FILE="$BRANCH_FILE" \
  FM_FAKE_PIPELINE_HEAD_FILE="$PIPELINE_HEAD" \
  FM_FAKE_TASK_ID="$ID" \
  FM_HANDOFF_TEST_FINAL_RECHECK_READY="$ready" \
  FM_HANDOFF_TEST_FINAL_RECHECK_PROCEED="$proceed" \
  PATH="$FAKEBIN:$PATH" \
    "$HANDOFF" "$ID" "$ARTIFACT" > "$output" 2>&1 &
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
  assert_grep "$WORK_HEAD"$'\t''unpublished no-owner' "$out" "no-owner handoff lost the unpublished commit"
  assert_grep 'Preserve this human-written intent' "$out" "no-owner refresh lost human intent"

  handoff_env > "$out" || fail "idempotent no-owner handoff rerun failed"
  count=$(grep -cF '<!-- firstmate-live-mutation-custody:start -->' "$ARTIFACT")
  [ "$count" -eq 1 ] || fail "handoff rerun duplicated the live-custody block"
  assert_free_edit "$out" "rerun handoff"
  pass "handoff with no active owner grants one idempotent exact-generation takeover"
}

test_active_no_mistakes_owner_is_supervise_only() {
  local out
  make_case active-pipeline
  printf 'parked\n' > "$NM_STATE"
  out=$CASE_DIR/out
  handoff_env > "$out" || fail "parked-pipeline handoff failed"
  assert_supervise_only "$out" "parked no-mistakes handoff"
  assert_grep 'Active mutation owner: **no-mistakes run run-parked-1**' "$out" \
    "parked no-mistakes handoff did not retain pipeline custody"
  assert_grep "status=\`awaiting_approval\`, outcome=\`none\`, step=\`none\`" "$out" \
    "parked no-mistakes handoff lost its exact gate state"
  assert_grep "pipeline-head=\`$WORK_HEAD\`" "$out" "parked no-mistakes handoff lost its pipeline head"
  pass "parked no-mistakes custody converts takeover to supervise-only"
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
  assert_grep "presence=\`present\`, process=\`alive\`" "$out" "active crewmate handoff lost endpoint/process liveness"
  pass "active crewmate custody converts takeover to supervise-only"
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
  assert_grep "presence=\`absent\`, process=\`dead\`" "$out" "owner-termination refresh retained stale liveness"
  pass "an owner that terminates after capture refreshes before presentation"
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
  assert_grep "$new_head"$'\t''later unpublished generation' "$out" "head-change refresh lost the new unpublished commit"
  assert_no_grep "HEAD: \`$WORK_HEAD\`" "$out" "head-change refresh retained the old HEAD"
  pass "a HEAD change after capture is refreshed before presentation"
}

test_unknown_process_liveness_is_supervise_only() {
  local out pipeline_out
  make_case unknown-liveness
  printf 'present\n' > "$ENDPOINT_STATE"
  printf 'node\n' > "$PROCESS_STATE"
  out=$CASE_DIR/out
  handoff_env > "$out" || fail "unknown-liveness handoff failed"
  assert_supervise_only "$out" "unknown-liveness handoff"
  assert_grep 'Active mutation owner: **unknown (endpoint/process liveness is unproved' "$out" \
    "unknown-liveness handoff did not name its uncertainty"
  assert_grep "presence=\`present\`, process=\`unknown\`" "$out" "unknown-liveness handoff hid its evidence"

  printf 'absent\n' > "$ENDPOINT_STATE"
  printf 'unknown\n' > "$NM_STATE"
  pipeline_out=$CASE_DIR/pipeline-out
  handoff_env > "$pipeline_out" || fail "unknown-pipeline handoff failed"
  assert_supervise_only "$pipeline_out" "unknown-pipeline handoff"
  assert_grep 'Active mutation owner: **unknown (no-mistakes run or step liveness is unreadable)' "$pipeline_out" \
    "unknown-pipeline handoff did not name its uncertainty"
  pass "missing or unknown worker and pipeline liveness never grants free mutation custody"
}

test_final_recheck_catches_pipeline_activation() {
  local out ready proceed
  make_case pipeline-activates
  out=$CASE_DIR/out
  ready=$CASE_DIR/recheck.ready
  proceed=$CASE_DIR/recheck.proceed
  run_gated_handoff "$out" "$ready" "$proceed"
  fm_test_wait_for_file "$ready" "$GATED_PID" || fail "pipeline-activation final-recheck gate did not open"
  printf 'active\n' > "$NM_STATE"
  touch "$proceed"
  wait "$GATED_PID" || fail "pipeline-activation handoff did not refresh"
  assert_supervise_only "$out" "pipeline-activation refresh"
  assert_grep 'Active mutation owner: **no-mistakes run run-live-1**' "$out" \
    "final recheck missed the newly active pipeline"
  pass "final recheck catches a pipeline activated between generation and delivery"
}

test_completed_status_reconciles_newest_run() {
  local state out
  make_case stale-terminal
  out=$CASE_DIR/out
  for state in stale-terminal terminal-unavailable; do
    printf '%s\n' "$state" > "$NM_STATE"
    handoff_env > "$out" || fail "completed-status reconciliation failed"
    assert_supervise_only "$out" "$state reconciliation"
  done
  printf 'terminal\n' > "$NM_STATE"
  handoff_env > "$out" || fail "terminal reconciliation rerun failed"
  assert_free_edit "$out" "confirmed terminal reconciliation"
  pass "completed status cannot hide a newer owner or unavailable history"
}

test_verified_successor_is_not_competing_owner() {
  local out
  make_case successor
  out=$CASE_DIR/out
  printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$ROOT/tests/herdr-custody-fixture.py" > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"
  printf '%s\n' window=default:pane-custody backend=herdr herdr_session=default herdr_workspace_id=ws-custody herdr_tab_id=tab-custody herdr_pane_id=pane-custody >> "$HOME_DIR/state/$ID.meta"
  export FM_FAKE_ENDPOINT_FILE="$CASE_DIR/live" FM_FAKE_TMUX_LABEL_FILE="$CASE_DIR/label"
  touch "$FM_FAKE_ENDPOINT_FILE"
  printf 'fm-%s\n' "$ID" > "$FM_FAKE_TMUX_LABEL_FILE"
  handoff_env > "$out" || fail "Herdr owner capture failed"
  assert_supervise_only "$out" "unexcluded Herdr owner"
  FM_HANDOFF_SUCCESSOR_BACKEND=herdr FM_HANDOFF_SUCCESSOR_TARGET=default:pane-custody handoff_env > "$out" || fail "successor refresh failed"
  assert_free_edit "$out" "verified successor"
  FM_HANDOFF_SUCCESSOR_BACKEND=herdr FM_HANDOFF_SUCCESSOR_TARGET=default:different handoff_env > "$out" || fail "distinct owner refresh failed"
  assert_supervise_only "$out" "distinct Herdr owner"
  printf 'active\n' > "$NM_STATE"
  FM_HANDOFF_SUCCESSOR_BACKEND=herdr FM_HANDOFF_SUCCESSOR_TARGET=default:pane-custody handoff_env > "$out" || fail "successor pipeline refresh failed"
  assert_supervise_only "$out" "pipeline with verified successor"
  pass "exact Herdr successor exclusion preserves competing worker and pipeline custody"
}

test_overlapping_presentations_keep_private_decisions() {
  local normal successor gate pid status=0
  make_case overlap
  normal=$CASE_DIR/normal.out
  successor=$CASE_DIR/successor.out
  gate=$CASE_DIR/capture
  printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$ROOT/tests/herdr-custody-fixture.py" > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"
  printf '%s\n' window=default:pane-custody backend=herdr herdr_session=default herdr_workspace_id=ws-custody herdr_tab_id=tab-custody herdr_pane_id=pane-custody >> "$HOME_DIR/state/$ID.meta"
  export FM_FAKE_ENDPOINT_FILE="$CASE_DIR/live" FM_FAKE_TMUX_LABEL_FILE="$CASE_DIR/label"
  touch "$FM_FAKE_ENDPOINT_FILE"
  printf 'fm-%s\n' "$ID" > "$FM_FAKE_TMUX_LABEL_FILE"
  FM_HANDOFF_NM_TIMEOUT_SECONDS=60 FM_FAKE_CAPTURE_GATE="$gate" handoff_env > "$normal" &
  pid=$!
  if ! fm_test_wait_for_file "$gate.ready" "$pid"; then
    touch "$gate.proceed"
    wait "$pid" || true
    fail "normal presentation did not reach final capture"
  fi
  assert_supervise_only "$ARTIFACT" "normal installed generation"
  FM_HANDOFF_SUCCESSOR_BACKEND=herdr FM_HANDOFF_SUCCESSOR_TARGET=default:pane-custody \
    handoff_env > "$successor" || status=$?
  touch "$gate.proceed"
  wait "$pid" || fail "normal overlapping presentation failed"
  [ "$status" -eq 0 ] || fail "successor overlapping presentation failed"
  assert_free_edit "$successor" "successor private presentation"
  assert_free_edit "$ARTIFACT" "successor durable generation"
  assert_supervise_only "$normal" "normal private presentation"
  [ -z "$(find "$HOME_DIR/data/$ID" -name '.handoff-refresh.*' -print)" ] \
    || fail "overlapping presentation left private data behind"
  pass "overlapping normal and successor presentations retain their own validated decisions"
}

if [ "${FM_TEST_FOCUSED:-}" = presentation-overlap ]; then
  test_overlapping_presentations_keep_private_decisions
  exit 0
fi

test_overlapping_presentations_keep_private_decisions

test_pipeline_custody_ignores_delivery_mode() {
  local state out ready proceed
  make_case local-only-pipeline
  printf 'mode=local-only\n' >> "$HOME_DIR/state/$ID.meta"
  out=$CASE_DIR/out
  for state in active parked stale-terminal terminal-unavailable; do
    printf '%s\n' "$state" > "$NM_STATE"
    handoff_env > "$out" || fail "local-only $state handoff failed"
    assert_supervise_only "$out" "local-only $state pipeline"
  done
  for state in none terminal; do
    printf '%s\n' "$state" > "$NM_STATE"
    handoff_env > "$out" || fail "local-only $state handoff failed"
    assert_free_edit "$out" "local-only $state pipeline"
  done
  printf 'none\n' > "$NM_STATE"
  ready=$CASE_DIR/recheck.ready
  proceed=$CASE_DIR/recheck.proceed
  run_gated_handoff "$out" "$ready" "$proceed"
  fm_test_wait_for_file "$ready" "$GATED_PID" || fail "local-only final-recheck gate did not open"
  printf 'active\n' > "$NM_STATE"
  touch "$proceed"
  wait "$GATED_PID" || fail "local-only activation handoff failed"
  assert_supervise_only "$out" "local-only activation after capture"
  assert_grep 'Active mutation owner: **no-mistakes run run-live-1**' "$out" \
    "local-only activation lost pipeline ownership"
  pass "pipeline custody is independent of delivery mode and refreshes at delivery"
}

if [ "${FM_TEST_FOCUSED:-}" = delivery-mode ]; then
  test_pipeline_custody_ignores_delivery_mode
  exit 0
fi

test_pipeline_custody_ignores_delivery_mode

test_verified_successor_is_not_competing_owner
test_completed_status_reconciles_newest_run
test_no_active_owner_is_free_edit_and_idempotent
test_active_no_mistakes_owner_is_supervise_only
test_active_crewmate_owner_is_supervise_only
test_owner_termination_after_capture_refreshes_to_free_edit
test_head_change_after_capture_refreshes_exact_generation
test_unknown_process_liveness_is_supervise_only
test_final_recheck_catches_pipeline_activation
