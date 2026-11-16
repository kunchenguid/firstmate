#!/usr/bin/env bash
# tests/fm-fresh-start.test.sh - the daily fresh start of a Claude primary
# (bin/fm-fresh-start-lib.sh): it saves first, clears only after a same-day
# save, runs only inside the quiet window, and never runs while anything the
# conversation is in the middle of could be dropped.
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
  *) exec /bin/date "$@" ;;
esac
SH
chmod +x "$FAKEBIN/date"

# step <case-dir> [park-start]: run one step in a fresh shell; prints the
# verdict, and the typed lines land in <case-dir>/typed. TRANSCRIPT names the
# primary's current session transcript (default the case's own).
step() {
  local dir=$1 park=${2:-0}
  PATH="$FAKEBIN:$PATH" FM_FRESH_START_SETTLE=0 CASE_DIR="$dir" FM_HOME="$dir" \
    TRANSCRIPT="${TRANSCRIPT:-$dir/transcript.jsonl}" bash -c '
    . "$1/bin/fm-warm-compact-lib.sh"
    . "$1/bin/fm-fresh-start-lib.sh"
    fm_backend_busy_state() { cat "$CASE_DIR/busy" 2>/dev/null || printf "idle\n"; }
    fm_backend_composer_state() { cat "$CASE_DIR/composer" 2>/dev/null || printf "empty\n"; }
    fm_backend_send_text_submit() { printf "%s\n" "$3" >> "$CASE_DIR/typed"; printf "empty\n"; }
    fm_fresh_start_step "$CASE_DIR/config" "$CASE_DIR/state" herdr pane-1 "$TRANSCRIPT" "$2"
  ' _ "$ROOT" "$park"
}

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
      unprocessed) outcomes append --task t1 --verdict captain --summary 'pick A or B'; outcomes mark-read --through 1 ;;
      note) mkdir -p "$CASE/state/inbox" && : >"$CASE/state/inbox/1.note" ;;
      decision) printf 'needs-decision [at=1] [key=pick]: A or B\n' >"$CASE/state/t1.status" ;;
      blocked) printf 'blocked [at=1]: need a login\n' >"$CASE/state/t2.status" ;;
      held) hold t-pick 'choose A or B' ;;
      transferred)
        # The standard completion flow: the status question moves to a
        # captain hold and its status side is closed; the question is still open.
        printf 'needs-decision [at=1] [key=pick]: A or B\ncaptain-held [at=2] [key=pick]: moved to t-pick\n' >"$CASE/state/t1.status"
        hold t-pick 'choose A or B' ;;
      corrupt) printf 'not-json\n' >"$CASE/state/branch-outcomes.jsonl" ;;
      tail) outcomes append --task t1 --verdict routine --summary 'note'; printf 'not-json\n' >>"$CASE/state/branch-outcomes.jsonl" ;;
      linked) printf 'working [at=1]: x\n' >"$CASE/elsewhere.status"; ln -s "$CASE/elsewhere.status" "$CASE/state/t3.status" ;;
      dirlog) mkdir "$CASE/state/t4.status" ;;
      queue-dir) mkdir "$CASE/state/.wake-queue" ;;
      replies-file) printf 'x\n' >"$CASE/state/pending-replies" ;;
      inbox-file) printf 'x\n' >"$CASE/state/inbox" ;;
      no-backlog) rm -rf "$CASE/data"; printf 'x\n' >"$CASE/data" ;;
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
unprocessed|an unprocessed captain outcome
note|a captain inbox note
decision|an open decision (t1)
blocked|an open decision (t2)
held|a captain-held decision (1 held)
transferred|a captain-held decision (1 held)
corrupt|an unreadable outcome store
tail|an unreadable outcome store
linked|an unreadable status log (t3)
dirlog|an unreadable status log (t4)
queue-dir|an unreadable wake queue
replies-file|an unreadable pending-reply record
inbox-file|an unreadable captain inbox
no-backlog|an unreadable captain-held list
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
  printf 'needs-decision [at=1] [key=pick]: A or B\n' >"$CASE/state/t1.status"
  assert_equals 'waiting:an open decision (t1)' "$(step "$CASE" 99999999999)" "an open decision must hold the clear step too"
  [ "$(grep -c . "$CASE/typed")" = 1 ] || fail "a held clear step types nothing after the save: $(typed)"
  # A damaged input that appears between an attested save and the clear holds
  # the clear: an interrupted append or a broken link is not proof of quiet.
  local damage
  for damage in queue-torn store-dangling replies-dangling; do
    new_case "clear-$damage"
    assert_equals saving "$(step "$CASE" 100)" "$damage: the save step runs on a quiet home"
    stow_turn "$(record nonce)"
    attest "$(record nonce)" || fail "$damage: the save attempt's own nonce must attest"
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
  assert_equals saving "$(step "$CASE" 100)" "the park that submitted the save must not clear"
  stow_turn "$nonce"
  attest "$nonce" || fail "the stow turn's attestation must be accepted"
  assert_equals cleared "$(step "$CASE" 99999999999)" "a later park after an attested save clears"
  assert_equals "/stow daily-fresh-start $nonce
/clear
$(bash -c '. "$1/bin/fm-fresh-start-lib.sh"; printf "%s" "$FM_FRESH_START_RESUME_PROMPT"' _ "$ROOT")" "$(typed)" \
    "the clear step types /clear then exactly the resume prompt"
  assert_equals 'done' "$(step "$CASE" 99999999999)" "a cleared day is done"
  assert_equals 'done' "$(FAKE_HOUR=05 step "$CASE" 99999999999)" "the rest of the window stays done"
  assert_equals saving "$(FAKE_DAY=2030-01-03 step "$CASE" 99999999999)" "the next day starts again with a save"
  pass "one day saves, clears only after the save attests on a later park, then resumes with one prompt, exactly once"
}

test_only_an_attested_save_clears() {
  local nonce
  # A submitted /stow that never attests (it failed, was interrupted, or its
  # receipt was not reset-safe) never licenses a clear.
  new_case unattested
  assert_equals saving "$(step "$CASE" 100)" "the save is submitted"
  stow_turn "$(record nonce)"
  assert_equals unsaved "$(step "$CASE" 99999999999)" "a later idle park without an attestation does not clear"
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
  cp "$CASE/transcript.jsonl" "$CASE/new-session.jsonl"
  assert_equals skipped "$(TRANSCRIPT="$CASE/new-session.jsonl" step "$CASE" 99999999999)" "a changed primary session skips the day"
  [ ! -e "$CASE/state/.daily-fresh-start-attest" ] || fail "a skipped save's attestation must be removed"
  # Anything said after the save is not covered by its receipt.
  new_case later-prompt
  step "$CASE" 100 >/dev/null
  nonce=$(record nonce)
  stow_turn "$nonce"
  attest "$nonce"
  jq -cn '{type: "user", message: {role: "user", content: "one more thing before you go"}}' >>"$CASE/transcript.jsonl"
  assert_equals skipped "$(step "$CASE" 99999999999)" "a human prompt after the save skips the day"
  # A transcript the check cannot parse never verifies.
  new_case torn-transcript
  step "$CASE" 100 >/dev/null
  nonce=$(record nonce)
  stow_turn "$nonce"
  attest "$nonce"
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
    assert_equals saving "$verdict" "$n settled tasks must not hold the step"
    printf '# scale: %s settled task logs -> fresh-start step in %s ms\n' "$n" "$ms"
    printf 'needs-decision [at=5] [key=late]: one more\n' >>"$dir/t$n.status"
    rm -f "$dir/.daily-fresh-start"
    : >"$CASE/typed"
    assert_equals "waiting:an open decision (t$n)" "$(step "$CASE" 100)" "one open decision among $n must still hold the step"
    [ ! -s "$CASE/typed" ] || fail "scale $n: a held step typed"
  done
  pass "the gate's verdict is the same at 5, 100 and 1000 tasks (timings above)"
}

test_off_window_small
test_gate_holds_every_step
test_settled_records_do_not_hold
test_busy_and_composer
test_save_then_clear_once
test_only_an_attested_save_clears
test_scale_gate_cost
