#!/usr/bin/env bash
# Open a headed, persistent-profile Chrome session for a one-time interactive
# login (e.g. Keycloak SSO) so later headless chrome-devtools-axi launches
# against the same profile directory reuse the saved session cookies.
# Usage: fm-chrome-login.sh [start-url]
#   Captain-run only; crewmates never authenticate themselves (see
#   docs/chrome-auth-persistence.md and bin/fm-brief.sh's browser-work rule).
#   Launches chrome-devtools-axi headed with
#   CHROME_DEVTOOLS_AXI_USER_DATA_DIR=$FM_ROOT/data/chrome-profile, the fixed
#   profile directory every crewmate's browser work reuses afterward, and
#   opens <start-url> when given.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ "$#" -gt 1 ]; then
  echo "usage: fm-chrome-login.sh [start-url]" >&2
  exit 2
fi

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROFILE_DIR="$FM_HOME/data/chrome-profile"

mkdir -p "$PROFILE_DIR"

echo "fm-chrome-login: opening a headed Chrome window on the persistent profile"
echo "  profile: $PROFILE_DIR"
echo "Complete any login (e.g. Keycloak SSO) interactively in the opened window."
echo "When done, close the window or run: chrome-devtools-axi stop"
echo "Every crewmate's browser work reuses this same profile directory afterward."

CHROME_DEVTOOLS_AXI_HEADED=1 CHROME_DEVTOOLS_AXI_USER_DATA_DIR="$PROFILE_DIR" \
  chrome-devtools-axi start

if [ "$#" -eq 1 ]; then
  CHROME_DEVTOOLS_AXI_HEADED=1 CHROME_DEVTOOLS_AXI_USER_DATA_DIR="$PROFILE_DIR" \
    chrome-devtools-axi open "$1"
fi
