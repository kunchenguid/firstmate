#!/usr/bin/env bash
# Behavior tests for the bounded, privacy-safe local task observability collector.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-observe)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
WT="$TMP_ROOT/worktree"
PROJECT="$TMP_ROOT/project"
PI_SESSIONS="$TMP_ROOT/pi-sessions"
NM_DB="$TMP_ROOT/no-mistakes.sqlite"
COLLECTOR="$ROOT/bin/fm-observe.py"
STATUS="$ROOT/bin/fm-status.sh"
mkdir -p "$STATE" "$DATA" "$PI_SESSIONS/session-dir"
mkdir -p "$PROJECT"

fm_git_init_commit "$WT"
BASE=$(git -C "$WT" rev-parse HEAD)
printf 'observability fixture\n' > "$WT/fixture.txt"
git -C "$WT" add fixture.txt
git -C "$WT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm $'fixture task commit\n\nTask-Id: observe-feature'
HEAD=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" branch -M fm/observe-feature

cat > "$STATE/observe-feature.meta" <<EOF
task_id=observe-feature
run_id=observe-feature-20260101T000000Z-42
session_id=observe-feature-20260101T000000Z-42-s1
started_at=2026-01-01T00:00:00Z
status_start_line=1
base_commit=$BASE
window=firstmate:fm-observe-feature
worktree=$WT
project=$PROJECT
harness=pi
kind=ship
mode=no-mistakes
yolo=off
model=openai-codex/test-model
effort=high
EOF

mkdir -p "$PI_SESSIONS/no-mistakes" "$PI_SESSIONS/reused-worktree"
cat > "$PI_SESSIONS/no-mistakes/session.jsonl" <<EOF
{"type":"session","version":3,"id":"pi-no-mistakes","timestamp":"2026-01-01T00:02:00Z","cwd":"$WT"}
{"type":"message","timestamp":"2026-01-01T00:02:01Z","message":{"role":"assistant","usage":{"input":999,"output":999,"totalTokens":1998}}}
EOF
cat > "$PI_SESSIONS/reused-worktree/session.jsonl" <<EOF
{"type":"session","version":3,"id":"pi-later-run","timestamp":"2026-01-01T00:10:00Z","cwd":"$WT"}
{"type":"message","timestamp":"2026-01-01T00:10:01Z","message":{"role":"assistant","usage":{"input":777,"output":777,"totalTokens":1554}}}
EOF
printf 'done: old run must not be attributed\n' > "$STATE/observe-feature.status"
for spec in \
  '2026-01-01T00:01:00Z working implementing' \
  '2026-01-01T00:02:00Z needs-decision choose' \
  '2026-01-01T00:02:30Z needs-decision reminder' \
  '2026-01-01T00:03:00Z resolved chosen' \
  '2026-01-01T00:04:00Z done complete'; do
  IFS=' ' read -r stamp verb note <<EOF
$spec
EOF
  FM_HOME="$HOME_DIR" FM_STATUS_NOW=$stamp \
    FM_RUN_ID=observe-feature-20260101T000000Z-42 \
    FM_SESSION_ID=observe-feature-20260101T000000Z-42-s1 \
    "$STATUS" observe-feature "$verb" "$note" || fail "could not write fixture status $verb"
done

cat > "$PI_SESSIONS/session-dir/session.jsonl" <<EOF
{"type":"session","version":3,"id":"pi-native-session","timestamp":"2026-01-01T00:00:30Z","cwd":"$WT"}
{"type":"model_change","id":"m1","timestamp":"2026-01-01T00:00:31Z","provider":"openai-codex","modelId":"test-model"}
{"type":"message","id":"u1","timestamp":"2026-01-01T00:00:32Z","message":{"role":"user","content":"SECRET_PROMPT_MUST_NOT_ENTER_DB"}}
{"type":"message","id":"a1","timestamp":"2026-01-01T00:01:30Z","message":{"role":"assistant","content":[{"type":"text","text":"SECRET_RESPONSE_MUST_NOT_ENTER_DB"}],"model":"test-model","usage":{"input":10,"output":5,"cacheRead":2,"cacheWrite":0,"reasoning":1,"totalTokens":17,"cost":{"total":0.42}}}}
{"type":"message","id":"t1","timestamp":"2026-01-01T00:01:31Z","message":{"role":"toolResult","content":"SECRET_COMMAND_OUTPUT_MUST_NOT_ENTER_DB"}}
EOF

python3 - "$NM_DB" "$WT" <<'PY'
import json, sqlite3, sys
path, project = sys.argv[1:]
c = sqlite3.connect(path)
c.executescript('''
CREATE TABLE repos(id TEXT PRIMARY KEY, working_path TEXT);
CREATE TABLE runs(id TEXT PRIMARY KEY, repo_id TEXT, branch TEXT, status TEXT,
  pr_url TEXT, pr_state TEXT, created_at INTEGER, updated_at INTEGER);
CREATE TABLE agent_invocations(run_id TEXT, input_tokens INTEGER, output_tokens INTEGER,
  cache_read_tokens INTEGER, cache_creation_tokens INTEGER, reasoning_tokens INTEGER,
  model_roundtrips INTEGER, started_at INTEGER, completed_at INTEGER, model TEXT);
CREATE TABLE step_results(id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT, log_path TEXT);
CREATE TABLE step_rounds(step_result_id TEXT, round INTEGER, trigger_type TEXT,
  findings_json TEXT, user_findings_json TEXT);
''')
c.execute('INSERT INTO repos VALUES(?,?)', ('repo-1', project))
c.execute('INSERT INTO runs VALUES(?,?,?,?,?,?,?,?)', (
  '01NMOBSERVE', 'repo-1', 'fm/observe-feature', 'completed',
  'https://example.invalid/pull/7', 'merged', 1767225660, 1767225900))
c.execute('INSERT INTO agent_invocations VALUES(?,?,?,?,?,?,?,?,?,?)', (
  '01NMOBSERVE', 100, 20, 30, 4, 6, 3, 1767225700, 1767225800, 'review-model'))
log = '/tmp/no-mistakes/01NMOBSERVE/review.log'
c.execute('INSERT INTO step_results VALUES(?,?,?,?)', ('step-review', '01NMOBSERVE', 'review', log))
initial = json.dumps({'findings':[{'id':'Q1','severity':'medium','description':'SECRET_FINDING_DESCRIPTION'}]})
clean = json.dumps({'findings':[]})
c.execute('INSERT INTO step_rounds VALUES(?,?,?,?,?)', ('step-review', 1, 'initial', initial, None))
c.execute('INSERT INTO step_rounds VALUES(?,?,?,?,?)', ('step-review', 2, 'auto_fix', clean, None))
c.commit()
PY

run_collect() {
  FM_HOME="$HOME_DIR" FM_PI_SESSIONS="$PI_SESSIONS" FM_NO_MISTAKES_DB="$NM_DB" \
    "$COLLECTOR" collect --task observe-feature
}

out=$(run_collect) || fail "collector failed: $out"
assert_contains "$out" "collected: 1 runs" "collector did not report one run"
assert_present "$DATA/observability.sqlite3" "collector did not create SQLite store"
assert_present "$DATA/observability.html" "collector did not create static dashboard"
if [ "$(uname)" = Darwin ]; then
  db_mode=$(stat -f %Lp "$DATA/observability.sqlite3")
  html_mode=$(stat -f %Lp "$DATA/observability.html")
else
  db_mode=$(stat -c %a "$DATA/observability.sqlite3")
  html_mode=$(stat -c %a "$DATA/observability.html")
fi
[ "$db_mode" = 600 ] && [ "$html_mode" = 600 ] \
  || fail "observability outputs must be private (db=$db_mode html=$html_mode)"

if ! python3 - "$DATA/observability.sqlite3" "$BASE" "$HEAD" <<'PY'
import sqlite3, sys
path, base, head = sys.argv[1:]
c = sqlite3.connect(path)
c.row_factory = sqlite3.Row
r = c.execute('SELECT * FROM runs').fetchone()
assert r['task_id'] == 'observe-feature', dict(r)
assert r['run_id'] == 'observe-feature-20260101T000000Z-42', dict(r)
assert r['session_id'].endswith('-s1'), dict(r)
assert r['base_commit_ref'] == base, dict(r)
assert r['commit_ref'] == head, dict(r)
assert r['outcome'] == 'landed', dict(r)
assert r['runtime'] == 'tmux' and r['effort'] == 'high', dict(r)
assert r['tokens_input'] == 110 and r['tokens_output'] == 25, dict(r)
assert r['tokens_cache_read'] == 32 and r['tokens_cache_write'] == 4, dict(r)
assert r['tokens_total'] == 171, dict(r)
assert abs(r['cost_usd'] - 0.42) < 0.00001, dict(r)
assert r['intervention_count'] == 2 and r['wait_seconds'] == 60, dict(r)
assert r['first_pass_quality'] == 0, dict(r)
assert r['quality_findings'] == 1 and r['quality_unresolved'] == 0, dict(r)
assert c.execute('SELECT COUNT(*) FROM sessions').fetchone()[0] == 2
event_rows = [tuple(row) for row in c.execute('SELECT state,observed_at,source_line FROM events ORDER BY source_line')]
assert len(event_rows) == 5, event_rows
assert c.execute("SELECT COUNT(*) FROM evidence WHERE kind='commit' AND ref=?", (head,)).fetchone()[0] == 1
assert tuple(c.execute('SELECT finding_id,severity,resolved FROM quality_findings').fetchone()) == ('Q1','medium',1)
assert set(row[0] for row in c.execute("SELECT name FROM sqlite_master WHERE type='table'")) >= {
  'runs','events','sessions','quality_findings','evidence'}
assert c.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name LIKE '%entire%'").fetchone()[0] == 0
PY
then
  fail "collector database assertions failed"
fi
pass "fm-observe: correlates task, run, session, commits, lifecycle, quality, and usage"

run_collect >/dev/null || fail "idempotent second collection failed"
if ! python3 - "$DATA/observability.sqlite3" <<'PY'
import sqlite3, sys
c=sqlite3.connect(sys.argv[1])
assert c.execute('SELECT COUNT(*) FROM runs').fetchone()[0] == 1
assert c.execute('SELECT COUNT(*) FROM events').fetchone()[0] == 5
assert c.execute('SELECT COUNT(*) FROM sessions').fetchone()[0] == 2
assert c.execute('SELECT COUNT(*) FROM quality_findings').fetchone()[0] == 1
PY
then
  fail "idempotent database assertions failed"
fi
pass "fm-observe: repeated collection is idempotent"

mv "$NM_DB" "$NM_DB.unavailable"
run_collect >/dev/null || fail "collection without no-mistakes database failed"
if ! python3 - "$DATA/observability.sqlite3" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
r = c.execute("""SELECT first_pass_quality,no_mistakes_runs,retries,outcome,
                        quality_findings,quality_unresolved
                   FROM runs WHERE task_id='observe-feature'""").fetchone()
assert r == (0, 1, 0, 'landed', 1, 0), r
assert c.execute("SELECT COUNT(*) FROM sessions WHERE source='no-mistakes'").fetchone()[0] == 1
assert c.execute("SELECT COUNT(*) FROM evidence WHERE kind='no-mistakes-run'").fetchone()[0] == 1
PY
then
  fail "unavailable no-mistakes database erased reconciled lifecycle state"
fi
mv "$NM_DB.unavailable" "$NM_DB"
pass "fm-observe: unavailable quality evidence preserves reconciled lifecycle state"

python3 - "$STATE/observe-feature.status" <<'PY'
import sys
path = sys.argv[1]
with open(path, 'ab') as handle:
    for index in range(20000):
        handle.write(f"working: old-{index} [run=old-run] [at=2026-01-01T00:00:00Z]\n".encode())
    handle.write(b"needs-decision: uncorrelated [at=2026-01-01T00:05:00Z]\n")
    handle.write(b"working: current [run=observe-feature-20260101T000000Z-42] [at=2026-01-01T00:06:00Z]\n")
PY
run_collect >/dev/null || fail "truncated status collection failed"
events_after_tail=$(python3 - "$DATA/observability.sqlite3" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
assert c.execute("SELECT COUNT(*) FROM events WHERE state='needs-decision'").fetchone()[0] == 2
assert c.execute("SELECT COUNT(*) FROM events WHERE observed_at=1767225960").fetchone()[0] == 1
print(c.execute('SELECT COUNT(*) FROM events').fetchone()[0])
PY
) || fail "truncated status boundary assertions failed"
printf 'done: appended [run=observe-feature-20260101T000000Z-42] [at=2026-01-01T00:07:00Z]\n' >> "$STATE/observe-feature.status"
run_collect >/dev/null || fail "growing truncated status collection failed"
if ! python3 - "$DATA/observability.sqlite3" "$events_after_tail" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
before = int(sys.argv[2])
assert c.execute('SELECT COUNT(*) FROM events').fetchone()[0] == before + 1
PY
then
  fail "truncated status append duplicated existing events"
fi
pass "fm-observe: truncated status tails remain bounded, correlated, and idempotent"

python3 - "$NM_DB" "$WT" <<'PY'
import sqlite3, sys
path, project = sys.argv[1:]
c = sqlite3.connect(path)
for index in range(60):
    run_id = f'01NMNEW{index:02d}'
    status = 'completed' if index == 59 else 'failed'
    c.execute('INSERT INTO runs VALUES(?,?,?,?,?,?,?,?)', (
        run_id, 'repo-1', 'fm/observe-feature', status, None, None,
        1767226000 + index, 1767226000 + index))
c.execute('INSERT INTO repos VALUES(?,?)', ('repo-2', project + '/other'))
for index in range(60):
    c.execute('INSERT INTO runs VALUES(?,?,?,?,?,?,?,?)', (
        f'01NMOTHER{index:02d}', 'repo-2', 'fm/observe-feature', 'failed', None, None,
        1767227000 + index, 1767227000 + index))
c.commit()
PY
run_collect >/dev/null || fail "newest no-mistakes collection failed"
if ! python3 - "$DATA/observability.sqlite3" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
r = c.execute("""SELECT no_mistakes_runs,outcome,first_pass_quality,
                        tokens_input,tokens_output,quality_findings
                   FROM runs WHERE task_id='observe-feature'""").fetchone()
assert r == (50, 'completed', 0, 10, 5, 0), r
assert c.execute("SELECT COUNT(*) FROM sessions WHERE source='no-mistakes'").fetchone()[0] == 0
assert c.execute("SELECT COUNT(*) FROM quality_findings").fetchone()[0] == 0
refs = [row[0] for row in c.execute("SELECT ref FROM evidence WHERE kind='no-mistakes-run'")]
assert 'no-mistakes://run/01NMOBSERVE' not in refs
assert 'no-mistakes://run/01NMNEW59' in refs
assert 'no-mistakes://run/01NMNEW09' not in refs
assert not any('OTHER' in ref for ref in refs)
assert c.execute("SELECT COUNT(*) FROM evidence WHERE kind LIKE 'no-mistakes-%' OR kind='quality-log'").fetchone()[0] == 50
assert c.execute("SELECT COUNT(*) FROM evidence WHERE kind='no-mistakes-session'").fetchone()[0] == 0
PY
then
  fail "newest no-mistakes ordering and limit assertions failed"
fi
pass "fm-observe: no-mistakes window preserves first pass and reconciles derived detail"

for secret in SECRET_PROMPT_MUST_NOT_ENTER_DB SECRET_RESPONSE_MUST_NOT_ENTER_DB SECRET_COMMAND_OUTPUT_MUST_NOT_ENTER_DB SECRET_FINDING_DESCRIPTION; do
  if grep -aF "$secret" "$DATA/observability.sqlite3" >/dev/null; then
    fail "privacy violation: SQLite contains $secret"
  fi
done
pass "fm-observe: SQLite excludes prompt, response, command output, and finding prose"

assert_grep 'Known cost / success' "$DATA/observability.html" "dashboard missing cost-per-success view"
assert_grep 'Median duration' "$DATA/observability.html" "dashboard missing duration view"
assert_grep 'First-pass quality' "$DATA/observability.html" "dashboard missing quality view"
assert_grep 'Model × task class' "$DATA/observability.html" "dashboard missing model comparison"
assert_grep '<th>n</th>' "$DATA/observability.html" "dashboard comparison missing sample size"
pass "fm-observe: static dashboard covers the pilot decision metrics with sample size"

python3 - "$DATA/observability.sqlite3" <<'PY'
import sqlite3, sys, time
c=sqlite3.connect(sys.argv[1])
old=int(time.time())-3*86400
c.execute('''INSERT INTO runs(run_id,task_id,task_class,started_at,last_seen_at,ended_at,outcome)
VALUES('old-run','old-task','ship',?,?,?,'failed')''',(old,old,old))
c.commit()
PY
FM_HOME="$HOME_DIR" "$COLLECTOR" prune --retention-days 1 >/dev/null || fail "explicit prune failed"
remaining=$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT COUNT(*) FROM runs WHERE run_id=\"old-run\"").fetchone()[0])' "$DATA/observability.sqlite3")
[ "$remaining" = 0 ] || fail "retention did not delete an expired terminal run"
pass "fm-observe: retention is bounded and explicit prune is reversible local maintenance"

# shellcheck disable=SC2016 # The grep pattern must preserve the literal variable reference.
assert_grep '[ -f "$CONFIG/observability" ]' "$ROOT/bin/fm-teardown.sh" \
  "teardown did not keep scheduled collection behind the explicit local presence flag"
# shellcheck disable=SC2016 # The grep pattern must preserve the literal variable reference.
assert_grep 'fm-observe.py" collect --task "$ID"' "$ROOT/bin/fm-teardown.sh" \
  "teardown did not collect the exact task before cleanup"
assert_grep 'config/observability' "$ROOT/.gitignore" \
  "the local scheduling opt-in must remain gitignored"
pass "fm-observe: scheduled collection is explicit local opt-in only"

echo "# all fm-observe tests passed"
