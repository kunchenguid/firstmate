#!/usr/bin/env bash
# fm-version.sh - print this firstmate's version and the commit it is running.
#
# VERSION in the repo root is the single source of truth; this script reads it
# rather than carrying a copy, so the two can never disagree. A copy in code is
# how a version string ends up lying after someone bumps only one of them.
#
# Usage: fm-version.sh [--short]
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

[ -f "$ROOT/VERSION" ] || { echo "fm-version: no VERSION at $ROOT" >&2; exit 1; }
VERSION=$(tr -d '[:space:]' < "$ROOT/VERSION")

if [ "${1:-}" = "--short" ]; then printf '%s\n' "$VERSION"; exit 0; fi

commit=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
dirty=
git -C "$ROOT" diff --quiet 2>/dev/null || dirty=" (dirty)"
printf 'firstmate %s (%s)%s\n' "$VERSION" "$commit" "$dirty"
