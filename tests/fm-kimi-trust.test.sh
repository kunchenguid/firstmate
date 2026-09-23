#!/usr/bin/env bash
# Behavior tests for bin/fm-kimi-trust.sh, the Kimi Code workspace-trust
# pre-registration a kimi spawn runs before launch.
#
# Two halves of the contract are load-bearing and both are proven here. The
# WORKSPACE ID is Kimi's own derivation from the launch directory's resolved
# path, and it is the whole lookup key - a record under any other name grants no
# trust - so the slug cases below pin every step of that rule against the values
# the installed Kimi Code 2.0.2 was observed to produce (docs/verification/kimi.md
# owns that evidence). The SCOPE TEST is the safety property: a legitimate fresh
# task worktree and a seeded secondmate home are registered so the worker reaches
# its brief or charter with no human, and every out-of-scope path, malformed
# store, and already-decided record is REFUSED or left alone rather than
# overwritten.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# A captain running several Kimi accounts exports this to pick one. Inherited
# into the suite it would send every fixture registration into that real home,
# so the value is dropped and each case names its own isolated home instead.
unset KIMI_CODE_HOME

TMP_ROOT=$(fm_test_tmproot fm-kimi-trust)

TRUST="$ROOT/bin/fm-kimi-trust.sh"

# The 12 hex characters Kimi takes from the sha256 of the resolved absolute path.
# Computed with shasum rather than node so the expectation does not come from the
# same implementation the subject uses.
path_hash12() {  # <absolute-path>
  local out
  if command -v shasum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | shasum -a 256) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | sha256sum) || return 1
  else
    fail "test needs shasum or sha256sum"
  fi
  printf '%s\n' "${out:0:12}"
}

# make_case <name>: a project with one linked worktree plus an isolated Kimi home
# and a fake HOME, so nothing resolves to the operator's own store. Echoes
# "<case>|<proj>|<wt>|<kimi-home>|<fake-home>".
make_case() {
  local name=$1 case_dir proj wt kimi_home fake_home
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  kimi_home="$case_dir/kimi-home"
  fake_home="$case_dir/home"
  mkdir -p "$kimi_home" "$fake_home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$proj" "$wt" "$kimi_home" "$fake_home"
}

read_case() {
  IFS='|' read -r CASE_DIR PROJ WT KIMI_HOME FAKE_HOME <<EOC
$1
EOC
}

# run_trust <kimi-home> <fake-home> <args...>: invoke against an isolated store.
run_trust() {
  local kimi_home=$1 fake_home=$2
  shift 2
  KIMI_CODE_HOME="$kimi_home" HOME="$fake_home" "$TRUST" "$@" 2>&1
}

trust_dir_of() { printf '%s\n' "$1/workspace-trust"; }

# The record name the store must hold for <path>, derived independently.
expected_record() {  # <kimi-home> <path> <expected-slug>
  printf '%s/%s\n' "$(trust_dir_of "$1")" "wd_$3_$(path_hash12 "$2")"
}

record_names() {  # <kimi-home> -> one record basename per line
  local dir
  dir=$(trust_dir_of "$1")
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f -exec basename {} \; 2>/dev/null | sort
}

assert_record_count() {  # <kimi-home> <n> <msg>
  local actual
  actual=$(record_names "$1" | grep -c . || true)
  [ "$actual" -eq "$2" ] || fail "$3 (expected $2 records, found $actual: $(record_names "$1" | tr '\n' ' '))"
}

# The store is the vendor's own persisted JSON, so content is asserted against
# the parsed value rather than the serialized bytes.
record_field() {  # <record> <field>
  node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));const v=j[process.argv[2]];console.log(v===undefined?"":String(v));' "$1" "$2"
}

file_mode() {  # <path> -> octal permission bits
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

expect_code() {  # <expected> <actual> <msg>
  [ "$1" -eq "$2" ] || fail "$3 (expected exit $1, got $2)"
}

assert_grep() {  # <pattern> <file-or-text> <msg>
  if [ -f "$2" ]; then
    grep -Fq "$1" "$2" || fail "$3"
  else
    printf '%s\n' "$2" | grep -Fq "$1" || fail "$3"
  fi
}

# A PATH carrying the tools the scope test needs but no node, so the
# missing-interpreter path is exercised without disturbing the real PATH.
node_free_path() {  # <case-dir> -> a bin dir holding the script's own tools but no node
  local dir=$1/nonode-bin tool
  mkdir -p "$dir"
  for tool in bash env git mkdir cat find basename dirname stat ls; do
    ln -sf "$(command -v "$tool")" "$dir/$tool" 2>/dev/null || true
  done
  printf '%s\n' "$dir"
}

# seed_secondmate_home <home> <id> [shape]: the on-disk shape bin/fm-home-seed.sh
# leaves behind. "clone" (the default) is the standalone-clone home an explicit
# ~/fm-homes/<id> path produces, a primary checkout; "worktree" is the linked
# worktree a treehouse lease produces. Both shapes are real homes, so both must
# be trusted.
seed_secondmate_home() {
  local home=$1 id=$2 shape=${3:-clone} src
  case "$shape" in
  worktree)
    src="$home.src"
    fm_git_worktree "$src" "$home" "sm-$id"
    ;;
  *)
    mkdir -p "$home"
    fm_git_init_commit "$home"
    ;;
  esac
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
}

# --- the registration itself ------------------------------------------------

# The whole point: a fresh task worktree becomes trusted, under exactly the name
# Kimi looks the folder up by, with the record shape Kimi itself writes.
test_worktree_is_registered_with_the_vendor_record_shape() {
  local out record
  read_case "$(make_case basic)"
  out=$(run_trust "$KIMI_HOME" "$FAKE_HOME" "$WT" "$PROJ")
  expect_code 0 $? "registering a fresh worktree must succeed: $out"
  record=$(expected_record "$KIMI_HOME" "$WT" wt)
  [ -f "$record" ] || fail "no trust record at the workspace id Kimi derives for '$WT' (store holds: $(record_names "$KIMI_HOME" | tr '\n' ' '))"
  [ "$(record_field "$record" root)" = "$WT" ] || fail "the trust record does not name the worktree as its root"
  case "$(record_field "$record" trustedAt)" in
  '' | *[!0-9]*) fail "the trust record carries no epoch-millisecond trustedAt" ;;
  esac
  [ "$(file_mode "$record")" = 600 ] || fail "the trust record is not mode 0600 (got $(file_mode "$record"))"
  [ "$(file_mode "$(trust_dir_of "$KIMI_HOME")")" = 700 ] || fail "the created workspace-trust directory is not mode 0700"
  assert_grep "$WT" "$out" "the success line does not name the directory it trusted"
  pass "fm-kimi-trust.sh: a fresh worktree is registered with the vendor record shape"
}

# Kimi's trust lookup has no ancestor walk, so the primary checkout is out of
# scope: registering it would write the captain's own interactive store for a
# directory this launch never enters. It must stay untouched.
test_only_the_worktree_is_registered_never_the_primary_checkout() {
  local out
  read_case "$(make_case only-wt)"
  out=$(run_trust "$KIMI_HOME" "$FAKE_HOME" "$WT" "$PROJ")
  expect_code 0 $? "registering a fresh worktree must succeed: $out"
  assert_record_count "$KIMI_HOME" 1 "the registration wrote more than the one launch directory"
  [ ! -f "$(expected_record "$KIMI_HOME" "$PROJ" project)" ] \
    || fail "the registration also trusted the primary checkout, which the launch never enters"
  pass "fm-kimi-trust.sh: only the launch directory is registered, never the primary checkout"
}

# Presence alone grants trust, so a folder the captain already trusted must keep
# its own record, including the trustedAt its interactive session wrote.
test_an_existing_record_is_never_overwritten() {
  local record before out after
  read_case "$(make_case existing)"
  out=$(run_trust "$KIMI_HOME" "$FAKE_HOME" "$WT" "$PROJ")
  expect_code 0 $? "the first registration must succeed: $out"
  record=$(expected_record "$KIMI_HOME" "$WT" wt)
  # Rewrite it as a record an earlier interactive answer would have left.
  printf '{"root":"%s","trustedAt":1}' "$WT" > "$record"
  before=$(cat "$record")
  out=$(run_trust "$KIMI_HOME" "$FAKE_HOME" "$WT" "$PROJ")
  expect_code 0 $? "re-registering an already trusted worktree must succeed: $out"
  after=$(cat "$record")
  [ "$after" = "$before" ] || fail "the existing trust record was rewritten (was '$before', now '$after')"
  assert_grep "already trusted" "$out" "the repeat registration did not report the record as already present"
  assert_record_count "$KIMI_HOME" 1 "the repeat registration added a second record"
  pass "fm-kimi-trust.sh: an existing trust record is reported and never overwritten"
}

# Nothing else in the store is this script's business: sibling records and the
# workspace registry Kimi maintains itself must come through untouched.
test_unrelated_store_content_is_preserved() {
  local dir sibling registry out
  read_case "$(make_case preserve)"
  dir=$(trust_dir_of "$KIMI_HOME")
  mkdir -p "$dir" && chmod 700 "$dir"
  sibling="$dir/wd_someone-else_0123456789ab"
  printf '{"root":"/somewhere/else","trustedAt":7}' > "$sibling"
  registry="$KIMI_HOME/workspaces.json"
  printf '{"version":1,"workspaces":{"wd_keep_ffffffffffff":{"root":"/keep"}},"deleted_workspace_ids":[]}' > "$registry"
  out=$(run_trust "$KIMI_HOME" "$FAKE_HOME" "$WT" "$PROJ")
  expect_code 0 $? "registering beside unrelated store content must succeed: $out"
  [ "$(cat "$sibling")" = '{"root":"/somewhere/else","trustedAt":7}' ] \
    || fail "an unrelated trust record was modified"
  [ "$(cat "$registry")" = '{"version":1,"workspaces":{"wd_keep_ffffffffffff":{"root":"/keep"}},"deleted_workspace_ids":[]}' ] \
    || fail "the workspaces registry was modified, though trust does not depend on it"
  assert_record_count "$KIMI_HOME" 2 "the registration did not leave exactly the sibling plus its own record"
  pass "fm-kimi-trust.sh: unrelated store content is preserved"
}

# --- the workspace id derivation -------------------------------------------

# Kimi's slug rule, pinned step by step against the ids the installed 2.0.2 was
# observed to produce for these exact basenames. Each case is a real directory
# the subject registers, so the assertion runs through the executable and reads
# the name the store actually received.
test_workspace_id_slug_matches_the_vendor_rule() {
  local case_dir proj kimi_home fake_home name slug wt out record
  case_dir="$TMP_ROOT/slug"
  proj="$case_dir/project"
  kimi_home="$case_dir/kimi-home"
  fake_home="$case_dir/home"
  mkdir -p "$kimi_home" "$fake_home"
  fm_git_init_commit "$proj"
  fm_git_add_origin "$proj" "$proj.origin.git"
  local i=0
  # "<basename>|<slug Kimi 2.0.2 produced>"
  local cases=(
    'UPPER|upper'
    'a  b   c|a-b-c'
    '.hidden|.hidden'
    'trail--|trail'
    '-lead|lead'
    '__under__|__under__'
    'mid--dle|mid--dle'
    'dot.|dot.'
  )
  for entry in "${cases[@]}"; do
    name=${entry%%|*}
    slug=${entry##*|}
    i=$((i + 1))
    wt="$case_dir/$name"
    git -C "$proj" worktree add --quiet -b "slug$i" "$wt"
    out=$(run_trust "$kimi_home" "$fake_home" "$wt" "$proj")
    expect_code 0 $? "registering basename '$name' must succeed: $out"
    record=$(expected_record "$kimi_home" "$(cd -P -- "$wt" && pwd -P)" "$slug")
    [ -f "$record" ] \
      || fail "basename '$name' was not registered under the vendor slug '$slug' (store holds: $(record_names "$kimi_home" | tr '\n' ' '))"
  done
  pass "fm-kimi-trust.sh: the workspace id slug matches the vendor rule for every observed basename shape"
}

# The two ordering facts that a naive implementation gets wrong: the leading
# strip runs BEFORE the 40-character truncation and the trailing strip AFTER it.
# Both were read off Kimi 2.0.2 directly.
test_workspace_id_slug_truncation_order() {
  local case_dir proj kimi_home fake_home wt out record a39 a41 lead
  case_dir="$TMP_ROOT/slug-order"
  proj="$case_dir/project"
  kimi_home="$case_dir/kimi-home"
  fake_home="$case_dir/home"
  mkdir -p "$kimi_home" "$fake_home"
  fm_git_init_commit "$proj"
  fm_git_add_origin "$proj" "$proj.origin.git"
  a39=$(printf 'a%.0s' $(seq 39))
  a41=$(printf 'a%.0s' $(seq 41))
  lead="-----$(printf 'b%.0s' $(seq 40))"
  # Truncating to 40 lands on the dash, and the trailing strip then removes it,
  # so the slug is 39 characters rather than 40.
  wt="$case_dir/$a39-bbbb"
  git -C "$proj" worktree add --quiet -b order1 "$wt"
  out=$(run_trust "$kimi_home" "$fake_home" "$wt" "$proj")
  expect_code 0 $? "registering the truncate-onto-a-dash basename must succeed: $out"
  record=$(expected_record "$kimi_home" "$(cd -P -- "$wt" && pwd -P)" "$a39")
  [ -f "$record" ] || fail "the trailing strip did not run after the 40-character truncation"
  # A name over the cap keeps its first 40 characters.
  wt="$case_dir/$a41"
  git -C "$proj" worktree add --quiet -b order2 "$wt"
  out=$(run_trust "$kimi_home" "$fake_home" "$wt" "$proj")
  expect_code 0 $? "registering the over-cap basename must succeed: $out"
  record=$(expected_record "$kimi_home" "$(cd -P -- "$wt" && pwd -P)" "$(printf 'a%.0s' $(seq 40))")
  [ -f "$record" ] || fail "the slug was not truncated to 40 characters"
  # Leading dashes go before the cap is applied, so 40 characters survive.
  wt="$case_dir/$lead"
  git -C "$proj" worktree add --quiet -b order3 "$wt"
  out=$(run_trust "$kimi_home" "$fake_home" "$wt" "$proj")
  expect_code 0 $? "registering the leading-dash basename must succeed: $out"
  record=$(expected_record "$kimi_home" "$(cd -P -- "$wt" && pwd -P)" "$(printf 'b%.0s' $(seq 40))")
  [ -f "$record" ] || fail "the leading strip did not run before the 40-character truncation"
  pass "fm-kimi-trust.sh: the slug's leading strip precedes truncation and its trailing strip follows it"
}

# A basename with nothing left after the substitution falls back to the literal
# Kimi uses, so the record still lands somewhere deterministic.
test_workspace_id_slug_falls_back_when_nothing_is_left() {
  local out record
  read_case "$(make_case degenerate)"
  local wt="$CASE_DIR/@@@"
  git -C "$PROJ" worktree add --quiet -b degen "$wt"
  out=$(run_trust "$KIMI_HOME" "$FAKE_HOME" "$wt" "$PROJ")
  expect_code 0 $? "registering an all-punctuation basename must succeed: $out"
  record=$(expected_record "$KIMI_HOME" "$(cd -P -- "$wt" && pwd -P)" workspace)
  [ -f "$record" ] || fail "an all-punctuation basename did not fall back to the 'workspace' slug"
  pass "fm-kimi-trust.sh: a slug left empty by substitution falls back to 'workspace'"
}

# Kimi resolves the launch directory before deriving the id, so a symlinked
# argument must register the physical path's record and not the link's.
test_a_symlinked_argument_registers_the_resolved_path() {
  local link out
  read_case "$(make_case symlink)"
  link="$CASE_DIR/wt-link"
  ln -s "$WT" "$link"
  out=$(run_trust "$KIMI_HOME" "$FAKE_HOME" "$link" "$PROJ")
  expect_code 0 $? "registering through a symlinked worktree path must succeed: $out"
  [ -f "$(expected_record "$KIMI_HOME" "$(cd -P -- "$WT" && pwd -P)" wt)" ] \
    || fail "the symlinked argument did not register the resolved path Kimi derives its id from"
  assert_record_count "$KIMI_HOME" 1 "the symlinked argument registered more than the resolved path"
  pass "fm-kimi-trust.sh: a symlinked argument registers the resolved path"
}

# --- which home ------------------------------------------------------------

# A captain running several Kimi accounts selects one with KIMI_CODE_HOME, and a
# registration in the wrong home is a silent no-op, so the selected home is the
# one written.
test_kimi_code_home_selects_the_store() {
  local second out
  read_case "$(make_case home-select)"
  second="$CASE_DIR/kimi-code-2"
  mkdir -p "$second"
  out=$(run_trust "$second" "$FAKE_HOME" "$WT" "$PROJ")
  expect_code 0 $? "registering into a selected Kimi home must succeed: $out"
  [ -f "$(expected_record "$second" "$WT" wt)" ] \
    || fail "the record did not land in the Kimi home KIMI_CODE_HOME selected"
  [ ! -d "$(trust_dir_of "$KIMI_HOME")" ] \
    || fail "the registration also wrote the unselected Kimi home"
  pass "fm-kimi-trust.sh: KIMI_CODE_HOME selects which Kimi home is written"
}

# With no selection the default home under HOME is used, and it is created when
# Kimi has not run yet.
test_unset_kimi_code_home_defaults_under_home() {
  local out
  read_case "$(make_case home-default)"
  out=$(HOME="$FAKE_HOME" "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 0 $? "registering with no KIMI_CODE_HOME must succeed: $out"
  [ -f "$(expected_record "$FAKE_HOME/.kimi-code" "$WT" wt)" ] \
    || fail "the record did not land in the default \$HOME/.kimi-code home"
  pass "fm-kimi-trust.sh: an unset KIMI_CODE_HOME defaults to \$HOME/.kimi-code"
}

# A relative value names one home here and a different one in the worker's pane,
# so it is refused rather than guessed at.
test_relative_kimi_code_home_is_refused() {
  local out rc=0
  read_case "$(make_case home-relative)"
  out=$(KIMI_CODE_HOME="kimi-code" HOME="$FAKE_HOME" "$TRUST" "$WT" "$PROJ" 2>&1) || rc=$?
  expect_code 1 "$rc" "a relative KIMI_CODE_HOME must be refused: $out"
  assert_grep "relative path" "$out" "the refusal does not name the relative home as the reason"
  pass "fm-kimi-trust.sh: a relative KIMI_CODE_HOME is refused"
}

# --- scope refusals --------------------------------------------------------

assert_refused() {  # <msg-fragment> <kimi-home> <fake-home> <args...>
  local fragment=$1 kimi_home=$2 fake_home=$3 out rc=0
  shift 3
  out=$(run_trust "$kimi_home" "$fake_home" "$@") || rc=$?
  expect_code 1 "$rc" "'$*' must be refused, not accepted: $out"
  assert_grep "$fragment" "$out" "the refusal for '$*' does not name '$fragment' as the reason"
  assert_record_count "$kimi_home" 0 "a refused registration still wrote a trust record"
}

test_out_of_scope_directories_are_refused() {
  read_case "$(make_case refusals)"
  # A primary checkout is not a disposable worktree.
  assert_refused "primary checkout" "$KIMI_HOME" "$FAKE_HOME" "$PROJ" "$PROJ"
  # A worktree of an unrelated repository is not this project's worktree.
  local other="$CASE_DIR/other" other_wt="$CASE_DIR/other-wt"
  fm_git_worktree "$other" "$other_wt" other-branch
  assert_refused "is not a worktree of project" "$KIMI_HOME" "$FAKE_HOME" "$other_wt" "$PROJ"
  # A subdirectory of a worktree is not the worktree root the pane starts in.
  mkdir -p "$WT/sub"
  assert_refused "is not a worktree root" "$KIMI_HOME" "$FAKE_HOME" "$WT/sub" "$PROJ"
  # A plain directory has no git shape to prove anything about.
  local plain="$CASE_DIR/plain"
  mkdir -p "$plain"
  assert_refused "not inside a git repository" "$KIMI_HOME" "$FAKE_HOME" "$plain" "$PROJ"
  # A path that does not exist cannot be registered.
  assert_refused "not an accessible directory" "$KIMI_HOME" "$FAKE_HOME" "$CASE_DIR/missing" "$PROJ"
  # The home directory is never a task worktree.
  assert_refused "is the home directory" "$KIMI_HOME" "$FAKE_HOME" "$FAKE_HOME" "$PROJ"
  # Nor is the Kimi home itself.
  assert_refused "is the Kimi home directory" "$KIMI_HOME" "$FAKE_HOME" "$KIMI_HOME" "$PROJ"
  pass "fm-kimi-trust.sh: every out-of-scope directory is refused"
}

test_usage_errors_are_refused() {
  local out rc=0
  read_case "$(make_case usage)"
  out=$(run_trust "$KIMI_HOME" "$FAKE_HOME" "$WT") || rc=$?
  expect_code 2 "$rc" "a single argument must be a usage error: $out"
  rc=0
  out=$(run_trust "$KIMI_HOME" "$FAKE_HOME" --help) || rc=$?
  expect_code 2 "$rc" "--help must print usage and exit 2: $out"
  assert_grep "usage: fm-kimi-trust.sh" "$out" "the usage text does not name the script"
  rc=0
  out=$(run_trust "$KIMI_HOME" "$FAKE_HOME" --secondmate-home "$WT") || rc=$?
  expect_code 2 "$rc" "secondmate mode without an id must be a usage error: $out"
  pass "fm-kimi-trust.sh: malformed invocations are usage errors"
}

# --- malformed store -------------------------------------------------------

# The store is the captain's own, so a shape that is not the directory-of-records
# Kimi keeps must fail loudly instead of being written through or around.
test_malformed_store_is_refused() {
  local out rc=0 dir record
  read_case "$(make_case malformed)"
  # workspace-trust is a regular file, not the directory Kimi keeps.
  dir=$(trust_dir_of "$KIMI_HOME")
  printf 'not a directory\n' > "$dir"
  out=$(run_trust "$KIMI_HOME" "$FAKE_HOME" "$WT" "$PROJ") || rc=$?
  expect_code 1 "$rc" "a workspace-trust file must be refused: $out"
  assert_grep "is not a directory" "$out" "the refusal does not name the malformed store"
  rm -f "$dir"
  # workspace-trust is a symlink, which makes another directory stand in for the store.
  read_case "$(make_case malformed-link)"
  dir=$(trust_dir_of "$KIMI_HOME")
  mkdir -p "$CASE_DIR/elsewhere"
  ln -s "$CASE_DIR/elsewhere" "$dir"
  rc=0
  out=$(run_trust "$KIMI_HOME" "$FAKE_HOME" "$WT" "$PROJ") || rc=$?
  expect_code 1 "$rc" "a symlinked workspace-trust store must be refused: $out"
  assert_grep "is a symlink" "$out" "the refusal does not name the symlinked store"
  # The record path itself is a directory, so nothing can be written there.
  read_case "$(make_case malformed-record)"
  dir=$(trust_dir_of "$KIMI_HOME")
  mkdir -p "$dir" && chmod 700 "$dir"
  record=$(expected_record "$KIMI_HOME" "$WT" wt)
  mkdir -p "$record"
  rc=0
  out=$(run_trust "$KIMI_HOME" "$FAKE_HOME" "$WT" "$PROJ") || rc=$?
  expect_code 1 "$rc" "a record path that is a directory must be refused: $out"
  assert_grep "not a regular file" "$out" "the refusal does not name the malformed record"
  # The record path is a symlink, so some other file's bytes would stand in for trust.
  read_case "$(make_case malformed-record-link)"
  dir=$(trust_dir_of "$KIMI_HOME")
  mkdir -p "$dir" && chmod 700 "$dir"
  record=$(expected_record "$KIMI_HOME" "$WT" wt)
  printf '{"root":"/elsewhere","trustedAt":1}' > "$CASE_DIR/decoy.json"
  ln -s "$CASE_DIR/decoy.json" "$record"
  rc=0
  out=$(run_trust "$KIMI_HOME" "$FAKE_HOME" "$WT" "$PROJ") || rc=$?
  expect_code 1 "$rc" "a symlinked record must be refused: $out"
  assert_grep "is a symlink" "$out" "the refusal does not name the symlinked record"
  pass "fm-kimi-trust.sh: a malformed trust store is refused"
}

test_missing_node_is_refused() {
  local out rc=0 nonode
  read_case "$(make_case nonode)"
  nonode=$(node_free_path "$CASE_DIR")
  out=$(KIMI_CODE_HOME="$KIMI_HOME" HOME="$FAKE_HOME" PATH="$nonode" "$TRUST" "$WT" "$PROJ" 2>&1) || rc=$?
  expect_code 1 "$rc" "a missing node must be refused: $out"
  assert_grep "node is required" "$out" "the refusal does not name node as the missing tool"
  pass "fm-kimi-trust.sh: a missing node interpreter is refused"
}

# A scope refusal must not depend on node being present: the structural test runs
# first, so an out-of-scope path is refused for its own reason either way.
test_scope_refusal_precedes_the_node_requirement() {
  local out rc=0 nonode
  read_case "$(make_case nonode-scope)"
  nonode=$(node_free_path "$CASE_DIR")
  out=$(KIMI_CODE_HOME="$KIMI_HOME" HOME="$FAKE_HOME" PATH="$nonode" "$TRUST" "$PROJ" "$PROJ" 2>&1) || rc=$?
  expect_code 1 "$rc" "a primary checkout must still be refused without node: $out"
  assert_grep "primary checkout" "$out" "the refusal fell back to the node message instead of the scope reason"
  pass "fm-kimi-trust.sh: a scope refusal precedes the node requirement"
}

# --- secondmate homes ------------------------------------------------------

# Kimi is a verified secondmate harness, and the home is the directory that
# pane starts in, so both seeded shapes must be registered on seed evidence.
test_seeded_secondmate_homes_are_registered() {
  local case_dir kimi_home fake_home home out
  case_dir="$TMP_ROOT/sm"
  kimi_home="$case_dir/kimi-home"
  fake_home="$case_dir/home"
  mkdir -p "$kimi_home" "$fake_home"
  home="$case_dir/fm-homes/n1"
  seed_secondmate_home "$home" n1 clone
  out=$(run_trust "$kimi_home" "$fake_home" --secondmate-home "$home" n1)
  expect_code 0 $? "a seeded standalone-clone home must be registered: $out"
  [ -f "$(expected_record "$kimi_home" "$(cd -P -- "$home" && pwd -P)" n1)" ] \
    || fail "the standalone-clone secondmate home was not registered (store holds: $(record_names "$kimi_home" | tr '\n' ' '))"
  local leased="$case_dir/leased/n2"
  seed_secondmate_home "$leased" n2 worktree
  out=$(run_trust "$kimi_home" "$fake_home" --secondmate-home "$leased" n2)
  expect_code 0 $? "a seeded leased-worktree home must be registered: $out"
  [ -f "$(expected_record "$kimi_home" "$(cd -P -- "$leased" && pwd -P)" n2)" ] \
    || fail "the leased-worktree secondmate home was not registered"
  pass "fm-kimi-trust.sh: both seeded secondmate home shapes are registered"
}

# The seed is the entire boundary, so anything without it is refused.
test_secondmate_mode_refuses_everything_unseeded() {
  local case_dir kimi_home fake_home home
  case_dir="$TMP_ROOT/sm-refuse"
  kimi_home="$case_dir/kimi-home"
  fake_home="$case_dir/home"
  mkdir -p "$kimi_home" "$fake_home"
  # A plain directory carries no marker.
  local plain="$case_dir/plain"
  mkdir -p "$plain"
  assert_refused "carries no .fm-secondmate-home marker" "$kimi_home" "$fake_home" --secondmate-home "$plain" n1
  # A home seeded for another secondmate is not this one's.
  home="$case_dir/other"
  seed_secondmate_home "$home" other clone
  assert_refused "is marked for secondmate" "$kimi_home" "$fake_home" --secondmate-home "$home" n1
  # A marker that is a symlink lets another file's bytes stand in for the seed.
  local linked="$case_dir/linked"
  seed_secondmate_home "$linked" n1 clone
  rm -f "$linked/.fm-secondmate-home"
  printf 'n1\n' > "$case_dir/decoy-marker"
  ln -s "$case_dir/decoy-marker" "$linked/.fm-secondmate-home"
  assert_refused "is a symlink" "$kimi_home" "$fake_home" --secondmate-home "$linked" n1
  # A home whose operational directory escapes it is not a safe home.
  local escaping="$case_dir/escaping"
  seed_secondmate_home "$escaping" n1 clone
  rm -rf "$escaping/state"
  mkdir -p "$case_dir/outside-state"
  ln -s "$case_dir/outside-state" "$escaping/state"
  assert_refused "outside the home" "$kimi_home" "$fake_home" --secondmate-home "$escaping" n1
  # A firstmate checkout with no marker at all is still not a secondmate home.
  local bare="$case_dir/bare"
  mkdir -p "$bare/bin"
  fm_git_init_commit "$bare"
  printf '# Firstmate\n' > "$bare/AGENTS.md"
  assert_refused "carries no .fm-secondmate-home marker" "$kimi_home" "$fake_home" --secondmate-home "$bare" n1
  pass "fm-kimi-trust.sh: secondmate mode refuses every unseeded directory"
}

# The two modes must not accept each other's shapes: a secondmate home is not a
# linked worktree of a project, and the worktree test must say so.
test_worktree_mode_refuses_a_secondmate_home() {
  local case_dir kimi_home fake_home home
  case_dir="$TMP_ROOT/sm-crossmode"
  kimi_home="$case_dir/kimi-home"
  fake_home="$case_dir/home"
  mkdir -p "$kimi_home" "$fake_home"
  home="$case_dir/fm-homes/n1"
  seed_secondmate_home "$home" n1 clone
  assert_refused "primary checkout" "$kimi_home" "$fake_home" "$home" "$home"
  pass "fm-kimi-trust.sh: worktree mode refuses a seeded secondmate home"
}

test_worktree_is_registered_with_the_vendor_record_shape
test_only_the_worktree_is_registered_never_the_primary_checkout
test_an_existing_record_is_never_overwritten
test_unrelated_store_content_is_preserved
test_workspace_id_slug_matches_the_vendor_rule
test_workspace_id_slug_truncation_order
test_workspace_id_slug_falls_back_when_nothing_is_left
test_a_symlinked_argument_registers_the_resolved_path
test_kimi_code_home_selects_the_store
test_unset_kimi_code_home_defaults_under_home
test_relative_kimi_code_home_is_refused
test_out_of_scope_directories_are_refused
test_usage_errors_are_refused
test_malformed_store_is_refused
test_missing_node_is_refused
test_scope_refusal_precedes_the_node_requirement
test_seeded_secondmate_homes_are_registered
test_secondmate_mode_refuses_everything_unseeded
test_worktree_mode_refuses_a_secondmate_home
