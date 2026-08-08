#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

# --- Task 6 claim-before-allocation split handshake -------------------------
#
# The ship spawn's claim handshake (bin/fm-spawn.sh, engaged by
# FM_TRACKER_CLAIM=1) must complete before ANY workspace allocation or endpoint
# creation: the spawn allocates the immutable attempt, persists the exact claim
# request, and invokes the attended Decision OS main-steward adapter
# (FM_BR_RECEIPT_BIN) synchronously. A refused or unobserved claim leaves no
# workspace, no endpoint, and no meta; replay from claim_pending must never
# double-claim and never allocate before a valid receipt.

# make_claim_steward <dir> writes the fake attended Decision OS steward that
# FM_BR_RECEIPT_BIN resolves to. It appends one `claim <request-file>` line per
# invocation to $ORDER_FILE, honors FM_STEWARD_EXIT=1 (refused claim) and
# FM_CRASH_AFTER_CLAIM=1 (claim line written, then crash before the receipt),
# and otherwise simulates a SUCCESSFUL claim by observing the tracker effect
# receipt on the attempt record.
make_claim_steward() {
  local dir=$1 fakebin steward
  fakebin=$(fm_fakebin "$dir")
  steward="$fakebin/fm-br-receipt.sh"
  cat > "$steward" <<'SH'
#!/usr/bin/env bash
set -u
printf 'claim %s\n' "${1:-}" >> "${ORDER_FILE:?ORDER_FILE unset}"
[ "${FM_STEWARD_EXIT:-0}" != 1 ] || exit 1
[ "${FM_CRASH_AFTER_CLAIM:-0}" != 1 ] || exit 42
. "${FM_ATTEMPT_LIB:?FM_ATTEMPT_LIB unset}"
req=${1:?request file}
aid=$(jq -r '.attempt_id' "$req")
gen=$(jq -r '.generation' "$req")
bead=$(jq -r '.bead_id' "$req")
fm_attempt_effect_observe "$aid" "$gen" tracker "{\"bead\":\"$bead\",\"status\":\"claimed\"}" || exit 1
exit 0
SH
  chmod +x "$steward"
  printf '%s\n' "$steward"
}

# make_claim_case <name> <id> builds a fixture home, a project whose
# .beads/issues.jsonl is the claim source-hash target, a real worktree of the
# project (so a pre-handshake spawn settles fast instead of hanging the poll
# loop), and the fake steward. Echoes a pipe record.
make_claim_case() {
  local name=$1 id=$2 case_dir home proj wt countfile fakebin steward order
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  countfile="$case_dir/pane-call-count"
  order="$case_dir/order.log"
  steward=$(make_claim_steward "$case_dir")
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-claim-$name"
  mkdir -p "$proj/.beads"
  printf '%s\n' '{"id":"fixture","status":"open"}' > "$proj/.beads/issues.jsonl"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\nDelivery contract: mode=no-mistakes\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$steward|$order|$fakebin|$countfile"
}

read_claim_record() {
  IFS='|' read -r _ CLAIM_HOME CLAIM_PROJ CLAIM_WT CLAIM_STEWARD CLAIM_ORDER CLAIM_FAKEBIN CLAIM_COUNTFILE <<EOF
$1
EOF
}

# run_claim_spawn <id> [VAR=value ...]: the extra arguments are additional
# spawn-environment assignments (e.g. FM_STEWARD_EXIT=1) applied before the
# base fixture environment.
run_claim_spawn() {
  local id=$1
  shift
  env "$@" \
    FM_ROOT_OVERRIDE='' FM_HOME="$CLAIM_HOME" \
    FM_STATE_OVERRIDE="$CLAIM_HOME/state" FM_DATA_OVERRIDE="$CLAIM_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CLAIM_HOME/projects" FM_CONFIG_OVERRIDE="$CLAIM_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_TRACKER_CLAIM=1 \
    FM_BR_RECEIPT_BIN="$CLAIM_STEWARD" ORDER_FILE="$CLAIM_ORDER" \
    FM_REFILL_PROJECT="$CLAIM_PROJ" FM_ATTEMPT_LIB="$ROOT/bin/fm-attempt-lib.sh" \
    FM_FAKE_PANE_PATH="$CLAIM_WT" FM_FAKE_PANE_STALE_READS=0 \
    FM_FAKE_PANE_COUNTFILE="$CLAIM_COUNTFILE" \
    PATH="$CLAIM_FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$CLAIM_PROJ" --mode no-mistakes --yolo off 2>&1
}

# A refused claim must leave no workspace, no endpoint, and no meta: the spawn
# returns before allocation, and the refusal is visible as claim_pending.
test_no_workspace_or_endpoint_before_claim_observed() {
  local rec out rc
  rec=$(make_claim_case claim-refused test-task)
  read_claim_record "$rec"
  out=$(run_claim_spawn test-task FM_STEWARD_EXIT=1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "refused claim must refuse the spawn"
  assert_contains "$out" "claim_pending" "spawn did not report claim_pending"
  [ ! -d "$TMP_ROOT/worktrees/test-task" ] || fail "workspace created before claim receipt"
  [ ! -e "$CLAIM_HOME/state/test-task.meta" ] || fail "meta written before claim receipt"
  pass "no workspace or endpoint exists before claim_observed"
}

# Across a crash after the claim line and a replay, the ORDER file records
# exactly one claim invocation: replay from claim_pending never double-claims
# and never allocates before a valid receipt.
test_replay_after_receipt_does_not_double_claim() {
  local rec out n rc
  rec=$(make_claim_case claim-replay test-task)
  read_claim_record "$rec"
  : > "$CLAIM_ORDER"
  out=$(run_claim_spawn test-task FM_CRASH_AFTER_CLAIM=1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "crash run must refuse the spawn"
  n=$(grep -c '^claim ' "$CLAIM_ORDER" 2>/dev/null || echo 0)
  [ "$n" = 1 ] || fail "crash run claimed $n times, expected exactly 1"
  out=$(run_claim_spawn test-task)
  rc=$?
  [ "$rc" -ne 0 ] || fail "replay without a receipt must refuse the spawn"
  assert_contains "$out" "claim_pending" "replay did not report claim_pending"
  n=$(grep -c '^claim ' "$CLAIM_ORDER" 2>/dev/null || echo 0)
  [ "$n" = 1 ] || fail "double claim on replay: $n"
  [ ! -e "$CLAIM_HOME/state/test-task.meta" ] || fail "replay allocated before a valid receipt"
  pass "replay after the receipt never double-claims"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_no_workspace_or_endpoint_before_claim_observed
test_replay_after_receipt_does_not_double_claim

echo "# all fm-spawn-worktree-settle tests passed"
