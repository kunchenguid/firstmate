#!/usr/bin/env bash
# Behavior tests for bin/fm-pipeline-spend.sh: a task's no-mistakes pipeline
# spend reaches Firstmate's own records, attributed to the task, through the
# script's public show and record commands. Each case seeds a real SQLite state
# database shaped like no-mistakes' own (repos, runs, agent_invocations) under
# a private NM_HOME, a real git task copy whose branch reflog starts at a known
# time, and a fake no-mistakes CLI that only names the resolved repository.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity
TMP_ROOT=$(fm_test_tmproot fm-pipeline-spend)
SPEND="$ROOT/bin/fm-pipeline-spend.sh"
NOW=$(date +%s)
# The task branch is created well in the past so run timestamps can sit on
# either side of it; spawn_gen is minted later, as a relaunch would.
BRANCH_EPOCH=$((NOW - 100000))
SPAWN_EPOCH=$((BRANCH_EPOCH + 5000))
BRANCH_ISO=$(TZ=UTC0 date -d "@$BRANCH_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || TZ=UTC0 date -r "$BRANCH_EPOCH" +%Y-%m-%dT%H:%M:%SZ)

# make_case <name>: echo a case dir holding a Firstmate home (home/state,
# home/data), a project clone, a task copy (wt) on branch fm/task created at
# BRANCH_EPOCH, the task's meta, an empty NM_HOME (nm), and a fake
# no-mistakes whose `axi` prints `repo: $FAKE_NM_REPO`, or the CLI's
# uninitialized-repository error when FAKE_NM_REPO is empty.
make_case() {
  local d=$TMP_ROOT/$1
  mkdir -p "$d/home/state" "$d/home/data" "$d/nm" "$d/fakebin"
  fm_git_init_commit "$d/project"
  GIT_COMMITTER_DATE="@$BRANCH_EPOCH +0000" git -C "$d/project" worktree add -q -b fm/task "$d/wt"
  fm_write_meta "$d/home/state/task.meta" \
    "window=firstmate:fm-task" \
    "endpoint_task_id=task" \
    "worktree=$d/wt" \
    "project=$d/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=s$SPAWN_EPOCH.1.abc"
  cat > "$d/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "$*" = axi ] || exit 1
if [ -n "${FAKE_NM_REPO:-}" ]; then
  printf 'bin: no-mistakes\nrepo: %s\ncurrent_branch: fm/task\n' "$FAKE_NM_REPO"
  exit 0
fi
printf "error: repo not initialized (run 'no-mistakes init' first)\n"
printf 'help[1]: Run `no-mistakes init` to set up the gate in this repository\n'
exit 1
SH
  chmod +x "$d/fakebin/no-mistakes"
  printf '%s\n' "$d"
}

# seed_db <case-dir> <current|pre-delta|no-invocations>: build nm/state.sqlite
# from stdin rows, "-" meaning NULL and times given as offsets from
# BRANCH_EPOCH:
#   repo <id> <working_path>
#   run <id> <repo-id> <branch> <status> <created-offset>
#   inv <run-id> <purpose> <session_mode> <exit> <duration_ms> <in> <out> <cache_read> <cache_creation> <d_in> <d_out> <d_cache_read>
# current carries today's columns, pre-delta the original table from before
# no-mistakes added the delta columns, and no-invocations no table at all.
seed_db() {
  SEED_ROWS=$(cat) python3 - "$1/nm/state.sqlite" "$2" "$BRANCH_EPOCH" <<'PY'
import os
import sqlite3
import sys

database, schema, base = sys.argv[1], sys.argv[2], int(sys.argv[3])
db = sqlite3.connect(database)
db.executescript("""
    CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
    CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                       status TEXT NOT NULL, created_at INTEGER NOT NULL);
""")
tokens = ["input_tokens", "output_tokens", "cache_read_tokens", "cache_creation_tokens"]
deltas = ["delta_input_tokens", "delta_output_tokens", "delta_cache_read_tokens"]
columns = ["id", "run_id", "step_name", "round", "purpose", "agent", "session_mode",
           "started_at", "completed_at", "duration_ms", "exit_status"] + tokens
if schema == "current":
    columns += ["reasoning_tokens"] + deltas
if schema != "no-invocations":
    db.execute("CREATE TABLE agent_invocations (%s)" % ", ".join(columns))
value = lambda v: None if v == "-" else int(v)
for n, line in enumerate(os.environ["SEED_ROWS"].splitlines()):
    f = line.split()
    if not f:
        continue
    if f[0] == "repo":
        db.execute("INSERT INTO repos VALUES (?, ?)", (f[1], f[2]))
    elif f[0] == "run":
        db.execute("INSERT INTO runs VALUES (?, ?, ?, ?, ?)", (f[1], f[2], f[3], f[4], base + int(f[5])))
    elif f[0] == "inv":
        row = {"id": "inv%03d" % n, "run_id": f[1], "step_name": f[2], "round": 1, "purpose": f[2],
               "agent": "fake", "session_mode": f[3], "started_at": base + n, "completed_at": base + n,
               "duration_ms": int(f[5]), "exit_status": f[4], "reasoning_tokens": 999}
        row.update(zip(tokens, map(value, f[6:10])))
        row.update(zip(deltas, map(value, f[10:13])))
        db.execute("INSERT INTO agent_invocations VALUES (%s)" % ", ".join("?" * len(columns)),
                   [row[c] for c in columns])
db.commit()
PY
}

# spend <case-dir> <show|record> [task-id]: run the script against the case's
# home, NM_HOME, and fake no-mistakes.
spend() {
  local d=$1
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$d/home" NM_HOME="$d/nm" \
    FAKE_NM_REPO="${FAKE_NM_REPO-$d/project}" PATH="$d/fakebin:$PATH" \
    "$SPEND" "$2" "${3:-task}"
}

field() {  # <json> <jq-filter>
  printf '%s\n' "$1" | jq -cS "$2"
}

test_known_spend_including_failed_and_cancelled_is_attributed_to_the_task() {
  local d out
  d=$(make_case known)
  seed_db "$d" current <<EOF
repo r1 $d/project
repo r2 $d/elsewhere
run early r1 fm/task completed -500
run first r1 fm/task failed 100
run second r1 fm/task completed 6000
run sibling r1 fm/other completed 200
run foreign r2 fm/task completed 300
inv early review cold ok 1000 1000 1000 1000 1000 1000 1000 1000
inv first review cold ok 100 10 20 30 40 10 20 30
inv first test cold error 50 1 2 3 4 1 2 3
inv first ci cold cancelled 70 - - - - - - -
inv second review cold ok 200 100 200 300 400 100 200 300
inv sibling review cold ok 1000 1000 1000 1000 1000 1000 1000 1000
inv foreign review cold ok 1000 1000 1000 1000 1000 1000 1000 1000
EOF
  out=$(spend "$d" show) || fail "show failed for a task with recorded spend"
  assert_equals '"no-mistakes-state"' "$(field "$out" .source)" 'known spend reads from the no-mistakes state'
  assert_equals "\"$d/project\"" "$(field "$out" .repo)" 'the repository is the one no-mistakes resolved'
  assert_equals '"fm/task"' "$(field "$out" .branch)" 'the branch is the task copy branch'
  assert_equals "\"$BRANCH_ISO\"" "$(field "$out" .since)" 'attribution starts when the task branch was created'
  assert_equals '"s'"$SPAWN_EPOCH"'.1.abc"' "$(field "$out" .spawn_gen)" 'the record names the task incarnation'
  # The run before the relaunch's spawn_gen still counts: spawn_gen is not the
  # task's start. A run before the branch existed, another branch's run, and
  # another repository's run on the same branch name never count.
  assert_equals '["first","second"]' "$(field "$out" '[.runs[].id]')" 'only the task runs are attributed'
  assert_equals '4' "$(field "$out" .total.invocations)" 'every invocation of the task runs counts'
  assert_equals '{"cancelled":1,"error":1,"ok":2}' "$(field "$out" '.total.exit')" \
    'failed and cancelled invocations count next to the ones that finished'
  assert_equals '420' "$(field "$out" .total.duration_ms)" 'invocation time is summed'
  assert_equals '{"total":111,"unknown":1}' "$(field "$out" .total.input_tokens)" \
    'input sums the recorded rounds and names the unrecorded one'
  assert_equals '{"total":222,"unknown":1}' "$(field "$out" .total.output_tokens)" 'output is summed'
  assert_equals '{"total":333,"unknown":1}' "$(field "$out" .total.cache_read_tokens)" 'cache reads are summed'
  assert_equals '{"total":444,"unknown":1}' "$(field "$out" .total.cache_creation_tokens)" 'cache writes are summed'
  assert_equals '{"cancelled":1,"error":1,"ok":1}' "$(field "$out" '.runs[0].exit')" 'each run carries its own tally'
  assert_equals '"failed"' "$(field "$out" '.runs[0].status')" 'each run carries its no-mistakes status'
  assert_equals '["ci","review","test"]' "$(field "$out" '[.purposes[].purpose]')" 'spend is broken down by pipeline purpose'
  assert_equals '{"total":110,"unknown":0}' "$(field "$out" '.purposes[] | select(.purpose == "review") | .input_tokens')" \
    'the review purpose sums its rounds across runs'
  assert_absent "$d/home/data/pipeline-spend.jsonl" 'show writes nothing'
  pass 'known spend, including failed and cancelled invocations, is attributed to the task that ran it'
}

test_repeated_review_rounds_in_a_resumed_session_are_not_double_counted() {
  local d out
  d=$(make_case resumed)
  # A session whose raw counters are cumulative across resumes (as codex
  # reports them): each raw counter includes every earlier round, and the
  # per-round delta is what that round actually spent.
  seed_db "$d" current <<EOF
repo r1 $d/project
run loop r1 fm/task completed 100
inv loop review started ok 10 100 10 50 - 100 10 50
inv loop review-fix resumed ok 10 250 25 120 - 150 15 70
inv loop review resumed ok 10 400 40 200 - 150 15 80
EOF
  out=$(spend "$d" show) || fail "show failed for a resumed review loop"
  assert_equals '{"total":400,"unknown":0}' "$(field "$out" .total.input_tokens)" \
    'three review rounds count 400 input tokens, not the 750 their cumulative counters add up to'
  assert_equals '{"total":40,"unknown":0}' "$(field "$out" .total.output_tokens)" 'output counts each round once'
  assert_equals '{"total":200,"unknown":0}' "$(field "$out" .total.cache_read_tokens)" 'cache reads count each round once'
  assert_equals '{"total":0,"unknown":3}' "$(field "$out" .total.cache_creation_tokens)" \
    'an agent that reports no cache writes leaves them unknown, not zero'

  # A resumed row whose deltas equal its raw counters proves per-invocation
  # counters, so its cache writes count; one whose deltas differ is
  # cumulative, so its cache writes are unknown rather than counted again.
  d=$(make_case resumed-cache)
  seed_db "$d" current <<EOF
repo r1 $d/project
run loop r1 fm/task completed 100
inv loop review started ok 10 5 6 7 8 5 6 7
inv loop review-fix resumed ok 10 5 6 7 8 5 6 7
inv loop review resumed ok 10 20 12 14 30 15 6 7
EOF
  out=$(spend "$d" show) || fail "show failed for resumed cache writes"
  assert_equals '{"total":16,"unknown":1}' "$(field "$out" .total.cache_creation_tokens)" \
    'cache writes count only where the counters are proven per-invocation'
  assert_equals '{"total":25,"unknown":0}' "$(field "$out" .total.input_tokens)" 'input still sums the per-round deltas'
  pass 'repeated review rounds in a resumed session are counted once'
}

test_absent_spend_is_zero_or_unavailable_never_invented() {
  local d out
  # A registered repository with no run on this branch: a truthful zero.
  d=$(make_case no-runs)
  seed_db "$d" current <<EOF
repo r1 $d/project
run sibling r1 fm/other completed 100
inv sibling review cold ok 10 1 1 1 1 1 1 1
EOF
  out=$(spend "$d" show) || fail "show failed for a task with no runs"
  assert_equals '"no-mistakes-state"' "$(field "$out" .source)" 'no runs is still a readable source'
  assert_equals '0' "$(field "$out" .total.invocations)" 'a task with no runs spent nothing'
  assert_equals '[]' "$(field "$out" .runs)" 'a task with no runs lists none'

  # A repository no-mistakes never initialized: unavailable, with its reason.
  d=$(make_case uninitialized)
  seed_db "$d" current </dev/null
  out=$(FAKE_NM_REPO='' spend "$d" show) || fail "show failed for an uninitialized repository"
  assert_equals '"unavailable"' "$(field "$out" .source)" 'an unresolved repository is unavailable'
  assert_contains "$(field "$out" .reason)" 'repo not initialized' 'the reason quotes the CLI'
  assert_equals 'null' "$(field "$out" .total)" 'an unavailable total is null, not zero'

  # A resolved repository whose state database is missing: unavailable, and
  # the read-only open never creates the database.
  d=$(make_case missing-db)
  out=$(spend "$d" show) || fail "show failed for a missing state database"
  assert_equals '"unavailable"' "$(field "$out" .source)" 'a missing state database is unavailable'
  assert_contains "$(field "$out" .reason)" 'cannot read no-mistakes state' 'the reason names the unreadable state'
  assert_absent "$d/nm/state.sqlite" 'the read-only open created a state database'

  # A state database from before no-mistakes recorded invocations.
  d=$(make_case no-invocations)
  seed_db "$d" no-invocations <<EOF
repo r1 $d/project
run first r1 fm/task completed 100
EOF
  out=$(spend "$d" show) || fail "show failed without an invocations table"
  assert_equals '"unavailable"' "$(field "$out" .source)" 'state without invocation records is unavailable'
  assert_contains "$(field "$out" .reason)" 'agent_invocations' 'the reason names the missing records'
  pass 'absent spend reads as zero only when no run exists, and as unavailable when it cannot be read'
}

test_older_state_without_delta_columns_counts_only_provable_rounds() {
  local d out
  d=$(make_case pre-delta)
  seed_db "$d" pre-delta <<EOF
repo r1 $d/project
run old r1 fm/task completed 100
inv old review cold ok 10 10 20 30 40 - - -
inv old review-fix resumed ok 10 99 99 99 99 - - -
EOF
  out=$(spend "$d" show) || fail "show failed for an older state database"
  assert_equals '{"total":10,"unknown":1}' "$(field "$out" .total.input_tokens)" \
    'a cold row counts its raw counter and a resumed row without a delta is unknown'
  assert_equals '{"total":40,"unknown":1}' "$(field "$out" .total.cache_creation_tokens)" \
    'an unproven resumed row leaves its cache writes unknown'
  pass 'older state without delta columns counts only rounds it can prove'
}

test_record_appends_once_per_task_incarnation() {
  local d out ledger
  d=$(make_case record)
  ledger=$d/home/data/pipeline-spend.jsonl
  seed_db "$d" current <<EOF
repo r1 $d/project
run first r1 fm/task completed 100
inv first review cold ok 10 1 2 3 4 1 2 3
EOF
  out=$(spend "$d" record) || fail "record failed"
  assert_contains "$out" 'recorded task' 'record reports the append'
  assert_equals 1 "$(wc -l < "$ledger" | tr -d ' ')" 'record appends one line'
  assert_equals '{"total":1,"unknown":0}' "$(jq -c .total.input_tokens "$ledger")" 'the ledger line carries the spend'
  out=$(spend "$d" record) || fail "a repeated record failed"
  assert_contains "$out" 'already recorded' 'a repeat for the same incarnation is recognized'
  assert_equals 1 "$(wc -l < "$ledger" | tr -d ' ')" 'a retried cleanup never counts the task twice'

  # A later task that reuses the id is a new incarnation and a new line, even
  # after a line that a crash left without its newline.
  printf '{"task":"torn' >> "$ledger"
  printf 'spawn_gen=s%s.2.def\n' "$NOW" >> "$d/home/state/task.meta"
  spend "$d" record >/dev/null || fail "record failed for a new incarnation"
  assert_equals 3 "$(wc -l < "$ledger" | tr -d ' ')" 'a new incarnation appends its own line'
  assert_equals "\"s$NOW.2.def\"" "$(tail -1 "$ledger" | jq -c .spawn_gen)" 'the new line names the new incarnation'

  # An unavailable source is still recorded, so its absence is explicit.
  d=$(make_case record-unavailable)
  FAKE_NM_REPO='' spend "$d" record >/dev/null || fail "record failed for an unavailable source"
  assert_equals '"unavailable"' "$(jq -c .source "$d/home/data/pipeline-spend.jsonl")" 'an unavailable record is kept'
  pass 'record appends one line per task incarnation'
}

test_refusals() {
  local d rc
  d=$(make_case refusals)
  set +e
  spend "$d" show missing >/dev/null 2>&1; rc=$?
  set -e
  expect_code 1 "$rc" 'a task with no record'
  fm_write_meta "$d/home/state/mate.meta" "kind=secondmate" "worktree=$d/wt"
  set +e
  spend "$d" record mate >/dev/null 2>&1; rc=$?
  set -e
  expect_code 1 "$rc" 'a secondmate'
  assert_absent "$d/home/data/pipeline-spend.jsonl" 'a refused record wrote the ledger'
  set +e
  spend "$d" show ../task >/dev/null 2>&1; rc=$?
  set -e
  expect_code 2 "$rc" 'an unsafe task id'
  pass 'missing tasks, secondmates, and unsafe ids are refused'
}

test_known_spend_including_failed_and_cancelled_is_attributed_to_the_task
test_repeated_review_rounds_in_a_resumed_session_are_not_double_counted
test_absent_spend_is_zero_or_unavailable_never_invented
test_older_state_without_delta_columns_counts_only_provable_rounds
test_record_appends_once_per_task_incarnation
test_refusals
