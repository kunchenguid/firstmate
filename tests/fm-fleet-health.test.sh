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

write_pending() {  # <home> <corr> <task> <phase> [completed_epoch] [grace] [sender-pid] [sender-identity]
  local home=$1 corr=$2 task=$3 phase=$4 completed=${5-} grace=${6:-120}
  local sender_pid=${7-} sender_identity=${8-}
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
recovery_delivery_outcome=
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
  pass "usage errors exit 2"
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
              and .count == 2 and (.evidence | contains("are invalid")))
      and any(.findings[]; .kind == "steering-inbox-inconclusive"
              and .count == 1 and (.evidence | contains("could not be aged")))
      and (any(.findings[]; .kind == "steering-inbox-aged") | not)
  ' >/dev/null || fail "malformed inbox evidence was hidden: $out"
  pass "invalid and unageable inbox records remain inconclusive"
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
  printf 'working: ping\n' > "$home/state/attorney-data.status"
  printf 'needs-decision [key=shape]: choose an API\n' >> "$home/state/attorney-data.status"
  printf 'working: still going\n' >> "$home/state/attorney-data.status"
  printf 'working: another historical reply event\n' >> "$home/state/attorney-data.status"
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
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 3 "$rc" "invalid pending-reply state should be inconclusive"
  printf '%s' "$out" | jq -e '
    .status == "inconclusive"
      and any(.findings[]; .kind == "pending-reply-inconclusive"
              and .subject == "pending-replies" and .count == 1)
      and (any(.findings[]; .kind == "pending-reply-broken") | not)
  ' >/dev/null || fail "invalid pending-reply record was hidden: $out"
  pass "invalid pending-reply records make health inconclusive"
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
  printf '#!/usr/bin/env bash\nprintf "OPEN\\n"\n' > "$home/state/pr-ship.check.sh"
  chmod 0600 "$home/state/pr-ship.check.sh"
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

test_invalid_procevent_registration_is_reported() {
  local home fakebin out rc=0
  home=$(make_home invalid-procevent-registration)
  mkdir -p "$home/state/procevent/broken.source"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 1 "$rc" "structurally invalid process-event registration should be actionable"
  printf '%s' "$out" | jq -e '
    .status == "actionable"
      and any(.findings[]; .kind == "result-listener-missing"
              and .subject == "broken"
              and (.evidence | contains("owner=invalid")))
  ' >/dev/null || fail "invalid process-event registration was hidden: $out"
  pass "invalid process-event registrations remain visible"
}

test_paused_ship_still_requires_pr_listener() {
  local home fakebin out rc=0
  home=$(make_home paused-pr-listener)
  write_live_ship "$home" paused-ship
  printf 'pr=https://github.com/example/alpha/pull/18\n' >> "$home/state/paused-ship.meta"
  printf 'paused: waiting for upstream checks\n' > "$home/state/paused-ship.status"
  fresh_autoarm_supervision "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_MODEL=autoarm "$HEALTH" --json) || rc=$?
  expect_code 1 "$rc" "paused ship without its PR listener should be actionable"
  printf '%s' "$out" | jq -e '
    .status == "actionable"
      and any(.findings[]; .kind == "result-listener-missing" and .subject == "paused-ship")
  ' >/dev/null || fail "paused ship escaped PR-listener validation: $out"
  pass "declared waits retain their required PR listeners"
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
test_healthy_empty_fleet
test_missing_state_home_remains_unmodified
test_unsearchable_state_is_inconclusive
test_unsearchable_nested_inventories_are_inconclusive
test_actionable_dead_direct_report
test_dead_agent_with_live_endpoint
test_unreadable_local_endpoint_is_inconclusive
test_terminal_unreadable_endpoint_is_inconclusive
test_historical_status_pr_does_not_require_listener
test_grouped_inbox_and_stable_fingerprints
test_invalid_inbox_records_are_inconclusive
test_remote_liveness_is_inconclusive
test_unknown_worker_state_is_inconclusive
test_registry_only_remote_evidence_is_inconclusive
test_pending_reply_broken_and_historical_noise_omitted
test_recovery_sending_owner_verdicts
test_inconclusive_secondmate_summary_not_broken
test_invalid_secondmate_summary_uses_normalized_kind
test_truncated_secondmate_inventory_is_inconclusive
test_incomplete_registry_does_not_break_secondmate_summary
test_pending_reply_uses_recorded_grace
test_invalid_pending_reply_is_inconclusive
test_inventory_and_missing_listener
test_invalid_procevent_registration_is_reported
test_paused_ship_still_requires_pr_listener
test_matching_retired_pr_listener_is_not_missing
test_inconclusive_dominates_actionable_status
test_unreadable_supervision_lock_is_inconclusive
test_internal_worker_failure_returns_json
test_complete_timeout_covers_fingerprinting
test_human_view_and_incomplete_exit
