#!/usr/bin/env bash
# Behavior tests for bin/fm-base-lib.sh, the shared facts about a task's declared base.
#
# The lib answers two questions and no more. It deliberately says NOTHING about a base's
# end of life - merged, squash-merged, abandoned - because git cannot tell those apart
# without a guess, and every consumer hands that question to a human instead.
#
# fm_base_probe_origin - does the branch exist on origin?
#   (a) it is there                                             -> PRESENT
#   (b) it is not there                                         -> ABSENT
#   (c) origin cannot be asked at all (auth, network, no remote) -> PROBE_FAILED, and NOT
#       mistaken for a branch that is gone: an infrastructure failure is not a fact about
#       the base
#
# fm_base_head_rooted - is a head rooted in the base's own history, or in the default
# branch?
#   (d) head stacked on the base                     -> ROOTED
#   (e) head rebased onto the default branch         -> UNROOTED (the 2026-07-07 incident)
#   (f) head stacked, but the base ADVANCED since    -> still ROOTED. Rootedness is not
#       tip-descent: a stacked PR whose own base is under review sees it advance all the
#       time, and demanding descent from the current tip would refuse a routine merge
#   (g) head and base share no history at all        -> UNRELATED
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-base-lib.sh
. "$ROOT/bin/fm-base-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-base-lib)

commit() {  # <dir> <file> <content> <message>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" -c user.name=t -c user.email=t@t commit -qm "$4"
}

# A clone with a real origin: main, plus a feature/base branch carrying a commit of its own.
make_repo() {  # <name>; echoes the work dir
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir"
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/wt" 2>/dev/null
  commit "$dir/wt" seed.txt seed "seed"
  git -C "$dir/wt" push -q origin main

  git -C "$dir/wt" checkout -q -b feature/base
  commit "$dir/wt" base-only.txt base-work "feature base work"
  git -C "$dir/wt" push -q origin feature/base
  git -C "$dir/wt" checkout -q main
  git -C "$dir/wt" fetch -q origin
  printf '%s\n' "$dir"
}

probe_word() {  # <dir> <branch>; echoes present|absent|probe-failed
  local rc=0
  fm_base_probe_origin "$1/wt" "$2" || rc=$?
  case "$rc" in
    "$FM_BASE_PRESENT") printf 'present' ;;
    "$FM_BASE_ABSENT") printf 'absent' ;;
    *) printf 'probe-failed' ;;
  esac
}

rooted_word() {  # <dir> <base-rev> <head-rev>; echoes rooted|unrooted|unrelated
  local dir=$1 base head default rc=0
  base=$(git -C "$dir/wt" rev-parse "$2")
  head=$(git -C "$dir/wt" rev-parse "$3")
  default=$(git -C "$dir/wt" rev-parse origin/main)
  fm_base_head_rooted "$dir/wt" "$base" "$head" "$default" || rc=$?
  case "$rc" in
    "$FM_BASE_HEAD_ROOTED") printf 'rooted' ;;
    "$FM_BASE_HEAD_UNROOTED") printf 'unrooted' ;;
    *) printf 'unrelated' ;;
  esac
}

expect_word() {  # <expected> <actual> <msg>
  [ "$1" = "$2" ] || fail "$3"$'\n'"  expected: $1"$'\n'"  got:      $2"
}

test_valid_branch_name() {
  fm_base_valid_branch_name 'feature/base' \
    || fail "valid-name: an ordinary branch name was rejected"
  ! fm_base_valid_branch_name '' \
    || fail "valid-name: an empty name must be rejected"
  ! fm_base_valid_branch_name '--upload-pack=touch /tmp/pwned' \
    || fail "valid-name: a dash-leading value must be rejected - git would read it as an option"
  ! fm_base_valid_branch_name 'has space' \
    || fail "valid-name: a name with whitespace must be rejected"
  ! fm_base_valid_branch_name 'bad..name' \
    || fail "valid-name: a git-illegal name must be rejected"
  pass "fm_base_valid_branch_name accepts a branch name and rejects empty, dash-leading, spaced, and git-illegal ones"
}

test_probe_present() {
  local dir
  dir=$(make_repo probe-present)
  expect_word present "$(probe_word "$dir" feature/base)" \
    "probe-present: a branch that is on origin must read PRESENT"
  pass "fm_base_probe_origin reports a branch that exists on origin as PRESENT"
}

test_probe_absent() {
  local dir
  dir=$(make_repo probe-absent)
  git -C "$dir/origin.git" update-ref -d refs/heads/feature/base
  expect_word absent "$(probe_word "$dir" feature/base)" \
    "probe-absent: a branch deleted from origin must read ABSENT"
  pass "fm_base_probe_origin reports a branch deleted from origin as ABSENT"
}

# An origin that cannot be ASKED is an infrastructure failure. Reading it as "the branch is
# gone" would let a network blip decide a merge, which is the fail-open this lib exists to
# make impossible.
test_probe_failure_is_not_absence() {
  local dir rc=0
  dir=$(make_repo probe-failed)
  git -C "$dir/wt" remote set-url origin "$TMP_ROOT/does-not-exist.git"
  expect_word probe-failed "$(probe_word "$dir" feature/base)" \
    "probe-failed: an unreachable origin must NOT be reported as a branch that is gone"
  # Called here rather than through probe_word: an out-param set inside a command
  # substitution never reaches this scope.
  fm_base_probe_origin "$dir/wt" feature/base || rc=$?
  [ -n "${FM_BASE_PROBE_ERR:-}" ] \
    || fail "probe-failed: git's own error was swallowed instead of captured for the caller"
  pass "fm_base_probe_origin tells an unreachable origin from a branch that is gone, and keeps git's error"
}

test_head_stacked_on_base_is_rooted() {
  local dir
  dir=$(make_repo rooted)
  git -C "$dir/wt" checkout -q -b prhead origin/feature/base
  commit "$dir/wt" fix.txt fix "task fix"
  expect_word rooted "$(rooted_word "$dir" origin/feature/base prhead)" \
    "rooted: a head stacked on its base must read ROOTED"
  pass "fm_base_head_rooted reports a head stacked on its base as ROOTED"
}

# The incident (data/learnings.md 2026-07-07): the pipeline rebased the head onto the
# default branch, replaying the base's unmerged commits onto it.
test_head_rebased_onto_default_is_unrooted() {
  local dir
  dir=$(make_repo unrooted)
  git -C "$dir/wt" checkout -q -b prhead origin/main
  commit "$dir/wt" fix.txt fix "task fix"
  expect_word unrooted "$(rooted_word "$dir" origin/feature/base prhead)" \
    "unrooted: a head rooted in the default branch must read UNROOTED"
  pass "fm_base_head_rooted reports a head rebased onto the default branch as UNROOTED"
}

# Rootedness is not tip-descent. A stacked PR whose own base is still under review sees
# that base advance all the time; demanding descent from the current tip would turn every
# routine base advance into a hard merge refusal.
test_base_advanced_since_head_is_still_rooted() {
  local dir
  dir=$(make_repo advanced)
  git -C "$dir/wt" checkout -q -b prhead origin/feature/base
  commit "$dir/wt" fix.txt fix "task fix"
  git -C "$dir/wt" checkout -q -b base-advance origin/feature/base
  commit "$dir/wt" base-2.txt more "further base work"
  git -C "$dir/wt" push -q origin base-advance:feature/base
  git -C "$dir/wt" fetch -q origin
  expect_word rooted "$(rooted_word "$dir" origin/feature/base prhead)" \
    "advanced: a head whose base merely advanced is still correctly stacked and must read ROOTED"
  pass "fm_base_head_rooted keeps a head ROOTED when its base merely advanced past it"
}

test_unrelated_histories() {
  local dir
  dir=$(make_repo unrelated)
  git -C "$dir/wt" checkout -q --orphan lonely
  git -C "$dir/wt" rm -q -rf . >/dev/null 2>&1 || true
  commit "$dir/wt" other.txt other "unrelated root"
  expect_word unrelated "$(rooted_word "$dir" origin/feature/base lonely)" \
    "unrelated: a head sharing no history with the base must read UNRELATED"
  pass "fm_base_head_rooted reports a head sharing no history with the base as UNRELATED"
}

# The two enums travel as return codes through the same scope in fm-pr-check.sh. Sharing a
# value would let a probe outcome be read as a rootedness outcome in a merge gate.
test_enum_values_cannot_alias_across_enums() {
  local dupes
  dupes=$(printf '%s\n' \
    "$FM_BASE_PRESENT" "$FM_BASE_PROBE_FAILED" "$FM_BASE_ABSENT" \
    "$FM_BASE_HEAD_ROOTED" "$FM_BASE_HEAD_UNROOTED" "$FM_BASE_HEAD_UNRELATED" \
    | sort | uniq -d)
  [ -z "$dupes" ] \
    || fail "enum: FM_BASE_* outcomes share the value(s) [$dupes] across enums; a value of one could be read as a value of another in the same scope"
  pass "fm-base-lib: no two FM_BASE_* outcomes share a numeric value"
}

test_valid_branch_name
test_probe_present
test_probe_absent
test_probe_failure_is_not_absence
test_head_stacked_on_base_is_rooted
test_head_rebased_onto_default_is_unrooted
test_base_advanced_since_head_is_still_rooted
test_unrelated_histories
test_enum_values_cannot_alias_across_enums
