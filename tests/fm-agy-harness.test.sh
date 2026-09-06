#!/usr/bin/env bash
# Behavior tests for the verified agy (Antigravity CLI) crewmate adapter.
#
# The trust registration is the load-bearing half and BOTH sides of its contract
# are proven here: a legitimate fresh task worktree is trusted so an agy worker
# reaches its brief with no human, and every out-of-scope path is REFUSED rather
# than warned about or quietly skipped. agy's trust dialog renders no status-bar
# text, so a worker parked on it is indistinguishable from an idle one; a
# registration that silently did nothing would produce exactly that pane.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run from
# inside Cursor, Claude, Pi, Grok, or agy inherits those markers, which outrank
# the fake ancestry the detection cases set up. Drop them so the asserted verdict
# does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT \
  CURSOR_INVOKED_AS ANTIGRAVITY_CONVERSATION_ID

# shellcheck source=bin/fm-trace-context-lib.sh
. "$ROOT/bin/fm-trace-context-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-harness)
TRUST="$ROOT/bin/fm-agy-trust.sh"
HOOK="$ROOT/bin/fm-agy-turnend-hook.sh"

# make_case <name>: a project with one linked worktree plus an isolated HOME
# standing in for the launching user's own agy store.
# Echoes "<case>|<proj>|<wt>|<home>".
make_case() {
  local name=$1 case_dir proj wt home
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  home="$case_dir/home"
  mkdir -p "$home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s|%s|%s|%s\n' "$case_dir" "$proj" "$wt" "$home"
}

read_case() {
  IFS='|' read -r CASE_DIR PROJ WT AGY_HOME <<EOF
$1
EOF
}

store_path() { printf '%s/.gemini/antigravity-cli/settings.json\n' "$1"; }

run_trust() {  # <home> <worktree> <project>
  HOME="$1" "$TRUST" "$2" "$3" 2>&1
}

run_untrust() {  # <home> <worktree>
  HOME="$1" "$TRUST" --remove "$2" 2>&1
}

trusted_paths() {  # <store>
  node -e 'const fs=require("node:fs");const p=process.argv[1];if(!fs.existsSync(p))process.exit(0);const j=JSON.parse(fs.readFileSync(p,"utf8"));for(const v of (j.trustedWorkspaces||[]))console.log(v);' "$1"
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
store_value() {  # <store> <key...>
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
node_free_path() {  # <case-dir>
  local dir=$1/nonode-bin tool
  mkdir -p "$dir"
  for tool in bash env git mkdir sed; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

# --- trust: the accepted path ------------------------------------------------

test_fresh_worktree_is_trusted() {
  local rec out store
  rec=$(make_case fresh)
  read_case "$rec"
  out=$(run_trust "$AGY_HOME" "$WT" "$PROJ")
  expect_code 0 $? "a fresh linked worktree must be trusted: $out"
  assert_contains "$out" "trusted:" "registration did not report what it trusted"
  store=$(store_path "$AGY_HOME")
  assert_trusted "$store" "$WT" "the worktree was not recorded as trusted"
  # The staged write is renamed into place, so no temporary store may survive it.
  [ -z "$(find "$(dirname "$store")" -maxdepth 1 -name '.settings.json.fm-trust.*' -print -quit)" ] \
    || fail "a temporary store file was left behind in the settings directory"
  pass "fm-agy-trust.sh: a fresh task worktree is trusted"
}

# agy runs in the pane's cwd, which fm-spawn hands over unresolved, so a
# worktree reached through a symlinked parent can be presented to the trust
# lookup under either spelling. A miss is silent - the pane parks on a dialog
# that draws no status text - so both spellings of the one directory are recorded.
test_symlinked_worktree_spelling_is_trusted_too() {
  local rec out store link wt_link
  rec=$(make_case symlink-spelling)
  read_case "$rec"
  link="$TMP_ROOT/symlink-spelling-link"
  ln -sfn "$CASE_DIR" "$link"
  wt_link="$link/wt"
  out=$(run_trust "$AGY_HOME" "$wt_link" "$PROJ")
  expect_code 0 $? "a worktree named through a symlinked parent must be trusted: $out"
  store=$(store_path "$AGY_HOME")
  assert_trusted "$store" "$wt_link" "the launch spelling of the worktree was not recorded as trusted"
  assert_trusted "$store" "$WT" "the resolved spelling of the worktree was not recorded as trusted"
  pass "fm-agy-trust.sh: both spellings of a symlinked worktree path are trusted"
}

test_registration_is_idempotent() {
  local rec out count
  rec=$(make_case idempotent)
  read_case "$rec"
  run_trust "$AGY_HOME" "$WT" "$PROJ" >/dev/null
  out=$(run_trust "$AGY_HOME" "$WT" "$PROJ")
  expect_code 0 $? "a repeat registration must succeed: $out"
  count=$(trusted_paths "$(store_path "$AGY_HOME")" | grep -Fxc "$WT")
  [ "$count" = 1 ] || fail "a repeat registration duplicated the entry ($count)"
  pass "fm-agy-trust.sh: repeat registration is idempotent"
}

# The registration is the one task artifact written outside this home, into the
# operator's own vendor settings, so teardown needs a withdrawal that takes back
# exactly what the spawn added and nothing else.
# Registration covers both spellings of the directory, and each is withdrawn by
# naming it: the caller withdraws from a record of what its own registration
# reported adding, so withdrawing both is two calls, not one that re-derives.
test_removal_withdraws_the_spelling_it_is_named_and_keeps_the_rest() {
  local rec out store link wt_link
  rec=$(make_case removal)
  read_case "$rec"
  store=$(store_path "$AGY_HOME")
  mkdir -p "$(dirname "$store")"
  printf '%s\n' '{"enableTelemetry":false,"trustedWorkspaces":["/already/trusted"]}' > "$store"
  link="$TMP_ROOT/removal-link"
  ln -sfn "$CASE_DIR" "$link"
  wt_link="$link/wt"
  run_trust "$AGY_HOME" "$wt_link" "$PROJ" >/dev/null || fail "the fixture registration failed"
  assert_trusted "$store" "$wt_link" "the fixture did not register the launch spelling"
  assert_trusted "$store" "$WT" "the fixture did not register the resolved spelling"
  out=$(run_untrust "$AGY_HOME" "$wt_link")
  expect_code 0 $? "a registered worktree must be withdrawable: $out"
  assert_not_trusted "$store" "$wt_link" "the named spelling survived its own withdrawal"
  assert_trusted "$store" "$WT" "withdrawing one spelling took the other spelling with it"
  out=$(run_untrust "$AGY_HOME" "$WT")
  expect_code 0 $? "the second spelling must be withdrawable too: $out"
  assert_not_trusted "$store" "$WT" "the resolved spelling survived being named"
  assert_trusted "$store" "/already/trusted" "the withdrawal dropped an unrelated operator entry"
  assert_store_value "$store" 'false' "the withdrawal disturbed an unrelated key" enableTelemetry
  pass "fm-agy-trust.sh: removal withdraws the spelling it is named and leaves the rest alone"
}

# The two spellings of one directory can have two different owners: the operator
# trusted the resolved path by hand, and only the launch spelling is the task's.
# Re-deriving the pair on removal would take theirs, and the dialog it resurrects
# draws no status text, so the pane it wedges looks idle.
test_removal_leaves_the_operator_spelling_of_the_same_directory() {
  local rec out store link wt_link
  rec=$(make_case removal-operator-spelling)
  read_case "$rec"
  store=$(store_path "$AGY_HOME")
  mkdir -p "$(dirname "$store")"
  # The operator's own entry, on the RESOLVED spelling, made before any task ran.
  printf '{"trustedWorkspaces":["%s"]}\n' "$WT" > "$store"
  link="$TMP_ROOT/removal-operator-link"
  ln -sfn "$CASE_DIR" "$link"
  wt_link="$link/wt"
  out=$(run_trust "$AGY_HOME" "$wt_link" "$PROJ")
  expect_code 0 $? "the spawn's registration must succeed: $out"
  assert_contains "$out" "added: $wt_link" "the registration did not report adding the launch spelling"
  case "$out" in
    *"added: $WT"*) fail "the registration claimed to add the spelling the operator already trusted" ;;
  esac
  out=$(run_untrust "$AGY_HOME" "$wt_link")
  expect_code 0 $? "the task's own spelling must be withdrawable: $out"
  assert_not_trusted "$store" "$wt_link" "the task's own spelling survived the withdrawal"
  assert_trusted "$store" "$WT" "the withdrawal revoked the operator's own entry for the same directory"
  pass "fm-agy-trust.sh: removal leaves the operator's spelling of the same directory alone"
}

# Teardown calls the withdrawal for every task, so a task that never ran on agy
# must not cause a write at all - reformatting a vendor file firstmate does not
# own is exactly what the registration promises not to do.
test_removal_of_an_unregistered_path_writes_nothing() {
  local rec out store before
  rec=$(make_case removal-noop)
  read_case "$rec"
  store=$(store_path "$AGY_HOME")
  mkdir -p "$(dirname "$store")"
  printf '%s\n' '{"enableTelemetry":false,"trustedWorkspaces":["/already/trusted"]}' > "$store"
  before=$(cat "$store")
  out=$(run_untrust "$AGY_HOME" "$WT")
  expect_code 0 $? "withdrawing a path that was never registered must succeed: $out"
  [ "$(cat "$store")" = "$before" ] \
    || fail "withdrawing an unregistered path rewrote the operator's store"
  pass "fm-agy-trust.sh: withdrawing an unregistered path leaves the store byte-identical"
}

# A home that never ran agy has no store, and a teardown must not mint one.
test_removal_without_a_store_creates_nothing() {
  local rec out
  rec=$(make_case removal-no-store)
  read_case "$rec"
  out=$(run_untrust "$AGY_HOME" "$WT")
  expect_code 0 $? "withdrawing against a home with no agy store must succeed: $out"
  [ ! -e "$AGY_HOME/.gemini" ] || fail "the withdrawal created an agy store in a home that had none"
  pass "fm-agy-trust.sh: withdrawing against a home with no store creates nothing"
}

# Teardown withdraws while the worktree still resolves, but the entry is an
# absolute path and must stay withdrawable once the directory is gone.
test_removal_works_after_the_worktree_is_gone() {
  local rec out store wt_path
  rec=$(make_case removal-after-removal)
  read_case "$rec"
  store=$(store_path "$AGY_HOME")
  wt_path=$WT
  run_trust "$AGY_HOME" "$WT" "$PROJ" >/dev/null || fail "the fixture registration failed"
  git -C "$PROJ" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
  [ ! -d "$wt_path" ] || fail "the fixture did not remove the worktree"
  out=$(run_untrust "$AGY_HOME" "$wt_path")
  expect_code 0 $? "a removed worktree's registration must still be withdrawable: $out"
  assert_not_trusted "$store" "$wt_path" "the registration survived after the worktree was removed"
  pass "fm-agy-trust.sh: a registration is withdrawable after its worktree is gone"
}

# The registration is idempotent, so it cannot be asked "did you add this?" after
# the fact - it has to say so at the time. Teardown withdraws exactly what it
# reported adding, and a workspace the operator trusted by hand is not that.
test_registration_reports_only_what_it_added() {
  local rec out
  rec=$(make_case reports-added)
  read_case "$rec"
  out=$(run_trust "$AGY_HOME" "$WT" "$PROJ")
  expect_code 0 $? "a fresh registration must succeed: $out"
  assert_contains "$out" "added: $WT" "a fresh registration did not report the spelling it added"
  out=$(run_trust "$AGY_HOME" "$WT" "$PROJ")
  expect_code 0 $? "a repeat registration must succeed: $out"
  case "$out" in
    *"added: "*) fail "a repeat registration claimed to add a spelling that was already trusted: $out" ;;
  esac
  assert_contains "$out" "trusted:" "a repeat registration did not report what it trusted"
  assert_trusted "$(store_path "$AGY_HOME")" "$WT" "the repeat registration dropped the entry"
  pass "fm-agy-trust.sh: registration reports only the spellings it actually added"
}

test_unrelated_store_content_is_preserved() {
  local rec store
  rec=$(make_case preserve)
  read_case "$rec"
  store=$(store_path "$AGY_HOME")
  mkdir -p "$(dirname "$store")"
  cat > "$store" <<'JSON'
{"enableTelemetry":false,"remoteControlHostname":"box-1","trustedWorkspaces":["/already/trusted"]}
JSON
  run_trust "$AGY_HOME" "$WT" "$PROJ" >/dev/null || fail "registration failed against an existing store"
  assert_trusted "$store" "$WT" "the worktree was not recorded in an existing store"
  assert_trusted "$store" "/already/trusted" "an existing trusted workspace was dropped"
  assert_store_value "$store" false "an unrelated top-level key was lost" enableTelemetry
  assert_store_value "$store" '"box-1"' "an unrelated top-level value was changed" remoteControlHostname
  pass "fm-agy-trust.sh: preserves unrelated store content"
}

# --- trust: the refusals -----------------------------------------------------

test_primary_checkout_is_refused() {
  local rec out
  rec=$(make_case primary)
  read_case "$rec"
  out=$(run_trust "$AGY_HOME" "$PROJ" "$PROJ")
  expect_code 1 $? "the primary checkout must be refused: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  assert_not_trusted "$(store_path "$AGY_HOME")" "$PROJ" "the primary checkout was trusted"
  pass "fm-agy-trust.sh: refuses the primary checkout"
}

# CDPATH redirects a relative `cd` operand, and `git rev-parse --git-common-dir`
# answers `.git` for a primary checkout. With a decoy on CDPATH that also holds a
# `.git`, the common dir resolved for both arguments can land in the decoy
# instead, so the git-dir-vs-common-dir comparison would disagree and the primary
# checkout would be trusted.
test_cdpath_cannot_defeat_the_primary_checkout_refusal() {
  local rec out
  rec=$(make_case cdpath)
  read_case "$rec"
  mkdir -p "$CASE_DIR/decoy/.git"
  export CDPATH="$CASE_DIR/decoy"
  out=$(run_trust "$AGY_HOME" "$PROJ" "$PROJ")
  set -- $?
  unset CDPATH
  expect_code 1 "$1" "an exported CDPATH must not let the primary checkout through: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  assert_not_trusted "$(store_path "$AGY_HOME")" "$PROJ" "an exported CDPATH let the primary checkout be trusted"
  pass "fm-agy-trust.sh: an exported CDPATH cannot defeat the scope refusal"
}

# Git exports GIT_DIR into every hook environment, so an inherited pair is
# ordinary. With GIT_DIR naming a linked worktree's git dir and GIT_WORK_TREE
# naming the primary checkout, git reports a toplevel that matches the argument
# and a git dir that differs from the common dir, so the primary checkout would
# satisfy the refusal on the caller's environment rather than on disk.
test_git_env_overrides_cannot_defeat_the_primary_checkout_refusal() {
  local rec out
  rec=$(make_case gitenv)
  read_case "$rec"
  GIT_DIR=$(git -C "$WT" rev-parse --absolute-git-dir)
  GIT_WORK_TREE=$PROJ
  export GIT_DIR GIT_WORK_TREE
  out=$(run_trust "$AGY_HOME" "$PROJ" "$PROJ")
  set -- $?
  unset GIT_DIR GIT_WORK_TREE
  expect_code 1 "$1" "inherited git environment overrides must not let the primary checkout through: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  assert_not_trusted "$(store_path "$AGY_HOME")" "$PROJ" "inherited git environment overrides let the primary checkout be trusted"
  pass "fm-agy-trust.sh: inherited git environment overrides cannot defeat the scope refusal"
}

test_home_directory_is_refused_even_when_it_is_a_worktree() {
  local rec out home
  rec=$(make_case home-worktree)
  read_case "$rec"
  # Make HOME itself a linked worktree of the project, so every git check PASSES
  # and only the home guard can refuse it. Without this the home case would pass
  # vacuously through the "not inside a git repository" branch.
  home="$CASE_DIR/home-wt"
  git -C "$PROJ" worktree add --quiet -b wt-home "$home"
  out=$(run_trust "$home" "$home" "$PROJ")
  expect_code 1 $? "a home directory must be refused even as a valid worktree: $out"
  assert_contains "$out" "home directory" "the refusal did not name the home directory"
  assert_not_trusted "$(store_path "$home")" "$home" "the home directory was trusted"
  # Prove the git checks really would have accepted it, so the guard above is
  # what refused rather than an unrelated failure.
  out=$(run_trust "$AGY_HOME" "$home" "$PROJ")
  expect_code 0 $? "the same path must be acceptable once it is not HOME: $out"
  pass "fm-agy-trust.sh: refuses a home directory the git checks would accept"
}

test_settings_directory_is_refused() {
  local rec out settings_dir
  rec=$(make_case settings-dir)
  read_case "$rec"
  settings_dir="$AGY_HOME/.gemini/antigravity-cli"
  mkdir -p "$settings_dir"
  out=$(run_trust "$AGY_HOME" "$settings_dir" "$PROJ")
  expect_code 1 $? "the agy settings directory must be refused: $out"
  assert_contains "$out" "settings directory" "the refusal did not name the settings directory"
  pass "fm-agy-trust.sh: refuses the agy settings directory"
}

test_non_git_directory_is_refused() {
  local rec out plain
  rec=$(make_case plain)
  read_case "$rec"
  plain="$CASE_DIR/plain"
  mkdir -p "$plain"
  out=$(run_trust "$AGY_HOME" "$plain" "$PROJ")
  expect_code 1 $? "a plain directory must be refused: $out"
  assert_contains "$out" "not inside a git repository" "the refusal did not name the missing repository"
  assert_not_trusted "$(store_path "$AGY_HOME")" "$plain" "a plain directory was trusted"
  pass "fm-agy-trust.sh: refuses a directory that is not a git worktree"
}

test_missing_directory_is_refused() {
  local rec out
  rec=$(make_case missing)
  read_case "$rec"
  out=$(run_trust "$AGY_HOME" "$CASE_DIR/nope" "$PROJ")
  expect_code 1 $? "a nonexistent path must be refused: $out"
  assert_contains "$out" "not an accessible directory" "the refusal did not name the inaccessible path"
  pass "fm-agy-trust.sh: refuses a path that does not exist"
}

test_foreign_project_worktree_is_refused() {
  local rec out other other_wt
  rec=$(make_case foreign)
  read_case "$rec"
  other="$CASE_DIR/other-project"
  other_wt="$CASE_DIR/other-wt"
  fm_git_worktree "$other" "$other_wt" wt-other
  out=$(run_trust "$AGY_HOME" "$other_wt" "$PROJ")
  expect_code 1 $? "another project's worktree must be refused: $out"
  assert_contains "$out" "is not a worktree of project" "the refusal did not name the project mismatch"
  assert_not_trusted "$(store_path "$AGY_HOME")" "$other_wt" "a foreign project's worktree was trusted"
  pass "fm-agy-trust.sh: refuses a worktree belonging to another project"
}

test_worktree_subdirectory_is_refused() {
  local rec out sub
  rec=$(make_case subdir)
  read_case "$rec"
  sub="$WT/sub"
  mkdir -p "$sub"
  out=$(run_trust "$AGY_HOME" "$sub" "$PROJ")
  expect_code 1 $? "a subdirectory of the worktree must be refused: $out"
  assert_contains "$out" "is not a worktree root" "the refusal did not name the non-root path"
  assert_not_trusted "$(store_path "$AGY_HOME")" "$sub" "a worktree subdirectory was trusted"
  pass "fm-agy-trust.sh: refuses a subdirectory of the worktree"
}

test_symlinked_store_to_a_foreign_owned_target_is_refused() {
  local rec out store
  rec=$(make_case symlink-foreign)
  read_case "$rec"
  # Root owns /etc/passwd as a regular file on both Linux and macOS, so it stands
  # in for a store resolving outside this user's ownership. Running as root would
  # own it and make the refusal vacuous.
  if [ "$(id -u)" = 0 ]; then
    pass "fm-agy-trust.sh: refuses a store symlinked to another user's file (skipped as root)"
    return 0
  fi
  store=$(store_path "$AGY_HOME")
  mkdir -p "$(dirname "$store")"
  ln -s /etc/passwd "$store"
  out=$(run_trust "$AGY_HOME" "$WT" "$PROJ")
  expect_code 1 $? "a store resolving to another user's file must be refused: $out"
  assert_contains "$out" "not owned by this user" "the refusal did not name the ownership failure"
  assert_contains "$out" "/etc/passwd" "the refusal named the link rather than the resolved target it judged"
  pass "fm-agy-trust.sh: refuses a store symlinked to another user's file"
}

test_symlinked_store_to_an_owned_target_is_accepted() {
  local rec out target store
  rec=$(make_case symlink-owned)
  read_case "$rec"
  # The dotfile-manager and synced-folder layout: the store is a symlink whose
  # target this user owns, so it must be followed rather than refused, and the
  # link must survive so the layout keeps working.
  target="$CASE_DIR/dotfiles/settings.json"
  mkdir -p "$CASE_DIR/dotfiles"
  printf '%s\n' '{"enableTelemetry":true,"trustedWorkspaces":[]}' > "$target"
  store=$(store_path "$AGY_HOME")
  mkdir -p "$(dirname "$store")"
  ln -s "$target" "$store"
  out=$(run_trust "$AGY_HOME" "$WT" "$PROJ")
  expect_code 0 $? "a store symlinked to this user's own file must be accepted: $out"
  assert_trusted "$target" "$WT" "the trust did not land in the symlink's target"
  [ -L "$store" ] || fail "the store symlink was replaced by a regular file instead of followed"
  assert_store_value "$target" true "an unrelated key in the target was lost" enableTelemetry
  [ -z "$(find "$CASE_DIR/dotfiles" -maxdepth 1 -name '.settings.json.fm-trust.*' -print -quit)" ] \
    || fail "a temporary store file was left beside the resolved target"
  pass "fm-agy-trust.sh: follows a store symlink to this user's own file and leaves the link intact"
}

test_corrupt_store_fails_closed() {
  local rec out store
  rec=$(make_case corrupt)
  read_case "$rec"
  store=$(store_path "$AGY_HOME")
  mkdir -p "$(dirname "$store")"
  printf '%s\n' 'not json' > "$store"
  out=$(run_trust "$AGY_HOME" "$WT" "$PROJ")
  expect_code 1 $? "an unparseable store must be refused: $out"
  assert_grep 'not json' "$store" "the unparseable store was overwritten instead of left alone"
  pass "fm-agy-trust.sh: refuses an unparseable store and leaves it untouched"
}

# A non-array trustedWorkspaces is a store shape this does not own, so it is
# refused rather than replaced: overwriting would discard whatever agy meant by
# it, in a format firstmate has no claim over.
test_non_array_trusted_workspaces_fails_closed() {
  local rec out store
  rec=$(make_case non-array)
  read_case "$rec"
  store=$(store_path "$AGY_HOME")
  mkdir -p "$(dirname "$store")"
  printf '%s\n' '{"trustedWorkspaces":"/one/path"}' > "$store"
  out=$(run_trust "$AGY_HOME" "$WT" "$PROJ")
  expect_code 1 $? "a non-array trustedWorkspaces must be refused: $out"
  assert_grep '"/one/path"' "$store" "the unexpected store shape was overwritten instead of left alone"
  pass "fm-agy-trust.sh: refuses a non-array trustedWorkspaces and leaves it untouched"
}

# Registering trust is what keeps a worker off the dialog, so a missing node
# refuses rather than degrades: proceeding would launch the worker straight into
# the dialog this control exists to remove.
test_missing_node_is_refused() {
  local rec out bindir
  rec=$(make_case no-node)
  read_case "$rec"
  bindir=$(node_free_path "$CASE_DIR")
  out=$(PATH="$bindir" run_trust "$AGY_HOME" "$WT" "$PROJ")
  expect_code 1 $? "a missing node must refuse rather than let the spawn proceed: $out"
  assert_contains "$out" "node" "the refusal did not name the missing interpreter"
  assert_not_trusted "$(store_path "$AGY_HOME")" "$WT" "a worktree was trusted without an interpreter to write the store"
  case "$out" in
    *"trusted:"*) fail "a registration was claimed although none could be written: $out" ;;
  esac
  pass "fm-agy-trust.sh: a missing node is refused rather than degraded"
}

# A missing interpreter must not soften the scope boundary, which git and the
# filesystem decide on their own.
test_scope_refusal_stays_fail_closed_without_node() {
  local rec out bindir
  rec=$(make_case no-node-refusal)
  read_case "$rec"
  bindir=$(node_free_path "$CASE_DIR")
  out=$(PATH="$bindir" run_trust "$AGY_HOME" "$PROJ" "$PROJ")
  expect_code 1 $? "the primary checkout must still be refused without node: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  pass "fm-agy-trust.sh: a scope refusal stays fail-closed without node"
}

# fm-spawn runs from a live firstmate session that may itself be driving agy, so
# the store can be rewritten mid-registration. Losing the vendor's write would
# discard keys this does not own, so a store that moved is refused rather than
# clobbered.
#
# The race is driven deterministically rather than by a sleeping background
# writer: a preloaded module wraps fs.writeFileSync so that the moment the
# registration stages its temporary store - which is after it has read the
# original and before it re-checks the fingerprint - the real store is rewritten
# underneath it. That is the exact window the guard exists to catch, and it lands
# on every attempt, so the assertion cannot go flaky or vacuous.
test_concurrent_store_rewrite_is_refused_rather_than_clobbered() {
  local rec out store shim real_node inject
  rec=$(make_case concurrent)
  read_case "$rec"
  store=$(store_path "$AGY_HOME")
  mkdir -p "$(dirname "$store")"
  printf '%s\n' '{"enableTelemetry":false,"trustedWorkspaces":[]}' > "$store"
  real_node=$(command -v node) || fail "test needs node"
  shim="$CASE_DIR/shim"
  inject="$CASE_DIR/inject.js"
  mkdir -p "$shim"
  cat > "$inject" <<JS
const fs = require("node:fs");
const store = process.env.FM_TEST_AGY_STORE;
const original = fs.writeFileSync.bind(fs);
let n = 0;
fs.writeFileSync = (target, ...rest) => {
  const result = original(target, ...rest);
  if (typeof target === "string" && target.includes(".settings.json.fm-trust.")) {
    n += 1;
    original(store, JSON.stringify({ enableTelemetry: false, vendorKey: n, trustedWorkspaces: [] }, null, 2) + "\n");
  }
  return result;
};
JS
  cat > "$shim/node" <<SH
#!/usr/bin/env bash
exec "$real_node" --require "$inject" "\$@"
SH
  chmod +x "$shim/node"
  out=$(FM_TEST_AGY_STORE="$store" PATH="$shim:$PATH" run_trust "$AGY_HOME" "$WT" "$PROJ")
  expect_code 1 $? "a store rewritten under the registration must be refused: $out"
  assert_contains "$out" "modified while trust was being recorded" "the refusal did not name the concurrent modification"
  assert_grep 'vendorKey' "$store" "the concurrent writer's content was clobbered"
  assert_not_trusted "$store" "$WT" "a trust was recorded over a store that moved underneath it"
  [ -z "$(find "$(dirname "$store")" -maxdepth 1 -name '.settings.json.fm-trust.*' -print -quit)" ] \
    || fail "a staged store file was left behind after the refusal"
  pass "fm-agy-trust.sh: refuses a store modified under it rather than clobbering the vendor's write"
}

# --- turn-end hook -----------------------------------------------------------

run_hook_install() { HOME="$1" "$HOOK" install 2>&1; }
run_hook_remove() { HOME="$1" "$HOOK" remove 2>&1; }
hooks_config() { printf '%s/.gemini/config/hooks.json\n' "$1"; }
hook_script() { printf '%s/.gemini/antigravity-cli/fm-turn-end.sh\n' "$1"; }
hook_registry() { printf '%s/.gemini/antigravity-cli/fm-turn-end.d\n' "$1"; }

hook_payload() {  # <fully-idle> <workspace>
  printf '{"fullyIdle":%s,"workspacePaths":["%s"],"conversationId":"c1","terminationReason":"NO_TOOL_CALL"}' "$1" "$2"
}

test_hook_install_preserves_operator_hooks_and_remove_restores_them() {
  local rec out config
  rec=$(make_case hook-install)
  read_case "$rec"
  config=$(hooks_config "$AGY_HOME")
  mkdir -p "$(dirname "$config")"
  printf '%s\n' '{"operator-lint":{"PostToolUse":[]}}' > "$config"
  out=$(run_hook_install "$AGY_HOME")
  expect_code 0 $? "installing the turn-end hook must succeed: $out"
  assert_store_value "$config" '{"PostToolUse":[]}' "the operator's own hook was lost on install" operator-lint
  assert_store_value "$config" '"command"' "the firstmate hook was not installed as a command hook" \
    firstmate-turn-end Stop 0 type
  [ -x "$(hook_script "$AGY_HOME")" ] || fail "the hook script was not installed executable"
  out=$(run_hook_remove "$AGY_HOME")
  expect_code 0 $? "removing the turn-end hook must succeed: $out"
  assert_store_value "$config" '{"PostToolUse":[]}' "the operator's own hook was lost on remove" operator-lint
  assert_store_value "$config" undefined "the firstmate hook survived removal" firstmate-turn-end
  [ ! -e "$(hook_script "$AGY_HOME")" ] || fail "the hook script survived removal"
  [ ! -e "$(hook_registry "$AGY_HOME")" ] || fail "the token registry survived removal"
  pass "fm-agy-turnend-hook.sh: install and remove leave operator hooks untouched"
}

# THE fullyIdle GATE. agy backgrounds a command that outruns its own wait, yields
# the composer, and fires Stop with fullyIdle false while that command still
# runs. Touching the marker there would report a worker done while its own build
# is still going, so only fullyIdle true may signal a finished turn.
test_hook_signals_only_a_fully_idle_turn() {
  local rec marker token registry
  rec=$(make_case hook-fullyidle)
  read_case "$rec"
  run_hook_install "$AGY_HOME" >/dev/null || fail "install failed"
  registry=$(hook_registry "$AGY_HOME")
  marker="$CASE_DIR/task.turn-ended"
  token=fm.aaaaaaaaaaaa
  printf '%s\n' "$marker" > "$registry/$token"
  printf 'token=%s\n' "$token" > "$WT/.fm-agy-turnend"

  hook_payload false "$WT" | HOME="$AGY_HOME" bash "$(hook_script "$AGY_HOME")" >/dev/null
  [ ! -e "$marker" ] || fail "a Stop with fullyIdle false reported the turn finished"

  hook_payload true "$WT" | HOME="$AGY_HOME" bash "$(hook_script "$AGY_HOME")" >/dev/null
  [ -e "$marker" ] || fail "a Stop with fullyIdle true did not signal the finished turn"
  pass "fm-agy-turnend-hook.sh: signals only a fullyIdle turn end"
}

# The hook is global, so it must be inert for a workspace that is not a
# firstmate task: an unregistered token can never touch a marker.
test_hook_ignores_an_unregistered_token() {
  local rec marker
  rec=$(make_case hook-token)
  read_case "$rec"
  run_hook_install "$AGY_HOME" >/dev/null || fail "install failed"
  marker="$CASE_DIR/task.turn-ended"
  printf 'token=fm.zzzzzzzzzzzz\n' > "$WT/.fm-agy-turnend"
  hook_payload true "$WT" | HOME="$AGY_HOME" bash "$(hook_script "$AGY_HOME")" >/dev/null
  [ ! -e "$marker" ] || fail "an unregistered token signalled a turn end"
  pass "fm-agy-turnend-hook.sh: ignores a workspace whose token is not registered"
}

# The hook blocks agy's own loop, so it must always answer with valid JSON and
# exit zero even when it does nothing at all.
test_hook_always_answers_and_exits_zero() {
  local rec out
  rec=$(make_case hook-answer)
  read_case "$rec"
  run_hook_install "$AGY_HOME" >/dev/null || fail "install failed"
  out=$(printf 'not json at all' | HOME="$AGY_HOME" bash "$(hook_script "$AGY_HOME")")
  expect_code 0 $? "the hook must exit zero on an unparseable payload"
  [ "$out" = '{}' ] || fail "the hook answered '$out' rather than an empty JSON object"
  pass "fm-agy-turnend-hook.sh: always answers with {} and exits zero"
}

test_hook_remove_refuses_while_a_task_token_is_live() {
  local rec out
  rec=$(make_case hook-live-token)
  read_case "$rec"
  run_hook_install "$AGY_HOME" >/dev/null || fail "install failed"
  printf '%s\n' "$CASE_DIR/task.turn-ended" > "$(hook_registry "$AGY_HOME")/fm.bbbbbbbbbbbb"
  out=$(run_hook_remove "$AGY_HOME")
  expect_code 1 $? "removing the hook under a live task token must be refused: $out"
  assert_contains "$out" "still registered" "the refusal did not name the live token"
  [ -e "$(hook_script "$AGY_HOME")" ] || fail "the hook script was removed despite the refusal"
  pass "fm-agy-turnend-hook.sh: refuses removal while a task still expects a wake"
}

test_hook_refuses_a_malformed_config() {
  local rec out config
  rec=$(make_case hook-malformed)
  read_case "$rec"
  config=$(hooks_config "$AGY_HOME")
  mkdir -p "$(dirname "$config")"
  printf '%s\n' 'not json' > "$config"
  out=$(run_hook_install "$AGY_HOME")
  expect_code 1 $? "a malformed hooks config must be refused: $out"
  assert_grep 'not json' "$config" "the malformed config was overwritten instead of left alone"
  pass "fm-agy-turnend-hook.sh: refuses a malformed hooks config and leaves it untouched"
}

# The registry is created on the first install a box ever runs, and a captain can
# dispatch several agy crewmates at once. Losing that race must not refuse a
# spawn whose directory now exists and is correct.
test_concurrent_first_installs_all_succeed() {
  local round home failures
  for round in 1 2 3 4 5; do
    home="$TMP_ROOT/concurrent-install-$round"
    mkdir -p "$home"
    for _ in 1 2 3 4 5 6 7 8; do
      ( run_hook_install "$home" >/dev/null 2>&1 || printf 'x' >> "$home/failures" ) &
    done
    wait
    if [ -s "$home/failures" ]; then
      failures=$(wc -c < "$home/failures" | tr -d ' ')
      fail "$failures of 8 concurrent first installs were refused in round $round"
    fi
    assert_store_value "$(hooks_config "$home")" '"command"' \
      "a concurrent install round left no usable hook" firstmate-turn-end Stop 0 type
  done
  pass "fm-agy-turnend-hook.sh: concurrent first installs all succeed"
}

# The registry holds every live task's wake token, so its mode is a property of
# the install rather than of whoever happened to create the directory first.
test_install_normalizes_a_loose_registry_mode() {
  local rec mode
  rec=$(make_case loose-registry)
  read_case "$rec"
  mkdir -p "$AGY_HOME/.gemini/antigravity-cli/fm-turn-end.d"
  chmod 0755 "$AGY_HOME/.gemini/antigravity-cli/fm-turn-end.d"
  run_hook_install "$AGY_HOME" >/dev/null || fail "install failed against an existing registry"
  mode=$(stat -c %a "$AGY_HOME/.gemini/antigravity-cli/fm-turn-end.d" 2>/dev/null \
    || stat -f %Lp "$AGY_HOME/.gemini/antigravity-cli/fm-turn-end.d")
  [ "$mode" = 700 ] \
    || fail "the install left the registry world-readable (mode $mode)"
  pass "fm-agy-turnend-hook.sh: install narrows a loose registry directory mode"
}

# --- adapter tables ----------------------------------------------------------

# agy does NOT clear an inherited CLAUDECODE, so both markers can be present at
# once and whichever is tested first decides. Drive them apart deliberately: with
# both set the verdict must be agy, and removing agy's marker must flip it back
# to claude, so the case cannot pass vacuously.
test_detection_prefers_the_agy_marker_over_an_inherited_claudecode() {
  local verdict
  verdict=$(ANTIGRAVITY_CONVERSATION_ID=abc123 CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
  [ "$verdict" = agy ] || fail "an agy session carrying an inherited CLAUDECODE detected as '$verdict'"
  verdict=$(CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
  [ "$verdict" = claude ] || fail "removing agy's marker did not restore the claude verdict (got '$verdict')"
  pass "fm-harness.sh: agy's marker outranks an inherited CLAUDECODE"
}

test_control_tables_carry_agys_verified_mechanics() {
  # shellcheck source=bin/fm-control-lib.sh
  . "$ROOT/bin/fm-control-lib.sh"
  fm_control_harness_supported agy || fail "agy is not a supported control-plane harness"
  [ "$(fm_control_harness_family agy)" = agy ] || fail "agy does not resolve to its own adapter family"
  [ "$(fm_control_interrupt_key agy)" = Escape ] || fail "agy's interrupt key is not Escape"
  [ "$(fm_control_interrupt_repeat agy)" = 1 ] || fail "agy's interrupt is not a single press"
  [ -z "$(fm_control_interrupt_clear_key agy)" ] || fail "agy was given a composer clear key it does not need"
  [ "$(fm_control_exit_command agy)" = /exit ] || fail "agy's exit command is not /exit"
  fm_control_harness_supports_kind agy ship || fail "agy must be usable for a ship task"
  fm_control_harness_supports_kind agy scout || fail "agy must be usable for a scout task"
  ! fm_control_harness_supports_kind agy secondmate \
    || fail "agy was accepted for a secondmate despite having no primary supervision protocol"
  pass "fm-control-lib.sh: agy's verified control mechanics are registered"
}

test_delivery_guard_reads_agys_status_bar() {
  # shellcheck source=bin/fm-composer-lib.sh
  . "$ROOT/bin/fm-composer-lib.sh"
  printf '%s\n' '⣾  Editing files...' 'esc to cancel      Gemini 3.8 Flash · high' \
    | fm_busy_lines_match agy || fail "agy's busy status bar was not read as busy"
  printf '%s\n' '>' '? for shortcuts      Gemini 3.8 Flash · high' \
    | fm_busy_lines_match agy && fail "agy's idle status bar was read as busy"
  # A tool-permission prompt is NOT a pane that will accept a steer, and it
  # carries the same footer, so the guard must refuse it too.
  printf '%s\n' 'Do you want to proceed?' 'esc to cancel      Gemini 3.8 Flash · high' \
    | fm_busy_lines_match agy || fail "a pane parked on a permission prompt was read as free"
  pass "fm-composer-lib.sh: agy's delivery guard separates its two status bars"
}

# agy's composer is a bare `>` between rules, and the classifier's safety rule
# reads a bare shell glyph outside a bordered container as a dead shell prompt.
# The verdict is therefore `unknown`, never `empty`, which is the whole reason
# typed-submit confirmation is a tmux-only boundary for agy - the docs claim that
# scope, so the verdict it rests on is pinned here rather than assumed.
test_agy_composer_verdict_is_unknown_not_empty() {
  # shellcheck source=bin/fm-composer-lib.sh
  . "$ROOT/bin/fm-composer-lib.sh"
  local screen verdict
  screen=$(printf '%s\n' \
    '─────────────────────────────────────────' \
    '> ' \
    '─────────────────────────────────────────' \
    '? for shortcuts      Gemini 3.8 Flash · high')
  verdict=$(fm_composer_classify_screen "" "$screen" "" agy)
  [ "$verdict" = unknown ] \
    || fail "an empty agy composer classified '$verdict'; the documented tmux-only submit boundary rests on 'unknown'"
  pass "fm-composer-lib.sh: an empty agy composer classifies unknown, not empty"
}

test_spawn_refuses_a_secondmate_on_agy() {
  local case_dir home out
  case_dir="$TMP_ROOT/secondmate-refusal"
  home="$case_dir/home"
  fm_test_spawn_home "$home" agy
  out=$(fm_test_run_spawn "$home" "$case_dir/pane" "$(fm_fakebin "$case_dir/fake")" \
    --secondmate smtest "$home" agy 2>&1 || true)
  assert_contains "$out" "cannot run a secondmate" "a secondmate spawn on agy was not refused"
  # The documented two-positional form omits the firstmate home, so agy has to be
  # recognised as a harness name there too; unrecognised it binds as a home path
  # and the run dies pointing at a directory that was never named. The home here
  # is pinned to another harness so the refusal can only come from the positional
  # agy, not from a configured default that happens to be agy already.
  local other_home
  other_home="$case_dir/other-home"
  fm_test_spawn_home "$other_home" claude
  out=$(fm_test_run_spawn "$other_home" "$case_dir/pane" "$(fm_fakebin "$case_dir/fake")" \
    --secondmate smtest agy 2>&1 || true)
  assert_contains "$out" "cannot run a secondmate" \
    "the home-less secondmate form did not reach the agy adapter refusal"
  pass "fm-spawn.sh: refuses a secondmate launch on agy"
}

# agy's marker is tested BEFORE claude's, so an ANTIGRAVITY_CONVERSATION_ID that
# survives in the environment a non-agy worker is launched from would make that
# worker report itself as agy and misroute every crew and secondmate decision
# derived from it. The launch boundary is where the foreign marker is dropped.
test_a_non_agy_launch_clears_the_inherited_agy_marker() {
  local case_dir home proj wt fakebin launch_log out launch prefix verdict
  case_dir="$TMP_ROOT/marker-clear"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launch_log="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" wt-marker-clear
  fm_test_spawn_brief "$home" markerclear
  out=$(FM_FAKE_LAUNCH_LOG="$launch_log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" markerclear "$proj" claude \
    --mode no-mistakes --yolo off)
  expect_code 0 $? "the claude spawn must succeed: $out"
  assert_present "$launch_log" "the claude spawn sent no launch command"
  launch=$(head -1 "$launch_log")
  prefix=${launch%%claude *}
  [ "$prefix" != "$launch" ] || fail "the launch command did not invoke claude: $launch"
  # Run the launch command's own environment prefix over the detector: the
  # launched worker must self-identify as claude even when the pane it is
  # created from still carries an agy conversation id.
  verdict=$(ANTIGRAVITY_CONVERSATION_ID=abc123 CLAUDECODE=1 \
    eval "$prefix \"$ROOT/bin/fm-harness.sh\"")
  [ "$verdict" = claude ] \
    || fail "a claude worker launched under an inherited agy marker detected as '$verdict'"
  pass "fm-spawn.sh: a non-agy launch drops an inherited agy marker"
}

# The spawn half: a real fm-spawn of an agy worker must pre-register the
# worktree, install the turn-end hook, mint its task token, AND deliver the
# launch command carrying the brief, with no dialog to answer and no human.
test_agy_spawn_pretrusts_its_worktree_and_reaches_the_brief() {
  local case_dir home proj wt agyhome fakebin launch_log out
  case_dir="$TMP_ROOT/spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  # The spawn fixture pins HOME to $home/user-home so a trust pre-registration
  # cannot reach the developer's real store (tests/fixtures.sh), and that pin
  # beats an outer HOME= on the call. agy registers into the same sandboxed
  # HOME as claude, so the store this asserts against must be that one.
  agyhome="$home/user-home"
  launch_log="$case_dir/launch.log"
  mkdir -p "$agyhome"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" agy)
  fm_test_spawn_home "$home" agy
  fm_git_worktree "$proj" "$wt" wt-spawn
  fm_test_spawn_brief "$home" agyspawn
  out=$(HOME="$agyhome" FM_FAKE_LAUNCH_LOG="$launch_log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" agyspawn "$proj" agy \
    --mode no-mistakes --yolo off)
  expect_code 0 $? "the agy spawn must succeed: $out"
  assert_trusted "$(store_path "$agyhome")" "$wt" \
    "the agy spawn did not pre-register workspace trust for its worktree"
  assert_present "$launch_log" "the agy spawn sent no launch command"
  # -i starts an interactive session on the prompt; -p would run one turn and
  # exit, and every flag must precede the prompt or agy consumes the wrong one.
  assert_grep 'agy --dangerously-skip-permissions -i "' "$launch_log" \
    "the launch command was not the interactive agy worker launch"
  assert_grep "$home/data/agyspawn/launch-brief.md" "$launch_log" \
    "the launch command did not carry the brief the worker must read"
  # agy does not clear an inherited primary marker, so the launch must.
  assert_grep 'env -u CLAUDECODE' "$launch_log" \
    "the launch command did not clear the foreign primary markers"
  assert_store_value "$(hooks_config "$agyhome")" '"command"' \
    "the agy spawn did not install the turn-end hook" firstmate-turn-end Stop 0 type
  assert_grep 'token=fm.' "$wt/.fm-agy-turnend" \
    "the agy spawn did not leave a task token pointer in the worktree"
  # Teardown withdraws exactly what this record names, so a spawn that registers
  # without writing it would leave the entry with nothing to key the removal off.
  [ "$(head -1 "$home/state/agyspawn.agy-trust" 2>/dev/null)" = "$wt" ] \
    || fail "the agy spawn did not record the workspace trust it registered"
  pass "fm-spawn.sh: an agy spawn pre-trusts its worktree, arms its wake, and launches with the brief"
}

# The trust entry is written into the operator's vendor settings before the rest
# of the spawn can fail, and teardown - the only other withdrawal - refuses for an
# id that never published a task record. So an abort after a SUCCESSFUL
# registration has to take the entry back, or it is stranded with no supported
# command that can remove it. A malformed operator hooks config is the abort:
# the hook install refuses on it, one step after the registration.
test_aborted_spawn_withdraws_the_trust_it_registered() {
  local case_dir home proj wt agyhome fakebin store config out
  case_dir="$TMP_ROOT/aborted-spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  # The spawn fixture pins HOME to $home/user-home so a trust pre-registration
  # cannot reach the developer's real store (tests/fixtures.sh), and that pin
  # beats an outer HOME= on the call. agy registers into the same sandboxed
  # HOME as claude, so the store this asserts against must be that one.
  agyhome="$home/user-home"
  store=$(store_path "$agyhome")
  config=$(hooks_config "$agyhome")
  mkdir -p "$(dirname "$store")" "$(dirname "$config")"
  printf '%s\n' '{"enableTelemetry":false,"trustedWorkspaces":["/already/trusted"]}' > "$store"
  printf '%s\n' 'not json' > "$config"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" agy)
  fm_test_spawn_home "$home" agy
  fm_git_worktree "$proj" "$wt" wt-aborted
  fm_test_spawn_brief "$home" abortedspawn
  out=$(HOME="$agyhome" fm_test_run_spawn "$home" "$wt" "$fakebin" abortedspawn "$proj" agy \
    --mode no-mistakes --yolo off)
  expect_code 1 $? "a spawn whose hook install is refused must fail: $out"
  [ ! -e "$home/state/abortedspawn.meta" ] \
    || fail "the abort published a task record, so the leak this covers cannot happen"
  assert_not_trusted "$store" "$wt" "the aborted spawn stranded its workspace-trust entry"
  assert_trusted "$store" "/already/trusted" "the withdrawal dropped an unrelated operator entry"
  pass "fm-spawn.sh: a spawn that aborts after registering trust withdraws it again"
}

# The withdrawal is guarded on whether a task record survives, because a record
# is what lets teardown withdraw it later. An abort AFTER the provisional record
# is published still ends with no record - the fresh-commit rollback removes it -
# so the guard has to observe the state the cleanup LEAVES, not an intermediate
# one. An unsafe trace-context send is that abort: it fires after publication.
test_post_publish_abort_withdraws_the_trust_it_registered() {
  local case_dir home proj wt agyhome fakebin store out
  case_dir="$TMP_ROOT/post-publish-abort"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  # The spawn fixture pins HOME to $home/user-home so a trust pre-registration
  # cannot reach the developer's real store (tests/fixtures.sh), and that pin
  # beats an outer HOME= on the call. agy registers into the same sandboxed
  # HOME as claude, so the store this asserts against must be that one.
  agyhome="$home/user-home"
  store=$(store_path "$agyhome")
  mkdir -p "$(dirname "$store")"
  printf '%s\n' '{"enableTelemetry":false,"trustedWorkspaces":["/already/trusted"]}' > "$store"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" agy)
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    for a in "$@"; do
      case "$a" in
        "export TRACEPARENT="*) exit 2 ;;
      esac
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_test_spawn_home "$home" agy
  fm_git_worktree "$proj" "$wt" wt-post-publish
  fm_test_spawn_brief "$home" postpublish
  # The home's own frozen trace-context decision is what makes the spawn export a
  # carrier at all; the stub above then refuses that send unsafely.
  : > "$home/config/trace-context"
  printf '%s\n' "$$" > "$home/state/.lock"
  fm_trace_context_session_start "$home/config" "$home/state/.trace-context-effective"
  out=$(HOME="$agyhome" fm_test_run_spawn "$home" "$wt" "$fakebin" postpublish "$proj" agy \
    --mode no-mistakes --yolo off)
  expect_code 1 $? "an unsafe trace-context send must abort the spawn: $out"
  [ ! -e "$home/state/postpublish.meta" ] \
    || fail "the abort left a task record, so this case no longer covers the recordless leak"
  assert_not_trusted "$store" "$wt" "the post-publish abort stranded its workspace-trust entry"
  assert_trusted "$store" "/already/trusted" "the withdrawal dropped an unrelated operator entry"
  pass "fm-spawn.sh: an abort after the record is published still withdraws the trust it registered"
}

# The registration records both spellings of the worktree, and --remove can only
# re-derive that pair while the directory still resolves. An orca abort deletes
# the worktree before the cleanup runs, so a re-derived pair would collapse to
# the literal argument and leave the resolved spelling behind forever.
test_abort_withdraws_both_spellings_after_the_worktree_is_deleted() {
  local case_dir home proj wt agyhome fakebin store link wt_link wt_real out
  case_dir="$TMP_ROOT/abort-deleted-worktree"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  # The spawn fixture pins HOME to $home/user-home so a trust pre-registration
  # cannot reach the developer's real store (tests/fixtures.sh), and that pin
  # beats an outer HOME= on the call. agy registers into the same sandboxed
  # HOME as claude, so the store this asserts against must be that one.
  agyhome="$home/user-home"
  store=$(store_path "$agyhome")
  mkdir -p "$case_dir" "$(dirname "$store")"
  printf '%s\n' '{"enableTelemetry":false,"trustedWorkspaces":["/already/trusted"]}' > "$store"
  fm_test_spawn_home "$home" agy
  fm_git_worktree "$proj" "$wt" wt-abort-deleted
  fm_test_spawn_brief "$home" abortdeleted
  link="$TMP_ROOT/abort-deleted-link"
  ln -sfn "$case_dir" "$link"
  wt_link="$link/wt"
  wt_real=$(cd -P -- "$wt" && pwd -P)
  [ "$wt_link" != "$wt_real" ] || fail "the fixture did not produce two distinct spellings"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" agy)
  # The abort fires on the trace-context send, and the stub removes the worktree
  # first - the state an orca abort leaves behind when it reclaims the worktree.
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    for a in "\$@"; do
      case "\$a" in
        "export TRACEPARENT="*) rm -rf -- "$wt_real"; exit 2 ;;
      esac
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  : > "$home/config/trace-context"
  printf '%s\n' "$$" > "$home/state/.lock"
  fm_trace_context_session_start "$home/config" "$home/state/.trace-context-effective"
  out=$(HOME="$agyhome" fm_test_run_spawn "$home" "$wt_link" "$fakebin" abortdeleted "$proj" agy \
    --mode no-mistakes --yolo off)
  expect_code 1 $? "an unsafe trace-context send must abort the spawn: $out"
  [ ! -d "$wt_real" ] || fail "the fixture did not remove the worktree before the cleanup ran"
  [ ! -e "$home/state/abortdeleted.meta" ] \
    || fail "the abort left a task record, so this case no longer covers the recordless leak"
  assert_not_trusted "$store" "$wt_link" "the launch spelling survived the aborted spawn"
  assert_not_trusted "$store" "$wt_real" "the resolved spelling survived the aborted spawn"
  assert_trusted "$store" "/already/trusted" "the withdrawal dropped an unrelated operator entry"
  pass "fm-spawn.sh: an abort withdraws both trust spellings after the worktree is deleted"
}

# The store is the operator's own. If they trusted this worktree by hand, the
# spawn finds it already there and adds nothing, so it must not claim it: the
# record is what teardown withdraws, and taking their entry back would park their
# next hand-run agy on the dialog the whole control exists to remove.
test_spawn_does_not_claim_a_workspace_the_operator_already_trusted() {
  local case_dir home proj wt agyhome fakebin store out
  case_dir="$TMP_ROOT/operator-trusted"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  # The spawn fixture pins HOME to $home/user-home so a trust pre-registration
  # cannot reach the developer's real store (tests/fixtures.sh), and that pin
  # beats an outer HOME= on the call. agy registers into the same sandboxed
  # HOME as claude, so the store this asserts against must be that one.
  agyhome="$home/user-home"
  store=$(store_path "$agyhome")
  mkdir -p "$agyhome"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" agy)
  fm_test_spawn_home "$home" agy
  fm_git_worktree "$proj" "$wt" wt-operator-trusted
  fm_test_spawn_brief "$home" operatortrusted
  # The operator's own trust for this exact path, made before any task ran here.
  HOME="$agyhome" "$TRUST" "$wt" "$proj" >/dev/null \
    || fail "the fixture could not record the operator's own trust"
  out=$(HOME="$agyhome" fm_test_run_spawn "$home" "$wt" "$fakebin" operatortrusted "$proj" agy \
    --mode no-mistakes --yolo off)
  expect_code 0 $? "the agy spawn must succeed against an already-trusted worktree: $out"
  assert_trusted "$store" "$wt" "the spawn disturbed the operator's own trust entry"
  [ ! -e "$home/state/operatortrusted.agy-trust" ] \
    || fail "the spawn claimed a workspace the operator had already trusted: $(cat "$home/state/operatortrusted.agy-trust")"
  pass "fm-spawn.sh: a spawn into an already-trusted worktree claims no registration of its own"
}

# A refused registration must abort the spawn before any task state exists: the
# busy-state generation is armed later in the same run and nothing between would
# clear it, so a record stranded here would read as a task busy forever for an id
# that has no metadata at all.
test_refused_spawn_leaves_no_task_state() {
  local case_dir home proj wt agyhome fakebin out
  case_dir="$TMP_ROOT/refused-spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  # The spawn fixture pins HOME to $home/user-home so a trust pre-registration
  # cannot reach the developer's real store (tests/fixtures.sh), and that pin
  # beats an outer HOME= on the call. agy registers into the same sandboxed
  # HOME as claude, so the store this asserts against must be that one.
  agyhome="$home/user-home"
  # Root owns /etc/passwd, so a store resolving to it is refused as another
  # user's file. Running as root would own it and make the refusal vacuous.
  if [ "$(id -u)" = 0 ]; then
    pass "fm-spawn.sh: a trust-refused agy spawn leaves no task state (skipped as root)"
    return 0
  fi
  mkdir -p "$agyhome/.gemini/antigravity-cli"
  ln -s /etc/passwd "$(store_path "$agyhome")"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" agy)
  fm_test_spawn_home "$home" agy
  fm_git_worktree "$proj" "$wt" wt-refused
  fm_test_spawn_brief "$home" refusedspawn
  out=$(HOME="$agyhome" fm_test_run_spawn "$home" "$wt" "$fakebin" refusedspawn "$proj" agy \
    --mode no-mistakes --yolo off)
  expect_code 1 $? "a spawn whose trust registration is refused must fail: $out"
  assert_contains "$out" "workspace trust" "the spawn did not report the trust refusal"
  [ ! -e "$home/state/refusedspawn.busy-state" ] \
    || fail "a refused spawn stranded a busy record nothing can clear"
  [ ! -e "$home/state/refusedspawn.busy-gen" ] \
    || fail "a refused spawn stranded a busy generation nothing can clear"
  [ ! -e "$wt/.fm-agy-turnend" ] \
    || fail "a refused spawn left a task token pointer in the worktree"
  pass "fm-spawn.sh: a trust-refused agy spawn leaves no task state behind"
}

test_fresh_worktree_is_trusted
test_symlinked_worktree_spelling_is_trusted_too
test_removal_withdraws_the_spelling_it_is_named_and_keeps_the_rest
test_removal_leaves_the_operator_spelling_of_the_same_directory
test_removal_of_an_unregistered_path_writes_nothing
test_removal_without_a_store_creates_nothing
test_removal_works_after_the_worktree_is_gone
test_registration_is_idempotent
test_registration_reports_only_what_it_added
test_unrelated_store_content_is_preserved
test_primary_checkout_is_refused
test_cdpath_cannot_defeat_the_primary_checkout_refusal
test_git_env_overrides_cannot_defeat_the_primary_checkout_refusal
test_home_directory_is_refused_even_when_it_is_a_worktree
test_settings_directory_is_refused
test_non_git_directory_is_refused
test_missing_directory_is_refused
test_foreign_project_worktree_is_refused
test_worktree_subdirectory_is_refused
test_symlinked_store_to_a_foreign_owned_target_is_refused
test_symlinked_store_to_an_owned_target_is_accepted
test_corrupt_store_fails_closed
test_non_array_trusted_workspaces_fails_closed
test_missing_node_is_refused
test_scope_refusal_stays_fail_closed_without_node
test_concurrent_store_rewrite_is_refused_rather_than_clobbered
test_hook_install_preserves_operator_hooks_and_remove_restores_them
test_hook_signals_only_a_fully_idle_turn
test_hook_ignores_an_unregistered_token
test_hook_always_answers_and_exits_zero
test_hook_remove_refuses_while_a_task_token_is_live
test_hook_refuses_a_malformed_config
test_concurrent_first_installs_all_succeed
test_install_normalizes_a_loose_registry_mode
test_detection_prefers_the_agy_marker_over_an_inherited_claudecode
test_control_tables_carry_agys_verified_mechanics
test_delivery_guard_reads_agys_status_bar
test_agy_composer_verdict_is_unknown_not_empty
test_spawn_refuses_a_secondmate_on_agy
test_a_non_agy_launch_clears_the_inherited_agy_marker
test_agy_spawn_pretrusts_its_worktree_and_reaches_the_brief
test_refused_spawn_leaves_no_task_state
test_spawn_does_not_claim_a_workspace_the_operator_already_trusted
test_aborted_spawn_withdraws_the_trust_it_registered
test_post_publish_abort_withdraws_the_trust_it_registered
test_abort_withdraws_both_spellings_after_the_worktree_is_deleted
