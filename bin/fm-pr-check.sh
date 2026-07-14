#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
#
# When state/<id>.meta records a non-default base= (declared with fm-brief.sh
# --base and promoted into meta by fm-spawn.sh), this refuses to record pr= or arm
# the poll unless BOTH hold, refusing loudly otherwise:
#
#   1. The PR head is ROOTED IN THAT BASE'S UNMERGED HISTORY. Concretely: the
#      merge-base of the PR head and the base is itself a commit the default
#      branch cannot reach, so the head genuinely carries the feature base's own
#      work. This deliberately does NOT require the head to descend from the
#      base's CURRENT TIP: a stacked PR whose base is itself under review sees
#      that base advance all the time, and a head that is merely behind is still
#      correctly based and safe to merge. Requiring tip-descent would turn every
#      routine base advance into a hard merge refusal.
#      When the base carries no unmerged history at all (it is already contained
#      in the default branch), rootedness is not observable and the base label
#      below is the whole guard.
#   2. The PR's base label targets it (gh pr view --json baseRefName).
#
# Requiring both catches a head rebased onto the repo default branch and a PR
# opened against the default branch, either of which would drag the feature
# base's unmerged commits into the default branch on merge. That is the launch
# incident (data/learnings.md 2026-07-07) where the pipeline rebased a whole
# feature branch onto main and opened the PR against main.
#
# The no-mistakes pipeline cannot be told a base - it always rebases onto the
# repo default and opens the PR there - so for a based task the expected recovery
# is to retarget the PR's base (gh-axi pr edit --base <branch>), which the
# pipeline's monitor picks up: it re-rebases onto the new base and force-pushes a
# clean head. This guard is what makes a wrong-based PR impossible to merge
# unnoticed; it does not steer the pipeline.
#
# The assertion is fail-closed: any resolution failure (missing worktree,
# unfetchable base/head/default, unresolvable base label) also refuses, so a
# wrong-based or unverifiable head never reaches merge. It is also closed against
# its own fail-open path: a data/<id>/base sidecar that never reached meta (so
# base= is absent and the guard would silently skip) refuses too.
# With no base= and no sidecar (the common case) the whole block is skipped and
# behavior is exactly as before: the repo default branch is the base.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
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

# The intended base is declared to fm-brief.sh, lands in the data/<id>/base
# sidecar, and is promoted into meta by fm-spawn.sh. If that promotion never
# happened, base= is absent and this guard would skip silently - restoring the
# very incident it exists to prevent. Cross-check the two and refuse on any
# disagreement rather than trusting the weaker of the pair.
BASE_SIDECAR=
if [ -f "$DATA/$ID/base" ]; then
  IFS= read -r BASE_SIDECAR < "$DATA/$ID/base" || true
fi
if [ -n "$BASE_SIDECAR" ] && [ "$BASE_SIDECAR" != "$BASE" ]; then
  echo "error: task $ID declares intended base '$BASE_SIDECAR' in $DATA/$ID/base, but state/$ID.meta records base='$BASE'." >&2
  echo "  The intended base never reached meta, so the PR-base guard would be skipped and a wrong-based PR could merge unnoticed. Refusing before merge." >&2
  echo "  Record it with: echo 'base=$BASE_SIDECAR' >> $META" >&2
  exit 1
fi

# A hand-edited meta could carry a base= that git would read as an option rather
# than a ref. fm-brief.sh validates on the way in; validate again on the way out.
if [ -n "$BASE" ]; then
  case "$BASE" in
    -*) echo "error: task $ID records an invalid base='$BASE' (must not begin with '-'). Refusing before merge." >&2; exit 1 ;;
  esac
  git check-ref-format --branch "$BASE" >/dev/null 2>&1 \
    || { echo "error: task $ID records base='$BASE', which is not a valid git branch name. Refusing before merge." >&2; exit 1; }
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

# Assert the PR head is rooted in the declared base's unmerged history, and that
# the PR targets that base. Fetches the PR head, the base, and the default branch
# from origin so the check runs against authoritative commits in the local object
# store - not a stale local branch or a head SHA whose objects were never fetched.
assert_pr_based_on_base() {
  local n pr_sha base_sha default_sha default_branch_name merge_base err
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
  default_branch_name=$(default_branch) || {
    echo "error: task $ID declares intended base '$BASE' but the repo's default branch cannot be resolved in '$WT' (expected origin/HEAD, main, or master); cannot tell that base's own history apart from the default branch's. Refusing before merge." >&2
    return 1
  }
  default_sha=$(fetch_branch_sha "$default_branch_name" "repo default branch") || return 1

  merge_base=$(git -C "$WT" merge-base "$base_sha" "$pr_sha" 2>/dev/null) || {
    echo "error: task $ID PR head and its intended base '$BASE' share no common history at all - refusing to record pr= or arm the merge poll before merge." >&2
    return 1
  }

  # When the base is already contained in the default branch it has no unmerged
  # history of its own, so rootedness says nothing; the base label is the guard.
  if ! git -C "$WT" merge-base --is-ancestor "$base_sha" "$default_sha"; then
    # The head must fork from the base's OWN history, not from the default
    # branch. A merge-base the default branch can reach means the head carries
    # none of the base's unmerged work - it was rebased onto the default branch.
    # A base that merely advanced past the head leaves the merge-base on the
    # base's own unmerged history, which is correct and passes.
    if git -C "$WT" merge-base --is-ancestor "$merge_base" "$default_sha"; then
      echo "error: task $ID PR is not stacked on its intended base - refusing to record pr= or arm the merge poll before merge." >&2
      echo "  intended base : $BASE ($base_sha)" >&2
      [ -z "$PR_BASE_LABEL" ] || echo "  PR base label : $PR_BASE_LABEL" >&2
      echo "  PR head       : $pr_sha" >&2
      echo "  branch point  : $merge_base (reachable from the default branch '$default_branch_name')" >&2
      echo "  The head carries none of '$BASE''s unmerged history, so it was rebased onto the default branch - merging it would not deliver the fix onto '$BASE'." >&2
      echo "  Recovery: retarget the PR's base with 'gh-axi pr edit $n --base $BASE'. The no-mistakes pipeline's monitor picks the new base up, re-rebases the branch onto it, and force-pushes a clean head; then re-run fm-pr-check." >&2
      echo "  (A base that merely ADVANCED past the head is fine and is not refused here - only a head rooted in the default branch is.)" >&2
      return 1
    fi
  fi

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
