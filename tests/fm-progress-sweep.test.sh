#!/usr/bin/env bash
# Behavior tests for the orphaned-work sweep (bin/fm-progress-sweep.sh) and its
# two consumers: the watcher heartbeat (bin/fm-watch.sh) and the turn-end guard
# (bin/fm-turnend-guard.sh plus the Pi adapter's follow-up text).
#
# The anchor case replays the 31 October stall: an In-flight row whose worker
# had died and a finished row nobody landed, with no blocker, hold, or wait.
# It must raise a wake and refuse the turn end. A paused, a held, and a blocked
# row must each stay silent.
# All hermetic over temp homes with a real markdown tasks-axi backlog, a fake
# tmux that answers only which panes are alive, and a canned fm-crew-state.sh.
# Subshells below deliberately scope their exports to one watcher or guard run.
# shellcheck disable=SC2030,SC2031
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-progress-sweep)
fm_git_identity fmtest fmtest@example.invalid
SWEEP="$ROOT/bin/fm-progress-sweep.sh"
WATCH="$ROOT/bin/fm-watch.sh"
OLD=$(( $(date +%s) - 7200 ))

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# A fake tmux that reports FM_FAKE_LIVE_PANES (space-separated %ids) as the
# only live panes, and a canned crew-state that answers FM_FAKE_CREW_STATE_<id>.
make_fakebin() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-panes ]; then
  for p in ${FM_FAKE_LIVE_PANES:-}; do printf '%s\n' "$p"; done
  exit 0
fi
exit 1
SH
  cat > "$fb/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
key=$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9' '_')
var="FM_FAKE_CREW_STATE_$key"
printf '%s\n' "${!var:-state: unknown · source: none · fake default}"
SH
  chmod +x "$fb/tmux" "$fb/fm-crew-state.sh"
  printf '%s\n' "$fb"
}

make_home() {  # <name> -> home dir
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  make_fakebin "$home" >/dev/null
  printf '%s\n' "$home"
}

axi() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$ROOT/bin/fm-tasks-axi.sh" "$@" >/dev/null \
    || fail "tasks-axi $* failed in $home"
}

# An In-flight row with a task record whose endpoint is the tmux pane <pane>,
# and an optional status log; every grace anchor is two hours old.
add_inflight() {  # <home> <id> <pane> <status-line-or-empty> [meta kv...]
  local home=$1 id=$2 pane=$3 line=$4
  shift 4
  axi "$home" add "$id" "Row $id" --kind ship --repo demo
  axi "$home" start "$id"
  fm_write_meta "$home/state/$id.meta" "window=$pane" backend=tmux kind=ship mode=no-mistakes yolo=off "$@"
  [ -z "$line" ] || printf '%s\n' "$line" > "$home/state/$id.status"
  age_anchors "$home" "$id"
}

age_anchors() {  # <home> <id>
  local f
  for f in "$1/state/$2.meta" "$1/state/$2.status"; do
    [ -e "$f" ] && fm_touch_epoch "$OLD" "$f"
  done
  return 0
}

run_sweep() {  # <home> [env...]
  local home=$1
  shift
  env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" "$@" "$SWEEP" --all
}

row_of() {  # <output> <id> -> "<class> <reason>"
  printf '%s\n' "$1" | awk -F '\t' -v id="$2" '$2 == id { print $1 " " $3 }'
}

# The 31 October state: a dead worker's row still In flight with no blocker,
# hold, or wait, and finished work whose worker is gone and nobody landed.
seed_oct31() {  # <home>
  add_inflight "$1" witness %91 "working [at=$OLD]: handing back the witness run"
  add_inflight "$1" accessory %92 "done [at=$OLD]: fix landed on the local branch"
}

# A paused, a held, and a blocked row: each has one typed reason.
seed_quiet() {  # <home>
  add_inflight "$1" waiting %93 "paused [at=$OLD]: upstream CI queued for runners"
  add_inflight "$1" held %94 "needs-decision [at=$OLD]: which route"
  axi "$1" hold held --kind captain --reason "route choice is the captain's"
  axi "$1" add gate "Gate the blocked row" --repo demo
  axi "$1" hold gate --kind external --reason "upstream release"
  add_inflight "$1" blocked %95 "blocked [at=$OLD]: needs the gate first"
  axi "$1" block blocked --by gate
}

# --- predicate ----------------------------------------------------------------

test_sweep_flags_oct31_dead_worker_and_unlanded_work() {
  local home out
  home=$(make_home pred-oct31)
  seed_oct31 "$home"
  out=$(run_sweep "$home") || fail "sweep failed on the 31 October state: $out"
  assert_equals "orphan worker-dead" "$(row_of "$out" witness)" "dead worker's In-flight row must be an orphan"
  assert_equals "orphan worker-dead-after-done" "$(row_of "$out" accessory)" "finished, unlanded work with a gone worker must be an orphan"
  pass "sweep: the 31 October dead worker and unlanded finished work are orphans"
}

test_sweep_paused_held_blocked_rows_have_reasons() {
  local home out
  home=$(make_home pred-quiet)
  seed_quiet "$home"
  out=$(run_sweep "$home") || fail "sweep failed: $out"
  assert_equals "progressing paused" "$(row_of "$out" waiting)" "a declared paused wait is a typed reason"
  assert_equals "progressing hold-captain" "$(row_of "$out" held)" "an active captain hold is a typed reason"
  assert_equals "progressing blocked-by" "$(row_of "$out" blocked)" "an open blocked-by edge is a typed reason"
  assert_not_contains "$out" "orphan" "no row in the quiet home may be an orphan"
  pass "sweep: a paused, a held, and a blocked row each carry a typed reason"
}

test_sweep_grace_and_live_worker_reasons() {
  local home out
  home=$(make_home pred-grace)
  add_inflight "$home" fresh %80 "done [at=$OLD]: finished"
  touch "$home/state/fresh.status"
  add_inflight "$home" answered %81 "needs-decision [at=$OLD]: which"
  mkdir -p "$home/state/answered.inbox/handled"
  : > "$home/state/answered.inbox/handled/1.msg"
  add_inflight "$home" busy %82 "working [at=$OLD]: long build"
  out=$(run_sweep "$home" FM_FAKE_LIVE_PANES="%81 %82" \
    "FM_FAKE_CREW_STATE_busy=state: working · source: pane · busy") || fail "sweep failed: $out"
  assert_equals "progressing grace" "$(row_of "$out" fresh)" "a just-written status event starts the grace window"
  assert_equals "progressing grace" "$(row_of "$out" answered)" "a just-sent firstmate answer starts the grace window"
  assert_equals "progressing working" "$(row_of "$out" busy)" "a worker reported working is a typed reason"
  pass "sweep: the grace window and a working worker are typed reasons"
}

test_sweep_finished_and_unanswered_live_workers() {
  local home out
  home=$(make_home pred-live)
  add_inflight "$home" landable %70 "done [at=$OLD]: ready"
  fm_write_meta "$home/state/landable.meta" window=%70 backend=tmux kind=ship yolo=on
  fm_touch_epoch "$OLD" "$home/state/landable.meta"
  add_inflight "$home" approval %71 "done [at=$OLD]: PR ready"
  add_inflight "$home" asking %72 "needs-decision [at=$OLD]: pick one"
  add_inflight "$home" idle %73 "working [at=$OLD]: reading"
  out=$(run_sweep "$home" FM_FAKE_LIVE_PANES="%70 %71 %72 %73" \
    "FM_FAKE_CREW_STATE_landable=state: done · source: status-log · ready" \
    "FM_FAKE_CREW_STATE_approval=state: done · source: status-log · ready" \
    "FM_FAKE_CREW_STATE_asking=state: blocked · source: status-log · asked" \
    "FM_FAKE_CREW_STATE_idle=state: working · source: status-log · reading") || fail "sweep failed: $out"
  assert_equals "orphan ready-to-land" "$(row_of "$out" landable)" "finished work within merge authority is an orphan"
  assert_equals "orphan finished-needs-landing-call" "$(row_of "$out" approval)" "finished work needing the captain's word is an orphan until held"
  assert_equals "orphan terminal-needs-decision" "$(row_of "$out" asking)" "an unanswered decision past grace is an orphan"
  assert_equals "progressing idle-watched" "$(row_of "$out" idle)" "a live idle worker whose working comes only from the status log is not working"
  pass "sweep: finished and unanswered work with a live worker is orphaned"
}

test_sweep_queued_and_out_of_scope_rows() {
  local home out
  home=$(make_home pred-queued)
  axi "$home" add next-unit "Next unit" --repo demo
  axi "$home" add later-unit "Later" --repo demo
  axi "$home" hold later-unit --kind future --reason "after the release"
  axi "$home" add mate-row "A secondmate" --kind secondmate --repo demo
  axi "$home" start mate-row
  axi "$home" add missing "No record" --kind ship --repo demo
  axi "$home" start missing
  out=$(run_sweep "$home") || fail "sweep failed: $out"
  assert_equals "orphan queued-ready" "$(row_of "$out" next-unit)" "a dispatchable Queued row with free capacity is an orphan"
  assert_equals "" "$(row_of "$out" later-unit)" "a held Queued row is not dispatchable and is not reported"
  assert_equals "" "$(row_of "$out" mate-row)" "secondmate rows are out of scope"
  assert_equals "orphan no-task-record" "$(row_of "$out" missing)" "an In-flight row with no task record is an orphan"
  out=$(run_sweep "$TMP_ROOT/no-such-home") || fail "sweep must succeed silently for a home with no data"
  assert_equals "" "$out" "a home with no data directory has no rows"
  pass "sweep: Queued orphans, held and secondmate rows, and a missing task record"
}

# tasks-axi `ready` also prints delivery-ready public-followup obligations as a
# second table, ready_public_followups, which tasks-axi documents as never
# dispatchable. This wraps the real tasks-axi to add one such row in that
# documented shape, so only the sweep's reading of it is under test.
test_sweep_ignores_ready_public_followups() {
  local home out
  home=$(make_home pred-followups)
  mkdir -p "$home/bin"
  cp -R "$ROOT/bin/." "$home/bin/"
  mv "$home/bin/fm-tasks-axi.sh" "$home/bin/fm-tasks-axi-real.sh"
  cat > "$home/bin/fm-tasks-axi.sh" <<'SH'
#!/usr/bin/env bash
"${0%/*}/fm-tasks-axi-real.sh" "$@" || exit
if [ "${1:-}" = ready ]; then
  printf 'ready_public_followups[1]{id,state,kind,repo,title,delivery_state}:\n'
  printf '  pf-owed,queued,public-followup,demo,Reply owed on the thread,ready\n'
fi
SH
  chmod +x "$home/bin/fm-tasks-axi.sh"
  axi "$home" add next-unit "Next unit" --repo demo
  out=$(env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" "$home/bin/fm-progress-sweep.sh" --all) \
    || fail "sweep failed: $out"
  assert_equals "orphan queued-ready" "$(row_of "$out" next-unit)" "the dispatchable ready row is still an orphan"
  assert_equals "" "$(row_of "$out" pf-owed)" "a never-dispatchable public-followup obligation is not a Queued row"
  pass "sweep: ready public-followup obligations are not read as dispatchable rows"
}

# tasks-axi's TOON output quotes a value that reads as a number, boolean, or
# null, so the ids 2048 and true arrive as "2048" and "true". The row's real id
# names its task record and its wake key.
test_sweep_unquotes_numeric_and_boolean_ids() {
  local home out
  home=$(make_home pred-quoted)
  add_inflight "$home" 2048 %60 "working [at=$OLD]: long build"
  axi "$home" add true "A boolean-looking id" --repo demo
  out=$(run_sweep "$home" FM_FAKE_LIVE_PANES="%60" \
    "FM_FAKE_CREW_STATE_2048=state: working · source: pane · busy") || fail "sweep failed: $out"
  assert_equals "progressing working" "$(row_of "$out" 2048)" "a numeric id must find its own task record and working worker"
  assert_equals "orphan queued-ready" "$(row_of "$out" true)" "a boolean-looking Queued id must be reported by its real id"
  assert_not_contains "$out" '"' "no emitted id may keep its TOON quotes"
  pass "sweep: TOON-quoted numeric and boolean ids are read as their real ids"
}

seed_full_lanes() {  # <home> <lane-capacity-content>
  local i
  printf '%s\n' "$2" > "$1/config/lane-capacity"
  for i in 1 2 3; do
    add_inflight "$1" "lane$i" "%5$i" "working [at=$OLD]: running"
  done
  axi "$1" add next-unit "Next unit" --repo demo
}

full_lane_env() {
  printf '%s\n' "FM_FAKE_LIVE_PANES=%51 %52 %53" \
    "FM_FAKE_CREW_STATE_lane1=state: working · source: pane · busy" \
    "FM_FAKE_CREW_STATE_lane2=state: working · source: pane · busy" \
    "FM_FAKE_CREW_STATE_lane3=state: working · source: pane · busy"
}

test_sweep_full_lane_capacity_is_a_reason() {
  local home out line envs=()
  home=$(make_home pred-lanes-full)
  seed_full_lanes "$home" 3
  while IFS= read -r line; do envs+=("$line"); done < <(full_lane_env)
  out=$(run_sweep "$home" "${envs[@]}") || fail "sweep failed: $out"
  assert_equals "progressing lane-capacity-full" "$(row_of "$out" next-unit)" "a ready row with every configured lane running is held by lane capacity"
  assert_not_contains "$out" "orphan" "no row in a home at its lane cap may be an orphan"
  (
    export PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh"
    export "${envs[@]}"
    # shellcheck source=bin/fm-watch.sh
    . "$WATCH"
    progress_orphans_enqueue
    [ "$?" -eq 1 ] || { printf 'heartbeat found an orphan: %s\n' "$PROGRESS_ORPHAN_REASON"; exit 1; }
  ) || fail "the heartbeat must stay silent for a home at its lane cap"
  if [ -f "$home/state/.wake-queue" ]; then
    assert_no_grep "progress-orphan" "$home/state/.wake-queue" "no progress-orphan wake may be queued at the lane cap"
  fi
  pass "sweep: a ready row held by a full lane cap is progressing and wakes nobody"
}

test_sweep_undeterminable_lane_capacity_still_orphans() {
  local home out line envs=()
  home=$(make_home pred-lanes-bad)
  seed_full_lanes "$home" "three lanes"
  while IFS= read -r line; do envs+=("$line"); done < <(full_lane_env)
  out=$(run_sweep "$home" "${envs[@]}") || fail "sweep failed: $out"
  assert_equals "orphan queued-ready" "$(row_of "$out" next-unit)" "an unreadable lane cap must never make an idle ready row look held"
  pass "sweep: an undeterminable lane capacity still reports the ready row as an orphan"
}

# --- watcher heartbeat --------------------------------------------------------

# The 31 October events had already been surfaced and handled: every status
# line was seen by the per-poll scan and classified by the heartbeat backstop.
# Record that through the watcher's own bookkeeping so only the sweep can wake.
settle_status_history() {  # <home>
  local home=$1 f
  for f in "$home/state"/*.status; do
    [ -e "$f" ] && prime_status_seen "$home/state" "$f"
  done
  (
    export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state"
    # shellcheck source=bin/fm-watch.sh
    . "$WATCH"
    heartbeat_scan_finds_actionable || :
    mark_all_captain_relevant_surfaced
  ) >/dev/null 2>&1 || fail "could not record the status history as surfaced"
}

start_heartbeat_watcher() {  # <home> <out>
  local home=$1
  settle_status_history "$home"
  printf '3\n' > "$home/state/.heartbeat-streak"
  touch "$home/state/.last-heartbeat"
  fm_touch_epoch "$(( $(date +%s) - 30 ))" "$home/state/.last-heartbeat"
  fm_test_track_watcher_state "$home/state"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    "$WATCH" > "$2" 2>/dev/null &
}

test_heartbeat_wakes_on_oct31_orphan() {
  local home out pid i
  home=$(make_home hb-oct31)
  seed_oct31 "$home"
  out="$home/watch.out"
  start_heartbeat_watcher "$home" "$out"
  pid=$!
  i=0
  while [ "$i" -lt 300 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  kill -0 "$pid" 2>/dev/null && { reap "$pid"; fail "heartbeat absorbed the 31 October orphans instead of waking"; }
  wait "$pid" 2>/dev/null || true
  grep -Eq '^check: progress-orphan (witness|accessory) worker-dead(-after-done)? \(\+1 more\)$' "$out" \
    || fail "the wake reason must name an orphan, why, and how many more: $(cat "$out")"
  awk -F '\t' '$3 == "check" && $4 == "progress-orphan:witness" && $5 == "check: progress-orphan witness worker-dead" { f = 1 } END { exit !f }' \
    "$home/state/.wake-queue" || fail "the dead worker's orphan was not queued as a check wake"
  awk -F '\t' '$3 == "check" && $4 == "progress-orphan:accessory" { f = 1 } END { exit !f }' \
    "$home/state/.wake-queue" || fail "the unlanded finished work was not queued as a check wake"
  assert_equals 0 "$(cat "$home/state/.heartbeat-streak")" "an orphan must reset the heartbeat backoff streak"
  pass "heartbeat: the 31 October orphans wake firstmate and reset the backoff"
}

test_heartbeat_requeue_skips_unacknowledged_orphan() {
  local home reason
  home=$(make_home hb-requeue)
  add_inflight "$home" witness %91 "working [at=$OLD]: handing back"
  printf '%s\t1\tcheck\tprogress-orphan:witness\tcheck: progress-orphan witness worker-dead\n' "$(date +%s)" \
    > "$home/state/.wake-queue"
  printf '1\n' > "$home/state/.wake-queue.seq"
  reason=$(
    export PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh"
    # shellcheck source=bin/fm-watch.sh
    . "$WATCH"
    progress_orphans_enqueue || exit $?
    printf '%s\n' "$PROGRESS_ORPHAN_REASON"
  ) || fail "the heartbeat sweep must still report a still-orphaned item"
  assert_equals "check: progress-orphan witness worker-dead" "$reason" "the heartbeat must still wake for the still-orphaned item"
  assert_equals 1 "$(awk -F '\t' '$4 == "progress-orphan:witness"' "$home/state/.wake-queue" | wc -l | tr -d ' ')" \
    "an orphan still queued and unacknowledged must not be queued twice"
  pass "heartbeat: a still-orphaned item re-fires without duplicating its queued wake"
}

test_heartbeat_absorbs_paused_held_blocked_rows() {
  local home out pid i
  home=$(make_home hb-quiet)
  seed_quiet "$home"
  out="$home/watch.out"
  start_heartbeat_watcher "$home" "$out"
  pid=$!
  i=0
  while [ "$i" -lt 300 ]; do
    kill -0 "$pid" 2>/dev/null || break
    [ "$(cat "$home/state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 4 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || fail "watcher woke for rows that each have a typed reason: $(cat "$out")"
  reap "$pid"
  [ "$(cat "$home/state/.heartbeat-streak")" -ge 4 ] || fail "the quiet heartbeat was not absorbed"
  [ ! -s "$out" ] || fail "a quiet heartbeat printed a wake reason: $(cat "$out")"
  if [ -f "$home/state/.wake-queue" ]; then
    assert_no_grep "progress-orphan" "$home/state/.wake-queue" "no orphan may be queued for paused, held, or blocked rows"
  fi
  pass "heartbeat: paused, held, and blocked rows stay silent"
}

# --- turn-end guard -----------------------------------------------------------

make_guard_home() {  # <name> -> primary-shaped home with a live, healthy watcher
  local home
  home=$(make_home "$1")
  git init -q "$home"
  git -C "$home" commit -q --allow-empty -m init
  : > "$home/AGENTS.md"
  cp -R "$ROOT/bin" "$home/bin"
  mkdir -p "$home/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$home/docs/supervision-protocols"
  printf '%s\n' "$home"
}

GUARD_WATCHER_PID=
arm_fake_watcher() {  # <home>
  local home=$1 identity
  sleep 120 &
  GUARD_WATCHER_PID=$!
  identity=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$home/bin/fm-wake-lib.sh" "$GUARD_WATCHER_PID") \
    || { reap "$GUARD_WATCHER_PID"; fail "could not identify the fake watcher"; }
  mkdir -p "$home/state/.watch.lock"
  printf '%s\n' "$GUARD_WATCHER_PID" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$home/bin/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
  touch "$home/state/.last-watcher-beat"
}

run_guard() {  # <home> <payload> [guard-args...]
  local home=$1 payload=$2
  shift 2
  # wake-helpers.sh points FM_ROOT_OVERRIDE at its own tangle root; the guard
  # must scope itself to this primary-shaped home instead.
  printf '%s' "$payload" | env -u FM_ROOT_OVERRIDE PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" bash "$home/bin/fm-turnend-guard.sh" "$@" 2>&1
}

test_guard_refuses_idle_turn_on_oct31_state() {
  local home out status
  home=$(make_guard_home guard-oct31)
  seed_oct31 "$home"
  arm_fake_watcher "$home"
  out=$(run_guard "$home" '{"stop_hook_active":false}'); status=$?
  reap "$GUARD_WATCHER_PID"
  expect_code 2 "$status" "a healthy-but-idle turn with orphans must be refused"
  assert_contains "$out" "TURN WOULD END IDLE - 2 item(s)" "the refusal must count the idle items"
  assert_contains "$out" "witness - worker-dead" "the refusal must name the dead worker's row and why"
  assert_contains "$out" "accessory - worker-dead-after-done" "the refusal must name the unlanded finished work"
  assert_contains "$out" "never cleared with --force" "the refusal must say a refusal is not bypassed by force"
  assert_not_contains "$out" "TURN WOULD END BLIND" "a healthy watcher must not be reported as blind"
  pass "turn-end guard: the 31 October state refuses the turn end as IDLE"
}

test_guard_silent_for_paused_held_blocked_rows() {
  local home out status
  home=$(make_guard_home guard-quiet)
  seed_quiet "$home"
  arm_fake_watcher "$home"
  out=$(run_guard "$home" '{"stop_hook_active":false}'); status=$?
  reap "$GUARD_WATCHER_PID"
  expect_code 0 "$status" "rows that each have a typed reason must let the turn end"
  assert_equals "" "$out" "the guard must stay silent for paused, held, and blocked rows"
  pass "turn-end guard: paused, held, and blocked rows let the turn end silently"
}

test_guard_refuses_idle_with_nothing_in_flight() {
  local home out status
  home=$(make_guard_home guard-queued)
  axi "$home" add next-unit "Next unit" --repo demo
  out=$(run_guard "$home" '{"stop_hook_active":false}'); status=$?
  expect_code 2 "$status" "finished work with a ready next unit and nothing dispatched must be refused"
  assert_contains "$out" "next-unit - queued-ready" "the refusal must name the undispatched ready row"
  out=$(run_guard "$home" '{"stop_hook_active":true}'); status=$?
  expect_code 0 "$status" "the forced follow-up's own stop must end (one bounded continuation)"
  pass "turn-end guard: a ready Queued row with nothing in flight is refused once per turn"
}

test_guard_claude_mode_bounds_idle_followup() {
  local home out status payload
  home=$(make_guard_home guard-claude)
  seed_oct31 "$home"
  arm_fake_watcher "$home"
  payload='{"stop_hook_active":true,"session_id":"sess-1"}'
  out=$(run_guard "$home" "$payload" --claude); status=$?
  expect_code 2 "$status" "Claude must refuse the first idle stop even when stop_hook_active is set"
  assert_contains "$out" "TURN WOULD END IDLE" "Claude's refusal must carry the IDLE banner"
  out=$(run_guard "$home" "$payload" --claude); status=$?
  expect_code 0 "$status" "the forced follow-up's own stop must end, so the session is never wedged"
  out=$(run_guard "$home" "$payload" --claude); status=$?
  reap "$GUARD_WATCHER_PID"
  expect_code 2 "$status" "a later turn that is still idle must be refused again"
  pass "turn-end guard: Claude allows exactly one forced idle follow-up per turn"
}

test_guard_claude_idle_followup_is_per_session() {
  local home out status a b
  home=$(make_guard_home guard-claude-two)
  seed_oct31 "$home"
  arm_fake_watcher "$home"
  a='{"stop_hook_active":true,"session_id":"sess-a"}'
  b='{"stop_hook_active":true,"session_id":"sess-b"}'
  out=$(run_guard "$home" "$a" --claude); status=$?
  expect_code 2 "$status" "session A's idle stop must be refused"
  out=$(run_guard "$home" "$b" --claude); status=$?
  expect_code 2 "$status" "session B's idle stop must be refused"
  out=$(run_guard "$home" "$a" --claude); status=$?
  expect_code 0 "$status" "session A's follow-up must end even after B was refused: $out"
  out=$(run_guard "$home" "$b" --claude); status=$?
  expect_code 0 "$status" "session B's follow-up must end even after A ended: $out"
  out=$(run_guard "$home" "$a" --claude); status=$?
  expect_code 2 "$status" "a later idle stop must be refused again"
  reap "$GUARD_WATCHER_PID"
  out=$(run_guard "$home" "$a" --claude); status=$?
  assert_contains "$out" "TURN WOULD END BLIND" "a follow-up that finds supervision down gets the blind refusal"
  arm_fake_watcher "$home"
  out=$(run_guard "$home" "$a" --claude); status=$?
  reap "$GUARD_WATCHER_PID"
  expect_code 2 "$status" "a follow-up that took the blind path must not let the next idle stop pass unswept"
  assert_contains "$out" "TURN WOULD END IDLE" "the next idle stop must carry the IDLE banner"
  pass "turn-end guard: each Claude session gets its own one forced idle follow-up"
}

# Runs the guard as its own harness process (argv0 codex), so its session
# ancestry is fixed by the test rather than by whatever launched the suite.
# With <own-lock>, that harness pid is first written as the home lock owner.
run_guard_as_harness() {  # <home> <payload> [own-lock-path]
  local home=$1 payload=$2 lock=${3:-}
  # shellcheck disable=SC2016 # Expanded by the inner shell.
  printf '%s' "$payload" | env -u FM_ROOT_OVERRIDE PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" \
    bash -c '[ -z "$1" ] || printf "%s\n" "$$" > "$1"; exec -a codex bash "$2"' _ "$lock" "$home/bin/fm-turnend-guard.sh" 2>&1
}

test_guard_readonly_session_not_refused_idle() {
  local home out status owner
  home=$(make_guard_home guard-readonly)
  seed_oct31 "$home"
  arm_fake_watcher "$home"
  bash -c 'exec -a claude sleep 120' &
  owner=$!
  printf '%s\n' "$owner" > "$home/state/.lock"
  out=$(run_guard_as_harness "$home" '{"stop_hook_active":false}'); status=$?
  reap "$owner"
  if [ "$status" -ne 0 ]; then reap "$GUARD_WATCHER_PID"; fi
  expect_code 0 "$status" "a session whose home lock another live session owns is read-only and must not be refused: $out"
  assert_not_contains "$out" "TURN WOULD END IDLE" "a read-only session must not be told to dispatch or land"
  out=$(run_guard_as_harness "$home" '{"stop_hook_active":false}' "$home/state/.lock"); status=$?
  reap "$GUARD_WATCHER_PID"
  expect_code 2 "$status" "the session that owns the home lock must still be refused for idle items: $out"
  assert_contains "$out" "TURN WOULD END IDLE" "the lock-owning session must get the IDLE banner"
  pass "turn-end guard: a read-only second session is never refused for idle items"
}

test_pi_adapter_relays_idle_banner_unframed() {
  local repo ext out status
  repo="$TMP_ROOT/pi-idle-root"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$repo/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '●  TURN WOULD END IDLE - 1 item(s) in flight or ready with no worker, wait, hold, or blocker:\n' >&2
exit 2
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/fm-arm-pretool-check.sh"
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-arm-pretool-check.sh"
  command -v node >/dev/null 2>&1 || { pass "Pi adapter idle relay skipped: node not found"; return 0; }
  out=$(PLUGIN="$ext" FM_HOME="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = new Map();
let seen = "";
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  async sendUserMessage(message) { seen = message; },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("agent_settled")?.({ type: "agent_settled" }, {});
if (!seen.includes("TURN WOULD END IDLE")) throw new Error(`idle banner not relayed: ${seen}`);
if (seen.includes("TURN WOULD END BLIND")) throw new Error(`idle refusal framed as blind: ${seen}`);
EOF
)
  status=$?
  expect_code 0 "$status" "the Pi adapter must relay the idle banner without the blind framing: $out"
  pass "Pi adapter: an idle refusal is relayed without the supervision-outage framing"
}

fm_test_run \
  test_sweep_flags_oct31_dead_worker_and_unlanded_work \
  test_sweep_paused_held_blocked_rows_have_reasons \
  test_sweep_grace_and_live_worker_reasons \
  test_sweep_finished_and_unanswered_live_workers \
  test_sweep_queued_and_out_of_scope_rows \
  test_sweep_ignores_ready_public_followups \
  test_sweep_unquotes_numeric_and_boolean_ids \
  test_sweep_full_lane_capacity_is_a_reason \
  test_sweep_undeterminable_lane_capacity_still_orphans \
  test_heartbeat_wakes_on_oct31_orphan \
  test_heartbeat_requeue_skips_unacknowledged_orphan \
  test_heartbeat_absorbs_paused_held_blocked_rows \
  test_guard_refuses_idle_turn_on_oct31_state \
  test_guard_silent_for_paused_held_blocked_rows \
  test_guard_refuses_idle_with_nothing_in_flight \
  test_guard_claude_mode_bounds_idle_followup \
  test_guard_claude_idle_followup_is_per_session \
  test_guard_readonly_session_not_refused_idle \
  test_pi_adapter_relays_idle_banner_unframed
