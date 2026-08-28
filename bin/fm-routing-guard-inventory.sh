#!/usr/bin/env bash
# Emit, refresh, or verify the committed routing-refusal guard-site inventory.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
INVENTORY="$ROOT/docs/verification/routing-receipt-guard-sites.tsv"

emit_inventory() {
  awk '
    function emit(kind) {
      text = $0
      sub(/^[[:space:]]+/, "", text)
      printf "%s\t%d\t%s\t%s\n", label, FNR, kind, text
    }
    /^[[:space:]]*fm_routing_decision_required\(\)/ { predicate_function = "required"; next }
    /^[[:space:]]*fm_routing_raw_environment_assignment\(\)/ { predicate_function = "environment"; next }
    /^[[:space:]]*fm_routing_literal_words\(\)/ { predicate_function = "literal-words"; next }
    predicate_function == "required" && /^[[:space:]]*\[/ { emit("implicit-status-predicate") }
    predicate_function == "environment" && /^[[:space:]]*\[\[/ { emit("implicit-status-predicate") }
    predicate_function == "literal-words" && /^[[:space:]]*\[ "\$\{#FM_ROUTING_WORDS\[@\]\}"/ { emit("implicit-status-predicate") }
    /^[[:space:]]*}/ { predicate_function = "" }
    index($0, "fm_routing_refuse") && $0 !~ /^[[:space:]]*fm_routing_refuse\(\)/ {
      emit("refusal-call")
    }
    index($0, "return 1") {
      emit("failure-return")
    }
  ' label=bin/fm-routing-decision-lib.sh "$ROOT/bin/fm-routing-decision-lib.sh"
  awk '
    function emit(kind) {
      text = $0
      sub(/^[[:space:]]+/, "", text)
      printf "%s\t%d\t%s\t%s\n", label, FNR, kind, text
    }
    index($0, "fail(") {
      emit("failure-call")
    }
  ' label=bin/fm-routing-fs-boundary.pl "$ROOT/bin/fm-routing-fs-boundary.pl"
  awk '
    function emit(kind) {
      text = $0
      sub(/^[[:space:]]+/, "", text)
      printf "%s\t%d\t%s\t%s\n", label, FNR, kind, text
    }
    /^[[:space:]]*#/ { next }
    continuation {
      if ($0 !~ /^[[:space:]]*$/) emit("dispatch-routing-candidate")
      if (index($0, "exit 1") || $0 ~ /^[[:space:]]*}/ || $0 ~ /; then[[:space:]]*$/) continuation = 0
      next
    }
    /ROUTING_CONFIG|ROUTING_DECISION_REQUIRED|ROUTING_COMMITTED_HANDOFF|ROUTING_PREFLIGHT_ONLY|FM_ROUTING_[[:alnum:]_]+|RELAUNCH_PRIOR_ROUTING_[[:alnum:]_]+|fm_routing_decision_[[:alnum:]_]+|fm_operational_verified_file_input/ {
      emit("dispatch-routing-candidate")
      if ($0 ~ /\\[[:space:]]*$/ || $0 ~ /\|\|[[:space:]]*{[[:space:]]*$/) continuation = 1
    }
  ' label=bin/fm-spawn.sh "$ROOT/bin/fm-spawn.sh"
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
