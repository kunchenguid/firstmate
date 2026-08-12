#!/usr/bin/env bash
# Ordinary task spawns must keep their Treehouse slot leased until teardown.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/bin/fm-worker-isolation-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-lease)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
WORKTREE="$TMP_ROOT/worktree"
LOG="$TMP_ROOT/treehouse.log"
mkdir -p "$WORKTREE"

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TREEHOUSE_LOG"
[ "${1:-}" = get ] && [ "${2:-}" = --lease ] \
  && [ "${3:-}" = --lease-holder ] && [ "${4:-}" = task-a1 ] || exit 1
printf '%s\n' "$FM_TREEHOUSE_WORKTREE"
SH
chmod +x "$FAKEBIN/treehouse"

command=$(fm_worker_treehouse_lease_command task-a1) \
  || fail "could not build a durable Treehouse lease command"
actual=$(PATH="$FAKEBIN:$PATH" FM_TREEHOUSE_LOG="$LOG" \
  FM_TREEHOUSE_WORKTREE="$WORKTREE" bash -c "$command; pwd -P") \
  || fail "durable Treehouse lease command did not execute"
[ "$actual" = "$WORKTREE" ] \
  || fail "durable Treehouse lease command did not enter its returned worktree"
[ "$(cat "$LOG")" = 'get --lease --lease-holder task-a1' ] \
  || fail "ordinary spawn did not request a durable task-bound lease"
pass "ordinary task command durably leases and enters its Treehouse worktree"

echo "# all fm-treehouse-lease tests passed"
