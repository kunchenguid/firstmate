#!/usr/bin/env bash
# fm-nm-status.test.sh - the panel reads a run's rework count from the daemon's
# step_rounds record and never presents the run id as a round number.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v sqlite3 >/dev/null 2>&1 || { echo 'skip: sqlite3 not found'; exit 0; }

TMP=$(fm_test_tmproot fm-nm-status) || fail 'could not create a fixture root'
FAKEBIN=$(fm_fakebin "$TMP")
NM_HOME="$TMP/nm"
mkdir -p "$NM_HOME"

# The fake daemon answers `axi status [--run ID]` with the TOON shape the panel
# parses. With no --run the current branch has no record and another branch's run
# is the only thing axi would offer (`other_branch_run:`); naming a run with
# --run returns it under its own key. RUNOTHER stands in for a run that lives on
# another branch even though --run named it.
cat > "$FAKEBIN/no-mistakes" <<'FAKE'
#!/usr/bin/env bash
id=RUNNONE
explicit=0
while [ $# -gt 0 ]; do
  case "$1" in --run) id=$2; explicit=1; shift ;; esac
  shift
done
status=running
review=completed
teststep=completed
active=''
case "$id" in
  RUNPASSED) status=completed ;;
  RUNFIXING)
    review=fixing
    active='  active_steps[1]{step,status,active_for,round_active_for,last_activity,agent_pid,round}:
    review,fixing,12m3s,8s,8s,44121,"fix 1"'
    ;;
  RUNFIXING2)
    review=fixing
    active='  active_steps[1]{step,status,active_for,round_active_for,last_activity,agent_pid,round}:
    review,fixing,12m3s,8s,8s,44121,"fix 2"'
    ;;
  RUNROUND2 | RUNROUND2LANDED)
    review=running
    active='  active_steps[1]{step,status,active_for,round_active_for,last_activity,agent_pid,round}:
    review,running,12m3s,8s,8s,44121,"round 2"'
    ;;
  RUNSTARTING)
    review=running
    active='  active_steps[1]{step,status,active_for,round_active_for,last_activity,agent_pid,round}:
    review,running,12m3s,8s,8s,44121,"starting"'
    ;;
  RUNMANYFIX)
    teststep=fixing
    active='  active_steps[1]{step,status,active_for,round_active_for,last_activity,agent_pid,round}:
    test,fixing,12m3s,8s,8s,44121,"auto-fix 1/3"'
    ;;
esac
block=run
branch=fm/demo
if [ "$explicit" -eq 0 ] || [ "$id" = RUNOTHER ]; then
  block=other_branch_run
  branch=fm/other
  [ "$explicit" -eq 0 ] && id=RUNOTHER
fi
[ "$explicit" -eq 0 ] && echo 'runs_on_current_branch: 0'
cat <<TOON
$block:
  id: "$id"
  branch: $branch
  status: $status
  head: abc12345
  findings: none
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,3
    rebase,completed,0,3510
    review,$review,0,1436878
    test,$teststep,0,1000
    document,completed,0,1000
    lint,completed,0,1000
    push,completed,0,1000
    pr,completed,0,1000
    ci,completed,0,1000
$active
TOON
FAKE
chmod +x "$FAKEBIN/no-mistakes"

# Only the columns the panel's query touches; the real schema has many more.
sqlite3 "$NM_HOME/state.sqlite" <<'SQL'
CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL);
CREATE TABLE step_rounds (id TEXT PRIMARY KEY, step_result_id TEXT NOT NULL, round INTEGER NOT NULL, trigger_type TEXT NOT NULL);
INSERT INTO step_results VALUES ('s-none-review', 'RUNNONE', 'review');
INSERT INTO step_rounds VALUES ('r-none-1', 's-none-review', 1, 'initial');
INSERT INTO step_results VALUES ('s-many-review', 'RUNMANY', 'review');
INSERT INTO step_results VALUES ('s-many-test', 'RUNMANY', 'test');
INSERT INTO step_rounds VALUES ('r-many-1', 's-many-review', 1, 'initial');
INSERT INTO step_rounds VALUES ('r-many-2', 's-many-review', 2, 'auto_fix');
INSERT INTO step_rounds VALUES ('r-many-3', 's-many-review', 3, 'auto_fix');
INSERT INTO step_rounds VALUES ('r-many-4', 's-many-review', 4, 'auto_fix');
INSERT INTO step_rounds VALUES ('r-many-5', 's-many-review', 5, 'auto_fix');
INSERT INTO step_rounds VALUES ('r-many-t1', 's-many-test', 1, 'initial');
INSERT INTO step_rounds VALUES ('r-many-t2', 's-many-test', 2, 'auto_fix');
INSERT INTO step_results VALUES ('s-passed-review', 'RUNPASSED', 'review');
INSERT INTO step_rounds VALUES ('r-passed-1', 's-passed-review', 1, 'initial');
INSERT INTO step_rounds VALUES ('r-passed-2', 's-passed-review', 2, 'auto_fix');
INSERT INTO step_results VALUES ('s-other-review', 'RUNOTHER', 'review');
INSERT INTO step_rounds VALUES ('r-other-1', 's-other-review', 1, 'initial');
INSERT INTO step_rounds VALUES ('r-other-2', 's-other-review', 2, 'auto_fix');
INSERT INTO step_results VALUES ('s-fixing-review', 'RUNFIXING', 'review');
INSERT INTO step_rounds VALUES ('r-fixing-1', 's-fixing-review', 1, 'initial');
INSERT INTO step_results VALUES ('s-round2-review', 'RUNROUND2', 'review');
INSERT INTO step_rounds VALUES ('r-round2-1', 's-round2-review', 1, 'initial');
INSERT INTO step_results VALUES ('s-starting-review', 'RUNSTARTING', 'review');
INSERT INTO step_rounds VALUES ('r-starting-1', 's-starting-review', 1, 'initial');
INSERT INTO step_results VALUES ('s-fixing2-review', 'RUNFIXING2', 'review');
INSERT INTO step_rounds VALUES ('r-fixing2-1', 's-fixing2-review', 1, 'initial');
INSERT INTO step_rounds VALUES ('r-fixing2-2', 's-fixing2-review', 2, 'auto_fix');
INSERT INTO step_results VALUES ('s-round2done-review', 'RUNROUND2LANDED', 'review');
INSERT INTO step_rounds VALUES ('r-round2done-1', 's-round2done-review', 1, 'initial');
INSERT INTO step_rounds VALUES ('r-round2done-2', 's-round2done-review', 2, 'auto_fix');
INSERT INTO step_results VALUES ('s-manyfix-review', 'RUNMANYFIX', 'review');
INSERT INTO step_results VALUES ('s-manyfix-test', 'RUNMANYFIX', 'test');
INSERT INTO step_rounds VALUES ('r-manyfix-1', 's-manyfix-review', 1, 'initial');
INSERT INTO step_rounds VALUES ('r-manyfix-2', 's-manyfix-review', 2, 'auto_fix');
INSERT INTO step_rounds VALUES ('r-manyfix-3', 's-manyfix-review', 3, 'auto_fix');
INSERT INTO step_rounds VALUES ('r-manyfix-4', 's-manyfix-review', 4, 'auto_fix');
INSERT INTO step_rounds VALUES ('r-manyfix-5', 's-manyfix-review', 5, 'auto_fix');
INSERT INTO step_rounds VALUES ('r-manyfix-t1', 's-manyfix-test', 1, 'initial');
SQL

panel() {
  PATH="$FAKEBIN:$PATH" COLUMNS=80 NO_COLOR=1 TERM=dumb NM_HOME="$NM_HOME" \
    bash "$ROOT/bin/fm-nm-status.sh" "$@" 2>&1
}

OUT=$(panel --run RUNNONE); CODE=$?
expect_code 0 "$CODE" 'panel with no rework'
assert_contains "$OUT" '运行编号  RUNNONE' 'run id is labelled as the run number'
assert_contains "$OUT" '未返工' 'a run with only initial rounds reads as not reworked'
assert_not_contains "$OUT" '轮' 'no round wording survives'

OUT=$(panel --run RUNMANY); CODE=$?
expect_code 0 "$CODE" 'panel with rework across two steps'
assert_contains "$OUT" '返工 5 次' 'rework sums non-initial rounds over every step'
assert_not_contains "$OUT" '第 ' 'the run is not numbered as a round'

OUT=$(panel --run RUNPASSED); CODE=$?
expect_code 0 "$CODE" 'panel for a passed run'
assert_contains "$OUT" '✓ 验收通过' 'passed status still renders'
assert_contains "$OUT" '返工 1 次' 'a passed run keeps its rework count'

OUT=$(NM_HOME="$TMP/empty" panel --run RUNMANY); CODE=$?
expect_code 0 "$CODE" 'panel with an unreadable record keeps rendering'
assert_contains "$OUT" '返工次数不可读' 'an unreadable record is reported, not shown as zero'
assert_contains "$OUT" '09  远端验证' 'the step table still renders after the failed read'
assert_not_contains "$OUT" '未返工' 'an unreadable record never reads as no rework'

OUT=$(panel); CODE=$?
expect_code 0 "$CODE" 'panel with no run on the current branch'
assert_contains "$OUT" '当前分支还没有验收记录' 'an unattributed other-branch run reads as no local record'
assert_not_contains "$OUT" 'fm/other' 'another branch name never leaks into the panel'
assert_not_contains "$OUT" 'RUNOTHER' 'another branch run id never leaks into the panel'
assert_not_contains "$OUT" '返工' 'another branch rework count is never shown'

OUT=$(panel --run RUNOTHER); CODE=$?
expect_code 0 "$CODE" 'panel for a run named with --run on another branch'
assert_contains "$OUT" '运行编号  RUNOTHER' 'an explicit --run still renders the run id'
assert_contains "$OUT" '返工 1 次' 'an explicit --run still shows the run rework count'

# A pass that is still running has no step_rounds row yet, so the panel must add
# the in-flight one instead of reporting the stale stored count.
OUT=$(panel --run RUNFIXING); CODE=$?
expect_code 0 "$CODE" 'panel while a step is being repaired'
assert_contains "$OUT" '返工 1 次' 'a fixing step counts the in-flight rework pass'
assert_contains "$OUT" '12m3s · fix 1' 'the fixing step keeps its active timing and round label'

OUT=$(panel --run RUNROUND2); CODE=$?
expect_code 0 "$CODE" 'panel while a round-2 review runs'
assert_contains "$OUT" '返工 1 次' 'a running round-2 review counts the in-flight pass'

OUT=$(panel --run RUNSTARTING); CODE=$?
expect_code 0 "$CODE" 'panel while a first review starts'
assert_contains "$OUT" '未返工' 'a running first pass is not rework'

OUT=$(panel --run RUNFIXING2); CODE=$?
expect_code 0 "$CODE" 'panel with stored rework plus an in-flight pass'
assert_contains "$OUT" '返工 2 次' 'the in-flight pass is added to the stored count, not replaced'

# The stored round and the label can disagree for one refresh while a round lands;
# taking the further-along side per step keeps the panel stable either way.
OUT=$(panel --run RUNROUND2LANDED); CODE=$?
expect_code 0 "$CODE" 'panel when the running round is already stored'
assert_contains "$OUT" '返工 1 次' 'a round already stored is not counted twice'

OUT=$(panel --run RUNMANYFIX); CODE=$?
expect_code 0 "$CODE" 'panel with stored rework on another step'
assert_contains "$OUT" '返工 5 次' 'stored per-step passes sum with the in-flight pass on another step'

OUT=$(panel --help)
assert_contains "$OUT" '返工次数' 'help explains the rework count'
assert_not_contains "$OUT" '轮次' 'help drops the old round wording'

pass 'fm-nm-status reads rework count from step_rounds and labels the run id separately'
