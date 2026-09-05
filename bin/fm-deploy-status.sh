#!/usr/bin/env bash
# Report what is merged but not yet live for one project, split into what may
# ship without the captain and what may not.
#
# Read-only everywhere: it reads this home's config, the project clone as it
# already stands, and the deployed commit from the host over ssh. It never
# fetches, never writes to the clone, and never changes the host.
#
# Usage:
#   fm-deploy-status.sh <project> [--porcelain]
#
# <project> is a directory name under this home's projects/ dir. The project
# needs both a deploy policy (config/deploy-policy/<project>) and a deploy
# target (config/deploy-target/<project>); a project with neither is simply not
# deploy-managed and is reported as such rather than guessed at.
# docs/configuration.md owns both file formats.
#
# Human output is captain-facing prose. `--porcelain` prints a stable key=value
# block for bin/fm-deploy-trigger.sh; the two never diverge because both read
# the same classification from bin/fm-deploy-lib.sh.
#
# Exit status: 0 when the report was produced (whatever it says), 2 on an
# invalid request or unusable configuration, 3 when the host could not be read
# or the deployed commit is not an ancestor of the target. A caller must treat
# every non-zero status as "unknown", never as "nothing pending".
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
# shellcheck source=bin/fm-deploy-lib.sh
. "$SCRIPT_DIR/fm-deploy-lib.sh"
# shellcheck source=bin/fm-deploy-target-lib.sh
. "$SCRIPT_DIR/fm-deploy-target-lib.sh"

PORCELAIN=0
PROJECT=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --porcelain) PORCELAIN=1 ;;
    -h | --help)
      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      printf 'error: unknown option %s\n' "$1" >&2
      exit 2
      ;;
    *)
      [ -z "$PROJECT" ] || { printf 'error: one project only\n' >&2; exit 2; }
      PROJECT=$1
      ;;
  esac
  shift
done
[ -n "$PROJECT" ] || { printf 'error: usage: fm-deploy-status.sh <project> [--porcelain]\n' >&2; exit 2; }

POLICY=$(fm_deploy_policy_file "$FM_HOME" "$PROJECT")
if ! fm_deploy_policy_readable "$POLICY"; then
  if [ "$PORCELAIN" -eq 1 ]; then
    printf 'managed=no\n'
    exit 0
  fi
  printf '%s is not set up for deploys from here, so nothing is tracked for it.\n' "$PROJECT"
  exit 0
fi

fm_deploy_target_load "$FM_HOME" "$PROJECT" || exit 2

REPO="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}/$PROJECT"
[ -d "$REPO/.git" ] || { printf 'error: no local copy of %s at %s\n' "$PROJECT" "$REPO" >&2; exit 2; }

TARGET_SHA=$(git -C "$REPO" rev-parse --verify --quiet 'origin/HEAD^{commit}' 2>/dev/null || true)
[ -n "$TARGET_SHA" ] || TARGET_SHA=$(git -C "$REPO" rev-parse --verify --quiet 'origin/main^{commit}' 2>/dev/null || true)
if [ -z "$TARGET_SHA" ]; then
  printf 'error: %s has no origin/main to compare against\n' "$PROJECT" >&2
  exit 2
fi

DEPLOYED_SHA=$(fm_deploy_host_sha) || {
  if [ "$PORCELAIN" -eq 1 ]; then
    printf 'managed=yes\nreadable=no\n'
    exit 3
  fi
  printf 'Could not reach the machine that serves %s, so what is live there is unknown.\n' "$PROJECT"
  exit 3
}
if ! fm_deploy_sha_valid "$DEPLOYED_SHA"; then
  if [ "$PORCELAIN" -eq 1 ]; then
    printf 'managed=yes\nreadable=no\n'
    exit 3
  fi
  printf 'The machine serving %s is not on a specific pinned version (it reports %s), so nothing should be deployed onto it until that is sorted out.\n' \
    "$PROJECT" "$DEPLOYED_SHA"
  exit 3
fi

classify_rc=0
fm_deploy_classify "$REPO" "$DEPLOYED_SHA" "$TARGET_SHA" "$POLICY" || classify_rc=$?
if [ "$classify_rc" -eq 2 ]; then
  if [ "$PORCELAIN" -eq 1 ]; then
    printf 'managed=yes\nreadable=yes\ndiverged=yes\ndeployed_sha=%s\ntarget_sha=%s\n' "$DEPLOYED_SHA" "$TARGET_SHA"
    exit 3
  fi
  printf 'What is live for %s is not on the main line of work, so "what is not deployed yet" has no honest answer. It needs a look before anything is deployed.\n' "$PROJECT"
  exit 3
fi
[ "$classify_rc" -eq 0 ] || exit 3

CAPTAIN_COUNT=$FM_DEPLOY_CAPTAIN_COUNT

if [ "$PORCELAIN" -eq 1 ]; then
  printf 'managed=yes\nreadable=yes\ndiverged=no\n'
  printf 'deployed_sha=%s\ntarget_sha=%s\n' "$DEPLOYED_SHA" "$TARGET_SHA"
  printf 'pending_total=%s\npending_captain_paths=%s\n' "$FM_DEPLOY_PENDING_COUNT" "$CAPTAIN_COUNT"
  printf 'auto_deployable=%s\n' "$([ "$FM_DEPLOY_PENDING_COUNT" -gt 0 ] && [ "$CAPTAIN_COUNT" -eq 0 ] && printf yes || printf no)"
  exit 0
fi

plural() { [ "$1" -eq 1 ] && printf 'change' || printf 'changes'; }

if [ "$FM_DEPLOY_PENDING_COUNT" -eq 0 ]; then
  printf 'Everything merged for %s is already live.\n' "$PROJECT"
  exit 0
fi

if [ "$CAPTAIN_COUNT" -eq 0 ]; then
  printf '%s: %s merged %s can go live on their own; nothing needs your permission.\n' \
    "$PROJECT" "$FM_DEPLOY_PENDING_COUNT" "$(plural "$FM_DEPLOY_PENDING_COUNT")"
  exit 0
fi

# The captain asked for exactly this shape: once nothing can ship on its own,
# the report is only what he owns, and why. Grouped by the design area he named,
# because a list of individual files is not a decision he can read.
printf '%s: %s merged %s are waiting on your permission, because they change how the product looks:\n' \
  "$PROJECT" "$FM_DEPLOY_PENDING_COUNT" "$(plural "$FM_DEPLOY_PENDING_COUNT")"
printf '%s' "$FM_DEPLOY_CAPTAIN" | cut -f1 | sort | uniq -c | while read -r count pattern; do
  [ -n "$pattern" ] || continue
  printf '  - %s (%s %s)\n' "$pattern" "$count" "$([ "$count" -eq 1 ] && printf file || printf files)"
done
printf 'The changes themselves:\n'
printf '%s\n' "$FM_DEPLOY_PENDING" | while IFS= read -r commit; do
  [ -n "$commit" ] || continue
  printf '  - %s\n' "${commit#* }"
done
printf 'Say the word and all %s go live.\n' "$FM_DEPLOY_PENDING_COUNT"
