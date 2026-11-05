#!/usr/bin/env bash
# Opt-in live guard for Droid's primary hook, foreground-tool, and composer facts.
# Requires an authenticated Droid installation and spends model tokens.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_DROID_PRIMARY_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_DROID_PRIMARY_LIVE_E2E=1 to run the real Droid primary probe"
  exit 0
fi

for tool in droid tmux jq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

REAL_TMUX=$(command -v tmux)
SOCKET="fm-droid-primary-live-$$"
LAB=$(fm_test_tmproot fm-droid-primary-live)
PROJECT="$LAB/project"
SESSION=droid-primary-live

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT/.factory" "$LAB/shim"
git init -q "$PROJECT"

cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"

cat > "$PROJECT/.factory/sessionstart.sh" <<'SH'
#!/usr/bin/env bash
cat > .factory/sessionstart-payload.json
printf '%s\n' 'Startup nonce: DROID_LIVE_SESSIONSTART_8291. When asked, report SESSIONSTART_OBSERVED_ followed by the nonce.'
SH

cat > "$PROJECT/.factory/pretool.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
printf '%s\n' "$payload" >> .factory/pretool-payloads.jsonl
command=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')
case "$command" in
  *droid-live-denied-sentinel*)
    printf '%s\n' DROID_LIVE_PRETOOL_DENIED >&2
    exit 2
    ;;
esac
exit 0
SH

cat > "$PROJECT/.factory/stop.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
printf '%s\n' "$payload" >> .factory/stop-payloads.jsonl
if printf '%s' "$payload" | jq -e '.stop_hook_active == true' >/dev/null; then
  printf '%s\n' DROID_LIVE_STOP_ALLOW >&2
  exit 0
fi
printf '%s\n' DROID_LIVE_STOP_BLOCK >&2
exit 2
SH

cat > "$PROJECT/.factory/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "bash .factory/sessionstart.sh"}]}],
    "PreToolUse": [{"matcher": "Execute", "hooks": [{"type": "command", "command": "bash .factory/pretool.sh"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "bash .factory/stop.sh"}]}]
  }
}
JSON

chmod +x "$PROJECT/.factory/sessionstart.sh" "$PROJECT/.factory/pretool.sh" "$PROJECT/.factory/stop.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n hooks -c "$PROJECT" -- \
  droid --auto high \
  'Report the startup nonce using the format requested by the SessionStart context, use a shell tool to run exactly: touch droid-live-denied-sentinel, report the denial, then end your turn.'

capture=
trust_confirmed=0
for _ in $(seq 1 180); do
  capture=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:hooks" -S -120 2>/dev/null || true)
  if [ "$trust_confirmed" -eq 0 ] \
     && printf '%s' "$capture" | grep -q 'Trust this folder?'; then
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:hooks" Enter
    trust_confirmed=1
  fi
  if [ -s "$PROJECT/.factory/stop-payloads.jsonl" ] \
     && [ "$(wc -l < "$PROJECT/.factory/stop-payloads.jsonl" | tr -d ' ')" -ge 2 ] \
     && printf '%s' "$capture" | grep -q 'DROID_LIVE_STOP_ALLOW'; then
    break
  fi
  sleep 0.5
done

printf '%s' "$capture" | grep -q 'SESSIONSTART_OBSERVED_DROID_LIVE_SESSIONSTART_8291' \
  || fail "Droid SessionStart stdout did not reach model-visible context"
[ ! -e "$PROJECT/droid-live-denied-sentinel" ] \
  || fail "Droid PreToolUse denial did not stop the command before execution"
jq -e 'select(.hook_event_name == "SessionStart" and .source == "startup")' \
  "$PROJECT/.factory/sessionstart-payload.json" >/dev/null \
  || fail "Droid SessionStart payload did not carry source=startup"
jq -s -e 'any(.[]; .hook_event_name == "PreToolUse" and .tool_name == "Execute" and .tool_input.command == "touch droid-live-denied-sentinel")' \
  "$PROJECT/.factory/pretool-payloads.jsonl" >/dev/null \
  || fail "Droid PreToolUse payload shape drifted"
jq -s -e 'length >= 2 and .[0].stop_hook_active == false and .[1].stop_hook_active == true' \
  "$PROJECT/.factory/stop-payloads.jsonl" >/dev/null \
  || fail "Droid Stop blocking or stop_hook_active loop semantics drifted"
pass "Droid live primary hooks: project settings, SessionStart, PreToolUse, Stop blocking, and loop guard"

PATH="$LAB/shim:$PATH"
export PATH
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

for _ in $(seq 1 60); do
  [ "$(fm_tmux_composer_state "$SESSION:hooks")" = empty ] && break
  sleep 0.25
done
fm_tmux_pane_is_droid "$SESSION:hooks" \
  || fail "Droid live pane lost exact foreground-process identity"
[ "$(fm_tmux_composer_state "$SESSION:hooks")" = empty ] \
  || fail "Droid live idle composer did not classify empty"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:hooks" -l DROID_LIVE_TYPED
sleep 0.5
[ "$(fm_tmux_composer_state "$SESSION:hooks")" = pending ] \
  || fail "Droid live typed composer did not classify pending"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:hooks" C-u
pass "Droid live composer: detached cursor remains safe for idle and typed input"

"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n foreground -c "$PROJECT" -- \
  droid --auto high \
  "Run this exact foreground shell command: bash -lc 'touch .factory/foreground-running; sleep 20; rm .factory/foreground-running; echo DROID_LIVE_TOOL_DONE'. While it is still running, visibly publish the concatenation of DROID_LIVE_MIDCALL_ and UPDATE. After it completes, publish the concatenation of DROID_LIVE_FOREGROUND_ and FINISHED."

running_capture=
for _ in $(seq 1 80); do
  running_capture=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:foreground" -S -80 2>/dev/null || true)
  if [ -e "$PROJECT/.factory/foreground-running" ] \
     && printf '%s' "$running_capture" | grep -q 'Press ESC to stop'; then
    break
  fi
  sleep 0.25
done
[ -e "$PROJECT/.factory/foreground-running" ] \
  || fail "Droid live foreground probe was no longer active during its busy capture"
printf '%s' "$running_capture" | grep -q 'Press ESC to stop' \
  || fail "Droid live foreground probe never exposed the verified busy token"
printf '%s\n' "$running_capture" | awk '
  /Execute bash -lc/ { execute = NR }
  /DROID_LIVE_MIDCALL_UPDATE/ && execute && NR > execute { found = 1 }
  END { exit !found }
' && fail "Droid unexpectedly emitted the requested visible update during the active foreground tool"
printf '%s\n' "$running_capture" | awk '
  /Execute bash -lc/ { execute = NR }
  /DROID_LIVE_FOREGROUND_FINISHED/ && execute && NR > execute { found = 1 }
  END { exit !found }
' && fail "Droid reasoned past the foreground tool before it completed"

finished_capture=
for _ in $(seq 1 160); do
  finished_capture=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:foreground" -S -100 2>/dev/null || true)
  printf '%s\n' "$finished_capture" | awk '
    /DROID_LIVE_TOOL_DONE/ { tool_done = NR }
    /DROID_LIVE_FOREGROUND_FINISHED/ && tool_done && NR > tool_done { found = 1 }
    END { exit !found }
  ' && break
  sleep 0.25
done
printf '%s\n' "$finished_capture" | awk '
  /DROID_LIVE_TOOL_DONE/ { tool_done = NR }
  /DROID_LIVE_FOREGROUND_FINISHED/ && tool_done && NR > tool_done { found = 1 }
  END { exit !found }
' \
  || fail "Droid did not resume reasoning after the foreground tool completed"
pass "Droid live foreground tool: no reasoning continuation until tool completion"

printf 'ok - Droid %s primary live verification complete\n' "$(droid --version)"
