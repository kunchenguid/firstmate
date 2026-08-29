#!/usr/bin/env bash
# GATE h1 - herdr is the only surface. There is nothing to select.
#
# THE CAPTAIN'S RULE, stated 2026-08-28 and recorded in AGENTS.md under
# "herdr workspace hygiene" (his own copy is local and gitignored, so the
# tracked section is what any clone can read):
#
#   "Headless is not an automatic fallback and must never be selected by a
#    reachability rule. Any tier may *recommend* a headless run, but it asks me
#    first... Silent degradation to headless is the specific failure this rule
#    exists to prevent."
#
# This gate has been re-cut twice, and the history is the point.
#
#   v1 pinned a reachability rule: herdr when a server answered, tmux otherwise,
#      announced on stderr. Loud, but still the machine choosing headless.
#   v2 removed the reachability branch but kept FM_MUX as an explicit override
#      and a whole driver-dispatch layer behind it.
#   v3 (here) removes the selection machinery entirely. With one surface there
#      is no driver to choose, so there is no code that could choose wrongly.
#
# A rule enforced by a branch is a rule that can be branched around. A rule
# enforced by there being no branch cannot. What is left to gate is that the
# machinery is genuinely GONE - not reduced to a constant that a later edit
# could turn back into a decision - and that an unreachable herdr escalates.
set -u

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"
# shellcheck source=bin/fm-herdr.sh
. "$ROOT/bin/fm-herdr.sh"

# The reachability cases below assert what the session probe resolves to, so an
# ambient HERDR_SESSION in the runner's shell would silently change the answer.
unset HERDR_SESSION FM_HERDR_SESSION

TMP_ROOT=$(fm_test_tmproot fm-herdr-h1)
FB=$(fm_herdr_fake_server "$TMP_ROOT")
PATH="$FB:$PATH"; export PATH
CALLS="$TMP_ROOT/calls"; export CALLS
: > "$CALLS"

LIB="$ROOT/bin/fm-herdr.sh"

# --- the selection machinery is gone ----------------------------------------

# Not "returns herdr" - ABSENT. A constant-returning selector is an invitation
# to add a branch back into it; no selector at all is not.
test_there_is_no_driver_selector() {
  if grep -qE '^\s*fm_(mux|herdr)_driver\s*\(\)' "$LIB"; then
    fail "a driver selector still exists; the rule is enforced by there being no choice"
  fi
  # Strip comments first: the collapsed library NAMES the machinery it removed,
  # which is documentation, not a surviving call site.
  if grep -h -vE '^[[:space:]]*#' "$ROOT"/bin/fm-*.sh | grep -qE 'fm_mux_dispatch|fm_mux_driver'; then
    fail "driver dispatch survives somewhere in bin/"
  fi
  pass "selection: no driver selector and no dispatch layer exist"
}

# FM_MUX was the override in v2. With one surface there is nothing for it to
# select, so it must not be readable anywhere - a variable that still works is
# a way to divert an agent off the captain's screen.
test_fm_mux_no_longer_selects_anything() {
  local hits
  hits=$(grep -h -vE '^[[:space:]]*#' "$ROOT"/bin/*.sh | grep -F 'FM_MUX' || true)
  if [ -n "$hits" ]; then
    fail "FM_MUX is still read by bin/: $hits"
  fi
  pass "selection: FM_MUX selects nothing; it is not read by any script"
}

# The proof that matters to the fleet, not to the source: setting the old
# override cannot divert a spawn. Covered end to end in h3; asserted here
# because this is the file that owns the rule.
test_the_old_override_cannot_divert_anything() {
  local out
  out=$(FM_MUX=tmux bash -c '. "$1"; fm_herdr_pane_name proj work' _ "$LIB" 2>&1)
  assert_eq "$out" "proj-work" "the library behaved differently under the retired override"
  pass "selection: the retired FM_MUX override changes nothing"
}

# --- reachability is a diagnostic, never a selector --------------------------

test_reachability_is_only_ever_a_diagnostic() {
  local rc=0
  HERDR_SERVER=running bash -c '. "$1"; fm_herdr_up' _ "$LIB" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "fm_herdr_up did not see a running server"
  rc=0
  HERDR_SERVER=stopped bash -c '. "$1"; fm_herdr_up' _ "$LIB" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then fail "fm_herdr_up reported a stopped server as up"; fi
  pass "reachability: answers honestly, and nothing selects a surface from it"
}

# A false negative here strands the WHOLE fleet: this predicate is the single
# gate on all dispatch, so a running server it refuses to see makes bootstrap
# print NEEDS_HERDR_SERVER and every spawn stop at the escalation. herdr manages
# named persistent sessions, so a fleet running under one must be reachable -
# reached the way the verbs reach it, through $HERDR_SESSION.
test_a_named_session_is_a_running_server() {
  local rc=0
  HERDR_SESSION=fleet HERDR_SESSION_NAME=fleet HERDR_SERVER=running \
    bash -c '. "$1"; fm_herdr_up' _ "$LIB" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "a running session not called 'default' was reported as unreachable"
  rc=0
  HERDR_SESSION=fleet HERDR_SESSION_NAME=fleet HERDR_SERVER=stopped \
    bash -c '. "$1"; fm_herdr_up' _ "$LIB" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then fail "a stopped named session was reported as up"; fi
  pass "reachability: the session the verbs target counts, whatever it is named"
}

# THE OPPOSITE ERROR, and the one no gate covered - which is how it shipped.
# Matching ANY running row answers a different question from the one dispatch
# depends on: `herdr session list` ignores $HERDR_SESSION and lists every
# session on the machine, while every verb targets $HERDR_SESSION only. So a
# machine with `fleet` up and nothing on `default` reported REACHABLE, bootstrap
# stayed silent, and the spawn died later at `tab create` with a worse, less
# actionable diagnostic than the escalation this predicate exists to produce.
test_a_running_session_the_verbs_cannot_reach_is_not_up() {
  local rc=0
  # $1 is bash -c's own positional, expanded by the inner shell - intentional.
  # shellcheck disable=SC2016
  env -u HERDR_SESSION -u FM_HERDR_SESSION HERDR_SESSION_NAME=fleet HERDR_SERVER=running \
    bash -c '. "$1"; fm_herdr_up' _ "$LIB" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then
    fail "a running session the verbs will never target was reported as reachable"
  fi
  pass "reachability: a running session the verbs cannot reach is not a reachable fleet"
}

# The override is for pinning ONE session deliberately. It must actually
# discriminate, or it is decoration.
test_the_session_override_pins_one_session() {
  local rc=0
  FM_HERDR_SESSION=fleet HERDR_SESSION_NAME=fleet HERDR_SERVER=running \
    bash -c '. "$1"; fm_herdr_up' _ "$LIB" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "the override did not match the session it names"
  rc=0
  FM_HERDR_SESSION=other HERDR_SESSION_NAME=fleet HERDR_SERVER=running \
    bash -c '. "$1"; fm_herdr_up' _ "$LIB" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then fail "the override matched a session it does not name"; fi
  pass "reachability: FM_HERDR_SESSION pins one named session"
}

# The pin has to move the VERBS, not just the probe. Filtering this predicate
# while every verb still hit `default` is exactly the divergence above, dressed
# up as an override that appeared to work.
test_the_session_override_moves_the_verbs_too() {
  local out
  # $1 and $HERDR_SESSION are expanded by the inner shell - intentional.
  # shellcheck disable=SC2016
  out=$(env -u HERDR_SESSION FM_HERDR_SESSION=fleet \
    bash -c '. "$1"; printf "%s" "${HERDR_SESSION:-unset}"' _ "$LIB" 2>/dev/null)
  assert_eq "$out" "fleet" "FM_HERDR_SESSION did not export HERDR_SESSION for the verbs"
  # shellcheck disable=SC2016
  out=$(env -u HERDR_SESSION -u FM_HERDR_SESSION \
    bash -c '. "$1"; fm_herdr_session' _ "$LIB" 2>/dev/null)
  assert_eq "$out" "default" "the probed session is not herdr's own default"
  pass "reachability: the session pin moves the verbs, not only the probe"
}

# --- an unreachable herdr ESCALATES -----------------------------------------

# The message has to be one the captain can act on: what is wrong, and that the
# call is his. A tier RECOMMENDS headless by printing this and stopping - it
# never chooses it.
test_unreachable_herdr_escalates_with_an_actionable_message() {
  local out rc=0
  out=$(HERDR_SERVER=stopped bash -c '. "$1"; fm_herdr_require "crewmate x"' _ "$LIB" 2>&1) || rc=$?
  if [ "$rc" = 0 ]; then fail "an unreachable herdr was treated as fine"; fi
  assert_contains "$out" "no herdr server is reachable" "the escalation does not name the problem"
  assert_contains "$out" "crewmate x" "the escalation does not say what could not be placed"
  assert_contains "$out" "captain" "the escalation does not say whose decision this is"
  assert_contains "$out" "NOT falling back" "the escalation does not say it refused to degrade"
  pass "escalation: an unreachable herdr stops and asks, naming the problem and the decision"
}

# It must name WHICH session was missing. Another session can be plainly running
# while the one the verbs target is not, and "no herdr server is running" would
# send the captain to restart a server he can already see.
test_the_escalation_names_the_session_it_looked_for() {
  local out rc=0
  out=$(FM_HERDR_SESSION=fleet HERDR_SESSION_NAME=other HERDR_SERVER=running \
    bash -c '. "$1"; fm_herdr_require "crewmate z"' _ "$LIB" 2>&1) || rc=$?
  if [ "$rc" = 0 ]; then fail "a session the verbs cannot reach passed the precondition"; fi
  assert_contains "$out" "fleet" "the escalation does not name the session it looked for"
  pass "escalation: the message names the session the verbs would have used"
}

test_absent_binary_escalates_with_its_own_reason() {
  local out rc=0 clean
  clean=$(fm_herdr_path_without_binary herdr)
  out=$(PATH="$clean" bash -c '. "$1"; fm_herdr_require "crewmate y"' _ "$LIB" 2>&1) || rc=$?
  if [ "$rc" = 0 ]; then fail "a missing herdr binary was treated as fine"; fi
  assert_contains "$out" "not on PATH" "an absent binary is not reported as its own distinct reason"
  pass "escalation: an absent binary escalates too - installing it is not this script's call"
}

# A SUITE MUST NOT DEPEND ON THE CAPTAIN'S OWN SHELL. The probe resolves
# ${HERDR_SESSION:-default}, so an ambient pin - the very configuration the
# override exists to support - would make every fake-server suite ask for a
# session its fake does not model, and each would go red for a reason unrelated
# to what it tests. tests/lib.sh neutralises the pin for every non-live suite,
# which is a property; leaving each file to remember was a hope, and six of them
# did not. A case that wants a named session still sets it per invocation.
test_a_fake_server_suite_is_hermetic_against_an_ambient_pin() {
  local rc=0 out
  out=$(HERDR_SESSION=fleet FM_HERDR_SESSION=fleet HERDR_SERVER=running FB="$FB" \
    bash -c '. "$1"; PATH="$FB:$PATH"; . "$2"; printf "%s" "${HERDR_SESSION:-unset}"' \
    _ "$ROOT/tests/lib.sh" "$LIB" 2>/dev/null)
  assert_eq "$out" "unset" "tests/lib.sh left the captain's session pin in the suite's environment"
  HERDR_SESSION=fleet FM_HERDR_SESSION=fleet HERDR_SERVER=running FB="$FB" \
    bash -c '. "$1"; PATH="$FB:$PATH"; . "$2"; fm_herdr_up' \
    _ "$ROOT/tests/lib.sh" "$LIB" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "an ambient session pin made a fake-server suite see an unreachable fleet"
  pass "reachability: a fake-server suite is hermetic against an ambient session pin"
}

# The fake must model a server the verbs would actually reach, or it proves
# nothing about them. When a case pins a session deliberately, the fake's
# default follows that pin rather than answering for `default`.
test_the_fake_server_models_the_session_the_verbs_target() {
  local rc=0
  HERDR_SESSION=fleet HERDR_SERVER=running \
    bash -c '. "$1"; fm_herdr_up' _ "$LIB" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "the fake answered for a session the probe would never ask about"
  pass "reachability: the fake server models the session the verbs target"
}

test_reachable_herdr_passes_silently() {
  local out rc=0
  out=$(HERDR_SERVER=running bash -c '. "$1"; fm_herdr_require' _ "$LIB" 2>&1) || rc=$?
  expect_code 0 "$rc" "a reachable herdr server failed the precondition"
  assert_eq "$out" "" "the precondition is noisy on the happy path"
  pass "escalation: a reachable server passes silently"
}

test_there_is_no_driver_selector
test_fm_mux_no_longer_selects_anything
test_the_old_override_cannot_divert_anything
test_reachability_is_only_ever_a_diagnostic
test_a_named_session_is_a_running_server
test_a_running_session_the_verbs_cannot_reach_is_not_up
test_the_session_override_pins_one_session
test_the_session_override_moves_the_verbs_too
test_a_fake_server_suite_is_hermetic_against_an_ambient_pin
test_the_fake_server_models_the_session_the_verbs_target
test_unreachable_herdr_escalates_with_an_actionable_message
test_the_escalation_names_the_session_it_looked_for
test_absent_binary_escalates_with_its_own_reason
test_reachable_herdr_passes_silently
