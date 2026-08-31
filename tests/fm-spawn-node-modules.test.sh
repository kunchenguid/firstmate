#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's fresh Beeline worktree dependency sharing.
#
# These tests use a real git worktree and a tiny fabricated dependency tree to
# prove third-party packages stay shared while @beeline packages and binaries
# resolve into the spawned worktree's own source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-node-modules)

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
set -u
last=
for last in "$@"; do :; done
case "${FM_FAIL_NODE_MODULES_LINK:-0}:$last" in
  1:*/.fm-node-modules.*/third-party) exit 42 ;;
esac
exec /bin/ln "$@"
SH
  chmod +x "$fakebin/ln"
  local real_mktemp
  real_mktemp=$(command -v mktemp)
  cat > "$fakebin/mktemp" <<SH
#!/usr/bin/env bash
set -u
last=
for last in "\$@"; do :; done
if [ "\${FM_INTERRUPT_NODE_MODULES_CREATION:-0}" = 1 ] && [[ "\$last" = */.fm-node-modules.XXXXXX ]]; then
  out=\$("$real_mktemp" "\$@") || exit \$?
  kill -TERM "\$PPID" "\$\$"
  printf '%s\n' "\$out"
  exit 0
fi
exec "$real_mktemp" "\$@"
SH
  chmod +x "$fakebin/mktemp"
  cat > "$fakebin/node-race-hook.cjs" <<'JS'
const fs = require('node:fs');
const symlinkSync = fs.symlinkSync;

fs.symlinkSync = function (source, target, type) {
  const raceTarget = process.env.FM_NODE_MODULES_RACE_TARGET;
  if (raceTarget && target === `${raceTarget}/node_modules`) {
    fs.mkdirSync(target, { recursive: true });
    fs.writeFileSync(`${target}/owned.txt`, 'worker install\n');
  }
  const result = symlinkSync.call(this, source, target, type);
  if (process.env.FM_INTERRUPT_NODE_MODULES_PUBLICATION === '1') {
    process.kill(process.ppid, 'SIGTERM');
    process.kill(process.pid, 'SIGTERM');
  }
  if (process.env.FM_KILL_NODE_MODULES_PUBLISHER === '1') {
    process.kill(process.pid, 'SIGKILL');
  }
  return result;
};
JS
  cat > "$fakebin/node-ambient-hook.cjs" <<'JS'
const fs = require('node:fs');
const symlinkSync = fs.symlinkSync;

fs.symlinkSync = function (source, target, type) {
  symlinkSync.call(this, source, target, type);
  throw new Error('ambient preload ran');
};
JS
  local real_node
  real_node=$(command -v node)
  cat > "$fakebin/node" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = - ] && { [ -n "\${FM_NODE_MODULES_RACE_TARGET:-}" ] || [ "\${FM_INTERRUPT_NODE_MODULES_PUBLICATION:-0}" = 1 ] || [ "\${FM_KILL_NODE_MODULES_PUBLISHER:-0}" = 1 ]; }; then
  exec "$real_node" --require="$fakebin/node-race-hook.cjs" "\$@"
fi
exec "$real_node" "\$@"
SH
  chmod +x "$fakebin/node"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir home project worktree fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  fm_git_init_commit "$project"
  mkdir -p "$project/packages/lib" "$project/packages/absolute-lib" \
    "$project/packages/cli" "$project/node_modules/@beeline" \
    "$project/node_modules/.bin" "$project/node_modules/third-party"
  printf 'canonical\n' > "$project/packages/lib/origin.txt"
  printf 'canonical absolute\n' > "$project/packages/absolute-lib/origin.txt"
  printf '#!/usr/bin/env bash\nprintf "primary cli\\n"\n' > "$project/packages/cli/bin.sh"
  chmod +x "$project/packages/cli/bin.sh"
  printf 'shared dependency\n' > "$project/node_modules/third-party/index.js"
  ln -s ../../packages/lib "$project/node_modules/@beeline/lib"
  ln -s "$project/packages/absolute-lib" "$project/node_modules/@beeline/absolute-lib"
  ln -s ../../packages/cli "$project/node_modules/@beeline/cli"
  ln -s ../@beeline/cli/bin.sh "$project/node_modules/.bin/beeline-cli"
  git -C "$project" add packages
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm workspace
  git -C "$project" worktree add --quiet -b "wt-$name" "$worktree"
  printf '%s\n' "$case_dir|$home|$project|$worktree|$fakebin"
}

read_case() {
  IFS='|' read -r _ HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' FM_FAKE_PANE_PATH="$WORKTREE_DIR" \
    FM_FAIL_NODE_MODULES_LINK="${FM_FAIL_NODE_MODULES_LINK:-0}" \
    FM_NODE_MODULES_RACE_TARGET="${FM_NODE_MODULES_RACE_TARGET:-}" \
    FM_INTERRUPT_NODE_MODULES_CREATION="${FM_INTERRUPT_NODE_MODULES_CREATION:-0}" \
    FM_INTERRUPT_NODE_MODULES_PUBLICATION="${FM_INTERRUPT_NODE_MODULES_PUBLICATION:-0}" \
    FM_KILL_NODE_MODULES_PUBLISHER="${FM_KILL_NODE_MODULES_PUBLISHER:-0}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off 2>&1
}

test_spawn_shares_dependencies_and_repoints_workspace_links() {
  local rec id out status node_modules_link third_party_link workspace_link absolute_workspace_link bin_link bin_out
  id=node-modules-share-z1
  rec=$(make_case shared-dependencies "$id")
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed with a Beeline dependency tree"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  [ -d "$WORKTREE_DIR/node_modules" ] || fail "worktree node_modules was not created"
  [ -L "$WORKTREE_DIR/node_modules" ] || fail "worktree node_modules was not atomically published"
  node_modules_link=$(readlink "$WORKTREE_DIR/node_modules")
  case "$node_modules_link" in
    .fm-node-modules.*) ;;
    *) fail "worktree node_modules did not point to its local dependency link farm" ;;
  esac
  [ -d "$WORKTREE_DIR/$node_modules_link" ] || fail "worktree dependency link farm is missing"
  third_party_link=$(readlink "$WORKTREE_DIR/node_modules/third-party")
  [ "$third_party_link" = "$PROJECT_DIR/node_modules/third-party" ] \
    || fail "third-party package did not share the primary dependency tree"

  workspace_link=$(readlink "$WORKTREE_DIR/node_modules/@beeline/lib")
  [ "$workspace_link" = '../../packages/lib' ] \
    || fail "workspace package did not retain its worktree-relative npm link"
  printf 'edited by worker\n' > "$WORKTREE_DIR/packages/lib/worker.txt"
  assert_present "$WORKTREE_DIR/node_modules/@beeline/lib/worker.txt" \
    "workspace package did not resolve to the worker's source"
  assert_absent "$PROJECT_DIR/packages/lib/worker.txt" \
    "workspace package link incorrectly resolved to the primary source"
  absolute_workspace_link=$(readlink "$WORKTREE_DIR/node_modules/@beeline/absolute-lib")
  [ "$absolute_workspace_link" = "$WORKTREE_DIR/packages/absolute-lib" ] \
    || fail "absolute workspace package link did not point at the worker's source"
  printf 'edited absolute worker\n' > "$WORKTREE_DIR/packages/absolute-lib/worker.txt"
  assert_present "$WORKTREE_DIR/node_modules/@beeline/absolute-lib/worker.txt" \
    "absolute workspace package did not resolve to the worker's source"
  assert_absent "$PROJECT_DIR/packages/absolute-lib/worker.txt" \
    "absolute workspace package link incorrectly resolved to the primary source"
  bin_link=$(readlink "$WORKTREE_DIR/node_modules/.bin/beeline-cli")
  [ "$bin_link" = '../@beeline/cli/bin.sh' ] \
    || fail "workspace binary did not retain its worktree-relative npm link"
  printf '#!/usr/bin/env bash\nprintf "worker cli\\n"\n' > "$WORKTREE_DIR/packages/cli/bin.sh"
  chmod +x "$WORKTREE_DIR/packages/cli/bin.sh"
  bin_out=$("$WORKTREE_DIR/node_modules/.bin/beeline-cli")
  [ "$bin_out" = 'worker cli' ] || fail "workspace binary executed primary source"
  pass "fm-spawn shares third-party dependencies while @beeline links and binaries resolve to the worktree"
}

test_spawn_leaves_existing_node_modules_untouched() {
  local rec id out status
  id=node-modules-existing-z2
  rec=$(make_case existing-tree "$id")
  read_case "$rec"
  mkdir -p "$WORKTREE_DIR/node_modules"
  printf 'worker install\n' > "$WORKTREE_DIR/node_modules/owned.txt"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should preserve an existing worktree dependency tree"
  assert_present "$WORKTREE_DIR/node_modules/owned.txt" \
    "spawn replaced an existing worktree node_modules tree"
  [ ! -e "$WORKTREE_DIR/node_modules/third-party" ] \
    || fail "spawn overlaid primary dependencies onto an existing worktree tree"
  pass "fm-spawn leaves an existing worktree node_modules tree untouched"
}

test_spawn_ignores_published_beeline_consumers() {
  local rec id out status
  id=node-modules-consumer-z3
  rec=$(make_case published-consumer "$id")
  read_case "$rec"
  rm "$PROJECT_DIR/node_modules/@beeline/lib" \
    "$PROJECT_DIR/node_modules/@beeline/absolute-lib" \
    "$PROJECT_DIR/node_modules/@beeline/cli"
  mkdir "$PROJECT_DIR/node_modules/@beeline/published"
  printf 'published package\n' > "$PROJECT_DIR/node_modules/@beeline/published/index.js"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should ignore a non-workspace Beeline consumer"
  [ ! -e "$WORKTREE_DIR/node_modules" ] && [ ! -L "$WORKTREE_DIR/node_modules" ] \
    || fail "spawn shared dependencies for a non-workspace Beeline consumer"
  pass "fm-spawn scopes dependency sharing to Beeline workspaces"
}

test_spawn_preserves_tree_created_during_publication() {
  local rec id out status
  id=node-modules-race-z4
  rec=$(make_case publication-race "$id")
  read_case "$rec"

  out=$(FM_NODE_MODULES_RACE_TARGET="$WORKTREE_DIR" run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should preserve a dependency tree created during publication"
  assert_present "$WORKTREE_DIR/node_modules/owned.txt" \
    "spawn replaced a dependency tree created during publication"
  [ ! -e "$WORKTREE_DIR/node_modules/third-party" ] \
    || fail "spawn overlaid dependencies onto a tree created during publication"
  pass "fm-spawn publication does not replace a concurrently created dependency tree"
}

test_spawn_cleans_staging_after_setup_failure() {
  local rec id out status candidate
  id=node-modules-failure-z5
  rec=$(make_case setup-failure "$id")
  read_case "$rec"

  out=$(FM_FAIL_NODE_MODULES_LINK=1 run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should fail when dependency sharing cannot be built"
  [ ! -e "$WORKTREE_DIR/node_modules" ] && [ ! -L "$WORKTREE_DIR/node_modules" ] \
    || fail "failed setup published a partial dependency tree"
  for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ] \
      || fail "failed setup leaked a staging dependency tree"
  done
  pass "fm-spawn cleans dependency staging after setup failure"
}

test_spawn_cancels_after_staging_registration_interrupt() {
  local rec id out status candidate
  id=node-modules-interrupt-z6
  rec=$(make_case setup-interrupt "$id")
  read_case "$rec"

  out=$(FM_INTERRUPT_NODE_MODULES_CREATION=1 run_spawn "$id")
  status=$?
  expect_code 143 "$status" "spawn should preserve cancellation during dependency staging registration"
  assert_not_contains "$out" "spawned $id" "cancelled setup launched a worker"
  [ ! -e "$WORKTREE_DIR/node_modules" ] && [ ! -L "$WORKTREE_DIR/node_modules" ] \
    || fail "cancelled setup published dependencies"
  for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ] \
      || fail "cancelled staging registration leaked a dependency tree"
  done
  pass "fm-spawn cancels cleanly during dependency staging registration"
}

test_spawn_preserves_publication_after_interrupt() {
  local rec id out status publication
  id=node-modules-published-interrupt-z7
  rec=$(make_case published-interrupt "$id")
  read_case "$rec"

  out=$(FM_INTERRUPT_NODE_MODULES_PUBLICATION=1 run_spawn "$id")
  status=$?
  expect_code 143 "$status" "spawn should preserve cancellation after dependency publication"
  assert_not_contains "$out" "spawned $id" "cancelled publication launched a worker"
  [ -L "$WORKTREE_DIR/node_modules" ] || fail "cancelled spawn removed published dependencies"
  publication=$(readlink "$WORKTREE_DIR/node_modules")
  [ -d "$WORKTREE_DIR/$publication" ] || fail "cancelled spawn removed published dependency backing"
  pass "fm-spawn never cleans node_modules after publication"
}

test_spawn_preserves_backing_after_ambiguous_publisher_exit() {
  local rec id out status publication
  id=node-modules-publisher-kill-z8
  rec=$(make_case publisher-kill "$id")
  read_case "$rec"

  out=$(FM_KILL_NODE_MODULES_PUBLISHER=1 run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should fail after an ambiguous publisher exit"
  assert_not_contains "$out" "spawned $id" "failed publisher launched a worker"
  [ -L "$WORKTREE_DIR/node_modules" ] || fail "ambiguous publisher exit removed node_modules"
  publication=$(readlink "$WORKTREE_DIR/node_modules")
  [ -d "$WORKTREE_DIR/$publication" ] || fail "ambiguous publisher exit removed dependency backing"
  pass "fm-spawn retains dependency backing after ambiguous publisher exit"
}

test_spawn_isolates_publisher_from_ambient_node_options() {
  local rec id out status publication
  id=node-modules-node-options-z9
  rec=$(make_case ambient-node-options "$id")
  read_case "$rec"

  out=$(NODE_OPTIONS="--require=$FAKEBIN_DIR/node-ambient-hook.cjs" run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should isolate dependency publication from ambient Node options"
  assert_contains "$out" "spawned $id" "isolated dependency publication did not launch the worker"
  [ -L "$WORKTREE_DIR/node_modules" ] || fail "ambient Node options prevented dependency publication"
  publication=$(readlink "$WORKTREE_DIR/node_modules")
  [ -d "$WORKTREE_DIR/$publication" ] || fail "ambient Node options left dependency publication dangling"
  pass "fm-spawn isolates dependency publication from ambient Node options"
}

test_spawn_shares_dependencies_and_repoints_workspace_links
test_spawn_leaves_existing_node_modules_untouched
test_spawn_ignores_published_beeline_consumers
test_spawn_preserves_tree_created_during_publication
test_spawn_cleans_staging_after_setup_failure
test_spawn_cancels_after_staging_registration_interrupt
test_spawn_preserves_publication_after_interrupt
test_spawn_preserves_backing_after_ambiguous_publisher_exit
test_spawn_isolates_publisher_from_ambient_node_options

echo "# all fm-spawn-node-modules tests passed"
