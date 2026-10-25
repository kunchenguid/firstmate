#!/usr/bin/env bash
# End to end: install into a throwaway HOME against a fixture home built from a Firstmate checkout's bin/, then drive the
# installed check against real tasks-axi writers. A writer SIGKILLed between its lock open and its token write leaves a
# 0-byte lock; once old the check reclaims it and the next write succeeds. A young 0-byte lock, a lock with a token, and
# a lock a live writer still has open are each left alone. Usage: backlog-lock-reclaim-e2e.sh <firstmate-checkout> [git-ref]
set -euo pipefail
ADDON=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TASKS_JS=$(readlink -f "$(command -v tasks-axi)") || { echo "FAIL: tasks-axi is not installed" >&2; exit 1; }
T=$(mktemp -d)
W=
trap 'kill -9 "$W" 2>/dev/null || true; rm -rf -- "$T"' EXIT
mkdir -p "$T/fm/state" "$T/fm/data" "$T/home"
git -C "$1" archive "${2:-HEAD}" bin | tar -x -C "$T/fm"
printf '# Backlog\n\n## In flight\n## Queued\n- [ ] seed-task - seed (since 2026-10-18)\n## Done\n' > "$T/fm/data/backlog.md"
export TASKS_AXI_FILE="$T/fm/data/backlog.md"
LOCK=$T/fm/data/backlog.md.lock
CHECK=$T/fm/state/backlog-lock-reclaim.check.sh
fail=0
ok() { echo "ok: $*"; }
no() { echo "FAIL: $*"; fail=1; }
inst() { env HOME="$T/home" XDG_DATA_HOME="$T/data" "$ADDON/install.sh" "$@" "$T/fm"; }

# start_frozen_writer <task>: start a real tasks-axi write that freezes between its lock open and its token write, and
# leave it running. Sets W to the PID this test started.
start_frozen_writer() {
  rm -f -- "$T/mark"
  REPRO_MARK="$T/mark" node --import "$ADDON/tests/fixtures/freeze-after-lock-open.mjs" "$TASKS_JS" add "$1" "$1" >/dev/null 2>&1 &
  W=$!
  for _ in $(seq 1 100); do [ -e "$T/mark" ] && return 0; sleep 0.1; done
  no "writer $1 never reached its lock"; exit 1
}
kill_writer() { kill -9 "$W" 2>/dev/null || true; wait "$W" 2>/dev/null || true; W=; }
age_lock() { touch -d '5 minutes ago' -- "$LOCK"; }

inst --dry-run > "$T/dry.out"
[ ! -e "$CHECK" ] && [ ! -e "$T/data/fm-backlog-lock-reclaim/backlog-lock-reclaim.check.sh" ] \
  && ok "dry run writes nothing" || no "dry run wrote files"
inst > "$T/install.out" && inst > "$T/reinstall.out"
grep -q 'registered: state/backlog-lock-reclaim.check.sh' "$T/install.out" && ok "check registered" || no "check not registered"
grep -q 'installed:' "$T/reinstall.out" && ok "reinstall runs" || no "reinstall failed"

# 1. A dead writer's 0-byte lock, still young: left alone.
start_frozen_writer young-writer; kill_writer
[ -f "$LOCK" ] && [ ! -s "$LOCK" ] && ok "dead writer left a 0-byte lock" || no "no 0-byte lock after dead writer"
out=$("$CHECK")
[ -z "$out" ] && [ -f "$LOCK" ] && ok "young 0-byte lock left alone, nothing printed" || no "young lock touched or printed: $out"

# 2. Same lock, now older than the safe age: reclaimed once, logged, one wake line, and the next write succeeds.
age_lock
out=$("$CHECK")
[ ! -e "$LOCK" ] && ok "old 0-byte dead-writer lock reclaimed" || no "old dead-writer lock not reclaimed"
[ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] && printf '%s\n' "$out" | grep -q 'reclaimed' \
  && ok "one wake line printed" || no "wake output: $out"
grep -q " reclaimed $LOCK age=" "$T/fm/state/backlog-lock-reclaim.log" && ok "reclaim logged with path and age" || no "no reclaim log"
tasks-axi add after-reclaim "write after reclaim" >/dev/null && ok "next tasks-axi write succeeds" || no "next write failed after reclaim"
[ -z "$("$CHECK")" ] && ok "nothing to do once reclaimed" || no "check printed again"

# 3. A lock with a token: never touched, however old.
printf '4242:nonce:1:1\n' > "$LOCK"; age_lock
[ -z "$("$CHECK")" ] && [ "$(cat "$LOCK")" = "4242:nonce:1:1" ] && ok "lock with a token left alone" || no "token lock touched"
rm -f -- "$LOCK"

# 4. A 0-byte lock a live writer still has open: left alone while the writer lives, reclaimed once it is dead.
start_frozen_writer held-writer
age_lock
[ -z "$("$CHECK")" ] && [ -f "$LOCK" ] && ok "lock held by a live writer left alone" || no "live-held lock touched"
kill_writer
out=$("$CHECK")
[ ! -e "$LOCK" ] && printf '%s\n' "$out" | grep -q 'reclaimed' && ok "reclaimed after its holder was killed" \
  || no "lock not reclaimed after holder death: $out"

HOME="$T/home" XDG_DATA_HOME="$T/data" "$ADDON/uninstall.sh" "$T/fm" > "$T/uninstall.out" \
  && [ ! -e "$CHECK" ] && [ ! -e "$T/data/fm-backlog-lock-reclaim/backlog-lock-reclaim.check.sh" ] \
  && ok "uninstall retires the check and its copy" || no "uninstall left files: $(cat "$T/uninstall.out")"

[ "$fail" -eq 0 ] && echo "PASS: backlog-lock-reclaim e2e" || echo "FAIL: backlog-lock-reclaim e2e"
exit "$fail"
