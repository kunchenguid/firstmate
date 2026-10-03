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
# idle-gap re-run. A re-run counts only when it lands while the idle
# supervisor lock is owned by the Codex pid and that supervisor's own arm
# started the watcher. The pane is not required to be idle then: the
# supervisor queues each close into the thread before it re-arms, so Codex is
# usually busy with that queued turn when the next run lands.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CODEX_LIVE_E2E codex tmux jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$ROOT/.codex-idle-live.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
LAB_CODEX_HOME="$LAB/codex-home"
LOG="$LAB/hits"
SRC="$LAB/source.sh"
SOCKET="fm-codex-idle-continuity-$$"
# Claims are keyed by source id under one per-user root. Sharing it lets any
# other home that holds `shot` there keep this lab's source from ever starting.
export FM_PROCEVENT_CLAIM_ROOT="$LAB/claims"
CODEX_VERSION=$(codex --version)

# The lab holds a copy of the operator's auth and sits in the worktree, so it
# is always removed. What a failure needs for diagnosis is copied out first.
keep_evidence() {
  local kept
  [ -d "$LAB" ] || return 0
  kept=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-idle-live-failed.XXXXXX") || return 0
  tmux -L "$SOCKET" capture-pane -p -S - -t idle > "$kept/pane.txt" 2>/dev/null || true
  rollouts | while IFS= read -r rollout; do cp "$rollout" "$kept/"; done
  cp -R "$HOME_DIR/state" "$kept/state" 2>/dev/null || true
  cp "$LOG" "$kept/hits" 2>/dev/null || true
  printf '# evidence kept at %s\n' "$kept" >&2
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  tmux -L "$SOCKET" capture-pane -p -t idle 2>/dev/null | grep '[^[:space:]]' | tail -12 | sed 's/^/#   /' >&2
  keep_evidence
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

rollouts() {
  find "$LAB_CODEX_HOME/sessions" -name 'rollout-*.jsonl' 2>/dev/null
}

supervisor_started_watcher() {
  grep -q '^watcher: started ' "$HOME_DIR/state/.codex-idle-continuity.lock/arm.out" 2>/dev/null
}

# A queued close is recorded in the session rollout as a user message. Tool
# output of an in-turn checkpoint can print the same text; it is recorded as a
# tool result and does not count. The pane is not read for this: its prompt
# lines come and go as Codex redraws, so a delivered close can be missed there.
# `fromjson?` skips the line Codex is still writing.
captures() {
  rollouts | while IFS= read -r rollout; do cat "$rollout"; done | jq -R -r '
    fromjson?
    | select(.type == "response_item" and .payload.type == "message" and .payload.role == "user")
    | .payload.content[]?.text // empty
    | select(startswith("check: process-event result captured"))
  ' | grep -c . || true
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
fm_test_track_procevent_home "$HOME_DIR" "$FM_PROCEVENT_CLAIM_ROOT"

tmux -L "$SOCKET" new-session -d -s idle -x 160 -y 45 -c "$PROJECT" -- env \
  CODEX_HOME="$LAB_CODEX_HOME" FM_HOME="$HOME_DIR" FM_POLL=1 \
  FM_PROCEVENT_CLAIM_ROOT="$FM_PROCEVENT_CLAIM_ROOT" codex \
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
watching=0
last=$(hits)
rearmed=0
delivered=0
# Captures from the poll before the re-arm is noticed. A close that lands in
# the same poll as that notice is after this count, so it still counts.
baseline=$(captures)
for _ in $(seq 1 360); do
  kill -0 "$codex_pid" 2>/dev/null || fail "Codex exited before the idle gap"
  now=$(hits)
  if [ "$(supervisor_owner)" = "$codex_pid" ]; then
    supervised=1
    # `watching` comes from an earlier poll, so the run counted here started
    # after the supervisor's watcher did. arm.out is empty between two arms,
    # which is why the flag is kept rather than read again in this poll.
    if [ "$watching" -eq 1 ] && [ "$now" -gt "$last" ]; then
      rearmed=1
    fi
    if supervisor_started_watcher; then
      watching=1
    fi
    if [ "$rearmed" -eq 1 ] && [ "$(captures)" -gt "$baseline" ]; then
      delivered=1
      break
    fi
  else
    watching=0
  fi
  if [ "$rearmed" -eq 0 ]; then
    baseline=$(captures)
  fi
  last=$now
  sleep 1
done
[ "$supervised" = 1 ] || fail "no idle supervisor owned by Codex pid $codex_pid (owner: $(supervisor_owner | grep . || echo none))"
[ "$rearmed" = 1 ] || fail "the idle supervisor did not re-arm the ownerless source ($(hits) hits)"
[ "$delivered" = 1 ] || fail "an actionable close never reached the Codex thread"
printf 'ok - %s Stop re-armed an ownerless source and queued its close into the idle thread\n' "$CODEX_VERSION"
