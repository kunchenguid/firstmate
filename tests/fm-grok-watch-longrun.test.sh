#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LONGRUN="$ROOT/bin/fm-watch-grok-longrun.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-watch-grok-longrun.XXXXXX")
trap 'rm -rf "$LAB"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

mkdir -p "$LAB/repo/bin" "$LAB/home/state"
cp "$LONGRUN" "$LAB/repo/bin/fm-watch-grok-longrun.sh"
cat > "$LAB/repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
count_file="$STATE/cycle-count"
count=$(cat "$count_file" 2>/dev/null || printf '0')
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
if [ "$count" -le 5 ]; then
  printf 'stale: fixture:w1:p%s (paused 20000s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)\n' "$count"
  exit 0
fi
printf 'signal: %s/actionable.status\n' "$STATE"
SH
chmod +x "$LAB/repo/bin/fm-watch-arm.sh" "$LAB/repo/bin/fm-watch-grok-longrun.sh"

FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state" \
  "$LAB/repo/bin/fm-watch-grok-longrun.sh" > "$LAB/output" 2>&1 &
pid=$!
i=0
while [ "$i" -lt 100 ]; do
  [ "$(cat "$LAB/home/state/cycle-count" 2>/dev/null || true)" = 6 ] && break
  sleep 0.02
  i=$((i + 1))
done
wait "$pid" || fail "long-runner failed while handing over the actionable cycle"
[ "$(cat "$LAB/home/state/cycle-count")" = 6 ] \
  || fail "fixture did not reproduce five routine closes before the actionable cycle"
[ "$(grep -c '^signal:' "$LAB/output")" -eq 1 ] \
  || fail "actionable wake did not surface exactly once"
! grep -q 'declared pause' "$LAB/output" \
  || fail "a routine declared-wait cycle escaped the long-runner"
[ "$(grep -c '^watcher: started' "$LAB/output")" -eq 1 ] \
  || fail "quiet cycle diagnostics leaked into tracked-task completion output"

printf 'ok - five routine watcher closes stayed inside one tracked task and one actionable wake surfaced\n'
