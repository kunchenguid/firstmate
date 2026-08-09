#!/usr/bin/env bash
# Public-interface tests for conservative legacy attempt migration.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-attempt-migrate)
STATE="$TMP_ROOT/state"
PROJECT="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$STATE" "$PROJECT" "$FAKEBIN"

export FM_HOME="$ROOT"
export FM_STATE_OVERRIDE="$STATE"
export FM_REFILL_PROJECT="$PROJECT"
# shellcheck source=bin/fm-attempt-lib.sh
. "$ROOT/bin/fm-attempt-lib.sh"

write_legacy_meta() {
  local id=$1 pr=${2:-}
  {
    printf 'window=w-%s\n' "$id"
    printf 'kind=ship\n'
    printf 'mode=direct-PR\n'
    printf 'worktree=%s/wt-%s\n' "$TMP_ROOT" "$id"
    [ -z "$pr" ] || printf 'pr=%s\n' "$pr"
  } > "$STATE/$id.meta"
}

fake_gh() {
  cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
printf '%s\\n' '$1'
SH
  chmod +x "$FAKEBIN/gh"
}

fake_br_status() {
  cat > "$FAKEBIN/br" <<SH
#!/usr/bin/env bash
printf '%s\\n' '[{"id":"fixture","status":"$1"}]'
SH
  chmod +x "$FAKEBIN/br"
}

attempt_for_meta() {
  local id=$1 aid
  aid=$(sed -n 's/^attempt=//p' "$STATE/$id.meta" | head -1)
  [ -n "$aid" ] || fail "meta for $id has no attempt binding"
  printf '%s\n' "$STATE/attempts/$aid.json"
}

assert_no_fabricated_receipts() {
  local file=$1
  jq -e '
    ([.receipts | keys[]?] - ["landing"] | length) == 0
    and ([.receipts.retirement[]? | select(.state == "observed")] | length) == 0
  ' "$file" >/dev/null || fail "migration fabricated lifecycle or retirement receipts: $file"
}

test_merged_pr_without_exact_identity_stays_unknown() {
  local out file
  write_legacy_meta legacy-landed "https://github.com/example/project/pull/1"
  fake_gh '{"state":"MERGED","headRefOid":"abc123","baseRefOid":"old"}'
  fake_br_status open
  out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-attempt-migrate.sh" legacy-landed 2>&1) \
    || fail "landed migration failed: $out"
  assert_contains "$out" "journal evidence only" "inexact merged PR was treated as landing evidence"
  file=$(attempt_for_meta legacy-landed)
  jq -e '(.receipts.landing // [] | length) == 0
    and ([.observations[]? | select(.name == "migration" and .evidence.disposition == "unknown")] | length) == 1' \
    "$file" >/dev/null || fail "inexact merged PR did not remain unknown"
  assert_no_fabricated_receipts "$file"
  pass "migration never promotes a merged PR without exact attempt identity"
}

test_unknown_is_journal_evidence_only() {
  local out file
  write_legacy_meta legacy-unknown
  fake_gh 'not json'
  fake_br_status open
  out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-attempt-migrate.sh" legacy-unknown 2>&1) \
    || fail "unknown migration failed: $out"
  assert_contains "$out" "journal evidence only" "unknown was not reported as journal-only"
  file=$(attempt_for_meta legacy-unknown)
  jq -e '(.receipts.landing // [] | length) == 0
    and ([.observations[]? | select(.name == "migration" and .evidence.disposition == "unknown")] | length) == 1' \
    "$file" >/dev/null || fail "unknown was written as landing evidence or omitted from the journal"
  assert_no_fabricated_receipts "$file"
  pass "unknown disposition is journal evidence only and never landing=unknown"
}

test_closed_bead_without_recovery_proof_stays_unknown() {
  local out file
  write_legacy_meta legacy-preserved
  fake_br_status closed
  out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-attempt-migrate.sh" legacy-preserved 2>&1) \
    || fail "preserved migration failed: $out"
  file=$(attempt_for_meta legacy-preserved)
  jq -e '(.receipts.landing // [] | length) == 0
    and ([.observations[]? | select(.name == "migration" and .evidence.disposition == "unknown")] | length) == 1' \
    "$file" >/dev/null || fail "closed bead was promoted without durable recovery proof"
  assert_no_fabricated_receipts "$file"
  pass "migration preserves a closed bead without fabricating recovery evidence"
}

test_binding_waits_for_initial_reconciliation_and_rerun_recovers_attempt() {
  local out rc aid count file
  write_legacy_meta legacy-resume "https://github.com/example/project/pull/9"
  fake_gh '{"state":"MERGED","headRefOid":"abc123","baseRefOid":"old"}'
  fake_br_status open

  mkdir -p "$STATE/attempts"
  aid=$(fm_attempt_alloc migration legacy-resume "$ROOT") || fail "fixture allocation"
  fm_attempt_lock_acquire "$aid" || fail "fixture lock"
  out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-attempt-migrate.sh" legacy-resume 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "locked initial reconciliation unexpectedly succeeded"
  assert_no_grep 'attempt=' "$STATE/legacy-resume.meta" \
    "meta binding was appended before initial observation reconciliation"
  fm_attempt_lock_release "$aid"

  out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-attempt-migrate.sh" legacy-resume 2>&1) \
    || fail "migration rerun did not recover the existing attempt: $out"
  count=$(find "$STATE/attempts" -maxdepth 1 -name 'legacy-resume-a*.json' | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || fail "rerun allocated $count attempts instead of recovering one"
  [ "$(sed -n 's/^attempt=//p' "$STATE/legacy-resume.meta")" = "$aid" ] \
    || fail "meta did not bind the recovered exact attempt"
  file="$STATE/attempts/$aid.json"
  jq -e '[.observations[]? | select(.name == "forge")] | length == 1' "$file" >/dev/null \
    || fail "initial observation was not published exactly once"
  pass "meta binding waits for reconciliation and rerun recovers the exact task attempt"
}

test_merged_pr_without_exact_identity_stays_unknown
test_unknown_is_journal_evidence_only
test_closed_bead_without_recovery_proof_stays_unknown
test_binding_waits_for_initial_reconciliation_and_rerun_recovers_attempt
