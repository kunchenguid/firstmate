#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DETECTOR="$ROOT/bin/fm-unadvanceable-work.sh"
TMP_ROOT=$(fm_test_tmproot fm-unadvanceable-work)

make_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$FM_TEST_TASKS"
SH
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: pane · fixture liveness\n' "${FM_TEST_LIVENESS:-unknown}"
SH
  chmod +x "$fakebin/tasks-axi" "$fakebin/fm-crew-state.sh"
  printf '%s\n' "$fakebin"
}

run_detector() {
  local name=$1 listing=$2 liveness=${3:-unknown} meta_ids=${4:-} dir fakebin id
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/data" "$dir/home/state"
  : > "$dir/home/data/backlog.md"
  for id in $meta_ids; do
    : > "$dir/home/state/$id.meta"
  done
  fakebin=$(make_fakebin "$dir")
  PATH="$fakebin:$PATH" \
    FM_HOME="$dir/home" \
    FM_DATA_OVERRIDE="$dir/home/data" \
    FM_STATE_OVERRIDE="$dir/home/state" \
    FM_TEST_TASKS="$listing" \
    FM_TEST_LIVENESS="$liveness" \
    FM_CREW_STATE_OVERRIDE="$fakebin/fm-crew-state.sh" \
    "$DETECTOR"
}

test_unadvanceable_task_is_flagged() {
  local listing out
  listing='count: 1
tasks[1]{id,state,kind,repo,title,blocked_by,held}:
  abandoned,in_flight,ship,firstmate,Abandoned work,none,no'
  out=$(run_detector abandoned "$listing") || fail "unadvanceable-work detector failed"
  assert_contains "$out" \
    "abandoned: state=in_flight; live_worker=no; hold=no; blocked_by=no" \
    "genuinely unadvanceable task finding"
  pass "a genuinely unadvanceable in-flight task is flagged"
}

test_live_worker_is_not_flagged() {
  local listing out
  listing='count: 1
tasks[1]{id,state,kind,repo,title,blocked_by,held}:
  active,in_flight,ship,firstmate,Active work,none,no'
  out=$(run_detector active "$listing" working active) || fail "live-worker detector case failed"
  [ -z "$out" ] || fail "live worker was flagged: $out"
  pass "an in-flight task with a live worker is silent"
}

test_held_task_is_not_flagged() {
  local listing out
  listing='count: 1
tasks[1]{id,state,kind,repo,title,blocked_by,held}:
  held,in_flight,ship,firstmate,Held work,none,yes'
  out=$(run_detector held "$listing") || fail "held detector case failed"
  [ -z "$out" ] || fail "held task was flagged: $out"
  pass "an in-flight task with a hold is silent"
}

test_dependency_edge_is_not_flagged() {
  local listing out
  listing='count: 1
tasks[1]{id,state,kind,repo,title,blocked_by,held}:
  dependent,in_flight,ship,firstmate,Dependent work,"parent-a,parent-b",no'
  out=$(run_detector dependent "$listing") || fail "dependency-edge detector case failed"
  [ -z "$out" ] || fail "task with a dependency edge was flagged: $out"
  pass "an in-flight task with a dependency edge is silent"
}

test_unknown_liveness_is_not_flagged() {
  local listing out
  listing='count: 1
tasks[1]{id,state,kind,repo,title,blocked_by,held}:
  uncertain,in_flight,ship,firstmate,Uncertain worker,none,no'
  out=$(run_detector uncertain "$listing" unknown uncertain) || fail "unknown-liveness detector case failed"
  [ -z "$out" ] || fail "unknown liveness was flagged: $out"
  pass "unknown worker liveness fails toward silence"
}

test_unadvanceable_task_is_flagged
test_live_worker_is_not_flagged
test_held_task_is_not_flagged
test_dependency_edge_is_not_flagged
test_unknown_liveness_is_not_flagged
