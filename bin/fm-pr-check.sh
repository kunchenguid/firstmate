#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
#
# THIS HEADER IS THE ONE OWNER OF THE PR-BASE GUARD CONTRACT. AGENTS.md and
# docs/architecture.md state the operator-facing outcome and point here; do not
# restate the mechanics there.
#
# When state/<id>.meta records a non-default base= (declared with fm-spawn.sh
# --base, which also records the base's tip at spawn time as base_sha=), this guards
# the PR's base before merge. meta is the single source of truth for a task's base,
# so retiring a declaration is one edit - drop the base= line - and every refusal
# below can name it as a recovery that actually works.
#
# THE GUARD DECIDES NOTHING ITSELF. It resolves what the base IS (fm_base_resolve_state)
# and where the head is ROOTED (fm_base_head_rooted), then hands both to fm_base_verdict -
# all three in bin/fm-base-lib.sh, which owns why neither question means anything without
# the other. bin/fm-review-diff.sh picks its diff base from the same verdict, so review and
# merge cannot disagree about what a declared base means. Branch existence decides nothing:
# it only chooses which tip the predicates reason from, and a fetch that fails is never
# read as a base that merged.
#
# The verdict, and what this script does with it:
#
#   ORDINARY        the head sits on the default branch and the base has merged, so
#                   nothing it once carried is unmerged any more. THE GUARD STANDS DOWN,
#                   loudly, AND VERIFIES THE PR AS THE ORDINARY DEFAULT-BRANCH PR IT NOW
#                   IS. Guarding it against the base would deadlock a legitimate merge
#                   forever behind a recovery - retarget onto the base - that is a no-op
#                   at best and impossible at worst.
#                   Standing down is NOT skipping the check. The base label must still
#                   resolve, and it must be the DEFAULT BRANCH: a PR still pointed at the
#                   merged base would merge into that stale branch, so the fix would never
#                   reach the default branch at all, while fm-teardown.sh would read a
#                   MERGED PR and release the work. That is reachable whenever the base
#                   merged without being deleted, because a no-mistakes crewmate is
#                   required to retarget the PR onto the base before it reports done. So a
#                   stood-down guard refuses a PR that still targets anything but the
#                   default branch, and names the retarget BACK to it.
#   STACKED_LIVE    correctly stacked on a base that still carries unmerged work - PROVED
#                   to, never merely assumed, because "we could not tell whether that base
#                   merged" is INDETERMINATE, not this. Require the PR's base label to
#                   target it (gh pr view --json baseRefName), so a PR opened against the
#                   default branch cannot drag the base's unmerged commits into it, and
#                   pass. Rootedness is not tip-descent: a base that merely ADVANCED past
#                   the head is fine.
#   STACKED_LANDED  a squash or rebase merge put the base's CONTENT in the default branch
#                   but not its COMMITS, and this head still carries them. Merging it into
#                   the default branch would land them all over again, and its diff shows
#                   the base's already-merged changes as part of this task. REFUSE - and
#                   prescribe the head's REBASE ONTO THE DEFAULT BRANCH, because a
#                   retarget alone leaves those commits on the head.
#   UNSTACKED       the base still carries unmerged history, so the head was rebased off
#                   it onto the default branch and merging would drag that history in.
#                   That is the launch incident (data/learnings.md 2026-07-07). REFUSE.
#   ABANDONED_BASE  the base was deleted from origin WITHOUT merging. Its never-merged
#                   commits ride on this head either way, and there is no branch left to
#                   target. REFUSE by name.
#   INDETERMINATE   the question was never ANSWERED: origin could not be asked (auth,
#                   network), the base is gone with no usable recorded tip, the containment
#                   merge could not be RUN (a git older than 2.38), or the head and the base
#                   share no history. REFUSE. Never a relaxation, and never quietly
#                   downgraded to one of the answers above: passing a PR the guard never
#                   verified is the fail-open it exists to close - if that base did in fact
#                   merge, merging this PR into it lands the fix on a dead branch and never
#                   on the default branch, while fm-teardown.sh reads a MERGED PR and
#                   releases the work. Name git's own error where there is one, so an
#                   infrastructure failure is diagnosable instead of masquerading as a
#                   wrong-base verdict.
#                   A base whose replay merely CONFLICTS with the default branch is NOT
#                   this: a conflict proves the base's content is not cleanly in the
#                   default branch, so it is an unmerged base like any other, and it is
#                   judged as STACKED_LIVE or UNSTACKED above. Refusing it would block
#                   every stacked task whose base has drifted from the default branch.
#
# The no-mistakes pipeline cannot be told a base - it always rebases onto the
# repo default and opens the PR there - so for a based task the expected recovery
# is to retarget the PR's base (gh-axi pr edit --base <branch>), which the
# pipeline's monitor picks up: it re-rebases onto the new base and force-pushes a
# clean head. This guard is what makes a wrong-based PR impossible to merge
# unnoticed; it does not steer the pipeline. Every refusal names the recovery that
# fits the state it actually found, because an instruction that cannot change the
# state it is printed in just sends the reader in a circle.
#
# The assertion is otherwise fail-closed: any resolution failure (missing
# worktree, unfetchable head/default, unresolvable base label) refuses, so a
# wrong-based or unverifiable head never reaches merge.
# With no base= (the common case) the whole block is skipped and behavior is exactly
# as before: the repo default branch is the base.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-base-lib.sh
. "$SCRIPT_DIR/fm-base-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

META="$STATE/$ID.meta"
WT=
BASE=
BASE_SHA=
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  BASE=$(grep '^base=' "$META" | tail -1 | cut -d= -f2- || true)
  BASE_SHA=$(grep '^base_sha=' "$META" | tail -1 | cut -d= -f2- || true)
fi

# A hand-edited meta could carry a base= that git would read as an option rather
# than a ref. fm-spawn.sh validates on the way in; validate again on the way out.
if [ -n "$BASE" ] && ! fm_base_valid_branch_name "$BASE"; then
  echo "error: task $ID records base='$BASE', which is not a valid git branch name (it must be non-empty, free of whitespace, and must not begin with '-'). Refusing before merge." >&2
  exit 1
fi
if [ -n "$BASE_SHA" ] && ! fm_base_valid_commit_id "$BASE_SHA"; then
  echo "error: task $ID records base_sha='$BASE_SHA', which is not a git object id, so the base's recorded tip cannot be trusted to decide whether that base merged. Refusing before merge." >&2
  exit 1
fi

# Parse the PR number from the URL for the refs/pull/<n>/head fetch below.
pr_number_from_url() {
  local url=$1 n
  case "$url" in
    *"/pull/"*) n=${url##*/pull/}; n=${n%%[!0-9]*} ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# Resolve the PR's base label and head SHA in ONE gh call, shared by the base
# guard and the pr_head= recording below. Best-effort: a failure leaves both
# empty, which the guard treats as fail-closed and the default path treats
# exactly as before (no pr_head= line).
PR_BASE_LABEL=
PR_HEAD_OID=
resolve_pr_fields() {
  local out base head extra
  [ -n "$WT" ] && [ -d "$WT" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  out=$(cd "$WT" && gh pr view "$URL" --json baseRefName,headRefOid \
    -q '[.baseRefName, .headRefOid] | @tsv' 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  # Split strictly on the tab. `cut` would not do: without -s it echoes a line
  # carrying no delimiter IN FULL for every field asked of it, so a single
  # undelimited field would silently land the SAME string in both variables and
  # record a bogus pr_head= that fm-review-diff.sh and fm-teardown.sh then read
  # as a commit sha. Anything but exactly two non-empty fields is malformed:
  # say so and leave both empty, so the base guard fails closed.
  IFS=$'\t' read -r base head extra <<< "$out"
  if [ -z "$base" ] || [ -z "$head" ] || [ -n "$extra" ]; then
    echo "warning: gh returned a malformed base/head response for $URL ('$out'); treating both as unresolved." >&2
    return 1
  fi
  PR_BASE_LABEL=$base
  PR_HEAD_OID=$head
  return 0
}
resolve_pr_fields || true

# The repo's default branch, needed to tell the base's own unmerged history apart
# from history the default branch already carries.
default_branch() {
  local ref branch
  ref=$(git -C "$WT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$WT" show-ref --verify --quiet "refs/remotes/origin/$branch" \
      || git -C "$WT" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s' "$branch"
      return 0
    fi
  done
  return 1
}

# ORDINARY. The declared base's work IS in the default branch and this head sits there
# too, so the base merged and there is nothing left to guard it against. Say so out loud
# - a guard that relaxes silently is a guard nobody can audit - and then VERIFY THE PR AS
# THE ORDINARY DEFAULT-BRANCH PR IT NOW IS. Standing down swaps the base the PR is checked
# against; it does not skip the check, so the label must now be the default branch.
# Verify BEFORE announcing: the label check can still refuse, and in a merge gate the
# message is the only signal an operator gets - a confident "the guard stands down and
# this PR is verified" printed one line above "error: refusing" contradicts itself.
stand_down_landed_base() {  # <default-branch-name> <why> <pr-number>
  local default_branch_name=$1 why=$2 n=$3
  if [ -z "$PR_BASE_LABEL" ]; then
    echo "error: task $ID declares intended base '$BASE', whose work has merged - but the PR's base label could not be resolved via gh, so it cannot be confirmed to target '$default_branch_name'. Refusing before merge." >&2
    return 1
  fi
  if [ "$PR_BASE_LABEL" != "$default_branch_name" ]; then
    echo "error: task $ID PR is opened against base '$PR_BASE_LABEL', but that base has already merged - refusing to record pr= or arm the merge poll before merge." >&2
    echo "  Merging into an already-merged branch would land this fix on '$PR_BASE_LABEL' and never on '$default_branch_name', while the PR would still read as MERGED." >&2
    echo "  Recovery: retarget the PR back to the default branch with 'gh-axi pr edit $n --base $default_branch_name', then drop the 'base=$BASE' line from $META and re-run fm-pr-check." >&2
    return 1
  fi
  echo "notice: task $ID declares intended base '$BASE', and its work has already merged into '$default_branch_name'; the PR head sits on the default branch and carries none of the base's own commits." >&2
  echo "  Its work IS carried by the default branch '$default_branch_name' ($why), so the base merged and there is nothing left to guard." >&2
  echo "  PR base label : $PR_BASE_LABEL" >&2
  echo "  No unmerged feature history can be dragged into '$default_branch_name', so the base guard stands down and this PR is verified as the ordinary default-branch PR it now is." >&2
  echo "  Drop the 'base=$BASE' line from $META to retire the declaration for good." >&2
  return 0
}

# STACKED_LIVE. Correctly stacked on a base PROVED to still carry unmerged work - the state
# the whole feature exists to protect. The label must target that base, or merging would
# drag its unmerged commits into whatever the PR points at instead.
#
# There is no "stacked on a base we could not settle" case to handle here, by construction:
# an unsettled landedness resolves to INDETERMINATE, not to this verdict, so nothing that
# reaches this function is unverified.
verify_stacked_on_live_base() {  # <pr-number>
  local n=$1
  if [ -z "$PR_BASE_LABEL" ]; then
    echo "error: task $ID declares intended base '$BASE' but the PR's base label could not be resolved via gh; cannot verify the PR targets that base. Refusing before merge." >&2
    return 1
  fi
  if [ "$PR_BASE_LABEL" != "$BASE" ]; then
    echo "error: task $ID PR is opened against base '$PR_BASE_LABEL', not its intended base '$BASE' - refusing to record pr= or arm the merge poll before merge." >&2
    echo "  Merging it would land '$BASE''s unmerged commits into '$PR_BASE_LABEL'." >&2
    echo "  Recovery: retarget the PR's base with 'gh-axi pr edit $n --base $BASE'. The no-mistakes pipeline's monitor picks the new base up, re-rebases the branch onto it, and force-pushes a clean head; then re-run fm-pr-check." >&2
    return 1
  fi
  return 0
}

# STACKED_LANDED. The PR head still carries the declared base's OWN commits, and that base
# has already merged. A squash or rebase merge (a squash is firstmate's own default, and
# GitHub's most common setting) puts the base's CONTENT in the default branch but not its
# COMMITS, so this head is the one head that would land them all over again - and its diff
# presents the base's already-merged changes as part of this task's. The recovery is the
# head's REBASE, not a retarget: retargeting the label leaves those commits exactly where
# they are.
refuse_head_carries_merged_base() {  # <default-branch-name> <base-sha> <pr-sha> <how> <pr-number>
  local default_branch_name=$1 base_sha=$2 pr_sha=$3 how=$4 n=$5
  echo "error: task $ID PR head is still stacked on its intended base '$BASE', but that base has already merged - refusing to record pr= or arm the merge poll before merge." >&2
  echo "  intended base : $BASE ($base_sha)" >&2
  [ -z "$PR_BASE_LABEL" ] || echo "  PR base label : $PR_BASE_LABEL" >&2
  echo "  PR head       : $pr_sha" >&2
  echo "  branch point  : $FM_BASE_MERGE_BASE (NOT reachable from the default branch '$default_branch_name')" >&2
  echo "  '$BASE''s work is carried by '$default_branch_name' ($how), but this head is rooted in the base's own pre-merge commits, which a squash or rebase merge left out of '$default_branch_name' by commit id. Merging would land them there a second time." >&2
  echo "  Recovery: rebase the head onto the default branch so it carries only this task's commits - 'git rebase --onto origin/$default_branch_name $base_sha fm/$ID' then force-push with lease - and retarget the PR with 'gh-axi pr edit $n --base $default_branch_name' if it does not already target it. Then drop the 'base=$BASE' line from $META (the base has merged; there is nothing left to stack on) and re-run fm-pr-check." >&2
  return 1
}

# UNSTACKED. The head forks from a commit the default branch can reach, while the base
# still carries unmerged work: the head was rebased off the base onto the default branch,
# and the pipeline replayed the base's own commits onto it when it did. Merging would land
# them on the default branch - the launch incident.
refuse_head_rebased_off_base() {  # <default-branch-name> <base-sha> <pr-sha> <pr-number>
  local default_branch_name=$1 base_sha=$2 pr_sha=$3 n=$4
  echo "error: task $ID PR is not stacked on its intended base - refusing to record pr= or arm the merge poll before merge." >&2
  echo "  intended base : $BASE ($base_sha)" >&2
  [ -z "$PR_BASE_LABEL" ] || echo "  PR base label : $PR_BASE_LABEL" >&2
  echo "  PR head       : $pr_sha" >&2
  echo "  branch point  : $FM_BASE_MERGE_BASE (reachable from the default branch '$default_branch_name')" >&2
  echo "  The head carries none of '$BASE''s unmerged history, so it was rebased onto the default branch - merging it would not deliver the fix onto '$BASE'." >&2
  # The recovery has to fit the state actually found. Once the PR already targets the
  # base, telling the reader to retarget it is a no-op they have performed - and
  # re-running this check would just print it again, so a merge-blocking refusal would
  # offer no way forward at all. What is missing then is the HEAD's re-rebase, not the
  # label's.
  if [ "$PR_BASE_LABEL" = "$BASE" ]; then
    echo "  The PR already targets '$BASE', so the retarget landed; it is the head that has not been re-rebased onto it yet." >&2
    echo "  Recovery: let the no-mistakes pipeline's monitor re-rebase the branch onto '$BASE' and force-push, then re-run fm-pr-check. To do it by hand: 'git rebase --onto origin/$BASE origin/$default_branch_name fm/$ID' then force-push with lease." >&2
  else
    echo "  Recovery: retarget the PR's base with 'gh-axi pr edit $n --base $BASE'. The no-mistakes pipeline's monitor picks the new base up, re-rebases the branch onto it, and force-pushes a clean head; then re-run fm-pr-check." >&2
  fi
  echo "  (A base that merely ADVANCED past the head is fine and is not refused here - only a head rooted in the default branch is.)" >&2
  return 1
}

# ABANDONED_BASE. The declared base was deleted from origin and its work is demonstrably
# NOT in the default branch - an abandoned feature, a closed base PR, a force-deleted
# branch. Its never-merged commits ride on this head, either replayed by the pipeline's
# rebase or carried directly, and there is no branch left to target instead.
refuse_abandoned_base() {  # <default-branch-name> <default-sha> <base-sha>
  local default_branch_name=$1 default_sha=$2 base_sha=$3
  echo "error: task $ID declares intended base '$BASE', and that branch was deleted from origin WITHOUT merging - refusing to record pr= or arm the merge poll before merge." >&2
  echo "  recorded base tip : $base_sha" >&2
  echo "  default branch    : $default_branch_name ($default_sha)" >&2
  echo "  The base's work is NOT in '$default_branch_name', so this is an abandoned base, not a merged one, and this PR head carries its never-merged commits. Merging would land that abandoned work on '$default_branch_name'." >&2
  echo "  Recovery: review what this PR would actually land with 'bin/fm-review-diff.sh $ID'. If the base's work is meant to be dropped, reset the branch onto '$default_branch_name' with only this task's own commits and force-push; if the declaration is simply stale, drop the 'base=$BASE' line from $META. Then re-run fm-pr-check." >&2
  return 1
}

# INDETERMINATE. The verdict could not be settled at all. Never a stand-down: relaxing is
# the guard's only concession and it takes proof. Name WHICH question went unanswered, so
# an infrastructure failure reads as one instead of as a wrong-base verdict, and name the
# escape that fits it.
refuse_indeterminate() {  # <default-branch-name>
  local default_branch_name=$1
  local review="  Recovery: review what this PR would actually land with 'bin/fm-review-diff.sh $ID'. If it is now an ordinary '$default_branch_name' PR, drop the 'base=$BASE' line from $META to retire the declaration, then re-run fm-pr-check."
  case "$FM_BASE_VERDICT_WHY" in
    probe-failed)
      echo "error: task $ID declares intended base '$BASE' but origin could not be asked whether that branch still exists; cannot verify the PR is based on it. Refusing before merge." >&2
      [ -z "$FM_BASE_STATE_ERR" ] || printf '  git: %s\n' "$FM_BASE_STATE_ERR" >&2
      ;;
    fetch-failed)
      echo "error: task $ID declares intended base '$BASE' but that branch could not be fetched from origin; cannot verify the PR is based on it. Refusing before merge." >&2
      [ -z "$FM_BASE_STATE_ERR" ] || printf '  git: %s\n' "$FM_BASE_STATE_ERR" >&2
      ;;
    no-tip)
      echo "error: task $ID declares intended base '$BASE' but that branch did not resolve to a commit on origin; cannot verify the PR is based on it. Refusing before merge." >&2
      ;;
    default-fetch-failed)
      echo "error: task $ID declares intended base '$BASE' but the repo default branch ('$default_branch_name') could not be fetched from origin, so that base's own history cannot be told apart from history the default branch already carries. Refusing before merge." >&2
      [ -z "$FM_BASE_STATE_ERR" ] || printf '  git: %s\n' "$FM_BASE_STATE_ERR" >&2
      ;;
    default-no-tip)
      echo "error: task $ID declares intended base '$BASE' but the repo default branch ('$default_branch_name') did not resolve to a commit; cannot verify the PR is based on that base. Refusing before merge." >&2
      ;;
    gone-no-tip)
      echo "error: task $ID declares intended base '$BASE', but that branch no longer exists on origin AND no base_sha= tip was recorded for it, so whether it merged or was abandoned cannot be told apart. Refusing before merge." >&2
      echo "  A base that merged is harmless; a base that was deleted WITHOUT merging left its unmerged commits on this PR head, and merging would land them on '$default_branch_name'." >&2
      printf '%s\n' "$review" >&2
      ;;
    gone-tip-unknown)
      echo "error: task $ID declares intended base '$BASE', that branch no longer exists on origin, and whether its work reached '$default_branch_name' could not be determined: the recorded tip is not in this worktree's object store, so it cannot be compared against '$default_branch_name' at all. Refusing before merge." >&2
      echo "  recorded base tip : $BASE_SHA" >&2
      printf '%s\n' "$review" >&2
      ;;
    unrelated)
      echo "error: task $ID PR head and its intended base '$BASE' share no common history at all - refusing to record pr= or arm the merge poll before merge." >&2
      ;;
    merge-tree-failed)
      # The TOOL failed, not the repo. A conflicting replay is an answer (the base has not
      # merged) and never lands here; this is a merge that could not be RUN, so nothing was
      # learned about the base either way. Say exactly that, and name the fix for the thing
      # that is actually broken - telling the operator to rebase a base that may have
      # nothing wrong with it would send them to repair a branch on no evidence at all.
      echo "error: task $ID declares intended base '$BASE', but git could not RUN the 3-way merge that decides whether that base's work already reached '$default_branch_name'. Refusing before merge rather than assuming." >&2
      echo "  base tip       : $FM_BASE_STATE_TIP" >&2
      echo "  default branch : $default_branch_name ($FM_BASE_STATE_DEFAULT_SHA)" >&2
      echo "  'git merge-tree --write-tree' did not run here; it needs git 2.38 or newer. That is a tool failure, not a verdict about '$BASE': the base may merge perfectly cleanly." >&2
      echo "  Recovery: upgrade git to 2.38 or newer and re-run fm-pr-check, which can then settle the question." >&2
      printf '%s\n' "$review" >&2
      ;;
    *)
      # no-commit, no-default-tree: a commit the predicates needed was not in the object
      # store. Also a tool-level failure rather than a fact about the base.
      echo "error: task $ID declares intended base '$BASE', and whether that base's work has already reached '$default_branch_name' could not be determined ($FM_BASE_VERDICT_WHY). Refusing before merge rather than assuming." >&2
      echo "  base tip       : $FM_BASE_STATE_TIP" >&2
      echo "  default branch : $default_branch_name ($FM_BASE_STATE_DEFAULT_SHA)" >&2
      echo "  A commit the check needed did not resolve in this worktree, so the base's work can be shown neither to be there nor to be missing." >&2
      printf '%s\n' "$review" >&2
      ;;
  esac
  return 1
}

# Assert the PR head is what it should be for the state its declared base is actually in.
# Fetches the PR head and the default branch from origin so the classifier runs against
# authoritative commits in the local object store - not a stale local branch or a head SHA
# whose objects were never fetched. Returns 0 (verified: the PR may be recorded and armed)
# or 1 (refuse).
assert_pr_based_on_base() {
  local n pr_sha default_branch_name err state_rc=0 rooted_rc=0 verdict_rc=0
  if [ -z "$WT" ] || [ ! -d "$WT" ]; then
    echo "error: task $ID declares intended base '$BASE' but its worktree is unavailable ('$WT'); cannot verify the PR is based on that base. Refusing before merge." >&2
    return 1
  fi
  if ! git -C "$WT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "error: task $ID declares intended base '$BASE' but '$WT' is not a git worktree; cannot verify the PR is based on that base. Refusing before merge." >&2
    return 1
  fi
  n=$(pr_number_from_url "$URL") || {
    echo "error: task $ID declares intended base '$BASE' but a PR number cannot be parsed from '$URL'; cannot verify the PR is based on that base. Refusing before merge." >&2
    return 1
  }
  default_branch_name=$(default_branch) || {
    echo "error: task $ID declares intended base '$BASE' but the repo's default branch cannot be resolved in '$WT' (expected origin/HEAD, main, or master); cannot tell that base's own history apart from the default branch's. Refusing before merge." >&2
    return 1
  }

  # WHAT IS THE BASE, before anything is spent on the PR head. This is also what makes an
  # unreachable origin report itself as one: the probe inside runs before any fetch, so a
  # broken remote can never surface as "the PR head could not be fetched" instead.
  fm_base_resolve_state "$WT" "$BASE" "$BASE_SHA" "$default_branch_name" || state_rc=$?
  if [ "$state_rc" -eq "$FM_BASE_STATE_UNKNOWN" ]; then
    # Still the owner's verdict, not a shortcut around it: an UNKNOWN base is INDETERMINATE
    # whatever the head turns out to be, and asking it here is what fills in the reason the
    # refusal names. The rootedness argument is moot and any value gives the same answer.
    fm_base_verdict "$state_rc" "$FM_BASE_HEAD_UNROOTED" || true
    refuse_indeterminate "$default_branch_name"
    return 1
  fi
  if [ "$FM_BASE_STATE_PRESENT" = false ]; then
    echo "notice: task $ID declares intended base '$BASE', but that branch no longer exists on origin; reasoning from the tip recorded at spawn." >&2
    echo "  recorded base tip : $FM_BASE_STATE_TIP" >&2
  fi

  if ! err=$(git -C "$WT" fetch --quiet origin "refs/pull/$n/head" 2>&1); then
    echo "error: task $ID declares intended base '$BASE' but the PR head (refs/pull/$n/head) could not be fetched from origin; cannot verify the PR is based on that base. Refusing before merge." >&2
    [ -z "$err" ] || printf '  git: %s\n' "$err" >&2
    return 1
  fi
  pr_sha=$(git -C "$WT" rev-parse --verify --quiet 'FETCH_HEAD^{commit}') || {
    echo "error: task $ID declares intended base '$BASE' but the fetched PR head did not resolve to a commit; cannot verify the PR is based on that base. Refusing before merge." >&2
    return 1
  }

  # WHERE IS THE HEAD ROOTED, and what does that MEAN given what became of the base?
  # One decision, one owner: bin/fm-base-lib.sh's fm_base_verdict. This script's header
  # owns only what the guard does with each answer.
  fm_base_head_rooted "$WT" "$FM_BASE_STATE_TIP" "$pr_sha" "$FM_BASE_STATE_DEFAULT_SHA" \
    || rooted_rc=$?
  fm_base_verdict "$state_rc" "$rooted_rc" || verdict_rc=$?

  case "$verdict_rc" in
    "$FM_BASE_VERDICT_ORDINARY")
      stand_down_landed_base "$default_branch_name" "$FM_BASE_VERDICT_WHY" "$n"
      ;;
    "$FM_BASE_VERDICT_STACKED_LIVE")
      verify_stacked_on_live_base "$n"
      ;;
    "$FM_BASE_VERDICT_STACKED_LANDED")
      refuse_head_carries_merged_base "$default_branch_name" "$FM_BASE_STATE_TIP" \
        "$pr_sha" "$FM_BASE_VERDICT_WHY" "$n"
      ;;
    "$FM_BASE_VERDICT_UNSTACKED")
      refuse_head_rebased_off_base "$default_branch_name" "$FM_BASE_STATE_TIP" "$pr_sha" "$n"
      ;;
    "$FM_BASE_VERDICT_ABANDONED_BASE")
      refuse_abandoned_base "$default_branch_name" "$FM_BASE_STATE_DEFAULT_SHA" \
        "$FM_BASE_STATE_TIP"
      ;;
    *)
      refuse_indeterminate "$default_branch_name"
      ;;
  esac
}

if [ -n "$BASE" ]; then
  assert_pr_based_on_base || exit 1
fi

if [ -f "$META" ]; then
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD_OID" ] && ! grep -qxF "pr_head=$PR_HEAD_OID" "$META"; then
    echo "pr_head=$PR_HEAD_OID" >> "$META"
  fi
fi

cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
echo "armed: state/$ID.check.sh polls $URL"
