#!/usr/bin/env bash
# tests/fm-slot-audit.test.sh - bin/fm-slot-audit.sh: each live record that
# names a Treehouse pool slot is compared with the slot's owner claim, the
# recorded endpoint's current directory, and the pool's own status word, and
# reported on one line with a verdict. These cases pin every verdict and column
# hermetically over a real git worktree standing in for a pool slot, a fake
# tmux that serves the endpoint's cwd, and a fake treehouse that serves the
# pool's JSON status, then the spawn-time wiring: bin/fm-spawn.sh prints every
# slot-unprotected line as a warning before it sends `treehouse get`.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

AUDIT="$ROOT/bin/fm-slot-audit.sh"
TMP_ROOT=$(fm_test_tmproot fm-slot-audit)
fm_git_identity fmtest fmtest@example.invalid

# make_pool_case <name>: a home, a project repo, and pool/1/project as a real
# git worktree of it under a treehouse-state.json, plus a fakebin whose tmux
# serves FM_FAKE_CWD_FILE's content as the pane's current path and whose
# treehouse serves FM_FAKE_POOL_JSON for `status --json`. Echoes the case dir.
make_pool_case() {  # <name>
  local dir=$1
  dir="$TMP_ROOT/$dir"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin" \
    "$dir/project" "$dir/pool/1" "$dir/elsewhere"
  git init -q "$dir/project"
  git -C "$dir/project" commit --allow-empty -qm pool-fixture
  git -C "$dir/project" worktree add -q --detach "$dir/pool/1/project"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$dir/pool/1/project" \
    > "$dir/pool/treehouse-state.json"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *pane_current_path*)
    [ ! -f "${FM_FAKE_CWD_FILE:-}" ] || cat "$FM_FAKE_CWD_FILE"
    exit 0 ;;
esac
exit 0
SH
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  [ -z "${FM_FAKE_POOL_FAIL:-}" ] || exit 1
  printf '%s\n' "${FM_FAKE_POOL_JSON:-[]}"
  printf 'upgrade banner on stderr\n' >&2
  exit 0
fi
exit 0
SH
  chmod +x "$dir/fakebin/tmux" "$dir/fakebin/treehouse"
  printf '%s\n' "$dir"
}

pool_json() {  # <slot-path> <status>
  printf '[{"name":"1","path":"%s","status":"%s","flavor":"git","lease_id":"","lease_holder":"","leased_at":null,"processes":[]}]' "$1" "$2"
}

write_task() {  # <case> <id> [kind] [worktree]
  local dir=$1 id=$2 kind=${3:-scout} wt=${4:-$1/pool/1/project}
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" \
    "worktree=$wt" "project=$dir/project" "kind=$kind"
}

claim_slot() {  # <case> <task-id>
  printf 'task=%s\nhome=%s\n' "$2" "$1/home" > "$1/pool/1/.fm-slot-owner"
}

run_audit() {  # <case> <args...>
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$PATH" \
    FM_FAKE_CWD_FILE="$dir/cwd" FM_FAKE_POOL_JSON="${FM_FAKE_POOL_JSON:-}" \
    FM_FAKE_POOL_FAIL="${FM_FAKE_POOL_FAIL:-}" \
    "$AUDIT" "$@"
}

test_own_claim_in_slot_reads_ok() {
  local dir out
  dir=$(make_pool_case ok)
  write_task "$dir" t-ok
  claim_slot "$dir" t-ok
  printf '%s\n' "$dir/pool/1/project" > "$dir/cwd"
  FM_FAKE_POOL_JSON=$(pool_json "$dir/pool/1/project" in-use)
  out=$(run_audit "$dir" t-ok) || fail "audit of a healthy record failed: $out"
  assert_equals "slot-audit: t-ok slot=$dir/pool/1/project claim=mine worker=in-slot pool=in-use verdict=ok" "$out" \
    "a claimed slot with its worker inside and the pool in use is ok"
  pass "fm-slot-audit: own claim, worker in the slot, pool in use reads ok"
}

test_claim_by_another_task_is_slot_lost() {
  local dir out
  dir=$(make_pool_case lost)
  write_task "$dir" t-lost
  claim_slot "$dir" t-claimant
  # The displaced worker sits in the project directory, as a Herdr restore
  # leaves it; the pool still reads in-use because the claimant is in there.
  printf '%s\n' "$dir/project" > "$dir/cwd"
  FM_FAKE_POOL_JSON=$(pool_json "$dir/pool/1/project" in-use)
  out=$(run_audit "$dir" --all) || fail "audit of a lost slot failed: $out"
  assert_equals "slot-audit: t-lost slot=$dir/pool/1/project claim=other:t-claimant worker=outside:$dir/project pool=in-use verdict=slot-lost" "$out" \
    "a claim naming another task is slot-lost regardless of the other columns"
  pass "fm-slot-audit: a slot claimed by another task reads slot-lost"
}

test_absent_claim_is_unprotected() {
  local dir out
  dir=$(make_pool_case absent)
  write_task "$dir" t-absent
  printf '%s\n' "$dir/pool/1/project" > "$dir/cwd"
  FM_FAKE_POOL_JSON=$(pool_json "$dir/pool/1/project" in-use)
  out=$(run_audit "$dir" t-absent) || fail "audit of an unclaimed slot failed: $out"
  assert_contains "$out" "claim=absent" "the absent claim should be reported"
  assert_contains "$out" "verdict=slot-unprotected" "an absent claim alone is slot-unprotected"
  assert_not_contains "$out" "worker-outside-slot" "a worker inside its slot is not outside it"
  pass "fm-slot-audit: an absent claim reads slot-unprotected"
}

test_available_pool_and_drifted_worker_combine() {
  local dir out
  dir=$(make_pool_case drifted)
  write_task "$dir" t-drift
  claim_slot "$dir" t-drift
  printf '%s\n' "$dir/elsewhere" > "$dir/cwd"
  FM_FAKE_POOL_JSON=$(pool_json "$dir/pool/1/project" available)
  out=$(run_audit "$dir" t-drift) || fail "audit of a drifted worker failed: $out"
  assert_equals "slot-audit: t-drift slot=$dir/pool/1/project claim=mine worker=outside:$dir/elsewhere pool=available verdict=slot-unprotected,worker-outside-slot" "$out" \
    "an available pool slot whose worker drifted carries both hazards"
  pass "fm-slot-audit: an available slot with a drifted worker reads slot-unprotected,worker-outside-slot"
}

test_pool_read_failure_and_no_pool_are_distinct() {
  local dir out
  dir=$(make_pool_case pool-unknown)
  write_task "$dir" t-pool
  claim_slot "$dir" t-pool
  printf '%s\n' "$dir/pool/1/project" > "$dir/cwd"
  out=$(FM_FAKE_POOL_FAIL=1 run_audit "$dir" t-pool) || fail "audit with a failing treehouse failed: $out"
  assert_contains "$out" "pool=unknown verdict=ok" "a failed pool read is unknown and never a hazard on its own"
  out=$(run_audit "$dir" t-pool --no-pool) || fail "audit with --no-pool failed: $out"
  assert_contains "$out" "pool=skipped verdict=ok" "--no-pool skips the pool read"
  FM_FAKE_POOL_JSON='[]'
  out=$(run_audit "$dir" t-pool) || fail "audit with an empty pool listing failed: $out"
  assert_contains "$out" "pool=unlisted" "a slot the pool listing omits is unlisted"
  pass "fm-slot-audit: pool read failure, --no-pool, and an unlisted slot are told apart"
}

test_endpoint_without_a_path_is_no_endpoint() {
  local dir out
  dir=$(make_pool_case no-endpoint)
  write_task "$dir" t-gone
  claim_slot "$dir" t-gone
  rm -f "$dir/cwd"
  FM_FAKE_POOL_JSON=$(pool_json "$dir/pool/1/project" in-use)
  out=$(run_audit "$dir" t-gone) || fail "audit of an endpoint with no path failed: $out"
  assert_contains "$out" "worker=no-endpoint" "an endpoint that answers no path is no-endpoint"
  assert_contains "$out" "verdict=ok" "no-endpoint alone is not a hazard the audit can prove"
  pass "fm-slot-audit: an endpoint that answers no path reads no-endpoint"
}

test_missing_slot_directory_is_slot_lost() {
  local dir out
  dir=$(make_pool_case missing)
  write_task "$dir" t-missing scout "$dir/pool/1/project"
  git -C "$dir/project" worktree remove --force "$dir/pool/1/project"
  rm -rf "$dir/pool/1"
  out=$(run_audit "$dir" t-missing) || fail "audit of a missing slot failed: $out"
  assert_contains "$out" "pool=missing verdict=slot-lost" "a recorded slot that no longer exists under its pool is slot-lost"
  pass "fm-slot-audit: a recorded slot directory that is gone reads slot-lost"
}

test_records_without_a_pool_slot_are_skipped() {
  local dir out
  dir=$(make_pool_case skipped)
  write_task "$dir" t-plain scout "$dir/elsewhere"
  write_task "$dir" t-mate secondmate
  write_task "$dir" t-pool
  claim_slot "$dir" t-pool
  printf '%s\n' "$dir/pool/1/project" > "$dir/cwd"
  FM_FAKE_POOL_JSON=$(pool_json "$dir/pool/1/project" in-use)
  out=$(run_audit "$dir" --all) || fail "audit over mixed records failed: $out"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c '^slot-audit: ')" "only the pool-slot record should print"
  assert_contains "$out" "slot-audit: t-pool " "the pool-slot record should print"
  pass "fm-slot-audit: records outside a pool and secondmates print nothing"
}

test_json_output_carries_every_column() {
  local dir out
  command -v jq >/dev/null 2>&1 || { echo "skip - jq not installed"; return 0; }
  dir=$(make_pool_case json)
  write_task "$dir" t-json
  claim_slot "$dir" t-other
  printf '%s\n' "$dir/project" > "$dir/cwd"
  FM_FAKE_POOL_JSON=$(pool_json "$dir/pool/1/project" in-use)
  out=$(run_audit "$dir" --all --json) || fail "json audit failed: $out"
  assert_equals t-json "$(printf '%s' "$out" | jq -r '.[0].task')" "json task"
  assert_equals other "$(printf '%s' "$out" | jq -r '.[0].claim')" "json claim"
  assert_equals t-other "$(printf '%s' "$out" | jq -r '.[0].claimant')" "json claimant"
  assert_equals outside "$(printf '%s' "$out" | jq -r '.[0].worker')" "json worker"
  assert_equals "$dir/project" "$(printf '%s' "$out" | jq -r '.[0].worker_cwd')" "json worker cwd"
  assert_equals slot-lost "$(printf '%s' "$out" | jq -r '.[0].verdict')" "json verdict"
  assert_equals 1 "$(printf '%s' "$out" | jq -r 'length')" "one row"
  pass "fm-slot-audit: --json carries every column as a field"
}

test_usage_errors_and_unknown_task() {
  local dir out rc=0
  dir=$(make_pool_case usage)
  out=$(run_audit "$dir" 2>&1) || rc=$?
  expect_code 2 "$rc" "no argument is a usage error"
  rc=0
  out=$(run_audit "$dir" --all t-x 2>&1) || rc=$?
  expect_code 2 "$rc" "a task id with --all is a usage error"
  rc=0
  out=$(run_audit "$dir" t-nope 2>&1) || rc=$?
  expect_code 1 "$rc" "an unknown task id exits 1"
  assert_contains "$out" "no task record for t-nope" "the unknown id is named"
  pass "fm-slot-audit: usage errors exit 2 and an unknown task exits 1"
}

# --- spawn wiring: slot-unprotected lines are warnings before treehouse get --

test_spawn_warns_about_unprotected_slots_before_acquiring() {
  local dir home fakebin proj wt out rc=0
  dir="$TMP_ROOT/spawn-warn"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" spawn-warn-z1
  fm_git_worktree "$proj" "$wt" "wt-spawn-warn"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  cat > "$fakebin/fm-slot-audit-fake.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' 'slot-audit: parked-a slot=$dir/pool/3/project claim=absent worker=outside:$proj pool=available verdict=slot-unprotected,worker-outside-slot'
printf '%s\n' 'slot-audit: healthy-b slot=$dir/pool/4/project claim=mine worker=in-slot pool=in-use verdict=ok'
printf '%s\n' 'slot-audit: lost-c slot=$dir/pool/5/project claim=other:x worker=outside:$proj pool=in-use verdict=slot-lost'
SH
  chmod +x "$fakebin/fm-slot-audit-fake.sh"
  out=$(FM_SLOT_AUDIT_BIN="$fakebin/fm-slot-audit-fake.sh" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" spawn-warn-z1 "$proj" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "the spawn itself should still succeed"$'\n'"$out"
  assert_contains "$out" "warning: slot-audit: parked-a slot=$dir/pool/3/project" \
    "the slot-unprotected record should be named as a warning"
  assert_contains "$out" "may take that slot" "the warning should say why it matters now"
  assert_not_contains "$out" "warning: slot-audit: healthy-b" "an ok record is not a warning"
  assert_not_contains "$out" "warning: slot-audit: lost-c" "a slot-lost record is not the acquisition's hazard"
  pass "fm-spawn: slot-unprotected audit lines are warned about before treehouse get"
}

test_own_claim_in_slot_reads_ok
test_claim_by_another_task_is_slot_lost
test_absent_claim_is_unprotected
test_available_pool_and_drifted_worker_combine
test_pool_read_failure_and_no_pool_are_distinct
test_endpoint_without_a_path_is_no_endpoint
test_missing_slot_directory_is_slot_lost
test_records_without_a_pool_slot_are_skipped
test_json_output_carries_every_column
test_usage_errors_and_unknown_task
test_spawn_warns_about_unprotected_slots_before_acquiring
