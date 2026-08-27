#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Opt-in live Pi compaction regression on a private tmux socket and isolated homes.
set -u

if [ "${FM_PI_COMPACTION_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_COMPACTION_LIVE_E2E=1 to run the isolated live Pi compaction regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v pi >/dev/null 2>&1 || { echo "skip: pi not found"; exit 0; }
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

AUTH_DIR=${FM_PI_LIVE_AUTH_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}}
AUTH_FILE="$AUTH_DIR/auth.json"
[ -f "$AUTH_FILE" ] || {
  echo "not ok - live Pi auth is unavailable at $AUTH_FILE" >&2
  exit 1
}

TMUX=$(command -v tmux)
SOCKET="fm-pi-compaction-live-e2e-$$"
SESSION=pi-compaction-live-e2e
LAB="$ROOT/.pi-compaction-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
PI_DIR="$LAB/pi-agent"
CONTEXT_LOG="$LAB/rebuilt-context.json"
PI_VERSION=$(pi --version)
QUESTION='DIRECT-CAPTAIN-Q-7: Which harbor token should remain reserved? Reply exactly DIRECT-CAPTAIN-A-7: amber.'
FOLLOWUP='Identify the direct human question immediately before the automated supervision turn and whether it received a completed answer. Reply on one line as CONTINUITY-SMOKE prior=<the earlier marker and harbor question> answered=<yes-or-no>. Do not use this follow-up or an automated prompt as the prior question.'

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -1000 2>/dev/null || true
}

wait_for_text() {
  local expected=$1 attempts=${2:-180} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fq "$expected"; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

session_file() {
  find "$PI_DIR/sessions" -type f -name '*.jsonl' 2>/dev/null | head -1
}

wait_for_session_probe() {
  local probe=$1 attempts=${2:-240} i=0 file
  while [ "$i" -lt "$attempts" ]; do
    file=$(session_file)
    if [ -n "$file" ] && PI_SMOKE_PROBE="$probe" python3 - "$file" <<'PY' >/dev/null 2>&1
import json
import os
import sys
entries = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
probe = os.environ["PI_SMOKE_PROBE"]
if probe == "answer":
    ok = any(
        entry.get("type") == "message"
        and entry.get("message", {}).get("role") == "assistant"
        and "DIRECT-CAPTAIN-A-7: amber." in json.dumps(entry["message"].get("content"), ensure_ascii=False)
        and entry["message"].get("stopReason") == "stop"
        for entry in entries
    )
elif probe == "automation-settled":
    custom = [
        i for i, entry in enumerate(entries)
        if entry.get("type") == "custom_message" and entry.get("customType") == "firstmate-watcher-wake"
    ]
    ok = bool(custom) and any(
        i > custom[-1]
        and entry.get("type") == "message"
        and entry.get("message", {}).get("role") == "assistant"
        and entry["message"].get("stopReason") == "stop"
        for i, entry in enumerate(entries)
    )
elif probe == "compaction":
    ok = any(entry.get("type") == "compaction" for entry in entries)
elif probe == "continuity-answer":
    followups = [
        i for i, entry in enumerate(entries)
        if entry.get("type") == "message"
        and entry.get("message", {}).get("role") == "user"
        and "Identify the direct human question immediately before" in json.dumps(entry["message"].get("content"), ensure_ascii=False)
    ]
    ok = bool(followups) and any(
        i > followups[-1]
        and entry.get("type") == "message"
        and entry.get("message", {}).get("role") == "assistant"
        and entry["message"].get("stopReason") == "stop"
        and "CONTINUITY-SMOKE" in json.dumps(entry["message"].get("content"), ensure_ascii=False)
        and "DIRECT-CAPTAIN-Q-7" in json.dumps(entry["message"].get("content"), ensure_ascii=False)
        and "answered=yes" in json.dumps(entry["message"].get("content"), ensure_ascii=False)
        for i, entry in enumerate(entries)
    )
else:
    ok = False
raise SystemExit(0 if ok else 1)
PY
    then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

send_prompt() {
  local prompt=$1
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$prompt"
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
}

lab_pid_is_safe() {
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local pid
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  while IFS= read -r pid; do
    if lab_pid_is_safe "$pid"; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done < <(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid -exec sed -n '1p' {} \; 2>/dev/null)
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$PI_DIR" "$PROJECT/.pi/extensions"
cp "$AUTH_FILE" "$PI_DIR/auth.json"
chmod 600 "$PI_DIR/auth.json"
cat > "$PI_DIR/settings.json" <<'JSON'
{
  "compaction": {
    "enabled": true,
    "reserveTokens": 16384,
    "keepRecentTokens": 1
  }
}
JSON
cat > "$PROJECT/.pi/extensions/zz-compaction-context-capture.ts" <<'TS'
import { writeFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.on("context", (event) => {
    if (!event.messages.some((message) => message.role === "custom" && message.customType === "firstmate-direct-exchange-continuity")) return;
    writeFileSync(process.env.FM_PI_CONTEXT_LOG!, JSON.stringify(event.messages, null, 2));
  });
}
TS
cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
count_file="$FM_HOME/state/.compaction-smoke-arm-count"
count=0
[ ! -f "$count_file" ] || count=$(cat "$count_file")
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [ "$count" -eq 1 ]; then
  printf 'signal: isolated compaction smoke supervision turn\n'
  exit 0
fi
trap 'exit 0' TERM INT
while :; do sleep 1; done
SH
chmod +x "$PROJECT/bin/fm-watch-arm.sh"

"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env PI_CODING_AGENT_DIR='$PI_DIR' FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_STATE_OVERRIDE='$HOME_DIR/state' FM_CONFIG_OVERRIDE='$HOME_DIR/config' FM_PI_CONTEXT_LOG='$CONTEXT_LOG' bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; pi --approve --provider openai-codex --model gpt-5.6-sol --thinking low; rc=\$?; printf \"PI_EXIT=%s\\n\" \"\$rc\"; sleep 300'"
"$TMUX" -L "$SOCKET" resize-window -t "$SESSION" -x 220 -y 60

wait_for_text "fm-primary-pi-watch.ts" 120 || fail "Pi primary extensions did not load"
send_prompt "$QUESTION"
wait_for_session_probe answer 240 || fail "direct captain answer did not complete"

send_prompt "/fm-watch-arm-pi"
wait_for_text "FIRSTMATE WATCHER WAKE" 180 || fail "custom watcher prompt did not render"
wait_for_session_probe automation-settled 300 || fail "automated supervision turn did not settle"

send_prompt "/compact"
wait_for_session_probe compaction 480 || fail "real Pi compaction did not complete"
FILE=$(session_file)
[ -n "$FILE" ] || fail "isolated Pi session file is missing"
BOUNDARY=$(python3 - "$FILE" <<'PY'
import json
import sys
entries = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
question = next(i for i, e in enumerate(entries) if e.get("type") == "message" and e.get("message", {}).get("role") == "user" and "DIRECT-CAPTAIN-Q-7" in json.dumps(e["message"].get("content"), ensure_ascii=False))
answer = next(i for i, e in enumerate(entries) if e.get("type") == "message" and e.get("message", {}).get("role") == "assistant" and "DIRECT-CAPTAIN-A-7" in json.dumps(e["message"].get("content"), ensure_ascii=False) and e["message"].get("stopReason") == "stop")
automation = next(i for i, e in enumerate(entries) if e.get("type") == "custom_message" and e.get("customType") == "firstmate-watcher-wake")
compaction_index = max(i for i, e in enumerate(entries) if e.get("type") == "compaction")
compaction = entries[compaction_index]
if not (question < answer < automation < compaction_index):
    raise SystemExit("unexpected interleaving")
kept = compaction.get("firstKeptEntryId", "")
kept_index = next((i for i, e in enumerate(entries) if e.get("id") == kept), len(entries))
if kept_index <= answer:
    raise SystemExit("compaction retained the original direct exchange instead of exercising continuity recovery")
kept_type = "none" if not kept else entries[kept_index].get("type", "unknown")
print(f"firstKeptType={kept_type}")
PY
) || fail "real compaction did not cut after the direct exchange"

send_prompt "$FOLLOWUP"
wait_for_session_probe continuity-answer 300 || fail "resumed model did not identify the prior question and completed answer"

for _ in $(seq 1 100); do
  [ -f "$CONTEXT_LOG" ] && break
  sleep 0.1
done
[ -f "$CONTEXT_LOG" ] || fail "post-compaction provider context was not captured"
python3 - "$CONTEXT_LOG" <<'PY' || fail "post-compaction model context lacks exact direct-exchange continuity"
import json
import sys
messages = json.load(open(sys.argv[1], encoding="utf-8"))
records = [m for m in messages if m.get("role") == "custom" and m.get("customType") == "firstmate-direct-exchange-continuity"]
assert records, "continuity custom message absent"
content = records[-1]["content"]
assert "DIRECT-CAPTAIN-Q-7: Which harbor token should remain reserved?" in content
assert "DIRECT-CAPTAIN-A-7: amber." in content
assert "ANSWERED" in content
assert "not human-authored input" in content
PY

printf 'ok - Pi %s live compaction rebuilt the exact answered captain exchange across a custom watcher turn (%s)\n' "$PI_VERSION" "$BOUNDARY"
