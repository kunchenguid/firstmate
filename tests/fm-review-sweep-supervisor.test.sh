#!/usr/bin/env bash
# tests/fm-review-sweep-supervisor.test.sh - durable half-hour sweep scheduling.
#
# Exercises the public installer, slot calculator, LaunchAgent renderer, tick,
# receipt gate, overlap exclusion, retry, recovery, status, and uninstall paths
# against an isolated Firstmate-shaped home and fake Codex/launchctl processes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_eq() { # <expected> <actual> <message>
  [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"
}

TMP_ROOT=$(fm_test_tmproot fm-review-sweep-supervisor)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
CASE_HOME="$TMP_ROOT/account"
CASE_APP="$TMP_ROOT/app"
CASE_SOURCE="$TMP_ROOT/source"
CASE_BIN="$TMP_ROOT/bin"
CASE_LAUNCH_AGENT_DIR="$CASE_HOME/Library/LaunchAgents"
CASE_LOG_DIR="$CASE_HOME/Library/Logs"
CASE_LAUNCH_STATE="$TMP_ROOT/launch-state"
CASE_CODEX_LOG="$TMP_ROOT/codex.log"
CASE_CODEX_COUNT="$TMP_ROOT/codex.count"
CASE_CODEX_FAIL="$TMP_ROOT/codex.fail"
CASE_CODEX_OMIT_RECEIPT="$TMP_ROOT/codex.omit-receipt"
SUBJECT="$ROOT/bin/fm-review-sweep-supervisor.sh"
mkdir -p "$CASE_HOME" "$CASE_BIN" "$CASE_LAUNCH_STATE"
: > "$CASE_CODEX_LOG"
printf '0\n' > "$CASE_CODEX_COUNT"

cat > "$CASE_BIN/launchctl" <<'SH'
#!/usr/bin/env bash
set -u
command=${1:-}
target=${2:-}
loaded="$FM_FAKE_LAUNCH_STATE/loaded"
case $command in
  print)
    case $target in
      */dev.firstmate.review-sweep)
        [ -f "$loaded" ] || exit 113
        cat "$loaded"
        ;;
      *) exit 0 ;;
    esac
    ;;
  bootout)
    rm -f -- "$loaded"
    ;;
  bootstrap)
    plist=${3:-}
    cat > "$loaded" <<EOF
path = $plist
program = $FM_FAKE_RUNTIME_SCRIPT
EOF
    ;;
  kickstart) ;;
  *) exit 2 ;;
esac
SH

cat > "$CASE_BIN/codex" <<'SH'
#!/usr/bin/env bash
set -u
out=
prompt=
while [ "$#" -gt 0 ]; do
  case $1 in
    -o) out=${2:-}; shift 2 ;;
    *) prompt=$1; shift ;;
  esac
done
slot=$(printf '%s\n' "$prompt" | sed -n 's/^Run the private \/nt-review-sweep skill for scheduled slot \([^.]\{1,80\}\)[.]$/\1/p')
[ -n "$slot" ] || { printf 'missing slot in prompt\n' >&2; exit 8; }
count=$(sed -n '1p' "$FM_FAKE_CODEX_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_FAKE_CODEX_COUNT"
printf 'slot=%s\n%s\n' "$slot" "$prompt" >> "$FM_FAKE_CODEX_LOG"
if [ -f "$FM_FAKE_CODEX_FAIL" ]; then exit 9; fi
if [ -f "$FM_FAKE_CODEX_OMIT_RECEIPT" ]; then
  printf 'unreceipted result for %s\n' "$slot" > "$out"
  exit 0
fi
mkdir -p "$FM_HOME/state/review-sweep-cycle-receipts"
cat > "$FM_HOME/state/review-sweep-cycle-receipts/$slot.json" <<EOF
{"version":1,"slot":"$slot","coverage":"complete","discovered":0,"reviewed":0,"skipped":0,"failed":0,"comments_published":0,"slack_messages_sent":0,"tasks_left_in_flight":0,"reviews":[]}
EOF
printf 'verified no-op for %s\n' "$slot" > "$out"
SH

chmod +x "$CASE_BIN/launchctl" "$CASE_BIN/codex"

mkdir -p "$CASE_SOURCE/bin" "$CASE_SOURCE/data" "$CASE_SOURCE/config" "$CASE_SOURCE/projects"
cp "$ROOT/AGENTS.md" "$CASE_SOURCE/AGENTS.md"
cp "$ROOT/.gitignore" "$CASE_SOURCE/.gitignore"
cp "$ROOT/.tasks.toml" "$CASE_SOURCE/.tasks.toml"
cp "$ROOT/bin/fm-session-start.sh" "$CASE_SOURCE/bin/fm-session-start.sh"
cp "$ROOT/bin/fm-config-inherit-lib.sh" "$CASE_SOURCE/bin/fm-config-inherit-lib.sh"
cp "$ROOT/bin/fm-startup-memory-budget-lib.sh" "$CASE_SOURCE/bin/fm-startup-memory-budget-lib.sh"
cp "$ROOT/bin/fm-project-origin-lib.sh" "$CASE_SOURCE/bin/fm-project-origin-lib.sh"
chmod +x "$CASE_SOURCE/bin/fm-session-start.sh"
printf '# Projects\n' > "$CASE_SOURCE/data/projects.md"
printf '# Captain test preferences\n' > "$CASE_SOURCE/data/captain.md"
printf '# Test learning\n' > "$CASE_SOURCE/data/learnings.md"
git -C "$CASE_SOURCE" init -q
git -C "$CASE_SOURCE" symbolic-ref HEAD refs/heads/main
git -C "$CASE_SOURCE" add AGENTS.md .gitignore .tasks.toml bin
git -C "$CASE_SOURCE" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial

run_subject() {
  HOME="$CASE_HOME" \
  PATH="$CASE_BIN:$PATH" \
  FM_REVIEW_SWEEP_APP_ROOT="$CASE_APP" \
  FM_REVIEW_SWEEP_LAUNCH_AGENT_DIR="$CASE_LAUNCH_AGENT_DIR" \
  FM_REVIEW_SWEEP_LOG_DIR="$CASE_LOG_DIR" \
  FM_REVIEW_SWEEP_LAUNCHCTL="$CASE_BIN/launchctl" \
  FM_FAKE_LAUNCH_STATE="$CASE_LAUNCH_STATE" \
  FM_FAKE_RUNTIME_SCRIPT="$CASE_APP/runtime/fm-review-sweep-supervisor.sh" \
  FM_FAKE_CODEX_LOG="$CASE_CODEX_LOG" \
  FM_FAKE_CODEX_COUNT="$CASE_CODEX_COUNT" \
  FM_FAKE_CODEX_FAIL="$CASE_CODEX_FAIL" \
  FM_FAKE_CODEX_OMIT_RECEIPT="$CASE_CODEX_OMIT_RECEIPT" \
  "$SUBJECT" "$@"
}

run_tick() { # <clock fields>
  FM_REVIEW_SWEEP_NOW_FIELDS=$1 run_subject tick
}

INSTALL_OUT=$(run_subject install --source-home "$CASE_SOURCE") || fail "install failed: $INSTALL_OUT"
assert_contains "$INSTALL_OUT" 'max-concurrent-reviews: 10' 'install did not report the ten-review cap'
assert_present "$CASE_APP/config/supervisor.conf" 'private config was not installed'
assert_present "$CASE_APP/home/config/review-sweep-host-contract" 'host-job contract was not installed'
assert_present "$CASE_LAUNCH_AGENT_DIR/dev.firstmate.review-sweep.plist" 'LaunchAgent was not installed'
assert_grep '<key>StartInterval</key>' "$CASE_LAUNCH_AGENT_DIR/dev.firstmate.review-sweep.plist" 'LaunchAgent lacks its minute-level durable tick'
assert_grep '<integer>60</integer>' "$CASE_LAUNCH_AGENT_DIR/dev.firstmate.review-sweep.plist" 'LaunchAgent tick is not one minute'
assert_grep '<key>LimitLoadToSessionType</key>' "$CASE_LAUNCH_AGENT_DIR/dev.firstmate.review-sweep.plist" 'LaunchAgent is not Aqua-scoped'
assert_grep 'max_concurrent_reviews=10' "$CASE_APP/config/supervisor.conf" 'private config did not persist max concurrency 10'
assert_grep 'max_concurrent_reviews=10' "$CASE_APP/home/config/review-sweep-host-contract" 'host contract did not authorize max concurrency 10'
pass 'install persists the isolated home, authorization, ten-review cap, and Aqua LaunchAgent'

set +e
BEFORE_OUT=$(run_subject slot-at 20260826 06 59 2>&1)
BEFORE_RC=$?
set -e
assert_eq 3 "$BEFORE_RC" 'pre-window slot calculation should report no due slot'
assert_eq '' "$BEFORE_OUT" 'pre-window slot calculation should print nothing'
assert_eq '20260826-0700' "$(run_subject slot-at 20260826 07 00)" '07:00 slot was not selected'
assert_eq '20260826-0700' "$(run_subject slot-at 20260826 07 29)" '07:29 should still select 07:00'
assert_eq '20260826-0730' "$(run_subject slot-at 20260826 07 30)" '07:30 slot was not selected'
assert_eq '20260826-1700' "$(run_subject slot-at 20260826 17 30)" '17:30 must coalesce to the final 17:00 slot'
assert_eq '20260826-1700' "$(run_subject slot-at 20260826 23 59)" 'same-day late wake did not catch the final slot'
pass 'slot calculation honors the Chicago window and final 17:00 boundary'

cat > "$CASE_BIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$CASE_BIN/sleep"

TICK_OUT=$(run_tick '20260826 07 29 1000 -0500') || fail "first tick failed: $TICK_OUT"
assert_contains "$TICK_OUT" 'complete: slot=20260826-0700 status=succeeded' 'first due slot did not complete'
assert_eq 1 "$(sed -n '1p' "$CASE_CODEX_COUNT")" 'first due slot did not invoke Codex exactly once'
assert_grep 'maximum of 10 concurrent independent PR reviews' "$CASE_CODEX_LOG" 'cycle prompt did not carry approved large-swarm cap'
assert_grep 'publication-and-Slack notification sequence' "$CASE_CODEX_LOG" 'cycle prompt did not bind publication to notification'
assert_grep "Do not finish while this home's state contains task metadata" "$CASE_CODEX_LOG" 'cycle prompt did not require teardown'
assert_present "$CASE_APP/home/state/review-sweep-cycle-receipts/20260826-0700.json" 'cycle receipt was not retained'
pass 'a due slot runs once and requires publication, notification, receipt, and teardown'

SECOND_OUT=$(run_tick '20260826 07 29 1001 -0500') || fail "repeat tick failed: $SECOND_OUT"
assert_contains "$SECOND_OUT" 'noop: slot 20260826-0700 already succeeded' 'successful slot was not deduplicated'
assert_eq 1 "$(sed -n '1p' "$CASE_CODEX_COUNT")" 'successful slot ran twice'
THIRD_OUT=$(run_tick '20260826 07 30 1002 -0500') || fail "next slot failed: $THIRD_OUT"
assert_contains "$THIRD_OUT" 'complete: slot=20260826-0730 status=succeeded' 'next half-hour slot did not run'
assert_eq 2 "$(sed -n '1p' "$CASE_CODEX_COUNT")" 'next half-hour slot did not invoke Codex'
pass 'slot ledger deduplicates successes and advances on the half hour'

mkdir -p "$CASE_APP/state/run.lock"
printf '%s\n' "$$" > "$CASE_APP/state/run.lock/owner"
cat > "$CASE_BIN/ps" <<'SH'
#!/usr/bin/env bash
printf '/bin/bash /fixture/fm-review-sweep-supervisor.sh tick\n'
SH
chmod +x "$CASE_BIN/ps"
BUSY_OUT=$(run_tick '20260826 08 00 2000 -0500') || fail "busy tick should be a safe no-op: $BUSY_OUT"
assert_contains "$BUSY_OUT" 'busy: review-sweep cycle already owned' 'live owner did not exclude overlap'
assert_eq 2 "$(sed -n '1p' "$CASE_CODEX_COUNT")" 'overlapping tick started another cycle'
rm -f -- "$CASE_APP/state/run.lock/owner"
rmdir -- "$CASE_APP/state/run.lock"
rm -f -- "$CASE_BIN/ps"
pass 'a live owner excludes overlapping scheduled or manual cycles'

touch "$CASE_CODEX_FAIL"
set +e
FAIL_OUT=$(run_tick '20260826 08 00 3000 -0500' 2>&1)
FAIL_RC=$?
set -e
assert_eq 9 "$FAIL_RC" 'failed Codex cycle exit was not preserved'
assert_contains "$FAIL_OUT" 'status=failed exit=9 retry-after=300' 'failed slot did not publish retry state'
assert_eq 3 "$(sed -n '1p' "$CASE_CODEX_COUNT")" 'failed slot did not run exactly once'
DEFER_OUT=$(run_tick '20260826 08 00 3100 -0500') || fail "deferred retry failed: $DEFER_OUT"
assert_contains "$DEFER_OUT" 'deferred: slot 20260826-0800 retry is due at epoch 3300' 'retry throttle was not enforced'
assert_eq 3 "$(sed -n '1p' "$CASE_CODEX_COUNT")" 'retry ran before its deadline'
rm -f -- "$CASE_CODEX_FAIL"
RECOVER_OUT=$(run_tick '20260826 08 00 3301 -0500') || fail "retry recovery failed: $RECOVER_OUT"
assert_contains "$RECOVER_OUT" 'attempt=2' 'failed slot did not resume as its second attempt'
assert_contains "$RECOVER_OUT" 'status=succeeded' 'retried slot did not succeed'
assert_eq 4 "$(sed -n '1p' "$CASE_CODEX_COUNT")" 'retried slot did not invoke Codex once'
pass 'failed slots throttle retries and recover without losing slot identity'

mkdir -p "$CASE_APP/state/slots/20260826-0830"
printf '1\n' > "$CASE_APP/state/slots/20260826-0830/attempt"
printf 'running\n' > "$CASE_APP/state/slots/20260826-0830/status"
CRASH_OUT=$(run_tick '20260826 08 45 4000 -0500') || fail "crash recovery failed: $CRASH_OUT"
assert_contains "$CRASH_OUT" 'slot=20260826-0830 attempt=2' 'abandoned running slot was not recovered'
assert_contains "$CRASH_OUT" 'status=succeeded' 'recovered running slot did not finish'
pass 'an abandoned running slot is recovered after process failure'

touch "$CASE_CODEX_OMIT_RECEIPT"
set +e
RECEIPT_OUT=$(run_tick '20260826 09 00 6000 -0500' 2>&1)
RECEIPT_RC=$?
set -e
assert_eq 74 "$RECEIPT_RC" 'missing cycle receipt should fail the slot'
assert_contains "$RECEIPT_OUT" 'did not publish its cycle receipt' 'missing receipt failure was not explicit'
assert_eq 6 "$(sed -n '1p' "$CASE_CODEX_COUNT")" 'missing-receipt case did not run exactly once'
rm -f -- "$CASE_CODEX_OMIT_RECEIPT"
RECEIPT_RECOVER_OUT=$(run_tick '20260826 09 00 6301 -0500') || fail "receipt retry failed: $RECEIPT_RECOVER_OUT"
assert_contains "$RECEIPT_RECOVER_OUT" 'slot=20260826-0900 attempt=2' 'receipt failure did not retry the same slot'
assert_contains "$RECEIPT_RECOVER_OUT" 'status=succeeded' 'receipt retry did not succeed'
assert_eq 7 "$(sed -n '1p' "$CASE_CODEX_COUNT")" 'receipt retry did not invoke Codex once'
pass 'a cycle cannot succeed without its publication and notification receipt'

NOOP_OUT=$(run_tick '20260827 06 59 5000 -0500') || fail "pre-window tick failed: $NOOP_OUT"
assert_contains "$NOOP_OUT" 'noop: no review-sweep slot is due' 'next-day pre-window tick replayed yesterday'
assert_eq 7 "$(sed -n '1p' "$CASE_CODEX_COUNT")" 'next-day pre-window tick invoked Codex'
pass 'catch-up stays within the current Chicago calendar day'

STATUS_OUT=$(run_subject status) || fail "status failed: $STATUS_OUT"
assert_contains "$STATUS_OUT" 'launchagent-loaded: yes' 'status did not verify the loaded LaunchAgent'
assert_contains "$STATUS_OUT" 'max-concurrent-reviews: 10' 'status did not report the configured cap'
assert_contains "$STATUS_OUT" 'automation-inflight: 0' 'status did not verify terminal task metadata'
pass 'status reports the loaded job, schedule cap, and terminal metadata'

UNINSTALL_OUT=$(run_subject uninstall) || fail "uninstall failed: $UNINSTALL_OUT"
assert_contains "$UNINSTALL_OUT" "retained-runtime: $CASE_APP" 'uninstall did not report retained recoverable state'
assert_absent "$CASE_LAUNCH_AGENT_DIR/dev.firstmate.review-sweep.plist" 'uninstall left the LaunchAgent property list'
assert_present "$CASE_APP/config/supervisor.conf" 'uninstall destroyed private configuration'
assert_present "$CASE_APP/home/state/review-sweep-cycle-receipts/20260826-0830.json" 'uninstall destroyed review receipts'
pass 'uninstall removes only the LaunchAgent and retains durable records'
