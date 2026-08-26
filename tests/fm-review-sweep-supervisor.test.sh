#!/usr/bin/env bash
# tests/fm-review-sweep-supervisor.test.sh - durable half-hour sweep scheduling.
#
# Exercises the public installer, source-home validation, pinned default-branch
# synchronization, slot calculator, LaunchAgent renderer, tick, receipt gate,
# overlap exclusion, ownerless-lock recovery, process-group termination,
# duplicate-tick fast path, retry-from-completion, bounded artifacts, retention
# pruning, status, and uninstall paths against an isolated Firstmate-shaped home
# and fake Codex/launchctl processes.
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
CASE_ALT_APP="$TMP_ROOT/app-alt"
CASE_SOURCE="$TMP_ROOT/source"
CASE_BIN="$TMP_ROOT/bin"
CASE_LAUNCH_AGENT_DIR="$CASE_HOME/Library/LaunchAgents"
CASE_LOG_DIR="$CASE_HOME/Library/Logs"
CASE_LAUNCH_STATE="$TMP_ROOT/launch-state"
CASE_CODEX_LOG="$TMP_ROOT/codex.log"
CASE_CODEX_COUNT="$TMP_ROOT/codex.count"
CASE_CODEX_FAIL="$TMP_ROOT/codex.fail"
CASE_CODEX_OMIT_RECEIPT="$TMP_ROOT/codex.omit-receipt"
CASE_CODEX_BAD_JSON="$TMP_ROOT/codex.bad-json"
CASE_CODEX_BAD_RECEIPT="$TMP_ROOT/codex.bad-receipt"
CASE_CODEX_LINGER="$TMP_ROOT/codex.linger"
CASE_CODEX_LINGER_PID="$TMP_ROOT/codex.linger-pid"
CASE_CODEX_MALFORMED_SLACK="$TMP_ROOT/codex.malformed-slack"
CASE_CODEX_SLOW="$TMP_ROOT/codex.slow"
CASE_CODEX_HELPER_SUCCESS="$TMP_ROOT/codex.helper-success"
CASE_CODEX_CONNECTOR_FALLBACK="$TMP_ROOT/codex.connector-fallback"
CASE_CODEX_NOTIFICATION_FAILURE="$TMP_ROOT/codex.notification-failure"
CASE_CODEX_TOKEN_PROBE="$TMP_ROOT/codex.token-probe"
CASE_SLACK_SECRET='xoxb-test-not-a-real-token-0001'
CASE_CLOCK_FILE="$TMP_ROOT/clock.fields"
CASE_ALT_LAUNCH_AGENT_DIR="$CASE_HOME/Library/LaunchAgentsAlt"
CASE_ALT_LAUNCH_STATE="$TMP_ROOT/launch-state-alt"
SUBJECT="$ROOT/bin/fm-review-sweep-supervisor.sh"
SUBJECT_APP_ROOT="$CASE_APP"
SUBJECT_LAUNCH_AGENT_DIR="$CASE_LAUNCH_AGENT_DIR"
SUBJECT_LAUNCH_STATE="$CASE_LAUNCH_STATE"
REAL_JQ=$(command -v jq) || fail 'jq is required by this test'
mkdir -p "$CASE_HOME" "$CASE_BIN" "$CASE_LAUNCH_STATE" "$CASE_ALT_LAUNCH_STATE"
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
receipts="$FM_HOME/state/review-sweep-cycle-receipts"
if [ -n "${FM_FAKE_CODEX_TOKEN_PROBE:-}" ]; then
  if [ -n "${SLACK_BOT_TOKEN:-}" ]; then
    printf 'present %s\n' "${#SLACK_BOT_TOKEN}" > "$FM_FAKE_CODEX_TOKEN_PROBE"
  else
    printf 'absent\n' > "$FM_FAKE_CODEX_TOKEN_PROBE"
  fi
fi
# Simulate a cycle whose wall time advances the supervisor's logical clock.
if [ -n "${FM_FAKE_CODEX_CLOCK_AFTER:-}" ] && [ -n "${FM_REVIEW_SWEEP_NOW_FIELDS_FILE:-}" ]; then
  printf '%s\n' "$FM_FAKE_CODEX_CLOCK_AFTER" > "$FM_REVIEW_SWEEP_NOW_FIELDS_FILE"
fi
# Simulate a reviewer subprocess that outlives the Codex process itself.
if [ -f "$FM_FAKE_CODEX_LINGER" ]; then
  /bin/sleep 300 &
  printf '%s\n' "$!" > "$FM_FAKE_CODEX_LINGER_PID"
fi
if [ -f "$FM_FAKE_CODEX_FAIL" ]; then exit 9; fi
if [ -f "$FM_FAKE_CODEX_OMIT_RECEIPT" ]; then
  printf 'unreceipted result for %s\n' "$slot" > "$out"
  exit 0
fi
mkdir -p "$receipts"
if [ -f "$FM_FAKE_CODEX_BAD_JSON" ]; then
  printf 'this is not a json receipt\n' > "$receipts/$slot.json"
  printf 'unparseable receipt for %s\n' "$slot" > "$out"
  exit 0
fi
if [ -f "$FM_FAKE_CODEX_HELPER_SUCCESS" ]; then
  printf 'active\n' > "$FM_HOME/state/notification-review.meta"
  cat > "$receipts/$slot.json" <<EOF
{"version":2,"slot":"$slot","coverage":"complete","discovered":1,"reviewed":1,"skipped":0,"failed":0,"comments_published":1,"slack_messages_sent":1,"tasks_left_in_flight":0,"reviews":[{"pr":"https://github.com/acme/widget/pull/9","head":"0123456789abcdef0123456789abcdef01234567","comment_url":"https://github.com/acme/widget/pull/9#issuecomment-91","slack":{"status":"sent","transport":"helper","message_url":"https://example.slack.com/archives/C0/p1","attempts":[{"transport":"helper","outcome":"sent"}]}}]}
EOF
  rm -f -- "$FM_HOME/state/notification-review.meta"
  printf 'review published and helper notification sent for %s\n' "$slot" > "$out"
  exit 0
fi
if [ -f "$FM_FAKE_CODEX_CONNECTOR_FALLBACK" ]; then
  printf 'active\n' > "$FM_HOME/state/notification-review.meta"
  cat > "$receipts/$slot.json" <<EOF
{"version":2,"slot":"$slot","coverage":"complete","discovered":1,"reviewed":1,"skipped":0,"failed":0,"comments_published":1,"slack_messages_sent":1,"tasks_left_in_flight":0,"reviews":[{"pr":"https://github.com/acme/widget/pull/10","head":"0123456789abcdef0123456789abcdef01234567","comment_url":"https://github.com/acme/widget/pull/10#issuecomment-92","slack":{"status":"sent","transport":"connector","message_url":"https://example.slack.com/archives/C0/p2","attempts":[{"transport":"helper","outcome":"failed","reason":"helper send failed"},{"transport":"connector","outcome":"sent"}]}}]}
EOF
  rm -f -- "$FM_HOME/state/notification-review.meta"
  printf 'review published and connector fallback notification sent for %s\n' "$slot" > "$out"
  exit 0
fi
if [ -f "$FM_FAKE_CODEX_NOTIFICATION_FAILURE" ]; then
  printf 'active\n' > "$FM_HOME/state/notification-review.meta"
  cat > "$receipts/$slot.json" <<EOF
{"version":2,"slot":"$slot","coverage":"complete","discovered":1,"reviewed":1,"skipped":0,"failed":0,"comments_published":1,"slack_messages_sent":0,"tasks_left_in_flight":0,"reviews":[{"pr":"https://github.com/acme/widget/pull/11","head":"0123456789abcdef0123456789abcdef01234567","comment_url":"https://github.com/acme/widget/pull/11#issuecomment-93","slack":{"status":"ignored","attempts":[{"transport":"helper","outcome":"unavailable","reason":"helper unavailable or unsafe"},{"transport":"connector","outcome":"failed","reason":"connector send failed"}]}}]}
EOF
  rm -f -- "$FM_HOME/state/notification-review.meta"
  printf 'review published and notification failure ignored for %s\n' "$slot" > "$out"
  exit 0
fi
if [ -f "$FM_FAKE_CODEX_MALFORMED_SLACK" ]; then
  cat > "$receipts/$slot.json" <<EOF
{"version":2,"slot":"$slot","coverage":"complete","discovered":1,"reviewed":1,"skipped":0,"failed":0,"comments_published":1,"slack_messages_sent":1,"tasks_left_in_flight":0,"reviews":[{"pr":"https://github.com/acme/widget/pull/7","head":"0123456789abcdef0123456789abcdef01234567","comment_url":"https://github.com/acme/widget/pull/7#issuecomment-42","slack":"sent"}]}
EOF
  printf 'receipt with a malformed slack field for %s\n' "$slot" > "$out"
  exit 0
fi
if [ -f "$FM_FAKE_CODEX_BAD_RECEIPT" ]; then
  cat > "$receipts/$slot.json" <<EOF
{"version":2,"slot":"$slot","coverage":"partial","discovered":3,"reviewed":1,"skipped":0,"failed":0,"comments_published":1,"slack_messages_sent":0,"tasks_left_in_flight":0,"reviews":[]}
EOF
  printf 'semantically invalid receipt for %s\n' "$slot" > "$out"
  exit 0
fi
cat > "$receipts/$slot.json" <<EOF
{"version":2,"slot":"$slot","coverage":"complete","discovered":0,"reviewed":0,"skipped":0,"failed":0,"comments_published":0,"slack_messages_sent":0,"tasks_left_in_flight":0,"reviews":[]}
EOF
printf 'verified no-op for %s\n' "$slot" > "$out"
# Publish first, then outlive the configured runtime bound.
if [ -f "$FM_FAKE_CODEX_SLOW" ]; then /bin/sleep 20; fi
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
  FM_REVIEW_SWEEP_APP_ROOT="$SUBJECT_APP_ROOT" \
  FM_REVIEW_SWEEP_LAUNCH_AGENT_DIR="$SUBJECT_LAUNCH_AGENT_DIR" \
  FM_REVIEW_SWEEP_LOG_DIR="$CASE_LOG_DIR" \
  FM_REVIEW_SWEEP_LAUNCHCTL="$CASE_BIN/launchctl" \
  FM_FAKE_LAUNCH_STATE="$SUBJECT_LAUNCH_STATE" \
  FM_FAKE_RUNTIME_SCRIPT="$SUBJECT_APP_ROOT/runtime/fm-review-sweep-supervisor.sh" \
  FM_FAKE_CODEX_LOG="$CASE_CODEX_LOG" \
  FM_FAKE_CODEX_COUNT="$CASE_CODEX_COUNT" \
  FM_FAKE_CODEX_FAIL="$CASE_CODEX_FAIL" \
  FM_FAKE_CODEX_OMIT_RECEIPT="$CASE_CODEX_OMIT_RECEIPT" \
  FM_FAKE_CODEX_BAD_JSON="$CASE_CODEX_BAD_JSON" \
  FM_FAKE_CODEX_BAD_RECEIPT="$CASE_CODEX_BAD_RECEIPT" \
  FM_FAKE_CODEX_LINGER="$CASE_CODEX_LINGER" \
  FM_FAKE_CODEX_LINGER_PID="$CASE_CODEX_LINGER_PID" \
  FM_FAKE_CODEX_MALFORMED_SLACK="$CASE_CODEX_MALFORMED_SLACK" \
  FM_FAKE_CODEX_SLOW="$CASE_CODEX_SLOW" \
  FM_FAKE_CODEX_HELPER_SUCCESS="$CASE_CODEX_HELPER_SUCCESS" \
  FM_FAKE_CODEX_CONNECTOR_FALLBACK="$CASE_CODEX_CONNECTOR_FALLBACK" \
  FM_FAKE_CODEX_NOTIFICATION_FAILURE="$CASE_CODEX_NOTIFICATION_FAILURE" \
  FM_FAKE_CODEX_TOKEN_PROBE="$CASE_CODEX_TOKEN_PROBE" \
  "$SUBJECT" "$@"
}

run_tick() { # <clock fields>
  FM_REVIEW_SWEEP_NOW_FIELDS=$1 run_subject tick
}

codex_runs() {
  sed -n '1p' "$CASE_CODEX_COUNT"
}

INSTALL_OUT=$(run_subject install --source-home "$CASE_SOURCE") || fail "install failed: $INSTALL_OUT"
assert_contains "$INSTALL_OUT" 'max-concurrent-reviews: 10' 'install did not report the ten-review cap'
assert_contains "$INSTALL_OUT" 'source-branch: main' 'install did not pin the source default branch'
assert_contains "$INSTALL_OUT" 'retention-days: 90' 'install did not report bounded artifact retention'
assert_contains "$INSTALL_OUT" 'slack-transport: data/tools/fm-slack-message.sh (unavailable)' 'install did not report the Slack transport state'
assert_no_grep 'SLACK_BOT_TOKEN' "$CASE_LAUNCH_AGENT_DIR/dev.firstmate.review-sweep.plist" 'the LaunchAgent carries a Slack credential'
assert_grep 'slack_notification_order=helper,connector' "$CASE_APP/home/config/review-sweep-host-contract" 'host contract did not order helper before connector'
assert_grep 'slack_notification_allowed_transports=helper,connector' "$CASE_APP/home/config/review-sweep-host-contract" 'host contract did not forbid a third notification transport'
assert_grep 'slack_connector_fallback=authorized' "$CASE_APP/home/config/review-sweep-host-contract" 'host contract did not authorize connector fallback'
assert_grep 'slack_notification_failure=best-effort' "$CASE_APP/home/config/review-sweep-host-contract" 'host contract did not make notification failure best-effort'
assert_grep 'agent_attribution=forbidden' "$CASE_APP/home/config/review-sweep-host-contract" 'host contract did not forbid agent attribution'
assert_grep 'slack_transport=data/tools/fm-slack-message.sh' "$CASE_APP/home/config/review-sweep-host-contract" 'host contract did not name the authorized Slack transport'
assert_grep 'slack_transport_state=unavailable' "$CASE_APP/home/config/review-sweep-host-contract" 'host contract did not report an absent Slack transport'
assert_absent "$CASE_APP/home/data/tools/fm-slack-message.sh" 'an absent private Slack transport was invented'
assert_present "$CASE_APP/config/supervisor.conf" 'private config was not installed'
assert_present "$CASE_APP/home/config/review-sweep-host-contract" 'host-job contract was not installed'
assert_present "$CASE_LAUNCH_AGENT_DIR/dev.firstmate.review-sweep.plist" 'LaunchAgent was not installed'
assert_grep '<key>StartInterval</key>' "$CASE_LAUNCH_AGENT_DIR/dev.firstmate.review-sweep.plist" 'LaunchAgent lacks its minute-level durable tick'
assert_grep '<integer>60</integer>' "$CASE_LAUNCH_AGENT_DIR/dev.firstmate.review-sweep.plist" 'LaunchAgent tick is not one minute'
assert_grep '<key>LimitLoadToSessionType</key>' "$CASE_LAUNCH_AGENT_DIR/dev.firstmate.review-sweep.plist" 'LaunchAgent is not Aqua-scoped'
assert_grep 'max_concurrent_reviews=10' "$CASE_APP/config/supervisor.conf" 'private config did not persist max concurrency 10'
assert_grep 'source_branch=main' "$CASE_APP/config/supervisor.conf" 'private config did not persist the pinned branch'
assert_grep 'max_concurrent_reviews=10' "$CASE_APP/home/config/review-sweep-host-contract" 'host contract did not authorize max concurrency 10'
pass 'install persists the isolated home, authorization, ten-review cap, pinned branch, and Aqua LaunchAgent'

SUBJECT_APP_ROOT="$CASE_ALT_APP"
SUBJECT_LAUNCH_AGENT_DIR="$CASE_ALT_LAUNCH_AGENT_DIR"
SUBJECT_LAUNCH_STATE="$CASE_ALT_LAUNCH_STATE"
set +e
BAD_INSTALL_OUT=$(run_subject install --source-home "$TMP_ROOT/missing-home" 2>&1)
BAD_INSTALL_RC=$?
set -e
assert_eq 1 "$BAD_INSTALL_RC" 'install with an unusable source home should fail'
assert_contains "$BAD_INSTALL_OUT" 'source home is unavailable' 'install did not name the unusable source home'
assert_absent "$CASE_ALT_APP/config/supervisor.conf" 'a refused install persisted private configuration'
set +e
BAD_INSTALL_AGAIN=$(run_subject install --source-home "$CASE_SOURCE/bin" 2>&1)
BAD_INSTALL_AGAIN_RC=$?
set -e
assert_eq 1 "$BAD_INSTALL_AGAIN_RC" 'install with a non-root source home should fail'
assert_not_contains "$BAD_INSTALL_AGAIN" 'existing config belongs to' 'a refused install left the installer unusable'
assert_absent "$CASE_ALT_APP/config/supervisor.conf" 'a refused install persisted private configuration'
pass 'install validates the source home before persisting anything and stays recoverable'

ALT_INSTALL_OUT=$(run_subject install --source-home "$CASE_SOURCE") || fail "alt install failed: $ALT_INSTALL_OUT"
assert_grep 'source_branch=main' "$CASE_ALT_APP/config/supervisor.conf" 'alt install did not pin the source branch'
grep -v '^source_branch=' "$CASE_ALT_APP/config/supervisor.conf" > "$TMP_ROOT/legacy.conf"
cp "$TMP_ROOT/legacy.conf" "$CASE_ALT_APP/config/supervisor.conf"
set +e
LEGACY_STATUS_OUT=$(run_subject status 2>&1)
LEGACY_STATUS_RC=$?
set -e
assert_eq 1 "$LEGACY_STATUS_RC" 'a config without a pinned branch should fail loudly'
assert_contains "$LEGACY_STATUS_OUT" 'rerun install' 'a config without a pinned branch named no repair path'
BACKFILL_OUT=$(run_subject install --source-home "$CASE_SOURCE") || fail "backfill install failed: $BACKFILL_OUT"
assert_contains "$BACKFILL_OUT" 'repinned: source_branch=main' 'install did not backfill the pinned branch'
assert_grep 'source_branch=main' "$CASE_ALT_APP/config/supervisor.conf" 'backfill did not persist the pinned branch'
assert_grep 'retention_days=90' "$CASE_ALT_APP/config/supervisor.conf" 'backfill discarded other configuration'
assert_eq 1 "$(grep -c '^source_branch=' "$CASE_ALT_APP/config/supervisor.conf")" 'backfill duplicated the pinned branch key'
STABLE_OUT=$(run_subject install --source-home "$CASE_SOURCE") || fail "stable reinstall failed: $STABLE_OUT"
assert_not_contains "$STABLE_OUT" 'repinned:' 'a resolvable pin was rewritten'
# A pin the source home no longer carries must be repairable by the same reinstall.
sed 's/^source_branch=.*/source_branch=retired-default/' "$CASE_ALT_APP/config/supervisor.conf" > "$TMP_ROOT/repin.conf"
cp "$TMP_ROOT/repin.conf" "$CASE_ALT_APP/config/supervisor.conf"
set +e
MISSING_PIN_OUT=$(FM_REVIEW_SWEEP_NOW_FIELDS='20260828 09 00 20000 -0500' run_subject tick 2>&1)
MISSING_PIN_RC=$?
set -e
assert_eq 1 "$MISSING_PIN_RC" 'a vanished pinned branch should fail loudly'
assert_contains "$MISSING_PIN_OUT" "no longer carries its pinned branch 'retired-default'" 'a vanished pinned branch was not named'
assert_contains "$MISSING_PIN_OUT" 'rerun install' 'a vanished pinned branch named no recovery path'
REPIN_OUT=$(run_subject install --source-home "$CASE_SOURCE") || fail "repin install failed: $REPIN_OUT"
assert_contains "$REPIN_OUT" 'repinned: source_branch=main' 'install did not re-resolve a vanished pinned branch'
assert_grep 'source_branch=main' "$CASE_ALT_APP/config/supervisor.conf" 'repin did not persist the resolved branch'
assert_eq 1 "$(grep -c '^source_branch=' "$CASE_ALT_APP/config/supervisor.conf")" 'repin duplicated the pinned branch key'
assert_no_grep 'source_branch=retired-default' "$CASE_ALT_APP/config/supervisor.conf" 'repin left the vanished branch behind'
SUBJECT_APP_ROOT="$CASE_APP"
SUBJECT_LAUNCH_AGENT_DIR="$CASE_LAUNCH_AGENT_DIR"
SUBJECT_LAUNCH_STATE="$CASE_LAUNCH_STATE"
pass 'install repins the source branch when it is missing or vanished, and leaves a valid pin alone'

set +e
BEFORE_OUT=$(run_subject slot-at 20260826 06 59 2>&1)
BEFORE_RC=$?
set -e
assert_eq 3 "$BEFORE_RC" 'pre-window slot calculation should report no due slot'
assert_eq '' "$BEFORE_OUT" 'pre-window slot calculation should print nothing'
assert_eq '20260826-0700' "$(run_subject slot-at 20260826 07 00)" '07:00 slot was not selected'
assert_eq '20260826-0700' "$(run_subject slot-at 20260826 07 29)" '07:29 should still select 07:00'
assert_eq '20260826-0730' "$(run_subject slot-at 20260826 07 30)" '07:30 slot was not selected'
assert_eq '20260826-1700' "$(run_subject slot-at 20260826 17 29)" '17:29 must still catch the final 17:00 slot'
set +e
AFTER_OUT=$(run_subject slot-at 20260826 17 30 2>&1)
AFTER_RC=$?
set -e
assert_eq 3 "$AFTER_RC" '17:30 must close the final slot window'
assert_eq '' "$AFTER_OUT" 'a closed final slot window should print nothing'
set +e
LATE_OUT=$(run_subject slot-at 20260826 23 59 2>&1)
LATE_RC=$?
set -e
assert_eq 3 "$LATE_RC" 'a late evening wake must not resurrect the final slot'
assert_eq '' "$LATE_OUT" 'a late evening wake should print nothing'
pass 'slot calculation honors the Chicago window and closes the final slot at 17:29'

cat > "$CASE_BIN/sleep" <<'SH'
#!/usr/bin/env bash
# Collapse the supervisor's long poll interval so cycles finish immediately,
# but keep short waits real so process-group termination has time to land.
case ${1:-0} in
  5) exit 0 ;;
esac
exec /bin/sleep "${1:-0}"
SH
chmod +x "$CASE_BIN/sleep"

TICK_OUT=$(run_tick '20260826 07 29 1000 -0500') || fail "first tick failed: $TICK_OUT"
assert_contains "$TICK_OUT" 'complete: slot=20260826-0700 status=succeeded' 'first due slot did not complete'
assert_eq 1 "$(codex_runs)" 'first due slot did not invoke Codex exactly once'
assert_grep 'maximum of 10 concurrent independent PR reviews' "$CASE_CODEX_LOG" 'cycle prompt did not carry approved large-swarm cap'
assert_grep 'publication-and-Slack notification sequence' "$CASE_CODEX_LOG" 'cycle prompt did not bind publication to notification'
assert_grep "Do not finish while this home's state contains task metadata" "$CASE_CODEX_LOG" 'cycle prompt did not require teardown'
assert_grep 'Review posted: <direct PR comment URL>' "$CASE_CODEX_LOG" 'cycle prompt did not carry the exact Slack message template'
assert_grep 'try the private helper first' "$CASE_CODEX_LOG" 'cycle prompt did not prefer the private helper'
assert_grep 'fall back to the available Slack connector' "$CASE_CODEX_LOG" 'cycle prompt did not require connector fallback'
assert_grep 'never try a third transport' "$CASE_CODEX_LOG" 'cycle prompt did not forbid a third notification transport'
assert_grep 'must never fail or retry an otherwise valid sweep receipt' "$CASE_CODEX_LOG" 'cycle prompt did not make notification failure best-effort'
assert_present "$CASE_APP/home/state/review-sweep-cycle-receipts/20260826-0700.json" 'cycle receipt was not retained'
pass 'a due slot runs once and requires publication, notification, receipt, and teardown'

SECOND_OUT=$(run_tick '20260826 07 29 1001 -0500') || fail "repeat tick failed: $SECOND_OUT"
assert_contains "$SECOND_OUT" 'noop: slot 20260826-0700 already succeeded' 'successful slot was not deduplicated'
assert_eq 1 "$(codex_runs)" 'successful slot ran twice'
THIRD_OUT=$(run_tick '20260826 07 30 1002 -0500') || fail "next slot failed: $THIRD_OUT"
assert_contains "$THIRD_OUT" 'complete: slot=20260826-0730 status=succeeded' 'next half-hour slot did not run'
assert_eq 2 "$(codex_runs)" 'next half-hour slot did not invoke Codex'
pass 'slot ledger deduplicates successes and advances on the half hour'

assert_present "$CASE_APP/results/20260826-0730/result.txt" 'a verified cycle discarded its compact result'
assert_present "$CASE_APP/results/20260826-0730/prompt.txt" 'a verified cycle discarded its audited prompt'
assert_absent "$CASE_APP/results/20260826-0730/events.jsonl" 'a verified cycle retained its full event stream'
assert_absent "$CASE_APP/results/20260826-0730/events.tail.jsonl" 'a verified cycle retained a failure tail'
assert_eq 0 "$(sed -n '1p' "$CASE_APP/state/slots/20260826-0730/receipt-status")" 'a verified cycle did not record its receipt verdict'
pass 'a successful cycle keeps its compact records and discards unbounded telemetry'

mkdir -p "$CASE_APP/state/run.lock"
printf '%s\n' "$$" > "$CASE_APP/state/run.lock/owner"
cat > "$CASE_BIN/ps" <<'SH'
#!/usr/bin/env bash
printf '/bin/bash /fixture/fm-review-sweep-supervisor.sh tick\n'
SH
chmod +x "$CASE_BIN/ps"
BUSY_OUT=$(run_tick '20260826 08 00 2000 -0500') || fail "busy tick should be a safe no-op: $BUSY_OUT"
assert_contains "$BUSY_OUT" 'busy: review-sweep cycle already owned' 'live owner did not exclude overlap'
assert_eq 2 "$(codex_runs)" 'overlapping tick started another cycle'
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
assert_eq 3 "$(codex_runs)" 'failed slot did not run exactly once'
DEFER_OUT=$(run_tick '20260826 08 00 3100 -0500') || fail "deferred retry failed: $DEFER_OUT"
assert_contains "$DEFER_OUT" 'deferred: slot 20260826-0800 retry is due at epoch 3300' 'retry throttle was not enforced'
assert_eq 3 "$(codex_runs)" 'retry ran before its deadline'
rm -f -- "$CASE_CODEX_FAIL"
RECOVER_OUT=$(run_tick '20260826 08 00 3301 -0500') || fail "retry recovery failed: $RECOVER_OUT"
assert_contains "$RECOVER_OUT" 'attempt=2' 'failed slot did not resume as its second attempt'
assert_contains "$RECOVER_OUT" 'status=succeeded' 'retried slot did not succeed'
assert_eq 4 "$(codex_runs)" 'retried slot did not invoke Codex once'
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
assert_eq 6 "$(codex_runs)" 'missing-receipt case did not run exactly once'
rm -f -- "$CASE_CODEX_OMIT_RECEIPT"
RECEIPT_RECOVER_OUT=$(run_tick '20260826 09 00 6301 -0500') || fail "receipt retry failed: $RECEIPT_RECOVER_OUT"
assert_contains "$RECEIPT_RECOVER_OUT" 'slot=20260826-0900 attempt=2' 'receipt failure did not retry the same slot'
assert_contains "$RECEIPT_RECOVER_OUT" 'status=succeeded' 'receipt retry did not succeed'
assert_eq 7 "$(codex_runs)" 'receipt retry did not invoke Codex once'
pass 'a cycle cannot succeed without its publication and notification receipt'

NOOP_OUT=$(run_tick '20260827 06 59 5000 -0500') || fail "pre-window tick failed: $NOOP_OUT"
assert_contains "$NOOP_OUT" 'noop: no review-sweep slot is due' 'next-day pre-window tick replayed yesterday'
assert_eq 7 "$(codex_runs)" 'next-day pre-window tick invoked Codex'
EVENING_OUT=$(run_tick '20260827 17 45 5400 -0500') || fail "after-hours tick failed: $EVENING_OUT"
assert_contains "$EVENING_OUT" 'noop: no review-sweep slot is due' 'an after-hours tick started an authorized cycle'
assert_eq 7 "$(codex_runs)" 'an after-hours tick invoked Codex'
LATE_NIGHT_OUT=$(run_tick '20260827 23 30 5500 -0500') || fail "late-night tick failed: $LATE_NIGHT_OUT"
assert_contains "$LATE_NIGHT_OUT" 'noop: no review-sweep slot is due' 'a late-night tick started an authorized cycle'
assert_eq 7 "$(codex_runs)" 'a late-night tick invoked Codex'
pass 'catch-up stays inside the current Chicago day and never runs after the final slot window'

touch "$CASE_CODEX_BAD_JSON"
set +e
BAD_JSON_OUT=$(run_tick '20260828 07 00 8000 -0500' 2>&1)
BAD_JSON_RC=$?
set -e
rm -f -- "$CASE_CODEX_BAD_JSON"
assert_eq 76 "$BAD_JSON_RC" 'an unparseable receipt was not reported as its own failure'
assert_contains "$BAD_JSON_OUT" 'not a readable JSON object' 'unparseable receipt failure was not explicit'
assert_eq 8 "$(codex_runs)" 'unparseable-receipt case did not run exactly once'
assert_present "$CASE_APP/results/20260828-0700/events.tail.jsonl" 'a failed cycle kept no diagnostic tail'
assert_absent "$CASE_APP/results/20260828-0700/events.jsonl" 'a failed cycle retained its full event stream'
assert_eq 76 "$(sed -n '1p' "$CASE_APP/state/slots/20260828-0700/receipt-status")" 'a failed cycle did not record its receipt verdict'
touch "$CASE_CODEX_BAD_RECEIPT"
set +e
BAD_RECEIPT_OUT=$(run_tick '20260828 07 30 8100 -0500' 2>&1)
BAD_RECEIPT_RC=$?
set -e
rm -f -- "$CASE_CODEX_BAD_RECEIPT"
assert_eq 75 "$BAD_RECEIPT_RC" 'a semantically invalid receipt was not reported as its own failure'
assert_contains "$BAD_RECEIPT_OUT" 'invalid or incomplete cycle receipt' 'invalid receipt failure was not explicit'
assert_eq 9 "$(codex_runs)" 'invalid-receipt case did not run exactly once'
assert_present "$CASE_APP/results/20260828-0730/events.tail.jsonl" 'the latest failure kept no diagnostic tail'
assert_absent "$CASE_APP/results/20260828-0700/events.tail.jsonl" 'an older failure tail was retained alongside the latest'
pass 'unparseable and contract-violating receipts fail distinctly and keep one bounded tail'

printf '20260828 08 00 9000 -0500\n' > "$CASE_CLOCK_FILE"
touch "$CASE_CODEX_FAIL"
set +e
SLOW_FAIL_OUT=$(FM_REVIEW_SWEEP_NOW_FIELDS_FILE="$CASE_CLOCK_FILE" \
  FM_FAKE_CODEX_CLOCK_AFTER='20260828 08 25 10500 -0500' run_subject tick 2>&1)
SLOW_FAIL_RC=$?
set -e
rm -f -- "$CASE_CODEX_FAIL"
assert_eq 9 "$SLOW_FAIL_RC" 'a long failing cycle did not preserve its exit code'
assert_contains "$SLOW_FAIL_OUT" 'slot=20260828-0800 status=failed' 'a long failing cycle lost its slot identity'
assert_eq 10 "$(codex_runs)" 'long-failure case did not run exactly once'
assert_eq 10800 "$(sed -n '1p' "$CASE_APP/state/slots/20260828-0800/retry-at")" \
  'retry deadline was not measured from cycle completion'
EARLY_RETRY_OUT=$(run_tick '20260828 08 29 10700 -0500') || fail "post-failure tick failed: $EARLY_RETRY_OUT"
assert_contains "$EARLY_RETRY_OUT" 'deferred: slot 20260828-0800 retry is due at epoch 10800' 'retry throttle did not survive a long cycle'
assert_not_contains "$EARLY_RETRY_OUT" 'epoch 9300' 'retry deadline was still derived from the tick start'
assert_eq 10 "$(codex_runs)" 'a long-failing slot retried before its deadline'
pass 'a cycle longer than the retry window still waits a full throttle before its next attempt'

touch "$CASE_CODEX_LINGER"
LINGER_OUT=$(run_tick '20260828 09 00 11000 -0500') || fail "lingering cycle failed: $LINGER_OUT"
rm -f -- "$CASE_CODEX_LINGER"
assert_contains "$LINGER_OUT" 'slot=20260828-0900 status=succeeded' 'a cycle with a lingering child did not complete'
assert_eq 11 "$(codex_runs)" 'lingering-child case did not run exactly once'
LINGER_PID=$(sed -n '1p' "$CASE_CODEX_LINGER_PID")
[ -n "$LINGER_PID" ] || fail 'fake Codex did not record its lingering child'
if kill -0 "$LINGER_PID" 2>/dev/null; then
  kill -KILL "$LINGER_PID" 2>/dev/null || true
  fail "a review subprocess outlived its cycle and the released owner lock (pid $LINGER_PID)"
fi
assert_absent "$CASE_APP/state/run.lock" 'the owner lock was not released after the cycle process group ended'
pass 'a cycle owns a process group and no descendant outlives the released owner lock'

mkdir -p "$CASE_APP/state/run.lock"
FRESH_LOCK_OUT=$(run_tick '20260828 09 30 12000 -0500') || fail "fresh ownerless lock tick failed: $FRESH_LOCK_OUT"
assert_contains "$FRESH_LOCK_OUT" 'busy: review-sweep lock is being claimed by another process' 'a fresh ownerless lock was stolen'
assert_eq 11 "$(codex_runs)" 'a fresh ownerless lock did not exclude a cycle'
touch -t 202001010000 "$CASE_APP/state/run.lock"
ORPHAN_LOCK_OUT=$(run_tick '20260828 09 30 12001 -0500') || fail "ownerless lock recovery failed: $ORPHAN_LOCK_OUT"
assert_contains "$ORPHAN_LOCK_OUT" 'reclaim: retiring an ownerless review-sweep lock' 'an abandoned ownerless lock was not reclaimed'
assert_contains "$ORPHAN_LOCK_OUT" 'slot=20260828-0930 status=succeeded' 'the reclaimed slot did not run'
assert_eq 12 "$(codex_runs)" 'the reclaimed slot did not invoke Codex once'
pass 'an ownerless crash-window lock is respected briefly and then reclaimed'

printf 'local captain edit\n' >> "$CASE_APP/home/AGENTS.md"
FASTPATH_OUT=$(run_tick '20260828 09 45 12100 -0500') || fail "duplicate tick failed: $FASTPATH_OUT"
assert_contains "$FASTPATH_OUT" 'noop: slot 20260828-0930 already succeeded' 'a duplicate tick did not take the fast path'
assert_not_contains "$FASTPATH_OUT" 'automation_home has tracked local changes' 'a duplicate tick synchronized the automation home'
assert_eq 12 "$(codex_runs)" 'a duplicate tick started another cycle'
set +e
PREPARE_OUT=$(run_tick '20260828 10 00 12200 -0500' 2>&1)
PREPARE_RC=$?
set -e
assert_eq 1 "$PREPARE_RC" 'a runnable slot ignored an unsafe automation home'
assert_contains "$PREPARE_OUT" 'automation_home has tracked local changes' 'preparation no longer guards a runnable slot'
assert_contains "$PREPARE_OUT" 'slot=20260828-1000 status=failed exit=1 retry-after=300 reason=preparation' 'a preparation failure was not recorded against the slot'
assert_eq 12 "$(codex_runs)" 'a guarded slot still started a cycle'
THROTTLED_OUT=$(run_tick '20260828 10 05 12300 -0500') || fail "throttled tick failed: $THROTTLED_OUT"
assert_contains "$THROTTLED_OUT" 'deferred: slot 20260828-1000 retry is due at epoch 12500' 'a preparation failure was retried on the next minute tick'
assert_not_contains "$THROTTLED_OUT" 'automation_home has tracked local changes' 'a throttled tick still synchronized the automation home'
assert_eq 12 "$(codex_runs)" 'a throttled slot started a cycle'
git -C "$CASE_APP/home" checkout -- AGENTS.md
pass 'a duplicate minute tick and a failed preparation both stay cheap under the retry throttle'

git -C "$CASE_SOURCE" checkout -q -b captain-working-branch
BRANCH_OUT=$(run_tick '20260828 10 15 12600 -0500') || fail "pinned-branch tick failed: $BRANCH_OUT"
assert_contains "$BRANCH_OUT" 'slot=20260828-1000 status=succeeded' 'a source working-branch switch disabled the scheduled job'
assert_eq 13 "$(codex_runs)" 'the pinned-branch slot did not invoke Codex once'
assert_eq main "$(git -C "$CASE_APP/home" symbolic-ref --short HEAD)" 'the automation home left its pinned default branch'
pass 'the automation home tracks the pinned default branch through source working-branch changes'

SOURCE_HEAD_BEFORE=$(git -C "$CASE_SOURCE" rev-parse refs/heads/main)
git -C "$CASE_SOURCE" checkout -q main
printf 'rewritten source line\n' >> "$CASE_SOURCE/AGENTS.md"
git -C "$CASE_SOURCE" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -aq --amend -m 'rewritten history'
git -C "$CASE_SOURCE" checkout -q captain-working-branch
SOURCE_HEAD_AFTER=$(git -C "$CASE_SOURCE" rev-parse refs/heads/main)
[ "$SOURCE_HEAD_BEFORE" != "$SOURCE_HEAD_AFTER" ] || fail 'the source history rewrite fixture did not change the head'
REWRITE_OUT=$(run_tick '20260828 10 30 12700 -0500') || fail "history rewrite tick failed: $REWRITE_OUT"
assert_contains "$REWRITE_OUT" "realigned: automation home reset to pinned main at $SOURCE_HEAD_AFTER" 'a rewritten source history did not self-heal'
assert_contains "$REWRITE_OUT" 'slot=20260828-1030 status=succeeded' 'the realigned slot did not run'
assert_eq 14 "$(codex_runs)" 'the realigned slot did not invoke Codex once'
assert_eq "$SOURCE_HEAD_AFTER" "$(git -C "$CASE_APP/home" rev-parse HEAD)" 'the automation home did not settle on the pinned source head'
assert_eq "$SOURCE_HEAD_AFTER" "$(git -C "$CASE_SOURCE" rev-parse refs/heads/main)" 'realignment rewrote the source home'
assert_eq captain-working-branch "$(git -C "$CASE_SOURCE" symbolic-ref --short HEAD)" 'realignment moved the source working branch'
assert_present "$CASE_APP/home/data/captain.md" 'realignment deleted untracked private context'
assert_present "$CASE_APP/home/data/backlog.md" 'realignment deleted the automation backlog'
pass 'a rewritten pinned history realigns the supervisor-owned clone without touching the source home'

STRAY_OWNER_PID=$(bash -c 'echo $$')
set -m
bash -c 'exec -a "$0" /bin/sleep 300' "$CASE_BIN/codex" >/dev/null 2>&1 </dev/null &
CODEX_LIKE_PGID=$!
/bin/sleep 300 >/dev/null 2>&1 &
STRAY_PGID=$!
set +m
disown -a 2>/dev/null || true
# These fixtures must never hold this script's output open, or a failing
# assertion would leave the suite's reader blocked until they expire.
trap 'kill -KILL "-$CODEX_LIKE_PGID" "-$STRAY_PGID" 2>/dev/null || true; fm_test_cleanup' EXIT
mkdir -p "$CASE_APP/state/run.lock"
printf '%s\n' "$STRAY_OWNER_PID" > "$CASE_APP/state/run.lock/owner"
printf '%s\n%s\n' "$CODEX_LIKE_PGID" "$(date +%s)" > "$CASE_APP/state/run.lock/cycle-pgid"
LIVE_PGID_OUT=$(run_tick '20260828 11 30 12900 -0500') || fail "live cycle group tick failed: $LIVE_PGID_OUT"
assert_contains "$LIVE_PGID_OUT" "busy: review-sweep cycle process group $CODEX_LIKE_PGID outlived its supervisor" 'a live cycle group no longer excludes a second cycle'
assert_eq 14 "$(codex_runs)" 'a live cycle group did not exclude a second cycle'
# A surviving reviewer whose codex parent already exited is exactly what the
# retained lock exists for, so a live group must block even without codex in it.
printf '%s\n%s\n' "$STRAY_PGID" "$(date +%s)" > "$CASE_APP/state/run.lock/cycle-pgid"
ORPHAN_WRITER_OUT=$(run_tick '20260828 11 30 12901 -0500') || fail "orphan writer tick failed: $ORPHAN_WRITER_OUT"
assert_contains "$ORPHAN_WRITER_OUT" "busy: review-sweep cycle process group $STRAY_PGID outlived its supervisor" 'a live orphaned writer group no longer excludes a second cycle'
assert_not_contains "$ORPHAN_WRITER_OUT" 'reclaim:' 'a live orphaned writer group was retired'
assert_eq 14 "$(codex_runs)" 'a live orphaned writer group did not exclude a second cycle'
# A record older than any cycle could possibly be is positive reuse evidence.
printf '%s\n%s\n' "$STRAY_PGID" 1 > "$CASE_APP/state/run.lock/cycle-pgid"
STALE_PGID_OUT=$(run_tick '20260828 11 30 12902 -0500') || fail "stale cycle group tick failed: $STALE_PGID_OUT"
assert_contains "$STALE_PGID_OUT" "reclaim: retiring a review-sweep cycle process group record ($STRAY_PGID) that outlived any possible cycle" 'a reused cycle process group id wedged the supervisor'
assert_contains "$STALE_PGID_OUT" 'slot=20260828-1130 status=succeeded' 'the reclaimed slot did not run'
assert_eq 15 "$(codex_runs)" 'the reclaimed slot did not invoke Codex once'
# Past that bound a codex-running group that is not provably this job's own
# cycle is still never killed, and still keeps the lock.
mkdir -p "$CASE_APP/state/run.lock"
printf '%s\n' "$STRAY_OWNER_PID" > "$CASE_APP/state/run.lock/owner"
printf '%s\n%s\n' "$CODEX_LIKE_PGID" 1 > "$CASE_APP/state/run.lock/cycle-pgid"
EXPIRED_CODEX_OUT=$(run_tick '20260828 12 00 12903 -0500') || fail "expired codex group tick failed: $EXPIRED_CODEX_OUT"
assert_contains "$EXPIRED_CODEX_OUT" "busy: review-sweep cycle process group $CODEX_LIKE_PGID outlived its supervisor" 'an unverifiable expired group was retired'
assert_not_contains "$EXPIRED_CODEX_OUT" 'reaping:' 'an unverifiable expired group was reaped'
assert_eq 15 "$(codex_runs)" 'an unverifiable expired group did not exclude a cycle'
kill -0 "$CODEX_LIKE_PGID" 2>/dev/null || fail 'an unverifiable expired group was terminated'
rm -f -- "$CASE_APP/state/run.lock/owner" "$CASE_APP/state/run.lock/cycle-pgid"
rmdir -- "$CASE_APP/state/run.lock"
kill -KILL "-$CODEX_LIKE_PGID" 2>/dev/null || true
kill -KILL "-$STRAY_PGID" 2>/dev/null || true
trap fm_test_cleanup EXIT
pass 'a live cycle process group always blocks, and an unverifiable one is never killed'

# A group whose leader is provably this job's own abandoned Codex cycle is
# reaped by the next supervisor rather than blocking forever.
ORPHAN_OWNER_PID=$(bash -c 'echo $$')
set -m
bash -c 'exec -a "$0" /bin/sleep 300' \
  "$CASE_BIN/codex exec --ephemeral --json --color never --approve-for-me -C $CASE_APP/home -o result prompt" \
  >/dev/null 2>&1 </dev/null &
OWNED_ORPHAN_PGID=$!
set +m
disown -a 2>/dev/null || true
trap 'kill -KILL "-$OWNED_ORPHAN_PGID" 2>/dev/null || true; fm_test_cleanup' EXIT
mkdir -p "$CASE_APP/state/run.lock"
printf '%s\n' "$ORPHAN_OWNER_PID" > "$CASE_APP/state/run.lock/owner"
printf '%s\n%s\n' "$OWNED_ORPHAN_PGID" 1 > "$CASE_APP/state/run.lock/cycle-pgid"
REAP_OUT=$(run_tick '20260828 12 00 12904 -0500') || fail "orphan reaper tick failed: $REAP_OUT"
assert_contains "$REAP_OUT" "reaping: review-sweep cycle process group $OWNED_ORPHAN_PGID has run" 'a provably abandoned cycle was not reaped'
assert_contains "$REAP_OUT" "reclaim: terminated an abandoned review-sweep cycle process group ($OWNED_ORPHAN_PGID)" 'the reaped cycle was not reclaimed'
assert_contains "$REAP_OUT" 'slot=20260828-1200 status=succeeded' 'the slot behind a reaped orphan did not run'
assert_eq 16 "$(codex_runs)" 'the reaped slot did not invoke Codex once'
if kill -0 "$OWNED_ORPHAN_PGID" 2>/dev/null; then
  kill -KILL "-$OWNED_ORPHAN_PGID" 2>/dev/null || true
  fail 'the abandoned cycle survived its reaper'
fi
trap fm_test_cleanup EXIT
pass 'an expired cycle group proven to be this job own runaway is terminated, not blocked forever'

mkdir -p "$CASE_SOURCE/data/tools"
cat > "$CASE_SOURCE/data/tools/fm-slack-message.sh" <<'SH'
#!/usr/bin/env bash
printf 'https://example.slack.com/archives/C0/p1\n'
SH
chmod +x "$CASE_SOURCE/data/tools/fm-slack-message.sh"
CREDENTIALLESS_OUT=$(run_tick '20260828 14 00 13400 -0500') || fail "credentialless tick failed: $CREDENTIALLESS_OUT"
assert_contains "$CREDENTIALLESS_OUT" 'slot=20260828-1400 status=succeeded' 'a missing helper credential cost the sweep'
assert_eq 17 "$(codex_runs)" 'the credentialless case did not run exactly once'
assert_present "$CASE_APP/home/data/tools/fm-slack-message.sh" 'the private Slack transport was not provisioned'
[ -x "$CASE_APP/home/data/tools/fm-slack-message.sh" ] || fail 'the provisioned Slack transport is not executable'
assert_grep 'slack_transport_state=credentials-missing' "$CASE_APP/home/config/review-sweep-host-contract" 'a transport without a credential was reported available'
assert_eq absent "$(sed -n '1p' "$CASE_CODEX_TOKEN_PROBE")" 'the cycle saw a credential that was never provisioned'
pass 'a provisioned helper without a credential is reported credentials-missing without failing the sweep'

# Every rejected credential shape must degrade to credentials-missing, never leak.
for CASE_BAD_TOKEN in 'mode' 'symlink' 'multiline' 'empty'; do
  case $CASE_BAD_TOKEN in
    mode)
      printf '%s\n' "$CASE_SLACK_SECRET" > "$CASE_SOURCE/config/slack-bot-token"
      chmod 0644 "$CASE_SOURCE/config/slack-bot-token"
      ;;
    symlink)
      printf '%s\n' "$CASE_SLACK_SECRET" > "$TMP_ROOT/linked-token"
      chmod 0600 "$TMP_ROOT/linked-token"
      rm -f -- "$CASE_SOURCE/config/slack-bot-token"
      ln -s "$TMP_ROOT/linked-token" "$CASE_SOURCE/config/slack-bot-token"
      ;;
    multiline)
      rm -f -- "$CASE_SOURCE/config/slack-bot-token"
      printf '%s\nextra\n' "$CASE_SLACK_SECRET" > "$CASE_SOURCE/config/slack-bot-token"
      chmod 0600 "$CASE_SOURCE/config/slack-bot-token"
      ;;
    empty)
      rm -f -- "$CASE_SOURCE/config/slack-bot-token"
      printf '\n' > "$CASE_SOURCE/config/slack-bot-token"
      chmod 0600 "$CASE_SOURCE/config/slack-bot-token"
      ;;
  esac
  BAD_TOKEN_INSTALL=$(run_subject install --source-home "$CASE_SOURCE") \
    || fail "install with a $CASE_BAD_TOKEN credential failed: $BAD_TOKEN_INSTALL"
  assert_contains "$BAD_TOKEN_INSTALL" 'slack-transport: data/tools/fm-slack-message.sh (credentials-missing)' \
    "a $CASE_BAD_TOKEN credential was accepted"
  assert_absent "$CASE_APP/home/config/slack-bot-token" "a $CASE_BAD_TOKEN credential was provisioned"
done
rm -f -- "$CASE_SOURCE/config/slack-bot-token"
pass 'an unsafe or malformed Slack credential is refused without failing installation'

printf '%s\n' "$CASE_SLACK_SECRET" > "$CASE_SOURCE/config/slack-bot-token"
chmod 0600 "$CASE_SOURCE/config/slack-bot-token"
TOKEN_INSTALL=$(run_subject install --source-home "$CASE_SOURCE") || fail "credential install failed: $TOKEN_INSTALL"
assert_contains "$TOKEN_INSTALL" 'slack-transport: data/tools/fm-slack-message.sh (available)' 'a valid credential was not recognized'
assert_present "$CASE_APP/home/config/slack-bot-token" 'a valid credential was not provisioned'
assert_eq 600 "$(stat -f %Lp "$CASE_APP/home/config/slack-bot-token" 2>/dev/null || stat -c %a "$CASE_APP/home/config/slack-bot-token")" \
  'the provisioned credential is not owner-only'
touch "$CASE_CODEX_HELPER_SUCCESS"
TOKEN_OUT=$(run_tick '20260828 14 30 13450 -0500') || fail "credentialed tick failed: $TOKEN_OUT"
rm -f -- "$CASE_CODEX_HELPER_SUCCESS"
assert_contains "$TOKEN_OUT" 'slot=20260828-1430 status=succeeded' 'the credentialed cycle did not complete'
assert_eq 18 "$(codex_runs)" 'the credentialed cycle did not run exactly once'
assert_eq "present ${#CASE_SLACK_SECRET}" "$(sed -n '1p' "$CASE_CODEX_TOKEN_PROBE")" 'the cycle did not receive the provisioned credential'
assert_eq helper "$(jq -r '.reviews[0].slack.transport' "$CASE_APP/home/state/review-sweep-cycle-receipts/20260828-1430.json")" \
  'helper success did not record its transport'
assert_eq 'https://example.slack.com/archives/C0/p1' \
  "$(jq -r '.reviews[0].slack.message_url' "$CASE_APP/home/state/review-sweep-cycle-receipts/20260828-1430.json")" \
  'helper success did not retain its direct Slack permalink'
assert_absent "$CASE_APP/home/state/notification-review.meta" 'helper success left task metadata behind'
# The secret must exist only in the two private files and the cycle environment.
assert_no_grep "$CASE_SLACK_SECRET" "$CASE_LAUNCH_AGENT_DIR/dev.firstmate.review-sweep.plist" 'the LaunchAgent leaked the credential'
assert_no_grep "$CASE_SLACK_SECRET" "$CASE_APP/home/config/review-sweep-host-contract" 'the host contract leaked the credential'
assert_no_grep "$CASE_SLACK_SECRET" "$CASE_APP/results/20260828-1430/prompt.txt" 'the cycle prompt leaked the credential'
assert_no_grep "$CASE_SLACK_SECRET" "$CASE_CODEX_LOG" 'the cycle log leaked the credential'
assert_no_grep "$CASE_SLACK_SECRET" "$CASE_APP/home/state/review-sweep-cycle-receipts/20260828-1430.json" 'the receipt leaked the credential'
assert_not_contains "$TOKEN_OUT" "$CASE_SLACK_SECRET" 'the cycle output leaked the credential'
TOKEN_STATUS=$(run_subject status) || fail "credentialed status failed: $TOKEN_STATUS"
assert_contains "$TOKEN_STATUS" 'slack-transport: data/tools/fm-slack-message.sh (available)' 'status did not report the usable transport'
assert_not_contains "$TOKEN_STATUS" "$CASE_SLACK_SECRET" 'status leaked the credential'
pass 'a valid credential reaches only the cycle process and helper success reconciles with its permalink'

touch "$CASE_CODEX_CONNECTOR_FALLBACK"
FALLBACK_OUT=$(run_tick '20260828 15 00 13500 -0500') || fail "connector fallback tick failed: $FALLBACK_OUT"
rm -f -- "$CASE_CODEX_CONNECTOR_FALLBACK"
assert_contains "$FALLBACK_OUT" 'slot=20260828-1500 status=succeeded' 'helper-to-connector fallback invalidated the sweep receipt'
assert_eq 19 "$(codex_runs)" 'the connector-fallback case did not run exactly once'
assert_eq connector \
  "$(jq -r '.reviews[0].slack.transport' "$CASE_APP/home/state/review-sweep-cycle-receipts/20260828-1500.json")" \
  'connector fallback did not record its successful transport'
assert_eq 'https://example.slack.com/archives/C0/p2' \
  "$(jq -r '.reviews[0].slack.message_url' "$CASE_APP/home/state/review-sweep-cycle-receipts/20260828-1500.json")" \
  'connector fallback did not retain its direct Slack permalink'
assert_eq 'helper:failed,connector:sent' \
  "$(jq -r '[.reviews[0].slack.attempts[] | .transport + ":" + .outcome] | join(",")' "$CASE_APP/home/state/review-sweep-cycle-receipts/20260828-1500.json")" \
  'connector fallback did not retain its ordered attempt outcomes'
assert_absent "$CASE_APP/home/state/notification-review.meta" 'connector fallback left task metadata behind'
pass 'a helper send failure falls back to the connector and reconciles with its permalink'

# A symlinked helper and failed connector must not cost the sweep its reviews.
rm -f -- "$CASE_SOURCE/data/tools/fm-slack-message.sh"
ln -s "$TMP_ROOT/linked-token" "$CASE_SOURCE/data/tools/fm-slack-message.sh"
touch "$CASE_CODEX_NOTIFICATION_FAILURE"
SYMLINK_OUT=$(run_tick '20260828 15 30 13550 -0500') || fail "symlinked transport tick failed: $SYMLINK_OUT"
rm -f -- "$CASE_CODEX_NOTIFICATION_FAILURE"
assert_contains "$SYMLINK_OUT" 'slot=20260828-1530 status=succeeded' 'total notification failure invalidated the sweep receipt'
assert_eq 20 "$(codex_runs)" 'the total-notification-failure case did not run exactly once'
assert_absent "$CASE_APP/home/data/tools/fm-slack-message.sh" 'an unsafe Slack helper was provisioned'
assert_grep 'slack_transport_state=unavailable' "$CASE_APP/home/config/review-sweep-host-contract" 'an unsafe Slack helper was reported usable'
assert_eq 'helper:unavailable:helper unavailable or unsafe,connector:failed:connector send failed' \
  "$(jq -r '[.reviews[0].slack.attempts[] | .transport + ":" + .outcome + ":" + .reason] | join(",")' "$CASE_APP/home/state/review-sweep-cycle-receipts/20260828-1530.json")" \
  'total notification failure did not retain both concrete attempt outcomes'
assert_absent "$CASE_APP/home/state/notification-review.meta" 'total notification failure left task metadata behind'
FAILED_NOTIFICATION_AGAIN=$(run_tick '20260828 15 30 13551 -0500') || fail "failed-notification duplicate tick failed: $FAILED_NOTIFICATION_AGAIN"
assert_contains "$FAILED_NOTIFICATION_AGAIN" 'noop: slot 20260828-1530 already succeeded' 'a total notification failure retried a verified sweep receipt'
assert_eq 20 "$(codex_runs)" 'a total notification failure retried the sweep'
rm -f -- "$CASE_SOURCE/data/tools/fm-slack-message.sh" "$CASE_SOURCE/config/slack-bot-token"
pass 'total notification failure preserves both outcomes and still completes reconciliation and teardown'

sed 's/^max_runtime_seconds=.*/max_runtime_seconds=1/' "$CASE_APP/config/supervisor.conf" > "$TMP_ROOT/bounded.conf"
cp "$TMP_ROOT/bounded.conf" "$CASE_APP/config/supervisor.conf"
touch "$CASE_CODEX_SLOW"
set +e
BOUNDED_OUT=$(run_tick '20260828 16 00 13600 -0500' 2>&1)
BOUNDED_RC=$?
set -e
rm -f -- "$CASE_CODEX_SLOW"
sed 's/^max_runtime_seconds=.*/max_runtime_seconds=10800/' "$CASE_APP/config/supervisor.conf" > "$TMP_ROOT/bounded.conf"
cp "$TMP_ROOT/bounded.conf" "$CASE_APP/config/supervisor.conf"
assert_eq 124 "$BOUNDED_RC" 'a cycle past its runtime bound did not report the timeout'
assert_contains "$BOUNDED_OUT" 'exceeded 1 seconds' 'the runtime bound was not enforced'
assert_contains "$BOUNDED_OUT" 'slot=20260828-1600 status=succeeded exit=124 publication=verified' 'a verified publication was discarded with the failed cycle'
assert_eq 0 "$(sed -n '1p' "$CASE_APP/state/slots/20260828-1600/receipt-status")" 'the receipt verdict was not recorded for a failed cycle'
assert_eq 21 "$(codex_runs)" 'the bounded cycle did not run exactly once'
REPUBLISH_OUT=$(run_tick '20260828 16 15 13610 -0500') || fail "post-timeout tick failed: $REPUBLISH_OUT"
assert_contains "$REPUBLISH_OUT" 'noop: slot 20260828-1600 already succeeded' 'a verified publication was scheduled again'
assert_eq 21 "$(codex_runs)" 'a verified publication was published twice'
pass 'a cycle that verified its publication is never re-run, even when it ended badly'

touch "$CASE_CODEX_MALFORMED_SLACK"
set +e
MALFORMED_OUT=$(run_tick '20260828 12 30 13100 -0500' 2>&1)
MALFORMED_RC=$?
set -e
rm -f -- "$CASE_CODEX_MALFORMED_SLACK"
assert_eq 75 "$MALFORMED_RC" 'a receipt field of the wrong type was not a contract violation'
assert_contains "$MALFORMED_OUT" 'invalid or incomplete cycle receipt' 'a malformed receipt field was reported as a tooling failure'
assert_not_contains "$MALFORMED_OUT" 'could not be run by jq' 'a malformed receipt field was reported as a tooling failure'
cat > "$CASE_BIN/jq" <<SH
#!/usr/bin/env bash
# Pass the parse probe through to real jq, then refuse to run the gate program.
for arg in "\$@"; do
  case \$arg in
    'type == "object"') exec "$REAL_JQ" "\$@" ;;
  esac
done
exit 3
SH
chmod +x "$CASE_BIN/jq"
set +e
JQ_BROKEN_OUT=$(run_tick '20260828 13 00 13200 -0500' 2>&1)
JQ_BROKEN_RC=$?
set -e
rm -f -- "$CASE_BIN/jq"
assert_eq 77 "$JQ_BROKEN_RC" 'an unrunnable receipt gate was not reported as a tooling failure'
assert_contains "$JQ_BROKEN_OUT" 'receipt gate could not be run by jq' 'an unrunnable receipt gate was not named'
assert_eq 23 "$(codex_runs)" 'the receipt classification cases did not run once each'
pass 'a malformed receipt field is a contract violation and only an unrunnable gate is a tooling failure'

mkdir -p "$CASE_APP/state/slots/20200101-0700" "$CASE_APP/results/20200101-0700" "$TMP_ROOT/linked-slot"
printf 'succeeded\n' > "$CASE_APP/state/slots/20200101-0700/status"
printf 'stale\n' > "$CASE_APP/results/20200101-0700/result.txt"
printf '{}\n' > "$CASE_APP/home/state/review-sweep-cycle-receipts/20200101-0700.json"
printf 'operator note\n' > "$CASE_APP/home/state/review-sweep-cycle-receipts/notes.txt"
printf 'not a slot directory\n' > "$CASE_APP/state/slots/20200101-0800"
ln -s "$TMP_ROOT/linked-slot" "$CASE_APP/results/20200101-0900"
touch -t 202001010000 "$CASE_APP/state/slots/20200101-0700" "$CASE_APP/results/20200101-0700" \
  "$CASE_APP/home/state/review-sweep-cycle-receipts/20200101-0700.json" \
  "$CASE_APP/home/state/review-sweep-cycle-receipts/notes.txt" \
  "$CASE_APP/state/slots/20200101-0800"
touch -h -t 202001010000 "$CASE_APP/results/20200101-0900"
RETAIN_OUT=$(run_tick '20260828 13 30 13300 -0500') || fail "retention tick failed: $RETAIN_OUT"
assert_contains "$RETAIN_OUT" 'slot=20260828-1330 status=succeeded' 'the retention cycle did not complete'
assert_eq 24 "$(codex_runs)" 'the retention cycle did not invoke Codex once'
assert_absent "$CASE_APP/state/slots/20200101-0700" 'an expired slot record was retained'
assert_absent "$CASE_APP/results/20200101-0700" 'an expired result directory was retained'
assert_absent "$CASE_APP/home/state/review-sweep-cycle-receipts/20200101-0700.json" 'an expired receipt was retained'
assert_present "$CASE_APP/home/state/review-sweep-cycle-receipts/notes.txt" 'retention removed a file it does not own'
assert_present "$CASE_APP/state/slots/20200101-0800" 'retention removed an unexpectedly shaped entry'
assert_present "$CASE_APP/results/20200101-0900" 'retention followed a symlinked result path'
assert_present "$TMP_ROOT/linked-slot" 'retention deleted through a symlinked result path'
assert_present "$CASE_APP/state/slots/20260828-1330" 'retention removed a current slot record'
assert_present "$CASE_APP/home/state/review-sweep-cycle-receipts/20260828-1330.json" 'retention removed a current receipt'
pass 'retention prunes only expired supervisor-owned artifacts and refuses unexpected shapes'

STATUS_OUT=$(run_subject status) || fail "status failed: $STATUS_OUT"
assert_contains "$STATUS_OUT" 'launchagent-loaded: yes' 'status did not verify the loaded LaunchAgent'
assert_contains "$STATUS_OUT" 'max-concurrent-reviews: 10' 'status did not report the configured cap'
assert_contains "$STATUS_OUT" 'source-branch: main' 'status did not report the pinned branch'
assert_contains "$STATUS_OUT" 'retention-days: 90' 'status did not report artifact retention'
assert_contains "$STATUS_OUT" 'cycle: idle' 'status did not report an idle cycle'
assert_contains "$STATUS_OUT" 'last-slot-receipt-status: 0' 'status did not report the last verified receipt'
assert_contains "$STATUS_OUT" 'automation-inflight: 0' 'status did not verify terminal task metadata'
pass 'status reports the loaded job, schedule cap, pinned branch, retention, and terminal metadata'

UNINSTALL_OUT=$(run_subject uninstall) || fail "uninstall failed: $UNINSTALL_OUT"
assert_contains "$UNINSTALL_OUT" "retained-runtime: $CASE_APP" 'uninstall did not report retained recoverable state'
assert_absent "$CASE_LAUNCH_AGENT_DIR/dev.firstmate.review-sweep.plist" 'uninstall left the LaunchAgent property list'
assert_present "$CASE_APP/config/supervisor.conf" 'uninstall destroyed private configuration'
assert_present "$CASE_APP/home/state/review-sweep-cycle-receipts/20260826-0830.json" 'uninstall destroyed review receipts'
pass 'uninstall removes only the LaunchAgent and retains durable records'
