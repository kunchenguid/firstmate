#!/usr/bin/env bash
# Behavior tests for resource-aware parallel dispatch: slot formula, live
# host-scoped occupancy, same-task uniqueness, refuse-rather-than-kill spawn
# gating, and preferred-then-fallback host routing from fresh probes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-capacity-lib.sh
. "$ROOT/bin/fm-capacity-lib.sh"

SCRIPT="$ROOT/bin/fm-capacity.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-capacity)

setup_home() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/config" "$dir/data" "$dir/projects/demo"
}

run_capacity() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="" \
    FM_STATE_OVERRIDE="" FM_CONFIG_OVERRIDE="" \
    "$SCRIPT" "$@"
}

write_ship_meta() {
  local home=$1 id=$2
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "kind=ship" \
    "harness=echo"
}

# A ship record on a backend that has no recovery classifier (zellij, orca and
# cmux always report `unverified`), which is exactly where endpoint liveness
# can never be proven negative.
write_unverified_ship_meta() {
  local home=$1 id=$2 backend=${3:-zellij}
  fm_write_meta "$home/state/$id.meta" \
    "window=fm-$id" \
    "endpoint_task_id=$id" \
    "kind=ship" \
    "backend=$backend" \
    "harness=echo"
}

# Append one line to a task's append-only status log.
write_status() {
  local home=$1 id=$2 line=$3
  printf '%s\n' "$line" >> "$home/state/$id.status"
}

# A tmux stand-in whose session window list is the fixture: a task whose window
# is listed has a live agent pane, a task whose window is absent is an
# authoritatively gone endpoint. That is exactly the distinction the capacity
# budget must draw between a running worker and a parked record.
make_fake_tmux() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_CAPACITY_PROBE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_CAPACITY_PROBE_LOG"
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

# Declare which task windows are live in the fake tmux session for <home>.
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

# Run <home>'s capacity CLI with the fake tmux answering endpoint liveness.
run_capacity_live() {
  local home=$1
  shift
  local fakebin
  fakebin=$(fm_fakebin "$home")
  make_fake_tmux "$fakebin"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_DIR="$home/tmux" \
    run_capacity "$home" "$@"
}

make_fake_ssh() {
  local fakebin=$1
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
host=${1:-}
shift || true
dir=${FM_FAKE_SSH_DIR:-}
if [ -n "$dir" ] && [ -f "$dir/$host" ]; then
  cat "$dir/$host"
  exit 0
fi
exit 255
SH
  chmod +x "$fakebin/ssh"
}

test_slots_allow_five_on_healthy_supervisor() {
  local got
  got=$(fm_capacity_slots_from_local 16 24576 0.4)
  [ "$got" = 5 ] || fail "healthy 16-CPU/24GiB host should yield 5 slots, got $got"
  pass "healthy supervisor measurements yield five worker slots"
}

test_slots_drop_to_zero_when_load_saturates() {
  local got
  got=$(fm_capacity_slots_from_local 16 24576 16)
  [ "$got" = 0 ] || fail "load1==nproc should yield 0 slots, got $got"
  pass "saturated load yields zero new slots"
}

test_slots_drop_when_ram_is_tight() {
  local got
  got=$(fm_capacity_slots_from_local 16 4096 0.4)
  [ "$got" = 0 ] || fail "mem at the reserve floor should yield 0 slots, got $got"
  got=$(fm_capacity_slots_from_local 16 7168 0.4)
  [ "$got" = 1 ] || fail "one RAM slot of headroom should yield 1, got $got"
  pass "RAM axis cuts slots without a hardcoded agent count"
}

test_slots_small_host_keeps_one_when_healthy() {
  local got
  got=$(fm_capacity_slots_from_local 2 24576 0.2)
  [ "$got" = 1 ] || fail "healthy 2-CPU host should keep 1 slot, got $got"
  pass "small healthy hosts keep a single slot rather than a rigid zero"
}

test_slots_high_but_not_full_load_caps_at_one() {
  local got
  got=$(fm_capacity_slots_from_local 16 24576 11.2)
  [ "$got" = 1 ] || fail "70 percent load should cap at 1 slot, got $got"
  pass "elevated load caps new parallelism at one"
}

test_occupied_counts_ship_and_scout_not_secondmates() {
  local home n
  home="$TMP_ROOT/occupied"
  setup_home "$home"
  write_ship_meta "$home" ship-a1
  write_ship_meta "$home" ship-b2
  fm_write_meta "$home/state/scout-c3.meta" kind=scout window=firstmate:fm-scout-c3
  fm_write_secondmate_meta "$home/state/jarvis.meta" "$home/jarvis-home"
  set_live_windows "$home" ship-a1 ship-b2 scout-c3 jarvis
  n=$(run_capacity_live "$home" slots | sed -n 's/^occupied=//p')
  [ "$n" = 3 ] || fail "occupied should count 2 ship + 1 scout, not the secondmate; got $n"
  pass "occupied slots are live ship and scout workers, not idle secondmates"
}

test_parked_task_without_a_live_worker_frees_its_slot() {
  local home out rc i
  home="$TMP_ROOT/parked"
  setup_home "$home"
  for i in 1 2 3 4 5; do
    write_ship_meta "$home" "occ-$i"
  done
  # occ-1 and occ-2 still run; the other three are parked records whose panes
  # are gone (captain hold, merge wait, exited pane).
  set_live_windows "$home" occ-1 occ-2
  out=$(
    FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
      run_capacity_live "$home" slots
  )
  assert_contains "$out" "occupied=2" "only live workers hold slots"
  assert_contains "$out" "free=3" "parked records must not consume the budget"
  set +e
  FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    run_capacity_live "$home" spawn-gate --task-id fresh-x7 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "spawn-gate with parked records only"
  [ -f "$home/state/occ-5.meta" ] || fail "a parked record must survive as a durable record"
  pass "parked tasks with no running worker do not block fresh dispatch"
}

test_live_workers_in_a_local_secondmate_home_share_the_host_budget() {
  local home mate out rc i
  home="$TMP_ROOT/host-budget"
  mate="$TMP_ROOT/host-budget/jarvis-home"
  setup_home "$home"
  setup_home "$mate"
  printf -- '- jarvis - platform work (home: %s; scope: platform work; projects: alpha; added 2026-08-27)\n' \
    "$mate" > "$home/data/secondmates.md"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$home" \
    > "$mate/.fm-secondmate-parent"
  write_ship_meta "$home" prim-a1
  for i in 1 2 3 4; do
    write_ship_meta "$mate" "mate-$i"
  done
  set_live_windows "$home" prim-a1 mate-1 mate-2 mate-3 mate-4
  cp -R "$home/tmux" "$mate/tmux"
  set +e
  out=$(
    FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
      run_capacity_live "$home" spawn-gate --task-id extra-p6 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "host-wide budget from the primary home"
  assert_contains "$out" "occupied=5" "the primary home must see the secondmate home's live workers"
  assert_contains "$out" "homes_scanned=2" "the measurement must name how many homes it counted"
  set +e
  out=$(
    FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
      run_capacity_live "$mate" spawn-gate --task-id extra-m6 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "host-wide budget from the secondmate home"
  assert_contains "$out" "occupied=5" "a secondmate home must not take a second independent budget"
  pass "local firstmate homes share one measured budget for this host"
}

test_same_task_refuses_a_second_concurrent_worker() {
  local home out rc
  home="$TMP_ROOT/same-task"
  setup_home "$home"
  write_ship_meta "$home" live-task-a1
  set_live_windows "$home" live-task-a1
  set +e
  out=$(run_capacity_live "$home" spawn-gate --task-id live-task-a1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "same-task spawn-gate"
  assert_contains "$out" "already has a worker" "same-task refuse must name the duplicate worker"
  pass "spawn-gate refuses a second worker on the same task"
}

test_full_budget_refuses_without_touching_running_workers() {
  local home before after out rc i
  home="$TMP_ROOT/full-budget"
  setup_home "$home"
  for i in 1 2 3 4 5; do
    write_ship_meta "$home" "occ-$i"
  done
  set_live_windows "$home" occ-1 occ-2 occ-3 occ-4 occ-5
  before=$(cat "$home/state/occ-1.meta" "$home/state/occ-2.meta" "$home/state/occ-3.meta" \
    "$home/state/occ-4.meta" "$home/state/occ-5.meta")
  set +e
  out=$(
    FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
      run_capacity_live "$home" spawn-gate --task-id extra-w6 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "full-budget spawn-gate"
  assert_contains "$out" "no free worker slot" "full budget must refuse a new independent worker"
  assert_contains "$out" "left running" "refuse path must leave running workers running"
  after=$(cat "$home/state/occ-1.meta" "$home/state/occ-2.meta" "$home/state/occ-3.meta" \
    "$home/state/occ-4.meta" "$home/state/occ-5.meta")
  [ "$before" = "$after" ] || fail "occupied worker records changed during a capacity refuse"
  pass "full slot budget refuses a new worker and leaves running workers untouched"
}

test_free_slot_allows_a_new_independent_worker() {
  local home rc
  home="$TMP_ROOT/free-slot"
  setup_home "$home"
  write_ship_meta "$home" occ-a1
  write_ship_meta "$home" occ-b2
  set +e
  FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    run_capacity "$home" spawn-gate --task-id extra-c3 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "free-slot spawn-gate"
  pass "a new independent worker is allowed while free slots remain"
}

test_relaunch_and_secondmate_skip_the_slot_budget() {
  local home rc
  # These names are exported by tests/lib.sh, so a saturating value assigned
  # here would otherwise stay in the environment of every later test.
  local was_nproc=$FM_CAPACITY_NPROC
  local was_mem=$FM_CAPACITY_MEM_AVAIL_MB
  local was_load=$FM_CAPACITY_LOAD1
  home="$TMP_ROOT/skip-kinds"
  setup_home "$home"
  write_ship_meta "$home" occ-a1
  FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=4096 FM_CAPACITY_LOAD1=16
  fm_capacity_measure_local "$home/state" "$home"
  FM_CAPACITY_NPROC=$was_nproc
  FM_CAPACITY_MEM_AVAIL_MB=$was_mem
  FM_CAPACITY_LOAD1=$was_load
  [ "$FM_CAPACITY_SLOTS" = 0 ] || fail "preload should force slots=0, got $FM_CAPACITY_SLOTS"
  set +e
  fm_capacity_allow_new_worker "$home/state" new-b2 ship 1 "$home"
  rc=$?
  set -e
  expect_code 0 "$rc" "relaunch skip"
  set +e
  fm_capacity_allow_new_worker "$home/state" mate-c3 secondmate 0 "$home"
  rc=$?
  set -e
  expect_code 0 "$rc" "secondmate skip"
  pass "relaunch and secondmate spawns skip the independent-worker slot budget"
}

test_cli_slots_print_measured_budget() {
  local home out
  home="$TMP_ROOT/cli-slots"
  setup_home "$home"
  write_ship_meta "$home" occ-a1
  set_live_windows "$home" occ-a1
  out=$(
    FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
      run_capacity_live "$home" slots
  )
  assert_contains "$out" "slots=5" "slots line"
  assert_contains "$out" "occupied=1" "occupied line"
  assert_contains "$out" "free=4" "free line"
  assert_contains "$out" "homes_scanned=1" "homes scanned line"
  pass "slots command prints measured slots, live occupancy, free, and homes scanned"
}

test_preferred_gpu_host_wins_when_freshly_suitable() {
  local home fakebin out
  home="$TMP_ROOT/route-pref"
  setup_home "$home"
  fakebin=$(fm_fakebin "$home")
  make_fake_ssh "$fakebin"
  mkdir -p "$home/ssh"
  cat > "$home/ssh/Valentino" <<'OUT'
FM_CAP nproc=24
FM_CAP mem_avail_mb=32000
FM_CAP load1=2.0
FM_CAP gpu=8192,10
OUT
  cat > "$home/ssh/Valentino-Arbeit" <<'OUT'
FM_CAP nproc=16
FM_CAP mem_avail_mb=16000
FM_CAP load1=1.0
FM_CAP gpu=
OUT
  printf '%s\n' '{"preferred":{"ssh":"Valentino","kind":"gpu"},"fallback":{"ssh":"Valentino-Arbeit","kind":"cpu"}}' \
    > "$home/config/compute-hosts.json"
  out=$(
    PATH="$fakebin:$PATH" FM_CAPACITY_SKIP_REMOTE='' \
      FM_FAKE_SSH_DIR="$home/ssh" \
      run_capacity "$home" route
  )
  assert_contains "$out" "route=preferred" "preferred route"
  assert_contains "$out" "route_host=Valentino" "preferred host"
  assert_contains "$out" "preferred_reachable=yes" "preferred reachable"
  assert_contains "$out" "preferred_suitable=yes" "preferred suitable"
  pass "reachable suitable Heim-PC GPU host is preferred"
}

test_fallback_used_when_preferred_is_unsuitable() {
  local home fakebin out
  home="$TMP_ROOT/route-fall"
  setup_home "$home"
  fakebin=$(fm_fakebin "$home")
  make_fake_ssh "$fakebin"
  mkdir -p "$home/ssh"
  cat > "$home/ssh/Valentino" <<'OUT'
FM_CAP nproc=24
FM_CAP mem_avail_mb=32000
FM_CAP load1=2.0
FM_CAP gpu=512,95
OUT
  cat > "$home/ssh/Valentino-Arbeit" <<'OUT'
FM_CAP nproc=16
FM_CAP mem_avail_mb=16000
FM_CAP load1=1.0
FM_CAP gpu=
OUT
  printf '%s\n' '{"preferred":{"ssh":"Valentino","kind":"gpu"},"fallback":{"ssh":"Valentino-Arbeit","kind":"cpu"}}' \
    > "$home/config/compute-hosts.json"
  out=$(
    PATH="$fakebin:$PATH" FM_CAPACITY_SKIP_REMOTE='' \
      FM_FAKE_SSH_DIR="$home/ssh" \
      run_capacity "$home" route
  )
  assert_contains "$out" "route=fallback" "fallback route"
  assert_contains "$out" "route_host=Valentino-Arbeit" "fallback host"
  assert_contains "$out" "preferred_reachable=yes" "preferred still reachable"
  assert_contains "$out" "preferred_suitable=no" "preferred unsuitable GPU"
  pass "Arbeits-PC is the fallback when the Heim-PC GPU is not suitable"
}

test_no_route_when_both_hosts_are_down() {
  local home fakebin out
  home="$TMP_ROOT/route-none"
  setup_home "$home"
  fakebin=$(fm_fakebin "$home")
  make_fake_ssh "$fakebin"
  mkdir -p "$home/ssh"
  printf '%s\n' '{"preferred":{"ssh":"Valentino","kind":"gpu"},"fallback":{"ssh":"Valentino-Arbeit","kind":"cpu"}}' \
    > "$home/config/compute-hosts.json"
  out=$(
    PATH="$fakebin:$PATH" FM_CAPACITY_SKIP_REMOTE='' \
      FM_FAKE_SSH_DIR="$home/ssh" \
      run_capacity "$home" route
  )
  assert_contains "$out" "route=none" "no route onto the supervisor"
  assert_not_contains "$out" "route_host=Valentino" "must not claim a down preferred host"
  pass "host-bound work is not piled onto the supervisor when both remotes fail"
}

test_preferred_pin_keeps_the_configured_fallback() {
  local home fakebin out
  home="$TMP_ROOT/route-pin-merge"
  setup_home "$home"
  fakebin=$(fm_fakebin "$home")
  make_fake_ssh "$fakebin"
  mkdir -p "$home/ssh"
  # Heim-PC is down; only the configured Arbeits-PC answers.
  cat > "$home/ssh/Valentino-Arbeit" <<'OUT'
FM_CAP nproc=16
FM_CAP mem_avail_mb=16000
FM_CAP load1=1.0
FM_CAP gpu=
OUT
  printf '%s\n' '{"preferred":{"ssh":"Valentino","kind":"gpu"},"fallback":{"ssh":"Valentino-Arbeit","kind":"cpu"}}' \
    > "$home/config/compute-hosts.json"
  out=$(
    PATH="$fakebin:$PATH" FM_CAPACITY_SKIP_REMOTE='' \
      FM_FAKE_SSH_DIR="$home/ssh" \
      run_capacity "$home" route --preferred Valentino
  )
  assert_contains "$out" "route=fallback" "a preferred-only pin must keep the configured fallback"
  assert_contains "$out" "route_host=Valentino-Arbeit" "fallback host survives the pin"
  assert_contains "$out" "fallback_ssh=Valentino-Arbeit" "the configured fallback is still loaded"
  pass "pinning only the preferred host preserves the configured Arbeits-PC fallback"
}

test_invalid_pinned_kind_is_rejected() {
  local home out rc
  home="$TMP_ROOT/route-bad-kind"
  setup_home "$home"
  set +e
  out=$(run_capacity "$home" route --preferred Valentino-Arbeit --preferred-kind CPU 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "invalid pinned kind"
  assert_contains "$out" "must be gpu or cpu" "an unknown pinned kind must be reported, not coerced"
  assert_not_contains "$out" "preferred_suitable" "a rejected pin must not produce a routing verdict"
  pass "an unknown pinned host kind is rejected instead of silently coerced"
}

test_spawn_refuses_at_capacity_without_launching() {
  local home fakebin out rc id=cap-new-z9
  home="$TMP_ROOT/spawn-refuse"
  setup_home "$home"
  write_ship_meta "$home" occ-a1
  write_ship_meta "$home" occ-b2
  fakebin=$(fm_fakebin "$home")
  make_fake_tmux "$fakebin"
  set_live_windows "$home" occ-a1 occ-b2
  mkdir -p "$home/data/$id"
  printf 'Delivery contract: mode=no-mistakes\n' > "$home/data/$id/brief.md"
  set +e
  out=$(
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_DIR="$home/tmux" \
      FM_CAPACITY_NPROC=6 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.2 \
      FM_HOME="$home" FM_ROOT_OVERRIDE="" \
      FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
      "$SPAWN" "$id" projects/demo --mode no-mistakes --yolo off 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "spawn at capacity"
  assert_contains "$out" "error: capacity:" "spawn must refuse through the capacity gate"
  assert_not_contains "$out" "spawned $id" "spawn must not report a launch"
  pass "fm-spawn refuses a new independent worker when no slot remains"
}

test_gpu_suitability_requires_headroom() {
  fm_capacity_host_suitable gpu 24 32000 2.0 8192 10 \
    || fail "healthy GPU host should be suitable"
  fm_capacity_host_suitable gpu 24 32000 2.0 512 10 \
    && fail "low VRAM should be unsuitable"
  fm_capacity_host_suitable gpu 24 32000 2.0 8192 95 \
    && fail "high GPU util should be unsuitable"
  fm_capacity_host_suitable gpu 24 32000 48.0 8192 10 \
    && fail "free VRAM behind a pinned CPU should be unsuitable"
  fm_capacity_host_suitable gpu 24 256 2.0 8192 10 \
    && fail "free VRAM with no usable RAM should be unsuitable"
  fm_capacity_host_suitable gpu 24 0 0 8192 10 \
    && fail "an unmeasurable host reporting mem=0 load=0 must not read as idle"
  fm_capacity_host_suitable cpu 16 16000 1.0 "" "" \
    || fail "healthy CPU host should be suitable"
  fm_capacity_host_suitable cpu 16 16000 16.0 0 0 \
    && fail "saturated CPU host should be unsuitable"
  pass "gpu and cpu suitability follow measured headroom"
}

test_unverified_backend_releases_finished_records_but_not_active_work() {
  local home out rc i
  home="$TMP_ROOT/unverified-backend"
  setup_home "$home"
  for i in 1 2 3 4 5; do
    write_unverified_ship_meta "$home" "occ-$i"
  done
  # occ-1 is still working and occ-2 has not declared anything yet (a worker one
  # second after launch); the other three are finished or held. Nothing on this
  # backend can be proven dead, so the declared state is the only evidence.
  write_status "$home" occ-1 'working: implementing the parser'
  write_status "$home" occ-3 'done: merged in PR 42'
  write_status "$home" occ-4 'needs-decision: which schema wins?'
  write_status "$home" occ-5 'paused: waiting on the upstream release'
  out=$(
    FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
      run_capacity "$home" slots
  )
  assert_contains "$out" "occupied=2" \
    "only actively working and not-yet-declared work may hold a slot on an unverifiable backend"
  assert_contains "$out" "free=3" \
    "done, needs-decision and paused records must not permanently consume the budget"
  set +e
  FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    run_capacity "$home" spawn-gate --task-id fresh-u7 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "spawn-gate on a backend whose liveness is unverifiable"
  [ -f "$home/state/occ-3.meta" ] || fail "a released record must survive as a durable record"
  pass "finished work on an unverifiable backend releases its slot while active work keeps it"
}

test_live_worker_keeps_its_slot_despite_a_finished_status_line() {
  local home out
  home="$TMP_ROOT/live-beats-log"
  setup_home "$home"
  write_ship_meta "$home" occ-a1
  set_live_windows "$home" occ-a1
  # The append-only log is an EVENT history: a done line can precede more work.
  # A positively live worker is never freed on the strength of that line.
  write_status "$home" occ-a1 'done: first slice shipped'
  out=$(
    FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
      run_capacity_live "$home" slots
  )
  assert_contains "$out" "occupied=1" "a positively live worker must never be freed"
  pass "a running worker keeps its slot even after a terminal status line"
}

test_uniqueness_refuses_reusing_a_live_secondmate_id() {
  local home out rc
  home="$TMP_ROOT/secondmate-id"
  setup_home "$home"
  fm_write_secondmate_meta "$home/state/jarvis.meta" "$home/jarvis-home"
  set +e
  out=$(run_capacity "$home" spawn-gate --task-id jarvis 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "spawn-gate on an id a secondmate already owns"
  assert_contains "$out" "secondmate record" \
    "the refusal must name the record a fresh worker would have overwritten"
  pass "a fresh ship or scout may not reuse a live secondmate's task id"
}

test_home_paths_are_deduplicated_by_canonical_path() {
  local home mate out i
  home="$TMP_ROOT/canonical"
  mate="$TMP_ROOT/canonical/jarvis-home"
  setup_home "$home"
  setup_home "$mate"
  printf -- '- jarvis - platform work (home: %s; scope: platform work; projects: alpha; added 2026-08-27)\n' \
    "$mate" > "$home/data/secondmates.md"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$home" \
    > "$mate/.fm-secondmate-parent"
  write_ship_meta "$home" prim-a1
  for i in 1 2; do
    write_ship_meta "$mate" "mate-$i"
  done
  set_live_windows "$home" prim-a1 mate-1 mate-2
  cp -R "$home/tmux" "$mate/tmux"
  # FM_HOME spelled with a trailing slash: the registry records the same home
  # without one, so a raw string dedupe counts this home's workers twice.
  out=$(
    FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
      run_capacity_live "$mate/" slots
  )
  assert_contains "$out" "homes_scanned=2" \
    "one home spelled two ways is still one home"
  assert_contains "$out" "occupied=3" \
    "a non-canonical FM_HOME must not double-count its own live workers"
  assert_contains "$out" "free=2" "the inflated count must not eat free slots"
  pass "host homes are deduplicated by canonical path, not by spelling"
}

test_legacy_terminal_line_releases_a_slot_on_an_unverifiable_backend() {
  local home out rc
  home="$TMP_ROOT/legacy-terminal"
  setup_home "$home"
  write_unverified_ship_meta "$home" occ-a1
  write_unverified_ship_meta "$home" occ-b2
  write_unverified_ship_meta "$home" occ-c3
  # Legacy lines that carry no leading verb at all. bin/fm-classify-lib.sh owns
  # this vocabulary; nothing on this backend can ever be proven dead, so a line
  # it reads as captain-relevant must release the slot too.
  write_status "$home" occ-a1 'PR ready for review, captain: https://example.test/pull/42'
  write_status "$home" occ-b2 'merged'
  write_status "$home" occ-c3 'working: still building the parser'
  out=$(
    FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
      run_capacity "$home" slots
  )
  assert_contains "$out" "occupied=1" \
    "a bare legacy terminal line must not pin a slot forever"
  assert_contains "$out" "free=4" "released legacy records must return their slots"
  set +e
  FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    run_capacity "$home" spawn-gate --task-id fresh-l9 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "spawn-gate behind bare legacy terminal lines"
  pass "legacy terminal status lines release their slot on an unverifiable backend"
}

test_percentage_load_is_averaged_across_probe_samples() {
  local got
  # One ~1s burst inside an otherwise idle window must not read as a pinned
  # host: the mean of every sample is the measurement, not the last sample.
  fm_capacity_absorb_probe_text 'FM_CAP nproc=24
FM_CAP mem_avail_mb=32000
FM_CAP load_pct=10
FM_CAP load_pct=10
FM_CAP load_pct=100
FM_CAP gpu=8192,10' || fail "a multi-sample Windows probe transcript should absorb"
  [ "$FM_CAPACITY_PROBE_LOAD_SAMPLES" = 3 ] \
    || fail "every load_pct sample must count, got $FM_CAPACITY_PROBE_LOAD_SAMPLES"
  [ "$FM_CAPACITY_PROBE_LOAD_PCT" = "40.00" ] \
    || fail "the mean of 10/10/100 should be 40.00, got $FM_CAPACITY_PROBE_LOAD_PCT"
  [ -z "$FM_CAPACITY_PROBE_LOAD1" ] \
    || fail "a percentage host reports no run-queue load1, got $FM_CAPACITY_PROBE_LOAD1"
  got=$(fm_capacity_cpu_headroom_reading)
  [ "$got" = "busy_pct=40.00/samples=3" ] \
    || fail "the route report must name the averaged reading, got $got"
  fm_capacity_host_suitable gpu 24 32000 "" 8192 10 "$FM_CAPACITY_PROBE_LOAD_PCT" \
    || fail "a one-second burst must not demote a healthy preferred GPU host"
  # A host sitting near 100% in every sample is a sustained overload. Rescaled
  # into a load1 it would be 23.84, still below nproc, so the percentage itself
  # has to be the gate or a pinned machine walks straight through.
  fm_capacity_absorb_probe_text 'FM_CAP nproc=24
FM_CAP mem_avail_mb=32000
FM_CAP load_pct=100
FM_CAP load_pct=98
FM_CAP load_pct=100
FM_CAP gpu=8192,10' || fail "a pinned Windows probe transcript should absorb"
  fm_capacity_host_suitable gpu 24 32000 "" 8192 10 "$FM_CAPACITY_PROBE_LOAD_PCT" \
    && fail "a sustained pin must still fail the CPU-headroom gate"
  # A real run-queue load average keeps its own gate: no percentage, no change.
  fm_capacity_host_suitable cpu 16 16000 1.0 "" "" \
    || fail "a loadavg host must still be judged on load1"
  fm_capacity_host_suitable cpu 16 16000 16.0 "" "" \
    && fail "a saturated loadavg host must still be refused"
  pass "a percentage-derived load is averaged and gated as a percentage"
}

test_burst_on_the_preferred_windows_host_keeps_heim_preference() {
  local home fakebin out
  home="$TMP_ROOT/route-win-burst"
  setup_home "$home"
  fakebin=$(fm_fakebin "$home")
  make_fake_ssh "$fakebin"
  mkdir -p "$home/ssh"
  # The Heim-PC reports no load1 at all (Windows), just busy-percent samples.
  # The burst lands on the LAST sample, which is what a last-sample-wins read
  # would hand to the gate.
  cat > "$home/ssh/Valentino" <<'OUT'
FM_CAP nproc=24
FM_CAP mem_avail_mb=32000
FM_CAP gpu=8192,10
FM_CAP load_pct=12
FM_CAP load_pct=8
FM_CAP load_pct=100
OUT
  cat > "$home/ssh/Valentino-Arbeit" <<'OUT'
FM_CAP nproc=16
FM_CAP mem_avail_mb=16000
FM_CAP load1=1.0
FM_CAP gpu=
OUT
  printf '%s\n' '{"preferred":{"ssh":"Valentino","kind":"gpu"},"fallback":{"ssh":"Valentino-Arbeit","kind":"cpu"}}' \
    > "$home/config/compute-hosts.json"
  out=$(
    PATH="$fakebin:$PATH" FM_CAPACITY_SKIP_REMOTE='' \
      FM_FAKE_SSH_DIR="$home/ssh" \
      run_capacity "$home" route
  )
  assert_contains "$out" "route=preferred" \
    "a single burst sample must not force the Arbeits-PC"
  assert_contains "$out" "route_host=Valentino" "the Heim-PC keeps the route"
  pass "a transient burst on the Windows Heim-PC does not invert the routing preference"
}

test_sustained_windows_pin_falls_through_to_the_fallback() {
  local home fakebin out
  home="$TMP_ROOT/route-win-pinned"
  setup_home "$home"
  fakebin=$(fm_fakebin "$home")
  make_fake_ssh "$fakebin"
  mkdir -p "$home/ssh"
  cat > "$home/ssh/Valentino" <<'OUT'
FM_CAP nproc=24
FM_CAP mem_avail_mb=32000
FM_CAP gpu=8192,10
FM_CAP load_pct=100
FM_CAP load_pct=100
FM_CAP load_pct=99
OUT
  cat > "$home/ssh/Valentino-Arbeit" <<'OUT'
FM_CAP nproc=16
FM_CAP mem_avail_mb=16000
FM_CAP load1=1.0
FM_CAP gpu=
OUT
  printf '%s\n' '{"preferred":{"ssh":"Valentino","kind":"gpu"},"fallback":{"ssh":"Valentino-Arbeit","kind":"cpu"}}' \
    > "$home/config/compute-hosts.json"
  out=$(
    PATH="$fakebin:$PATH" FM_CAPACITY_SKIP_REMOTE='' \
      FM_FAKE_SSH_DIR="$home/ssh" \
      run_capacity "$home" route
  )
  assert_contains "$out" "route=fallback" "a sustained pin must still yield to the fallback"
  assert_contains "$out" "preferred_suitable=no" "the overload gate must still fire"
  pass "a sustained pin on the Windows Heim-PC still routes host-bound work to the Arbeits-PC"
}

test_duplicate_id_refuses_without_measuring_the_host() {
  local home fakebin out rc i
  home="$TMP_ROOT/identity-first"
  setup_home "$home"
  for i in 1 2 3; do
    write_ship_meta "$home" "occ-$i"
  done
  fakebin=$(fm_fakebin "$home")
  make_fake_tmux "$fakebin"
  set_live_windows "$home" occ-1 occ-2 occ-3
  : > "$home/probe.log"
  # Every liveness read costs backend subprocesses. An id collision is decided
  # from the colliding record alone, so refusing it must not walk the host-wide
  # occupancy scan and probe every other task's endpoint.
  set +e
  out=$(
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_DIR="$home/tmux" \
      FM_CAPACITY_PROBE_LOG="$home/probe.log" \
      FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
      run_capacity "$home" spawn-gate --task-id occ-2 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "duplicate-id spawn-gate"
  assert_contains "$out" "already has a worker" "the identity refusal must still name the duplicate"
  grep -q -- "fm-occ-1" "$home/probe.log" \
    && fail "an identity refusal must not probe an unrelated task's endpoint"
  grep -q -- "fm-occ-3" "$home/probe.log" \
    && fail "an identity refusal must not probe an unrelated task's endpoint"
  # The same gate on a free id does measure, so the fixture really can record
  # the reads the identity refusal skipped.
  set +e
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_DIR="$home/tmux" \
    FM_CAPACITY_PROBE_LOG="$home/probe.log" \
    FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    run_capacity "$home" spawn-gate --task-id fresh-i8 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "free-id spawn-gate"
  grep -q -- "fm-occ-1" "$home/probe.log" \
    || fail "the occupancy scan should have probed every recorded endpoint"
  grep -q -- "fm-occ-3" "$home/probe.log" \
    || fail "the occupancy scan should have probed every recorded endpoint"
  pass "a duplicate id is refused without the host-wide occupancy scan"
}

test_unmeasurable_windows_cpu_is_not_read_as_idle() {
  local got
  # Win32_Processor unavailable while the OS class answers: the probe emits no
  # load_pct line at all rather than a fabricated 0%.
  fm_capacity_absorb_probe_text 'FM_CAP nproc=24
FM_CAP mem_avail_mb=32000
FM_CAP gpu=8192,10' || fail "a transcript with no CPU sample should still absorb"
  [ "$FM_CAPACITY_PROBE_LOAD_SAMPLES" = 0 ] \
    || fail "no CPU sample means no samples, got $FM_CAPACITY_PROBE_LOAD_SAMPLES"
  [ -z "$FM_CAPACITY_PROBE_LOAD_PCT" ] \
    || fail "an absent CPU reading must not become a percentage, got $FM_CAPACITY_PROBE_LOAD_PCT"
  got=$(fm_capacity_cpu_headroom_reading)
  [ "$got" = unmeasured ] || fail "the route report must say unmeasured, got $got"
  fm_capacity_host_suitable gpu 24 32000 "$FM_CAPACITY_PROBE_LOAD1" 8192 10 \
    "$FM_CAPACITY_PROBE_LOAD_PCT" \
    && fail "a host whose CPU was never measured must be unsuitable, not idle"
  # A zero that the host genuinely measured is still a real reading.
  fm_capacity_absorb_probe_text 'FM_CAP nproc=24
FM_CAP mem_avail_mb=32000
FM_CAP load_pct=0
FM_CAP gpu=8192,10' || fail "a genuinely idle transcript should absorb"
  fm_capacity_host_suitable gpu 24 32000 "" 8192 10 "$FM_CAPACITY_PROBE_LOAD_PCT" \
    || fail "a measured idle host must stay suitable"
  pass "an unreadable Windows CPU counter reads as unmeasurable, never as idle"
}

test_unmeasurable_preferred_host_falls_through_to_the_fallback() {
  local home fakebin out
  home="$TMP_ROOT/route-win-unmeasured"
  setup_home "$home"
  fakebin=$(fm_fakebin "$home")
  make_fake_ssh "$fakebin"
  mkdir -p "$home/ssh"
  # Reachable, plenty of RAM and VRAM, but the CPU counter answered nothing.
  cat > "$home/ssh/Valentino" <<'OUT'
FM_CAP nproc=24
FM_CAP mem_avail_mb=32000
FM_CAP gpu=8192,10
OUT
  cat > "$home/ssh/Valentino-Arbeit" <<'OUT'
FM_CAP nproc=16
FM_CAP mem_avail_mb=16000
FM_CAP load1=1.0
FM_CAP gpu=
OUT
  printf '%s\n' '{"preferred":{"ssh":"Valentino","kind":"gpu"},"fallback":{"ssh":"Valentino-Arbeit","kind":"cpu"}}' \
    > "$home/config/compute-hosts.json"
  out=$(
    PATH="$fakebin:$PATH" FM_CAPACITY_SKIP_REMOTE='' \
      FM_FAKE_SSH_DIR="$home/ssh" \
      run_capacity "$home" route
  )
  assert_contains "$out" "route=fallback" \
    "an unmeasured CPU must not be routed to as if it were idle"
  assert_contains "$out" "preferred_reachable=yes" "the host did answer the probe"
  assert_contains "$out" "preferred_suitable=no" "but it is not suitable"
  assert_contains "$out" "preferred_cpu=unmeasured" \
    "the report must say why the preferred host was passed over"
  assert_contains "$out" "fallback_cpu=load1=1.0" \
    "a run-queue host reports its own load average"
  pass "a preferred host whose CPU could not be measured yields to the fallback"
}

test_gone_worker_releases_its_id_for_a_sequential_restart() {
  local home out rc
  home="$TMP_ROOT/restart-gone"
  setup_home "$home"
  write_ship_meta "$home" reboot-a1
  write_ship_meta "$home" alive-b2
  # The server was killed: alive-b2's window is listed, reboot-a1's is not, so
  # its endpoint reads `missing` - positively gone, worktree and commits intact.
  set_live_windows "$home" alive-b2
  set +e
  out=$(
    FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
      run_capacity_live "$home" spawn-gate --task-id reboot-a1 2>&1
  )
  rc=$?
  set -e
  expect_code 0 "$rc" "restart of a task whose endpoint is gone"
  [ -f "$home/state/reboot-a1.meta" ] || fail "the durable record must survive the gate"
  # The still-running worker's id stays refused: no second concurrent worker.
  set +e
  out=$(
    FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
      run_capacity_live "$home" spawn-gate --task-id alive-b2 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "spawn-gate against a live worker"
  assert_contains "$out" "already has a worker" "a live worker still blocks its id"
  pass "a task whose worker is positively gone can be restarted; a live one cannot"
}

test_undeclared_work_on_an_unverifiable_backend_still_blocks_its_id() {
  local home out rc
  home="$TMP_ROOT/restart-unknown"
  setup_home "$home"
  write_unverified_ship_meta "$home" unknown-a1
  # Nothing can prove this endpoint dead and the task has declared nothing, so
  # the fail-closed half of the liveness predicate keeps holding the id.
  set +e
  out=$(
    FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
      run_capacity "$home" spawn-gate --task-id unknown-a1 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "spawn-gate against unverifiable active work"
  assert_contains "$out" "already has a worker" "an unproven endpoint must fail closed"
  pass "an unverifiable endpoint on undeclared work still blocks a duplicate spawn"
}

# Run the real emitted Windows probe under pwsh with <stub> standing in for the
# CIM layer, and echo the FM_CAP transcript it produces. The probe command is a
# generated interface delivered to a remote shell, so it is executed rather than
# inspected.
run_windows_probe() { # <stub-powershell>
  local stub=$1 cmd
  local was_samples=$FM_CAPACITY_WIN_LOAD_SAMPLES
  local was_sample_ms=$FM_CAPACITY_WIN_LOAD_SAMPLE_MS
  FM_CAPACITY_WIN_LOAD_SAMPLES=2 FM_CAPACITY_WIN_LOAD_SAMPLE_MS=1
  cmd=$(fm_capacity_windows_probe_cmd)
  FM_CAPACITY_WIN_LOAD_SAMPLES=$was_samples
  FM_CAPACITY_WIN_LOAD_SAMPLE_MS=$was_sample_ms
  # The transcript is the contract under test, not pwsh's exit code: a probe
  # whose CPU query failed is exactly the case being exercised.
  pwsh -NoProfile -NonInteractive -Command "$stub
$cmd" 2>/dev/null || true
  return 0
}

# PowerShell stubs for the probe under test; $-expressions here are PowerShell's.
# shellcheck disable=SC2016
FM_TEST_CIM_OK='function Get-CimInstance { [CmdletBinding()] param([Parameter(Position=0)]$ClassName)
  if ($ClassName -eq "Win32_OperatingSystem") { [pscustomobject]@{ FreePhysicalMemory = 32768000 } }
  else { [pscustomobject]@{ LoadPercentage = 42 } } }'
# shellcheck disable=SC2016
FM_TEST_CIM_CPU_THROWS='function Get-CimInstance { [CmdletBinding()] param([Parameter(Position=0)]$ClassName)
  if ($ClassName -eq "Win32_OperatingSystem") { [pscustomobject]@{ FreePhysicalMemory = 32768000 } }
  else { throw "WMI processor class unavailable" } }'
# shellcheck disable=SC2016
FM_TEST_CIM_CPU_NULL='function Get-CimInstance { [CmdletBinding()] param([Parameter(Position=0)]$ClassName)
  if ($ClassName -eq "Win32_OperatingSystem") { [pscustomobject]@{ FreePhysicalMemory = 32768000 } }
  else { [pscustomobject]@{ LoadPercentage = $null } } }'

test_windows_probe_omits_a_sample_it_could_not_take() {
  local out
  command -v pwsh >/dev/null 2>&1 \
    || { echo "skip: pwsh not found (Windows probe execution)"; return 0; }
  out=$(run_windows_probe "$FM_TEST_CIM_OK")
  assert_contains "$out" "FM_CAP mem_avail_mb=32000" "the probe must report available RAM"
  assert_contains "$out" "FM_CAP load_pct=42" "a readable CPU counter must be reported"
  [ "$(printf '%s\n' "$out" | grep -c 'FM_CAP load_pct=')" = 2 ] \
    || fail "each configured sample should emit one line"
  # The processor class errors: no line at all, never a fabricated 0%.
  out=$(run_windows_probe "$FM_TEST_CIM_CPU_THROWS")
  assert_contains "$out" "FM_CAP mem_avail_mb=32000" "the rest of the probe must still report"
  assert_not_contains "$out" "FM_CAP load_pct=" \
    "a failed processor query must emit no sample rather than 0%"
  fm_capacity_absorb_probe_text "$out
FM_CAP gpu=8192,10" || fail "the transcript should still absorb"
  fm_capacity_host_suitable gpu 24 "$FM_CAPACITY_PROBE_MEM_MB" \
    "$FM_CAPACITY_PROBE_LOAD1" 8192 10 "$FM_CAPACITY_PROBE_LOAD_PCT" \
    && fail "a host whose CPU query failed must be unsuitable, not idle"
  # A null LoadPercentage is the same non-answer, not [int]$null = 0.
  out=$(run_windows_probe "$FM_TEST_CIM_CPU_NULL")
  assert_not_contains "$out" "FM_CAP load_pct=" \
    "a null LoadPercentage must emit no sample rather than 0%"
  pass "the Windows probe omits an unreadable CPU sample instead of fabricating idle"
}

# One processor query per sample costs real time on top of the sleeps, and the
# script pays a PowerShell start plus the one-off OS and GPU queries before the
# loop begins. All of it has to fit the extra SSH seconds the shell grants the
# Windows probe, or a reachable preferred host is cut short and recorded
# unreachable. Runs the real emitted probe at its real sample settings against
# a CIM stub that costs a realistic amount per query.
# shellcheck disable=SC2016
FM_TEST_CIM_SLOW='function Get-CimInstance { [CmdletBinding()] param([Parameter(Position=0)]$ClassName)
  Start-Sleep -Milliseconds 300
  if ($ClassName -eq "Win32_OperatingSystem") { [pscustomobject]@{ FreePhysicalMemory = 32768000 } }
  else { [pscustomobject]@{ LoadPercentage = 42 } } }'

test_windows_probe_fits_the_extra_ssh_seconds_it_is_granted() {
  local budget started elapsed out
  command -v pwsh >/dev/null 2>&1 \
    || { echo "skip: pwsh not found (Windows probe execution)"; return 0; }
  budget=$(fm_capacity_win_probe_extra_secs)
  started=$SECONDS
  out=$(pwsh -NoProfile -NonInteractive -Command "$FM_TEST_CIM_SLOW
$(fm_capacity_windows_probe_cmd)" 2>/dev/null) || true
  elapsed=$((SECONDS - started))
  [ "$(printf '%s\n' "$out" | grep -c 'FM_CAP load_pct=')" = "$FM_CAPACITY_WIN_LOAD_SAMPLES" ] \
    || fail "the probe should emit one sample per configured sample"
  # Compared against the extra allowance alone, so the base bound stays
  # available for the SSH connect and transport it was sized for.
  [ "$elapsed" -le "$budget" ] \
    || fail "the probe ran ${elapsed}s but is granted only ${budget}s of extra SSH time"
  pass "the Windows probe's startup, queries and sampling fit its extra SSH seconds"
}

test_posix_probe_omits_a_load_it_could_not_read() {
  local proc out
  proc="$TMP_ROOT/posix-proc"
  mkdir -p "$proc"
  printf 'MemTotal:       32768000 kB\nMemAvailable:    8192000 kB\n' > "$proc/meminfo"
  printf '0.40 0.35 0.30 1/900 1234\n' > "$proc/loadavg"
  out=$(sh -c "$(fm_capacity_posix_probe_cmd "$proc")")
  assert_contains "$out" "FM_CAP mem_avail_mb=8000" "a readable meminfo must report available RAM"
  assert_contains "$out" "FM_CAP load1=0.40" "a readable loadavg must report the run-queue average"
  fm_capacity_absorb_probe_text "$out" || fail "a healthy POSIX transcript should absorb"
  fm_capacity_host_suitable cpu "$FM_CAPACITY_PROBE_NPROC" "$FM_CAPACITY_PROBE_MEM_MB" \
    "$FM_CAPACITY_PROBE_LOAD1" "" "" "$FM_CAPACITY_PROBE_LOAD_PCT" \
    || fail "a measured idle POSIX host must stay suitable"
  # RAM still readable, load average not: the probe emits no load1 line at all,
  # so the missing measurement cannot be mistaken for an idle host.
  rm -f "$proc/loadavg"
  out=$(sh -c "$(fm_capacity_posix_probe_cmd "$proc")")
  assert_contains "$out" "FM_CAP mem_avail_mb=8000" "the rest of the probe must still report"
  assert_not_contains "$out" "FM_CAP load1=" \
    "an unreadable loadavg must emit no line rather than a fabricated 0"
  fm_capacity_absorb_probe_text "$out" || fail "the transcript should still absorb"
  [ -z "$FM_CAPACITY_PROBE_LOAD1" ] \
    || fail "an absent loadavg must leave no load reading, got $FM_CAPACITY_PROBE_LOAD1"
  [ "$(fm_capacity_cpu_headroom_reading)" = unmeasured ] \
    || fail "the route report must say unmeasured for a host with no CPU sample"
  fm_capacity_host_suitable cpu "$FM_CAPACITY_PROBE_NPROC" "$FM_CAPACITY_PROBE_MEM_MB" \
    "$FM_CAPACITY_PROBE_LOAD1" "" "" "$FM_CAPACITY_PROBE_LOAD_PCT" \
    && fail "readable RAM with no CPU measurement must be unsuitable, not idle"
  if [ "$(id -u)" != 0 ]; then
    printf '0.40 0.35 0.30 1/900 1234\n' > "$proc/loadavg"
    chmod 000 "$proc/loadavg"
    out=$(sh -c "$(fm_capacity_posix_probe_cmd "$proc")")
    assert_not_contains "$out" "FM_CAP load1=" \
      "a permission-denied loadavg must emit no line either"
    chmod 644 "$proc/loadavg"
  fi
  pass "the POSIX probe omits an unreadable load average instead of fabricating idle"
}

test_unreadable_local_load_is_not_read_as_idle() {
  local home out rc
  home="$TMP_ROOT/local-load-unreadable"
  setup_home "$home"
  # A failed platform query is a non-numeric override, not a measured 0.
  out=$(
    FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=unavailable \
      run_capacity "$home" slots
  )
  assert_contains "$out" "slots=0" "unreadable load must yield zero slots, not idle headroom"
  assert_contains "$out" "load1=unavailable" "the failed reading must stay visible"
  assert_not_contains "$out" "load1=0" "a missing load must not be rewritten as idle"
  set +e
  out=$(
    FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=unavailable \
      run_capacity "$home" spawn-gate --task-id fresh-u0 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "spawn-gate with unreadable load"
  assert_contains "$out" "slots=0" "the refuse must cite a zero budget"
  assert_not_contains "$out" "load1=0" "the refuse must not claim idle load"
  # A host that actually measured 0 is idle and still has headroom.
  out=$(
    FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0 \
      run_capacity "$home" slots
  )
  assert_contains "$out" "slots=5" "a measured idle load must keep the full budget"
  assert_contains "$out" "load1=0" "a genuine zero must remain a zero"
  pass "an unreadable local load yields zero slots rather than idle headroom"
}

test_task_id_is_refused_on_probe_slots_and_route() {
  local home out rc cmd
  home="$TMP_ROOT/task-id-commands"
  setup_home "$home"
  for cmd in probe slots route; do
    set +e
    out=$(run_capacity "$home" "$cmd" --task-id ghost-a1 2>&1)
    rc=$?
    set -e
    expect_code 1 "$rc" "$cmd --task-id"
    assert_contains "$out" "--task-id applies only to spawn-gate" \
      "$cmd must refuse --task-id rather than ignore it"
    assert_not_contains "$out" "slots=" "$cmd --task-id must not print a slot budget"
    assert_not_contains "$out" "route=" "$cmd --task-id must not print a routing verdict"
    assert_not_contains "$out" "generated=" "$cmd --task-id must not print a probe"
  done
  set +e
  out=$(run_capacity "$home" slots --task-id=ghost-b2 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "slots --task-id="
  assert_contains "$out" "--task-id applies only to spawn-gate" \
    "the equals form must also be refused on slots"
  set +e
  out=$(run_capacity "$home" --task-id ghost-c3 probe 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "--task-id before probe"
  assert_contains "$out" "--task-id applies only to spawn-gate" \
    "flag-before-command must also be refused"
  set +e
  FM_CAPACITY_NPROC=16 FM_CAPACITY_MEM_AVAIL_MB=24576 FM_CAPACITY_LOAD1=0.4 \
    run_capacity "$home" spawn-gate --task-id fresh-t9 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "spawn-gate --task-id"
  pass "probe, slots, and route refuse --task-id; spawn-gate still accepts it"
}

test_slots_allow_five_on_healthy_supervisor
test_slots_drop_to_zero_when_load_saturates
test_slots_drop_when_ram_is_tight
test_slots_small_host_keeps_one_when_healthy
test_slots_high_but_not_full_load_caps_at_one
test_occupied_counts_ship_and_scout_not_secondmates
test_parked_task_without_a_live_worker_frees_its_slot
test_live_workers_in_a_local_secondmate_home_share_the_host_budget
test_same_task_refuses_a_second_concurrent_worker
test_full_budget_refuses_without_touching_running_workers
test_free_slot_allows_a_new_independent_worker
test_relaunch_and_secondmate_skip_the_slot_budget
test_cli_slots_print_measured_budget
test_preferred_gpu_host_wins_when_freshly_suitable
test_fallback_used_when_preferred_is_unsuitable
test_no_route_when_both_hosts_are_down
test_preferred_pin_keeps_the_configured_fallback
test_invalid_pinned_kind_is_rejected
test_spawn_refuses_at_capacity_without_launching
test_gpu_suitability_requires_headroom
test_unverified_backend_releases_finished_records_but_not_active_work
test_live_worker_keeps_its_slot_despite_a_finished_status_line
test_uniqueness_refuses_reusing_a_live_secondmate_id
test_home_paths_are_deduplicated_by_canonical_path
test_legacy_terminal_line_releases_a_slot_on_an_unverifiable_backend
test_percentage_load_is_averaged_across_probe_samples
test_burst_on_the_preferred_windows_host_keeps_heim_preference
test_sustained_windows_pin_falls_through_to_the_fallback
test_duplicate_id_refuses_without_measuring_the_host
test_unmeasurable_windows_cpu_is_not_read_as_idle
test_unmeasurable_preferred_host_falls_through_to_the_fallback
test_gone_worker_releases_its_id_for_a_sequential_restart
test_undeclared_work_on_an_unverifiable_backend_still_blocks_its_id
test_windows_probe_omits_a_sample_it_could_not_take
test_windows_probe_fits_the_extra_ssh_seconds_it_is_granted
test_posix_probe_omits_a_load_it_could_not_read
test_unreadable_local_load_is_not_read_as_idle
test_task_id_is_refused_on_probe_slots_and_route

echo "# all fm-capacity tests passed"
