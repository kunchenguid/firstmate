#!/usr/bin/env bash
# Deterministic captain-facing lifecycle migration, transition, precedence, and closure integration tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIFE="$ROOT/bin/fm-task-lifecycle.sh"
TASKS="$ROOT/bin/fm-tasks.sh"
CLOSE="$ROOT/bin/fm-close.sh"
HISTORY="$ROOT/bin/fm-history.sh"
AXI="$ROOT/bin/fm-tasks-axi.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-lifecycle)
command -v tasks-axi >/dev/null 2>&1 || { printf 'ok - skipped: tasks-axi is required\n'; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"
[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 50
EOF
  printf '%s\n' "$home"
}

add_done() {  # <home> <id> <title>
  FM_HOME="$1" "$AXI" add "$2" "$3" --kind scout --repo sample >/dev/null || fail "could not add $2"
  FM_HOME="$1" "$AXI" 'done' "$2" --note "candidate result" >/dev/null || fail "could not finish $2"
}

run_life() {  # <home> <time> <args...>
  local home=$1 time=$2
  shift 2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TASK_LIFECYCLE_NOW="$time" "$LIFE" "$@"
}

home=$(make_home routes)
add_done "$home" monitored-task "Monitored release task"

# Migration is read-only and never promotes legacy Done to acceptance.
before=$(cksum "$home/data/backlog.md")
row=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$TASKS" --json monitored-task) || fail "legacy Done projection failed"
printf '%s\n' "$row" | jq -e '
  .[0].status == "done" and .[0].lifecycle == null and .[0].route == null
  and .[0].close_ready == false and .[0].next_action == "Start review"
' >/dev/null || fail "legacy Done acquired false acceptance: $row"
[ "$before" = "$(cksum "$home/data/backlog.md")" ] || fail "migration projection mutated backlog"
assert_absent "$home/data/task-lifecycle" "migration projection wrote a lifecycle record"
if FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$CLOSE" monitored-task >"$home/unreviewed.out" 2>&1; then
  fail "unreviewed Done task closed"
fi
assert_grep "cannot close: Start review" "$home/unreviewed.out" "unreviewed close refusal omitted the missing next step"
pass "existing Done tasks migrate without false acceptance"

run_life "$home" 2026-09-16T10:00:00Z review-start monitored-task >/dev/null
row=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$TASKS" --json monitored-task)
printf '%s\n' "$row" | jq -e '.[0].status == "reviewing" and .[0].started_at == "2026-09-16T10:00:00Z" and (.[0].next_action | contains("Accept"))' >/dev/null \
  || fail "review-start did not enter reviewing: $row"
record="$home/data/task-lifecycle/monitored-task.json"
review_sum=$(cksum "$record")
if run_life "$home" 2026-09-16T10:00:30Z delivery-start monitored-task >"$home/early-delivery.out" 2>&1; then
  fail "delivery started before acceptance"
fi
assert_grep "must be accepted before delivery" "$home/early-delivery.out" "invalid transition did not name its prerequisite"
[ "$review_sum" = "$(cksum "$record")" ] || fail "refused transition changed the lifecycle record"

run_life "$home" 2026-09-16T10:01:00Z accept monitored-task \
  --actor release-reviewer --evidence "review checklist passed" --limitations "observe error rate" --route deliver-monitor >/dev/null
jq -e '
  .stage == "accepted"
  and .acceptance.actor == "release-reviewer"
  and .acceptance.at == "2026-09-16T10:01:00Z"
  and .acceptance.evidence == "review checklist passed"
  and .acceptance.limitations == "observe error rate"
  and .acceptance.route == "deliver-monitor"
' "$record" >/dev/null || fail "acceptance evidence was incomplete"
if FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$CLOSE" monitored-task >"$home/undelivered.out" 2>&1; then
  fail "accepted undelivered task closed"
fi
assert_grep "Start the selected delivery route" "$home/undelivered.out" "undelivered close refusal omitted its next action"

run_life "$home" 2026-09-16T10:02:00Z delivery-start monitored-task >/dev/null
run_life "$home" 2026-09-16T10:03:00Z delivery-complete monitored-task --evidence "release 42 published" >/dev/null
row=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$TASKS" --json monitored-task)
printf '%s\n' "$row" | jq -e '
  .[0].status == "delivering" and .[0].started_at == "2026-09-16T10:02:00Z"
  and .[0].route == "deliver-monitor"
  and .[0].close_ready == false and .[0].next_action == "Start monitoring"
' >/dev/null || fail "completed delivery skipped required monitoring: $row"
if FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$CLOSE" monitored-task >"$home/unmonitored.out" 2>&1; then
  fail "unmonitored delivery closed"
fi
assert_grep "Start monitoring" "$home/unmonitored.out" "unmonitored close refusal omitted its next action"

run_life "$home" 2026-09-16T10:04:00Z monitoring-start monitored-task >/dev/null
run_life "$home" 2026-09-16T10:05:00Z monitoring-complete monitored-task --evidence "error rate stable for 30 minutes" >/dev/null
row=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$TASKS" --json monitored-task)
printf '%s\n' "$row" | jq -e '
  .[0].status == "monitoring" and .[0].started_at == "2026-09-16T10:04:00Z"
  and .[0].close_ready == true
  and .[0].outcome == "Monitoring complete; ready to close"
' >/dev/null || fail "completed monitoring did not become closable: $row"
FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$CLOSE" monitored-task >/dev/null || fail "completed monitored route did not close"
closed=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$HISTORY" --json monitored-task) || fail "closed lifecycle was not in history"
printf '%s\n' "$closed" | jq -e '
  .[0].version == 2
  and .[0].lifecycle.acceptance.actor == "release-reviewer"
  and .[0].lifecycle.acceptance.route == "deliver-monitor"
  and .[0].lifecycle.delivery.evidence == "release 42 published"
  and .[0].lifecycle.monitoring.evidence == "error rate stable for 30 minutes"
' >/dev/null || fail "closure archive lost acceptance or route evidence: $closed"
assert_absent "$record" "closure left the live lifecycle record behind"
[ "$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$TASKS" --json | jq 'length')" -eq 0 ] \
  || fail "closed lifecycle remained in /tasks"
pass "review, acceptance, delivery, monitoring, close, and history integrate end to end"

# Review and monitoring findings deterministically return a task to working and clear acceptance for the changed result.
add_done "$home" correction-task "Review correction task"
run_life "$home" 2026-09-16T11:00:00Z review-start correction-task >/dev/null
run_life "$home" 2026-09-16T11:01:00Z return-to-work correction-task --reason "add the missing regression test" >/dev/null
row=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$TASKS" --json correction-task)
printf '%s\n' "$row" | jq -e '
  .[0].status == "working" and .[0].started_at == "2026-09-16T11:01:00Z"
  and .[0].route == null and .[0].close_ready == false
  and .[0].lifecycle.acceptance == null
  and .[0].lifecycle.correction.from == "reviewing"
  and .[0].lifecycle.correction.reason == "add the missing regression test"
' >/dev/null || fail "review correction did not return to unaccepted working: $row"
if FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$CLOSE" correction-task >"$home/correction-close.out" 2>&1; then
  fail "corrective working task closed"
fi
assert_grep "Continue the current work" "$home/correction-close.out" "corrective close refusal omitted current work"
pass "review correction returns to working and invalidates acceptance"

add_done "$home" rollback-task "Monitoring rollback task"
run_life "$home" 2026-09-16T11:10:00Z review-start rollback-task >/dev/null
run_life "$home" 2026-09-16T11:11:00Z accept rollback-task --actor reviewer --evidence "ready to release" --route deliver-monitor >/dev/null
run_life "$home" 2026-09-16T11:12:00Z delivery-start rollback-task >/dev/null
run_life "$home" 2026-09-16T11:13:00Z delivery-complete rollback-task --evidence "deployed" >/dev/null
run_life "$home" 2026-09-16T11:14:00Z monitoring-start rollback-task >/dev/null
run_life "$home" 2026-09-16T11:15:00Z return-to-work rollback-task --reason "rollback after elevated errors" >/dev/null
row=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$TASKS" --json rollback-task)
printf '%s\n' "$row" | jq -e '
  .[0].status == "working" and .[0].lifecycle.acceptance == null
  and .[0].lifecycle.correction.from == "monitoring"
  and .[0].lifecycle.correction.reason == "rollback after elevated errors"
' >/dev/null || fail "monitoring problem did not return to working: $row"
pass "monitoring rollback returns to working and requires fresh acceptance"

# Durable post-review evidence remains closable if bounded backlog retention moved its Done row first.
add_done "$home" retained-task "Retained post-review task"
run_life "$home" 2026-09-16T11:20:00Z review-start retained-task >/dev/null
run_life "$home" 2026-09-16T11:21:00Z accept retained-task --actor reviewer --evidence "retained result accepted" --route close >/dev/null
retained_ref=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$TASKS" --json retained-task | jq -r '.[0].ref')
FM_HOME="$home" "$AXI" rm retained-task >/dev/null || fail "could not simulate bounded Done rotation"
retained_detail=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-task.sh" --json "$retained_ref") \
  || fail "retained post-review task was not addressable"
printf '%s\n' "$retained_detail" | jq -e '
  .id == "retained-task" and .status == "accepted" and .closeReady == true
  and .acceptance.evidence == "retained result accepted"
' >/dev/null || fail "retained detail lost acceptance evidence: $retained_detail"
FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$CLOSE" "$retained_ref" >/dev/null \
  || fail "retained post-review task could not close"
retained_history=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$HISTORY" --json retained-task)
printf '%s\n' "$retained_history" | jq -e '.[0].lifecycle.acceptance.evidence == "retained result accepted"' >/dev/null \
  || fail "retained close lost acceptance evidence: $retained_history"
pass "post-review records retain task detail, callsign, and guarded closure after Done rotation"

# One explicit close may combine acceptance only onto route close.
add_done "$home" combined-task "Explicit combined close"
FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TASK_LIFECYCLE_NOW=2026-09-16T12:00:00Z \
  "$CLOSE" --accept-close --actor captain --evidence "explicit close command" --limitations "report-only result" combined-task >/dev/null \
  || fail "explicit combined acceptance and close failed"
combined=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$HISTORY" --json combined-task)
printf '%s\n' "$combined" | jq -e '
  .[0].lifecycle.stage == "accepted"
  and .[0].lifecycle.acceptance.actor == "captain"
  and .[0].lifecycle.acceptance.evidence == "explicit close command"
  and .[0].lifecycle.acceptance.limitations == "report-only result"
  and .[0].lifecycle.acceptance.route == "close"
' >/dev/null || fail "combined close did not archive explicit acceptance: $combined"
pass "explicit close can atomically accept only the close route"

# Captain action, external wait, blocker, and failure evidence outrank a stored phase.
precedence="$TMP_ROOT/precedence"
mkdir -p "$precedence/task-lifecycle"
for id in need wait block fail; do
  cat > "$precedence/task-lifecycle/$id.json" <<EOF
{"version":1,"id":"$id","stage":"accepted","updatedAt":"2026-09-16T12:00:00Z","review":{"startedAt":"2026-09-16T11:00:00Z","completedAt":"2026-09-16T12:00:00Z"},"acceptance":{"actor":"reviewer","at":"2026-09-16T12:00:00Z","evidence":"passed","limitations":"none declared","route":"close"},"delivery":null,"monitoring":null,"correction":null}
EOF
done
snapshot="$TMP_ROOT/precedence.json"
cat > "$snapshot" <<'JSON'
{"schema":"fm-fleet-snapshot.v1","generated":"2026-09-16T12:30:00Z","backlog":{"records":[
{"structured":true,"id":"need","title":"Need action","state":"done","kind":"ship","captain_actionable":true,"hold_kind":"captain","hold_reason":"approve production","unresolved_blocker_ids":["dependency"]},
{"structured":true,"id":"wait","title":"Wait external","state":"done","kind":"ship","hold_kind":"external","hold_reason":"vendor window","unresolved_blocker_ids":[]},
{"structured":true,"id":"block","title":"Blocked task","state":"done","kind":"ship","unresolved_blocker_ids":["dependency"]},
{"structured":true,"id":"fail","title":"Failed task","state":"done","kind":"ship","unresolved_blocker_ids":[]},
{"structured":true,"id":"legacy-done","title":"Legacy done","state":"done","kind":"ship","unresolved_blocker_ids":[]}
]},"tasks":[{"id":"fail","current_state":{"state":"failed","detail":"attempt failed"},"hints":{}}],"secondmate_current":{"records":[]}}
JSON
projection=$(FM_DATA_OVERRIDE="$precedence" "$LIFE" project --snapshot "$snapshot" --callsigns-json '[]') || fail "precedence projection failed"
printf '%s\n' "$projection" | jq -e '
  (map({key:.id,value:.status}) | from_entries) == {
    need:"needs-you",wait:"waiting",block:"blocked",fail:"failed","legacy-done":"done"
  }
  and (.[] | select(.id == "need") | .close_ready) == false
  and (.[] | select(.id == "legacy-done") | .lifecycle) == null
' >/dev/null || fail "status precedence or migration honesty changed: $projection"
pass "status precedence preserves exact captain action, wait, blocker, failure, and legacy Done meaning"

# Legacy history stays readable without invented acceptance.
legacy="$home/data/closed-tasks/legacy-task"
mkdir -p "$legacy"
cat > "$legacy/closure.json" <<'JSON'
{"version":1,"disposition":"closed","id":"legacy-task","ref":"t9","name":"legacy-task-name","project":"sample","kind":"ship","dates":{"created":null,"started":null,"completed":"2026-01-01","closed":"2026-01-02T00:00:00Z"},"closedEpoch":1767312000,"result":"legacy result","artifacts":[],"retainedKnowledge":[],"followUps":[],"archive":"data/closed-tasks/legacy-task"}
JSON
legacy_json=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$HISTORY" --json legacy-task)
printf '%s\n' "$legacy_json" | jq -e '.[0].version == 1 and .[0].lifecycle == null' >/dev/null \
  || fail "legacy closure acquired inferred acceptance: $legacy_json"
legacy_text=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$HISTORY" legacy-task)
assert_contains "$legacy_text" "acceptance not recorded" "legacy text did not disclose missing acceptance"
pass "legacy closure migration remains readable without false acceptance"

echo "# all fm-task-lifecycle tests passed"
