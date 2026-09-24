#!/usr/bin/env bash
# Codex idle continuity: a single-shot process-event source stays ownerless
# after reconciliation stops, and the allowing Stop starts a detached
# supervisor that runs it again.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot fm-codex-idle)
HOME_DIR="$TMP_ROOT/primary"
LOG="$TMP_ROOT/hits"
QUEUE="$TMP_ROOT/queue"
SRC="$TMP_ROOT/source.sh"
QUEUE_BIN="$TMP_ROOT/queue.sh"
CONT="$ROOT/bin/fm-codex-idle-continuity.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

mkdir -p "$HOME_DIR/bin" "$HOME_DIR/state"
git init -q "$HOME_DIR"
: > "$HOME_DIR/AGENTS.md"
cat > "$SRC" <<EOF
#!/bin/sh
printf 'x\n' >> '$LOG'
EOF
chmod +x "$SRC"
cat > "$QUEUE_BIN" <<EOF
#!/bin/sh
cat >> '$QUEUE'
EOF
chmod +x "$QUEUE_BIN"
fm_test_track_procevent_home "$HOME_DIR"

hits() { wc -l < "$LOG" | tr -d ' '; }

FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" register lavish shot -- "$SRC" >/dev/null \
  || fail "could not register the single-shot source"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null \
  || fail "initial reconcile did not start the source"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [ -f "$LOG" ] && [ "$(hits)" -ge 1 ] && break
  sleep 0.2
done
[ "$(hits)" -eq 1 ] || fail "registration reconcile did not run the source once"
list=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" list)
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  printf '%s\n' "$list" | grep -F 'none' >/dev/null && break
  sleep 0.3
  list=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" list)
done
printf '%s\n' "$list" | grep -F 'none' >/dev/null || fail "source was still owned after it exited: $list"
sleep 1
[ "$(hits)" -eq 1 ] || fail "source restarted with no supervision cycle"

payload=$(jq -cn '{stop_hook_active:true,session_id:"thread-test"}')
printf '%s' "$payload" | FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" \
  "$CONT" >/dev/null || fail "allowing stop without a Codex owner must still forward"
sleep 1
[ "$(hits)" -eq 1 ] || fail "allowing stop spawned continuity without a Codex owner"
[ ! -d "$HOME_DIR/state/.codex-idle-continuity.lock" ] || fail "lock left behind without a Codex owner"

sleep 60 &
owner=$!
printf '%s' "$payload" | FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" \
  FM_CODEX_IDLE_OWNER_PID="$owner" FM_CODEX_IDLE_QUEUE="$QUEUE_BIN" FM_POLL=1 \
  "$CONT" >/dev/null || fail "allowing stop with a Codex owner failed"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  [ -f "$LOG" ] && [ "$(hits)" -ge 2 ] && [ -s "$QUEUE" ] && break
  sleep 0.5
done
[ "$(hits)" -ge 2 ] || fail "detached supervisor did not reconcile the ownerless source"
[ -s "$QUEUE" ] || fail "actionable close was not handed to the queue command"
kill "$owner" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ ! -d "$HOME_DIR/state/.codex-idle-continuity.lock" ] && break
  sleep 0.5
done
[ ! -d "$HOME_DIR/state/.codex-idle-continuity.lock" ] || fail "supervisor survived its Codex owner"
wait "$owner" 2>/dev/null || true

printf 'ok - codex idle continuity re-arms a single-shot source only for a live owner\n'
