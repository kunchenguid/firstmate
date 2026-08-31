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
  cat > "$fakebin/mkdir" <<'SH'
#!/usr/bin/env bash
set -u
last=
for last in "$@"; do :; done
base=${last##*/}
if [[ "$base" = .fm-node-modules.* ]]; then
  if [ "${FM_INTERRUPT_NODE_MODULES_CREATION:-0}" = 1 ]; then
    /bin/mkdir "$@" || exit $?
    kill -TERM "$PPID" "$$"
    exit 0
  fi
  if [ "${FM_KILL_NODE_MODULES_CREATOR:-0}" = 1 ]; then
    /bin/mkdir "$@" || exit $?
    kill -HUP "$$"
    exit 0
  fi
  if [ "${FM_FAIL_NODE_MODULES_CREATOR_AFTER_CREATE:-0}" = 1 ]; then
    /bin/mkdir "$@" || exit $?
    exit 1
  fi
fi
exec /bin/mkdir "$@"
SH
  chmod +x "$fakebin/mkdir"
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
set -u
last=
for last in "$@"; do :; done
base=${last##*/}
if [ "${FM_INTERRUPT_NODE_MODULES_CLEANUP:-0}" = 1 ] && [[ "$base" = .fm-node-modules.* ]]; then
  kill -TERM "$PPID" "$$"
fi
exec /bin/rm "$@"
SH
  chmod +x "$fakebin/rm"
  cat > "$fakebin/node-race-hook.cjs" <<'JS'
const fs = require('node:fs');
const symlinkSync = fs.symlinkSync;

fs.symlinkSync = function (source, target, type) {
  const raceTarget = process.env.FM_NODE_MODULES_RACE_TARGET;
  if (raceTarget && target === `${raceTarget}/node_modules`) {
    const primaryTarget = process.env.FM_NODE_MODULES_RACE_PRIMARY_TARGET;
    if (primaryTarget) {
      symlinkSync(primaryTarget, target, 'dir');
    } else {
      fs.mkdirSync(`${target}/@beeline`, { recursive: true });
      fs.writeFileSync(`${target}/owned.txt`, 'worker install\n');
      symlinkSync('../../packages/lib', `${target}/@beeline/lib`, 'dir');
      symlinkSync(`${raceTarget}/packages/absolute-lib`, `${target}/@beeline/absolute-lib`, 'dir');
      symlinkSync('../../packages/cli', `${target}/@beeline/cli`, 'dir');
    }
  }
  const result = symlinkSync.call(this, source, target, type);
  if (process.env.FM_INTERRUPT_NODE_MODULES_PUBLICATION === '1') {
    process.kill(process.ppid, 'SIGTERM');
    process.kill(process.pid, 'SIGTERM');
  }
  if (process.env.FM_HUP_NODE_MODULES_PUBLICATION === '1') {
    process.kill(process.ppid, 'SIGHUP');
    process.kill(process.pid, 'SIGHUP');
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
  cat > "$fakebin/node-invalid-publication-hook.cjs" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const symlinkSync = fs.symlinkSync;

fs.symlinkSync = function (source, target, type) {
  const result = symlinkSync.call(this, source, target, type);
  const backing = path.resolve(path.dirname(target), source);
  if (process.env.FM_INVALID_NODE_MODULES_PUBLICATION === 'workspace') {
    fs.unlinkSync(`${backing}/@beeline/lib`);
    symlinkSync.call(
      this,
      process.env.FM_NODE_MODULES_PRIMARY_WORKSPACE,
      `${backing}/@beeline/lib`,
      'dir'
    );
  }
  if (process.env.FM_INVALID_NODE_MODULES_PUBLICATION === 'backing') {
    fs.rmSync(backing, { recursive: true, force: true });
  }
  return result;
};
JS
  local real_node
  real_node=$(command -v node)
  cat > "$fakebin/node" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = - ] && [ "\${FM_FAIL_NODE_PUBLISHER_EXEC:-0}" = 1 ]; then
  exit 127
fi
if [ "\${1:-}" = - ] && [ -n "\${FM_NODE_PUBLISHER_EARLY_STATUS:-}" ]; then
  exit "\$FM_NODE_PUBLISHER_EARLY_STATUS"
fi
if [ "\${1:-}" = - ] && [ "\${FM_INJECT_NODE_PUBLISHER_HOOK:-0}" = 1 ]; then
  exec "$real_node" --require="$fakebin/node-ambient-hook.cjs" "\$@"
fi
if [ "\${1:-}" = - ] && [ -n "\${FM_INVALID_NODE_MODULES_PUBLICATION:-}" ]; then
  exec "$real_node" --require="$fakebin/node-invalid-publication-hook.cjs" "\$@"
fi
if [ "\${1:-}" = - ] && { [ -n "\${FM_NODE_MODULES_RACE_TARGET:-}" ] || [ "\${FM_INTERRUPT_NODE_MODULES_PUBLICATION:-0}" = 1 ] || [ "\${FM_HUP_NODE_MODULES_PUBLICATION:-0}" = 1 ] || [ "\${FM_KILL_NODE_MODULES_PUBLISHER:-0}" = 1 ]; }; then
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
    FM_NODE_MODULES_RACE_PRIMARY_TARGET="${FM_NODE_MODULES_RACE_PRIMARY_TARGET:-}" \
    FM_INTERRUPT_NODE_MODULES_CREATION="${FM_INTERRUPT_NODE_MODULES_CREATION:-0}" \
    FM_KILL_NODE_MODULES_CREATOR="${FM_KILL_NODE_MODULES_CREATOR:-0}" \
    FM_FAIL_NODE_MODULES_CREATOR_AFTER_CREATE="${FM_FAIL_NODE_MODULES_CREATOR_AFTER_CREATE:-0}" \
    FM_INTERRUPT_NODE_MODULES_CLEANUP="${FM_INTERRUPT_NODE_MODULES_CLEANUP:-0}" \
    FM_INTERRUPT_NODE_MODULES_PUBLICATION="${FM_INTERRUPT_NODE_MODULES_PUBLICATION:-0}" \
    FM_HUP_NODE_MODULES_PUBLICATION="${FM_HUP_NODE_MODULES_PUBLICATION:-0}" \
    FM_KILL_NODE_MODULES_PUBLISHER="${FM_KILL_NODE_MODULES_PUBLISHER:-0}" \
    FM_FAIL_NODE_PUBLISHER_EXEC="${FM_FAIL_NODE_PUBLISHER_EXEC:-0}" \
    FM_NODE_PUBLISHER_EARLY_STATUS="${FM_NODE_PUBLISHER_EARLY_STATUS:-}" \
    FM_INJECT_NODE_PUBLISHER_HOOK="${FM_INJECT_NODE_PUBLISHER_HOOK:-0}" \
    FM_INVALID_NODE_MODULES_PUBLICATION="${FM_INVALID_NODE_MODULES_PUBLICATION:-}" \
    FM_NODE_MODULES_PRIMARY_WORKSPACE="${FM_NODE_MODULES_PRIMARY_WORKSPACE:-}" \
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
  mkdir -p "$WORKTREE_DIR/node_modules/@beeline"
  printf 'worker install\n' > "$WORKTREE_DIR/node_modules/owned.txt"
  ln -s ../../packages/lib "$WORKTREE_DIR/node_modules/@beeline/lib"
  ln -s "$WORKTREE_DIR/packages/absolute-lib" "$WORKTREE_DIR/node_modules/@beeline/absolute-lib"
  ln -s ../../packages/cli "$WORKTREE_DIR/node_modules/@beeline/cli"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should preserve an existing worktree dependency tree"
  assert_present "$WORKTREE_DIR/node_modules/owned.txt" \
    "spawn replaced an existing worktree node_modules tree"
  [ ! -e "$WORKTREE_DIR/node_modules/third-party" ] \
    || fail "spawn overlaid primary dependencies onto an existing worktree tree"
  pass "fm-spawn leaves an existing worktree node_modules tree untouched"
}

test_spawn_rejects_existing_primary_dependency_link() {
  local rec id out status
  id=node-modules-existing-primary-z2b
  rec=$(make_case existing-primary-link "$id")
  read_case "$rec"
  ln -s "$PROJECT_DIR/node_modules" "$WORKTREE_DIR/node_modules"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted an existing dependency link to primary source"
  assert_not_contains "$out" "spawned $id" "primary dependency link launched a worker"
  [ "$(readlink "$WORKTREE_DIR/node_modules")" = "$PROJECT_DIR/node_modules" ] \
    || fail "spawn mutated the existing primary dependency link"
  pass "fm-spawn refuses existing dependency links whose workspaces resolve to primary source"
}

test_spawn_rejects_target_only_primary_workspace_link() {
  local rec id out status
  id=node-modules-target-only-primary-z2c
  rec=$(make_case target-only-primary "$id")
  read_case "$rec"
  mkdir -p "$WORKTREE_DIR/node_modules/@beeline"
  ln -s ../../packages/lib "$WORKTREE_DIR/node_modules/@beeline/lib"
  ln -s "$WORKTREE_DIR/packages/absolute-lib" "$WORKTREE_DIR/node_modules/@beeline/absolute-lib"
  ln -s ../../packages/cli "$WORKTREE_DIR/node_modules/@beeline/cli"
  ln -s "$PROJECT_DIR/packages/lib" "$WORKTREE_DIR/node_modules/@beeline/legacy"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a target-only workspace link to primary source"
  assert_not_contains "$out" "spawned $id" "target-only primary workspace link launched a worker"
  [ "$(readlink "$WORKTREE_DIR/node_modules/@beeline/legacy")" = "$PROJECT_DIR/packages/lib" ] \
    || fail "spawn mutated the target-only primary workspace link"
  pass "fm-spawn refuses target-only workspace links to primary source"
}

test_spawn_rejects_dangling_existing_workspace_link() {
  local rec id out status
  id=node-modules-dangling-existing-z2d
  rec=$(make_case dangling-existing "$id")
  read_case "$rec"
  mkdir -p "$WORKTREE_DIR/node_modules/@beeline"
  ln -s ../../packages/lib "$WORKTREE_DIR/node_modules/@beeline/lib"
  ln -s "$WORKTREE_DIR/packages/absolute-lib" "$WORKTREE_DIR/node_modules/@beeline/absolute-lib"
  ln -s ../../packages/cli "$WORKTREE_DIR/node_modules/@beeline/cli"
  ln -s ../../packages/missing "$WORKTREE_DIR/node_modules/@beeline/legacy"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a dangling existing workspace link"
  assert_not_contains "$out" "spawned $id" "dangling existing workspace link launched a worker"
  [ "$(readlink "$WORKTREE_DIR/node_modules/@beeline/legacy")" = '../../packages/missing' ] \
    || fail "spawn mutated the dangling existing workspace link"
  pass "fm-spawn refuses dangling existing workspace links without mutation"
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
  local rec id out status candidate
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
  for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ] \
      || fail "publication contention leaked unused dependency staging"
  done
  pass "fm-spawn publication does not replace a concurrently created dependency tree"
}

test_spawn_rejects_primary_dependency_link_created_during_publication() {
  local rec id out status candidate
  id=node-modules-race-primary-z4b
  rec=$(make_case publication-primary-race "$id")
  read_case "$rec"

  out=$(FM_NODE_MODULES_RACE_TARGET="$WORKTREE_DIR" \
    FM_NODE_MODULES_RACE_PRIMARY_TARGET="$PROJECT_DIR/node_modules" run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a contended dependency link to primary source"
  assert_not_contains "$out" "spawned $id" "contended primary dependency link launched a worker"
  [ "$(readlink "$WORKTREE_DIR/node_modules")" = "$PROJECT_DIR/node_modules" ] \
    || fail "spawn mutated the contended primary dependency link"
  for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ] \
      || fail "invalid publication contention leaked unused dependency staging"
  done
  pass "fm-spawn refuses contended dependency links whose workspaces resolve to primary source"
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

test_spawn_validates_staging_before_publication() {
  local rec id out status candidate
  id=node-modules-invalid-staging-z5b
  rec=$(make_case invalid-staging "$id")
  read_case "$rec"
  /bin/rm -rf "$WORKTREE_DIR/packages/absolute-lib"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn published staging with a missing worktree workspace"
  assert_not_contains "$out" "spawned $id" "invalid dependency staging launched a worker"
  [ ! -e "$WORKTREE_DIR/node_modules" ] && [ ! -L "$WORKTREE_DIR/node_modules" ] \
    || fail "invalid dependency staging published node_modules"
  for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ] \
      || fail "invalid dependency staging survived validation failure"
  done
  pass "fm-spawn validates workspace links before dependency publication"
}

test_spawn_rejects_dangling_staged_workspace_link() {
  local rec id out status candidate
  id=node-modules-dangling-staging-z5c
  rec=$(make_case dangling-staging "$id")
  read_case "$rec"
  ln -s ../../packages/missing "$PROJECT_DIR/node_modules/@beeline/legacy"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn published a dangling staged workspace link"
  assert_not_contains "$out" "spawned $id" "dangling staged workspace link launched a worker"
  [ ! -e "$WORKTREE_DIR/node_modules" ] && [ ! -L "$WORKTREE_DIR/node_modules" ] \
    || fail "dangling staged workspace link published node_modules"
  for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ] \
      || fail "dangling staged workspace link leaked dependency staging"
  done
  pass "fm-spawn rejects dangling workspace links before publication"
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

test_spawn_cleans_staging_after_creator_status_failure() {
  local rec id out status candidate
  id=node-modules-creator-status-z6b
  rec=$(make_case creator-status "$id")
  read_case "$rec"

  out=$(FM_FAIL_NODE_MODULES_CREATOR_AFTER_CREATE=1 run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted failed dependency staging creation"
  assert_not_contains "$out" "spawned $id" "failed staging creation launched a worker"
  [ ! -e "$WORKTREE_DIR/node_modules" ] && [ ! -L "$WORKTREE_DIR/node_modules" ] \
    || fail "failed staging creation published node_modules"
  for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ] \
      || fail "failed staging creation leaked its registered directory"
  done
  pass "fm-spawn cleans registered staging after creator status failure"
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

test_spawn_preserves_publication_after_hup() {
  local rec id out status publication
  id=node-modules-published-hup-z7b
  rec=$(make_case published-hup "$id")
  read_case "$rec"

  out=$(FM_HUP_NODE_MODULES_PUBLICATION=1 run_spawn "$id")
  status=$?
  expect_code 129 "$status" "spawn should preserve cancellation after publication HUP"
  assert_not_contains "$out" "spawned $id" "HUP-cancelled publication launched a worker"
  [ -L "$WORKTREE_DIR/node_modules" ] || fail "publication HUP removed node_modules"
  publication=$(readlink "$WORKTREE_DIR/node_modules")
  [ -d "$WORKTREE_DIR/$publication" ] || fail "publication HUP removed dependency backing"
  pass "fm-spawn defers HUP until dependency publication state is settled"
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

test_spawn_retains_staging_after_ambiguous_publisher_exec_failure() {
  local rec id out status candidate retained count
  id=node-modules-exec-failure-z10
  rec=$(make_case publisher-exec-failure "$id")
  read_case "$rec"

  out=$(FM_FAIL_NODE_PUBLISHER_EXEC=1 run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should fail when the dependency publisher cannot execute"
  assert_not_contains "$out" "spawned $id" "publisher execution failure launched a worker"
  [ ! -e "$WORKTREE_DIR/node_modules" ] && [ ! -L "$WORKTREE_DIR/node_modules" ] \
    || fail "publisher execution failure created node_modules"
  retained=
  count=0
  for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    retained=$candidate
    count=$((count + 1))
  done
  [ "$count" -eq 1 ] || fail "ambiguous publisher execution failure did not retain exactly one backing tree"
  assert_present "$retained/third-party/index.js" \
    "ambiguous publisher execution failure retained an incomplete backing tree"
  pass "fm-spawn retains complete staging after ambiguous publisher execution failure"
}

test_spawn_cleans_staging_after_creator_termination() {
  local rec id out status candidate
  id=node-modules-creator-kill-z11
  rec=$(make_case creator-kill "$id")
  read_case "$rec"

  out=$(FM_KILL_NODE_MODULES_CREATOR=1 run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should fail after dependency staging creation terminates"
  assert_not_contains "$out" "spawned $id" "terminated staging creation launched a worker"
  [ ! -e "$WORKTREE_DIR/node_modules" ] && [ ! -L "$WORKTREE_DIR/node_modules" ] \
    || fail "terminated staging creation published dependencies"
  for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ] \
      || fail "terminated staging creation leaked a dependency tree"
  done
  pass "fm-spawn cleans registered staging after creator termination"
}

test_spawn_cleans_known_unpublished_staging_during_interrupt() {
  local rec id out status candidate
  id=node-modules-cleanup-interrupt-z12
  rec=$(make_case cleanup-interrupt "$id")
  read_case "$rec"

  out=$(FM_FAIL_NODE_MODULES_LINK=1 FM_INTERRUPT_NODE_MODULES_CLEANUP=1 run_spawn "$id")
  status=$?
  expect_code 143 "$status" "spawn should preserve cancellation during dependency staging cleanup"
  assert_not_contains "$out" "spawned $id" "cancelled dependency cleanup launched a worker"
  [ ! -e "$WORKTREE_DIR/node_modules" ] && [ ! -L "$WORKTREE_DIR/node_modules" ] \
    || fail "cancelled pre-publication cleanup created node_modules"
  for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ] \
      || fail "cancelled cleanup leaked known-unpublished dependency staging"
  done
  pass "fm-spawn completes staging cleanup before honoring cancellation"
}

test_spawn_retains_backing_after_wrapper_postpublication_failure() {
  local rec id out status publication
  id=node-modules-wrapper-failure-z13
  rec=$(make_case wrapper-failure "$id")
  read_case "$rec"

  out=$(FM_INJECT_NODE_PUBLISHER_HOOK=1 run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should fail after a wrapper-controlled publication error"
  assert_not_contains "$out" "spawned $id" "wrapper-controlled publication failure launched a worker"
  [ -L "$WORKTREE_DIR/node_modules" ] || fail "wrapper-controlled failure removed published node_modules"
  publication=$(readlink "$WORKTREE_DIR/node_modules")
  [ -d "$WORKTREE_DIR/$publication" ] \
    || fail "wrapper-controlled failure removed published dependency backing"
  pass "fm-spawn retains backing after wrapper-controlled publication failure"
}

test_spawn_rejects_wrapper_status_without_dependency_tree() {
  local rec id out status candidate retained count early_status
  for early_status in 0 3; do
    id="node-modules-wrapper-status-${early_status}-z14"
    rec=$(make_case "wrapper-status-$early_status" "$id")
    read_case "$rec"

    out=$(FM_NODE_PUBLISHER_EARLY_STATUS="$early_status" run_spawn "$id")
    status=$?
    [ "$status" -ne 0 ] || fail "spawn accepted wrapper status $early_status without node_modules"
    assert_not_contains "$out" "spawned $id" "wrapper status $early_status launched a worker without dependencies"
    [ ! -e "$WORKTREE_DIR/node_modules" ] && [ ! -L "$WORKTREE_DIR/node_modules" ] \
      || fail "wrapper status $early_status unexpectedly created node_modules"
    retained=
    count=0
    for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
      [ -e "$candidate" ] || [ -L "$candidate" ] || continue
      retained=$candidate
      count=$((count + 1))
    done
    if [ "$early_status" = 0 ]; then
      [ "$count" -eq 1 ] || fail "wrapper status 0 did not retain exactly one ambiguous backing tree"
      assert_present "$retained/third-party/index.js" \
        "wrapper status 0 retained an incomplete dependency backing"
    else
      [ "$count" -eq 0 ] || fail "wrapper status 3 leaked unused dependency staging"
    fi
  done
  pass "fm-spawn rejects wrapper statuses without a valid dependency tree"
}

test_spawn_retracts_invalid_owned_publication() {
  local rec id out status candidate mode
  for mode in workspace backing; do
    id="node-modules-invalid-owned-$mode-z15"
    rec=$(make_case "invalid-owned-$mode" "$id")
    read_case "$rec"

    out=$(FM_INVALID_NODE_MODULES_PUBLICATION="$mode" \
      FM_NODE_MODULES_PRIMARY_WORKSPACE="$PROJECT_DIR/packages/lib" run_spawn "$id")
    status=$?
    [ "$status" -ne 0 ] || fail "spawn accepted invalid owned publication mode $mode"
    assert_not_contains "$out" "spawned $id" "invalid owned publication mode $mode launched a worker"
    [ ! -e "$WORKTREE_DIR/node_modules" ] && [ ! -L "$WORKTREE_DIR/node_modules" ] \
      || fail "invalid owned publication mode $mode left node_modules"
    for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
      [ ! -e "$candidate" ] && [ ! -L "$candidate" ] \
        || fail "invalid owned publication mode $mode leaked dependency staging"
    done
  done
  pass "fm-spawn retracts invalid owned dependency publications"
}

test_spawn_shares_dependencies_and_repoints_workspace_links
test_spawn_leaves_existing_node_modules_untouched
test_spawn_rejects_existing_primary_dependency_link
test_spawn_rejects_target_only_primary_workspace_link
test_spawn_rejects_dangling_existing_workspace_link
test_spawn_ignores_published_beeline_consumers
test_spawn_preserves_tree_created_during_publication
test_spawn_rejects_primary_dependency_link_created_during_publication
test_spawn_cleans_staging_after_setup_failure
test_spawn_validates_staging_before_publication
test_spawn_rejects_dangling_staged_workspace_link
test_spawn_cancels_after_staging_registration_interrupt
test_spawn_cleans_staging_after_creator_status_failure
test_spawn_preserves_publication_after_interrupt
test_spawn_preserves_publication_after_hup
test_spawn_preserves_backing_after_ambiguous_publisher_exit
test_spawn_isolates_publisher_from_ambient_node_options
test_spawn_retains_staging_after_ambiguous_publisher_exec_failure
test_spawn_cleans_staging_after_creator_termination
test_spawn_cleans_known_unpublished_staging_during_interrupt
test_spawn_retains_backing_after_wrapper_postpublication_failure
test_spawn_rejects_wrapper_status_without_dependency_tree
test_spawn_retracts_invalid_owned_publication

echo "# all fm-spawn-node-modules tests passed"
