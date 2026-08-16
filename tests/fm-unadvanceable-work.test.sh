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
set -u
case "${1:-}" in
  --version|-v|-V)
    printf '%s\n' "${FM_TEST_TASKS_AXI_VERSION:-0.2.5}"
    exit 0
    ;;
  update)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi update <id> [--archive-body]'
      exit 0
    fi
    ;;
  mv)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi mv <dest> [<id>...]'
      exit 0
    fi
    ;;
  list)
    printf '%s\n' "$FM_TEST_TASKS"
    exit 0
    ;;
esac
printf 'fm-unadvanceable-work fixture: unsupported tasks-axi %s\n' "$*" >&2
exit 1
SH
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: pane · fixture liveness\n' "${FM_TEST_LIVENESS:-unknown}"
SH
  chmod +x "$fakebin/tasks-axi" "$fakebin/fm-crew-state.sh"
  printf '%s\n' "$fakebin"
}

# Real tasks-axi 0.2.5 closes a row-bearing listing with this two-space-indented
# help block, so every fixture listing that has rows carries it: the row scan
# has to reset on the non-indented header and leave the entries alone. An empty
# result carries no bracketed header and no help block, so it gets neither.
with_help_trailer() {  # <listing>
  case "$1" in
    *'tasks['*) ;;
    *) printf '%s\n' "$1"; return 0 ;;
  esac
  # shellcheck disable=SC2016 # The backticks are literal tasks-axi help text.
  printf '%s\nhelp[1]:\n  - Run `tasks-axi show <id> --file=%s` for full notes on a task\n' \
    "$1" "$TMP_ROOT/home/data/backlog.md"
}

run_detector() {
  local name=$1 listing=$2 liveness=${3:-unknown} meta_ids=${4:-} dir fakebin id
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/data" "$dir/home/state" "$dir/home/config"
  : > "$dir/home/data/backlog.md"
  if [ -n "${FM_TEST_BACKLOG_BACKEND:-}" ]; then
    printf '%s\n' "$FM_TEST_BACKLOG_BACKEND" > "$dir/home/config/backlog-backend"
  fi
  for id in $meta_ids; do
    : > "$dir/home/state/$id.meta"
  done
  fakebin=$(make_fakebin "$dir")
  PATH="$fakebin:$PATH" \
    FM_HOME="$dir/home" \
    FM_DATA_OVERRIDE="$dir/home/data" \
    FM_STATE_OVERRIDE="$dir/home/state" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_TEST_TASKS="$(with_help_trailer "$listing")" \
    FM_TEST_LIVENESS="$liveness" \
    FM_CREW_STATE_OVERRIDE="$fakebin/fm-crew-state.sh" \
    "$DETECTOR"
}

test_unadvanceable_task_is_flagged() {
  local listing out
  listing='count: 1
tasks[1]{id,state,kind,repo,title,blocked_by,held}:
  abandoned,in_flight,ship,firstmate,Abandoned work,none,no'
  out=$(run_detector abandoned "$listing" "done" abandoned) || fail "unadvanceable-work detector failed"
  assert_contains "$out" \
    "abandoned: state=in_flight; live_worker=no; hold=no; blocked_by=no" \
    "genuinely unadvanceable task finding"
  pass "a genuinely unadvanceable in-flight task is flagged"
}

test_missing_meta_is_not_flagged() {
  local listing out
  listing='count: 1
tasks[1]{id,state,kind,repo,title,blocked_by,held}:
  missing,in_flight,ship,firstmate,Missing runtime record,none,no'
  out=$(run_detector missing-meta "$listing") || fail "no-meta detector case failed"
  [ -z "$out" ] || fail "a no-meta in-flight row was flagged: $out"
  pass "missing metadata is owned by the contradiction digest"
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

test_manual_backlog_backend_cannot_answer() {
  local listing out rc
  listing='count: 1
tasks[1]{id,state,kind,repo,title,blocked_by,held}:
  abandoned,in_flight,ship,firstmate,Abandoned work,none,no'
  out=$(FM_TEST_BACKLOG_BACKEND=manual \
    run_detector manual-backend "$listing" "done" abandoned 2>/dev/null)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a manual backlog backend reported strandedness it never read"
  [ -z "$out" ] || fail "a manual backlog backend printed a finding: $out"
  pass "an opted-out backlog backend reports unreadable instead of silence"
}

test_incompatible_tasks_axi_cannot_answer() {
  local listing out rc
  listing='count: 1
tasks[1]{id,state,kind,repo,title,blocked_by,held}:
  abandoned,in_flight,ship,firstmate,Abandoned work,none,no'
  out=$(FM_TEST_TASKS_AXI_VERSION=0.1.0 \
    run_detector incompatible-backend "$listing" "done" abandoned 2>/dev/null)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an incompatible tasks-axi reported strandedness it never read"
  [ -z "$out" ] || fail "an incompatible tasks-axi printed a finding: $out"
  pass "an incompatible tasks-axi reports unreadable instead of silence"
}

test_unreadable_listing_shape_is_an_error() {
  local listing out rc
  listing='count: 1
tasks[1]{id,state,kind,repo,title,blocked_by,held,priority}:
  abandoned,in_flight,ship,firstmate,Abandoned work,none,no,p2'
  out=$(run_detector unreadable-shape "$listing" "done" abandoned 2>/dev/null)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a listing the row scan cannot read reported peace instead of failing"
  [ -z "$out" ] || fail "an unreadable listing shape printed a finding: $out"
  pass "a listing shape the row scan cannot read is an error, not silence"
}

test_listing_without_a_count_is_an_error() {
  local listing out rc
  listing='tasks[1]{id,state,kind,repo,title,blocked_by,held}:
  abandoned,in_flight,ship,firstmate,Abandoned work,none,no'
  out=$(run_detector countless-listing "$listing" "done" abandoned 2>/dev/null)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a listing with no task count was parsed as authoritative"
  [ -z "$out" ] || fail "a listing with no task count printed a finding: $out"
  pass "a listing with no task count to check the parse against is an error"
}

test_empty_in_flight_listing_is_silent_success() {
  local listing out rc
  listing='count: 0
tasks: 0 in_flight tasks in this backlog'
  out=$(run_detector empty-listing "$listing")
  rc=$?
  [ "$rc" -eq 0 ] || fail "an empty in-flight listing failed instead of reporting no work"
  [ -z "$out" ] || fail "an empty in-flight listing printed a finding: $out"
  pass "an empty in-flight listing stays silent success"
}

test_unadvanceable_task_is_flagged
test_missing_meta_is_not_flagged
test_live_worker_is_not_flagged
test_held_task_is_not_flagged
test_dependency_edge_is_not_flagged
test_unknown_liveness_is_not_flagged
test_manual_backlog_backend_cannot_answer
test_incompatible_tasks_axi_cannot_answer
test_unreadable_listing_shape_is_an_error
test_listing_without_a_count_is_an_error
test_empty_in_flight_listing_is_silent_success
