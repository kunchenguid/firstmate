#!/usr/bin/env bash
# Topic index path refusal. AGENTS.md markers are Unit 3.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INDEX="$ROOT/bin/fm-contract-index.sh"
TMP_ROOT=$(fm_test_tmproot fm-contract-index)

write_topics() {  # <name> <path-cell>
  local file=$TMP_ROOT/$1.tsv
  printf '%s\n' $'id\ttrigger\tpath' >"$file"
  printf $'%s\t%s\n' $'sample\ta real trigger' "$2" >>"$file"
  printf '%s\n' "$file"
}

expect_refuse() {  # <path-cell> <label>
  local file out err code
  file=$(write_topics "$2" "$1")
  err=$TMP_ROOT/$2.err
  out=$("$INDEX" --check "$file" 2>"$err")
  code=$?
  assert_not_equals 0 "$code" "$2 was accepted"
  assert_equals '' "$out" "$2 wrote a table"
  assert_contains "$(cat "$err")" "refuse path: $1" "$2 did not refuse the path"
}

test_tracked_topics_check_without_agents_markers() {
  local out err code
  err=$TMP_ROOT/tracked.err
  out=$("$INDEX" --check 2>"$err")
  code=$?
  assert_equals 0 "$code" "tracked topics failed check"
  assert_equals '' "$out" "check printed a marker diff"
  assert_equals '' "$(cat "$err")" "check wrote an error"
  out=$("$INDEX" render 2>"$err")
  assert_contains "$out" '| quota-array | a matched profile array must be ranked | .agents/skills/quota-array-dispatch/SKILL.md |' \
    "render dropped the quota-array topic"
  assert_contains "$out" '| layout | locating or changing home, config, data, state, or project paths | .agents/skills/operational-home-layout/SKILL.md |' \
    "render dropped the layout topic"
  pass "tracked topics render and check without AGENTS.md markers"
}

test_refuse_escaping_paths() {
  local home_path missing file out err code
  expect_refuse '/etc/passwd' absolute
  expect_refuse '.agents/../../bin/fm-lock.sh' dotdot
  # shellcheck disable=SC2016 # The topic cell is a literal dollar path.
  expect_refuse '$HOME/secret' dollar
  expect_refuse 'state/.afk' state
  expect_refuse 'data/captain.md' data
  home_path=${HOME}/.agents/skills/quota-array-dispatch/SKILL.md
  expect_refuse "$home_path" home
  missing=$(write_topics missing '.agents/skills/does-not-exist/SKILL.md')
  err=$TMP_ROOT/missing.err
  out=$("$INDEX" --check "$missing" 2>"$err")
  code=$?
  assert_not_equals 0 "$code" "missing path was accepted"
  assert_contains "$(cat "$err")" 'refuse path: .agents/skills/does-not-exist/SKILL.md' \
    "missing path was not refused"
  file=$(write_topics ok '.agents/skills/quota-array-dispatch/SKILL.md')
  out=$("$INDEX" --check "$file" 2>"$TMP_ROOT/ok.err")
  code=$?
  assert_equals 0 "$code" "skill path that exists was refused"
  assert_equals '' "$out" "accepted topic check printed a table"
  pass "index refuses absolute, parent, dollar, home, state, data, and missing paths"
}

test_tracked_topics_check_without_agents_markers
test_refuse_escaping_paths
