#!/usr/bin/env bash
# tests/fm-fresh-start.test.sh - the daily fresh start of a Claude primary
# (bin/fm-fresh-start-lib.sh): it saves first, clears only after a same-day
# save, runs only inside the quiet window, and never runs while anything the
# conversation is in the middle of could be dropped.
#
# Drives fm_fresh_start_step through its public interface with the backend
# primitives replaced by recorders, and the clock by a fake `date` on PATH, so
# what is asserted is exactly what would be typed into the primary. The live
# proof against a real Claude primary is recorded in the PR evidence.
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
# verdict, and the typed lines land in <case-dir>/typed.
step() {
  local dir=$1 park=${2:-0}
  PATH="$FAKEBIN:$PATH" FM_FRESH_START_SETTLE=0 CASE_DIR="$dir" bash -c '
    . "$1/bin/fm-warm-compact-lib.sh"
    . "$1/bin/fm-fresh-start-lib.sh"
    fm_backend_busy_state() { cat "$CASE_DIR/busy" 2>/dev/null || printf "idle\n"; }
    fm_backend_composer_state() { cat "$CASE_DIR/composer" 2>/dev/null || printf "empty\n"; }
    fm_backend_send_text_submit() { printf "%s\n" "$3" >> "$CASE_DIR/typed"; printf "empty\n"; }
    fm_fresh_start_step "$CASE_DIR/config" "$CASE_DIR/state" herdr pane-1 "$CASE_DIR/transcript.jsonl" "$2"
  ' _ "$ROOT" "$park"
}

new_case() {  # <name> [context-tokens] -> sets CASE
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE/config" "$CASE/state"
  : >"$CASE/config/daily-fresh-start"
  printf '{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0}}}\n' \
    "${2:-300000}" >"$CASE/transcript.jsonl"
  : >"$CASE/typed"
}

typed() { cat "$CASE/typed"; }
record() { sed -n "s/^$1=//p" "$CASE/state/.daily-fresh-start" 2>/dev/null; }

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
      outcome) printf '{"seq":4,"verdict":"captain","task":"t1"}\n' >"$CASE/state/branch-outcomes.jsonl"; printf '3\n' >"$CASE/state/.branch-outcomes-processed" ;;
      note) mkdir -p "$CASE/state/inbox" && : >"$CASE/state/inbox/1.note" ;;
      decision) printf 'needs-decision [at=1] [key=pick]: A or B\n' >"$CASE/state/t1.status" ;;
      blocked) printf 'blocked [at=1]: need a login\n' >"$CASE/state/t2.status" ;;
    esac
    assert_equals "waiting:$reason" "$(step "$CASE")" "$name must hold the save step"
    [ ! -s "$CASE/typed" ] || fail "$name: a held step typed: $(typed)"
    [ ! -e "$CASE/state/.daily-fresh-start" ] || fail "$name: a held step recorded progress"
  done <<'ROWS'
afk|away or quiet mode
queue|a queued wake
handoff|a supervision handoff
reply|a secondmate reply
outcome|an unprocessed captain outcome
note|a captain inbox note
decision|an open decision (t1)
blocked|an open decision (t2)
ROWS
  # The same gate holds the clear step after a save.
  new_case gate-clear
  assert_equals saving "$(step "$CASE" 100)" "the save step runs on a quiet home"
  printf 'needs-decision [at=1] [key=pick]: A or B\n' >"$CASE/state/t1.status"
  assert_equals 'waiting:an open decision (t1)' "$(step "$CASE" 99999999999)" "an open decision must hold the clear step too"
  assert_equals /stow "$(typed)" "a held clear step types nothing after the save"
  pass "every gate reason holds both steps and types or records nothing"
}

test_settled_records_do_not_hold() {
  new_case settled
  printf 'needs-decision [at=1] [key=pick]: A or B\nresolved [at=2] [key=pick]: B\n' >"$CASE/state/t1.status"
  printf '{"seq":4,"verdict":"captain","task":"t1"}\n{"seq":5,"verdict":"routine","task":"t2"}\n' >"$CASE/state/branch-outcomes.jsonl"
  printf '4\n' >"$CASE/state/.branch-outcomes-processed"
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
  new_case happy
  assert_equals saving "$(step "$CASE" 100)" "the first step saves"
  assert_equals /stow "$(typed)" "the save step types /stow and nothing else"
  assert_equals saving "$(record step)" "the save is recorded"
  assert_equals saving "$(step "$CASE" 100)" "the park that submitted the save must not clear"
  assert_equals /stow "$(typed)" "a second tick in the same park types nothing"
  assert_equals cleared "$(step "$CASE" 99999999999)" "a later park after the save clears"
  assert_equals "/stow
/clear
$(bash -c '. "$1/bin/fm-fresh-start-lib.sh"; printf "%s" "$FM_FRESH_START_RESUME_PROMPT"' _ "$ROOT")" "$(typed)" \
    "the clear step types /clear then exactly the resume prompt"
  assert_equals done "$(step "$CASE" 99999999999)" "a cleared day is done"
  assert_equals done "$(FAKE_HOUR=05 step "$CASE" 99999999999)" "the rest of the window stays done"
  assert_equals saving "$(FAKE_DAY=2030-01-03 step "$CASE" 99999999999)" "the next day starts again with a save"
  pass "one day saves, then clears on a later park, then resumes with one prompt, exactly once"
}

test_never_clears_an_unsaved_conversation() {
  new_case stale-save
  printf 'date=2030-01-01\nstep=saving\nat=1\n' >"$CASE/state/.daily-fresh-start"
  assert_equals saving "$(step "$CASE" 99999999999)" "yesterday's save must not license today's clear"
  assert_equals /stow "$(typed)" "today starts with its own save"
  new_case window-closed
  assert_equals saving "$(step "$CASE" 100)" "the save runs"
  assert_equals skipped "$(FAKE_HOUR=07 step "$CASE" 99999999999)" "a window that closes before the clear records skipped"
  assert_equals done "$(FAKE_HOUR=04 step "$CASE" 99999999999)" "a skipped day never clears later"
  assert_equals /stow "$(typed)" "nothing after the save was typed"
  pass "a clear never runs without a save of the same day, even when the window closes between them"
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
test_never_clears_an_unsaved_conversation
test_scale_gate_cost
