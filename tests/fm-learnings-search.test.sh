#!/usr/bin/env bash
# Behavior tests for bin/fm-learnings-search.sh.
#
# The helper is the start half of the gstack-learnings feature: it calls the
# gstack learnings searcher for task tokens and is fail-soft, printing nothing
# and exiting 0 when the searcher is missing, the token list is empty, the
# search returns no hits, or the searcher errors. All of that refuse-fail
# behavior is what lets bin/fm-brief.sh embed a "Relevant project learnings"
# section without ever failing a scaffold.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-learnings-search)

# write_fake_searcher <dir> <name> <mode: ok|empty|fail>
# A fixture that honors the real gstack-learnings-search contract: --query
# carries one whitespace-joined token list, --limit caps the count. The ok mode
# echoes the query and limit back so tests can assert token derivation and limit
# forwarding through the helper's public interface; empty and fail modes model a
# no-hits searcher and a broken searcher respectively.
write_fake_searcher() {
  local dir=$1 name=$2 mode=$3
  mkdir -p "$dir"
  case "$mode" in
    empty) printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/$name" ;;
    fail) printf '#!/usr/bin/env bash\nexit 3\n' > "$dir/$name" ;;
    *)
      cat > "$dir/$name" <<'SH'
#!/usr/bin/env bash
query=""
limit="5"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --query) query=$2; shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$query" ] || exit 0
printf 'LEARNINGS: %s loaded (2 pitfalls)\n\n## Pitfalls\n- [fixture] (confidence: 9/10, observed, 2026-01-01)\n  insight for: %s\n' "$limit" "$query"
SH
      ;;
  esac
  chmod +x "$dir/$name"
}

test_help_renders_complete_header() {
  local help
  help=$("$ROOT/bin/fm-learnings-search.sh" --help)
  assert_contains "$help" "fm-learnings-search.sh" "help did not name the helper"
  assert_contains "$help" "Fail-soft contract" "help did not own the fail-soft mechanics"
  assert_contains "$help" "--limit <n>" "help did not document the limit flag"
  assert_contains "$help" "never fails a brief scaffold" "help did not own the never-fail guarantee"
  pass "fm-learnings-search.sh: --help renders the complete header"
}

test_missing_searcher_is_silent_noop() {
  local out status
  out=$(FM_GSTACK_SEARCH_BIN="$TMP_ROOT/no-such-searcher" \
    "$ROOT/bin/fm-learnings-search.sh" alpha beta 2>/dev/null); status=$?
  expect_code 0 "$status" "missing searcher must exit 0"
  [ -z "$out" ] || fail "missing searcher printed output: $out"
  pass "fm-learnings-search.sh: a missing searcher prints nothing and exits 0"
}

test_no_tokens_is_silent_noop() {
  local fake out status
  fake="$TMP_ROOT/fakebin/gstack-learnings-search"
  write_fake_searcher "$TMP_ROOT/fakebin" gstack-learnings-search ok
  out=$(FM_GSTACK_SEARCH_BIN="$fake" "$ROOT/bin/fm-learnings-search.sh" 2>/dev/null); status=$?
  expect_code 0 "$status" "empty token list must exit 0"
  [ -z "$out" ] || fail "empty token list printed output: $out"
  pass "fm-learnings-search.sh: an empty token list prints nothing and exits 0"
}

test_hits_are_printed_and_tokens_joined() {
  local fake out
  fake="$TMP_ROOT/fakebin-hits/gstack-learnings-search"
  write_fake_searcher "$TMP_ROOT/fakebin-hits" gstack-learnings-search ok
  out=$(FM_GSTACK_SEARCH_BIN="$fake" "$ROOT/bin/fm-learnings-search.sh" alpha beta)
  expect_code 0 "$?" "searcher present with hits must exit 0"
  assert_contains "$out" "LEARNINGS: 5 loaded (2 pitfalls)" "helper lost the searcher summary"
  assert_contains "$out" "insight for: alpha beta" "helper did not join the tokens into one query"
  pass "fm-learnings-search.sh: prints the searcher hits and joins tokens"
}

test_limit_flag_is_forwarded() {
  local fake out
  fake="$TMP_ROOT/fakebin-limit/gstack-learnings-search"
  write_fake_searcher "$TMP_ROOT/fakebin-limit" gstack-learnings-search ok
  out=$(FM_GSTACK_SEARCH_BIN="$fake" "$ROOT/bin/fm-learnings-search.sh" --limit 2 alpha)
  assert_contains "$out" "LEARNINGS: 2 loaded (2 pitfalls)" "helper did not forward --limit 2"
  pass "fm-learnings-search.sh: the --limit flag is forwarded to the searcher"
}

test_bad_limit_is_refused() {
  local fake out status
  fake="$TMP_ROOT/fakebin-badlimit/gstack-learnings-search"
  write_fake_searcher "$TMP_ROOT/fakebin-badlimit" gstack-learnings-search ok
  out=$(FM_GSTACK_SEARCH_BIN="$fake" "$ROOT/bin/fm-learnings-search.sh" --limit nope alpha 2>&1); status=$?
  expect_code 2 "$status" "a non-numeric --limit must be refused"
  assert_contains "$out" "--limit" "bad --limit refusal did not name the flag"
  pass "fm-learnings-search.sh: a non-numeric --limit is refused loudly"
}

test_empty_results_are_silent() {
  local fake out status
  fake="$TMP_ROOT/fakebin-empty/gstack-learnings-search"
  write_fake_searcher "$TMP_ROOT/fakebin-empty" gstack-learnings-search empty
  out=$(FM_GSTACK_SEARCH_BIN="$fake" "$ROOT/bin/fm-learnings-search.sh" alpha 2>/dev/null); status=$?
  expect_code 0 "$status" "an empty-results searcher must exit 0"
  [ -z "$out" ] || fail "empty-results searcher printed output: $out"
  pass "fm-learnings-search.sh: no hits prints nothing and exits 0"
}

test_searcher_failure_is_silent() {
  local fake out status
  fake="$TMP_ROOT/fakebin-fail/gstack-learnings-search"
  write_fake_searcher "$TMP_ROOT/fakebin-fail" gstack-learnings-search fail
  out=$(FM_GSTACK_SEARCH_BIN="$fake" "$ROOT/bin/fm-learnings-search.sh" alpha 2>/dev/null); status=$?
  expect_code 0 "$status" "a failing searcher must not propagate its exit"
  [ -z "$out" ] || fail "a failing searcher printed output: $out"
  pass "fm-learnings-search.sh: a searcher error prints nothing and exits 0"
}

test_help_renders_complete_header
test_missing_searcher_is_silent_noop
test_no_tokens_is_silent_noop
test_hits_are_printed_and_tokens_joined
test_limit_flag_is_forwarded
test_bad_limit_is_refused
test_empty_results_are_silent
test_searcher_failure_is_silent