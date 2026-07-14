#!/usr/bin/env bash
# fm-base-lib.sh - the one owner of what a task's declared base branch (base= in
# state/<id>.meta, from fm-brief.sh --base) means on origin RIGHT NOW.
#
# Two consumers must agree exactly, because they gate the same merge:
#   - bin/fm-pr-check.sh  refuses to record pr= or arm the merge poll unless the
#                         PR head is rooted in the base's unmerged history.
#   - bin/fm-review-diff.sh  diffs the crewmate's branch against that base.
#
# Three states, not two. A base branch that is ABSENT from origin is not the same
# as a base branch we FAILED TO ASK ABOUT:
#
#   present  the base is live on origin. Its unmerged history is real, so a head
#            rebased off it would drag that history into the default branch on
#            merge - the hazard the guard exists for. Verify, and refuse if wrong.
#   absent   the base no longer exists on origin. That is the state, and ONLY the
#            state: absence is not proof the base merged. A base that merged and
#            was auto-deleted (GitHub's default) and a base that was abandoned and
#            force-deleted look identical here, and they call for opposite verdicts.
#            fm_base_work_landed below decides between them from a recorded fact.
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

# Landedness outcomes for an absent base (fm_base_work_landed).
FM_BASE_WORK_LANDED=0
FM_BASE_WORK_UNLANDED=1
FM_BASE_WORK_UNKNOWN=3

# fm_base_valid_branch_name: 0 (true) if <name> is a non-empty, dash-free,
# whitespace-free, git-legal branch name. A leading dash matters beyond tidiness:
# the value reaches git as a refspec, where git would read it as an option, and
# `--upload-pack=<cmd>` is an arbitrary-command vector. fm-brief.sh validates on
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
# branch? This is the question a base branch that is GONE from origin poses, and
# the only sound way to answer it. Absence alone says nothing: a base that merged
# and was auto-deleted took the hazard with it, while a base that was ABANDONED and
# deleted left its unmerged commits replayed on the PR head, so merging would land
# them on the default branch - the very incident the guard exists to prevent.
#
# The fact it reasons from is base_sha=, the base's tip on origin recorded by
# fm-spawn.sh at spawn time, when the base necessarily still existed. Two ways that
# commit's work can be carried by the default branch:
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
# The recorded tip is the SPAWN-TIME tip, which is exactly what we want: if the base
# advanced and then merged, the merged content is a superset of the recorded tip's,
# so both tests still hold.
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
