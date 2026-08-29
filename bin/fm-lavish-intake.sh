#!/usr/bin/env bash
# Consume durable Lavish answers at an existing Firstmate turn boundary.
#
# The fork identifies itself with:
#   lavish-axi 1.3+ (store-forward protocol 1)
# Older upstream binaries are ignored during cutover because their lifecycle
# commands are incompatible and must never be invoked by this adapter.
set -u

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-lavish-version-lib.sh
. "$SCRIPT_DIR/fm-lavish-version-lib.sh"

command -v lavish-axi >/dev/null 2>&1 || exit 0
version=$(lavish-axi --version 2>/dev/null || true)
fm_lavish_version_compatible "$version" || exit 0

# Ordinary wake and session-start boundaries must not wait on optional legacy
# recovery below the invoking user's Downloads directory. Authoritative
# unreceipted answers and board payloads below the effective state root remain
# part of this intake.
export LAVISH_SCAN_HOME_DOWNLOADS=0
exec lavish-axi intake --home "$FM_HOME"
