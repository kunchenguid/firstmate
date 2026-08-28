#!/usr/bin/env bash
# Real Pi/Herdr ownership transfer smoke test.
#
# Opt-in because it launches a real interactive Pi primary and away daemon in a
# named non-default Herdr lab. It proves an already-live ordinary Pi watcher is
# retired before daemon launch, emits no direct follow-up during away mode, and
# returns as exactly one ordinary cycle after the daemon stops.
# The wait_for predicates intentionally defer variable expansion until eval.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_PI_AWAY_TAKEOVER_HERDR_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_AWAY_TAKEOVER_HERDR_E2E=1 to run the real Pi/Herdr ownership-transfer regression"
  exit 0
fi

for tool in herdr jq pi; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=${HERDR_LAB_SESSION:-$("$LAB_HELPER" name firstmate-silent-routine-notifications-v1)}
TMP_ROOT=$(fm_test_tmproot fm-pi-away-takeover-herdr)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
PROJECT="$TMP_ROOT/project"
PI_DIR="$TMP_ROOT/pi-agent"
FAKEBIN="$TMP_ROOT/fakebin"
CAPTURE="$TMP_ROOT/pi-prompts.jsonl"
ORIGINAL_PATH=$PATH
PRIMARY_PANE=
PRIMARY_TARGET=
DAEMON_STARTED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$DAEMON_STARTED" -eq 1 ]; then
    PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
      FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$PRIMARY_TARGET" \
      "$ROOT/bin/fm-afk-launch.sh" stop >/dev/null 2>&1 || true
  fi
  if ! "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$SESSION"

mkdir -p "$HOME_DIR"/{state,data,config,projects} "$PROJECT" "$PI_DIR" "$FAKEBIN"
printf '# Synthetic isolated Firstmate primary\n' > "$PROJECT/AGENTS.md"

CAPTURE_EXT="$TMP_ROOT/capture-extension.ts"
cat > "$CAPTURE_EXT" <<'EOF'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync, writeFileSync } from "node:fs";
const capturePath = process.env.FM_PI_CAPTURE_PATH!;
export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("session_start", () => {
    writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
  });
  pi.on("before_agent_start", (event, ctx) => {
    appendFileSync(capturePath, `${JSON.stringify({ prompt: event.prompt })}\n`);
    ctx.abort();
  });
}
EOF

# Production backend calls are forced through the guarded session helper.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || { echo 'wrapper refused foreign session' >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || { echo 'wrapper requires isolated session' >&2; exit 98; }
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

cat > "$TMP_ROOT/daemon-entry" <<EOF
#!/usr/bin/env bash
export PATH='$FAKEBIN:$ORIGINAL_PATH'
export HERDR_SESSION='$SESSION'
export FM_STATE_OVERRIDE='$STATE'
export FM_POLL=1
export FM_SIGNAL_GRACE=0
export FM_HEARTBEAT=999999
export FM_CHECK_INTERVAL=999999
exec '$ROOT/bin/fm-afk-start.sh'
EOF
chmod +x "$TMP_ROOT/daemon-entry"

PRIMARY_OUT=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$PROJECT" --label synthetic-primary --no-focus)
PRIMARY_PANE=$(printf '%s' "$PRIMARY_OUT" | jq -r '.result.root_pane.pane_id')
PRIMARY_TARGET="$SESSION:$PRIMARY_PANE"
PI_CMD=$(printf 'exec env PI_CODING_AGENT_DIR=%q FM_HOME=%q FM_ROOT_OVERRIDE=%q FM_PI_CAPTURE_PATH=%q FM_PI_OWNERSHIP_POLL_MS=50 pi -e %q -e %q -e %q --no-context-files --no-session' \
  "$PI_DIR" "$HOME_DIR" "$ROOT" "$CAPTURE" "$CAPTURE_EXT" \
  "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ROOT/.pi/extensions/fm-primary-pi-watch.ts")
"$LAB_HELPER" run "$SESSION" pane run "$PRIMARY_PANE" "$PI_CMD" >/dev/null

wait_for() { # <shell predicate string> <message>
  local predicate=$1 message=$2 _
  for _ in $(seq 1 240); do
    if eval "$predicate"; then return 0; fi
    sleep 0.25
  done
  fail "$message"
}

wait_for_idle() {
  local stable=0 status _
  for _ in $(seq 1 240); do
    status=$("$LAB_HELPER" run "$SESSION" agent get "$PRIMARY_PANE" 2>/dev/null \
      | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
    case "$status" in
      idle|done|blocked) stable=$((stable + 1)); [ "$stable" -ge 4 ] && return 0 ;;
      *) stable=0 ;;
    esac
    sleep 0.25
  done
  return 1
}

wait_for_idle || fail "real Pi primary did not become stably idle"
wait_for '[ -s "$STATE/.pi-watch-extension-loaded" ] && [ -s "$STATE/.pi-turnend-extension-loaded" ]' \
  "tracked Pi supervision extensions did not load"

"$LAB_HELPER" run "$SESSION" pane send-text "$PRIMARY_PANE" '/fm-watch-arm-pi' >/dev/null
"$LAB_HELPER" run "$SESSION" pane send-keys "$PRIMARY_PANE" enter >/dev/null
wait_for '[ -s "$STATE/.watch.lock/pid" ]' "ordinary Pi watcher did not start"
ORDINARY_PID=$(cat "$STATE/.watch.lock/pid")
kill -0 "$ORDINARY_PID" 2>/dev/null || fail "ordinary Pi watcher was not live"

PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$PRIMARY_TARGET" FM_AFK_LAUNCH_ENTRY="$TMP_ROOT/daemon-entry" \
  "$ROOT/bin/fm-afk-launch.sh" start >/dev/null
DAEMON_STARTED=1
wait_for '[ -s "$STATE/.supervise-daemon.pid" ] && [ -s "$STATE/.pi-watch-away-standdown" ]' \
  "away daemon started without a Pi standdown receipt"
kill -0 "$ORDINARY_PID" 2>/dev/null && fail "ordinary Pi watcher remained live beside the away daemon"
wait_for '[ -s "$STATE/.watch.lock/pid" ] && [ "$(cat "$STATE/.watch.lock/pid")" != "$ORDINARY_PID" ]' \
  "away daemon did not establish its own watcher"
AWAY_PID=$(cat "$STATE/.watch.lock/pid")
kill -0 "$AWAY_PID" 2>/dev/null || fail "away daemon watcher was not live"
if [ -s "$CAPTURE" ] && jq -e 'select(.prompt | startswith("⁣FIRSTMATE_OP: v1 watcher:"))' "$CAPTURE" >/dev/null 2>&1; then
  fail "ordinary Pi watcher delivered a direct follow-up after away takeover"
fi
pass "real Pi ordinary supervision retires before the away daemon becomes sole owner"

PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$PRIMARY_TARGET" \
  "$ROOT/bin/fm-afk-launch.sh" stop >/dev/null
DAEMON_STARTED=0
wait_for '[ ! -e "$STATE/.afk" ] && [ ! -e "$STATE/.pi-watch-away-standdown" ]' \
  "away lifecycle did not clear before ordinary return"
wait_for '[ -s "$STATE/.watch.lock/pid" ] && [ "$(cat "$STATE/.watch.lock/pid")" != "$AWAY_PID" ]' \
  "Pi ordinary watcher did not return"
RETURN_PID=$(cat "$STATE/.watch.lock/pid")
kill -0 "$RETURN_PID" 2>/dev/null || fail "returned Pi watcher was not live"

# A redundant arm command must preserve the same singleton.
"$LAB_HELPER" run "$SESSION" pane send-text "$PRIMARY_PANE" '/fm-watch-arm-pi' >/dev/null
"$LAB_HELPER" run "$SESSION" pane send-keys "$PRIMARY_PANE" enter >/dev/null
sleep 1
[ "$(cat "$STATE/.watch.lock/pid")" = "$RETURN_PID" ] || fail "away return created more than one ordinary cycle"
if [ -s "$CAPTURE" ] && jq -e 'select(.prompt | startswith("⁣FIRSTMATE_OP: v1 watcher:"))' "$CAPTURE" >/dev/null 2>&1; then
  fail "away return replayed a direct watcher follow-up"
fi
pass "real Pi away return restores exactly one ordinary cycle with no replayed turn"

printf 'evidence: herdr-session=%s pi=%s ordinary=%s away=%s returned=%s\n' \
  "$SESSION" "$(pi --version)" "$ORDINARY_PID" "$AWAY_PID" "$RETURN_PID"
