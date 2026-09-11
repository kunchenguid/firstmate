#!/usr/bin/env bash
# Real Pi/Herdr end-to-end regression for the away posture on Pi.
#
# Opt-in because it launches a real interactive Pi primary and a real isolated
# Herdr lab session. Real side effects and heavyweight lab setup put it outside
# the token-free default-on class, so it does not run merely because its tools
# are installed. Every explicit and production-adapter Herdr call is routed
# through fm-herdr-lab.sh. The scenario proves, against a real Pi primary:
#   - the away daemon is never launched on Pi: `start` refuses and `confirm`
#     records the posture with no daemon terminal, pid, or flag;
#   - a real Pi draft is never touched by away mode (nothing injects on Pi);
#   - an unmarked return request is recognized as the return, opens the
#     catch-up gate before Bearings on the live blocker, and renders the brief;
#   - remediation/resolution clears the gate, and re-entry is idempotent.
# The 2026-07-14 two-owner incident's daemon-injection assertions retired with
# the daemon on Pi; the daemon transport keeps its coverage in
# tests/fm-afk-inject-herdr-e2e.test.sh for the harnesses that still run it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_AFK_PI_HERDR_E2E herdr jq pi python3

# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervise-daemon.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name fm-afk-pi-return-e2e)
TMP_ROOT=$(fm_test_tmproot fm-afk-pi-return-e2e)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
PROJECT="$TMP_ROOT/project"
PI_DIR="$TMP_ROOT/pi-agent"
FAKEBIN="$TMP_ROOT/fakebin"
CAPTURE="$TMP_ROOT/pi-prompts.jsonl"
ORIGINAL_PATH=$PATH
unset CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI ATLASSIAN_AGENT_TYPE ROVODEV_CLI CLAUDECODE
PRIMARY_PANE=
CHILD_PANE=
PRIMARY_TARGET=

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -f "$STATE/.afk-contract" ] || [ -e "$STATE/.afk" ]; then
    PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
      PI_CODING_AGENT=true "$ROOT/bin/fm-afk-launch.sh" stop >/dev/null 2>&1 || true
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

# A task-local extension grants session-only trust, captures exact submitted
# input bytes through Pi's `input` hook and marks them handled, so no provider,
# model, or credential is ever involved (the lab agent dir has none), and it
# aborts as a backstop should a turn ever start. No production supervision
# extension is loaded in this synthetic primary, so nothing except the test can
# mutate fleet state.
CAPTURE_EXT="$TMP_ROOT/capture-extension.ts"
cat > "$CAPTURE_EXT" <<'EOF'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync } from "node:fs";
const capturePath = process.env.FM_PI_CAPTURE_PATH!;
export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("input", (event) => {
    appendFileSync(capturePath, `${JSON.stringify({ prompt: event.text, hex: Buffer.from(event.text, "utf8").toString("hex") })}\n`);
    return { action: "handled" };
  });
  pi.on("before_agent_start", (event, ctx) => {
    appendFileSync(capturePath, `${JSON.stringify({ prompt: event.prompt, hex: Buffer.from(event.prompt, "utf8").toString("hex") })}\n`);
    ctx.abort();
  });
}
EOF

# Route production adapter invocations through the guarded helper too. The shim
# removes only the adapter's validated trailing pair, then the helper appends it.
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


PRIMARY_OUT=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$PROJECT" --label synthetic-primary --no-focus)
WORKSPACE=$(printf '%s' "$PRIMARY_OUT" | jq -r '.result.workspace.workspace_id')
PRIMARY_PANE=$(printf '%s' "$PRIMARY_OUT" | jq -r '.result.root_pane.pane_id')
PRIMARY_TARGET="$SESSION:$PRIMARY_PANE"
EXT="$CAPTURE_EXT"
PI_CMD=$(printf 'exec env PI_CODING_AGENT_DIR=%q FM_HOME=%q FM_PI_CAPTURE_PATH=%q pi -e %q --no-context-files --no-session' "$PI_DIR" "$HOME_DIR" "$CAPTURE" "$EXT")
"$LAB_HELPER" run "$SESSION" pane run "$PRIMARY_PANE" "$PI_CMD" >/dev/null

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

wait_for_prompt() {  # <jq predicate>
  local predicate=$1 _
  for _ in $(seq 1 240); do
    if [ -s "$CAPTURE" ] && jq -s -e "$predicate" "$CAPTURE" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_for_idle || fail "real Pi primary did not become stably idle"

assert_blocker_open() {
  local at=$1 open
  open=$(status_open_decisions "$STATE/repair-task.status")
  printf '%s' "$open" | grep -F $'synthetic-dependency\tblocked\t' >/dev/null \
    || fail "live blocked decision disappeared $at: status=$(cat "$STATE/repair-task.status" 2>/dev/null)"
}

CHILD_OUT=$("$LAB_HELPER" run "$SESSION" tab create --workspace "$WORKSPACE" --cwd "$PROJECT" --label fm-repair-task --no-focus)
CHILD_PANE=$(printf '%s' "$CHILD_OUT" | jq -r '.result.root_pane.pane_id')
CHILD_TARGET="$SESSION:$CHILD_PANE"
cat > "$STATE/repair-task.meta" <<EOF
window=$CHILD_TARGET
backend=herdr
kind=ship
mode=no-mistakes
worktree=$PROJECT
project=synthetic-project
EOF
fm_test_write_tasks_config "$HOME_DIR"
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight
- [ ] repair-task - Repair the synthetic dependency (repo: synthetic-project, since 2026-07-14)

## Queued

## Done
EOF

# The away daemon is never launched on Pi. The launcher detects the primary
# harness from its own ancestry in production; this test process is not under
# Pi, so it supplies Pi's verified PI_CODING_AGENT environment marker.
set +e
START_OUT=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  PI_CODING_AGENT=true FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$PRIMARY_TARGET" \
  "$ROOT/bin/fm-afk-launch.sh" start 2>&1)
START_RC=$?
set -e
[ "$START_RC" -ne 0 ] || fail "the away daemon launched on a Pi primary"
assert_contains "$START_OUT" 'the away daemon is no longer launched on pi' "the Pi refusal did not name its reason"
PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  PI_CODING_AGENT=true "$ROOT/bin/fm-afk-launch.sh" propose >/dev/null || fail "the away posture read-back failed on Pi"
CONFIRM_OUT=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  PI_CODING_AGENT=true "$ROOT/bin/fm-afk-launch.sh" confirm 2>&1) || fail "the away posture could not be recorded on Pi: $CONFIRM_OUT"
assert_contains "$CONFIRM_OUT" 'hold-for-return only' "the entry announcement did not say hold-for-return"
[ -f "$STATE/.afk-contract" ] || fail "confirm did not write the away-posture record"
[ ! -e "$STATE/.afk" ] || fail "confirm wrote the daemon flag on Pi"
[ ! -e "$STATE/.afk-daemon-terminal" ] || fail "confirm recorded a daemon terminal on Pi"
sleep 2
[ ! -s "$STATE/.supervise-daemon.pid" ] || fail "an away daemon started on Pi"
pass "real Pi primary: the away posture is recorded with no daemon launched"

# A real draft in Pi and a live blocker from the child: with no daemon on Pi,
# nothing is typed into the captain's pane and the draft survives untouched.
"$LAB_HELPER" run "$SESSION" pane send-text "$PRIMARY_PANE" 'privacy safe human draft' >/dev/null
sleep 0.5
composer=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" fm_backend_composer_state herdr "$PRIMARY_TARGET")
[ "$composer" = pending ] || fail "real Pi draft did not classify pending (got $composer)"
CHILD_CMD=$(printf "printf 'blocked [key=synthetic-dependency]: firstmate can refresh the synthetic token\\n' >> %q; exec sleep 120" "$STATE/repair-task.status")
"$LAB_HELPER" run "$SESSION" pane run "$CHILD_PANE" "$CHILD_CMD" >/dev/null
for _ in $(seq 1 40); do grep -q 'synthetic-dependency' "$STATE/repair-task.status" 2>/dev/null && break; sleep 0.1; done
assert_blocker_open 'after the child declared it'
sleep 3
[ ! -s "$CAPTURE" ] || fail "something submitted into Pi while the away posture stood with no daemon"
plain=$("$LAB_HELPER" run "$SESSION" pane read "$PRIMARY_PANE" --source recent --lines 200)
printf '%s' "$plain" | grep -F 'privacy safe human draft' >/dev/null || fail "the pending Pi draft was modified or submitted"
[ ! -e "$STATE/.subsuper-inject-wedged" ] || fail "a daemon wedge marker appeared with no daemon on Pi"
pass "real Pi/Herdr: nothing injects into the captain pane under the away posture"

# Clear, never submit, the synthetic human draft; then the captain returns with
# an ordinary unmarked Bearings request, captured byte-exact.
"$LAB_HELPER" run "$SESSION" pane send-keys "$PRIMARY_PANE" ctrl+c >/dev/null
wait_for_idle || fail "real Pi did not return idle after clearing the draft"
for _ in $(seq 1 80); do
  composer=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" fm_backend_composer_state herdr "$PRIMARY_TARGET")
  [ "$composer" = empty ] && break
  sleep 0.1
done
[ "$composer" = empty ] || fail "real Pi composer was not ready for the unmarked return request"
# Type once, then submit with Enter retried until Pi starts the turn, the same
# Enter-only retry the production submit primitive uses (a lone Enter on a
# freshly typed Pi composer can be swallowed while the composer settles).
"$LAB_HELPER" run "$SESSION" pane send-text "$PRIMARY_PANE" 'Synthetic Bearings request' >/dev/null
sleep 0.5
RETURN_SEEN=0
for _ in $(seq 1 6); do
  "$LAB_HELPER" run "$SESSION" pane send-keys "$PRIMARY_PANE" enter >/dev/null
  for _ in $(seq 1 40); do
    if [ -s "$CAPTURE" ] && jq -s -e 'any(.[]; .prompt == "Synthetic Bearings request")' "$CAPTURE" >/dev/null 2>&1; then
      RETURN_SEEN=1
      break
    fi
    sleep 0.25
  done
  [ "$RETURN_SEEN" -eq 1 ] && break
done
[ "$RETURN_SEEN" -eq 1 ] || fail "real Pi did not receive the unmarked return request; agent=$("$LAB_HELPER" run "$SESSION" agent get "$PRIMARY_PANE" 2>/dev/null | jq -c '.result.agent // empty' 2>/dev/null); pane: $("$LAB_HELPER" run "$SESSION" pane read "$PRIMARY_PANE" --source recent --lines 40 2>/dev/null)"
RETURN_PROMPT=$(jq -r 'select(.prompt == "Synthetic Bearings request") | .prompt' "$CAPTURE" | tail -1)
should_exit_afk "$STATE" "$RETURN_PROMPT" || fail "unmarked Pi return request did not trigger the away exit contract"
assert_blocker_open 'before return catch-up'
[ -f "$STATE/repair-task.meta" ] || fail "live blocker metadata disappeared before return catch-up"

set +e
RETURN_OUT=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_ROOT_OVERRIDE="$PROJECT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  PI_CODING_AGENT=true "$ROOT/bin/fm-afk-return.sh" begin 2>&1)
RETURN_RC=$?
set -e
[ "$RETURN_RC" -eq 3 ] || fail "return catch-up did not gate the still-live blocker (rc=$RETURN_RC): $RETURN_OUT"
assert_contains "$RETURN_OUT" 'firstmate-actionable blocker: repair-task [key=synthetic-dependency]' "return gate did not assign remediation"
assert_contains "$RETURN_OUT" '=== Return brief (away ' "the return did not render the brief"
assert_contains "$RETURN_OUT" 'Supervisor health:' "the brief did not lead with supervisor health"
[ ! -f "$STATE/.afk-contract" ] || fail "the return did not archive the away-posture record"
set +e
BEARINGS_OUT=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_ROOT_OVERRIDE="$PROJECT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  "$ROOT/bin/fm-bearings-snapshot.sh" --json 2>&1)
BEARINGS_RC=$?
set -e
[ "$BEARINGS_RC" -eq 3 ] || fail "Bearings bypassed the return gate (rc=$BEARINGS_RC): $BEARINGS_OUT"
pass "real unmarked Pi return renders the brief, opens catch-up, and blocks Bearings before the unresolved blocker can be deferred"

printf 'resolved [key=synthetic-dependency]: refreshed the synthetic token and resumed the task\n' >> "$STATE/repair-task.status"
PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_ROOT_OVERRIDE="$PROJECT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  "$ROOT/bin/fm-afk-return.sh" check >/dev/null || fail "remediated blocker did not clear return catch-up"
PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_ROOT_OVERRIDE="$PROJECT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  "$ROOT/bin/fm-bearings-snapshot.sh" --json >/dev/null || fail "Bearings remained gated after blocker remediation"

# A clean re-entry records a fresh posture, and an immediate return is
# idempotently clear because the keyed blocker is resolved.
PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  PI_CODING_AGENT=true "$ROOT/bin/fm-afk-launch.sh" propose >/dev/null || fail "clean away re-entry read-back failed"
PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  PI_CODING_AGENT=true "$ROOT/bin/fm-afk-launch.sh" confirm >/dev/null || fail "clean away re-entry failed"
PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_ROOT_OVERRIDE="$PROJECT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  PI_CODING_AGENT=true "$ROOT/bin/fm-afk-return.sh" begin >/dev/null \
  || fail "clean away re-entry/return was not idempotent"
[ "$(find "$STATE/afk-contracts" -name '*.afk-contract' | wc -l | tr -d ' ')" -eq 2 ] || fail "each away window did not leave exactly one archived record"
pass "resolved return catch-up allows Bearings and a clean idempotent away re-entry"

printf 'evidence: herdr=%s pi=%s target=%s archived-records=2\n' \
  "$(herdr --version)" "$(pi --version)" "$PRIMARY_TARGET"
