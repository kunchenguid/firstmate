#!/usr/bin/env bash
# tests/fm-rex-secondmate-e2e.test.sh - real Pi/Rex guard for a secondmate on
# the rex backend, the Rex counterpart of
# tests/fm-send-secondmate-marker-herdr-e2e.test.sh. A real
# `fm-spawn.sh --secondmate --backend rex` launch stands the secondmate up in
# its own `fm-<id>` session as that session's first tab, an exact-id
# fm-send stores its request and rings that secondmate's doorbell, a destroyed
# endpoint is proven gone and respawned into the SAME recorded session, and
# closing the secondmate retires that session.
#
# Opt-in (FM_REX_SECONDMATE_E2E=1) because it launches a real interactive Pi.
# A session-only Pi extension records before_agent_start prompts and aborts
# before any provider request, so no model tokens are spent. Every Rex call
# runs on a private lab server provisioned through bin/fm-rex-lab.sh, whose
# tripwire proves the live Rex server was left untouched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"

fm_live_gate opt-in FM_REX_SECONDMATE_E2E git rex jq pi

unset TMUX TMUX_PANE HERDR_ENV REX_SESSION REX_BLOCK REX_SERVER REX_CLIENT FM_BACKEND_REX_SERVER 2>/dev/null || true

LAB_HELPER="$ROOT/bin/fm-rex-lab.sh"
LAB=$("$LAB_HELPER" name secondmate)
TMP_ROOT=$(fm_test_tmproot fm-rex-secondmate-e2e)
REX_VERSION=$(rex version 2>/dev/null | head -1)
SENDER_HOME="$TMP_ROOT/sender-home"
SECOND_HOME="$TMP_ROOT/secondmate-home"
CAPTURE="$TMP_ROOT/pi-before-agent.jsonl"
FAKEBIN="$TMP_ROOT/fakebin"
REAL_PI=$(command -v pi)
ID='rex-sm'
REQUEST='FM_REX_SECONDMATE_E2E exact-id request'

cleanup() {
  "$LAB_HELPER" teardown "$LAB" || printf 'not ok - the Rex lab teardown or its live-server tripwire failed\n' >&2
}
trap cleanup EXIT

e2e_fail() { fail "$1 ($REX_VERSION; pi $("$REAL_PI" --version 2>/dev/null | head -1))"; }

"$LAB_HELPER" provision "$LAB" || e2e_fail "could not provision a private Rex lab server"
FM_REX_SERVER=$("$LAB_HELPER" server "$LAB")
export FM_REX_SERVER

mkdir -p "$SENDER_HOME/state" "$SENDER_HOME/data" "$SENDER_HOME/config" "$SENDER_HOME/projects" "$FAKEBIN"
git clone -q --no-hardlinks "$ROOT" "$SECOND_HOME"
git -C "$SECOND_HOME" checkout -q --detach HEAD
mkdir -p "$SECOND_HOME/state" "$SECOND_HOME/data" "$SECOND_HOME/config" "$SECOND_HOME/projects"
printf '%s\n' "$ID" >"$SECOND_HOME/.fm-secondmate-home"
cat >"$SECOND_HOME/data/charter.md" <<'EOF'
# Isolated Rex secondmate

You are a task-local secondmate used only for the Rex secondmate regression.
Stay idle and do not initiate work.
EOF

CAPTURE_JSON=$(printf '%s' "$CAPTURE" | jq -Rs .)
CAPTURE_EXTENSION="$TMP_ROOT/fm-rex-secondmate-capture.ts"
cat >"$CAPTURE_EXTENSION" <<EOF
import { appendFileSync } from "node:fs";
const capturePath = $CAPTURE_JSON;
export default function (pi: any) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("before_agent_start", (event, ctx) => {
    appendFileSync(capturePath, \`\${JSON.stringify({ prompt: event.prompt })}\\n\`);
    ctx.abort();
  });
}
EOF
printf '#!/usr/bin/env bash\nexec %q -e %q "$@"\n' "$REAL_PI" "$CAPTURE_EXTENSION" >"$FAKEBIN/pi"
chmod +x "$FAKEBIN/pi"

spawn_secondmate() { # [id] [home]
  PATH="$FAKEBIN:$PATH" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$SENDER_HOME" \
    "$ROOT/bin/fm-spawn.sh" "${1:-$ID}" "${2:-$SECOND_HOME}" --secondmate --harness pi --backend rex >/dev/null
}

wait_for_prompt() { # <needle>
  local _
  for _ in $(seq 1 240); do
    [ -s "$CAPTURE" ] && jq -e --arg n "$1" 'select(.prompt | contains($n))' "$CAPTURE" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  return 1
}

wait_for_settled() {
  local screen last='' stable=0 _
  for _ in $(seq 1 240); do
    screen=$(fm_backend_rex_capture "$TARGET" 40 "fm-$ID" 2>/dev/null || true)
    if [[ "$screen" == *'operation was aborted'* ]] && [ "$screen" = "$last" ]; then
      stable=$((stable + 1))
      [ "$stable" -ge 4 ] && return 0
    else
      stable=0
    fi
    last=$screen
    sleep 0.25
  done
  return 1
}

# All adapter reads below run as the sender home, like the parent firstmate.
export FM_HOME="$SENDER_HOME" STATE="$SENDER_HOME/state"
fm_backend_source rex || e2e_fail "could not source the rex adapter"
META="$STATE/$ID.meta"

spawn_secondmate || e2e_fail "fm-spawn --secondmate --backend rex failed"
[ "$(fm_meta_get "$META" backend)" = rex ] || e2e_fail "the secondmate record does not name backend=rex"
[ "$(fm_meta_get "$META" rex_server)" = "$FM_REX_SERVER" ] || e2e_fail "the secondmate record does not pin the lab server"
TARGET=$(fm_backend_target_of_meta "$META")
SID=${TARGET%%:*}
VIEW=$(fm_backend_rex_cli session inspect "session:$SID" --json) || e2e_fail "the recorded session cannot be read"
[ "$(printf '%s' "$VIEW" | jq -r .label)" = "fm-$ID" ] || e2e_fail "the secondmate session is not labeled fm-$ID"
[ "$(printf '%s' "$VIEW" | jq -r '.windows[0].window_id')" = "window:$(fm_meta_get "$META" rex_window_id)" ] \
  || e2e_fail "the secondmate pane is not its session's first tab"
fm_backend_rex_target_ready "$TARGET" "fm-$ID" || e2e_fail "the secondmate block does not carry the parent's scoped label"
pass "real Pi/Rex: --secondmate opens the first tab of its own fm-<id> session, labeled for the parent home"

wait_for_prompt 'Isolated Rex secondmate' || e2e_fail "the secondmate never received its charter"
# Rex has no native idle signal, so wait until Pi has rendered the charter
# turn's abort and its screen stays unchanged: a doorbell typed while that
# aborting turn is still in flight is queued and dropped with it.
wait_for_settled || e2e_fail "the secondmate never settled after its charter abort"
SEND_OUT=$(PATH="$FAKEBIN:$PATH" FM_GATE_REFUSE_BYPASS=1 "$ROOT/bin/fm-send.sh" "$ID" "$REQUEST" 2>&1) \
  || e2e_fail "fm-send to the rex secondmate failed: $SEND_OUT"
# fm-send stores the request as a durable inbox record and rings the agent with
# one constant doorbell line (bin/fm-task-inbox-lib.sh).
wait_for_prompt 'Firstmate instruction waiting' || e2e_fail "the secondmate never received the doorbell; fm-send said: $(printf '%s' "$SEND_OUT" | grep -v '^●' | tail -5); screen: $(fm_backend_rex_capture "$TARGET" 12 "fm-$ID")"
GOT=$(jq -r 'select(.prompt | contains("Firstmate instruction waiting")) | .prompt' "$CAPTURE" | tail -1)
assert_contains "$GOT" "'$ID.inbox' steering inbox" "the doorbell should name this secondmate's own inbox"
grep -rlF -- "$REQUEST" "$SENDER_HOME/state" "$SECOND_HOME/state" 2>/dev/null | grep -q '\.inbox/.*\.msg$' \
  || e2e_fail "the exact-id request was not stored as a durable inbox record"
pass "real Pi/Rex: an exact-id fm-send stores the request and rings the secondmate with its inbox doorbell"

FIRST_BLOCK=$(fm_meta_get "$META" rex_block_id)
fm_backend_rex_cli block close -s "session:$SID" "block:$FIRST_BLOCK" >/dev/null 2>&1 || true
[ "$(fm_backend_agent_state rex "$TARGET")" = missing ] || e2e_fail "a closed secondmate block does not read missing"
VERDICT=$(fm_control_endpoint_absence_verdict rex "$TARGET" 2>/dev/null || true)
[ "${VERDICT%%$'\t'*}" = gone ] || e2e_fail "the closed secondmate endpoint was not proven gone: $VERDICT"
spawn_secondmate || e2e_fail "the respawn of a destroyed rex secondmate failed"
TARGET2=$(fm_backend_target_of_meta "$META")
[ "${TARGET2%%:*}" = "$SID" ] || e2e_fail "the respawn did not reuse the recorded fm-$ID session"
[ "${TARGET2#*:}" != "$FIRST_BLOCK" ] || e2e_fail "the respawn did not mint a new block"
[ "$(fm_backend_rex_cli session inspect "session:$SID" --json | jq -r '.windows[0].window_id')" = "window:$(fm_meta_get "$META" rex_window_id)" ] \
  || e2e_fail "the respawned secondmate is not its session's first tab"
pass "real Pi/Rex: a destroyed secondmate endpoint is proven gone and respawns into its recorded session"

fm_backend_kill rex "$TARGET2" "" "fm-$ID" || e2e_fail "closing the secondmate endpoint failed"
fm_backend_rex_cli session inspect "session:$SID" --json >/dev/null 2>&1
[ "$?" -eq 3 ] || e2e_fail "the emptied fm-$ID session was not retired with its secondmate"
pass "real Pi/Rex: closing the secondmate retires its emptied session"

# One fm-teardown run must retire a Rex secondmate completely: its pane, its
# fm-<id> session, its home, its registry route, and every record naming it, so
# no cleanup is left that needs a second teardown. A fresh secondmate is used so
# the exact-id request above leaves no unresolved routed reply to refuse it.
RETIRE_ID='rex-sm-retire'
RETIRE_HOME="$TMP_ROOT/secondmate-home-retire"
git clone -q --no-hardlinks "$ROOT" "$RETIRE_HOME"
git -C "$RETIRE_HOME" checkout -q --detach HEAD
mkdir -p "$RETIRE_HOME/state" "$RETIRE_HOME/data" "$RETIRE_HOME/config" "$RETIRE_HOME/projects"
printf '%s\n' "$RETIRE_ID" >"$RETIRE_HOME/.fm-secondmate-home"
cp "$SECOND_HOME/data/charter.md" "$RETIRE_HOME/data/charter.md" 2>/dev/null \
  || printf '# Isolated Rex secondmate\n\nStay idle and do not initiate work.\n' >"$RETIRE_HOME/data/charter.md"
printf -- '- %s - Rex retire regression (home: %s; scope: retire; projects: none; added 2026-10-22)\n' \
  "$RETIRE_ID" "$RETIRE_HOME" >>"$SENDER_HOME/data/secondmates.md"
spawn_secondmate "$RETIRE_ID" "$RETIRE_HOME" || e2e_fail "the second rex secondmate did not launch"
RETIRE_TARGET=$(fm_backend_target_of_meta "$STATE/$RETIRE_ID.meta")
RETIRE_SID=${RETIRE_TARGET%%:*}
fm_backend_rex_cli session inspect "session:$RETIRE_SID" --json >/dev/null 2>&1 \
  || e2e_fail "the second rex secondmate has no live fm-$RETIRE_ID session to retire"
TEARDOWN_OUT=$(PATH="$FAKEBIN:$PATH" FM_GATE_REFUSE_BYPASS=1 "$ROOT/bin/fm-teardown.sh" "$RETIRE_ID" 2>&1) \
  || e2e_fail "one fm-teardown run did not retire the rex secondmate: $TEARDOWN_OUT"
fm_backend_rex_cli session inspect "session:$RETIRE_SID" --json >/dev/null 2>&1
[ "$?" -eq 3 ] || e2e_fail "the retired secondmate's fm-$RETIRE_ID session survived its only teardown run"
assert_absent "$RETIRE_HOME" "the retired secondmate home survived its only teardown run"
assert_no_grep "^- $RETIRE_ID " "$SENDER_HOME/data/secondmates.md" "the retired secondmate route survived its only teardown run"
LEFTOVERS=$(find "$STATE" -name "$RETIRE_ID*" 2>/dev/null)
[ -z "$LEFTOVERS" ] || e2e_fail "records naming the retired secondmate survived its only teardown run: $LEFTOVERS"
pass "real Pi/Rex: a single fm-teardown retires the secondmate, its session, home, route, and records"
