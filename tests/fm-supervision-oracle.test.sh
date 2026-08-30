#!/usr/bin/env bash
# tests/fm-supervision-oracle.test.sh - self-tests for the supervision recovery oracle.
#
# Proves each invariant fires on violation and stays silent when satisfied, and that
# the oracle detects a deliberately introduced fault. Every case uses a disposable
# synthetic home under fm_test_tmproot; the live fleet is never touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

ORACLE="$ROOT/bin/fm-supervision-oracle.sh"
ORACLE_LIB="$ROOT/bin/fm-supervision-oracle-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervision-oracle)

assert_present "$ORACLE" "bin/fm-supervision-oracle.sh is missing"
assert_present "$ORACLE_LIB" "bin/fm-supervision-oracle-lib.sh is missing"
[ -x "$ORACLE" ] || fail "bin/fm-supervision-oracle.sh must be executable"

make_synthetic_home() { # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/projects"
  "$ORACLE" init-synthetic --home "$home" >/dev/null
  printf '%s\n' "$home"
}

make_fake_crew_state() { # <fakebin> <id> <verdict-line>
  local fakebin=$1 id=$2 verdict=$3
  cat > "$fakebin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  --worker-liveness) shift ;;
esac
id=\${1:-}
case "\$id" in
  $id) printf '%s\n' "$verdict" ;;
  *) printf 'liveness: unknown · source: none\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/fm-crew-state.sh"
}

make_task() { # <home> <id> [status-line]
  local home=$1 id=$2 status=${3:-working: synthetic task}
  local repo wt
  repo="$home/projects/$id.git"
  wt="$home/projects/$id-wt"
  fm_git_worktree "$repo" "$wt" "task/$id"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  printf '%s\n' "$status" > "$home/state/$id.status"
}

oracle_with_lib() { # <home> <function> [args...]
  local home=$1
  shift
  bash -c '
    home=$1
    lib=$2
    shift 2
    FM_ORACLE_HOME=$home
    FM_ORACLE_STATE=$home/state
    FM_ORACLE_SNAPSHOT=$home/state/.supervision-oracle-snapshot.tsv
    FM_ORACLE_LIVENESS=$home/state/.supervision-oracle-liveness.tsv
    FM_ORACLE_ENDPOINTS=$home/state/.supervision-oracle-endpoints.tsv
    . "$lib"
    "$@"
  ' _ "$home" "$ORACLE_LIB" "$@"
}

mark_live_endpoint() { # <home> <id>
  oracle_with_lib "$1" fm_oracle_endpoint_set "$2" alive >/dev/null
}

set_liveness_truth() { # <home> <id> <live|absent|unknown>
  oracle_with_lib "$1" fm_oracle_liveness_set "$2" "$3" >/dev/null
}

oracle_check() { # <home> [extra-env...]
  local home=$1
  shift
  env "$@" FM_ORACLE_CREW_STATE="$home/fakebin/fm-crew-state.sh" \
    "$ORACLE" check --home "$home" 2>&1
}

oracle_expect_violation() { # <pattern> <home> [extra-env...]
  local pattern=$1 home=$2
  shift 2
  local out rc=0
  out=$(oracle_check "$home" "$@") || rc=$?
  [ "$rc" -eq 1 ] || fail "expected violation exit 1, got $rc: $out"
  case "$out" in
    *"$pattern"*) ;;
    *) fail "expected violation matching '$pattern', got: $out" ;;
  esac
}

oracle_expect_clean() { # <home> [extra-env...]
  local home=$1
  shift
  local out rc=0
  out=$(oracle_check "$home" "$@" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "expected clean oracle, got exit $rc: $out"
  case "$out" in
    *VIOLATION:*) fail "unexpected violation on clean home: $out" ;;
  esac
}

test_refuses_live_fleet_paths() {
  local rc=0
  "$ORACLE" check --home /Users/pedromuller/dev/firstmate/state >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "live fleet path must refuse with exit 2, got $rc"
  pass "oracle refuses the live fleet state directory"
}

test_refuses_unmarked_home() {
  local home rc=0
  home=$(fm_test_tmproot fm-oracle-unmarked)
  mkdir -p "$home/state"
  "$ORACLE" check --home "$home" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "unmarked home must refuse with exit 2, got $rc"
  pass "oracle refuses a home without the synthetic marker"
}

test_work_preserved_passes_when_unchanged() {
  local home
  home=$(make_synthetic_home work-ok)
  make_task "$home" alpha 'working: hold'
  mark_live_endpoint "$home" alpha
  "$ORACLE" snapshot --home "$home" >/dev/null
  oracle_expect_clean "$home"
  pass "work_preserved stays silent when worktree fingerprints are unchanged"
}

test_work_preserved_fires_on_lost_uncommitted_work() {
  local home
  home=$(make_synthetic_home work-lost)
  make_task "$home" beta 'working: edit'
  mark_live_endpoint "$home" beta
  "$ORACLE" snapshot --home "$home" >/dev/null
  printf 'lost local edit\n' >> "$home/projects/beta-wt/README.md"
  oracle_expect_violation 'work_preserved: task beta' "$home"
  pass "work_preserved fires when uncommitted work disappears"
}

test_no_orphans_passes_with_live_endpoint_and_terminal_tasks() {
  local home
  home=$(make_synthetic_home orphan-ok)
  make_task "$home" live 'working: active'
  make_task "$home" closed 'done: shipped'
  mark_live_endpoint "$home" live
  oracle_expect_clean "$home"
  pass "no_orphans stays silent when live endpoints have metadata and terminal tasks are closed"
}

test_no_orphans_fires_on_live_endpoint_without_metadata() {
  local home
  home=$(make_synthetic_home orphan-live)
  make_task "$home" keeper 'done: shipped'
  oracle_with_lib "$home" fm_oracle_endpoint_set ghost alive >/dev/null
  oracle_expect_violation 'no_orphans: live endpoint ghost has no metadata' "$home"
  pass "no_orphans fires when a live endpoint lacks metadata"
}

test_no_orphans_fires_on_inflight_without_endpoint() {
  local home
  home=$(make_synthetic_home orphan-inflight)
  make_task "$home" stray 'working: nowhere'
  oracle_expect_violation 'no_orphans: in-flight task stray' "$home"
  pass "no_orphans fires when in-flight metadata has no live endpoint or terminal outcome"
}

test_liveness_honest_passes_when_verdict_matches_ground_truth() {
  local home fakebin
  home=$(make_synthetic_home liveness-ok)
  make_task "$home" crew 'working: busy'
  mark_live_endpoint "$home" crew
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  make_fake_crew_state "$fakebin" crew 'liveness: live · source: pane'
  set_liveness_truth "$home" crew live
  oracle_expect_clean "$home" FM_ORACLE_CREW_STATE="$fakebin/fm-crew-state.sh"
  pass "liveness_honest stays silent when fm-crew-state matches ground truth"
}

test_liveness_honest_fires_when_alive_worker_reported_dead() {
  local home fakebin
  home=$(make_synthetic_home liveness-dead)
  make_task "$home" crew 'working: busy'
  mark_live_endpoint "$home" crew
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  make_fake_crew_state "$fakebin" crew 'liveness: absent · source: metadata'
  set_liveness_truth "$home" crew live
  oracle_expect_violation 'liveness_honest: task crew is alive but reported absent' "$home" \
    FM_ORACLE_CREW_STATE="$fakebin/fm-crew-state.sh"
  pass "liveness_honest fires when a live worker is reported dead"
}

test_liveness_honest_fires_when_dead_worker_reported_alive() {
  local home fakebin
  home=$(make_synthetic_home liveness-live)
  make_task "$home" crew 'failed: gone'
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  make_fake_crew_state "$fakebin" crew 'liveness: live · source: pane'
  set_liveness_truth "$home" crew absent
  oracle_expect_violation 'liveness_honest: task crew is dead but reported live' "$home" \
    FM_ORACLE_CREW_STATE="$fakebin/fm-crew-state.sh"
  pass "liveness_honest fires when a dead worker is reported alive"
}

test_wake_queue_converged_passes_after_drain_and_ack() {
  local home state
  home=$(make_synthetic_home wake-ok)
  state="$home/state"
  append_wake "$state" signal task.status 'signal: synthetic' || fail "wake append failed"
  oracle_expect_clean "$home"
  pass "wake_queue_converged stays silent after drain and acknowledgement"
}

test_wake_queue_converged_fires_when_durable_rows_remain() {
  local home state
  home=$(make_synthetic_home wake-stuck)
  state="$home/state"
  append_wake "$state" signal task.status 'signal: stuck' || fail "wake append failed"
  printf 'stuck-row\n' >> "$state/.wake-queue"
  oracle_expect_violation 'wake_queue_converged: durable wake rows remain' "$home"
  pass "wake_queue_converged fires when durable wake rows survive drain and ack"
}

test_state_matches_reality_passes_on_consistent_records() {
  local home
  home=$(make_synthetic_home state-ok)
  make_task "$home" tidy 'working: tidy'
  mark_live_endpoint "$home" tidy
  oracle_expect_clean "$home"
  pass "state_matches_reality stays silent when metadata and worktrees agree"
}

test_state_matches_reality_fires_on_missing_worktree() {
  local home
  home=$(make_synthetic_home state-missing)
  make_task "$home" gone 'working: ghost'
  mark_live_endpoint "$home" gone
  rm -rf "$home/projects/gone-wt"
  oracle_expect_violation 'state_matches_reality: task gone worktree missing' "$home"
  pass "state_matches_reality fires when metadata points at a missing worktree"
}

test_state_matches_reality_fires_on_endpoint_task_id_mismatch() {
  local home
  home=$(make_synthetic_home state-mismatch)
  make_task "$home" alpha 'working: pooled'
  mark_live_endpoint "$home" alpha
  printf 'endpoint_task_id=beta\n' >> "$home/state/alpha.meta"
  oracle_expect_violation 'state_matches_reality: task alpha metadata endpoint_task_id=beta' "$home"
  pass "state_matches_reality fires when metadata claims another task's endpoint"
}

test_state_matches_reality_fires_on_duplicate_worktree_claim() {
  local home wt
  home=$(make_synthetic_home state-dup-wt)
  make_task "$home" alpha 'working: first holder'
  make_task "$home" beta 'working: second holder'
  wt="$home/projects/beta-wt"
  printf 'worktree=%s\n' "$wt" >> "$home/state/alpha.meta"
  oracle_expect_violation 'state_matches_reality: duplicate worktree claim' "$home"
  pass "state_matches_reality fires when two tasks claim the same worktree path"
}

test_oracle_catches_deliberate_fault_injection() {
  local home out rc=0
  home=$(make_synthetic_home fault-proof)
  make_task "$home" ship 'working: before fault'
  mark_live_endpoint "$home" ship
  "$ORACLE" snapshot --home "$home" >/dev/null
  oracle_expect_clean "$home"
  printf 'injected fault line\n' >> "$home/projects/ship-wt/README.md"
  out=$(oracle_check "$home") || rc=$?
  [ "$rc" -eq 1 ] || fail "deliberately injected work loss must fail the oracle, got $rc"
  case "$out" in
    *work_preserved:*) ;;
    *) fail "deliberate fault must trip work_preserved, got: $out" ;;
  esac
  pass "oracle detects a deliberately introduced work-loss fault"
}

test_refuses_live_fleet_paths
test_refuses_unmarked_home
test_work_preserved_passes_when_unchanged
test_work_preserved_fires_on_lost_uncommitted_work
test_no_orphans_passes_with_live_endpoint_and_terminal_tasks
test_no_orphans_fires_on_live_endpoint_without_metadata
test_no_orphans_fires_on_inflight_without_endpoint
test_liveness_honest_passes_when_verdict_matches_ground_truth
test_liveness_honest_fires_when_alive_worker_reported_dead
test_liveness_honest_fires_when_dead_worker_reported_alive
test_wake_queue_converged_passes_after_drain_and_ack
test_wake_queue_converged_fires_when_durable_rows_remain
test_state_matches_reality_passes_on_consistent_records
test_state_matches_reality_fires_on_missing_worktree
test_state_matches_reality_fires_on_endpoint_task_id_mismatch
test_state_matches_reality_fires_on_duplicate_worktree_claim
test_oracle_catches_deliberate_fault_injection
