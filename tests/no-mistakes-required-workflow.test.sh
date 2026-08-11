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
  # GH_TOKEN is pinned empty so the live-body fallback stays offline and the
  # unsigned verdict is immediate and deterministic in local replay.
  PR_NUMBER=418 PR_AUTHOR=synthetic-fork-contributor PR_BODY="$body" GH_TOKEN='' \
    bash -c "$script" >/dev/null 2>&1
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

# The no-mistakes pipeline pushes the branch (synchronize) moments before it
# writes the signed body (edited), so a synchronize payload can snapshot the
# pre-signature body. The check must re-read the live body before failing so
# that stale snapshot cannot permanently redden a head whose PR body is signed.
test_stale_snapshot_rechecks_live_body() {
  local tmp fakebin script count_file signed_body
  tmp=$(fm_test_tmproot nm-required)
  fakebin=$(fm_fakebin "$tmp")
  count_file="$tmp/gh-calls"
  signed_body="Synthetic live body"$'\n'"$MARKER"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$STUB_GH_COUNT_FILE" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" > "$STUB_GH_COUNT_FILE"
if [ "$count" -ge "$STUB_GH_SIGNED_AT" ]; then
  printf '%s' "$STUB_GH_SIGNED_BODY"
else
  printf '%s' 'still unsigned live body'
fi
SH
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh" "$fakebin/sleep"
  script=$(extract_signature_script)

  rm -f "$count_file"
  PATH="$fakebin:$PATH" GH_TOKEN=synthetic-token GITHUB_REPOSITORY=synthetic/firstmate \
    STUB_GH_COUNT_FILE="$count_file" STUB_GH_SIGNED_AT=3 STUB_GH_SIGNED_BODY="$signed_body" \
    PR_NUMBER=418 PR_AUTHOR=synthetic-fork-contributor PR_BODY='stale unsigned snapshot' \
    bash -c "$script" >/dev/null 2>&1 || fail "stale snapshot must pass once the live body is signed"
  [ "$(cat "$count_file")" = 3 ] || fail "check must poll the live body until the signature lands"

  rm -f "$count_file"
  if PATH="$fakebin:$PATH" GH_TOKEN=synthetic-token GITHUB_REPOSITORY=synthetic/firstmate \
    STUB_GH_COUNT_FILE="$count_file" STUB_GH_SIGNED_AT=99 STUB_GH_SIGNED_BODY="$signed_body" \
    PR_NUMBER=418 PR_AUTHOR=synthetic-fork-contributor PR_BODY='stale unsigned snapshot' \
    bash -c "$script" >/dev/null 2>&1; then
    fail "unsigned live body must still fail"
  fi
  [ "$(cat "$count_file")" = 6 ] || fail "unsigned live body must exhaust the bounded poll window"
  pass "stale payload snapshots re-read the live PR body within a bounded window"
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
  assert_grep '  pull-requests: read' "$WORKFLOW" "live body re-check needs pull-requests read"
  assert_no_grep 'pull-requests: write' "$WORKFLOW" "workflow must not gain pull-requests write permission"
  assert_grep 'GH_TOKEN: ${{ github.token }}' "$WORKFLOW" "live body re-check must use the workflow token, not a secret"
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
test_stale_snapshot_rechecks_live_body
test_event_identity_contract
test_run_names_are_ordered_and_unique
test_security_and_signature_contract_is_preserved
