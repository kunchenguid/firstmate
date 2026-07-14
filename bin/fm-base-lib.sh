#!/usr/bin/env bash
# fm-base-lib.sh - the one owner of what a task's declared base branch (base= in
# state/<id>.meta, from fm-spawn.sh --base) means on origin RIGHT NOW.
#
# Two consumers must agree exactly, because they gate the same merge:
#   - bin/fm-pr-check.sh  refuses to record pr= or arm the merge poll unless the
#                         PR head is rooted in the base's unmerged history.
#   - bin/fm-review-diff.sh  diffs the crewmate's branch against that base.
#
# THE DECIDING QUESTION IS NOT WHETHER THE BASE BRANCH STILL EXISTS. It is whether
# THE BASE'S WORK HAS LANDED IN THE DEFAULT BRANCH. Branch existence is an unsound
# proxy for that in BOTH directions:
#
#   deleted without merging   an abandoned feature, a closed base PR, a force-deleted
#                             branch. The base's commits never landed, the pipeline
#                             replayed them onto the head when it rebased onto the
#                             default branch, and merging would drag them in. The
#                             hazard is fully present even though the branch is gone.
#   merged but NOT deleted    GitHub's "automatically delete head branches" is OFF by
#                             default, so this is at least as common an end-state as
#                             the deleted one. The base's work is already in the
#                             default branch: nothing is left to drag anywhere, and
#                             guarding it would refuse a safe merge forever.
#
# So fm_base_work_landed below is the single predicate both consumers decide on, and
# the origin probe is an INPUT to it, not the decision. Standing the guard down is
# the only relaxation, and it requires proof that the work landed; anything short of
# proof keeps the guard on.
#
# The probe still has three states, because a base that is ABSENT from origin is not
# the same as a base we FAILED TO ASK ABOUT:
#
#   present  the base is live on origin, so its own tip is the authoritative fact to
#            test for landedness.
#   absent   the base no longer exists on origin. That is the state, and ONLY the
#            state. The fact to test is then the tip recorded at spawn (base_sha=),
#            the last time the branch demonstrably existed.
#   failed   the probe itself could not run (auth, network, a broken remote). We
#            know nothing, so callers stay fail-closed.
#
# `git ls-remote --exit-code` distinguishes all three at the source: 0 = the ref
# matched, 2 = no ref matched, anything else = the probe failed. That is a real
# discriminator, not a guess at git's error text.
#
# Sourced by bin/fm-pr-check.sh and bin/fm-review-diff.sh. No side effects on
# source. set -u / set -e safe.

# Probe outcomes. Callers compare against these names, never bare numbers.
FM_BASE_PRESENT=0
FM_BASE_PROBE_FAILED=1
FM_BASE_ABSENT=2

# Landedness outcomes (fm_base_work_landed).
FM_BASE_WORK_LANDED=0
FM_BASE_WORK_UNLANDED=1
FM_BASE_WORK_UNKNOWN=3

# Rootedness outcomes (fm_base_head_rooted).
FM_BASE_HEAD_ROOTED=0
FM_BASE_HEAD_UNROOTED=1
FM_BASE_HEAD_UNRELATED=2

# The guard's own verdict, returned up through bin/fm-pr-check.sh's assertion and
# compared by its caller. It MUST NOT share a value with any FM_BASE_* outcome above:
# those travel as return codes through the same scope, and "stand the guard down and
# record pr=" is the exact opposite verdict to "we could not tell" (FM_BASE_WORK_UNKNOWN)
# in a merge gate. Aliasing them would turn every indeterminate answer into a fail-open.
# shellcheck disable=SC2034 # FM_BASE_GUARD_STAND_DOWN is read by bin/fm-pr-check.sh, which sources this lib.
FM_BASE_GUARD_STAND_DOWN=4

# fm_base_valid_branch_name: 0 (true) if <name> is a non-empty, dash-free,
# whitespace-free, git-legal branch name. A leading dash matters beyond tidiness:
# the value reaches git as a refspec, where git would read it as an option, and
# `--upload-pack=<cmd>` is an arbitrary-command vector. fm-spawn.sh validates on
# the way in; the consumers validate again on the way out, because meta is a plain
# text file a human can edit.
fm_base_valid_branch_name() {  # <name>
  local name=${1-}
  [ -n "$name" ] || return 1
  case "$name" in
    -*) return 1 ;;
    *[[:space:]]*) return 1 ;;
  esac
  git check-ref-format --branch "$name" >/dev/null 2>&1 || return 1
  return 0
}

# fm_base_valid_commit_id: 0 (true) if <id> looks like a git object id. base_sha=
# reaches git as a rev, where a leading dash would be read as an option; and meta is
# a plain text file a human can edit, so the recorded value is checked on the way out
# just as the branch name is.
fm_base_valid_commit_id() {  # <id>
  local id=${1-}
  case "$id" in
    *[!0-9a-f]* | '') return 1 ;;
  esac
  [ "${#id}" -ge 7 ] && [ "${#id}" -le 64 ]
}

# fm_base_probe_origin: ask origin whether <branch> exists, from within <git-dir>.
# Returns FM_BASE_PRESENT, FM_BASE_ABSENT, or FM_BASE_PROBE_FAILED. On PRESENT it
# sets FM_BASE_PROBE_SHA to the branch's tip on origin, which is how fm-spawn.sh
# records the durable base_sha= that fm_base_work_landed later reasons from. It
# always sets FM_BASE_PROBE_ERR to git's stderr, so a caller's fail-closed refusal
# can name the infrastructure failure instead of it masquerading as a wrong-base
# verdict. The ref is fully qualified, so a branch name can never be read as an
# option.
fm_base_probe_origin() {  # <git-dir> <branch>
  local dir=${1-} branch=${2-} rc=0 out err_file
  FM_BASE_PROBE_ERR=
  FM_BASE_PROBE_SHA=
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-base-probe.XXXXXX")
  out=$(git -C "$dir" ls-remote --exit-code --heads origin \
    "refs/heads/$branch" 2>"$err_file") || rc=$?
  # shellcheck disable=SC2034 # FM_BASE_PROBE_ERR is read by callers (fm-pr-check.sh, fm-review-diff.sh) after the probe returns.
  FM_BASE_PROBE_ERR=$(cat "$err_file" 2>/dev/null || true)
  rm -f "$err_file"
  case "$rc" in
    0)
      # shellcheck disable=SC2034 # FM_BASE_PROBE_SHA is read by fm-spawn.sh after the probe returns.
      FM_BASE_PROBE_SHA=${out%%[[:space:]]*}
      return "$FM_BASE_PRESENT"
      ;;
    2) return "$FM_BASE_ABSENT" ;;
    *) return "$FM_BASE_PROBE_FAILED" ;;
  esac
}

# fm_base_work_landed: did the declared base's work actually reach the default
# branch? THIS IS THE ONE PREDICATE THE GUARD AND THE REVIEW DIFF BOTH DECIDE ON,
# whether the base branch is still on origin or not, because it is the question that
# actually determines whether any hazard is left:
#
#   landed    the base's work is in the default branch already. There is no unmerged
#             feature history left to drag into it, so the declared base has nothing
#             to guard and nothing to diff against: callers stand down and treat the
#             task as an ordinary default-branch PR. It does not matter whether the
#             branch was deleted afterwards or kept.
#   unlanded  the base still carries unmerged work. This is the live-feature-branch
#             case the guard exists for - and it is ALSO an abandoned base that was
#             deleted without merging, whose commits the pipeline replayed onto the
#             head. Callers keep guarding.
#   unknown   we could not tell. Not landed: callers stay fail-closed and never
#             relax on it.
#
# The fact it reasons from is a base tip: the live tip on origin while the branch is
# still there, else base_sha=, the tip fm-spawn.sh recorded at spawn time when the
# base necessarily still existed. Two ways that commit's work can be carried by the
# default branch:
#
#   ancestor  the base merged with a merge commit or a fast-forward, so the recorded
#             commit is literally an ancestor of the default branch.
#   contained the base was squash-merged or rebase-merged (a squash is firstmate's
#             own default, and GitHub's most common setting), so the commit is NOT an
#             ancestor, but its content is already in the default branch: merging the
#             base into the default branch again would change nothing. Tested with a
#             real 3-way merge (git merge-tree --write-tree, git >= 2.38), so a
#             default branch that advanced past the squash still reads as containing
#             the base.
#
# When the tip is the recorded SPAWN-TIME one, that is exactly what we want: if the
# base advanced and then merged, the merged content is a superset of the recorded
# tip's, so both tests still hold. When the branch is still on origin its LIVE tip is
# used instead, which is stricter: a base that merged and then took new commits reads
# as unlanded, and the guard rightly stays on.
#
# Returns FM_BASE_WORK_LANDED, FM_BASE_WORK_UNLANDED, or FM_BASE_WORK_UNKNOWN (the
# recorded commit is not in the local object store, or the containment merge could
# not be run or conflicted). UNKNOWN is not LANDED: callers stay fail-closed on it.
# Sets FM_BASE_WORK_HOW to ancestor|contained|no-commit|no-merge|diverged.
fm_base_work_landed() {  # <git-dir> <base-sha> <default-sha>
  local dir=${1-} base_sha=${2-} default_sha=${3-} out rc=0 merged_tree default_tree
  FM_BASE_WORK_HOW=
  if ! git -C "$dir" cat-file -e "$base_sha^{commit}" 2>/dev/null; then
    # shellcheck disable=SC2034 # FM_BASE_WORK_HOW is read by callers after the check returns.
    FM_BASE_WORK_HOW=no-commit
    return "$FM_BASE_WORK_UNKNOWN"
  fi
  if git -C "$dir" merge-base --is-ancestor "$base_sha" "$default_sha" 2>/dev/null; then
    FM_BASE_WORK_HOW=ancestor
    return "$FM_BASE_WORK_LANDED"
  fi
  out=$(git -C "$dir" merge-tree --write-tree "$default_sha" "$base_sha" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    # A conflict (rc 1) means the base's changes cannot be replayed onto the default
    # branch cleanly, so we cannot prove they are already there; an older git with no
    # `merge-tree --write-tree` lands here too. Neither is evidence of a merge.
    FM_BASE_WORK_HOW=no-merge
    return "$FM_BASE_WORK_UNKNOWN"
  fi
  merged_tree=${out%%$'\n'*}
  default_tree=$(git -C "$dir" rev-parse --verify --quiet "$default_sha^{tree}") || {
    FM_BASE_WORK_HOW=no-merge
    return "$FM_BASE_WORK_UNKNOWN"
  }
  if [ -n "$merged_tree" ] && [ "$merged_tree" = "$default_tree" ]; then
    FM_BASE_WORK_HOW=contained
    return "$FM_BASE_WORK_LANDED"
  fi
  # shellcheck disable=SC2034 # FM_BASE_WORK_HOW is read by callers after the check returns.
  FM_BASE_WORK_HOW=diverged
  return "$FM_BASE_WORK_UNLANDED"
}

# fm_base_head_rooted: is <head-sha> rooted in the base's OWN unmerged history, rather
# than in the default branch? The head must fork from a commit the default branch cannot
# reach; a merge-base the default branch CAN reach means the head carries none of the
# base's unmerged work, because it was rebased onto the default branch - the incident.
#
# It deliberately does NOT ask the head to descend from the base's CURRENT TIP. A
# stacked PR whose base is itself under review sees that base advance all the time, and
# a head that is merely behind is still correctly based and safe to merge; demanding
# tip-descent would turn every routine base advance into a hard merge refusal.
#
# Only meaningful for an UNLANDED base. Once the base's work is in the default branch it
# has no unmerged history of its own, so every merge-base is reachable from the default
# branch and this would report UNROOTED for a head that is perfectly fine - which is why
# callers ask fm_base_work_landed FIRST and stand down before ever getting here.
#
# Returns FM_BASE_HEAD_ROOTED, FM_BASE_HEAD_UNROOTED, or FM_BASE_HEAD_UNRELATED (the two
# commits share no history at all). Sets FM_BASE_MERGE_BASE to the branch point when
# there is one, so a caller's refusal can name it.
fm_base_head_rooted() {  # <git-dir> <base-sha> <head-sha> <default-sha>
  local dir=${1-} base_sha=${2-} head_sha=${3-} default_sha=${4-} merge_base
  FM_BASE_MERGE_BASE=
  merge_base=$(git -C "$dir" merge-base "$base_sha" "$head_sha" 2>/dev/null) \
    || return "$FM_BASE_HEAD_UNRELATED"
  [ -n "$merge_base" ] || return "$FM_BASE_HEAD_UNRELATED"
  # shellcheck disable=SC2034 # FM_BASE_MERGE_BASE is read by callers after the check returns.
  FM_BASE_MERGE_BASE=$merge_base
  if git -C "$dir" merge-base --is-ancestor "$merge_base" "$default_sha" 2>/dev/null; then
    return "$FM_BASE_HEAD_UNROOTED"
  fi
  return "$FM_BASE_HEAD_ROOTED"
}
