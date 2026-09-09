#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-trust.sh and the claude spawn that calls it.
#
# Both halves of the contract are load-bearing and both are proven here: a
# legitimate fresh task worktree AND its canonical root (the primary checkout
# Claude's gated-grants backstop keys trust on) are trusted so a claude worker
# reaches its brief with no human, and every out-of-scope path is REFUSED
# rather than warned about or quietly skipped.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-trust)

TRUST="$ROOT/bin/fm-claude-trust.sh"

# make_case <name>: a project with one linked worktree plus an isolated Claude
# config directory. Echoes "<case>|<proj>|<wt>|<config>".
make_case() {
  local name=$1 case_dir proj wt config
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  config="$case_dir/claude-config"
  mkdir -p "$config"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s|%s|%s|%s\n' "$case_dir" "$proj" "$wt" "$config"
}

read_case() {
  IFS='|' read -r CASE_DIR PROJ WT CONFIG <<EOF
$1
EOF
}

# run_trust <config> <worktree> <project> [home]: invoke with an isolated store.
run_trust() {
  local config=$1 wt=$2 proj=$3 home=${4:-$1}
  CLAUDE_CONFIG_DIR="$config" HOME="$home" "$TRUST" "$wt" "$proj" 2>&1
}

trusted_paths() {  # <store>
  node -e 'const j=require("node:fs").existsSync(process.argv[1])?JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")):{};for(const [k,v] of Object.entries(j.projects||{})){if(v&&v.hasTrustDialogAccepted===true)console.log(k);}' "$1"
}

assert_trusted() {  # <store> <path> <msg>
  trusted_paths "$1" | grep -Fqx "$2" || fail "$3"
}

assert_not_trusted() {  # <store> <path> <msg>
  trusted_paths "$1" | grep -Fqx "$2" && fail "$3"
  return 0
}

# The store is the vendor's own persisted JSON, so preservation is asserted
# against the parsed value at a key path rather than the serialized bytes.
store_value() {  # <store> <key...> -> the JSON value at that key path
  local store=$1
  shift
  node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));let v=j;for(const k of process.argv.slice(2)){v=(v===undefined||v===null)?undefined:v[k];}console.log(JSON.stringify(v));' "$store" "$@"
}

assert_store_value() {  # <store> <expected-json> <msg> <key...>
  local store=$1 expected=$2 msg=$3 actual
  shift 3
  actual=$(store_value "$store" "$@")
  [ "$actual" = "$expected" ] || fail "$msg (expected $expected, got $actual)"
}

# A PATH carrying the tools the scope test needs but no node, so the
# missing-interpreter path is exercised without disturbing the real PATH.
node_free_path() {  # <case-dir> -> a bin dir holding the script's own tools but no node
  local dir=$1/nonode-bin tool
  mkdir -p "$dir"
  for tool in bash env git mkdir; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

test_fresh_worktree_is_trusted() {
  local rec out
  rec=$(make_case fresh)
  read_case "$rec"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 0 $? "a fresh linked worktree must be trusted: $out"
  assert_contains "$out" "trusted:" "registration did not report what it trusted"
  assert_trusted "$CONFIG/.claude.json" "$WT" "the worktree was not recorded as trusted"
  # Claude's gated-grants backstop keys trust on the canonical git root, the
  # primary checkout a linked worktree's .git file points at, so the worktree
  # entry alone leaves a worker parked on that dialog variant.
  assert_trusted "$CONFIG/.claude.json" "$PROJ" "the worktree's canonical root was not recorded as trusted"
  assert_contains "$out" "$WT" "the success line did not name the worktree"
  assert_contains "$out" "$PROJ" "the success line did not name the canonical root"
  # The staged write is renamed into place, so no temporary store may survive it.
  [ -z "$(find "$CONFIG" -maxdepth 1 -name '.claude.json.fm-trust.*' -print -quit)" ] \
    || fail "a temporary store file was left behind in the config directory"
  pass "fm-claude-trust.sh: a fresh task worktree is trusted"
}

test_registration_is_idempotent() {
  local rec out count
  rec=$(make_case idempotent)
  read_case "$rec"
  run_trust "$CONFIG" "$WT" "$PROJ" >/dev/null
  out=$(run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 0 $? "a repeat registration must succeed: $out"
  count=$(trusted_paths "$CONFIG/.claude.json" | grep -Fxc "$WT")
  [ "$count" = 1 ] || fail "a repeat registration duplicated the entry ($count)"
  count=$(trusted_paths "$CONFIG/.claude.json" | grep -Fxc "$PROJ")
  [ "$count" = 1 ] || fail "a repeat registration duplicated the canonical-root entry ($count)"
  pass "fm-claude-trust.sh: repeat registration is idempotent"
}

test_primary_checkout_is_refused() {
  local rec out
  rec=$(make_case primary)
  read_case "$rec"
  out=$(run_trust "$CONFIG" "$PROJ" "$PROJ")
  expect_code 1 $? "the primary checkout must be refused: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  assert_not_trusted "$CONFIG/.claude.json" "$PROJ" "the primary checkout was trusted"
  pass "fm-claude-trust.sh: refuses the primary checkout"
}

# CDPATH redirects a relative `cd` operand, and `git rev-parse
# --git-common-dir` answers `.git` for a primary checkout. With a decoy on
# CDPATH that also holds a `.git`, the common dir resolved for both arguments
# once landed in the decoy instead, so the git-dir-vs-common-dir comparison
# disagreed and the primary checkout was trusted.
test_cdpath_cannot_defeat_the_primary_checkout_refusal() {
  local rec out
  rec=$(make_case cdpath)
  read_case "$rec"
  mkdir -p "$CASE_DIR/decoy/.git"
  export CDPATH="$CASE_DIR/decoy"
  out=$(run_trust "$CONFIG" "$PROJ" "$PROJ")
  expect_code 1 $? "an exported CDPATH must not let the primary checkout through: $out"
  unset CDPATH
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  assert_not_trusted "$CONFIG/.claude.json" "$PROJ" "an exported CDPATH let the primary checkout be trusted"
  pass "fm-claude-trust.sh: an exported CDPATH cannot defeat the scope refusal"
}

# There is deliberately no case for an unresolvable git directory. The guard at
# that line is defence in depth and cannot be reached from outside the script:
# `real_dir`'s `cd` needs search permission on the git dir and git's own reads
# need the same permission on the same directory, so any mode that makes the
# resolution empty makes git fail first and the earlier "not inside a git
# repository" refusal fires instead. A case built with `chmod 000` passes
# identically with the guard deleted, which reports safety that is not there.

# Git exports GIT_DIR into every hook environment, so an inherited pair is
# ordinary. With GIT_DIR naming a linked worktree's git dir and GIT_WORK_TREE
# naming the primary checkout, git reports a toplevel that matches the argument
# and a git dir that differs from the common dir, so the primary checkout once
# satisfied the refusal on the caller's environment rather than on disk.
test_git_env_overrides_cannot_defeat_the_primary_checkout_refusal() {
  local rec out
  rec=$(make_case gitenv)
  read_case "$rec"
  GIT_DIR=$(git -C "$WT" rev-parse --absolute-git-dir)
  GIT_WORK_TREE=$PROJ
  export GIT_DIR GIT_WORK_TREE
  out=$(run_trust "$CONFIG" "$PROJ" "$PROJ")
  set -- $?
  unset GIT_DIR GIT_WORK_TREE
  expect_code 1 "$1" "inherited git environment overrides must not let the primary checkout through: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  assert_not_trusted "$CONFIG/.claude.json" "$PROJ" "inherited git environment overrides let the primary checkout be trusted"
  pass "fm-claude-trust.sh: inherited git environment overrides cannot defeat the scope refusal"
}

test_home_directory_is_refused_even_when_it_is_a_worktree() {
  local rec out home
  rec=$(make_case home-worktree)
  read_case "$rec"
  # Make HOME itself a linked worktree of the project, so every git check
  # PASSES and only the home guard can refuse it. Without this the home case
  # would pass vacuously through the "not a git repository" branch.
  home="$CASE_DIR/home"
  git -C "$PROJ" worktree add --quiet -b wt-home "$home"
  out=$(run_trust "$CONFIG" "$home" "$PROJ" "$home")
  expect_code 1 $? "a home directory must be refused even as a valid worktree: $out"
  assert_contains "$out" "home directory" "the refusal did not name the home directory"
  assert_not_trusted "$CONFIG/.claude.json" "$home" "the home directory was trusted"
  # Prove the git checks really would have accepted it, so the guard above is
  # what refused rather than an unrelated failure.
  out=$(run_trust "$CONFIG" "$home" "$PROJ" "$CASE_DIR/elsewhere-home")
  expect_code 0 $? "the same path must be acceptable once it is not HOME: $out"
  pass "fm-claude-trust.sh: refuses a home directory the git checks would accept"
}

# fm-spawn forwards CLAUDE_CONFIG_DIR onto the worker verbatim and the worker's
# pane starts in the task worktree, so a relative value names one store here and
# another there; registering into the first and reporting success would leave the
# worker meeting the dialog this control exists to remove.
test_relative_config_dir_is_refused() {
  local rec out
  rec=$(make_case relative-config)
  read_case "$rec"
  mkdir -p "$CASE_DIR/relhome"
  out=$(cd "$CASE_DIR/relhome" && CLAUDE_CONFIG_DIR=.claude-work HOME="$CASE_DIR/relhome" "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 1 $? "a relative CLAUDE_CONFIG_DIR must be refused: $out"
  assert_contains "$out" ".claude-work" "the refusal did not name the relative value"
  assert_contains "$out" "relative" "the refusal did not say why the value is unusable"
  [ ! -e "$CASE_DIR/relhome/.claude-work/.claude.json" ] \
    || fail "a store was written under this process's cwd for a relative CLAUDE_CONFIG_DIR"
  case "$out" in
    *"trusted:"*) fail "a registration was claimed for a store the worker may not read: $out" ;;
  esac
  pass "fm-claude-trust.sh: refuses a relative CLAUDE_CONFIG_DIR"
}

test_config_directory_is_refused() {
  local rec out
  rec=$(make_case config-dir)
  read_case "$rec"
  out=$(run_trust "$CONFIG" "$CONFIG" "$PROJ")
  expect_code 1 $? "the Claude config directory must be refused: $out"
  assert_contains "$out" "config directory" "the refusal did not name the config directory"
  pass "fm-claude-trust.sh: refuses the Claude config directory"
}

test_non_git_directory_is_refused() {
  local rec out plain
  rec=$(make_case plain)
  read_case "$rec"
  plain="$CASE_DIR/plain"
  mkdir -p "$plain"
  out=$(run_trust "$CONFIG" "$plain" "$PROJ")
  expect_code 1 $? "a plain directory must be refused: $out"
  assert_contains "$out" "not inside a git repository" "the refusal did not name the missing repository"
  assert_not_trusted "$CONFIG/.claude.json" "$plain" "a plain directory was trusted"
  pass "fm-claude-trust.sh: refuses a directory that is not a git worktree"
}

test_missing_directory_is_refused() {
  local rec out
  rec=$(make_case missing)
  read_case "$rec"
  out=$(run_trust "$CONFIG" "$CASE_DIR/nope" "$PROJ")
  expect_code 1 $? "a nonexistent path must be refused: $out"
  assert_contains "$out" "not an accessible directory" "the refusal did not name the inaccessible path"
  pass "fm-claude-trust.sh: refuses a path that does not exist"
}

test_foreign_project_worktree_is_refused() {
  local rec out other other_wt
  rec=$(make_case foreign)
  read_case "$rec"
  other="$CASE_DIR/other-project"
  other_wt="$CASE_DIR/other-wt"
  fm_git_worktree "$other" "$other_wt" wt-other
  out=$(run_trust "$CONFIG" "$other_wt" "$PROJ")
  expect_code 1 $? "another project's worktree must be refused: $out"
  assert_contains "$out" "is not a worktree of project" "the refusal did not name the project mismatch"
  assert_not_trusted "$CONFIG/.claude.json" "$other_wt" "a foreign project's worktree was trusted"
  pass "fm-claude-trust.sh: refuses a worktree belonging to another project"
}

test_worktree_subdirectory_is_refused() {
  local rec out sub
  rec=$(make_case subdir)
  read_case "$rec"
  sub="$WT/sub"
  mkdir -p "$sub"
  out=$(run_trust "$CONFIG" "$sub" "$PROJ")
  expect_code 1 $? "a subdirectory of the worktree must be refused: $out"
  assert_contains "$out" "is not a worktree root" "the refusal did not name the non-root path"
  assert_not_trusted "$CONFIG/.claude.json" "$sub" "a worktree subdirectory was trusted"
  pass "fm-claude-trust.sh: refuses a subdirectory of the worktree"
}

# The canonical root Claude's backstop keys on is the repository's MAIN
# checkout, which is not always the project argument: a linked spawning home
# (fm-spawn.sh's header) is a firstmate home that is itself a linked worktree
# of the project repository, and spawns from it must keep launching. The
# registered root must then be the main checkout, and the home's own path must
# never be written, because Claude does not look there.
test_linked_spawning_home_registers_the_repository_main_checkout() {
  local rec out home_wt
  rec=$(make_case linked-home)
  read_case "$rec"
  home_wt="$CASE_DIR/linked-home"
  git -C "$PROJ" worktree add --quiet --detach "$home_wt" HEAD
  out=$(run_trust "$CONFIG" "$WT" "$home_wt")
  expect_code 0 $? "a spawn from a linked spawning home must still register: $out"
  assert_trusted "$CONFIG/.claude.json" "$WT" "the worktree was not recorded for a linked spawning home"
  assert_trusted "$CONFIG/.claude.json" "$PROJ" "the repository main checkout was not recorded as the canonical root"
  assert_not_trusted "$CONFIG/.claude.json" "$home_wt" "the linked spawning home itself was trusted although Claude never keys on it"
  assert_contains "$out" "$PROJ" "the success line did not name the main checkout as the canonical root"
  pass "fm-claude-trust.sh: a linked spawning home registers the repository main checkout, not itself"
}

# The root is derived from git, never from the project argument's path: a
# subdirectory of the primary shares its common dir and passes the project
# check, and what gets written is still the checkout root.
test_primary_subdirectory_as_project_registers_the_checkout_root() {
  local rec out sub
  rec=$(make_case subdir-project)
  read_case "$rec"
  sub="$PROJ/sub"
  mkdir -p "$sub"
  out=$(run_trust "$CONFIG" "$WT" "$sub")
  expect_code 0 $? "a subdirectory of the primary named as the project must still register: $out"
  assert_trusted "$CONFIG/.claude.json" "$PROJ" "the checkout root was not recorded as the canonical root"
  assert_not_trusted "$CONFIG/.claude.json" "$sub" "the project argument's subdirectory was trusted instead of the checkout root"
  pass "fm-claude-trust.sh: the canonical root comes from git, not from the project argument's path"
}

# A home directory that happens to hold the main checkout is still never a
# standing trust grant, for the same reason it is refused as a worktree.
test_home_directory_as_canonical_root_is_refused() {
  local rec out home wt
  rec=$(make_case home-root)
  read_case "$rec"
  home="$CASE_DIR/home-repo"
  wt="$CASE_DIR/home-repo-wt"
  fm_git_worktree "$home" "$wt" wt-home-root
  out=$(run_trust "$CONFIG" "$wt" "$home" "$home")
  expect_code 1 $? "a home directory as the canonical root must be refused: $out"
  assert_contains "$out" "home directory" "the refusal did not name the home directory"
  assert_not_trusted "$CONFIG/.claude.json" "$home" "the home directory was trusted as the canonical root"
  assert_not_trusted "$CONFIG/.claude.json" "$wt" "the worktree was trusted although its canonical root was refused"
  # The same pair is acceptable once the root is not HOME, so the home guard is
  # what refused rather than an unrelated failure.
  out=$(run_trust "$CONFIG" "$wt" "$home" "$CASE_DIR/elsewhere-home")
  expect_code 0 $? "the same pair must be acceptable once the root is not HOME: $out"
  assert_trusted "$CONFIG/.claude.json" "$home" "the canonical root was not recorded once it was no longer HOME"
  pass "fm-claude-trust.sh: refuses a home directory as the canonical root"
}

# A bare repository has linked worktrees but no main checkout, so there is no
# canonical root for Claude's backstop to find and nothing safe to guess at.
test_bare_repository_worktree_is_refused() {
  local rec out bare wt
  rec=$(make_case bare)
  read_case "$rec"
  bare="$CASE_DIR/bare.git"
  wt="$CASE_DIR/bare-wt"
  git clone --quiet --bare "$PROJ" "$bare"
  git -C "$bare" worktree add --quiet --detach "$wt" HEAD
  out=$(run_trust "$CONFIG" "$wt" "$bare")
  expect_code 1 $? "a worktree of a bare repository must be refused: $out"
  assert_contains "$out" "bare" "the refusal did not say the repository has no main working tree"
  assert_not_trusted "$CONFIG/.claude.json" "$wt" "a bare repository's worktree was trusted without a canonical root"
  pass "fm-claude-trust.sh: refuses a worktree whose repository has no main checkout"
}

# A canonical-root entry usually already exists: firstmate itself opens the
# primary checkout in Claude, and Claude records per-project state there.
# Registration must only set the trust flag and leave every other key alone.
test_existing_canonical_root_entry_keeps_its_other_keys() {
  local rec store
  rec=$(make_case preserve-root)
  read_case "$rec"
  store="$CONFIG/.claude.json"
  node -e 'const [store, proj] = process.argv.slice(1); require("node:fs").writeFileSync(store, JSON.stringify({numStartups: 4, projects: {[proj]: {hasTrustDialogAccepted: false, allowedTools: ["Bash"], history: [{display: "hello"}], hasCompletedProjectOnboarding: true}}}) + "\n");' "$store" "$PROJ"
  run_trust "$CONFIG" "$WT" "$PROJ" >/dev/null || fail "registration failed against a store holding the canonical root"
  assert_trusted "$store" "$PROJ" "an existing canonical-root entry was not flipped to trusted"
  assert_trusted "$store" "$WT" "the worktree was not recorded beside an existing canonical-root entry"
  assert_store_value "$store" '["Bash"]' "the canonical root's allowedTools were lost" projects "$PROJ" allowedTools
  assert_store_value "$store" '[{"display":"hello"}]' "the canonical root's history was lost" projects "$PROJ" history
  assert_store_value "$store" true "the canonical root's onboarding flag was lost" projects "$PROJ" hasCompletedProjectOnboarding
  assert_store_value "$store" 4 "an unrelated top-level value was changed" numStartups
  pass "fm-claude-trust.sh: an existing canonical-root entry keeps its other keys"
}

test_unrelated_store_content_is_preserved() {
  local rec store
  rec=$(make_case preserve)
  read_case "$rec"
  store="$CONFIG/.claude.json"
  cat > "$store" <<'JSON'
{"hasCompletedOnboarding":true,"numStartups":7,"projects":{"/other/path":{"hasTrustDialogAccepted":false,"allowedTools":["Bash"]}}}
JSON
  run_trust "$CONFIG" "$WT" "$PROJ" >/dev/null || fail "registration failed against an existing store"
  assert_trusted "$store" "$WT" "the worktree was not recorded in an existing store"
  assert_store_value "$store" true "an unrelated top-level key was lost" hasCompletedOnboarding
  assert_store_value "$store" 7 "an unrelated top-level value was changed" numStartups
  assert_store_value "$store" '["Bash"]' "another project's settings were lost" projects /other/path allowedTools
  assert_not_trusted "$store" "/other/path" "another project's trust decision was flipped"
  pass "fm-claude-trust.sh: preserves unrelated store content"
}

test_symlinked_store_to_a_foreign_owned_target_is_refused() {
  local rec out
  rec=$(make_case symlink-foreign)
  read_case "$rec"
  # Root owns /etc/passwd as a regular file on both Linux and macOS, so it
  # stands in for a store resolving outside this user's ownership. Running as
  # root would own it and make the refusal vacuous.
  if [ "$(id -u)" = 0 ]; then
    pass "fm-claude-trust.sh: refuses a store symlinked to another user's file (skipped as root)"
    return 0
  fi
  ln -s /etc/passwd "$CONFIG/.claude.json"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 1 $? "a store resolving to another user's file must be refused: $out"
  assert_contains "$out" "not owned by this user" "the refusal did not name the ownership failure"
  assert_contains "$out" "/etc/passwd" "the refusal named the link rather than the resolved target it judged"
  pass "fm-claude-trust.sh: refuses a store symlinked to another user's file"
}

test_symlinked_store_to_an_owned_target_is_accepted() {
  local rec out target
  rec=$(make_case symlink-owned)
  read_case "$rec"
  # The dotfile-manager and synced-folder layout: the store is a symlink whose
  # target this user owns, so it must be followed rather than refused, and the
  # link must survive so the layout keeps working.
  target="$CASE_DIR/dotfiles/.claude.json"
  mkdir -p "$CASE_DIR/dotfiles"
  printf '%s\n' '{"numStartups":3,"projects":{}}' > "$target"
  ln -s "$target" "$CONFIG/.claude.json"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 0 $? "a store symlinked to this user's own file must be accepted: $out"
  assert_trusted "$target" "$WT" "the trust did not land in the symlink's target"
  [ -L "$CONFIG/.claude.json" ] || fail "the store symlink was replaced by a regular file instead of followed"
  assert_store_value "$target" 3 "an unrelated key in the target was lost" numStartups
  [ -z "$(find "$CASE_DIR/dotfiles" -maxdepth 1 -name '.claude.json.fm-trust.*' -print -quit)" ] \
    || fail "a temporary store file was left beside the resolved target"
  pass "fm-claude-trust.sh: follows a store symlink to this user's own file and leaves the link intact"
}

# Registering trust is what keeps a worker off the dialog, so a missing node
# refuses rather than degrades: proceeding would launch the worker straight into
# the dialog this control exists to remove.
test_missing_node_is_refused() {
  local rec out bindir
  rec=$(make_case no-node)
  read_case "$rec"
  bindir=$(node_free_path "$CASE_DIR")
  out=$(PATH="$bindir" run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 1 $? "a missing node must refuse rather than let the spawn proceed: $out"
  assert_contains "$out" "node" "the refusal did not name the missing interpreter"
  assert_not_trusted "$CONFIG/.claude.json" "$WT" "a worktree was trusted without an interpreter to write the store"
  case "$out" in
    *"trusted:"*) fail "a registration was claimed although none could be written: $out" ;;
  esac
  pass "fm-claude-trust.sh: a missing node is refused rather than degraded"
}

# A missing interpreter must not soften the scope boundary, which
# git and the filesystem decide on their own.
test_scope_refusal_stays_fail_closed_without_node() {
  local rec out bindir
  rec=$(make_case no-node-refusal)
  read_case "$rec"
  bindir=$(node_free_path "$CASE_DIR")
  out=$(PATH="$bindir" run_trust "$CONFIG" "$PROJ" "$PROJ")
  expect_code 1 $? "the primary checkout must still be refused without node: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  pass "fm-claude-trust.sh: a scope refusal stays fail-closed without node"
}

test_corrupt_store_fails_closed() {
  local rec out store
  rec=$(make_case corrupt)
  read_case "$rec"
  store="$CONFIG/.claude.json"
  printf '%s\n' 'not json' > "$store"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 1 $? "an unparseable store must be refused: $out"
  assert_grep 'not json' "$store" "the unparseable store was overwritten instead of left alone"
  pass "fm-claude-trust.sh: refuses an unparseable store and leaves it untouched"
}

# A refused registration must abort the spawn before any per-task state exists.
# The busy-state generation is armed after it, and nothing between that arm and
# the far-later rollback arming can clear it, so a record stranded here would
# read as a task busy forever for an id that has no meta at all. The per-task
# temp root /tmp/fm-<id> is the other resource created on the way to the arm, and
# nothing removes it either: fm-teardown finds it through tasktmp= in the task's
# meta, which a refused spawn never publishes. The id carries this process's pid
# so the temp-root assertion reads only this run's path.
test_refused_spawn_leaves_no_task_state() {
  local case_dir home proj wt config fakebin out id
  case_dir="$TMP_ROOT/refused-spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  config="$case_dir/claude-config"
  id="refusedspawn$$"
  # Root owns /etc/passwd, so a store resolving to it is refused as another
  # user's file. Running as root would own it and make the refusal vacuous.
  if [ "$(id -u)" = 0 ]; then
    pass "fm-spawn.sh: a trust-refused claude spawn leaves no task state (skipped as root)"
    return 0
  fi
  mkdir -p "$config"
  ln -s /etc/passwd "$config/.claude.json"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" wt-refused
  fm_test_spawn_brief "$home" "$id"
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$config" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" claude \
    --mode no-mistakes --yolo off)
  expect_code 1 $? "a spawn whose trust registration is refused must fail: $out"
  assert_contains "$out" "workspace trust" "the spawn did not report the trust refusal"
  [ ! -e "$home/state/$id.busy-state" ] \
    || fail "a refused spawn stranded a busy record nothing can clear"
  [ ! -e "$home/state/$id.busy-gen" ] \
    || fail "a refused spawn stranded a busy generation nothing can clear"
  [ ! -e "/tmp/fm-$id" ] \
    || { rm -rf "/tmp/fm-$id"; fail "a refused spawn stranded a temp root no teardown can find"; }
  pass "fm-spawn.sh: a trust-refused claude spawn leaves no task state behind"
}

# The spawn half: a real fm-spawn of a claude worker must pre-register the
# worktree AND deliver the launch command carrying the brief, with no dialog to
# answer and no human in the loop.
test_claude_spawn_pretrusts_its_worktree_and_reaches_the_brief() {
  local case_dir home proj wt config fakebin launch_log out
  case_dir="$TMP_ROOT/spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  config="$case_dir/claude-config"
  launch_log="$case_dir/launch.log"
  mkdir -p "$config"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" wt-spawn
  fm_test_spawn_brief "$home" trustspawn
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$config" FM_FAKE_LAUNCH_LOG="$launch_log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" trustspawn "$proj" claude \
    --mode no-mistakes --yolo off)
  expect_code 0 $? "the claude spawn must succeed: $out"
  assert_trusted "$config/.claude.json" "$wt" \
    "the claude spawn did not pre-register trust for its worktree"
  assert_trusted "$config/.claude.json" "$proj" \
    "the claude spawn did not pre-register trust for the worktree's canonical root"
  assert_present "$launch_log" "the claude spawn sent no launch command"
  assert_grep 'claude --dangerously-skip-permissions' "$launch_log" \
    "the launch command was not the claude worker launch"
  assert_grep "$home/data/trustspawn/launch-brief.md" "$launch_log" \
    "the launch command did not carry the brief the worker must read"
  # The worker must read the SAME store the registration wrote, or the trust
  # would land somewhere the pane never looks.
  assert_grep "CLAUDE_CONFIG_DIR='$config'" "$launch_log" \
    "the launch command did not point the worker at the store that was trusted"
  pass "fm-spawn.sh: a claude spawn pre-trusts its worktree and launches with the brief"
}

test_fresh_worktree_is_trusted
test_registration_is_idempotent
test_primary_checkout_is_refused
test_cdpath_cannot_defeat_the_primary_checkout_refusal
test_git_env_overrides_cannot_defeat_the_primary_checkout_refusal
test_home_directory_is_refused_even_when_it_is_a_worktree
test_config_directory_is_refused
test_relative_config_dir_is_refused
test_non_git_directory_is_refused
test_missing_directory_is_refused
test_foreign_project_worktree_is_refused
test_worktree_subdirectory_is_refused
test_linked_spawning_home_registers_the_repository_main_checkout
test_primary_subdirectory_as_project_registers_the_checkout_root
test_home_directory_as_canonical_root_is_refused
test_bare_repository_worktree_is_refused
test_existing_canonical_root_entry_keeps_its_other_keys
test_unrelated_store_content_is_preserved
test_symlinked_store_to_a_foreign_owned_target_is_refused
test_symlinked_store_to_an_owned_target_is_accepted
test_corrupt_store_fails_closed
test_missing_node_is_refused
test_scope_refusal_stays_fail_closed_without_node
test_claude_spawn_pretrusts_its_worktree_and_reaches_the_brief
test_refused_spawn_leaves_no_task_state
