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
/bin/ln "$@" || exit $?
if [ -n "${FM_NODE_MODULES_MUTATION_TARGET:-}" ] \
   && [[ "$last" = */.fm-node-modules.*/.bin/beeline-cli ]]; then
  (
    while [ ! -L "$FM_NODE_MODULES_MUTATION_TARGET/node_modules" ]; do
      sleep 0.01
    done
    publication=$(/usr/bin/readlink "$FM_NODE_MODULES_MUTATION_TARGET/node_modules")
    staging="$FM_NODE_MODULES_MUTATION_TARGET/$publication"
    /bin/rm -f "$staging/@beeline/lib"
    /bin/ln -s "$FM_NODE_MODULES_MUTATION_PRIMARY" "$staging/@beeline/lib"
  ) >/dev/null 2>&1 &
fi
exit 0
SH
  chmod +x "$fakebin/ln"
  local real_node
  real_node=$(command -v node)
  cat > "$fakebin/node" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = - ] && [ "\${FM_REJECT_PATH_NODE_PUBLISHER:-0}" = 1 ]; then
  exit 99
fi
exec "$real_node" "\$@"
SH
  chmod +x "$fakebin/node"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_toolbin_without_node() {
  local dir=$1 source name
  mkdir -p "$dir"
  for source in /usr/bin/* /bin/*; do
    [ -x "$source" ] || continue
    name=${source##*/}
    [ "$name" = node ] && continue
    [ ! -e "$dir/$name" ] && [ ! -L "$dir/$name" ] || continue
    /bin/ln -s "$source" "$dir/$name"
  done
  printf '%s\n' "$dir"
}

add_dependency_volume() {
  local index=0
  while [ "$index" -lt 300 ]; do
    /bin/mkdir "$PROJECT_DIR/node_modules/third-party-$index"
    index=$((index + 1))
  done
}

start_publication_contender() {
  local target=$1 primary=${2:-}
  (
    local candidate
    while :; do
      for candidate in "$target"/.fm-node-modules.*; do
        [ -d "$candidate" ] || continue
        if [ -n "$primary" ]; then
          /bin/ln -s "$primary" "$target/node_modules"
        else
          /bin/mkdir "$target/node_modules" || exit 2
          /bin/mkdir "$target/node_modules/@beeline"
          printf 'worker install\n' > "$target/node_modules/owned.txt"
          /bin/ln -s ../../packages/lib "$target/node_modules/@beeline/lib"
          /bin/ln -s "$target/packages/absolute-lib" "$target/node_modules/@beeline/absolute-lib"
          /bin/ln -s ../../packages/cli "$target/node_modules/@beeline/cli"
        fi
        exit 0
      done
    done
  ) &
  PUBLICATION_CONTENDER_PID=$!
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
    FM_NODE_MODULES_MUTATION_TARGET="${FM_NODE_MODULES_MUTATION_TARGET:-}" \
    FM_NODE_MODULES_MUTATION_PRIMARY="${FM_NODE_MODULES_MUTATION_PRIMARY:-}" \
    FM_REJECT_PATH_NODE_PUBLISHER="${FM_REJECT_PATH_NODE_PUBLISHER:-0}" \
    PATH="${FM_SPAWN_TEST_PATH:-$FAKEBIN_DIR:$PATH}" \
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

test_spawn_publication_is_independent_of_path_node_wrappers() {
  local rec id out status publication
  id=node-modules-owner-safe-publisher-z1b
  rec=$(make_case owner-safe-publisher "$id")
  read_case "$rec"

  out=$(FM_REJECT_PATH_NODE_PUBLISHER=1 run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should publish dependencies without a PATH-controlled Node publisher"
  assert_contains "$out" "spawned $id" "owner-safe dependency publication did not launch the worker"
  [ -L "$WORKTREE_DIR/node_modules" ] || fail "owner-safe publisher did not create node_modules"
  publication=$(readlink "$WORKTREE_DIR/node_modules")
  [ -d "$WORKTREE_DIR/$publication" ] || fail "owner-safe publisher left dependency backing unavailable"
  pass "fm-spawn dependency publication is independent of PATH Node wrappers"
}

test_spawn_resolves_script_managed_node_runtime() {
  local rec id out status publication toolbin
  id=node-modules-script-node-z1c
  rec=$(make_case script-node "$id")
  read_case "$rec"
  toolbin=$(make_toolbin_without_node "$TMP_ROOT/script-node-tools")

  out=$(FM_REJECT_PATH_NODE_PUBLISHER=1 \
    FM_SPAWN_TEST_PATH="$FAKEBIN_DIR:$toolbin" run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should resolve a script-managed Node runtime"
  assert_contains "$out" "spawned $id" "script-managed Node runtime did not launch the worker"
  [ -L "$WORKTREE_DIR/node_modules" ] || fail "script-managed Node runtime did not publish node_modules"
  publication=$(readlink "$WORKTREE_DIR/node_modules")
  [ -d "$WORKTREE_DIR/$publication" ] || fail "script-managed Node runtime left dependency backing unavailable"
  pass "fm-spawn resolves script-managed Node runtimes before publication"
}

test_spawn_prevents_path_link_mutation_after_validation() {
  local rec id out status workspace_real expected_real
  id=node-modules-path-link-mutation-z1d
  rec=$(make_case path-link-mutation "$id")
  read_case "$rec"

  out=$(FM_NODE_MODULES_MUTATION_TARGET="$WORKTREE_DIR" \
    FM_NODE_MODULES_MUTATION_PRIMARY="$PROJECT_DIR/packages/lib" run_spawn "$id")
  status=$?
  sleep 0.5
  expect_code 0 "$status" "spawn should prevent PATH link helpers from mutating validated staging"
  assert_contains "$out" "spawned $id" "safe staged dependency publication did not launch the worker"
  workspace_real=$(cd "$WORKTREE_DIR/node_modules/@beeline/lib" && pwd -P)
  expected_real=$(cd "$WORKTREE_DIR/packages/lib" && pwd -P)
  [ "$workspace_real" = "$expected_real" ] || fail "published workspace link changed after validation"
  pass "fm-spawn prevents PATH link helpers from mutating validated staging"
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

test_spawn_rejects_workspace_link_from_another_worktree() {
  local rec id out status other_worktree
  id=node-modules-other-worktree-z2e
  rec=$(make_case other-worktree "$id")
  read_case "$rec"
  other_worktree="$TMP_ROOT/other-worktree-source"
  mkdir -p "$other_worktree/packages/legacy" "$WORKTREE_DIR/node_modules/@beeline"
  ln -s ../../packages/lib "$WORKTREE_DIR/node_modules/@beeline/lib"
  ln -s "$WORKTREE_DIR/packages/absolute-lib" "$WORKTREE_DIR/node_modules/@beeline/absolute-lib"
  ln -s ../../packages/cli "$WORKTREE_DIR/node_modules/@beeline/cli"
  ln -s "$other_worktree/packages/legacy" "$WORKTREE_DIR/node_modules/@beeline/legacy"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a workspace link from another worktree"
  assert_not_contains "$out" "spawned $id" "another worktree's workspace link launched a worker"
  [ "$(readlink "$WORKTREE_DIR/node_modules/@beeline/legacy")" = "$other_worktree/packages/legacy" ] \
    || fail "spawn mutated another worktree's workspace link"
  pass "fm-spawn refuses workspace links outside the exact worktree"
}

test_spawn_rejects_worktree_workspace_alias() {
  local rec id out status candidate
  id=node-modules-worktree-alias-z2f
  rec=$(make_case worktree-alias "$id")
  read_case "$rec"
  /bin/rm -rf "$WORKTREE_DIR/packages/lib"
  ln -s "$PROJECT_DIR/packages/lib" "$WORKTREE_DIR/packages/lib"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a worktree workspace alias to primary source"
  assert_not_contains "$out" "spawned $id" "worktree workspace alias launched a worker"
  [ "$(readlink "$WORKTREE_DIR/packages/lib")" = "$PROJECT_DIR/packages/lib" ] \
    || fail "spawn mutated the worktree workspace alias"
  [ ! -e "$WORKTREE_DIR/node_modules" ] && [ ! -L "$WORKTREE_DIR/node_modules" ] \
    || fail "worktree workspace alias published node_modules"
  for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ] \
      || fail "worktree workspace alias leaked dependency staging"
  done
  pass "fm-spawn refuses workspace aliases outside the canonical worktree"
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
  add_dependency_volume
  start_publication_contender "$WORKTREE_DIR"

  out=$(run_spawn "$id")
  status=$?
  wait "$PUBLICATION_CONTENDER_PID" \
    || fail "publication contender did not create its dependency tree"
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
  add_dependency_volume
  start_publication_contender "$WORKTREE_DIR" "$PROJECT_DIR/node_modules"

  out=$(run_spawn "$id")
  status=$?
  wait "$PUBLICATION_CONTENDER_PID" \
    || fail "primary publication contender did not create its dependency link"
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

test_spawn_shares_dependencies_and_repoints_workspace_links
test_spawn_publication_is_independent_of_path_node_wrappers
test_spawn_resolves_script_managed_node_runtime
test_spawn_prevents_path_link_mutation_after_validation
test_spawn_leaves_existing_node_modules_untouched
test_spawn_rejects_existing_primary_dependency_link
test_spawn_rejects_target_only_primary_workspace_link
test_spawn_rejects_dangling_existing_workspace_link
test_spawn_rejects_workspace_link_from_another_worktree
test_spawn_rejects_worktree_workspace_alias
test_spawn_ignores_published_beeline_consumers
test_spawn_preserves_tree_created_during_publication
test_spawn_rejects_primary_dependency_link_created_during_publication
test_spawn_validates_staging_before_publication
test_spawn_rejects_dangling_staged_workspace_link

echo "# all fm-spawn-node-modules tests passed"
