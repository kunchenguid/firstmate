#!/usr/bin/env bash
# tests/fm-agent-memory-scope-live.test.sh - live guard for the per-worker
# memory scope (bin/fm-agent-memory-lib.sh). Runs a trivial `sleep` through
# the real fm_agent_memory_compose_launch wrapper against the REAL systemd
# --user manager and reads back its live MemoryCurrent, proving the compose
# + systemd-run + `systemctl --user show` round trip actually works end to
# end - a stub can only confirm the assumption already written into it.
# Self-skips (no explicit opt-in needed) when this host has no working
# `systemd --user` session; no model tokens are spent either way.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-agent-memory-lib.sh"

# This guard exists to exercise the real wrapper, so it must see real
# detection rather than tests/lib.sh's global test-suite exemption
# (FM_AGENT_MEMORY_DISABLE=1).
unset FM_AGENT_MEMORY_DISABLE

if ! fm_agent_memory_systemd_user_available; then
  echo "skip: systemd --user is not available on this host (fm_agent_memory_systemd_user_available reported false)"
  exit 0
fi

UNIT="fm-live-guard-$$.scope"
CLEANED=0
cleanup() {
  [ "$CLEANED" -eq 1 ] && return
  CLEANED=1
  systemctl --user stop "$UNIT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

LAUNCH=$(fm_agent_memory_compose_launch "sleep 3" "$UNIT" 256M 512M 128M)
eval "$LAUNCH" &
RUN_PID=$!

# Wait for the scope to become active (registered with the manager and still
# running the sleep), never for it to finish - ActiveState only reports a
# terminal value once the unit stops, so polling THAT would race the sleep
# instead of catching it mid-flight. 3s of sleep gives ample headroom.
SETTLE=0
ACTIVE_STATE=
while [ "$SETTLE" -lt 30 ]; do
  ACTIVE_STATE=$(systemctl --user show -p ActiveState --value "$UNIT" 2>/dev/null) || ACTIVE_STATE=
  [ "$ACTIVE_STATE" = active ] && break
  sleep 0.1
  SETTLE=$((SETTLE + 1))
done
[ "$ACTIVE_STATE" = active ] || fail "scope $UNIT never reached ActiveState=active within 3s (last seen: '$ACTIVE_STATE')"

CURRENT=$(fm_agent_memory_current "$UNIT") || CURRENT=
wait "$RUN_PID" 2>/dev/null || true

case "$CURRENT" in
  ''|*[!0-9]*) fail "fm_agent_memory_current returned no usable MemoryCurrent for $UNIT while the wrapped sleep was running (got: '$CURRENT')" ;;
esac
pass "the real systemd-run --user --scope wrapper launches a trivial sleep and fm_agent_memory_current reads back its live MemoryCurrent ($CURRENT bytes, unit $UNIT)"

echo "# fm-agent-memory-scope-live.test.sh: all assertions passed"
