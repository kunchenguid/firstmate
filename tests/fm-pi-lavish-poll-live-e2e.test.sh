#!/usr/bin/env bash
# Opt-in credentialed Pi TUI smoke for the completion-aware Lavish relay.
set -u

if [ "${FM_PI_LAVISH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_LAVISH_LIVE_E2E=1 to run the Pi Lavish relay product-path smoke"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMUX=$(command -v tmux || true)
[ -n "$TMUX" ] || { echo "not ok - tmux not found" >&2; exit 1; }
command -v pi >/dev/null 2>&1 || { echo "not ok - pi not found" >&2; exit 1; }

SOCKET="fm-pi-lavish-live-$$"
SESSION=pi-lavish-live
LAB="$ROOT/.pi-lavish-live.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/home"
CONTROL="$LAB/control"
FAKE="$LAB/fake-lavish-axi"
PI_VERSION=$(pi --version)
LAVISH_VERSION=$(lavish-axi --version)

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -700 2>/dev/null || true
}

wait_for_text() {
  local expected=$1 attempts=${2:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture | grep -Fq "$expected" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

wait_for_exact_line() {
  local expected=$1 attempts=${2:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture | grep -Fxq " $expected" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

send_prompt() {
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
}

pid_alive() {
  kill -0 "$1" 2>/dev/null
}

pid_is_fake_poll() {
  local command
  command=$(ps -p "$1" -o command= 2>/dev/null || true)
  case "$command" in
    *"$FAKE"*) return 0 ;;
    *) return 1 ;;
  esac
}

wait_pid_dead() {
  local pid=$1 i=0
  while [ "$i" -lt 80 ]; do
    pid_alive "$pid" || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

cleanup() {
  local pid_file pid
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  sleep 0.1
  for pid_file in "$CONTROL"/pid.*; do
    [ -f "$pid_file" ] || continue
    pid=$(sed -n '1p' "$pid_file" 2>/dev/null || true)
    if [ -n "$pid" ] && pid_is_fake_poll "$pid"; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$CONTROL" "$PROJECT/.lavish"
cp "$ROOT/.pi/extensions/fm-lavish-poll.ts" "$PROJECT/.pi/extensions/fm-lavish-poll.ts"
printf '<!doctype html><title>Pi Lavish relay smoke</title>\n' >"$PROJECT/.lavish/pi-relay-smoke.html"

cat >"$FAKE" <<'SH'
#!/usr/bin/env bash
set -u
control=${FM_LAVISH_LIVE_CONTROL:?}
while ! mkdir "$control/counter.lock" 2>/dev/null; do sleep 0.01; done
count=0
[ ! -f "$control/counter" ] || count=$(sed -n '1p' "$control/counter")
count=$((count + 1))
printf '%s\n' "$count" >"$control/counter"
rmdir "$control/counter.lock"
printf '%s\n' "$$" >"$control/pid.$count"
printf 'invocation=%s\n' "$count" >>"$control/argv.log"
for arg in "$@"; do printf 'arg=<%s>\n' "$arg" >>"$control/argv.log"; done
trap 'exit 143' TERM INT
while [ ! -f "$control/release.$count" ]; do sleep 0.05; done
if [ "$count" -eq 1 ]; then
  cat <<'EOF'
session:
  status: feedback
prompts[1]{tag,text}:
  review,"SYNTHETIC_LIVE_FEEDBACK"
next_step: continue review
EOF
else
  cat <<'EOF'
session:
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{tag,text}:
  review,"SYNTHETIC_LIVE_FINAL_FEEDBACK"
next_step: stop polling
EOF
fi
SH
chmod +x "$FAKE"

"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env FM_HOME='$HOME_DIR' FM_LAVISH_AXI_BIN='$FAKE' FM_LAVISH_LIVE_CONTROL='$CONTROL' PI_OFFLINE=1 pi --approve --no-session --no-context-files --no-prompt-templates --no-extensions -e .pi/extensions/fm-lavish-poll.ts --skill .agents/skills --model openai-codex/gpt-5.6-sol --thinking low; rc=\$?; printf 'PI_EXIT=%s\n' \"\$rc\"; sleep 30"

wait_for_text "gpt-5.6-sol" 240 || fail "Pi did not reach its ready composer"
[ -f "$HOME_DIR/state/.pi-lavish-extension-loaded" ] || fail "Pi Lavish relay extension did not publish its loaded marker"
send_prompt "Use fm_lavish_poll with action=start for .lavish/pi-relay-smoke.html and do not use bash. Reply exactly LAVISH_RELAY_STARTED after the tool returns. When LAVISH_RELAY_RESULT later contains SYNTHETIC_LIVE_FEEDBACK, start the same relay again with agent_reply set to LIVE_AGENT_REPLY and reply exactly LAVISH_REARMED. When it contains SYNTHETIC_LIVE_FINAL_FEEDBACK, reply exactly LAVISH_REVIEW_TERMINAL."
wait_for_exact_line "LAVISH_RELAY_STARTED" 240 || fail "Pi did not start the relay through fm_lavish_poll"

for _ in $(seq 1 120); do
  [ -f "$CONTROL/pid.1" ] && break
  sleep 0.25
done
[ -f "$CONTROL/pid.1" ] || fail "first fake poll did not start"
first_pid=$(sed -n '1p' "$CONTROL/pid.1")
pid_alive "$first_pid" || fail "first poll was not alive after the start turn settled"

send_prompt "/bearings"
wait_for_text "[skill] bearings" 240 || fail "Pi did not accept Bearings while the Lavish poll waited"
pid_alive "$first_pid" || fail "Bearings cancelled the waiting Lavish poll"
send_prompt "Reply exactly LAVISH_SECOND_COMMAND_ACCEPTED."
wait_for_exact_line "LAVISH_SECOND_COMMAND_ACCEPTED" 240 || fail "a second normal prompt did not complete while the Lavish poll waited"
pid_alive "$first_pid" || fail "the second normal prompt cancelled the waiting Lavish poll"

printf 'release\n' >"$CONTROL/release.1"
wait_for_exact_line "LAVISH_REARMED" 240 || fail "synthetic feedback did not wake Pi and re-arm the relay"
for _ in $(seq 1 120); do
  [ -f "$CONTROL/pid.2" ] && break
  sleep 0.25
done
[ -f "$CONTROL/pid.2" ] || fail "second fake poll did not start"
grep -Fq 'arg=<--agent-reply>' "$CONTROL/argv.log" || fail "re-arm omitted --agent-reply"
grep -Fq 'arg=<LIVE_AGENT_REPLY>' "$CONTROL/argv.log" || fail "re-arm changed the agent reply value"
second_pid=$(sed -n '1p' "$CONTROL/pid.2")
pid_alive "$second_pid" || fail "second poll was not waiting"

printf 'release\n' >"$CONTROL/release.2"
wait_for_exact_line "LAVISH_REVIEW_TERMINAL" 240 || fail "terminal feedback did not wake the same Pi session"
wait_pid_dead "$second_pid" || fail "terminal review left the second poll alive"
send_prompt "Call fm_lavish_poll with action=status. If it reports no active polls, reply exactly LAVISH_REVIEW_ENDED."
wait_for_exact_line "LAVISH_REVIEW_ENDED" 240 || fail "terminal review did not clear relay ownership"

pane=$(capture)
printf '%s\n' "$pane" | grep -Fq '$ lavish-axi poll' \
  && fail "Pi used a foreground lavish-axi poll"
relay_root="$HOME_DIR/state/.pi-lavish-relay"
if [ -d "$relay_root" ] && find "$relay_root" -mindepth 1 -print -quit | grep -q .; then
  fail "terminal review left private relay records"
fi

send_prompt "/quit"
wait_for_text "PI_EXIT=0" 120 || fail "Pi did not exit cleanly"
wait_pid_dead "$first_pid" || fail "first poll survived Pi exit"
wait_pid_dead "$second_pid" || fail "second poll survived Pi exit"

printf 'ok - Pi %s with Lavish AXI %s kept Bearings and a normal prompt responsive during feedback wait, delivered one synthetic result, re-armed with agent reply, and ended cleanly\n' "$PI_VERSION" "$LAVISH_VERSION"
