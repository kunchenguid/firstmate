#!/usr/bin/env bash
# Public-interface tests for bin/fm-autostart-proposal.sh.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-autostart-proposal)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$HOME_DIR/data" "$FAKEBIN"
: > "$HOME_DIR/data/backlog.md"

cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TASKS_CALL_LOG"
cat "$READY_FIXTURE"
SH
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
[ "$*" = '--full --json' ] || exit 9
cat "$QUOTA_FIXTURE"
SH
chmod +x "$FAKEBIN/tasks-axi" "$FAKEBIN/quota-axi"

export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT"
export PATH="$FAKEBIN:$PATH"
export TASKS_CALL_LOG="$TMP_ROOT/tasks-calls"
export READY_FIXTURE="$TMP_ROOT/ready.toon"
export QUOTA_FIXTURE="$TMP_ROOT/quota.json"

cat > "$READY_FIXTURE" <<'TOON'
count: 1
ready[1]{id,state,kind,repo,title}:
  ready-ship,queued,ship,firstmate,Ready work
ready_public_followups: 0 delivery-ready obligations
TOON

quota_fixture() {
  local remaining=$1 priority=$2 runway=$3
  cat > "$QUOTA_FIXTURE" <<JSON
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [{
    "provider": "codex",
    "state": {"status": "fresh"},
    "windows": [],
    "quotaSemantics": {
      "status": "known",
      "effectiveAvailability": [{
        "scope": "all_models",
        "status": "known",
        "effectivePercentRemaining": $remaining,
        "runway": {"status": "$runway"},
        "selection": {"status": "known", "spendPriority": $priority}
      }]
    }
  }]
}
JSON
}

quota_fixture 60 2 through_reset
out=$("$ROOT/bin/fm-autostart-proposal.sh") || fail "proposal command failed: $out"
assert_contains "$out" 'ready-ship' 'queued, unblocked, unheld ready item was not named'
assert_contains "$out" 'codex (all_models)' 'quota headroom harness was not named'
assert_contains "$out" 'advisory' 'proposal was not identified as advisory'
assert_grep 'ready' "$TASKS_CALL_LOG" 'candidate scan did not use tasks-axi ready'
pass 'a queued, unblocked, unheld item is proposed with a harness that has quota headroom'

quota_fixture 60 -0.4627 through_reset
out=$("$ROOT/bin/fm-autostart-proposal.sh") || fail "negative-priority proposal command failed: $out"
assert_contains "$out" 'ready-ship' 'negative spendPriority suppressed a headroom proposal'
assert_contains "$out" 'codex (all_models)' 'negative spendPriority suppressed the headroom harness'
pass 'spendPriority sign does not suppress known through-reset headroom'

# The fixture is the canonical `ready` response; held and blocked rows are
# excluded by tasks-axi before this script receives the candidate set.
assert_no_grep '--include-held' "$TASKS_CALL_LOG" 'candidate scan explicitly included held work'
pass 'held and blocked queued items are excluded by the canonical ready listing'

quota_fixture 0 0 exhausted_now
out=$("$ROOT/bin/fm-autostart-proposal.sh") || fail "exhausted quota command failed: $out"
[ -z "$out" ] || fail "proposal surfaced with exhausted quota: $out"
pass 'exhausted quota suppresses the ready-work proposal'

quota_fixture 60 -2 projected_exhaustion
out=$("$ROOT/bin/fm-autostart-proposal.sh") || fail "tight-window quota command failed: $out"
[ -z "$out" ] || fail "proposal surfaced with projected quota exhaustion: $out"
pass 'a projected-exhaustion runway suppresses the ready-work proposal despite remaining quota'

quota_fixture 60 2 through_reset
cat > "$READY_FIXTURE" <<'TOON'
count: 0
ready[0]{id,state,kind,repo,title}:
ready_public_followups: 0 delivery-ready obligations
TOON
out=$("$ROOT/bin/fm-autostart-proposal.sh") || fail "empty ready command failed: $out"
[ -z "$out" ] || fail "proposal surfaced without a ready candidate: $out"
pass 'quota headroom alone does not surface a proposal without ready work'
