#!/usr/bin/env bash
# Behavior tests for bin/fm-kimi-trust.sh, the spawn-time pre-registration of a
# task worktree in Kimi Code's own per-root workspace-trust store.
#
# Both halves of the contract are proven through the executable: a legitimate
# fresh linked worktree gets exactly the record Kimi itself would write (the
# name Kimi derives from the path, the one-line JSON body, the 0600 file in a
# 0700 directory), a repeat is a success that leaves the record alone, every
# unrelated record survives byte for byte, and every out-of-scope path is
# REFUSED rather than warned about or quietly skipped. The spawn wiring that
# calls this helper is proven in tests/fm-kimi-harness.test.sh beside the rest
# of the adapter, and tests/fm-kimi-trust-live-e2e.test.sh proves against the
# installed Kimi that the record actually removes the dialog.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-kimi-trust)

TRUST="$ROOT/bin/fm-kimi-trust.sh"

if command -v sha256sum >/dev/null 2>&1; then SHA256=sha256sum; else SHA256="shasum -a 256"; fi

# sha12 <string>: the first 12 hex characters of the SHA-256 of the string with
# no trailing newline, computed here independently of the helper's own writer.
sha12() { printf '%s' "$1" | $SHA256 | cut -c1-12; }

real_path() { (cd -P -- "$1" && pwd -P); }

file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# make_case <name> [worktree-basename]: a project with one linked worktree plus
# an isolated HOME whose .kimi-code the helper may create. Echoes
# "<case>|<proj>|<wt>|<home>".
make_case() {
  local name=$1 wt_name=${2:-wt} case_dir proj wt home
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  wt="$case_dir/$wt_name"
  home="$case_dir/home"
  mkdir -p "$home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s|%s|%s|%s\n' "$case_dir" "$proj" "$wt" "$home"
}

read_case() {
  IFS='|' read -r CASE_DIR PROJ WT HOME_DIR <<EOF2
$1
EOF2
}

# run_trust <home> <worktree> <project>: invoke against the isolated HOME with
# any developer KIMI_CODE_HOME cleared, so the store under test is the one the
# spawn's launch would read.
run_trust() {
  local home=$1 wt=$2 proj=$3
  env -u KIMI_CODE_HOME HOME="$home" "$TRUST" "$wt" "$proj" 2>&1
}

store_of() {  # <home>
  printf '%s/.kimi-code/workspace-trust\n' "$1"
}

# record_for <home> <slug> <path>: the record Kimi would look up for <path>,
# whose basename slugifies to <slug>.
record_for() {
  printf '%s/wd_%s_%s\n' "$(store_of "$1")" "$2" "$(sha12 "$3")"
}

# assert_record <file> <root> <msg>: a regular 0600 file holding exactly one
# line of JSON of the shape Kimi writes - {"root":"<root>","trustedAt":<ms>} -
# with no trailing newline.
assert_record() {
  local file=$1 root=$2 msg=$3 body last
  [ -f "$file" ] || fail "$msg (no record at $file)"
  [ ! -L "$file" ] || fail "$msg ($file is a symlink)"
  [ "$(file_mode "$file")" = 600 ] || fail "$msg (mode $(file_mode "$file"), expected 600)"
  body=$(cat "$file")
  case "$body" in
    '{"root":"'"$root"'","trustedAt":'*'}') ;;
    *) fail "$msg (unexpected record body: $body)" ;;
  esac
  body=${body#*\"trustedAt\":}
  body=${body%\}}
  case "$body" in
    ''|*[!0-9]*) fail "$msg (trustedAt is not epoch milliseconds: $body)" ;;
  esac
  last=$(tail -c 1 "$file")
  [ "$last" = '}' ] || fail "$msg (record does not end at the closing brace; Kimi writes no trailing newline)"
  [ "$(wc -l < "$file" | tr -d ' ')" = 0 ] || fail "$msg (record spans more than one line)"
}

assert_no_temp_files() {  # <home> <msg>
  [ -z "$(find "$(store_of "$1")" -name '.*fm-trust*' -print -quit 2>/dev/null)" ] || fail "$2"
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
  local rec out wt_real record
  rec=$(make_case fresh)
  read_case "$rec"
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "a fresh linked worktree must be trusted: $out"
  wt_real=$(real_path "$WT")
  [ "$out" = "trusted: $wt_real" ] || fail "registration did not report the one trusted line: $out"
  record=$(record_for "$HOME_DIR" wt "$wt_real")
  assert_record "$record" "$wt_real" "the worktree record is not the one Kimi looks up"
  [ "$(file_mode "$HOME_DIR/.kimi-code")" = 700 ] \
    || fail "a Kimi home created by the helper is not mode 700"
  [ "$(file_mode "$(store_of "$HOME_DIR")")" = 700 ] \
    || fail "the trust store directory created by the helper is not mode 700"
  assert_no_temp_files "$HOME_DIR" "a temporary record was left behind in the store"
  pass "fm-kimi-trust.sh: a fresh task worktree is trusted with exactly Kimi's record"
}

# The record name is derived from the path the way Kimi derives it: the last
# segment lowercased, runs outside [a-z0-9._-] collapsed to one dash, leading
# and trailing dashes stripped, cut to 40 characters and stripped again, with
# "workspace" standing in for an empty slug, then the SHA-256 prefix of the
# whole path. Each case names the slug it expects; the hash is computed here.
test_record_names_follow_kimi_slug_rules() {
  local name slug rec out wt_real
  while IFS='|' read -r name slug; do
    [ -n "$name" ] || continue
    rec=$(make_case "slug-$slug" "$name")
    read_case "$rec"
    out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
    expect_code 0 $? "worktree '$name' must be trusted: $out"
    wt_real=$(real_path "$WT")
    assert_record "$(record_for "$HOME_DIR" "$slug" "$wt_real")" "$wt_real" \
      "worktree '$name' was not recorded under slug '$slug'"
    [ "$(find "$(store_of "$HOME_DIR")" -type f | wc -l | tr -d ' ')" = 1 ] \
      || fail "worktree '$name' produced more than one record"
  done <<'CASES'
neuronet.com|neuronet.com
My Repo (2)!|my-repo-2
UPPER_case.v2|upper_case.v2
ünïcode-répo|n-code-r-po
--leading-and-trailing--|leading-and-trailing
abcdefghijabcdefghijabcdefghijabcdefghijklmno|abcdefghijabcdefghijabcdefghijabcdefghij
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-b|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
***|workspace
CASES
  pass "fm-kimi-trust.sh: record names follow Kimi's slug and hash derivation"
}

test_registration_is_idempotent() {
  local rec out wt_real record before after
  rec=$(make_case idempotent)
  read_case "$rec"
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "first registration must succeed: $out"
  wt_real=$(real_path "$WT")
  record=$(record_for "$HOME_DIR" wt "$wt_real")
  before=$(cat "$record")
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "repeat registration must succeed, not report a duplicate: $out"
  [ "$out" = "trusted: $wt_real" ] || fail "repeat registration did not report success: $out"
  after=$(cat "$record")
  [ "$before" = "$after" ] || fail "repeat registration rewrote an already trusted record (trustedAt changed)"
  [ "$(find "$(store_of "$HOME_DIR")" -type f | wc -l | tr -d ' ')" = 1 ] \
    || fail "repeat registration added a second record"
  pass "fm-kimi-trust.sh: registering an already trusted worktree is a success that leaves the record alone"
}

# The store is one file per root, and the other files in it are Kimi's own
# records for the operator's other folders. Every one of them, and anything
# else in the directory, must survive byte for byte.
test_unrelated_records_are_preserved() {
  local rec out store wt_real
  rec=$(make_case preserve)
  read_case "$rec"
  store=$(store_of "$HOME_DIR")
  mkdir -p "$store"
  printf '%s' '{"root":"/home/bemsas","trustedAt":1789669271066}' > "$store/wd_bemsas_495d3edf4d70"
  printf '%s' '{"root":"/somewhere/else","trustedAt":1}' > "$store/wd_else_000000000000"
  printf 'not a record\n' > "$store/stray.txt"
  cp "$store/wd_bemsas_495d3edf4d70" "$CASE_DIR/bemsas.before"
  cp "$store/wd_else_000000000000" "$CASE_DIR/else.before"
  cp "$store/stray.txt" "$CASE_DIR/stray.before"
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "registration beside existing records must succeed: $out"
  wt_real=$(real_path "$WT")
  assert_record "$(record_for "$HOME_DIR" wt "$wt_real")" "$wt_real" "the worktree was not recorded beside the existing records"
  cmp -s "$store/wd_bemsas_495d3edf4d70" "$CASE_DIR/bemsas.before" \
    || fail "an unrelated record for the home directory was rewritten"
  cmp -s "$store/wd_else_000000000000" "$CASE_DIR/else.before" \
    || fail "an unrelated record was rewritten"
  cmp -s "$store/stray.txt" "$CASE_DIR/stray.before" \
    || fail "an unrelated file in the store was rewritten"
  [ "$(find "$store" -type f | wc -l | tr -d ' ')" = 4 ] \
    || fail "the store holds something other than the three seeded files plus the new record"
  pass "fm-kimi-trust.sh: every unrelated record in the store is preserved byte for byte"
}

# Kimi treats a record that does not decode as JSON as untrusted (its read
# fails and the dialog shows), and overwrites exactly that file when the dialog
# is answered, so the helper replaces it rather than reporting trust that Kimi
# would not honour.
test_corrupt_record_for_the_worktree_is_replaced() {
  local rec out wt_real record
  rec=$(make_case corrupt)
  read_case "$rec"
  wt_real=$(real_path "$WT")
  record=$(record_for "$HOME_DIR" wt "$wt_real")
  mkdir -p "$(store_of "$HOME_DIR")"
  printf 'garbage' > "$record"
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "a corrupt record for the worktree must be replaced: $out"
  assert_record "$record" "$wt_real" "the corrupt record was not replaced with a readable one"
  pass "fm-kimi-trust.sh: a record Kimi could not decode is replaced"
}

# A symlink where the record belongs is a way to make some other file stand in
# for it, so it is refused rather than followed or replaced.
test_symlinked_record_is_refused() {
  local rec out wt_real record
  rec=$(make_case symlinked-record)
  read_case "$rec"
  wt_real=$(real_path "$WT")
  record=$(record_for "$HOME_DIR" wt "$wt_real")
  mkdir -p "$(store_of "$HOME_DIR")"
  printf 'target\n' > "$CASE_DIR/target"
  ln -s "$CASE_DIR/target" "$record"
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 1 $? "a symlinked record must be refused: $out"
  assert_contains "$out" "symlink" "the refusal did not name the symlink"
  [ -L "$record" ] || fail "the symlink was replaced"
  [ "$(cat "$CASE_DIR/target")" = target ] || fail "the symlink target was written through"
  case "$out" in *"trusted:"*) fail "a registration was claimed although it was refused: $out" ;; esac
  pass "fm-kimi-trust.sh: a symlink in the record's place is refused"
}

# Kimi hashes the pane's physical working directory, so a worktree reached
# through a symlink is resolved first and gets exactly one record - the one
# Kimi looks up - and no second record under the unresolved path.
test_symlinked_worktree_path_registers_the_resolved_root_only() {
  local rec out wt_real link
  rec=$(make_case symlinked-path)
  read_case "$rec"
  wt_real=$(real_path "$WT")
  link="$CASE_DIR/link"
  ln -s "$WT" "$link"
  out=$(run_trust "$HOME_DIR" "$link" "$PROJ")
  expect_code 0 $? "a worktree reached through a symlink must be trusted: $out"
  [ "$out" = "trusted: $wt_real" ] || fail "registration did not report the resolved path: $out"
  assert_record "$(record_for "$HOME_DIR" wt "$wt_real")" "$wt_real" "the resolved path was not recorded"
  [ ! -e "$(record_for "$HOME_DIR" link "$link")" ] \
    || fail "a second record was written for the unresolved path, which Kimi never looks up"
  [ "$(find "$(store_of "$HOME_DIR")" -type f | wc -l | tr -d ' ')" = 1 ] \
    || fail "the store holds more than the one record this registration needs"
  pass "fm-kimi-trust.sh: a symlinked worktree path records only the resolved root"
}

test_kimi_code_home_is_honoured_when_absolute() {
  local rec out wt_real custom
  rec=$(make_case kimi-code-home)
  read_case "$rec"
  custom="$CASE_DIR/custom-kimi-home"
  out=$(KIMI_CODE_HOME="$custom" HOME="$HOME_DIR" "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 0 $? "an absolute KIMI_CODE_HOME must select the store: $out"
  wt_real=$(real_path "$WT")
  assert_record "$custom/workspace-trust/wd_wt_$(sha12 "$wt_real")" "$wt_real" \
    "the record did not land in the KIMI_CODE_HOME store"
  [ ! -e "$HOME_DIR/.kimi-code" ] || fail "the default store was written although KIMI_CODE_HOME named another"
  pass "fm-kimi-trust.sh: an absolute KIMI_CODE_HOME selects the store Kimi itself would read"
}

test_relative_kimi_code_home_is_refused() {
  local rec out
  rec=$(make_case relative-kimi-code-home)
  read_case "$rec"
  out=$(KIMI_CODE_HOME=relative-home HOME="$HOME_DIR" "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 1 $? "a relative KIMI_CODE_HOME must be refused: $out"
  assert_contains "$out" "relative path" "the refusal did not name the relative value"
  [ ! -e "$HOME_DIR/.kimi-code" ] && [ ! -e "$CASE_DIR/relative-home" ] && [ ! -e "$ROOT/relative-home" ] \
    || fail "a store was written for a relative KIMI_CODE_HOME"
  pass "fm-kimi-trust.sh: a relative KIMI_CODE_HOME is refused rather than guessed at"
}

test_primary_checkout_is_refused() {
  local rec out
  rec=$(make_case primary)
  read_case "$rec"
  out=$(run_trust "$HOME_DIR" "$PROJ" "$PROJ")
  expect_code 1 $? "the primary checkout must be refused: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  [ ! -e "$(record_for "$HOME_DIR" project "$(real_path "$PROJ")")" ] || fail "the primary checkout was trusted"
  pass "fm-kimi-trust.sh: refuses the primary checkout"
}

# CDPATH redirects a relative `cd` operand, and `git rev-parse --git-common-dir`
# answers `.git` for a primary checkout, so a decoy on CDPATH holding a `.git`
# could make the common dir resolve elsewhere and the refusal disagree.
test_cdpath_cannot_defeat_the_primary_checkout_refusal() {
  local rec out
  rec=$(make_case cdpath)
  read_case "$rec"
  mkdir -p "$CASE_DIR/decoy/.git"
  export CDPATH="$CASE_DIR/decoy"
  out=$(run_trust "$HOME_DIR" "$PROJ" "$PROJ")
  set -- $?
  unset CDPATH
  expect_code 1 "$1" "an exported CDPATH must not let the primary checkout through: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  pass "fm-kimi-trust.sh: an exported CDPATH cannot defeat the scope refusal"
}

# Git exports GIT_DIR into every hook environment, so an inherited pair is
# ordinary; with GIT_DIR naming the linked worktree's git dir and GIT_WORK_TREE
# the primary checkout, git would report the primary checkout as a worktree.
test_git_env_overrides_cannot_defeat_the_primary_checkout_refusal() {
  local rec out
  rec=$(make_case gitenv)
  read_case "$rec"
  GIT_DIR=$(git -C "$WT" rev-parse --absolute-git-dir)
  GIT_WORK_TREE=$PROJ
  export GIT_DIR GIT_WORK_TREE
  out=$(run_trust "$HOME_DIR" "$PROJ" "$PROJ")
  set -- $?
  unset GIT_DIR GIT_WORK_TREE
  expect_code 1 "$1" "inherited git environment overrides must not let the primary checkout through: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  pass "fm-kimi-trust.sh: inherited git environment overrides cannot defeat the scope refusal"
}

test_home_directory_is_refused_even_when_it_is_a_worktree() {
  local rec out
  rec=$(make_case home)
  read_case "$rec"
  out=$(run_trust "$WT" "$WT" "$PROJ")
  expect_code 1 $? "the home directory must be refused even as a linked worktree: $out"
  assert_contains "$out" "home directory" "the refusal did not name the home directory"
  [ ! -e "$WT/.kimi-code/workspace-trust" ] || fail "the home directory was trusted"
  pass "fm-kimi-trust.sh: refuses the home directory"
}

test_kimi_home_is_refused() {
  local rec out
  rec=$(make_case kimi-home)
  read_case "$rec"
  out=$(KIMI_CODE_HOME="$WT" HOME="$HOME_DIR" "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 1 $? "the Kimi home itself must be refused: $out"
  assert_contains "$out" "Kimi home directory" "the refusal did not name the Kimi home"
  [ ! -e "$WT/workspace-trust" ] || fail "the Kimi home was trusted as a worktree"
  pass "fm-kimi-trust.sh: refuses the Kimi home directory"
}

test_non_git_directory_is_refused() {
  local rec out
  rec=$(make_case plain)
  read_case "$rec"
  mkdir -p "$CASE_DIR/plain"
  out=$(run_trust "$HOME_DIR" "$CASE_DIR/plain" "$PROJ")
  expect_code 1 $? "a plain directory must be refused: $out"
  assert_contains "$out" "not inside a git repository" "the refusal did not name the missing repository"
  [ ! -e "$HOME_DIR/.kimi-code/workspace-trust" ] || fail "a plain directory was trusted"
  pass "fm-kimi-trust.sh: refuses a directory that is not a git worktree"
}

test_missing_directory_is_refused() {
  local rec out
  rec=$(make_case missing)
  read_case "$rec"
  out=$(run_trust "$HOME_DIR" "$CASE_DIR/absent" "$PROJ")
  expect_code 1 $? "a missing directory must be refused: $out"
  assert_contains "$out" "not an accessible directory" "the refusal did not name the missing directory"
  pass "fm-kimi-trust.sh: refuses a missing directory"
}

test_foreign_project_worktree_is_refused() {
  local rec out other_rec
  rec=$(make_case foreign)
  read_case "$rec"
  other_rec=$(make_case foreign-other)
  out=$(run_trust "$HOME_DIR" "$WT" "$(printf '%s' "$other_rec" | cut -d'|' -f2)")
  expect_code 1 $? "a worktree of another project must be refused: $out"
  assert_contains "$out" "not a worktree of project" "the refusal did not name the project mismatch"
  [ ! -e "$HOME_DIR/.kimi-code/workspace-trust" ] || fail "a foreign worktree was trusted"
  pass "fm-kimi-trust.sh: refuses a worktree that belongs to a different project"
}

test_worktree_subdirectory_is_refused() {
  local rec out
  rec=$(make_case subdir)
  read_case "$rec"
  mkdir -p "$WT/sub"
  out=$(run_trust "$HOME_DIR" "$WT/sub" "$PROJ")
  expect_code 1 $? "a subdirectory of a worktree must be refused: $out"
  assert_contains "$out" "not a worktree root" "the refusal did not name the worktree root"
  [ ! -e "$HOME_DIR/.kimi-code/workspace-trust" ] || fail "a worktree subdirectory was trusted"
  pass "fm-kimi-trust.sh: refuses a subdirectory of a worktree"
}

test_store_directory_that_is_a_file_is_refused() {
  local rec out
  rec=$(make_case store-file)
  read_case "$rec"
  mkdir -p "$HOME_DIR/.kimi-code"
  : > "$HOME_DIR/.kimi-code/workspace-trust"
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 1 $? "a store that is not a directory must be refused: $out"
  assert_contains "$out" "not a directory" "the refusal did not name the store shape"
  [ -f "$HOME_DIR/.kimi-code/workspace-trust" ] || fail "the file in the store's place was replaced"
  pass "fm-kimi-trust.sh: refuses a store that cannot be written"
}

test_missing_node_is_refused() {
  local rec out bindir
  rec=$(make_case no-node)
  read_case "$rec"
  bindir=$(node_free_path "$CASE_DIR")
  out=$(PATH="$bindir" run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 1 $? "a missing node must refuse rather than let the spawn proceed: $out"
  assert_contains "$out" "node" "the refusal did not name the missing interpreter"
  [ ! -e "$(record_for "$HOME_DIR" wt "$(real_path "$WT")")" ] \
    || fail "a worktree was trusted without an interpreter to write the record"
  case "$out" in *"trusted:"*) fail "a registration was claimed although none could be written: $out" ;; esac
  pass "fm-kimi-trust.sh: a missing node is refused rather than degraded"
}

test_scope_refusal_stays_fail_closed_without_node() {
  local rec out bindir
  rec=$(make_case no-node-refusal)
  read_case "$rec"
  bindir=$(node_free_path "$CASE_DIR")
  out=$(PATH="$bindir" run_trust "$HOME_DIR" "$PROJ" "$PROJ")
  expect_code 1 $? "the primary checkout must still be refused without node: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  pass "fm-kimi-trust.sh: a scope refusal stays fail-closed without node"
}

test_usage_is_refused_without_both_arguments() {
  local out
  out=$("$TRUST" 2>&1)
  expect_code 2 $? "no arguments must print usage: $out"
  assert_contains "$out" "usage:" "no usage line was printed"
  out=$("$TRUST" "$TMP_ROOT" 2>&1)
  expect_code 2 $? "one argument must print usage: $out"
  pass "fm-kimi-trust.sh: refuses anything but exactly two arguments"
}

test_fresh_worktree_is_trusted
test_record_names_follow_kimi_slug_rules
test_registration_is_idempotent
test_unrelated_records_are_preserved
test_corrupt_record_for_the_worktree_is_replaced
test_symlinked_record_is_refused
test_symlinked_worktree_path_registers_the_resolved_root_only
test_kimi_code_home_is_honoured_when_absolute
test_relative_kimi_code_home_is_refused
test_primary_checkout_is_refused
test_cdpath_cannot_defeat_the_primary_checkout_refusal
test_git_env_overrides_cannot_defeat_the_primary_checkout_refusal
test_home_directory_is_refused_even_when_it_is_a_worktree
test_kimi_home_is_refused
test_non_git_directory_is_refused
test_missing_directory_is_refused
test_foreign_project_worktree_is_refused
test_worktree_subdirectory_is_refused
test_store_directory_that_is_a_file_is_refused
test_missing_node_is_refused
test_scope_refusal_stays_fail_closed_without_node
test_usage_is_refused_without_both_arguments
