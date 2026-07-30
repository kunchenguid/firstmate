#!/usr/bin/env bash
# Restart ladder dev servers on keeper ports (browser open is opt-in).
#
# After ladder landing or promote, restart dev servers on keeper ports. Browser open is
# opt-in (--open-browser); fm-open-url.sh prefers wezterm open, then wezterm-open, then macOS open.
# Never open a GitHub PR unless the captain explicitly asks.
#
# Usage:
#   fm-proplane-open-localhost.sh              # restart all keeper ports + prakrit
#   fm-proplane-open-localhost.sh prakrit      # integration only (3000)
#   fm-proplane-open-localhost.sh cursor-2     # one sandbox
#   fm-proplane-open-localhost.sh --open-browser prakrit
#   fm-proplane-open-localhost.sh --no-browser # same as default (no browser)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-proplane-agent-branches-lib.sh
. "$SCRIPT_DIR/fm-proplane-agent-branches-lib.sh"

OPEN_BROWSER=0
ONLY_BRANCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --open-browser) OPEN_BROWSER=1; shift ;;
    --no-browser) OPEN_BROWSER=0; shift ;;
    --help|-h)
      echo "usage: fm-proplane-open-localhost.sh [--open-browser] [--no-browser] [branch]"
      exit 0
      ;;
    *)
      ONLY_BRANCH=$1
      shift
      ;;
  esac
done

open_url() {
  local url=$1
  if [ "$OPEN_BROWSER" -eq 0 ]; then
    return 0
  fi
  "$SCRIPT_DIR/fm-open-url.sh" "$url" || true
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PropPlane — test on localhost before any push or PR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

while IFS=$'\t' read -r branch worktree port; do
  [ -n "$branch" ] || continue
  if [ -n "$ONLY_BRANCH" ] && [ "$branch" != "$ONLY_BRANCH" ]; then
    continue
  fi
  url="http://localhost:${port}"
  echo "  $branch → $url"
  "$SCRIPT_DIR/fm-proplane-dev-server.sh" restart "$worktree" "$port" || {
    echo "proplane-open: failed to start $branch on port $port" >&2
    continue
  }
  open_url "$url"
done < <(fm_proplane_agent_all_review_rows)

echo ""
echo "  Do not open a GitHub PR unless the captain explicitly asks."
echo "  Keeper ladder: land on your branch → test localhost → captain yes → promote."
echo "  Push main only after you approve: bin/fm-proplane-promote-prakrit-to-main.sh --push-main"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
