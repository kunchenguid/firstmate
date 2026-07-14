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
# THE GUARD ASKS ONE QUESTION FIRST: HAS THE BASE'S WORK LANDED IN THE DEFAULT
# BRANCH? Not "does the base branch still exist" - that is an unsound proxy in both
# directions, and bin/fm-base-lib.sh owns why. fm_base_work_landed answers it from
# the base's tip: the live tip while the branch is on origin, else the spawn-time
# base_sha=. Everything below follows from the answer.
#
# THE BASE'S WORK HAS NOT LANDED. The base carries unmerged history, so a head that
# does not sit on it would drag that history into the default branch on merge. Refuse
# to record pr= or arm the poll unless BOTH hold, refusing loudly otherwise:
#
#   1. The PR head is ROOTED IN THE BASE'S UNMERGED HISTORY (fm_base_head_rooted).
#      Not tip-descent: a base that merely ADVANCED past the head is fine.
#   2. The PR's base label targets it (gh pr view --json baseRefName).
#
# Requiring both catches a head rebased onto the repo default branch and a PR
# opened against the default branch, either of which would drag the feature
# base's unmerged commits into the default branch on merge. That is the launch
# incident (data/learnings.md 2026-07-07) where the pipeline rebased a whole
# feature branch onto main and opened the PR against main. An abandoned base -
# deleted from origin WITHOUT merging - is this same case and refuses by name: its
# commits never landed, so the pipeline's rebase replayed them onto the head.
#
# THE BASE'S WORK HAS LANDED. The base merged: its work is in the default branch,
# whether or not its branch was deleted afterwards (GitHub deletes it by default,
# but the setting is off by default too - both end-states are ordinary). No unmerged
# feature history is left to drag anywhere, so the hazard is gone and rootedness
# against the base is meaningless - it cannot even be observed. THE GUARD STANDS
# DOWN, loudly, and the PR is VERIFIED AS THE ORDINARY DEFAULT-BRANCH PR IT NOW IS.
# Guarding it against the base would deadlock a legitimate merge forever behind a
# recovery - retarget onto the base - that is a no-op at best and impossible at worst.
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
# WE COULD NOT TELL. Never a stand-down: standing down is the only relaxation the
# guard has, and it requires proof. With the base still on origin we keep guarding
# (rootedness plus the base label), which is the strict path and refuses nothing that
# is correctly stacked. With the base gone there is nothing left to check against, so
# we refuse and name the reason - including the task with no base_sha= recorded at
# all, where the merged and abandoned cases simply cannot be told apart.
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

# The declared base is GONE from origin. Absence decides nothing on its own, so ask
# the one question that does: did its work actually reach the default branch (it
# merged, so the hazard went with the branch) or never did (it was abandoned, so the
# head still carries its replayed commits and merging would land them on the default
# branch)? With the branch gone, the recorded spawn-time tip is the only fact that can
# tell those apart, and there is no rootedness check left to fall back on; with no
# fact, refuse.
# Returns FM_BASE_GUARD_STAND_DOWN (proceed on the ordinary default-branch path) or 1.
handle_absent_base() {  # <default-branch-name> <default-sha> <pr-number>
  local default_branch_name=$1 default_sha=$2 n=$3 landed_rc=0
  if [ -z "$BASE_SHA" ]; then
    echo "error: task $ID declares intended base '$BASE', but that branch no longer exists on origin AND no base_sha= tip was recorded for it, so whether it merged or was abandoned cannot be told apart. Refusing before merge." >&2
    echo "  A base that merged is harmless; a base that was deleted WITHOUT merging left its unmerged commits replayed on this PR head, and merging would land them on '$default_branch_name'." >&2
    echo "  Recovery: review what this PR would actually land with 'bin/fm-review-diff.sh $ID'. If it is now an ordinary '$default_branch_name' PR, drop the 'base=$BASE' line from $META to retire the declaration, then re-run fm-pr-check." >&2
    return 1
  fi
  fm_base_work_landed "$WT" "$BASE_SHA" "$default_sha" || landed_rc=$?
  case "$landed_rc" in
    "$FM_BASE_WORK_LANDED")
      echo "notice: task $ID declares intended base '$BASE', but that branch no longer exists on origin - it merged and was deleted, the normal end-state of a stacked PR." >&2
      echo "  recorded base tip : $BASE_SHA" >&2
      stand_down_landed_base "$default_branch_name" "$FM_BASE_WORK_HOW" "$n"
      return $?
      ;;
    "$FM_BASE_WORK_UNLANDED")
      echo "error: task $ID declares intended base '$BASE', and that branch was deleted from origin WITHOUT merging - refusing to record pr= or arm the merge poll before merge." >&2
      echo "  recorded base tip : $BASE_SHA" >&2
      echo "  default branch    : $default_branch_name ($default_sha)" >&2
      echo "  The base's work is NOT in '$default_branch_name', so this is an abandoned base, not a merged one. The pipeline rebased this head onto '$default_branch_name', which replays the base's never-merged commits onto it, and merging would land that abandoned work on '$default_branch_name'." >&2
      echo "  Recovery: review what this PR would actually land with 'bin/fm-review-diff.sh $ID'. If the base's work is meant to be dropped, reset the branch onto '$default_branch_name' with only this task's own commits and force-push; if the declaration is simply stale, drop the 'base=$BASE' line from $META. Then re-run fm-pr-check." >&2
      return 1
      ;;
    *)
      echo "error: task $ID declares intended base '$BASE', that branch no longer exists on origin, and whether its work reached '$default_branch_name' could not be determined ($FM_BASE_WORK_HOW). Refusing before merge." >&2
      echo "  recorded base tip : $BASE_SHA" >&2
      case "$FM_BASE_WORK_HOW" in
        no-commit) echo "  That commit is not in this worktree's object store, so it cannot be compared against '$default_branch_name' at all." >&2 ;;
        *) echo "  Replaying the base onto '$default_branch_name' did not resolve cleanly, so its work cannot be shown to be there already." >&2 ;;
      esac
      echo "  Refusing rather than assuming: a base deleted WITHOUT merging leaves its unmerged commits replayed on this PR head, and merging would land them on '$default_branch_name'." >&2
      echo "  Recovery: review what this PR would actually land with 'bin/fm-review-diff.sh $ID'. If it is now an ordinary '$default_branch_name' PR, drop the 'base=$BASE' line from $META to retire the declaration, then re-run fm-pr-check." >&2
      return 1
      ;;
  esac
}

# Assert the PR head is rooted in the declared base's unmerged history, and that
# the PR targets that base. Fetches the PR head, the base, and the default branch
# from origin so the check runs against authoritative commits in the local object
# store - not a stale local branch or a head SHA whose objects were never fetched.
# Returns 0 (verified), FM_BASE_GUARD_STAND_DOWN (the base's work has landed in the
# default branch, so there is nothing left to guard and the caller proceeds on the
# ordinary path), or 1 (refuse).
assert_pr_based_on_base() {
  local n pr_sha base_sha default_sha default_branch_name err probe_rc landed_rc rooted_rc
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

  # Ask origin what the declared base IS before verifying anything against it.
  # Gone is not the same as unverifiable, and it is not the same as merged either:
  # handle_absent_base settles that from the recorded spawn-time tip.
  probe_rc=0
  fm_base_probe_origin "$WT" "$BASE" || probe_rc=$?
  case "$probe_rc" in
    "$FM_BASE_ABSENT")
      default_sha=$(fetch_branch_sha "$default_branch_name" "repo default branch") || return 1
      handle_absent_base "$default_branch_name" "$default_sha" "$n"
      return $?
      ;;
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
  base_sha=$(fetch_branch_sha "$BASE" "intended base branch") || return 1
  default_sha=$(fetch_branch_sha "$default_branch_name" "repo default branch") || return 1

  # The same question the absent path asks, asked of the live tip: has the base's
  # work landed? A base that merged but was never deleted (GitHub's delete-on-merge
  # is off by default) has no unmerged history left, so neither check below means
  # anything - rootedness cannot be observed, and the label the pipeline set is the
  # right one. Guarding it would refuse a safe merge with advice that cannot help.
  landed_rc=0
  fm_base_work_landed "$WT" "$base_sha" "$default_sha" || landed_rc=$?
  if [ "$landed_rc" -eq "$FM_BASE_WORK_LANDED" ]; then
    echo "notice: task $ID declares intended base '$BASE', and that branch is still on origin - but it has already merged." >&2
    echo "  base tip : $base_sha" >&2
    stand_down_landed_base "$default_branch_name" "$FM_BASE_WORK_HOW" "$n"
    return $?
  fi

  # Not landed, or not PROVABLY landed. Either way the base may still carry unmerged
  # history, so the guard stays on: standing down is the only relaxation it has, and
  # it takes proof. Enforcing the strict checks costs a correctly stacked PR nothing.
  rooted_rc=0
  fm_base_head_rooted "$WT" "$base_sha" "$pr_sha" "$default_sha" || rooted_rc=$?
  case "$rooted_rc" in
    "$FM_BASE_HEAD_UNRELATED")
      echo "error: task $ID PR head and its intended base '$BASE' share no common history at all - refusing to record pr= or arm the merge poll before merge." >&2
      return 1
      ;;
    "$FM_BASE_HEAD_UNROOTED")
      echo "error: task $ID PR is not stacked on its intended base - refusing to record pr= or arm the merge poll before merge." >&2
      echo "  intended base : $BASE ($base_sha)" >&2
      [ -z "$PR_BASE_LABEL" ] || echo "  PR base label : $PR_BASE_LABEL" >&2
      echo "  PR head       : $pr_sha" >&2
      echo "  branch point  : $FM_BASE_MERGE_BASE (reachable from the default branch '$default_branch_name')" >&2
      echo "  The head carries none of '$BASE''s unmerged history, so it was rebased onto the default branch - merging it would not deliver the fix onto '$BASE'." >&2
      # The recovery has to fit the state actually found. Once the PR already
      # targets the base, telling the reader to retarget it is a no-op they have
      # performed - and re-running this check would just print it again, so a
      # merge-blocking refusal would offer no way forward at all. What is missing
      # then is the HEAD's re-rebase, not the label's.
      if [ "$PR_BASE_LABEL" = "$BASE" ]; then
        echo "  The PR already targets '$BASE', so the retarget landed; it is the head that has not been re-rebased onto it yet." >&2
        echo "  Recovery: let the no-mistakes pipeline's monitor re-rebase the branch onto '$BASE' and force-push, then re-run fm-pr-check. To do it by hand: 'git rebase --onto origin/$BASE origin/$default_branch_name fm/$ID' then force-push with lease." >&2
      else
        echo "  Recovery: retarget the PR's base with 'gh-axi pr edit $n --base $BASE'. The no-mistakes pipeline's monitor picks the new base up, re-rebases the branch onto it, and force-pushes a clean head; then re-run fm-pr-check." >&2
      fi
      if [ "$landed_rc" -eq "$FM_BASE_WORK_UNKNOWN" ]; then
        echo "  Note: whether '$BASE''s work already reached '$default_branch_name' could not be determined ($FM_BASE_WORK_HOW), so the guard stayed on rather than assuming. If that base has in fact merged, drop the 'base=$BASE' line from $META and re-run fm-pr-check." >&2
      fi
      echo "  (A base that merely ADVANCED past the head is fine and is not refused here - only a head rooted in the default branch is.)" >&2
      return 1
      ;;
  esac

  if [ -z "$PR_BASE_LABEL" ]; then
    echo "error: task $ID declares intended base '$BASE' but the PR's base label could not be resolved via gh; cannot verify the PR targets that base. Refusing before merge." >&2
    return 1
  fi
  if [ "$PR_BASE_LABEL" != "$BASE" ]; then
    echo "error: task $ID PR is opened against base '$PR_BASE_LABEL', not its intended base '$BASE' - refusing to record pr= or arm the merge poll before merge." >&2
    echo "  Merging it would land '$BASE''s unmerged commits into '$PR_BASE_LABEL'." >&2
    echo "  Recovery: retarget the PR's base with 'gh-axi pr edit $n --base $BASE'. The no-mistakes pipeline's monitor picks the new base up, re-rebases the branch onto it, and force-pushes a clean head; then re-run fm-pr-check." >&2
    if [ "$landed_rc" -eq "$FM_BASE_WORK_UNKNOWN" ]; then
      echo "  Note: whether '$BASE''s work already reached '$default_branch_name' could not be determined ($FM_BASE_WORK_HOW), so the guard stayed on rather than assuming. If that base has in fact merged, drop the 'base=$BASE' line from $META and re-run fm-pr-check." >&2
    fi
    return 1
  fi
  return 0
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
