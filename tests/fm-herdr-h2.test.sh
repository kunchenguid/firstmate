#!/usr/bin/env bash
# GATE h2 - workspace scoping: resolved explicitly, never by luck.
#
# THE BUG THIS REPLACES. The original tab-create took a <session> argument and
# ignored it, calling `herdr tab create --cwd ... --label ... --no-focus` with
# no --workspace at all. herdr then puts the tab in whatever workspace happens
# to be FOCUSED. That is not targeting, it is luck: a crewmate for project A
# lands in the captain's config workspace because that is where his cursor was.
#
# THE ANSWER, per the captain's one-workspace-per-project standing order:
#   1. FM_HERDR_WORKSPACE overrides everything (a label if one matches, else a
#      literal workspace id) - and refuses loudly if it names nothing live,
#      because a typo'd override must not silently become focus-luck again;
#   2. otherwise the workspace whose LABEL is the project name;
#   3. neither exists -> CREATE it, labelled for the project.
#
# WHY CREATE, of the three options the design left open (create / fall back /
# refuse). Refusing would strand the first spawn into every newly added project,
# for a workspace firstmate is willing to make. Falling back is the bug above.
# Creating is also exactly what `fm-herdr.sh --apply` already does,
# so the spawn path and the reconcile path agree instead of disagreeing.
#
# NEVER HARDCODED. Workspace ids like `wJ` are runtime values: the captain's
# workspace today, someone else's after a server restart. Resolution is by
# label, always.
set -u

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"
# shellcheck source=bin/fm-herdr.sh
. "$ROOT/bin/fm-herdr.sh"

TMP_ROOT=$(fm_test_tmproot fm-mux-h2)
FB=$(fm_herdr_fake_server "$TMP_ROOT")
PATH="$FB:$PATH"; export PATH
CALLS="$TMP_ROOT/calls"; export CALLS
export HERDR_WORKSPACES="wJ=config,wM=archify,wN=firstmate"
export HERDR_WS_CREATED="$TMP_ROOT/created"
export HERDR_TABS="$TMP_ROOT/tabs"
reset() { : > "$CALLS"; : > "$HERDR_WS_CREATED"; : > "$HERDR_TABS"; }

# --- resolution by project label --------------------------------------------

test_resolves_the_project_workspace_by_label() {
  reset
  local got
  got=$(FM_HERDR_WORKSPACE='' fm_herdr_workspace_for archify /p/archify)
  assert_eq "$got" wM "a project must resolve to ITS workspace, not the focused one"
  assert_no_grep "workspace create" "$CALLS" "an existing workspace was recreated"
  pass "scope: resolved by project label (archify -> wM)"
}

# The id is never baked in. Same label, different runtime id, same answer.
test_resolution_survives_a_reshuffled_id_space() {
  reset
  local got
  got=$(HERDR_WORKSPACES="w1=firstmate,w2=archify" FM_HERDR_WORKSPACE='' fm_herdr_workspace_for archify /p/archify)
  assert_eq "$got" w2 "resolution must follow the LABEL; ids do not survive a restart"
  pass "scope: follows the label across a reshuffled id space (no hardcoded wJ)"
}

# --- create on missing ------------------------------------------------------

test_missing_workspace_is_created_for_the_project() {
  reset
  local got
  got=$(FM_HERDR_WORKSPACE='' fm_herdr_workspace_for brandnew /p/brandnew)
  assert_eq "$got" wNEW "a created workspace must yield its new id"
  assert_grep "workspace create" "$CALLS" "the missing workspace was not created"
  assert_grep "--label brandnew" "$CALLS" "the new workspace was not labelled for the project"
  assert_grep "--no-focus" "$CALLS" "creating a workspace stole the captain's focus"
  pass "scope: an absent project workspace is created, labelled, and not focused"
}

test_creation_failure_is_fatal_not_a_silent_fallback() {
  reset
  local rc=0
  # No server: `workspace create` cannot succeed, and the seam must NOT quietly
  # proceed to an unscoped tab create - that is the original bug.
  HERDR_WORKSPACES="" PATH="$(fm_herdr_path_without_binary herdr)" fm_herdr_workspace_for nope /p/nope >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then fail "a workspace that could not be resolved returned success"; fi
  pass "scope: an unresolvable workspace fails loudly instead of falling back to focus"
}

# --- the override -----------------------------------------------------------

test_override_by_label_wins() {
  reset
  local got
  got=$(FM_HERDR_WORKSPACE=config fm_herdr_workspace_for archify /p/archify)
  assert_eq "$got" wJ "FM_HERDR_WORKSPACE given as a label must win"
  pass "scope: FM_HERDR_WORKSPACE overrides by label"
}

test_override_by_raw_id_wins() {
  reset
  local got
  got=$(FM_HERDR_WORKSPACE=wM fm_herdr_workspace_for archify /p/archify)
  assert_eq "$got" wM "FM_HERDR_WORKSPACE given as a raw id must win"
  pass "scope: FM_HERDR_WORKSPACE overrides by workspace id"
}

# A typo must not degrade into focus-luck; that is the failure being removed.
test_override_naming_nothing_live_refuses() {
  reset
  local rc=0 err
  err=$(FM_HERDR_WORKSPACE=wDOESNOTEXIST fm_herdr_workspace_for archify /p/archify 2>&1) || rc=$?
  if [ "$rc" = 0 ]; then fail "an override naming no live workspace was accepted"; fi
  assert_contains "$err" "FM_HERDR_WORKSPACE" "the refusal does not name the override"
  assert_no_grep "workspace create" "$CALLS" "a bad override silently created a workspace"
  pass "scope: an override naming nothing live is refused, not silently re-resolved"
}

# --- the tab actually carries the scope -------------------------------------

# The end of the chain: whatever was resolved must reach `herdr tab create` as
# --workspace. Resolving correctly and then not passing it is the same bug.
test_new_window_passes_the_resolved_workspace() {
  reset
  local ws target
  ws=$(FM_HERDR_WORKSPACE='' fm_herdr_workspace_for archify /p/archify)
  target=$(fm_herdr_new_tab "$ws" booking-fix /p/archify)
  assert_grep "tab create --workspace wM" "$CALLS" "the resolved workspace never reached tab create"
  assert_eq "$target" "wM:p2" "the target must be the pane herdr actually made"
  pass "scope: the resolved workspace is what tab create is scoped to"
}

# Belt and braces on the other side of the same seam: an EMPTY scope must not
# silently produce a tab somewhere. The fake mirrors the real hazard by refusing
# an unscoped create, so a driver that shrugged and carried on would be caught
# here rather than in the captain's config workspace.
test_an_empty_scope_cannot_produce_a_tab() {
  reset
  local rc=0 out
  out=$(fm_herdr_new_tab "" booking-fix /p/archify 2>&1) || rc=$?
  if [ "$rc" = 0 ]; then fail "an unscoped tab create was treated as success: '$out'"; fi
  assert_contains "$out" "tab create failed" "the refusal is not reported to the caller"
  pass "scope: an unscoped tab create cannot succeed (focus-luck is unreachable)"
}

test_resolves_the_project_workspace_by_label
test_resolution_survives_a_reshuffled_id_space
test_missing_workspace_is_created_for_the_project
test_creation_failure_is_fatal_not_a_silent_fallback
test_override_by_label_wins
test_override_by_raw_id_wins
test_override_naming_nothing_live_refuses
test_new_window_passes_the_resolved_workspace
test_an_empty_scope_cannot_produce_a_tab
