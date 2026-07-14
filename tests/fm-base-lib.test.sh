#!/usr/bin/env bash
# Behavior tests for bin/fm-base-lib.sh, the shared facts about a task's declared base.
#
# The lib answers two questions and no more. It deliberately says NOTHING about a base's
# end of life - merged, squash-merged, abandoned - because git cannot tell those apart
# without a guess, and every consumer hands that question to a human instead.
#
# fm_base_liveness - IS THIS BASE STILL A LIVE FEATURE BASE? The one question, and the one
# every base-aware consumer decides on: fm-spawn.sh before it records a declaration,
# fm-pr-check.sh before it records pr=, fm-review-diff.sh before it picks a diff base, and
# fm-brief.sh through the crewmate's form of it. A consumer asking a weaker question is how
# four scripts came to give four different answers about one base.
#   (l) on origin, carrying a commit of its own    -> LIVE (guard it)
#   (m) on origin, but the default branch has absorbed everything it carries -> ABSORBED.
#       Existing is NOT liveness: delete-on-merge is off by default, so a merged base that
#       kept its branch is an ordinary end-state with no unmerged history left to drag
#       anywhere - and rootedness is not observable against it (see (h))
#   (n) not on origin at all                       -> GONE, and NOT a claim about whether it
#       merged or was abandoned
#   (o) the question could not be settled          -> LIVENESS_UNKNOWN, never read as either
#       verdict, and carrying git's own error
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

liveness_word() {  # <dir> <base-branch>; echoes live|absorbed|gone|unknown
  local rc=0
  fm_base_liveness "$1/wt" "$2" main || rc=$?
  case "$rc" in
    "$FM_BASE_LIVE") printf 'live' ;;
    "$FM_BASE_ABSORBED") printf 'absorbed' ;;
    "$FM_BASE_GONE") printf 'gone' ;;
    *) printf 'unknown' ;;
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

# THE question, and the one every consumer decides on. A base carrying unmerged work of its
# own is the case the guard exists for.
test_liveness_live_base() {
  local dir
  dir=$(make_repo liveness-live)
  expect_word live "$(liveness_word "$dir" feature/base)" \
    "liveness-live: a base carrying unmerged work of its own must read LIVE"
  pass "fm_base_liveness reports a base with unmerged work of its own as LIVE"
}

# EXISTING IS NOT LIVENESS. GitHub's delete-on-merge is off by default, so a base that merged
# and kept its branch is an ordinary end-state: nothing left to drag onto the default branch,
# and a head stacked on it reads UNROOTED. A consumer that asked the weaker does-it-exist
# question would spawn against it, refuse its PR, and claim its head was rebased when it was
# not.
test_liveness_absorbed_base() {
  local dir
  dir=$(make_repo liveness-absorbed)
  git -C "$dir/origin.git" update-ref refs/heads/main refs/heads/feature/base
  expect_word absorbed "$(liveness_word "$dir" feature/base)" \
    "liveness-absorbed: a base still on origin that the default branch has absorbed must read ABSORBED, not LIVE"
  pass "fm_base_liveness reports a base the default branch has absorbed as ABSORBED, though it is still on origin"
}

# GONE is not a claim about what became of the base. Whether it merged or was abandoned is a
# human's call (bin/fm-pr-check.sh defers it); the lib only reports that origin has no such
# branch.
test_liveness_gone_base() {
  local dir
  dir=$(make_repo liveness-gone)
  git -C "$dir/origin.git" update-ref -d refs/heads/feature/base
  expect_word gone "$(liveness_word "$dir" feature/base)" \
    "liveness-gone: a base deleted from origin must read GONE"
  pass "fm_base_liveness reports a base deleted from origin as GONE"
}

# An infrastructure failure is not a fact about a base. Reading it as either verdict would let
# a network blip spawn a task, pick a diff base, or decide a merge.
test_liveness_unknown_is_not_a_verdict() {
  local dir rc=0
  dir=$(make_repo liveness-unknown)
  git -C "$dir/wt" remote set-url origin "$TMP_ROOT/does-not-exist.git"
  expect_word unknown "$(liveness_word "$dir" feature/base)" \
    "liveness-unknown: an unreachable origin must read UNKNOWN, never LIVE, ABSORBED, or GONE"
  # Called here rather than through liveness_word: an out-param set inside a command
  # substitution never reaches this scope.
  fm_base_liveness "$dir/wt" feature/base main || rc=$?
  [ -n "${FM_BASE_LIVENESS_WHY:-}" ] \
    || fail "liveness-unknown: the caller was given no clause naming what could not be determined"
  [ -n "${FM_BASE_LIVENESS_ERR:-}" ] \
    || fail "liveness-unknown: git's own error was swallowed, so an infrastructure failure cannot be told from a verdict about the base"
  pass "fm_base_liveness reports an unsettleable question as UNKNOWN, naming what failed and keeping git's error"
}

# The commits a caller needs next come back with the answer, so no consumer has to re-resolve
# them - and none can re-resolve them differently.
test_liveness_hands_back_the_commits_it_compared() {
  local dir rc=0
  dir=$(make_repo liveness-outparams)
  fm_base_liveness "$dir/wt" feature/base main || rc=$?
  [ "$rc" = "$FM_BASE_LIVE" ] || fail "liveness-outparams: the fixture base should read LIVE"
  [ "$FM_BASE_TIP" = "$(git -C "$dir/wt" rev-parse origin/feature/base)" ] \
    || fail "liveness-outparams: FM_BASE_TIP is not the base tip it counted against"
  [ "$FM_BASE_DEFAULT_SHA" = "$(git -C "$dir/wt" rev-parse origin/main)" ] \
    || fail "liveness-outparams: FM_BASE_DEFAULT_SHA is not the default-branch commit it counted against"
  pass "fm_base_liveness hands back the base and default-branch commits it compared, for fm_base_head_rooted"
}

# The enums travel as return codes through the same scope in fm-pr-check.sh. Sharing a value
# would let a liveness outcome be read as a rootedness outcome in a merge gate.
test_enum_values_cannot_alias_across_enums() {
  local dupes
  dupes=$(printf '%s\n' \
    "$FM_BASE_PRESENT" "$FM_BASE_PROBE_FAILED" "$FM_BASE_ABSENT" \
    "$FM_BASE_HEAD_ROOTED" "$FM_BASE_HEAD_UNROOTED" "$FM_BASE_HEAD_UNRELATED" \
    "$FM_BASE_HAS_OWN_COMMITS" "$FM_BASE_NO_OWN_COMMITS" "$FM_BASE_OWN_COMMITS_UNKNOWN" \
    "$FM_BASE_LIVE" "$FM_BASE_ABSORBED" "$FM_BASE_GONE" "$FM_BASE_LIVENESS_UNKNOWN" \
    | sort | uniq -d)
  [ -z "$dupes" ] \
    || fail "enum: FM_BASE_* outcomes share the value(s) [$dupes] across enums; a value of one could be read as a value of another in the same scope"
  pass "fm-base-lib: no two FM_BASE_* outcomes share a numeric value"
}

# The crewmate's form of the liveness question must cover EVERY answer it can return. An
# answer with no instruction is an answer the crewmate resolves by guessing.
test_liveness_brief_block_answers_every_outcome() {
  local block
  block=$(fm_base_liveness_brief_block feature/base)
  case "$block" in
    *"git ls-remote --exit-code --heads origin refs/heads/feature/base"*) ;;
    *) fail "brief-block: the crewmate is not told to ask origin whether the branch is there" ;;
  esac
  # shellcheck disable=SC2016  # A literal match against the brief's text: $default is not ours.
  case "$block" in
    *'git rev-list --count "origin/feature/base" "^origin/$default"'*) ;;
    *) fail "brief-block: the crewmate is not told to ask whether the base carries anything the default branch lacks - the half of liveness a mere existence check misses" ;;
  esac
  case "$block" in
    *"blocked: intended base feature/base carries nothing the default branch does not already have"*) ;;
    *) fail "brief-block: an ABSORBED base has no instruction, so the crewmate would stack on a spent base and have its PR refused" ;;
  esac
  case "$block" in
    *"blocked: intended base feature/base is gone from origin"*) ;;
    *) fail "brief-block: a GONE base has no instruction" ;;
  esac
  case "$block" in
    *"blocked: origin could not be asked about intended base feature/base"*) ;;
    *) fail "brief-block: an infrastructure failure has no distinct report, so it would masquerade as a verdict about the base" ;;
  esac
  pass "fm_base_liveness_brief_block gives the crewmate a followable instruction for every answer liveness can return"
}

# Naming the right commands is not enough: the commands must RUN, in the clone the crewmate
# actually gets, and reach the SAME answer fm_base_liveness reaches. `origin/HEAD` is not that
# question and is not dependable - a clone of an empty repo never gets one, which is exactly what
# firstmate's create-the-repo-then-clone-it flow produces (make_repo clones an empty bare repo for
# the same reason). A block that asked `^origin/HEAD` dies with a fatal on a base the scripts call
# LIVE, and the crewmate's decision table reads that fatal as "cannot tell" and blocks a healthy
# task, claiming an infrastructure failure that never happened.
test_liveness_brief_block_agrees_with_the_scripts() {
  local dir snippet out rc count
  dir=$(make_repo brief-block-agrees)
  ! git -C "$dir/wt" symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1 \
    || fail "brief-block-agrees: this clone HAS an origin/HEAD, so it no longer pins the case the crewmate hits in a clone of an empty repo"

  snippet="$TMP_ROOT/brief-block-agrees.sh"
  fm_base_liveness_brief_block feature/base | awk '/^```$/ { f = !f; next } f' > "$snippet"

  # LIVE: the scripts say the base carries one commit main does not have. So must the crewmate.
  expect_word live "$(liveness_word "$dir" feature/base)" \
    "brief-block-agrees: the scripts do not call this base live, so there is nothing for the crewmate's answer to agree with"
  out=$(cd "$dir/wt" && bash "$snippet" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "brief-block-agrees: the commands the brief hands the crewmate do not run in the task's own clone (rc=$rc)"$'\n'"  git: $out"
  count=$(printf '%s\n' "$out" | tail -1)
  expect_word 1 "$count" \
    "brief-block-agrees: the crewmate counts something other than what fm_base_liveness counted for a LIVE base, so the brief and the merge gate would tell different stories about one base"

  # ABSORBED: the default branch takes everything the base carries. Both must see the count fall
  # to 0 - a crewmate that still read 1 here would stack on a spent base.
  git -C "$dir/origin.git" update-ref refs/heads/main refs/heads/feature/base
  expect_word absorbed "$(liveness_word "$dir" feature/base)" \
    "brief-block-agrees: the scripts do not call this base absorbed, so the crewmate's answer cannot be checked against it"
  out=$(cd "$dir/wt" && bash "$snippet" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "brief-block-agrees: the crewmate's commands fail against an absorbed base (rc=$rc)"$'\n'"  git: $out"
  count=$(printf '%s\n' "$out" | tail -1)
  expect_word 0 "$count" \
    "brief-block-agrees: the crewmate does not see an absorbed base as absorbed, so it would root on a base the merge gate refuses"
  pass "fm_base_liveness_brief_block's own commands run in the task's clone and reach the same verdict the scripts reach"
}

test_liveness_live_base
test_liveness_absorbed_base
test_liveness_gone_base
test_liveness_unknown_is_not_a_verdict
test_liveness_hands_back_the_commits_it_compared
test_liveness_brief_block_answers_every_outcome
test_liveness_brief_block_agrees_with_the_scripts
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
