#!/usr/bin/env bash
# Behavior tests for bin/fm-review-outcome.sh append validation and sheet output.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REVIEW_OUTCOME="$ROOT/bin/fm-review-outcome.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-outcome)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

file_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

file_size() {
  wc -c < "$1" | tr -d '[:space:]'
}

envelope_payload() {
  jq -cn '{
    schemaVersion: 4,
    taskId: "review-task-1",
    repository: "pedromuller-del/firstmate",
    pr: 123,
    roundKind: "initial",
    timestamp: "2026-08-28T12:00:00Z",
    status: "posted"
  }'
}

valid_payload() {
  envelope_payload | jq -c '. + {
    candidates: 4,
    kills: 1,
    survivors: 3,
    agreement: "unanimous"
  }'
}

unavailable_payload() {
  envelope_payload | jq -c '. + {
    status: "abandoned-unposted",
    metricsUnavailable: true,
    metricsUnavailableReason: "abandoned-before-compile"
  }'
}

HISTORIC_FIXTURE="$ROOT/tests/fixtures/fm-review-outcome/historic-shapes.jsonl"

install_historic_ledger() {
  local home=$1
  mkdir -p "$home/data"
  cp "$HISTORIC_FIXTURE" "$home/data/review-outcomes.jsonl"
  chmod 600 "$home/data/review-outcomes.jsonl"
}

WINDOW_FIXTURE="$ROOT/tests/fixtures/fm-review-outcome/window-shapes.jsonl"

install_window_ledger() {
  local home=$1
  mkdir -p "$home/data"
  cp "$WINDOW_FIXTURE" "$home/data/review-outcomes.jsonl"
  chmod 600 "$home/data/review-outcomes.jsonl"
}

test_append_refuses_bad_arguments_and_offset_timestamps() {
  local home err payload rc
  home=$(make_home append-args)

  rmdir "$home/data"
  printf '%s\n' 'not a directory' > "$home/data"
  payload=$(valid_payload)
  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "append accepted a regular file as the data directory"
  assert_contains "$err" "data directory is not a directory" \
    "regular data-path refusal did not name the directory requirement"
  rc=0

  rm -f "$home/data"
  mkdir -p "$home/data"

  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" append --bogus 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "append accepted unknown option --bogus"
  assert_contains "$err" "unknown argument" \
    "refusal for unknown append option did not name the argument"
  rc=0

  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" append --payload 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "append accepted --payload without a value"
  assert_contains "$err" "payload" \
    "refusal for missing --payload value did not name payload"
  rc=0

  payload=$(valid_payload | jq -c '.timestamp="2026-08-28T12:00:00+05:00"')
  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "append accepted offset timestamp"
  assert_contains "$err" "timestamp" \
    "refusal for offset timestamp did not name timestamp"
  rc=0

  pass "review outcome append refuses unknown options, missing payload, and offset timestamps"
}

test_append_validates_required_fields_and_status() {
  local home err ledger payload rc field bad
  home=$(make_home append-fields)
  ledger="$home/data/review-outcomes.jsonl"

  for field in schemaVersion taskId repository pr roundKind timestamp status; do
    payload=$(valid_payload | jq -c "del(.$field)")
    err=$(FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" 2>&1) || rc=$?
    rc=${rc:-0}
    [ "$rc" -ne 0 ] || fail "append accepted payload missing $field"
    assert_contains "$err" "$field" "refusal for missing $field did not name the field"
    rc=0
  done

  for bad in finished-maybe legacy-unclassified; do
    payload=$(valid_payload | jq -c --arg s "$bad" '.status=$s')
    err=$(FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" 2>&1) || rc=$?
    rc=${rc:-0}
    [ "$rc" -ne 0 ] || fail "append accepted invalid status $bad"
    assert_contains "$err" "$bad" "refusal for status $bad did not name the value"
    rc=0
  done

  payload=$(valid_payload | jq -c '.repository="foo"')
  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "append accepted a repository without owner/name shape"
  assert_contains "$err" "repository" \
    "refusal for malformed repository did not name the field"
  rc=0

  payload=$(valid_payload)
  FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" >/dev/null \
    || fail "valid append failed"
  [ -f "$ledger" ] || fail "ledger was not created"
  [ "$(wc -l < "$ledger" | tr -d ' ')" -eq 1 ] || fail "ledger should have exactly one line"
  jq -e . "$ledger" >/dev/null || fail "appended line is not valid JSON"

  pass "review outcome append validates required fields and status enum"
}

test_append_metrics_honesty_and_append_only() {
  local home err ledger payload rc
  local before_size before_hash after_hash prefix_hash before_lines after_lines
  home=$(make_home append-metrics)
  ledger="$home/data/review-outcomes.jsonl"

  payload=$(envelope_payload)
  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "append accepted payload with no metrics and no metricsUnavailable"
  case "$err" in
    *candidates*|*kills*|*survivors*|*agreement*|*metricsUnavailable*) ;;
    *) fail "refusal for empty metrics did not name a missing metrics field: $err" ;;
  esac
  rc=0

  payload=$(envelope_payload | jq -c '. + {candidates: 4, kills: 1, agreement: "unanimous"}')
  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "append accepted payload missing survivors"
  assert_contains "$err" "survivors" "refusal for partial metrics did not name survivors"
  rc=0

  payload=$(envelope_payload | jq -c '. + {metricsUnavailable: true}')
  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "append accepted metricsUnavailable=true with no reason"
  assert_contains "$err" "metricsUnavailableReason" \
    "refusal for missing unavailable reason did not name metricsUnavailableReason"
  rc=0

  payload=$(envelope_payload | jq -c '. + {
    metricsUnavailable: true,
    metricsUnavailableReason: "guessed-counts"
  }')
  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "append accepted invented metricsUnavailableReason"
  assert_contains "$err" "guessed-counts" \
    "refusal for invented unavailable reason did not name the value"
  rc=0

  payload=$(envelope_payload | jq -c '. + {
    metricsUnavailable: true,
    metricsUnavailableReason: "legacy-shape"
  }')
  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "append accepted read-only metricsUnavailableReason legacy-shape"
  assert_contains "$err" "legacy-shape" \
    "refusal for legacy-shape did not name the value"
  rc=0

  payload=$(valid_payload | jq -c '. + {metricsUnavailable: "false"}')
  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "append accepted a non-boolean metricsUnavailable"
  assert_contains "$err" "metricsUnavailable" \
    "refusal for a non-boolean metricsUnavailable did not name the field"
  rc=0

  payload=$(valid_payload | jq -c '. + {metricsUnavailableReason: "no-round"}')
  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "append accepted a reason with available metrics"
  assert_contains "$err" "metricsUnavailableReason" \
    "refusal for a mixed available reason did not name the field"
  rc=0

  payload=$(valid_payload)
  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload"$'\n'"$payload" 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "append accepted multiple JSON documents"
  assert_contains "$err" "malformed JSON payload" \
    "refusal for multiple JSON documents did not name malformed JSON"
  [ ! -e "$ledger" ] || fail "multi-document refusal created a ledger file"
  rc=0

  payload=$(valid_payload | jq -c '.timestamp="2026-99-99T99:99:99Z"')
  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "append accepted an impossible timestamp"
  assert_contains "$err" "timestamp" \
    "refusal for an impossible timestamp did not name timestamp"
  [ ! -e "$ledger" ] || fail "invalid timestamp refusal created a ledger file"
  rc=0

  payload=$(envelope_payload | jq -c '. + {
    metricsUnavailable: true,
    metricsUnavailableReason: "no-round",
    candidates: 0
  }')
  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "append accepted typed metrics with metricsUnavailable=true"
  assert_contains "$err" "candidates" \
    "refusal for mixed unavailable metrics did not name candidates"
  rc=0

  [ ! -e "$ledger" ] || fail "refused appends created a ledger file"

  payload=$(valid_payload)
  FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" >/dev/null \
    || fail "valid metrics append failed"
  [ "$(wc -l < "$ledger" | tr -d ' ')" -eq 1 ] || fail "ledger should have exactly one line after first accepted append"
  jq -e . "$ledger" >/dev/null || fail "first appended line is not valid JSON"

  before_size=$(file_size "$ledger")
  before_hash=$(file_sha256 "$ledger")
  before_lines=$(wc -l < "$ledger" | tr -d ' ')

  payload=$(unavailable_payload)
  FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" >/dev/null \
    || fail "valid metricsUnavailable append failed"
  after_lines=$(wc -l < "$ledger" | tr -d ' ')
  [ "$after_lines" -eq $((before_lines + 1)) ] \
    || fail "accepted append did not raise line count by exactly one"
  prefix_hash=$(head -c "$before_size" "$ledger" | if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi)
  [ "$prefix_hash" = "$before_hash" ] \
    || fail "accepted append mutated bytes before the previous end"

  before_size=$(file_size "$ledger")
  before_hash=$(file_sha256 "$ledger")
  payload=$(envelope_payload)
  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "second empty-metrics append was accepted"
  [ "$(file_size "$ledger")" = "$before_size" ] \
    || fail "refused append changed ledger size"
  after_hash=$(file_sha256 "$ledger")
  [ "$after_hash" = "$before_hash" ] \
    || fail "refused append changed ledger sha256"

  pass "review outcome append enforces metrics honesty and append-only bytes"
}

test_append_repairs_missing_final_newline() {
  local home ledger payload out
  home=$(make_home append-missing-newline)
  ledger="$home/data/review-outcomes.jsonl"
  payload=$(valid_payload)
  printf '%s' "$payload" > "$ledger"
  chmod 600 "$ledger"

  FM_HOME="$home" "$REVIEW_OUTCOME" append --payload "$payload" >/dev/null \
    || fail "append failed to repair a missing final newline"
  [ "$(wc -l < "$ledger" | tr -d ' ')" -eq 2 ] \
    || fail "append did not preserve two JSONL records"
  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet --format json) \
    || fail "sheet failed after append repaired a missing final newline"
  printf '%s' "$out" | jq -e 'length == 2' >/dev/null \
    || fail "append concatenated records at an unterminated EOF: $out"

  pass "review outcome append repairs missing final newlines"
}

test_sheet_normalizes_historic_shapes() {
  local home out fixture_lines sheet_len
  home=$(make_home sheet-historic)
  install_historic_ledger "$home"

  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet --format json) \
    || fail "sheet --format json failed"

  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null \
    || fail "sheet did not emit a JSON array: $out"

  fixture_lines=$(grep -c . "$HISTORIC_FIXTURE" || true)
  sheet_len=$(printf '%s' "$out" | jq 'length')
  [ "$sheet_len" = "$fixture_lines" ] \
    || fail "sheet dropped or invented rows: fixture=$fixture_lines sheet=$sheet_len"

  printf '%s' "$out" | jq -e '
    (.[0] | keys) as $cols
    | ($cols == [
        "agreement",
        "candidates",
        "kills",
        "legacyStatus",
        "metricsUnavailable",
        "metricsUnavailableReason",
        "status",
        "survivors"
      ])
    and all(keys == $cols)
  ' >/dev/null || fail "sheet rows do not share the canonical column set: $out"

  printf '%s' "$out" | jq -e '
    .[0].status == "posted"
    and .[0].legacyStatus == "posted-zero-findings"
    and .[0].kills == 2
    and .[0].survivors == 3
    and .[0].metricsUnavailable != true
  ' >/dev/null || fail "v1 row did not normalize to posted from compiler counts: $(printf '%s' "$out" | jq '.[0]')"

  printf '%s' "$out" | jq -e '
    .[1].status == "abandoned-unposted"
    and .[1].legacyStatus == "abandoned-unposted"
    and .[1].kills == 3
  ' >/dev/null || fail "v3 row did not take kills from rulings.kills length: $(printf '%s' "$out" | jq '.[1]')"

  printf '%s' "$out" | jq -e '
    .[2].status == "legacy-unclassified"
    and .[2].legacyStatus == null
    and .[2].metricsUnavailable == true
    and .[2].metricsUnavailableReason == "legacy-shape"
    and .[2].candidates == null
    and .[2].kills == null
    and .[2].survivors == null
    and .[2].agreement == null
  ' >/dev/null || fail "persona row was dropped, zeroed, or classified: $(printf '%s' "$out" | jq '.[2]')"

  printf '%s' "$out" | jq -e '
    .[3].status == "legacy-unclassified"
    and .[3].legacyStatus == "noted-deferred"
    and .[3].metricsUnavailable == true
    and .[3].metricsUnavailableReason == "legacy-shape"
    and .[3].candidates == null
    and .[3].kills == null
    and .[3].survivors == null
    and .[3].agreement == null
  ' >/dev/null || fail "unmatched row was dropped, zeroed, or classified: $(printf '%s' "$out" | jq '.[3]')"

  pass "review outcome sheet normalizes historic shapes into one canonical view"
}

test_sheet_uses_schema_specific_status_tables() {
  local home out
  home=$(make_home sheet-status-tables)
  printf '%s\n' \
    '{"schemaVersion":1,"result":"completed","completedAt":"2026-07-01T00:00:00Z"}' \
    '{"schemaVersion":3,"status":"posted-zero-findings","timestamp":"2026-07-02T00:00:00Z"}' \
    '{"status":"posted","timestamp":"2026-07-03T00:00:00Z"}' \
    > "$home/data/review-outcomes.jsonl"
  chmod 600 "$home/data/review-outcomes.jsonl"

  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet --format json) \
    || fail "sheet schema-specific status probe failed"
  printf '%s' "$out" | jq -e '
    length == 3
    and all(.[]; .status == "legacy-unclassified" and .metricsUnavailable == true)
    and .[0].legacyStatus == "completed"
    and .[1].legacyStatus == "posted-zero-findings"
    and .[2].legacyStatus == "posted"
  ' >/dev/null || fail "sheet reused a status spelling across legacy schemas: $out"

  pass "review outcome sheet dispatches status normalization by schema"
}

test_sheet_handles_nonstring_legacy_keys() {
  local home out rc
  home=$(make_home sheet-nonstring-legacy-key)
  printf '%s\n' \
    '{"schemaVersion":1,"result":42,"completedAt":"2026-07-03T00:00:00Z"}' \
    > "$home/data/review-outcomes.jsonl"
  chmod 600 "$home/data/review-outcomes.jsonl"

  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet --format json) || rc=$?
  rc=${rc:-0}
  [ "$rc" -eq 0 ] || fail "sheet rejected a non-string legacy key: $out"
  printf '%s' "$out" | jq -e '
    .[0].status == "legacy-unclassified"
    and .[0].metricsUnavailable == true
  ' >/dev/null || fail "unbounded sheet mishandled a non-string legacy key: $out"

  rc=0
  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet \
    --from 2026-07-03 --to 2026-07-03 --format json) || rc=$?
  rc=${rc:-0}
  [ "$rc" -eq 0 ] || fail "bounded sheet rejected a non-string legacy key: $out"
  printf '%s' "$out" | jq -e '.summary.rounds == 1 and .summary.legacyUnclassified == 1' \
    >/dev/null || fail "bounded sheet mishandled a non-string legacy key: $out"

  pass "review outcome sheet handles non-string legacy keys"
}

test_sheet_handles_malformed_legacy_carriers() {
  local home out
  home=$(make_home sheet-malformed-legacy-carrier)
  printf '%s\n' \
    '{"schemaVersion":1,"result":"posted-zero-findings","compiler":"invalid","completedAt":"2026-07-01T00:00:00Z"}' \
    '{"schemaVersion":3,"status":"posted","timestamp":"2026-07-02T00:00:00Z","rulings":"invalid"}' \
    '{"schemaVersion":3,"status":"posted","timestamp":"2026-07-03T00:00:00Z","rulings":{"kills":["kill-a"],"survivors":["survivor-a"]},"accounting":"invalid"}' \
    > "$home/data/review-outcomes.jsonl"
  chmod 600 "$home/data/review-outcomes.jsonl"

  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet --format json) \
    || fail "sheet malformed legacy carrier probe failed"
  printf '%s' "$out" | jq -e '
    .[0].metricsUnavailable == true
    and .[1].metricsUnavailable == true
    and .[2].metricsUnavailable == false
    and .[2].kills == 1
    and .[2].survivors == 1
    and .[2].candidates == null
  ' >/dev/null || fail "malformed legacy carriers aborted or corrupted normalization: $out"

  pass "review outcome sheet guards malformed legacy carriers"
}

test_sheet_marks_partial_v3_metrics_unavailable() {
  local home out
  home=$(make_home sheet-partial-v3)
  printf '%s\n' \
    '{"schemaVersion":3,"status":"posted","timestamp":"2026-07-04T00:00:00Z","rulings":{"kills":["kill-a"]}}' \
    > "$home/data/review-outcomes.jsonl"
  chmod 600 "$home/data/review-outcomes.jsonl"

  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet --format json) \
    || fail "sheet partial v3 metrics probe failed"
  printf '%s' "$out" | jq -e '
    .[0].metricsUnavailable == true
    and .[0].metricsUnavailableReason == "legacy-shape"
    and .[0].kills == null
    and .[0].survivors == null
  ' >/dev/null || fail "partial v3 metrics were treated as complete: $out"

  pass "review outcome sheet rejects incomplete v3 metric carriers"
}

test_sheet_marks_partial_v4_metrics_unavailable() {
  local home out
  home=$(make_home sheet-partial-v4)
  printf '%s\n' \
    '{"schemaVersion":4,"taskId":"partial-v4","repository":"pedromuller-del/firstmate","pr":302,"roundKind":"initial","timestamp":"2026-07-04T00:00:00Z","status":"posted","candidates":2,"kills":2,"agreement":"unanimous"}' \
    > "$home/data/review-outcomes.jsonl"
  chmod 600 "$home/data/review-outcomes.jsonl"

  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet --format json) \
    || fail "sheet partial v4 metrics probe failed"
  printf '%s' "$out" | jq -e '
    .[0].metricsUnavailable == true
    and .[0].metricsUnavailableReason == "legacy-shape"
    and .[0].kills == null
    and .[0].survivors == null
  ' >/dev/null || fail "partial v4 metrics were treated as complete: $out"

  pass "review outcome sheet rejects incomplete v4 metric carriers"
}

test_sheet_invalid_v4_status_hides_metrics() {
  local home out
  home=$(make_home sheet-invalid-v4-status)
  printf '%s\n' \
    '{"schemaVersion":4,"taskId":"invalid-v4-status","repository":"pedromuller-del/firstmate","pr":303,"roundKind":"initial","timestamp":"2026-07-04T00:00:00Z","status":"finished-maybe","candidates":2,"kills":2,"survivors":1,"agreement":"unanimous"}' \
    > "$home/data/review-outcomes.jsonl"
  chmod 600 "$home/data/review-outcomes.jsonl"

  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet --format json) \
    || fail "sheet invalid v4 status probe failed"
  printf '%s' "$out" | jq -e '
    .[0].status == "legacy-unclassified"
    and .[0].metricsUnavailable == true
    and .[0].kills == null
    and .[0].survivors == null
  ' >/dev/null || fail "invalid v4 status retained typed metrics: $out"

  pass "review outcome sheet hides metrics for invalid v4 statuses"
}

test_sheet_nulls_v3_string_agreement() {
  local home out
  home=$(make_home sheet-v3-agreement)
  printf '%s\n' \
    '{"schemaVersion":3,"status":"posted","timestamp":"2026-07-05T00:00:00Z","rulings":{"kills":["kill-a"],"survivors":["survivor-a"]},"agreement":"unanimous"}' \
    > "$home/data/review-outcomes.jsonl"
  chmod 600 "$home/data/review-outcomes.jsonl"

  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet --format json) \
    || fail "sheet v3 agreement probe failed"
  printf '%s' "$out" | jq -e '
    .[0].metricsUnavailable == false
    and .[0].agreement == null
    and .[0].kills == 1
    and .[0].survivors == 1
  ' >/dev/null || fail "v3 string agreement was copied into the canonical row: $out"

  pass "review outcome sheet nulls v3 string agreement carriers"
}

test_sheet_window_summary() {
  local home out summary rows_len fixture_lines
  home=$(make_home sheet-window)
  install_window_ledger "$home"

  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet --from 2026-07-10 --to 2026-07-20 --format json) \
    || fail "sheet --from --to --format json failed"

  printf '%s' "$out" | jq -e 'type == "object" and (.rows | type) == "array" and (.summary | type) == "object"' >/dev/null \
    || fail "windowed sheet did not emit {rows, summary}: $out"

  fixture_lines=$(grep -c . "$WINDOW_FIXTURE" || true)
  rows_len=$(printf '%s' "$out" | jq '.rows | length')
  [ "$rows_len" = "$fixture_lines" ] \
    || fail "windowed sheet dropped or invented rows: fixture=$fixture_lines rows=$rows_len"

  summary=$(printf '%s' "$out" | jq -c '.summary')
  printf '%s' "$out" | jq -e '
    .summary == {
      rounds: 4,
      posted: 2,
      abandonedUnposted: 1,
      blocked: 0,
      superseded: 0,
      noRound: 1,
      legacyUnclassified: 0,
      undated: 1,
      metricsUnavailable: 2,
      kills: 4,
      survivors: 4,
      killRate: 0.5
    }
  ' >/dev/null || fail "windowed summary mismatched hand-computed truth: $summary"

  local err rc
  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet --from "not-a-date" --to 2026-07-20 --format json 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "sheet accepted a malformed --from bound"

  pass "review outcome sheet window summary reports rounds, status counts, undated, metrics and killRate"
}

test_sheet_window_rejects_partial_and_invalid_bounds() {
  local home err rc
  home=$(make_home sheet-bound-validation)

  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet --from 2026-07-10 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "sheet accepted a one-sided --from window"
  assert_contains "$err" "supplied together" \
    "one-sided --from refusal did not require both bounds"
  rc=0

  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet --to 2026-07-10 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "sheet accepted a one-sided --to window"
  assert_contains "$err" "supplied together" \
    "one-sided --to refusal did not require both bounds"
  rc=0

  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet --from 2026-02-29 --to 2026-03-01 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "sheet accepted an impossible calendar date"
  assert_contains "$err" "UTC RFC3339" \
    "refusal for an impossible bound did not name the bound format"

  rc=0
  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet \
    --from 1969-12-31T23:59:59.9Z \
    --to 1970-01-01T00:00:00Z 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -eq 0 ] || fail "sheet rejected a valid pre-epoch window: $err"

  rc=0
  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet \
    --from 1969-12-31T23:59:58.9999Z \
    --to 1969-12-31T23:59:59.0001Z 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -eq 0 ] || fail "sheet rejected a valid high-precision pre-epoch window: $err"

  pass "review outcome sheet requires complete windows and real calendar bounds"
}

test_sheet_window_normalizes_fractional_instants() {
  local home out
  home=$(make_home sheet-fractional-window)
  printf '%s\n' \
    '{"schemaVersion":4,"taskId":"fractional","repository":"pedromuller-del/firstmate","pr":301,"roundKind":"initial","timestamp":"2026-07-10T00:00:00.10Z","status":"posted","candidates":1,"kills":1,"survivors":0,"agreement":"unanimous"}' \
    > "$home/data/review-outcomes.jsonl"
  chmod 600 "$home/data/review-outcomes.jsonl"

  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet \
    --from 2026-07-10T00:00:00.1Z --to 2026-07-10T00:00:00.1Z --format json) \
    || fail "sheet fractional window failed"
  printf '%s' "$out" | jq -e '.summary.rounds == 1 and .summary.kills == 1' >/dev/null \
    || fail "fractionally equivalent bounds excluded the row: $out"

  pass "review outcome sheet compares fractional timestamps by instant"
}

test_sheet_window_preserves_fraction_precision() {
  local home out
  home=$(make_home sheet-fraction-precision)
  printf '%s\n' \
    '{"schemaVersion":3,"status":"posted","timestamp":"2026-07-10T00:00:00.123456789012345679Z","rulings":{"kills":["kill-a"],"survivors":["survivor-a"]}}' \
    > "$home/data/review-outcomes.jsonl"
  chmod 600 "$home/data/review-outcomes.jsonl"

  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet \
    --from 2026-07-10T00:00:00.123456789012345678Z \
    --to 2026-07-10T00:00:00.123456789012345678Z --format json) \
    || fail "sheet high-precision fractional window failed"
  printf '%s' "$out" | jq -e '.summary.rounds == 0' >/dev/null \
    || fail "high-precision fraction was rounded into the window: $out"

  pass "review outcome sheet preserves high-precision fractional ordering"
}

test_sheet_window_normalizes_offset_bare_dates() {
  local home out
  home=$(make_home sheet-offset-bare-date)
  printf '%s\n' \
    '{"schemaVersion":3,"status":"posted","timestamp":"2026-07-09T23:00:00-02:00","rulings":{"kills":["kill-a"],"survivors":["survivor-a"]}}' \
    > "$home/data/review-outcomes.jsonl"
  chmod 600 "$home/data/review-outcomes.jsonl"

  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet \
    --from 2026-07-10 --to 2026-07-10 --format json) \
    || fail "sheet offset bare-date window failed"
  printf '%s' "$out" | jq -e '.summary.rounds == 1' >/dev/null \
    || fail "offset timestamp was excluded from its UTC bare-date window: $out"

  pass "review outcome sheet normalizes offset timestamps for bare-date windows"
}

test_sheet_window_crosses_month_boundary() {
  local home out
  home=$(make_home sheet-month-boundary)
  printf '%s\n' \
    '{"schemaVersion":3,"status":"posted","timestamp":"2026-07-31T23:00:00Z","rulings":{"kills":["kill-a"],"survivors":["survivor-a"]}}' \
    > "$home/data/review-outcomes.jsonl"
  chmod 600 "$home/data/review-outcomes.jsonl"

  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet \
    --from 2026-07-31 --to 2026-08-01 --format json) \
    || fail "sheet cross-month window failed"
  printf '%s' "$out" | jq -e '.summary.rounds == 1' >/dev/null \
    || fail "cross-month window excluded a valid row: $out"

  pass "review outcome sheet handles cross-month windows"
}

test_sheet_rejects_nonobject_ledger_rows() {
  local home out rc
  home=$(make_home sheet-nonobject-row)
  printf '%s\n' 'null' > "$home/data/review-outcomes.jsonl"
  chmod 600 "$home/data/review-outcomes.jsonl"

  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet --format json 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "sheet accepted a non-object unbounded row"
  assert_contains "$out" "malformed JSON" \
    "unbounded non-object row refusal did not fail closed"

  rc=0
  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet \
    --from 2026-01-01 --to 2026-12-31 --format json 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "sheet accepted a non-object bounded row"
  assert_contains "$out" "malformed JSON" \
    "bounded non-object row refusal did not fail closed"

  pass "review outcome sheet rejects non-object ledger rows"
}

test_sheet_rejects_invalid_legacy_instants() {
  local home out rc
  home=$(make_home sheet-invalid-legacy-instant)
  printf '%s\n' \
    '{"schemaVersion":3,"status":"posted","timestamp":"2026-02-30T00:00:00Z","rulings":{"kills":["kill-a"],"survivors":["survivor-a"]}}' \
    > "$home/data/review-outcomes.jsonl"
  chmod 600 "$home/data/review-outcomes.jsonl"

  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet \
    --from 2026-02-01T00:00:00Z --to 2026-03-01T00:00:00Z --format json 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "sheet accepted an invalid legacy instant"
  assert_contains "$out" "malformed JSON" \
    "invalid legacy instant refusal did not fail closed"

  pass "review outcome sheet rejects invalid legacy instants"
}

test_sheet_accepts_offset_legacy_timestamps() {
  local home out
  home=$(make_home sheet-offset-timestamp)
  printf '%s\n' \
    '{"schemaVersion":3,"status":"posted","timestamp":"2026-08-29T02:00:00+02:00","rulings":{"kills":["kill-a"],"survivors":["survivor-a"]}}' \
    > "$home/data/review-outcomes.jsonl"
  chmod 600 "$home/data/review-outcomes.jsonl"

  out=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet \
    --from 2026-08-29T00:00:00Z \
    --to 2026-08-29T00:00:00Z --format json) \
    || fail "sheet offset timestamp probe failed"
  printf '%s' "$out" | jq -e '
    .summary.rounds == 1
    and .summary.kills == 1
    and .summary.survivors == 1
  ' >/dev/null || fail "offset timestamp was not normalized to its UTC instant: $out"

  pass "review outcome sheet normalizes offset-bearing legacy timestamps"
}

test_sheet_refuses_data_symlink_and_unknown_command() {
  local home outside err rc
  home="$TMP_ROOT/sheet-data-symlink/home"
  outside="$TMP_ROOT/sheet-data-symlink/outside"
  mkdir -p "$home" "$outside"
  ln -s "$outside" "$home/data"

  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "sheet followed a symlinked data directory"
  assert_contains "$err" "data directory is a symlink" \
    "data-directory symlink refusal did not name the data directory"
  rc=0

  home="$TMP_ROOT/sheet-data-file/home"
  mkdir -p "$home"
  printf '%s\n' 'not a directory' > "$home/data"
  err=$(FM_HOME="$home" "$REVIEW_OUTCOME" sheet 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "sheet accepted a regular file as the data directory"
  assert_contains "$err" "data directory is not a directory" \
    "regular data-path refusal did not name the directory requirement"
  rc=0

  err=$(FM_HOME="$TMP_ROOT/unknown-command-home" "$REVIEW_OUTCOME" unknown 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "unknown top-level command exited successfully"
  assert_contains "$err" "unknown command" \
    "unknown top-level command refusal did not name the command"

  pass "review outcome sheet refuses data symlinks and unknown commands"
}

test_append_refuses_bad_arguments_and_offset_timestamps
test_append_validates_required_fields_and_status
test_append_metrics_honesty_and_append_only
test_append_repairs_missing_final_newline
test_sheet_normalizes_historic_shapes
test_sheet_uses_schema_specific_status_tables
test_sheet_handles_nonstring_legacy_keys
test_sheet_handles_malformed_legacy_carriers
test_sheet_marks_partial_v3_metrics_unavailable
test_sheet_marks_partial_v4_metrics_unavailable
test_sheet_invalid_v4_status_hides_metrics
test_sheet_nulls_v3_string_agreement
test_sheet_window_summary
test_sheet_window_rejects_partial_and_invalid_bounds
test_sheet_window_normalizes_fractional_instants
test_sheet_window_preserves_fraction_precision
test_sheet_window_normalizes_offset_bare_dates
test_sheet_window_crosses_month_boundary
test_sheet_rejects_nonobject_ledger_rows
test_sheet_rejects_invalid_legacy_instants
test_sheet_accepts_offset_legacy_timestamps
test_sheet_refuses_data_symlink_and_unknown_command
printf 'All fm-review-outcome tests passed.\n'
