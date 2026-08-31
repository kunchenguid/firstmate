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
if ! command -v node >/dev/null 2>&1; then
  echo "ok - fm-spawn node_modules behavior # SKIP node unavailable"
  exit 0
fi
for utility in ln mkdir mv rm readlink false; do
  if ! command -v "$utility" >/dev/null 2>&1; then
    echo "ok - fm-spawn node_modules behavior # SKIP $utility unavailable"
    exit 0
  fi
done
SYSTEM_NODE=$(NODE_OPTIONS= node -p 'process.execPath')
LN_BIN=$(command -v ln)
MKDIR_BIN=$(command -v mkdir)
MV_BIN=$(command -v mv)
RM_BIN=$(command -v rm)
READLINK_BIN=$(command -v readlink)
FALSE_BIN=$(command -v false)

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
  send-keys)
    if [ "${4:-}" = -l ] && [ -n "${FM_FAKE_LAUNCH_SCRIPT:-}" ]; then
      printf '%s\n' "${5:-}" > "$FM_FAKE_LAUNCH_SCRIPT"
      if [ "${FM_SIGNAL_AFTER_LAUNCH_PAYLOAD:-0}" = 1 ]; then
        parent=$PPID
        (sleep 0.05; kill -TERM "$parent") &
      fi
    elif [ "${4:-}" = C-c ] && [ -n "${FM_FAKE_LAUNCH_SCRIPT:-}" ]; then
      : > "$FM_FAKE_LAUNCH_SCRIPT"
    fi
    exit 0
    ;;
  list-windows|has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
set -u
last=
for last in "$@"; do :; done
"$FM_TEST_LN_BIN" "$@" || exit $?
if [ -n "${FM_NODE_MODULES_MUTATION_TARGET:-}" ] \
   && [[ "$last" = */.fm-node-modules.*/.bin/beeline-cli ]]; then
  (
    while [ ! -L "$FM_NODE_MODULES_MUTATION_TARGET/node_modules" ]; do
      sleep 0.01
    done
    publication=$("$FM_TEST_READLINK_BIN" "$FM_NODE_MODULES_MUTATION_TARGET/node_modules")
    staging="$FM_NODE_MODULES_MUTATION_TARGET/$publication"
    "$FM_TEST_RM_BIN" -f "$staging/@beeline/lib"
    "$FM_TEST_LN_BIN" -s "$FM_NODE_MODULES_MUTATION_PRIMARY" "$staging/@beeline/lib"
  ) >/dev/null 2>&1 &
fi
exit 0
SH
  chmod +x "$fakebin/ln"
  cat > "$fakebin/node" <<SH
#!/usr/bin/env bash
set -u
if [ "\${FM_REJECT_PATH_NODE_PUBLISHER:-0}" = 1 ]; then
  exit 99
fi
if [ -n "\${FM_NODE_SHIM_MUTATION_TARGET:-}" ]; then
  (
    candidate=
    while [ -z "\$candidate" ]; do
      for candidate in "\$FM_NODE_SHIM_MUTATION_TARGET"/.fm-node-modules.*; do
        [ -d "\$candidate" ] || { candidate=; continue; }
        break
      done
    done
    publication=\${candidate##*/}
    "$LN_BIN" -s "\$publication" "\$FM_NODE_SHIM_MUTATION_TARGET/node_modules" || exit 0
    "$RM_BIN" -f "\$candidate/@beeline/lib"
    "$LN_BIN" -s "\$FM_NODE_SHIM_MUTATION_PRIMARY" "\$candidate/@beeline/lib"
  ) >/dev/null 2>&1 &
fi
exec "$SYSTEM_NODE" "\$@"
SH
  chmod +x "$fakebin/node"
  cat > "$fakebin/codex" <<SH
#!/usr/bin/env bash
set -u
case "\${FM_TEST_NODE_PROBE:-}" in
  cjs)
    exec node -e "\$FM_TEST_NODE_SCRIPT" \
      "\${FM_TEST_NODE_ARG1:-}" "\${FM_TEST_NODE_ARG2:-}"
    ;;
  esm)
    exec node --input-type=module -e "\$FM_TEST_NODE_SCRIPT" \
      "\${FM_TEST_NODE_ARG1:-}" "\${FM_TEST_NODE_ARG2:-}"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/codex"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_toolbin_without_node() {
  local dir=$1 source name directory old_ifs
  mkdir -p "$dir"
  old_ifs=$IFS
  IFS=:
  for directory in $PATH; do
    [ -n "$directory" ] || directory=.
    [ -d "$directory" ] || continue
    for source in "$directory"/*; do
      [ -x "$source" ] || continue
      name=${source##*/}
      [ "$name" = node ] && continue
      [ ! -e "$dir/$name" ] && [ ! -L "$dir/$name" ] || continue
      "$LN_BIN" -s "$source" "$dir/$name"
    done
  done
  IFS=$old_ifs
  printf '%s\n' "$dir"
}

add_dependency_volume() {
  local index=0
  while [ "$index" -lt 300 ]; do
    "$MKDIR_BIN" "$PROJECT_DIR/node_modules/third-party-$index"
    index=$((index + 1))
  done
}

start_primary_dependency_mutator() {
  local stop=$1 source=$2
  (
    local candidate attempts=0 value=0
    while [ "$attempts" -lt 200000 ]; do
      for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
        [ -d "$candidate" ] || continue
        while [ ! -e "$stop" ]; do
          printf '%s\n' "$value" > "$source"
          value=$((value + 1))
        done
        exit 0
      done
      attempts=$((attempts + 1))
      sleep 0.001
    done
    exit 124
  ) >/dev/null 2>&1 &
  PUBLICATION_CONTENDER_PID=$!
}

add_workspace_validation_volume() {
  local index=0 name
  while [ "$index" -lt 150 ]; do
    name="race-$index"
    mkdir -p "$PROJECT_DIR/packages/$name" "$WORKTREE_DIR/packages/$name"
    printf '{"name":"@beeline/%s","version":"1.0.0"}\n' "$name" \
      > "$PROJECT_DIR/packages/$name/package.json"
    printf '{"name":"@beeline/%s","version":"1.0.0"}\n' "$name" \
      > "$WORKTREE_DIR/packages/$name/package.json"
    "$LN_BIN" -s "../../packages/$name" "$PROJECT_DIR/node_modules/@beeline/$name"
    index=$((index + 1))
  done
}

start_publication_contender() {
  local target=$1 primary=${2:-}
  (
    local candidate attempts=0
    while [ "$attempts" -lt 2000 ]; do
      for candidate in "$target"/.fm-node-modules.*; do
        [ -d "$candidate" ] || continue
        if [ -n "$primary" ]; then
          "$LN_BIN" -s "$primary" "$target/node_modules"
        else
          "$MKDIR_BIN" "$target/node_modules" || exit 2
          "$MKDIR_BIN" "$target/node_modules/@beeline"
          printf 'worker install\n' > "$target/node_modules/owned.txt"
          "$LN_BIN" -s ../../packages/lib "$target/node_modules/@beeline/lib"
          "$LN_BIN" -s "$target/packages/absolute-lib" "$target/node_modules/@beeline/absolute-lib"
          "$LN_BIN" -s ../../packages/cli "$target/node_modules/@beeline/cli"
        fi
        exit 0
      done
      attempts=$((attempts + 1))
      sleep 0.005
    done
    exit 124
  ) &
  PUBLICATION_CONTENDER_PID=$!
}

start_postpublication_workspace_mutator() {
  local target=$1 victim=$2 primary=$3
  (
    local attempts=0 publication staging probe
    while [ "$attempts" -lt 20000 ]; do
      for probe in "$target"/.fm-node-modules.probe.*; do
        [ -L "$probe" ] || continue
        publication=$("$READLINK_BIN" "$probe")
        staging="$target/$publication"
        if [ -L "$staging/@beeline/$victim" ]; then
          "$RM_BIN" -f "$staging/@beeline/$victim"
          "$LN_BIN" -s "$primary" "$staging/@beeline/$victim"
          "$MKDIR_BIN" "$target/node_modules" || exit 2
          printf 'competing install\n' > "$target/node_modules/owned.txt"
          exit 0
        fi
      done
      attempts=$((attempts + 1))
      sleep 0.001
    done
    exit 124
  ) &
  PUBLICATION_CONTENDER_PID=$!
}

start_postpublication_replacer() {
  local target=$1 replacement launch_script
  replacement="$target/.fm-test-node-modules-replacement.$$"
  launch_script="$HOME_DIR/state/fake-pane-launch.sh"
  mkdir -p "$replacement/@beeline"
  printf 'competing install\n' > "$replacement/owned.txt"
  ln -s ../../packages/lib "$replacement/@beeline/lib"
  ln -s "$target/packages/absolute-lib" "$replacement/@beeline/absolute-lib"
  ln -s ../../packages/cli "$replacement/@beeline/cli"
  (
    local attempts=0
    while [ "$attempts" -lt 20000 ]; do
      if [ -s "$launch_script" ] && [ -L "$target/node_modules" ]; then
        "$RM_BIN" -f "$target/node_modules"
        "$MV_BIN" "$replacement" "$target/node_modules"
        exit 0
      fi
      attempts=$((attempts + 1))
      sleep 0.001
    done
    exit 124
  ) &
  PUBLICATION_CONTENDER_PID=$!
}

wait_publication_contender() {
  local status=0
  wait "$PUBLICATION_CONTENDER_PID" || status=$?
  if [ "$status" -ne 0 ]; then
    kill "$PUBLICATION_CONTENDER_PID" 2>/dev/null || true
    wait "$PUBLICATION_CONTENDER_PID" 2>/dev/null || true
  fi
  PUBLICATION_CONTENDER_PID=
  return "$status"
}

stop_publication_contender() {
  [ -n "${PUBLICATION_CONTENDER_PID:-}" ] || return 0
  kill "$PUBLICATION_CONTENDER_PID" 2>/dev/null || true
  wait "$PUBLICATION_CONTENDER_PID" 2>/dev/null || true
  PUBLICATION_CONTENDER_PID=
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
  printf '{"name":"@beeline/lib","version":"1.0.0","main":"index.js"}\n' \
    > "$project/packages/lib/package.json"
  printf '{"name":"@beeline/absolute-lib","version":"1.0.0"}\n' \
    > "$project/packages/absolute-lib/package.json"
  printf '{"name":"@beeline/cli","version":"1.0.0"}\n' \
    > "$project/packages/cli/package.json"
  printf 'module.exports = "primary";\n' > "$project/packages/lib/index.js"
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
  : > "$HOME_DIR/state/fake-pane-launch.sh"
  HOME="${FM_TEST_ACCOUNT_HOME:-$HOME}" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' FM_FAKE_PANE_PATH="$WORKTREE_DIR" \
    FM_NODE_MODULES_MUTATION_TARGET="${FM_NODE_MODULES_MUTATION_TARGET:-}" \
    FM_NODE_MODULES_MUTATION_PRIMARY="${FM_NODE_MODULES_MUTATION_PRIMARY:-}" \
    FM_NODE_SHIM_MUTATION_TARGET="${FM_NODE_SHIM_MUTATION_TARGET:-}" \
    FM_NODE_SHIM_MUTATION_PRIMARY="${FM_NODE_SHIM_MUTATION_PRIMARY:-}" \
    FM_REJECT_PATH_NODE_PUBLISHER="${FM_REJECT_PATH_NODE_PUBLISHER:-0}" \
    FM_SIGNAL_AFTER_LAUNCH_PAYLOAD="${FM_SIGNAL_AFTER_LAUNCH_PAYLOAD:-0}" \
    FM_TEST_LN_BIN="$LN_BIN" FM_TEST_RM_BIN="$RM_BIN" \
    FM_TEST_READLINK_BIN="$READLINK_BIN" \
    FM_FAKE_LAUNCH_SCRIPT="$HOME_DIR/state/fake-pane-launch.sh" \
    PATH="${FM_SPAWN_TEST_PATH:-$FAKEBIN_DIR:$PATH}" \
    "$SPAWN" "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off 2>&1
}

run_beeline_cjs() {
  local script=$1 launch
  shift
  launch=$(cat "$HOME_DIR/state/fake-pane-launch.sh")
  [ -n "$launch" ] || fail "Beeline launch payload was not captured"
  FM_TEST_NODE_PROBE=cjs FM_TEST_NODE_SCRIPT="$script" \
    FM_TEST_NODE_ARG1="${1:-}" FM_TEST_NODE_ARG2="${2:-}" \
    NODE_OPTIONS= PATH="$FAKEBIN_DIR:$PATH" bash -c "$launch"
}

run_beeline_esm() {
  local script=$1 launch
  shift
  launch=$(cat "$HOME_DIR/state/fake-pane-launch.sh")
  [ -n "$launch" ] || fail "Beeline launch payload was not captured"
  FM_TEST_NODE_PROBE=esm FM_TEST_NODE_SCRIPT="$script" \
    FM_TEST_NODE_ARG1="${1:-}" FM_TEST_NODE_ARG2="${2:-}" \
    NODE_OPTIONS= PATH="$FAKEBIN_DIR:$PATH" bash -c "$launch"
}

test_spawn_shares_dependencies_and_repoints_workspace_links() {
  local rec id out status node_modules_link workspace_link absolute_workspace_link bin_link bin_out
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
  [ ! "$WORKTREE_DIR/node_modules/third-party/index.js" -ef \
    "$PROJECT_DIR/node_modules/third-party/index.js" ] \
    || fail "third-party package file shared a mutable inode with the primary installation"
  printf 'worker dependency patch\n' > "$WORKTREE_DIR/node_modules/third-party/index.js"
  [ "$(cat "$PROJECT_DIR/node_modules/third-party/index.js")" = 'shared dependency' ] \
    || fail "worker dependency write mutated the primary installation"

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

test_spawn_shared_dependency_imports_worktree_workspace() {
  local rec id out status result
  id=node-modules-shared-import-z1a
  rec=$(make_case shared-import "$id")
  read_case "$rec"
  printf 'module.exports = require("@beeline/lib");\n' \
    > "$PROJECT_DIR/node_modules/third-party/index.js"
  printf 'module.exports = "worker";\n' > "$WORKTREE_DIR/packages/lib/index.js"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should publish worktree-rooted shared dependencies"
  assert_contains "$out" "spawned $id" "worktree-rooted dependency publication did not launch the worker"
  result=$(NODE_OPTIONS= "$SYSTEM_NODE" -e \
    'process.stdout.write(require(process.argv[1]));' \
    "$WORKTREE_DIR/node_modules/third-party")
  [ "$result" = worker ] || fail "shared dependency imported the primary workspace source"
  pass "fm-spawn roots shared dependency workspace imports in the worktree"
}

test_spawn_preserves_shared_dependency_symlinks() {
  local rec id out status result alias_link root_alias_link nested_link publication
  id=node-modules-shared-symlink-z1aa
  rec=$(make_case shared-symlink "$id")
  read_case "$rec"
  mkdir "$PROJECT_DIR/node_modules/shared"
  mkdir "$PROJECT_DIR/node_modules/bridge"
  printf 'module.exports = {};\n' > "$PROJECT_DIR/node_modules/shared/index.js"
  printf 'module.exports = require("@beeline/lib");\n' \
    > "$PROJECT_DIR/node_modules/bridge/index.js"
  ln -s ../shared "$PROJECT_DIR/node_modules/third-party/alias"
  ln -s "$PROJECT_DIR/node_modules/bridge" \
    "$PROJECT_DIR/node_modules/third-party/absolute-bridge"
  ln -s shared "$PROJECT_DIR/node_modules/root-alias"
  printf 'const direct = require("../shared");\nconst alias = require("./alias");\nconst rootAlias = require("../root-alias");\nif (direct !== alias || direct !== rootAlias) throw new Error("identity changed");\nmodule.exports = require("./absolute-bridge");\n' \
    > "$PROJECT_DIR/node_modules/third-party/index.js"
  printf 'module.exports = "worker";\n' > "$WORKTREE_DIR/packages/lib/index.js"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should preserve internal dependency symlinks"
  assert_contains "$out" "spawned $id" "dependency symlink publication did not launch the worker"
  alias_link=$(readlink "$WORKTREE_DIR/node_modules/third-party/alias")
  [ "$alias_link" = ../shared ] || fail "shared dependency symlink topology changed"
  root_alias_link=$(readlink "$WORKTREE_DIR/node_modules/root-alias")
  [ "$root_alias_link" = shared ] || fail "package-root dependency symlink topology changed"
  publication=$(readlink "$WORKTREE_DIR/node_modules")
  nested_link=$(readlink "$WORKTREE_DIR/node_modules/third-party/absolute-bridge")
  [ "$nested_link" = "$WORKTREE_DIR/$publication/bridge" ] \
    || fail "absolute nested dependency symlink remained rooted in the primary checkout"
  result=$(NODE_OPTIONS= "$SYSTEM_NODE" -e \
    'process.stdout.write(require(process.argv[1]));' \
    "$WORKTREE_DIR/node_modules/third-party")
  [ "$result" = worker ] || fail "nested dependency symlink imported the primary workspace"
  pass "fm-spawn preserves dependency symlinks while rebasing primary targets"
}

test_spawn_preserves_external_package_root_symlinks() {
  local rec id out status external external_esm first_link second_link result relative_link relative_target
  id=node-modules-external-roots-z1aab
  rec=$(make_case external-roots "$id")
  read_case "$rec"
  external="$TMP_ROOT/external-linked-package"
  external_esm="$TMP_ROOT/external-linked-esm-package"
  mkdir -p "$external"
  mkdir -p "$external_esm"
  printf 'module.exports = { value: "initial", workspace: require("@beeline/lib") };\n' \
    > "$external/index.js"
  printf '{"type":"module"}\n' > "$external_esm/package.json"
  printf 'import workspace from "@beeline/lib"; export default workspace;\n' \
    > "$external_esm/index.js"
  ln -s "$external" "$PROJECT_DIR/node_modules/external-first"
  ln -s "$external" "$PROJECT_DIR/node_modules/external-second"
  ln -s "$external_esm" "$PROJECT_DIR/node_modules/external-esm"
  relative_target=$(NODE_OPTIONS= "$SYSTEM_NODE" -e \
    'process.stdout.write(require("path").relative(process.argv[1], process.argv[2]));' \
    "$PROJECT_DIR/node_modules/third-party" "$external/index.js")
  ln -s "$relative_target" "$PROJECT_DIR/node_modules/third-party/external-resource"
  printf 'module.exports = "worker";\n' > "$WORKTREE_DIR/packages/lib/index.js"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should preserve external package-root links"
  assert_contains "$out" "spawned $id" "external package-root publication did not launch the worker"
  first_link=$(readlink "$WORKTREE_DIR/node_modules/external-first")
  second_link=$(readlink "$WORKTREE_DIR/node_modules/external-second")
  [ "$first_link" = "$external" ] && [ "$second_link" = "$external" ] \
    || fail "external package roots were materialized instead of shared"
  relative_link=$(readlink "$WORKTREE_DIR/node_modules/third-party/external-resource")
  [ "$relative_link" = "$external/index.js" ] \
    || fail "escaping relative dependency link changed its external target"
  result=$(run_beeline_cjs \
    'const first = require(process.argv[1]); const second = require(process.argv[2]); process.stdout.write(`${first === second}:${first.workspace}:${first.value}`);' \
    "$WORKTREE_DIR/node_modules/external-first" \
    "$WORKTREE_DIR/node_modules/external-second")
  [ "$result" = true:worker:initial ] \
    || fail "external package identity or worktree workspace resolution changed"
  printf 'module.exports = { value: "updated", workspace: require("@beeline/lib") };\n' \
    > "$external/index.js"
  result=$(run_beeline_cjs \
    'process.stdout.write(require(process.argv[1]).value);' \
    "$WORKTREE_DIR/node_modules/external-first")
  [ "$result" = updated ] || fail "external package-root updates were not shared live"
  result=$(run_beeline_esm \
    'const { pathToFileURL } = await import("node:url"); const value = await import(pathToFileURL(process.argv[1]).href); process.stdout.write(value.default);' \
    "$WORKTREE_DIR/node_modules/external-esm/index.js")
  [ "$result" = worker ] || fail "external ESM package did not resolve the worktree workspace"
  pass "fm-spawn preserves external package-root sharing and identity"
}

test_spawn_uses_worktree_workspace_manifests() {
  local rec id out status renamed_real expected_renamed_real new_real expected_new_real
  id=node-modules-worktree-manifests-z1aaa
  rec=$(make_case worktree-manifests "$id")
  read_case "$rec"
  printf '{"name":"@beeline/renamed","version":"1.0.0","main":"index.js"}\n' \
    > "$WORKTREE_DIR/packages/lib/package.json"
  mkdir -p "$WORKTREE_DIR/packages/new"
  printf '{"name":"@beeline/new","version":"1.0.0"}\n' \
    > "$WORKTREE_DIR/packages/new/package.json"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should synthesize links from worktree workspace manifests"
  assert_contains "$out" "spawned $id" "worktree workspace manifest publication did not launch the worker"
  assert_absent "$WORKTREE_DIR/node_modules/@beeline/lib" \
    "renamed workspace retained its obsolete primary package link"
  renamed_real=$(cd "$WORKTREE_DIR/node_modules/@beeline/renamed" && pwd -P)
  expected_renamed_real=$(cd "$WORKTREE_DIR/packages/lib" && pwd -P)
  [ "$renamed_real" = "$expected_renamed_real" ] \
    || fail "renamed workspace did not resolve to its worktree source"
  new_real=$(cd "$WORKTREE_DIR/node_modules/@beeline/new" && pwd -P)
  expected_new_real=$(cd "$WORKTREE_DIR/packages/new" && pwd -P)
  [ "$new_real" = "$expected_new_real" ] \
    || fail "worktree-only workspace did not resolve to its worktree source"
  [ "$(readlink "$PROJECT_DIR/node_modules/@beeline/lib")" = ../../packages/lib ] \
    || fail "worktree manifest publication mutated the primary workspace link"
  pass "fm-spawn makes worktree manifests authoritative for workspace links"
}

test_spawn_rebases_canonical_absolute_workspace_binary() {
  local rec id out status project_alias bin_link bin_out
  id=node-modules-canonical-bin-z1ab
  rec=$(make_case canonical-bin "$id")
  read_case "$rec"
  project_alias="$TMP_ROOT/canonical-bin-project-alias"
  ln -s "$PROJECT_DIR" "$project_alias"
  rm "$PROJECT_DIR/node_modules/.bin/beeline-cli"
  ln -s "$project_alias/packages/cli/bin.sh" "$PROJECT_DIR/node_modules/.bin/beeline-cli"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should rebase canonical absolute workspace binaries"
  assert_contains "$out" "spawned $id" "canonical workspace binary publication did not launch the worker"
  bin_link=$(readlink "$WORKTREE_DIR/node_modules/.bin/beeline-cli")
  [ "$bin_link" = "$WORKTREE_DIR/packages/cli/bin.sh" ] \
    || fail "canonical absolute workspace binary remained pointed at primary source"
  printf '#!/usr/bin/env bash\nprintf "worker cli\\n"\n' > "$WORKTREE_DIR/packages/cli/bin.sh"
  chmod +x "$WORKTREE_DIR/packages/cli/bin.sh"
  bin_out=$("$WORKTREE_DIR/node_modules/.bin/beeline-cli")
  [ "$bin_out" = 'worker cli' ] || fail "canonical absolute workspace binary executed primary source"
  pass "fm-spawn rebases canonical absolute workspace binaries to the worktree"
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
  local rec id out status publication toolbin account_home result
  id=node-modules-script-node-z1c
  rec=$(make_case script-node "$id")
  read_case "$rec"
  toolbin=$(make_toolbin_without_node "$TMP_ROOT/script-node-tools")
  account_home="$TMP_ROOT/script-node-account"
  mkdir -p "$account_home/.asdf/installs/nodejs/12/bin" \
    "$account_home/.asdf/installs/nodejs/22/bin"
  "$LN_BIN" -s "$FALSE_BIN" "$account_home/.asdf/installs/nodejs/12/bin/node"
  "$LN_BIN" -s "$SYSTEM_NODE" "$account_home/.asdf/installs/nodejs/22/bin/node"

  out=$(FM_REJECT_PATH_NODE_PUBLISHER=1 \
    FM_TEST_ACCOUNT_HOME="$account_home" \
    FM_SPAWN_TEST_PATH="$FAKEBIN_DIR:$toolbin" run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should resolve a script-managed Node runtime"
  assert_contains "$out" "spawned $id" "script-managed Node runtime did not launch the worker"
  [ -L "$WORKTREE_DIR/node_modules" ] || fail "script-managed Node runtime did not publish node_modules"
  publication=$(readlink "$WORKTREE_DIR/node_modules")
  [ -d "$WORKTREE_DIR/$publication" ] || fail "script-managed Node runtime left dependency backing unavailable"
  result=$(FM_REJECT_PATH_NODE_PUBLISHER=1 \
    run_beeline_cjs 'process.stdout.write("compatible")')
  [ "$result" = compatible ] \
    || fail "pane launch did not pin the compatible Node runtime"
  pass "fm-spawn resolves script-managed Node runtimes before publication"
}

test_spawn_reports_missing_compatible_node_runtime() {
  local rec id out status toolbin account_home
  id=node-modules-missing-node-z1ca
  rec=$(make_case missing-node "$id")
  read_case "$rec"
  toolbin=$(make_toolbin_without_node "$TMP_ROOT/missing-node-tools")
  account_home="$TMP_ROOT/missing-node-account"
  mkdir -p "$account_home"

  out=$(FM_REJECT_PATH_NODE_PUBLISHER=1 \
    FM_TEST_ACCOUNT_HOME="$account_home" \
    FM_SPAWN_TEST_PATH="$FAKEBIN_DIR:$toolbin" run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted an environment without a compatible Node runtime"
  assert_contains "$out" "requires a compatible native Node runtime" \
    "missing Node runtime failure was silent"
  assert_not_contains "$out" "spawned $id" "missing Node runtime launched a worker"
  pass "fm-spawn reports an unavailable compatible Node runtime"
}

test_spawn_does_not_accept_unvalidated_exact_contention() {
  local rec id out status workspace_real expected_real
  id=node-modules-exact-contention-z1cc
  rec=$(make_case exact-contention "$id")
  read_case "$rec"

  out=$(FM_NODE_SHIM_MUTATION_TARGET="$WORKTREE_DIR" \
    FM_NODE_SHIM_MUTATION_PRIMARY="$PROJECT_DIR/packages/lib" run_spawn "$id")
  status=$?
  sleep 0.5
  expect_code 0 "$status" "spawn should avoid PATH shim interference with dependency publication"
  assert_contains "$out" "spawned $id" "safe dependency publication did not launch the worker"
  workspace_real=$(cd "$WORKTREE_DIR/node_modules/@beeline/lib" && pwd -P)
  expected_real=$(cd "$WORKTREE_DIR/packages/lib" && pwd -P)
  [ "$workspace_real" = "$expected_real" ] || fail "exact publication contention bypassed workspace validation"
  pass "fm-spawn avoids and validates exact dependency publication contention"
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
  local rec id out status external external_esm result
  id=node-modules-existing-z2
  rec=$(make_case existing-tree "$id")
  read_case "$rec"
  mkdir -p "$WORKTREE_DIR/node_modules/@beeline"
  printf 'worker install\n' > "$WORKTREE_DIR/node_modules/owned.txt"
  ln -s ../../packages/lib "$WORKTREE_DIR/node_modules/@beeline/lib"
  ln -s "$WORKTREE_DIR/packages/absolute-lib" "$WORKTREE_DIR/node_modules/@beeline/absolute-lib"
  ln -s ../../packages/cli "$WORKTREE_DIR/node_modules/@beeline/cli"
  external="$TMP_ROOT/existing-external-cjs"
  external_esm="$TMP_ROOT/existing-external-esm"
  mkdir -p "$external" "$external_esm"
  printf 'module.exports = require("@beeline/lib");\n' > "$external/index.js"
  printf '{"type":"module"}\n' > "$external_esm/package.json"
  printf 'import workspace from "@beeline/lib"; export default workspace;\n' \
    > "$external_esm/index.js"
  ln -s "$external" "$WORKTREE_DIR/node_modules/external-cjs"
  ln -s "$external_esm" "$WORKTREE_DIR/node_modules/external-esm"
  printf 'module.exports = "worker";\n' > "$WORKTREE_DIR/packages/lib/index.js"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should preserve an existing worktree dependency tree"
  assert_present "$WORKTREE_DIR/node_modules/owned.txt" \
    "spawn replaced an existing worktree node_modules tree"
  [ ! -e "$WORKTREE_DIR/node_modules/third-party" ] \
    || fail "spawn overlaid primary dependencies onto an existing worktree tree"
  assert_absent "$WORKTREE_DIR/node_modules/__firstmate_beeline_workspace_resolver__.cjs" \
    "spawn mutated the existing tree with a resolver"
  result=$(run_beeline_cjs \
    'process.stdout.write(require(process.argv[1]));' \
    "$WORKTREE_DIR/node_modules/external-cjs")
  [ "$result" = worker ] || fail "existing-tree external CommonJS import escaped the worktree"
  result=$(run_beeline_esm \
    'const { pathToFileURL } = await import("node:url"); const value = await import(pathToFileURL(process.argv[1]).href); process.stdout.write(value.default);' \
    "$WORKTREE_DIR/node_modules/external-esm/index.js")
  [ "$result" = worker ] || fail "existing-tree external ESM import escaped the worktree"
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
  "$RM_BIN" -rf "$WORKTREE_DIR/packages/lib"
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

test_spawn_rejects_stale_primary_workspace_link() {
  local rec id out status other_worktree candidate
  id=node-modules-stale-primary-z2g
  rec=$(make_case stale-primary-workspace "$id")
  read_case "$rec"
  other_worktree="$TMP_ROOT/stale-primary-source"
  mkdir -p "$other_worktree/packages/lib"
  rm "$PROJECT_DIR/node_modules/@beeline/lib"
  ln -s "$other_worktree/packages/lib" "$PROJECT_DIR/node_modules/@beeline/lib"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a stale primary workspace link to another worktree"
  assert_not_contains "$out" "spawned $id" "stale primary workspace link launched a worker"
  [ "$(readlink "$PROJECT_DIR/node_modules/@beeline/lib")" = "$other_worktree/packages/lib" ] \
    || fail "spawn mutated the stale primary workspace link"
  [ ! -e "$WORKTREE_DIR/node_modules" ] && [ ! -L "$WORKTREE_DIR/node_modules" ] \
    || fail "stale primary workspace link published node_modules"
  for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ] \
      || fail "stale primary workspace link leaked dependency staging"
  done
  pass "fm-spawn rejects stale primary workspace links independently of their destinations"
}

test_spawn_ignores_published_beeline_consumers() {
  local rec id out status
  id=node-modules-consumer-z3
  rec=$(make_case published-consumer "$id")
  read_case "$rec"
  rm "$PROJECT_DIR/node_modules/@beeline/lib" \
    "$PROJECT_DIR/node_modules/@beeline/absolute-lib" \
    "$PROJECT_DIR/node_modules/@beeline/cli"
  rm "$PROJECT_DIR/packages/lib/package.json" \
    "$PROJECT_DIR/packages/absolute-lib/package.json" \
    "$PROJECT_DIR/packages/cli/package.json"
  rm "$WORKTREE_DIR/packages/lib/package.json" \
    "$WORKTREE_DIR/packages/absolute-lib/package.json" \
    "$WORKTREE_DIR/packages/cli/package.json"
  mkdir "$PROJECT_DIR/node_modules/@beeline/published"
  printf 'published package\n' > "$PROJECT_DIR/node_modules/@beeline/published/index.js"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should ignore a non-workspace Beeline consumer"
  [ ! -e "$WORKTREE_DIR/node_modules" ] && [ ! -L "$WORKTREE_DIR/node_modules" ] \
    || fail "spawn shared dependencies for a non-workspace Beeline consumer"
  pass "fm-spawn scopes dependency sharing to Beeline workspaces"
}

test_spawn_preserves_exclude_path_for_harness_files() {
  local rec id out status
  id=node-modules-harness-exclude-z3a
  rec=$(make_case harness-exclude "$id")
  read_case "$rec"
  rm "$PROJECT_DIR/packages/lib/package.json" \
    "$PROJECT_DIR/packages/absolute-lib/package.json" \
    "$PROJECT_DIR/packages/cli/package.json"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  fm_fake_exit0 "$FAKEBIN_DIR" claude

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should preserve harness exclude-path setup"
  assert_contains "$out" "spawned $id" "harness exclude-path setup did not launch the worker"
  assert_present "$WORKTREE_DIR/.claude/settings.local.json" \
    "Claude harness settings were not created"
  pass "fm-spawn preserves one-argument exclude-path setup for harness files"
}

test_spawn_shares_published_beeline_dependencies_with_workspaces() {
  local rec id out status workspace_real expected_workspace_real
  id=node-modules-mixed-beeline-z3b
  rec=$(make_case mixed-beeline "$id")
  read_case "$rec"
  mkdir "$PROJECT_DIR/node_modules/@beeline/published"
  printf 'published package\n' > "$PROJECT_DIR/node_modules/@beeline/published/index.js"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should share published @beeline dependencies alongside workspaces"
  assert_contains "$out" "spawned $id" "mixed @beeline dependency tree did not launch the worker"
  [ ! "$WORKTREE_DIR/node_modules/@beeline/published/index.js" -ef \
    "$PROJECT_DIR/node_modules/@beeline/published/index.js" ] \
    || fail "published @beeline dependency shared a mutable primary inode"
  printf 'worker patch\n' > "$WORKTREE_DIR/node_modules/@beeline/published/index.js"
  [ "$(cat "$PROJECT_DIR/node_modules/@beeline/published/index.js")" = 'published package' ] \
    || fail "published @beeline dependency write mutated primary source"
  workspace_real=$(cd "$WORKTREE_DIR/node_modules/@beeline/lib" && pwd -P)
  expected_workspace_real=$(cd "$WORKTREE_DIR/packages/lib" && pwd -P)
  [ "$workspace_real" = "$expected_workspace_real" ] || fail "mixed @beeline workspace did not resolve to worktree source"
  pass "fm-spawn shares published @beeline dependencies while isolating workspaces"
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
  if [ "$status" -ne 0 ]; then
    stop_publication_contender
    expect_code 0 "$status" "spawn should preserve a dependency tree created during publication"
  fi
  wait_publication_contender \
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

test_spawn_rejects_dependency_source_changes_during_staging() {
  local rec id out status candidate stop source
  id=node-modules-source-change-z4a
  rec=$(make_case source-change "$id")
  read_case "$rec"
  add_dependency_volume
  stop="$HOME_DIR/state/stop-primary-mutation"
  source="$PROJECT_DIR/node_modules/third-party/index.js"
  start_primary_dependency_mutator "$stop" "$source"

  out=$(run_spawn "$id")
  status=$?
  : > "$stop"
  wait_publication_contender \
    || fail "primary dependency mutator did not overlap staging"
  [ "$status" -ne 0 ] || fail "spawn published dependencies while the primary tree changed"
  assert_contains "$out" "failed to stage the primary Beeline dependency tree" \
    "primary dependency source change was not diagnosed"
  assert_not_contains "$out" "spawned $id" "mixed dependency snapshot launched a worker"
  [ ! -e "$WORKTREE_DIR/node_modules" ] && [ ! -L "$WORKTREE_DIR/node_modules" ] \
    || fail "mixed dependency snapshot published node_modules"
  for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ] \
      || fail "mixed dependency snapshot leaked staging"
  done
  pass "fm-spawn rejects primary dependency changes during staging"
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
  if [ "$status" -eq 0 ]; then
    stop_publication_contender
    fail "spawn accepted a contended dependency link to primary source"
  fi
  wait_publication_contender \
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

test_spawn_rejects_invalid_candidate_before_competing_publication() {
  local rec id out status candidate victim
  id=node-modules-postpublication-invalid-z4c
  rec=$(make_case postpublication-invalid "$id")
  read_case "$rec"
  add_workspace_validation_volume
  victim=race-149
  start_postpublication_workspace_mutator \
    "$WORKTREE_DIR" "$victim" "$PROJECT_DIR/packages/$victim"

  out=$(run_spawn "$id")
  status=$?
  wait_publication_contender \
    || fail "post-publication workspace mutator did not alter the published tree"
  [ "$status" -ne 0 ] || fail "spawn accepted a workspace mutation after publication"
  assert_contains "$out" "Beeline dependency" \
    "candidate or competing-tree validation failure was not diagnosed"
  assert_not_contains "$out" "spawned $id" "invalid owned publication launched a worker"
  assert_present "$WORKTREE_DIR/node_modules/owned.txt" \
    "invalid publication rollback removed a cooperative competing install"
  for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ] \
      || fail "invalid owned publication left its backing tree installed"
  done
  [ "$(readlink "$PROJECT_DIR/node_modules/@beeline/$victim")" = "../../packages/$victim" ] \
    || fail "invalid publication rollback mutated the primary dependency tree"
  pass "fm-spawn rejects invalid candidates without touching non-cooperative replacements"
}

test_spawn_rejects_replacement_after_owned_publication() {
  local rec id out status candidate
  id=node-modules-launch-replacement-z4d
  rec=$(make_case launch-replacement "$id")
  read_case "$rec"
  start_postpublication_replacer "$WORKTREE_DIR"

  out=$(run_spawn "$id")
  status=$?
  wait_publication_contender \
    || fail "post-publication contender did not replace node_modules"
  [ "$status" -ne 0 ] || fail "spawn launched after its dependency publication was replaced"
  assert_contains "$out" "replaced before worker launch" \
    "publication identity replacement was not diagnosed"
  assert_not_contains "$out" "spawned $id" "replaced dependency publication launched a worker"
  [ ! -s "$HOME_DIR/state/fake-pane-launch.sh" ] \
    || fail "failed final validation left a stale launch payload in the pane"
  assert_present "$WORKTREE_DIR/node_modules/owned.txt" \
    "publication validation mutated the competing dependency tree"
  for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ] \
      || fail "replaced publication leaked its private dependency staging"
  done
  pass "fm-spawn rejects replacement of its validated publication before launch"
}

test_spawn_preserves_presubmission_cancellation() {
  local rec id out status
  id=node-modules-presubmit-signal-z4e
  rec=$(make_case presubmit-signal "$id")
  read_case "$rec"

  out=$(FM_SIGNAL_AFTER_LAUNCH_PAYLOAD=1 run_spawn "$id")
  status=$?
  expect_code 143 "$status" "spawn should retain pre-submission TERM status"
  assert_not_contains "$out" "spawned $id" "cancelled dependency launch reported success"
  [ ! -s "$HOME_DIR/state/fake-pane-launch.sh" ] \
    || fail "cancelled dependency launch left a staged pane command"
  pass "fm-spawn preserves cancellation before dependency launch submission"
}

test_spawn_omits_worktree_deleted_workspace() {
  local rec id out status
  id=node-modules-deleted-workspace-z5b
  rec=$(make_case deleted-workspace "$id")
  read_case "$rec"
  "$RM_BIN" -rf "$WORKTREE_DIR/packages/absolute-lib"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should omit a workspace deleted from the worktree"
  assert_contains "$out" "spawned $id" "worktree workspace deletion did not launch the worker"
  assert_absent "$WORKTREE_DIR/node_modules/@beeline/absolute-lib" \
    "deleted worktree workspace retained its primary package link"
  [ "$(readlink "$PROJECT_DIR/node_modules/@beeline/absolute-lib")" = "$PROJECT_DIR/packages/absolute-lib" ] \
    || fail "worktree workspace deletion mutated the primary workspace link"
  pass "fm-spawn omits workspaces deleted from the authoritative worktree"
}

test_spawn_rejects_missing_installed_workspace_link() {
  local rec id out status candidate
  id=node-modules-missing-installed-workspace-z5bb
  rec=$(make_case missing-installed-workspace "$id")
  read_case "$rec"
  mkdir -p "$PROJECT_DIR/packages/new" "$WORKTREE_DIR/packages/new"
  printf '{"name":"@beeline/new","version":"1.0.0"}\n' \
    > "$PROJECT_DIR/packages/new/package.json"
  printf '{"name":"@beeline/new","version":"1.0.0"}\n' \
    > "$WORKTREE_DIR/packages/new/package.json"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a missing installed workspace link"
  assert_contains "$out" "primary Beeline workspace links failed validation" \
    "workspace validation failure was silent"
  assert_not_contains "$out" "spawned $id" "missing installed workspace link launched a worker"
  [ ! -e "$WORKTREE_DIR/node_modules" ] && [ ! -L "$WORKTREE_DIR/node_modules" ] \
    || fail "missing installed workspace link published node_modules"
  for candidate in "$WORKTREE_DIR"/.fm-node-modules.*; do
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ] \
      || fail "missing installed workspace link leaked dependency staging"
  done
  pass "fm-spawn requires an installed link for every workspace manifest"
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
test_spawn_shared_dependency_imports_worktree_workspace
test_spawn_preserves_shared_dependency_symlinks
test_spawn_preserves_external_package_root_symlinks
test_spawn_uses_worktree_workspace_manifests
test_spawn_rebases_canonical_absolute_workspace_binary
test_spawn_publication_is_independent_of_path_node_wrappers
test_spawn_resolves_script_managed_node_runtime
test_spawn_reports_missing_compatible_node_runtime
test_spawn_does_not_accept_unvalidated_exact_contention
test_spawn_prevents_path_link_mutation_after_validation
test_spawn_leaves_existing_node_modules_untouched
test_spawn_rejects_existing_primary_dependency_link
test_spawn_rejects_target_only_primary_workspace_link
test_spawn_rejects_dangling_existing_workspace_link
test_spawn_rejects_workspace_link_from_another_worktree
test_spawn_rejects_worktree_workspace_alias
test_spawn_rejects_stale_primary_workspace_link
test_spawn_ignores_published_beeline_consumers
test_spawn_preserves_exclude_path_for_harness_files
test_spawn_shares_published_beeline_dependencies_with_workspaces
test_spawn_preserves_tree_created_during_publication
test_spawn_rejects_dependency_source_changes_during_staging
test_spawn_rejects_primary_dependency_link_created_during_publication
test_spawn_rejects_invalid_candidate_before_competing_publication
test_spawn_rejects_replacement_after_owned_publication
test_spawn_preserves_presubmission_cancellation
test_spawn_omits_worktree_deleted_workspace
test_spawn_rejects_missing_installed_workspace_link
test_spawn_rejects_dangling_staged_workspace_link

echo "# all fm-spawn-node-modules tests passed"
