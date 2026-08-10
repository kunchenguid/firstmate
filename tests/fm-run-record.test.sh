#!/usr/bin/env bash
# Behavior tests for reading the validation pipeline's own run record.
#
# This backs a firstmate-invoked DIAGNOSTIC, not a gate. An automatic gate on
# head comparison was built and withdrawn on evidence: the pipeline overwrites
# its pre-push head at push, so no retained record holds the validated head
# afterwards, and every attempt to recover it failed differently - a stale
# snapshot refuses a good push with a false accusation, a missing one made the
# request permanently unmergeable. tests/fm-pr-check-security.test.sh pins that
# intake and merge can no longer block on any of it.
#
# What is pinned here is that each answer is three-valued and honest: found,
# nothing recorded, or could-not-observe - and that the snapshot never invents
# or back-fills a head it did not observe.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-run-record-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-intake-equivalence)

command -v python3 >/dev/null 2>&1 || {
  printf 'ok - skipped: python3 is required to read a pipeline run record\n'
  exit 0
}

git_do() {  # <dir> <args...>
  local dir=$1; shift
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "$@"
}

commit_all() {  # <dir> <message>
  git_do "$1" add -A
  git_do "$1" commit -qm "$2"
  git -C "$1" rev-parse HEAD
}

# make_db <path> <pr-url> <submitted> <pushed>: a stand-in for the pipeline's
# own state database, carrying only the columns this gate reads.
make_db() {
  FM_T_DB=$1 FM_T_URL=$2 FM_T_SUB=$3 FM_T_PUSH=$4 python3 - <<'PY'
import os, sqlite3
con = sqlite3.connect(os.environ["FM_T_DB"])
con.execute("CREATE TABLE runs (id TEXT, pr_url TEXT, submitted_head_sha TEXT, "
            "last_pushed_sha TEXT, created_at INTEGER)")
con.execute("INSERT INTO runs VALUES ('r1', ?, ?, ?, 1)",
            (os.environ["FM_T_URL"], os.environ["FM_T_SUB"], os.environ["FM_T_PUSH"]))
con.commit()
PY
}

# --- the run-record reader is three-valued -----------------------------------

DB="$TMP_ROOT/state.sqlite"
make_db "$DB" 'https://github.com/o/r/pull/1' aaaabbbbccccddddeeeeffff0000111122223333 4444555566667777888899990000aaaabbbbcccc

RC=0
OUT=$(FM_RUN_RECORD_DB="$DB" fm_run_record_for_pr 'https://github.com/o/r/pull/1') || RC=$?
expect_code 0 "$RC" 'a recorded run must be found'
assert_contains "$OUT" 'run=r1' 'the run id must be reported so its snapshot can be found'
assert_contains "$OUT" 'pushed=4444555566667777888899990000aaaabbbbcccc' 'the pushed head must be reported'
pass 'a recorded run reports its id and the head it pushed'

# The lookup matches forge identity, not the URL's exact spelling. An exact
# string match silently disabled the gate on any difference, and a silently
# disabled gate is indistinguishable from a request that had no pipeline run.
for spelling in 'https://github.com/o/r/pull/1/' 'https://www.github.com/o/r/pull/1'; do
  RC=0
  OUT=$(FM_RUN_RECORD_DB="$DB" fm_run_record_for_pr "$spelling") || RC=$?
  expect_code 0 "$RC" "a differently spelled URL must still find its run: $spelling"
done
pass 'the run lookup matches forge identity rather than the URL spelling'

RC=0
OUT=$(FM_RUN_RECORD_DB="$DB" fm_run_record_for_pr 'https://github.com/other/r/pull/1') || RC=$?
expect_code 1 "$RC" 'a different repository must not answer for this request'
pass 'identity matching does not over-match a different repository'

RC=0
OUT=$(FM_RUN_RECORD_DB="$DB" fm_run_record_for_pr 'not-a-request-url') || RC=$?
expect_code 2 "$RC" 'an unresolvable request identity must be could-not-observe'
pass 'an unresolvable request identity is could-not-observe, never no-record'

RC=0
OUT=$(FM_RUN_RECORD_DB="$DB" fm_run_record_for_pr 'https://github.com/o/r/pull/999') || RC=$?
expect_code 1 "$RC" 'a request with no recorded run must be distinguishable'
pass 'a request with no recorded run is reported as absent, not as unreadable'

# A database that is PRESENT but unreadable is could-not-observe, because a run
# may well exist and this cannot tell. A database that does not exist at all is
# a machine where no pipeline run has ever happened, which is genuinely nothing
# recorded - conflating the two would either fail open or refuse every request
# on a machine that never ran the pipeline.
printf 'not a database\n' > "$TMP_ROOT/corrupt.sqlite"
RC=0
OUT=$(FM_RUN_RECORD_DB="$TMP_ROOT/corrupt.sqlite" fm_run_record_for_pr 'https://github.com/o/r/pull/1') || RC=$?
expect_code 2 "$RC" 'a present but unreadable database must be could-not-observe'
pass 'an unreadable run record is could-not-observe, never an absent run'

RC=0
OUT=$(FM_RUN_RECORD_DB="$TMP_ROOT/no-such.sqlite" fm_run_record_for_pr 'https://github.com/o/r/pull/1') || RC=$?
expect_code 1 "$RC" 'no database at all means no pipeline run has ever existed here'
pass 'an absent pipeline database is nothing recorded, not an unreadable one'

# A recorded run that never completed a push has nothing to compare, and must
# not be confused with one whose push dropped everything.
NOPUSH="$TMP_ROOT/nopush.sqlite"
make_db "$NOPUSH" 'https://github.com/o/r/pull/2' aaaabbbbccccddddeeeeffff0000111122223333 ''
RC=0
OUT=$(FM_RUN_RECORD_DB="$NOPUSH" fm_run_record_for_pr 'https://github.com/o/r/pull/2') || RC=$?
expect_code 1 "$RC" 'a run that never pushed has nothing to compare'
pass 'a recorded run with no push is absent rather than a comparison of nothing'

# --- the snapshot is what makes a sound comparison possible ------------------
#
# The validated head is destroyed at push: the pipeline overwrites head_sha with
# the pushed head, so nothing afterwards can recover the content it judged. The
# watcher therefore records the last head each run had while it had NOT pushed.

SNAPDB="$TMP_ROOT/snap.sqlite"
NOW=$(date +%s)
FM_T_DB="$SNAPDB" FM_T_NOW="$NOW" python3 - <<'PY2'
import os, sqlite3
now = int(os.environ["FM_T_NOW"])
con = sqlite3.connect(os.environ["FM_T_DB"])
con.execute("CREATE TABLE runs (id TEXT, pr_url TEXT, submitted_head_sha TEXT, "
            "head_sha TEXT, last_pushed_sha TEXT, created_at INTEGER, updated_at INTEGER)")
con.execute("INSERT INTO runs VALUES ('inflight', '', 'aaaa', "
            "'bbbbccccddddeeeeffff00001111222233334444', '', ?, ?)", (now, now))
con.execute("INSERT INTO runs VALUES ('already-pushed', '', 'aaaa', 'cccc', 'cccc', ?, ?)", (now, now))
# A long-dead run that never pushed. Every one of these qualified forever and
# was rewritten on every watcher cycle - 48 of 116 in a real database - in a
# directory nothing prunes.
con.execute("INSERT INTO runs VALUES ('ancient', '', 'aaaa', 'dddd', '', 1, 1)")
con.commit()
PY2

SNAPSTATE="$TMP_ROOT/snapstate"
mkdir -p "$SNAPSTATE"
FM_RUN_RECORD_DB="$SNAPDB" fm_run_snapshot_tick "$SNAPSTATE"

RC=0
OUT=$(fm_run_snapshot_read "$SNAPSTATE" inflight) || RC=$?
expect_code 0 "$RC" 'a run that has not pushed must be snapshot'
assert_contains "$OUT" 'head=bbbbccccddddeeeeffff00001111222233334444' 'the snapshot must carry the head observed'
assert_contains "$OUT" 'observed_at=' 'a snapshot that cannot say when it was taken is not evidence'
pass 'the watcher snapshots the head of a run that has not pushed yet'

RC=0
OUT=$(fm_run_snapshot_read "$SNAPSTATE" already-pushed) || RC=$?
expect_code 1 "$RC" 'a run that already pushed must not be snapshot after the fact'
pass 'an already-pushed run is never snapshot, so nothing is ever back-filled'

RC=0
OUT=$(fm_run_snapshot_read "$SNAPSTATE" never-seen) || RC=$?
expect_code 1 "$RC" 'an absent snapshot must be distinguishable'
pass 'an absent snapshot reports absent rather than inventing a head'

RC=0
OUT=$(fm_run_snapshot_read "$SNAPSTATE" ancient) || RC=$?
expect_code 1 "$RC" 'a long-dead never-pushed run must fall outside the tick'
pass 'the tick is bounded, so dead runs are not rewritten forever'

# --- a run whose newest attempt has not pushed yet ---------------------------
#
# Stopping at the first identity match reported "nothing recorded" whenever a
# re-run was in flight, so a request that WAS produced by a pipeline push read
# exactly like one that never had a run - a silent fail-open in the diagnostic.

RERUN_DB="$TMP_ROOT/rerun.sqlite"
FM_T_DB="$RERUN_DB" python3 - <<'PY2'
import os, sqlite3
con = sqlite3.connect(os.environ["FM_T_DB"])
con.execute("CREATE TABLE runs (id TEXT, pr_url TEXT, submitted_head_sha TEXT, "
            "head_sha TEXT, last_pushed_sha TEXT, created_at INTEGER)")
url = 'https://github.com/o/r/pull/5'
con.execute("INSERT INTO runs VALUES ('older', ?, 'aaaa', 'bbbb', 'bbbb', 1)", (url,))
con.execute("INSERT INTO runs VALUES ('newer-inflight', ?, 'aaaa', 'cccc', '', 2)", (url,))
con.commit()
PY2

RC=0
OUT=$(FM_RUN_RECORD_DB="$RERUN_DB" fm_run_record_for_pr 'https://github.com/o/r/pull/5') || RC=$?
expect_code 0 "$RC" 'a re-run in flight must not hide the run that actually pushed'
assert_contains "$OUT" 'run=older' 'the newest run that actually pushed must be the one reported'
pass 'a newer unpushed re-run does not read as though nothing was ever pushed'

# --- the snapshot never rewrites an unchanged head ---------------------------

CHURN="$TMP_ROOT/churnstate"
mkdir -p "$CHURN"
FM_RUN_RECORD_DB="$SNAPDB" fm_run_snapshot_tick "$CHURN"
before=$(cat "$CHURN/run-snapshot/inflight")
touch -t 200001010000 "$CHURN/run-snapshot/inflight"
stamp=$(ls -l "$CHURN/run-snapshot/inflight")
FM_RUN_RECORD_DB="$SNAPDB" fm_run_snapshot_tick "$CHURN"
[ "$(ls -l "$CHURN/run-snapshot/inflight")" = "$stamp" ] \
  || fail 'an unchanged head must not be rewritten on every watcher cycle'
[ "$(cat "$CHURN/run-snapshot/inflight")" = "$before" ] \
  || fail 'skipping the write must not alter the recorded snapshot'
pass 'a snapshot whose head has not moved is left alone'

printf 'all run record tests passed\n'
