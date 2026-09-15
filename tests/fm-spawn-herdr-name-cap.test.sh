#!/usr/bin/env bash
# tests/fm-spawn-herdr-name-cap.test.sh - herdr agent-name length cap guard.
#
# Herdr's `agent start <NAME>` caps names at 32 characters (verified against
# the real binary; over-cap names return `invalid_agent_name`:
# "agent name must start with a lowercase letter and contain only lowercase
# letters, digits, '-' or '_' (1-32 characters)"). fm-spawn.sh's fresh and
# --relaunch paths and fm-control.sh's relaunch path each refuse the task id
# before any pane, tab, workspace, or agent is created, so a too-long id
# fails closed rather than half-creating a stranded endpoint whose inner
# agent-start would silently error. Ids are semantic, so the scripts never
# auto-truncate - the hint is to recreate the task under a shorter id.
#
# This suite pins the cap on its exact 32/33 boundary:
#   - Unit: the predicate itself (fm_backend_herdr_agent_name_within_cap)
#     accepts 0-32 chars and refuses 33+.
#   - Integration (spawn): a fresh fm-spawn.sh ship spawn with --backend herdr
#     refuses a 33-char id with the cap and the offending length named, and
#     does NOT refuse when the backend is anything other than herdr (tmux).
#   - Integration (spawn, relaunch): fm-spawn.sh --relaunch against a meta
#     whose recorded backend is herdr refuses a 33-char id with the cap named.
#   - Integration (control, relaunch): bin/fm-control.sh's relaunch verb
#     refuses a 33-char id BEFORE do_exit stops the (faked) old agent.
#
# Boundary cases (32 chars exact, 33 chars exact) are exercised, because the
# cap is inclusive and the regression risk lives on either side of the line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
CONTROL="$ROOT/bin/fm-control.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-name-cap)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
trap 'rm -rf "$TMP_ROOT"' EXIT

# 32 chars exactly (within the cap), 33 chars (one past), 40 chars (the live
# failure shape from 2026-09-15, m5-audit-chain-test-double-contamination).
ID32=$(printf 'a%.0s' $(seq 1 32))
ID33=$(printf 'a%.0s' $(seq 1 33))
ID40="m5-audit-chain-test-double-contamination"

# --- unit ----------------------------------------------------------------

test_predicate_accepts_0_to_32_chars() {
  local i
  for i in $(seq 0 32); do
    fm_backend_herdr_agent_name_within_cap "$(printf 'a%.0s' $(seq 1 "$i"))" \
      || fail "predicate should accept $i-char id"
  done
  pass "predicate accepts 0..32 chars inclusively"
}

test_predicate_refuses_33_and_beyond() {
  local id
  id=$(printf 'a%.0s' $(seq 1 33))
  fm_backend_herdr_agent_name_within_cap "$id" \
    && fail "predicate should refuse a 33-char id"
  id=$(printf 'a%.0s' $(seq 1 64))
  fm_backend_herdr_agent_name_within_cap "$id" \
    && fail "predicate should refuse a 64-char id"
  pass "predicate refuses every id past the 32-char cap"
}

# --- integration: fresh spawn -------------------------------------------

# run_fresh <backend> <id> -> echoes combined stdout+stderr, sets rc.
# Uses FM_SPAWN_NO_GUARD so the watcher guard does not pollute output.
run_fresh() {
  local backend=$1 id=$2
  local dir="$TMP_ROOT/fresh-$backend-$id"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/projects" "$dir/home/config"
  env PATH="$TMP_ROOT/fakebin:$PATH" \
    FM_HOME="$dir/home" \
    FM_ROOT_OVERRIDE='' \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" "$dir/home/projects/none" \
    --mode no-mistakes --yolo off \
    --backend "$backend" 2>&1
}

test_fresh_spawn_herdr_refuses_33_char_id() {
  local out rc
  out=$(run_fresh herdr "$ID33")
  rc=$?
  [ "$rc" -ne 0 ] || fail "fresh herdr spawn with 33-char id should exit non-zero"
  assert_contains "$out" "herdr caps agent names at 32 characters" \
    "fresh herdr refusal must name the 32-char cap"
  assert_contains "$out" "$ID33" "fresh herdr refusal must echo the offending id"
  assert_contains "$out" "${#ID33} chars" \
    "fresh herdr refusal must name the offending length (got: $(printf '%s' "$out" | tr '\n' ' '))"
  pass "fresh fm-spawn --backend herdr refuses a 33-char task id before any endpoint is created"
}

test_fresh_spawn_herdr_refuses_40_char_id_with_live_failure_shape() {
  local out rc
  out=$(run_fresh herdr "$ID40")
  rc=$?
  [ "$rc" -ne 0 ] || fail "fresh herdr spawn with 40-char id should exit non-zero"
  assert_contains "$out" "herdr caps agent names at 32 characters" \
    "40-char herdr refusal must name the 32-char cap"
  assert_contains "$out" "${#ID40} chars" \
    "40-char herdr refusal must name the offending length (got: $(printf '%s' "$out" | tr '\n' ' '))"
  pass "fresh fm-spawn --backend herdr refuses the 2026-09-15 40-char live-failure id"
}

test_fresh_spawn_herdr_passes_32_char_id_at_the_cap() {
  # A 32-char id is at the cap. The cap check must NOT fire; any subsequent
  # failure (missing brief, etc.) is fine - this test only asserts the cap
  # is not what refused it.
  local out rc
  out=$(run_fresh herdr "$ID32")
  rc=$?
  [ "$rc" -ne 0 ] || fail "32-char herdr spawn should still fail downstream (no brief), but the cap must not be the cause"
  if printf '%s' "$out" | grep -F "herdr caps agent names at 32 characters" >/dev/null; then
    fail "32-char id must not trigger the herdr-cap refusal; got: $(printf '%s' "$out" | tr '\n' '|')"
  fi
  pass "fresh fm-spawn --backend herdr lets a 32-char id pass the cap check"
}

test_fresh_spawn_tmux_does_not_apply_herdr_cap() {
  local out rc
  out=$(run_fresh tmux "$ID33")
  rc=$?
  [ "$rc" -ne 0 ] || fail "tmux spawn with 33-char id should fail downstream (no brief), but not at the cap"
  if printf '%s' "$out" | grep -F "herdr caps agent names at 32 characters" >/dev/null; then
    fail "tmux backend must not apply the herdr-only cap; got: $(printf '%s' "$out" | tr '\n' '|')"
  fi
  pass "fresh fm-spawn --backend tmux ignores the herdr-only name cap"
}

# --- integration: fm-spawn --relaunch (herdr meta) ----------------------

# Write a minimal valid herdr meta for <id> so fm-spawn --relaunch can resolve
# the recorded endpoint and reach the cap check. The agent_state classifier
# check that follows the cap check is bypassed by making fm_backend_agent_state
# echo `dead` via the recorded endpoint and a herdr stub.
write_herdr_meta() {
  local dir=$1 id=$2
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-remote:p1" \
    "endpoint_task_id=$id" \
    "worktree=$dir/home/projects/none" \
    "project=$dir/home/projects/none" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "backend=herdr" \
    "herdr_session=fm-remote" \
    "herdr_workspace_id=w1" \
    "herdr_tab_id=t1" \
    "herdr_pane_id=p1"
}

# run_relaunch <id>: writes the meta, runs fm-spawn.sh --relaunch, echoes
# combined output. fm-spawn --relaunch reaches the cap check before
# fm_control_backend_state_verified, so the herdr stub is not exercised.
run_relaunch() {
  local id=$1
  local dir="$TMP_ROOT/relaunch-$id"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/projects" "$dir/home/config"
  write_herdr_meta "$dir" "$id"
  env PATH="$TMP_ROOT/fakebin:$PATH" \
    FM_HOME="$dir/home" \
    FM_ROOT_OVERRIDE='' \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" --relaunch --harness claude 2>&1
}

test_relaunch_herdr_refuses_33_char_id() {
  local out rc
  out=$(run_relaunch "$ID33")
  rc=$?
  [ "$rc" -ne 0 ] || fail "fm-spawn --relaunch with 33-char herdr meta should exit non-zero"
  assert_contains "$out" "herdr caps agent names at 32 characters" \
    "fm-spawn --relaunch herdr refusal must name the 32-char cap"
  assert_contains "$out" "recreate the task under a shorter id before relaunching" \
    "fm-spawn --relaunch herdr refusal must carry the actionable hint"
  assert_contains "$out" "$ID33" "fm-spawn --relaunch herdr refusal must echo the offending id"
  pass "fm-spawn --relaunch refuses a 33-char task id whose meta records backend=herdr"
}

test_relaunch_herdr_passes_32_char_id_at_the_cap() {
  local out rc
  out=$(run_relaunch "$ID32")
  rc=$?
  [ "$rc" -ne 0 ] || fail "32-char herdr relaunch should fail downstream, but not at the cap"
  if printf '%s' "$out" | grep -F "herdr caps agent names at 32 characters" >/dev/null; then
    fail "32-char id must not trigger the herdr-cap refusal on relaunch; got: $(printf '%s' "$out" | tr '\n' '|')"
  fi
  pass "fm-spawn --relaunch lets a 32-char id pass the herdr cap check"
}

# --- integration: fm-control relaunch (herdr meta) ----------------------

# fm-control relaunch must refuse a too-long id BEFORE stopping the old agent.
# We never reach the old-agent stop because the cap check is the first thing
# do_relaunch does, so this test asserts the exit code and the hint without
# modeling the agent-stop path.
run_control_relaunch() {
  local id=$1
  local dir="$TMP_ROOT/control-$id"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/projects" "$dir/home/config" "$dir/home/data/$id"
  write_herdr_meta "$dir" "$id"
  # A ship/scout relaunch requires an existing brief, so seed one so any
  # downstream check past the cap check has something to read. The cap check
  # fires first, so the brief is never inspected on the refusal path; this
  # keeps the test focused on the cap guard, not on the brief check.
  printf '# placeholder brief\n' > "$dir/home/data/$id/brief.md"
  env PATH="$TMP_ROOT/fakebin:$PATH" \
    FM_HOME="$dir/home" \
    FM_ROOT_OVERRIDE='' \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    "$CONTROL" "$id" relaunch --note "progress note" 2>&1
}

test_control_relaunch_herdr_refuses_33_char_id() {
  local out rc
  out=$(run_control_relaunch "$ID33")
  rc=$?
  [ "$rc" -ne 0 ] || fail "fm-control relaunch with 33-char herdr meta should exit non-zero"
  assert_contains "$out" "herdr caps agent names at 32 characters" \
    "fm-control relaunch herdr refusal must name the 32-char cap"
  assert_contains "$out" "recreate the task under a shorter id before relaunching" \
    "fm-control relaunch herdr refusal must carry the actionable hint"
  assert_contains "$out" "$ID33" "fm-control relaunch herdr refusal must echo the offending id"
  pass "fm-control relaunch refuses a 33-char task id on backend=herdr BEFORE stopping the old agent"
}

test_control_relaunch_herdr_passes_32_char_id_at_the_cap() {
  local out rc
  out=$(run_control_relaunch "$ID32")
  rc=$?
  [ "$rc" -ne 0 ] || fail "32-char herdr control relaunch should fail downstream, but not at the cap"
  if printf '%s' "$out" | grep -F "herdr caps agent names at 32 characters" >/dev/null; then
    fail "32-char id must not trigger the herdr-cap refusal on control relaunch; got: $(printf '%s' "$out" | tr '\n' '|')"
  fi
  pass "fm-control relaunch lets a 32-char id pass the herdr cap check"
}

# --- integration: tmux meta is unaffected -------------------------------

# A meta recorded with backend=tmux must NOT apply the herdr cap; this
# confirms the guard is backend-conditional in fm-control.sh too.
test_control_relaunch_tmux_does_not_apply_herdr_cap() {
  local id dir
  id=$ID33
  dir="$TMP_ROOT/control-tmux-$id"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/projects" "$dir/home/config" "$dir/home/data/$id"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/home/projects/none" \
    "project=$dir/home/projects/none" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  printf '# placeholder brief\n' > "$dir/home/data/$id/brief.md"
  local out rc
  out=$(env PATH="$TMP_ROOT/fakebin:$PATH" \
    FM_HOME="$dir/home" \
    FM_ROOT_OVERRIDE='' \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    "$CONTROL" "$id" relaunch --note "progress note" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "tmux-backed control relaunch with 33-char id should fail downstream, but not at the cap"
  if printf '%s' "$out" | grep -F "herdr caps agent names at 32 characters" >/dev/null; then
    fail "tmux-backed relaunch must not apply the herdr-only cap; got: $(printf '%s' "$out" | tr '\n' '|')"
  fi
  pass "fm-control relaunch with backend=tmux ignores the herdr-only name cap"
}

test_predicate_accepts_0_to_32_chars
test_predicate_refuses_33_and_beyond
test_fresh_spawn_herdr_refuses_33_char_id
test_fresh_spawn_herdr_refuses_40_char_id_with_live_failure_shape
test_fresh_spawn_herdr_passes_32_char_id_at_the_cap
test_fresh_spawn_tmux_does_not_apply_herdr_cap
test_relaunch_herdr_refuses_33_char_id
test_relaunch_herdr_passes_32_char_id_at_the_cap
test_control_relaunch_herdr_refuses_33_char_id
test_control_relaunch_herdr_passes_32_char_id_at_the_cap
test_control_relaunch_tmux_does_not_apply_herdr_cap
