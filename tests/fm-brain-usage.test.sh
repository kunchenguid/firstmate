#!/usr/bin/env bash
# tests/fm-brain-usage.test.sh - test suite for bin/fm-brain-usage.sh.
#
# Asserts the adoption and usage aggregation logic against synthetic usage.jsonl
# fixtures:
#   - fail-open: absent or empty usage.jsonl is a clean exit-0 no-op;
#   - deliberate vs automatic split (firstmate-auto vs task/interactive);
#   - adoption metric (distinct task-ids with deliberate recall/remember);
#   - recall quality metrics (count, hit-rate, latency p50/p95);
#   - per-by verb breakdown;
#   - time window filtering (--since <ISO|Nd>);
#   - human and --json output modes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

USAGE_BIN="$ROOT/bin/fm-brain-usage.sh"
TMP_ROOT=$(fm_test_tmproot fm-brain-usage-tests)

test_absent_store_is_clean_noop() {
  local dir="$TMP_ROOT/absent-store"
  mkdir -p "$dir"

  local out rc
  out=$(BRAIN_STORE="$dir" "$USAGE_BIN" 2>&1); rc=$?
  expect_code 0 "$rc" "absent usage.jsonl must exit 0"
  [ -z "$out" ] || fail "absent usage.jsonl in human mode must produce no output, got: $out"

  out=$(BRAIN_STORE="$dir" "$USAGE_BIN" --json 2>&1); rc=$?
  expect_code 0 "$rc" "absent usage.jsonl with --json must exit 0"
  [ "$out" = "{}" ] || fail "absent usage.jsonl with --json must output {}, got: $out"

  touch "$dir/usage.jsonl"
  out=$(BRAIN_STORE="$dir" "$USAGE_BIN" 2>&1); rc=$?
  expect_code 0 "$rc" "empty usage.jsonl must exit 0"
  [ -z "$out" ] || fail "empty usage.jsonl in human mode must produce no output, got: $out"

  out=$(BRAIN_STORE="$dir" "$USAGE_BIN" --json 2>&1); rc=$?
  expect_code 0 "$rc" "empty usage.jsonl with --json must exit 0"
  [ "$out" = "{}" ] || fail "empty usage.jsonl with --json must output {}, got: $out"

  pass "absent or empty usage.jsonl is a clean exit-0 no-op"
}

test_full_aggregation_json() {
  local dir="$TMP_ROOT/full-store"
  mkdir -p "$dir"

  cat > "$dir/usage.jsonl" <<'EOF'
{"at":"2026-08-20T10:00:00Z","by":"firstmate-auto","verb":"context_pack","entities":3}
{"at":"2026-08-20T10:00:01Z","by":"firstmate-auto","verb":"delta","agent":"firstmate"}
{"at":"2026-08-20T11:00:00Z","by":"task-alpha","verb":"recall","q":"auth","hits":2,"ms":50}
{"at":"2026-08-20T11:05:00Z","by":"task-alpha","verb":"recall","q":"session","hits":0,"ms":200}
{"at":"2026-08-20T11:10:00Z","by":"task-alpha","verb":"remember","status":"ok"}
{"at":"2026-08-20T12:00:00Z","by":"task-beta","verb":"recall","q":"database","hits":1,"ms":150}
{"at":"2026-08-20T13:00:00Z","by":"cli","verb":"recall","q":"help","hits":1,"ms":100}
{"at":"2026-08-20T14:00:00Z","by":"fm-remember","verb":"remember","status":"ok"}
{"at":"2026-08-26T09:00:00Z","by":"task-gamma","verb":"recall","q":"config","hits":5,"ms":10}
EOF

  local out rc
  out=$(BRAIN_STORE="$dir" "$USAGE_BIN" --json 2>&1); rc=$?
  expect_code 0 "$rc" "aggregation must exit 0"

  local total auto deliberate adoption recall_count recall_hits p50 p95
  total=$(printf '%s' "$out" | jq -r '.total')
  auto=$(printf '%s' "$out" | jq -r '.automatic')
  deliberate=$(printf '%s' "$out" | jq -r '.deliberate')
  adoption=$(printf '%s' "$out" | jq -r '.adoption')
  recall_count=$(printf '%s' "$out" | jq -r '.recall.count')
  recall_hits=$(printf '%s' "$out" | jq -r '.recall.hits')
  p50=$(printf '%s' "$out" | jq -r '.recall.latency_ms.p50')
  p95=$(printf '%s' "$out" | jq -r '.recall.latency_ms.p95')

  [ "$total" = "9" ] || fail "expected total=9, got: $total"
  [ "$auto" = "2" ] || fail "expected automatic=2, got: $auto"
  [ "$deliberate" = "7" ] || fail "expected deliberate=7, got: $deliberate"
  # Adoption counts distinct task-ids (not in firstmate-auto, fm-remember, cli, $USER) with recall/remember
  # task-alpha (recall, remember), task-beta (recall), task-gamma (recall) -> 3
  [ "$adoption" = "3" ] || fail "expected adoption=3, got: $adoption"

  # Recalls: task-alpha(2), task-beta(1), cli(1), task-gamma(1) -> 5
  [ "$recall_count" = "5" ] || fail "expected recall.count=5, got: $recall_count"
  # Hits > 0: task-alpha#1(2), task-beta(1), cli(1), task-gamma(5) -> 4
  [ "$recall_hits" = "4" ] || fail "expected recall.hits=4, got: $recall_hits"

  # Latencies sorted: [10, 50, 100, 150, 200]
  # p50 -> index floor(4 * 0.50) = 2 -> 100
  # p95 -> index floor(4 * 0.95) = 3 -> 150
  [ "$p50" = "100" ] || fail "expected p50=100, got: $p50"
  [ "$p95" = "150" ] || fail "expected p95=150, got: $p95"

  # Verify per-by verb breakdown structure
  local alpha_verbs
  alpha_verbs=$(printf '%s' "$out" | jq -r '.by[] | select(.by == "task-alpha") | .verbs | map("\(.verb):\(.count)") | sort | join(",")')
  [ "$alpha_verbs" = "recall:2,remember:1" ] || fail "expected task-alpha verbs recall:2,remember:1, got: $alpha_verbs"

  pass "full aggregation computes breakdown, split, adoption, and recall latency"
}

test_human_readable_output() {
  local dir="$TMP_ROOT/human-store"
  mkdir -p "$dir"

  cat > "$dir/usage.jsonl" <<'EOF'
{"at":"2026-08-20T10:00:00Z","by":"firstmate-auto","verb":"context_pack","entities":3}
{"at":"2026-08-20T11:00:00Z","by":"task-ship","verb":"recall","q":"auth","hits":1,"ms":50}
EOF

  local out rc
  out=$(BRAIN_STORE="$dir" "$USAGE_BIN" 2>&1); rc=$?
  expect_code 0 "$rc" "human output must exit 0"

  assert_contains "$out" "brain-axi usage summary" "must contain title"
  assert_contains "$out" "total calls:      2" "must contain total count"
  assert_contains "$out" "automatic:        1 (firstmate-auto)" "must contain automatic count"
  assert_contains "$out" "task-ship: 1 call(s)" "must contain per-by breakdown"
  assert_contains "$out" "hit rate:  100%" "must contain recall hit rate"

  pass "human-readable report format is structured and readable"
}

test_since_filter_iso() {
  local dir="$TMP_ROOT/since-iso-store"
  mkdir -p "$dir"

  cat > "$dir/usage.jsonl" <<'EOF'
{"at":"2026-08-10T10:00:00Z","by":"task-old","verb":"recall","hits":1,"ms":50}
{"at":"2026-08-20T10:00:00Z","by":"task-mid","verb":"recall","hits":1,"ms":60}
{"at":"2026-08-25T10:00:00Z","by":"task-new","verb":"recall","hits":1,"ms":70}
EOF

  local out total
  out=$(BRAIN_STORE="$dir" "$USAGE_BIN" --since "2026-08-19T00:00:00Z" --json)
  total=$(printf '%s' "$out" | jq -r '.total')
  [ "$total" = "2" ] || fail "expected 2 records after ISO since cutoff, got: $total"

  out=$(BRAIN_STORE="$dir" "$USAGE_BIN" --since "2026-08-24T00:00:00Z" --json)
  total=$(printf '%s' "$out" | jq -r '.total')
  [ "$total" = "1" ] || fail "expected 1 record after ISO since cutoff, got: $total"

  pass "--since ISO timestamp filter correctly restricts the time window"
}

test_since_filter_days() {
  local dir="$TMP_ROOT/since-days-store"
  mkdir -p "$dir"

  cat > "$dir/usage.jsonl" <<'EOF'
{"at":"2026-08-10T10:00:00Z","by":"task-1","verb":"recall","hits":1,"ms":50}
{"at":"2026-08-20T10:00:00Z","by":"task-2","verb":"recall","hits":1,"ms":60}
EOF

  local out total
  # A huge duration (100000d) must include all historical records
  out=$(BRAIN_STORE="$dir" "$USAGE_BIN" --since "100000d" --json)
  total=$(printf '%s' "$out" | jq -r '.total')
  [ "$total" = "2" ] || fail "expected 2 records with large Nd window, got: $total"

  pass "--since Nd duration filter parses and filters"
}

test_invalid_since_rejected() {
  local dir="$TMP_ROOT/invalid-since-store"
  mkdir -p "$dir"
  touch "$dir/usage.jsonl"

  local out rc
  out=$(BRAIN_STORE="$dir" "$USAGE_BIN" --since "not-a-valid-date" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "invalid --since must fail with non-zero exit code"
  assert_contains "$out" "invalid --since" "must describe the invalid argument"

  pass "invalid --since format is rejected with exit > 0"
}

test_absent_store_is_clean_noop
test_full_aggregation_json
test_human_readable_output
test_since_filter_iso
test_since_filter_days
test_invalid_since_rejected
