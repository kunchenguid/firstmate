#!/usr/bin/env bash
# tests/ak47-census.test.sh - the producer census.
#
# A census that only counts is not a census. These tests pin the two things that
# make it one: every class of growth is attributed to a named producer, and the
# check mode compares against a baseline it never moves.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CENSUS="$ROOT/ak47/census.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

SANDBOX=
cleanup() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/ak47-census-tests.XXXXXX")

export AK47_STATE=$SANDBOX/state
export AK47_CACHE=$SANDBOX/cache
export AK47_CONFIG=$SANDBOX/config
export AK47_TMP_ROOT=$SANDBOX/tmp
export FM_HOME=$SANDBOX/fmhome
mkdir -p "$AK47_STATE" "$AK47_CACHE" "$AK47_CONFIG" "$AK47_TMP_ROOT" "$FM_HOME/state"

reset_tree() {
  rm -rf "$AK47_TMP_ROOT" "$AK47_STATE"
  mkdir -p "$AK47_TMP_ROOT" "$AK47_STATE"
}

# --- the shipped table ----------------------------------------------------------

test_every_shipped_producer_row_is_well_formed() {
  local id match pattern owner fix guard n=0
  while IFS='|' read -r id match pattern owner fix guard; do
    case "$id" in ''|'#'*) continue ;; esac
    n=$((n + 1))
    [ -n "${pattern:-}" ] || fail "producer row $id has no pattern"
    [ -n "${owner:-}" ] || fail "producer row $id has no owner"
    [ -n "${fix:-}" ] || fail "producer row $id has no source fix"
    [ -n "${guard:-}" ] || fail "producer row $id has no guard"
    case "$match" in prefix|regex) : ;; *) fail "producer row $id has match '$match'; expected prefix or regex" ;; esac
  done <"$ROOT/ak47/census-producers.conf"
  [ "$n" -ge 10 ] || fail "the shipped producer table has only $n rows"
  pass "every shipped producer row names a pattern, an owner, a fix and a guard"
}

# --- classification -------------------------------------------------------------

test_classifies_every_named_producer_prefix() {
  reset_tree
  # One entry per producer id, so a row that stops matching shows up as a zero
  # rather than as a silently smaller total.
  local pair id name
  for pair in uvn:uvn-abc123 uvn-lens:uvn-lens-1 wc:wc-1 irc:irc-2 \
              merge-outcome:merge-outcome-x rmtc:rmtc-1 \
              rmtc-artifacts:rmtc-artifacts-2 restore-test:restore-test-3 \
              csv:csv-4 puppeteer:puppeteer_dev_chrome_profile-zz \
              twin-req:twin-req-9; do
    id=${pair%%:*}; name=${pair#*:}
    mkdir -p "$AK47_TMP_ROOT/$name"
  done
  local out
  out=$("$CENSUS" 2>/dev/null) || fail "census failed"
  for pair in uvn:uvn-abc123 uvn-lens:uvn-lens-1 wc:wc-1 irc:irc-2 \
              merge-outcome:merge-outcome-x rmtc:rmtc-1 \
              rmtc-artifacts:rmtc-artifacts-2 restore-test:restore-test-3 \
              csv:csv-4 puppeteer:puppeteer_dev_chrome_profile-zz \
              twin-req:twin-req-9; do
    id=${pair%%:*}
    # The census prints one row per producer id with its count; a row that is
    # absent means the pattern stopped matching.
    printf '%s\n' "$out" | grep -Eq "^${id}[[:space:]]+[1-9]" \
      || fail "census did not attribute any entry to producer $id"
  done
  pass "the census attributes every named producer prefix"
}

test_classifies_python_mkdtemp_including_underscores() {
  reset_tree
  # Python's tempfile name alphabet is [a-z0-9_], so 91,115 of the 464,620
  # measured names contained an underscore. A pattern that only allows
  # alphanumerics silently drops a fifth of the population.
  mkdir -p "$AK47_TMP_ROOT/tmpa003ltt_" "$AK47_TMP_ROOT/tmpb004muu_"
  local out
  out=$("$CENSUS" 2>/dev/null) || fail "census failed"
  case "$out" in
    *py-mkdtemp*) : ;;
    *) fail "census did not attribute an underscore-bearing Python temp dir" ;;
  esac
  pass "the census attributes Python temp dirs whose names contain an underscore"
}

test_classifies_shell_mktemp() {
  reset_tree
  mkdir -p "$AK47_TMP_ROOT/tmp.abcdefghij"
  local out
  out=$("$CENSUS" 2>/dev/null) || fail "census failed"
  case "$out" in
    *sh-mktemp*) : ;;
    *) fail "census did not attribute a shell mktemp -d directory" ;;
  esac
  pass "the census attributes shell mktemp -d directories"
}

test_reports_an_unattributed_remainder() {
  reset_tree
  mkdir -p "$AK47_TMP_ROOT/something-nobody-has-explained"
  local out
  out=$("$CENSUS" 2>/dev/null) || fail "census failed"
  case "$out" in
    *unattributed*) : ;;
    *) fail "census did not report an unattributed remainder" ;;
  esac
  pass "the census reports an unattributed remainder rather than hiding it"
}

# --- the check mode -------------------------------------------------------------

test_check_refuses_without_a_baseline() {
  reset_tree
  mkdir -p "$AK47_TMP_ROOT/uvn-abc123"
  if "$CENSUS" --check >/dev/null 2>&1; then
    fail "census --check passed with no baseline to compare against"
  fi
  pass "census --check refuses when there is no baseline"
}

test_check_passes_against_an_unchanged_tree() {
  reset_tree
  mkdir -p "$AK47_TMP_ROOT/uvn-abc123"
  "$CENSUS" --write-baseline >/dev/null 2>&1 || fail "could not write a baseline"
  "$CENSUS" --check >/dev/null 2>&1 \
    || fail "census --check failed against an unchanged tree"
  pass "census --check passes against an unchanged tree"
}

test_check_fails_when_a_producer_grows() {
  reset_tree
  mkdir -p "$AK47_TMP_ROOT/uvn-abc123"
  "$CENSUS" --write-baseline >/dev/null 2>&1 || fail "could not write a baseline"
  mkdir -p "$AK47_TMP_ROOT/uvn-def456" "$AK47_TMP_ROOT/uvn-ghi789"
  if "$CENSUS" --check >/dev/null 2>&1; then
    fail "census --check passed after a producer grew"
  fi
  pass "census --check fails when a producer grows"
}

test_check_never_moves_its_own_baseline() {
  reset_tree
  mkdir -p "$AK47_TMP_ROOT/uvn-abc123"
  "$CENSUS" --write-baseline >/dev/null 2>&1 || fail "could not write a baseline"
  local before after
  before=$(cat "$AK47_STATE/census.baseline")
  mkdir -p "$AK47_TMP_ROOT/uvn-def456"
  "$CENSUS" --check >/dev/null 2>&1 || true
  after=$(cat "$AK47_STATE/census.baseline")
  [ "$before" = "$after" ] \
    || fail "census --check rewrote its own baseline; a check that moves its reference can only see one interval"
  pass "census --check never moves its own baseline"
}

test_every_shipped_producer_row_is_well_formed
test_classifies_every_named_producer_prefix
test_classifies_python_mkdtemp_including_underscores
test_classifies_shell_mktemp
test_reports_an_unattributed_remainder
test_check_refuses_without_a_baseline
test_check_passes_against_an_unchanged_tree
test_check_fails_when_a_producer_grows
test_check_never_moves_its_own_baseline
