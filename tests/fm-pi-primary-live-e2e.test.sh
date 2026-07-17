#!/usr/bin/env bash
# Opt-in interactive Pi primary regression on a private tmux socket and isolated homes.
set -u

if [ "${FM_PI_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_LIVE_E2E=1 to run the isolated interactive Pi regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v pi >/dev/null 2>&1 || { echo "skip: pi not found"; exit 0; }
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

TMUX=$(command -v tmux)
SOCKET="fm-pi-live-e2e-$$"
SESSION=pi-live-e2e
PI_SESSION_ID=11111111-1111-4111-8111-111111111111
PI_VERSION=$(pi --version)

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

[ "$PI_VERSION" = 0.80.7 ] || fail "live resume regression requires Pi 0.80.7, found $PI_VERSION"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-live-e2e.XXXXXX") || fail "could not create the system temporary lab"
chmod 700 "$LAB" || fail "could not restrict the system temporary lab"
umask 077
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
PI_DIR="$LAB/pi-agent"
PI_SESSION_DIR="$PI_DIR/sessions"
PI_LAUNCHER="$LAB/run-pi-resume.sh"

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -600 2>/dev/null || true
}

wait_for_text() {
  local expected=$1 attempts=${2:-120} i=0
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

wait_for_exact_line() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fxq " $expected"; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

wait_for_file() {
  local file=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ -f "$file" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

wait_for_path_absent() {
  local path=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ ! -e "$path" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
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
  local pid_file watcher_pid arm_pid
  pid_file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid 2>/dev/null | head -1 || true)
  watcher_pid=
  arm_pid=
  if [ -n "$pid_file" ]; then
    watcher_pid=$(sed -n '1p' "$pid_file" 2>/dev/null || true)
    arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  fi
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  sleep 0.1
  if [ -n "$watcher_pid" ] && lab_pid_is_safe "$watcher_pid"; then
    kill -TERM "$watcher_pid" 2>/dev/null || true
  fi
  if [ -n "$arm_pid" ] && lab_pid_is_safe "$arm_pid"; then
    kill -TERM "$arm_pid" 2>/dev/null || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

send_prompt() {
  local prompt=$1
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$prompt"
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
}

wait_pid_dead() {
  local pid=$1 i=0
  while [ "$i" -lt 50 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

git clone -q "$ROOT" "$PROJECT"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/bin/fm-primary-scope.sh" "$PROJECT/bin/fm-primary-scope.sh"
cp "$ROOT/bin/fm-turnend-guard.sh" "$PROJECT/bin/fm-turnend-guard.sh"
cp "$ROOT/bin/fm-supervision-instructions.sh" "$PROJECT/bin/fm-supervision-instructions.sh"
chmod +x "$PROJECT/bin/fm-primary-scope.sh" "$PROJECT/bin/fm-turnend-guard.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$PI_DIR" "$PI_SESSION_DIR"

cat > "$PROJECT/.pi/extensions/fm-live-e2e-provider.ts" <<'TS'
import { createFauxCore, fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";

const provider = "fm-live-e2e";
const model = {
  id: provider,
  name: "Firstmate live E2E",
  reasoning: false,
  input: ["text"] as ("text" | "image")[],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  contextWindow: 32000,
  maxTokens: 1024,
};

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((block) => block && typeof block === "object" && (block as { type?: string }).type === "text")
    .map((block) => String((block as { text?: string }).text || ""))
    .join("\n");
}

function respond(context: { messages: Array<{ role: string; content?: unknown; toolName?: string }> }) {
  const userIndex = context.messages.findLastIndex((message) => message.role === "user");
  if (userIndex < 0) throw new Error("live E2E provider received no user message");
  const prompt = contentText(context.messages[userIndex].content);
  const toolNames = context.messages.slice(userIndex + 1)
    .filter((message) => message.role === "toolResult")
    .map((message) => message.toolName || "");

  if (prompt.includes("PI_E2E_BASH_ONE")) {
    return toolNames.includes("bash")
      ? fauxAssistantMessage("BASH-ONE")
      : fauxAssistantMessage(fauxToolCall("bash", { command: "printf PI_E2E_BASH_ONE" }, { id: "bash-one" }), { stopReason: "toolUse" });
  }
  if (prompt.includes("first five lines of README.md")) {
    return toolNames.includes("read")
      ? fauxAssistantMessage("READ-ONE")
      : fauxAssistantMessage(fauxToolCall("read", { path: "README.md", offset: 1, limit: 5 }, { id: "read-one" }), { stopReason: "toolUse" });
  }
  if (prompt.includes("PI_E2E_BASH_TWO")) {
    return toolNames.includes("bash")
      ? fauxAssistantMessage("BASH-TWO")
      : fauxAssistantMessage(fauxToolCall("bash", { command: "printf PI_E2E_BASH_TWO" }, { id: "bash-two" }), { stopReason: "toolUse" });
  }
  if (prompt.includes("Reply exactly READY")) return fauxAssistantMessage("READY");
  if (prompt.startsWith("FIRSTMATE WATCHER WAKE:")) {
    if (!toolNames.includes("bash")) {
      return fauxAssistantMessage(fauxToolCall("bash", { command: "bin/fm-wake-drain.sh" }, { id: "wake-drain" }), { stopReason: "toolUse" });
    }
    if (!toolNames.includes("fm_watch_arm_pi")) {
      return fauxAssistantMessage(fauxToolCall("fm_watch_arm_pi", {}, { id: "wake-arm" }), { stopReason: "toolUse" });
    }
    return fauxAssistantMessage("REARMED");
  }
  throw new Error(`live E2E provider received an unexpected prompt: ${prompt}`);
}

const faux = createFauxCore({ api: provider, provider, models: [model], tokenSize: { min: 64, max: 64 } });
faux.setResponses(Array.from({ length: 32 }, () => respond));

export default function (pi: { registerProvider(name: string, config: Record<string, unknown>): void }) {
  pi.registerProvider(provider, {
    name: "Firstmate live E2E",
    baseUrl: "http://localhost:0",
    apiKey: "test-owned-no-network",
    api: faux.api,
    streamSimple: faux.streamSimple,
    models: [model],
  });
}
TS

mv "$PROJECT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-watch-arm-live-e2e-real.sh"
cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
expected="$state/.resume-expected-old-pid"
observed="$state/.resume-lock-before-watcher"
if [ -f "$expected" ]; then
  old=$(cat "$expected")
  current=$(cat "$state/.lock")
  old_state=dead
  kill -0 "$old" 2>/dev/null && old_state=live
  current_comm=$(ps -p "$current" -o comm= 2>/dev/null || true)
  current_comm=${current_comm##*/}
  temporary=$(mktemp "$state/.resume-lock-before-watcher.XXXXXX")
  printf '%s\n%s\n%s\n' "$old_state" "$current" "$current_comm" > "$temporary"
  mv "$temporary" "$observed"
  [ "$old_state" = dead ] && [ "$current" != "$old" ] && [ "$current_comm" = pi ] || exit 97
fi
exec "$(dirname "$0")/fm-watch-arm-live-e2e-real.sh" "$@"
SH
chmod +x "$PROJECT/bin/fm-watch-arm.sh"

cat > "$PI_LAUNCHER" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
pi --provider fm-live-e2e --model fm-live-e2e --session-dir "$PI_SESSION_DIR" --session-id "$PI_SESSION_ID"
first_rc=$?
printf 'FIRST_PI_EXIT=%s\n' "$first_rc"
[ "$first_rc" -eq 0 ] || exit "$first_rc"
while [ ! -f "$FM_HOME/state/.resume-now" ]; do sleep 0.1; done
printf 'PI_RESUME_STARTING=%s\n' "$PI_SESSION_ID"
pi --provider fm-live-e2e --model fm-live-e2e --session-dir "$PI_SESSION_DIR" --session "$PI_SESSION_ID"
resumed_rc=$?
printf 'RESUMED_PI_EXIT=%s\n' "$resumed_rc"
[ "$resumed_rc" -eq 0 ] || exit "$resumed_rc"
sleep 300
SH
chmod +x "$PI_LAUNCHER"

"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env PI_CODING_AGENT_DIR='$PI_DIR' PI_SESSION_DIR='$PI_SESSION_DIR' PI_SESSION_ID='$PI_SESSION_ID' FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 PI_OFFLINE=1 '$PI_LAUNCHER'"

wait_for_text "Trust project folder?" 40 || fail "Pi trust prompt did not appear"
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_text "fm-primary-turnend-guard.ts" 60 || fail "Pi primary extensions did not load"
wait_for_file "$HOME_DIR/state/.watch.lock/pid" 60 || fail "Pi session_start did not automatically arm supervision"
initial_pi_pid=$(cat "$HOME_DIR/state/.lock")
initial_pi_comm=$(ps -p "$initial_pi_pid" -o comm= 2>/dev/null || true)
[ "${initial_pi_comm##*/}" = pi ] || fail "Pi session_start did not replace the shell fixture lock with the native Pi owner"
initial_watcher_pid=$(cat "$HOME_DIR/state/.watch.lock/pid")
initial_arm_pid=$(ps -p "$initial_watcher_pid" -o ppid= | tr -d ' ')
[ -n "$initial_arm_pid" ] || fail "initial watcher parent was not live"

send_prompt "Use the bash tool to run printf PI_E2E_BASH_ONE. Then reply exactly BASH-ONE."
wait_for_exact_line "BASH-ONE" || fail "first bash turn did not complete"
session_file=$(find "$PI_SESSION_DIR" -maxdepth 1 -type f -name "*_${PI_SESSION_ID}.jsonl" | head -1)
[ -n "$session_file" ] || fail "Pi did not persist the session selected for native resume"

"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l '/quit'
sleep 1
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_text "FIRST_PI_EXIT=0" 60 || fail "initial Pi session did not exit cleanly"
wait_pid_dead "$initial_pi_pid" || fail "initial native Pi owner survived clean exit"
wait_pid_dead "$initial_watcher_pid" || fail "initial watcher survived clean Pi exit"
wait_pid_dead "$initial_arm_pid" || fail "initial arm child survived clean Pi exit"
wait_for_path_absent "$HOME_DIR/state/.watch.lock" 60 || fail "initial watcher lock survived clean Pi exit"
[ "$(cat "$HOME_DIR/state/.lock")" = "$initial_pi_pid" ] || fail "initial native Pi PID was not left in the session lock"

printf '%s\n' "$initial_pi_pid" > "$HOME_DIR/state/.resume-expected-old-pid"
: > "$HOME_DIR/state/.resume-now"
wait_for_text "PI_RESUME_STARTING=$PI_SESSION_ID" 60 || fail "native Pi resume command did not start"
wait_for_file "$HOME_DIR/state/.resume-lock-before-watcher" 60 || fail "resume watcher boundary was not observed"
resume_old_state=$(sed -n '1p' "$HOME_DIR/state/.resume-lock-before-watcher")
resumed_pi_pid=$(sed -n '2p' "$HOME_DIR/state/.resume-lock-before-watcher")
resumed_pi_comm=$(sed -n '3p' "$HOME_DIR/state/.resume-lock-before-watcher")
[ "$resume_old_state" = dead ] || fail "old native Pi owner was still live before resumed watcher startup"
[ "$resumed_pi_pid" != "$initial_pi_pid" ] || fail "native Pi resume did not replace the dead session lock owner"
[ "$resumed_pi_comm" = pi ] || fail "resumed session lock owner was not native Pi"
[ "$(cat "$HOME_DIR/state/.lock")" = "$resumed_pi_pid" ] || fail "session lock changed after resume reclamation"
wait_for_file "$HOME_DIR/state/.watch.lock/pid" 60 || fail "resumed Pi did not arm supervision after lock reclamation"

send_prompt "Use the read tool to read the first five lines of README.md. Then reply exactly READ-ONE."
wait_for_exact_line "READ-ONE" || fail "read turn did not complete"
send_prompt "Use the bash tool to run printf PI_E2E_BASH_TWO. Then reply exactly BASH-TWO."
wait_for_exact_line "BASH-TWO" || fail "second bash turn did not complete"

: > "$HOME_DIR/state/pi-e2e.meta"
send_prompt "Reply exactly READY with no tools. After any FIRSTMATE WATCHER WAKE, run bin/fm-wake-drain.sh, read the signaled status, call fm_watch_arm_pi to re-arm, and finish exactly REARMED."
wait_for_exact_line "READY" 120 || fail "Pi did not settle with the automatic watcher armed"

printf 'done: pi live e2e watcher fire\n' > "$HOME_DIR/state/pi-e2e.status"
wait_for_text "watcher: started Pi extension arm child 2" 180 || fail "watcher wake did not drain and re-arm through the Pi tool"
wait_for_exact_line "REARMED" 120 || fail "Pi did not settle after re-arming watcher supervision"

pane=$(capture)
guard_count=$(printf '%s\n' "$pane" | grep -Fc "TURN WOULD END BLIND - supervision is off." || true)
[ "$guard_count" -eq 0 ] || fail "automatic session_start arm should prevent guard injection, saw $guard_count"
foreground_arm='$ bin/fm-watch-arm.sh'
if printf '%s\n' "$pane" | grep -Fq "$foreground_arm"; then
  fail "Pi used a foreground bash watcher arm"
fi

wait_for_file "$HOME_DIR/state/.watch.lock/pid" 60 || fail "re-armed watcher pid was not recorded"
pid_file="$HOME_DIR/state/.watch.lock/pid"
watcher_pid=$(sed -n '1p' "$pid_file")
arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
[ -n "$arm_pid" ] || fail "re-armed watcher parent was not live"

"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l '/quit'
sleep 1
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_text "RESUMED_PI_EXIT=0" 60 || fail "resumed Pi did not exit cleanly"
wait_pid_dead "$resumed_pi_pid" || fail "resumed native Pi owner survived clean exit"
wait_pid_dead "$watcher_pid" || fail "watcher child survived clean Pi exit"
wait_pid_dead "$arm_pid" || fail "arm child survived clean Pi exit"

printf 'ok - Pi %s live E2E created, exited, resumed, reclaimed before watcher startup, woke, re-armed, and cleaned up\n' "$PI_VERSION"
