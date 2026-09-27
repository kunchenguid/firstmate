#!/usr/bin/env bash
# tests/fm-jev-disk-reaper.test.sh - Test suite for Pattern 26 Disk Reaper
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
REAPER_SH="$FM_ROOT/bin/fm-jev-disk-reaper.sh"

pass() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

TDIR=$(mktemp -d "/tmp/fm-jev-reaper-test.XXXXXX")
cleanup() { rm -rf "$TDIR"; }
trap cleanup EXIT

# 1. ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$REAPER_SH" || fail "shellcheck failed on fm-jev-disk-reaper.sh"
  pass "shellcheck clean"
else
  echo "skip: shellcheck not found"
fi

# 2. Help flag verification
"$REAPER_SH" --help >/dev/null 2>&1 || fail "--help failed"
pass "--help works"

# 3. Create mock files in mock tmp
MOCK_TMP="$TDIR/mock_tmp"
mkdir -p "$MOCK_TMP"

# Stale candidate (fm- prefix, older than 4h)
echo "stale content" > "$MOCK_TMP/fm-stale-test.txt"
touch -d "5 hours ago" "$MOCK_TMP/fm-stale-test.txt"

# Fresh candidate (fm- prefix, but modified 10 mins ago -> should NOT be reaped)
echo "fresh content" > "$MOCK_TMP/fm-fresh-test.txt"
touch -d "10 minutes ago" "$MOCK_TMP/fm-fresh-test.txt"

# Non-matching prefix (even if stale -> should NOT be touched)
echo "important file" > "$MOCK_TMP/important-doc.txt"
touch -d "10 hours ago" "$MOCK_TMP/important-doc.txt"

# Stale dir
mkdir -p "$MOCK_TMP/playwright-artifacts-stale"
echo "trace" > "$MOCK_TMP/playwright-artifacts-stale/trace.bin"
touch -d "6 hours ago" "$MOCK_TMP/playwright-artifacts-stale"

# 4. Dry-run test
json_dry=$("$REAPER_SH" --tmp-dir "$MOCK_TMP" --max-age-hours 4 --json)
cand_count=$(echo "$json_dry" | jq '.summary.candidate_count')
dry_flag=$(echo "$json_dry" | jq '.summary.dry_run')

[ "$cand_count" -eq 2 ] || fail "expected 2 stale candidates, got $cand_count"
[ "$dry_flag" = "true" ] || fail "expected dry_run=true"
[ -f "$MOCK_TMP/fm-stale-test.txt" ] || fail "dry-run should not delete files"
[ -f "$MOCK_TMP/fm-fresh-test.txt" ] || fail "fresh file disappeared"
[ -f "$MOCK_TMP/important-doc.txt" ] || fail "important doc disappeared"
pass "dry-run identifies exactly 2 candidates without deleting"

# 5. Apply test
json_apply=$("$REAPER_SH" --tmp-dir "$MOCK_TMP" --max-age-hours 4 --apply --json)
reaped=$(echo "$json_apply" | jq '.summary.reaped_count')
[ "$reaped" -eq 2 ] || fail "expected 2 reaped items, got $reaped"

[ ! -f "$MOCK_TMP/fm-stale-test.txt" ] || fail "stale file was not deleted"
[ ! -d "$MOCK_TMP/playwright-artifacts-stale" ] || fail "stale dir was not deleted"
[ -f "$MOCK_TMP/fm-fresh-test.txt" ] || fail "fresh file was wrongly deleted!"
[ -f "$MOCK_TMP/important-doc.txt" ] || fail "important doc was wrongly deleted!"
pass "apply mode pruned only stale candidates and preserved fresh/whitelisted files"

pass "all Pattern 26 disk reaper tests passed"
