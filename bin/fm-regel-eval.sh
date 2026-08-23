#!/usr/bin/env bash
# fm-regel-eval.sh - the rule-TDD gate (plan v3 U1.9; hardening 14: a rule
# without a case that is red without it and green with it is not adopted, and
# the golden suite runs as a gate over every rulebook change - the rulebook
# becomes a test-covered artifact, so shrinking it becomes low-risk).
#
# Usage:
#   fm-regel-eval.sh check [--regelwerk <file>] [--manifest <file>]
#       Structure gate, fast, no test runs:
#         - manifest rows are well-formed and every test: target EXISTS
#         - when the rulebook opts in (a line containing "regel-eval: enforced"),
#           every rule bullet carries an accepted anchor and the file stays
#           under 200 lines (hardening 12)
#         - coverage debt is REPORTED, never fatal: rulebook anchors with no
#           manifest row, and prose:-only rows (a rule whose enforcement is
#           still prose) - a permanently red gate would only train bypassing
#           it (L22), so debt is visible, breaches are fatal
#   fm-regel-eval.sh run [--regelwerk <file>] [--manifest <file>]
#       check, then execute every unique test: target (the golden suite);
#       nonzero when any fails
#   fm-regel-eval.sh --help
#
# Manifest (default tests/regel-eval.manifest.tsv, tracked), one row per
# incident-derived guarantee, tab-separated:
#   <row-id>\t<anchors>\t<claim>\t<enforcement>
#   enforcement: test:<repo-relative test file> | probe:<one-line command> |
#                prose:<where the duty lives until it is mechanized>
#
# Accepted rule anchors in an opted-in rulebook: (Lnn ...) ledger patterns,
# (HRn) the captain's standing hard rules (axioms, not incident-derived),
# (hardening n) the adopted best-practice hardenings, (kept) a rule the
# captain explicitly kept. A rule line without any of these is invalid -
# exactly the draft charter's "a rule without an anchor is invalid".
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
REGELWERK="$FM_ROOT/AGENTS.md"
MANIFEST="$FM_ROOT/tests/regel-eval.manifest.tsv"
MARKER='regel-eval: enforced'
TAB=$(printf '\t')

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

parse_flags() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --regelwerk) REGELWERK="${2:-}"; shift 2 ;;
      --manifest) MANIFEST="${2:-}"; shift 2 ;;
      *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
    esac
  done
}

VIOLATIONS=0
violate() { echo "VIOLATION: $*"; VIOLATIONS=$((VIOLATIONS + 1)); }

check_manifest() {
  local id anchors claim enforcement target n=0 prose=0
  if [ ! -f "$MANIFEST" ]; then
    violate "manifest missing: $MANIFEST"
    return 0
  fi
  while IFS="$TAB" read -r id anchors claim enforcement; do
    case "$id" in ''|'#'*) continue ;; esac
    n=$((n + 1))
    if [ -z "$anchors" ] || [ -z "$claim" ] || [ -z "$enforcement" ]; then
      violate "manifest row '$id' is missing a field (needs id, anchors, claim, enforcement)"
      continue
    fi
    case "$enforcement" in
      test:*)
        target=${enforcement#test:}
        [ -f "$FM_ROOT/$target" ] || violate "manifest row '$id' names a missing test: $target"
        ;;
      probe:*) ;;
      prose:*) prose=$((prose + 1)) ;;
      *) violate "manifest row '$id' has an unknown enforcement '$enforcement' (test:|probe:|prose:)" ;;
    esac
  done < "$MANIFEST"
  echo "manifest: $n row(s), $prose still prose-only (enforcement debt, not a breach)"
  if [ "$prose" -gt 0 ]; then
    awk -F'\t' '$1 !~ /^#/ && $4 ~ /^prose:/ {printf "  prose-only: %s (%s) - %s\n", $1, $2, $4}' "$MANIFEST"
  fi
}

check_rulebook() {
  local lines
  if [ ! -f "$REGELWERK" ]; then
    violate "rulebook missing: $REGELWERK"
    return 0
  fi
  if ! grep -qF "$MARKER" "$REGELWERK"; then
    echo "rulebook: $REGELWERK carries no '$MARKER' line - anchor gate skipped (pre-landing state)"
    return 0
  fi
  lines=$(wc -l < "$REGELWERK" | tr -d ' ')
  if [ "$lines" -gt 200 ]; then
    violate "rulebook has $lines lines (limit 200, hardening 12: when it grows, deletion comes first)"
  else
    echo "rulebook: $lines line(s) (limit 200)"
  fi
  local unanchored
  unanchored=$(awk '
    /^## / { insec = 1 }
    insec && (/^- / || /^[0-9]+\. /) {
      if ($0 !~ /\((L[0-9]|HR[0-9]|hardenings? [0-9]|kept)/) print NR ": " substr($0, 1, 100)
    }
  ' "$REGELWERK")
  if [ -n "$unanchored" ]; then
    while IFS= read -r l; do
      violate "rule without an anchor - invalid by its own charter: $l"
    done <<< "$unanchored"
  else
    echo "rulebook: every rule line carries an accepted anchor"
  fi
  # Coverage debt (soft): cited ledger anchors with no manifest row.
  local cited mapped unmapped
  cited=$(grep -o 'L[0-9][0-9]' "$REGELWERK" | sort -u)
  mapped=$(awk -F'\t' '$1 !~ /^#/ {print $2}' "$MANIFEST" 2>/dev/null | grep -o 'L[0-9][0-9]' | sort -u)
  unmapped=$(comm -23 <(printf '%s\n' "$cited") <(printf '%s\n' "$mapped") | tr '\n' ' ')
  if [ -n "${unmapped// /}" ]; then
    echo "coverage debt: cited anchors with no manifest row yet: $unmapped(map them or mechanize them)"
  else
    echo "coverage: every cited ledger anchor has a manifest row"
  fi
}

run_suite() {
  local target rc=0 total=0 failed=0
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    total=$((total + 1))
    if bash "$FM_ROOT/$target" >/dev/null 2>&1; then
      echo "PASS: $target"
    else
      echo "FAIL: $target"
      failed=$((failed + 1))
    fi
  done < <(awk -F'\t' '$1 !~ /^#/ && $4 ~ /^test:/ {sub(/^test:/, "", $4); print $4}' "$MANIFEST" | sort -u)
  echo "golden suite: $total test file(s), $failed failed"
  [ "$failed" -eq 0 ] || rc=1
  return "$rc"
}

cmd="${1:-check}"
case "$cmd" in
  check)
    shift || true
    parse_flags "$@"
    check_manifest
    check_rulebook
    if [ "$VIOLATIONS" -gt 0 ]; then
      echo "regel-eval: $VIOLATIONS breach(es) - the change does not pass the gate"
      exit 1
    fi
    echo "regel-eval: gate passed"
    ;;
  run)
    shift || true
    parse_flags "$@"
    check_manifest
    check_rulebook
    if [ "$VIOLATIONS" -gt 0 ]; then
      echo "regel-eval: $VIOLATIONS breach(es) - fix the structure before running the suite"
      exit 1
    fi
    run_suite
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
