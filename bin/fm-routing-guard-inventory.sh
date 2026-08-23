#!/usr/bin/env bash
# Emit, refresh, or verify the committed routing-refusal guard-site inventory.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
INVENTORY="$ROOT/docs/verification/routing-receipt-guard-sites.tsv"

emit_inventory() {
  awk '
    index($0, "fm_routing_refuse") && $0 !~ /^[[:space:]]*fm_routing_refuse\(\)/ {
      text = $0
      sub(/^[[:space:]]+/, "", text)
      printf "%s\t%d\t%s\n", label, FNR, text
    }
  ' label=bin/fm-routing-decision-lib.sh "$ROOT/bin/fm-routing-decision-lib.sh"
  awk '
    index($0, "fail(") {
      text = $0
      sub(/^[[:space:]]+/, "", text)
      printf "%s\t%d\t%s\n", label, FNR, text
    }
  ' label=bin/fm-routing-fs-boundary.pl "$ROOT/bin/fm-routing-fs-boundary.pl"
}

case "${1:-}" in
  '') emit_inventory ;;
  --write)
    tmp=$(mktemp "${TMPDIR:-/tmp}/fm-routing-guards.XXXXXX") || exit 1
    trap 'rm -f "$tmp"' EXIT
    emit_inventory > "$tmp" || exit 1
    mv "$tmp" "$INVENTORY" || exit 1
    trap - EXIT
    ;;
  --check)
    tmp=$(mktemp "${TMPDIR:-/tmp}/fm-routing-guards.XXXXXX") || exit 1
    trap 'rm -f "$tmp"' EXIT
    emit_inventory > "$tmp" || exit 1
    cmp -s "$tmp" "$INVENTORY" || {
      echo "error: routing guard inventory is stale; run bin/fm-routing-guard-inventory.sh --write" >&2
      exit 1
    }
    ;;
  *)
    echo "usage: bin/fm-routing-guard-inventory.sh [--write|--check]" >&2
    exit 2
    ;;
esac
