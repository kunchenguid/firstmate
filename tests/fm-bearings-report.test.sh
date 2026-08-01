#!/usr/bin/env bash
# Behavior tests for create-exclusive Bearings report versioning.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-bearings-report)
WRITER="$ROOT/bin/fm-bearings-report.sh"

test_prior_report_is_versioned_before_replacement() {
  local home draft target archived receipt old_digest old_bytes
  home="$TMP_ROOT/home"
  mkdir -p "$home/data"
  target="$home/data/status-report-2026-07-31.md"
  draft="$home/draft.md"
  printf '# Prior Bearings\nEvidence cited elsewhere.\n' > "$target"
  printf '# Current Bearings\nFresh fleet state.\n' > "$draft"
  old_digest=$(shasum -a 256 "$target" | awk '{print $1}')
  old_bytes=$(wc -c < "$target" | tr -d '[:space:]')

  FM_HOME="$home" FM_BEARINGS_REPORT_DATE=2026-07-31 "$WRITER" "$draft" >/dev/null \
    || fail "Bearings report writer refused a valid replacement"
  cmp -s "$target" "$draft" || fail "dated report did not receive the fresh draft"

  archived=$(find "$home/data/status-report-versions" -type f ! -name '*.receipt' | head -1)
  receipt=$(find "$home/data/status-report-versions" -type f -name '*.receipt' | head -1)
  assert_present "$archived" "prior Bearings report was destroyed without a version"
  assert_present "$receipt" "prior Bearings report has no custody receipt"
  printf '# Prior Bearings\nEvidence cited elsewhere.\n' > "$home/expected-prior"
  cmp -s "$archived" "$home/expected-prior" || fail "versioned report bytes changed"
  assert_grep "sha256=$old_digest" "$receipt" "receipt digest does not bind the prior report"
  assert_grep "bytes=$old_bytes" "$receipt" "receipt byte count does not bind the prior report"
  assert_grep 'source_ref=' "$receipt" "receipt omitted the source ref"
  assert_grep 'custody_class=bearings-prior-snapshot' "$receipt" "receipt omitted custody class"
  assert_grep 'timestamp_utc=' "$receipt" "receipt omitted its pre-transition timestamp"
  assert_grep "archived_path=$archived" "$receipt" "receipt does not link the preserved bytes"
  pass "Bearings versions a prior same-day report with a pre-transition custody receipt"
}

test_repeated_replacements_never_overwrite_versions() {
  local home draft count
  home="$TMP_ROOT/repeat"
  mkdir -p "$home/data"
  draft="$home/draft.md"
  printf 'version zero\n' > "$home/data/status-report-2026-07-31.md"
  printf 'version one\n' > "$draft"
  FM_HOME="$home" FM_BEARINGS_REPORT_DATE=2026-07-31 "$WRITER" "$draft" >/dev/null \
    || fail "first replacement failed"
  printf 'version two\n' > "$draft"
  FM_HOME="$home" FM_BEARINGS_REPORT_DATE=2026-07-31 "$WRITER" "$draft" >/dev/null \
    || fail "second replacement failed"
  count=$(find "$home/data/status-report-versions" -type f ! -name '*.receipt' | wc -l | tr -d '[:space:]')
  [ "$count" -eq 2 ] || fail "expected two create-exclusive versions, got $count"
  pass "repeated Bearings replacements create unique versions"
}

test_prior_report_is_versioned_before_replacement
test_repeated_replacements_never_overwrite_versions
