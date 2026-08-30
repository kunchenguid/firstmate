#!/usr/bin/env bash
# tests/fm-work-loop.test.sh - parallel slot refill planning for section 7's work loop.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-capacity-lib.sh
. "$ROOT/bin/fm-capacity-lib.sh"

SCRIPT="$ROOT/bin/fm-work-loop.sh"
TMP_ROOT=$(fm_test_tmproot fm-work-loop)

setup_home() {
  local home=$1
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects/demo"
  printf '%s\n' '- [ ] alpha-one - Alpha one (repo: demo) (kind: ship)' > "$home/data/backlog.md"
}

write_ship_meta() {
  local home=$1 id=$2
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "kind=ship" \
    "harness=echo"
}

make_fake_tmux() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
cmd=${1:-}
shift || true
session=; fmt=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) shift ;;
    -t) session=${2%%:*}; shift 2 ;;
    -F) shift 2 ;;
    *) fmt=$1; shift ;;
  esac
done
dir=${FM_FAKE_TMUX_DIR:-}
case "$cmd" in
  list-windows)
    if [ -n "$dir" ] && [ -f "$dir/$session" ]; then
      cat "$dir/$session"
      exit 0
    fi
    printf "can't find session: %s\n" "$session" >&2
    exit 1
    ;;
  display-message)
    [ "$fmt" = '#{pane_current_command}' ] && printf 'claude\n'
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
}

set_live_windows() {
  local home=$1
  shift
  local id
  mkdir -p "$home/tmux"
  : > "$home/tmux/firstmate"
  for id in "$@"; do
    printf 'fm-%s\n' "$id" >> "$home/tmux/firstmate"
  done
}

install_fake_crew_state() {
  local fakebin=$1
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
case "$id" in
  live-a|live-b|live-c|live-d|live-e|alpha-one|busy-a|busy-b|busy-c|done-idle|validating-a)
    printf 'state: working · source: pane · harness busy\n'
    ;;
  validating-run)
    printf 'state: working · source: run-step · validating (running)\n'
    ;;
  card-a|card-b|done-live-busy)
    printf 'state: working · source: pane · harness busy\n'
    ;;
  done-a|done-b|done-c)
    printf 'state: done · source: status-log · crew finished\n'
    ;;
  *)
    printf 'state: unknown · source: none\n'
    ;;
esac
SH
  chmod +x "$fakebin/fm-crew-state.sh"
}

run_work_loop() {
  local home=$1
  shift
  local fakebin
  fakebin=$(fm_fakebin "$home")
  make_fake_tmux "$fakebin"
  install_fake_crew_state "$fakebin"
  PATH="$fakebin:${PATH:-/usr/bin:/bin}" FM_FAKE_TMUX_DIR="$home/tmux" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
  "$SCRIPT" "$@"
}

add_compatible_tasks_axi() {
  local home=$1
  mkdir -p "$home/bin"
  cat > "$home/bin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf '0.2.4\n'; exit 0 ;;
  update)
    [ "${2:-}" = --help ] && { printf 'usage: tasks-axi update <id> [--archive-body]\n'; exit 0; }
    ;;
  mv)
    [ "${2:-}" = --help ] && { printf 'usage: tasks-axi mv <dest> [<id>...]\n'; exit 0; }
    ;;
  ready)
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) shift 2 ;;
      *) shift ;;
    esac
  done
  printf 'count: 3\n'
  printf 'ready[3]{id,state,kind,repo,title}:\n'
  printf '  alpha-one,queued,ship,demo,Alpha one\n'
  printf '  alpha-two,queued,ship,demo,Alpha two\n'
  printf '  alpha-three,queued,ship,demo,Alpha three\n'
  printf 'ready_public_followups: 0 delivery-ready obligations\n'
  exit 0
  ;;
esac
exit 1
SH
  chmod +x "$home/bin/tasks-axi"
}

test_status_reports_measured_slots() {
  local home out
  home="$TMP_ROOT/status"
  setup_home "$home"
  out=$(FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    run_work_loop "$home" status)
  assert_contains "$out" 'FM_WORK_LOOP slots=5 occupied=0 free=5 real=0 min_real=3 shortfall=3 homes_scanned=1' \
    "status did not report measured slot budget and real-worker floor: $out"
  pass "fm-work-loop status reports measured slot budget"
}

test_plan_fills_up_to_free_slots() {
  local home out n
  home="$TMP_ROOT/plan-fill"
  setup_home "$home"
  add_compatible_tasks_axi "$home"
  write_ship_meta "$home" busy-a
  write_ship_meta "$home" busy-b
  write_ship_meta "$home" busy-c
  set_live_windows "$home" busy-a busy-b busy-c
  out=$(FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    PATH="$home/bin:$PATH" run_work_loop "$home" plan)
  n=$(printf '%s\n' "$out" | sed '/^$/d' | wc -l)
  [ "$n" -eq 2 ] || fail "expected 2 planned spawns with 3 real workers and 2 free slots, got $n: $out"
  pass "fm-work-loop plan lists every dispatchable id up to the free budget once the real floor is met"
}

test_plan_tops_up_below_real_floor() {
  local home out n
  home="$TMP_ROOT/plan-floor"
  setup_home "$home"
  add_compatible_tasks_axi "$home"
  write_ship_meta "$home" busy-a
  set_live_windows "$home" busy-a
  out=$(FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    PATH="$home/bin:$PATH" run_work_loop "$home" plan)
  n=$(printf '%s\n' "$out" | sed '/^$/d' | wc -l)
  [ "$n" -eq 2 ] || fail "expected 2 planned spawns to reach min_real=3, got $n: $out"
  pass "fm-work-loop plan tops up toward min_real when fewer than three workers are busy"
}

test_plan_ignores_idle_done_panes_for_real_floor() {
  local home out n
  home="$TMP_ROOT/plan-done-idle"
  setup_home "$home"
  add_compatible_tasks_axi "$home"
  write_ship_meta "$home" done-a
  write_ship_meta "$home" done-b
  write_ship_meta "$home" busy-a
  set_live_windows "$home" done-a done-b busy-a
  out=$(FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    PATH="$home/bin:$PATH" run_work_loop "$home" plan)
  n=$(printf '%s\n' "$out" | sed '/^$/d' | wc -l)
  [ "$n" -eq 2 ] || fail "idle done-panes should not count toward min_real; expected 2 spawns, got $n: $out"
  pass "fm-work-loop plan ignores idle done-panes when topping up the real-worker floor"
}

test_plan_ignores_live_done_panes_with_stale_busy_pane() {
  local home out n
  home="$TMP_ROOT/plan-done-live-busy"
  setup_home "$home"
  add_compatible_tasks_axi "$home"
  write_ship_meta "$home" done-live-busy
  write_ship_meta "$home" card-a
  write_ship_meta "$home" busy-a
  printf 'done: fertig · Tests 3/0\n' > "$home/state/done-live-busy.status"
  printf 'done: Karte idle · Tests 1/0\n' > "$home/state/card-a.status"
  set_live_windows "$home" done-live-busy card-a busy-a
  out=$(FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    PATH="$home/bin:$PATH" run_work_loop "$home" plan)
  n=$(printf '%s\n' "$out" | sed '/^$/d' | wc -l)
  [ "$n" -eq 2 ] || fail "stale busy panes after done: should not count; expected 2 spawns, got $n: $out"
  pass "fm-work-loop plan ignores done-panes whose endpoint still looks busy"
}

test_plan_counts_validating_run_step_despite_done_status_log() {
  local home out n
  home="$TMP_ROOT/plan-validating-run"
  setup_home "$home"
  add_compatible_tasks_axi "$home"
  write_ship_meta "$home" validating-run
  write_ship_meta "$home" card-a
  write_ship_meta "$home" card-b
  write_ship_meta "$home" busy-a
  printf 'done: alter Eintrag vor Validierung\n' > "$home/state/validating-run.status"
  printf 'done: Karte idle\n' > "$home/state/card-a.status"
  printf 'done: Karte idle\n' > "$home/state/card-b.status"
  printf 'done: schon fertig\n' > "$home/state/busy-a.status"
  set_live_windows "$home" validating-run card-a card-b busy-a
  out=$(FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    PATH="$home/bin:$PATH" run_work_loop "$home" plan)
  n=$(printf '%s\n' "$out" | sed '/^$/d' | wc -l)
  [ "$n" -eq 1 ] || fail "active run-step should count even with stale done status; expected 1 spawn, got $n: $out"
  pass "fm-work-loop plan still counts an active run-step over a stale done status line"
}

test_plan_skips_tasks_that_already_occupy_slots() {
  local home out
  home="$TMP_ROOT/plan-skip"
  setup_home "$home"
  add_compatible_tasks_axi "$home"
  write_ship_meta "$home" alpha-one
  set_live_windows "$home" alpha-one
  out=$(FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    PATH="$home/bin:$PATH" run_work_loop "$home" plan)
  assert_not_contains "$out" 'alpha-one' "plan should skip a task that already holds a live slot"
  assert_contains "$out" 'alpha-two' "plan should still offer other dispatchable tasks"
  pass "fm-work-loop plan skips ids that already occupy a live worker slot"
}

test_plan_prints_nothing_when_no_free_slots() {
  local home out rc
  home="$TMP_ROOT/plan-full"
  setup_home "$home"
  add_compatible_tasks_axi "$home"
  write_ship_meta "$home" live-a
  write_ship_meta "$home" live-b
  write_ship_meta "$home" live-c
  write_ship_meta "$home" live-d
  write_ship_meta "$home" live-e
  set_live_windows "$home" live-a live-b live-c live-d live-e
  out=$(FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    PATH="$home/bin:$PATH" run_work_loop "$home" plan)
  [ -z "$out" ] || fail "plan should be silent when free=0, got: $out"
  pass "fm-work-loop plan stays silent when every slot is occupied"
}

write_fixed_list() {
  local home=$1
  shift
  mkdir -p "$home/config"
  : > "$home/config/work-loop-list"
  while [ "$#" -gt 0 ]; do
    printf '%s\n' "$1" >> "$home/config/work-loop-list"
    shift
  done
}

test_status_reports_list_source_when_fixed_list_active() {
  local home out
  home="$TMP_ROOT/status-list"
  setup_home "$home"
  write_fixed_list "$home" alpha-one
  out=$(FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    run_work_loop "$home" status)
  assert_contains "$out" 'source=list' "status should name fixed-list source: $out"
  pass "fm-work-loop status reports source=list when a fixed list is active"
}

test_plan_uses_fixed_list_order() {
  local home out first second
  home="$TMP_ROOT/plan-list-order"
  setup_home "$home"
  add_compatible_tasks_axi "$home"
  write_fixed_list "$home" alpha-three alpha-one alpha-two
  out=$(FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    PATH="$home/bin:$PATH" run_work_loop "$home" plan)
  first=$(printf '%s\n' "$out" | sed -n '1p')
  second=$(printf '%s\n' "$out" | sed -n '2p')
  [ "$first" = alpha-three ] || fail "fixed list should preserve file order, first=$first"
  [ "$second" = alpha-one ] || fail "fixed list should preserve file order, second=$second"
  pass "fm-work-loop plan walks the fixed list in file order"
}

test_plan_fixed_list_skips_not_ready_ids() {
  local home out
  home="$TMP_ROOT/plan-list-skip"
  setup_home "$home"
  add_compatible_tasks_axi "$home"
  write_fixed_list "$home" alpha-missing alpha-two
  out=$(FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    PATH="$home/bin:$PATH" run_work_loop "$home" plan)
  assert_not_contains "$out" 'alpha-missing' "plan should skip list ids that are not ready"
  assert_contains "$out" 'alpha-two' "plan should still offer ready list ids"
  pass "fm-work-loop plan skips fixed-list ids that are not tasks-axi ready"
}

test_plan_fixed_list_skips_tasks_that_already_occupy_slots() {
  local home out
  home="$TMP_ROOT/plan-list-occupied"
  setup_home "$home"
  add_compatible_tasks_axi "$home"
  write_fixed_list "$home" alpha-one alpha-two alpha-three
  write_ship_meta "$home" alpha-one
  set_live_windows "$home" alpha-one
  out=$(FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    PATH="$home/bin:$PATH" run_work_loop "$home" plan)
  assert_not_contains "$out" 'alpha-one' "fixed-list plan should skip a task that already holds a live slot"
  assert_contains "$out" 'alpha-two' "fixed-list plan should still offer other ready list ids"
  pass "fm-work-loop fixed-list plan skips ids that already occupy a live worker slot"
}

add_empty_ready_tasks_axi() {
  local home=$1
  mkdir -p "$home/bin" "$home/state"
  cat > "$home/bin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf '0.2.4\n'; exit 0 ;;
  update)
    [ "${2:-}" = --help ] && { printf 'usage: tasks-axi update <id> [--archive-body]\n'; exit 0; }
    ;;
  mv)
    [ "${2:-}" = --help ] && { printf 'usage: tasks-axi mv <dest> [<id>...]\n'; exit 0; }
    ;;
  ready)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --file) shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -f "${FM_SUPPLY_READY_FILE:-}" ]; then
      cat "${FM_SUPPLY_READY_FILE}"
      exit 0
    fi
    printf 'count: 0\n'
    printf 'ready[0]{id,state,kind,repo,title}:\n'
    printf 'ready_public_followups: 0 delivery-ready obligations\n'
    exit 0
    ;;
  show)
    id=${2:-}
    shift 2 || true
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --file) shift 2 ;;
        *) shift ;;
      esac
    done
    case "$id" in
      alpha-done)
        printf 'task:\n  id: alpha-done\n  title: "Done task"\n  state: done\n'
        ;;
      alpha-live)
        printf 'task:\n  id: alpha-live\n  title: "Live task"\n  state: in_flight\n'
        ;;
      *)
        exit 1
        ;;
    esac
    exit 0
    ;;
  reopen)
    id=${2:-}
    shift 2 || true
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --file) shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$id" >> "${FM_SUPPLY_REOPEN_LOG:-/dev/null}"
    printf 'ready[1]{id,state,kind,repo,title}:\n' > "${FM_SUPPLY_READY_FILE:-}"
    printf '  %s,queued,ship,demo,Done task\n' "$id" >> "${FM_SUPPLY_READY_FILE:-}"
    exit 0
    ;;
  add)
    id=$2
    shift 2 || true
  title=; repo=; kind=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) repo=$2; shift 2 ;;
      --kind) kind=$2; shift 2 ;;
      --file) shift 2 ;;
      *) title=$1; shift ;;
    esac
  done
    printf '%s\t%s\t%s\t%s\n' "$id" "$repo" "$title" "$kind" >> "${FM_SUPPLY_ADD_LOG:-/dev/null}"
    printf 'ready[1]{id,state,kind,repo,title}:\n' > "${FM_SUPPLY_READY_FILE:-}"
    printf '  %s,queued,%s,%s,%s\n' "$id" "$kind" "$repo" "$title" >> "${FM_SUPPLY_READY_FILE:-}"
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$home/bin/tasks-axi"
}

test_supply_reopens_done_list_id_when_ready_queue_empty() {
  local home out log
  home="$TMP_ROOT/supply-reopen"
  setup_home "$home"
  add_empty_ready_tasks_axi "$home"
  write_fixed_list "$home" alpha-done
  log="$home/reopen.log"
  : > "$log"
  out=$(FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    FM_SUPPLY_REOPEN_LOG="$log" FM_SUPPLY_READY_FILE="$home/ready.txt" \
    PATH="$home/bin:$PATH" run_work_loop "$home" supply)
  assert_contains "$out" 'FM_WORK_LOOP supplied=alpha-done' "supply should report reopened id: $out"
  grep -F 'alpha-done' "$log" >/dev/null || fail "supply should reopen the done list id"
  pass "fm-work-loop supply reopens the next done fixed-list id when ready is empty"
}

test_plan_supplies_done_list_id_before_printing_candidates() {
  local home out
  home="$TMP_ROOT/plan-supply"
  setup_home "$home"
  add_empty_ready_tasks_axi "$home"
  write_fixed_list "$home" alpha-done
  out=$(FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    FM_SUPPLY_REOPEN_LOG="$home/reopen.log" FM_SUPPLY_READY_FILE="$home/ready.txt" \
    PATH="$home/bin:$PATH" run_work_loop "$home" plan)
  assert_contains "$out" 'alpha-done' "plan should offer a resupplied list id: $out"
  pass "fm-work-loop plan resupplies the next known id when ready is empty"
}

test_supply_adds_missing_spec_row_when_ready_queue_empty() {
  local home out log
  home="$TMP_ROOT/supply-add"
  setup_home "$home"
  add_empty_ready_tasks_axi "$home"
  write_fixed_list "$home" 'alpha-new'$'\t''demo'$'\t''New task'$'\t''ship'
  log="$home/add.log"
  : > "$log"
  out=$(FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    FM_SUPPLY_ADD_LOG="$log" FM_SUPPLY_READY_FILE="$home/ready.txt" \
    PATH="$home/bin:$PATH" run_work_loop "$home" supply)
  assert_contains "$out" 'FM_WORK_LOOP supplied=alpha-new' "supply should report added id: $out"
  grep -F $'alpha-new\tdemo\tNew task\tship' "$log" >/dev/null \
    || fail "supply should add the missing spec row"
  pass "fm-work-loop supply adds a missing tab-separated list row when ready is empty"
}

test_supply_skips_when_ready_queue_has_candidates() {
  local home out
  home="$TMP_ROOT/supply-skip-ready"
  setup_home "$home"
  add_compatible_tasks_axi "$home"
  write_fixed_list "$home" alpha-done
  out=$(FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    FM_SUPPLY_REOPEN_LOG="$home/reopen.log" \
    PATH="$home/bin:$PATH" run_work_loop "$home" supply)
  [ -z "$out" ] || fail "supply should stay silent while ready work remains: $out"
  pass "fm-work-loop supply does nothing while the ready queue still has candidates"
}

test_status_reports_measured_slots
test_plan_fills_up_to_free_slots
test_plan_tops_up_below_real_floor
test_plan_ignores_idle_done_panes_for_real_floor
test_plan_ignores_live_done_panes_with_stale_busy_pane
test_plan_counts_validating_run_step_despite_done_status_log
test_plan_skips_tasks_that_already_occupy_slots
test_plan_prints_nothing_when_no_free_slots
test_status_reports_list_source_when_fixed_list_active
test_plan_uses_fixed_list_order
test_plan_fixed_list_skips_not_ready_ids
test_plan_fixed_list_skips_tasks_that_already_occupy_slots
test_supply_reopens_done_list_id_when_ready_queue_empty
test_plan_supplies_done_list_id_before_printing_candidates
test_supply_adds_missing_spec_row_when_ready_queue_empty
test_supply_skips_when_ready_queue_has_candidates
