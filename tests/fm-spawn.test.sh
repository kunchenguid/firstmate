#!/usr/bin/env bash
# Wave 3 engine-room wiring: fm-spawn.sh must provision firstmate's
# worker-facing skills into every fresh ship/scout worktree as
# `.agents/skills`, so briefs can reference playbooks and skills just-in-time
# without dumping them into the supervisor prompt.
#
# Drives the real fm-spawn.sh fresh-spawn path with a fake tmux backend (an
# already-settled pane, mirroring tests/fm-spawn-worktree-settle.test.sh) and
# asserts: the link exists and resolves to firstmate's skill library, it stays
# out of git's view so teardown's uncommitted-work check stays green, and a
# project-owned `.agents/skills` path is never replaced.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-skills)

# make_skills_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query always reports FM_FAKE_PANE_PATH (an already-settled pane), plus an
# exit-0 treehouse stub. Same covered command surface as the settle suite.
make_skills_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"
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

# make_skills_case <name> <id> [project-skills] builds a fixture home, a
# primary project with a real worktree, and a minimal ship brief. With
# project-skills=1 the origin repo carries a committed, project-owned
# `.agents/skills/custom.md` before the worktree is added. Echoes a
# `|`-separated record the runners below unpack.
make_skills_case() {
  local name=$1 id=$2 owned=${3:-0} case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_skills_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  if [ "$owned" = 1 ]; then
    fm_git_init_commit "$proj"
    mkdir -p "$proj/.agents/skills"
    printf '# project-owned skill\n' > "$proj/.agents/skills/custom.md"
    git -C "$proj" add .agents/skills/custom.md
    git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "project-owned skills"
    fm_git_add_origin "$proj" "$proj.origin.git"
    git -C "$proj" worktree add --quiet -b "wt-$name" "$wt"
  else
    fm_git_worktree "$proj" "$wt" "wt-$name"
  fi
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise worker skill provisioning for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_skills_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_skills_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode local-only --yolo off 2>&1
}

# A fresh spawn must link the worktree's `.agents/skills` at firstmate's
# skill library, readable through the link (Wave 1 content included).
test_skills_symlinked_into_fresh_worktree() {
  local rec id out status target
  id=skills-provisioned-z1
  rec=$(make_skills_case skills-fresh "$id")
  read_skills_record "$rec"

  out=$(run_skills_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ -L "$WT_DIR/.agents/skills" ] || fail "task worktree has no .agents/skills symlink after spawn"
  target=$(readlink "$WT_DIR/.agents/skills")
  [ "$target" = "$ROOT/.agents/skills" ] || fail "skills link points at '$target', not the skill library"
  [ -r "$WT_DIR/.agents/skills/how/SKILL.md" ] || fail "Wave 1 skill library is not readable through the provisioned link"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the isolated worktree"
  pass "a fresh spawn provisions .agents/skills as a readable link into the skill library"
}

# The provisioned link must stay out of git's view, or every teardown would
# read it as uncommitted work and refuse to clean up.
test_skills_link_hidden_from_git_status() {
  local rec id out status porcelain
  id=skills-hidden-z2
  rec=$(make_skills_case skills-hidden "$id")
  read_skills_record "$rec"

  out=$(run_skills_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  porcelain=$(git -C "$WT_DIR" status --porcelain) || fail "could not read worktree status"
  [ -z "$porcelain" ] || fail "provisioned skills link leaks into git status: $porcelain"
  pass "the provisioned skills link stays out of git status"
}

# A project that owns `.agents/skills` keeps it: provisioning never replaces
# an existing path, tracked content included.
test_project_owned_skills_dir_left_untouched() {
  local rec id out status
  id=skills-owned-z3
  rec=$(make_skills_case skills-owned "$id" 1)
  read_skills_record "$rec"

  out=$(run_skills_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ ! -L "$WT_DIR/.agents/skills" ] || fail "provisioning replaced the project-owned .agents/skills with a symlink"
  [ -f "$WT_DIR/.agents/skills/custom.md" ] || fail "project-owned skill content is missing after spawn"
  pass "a project-owned .agents/skills directory is left untouched"
}

test_skills_symlinked_into_fresh_worktree
test_skills_link_hidden_from_git_status
test_project_owned_skills_dir_left_untouched

echo "# all fm-spawn tests passed"
