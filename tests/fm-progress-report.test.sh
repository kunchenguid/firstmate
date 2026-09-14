#!/usr/bin/env bash
# Behavior tests for bin/fm-progress-report.sh.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/fm-progress-report.sh"
LIB="$ROOT/bin/fm-progress-report-lib.sh"
FIX="$ROOT/tests/fixtures/fm-progress-report"
TMP_ROOT=$(fm_test_tmproot fm-progress-report)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

NOW_MS=1789297200000 # 2026-09-13T11:00:00Z

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

run_report() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$@" "$REPORT" 2>&1
}

seed_state() { # <home> <key=value>...
  local home=$1 kv
  shift
  : > "$home/state/progress-report.last"
  for kv in "$@"; do printf '%s\n' "$kv" >> "$home/state/progress-report.last"; done
}

test_bar_rounding_boundaries() {
  local out
  out=$(bash -c '. "$1"; fm_progress_bar 0 1; echo; fm_progress_bar 1 3; echo; fm_progress_bar 7 14; echo; fm_progress_bar 87 100' _ "$LIB")
  assert_equals $'░░░░░░░░░░░░░░\n█████░░░░░░░░░\n███████░░░░░░░\n████████████░░' "$out" \
    "14-cell bars must divide by max at documented boundaries"
  pass "bar helper rounds to exactly 14 cells"
}

test_refuses_missing_quarantine() {
  local home out rc
  home=$(make_home missing-quarantine)
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$home/missing-quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    "$REPORT" 2>&1); rc=$?
  expect_code 1 "$rc" "missing quarantine must fail"
  assert_contains "$out" 'quarantine is missing' "missing quarantine diagnostic"
  [ ! -e "$home/state/progress-report.last" ] || fail "refusal must not create state"
  pass "missing quarantine is refused before state mutation"
}

test_refuses_malformed_quota() {
  local home bad out rc
  home=$(make_home bad-quota)
  bad="$home/bad-quota.json"
  printf '{ "schemaVersion": 1 }\n' > "$bad"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$bad" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    "$REPORT" 2>&1); rc=$?
  expect_code 1 "$rc" "malformed quota must fail"
  assert_contains "$out" 'quota snapshot is malformed' "malformed quota diagnostic"
  [ ! -e "$home/state/progress-report.last" ] || fail "refusal must not create state"
  pass "malformed quota snapshot is refused"
}

test_unchanged_render_is_suppressed() {
  local home first second rc
  home=$(make_home unchanged)
  first=$(run_report "$home")
  [ -n "$first" ] || fail "first render must emit a report"
  second=$(run_report "$home"); rc=$?
  expect_code 0 "$rc" "unchanged second render must succeed silently"
  [ -z "$second" ] || fail "unchanged render must print nothing: $second"
  pass "unchanged render exits silently and leaves prior state intact"
}

test_changed_render_advances_timestamp() {
  local home first second last before after
  home=$(make_home changed)
  first=$(run_report "$home")
  [ -n "$first" ] || fail "initial render must emit output"
  last="$home/state/progress-report.last"
  before=$(grep '^post_ts=' "$last" | cut -d= -f2-)
  cat > "$home/merged-prs.toon" <<'EOF'
[2]{mergedAt,number,title,url}:
  "2026-09-13T10:30:00Z",368,"Scope gate for review watches","https://github.com/pedromuller-del/firstmate/pull/368"
  "2026-09-13T12:00:01Z",999,"New merge","https://github.com/pedromuller-del/firstmate/pull/999"
EOF
  second=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$home/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=1789300800000 \
    "$REPORT" 2>&1)
  [ -n "$second" ] || fail "changed render must emit a report"
  after=$(grep '^post_ts=' "$last" | cut -d= -f2-)
  [ "$before" = "2026-09-13T11:00:00Z" ] || fail "first post must use the rendered clock: $before"
  [ "$after" = "2026-09-13T12:00:00Z" ] || fail "last-post timestamp must advance on a changed render: $after"
  assert_contains "$second" 'pull/999' "changed render must include the new merged pull request"
  pass "changed render advances the last-post timestamp"
}

test_ready_queue_order_is_preserved() {
  local home out
  home=$(make_home queue-order)
  out=$(run_report "$home")
  assert_contains "$out" '1. fm-followup-b48 (ship, firstmate)' "first ready item"
  assert_contains "$out" '2. fm-followup-b60 (scout, firstmate)' "second ready item"
  pass "ready queue order matches tasks-axi"
}

test_complete_fixture_matches_template() {
  local home out expected
  home=$(make_home complete)
  out=$(run_report "$home")
  expected=$(<"$FIX/expected-report.txt")
  assert_equals "$expected" "$out" "complete fixture must match the hourly template"
  pass "complete fixture render matches the stored template output"
}

test_worker_status_files_do_not_affect_output() {
  local home first second
  home=$(make_home source-boundary)
  printf 'needs-decision: merge https://github.com/example.com/secret\n' > "$home/state/fm-secret.status"
  first=$(run_report "$home")
  printf 'needs-decision: changed decision text must not matter\n' > "$home/state/fm-secret.status"
  second=$(run_report "$home")
  [ -n "$first" ] || fail "first render must emit output"
  [ -z "$second" ] || fail "worker status mutation must not change a suppressed render: $second"
  pass "worker status files cannot affect output or fingerprint"
}

test_smoke_unknown_without_permitted_source() {
  local home out
  home=$(make_home smoke-unknown)
  out=$(run_report "$home")
  assert_contains "$out" 'unknown / 1' "smoke must be unknown without a permitted source"
  assert_contains "$out" 'unknown / 24 h' "quiet clock must be unknown without a permitted source"
  pass "unsupported metrics render as unknown"
}

test_bar_fraction_visible_in_render() {
  local home out
  home=$(make_home bar-fraction)
  out=$(run_report "$home")
  assert_contains "$out" 'Fix classes landed   █████░░░░░░░░░  1 / 3' "quarantine fraction must not render a full bar"
  pass "rendered bars divide by max"
}

test_gh_transport_decodes_supported_toon() {
  local home fake out
  home=$(make_home gh-transport)
  fake="$home/fake-gh"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$FIX/merged-prs.toon" > "$fake"
  chmod +x "$fake"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_GH_CMD="$fake" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'https://github.com/pedromuller-del/firstmate/pull/368 unknown min' \
    "production gh transport must decode the supported TOON envelope"
  pass "gh-axi TOON envelope is decoded and rendered"
}

test_gh_envelope_truncation_is_refused() {
  local home fake out rc
  home=$(make_home gh-truncated)
  fake="$home/fake-gh"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
printf 'api_response:\n  body: "[{\"number\":368}]"\n  truncated: true\n  original_length: 9999\n'
EOF
  chmod +x "$fake"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_GH_CMD="$fake" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1); rc=$?
  expect_code 1 "$rc" "truncated gh envelope must fail"
  [ ! -e "$home/state/progress-report.last" ] || fail "refusal must not create state"
  pass "truncated or non-array gh-axi envelopes are refused"
}

test_merged_row_must_be_canonical() {
  local home out
  home=$(make_home merged-canonical)
  cat > "$home/merged-bad.toon" <<'EOF'
[2]{mergedAt,number,title,url}:
  "2026-09-13T10:30:00Z",1,"Wrong repo and URL","https://github.com/other/repo/pull/999"
  "2026-09-13T10:31:00Z",368,"Scope gate","https://github.com/pedromuller-del/firstmate/pull/368"
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$home/merged-bad.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'merged unknown' "a non-canonical merged row must surface as unknown"
  case "$out" in *pull/368*) fail "incomplete merged evidence must not silently render rows" ;; esac
  pass "non-canonical merged rows stay visible as unknown"
}

test_merged_duplicate_conflict_is_unknown() {
  local home out
  home=$(make_home merged-conflict)
  cat > "$home/merged-conflict.toon" <<'EOF'
[2]{mergedAt,number,title,url}:
  "2026-09-13T10:30:00Z",368,"First title","https://github.com/pedromuller-del/firstmate/pull/368"
  "2026-09-13T10:31:00Z",368,"Conflicting title","https://github.com/pedromuller-del/firstmate/pull/368"
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$home/merged-conflict.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'merged unknown' "conflicting duplicate merged rows must surface as unknown"
  pass "conflicting merged duplicates are rejected"
}

test_quarantine_requires_exact_schema() {
  local home out
  home=$(make_home quarantine-no-table)
  printf '# Quarantine\n\nNo ledger table here at all.\n' > "$home/q.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$home/q.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'Ledger               unknown classes' "prose without the exact table must not render a numeric ledger"
  case "$out" in *'0 / 0'*) fail "a missing table must not invent 0 / 0" ;; esac
  home=$(make_home quarantine-prefix-status)
  cat > "$home/q.md" <<'EOF'
# Quarantine

| Class | Occurrences (evidence) | Status | Owner / plan | Verification window |
|---|---|---|---|---|
| Prefix claim | 2 | fixed totally-unverified | owner | 48 h |
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$home/q.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'Ledger               unknown classes' "a status prefix claim must invalidate the ledger"
  pass "quarantine requires the exact header and status grammar"
}

test_quarantine_accepts_real_prose_grammar() {
  local home out
  home=$(make_home quarantine-real-grammar)
  cat > "$home/q.md" <<'EOF'
# Quarantine (what does not work goes here until data shows the fix held)

Rule: one row per flaw class, not per incident.

| Class | Occurrences (evidence) | Status | Owner / plan | Verification window |
|---|---|---|---|---|
| Watcher heartbeat stalls during sweeps | 2 (B38 09-12 04:xx, 09-12 11:55) | open | fm-followup-b38 (queued) | 48 h without a stale-beat notice |
| Relaunch drops dispatch attestation | 3 (B21, B27b, B44) | fixed for quota (334); open for plain relaunch | fm-followup-b44 (queued) | 5 relaunches with intact meta |
| Seal times out during child teardown | 1 (reviews home, key abc) | fixed (PR 359, 18:51; b56 retired) | verify from lifecycle | 5 merged seats auto-collected |
| Install scope gate | 3 events, 5 homes each (09-12 17:55) | fixed (PR 368, 09-13 09:2x) | fm-followup-b59 done | next fm-update installs exactly one home |
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$home/q.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'Ledger               4 classes: 2 fixed · 2 owned' \
    "the live prose grammar must render a numeric ledger"
  pass "real prose-rich quarantine grammar renders numbers"
}

test_quarantine_strict_validation() {
  local home out
  home=$(make_home quarantine-strict)
  cat > "$home/q.md" <<'EOF'
# Quarantine

| Class | Occurrences (evidence) | Status | Owner / plan | Verification window |
|---|---|---|---|---|
| Classifier drift misroutes seats | 2 | open | fm-followup-b70 | 48 h |
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$home/q.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'Ledger               1 classes: 0 fixed · 1 owned' \
    "a class whose name contains Class must be kept"
  home=$(make_home quarantine-bad-evidence)
  cat > "$home/q.md" <<'EOF'
# Quarantine

| Class | Occurrences (evidence) | Status | Owner / plan | Verification window |
|---|---|---|---|---|
| Bad evidence | several | open | fm-followup-b70 | 48 h |
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$home/q.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'Ledger               unknown classes' "nonnumeric evidence must invalidate the ledger"
  home=$(make_home quarantine-duplicates)
  cat > "$home/q.md" <<'EOF'
# Quarantine

| Class | Occurrences (evidence) | Status | Owner / plan | Verification window |
|---|---|---|---|---|
| Duplicate class | 1 | open | owner-a | 48 h |
| Duplicate class | 2 | fixed | owner-b | 24 h |
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$home/q.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'Ledger               unknown classes' "conflicting duplicates must invalidate the ledger"
  pass "quarantine identity, evidence, and duplicates are strictly validated"
}

test_empty_ledger_renders_honestly() {
  local home out
  home=$(make_home empty-ledger)
  cat > "$home/q.md" <<'EOF'
# Quarantine

| Class | Occurrences (evidence) | Status | Owner / plan | Verification window |
|---|---|---|---|---|
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$home/q.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'Fix classes landed' "empty ledger still renders the landed line"
  assert_contains "$out" '  0 / 0' "empty ledger must not invent a denominator"
  assert_contains "$out" 'Ledger               0 classes' "empty ledger renders zero classes"
  pass "an empty quarantine ledger renders honestly as 0 / 0"
}

test_verification_window_claim_removed() {
  local home out
  home=$(make_home window-claim)
  out=$(run_report "$home")
  case "$out" in *'inside their verification window'*)
    fail "unsupported verification-window claim must be removed" ;; esac
  assert_contains "$out" 'verification window unknown' "window claim must render as unknown"
  pass "no unsupported verification-window language is rendered"
}

test_new_flaw_classes_stay_unknown() {
  local home first second
  home=$(make_home new-classes)
  first=$(run_report "$home")
  assert_contains "$first" 'new flaw classes unknown' "first render reports new classes as unknown"
  cat > "$home/q.md" <<'EOF'
# Quarantine

| Class | Occurrences (evidence) | Status | Owner / plan | Verification window |
|---|---|---|---|---|
| Auto-retire refusal lines block completion gates | 4 | fixed (PR 339) | verify | 24 h |
| Watcher heartbeat stalls | 2 | open | fm-followup-b38 | 48 h |
| Pane-close verification refuses an already-gone pane | 3 | researching | fm-followup-b46 | 48 h |
| Brand-new class appearing now | 1 | open | fm-followup-b71 | 48 h |
EOF
  second=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$home/q.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=1789300800000 \
    "$REPORT" 2>&1)
  [ -n "$second" ] || fail "a quarantine change must re-render"
  assert_contains "$second" 'new flaw classes unknown' "a new class must still render unknown without a typed creation event"
  pass "new-class delta stays unknown without a lossless identity snapshot"
}

test_lifecycle_counts_valid_operations() {
  local home out
  home=$(make_home lifecycle-counts)
  cp "$FIX/lifecycle.jsonl" "$home/lifecycle.jsonl"
  run_report "$home" > /dev/null
  cat > "$home/lifecycle.jsonl" <<'EOF'
{"op":"spawn","taskId":"fm-followup-b46","operationId":"fmo-1789200000001-1-1","status":0,"ts":1789200000001,"home":"firstmate"}
{"op":"spawn","taskId":"fm-followup-b47","operationId":"fmo-1789200000003-1-2","status":0,"ts":1789200000003,"home":"firstmate"}
{"op":"teardown","taskId":"fm-followup-b50","operationId":"fmo-1789200000005-1-3","status":0,"ts":1789200000005,"home":"firstmate"}
{"op":"teardown","taskId":"fm-followup-b51","operationId":"fmo-1789200000006-1-4","status":1,"ts":1789200000006,"home":"firstmate"}
{"op":"wake-drain","elapsedMs":1000,"status":0,"ts":1789200000007,"home":"firstmate"}
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$home/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'seats started/retired 2/1' \
    "successful identity-carrying operations count; failures and foreign ops do not"
  pass "lifecycle counts only valid successful seat operations"
}

test_lifecycle_unclassifiable_rows_poison_counts() {
  local home out variant
  local i=0
  for variant in \
    '{"op":"spawn","taskId":"t1","operationId":"fmo-1-1-1","status":0,"ts":1789200000001' \
    '{"op":"spawn","status":0,"ts":1789200000002,"home":"firstmate"}' \
    '{"op":"teardown","taskId":"t2","operationId":"fmo-1-1-3","ts":1789200000003,"home":"firstmate"}' \
    '{"op":"spawn","taskId":"t3","operationId":"fmo-1-1-4","status":0,"ts":99999999999999,"home":"firstmate"}'; do
    i=$((i + 1))
    home=$(make_home "lifecycle-poison-$i")
    cp "$FIX/lifecycle.jsonl" "$home/lifecycle.jsonl"
    run_report "$home" > /dev/null
    printf '%s\n' "$variant" >> "$home/lifecycle.jsonl"
    out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
      FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
      FM_PROGRESS_LIFECYCLE="$home/lifecycle.jsonl" \
      FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
      FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
      FM_PROGRESS_NOW_MS=$NOW_MS \
      "$REPORT" 2>&1)
    assert_contains "$out" 'seats started/retired unknown' \
      "an unclassifiable row must poison lifecycle counts: ${variant:0:60}"
  done
  pass "unclassifiable lifecycle rows render the snapshot unknown"
}

test_lifecycle_malformed_time_poisons() {
  local home out
  home=$(make_home lifecycle-bad-time)
  cp "$FIX/lifecycle.jsonl" "$home/lifecycle.jsonl"
  run_report "$home" > /dev/null
  printf '%s\n' '{"op":"spawn","taskId":"t1","operationId":"fmo-1-1-1","status":0,"ts":"soon"}' >> "$home/lifecycle.jsonl"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$home/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'seats started/retired unknown' "a non-numeric timestamp must poison lifecycle counts"
  pass "malformed lifecycle timestamps poison the snapshot"
}

test_lifecycle_late_append_is_counted() {
  local home out
  home=$(make_home lifecycle-late)
  cp "$FIX/lifecycle.jsonl" "$home/lifecycle.jsonl"
  run_one() {
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
      FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
      FM_PROGRESS_LIFECYCLE="$home/lifecycle.jsonl" \
      FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
      FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
      FM_PROGRESS_NOW_MS=$NOW_MS \
      "$REPORT" 2>&1
  }
  run_one > /dev/null
  # A delayed append whose producer timestamp predates the committed cursor
  # must still count: cursoring follows stream positions, not timestamps.
  printf '%s\n' '{"op":"spawn","taskId":"late-seat","operationId":"fmo-late-1-1","status":0,"ts":1789100000000,"home":"firstmate"}' \
    >> "$home/lifecycle.jsonl"
  out=$(run_one)
  assert_contains "$out" 'seats started/retired 1/0' "a late append with an older timestamp must count"
  out=$(run_one)
  [ -z "$out" ] || fail "the consumed late append must not replay: $out"
  pass "lifecycle cursor survives delayed older appends without loss or replay"
}

test_lifecycle_rotation_is_consumed() {
  local home out
  home=$(make_home lifecycle-rotation)
  : > "$home/lifecycle.jsonl"
  printf '%s\n' '{"op":"spawn","taskId":"rot-seat","operationId":"fmo-rot-1-1","status":0,"ts":1789200000001,"home":"firstmate"}' \
    > "$home/lifecycle.jsonl.1"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$home/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  # First run seeds positions at stream ends; a second run after appending to
  # the rotation must count the appended row.
  printf '%s\n' '{"op":"teardown","taskId":"rot-seat","operationId":"fmo-rot-1-2","status":0,"ts":1789200000002,"home":"firstmate"}' \
    >> "$home/lifecycle.jsonl.1"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$home/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'seats started/retired 0/1' "rotated lifecycle streams must be consumed by position"
  pass "lifecycle cursoring covers rotated streams"
}

test_clock_rollback_is_refused() {
  local home out rc
  home=$(make_home clock-rollback)
  seed_state "$home" post_epoch=1789299999 material_sha256=stale
  out=$(run_report "$home"); rc=$?
  expect_code 1 "$rc" "a clock behind the last post must fail"
  assert_contains "$out" 'clock' "rollback diagnostic mentions the clock"
  pass "clock rollback is refused before rendering"
}

test_malformed_tasks_output_is_refused() {
  local home fake out rc
  home=$(make_home tasks-malformed)
  fake="$home/fake-tasks"
  printf '#!/usr/bin/env bash\nprintf "garbage not toon at all\\n"\n' > "$fake"
  chmod +x "$fake"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_TASKS_AXI="$fake" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1); rc=$?
  expect_code 1 "$rc" "malformed tasks-axi output must fail"
  [ ! -e "$home/state/progress-report.last" ] || fail "refusal must not create state"
  pass "malformed tasks-axi output is refused"
}

test_unicode_titles_survive_backlog_decode() {
  local home out
  home=$(make_home unicode-backlog)
  cat > "$home/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued
- [ ] fm-followup-b82 - Renés fix: déjà vu — 100% 中文 too (repo: firstmate) (kind: ship)

## Done
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$home/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'Renés fix: déjà vu' "non-ASCII backlog text must survive decoding"
  pass "backlog decoding preserves non-ASCII text"
}

test_waiting_on_you_lists_captain_holds() {
  local home out
  home=$(make_home captain-hold)
  cat > "$home/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] fm-followup-b90 - Held repair (repo: firstmate) (kind: ship) (since 2026-09-12)

## Queued

## Done
EOF
  tasks-axi hold fm-followup-b90 --file "$home/backlog.md" \
    --reason 'Pedro picks the merge order' --kind captain --until 2026-09-14 >/dev/null 2>&1 \
    || fail "fixture hold mutation must succeed"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$home/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  case "$out" in *'Waiting on you:* nothing'*)
    fail "a captain hold must not render Waiting on you: nothing" ;; esac
  assert_contains "$out" 'fm-followup-b90' "captain-held item must be visible"
  assert_contains "$out" 'until 2026-09-14' "the typed hold deadline must survive to the render"
  pass "captain holds render as waiting-on-you items with their deadline"
}

test_blocked_in_flight_marks_header_red() {
  local home out
  home=$(make_home blocked-header)
  cat > "$home/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] fm-followup-b91 - Blocked repair (repo: firstmate) (kind: ship) (since 2026-09-12)

## Queued
- [ ] fm-followup-b92 - Unblocker (repo: firstmate) (kind: ship)

## Done
EOF
  tasks-axi block fm-followup-b91 --file "$home/backlog.md" \
    --by fm-followup-b92 >/dev/null 2>&1 || fail "fixture block mutation must succeed"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$home/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" '🔴 blocked' "a typed blocked in-flight row must mark the header blocked"
  assert_contains "$out" 'fm-followup-b91 by fm-followup-b92' "the dependency identity must render"
  pass "header health and dependency identity use typed blocked state"
}

test_health_is_unknown_without_negative_evidence() {
  local home out
  home=$(make_home health-unknown)
  out=$(run_report "$home")
  assert_contains "$out" '⚪ health unknown' "no typed blocked rows must render health unknown, never a proven positive"
  case "$out" in *'🟢 on track'*) fail "an unproven positive health claim must not render" ;; esac
  pass "global health never claims a positive without evidence"
}

test_quota_requires_aggregate_scope_and_freshness() {
  local home out
  home=$(make_home quota-scope)
  jq '.generatedAt = "2026-09-13T07:00:00Z"' "$FIX/quota.json" > "$home/quota-stale.json"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$home/quota-stale.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" "Codex $(printf '%14s' '') unknown" "a stale observation must render quota unknown"
  home=$(make_home quota-wrong-scope)
  jq '(.providers[] | select(.provider=="codex") | .quotaSemantics.effectiveAvailability) = [{"scope":"weekly","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]' \
    "$FIX/quota.json" > "$home/quota-partial.json"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$home/quota-partial.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" "Codex $(printf '%14s' '') unknown" "a known but non-aggregate sole scope must render unknown"
  pass "quota requires the aggregate scope and a fresh observation"
}

test_fingerprint_covers_program_label() {
  local home first second
  home=$(make_home fingerprint-program)
  first=$(run_report "$home")
  [ -n "$first" ] || fail "first render must emit output"
  second=$(run_report "$home" env FM_PROGRESS_PROGRAM='Renamed program')
  [ -n "$second" ] || fail "a program-label-only change must not be suppressed"
  assert_contains "$second" 'Renamed program' "new program label renders"
  pass "fingerprint covers the rendered program label"
}

test_fingerprint_covers_coverage_recovery() {
  local home first second
  home=$(make_home fingerprint-recovery)
  cat > "$home/merged-bad.toon" <<'EOF'
[1]{mergedAt,number,title,url}:
  "2026-09-13T10:30:00Z",1,"Wrong repo","https://github.com/other/repo/pull/1"
EOF
  first=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$home/merged-bad.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$first" 'merged unknown' "invalid coverage must render unknown"
  printf '[]\n' > "$home/merged-none.toon"
  second=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$home/merged-none.toon" \
    FM_PROGRESS_NOW_MS=1789297201000 \
    "$REPORT" 2>&1)
  [ -n "$second" ] || fail "recovery from merged unknown to merged none must re-post"
  assert_contains "$second" 'merged none' "recovered coverage renders valid none"
  pass "fingerprint covers merged-coverage state transitions"
}

test_symlinked_state_dir_is_refused() {
  local home out rc
  home=$(make_home symlink-state)
  rm -rf "$home/state"
  mkdir -p "$home/real-state"
  ln -s "$home/real-state" "$home/state"
  out=$(run_report "$home"); rc=$?
  expect_code 1 "$rc" "a symlinked state directory must fail"
  assert_contains "$out" 'symlink' "symlink diagnostic"
  [ ! -e "$home/real-state/progress-report.last" ] || fail "refusal must not write through the symlink"
  rm -rf "$home/state" "$home/real-state"
  mkdir -p "$home/real-parent/state"
  ln -s "$home/real-parent" "$home/linked-parent"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/linked-parent/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1); rc=$?
  expect_code 1 "$rc" "a state path beneath a symlinked ancestor must fail"
  [ ! -e "$home/real-parent/state/progress-report.last" ] || fail "refusal must not write through the ancestor symlink"
  pass "symlinked state directories are refused"
}

test_commit_tracks_the_validated_inode() {
  local home out rc
  home=$(make_home commit-swap)
  cat > "$home/swap.sh" <<SWAPEOF
#!/usr/bin/env bash
mv "$home/state" "$home/state-orig" && mkdir "$home/state"
SWAPEOF
  chmod +x "$home/swap.sh"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    FM_PROGRESS_TEST_SEAM=1 FM_PROGRESS_TEST_SWAP_HOOK="$home/swap.sh" \
    "$REPORT" 2>&1); rc=$?
  expect_code 0 "$rc" "a path exchange must not disturb a descriptor-relative commit"
  [ -e "$home/state-orig/progress-report.last" ] || fail "the commit must land in the originally validated directory"
  [ ! -e "$home/state/progress-report.last" ] || fail "the commit must never land in the exchanged-in directory"
  pass "the commit tracks the validated inode regardless of path exchange"
}

test_digest_shape_is_enforced() {
  local home out rc fakebin
  home=$(make_home digest-shape)
  fakebin="$home/bin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nprintf "deadbeef not a digest\\n"\n' > "$fakebin/shasum"
  chmod +x "$fakebin/shasum"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1); rc=$?
  expect_code 1 "$rc" "a malformed successful hash must fail"
  [ ! -e "$home/state/progress-report.last" ] || fail "a malformed digest must not advance state"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/shasum"
  home2=$(make_home digest-failure)
  out=$(FM_HOME="$home2" FM_STATE_OVERRIDE="$home2/state" PATH="$fakebin:$PATH" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1); rc=$?
  expect_code 1 "$rc" "a failed hash command must fail"
  [ ! -e "$home2/state/progress-report.last" ] || fail "a failed hash must not advance state"
  pass "digest shape and pipeline failure both fail closed"
}

test_shared_deadline_leaves_state_untouched() {
  local home fake out rc
  home=$(make_home deadline)
  fake="$home/slow-tasks"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$fake"
  chmod +x "$fake"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_TASKS_AXI="$fake" \
    FM_PROGRESS_TIMEOUT=1 \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1); rc=$?
  expect_code 1 "$rc" "a collection past the shared deadline must fail"
  case "$out" in *'<@U0A7XV408AD>'*) fail "a deadline must not leak report output" ;; esac
  [ ! -e "$home/state/progress-report.last" ] || fail "timeout must leave state unchanged"
  pass "one shared end-to-end deadline bounds collection"
}


test_titles_are_escaped_for_slack() {
  local home out fences
  home=$(make_home sanitize)
  cat > "$home/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued
- [ ] fm-followup-b95 - Ping <@U0SECRET> & break ``` fences now (repo: firstmate) (kind: ship)

## Done
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$home/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'Ping' "the report must render the sanitized title"
  case "$out" in *'<@U0SECRET>'*) fail "raw mention markup must not pass through" ;; esac
  fences=$(printf '%s\n' "$out" | grep -c '```')
  [ "$fences" -le 2 ] || fail "title backticks must not break the code fence: $fences fence lines"
  pass "task titles are redacted and escaped at the render boundary"
}

test_token_shaped_secrets_are_redacted() {
  local home out
  home=$(make_home sanitize-secret)
  cat > "$home/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued
- [ ] fm-followup-b96 - Rotate ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8 and e3b0c44298fc1c149afbf4c8996fb92427ae41e4 now (repo: firstmate) (kind: ship)

## Done
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$home/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'fm-followup-b96' "the item must still render"
  case "$out" in *'ghp_A1b2C3d4'*) fail "a token-shaped secret must not pass through" ;; esac
  case "$out" in *'e3b0c44298fc1c149afbf4c8996fb92427ae41e4'*) fail "a long hex blob must not pass through" ;; esac
  pass "token-shaped strings are redacted at the render boundary"
}

test_deadline_budget_uses_unfreezable_clock() {
  local home fake out rc
  home=$(make_home deadline-frozen-clock)
  fake="$home/point45-tasks"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
sleep 0.45
case " $* " in
  *" ready "*) printf 'count: 0\nready: 0 unblocked queued tasks\nready_public_followups: 0 delivery-ready obligations\n' ;;
  *" in_flight "*) printf 'count: 0\ntasks: 0 in_flight tasks in this backlog\n' ;;
  *) printf 'count: 0\ntasks: 0 queued tasks in this backlog\n' ;;
esac
EOF
  chmod +x "$fake"
  # The round-4 reproduction, minus the forgeable child mode (which no longer
  # exists): a frozen render clock must not freeze the deadline budget.
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_TASKS_AXI="$fake" \
    FM_PROGRESS_TIMEOUT=1 \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1); rc=$?
  expect_code 1 "$rc" "three 0.45s calls under a frozen clock must still die at the 1s budget"
  assert_contains "$out" 'deadline' "the shared deadline diagnostic"
  case "$out" in *'<@U0A7XV408AD>'*) fail "a deadline must not emit report output" ;; esac
  [ ! -e "$home/state/progress-report.last" ] || fail "a deadline must not commit state"
  # The exact round-4 reproduction vector: a caller-created proof file plus
  # frozen render clock entered child mode and completed past the budget.
  printf 'legacy-forge' > "$home/forge-proof"
  chmod 600 "$home/forge-proof"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_DEADLINE_PROOF="$home/forge-proof" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_TASKS_AXI="$fake" \
    FM_PROGRESS_TIMEOUT=1 \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" --deadline-child legacy-forge 2>&1); rc=$?
  expect_code 2 "$rc" "no privileged child mode exists to enter"
  pass "the deadline budget is monotonic and there is no child mode to forge"
}

test_deadline_during_commit_emits_nothing() {
  local home out rc second
  home=$(make_home deadline-commit)
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_TIMEOUT=1 \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    FM_PROGRESS_TEST_SEAM=1 FM_PROGRESS_TEST_SWAP_HOOK='sleep 30' \
    "$REPORT" 2>&1); rc=$?
  expect_code 1 "$rc" "a deadline during the commit must fail the run"
  case "$out" in *'<@U0A7XV408AD>'*) fail "a deadline must not leak report output" ;; esac
  second=$(run_report "$home")
  if [ -n "$second" ]; then
    case "$second" in
      *'<@U0A7XV408AD>'*) ;;
      *) fail "retry must emit a complete report or nothing" ;;
    esac
  fi
  pass "a deadline during commit emits nothing and the retry never duplicates"
}

test_quarantine_rejects_extra_columns() {
  local home out
  home=$(make_home quarantine-extra-column)
  cat > "$home/q.md" <<'EOF'
# Quarantine

| Class | Occurrences (evidence) | Status | Owner / plan | Verification window | Notes |
|---|---|---|---|---|---|
| Extra column row | 2 | fixed | verify | 24 h | smuggled |
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$home/q.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'Ledger               unknown classes' "an extra column must invalidate the ledger"
  case "$out" in *'1 / 1'*) fail "an extra-column row must not render as fixed" ;; esac
  pass "quarantine enforces the exact column count"
}

test_lifecycle_identity_types_are_strings() {
  local home out variant
  local i=0
  for variant in \
    '{"op":"spawn","taskId":["not","a","string"],"operationId":"fmo-1-1-1","status":0,"ts":1789200000001,"home":"firstmate"}' \
    '{"op":"spawn","taskId":"t1","operationId":["fmo-1-1-2"],"status":0,"ts":1789200000002,"home":"firstmate"}' \
    '{"op":"teardown","taskId":"t2","operationId":"fmo-1-1-3","status":"0","ts":1789200000003,"home":"firstmate"}'; do
    i=$((i + 1))
    home=$(make_home "lifecycle-types-$i")
    cp "$FIX/lifecycle.jsonl" "$home/lifecycle.jsonl"
    run_report "$home" > /dev/null
    printf '%s\n' "$variant" >> "$home/lifecycle.jsonl"
    out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
      FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
      FM_PROGRESS_LIFECYCLE="$home/lifecycle.jsonl" \
      FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
      FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
      FM_PROGRESS_NOW_MS=$NOW_MS \
      "$REPORT" 2>&1)
    assert_contains "$out" 'seats started/retired unknown' \
      "a non-string identity must poison lifecycle counts: ${variant:0:70}"
  done
  pass "lifecycle identities require producer-valid string types"
}

test_lifecycle_rotation_beyond_ring_does_not_replay() {
  local home out i
  home=$(make_home lifecycle-big-rotation)
  : > "$home/lifecycle.jsonl"
  for i in $(seq 1 1001); do
    printf '{"op":"spawn","taskId":"bulk-%d","operationId":"fmo-bulk-%d","status":0,"ts":1789200000001,"home":"firstmate"}\n' "$i" "$i"
  done >> "$home/lifecycle.jsonl"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$home/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" >/dev/null 2>&1
  # Rotate: the consumed stream becomes .1 (same inode) and a fresh current starts.
  mv "$home/lifecycle.jsonl" "$home/lifecycle.jsonl.1"
  printf '%s\n' '{"op":"spawn","taskId":"fresh","operationId":"fmo-fresh-1","status":0,"ts":1789200000002,"home":"firstmate"}' \
    > "$home/lifecycle.jsonl"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$home/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'seats started/retired 1/0' \
    "a rotation past the dedupe window must not replay consumed rows"
  pass "lifecycle cursor follows file identity across rotation renames"
}

test_merged_boundary_overlap_recovers_late_indexed_merge() {
  local home first second
  home=$(make_home merged-boundary)
  printf '[]\n' > "$home/merged-empty.toon"
  first=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$home/merged-empty.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  [ -n "$first" ] || fail "first render must emit output"
  # A merge timestamped one second BEFORE the committed bound but only
  # visible to the next query must not be lost.
  cat > "$home/merged-late.toon" <<'EOF'
[1]{mergedAt,number,title,url}:
  "2026-09-13T10:59:59Z",370,"Late indexed merge","https://github.com/pedromuller-del/firstmate/pull/370"
EOF
  second=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$home/merged-late.toon" \
    FM_PROGRESS_NOW_MS=1789297260000 \
    "$REPORT" 2>&1)
  [ -n "$second" ] || fail "a late-indexed merge before the bound must re-post"
  assert_contains "$second" 'pull/370' "the late-indexed merge must render"
  pass "identity-backed overlap recovers merges missed at the boundary"
}

test_zero_listing_rejects_truncation_marker() {
  local home fake out rc
  home=$(make_home zero-truncated)
  fake="$home/fake-tasks"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" ready "*) printf 'count: 0\nready: 0 unblocked queued tasks\nready_public_followups: 0 delivery-ready obligations\n' ;;
  *) printf 'count: 0\ntasks: 0 held tasks in this backlog\ntruncated: true\n' ;;
esac
EOF
  chmod +x "$fake"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_TASKS_AXI="$fake" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1); rc=$?
  expect_code 1 "$rc" "a zero listing carrying a truncation marker must fail"
  [ ! -e "$home/state/progress-report.last" ] || fail "refusal must not create state"
  pass "zero-listing envelope is whitelisted"
}

test_parked_preserves_hold_kind_reason_deadline() {
  local home out
  home=$(make_home parked-meaning)
  cat > "$home/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] fm-followup-b97 - Parked scout (repo: firstmate) (kind: scout) (since 2026-09-12)

## Queued

## Done
EOF
  tasks-axi hold fm-followup-b97 --file "$home/backlog.md" \
    --reason 'Graph v1.6 frozen by the program owner' --kind parked --until 2026-09-20 >/dev/null 2>&1 \
    || fail "fixture hold mutation must succeed"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$home/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'held parked: Graph v1.6 frozen by the program owner; until 2026-09-20' \
    "parked rows must carry hold kind, reason, and deadline"
  pass "held meaning survives end to end in parked output"
}

test_hash_grammar_rejects_valid_length_plus_junk() {
  local home out rc fakebin
  home=$(make_home hash-junk)
  fakebin="$home/bin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nprintf "%%064d junk\\n" 0\n' > "$fakebin/shasum"
  chmod +x "$fakebin/shasum"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1); rc=$?
  expect_code 1 "$rc" "a valid-length digest with trailing junk must fail"
  [ ! -e "$home/state/progress-report.last" ] || fail "a junk digest must not advance state"
  pass "hash grammar requires exactly one complete record"
}

test_token_families_are_redacted() {
  local home out
  home=$(make_home sanitize-families)
  cat > "$home/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued
- [ ] fm-followup-b98 - Rotate glpat-abcdefghijklmnopqrstuvwx and AKIAIOSFODNN7EXAMPLE keys (repo: firstmate) (kind: ship)

## Done
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$home/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'fm-followup-b98' "the item must still render"
  case "$out" in *'glpat-abcdefghij'*) fail "a GitLab token must not pass through" ;; esac
  case "$out" in *'AKIAIOSFODNN7EXAMPLE'*) fail "an AWS access key id must not pass through" ;; esac
  pass "supported token families are redacted at the render boundary"
}

test_quarantine_rejects_weak_fixed_row() {
  local home out
  home=$(make_home quarantine-weak-row)
  cat > "$home/q.md" <<'EOF'
# Quarantine

| Class | Occurrences (evidence) | Status | Owner / plan | Verification window |
|---|---|---|---|---|
| Unsupported fixed claim | 0 | fixed | - | - |
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$home/q.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'Ledger               unknown classes' "a zero-evidence dash-owner fixed row must invalidate the ledger"
  case "$out" in *'1 / 1'*) fail "a weak row must not render a fixed claim" ;; esac
  pass "quarantine requires positive evidence and meaningful owner and window"
}

test_merged_overlap_retains_reported_identity() {
  local home first second third
  home=$(make_home merged-replay)
  cat > "$home/merged-window.toon" <<'EOF'
[1]{mergedAt,number,title,url}:
  "2026-09-13T10:58:00Z",369,"Recent merge inside the overlap","https://github.com/pedromuller-del/firstmate/pull/369"
EOF
  first=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$home/merged-window.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$first" 'pull/369' "first run renders the merged item"
  cat > "$home/q.md" <<'EOF'
# Quarantine

| Class | Occurrences (evidence) | Status | Owner / plan | Verification window |
|---|---|---|---|---|
| Ledger change forcing a post | 1 | open | owner | 48 h |
EOF
  second=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$home/q.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$home/merged-window.toon" \
    FM_PROGRESS_NOW_MS=1789297210000 \
    "$REPORT" 2>&1)
  [ -n "$second" ] || fail "an unrelated change must re-post"
  case "$second" in *pull/369*) fail "an already-reported merge must not re-render on the second post" ;; esac
  third=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$home/merged-window.toon" \
    FM_PROGRESS_NOW_MS=1789297220000 \
    "$REPORT" 2>&1)
  case "$third" in *pull/369*) fail "the reported identity must be retained across the whole overlap: no third-run replay" ;; esac
  pass "reported merged identities persist for the full overlap window"
}

test_zero_listing_rejects_same_line_marker() {
  local home fake out rc
  home=$(make_home zero-same-line)
  fake="$home/fake-tasks"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" ready "*) printf 'count: 0
ready: 0 unblocked queued tasks
ready_public_followups: 0 delivery-ready obligations
' ;;
  *) printf 'count: 0
tasks: 0 truncated: true
' ;;
esac
EOF
  chmod +x "$fake"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_TASKS_AXI="$fake" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1); rc=$?
  expect_code 1 "$rc" "a summary line carrying extra words must fail"
  [ ! -e "$home/state/progress-report.last" ] || fail "refusal must not create state"
  pass "zero-listing summaries validate exact supported values"
}

test_zero_listing_rejects_malformed_summary_without_state() {
  local home fake out rc
  home=$(make_home zero-malformed)
  fake="$home/fake-tasks"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" ready "*) printf 'count: 0
ready: 0 unblocked queued tasks
ready_public_followups: 0 delivery-ready obligations
' ;;
  *" in_flight "*) printf 'count: 0
tasks: 0 truncated true
' ;;
  *) printf 'count: 0
tasks: 0 queued tasks in this backlog
' ;;
esac
EOF
  chmod +x "$fake"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$FIX/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_TASKS_AXI="$fake" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1); rc=$?
  expect_code 1 "$rc" "a malformed zero summary must fail"
  case "$out" in *'<@U0A7XV408AD>'*) fail "a malformed summary must not emit a report" ;; esac
  [ ! -e "$home/state/progress-report.last" ] || fail "a malformed summary must not commit state"
  pass "malformed zero summaries refuse without state mutation"
}

test_token_shaped_ids_are_redacted() {
  local home out
  home=$(make_home sanitize-id)
  cat > "$home/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued
- [ ] glpat-abcdefghijklmnopqrstuvwx - Ordinary queued title (repo: firstmate) (kind: ship)

## Done
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROGRESS_QUARANTINE="$FIX/quarantine.md" \
    FM_PROGRESS_BACKLOG="$home/backlog.md" \
    FM_PROGRESS_LIFECYCLE="$FIX/lifecycle.jsonl" \
    FM_PROGRESS_QUOTA_FILE="$FIX/quota.json" \
    FM_PROGRESS_MERGED_PRS_FILE="$FIX/merged-prs.toon" \
    FM_PROGRESS_NOW_MS=$NOW_MS \
    "$REPORT" 2>&1)
  assert_contains "$out" 'Ordinary queued title' "the row must still render"
  case "$out" in *'glpat-abcdefghij'*) fail "a token-shaped identifier must not pass through" ;; esac
  pass "identifiers pass the public-safe boundary"
}

test_bar_rounding_boundaries
test_refuses_missing_quarantine
test_refuses_malformed_quota
test_unchanged_render_is_suppressed
test_changed_render_advances_timestamp
test_ready_queue_order_is_preserved
test_complete_fixture_matches_template
test_worker_status_files_do_not_affect_output
test_smoke_unknown_without_permitted_source
test_bar_fraction_visible_in_render
test_gh_transport_decodes_supported_toon
test_gh_envelope_truncation_is_refused
test_merged_row_must_be_canonical
test_merged_duplicate_conflict_is_unknown
test_quarantine_requires_exact_schema
test_quarantine_accepts_real_prose_grammar
test_quarantine_strict_validation
test_empty_ledger_renders_honestly
test_verification_window_claim_removed
test_new_flaw_classes_stay_unknown
test_lifecycle_counts_valid_operations
test_lifecycle_unclassifiable_rows_poison_counts
test_lifecycle_malformed_time_poisons
test_lifecycle_late_append_is_counted
test_lifecycle_rotation_is_consumed
test_clock_rollback_is_refused
test_malformed_tasks_output_is_refused
test_unicode_titles_survive_backlog_decode
test_waiting_on_you_lists_captain_holds
test_blocked_in_flight_marks_header_red
test_health_is_unknown_without_negative_evidence
test_quota_requires_aggregate_scope_and_freshness
test_fingerprint_covers_program_label
test_fingerprint_covers_coverage_recovery
test_symlinked_state_dir_is_refused
test_commit_tracks_the_validated_inode
test_digest_shape_is_enforced
test_shared_deadline_leaves_state_untouched
test_titles_are_escaped_for_slack
test_token_shaped_secrets_are_redacted
test_deadline_budget_uses_unfreezable_clock
test_deadline_during_commit_emits_nothing
test_quarantine_rejects_extra_columns
test_lifecycle_identity_types_are_strings
test_lifecycle_rotation_beyond_ring_does_not_replay
test_merged_boundary_overlap_recovers_late_indexed_merge
test_zero_listing_rejects_truncation_marker
test_parked_preserves_hold_kind_reason_deadline
test_hash_grammar_rejects_valid_length_plus_junk
test_token_families_are_redacted
test_quarantine_rejects_weak_fixed_row
test_merged_overlap_retains_reported_identity
test_zero_listing_rejects_same_line_marker
test_zero_listing_rejects_malformed_summary_without_state
test_token_shaped_ids_are_redacted
