#!/usr/bin/env bash
# Real bounded Pi-on-Herdr transport-ack regression for issue #1859.
#
# Opt in with FM_AFK_PI_HERDR_ACK_E2E=1.
# The test uses a real Pi primary and real away daemon inside a named Herdr lab,
# but gives Pi no provider credentials so the transport boundary stays bounded.
# It proves one delivered digest clears exactly once, while a swallowed Enter
# leaves the buffer pending.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_AFK_PI_HERDR_ACK_E2E:-0}" != 1 ]; then
  echo "skip: set FM_AFK_PI_HERDR_ACK_E2E=1 to run the real Pi/Herdr acknowledgement regression"
  exit 0
fi

for tool in herdr jq pi python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

ROOT=${ROOT:?}
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fix-afk-pi-herdr-ack)
trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"' EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null

TMP_ROOT=$(fm_test_tmproot fm-afk-pi-herdr-ack-e2e)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
PROJECT="$TMP_ROOT/project"
PI_DIR="$TMP_ROOT/pi-agent"
FAKEBIN="$TMP_ROOT/fakebin"
CAPTURE="$TMP_ROOT/pi-prompts.jsonl"
HERDR_LOG="$TMP_ROOT/herdr-calls.log"
ORIGINAL_PATH=$PATH
PRIMARY_PANE=
PRIMARY_TARGET=
DAEMON_STARTED=0

# shellcheck disable=SC2329 # invoked indirectly through the EXIT trap below
cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$DAEMON_STARTED" -eq 1 ]; then
    PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$HERDR_LAB_SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
      FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$PRIMARY_TARGET" \
      "$ROOT/bin/fm-afk-launch.sh" stop >/dev/null 2>&1 || rc=1
  fi
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$HOME_DIR"/{state,data,config,projects} "$PROJECT" "$PI_DIR" "$FAKEBIN"
printf '# Pi Herdr acknowledgement fixture\n' > "$PROJECT/AGENTS.md"
cat > "$TMP_ROOT/capture-extension.ts" <<'EOF'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync } from "node:fs";
const capturePath = process.env.FM_PI_CAPTURE_PATH!;
export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("before_agent_start", (event, ctx) => {
    appendFileSync(capturePath, `${JSON.stringify({ prompt: event.prompt, hex: Buffer.from(event.prompt, "utf8").toString("hex") })}\n`);
    ctx.abort();
  });
}
EOF

# Route all adapter Herdr calls through the guarded lab helper and record only
# the public command shape needed to prove exactly-once transport.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$HERDR_LAB_HELPER'
session='$HERDR_LAB_SESSION'
real_path='$ORIGINAL_PATH'
log='$HERDR_LOG'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || { echo 'wrapper refused foreign session' >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || { echo 'wrapper requires isolated session' >&2; exit 98; }
fi
printf '%s\\n' "\${args[*]}" >> "\$log"
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

cat > "$TMP_ROOT/daemon-entry" <<EOF
#!/usr/bin/env bash
export PATH='$FAKEBIN:$ORIGINAL_PATH'
export HERDR_SESSION='$HERDR_LAB_SESSION'
export FM_STATE_OVERRIDE='$STATE'
export FM_ESCALATE_BATCH_SECS=0
export FM_HOUSEKEEPING_TICK=1
export FM_POLL=1
export FM_SIGNAL_GRACE=1
export FM_HEARTBEAT=999999
export FM_CHECK_INTERVAL=999999
export FM_MAX_DEFER_SECS=30
export FM_STALE_ESCALATE_SECS=999999
exec '$ROOT/bin/fm-afk-start.sh'
EOF
chmod +x "$TMP_ROOT/daemon-entry"

PRIMARY_OUT=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --cwd "$PROJECT" --label ack-primary --no-focus)
WORKSPACE=$(printf '%s' "$PRIMARY_OUT" | jq -r '.result.workspace.workspace_id')
PRIMARY_PANE=$(printf '%s' "$PRIMARY_OUT" | jq -r '.result.root_pane.pane_id')
PRIMARY_TARGET="$HERDR_LAB_SESSION:$PRIMARY_PANE"
PI_CMD=$(printf 'exec env PI_CODING_AGENT_DIR=%q FM_HOME=%q FM_PI_CAPTURE_PATH=%q pi -e %q --no-context-files --no-session' "$PI_DIR" "$HOME_DIR" "$CAPTURE" "$TMP_ROOT/capture-extension.ts")
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$PRIMARY_PANE" "$PI_CMD" >/dev/null

wait_for_idle() {
  local stable=0 status _
  for _ in $(seq 1 240); do
    status=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent get "$PRIMARY_PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
    case "$status" in
      idle|done|blocked) stable=$((stable + 1)); [ "$stable" -ge 4 ] && return 0 ;;
      *) stable=0 ;;
    esac
    sleep 0.25
  done
  return 1
}

wait_for_idle || { echo "not ok - real Pi did not become idle" >&2; exit 1; }

CHILD_OUT=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab create --workspace "$WORKSPACE" --cwd "$PROJECT" --label fm-ack-task --no-focus)
CHILD_PANE=$(printf '%s' "$CHILD_OUT" | jq -r '.result.root_pane.pane_id')
CHILD_TARGET="$HERDR_LAB_SESSION:$CHILD_PANE"
cat > "$STATE/ack-task.meta" <<EOF
window=$CHILD_TARGET
backend=herdr
kind=ship
mode=no-mistakes
worktree=$PROJECT
project=ack-fixture
EOF
cat > "$STATE/ack-task.status" <<'EOF'
working: waiting for transport acknowledgement
EOF

PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$HERDR_LAB_SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$PRIMARY_TARGET" FM_AFK_LAUNCH_ENTRY="$TMP_ROOT/daemon-entry" \
  "$ROOT/bin/fm-afk-launch.sh" start >/dev/null
DAEMON_STARTED=1
for _ in $(seq 1 100); do [ -s "$STATE/.supervise-daemon.pid" ] && break; sleep 0.1; done
[ -s "$STATE/.supervise-daemon.pid" ] || { echo "not ok - away daemon did not start" >&2; exit 1; }

# Successful Pi delivery: Pi stays native-idle, but consumes the marked message
# and exposes a structurally empty Pi composer after the single Enter.
printf 'blocked [key=delivered]: unchanged digest\n' >> "$STATE/ack-task.status"
for _ in $(seq 1 180); do
  sends=$(grep -c '^pane send-text ' "$HERDR_LOG" 2>/dev/null || true)
  if [ "$sends" -ge 1 ] && [ ! -s "$STATE/.subsuper-escalations" ]; then break; fi
  sleep 0.1
done
sends=$(grep -c '^pane send-text ' "$HERDR_LOG" 2>/dev/null || true)
[ "$sends" -eq 1 ] || { echo "not ok - delivered digest was typed $sends times" >&2; exit 1; }
[ ! -s "$STATE/.subsuper-escalations" ] || { echo "not ok - delivered digest remained buffered" >&2; exit 1; }
composer=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$HERDR_LAB_SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  bash -c '. "$0/bin/fm-backend.sh"; fm_backend_composer_state herdr "$1"' "$ROOT" "$PRIMARY_TARGET")
[ "$composer" = empty ] || { echo "not ok - delivered Pi composer was not empty: $composer" >&2; exit 1; }
printf 'ok - real Pi/Herdr idle-native delivery clears the buffer after one typed digest\n'

# Unsubmitted-input control: a human draft makes the same Pi composer pending,
# so the daemon must retain the new digest rather than merging or clearing it.
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$PRIMARY_PANE" 'unsubmitted human draft' >/dev/null
for _ in $(seq 1 80); do
  composer=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$HERDR_LAB_SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_composer_state herdr "$1"' "$ROOT" "$PRIMARY_TARGET")
  [ "$composer" = pending ] && break
  sleep 0.1
done
[ "$composer" = pending ] || { echo "not ok - Pi draft control did not become pending: $composer" >&2; exit 1; }
printf 'blocked [key=unsubmitted]: unchanged digest\n' >> "$STATE/ack-task.status"
for _ in $(seq 1 100); do
  [ -s "$STATE/.subsuper-escalations" ] && break
  sleep 0.1
done
[ -s "$STATE/.subsuper-escalations" ] || { echo "not ok - unsubmitted Pi input did not retain the digest" >&2; exit 1; }
printf 'ok - real Pi/Herdr unsubmitted input preserves the pending buffer\n'

# Clear the real draft before the guarded daemon teardown.
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PRIMARY_PANE" ctrl+c >/dev/null
PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$HERDR_LAB_SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$PRIMARY_TARGET" "$ROOT/bin/fm-afk-launch.sh" stop >/dev/null
DAEMON_STARTED=0
printf 'evidence: pi=%s herdr=%s protocol=%s successful_send_texts=%s\n' \
  "$(pi --version)" \
  "$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" status --json | jq -r '.client.version')" \
  "$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" status --json | jq -r '.client.protocol')" \
  "$sends"
exit 0
