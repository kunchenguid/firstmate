#!/usr/bin/env bash
# tests/fm-dashboard.test.sh - end-to-end coverage for the Admiral's Fleet
# Dashboard: a real server process, driven only through bin/fm-dashboard.sh
# and the HTTP API it wraps, exactly the way an agent or the fleet auditor
# would use it. No test here asserts on implementation-source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { pass "skipped - python3 not available"; exit 0; }
command -v jq >/dev/null 2>&1 || { pass "skipped - jq not available"; exit 0; }
command -v curl >/dev/null 2>&1 || { pass "skipped - curl not available"; exit 0; }

DASH="$ROOT/bin/fm-dashboard.sh"
SERVER_PID=""

fm_dashboard_test_cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  fm_test_cleanup
}
trap fm_dashboard_test_cleanup EXIT
trap 'fm_dashboard_test_cleanup; exit 130' INT
trap 'fm_dashboard_test_cleanup; exit 143' TERM

FM_HOME=$(fm_test_tmproot fm-dashboard-test) || fail "could not create temp FM_HOME"
mkdir -p "$FM_HOME/state" "$FM_HOME/data"
export FM_HOME
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()') \
  || fail "could not allocate a free port"
export FM_DASHBOARD_HOST=127.0.0.1
export FM_DASHBOARD_PORT="$PORT"

start_server() {
  "$DASH" start >"$FM_HOME/start.out" 2>&1 || {
    cat "$FM_HOME/start.out" >&2
    fail "server did not start"
  }
  SERVER_PID=$(cat "$FM_HOME/state/dashboard.pid" 2>/dev/null)
  [ -n "$SERVER_PID" ] || fail "no pid recorded after start"
}

start_server

test_health_and_server_status() {
  "$DASH" server-status | assert_grep "api:     reachable" -
  pass "server-status reports the running, reachable server"
}

test_add_and_list_round_trip() {
  local id row
  row=$("$DASH" add --title "Ship the board" --captain dj --prompt "His own words, verbatim." --agent "crew-1") \
    || fail "add failed: $row"
  id=$(printf '%s' "$row" | awk '{print $1}')
  [ -n "$id" ] || fail "add did not return a task id"

  assert_contains "$("$DASH" list)" "$id" "list did not include the newly added task"
  assert_contains "$("$DASH" show "$id")" "His own words, verbatim." "show did not return the verbatim prompt"
  echo "$id" > "$FM_HOME/task-id"
  pass "add/list/show round-trip works through the CLI"
}

test_status_and_captain_and_title_updates() {
  local id
  id=$(cat "$FM_HOME/task-id")

  "$DASH" status "$id" working >/dev/null || fail "status transition to working failed"
  assert_contains "$("$DASH" show "$id")" "status:   working" "status did not persist"

  "$DASH" title "$id" "Ship the board (renamed)" >/dev/null || fail "title update failed"
  assert_contains "$("$DASH" show "$id")" "Ship the board (renamed)" "title did not persist"

  "$DASH" captain "$id" river >/dev/null || fail "captain update failed"
  assert_contains "$("$DASH" show "$id")" "captain:  captain_river" "captain did not persist"

  pass "status, title, and captain updates persist through the CLI"
}

test_waiting_status_carries_target_and_reason() {
  local id waiter
  id=$(cat "$FM_HOME/task-id")
  waiter=$("$DASH" add --title "Blocked on the board" --captain firstmate --prompt "waits on the other card" | awk '{print $1}')
  [ -n "$waiter" ] || fail "second add failed"

  "$DASH" status "$waiter" waiting --waiting-on "$id" --reason "needs it merged first" >/dev/null \
    || fail "waiting status with target failed"
  local out
  out=$("$DASH" show "$waiter")
  assert_contains "$out" "waiting on: $id" "waiting-on target did not persist"
  assert_contains "$out" "needs it merged first" "waiting reason did not persist"
  pass "waiting status carries its target card and reason"
}

test_needs_attention_status_carries_reason_and_sorts_first() {
  local id working_id out
  id=$("$DASH" add --title "Needs a decision" --captain firstmate --prompt "checking needs-attention" | awk '{print $1}')
  working_id=$("$DASH" add --title "Being actively worked" --captain firstmate --prompt "sort-order control" --status working | awk '{print $1}')

  "$DASH" status "$id" needs-attention --reason "pick red or blue for the trim" >/dev/null \
    || fail "status transition to needs-attention failed"
  out=$("$DASH" show "$id")
  assert_contains "$out" "status:   needs_attention" "needs-attention status did not persist"
  assert_contains "$out" "needs attention: pick red or blue for the trim" "needs-attention reason did not persist"

  local first_id
  first_id=$("$DASH" list --sort status | head -n1 | awk '{print $1}')
  [ "$first_id" = "$id" ] || fail "needs-attention ($id) did not sort above a working card ($working_id) under --sort status, got: $first_id"

  "$DASH" status "$id" working >/dev/null || fail "leaving needs-attention failed"
  assert_not_contains "$("$DASH" show "$id")" "needs attention:" "needs-attention reason was not cleared on status change"

  pass "needs-attention status carries a reason and sorts above every other status"
}

test_needs_attention_requires_a_real_ask() {
  local id out rc
  id=$("$DASH" add --title "Reason guard coverage" --captain firstmate --prompt "checking the needs-attention guard" | awk '{print $1}')

  # The CLI refuses locally, before any network round-trip, on the obvious
  # missing-reason case.
  out=$("$DASH" status "$id" needs-attention 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "needs-attention with no --reason was accepted"
  assert_contains "$out" "requires --reason" "missing-reason rejection did not explain the requirement"

  # The server enforces the same rule structurally, not just the CLI's
  # local check: a direct call with an empty reason must also be refused.
  local raw_code
  raw_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks/$id/status" \
    -H 'Content-Type: application/json' -d '{"status":"needs_attention"}')
  [ "$raw_code" = "400" ] || fail "the API accepted needs_attention with no reason (got HTTP $raw_code)"

  # A reason that only reports progress is refused too, even though it is
  # non-empty.
  out=$("$DASH" status "$id" needs-attention --reason "You reported flares not changing the lights - being chased now" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a report-shaped needs-attention reason was accepted"
  assert_contains "$out" "reads as a progress report" "report-shaped rejection did not explain why"

  # A genuine ask is accepted and persists.
  "$DASH" status "$id" needs-attention --reason "approve the trim color before the install" >/dev/null \
    || fail "a genuine ask was rejected as report-shaped"
  assert_contains "$("$DASH" show "$id")" "needs attention: approve the trim color before the install" \
    "a genuine ask did not persist after the guard ran"

  # Creating a card straight into needs-attention is governed the same way.
  out=$("$DASH" add --title "Bad create" --captain firstmate --prompt "x" --status needs-attention 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "add --status needs-attention with no --reason was accepted"
  assert_contains "$out" "requires --reason" "add's missing-reason rejection did not explain the requirement"

  local created
  created=$("$DASH" add --title "Good create" --captain firstmate --prompt "x" \
    --status needs-attention --reason "sign the updated contractor agreement" | awk '{print $1}')
  [ -n "$created" ] || fail "add --status needs-attention with a real ask should have succeeded"
  assert_contains "$("$DASH" show "$created")" "needs attention: sign the updated contractor agreement" \
    "a card created straight into needs-attention did not carry its reason"

  pass "needs-attention refuses a missing or report-shaped reason, on both status and add, and the server enforces it independently of the CLI"
}

test_star_and_delete() {
  local id
  id=$(cat "$FM_HOME/task-id")
  "$DASH" star "$id" >/dev/null || fail "star failed"
  assert_contains "$("$DASH" show "$id")" "starred:  true" "star did not persist"

  if "$DASH" delete "$id" 2>/dev/null; then
    fail "delete without --confirm should have been refused"
  fi

  "$DASH" delete "$id" --confirm >/dev/null || fail "confirmed delete failed"
  if "$DASH" show "$id" >/dev/null 2>&1; then
    fail "deleted task is still readable"
  fi
  pass "starring persists and delete requires --confirm"
}

test_notes_tabs_and_empty_tab_semantics() {
  local id out
  id=$("$DASH" add --title "Notes coverage" --captain firstmate --prompt "checking tabs" | awk '{print $1}')

  out=$("$DASH" show "$id")
  assert_not_contains "$out" "--- interpretation ---" "a fresh task must not show a forced interpretation section"

  "$DASH" note "$id" --tab interpretation --author agent --text "a genuine reading" >/dev/null \
    || fail "note add failed"
  out=$("$DASH" show "$id")
  assert_contains "$out" "a genuine reading" "interpretation note did not appear"

  pass "interpretation tab stays absent until something real is recorded"
}

test_link_policy_rejects_github_and_localhost() {
  local id out rc
  id=$("$DASH" add --title "Link policy coverage" --captain firstmate --prompt "checking links" | awk '{print $1}')

  out=$("$DASH" link "$id" --url "https://github.com/kunchenguid/firstmate/pull/1" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a GitHub link was accepted"
  assert_contains "$out" "standing order 17" "GitHub rejection did not cite standing order 17"

  out=$("$DASH" link "$id" --url "http://127.0.0.1:9/thing" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a local-only link was accepted"

  "$DASH" link "$id" --url "https://example.com/review/42" --label "Preview" >/dev/null \
    || fail "a legitimate phone-openable link was rejected"
  assert_contains "$("$DASH" show "$id")" "example.com/review/42" "accepted link did not persist"
  pass "link policy rejects GitHub/PR and local-only links, accepts a real one"
}

test_audit_log_run_and_interval() {
  "$DASH" audit-log --fleet "seeded discrepancy for coverage" --kind discrepancy >/dev/null \
    || fail "fleet-wide audit-log failed"
  "$DASH" audit-run --duration-seconds 1.5 --checked 3 --discrepancies 1 >/dev/null \
    || fail "audit-run failed"

  local status_json
  status_json=$(curl -sS "http://127.0.0.1:$PORT/api/audit/status")
  assert_contains "$status_json" "seeded discrepancy for coverage" "discrepancy log did not record the finding"
  assert_contains "$status_json" '"tasks_checked": 3' "audit run summary did not persist"

  assert_contains "$("$DASH" audit-interval get)" "every 15 minute(s)" "default audit interval is not 15 minutes"
  assert_contains "$("$DASH" audit-interval 5)" "every 5 minute(s)" "audit interval did not update"
  assert_contains "$("$DASH" audit-interval get)" "every 5 minute(s)" "audit interval change did not persist"
  pass "audit-log, audit-run, and audit-interval work end to end"
}

# The board is typically a tailnet host that can simply be powered off, which
# drops packets rather than refusing them, and these calls run inside held
# handoff locks (bin/fm-backlog-handoff.sh) and on bin/fm-bootstrap.sh's
# synchronous path - an unbounded wait there stalls the whole fleet rather
# than one card. Drive that with a real listener that accepts the connection
# and then answers nothing at all, which is exactly what a refused-connection
# fixture cannot reproduce.
test_calls_are_bounded_against_a_board_that_never_answers() {
  local portfile blackhole_pid port i rc
  command -v timeout >/dev/null 2>&1 || { pass "skipped bounded-call coverage - timeout(1) not available"; return 0; }
  portfile="$FM_HOME/blackhole.port"
  rm -f "$portfile"
  python3 - "$portfile" >/dev/null 2>&1 <<'PY' &
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(16)
with open(sys.argv[1] + ".tmp", "w") as fh:
    fh.write(str(s.getsockname()[1]))
import os
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
held = []
while True:
    conn, _ = s.accept()
    held.append(conn)  # accepted, then deliberately never answered
    time.sleep(0.01)
PY
  blackhole_pid=$!
  i=0
  until [ -s "$portfile" ]; do
    i=$((i + 1))
    [ "$i" -lt 200 ] || { kill "$blackhole_pid" 2>/dev/null; fail "the never-answering fixture never bound a port"; }
    sleep 0.05
  done
  port=$(cat "$portfile")

  rc=0
  FM_DASHBOARD_URL="http://127.0.0.1:$port" FM_DASHBOARD_MAX_TIME=2 \
    timeout 20 "$DASH" show any-card --json >/dev/null 2>&1 || rc=$?
  kill "$blackhole_pid" 2>/dev/null
  wait "$blackhole_pid" 2>/dev/null

  [ "$rc" -ne 124 ] || fail "a board that accepts the connection and never answers hung the call: it is not bounded"
  [ "$rc" -ne 0 ] || fail "a board that never answers somehow reported success"
  pass "every dashboard call is bounded, so a board that never answers fails fast instead of hanging"
}

# The bound above can be handed back by an override curl accepts but reads as
# "no timeout at all": --max-time 0 and --connect-timeout 0 are unlimited, not
# instant. A zero (or all-zero decimal) override therefore has to be refused
# exactly like a non-numeric one - reported loudly and replaced by the
# default - rather than passed through to curl.
test_zero_timeout_override_is_refused_like_any_other_unusable_one() {
  local err
  err="$FM_HOME/zero-timeout.err"

  FM_DASHBOARD_MAX_TIME=0 FM_DASHBOARD_CONNECT_TIMEOUT=0.0 \
    "$DASH" list >/dev/null 2>"$err" || fail "list failed under a zero timeout override: $(cat "$err")"
  assert_grep 'ignoring invalid FM_DASHBOARD_MAX_TIME=0' "$err" \
    "a zero --max-time override was accepted silently instead of falling back to the bounded default"
  assert_grep 'ignoring invalid FM_DASHBOARD_CONNECT_TIMEOUT=0.0' "$err" \
    "an all-zero --connect-timeout override was accepted silently instead of falling back to the bounded default"

  FM_DASHBOARD_MAX_TIME=2 "$DASH" list >/dev/null 2>"$err" \
    || fail "list failed under a valid timeout override: $(cat "$err")"
  assert_no_grep 'ignoring invalid' "$err" "a valid timeout override was rejected"
  pass "a zero timeout override is refused and replaced by the default, so the bound cannot be handed back"
}

# bin/fm-backlog-handoff.sh's pending card record retires neither: a
# "no such card" only proves some host answered, never that the host answering
# was the board, so such a pair is kept and retried exactly like one the board
# could not be reached for. Both are reported the same way too - once per
# command that sweeps the pair, and again on a later separate invocation while
# the link is still owed. Neither reaches the fleet audit log either. What the
# two answers still decide is WHICH stderr warning the pair gets, so the
# handoff has to be able to tell them apart from the outside - by exit code
# rather than by parsing stderr.
test_missing_id_and_unreachable_board_have_distinct_exit_codes() {
  local rc=0
  "$DASH" show definitely-no-such-card --json >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 4 ] || fail "a board-answered 'no such card' should exit 4, got $rc"

  rc=0
  FM_DASHBOARD_PORT=1 "$DASH" show definitely-no-such-card --json >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "an unreachable board should exit 1, not the not-found code, got $rc"
  pass "a board-answered missing id and an unreachable board are distinguishable by exit code"
}

test_bad_input_fails_with_nonzero_exit() {
  if "$DASH" status nonexistent-id working >/dev/null 2>&1; then
    fail "status on a nonexistent task should have failed"
  fi

  if "$DASH" add --captain dj --prompt "missing title" >/dev/null 2>&1; then
    fail "add without --title should have failed"
  fi

  if "$DASH" captain "$(cat "$FM_HOME/task-id" 2>/dev/null || printf 'x')" nobody >/dev/null 2>&1; then
    fail "an unknown captain should have been refused"
  fi
  pass "invalid input fails loudly with a non-zero exit, not a silent success"
}

test_health_and_server_status
test_add_and_list_round_trip
test_status_and_captain_and_title_updates
test_waiting_status_carries_target_and_reason
test_notes_tabs_and_empty_tab_semantics
test_link_policy_rejects_github_and_localhost
test_needs_attention_status_carries_reason_and_sorts_first
test_needs_attention_requires_a_real_ask
test_audit_log_run_and_interval
test_bad_input_fails_with_nonzero_exit
test_calls_are_bounded_against_a_board_that_never_answers
test_zero_timeout_override_is_refused_like_any_other_unusable_one
test_missing_id_and_unreachable_board_have_distinct_exit_codes
test_star_and_delete
