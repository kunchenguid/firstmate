#!/usr/bin/env bash
# fm_meta_insert_before_pr (bin/fm-wake-lib.sh): a key added to a task record
# lands before its pr= identity block, so fm_pr_metadata_identity_parse still
# accepts the record.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-meta-insert-before-pr)
mkdir -p "$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

test_inserts_before_the_pr_block_and_drops_replaced_keys() {
  local meta="$TMP_ROOT/armed.meta" out="$TMP_ROOT/armed.out"
  printf '%s\n' kind=scout mode=scout note=kept \
    pr=https://github.com/example/repo/pull/7 \
    pr_head=f965bd680f44eeed2969d97ea885f3aaac2229d1 x_request=r1 > "$meta"
  fm_meta_insert_before_pr "$meta" "$(printf 'kind=ship\nmode=no-mistakes')" kind mode > "$out" \
    || fail "the rewrite failed"
  [ "$(cat "$out")" = "$(printf '%s\n' note=kept kind=ship mode=no-mistakes \
    pr=https://github.com/example/repo/pull/7 \
    pr_head=f965bd680f44eeed2969d97ea885f3aaac2229d1 x_request=r1)" ] \
    || fail "unexpected rewrite:"$'\n'"$(cat "$out")"
  fm_pr_metadata_identity_parse "$out" || fail "the rewritten record no longer parses"
  [ "$FM_PR_META_URL" = https://github.com/example/repo/pull/7 ] || fail "the watched PR changed"
  pass "fm_meta_insert_before_pr: new keys land before pr= and the record still parses"
}

test_appends_when_no_pr_is_recorded() {
  local meta="$TMP_ROOT/plain.meta"
  printf '%s\n' kind=ship traceparent=old > "$meta"
  [ "$(fm_meta_insert_before_pr "$meta" traceparent=new traceparent)" = "$(printf '%s\n' kind=ship traceparent=new)" ] \
    || fail "a record without pr= should get the new key at the end"
  [ "$(fm_meta_insert_before_pr "$meta" '' traceparent)" = kind=ship ] \
    || fail "an empty insertion should only drop the named keys"
  pass "fm_meta_insert_before_pr: a record without pr= gets the key appended"
}

test_inserts_before_the_pr_block_and_drops_replaced_keys
test_appends_when_no_pr_is_recorded
