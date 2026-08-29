#!/usr/bin/env bash
# Behavior tests for the committed-ready validation continuation owner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"

CONTINUE="$ROOT/bin/fm-delivery-continue.sh"
TMP_ROOT=$(fm_test_tmproot fm-delivery-continue)

make_fixture() {
  local dir=$1 home wt
  home="$dir/home"
  wt="$home/projects/ship"
  mkdir -p "$home/state" "$home/data/ship" "$home/projects"
  fm_git_init_commit "$wt"
  git -C "$wt" checkout -qb fm/ship
  fm_write_meta "$home/state/ship.meta" "window=fm:fm-ship" "worktree=$wt" "project=sample" "harness=codex" "kind=ship" "mode=no-mistakes" "spawn_gen=g1"
  printf 'done: implementation committed and focused checks passed\n' > "$home/state/ship.status"
  cat > "$home/data/ship/brief.md" <<'EOF'
Delivery contract: mode=no-mistakes
When you believe it is complete, append `done: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.
EOF
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship - Ship task (repo: sample) (kind: ship)

## Queued

## Done
EOF
  printf '%s\n' "$home"
}

make_send_stub() {
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -eu
task=$1; shift
message=$*
[ "${FM_SEND_EXPECTED_SPAWN_GEN:-}" = g1 ] || exit 11
. "${FM_TEST_ROOT:?}/bin/fm-task-inbox-lib.sh"
fm_task_inbox_write_idempotent "${FM_STATE_OVERRIDE:?}" "$task" "$message" >/dev/null
SH
  chmod +x "$path"
}

make_state_stub() {
  local path=$1 state=$2
  printf '#!/usr/bin/env bash\nprintf '\''run-attribution: %%s\\n'\'' %q\n' "$state" > "$path"
  chmod +x "$path"
}

run_continue() {
  local home=$1 send=$2 state=$3
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_TEST_ROOT="$ROOT" \
    FM_DELIVERY_SEND_BIN="$send" FM_DELIVERY_CREW_STATE_BIN="$state" "$CONTINUE" ship
}

test_exactly_once_delivery_and_replay() {
  local dir home send state first second third count due record
  dir="$TMP_ROOT/exactly-once"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  first=$(run_continue "$home" "$send" "$state") || fail "initial continuation failed"
  make_state_stub "$state" unavailable
  second=$(run_continue "$home" "$send" "$state") || fail "replay continuation failed"
  due=$(FM_TASK_INBOX_GRACE_SECS=0 fm_task_inbox_due_action "$home/state" ship)
  record=$(find "$home/state/ship.inbox" -maxdepth 1 -name '*.msg' -print -quit)
  mkdir -p "$home/state/ship.inbox/handled"
  mv "$record" "$home/state/ship.inbox/handled/"
  third=$(run_continue "$home" "$send" "$state") || fail "handled replay continuation failed"
  count=$(find "$home/state/ship.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$first" = 'result=sent task=ship' ] || fail "initial result wrong: $first"
  [ "$second" = 'result=already-delivered task=ship' ] || fail "replay result wrong: $second"
  [ "$third" = 'result=already-delivered task=ship' ] || fail "handled replay result wrong: $third"
  [ "$count" = 1 ] || fail "replay created $count delivery records"
  [[ "$due" == ring* ]] || fail "continuation record was excluded from acknowledgement retries: $due"
  [ ! -e "$home/state/.lease-ship" ] || fail "continuation stranded its lease"
  pass "committed-ready delivery is durable exactly once and replay-safe"
}

test_refusals_preserve_stop() {
  local dir home send state out
  dir="$TMP_ROOT/refusals"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  { printf 'blocked: waiting while docs mention [key=route] in prose\n'; cat "$home/state/ship.status"; } > "$home/state/ship.status.next"
  mv "$home/state/ship.status.next" "$home/state/ship.status"
  out=$(run_continue "$home" "$send" "$state") || fail "blocked result execution failed"
  [[ "$out" == *'reason=open-decision-or-blocker'* ]] || fail "open blocker was not refused: $out"
  [ ! -d "$home/state/ship.inbox" ] || fail "blocked task received validation delivery"
  pass "an open canonical blocker remains stopped"
}

test_active_run_and_unavailable_attribution_refuse() {
  local dir home send state out
  dir="$TMP_ROOT/active-and-mismatch"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" active
  out=$(run_continue "$home" "$send" "$state") || fail "active run execution failed"
  [[ "$out" == 'result=already-active task=ship' ]] || fail "active run was not recognized: $out"
  make_state_stub "$state" unavailable
  out=$(run_continue "$home" "$send" "$state") || fail "unavailable attribution execution failed"
  [ "$out" = 'result=retry task=ship reason=validation-attribution-unavailable' ] \
    || fail "unavailable run query did not remain retryable: $out"
  [ ! -d "$home/state/ship.inbox" ] || fail "unavailable run attribution received validation delivery"
  pass "active validation stops delivery and unavailable attribution remains retryable"
}

test_current_brief_requires_canonical_receipt() {
  local dir home send state out head
  dir="$TMP_ROOT/current-receipt"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  cat > "$home/data/ship/brief.md" <<'EOF'
Delivery contract: mode=no-mistakes
Delivery receipt contract: committed-head-v1
When you believe it is complete, append `done: committed $(git rev-parse HEAD) {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.
EOF
  printf 'done: validation complete\n' > "$home/state/ship.status"
  out=$(run_continue "$home" "$send" "$state") || fail "noncanonical current receipt execution failed"
  [ "$out" = 'result=refused task=ship reason=missing-committed-receipt' ] \
    || fail "current brief accepted a noncanonical receipt: $out"
  [ ! -d "$home/state/ship.inbox" ] || fail "current noncanonical receipt created an inbox delivery"
  head=$(git -C "$home/projects/ship" rev-parse HEAD)
  printf 'done: committed %s validation complete\n' "$head" > "$home/state/ship.status"
  out=$(run_continue "$home" "$send" "$state") || fail "canonical current receipt execution failed"
  [ "$out" = 'result=sent task=ship' ] || fail "current canonical receipt did not deliver: $out"
  pass "current briefs require canonical committed-head receipts"
}

test_inbox_failure_remains_retryable() {
  local dir home send state out
  dir="$TMP_ROOT/inbox-retry"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_state_stub "$state" absent
  printf '#!/usr/bin/env bash\nexit 1\n' > "$send"
  chmod +x "$send"
  out=$(run_continue "$home" "$send" "$state") || fail "inbox failure execution failed"
  [ "$out" = 'result=retry task=ship reason=inbox-delivery-failed' ] \
    || fail "inbox delivery failure did not remain retryable: $out"
  pass "inbox delivery failures remain retry obligations"
}

test_strict_run_attribution_distinguishes_absence_from_query_failure() {
  local dir home fakebin out
  dir="$TMP_ROOT/strict-attribution"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit "${FM_FAKE_NM_EXIT:-0}"
SH
  chmod +x "$fakebin/no-mistakes"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_FAKE_NM_EXIT=1 \
    "$ROOT/bin/fm-crew-state.sh" --run-attribution ship)
  [ "$out" = 'run-attribution: unavailable' ] || fail "failed run query was not unavailable: $out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_FAKE_NM_EXIT=0 \
    "$ROOT/bin/fm-crew-state.sh" --run-attribution ship)
  [ "$out" = 'run-attribution: absent' ] || fail "successful empty run inventory was not proven absent: $out"
  pass "strict run attribution separates proven absence from query unavailability"
}

test_identity_and_committed_head_requirements() {
  local dir home send state out head
  dir="$TMP_ROOT/identity-and-head"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  sed '/^spawn_gen=/d' "$home/state/ship.meta" > "$home/state/ship.meta.next"
  mv "$home/state/ship.meta.next" "$home/state/ship.meta"
  out=$(run_continue "$home" "$send" "$state") || fail "missing-incarnation execution failed"
  [[ "$out" == *'reason=missing-task-incarnation'* ]] || fail "missing incarnation was not refused: $out"
  printf 'spawn_gen=g1\n' >> "$home/state/ship.meta"
  printf 'dirty\n' > "$home/projects/ship/uncommitted.txt"
  out=$(run_continue "$home" "$send" "$state") || fail "dirty legacy receipt execution failed"
  [[ "$out" == *'reason=uncommitted-worktree'* ]] || fail "legacy receipt did not independently require a clean committed head: $out"
  rm "$home/projects/ship/uncommitted.txt"
  head=$(git -C "$home/projects/ship" rev-parse HEAD)
  printf 'done: committed %s canonical receipt\n' "$head" > "$home/state/ship.status"
  out=$(run_continue "$home" "$send" "$state") || fail "canonical receipt execution failed"
  [ "$out" = 'result=sent task=ship' ] || fail "canonical committed receipt did not deliver: $out"
  pass "continuation requires an incarnation and proves both legacy and canonical committed heads"
}

test_terminal_receipt_and_existing_lease_retry() {
  local dir home send state out
  dir="$TMP_ROOT/terminal-and-lease"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  printf 'done: PR https://example.invalid/pull/1 checks green\n' > "$home/state/ship.status"
  out=$(run_continue "$home" "$send" "$state") || fail "terminal receipt execution failed"
  [[ "$out" == *'reason=attributable-validation-terminal-receipt'* ]] || fail "terminal PR receipt was treated as committed-ready: $out"
  printf 'done: implementation committed and focused checks passed\n' > "$home/state/ship.status"
  printf '%s\n' "$$" > "$home/state/.lock"
  PI_CODING_AGENT=true FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_LEASE_HOLDER_PID=$$ \
    "$ROOT/bin/fm-lease.sh" claim ship >/dev/null || fail "fixture main lease claim failed"
  out=$(PI_CODING_AGENT=true run_continue "$home" "$send" "$state") || fail "borrowed lease execution failed"
  [[ "$out" == 'result=retry task=ship reason=supervision-owner-active' ]] || fail "borrowed same-actor lease was not retained as retry: $out"
  PI_CODING_AGENT=true FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-lease.sh" check ship >/dev/null \
    || fail "continuation released the pre-existing lease"
  PI_CODING_AGENT=true FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-lease.sh" release ship >/dev/null
  pass "terminal receipts stop and existing supervision custody remains a retry obligation"
}

test_killed_delivery_operation_does_not_strand_session_lease() {
  local dir home send state marker pid operation_pid helper_pid out
  dir="$TMP_ROOT/killed-delivery-operation"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; marker="$dir/operation.pid"
  make_send_stub "$send"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$state" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "${FM_OPERATION_MARKER:?}"
trap 'exit 0' TERM INT
while :; do sleep 0.02; done
SH
  chmod +x "$state"
  PI_CODING_AGENT=true FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_TEST_ROOT="$ROOT" FM_OPERATION_MARKER="$marker" FM_DELIVERY_SEND_BIN="$send" \
    FM_DELIVERY_CREW_STATE_BIN="$state" "$CONTINUE" ship > "$dir/first.out" 2> "$dir/first.err" &
  pid=$!
  for _ in $(seq 1 100); do
    [ -s "$marker" ] && [ -e "$home/state/.lease-ship" ] && break
    sleep 0.01
  done
  operation_pid=$(cut -f4 "$home/state/.lease-ship" 2>/dev/null)
  operation_pid=${operation_pid##*-}
  helper_pid=$(cat "$marker" 2>/dev/null)
  case "$operation_pid:$helper_pid" in *[!0-9:]*|:|*:) fail "delivery fixture did not expose both operation pids" ;; esac
  kill -9 "$operation_pid" 2>/dev/null || fail "could not kill the delivery operation"
  kill -9 "$helper_pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ -e "$home/state/.lease-ship" ] || fail "killed delivery operation did not leave the crash-window lease"
  make_state_stub "$state" absent
  out=$(PI_CODING_AGENT=true run_continue "$home" "$send" "$state") || fail "delivery replay after killed owner failed"
  [ "$out" = 'result=sent task=ship' ] || fail "dead delivery operation stranded the session lease: $out"
  [ ! -e "$home/state/.lease-ship" ] || fail "replay left the recovered delivery lease"
  pass "a killed delivery operation cannot strand its live Pi session lease"
}

test_pi_empty_drain_recovers_unqueued_durable_candidate() {
  local dir home stub log out
  dir="$TMP_ROOT/pi-empty-durable-preflight"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  stub="$dir/continue"; log="$dir/delivery.log"
  printf '%s\n' "$$" > "$home/state/.lock"
  : > "$home/state/.wake-queue"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_PREFLIGHT_LOG:?}"
printf 'result=sent task=%s\n' "$1"
SH
  chmod +x "$stub"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_PI_DELIVERY_PREFLIGHT=1 \
    FM_DELIVERY_PREFLIGHT_CONTINUE_BIN="$stub" FM_PREFLIGHT_LOG="$log" \
    "$ROOT/bin/fm-wake-drain.sh") || fail "empty Pi drain durable preflight failed"
  assert_contains "$out" "Deterministic delivery continuation preflight:" \
    "empty Pi drain omitted its durable continuation result"
  assert_contains "$out" "result=sent task=ship" \
    "empty Pi drain did not recover the unqueued committed-ready task"
  [ "$(cat "$log")" = ship ] || fail "empty Pi drain did not invoke exactly one durable candidate"
  [ ! -s "$home/state/.wake-queue" ] || fail "durable inventory manufactured a wake row"
  pass "Pi startup intake recovers committed-ready state without a wake row"
}

test_fleet_and_bearings_project_pending_continuation() {
  local dir home send state fakebin snapshot bearings head active_bearings monitoring_bearings terminal_bearings
  dir="$TMP_ROOT/fleet-projection"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  run_continue "$home" "$send" "$state" >/dev/null || fail "projection continuation failed"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'fm-ship\n' ;;
  display-message) printf 'codex\n' ;;
  capture-pane) printf 'working\nesc to interrupt\n' ;;
esac
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/tmux"
  snapshot=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$snapshot" | jq -e '.tasks[] | select(.id == "ship") | .delivery_continuation.state == "pending" and .delivery_continuation.worker_unverified_busy == true' >/dev/null \
    || fail "fleet snapshot hid pending continuation or unverified busy source: $snapshot"
  bearings=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-bearings-snapshot.sh" --json)
  printf '%s' "$bearings" | jq -e '.in_flight[] | select(.id == "ship") | .state == "validation_pending" and (.doing | contains("source unverified"))' >/dev/null \
    || fail "Bearings hid pending continuation or unverified busy source: $bearings"
  head=$(git -C "$home/projects/ship" rev-parse HEAD)
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'axi status')
    if [ "${FM_FAKE_RUN_MODE:-}" = active ]; then
      cat <<EOF
run:
  id: "01RUN"
  branch: fm/ship
  status: running
  head: "${FM_FAKE_RUN_HEAD:?}"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
    elif [ "${FM_FAKE_RUN_MODE:-}" = monitoring ]; then
      cat <<EOF
run:
  id: "01RUN"
  branch: fm/ship
  status: running
  head: "${FM_FAKE_RUN_HEAD:?}"
  pr: "https://example.invalid/pull/1"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
    else
      cat <<EOF
run:
  id: "01RUN"
  branch: fm/ship
  status: completed
  head: "${FM_FAKE_RUN_HEAD:?}"
  pr: "https://example.invalid/pull/1"
  findings: none
outcome: checks-passed
EOF
    fi
    ;;
  'axi logs') exit 0 ;;
  'runs --limit') exit 0 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  active_bearings=$(FM_FAKE_RUN_MODE=active FM_FAKE_RUN_HEAD="$head" PATH="$fakebin:$PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-bearings-snapshot.sh" --json)
  printf '%s' "$active_bearings" | jq -e '.in_flight[] | select(.id == "ship") | .state == "working" and (.doing | contains("validating (running)")) and (.doing | contains("validation instr"))' >/dev/null \
    || fail "Bearings let pending delivery hide an attributed active run: $active_bearings"
  printf 'done: PR https://example.invalid/pull/1 checks green\n' > "$home/state/ship.status"
  monitoring_bearings=$(FM_FAKE_RUN_MODE=monitoring FM_FAKE_RUN_HEAD="$head" PATH="$fakebin:$PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-bearings-snapshot.sh" --json)
  printf '%s' "$monitoring_bearings" | jq -e '.in_flight[] | select(.id == "ship") | .state == "done" and (.doing | contains("checks green")) and (.doing | contains("validation instr"))' >/dev/null \
    || fail "Bearings lost an attributed monitoring run reconciled through status: $monitoring_bearings"
  terminal_bearings=$(FM_FAKE_RUN_MODE=terminal FM_FAKE_RUN_HEAD="$head" PATH="$fakebin:$PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-bearings-snapshot.sh" --json)
  printf '%s' "$terminal_bearings" | jq -e '.in_flight[] | select(.id == "ship") | .state == "done" and (.doing | contains("checks green: PR ready for review")) and (.doing | contains("validation instr"))' >/dev/null \
    || fail "Bearings let pending delivery hide an attributed terminal run: $terminal_bearings"
  pass "fleet and Bearings preserve pending delivery behind authoritative run state"
}

test_advanced_head_surfaces_continuation_conflict() {
  local dir home send state out head snapshot bearings fakebin
  dir="$TMP_ROOT/head-conflict"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  run_continue "$home" "$send" "$state" >/dev/null || fail "initial head continuation failed"
  git -C "$home/projects/ship" commit -q --allow-empty -m advance
  head=$(git -C "$home/projects/ship" rev-parse HEAD)
  printf 'done: committed %s advanced head\n' "$head" > "$home/state/ship.status"
  out=$(run_continue "$home" "$send" "$state") || fail "advanced head execution failed"
  [[ "$out" == *'reason=continuation-head-mismatch'* ]] || fail "old delivery was accepted for the advanced head: $out"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'fm-ship\n' ;;
  display-message) printf 'codex\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/tmux"
  snapshot=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$snapshot" | jq -e '.tasks[] | select(.id == "ship") | .delivery_continuation.state == "head-mismatch" and .delivery_continuation.head != .delivery_continuation.current_head' >/dev/null \
    || fail "fleet snapshot hid the exact-head continuation conflict: $snapshot"
  bearings=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-bearings-snapshot.sh" --json)
  printf '%s' "$bearings" | jq -e '.in_flight[] | select(.id == "ship") | .state == "validation_conflict"' >/dev/null \
    || fail "Bearings hid the exact-head continuation conflict: $bearings"
  pass "advanced committed heads refuse stale delivery and surface the conflict"
}

test_pi_drain_preflights_before_presenting_committed_ready_rows() {
  local dir home state stub log out err status first_label first_row
  dir="$TMP_ROOT/pi-drain-preflight"
  home="$dir/home"
  state="$home/state"
  stub="$dir/continue"
  log="$dir/delivery.log"
  mkdir -p "$state"
  printf '%s\n' "$$" > "$state/.lock"
  fm_write_meta "$state/ship.meta" "window=default:w1:p1" "project=sample"
  printf 'done: committed fixture\n' > "$state/ship.status"
  printf '1\t1\tsignal\tship.status\tsignal: ship.status\n' > "$state/.wake-queue"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
if [ "${FM_PREFLIGHT_RETRY:-0}" = 1 ]; then
  printf 'result=retry task=%s reason=validation-attribution-unavailable\n' "$1"
  exit 0
fi
if [ -e "${FM_PREFLIGHT_MARK:?}" ]; then
  printf 'result=already-delivered task=%s\n' "$1"
else
  printf '%s\n' "$1" > "$FM_PREFLIGHT_MARK"
  printf 'sent\n' >> "${FM_PREFLIGHT_LOG:?}"
  printf 'result=sent task=%s\n' "$1"
fi
SH
  chmod +x "$stub"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PI_DELIVERY_PREFLIGHT=1 \
    FM_DELIVERY_PREFLIGHT_CONTINUE_BIN="$stub" FM_PREFLIGHT_MARK="$dir/delivered" FM_PREFLIGHT_LOG="$log" \
    "$ROOT/bin/fm-wake-drain.sh" 2> "$dir/first.err") || fail "Pi preflight drain failed: $(cat "$dir/first.err")"
  first_label=$(printf '%s\n' "$out" | grep -n '^Deterministic delivery continuation preflight:$' | cut -d: -f1)
  first_row=$(printf '%s\n' "$out" | grep -n "$(printf '\tsignal\tship.status\t')" | cut -d: -f1)
  [ -n "$first_label" ] && [ -n "$first_row" ] && [ "$first_label" -lt "$first_row" ] \
    || fail "Pi drain presented committed-ready work before deterministic continuation: $out"
  [ "$(cat "$log")" = sent ] || fail "Pi drain did not create exactly one continuation"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PI_DELIVERY_PREFLIGHT=1 \
    FM_DELIVERY_PREFLIGHT_CONTINUE_BIN="$stub" FM_PREFLIGHT_MARK="$dir/delivered" FM_PREFLIGHT_LOG="$log" \
    "$ROOT/bin/fm-wake-drain.sh" 2> "$dir/replay.err") || fail "Pi replay drain failed: $(cat "$dir/replay.err")"
  printf '%s\n' "$out" | grep -q '^result=already-delivered task=ship$' \
    || fail "Pi replay did not converge on the durable continuation: $out"
  [ "$(wc -l < "$log" | tr -d ' ')" -eq 1 ] || fail "Pi replay created a second continuation"

  rm -f "$dir/delivered"
  : > "$log"
  status=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PI_DELIVERY_PREFLIGHT=1 FM_PREFLIGHT_RETRY=1 \
    FM_DELIVERY_PREFLIGHT_CONTINUE_BIN="$stub" FM_PREFLIGHT_MARK="$dir/delivered" FM_PREFLIGHT_LOG="$log" \
    "$ROOT/bin/fm-wake-drain.sh" > "$dir/retry.out" 2> "$dir/retry.err" || status=$?
  [ "$status" -ne 0 ] || fail "transient Pi preflight still presented the wake"
  err=$(cat "$dir/retry.err")
  printf '%s\n' "$err" | grep -q '^result=retry task=ship reason=validation-attribution-unavailable$' \
    || fail "transient Pi preflight did not preserve its retry obligation: $err"
  ! grep -q "$(printf '\tsignal\tship.status\t')" "$dir/retry.out" \
    || fail "transient Pi preflight exposed committed-ready work before settling"
  grep -q "$(printf '\tsignal\tship.status\t')" "$state/.wake-queue" \
    || fail "transient Pi preflight consumed its durable wake"
  pass "Pi queue intake preflights committed-ready rows before presentation"
}

test_exactly_once_delivery_and_replay
test_refusals_preserve_stop
test_active_run_and_unavailable_attribution_refuse
test_current_brief_requires_canonical_receipt
test_inbox_failure_remains_retryable
test_strict_run_attribution_distinguishes_absence_from_query_failure
test_identity_and_committed_head_requirements
test_terminal_receipt_and_existing_lease_retry
test_killed_delivery_operation_does_not_strand_session_lease
test_pi_empty_drain_recovers_unqueued_durable_candidate
test_fleet_and_bearings_project_pending_continuation
test_advanced_head_surfaces_continuation_conflict
test_pi_drain_preflights_before_presenting_committed_ready_rows
echo "all fm-delivery-continue tests passed"
