#!/usr/bin/env bash
# Run one shell behavior-test lane.
#
# Usage:
#   fm-test-lane.sh <unit|integration|e2e>
#
# tests/shell-lanes.tsv is the single owner of shell-test lane classification.
# This runner validates that every tracked tests/*.test.sh file appears exactly
# once before it runs any script.
# Output deliberately includes lane/script start and finish markers with elapsed
# seconds so CI and local timeout logs name the active script.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=${FM_TEST_LANE_TEST_DIR:-"$ROOT/tests"}
MANIFEST=${FM_TEST_LANE_MANIFEST:-"$ROOT/tests/shell-lanes.tsv"}

usage() {
  echo "usage: fm-test-lane.sh <unit|integration|e2e>" >&2
}

die() {
  echo "error: $1" >&2
  exit 2
}

lane=${1:-}
[ "$#" -eq 1 ] || { usage; exit 2; }
case "$lane" in
  unit|integration|e2e) ;;
  *) usage; exit 2 ;;
esac

[ -d "$TEST_DIR" ] || die "test directory not found: $TEST_DIR"
[ -f "$MANIFEST" ] || die "lane manifest not found: $MANIFEST"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-lane.XXXXXX") || exit 2
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

actual="$tmp/actual"
manifest_scripts="$tmp/manifest-scripts"
entries="$tmp/entries"
selected="$tmp/selected"
: > "$manifest_scripts"
: > "$entries"
: > "$selected"

find "$TEST_DIR" -maxdepth 1 -type f -name '*.test.sh' -exec basename {} \; | sort > "$actual"

tab=$(printf '\t')
line_no=0
while IFS= read -r line || [ -n "$line" ]; do
  line_no=$((line_no + 1))
  case "$line" in
    ''|'#'*) continue ;;
  esac

  case "$line" in
    *"$tab"*) ;;
    *) die "malformed lane manifest line $line_no" ;;
  esac
  entry_lane=${line%%"$tab"*}
  rest=${line#*"$tab"}
  case "$rest" in
    *"$tab"*) script=${rest%%"$tab"*} ;;
    *) script=$rest ;;
  esac
  [ -n "$entry_lane" ] && [ -n "$script" ] \
    || die "malformed lane manifest line $line_no"
  case "$entry_lane" in
    unit|integration|e2e) ;;
    *) die "unknown lane '$entry_lane' in manifest line $line_no" ;;
  esac
  case "$script" in
    */*) die "manifest line $line_no must use a test basename, got '$script'" ;;
    *.test.sh) ;;
    *) die "manifest line $line_no is not a shell behavior test: $script" ;;
  esac
  printf '%s\n' "$script" >> "$manifest_scripts"
  printf '%s\t%s\n' "$entry_lane" "$script" >> "$entries"
  [ "$entry_lane" = "$lane" ] && printf '%s\n' "$script" >> "$selected"
done < "$MANIFEST"

duplicates=$(sort "$manifest_scripts" | uniq -d)
if [ -n "$duplicates" ]; then
  while IFS= read -r script; do
    [ -n "$script" ] && echo "error: duplicate lane classification: $script" >&2
  done <<EOF
$duplicates
EOF
  exit 2
fi

while IFS= read -r script || [ -n "$script" ]; do
  [ -n "$script" ] || continue
  if ! grep -Fx -- "$script" "$manifest_scripts" >/dev/null; then
    echo "error: missing lane classification: $script" >&2
    exit 2
  fi
done < "$actual"

while IFS= read -r script || [ -n "$script" ]; do
  [ -n "$script" ] || continue
  if ! grep -Fx -- "$script" "$actual" >/dev/null; then
    echo "error: stale lane classification: $script" >&2
    exit 2
  fi
done < "$manifest_scripts"

count=$(grep -c . "$selected" || true)
[ "$count" -gt 0 ] || die "lane '$lane' has no tests"

lane_start=$(date +%s)
printf 'lane-start lane=%s script-count=%s started=%s\n' "$lane" "$count" "$(date -u +%FT%TZ)"

while IFS= read -r script || [ -n "$script" ]; do
  [ -n "$script" ] || continue
  display="tests/$script"
  script_start=$(date +%s)
  printf 'script-start lane=%s script=%s started=%s\n' "$lane" "$display" "$(date -u +%FT%TZ)"
  "$TEST_DIR/$script" </dev/null
  status=$?
  script_end=$(date +%s)
  printf 'script-end lane=%s script=%s status=%s elapsed=%ss\n' \
    "$lane" "$display" "$status" "$((script_end - script_start))"
  if [ "$status" -ne 0 ]; then
    lane_end=$(date +%s)
    printf 'lane-end lane=%s status=%s failed=%s elapsed=%ss\n' \
      "$lane" "$status" "$display" "$((lane_end - lane_start))"
    exit "$status"
  fi
done < "$selected"

lane_end=$(date +%s)
printf 'lane-end lane=%s status=0 elapsed=%ss\n' "$lane" "$((lane_end - lane_start))"
