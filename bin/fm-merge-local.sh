#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# Before moving the default branch, this gate atomically records the exact
# local_delivery_base=/local_delivery_head= interval that is unique to the task
# branch at merge time. A branch that only synced commits already on the current
# default has no such interval. Teardown validates this receipt before it can
# classify a local-only attempt as accepted.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"
ID=${1:?usage: fm-merge-local.sh <task-id>}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

meta_get() {  # <key>
  local key=$1
  awk -v prefix="$key=" 'index($0, prefix) == 1 { value=substr($0, length(prefix) + 1) } END { print value }' "$META"
}

commit_valid() {  # <commit>
  local commit=$1
  [[ "$commit" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] \
    && git -C "$PROJ" cat-file -e "$commit^{commit}" 2>/dev/null
}

write_local_delivery_receipt() {  # [<base> <head>]
  local base=${1:-} head=${2:-} tmp
  tmp=$(mktemp "$STATE/.fm-local-delivery-meta.XXXXXX") || return 1
  if ! {
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        local_delivery_base=*|local_delivery_head=*) ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$META"
    if [ -n "$base" ] && [ -n "$head" ]; then
      printf 'local_delivery_base=%s\n' "$base"
      printf 'local_delivery_head=%s\n' "$head"
    fi
  } > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$META" || { rm -f -- "$tmp"; return 1; }
}

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
DEFAULT_HEAD=$(git -C "$PROJ" rev-parse --verify "$DEFAULT^{commit}")
BRANCH_HEAD=$(git -C "$PROJ" rev-parse --verify "$BRANCH^{commit}")
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT_HEAD" "$BRANCH_HEAD"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

EXISTING_DELIVERY_BASE=$(meta_get local_delivery_base)
EXISTING_DELIVERY_HEAD=$(meta_get local_delivery_head)
PRESERVE_DELIVERY_RECEIPT=0
if [ "$EXISTING_DELIVERY_HEAD" = "$BRANCH_HEAD" ] \
  && commit_valid "$EXISTING_DELIVERY_BASE" \
  && git -C "$PROJ" merge-base --is-ancestor "$EXISTING_DELIVERY_BASE" "$EXISTING_DELIVERY_HEAD" \
  && [ "$(git -C "$PROJ" rev-list --count "$EXISTING_DELIVERY_BASE..$EXISTING_DELIVERY_HEAD")" -gt 0 ] \
  && ! git -C "$PROJ" diff --quiet "$EXISTING_DELIVERY_BASE" "$EXISTING_DELIVERY_HEAD" --; then
  PRESERVE_DELIVERY_RECEIPT=1
fi

if [ "$PRESERVE_DELIVERY_RECEIPT" -ne 1 ]; then
  if [ "$DEFAULT_HEAD" != "$BRANCH_HEAD" ] \
    && [ "$(git -C "$PROJ" rev-list --count "$DEFAULT_HEAD..$BRANCH_HEAD")" -gt 0 ] \
    && ! git -C "$PROJ" diff --quiet "$DEFAULT_HEAD" "$BRANCH_HEAD" --; then
    write_local_delivery_receipt "$DEFAULT_HEAD" "$BRANCH_HEAD" || {
      echo "error: could not record the task-authored local delivery interval; nothing was merged" >&2
      exit 1
    }
  else
    write_local_delivery_receipt || {
      echo "error: could not clear the absent local delivery interval; nothing was merged" >&2
      exit 1
    }
  fi
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT_HEAD")
git -C "$PROJ" merge --ff-only "$BRANCH_HEAD" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
