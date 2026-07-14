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
# THE GUARD, IN FULL. When state/<id>.meta records a non-default base= (declared with
# fm-spawn.sh --base), the guard first asks whether that base is a LIVE feature base at
# all - bin/fm-base-lib.sh's fm_base_liveness, the one predicate every base-aware consumer
# decides on, and the one owner of what "live" means: the branch must still EXIST on origin,
# and it must still carry at least one commit the default branch does not already have.
# Existing is not enough. GitHub's delete-on-merge is off by default, so a base that merged
# and kept its branch is an ordinary end-state - and it has no unmerged history left to drag
# anywhere, which means the hazard is gone and rootedness is not even observable against it
# (every fork point with such a base is reachable from the default branch, so a perfectly
# stacked head would read UNROOTED). Guarding it as though it were live refuses a safe PR and
# says something false about its head.
#
# Against a LIVE base, two things must both hold before pr= is recorded and the merge poll
# is armed:
#
#   ROOTED   the PR head is rooted in that base's own history - its fork point is a commit
#            the default branch cannot reach (fm_base_head_rooted). A head rooted in the
#            default branch instead was rebased off the base, and the no-mistakes pipeline
#            replayed the base's unmerged commits onto it when it did, so merging would
#            drag them onto the default branch. That is the launch incident
#            (data/learnings.md 2026-07-07).
#            Rootedness is NOT tip-descent: a base that merely ADVANCED past the head is
#            the routine state of a stacked PR whose own base is under review, and it
#            merges fine.
#   TARGETED the PR's base label is that base (gh pr view --json baseRefName), so a PR
#            opened against the default branch cannot land the base's unmerged commits
#            there.
#
# Both are required. The label alone misses a head rebased onto the wrong base; the
# ancestry alone misses a PR opened against the wrong base. Either failing is a REFUSAL,
# and every refusal names the recovery that fits the state it actually found - an
# instruction that cannot change the state it is printed in just sends the reader in a
# circle.
#
# A base that is on origin but carries NOTHING the default branch lacks is verified as the
# ordinary default-branch PR it now is: there is no unmerged base history to protect, so
# only the target is checked, and it must be the default branch. A PR still pointed at that
# spent base is refused - merging it would land the fix on a branch the default branch has
# already absorbed, so the fix would never reach the default branch at all.
#
# This is plain ancestry and it is NOT a merge detector. A SQUASH-merged base still has its
# own commits absent from the default branch by SHA, so it reads live and gets the full
# guard. Telling a squash merge from an abandoned branch takes an inference, and this guard
# does not infer (see below).
#
# WHAT THIS GUARD DELIBERATELY DOES NOT DO. It does not adjudicate a base's END OF LIFE.
# If the declared base is not on origin, or origin cannot be asked, or anything else stops
# those two assertions from being made, the guard does not guess: a base that merged, one
# that was squash-merged, and one that was abandoned without merging all look alike to
# git, and every rule for telling them apart is an inference that can be wrong in the one
# direction that matters. So it DEFERS: it prints what it could not determine, names git's
# own error where there is one, tells the operator a human must confirm the PR's base
# before merging, and stops without recording pr= or arming the poll. That is neither a
# silent pass nor a permanent block - dropping the base= line from meta retires the
# declaration in one edit, which is the human saying "I looked; this PR's base is right."
#
# A deferral is therefore not a verdict about the PR. A refusal says the PR IS wrong-based;
# a deferral says the guard could not tell and will not pretend to.
#
# The no-mistakes pipeline cannot be told a base - it always rebases onto the repo default
# and opens the PR there - so for a based task the expected recovery is to retarget the
# PR's base (gh-axi pr edit --base <branch>), which the pipeline's monitor picks up: it
# re-rebases onto the new base and force-pushes a clean head. This guard is what makes a
# wrong-based PR impossible to merge unnoticed; it does not steer the pipeline.
#
# With no base= (the common case) the whole block is skipped and behavior is exactly as
# before: the repo default branch is the base.
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
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  BASE=$(grep '^base=' "$META" | tail -1 | cut -d= -f2- || true)
fi

# A hand-edited meta could carry a base= that git would read as an option rather than a
# ref. fm-spawn.sh validates on the way in; validate again on the way out.
if [ -n "$BASE" ] && ! fm_base_valid_branch_name "$BASE"; then
  echo "error: task $ID records base='$BASE', which is not a valid git branch name (it must be non-empty, free of whitespace, and must not begin with '-'). Refusing before merge." >&2
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

# Resolve the PR's base label and head SHA in ONE gh call, shared by the base guard and
# the pr_head= recording below. Best-effort: a failure leaves both empty, which the guard
# defers on and the default path treats exactly as before (no pr_head= line).
PR_BASE_LABEL=
PR_HEAD_OID=
resolve_pr_fields() {
  local out base head extra
  [ -n "$WT" ] && [ -d "$WT" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  out=$(cd "$WT" && gh pr view "$URL" --json baseRefName,headRefOid \
    -q '[.baseRefName, .headRefOid] | @tsv' 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  # Split strictly on the tab. `cut` would not do: without -s it echoes a line carrying no
  # delimiter IN FULL for every field asked of it, so a single undelimited field would
  # silently land the SAME string in both variables and record a bogus pr_head= that
  # fm-review-diff.sh and fm-teardown.sh then read as a commit sha. Anything but exactly
  # two non-empty fields is malformed: say so and leave both empty.
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

# The repo's default branch, needed to tell the base's own history apart from history the
# default branch already carries.
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

# DEFER. The two assertions could not be made, so the guard hands the PR to a human instead
# of adjudicating it. Nothing is recorded and nothing is armed. Say what could not be
# determined, name git's own error where there is one, and give the two moves that actually
# resolve it - retarget the PR, or retire the declaration once the base is confirmed.
defer_to_human() {  # <what-could-not-be-determined> [git-error]
  local what=$1 err=${2-} n
  n=$(pr_number_from_url "$URL" || true)
  echo "error: task $ID declares intended base '$BASE', and this PR's base could not be verified: $what. Refusing to record pr= or arm the merge poll." >&2
  [ -z "$err" ] || printf '  git: %s\n' "$err" >&2
  echo "  The guard verifies a base branch that still EXISTS on origin: that the PR head is rooted in it, and that the PR targets it. It does not try to work out what became of a base it cannot see - merged, squash-merged, and abandoned-without-merging all look alike to git, and guessing wrong is how a feature base's unmerged commits reach the default branch." >&2
  echo "  A HUMAN MUST CONFIRM THIS PR'S BASE BEFORE IT MERGES. Review what it would actually land with 'bin/fm-review-diff.sh $ID'." >&2
  if [ -n "$n" ]; then
    echo "  Then retarget the PR if it points at the wrong branch ('gh-axi pr edit $n --base <branch>'); or, once its base is confirmed right, drop the 'base=$BASE' line from $META to retire the declaration and re-run fm-pr-check." >&2
  else
    echo "  Then, once the PR's base is confirmed right, drop the 'base=$BASE' line from $META to retire the declaration and re-run fm-pr-check." >&2
  fi
  return 1
}

# REFUSE: the head is not rooted in the base. It forks from a commit the default branch can
# reach, so it was rebased off the base onto the default branch - and the pipeline replayed
# the base's own commits onto it when it did.
refuse_head_rebased_off_base() {  # <default-branch-name> <base-sha> <pr-sha> <pr-number>
  local default_branch_name=$1 base_sha=$2 pr_sha=$3 n=$4
  echo "error: task $ID PR is not stacked on its intended base - refusing to record pr= or arm the merge poll before merge." >&2
  echo "  intended base : $BASE ($base_sha)" >&2
  [ -z "$PR_BASE_LABEL" ] || echo "  PR base label : $PR_BASE_LABEL" >&2
  echo "  PR head       : $pr_sha" >&2
  echo "  branch point  : $FM_BASE_MERGE_BASE (reachable from the default branch '$default_branch_name')" >&2
  echo "  The head carries none of '$BASE''s history, so it was rebased onto the default branch - merging it would not deliver the fix onto '$BASE'." >&2
  # The recovery has to fit the state actually found. Once the PR already targets the base,
  # telling the reader to retarget it is a no-op they have performed - and re-running this
  # check would just print it again, so a merge-blocking refusal would offer no way forward
  # at all. What is missing then is the HEAD's re-rebase, not the label's.
  if [ "$PR_BASE_LABEL" = "$BASE" ]; then
    echo "  The PR already targets '$BASE', so the retarget landed; it is the head that has not been re-rebased onto it yet." >&2
    echo "  Recovery: let the no-mistakes pipeline's monitor re-rebase the branch onto '$BASE' and force-push, then re-run fm-pr-check. To do it by hand: 'git rebase --onto origin/$BASE origin/$default_branch_name fm/$ID' then force-push with lease." >&2
  else
    echo "  Recovery: retarget the PR's base with 'gh-axi pr edit $n --base $BASE'. The no-mistakes pipeline's monitor picks the new base up, re-rebases the branch onto it, and force-pushes a clean head; then re-run fm-pr-check." >&2
  fi
  echo "  (A base that merely ADVANCED past the head is fine and is not refused here - only a head rooted in the default branch is.)" >&2
  return 1
}

# REFUSE: the head is rooted in the base, but the PR points somewhere else. Merging it
# would land the base's unmerged commits into whatever it points at.
refuse_wrong_base_label() {  # <pr-number>
  local n=$1
  echo "error: task $ID PR is opened against base '$PR_BASE_LABEL', not its intended base '$BASE' - refusing to record pr= or arm the merge poll before merge." >&2
  echo "  The head IS rooted in '$BASE''s history, so merging this PR would land '$BASE''s commits into '$PR_BASE_LABEL'." >&2
  echo "  Recovery: retarget the PR's base with 'gh-axi pr edit $n --base $BASE'. The no-mistakes pipeline's monitor picks the new base up, re-rebases the branch onto it, and force-pushes a clean head; then re-run fm-pr-check." >&2
  return 1
}

# The declared base is still on origin, but it carries nothing the default branch does not
# already have, so it is no longer a live feature base: there is no unmerged history a merge
# could drag onto the default branch, and the guard's whole premise is gone with it. Verify
# the PR as the ordinary default-branch PR it now is. Returns 0 to record and arm, 1 to
# refuse or defer.
#
# The one thing still worth checking is the target. A PR left pointing at a base the default
# branch has already absorbed merges into a spent branch, so the fix never reaches the
# default branch at all - while the PR reads MERGED, teardown calls the work landed, and the
# task goes to Done having delivered nothing.
verify_as_ordinary_default_pr() {  # <default-branch-name> <base-tip> <pr-number>
  local default_branch_name=$1 base_tip=$2 n=$3
  if [ -z "$PR_BASE_LABEL" ]; then
    defer_to_human "'$BASE' carries no commits '$default_branch_name' does not already have, so it is no longer a live feature base and this is an ordinary '$default_branch_name' PR - but its base label could not be resolved via gh, so what it actually targets cannot be confirmed"
    return 1
  fi
  if [ "$PR_BASE_LABEL" != "$default_branch_name" ]; then
    echo "error: task $ID PR is opened against '$PR_BASE_LABEL', a branch '$default_branch_name' has already absorbed - refusing to record pr= or arm the merge poll before merge." >&2
    echo "  intended base : $BASE ($base_tip)" >&2
    echo "  PR base label : $PR_BASE_LABEL" >&2
    echo "  '$BASE' carries no commits '$default_branch_name' does not already have, so it is no longer a live feature base. Merging this PR into it would land the fix on a spent branch and never on '$default_branch_name' - and the PR would read MERGED while delivering nothing." >&2
    echo "  Recovery: retarget the PR at the default branch with 'gh-axi pr edit $n --base $default_branch_name', then drop the 'base=$BASE' line from $META to retire the declaration - this is an ordinary '$default_branch_name' task now - and re-run fm-pr-check." >&2
    return 1
  fi
  echo "note: task $ID declares intended base '$BASE', but that branch carries no commits '$default_branch_name' does not already have, so it is no longer a live feature base: there is no unmerged history this PR could carry onto '$default_branch_name', and the head's rootedness in it is no longer observable. Verified as the ordinary '$default_branch_name' PR it now targets." >&2
  echo "  Drop the 'base=$BASE' line from $META to retire the declaration." >&2
  return 0
}

# Assert the declared base is still live, that the PR head is rooted in it, and that the PR
# targets it. fm_base_liveness fetches the base and the default branch; the PR head is fetched
# here, so every check runs against origin's authoritative commits in the local object store -
# not a stale local branch, or a head SHA whose objects were never fetched. Returns 0
# (verified: the PR may be recorded and armed) or 1 (refuse or defer, both of which have
# already said which).
guard_pr_base() {
  local n pr_sha default_branch_name default_sha base_tip err
  local liveness_rc=0 rooted_rc=0

  if [ -z "$WT" ] || [ ! -d "$WT" ]; then
    defer_to_human "its worktree is unavailable ('$WT'), so nothing can be fetched or compared"
    return 1
  fi
  if ! git -C "$WT" rev-parse --git-dir >/dev/null 2>&1; then
    defer_to_human "'$WT' is not a git worktree, so nothing can be fetched or compared"
    return 1
  fi
  n=$(pr_number_from_url "$URL") || {
    defer_to_human "no PR number can be parsed from '$URL', so the PR head cannot be fetched"
    return 1
  }
  default_branch_name=$(default_branch) || {
    defer_to_human "the repo's default branch cannot be resolved in '$WT' (expected origin/HEAD, main, or master), so the base's own history cannot be told apart from the default branch's"
    return 1
  }

  # IS THE BASE STILL LIVE? The one question, asked with the one predicate every base-aware
  # consumer shares (bin/fm-base-lib.sh's fm_base_liveness), which also leaves the base and
  # default-branch commits it resolved in FM_BASE_TIP / FM_BASE_DEFAULT_SHA. Asked FIRST and
  # always: rootedness cannot be asked of a base the default branch has already absorbed,
  # because every fork point with such a base is reachable from the default branch, so a
  # correctly stacked head would read UNROOTED and be refused with a diagnosis that is simply
  # untrue.
  fm_base_liveness "$WT" "$BASE" "$default_branch_name" || liveness_rc=$?
  base_tip=$FM_BASE_TIP
  default_sha=$FM_BASE_DEFAULT_SHA
  case "$liveness_rc" in
    "$FM_BASE_LIVE") ;;
    "$FM_BASE_ABSORBED")
      verify_as_ordinary_default_pr "$default_branch_name" "$base_tip" "$n" || return 1
      return 0
      ;;
    "$FM_BASE_GONE")
      defer_to_human "that branch no longer exists on origin, so there is nothing left to check the PR head against"
      return 1
      ;;
    *)
      defer_to_human "$FM_BASE_LIVENESS_WHY, so whether that base is still a live feature branch cannot be settled" "$FM_BASE_LIVENESS_ERR"
      return 1
      ;;
  esac

  if ! err=$(git -C "$WT" fetch --quiet origin "refs/pull/$n/head" 2>&1); then
    defer_to_human "the PR head (refs/pull/$n/head) could not be fetched from origin" "$err"
    return 1
  fi
  pr_sha=$(git -C "$WT" rev-parse --verify --quiet 'FETCH_HEAD^{commit}') || {
    defer_to_human "the fetched PR head did not resolve to a commit"
    return 1
  }

  # ROOTED?
  fm_base_head_rooted "$WT" "$base_tip" "$pr_sha" "$default_sha" || rooted_rc=$?
  case "$rooted_rc" in
    "$FM_BASE_HEAD_ROOTED") ;;
    "$FM_BASE_HEAD_UNROOTED")
      refuse_head_rebased_off_base "$default_branch_name" "$base_tip" "$pr_sha" "$n"
      return 1
      ;;
    *)
      defer_to_human "the PR head ($pr_sha) and '$BASE' ($base_tip) share no common history at all, so whether the head is stacked on that base is not a question git can answer"
      return 1
      ;;
  esac

  # TARGETED?
  if [ -z "$PR_BASE_LABEL" ]; then
    defer_to_human "the PR's base label could not be resolved via gh, so the PR cannot be confirmed to target that base"
    return 1
  fi
  if [ "$PR_BASE_LABEL" != "$BASE" ]; then
    refuse_wrong_base_label "$n"
    return 1
  fi
  return 0
}

if [ -n "$BASE" ]; then
  guard_pr_base || exit 1
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
