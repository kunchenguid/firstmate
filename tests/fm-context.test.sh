#!/usr/bin/env bash
# Behavior tests for bin/fm-context.sh - the read-only crewmate context monitor.
# It reads state/<id>.context (written by the claude Stop hook), divides by the
# window implied by the task's meta model= (1M default, 200k for haiku), prints one
# line per task, and exits non-zero if ANY listed task is at/over the handoff
# threshold (default 60%, override FM_CTX_THRESHOLD) so a heartbeat can branch on it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CTX="$ROOT/bin/fm-context.sh"
TMP=$(fm_test_tmproot fm-context)
STATE="$TMP/state"
mkdir -p "$STATE"

# seed <id> <tokens> <model>: write a task's .context + .meta pair.
seed() {
  local id=$1 tokens=$2 model=${3:-default}
  printf '%s\n' "$tokens" > "$STATE/$id.context"
  fm_write_meta "$STATE/$id.meta" \
    "window=firstmate:fm-$id" "worktree=/tmp/$id" "project=/tmp/$id" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "model=$model" "effort=default"
}

run() {  # <args...> -> sets OUT and RC
  OUT=$(FM_STATE_OVERRIDE="$STATE" "$CTX" "$@"); RC=$?
  return 0
}

# --- below threshold: exit 0, no FLAG ---------------------------------------
seed below 500000 default          # 50% of 1M
run below
expect_code 0 "$RC" "below-threshold task exits 0"
assert_contains "$OUT" "500000/1000000" "prints tokens/window"
assert_not_contains "$OUT" "FLAG" "below threshold is not flagged"
pass "below threshold (50%): exit 0, no FLAG"

# --- at/over threshold: exit 1, FLAG ----------------------------------------
seed over 700000 default           # 70% of 1M
run over
expect_code 1 "$RC" "over-threshold task exits 1"
assert_contains "$OUT" "FLAG >=60%" "over threshold is flagged"
pass "over threshold (70%): exit 1, FLAG"

# --- exactly at threshold is flagged (>= not >) -----------------------------
seed exact 600000 default          # 60% of 1M
run exact
expect_code 1 "$RC" "exactly-at-threshold task exits 1"
assert_contains "$OUT" "FLAG >=60%" "exactly at threshold is flagged (>=)"
pass "exactly at threshold (60%): flagged"

# --- haiku uses the 200k window ---------------------------------------------
seed hk 130000 claude-haiku-4-5    # 65% of 200k
run hk
expect_code 1 "$RC" "haiku task over 200k window exits 1"
assert_contains "$OUT" "130000/200000" "haiku window is 200k"
assert_contains "$OUT" "FLAG" "haiku 65% is flagged"
pass "haiku model: 200k window, 65% flagged"

# --- custom threshold via FM_CTX_THRESHOLD ----------------------------------
OUT=$(FM_STATE_OVERRIDE="$STATE" FM_CTX_THRESHOLD=40 "$CTX" below); RC=$?
expect_code 1 "$RC" "50% task exits 1 under a 40% threshold"
assert_contains "$OUT" "FLAG >=40%" "custom threshold shown in FLAG"
pass "FM_CTX_THRESHOLD=40: a 50% task now flags"

# --- a task with no .context is no-data and not flagged ----------------------
fm_write_meta "$STATE/nod.meta" \
  "window=firstmate:fm-nod" "worktree=/tmp/nod" "project=/tmp/nod" \
  "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
  "model=default" "effort=default"
OUT=$(FM_STATE_OVERRIDE="$STATE" "$CTX" nod); RC=$?
expect_code 0 "$RC" "no-data task does not force a non-zero exit"
assert_contains "$OUT" "no-data" "missing .context reports no-data"
pass "no .context file: no-data, not flagged"

# --- scan-all mode: exits 1 because at least one flagged task exists ----------
OUT=$(FM_STATE_OVERRIDE="$STATE" "$CTX"); RC=$?
expect_code 1 "$RC" "scan-all exits 1 when any task is flagged"
assert_contains "$OUT" "below" "scan-all includes the below task"
assert_contains "$OUT" "over" "scan-all includes the over task"
pass "scan-all (no args): reports every context task, exits 1 on any flag"

pass "fm-context: all cases"
