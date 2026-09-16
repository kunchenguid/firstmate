#!/usr/bin/env bash
# Validate and probe home-local account slots without exposing account identity.
# Usage:
#   fm-account-slot.sh validate
#   fm-account-slot.sh probe <slot>
#   fm-account-slot.sh probe-all <slot>...
#
# FM_HOME selects the home. FM_CONFIG_OVERRIDE selects its exact config
# directory. probe-all requires at least one slot ID, de-duplicates the names it
# is given, validates the registry and references as one configuration, then
# probes sequentially. A valid but unavailable slot emits only its logical ID,
# availability.status=unavailable, and availability.reason - the probe's own
# refusal, which names logical slot IDs and missing prerequisites but never
# account identity, credential sources, or store paths - and does not stop later
# slots; malformed configuration and missing requested IDs still refuse.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-account-slot-lib.sh
. "$SCRIPT_DIR/fm-account-slot-lib.sh"

die_slot() {
  printf 'error: %s\n' "$FM_ACCOUNT_SLOT_ERROR" >&2
  exit 1
}

case "${1:-}" in
  validate)
    [ "$#" -eq 1 ] || { echo "usage: fm-account-slot.sh validate" >&2; exit 2; }
    fm_account_slot_validate_registry "$CONFIG" || die_slot
    fm_account_slot_validate_dispatch "$CONFIG" || die_slot
    printf 'account slots valid\n'
    ;;
  probe)
    [ "$#" -eq 2 ] || { echo "usage: fm-account-slot.sh probe <slot>" >&2; exit 2; }
    fm_account_slot_probe "$CONFIG" "$2" || die_slot
    ;;
  probe-all)
    shift
    [ "$#" -gt 0 ] || { echo "usage: fm-account-slot.sh probe-all <slot>..." >&2; exit 2; }
    fm_account_slot_validate_registry "$CONFIG" || die_slot
    fm_account_slot_validate_dispatch "$CONFIG" || die_slot
    fm_quota_axi_probe_capability || { FM_ACCOUNT_SLOT_ERROR=$FM_QUOTA_AXI_CAPABILITY_ERROR; die_slot; }
    slots=
    for slot in "$@"; do
      case $'\n'"$slots"$'\n' in *$'\n'"$slot"$'\n'*) continue ;; esac
      slots=${slots:+$slots$'\n'}$slot
    done
    while IFS= read -r slot; do
      [ -n "$slot" ] || continue
      harness=$(jq -r --arg slot "$slot" '.slots[$slot].harness // empty' "$CONFIG/account-slots.json") \
        || { FM_ACCOUNT_SLOT_ERROR="slot '$slot' cannot be read"; die_slot; }
      [ -n "$harness" ] || { FM_ACCOUNT_SLOT_ERROR="slot '$slot' is not configured in this home"; die_slot; }
    done <<< "$slots"
    tmp=$(mktemp "${TMPDIR:-/tmp}/fm-account-slots.XXXXXX") || exit 1
    trap 'rm -f "$tmp"' EXIT
    : > "$tmp"
    while IFS= read -r slot; do
      [ -n "$slot" ] || continue
      if ! fm_account_slot_probe "$CONFIG" "$slot" >> "$tmp"; then
        jq -cn --arg slot "$slot" --arg reason "$FM_ACCOUNT_SLOT_ERROR" \
          '{accountSlot:$slot,availability:{status:"unavailable",reason:$reason}}' >> "$tmp" \
          || { FM_ACCOUNT_SLOT_ERROR="sanitized unavailable evidence could not be emitted"; die_slot; }
      fi
    done <<< "$slots"
    jq -sc '{slots:.}' "$tmp"
    ;;
  -h|--help|'')
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "usage: fm-account-slot.sh validate|probe <slot>|probe-all <slot>..." >&2
    exit 2
    ;;
esac
