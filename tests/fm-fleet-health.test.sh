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
    printf 'work in progress\nesc to interrupt\n'
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

write_pending() {  # <home> <corr> <task> <phase> [completed_epoch] [grace]
  local home=$1 corr=$2 task=$3 phase=$4 completed=${5-} grace=${6:-120}
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
recovery_sender_pid=
recovery_sender_identity=
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
    "harness=codex" \
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
    "harness=codex" \
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
test_actionable_dead_direct_report
test_dead_agent_with_live_endpoint
test_grouped_inbox_and_stable_fingerprints
test_remote_liveness_is_inconclusive
test_pending_reply_broken_and_historical_noise_omitted
test_inconclusive_secondmate_summary_not_broken
test_invalid_secondmate_summary_uses_normalized_kind
test_truncated_secondmate_inventory_is_inconclusive
test_pending_reply_uses_recorded_grace
test_inventory_and_missing_listener
test_complete_timeout_covers_fingerprinting
test_human_view_and_incomplete_exit
