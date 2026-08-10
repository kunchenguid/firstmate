#!/usr/bin/env bash
# fm-product-idea-lib.sh - single owner of product-idea ledger row grammar.
#
# Sourced, never executed. Completion attestation and Bearings counting both
# consume this grammar so a green completion cannot leave a row that Bearings
# later marks malformed.
#
#   fm_product_idea_ledger_count <ledger-path>
#       Prints the unscheduled count. Exit 0 on success, including an absent
#       ledger which counts as 0. Exit 2 when unreadable. Exit 3 when malformed.
#
#   fm_product_idea_verify_row <ledger-path> <origin-id> <idea-id>
#       Exit 0 when the ledger is fully well-formed under the count contract and
#       exactly one well-formed row for idea-id cites
#       data/<origin-id>/report.md#<section-heading> without a line number.
#       Exit 4 when the ledger is well-formed and the id is absent. Exit 3 when
#       the ledger is malformed, or the row is present but not origin-bound or
#       not well-formed under the shared row contract.
set -u

fm_product_idea_ledger_count() {  # <ledger-path>
  local ledger=$1 mode
  [ -e "$ledger" ] || { printf '0\n'; return 0; }
  if stat -f '%Lp' "$ledger" >/dev/null 2>&1; then
    mode=$(stat -f '%Lp' "$ledger" 2>/dev/null || true)
  else
    mode=$(stat -c '%a' "$ledger" 2>/dev/null || true)
  fi
  [ -f "$ledger" ] || return 2
  case "$mode" in ''|*[!0-7]*) return 2 ;; esac
  [ $((8#$mode & 0444)) -ne 0 ] || return 2
  awk -F '|' '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function valid_status(s) {
      return s == "unscheduled" \
        || s ~ /^parked \(captain [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/ \
        || s ~ /^scheduled -> [A-Za-z0-9._-]+$/ \
        || s ~ /^shipped \(was [A-Za-z0-9._-]+\)$/ \
        || s ~ /^dropped \([^()]+\)$/
    }
    function valid_source(s) {
      return s ~ /^data\/[A-Za-z0-9._-]+\/report\.md#[^#[:space:]].*$/ \
        && s !~ /:[0-9]+$/ \
        && s !~ /#L?[0-9]+(-L?[0-9]+)?$/
    }
    /^\|[[:space:]]*ID[[:space:]]*\|[[:space:]]*Idea[[:space:]]*\|[[:space:]]*Status[[:space:]]*\|[[:space:]]*Source[[:space:]]*\|[[:space:]]*$/ { header++; next }
    /^\|[[:space:]-]+\|[[:space:]-]+\|[[:space:]-]+\|[[:space:]-]+\|[[:space:]]*$/ { separator++; next }
    /^[[:space:]]*$/ || /^#/ || /^<!--[[:space:][:print:]]*-->$/ { next }
    /^\|/ {
      if (NF != 6) { malformed=1; next }
      id=trim($2); idea=trim($3); status=trim($4); source=trim($5)
      if (id !~ /^PI-[0-9][0-9][0-9]$/ || idea == "" || !valid_status(status) \
          || !valid_source(source) || seen[id]++) malformed=1
      if (status == "unscheduled") count++
      next
    }
    { malformed=1 }
    END {
      if (header != 1 || separator != 1 || malformed) exit 3
      print count + 0
    }
  ' "$ledger"
}

fm_product_idea_verify_row() {  # <ledger-path> <origin-id> <idea-id>
  local ledger=$1 origin=$2 idea_id=$3
  if ! fm_product_idea_ledger_count "$ledger" >/dev/null; then
    return 3
  fi
  awk -F '|' -v wanted="$idea_id" -v source_prefix="data/$origin/report.md#" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function valid_status(s) {
      return s == "unscheduled" \
        || s ~ /^parked \(captain [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/ \
        || s ~ /^scheduled -> [A-Za-z0-9._-]+$/ \
        || s ~ /^shipped \(was [A-Za-z0-9._-]+\)$/ \
        || s ~ /^dropped \([^()]+\)$/
    }
    function valid_source(s) {
      return s ~ /^data\/[A-Za-z0-9._-]+\/report\.md#[^#[:space:]].*$/ \
        && s !~ /:[0-9]+$/ \
        && s !~ /#L?[0-9]+(-L?[0-9]+)?$/
    }
    /^\|/ {
      if (NF != 6) next
      id = trim($2)
      if (id != wanted) next
      found++
      idea = trim($3)
      status = trim($4)
      source = trim($5)
      if (idea != "" && valid_status(status) && valid_source(source) \
          && index(source, source_prefix) == 1 \
          && length(source) > length(source_prefix)) good++
    }
    END {
      if (found == 0) exit 4
      if (found != 1 || good != 1) exit 3
    }
  ' "$ledger"
}
