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
#   absent   the base no longer exists on origin. That is the NORMAL end-state of
#            a stacked PR: the base merged and GitHub deleted the branch (it does
#            so by default), retargeting the child PR to the default branch. The
#            hazard is gone with it - there is no unmerged feature history left to
#            drag anywhere - so callers stand the base handling down and fall back
#            to ordinary default-branch behavior. Refusing here would permanently
#            deadlock a legitimate merge, which is a worse failure than the
#            incident the guard prevents.
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

# fm_base_probe_origin: ask origin whether <branch> exists, from within <git-dir>.
# Returns FM_BASE_PRESENT, FM_BASE_ABSENT, or FM_BASE_PROBE_FAILED, and sets
# FM_BASE_PROBE_ERR to git's stderr so a caller's fail-closed refusal can name the
# infrastructure failure instead of it masquerading as a wrong-base verdict.
# The ref is fully qualified, so a branch name can never be read as an option.
fm_base_probe_origin() {  # <git-dir> <branch>
  local dir=${1-} branch=${2-} rc=0
  FM_BASE_PROBE_ERR=
  # shellcheck disable=SC2034 # FM_BASE_PROBE_ERR is read by callers (fm-pr-check.sh, fm-review-diff.sh) after the probe returns.
  FM_BASE_PROBE_ERR=$(git -C "$dir" ls-remote --exit-code --heads origin \
    "refs/heads/$branch" 2>&1 >/dev/null) || rc=$?
  case "$rc" in
    0) return "$FM_BASE_PRESENT" ;;
    2) return "$FM_BASE_ABSENT" ;;
    *) return "$FM_BASE_PROBE_FAILED" ;;
  esac
}
