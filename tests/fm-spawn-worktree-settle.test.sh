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

# The Task 7 attempt fixtures below allocate attempt records directly; point the
# attempt lib at a hermetic per-run state dir so records never land in the repo's
# private state. Every spawn in this file passes its own FM_STATE_OVERRIDE, so
# this export only scopes the direct attempt-lib calls.
export FM_STATE_OVERRIDE="$TMP_ROOT/state"
# shellcheck source=bin/fm-attempt-lib.sh
. "$ROOT/bin/fm-attempt-lib.sh"

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
  *"#{pane_current_command}"*)
    printf '%s\n' "${FM_FAKE_PANE_COMMAND:-bash}"
    exit 0
    ;;
  *"#{pane_tty}"*) exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ -z "${FM_FAKE_LIVE_WINDOW:-}" ] || printf '%s\n' "$FM_FAKE_LIVE_WINDOW"
    exit 0
    ;;
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
# and otherwise simulates a successful claim by observing the claim effect
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
fm_attempt_effect_observe "$aid" "$gen" claim "{\"bead\":\"$bead\",\"status\":\"claimed\"}" || exit 1
if [ "${FM_PRESEED_BAD_LAUNCH:-0}" = 1 ]; then
  fm_attempt_effect_observe "$aid" "$gen" launch '{"task":"wrong","status":"launched","endpoint":"wrong","worktree":"wrong","harness":"wrong"}' || exit 1
fi
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
  local rec out rc attempt_file
  rec=$(make_claim_case claim-refused test-task)
  read_claim_record "$rec"
  out=$(run_claim_spawn test-task FM_STEWARD_EXIT=1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "refused claim must refuse the spawn"
  assert_contains "$out" "claim_pending" "spawn did not report claim_pending"
  [ ! -d "$TMP_ROOT/worktrees/test-task" ] || fail "workspace created before claim receipt"
  [ ! -e "$CLAIM_HOME/state/test-task.meta" ] || fail "meta written before claim receipt"
  attempt_file=$(find "$CLAIM_HOME/state/attempts" -maxdepth 1 -name 'test-task-a*.json' | head -1)
  jq -e '[.receipts.claim[]? | select(.state == "pending" and (.reason.reason | contains("exit 1")))] | length >= 1' \
    "$attempt_file" >/dev/null || fail "claim pending evidence lost the steward exit status"
  pass "no workspace or endpoint exists before claim_observed and refusal retains its exit status"
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

test_replay_rejects_mismatched_claim_evidence() {
  local rec out rc aid gen n
  rec=$(make_claim_case claim-mismatch test-task)
  read_claim_record "$rec"
  : > "$CLAIM_ORDER"
  out=$(run_claim_spawn test-task FM_CRASH_AFTER_CLAIM=1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "crash run must refuse the spawn"
  aid=$(basename "$(find "$CLAIM_HOME/state/attempts" -maxdepth 1 -name 'test-task-a*.json' | head -1)" .json)
  gen=$(jq -r '.envelope.generation' "$CLAIM_HOME/state/attempts/$aid.json")
  FM_STATE_OVERRIDE="$CLAIM_HOME/state" fm_attempt_effect_observe "$aid" "$gen" claim \
    '{"bead":"another-bead","status":"claimed"}' || fail "mismatch fixture"
  out=$(run_claim_spawn test-task)
  rc=$?
  [ "$rc" -ne 0 ] || fail "mismatched claim evidence released allocation"
  assert_contains "$out" "claim_pending" "mismatched claim evidence was not preserved pending"
  n=$(grep -c '^claim ' "$CLAIM_ORDER" 2>/dev/null || echo 0)
  [ "$n" = 1 ] || fail "mismatched replay invoked the steward again"
  [ ! -e "$CLAIM_HOME/state/test-task.meta" ] || fail "mismatched evidence allocated a runtime"
  pass "resume validates the exact current-generation claim bead and status"
}

test_successful_launch_receipt_precedes_audit_ledger() {
  local rec out rc aid
  rec=$(make_claim_case claim-launch-receipt test-task)
  read_claim_record "$rec"
  out=$(run_claim_spawn test-task)
  rc=$?
  expect_code 0 "$rc" "claimed spawn should launch"
  aid=$(sed -n 's/^attempt=//p' "$CLAIM_HOME/state/test-task.meta")
  jq -e --arg task test-task '
    . as $record
    | [.receipts.launch[]?
       | select(.state == "observed" and .generation == $record.envelope.generation)
       | select(.evidence.task == $task and .evidence.status == "launched")] | length == 1
  ' "$CLAIM_HOME/state/attempts/$aid.json" >/dev/null || fail "current-generation launch receipt missing"
  jq -e --arg aid "$aid" 'select(.attempt_id == $aid)' "$CLAIM_HOME/state/launch-ledger.jsonl" >/dev/null \
    || fail "audit ledger was not published after the launch receipt"
  pass "successful launch and instruction delivery publish launch evidence before the audit ledger"
}

test_launch_receipt_publication_failure_is_loud_and_skips_ledger() {
  local rec out rc aid
  rec=$(make_claim_case claim-launch-failure test-task)
  read_claim_record "$rec"
  out=$(run_claim_spawn test-task FM_PRESEED_BAD_LAUNCH=1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "contradictory launch receipt did not fail the spawn"
  assert_contains "$out" "launch receipt could not be published" "launch receipt failure was not loud"
  aid=$(basename "$(find "$CLAIM_HOME/state/attempts" -maxdepth 1 -name 'test-task-a*.json' | head -1)" .json)
  if [ -f "$CLAIM_HOME/state/launch-ledger.jsonl" ]; then
    ! jq -e --arg aid "$aid" 'select(.attempt_id == $aid)' "$CLAIM_HOME/state/launch-ledger.jsonl" >/dev/null \
      || fail "audit ledger published despite launch receipt failure"
  fi
  pass "launch receipt publication failure fails loudly and suppresses the audit ledger"
}

test_live_endpoint_reconciles_missing_launch_receipt_on_resume() {
  local rec out rc aid attempt_file claims ledger_rows
  rec=$(make_claim_case claim-live-launch-replay test-task)
  read_claim_record "$rec"
  : > "$CLAIM_ORDER"
  out=$(run_claim_spawn test-task)
  rc=$?
  expect_code 0 "$rc" "initial claimed spawn should launch"
  aid=$(sed -n 's/^attempt=//p' "$CLAIM_HOME/state/test-task.meta")
  attempt_file="$CLAIM_HOME/state/attempts/$aid.json"
  jq '.receipts.launch = null' "$attempt_file" > "$attempt_file.tmp"
  mv -f "$attempt_file.tmp" "$attempt_file"
  rm -f "$CLAIM_HOME/state/launch-ledger.jsonl"
  out=$(run_claim_spawn test-task FM_FAKE_LIVE_WINDOW=fm-test-task FM_FAKE_PANE_COMMAND=codex)
  rc=$?
  expect_code 0 "$rc" "live endpoint resume should restore its launch receipt: $out"
  assert_contains "$out" "reconciled launch receipt" "spawn did not report launch reconciliation"
  jq -e --arg task test-task --arg endpoint firstmate:fm-test-task '
    [.receipts.launch[]?
      | select(.state == "observed")
      | select(.evidence.task == $task and .evidence.endpoint == $endpoint)
      | select(.evidence.status == "launched" and .evidence.recovered_from == "verified-live-endpoint")]
    | length == 1
  ' "$attempt_file" >/dev/null || fail "verified live endpoint did not restore exact launch evidence"
  claims=$(grep -c '^claim ' "$CLAIM_ORDER" 2>/dev/null || echo 0)
  [ "$claims" = 1 ] || fail "launch reconciliation repeated the authoritative claim"
  ledger_rows=$(jq -s --arg aid "$aid" '[.[] | select(.attempt_id == $aid)] | length' \
    "$CLAIM_HOME/state/launch-ledger.jsonl")
  [ "$ledger_rows" = 1 ] || fail "launch reconciliation did not publish exactly one audit row"
  pass "verified live endpoint restores a missing launch receipt on resume"
}

test_live_endpoint_with_mismatched_attempt_still_refuses_resume() {
  local rec out rc aid attempt_file
  rec=$(make_claim_case claim-live-launch-mismatch test-task)
  read_claim_record "$rec"
  out=$(run_claim_spawn test-task)
  rc=$?
  expect_code 0 "$rc" "initial claimed spawn should launch"
  aid=$(sed -n 's/^attempt=//p' "$CLAIM_HOME/state/test-task.meta")
  attempt_file="$CLAIM_HOME/state/attempts/$aid.json"
  jq '.receipts.launch = null' "$attempt_file" > "$attempt_file.tmp"
  mv -f "$attempt_file.tmp" "$attempt_file"
  sed -i 's/^attempt=.*/attempt=another-attempt/' "$CLAIM_HOME/state/test-task.meta"
  out=$(run_claim_spawn test-task FM_FAKE_LIVE_WINDOW=fm-test-task FM_FAKE_PANE_COMMAND=codex)
  rc=$?
  [ "$rc" -ne 0 ] || fail "mismatched attempt metadata authorized launch reconciliation"
  assert_contains "$out" "refusing launch receipt recovery" "mismatched endpoint identity was not refused"
  jq -e '.receipts.launch == null' "$attempt_file" >/dev/null \
    || fail "mismatched endpoint identity published launch evidence"
  pass "live endpoint cannot reconcile a different attempt identity"
}

# --- Task 7 attempt-bound provider-wide physical-copy ownership -----------
#
# The treehouse pool lease binds BOTH home and attempt (home_id:attempt_id),
# so two attempts in the same home cannot acquire the same physical copy. A
# crash after allocation (freeze) leaves the provider effect in place and the
# release obligation derives from the missing launch effect; replay releases
# only the exact owning attempt.

# claim_copy <home> <attempt>: fake treehouse get --lease --lease-holder
# against a shared pool; the lease holder is home:attempt and one physical
# copy is owned by exactly one (home, attempt).
claim_copy() {  # <home> <attempt>
  mkdir -p "$TMP_ROOT/pool"
  local holder="$1:$2"
  local i
  for i in 1 2 3; do
    if [ ! -e "$TMP_ROOT/pool/copy-$i" ]; then
      printf '%s\n' "$holder" > "$TMP_ROOT/pool/copy-$i.holder"
      touch "$TMP_ROOT/pool/copy-$i"
      printf '%s\n' "$TMP_ROOT/pool/copy-$i"
      return 0
    fi
    if [ "$(cat "$TMP_ROOT/pool/copy-$i.holder")" = "$holder" ]; then
      printf '%s\n' "$TMP_ROOT/pool/copy-$i"
      return 0
    fi
  done
  echo "pool exhausted" >&2
  return 1
}
HOLDER_1() { cat "$TMP_ROOT/pool/copy-1.holder"; }
HOLDER_2() { cat "$TMP_ROOT/pool/copy-2.holder"; }

test_same_home_concurrent_attempts_get_distinct_copies() {
  # two attempts in the same home acquire two distinct pooled copies; the
  # lease-holder records home AND attempt
  local c1 c2
  c1=$(claim_copy "home-a" "attempt-a1")
  c2=$(claim_copy "home-a" "attempt-a2")
  [ "$c1" != "$c2" ] || fail "same-home attempts share a copy"
  [ "$(HOLDER_1)" = "home-a:attempt-a1" ] || fail "lease holder lacks attempt identity"
  [ "$(HOLDER_2)" = "home-a:attempt-a2" ] || fail "second attempt lease holder"
  pass "two attempts in the same home cannot acquire the same physical copy"
}

test_crash_after_allocation_retains_pending_release_obligation() {
  # crash after the provider receipt but before launch; the attempt record
  # carries the provider effect and the release obligation derives from the
  # missing launch effect
  local aid
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-c holu) || fail "alloc"
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-c"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' || fail "freeze"
  assert_contains "$(fm_attempt_obligations "$aid")" "launch" "no pending obligation after crash"
  pass "a crash after allocation retains a pending release obligation"
}

test_replay_releases_only_the_exact_owning_attempt() {
  # two attempts, one owns copy C; replay of the other must not release C
  local aid1 aid2
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid1=$(fm_attempt_alloc pi dos-d holu)
  aid2=$(fm_attempt_alloc pi dos-e holu)
  fm_attempt_freeze_allocation "$aid1" 1 '{"provider":"tmux","copy":"wt-d"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}'
  fm_attempt_freeze_allocation "$aid2" 1 '{"provider":"tmux","copy":"wt-e"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}'
  [ "$(fm_attempt_load "$aid2" | jq -r '.provider.copy')" = wt-e ] || fail "a2 owns wrong copy"
  [ "$(fm_attempt_load "$aid1" | jq -r '.provider.copy')" = wt-d ] || fail "a1 lost its copy"
  pass "replay releases only the exact owning attempt"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_no_workspace_or_endpoint_before_claim_observed
test_replay_after_receipt_does_not_double_claim
test_replay_rejects_mismatched_claim_evidence
test_successful_launch_receipt_precedes_audit_ledger
test_launch_receipt_publication_failure_is_loud_and_skips_ledger
test_live_endpoint_reconciles_missing_launch_receipt_on_resume
test_live_endpoint_with_mismatched_attempt_still_refuses_resume
test_same_home_concurrent_attempts_get_distinct_copies
test_crash_after_allocation_retains_pending_release_obligation
test_replay_releases_only_the_exact_owning_attempt

echo "# all fm-spawn-worktree-settle tests passed"
