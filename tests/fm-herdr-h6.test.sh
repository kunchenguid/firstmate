#!/usr/bin/env bash
# GATE h6 - the drain stays open, and nothing new is created on tmux.
#
# WHAT THIS GATE USED TO SAY, AND WHY IT CHANGED. It froze the exact sequence of
# tmux calls fm-spawn emitted, so that FM_MUX=tmux was provably a byte-identical
# rollback. That property is gone on purpose: with herdr the only surface there
# is no tmux spawn path left to be identical to, and a gate asserting parity
# with a retired path would keep passing while measuring nothing. A gate whose
# text stays put while its meaning drifts is worse than no gate.
#
# WHAT IS ACTUALLY TRUE AFTER THE CUTOVER, and is gated here instead:
#
#   1. NOTHING NEW IS CREATED ON TMUX. No spawn, under any environment, puts an
#      agent in a tmux window. The old FM_MUX=tmux override cannot bring it back.
#
#   2. THE DRAIN STAYS OPEN. Crewmates spawned BEFORE the cutover live in tmux
#      windows; their state/<id>.meta has no `mux=herdr` line. Those must stay
#      readable AND steerable AND closable until they are torn down. A watcher
#      that cannot read a live crewmate is blind; a supervisor that can watch
#      one but not correct it has lost half of supervision; and a teardown that
#      cannot close one strands work carrying unlanded commits. Removing the
#      drain would be a self-inflicted outage, so it is gated, not trusted.
#
#   3. THE DRAIN IS DERIVED, NOT LISTED. Which windows are draining is read from
#      the metas, never from a hardcoded inventory. A list has to be right, and
#      the one this migration was handed was not: it named four windows, missed
#      three live crewmates whose metas sit in another firstmate home, and named
#      two whose metas the author had not enumerated. A meta-derived rule is
#      correct under any inventory, and it closes by itself.
set -u

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"
# shellcheck source=bin/fm-herdr.sh
. "$ROOT/bin/fm-herdr.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-h6)
STATE="$TMP_ROOT/state"; mkdir -p "$STATE"

# A pre-cutover meta: a tmux window, no mux= line, because the seam that would
# have written one did not exist when it was spawned. This is the real shape -
# verified against every live meta in every firstmate home at cutover time, none
# of which carried a mux= key.
cat > "$STATE/drainer.meta" <<META
window=firstmate:fm-drainer
worktree=/wt
project=/p/thing
harness=claude
kind=ship
META
# A post-cutover meta: a herdr pane, marked as such.
cat > "$STATE/moderne.meta" <<META
window=wM:p4
worktree=/wt
project=/p/thing
harness=claude
mux=herdr
name=thing-fleet-view
kind=ship
META

# --- 1. nothing new is created on tmux --------------------------------------

test_no_script_can_spawn_onto_tmux() {
  # The spawn path names exactly one surface. If a tmux window-create ever
  # reappears in it, an agent can land where the captain cannot see it.
  if grep -vE '^[[:space:]]*#' "$ROOT/bin/fm-spawn.sh" | grep -qE 'tmux (new-window|new-session|has-session)'; then
    fail "fm-spawn can still create a tmux window or session"
  fi
  if grep -vE '^[[:space:]]*#' "$ROOT/bin/fm-spawn.sh" | grep -q 'FM_MUX'; then
    fail "the retired FM_MUX override is still read by fm-spawn"
  fi
  pass "cutover: fm-spawn cannot create a tmux window, and the old override is gone"
}

test_the_collapsed_libraries_are_gone() {
  assert_absent "$ROOT/bin/fm-mux-lib.sh" "the driver-selection library survived the collapse"
  assert_absent "$ROOT/bin/fm-herdr-workspaces.sh" "the workspaces script survived the collapse"
  assert_present "$ROOT/bin/fm-herdr.sh" "the collapsed library is missing"
  # Not a bare `herdr`: that would shadow the real binary at ~/.local/bin/herdr
  # and make which one a call site got depend on PATH order.
  assert_absent "$ROOT/bin/herdr" "a bare 'herdr' script would shadow the real binary"
  pass "cutover: one library, named so it cannot shadow the binary"
}

# --- 2. the drain stays open ------------------------------------------------

test_a_pre_cutover_meta_resolves_to_the_drain() {
  fm_herdr_resolve fm-drainer "$STATE" || fail "a pre-cutover meta would not resolve"
  assert_eq "$FM_HERDR_TARGET" "firstmate:fm-drainer" "the drain target was lost"
  assert_eq "$FM_HERDR_DRAIN" "1" "a pre-cutover meta was not marked for the drain"
  pass "drain: a meta with no mux=herdr resolves as a draining tmux window"
}

test_a_post_cutover_meta_does_not() {
  fm_herdr_resolve fm-moderne "$STATE" || fail "a post-cutover meta would not resolve"
  assert_eq "$FM_HERDR_TARGET" "wM:p4" "the herdr pane id was lost"
  assert_eq "$FM_HERDR_DRAIN" "0" "a herdr crewmate was sent down the drain path"
  pass "drain: a meta with mux=herdr is addressed as herdr, never drained"
}

# The three verbs the constraint names. Losing any one is an outage: read is
# supervision, send is correction, close is cleanup.
test_the_drain_keeps_read_send_and_close_reachable() {
  local peek send
  peek=$(grep -vE '^[[:space:]]*#' "$ROOT/bin/fm-peek.sh")
  send=$(grep -vE '^[[:space:]]*#' "$ROOT/bin/fm-send.sh")
  case "$peek" in
    *"FM_HERDR_DRAIN"*) : ;;
    *) fail "fm-peek has no drain branch; a live pre-cutover crewmate is unreadable" ;;
  esac
  case "$peek" in
    *"capture-pane"*) : ;;
    *) fail "fm-peek can no longer read a tmux pane; the watcher would go blind" ;;
  esac
  case "$send" in
    *"FM_HERDR_DRAIN"*) : ;;
    *) fail "fm-send has no drain branch; a live pre-cutover crewmate is unsteerable" ;;
  esac
  case "$send" in
    *"fm_tmux_submit_core"*) : ;;
    *) fail "fm-send can no longer submit to a tmux pane; steering a draining crewmate would break" ;;
  esac
  # Close now routes through fm_herdr_close_pane, which keeps the tmux branch for
  # a draining window. Assert the branch still EXISTS where it moved to, and that
  # teardown actually reaches it - checking only that teardown mentions
  # `tmux kill-window` was what let a herdr tab leak while the gate stayed green.
  case "$(grep -vE '^[[:space:]]*#' "$ROOT/bin/fm-herdr.sh")" in
    *"tmux kill-window"*) : ;;
    *) fail "the drain lost its tmux close; draining work would be stranded" ;;
  esac
  case "$(grep -vE '^[[:space:]]*#' "$ROOT/bin/fm-teardown.sh")" in
    *"fm_herdr_close_pane"*) : ;;
    *) fail "teardown does not close through the surface; a herdr tab would leak" ;;
  esac
  pass "drain: read, send and close all remain reachable for a draining window"
}

test_the_drain_library_is_retired_not_deleted() {
  assert_present "$ROOT/bin/fm-tmux-lib.sh" \
    "fm-tmux-lib.sh was deleted while windows are still draining; supervision and cleanup would both break"
  # Retired means NO NEW USE: the spawn path must not touch it.
  if grep -vE '^[[:space:]]*#' "$ROOT/bin/fm-spawn.sh" | grep -q 'fm-tmux-lib.sh'; then
    fail "the spawn path still sources the retired tmux library"
  fi
  pass "drain: fm-tmux-lib.sh is retired for new use, and kept while the drain is open"
}

# --- 3. the drain is derived, and it closes by itself ------------------------

test_drain_pending_is_computed_from_metas() {
  if ! fm_herdr_drain_pending "$STATE"; then
    fail "a state dir holding a pre-cutover meta reported no drain pending"
  fi
  # Remove the only pre-cutover meta and the drain closes - no list to edit.
  rm -f "$STATE/drainer.meta"
  if fm_herdr_drain_pending "$STATE"; then
    fail "the drain stayed open with every meta marked mux=herdr"
  fi
  pass "drain: pending is computed from the metas, and closes when the last one is gone"
}

# --- an EXPLICIT target, which no gate covered at all -----------------------
#
# The documented cross-home path: AGENTS.md tells firstmate to pass an explicit
# target to reach a pane outside this home, and fm-peek/fm-send both advertise
# it. Misclassifying one aims tmux verbs at a session that does not exist, so
# peek and steer break silently for that crewmate.

# BOTH halves of a herdr pane id are base-36, not decimal: the pane counter
# rolls into letters at the tenth pane, so a live server holds `wM:p9` and
# `wM:pA` side by side. Matching only digits sent every pane past the ninth
# down the drain - i.e. exactly the crewmates a busy fleet has most of.
test_a_letter_suffixed_pane_id_is_not_drained() {
  local id
  for id in wM:p9 wM:pA wN:p1 wZ:p10 wAB:pZZ; do
    fm_herdr_resolve "$id" "$STATE" || fail "explicit target $id would not resolve"
    assert_eq "$FM_HERDR_TARGET" "$id" "the explicit target was rewritten"
    assert_eq "$FM_HERDR_DRAIN" "0" "herdr pane id $id was misclassified as a draining tmux window"
  done
  pass "explicit: a base-36 herdr pane id is addressed as herdr, never drained"
}

# The same shape test errs in BOTH directions, so both are pinned. Matching too
# narrowly drained real panes; matching with unanchored tails swallows tmux
# targets that merely start `w...:p...` - `work:prod-fix` and `web:pane1` are
# session:window pairs, and sending herdr verbs at them is the same misrouting
# with the surfaces swapped.
test_an_explicit_tmux_target_still_drains() {
  local t
  for t in firstmate:fm-drainer other:fm-thing firstmate:pending-fix \
           work:prod-fix web:pane1 wide:print; do
    fm_herdr_resolve "$t" "$STATE" || fail "explicit target $t would not resolve"
    assert_eq "$FM_HERDR_TARGET" "$t" "the explicit target was rewritten"
    assert_eq "$FM_HERDR_DRAIN" "1" "tmux target $t was misclassified as a herdr pane"
  done
  pass "explicit: a session:window target still takes the drain path"
}

# The META, not the shape. A recorded target is not something to guess at: when
# this home has a meta whose window= is exactly this target, its mux= is the
# answer and the shape test is never consulted.
test_an_explicit_target_is_classified_by_its_meta_first() {
  fm_herdr_resolve "wM:p4" "$STATE" || fail "a recorded herdr target would not resolve"
  assert_eq "$FM_HERDR_DRAIN" "0" "a recorded mux=herdr target was drained"
  # The adversarial case: a pre-cutover window whose NAME happens to take the
  # herdr shape. The meta says tmux, so the shape must not get a vote.
  cat > "$STATE/oddly.meta" <<META
window=w9:p9
worktree=/wt
project=/p/thing
harness=claude
kind=ship
META
  fm_herdr_resolve "w9:p9" "$STATE" || fail "a recorded pre-cutover target would not resolve"
  assert_eq "$FM_HERDR_DRAIN" "1" "the shape test overrode a meta that says this is a tmux window"
  rm -f "$STATE/oddly.meta"
  pass "explicit: the meta decides where one exists; the shape test is the last resort"
}

# An empty or absent state dir is not a drain - it is nothing to drain.
test_an_empty_home_has_no_drain() {
  mkdir -p "$TMP_ROOT/empty-state"
  if fm_herdr_drain_pending "$TMP_ROOT/empty-state"; then
    fail "an empty state dir reported a drain pending"
  fi
  if fm_herdr_drain_pending "$TMP_ROOT/no-such-dir"; then
    fail "a missing state dir reported a drain pending"
  fi
  pass "drain: an empty or absent home has nothing to drain"
}

test_no_script_can_spawn_onto_tmux
test_the_collapsed_libraries_are_gone
test_a_pre_cutover_meta_resolves_to_the_drain
test_a_post_cutover_meta_does_not
test_the_drain_keeps_read_send_and_close_reachable
test_the_drain_library_is_retired_not_deleted
test_a_letter_suffixed_pane_id_is_not_drained
test_an_explicit_tmux_target_still_drains
test_an_explicit_target_is_classified_by_its_meta_first
test_drain_pending_is_computed_from_metas
test_an_empty_home_has_no_drain
