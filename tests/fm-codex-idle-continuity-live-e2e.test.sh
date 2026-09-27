#!/usr/bin/env bash
# Opt-in credentialed check: a real Codex Stop reaches idle continuity and
# re-arms an ownerless source while the interactive session idles.
#
# The session must outlive its turn: the supervisor exits with its Codex
# owner, so a one-shot `codex exec` ends before the idle gap exists. Codex
# therefore runs interactively in an isolated tmux server with a throwaway
# CODEX_HOME, which carries a copy of the operator's auth and trusts only the
# lab project, so the operator's own Codex config is never written.
#
# The source is registered only after the first turn is idle, and it lives
# for a while after each run, so the model's in-turn drain does not race the
# idle-gap re-run. A re-run counts only when it lands while the turn is idle
# and the idle supervisor lock is owned by the Codex pid.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CODEX_LIVE_E2E codex tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$ROOT/.codex-idle-live.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
LAB_CODEX_HOME="$LAB/codex-home"
LOG="$LAB/hits"
SRC="$LAB/source.sh"
SOCKET="fm-codex-idle-continuity-$$"
CODEX_VERSION=$(codex --version)

fail() {
  printf 'not ok - %s\n' "$1" >&2
  tmux -L "$SOCKET" capture-pane -p -t idle 2>/dev/null | grep '[^[:space:]]' | tail -12 | sed 's/^/#   /' >&2
  exit 1
}

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  if [ -d "$HOME_DIR/state" ]; then
    FM_HOME="$HOME_DIR" "$ROOT/bin/fm-codex-idle-continuity.sh" --handover >/dev/null 2>&1 || true
    FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

hits() {
  if [ -f "$LOG" ]; then wc -l < "$LOG" | tr -d ' '; else printf '0\n'; fi
}

turn_idle() {
  ! tmux -L "$SOCKET" capture-pane -p -t idle 2>/dev/null | grep -F 'esc to interrupt' >/dev/null
}

supervisor_owner() {
  cat "$HOME_DIR/state/.codex-idle-continuity.lock/owner" 2>/dev/null || true
}

send_prompt() {
  tmux -L "$SOCKET" send-keys -t idle "$1"
  sleep 1
  tmux -L "$SOCKET" send-keys -t idle Enter
}

AUTH="${CODEX_HOME:-$HOME/.codex}/auth.json"
[ -f "$AUTH" ] || fail "no Codex auth at $AUTH"

mkdir -p "$LAB" "$HOME_DIR/state" "$LAB_CODEX_HOME"
git clone -q "$ROOT" "$PROJECT"
cp "$ROOT/bin/fm-codex-idle-continuity.sh" "$PROJECT/bin/fm-codex-idle-continuity.sh"
cp "$ROOT/.codex/hooks.json" "$PROJECT/.codex/hooks.json"
chmod +x "$PROJECT/bin/fm-codex-idle-continuity.sh"
cp "$AUTH" "$LAB_CODEX_HOME/auth.json"
printf '[projects."%s"]\ntrust_level = "trusted"\n' "$(cd "$PROJECT" && pwd -P)" > "$LAB_CODEX_HOME/config.toml"
cat > "$SRC" <<EOF
#!/bin/sh
printf 'x\n' >> '$LOG'
sleep 20
EOF
chmod +x "$SRC"
fm_test_track_procevent_home "$HOME_DIR"

tmux -L "$SOCKET" new-session -d -s idle -x 160 -y 45 -c "$PROJECT" -- env \
  CODEX_HOME="$LAB_CODEX_HOME" FM_HOME="$HOME_DIR" FM_POLL=1 codex \
  --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox \
  -c 'model_reasoning_effort="low"' \
  'Reply with exactly IDLE-OK. Do not call tools.' \
  || fail "could not launch Codex in the isolated tmux server"
codex_pid=$(tmux -L "$SOCKET" display-message -p -t idle '#{pane_pid}')

first_done=0
for _ in $(seq 1 180); do
  kill -0 "$codex_pid" 2>/dev/null || fail "Codex exited during its first turn"
  if turn_idle && tmux -L "$SOCKET" capture-pane -p -t idle | grep -F 'IDLE-OK' >/dev/null; then
    first_done=1
    break
  fi
  sleep 1
done
[ "$first_done" = 1 ] || fail "the first Codex turn did not finish"

FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" register lavish shot -- "$SRC" >/dev/null \
  || fail "could not register the live source"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null \
  || fail "initial live reconcile failed"
for _ in $(seq 1 30); do
  [ "$(hits)" -ge 1 ] && break
  sleep 0.5
done
[ "$(hits)" -ge 1 ] || fail "live source did not run after registration"

send_prompt 'Reply with exactly OK2. Do not retire, register, or modify any process-event source; it is an intentional test fixture. Follow the normal wake drain protocol otherwise.'

supervised=0
last=$(hits)
rearmed=0
for _ in $(seq 1 360); do
  kill -0 "$codex_pid" 2>/dev/null || fail "Codex exited before the idle gap"
  now=$(hits)
  if turn_idle && [ "$(supervisor_owner)" = "$codex_pid" ]; then
    supervised=1
    if [ "$now" -gt "$last" ]; then
      rearmed=1
      break
    fi
  fi
  last=$now
  sleep 1
done
[ "$supervised" = 1 ] || fail "no idle supervisor owned by Codex pid $codex_pid (owner: $(supervisor_owner | grep . || echo none))"
[ "$rearmed" = 1 ] || fail "the idle supervisor did not re-arm the ownerless source ($(hits) hits)"
printf 'ok - %s Stop re-armed an ownerless source while the interactive session idled\n' "$CODEX_VERSION"
