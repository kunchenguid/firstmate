#!/usr/bin/env bash
# tests/fm-afk-wedge.test.sh - regression suite for the away-mode injection wedge
# (incident: a stalled crewmate went un-recovered for ~8h because the daemon's
# max-defer escape only RE-TRIED the same guarded flush). The wedge: a prior
# injection's Enter is swallowed, leaving the daemon's OWN marker-prefixed digest
# in the supervisor composer; the composer classifier then reads that as
# 'pending' input on every tick and the composer guard defers delivery forever,
# while the wedge alarm is invisible precisely because nobody is watching
# firstmate in afk.
#
# The fix: past FM_MAX_DEFER_SECS, on a pane that is NOT genuinely busy, the
# daemon FORCE-delivers — it clears the stale self-injected text (via the
# backend-dispatched fm_backend_clear_composer -> fm_tmux_clear_composer) and
# submits the digest, so a buffered escalation always reaches firstmate. These
# tests pin:
#   1. the wedge is broken: stale self-injected composer text past max-defer is
#      cleared and the digest delivered (buffer cleared, no lingering alarm);
#   2. a genuinely BUSY pane (agent mid-turn) still defers even under force;
#   3. afk OFF preserves the human-safety guard: a half-typed line is never
#      clobbered because the force path never runs;
#   4. the decline path: past max-defer, a composer whose readable text will NOT
#      clear is never typed over — delivery defers, the buffer survives, and the
#      wedge alarm is raised, so a marked digest is never concatenated onto residue;
#   5. fm_tmux_clear_composer empties a poisoned composer (the primitive).
#
# Hermetic: every case runs in its own temp dir with a fake tmux; nothing touches
# the live state/ of any running firstmate.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
# Source the daemon's pure functions (and, transitively, fm-tmux-lib.sh and
# fm-backend.sh). Its main loop is skipped under sourcing via the BASH_SOURCE
# guard.
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$DAEMON"
fi

TMP_ROOT=$(fm_test_tmproot fm-afk-wedge-tests)

# The exact text a swallowed-Enter injection leaves behind: the daemon prepends
# FM_INJECT_MARK (0x1f) to every digest, so the poisoned composer line carries
# that marker. Modeling it faithfully proves the clear path handles the daemon's
# own marker-prefixed stale text, not just arbitrary text.
stale_inject_line() {  # echoes a bordered composer line holding a stale digest
  printf '│ > %sSupervisor escalate (1 event(s)): needs-decision: pick A │' "$FM_INJECT_MARK"
}

test_afk_wedge_force_delivers_stale_self_injection() {
  # THE regression. A previous inject's Enter was swallowed, so the daemon's own
  # marker-prefixed digest sits unsubmitted in the composer (pending input). Past
  # max-defer, on a not-busy pane, the daemon must CLEAR that stale text and
  # FORCE-deliver — never defer forever.
  local dir state fakebin sent
  dir=$(make_bordered_case wedge-force-deliver)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  stale_inject_line > "$dir/composer"   # poisoned composer (pending input)
  # Sanity: the fixture really does read as pending before the force path runs.
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" \
    pane_input_pending "win" \
    || fail "fixture composer did not read as pending (test would not exercise the wedge)"
  escalate_add "$state" "needs-decision: pick A"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 FM_INJECT_CONFIRM_SLEEP=0.05 \
    housekeeping "$state"
  grep -F 'Supervisor escalate' "$sent" >/dev/null \
    || fail "wedged escalation was not delivered past max-defer (still deferring forever)"
  [ "$(grep -c 'Supervisor escalate' "$sent")" -eq 1 ] \
    || fail "digest typed more than once (no clear-before-type / retype)"
  grep -F '[ENTER]' "$sent" >/dev/null || fail "force-deliver did not submit the digest"
  [ ! -s "$state/.subsuper-escalations" ] || fail "buffer not cleared after force-delivery"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge alarm left behind after a successful force-delivery"
  pass "afk wedge: stale self-injected composer text is cleared and force-delivered past max-defer"
}

test_afk_wedge_busy_pane_still_defers() {
  # The distinction the fix must preserve: a genuinely BUSY pane (firstmate
  # mid-turn) is NOT clobbered even on the force path. It defers and raises the
  # visible wedge alarm; the buffer survives.
  local dir state fakebin sent
  dir=$(make_bordered_case wedge-busy-defers)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf 'esc to interrupt\n' > "$dir/composer"   # agent mid-turn busy footer
  escalate_add "$state" "needs-decision: pick A"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 FM_INJECT_CONFIRM_SLEEP=0.05 \
    housekeeping "$state"
  [ ! -s "$sent" ] || fail "force path typed into a genuinely busy pane (clobbered an active turn)"
  [ -s "$state/.subsuper-inject-wedged" ] || fail "busy pane past max-defer did not raise a wedge alarm"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer lost while pane was busy"
  grep -F 'esc to interrupt' "$dir/composer" >/dev/null || fail "busy pane composer content changed"
  pass "afk wedge: a genuinely busy pane still defers under force (no clobber, visible alarm)"
}

test_afk_off_does_not_clobber_human_line() {
  # The human-safety guard. With afk OFF the max-defer escape never runs (it is
  # afk-gated), so a captain's half-typed line is never cleared or typed over,
  # even with a long-buffered escalation present. Force applies ONLY in afk.
  local dir state fakebin sent
  dir=$(make_bordered_case wedge-afk-off-safe)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf '│ > human half-typed │\n' > "$dir/composer"
  escalate_add "$state" "needs-decision: pick A"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  # afk deliberately NOT entered.
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 FM_INJECT_CONFIRM_SLEEP=0.05 \
    housekeeping "$state"
  [ ! -s "$sent" ] || fail "force path ran while afk was off (would clobber a human line)"
  grep -F 'human half-typed' "$dir/composer" >/dev/null \
    || fail "human's half-typed line was clobbered while afk off"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge alarm fired while afk off"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer dropped while afk off"
  pass "afk off: a human's half-typed line is never clobbered (force path is afk-only)"
}

test_afk_wedge_unclearable_composer_declines() {
  # The decline path. Past max-defer on a not-busy afk pane, if the composer holds
  # readable text the clear keys CANNOT wipe, the daemon must NOT type over it — a
  # marked digest concatenated onto non-marker residue could corrupt the message
  # and make firstmate read an unmarked line and exit afk early. It defers, keeps
  # the buffer, and block 1b raises the visible wedge alarm instead.
  local dir state fakebin sent
  dir=$(make_bordered_case wedge-unclearable-declines)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf '│ > leftover junk that will not clear │\n' > "$dir/composer"
  # Sanity: the fixture reads as pending, so the force path is actually exercised.
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" \
    pane_input_pending "win" \
    || fail "fixture composer did not read as pending (test would not exercise the decline)"
  escalate_add "$state" "needs-decision: pick A"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_NO_CLEAR=1 \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 FM_INJECT_CONFIRM_SLEEP=0.05 \
    housekeeping "$state"
  [ ! -s "$sent" ] || fail "digest typed into a composer whose residual text would not clear"
  grep -F 'leftover junk that will not clear' "$dir/composer" >/dev/null \
    || fail "unclearable residual text was altered instead of preserved"
  [ -s "$state/.subsuper-inject-wedged" ] || fail "unclearable composer past max-defer did not raise a wedge alarm"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer lost while composer could not be cleared"
  pass "afk wedge: an unclearable composer declines delivery, preserves the buffer, and raises the alarm"
}

test_clear_composer_empties_poisoned_composer() {
  # The primitive in isolation: fm_tmux_clear_composer wipes stale text and
  # confirms the composer is empty (exit 0). A bare bordered prompt is already
  # empty (also exit 0, no-op).
  local dir fakebin
  dir=$(make_bordered_case clear-primitive)
  fakebin="$dir/fakebin"
  stale_inject_line > "$dir/composer"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" \
    fm_tmux_clear_composer "win" \
    || fail "fm_tmux_clear_composer did not confirm an empty composer after clearing"
  [ "$(PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" fm_tmux_composer_state win)" = empty ] \
    || fail "composer not empty after fm_tmux_clear_composer"
  pass "fm_tmux_clear_composer empties a poisoned composer and confirms empty"
}

test_afk_wedge_force_delivers_stale_self_injection
test_afk_wedge_busy_pane_still_defers
test_afk_off_does_not_clobber_human_line
test_afk_wedge_unclearable_composer_declines
test_clear_composer_empties_poisoned_composer
