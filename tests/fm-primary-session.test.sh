#!/usr/bin/env bash
# Hermetic behavior tests for the recoverable primary-session handoff.
# Every Paseo call is a fake local provider fixture.
# No real agent, daemon, provider transcript, or Firstmate home is inspected or
# mutated by this suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-primary-session)
LIVE_PIDS=()
AGENT_A=agent-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
AGENT_B=agent-bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
AGENT_C=agent-cccccccc-cccc-cccc-cccc-cccccccccccc

record_last_value() {
  local file=$1 key=$2
  sed -n "s/^${key}=//p" "$file" | tail -1
}

cleanup_primary_session_tests() {
  local pid
  for pid in "${LIVE_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_primary_session_tests EXIT

write_fake_paseo() {
  local fakebin=$1
  cat > "$fakebin/paseo" <<'SH'
#!/usr/bin/env bash
set -u
home=${PASEO_HOME:?}
cmd1=${1:-}
cmd2=${2:-}

inspect_agent() {
  local id=$1 file archived=false status provider cwd pending parent persistence
  file=$(resolve_agent_file "$id") || exit 4
  [ ! -e "$home/archived-$id" ] || archived=true
  status=$(jq -r '.lastStatus' "$file")
  [ "$archived" = false ] || status=closed
  provider=$(jq -r '.provider' "$file")
  cwd=$(jq -r '.cwd' "$file")
  pending=$(jq -r '.testPending // 0' "$file")
  parent=$(jq -r '.testParent // empty' "$file")
  persistence=$(jq -r '.testPersistence // true' "$file")
  jq -cn \
    --arg id "$id" \
    --arg provider "$provider" \
    --arg status "$status" \
    --arg cwd "$cwd" \
    --arg parent "$parent" \
    --argjson archived "$archived" \
    --argjson pending "$pending" \
    --argjson persistence "$persistence" '
      {
        Id:$id,
        Provider:$provider,
        Status:$status,
        Archived:$archived,
        Cwd:$cwd,
        Capabilities:{Persistence:$persistence},
        PendingPermissions:[range(0;$pending) | {id:("permission-" + tostring),tool:"fixture"}],
        ParentAgentId:(if $parent == "" then null else $parent end)
      }
    '
}

resolve_agent_file() {
  local id=$1 candidate match='' count=0
  if [ -f "$home/agents/$id.json" ]; then
    printf '%s\n' "$home/agents/$id.json"
    return 0
  fi
  for candidate in "$home"/agents/*/"$id.json"; do
    [ -f "$candidate" ] || continue
    match=$candidate
    count=$(( count + 1 ))
  done
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$match"
}

list_agents() {
  local file id archived
  for file in "$home"/agents/*.json "$home"/agents/*/*.json; do
    [ -e "$file" ] || continue
    id=$(jq -r '.id' "$file")
    archived=false
    [ ! -e "$home/archived-$id" ] || archived=true
    [ "$archived" = false ] || continue
    jq -cn --arg id "$id" '{id:$id,status:"idle",provider:"claude",cwd:"fixture"}'
  done | jq -s '.'
}

case "$cmd1 $cmd2" in
  "agent inspect")
    inspect_agent "${3:?}"
    ;;
  "agent ls")
    list_agents
    ;;
  "agent archive")
    id=${3:?}
    printf 'archive %s\n' "$id" >> "$home/calls.log"
    if [ -e "$home/suspend-fail" ]; then
      printf 'fixture suspend failed\n' >&2
      exit 9
    fi
    : > "$home/archived-$id"
    if [ ! -e "$home/keep-owner-alive" ]; then
      owner=$(cat "$home/owner-pid")
      kill "$owner" 2>/dev/null || true
    fi
    if [ -e "$home/chmod-receipt-after-archive" ]; then
      chmod 400 "$FM_HOME"/data/primary-session-handoffs/*.receipt
    fi
    jq -cn --arg id "$id" '{agentId:$id,status:"archived"}'
    ;;
  "agent reload")
    id=${3:?}
    printf 'reload %s\n' "$id" >> "$home/calls.log"
    rm -f "$home/archived-$id"
    if [ -e "$home/reload-spawn" ]; then
      PASEO_AGENT_ID="$id" "$FM_TEST_FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$PASEO_HOME/restored-pid"
        "$FM_TEST_ROOT/bin/fm-session-start.sh" >/dev/null 2>&1
        : > "$PASEO_HOME/restored-started"
        trap "exit 0" TERM INT
        while :; do sleep 0.2; done
      ' </dev/null >/dev/null 2>&1 &
      printf '%s\n' "$!" > "$home/reload-launch-pid"
    fi
    jq -cn --arg id "$id" '{agentId:$id,status:"reloaded"}'
    ;;
  *)
    printf 'unsupported fake paseo call: %s\n' "$*" >&2
    exit 8
    ;;
esac
SH
  chmod +x "$fakebin/paseo"
}

write_fake_quota() {
  local fakebin=$1
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
provider=claude
prev=
for arg in "$@"; do
  [ "$prev" = --provider ] && provider=$arg
  prev=$arg
done
remaining=100
[ ! -e "${PASEO_HOME:?}/quota-blocked" ] || remaining=0
state=fresh
[ ! -e "$PASEO_HOME/quota-unknown" ] || state=error
jq -cn \
  --arg provider "$provider" \
  --arg state "$state" \
  --argjson remaining "$remaining" '
    {
      schemaVersion:1,
      providers:[{
        provider:$provider,
        state:{status:$state,stale:false},
        windows:[{id:"five_hour",kind:"session",percentRemaining:$remaining}]
      }]
    }
  '
SH
  chmod +x "$fakebin/quota-axi"
}

new_world() {
  local name=$1 script
  W_DIR="$TMP_ROOT/$name"
  W_ROOT="$W_DIR/root"
  W_PASEO="$W_DIR/paseo"
  W_FAKEBIN="$W_DIR/fakebin"
  mkdir -p "$W_ROOT/bin" "$W_ROOT/state" "$W_ROOT/data" "$W_PASEO/agents" "$W_FAKEBIN"
  git init -q -b main "$W_ROOT"
  git -C "$W_ROOT" commit -q --allow-empty -m init
  : > "$W_ROOT/AGENTS.md"
  for script in \
    fm-primary-session.sh \
    fm-primary-session-lib.sh \
    fm-session-lock-lib.sh \
    fm-lock.sh \
    fm-wake-lib.sh \
    fm-gate-refuse-lib.sh \
    fm-primary-scope-lib.sh; do
    cp "$ROOT/bin/$script" "$W_ROOT/bin/$script"
  done
  chmod +x "$W_ROOT/bin/fm-primary-session.sh" "$W_ROOT/bin/fm-lock.sh"
  cat > "$W_ROOT/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
set -u
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$dir/fm-lock.sh"
printf 'session-start owner=%s\n' "$(cat "${FM_HOME:?}/state/.lock")" >> "$FM_HOME/state/session-start.log"
SH
  chmod +x "$W_ROOT/bin/fm-session-start.sh"
  ln -s /bin/bash "$W_FAKEBIN/claude"
  W_FAKE_CLAUDE="$W_FAKEBIN/claude"
  write_fake_paseo "$W_FAKEBIN"
  write_fake_quota "$W_FAKEBIN"
}

write_agent() {
  local id=$1 status=${2:-idle} pending=${3:-0} attention=${4:-false} reason=${5:-}
  local activity=${6:-2026-07-29T07:00:00Z} parent=${7:-}
  local last_user=${8:-2026-07-29T06:00:00Z}
  jq -n \
    --arg id "$id" \
    --arg provider claude \
    --arg cwd "$W_ROOT" \
    --arg status "$status" \
    --arg activity "$activity" \
    --arg last_user "$last_user" \
    --arg reason "$reason" \
    --arg parent "$parent" \
    --argjson pending "$pending" \
    --argjson attention "$attention" '
      {
        id:$id,
        provider:$provider,
        cwd:$cwd,
        lastStatus:$status,
        archivedAt:null,
        requiresAttention:$attention,
        attentionReason:(if $reason == "" then null else $reason end),
        lastUserMessageAt:$last_user,
        lastActivityAt:$activity,
        persistence:{provider:$provider,sessionId:("provider-" + $id)},
        runtimeInfo:{provider:$provider,sessionId:("provider-" + $id)},
        testPending:$pending,
        testParent:$parent,
        testPersistence:true
      }
    ' > "$W_PASEO/agents/$id.json"
}

start_owner() {
  local id=$1 supervisor_pid tries=0
  # shellcheck disable=SC2016
  PASEO_AGENT_ID="$id" "$W_FAKE_CLAUDE" -c '
    PASEO_AGENT_ID="$1" "$2" -c '\''
      trap "exit 0" TERM INT
      while :; do sleep 0.2; done
    '\'' _ "$3" </dev/null >/dev/null 2>&1 &
    child=$!
    printf "%s\n" "$child" > "$4"
    wait "$child"
  ' _ "$id" "$W_FAKE_CLAUDE" "provider-$id" "$W_PASEO/started-owner-pid" \
    </dev/null >/dev/null 2>&1 &
  supervisor_pid=$!
  LIVE_PIDS+=("$supervisor_pid")
  while [ ! -s "$W_PASEO/started-owner-pid" ]; do
    tries=$(( tries + 1 ))
    [ "$tries" -lt 50 ] || fail "owner fixture did not start"
    sleep 0.02
  done
  OWNER_PID=$(cat "$W_PASEO/started-owner-pid")
  LIVE_PIDS+=("$OWNER_PID")
  printf '%s\n' "$OWNER_PID" > "$W_ROOT/state/.lock"
  printf '%s\n' "$OWNER_PID" > "$W_PASEO/owner-pid"
  sleep 0.1
}

start_descriptor_owner() {
  local id=$1 supervisor_pid tries=0
  # shellcheck disable=SC2016
  PASEO_AGENT_ID="$id" \
    FM_HOME="$W_ROOT" \
    FM_ROOT_OVERRIDE="$W_ROOT" \
    PASEO_HOME="$W_PASEO" \
    PATH="$W_FAKEBIN:$PATH" \
    "$W_FAKE_CLAUDE" -c '
      "$1/bin/fm-lock.sh" > "$2" 2>&1 || exit $?
      trap "exit 0" TERM INT
      while :; do sleep 0.2; done
    ' _ "$W_ROOT" "$W_PASEO/owner-lock.out" </dev/null >/dev/null 2>&1 &
  supervisor_pid=$!
  LIVE_PIDS+=("$supervisor_pid")
  while [ ! -s "$W_ROOT/state/.lock" ] || [ ! -s "$W_ROOT/state/.lock.owner" ]; do
    tries=$(( tries + 1 ))
    [ "$tries" -lt 100 ] || fail "descriptor owner fixture did not acquire the lock: $(cat "$W_PASEO/owner-lock.out" 2>/dev/null)"
    sleep 0.02
  done
  OWNER_PID=$(cat "$W_ROOT/state/.lock")
  LIVE_PIDS+=("$OWNER_PID")
  printf '%s\n' "$OWNER_PID" > "$W_PASEO/owner-pid"
  sleep 0.1
}

run_takeover() {
  local agent_id=$1
  RUN_RC=0
  # shellcheck disable=SC2016
  RUN_OUT=$(
    env -u PASEO_AGENT_ID \
      FM_HOME="$W_ROOT" \
      FM_ROOT_OVERRIDE="$W_ROOT" \
      PASEO_HOME="$W_PASEO" \
      FM_PRIMARY_OWNER_EXIT_TIMEOUT=3 \
      PATH="$W_FAKEBIN:$PATH" \
      "$W_FAKE_CLAUDE" -c '
        "$1/bin/fm-primary-session.sh" takeover "$2"
        rc=$?
        :
        exit "$rc"
      ' _ "$W_ROOT" "$agent_id" 2>&1
  ) || RUN_RC=$?
}

run_restore() {
  local receipt_id=$1
  RUN_RC=0
  RUN_OUT=$(
    FM_HOME="$W_ROOT" \
      FM_ROOT_OVERRIDE="$W_ROOT" \
      PASEO_HOME="$W_PASEO" \
      FM_PRIMARY_RELOAD_TIMEOUT=2 \
      FM_TEST_FAKE_CLAUDE="$W_FAKE_CLAUDE" \
      FM_TEST_ROOT="$W_ROOT" \
      PATH="$W_FAKEBIN:$PATH" \
      "$W_ROOT/bin/fm-primary-session.sh" restore "$receipt_id" 2>&1
  ) || RUN_RC=$?
}

run_lock_acquire() {
  RUN_RC=0
  # shellcheck disable=SC2016
  RUN_OUT=$(
    env -u PASEO_AGENT_ID \
      FM_HOME="$W_ROOT" \
      FM_ROOT_OVERRIDE="$W_ROOT" \
      PASEO_HOME="$W_PASEO" \
      PATH="$W_FAKEBIN:$PATH" \
      "$W_FAKE_CLAUDE" -c '
        "$1/bin/fm-lock.sh"
        rc=$?
        :
        exit "$rc"
      ' _ "$W_ROOT" 2>&1
  ) || RUN_RC=$?
}

only_receipt() {
  local -a receipts
  receipts=("$W_ROOT"/data/primary-session-handoffs/*.receipt)
  [ "${#receipts[@]}" -eq 1 ] && [ -f "${receipts[0]}" ] || return 1
  printf '%s\n' "${receipts[0]}"
}

test_owner_mismatch_refuses_without_archive() {
  local descriptor_tmp
  new_world owner-mismatch
  write_agent "$AGENT_A"
  write_agent "$AGENT_B"
  start_owner "$AGENT_A"
  run_takeover "$AGENT_B"
  [ "$RUN_RC" -ne 0 ] || fail "owner mismatch unexpectedly took over"
  assert_contains "$RUN_OUT" "owner mismatch" "owner mismatch lacked a typed refusal"
  kill -0 "$OWNER_PID" 2>/dev/null || fail "owner mismatch stopped the real owner"
  [ "$(cat "$W_ROOT/state/.lock")" = "$OWNER_PID" ] || fail "owner mismatch changed the lock"
  [ ! -e "$W_PASEO/calls.log" ] || fail "owner mismatch invoked Paseo lifecycle"

  new_world owner-identity-mismatch
  write_agent "$AGENT_A"
  start_descriptor_owner "$AGENT_A"
  descriptor_tmp="$W_ROOT/state/.lock.owner.test"
  awk '
    /^owner_identity_sha256=/ {
      print "owner_identity_sha256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      next
    }
    { print }
  ' "$W_ROOT/state/.lock.owner" > "$descriptor_tmp"
  mv "$descriptor_tmp" "$W_ROOT/state/.lock.owner"
  run_takeover "$AGENT_A"
  [ "$RUN_RC" -ne 0 ] || fail "process-identity mismatch unexpectedly took over"
  assert_contains "$RUN_OUT" "owner mismatch" "process-identity mismatch lacked a typed refusal"
  kill -0 "$OWNER_PID" 2>/dev/null || fail "process-identity mismatch stopped the owner"
  [ "$(cat "$W_ROOT/state/.lock")" = "$OWNER_PID" ] || fail "process-identity mismatch changed the lock"
  [ ! -e "$W_PASEO/calls.log" ] || fail "process-identity mismatch invoked Paseo lifecycle"
  pass "primary-session: requested external session and process identity must exactly match the live lock owner"
}

test_busy_pending_and_unknown_refuse() {
  new_world busy
  write_agent "$AGENT_A" running 0 false "" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  start_owner "$AGENT_A"
  run_takeover "$AGENT_A"
  [ "$RUN_RC" -ne 0 ] || fail "busy owner unexpectedly took over"
  assert_contains "$RUN_OUT" "busy:" "busy owner did not retain its distinct classification"
  [ ! -e "$W_PASEO/calls.log" ] || fail "busy owner invoked Paseo archive"

  new_world pending
  write_agent "$AGENT_A" idle 1
  start_owner "$AGENT_A"
  run_takeover "$AGENT_A"
  [ "$RUN_RC" -ne 0 ] || fail "pending-permission owner unexpectedly took over"
  assert_contains "$RUN_OUT" "waiting-on-captain:" "pending permission did not classify as waiting on captain"
  [ ! -e "$W_PASEO/calls.log" ] || fail "pending owner invoked Paseo archive"

  new_world unknown
  write_agent "$AGENT_A" mystery
  start_owner "$AGENT_A"
  run_takeover "$AGENT_A"
  [ "$RUN_RC" -ne 0 ] || fail "unknown owner unexpectedly took over"
  assert_contains "$RUN_OUT" "unknown:" "unknown owner lacked a distinct classification"
  [ ! -e "$W_PASEO/calls.log" ] || fail "unknown owner invoked Paseo archive"
  pass "primary-session: busy, pending-action, and unknown owners fail closed with distinct states"
}

test_wedged_and_attached_child_refuse() {
  new_world wedged
  write_agent "$AGENT_A" running 0 false "" "2020-01-01T00:00:00Z" "" "2019-01-01T00:00:00Z"
  start_owner "$AGENT_A"
  run_takeover "$AGENT_A"
  [ "$RUN_RC" -ne 0 ] || fail "wedged owner unexpectedly took over"
  assert_contains "$RUN_OUT" "wedged:" "wedged owner lacked its distinct classification"

  new_world child
  write_agent "$AGENT_A"
  write_agent "$AGENT_B" idle 0 false "" "2026-07-29T07:00:00Z" "$AGENT_A"
  start_owner "$AGENT_A"
  run_takeover "$AGENT_A"
  [ "$RUN_RC" -ne 0 ] || fail "owner with attached child unexpectedly took over"
  assert_contains "$RUN_OUT" "attached child agents" "attached child refusal was not explicit"
  [ ! -e "$W_PASEO/calls.log" ] || fail "attached child owner invoked Paseo archive"
  pass "primary-session: wedged and attached-child sessions remain suspended from takeover eligibility"
}

test_suspend_failure_and_live_tree_refuse() {
  new_world suspend-failure
  write_agent "$AGENT_A"
  : > "$W_PASEO/suspend-fail"
  start_owner "$AGENT_A"
  run_takeover "$AGENT_A"
  [ "$RUN_RC" -ne 0 ] || fail "failed Paseo suspend unexpectedly took over"
  assert_contains "$RUN_OUT" "soft archive failed" "suspend failure lacked a typed refusal"
  kill -0 "$OWNER_PID" 2>/dev/null || fail "suspend failure stopped the owner"
  [ "$(cat "$W_ROOT/state/.lock")" = "$OWNER_PID" ] || fail "suspend failure changed the lock"
  receipt=$(only_receipt) || fail "suspend failure did not retain its fail-closed receipt"
  [ "$(record_last_value "$receipt" state)" = archive-failed ] \
    || fail "suspend failure receipt did not record archive-failed"

  new_world tree-alive
  write_agent "$AGENT_A"
  : > "$W_PASEO/keep-owner-alive"
  start_owner "$AGENT_A"
  run_takeover "$AGENT_A"
  [ "$RUN_RC" -ne 0 ] || fail "live owner tree unexpectedly took over"
  assert_contains "$RUN_OUT" "process tree remained alive" "live-tree failure lacked a typed refusal"
  kill -0 "$OWNER_PID" 2>/dev/null || fail "live-tree fixture owner unexpectedly died"
  [ "$(cat "$W_ROOT/state/.lock")" = "$OWNER_PID" ] || fail "live-tree failure changed the lock"
  receipt=$(only_receipt) || fail "live-tree failure did not publish its recovery receipt"
  [ "$(record_last_value "$receipt" state)" = suspend-incomplete ] \
    || fail "live-tree receipt did not record suspend-incomplete"
  [ "$(record_last_value "$receipt" remaining_pids)" = "$OWNER_PID" ] \
    || fail "live-tree receipt did not record the surviving pid set"
  run_lock_acquire
  [ "$RUN_RC" -ne 0 ] || fail "ordinary stale-lock acquisition bypassed suspend-incomplete receipt"
  assert_contains "$RUN_OUT" "unresolved suspend-incomplete primary-session receipt still has live captured pids" \
    "ordinary lock refusal did not cite the unresolved incomplete handoff"
  [ "$(cat "$W_ROOT/state/.lock")" = "$OWNER_PID" ] || fail "blocked stale acquisition changed the old lock"
  receipt_id=$(record_last_value "$receipt" receipt_id)
  run_restore "$receipt_id"
  [ "$RUN_RC" -ne 0 ] || fail "restore bypassed unresolved suspend-incomplete receipt"
  assert_contains "$RUN_OUT" "unresolved suspend-incomplete primary-session receipt still has live captured pids" \
    "restore refusal did not cite the unresolved incomplete handoff"
  [ "$(grep -c '^reload ' "$W_PASEO/calls.log" || true)" -eq 0 ] || fail "refused suspend-incomplete restore invoked reload"
  kill "$OWNER_PID" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$OWNER_PID" 2>/dev/null || break
    sleep 0.05
  done
  run_lock_acquire
  [ "$RUN_RC" -eq 0 ] || fail "ordinary stale-lock acquisition did not proceed after captured tree exited: $RUN_OUT"
  [ "$(record_last_value "$receipt" state)" = suspend-resolved ] \
    || fail "ordinary stale-lock acquisition did not resolve the incomplete receipt"
  pass "primary-session: suspend failure and surviving owner process tree block stale-lock acquisition until resolved"
}

test_post_archive_receipt_write_failure_remains_restorable() {
  new_world post-archive-receipt-failure
  write_agent "$AGENT_A"
  : > "$W_PASEO/chmod-receipt-after-archive"
  start_owner "$AGENT_A"
  run_takeover "$AGENT_A"
  [ "$RUN_RC" -ne 0 ] || fail "post-archive receipt write failure unexpectedly completed takeover"
  assert_contains "$RUN_OUT" "provider was suspended but the durable handoff receipt could not be published" \
    "post-archive receipt write failure lacked a typed refusal"
  receipt=$(only_receipt) || fail "post-archive receipt failure did not leave a restore-eligible receipt"
  [ "$(record_last_value "$receipt" state)" = archive-requested ] \
    || fail "post-archive receipt failure lost the pre-archive receipt state"
  [ -e "$W_PASEO/archived-$AGENT_A" ] || fail "post-archive receipt failure did not archive the provider"
  chmod 600 "$receipt"
  receipt_id=$(record_last_value "$receipt" receipt_id)
  : > "$W_PASEO/reload-spawn"
  run_restore "$receipt_id"
  [ "$RUN_RC" -eq 0 ] || fail "restore could not use the pre-archive receipt after publication recovered: $RUN_OUT"
  assert_contains "$RUN_OUT" "restore requested" \
    "restore did not proceed from the pre-archive receipt"
  pass "primary-session: post-archive receipt write failure preserves an explicit restore path"
}

test_lock_publish_failure_rolls_back_own_claim() {
  new_world publish-failure
  mkdir "$W_ROOT/state/.lock.owner"
  run_lock_acquire
  [ "$RUN_RC" -ne 0 ] || fail "lock acquisition unexpectedly succeeded despite descriptor publication failure"
  assert_contains "$RUN_OUT" "rolled back this session lock claim" \
    "lock publication failure did not report a safe rollback"
  [ ! -e "$W_ROOT/state/.lock" ] || fail "failed descriptor publication left this session's numeric lock behind"
  pass "fm-lock: descriptor publication failure rolls back only its own numeric claim"
}

test_successful_takeover_preserves_fleet_and_records_receipt() {
  new_world successful
  write_agent "$AGENT_A"
  printf 'window=firstmate:fm-task\nworktree=/fixture/task\n' > "$W_ROOT/state/task.meta"
  printf '1\t1\tsignal\ttask\tfixture wake\n' > "$W_ROOT/state/.wake-queue"
  printf 'secondmate fixture\n' > "$W_ROOT/data/secondmates.md"
  start_owner "$AGENT_A"
  run_takeover "$AGENT_A"
  [ "$RUN_RC" -eq 0 ] || fail "safe idle takeover failed: $RUN_OUT"
  assert_contains "$RUN_OUT" "takeover complete" "successful takeover lacked completion output"
  new_owner=$(cat "$W_ROOT/state/.lock")
  [ "$new_owner" != "$OWNER_PID" ] || fail "successful takeover kept the old lock pid"
  [ -s "$W_ROOT/state/session-start.log" ] || fail "successful takeover did not run ordinary session start"
  receipt=$(only_receipt) || fail "successful takeover did not publish exactly one receipt"
  [ "$(record_last_value "$receipt" state)" = active-successor ] \
    || fail "successful receipt did not record active-successor"
  [ "$(record_last_value "$receipt" provider_session_id)" = "provider-$AGENT_A" ] \
    || fail "receipt lost the provider-native session id"
  assert_grep "window=firstmate:fm-task" "$W_ROOT/state/task.meta" "task metadata changed during takeover"
  assert_grep "fixture wake" "$W_ROOT/state/.wake-queue" "wake queue changed during takeover"
  assert_grep "secondmate fixture" "$W_ROOT/data/secondmates.md" "secondmate registry changed during takeover"
  pass "primary-session: safe idle takeover uses stale-lock acquisition and preserves fleet state"
}

test_rate_limited_takeover_is_distinct_and_recoverable() {
  new_world rate-limited
  write_agent "$AGENT_A"
  : > "$W_PASEO/quota-blocked"
  start_owner "$AGENT_A"
  run_takeover "$AGENT_A"
  [ "$RUN_RC" -eq 0 ] || fail "rate-limited idle takeover failed: $RUN_OUT"
  receipt=$(only_receipt) || fail "rate-limited takeover lacked a receipt"
  [ "$(record_last_value "$receipt" classification)" = paused-rate-limited ] \
    || fail "rate-limited target was not distinguished from ordinary idle"
  pass "primary-session: fresh exhausted quota evidence produces a distinct recoverable pause"
}

test_concurrent_takeovers_admit_one_successor() {
  local rc1 rc2 successes archive_count
  new_world concurrent
  write_agent "$AGENT_A"
  start_owner "$AGENT_A"
  # shellcheck disable=SC2016
  env -u PASEO_AGENT_ID \
    FM_HOME="$W_ROOT" FM_ROOT_OVERRIDE="$W_ROOT" PASEO_HOME="$W_PASEO" \
    FM_PRIMARY_OWNER_EXIT_TIMEOUT=3 PATH="$W_FAKEBIN:$PATH" \
    "$W_FAKE_CLAUDE" -c '"$1/bin/fm-primary-session.sh" takeover "$2"; rc=$?; :; exit "$rc"' \
    _ "$W_ROOT" "$AGENT_A" > "$W_DIR/out1" 2>&1 &
  p1=$!
  # shellcheck disable=SC2016
  env -u PASEO_AGENT_ID \
    FM_HOME="$W_ROOT" FM_ROOT_OVERRIDE="$W_ROOT" PASEO_HOME="$W_PASEO" \
    FM_PRIMARY_OWNER_EXIT_TIMEOUT=3 PATH="$W_FAKEBIN:$PATH" \
    "$W_FAKE_CLAUDE" -c '"$1/bin/fm-primary-session.sh" takeover "$2"; rc=$?; :; exit "$rc"' \
    _ "$W_ROOT" "$AGENT_A" > "$W_DIR/out2" 2>&1 &
  p2=$!
  rc1=0
  wait "$p1" || rc1=$?
  rc2=0
  wait "$p2" || rc2=$?
  successes=0
  [ "$rc1" -eq 0 ] && successes=$(( successes + 1 ))
  [ "$rc2" -eq 0 ] && successes=$(( successes + 1 ))
  [ "$successes" -eq 1 ] || fail "concurrent takeover expected one success, got rc1=$rc1 rc2=$rc2"
  archive_count=$(grep -c '^archive ' "$W_PASEO/calls.log")
  [ "$archive_count" -eq 1 ] || fail "concurrent takeover archived $archive_count times"
  pass "primary-session: concurrent takeover attempts admit one suspension and one successor"
}

test_restore_refuses_live_successor() {
  new_world restore-refusal
  write_agent "$AGENT_A"
  start_owner "$AGENT_A"
  run_takeover "$AGENT_A"
  expect_code 0 "$RUN_RC" "takeover before restore-refusal test"
  receipt=$(only_receipt) || fail "restore-refusal setup lacked a receipt"
  receipt_id=$(record_last_value "$receipt" receipt_id)
  "$W_FAKE_CLAUDE" -c '
    trap "exit 0" TERM INT
    while :; do read -r -t 1 _ || true; done
  ' </dev/null >/dev/null 2>&1 &
  live_successor=$!
  LIVE_PIDS+=("$live_successor")
  printf '%s\n' "$live_successor" > "$W_ROOT/state/.lock"
  run_restore "$receipt_id"
  [ "$RUN_RC" -ne 0 ] || fail "restore under a live successor unexpectedly succeeded"
  assert_contains "$RUN_OUT" "restore refused: live pid" "live-successor restore refusal was not explicit"
  [ -e "$W_PASEO/archived-$AGENT_A" ] || fail "refused restore unarchived the provider"
  [ "$(grep -c '^reload ' "$W_PASEO/calls.log" || true)" -eq 0 ] || fail "refused restore invoked reload"
  pass "primary-session: restore fails closed while another live primary owns the lock"
}

test_recoverable_happy_path_reacquires_normally() {
  new_world restore-happy
  write_agent "$AGENT_A"
  start_owner "$AGENT_A"
  run_takeover "$AGENT_A"
  expect_code 0 "$RUN_RC" "takeover before restore happy path"
  receipt=$(only_receipt) || fail "restore happy-path setup lacked a receipt"
  receipt_id=$(record_last_value "$receipt" receipt_id)
  : > "$W_PASEO/reload-spawn"
  run_restore "$receipt_id"
  [ "$RUN_RC" -eq 0 ] || fail "explicit restore failed: $RUN_OUT"
  deadline=$(( $(date +%s) + 5 ))
  while [ "$(record_last_value "$receipt" state)" != restored ]; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "restored provider did not reacquire through normal session start"
    sleep 0.1
  done
  restored_pid=$(cat "$W_PASEO/restored-pid")
  LIVE_PIDS+=("$restored_pid")
  [ "$(cat "$W_ROOT/state/.lock")" = "$restored_pid" ] \
    || fail "restored provider did not become the canonical lock owner"
  [ "$(record_last_value "$W_ROOT/state/.lock.owner" external_session_id)" = "$AGENT_A" ] \
    || fail "restored lock descriptor lost the Paseo agent id"
  assert_contains "$RUN_OUT" "must complete the native session-start nudge" \
    "restore output did not state the reacquisition requirement"
  pass "primary-session: archived provider reload remains recoverable and reacquires through normal session start"
}

test_scan_is_read_only_and_privacy_safe() {
  new_world scan
  write_agent "$AGENT_A" idle 1
  write_agent "$AGENT_B" idle 0 true finished
  write_agent "$AGENT_C" idle 0 true "private fixture prose"
  before=$(git -C "$W_ROOT" status --porcelain)
  out=$(FM_HOME="$W_ROOT" FM_ROOT_OVERRIDE="$W_ROOT" PASEO_HOME="$W_PASEO" \
    PATH="$W_FAKEBIN:$PATH" "$W_ROOT/bin/fm-primary-session.sh" scan --json)
  after=$(git -C "$W_ROOT" status --porcelain)
  [ "$before" = "$after" ] || fail "read-only scan changed the fixture checkout"
  [ "$(jq 'length' <<< "$out")" -eq 3 ] || fail "scan did not return all captain-action sessions"
  jq -e --arg a "$AGENT_A" --arg b "$AGENT_B" --arg c "$AGENT_C" '
    any(.[]; .external_session_id == $a and .action == "permission")
    and any(.[]; .external_session_id == $b and .action == "finished")
    and any(.[]; .external_session_id == $c and .action == "attention")
    and all(.[]; has("name") | not)
  ' <<< "$out" >/dev/null || fail "scan output lost action identity or exposed titles"
  assert_not_contains "$out" "private fixture prose" "scan exposed raw attention prose"
  [ ! -e "$W_PASEO/calls.log" ] || fail "scan invoked a Paseo lifecycle command"
  pass "primary-session: fleet-wide captain-action scan is read-only and omits prompt/title prose"
}

test_nested_paseo_state_resolves_uniquely() {
  local receipt
  new_world nested-paseo-state
  write_agent "$AGENT_A"
  mkdir -p "$W_PASEO/agents/workspace-fixture"
  mv "$W_PASEO/agents/$AGENT_A.json" "$W_PASEO/agents/workspace-fixture/$AGENT_A.json"
  start_owner "$AGENT_A"
  run_takeover "$AGENT_A"
  [ "$RUN_RC" -eq 0 ] || fail "workspace-scoped Paseo takeover failed: $RUN_OUT"
  receipt=$(only_receipt) || fail "workspace-scoped Paseo takeover lacked a receipt"
  [ "$(record_last_value "$receipt" provider_session_id)" = "provider-$AGENT_A" ] \
    || fail "workspace-scoped Paseo state resolved the wrong provider session"
  pass "primary-session: workspace-scoped Paseo state resolves by unique external session id"
}

test_owner_mismatch_refuses_without_archive
test_busy_pending_and_unknown_refuse
test_wedged_and_attached_child_refuse
test_suspend_failure_and_live_tree_refuse
test_post_archive_receipt_write_failure_remains_restorable
test_lock_publish_failure_rolls_back_own_claim
test_successful_takeover_preserves_fleet_and_records_receipt
test_rate_limited_takeover_is_distinct_and_recoverable
test_concurrent_takeovers_admit_one_successor
test_restore_refuses_live_successor
test_recoverable_happy_path_reacquires_normally
test_scan_is_read_only_and_privacy_safe
test_nested_paseo_state_resolves_uniquely
