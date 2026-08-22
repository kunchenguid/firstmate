#!/usr/bin/env bash
# Behavior tests for the one-shot Linear reconciliation producer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-linear-reconcile-tests)
HOME_DIR="$TMP_ROOT/home"
FAKE_BIN="$TMP_ROOT/bin"
CALLS="$TMP_ROOT/calls"
RECONCILE="$ROOT/bin/fm-linear-reconcile.sh"
mkdir -p "$HOME_DIR/state" "$FAKE_BIN"
: > "$CALLS"

cat > "$FAKE_BIN/orca-linear-fixture" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_LINEAR_TEST_CALLS"
case $* in
  'linear team list --workspace all --json')
    printf '%s\n' '{"ok":true,"result":{"teams":[{"workspace":{"id":"workspace-a"}},{"workspace":{"id":"workspace-a"}},{"workspace":{"id":"workspace-b"}}]}}'
    ;;
  *'--workspace workspace-a --json')
    if [ "${FM_LINEAR_TEST_MODE:-}" = missing-cursor ]; then
      printf '%s\n' '{"ok":true,"result":{"issues":[],"meta":{"hasMore":true}}}'
      exit 0
    fi
    if [ "${FM_LINEAR_TEST_MODE:-}" = invalid-issue ]; then
      printf '%s\n' '{"ok":true,"result":{"issues":[{"id":null,"updatedAt":"2026-08-22T10:00:00.000Z","state":{"type":"started"}}],"meta":{"hasMore":false}}}'
      exit 0
    fi
    case $* in
      *'--cursor page-two'*)
        printf '%s\n' '{"ok":true,"result":{"issues":[{"id":"22222222-2222-4222-8222-222222222222","updatedAt":"2026-08-22T11:00:00.000Z","state":{"type":"started"},"title":"second page"}],"meta":{"hasMore":false}}}'
        ;;
      *)
        printf '%s\n' '{"ok":true,"result":{"issues":[{"id":"11111111-1111-4111-8111-111111111111","updatedAt":"2026-08-22T10:00:00.000Z","state":{"type":"unstarted"},"title":"untrusted $(touch must-not-run)"},{"id":"99999999-9999-4999-8999-999999999999","updatedAt":"2026-08-22T09:00:00.000Z","state":{"type":"completed"},"title":"terminal"}],"meta":{"hasMore":true,"nextCursor":"page-two"}}}'
        ;;
    esac
    ;;
  *'--workspace workspace-b --json')
    printf '%s\n' '{"ok":true,"result":{"issues":[],"meta":{"hasMore":false}}}'
    ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$FAKE_BIN/orca-linear-fixture"

out=$(FM_HOME="$HOME_DIR" FM_LINEAR_CLI="$FAKE_BIN/orca-linear-fixture" \
  FM_LINEAR_TEST_CALLS="$CALLS" "$RECONCILE") \
  || fail "Linear reconciliation producer failed"
[ "$out" = 'reconciled: workspaces=2 issues=2 consumption=active-supervisor-required' ] \
  || fail "Linear reconciliation reported the wrong scan result: $out"
[ "$(find "$HOME_DIR/state/procevent-inbox" -name 'event-*.result' | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "Linear reconciliation did not durably ingest exactly the active bugs"
[ "$(grep -c -- '--workspace workspace-a --json' "$CALLS")" -eq 2 ] \
  || fail "Linear reconciliation did not follow workspace pagination"
[ "$(grep -c -- '--workspace workspace-b --json' "$CALLS")" -eq 1 ] \
  || fail "Linear reconciliation did not enumerate every connected workspace once"
grep -F -- '--label Bug' "$CALLS" >/dev/null \
  || fail "Linear reconciliation did not authoritatively select Bug-labeled issues"
find "$HOME_DIR/state/procevent-inbox" -name 'event-*.result' -exec grep -l 'terminal' {} + \
  | grep . >/dev/null && fail "Linear reconciliation ingested a terminal bug"
[ ! -e "$TMP_ROOT/must-not-run" ] || fail "Linear issue text was executed"
pass "hourly producer scans every workspace and ingests every active bug revision"

FM_HOME="$HOME_DIR" FM_LINEAR_CLI="$FAKE_BIN/orca-linear-fixture" \
  FM_LINEAR_TEST_CALLS="$CALLS" "$RECONCILE" >/dev/null \
  || fail "repeated Linear reconciliation failed"
[ "$(find "$HOME_DIR/state/procevent-inbox" -name 'event-*.result' | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "repeated Linear reconciliation duplicated unchanged issue revisions"
pass "reconciliation and immediate delivery share durable revision deduplication"

if FM_HOME="$HOME_DIR" FM_LINEAR_CLI="$FAKE_BIN/orca-linear-fixture" \
  FM_LINEAR_TEST_CALLS="$CALLS" FM_LINEAR_TEST_MODE=invalid-issue \
  "$RECONCILE" >/dev/null 2>&1; then
  fail "Linear reconciliation accepted invalid issue metadata"
fi
pass "reconciliation fails closed on invalid issue metadata"

if FM_HOME="$HOME_DIR" FM_LINEAR_CLI="$FAKE_BIN/orca-linear-fixture" \
  FM_LINEAR_TEST_CALLS="$CALLS" FM_LINEAR_TEST_MODE=missing-cursor \
  "$RECONCILE" >/dev/null 2>&1; then
  fail "Linear reconciliation accepted a missing pagination cursor"
fi
pass "reconciliation fails closed on missing pagination cursors"

BLOCKED_HOME="$TMP_ROOT/blocked-home"
mkdir -p "$BLOCKED_HOME/state"
: > "$BLOCKED_HOME/state/procevent-inbox"
if FM_HOME="$BLOCKED_HOME" FM_LINEAR_CLI="$FAKE_BIN/orca-linear-fixture" \
  FM_LINEAR_TEST_CALLS="$CALLS" "$RECONCILE" >/dev/null 2>&1; then
  fail "Linear reconciliation ignored a failed canonical ingress"
fi
pass "reconciliation fails closed when canonical ingress fails"
