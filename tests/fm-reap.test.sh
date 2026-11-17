#!/usr/bin/env bash
# fm-reap.sh: finished crewmates and scouts close after their time; second
# mates, active tasks, and boards in review are left alone; shadow mode only
# reports, enforce mode closes through teardown and keeps what teardown refuses.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-reap)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state/procevent" "$HOME_DIR/state/procevent-inbox" "$HOME_DIR/config" "$HOME_DIR/data"
trap 'kill "${LIVE_PID:-}" "${HOLDER:-}" 2>/dev/null; rm -rf "$TMP_ROOT"' EXIT
export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_DATA_OVERRIDE="$HOME_DIR/data"
REAP="$ROOT/bin/fm-reap.sh"
now=$(date +%s)
task() {  # <id> <kind> <status lines...>
  local id=$1 kind=$2
  shift 2
  printf 'kind=%s\nharness=claude\n' "$kind" > "$HOME_DIR/state/$id.meta"
  printf '%s\n' "$@" > "$HOME_DIR/state/$id.status"
}
task old ship "working [at=$((now - 9000))]: x" "done [at=$((now - 8000))]: PR https://example.invalid/1" "resolved [key=k] [at=$((now - 10))]: answered"
task fresh ship "done [at=$((now - 600))]: PR https://example.invalid/2"
task busy scout "done [at=$((now - 90000))]: report" "working [at=$((now - 60))]: board round"
task scoutdone scout "done [at=$((now - 30000))]: report"
task mate secondmate "done [at=$((now - 900000))]: idle"
task review scout "done [at=$((now - 30000))]: report"
printf 'adapter=lavish\nkind=task-owned\nowner_task=review\n' > "$HOME_DIR/state/procevent/lavish-abc.source"
touch -d "@$((now - 3600))" "$HOME_DIR/state/procevent-inbox/lavish-abc.4.result"
out=$("$REAP" list)
assert_contains "$out" 'old due done 2h ago' 'a ship done past its time is due'
assert_contains "$out" 'fresh waiting done 10m ago, closes in 110m' 'a recent done waits'
assert_contains "$out" 'busy active working' 'a task that resumed is active'
assert_contains "$out" 'scoutdone due' 'a finished scout is due'
assert_not_contains "$out" 'mate' 'second mates are never listed'
assert_contains "$out" 'review waiting done 60m ago board, closes in 1380m' 'a board in review waits a day from its last round'
pass 'verdicts: done past its time, resumed, board grace, second mates exempt'
assert_equals '' "$("$REAP" check)" 'without config/reaper the reaper is off'
printf 'shadow\n' > "$HOME_DIR/config/reaper"
out=$("$REAP" check)
assert_contains "$out" 'reap (shadow, nothing closed): 2 finished worker(s) past their close time: old done 2h ago; scoutdone done 8h ago' 'shadow names every due worker once'
assert_equals '' "$("$REAP" check)" 'an unchanged due set does not wake again'
pass 'shadow mode reports the due set once and closes nothing'
printf 'enforce\n' > "$HOME_DIR/config/reaper"
cat > "$TMP_ROOT/teardown" <<'SH'
#!/usr/bin/env bash
case "$1" in
  old) printf 'tore down old\n' ;;
  *) printf 'error: refusing - the worktree holds work that has not landed (2 commits)\n' >&2; exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/teardown"
out=$(FM_REAP_TEARDOWN="$TMP_ROOT/teardown" "$REAP" run)
assert_contains "$out" 'closed old (done 2h ago)' 'a landed worker is closed'
assert_contains "$out" 'kept scoutdone: error: refusing - the worktree holds work that has not landed (2 commits)' 'an unlanded worker is kept with teardown reason'
FM_REAP_TEARDOWN="$TMP_ROOT/teardown" "$REAP" check > "$TMP_ROOT/first"
for ((i = 0; i < 50; i++)); do [ -s "$HOME_DIR/state/reaper-run.log" ] && [ ! -d "$HOME_DIR/state/.reaper-run.lock" ] && break; sleep 0.1; done
sleep 1
touch "$HOME_DIR/state/reaper-run.log"
out=$(FM_REAP_TEARDOWN="$TMP_ROOT/teardown" "$REAP" check)
assert_contains "$out" 'reap: closed old' 'enforce reports the background run outcome'
assert_contains "$out" 'kept scoutdone' 'enforce reports what it kept'
pass 'enforce closes through teardown in the background and keeps what teardown refuses'

# --- the kept-report backoff ----------------------------------------------
# An unchanged `kept` line reports once, then again only after an exponentially
# growing delay (FM_REAP_REPEAT_BASE_SECS doubling per repeat, capped), so a
# worker kept for days is a daily reminder, not a wake on every check pass. A
# changed teardown reason is a new line and resurfaces at once; `closed` is a
# one-time event and always prints. Only the report backs off - every check
# still starts the run that would surface either change.
BACKOFF_HOME="$TMP_ROOT/backoff"
mkdir -p "$BACKOFF_HOME/state" "$BACKOFF_HOME/config" "$BACKOFF_HOME/data"
export FM_HOME="$BACKOFF_HOME" FM_STATE_OVERRIDE="$BACKOFF_HOME/state" FM_CONFIG_OVERRIDE="$BACKOFF_HOME/config" FM_DATA_OVERRIDE="$BACKOFF_HOME/data"
printf 'kind=ship\nharness=claude\n' > "$BACKOFF_HOME/state/stuck.meta"
printf 'done [at=%s]: PR https://example.invalid/9\n' "$((now - 8000))" > "$BACKOFF_HOME/state/stuck.status"
printf 'enforce\n' > "$BACKOFF_HOME/config/reaper"
cat > "$TMP_ROOT/teardown2" <<'SH'
#!/usr/bin/env bash
case "$1" in
  stuck)
    if [ -e "$FM_STATE_OVERRIDE/stuck.meta.gone" ]; then
      rm -f "$FM_STATE_OVERRIDE/stuck.meta"
      printf 'tore down stuck\n'
      exit 0
    fi
    if [ -e "$FM_STATE_OVERRIDE/stuck.meta.new" ]; then
      printf 'error: CI still failing on the final job\n' >&2
      exit 1
    fi
    printf 'error: refusing - the worktree holds work that has not landed (2 commits)\n' >&2
    exit 1
    ;;
  *) printf 'error: unknown worker\n' >&2; exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/teardown2"
rlog="$BACKOFF_HOME/state/reaper-run.log"
run_done() {
  for ((i = 0; i < 100; i++)); do
    [ -s "$rlog" ] && [ ! -d "$BACKOFF_HOME/state/.reaper-run.lock" ] && return 0
    sleep 0.1
  done
  return 1
}
# One reporting check: report what the settled log holds, drain the run that
# check starts, and re-stamp the log so the next check reads a strictly newer
# log than the `.reaper-reported` marker it just wrote.
report_once() {
  local out
  out=$(FM_REAP_TEARDOWN="$TMP_ROOT/teardown2" "$REAP" check)
  run_done || fail "the background reaper run never finished"
  sleep 1.1
  touch "$rlog"
  printf '%s' "$out"
}
err=$(FM_REAP_REPEAT_BASE_SECS=abc "$REAP" check 2>&1) && fail 'a bad repeat base must refuse'
assert_contains "$err" 'FM_REAP_REPEAT_BASE_SECS must be whole seconds' 'the bad repeat base names itself'
err=$(FM_REAP_REPEAT_CAP_SECS=30 "$REAP" check 2>&1) && fail 'a repeat cap below the base must refuse'
assert_contains "$err" 'at least FM_REAP_REPEAT_BASE_SECS' 'the inverted repeat cap names itself'
FM_REAP_TEARDOWN="$TMP_ROOT/teardown2" "$REAP" check > /dev/null
run_done || fail "the first background run never finished"
sleep 1.1
touch "$rlog"
out=$(report_once)
assert_contains "$out" 'kept stuck: error: refusing - the worktree holds work that has not landed (2 commits)' 'the first kept report prints'
sleep 1
out=$(report_once)
assert_equals '' "$out" 'an unchanged kept line backs off instead of repeating every check'
# 2h past a 1h base: the second report is due; the delay doubles after it, so
# only 1h more is still inside the new 2h delay.
h=$(printf '%s' "kept stuck: error: refusing - the worktree holds work that has not landed (2 commits)" | cksum | cut -d' ' -f1)
backdate() {  # <age-seconds>
  awk -v h="$h" -v b=$(( $(date +%s) - $1 )) '$1 == h { $2 = b } { print }' \
    "$BACKOFF_HOME/state/.reaper-repeat" > "$BACKOFF_HOME/state/.reaper-repeat.new" && \
    mv -f "$BACKOFF_HOME/state/.reaper-repeat.new" "$BACKOFF_HOME/state/.reaper-repeat"
}
sleep 1
backdate 7200
out=$(report_once)
assert_contains "$out" 'kept stuck: error: refusing' 'a kept line past its base delay reports again'
sleep 1
backdate 3600
out=$(report_once)
assert_equals '' "$out" 'the repeat delay doubles: 1h past a 2h delay stays silent'
# High repeat counts cap at one day, rather than growing without bound.
awk '{ $3 = 20; print }' "$BACKOFF_HOME/state/.reaper-repeat" > "$BACKOFF_HOME/state/repeat.new"
mv "$BACKOFF_HOME/state/repeat.new" "$BACKOFF_HOME/state/.reaper-repeat"
backdate 86000
out=$(report_once)
assert_equals '' "$out" 'the daily reminder waits until a day has elapsed'
backdate 86401
out=$(report_once)
assert_contains "$out" 'kept stuck: error: refusing' 'the exponential delay caps at a daily reminder'
# A malformed ledger fails open instead of hiding the cleanup or crashing.
printf '%s invalid 2 kept stuck: error: refusing - the worktree holds work that has not landed (2 commits)\n' "$h" > "$BACKOFF_HOME/state/.reaper-repeat"
out=$(report_once)
assert_contains "$out" 'kept stuck: error: refusing' 'malformed repeat state reports again'
# A clock rollback cannot suppress reminders until a future ledger time.
backdate -7200
out=$(report_once)
assert_contains "$out" 'kept stuck: error: refusing' 'future repeat state fails open after clock rollback'
# A changed reason is a new line: it resurfaces at once and the ledger prunes
# the reason the log no longer names.
printf 'x\n' > "$BACKOFF_HOME/state/stuck.meta.new"
FM_REAP_TEARDOWN="$TMP_ROOT/teardown2" "$REAP" check > /dev/null
run_done || fail "the reason-change run never finished"
sleep 1.1
touch "$rlog"
out=$(report_once)
assert_contains "$out" 'kept stuck: error: CI still failing on the final job' 'a changed reason resurfaces at once'
grep -F "$h" "$BACKOFF_HOME/state/.reaper-repeat" >/dev/null && fail 'the repeat ledger must prune the old reason'
# `closed` is a one-time event: it prints, and a re-read prints it again.
printf 'x\n' > "$BACKOFF_HOME/state/stuck.meta.gone"
FM_REAP_TEARDOWN="$TMP_ROOT/teardown2" "$REAP" check > /dev/null
run_done || fail "the closing run never finished"
sleep 1.1
touch "$rlog"
out=$(report_once)
assert_contains "$out" 'closed stuck (done 2h ago)' 'a closed worker reports its close'
sleep 1.1
touch "$rlog"
out=$(FM_REAP_TEARDOWN="$TMP_ROOT/teardown2" "$REAP" check)
assert_contains "$out" 'closed stuck (done 2h ago)' 'a closed line is never gated by the repeat backoff'
pass 'the enforce report backs off unchanged kept lines, resurfaces on change, never gates closes'
# Restore the shared fixture home for the arm and sweep-state tests below.
export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_DATA_OVERRIDE="$HOME_DIR/data"
"$REAP" arm >/dev/null 2>&1 || true
assert_present "$HOME_DIR/state/reaper.check.sh" 'arm writes the watcher check'
assert_contains "$(<"$HOME_DIR/state/reaper.check.sh")" 'fm-reap.sh check' 'the check runs the reaper'
pass 'arm writes state/reaper.check.sh'

# sweep-state runs against its own fixture home so the task records above cannot
# colour its verdicts.
SWEEP_HOME="$TMP_ROOT/sweep"
SWEEP_STATE="$SWEEP_HOME/state"
mkdir -p "$SWEEP_STATE" "$SWEEP_HOME/config" "$SWEEP_HOME/data"
sweep() {
  FM_HOME="$SWEEP_HOME" FM_STATE_OVERRIDE="$SWEEP_STATE" FM_CONFIG_OVERRIDE="$SWEEP_HOME/config" \
    FM_DATA_OVERRIDE="$SWEEP_HOME/data" "$REAP" sweep-state "$@"
}
OLD_LOCK=$((now - 2 * 86400))
OLD_MARKER=$((now - 8 * 86400))
age() { touch -h -d "@$1" "$2"; }
owner() {  # <name> <age-epoch> [<file>=<value>...]
  local dir="$SWEEP_STATE/$1" stamp=$2 pair
  shift 2
  mkdir "$dir"
  for pair in "$@"; do printf '%s\n' "${pair#*=}" > "$dir/${pair%%=*}"; done
  age "$stamp" "$dir"
}
stray() {  # <owner-name> <link-target-name>; the shape a losing `ln -s` leaves
  ln -s "$SWEEP_STATE/$2" "$SWEEP_STATE/$1/$2"
  age "$OLD_LOCK" "$SWEEP_STATE/$1"
}
sleep 60 &
LIVE_PID=$!
sh -c 'exit 0' &
DEAD_PID=$!
wait "$DEAD_PID"

owner .wake-queue.lock.owner.released "$OLD_LOCK"
stray .wake-queue.lock.owner.released .wake-queue.lock.owner.gone1
stray .wake-queue.lock.owner.released .wake-queue.lock.owner.gone2
owner .wake-queue.lock.steal.owner.released "$OLD_LOCK"
stray .wake-queue.lock.steal.owner.released .wake-queue.lock.steal.owner.gone3
owner .wake-queue.lock.owner.empty "$OLD_LOCK"
owner .wake-queue.lock.owner.deadpid "$OLD_LOCK" "pid=$DEAD_PID" 'pid-start=proc-starttime=1' 'role=holder'
owner .wake-queue.lock.owner.reused "$OLD_LOCK" "pid=$LIVE_PID" 'pid-start=not-its-start-time'
owner .wake-queue.lock.owner.freshrelease "$now"
owner .wake-queue.lock.owner.freshdead "$now" "pid=$DEAD_PID"
owner .wake-queue.lock.owner.livepid "$OLD_LOCK" "pid=$LIVE_PID"
owner .watch.lock.owner.linkeddead "$OLD_LOCK" "pid=$DEAD_PID"
ln -s "$SWEEP_STATE/.watch.lock.owner.linkeddead" "$SWEEP_STATE/.watch.lock"
owner .wake-queue.lock.owner.linkedsteal "$OLD_LOCK"
ln -s "$SWEEP_STATE/.wake-queue.lock.owner.linkedsteal" "$SWEEP_STATE/.wake-queue.lock.steal"
owner .wake-queue.lock.owner.foreignfile "$OLD_LOCK" 'unexpected=1'
owner .wake-queue.lock.owner.badpid "$OLD_LOCK" 'pid=not-a-pid'
owner .wake-queue.lock.owner.livestray "$OLD_LOCK"
owner .wake-queue.lock.owner.straytarget "$OLD_LOCK" "pid=$LIVE_PID"
stray .wake-queue.lock.owner.livestray .wake-queue.lock.owner.straytarget
owner ".wake-queue.lock.owner.tomb.reaped.$DEAD_PID" "$OLD_LOCK"
mkdir "$SWEEP_STATE/.unrelated.lock" && age "$OLD_LOCK" "$SWEEP_STATE/.unrelated.lock"

printf 'window=personal:w1:p2\nkind=ship\n' > "$SWEEP_STATE/alive.meta"
printf 'window=personal:w1:p3\n' > "$SWEEP_STATE/prior.meta-prior"
printf 'backend=orca\nterminal=orca-term.7\n' > "$SWEEP_STATE/orca.meta"
printf 'stale personal:w9:p9 queued reason\n' > "$SWEEP_STATE/.wake-queue"
marker() { : > "$SWEEP_STATE/$1"; age "${2:-$OLD_MARKER}" "$SWEEP_STATE/$1"; }
for name in hash count stale stale-since churn-since dead-reported wedge-escalations paused-resurfaced; do
  marker ".$name-closed_w0_p1"
done
for name in .hash-personal_w1_p2 .stale-since-personal_w1_p2 .hash-personal_w1_p3 .hash-orca-term_7 .hash-personal_w9_p9; do
  marker "$name"
done
marker .hash-closed_w0_p2 "$now"
marker .home-summary.json.AbC123
marker .home-summary-error.Xy1234
marker .home-summary.json.Fresh1 "$now"
ln -s missing "$SWEEP_STATE/.hash-symlink_w0_p1"
# Everything else a sweep must never consider, however old.
marker .seen-procevent-6162
marker .seen-done-task_status
marker .home-summary-refresh.log
marker .backlog-handoff-task.wake-pending
marker .startup-growth-check
marker .hashes-not-a-family
printf 'done [at=1]: x\n' > "$SWEEP_STATE/closed.status"
age "$OLD_MARKER" "$SWEEP_STATE/closed.status"
mkdir -p "$SWEEP_STATE/closed.inbox/handled" "$SWEEP_STATE/terminal-outcomes"
: > "$SWEEP_STATE/closed.inbox/handled/1.msg"
age "$OLD_MARKER" "$SWEEP_STATE/.wake-queue"

snapshot() { (cd "$SWEEP_STATE" && find . | LC_ALL=C sort && ls -lAR --time-style=+%s .); }
before=$(snapshot)
out=$(sweep) || fail 'a dry run must succeed'
assert_equals "$before" "$(snapshot)" 'a default sweep changes nothing in the state folder'
assert_contains "$out" 'sweep-state: dry-run' 'the default mode is a dry run'
assert_contains "$out" 'would-remove lock-owner-released 3' 'a dry run counts released owners'
assert_contains "$out" 'would-remove lock-owner-dead-pid 2' 'a dry run counts dead and reused pids'
assert_contains "$out" 'would-remove window-marker 8' 'a dry run counts markers of closed windows'
assert_contains "$out" 'would-remove home-summary-temp 2' 'a dry run counts abandoned summary scratch'
assert_contains "$out" 'kept lock-owner-young 2' 'a recent owner may still be mid-acquire'
assert_contains "$out" 'kept lock-owner-live-pid 2' 'a live holder is kept'
assert_contains "$out" 'kept lock-owner-linked 2' 'an owner a lock or steal link names is kept even when dead'
assert_contains "$out" 'kept lock-owner-unknown-contents 3' 'unexplained contents and live stray targets are kept'
assert_contains "$out" 'kept lock-owner-reap-election 1' 'a reap election tomb is kept'
assert_contains "$out" 'kept window-marker-recorded-task 4' 'markers of recorded windows, including prior and orca records, are kept'
assert_contains "$out" 'kept window-marker-queued-wake 1' 'a marker with an unacknowledged wake is kept'
assert_contains "$out" 'kept window-marker-young 1' 'a recent marker is kept'
assert_contains "$out" 'kept home-summary-temp-young 1' 'recent summary scratch is kept'
assert_contains "$out" 'total would-remove=15 removed=0 failed=0 kept=17' 'the dry run totals every kind'
assert_not_contains "$out" "$SWEEP_STATE/.hash-" 'plain output is counts, not entries'
assert_contains "$(sweep --verbose)" "would-remove window-marker $SWEEP_STATE/.hash-closed_w0_p1" 'verbose names each entry'
pass 'sweep-state: a default dry run counts by kind and changes nothing'

err=$(sweep --force 2>&1) && fail 'an unknown flag must refuse'
assert_contains "$err" 'unknown argument --force; nothing changed' 'an unknown flag refuses rather than running'
mkdir "$SWEEP_STATE/broken.meta"
err=$(sweep --apply 2>&1) && fail 'an unreadable record must refuse the sweep'
assert_contains "$err" 'unreadable task record' 'an unreadable record names itself'
rmdir "$SWEEP_STATE/broken.meta"
assert_equals "$before" "$(snapshot)" 'a refused sweep changes nothing'
pass 'sweep-state: an unknown flag or an unreadable task record refuses before any change'

out=$(sweep --apply) || fail "an apply run must succeed: $out"
assert_contains "$out" 'total would-remove=0 removed=15 failed=0 kept=17' 'apply removes what the dry run listed'
for gone in .wake-queue.lock.owner.released .wake-queue.lock.steal.owner.released .wake-queue.lock.owner.empty \
  .wake-queue.lock.owner.deadpid .wake-queue.lock.owner.reused .hash-closed_w0_p1 .count-closed_w0_p1 \
  .stale-closed_w0_p1 .stale-since-closed_w0_p1 .dead-reported-closed_w0_p1 .home-summary.json.AbC123 .home-summary-error.Xy1234; do
  [ ! -e "$SWEEP_STATE/$gone" ] || fail "$gone should be removed"
done
for kept in .wake-queue.lock.owner.freshrelease .wake-queue.lock.owner.freshdead .wake-queue.lock.owner.livepid \
  .watch.lock.owner.linkeddead .watch.lock .wake-queue.lock.owner.linkedsteal .wake-queue.lock.steal \
  .wake-queue.lock.owner.foreignfile/unexpected .wake-queue.lock.owner.badpid/pid .wake-queue.lock.owner.livestray \
  .wake-queue.lock.owner.straytarget/pid ".wake-queue.lock.owner.tomb.reaped.$DEAD_PID" .unrelated.lock \
  .hash-personal_w1_p2 .stale-since-personal_w1_p2 .hash-personal_w1_p3 .hash-orca-term_7 .hash-personal_w9_p9 .hash-closed_w0_p2 \
  .home-summary.json.Fresh1 .seen-procevent-6162 .seen-done-task_status .home-summary-refresh.log \
  .backlog-handoff-task.wake-pending .startup-growth-check .hashes-not-a-family .wake-queue \
  closed.status closed.inbox/handled/1.msg terminal-outcomes alive.meta prior.meta-prior; do
  [ -e "$SWEEP_STATE/$kept" ] || [ -L "$SWEEP_STATE/$kept" ] || fail "$kept must survive the sweep"
done
[ -L "$SWEEP_STATE/.hash-symlink_w0_p1" ] || fail 'a symlink is never followed or removed as a marker'
pass 'sweep-state: --apply removes only proven entries and leaves every protected record'

out=$(sweep --apply) || fail "a repeat apply must succeed: $out"
assert_contains "$out" 'total would-remove=0 removed=0 failed=0 kept=17' 'a repeat sweep converges'
pass 'sweep-state: a repeat sweep has nothing left to remove'

# A real lock acquired through the library must read as held, and stay protected
# by its link after its holder dies.
FM_STATE_OVERRIDE="$SWEEP_STATE" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$FM_STATE_OVERRIDE/.real.lock" || exit 1; exec 3>&-; : > "$FM_STATE_OVERRIDE/acquired"; sleep 60' _ "$ROOT" &
HOLDER=$!
for ((i = 0; i < 100; i++)); do [ -e "$SWEEP_STATE/acquired" ] && break; sleep 0.05; done
assert_present "$SWEEP_STATE/acquired" 'the fixture lock was acquired'
real_owner=$(readlink "$SWEEP_STATE/.real.lock")
age "$OLD_LOCK" "$real_owner"
assert_contains "$(sweep --verbose)" "kept lock-owner-linked $real_owner" 'a real held lock is kept'
kill "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
age "$OLD_LOCK" "$real_owner"
out=$(sweep --apply --verbose)
assert_contains "$out" "kept lock-owner-linked $real_owner" 'a dead holder still linked is left to the lock takeover path'
rm -f "$SWEEP_STATE/.real.lock"
age "$OLD_LOCK" "$real_owner"
assert_contains "$(sweep --apply --verbose)" "removed lock-owner-dead-pid $real_owner" 'the real owner format is understood once nothing links it'
pass 'sweep-state: a real library lock is protected while linked and removable once abandoned'

err=$(FM_REAP_LOCK_AGE_SECS=soon "$REAP" sweep-state 2>&1) && fail 'a bad threshold must refuse'
assert_contains "$err" 'FM_REAP_LOCK_AGE_SECS must be whole seconds' 'a bad threshold names itself'
ln -s "$SWEEP_STATE" "$TMP_ROOT/state-link"
err=$(FM_STATE_OVERRIDE="$TMP_ROOT/state-link" "$REAP" sweep-state 2>&1) && fail 'a symlinked state must refuse'
assert_contains "$err" 'state directory unavailable' 'a symlinked state refuses'
pass 'sweep-state: bad thresholds and a symlinked state refuse'
# A lane that never wrote done but finished its work (passed gate, PR ready or
# merged) is due once idle, and only then. Its own home keeps the earlier cases'
# shadow report untouched.
FIN="$TMP_ROOT/finished"
mkdir -p "$FIN/state" "$FIN/config" "$FIN/data"
SHA=0123456789abcdef0123456789abcdef01234567
fin_lane() {  # <id> <idle-secs> <milestone-name>... (each "name:extra" milestone line body)
  local id=$1 idle=$2 m name rest line
  shift 2
  printf 'kind=ship\nharness=claude\n' > "$FIN/state/$id.meta"
  : > "$FIN/state/$id.status"
  for m in "$@"; do
    name=${m%%:*}
    rest=${m#*:}
    case "$name" in
      gate-end) line="milestone [name=gate-end] [at=$((now - 20000))] [sha=$SHA] [run=r1] [rounds=1] [result=$rest]: gate" ;;
      gate-start) line="milestone [name=gate-start] [at=$((now - 10000))] [sha=$SHA] [run=r2]: gate" ;;
      pr-created) line="milestone [name=pr-created] [at=$((now - 19000))] [sha=$SHA]: PR https://example.invalid/pr/1" ;;
      merge) line="milestone [name=merge] [at=$((now - 18000))] [sha=$SHA]: PR https://example.invalid/pr/1" ;;
    esac
    printf '%s\n' "$line" >> "$FIN/state/$id.status"
  done
  printf 'working [at=%s]: waiting\n' "$((now - idle))" >> "$FIN/state/$id.status"
  touch -d "@$((now - idle))" "$FIN/state/$id.status"
}
fin_list() { FM_STATE_OVERRIDE="$FIN/state" FM_CONFIG_OVERRIDE="$FIN/config" FM_DATA_OVERRIDE="$FIN/data" "$REAP" list; }
fin_lane ready-idle 8000 gate-end:passed pr-created:
fin_lane merged-idle 8000 gate-end:passed merge:
fin_lane ready-fresh 600 gate-end:passed pr-created:
fin_lane no-gate 8000 pr-created:
fin_lane gate-failed 8000 gate-end:failed pr-created:
fin_lane no-pr 8000 gate-end:passed
fin_lane regated 8000 gate-end:passed pr-created: gate-start:
out=$(fin_list)
assert_contains "$out" 'ready-idle due gate passed, PR ready, idle 2h' 'a passed gate with a ready PR, idle 2h, is due'
assert_contains "$out" 'merged-idle due gate passed, PR merged, idle 2h' 'a passed gate with a merged PR, idle 2h, is due'
assert_contains "$out" 'ready-fresh active working' 'a finished lane that is not yet idle 2h stays active'
assert_contains "$out" 'no-gate active working' 'a PR without a passed gate is not due'
assert_contains "$out" 'gate-failed active working' 'a failed gate is not due'
assert_contains "$out" 'no-pr active working' 'a passed gate without a PR is not due'
assert_contains "$out" 'regated active working' 'a gate restarted after the pass is rework, not due'
printf 'kind=ship\nharness=claude\n' > "$FIN/state/blocked-idle.meta"
printf 'milestone [name=gate-end] [at=%s] [sha=%s] [run=r1] [rounds=1] [result=passed]: gate\nmilestone [name=pr-created] [at=%s] [sha=%s]: PR https://example.invalid/pr/1\nblocked [at=%s]: need a key\n' \
  "$((now - 20000))" "$SHA" "$((now - 19000))" "$SHA" "$((now - 8000))" > "$FIN/state/blocked-idle.status"
touch -d "@$((now - 8000))" "$FIN/state/blocked-idle.status"
printf 'kind=ship\nharness=claude\n' > "$FIN/state/garbled.meta"
printf 'milestone [name=gate-end] [at=%s]: no sha or run\nworking [at=%s]: x\n' "$((now - 20000))" "$((now - 8000))" > "$FIN/state/garbled.status"
touch -d "@$((now - 8000))" "$FIN/state/garbled.status"
out=$(fin_list)
assert_contains "$out" 'blocked-idle active blocked' 'a blocked lane is left for firstmate even with a passed gate'
assert_contains "$out" 'garbled active working' 'a malformed milestone record is never due'
pass 'verdicts: a lane with a passed gate and ready or merged PR is due once idle 2h, and nothing else is'

# Shadow reports it; enforce hands it to teardown, which keeps unlanded work.
printf 'shadow\n' > "$FIN/config/reaper"
out=$(FM_STATE_OVERRIDE="$FIN/state" FM_CONFIG_OVERRIDE="$FIN/config" FM_DATA_OVERRIDE="$FIN/data" "$REAP" check)
assert_contains "$out" 'reap (shadow, nothing closed): 2 finished worker(s)' 'shadow reports the idle finished lanes in the reap check wake'
assert_contains "$out" 'ready-idle gate passed, PR ready, idle 2h' 'the wake names the lane and why'
cat > "$TMP_ROOT/teardown-unlanded" <<'SH'
#!/usr/bin/env bash
case "$1" in
  merged-idle) printf 'tore down %s\n' "$1" ;;
  *) printf 'error: refusing - the worktree holds work that has not landed (1 commit)\n' >&2; exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/teardown-unlanded"
out=$(FM_STATE_OVERRIDE="$FIN/state" FM_CONFIG_OVERRIDE="$FIN/config" FM_DATA_OVERRIDE="$FIN/data" FM_REAP_TEARDOWN="$TMP_ROOT/teardown-unlanded" "$REAP" run)
assert_contains "$out" 'closed merged-idle (gate passed, PR merged, idle 2h)' 'a landed finished lane is closed'
assert_contains "$out" 'kept ready-idle: error: refusing - the worktree holds work that has not landed' 'an unlanded finished lane is kept, never discarded'
assert_present "$FIN/state/ready-idle.meta" 'the kept lane keeps its record'
pass 'reap: finished-but-not-done lanes reach the check wake and teardown alone decides what lands'

# --- the merged fast path ----------------------------------------------------
# A lane whose PR merged and whose worktree is clean is due at once: done
# without the 2h wait, a finished-but-working lane without the idle wait. A
# dirty or missing worktree falls back to the timed waits; a registered board
# keeps its grace; a merge without a clean tree never closes anything by
# itself - teardown stays the judge of landed work.
MERGED="$TMP_ROOT/merged"
mkdir -p "$MERGED/state" "$MERGED/config" "$MERGED/data"
mwt="$MERGED/wt-clean"
git init -q "$mwt"
git -C "$mwt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
mkdir -p "$MERGED/state/procevent"
mwt2="$MERGED/wt-dirty"
git init -q "$mwt2"
git -C "$mwt2" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
touch "$mwt2/untracked"
mmerged() {  # <id> <worktree-or-empty> <status lines...>
  local id=$1 wt=$2
  shift 2
  printf 'kind=ship\nharness=claude\nworktree=%s\n' "$wt" > "$MERGED/state/$id.meta"
  printf 'milestone [name=gate-end] [at=%s] [sha=%s] [run=r1] [rounds=1] [result=passed]: gate\nmilestone [name=pr-created] [at=%s] [sha=%s]: PR https://example.invalid/pr/1\nmilestone [name=merge] [at=%s] [sha=%s]: PR https://example.invalid/pr/1\n%s\n' \
    "$((now - 20000))" "$SHA" "$((now - 19000))" "$SHA" "$((now - 18000))" "$SHA" "$1" > "$MERGED/state/$id.status"
  shift
  printf '%s\n' "$@" >> "$MERGED/state/$id.status"
}
merged_list() { FM_STATE_OVERRIDE="$MERGED/state" FM_CONFIG_OVERRIDE="$MERGED/config" FM_DATA_OVERRIDE="$MERGED/data" "$REAP" list; }
mmerged fresh-done "$mwt" "done [at=$((now - 300))]: PR https://example.invalid/pr/1"
mmerged stale-done-dirty "$mwt2" "done [at=$((now - 9000))]: PR https://example.invalid/pr/1"
mmerged fresh-done-dirty "$mwt2" "done [at=$((now - 300))]: PR https://example.invalid/pr/1"
mmerged fresh-working "$mwt" "working [at=$((now - 600))]: waiting"
touch -d "@$((now - 600))" "$MERGED/state/fresh-working.status"
mmerged stale-working-dirty "$mwt2" "working [at=$((now - 9000))]: waiting"
touch -d "@$((now - 9000))" "$MERGED/state/stale-working-dirty.status"
printf 'kind=ship\nharness=claude\nworktree=%s\n' "$mwt" > "$MERGED/state/no-merge.meta"
printf 'milestone [name=pr-created] [at=%s] [sha=%s]: PR https://example.invalid/pr/1\ndone [at=%s]: PR https://example.invalid/pr/1\n' \
  "$((now - 19000))" "$SHA" "$((now - 300))" > "$MERGED/state/no-merge.status"
printf 'kind=ship\nharness=claude\nworktree=%s\n' "$MERGED/wt-gone" > "$MERGED/state/gone-wt.meta"
printf 'milestone [name=merge] [at=%s] [sha=%s]: PR https://example.invalid/pr/1\ndone [at=%s]: PR https://example.invalid/pr/1\n' \
  "$((now - 18000))" "$SHA" "$((now - 300))" > "$MERGED/state/gone-wt.status"
printf 'kind=ship\nharness=claude\nworktree=%s\n' "$mwt" > "$MERGED/state/boarded.meta"
printf 'milestone [name=merge] [at=%s] [sha=%s]: PR https://example.invalid/pr/1\ndone [at=%s]: PR https://example.invalid/pr/1\n' \
  "$((now - 18000))" "$SHA" "$((now - 300))" > "$MERGED/state/boarded.status"
printf 'adapter=lavish\nkind=task-owned\nowner_task=boarded\n' > "$MERGED/state/procevent/lavish-b.source"
out=$(merged_list)
assert_contains "$out" 'fresh-done due done 5m ago, PR merged, worktree clean' 'a merged, clean, done lane is due at once, not in 2h'
assert_contains "$out" 'stale-done-dirty due done 2h ago' 'a merged lane past its done time is due through the ordinary wait'
assert_contains "$out" 'fresh-done-dirty waiting done 5m ago, closes in 115m' 'a dirty worktree keeps the done wait'
assert_contains "$out" 'fresh-working due gate passed, PR merged, worktree clean' 'a merged, clean, finished lane is due without idling 2h'
assert_contains "$out" 'stale-working-dirty due gate passed, PR merged, idle 2h' 'a dirty finished lane is due through its idle wait'
assert_contains "$out" 'no-merge waiting done 5m ago, closes in 115m' 'a clean lane without a merge keeps the done wait'
assert_contains "$out" 'gone-wt waiting done 5m ago, closes in 115m' 'a missing worktree keeps the done wait'
assert_contains "$out" 'boarded waiting done 5m ago board, closes in 1435m' 'a registered board keeps its grace over a merged PR'
pass 'verdicts: merged and clean closes at once; dirty, unmerged, missing, and boarded lanes keep their waits'

# Enforce closes the merged lane at once through teardown, nothing else.
printf 'shadow\n' > "$MERGED/config/reaper"
out=$(FM_STATE_OVERRIDE="$MERGED/state" FM_CONFIG_OVERRIDE="$MERGED/config" FM_DATA_OVERRIDE="$MERGED/data" "$REAP" check)
assert_contains "$out" 'reap (shadow, nothing closed): 4 finished worker(s)' 'shadow reports the merged fast lanes'
cat > "$TMP_ROOT/teardown-merged" <<SH
#!/usr/bin/env bash
case "\$1" in
  fresh-done|fresh-working) printf 'tore down %s\n' "\$1" ;;
  *) printf 'error: refusing - the worktree holds work that has not landed (1 commit)\n' >&2; exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/teardown-merged"
out=$(FM_STATE_OVERRIDE="$MERGED/state" FM_CONFIG_OVERRIDE="$MERGED/config" FM_DATA_OVERRIDE="$MERGED/data" \
  FM_REAP_TEARDOWN="$TMP_ROOT/teardown-merged" "$REAP" run)
assert_contains "$out" 'closed fresh-done (done 5m ago, PR merged, worktree clean)' 'a merged clean done lane is closed at once'
assert_contains "$out" 'closed fresh-working (gate passed, PR merged, worktree clean)' 'a merged clean finished lane is closed at once'
assert_contains "$out" 'kept stale-done-dirty: error: refusing - the worktree holds work that has not landed (1 commit)' 'teardown alone decides a dirty merged lane'
pass 'reap: the merged fast path closes clean lanes through teardown and keeps the rest'

kill "$LIVE_PID" 2>/dev/null
wait "$LIVE_PID" 2>/dev/null
echo '# all fm-reap tests passed'
