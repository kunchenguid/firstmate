#!/usr/bin/env bash
# End-to-end: a spawn must leave the task worktree carrying the project's local,
# gitignored env files, with nothing for git to commit.
#
# This drives the real bin/fm-spawn.sh through its treehouse path against a REAL
# git worktree, so the condition under test is the genuine one: git does not copy
# ignored files into a new worktree, so the worktree starts without .env.local and
# only the spawn path can put it there. tmux and treehouse are the established
# fakes; the worktree, the .gitignore, and the copy are real.
#
# Coverage anchored here (must not regress):
#   - a spawned worktree has the stored env file, and `git status` stays clean
#   - a project with nothing stored still spawns, and the gap is reported
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-project-env)

HOME_DIR=
PROJ_DIR=
WT_DIR=
FAKEBIN_DIR=

# A project whose .gitignore covers .env*.local, plus a real worktree of it -
# the same shape as every live project this runs against.
make_case() {  # <name> <id>
  local name=$1 id=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  HOME_DIR="$case_dir/home"
  PROJ_DIR="$case_dir/project"
  WT_DIR="$case_dir/wt"
  FAKEBIN_DIR=$(fm_fakebin "$case_dir/fake")

  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  fm_git_init_commit "$PROJ_DIR"
  printf '.env*.local\n' > "$PROJ_DIR/.gitignore"
  printf 'PUBLIC_KEY=example\n' > "$PROJ_DIR/.env.example"
  git -C "$PROJ_DIR" add .gitignore .env.example
  git -C "$PROJ_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "ignore local env"
  git -C "$PROJ_DIR" worktree add --quiet -b "wt-$name" "$WT_DIR"

  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  touch "$HOME_DIR/state/.last-watcher-beat"

  cat > "$FAKEBIN_DIR/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$WT_DIR"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  fm_fake_exit0 "$FAKEBIN_DIR" treehouse
}

# Stores a local env file for the project, at the store layout fm-project-env.sh
# owns: <store>/<project name>/<repo-relative path>.
store_env_file() {  # <content>
  local store
  store="$HOME_DIR/config/project-env/$(basename "$PROJ_DIR")"
  mkdir -p "$store"
  printf '%s\n' "$1" > "$store/.env.local"
}

run_spawn() {  # <id>
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_PROJECT_ENV_DIR='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

test_spawned_worktree_carries_the_local_env_file() {
  local id=project-env-present-z1 out status
  make_case env-present "$id"
  store_env_file 'SECRET=from-store'

  # The premise: git did not bring the ignored file along.
  [ ! -e "$WT_DIR/.env.local" ] || fail "the new worktree already had .env.local before the spawn"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  [ -f "$WT_DIR/.env.local" ] || fail "the spawned worktree has no .env.local"
  [ ! -L "$WT_DIR/.env.local" ] || fail "the spawned worktree got a symlink; the mechanism must copy"
  grep -q 'SECRET=from-store' "$WT_DIR/.env.local" \
    || fail "the spawned worktree's .env.local does not carry the stored content"
  [ -z "$(git -C "$WT_DIR" status --porcelain)" ] \
    || fail "the spawned worktree has something to commit: $(git -C "$WT_DIR" status --porcelain)"
  pass "a spawned worktree carries the stored local env file and git still has nothing to commit"
}

test_spawn_survives_a_project_with_nothing_stored() {
  local id=project-env-absent-z2 out status
  make_case env-absent "$id"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "a project with no stored env file must still spawn"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_contains "$out" "no local env file stored" \
    "spawn did not report the missing local env file"
  pass "a project with nothing stored still spawns, and the spawn says what is missing"
}

test_spawned_worktree_carries_the_local_env_file
test_spawn_survives_a_project_with_nothing_stored

echo "# all fm-spawn-project-env tests passed"
