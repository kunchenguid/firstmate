#!/usr/bin/env bash
# End-to-end behavior tests for the loopback fleet-board server and action path.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-fleet-board)
FAKE_ROOT="$TMP_ROOT/root"
HOME_ROOT="$TMP_ROOT/home"
SERVER="$ROOT/bin/fleet-board/server.py"
mkdir -p "$FAKE_ROOT/bin" "$HOME_ROOT/state" "$HOME_ROOT/data"

cat > "$FAKE_ROOT/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "${FM_HOME:?}/snapshot.fail" ]; then
  printf 'fixture snapshot failure\n' >&2
  exit 1
fi
cat <<'JSON'
{
  "schema":"fm-fleet-snapshot.v1",
  "generated":"2026-08-24T11:00:00Z",
  "fm_home":"/fixture/firstmate",
  "backlog":{"present":true,"records":[
    {"order":1,"structured":true,"id":"ready-task","title":"Chart the backlog","state":"queued","repo":"firstmate","kind":"ship","risk":{"level":"low","rationale":"Narrow and reversible.","source":"task-body"},"body_excerpt":"Ready context.","captain_actionable":false,"unresolved_blocker_ids":[],"links":[]},
    {"order":2,"structured":true,"id":"working-task","title":"Build the hull","state":"in_flight","repo":"firstmate","kind":"ship","risk":{"level":"medium","rationale":"Contained runtime change.","source":"task-body"},"body_excerpt":"Implementation context.","captain_actionable":false,"unresolved_blocker_ids":[],"links":[]},
    {"order":3,"structured":true,"id":"verify-task","title":"Verify the rigging","state":"in_flight","repo":"firstmate","kind":"ship","risk":{"level":"high","rationale":"Production behavior changes.","source":"task-body"},"body_excerpt":"Verification context.","captain_actionable":false,"unresolved_blocker_ids":[],"pr_url":"https://github.com/example/repo/pull/7","links":["https://github.com/example/repo/pull/7"]},
    {"order":4,"structured":true,"id":"captain-task","title":"Choose the safe route","state":"queued","repo":"firstmate","kind":"ship","risk":{"level":"high","rationale":"Irreversible data choice.","source":"task-body"},"body_excerpt":"Two valid choices remain.","hold_reason":"Choose the migration strategy","hold_kind":"captain","captain_actionable":true,"unresolved_blocker_ids":[],"links":[]},
    {"order":5,"structured":true,"id":"waiting-task","title":"Wait for the tide","state":"queued","repo":"firstmate","kind":"ship","risk":{"level":"unknown","rationale":null,"source":"absent"},"blocked_reason":"Awaiting vendor approval","captain_actionable":false,"unresolved_blocker_ids":["vendor-approval"],"links":[]},
    {"order":6,"structured":true,"id":"deferred-task","title":"Revisit the harbor plan","state":"queued","repo":"firstmate","kind":"ship","risk":{"level":"low","rationale":"No active impact.","source":"task-body"},"body_excerpt":"Deferred until the next planning cycle.","deferred_marker":true,"captain_actionable":false,"unresolved_blocker_ids":[],"links":[]},
    {"order":7,"structured":true,"id":"done-task","title":"Land the chart","state":"done","repo":"firstmate","kind":"ship","risk":{"level":"low","rationale":"Documentation only.","source":"task-body"},"captain_actionable":false,"unresolved_blocker_ids":[],"report_path":"data/done-task/report.md","links":[]}
  ]},
  "tasks":[
    {"id":"working-task","project":"firstmate","kind":"ship","current_state":{"state":"working","source":"pane","detail":"Implementing the board"},"hints":{"pending_decision":false,"blocked_event":false,"open_decisions":[]},"pr":{"url":null},"paths":{"report":{"present":false}}},
    {"id":"verify-task","project":"firstmate","kind":"ship","current_state":{"state":"working","source":"run-step","detail":"Running behavior tests"},"hints":{"pending_decision":false,"blocked_event":false,"open_decisions":[]},"pr":{"url":"https://github.com/example/repo/pull/7"},"paths":{"report":{"present":false}}},
    {"id":"captain-task","project":"firstmate","kind":"ship","current_state":{"state":"parked","source":"status-log","detail":"Choose the migration strategy"},"hints":{"pending_decision":true,"blocked_event":false,"open_decisions":[{"key":"migration","verb":"needs-decision","summary":"Choose the migration strategy"}]},"pr":{"url":null},"paths":{"report":{"present":false}}}
  ],
  "main_inventory":{"valid":true,"reason":null},
  "secondmate_current":{"records":[{
    "id":"design-mate","remote":false,"current":{"state":"captain_decision","reason":null},
    "queued":[{"id":"mate-ready","title":"Polish mobile cards","repo":"firstmate","kind":"ship","risk":{"level":"medium","rationale":"Visible UI change.","source":"task-body"},"context":"Mobile context.","captain_actionable":false,"unresolved_blocker_ids":[]},{"id":"mate-held","title":"Hold for vendor keys","repo":"firstmate","kind":"ship","risk":{"level":"low","rationale":"Reversible integration.","source":"task-body"},"context":"Held context.","hold_reason":"Waiting on vendor API keys","captain_actionable":false,"unresolved_blocker_ids":[]}],
    "active_children":[{"id":"mate-working","title":"Tune board spacing","repo":"firstmate","kind":"ship","state":"working","source":"pane","doing":"Checking spacing","risk":{"level":"low","rationale":"Reversible CSS.","source":"task-body"},"context":"Spacing context."}],
    "decisions_open":[{"id":"mate-choice","key":"mate-choice","verb":"needs-decision","summary":"Approve the contrast direction","reason":"Choose navy or rust","risk":{"level":"medium","rationale":"Visible UI choice.","source":"task-body"}}],
    "holds":[],"landed":[],"omitted":[]
  }],"truncated":0},
  "secondmate_landed":{"records":[]}
}
JSON
SH

cat > "$FAKE_ROOT/bin/fm-inbox.sh" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1:-}" = note ] && [ "${2:-}" = - ] || exit 2
{
  printf '%s\n' '--- action ---'
  cat
} >> "${FM_HOME:?}/inbox.log"
printf 'noted: fixture\n'
SH
chmod +x "$FAKE_ROOT/bin/fm-fleet-snapshot.sh" "$FAKE_ROOT/bin/fm-inbox.sh"

SERVER_PID=''
cleanup_server() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup_server EXIT

FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_ROOT" FM_STATE_OVERRIDE="$HOME_ROOT/state" \
  FM_FLEET_BOARD_CACHE_SECONDS=1 python3 "$SERVER" --serve --port 0 \
  >"$HOME_ROOT/server.out" 2>"$HOME_ROOT/server.err" &
SERVER_PID=$!

runtime="$HOME_ROOT/state/fleet-board/runtime.json"
for _ in $(seq 1 100); do
  [ -s "$runtime" ] && break
  sleep 0.05
done
[ -s "$runtime" ] || fail "fleet board did not publish its runtime record"
url=$(jq -r '.url' "$runtime")

health=$(curl -fsS "${url}healthz") || fail "health endpoint was unavailable"
printf '%s' "$health" | jq -e --argjson pid "$SERVER_PID" '.ok == true and .pid == $pid' >/dev/null \
  || fail "health endpoint did not prove the foreground server"
headers=$(curl -fsSI "$url") || fail "application shell was unavailable"
assert_contains "$headers" "Content-Security-Policy:" "application omitted its content security policy"
assert_contains "$headers" "X-Frame-Options: DENY" "application omitted frame protection"
code=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Host: rebound.example' "${url}api/v1/board")
[ "$code" = 403 ] || fail "board with a foreign Host header returned $code"
code=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Host: rebound.example' "$url")
[ "$code" = 403 ] || fail "application shell with a foreign Host header returned $code"
pass "server is loopback-ready and serves a protected application shell"

board=$(curl -fsS "${url}api/v1/board") || fail "board endpoint failed"
printf '%s' "$board" | jq -e '
  .schema == "fm-fleet-board.v1"
  and .counts == {backlog:2,in_progress:2,verification:1,needs_you:2,waiting:3,done:1}
  and .summary == {open:10,needs_you:2,high_risk_open:2}
  and ([.cards[] | select(.id == "captain-task")][0]
       | .lane == "needs_you" and .actions.answer == true and .risk.level == "high")
  and ([.cards[] | select(.id == "verify-task")][0]
       | .lane == "verification" and (.evidence | map(.kind) | index("pull_request") != null))
  and ([.cards[] | select(.id == "mate-working")][0]
       | .lane == "in_progress" and .home.id == "design-mate")
  and ([.cards[] | select(.id == "deferred-task")][0]
       | .lane == "waiting" and .status.wait_reason == "Marked deferred in task context")
  and ([.cards[] | select(.id == "mate-held")][0]
       | .lane == "waiting" and .status.wait_reason == "Waiting on vendor API keys")
' >/dev/null || fail "Kanban projection did not preserve lifecycle, risk, evidence, or secondmate work"
pass "canonical fleet state maps into the six truthful Kanban lanes"

csrf=$(printf '%s' "$board" | jq -r '.actions.csrf_token')
payload='{"action":"answer","task_id":"captain-task","home_id":"primary","text":"Use the reversible route and preserve rollback evidence.","request_id":"request-1"}'
code=$(curl -sS -o "$HOME_ROOT/no-csrf.json" -w '%{http_code}' \
  -H 'Content-Type: application/json' -d "$payload" "${url}api/v1/actions")
[ "$code" = 403 ] || fail "action without CSRF token returned $code"
code=$(curl -sS -o "$HOME_ROOT/bad-origin.json" -w '%{http_code}' \
  -H "X-Firstmate-CSRF: $csrf" -H 'Origin: https://example.com' \
  -H 'Content-Type: application/json' -d "$payload" "${url}api/v1/actions")
[ "$code" = 403 ] || fail "cross-origin action returned $code"
invalid_payload='{"action":"answer","task_id":"ready-task","home_id":"primary","text":"Answer a non-decision.","request_id":"request-invalid"}'
code=$(curl -sS -o "$HOME_ROOT/invalid-state.json" -w '%{http_code}' \
  -H "X-Firstmate-CSRF: $csrf" -H "Origin: ${url%/}" \
  -H 'Content-Type: application/json' -d "$invalid_payload" "${url}api/v1/actions")
[ "$code" = 400 ] || fail "answer on a non-decision task returned $code"
response=$(curl -fsS -H "X-Firstmate-CSRF: $csrf" -H "Origin: ${url%/}" \
  -H 'Content-Type: application/json' -d "$payload" "${url}api/v1/actions") \
  || fail "valid captain action was refused"
printf '%s' "$response" | jq -e '.queued == true and .duplicate == false' >/dev/null \
  || fail "valid action did not report durable queueing"
assert_contains "$(cat "$HOME_ROOT/inbox.log")" "Task: captain-task" "inbox note omitted the task identity"
assert_contains "$(cat "$HOME_ROOT/inbox.log")" "Use the reversible route" "inbox note omitted the captain answer"
response=$(curl -fsS -H "X-Firstmate-CSRF: $csrf" -H "Origin: ${url%/}" \
  -H 'Content-Type: application/json' -d "$payload" "${url}api/v1/actions") \
  || fail "idempotent captain action retry was refused"
printf '%s' "$response" | jq -e '.queued == true and .duplicate == true' >/dev/null \
  || fail "action retry was not deduplicated"
[ "$(grep -c '^--- action ---$' "$HOME_ROOT/inbox.log")" -eq 1 ] \
  || fail "deduplicated action reached the inbox more than once"
pass "captain actions require same-origin CSRF proof and queue exactly once"

touch "$HOME_ROOT/snapshot.fail"
sleep 1.1
stale=$(curl -fsS "${url}api/v1/board") || fail "last-good board disappeared after refresh failure"
printf '%s' "$stale" | jq -e '
  .health.stale == true
  and (.health.error | contains("fixture snapshot failure"))
  and .counts.needs_you == 2
' >/dev/null || fail "snapshot failure did not retain and disclose the last-good board"
pass "snapshot failures retain a visibly stale last-good board"

kill "$SERVER_PID" 2>/dev/null || fail "could not stop the foreground fixture server"
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=''
LIFE_HOME="$TMP_ROOT/lifecycle-home"
mkdir -p "$LIFE_HOME/state" "$LIFE_HOME/data"
start_url=$(FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$LIFE_HOME" \
  FM_STATE_OVERRIDE="$LIFE_HOME/state" python3 "$SERVER" --start) \
  || fail "background lifecycle start failed"
case "$start_url" in http://127.0.0.1:*/ ) ;; *) fail "start returned an unsafe URL: $start_url" ;; esac
status_out=$(FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$LIFE_HOME" \
  FM_STATE_OVERRIDE="$LIFE_HOME/state" python3 "$SERVER" --status) \
  || fail "background lifecycle status failed"
assert_contains "$status_out" "running: $start_url" "status did not verify the started instance"
stop_out=$(FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$LIFE_HOME" \
  FM_STATE_OVERRIDE="$LIFE_HOME/state" python3 "$SERVER" --stop) \
  || fail "background lifecycle stop failed"
[ "$stop_out" = stopped ] || fail "stop returned an unexpected result: $stop_out"
if FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$LIFE_HOME" \
  FM_STATE_OVERRIDE="$LIFE_HOME/state" python3 "$SERVER" --status >/dev/null 2>&1; then
  fail "stopped application still reported healthy"
fi
pass "background lifecycle reuses verified identity and stops only that instance"
