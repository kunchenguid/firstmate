#!/usr/bin/env bash
# Run Playwright ladder smoke tests against live agent localhost servers.
# Uses PLAYWRIGHT_SKIP_WEBSERVER so each port's already-running dev server is tested.
#
# Token-efficient default: ladder-smoke spec only (not the full e2e suite).
# Seeds gitignored env into worktrees missing .env.local before testing.
#
# Usage:
#   fm-proplane-branch-e2e.sh --smoke              # all ladder ports
#   fm-proplane-branch-e2e.sh --smoke cursor-2     # one branch
#   fm-proplane-branch-e2e.sh --full cursor-2      # full e2e (expensive)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-proplane-agent-branches-lib.sh
. "$SCRIPT_DIR/fm-proplane-agent-branches-lib.sh"

MODE=smoke
ONLY_BRANCH=""
for arg in "$@"; do
  case "$arg" in
    --smoke) MODE=smoke ;;
    --full) MODE=full ;;
    --help|-h)
      echo "usage: fm-proplane-branch-e2e.sh [--smoke|--full] [branch]"
      exit 0
      ;;
    *)
      if [ -z "$ONLY_BRANCH" ]; then
        ONLY_BRANCH=$arg
      else
        echo "unknown argument: $arg" >&2
        exit 2
      fi
      ;;
  esac
done

GIT_ROOT=$(fm_proplane_agent_git_root) || exit 1
SPEC=tests/e2e/ladder-smoke.spec.ts
if [ "$MODE" = full ]; then
  SPEC=tests/e2e
fi

ensure_worktree_env() {
  local worktree=$1
  if [ -f "$worktree/.env.local" ] || [ -L "$worktree/.env.local" ]; then
    return 0
  fi
  if [ -f "$GIT_ROOT/scripts/seed-worktree-env.mjs" ]; then
    echo "proplane-e2e: seeding env in $worktree"
    (cd "$worktree" && node scripts/seed-worktree-env.mjs) || return 1
  fi
}

failed=0
while IFS=$'\t' read -r branch worktree port; do
  [ -n "$branch" ] || continue
  if [ -n "$ONLY_BRANCH" ] && [ "$branch" != "$ONLY_BRANCH" ]; then
    continue
  fi
  holder=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)
  if [ -z "$holder" ]; then
    echo "proplane-e2e: localhost:$port not listening for $branch — starting dev server"
    ensure_worktree_env "$worktree" || true
    "$SCRIPT_DIR/fm-proplane-dev-server.sh" restart "$worktree" "$port" || {
      failed=$((failed + 1))
      continue
    }
    sleep 3
  fi
  ensure_worktree_env "$worktree" || true
  echo "== playwright $MODE $branch @ http://localhost:$port =="
  if ! (
    cd "$worktree"
    export PLAYWRIGHT_SKIP_WEBSERVER=1
    export PLAYWRIGHT_BASE_URL="http://localhost:${port}"
    npx playwright test "$SPEC" --reporter=list
  ); then
    echo "proplane-e2e: FAILED $branch on port $port" >&2
    failed=$((failed + 1))
  else
    echo "proplane-e2e: ok $branch"
  fi
done < <(fm_proplane_agent_all_review_rows)

if [ "$failed" -gt 0 ]; then
  echo "proplane-e2e: $failed target(s) failed" >&2
  exit 1
fi
echo "proplane-e2e: all targets passed ($MODE)"
