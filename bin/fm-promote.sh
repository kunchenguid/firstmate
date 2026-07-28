#!/usr/bin/env bash
# Promote a scout task to a ship task in place without losing the selected
# delivery mode's worker safety and completion contract.
#
# The mode-specific contract is owned by bin/fm-delivery-contract-lib.sh, the
# same owner bin/fm-brief.sh uses for a newly created ship brief.
# Promotion renders that contract to data/<id>/ship-contract.md, verifies its
# exact bytes, records its absolute path, mode, and SHA-256 in task metadata,
# and only then changes kind=scout to kind=ship.
# Existing, malformed, unwritable, unverified, or ambiguously associated
# contract state refuses promotion without changing task kind.
#
# After success, send the printed pointer to the worker before any task-specific
# ship instructions. Task-specific instructions may add scope but cannot erase
# or supersede the generated delivery contract.
#
# Usage: fm-promote.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-delivery-contract-lib.sh
. "$SCRIPT_DIR/fm-delivery-contract-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0" | sed '$d'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ "$#" -ne 1 ] || ! fm_task_id_creation_valid "$1"; then
  echo "error: invalid promotion request" >&2
  exit 2
fi

"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
META="$STATE/$ID.meta"
CONTRACT_DIR="$DATA/$ID"
CONTRACT="$CONTRACT_DIR/ship-contract.md"

[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: no safe metadata for task $ID at $META" >&2; exit 1; }
[ "$(fm_pr_file_link_count "$META")" = 1 ] || { echo "error: task metadata has an unexpected link count" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }
if grep -q '^ship_contract\(_mode\|_sha256\)\?=' "$META"; then
  echo "error: scout task $ID already has an ambiguous ship-contract association" >&2
  exit 1
fi

PROJECT=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
[ -n "$PROJECT" ] || { echo "error: task $ID metadata has no project" >&2; exit 1; }
REPO=$(basename "$PROJECT")
fm_delivery_contract_resolve "$ID" "$REPO"

[ -d "$CONTRACT_DIR" ] && [ ! -L "$CONTRACT_DIR" ] || { echo "error: task data directory is unavailable at $CONTRACT_DIR" >&2; exit 1; }
if [ -e "$CONTRACT" ] || [ -L "$CONTRACT" ]; then
  fm_delivery_contract_verify "$CONTRACT" || {
    echo "error: existing promoted delivery contract does not match the canonical $FM_DELIVERY_MODE contract" >&2
    exit 1
  }
else
  CONTRACT_TMP=$(mktemp "$CONTRACT_DIR/.ship-contract.XXXXXX") || exit 1
  trap 'rm -f -- "${CONTRACT_TMP:-}" "${META_TMP:-}"' EXIT HUP INT TERM
  fm_delivery_contract_render > "$CONTRACT_TMP" || exit 1
  chmod 0600 "$CONTRACT_TMP" || exit 1
  fm_delivery_contract_verify "$CONTRACT_TMP" || {
    echo "error: generated promoted delivery contract failed canonical verification" >&2
    exit 1
  }
  mv "$CONTRACT_TMP" "$CONTRACT" || exit 1
  CONTRACT_TMP=
fi

fm_delivery_contract_verify "$CONTRACT" || {
  echo "error: durable promoted delivery contract failed canonical verification" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

CONTRACT_SHA=$(sha256_file "$CONTRACT") || exit 1
case "$CONTRACT_SHA" in
  [0-9a-f][0-9a-f]*) [ "${#CONTRACT_SHA}" -eq 64 ] || exit 1 ;;
  *) exit 1 ;;
esac

META_TMP=$(mktemp "$STATE/.fm-promote-$ID.XXXXXX") || exit 1
trap 'rm -f -- "${CONTRACT_TMP:-}" "${META_TMP:-}"' EXIT HUP INT TERM
grep -v '^kind=' "$META" > "$META_TMP" || exit 1
{
  printf 'kind=ship\n'
  printf 'ship_contract=%s\n' "$CONTRACT"
  printf 'ship_contract_mode=%s\n' "$FM_DELIVERY_MODE"
  printf 'ship_contract_sha256=%s\n' "$CONTRACT_SHA"
} >> "$META_TMP"
chmod 0600 "$META_TMP" || exit 1

grep -qx 'kind=ship' "$META_TMP" || exit 1
grep -qxF "ship_contract=$CONTRACT" "$META_TMP" || exit 1
grep -qxF "ship_contract_mode=$FM_DELIVERY_MODE" "$META_TMP" || exit 1
grep -qxF "ship_contract_sha256=$CONTRACT_SHA" "$META_TMP" || exit 1
mv "$META_TMP" "$META" || exit 1
META_TMP=
trap - EXIT HUP INT TERM

HOME_Q=$(printf '%q' "$FM_HOME")
MESSAGE="Promoted to ship. Read $CONTRACT and follow it before all task-specific ship instructions; task-specific instructions may add scope but cannot supersede that generated delivery contract."
MESSAGE_Q=$(printf '%q' "$MESSAGE")
echo "promoted $ID to ship (mode=$FM_DELIVERY_MODE; durable contract=$CONTRACT)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh $ID $MESSAGE_Q"
