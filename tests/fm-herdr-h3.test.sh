#!/usr/bin/env bash
# GATE h3 - a herdr spawn lands as a NAMED TAB in the RESOLVED workspace.
#
# THE DEFECT. bin/fm-spawn.sh drove tmux directly, so every crewmate this fleet
# spawned landed in a tmux session the captain cannot see. A pane he cannot see
# does not count.
#
# WHAT THIS GATE PINS, end to end through fm-spawn.sh:
#   * herdr is where the crewmate is created - there is no other surface, and
#     an unreachable server stops the spawn rather than diverting it;
#   * the tab is scoped to the project's workspace, resolved by label;
#   * the tab is NAMED <project>-<work>, never the task id;
#   * the name is one herdr will actually accept as an agent address - the fake
#     enforces herdr 0.8.2's real ^[a-z][a-z0-9_-]{0,31}$ rule, so a slash
#     separator fails here rather than in the captain's sidebar;
#   * the meta records the herdr pane id and marks the crewmate post-cutover,
#     which is what keeps it addressed with herdr verbs later;
#   * the task id stays in the meta and out of the name.
set -u
export FM_INTAKE_OVERRIDE=1   # wardroom: this suite tests spawn machinery, not intake
export FM_SKIP_SHELL_READY=1  # readiness is gated by h5 against a live pane

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-mux-h3)
fm_git_identity fmtest fmtest@example.invalid

make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

PROJ=$(make_repo "$TMP_ROOT/archify")
git -C "$PROJ" worktree add -q --detach "$TMP_ROOT/wt" >/dev/null 2>&1
WT=$(cd "$TMP_ROOT/wt" && pwd -P)

# BOTH multiplexers are faked. Faking only herdr is not enough: a stray tmux
# call would then drive the REAL tmux server and leave a window in the captain's
# live firstmate session - which is exactly what happened once during this work,
# and what the duplicate-window guard then refused on the next run. Faking tmux
# is how such a call is CAUGHT here rather than landing on the live server.
# A spawn test must be unable to reach any live multiplexer.
FB=$(fm_herdr_fake_server "$TMP_ROOT")
fm_herdr_fake_tmux "$TMP_ROOT" >/dev/null
fm_fake_exit0 "$FB" treehouse
CALLS="$TMP_ROOT/calls"; export CALLS

run_spawn() {  # <home> <id> [extra args...]
  local home=$1 id=$2; shift 2
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  env \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_LAUNCH_VERIFY_SLEEP=0 \
    HERDR_SERVER="${HERDR_SERVER:-running}" HERDR_NO_TAB="${HERDR_NO_TAB:-0}" \
    FM_HERDR_SESSION="${FM_HERDR_SESSION:-}" \
    HERDR_SESSION_NAME="${HERDR_SESSION_NAME:-default}" \
    HERDR_WORKSPACES="wJ=config,wM=archify" \
    HERDR_PANE_CWD="$WT" \
    HERDR_TABS="$TMP_ROOT/tabs" \
    HERDR_WS_CREATED="$TMP_ROOT/created" \
    TMUX_CWD="$WT" TMUX_SESSION=firstmate TMUX="fake,1,0" \
    CALLS="$CALLS" \
    PATH="$FB:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" codex "$@" 2>&1
}

reset() { : > "$CALLS"; : > "$TMP_ROOT/tabs"; : > "$TMP_ROOT/created"; }

# --- the default lands in herdr ---------------------------------------------

test_a_spawn_lands_in_herdr() {
  reset
  local home out
  home="$TMP_ROOT/home-default"; mkdir -p "$home/data"
  out=$(run_spawn "$home" fleet-view-q4 --name "fleet view")
  assert_contains "$out" "spawned fleet-view-q4" "the spawn did not succeed"
  assert_contains "$out" "mux=herdr" "the spawn did not report herdr as the surface"
  assert_grep "tab create" "$CALLS" "no herdr tab was created - the crewmate went somewhere invisible"
  assert_no_grep "new-window" "$CALLS" "the spawn created a tmux window; herdr is the only surface"
  pass "surface: a crewmate is created as a herdr tab, with nothing to configure"
}

# --- scoped to the project's workspace --------------------------------------

test_tab_is_scoped_to_the_project_workspace() {
  reset
  local home
  home="$TMP_ROOT/home-scope"; mkdir -p "$home/data"
  run_spawn "$home" leak-fixes-b2 --name "leak fixes" >/dev/null
  assert_grep "tab create --workspace wM" "$CALLS" \
    "the tab was not scoped to the archify workspace (it landed wherever focus was)"
  pass "scope: the tab is created in the project's own workspace, resolved by label"
}

# --- named for the work, not the id -----------------------------------------

test_tab_is_named_for_the_work() {
  reset
  local home
  home="$TMP_ROOT/home-name"; mkdir -p "$home/data"
  run_spawn "$home" resources-r7 --name "resource registry" >/dev/null
  assert_grep "--label archify-resource-registry" "$CALLS" \
    "the tab was not labelled <project>-<work>"
  assert_no_grep "--label fm-resources-r7" "$CALLS" \
    "the tab was labelled with the task id - the exact thing a name must not be"
  pass "naming: the tab is labelled archify-resource-registry, not the task id"
}

# The name must be one herdr ACCEPTS. The fake enforces the real 0.8.2 rule, so
# a slash separator makes `agent rename` fail here instead of leaving the
# captain with an unaddressable pane.
test_the_name_is_one_herdr_accepts() {
  reset
  local home
  home="$TMP_ROOT/home-accept"; mkdir -p "$home/data"
  run_spawn "$home" hook-register-c9 --name "hook register" >/dev/null
  assert_grep "agent rename" "$CALLS" "the agent was never given its address"
  assert_grep "agent rename wM:p2 archify-hook-register" "$CALLS" \
    "the agent address is not the hyphen-joined project-first name herdr accepts"
  pass "naming: herdr accepted the name as an agent address (a slash would not be)"
}

# Absent --name, the work half comes from the id with its random suffix dropped.
test_name_defaults_from_the_task_id_without_its_suffix() {
  reset
  local home
  home="$TMP_ROOT/home-derive"; mkdir -p "$home/data"
  run_spawn "$home" boot-activation-k3 >/dev/null
  assert_grep "--label archify-boot-activation" "$CALLS" \
    "the derived name kept the random task suffix"
  pass "naming: an absent --name derives archify-boot-activation from boot-activation-k3"
}

# The other direction, and the one a length rule gets wrong. Stripping any short
# trailing segment ate REAL words - `add-api` became `add`, `fix-ui` became
# `fix` - dropping the most specific word from the name the captain reads, and
# collapsing ids that share no stem onto one label so the second spawn hard-
# failed at the duplicate check. The suffix is a SHAPE (letter then digit), not
# a length.
test_a_derived_name_keeps_a_real_trailing_word() {
  reset
  local home
  home="$TMP_ROOT/home-derive-word"; mkdir -p "$home/data"
  run_spawn "$home" add-api >/dev/null
  assert_grep "--label archify-add-api" "$CALLS" \
    "the derived name ate a real trailing word - the work is 'add-api', not 'add'"
  reset
  home="$TMP_ROOT/home-derive-word2"; mkdir -p "$home/data"
  run_spawn "$home" update-dns-k3 >/dev/null
  assert_grep "--label archify-update-dns" "$CALLS" \
    "the derived name did not drop a real task-id suffix"
  pass "naming: the derived name drops a <letter><digit> suffix and keeps real words"
}

# The suffix is a CONTRACT stated where ids are minted (AGENTS.md section 2), so
# an id outside it keeps its suffix rather than being guessed at - guessing is
# what ate real words. And the one case that genuinely loses information, a work
# half too long for the name budget, SAYS so instead of silently handing the
# captain a truncated name.
test_an_off_contract_id_keeps_its_suffix_and_truncation_speaks_up() {
  reset
  local home out
  home="$TMP_ROOT/home-off-contract"; mkdir -p "$home/data"
  run_spawn "$home" fix-login-ab >/dev/null
  assert_grep "--label archify-fix-login-ab" "$CALLS" \
    "an id outside the documented suffix shape must keep its suffix, not be guessed at"

  reset
  home="$TMP_ROOT/home-truncated"; mkdir -p "$home/data"
  out=$(run_spawn "$home" long-x1 \
    --name "a work name far too long for one pane label")
  case "$out" in
    *"does not fit a pane name"*"pass --name"*) ;;
    *) fail "a truncated pane name degraded silently (got: $out)" ;;
  esac
  pass "naming: an off-contract id keeps its suffix, and truncation reports itself"
}

# herdr constrains the FIRST character of the WHOLE name, so a digit is only
# illegal where the name STARTS. Enforcing that on every half deleted a leading
# character for nothing: `2fa-login` became `fa-login`, so the captain read
# `archify-fa-login` for work called 2fa-login - the wrong work, in the one line
# that names the work. It degraded silently too, because the shortened-name note
# compared the assembled name against the same mangled halves.
test_a_leading_digit_survives_in_the_work_half() {
  reset
  local home out
  home="$TMP_ROOT/home-lead-digit"; mkdir -p "$home/data"
  out=$(run_spawn "$home" 2fa-login-k3)
  assert_grep "--label archify-2fa-login" "$CALLS" \
    "a leading digit was eaten from the work half - the work is '2fa-login', not 'fa-login'"
  case "$out" in
    *"does not fit a pane name"*) fail "an untruncated name reported itself as shortened" ;;
  esac

  reset
  home="$TMP_ROOT/home-lead-digit2"; mkdir -p "$home/data"
  run_spawn "$home" render-x1 --name "3d render" >/dev/null
  assert_grep "--label archify-3d-render" "$CALLS" \
    "a leading digit was eaten from an explicit --name"

  # The project half DOES lead, so there the strip is real and still applies.
  reset
  home="$TMP_ROOT/home-lead-proj"; mkdir -p "$home/data"
  local nm
  nm=$(bash -c '. "$1"; fm_herdr_pane_name 2app work' _ "$ROOT/bin/fm-herdr.sh")
  [ "$nm" = "app-work" ] || fail "the leading half must still start with a letter (got: $nm)"
  pass "naming: a leading digit is kept in the work half and stripped only where the name starts"
}

# --- the session pin reaches the AGENT ---------------------------------------

# A pane's shell is forked by the herdr server at `tab create`, not by fm-spawn,
# so nothing this process exports reaches the agent - which is why FM_HOME has
# to be prepended to the launch string. HERDR_SESSION is in exactly the same
# position: without it in the prefix, an agent that runs these scripts itself
# resolves `default`. A secondmate is a full firstmate, so on a fleet pinned to
# a named session it would print NEEDS_HERDR_SERVER while that session is
# plainly up, and then refuse every spawn it tried.
test_the_session_pin_reaches_the_launched_agent() {
  reset
  local home
  home="$TMP_ROOT/home-session"; mkdir -p "$home/data"
  FM_HERDR_SESSION=fleet HERDR_SESSION_NAME=fleet \
    run_spawn "$home" session-pin-p2 --name "session pin" >/dev/null
  assert_grep "HERDR_SESSION='fleet'" "$CALLS" \
    "the launch command does not pin the agent's herdr session; it would probe 'default'"
  pass "session: the pinned session rides the launch prefix into the agent's pane"
}

# --- the meta keeps the task id, and the routing -----------------------------

test_meta_records_the_target_and_its_driver() {
  reset
  local home meta
  home="$TMP_ROOT/home-meta"; mkdir -p "$home/data"
  run_spawn "$home" provisioning-m5 --name provisioning >/dev/null
  meta="$home/state/provisioning-m5.meta"
  assert_present "$meta" "no meta was recorded"
  assert_grep "window=wM:p2" "$meta" "the meta does not carry the opaque herdr target"
  assert_grep "mux=herdr" "$meta" \
    "the meta does not record WHICH driver minted the target; a later steer would guess"
  assert_grep "name=archify-provisioning" "$meta" "the meta does not record the pane name"
  assert_grep "worktree=$WT" "$meta" "the worktree was not resolved through the seam's cwd read"
  pass "meta: records the opaque target, the driver that minted it, and the pane name"
}

# The id belongs in the meta and nowhere else. This is the whole naming argument
# in one assertion.
test_the_task_id_lives_in_the_meta_not_the_name() {
  reset
  local home
  home="$TMP_ROOT/home-id"; mkdir -p "$home/data"
  run_spawn "$home" automerge-z1 --name automerge >/dev/null
  # The id addresses the meta - it IS the meta's filename, which is the whole
  # point: firstmate looks a task up by id, the captain looks a pane up by work.
  assert_present "$home/state/automerge-z1.meta" "the id does not address a meta file"
  assert_no_grep "automerge-z1" "$TMP_ROOT/tabs" "the task id leaked into a tab label"
  assert_grep "archify-automerge" "$TMP_ROOT/tabs" "the tab does not carry the work name"
  pass "naming: the id lives in state/<id>.meta; the tab carries the work"
}

# A pane herdr refuses to name must be REPORTED. The tab label is the gated half
# of naming - an unnamed tab is the defect this work exists to remove - so the
# warning has to actually reach the operator. It previously could not: the check
# read `$?` inside `if ! cmd; then`, where it is the negation's status and
# always 0, so the rc=2 branch was unreachable dead code.
test_a_refused_pane_name_is_reported() {
  reset
  local home out
  home="$TMP_ROOT/home-badname"; mkdir -p "$home/data"
  # HERDR_NO_TAB makes `pane get` return no tab_id, so fm_herdr_label cannot find
  # a tab to rename and returns 2 - herdr refusing the name.
  out=$(HERDR_NO_TAB=1 run_spawn "$home" unnamed-x4 --name unnamed)
  assert_contains "$out" "would not name pane" "a refused pane name was silently swallowed"
  assert_contains "$out" "show unlabelled" "the warning does not say what the captain will see"
  pass "naming: a pane herdr refuses to name is reported, not silently unlabelled"
}

# --- an unreachable herdr STOPS the spawn ------------------------------------

# THE GATE THAT PROVES THE RULE (AGENTS.md, "herdr workspace hygiene"). With no
# herdr server reachable, the spawn must FAIL - non-zero, with an escalation -
# and must not put the crewmate anywhere else. Falling back to a tmux window
# here is the exact failure the captain drew the line against: he would believe
# he is watching the fleet while the work landed somewhere invisible. Knowing
# the fleet is invisible is strictly better than wrongly believing it is
# visible.
test_unreachable_herdr_fails_the_spawn() {
  reset
  local home out rc=0
  home="$TMP_ROOT/home-noserver"; mkdir -p "$home/data"
  out=$(HERDR_SERVER=stopped run_spawn "$home" stranded-w2 --name stranded) || rc=$?
  if [ "$rc" = 0 ]; then fail "the spawn succeeded with no herdr server: $out"; fi
  assert_contains "$out" "no herdr server is reachable" "the failure does not name the reason"
  assert_contains "$out" "captain" "the failure does not say whose decision this is"
  assert_contains "$out" "NOT falling back" "the failure does not say it refused to degrade"
  pass "escalation: an unreachable herdr fails the spawn and asks the captain"
}

# The other half, and the one that would go unnoticed: nothing may be created.
# Not a tmux window, not a herdr tab, not a meta recording a pane that holds
# nothing.
test_unreachable_herdr_creates_nothing() {
  reset
  local home
  home="$TMP_ROOT/home-nothing"; mkdir -p "$home/data"
  HERDR_SERVER=stopped run_spawn "$home" stranded-w3 --name stranded >/dev/null 2>&1
  assert_no_grep "new-window" "$CALLS" "a tmux window was created after herdr was unreachable"
  assert_no_grep "tab create" "$CALLS" "a herdr tab was created against an unreachable server"
  assert_absent "$home/state/stranded-w3.meta" "a meta was recorded for a pane that was never created"
  pass "escalation: an unreachable herdr creates no window, no tab, and no meta"
}

test_a_spawn_lands_in_herdr
test_tab_is_scoped_to_the_project_workspace
test_tab_is_named_for_the_work
test_the_name_is_one_herdr_accepts
test_name_defaults_from_the_task_id_without_its_suffix
test_a_derived_name_keeps_a_real_trailing_word
test_an_off_contract_id_keeps_its_suffix_and_truncation_speaks_up
test_a_leading_digit_survives_in_the_work_half
test_the_session_pin_reaches_the_launched_agent
test_meta_records_the_target_and_its_driver
test_the_task_id_lives_in_the_meta_not_the_name
test_a_refused_pane_name_is_reported
test_unreachable_herdr_fails_the_spawn
test_unreachable_herdr_creates_nothing
