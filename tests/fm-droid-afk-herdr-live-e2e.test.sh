#!/usr/bin/env bash
# Real Droid/Herdr end-to-end guard for away-mode escalation delivery.
#
# Opt-in because it launches a real interactive Droid primary, spends model
# tokens, and provisions an isolated Herdr session through fm-herdr-lab.sh.
# Every explicit and production-adapter Herdr call is routed through the lab
# helper, and teardown verifies that the live default session was untouched.
# The scenario proves the current vendor-rendered Droid status footer is an
# affirmatively empty composer, ordinary fm-send uses the same verified submit
# transport, the native session continuation surface does not address the
# already-running interactive pane, and a buffered escalation survives pending
# text plus max-defer before delivering exactly through the shared idle guard.
# It also drives the tracked Droid-only AskUser guard: the same independently
# authorized turn continues after an AFK denial, the keyed approval remains
# durable, return catch-up presents it, and AskUser becomes interactive only
# after the real return lifecycle removes the AFK flag.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_DROID_AFK_HERDR_E2E:-0}" != 1 ]; then
  echo "skip: set FM_DROID_AFK_HERDR_E2E=1 to run the real Droid/Herdr away-delivery regression"
  exit 0
fi

for tool in droid herdr jq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $LAB_HELPER"; exit 0; }

# Droid's runtime-wide hook registration must be provably untouched by this
# probe, so the fingerprint is taken before anything in this file can launch
# Droid. It records only presence, a digest, and the hook subtree that this
# feature could leak into; no other setting, token, or credential value is read.
#
# A real interactive Droid launch rewrites vendor-managed fields in
# ~/.factory/settings.json on its own, so the whole-file digest is reported
# rather than asserted. The hook subtree and permissions file are the isolation
# claim, and those must be identical.
droid_global_fingerprint() {  # <mode: hooks|whole>
  local file base
  for file in "$HOME/.factory/settings.json" "$HOME/.factory/permissions.json"; do
    base=$(basename "$file")
    if [ ! -e "$file" ]; then
      printf '%s absent\n' "$base"
    elif [ "$1" = whole ]; then
      printf '%s present %s\n' "$base" "$(shasum -a 256 < "$file" | awk '{print $1}')"
    else
      printf '%s hooks %s\n' "$base" "$(jq -S -c '.hooks // null' "$file" 2>/dev/null || printf unreadable)"
    fi
  done
}

if [ "${FM_DROID_AFK_HERDR_PHASE:-orchestrate}" = orchestrate ]; then
  GLOBAL_HOOKS_BEFORE=$(droid_global_fingerprint hooks)
  GLOBAL_WHOLE_BEFORE=$(droid_global_fingerprint whole)
  SESSION=$("$LAB_HELPER" name afk-droid-approval-deferral-f1)
  TMP_ROOT=$(fm_test_tmproot fm-droid-afk-herdr-e2e)
  ORIGINAL_PATH=$PATH
  LAB_PROVISIONED=0
  SCENARIO_FINISHED=0
  SCENARIO_RC=1

  # shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
  orchestrator_cleanup() {
    local rc=$? remaining
    trap - EXIT
    [ "$SCENARIO_FINISHED" -eq 1 ] && rc=$SCENARIO_RC
    if [ "$LAB_PROVISIONED" -eq 1 ]; then
      if "$LAB_HELPER" teardown "$SESSION"; then
        remaining=$("$LAB_HELPER" run "$SESSION" session list --json 2>/dev/null \
          | jq -r --arg session "$SESSION" 'any(.sessions[]?; .name == $session)' 2>/dev/null || true)
        [ "$remaining" = false ] || {
          echo "not ok - guarded teardown returned success but lab session $SESSION remains" >&2
          rc=1
        }
        [ "$remaining" != false ] \
          || pass "guarded teardown deletes the isolated Herdr session after the scenario process exits"
      else
        echo "not ok - guarded teardown failed after the live scenario process exited; lab session $SESSION may remain" >&2
        rc=1
      fi
    fi
    [ "$rc" -ne 0 ] || rm -rf "$TMP_ROOT"
    exit "$rc"
  }
  trap orchestrator_cleanup EXIT
  "$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
  LAB_PROVISIONED=1

  FM_DROID_AFK_HERDR_PHASE=scenario \
    FM_DROID_AFK_HERDR_SESSION="$SESSION" \
    FM_DROID_AFK_HERDR_TMP_ROOT="$TMP_ROOT" \
    FM_DROID_AFK_HERDR_ORIGINAL_PATH="$ORIGINAL_PATH" \
    HERDR_LAB_HELPER="$LAB_HELPER" \
    "$0"
  SCENARIO_RC=$?
  SCENARIO_FINISHED=1
  if [ "$GLOBAL_HOOKS_BEFORE" = "$(droid_global_fingerprint hooks)" ]; then
    pass "the isolated live probe left Droid's runtime-wide hook registration unchanged"
  else
    echo "not ok - the isolated live probe changed Droid's runtime-wide hook registration" >&2
    SCENARIO_RC=1
  fi
  if [ "$GLOBAL_WHOLE_BEFORE" != "$(droid_global_fingerprint whole)" ]; then
    echo "# observed: a real Droid launch rewrote vendor-managed fields in ~/.factory/settings.json; the hook subtree above is the isolation claim" >&2
  fi
  exit "$SCENARIO_RC"
fi

SESSION=${FM_DROID_AFK_HERDR_SESSION:?scenario requires its lab session}
TMP_ROOT=${FM_DROID_AFK_HERDR_TMP_ROOT:?scenario requires its temporary root}
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
PROJECT="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
NOTIFY_LOG="$TMP_ROOT/wedge-notify.log"
ORIGINAL_PATH=${FM_DROID_AFK_HERDR_ORIGINAL_PATH:?scenario requires its original PATH}
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
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$HOME_DIR"/{state,data,config,projects} "$PROJECT/.factory" "$FAKEBIN"
git init -q "$PROJECT"
printf '%s\n' '# Synthetic isolated Firstmate Droid primary' > "$PROJECT/AGENTS.md"
# The guard files questions through the tracked decision owner, so the isolated
# project reaches the real bin/ rather than a copied subset of it. Scope and
# state stay isolated through FM_ROOT_OVERRIDE and FM_STATE_OVERRIDE below.
ln -s "$ROOT/bin" "$PROJECT/bin"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"

cat > "$PROJECT/.factory/sessionstart.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
printf '%s\n' "$payload" >> .factory/sessionstart-payloads.jsonl
printf '%s' "$payload" | jq -r '.session_id' > .factory/live-session-id
printf '%s\n' 'For startup verification, reply exactly DROID_SESSIONSTART_HOOK_7C91.'
SH

cat > "$PROJECT/.factory/userprompt.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
printf '%s\n' "$payload" >> .factory/userprompt-payloads.jsonl
if printf '%s' "$payload" | jq -e '.prompt | contains("DROID_ORDINARY_SEND_PROBE")' >/dev/null; then
  printf '%s\n' 'After completing the requested action, reply exactly DROID_USERPROMPT_HOOK_6B42.'
fi
SH

cat > "$PROJECT/.factory/askuser.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
printf '%s\n' "$payload" >> .factory/askuser-payloads.jsonl
printf '%s' "$payload" | "$DROID_PROJECT_DIR/bin/fm-droid-afk-askuser-check.sh"
SH

cat > "$PROJECT/.factory/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "bash .factory/sessionstart.sh"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "bash .factory/userprompt.sh"}]}],
    "PreToolUse": [{"matcher": "AskUser", "hooks": [{"type": "command", "command": "bash .factory/askuser.sh"}]}]
  }
}
JSON

chmod +x "$PROJECT/.factory/sessionstart.sh" "$PROJECT/.factory/userprompt.sh" \
  "$PROJECT/.factory/askuser.sh"

# Route adapter-owned Herdr calls through the same guarded lab helper as every
# explicit call below. The shim accepts only this test's exact trailing session
# pair, strips it, and lets the helper append the required pair itself.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -lt 2 ] || [ "\${args[\$((n-2))]}" != --session ]; then
  echo 'wrapper requires an explicit trailing lab session' >&2
  exit 98
fi
[ "\${args[\$((n-1))]}" = "\$session" ] || { echo 'wrapper refused foreign session' >&2; exit 97; }
args=("\${args[@]:0:\$((n-2))}")
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

cat > "$TMP_ROOT/wedge-recorder" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\n' "\$1" "\$2" >> '$NOTIFY_LOG'
EOF
chmod +x "$TMP_ROOT/wedge-recorder"

cat > "$PROJECT/.factory/return-probe.sh" <<EOF
#!/usr/bin/env bash
export PATH='$FAKEBIN:$ORIGINAL_PATH'
export HERDR_SESSION='$SESSION'
export FM_ROOT_OVERRIDE='$ROOT'
export FM_HOME='$HOME_DIR'
export FM_STATE_OVERRIDE='$STATE'
export FM_SUPERVISOR_BACKEND=herdr
export FM_SUPERVISOR_TARGET='$SESSION:__PRIMARY_PANE__'
exec '$ROOT/bin/fm-afk-return.sh' begin
EOF
chmod +x "$PROJECT/.factory/return-probe.sh"

cat > "$TMP_ROOT/daemon-entry" <<EOF
#!/usr/bin/env bash
export PATH='$FAKEBIN:$ORIGINAL_PATH'
export HERDR_SESSION='$SESSION'
export FM_ROOT_OVERRIDE='$ROOT'
export FM_HOME='$HOME_DIR'
export FM_STATE_OVERRIDE='$STATE'
export FM_SUPERVISOR_BACKEND=herdr
export FM_SUPERVISOR_TARGET='$SESSION:__PRIMARY_PANE__'
export FM_DAEMON_PRIMARY_HARNESS=droid
export FM_ESCALATE_BATCH_SECS=0
export FM_HOUSEKEEPING_TICK=1
export FM_POLL=1
export FM_SIGNAL_GRACE=1
export FM_HEARTBEAT=999999
export FM_CHECK_INTERVAL=999999
export FM_MAX_DEFER_SECS=3
export FM_STALE_ESCALATE_SECS=999999
export FM_WEDGE_ALARM_EXEC='$TMP_ROOT/wedge-recorder'
exec '$ROOT/bin/fm-afk-start.sh'
EOF
chmod +x "$TMP_ROOT/daemon-entry"

PRIMARY_OUT=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$PROJECT" --label droid-afk-primary --no-focus) \
  || fail "could not create the isolated Droid workspace"
PRIMARY_PANE=$(printf '%s' "$PRIMARY_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PRIMARY_PANE" ] || fail "Herdr workspace creation did not return a root pane"
PRIMARY_TARGET="$SESSION:$PRIMARY_PANE"
sed -i.bak "s/__PRIMARY_PANE__/$PRIMARY_PANE/" "$TMP_ROOT/daemon-entry"
rm -f "$TMP_ROOT/daemon-entry.bak"
sed -i.bak "s/__PRIMARY_PANE__/$PRIMARY_PANE/" "$PROJECT/.factory/return-probe.sh"
rm -f "$PROJECT/.factory/return-probe.sh.bak"

DROID_PROMPT='Follow the exact startup verification instruction supplied by the SessionStart hook.'
DROID_CMD=$(printf 'exec env FM_ROOT_OVERRIDE=%q FM_HOME=%q FM_STATE_OVERRIDE=%q droid --auto high %q' \
  "$PROJECT" "$HOME_DIR" "$STATE" "$DROID_PROMPT")
"$LAB_HELPER" run "$SESSION" pane run "$PRIMARY_PANE" "$DROID_CMD" >/dev/null \
  || fail "could not launch Droid in the isolated Herdr pane"

capture=
status=
trust_confirmed=0
for _ in $(seq 1 240); do
  capture=$("$LAB_HELPER" run "$SESSION" pane read "$PRIMARY_PANE" --source recent --lines 200 2>/dev/null || true)
  if [ "$trust_confirmed" -eq 0 ] && printf '%s' "$capture" | grep -q 'Trust this folder?'; then
    "$LAB_HELPER" run "$SESSION" pane send-keys "$PRIMARY_PANE" enter >/dev/null \
      || fail "could not confirm the isolated Droid project trust prompt"
    trust_confirmed=1
  fi
  status=$("$LAB_HELPER" run "$SESSION" agent get "$PRIMARY_PANE" 2>/dev/null \
    | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
  if [ "$status" = idle ] && printf '%s' "$capture" | grep -Fq '⛬  DROID_SESSIONSTART_HOOK_7C91'; then
    break
  fi
  sleep 0.25
done
[ "$status" = idle ] || fail "real Droid did not become idle in Herdr (last status: ${status:-unreadable})"
printf '%s' "$capture" | grep -Fq '⛬  DROID_SESSIONSTART_HOOK_7C91' \
  || fail "Droid did not receive SessionStart context in the Herdr lab"
jq -s -e 'any(.[]; .hook_event_name == "SessionStart" and .source == "startup")' \
  "$PROJECT/.factory/sessionstart-payloads.jsonl" >/dev/null \
  || fail "Droid/Herdr SessionStart payload was not observed"
pass "Droid/Herdr SessionStart delivers shared recovery context"

export PATH="$FAKEBIN:$ORIGINAL_PATH"
export HERDR_SESSION="$SESSION"
export FM_ROOT_OVERRIDE="$ROOT"
export FM_HOME="$HOME_DIR"
export FM_STATE_OVERRIDE="$STATE"
export FM_SUPERVISOR_BACKEND=herdr
export FM_SUPERVISOR_TARGET="$PRIMARY_TARGET"
export FM_DAEMON_PRIMARY_HARNESS=droid
export FM_WEDGE_ALARM_EXEC="$TMP_ROOT/wedge-recorder"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervise-daemon.sh"

composer=$(fm_backend_composer_state herdr "$PRIMARY_TARGET")
if [ "$composer" != empty ]; then
  diagnostic=$(fm_backend_capture herdr "$PRIMARY_TARGET" 12 2>/dev/null || true)
  fail "real idle Droid composer with its current status footer classified $composer instead of empty; tail: $(printf '%q' "$diagnostic")"
fi
pass "Droid/Herdr current rendered composer is affirmatively empty through the shared classifier"

SESSION_ID=$(cat "$PROJECT/.factory/live-session-id" 2>/dev/null || true)
[ -n "$SESSION_ID" ] || fail "Droid hooks did not expose the isolated session id"

SEND_PROMPT='DROID_ORDINARY_SEND_PROBE: use the Execute tool to run exactly: sleep 8. After it finishes, follow the exact response instruction supplied by the UserPromptSubmit hook.'
FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "$PRIMARY_TARGET" "$SEND_PROMPT" >/dev/null \
  || fail "ordinary fm-send could not submit to the real Droid/Herdr pane"
busy_seen=0
for _ in $(seq 1 80); do
  if pane_is_busy "$PRIMARY_TARGET" herdr; then busy_seen=1; break; fi
  sleep 0.1
done
[ "$busy_seen" -eq 1 ] || fail "Droid/Herdr did not expose a busy state after ordinary fm-send"
for _ in $(seq 1 240); do
  capture=$("$LAB_HELPER" run "$SESSION" pane read "$PRIMARY_PANE" --source recent --lines 200 2>/dev/null || true)
  status=$("$LAB_HELPER" run "$SESSION" agent get "$PRIMARY_PANE" 2>/dev/null \
    | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
  if [ "$status" = idle ] && printf '%s' "$capture" | grep -Fq '⛬  DROID_USERPROMPT_HOOK_6B42'; then break; fi
  sleep 0.25
done
printf '%s' "$capture" | grep -Fq '⛬  DROID_USERPROMPT_HOOK_6B42' \
  || fail "ordinary fm-send was confirmed but its Droid turn did not complete visibly"
jq -s -e --arg session "$SESSION_ID" --arg prompt "$SEND_PROMPT" '
  any(.[]; .session_id == $session and .hook_event_name == "UserPromptSubmit" and .prompt == $prompt)
' "$PROJECT/.factory/userprompt-payloads.jsonl" >/dev/null \
  || fail "ordinary fm-send did not leave a durable prompt receipt for the interactive Droid session"
pass "ordinary fm-send reaches Droid through Herdr, UserPromptSubmit adds catch-up context, and the busy guard observes the turn"

api_out=$(PATH="$ORIGINAL_PATH" droid exec -s "$SESSION_ID" --auto low \
  'Reply exactly DROID_SESSION_API_HEADLESS_ONLY and do nothing else.' 2>&1) \
  || fail "Droid's native session continuation surface was unavailable: $api_out"
printf '%s' "$api_out" | grep -q DROID_SESSION_API_HEADLESS_ONLY \
  || fail "Droid's native session continuation surface returned no proof of its headless turn"
sleep 3
capture=$("$LAB_HELPER" run "$SESSION" pane read "$PRIMARY_PANE" --source recent --lines 200 2>/dev/null || true)
printf '%s' "$capture" | grep -q DROID_SESSION_API_HEADLESS_ONLY \
  && fail "Droid's session continuation unexpectedly addressed the live interactive pane; re-evaluate the delivery hierarchy"
pass "Droid session continuation is available but does not deliver into the already-running interactive pane"

PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$PRIMARY_TARGET" \
  FM_AFK_LAUNCH_ENTRY="$TMP_ROOT/daemon-entry" \
  "$ROOT/bin/fm-afk-launch.sh" start >/dev/null \
  || fail "could not start the isolated away-mode daemon"
DAEMON_STARTED=1
for _ in $(seq 1 100); do [ -s "$STATE/.supervise-daemon.pid" ] && break; sleep 0.1; done
[ -s "$STATE/.supervise-daemon.pid" ] || fail "away-mode daemon did not publish its pid"

"$LAB_HELPER" run "$SESSION" pane send-text "$PRIMARY_PANE" 'privacy safe captain draft' >/dev/null \
  || fail "could not type the pending-input guard fixture"
sleep 0.5
composer=$(fm_backend_composer_state herdr "$PRIMARY_TARGET")
[ "$composer" = pending ] || fail "real Droid draft classified $composer instead of pending"
cat > "$STATE/live-worker.meta" <<EOF
window=$PRIMARY_TARGET
backend=herdr
kind=ship
EOF
printf '%s\n' 'needs-decision [key=droid-herdr-live]: choose the isolated review path' > "$STATE/live-worker.status"

for _ in $(seq 1 180); do [ -s "$STATE/.subsuper-inject-wedged" ] && break; sleep 0.1; done
[ -s "$STATE/.subsuper-inject-wedged" ] \
  || fail "pending Droid composer did not raise the bounded max-defer alarm"
[ -s "$STATE/.subsuper-escalations" ] || fail "pending Droid composer lost the buffered decision"
for _ in $(seq 1 50); do [ -s "$NOTIFY_LOG" ] && break; sleep 0.1; done
[ -s "$NOTIFY_LOG" ] || fail "max-defer marker appeared without its active notifier"
capture=$("$LAB_HELPER" run "$SESSION" pane read "$PRIMARY_PANE" --source recent --lines 200 2>/dev/null || true)
printf '%s' "$capture" | grep -F 'privacy safe captain draft' >/dev/null \
  || fail "the pending Droid draft was modified or submitted"
printf '%s' "$capture" | grep -F 'choose the isolated review path' >/dev/null \
  && fail "the away daemon submitted while Droid held pending captain text"
pass "pending Droid input preserves the escalation and raises a bounded visible failure"

"$LAB_HELPER" run "$SESSION" pane send-keys "$PRIMARY_PANE" ctrl+u >/dev/null \
  || fail "could not clear the pending Droid draft"
delivery_durable=0
delivery_rendered=0
for _ in $(seq 1 240); do
  capture=$("$LAB_HELPER" run "$SESSION" pane read "$PRIMARY_PANE" --source recent --lines 200 2>/dev/null || true)
  if printf '%s' "$capture" | grep -Fq 'choose the isolated review path'; then
    delivery_rendered=1
  fi
  if jq -s -e --arg session "$SESSION_ID" '
    any(.[]; .session_id == $session and .hook_event_name == "UserPromptSubmit" and (.prompt | contains("choose the isolated review path")))
  ' "$PROJECT/.factory/userprompt-payloads.jsonl" >/dev/null 2>&1; then
    delivery_durable=1
  fi
  if [ ! -s "$STATE/.subsuper-escalations" ] && [ "$delivery_durable" -eq 1 ]; then
    break
  fi
  sleep 0.1
done
[ ! -s "$STATE/.subsuper-escalations" ] || fail "idle Droid did not consume the buffered escalation"
[ "$delivery_durable" -eq 1 ] \
  || fail "idle Droid cleared the buffer without a durable prompt receipt in the interactive session"
delivery_count=$(jq -s --arg session "$SESSION_ID" '
  [.[] | select(.session_id == $session and .hook_event_name == "UserPromptSubmit" and (.prompt | contains("choose the isolated review path")))] | length
' "$PROJECT/.factory/userprompt-payloads.jsonl")
[ "$delivery_count" -eq 1 ] \
  || fail "buffered Droid escalation was submitted $delivery_count times instead of exactly once"
for _ in $(seq 1 50); do
  [ ! -e "$STATE/.subsuper-inject-wedged" ] && break
  sleep 0.1
done
[ ! -e "$STATE/.subsuper-inject-wedged" ] || fail "successful Droid delivery retained the wedge marker"
if [ "$delivery_rendered" -eq 1 ]; then
  pass "clearing the draft makes the buffered decision render through verified Droid/Herdr submit"
else
  pass "clearing the draft delivers the buffered decision with a durable interactive-session prompt receipt; the rendered viewport was racy"
fi

for _ in $(seq 1 600); do
  status=$("$LAB_HELPER" run "$SESSION" agent get "$PRIMARY_PANE" 2>/dev/null \
    | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
  [ "$status" = idle ] && break
  sleep 0.1
done
[ "$status" = idle ] || fail "Droid did not become idle before the AFK approval probe"
if [ -f "$PROJECT/.factory/askuser-payloads.jsonl" ]; then
  ask_count_before=$(jq -s 'length' "$PROJECT/.factory/askuser-payloads.jsonl")
else
  ask_count_before=0
fi

AFK_APPROVAL_PROMPT='Read the open droid-herdr-live decision from the durable state. First use AskUser to ask whether to approve it, with APPROVE_ISOLATED_CHANGE and KEEP_ISOLATED_PARKED as the two options, and include this exact line immediately after the question line, copied without alteration: [firstmate-decision origin=live-worker key=droid-herdr-live state=existing]. If and only if the tool is denied, use Execute to run exactly: touch .factory/authorized-after-afk-denial. Then reply exactly DROID_AFK_ASKUSER_DEFERRED.'
FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "$PRIMARY_TARGET" "$AFK_APPROVAL_PROMPT" >/dev/null \
  || fail "could not submit the AFK approval probe to Droid"
for _ in $(seq 1 300); do
  status=$("$LAB_HELPER" run "$SESSION" agent get "$PRIMARY_PANE" 2>/dev/null \
    | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
  [ -e "$PROJECT/.factory/authorized-after-afk-denial" ] && [ "$status" = idle ] && break
  sleep 0.1
done
[ -e "$PROJECT/.factory/authorized-after-afk-denial" ] \
  || fail "Droid did not continue the independently authorized action after AFK AskUser denial"
[ "$status" = idle ] || fail "Droid stayed interactive after the AFK AskUser denial"
[ -e "$STATE/.afk" ] || fail "Droid AskUser attempt incorrectly counted as captain return"
jq -s -e --argjson expected "$((ask_count_before + 1))" '
  length == $expected and
  .[-1].hook_event_name == "PreToolUse" and
  .[-1].tool_name == "AskUser" and
  (.[-1].tool_input.questionnaire | contains("APPROVE_ISOLATED_CHANGE"))
' "$PROJECT/.factory/askuser-payloads.jsonl" >/dev/null \
  || fail "the isolated Droid AskUser call did not reach the exact tracked matcher once"
status_open=$(status_open_decisions "$STATE/live-worker.status")
printf '%s' "$status_open" | grep -q '^droid-herdr-live	needs-decision	' \
  || fail "AFK AskUser denial lost or resolved the keyed decision"
[ "$(printf '%s' "$status_open" | grep -c '^droid-herdr-live	')" -eq 1 ] \
  || fail "the deferred question forked its decision into more than one open identity"

# The attempted question must be recoverable from its bound owner, byte for byte.
live_listing=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  PATH="$FAKEBIN:$ORIGINAL_PATH" "$ROOT/bin/fm-decision-hold.sh" open-questions --render) \
  || fail "the deferred live question could not be projected for the captain's return"
printf '%s' "$live_listing" | grep -Fq 'APPROVE_ISOLATED_CHANGE' \
  || fail "the deferred live question was not preserved with its bound decision owner"
printf '%s' "$live_listing" | grep -Fq '[firstmate-decision origin=' \
  && fail "the transport binding line leaked into the captain-facing listing"
pass "Droid denies interactive approval during AFK, files it with its bound owner, and continues independently authorized work"

# A question that names no owner must be rejected loudly rather than guessed at.
ask_count_before=$(jq -s 'length' "$PROJECT/.factory/askuser-payloads.jsonl")
status_bytes_before=$(cksum < "$STATE/live-worker.status")
UNBOUND_PROMPT='Use AskUser exactly once to ask whether to approve the isolated change, with UNBOUND_APPROVE and UNBOUND_KEEP_PARKED as the two options, and include no other bracketed metadata lines at all. If and only if the tool is denied, use Execute to run exactly: touch .factory/unbound-question-denied. Then reply exactly DROID_AFK_UNBOUND_REJECTED.'
FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "$PRIMARY_TARGET" "$UNBOUND_PROMPT" >/dev/null \
  || fail "could not submit the unbound-question probe to Droid"
for _ in $(seq 1 300); do
  status=$("$LAB_HELPER" run "$SESSION" agent get "$PRIMARY_PANE" 2>/dev/null \
    | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
  [ -e "$PROJECT/.factory/unbound-question-denied" ] && [ "$status" = idle ] && break
  sleep 0.1
done
[ -e "$PROJECT/.factory/unbound-question-denied" ] \
  || fail "the unbound live question was not denied before becoming interactive"
[ "$(jq -s 'length' "$PROJECT/.factory/askuser-payloads.jsonl")" -gt "$ask_count_before" ] \
  || fail "the unbound-question probe never reached the tracked matcher"
[ "$status_bytes_before" = "$(cksum < "$STATE/live-worker.status")" ] \
  || fail "a rejected unbound question still mutated a durable decision owner"
pass "a live question naming no owner is rejected without inventing or mutating one"

RETURN_OUTPUT="$PROJECT/.factory/return-output"
POST_RETURN_PROMPT='DROID_REAL_RETURN_PROBE: this is an unmarked returning-captain message. Before any ordinary work, use Execute to run exactly: bash .factory/return-probe.sh > .factory/return-output 2>&1 . Only after that command succeeds, use AskUser to ask whether to approve the isolated change, with POST_RETURN_APPROVE and POST_RETURN_KEEP_PARKED as the two options. Do not answer the question yourself and do nothing after opening it.'
"$ROOT/bin/fm-send.sh" "$PRIMARY_TARGET" "$POST_RETURN_PROMPT" >/dev/null \
  || fail "could not submit the real unmarked return probe"
for _ in $(seq 1 200); do
  ask_count=$(jq -s 'length' "$PROJECT/.factory/askuser-payloads.jsonl" 2>/dev/null || printf 0)
  [ "$ask_count" -ge "$((ask_count_before + 2))" ] && [ -s "$RETURN_OUTPUT" ] && break
  sleep 0.1
done
[ "$ask_count" -eq "$((ask_count_before + 2))" ] \
  || fail "post-return AskUser did not reach the tracked matcher exactly once"
[ -s "$RETURN_OUTPUT" ] || fail "Droid did not run return catch-up before opening AskUser"
DAEMON_STARTED=0
[ ! -e "$STATE/.afk" ] || fail "Droid opened post-return AskUser before the return owner cleared AFK"
grep -Fq 'droid-herdr-live' "$RETURN_OUTPUT" \
  || fail "Droid return catch-up did not present the outstanding keyed question: $(cat "$RETURN_OUTPUT")"
status_open=$(status_open_decisions "$STATE/live-worker.status")
printf '%s' "$status_open" | grep -q '^droid-herdr-live	needs-decision	' \
  || fail "Droid return catch-up automatically approved or lost the question"
pass "a real unmarked Droid return runs ordered catch-up and presents the outstanding question first"

sleep 1
capture=$("$LAB_HELPER" run "$SESSION" pane read "$PRIMARY_PANE" --source recent --lines 100 2>/dev/null || true)
printf '%s' "$capture" | grep -Fq 'POST_RETURN_APPROVE' \
  || fail "post-return Droid questionnaire did not become visible"
[ ! -e "$PROJECT/.factory/post-return-answer" ] || fail "post-return question was automatically approved"
"$LAB_HELPER" run "$SESSION" pane send-keys "$PRIMARY_PANE" escape >/dev/null \
  || fail "could not cancel the isolated post-return questionnaire"
pass "Droid AskUser becomes available on return without an automatic approval"

DEAD_OUT=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$PROJECT" --label droid-dead-shell --no-focus) \
  || fail "could not create the dead-shell negative-control pane"
DEAD_PANE=$(printf '%s' "$DEAD_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$DEAD_PANE" ] || fail "dead-shell workspace creation returned no pane"
dead_composer=$(fm_backend_composer_state herdr "$SESSION:$DEAD_PANE")
[ "$dead_composer" = unknown ] \
  || fail "a real Herdr shell prompt classified $dead_composer instead of unknown"
pass "a real dead shell stays outside the Droid composer exception"

printf 'ok - Droid %s / Herdr away-mode live verification complete\n' "$(PATH="$ORIGINAL_PATH" droid --version)"
