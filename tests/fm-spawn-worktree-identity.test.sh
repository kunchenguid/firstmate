#!/usr/bin/env bash
# Regression test for fm-spawn.sh's worker-isolation assertion
# (bin/fm-spawn.sh's validate_spawn_worktree, reached from the treehouse-get
# path for tmux/herdr/zellij/cmux, from the Orca worktree-create path, and from
# relaunch).
#
# The assertion used to prove only that the resolved worktree was a real git
# top-level distinct from the project's own checkout. Any OTHER repository
# satisfied that: seen live dispatching a scout, a pane that never left the
# firstmate home recorded worktree=<firstmate home> and passed, because the
# firstmate home is a real git top-level distinct from the project. The worker
# would have been launched against firstmate's own primary checkout - the exact
# tangle the assertion exists to prevent - and the settle loop's two-consecutive
# -reads guard does not help, because a pane that never moved trivially agrees
# with itself.
#
# These cases drive fm-spawn with a fake tmux whose pane_current_path reports a
# real, settled, but foreign worktree, and assert the spawn is refused: the
# firstmate home itself, an unrelated repository's worktree, a worktree whose
# repository identity cannot be read, and a project whose repository identity
# cannot be read. The last case asserts a legitimate worktree of the project
# still spawns, so the assertion cannot pass by refusing everything.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-identity)
GIT_BIN=$(command -v git) || fail "git not found"
fm_git_identity

# A fake tmux whose pane_current_path always answers FM_FAKE_PANE_PATH, i.e. a
# pane that is already settled wherever the case put it.
make_identity_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# Shadow git with a pass-through wrapper that breaks ONLY the repository-identity
# query, and only for the directory named by FM_FAKE_GIT_BREAK_DIR:
# FM_FAKE_GIT_COMMON_DIR_MODE "fail" exits non-zero, "empty" prints nothing, and
# "garbage" prints a path that does not exist. Every other invocation reaches the
# real git untouched, so the resolved worktree stays a genuine, settled worktree
# and only its identity is unreadable - the inconclusive case, not a wrong-repo
# case wearing its clothes.
install_git_shim() {
  local fakebin=$1
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
set -u
GIT_REAL=$(printf '%q' "$GIT_BIN")
break_dir=\${FM_FAKE_GIT_BREAK_DIR:-}
mode=\${FM_FAKE_GIT_COMMON_DIR_MODE:-}
if [ -n "\$break_dir" ] && [ -n "\$mode" ] && [ "\${1:-}" = -C ] && [ "\${3:-}" = rev-parse ]; then
  asked=\$(cd "\${2:-.}" 2>/dev/null && pwd -P) || asked=
  wanted=\$(cd "\$break_dir" 2>/dev/null && pwd -P) || wanted=
  if [ -n "\$asked" ] && [ "\$asked" = "\$wanted" ]; then
    for arg in "\$@"; do
      if [ "\$arg" = --git-common-dir ]; then
        case "\$mode" in
          fail) exit 1 ;;
          empty) printf '\n'; exit 0 ;;
          garbage) printf '%s\n' "\${FM_FAKE_GIT_COMMON_DIR_GARBAGE:-/nonexistent/fm-test-missing/.git}"; exit 0 ;;
        esac
      fi
    done
  fi
fi
exec "\$GIT_REAL" "\$@"
SH
  chmod +x "$fakebin/git"
}

# make_identity_case <name> <id>: a home, a project with a real worktree, an
# unrelated repository with its own real worktree, and a fake tmux. Sets the
# CASE_* variables the runner reads.
make_identity_case() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/$name"
  CASE_HOME="$CASE_DIR/home"
  CASE_PROJ="$CASE_DIR/project"
  CASE_WT="$CASE_DIR/wt"
  CASE_OTHER="$CASE_DIR/other-project"
  CASE_OTHER_WT="$CASE_DIR/other-wt"
  CASE_FAKEBIN=$(make_identity_fakebin "$CASE_DIR/fake")
  mkdir -p "$CASE_HOME/data" "$CASE_HOME/projects" "$CASE_HOME/state" "$CASE_HOME/config"
  printf 'codex\n' > "$CASE_HOME/config/crew-harness"
  fm_git_worktree "$CASE_PROJ" "$CASE_WT" "wt-$name"
  fm_git_worktree "$CASE_OTHER" "$CASE_OTHER_WT" "other-wt-$name"
  mkdir -p "$CASE_HOME/data/$id"
  printf 'brief for %s\n' "$id" > "$CASE_HOME/data/$id/brief.md"
  touch "$CASE_HOME/state/.last-watcher-beat"
}

# run_identity_spawn <id> <pane-path>: drive one spawn whose pane reports
# <pane-path>, echoing combined output. FM_FAKE_GIT_COMMON_DIR_MODE (and its
# garbage value) pass through for the unreadable-identity cases.
run_identity_spawn() {
  local id=$1 pane=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$pane" \
    FM_FAKE_GIT_BREAK_DIR="${FM_FAKE_GIT_BREAK_DIR:-}" \
    FM_FAKE_GIT_COMMON_DIR_MODE="${FM_FAKE_GIT_COMMON_DIR_MODE:-}" \
    PATH="$CASE_FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$CASE_PROJ" --mode no-mistakes --yolo off 2>&1
}

# Orca reaches the same assertion from its own worktree-create result instead of
# a pane cwd, so the identity check has to hold on that call site too. This fake
# answers the create call with FM_FAKE_ORCA_WT_PATH, whatever directory the case
# points it at.
install_orca_fake() {
  local fakebin=$1
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status "*|"status")
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' ;;
  "repo show"|"repo add")
    printf '{"ok":true,"result":{"repo":{"id":"fm-test-repo"}}}\n' ;;
  "worktree create")
    printf '{"ok":true,"result":{"worktree":{"id":"fm-test-wt","path":"%s"}}}\n' "${FM_FAKE_ORCA_WT_PATH:?}" ;;
  "terminal create")
    printf '{"ok":true,"result":{"terminal":{"handle":"fm-test-terminal"}}}\n' ;;
  *)
    printf '{"ok":true,"result":{}}\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/orca"
}

run_orca_identity_spawn() {  # <id> <orca-worktree-path>
  local id=$1 wt=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_ORCA_WT_PATH="$wt" \
    PATH="$CASE_FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$CASE_PROJ" --mode no-mistakes --yolo off --backend orca 2>&1
}

# The live incident: the pane never left the firstmate home, which is itself a
# real git checkout, so every path-shape check agreed and the spawn recorded
# firstmate's own home as the task worktree.
test_firstmate_home_is_refused() {
  local id out status
  id=identity-firstmate-home-i1
  make_identity_case identity-firstmate-home "$id"
  # A real firstmate checkout: committed tracked material, an origin, and its
  # private state gitignored the way a live home has it. Nothing downstream of
  # the assertion can then refuse this case for an unrelated reason, so what the
  # assertion itself accepts or refuses is what the case measures.
  fm_git_init_commit "$CASE_HOME"
  printf '%s\n' 'data/' 'state/' 'config/' 'projects/' > "$CASE_HOME/.gitignore"
  git -C "$CASE_HOME" add .gitignore
  git -C "$CASE_HOME" commit -qm gitignore
  fm_git_add_origin "$CASE_HOME" "$CASE_HOME.origin.git"

  out=$(run_identity_spawn "$id" "$CASE_HOME")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted the firstmate home as the task worktree"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "belongs to a different repository" \
    "refusal did not name the repository mismatch"
  assert_not_contains "$out" "spawned $id" "spawn launched a worker into the firstmate home"
  assert_absent "$CASE_HOME/state/$id.meta" \
    "spawn recorded task metadata after refusing the firstmate home"
  pass "a pane sitting in the firstmate home is refused, not recorded as the task worktree"
}

# The general case: a real, settled worktree that belongs to some other
# repository entirely.
test_unrelated_repository_worktree_is_refused() {
  local id out status
  id=identity-other-repo-i2
  make_identity_case identity-other-repo "$id"

  out=$(run_identity_spawn "$id" "$CASE_OTHER_WT")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a worktree of an unrelated repository"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "belongs to a different repository" \
    "refusal did not name the repository mismatch"
  assert_not_contains "$out" "spawned $id" \
    "spawn launched a worker into an unrelated repository's worktree"
  assert_absent "$CASE_HOME/state/$id.meta" \
    "spawn recorded task metadata after refusing an unrelated repository's worktree"
  pass "a real worktree of an unrelated repository is refused"
}

# Inconclusive is not a pass: when the repository identity of the resolved
# worktree cannot be read, the launch must be refused rather than assumed good.
test_unreadable_repository_identity_is_refused() {
  local id out status mode
  for mode in fail empty garbage; do
    id="identity-unreadable-$mode-i3"
    make_identity_case "identity-unreadable-$mode" "$id"
    install_git_shim "$CASE_FAKEBIN"

    out=$(FM_FAKE_GIT_BREAK_DIR="$CASE_WT" FM_FAKE_GIT_COMMON_DIR_MODE="$mode" \
      run_identity_spawn "$id" "$CASE_WT")
    status=$?
    [ "$status" -ne 0 ] || fail "spawn proceeded with an unreadable repository identity (mode=$mode)"$'\n'"--- output ---"$'\n'"$out"
    assert_contains "$out" "could not be established" \
      "refusal did not name the unestablished repository identity (mode=$mode)"
    assert_not_contains "$out" "spawned $id" \
      "spawn launched a worker despite an unreadable repository identity (mode=$mode)"
    assert_absent "$CASE_HOME/state/$id.meta" \
      "spawn recorded task metadata after an unreadable repository identity (mode=$mode)"
  done
  pass "an unreadable worktree repository identity refuses the launch instead of passing"
}

# The same fail-closed rule on the project side: with no readable project
# repository there is nothing to prove the worktree belongs to.
test_project_without_repository_identity_is_refused() {
  local id out status
  id=identity-no-project-repo-i4
  make_identity_case identity-no-project-repo "$id"
  rm -rf "$CASE_PROJ/.git"

  out=$(run_identity_spawn "$id" "$CASE_OTHER_WT")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn proceeded with no readable project repository"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "repository identity of project" \
    "refusal did not name the unestablished project repository identity"
  assert_not_contains "$out" "spawned $id" \
    "spawn launched a worker with no readable project repository"
  assert_absent "$CASE_HOME/state/$id.meta" \
    "spawn recorded task metadata with no readable project repository"
  pass "a project whose repository identity cannot be established refuses the launch"
}

# The assertion must not pass by refusing everything: a genuine worktree of the
# project's own repository still spawns and is still recorded.
test_project_worktree_still_spawns() {
  local id out status
  id=identity-legit-worktree-i5
  make_identity_case identity-legit-worktree "$id"

  out=$(run_identity_spawn "$id" "$CASE_WT")
  status=$?
  expect_code 0 "$status" "a legitimate worktree of the project should still spawn"
  assert_contains "$out" "spawned $id" "spawn did not report success for a legitimate worktree"
  assert_grep "worktree=$CASE_WT" "$CASE_HOME/state/$id.meta" \
    "meta did not record the project's own worktree"
  pass "a legitimate worktree of the project's repository still spawns"
}

# Orca never runs treehouse get: it hands fm-spawn its own worktree path, so its
# call site needs the same proof, and must still accept a real worktree of the
# project's repository.
test_orca_worktree_of_another_repository_is_refused() {
  local id out status
  id=identity-orca-other-repo-i6
  make_identity_case identity-orca-other-repo "$id"
  install_orca_fake "$CASE_FAKEBIN"

  out=$(run_orca_identity_spawn "$id" "$CASE_OTHER_WT")
  status=$?
  [ "$status" -ne 0 ] || fail "orca spawn accepted a worktree of an unrelated repository"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "belongs to a different repository" \
    "orca refusal did not name the repository mismatch"
  assert_not_contains "$out" "spawned $id" \
    "orca spawn launched a worker into an unrelated repository's worktree"
  assert_absent "$CASE_HOME/state/$id.meta" \
    "orca spawn recorded task metadata after refusing an unrelated repository's worktree"
  pass "an Orca worktree belonging to another repository is refused"
}

test_orca_project_worktree_still_spawns() {
  local id out status
  id=identity-orca-legit-i7
  make_identity_case identity-orca-legit "$id"
  install_orca_fake "$CASE_FAKEBIN"

  out=$(run_orca_identity_spawn "$id" "$CASE_WT")
  status=$?
  expect_code 0 "$status" "a legitimate Orca worktree of the project should still spawn"
  assert_contains "$out" "spawned $id" "orca spawn did not report success for a legitimate worktree"
  assert_grep "worktree=$CASE_WT" "$CASE_HOME/state/$id.meta" \
    "orca meta did not record the project's own worktree"
  pass "an Orca worktree of the project's own repository still spawns"
}

test_firstmate_home_is_refused
test_unrelated_repository_worktree_is_refused
test_unreadable_repository_identity_is_refused
test_project_without_repository_identity_is_refused
test_project_worktree_still_spawns
if command -v node >/dev/null 2>&1; then
  test_orca_worktree_of_another_repository_is_refused
  test_orca_project_worktree_still_spawns
else
  echo "# orca cases not run: node is required by the Orca adapter's JSON helpers"
fi

echo "# all fm-spawn-worktree-identity tests passed"
