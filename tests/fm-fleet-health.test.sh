#!/usr/bin/env bash
# Behavior tests for the read-only fleet health checker.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-task-inbox-lib.sh"

HEALTH="$ROOT/bin/fm-fleet-health.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-health)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

export FM_SUPERVISION_MODEL=persistent
export FM_GUARD_GRACE=300
export FM_TASK_INBOX_GRACE_SECS=90
export FM_PENDING_REPLY_GRACE_SECS=120

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
listed_windows() {
  if [ -f "${FM_HOME:?}/state/.fake-windows" ]; then
    cat "${FM_HOME}/state/.fake-windows"
  else
    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta 2>/dev/null
  fi
}
window_present() {
  local w
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    case "$target" in
      *"$w"*) return 0 ;;
    esac
  done <<EOF
$(listed_windows)
EOF
  return 1
}
case "${1:-}" in
  list-windows)
    listed_windows
    ;;
  display-message)
    window_present || exit 1
    case "$*" in
      *pane_current_command*)
        case "$target" in
          *dead*) printf 'zsh\n' ;;
          *) printf 'codex\n' ;;
        esac
        ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    window_present || exit 1
    case "$target" in
      *codex-resume*) printf 'session ended\nTo continue this session, run codex resume\n' ;;
      *paused*) printf 'all quiet\n> \n' ;;
      *) printf 'work in progress\nesc to interrupt\n' ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

run_health() {  # <home> <fakebin>
  PATH="$2:$PATH" FM_HOME="$1" "$HEALTH" --json
}

make_health_fixture_root() {  # <name>
  local root=$TMP_ROOT/health-command-$1 source base
  mkdir -p "$root/bin"
  cp "$HEALTH" "$root/bin/fm-fleet-health.sh"
  for source in "$ROOT"/bin/*.sh; do
    base=${source##*/}
    case "$base" in
      fm-fleet-health.sh|fm-fleet-snapshot.sh) continue ;;
    esac
    ln -s "$source" "$root/bin/$base"
  done
  cat > "$root/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_SNAPSHOT:?}"
SH
  chmod +x "$root/bin/fm-fleet-health.sh" "$root/bin/fm-fleet-snapshot.sh"
  printf '%s\n' "$root"
}

make_snapshot_fixture_root() {  # <name>
  local root=$TMP_ROOT/snapshot-command-$1 source base
  mkdir -p "$root/bin"
  cp "$ROOT/bin/fm-fleet-snapshot.sh" "$root/bin/fm-fleet-snapshot.sh"
  for source in "$ROOT"/bin/*.sh; do
    base=${source##*/}
    case "$base" in
      fm-fleet-snapshot.sh|fm-on.sh) continue ;;
    esac
    ln -s "$source" "$root/bin/$base"
  done
  cat > "$root/bin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_REMOTE_CALL_LOG:?}" >> "$FM_TEST_REMOTE_CALL_LOG"
exit 1
SH
  chmod +x "$root/bin/fm-fleet-snapshot.sh" "$root/bin/fm-on.sh"
  printf '%s\n' "$root"
}

write_pending() {  # <home> <corr> <task> <phase> [completed_epoch] [grace] [sender-pid] [sender-identity] [recovery-outcome]
  local home=$1 corr=$2 task=$3 phase=$4 completed=${5-} grace=${6:-120}
  local sender_pid=${7-} sender_identity=${8-} recovery_outcome=${9-}
  if [ -z "$recovery_outcome" ]; then
    case "$phase" in
      recovery_sent) recovery_outcome=confirmed ;;
      recovery_failed) recovery_outcome=failed ;;
      recovery_unknown) recovery_outcome=unknown ;;
    esac
  fi
  mkdir -p "$home/state/pending-replies"
  cat > "$home/state/pending-replies/$corr" <<EOF
schema=fm-pending-reply.v1
corr_id=$corr
task_id=$task
parent_home=$home
parent_status=$home/state/${task}.status
parent_status_scan_signature=
request_summary=ping
created_epoch=1000
delivered_epoch=1001
phase=$phase
turn_seen_busy=1
request_turn_completed_epoch=$completed
recovery_attempted_epoch=
recovery_sender_pid=$sender_pid
recovery_sender_identity=$sender_identity
recovery_sent_epoch=
recovery_delivery_outcome=$recovery_outcome
recovery_turn_seen_busy=0
recovery_turn_completed_epoch=
escalated_epoch=
escalation_closed_epoch=
resolved_epoch=
resolved_via=
wrong_home_hits=0
wrong_home_sightings=
wrong_home_scan_signature=
grace_secs=$grace
EOF
}

write_live_ship() {  # <home> <id>
  local home=$1 id=$2
  mkdir -p "$home/projects/${id}-wt"
  fm_write_meta "$home/state/${id}.meta" \
    "window=firstmate:fm-${id}" \
    "worktree=$home/projects/${id}-wt" \
    "project=alpha" \
    "harness=grok" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  printf 'working: implementing\n' > "$home/state/${id}.status"
}

fresh_autoarm_supervision() {  # <home>
  touch "$1/state/.last-watcher-beat"
}

kinds_of() {  # <json>
  printf '%s' "$1" | jq -r '[.findings[].kind] | join(",")'
}

test_usage_exit() {
  local rc=0
  "$HEALTH" --nope >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "unknown flag must be a usage error"
  rc=0
  "$HEALTH" --json extra >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "extra arguments must be a usage error"
  pass "usage errors exit 2"
}

test_invalid_handoff_threshold_is_usage_error() {
  local home fakebin rc=0
  home=$(make_home invalid-handoff-threshold)
  fakebin=$(make_fakebin "$home")
  FM_HOME="$home" PATH="$fakebin:$PATH" \
    FM_FLEET_HEALTH_HANDOFF_STALE_SECS=not-a-number "$HEALTH" --json >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "invalid handoff threshold should be a usage error"
  pass "invalid handoff threshold retains usage-error semantics"
}

test_healthy_empty_fleet() {
  local home fakebin out rc=0
  home=$(make_home healthy)
  fakebin=$(make_fakebin "$home")
  out=$(run_health "$home" "$fakebin") || rc=$?
  expect_code 0 "$rc" "empty fleet should be healthy"
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-health.v1"
      and .status == "healthy"
      and (.findings | length) == 0
  ' >/dev/null || fail "empty fleet health JSON wrong: $out"
  pass "empty fleet is healthy with no findings"
}

test_missing_state_home_remains_unmodified() {
  local home fakebin out rc=0
  home=$TMP_ROOT/missing-state
  mkdir -p "$home"
  fakebin=$(make_fakebin "$home")
  out=$(run_health "$home" "$fakebin") || rc=$?
  expect_code 0 "$rc" "home without state should remain a healthy empty fleet"
  [ ! -e "$home/state" ] || fail "read-only health check created the missing state directory"
  printf '%s' "$out" | jq -e '.status == "healthy"' >/dev/null \
    || fail "missing-state home did not report healthy: $out"
  pass "health check does not create a missing state directory"
}

test_malformed_snapshot_is_incomplete() {
  local home fixture out rc=0 field snapshot
  home=$(make_home malformed-snapshot)
  fixture=$(make_health_fixture_root malformed-snapshot)
  snapshot='{"schema":"fm-fleet-snapshot.v1","generated":"2026-01-01T00:00:00Z","fm_home":"/tmp/home","roots":{"fm_root":"/tmp/root","state":"/tmp/state","data":"/tmp/data","config":"/tmp/config","projects":"/tmp/projects"},"backlog":{"path":"/tmp/backlog.md","present":false,"records":[]},"tasks":[],"scout_reports":[],"collection":{"state":{"present":false,"available":true,"invalid_metadata_count":0,"invalid_metadata":[]}},"main_inventory":{"valid":true,"reason":null},"secondmate_current":{"records":[],"truncated":0,"registry":{"available":true,"complete":true,"input_truncated":false,"records_truncated":false}},"secondmate_landed":{"records":[],"truncated":[],"unreadable":[],"partial":[]},"secondmate_guidance":{"note":"fixture"}}'
  for field in roots backlog secondmate_landed; do
    rc=0
    out=$(FM_HOME="$home" FM_TEST_SNAPSHOT="$(printf '%s' "$snapshot" | jq --arg field "$field" 'del(.[$field])')" \
      FM_FLEET_HEALTH_TIMED_WORKER=1 "$fixture/bin/fm-fleet-health.sh" --json) || rc=$?
    expect_code 3 "$rc" "a snapshot missing $field should be incomplete"
    printf '%s' "$out" | jq -e '
      .status == "incomplete"
        and .reason == "fleet snapshot was malformed"
        and (.findings | length) == 0
    ' >/dev/null || fail "snapshot missing $field was treated as usable: $out"
  done
  pass "schema-tagged snapshots require the complete top-level shape"
}

test_snapshot_task_evidence_requires_keys_and_known_states() {
  local home fixture out rc=0 mutation snapshot
  home=$(make_home malformed-task-evidence)
  fixture=$(make_health_fixture_root malformed-task-evidence)
  snapshot='{"schema":"fm-fleet-snapshot.v1","generated":"2026-01-01T00:00:00Z","fm_home":"/tmp/home","roots":{"fm_root":"/tmp/root","state":"/tmp/state","data":"/tmp/data","config":"/tmp/config","projects":"/tmp/projects"},"backlog":{"path":"/tmp/backlog.md","present":false,"records":[]},"tasks":[{"id":"task","kind":"ship","remote":null,"current_state":{"state":"working"},"endpoint":{"agent_state":"alive","agent_alive":"alive","probe":"local","codex_session":{"collected":true,"reason":null,"resume_banner":null}},"paths":{"status_log":{"available":true,"reason":null,"last_event":{"state":"working","handoff_required":false,"mtime_epoch":null}}},"pr":{"url":null,"source":"absent"}}],"scout_reports":[],"collection":{"state":{"present":true,"available":true,"invalid_metadata_count":0,"invalid_metadata":[]}},"main_inventory":{"valid":true,"reason":null},"secondmate_current":{"records":[],"truncated":0,"registry":{"available":true,"complete":true,"input_truncated":false,"records_truncated":false}},"secondmate_landed":{"records":[],"truncated":[],"unreadable":[],"partial":[]},"secondmate_guidance":{"note":"fixture"}}'
  for mutation in omit-endpoint-exists invalid-state invalid-agent-state invalid-agent-alive invalid-probe; do
    if [ "$mutation" = omit-endpoint-exists ]; then
      snapshot=$(printf '%s' "$snapshot" | jq 'del(.tasks[0].endpoint.exists)')
    elif [ "$mutation" = invalid-state ]; then
      snapshot=$(printf '%s' "$snapshot" | jq '.tasks[0].current_state.state = "not-a-state"')
    elif [ "$mutation" = invalid-agent-state ]; then
      snapshot=$(printf '%s' "$snapshot" | jq '.tasks[0].endpoint.agent_state = "not-a-state"')
    elif [ "$mutation" = invalid-agent-alive ]; then
      snapshot=$(printf '%s' "$snapshot" | jq '.tasks[0].endpoint.agent_alive = "not-a-state"')
    else
      snapshot=$(printf '%s' "$snapshot" | jq '.tasks[0].endpoint.probe = "not-a-probe"')
    fi
    rc=0
    out=$(FM_HOME="$home" FM_TEST_SNAPSHOT="$snapshot" FM_FLEET_HEALTH_TIMED_WORKER=1 \
      "$fixture/bin/fm-fleet-health.sh" --json) || rc=$?
    expect_code 3 "$rc" "snapshot with $mutation should be incomplete"
    printf '%s' "$out" | jq -e '.status == "incomplete" and .reason == "fleet snapshot was malformed"' \
      >/dev/null || fail "snapshot with $mutation was accepted: $out"
  done
  pass "snapshot task evidence requires nullable keys and known enums"
}

test_remote_snapshot_probe_disabled_skips_remote_state() {
  local home fixture out rc=0 log
  home=$(make_home remote-probe-disabled)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/remote-mate.meta" \
    "window=firstmate:fm-remote-mate" \
    "worktree=$home/secondmate-home" \
    "project=alpha" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=/remote/secondmate-home" \
    "remote_host=example.invalid" \
    "remote_root=/remote/firstmate"
  printf 'working: watching scope\n' > "$home/state/remote-mate.status"
  fixture=$(make_snapshot_fixture_root remote-probe-disabled)
  log=$TMP_ROOT/remote-probe-disabled.log
  out=$(PATH="$fixture/bin:$PATH" FM_HOME="$home" FM_SNAPSHOT_REMOTE_PROBES=0 \
    FM_TEST_REMOTE_CALL_LOG="$log" "$fixture/bin/fm-fleet-snapshot.sh" --json) || rc=$?
  expect_code 0 "$rc" "disabled remote probes should still produce a snapshot"
  [ ! -e "$log" ] || fail "disabled remote probes invoked the remote transport"
  printf '%s' "$out" | jq -e '
    any(.tasks[]; .id == "remote-mate"
        and .current_state.state == "unknown"
        and .current_state.source == "remote-not-collected"
        and .endpoint.probe == "skipped"
        and .endpoint.agent_state == "not_collected")
  ' >/dev/null || fail "remote current-state evidence was not explicitly unavailable: $out"
  pass "disabled remote probes skip remote current-state collection"
}

test_dangling_state_path_is_inconclusive() {
  local home fakebin out rc=0
  home=$TMP_ROOT/dangling-state
  mkdir -p "$home"
  ln -s "$home/missing-state-target" "$home/state"
  fakebin=$(make_fakebin "$home")
  out=$(run_health "$home" "$fakebin") || rc=$?
  expect_code 3 "$rc" "dangling state path should make health inconclusive"
  [ -L "$home/state" ] || fail "read-only health changed dangling state path"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "fleet-inventory-inconclusive" and .subject == "state")
  ' >/dev/null || fail "dangling state path was treated as healthy: $out"
  pass "dangling state path remains unavailable and inconclusive"
}

test_unsearchable_state_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home unsearchable-state)
  write_live_ship "$home" hidden-task
  fakebin=$(make_fakebin "$home")
  chmod 400 "$home/state"
  out=$(run_health "$home" "$fakebin") || rc=$?
  chmod 700 "$home/state"
  expect_code 3 "$rc" "unsearchable state should make health inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "fleet-inventory-inconclusive" and .subject == "state")
      and (any(.findings[]; .kind == "result-listener-missing") | not)
  ' >/dev/null || fail "unsearchable state was treated as healthy or definitely broken: $out"
  pass "unsearchable state inventory remains inconclusive"
}

test_dangling_metadata_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home dangling-metadata)
  ln -s "$home/state/missing-target" "$home/state/dangling.meta"
  fakebin=$(make_fakebin "$home")
  out=$(run_health "$home" "$fakebin") || rc=$?
  expect_code 3 "$rc" "dangling task metadata should make health inconclusive"
  [ -L "$home/state/dangling.meta" ] || fail "read-only health changed dangling metadata"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "fleet-inventory-inconclusive"
              and .subject == "metadata" and .count == 1)
  ' >/dev/null || fail "dangling task metadata was treated as healthy: $out"
  pass "dangling task metadata remains visible and inconclusive"
}

test_unsearchable_nested_inventories_are_inconclusive() {
  local home fakebin claim_root out rc=0
  home=$(make_home unsearchable-nested)
  claim_root="$home/procevent-claims"
  mkdir -p "$home/state/pending-replies" "$home/state/hidden.inbox" \
    "$home/state/procevent" "$claim_root"
  printf 'adapter=lavish\nargc=1\nargv:\ntrue\n' > "$home/state/procevent/hidden.source"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  chmod 400 "$home/state/pending-replies" "$home/state/hidden.inbox" \
    "$home/state/procevent" "$claim_root"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm \
    FM_PROCEVENT_CLAIM_ROOT="$claim_root" "$HEALTH" --json) || rc=$?
  chmod 700 "$home/state/pending-replies" "$home/state/hidden.inbox" \
    "$home/state/procevent" "$claim_root"
  expect_code 3 "$rc" "unsearchable nested inventories should make health inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "pending-reply-inconclusive")
      and any(.findings[]; .kind == "steering-inbox-inconclusive")
      and any(.findings[]; .kind == "result-listener-inconclusive"
              and .subject == "procevent")
      and (any(.findings[]; .kind == "pending-reply-broken") | not)
      and (any(.findings[]; .kind == "result-listener-missing"
               and .subject == "hidden") | not)
  ' >/dev/null || fail "nested inaccessible evidence was treated as healthy or broken: $out"
  pass "nested inventory access failures remain inconclusive"
}

test_actionable_dead_direct_report() {
  local home fakebin out rc=0
  home=$(make_home dead-agent)
  write_live_ship "$home" ship-task
  : > "$home/state/.fake-windows"
  fakebin=$(make_fakebin "$home")
  out=$(run_health "$home" "$fakebin") || rc=$?
  expect_code 1 "$rc" "dead direct report should be actionable"
  printf '%s' "$out" | jq -e '
    .status == "actionable"
      and any(.findings[]; .kind == "dead-direct-report" and .subject == "ship-task" and .confidence == "high")
  ' >/dev/null || fail "dead direct report missing: $out"
  pass "dead local worker is an actionable finding"
}

test_dead_agent_with_live_endpoint() {
  local home fakebin out rc=0
  home=$(make_home dead-agent-live-endpoint)
  write_live_ship "$home" dead-worker
  printf 'fm-dead-worker\n' > "$home/state/.fake-windows"
  fakebin=$(make_fakebin "$home")
  out=$(run_health "$home" "$fakebin") || rc=$?
  expect_code 1 "$rc" "dead agent behind a live endpoint should be actionable"
  printf '%s' "$out" | jq -e '
    any(.findings[]; .kind == "dead-direct-report" and .subject == "dead-worker"
        and .evidence == "direct-report agent is dead while its endpoint remains present")
  ' >/dev/null || fail "dead agent behind live endpoint was missed: $out"
  pass "dead agent is detected even when its endpoint remains present"
}

test_codex_resume_banner_is_dead_session() {
  local home fakebin out rc=0
  home=$(make_home codex-resume-banner)
  mkdir -p "$home/projects/codex-resume-wt"
  fm_write_meta "$home/state/codex-resume-task.meta" \
    "window=firstmate:fm-codex-resume-task" \
    "worktree=$home/projects/codex-resume-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  printf 'working: still in flight\n' > "$home/state/codex-resume-task.status"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 1 "$rc" "Codex resume banner should be an actionable dead session"
  printf '%s' "$out" | jq -e '
    .status == "actionable"
      and any(.findings[]; .kind == "dead-codex-session" and .subject == "codex-resume-task"
              and .confidence == "high"
              and .evidence == "Codex session exited; pane contains the resume banner")
      and (any(.findings[]; .kind == "dead-direct-report" and .subject == "codex-resume-task") | not)
  ' >/dev/null || fail "Codex resume banner was missed or duplicated: $out"
  pass "Codex resume banner is a high-confidence dead-session finding"
}

test_unverified_backend_codex_banner_is_dead_session() {
  local home fakebin out rc=0
  home=$(make_home codex-unverified-banner)
  mkdir -p "$home/projects/codex-unverified-wt"
  fm_write_meta "$home/state/codex-unverified.meta" \
    "window=firstmate:7" \
    "endpoint_task_id=codex-unverified" \
    "backend=zellij" \
    "zellij_session=firstmate" \
    "zellij_tab_id=3" \
    "zellij_pane_id=7" \
    "worktree=$home/projects/codex-unverified-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  printf 'working: still in flight\n' > "$home/state/codex-unverified.status"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  cat > "$fakebin/zellij" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "list-sessions --short --no-formatting") printf 'firstmate\n' ;;
  *"action list-panes --json"*) printf '[{"id":7,"tab_id":3,"is_plugin":false}]\n' ;;
  *"action list-tabs --json"*) printf '[{"tab_id":3,"name":"fm-codex-unverified"}]\n' ;;
  *"action dump-screen --pane-id 7"*) printf 'session ended\nTo continue this session, run codex resume\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/zellij"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 1 "$rc" "Codex resume banner should override unverified backend liveness"
  printf '%s' "$out" | jq -e '
    .status == "actionable"
      and any(.findings[]; .kind == "dead-codex-session" and .subject == "codex-unverified"
              and .confidence == "high")
      and (any(.findings[]; .kind == "endpoint-inconclusive" and .subject == "codex-unverified") | not)
  ' >/dev/null || fail "unverified backend hid a captured Codex resume banner: $out"
  pass "captured Codex banner overrides unverified backend liveness"
}

test_failed_codex_capture_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home codex-capture-failed)
  mkdir -p "$home/projects/codex-capture-failed-wt"
  fm_write_meta "$home/state/codex-capture-failed.meta" \
    "window=firstmate:fm-codex-capture-failed" \
    "worktree=$home/projects/codex-capture-failed-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  printf 'working: still in flight\n' > "$home/state/codex-capture-failed.status"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'fm-codex-capture-failed\n' ;;
  display-message)
    case "$*" in *pane_current_command*) printf 'codex\n' ;; *) printf '%%1\n' ;; esac
    ;;
  capture-pane) exit 1 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "failed Codex pane capture should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "endpoint-inconclusive" and .subject == "codex-capture-failed")
      and (any(.findings[]; .kind == "dead-codex-session" and .subject == "codex-capture-failed") | not)
  ' >/dev/null || fail "failed Codex pane capture did not remain inconclusive: $out"
  pass "failed Codex pane capture remains inconclusive"
}

test_codex_bare_shell_is_dead_session() {
  local home fakebin out rc=0
  home=$(make_home codex-bare-shell)
  mkdir -p "$home/projects/dead-codex-wt"
  fm_write_meta "$home/state/dead-codex.meta" \
    "window=firstmate:fm-dead-codex" \
    "worktree=$home/projects/dead-codex-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  printf 'working: still in flight\n' > "$home/state/dead-codex.status"
  printf 'fm-dead-codex\n' > "$home/state/.fake-windows"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 1 "$rc" "Codex bare-shell pane should be an actionable dead session"
  printf '%s' "$out" | jq -e '
    any(.findings[]; .kind == "dead-codex-session" and .subject == "dead-codex"
        and .confidence == "high"
        and .evidence == "Codex session exited; endpoint pane is a bare shell")
      and (any(.findings[]; .kind == "dead-direct-report" and .subject == "dead-codex") | not)
  ' >/dev/null || fail "Codex bare-shell session was missed or classified generically: $out"
  pass "Codex bare-shell pane is a high-confidence dead-session finding"
}

test_live_codex_without_banner_is_not_dead_session() {
  local home fakebin out rc=0
  home=$(make_home live-codex)
  mkdir -p "$home/projects/codex-live-wt"
  fm_write_meta "$home/state/codex-live.meta" \
    "window=firstmate:fm-codex-live" \
    "worktree=$home/projects/codex-live-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  printf 'working: implementing\n' > "$home/state/codex-live.status"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "live Codex without resume banner keeps unknown lifecycle inconclusive"
  printf '%s' "$out" | jq -e '
    (any(.findings[]; .kind == "dead-codex-session") | not)
      and any(.findings[]; .kind == "current-state-inconclusive" and .subject == "codex-live")
  ' >/dev/null || fail "live Codex was reported as a dead session or lost unknown-state evidence: $out"
  pass "live Codex without resume banner is not a dead-session finding"
}

test_missed_handoff_after_done_signal() {
  local home fakebin out rc=0
  home=$(make_home missed-handoff)
  write_live_ship "$home" done-idle
  printf 'done: PR https://example.test/pull/1 checks green\n' > "$home/state/done-idle.status"
  touch -t 202001011200 "$home/state/done-idle.status"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm \
    FM_FLEET_HEALTH_HANDOFF_STALE_SECS=60 "$HEALTH" --json) || rc=$?
  expect_code 1 "$rc" "stale done signal should be an actionable missed handoff"
  printf '%s' "$out" | jq -e '
    .status == "actionable"
      and any(.findings[]; .kind == "missed-handoff" and .subject == "done-idle"
              and .confidence == "high")
  ' >/dev/null || fail "missed handoff was not reported: $out"
  pass "stale done signal with no later inbox is a missed handoff"
}

test_later_inbox_clears_missed_handoff() {
  local home fakebin out rc=0
  home=$(make_home handoff-inbox)
  write_live_ship "$home" done-followed
  printf 'done: ready for next step\n' > "$home/state/done-followed.status"
  touch -t 202001011200 "$home/state/done-followed.status"
  fakebin=$(make_fakebin "$home")
  PATH="$fakebin:$PATH" FM_HOME="$home" \
    fm_task_inbox_write "$home/state" done-followed "next step" >/dev/null
  fresh_autoarm_supervision "$home"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm \
    FM_FLEET_HEALTH_HANDOFF_STALE_SECS=60 "$HEALTH" --json) || rc=$?
  printf '%s' "$out" | jq -e '
    any(.findings[]; .kind == "missed-handoff" and .subject == "done-followed") | not
  ' >/dev/null || fail "later inbox did not suppress missed handoff: $out"
  pass "a later steering message suppresses the missed-handoff finding"
}

test_recent_done_signal_is_not_missed_handoff() {
  local home fakebin out rc=0
  home=$(make_home recent-done)
  write_live_ship "$home" just-done
  printf 'done: just finished\n' > "$home/state/just-done.status"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm \
    FM_FLEET_HEALTH_HANDOFF_STALE_SECS=1800 "$HEALTH" --json) || rc=$?
  printf '%s' "$out" | jq -e '
    (any(.findings[]; .kind == "missed-handoff" and .subject == "just-done") | not)
  ' >/dev/null || fail "fresh done signal was treated as missed handoff: $out"
  pass "a fresh done signal is inside the handoff stale window"
}

test_missed_handoff_after_contracted_step_complete_signal() {
  local home fakebin out rc=0
  home=$(make_home step-complete-handoff)
  write_live_ship "$home" step-idle
  printf 'blocked: phase 7 complete; send the next instruction\n' > "$home/state/step-idle.status"
  touch -t 202001011200 "$home/state/step-idle.status"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm \
    FM_FLEET_HEALTH_HANDOFF_STALE_SECS=60 "$HEALTH" --json) || rc=$?
  expect_code 1 "$rc" "contracted step-complete signal should be actionable"
  printf '%s' "$out" | jq -e '
    any(.findings[]; .kind == "missed-handoff" and .subject == "step-idle"
        and .confidence == "high"
        and (.evidence | contains("signaled blocked awaiting the next instruction")))
  ' >/dev/null || fail "contracted step-complete missed handoff was not reported: $out"
  pass "contracted step-complete signal is a missed handoff"
}

test_failed_status_is_not_missed_handoff() {
  local home fakebin out rc=0
  home=$(make_home failed-not-handoff)
  write_live_ship "$home" failed-task
  printf 'failed: tests did not pass\n' > "$home/state/failed-task.status"
  touch -t 202001011200 "$home/state/failed-task.status"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm \
    FM_FLEET_HEALTH_HANDOFF_STALE_SECS=60 "$HEALTH" --json) || rc=$?
  printf '%s' "$out" | jq -e '
    any(.findings[]; .kind == "missed-handoff" and .subject == "failed-task") | not
  ' >/dev/null || fail "failed status was treated as a completed handoff: $out"
  pass "failed statuses do not assert a missed handoff"
}

test_dangling_status_log_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home dangling-status-log)
  write_live_ship "$home" dangling-status
  rm "$home/state/dangling-status.status"
  ln -s "$home/state/missing-status-target" "$home/state/dangling-status.status"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "dangling task status evidence should be inconclusive"
  printf '%s' "$out" | jq -e '
    any(.findings[]; .kind == "missed-handoff-inconclusive"
        and .subject == "dangling-status"
        and .evidence == "task status-log evidence could not be established")
  ' >/dev/null || fail "dangling status-log evidence was hidden: $out"
  pass "dangling status-log evidence remains inconclusive"
}

test_captain_decision_wait_is_not_missed_handoff() {
  local home fakebin out rc=0
  home=$(make_home captain-decision-wait)
  write_live_ship "$home" decision-idle
  printf 'needs-decision [key=shape]: choose an API\n' > "$home/state/decision-idle.status"
  touch -t 202001011200 "$home/state/decision-idle.status"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm \
    FM_FLEET_HEALTH_HANDOFF_STALE_SECS=60 "$HEALTH" --json) || rc=$?
  printf '%s' "$out" | jq -e '
    any(.findings[]; .kind == "missed-handoff" and .subject == "decision-idle") | not
  ' >/dev/null || fail "captain decision wait was treated as a missed handoff: $out"
  pass "captain decision waits stay out of missed handoffs"
}

test_handled_inbox_corruption_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home handled-inbox-corruption)
  write_live_ship "$home" handled-task
  printf 'done: ready for the next step\n' > "$home/state/handled-task.status"
  touch -t 202001011200 "$home/state/handled-task.status"
  mkdir -p "$home/state/handled-task.inbox/handled"
  printf 'not a task inbox record\n' > "$home/state/handled-task.inbox/handled/001.msg"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm \
    FM_FLEET_HEALTH_HANDOFF_STALE_SECS=60 "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "corrupt handled inbox evidence should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "steering-inbox-inconclusive"
              and (.evidence | contains("activity record(s) are invalid")))
      and (any(.findings[]; .kind == "missed-handoff" and .subject == "handled-task") | not)
  ' >/dev/null || fail "corrupt handled inbox evidence was hidden: $out"
  pass "corrupt handled inbox evidence remains inconclusive"
}

test_unrelated_inbox_corruption_preserves_missed_handoff() {
  local home fakebin out rc=0
  home=$(make_home unrelated-inbox-corruption)
  write_live_ship "$home" stale-task
  write_live_ship "$home" corrupt-task
  printf 'done: ready for the next step\n' > "$home/state/stale-task.status"
  touch -t 202001011200 "$home/state/stale-task.status"
  mkdir -p "$home/state/corrupt-task.inbox/handled"
  printf 'not a task inbox record\n' > "$home/state/corrupt-task.inbox/handled/001.msg"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm \
    FM_FLEET_HEALTH_HANDOFF_STALE_SECS=60 "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "unrelated inbox corruption should preserve actionable and inconclusive findings"
  printf '%s' "$out" | jq -e '
    any(.findings[]; .kind == "steering-inbox-inconclusive")
      and any(.findings[]; .kind == "missed-handoff" and .subject == "stale-task")
      and (any(.findings[]; .kind == "missed-handoff-inconclusive" and .subject == "stale-task") | not)
  ' >/dev/null || fail "unrelated inbox corruption suppressed a proven missed handoff: $out"
  pass "unrelated inbox corruption does not suppress proven handoffs"
}

test_unreadable_local_endpoint_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home unreadable-local-endpoint)
  mkdir -p "$home/projects/unreadable-wt"
  fm_write_meta "$home/state/unreadable-worker.meta" \
    "backend=herdr" \
    "window=malformed-herdr-target" \
    "worktree=$home/projects/unreadable-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'working: implementing\n' > "$home/state/unreadable-worker.status"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "unreadable local endpoint evidence should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "endpoint-inconclusive" and .subject == "unreadable-worker")
      and (any(.findings[]; .kind == "dead-direct-report" and .subject == "unreadable-worker") | not)
  ' >/dev/null || fail "unreadable Herdr evidence was classified as dead: $out"
  pass "unreadable local endpoint evidence remains inconclusive"
}

test_terminal_unreadable_endpoint_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home terminal-unreadable-endpoint)
  mkdir -p "$home/projects/terminal-unreadable-wt"
  fm_write_meta "$home/state/terminal-unreadable.meta" \
    "backend=herdr" \
    "window=malformed-herdr-target" \
    "worktree=$home/projects/terminal-unreadable-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'done: worker completed\n' > "$home/state/terminal-unreadable.status"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "terminal worker with unreadable endpoint evidence should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "endpoint-inconclusive"
              and .subject == "terminal-unreadable")
      and (any(.findings[]; .kind == "terminal-needs-cleanup"
               and .subject == "terminal-unreadable") | not)
  ' >/dev/null || fail "terminal unreadable endpoint evidence disappeared: $out"
  pass "terminal endpoint uncertainty remains inconclusive"
}

test_historical_status_pr_does_not_require_listener() {
  local home fakebin out rc=0
  home=$(make_home historical-status-pr)
  write_live_ship "$home" historical-pr
  cat > "$home/state/historical-pr.status" <<'EOF'
update: old delivery was https://github.com/example/alpha/pull/7
working: implementing the current delivery
EOF
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 0 "$rc" "historical status PR should not require a current listener"
  printf '%s' "$out" | jq -e '
    .status == "healthy"
      and (any(.findings[]; .kind == "result-listener-missing"
               and .subject == "historical-pr") | not)
  ' >/dev/null || fail "historical status PR created a listener requirement: $out"
  pass "historical status PR events do not require current listeners"
}

test_grouped_inbox_and_stable_fingerprints() {
  local home fakebin out1 out2 rc=0 fp1 fp2 count
  home=$(make_home grouped-inbox)
  write_live_ship "$home" steer-task
  fakebin=$(make_fakebin "$home")
  PATH="$fakebin:$PATH" FM_HOME="$home" \
    fm_task_inbox_write "$home/state" steer-task "first steer" >/dev/null
  PATH="$fakebin:$PATH" FM_HOME="$home" \
    fm_task_inbox_write "$home/state" steer-task "second steer" >/dev/null
  touch -t 202001011200 "$home/state/steer-task.inbox/"*.msg
  out1=$(run_health "$home" "$fakebin") || rc=$?
  expect_code 1 "$rc" "aged inbox should be actionable"
  count=$(printf '%s' "$out1" | jq '[.findings[] | select(.kind == "steering-inbox-aged")] | length')
  [ "$count" = 1 ] || fail "aged inbox findings were not grouped, count=$count: $out1"
  printf '%s' "$out1" | jq -e '
    .findings[] | select(.kind == "steering-inbox-aged")
    | .subject == "steer-task" and .count == 2
  ' >/dev/null || fail "grouped inbox count wrong: $out1"
  fp1=$(printf '%s' "$out1" | jq -r '.findings[] | select(.kind == "steering-inbox-aged") | .fingerprint')
  out2=$(run_health "$home" "$fakebin")
  fp2=$(printf '%s' "$out2" | jq -r '.findings[] | select(.kind == "steering-inbox-aged") | .fingerprint')
  [ "$fp1" = "$fp2" ] || fail "fingerprints were not stable: $fp1 vs $fp2"
  case "$fp1" in sha256:*) ;; *) fail "fingerprint is not sha256-prefixed: $fp1" ;; esac
  pass "aged inbox messages group by task and keep a stable fingerprint"
}

test_invalid_inbox_records_are_inconclusive() {
  local home fakebin real_stat out rc=0
  home=$(make_home invalid-inbox-records)
  mkdir -p "$home/state/broken.inbox"
  cat > "$home/state/broken.inbox/bad.msg" <<'EOF'
schema=fm-task-inbox.v1
at=2026-08-26T12:00:00Z
--
invalid sequence
EOF
  printf 'schema=fm-task-inbox.v1\n' > "$home/state/broken.inbox/001.msg"
  cat > "$home/state/broken.inbox/002.msg" <<'EOF'
schema=fm-task-inbox.v1
at=2026-08-26T12:00:00Z
--
unageable record
EOF
  cat > "$home/state/broken.inbox/003.msg" <<'EOF'
schema=fm-task-inbox.v1
at=xxxx-xx-xxTxx:xx:xxZ
--
malformed timestamp
EOF
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  real_stat=$(command -v stat)
  cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
case "${!#}" in
  */002.msg) exit 1 ;;
esac
exec "$FM_TEST_REAL_STAT" "$@"
SH
  chmod +x "$fakebin/stat"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm \
    FM_TEST_REAL_STAT="$real_stat" "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "invalid or unageable inbox records should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "steering-inbox-inconclusive"
              and .count == 3 and (.evidence | contains("are invalid")))
      and any(.findings[]; .kind == "steering-inbox-inconclusive"
              and .count == 1 and (.evidence | contains("could not be aged")))
      and (any(.findings[]; .kind == "steering-inbox-aged") | not)
  ' >/dev/null || fail "malformed inbox evidence was hidden: $out"
  pass "invalid and unageable inbox records remain inconclusive"
}

test_invalid_inbox_containers_are_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home invalid-inbox-containers)
  printf 'not a directory\n' > "$home/state/file.inbox"
  ln -s "$home/state/missing.inbox-target" "$home/state/dangling.inbox"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "invalid inbox containers should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "steering-inbox-inconclusive"
              and .count == 2 and (.evidence | contains("are invalid")))
  ' >/dev/null || fail "invalid inbox containers were hidden: $out"
  pass "invalid inbox containers remain visible and inconclusive"
}

test_remote_liveness_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home remote-liveness)
  mkdir -p "$home/secondmate-home"
  cat > "$home/data/secondmates.md" <<'EOF'
- remote-mate (host: example.invalid; root: /remote/firstmate; home: /remote/secondmate-home; scope: remote work; projects: alpha; added 2026-08-01)
EOF
  fm_write_meta "$home/state/remote-mate.meta" \
    "window=firstmate:fm-remote-mate" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=/remote/secondmate-home" \
    "remote_host=example.invalid" \
    "remote_root=/remote/firstmate" \
    "projects=alpha"
  printf 'working: watching delegated scope\n' > "$home/state/remote-mate.status"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "inconclusive remote liveness should use the incomplete exit"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "remote-liveness-inconclusive" and .subject == "remote-mate" and .confidence == "inconclusive")
      and (any(.findings[]; .kind == "dead-secondmate") | not)
      and (any(.findings[]; .kind == "dead-direct-report") | not)
  ' >/dev/null || fail "remote placeholder was treated as authoritative liveness: $out"
  pass "remote local placeholder is inconclusive, not healthy or dead"
}

test_unknown_worker_state_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home unknown-worker-state)
  mkdir -p "$home/projects/paused-unknown-wt"
  fm_write_meta "$home/state/paused-unknown.meta" \
    "window=firstmate:fm-paused-unknown" \
    "worktree=$home/projects/paused-unknown-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "unknown worker lifecycle state should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "current-state-inconclusive"
              and .subject == "paused-unknown" and .confidence == "inconclusive")
  ' >/dev/null || fail "unknown worker lifecycle state was hidden: $out"
  pass "unknown worker lifecycle state remains inconclusive"
}

test_registry_only_remote_evidence_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home registry-only-remote)
  cat > "$home/data/secondmates.md" <<'EOF'
- registry-only (host: example.invalid; root: /remote/firstmate; home: /remote/registry-only; scope: remote work; projects: alpha; added 2026-08-01)
EOF
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "registry-only remote evidence should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and ([.findings[] | select(.kind == "remote-liveness-inconclusive"
                                 and .subject == "registry-only")] | length) == 1
  ' >/dev/null || fail "registry-only remote evidence was hidden or duplicated: $out"
  pass "registry-only remote evidence remains grouped and inconclusive"
}

test_pending_reply_broken_and_historical_noise_omitted() {
  local home fakebin out
  home=$(make_home reply-and-noise)
  write_live_ship "$home" attorney-data
  write_pending "$home" abcdabcdabcdabcd attorney-data delivery_unknown
  write_pending "$home" 1234123412341234 attorney-data recovery_failed
  mkdir -p "$home/projects/noise-wt"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] attorney-data - Attorney Data (repo: alpha) (kind: ship) (since 2026-08-01)

## Queued
- [ ] recruit-magic - RecruitMagic blocked-by: attorney-data (repo: alpha) (kind: ship) (hold: waiting on product) (hold-kind: captain) (since 2026-08-02)

## Done
EOF
  {
    printf 'working: ping\n'
    printf 'needs-decision [key=shape]: choose an API\n'
    printf 'working: still going\n'
    printf 'working: another historical reply event\n'
  } > "$home/state/attorney-data.status"
  fakebin=$(make_fakebin "$home")
  out=$(run_health "$home" "$fakebin")
  printf '%s' "$out" | jq -e '
    ([.findings[] | select(.kind == "pending-reply-broken")] | length) == 1
      and (.findings[] | select(.kind == "pending-reply-broken") | .subject == "attorney-data" and .count == 2)
      and (any(.findings[]; .kind == "pending-reply-broken") )
      and (any(.findings[]; .subject == "recruit-magic") | not)
  ' >/dev/null || fail "historical events or product blockers leaked into health: $out"
  kinds=$(kinds_of "$out")
  case "$kinds" in
    *recruit*) fail "queued product blocker appeared in health kinds: $kinds" ;;
  esac
  pass "broken replies group by owner and product blockers stay out"
}

test_recovery_sending_owner_verdicts() {
  local home fakebin real_ps out rc=0
  home=$(make_home recovery-sending-verdicts)
  write_pending "$home" 1111111111111111 orphaned-recovery recovery_sending "" 120 999999 dead-sender
  write_pending "$home" 2222222222222222 unreadable-recovery recovery_sending "" 120 "$$" unreadable-sender
  fakebin=$(make_fakebin "$home")
  real_ps=$(command -v ps)
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -p $FM_TEST_UNREADABLE_PID "*) exit 1 ;;
esac
exec "$FM_TEST_REAL_PS" "$@"
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_TEST_REAL_PS="$real_ps" \
    FM_TEST_UNREADABLE_PID="$$" "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "unreadable recovery ownership should dominate an orphaned sender"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "pending-reply-broken"
              and .subject == "orphaned-recovery")
      and any(.findings[]; .kind == "pending-reply-inconclusive"
              and .subject == "unreadable-recovery")
  ' >/dev/null || fail "recovery_sending ownership evidence was hidden: $out"
  pass "recovery sender ownership distinguishes orphaned and unreadable"
}

test_committed_recovery_outcome_transition_is_valid() {
  local home fakebin out rc=0
  home=$(make_home inconsistent-recovery-outcome)
  write_pending "$home" 3333333333333333 half-written recovery_sending "" 120 "$$" sender confirmed
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$HEALTH" --json) || rc=$?
  expect_code 0 "$rc" "observable recovery outcome transition should remain valid"
  printf '%s' "$out" | jq -e '
    .status == "healthy"
      and (any(.findings[]; .kind == "pending-reply-inconclusive") | not)
      and (any(.findings[]; .kind == "pending-reply-broken") | not)
  ' >/dev/null || fail "observable recovery outcome transition was rejected: $out"
  pass "committed recovery outcomes remain valid before the phase advance"
}

test_inconclusive_secondmate_summary_not_broken() {
  local home fakebin out rc=0
  home=$(make_home remote-summary)
  mkdir -p "$home/secondmate-home"
  cat > "$home/data/secondmates.md" <<'EOF'
- remote-mate (host: example.invalid; root: /remote/firstmate; home: /remote/secondmate-home; scope: remote work; projects: alpha; added 2026-08-01)
EOF
  fm_write_meta "$home/state/remote-mate.meta" \
    "window=firstmate:fm-remote-mate" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=/remote/secondmate-home" \
    "remote_host=example.invalid" \
    "remote_root=/remote/firstmate" \
    "projects=alpha"
  printf 'working: watching delegated scope\n' > "$home/state/remote-mate.status"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "uncollected remote summary should be inconclusive"
  printf '%s' "$out" | jq -e '
    any(.findings[]; .kind == "remote-liveness-inconclusive" and .confidence == "inconclusive")
      and (any(.findings[]; .kind == "secondmate-summary-invalid") | not)
      and (any(.findings[]; .kind == "secondmate-summary-unavailable" and .confidence == "high") | not)
  ' >/dev/null || fail "uncollected remote summary was marked broken: $out"
  pass "uncollected remote secondmate summary is inconclusive"
}

test_invalid_secondmate_summary_uses_normalized_kind() {
  local home fakebin out rc=0
  home=$(make_home invalid-summary)
  printf '%s\n' '- missing-home' > "$home/data/secondmates.md"
  fm_write_meta "$home/state/missing-home.meta" \
    "window=firstmate:fm-missing-home" \
    "project=alpha" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate"
  printf 'working: watching scope\n' > "$home/state/missing-home.status"
  fakebin=$(make_fakebin "$home")
  out=$(run_health "$home" "$fakebin") || rc=$?
  expect_code 1 "$rc" "missing recorded secondmate home should be invalid"
  printf '%s' "$out" | jq -e '
    any(.findings[]; .kind == "secondmate-summary-invalid" and .subject == "missing-home"
        and .evidence == "registry entry has no home")
  ' >/dev/null || fail "normalized secondmate failure kind was not projected: $out"
  pass "normalized snapshot failure kinds drive secondmate health findings"
}

test_truncated_secondmate_inventory_is_inconclusive() {
  local home fakebin out rc=0 id
  home=$(make_home truncated-secondmates)
  cat > "$home/data/secondmates.md" <<'EOF'
- mate-a (host: example.invalid; root: /remote/firstmate; home: /remote/mate-a; scope: work; projects: alpha; added 2026-08-01)
- mate-b (host: example.invalid; root: /remote/firstmate; home: /remote/mate-b; scope: work; projects: alpha; added 2026-08-01)
EOF
  for id in mate-a mate-b; do
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "project=alpha" \
      "harness=codex" \
      "kind=secondmate" \
      "mode=secondmate" \
      "home=/remote/$id" \
      "remote_host=example.invalid" \
      "remote_root=/remote/firstmate"
    printf 'working: watching scope\n' > "$home/state/$id.status"
  done
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm FM_SNAPSHOT_SECONDMATES=1 "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "truncated secondmate inventory should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "secondmate-summary-inconclusive" and .subject == "secondmate-inventory")
  ' >/dev/null || fail "truncated secondmate inventory was not disclosed: $out"
  pass "bounded secondmate omissions make fleet health inconclusive"
}

test_incomplete_registry_does_not_break_secondmate_summary() {
  local home fakebin out rc=0
  home=$(make_home incomplete-registry)
  printf '%s\n' '- some-other-mate' > "$home/data/secondmates.md"
  chmod 000 "$home/data/secondmates.md"
  fm_write_meta "$home/state/omitted-mate.meta" \
    "window=firstmate:fm-omitted-mate" \
    "project=alpha" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/omitted-home"
  printf 'working: watching scope\n' > "$home/state/omitted-mate.status"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "incomplete registry evidence should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "secondmate-summary-inconclusive" and .subject == "omitted-mate")
      and (any(.findings[]; .kind == "secondmate-summary-unavailable" and .subject == "omitted-mate") | not)
  ' >/dev/null || fail "incomplete registry evidence became an actionable summary failure: $out"
  pass "incomplete registry evidence stays distinct from summary failure"
}

test_dangling_secondmate_registry_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home dangling-secondmate-registry)
  ln -s "$home/data/missing-secondmates-target" "$home/data/secondmates.md"
  fakebin=$(make_fakebin "$home")
  out=$(run_health "$home" "$fakebin") || rc=$?
  expect_code 3 "$rc" "dangling secondmate registry should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "secondmate-summary-inconclusive")
  ' >/dev/null || fail "dangling secondmate registry was treated as healthy: $out"
  pass "dangling secondmate registry remains unavailable"
}

test_pending_reply_uses_recorded_grace() {
  local home fakebin out rc=0
  home=$(make_home recorded-grace)
  write_live_ship "$home" grace-task
  write_pending "$home" fedcfedcfedcfedc grace-task awaiting_report 1000 600
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm FM_PENDING_REPLY_NOW=1300 "$HEALTH" --json) || rc=$?
  expect_code 0 "$rc" "recorded pending-reply grace should suppress a premature overdue finding"
  printf '%s' "$out" | jq -e '
    .status == "healthy" and (any(.findings[]; .kind == "pending-reply-overdue") | not)
  ' >/dev/null || fail "checker ignored the record-owned pending grace: $out"
  pass "pending-reply health uses each record's authoritative grace"
}

test_invalid_pending_reply_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home invalid-pending-reply)
  mkdir -p "$home/state/pending-replies"
  printf 'schema=fm-pending-reply.v1\ncorr_id=bad\n' > "$home/state/pending-replies/truncated"
  write_pending "$home" 0123012301230123 malformed-pending awaiting_report
  sed 's/^delivered_epoch=.*/delivered_epoch=not-a-number/' \
    "$home/state/pending-replies/0123012301230123" > "$home/state/pending-replies/invalid.tmp"
  mv "$home/state/pending-replies/invalid.tmp" "$home/state/pending-replies/0123012301230123"
  write_pending "$home" 4567456745674567 owner-gap awaiting_report
  sed 's/^parent_home=.*/parent_home=not-an-absolute-path/' \
    "$home/state/pending-replies/4567456745674567" > "$home/state/pending-replies/owner.tmp"
  mv "$home/state/pending-replies/owner.tmp" "$home/state/pending-replies/4567456745674567"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "invalid pending-reply state should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "pending-reply-inconclusive"
              and .subject == "pending-replies" and .count == 3)
      and (any(.findings[]; .kind == "pending-reply-broken") | not)
  ' >/dev/null || fail "invalid pending-reply record was hidden: $out"
  pass "invalid pending-reply records make health inconclusive"
}

test_dangling_pending_reply_directory_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home dangling-pending-dir)
  ln -s "$home/state/missing-pending-target" "$home/state/pending-replies"
  fakebin=$(make_fakebin "$home")
  out=$(run_health "$home" "$fakebin") || rc=$?
  expect_code 3 "$rc" "dangling pending-replies directory should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "pending-reply-inconclusive" and .subject == "pending-replies")
  ' >/dev/null || fail "dangling pending-replies directory was treated as healthy: $out"
  pass "dangling pending-replies directory remains unavailable"
}

test_inventory_and_missing_listener() {
  local home fakebin out
  home=$(make_home inventory)
  mkdir -p "$home/projects/pr-ship-wt"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] orphan-work - Orphan Work (repo: alpha) (kind: ship) (since 2026-08-01)
- [ ] pr-ship - PR Ship https://github.com/example/alpha/pull/9 (repo: alpha) (kind: ship) (since 2026-08-01)

## Queued
## Done
EOF
  fm_write_meta "$home/state/pr-ship.meta" \
    "window=firstmate:fm-pr-ship" \
    "worktree=$home/projects/pr-ship-wt" \
    "project=alpha" \
    "harness=grok" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=https://github.com/example/alpha/pull/9"
  printf 'working: waiting on CI\n' > "$home/state/pr-ship.status"
  mkdir -p "$home/state/procevent"
  printf 'adapter=lavish\nargc=1\nargv:\npoll\n' > "$home/state/procevent/board-src.source"
  fakebin=$(make_fakebin "$home")
  out=$(run_health "$home" "$fakebin")
  printf '%s' "$out" | jq -e '
    .status == "actionable"
      and any(.findings[]; .kind == "inventory-inconsistent")
      and any(.findings[]; .kind == "result-listener-missing" and .subject == "pr-ship")
      and any(.findings[]; .kind == "result-listener-missing" and .subject == "board-src")
  ' >/dev/null || fail "inventory or listener findings missing: $out"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$HEALTH") || true
  assert_contains "$view" "result-listener-missing" "human view must print listener findings"
  assert_contains "$view" "inventory-inconsistent" "human view must print inventory findings"
  pass "inconsistent inventory and missing listeners are actionable"
}

test_invalid_procevent_registration_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home invalid-procevent-registration)
  mkdir -p "$home/state/procevent/broken.source"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "structurally invalid process-event registration should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "result-listener-inconclusive"
              and .subject == "broken")
      and (any(.findings[]; .kind == "result-listener-missing" and .subject == "broken") | not)
  ' >/dev/null || fail "invalid process-event registration became actionable: $out"
  pass "invalid process-event registrations remain inconclusive"
}

test_dangling_procevent_claim_root_is_inconclusive() {
  local home fakebin claim_root out rc=0
  home=$(make_home dangling-procevent-root)
  mkdir -p "$home/state/procevent"
  printf 'adapter=lavish\nargc=1\nargv:\npoll\n' > "$home/state/procevent/source-one.source"
  claim_root="$home/missing-claims"
  ln -s "$home/missing-claims-target" "$claim_root"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm \
    FM_PROCEVENT_CLAIM_ROOT="$claim_root" "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "dangling process-event claim root should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "result-listener-inconclusive" and .subject == "procevent")
      and (any(.findings[]; .kind == "result-listener-missing" and .subject == "source-one") | not)
  ' >/dev/null || fail "dangling process-event claim root was classified as missing: $out"
  pass "dangling process-event claim root remains inconclusive"
}

test_dangling_procevent_registry_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home dangling-procevent-registry)
  ln -s "$home/state/missing-procevent-target" "$home/state/procevent"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm \
    "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "dangling process-event registry should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "result-listener-inconclusive" and .subject == "procevent")
      and (any(.findings[]; .kind == "result-listener-missing") | not)
  ' >/dev/null || fail "dangling process-event registry was treated as healthy: $out"
  pass "dangling process-event registry remains unavailable"
}

test_dangling_procevent_source_claim_is_inconclusive() {
  local home fakebin claim_root out rc=0
  home=$(make_home dangling-procevent-source-claim)
  mkdir -p "$home/state/procevent"
  printf 'adapter=lavish\nargc=1\nargv:\npoll\n' > "$home/state/procevent/source-one.source"
  claim_root="$home/procevent-claims"
  mkdir -p "$claim_root"
  ln -s "$claim_root/missing-claim-target" "$claim_root/source-one.claim"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm \
    FM_PROCEVENT_CLAIM_ROOT="$claim_root" "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "dangling source claim should be inconclusive"
  printf '%s' "$out" | jq -e '
    any(.findings[]; .kind == "result-listener-inconclusive" and .subject == "source-one")
      and (any(.findings[]; .kind == "result-listener-missing" and .subject == "source-one") | not)
  ' >/dev/null || fail "dangling source claim was classified as missing: $out"
  pass "dangling process-event source claims remain inconclusive"
}

test_paused_ship_still_requires_pr_listener() {
  local home fakebin out rc=0
  home=$(make_home paused-pr-listener)
  write_live_ship "$home" paused-ship
  printf 'pr=https://github.com/example/alpha/pull/18\n' >> "$home/state/paused-ship.meta"
  printf 'paused: waiting for upstream checks\n' > "$home/state/paused-ship.status"
  touch -t 202001011200 "$home/state/paused-ship.status"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 1 "$rc" "paused ship without its PR listener should be actionable"
  printf '%s' "$out" | jq -e '
    .status == "actionable"
      and any(.findings[]; .kind == "result-listener-missing" and .subject == "paused-ship")
      and (any(.findings[]; .kind == "missed-handoff" and .subject == "paused-ship") | not)
  ' >/dev/null || fail "paused ship escaped PR-listener validation: $out"
  pass "declared waits retain their required PR listeners"
}

test_invalid_current_pr_metadata_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home invalid-current-pr)
  write_live_ship "$home" invalid-current-pr
  printf 'pr=not-a-url\n' >> "$home/state/invalid-current-pr.meta"
  printf 'paused: waiting for CI\n' > "$home/state/invalid-current-pr.status"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm \
    "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "invalid current PR metadata should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "result-listener-inconclusive"
              and .subject == "pr-polls"
              and (.evidence | contains("current PR metadata")))
      and (any(.findings[]; .kind == "result-listener-missing"
               and .subject == "invalid-current-pr") | not)
  ' >/dev/null || fail "invalid current PR metadata became actionable: $out"
  pass "invalid current PR metadata remains inconclusive"
}

test_unknown_worker_state_does_not_create_missing_pr_listener() {
  local home fakebin out rc=0
  home=$(make_home unknown-pr-listener)
  mkdir -p "$home/projects/unknown-pr-wt"
  fm_write_meta "$home/state/unknown-pr.meta" \
    "window=firstmate:fm-unknown-pr" \
    "worktree=$home/projects/unknown-pr-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=https://github.com/example/alpha/pull/22"
  printf 'working: waiting on the unknown Codex lifecycle\n' > "$home/state/unknown-pr.status"
  printf 'fm-unknown-pr\n' > "$home/state/.fake-windows"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm \
    "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "unknown worker state should keep PR listener evidence inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "result-listener-inconclusive"
              and .subject == "unknown-pr")
      and (any(.findings[]; .kind == "result-listener-missing"
               and .subject == "unknown-pr") | not)
  ' >/dev/null || fail "unknown worker state produced a missing listener finding: $out"
  pass "unknown worker state does not create a missing PR listener"
}

test_invalid_pr_listener_evidence_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home invalid-pr-listener-evidence)
  write_live_ship "$home" invalid-pr
  printf 'pr=https://github.com/example/alpha/pull/24\n' >> "$home/state/invalid-pr.meta"
  printf 'paused: waiting for CI\n' > "$home/state/invalid-pr.status"
  printf 'not a valid merge-poll listener\n' > "$home/state/invalid-pr.check.sh"
  chmod 0600 "$home/state/invalid-pr.check.sh"
  ln -s "$home/state/missing-retirement" "$home/state/retired.pr-poll-merge-notified"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm \
    "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "invalid PR-listener artifacts should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "result-listener-inconclusive" and .subject == "pr-polls"
              and .count == 2)
      and (any(.findings[]; .kind == "result-listener-missing" and .subject == "invalid-pr") | not)
  ' >/dev/null || fail "invalid PR-listener evidence became actionable: $out"
  pass "invalid PR-listener evidence remains inconclusive"
}

test_unrelated_pr_listener_corruption_preserves_missing_listener() {
  local home fakebin out rc=0
  home=$(make_home unrelated-pr-listener-corruption)
  write_live_ship "$home" missing-listener
  printf 'pr=https://github.com/example/alpha/pull/25\n' >> "$home/state/missing-listener.meta"
  printf 'paused: waiting for CI\n' > "$home/state/missing-listener.status"
  printf 'not a valid merge-poll listener\n' > "$home/state/unrelated.check.sh"
  chmod 0600 "$home/state/unrelated.check.sh"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "unrelated PR-listener corruption should preserve both verdicts"
  printf '%s' "$out" | jq -e '
    any(.findings[]; .kind == "result-listener-inconclusive" and .subject == "pr-polls")
      and any(.findings[]; .kind == "result-listener-missing" and .subject == "missing-listener")
  ' >/dev/null || fail "unrelated PR-listener corruption suppressed a proven missing listener: $out"
  pass "unrelated PR-listener corruption does not suppress missing listeners"
}

test_matching_retired_pr_listener_is_not_missing() {
  local home fakebin marker out rc=0
  home=$(make_home retired-pr-listener)
  write_live_ship "$home" retired-pr
  printf 'pr=https://github.com/example/alpha/pull/19\n' >> "$home/state/retired-pr.meta"
  marker="$home/state/retired-pr.pr-poll-merge-notified"
  printf '%s\n' fm-pr-poll-merge-notified-v1 github github.com example/alpha 19 > "$marker"
  chmod 0600 "$marker"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 0 "$rc" "matching terminal PR notification should retire the listener requirement"
  printf '%s' "$out" | jq -e '
    .status == "healthy"
      and (any(.findings[]; .kind == "result-listener-missing"
               and .subject == "retired-pr") | not)
  ' >/dev/null || fail "matching retired PR listener was reported missing: $out"

  printf '%s\n' fm-pr-poll-merge-notified-v1 github github.com example/alpha 18 > "$marker"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 1 "$rc" "a terminal notification for another PR must not retire the current listener"
  printf '%s' "$out" | jq -e '
    .status == "actionable"
      and any(.findings[]; .kind == "result-listener-missing"
              and .subject == "retired-pr")
  ' >/dev/null || fail "mismatched terminal PR notification suppressed a missing listener: $out"
  pass "only matching terminal PR notifications retire listener requirements"
}

test_inconclusive_dominates_actionable_status() {
  local home fakebin out rc=0
  home=$(make_home mixed-confidence)
  write_live_ship "$home" dead-mixed
  mkdir -p "$home/projects/unreadable-mixed-wt"
  fm_write_meta "$home/state/unreadable-mixed.meta" \
    "backend=herdr" \
    "window=malformed-herdr-target" \
    "worktree=$home/projects/unreadable-mixed-wt" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'working: implementing\n' > "$home/state/unreadable-mixed.status"
  : > "$home/state/.fake-windows"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "inconclusive evidence should dominate actionable report status"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "dead-direct-report" and .subject == "dead-mixed")
      and any(.findings[]; .kind == "endpoint-inconclusive" and .subject == "unreadable-mixed")
  ' >/dev/null || fail "mixed-confidence report masked incomplete evidence: $out"
  pass "inconclusive evidence dominates overall status without hiding findings"
}

test_unreadable_supervision_lock_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home unreadable-supervision-lock)
  write_live_ship "$home" supervised-worker
  fresh_autoarm_supervision "$home"
  mkdir -p "$home/state/.watch.lock"
  printf '999999\n' > "$home/state/.watch.lock/pid"
  chmod 000 "$home/state/.watch.lock"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=persistent "$HEALTH" --json) || rc=$?
  chmod 700 "$home/state/.watch.lock"
  expect_code 3 "$rc" "unreadable watcher-lock evidence should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "supervision-inconclusive")
      and (any(.findings[]; .kind == "supervision-unhealthy") | not)
  ' >/dev/null || fail "unreadable supervision evidence became actionable: $out"
  pass "unreadable watcher-lock evidence remains inconclusive"
}

test_malformed_supervision_pid_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home malformed-supervision-pid)
  write_live_ship "$home" supervised-worker
  fresh_autoarm_supervision "$home"
  mkdir -p "$home/state/.watch.lock"
  printf 'not-a-pid\n' > "$home/state/.watch.lock/pid"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=persistent \
    "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "malformed watcher-lock PID should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "supervision-inconclusive")
      and (any(.findings[]; .kind == "supervision-unhealthy") | not)
  ' >/dev/null || fail "malformed supervision PID became actionable: $out"
  pass "malformed watcher-lock PID remains unavailable"
}

test_unreadable_supervision_beacon_is_inconclusive() {
  local home fakebin out rc=0
  home=$(make_home unreadable-supervision-beacon)
  write_live_ship "$home" supervised-worker
  fresh_autoarm_supervision "$home"
  rm "$home/state/.last-watcher-beat"
  ln -s "$home/state/missing-beacon" "$home/state/.last-watcher-beat"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=persistent \
    "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "unreadable watcher beacon should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "supervision-inconclusive")
      and (any(.findings[]; .kind == "supervision-unhealthy") | not)
  ' >/dev/null || fail "unreadable supervision beacon became actionable: $out"
  pass "unreadable watcher beacon remains inconclusive"
}

test_incomplete_supervision_lock_is_inconclusive() {
  local home fakebin out rc=0 watcher_pid identity
  home=$(make_home incomplete-supervision-lock)
  write_live_ship "$home" supervised-worker
  fresh_autoarm_supervision "$home"
  mkdir -p "$home/state/.watch.lock"
  sleep 30 &
  watcher_pid=$!
  identity=$(fm_pid_identity "$watcher_pid") || {
    kill "$watcher_pid" 2>/dev/null || true
    fail "could not identify the supervision fixture process"
  }
  printf '%s\n' "$watcher_pid" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=persistent \
    "$HEALTH" --json) || rc=$?
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  expect_code 3 "$rc" "incomplete watcher-lock metadata should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "supervision-inconclusive")
      and (any(.findings[]; .kind == "supervision-unhealthy") | not)
  ' >/dev/null || fail "incomplete supervision metadata became actionable: $out"
  pass "incomplete watcher-lock metadata remains unavailable"
}

test_internal_worker_failure_returns_json() {
  local home fakebin out rc=0
  home=$(make_home internal-worker-failure)
  write_live_ship "$home" hash-failure
  : > "$home/state/.fake-windows"
  fakebin=$(make_fakebin "$home")
  cat > "$fakebin/shasum" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/shasum"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "internal worker failure should use the incomplete exit"
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-health.v1"
      and .status == "incomplete"
      and .reason == "fleet health check failed"
  ' >/dev/null || fail "internal worker failure omitted stable JSON: $out"
  pass "internal worker failures retain the stable JSON contract"
}

test_complete_timeout_covers_fingerprinting() {
  local home fakebin out rc=0
  home=$(make_home complete-timeout)
  write_live_ship "$home" hash-task
  : > "$home/state/.fake-windows"
  fakebin=$(make_fakebin "$home")
  cat > "$fakebin/shasum" <<'SH'
#!/usr/bin/env bash
sleep 3
SH
  chmod +x "$fakebin/shasum"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_FLEET_HEALTH_TIMEOUT=1 "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "the complete health check should honor its timeout"
  printf '%s' "$out" | jq -e '
    .status == "incomplete" and .reason == "fleet health check timed out"
  ' >/dev/null || fail "post-snapshot timeout did not produce incomplete output: $out"
  pass "the timeout bounds collection, evaluation, and fingerprinting"
}

test_human_view_and_incomplete_exit() {
  local home fakebin view rc=0
  home=$(make_home human)
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$HEALTH") || rc=$?
  expect_code 0 "$rc" "healthy human view should exit 0"
  assert_contains "$view" "Status: healthy" "human view should print status"
  rc=0
  "$HEALTH" --bogus >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "human usage error still exits 2"
  pass "human view and usage exit semantics hold"
}

test_usage_exit
test_invalid_handoff_threshold_is_usage_error
test_healthy_empty_fleet
test_missing_state_home_remains_unmodified
test_malformed_snapshot_is_incomplete
test_snapshot_task_evidence_requires_keys_and_known_states
test_remote_snapshot_probe_disabled_skips_remote_state
test_dangling_state_path_is_inconclusive
test_unsearchable_state_is_inconclusive
test_dangling_metadata_is_inconclusive
test_unsearchable_nested_inventories_are_inconclusive
test_actionable_dead_direct_report
test_dead_agent_with_live_endpoint
test_codex_resume_banner_is_dead_session
test_unverified_backend_codex_banner_is_dead_session
test_failed_codex_capture_is_inconclusive
test_codex_bare_shell_is_dead_session
test_live_codex_without_banner_is_not_dead_session
test_missed_handoff_after_done_signal
test_later_inbox_clears_missed_handoff
test_recent_done_signal_is_not_missed_handoff
test_missed_handoff_after_contracted_step_complete_signal
test_failed_status_is_not_missed_handoff
test_dangling_status_log_is_inconclusive
test_captain_decision_wait_is_not_missed_handoff
test_handled_inbox_corruption_is_inconclusive
test_unrelated_inbox_corruption_preserves_missed_handoff
test_unreadable_local_endpoint_is_inconclusive
test_terminal_unreadable_endpoint_is_inconclusive
test_historical_status_pr_does_not_require_listener
test_grouped_inbox_and_stable_fingerprints
test_invalid_inbox_records_are_inconclusive
test_invalid_inbox_containers_are_inconclusive
test_remote_liveness_is_inconclusive
test_unknown_worker_state_is_inconclusive
test_registry_only_remote_evidence_is_inconclusive
test_pending_reply_broken_and_historical_noise_omitted
test_recovery_sending_owner_verdicts
test_committed_recovery_outcome_transition_is_valid
test_inconclusive_secondmate_summary_not_broken
test_invalid_secondmate_summary_uses_normalized_kind
test_truncated_secondmate_inventory_is_inconclusive
test_incomplete_registry_does_not_break_secondmate_summary
test_dangling_secondmate_registry_is_inconclusive
test_pending_reply_uses_recorded_grace
test_invalid_pending_reply_is_inconclusive
test_dangling_pending_reply_directory_is_inconclusive
test_inventory_and_missing_listener
test_invalid_procevent_registration_is_inconclusive
test_dangling_procevent_claim_root_is_inconclusive
test_dangling_procevent_registry_is_inconclusive
test_dangling_procevent_source_claim_is_inconclusive
test_paused_ship_still_requires_pr_listener
test_invalid_current_pr_metadata_is_inconclusive
test_unknown_worker_state_does_not_create_missing_pr_listener
test_invalid_pr_listener_evidence_is_inconclusive
test_unrelated_pr_listener_corruption_preserves_missing_listener
test_matching_retired_pr_listener_is_not_missing
test_inconclusive_dominates_actionable_status
test_unreadable_supervision_lock_is_inconclusive
test_malformed_supervision_pid_is_inconclusive
test_unreadable_supervision_beacon_is_inconclusive
test_incomplete_supervision_lock_is_inconclusive
test_internal_worker_failure_returns_json
test_complete_timeout_covers_fingerprinting
test_human_view_and_incomplete_exit
