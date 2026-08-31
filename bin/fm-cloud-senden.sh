#!/usr/bin/env bash
# Send state/cloud-bericht.md (or a given file) to the ntfy report topic.
#
# Usage:
#   fm-cloud-senden.sh [path-to-body]
#
# Requires state/bruecke.env with BRUECKE_BERICHT. Normalizes the on-disk bericht
# file to end with a single newline before posting.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-cloud-lib.sh
. "$SCRIPT_DIR/fm-cloud-lib.sh"

die() { printf 'fm-cloud-senden: %s\n' "$*" >&2; exit 1; }

fm_cloud_bruecke_configured || die "missing $CLOUD_BRUECKE_ENV"
fm_cloud_load_bruecke
[ -n "${BRUECKE_BERICHT:-}" ] || die 'BRUECKE_BERICHT is unset'

src=${1:-$CLOUD_BERICHT_FILE}
[ -r "$src" ] || die "cannot read report body: $src"
BODY=$(cat "$src")
[ -n "${BODY//[[:space:]]/}" ] || die 'refusing to send an empty report'

printf '%s\n' "$BODY" > "$CLOUD_BERICHT_FILE"
curl -fsS -H "Title: bericht" -d "$BODY" "https://ntfy.sh/${BRUECKE_BERICHT}"
printf '\nbericht gesendet\n'
