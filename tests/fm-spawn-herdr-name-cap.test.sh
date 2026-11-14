#!/usr/bin/env bash
# tests/fm-spawn-herdr-name-cap.test.sh - herdr agent-name length cap guard.
#
# Herdr's `agent start <NAME>` caps names at 32 characters (verified against
# the real binary; over-cap names return `invalid_agent_name`:
# "agent name must start with a lowercase letter and contain only lowercase
# letters, digits, '-' or '_' (1-32 characters)"). fm-spawn.sh's fresh and
# --relaunch paths and fm-control.sh's relaunch path each refuse the task id
# before any pane, tab, workspace, or agent is touched, so a too-long id
# fails closed rather than reporting success while the replacement agent's
# inner `agent start` silently errors and never boots.
#
# Ids are semantic, so the scripts never auto-truncate - the hint is to
# recreate the task under a shorter id. The cap predicate lives once in
# bin/fm-control-lib.sh, which both entry scripts source, so this
# suite pins the cap through the entry points a caller actually invokes,
# on the exact 32/33 boundary:
#   - Integration (spawn): a fresh fm-spawn.sh ship spawn with --backend herdr
#     refuses a 33-char id with the cap and the offending length named, and
#     does NOT refuse when the backend is anything other than herdr (tmux).
#   - Integration (spawn, relaunch): fm-spawn.sh --relaunch against a meta
#     whose recorded backend is herdr refuses a 33-char id with the cap named.
#   - Integration (control, relaunch): bin/fm-control.sh's relaunch verb
#     refuses a 33-char id BEFORE do_exit stops the old agent.
#
# Boundary cases (32 chars exact, 33 chars exact) are exercised, because the
# cap is inclusive and the regression risk lives on either side of the line.
# Each refusal assertion is also what makes the suite a guard rather than
# decoration: without the cap check in the scripts, the 33-char cases fall
# through to an unrelated downstream failure and the "herdr caps agent
# names" assertion fails.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
CONTROL="$ROOT/bin/fm-control.sh"

# fm_test_tmproot registers its own cleanup trap, so no EXIT trap here.
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-name-cap)
mkdir -p "$TMP_ROOT"

# A herdr stub shadows any real herdr CLI on the test host: the pass-through
# cases (32-char ids) continue PAST the cap check into the backend adapter,
# and a real binary could answer a nonexistent session by starting a real
# server - a side effect a hermetic suite must never risk. The stub fails
# every invocation instantly, so each pass-through case refuses downstream
# with a non-zero exit and, crucially, never touches a real endpoint.
mkdir -p "$TMP_ROOT/fakebin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'echo "herdr-stub: hermetic test stub refuses every invocation" >&2' \
  'exit 1' > "$TMP_ROOT/fakebin/herdr"
chmod +x "$TMP_ROOT/fakebin/herdr"

# 32 chars exactly (within the cap), 33 chars (one past), 40 chars (the live
# failure shape firstmate hit in practice on a real task id).
ID32=$(printf 'a%.0s' $(seq 1 32))
ID33=$(printf 'a%.0s' $(seq 1 33))
ID40="m5-audit-chain-test-double-contamination"

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
    "fresh herdr refusal must name the offending length"
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
    "40-char herdr refusal must name the offending length"
  pass "fresh fm-spawn --backend herdr refuses the 40-char live-failure id"
}

test_fresh_spawn_herdr_passes_32_char_id_at_the_cap() {
  # A 32-char id is at the cap. The cap check must NOT fire; any subsequent
  # failure (missing brief, missing project, etc.) is fine - this test only
  # asserts the cap is not what refused it.
  local out rc
  out=$(run_fresh herdr "$ID32")
  rc=$?
  [ "$rc" -ne 0 ] || fail "32-char herdr spawn should still fail downstream (no project), but the cap must not be the cause"
  assert_not_contains "$out" "herdr caps agent names at 32 characters" \
    "32-char id must not trigger the herdr-cap refusal"
  pass "fresh fm-spawn --backend herdr lets a 32-char id pass the cap check"
}

test_fresh_spawn_tmux_does_not_apply_herdr_cap() {
  local out rc
  out=$(run_fresh tmux "$ID33")
  rc=$?
  [ "$rc" -ne 0 ] || fail "tmux spawn with 33-char id should fail downstream (no project), but not at the cap"
  assert_not_contains "$out" "herdr caps agent names at 32 characters" \
    "tmux backend must not apply the herdr-only cap"
  pass "fresh fm-spawn --backend tmux ignores the herdr-only name cap"
}

# --- integration: fm-spawn --relaunch (herdr meta) ----------------------

# Write a minimal valid herdr meta for <id> so fm-spawn --relaunch can resolve
# the recorded endpoint and reach the cap check. The atoms are hyphen-free
# because fm_backend_endpoint_atom_valid rejects '-'.
write_herdr_meta() {
  local dir=$1 id=$2
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fmremote:p1" \
    "endpoint_task_id=$id" \
    "worktree=$dir/home/projects/none" \
    "project=$dir/home/projects/none" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "backend=herdr" \
    "herdr_session=fmremote" \
    "herdr_workspace_id=w1" \
    "herdr_tab_id=t1" \
    "herdr_pane_id=p1"
}

# run_relaunch <id>: writes the meta, runs fm-spawn.sh --relaunch, echoes
# combined output. fm-spawn --relaunch reaches the cap check before the
# agent-state classifier, so no herdr stub is exercised.
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
  assert_not_contains "$out" "herdr caps agent names at 32 characters" \
    "32-char id must not trigger the herdr-cap refusal on relaunch"
  pass "fm-spawn --relaunch lets a 32-char id pass the herdr cap check"
}

# --- integration: fm-control relaunch (herdr meta) ----------------------

# fm-control relaunch must refuse a too-long id BEFORE stopping the old agent.
# The cap check is the first thing do_relaunch does, so this test asserts the
# exit code and the hint without modeling the agent-stop path.
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
  assert_not_contains "$out" "herdr caps agent names at 32 characters" \
    "32-char id must not trigger the herdr-cap refusal on control relaunch"
  pass "fm-control relaunch lets a 32-char id pass the herdr cap check"
}

# --- integration: tmux meta is unaffected -------------------------------

# A meta recorded with backend=tmux must NOT apply the herdr cap; this
# confirms the guard is backend-conditional in fm-control.sh too.
test_control_relaunch_tmux_does_not_apply_herdr_cap() {
  local id dir out rc
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
  out=$(env PATH="$TMP_ROOT/fakebin:$PATH" \
    FM_HOME="$dir/home" \
    FM_ROOT_OVERRIDE='' \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    "$CONTROL" "$id" relaunch --note "progress note" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "tmux-backed control relaunch with 33-char id should fail downstream, but not at the cap"
  assert_not_contains "$out" "herdr caps agent names at 32 characters" \
    "tmux-backed relaunch must not apply the herdr-only cap"
  pass "fm-control relaunch with backend=tmux ignores the herdr-only name cap"
}

fm_test_run \
  test_fresh_spawn_herdr_refuses_33_char_id \
  test_fresh_spawn_herdr_refuses_40_char_id_with_live_failure_shape \
  test_fresh_spawn_herdr_passes_32_char_id_at_the_cap \
  test_fresh_spawn_tmux_does_not_apply_herdr_cap \
  test_relaunch_herdr_refuses_33_char_id \
  test_relaunch_herdr_passes_32_char_id_at_the_cap \
  test_control_relaunch_herdr_refuses_33_char_id \
  test_control_relaunch_herdr_passes_32_char_id_at_the_cap \
  test_control_relaunch_tmux_does_not_apply_herdr_cap
