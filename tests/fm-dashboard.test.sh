#!/usr/bin/env bash
# Behavior tests for the public read-only dashboard launcher and its localhost
# service, covering lifecycle, durable snapshots/events, cursor replay,
# supervision alarm presentation, wake-queue preservation, and the page's
# read-only boundary.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASHBOARD="$ROOT/bin/fm-dashboard.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard)
PIDS=()

cleanup_dashboard() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_dashboard EXIT

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

make_home() {
  local home=$TMP_ROOT/$1
  shift
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] dashboard-task - Dashboard task (repo: local) (kind: ship) (since 2026-08-04)

## Queued

## Done
EOF
  fm_write_meta "$home/state/dashboard-task.meta" \
    "project=local" \
    "kind=ship" \
    "mode=ship" \
    "harness=codex"
  printf 'working: initial observation\n' > "$home/state/dashboard-task.status"
  printf 'wake-sentinel\n' > "$home/state/.wake-queue"
  printf '%s\n' "$home"
}

make_active_secondmate() {
  local home=$1 mate=$2 gen
  mkdir -p "$mate/state" "$mate/data" "$mate/config" "$mate/projects/child" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight
- [ ] child - Active child (repo: local) (kind: ship) (since 2026-08-04)

## Queued

## Done
EOF
  fm_write_meta "$mate/state/child.meta" \
    "window=firstmate:fm-child" "worktree=$mate/projects/child" \
    "project=local" "harness=claude" "kind=ship" "mode=no-mistakes"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$mate/state" child)
  "$ROOT/bin/fm-busy-event.sh" apply "$mate/state" child busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  printf 'working [key=child]: active child\n' > "$mate/state/child.status"
  printf -- '- mate - fixture domain (home: %s; scope: fixture; projects: local; added 2026-08-04)\n' \
    "$mate" >> "$home/data/secondmates.md"
  fm_write_secondmate_meta "$home/state/mate.meta" "$mate" "firstmate:fm-mate" local claude
}

start_dashboard() {
  local home=$1 interval=${2:-0.1} output
  output=$(FM_HOME="$home" \
    FM_DASHBOARD_INCLUDE_PRS=0 \
    FM_STALE_ESCALATE_SECS=1 \
    FM_DASHBOARD_NO_OPEN=1 \
    "$DASHBOARD" start --port 0 --interval "$interval" --no-open --no-prs)
  DASHBOARD_URL=$(printf '%s\n' "$output" | sed -n 's/^dashboard: //p')
  [ -n "$DASHBOARD_URL" ] || fail "public launcher did not print dashboard URL"
  DASHBOARD_PID=$(sed -n '1p' "$home/state/.dashboard/service.pid")
  PIDS+=("$DASHBOARD_PID")
}

api_snapshot() {
  curl -fsS "${DASHBOARD_URL%/}/api/snapshot"
}

wait_for_snapshot() {
  local i=0
  while [ "$i" -lt 40 ]; do
    if api_snapshot | jq -e '.schema == "fm-dashboard-snapshot.v1"' >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  fail "dashboard did not publish its initial snapshot"
}

wait_for_secondmate_cursor() {
  local dashboard_dir=$1 status_path=$2 i=0
  while [ "$i" -lt 40 ]; do
    if jq -e --arg path "$status_path" '."mate/child".path == $path' \
      "$dashboard_dir/status-cursors.json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  fail "dashboard did not persist the secondmate status source"
}

test_public_launcher_snapshot_and_health() {
  local home out queue_after page
  home=$(make_home snapshot)
  start_dashboard "$home"
  sleep 1.6
  out=$(api_snapshot)
  printf '%s' "$out" | jq -e '
    .schema == "fm-dashboard-snapshot.v1"
    and .supervision.state == "no-watcher-active"
    and .supervision.needed == true
    and (.tasks | any(.[]; .id == "dashboard-task" and .phase == "unknown"))
    and (.tasks | any(.[]; .attention == "stale" or .attention == "possible-wedge"))
    and (.fleet.prs | contains("not_requested"))
  ' >/dev/null || fail "dashboard snapshot did not expose fleet and stale supervision health: $out"
  queue_after=$(cat "$home/state/.wake-queue")
  [ "$queue_after" = "wake-sentinel" ] || fail "dashboard changed the wake queue"
  page=$(curl -fsS "${DASHBOARD_URL%/}/")
  ! printf '%s' "$page" | grep -Eiq 'steer|interrupt|teardown|merge' \
    || fail "dashboard page exposed a fleet-control operation"
  pass "public launcher serves a compact read-only snapshot and explicit supervision alarm"
}

test_status_event_cursor_and_restart_replay() {
  local home stream replay output2 pid2 i
  home=$(make_home replay)
  start_dashboard "$home"
  wait_for_snapshot
  printf 'done [key=dashboard]: event arrived token=dashboard-sentinel\n' >> "$home/state/dashboard-task.status"
  sleep 0.4
  stream=$(curl -N -fsS --max-time 2 "${DASHBOARD_URL%/}/events?since=0" || true)
  printf '%s' "$stream" | grep -F 'event: status' >/dev/null \
    || fail "SSE stream did not deliver appended status event: $stream"
  printf '%s' "$stream" | grep -F 'event arrived' >/dev/null \
    || fail "SSE payload omitted the status summary: $stream"
  printf '%s' "$stream" | grep -F '"key": "dashboard"' >/dev/null \
    || fail "SSE payload omitted the status key: $stream"
  ! printf '%s' "$stream" | grep -F 'dashboard-sentinel' >/dev/null \
    || fail "SSE payload exposed a secret-looking status value: $stream"
  printf 'working [key=dashboard]: working: token ghp_status_secret_ABC123456789\n' >> "$home/state/dashboard-task.status"
  sleep 0.4
  stream=$(curl -N -fsS --max-time 2 "${DASHBOARD_URL%/}/events?since=0" || true)
  ! printf '%s' "$stream" | grep -F 'ghp_status_secret_ABC123456789' >/dev/null \
    || fail "SSE payload exposed a token-shaped status value: $stream"
  ! grep -F 'ghp_status_secret_ABC123456789' "$home/state/.dashboard/events.jsonl" >/dev/null \
    || fail "event outbox persisted a token-shaped status value"
  kill "$DASHBOARD_PID"
  i=0
  while [ "$i" -lt 40 ] && [ -e "$home/state/.dashboard/service.pid" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ ! -e "$home/state/.dashboard/service.pid" ] \
    || fail "dashboard service did not finish its graceful shutdown"
  output2=$(FM_HOME="$home" FM_DASHBOARD_INCLUDE_PRS=0 FM_STALE_ESCALATE_SECS=1 \
    FM_DASHBOARD_NO_OPEN=1 "$DASHBOARD" start --port 0 --interval 0.1 --no-open --no-prs)
  DASHBOARD_URL=$(printf '%s\n' "$output2" | sed -n 's/^dashboard: //p')
  pid2=$(sed -n '1p' "$home/state/.dashboard/service.pid")
  DASHBOARD_PID=$pid2
  PIDS+=("$pid2")
  replay=$(curl -N -fsS --max-time 2 "${DASHBOARD_URL%/}/events?since=0" || true)
  printf '%s' "$replay" | grep -F 'event arrived' >/dev/null \
    || fail "service restart did not replay the durable event outbox: $replay"
  pass "append-only events survive service restart and replay from a cursor"
}

test_snapshot_failure_is_not_healthy() {
  local home output out pid
  home=$(make_home failure)
  export FM_DASHBOARD_SNAPSHOT_TIMEOUT=not-a-duration
  output=$(FM_HOME="$home" FM_DASHBOARD_INCLUDE_PRS=0 FM_STALE_ESCALATE_SECS=1 \
    FM_DASHBOARD_NO_OPEN=1 \
    "$DASHBOARD" start --port 0 --interval 0.1 --no-open --no-prs)
  unset FM_DASHBOARD_SNAPSHOT_TIMEOUT
  DASHBOARD_URL=$(printf '%s\n' "$output" | sed -n 's/^dashboard: //p')
  pid=$(sed -n '1p' "$home/state/.dashboard/service.pid")
  DASHBOARD_PID=$pid
  PIDS+=("$pid")
  out=$(api_snapshot)
  printf '%s' "$out" | jq -e '
    .service.state == "degraded"
    and .supervision.state == "observation-stale"
    and .supervision.watcher_active == false
  ' >/dev/null || fail "stale snapshot was presented as healthy: $out"
  pass "snapshot failures mark the observation stale instead of presenting old health"
}

test_secondmate_child_work_and_events() {
  local home mate out stream gen
  home=$(make_home secondmate)
  : > "$home/data/secondmates.md"
  mate="$TMP_ROOT/secondmate-home"
  make_active_secondmate "$home" "$mate"
  start_dashboard "$home"
  sleep 1
  out=$(api_snapshot)
  printf '%s' "$out" | jq -e '
    .tasks | any(.[]; .id == "mate/child" and .kind == "ship" and .phase == "working")
  ' >/dev/null || fail "validated secondmate child was not rendered: $out"
  printf 'working [key=child]: child event arrived\n' >> "$mate/state/child.status"
  sleep 0.4
  stream=$(curl -N -fsS --max-time 2 "${DASHBOARD_URL%/}/events?since=0" || true)
  printf '%s' "$stream" | grep -F '"task_id": "mate/child"' >/dev/null \
    || fail "secondmate child status event was not delivered: $stream"
  printf '%s' "$stream" | grep -F 'child event arrived' >/dev/null \
    || fail "secondmate child status summary was not delivered: $stream"
  printf 'done [key=child]: child finished\n' >> "$mate/state/child.status"
  sleep 0.4
  stream=$(curl -N -fsS --max-time 2 "${DASHBOARD_URL%/}/events?since=0" || true)
  printf '%s' "$stream" | grep -F '"task_id": "mate/child"' | grep -F 'child finished' >/dev/null \
    || fail "secondmate terminal status event was not delivered while active: $stream"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$mate/state" child)
  "$ROOT/bin/fm-busy-event.sh" apply "$mate/state" child idle --gen "$gen" \
    --source claude-hook --event stop
  sleep 0.4
  jq -e 'has("mate/child") | not' "$home/state/.dashboard/status-cursors.json" >/dev/null \
    || fail "consumed secondmate source was not retired after the child became inactive"
  pass "validated secondmate child work and status events are visible"
}

test_secondmate_terminal_event_survives_restart() {
  local home mate output2 stream pid i
  home=$(make_home secondmate-restart)
  : > "$home/data/secondmates.md"
  mate="$TMP_ROOT/secondmate-restart-home"
  make_active_secondmate "$home" "$mate"
  start_dashboard "$home" 10
  wait_for_snapshot
  wait_for_secondmate_cursor "$home/state/.dashboard" "$mate/state/child.status"
  printf 'done [key=child]: restart child finished\n' >> "$mate/state/child.status"
  kill "$DASHBOARD_PID"
  i=0
  while [ "$i" -lt 40 ] && [ -e "$home/state/.dashboard/service.pid" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  output2=$(FM_HOME="$home" FM_DASHBOARD_INCLUDE_PRS=0 FM_STALE_ESCALATE_SECS=1 \
    FM_DASHBOARD_NO_OPEN=1 "$DASHBOARD" start --port 0 --interval 0.1 --no-open --no-prs)
  DASHBOARD_URL=$(printf '%s\n' "$output2" | sed -n 's/^dashboard: //p')
  pid=$(sed -n '1p' "$home/state/.dashboard/service.pid")
  DASHBOARD_PID=$pid
  PIDS+=("$pid")
  stream=$(curl -N -fsS --max-time 2 "${DASHBOARD_URL%/}/events?since=0" || true)
  printf '%s' "$stream" | grep -F 'restart child finished' >/dev/null \
    || fail "secondmate terminal event was not replayed after restart: $stream"
  pass "persisted secondmate source replays a terminal event after restart"
}

test_public_launcher_snapshot_and_health
test_status_event_cursor_and_restart_replay
test_snapshot_failure_is_not_healthy
test_secondmate_child_work_and_events
test_secondmate_terminal_event_survives_restart
