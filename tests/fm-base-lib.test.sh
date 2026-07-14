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
# fm_base_has_own_commits - does the base still carry anything the default branch lacks?
# This is what separates a LIVE feature base, whose unmerged history a wrong-based merge
# could drag onto the default branch, from a branch that is merely still on origin.
#   (d) base carries a commit of its own              -> HAS_OWN_COMMITS (live: guard it)
#   (e) the default branch has absorbed every commit it carries -> NO_OWN_COMMITS. Nothing
#       left to drag anywhere, so the hazard is gone - and rootedness is not observable
#       against such a base at all (see (h))
#   (f) the base was SQUASH-merged                    -> still HAS_OWN_COMMITS, deliberately.
#       Its own commits are absent from the default branch by SHA. This is plain ancestry,
#       not a merge detector, and it does not pretend to be one
#   (g) git cannot count                              -> OWN_COMMITS_UNKNOWN, and NOT read as
#       either verdict
#
# fm_base_head_rooted - is a head rooted in the base's own history, or in the default
# branch?
#   (h) head stacked on the base                     -> ROOTED
#   (i) head rebased onto the default branch         -> UNROOTED (the 2026-07-07 incident)
#   (j) head stacked, but the base ADVANCED since    -> still ROOTED. Rootedness is not
#       tip-descent: a stacked PR whose own base is under review sees it advance all the
#       time, and demanding descent from the current tip would refuse a routine merge
#   (k) head and base share no history at all        -> UNRELATED
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

own_word() {  # <dir> <base-rev>; echoes has-own|no-own|unknown
  local dir=$1 base default rc=0
  base=$(git -C "$dir/wt" rev-parse "$2" 2>/dev/null) || base=$2
  default=$(git -C "$dir/wt" rev-parse origin/main)
  fm_base_has_own_commits "$dir/wt" "$base" "$default" || rc=$?
  case "$rc" in
    "$FM_BASE_HAS_OWN_COMMITS") printf 'has-own' ;;
    "$FM_BASE_NO_OWN_COMMITS") printf 'no-own' ;;
    *) printf 'unknown' ;;
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

test_live_base_has_own_commits() {
  local dir
  dir=$(make_repo own-live)
  expect_word has-own "$(own_word "$dir" origin/feature/base)" \
    "own-live: a base carrying unmerged work of its own must read HAS_OWN_COMMITS"
  pass "fm_base_has_own_commits reports a live feature base as carrying its own commits"
}

# A branch existing on origin does NOT make it a live feature base. GitHub's delete-on-merge
# is off by default, so a base that merged and kept its branch is an ordinary end-state: it
# has nothing left to drag onto the default branch, and a head stacked on it reads UNROOTED
# (see the companion assertion below), so a guard that skips this question refuses a safe PR
# and tells the operator its head was rebased when it never was.
test_absorbed_base_has_no_own_commits() {
  local dir
  dir=$(make_repo own-absorbed)
  git -C "$dir/wt" checkout -q -b prhead origin/feature/base
  commit "$dir/wt" fix.txt fix "task fix"
  # feature/base merges into main; origin KEEPS the branch.
  git -C "$dir/origin.git" update-ref refs/heads/main refs/heads/feature/base
  git -C "$dir/wt" fetch -q origin

  expect_word no-own "$(own_word "$dir" origin/feature/base)" \
    "own-absorbed: a base the default branch has absorbed must read NO_OWN_COMMITS"
  expect_word unrooted "$(rooted_word "$dir" origin/feature/base prhead)" \
    "own-absorbed: rootedness is not observable against an absorbed base - this is exactly why liveness must be asked FIRST"
  pass "fm_base_has_own_commits reports a base the default branch has absorbed as carrying nothing of its own"
}

# Plain ancestry, not a merge detector. A squash-merged base's own commits are absent from
# the default branch by SHA, so it still reads live and still gets the full guard. Telling a
# squash merge from an abandoned branch takes an inference, and an inference that can be
# wrong is the thing this design refuses to make.
test_squash_merged_base_still_reads_live() {
  local dir
  dir=$(make_repo own-squashed)
  # main gains the base's CONTENT as one new commit, never the base's commits.
  git -C "$dir/wt" checkout -q main
  git -C "$dir/wt" merge -q --squash feature/base >/dev/null 2>&1 || true
  git -C "$dir/wt" -c user.name=t -c user.email=t@t commit -qm "squash feature/base"
  git -C "$dir/wt" push -q origin main
  git -C "$dir/wt" fetch -q origin

  expect_word has-own "$(own_word "$dir" origin/feature/base)" \
    "own-squashed: a squash-merged base still carries its own commits by SHA and must read HAS_OWN_COMMITS - this predicate does not detect a squash merge and must not pretend to"
  pass "fm_base_has_own_commits leaves a squash-merged base reading live, because plain ancestry cannot see a squash"
}

# A question git could not answer is not an answer. Reading it as either verdict would let a
# broken read decide a merge.
test_uncountable_base_is_unknown() {
  local dir
  dir=$(make_repo own-unknown)
  expect_word unknown "$(own_word "$dir" 0000000000000000000000000000000000000000)" \
    "own-unknown: a base git cannot count against must read OWN_COMMITS_UNKNOWN, not live and not absorbed"
  pass "fm_base_has_own_commits reports a count it could not take as UNKNOWN rather than guessing"
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
    "$FM_BASE_HAS_OWN_COMMITS" "$FM_BASE_NO_OWN_COMMITS" "$FM_BASE_OWN_COMMITS_UNKNOWN" \
    | sort | uniq -d)
  [ -z "$dupes" ] \
    || fail "enum: FM_BASE_* outcomes share the value(s) [$dupes] across enums; a value of one could be read as a value of another in the same scope"
  pass "fm-base-lib: no two FM_BASE_* outcomes share a numeric value"
}

test_valid_branch_name
test_probe_present
test_probe_absent
test_probe_failure_is_not_absence
test_live_base_has_own_commits
test_absorbed_base_has_no_own_commits
test_squash_merged_base_still_reads_live
test_uncountable_base_is_unknown
test_head_stacked_on_base_is_rooted
test_head_rebased_onto_default_is_unrooted
test_base_advanced_since_head_is_still_rooted
test_unrelated_histories
test_enum_values_cannot_alias_across_enums
