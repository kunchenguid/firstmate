#!/usr/bin/env bash
# Behavior tests for the record-contradiction collect and its machine-readable total.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-record-contradictions-lib)

run_total() {  # <home>
  local home=$1
  FM_HOME="$home" /bin/bash -c \
    '. "$1/fm-backend.sh" && . "$1/fm-pr-lib.sh" && . "$1/fm-record-contradictions-lib.sh" && fm_record_contradictions_total "$2" "$3"' \
    contradictions-total "$ROOT/bin" "$home/data" "$home/state"
}

run_render() {  # <home>
  local home=$1
  FM_HOME="$home" /bin/bash -c \
    '. "$1/fm-backend.sh" && . "$1/fm-pr-lib.sh" && . "$1/fm-record-contradictions-lib.sh" && fm_record_contradictions_render "$2" "$3"' \
    contradictions-render "$ROOT/bin" "$home/data" "$home/state"
}

test_total_is_zero_when_records_agree() {
  local home total
  home="$TMP_ROOT/agree"
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog
## In flight
## Queued
## Done
EOF
  total=$(run_total "$home") || fail "contradiction total failed on an empty home"
  [ "$total" = 0 ] || fail "agreeing records produced a non-zero total: $total"
  pass "the contradiction total is zero when the collect is silent"
}

test_total_counts_every_finding() {
  local home total
  home="$TMP_ROOT/kinds"
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog
## In flight
- [ ] missing-meta - In-flight work without metadata (repo: firstmate) (kind: ship)
## Queued
## Done
EOF
  printf 'kind=ship\n' > "$home/state/ghost-meta.meta"
  total=$(run_total "$home") || fail "contradiction total failed on a two-kind home"
  [ "$total" = 2 ] || fail "two digest findings produced total $total"
  pass "the contradiction total counts every finding the collect records"
}

test_total_outlives_the_display_cap() {
  local home total render id
  home="$TMP_ROOT/over-cap"
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog
## In flight
## Queued
## Done
EOF
  for id in ghost-1 ghost-2 ghost-3 ghost-4 ghost-5; do
    printf 'kind=ship\n' > "$home/state/$id.meta"
  done
  total=$(run_total "$home") || fail "contradiction total failed on an over-cap home"
  render=$(run_render "$home") || fail "contradiction render failed on an over-cap home"
  [ "$total" = 5 ] || fail "five findings of one kind produced total $total"
  assert_contains "$render" "meta-without-backlog (5)" \
    "the rendered kind count did not report every finding"
  assert_contains "$render" "ghost-3(" "the render omitted an entry inside the display cap"
  assert_contains "$render" "+2 more" "the render did not withhold the entries past its cap"
  assert_not_contains "$render" "ghost-4(" "the render named an entry past its display cap"
  assert_not_contains "$render" "ghost-5(" "the render named an entry past its display cap"
  pass "the total counts findings the render's display cap withholds"
}

test_total_is_zero_when_records_agree
test_total_counts_every_finding
test_total_outlives_the_display_cap
