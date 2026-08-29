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
  local dir home send state first second count due
  dir="$TMP_ROOT/exactly-once"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  first=$(run_continue "$home" "$send" "$state") || fail "initial continuation failed"
  second=$(run_continue "$home" "$send" "$state") || fail "replay continuation failed"
  count=$(find "$home/state/ship.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$first" = 'result=sent task=ship' ] || fail "initial result wrong: $first"
  [ "$second" = 'result=already-delivered task=ship' ] || fail "replay result wrong: $second"
  [ "$count" = 1 ] || fail "replay created $count delivery records"
  due=$(FM_TASK_INBOX_GRACE_SECS=0 fm_task_inbox_due_action "$home/state" ship)
  [[ "$due" == ring* ]] || fail "continuation record was excluded from acknowledgement retries: $due"
  [ ! -e "$home/state/.lease-ship" ] || fail "continuation stranded its lease"
  pass "committed-ready delivery is durable exactly once and replay-safe"
}

test_refusals_preserve_stop() {
  local dir home send state out
  dir="$TMP_ROOT/refusals"; mkdir -p "$dir"
  home=$(make_fixture "$dir")
  send="$dir/send"; state="$dir/state"; make_send_stub "$send"; make_state_stub "$state" absent
  { printf 'blocked [key=real]: waiting for authority\n'; cat "$home/state/ship.status"; } > "$home/state/ship.status.next"
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

test_exactly_once_delivery_and_replay
test_refusals_preserve_stop
test_active_run_and_unavailable_attribution_refuse
test_current_brief_requires_canonical_receipt
test_inbox_failure_remains_retryable
test_strict_run_attribution_distinguishes_absence_from_query_failure
test_identity_and_committed_head_requirements
test_terminal_receipt_and_existing_lease_retry
test_fleet_and_bearings_project_pending_continuation
test_advanced_head_surfaces_continuation_conflict
echo "all fm-delivery-continue tests passed"
