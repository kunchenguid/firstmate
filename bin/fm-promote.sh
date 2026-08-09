#!/usr/bin/env bash
# BOUNDED COMPATIBILITY SHIM. The scout-to-ship operation is bin/fm-reflag.sh;
# this file only forwards to it. It is not a supported entry point and carries no
# behavior of its own - do not add any, and do not cite it in documentation.
#
# It exists for exactly one caller: a firstmate turn that loaded the pre-rename
# instructions and has not yet fast-forwarded past the commit that introduced
# bin/fm-reflag.sh. docs/vocabulary-collisions.md owns the retirement condition
# in full - remove this file once every home this repository serves has
# fast-forwarded and re-read its instructions.
#
# Each use touches state/.reflag-shim-used so that retirement is settled by
# evidence rather than by memory: an absent marker after a full task cycle is the
# proof that no caller still needs the old name. The marker is best-effort and
# never blocks the forward, because refusing to reflag a live task in order to
# record a naming migration would be the wrong failure.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

echo "warning: bin/fm-promote.sh is a compatibility shim and will be removed; the scout-to-ship operation is bin/fm-reflag.sh" >&2
if [ -d "$STATE" ]; then
  { date -u '+%Y-%m-%dT%H:%M:%SZ' >> "$STATE/.reflag-shim-used"; } 2>/dev/null || true
fi

exec "$SCRIPT_DIR/fm-reflag.sh" "$@"
