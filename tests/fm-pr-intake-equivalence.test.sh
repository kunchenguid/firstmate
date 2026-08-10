#!/usr/bin/env bash
# Behavior tests for the rebase-equivalence gate at pull-request intake.
#
# A validation pipeline rebases a branch onto its target immediately before
# pushing, and twice a rebase dropped content the pipeline had already validated
# without any signal from the run. The comparison cannot live with the worker:
# the validated bytes are in the pipeline's gate repository, not the worker's
# clone. Intake is where both facts are readable, so that is where the gate is.
#
# These tests pin the three-valued outcome. A recorded run whose push dropped
# content must REFUSE and must not arm the merge watch; a request with no
# recorded run is not this gate's business and passes through; and a comparison
# that cannot be made is reported rather than quietly becoming a pass.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-run-record-lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-intake-equivalence)
BASE_PATH=$PATH

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
FM_T_DB="$SNAPDB" python3 - <<'PY2'
import os, sqlite3
con = sqlite3.connect(os.environ["FM_T_DB"])
con.execute("CREATE TABLE runs (id TEXT, pr_url TEXT, submitted_head_sha TEXT, "
            "head_sha TEXT, last_pushed_sha TEXT, created_at INTEGER)")
con.execute("INSERT INTO runs VALUES ('inflight', '', 'aaaa', 'bbbbccccddddeeeeffff00001111222233334444', '', 1)")
con.execute("INSERT INTO runs VALUES ('already-pushed', '', 'aaaa', 'cccc', 'cccc', 2)")
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

# --- intake refuses a push that dropped validated content --------------------

DIR="$TMP_ROOT/gate"
FAKEBIN="$DIR/fakebin"
mkdir -p "$DIR/home/state" "$DIR/home/data" "$FAKEBIN" "$DIR/root/bin"

cat > "$DIR/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$DIR/root/bin/fm-guard.sh"

# The pipeline's gate repository holds the validated head; the forge holds what
# would land. Neither is the worker's own branch, which is the whole point.
SRC="$DIR/src"
mkdir -p "$SRC"
git -C "$SRC" init -q
printf 'alpha\nbravo\n' > "$SRC/core.sh"
BASE=$(commit_all "$SRC" 'base')
printf 'alpha\nbravo\nthe validated fix\n' > "$SRC/core.sh"
VALIDATED=$(commit_all "$SRC" 'validated: the fix the pipeline judged')

git_do "$SRC" checkout -q -b trunk "$BASE"
printf 'alpha\nbravo\ntrunk moved on\n' > "$SRC/core.sh"
TRUNK=$(commit_all "$SRC" 'trunk: moved on')
printf 'unrelated\n' > "$SRC/unrelated.txt"
DROPPED=$(commit_all "$SRC" 'candidate: the validated fix never landed')
git_do "$SRC" checkout -q -b faithful "$TRUNK"
printf 'alpha\nbravo\ntrunk moved on\nthe validated fix\n' > "$SRC/core.sh"
FAITHFUL=$(commit_all "$SRC" 'candidate: the validated fix carried over')

GATE_REPO="$DIR/gate.git"
git init -q --bare -b main "$GATE_REPO"
git_do "$SRC" push -q "$GATE_REPO" "$VALIDATED:refs/heads/fm/work"

FORGE="$DIR/forge.git"
git init -q --bare -b main "$FORGE"
git_do "$SRC" push -q "$FORGE" "$TRUNK:refs/heads/main" \
  "$DROPPED:refs/pull/7/head" "$FAITHFUL:refs/pull/8/head"

WT="$DIR/wt"
git clone -q --no-local "$FORGE" "$WT"
git -C "$WT" remote add no-mistakes "$GATE_REPO"
git -C "$WT" config "url.$FORGE.insteadOf" 'https://github.com/o/r.git'

fm_write_meta "$DIR/home/state/task-a.meta" \
  "window=firstmate:fm-task-a" \
  "endpoint_task_id=task-a" \
  "worktree=$WT" \
  "project=$DIR/project" \
  "kind=ship" \
  "mode=no-mistakes"

# The gate reads the head from the forge to record it, and the comparison reads
# the request's base branch so the candidate is measured against the trunk it
# actually sits on. Both come through gh, so the stand-in answers both.
cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" headRefOid "*) printf '%s\n' "$DROPPED" ;;
  *" baseRefName "*) printf '%s\n' main ;;
esac
SH
chmod +x "$FAKEBIN/gh"

write_snapshot() {  # <run-id> <head>
  mkdir -p "$DIR/home/state/run-snapshot"
  printf 'run=%s\nhead=%s\nobserved_at=%s\npushed=no\n' "$1" "$2" 1786000000 \
    > "$DIR/home/state/run-snapshot/$1"
}

make_run_db() {  # <path> <pr-number> <pushed-head>
  FM_T_DB=$1 FM_T_URL="https://github.com/o/r/pull/$2" FM_T_PUSH=$3 python3 - <<'PY2'
import os, sqlite3
con = sqlite3.connect(os.environ["FM_T_DB"])
con.execute("CREATE TABLE runs (id TEXT, pr_url TEXT, submitted_head_sha TEXT, "
            "head_sha TEXT, last_pushed_sha TEXT, created_at INTEGER)")
con.execute("INSERT INTO runs VALUES ('run-a', ?, 'aaaa', ?, ?, 1)",
            (os.environ["FM_T_URL"], os.environ["FM_T_PUSH"], os.environ["FM_T_PUSH"]))
con.commit()
PY2
}

run_intake() {  # <db> <pr-number>
  RC=0
  OUT=$(FM_HOME="$DIR/home" FM_ROOT_OVERRIDE="$DIR/root" \
    FM_RUN_RECORD_DB="$1" PATH="$FAKEBIN:$BASE_PATH" \
    "$PR_CHECK" task-a "https://github.com/o/r/pull/$2" 2>&1) || RC=$?
}

DROP_DB="$DIR/drop.sqlite"
make_run_db "$DROP_DB" 7 "$DROPPED"

# No snapshot yet: the comparison has no sound validated side, so it must refuse
# rather than reach for a head that would false-refuse or silently pass.
rm -rf "$DIR/home/state/run-snapshot"
run_intake "$DROP_DB" 7
expect_code 1 "$RC" 'a run with no snapshot must refuse at intake'
assert_contains "$OUT" 'CANNOT-OBSERVE' 'a missing snapshot must be could-not-observe'
assert_contains "$OUT" 'never back-filled' 'the refusal must say why a snapshot is not invented'
assert_absent "$DIR/home/state/task-a.check.sh" 'a run with no snapshot must arm nothing'
pass 'a run with no validated-head snapshot refuses and arms nothing'

write_snapshot run-a "$VALIDATED"
run_intake "$DROP_DB" 7
expect_code 1 "$RC" 'a push that dropped validated content must be refused at intake'
assert_contains "$OUT" 'DROPPED' 'the refusal must carry the comparison verdict'
assert_contains "$OUT" 'core.sh' 'the losing path must be named'
assert_absent "$DIR/home/state/task-a.check.sh" 'a refused request must not arm a merge watch'
pass 'intake refuses a push that dropped what the pipeline validated, naming the path'

# --- a faithful push, compared against the snapshot, still arms ---------------
#
# This is the case the previous source got wrong: comparing submitted_head_sha
# would have reported the run's own accepted fixes as dropped content.

FAITHFUL_DB="$DIR/faithful.sqlite"
make_run_db "$FAITHFUL_DB" 8 "$FAITHFUL"
write_snapshot run-a "$VALIDATED"
run_intake "$FAITHFUL_DB" 8
expect_code 0 "$RC" 'a faithful push compared against the snapshot must arm'
assert_present "$DIR/home/state/task-a.check.sh" 'a faithful push must arm its merge watch'
pass 'a push that carried the validated content is compared and armed'

# --- a request with no recorded run is not this gate's business --------------
#
# Direct-PR delivery never runs the pipeline, so it has no run row. Refusing
# here would break a delivery mode this gate has nothing to say about.

rm -f "$DIR/home/state/task-a.check.sh"
EMPTY_DB="$DIR/empty.sqlite"
make_run_db "$EMPTY_DB" 999 aaaa
run_intake "$EMPTY_DB" 8
expect_code 0 "$RC" 'a request with no recorded run must pass through intake'
assert_present "$DIR/home/state/task-a.check.sh" 'an unrelated request must still arm its merge watch'
pass 'a request with no recorded pipeline run is armed untouched'

# --- could-not-observe refuses; it never arms --------------------------------
#
# A warning on stderr followed by an armed watch and a zero exit is a pass to
# every automated consumer, which is the fail-open this gate exists to close.

rm -f "$DIR/home/state/task-a.check.sh"
printf 'not a database\n' > "$DIR/corrupt.sqlite"
run_intake "$DIR/corrupt.sqlite" 8
expect_code 1 "$RC" 'an unreadable run record must refuse at intake'
assert_contains "$OUT" 'CANNOT-OBSERVE' 'an unreadable run record must be reported at intake'
assert_contains "$OUT" 'NOT checked' 'the report must say the content was not checked'
assert_absent "$DIR/home/state/task-a.check.sh" 'a could-not-observe outcome must arm nothing'
pass 'a comparison that cannot be made refuses and arms nothing'

printf 'all pr intake equivalence tests passed\n'
