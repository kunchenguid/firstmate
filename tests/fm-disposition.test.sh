#!/usr/bin/env bash
# Public-interface tests for the centralized live disposition reader and the
# fresh per-effect authority resolver.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-disposition)
STATE="$TMP_ROOT/state"
PROJECT="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$STATE" "$FAKEBIN"

export FM_STATE_OVERRIDE="$STATE"
export FM_REFILL_PROJECT="$PROJECT"
# shellcheck source=bin/fm-attempt-lib.sh
. "$ROOT/bin/fm-attempt-lib.sh"
# shellcheck source=bin/fm-disposition-lib.sh
. "$ROOT/bin/fm-disposition-lib.sh"

fake_gh() {  # <merged|unmerged|unknown>; emits the gh pr view --json shape
  local body
  case "$1" in
    merged) body='{"state":"MERGED","headRefOid":"abc123","baseRefOid":"old"}' ;;
    unmerged) body='{"state":"CLOSED","headRefOid":"abc123","baseRefOid":"old"}' ;;
    unknown) body='not json' ;;
  esac
  cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
printf '%s\\n' '$body'
SH
  chmod +x "$FAKEBIN/gh"
}

journal_forge_observation() {  # <attempt_id> <state>
  fm_attempt_observe "$1" 1 forge "{\"provider\":\"github\",\"pr\":\"https://github.com/kunchenguid/firstmate/pull/1\",\"state\":\"$2\"}"
}

test_live_merge_proof_is_forge_authority_not_bead_closure() {
  local aid out
  aid=$(fm_attempt_alloc pi dos-a holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-a"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main","planned_path":"docs/"}' || fail "freeze"
  journal_forge_observation "$aid" open
  # bead open but PR merged: forge wins for landing truth
  fake_gh merged
  out=$(PATH="$FAKEBIN:$PATH" fm_disposition_live "$aid")
  [ "$out" = landed ] || fail "forge merge proof not honored: $out"
  pass "forge merge proof decides landed; bead closure is tracker truth, not forge truth"
}

test_bead_closed_alone_never_retires_preserved_unlanded() {
  local aid out
  aid=$(fm_attempt_alloc pi dos-b holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-b"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' || fail "freeze"
  journal_forge_observation "$aid" open
  fake_gh unmerged
  out=$(PATH="$FAKEBIN:$PATH" fm_disposition_live "$aid")
  [ "$out" = preserved_unlanded ] || fail "closed-unmerged not preserved: $out"
  pass "a closed-unmerged delivery is preserved_unlanded, never landed"
}

test_unknown_owners_yield_unknown() {
  local aid out
  aid=$(fm_attempt_alloc pi dos-c holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-c"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' || fail "freeze"
  journal_forge_observation "$aid" open
  fake_gh unknown
  out=$(PATH="$FAKEBIN:$PATH" fm_disposition_live "$aid")
  [ "$out" = unknown ] || fail "unknown forge should be unknown: $out"
  pass "missing or unreadable owner evidence yields unknown, never a guess"
}

test_claim_authority_never_authorizes_closure() {
  local out
  out=$(FM_STATE_OVERRIDE="$STATE" fm_authority_for close dos-c 2>&1 || true)
  assert_contains "$out" "missing" "closure without fresh authority accepted"
  pass "claim authorization cannot authorize later bead closure"
}

test_authority_is_per_transition() {
  local out
  printf '%s\n' '{"transition":"claim","authority":"captain:dispatch"}' > "$STATE/authority-current.json"
  out=$(FM_AUTHORITY_FILE="$STATE/authority-current.json" fm_authority_for claim dos-d 2>&1) || fail "claim authority"
  assert_contains "$out" "captain:dispatch" "claim authority not returned"
  out=$(FM_AUTHORITY_FILE="$STATE/authority-current.json" fm_authority_for close dos-d 2>&1 || true)
  assert_contains "$out" "missing" "claim authority leaked to close"
  pass "each irreversible transition requires its own fresh current-session authority"
}

test_live_merge_proof_is_forge_authority_not_bead_closure
test_bead_closed_alone_never_retires_preserved_unlanded
test_unknown_owners_yield_unknown
test_claim_authority_never_authorizes_closure
test_authority_is_per_transition
