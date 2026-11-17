#!/usr/bin/env bash
# Behavior tests for bin/fm-meta-lib.sh, the owner of the task-record key
# vocabulary: a key one of firstmate's own writers records is known, anything
# else is not, and that answer is what lets the merge poll keep authenticating
# a record those writers appended to after its pr= identity.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-meta-lib.sh
. "$ROOT/bin/fm-meta-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-meta-lib)
PR=https://github.com/o/r/pull/1

test_keys_of_every_writer_are_known() {
  local key
  # One key per writer group: launch record, relaunch marker, delivery
  # identity, review record, Relay link, completion attestation, legacy stamp,
  # remote-secondmate route record, Orca cleanup recovery record.
  for key in window endpoint_task_id backend polytoken_credential control_relaunch_tx \
    pr pr_head review review_head x_request x_reply_max_chars decisions_reviewed decision_keys spawn_gen \
    remote_host remote_root remote_backend remote_herdr_session remote_rex_session_id remote_rex_server \
    remote_target cleanup_recovery; do
    fm_meta_key_known "$key" || fail "a firstmate writer records '$key' but the vocabulary does not know it"
  done
  pass "fm-meta-lib: every writer's keys are known"
}

test_foreign_and_malformed_keys_are_refused() {
  local key
  for key in injected '' 'window=' ' window' PR 'pr ' x_ x_other '*' 'window|pr' pr=; do
    ! fm_meta_key_known "$key" || fail "'$key' was accepted as a key firstmate records"
  done
  pass "fm-meta-lib: a key no firstmate writer records is refused"
}

test_the_vocabulary_decides_what_may_follow_pr() {
  local meta="$TMP_ROOT/t.meta"
  fm_write_meta "$meta" window=fm-t "pr=$PR" review=https://review.example.test/r/1 \
    decisions_reviewed=1 control_relaunch_tx=1.20261116T000000Z.2
  fm_pr_metadata_identity_parse "$meta" || fail "keys firstmate records after pr= invalidated the record"
  [ "$FM_PR_META_URL" = "$PR" ] || fail "the PR identity was not read past the trailing keys: '$FM_PR_META_URL'"
  fm_write_meta "$meta" window=fm-t "pr=$PR" review=https://review.example.test/r/1 injected=value
  ! fm_pr_metadata_identity_parse "$meta" || fail "a foreign key after firstmate's own keys was accepted"
  pass "fm-meta-lib: the vocabulary decides what may follow pr="
}

test_keys_of_every_writer_are_known
test_foreign_and_malformed_keys_are_refused
test_the_vocabulary_decides_what_may_follow_pr

echo "# all fm-meta-lib tests passed"
