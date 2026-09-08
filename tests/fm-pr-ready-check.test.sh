#!/usr/bin/env bash
# Tests for fm-pr-ready-check.sh, the generic bors-readiness watcher.
#
# gh is faked on PATH so no network call happens; the script's own contract
# (silent on every non-ready and every error path) is the thing under test,
# so a case failing to print is as significant as one printing the wrong
# line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-pr-ready-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-ready-check)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
export PATH="$FAKEBIN:$PATH"

STATE="$TMP_ROOT/state"
mkdir -p "$STATE"

assert_silent() {  # <output> <pass-message>
  if [ -z "$1" ]; then
    pass "$2"
  else
    fail "expected silence, got: $1"
  fi
}

# Writes a gh fake that answers `pr view` with the given state/mergeable/
# labels/head and `pr checks` with the given check states (space-separated,
# e.g. "SUCCESS SUCCESS" or "SUCCESS FAILURE").
write_gh() {  # <state> <mergeable> <labels-json-array> <head> <check-states...>
  local state=$1 mergeable=$2 labels=$3 head=$4
  shift 4
  local checks
  checks=$(printf '{"state":"%s"},' "$@")
  checks="[${checks%,}]"
  cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr view")
    printf '%s\n' '{"state":"$state","mergeable":"$mergeable","headRefOid":"$head","labels":$labels}'
    ;;
  "pr checks")
    printf '%s\n' '$checks'
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$FAKEBIN/gh"
}

test_bare_number_without_repo_is_silent() {
  unset FM_PR_READY_REPO
  write_gh OPEN MERGEABLE '[]' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa SUCCESS
  out=$(FM_PR_READY_STATE="$STATE" "$CHECK" 42 2>&1) || fail "bare PR with no repo must not error"
  assert_silent "$out" "bare PR number with FM_PR_READY_REPO unset prints nothing"
}

test_owner_repo_hash_number_ready() {
  write_gh OPEN MERGEABLE '[]' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa SUCCESS SUCCESS
  out=$(FM_PR_READY_STATE="$STATE/case-ready" "$CHECK" "acme/widgets#7" 2>&1) \
    || fail "ready PR must exit zero"
  case "$out" in
    *"ready: https://github.com/acme/widgets/pull/7"*"aaaaaaaaaa"*) pass "ready PR reported once" ;;
    *) fail "expected ready line, got: $out" ;;
  esac
}

test_not_open_is_silent() {
  write_gh CLOSED MERGEABLE '[]' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa SUCCESS
  out=$(FM_PR_READY_STATE="$STATE/case-closed" "$CHECK" "acme/widgets#8" 2>&1) \
    || fail "closed PR check must not error"
  assert_silent "$out" "non-OPEN PR prints nothing"
}

test_not_mergeable_is_silent() {
  write_gh OPEN CONFLICTING '[]' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa SUCCESS
  out=$(FM_PR_READY_STATE="$STATE/case-conflict" "$CHECK" "acme/widgets#9" 2>&1) \
    || fail "conflicting PR check must not error"
  assert_silent "$out" "non-MERGEABLE PR prints nothing"
}

test_review_blocker_label_is_silent() {
  write_gh OPEN MERGEABLE '[{"name":"review-blocker"}]' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa SUCCESS
  out=$(FM_PR_READY_STATE="$STATE/case-label" "$CHECK" "acme/widgets#10" 2>&1) \
    || fail "labeled PR check must not error"
  assert_silent "$out" "review-blocker label prints nothing"
}

test_failing_check_is_silent() {
  write_gh OPEN MERGEABLE '[]' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa SUCCESS FAILURE
  out=$(FM_PR_READY_STATE="$STATE/case-failcheck" "$CHECK" "acme/widgets#11" 2>&1) \
    || fail "failing-checks PR check must not error"
  assert_silent "$out" "non-SUCCESS check prints nothing"
}

test_same_head_not_reported_twice() {
  local mdir="$STATE/case-dedup"
  write_gh OPEN MERGEABLE '[]' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa SUCCESS
  first=$(FM_PR_READY_STATE="$mdir" "$CHECK" "acme/widgets#12" 2>&1)
  second=$(FM_PR_READY_STATE="$mdir" "$CHECK" "acme/widgets#12" 2>&1)
  if [ -n "$first" ] && [ -z "$second" ]; then
    pass "same head is reported only once"
  else
    fail "expected first run to report and second to be silent; first=[$first] second=[$second]"
  fi
}

test_new_head_reported_again() {
  local mdir="$STATE/case-repush"
  write_gh OPEN MERGEABLE '[]' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa SUCCESS
  first=$(FM_PR_READY_STATE="$mdir" "$CHECK" "acme/widgets#13" 2>&1)
  write_gh OPEN MERGEABLE '[]' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb SUCCESS
  second=$(FM_PR_READY_STATE="$mdir" "$CHECK" "acme/widgets#13" 2>&1)
  case "$first$second" in
    *aaaaaaaaaa*bbbbbbbbbb*) pass "a re-push to a new head is reported again" ;;
    *) fail "expected both heads reported; first=[$first] second=[$second]" ;;
  esac
}

test_bare_number_without_repo_is_silent
test_owner_repo_hash_number_ready
test_not_open_is_silent
test_not_mergeable_is_silent
test_review_blocker_label_is_silent
test_failing_check_is_silent
test_same_head_not_reported_twice
test_new_head_reported_again
