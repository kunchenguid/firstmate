#!/usr/bin/env bash
# Behavior tests for bin/fm-base-state.sh - the CREWMATE's accessor onto what its declared
# base is right now.
#
# A based brief is scaffolded once and relaunched with verbatim, while the base underneath
# it moves: it merges (the base lands first and the child follows is the normal order of a
# stack), and its branch is kept or deleted. So the brief asks this script rather than
# assuming, on every launch and again before it targets a PR at the base - which only works
# if the script answers from the same predicates the merge guard decides on, and never from
# whether the branch happens to exist.
#
# The verdict matrix itself is pinned in tests/fm-base-lib.test.sh. These cases show that
# the crewmate's accessor reports it faithfully, and that every answer it prints is one the
# brief actually has an instruction for.
#
# Matrix:
#   (a) base carrying unmerged work                     -> state=live, plus tip= and default=
#   (b) base squash-merged, branch KEPT                 -> state=landed (existence is not the
#       question: a merged branch is usually kept, and treating it as live would send the
#       crewmate to root on the base's pre-merge commits)
#   (c) base merged and deleted from origin             -> state=landed, decided from base_sha=
#   (d) base deleted from origin WITHOUT merging        -> state=abandoned
#   (e) origin cannot be asked at all                   -> state=unknown, never mistaken for a
#       base that is gone: an infrastructure failure is not a merge
#   (f) meta declares no base                           -> state=none
#   (g) a hand-edited meta with a dash-leading base     -> refuses; the value reaches git as a
#       refspec, where a leading dash is an option
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

BASE_STATE="$ROOT/bin/fm-base-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-base-state)

commit() {  # <dir> <file> <content> <message>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" -c user.name=t -c user.email=t@t commit -qm "$4"
}

# A project clone with a real origin, a main, and a feature/base carrying a commit of its
# own, plus the task meta a crewmate would be launched with.
make_case() {  # <name> [<base-sha>]; echoes the case dir
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/wt" 2>/dev/null
  commit "$dir/wt" seed.txt seed seed
  git -C "$dir/wt" push -q origin main
  git -C "$dir/wt" checkout -q -b feature/base
  commit "$dir/wt" base-only.txt base-work "feature base work"
  git -C "$dir/wt" push -q origin feature/base
  git -C "$dir/wt" checkout -q main
  git -C "$dir/wt" remote set-head origin main >/dev/null 2>&1 || true
  git -C "$dir/wt" fetch -q origin
  printf '%s\n' "$dir"
}

write_meta() {  # <case-dir> <line>...
  local dir=$1; shift
  fm_write_meta "$dir/state/task-b1.meta" \
    "window=fm-task-b1" "worktree=$dir/wt" "project=$dir/wt" \
    "kind=ship" "mode=no-mistakes" "$@"
}

base_tip() {  # <case-dir>
  git -C "$1/origin.git" rev-parse refs/heads/feature/base
}

# Read one key= line out of the script's output, so a test reads as the question it asks.
field() {  # <output> <key>
  printf '%s\n' "$1" | grep "^$2=" | cut -d= -f2-
}

test_live_base() {
  local dir out
  dir=$(make_case live)
  write_meta "$dir" "base=feature/base"
  out=$("$BASE_STATE" "$dir/state/task-b1.meta") \
    || fail "live: fm-base-state.sh should exit 0 when it can answer"
  [ "$(field "$out" state)" = live ] \
    || fail "live: a base carrying unmerged work must report state=live"$'\n'"  got: $out"
  [ -n "$(field "$out" tip)" ] \
    || fail "live: no tip= printed, so a crewmate has nothing to rebase off if the base lands"
  [ "$(field "$out" default)" = main ] \
    || fail "live: no default= printed, so the crewmate cannot name the branch to fall back to"
  pass "fm-base-state.sh: a base carrying unmerged work is live"
}

# Branch existence answers nothing. GitHub's delete-on-merge is off by default, so a merged
# base whose branch is still there is the ordinary end-state - and calling it live would
# send the crewmate to root its branch on the base's pre-merge commits, a whole run that
# fm-pr-check.sh is then guaranteed to refuse.
test_merged_base_whose_branch_was_kept() {
  local dir out tree parent squash
  dir=$(make_case merged-kept)
  tree=$(git -C "$dir/origin.git" rev-parse "refs/heads/feature/base^{tree}")
  parent=$(git -C "$dir/origin.git" rev-parse refs/heads/main)
  squash=$(git -C "$dir/origin.git" commit-tree "$tree" -p "$parent" -m 'squash feature/base')
  git -C "$dir/origin.git" update-ref refs/heads/main "$squash"
  write_meta "$dir" "base=feature/base"
  out=$("$BASE_STATE" "$dir/state/task-b1.meta") || fail "merged-kept: should exit 0"
  [ "$(field "$out" state)" = landed ] \
    || fail "merged-kept: a squash-merged base whose branch was kept must report state=landed, not live"$'\n'"  got: $out"
  pass "fm-base-state.sh: a merged base reads landed even with its branch still on origin"
}

test_merged_base_that_was_deleted() {
  local dir out tip
  dir=$(make_case merged-deleted)
  tip=$(base_tip "$dir")
  git -C "$dir/origin.git" update-ref refs/heads/main refs/heads/feature/base
  git -C "$dir/origin.git" update-ref -d refs/heads/feature/base
  write_meta "$dir" "base=feature/base" "base_sha=$tip"
  out=$("$BASE_STATE" "$dir/state/task-b1.meta") || fail "merged-deleted: should exit 0"
  [ "$(field "$out" state)" = landed ] \
    || fail "merged-deleted: a base that merged and was deleted must report state=landed"$'\n'"  got: $out"
  pass "fm-base-state.sh: a base that merged and was deleted reads landed, from its recorded tip"
}

# The mirror image, indistinguishable from the last case to anything that asks whether the
# branch exists - and the reason that question is never the one asked.
test_abandoned_base() {
  local dir out tip
  dir=$(make_case abandoned)
  tip=$(base_tip "$dir")
  git -C "$dir/origin.git" update-ref -d refs/heads/feature/base
  write_meta "$dir" "base=feature/base" "base_sha=$tip"
  out=$("$BASE_STATE" "$dir/state/task-b1.meta") || fail "abandoned: should exit 0"
  [ "$(field "$out" state)" = abandoned ] \
    || fail "abandoned: a base deleted WITHOUT merging must report state=abandoned, not landed"$'\n'"  got: $out"
  pass "fm-base-state.sh: a base deleted without merging reads abandoned, not landed"
}

test_unreachable_origin_is_unknown() {
  local dir out
  dir=$(make_case unreachable)
  write_meta "$dir" "base=feature/base"
  git -C "$dir/wt" remote set-url origin "$dir/no-such-origin.git"
  out=$("$BASE_STATE" "$dir/state/task-b1.meta" 2>/dev/null) \
    || fail "unreachable: an unanswerable question is still an answer (state=unknown), not a crash"
  [ "$(field "$out" state)" = unknown ] \
    || fail "unreachable: an origin that cannot be asked must be unknown, never read as a gone or merged base"$'\n'"  got: $out"
  pass "fm-base-state.sh: an origin that cannot be asked is unknown, never a merged base"
}

test_no_base_declared() {
  local dir out
  dir=$(make_case unbased)
  write_meta "$dir"
  out=$("$BASE_STATE" "$dir/state/task-b1.meta") || fail "unbased: should exit 0"
  [ "$(field "$out" state)" = none ] \
    || fail "unbased: a task with no base= must report state=none"$'\n'"  got: $out"
  pass "fm-base-state.sh: a task with no declared base reports none"
}

# meta is a plain text file a human can edit, and the value reaches git as a refspec, where
# a leading dash is read as an option (--upload-pack=<cmd> is an arbitrary-command vector).
test_refuses_a_dash_leading_base() {
  local dir rc=0
  dir=$(make_case dash-base)
  write_meta "$dir" "base=--upload-pack=touch /tmp/pwned"
  "$BASE_STATE" "$dir/state/task-b1.meta" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "dash-base: a base git would read as an option must be refused, not passed to git"
  pass "fm-base-state.sh: refuses a recorded base that git would read as an option"
}

test_live_base
test_merged_base_whose_branch_was_kept
test_merged_base_that_was_deleted
test_abandoned_base
test_unreachable_origin_is_unknown
test_no_base_declared
test_refuses_a_dash_leading_base
