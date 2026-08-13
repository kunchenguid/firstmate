#!/usr/bin/env bash
# Behavior tests for the neutral domain-review consumer extension point.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUBJECT="$ROOT/bin/fm-domain-review-consume.sh"
TMP_ROOT=$(fm_test_tmproot fm-domain-review-consume)

make_repo() {
  local repo=$1
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  printf '%s\n' fixture > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm fixture
}

write_consumer() {
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FAKE_CONSUMER_LOG:?}"
case "${FAKE_CONSUMER_MUTATE:-none}" in
  commit)
    printf '%s\n' consumer-moved > "${FAKE_CONSUMER_REPO:?}/file.txt"
    git -C "${FAKE_CONSUMER_REPO:?}" add file.txt
    git -C "${FAKE_CONSUMER_REPO:?}" commit -qm consumer-moved
    ;;
  dirty) printf '%s\n' consumer-dirtied >> "${FAKE_CONSUMER_REPO:?}/file.txt" ;;
esac
case "${FAKE_CONSUMER_RESULT:-accepted}" in
  accepted)
    cat <<JSON
{
  "ok": true,
  "schema_version": "${FAKE_SCHEMA:-firstmate-domain-review-consumption.v1}",
  "status": "accepted",
  "repository": "${FAKE_REPOSITORY:-example/product}",
  "receipt_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "product_head_sha": "${FAKE_PRODUCT_HEAD:?}",
  "diff_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "review_mode": "${FAKE_REVIEW_MODE:-provider-full}",
  "quality_label": "${FAKE_QUALITY_LABEL:-full}",
  "review_strategy": "consume-existing-exact-head-domain-review",
  "independent_review_required": false,
  "private_finding": "must not cross the extension boundary"
}
JSON
    exit 0
    ;;
  blocked)
    printf '%s\n' '{"ok":false,"status":"blocked","reason":"review-findings-unresolved"}'
    exit 11
    ;;
  invalidated)
    printf '%s\n' '{"ok":false,"status":"invalidated","reason":"product-head-changed"}'
    exit 12
    ;;
  error)
    printf '%s\n' '{"ok":false,"error":{"code":"CONTRACT_INVALID"}}'
    exit 23
    ;;
esac
SH
  chmod +x "$path"
}

new_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/run"
  dir=$(CDPATH='' cd -- "$dir" && pwd -P)
  make_repo "$dir/product"
  printf '%s\n' opaque-provider-artifact > "$dir/run/handoff.json"
  write_consumer "$dir/consumer"
  : > "$dir/consumer.log"
  printf '%s\n' "$dir"
}

run_case() {
  local dir=$1 expected=${2:-example/product}
  shift 2 || true
  FAKE_CONSUMER_LOG="$dir/consumer.log" \
    FAKE_PRODUCT_HEAD="$(git -C "$dir/product" rev-parse HEAD)" "$@" "$SUBJECT" \
    --consumer "$dir/consumer" \
    --handoff "$dir/run/handoff.json" \
    --repo "$dir/product" \
    --repository "$expected"
}

test_matching_accepted_result_is_consumed() {
  local dir out
  dir=$(new_case accepted)
  out=$(run_case "$dir" example/product env)
  assert_contains "$out" '"schema_version": "firstmate-domain-review-consumption.v1"' \
    "matching result did not preserve the neutral protocol"
  assert_contains "$out" '"status": "accepted"' "matching result was not accepted"
  assert_contains "$(cat "$dir/consumer.log")" \
    "consume $dir/run/handoff.json --repo $dir/product --repository example/product" \
    "extension point did not pass the exact inputs to the external consumer"
  assert_not_contains "$out" "private_finding" \
    "provider-private fields crossed the allowlisted extension boundary"
  pass "matching exact-head result is consumed without forwarding provider-private fields"
}

test_repository_identity_mismatch_is_refused() {
  local dir out rc
  dir=$(new_case repository-mismatch)
  set +e
  out=$(run_case "$dir" other/product env 2>&1)
  rc=$?
  set -e
  expect_code 13 "$rc" "repository mismatch must use the integration-refusal exit"
  assert_contains "$out" 'repository identity "example/product" does not match expected "other/product"' \
    "repository mismatch did not explain both identities"
  pass "matching code cannot consume a result for another repository identity"
}

test_changed_head_is_refused() {
  local dir out rc stale_head
  dir=$(new_case changed-head)
  stale_head=$(git -C "$dir/product" rev-parse HEAD)
  printf '%s\n' changed > "$dir/product/file.txt"
  git -C "$dir/product" add file.txt
  git -C "$dir/product" commit -qm changed
  set +e
  out=$(FAKE_CONSUMER_LOG="$dir/consumer.log" FAKE_PRODUCT_HEAD="$stale_head" "$SUBJECT" \
    --consumer "$dir/consumer" --handoff "$dir/run/handoff.json" \
    --repo "$dir/product" --repository example/product 2>&1)
  rc=$?
  set -e
  expect_code 13 "$rc" "stale accepted head must be refused"
  assert_contains "$out" 'accepted product HEAD does not match the exact product worktree' \
    "stale accepted head refusal was not actionable"
  pass "accepted results are bound to the exact current product HEAD"
}

test_dirty_worktree_is_refused_before_consumer() {
  local dir out rc
  dir=$(new_case dirty)
  printf '%s\n' dirty >> "$dir/product/file.txt"
  set +e
  out=$(run_case "$dir" example/product env 2>&1)
  rc=$?
  set -e
  expect_code 13 "$rc" "dirty worktree must be refused"
  assert_contains "$out" 'product worktree must be clean' "dirty refusal was not actionable"
  [ ! -s "$dir/consumer.log" ] || fail "consumer ran against a dirty product worktree"
  pass "dirty product worktrees stop before provider code runs"
}

test_worktree_moved_by_consumer_is_refused() {
  local mutation message dir out rc
  while IFS='|' read -r mutation message; do
    dir=$(new_case "consumer-$mutation")
    set +e
    out=$(run_case "$dir" example/product env \
      FAKE_CONSUMER_REPO="$dir/product" FAKE_CONSUMER_MUTATE="$mutation" 2>&1)
    rc=$?
    set -e
    expect_code 13 "$rc" "a consumer that $mutation the product worktree must be refused"
    assert_contains "$out" "$message" "post-consumer refusal was not actionable"
    assert_not_contains "$out" '"status": "accepted"' \
      "an unbound worktree still produced an accepted delivery result"
  done <<'ROWS'
commit|product HEAD moved during domain-review consumption
dirty|product worktree must be clean after domain-review consumption
ROWS
  pass "the exact clean head binding is re-checked after the consumer returns"
}

test_incompatible_accepted_version_is_refused() {
  local dir out rc
  dir=$(new_case incompatible-version)
  set +e
  out=$(run_case "$dir" example/product env FAKE_SCHEMA=firstmate-domain-review-consumption.v2 2>&1)
  rc=$?
  set -e
  expect_code 13 "$rc" "unsupported accepted-result version must be refused"
  assert_contains "$out" 'unsupported consumer-result version' \
    "unsupported version refusal was not actionable"
  pass "an unadopted protocol version cannot broaden policy"
}

test_provider_labels_remain_visible_without_core_allowlist() {
  local dir out
  dir=$(new_case provider-labels)
  out=$(run_case "$dir" example/product env \
    FAKE_REVIEW_MODE=specialized-reduced FAKE_QUALITY_LABEL=reduced-provider)
  assert_contains "$out" '"review_mode": "specialized-reduced"' \
    "provider review mode was not preserved"
  assert_contains "$out" '"quality_label": "reduced-provider"' \
    "provider quality label was not preserved"
  pass "provider-owned review labels remain visible without private core semantics"
}

test_nonaccepted_consumer_results_are_preserved() {
  local result expected dir out rc
  while IFS='|' read -r result expected; do
    dir=$(new_case "$result")
    set +e
    out=$(run_case "$dir" example/product env FAKE_CONSUMER_RESULT="$result" 2>&1)
    rc=$?
    set -e
    expect_code "$expected" "$rc" "$result consumer result changed exit status"
    assert_contains "$out" "\"status\":\"$result\"" "$result consumer JSON was not preserved"
  done <<'ROWS'
blocked|11
invalidated|12
ROWS

  dir=$(new_case provider-error)
  set +e
  out=$(run_case "$dir" example/product env FAKE_CONSUMER_RESULT=error 2>&1)
  rc=$?
  set -e
  expect_code 23 "$rc" "consumer contract error changed exit status"
  assert_contains "$out" '"code":"CONTRACT_INVALID"' "consumer error JSON was not preserved"
  pass "blocked, invalidated, and error consumer outcomes remain non-consumable"
}

test_matching_accepted_result_is_consumed
test_repository_identity_mismatch_is_refused
test_changed_head_is_refused
test_dirty_worktree_is_refused_before_consumer
test_worktree_moved_by_consumer_is_refused
test_incompatible_accepted_version_is_refused
test_provider_labels_remain_visible_without_core_allowlist
test_nonaccepted_consumer_results_are_preserved
