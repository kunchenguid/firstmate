#!/usr/bin/env bash
# Focused regression coverage for bin/fm-hermes-notify.sh: durable, idempotent
# Hermes/Telegram notification registration for a task held for the captain,
# duplicate suppression across the hold's own lifecycle identity, recovery
# after an interrupted send, and deterministic reply correlation back to the
# exact hold a Telegram reply answers - all against a fake `hermes` binary,
# never a live network call.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOTIFY="$ROOT/bin/fm-hermes-notify.sh"
INBOX="$ROOT/bin/fm-inbox.sh"
TMP_ROOT=$(fm_test_tmproot fm-hermes-notify)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_notify() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_TEST_HERMES_TARGETS_FILE="$home/hermes-targets.txt" \
    FM_TEST_HERMES_SEND_LOG="$home/hermes-send.log" \
    FM_TEST_HERMES_FAIL_ONCE="$home/hermes-fail-once" \
    "$NOTIFY" "$@"
}

run_inbox_note() {  # <home> <text>
  local home=$1 text=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$INBOX" note "$text" >/dev/null
}

# latest_note <home>: the most recently written state/inbox/*.note file.
latest_note() {  # <home>
  local home=$1 f newest='' newest_mtime=-1 mtime
  for f in "$home"/state/inbox/*.note; do
    [ -e "$f" ] || continue
    mtime=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null || echo 0)
    if [ "$mtime" -ge "$newest_mtime" ]; then
      newest=$f
      newest_mtime=$mtime
    fi
  done
  [ -n "$newest" ] || return 1
  printf '%s\n' "$newest"
}

# Installs a fake `hermes` that reads its behavior from three env vars the
# script under test is invoked with (run_notify sets them, so nothing about
# this fixture's own paths is baked into the generated script text):
#   FM_TEST_HERMES_TARGETS_FILE  one "telegram:<name> [<chat_id>]" line per
#                                 configured target; absent/empty means none.
#   FM_TEST_HERMES_SEND_LOG      every `send --to telegram:<id> <text>` call
#                                 is appended here as "to=<id> text=<text>".
#   FM_TEST_HERMES_FAIL_ONCE     when this path exists, the NEXT send call
#                                 fails (exit 1) and removes it, so a case can
#                                 force exactly one interrupted/failed attempt.
# configure_hermes <home> <target-line>... writes the targets file (or leaves
# it empty for "not configured") and installs the fake.
configure_hermes() {  # <home> <target-line>...
  local home=$1
  shift
  : > "$home/hermes-send.log"
  if [ "$#" -eq 0 ]; then
    : > "$home/hermes-targets.txt"
  else
    printf '%s\n' "$@" > "$home/hermes-targets.txt"
  fi
  cat > "$home/fakebin/hermes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = send ] && [ "${2:-}" = --list ] && [ "${3:-}" = telegram ]; then
  if [ -s "${FM_TEST_HERMES_TARGETS_FILE:-/dev/null}" ]; then
    cat "$FM_TEST_HERMES_TARGETS_FILE"
  else
    printf "%s\n" "no targets found for platform 'telegram'. Configured: (none)"
  fi
  exit 0
fi
if [ "${1:-}" = send ] && [ "${2:-}" = --to ]; then
  to=${3:-}
  shift 3
  if [ -n "${FM_TEST_HERMES_FAIL_ONCE:-}" ] && [ -e "$FM_TEST_HERMES_FAIL_ONCE" ]; then
    rm -f "$FM_TEST_HERMES_FAIL_ONCE"
    exit 1
  fi
  printf "to=%s text=%s\n" "$to" "$*" >> "$FM_TEST_HERMES_SEND_LOG"
  exit 0
fi
exit 2
SH
  chmod +x "$home/fakebin/hermes"
  run_notify "$home" presence away >/dev/null \
    || fail "could not put the test home into AWAY mode"
}

# Creates and holds a captain-facing task, returns nothing; the id is fixed by
# the caller.
hold_task() {  # <home> <id> [<title>]
  local home=$1 id=$2 title=${3:-"Captain call: $2"}
  tasks_in "$home" add "$id" "$title" --kind ship --repo sample \
    --body 'Sample body.' >/dev/null || fail "could not create task $id"
  run_captain "$home" hold "$id" --reason "captain decision pending" >/dev/null \
    || fail "could not hold task $id"
}

test_register_sends_and_records() {
  local home out
  home=$(make_home register-sends)
  configure_hermes "$home" 'telegram:Rajiv [8629896233]'
  hold_task "$home" sample-notify-one
  printf 'Captain, a decision is needed on sample-notify-one.\n' > "$home/reason.txt"
  out=$(run_notify "$home" register sample-notify-one --reason-file "$home/reason.txt") \
    || fail "register failed: $out"
  assert_contains "$out" "sent: sample-notify-one -> telegram:8629896233" \
    "register did not report a successful send"
  assert_grep "to=telegram:8629896233 text=Captain, a decision is needed on sample-notify-one." \
    "$home/hermes-send.log" "hermes was not invoked with the exact reason text"
  assert_grep "status=sent" "$home/state/hermes-notify/sample-notify-one.record" \
    "the durable record was not marked sent"
  pass "register sends the exact reason text and records status=sent"
}

test_register_refuses_when_not_an_active_hold() {
  local home out rc
  home=$(make_home register-not-held)
  configure_hermes "$home" 'telegram:Rajiv [8629896233]'
  tasks_in "$home" add sample-not-held "Not held" --kind ship --repo sample \
    --body 'Body.' >/dev/null
  printf 'reason\n' > "$home/reason.txt"
  set +e
  out=$(run_notify "$home" register sample-not-held --reason-file "$home/reason.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "register succeeded for a task that is not an active captain hold"
  [ -s "$home/hermes-send.log" ] && fail "a send was logged for a non-held task"
  pass "register refuses a task that is not an active captain hold"
}

test_register_is_idempotent_within_same_lifecycle() {
  local home out calls
  home=$(make_home register-dup)
  configure_hermes "$home" 'telegram:Rajiv [8629896233]'
  hold_task "$home" sample-notify-dup
  printf 'reason text\n' > "$home/reason.txt"
  run_notify "$home" register sample-notify-dup --reason-file "$home/reason.txt" >/dev/null \
    || fail "first register failed"
  out=$(run_notify "$home" register sample-notify-dup --reason-file "$home/reason.txt") \
    || fail "second register failed: $out"
  assert_contains "$out" "duplicate:" "a second register within the same hold lifecycle was not reported as a duplicate"
  calls=$(wc -l < "$home/hermes-send.log" | tr -d '[:space:]')
  assert_equals 1 "$calls" "a duplicate registration sent a second Telegram message"
  pass "register is idempotent for a second call within the same hold lifecycle"
}

test_register_resends_after_new_hold_lifecycle() {
  local home out calls
  home=$(make_home register-relifecycle)
  configure_hermes "$home" 'telegram:Rajiv [8629896233]'
  hold_task "$home" sample-notify-cycle
  printf 'reason one\n' > "$home/reason.txt"
  run_notify "$home" register sample-notify-cycle --reason-file "$home/reason.txt" >/dev/null \
    || fail "first register failed"
  printf 'the captain answered\n' > "$home/decision.txt"
  run_captain "$home" answer sample-notify-cycle --decision-file "$home/decision.txt" --release >/dev/null \
    || fail "could not release the hold"
  run_captain "$home" hold sample-notify-cycle --reason "a fresh decision is pending" >/dev/null \
    || fail "could not re-hold the task for a new lifecycle"
  printf 'reason two\n' > "$home/reason2.txt"
  out=$(run_notify "$home" register sample-notify-cycle --reason-file "$home/reason2.txt") \
    || fail "register after re-hold failed: $out"
  assert_contains "$out" "sent:" "a fresh hold lifecycle did not send a fresh notification"
  calls=$(wc -l < "$home/hermes-send.log" | tr -d '[:space:]')
  assert_equals 2 "$calls" "a new hold lifecycle did not produce a second, independent send"
  pass "register sends again after the task is released and re-held into a new lifecycle"
}

test_register_recovers_from_interrupted_send() {
  local home out
  home=$(make_home register-recover)
  configure_hermes "$home" 'telegram:Rajiv [8629896233]'
  hold_task "$home" sample-notify-crash
  printf 'reason\n' > "$home/reason.txt"
  : > "$home/hermes-fail-once"
  set +e
  out=$(run_notify "$home" register sample-notify-crash --reason-file "$home/reason.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a failed hermes send was reported as success"
  assert_grep "status=failed" "$home/state/hermes-notify/sample-notify-crash.record" \
    "an interrupted send did not leave a recoverable failed record"
  out=$(run_notify "$home" register sample-notify-crash --reason-file "$home/reason.txt") \
    || fail "retry after a failed send did not succeed: $out"
  assert_contains "$out" "sent:" "a retry after a failed send was not reported as sent"
  assert_grep "status=sent" "$home/state/hermes-notify/sample-notify-crash.record" \
    "the record was not updated to sent after a successful retry"
  local calls
  calls=$(wc -l < "$home/hermes-send.log" | tr -d '[:space:]')
  assert_equals 1 "$calls" "the failed attempt was logged as a successful send"
  pass "register retries and recovers after an interrupted or failed send"
}

test_register_skips_silently_when_hermes_not_configured() {
  local home out
  home=$(make_home register-unconfigured)
  configure_hermes "$home"
  hold_task "$home" sample-notify-unconfigured
  printf 'reason\n' > "$home/reason.txt"
  out=$(run_notify "$home" register sample-notify-unconfigured --reason-file "$home/reason.txt") \
    || fail "register with no configured target should exit 0, not fail: $out"
  assert_contains "$out" "skipped:" "register did not report skipping an unconfigured home"
  [ -s "$home/hermes-send.log" ] && fail "a send was attempted with no configured Telegram target"
  pass "register is a silent no-op when hermes has no configured Telegram target"
}

test_register_refuses_ambiguous_multiple_targets() {
  local home out rc
  home=$(make_home register-ambiguous)
  configure_hermes "$home" 'telegram:Rajiv [8629896233]' 'telegram:Other [111]'
  hold_task "$home" sample-notify-ambiguous
  printf 'reason\n' > "$home/reason.txt"
  set +e
  out=$(run_notify "$home" register sample-notify-ambiguous --reason-file "$home/reason.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "register guessed a target among multiple configured Telegram targets"
  [ -s "$home/hermes-send.log" ] && fail "a send was attempted despite an ambiguous target set"
  pass "register refuses rather than guessing among multiple configured Telegram targets"
}

test_resolve_reply_correlates_and_closes_through_the_keyed_intake() {
  local home note_file tsv show
  home=$(make_home resolve-reply)
  configure_hermes "$home" 'telegram:Rajiv [8629896233]'
  hold_task "$home" sample-notify-reply
  printf 'Captain, please confirm the plan.\n' > "$home/reason.txt"
  run_notify "$home" register sample-notify-reply --reason-file "$home/reason.txt" >/dev/null \
    || fail "register failed"
  run_inbox_note "$home" "[Telegram from Rajiv (chat 8629896233)] yes, go ahead"
  note_file=$(latest_note "$home") || fail "no inbox note was written"
  tsv=$(run_notify "$home" resolve-reply "$note_file") || fail "resolve-reply did not correlate a matching reply"
  assert_equals "$(printf 'sample-notify-reply\tyes, go ahead\tsample-notify-reply')" "$tsv" \
    "resolve-reply did not print the exact task id, unmodified reply text, and label"
  printf '%s\n' "$tsv" | run_captain "$home" answers --source hermes-telegram >/dev/null \
    || fail "the correlated reply did not close through the keyed-answer intake"
  show=$(tasks_in "$home" show sample-notify-reply --full)
  assert_contains "$show" "state: done" "the correlated Telegram reply did not close the captain hold"
  assert_contains "$show" "Answer: yes, go ahead" \
    "the captain's exact reply text was not recorded as the answer"
  pass "resolve-reply correlates an inbound Telegram reply to its exact hold and the answer closes it verbatim"
}

test_resolve_reply_ignores_a_notification_whose_hold_already_closed() {
  local home note_file out rc
  home=$(make_home resolve-reply-closed)
  configure_hermes "$home" 'telegram:Rajiv [8629896233]'
  hold_task "$home" sample-notify-closed
  printf 'reason\n' > "$home/reason.txt"
  run_notify "$home" register sample-notify-closed --reason-file "$home/reason.txt" >/dev/null \
    || fail "register failed"
  printf 'answered elsewhere\n' > "$home/decision.txt"
  run_captain "$home" answer sample-notify-closed --decision-file "$home/decision.txt" >/dev/null \
    || fail "could not close the hold through the ordinary answer path"
  run_inbox_note "$home" "[Telegram from Rajiv (chat 8629896233)] unrelated later message"
  note_file=$(latest_note "$home") || fail "no inbox note was written"
  set +e
  out=$(run_notify "$home" resolve-reply "$note_file" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "resolve-reply matched a notification whose hold was already closed by another channel"
  assert_contains "$out" "no open Hermes notification" "the refusal did not explain that no open notification correlates"
  pass "resolve-reply does not match a notification whose hold already closed through another channel"
}

test_resolve_reply_rejects_a_non_telegram_note() {
  local home note_file out rc
  home=$(make_home resolve-reply-nontelegram)
  configure_hermes "$home" 'telegram:Rajiv [8629896233]'
  hold_task "$home" sample-notify-voice
  printf 'reason\n' > "$home/reason.txt"
  run_notify "$home" register sample-notify-voice --reason-file "$home/reason.txt" >/dev/null \
    || fail "register failed"
  run_inbox_note "$home" "an ordinary voice-relay note with no Telegram provenance"
  note_file=$(latest_note "$home") || fail "no inbox note was written"
  set +e
  out=$(run_notify "$home" resolve-reply "$note_file" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "resolve-reply matched a note that never carried the Telegram convention"
  assert_contains "$out" "does not match" "the refusal did not name the missing Telegram convention"
  pass "resolve-reply never claims an ordinary, non-Telegram note as a correlated reply"
}

test_register_flattens_a_label_that_attempts_to_forge_record_fields() {
  local home record forged_chat tsv note_file
  home=$(make_home register-label-injection)
  configure_hermes "$home" 'telegram:Rajiv [8629896233]'
  hold_task "$home" sample-notify-forge
  printf 'Captain, please confirm the plan.\n' > "$home/reason.txt"
  forged_chat=999999999
  run_notify "$home" register sample-notify-forge --reason-file "$home/reason.txt" \
    --label "$(printf 'legit note\nchat_id=%s' "$forged_chat")" >/dev/null \
    || fail "register with a newline-bearing label failed"
  record="$home/state/hermes-notify/sample-notify-forge.record"
  grep -Fxq "chat_id=$forged_chat" "$record" \
    && fail "an embedded newline in --label forged a chat_id= record line"
  grep -Fxq "chat_id=8629896233" "$record" \
    || fail "the record's real chat_id line was lost or displaced"
  run_inbox_note "$home" "[Telegram from Rajiv (chat 8629896233)] confirmed"
  note_file=$(latest_note "$home") || fail "no inbox note was written"
  tsv=$(run_notify "$home" resolve-reply "$note_file") \
    || fail "resolve-reply did not correlate the reply from the real configured chat"
  assert_equals "$(printf 'sample-notify-forge\tconfirmed\tlegit note chat_id=%s' "$forged_chat")" "$tsv" \
    "resolve-reply did not return the exact task id and a flattened, single-line label"
  pass "an embedded newline in --label cannot forge a chat_id= or other record field"
}

test_status_reports_absent_and_present_records() {
  local home out
  home=$(make_home status)
  configure_hermes "$home" 'telegram:Rajiv [8629896233]'
  out=$(run_notify "$home" status sample-notify-absent)
  assert_equals absent "$out" "status did not report an absent record correctly"
  hold_task "$home" sample-notify-status
  printf 'reason\n' > "$home/reason.txt"
  run_notify "$home" register sample-notify-status --reason-file "$home/reason.txt" >/dev/null \
    || fail "register failed"
  out=$(run_notify "$home" status sample-notify-status)
  assert_contains "$out" "task=sample-notify-status" "status did not report the task field"
  assert_contains "$out" "status=sent" "status did not report the current send status"
  pass "status reports absent and present notification records without mutating anything"
}

test_presence_defaults_home_and_persists_transitions() {
  local home out
  home=$(make_home presence)
  out=$(run_notify "$home" presence status)
  assert_equals HOME "$out" "an absent presence record did not default HOME"
  out=$(run_notify "$home" presence away)
  assert_contains "$out" "now AWAY" "the AWAY transition was not clearly acknowledged"
  assert_equals AWAY "$(run_notify "$home" presence status)" "AWAY did not persist across invocations"
  out=$(run_notify "$home" presence away)
  assert_contains "$out" "already AWAY" "an idempotent AWAY command was not acknowledged"
  out=$(run_notify "$home" presence home)
  assert_contains "$out" "now HOME" "the HOME transition was not clearly acknowledged"
  printf 'schema=unknown\nmode=AWAY\n' > "$home/state/captain-presence"
  assert_equals HOME "$(run_notify "$home" presence status)" "an invalid presence record did not fail safe to HOME"
  pass "presence defaults HOME, acknowledges idempotent transitions, persists, and fails safe"
}

test_home_and_away_route_only_eligible_notifications() {
  local home out calls rc
  home=$(make_home presence-routing)
  configure_hermes "$home" 'telegram:Rajiv [8629896233]'
  printf 'A meaningful blocker needs attention.\n' > "$home/message.txt"
  run_notify "$home" presence home >/dev/null
  out=$(run_notify "$home" route blocker --message-file "$home/message.txt" --key blocked-one)
  assert_contains "$out" "presence is HOME" "HOME did not suppress proactive routing"
  calls=$(wc -l < "$home/hermes-send.log" | tr -d '[:space:]')
  assert_equals 0 "$calls" "HOME proactively sent a blocker"
  hold_task "$home" presence-hold
  printf 'A Captain hold needs a decision.\n' > "$home/hold.txt"
  out=$(run_notify "$home" register presence-hold --reason-file "$home/hold.txt")
  assert_contains "$out" "presence is HOME" "HOME did not suppress a Captain hold"
  run_notify "$home" presence away >/dev/null
  out=$(run_notify "$home" register presence-hold --reason-file "$home/hold.txt")
  assert_contains "$out" "sent:" "AWAY did not route a Captain hold"
  out=$(run_notify "$home" route blocker --message-file "$home/message.txt" --key blocked-one)
  assert_contains "$out" "sent:" "AWAY did not route an eligible blocker"
  out=$(run_notify "$home" route blocker --message-file "$home/message.txt" --key blocked-one)
  assert_contains "$out" "duplicate:" "a repeated routed event was not suppressed"
  calls=$(wc -l < "$home/hermes-send.log" | tr -d '[:space:]')
  assert_equals 2 "$calls" "duplicate suppression did not keep one send for each eligible event"
  set +e
  out=$(run_notify "$home" route routine --message-file "$home/message.txt" --key routine-one 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an ineligible routine event class was accepted"
  pass "HOME stays quiet while AWAY routes only eligible classes with durable dedupe"
}

test_inbound_mode_and_status_commands_work_in_both_modes() {
  local home note out
  home=$(make_home inbound-commands)
  configure_hermes "$home" 'telegram:Rajiv [8629896233]'
  run_inbox_note "$home" "[Telegram from Rajiv (chat 8629896233)] I'm back home, stop proactive Telegram notifications"
  note=$(latest_note "$home")
  out=$(run_notify "$home" inbound "$note") || fail "natural-language HOME command failed"
  assert_equals mode:HOME "$out" "natural-language HOME command was not classified"
  assert_equals HOME "$(run_notify "$home" presence status)" "inbound HOME did not persist"
  rm -f "$home/state/inbox"/*.note
  run_inbox_note "$home" "[Telegram from Rajiv (chat 8629896233)] status report"
  note=$(latest_note "$home")
  out=$(run_notify "$home" inbound "$note") || fail "HOME status request failed"
  assert_contains "$out" "request:status" "status request was unavailable at HOME"
  rm -f "$home/state/inbox"/*.note
  run_inbox_note "$home" "[Telegram from Rajiv (chat 8629896233)] I’m heading out, use Telegram"
  note=$(latest_note "$home")
  out=$(run_notify "$home" inbound "$note") || fail "natural-language AWAY command failed"
  assert_equals mode:AWAY "$out" "natural-language AWAY command was not classified"
  rm -f "$home/state/inbox"/*.note
  run_inbox_note "$home" "[Telegram from Rajiv (chat 8629896233)] status"
  note=$(latest_note "$home")
  out=$(run_notify "$home" inbound "$note") || fail "AWAY status request failed"
  assert_contains "$out" "request:status" "status request was unavailable at AWAY"
  assert_grep 'Captain presence is now HOME' "$home/hermes-send.log" "HOME was not acknowledged on Telegram"
  assert_grep 'Captain presence is now AWAY' "$home/hermes-send.log" "AWAY was not acknowledged on Telegram"
  pass "Telegram mode commands and inbound status requests work in HOME and AWAY"
}

test_mode_commands_do_not_answer_or_release_holds() {
  local home note show
  home=$(make_home mode-authority)
  configure_hermes "$home" 'telegram:Rajiv [8629896233]'
  hold_task "$home" authority-hold
  run_inbox_note "$home" "[Telegram from Rajiv (chat 8629896233)] Captain home"
  note=$(latest_note "$home")
  run_notify "$home" inbound "$note" >/dev/null || fail "Captain home command failed"
  show=$(tasks_in "$home" show authority-hold --full)
  assert_contains "$show" "held: yes" "a mode command removed the hold"
  assert_contains "$show" "hold_kind: captain" "a mode command changed hold authorization semantics"
  pass "presence commands change routing only and never answer or release a hold"
}

test_register_sends_and_records
test_register_refuses_when_not_an_active_hold
test_register_is_idempotent_within_same_lifecycle
test_register_resends_after_new_hold_lifecycle
test_register_recovers_from_interrupted_send
test_register_skips_silently_when_hermes_not_configured
test_register_refuses_ambiguous_multiple_targets
test_resolve_reply_correlates_and_closes_through_the_keyed_intake
test_resolve_reply_ignores_a_notification_whose_hold_already_closed
test_resolve_reply_rejects_a_non_telegram_note
test_register_flattens_a_label_that_attempts_to_forge_record_fields
test_status_reports_absent_and_present_records
test_presence_defaults_home_and_persists_transitions
test_home_and_away_route_only_eligible_notifications
test_inbound_mode_and_status_commands_work_in_both_modes
test_mode_commands_do_not_answer_or_release_holds
