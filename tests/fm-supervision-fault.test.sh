#!/usr/bin/env bash
# tests/fm-supervision-fault.test.sh - synthetic-home fault injection against recovery paths.
#
# Seeds disposable homes marked .fm-synthetic-home, injects faults observed in
# production supervision incidents, runs the real recovery scripts, and judges
# the result with the supervision oracle. Never touches the live fleet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

ORACLE="$ROOT/bin/fm-supervision-oracle.sh"
RECON="$ROOT/bin/fm-inactive-reconcile.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervision-fault)

assert_present "$ORACLE" "bin/fm-supervision-oracle.sh is missing"
assert_present "$RECON" "bin/fm-inactive-reconcile.sh is missing"

set_mtime() { # <epoch> <path>
  local epoch=$1 path=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$path"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$path"
  fi
}

age_paths() { # <path>...
  local path now
  now=$(( $(date +%s) - 120 ))
  for path in "$@"; do set_mtime "$now" "$path"; done
}

make_fault_home() { # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/projects" "$home/fakebin"
  "$ORACLE" init-synthetic --home "$home" >/dev/null
  make_fake_crew_state "$home/fakebin" >/dev/null
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "list-windows" ]; then
  if [ -n "${FM_FAKE_TMUX_WINDOW:-}" ]; then
    printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"
  fi
  exit 0
fi
if [ "${1:-}" = "display-message" ]; then
  [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
  printf '%%1\n'
  exit 0
fi
if [ "${1:-}" = "capture-pane" ]; then
  if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ]; then
    cat "$FM_FAKE_TMUX_CAPTURE"
  fi
  exit 0
fi
exit 1
SH
  chmod +x "$home/fakebin/tmux"
  printf '%s\n' "$home"
}

make_split_crew_state() { # <fakebin> <id> <state-word> <liveness-word>
  local fakebin=$1 id=$2 state_word=$3 liveness_word=$4
  cat > "$fakebin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
set -u
mode=\${1:-}
id=\${2:-}
case "\$mode" in
  --worker-liveness)
    case "\$id" in
      $id) printf 'liveness: $liveness_word · source: fake\n' ;;
      *) printf 'liveness: unknown · source: none\n' ;;
    esac
    ;;
  *)
    id=\$mode
    case "\$id" in
      $id) printf 'state: $state_word · source: fake\n' ;;
      *) printf 'state: unknown · source: none\n' ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/fm-crew-state.sh"
}

make_absorb_crew_state() { # <fakebin> <state-line>
  local fakebin=$1 line=$2
  cat > "$fakebin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' '$line'
exit 0
SH
  chmod +x "$fakebin/fm-crew-state.sh"
}

seed_task() { # <home> <id> <status-line>
  local home=$1 id=$2 status=$3 repo wt
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
    "yolo=off" \
    "spawn_gen=s${BASHPID:-$$}.$RANDOM" \
    'pr=https://example.test/owner/repo/pull/1'
  printf '%s\n' "$status" > "$home/state/$id.status"
  : > "$home/state/$id.turn-ended"
  age_paths "$home/state/$id.meta" "$home/state/$id.status" "$home/state/$id.turn-ended"
}

mark_live_endpoint() { # <home> <id>
  bash -c '
    home=$1
    lib=$2
    id=$3
    FM_ORACLE_HOME=$home
    FM_ORACLE_STATE=$home/state
    FM_ORACLE_ENDPOINTS=$home/state/.supervision-oracle-endpoints.tsv
    . "$lib"
    fm_oracle_endpoint_set "$id" alive
  ' _ "$1" "$ROOT/bin/fm-supervision-oracle-lib.sh" "$2"
}

set_liveness_truth() { # <home> <id> <live|absent|unknown>
  bash -c '
    home=$1
    lib=$2
    id=$3
    verdict=$4
    FM_ORACLE_HOME=$home
    FM_ORACLE_STATE=$home/state
    FM_ORACLE_LIVENESS=$home/state/.supervision-oracle-liveness.tsv
    . "$lib"
    fm_oracle_liveness_set "$id" "$verdict"
  ' _ "$1" "$ROOT/bin/fm-supervision-oracle-lib.sh" "$2" "$3"
}

run_inactive_reconcile() { # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$TMP_ROOT/root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_CREW_STATE_BIN="${FM_INACTIVE_CREW_STATE_BIN:-$home/fakebin/fm-crew-state.sh}" \
    "$RECON" scan --startup
}

enable_real_crew_state() { # <home>
  local home=$1 fb="$home/fakebin"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        shift
        if [ "${1:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"
        else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
    esac ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes"
  rm -f "$fb/fm-crew-state.sh"
}

make_gate_stall_crew_state() { # <home> <id> <branch> <duration-ms>
  local home=$1 id=$2 branch=$3 duration=$4 head
  enable_real_crew_state "$home"
  head=$(git -C "$home/projects/${id}-wt" rev-parse HEAD)
  export FM_FAKE_AXI_STATUS="run:
  id: \"01RUN\"
  branch: $branch
  status: running
  head: $head
  pr: \"\"
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,$duration"
  export FM_FAKE_RUNS_LIST=""
}

oracle_check() { # <home>
  local home=$1
  FM_ORACLE_CREW_STATE="$home/fakebin/fm-crew-state.sh" \
    "$ORACLE" check --home "$home" 2>&1
}

wake_count() { # <home> <prefix>
  local count
  count=$(grep -c "$2" "$1/state/.wake-queue" 2>/dev/null || true)
  [ -n "$count" ] || count=0
  printf '%s' "$count"
}

# 2026-08-28 incident: inactive-terminal reconciliation presented a failed outcome
# while the worker endpoint was still alive. fm-watch already refuses to trust a
# stale captain-relevant status when crew_is_provably_working; inactive reconcile
# must apply the same worker-liveness contract before queueing presentation.
test_inactive_reconcile_skips_live_worker_with_stale_failed_status() {
  local home
  home=$(make_fault_home inactive-live-failed)
  seed_task "$home" crew 'failed: inactive-terminal false positive'
  mark_live_endpoint "$home" crew
  make_split_crew_state "$home/fakebin" crew failed live
  set_liveness_truth "$home" crew live

  run_inactive_reconcile "$home" >/dev/null

  [ "$(wake_count "$home" 'inactive-outcome:')" = 0 ] \
    || fail "inactive reconcile queued terminal presentation for a live worker"
  [ ! -d "$home/state/terminal-outcomes" ] || [ "$(find "$home/state/terminal-outcomes" -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
    || fail "inactive reconcile retained a terminal receipt for a live worker"

  out=$(oracle_check "$home") || fail "oracle rejected the post-recovery home: $out"
  case "$out" in
    *VIOLATION:*) fail "oracle reported a violation after live-worker guard: $out" ;;
  esac
  pass "inactive reconcile skips stale failed status when worker liveness is live"
}

# The same guard must stay silent on unknown liveness: fm-crew-state treats unknown
# as live until structural absence is proven.
test_inactive_reconcile_skips_unknown_liveness_with_stale_failed_status() {
  local home
  home=$(make_fault_home inactive-unknown-failed)
  seed_task "$home" crew 'failed: ambiguous endpoint'
  mark_live_endpoint "$home" crew
  make_split_crew_state "$home/fakebin" crew failed unknown
  set_liveness_truth "$home" crew unknown

  run_inactive_reconcile "$home" >/dev/null

  [ "$(wake_count "$home" 'inactive-outcome:')" = 0 ] \
    || fail "inactive reconcile queued terminal presentation on unknown liveness"
  pass "inactive reconcile skips stale failed status when worker liveness is unknown"
}

# Genuine structural absence must still reconcile so terminal work is not stranded.
test_inactive_reconcile_still_reports_absent_worker() {
  local home
  home=$(make_fault_home inactive-absent-done)
  seed_task "$home" crew 'done: PR https://example.test/owner/repo/pull/1 checks green'
  make_split_crew_state "$home/fakebin" crew 'done' absent
  set_liveness_truth "$home" crew absent

  run_inactive_reconcile "$home" >/dev/null

  [ "$(wake_count "$home" 'inactive-outcome:')" = 1 ] \
    || fail "inactive reconcile did not present a genuinely absent terminal worker"
  pass "inactive reconcile still presents terminal outcomes for absent workers"
}

# A recycled pooled slot leaves stale metadata on a shared worktree. When the
# displaced endpoint is structurally absent and its status log is terminal,
# inactive reconcile must still present the outcome instead of trusting custody
# loss as a reason to skip reconciliation forever.
test_inactive_reconcile_presents_custody_lost_absent_endpoint() {
  local home json wt repo fb out
  home=$(make_fault_home inactive-custody-absent)
  enable_real_crew_state "$home"
  fb="$home/fakebin"
  repo="$home/projects/shared.git"
  wt="$home/projects/shared-wt"
  fm_git_worktree "$repo" "$wt" "task/new"
  fm_write_meta "$home/state/stale-task.meta" \
    "window=firstmate:fm-stale-task" \
    "endpoint_task_id=stale-task" \
    "worktree=$wt" \
    "project=$home/projects" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=s${BASHPID:-$$}.$RANDOM" \
    "treehouse_slot=slot-1" \
    "treehouse_lease=lease-old"
  fm_write_meta "$home/state/new-task.meta" \
    "window=firstmate:fm-new-task" \
    "endpoint_task_id=new-task" \
    "worktree=$wt" \
    "project=$home/projects" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=s${BASHPID:-$$}.$RANDOM" \
    "treehouse_slot=slot-1" \
    "treehouse_lease=lease-new"
  printf 'failed: pooled slot recycled under me\n' > "$home/state/stale-task.status"
  : > "$home/state/stale-task.turn-ended"
  age_paths "$home/state/stale-task.meta" "$home/state/stale-task.status" "$home/state/stale-task.turn-ended"
  json=$(jq -n --arg path "$wt" --arg lease lease-new --arg holder new-task --arg slot slot-1 \
    '[{name:$slot,path:$path,status:"leased",lease_id:$lease,lease_holder:$holder}]')
  FM_FAKE_TMUX_MISSING=1 FM_INACTIVE_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" \
    FM_CLASSIFY_TREEHOUSE_STATUS_JSON="$json" run_inactive_reconcile "$home" >/dev/null
  [ "$(wake_count "$home" 'inactive-outcome:')" = 1 ] \
    || fail "inactive reconcile did not present a custody-lost terminal worker with an absent endpoint"
  pass "inactive reconcile presents terminal outcomes for custody-lost displaced metadata when the endpoint is absent"
}

# Custody loss must not reopen inactive presentation while the displaced endpoint
# is still live - the 2026-08-28 false-failed guard still applies.
test_inactive_reconcile_skips_custody_lost_with_live_endpoint() {
  local home json wt repo fb
  home=$(make_fault_home inactive-custody-live)
  enable_real_crew_state "$home"
  repo="$home/projects/shared.git"
  wt="$home/projects/shared-wt"
  fm_git_worktree "$repo" "$wt" "task/new"
  fm_write_meta "$home/state/stale-task.meta" \
    "window=firstmate:fm-stale-task" \
    "endpoint_task_id=stale-task" \
    "worktree=$wt" \
    "project=$home/projects" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=s${BASHPID:-$$}.$RANDOM" \
    "treehouse_slot=slot-1" \
    "treehouse_lease=lease-old"
  fm_write_meta "$home/state/new-task.meta" \
    "window=firstmate:fm-new-task" \
    "endpoint_task_id=new-task" \
    "worktree=$wt" \
    "project=$home/projects" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=s${BASHPID:-$$}.$RANDOM" \
    "treehouse_slot=slot-1" \
    "treehouse_lease=lease-new"
  printf 'failed: pooled slot recycled under me\n' > "$home/state/stale-task.status"
  : > "$home/state/stale-task.turn-ended"
  age_paths "$home/state/stale-task.meta" "$home/state/stale-task.status" "$home/state/stale-task.turn-ended"
  json=$(jq -n --arg path "$wt" --arg lease lease-new --arg holder new-task --arg slot slot-1 \
    '[{name:$slot,path:$path,status:"leased",lease_id:$lease,lease_holder:$holder}]')
  FM_FAKE_TMUX_MISSING=0 FM_INACTIVE_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" \
    FM_CLASSIFY_TREEHOUSE_STATUS_JSON="$json" run_inactive_reconcile "$home" >/dev/null
  [ "$(wake_count "$home" 'inactive-outcome:')" = 0 ] \
    || fail "inactive reconcile presented a terminal outcome for custody-lost metadata with a live endpoint"
  pass "inactive reconcile skips custody-lost displaced metadata when the endpoint is still live"
}

# 2026-08 incident: away-mode classify_stale escalated stale terminal status
# immediately while no-mistakes validation was still running. fm-watch already
# honors crew_is_provably_working on that path; the daemon must match it.
# 2026-08 incident: away-mode heartbeat catch-all and signal paths escalated stale
# terminal status while no-mistakes validation was still running.
test_afk_catchall_skips_terminal_when_crew_is_provably_working() {
  local home fakebin out
  home=$(make_fault_home afk-catchall-validating)
  seed_task "$home" crew 'done: implementation complete, ready to validate'
  mark_live_endpoint "$home" crew
  fakebin="$home/fakebin"
  make_absorb_crew_state "$fakebin" 'state: working · source: run-step · validating (running)'
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$ROOT/bin/fm-supervise-daemon.sh"
  rm -f "$home/state/.subsuper-last-scan"
  PATH="$fakebin:$PATH" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STATE_OVERRIDE="$home/state" housekeeping "$home/state"
  [ ! -s "$home/state/.subsuper-escalations" ] \
    || fail "catch-all scan escalated a validating crew in the fault home"
  out=$(PATH="$fakebin:$PATH" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STATE_OVERRIDE="$home/state" classify_signal "$home/state/crew.status" "$home/state")
  case "$out" in
    self\|*) ;;
    escalate\|*) fail "classify_signal escalated validating crew in fault home: $out" ;;
    *) fail "unexpected classify_signal verdict: $out" ;;
  esac
  out=$(oracle_check "$home") || fail "oracle rejected the post-triage home: $out"
  case "$out" in
    *VIOLATION:*) fail "oracle reported a violation after catch-all guard: $out" ;;
  esac
  pass "afk catch-all and signal paths skip terminal status when crew is provably working"
}

test_afk_stale_terminal_absorbed_when_crew_is_provably_working() {
  local home fakebin out key win
  home=$(make_fault_home afk-stale-terminal-override)
  seed_task "$home" crew 'done: implementation complete, ready to validate'
  mark_live_endpoint "$home" crew
  fakebin="$home/fakebin"
  win="firstmate:fm-crew"
  make_absorb_crew_state "$fakebin" 'state: working · source: run-step · validating (running)'
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$ROOT/bin/fm-supervise-daemon.sh"
  out=$(PATH="$fakebin:$PATH" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STATE_OVERRIDE="$home/state" classify_stale "$win" "$home/state")
  case "$out" in
    self\|*overridden*) ;;
    escalate\|*) fail "afk classify_stale escalated a validating crew with stale done: status: $out" ;;
    *) fail "unexpected afk classify_stale verdict: $out" ;;
  esac
  PATH="$fakebin:$PATH" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STATE_OVERRIDE="$home/state" handle_wake "stale: $win" "$home/state"
  key=$(printf '%s' "crew" | tr ':/.' '___')
  [ -e "$home/state/.subsuper-stale-$key" ] \
    || fail "afk stale override did not record a wedge marker"
  [ ! -s "$home/state/.subsuper-escalations" ] \
    || fail "afk stale override queued an immediate escalation"
  out=$(oracle_check "$home") || fail "oracle rejected the post-triage home: $out"
  case "$out" in
    *VIOLATION:*) fail "oracle reported a violation after afk stale override: $out" ;;
  esac
  pass "afk classify_stale absorbs stale terminal status when crew is provably working"
}

# 2026-08 incident: fm-watch's heartbeat fleet-scan backstop escalated stale done:
# status while no-mistakes validation was still running. classify_stale already
# absorbs that line without marking it surfaced; the heartbeat backstop must
# honor crew_is_provably_working too.
test_watch_heartbeat_skips_provably_working_terminal() {
  local home fakebin out window key sig pid
  home=$(make_fault_home watch-heartbeat-validating)
  fakebin="$home/fakebin"
  out="$home/watch.out"
  window="firstmate:fm-crew"
  seed_task "$home" crew 'done: implementation complete, ready to validate'
  mark_live_endpoint "$home" crew
  printf 'window=%s\n' "$window" >> "$home/state/crew.meta"
  sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$home/state/crew.status" 2>/dev/null; else stat -c '%s:%Y' "$home/state/crew.status" 2>/dev/null; fi)
  printf '%s' "$sig" > "$home/state/.seen-crew_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "no-mistakes axi run: validating...")" > "$home/state/.stale-$key"
  date +%s > "$home/state/.stale-since-$key"
  touch "$home/state/.last-heartbeat"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" \
    FM_FAKE_TMUX_CAPTURE="$home/pane.txt" FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_STALE_ESCALATE_SECS=999999 \
    "$WATCH" > "$out" &
  pid=$!
  local beat first now i=0
  beat="$home/state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt 300 ]; do
    kill -0 "$pid" 2>/dev/null || break
    if [ -f "$beat" ]; then
      now=$(if [ "$(uname)" = Darwin ]; then stat -f '%m' "$beat" 2>/dev/null; else stat -c '%Y' "$beat" 2>/dev/null; fi)
      if [ -n "$first" ] && [ -n "$now" ] && [ "$now" != "$first" ]; then
        break
      fi
      [ -z "$first" ] && [ -n "$now" ] && first=$now
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || fail "watch heartbeat backstop surfaced a validating crew: $(cat "$out")"
  [ ! -s "$out" ] || fail "watch heartbeat backstop printed a wake for a validating crew: $(cat "$out")"
  [ ! -s "$home/state/.wake-queue" ] || fail "watch heartbeat backstop enqueued a wake for a validating crew"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  unset FM_FAKE_CREW_STATE
  oracle_check "$home" >/dev/null || fail "oracle rejected the post-triage home"
  pass "watch heartbeat backstop skips terminal status when crew is provably working"
}

# 2026-08 incident: fm-watch's signal triage short-circuited on
# signal_reason_is_actionable for a coalesced status+turn-end batch while
# no-mistakes validation was still running. classify_signal already honors
# crew_is_provably_working; signal_reason_is_actionable must match it.
test_watch_signal_skips_provably_working_terminal() {
  local home fakebin out status_file pid
  home=$(make_fault_home watch-signal-validating)
  fakebin="$home/fakebin"
  out="$home/watch.out"
  status_file="$home/state/crew.status"
  seed_task "$home" crew 'done: implementation complete, ready to validate'
  mark_live_endpoint "$home" crew
  : > "$home/state/crew.turn-ended"
  make_absorb_crew_state "$fakebin" 'state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="firstmate:fm-crew" \
    FM_FAKE_TMUX_CAPTURE="$home/pane.txt" FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  pid=$!
  local beat first now i=0
  beat="$home/state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt 300 ]; do
    kill -0 "$pid" 2>/dev/null || break
    if [ -f "$beat" ]; then
      now=$(if [ "$(uname)" = Darwin ]; then stat -f '%m' "$beat" 2>/dev/null; else stat -c '%Y' "$beat" 2>/dev/null; fi)
      if [ -n "$first" ] && [ -n "$now" ] && [ "$now" != "$first" ]; then
        break
      fi
      [ -z "$first" ] && [ -n "$now" ] && first=$now
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || fail "watch signal triage surfaced a validating crew: $(cat "$out")"
  [ ! -s "$out" ] || fail "watch signal triage printed a wake for a validating crew: $(cat "$out")"
  [ ! -s "$home/state/.wake-queue" ] || fail "watch signal triage enqueued a wake for a validating crew"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  oracle_check "$home" >/dev/null || fail "oracle rejected the post-triage home"
  pass "watch signal triage skips terminal status when crew is provably working"
}

# 2026-08 incident: away-mode handle_wake force-escalated enriched fm-watch wedge
# wakes while no-mistakes validation was still running. classify_stale already
# honors crew_is_provably_working; the stale_detail replay override must too.
test_afk_wedge_wake_skips_terminal_when_crew_is_provably_working() {
  local home fakebin out win reason key
  home=$(make_fault_home afk-wedge-validating)
  seed_task "$home" crew 'done: implementation complete, ready to validate'
  mark_live_endpoint "$home" crew
  fakebin="$home/fakebin"
  win="firstmate:fm-crew"
  make_absorb_crew_state "$fakebin" 'state: working · source: run-step · validating (running)'
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$ROOT/bin/fm-supervise-daemon.sh"
  reason="stale: $win (idle 500s, possible wedge, escalation 1)"
  PATH="$fakebin:$PATH" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STATE_OVERRIDE="$home/state" handle_wake "$reason" "$home/state"
  [ ! -s "$home/state/.subsuper-escalations" ] \
    || fail "afk wedge wake force-escalated a validating crew in fault home"
  key=$(printf '%s' "crew" | tr ':/.' '___')
  [ -e "$home/state/.subsuper-stale-$key" ] \
    || fail "afk wedge wake did not record a wedge marker for a validating crew"
  out=$(oracle_check "$home") || fail "oracle rejected the post-triage home: $out"
  case "$out" in
    *VIOLATION:*) fail "oracle reported a violation after wedge wake guard: $out" ;;
  esac
  pass "afk wedge wake skips terminal status when crew is provably working"
}

# 2026-08 incident: herdr's blocked fast-path escalated stale terminal status
# while no-mistakes validation was still running. classify_stale already
# honors crew_is_provably_working; handle_push_transition must match it.
test_push_transition_skips_provably_working_terminal() {
  local home fakebin out rec
  home=$(make_fault_home push-validating)
  seed_task "$home" crew 'done: implementation complete, ready to validate'
  mark_live_endpoint "$home" crew
  fakebin="$home/fakebin"
  make_absorb_crew_state "$fakebin" 'state: working · source: run-step · validating (running)'
  # shellcheck source=bin/fm-transition-lib.sh
  . "$ROOT/bin/fm-transition-lib.sh"
  rec=$(fm_transition_record "fm-crew" "firstmate" "" "blocked" "claude")
  FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" FM_ROOT_OVERRIDE="$TMP_ROOT/root" \
    PATH="$fakebin:$PATH" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    bash -c '
      home=$1
      lib=$2
      rec=$3
      . "$lib"
      wake() { printf "%s\n" "$1" > "$home/push.out"; return 0; }
      handle_push_transition herdr firstmate "$rec"
    ' _ "$home" "$ROOT/bin/fm-push-transition-lib.sh" "$rec"
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "push transition queued a wake for a validating crew in the fault home"
  [ ! -s "$home/push.out" ] \
    || fail "push transition surfaced a validating crew in the fault home: $(cat "$home/push.out")"
  out=$(oracle_check "$home") || fail "oracle rejected the post-triage home: $out"
  case "$out" in
    *VIOLATION:*) fail "oracle reported a violation after push-transition guard: $out" ;;
  esac
  pass "push transition skips terminal status when crew is provably working"
}

# 2026-08 incident: away-mode persistence recheck escalated stale terminal
# status while no-mistakes validation was still running. classify_stale and the
# catch-all scan already honor crew_is_provably_working; housekeeping must too.
test_afk_persistence_skips_terminal_when_crew_is_provably_working() {
  local home fakebin out key win
  home=$(make_fault_home afk-persistence-validating)
  seed_task "$home" crew 'done: implementation complete, ready to validate'
  mark_live_endpoint "$home" crew
  fakebin="$home/fakebin"
  win="firstmate:fm-crew"
  make_absorb_crew_state "$fakebin" 'state: working · source: run-step · validating (running)'
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$ROOT/bin/fm-supervise-daemon.sh"
  out=$(PATH="$fakebin:$PATH" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STATE_OVERRIDE="$home/state" classify_stale "$win" "$home/state")
  case "$out" in
    self\|*overridden*) ;;
    escalate\|*) fail "afk classify_stale escalated a validating crew in fault home: $out" ;;
    *) fail "unexpected afk classify_stale verdict: $out" ;;
  esac
  PATH="$fakebin:$PATH" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STATE_OVERRIDE="$home/state" handle_wake "stale: $win" "$home/state"
  key=$(printf '%s' "crew" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$home/state/.subsuper-stale-$key"
  PATH="$fakebin:$PATH" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STATE_OVERRIDE="$home/state" FM_STALE_ESCALATE_SECS=240 housekeeping "$home/state"
  [ ! -s "$home/state/.subsuper-escalations" ] \
    || fail "afk persistence recheck escalated a validating crew in fault home"
  out=$(oracle_check "$home") || fail "oracle rejected the post-triage home: $out"
  case "$out" in
    *VIOLATION:*) fail "oracle reported a violation after persistence guard: $out" ;;
  esac
  pass "afk persistence recheck skips terminal status when crew is provably working"
}

# 2026-08 incident: signal, catch-all, and heartbeat paths only honored
# crew_is_provably_working for standard terminal verbs, so a leftover legacy
# free-text captain line such as "PR ready" still escalated during validation.
test_legacy_captain_signal_skips_provably_working() {
  local home fakebin out
  home=$(make_fault_home legacy-signal-validating)
  seed_task "$home" crew 'PR ready https://example.com/pull/1'
  mark_live_endpoint "$home" crew
  fakebin="$home/fakebin"
  make_absorb_crew_state "$fakebin" 'state: working · source: run-step · validating (running)'
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$ROOT/bin/fm-supervise-daemon.sh"
  out=$(PATH="$fakebin:$PATH" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STATE_OVERRIDE="$home/state" classify_signal "$home/state/crew.status" "$home/state")
  case "$out" in
    self\|*) ;;
    escalate\|*) fail "classify_signal escalated validating crew with legacy PR ready status: $out" ;;
    *) fail "unexpected classify_signal verdict: $out" ;;
  esac
  rm -f "$home/state/.subsuper-last-scan"
  PATH="$fakebin:$PATH" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STATE_OVERRIDE="$home/state" housekeeping "$home/state"
  [ ! -s "$home/state/.subsuper-escalations" ] \
    || fail "catch-all scan escalated a validating crew with legacy PR ready status"
  out=$(oracle_check "$home") || fail "oracle rejected the post-triage home: $out"
  case "$out" in
    *VIOLATION:*) fail "oracle reported a violation after legacy captain guard: $out" ;;
  esac
  pass "legacy captain-relevant signal and catch-all paths skip status when crew is provably working"
}

# 2026-08 incident: away-mode persistence recheck wedge-escalated a quiet pane
# while the crew was still writing its worktree behind an idle composer.
test_afk_persistence_defers_while_worktree_is_written() {
  local home fakebin out win key wt back watcher_key
  home=$(make_fault_home afk-persistence-writing)
  fakebin="$home/fakebin"
  win="firstmate:fm-crew"
  wt="$home/projects/crew-wt"
  seed_task "$home" crew 'working: implementing'
  mark_live_endpoint "$home" crew
  mkdir -p "$wt/src"
  back=$(( $(date +%s) - 500 ))
  key=$(printf '%s' "crew" | tr ':/.' '___')
  watcher_key=$(printf '%s' "$win" | tr ':/.' '___')
  echo "$back" > "$home/state/.subsuper-stale-$key"
  set_mtime "$back" "$home/state/.subsuper-stale-$key"
  printf 'idle building output\n' > "$home/pane.txt"
  printf 'int main(void) { return 0; }\n' > "$wt/src/main.c"
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$ROOT/bin/fm-supervise-daemon.sh"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" \
    FM_FAKE_TMUX_CAPTURE="$home/pane.txt" FM_STATE_OVERRIDE="$home/state" \
    FM_STALE_ESCALATE_SECS=240 housekeeping "$home/state"
  [ ! -s "$home/state/.subsuper-escalations" ] \
    || fail "afk persistence recheck wedge-escalated a quiet pane whose worktree was being written"
  [ -e "$home/state/.writing-since-$watcher_key" ] \
    || fail "afk write deferral did not record the deferral chain marker"
  out=$(oracle_check "$home") || fail "oracle rejected the post-triage home: $out"
  case "$out" in
    *VIOLATION:*) fail "oracle reported a violation after write deferral: $out" ;;
  esac
  pass "afk persistence recheck defers a quiet writing worktree"
}

# 2026-08 incident: a quiet pane with an idle composer while the crew was still
# writing its worktree. wedge_timer_check already deferred repeat polls, but
# first-sight non-terminal stale with inconclusive crew state surfaced immediately.
test_watch_nonterminal_worktree_write_defers_when_crew_inconclusive() {
  local home fakebin out window key wt back pane_hash pid
  home=$(make_fault_home watch-writing-inconclusive)
  fakebin="$home/fakebin"
  out="$home/watch.out"
  window="firstmate:fm-crew"
  wt="$home/projects/crew-wt"
  seed_task "$home" crew 'working: implementing'
  mark_live_endpoint "$home" crew
  mkdir -p "$wt/src"
  back=$(( $(date +%s) - 120 ))
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf 'idle building output\n' > "$home/pane.txt"
  sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$home/state/crew.status" 2>/dev/null; else stat -c '%s:%Y' "$home/state/crew.status" 2>/dev/null; fi)
  printf '%s' "$sig" > "$home/state/.seen-crew_status"
  sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$home/state/crew.turn-ended" 2>/dev/null; else stat -c '%s:%Y' "$home/state/crew.turn-ended" 2>/dev/null; fi)
  printf '%s' "$sig" > "$home/state/.seen-crew_turn-ended"
  printf '%s' "$pane_hash" > "$home/state/.hash-$key"
  printf '1\n' > "$home/state/.count-$key"
  set_mtime "$back" "$home/state/.hash-$key"
  printf 'int main(void) { return 0; }\n' > "$wt/src/main.c"
  make_absorb_crew_state "$fakebin" 'state: unknown · source: none · inconclusive pane'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" \
    FM_FAKE_TMUX_CAPTURE="$home/pane.txt" FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_STALE_ESCALATE_SECS=999 \
    "$WATCH" > "$out" &
  pid=$!
  local beat first now i=0
  beat="$home/state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt 300 ]; do
    kill -0 "$pid" 2>/dev/null || break
    if [ -f "$beat" ]; then
      now=$(if [ "$(uname)" = Darwin ]; then stat -f '%m' "$beat" 2>/dev/null; else stat -c '%Y' "$beat" 2>/dev/null; fi)
      if [ -n "$first" ] && [ -n "$now" ] && [ "$now" != "$first" ]; then
        break
      fi
      [ -z "$first" ] && [ -n "$now" ] && first=$now
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || fail "watch surfaced a quiet writing crew with inconclusive state: $(cat "$out")"
  [ ! -s "$out" ] || fail "watch printed a wake for a quiet writing crew with inconclusive state: $(cat "$out")"
  [ ! -s "$home/state/.wake-queue" ] || fail "watch enqueued a wake for a quiet writing crew with inconclusive state"
  [ -e "$home/state/.stale-since-$key" ] \
    || fail "watch did not start the wedge timer for a quiet writing crew with inconclusive state"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  oracle_check "$home" >/dev/null || fail "oracle rejected the post-triage home"
  pass "watch defers first-sight non-terminal stale when the worktree was written since idle"
}

# 2026-08 incident: a quiet pane with stale done: status and an idle composer
# while the crew was still writing its worktree. Iteration 13 fixed the
# non-terminal first-sight path; the terminal first-sight path had the same gap.
test_watch_terminal_worktree_write_defers_when_crew_inconclusive() {
  local home fakebin out window key wt back pane_hash pid
  home=$(make_fault_home watch-terminal-writing-inconclusive)
  fakebin="$home/fakebin"
  out="$home/watch.out"
  window="firstmate:fm-crew"
  wt="$home/projects/crew-wt"
  seed_task "$home" crew 'done: implementation complete, ready to validate'
  mark_live_endpoint "$home" crew
  mkdir -p "$wt/src"
  back=$(( $(date +%s) - 120 ))
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf 'idle building output\n' > "$home/pane.txt"
  sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$home/state/crew.status" 2>/dev/null; else stat -c '%s:%Y' "$home/state/crew.status" 2>/dev/null; fi)
  printf '%s' "$sig" > "$home/state/.seen-crew_status"
  sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$home/state/crew.turn-ended" 2>/dev/null; else stat -c '%s:%Y' "$home/state/crew.turn-ended" 2>/dev/null; fi)
  printf '%s' "$sig" > "$home/state/.seen-crew_turn-ended"
  printf '%s' "$pane_hash" > "$home/state/.hash-$key"
  printf '1\n' > "$home/state/.count-$key"
  set_mtime "$back" "$home/state/.hash-$key"
  printf 'int main(void) { return 0; }\n' > "$wt/src/main.c"
  make_absorb_crew_state "$fakebin" 'state: unknown · source: none · inconclusive pane'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" \
    FM_FAKE_TMUX_CAPTURE="$home/pane.txt" FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_STALE_ESCALATE_SECS=999 \
    "$WATCH" > "$out" &
  pid=$!
  local beat first now i=0
  beat="$home/state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt 300 ]; do
    kill -0 "$pid" 2>/dev/null || break
    if [ -f "$beat" ]; then
      now=$(if [ "$(uname)" = Darwin ]; then stat -f '%m' "$beat" 2>/dev/null; else stat -c '%Y' "$beat" 2>/dev/null; fi)
      if [ -n "$first" ] && [ -n "$now" ] && [ "$now" != "$first" ]; then
        break
      fi
      [ -z "$first" ] && [ -n "$now" ] && first=$now
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || fail "watch surfaced a quiet writing crew with stale done: status: $(cat "$out")"
  [ ! -s "$out" ] || fail "watch printed a wake for a quiet writing crew with stale done: status: $(cat "$out")"
  [ ! -s "$home/state/.wake-queue" ] || fail "watch enqueued a wake for a quiet writing crew with stale done: status"
  [ -e "$home/state/.stale-since-$key" ] \
    || fail "watch did not start the wedge timer for a quiet writing crew with stale done: status"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  oracle_check "$home" >/dev/null || fail "oracle rejected the post-triage home"
  pass "watch defers first-sight terminal stale when the worktree was written since idle"
}

# 2026-08 incident: away-mode signal triage escalated stale done: status while
# the crew was still writing its worktree. classify_stale and the catch-all
# scan already defer on crew_worktree_written_since; classify_signal must match.
# 2026-08 incident: fm-watch signal triage escalated stale done: status while
# the crew was still writing its worktree. classify_signal already defers on
# crew_worktree_written_since; signal_reason_is_actionable must match.
test_watch_signal_defers_terminal_when_worktree_written_inconclusive() {
  local home fakebin out wt back status_file turn_file pid
  home=$(make_fault_home watch-signal-writing-inconclusive)
  fakebin="$home/fakebin"
  out="$home/watch.out"
  wt="$home/projects/crew-wt"
  seed_task "$home" crew 'done: implementation complete, ready to validate'
  mark_live_endpoint "$home" crew
  back=$(( $(date +%s) - 500 ))
  status_file="$home/state/crew.status"
  set_mtime "$back" "$status_file"
  printf 'done: implementation complete, ready to validate\n' > "$status_file"
  mkdir -p "$wt/src"
  printf 'int main(void) { return 0; }\n' > "$wt/src/main.c"
  turn_file="$home/state/crew.turn-ended"
  : > "$turn_file"
  sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$status_file" 2>/dev/null; else stat -c '%s:%Y' "$status_file" 2>/dev/null; fi)
  printf '%s' "$sig" > "$home/state/.seen-crew_status"
  sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$turn_file" 2>/dev/null; else stat -c '%s:%Y' "$turn_file" 2>/dev/null; fi)
  printf '%s' "$sig" > "$home/state/.seen-crew_turn-ended"
  make_absorb_crew_state "$fakebin" 'state: unknown · source: none · inconclusive pane'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="firstmate:fm-crew" \
    FM_FAKE_TMUX_CAPTURE="$home/pane.txt" FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  pid=$!
  local beat first now i=0
  beat="$home/state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt 300 ]; do
    kill -0 "$pid" 2>/dev/null || break
    if [ -f "$beat" ]; then
      now=$(if [ "$(uname)" = Darwin ]; then stat -f '%m' "$beat" 2>/dev/null; else stat -c '%Y' "$beat" 2>/dev/null; fi)
      if [ -n "$first" ] && [ -n "$now" ] && [ "$now" != "$first" ]; then
        break
      fi
      [ -z "$first" ] && [ -n "$now" ] && first=$now
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || fail "watch signal triage surfaced a writing crew with stale done: status: $(cat "$out")"
  [ ! -s "$out" ] || fail "watch printed a wake for a writing crew with stale done: status: $(cat "$out")"
  [ ! -s "$home/state/.wake-queue" ] || fail "watch enqueued a wake for a writing crew with stale done: status"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  oracle_check "$home" >/dev/null || fail "oracle rejected the post-triage home"
  pass "watch signal triage defers terminal status when the worktree was written since the status file"
}

# 2026-08 incident: fm-watch heartbeat backstop escalated stale done: status while
# the crew was still writing its worktree. classify_stale and the daemon catch-all
# already defer on crew_worktree_written_since; heartbeat_scan_finds_actionable must match.
test_watch_heartbeat_defers_terminal_when_worktree_written_inconclusive() {
  local home fakebin out wt back window key pane_hash pid
  home=$(make_fault_home watch-heartbeat-writing-inconclusive)
  fakebin="$home/fakebin"
  out="$home/watch.out"
  window="firstmate:fm-crew"
  wt="$home/projects/crew-wt"
  seed_task "$home" crew 'done: implementation complete, ready to validate'
  mark_live_endpoint "$home" crew
  back=$(( $(date +%s) - 500 ))
  set_mtime "$back" "$home/state/crew.status"
  printf 'done: implementation complete, ready to validate\n' > "$home/state/crew.status"
  mkdir -p "$wt/src"
  printf 'int main(void) { return 0; }\n' > "$wt/src/main.c"
  sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$home/state/crew.status" 2>/dev/null; else stat -c '%s:%Y' "$home/state/crew.status" 2>/dev/null; fi)
  printf '%s' "$sig" > "$home/state/.seen-crew_status"
  sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$home/state/crew.turn-ended" 2>/dev/null; else stat -c '%s:%Y' "$home/state/crew.turn-ended" 2>/dev/null; fi)
  printf '%s' "$sig" > "$home/state/.seen-crew_turn-ended"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$home/state/.stale-$key"
  date +%s > "$home/state/.stale-since-$key"
  touch "$home/state/.last-heartbeat"
  make_absorb_crew_state "$fakebin" 'state: unknown · source: none · inconclusive pane'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" \
    FM_FAKE_TMUX_CAPTURE="$home/pane.txt" FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_STALE_ESCALATE_SECS=999999 \
    "$WATCH" > "$out" &
  pid=$!
  local beat first now i=0
  beat="$home/state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt 300 ]; do
    kill -0 "$pid" 2>/dev/null || break
    if [ -f "$beat" ]; then
      now=$(if [ "$(uname)" = Darwin ]; then stat -f '%m' "$beat" 2>/dev/null; else stat -c '%Y' "$beat" 2>/dev/null; fi)
      if [ -n "$first" ] && [ -n "$now" ] && [ "$now" != "$first" ]; then
        break
      fi
      [ -z "$first" ] && [ -n "$now" ] && first=$now
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || fail "watch heartbeat backstop surfaced a writing crew with stale done: status: $(cat "$out")"
  [ ! -s "$out" ] || fail "watch heartbeat backstop printed a wake for a writing crew: $(cat "$out")"
  [ ! -s "$home/state/.wake-queue" ] || fail "watch heartbeat backstop enqueued a wake for a writing crew"
  [ ! -e "$home/state/.hb-surfaced-crew" ] \
    || fail "watch heartbeat backstop marked a writing crew's terminal status as surfaced"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  oracle_check "$home" >/dev/null || fail "oracle rejected the post-triage home"
  pass "watch heartbeat backstop defers terminal status when the worktree was written since the status file"
}

# 2026-08 incident: herdr's blocked fast-path escalated stale done: status while
# the crew was still writing its worktree. classify_stale and the daemon catch-all
# already defer on crew_worktree_written_since; handle_push_transition must match.
test_push_transition_defers_terminal_when_worktree_written_inconclusive() {
  local home fakebin out rec wt back
  home=$(make_fault_home push-writing-inconclusive)
  fakebin="$home/fakebin"
  wt="$home/projects/crew-wt"
  seed_task "$home" crew 'done: implementation complete, ready to validate'
  mark_live_endpoint "$home" crew
  back=$(( $(date +%s) - 500 ))
  set_mtime "$back" "$home/state/crew.status"
  printf 'done: implementation complete, ready to validate\n' > "$home/state/crew.status"
  mkdir -p "$wt/src"
  printf 'int main(void) { return 0; }\n' > "$wt/src/main.c"
  make_absorb_crew_state "$fakebin" 'state: unknown · source: none · inconclusive pane'
  # shellcheck source=bin/fm-transition-lib.sh
  . "$ROOT/bin/fm-transition-lib.sh"
  rec=$(fm_transition_record "fm-crew" "firstmate" "" "blocked" "claude")
  FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" FM_ROOT_OVERRIDE="$TMP_ROOT/root" \
    PATH="$fakebin:$PATH" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    bash -c '
      home=$1
      lib=$2
      rec=$3
      . "$lib"
      wake() { printf "%s\n" "$1" > "$home/push.out"; return 0; }
      handle_push_transition herdr firstmate "$rec"
    ' _ "$home" "$ROOT/bin/fm-push-transition-lib.sh" "$rec"
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "push transition queued a wake for a writing crew in the fault home"
  [ ! -s "$home/push.out" ] \
    || fail "push transition surfaced a writing crew in the fault home: $(cat "$home/push.out")"
  out=$(oracle_check "$home") || fail "oracle rejected the post-triage home: $out"
  case "$out" in
    *VIOLATION:*) fail "oracle reported a violation after push-transition worktree-write guard: $out" ;;
  esac
  pass "push transition defers terminal status when the worktree was written since the status file"
}

# 2026-08 incident: a pooled worktree slot was recycled while stale metadata still
# pointed at the same path. fm-crew-state must not attribute the new holder's
# no-mistakes run to the displaced task, or supervision will treat it as working.
test_recycled_slot_blocks_provably_working_misattribution() {
  local home json wt repo fb out
  home=$(make_fault_home recycled-slot-misattr)
  fb="$home/fakebin"
  repo="$home/projects/shared.git"
  wt="$home/projects/shared-wt"
  fm_git_worktree "$repo" "$wt" "task/new"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        shift
        if [ "${1:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"
        else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
    esac ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  fm_write_meta "$home/state/stale-task.meta" \
    "window=firstmate:fm-stale-task" \
    "endpoint_task_id=stale-task" \
    "worktree=$wt" \
    "project=$home/projects" \
    "harness=codex" \
    "kind=ship" \
    "treehouse_slot=slot-1" \
    "treehouse_lease=lease-old"
  fm_write_meta "$home/state/new-task.meta" \
    "window=firstmate:fm-new-task" \
    "endpoint_task_id=new-task" \
    "worktree=$wt" \
    "project=$home/projects" \
    "harness=codex" \
    "kind=ship" \
    "treehouse_slot=slot-1" \
    "treehouse_lease=lease-new"
  printf 'done: stale terminal before recycle\n' > "$home/state/stale-task.status"
  json=$(jq -n --arg path "$wt" --arg lease lease-new --arg holder new-task --arg slot slot-1 \
    '[{name:$slot,path:$path,status:"leased",lease_id:$lease,lease_holder:$holder}]')
  FM_FAKE_AXI_STATUS="run: validating-1
  branch: task/new
  head: $(git -C "$wt" rev-parse HEAD)
  state: running
  step: ci"
  FM_FAKE_RUNS_LIST=""
  export FM_FAKE_AXI_STATUS FM_FAKE_RUNS_LIST
  out=$(PATH="$fb:$PATH" FM_STATE_OVERRIDE="$home/state" FM_CLASSIFY_TREEHOUSE_STATUS_JSON="$json" \
    FM_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" \
    bash -c 'home=$1; lib=$2; . "$lib"; crew_is_provably_working stale-task && printf yes || printf no' \
    _ "$home" "$ROOT/bin/fm-classify-lib.sh")
  [ "$out" = no ] \
    || fail "recycled slot made the displaced task provably working from the new holder's run"
  pass "recycled pooled slot blocks provably-working misattribution on displaced metadata"
}

# 2026-08 incident: a recycled pooled slot left stale metadata on a worktree the
# new holder was actively writing. crew_worktree_written_since must not treat those
# writes as evidence the displaced task is still live, or supervision defers forever.
test_recycled_slot_blocks_worktree_write_deferral() {
  local home json wt repo fb out back
  home=$(make_fault_home recycled-slot-write-defer)
  fb="$home/fakebin"
  repo="$home/projects/shared.git"
  wt="$home/projects/shared-wt"
  fm_git_worktree "$repo" "$wt" "task/new"
  fm_write_meta "$home/state/stale-task.meta" \
    "window=firstmate:fm-stale-task" \
    "endpoint_task_id=stale-task" \
    "worktree=$wt" \
    "project=$home/projects" \
    "harness=codex" \
    "kind=ship" \
    "treehouse_slot=slot-1" \
    "treehouse_lease=lease-old"
  fm_write_meta "$home/state/new-task.meta" \
    "window=firstmate:fm-new-task" \
    "endpoint_task_id=new-task" \
    "worktree=$wt" \
    "project=$home/projects" \
    "harness=codex" \
    "kind=ship" \
    "treehouse_slot=slot-1" \
    "treehouse_lease=lease-new"
  back=$(( $(date +%s) - 120 ))
  set_mtime "$back" "$home/state/stale-task.status"
  printf 'done: stale terminal before recycle\n' > "$home/state/stale-task.status"
  mkdir -p "$wt/src"
  printf 'int main(void) { return 0; }\n' > "$wt/src/main.c"
  json=$(jq -n --arg path "$wt" --arg lease lease-new --arg holder new-task --arg slot slot-1 \
    '[{name:$slot,path:$path,status:"leased",lease_id:$lease,lease_holder:$holder}]')
  out=$(PATH="$fb:$PATH" FM_STATE_OVERRIDE="$home/state" FM_CLASSIFY_TREEHOUSE_STATUS_JSON="$json" \
    bash -c 'home=$1; lib=$2; . "$lib"; crew_worktree_written_since stale-task "$home/state" "$home/state/stale-task.status" && printf yes || printf no' \
    _ "$home" "$ROOT/bin/fm-classify-lib.sh")
  [ "$out" = no ] \
    || fail "recycled slot made the displaced task defer on the new holder's writes"
  pass "recycled pooled slot blocks worktree-write deferral on displaced metadata"
}

test_afk_signal_defers_terminal_when_worktree_written_inconclusive() {
  local home fakebin out wt back
  home=$(make_fault_home afk-signal-writing-inconclusive)
  fakebin="$home/fakebin"
  wt="$home/projects/crew-wt"
  seed_task "$home" crew 'done: implementation complete, ready to validate'
  mark_live_endpoint "$home" crew
  back=$(( $(date +%s) - 500 ))
  set_mtime "$back" "$home/state/crew.status"
  printf 'done: implementation complete, ready to validate\n' > "$home/state/crew.status"
  mkdir -p "$wt/src"
  printf 'int main(void) { return 0; }\n' > "$wt/src/main.c"
  make_absorb_crew_state "$fakebin" 'state: unknown · source: none · inconclusive pane'
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$ROOT/bin/fm-supervise-daemon.sh"
  out=$(PATH="$fakebin:$PATH" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STATE_OVERRIDE="$home/state" classify_signal "$home/state/crew.status" "$home/state")
  case "$out" in
    self\|*) ;;
    escalate\|*) fail "classify_signal escalated a writing crew with stale done: status: $out" ;;
    *) fail "unexpected classify_signal verdict: $out" ;;
  esac
  out=$(oracle_check "$home") || fail "oracle rejected the post-triage home: $out"
  case "$out" in
    *VIOLATION:*) fail "oracle reported a violation after signal worktree-write guard: $out" ;;
  esac
  pass "afk signal path defers terminal status when the worktree was written since the status file"
}

# 2026-08 incident: a steer stayed unhandled forever while the pane looked busy
# (live work above an idle composer) because inbox_steer_check deferred delivery
# without the stale path's BUSY_TURN_MAX_SECS bound.
test_watch_inbox_escalates_busy_deferred_steer() {
  local home fakebin out window rec pid
  home=$(make_fault_home watch-busy-steer-bound)
  fakebin="$home/fakebin"
  out="$home/watch.out"
  window="firstmate:fm-crew"
  seed_task "$home" crew 'working: long foreground call'
  mark_live_endpoint "$home" crew
  sed -i '' 's/harness=codex/harness=grok/' "$home/state/crew.meta" 2>/dev/null \
    || sed -i 's/harness=codex/harness=grok/' "$home/state/crew.meta"
  printf 'some output\nBUSYTOKEN active\n' > "$home/busy.capture"
  rec=$(FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_task_inbox_write "$2" crew "please continue"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state") \
    || fail "could not seed an aged steer in the synthetic inbox"
  age_paths "$rec" "$home/state/crew.turn-ended" "$home/state/crew.meta"
  sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$home/state/crew.status" 2>/dev/null; else stat -c '%s:%Y' "$home/state/crew.status" 2>/dev/null; fi)
  printf '%s' "$sig" > "$home/state/.seen-crew_status"
  sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$home/state/crew.turn-ended" 2>/dev/null; else stat -c '%s:%Y' "$home/state/crew.turn-ended" 2>/dev/null; fi)
  printf '%s' "$sig" > "$home/state/.seen-crew_turn-ended"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" \
    FM_FAKE_TMUX_CAPTURE="$home/busy.capture" FM_BUSY_REGEX=BUSYTOKEN \
    FM_STATE_OVERRIDE="$home/state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TASK_INBOX_GRACE_SECS=1 FM_BUSY_TURN_MAX_SECS=1 FM_TASK_INBOX_RING_MAX=1 \
    "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  local i=0
  while [ "$i" -lt 120 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null && { kill "$pid" 2>/dev/null; fail "watch never escalated a busy-deferred steer"; }
  [ "$(wake_count "$home" 'unread firstmate instruction')" = 1 ] \
    || fail "watch did not queue exactly one unread-steer escalation:"$'\n'"$(cat "$home/state/.wake-queue" 2>/dev/null)"
  out=$(oracle_check "$home") || fail "oracle rejected the post-recovery home: $out"
  case "$out" in
    *VIOLATION:*) fail "oracle reported a violation after busy steer escalation: $out" ;;
  esac
  pass "watch escalates an unread steer once a busy pane crosses BUSY_TURN_MAX_SECS"
}

# 2026-08-29 incident: a validation gate timed out at 30 minutes with zero
# findings while axi status still read top-level running. crew_is_provably_working
# stayed true and every stale guard absorbed a captain-relevant done: line,
# masking completed work.
test_watch_surfaces_terminal_when_gate_stalled_zero_findings() {
  local home fakebin out window key sig pid branch
  home=$(make_fault_home watch-gate-stall-zero)
  fakebin="$home/fakebin"
  out="$home/watch.out"
  window="firstmate:fm-crew"
  branch="task/crew"
  seed_task "$home" crew 'done: PR ready for review'
  mark_live_endpoint "$home" crew
  make_gate_stall_crew_state "$home" crew "$branch" 1800000
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf 'window=%s\n' "$window" >> "$home/state/crew.meta"
  sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$home/state/crew.status" 2>/dev/null; else stat -c '%s:%Y' "$home/state/crew.status" 2>/dev/null; fi)
  printf '%s' "$sig" > "$home/state/.seen-crew_status"
  sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$home/state/crew.turn-ended" 2>/dev/null; else stat -c '%s:%Y' "$home/state/crew.turn-ended" 2>/dev/null; fi)
  printf '%s' "$sig" > "$home/state/.seen-crew_turn-ended"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "all quiet")" > "$home/state/.stale-$key"
  date +%s > "$home/state/.stale-since-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" \
    FM_FAKE_TMUX_CAPTURE="$home/pane.txt" FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_STALE_ESCALATE_SECS=1 \
    "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  local i=0
  while [ "$i" -lt 120 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null && { kill "$pid" 2>/dev/null; fail "watch never surfaced a done: line for a stalled zero-finding gate"; }
  grep -qF 'stale:' "$out" \
    || fail "watch did not surface terminal status for a stalled zero-finding gate:"$'\n'"$(cat "$out")"
  out=$(oracle_check "$home") || fail "oracle rejected the post-recovery home: $out"
  case "$out" in
    *VIOLATION:*) fail "oracle reported a violation after gate-stall surfacing: $out" ;;
  esac
  pass "watch surfaces terminal status when the review gate stalled with zero findings"
}

# 2026-08-29 incident: an unread steer on a dead endpoint spent the ring ladder's
# grace and attempt budget before surfacing, even though doorbell delivery is
# impossible once the endpoint is gone.
test_watch_inbox_escalates_steer_when_endpoint_gone() {
  local home fakebin out window rec pid
  home=$(make_fault_home watch-inbox-steer-endpoint-gone)
  fakebin="$home/fakebin"
  out="$home/watch.out"
  window="firstmate:fm-crew"
  seed_task "$home" crew 'working: implementing feature'
  rec=$(FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_task_inbox_write "$2" crew "please continue"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state") \
    || fail "could not seed an aged steer in the synthetic inbox"
  age_paths "$rec" "$home/state/crew.turn-ended" "$home/state/crew.meta"
  sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$home/state/crew.status" 2>/dev/null; else stat -c '%s:%Y' "$home/state/crew.status" 2>/dev/null; fi)
  printf '%s' "$sig" > "$home/state/.seen-crew_status"
  sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$home/state/crew.turn-ended" 2>/dev/null; else stat -c '%s:%Y' "$home/state/crew.turn-ended" 2>/dev/null; fi)
  printf '%s' "$sig" > "$home/state/.seen-crew_turn-ended"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) printf "can't find session: firstmate\n" >&2; exit 1 ;;
  display-message|capture-pane) exit 1 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf 'window=%s\n' "$window" >> "$home/state/crew.meta"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" \
    FM_STATE_OVERRIDE="$home/state" FM_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TASK_INBOX_GRACE_SECS=90 FM_TASK_INBOX_RING_MAX=3 \
    "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  local i=0
  while [ "$i" -lt 120 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null && { kill "$pid" 2>/dev/null; fail "watch never escalated an unread steer on a dead endpoint"; }
  [ "$(wake_count "$home" 'unread firstmate instruction')" = 1 ] \
    || fail "watch did not queue exactly one unread-steer escalation on a dead endpoint:"$'\n'"$(cat "$home/state/.wake-queue" 2>/dev/null)"
  pass "watch escalates an unread steer immediately when the endpoint is gone"
}

# 2026-08-29 incident: endpoint death mid-task left a working: status line but
# fm-watch skipped the window entirely when capture failed, so non-terminal work
# never surfaced for recovery.
test_watch_surfaces_nonterminal_when_endpoint_gone_mid_task() {
  local home fakebin out window key sig pid
  home=$(make_fault_home watch-endpoint-gone-mid)
  fakebin="$home/fakebin"
  out="$home/watch.out"
  window="firstmate:fm-crew"
  seed_task "$home" crew 'working: implementing feature'
  enable_real_crew_state "$home"
  export FM_FAKE_AXI_STATUS=""
  export FM_FAKE_RUNS_LIST=""
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) printf "can't find session: firstmate\n" >&2; exit 1 ;;
  display-message|capture-pane) exit 1 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf 'window=%s\n' "$window" >> "$home/state/crew.meta"
  sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$home/state/crew.status" 2>/dev/null; else stat -c '%s:%Y' "$home/state/crew.status" 2>/dev/null; fi)
  printf '%s' "$sig" > "$home/state/.seen-crew_status"
  sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$home/state/crew.turn-ended" 2>/dev/null; else stat -c '%s:%Y' "$home/state/crew.turn-ended" 2>/dev/null; fi)
  printf '%s' "$sig" > "$home/state/.seen-crew_turn-ended"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" \
    FM_STATE_OVERRIDE="$home/state" FM_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_STALE_ESCALATE_SECS=1 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  local i=0
  while [ "$i" -lt 120 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null && { kill "$pid" 2>/dev/null; fail "watch never surfaced a stale wake for a gone endpoint mid-task"; }
  grep -qF 'stale:' "$out" \
    || fail "watch did not surface non-terminal status when the endpoint died mid-task:"$'\n'"$(cat "$out")"
  pass "watch surfaces non-terminal status when the endpoint dies mid-task"
}

# 2026-08-29 incident: away-mode persistence recheck silently dropped wedge
# markers when capture failed on a confidently dead endpoint, so mid-task death
# never reached the captain after the initial stale wake aged out.
test_afk_persistence_escalates_when_endpoint_gone_mid_task() {
  local home fakebin win key
  home=$(make_fault_home afk-persistence-endpoint-gone)
  fakebin="$home/fakebin"
  win="firstmate:fm-crew"
  seed_task "$home" crew 'working: implementing feature'
  key=$(printf '%s' "crew" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$home/state/.subsuper-stale-$key"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) printf "can't find session: firstmate\n" >&2; exit 1 ;;
  capture-pane|display-message) exit 1 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$ROOT/bin/fm-supervise-daemon.sh"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" \
    FM_STATE_OVERRIDE="$home/state" FM_STALE_ESCALATE_SECS=240 \
    housekeeping "$home/state"
  [ -s "$home/state/.subsuper-escalations" ] \
    || fail "afk persistence recheck did not escalate when endpoint died mid-task"
  [ ! -e "$home/state/.subsuper-stale-$key" ] \
    || fail "afk persistence recheck left a stale marker after gone-endpoint escalation"
  pass "afk persistence recheck escalates when endpoint dies mid-task"
}

# 2026-08-29 incident: capture failed with unreadable liveness (session inventory
# ok but pane reads failed) and away-mode persistence recheck silently dropped
# wedge markers instead of escalating mid-task death.
test_afk_persistence_escalates_when_capture_unreadable_mid_task() {
  local home fakebin win key
  home=$(make_fault_home afk-persistence-capture-unreadable)
  fakebin="$home/fakebin"
  win="firstmate:fm-crew"
  seed_task "$home" crew 'working: implementing feature'
  key=$(printf '%s' "crew" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$home/state/.subsuper-stale-$key"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) printf 'fm-crew\n'; exit 0 ;;
  capture-pane|display-message) exit 1 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$ROOT/bin/fm-supervise-daemon.sh"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" \
    FM_STATE_OVERRIDE="$home/state" FM_STALE_ESCALATE_SECS=240 \
    housekeeping "$home/state"
  [ -s "$home/state/.subsuper-escalations" ] \
    || fail "afk persistence recheck did not escalate when capture is unreadable mid-task"
  [ ! -e "$home/state/.subsuper-stale-$key" ] \
    || fail "afk persistence recheck left a stale marker after unreadable-capture escalation"
  pass "afk persistence recheck escalates when capture is unreadable mid-task"
}

# 2026-08-29 incident: away-mode pause recheck silently dropped markers when
# capture failed on a live endpoint, so a declared wait could rot invisibly.
test_afk_pause_defers_when_capture_unreadable_on_live_endpoint() {
  local home win key
  home=$(make_fault_home afk-pause-capture-live-defer)
  win="firstmate:fm-crew"
  seed_task "$home" crew 'paused: holding for upstream'
  key=$(printf '%s' "crew" | tr ':/.' '___')
  echo $(( $(date +%s) - 5000 )) > "$home/state/.subsuper-paused-$key"
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$ROOT/bin/fm-supervise-daemon.sh"
  (
    fm_backend_capture() { return 1; }
    fm_backend_agent_alive() { printf 'alive'; }
    FM_STATE_OVERRIDE="$home/state" FM_PAUSE_RESURFACE_SECS=240 housekeeping "$home/state"
  ) || fail "housekeeping subshell failed for live-endpoint pause deferral"
  [ ! -s "$home/state/.subsuper-escalations" ] \
    || fail "afk pause recheck escalated during a transient capture failure on a live endpoint"
  [ -e "$home/state/.subsuper-paused-$key" ] \
    || fail "afk pause recheck dropped the marker instead of deferring on a live endpoint"
  pass "afk pause recheck defers when capture fails on a live endpoint"
}

# 2026-08-29 incident: away-mode persistence recheck silently dropped wedge
# markers when capture failed on a live endpoint, so a genuine stale crew could
# rot invisibly during transient capture glitches.
test_afk_persistence_defers_when_capture_unreadable_on_live_endpoint() {
  local home win key
  home=$(make_fault_home afk-persistence-capture-live-defer)
  win="firstmate:fm-crew"
  seed_task "$home" crew 'working: still wedged'
  key=$(printf '%s' "crew" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$home/state/.subsuper-stale-$key"
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$ROOT/bin/fm-supervise-daemon.sh"
  (
    fm_backend_capture() { return 1; }
    fm_backend_agent_alive() { printf 'alive'; }
    FM_STATE_OVERRIDE="$home/state" FM_STALE_ESCALATE_SECS=240 housekeeping "$home/state"
  ) || fail "housekeeping subshell failed for live-endpoint persistence deferral"
  [ ! -s "$home/state/.subsuper-escalations" ] \
    || fail "afk persistence recheck escalated during a transient capture failure on a live endpoint"
  [ -e "$home/state/.subsuper-stale-$key" ] \
    || fail "afk persistence recheck dropped the marker instead of deferring on a live endpoint"
  pass "afk persistence recheck defers when capture fails on a live endpoint"
}

# 2026-08-29 incident: fm-watch skipped wedge follow-up when capture failed on
# a live endpoint, so an already-aging suppressor stalled until capture recovered.
test_watch_wedge_followup_continues_when_capture_unreadable_on_live_endpoint() {
  local dir home fakebin out window key pane_hash sig pid state
  dir=$(make_case watch-wedge-capture-live-defer)
  home="$dir"
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  window="firstmate:fm-crew"
  printf 'synthetic stress-test home\n' > "$home/.fm-synthetic-home"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/crew.meta"
  printf 'working: still wedged\n' > "$state/crew.status"
  sig=$(if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$state/crew.status" 2>/dev/null; else stat -c '%s:%Y' "$state/crew.status" 2>/dev/null; fi)
  printf '%s' "$sig" > "$state/.seen-crew_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '2\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: none'
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) printf 'fm-crew\n'; exit 0 ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'codex\n'; exit 0 ;;
    esac
    printf '%%1\n'; exit 0 ;;
  capture-pane) exit 1 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2>&1 &
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "watch never escalated wedge during live-endpoint capture failure: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    || fail "watch did not queue wedge escalation during live-endpoint capture failure:"$'\n'"$(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "watch wedge follow-up continues when capture fails on a live endpoint"
}

test_inactive_reconcile_skips_live_worker_with_stale_failed_status
test_inactive_reconcile_skips_unknown_liveness_with_stale_failed_status
test_inactive_reconcile_still_reports_absent_worker
test_inactive_reconcile_presents_custody_lost_absent_endpoint
test_inactive_reconcile_skips_custody_lost_with_live_endpoint
test_afk_catchall_skips_terminal_when_crew_is_provably_working
test_afk_stale_terminal_absorbed_when_crew_is_provably_working
test_watch_heartbeat_skips_provably_working_terminal
test_watch_signal_skips_provably_working_terminal
test_afk_wedge_wake_skips_terminal_when_crew_is_provably_working
test_push_transition_skips_provably_working_terminal
test_afk_persistence_skips_terminal_when_crew_is_provably_working
test_legacy_captain_signal_skips_provably_working
test_afk_persistence_defers_while_worktree_is_written
test_watch_nonterminal_worktree_write_defers_when_crew_inconclusive
test_watch_terminal_worktree_write_defers_when_crew_inconclusive
test_watch_signal_defers_terminal_when_worktree_written_inconclusive
test_watch_heartbeat_defers_terminal_when_worktree_written_inconclusive
test_push_transition_defers_terminal_when_worktree_written_inconclusive
test_afk_signal_defers_terminal_when_worktree_written_inconclusive
test_recycled_slot_blocks_provably_working_misattribution
test_recycled_slot_blocks_worktree_write_deferral
test_watch_inbox_escalates_busy_deferred_steer
test_watch_inbox_escalates_steer_when_endpoint_gone
test_watch_surfaces_terminal_when_gate_stalled_zero_findings
test_watch_surfaces_nonterminal_when_endpoint_gone_mid_task
test_afk_persistence_escalates_when_endpoint_gone_mid_task
test_afk_persistence_escalates_when_capture_unreadable_mid_task
test_afk_pause_defers_when_capture_unreadable_on_live_endpoint
test_afk_persistence_defers_when_capture_unreadable_on_live_endpoint
test_watch_wedge_followup_continues_when_capture_unreadable_on_live_endpoint
