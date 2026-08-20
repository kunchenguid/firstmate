#!/usr/bin/env bash
# tests/fm-watch-footer-drift-live-e2e.test.sh - opt-in real-harness guard for
# stale-pane hashing when an idle TUI redraws its footer without worker activity.
#
# A fake capture can prove that the watcher normalizes a deliberately changing
# footer, but only installed harnesses reveal which footer rows their current
# releases redraw. This guard launches each installed verified harness in a
# private tmux server, observes two captures at least 65 seconds apart, and
# proves that changed raw captures retain the exact same hash through
# bin/fm-watch.sh's production normalization path.
set -u

if [ "${FM_WATCH_FOOTER_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_WATCH_FOOTER_DRIFT=1 to run the installed-harness footer drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH="$ROOT/bin/fm-watch.sh"
WAIT_SECS=${FM_WATCH_FOOTER_DRIFT_WAIT_SECS:-70}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  [ -z "${REAL_TMUX:-}" ] || cleanup
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

case "$WAIT_SECS" in
  ''|*[!0-9]*) fail "FM_WATCH_FOOTER_DRIFT_WAIT_SECS must be a whole number of seconds" ;;
esac
[ "$WAIT_SECS" -ge 65 ] || fail "FM_WATCH_FOOTER_DRIFT_WAIT_SECS must be at least 65 seconds to observe minute countdowns"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-watch-footer-drift-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-watch-footer-drift.XXXXXX")
SESSION=footer-drift
WATCH_PID=

cleanup() {
  [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" >/dev/null 2>&1 || true
  [ -n "${WATCH_PID:-}" ] && wait "$WATCH_PID" >/dev/null 2>&1 || true
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB/shim" "$LAB/state" "$LAB/worktree"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
cat > "$LAB/shim/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'state: working · source: run-step · live footer guard'
SH
chmod +x "$LAB/shim/tmux" "$LAB/shim/fm-crew-state.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$LAB/worktree" \
  || fail "could not start private tmux server"

resolve_harness_binary() {  # <harness>
  local harness=$1 candidate
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ "$harness" = kimi ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    printf '%s\n' "$HOME/.kimi-code/bin/kimi"
    return 0
  fi
  return 1
}

stat_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1"; else stat -c '%s:%Y' "$1"; fi
}

normalized_hash() {
  FM_STATE_OVERRIDE="$LAB/state" bash -c '. "$1"; hash_pane' _ "$WATCH"
}

CHECKED=0
INSTALLED=0
CHANGING=0
ABSENT=
for harness in claude codex opencode pi pi-signed grok kimi; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    ABSENT="$ABSENT $harness"
    note "skip: $harness is not installed on this machine"
    continue
  fi
  INSTALLED=$((INSTALLED + 1))
  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version=unknown
  task="footer-$harness"
  window="$SESSION:fm-$task"
  status="$LAB/state/$task.status"
  printf 'window=%s\nkind=ship\nharness=%s\nbackend=tmux\n' "$window" "$harness" > "$LAB/state/$task.meta"
  printf 'working: live footer observation\n' > "$status"
  printf '%s' "$(stat_sig "$status")" > "$LAB/state/.seen-${task}_status"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "fm-$task" -c "$LAB/worktree" -- "$bin_path" \
    || fail "$harness $version: could not launch private probe pane"
  CHECKED=$((CHECKED + 1))
done

[ "$INSTALLED" -gt 0 ] || fail "no verified harness is installed here, so this run proved nothing"
sleep 15
for harness in claude codex opencode pi pi-signed grok kimi; do
  resolve_harness_binary "$harness" >/dev/null 2>&1 || continue
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:fm-footer-$harness" -S -40 > "$LAB/$harness.before" \
    || fail "$harness: could not capture the private probe pane"
  [ -s "$LAB/$harness.before" ] || note "$harness: private probe pane has not rendered output yet"
  normalized_hash < "$LAB/$harness.before" > "$LAB/$harness.before.hash" \
    || fail "$harness: could not hash the first private probe capture"
done

PATH="$LAB/shim:$PATH" FM_STATE_OVERRIDE="$LAB/state" FM_CREW_STATE_BIN="$LAB/shim/fm-crew-state.sh" \
  FM_POLL=1 FM_STALE_ESCALATE_SECS=999999 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$WATCH" > "$LAB/watch.out" &
WATCH_PID=$!
sleep "$WAIT_SECS"

for harness in claude codex opencode pi pi-signed grok kimi; do
  resolve_harness_binary "$harness" >/dev/null 2>&1 || continue
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:fm-footer-$harness" -S -40 > "$LAB/$harness.after" \
    || fail "$harness: could not capture the second private probe pane"
  normalized_hash < "$LAB/$harness.after" > "$LAB/$harness.after.hash" \
    || fail "$harness: could not hash the second private probe capture"
  version=$("$(resolve_harness_binary "$harness")" --version 2>/dev/null | head -1 | tr -d '\r') || version=unknown
  if [ ! -s "$LAB/$harness.before" ] || [ ! -s "$LAB/$harness.after" ]; then
    note "$harness $version: no rendered footer was available for a drift comparison"
  elif cmp -s "$LAB/$harness.before" "$LAB/$harness.after"; then
    note "$harness $version: no autonomous footer change observed in ${WAIT_SECS}s"
  else
    CHANGING=$((CHANGING + 1))
    cmp -s "$LAB/$harness.before.hash" "$LAB/$harness.after.hash" \
      || fail "FOOTER DRIFT: $harness $version changed raw pane output and changed its normalized stale hash"
    pass "$harness $version: changed raw footer content retained its exact normalized stale hash"
  fi
done

[ "$CHECKED" -gt 0 ] || fail "no installed harness probe completed"
[ "$CHANGING" -gt 0 ] || fail "no installed harness rendered an autonomous footer change in ${WAIT_SECS}s, so this run cannot prove footer normalization"
note "checked $CHECKED installed harness(es); raw footer drift observed on $CHANGING"
[ -z "$ABSENT" ] || note "unverified on this machine (not installed):$ABSENT"

cleanup
trap - EXIT
