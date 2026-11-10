#!/usr/bin/env bash
# tests/ak47-budget.test.sh - the budget table and the board it renders.
#
# The budget is the definition of "humming". If it can load a row with no reason,
# or a row whose direction is misspelled, then the board is describing a box
# nobody agreed on. These tests are about that contract, not about the numbers.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS="$ROOT/ak47/status.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

SANDBOX=
cleanup() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/ak47-budget-tests.XXXXXX")

export AK47_STATE=$SANDBOX/state
export AK47_CACHE=$SANDBOX/cache
export AK47_CONFIG=$SANDBOX/config
export AK47_TMP_ROOT=$SANDBOX/tmp
export FM_HOME=$SANDBOX/fmhome
mkdir -p "$AK47_STATE" "$AK47_CACHE" "$AK47_CONFIG" "$AK47_TMP_ROOT" "$FM_HOME/state"

# --- the shipped table ----------------------------------------------------------

test_the_shipped_budget_loads() {
  AK47_BUDGET=$ROOT/ak47/budget.conf "$STATUS" --print >/dev/null 2>&1 \
    || fail "the shipped budget.conf does not load"
  pass "the shipped budget.conf loads"
}

test_every_shipped_row_carries_a_reason() {
  local key ceil dir unit reason n=0
  while IFS='|' read -r key ceil dir unit reason; do
    case "$key" in ''|'#'*) continue ;; esac
    n=$((n + 1))
    [ -n "${reason:-}" ] || fail "budget row $key has no reason"
    [ "${#reason}" -ge 20 ] || fail "budget row $key's reason is too short to defend: $reason"
  done <"$ROOT/ak47/budget.conf"
  [ "$n" -ge 8 ] || fail "the shipped budget has only $n rows; expected at least 8"
  pass "every shipped budget row carries a reason a reader can defend"
}

test_every_shipped_row_has_a_numeric_ceiling() {
  local key ceil dir unit reason
  while IFS='|' read -r key ceil dir unit reason; do
    case "$key" in ''|'#'*) continue ;; esac
    case "$ceil" in ''|*[!0-9]*) fail "budget row $key has a non-numeric ceiling: $ceil" ;; esac
    case "$dir" in max|min) : ;; *) fail "budget row $key has direction '$dir'; expected max or min" ;; esac
  done <"$ROOT/ak47/budget.conf"
  pass "every shipped budget row has a numeric ceiling and a max/min direction"
}

# --- the refusals ---------------------------------------------------------------

test_refuses_a_row_with_no_reason() {
  local b=$SANDBOX/budget.noreason
  printf 'load15|32|max|load\n' >"$b"
  if AK47_BUDGET=$b "$STATUS" --print >/dev/null 2>&1; then
    fail "status.sh accepted a budget row with no reason"
  fi
  pass "status.sh refuses a budget row with no reason"
}

test_refuses_a_row_with_a_bad_direction() {
  local b=$SANDBOX/budget.baddir
  printf 'load15|32|sideways|load|a reason long enough to be defensible\n' >"$b"
  if AK47_BUDGET=$b "$STATUS" --print >/dev/null 2>&1; then
    fail "status.sh accepted a budget row with direction 'sideways'"
  fi
  pass "status.sh refuses a budget row whose direction is not max or min"
}

test_refuses_a_row_with_a_non_numeric_ceiling() {
  local b=$SANDBOX/budget.badceil
  printf 'load15|lots|max|load|a reason long enough to be defensible\n' >"$b"
  if AK47_BUDGET=$b "$STATUS" --print >/dev/null 2>&1; then
    fail "status.sh accepted a budget row with a non-numeric ceiling"
  fi
  pass "status.sh refuses a budget row with a non-numeric ceiling"
}

# --- the board ------------------------------------------------------------------

test_the_board_puts_the_verdict_first() {
  local out
  out=$(AK47_BUDGET=$ROOT/ak47/budget.conf "$STATUS" --print 2>/dev/null) \
    || fail "status.sh --print failed"
  local first
  first=$(printf '%s\n' "$out" | head -n 1)
  case "$first" in
    *VERDICT*) : ;;
    *) fail "the board's first line is not the verdict: $first" ;;
  esac
  pass "the board puts the verdict on the first line, so it reads in five seconds"
}

test_the_board_names_every_budget_metric() {
  local out key
  out=$(AK47_BUDGET=$ROOT/ak47/budget.conf "$STATUS" --print 2>/dev/null) \
    || fail "status.sh --print failed"
  while IFS='|' read -r key _; do
    case "$key" in ''|'#'*) continue ;; esac
    case "$out" in
      *"$key"*) : ;;
      *) fail "the board does not name the budget metric $key" ;;
    esac
  done <"$ROOT/ak47/budget.conf"
  pass "the board names every metric the budget defines"
}

test_the_board_writes_status_md() {
  rm -f "$AK47_STATE/status.md"
  AK47_BUDGET=$ROOT/ak47/budget.conf "$STATUS" >/dev/null 2>&1 \
    || fail "status.sh failed"
  [ -s "$AK47_STATE/status.md" ] || fail "status.sh did not write status.md"
  pass "status.sh writes the board to status.md"
}

test_no_write_leaves_the_board_alone() {
  printf 'sentinel\n' >"$AK47_STATE/status.md"
  AK47_BUDGET=$ROOT/ak47/budget.conf "$STATUS" --no-write >/dev/null 2>&1 \
    || fail "status.sh --no-write failed"
  local got
  got=$(cat "$AK47_STATE/status.md")
  [ "$got" = sentinel ] || fail "--no-write overwrote status.md"
  pass "--no-write leaves the board on disk alone"
}

test_the_shipped_budget_loads
test_every_shipped_row_carries_a_reason
test_every_shipped_row_has_a_numeric_ceiling
test_refuses_a_row_with_no_reason
test_refuses_a_row_with_a_bad_direction
test_refuses_a_row_with_a_non_numeric_ceiling
test_the_board_puts_the_verdict_first
test_the_board_names_every_budget_metric
test_the_board_writes_status_md
test_no_write_leaves_the_board_alone
