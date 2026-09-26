#!/usr/bin/env bash
# fm-decision-card-lib.sh - the durable fm-decision-card.v1 store.
#
# One composed Captain's Call card survives as one private record under
# <home>/state/decision-cards/<task-id>.json. The captain's deck resolves a
# ticket's dialog from that store (after the live Lavish board), so a call
# keeps the title, about/decide context, and authored options the captain was
# shown even when no board was built or the board was rebuilt from scratch.
#
# Ownership:
#   - bin/fm-decision-card.jq is the card contract itself, included by
#     bin/fm-bearings-board.sh's payload validator and by this store's
#     validator, so the payload item and the stored record cannot drift.
#   - bin/fm-captain-hold.sh `hold` writes the card composed with the call (or
#     a mechanical baseline carrying the hold reason) and `answer` /
#     `reconcile close` remove it once the call resolves.
#   - bin/fm-bearings-board.sh `build` refreshes every surviving card from the
#     effective payload and prunes records that are definitely no longer open
#     calls, because a card wrongly hidden is worse than one wrongly shown.
#
# Every write is atomic and 0600; the store directory is created 0700 and a
# symlinked store is refused rather than followed.

FM_DECISION_CARD_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

fm_decision_card_store_dir() {  # <home>
  printf '%s/state/decision-cards\n' "$1"
}

fm_decision_card_key_valid() {  # <key>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) [ "${#1}" -le 128 ] ;;
  esac
}

# Validate one composed card (before the standard reconcile choice is added).
fm_decision_card_validate() {  # <card-json>
  jq -e -L "$FM_DECISION_CARD_LIB_DIR" \
    'include "fm-decision-card"; call_item' >/dev/null <<<"$1"
}

# One card with the standard reconcile choice present. Prints the compact
# effective card. The board injects the same choice at payload level.
fm_decision_card_effective() {  # <card-json>
  jq -c -L "$FM_DECISION_CARD_LIB_DIR" '
    include "fm-decision-card";
    if .type == "decision" and ([.options[]?.value] | index("reconcile") == null)
    then .options = ((.options // []) + [reconcile_option])
    else . end' <<<"$1"
}

fm_decision_card_exists() {  # <home> <key>
  local dir
  fm_decision_card_key_valid "$2" || return 1
  dir=$(fm_decision_card_store_dir "$1")
  [ -f "$dir/$2.json" ] && [ ! -L "$dir/$2.json" ]
}

# Persist one effective card. The record's key is the file name, so the card
# must already carry a slug key; validation belongs to the caller, which knows
# whether the card is composed input or already-effective payload output.
fm_decision_card_persist() {  # <home> <card-json>
  local home=$1 card=$2 dir key tmp
  dir=$(fm_decision_card_store_dir "$home")
  key=$(jq -re '.key' <<<"$card" 2>/dev/null) || return 1
  fm_decision_card_key_valid "$key" || return 1
  if [ -d "$dir" ] && [ ! -L "$dir" ]; then
    :
  elif ! (umask 077; mkdir -p "$dir"); then
    return 1
  fi
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.card.XXXXXX") || return 1
  if jq -c --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --argjson card "$card" \
       -n '{schema:"fm-decision-card.v1",generated:$generated,card:$card}' > "$tmp" \
    && chmod 0600 "$tmp" \
    && mv -f -- "$tmp" "$dir/$key.json"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# Remove one record. Idempotent: an absent record is success, because the only
# outcomes are "the call has no stored card" and "the record is gone".
fm_decision_card_remove() {  # <home> <key>
  local dir
  fm_decision_card_key_valid "$2" || return 1
  dir=$(fm_decision_card_store_dir "$1")
  [ ! -d "$dir" ] || [ ! -L "$dir" ] || return 1
  rm -f -- "$dir/$2.json"
}
