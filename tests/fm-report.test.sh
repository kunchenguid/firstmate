#!/usr/bin/env bash
# Deterministic fixture tests for the durable Markdown fleet report.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/fm-report.sh"
TICK='`'
TMP_ROOT=$(fm_test_tmproot fm-report)
FIXTURE="$TMP_ROOT/fixture"
mkdir -p "$FIXTURE"

cat > "$FIXTURE/snapshot.json" <<'JSON'
{
  "schema":"fm-bearings.v1",
  "decisions_open":[{"id":"remote-call","summary":"Choose the remote rollout"}],
  "contributions":{"captain":[]},
  "in_flight":[{"id":"mate/remote-work","name":"Remote maintenance","state":"working","doing":"Updating the remote host"}],
  "gates":[{"id":"later-gate","title":"Scheduled migration","reason":"until 2026-10-01"}]
}
JSON
cat > "$FIXTURE/lifecycle.json" <<'JSON'
[
  {"id":"need","ref":"t1","name":"Unblock release","status":"needs-you","outcome":"Approve the production credential","next_action":"Provide the credential","route":null,"close_ready":false,"lifecycle":null},
  {"id":"work","ref":"t2","name":"Active implementation","status":"working","outcome":"Regression test is being added","next_action":"Continue the current work","route":null,"close_ready":false,"lifecycle":null},
  {"id":"candidate","ref":"t3","name":"Candidate feature","status":"done","outcome":"Branch is ready","next_action":"Start review","route":null,"close_ready":false,"lifecycle":null},
  {"id":"old-subtask","ref":"t10","name":"Old implementation slice","status":"done","outcome":"Superseded slice","next_action":"Start review","route":null,"close_ready":false,"lifecycle":null,"superseded_by":"candidate"},
  {"id":"review","ref":"t4","name":"Review active","status":"reviewing","outcome":"Review in progress","next_action":"Accept or return","route":null,"close_ready":false,"lifecycle":{"review":{"startedAt":"2026-09-16T10:00:00Z"},"acceptance":null}},
  {"id":"accepted","ref":"t5","name":"Accepted release","status":"accepted","outcome":"Accepted for delivery","next_action":"Start the selected delivery route","route":"deliver","close_ready":false,"lifecycle":{"acceptance":{"actor":"reviewer","at":"2026-09-16T11:00:00Z","evidence":"review passed","route":"deliver"},"delivery":null}},
  {"id":"delivery","ref":"t6","name":"Delivery active","status":"delivering","outcome":"Delivery in progress","next_action":"Complete delivery","route":"deliver-monitor","close_ready":false,"lifecycle":{"acceptance":{"actor":"reviewer","at":"2026-09-16T11:10:00Z","evidence":"release approved","route":"deliver-monitor"},"delivery":{"startedAt":"2026-09-16T11:20:00Z","completedAt":null}}},
  {"id":"monitor","ref":"t7","name":"Monitoring active","status":"monitoring","outcome":"Post-delivery monitoring in progress","next_action":"Complete monitoring","route":"deliver-monitor","close_ready":false,"lifecycle":{"acceptance":{"actor":"reviewer","at":"2026-09-16T11:30:00Z","evidence":"deployment approved","route":"deliver-monitor"},"delivery":{"completedAt":"2026-09-16T11:40:00Z"},"monitoring":{"startedAt":"2026-09-16T11:41:00Z","completedAt":null}}},
  {"id":"closable","ref":"t8","name":"Closable result","status":"accepted","outcome":"Accepted for closure","next_action":"Close the accepted task","route":"close","close_ready":true,"lifecycle":{"acceptance":{"actor":"reviewer","at":"2026-09-16T12:00:00Z","evidence":"report accepted","route":"close"}}},
  {"id":"queued","ref":"t9","name":"Queued follow-up","status":"queued","outcome":"Authorized; not started","next_action":"Start authorized work","route":null,"close_ready":false,"lifecycle":null}
]
JSON
cat > "$FIXTURE/history.json" <<'JSON'
[
  {"version":2,"disposition":"closed","id":"closed-one","ref":"t12","name":"Closed migration","dates":{"closed":"2026-09-15T09:00:00Z"},"result":"Migration shipped","lifecycle":{"acceptance":{"route":"deliver"}}}
]
JSON

out=$("$REPORT" --command report --snapshot "$FIXTURE/snapshot.json" --lifecycle "$FIXTURE/lifecycle.json" --history "$FIXTURE/history.json") \
  || fail "full report fixture failed"
for heading in \
  '## Captain decisions and actions' \
  '## Work under way' \
  '## Done and ready for review' \
  '## Accepted work in delivery or monitoring' \
  '## Recently completed and closed' \
  '## Charted next' \
  '## Recommendations'; do
  assert_contains "$out" "$heading" "report omitted lifecycle section $heading"
done
assert_contains "$out" '| t3, t10 | Candidate feature | Branch is ready |' "superseded implementation rows were not consolidated under the actionable result"
assert_not_contains "$out" '| t10 | Old implementation slice |' "superseded implementation row was listed separately"
assert_contains "$out" '| t12 | Closed migration | 2026-09-15T09:00:00Z | Migration shipped | deliver |' "closed lifecycle evidence was not rendered"
assert_contains "$out" "${TICK}/t t1${TICK} - Provide the credential" "captain action lost its exact task reference"
assert_contains "$out" "${TICK}/task-lifecycle delivery-start t5${TICK}" "accepted delivery lost its exact transition"
assert_contains "$out" "${TICK}/task-lifecycle monitoring-complete t7 --evidence <monitoring evidence>${TICK}" "monitoring recommendation lost its exact transition"
assert_not_contains "$out" "${TICK}/close t8${TICK}" "closure was recommended while forward work could still move"

need_line=$(printf '%s\n' "$out" | grep -n '\*\*Unblock release\*\*' | cut -d: -f1)
done_line=$(printf '%s\n' "$out" | grep -n '\*\*Candidate feature\*\*' | cut -d: -f1)
delivery_line=$(printf '%s\n' "$out" | grep -n '\*\*Accepted release\*\*' | cut -d: -f1)
[ -n "$need_line" ] && [ -n "$done_line" ] && [ -n "$delivery_line" ] \
  && [ "$need_line" -lt "$done_line" ] && [ "$done_line" -lt "$delivery_line" ] \
  || fail "recommendations were not ordered unblock, review, delivery"
pass "full lifecycle sections, recommendation order, consolidation, and actionable references render deterministically"

# Every Markdown table must have the same number of pipe delimiters on all rows
# until its following blank line.
printf '%s\n' "$out" | awk '
  /^\|/ {
    pipes=gsub(/\|/, "&")
    if (!inside) { expected=pipes; inside=1 }
    if (pipes != expected) exit 1
    next
  }
  { inside=0 }
' || fail "report emitted an invalid Markdown table"
pass "all report tables have valid aligned Markdown columns"

cat > "$FIXTURE/empty-snapshot.json" <<'JSON'
{"schema":"fm-bearings.v1","decisions_open":[],"contributions":{"captain":[]},"in_flight":[],"gates":[]}
JSON
printf '[]\n' > "$FIXTURE/empty.json"
empty=$("$REPORT" --command report --snapshot "$FIXTURE/empty-snapshot.json" --lifecycle "$FIXTURE/empty.json" --history "$FIXTURE/empty.json") \
  || fail "empty report fixture failed"
assert_contains "$empty" '| Nothing is under way | - | - | - |' "empty underway section was not explicit"
assert_contains "$empty" '| No accepted work is in delivery or monitoring | - | - | - | - |' "empty accepted section was not explicit"
assert_contains "$empty" 'No captain action is needed right now.' "empty report did not state that no captain action is needed"
report_alias=$("$REPORT" --command bearings --snapshot "$FIXTURE/empty-snapshot.json" --lifecycle "$FIXTURE/empty.json" --history "$FIXTURE/empty.json") \
  || fail "bearings compatibility route failed"
[ "$empty" = "$report_alias" ] || fail "/bearings compatibility output diverged from /report"
pass "empty sections, no-action output, and /bearings parity share one formatter"

cat > "$FIXTURE/closure-lifecycle.json" <<'JSON'
[
  {"id":"close-only","ref":"t2","name":"Accepted report","status":"accepted","outcome":"Accepted for closure","next_action":"Close the accepted task","route":"close","close_ready":true,"lifecycle":{"acceptance":{"actor":"reviewer","at":"2026-09-16T12:00:00Z","evidence":"report accepted","route":"close"}}}
]
JSON
closure=$("$REPORT" --snapshot "$FIXTURE/empty-snapshot.json" --lifecycle "$FIXTURE/closure-lifecycle.json" --history "$FIXTURE/empty.json") \
  || fail "closure-only report fixture failed"
assert_contains "$closure" "Action: Run ${TICK}/t t2${TICK}, then ${TICK}/close t2${TICK}." "closure was not recommended when no forward work remained"
pass "accepted closure is recommended only after forward work is exhausted"

echo "# all fm-report tests passed"
