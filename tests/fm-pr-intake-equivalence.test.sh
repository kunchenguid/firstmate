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
assert_contains "$OUT" 'submitted=aaaabbbbccccddddeeeeffff0000111122223333' 'the submitted head must be reported'
assert_contains "$OUT" 'pushed=4444555566667777888899990000aaaabbbbcccc' 'the pushed head must be reported'
pass 'a recorded run reports the head it submitted and the head it pushed'

RC=0
OUT=$(FM_RUN_RECORD_DB="$DB" fm_run_record_for_pr 'https://github.com/o/r/pull/999') || RC=$?
expect_code 1 "$RC" 'a request with no recorded run must be distinguishable'
pass 'a request with no recorded run is reported as absent, not as unreadable'

RC=0
OUT=$(FM_RUN_RECORD_DB="$TMP_ROOT/no-such.sqlite" fm_run_record_for_pr 'https://github.com/o/r/pull/1') || RC=$?
expect_code 2 "$RC" 'an unreadable database must be could-not-observe'
pass 'an unreadable run record is could-not-observe, never an absent run'

# A recorded run that never completed a push has nothing to compare, and must
# not be confused with one whose push dropped everything.
NOPUSH="$TMP_ROOT/nopush.sqlite"
make_db "$NOPUSH" 'https://github.com/o/r/pull/2' aaaabbbbccccddddeeeeffff0000111122223333 ''
RC=0
OUT=$(FM_RUN_RECORD_DB="$NOPUSH" fm_run_record_for_pr 'https://github.com/o/r/pull/2') || RC=$?
expect_code 1 "$RC" 'a run that never pushed has nothing to compare'
pass 'a recorded run with no push is absent rather than a comparison of nothing'

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

GATE_REPO="$DIR/gate.git"
git init -q --bare -b main "$GATE_REPO"
git_do "$SRC" push -q "$GATE_REPO" "$VALIDATED:refs/heads/fm/work"

FORGE="$DIR/forge.git"
git init -q --bare -b main "$FORGE"
git_do "$SRC" push -q "$FORGE" "$TRUNK:refs/heads/main" "$DROPPED:refs/pull/7/head"

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

GATE_DB="$DIR/state.sqlite"
make_db "$GATE_DB" 'https://github.com/o/r/pull/7' "$VALIDATED" "$DROPPED"

run_intake() {
  RC=0
  OUT=$(FM_HOME="$DIR/home" FM_ROOT_OVERRIDE="$DIR/root" \
    FM_RUN_RECORD_DB="$1" PATH="$FAKEBIN:$BASE_PATH" \
    "$PR_CHECK" task-a 'https://github.com/o/r/pull/7' 2>&1) || RC=$?
}

run_intake "$GATE_DB"
expect_code 1 "$RC" 'a push that dropped validated content must be refused at intake'
assert_contains "$OUT" 'DROPPED' 'the refusal must carry the comparison verdict'
assert_contains "$OUT" 'core.sh' 'the losing path must be named'
assert_absent "$DIR/home/state/task-a.check.sh" 'a refused request must not arm a merge watch'
pass 'intake refuses a push that dropped what the pipeline validated, naming the path'

# --- a request with no recorded run is not this gate's business --------------
#
# Direct-PR delivery never runs the pipeline, so it has no run row. Refusing
# here would break a delivery mode this gate has nothing to say about.

EMPTY_DB="$TMP_ROOT/empty.sqlite"
make_db "$EMPTY_DB" 'https://github.com/o/r/pull/999' aaaa bbbb
run_intake "$EMPTY_DB"
expect_code 0 "$RC" 'a request with no recorded run must pass through intake'
assert_present "$DIR/home/state/task-a.check.sh" 'an unrelated request must still arm its merge watch'
pass 'a request with no recorded pipeline run is armed untouched'

# --- a comparison that cannot be made is reported, never a silent pass -------

rm -f "$DIR/home/state/task-a.check.sh"
run_intake "$TMP_ROOT/no-such.sqlite"
assert_contains "$OUT" 'CANNOT-OBSERVE' 'an unreadable run record must be reported at intake'
assert_contains "$OUT" 'NOT checked' 'the report must say the content was not checked'
pass 'a comparison that cannot be made is reported rather than passing silently'

printf 'all pr intake equivalence tests passed\n'
