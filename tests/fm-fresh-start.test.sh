#!/usr/bin/env bash
# tests/fm-fresh-start.test.sh - the daily fresh start of a Claude primary
# (bin/fm-fresh-start-lib.sh): it saves first, clears only after a same-day
# save, runs only inside the quiet window, never runs while anything that
# lives only in the conversation could be dropped, ignores durable records that
# are printed again at session start, and tells the captain once when it has
# not run for two days.
#
# Drives fm_fresh_start_step through its public interface with the backend
# primitives replaced by recorders, and the clock by a fake `date` on PATH, so
# what is asserted is exactly what would be typed into the primary. The outcome
# store, status logs, and captain holds are the real records, written through
# their own scripts. The live proof against a real Claude primary is recorded
# in the PR evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fresh-start)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat >"$FAKEBIN/date" <<'SH'
#!/bin/sh
case "${1:-}" in
  +%H) printf '%s\n' "${FAKE_HOUR:?}" ;;
  +%Y-%m-%d) printf '%s\n' "${FAKE_DAY:?}" ;;
  +%s) if [ -n "${FAKE_EPOCH:-}" ]; then printf '%s\n' "$FAKE_EPOCH"; else exec /bin/date "$@"; fi ;;
  *) exec /bin/date "$@" ;;
esac
SH
chmod +x "$FAKEBIN/date"

# step <case-dir> [ignored]: run one step in a fresh shell; prints the
# verdict, and the typed lines land in <case-dir>/typed. TRANSCRIPT names the
# primary's current session transcript (default the case's own). An executable
# <case-dir>/on-busy or on-composer runs inside that probe, so a case can make
# something arrive between the step's first checks and its keystroke.
step() {
  local dir=$1
  PATH="$FAKEBIN:$PATH" FM_FRESH_START_SETTLE=0 CASE_DIR="$dir" FM_HOME="$dir" \
    TRANSCRIPT="${TRANSCRIPT:-$dir/transcript.jsonl}" bash -c '
    . "$1/bin/fm-warm-compact-lib.sh"
    . "$1/bin/fm-fresh-start-lib.sh"
    fm_backend_busy_state() { [ ! -x "$CASE_DIR/on-busy" ] || "$CASE_DIR/on-busy" >/dev/null 2>&1; cat "$CASE_DIR/busy" 2>/dev/null || printf "idle\n"; }
    fm_backend_composer_state() { [ ! -x "$CASE_DIR/on-composer" ] || "$CASE_DIR/on-composer" >/dev/null 2>&1; cat "$CASE_DIR/composer" 2>/dev/null || printf "empty\n"; }
    fm_backend_send_text_submit() {
      if [ -f "$CASE_DIR/send-fails" ] && grep -qxF -- "$3" "$CASE_DIR/send-fails"; then printf "text\n"; return 0; fi
      printf "%s\n" "$3" >> "$CASE_DIR/typed"; printf "empty\n"
    }
    fm_fresh_start_step "$CASE_DIR/config" "$CASE_DIR/state" herdr pane-1 "$TRANSCRIPT"
  ' _ "$ROOT"
}

# The primary's own turn boundaries, as its prompt-submit and Stop hooks
# deliver them (bin/fm-host-mirror.sh hook claude calls fm_fresh_start_hook).
hook_event() {  # <event> <payload>
  PATH="$FAKEBIN:$PATH" bash -c '. "$1/bin/fm-fresh-start-lib.sh"; fm_fresh_start_hook "$2" "$3" "$4"' \
    _ "$ROOT" "$CASE/state" "$1" "$2"
}
turn_ends() { hook_event Stop "$(jq -cn --arg t "${TRANSCRIPT:-$CASE/transcript.jsonl}" '{hook_event_name: "Stop", transcript_path: $t}')"; }
prompted() { hook_event UserPromptSubmit "$(jq -cn --arg p "$1" '{hook_event_name: "UserPromptSubmit", prompt: $p}')"; }

new_case() {  # <name> [context-tokens] -> sets CASE
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE/config" "$CASE/state" "$CASE/data"
  : >"$CASE/config/daily-fresh-start"
  printf '{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0}}}\n' \
    "${2:-300000}" >"$CASE/transcript.jsonl"
  : >"$CASE/typed"
}

typed() { cat "$CASE/typed"; }
record() { sed -n "s/^$1=//p" "$CASE/state/.daily-fresh-start" 2>/dev/null; }
outcomes() { FM_STATE_OVERRIDE="$CASE/state" "$ROOT/bin/fm-branch-outcome.sh" "$@" >/dev/null </dev/null || fail "outcome store: $*"; }
ask() { FM_STATE_OVERRIDE="$CASE/state" "$ROOT/bin/fm-chat-question.sh" "$@" </dev/null; }
attest() { PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$CASE/state" "$ROOT/bin/fm-fresh-start.sh" attest "$1" >/dev/null 2>&1; }
hold() {  # <task> <reason>
  FM_HOME="$CASE" "$ROOT/bin/fm-captain-hold.sh" hold "$1" --title "$2" --reason "$2" >"$CASE/hold.out" 2>&1 </dev/null \
    || fail "hold $1: $(tail -3 "$CASE/hold.out")"
}

# What the stow turn leaves in a Claude Code transcript, in the shape a live
# skill invocation recorded (2.1.325): the human prompt as a string carrying
# the command and its arguments, then the injected skill text marked isMeta.
stow_turn() {  # <nonce>
  {
    jq -cn --arg n "$1" '{type: "user", message: {role: "user", content: ("<command-message>stow</command-message>\n<command-name>/stow</command-name>\n<command-args>daily-fresh-start " + $n + "</command-args>")}}'
    jq -cn '{type: "user", isMeta: true, message: {role: "user", content: [{type: "text", text: "Base directory for this skill: ..."}]}}'
    printf '{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":300000,"cache_creation_input_tokens":0}}}\n'
  } >>"$CASE/transcript.jsonl"
}

export FAKE_DAY=2030-01-02 FAKE_HOUR=04

test_off_window_small() {
  new_case off
  rm -f "$CASE/config/daily-fresh-start"
  assert_equals off "$(step "$CASE")" "no setting means off"
  new_case window
  assert_equals window "$(FAKE_HOUR=12 step "$CASE")" "noon is outside the default 04-07 window"
  assert_equals window "$(FAKE_HOUR=07 step "$CASE")" "the window closes at hour+window"
  new_case small 90000
  assert_equals small "$(step "$CASE")" "a 90000-token session is below the default 100000"
  new_case wrap
  printf 'hour=23\nwindow-hours=3\n' >"$CASE/config/daily-fresh-start"
  assert_equals saving "$(FAKE_HOUR=01 step "$CASE")" "a window opened at 23 is still open at 01"
  [ ! -s "$TMP_ROOT/off/typed" ] && [ ! -s "$TMP_ROOT/window/typed" ] && [ ! -s "$TMP_ROOT/small/typed" ] \
    || fail "an off, out-of-window or small verdict must type nothing"
  pass "off, outside the window, and small sessions type nothing; the window wraps past midnight"
}

test_gate_holds_every_step() {
  local name reason
  while IFS='|' read -r name reason; do
    new_case "gate-$name"
    case "$name" in
      afk) : >"$CASE/state/.afk" ;;
      queue) printf '1\t2030\tsignal\tt1\tsignal: t1 done\n' >"$CASE/state/.wake-queue" ;;
      handoff) : >"$CASE/state/.supervision-handoff-pending" ;;
      reply) mkdir -p "$CASE/state/pending-replies" && : >"$CASE/state/pending-replies/corr-1" ;;
      unread) outcomes append --task t1 --verdict captain --summary 'pick A or B' ;;
      note) mkdir -p "$CASE/state/inbox" && : >"$CASE/state/inbox/1.note" ;;
      chat) ask open pick-layout 'which layout, A or B' >/dev/null ;;
      chat-file) printf 'x\n' >"$CASE/state/chat-questions" ;;
      chat-dangling) ln -s "$CASE/missing-dir" "$CASE/state/chat-questions" ;;
      corrupt) printf 'not-json\n' >"$CASE/state/branch-outcomes.jsonl" ;;
      tail) outcomes append --task t1 --verdict routine --summary 'note'; printf 'not-json\n' >>"$CASE/state/branch-outcomes.jsonl" ;;
      queue-dir) mkdir "$CASE/state/.wake-queue" ;;
      replies-file) printf 'x\n' >"$CASE/state/pending-replies" ;;
      inbox-file) printf 'x\n' >"$CASE/state/inbox" ;;
      queue-torn) printf 'torn pending wake\n' >"$CASE/state/.wake-queue" ;;
      queue-unterminated) printf '1\t2030\tsignal\tt1\tsignal: t1 do' >"$CASE/state/.wake-queue" ;;
      queue-mixed) printf '1\t2030\tsignal\tt1\tsignal: t1 done\ngarbage\n' >"$CASE/state/.wake-queue" ;;
      queue-badseq) printf '1\tx\tsignal\tt1\tsignal: t1 done\n' >"$CASE/state/.wake-queue" ;;
      store-dangling) ln -s "$CASE/missing.jsonl" "$CASE/state/branch-outcomes.jsonl" ;;
      store-dir) mkdir "$CASE/state/branch-outcomes.jsonl" ;;
      replies-dangling) ln -s "$CASE/missing-dir" "$CASE/state/pending-replies" ;;
      inbox-dangling) ln -s "$CASE/missing-dir" "$CASE/state/inbox" ;;
      afk-dangling) ln -s "$CASE/missing" "$CASE/state/.afk" ;;
      handoff-dangling) ln -s "$CASE/missing" "$CASE/state/.supervision-handoff-pending" ;;
    esac
    assert_equals "waiting:$reason" "$(step "$CASE")" "$name must hold the save step"
    [ ! -s "$CASE/typed" ] || fail "$name: a held step typed: $(typed)"
    [ ! -e "$CASE/state/.daily-fresh-start" ] || fail "$name: a held step recorded progress"
  done <<'ROWS'
afk|away or quiet mode
queue|a queued wake
handoff|a supervision handoff
reply|a secondmate reply
unread|an unread captain outcome
note|a captain inbox note
chat|an unanswered chat question (pick-layout)
chat-file|an unreadable chat-question record
chat-dangling|an unreadable chat-question record
corrupt|an unreadable outcome store
tail|an unreadable outcome store
queue-dir|an unreadable wake queue
replies-file|an unreadable pending-reply record
inbox-file|an unreadable captain inbox
queue-torn|an unreadable wake queue
queue-unterminated|an unreadable wake queue
queue-mixed|an unreadable wake queue
queue-badseq|an unreadable wake queue
store-dangling|an unreadable outcome store
store-dir|an unreadable outcome store
replies-dangling|an unreadable pending-reply record
inbox-dangling|an unreadable captain inbox
afk-dangling|away or quiet mode
handoff-dangling|a supervision handoff
ROWS
  # The same gate holds the clear step after a save.
  new_case gate-clear
  assert_equals saving "$(step "$CASE" 100)" "the save step runs on a quiet home"
  stow_turn "$(record nonce)"
  attest "$(record nonce)" || fail "the save attempt's own nonce must attest"
  turn_ends
  ask open pick-layout 'which layout, A or B' >/dev/null
  assert_equals 'waiting:an unanswered chat question (pick-layout)' "$(step "$CASE" 99999999999)" "an unanswered chat question must hold the clear step too"
  [ "$(grep -c . "$CASE/typed")" = 1 ] || fail "a held clear step types nothing after the save: $(typed)"
  # A damaged input that appears between an attested save and the clear holds
  # the clear: an interrupted append or a broken link is not proof of quiet.
  local damage
  for damage in queue-torn store-dangling replies-dangling; do
    new_case "clear-$damage"
    assert_equals saving "$(step "$CASE" 100)" "$damage: the save step runs on a quiet home"
    stow_turn "$(record nonce)"
    attest "$(record nonce)" || fail "$damage: the save attempt's own nonce must attest"
    turn_ends
    case "$damage" in
      queue-torn) printf 'torn pending wake\n' >"$CASE/state/.wake-queue" ;;
      store-dangling) ln -s "$CASE/missing.jsonl" "$CASE/state/branch-outcomes.jsonl" ;;
      replies-dangling) ln -s "$CASE/missing-dir" "$CASE/state/pending-replies" ;;
    esac
    case "$(step "$CASE" 99999999999)" in
      waiting:*) ;;
      *) fail "$damage must hold the clear step" ;;
    esac
    if grep -qx /clear "$CASE/typed"; then fail "$damage: /clear was typed"; fi
  done
  # Blank lines alone are still an empty queue.
  new_case queue-blank
  printf '\n\n' >"$CASE/state/.wake-queue"
  assert_equals saving "$(step "$CASE")" "a queue of blank lines is empty"
  pass "every gate reason, and every input the gate cannot read, holds both steps and types or records nothing"
}

# The captain's rule: durable records that survive a restart and are printed
# again at session start do not hold a fresh start, however long they stay.
test_durable_records_do_not_hold() {
  local name
  for name in held transferred decision blocked unprocessed linked dirlog no-backlog; do
    new_case "durable-$name"
    case "$name" in
      held) hold t-pick 'choose A or B' ;;
      transferred)
        printf 'needs-decision [at=1] [key=pick]: A or B\ncaptain-held [at=2] [key=pick]: moved to t-pick\n' >"$CASE/state/t1.status"
        hold t-pick 'choose A or B' ;;
      decision) printf 'needs-decision [at=1] [key=pick]: A or B\n' >"$CASE/state/t1.status" ;;
      blocked) printf 'blocked [at=1]: need a login\n' >"$CASE/state/t2.status" ;;
      unprocessed) outcomes append --task t1 --verdict captain --summary 'pick A or B'; outcomes mark-read --through 1 ;;
      linked) printf 'working [at=1]: x\n' >"$CASE/elsewhere.status"; ln -s "$CASE/elsewhere.status" "$CASE/state/t3.status" ;;
      dirlog) mkdir "$CASE/state/t4.status" ;;
      no-backlog) rm -rf "$CASE/data"; printf 'x\n' >"$CASE/data" ;;
    esac
    assert_equals saving "$(step "$CASE")" "$name is a durable record printed at session start and must not hold the step"
  done
  pass "captain holds, open worker decisions and blockers, presented outcomes, and status logs or a backlog it no longer reads never hold a fresh start"
}

# A question asked only in chat is known from its record, never from the
# conversation's words: open while unanswered, closed once answered.
test_chat_question_record() {
  local out
  new_case chat-record
  [ ! -e "$CASE/state/chat-questions" ] || fail "no question asked leaves no record"
  out=$(ask open pick-layout 'which layout, A or B') || fail "open must succeed"
  case "$out" in *pick-layout*) ;; *) fail "open names the key: $out" ;; esac
  ask open name-it "$(printf 'what\tshould it\nbe called')" >/dev/null || fail "a second question opens"
  assert_equals "what should it be called" "$(sed -n 's/^summary=//p' "$CASE/state/chat-questions/name-it.question")" \
    "tabs and newlines in the summary become spaces"
  [[ "$(sed -n 's/^asked=//p' "$CASE/state/chat-questions/pick-layout.question")" =~ ^[0-9]+$ ]] || fail "the record holds when the question was asked"
  assert_equals 'waiting:an unanswered chat question (name-it)' "$(step "$CASE")" "the gate names the first open question"
  ask close name-it >/dev/null || fail "close succeeds"
  assert_equals 'waiting:an unanswered chat question (pick-layout)' "$(step "$CASE")" "one open question still holds"
  ask close pick-layout >/dev/null || fail "close succeeds"
  if ask close pick-layout >/dev/null 2>&1; then fail "closing a question that is not open must fail"; fi
  assert_equals saving "$(step "$CASE")" "once every question is answered the step runs"
  local bad rc
  for bad in '' .hidden 'a/b' 'sp ace' "$(printf 'x%.0s' $(seq 1 65))"; do
    rc=0; ask open "$bad" summary >/dev/null 2>&1 || rc=$?
    assert_equals 2 "$rc" "key '$bad' is a usage error"
  done
  rc=0; ask open fine '' >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "an empty summary is a usage error"
  new_case chat-temp
  mkdir -p "$CASE/state/chat-questions"
  : >"$CASE/state/chat-questions/.question.abc123"
  assert_equals saving "$(step "$CASE")" "a half-written temp record is not an open question"
  pass "a chat question is recorded when asked, holds the fresh start while open, and clears when answered; bad keys and summaries are refused"
}

# The safety net: two days and one window without a fresh start sends the
# captain exactly one note naming the reason, then nothing until one runs.
test_stall_note_once() {
  local e
  new_case stall
  e=2000000000
  ask open pick-layout 'which layout, A or B' >/dev/null
  assert_equals 'waiting:an unanswered chat question (pick-layout)' "$(FAKE_EPOCH=$e step "$CASE")" "the step waits"
  assert_equals "$e" "$(sed -n 's/^last=//p' "$CASE/state/.daily-fresh-start-history")" "the first step starts the count"
  FAKE_EPOCH=$((e + 2 * 86400 + 3 * 3600 - 1)) step "$CASE" >/dev/null
  [ ! -e "$CASE/state/.wake-queue" ] || fail "no note before two days and one window: $(cat "$CASE/state/.wake-queue")"
  FAKE_HOUR=12 FAKE_EPOCH=$((e + 2 * 86400 + 3 * 3600)) step "$CASE" >/dev/null
  assert_equals 1 "$(grep -c . "$CASE/state/.wake-queue")" "exactly one note once two days and one window passed"
  assert_equals "check	daily-fresh-start-stalled:$e" "$(cut -f3,4 "$CASE/state/.wake-queue")" "the note is a check wake keyed by the stalled count"
  grep -q 'has not run for two days because it was waiting on an unanswered chat question (pick-layout); tell the captain once' "$CASE/state/.wake-queue" \
    || fail "the note names the reason: $(cut -f5 "$CASE/state/.wake-queue")"
  FAKE_EPOCH=$((e + 5 * 86400)) step "$CASE" >/dev/null
  FAKE_HOUR=12 FAKE_EPOCH=$((e + 9 * 86400)) step "$CASE" >/dev/null
  assert_equals 1 "$(grep -c . "$CASE/state/.wake-queue")" "no second note while it still has not run"
  # It runs again (here: not due, because the conversation is small), which
  # restarts the count; a later stall sends one new note.
  : >"$CASE/state/.wake-queue"
  ask close pick-layout >/dev/null
  printf '{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":0}}}\n' >>"$CASE/transcript.jsonl"
  assert_equals small "$(FAKE_EPOCH=$((e + 10 * 86400)) step "$CASE")" "a small conversation is not due"
  assert_equals "$((e + 10 * 86400))" "$(sed -n 's/^last=//p' "$CASE/state/.daily-fresh-start-history")" "not due counts as run"
  printf 'busy\n' >"$CASE/busy"
  printf '{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":300000,"cache_creation_input_tokens":0}}}\n' >>"$CASE/transcript.jsonl"
  assert_equals busy "$(FAKE_EPOCH=$((e + 11 * 86400)) step "$CASE")" "a busy session defers the step"
  FAKE_HOUR=12 FAKE_EPOCH=$((e + 12 * 86400 + 3 * 3600)) step "$CASE" >/dev/null
  assert_equals 1 "$(grep -c . "$CASE/state/.wake-queue")" "a new stall sends one new note"
  grep -q "daily-fresh-start-stalled:$((e + 10 * 86400))	check: the daily fresh start has not run for two days because the session was busy whenever it looked" "$CASE/state/.wake-queue" \
    || fail "the new note carries the new count and reason: $(cat "$CASE/state/.wake-queue")"
  # Turning the setting off forgets the count.
  rm -f "$CASE/config/daily-fresh-start"
  assert_equals off "$(step "$CASE")" "off"
  [ ! -e "$CASE/state/.daily-fresh-start-history" ] || fail "off forgets the history"
  pass "two days and one window without a fresh start queue one note naming the reason, then nothing until it runs again; off resets the count"
}

test_settled_records_do_not_hold() {
  new_case settled
  printf 'needs-decision [at=1] [key=pick]: A or B\nresolved [at=2] [key=pick]: B\n' >"$CASE/state/t1.status"
  outcomes append --task t1 --verdict captain --summary 'pick A or B'
  outcomes append --task t2 --verdict routine --summary 'progress'
  outcomes mark-read --through 2
  outcomes mark-processed --through 1
  mkdir -p "$CASE/state/pending-replies" "$CASE/state/inbox"
  assert_equals saving "$(step "$CASE")" "resolved decisions, processed outcomes and empty directories must not hold the step"
  pass "settled decisions, processed outcomes and empty record directories do not hold a fresh start"
}

test_busy_and_composer() {
  new_case busy
  printf 'busy\n' >"$CASE/busy"
  assert_equals busy "$(step "$CASE")" "a busy agent is never typed into"
  new_case composer
  printf 'pending\n' >"$CASE/composer"
  assert_equals composer "$(step "$CASE")" "a composer holding text is never typed into"
  [ ! -s "$TMP_ROOT/busy/typed" ] && [ ! -s "$CASE/typed" ] || fail "busy or composer verdicts must type nothing"
  pass "a busy agent or a non-empty composer defers the step without typing"
}

test_save_then_clear_once() {
  local nonce
  new_case happy
  assert_equals saving "$(step "$CASE" 100)" "the first step saves"
  nonce=$(record nonce)
  [[ "$nonce" =~ ^[0-9a-f]{16}$ ]] || fail "the save attempt must carry a random nonce, got '$nonce'"
  assert_equals "/stow daily-fresh-start $nonce" "$(typed)" "the save step types /stow with this attempt's nonce and nothing else"
  prompted "/stow daily-fresh-start $nonce"
  assert_equals saving "$(step "$CASE" 100)" "a save whose turn has not ended does not clear"
  stow_turn "$nonce"
  attest "$nonce" || fail "the stow turn's attestation must be accepted"
  assert_equals saving "$(step "$CASE")" "an attested save still waits for its turn to end"
  turn_ends
  assert_equals cleared "$(step "$CASE")" "once the save turn ends, the same park clears an attested save"
  assert_equals "/stow daily-fresh-start $nonce
/clear
$(bash -c '. "$1/bin/fm-fresh-start-lib.sh"; printf "%s" "$FM_FRESH_START_RESUME_PROMPT"' _ "$ROOT")" "$(typed)" \
    "the clear step types /clear then exactly the resume prompt"
  assert_equals 'done' "$(step "$CASE" 99999999999)" "a cleared day is done"
  assert_equals 'done' "$(FAKE_HOUR=05 step "$CASE" 99999999999)" "the rest of the window stays done"
  assert_equals saving "$(FAKE_DAY=2030-01-03 step "$CASE" 99999999999)" "the next day starts again with a save"
  pass "one day saves, clears only after the save attests and its turn ends, then resumes with one prompt, exactly once"
}

test_only_an_attested_save_clears() {
  local nonce
  # A submitted /stow that never attests (it failed, was interrupted, or its
  # receipt was not reset-safe) never licenses a clear.
  new_case unattested
  assert_equals saving "$(step "$CASE" 100)" "the save is submitted"
  stow_turn "$(record nonce)"
  assert_equals saving "$(step "$CASE" 99999999999)" "a save turn that has not ended is still saving"
  turn_ends
  assert_equals unsaved "$(step "$CASE" 99999999999)" "an ended save turn without an attestation does not clear"
  assert_equals unsaved "$(FAKE_HOUR=06 step "$CASE" 99999999999)" "it keeps waiting while the window is open"
  assert_equals skipped "$(FAKE_HOUR=07 step "$CASE" 99999999999)" "the closing window skips the day"
  assert_equals 1 "$(grep -c . "$CASE/typed")" "nothing but the save was typed"
  # An attestation must name this attempt, today, while a save waits.
  new_case wrong-nonce
  step "$CASE" 100 >/dev/null
  if attest 0123456789abcdef; then fail "a nonce other than the waiting save's must be refused"; fi
  [ ! -e "$CASE/state/.daily-fresh-start-attest" ] || fail "a refused attestation must record nothing"
  new_case nothing-waiting
  if attest 0123456789abcdef; then fail "an attestation with no save waiting must be refused"; fi
  # A save submitted to another session does not cover this one.
  new_case other-session
  step "$CASE" 100 >/dev/null
  nonce=$(record nonce)
  stow_turn "$nonce"
  attest "$nonce"
  turn_ends
  cp "$CASE/transcript.jsonl" "$CASE/new-session.jsonl"
  assert_equals skipped "$(TRANSCRIPT="$CASE/new-session.jsonl" step "$CASE" 99999999999)" "a changed primary session skips the day"
  [ ! -e "$CASE/state/.daily-fresh-start-attest" ] || fail "a skipped save's attestation must be removed"
  # Anything said after the save is not covered by its receipt.
  new_case later-prompt
  step "$CASE" 100 >/dev/null
  nonce=$(record nonce)
  stow_turn "$nonce"
  attest "$nonce"
  turn_ends
  jq -cn '{type: "user", message: {role: "user", content: "one more thing before you go"}}' >>"$CASE/transcript.jsonl"
  assert_equals skipped "$(step "$CASE" 99999999999)" "a human prompt after the save skips the day"
  # A transcript the check cannot parse never verifies.
  new_case torn-transcript
  step "$CASE" 100 >/dev/null
  nonce=$(record nonce)
  stow_turn "$nonce"
  attest "$nonce"
  turn_ends
  printf '{"type":"user","message":{"content":"tor\n' >>"$CASE/transcript.jsonl"
  assert_equals skipped "$(step "$CASE" 99999999999)" "an unparsable transcript skips the day"
  # Yesterday's save, even attested, never licenses today's clear.
  new_case stale-save
  printf 'date=2030-01-01\nstep=saving\nat=1\nnonce=0123456789abcdef\ntranscript=%s\n' "$CASE/transcript.jsonl" >"$CASE/state/.daily-fresh-start"
  printf 'nonce=0123456789abcdef\nat=2\n' >"$CASE/state/.daily-fresh-start-attest"
  assert_equals saving "$(step "$CASE" 99999999999)" "yesterday's save must not license today's clear"
  case "$(typed)" in "/stow daily-fresh-start "*) ;; *) fail "today starts with its own save: $(typed)" ;; esac
  [ "$(record nonce)" != 0123456789abcdef ] || fail "today's save must carry a new nonce"
  for c in unattested wrong-nonce other-session later-prompt torn-transcript stale-save; do
    if grep -qx /clear "$TMP_ROOT/$c/typed"; then fail "$c typed /clear"; fi
  done
  pass "only a save that attested for this attempt, in this session, with nothing said after it, ever clears"
}

# Deep review finding 1: a new captain message after the save always cancels
# that day's clear, through the primary's own prompt-submit boundary.
test_new_message_cancels_the_clear() {
  local nonce
  new_case cancel
  step "$CASE" >/dev/null
  nonce=$(record nonce)
  prompted "/stow daily-fresh-start $nonce"
  stow_turn "$nonce"
  attest "$nonce"
  turn_ends
  prompted /clear
  assert_equals saving "$(record step)" "the save's own /stow and the clear itself cancel nothing"
  prompted 'one more thing before you go'
  assert_equals cancelled "$(record step)" "a new message after the save cancels the day"
  [ ! -e "$CASE/state/.daily-fresh-start-attest" ] && [ ! -e "$CASE/state/.daily-fresh-start-ended" ] \
    || fail "a cancelled save forgets its attestation and its finished mark"
  assert_equals cancelled "$(step "$CASE")" "the cancelled day never clears"
  assert_equals cancelled "$(FAKE_HOUR=06 step "$CASE")" "not later in the window either"
  if attest "$nonce"; then fail "a cancelled save can no longer attest"; fi
  if grep -qx /clear "$CASE/typed"; then fail "a cancelled day typed /clear"; fi
  assert_equals saving "$(FAKE_DAY=2030-01-03 step "$CASE")" "the next day starts again with a save"
  # Before the save turn ends, too.
  new_case cancel-early
  step "$CASE" >/dev/null
  prompted 'are you still there'
  assert_equals cancelled "$(record step)" "a message while the save is still running cancels the day as well"
  pass "a new message after the save, at any point before the clear, cancels that day's clear; the save's own prompt and the clear do not"
}

# Deep review finding 1: anything that arrives between the step's first checks
# and its keystroke stops the clear, because everything is read again last.
test_input_during_the_probes_stops_the_clear() {
  local kind nonce expect
  for kind in wake question prompt cancel; do
    new_case "barrier-$kind"
    step "$CASE" >/dev/null
    nonce=$(record nonce)
    stow_turn "$nonce"
    attest "$nonce"
    turn_ends
    case "$kind" in
      wake)
        printf '#!/bin/sh\nFM_STATE_OVERRIDE="%s" bash -c ". \"%s/bin/fm-wake-lib.sh\" && fm_wake_append check arrival \"check: arrives during the idle probe\""\n' "$CASE/state" "$ROOT" >"$CASE/on-busy"
        expect='waiting:a queued wake' ;;
      question)
        printf '#!/bin/sh\nFM_STATE_OVERRIDE="%s" "%s/bin/fm-chat-question.sh" open late "asked during the composer probe"\n' "$CASE/state" "$ROOT" >"$CASE/on-composer"
        expect='waiting:an unanswered chat question (late)' ;;
      prompt)
        printf '#!/bin/sh\nprintf "%%s\\n" "{\\"type\\":\\"user\\",\\"message\\":{\\"content\\":\\"NEW_UNSAVED_CONTEXT\\"}}" >>"%s"\n' "$CASE/transcript.jsonl" >"$CASE/on-composer"
        expect=skipped ;;
      cancel)
        # shellcheck disable=SC2016 # $PATH expands in the generated script
        printf '#!/bin/sh\nPATH="%s:$PATH" bash -c ". \"%s/bin/fm-fresh-start-lib.sh\"; fm_fresh_start_hook \"%s\" UserPromptSubmit \"{\\\"prompt\\\":\\\"hello\\\"}\""\n' "$FAKEBIN" "$ROOT" "$CASE/state" >"$CASE/on-busy"
        expect=cancelled ;;
    esac
    chmod +x "$CASE/on-busy" "$CASE/on-composer" 2>/dev/null
    assert_equals "$expect" "$(step "$CASE")" "$kind arriving during the probes stops the clear"
    if grep -qx /clear "$CASE/typed"; then fail "$kind: /clear was typed"; fi
  done
  pass "a wake, a chat question, a prompt, or a cancel that arrives during the idle or composer probe stops the clear before it is typed"
}

# Final review finding 1: a prompt submitted while the last check before /clear
# is still running. A jq shim runs the real prompt hook after that check has
# captured the newest prompt and before it matches it: inside the check, where
# the hook can only wait out the lock, and beside it, as a real hook runs. A
# prompt either cancels the clear or is refused and told to send again; it is
# never let into the conversation that /clear then wipes.
race_shim() {  # <case-dir> <inline|beside>
  mkdir -p "$1/shim"
  cat >"$1/shim/jq" <<SH
#!/bin/bash
if [ "\${1:-}" = -e ] && [ "\${2:-}" = --arg ] && [ "\${3:-}" = n ]; then
  count=\$(cat "$1/jq-count" 2>/dev/null || echo 0)
  count=\$((count + 1))
  echo "\$count" >"$1/jq-count"
  if [ "\$count" = 2 ]; then
    printf '%s\n' '{"type":"user","message":{"content":"KEEP_THIS_NEW_INSTRUCTION"}}' >>"$1/transcript.jsonl"
    run_hook() {
      PATH="$FAKEBIN:$PATH" bash -c '. "\$1/bin/fm-fresh-start-lib.sh"; fm_fresh_start_hook "\$2" UserPromptSubmit "\$3"' \\
        _ "$ROOT" "$1/state" '{"hook_event_name":"UserPromptSubmit","prompt":"KEEP_THIS_NEW_INSTRUCTION","transcript_path":"$1/transcript.jsonl"}' \\
        >"$1/hook.out" 2>&1
      echo \$? >"$1/hook.rc"
    }
    if [ "$2" = inline ]; then run_hook; else run_hook & sleep 0.5; fi
  fi
fi
exec "$(command -v jq)" "\$@"
SH
  chmod +x "$1/shim/jq"
}

test_a_prompt_during_the_final_check_never_loses_to_the_clear() {
  local mode nonce verdict tries
  for mode in inline beside; do
    new_case "final-check-$mode"
    step "$CASE" >/dev/null
    nonce=$(record nonce)
    stow_turn "$nonce"
    attest "$nonce"
    turn_ends
    race_shim "$CASE" "$mode"
    verdict=$(PATH="$CASE/shim:$PATH" step "$CASE")
    tries=0
    until [ -s "$CASE/hook.rc" ] || [ "$tries" -ge 100 ]; do sleep 0.1; tries=$((tries + 1)); done
    [ -s "$CASE/hook.rc" ] || fail "$mode: the prompt hook never finished"
    if grep -qx /clear "$CASE/typed" && [ "$(cat "$CASE/hook.rc")" != 3 ]; then
      fail "$mode: the prompt was let into the conversation and /clear was typed anyway (verdict $verdict, record $(record step), hook rc $(cat "$CASE/hook.rc"), hook output $(cat "$CASE/hook.out"))"
    fi
    case "$mode" in
      inline)
        [ "$verdict" != cleared ] || fail "inline: cleared over a cancelling prompt"
        assert_equals cancelled "$(record step)" "inline: the prompt's cancellation stands"
        assert_equals cancelled "$(step "$CASE")" "inline: and the day stays cancelled"
        if grep -qx /clear "$CASE/typed"; then fail "inline: /clear was typed"; fi ;;
      beside)
        assert_equals cleared "$verdict" "beside: the committed clear goes ahead"
        assert_equals 3 "$(cat "$CASE/hook.rc")" "beside: the prompt that met the committed clear is refused"
        assert_equals block "$(jq -r .decision "$CASE/hook.out")" "beside: with Claude Code's block decision"
        jq -e '.reason | contains("Send it again")' "$CASE/hook.out" >/dev/null || fail "beside: the refusal tells the captain to send it again" ;;
    esac
  done
  pass "a prompt during the final check either cancels the clear or is refused with a reason; it never reaches the conversation /clear wipes"
}

# The clearing step the commit writes (THE CLEAR BOUNDARY) is short-lived and
# belongs to the save's session only.
test_the_clearing_commit_is_bounded() {
  local nonce now out
  now=$(date +%s)
  new_case clearing-other-session
  printf 'date=%s\nstep=clearing\nat=%s\nnonce=abc\ntranscript=%s\n' "$FAKE_DAY" "$now" "$CASE/transcript.jsonl" >"$CASE/state/.daily-fresh-start"
  out=$(hook_event UserPromptSubmit "$(jq -cn --arg t "$CASE/other.jsonl" '{hook_event_name: "UserPromptSubmit", prompt: "hi", transcript_path: $t}')")
  [ -z "$out" ] || fail "a prompt in another session is not refused: $out"
  assert_equals clearing "$(record step)" "and it leaves the commit alone"
  out=$(hook_event UserPromptSubmit '{"hook_event_name":"UserPromptSubmit","prompt":"/clear"}')
  [ -z "$out" ] || fail "the clear itself is never refused"
  assert_equals busy "$(step "$CASE")" "a fresh commit another host left makes the step wait"
  new_case clearing-stale
  printf 'date=%s\nstep=clearing\nat=%s\nnonce=abc\ntranscript=%s\n' "$FAKE_DAY" "$((now - 31))" "$CASE/transcript.jsonl" >"$CASE/state/.daily-fresh-start"
  out=$(prompted 'hello after a stalled clear')
  [ -z "$out" ] || fail "a stale commit refuses nothing: $out"
  assert_equals skipped "$(record step)" "a stale commit skips the day"
  new_case clearing-stale-step
  printf 'date=%s\nstep=clearing\nat=%s\nnonce=abc\ntranscript=%s\n' "$FAKE_DAY" "$((now - 31))" "$CASE/transcript.jsonl" >"$CASE/state/.daily-fresh-start"
  assert_equals skipped "$(step "$CASE")" "the step skips a stale commit too"
  assert_equals skipped "$(record step)" "and records it"
  [ ! -s "$CASE/typed" ] || fail "a stale commit typed something"
  new_case cleared-recent
  printf 'date=%s\nstep=cleared\nat=%s\nnonce=abc\ntranscript=%s\n' "$FAKE_DAY" "$now" "$CASE/transcript.jsonl" >"$CASE/state/.daily-fresh-start"
  out=$(hook_event UserPromptSubmit "$(jq -cn --arg t "$CASE/transcript.jsonl" '{hook_event_name: "UserPromptSubmit", prompt: "late for the old session", transcript_path: $t}')")
  assert_equals block "$(printf '%s' "$out" | jq -r .decision 2>/dev/null)" "a prompt still bound for the cleared session is refused"
  out=$(hook_event UserPromptSubmit "$(jq -cn --arg t "$CASE/new.jsonl" '{hook_event_name: "UserPromptSubmit", prompt: "hello fresh session", transcript_path: $t}')")
  [ -z "$out" ] || fail "a prompt in the fresh session is never refused: $out"
  out=$(hook_event UserPromptSubmit "$(bash -c '. "$1/bin/fm-fresh-start-lib.sh"; jq -cn --arg p "$FM_FRESH_START_RESUME_PROMPT" --arg t "$2" "{hook_event_name: \"UserPromptSubmit\", prompt: \$p, transcript_path: \$t}"' _ "$ROOT" "$CASE/transcript.jsonl")")
  [ -z "$out" ] || fail "the resume prompt is never refused: $out"
  printf 'date=%s\nstep=cleared\nat=%s\nnonce=abc\ntranscript=%s\n' "$FAKE_DAY" "$((now - 31))" "$CASE/transcript.jsonl" >"$CASE/state/.daily-fresh-start"
  out=$(hook_event UserPromptSubmit "$(jq -cn --arg t "$CASE/transcript.jsonl" '{hook_event_name: "UserPromptSubmit", prompt: "much later", transcript_path: $t}')")
  [ -z "$out" ] || fail "an old cleared record refuses nothing: $out"
  assert_equals cleared "$(record step)" "and the hook never rewrites a cleared day"
  new_case clearing-send-fails
  step "$CASE" >/dev/null
  nonce=$(record nonce)
  stow_turn "$nonce"
  attest "$nonce"
  turn_ends
  echo /clear >"$CASE/send-fails"
  assert_equals failed "$(step "$CASE")" "a /clear that did not go through fails"
  assert_equals saving "$(record step)" "and hands the day back to the save, so nothing stays refused"
  rm -f "$CASE/send-fails"
  assert_equals cleared "$(step "$CASE")" "the next tick clears"
  pass "the clearing commit refuses only the save session's prompts, for at most 30 seconds, and a failed /clear hands the day back"
}

# Deep review finding 2: in the real host the save is typed during a park and
# the same park keeps ticking; no later park ever begins. The save turn's own
# Stop is what lets that park clear, and only for the save's own session with
# the /stow still its newest prompt.
test_the_same_park_clears_once_the_save_turn_ends() {
  local nonce
  new_case same-park
  step "$CASE" >/dev/null
  nonce=$(record nonce)
  stow_turn "$nonce"
  attest "$nonce"
  assert_equals saving "$(step "$CASE")" "the attested save waits for its turn to end"
  assert_equals saving "$(step "$CASE")" "however many ticks pass"
  TRANSCRIPT="$CASE/other.jsonl" turn_ends
  [ ! -e "$CASE/state/.daily-fresh-start-ended" ] || fail "another session's turn end does not finish the save"
  turn_ends
  assert_equals "$nonce" "$(sed -n 's/^nonce=//p' "$CASE/state/.daily-fresh-start-ended")" "the save turn's end names its nonce"
  assert_equals cleared "$(step "$CASE")" "the same park now clears"
  new_case ended-after-prompt
  step "$CASE" >/dev/null
  nonce=$(record nonce)
  stow_turn "$nonce"
  jq -cn '{type: "user", message: {role: "user", content: "a later prompt"}}' >>"$CASE/transcript.jsonl"
  turn_ends
  [ ! -e "$CASE/state/.daily-fresh-start-ended" ] || fail "a turn whose newest prompt is not the /stow does not finish the save"
  pass "the save turn's own Stop, in its own session with the /stow newest, lets the same park clear; nothing else does"
}

# A turn that ends after the save's own, in the same session and with no
# submitted prompt (a supervision hand-back wakes the primary this way), may
# have answered the captain; its Stop skips the day, so the clear never wipes
# that answer.
test_a_later_turn_end_after_the_save_skips_the_day() {
  local nonce
  new_case later-turn
  step "$CASE" >/dev/null
  nonce=$(record nonce)
  prompted "/stow daily-fresh-start $nonce"
  stow_turn "$nonce"
  attest "$nonce"
  turn_ends
  assert_equals "$nonce" "$(sed -n 's/^nonce=//p' "$CASE/state/.daily-fresh-start-ended")" "the save turn's own end marks it finished"
  jq -cn '{type: "user", isMeta: true, message: {role: "user", content: [{type: "text", text: "supervision-host: branch-outcome: run bin/fm-wake-drain.sh"}]}}' >>"$CASE/transcript.jsonl"
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Captain, the docs fix is done."}],"usage":{"input_tokens":1,"cache_read_input_tokens":300000,"cache_creation_input_tokens":0}}}\n' >>"$CASE/transcript.jsonl"
  turn_ends
  assert_equals skipped "$(record step)" "a second turn end after the save skips the day"
  [ ! -e "$CASE/state/.daily-fresh-start-attest" ] && [ ! -e "$CASE/state/.daily-fresh-start-ended" ] \
    || fail "a skipped save forgets its attestation and its finished mark"
  assert_equals 'done' "$(step "$CASE")" "the skipped day never clears"
  assert_equals 'done' "$(FAKE_HOUR=06 step "$CASE")" "not later in the window either"
  if grep -qx /clear "$CASE/typed"; then fail "a later turn after the save was wiped by /clear"; fi
  assert_equals saving "$(FAKE_DAY=2030-01-03 step "$CASE")" "the next day starts again with a save"
  pass "only the first turn end after the save marks it finished; a later one skips the day, so its reply is never cleared"
}

# A window that runs past midnight is one day: a save typed before midnight
# attests and clears after it, and is not typed a second time.
test_a_window_past_midnight_is_one_day() {
  local nonce d
  new_case midnight
  printf 'hour=22\nwindow-hours=4\n' >"$CASE/config/daily-fresh-start"
  assert_equals saving "$(FAKE_DAY=2030-01-02 FAKE_HOUR=23 step "$CASE")" "the save is typed before midnight"
  nonce=$(record nonce)
  assert_equals 2030-01-02 "$(record date)" "the day is the date the window opened"
  stow_turn "$nonce"
  export FAKE_DAY=2030-01-03 FAKE_HOUR=00
  attest "$nonce" || fail "a save that finishes after midnight still attests"
  assert_equals saving "$(step "$CASE")" "after midnight the same save is still waiting, not typed again"
  turn_ends
  assert_equals cleared "$(step "$CASE")" "and clears once its turn ends"
  assert_equals 'done' "$(FAKE_HOUR=01 step "$CASE")" "the rest of the window is done"
  assert_equals 1 "$(grep -c '^/stow ' "$CASE/typed")" "the save was typed once"
  assert_equals saving "$(FAKE_HOUR=22 step "$CASE")" "the next evening's window is a new day"
  export FAKE_DAY=2030-01-02 FAKE_HOUR=04
  for d in 2030-03-01:2030-02-28 2032-03-01:2032-02-29 2031-01-01:2030-12-31 2030-05-01:2030-04-30 2030-08-01:2030-07-31; do
    assert_equals "${d#*:}" "$(PATH="$FAKEBIN:$PATH" FAKE_DAY="${d%%:*}" bash -c '. "$1/bin/fm-fresh-start-lib.sh"; FM_FRESH_START_HOUR=22; fm_fresh_start_day 01' _ "$ROOT")" \
      "before the opening hour, ${d%%:*} belongs to the day before"
  done
  pass "a window that runs past midnight is one day: one save, attested and cleared after midnight"
}

# The host keeps running across turns, so a fresh start leaves it holding the
# replaced session's transcript; every Stop records the current one, which the
# host reads instead, so the next day's save and clear follow the new session.
test_the_current_session_follows_each_stop() {
  new_case follows
  assert_equals /from/host/start "$(bash -c '. "$1/bin/fm-fresh-start-lib.sh"; fm_fresh_start_transcript "$2" /from/host/start' _ "$ROOT" "$CASE/state")" \
    "with no Stop seen yet the host's own path is used"
  TRANSCRIPT="$CASE/first.jsonl" turn_ends
  TRANSCRIPT="$CASE/after-clear.jsonl" turn_ends
  assert_equals "$CASE/after-clear.jsonl" "$(bash -c '. "$1/bin/fm-fresh-start-lib.sh"; fm_fresh_start_transcript "$2" /from/host/start' _ "$ROOT" "$CASE/state")" \
    "the latest Stop names the current session"
  hook_event Stop '{"hook_event_name":"Stop","transcript_path":"relative.jsonl"}'
  assert_equals "$CASE/after-clear.jsonl" "$(sed -n 's/^transcript=//p' "$CASE/state/.daily-fresh-start-session")" "a path that is not absolute is ignored"
  pass "every primary Stop records the current session transcript, which the host uses instead of the one it started with"
}

# Deep review finding 3: a conversation whose size cannot be read is never a
# successful day, so the two-day note still reaches the captain.
test_unknown_size_is_not_a_run() {
  local e=2000000000
  new_case unknown
  printf 'unparseable\n' >"$CASE/transcript.jsonl"
  assert_equals unknown "$(FAKE_EPOCH=$e step "$CASE")" "an unparseable transcript has no known size"
  assert_equals "$e" "$(sed -n 's/^last=//p' "$CASE/state/.daily-fresh-start-history")" "the count starts"
  assert_equals unknown "$(FAKE_EPOCH=$((e + 5 * 86400)) step "$CASE")" "five days later it is still unknown"
  assert_equals "$e" "$(sed -n 's/^last=//p' "$CASE/state/.daily-fresh-start-history")" "an unknown size never moves the count"
  assert_equals 1 "$(grep -c . "$CASE/state/.wake-queue" 2>/dev/null)" "the two-day note is sent"
  grep -q 'because the conversation size could not be read' "$CASE/state/.wake-queue" || fail "the note names the unreadable size: $(cat "$CASE/state/.wake-queue")"
  new_case missing
  rm -f "$CASE/transcript.jsonl"
  assert_equals unknown "$(step "$CASE")" "a missing transcript has no known size"
  pass "a missing or unparseable transcript is reported as unknown, never counted as a run, and the two-day note names it"
}

test_scale_gate_cost() {
  local n dir i start ms verdict
  for n in 5 100 1000; do
    new_case "scale-$n"
    dir="$CASE/state"
    for i in $(seq 1 "$n"); do
      printf 'working [at=1]: on it\nneeds-decision [at=2] [key=k%s]: pick\nresolved [at=3] [key=k%s]: picked\ndone [at=4]: ready\n' "$i" "$i" >"$dir/t$i.status"
    done
    start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
    verdict=$(step "$CASE" 100)
    ms=$(( $(perl -MTime::HiRes=time -e 'printf "%d", time*1000') - start ))
    assert_equals saving "$verdict" "$n task logs must not hold the step"
    printf '# scale: %s task logs -> fresh-start step in %s ms\n' "$n" "$ms"
    # The same home with an open question for every task: the first holds it.
    mkdir -p "$dir/chat-questions"
    for i in $(seq 1 "$n"); do printf 'asked=1\nsummary=q\n' >"$dir/chat-questions/q$(printf '%04d' "$i").question"; done
    rm -f "$dir/.daily-fresh-start"
    : >"$CASE/typed"
    start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
    verdict=$(step "$CASE" 100)
    ms=$(( $(perl -MTime::HiRes=time -e 'printf "%d", time*1000') - start ))
    assert_equals "waiting:an unanswered chat question (q0001)" "$verdict" "$n open questions hold the step and name the first"
    printf '# scale: %s open chat questions -> held in %s ms\n' "$n" "$ms"
    [ ! -s "$CASE/typed" ] || fail "scale $n: a held step typed"
  done
  pass "the gate's verdict is the same at 5, 100 and 1000 tasks or questions (timings above)"
}

test_off_window_small
test_gate_holds_every_step
test_durable_records_do_not_hold
test_chat_question_record
test_stall_note_once
test_new_message_cancels_the_clear
test_input_during_the_probes_stops_the_clear
test_a_prompt_during_the_final_check_never_loses_to_the_clear
test_the_clearing_commit_is_bounded
test_the_same_park_clears_once_the_save_turn_ends
test_a_later_turn_end_after_the_save_skips_the_day
test_a_window_past_midnight_is_one_day
test_unknown_size_is_not_a_run
test_the_current_session_follows_each_stop
test_settled_records_do_not_hold
test_busy_and_composer
test_save_then_clear_once
test_only_an_attested_save_clears
test_scale_gate_cost
