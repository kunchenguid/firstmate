#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
#
# When state/<id>.meta records a non-default base= (declared with fm-brief.sh
# --base and promoted into meta by fm-spawn.sh), this refuses to record pr= or arm
# the poll unless the PR head is actually STACKED on that intended base (git
# merge-base --is-ancestor <base> <pr-head>) AND the PR's base label targets it
# (gh pr view --json baseRefName), refusing loudly otherwise. Requiring both
# catches a head rebased onto the wrong base (e.g. the repo default main) and a PR
# opened against the wrong base, either of which would drag the feature base's
# unmerged commits into main on merge. That is the launch incident
# (data/learnings.md 2026-07-07) where the pipeline rebased a whole feature branch
# onto main and opened the PR against main. The assertion is fail-closed: any
# resolution failure (missing worktree, unfetchable base/head, unresolvable base
# label) also refuses, so a wrong-based or unverifiable head never reaches merge.
# With no base= in meta (the common case) this block is skipped and behavior is
# exactly as before: the repo default branch is the base.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
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

# Assert the PR head is stacked on the declared intended base. Fetches both the
# PR head (refs/pull/<n>/head) and the base branch from origin so the check runs
# against authoritative commits present in the local object store - not a stale
# local branch or a head SHA whose objects were never fetched. Fail-closed:
# returns non-zero on any resolution failure or a non-ancestor result.
assert_pr_stacked_on_base() {
  local n pr_sha base_sha actual_base
  if [ -z "$WT" ] || [ ! -d "$WT" ]; then
    echo "error: task $ID declares intended base '$BASE' but its worktree is unavailable ('$WT'); cannot verify the PR is stacked on that base. Refusing before merge." >&2
    return 1
  fi
  if ! git -C "$WT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "error: task $ID declares intended base '$BASE' but '$WT' is not a git worktree; cannot verify stacking. Refusing before merge." >&2
    return 1
  fi
  n=$(pr_number_from_url "$URL") || {
    echo "error: task $ID declares intended base '$BASE' but a PR number cannot be parsed from '$URL'; cannot verify stacking. Refusing before merge." >&2
    return 1
  }
  if ! git -C "$WT" fetch --quiet origin "refs/pull/$n/head" 2>/dev/null; then
    echo "error: task $ID declares intended base '$BASE' but the PR head (refs/pull/$n/head) could not be fetched from origin; cannot verify stacking. Refusing before merge." >&2
    return 1
  fi
  pr_sha=$(git -C "$WT" rev-parse --verify --quiet 'FETCH_HEAD^{commit}') || {
    echo "error: task $ID declares intended base '$BASE' but the fetched PR head did not resolve to a commit; cannot verify stacking. Refusing before merge." >&2
    return 1
  }
  if ! git -C "$WT" fetch --quiet origin "$BASE" 2>/dev/null; then
    echo "error: task $ID declares intended base '$BASE' but that branch could not be fetched from origin; cannot verify stacking. Refusing before merge." >&2
    return 1
  fi
  base_sha=$(git -C "$WT" rev-parse --verify --quiet 'FETCH_HEAD^{commit}') || {
    echo "error: task $ID declares intended base '$BASE' but it did not resolve to a commit; cannot verify stacking. Refusing before merge." >&2
    return 1
  }
  if git -C "$WT" merge-base --is-ancestor "$base_sha" "$pr_sha"; then
    if ! command -v gh >/dev/null 2>&1; then
      echo "error: task $ID declares intended base '$BASE' but gh is unavailable to resolve the PR's base label; cannot verify the PR targets that base. Refusing before merge." >&2
      return 1
    fi
    actual_base=$(cd "$WT" && gh pr view "$URL" --json baseRefName -q .baseRefName 2>/dev/null) || {
      echo "error: task $ID declares intended base '$BASE' but the PR's base label could not be resolved via gh; cannot verify the PR targets that base. Refusing before merge." >&2
      return 1
    }
    if [ -z "$actual_base" ]; then
      echo "error: task $ID declares intended base '$BASE' but the PR's base label resolved empty; cannot verify the PR targets that base. Refusing before merge." >&2
      return 1
    fi
    if [ "$actual_base" != "$BASE" ]; then
      echo "error: task $ID PR is opened against base '$actual_base', not its intended base '$BASE' - refusing to record pr= or arm the merge poll before merge; retarget the PR base to '$BASE'." >&2
      return 1
    fi
    return 0
  fi
  actual_base=
  if command -v gh >/dev/null 2>&1; then
    actual_base=$(cd "$WT" && gh pr view "$URL" --json baseRefName -q .baseRefName 2>/dev/null || true)
  fi
  echo "error: task $ID PR is not stacked on its intended base - refusing to record pr= or arm the merge poll before merge." >&2
  echo "  intended base : $BASE ($base_sha)" >&2
  [ -n "$actual_base" ] && echo "  PR base label : $actual_base" >&2
  echo "  PR head       : $pr_sha" >&2
  echo "  The PR head does not descend from the current tip of '$BASE'. Two causes are possible:" >&2
  echo "  1. The head was rebased onto the wrong base (e.g. the repo default main). Rebuild or retarget the head onto '$BASE', then re-run fm-pr-check." >&2
  echo "  2. '$BASE' advanced after the head was stacked, so the head is merely behind. Rebase the head onto the current tip of '$BASE', then re-run fm-pr-check." >&2
  return 1
}

if [ -n "$BASE" ]; then
  assert_pr_stacked_on_base || exit 1
fi

if [ -f "$META" ]; then
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    if command -v gh >/dev/null 2>&1; then
      if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
        PR_HEAD=$REMOTE_HEAD
      fi
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
echo "armed: state/$ID.check.sh polls $URL"
