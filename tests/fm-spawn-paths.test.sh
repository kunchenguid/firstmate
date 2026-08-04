#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh path-resolution and session-targeting.
#
# Two field-triggered bugs, both reproduced hermetically with a fake tmux (the
# same technique as fm-tangle-guard.test.sh): the fake reports a controllable
# pane_current_path and a numeric session name, records every invocation, and
# swallows the side-effecting window/send-keys/treehouse ops. A genuine isolated
# git worktree is created up front so the isolation guard's git checks are real.
#
# Bug A - symlinked project dir mis-detected. The captain keeps real clones under
#   ~/code/... and symlinks them into projects/. PROJ_ABS was computed with `pwd`
#   (logical), but tmux reports pane_current_path as the PHYSICAL path, so the
#   post-`treehouse get` wait loop saw physical != logical on its first sample and
#   broke immediately, treating the still-in-project pane as the worktree; the
#   isolation guard then correctly refused and the spawn aborted. The fix resolves
#   PROJ_ABS with `pwd -P`. Modelled here by a pane that reports the physical
#   project path first (still in project) and the worktree path afterwards: the
#   fixed code waits for the real worktree, the old code would abort.
#
# Bug B - numeric tmux session name. `tmux new-window -t "$SES"` with a numeric
#   session name (e.g. "0") is parsed as a WINDOW INDEX, so a second spawn failed
#   with "index 0 in use". The fix targets bare-session ops by the unambiguous
#   session id (#{session_id}) while keeping the session:window NAME form for the
#   window-addressed targets and the recorded meta. Asserted by inspecting which
#   target fm-spawn passed to new-window / list-windows.
#
# shellcheck disable=SC2016  # the literal $7/$9 tokens are tmux session ids (e.g. #{session_id}), not shell variables, and must stay single-quoted
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-paths)

# Build the fake tmux + treehouse fakebin. The fake tmux:
#   - logs every invocation (argv) to FM_FAKE_TMUX_LOG
#   - answers a pane_current_path query from a counter: the first
#     FM_FAKE_PANE_INPROJ_SAMPLES queries return FM_FAKE_PANE_PROJ (pane still in
#     the project), then FM_FAKE_PANE_WT (pane moved into the worktree)
#   - answers '#{session_id}' with FM_FAKE_SESSION_ID and '#S' with the numeric
#     FM_FAKE_SESSION_NAME
#   - swallows the window/session/send-keys ops (exit 0)
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
case "$*" in
  *pane_current_path*)
    c=${FM_FAKE_PANE_COUNTER:?}
    n=$(cat "$c" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s\n' "$n" > "$c"
    if [ "$n" -le "${FM_FAKE_PANE_INPROJ_SAMPLES:-1}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_PROJ:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_WT:-}"
    fi
    exit 0 ;;
  *session_id*) printf '%s\n' "${FM_FAKE_SESSION_ID:?}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf '%s\n' "${FM_FAKE_SESSION_NAME:-0}"; exit 0 ;;
  list-windows|has-session|new-session|new-window|send-keys|kill-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# One real clone + a genuine isolated linked worktree, plus a projects/ symlink to
# the clone (the captain's real-clone-elsewhere layout). Echoes nothing; sets the
# globals the run_spawn helper reads.
setup_fixture() {
  CLONE="$TMP_ROOT/code/clone"
  fm_git_init_commit "$CLONE"
  WT="$TMP_ROOT/wt"
  git -C "$CLONE" worktree add -q --detach "$WT" >/dev/null 2>&1
  HOME_D="$TMP_ROOT/home"
  mkdir -p "$HOME_D/data" "$HOME_D/projects"
  ln -s "$CLONE" "$HOME_D/projects/alpha"
  # Physical paths, exactly as tmux/pwd -P would report them.
  CLONE_PHYS=$(cd "$CLONE" && pwd -P)
  WT_PHYS=$(cd "$WT" && pwd -P)
  FAKEBIN=$(make_fakebin "$TMP_ROOT/fake")
}

# Run a single-task spawn through the fake tmux. TMUX is set (non-empty) so
# fm-spawn takes the in-tmux branch and uses the numeric session name. A raw
# launch command ('true ...') avoids resolving a real harness or installing hooks.
# Defaults to --scout: this fixture exercises path resolution and session
# targeting only, not delivery-contract behavior, and a ship spawn now requires
# an explicit --mode/--yolo - pass extra_flags (a single word-split string) to
# spawn ship instead, e.g. run_spawn id sid inproj '--mode direct-PR --yolo on'.
run_spawn() {
  local id=$1 sid=${2:-'$7'} inproj=${3:-1} extra_flags=${4:---scout}
  mkdir -p "$HOME_D/data/$id"
  printf 'brief\n' > "$HOME_D/data/$id/brief.md"
  : > "$TMP_ROOT/pane-counter-$id"
  # shellcheck disable=SC2086  # extra_flags is a deliberately word-split flag list
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_D" \
    FM_STATE_OVERRIDE="$HOME_D/state" FM_DATA_OVERRIDE="$HOME_D/data" \
    FM_PROJECTS_OVERRIDE="$HOME_D/projects" FM_CONFIG_OVERRIDE="$HOME_D/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$FAKEBIN:$PATH" \
    FM_FAKE_TMUX_LOG="$TMP_ROOT/tmux-log-$id" \
    FM_FAKE_PANE_COUNTER="$TMP_ROOT/pane-counter-$id" \
    FM_FAKE_PANE_INPROJ_SAMPLES="$inproj" \
    FM_FAKE_PANE_PROJ="$CLONE_PHYS" FM_FAKE_PANE_WT="$WT_PHYS" \
    FM_FAKE_SESSION_NAME=0 FM_FAKE_SESSION_ID="$sid" \
    "$SPAWN" "$id" projects/alpha $extra_flags 'true placeholder' 2>&1
}

# Bug A: a symlinked project dir resolves to its physical path, so the wait loop
# stays in step with the (physical) pane path - it waits while the pane is still
# in the project, then locks onto the real worktree once treehouse moves it,
# instead of aborting on the very first sample.
test_symlinked_project_resolves_physical() {
  local id=sym-wait-z1 out status meta
  out=$(run_spawn "$id" '$7' 1); status=$?
  expect_code 0 "$status" "spawn into a symlinked project should succeed"
  assert_contains "$out" "spawned $id" "symlinked-project spawn did not report success"
  assert_not_contains "$out" "did not yield an isolated worktree" \
    "symlinked-project spawn wrongly tripped the isolation guard"
  assert_not_contains "$out" "did not enter a worktree" \
    "symlinked-project spawn timed out waiting for the worktree"
  meta="$HOME_D/state/$id.meta"
  # project= must be the physical clone path, not the projects/alpha symlink path.
  assert_grep "project=$CLONE_PHYS" "$meta" "meta did not record the physical project path"
  assert_no_grep "project=$HOME_D/projects/alpha" "$meta" "meta recorded the symlink path, not the physical path"
  assert_grep "worktree=$WT_PHYS" "$meta" "meta did not record the resolved worktree"
  pass "fm-spawn: a symlinked project dir resolves physically and waits for the real worktree"
}

# Bug B: bare-session targets (new-window, list-windows) use the unambiguous
# session id, never the numeric session name, while the window-addressed targets
# and the recorded meta keep the session:window NAME form.
test_numeric_session_targets_by_id() {
  local id=num-sess-z2 out status log meta
  out=$(run_spawn "$id" '$9' 1); status=$?
  expect_code 0 "$status" "spawn into a numeric session should succeed"
  log="$TMP_ROOT/tmux-log-$id"
  # bin/backends/tmux.sh's fm_backend_tmux_create_task targets the session by
  # NAME with a trailing colon ("0:"), which tmux always parses as "this session,
  # next free window index" - unambiguous even for a numeric name - rather than
  # resolving a separate session id. list-windows (the pre-create duplicate
  # check) targets the same bare name, which is a safe read-only query.
  grep -E '^new-window .*-t 0:( |$)' "$log" >/dev/null \
    || fail "new-window did not target the session by trailing-colon name (-t 0:)"$'\n'"$(grep '^new-window' "$log")"
  grep -E '^list-windows -t 0( |$)' "$log" >/dev/null \
    || fail "list-windows did not target the session name (-t 0)"$'\n'"$(grep '^list-windows' "$log")"
  # send-keys must still address the window by the session:window NAME form, and
  # the recorded meta keeps that same human-addressable form.
  grep -E '^send-keys .*-t 0:fm-'"$id"'( |$)' "$log" >/dev/null \
    || fail "send-keys did not address the window by its session:window name"
  meta="$HOME_D/state/$id.meta"
  assert_grep "window=0:fm-$id" "$meta" "meta did not record the session:window name form"
  pass "fm-spawn: numeric session is targeted by trailing-colon name for window creation, name form kept for the window target"
}

# Bug A, regression: PROJ_NAME (used for the delivery-contract deviation notice)
# must be keyed on the logical projects/<name> registry entry ("alpha"), not the
# physical clone basename ("clone"), so a symlinked project's standing posture is
# still found. Delivery mode/yolo are now an explicit per-task decision passed to
# fm-spawn.sh (AGENTS.md section 7), not read from data/projects.md internally,
# so this exercises the flags surviving a symlinked project rather than a lookup.
test_symlinked_project_preserves_mode_and_yolo() {
  local id=sym-mode-z3 out status meta
  printf -- '- alpha [direct-PR +yolo] - test project (added 2026-06-29)\n' \
    > "$HOME_D/data/projects.md"
  out=$(run_spawn "$id" '$7' 1 '--mode direct-PR --yolo on'); status=$?
  rm -f "$HOME_D/data/projects.md"
  expect_code 0 "$status" "spawn into a symlinked project with an explicit delivery contract should succeed"
  assert_not_contains "$out" "less rigor than the captain's standing posture" \
    "PROJ_NAME missed the symlinked project's registry entry (spurious deviation notice)"
  meta="$HOME_D/state/$id.meta"
  assert_grep "mode=direct-PR" "$meta" "meta did not record the explicit mode"
  assert_grep "yolo=on" "$meta" "meta did not record the explicit yolo"
  pass "fm-spawn: a symlinked project's explicit delivery mode and yolo flag reach meta, and PROJ_NAME still matches its registry entry"
}

# The widened fm-project-mode.sh output ("<mode> <yolo> <tiered> <ci-tests>")
# is now consumed by firstmate at intake, not fm-spawn.sh internally; fm-spawn.sh
# takes explicit --tiered/--ci-tests flags (mirroring --mode/--yolo) and records
# them into meta as tiering=/ci_tests= without corrupting mode/yolo.
test_symlinked_project_preserves_tiered_and_ci_tests() {
  local id=sym-tier-z4 out status meta
  out=$(run_spawn "$id" '$7' 1 '--mode no-mistakes --yolo off --tiered on --ci-tests on'); status=$?
  expect_code 0 "$status" "spawn into a symlinked project with explicit tiered/ci-tests flags should succeed"
  meta="$HOME_D/state/$id.meta"
  assert_grep "mode=no-mistakes" "$meta" "tiered spawn lost its mode"
  assert_grep "yolo=off" "$meta" "tiered spawn's yolo was corrupted"
  assert_grep "tiering=on" "$meta" "meta did not record tiering=on"
  assert_grep "ci_tests=on" "$meta" "meta did not record ci_tests=on"
  pass "fm-spawn: tiered/ci-tests flags are recorded in meta without corrupting mode/yolo"
}

setup_fixture
test_symlinked_project_resolves_physical
test_numeric_session_targets_by_id
test_symlinked_project_preserves_mode_and_yolo
test_symlinked_project_preserves_tiered_and_ci_tests
