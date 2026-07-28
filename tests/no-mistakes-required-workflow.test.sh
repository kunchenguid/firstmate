#!/usr/bin/env bash
# Contract and synthetic event replay for the PR body compliance workflow.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
MARKER='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'

extract_signature_script() {
  awk '
    /^        run: \|$/ { capture=1; next }
    capture && /^          / { sub(/^          /, ""); print; next }
    capture { exit }
  ' "$WORKFLOW"
}

signature_result() {
  local body=$1 script
  script=$(extract_signature_script)
  PR_NUMBER=418 PR_AUTHOR=synthetic-fork-contributor PR_BODY="$body" bash -c "$script" >/dev/null 2>&1
}

render_group() {
  local action=$1 run_id=$2
  case "$action" in
    opened|edited) printf 'no-mistakes-required-418-%s\n' "$run_id" ;;
    synchronize|reopened) printf 'no-mistakes-required-418-head-change\n' ;;
  esac
}

render_run_name() {
  local action=$1 run_number=$2 run_id=$3
  printf 'PR #418 body compliance - %s - event %s (run %s)\n' "$action" "$run_number" "$run_id"
}

test_signature_sequence_at_fixed_head() {
  signature_result "Synthetic body\n$MARKER" || fail "signed opened event must succeed"
  if signature_result 'Synthetic unsigned edit'; then
    fail "unsigned edited event must fail"
  fi
  signature_result "Synthetic signed edit\n$MARKER" || fail "signed edited event must succeed"
  pass "fixed-head signed opened, unsigned edited, signed edited yields 0/1/0"
}

test_event_identity_contract() {
  local opened edited_one edited_two synchronize reopened
  opened=$(render_group opened 9001)
  edited_one=$(render_group edited 9002)
  edited_two=$(render_group edited 9003)
  synchronize=$(render_group synchronize 9004)
  reopened=$(render_group reopened 9005)
  [ "$opened" != "$edited_one" ] && [ "$opened" != "$edited_two" ] && [ "$edited_one" != "$edited_two" ] || \
    fail "body events must have distinct immutable groups"
  [ "$synchronize" = "$reopened" ] || fail "synchronize and reopened must share head-change"
  case "$opened $edited_one $edited_two" in *head-change*) fail "body event reused head-change" ;; esac

  assert_grep "group: no-mistakes-required-\${{ github.event.pull_request.number }}-\${{ (github.event.action == 'opened' || github.event.action == 'edited') && github.run_id || 'head-change' }}" "$WORKFLOW" \
    "workflow does not implement immutable body-event groups"
  assert_grep 'cancel-in-progress: true' "$WORKFLOW" "workflow lost cancellation for coalesced head changes"
  pass "body event groups are distinct while head changes remain coalesced"
}

test_run_names_are_ordered_and_unique() {
  local first second
  first=$(render_run_name edited 73 9002)
  second=$(render_run_name edited 74 9003)
  [ "$first" = 'PR #418 body compliance - edited - event 73 (run 9002)' ] || fail "first synthetic run name is incomplete"
  [ "$second" = 'PR #418 body compliance - edited - event 74 (run 9003)' ] || fail "second synthetic run name is incomplete"
  [ "$first" != "$second" ] || fail "distinct events must have unique run names"
  assert_grep 'run-name: "PR #${{ github.event.pull_request.number }} body compliance - ${{ github.event.action }} - event ${{ github.run_number }} (run ${{ github.run_id }})"' "$WORKFLOW" \
    "workflow run name does not expose PR, action, monotonic run number, and immutable run ID"
  pass "run names expose monotonic numbers and immutable IDs"
}

test_security_and_signature_contract_is_preserved() {
  assert_grep '  pull_request:' "$WORKFLOW" "workflow must use pull_request"
  assert_no_grep 'pull_request_target' "$WORKFLOW" "workflow must not use pull_request_target"
  assert_grep '  contents: read' "$WORKFLOW" "contents permission must remain read-only"
  assert_no_grep 'contents: write' "$WORKFLOW" "workflow must not gain contents write permission"
  assert_no_grep 'secrets.' "$WORKFLOW" "workflow must not read secrets"
  assert_no_grep 'actions/checkout' "$WORKFLOW" "workflow must not check out fork code"
  assert_grep 'name: PR must be raised via no-mistakes' "$WORKFLOW" "stable required check name changed"
  assert_grep "$MARKER" "$WORKFLOW" "signature marker changed"
  assert_grep "github.event.pull_request.user.login != 'github-actions[bot]'" "$WORKFLOW" "github-actions bot exemption changed"
  assert_grep "github.event.pull_request.user.login != 'dependabot[bot]'" "$WORKFLOW" "dependabot bot exemption changed"
  assert_no_grep 'release-please[bot]' "$WORKFLOW" "Firstmate must not exempt release-please"
  pass "fork, permission, check-name, marker, and bot-exemption contracts are preserved"
}

test_signature_sequence_at_fixed_head
test_event_identity_contract
test_run_names_are_ordered_and_unique
test_security_and_signature_contract_is_preserved
