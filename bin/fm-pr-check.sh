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
# THE GUARD ASKS WHERE THE PR HEAD IS ROOTED FIRST, and lets landedness refine what
# that answer means. Neither question is the whole story and neither subsumes the other;
# bin/fm-base-lib.sh owns both predicates and why branch existence answers neither. The
# base's tip is the fact they reason from: the live tip while the branch is on origin,
# else the spawn-time base_sha=.
#
# THE HEAD IS ROOTED IN THE DEFAULT BRANCH (fm_base_head_rooted reports UNROOTED). It
# forks from a commit the default branch can reach, so it carries none of the base's own
# commits. Then landedness decides:
#
#   base LANDED    the base merged, so nothing it once carried is unmerged any more and
#                  this is simply an ordinary default-branch PR. THE GUARD STANDS DOWN,
#                  loudly, AND VERIFIES IT AS THE ORDINARY DEFAULT-BRANCH PR IT NOW IS.
#                  Guarding it against the base would deadlock a legitimate merge forever
#                  behind a recovery - retarget onto the base - that is a no-op at best
#                  and impossible at worst.
#   otherwise      the base still carries unmerged history, so the head was rebased off
#                  it onto the default branch and merging would drag that history in.
#                  That is the launch incident (data/learnings.md 2026-07-07), and an
#                  abandoned base - deleted from origin WITHOUT merging - is the same
#                  case and refuses by name. REFUSE.
#
# THE HEAD IS ROOTED IN THE BASE (ROOTED). It forks from a commit the default branch
# cannot reach, so it carries the base's own commits. Then landedness decides:
#
#   base LANDED    a squash or rebase merge put the base's CONTENT in the default branch
#                  but not its COMMITS, and this head still carries them. Merging it into
#                  the default branch would land them all over again, and its diff shows
#                  the base's already-merged changes as part of this task. REFUSE - and
#                  prescribe the head's REBASE ONTO THE DEFAULT BRANCH, because a
#                  retarget alone leaves those commits on the head.
#   otherwise      correctly stacked on a base that still carries unmerged work. Require
#                  the PR's base label to target it (gh pr view --json baseRefName), so a
#                  PR opened against the default branch cannot drag the base's unmerged
#                  commits into it, and pass.
#
# Rootedness is not tip-descent: a base that merely ADVANCED past the head is fine.
#
# Standing down is NOT skipping the check. The base label must still resolve, and it
# must be the DEFAULT BRANCH: a PR still pointed at the merged base would merge into
# that stale branch, so the fix would never reach the default branch at all, while
# fm-teardown.sh would read a MERGED PR and release the work. That is reachable
# whenever the base merged without being deleted, because a no-mistakes crewmate is
# required to retarget the PR onto the base before it reports done. So a stood-down
# guard refuses a PR that still targets anything but the default branch, and names
# the retarget BACK to it.
#
# WE COULD NOT TELL WHETHER THE BASE LANDED. Never a stand-down: standing down is the
# only relaxation the guard has, and it requires proof. It is not a blanket refusal
# either - a base that conflicts with the default branch cannot be replayed onto it and
# reads indeterminate, which is ordinary for a long-lived base. The head's rootedness is
# still known, so the strict checks above still run, and running them costs a correctly
# stacked PR nothing.
#
# WE COULD NOT TELL WHERE THE HEAD IS ROOTED. There is nothing left to check against:
# refuse and name the reason - including the gone base with no base_sha= recorded at all,
# and the recorded tip whose commit is not in the local object store.
#
# THE PROBE ITSELF FAILED (auth, network, a broken remote). We know nothing:
# refuse, and name git's own error so an infrastructure failure is diagnosable
# instead of masquerading as a wrong-base verdict.
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
# worktree, unfetchable base/head/default, unresolvable base label) refuses, so a
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

# Fetch one branch from origin into its remote-tracking ref and echo its SHA.
# The refspec is fully qualified so a dash-leading branch name can never be read
# as an option, and git's stderr is surfaced so an auth or network failure is
# diagnosable instead of masquerading as a wrong-base verdict.
fetch_branch_sha() {
  local branch=$1 what=$2 err
  if ! err=$(git -C "$WT" fetch --quiet origin "+refs/heads/$branch:refs/remotes/origin/$branch" 2>&1); then
    echo "error: task $ID declares intended base '$BASE' but the $what ('$branch') could not be fetched from origin; cannot verify the PR is based on it. Refusing before merge." >&2
    [ -z "$err" ] || printf '  git: %s\n' "$err" >&2
    return 1
  fi
  git -C "$WT" rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}" || {
    echo "error: task $ID declares intended base '$BASE' but the $what ('$branch') did not resolve to a commit; cannot verify the PR is based on it. Refusing before merge." >&2
    return 1
  }
}

# Landedness came back indeterminate, on a path that refused anyway. Say so, so an
# operator can tell "the guard could not settle this question" from "the guard settled it
# against you" - and so the one honest escape (the base did in fact merge) is named.
# Indented: it only ever follows a refusal's own lines.
unknown_landedness_note() {  # <default-branch-name> <landed-rc>
  local default_branch_name=$1 landed_rc=$2
  [ "$landed_rc" -eq "$FM_BASE_WORK_UNKNOWN" ] || return 0
  echo "  Note: whether '$BASE''s work already reached '$default_branch_name' could not be determined ($FM_BASE_WORK_HOW), so the guard kept its strict checks rather than assuming. If that base has in fact merged, drop the 'base=$BASE' line from $META and re-run fm-pr-check." >&2
}

# The declared base's work IS in the default branch, so the base merged and there is
# nothing left to guard it against. Say so out loud - a guard that relaxes silently is
# a guard nobody can audit - and then VERIFY THE PR AS THE ORDINARY DEFAULT-BRANCH PR
# IT NOW IS. Standing down is not skipping the check: it swaps the base the PR is
# checked against, and the label must now be the default branch. A PR still pointed at
# the merged base is reachable (a no-mistakes crewmate is required to retarget onto the
# base before reporting done, and the base can merge afterwards without being deleted),
# and merging it would merge into that stale branch - so the fix would never reach the
# default branch, while fm-teardown.sh would read a MERGED PR and release the work.
# Returns FM_BASE_GUARD_STAND_DOWN (proceed on the ordinary default-branch path) or 1.
stand_down_landed_base() {  # <default-branch-name> <why> <pr-number>
  local default_branch_name=$1 why=$2 n=$3
  # Verify BEFORE announcing. The label check below can still refuse, and in a merge
  # gate the message is the only signal an operator gets - a confident "the guard
  # stands down and this PR is verified" printed one line above "error: refusing"
  # contradicts itself and teaches the reader to distrust both.
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
  echo "  Its work IS carried by the default branch '$default_branch_name' ($why), so the base merged and there is nothing left to guard." >&2
  echo "  PR base label : $PR_BASE_LABEL" >&2
  echo "  No unmerged feature history can be dragged into '$default_branch_name', so the base guard stands down and this PR is verified as the ordinary default-branch PR it now is." >&2
  echo "  Drop the 'base=$BASE' line from $META to retire the declaration for good." >&2
  return "$FM_BASE_GUARD_STAND_DOWN"
}

# The PR head still carries the declared base's OWN commits, and that base has already
# merged. A squash or rebase merge (a squash is firstmate's own default, and GitHub's
# most common setting) puts the base's CONTENT in the default branch but not its
# COMMITS, so this head is the one head that would land them all over again - and its
# diff presents the base's already-merged changes as part of this task's. The recovery
# is the head's REBASE, not a retarget: retargeting the label leaves those commits
# exactly where they are.
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

# The declared base is GONE from origin and its work cannot be SHOWN to be in the default
# branch. Absence proves nothing on its own: a base deleted WITHOUT merging (an abandoned
# feature, a closed base PR, a force-deleted branch) looks exactly the same to origin as
# one that merged and was auto-deleted, and its never-merged commits ride on this head
# either replayed by the pipeline's rebase or carried directly. With the branch gone
# there is nothing left to check the head against, so refuse and name which of the two
# it is - unlanded, or simply unanswerable.
refuse_unprovable_gone_base() {  # <default-branch-name> <default-sha> <landed-rc>
  local default_branch_name=$1 default_sha=$2 landed_rc=$3
  if [ "$landed_rc" -eq "$FM_BASE_WORK_UNLANDED" ]; then
    echo "error: task $ID declares intended base '$BASE', and that branch was deleted from origin WITHOUT merging - refusing to record pr= or arm the merge poll before merge." >&2
    echo "  recorded base tip : $BASE_SHA" >&2
    echo "  default branch    : $default_branch_name ($default_sha)" >&2
    echo "  The base's work is NOT in '$default_branch_name', so this is an abandoned base, not a merged one, and this PR head carries its never-merged commits. Merging would land that abandoned work on '$default_branch_name'." >&2
    echo "  Recovery: review what this PR would actually land with 'bin/fm-review-diff.sh $ID'. If the base's work is meant to be dropped, reset the branch onto '$default_branch_name' with only this task's own commits and force-push; if the declaration is simply stale, drop the 'base=$BASE' line from $META. Then re-run fm-pr-check." >&2
    return 1
  fi
  echo "error: task $ID declares intended base '$BASE', that branch no longer exists on origin, and whether its work reached '$default_branch_name' could not be determined ($FM_BASE_WORK_HOW). Refusing before merge." >&2
  echo "  recorded base tip : $BASE_SHA" >&2
  echo "  Replaying the base onto '$default_branch_name' did not resolve cleanly, so its work cannot be shown to be there already." >&2
  echo "  Refusing rather than assuming: a base deleted WITHOUT merging leaves its unmerged commits on this PR head, and merging would land them on '$default_branch_name'." >&2
  echo "  Recovery: review what this PR would actually land with 'bin/fm-review-diff.sh $ID'. If it is now an ordinary '$default_branch_name' PR, drop the 'base=$BASE' line from $META to retire the declaration, then re-run fm-pr-check." >&2
  return 1
}

# The base tip both predicates reason from, for a base that is GONE from origin: the tip
# recorded at spawn (base_sha=), the last time the branch demonstrably existed. A task
# with none, or whose recorded commit is not in the local object store, cannot be checked
# at all - not for landedness, not for rootedness - so it refuses rather than guessing.
# Echoes the tip; returns 1 to refuse.
absent_base_tip() {  # <default-branch-name>
  local default_branch_name=$1
  if [ -z "$BASE_SHA" ]; then
    echo "error: task $ID declares intended base '$BASE', but that branch no longer exists on origin AND no base_sha= tip was recorded for it, so whether it merged or was abandoned cannot be told apart. Refusing before merge." >&2
    echo "  A base that merged is harmless; a base that was deleted WITHOUT merging left its unmerged commits on this PR head, and merging would land them on '$default_branch_name'." >&2
    echo "  Recovery: review what this PR would actually land with 'bin/fm-review-diff.sh $ID'. If it is now an ordinary '$default_branch_name' PR, drop the 'base=$BASE' line from $META to retire the declaration, then re-run fm-pr-check." >&2
    return 1
  fi
  if ! git -C "$WT" cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
    echo "error: task $ID declares intended base '$BASE', that branch no longer exists on origin, and whether its work reached '$default_branch_name' could not be determined: the recorded tip is not in this worktree's object store, so it cannot be compared against '$default_branch_name' at all. Refusing before merge." >&2
    echo "  recorded base tip : $BASE_SHA" >&2
    echo "  Recovery: review what this PR would actually land with 'bin/fm-review-diff.sh $ID'. If it is now an ordinary '$default_branch_name' PR, drop the 'base=$BASE' line from $META to retire the declaration, then re-run fm-pr-check." >&2
    return 1
  fi
  printf '%s' "$BASE_SHA"
}

# Assert the PR head is rooted where it should be for the state its declared base is
# actually in. Fetches the PR head, the base, and the default branch from origin so the
# checks run against authoritative commits in the local object store - not a stale local
# branch or a head SHA whose objects were never fetched.
# Returns 0 (verified), FM_BASE_GUARD_STAND_DOWN (the head sits on the default branch and
# the base has merged, so there is nothing left to guard and the caller proceeds on the
# ordinary path), or 1 (refuse).
assert_pr_based_on_base() {
  local n pr_sha base_sha default_sha default_branch_name err probe_rc landed_rc rooted_rc
  local base_gone=false
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

  # Ask origin what the declared base IS before verifying anything against it. Gone is
  # not the same as unverifiable, and it is not the same as merged either: it only
  # changes WHICH tip the checks below reason from - the live one, or the spawn-time one.
  probe_rc=0
  fm_base_probe_origin "$WT" "$BASE" || probe_rc=$?
  case "$probe_rc" in
    "$FM_BASE_ABSENT") base_gone=true ;;
    "$FM_BASE_PROBE_FAILED")
      echo "error: task $ID declares intended base '$BASE' but origin could not be asked whether that branch still exists; cannot verify the PR is based on it. Refusing before merge." >&2
      [ -z "$FM_BASE_PROBE_ERR" ] || printf '  git: %s\n' "$FM_BASE_PROBE_ERR" >&2
      return 1
      ;;
  esac

  if ! err=$(git -C "$WT" fetch --quiet origin "refs/pull/$n/head" 2>&1); then
    echo "error: task $ID declares intended base '$BASE' but the PR head (refs/pull/$n/head) could not be fetched from origin; cannot verify the PR is based on that base. Refusing before merge." >&2
    [ -z "$err" ] || printf '  git: %s\n' "$err" >&2
    return 1
  fi
  # Resolve FETCH_HEAD before the branch fetches below overwrite it.
  pr_sha=$(git -C "$WT" rev-parse --verify --quiet 'FETCH_HEAD^{commit}') || {
    echo "error: task $ID declares intended base '$BASE' but the fetched PR head did not resolve to a commit; cannot verify the PR is based on that base. Refusing before merge." >&2
    return 1
  }
  default_sha=$(fetch_branch_sha "$default_branch_name" "repo default branch") || return 1
  if "$base_gone"; then
    base_sha=$(absent_base_tip "$default_branch_name") || return 1
    echo "notice: task $ID declares intended base '$BASE', but that branch no longer exists on origin; reasoning from the tip recorded at spawn." >&2
    echo "  recorded base tip : $base_sha" >&2
  else
    base_sha=$(fetch_branch_sha "$BASE" "intended base branch") || return 1
  fi

  # WHERE IS THE HEAD ROOTED, and WHAT DOES THAT MEAN given what became of the base?
  # Both, in that order: landedness alone tells the default branch's content story, and
  # a head still rooted in a squash-merged base carries commits that story does not
  # account for. The header owns the full matrix.
  rooted_rc=0
  fm_base_head_rooted "$WT" "$base_sha" "$pr_sha" "$default_sha" || rooted_rc=$?
  landed_rc=0
  fm_base_work_landed "$WT" "$base_sha" "$default_sha" || landed_rc=$?

  case "$rooted_rc" in
    "$FM_BASE_HEAD_UNRELATED")
      echo "error: task $ID PR head and its intended base '$BASE' share no common history at all - refusing to record pr= or arm the merge poll before merge." >&2
      return 1
      ;;
    "$FM_BASE_HEAD_ROOTED")
      # The head carries the base's own commits.
      if [ "$landed_rc" -eq "$FM_BASE_WORK_LANDED" ]; then
        refuse_head_carries_merged_base "$default_branch_name" "$base_sha" "$pr_sha" "$FM_BASE_WORK_HOW" "$n"
        return 1
      fi
      if "$base_gone"; then
        refuse_unprovable_gone_base "$default_branch_name" "$default_sha" "$landed_rc"
        return 1
      fi
      # Correctly stacked on a base that still carries unmerged work - the state the
      # whole feature exists to protect. The label must target that base, or merging
      # would drag its unmerged commits into whatever the PR points at instead.
      if [ -z "$PR_BASE_LABEL" ]; then
        echo "error: task $ID declares intended base '$BASE' but the PR's base label could not be resolved via gh; cannot verify the PR targets that base. Refusing before merge." >&2
        return 1
      fi
      if [ "$PR_BASE_LABEL" != "$BASE" ]; then
        echo "error: task $ID PR is opened against base '$PR_BASE_LABEL', not its intended base '$BASE' - refusing to record pr= or arm the merge poll before merge." >&2
        echo "  Merging it would land '$BASE''s unmerged commits into '$PR_BASE_LABEL'." >&2
        echo "  Recovery: retarget the PR's base with 'gh-axi pr edit $n --base $BASE'. The no-mistakes pipeline's monitor picks the new base up, re-rebases the branch onto it, and force-pushes a clean head; then re-run fm-pr-check." >&2
        unknown_landedness_note "$default_branch_name" "$landed_rc"
        return 1
      fi
      if [ "$landed_rc" -eq "$FM_BASE_WORK_UNKNOWN" ]; then
        echo "notice: task $ID PR is correctly stacked on its intended base '$BASE' and targets it, so it passes - but whether that base's work already reached '$default_branch_name' could not be determined ($FM_BASE_WORK_HOW), which is ordinary for a long-lived base that conflicts with it. The guard kept its strict checks rather than assuming." >&2
      fi
      return 0
      ;;
  esac

  # UNROOTED: the head forks from a commit the default branch can reach, so it carries
  # none of the base's own commits.
  if [ "$landed_rc" -eq "$FM_BASE_WORK_LANDED" ]; then
    echo "notice: task $ID declares intended base '$BASE', and its work has already merged into '$default_branch_name'; the PR head sits on the default branch and carries none of the base's own commits." >&2
    stand_down_landed_base "$default_branch_name" "$FM_BASE_WORK_HOW" "$n"
    return $?
  fi
  if "$base_gone"; then
    refuse_unprovable_gone_base "$default_branch_name" "$default_sha" "$landed_rc"
    return 1
  fi
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
  unknown_landedness_note "$default_branch_name" "$landed_rc"
  echo "  (A base that merely ADVANCED past the head is fine and is not refused here - only a head rooted in the default branch is.)" >&2
  return 1
}

if [ -n "$BASE" ]; then
  BASE_RC=0
  assert_pr_based_on_base || BASE_RC=$?
  # A stood-down guard (the base's work has landed in the default branch) continues
  # on the ordinary default-branch path; anything else nonzero is a refusal.
  [ "$BASE_RC" -eq 0 ] || [ "$BASE_RC" -eq "$FM_BASE_GUARD_STAND_DOWN" ] || exit 1
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
