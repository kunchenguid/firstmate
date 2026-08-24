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
printf '.\n' >> "${FM_HOME:?}/snapshot.calls"
if [ -f "${FM_HOME:?}/snapshot.fail" ]; then
  printf 'fixture snapshot failure\n' >&2
  exit 1
fi
if [ -f "${FM_HOME:?}/snapshot.invalid-utf8" ]; then
  printf '\377'
  exit 0
fi
if [ -f "${FM_HOME:?}/snapshot.array" ]; then
  printf '[]\n'
  exit 0
fi
if [ -f "${FM_HOME:?}/snapshot.bad-shape" ]; then
  printf '{"schema":"fm-fleet-snapshot.v1","backlog":{"records":[null]}}\n'
  exit 0
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
    {"order":7,"structured":true,"id":"done-task","title":"Land the chart","state":"done","repo":"firstmate","kind":"ship","risk":{"level":"low","rationale":"Documentation only.","source":"task-body"},"captain_actionable":false,"unresolved_blocker_ids":[],"report_path":"data/done-task/report.md","links":[]},
    {"order":8,"structured":true,"id":"reactivated-task","title":"Reopen the chart","state":"done","repo":"firstmate","kind":"ship","risk":{"level":"medium","rationale":"The completed task was reactivated.","source":"task-body"},"body_excerpt":"The live worker is canonical.","captain_actionable":false,"unresolved_blocker_ids":[],"links":[]},
    {"order":9,"structured":true,"id":"queued-live-task","title":"Start before charting","state":"queued","repo":"firstmate","kind":"ship","risk":{"level":"low","rationale":"Contained live work.","source":"task-body"},"body_excerpt":"The backlog row has not caught up.","captain_actionable":false,"unresolved_blocker_ids":[],"links":[]}
  ]},
  "tasks":[
    {"id":"working-task","project":"firstmate","kind":"ship","current_state":{"state":"working","source":"pane","detail":"Implementing the board"},"hints":{"pending_decision":false,"blocked_event":false,"open_decisions":[]},"pr":{"url":null},"paths":{"report":{"present":false}}},
    {"id":"verify-task","project":"firstmate","kind":"ship","current_state":{"state":"working","source":"run-step","detail":"Running behavior tests"},"hints":{"pending_decision":false,"blocked_event":false,"open_decisions":[]},"pr":{"url":"https://github.com/example/repo/pull/7"},"paths":{"report":{"present":false}}},
    {"id":"captain-task","project":"firstmate","kind":"ship","current_state":{"state":"parked","source":"status-log","detail":"Choose the migration strategy"},"hints":{"pending_decision":true,"blocked_event":false,"open_decisions":[{"key":"migration","verb":"needs-decision","summary":"Choose the migration strategy"},{"key":"rollout","verb":"needs-decision","summary":"Choose the rollout window"}]},"pr":{"url":null},"paths":{"report":{"present":false}}},
    {"id":"live-only-task","project":"firstmate","kind":"ship","current_state":{"state":"working","source":"pane","detail":"Repairing uncharted work"},"hints":{"pending_decision":false,"blocked_event":false,"open_decisions":[]},"pr":{"url":null},"paths":{"report":{"present":false}}},
    {"id":"reactivated-task","project":"firstmate","kind":"ship","current_state":{"state":"working","source":"pane","detail":"Reopening completed work"},"hints":{"pending_decision":false,"blocked_event":false,"open_decisions":[]},"pr":{"url":null},"paths":{"report":{"present":false}}},
    {"id":"queued-live-task","project":"firstmate","kind":"ship","current_state":{"state":"working","source":"pane","detail":"Working before backlog reconciliation"},"hints":{"pending_decision":false,"blocked_event":false,"open_decisions":[]},"pr":{"url":null},"paths":{"report":{"present":false}}}
  ],
  "main_inventory":{"valid":true,"reason":null},
  "secondmate_current":{"registry":{"complete":false,"reason":null,"reasons":["record_limit"]},"records":[{
    "id":"design-mate","remote":false,"current":{"state":"captain_decision","reason":null},
    "queued":[{"id":"mate-ready","title":"Polish mobile cards","repo":"firstmate","kind":"ship","risk":{"level":"medium","rationale":"Visible UI change.","source":"task-body"},"context":"Mobile context.","captain_actionable":false,"unresolved_blocker_ids":[]},{"id":"mate-held","title":"Hold for vendor keys","repo":"firstmate","kind":"ship","risk":{"level":"low","rationale":"Reversible integration.","source":"task-body"},"context":"Held context.","hold_reason":"Waiting on vendor API keys","captain_actionable":false,"unresolved_blocker_ids":[]}],
    "active_children":[{"id":"mate-working","title":"Tune board spacing","repo":"firstmate","kind":"ship","state":"working","source":"pane","doing":"Checking spacing","risk":{"level":"low","rationale":"Reversible CSS.","source":"task-body"},"context":"Spacing context."}],
    "decisions_open":[{"id":"mate-choice","key":"contrast","verb":"needs-decision","title":"Set the visual direction","summary":"Approve the contrast direction","reason":"Choose navy or rust","repo":"firstmate","kind":"ship","risk":{"level":"medium","rationale":"Visible UI choice.","source":"task-body"},"context":"Visual direction context.","links":["https://example.com/contrast"]},{"id":"mate-choice","key":"type-scale","verb":"needs-decision","title":"Set the visual direction","summary":"Approve the type scale","reason":"Choose compact or relaxed","repo":"firstmate","kind":"ship","risk":{"level":"medium","rationale":"Visible UI choice.","source":"task-body"},"context":"Visual direction context.","links":["https://example.com/type-scale"]}],
    "holds":[],"landed":[{"id":"mate-done","title":"Ship the companion card","repo":"firstmate","kind":"ship","risk":{"level":"medium","rationale":"Visible completion change.","source":"task-body"},"context":"Completion context.","pr_url":"https://github.com/example/repo/pull/8","report_path":"data/mate-done/report.md","links":["https://github.com/example/repo/pull/8"]}],"endpoints":[],
    "counts":{"active_children":1,"decisions_open":2,"holds":2,"queued":2,"landed":1,"endpoints":0},"omitted":[]
  }],"truncated":0},
  "secondmate_landed":{"records":[]}
}
JSON
SH

cat > "$FAKE_ROOT/bin/fm-inbox.sh" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1:-}" = note ] || exit 2
shift
request_id=
json=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request-id) request_id=$2; shift 2 ;;
    --json) json=1; shift ;;
    -) shift; break ;;
    *) exit 2 ;;
  esac
done
[ -n "$request_id" ] && [ "$json" -eq 1 ] && [ "$#" -eq 0 ] || exit 2
body=$(cat)
note="${FM_HOME:?}/request-$request_id.note"
duplicate=false
if [ -f "$note" ]; then
  if [ "$(cat "$note")" != "$body" ]; then
    printf '{"schema":"fm-inbox-note.v1","request_id":"%s","saved":false,"duplicate":true,"wake":"not-attempted","error":"request-id-conflict"}\n' "$request_id"
    exit 3
  fi
  duplicate=true
else
  printf '%s\n' "$body" > "$note"
  {
    printf '%s\n' '--- action ---'
    printf '%s\n' "$body"
  } >> "${FM_HOME:?}/inbox.log"
fi
wake=announced
rc=0
if [ -f "${FM_HOME:?}/wake.fail" ]; then
  wake=failed
  rc=1
fi
printf '{"schema":"fm-inbox-note.v1","id":"request-%s","request_id":"%s","saved":true,"duplicate":%s,"wake":"%s"}\n' \
  "$request_id" "$request_id" "$duplicate" "$wake"
exit "$rc"
SH
chmod +x "$FAKE_ROOT/bin/fm-fleet-snapshot.sh" "$FAKE_ROOT/bin/fm-inbox.sh"

SERVER_PID=''
SECOND_PID=''
RECYCLED_PID=''
HEALTH_PID=''
LIFE_HOME=''
cleanup_server() {
  if [ -n "$LIFE_HOME" ]; then
    FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$LIFE_HOME" \
      FM_STATE_OVERRIDE="$LIFE_HOME/state" python3 "$SERVER" --stop >/dev/null 2>&1 || true
  fi
  if [ -n "$RECYCLED_PID" ] && kill -0 "$RECYCLED_PID" 2>/dev/null; then
    kill "$RECYCLED_PID" 2>/dev/null || true
    wait "$RECYCLED_PID" 2>/dev/null || true
  fi
  if [ -n "$HEALTH_PID" ] && kill -0 "$HEALTH_PID" 2>/dev/null; then
    kill "$HEALTH_PID" 2>/dev/null || true
    wait "$HEALTH_PID" 2>/dev/null || true
  fi
  if [ -n "$SECOND_PID" ] && kill -0 "$SECOND_PID" 2>/dev/null; then
    kill "$SECOND_PID" 2>/dev/null || true
    wait "$SECOND_PID" 2>/dev/null || true
  fi
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -CONT "$SERVER_PID" 2>/dev/null || true
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
instance=$(jq -r '.instance' "$runtime")

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

: > "$HOME_ROOT/server.err"
curl -fsS "${url}healthz" >/dev/null || fail "health poll failed during access-log check"
curl -fsS "${url}api/v1/board" >/dev/null || fail "board poll failed during access-log check"
curl -fsS "$url" >/dev/null || fail "application poll failed during access-log check"
[ ! -s "$HOME_ROOT/server.err" ] || fail "successful polling produced unbounded access-log output"
pass "routine successful polling stays out of the always-on access log"

FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_ROOT" FM_STATE_OVERRIDE="$HOME_ROOT/state" \
  python3 "$SERVER" --serve --port 0 >"$HOME_ROOT/second.out" 2>"$HOME_ROOT/second.err" &
SECOND_PID=$!
for _ in $(seq 1 40); do
  kill -0 "$SECOND_PID" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "$SECOND_PID" 2>/dev/null; then
  kill "$SECOND_PID" 2>/dev/null || true
  wait "$SECOND_PID" 2>/dev/null || true
  SECOND_PID=''
  fail "a second foreground server remained alive for the same Firstmate home"
fi
wait "$SECOND_PID" 2>/dev/null
second_rc=$?
SECOND_PID=''
[ "$second_rc" -ne 0 ] || fail "a second foreground server was accepted"
[ "$(jq -r '.instance' "$runtime")" = "$instance" ] \
  || fail "a refused second server replaced the live runtime identity"
curl -fsS "${url}healthz" >/dev/null || fail "a refused second server disrupted the owner"
pass "one serving process owns the home for its full lifetime"

board=$(curl -fsS "${url}api/v1/board") || fail "board endpoint failed"
printf '%s' "$board" | jq -e '
  .schema == "fm-fleet-board.v1"
  and .counts == {backlog:2,in_progress:5,verification:1,needs_you:2,waiting:3,done:2}
  and .summary == {open:13,needs_you:2,high_risk_open:2}
  and ([.cards[] | select(.id == "captain-task")][0]
       | .lane == "needs_you" and .actions.answer == true and .risk.level == "high"
         and ([.decisions[].key] | sort) == ["migration","rollout"])
  and ([.cards[] | select(.id == "verify-task")][0]
       | .lane == "verification" and (.evidence | map(.kind) | index("pull_request") != null))
  and ([.cards[] | select(.id == "mate-working")][0]
       | .lane == "in_progress" and .home.id == "design-mate")
  and ([.cards[] | select(.id == "live-only-task")][0]
       | .lane == "in_progress" and .context == "Repairing uncharted work")
  and ([.cards[] | select(.id == "reactivated-task")][0]
       | .lane == "in_progress" and .title == "Reopen the chart")
  and ([.cards[] | select(.id == "queued-live-task")][0]
       | .lane == "in_progress" and .status.detail == "Working before backlog reconciliation")
  and ([.cards[] | select(.id == "deferred-task")][0]
       | .lane == "waiting" and .status.wait_reason == "Marked deferred in task context")
  and ([.cards[] | select(.id == "mate-held")][0]
       | .lane == "waiting" and .status.wait_reason == "Waiting on vendor API keys")
  and ([.cards[] | select(.id == "mate-done")][0]
       | .lane == "done"
         and .repo == "firstmate"
         and .kind == "ship"
         and .risk.level == "medium"
         and .context == "Completion context."
         and ([.evidence[].kind] | sort) == ["pull_request", "report"])
  and ([.cards[] | select(.id == "mate-choice")][0]
       | .title == "Set the visual direction"
         and .repo == "firstmate"
         and .kind == "ship"
         and .context == "Visual direction context."
         and ([.decisions[].key] | sort) == ["contrast","type-scale"]
         and ([.evidence[] | select(.kind == "link") | .value] | sort)
           == ["https://example.com/contrast","https://example.com/type-scale"])
  and (.warnings | index("Secondmate registry is incomplete: record_limit") != null)
  and (.warnings | index("design-mate: 2 holds omitted by the snapshot bound") != null)
  and (.warnings | index("live-only-task: live primary task has no structured backlog record") != null)
  and (.warnings | index("reactivated-task: live primary task state working conflicts with its Done backlog row") != null)
  and (.warnings | index("queued-live-task: live primary task state working conflicts with its Queued backlog row") != null)
' >/dev/null || fail "Kanban projection did not preserve lifecycle, risk, evidence, or secondmate work"
pass "canonical fleet state maps into the six truthful Kanban lanes"

for malformed_snapshot in invalid-utf8 array bad-shape; do
  touch "$HOME_ROOT/snapshot.$malformed_snapshot"
  malformed=$(curl -fsS "${url}api/v1/board?refresh=1") \
    || fail "$malformed_snapshot snapshot escaped the last-good boundary"
  printf '%s' "$malformed" | jq -e '.health.stale == true and .counts.in_progress == 5' >/dev/null \
    || fail "$malformed_snapshot snapshot did not retain a visibly stale board"
  rm "$HOME_ROOT/snapshot.$malformed_snapshot"
  board=$(curl -fsS "${url}api/v1/board?refresh=1") \
    || fail "board did not recover after $malformed_snapshot snapshot data"
  printf '%s' "$board" | jq -e '.health.stale == false' >/dev/null \
    || fail "$malformed_snapshot recovery remained stale"
done
pass "malformed snapshot bytes and shapes stay inside the last-good boundary"

csrf=$(printf '%s' "$board" | jq -r '.actions.csrf_token')
payload='{"action":"answer","task_id":"captain-task","home_id":"primary","decision_key":"migration","text":"Use the reversible route and preserve rollback evidence.","request_id":"request-1"}'
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
closed_decision_payload='{"action":"answer","task_id":"captain-task","home_id":"primary","decision_key":"closed-key","text":"Answer a closed decision.","request_id":"request-closed"}'
code=$(curl -sS -o "$HOME_ROOT/closed-decision.json" -w '%{http_code}' \
  -H "X-Firstmate-CSRF: $csrf" -H "Origin: ${url%/}" \
  -H 'Content-Type: application/json' -d "$closed_decision_payload" "${url}api/v1/actions")
[ "$code" = 400 ] || fail "answer routed to a non-open decision returned $code"
response=$(curl -fsS -H "X-Firstmate-CSRF: $csrf" -H "Origin: ${url%/}" \
  -H 'Content-Type: application/json' -d "$payload" "${url}api/v1/actions") \
  || fail "valid captain action was refused"
printf '%s' "$response" | jq -e '.queued == true and .duplicate == false' >/dev/null \
  || fail "valid action did not report durable queueing"
assert_contains "$(cat "$HOME_ROOT/inbox.log")" "Task: captain-task" "inbox note omitted the task identity"
assert_contains "$(cat "$HOME_ROOT/inbox.log")" "Decision: migration" "inbox note omitted the selected decision key"
assert_contains "$(cat "$HOME_ROOT/inbox.log")" "Use the reversible route" "inbox note omitted the captain answer"
response=$(curl -fsS -H "X-Firstmate-CSRF: $csrf" -H "Origin: ${url%/}" \
  -H 'Content-Type: application/json' -d "$payload" "${url}api/v1/actions") \
  || fail "idempotent captain action retry was refused"
printf '%s' "$response" | jq -e '.queued == true and .duplicate == true' >/dev/null \
  || fail "action retry was not deduplicated"
[ "$(grep -c '^--- action ---$' "$HOME_ROOT/inbox.log")" -eq 1 ] \
  || fail "deduplicated action reached the inbox more than once"
pass "captain actions require same-origin CSRF proof and queue exactly once"

kill "$SERVER_PID" 2>/dev/null || fail "could not stop the server for durable retry verification"
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=''
for _ in $(seq 1 100); do
  [ ! -e "$runtime" ] && break
  sleep 0.05
done
[ ! -e "$runtime" ] || fail "stopped server retained its runtime identity"
FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_ROOT" FM_STATE_OVERRIDE="$HOME_ROOT/state" \
  FM_FLEET_BOARD_CACHE_SECONDS=1 python3 "$SERVER" --serve --port 0 \
  >"$HOME_ROOT/server-restarted.out" 2>"$HOME_ROOT/server-restarted.err" &
SERVER_PID=$!
for _ in $(seq 1 100); do
  [ -s "$runtime" ] && break
  sleep 0.05
done
[ -s "$runtime" ] || fail "fleet board did not restart for durable retry verification"
url=$(jq -r '.url' "$runtime")
board=$(curl -fsS "${url}api/v1/board") || fail "restarted board endpoint failed"
csrf=$(printf '%s' "$board" | jq -r '.actions.csrf_token')
response=$(curl -fsS -H "X-Firstmate-CSRF: $csrf" -H "Origin: ${url%/}" \
  -H 'Content-Type: application/json' -d "$payload" "${url}api/v1/actions") \
  || fail "durable captain action retry after restart was refused"
printf '%s' "$response" | jq -e '.queued == true and .duplicate == true' >/dev/null \
  || fail "server restart forgot the durable action request id"
[ "$(grep -c '^--- action ---$' "$HOME_ROOT/inbox.log")" -eq 1 ] \
  || fail "server restart duplicated a durable inbox instruction"
pass "action idempotency survives the board process lifetime"

touch "$HOME_ROOT/wake.fail"
wake_payload='{"action":"answer","task_id":"captain-task","home_id":"primary","decision_key":"rollout","text":"Use the morning rollout window.","request_id":"request-wake-failure"}'
response=$(curl -fsS -H "X-Firstmate-CSRF: $csrf" -H "Origin: ${url%/}" \
  -H 'Content-Type: application/json' -d "$wake_payload" "${url}api/v1/actions") \
  || fail "a saved action was rejected when only its wake failed"
printf '%s' "$response" | jq -e '.queued == true and .duplicate == false and .wake == "failed"' >/dev/null \
  || fail "saved action did not disclose the wake failure"
response=$(curl -fsS -H "X-Firstmate-CSRF: $csrf" -H "Origin: ${url%/}" \
  -H 'Content-Type: application/json' -d "$wake_payload" "${url}api/v1/actions") \
  || fail "saved action retry after wake failure was refused"
printf '%s' "$response" | jq -e '.queued == true and .duplicate == true and .wake == "failed"' >/dev/null \
  || fail "wake-failure retry was not durably deduplicated"
[ "$(grep -c '^--- action ---$' "$HOME_ROOT/inbox.log")" -eq 2 ] \
  || fail "wake-failure retry duplicated the durable inbox note"
rm "$HOME_ROOT/wake.fail"
response=$(curl -fsS -H "X-Firstmate-CSRF: $csrf" -H "Origin: ${url%/}" \
  -H 'Content-Type: application/json' -d "$wake_payload" "${url}api/v1/actions") \
  || fail "saved action could not retry its failed wake"
printf '%s' "$response" | jq -e '.queued == true and .duplicate == true and .wake == "announced"' >/dev/null \
  || fail "saved action did not recover its failed wake without duplication"
pass "wake failure preserves one action and remains recoverable"

touch "$HOME_ROOT/snapshot.fail"
sleep 1.1
stale=$(curl -fsS "${url}api/v1/board") || fail "last-good board disappeared after refresh failure"
printf '%s' "$stale" | jq -e '
  .health.stale == true
  and (.health.error | contains("fixture snapshot failure"))
  and .counts.needs_you == 2
' >/dev/null || fail "snapshot failure did not retain and disclose the last-good board"
pass "snapshot failures retain a visibly stale last-good board"

failed_call_count=$(wc -l < "$HOME_ROOT/snapshot.calls" | tr -d ' ')
for _ in 1 2 3; do
  repeated=$(curl -fsS "${url}api/v1/board") || fail "last-good board failed during retry suppression"
  printf '%s' "$repeated" | jq -e '.health.stale == true' >/dev/null \
    || fail "a failed refresh became healthy without a successful snapshot"
done
[ "$(wc -l < "$HOME_ROOT/snapshot.calls" | tr -d ' ')" = "$failed_call_count" ] \
  || fail "ordinary readers reran the same failed snapshot inside the cache window"
pass "failed refreshes remain stale without repeated snapshot work"

stale_csrf=$(printf '%s' "$stale" | jq -r '.actions.csrf_token')
stale_payload='{"action":"answer","task_id":"captain-task","home_id":"primary","decision_key":"migration","text":"Revalidate, then use the reversible route.","request_id":"request-stale"}'
response=$(curl -fsS -H "X-Firstmate-CSRF: $stale_csrf" -H "Origin: ${url%/}" \
  -H 'Content-Type: application/json' -d "$stale_payload" "${url}api/v1/actions") \
  || fail "captain action on a stale last-good card was refused"
printf '%s' "$response" | jq -e '
  .queued == true and .duplicate == false and .observation == "stale-last-good"
  and .health.stale == true and (.health.error | contains("fixture snapshot failure"))
' >/dev/null || fail "stale action did not report its observation provenance"
assert_contains "$(cat "$HOME_ROOT/inbox.log")" "Board observation: stale-last-good" \
  "stale action omitted its provenance from the Firstmate instruction"
assert_contains "$(cat "$HOME_ROOT/inbox.log")" "Revalidate the canonical task" \
  "stale action did not require canonical revalidation"
action_count=$(grep -o -- '--- action ---' "$HOME_ROOT/inbox.log" | wc -l | tr -d ' ')
[ "$action_count" -eq 3 ] \
  || fail "stale action did not reach the inbox exactly once (total actions: $action_count)"
pass "stale last-good cards keep guarded actions available with revalidation provenance"

rm "$HOME_ROOT/snapshot.fail"
sleep 1.1
fresh=$(curl -fsS "${url}api/v1/board") || fail "board did not recover after snapshot restoration"
printf '%s' "$fresh" | jq -e '.health.stale == false' >/dev/null \
  || fail "a successful refresh did not clear stale health"
fresh_csrf=$(printf '%s' "$fresh" | jq -r '.actions.csrf_token')
response=$(curl -fsS -H "X-Firstmate-CSRF: $fresh_csrf" -H "Origin: ${url%/}" \
  -H 'Content-Type: application/json' -d "$stale_payload" "${url}api/v1/actions") \
  || fail "saved stale action could not retry after snapshot recovery"
printf '%s' "$response" | jq -e \
  '.queued == true and .duplicate == true and .observation == "fresh"' >/dev/null \
  || fail "snapshot freshness changed the durable action identity"
[ "$(grep -c '^--- action ---$' "$HOME_ROOT/inbox.log")" -eq 3 ] \
  || fail "freshness-changing retry duplicated the durable inbox note"
pass "durable action content is stable across snapshot freshness changes"
touch "$HOME_ROOT/snapshot.fail"
forced_payload='{"action":"answer","task_id":"captain-task","home_id":"primary","decision_key":"migration","text":"Keep the cached card guarded.","request_id":"request-forced-stale"}'
curl -fsS -H "X-Firstmate-CSRF: $fresh_csrf" -H "Origin: ${url%/}" \
  -H 'Content-Type: application/json' -d "$forced_payload" "${url}api/v1/actions" >/dev/null \
  || fail "forced stale revalidation refused the guarded action"
forced_stale=$(curl -fsS "${url}api/v1/board") || fail "board disappeared after forced refresh failure"
printf '%s' "$forced_stale" | jq -e '.health.stale == true' >/dev/null \
  || fail "an ordinary cache hit hid the latest forced refresh failure"
pass "the latest failed refresh stays visible inside the cache window"

foreground_instance=$(jq -r '.instance' "$runtime")
kill -STOP "$SERVER_PID" 2>/dev/null || fail "could not suspend the foreground server identity fixture"
if FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_ROOT" FM_STATE_OVERRIDE="$HOME_ROOT/state" \
  python3 "$SERVER" --stop >"$HOME_ROOT/suspended-stop.out" 2>"$HOME_ROOT/suspended-stop.err"; then
  kill -CONT "$SERVER_PID" 2>/dev/null || true
  fail "an unhealthy foreground owner was discarded as an unrelated process"
fi
[ "$(jq -r '.instance' "$runtime")" = "$foreground_instance" ] \
  || fail "foreground recovery replaced the suspended owner's runtime identity"
kill -CONT "$SERVER_PID" 2>/dev/null || fail "could not resume the foreground server identity fixture"
curl -fsS "${url}healthz" >/dev/null || fail "foreground owner did not recover after identity verification"
pass "foreground serving publishes process-verifiable instance identity"

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

HEALTH_FIXTURE="$TMP_ROOT/health-fixture.py"
cat > "$HEALTH_FIXTURE" <<'PY'
import http.server
import pathlib
import socket
import sys
import time

mode = sys.argv[1]
port_file = pathlib.Path(sys.argv[2])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"[]" if mode == "array" else b"\xff"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        pass

if mode in {"malformed_http", "stream"}:
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen()
    port_file.write_text(str(server.getsockname()[1]), encoding="utf-8")
    while True:
        connection, _address = server.accept()
        with connection:
            connection.recv(4096)
            if mode == "malformed_http":
                connection.sendall(b"this is not HTTP\r\n\r\n")
                continue
            connection.sendall(
                b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n"
            )
            try:
                while True:
                    connection.sendall(b"1\r\n{\r\n")
                    time.sleep(0.05)
            except (BrokenPipeError, ConnectionResetError):
                pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY
for health_mode in array invalid_utf8 malformed_http stream; do
  health_port_file="$LIFE_HOME/$health_mode.port"
  python3 "$HEALTH_FIXTURE" "$health_mode" "$health_port_file" &
  HEALTH_PID=$!
  for _ in $(seq 1 100); do
    [ -s "$health_port_file" ] && break
    sleep 0.05
  done
  [ -s "$health_port_file" ] || fail "$health_mode health fixture did not start"
  health_port=$(cat "$health_port_file")
  jq -n --argjson pid "$HEALTH_PID" --argjson port "$health_port" '{
    schema:"fm-fleet-board-runtime.v1",
    instance:"malformed-health-instance",
    pid:$pid,
    port:$port,
    url:("http://127.0.0.1:" + ($port | tostring) + "/")
  }' > "$LIFE_HOME/state/fleet-board/runtime.json"
  status_out=$(bash -c '. "$1"; shift; fm_run_timed 2 "$@"' _ \
    "$ROOT/bin/fm-timeout-lib.sh" env FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$LIFE_HOME" \
    FM_STATE_OVERRIDE="$LIFE_HOME/state" python3 "$SERVER" --status \
    2>"$LIFE_HOME/$health_mode.status.err")
  status_rc=$?
  [ "$status_rc" -eq 1 ] && [ "$status_out" = "not running" ] \
    || fail "$health_mode health response escaped the failed-identity boundary"
  recovered_url=$(FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$LIFE_HOME" \
    FM_STATE_OVERRIDE="$LIFE_HOME/state" python3 "$SERVER" --start) \
    || fail "background lifecycle did not recover from $health_mode health data"
  kill -0 "$HEALTH_PID" 2>/dev/null \
    || fail "health recovery signaled the unrelated $health_mode service"
  stop_out=$(FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$LIFE_HOME" \
    FM_STATE_OVERRIDE="$LIFE_HOME/state" python3 "$SERVER" --stop) \
    || fail "recovered $health_mode lifecycle stop failed"
  [ "$stop_out" = stopped ] || fail "recovered $health_mode stop returned $stop_out"
  kill "$HEALTH_PID" 2>/dev/null || true
  wait "$HEALTH_PID" 2>/dev/null || true
  HEALTH_PID=''
  assert_contains "$recovered_url" "http://127.0.0.1:" \
    "$health_mode recovery did not return the replacement URL"
done
pass "malformed health responses cannot wedge lifecycle recovery"

sleep 30 &
RECYCLED_PID=$!
jq -n --argjson pid "$RECYCLED_PID" '{
  schema:"fm-fleet-board-runtime.v1",
  instance:"unknown-process-instance",
  pid:$pid,
  port:1,
  url:"http://127.0.0.1:1/"
}' > "$LIFE_HOME/state/fleet-board/runtime.json"
PS_UNKNOWN_BIN="$TMP_ROOT/ps-unknown-bin"
mkdir -p "$PS_UNKNOWN_BIN"
cat > "$PS_UNKNOWN_BIN/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$PS_UNKNOWN_BIN/ps"
if PATH="$PS_UNKNOWN_BIN:$PATH" FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$LIFE_HOME" \
  FM_STATE_OVERRIDE="$LIFE_HOME/state" python3 "$SERVER" --start \
  >"$LIFE_HOME/unknown-start.out" 2>"$LIFE_HOME/unknown-start.err"; then
  fail "an unavailable process identity probe replaced a possibly live server"
fi
[ "$(jq -r '.instance' "$LIFE_HOME/state/fleet-board/runtime.json")" = unknown-process-instance ] \
  || fail "an unavailable process probe discarded the only runtime identity"
kill "$RECYCLED_PID" 2>/dev/null || true
wait "$RECYCLED_PID" 2>/dev/null || true
RECYCLED_PID=''
rm -f "$LIFE_HOME/state/fleet-board/runtime.json"
pass "unknown process identity fails closed without orphaning runtime state"

sleep 30 &
RECYCLED_PID=$!
jq -n --argjson pid "$RECYCLED_PID" '{
  schema:"fm-fleet-board-runtime.v1",
  instance:"stale-runtime-instance",
  pid:$pid,
  port:1,
  url:"http://127.0.0.1:1/"
}' > "$LIFE_HOME/state/fleet-board/runtime.json"
recovered_url=$(FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$LIFE_HOME" \
  FM_STATE_OVERRIDE="$LIFE_HOME/state" python3 "$SERVER" --start) \
  || fail "background lifecycle did not recover from a reused stale PID"
kill -0 "$RECYCLED_PID" 2>/dev/null \
  || fail "lifecycle recovery signaled the unrelated process that reused a stale PID"
stop_out=$(FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$LIFE_HOME" \
  FM_STATE_OVERRIDE="$LIFE_HOME/state" python3 "$SERVER" --stop) \
  || fail "recovered background lifecycle stop failed"
[ "$stop_out" = stopped ] || fail "recovered stop returned an unexpected result: $stop_out"
kill "$RECYCLED_PID" 2>/dev/null || true
wait "$RECYCLED_PID" 2>/dev/null || true
RECYCLED_PID=''
assert_contains "$recovered_url" "http://127.0.0.1:" \
  "lifecycle recovery did not return the replacement board URL"
pass "stale runtime records recover safely when their PID belongs to another process"

INBOX_HOME="$TMP_ROOT/inbox-home"
mkdir -p "$INBOX_HOME/state" "$INBOX_HOME/data"
inbox_out=$(printf '%s' 'Persist this captain action.' | \
  FM_HOME="$INBOX_HOME" FM_STATE_OVERRIDE="$INBOX_HOME/state" \
  FM_WAKE_QUEUE="$INBOX_HOME/state" "$ROOT/bin/fm-inbox.sh" \
  note --request-id durable-action --json - 2>"$INBOX_HOME/failed-wake.err")
inbox_rc=$?
[ "$inbox_rc" -ne 0 ] || fail "inbox wake fixture unexpectedly succeeded"
printf '%s' "$inbox_out" | jq -e \
  '.saved == true and .duplicate == false and .wake == "failed"' >/dev/null \
  || fail "inbox did not report that the note survived its wake failure"
[ "$(find "$INBOX_HOME/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "failed wake did not leave exactly one durable inbox note"
retry_out=$(printf '%s' 'Persist this captain action.' | \
  FM_HOME="$INBOX_HOME" FM_STATE_OVERRIDE="$INBOX_HOME/state" \
  FM_WAKE_QUEUE="$INBOX_HOME/state" "$ROOT/bin/fm-inbox.sh" \
  note --request-id durable-action --json - 2>"$INBOX_HOME/repeated-wake.err")
retry_rc=$?
[ "$retry_rc" -ne 0 ] || fail "repeated failed wake fixture unexpectedly succeeded"
printf '%s' "$retry_out" | jq -e \
  '.saved == true and .duplicate == true and .wake == "failed"' >/dev/null \
  || fail "a new inbox process did not recognize the durable request id"
[ "$(find "$INBOX_HOME/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "inbox restart duplicated the failed-wake note"
retry_out=$(printf '%s' 'Persist this captain action.' | \
  FM_HOME="$INBOX_HOME" FM_STATE_OVERRIDE="$INBOX_HOME/state" \
  FM_WAKE_QUEUE="$INBOX_HOME/state/.wake-queue" "$ROOT/bin/fm-inbox.sh" \
  note --request-id durable-action --json - 2>"$INBOX_HOME/recovered-wake.err")
retry_rc=$?
[ "$retry_rc" -eq 0 ] || fail "durable inbox retry did not recover its wake"
printf '%s' "$retry_out" | jq -e \
  '.saved == true and .duplicate == true and .wake == "announced"' >/dev/null \
  || fail "durable inbox retry did not announce the existing note"
FM_HOME="$INBOX_HOME" FM_STATE_OVERRIDE="$INBOX_HOME/state" \
  "$ROOT/bin/fm-inbox.sh" drain --ack request-durable-action >/dev/null \
  || fail "durable inbox note could not be acknowledged"
handled_out=$(printf '%s' 'Persist this captain action.' | \
  FM_HOME="$INBOX_HOME" FM_STATE_OVERRIDE="$INBOX_HOME/state" \
  FM_WAKE_QUEUE="$INBOX_HOME/state/.wake-queue" "$ROOT/bin/fm-inbox.sh" \
  note --request-id durable-action --json - 2>"$INBOX_HOME/handled-retry.err")
printf '%s' "$handled_out" | jq -e \
  '.saved == true and .duplicate == true and .wake == "handled"' >/dev/null \
  || fail "handled inbox request id did not remain idempotent"
conflict_out=$(printf '%s' 'Different action under the same id.' | \
  FM_HOME="$INBOX_HOME" FM_STATE_OVERRIDE="$INBOX_HOME/state" \
  FM_WAKE_QUEUE="$INBOX_HOME/state/.wake-queue" "$ROOT/bin/fm-inbox.sh" \
  note --request-id durable-action --json - 2>"$INBOX_HOME/conflict.err")
conflict_rc=$?
[ "$conflict_rc" -ne 0 ] || fail "inbox accepted different content under an existing request id"
printf '%s' "$conflict_out" | jq -e \
  '.saved == false and .error == "request-id-conflict"' >/dev/null \
  || fail "inbox request-id conflict was not machine-readable"
pass "the inbox durably owns action idempotency and wake recovery"

if command -v node >/dev/null 2>&1; then
  node --check "$ROOT/bin/fleet-board/app.js" >/dev/null \
    || fail "fleet board client script did not parse"
  if ! node - "$ROOT/bin/fleet-board/board-state.js" <<'JS'
require(process.argv[2]);
const {
  applyActionObservation,
  beginAction,
  cardFingerprint,
  reconcileBoardState,
  restoreActionOperations,
  serializeActionOperations,
} = globalThis.FleetBoardState;
const clone = (value) => JSON.parse(JSON.stringify(value));
const card = {
  key: "primary:captain-task",
  lane: "needs_you",
  status: { label: "Waiting for you", source: "status-log" },
  decisions: [{ key: "migration", verb: "needs-decision", summary: "Choose migration", reason: null }],
  actions: { answer: true, request_details: true },
};
const pending = new Map([[card.key, { fingerprint: cardFingerprint(card) }]]);
const drafts = new Map();
let result = reconcileBoardState(pending, drafts, card.key, [clone(card)]);
if (pending.size !== 1 || result.selectedKey !== card.key) process.exit(1);
const moved = clone(card);
moved.lane = "done";
moved.status = { label: "Completed", source: "backlog" };
moved.actions = { answer: false, request_details: false };
result = reconcileBoardState(pending, drafts, card.key, [moved]);
if (pending.size !== 0 || result.selectedKey !== card.key) process.exit(1);
const decisionPending = new Map([[card.key, { fingerprint: cardFingerprint(card) }]]);
const nextDecision = clone(card);
nextDecision.decisions = [{ key: "rollout", verb: "needs-decision", summary: "Choose rollout", reason: null }];
reconcileBoardState(decisionPending, new Map(), card.key, [nextDecision]);
if (decisionPending.size !== 0) process.exit(1);
result = reconcileBoardState(new Map(), new Map(), card.key, []);
if (result.selectedKey !== null || result.selectedCard !== null) process.exit(1);

const actionDrafts = new Map([[card.key, {
  action: "answer",
  text: "Keep the reversible route.",
  decisionKey: "migration",
  requestId: null,
  attempted: false,
  inFlight: false,
}]]);
let generated = 0;
const first = beginAction(actionDrafts, card.key, () => `request-${++generated}`);
if (actionDrafts.get(card.key) !== first || !first.inFlight || generated !== 1) process.exit(1);
first.inFlight = false;
const retry = beginAction(actionDrafts, card.key, () => `request-${++generated}`);
if (retry.requestId !== "request-1" || generated !== 1) process.exit(1);
const restored = restoreActionOperations(serializeActionOperations(actionDrafts));
const restoredOperation = restored.get(card.key);
if (
  restoredOperation?.requestId !== "request-1"
  || restoredOperation.text !== "Keep the reversible route."
  || !restoredOperation.attempted
  || restoredOperation.inFlight
) process.exit(1);
if (restoreActionOperations("not json").size !== 0) process.exit(1);

const unsent = new Map([[card.key, {
  action: "answer",
  text: "Preserve this draft.",
  decisionKey: "migration",
  requestId: null,
}]]);
const statusChanged = clone(card);
statusChanged.status = { label: "Still waiting for you", source: "fresh-status" };
reconcileBoardState(new Map(), unsent, card.key, [statusChanged]);
if (unsent.get(card.key)?.text !== "Preserve this draft.") process.exit(1);
reconcileBoardState(new Map(), unsent, card.key, [nextDecision]);
if (unsent.size !== 0) process.exit(1);

const observed = applyActionObservation(
  { generated: "2026-08-24T11:00:00Z", health: { stale: false, error: null } },
  { observation: "stale-last-good", health: { stale: true, error: "fixture failure" } }
);
if (!observed.health.stale || observed.health.error !== "fixture failure") process.exit(1);
JS
  then
    fail "fleet board client-state reconciliation failed"
  fi
  pass "client actions, drafts, stale health, and canonical state reconcile durably"
fi

OPEN_FAKEBIN="$TMP_ROOT/open-fakebin"
mkdir -p "$OPEN_FAKEBIN"
cat > "$OPEN_FAKEBIN/python3" <<'SH'
#!/usr/bin/env bash
printf 'http://127.0.0.1:43210/\n'
SH
cat > "$OPEN_FAKEBIN/open" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$OPEN_FAKEBIN/python3" "$OPEN_FAKEBIN/open"
open_out=$(PATH="$OPEN_FAKEBIN:$PATH" "$ROOT/bin/fm-fleet-board.sh" open 2>"$TMP_ROOT/open.err")
open_rc=$?
[ "$open_rc" -eq 0 ] || fail "a failed browser opener made the open command fail"
[ "$open_out" = "http://127.0.0.1:43210/" ] || fail "open did not print the usable board URL"
assert_contains "$(cat "$TMP_ROOT/open.err")" "browser opener failed" \
  "open did not disclose the browser launch failure"
pass "browser launch failure still returns the usable board URL"
