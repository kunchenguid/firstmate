#!/usr/bin/env bash
# Public-interface tests for the read/reconcile legacy migration. The
# migration reuses fm_disposition_live in read/reconcile mode, journals the
# meta's forge observation before classifying, never migrates or retires
# branches, and never retires preserved-unlanded work merely because a bead is
# closed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-attempt-migrate)
STATE="$TMP_ROOT/state"
PROJECT="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$STATE" "$FAKEBIN"

export FM_STATE_OVERRIDE="$STATE"
export FM_REFILL_PROJECT="$PROJECT"
# shellcheck source=bin/fm-attempt-lib.sh
. "$ROOT/bin/fm-attempt-lib.sh"

write_legacy_meta() {  # <id> <pr-url-or-empty>
  local id=$1 pr=${2:-}
  {
    printf 'window=w-%s\n' "$id"
    printf 'kind=ship\n'
    printf 'mode=direct-PR\n'
    printf 'worktree=%s/wt-%s\n' "$TMP_ROOT" "$id"
    [ -z "$pr" ] || printf 'pr=%s\n' "$pr"
  } > "$STATE/$id.meta"
}

fake_gh() {  # <state-json>
  cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
printf '%s\\n' '$1'
SH
  chmod +x "$FAKEBIN/gh"
}

test_landed_legacy_task_is_retired_with_disposition() {
  # meta kind=ship mode=direct-PR with pr=; live disposition=landed (forge proof)
  local out
  write_legacy_meta legacy-1 "https://github.com/kunchenguid/firstmate/pull/1"
  fake_gh '{"state":"MERGED","headRefOid":"abc123","baseRefOid":"old"}'
  out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-attempt-migrate.sh" legacy-1 2>&1)
  assert_contains "$out" "retired disposition=landed" "landed task not retired"
  local f="$STATE/attempts/legacy-1-a1.json"
  [ -f "$f" ] || fail "no envelope written"
  jq -e '.receipts.landing[0].state == "observed" and .receipts.landing[0].evidence.disposition == "landed"' "$f" >/dev/null \
    || fail "landing receipt missing"
  pass "landed legacy task is retired with a landing receipt"
}

test_unknown_work_is_preserved() {
  local out
  write_legacy_meta legacy-2
  fake_gh 'not json'
  out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-attempt-migrate.sh" legacy-2 2>&1)
  assert_contains "$out" "preserved" "unknown work was not preserved"
  local f="$STATE/attempts/legacy-2-a1.json"
  jq -e '.receipts.landing[0].evidence.disposition == "unknown"' "$f" >/dev/null \
    || fail "unknown disposition not recorded"
  pass "unknown or unlanded work is preserved, never discarded"
}

test_closed_unmerged_is_preserved_even_when_bead_closed() {
  local out
  write_legacy_meta legacy-3 "https://github.com/kunchenguid/firstmate/pull/3"
  fake_gh '{"state":"CLOSED","headRefOid":"abc123","baseRefOid":"old"}'
  out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-attempt-migrate.sh" legacy-3 2>&1)
  assert_contains "$out" "preserved" "closed-unmerged work retired on bead closure"
  pass "preserved-unlanded work is never retired merely because a bead is closed"
}

test_landed_legacy_task_is_retired_with_disposition
test_unknown_work_is_preserved
test_closed_unmerged_is_preserved_even_when_bead_closed
