#!/usr/bin/env bash
# tests/fm-jev-decisions.test.sh - verify Jev open decision triage behavior
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DECISION_SH="$ROOT/bin/fm-jev-decisions.sh"
DECISION_PY="$ROOT/bin/fm-jev-decisions.py"
[ -x "$DECISION_SH" ] || fail "bin/fm-jev-decisions.sh missing or not executable"
[ -x "$DECISION_PY" ] || fail "bin/fm-jev-decisions.py missing or not executable"

TDIR=$(fm_test_tmproot fm-jev-decisions-test)

# 1. Empty input / no decisions exits cleanly
out=$(python3 "$DECISION_PY" --input /dev/null 2>/dev/null || true)
assert_contains "$out" "No open decisions found" "empty input emits no decisions message"

out_json=$(python3 "$DECISION_PY" --input /dev/null --json 2>/dev/null || true)
assert_contains "$out_json" "[]" "empty input emits empty json array"

# 2. TSV input parsing with unavailable key fails open
TSV="$TDIR/decisions.tsv"
cat <<'EOF' > "$TSV"
test-task	pending-reply-abc123	blocked	pending-reply-missed: task=test-task request=CONFIG_REREAD
test-task	api-quota-exceeded	needs-decision	Need captain approval to upgrade Claude API tier
EOF

out_tsv=$(env TYPESAFE_API_KEY="" python3 "$DECISION_PY" --input "$TSV" 2>/dev/null || true)
assert_contains "$out_tsv" "TASK" "table header present"
assert_contains "$out_tsv" "test-task" "task identifier present"
assert_contains "$out_tsv" "pending-reply-abc123" "key present"

# 3. Live classification if key is available
if sudo -n /opt/ra/firstmate/bin/jev-typesafe-run.py -- env | grep -q "TYPESAFE_API_KEY"; then
  # Live run on TSV
  live_out=$(python3 "$DECISION_PY" --input "$TSV")
  assert_contains "$live_out" "stale_historical" "pending-reply classified as stale_historical"
  assert_contains "$live_out" "policy_spend" "api quota decision classified as policy_spend"

  # Resolve commands generation
  res_cmds=$(python3 "$DECISION_PY" --input "$TSV" --resolve-cmds)
  assert_contains "$res_cmds" "bin/fm-send.sh test-task --resolve-key pending-reply-abc123" "resolve cmd emitted for stale key"

  # JSON output verification
  json_res=$(python3 "$DECISION_PY" --input "$TSV" --json)
  assert_contains "$json_res" '"category": "stale_historical"' "json output has stale_historical category"
  assert_contains "$json_res" '"actionable_noul":' "json output has actionable_noul"

  # Category filtering
  stale_only=$(python3 "$DECISION_PY" --input "$TSV" --category stale_historical --json)
  assert_contains "$stale_only" "pending-reply-abc123" "filter includes stale key"
  if echo "$stale_only" | grep -q "api-quota-exceeded"; then
    fail "category filter failed to exclude policy_spend key"
  fi
fi

pass "all fm-jev-decisions tests passed"
