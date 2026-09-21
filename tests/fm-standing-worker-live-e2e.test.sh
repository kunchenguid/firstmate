#!/usr/bin/env bash
# Real-Herdr guard for the standing-worker stop classifier.
#
# bin/fm-standing-worker.sh decides "this worker stopped and is holding a
# question" from Herdr's own `agent get` .agent_status field. That is a
# harness-dependent signal: its spelling and its lifecycle belong to the vendor,
# so a fake herdr can only confirm the assumption already written into the fake.
# tests/fm-standing-worker.test.sh pins the LOGIC portably; this guard proves
# the SIGNAL against the installed binary, and fails naming the harness and its
# version when the field stops behaving the way the classifier reads it.
#
# It spends no model tokens: a real agent is never launched, and no prompt is
# ever submitted. It drives a real Herdr server in an isolated lab session,
# occupies a pane with an ordinary long-running shell command, and asserts the
# three facts the classifier actually depends on:
#
#   1. a pane the registration names in a session it is NOT in cannot be
#      registered, and the refusal names the sessions that were searched;
#   2. `agent get` on a registered pane returns one of the four statuses the
#      classifier accepts, or a recognizable agent_not_found - never something
#      it would silently read as "still working";
#   3. a pane that disappears is seen as gone rather than as still working,
#      which is the difference between a wake and a silently stranded worker;
#   4. the installed turn-end hook command, run inside the real pane, recognizes
#      that pane as its own - the pane identity Herdr gives a process in a pane
#      is the same id the registration recorded - and records the turn end.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
fm_live_gate default-on FM_STANDING_WORKER_LIVE_E2E herdr jq

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: live: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_VERSION=$(herdr --version 2>/dev/null | head -1)
[ -n "$HERDR_VERSION" ] || HERDR_VERSION='unknown'

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-standing-worker-live)
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-standing-worker)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH

cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# The script under test names its own session on every call, which is precisely
# the behavior being proven, so this shim accepts that explicit --session when
# it matches the lab and refuses any other. A call that reached the wrong
# session, or omitted the session entirely, exits 9 and fails the guard rather
# than quietly succeeding against whatever session happened to be ambient.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

standing_worker() {
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-standing-worker.sh" "$@"
}

# A real pane in a real workspace. No agent process and no prompt is ever
# launched: `pane report-agent` is Herdr's own lifecycle-reporting entry point,
# the same one an agent harness calls to publish its status, so driving it
# directly exercises the very field the classifier reads while spending nothing.
CREATE=$(lab workspace create --cwd "$TMP_ROOT" --label 'standing-worker' --no-focus) \
  || fail "live: could not create the lab workspace on herdr $HERDR_VERSION"
PANE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id') \
  || fail "live: could not read the lab pane id on herdr $HERDR_VERSION"

AGENT_SOURCE=fm-standing-worker-live
report_agent() {  # <state> [message]
  lab pane report-agent "$PANE" --source "$AGENT_SOURCE" \
    --agent standing-worker-guard --state "$1" \
    ${2:+--message "$2"} >/dev/null 2>&1
}

report_agent working 'mid turn' \
  || fail "live: herdr $HERDR_VERSION rejected pane report-agent --state working; the classifier's status source is unavailable"

# --- 1. the wrong session is refused, and the refusal is actionable ----------
#
# This is the half of the 2026-09-21 incident that a fake cannot prove: a real
# server has real sessions, and the refusal has to name them.
WRONG_SESSION="${HERDR_LAB_SESSION}-absent"
out=$(PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-standing-worker.sh" register wrong-session \
  --session "$WRONG_SESSION" --pane "$PANE" 2>&1) && {
  fail "live: registering into session $WRONG_SESSION should have been refused on herdr $HERDR_VERSION"
}
case "$out" in
  *"in session $WRONG_SESSION"*) ;;
  *) fail "live: the refusal must name the session searched on herdr $HERDR_VERSION: $out" ;;
esac
[ ! -e "$HOME_DIR/state/standing-workers/wrong-session.json" ] \
  || fail "live: a refused registration left a record on herdr $HERDR_VERSION"
pass "live: a pane is not registrable from a session it does not live in (herdr $HERDR_VERSION)"

# --- 2. agent_status reads as one of the statuses the classifier accepts -----

standing_worker register live-worker --session "$HERDR_LAB_SESSION" --pane "$PANE" \
  --cwd "$TMP_ROOT" >/dev/null \
  || fail "live: registering an existing pane in its own session failed on herdr $HERDR_VERSION"
pass "live: an existing pane registers in the session it actually lives in (herdr $HERDR_VERSION)"

agent_status_now() {
  local out
  out=$(lab agent get "$PANE" 2>&1) || true
  printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null
}

AGENT_STATUS=$(agent_status_now)
case "$AGENT_STATUS" in
  working) ;;
  '') fail "live: agent get published no agent_status on herdr $HERDR_VERSION after report-agent --state working; the stop classifier reads that field" ;;
  *) fail "live: agent get reported '$AGENT_STATUS' on herdr $HERDR_VERSION where working was published; the vendor field changed under the stop classifier" ;;
esac
pass "live: a working agent reads back as working on the real server (herdr $HERDR_VERSION)"

# The baseline poll must be silent: nothing stopped.
standing_worker check >/dev/null \
  || fail "live: the first poll failed against herdr $HERDR_VERSION"
out=$(standing_worker check)
[ -z "$out" ] || fail "live: a working pane must not report a stop on herdr $HERDR_VERSION: $out"
pass "live: polling a working pane is silent against the real server (herdr $HERDR_VERSION)"

# --- the transition this whole mechanism exists for -------------------------
#
# A real working->idle move on a real server must produce exactly one wake
# carrying the pane's own text. This is the 2026-09-21 failure in miniature.
#
# The question is printed into the real pane first, because only a real
# `pane read` proves the output shape the excerpt is parsed from.
SENTINEL="fm-sw-question-$$"
lab pane run "$PANE" "echo $SENTINEL" >/dev/null 2>&1 \
  || fail "live: herdr $HERDR_VERSION rejected pane run for the sentinel echo"
for _ in $(seq 1 40); do
  case "$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null)" in
    *"$SENTINEL"*) break ;;
  esac
  sleep 0.25
done
report_agent idle 'which database should I migrate first' \
  || fail "live: herdr $HERDR_VERSION rejected pane report-agent --state idle"
for _ in $(seq 1 40); do
  [ "$(agent_status_now)" = working ] || break
  sleep 0.25
done
STOPPED_STATUS=$(agent_status_now)
case "$STOPPED_STATUS" in
  idle|done|blocked) ;;
  *) fail "live: herdr $HERDR_VERSION never published the idle transition (still '$STOPPED_STATUS'); a stopped worker would go unnoticed" ;;
esac

out=$(standing_worker check)
case "$out" in
  *"stopped working (now $STOPPED_STATUS)"*"$PANE"*)
    pass "live: a real working->$STOPPED_STATUS transition raises one wake (herdr $HERDR_VERSION)"
    ;;
  *)
    fail "live: a real stop must raise a wake on herdr $HERDR_VERSION, got: ${out:-<silence>}"
    ;;
esac

case "$out" in
  *"$SENTINEL"*)
    pass "live: the stop wake carries the text printed in the real pane (herdr $HERDR_VERSION)"
    ;;
  *)
    fail "live: the stop wake lost the pane's own text on herdr $HERDR_VERSION, so the worker's question never travels: $out"
    ;;
esac

out=$(standing_worker check)
[ -z "$out" ] || fail "live: the stop must be reported once on herdr $HERDR_VERSION, got a repeat: $out"
pass "live: the stop wake is debounced against the real server (herdr $HERDR_VERSION)"

# --- the turn-end hook fires inside the real pane ---------------------------
#
# The hook's pane check compares the pane identity Herdr hands a process in a
# pane against the id recorded at registration. Only a real pane can prove
# those are the same spelling; if they were not, every turn end would be
# silently discarded as somebody else's. No agent runs: the pane's own shell
# executes the installed command exactly as a Stop hook would.
HOOK_CMD=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$TMP_ROOT/.claude/settings.local.json" 2>/dev/null)
[ -n "$HOOK_CMD" ] || fail "live: register --cwd installed no Stop hook on herdr $HERDR_VERSION"
HOOK_STATUS="$HOME_DIR/state/standing-live-worker.status"
lab pane run "$PANE" "env -u CLAUDE_PROJECT_DIR $HOOK_CMD </dev/null" >/dev/null 2>&1 \
  || fail "live: herdr $HERDR_VERSION rejected pane run for the hook command"
for _ in $(seq 1 80); do
  [ -s "$HOOK_STATUS" ] && break
  sleep 0.25
done
if [ -s "$HOOK_STATUS" ] && grep -q 'standing worker live-worker ended its turn' "$HOOK_STATUS"; then
  pass "live: the hook run inside the registered pane records its turn end (herdr $HERDR_VERSION)"
else
  fail "live: the hook run inside pane $PANE recorded nothing on herdr $HERDR_VERSION; the pane identity a pane process sees no longer matches the registered pane id"
fi

# --- 3. a pane that disappears is seen as gone ------------------------------
#
# The classifier must distinguish "gone" from "still working". A real pane
# closure is the only way to prove Herdr reports it the way the classifier
# reads it.

# Put the worker back to work through the real interface, so the remembered
# state is `working` for the same reason it would be in production: the server
# said so. A worker killed mid-turn is exactly this shape.
report_agent working 'back to work' \
  || fail "live: herdr $HERDR_VERSION rejected the return to working"
for _ in $(seq 1 40); do
  [ "$(agent_status_now)" = working ] && break
  sleep 0.25
done
[ "$(agent_status_now)" = working ] \
  || fail "live: herdr $HERDR_VERSION never published the return to working"
out=$(standing_worker check)
[ -z "$out" ] || fail "live: resuming work is not a stop on herdr $HERDR_VERSION: $out"

lab pane close "$PANE" >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
  lab pane get "$PANE" >/dev/null 2>&1 || break
  sleep 0.25
done
if lab pane get "$PANE" >/dev/null 2>&1; then
  fail "live: the lab pane did not close on herdr $HERDR_VERSION, so the vanish path could not be proven"
fi

out=$(standing_worker check)
case "$out" in
  *'vanished from session'*"$PANE"*)
    pass "live: a closed pane is reported as vanished, not as still working (herdr $HERDR_VERSION)"
    ;;
  *)
    fail "live: a closed pane must raise a vanish wake on herdr $HERDR_VERSION, got: ${out:-<silence>}"
    ;;
esac

out=$(standing_worker check)
[ -z "$out" ] || fail "live: the vanish must be reported once on herdr $HERDR_VERSION, got a repeat: $out"
pass "live: the vanish wake is debounced against the real server (herdr $HERDR_VERSION)"

# --- 4. the blind spot this mechanism silently dies of ----------------------
#
# Everything above drives agent_status through Herdr's own reporting entry
# point, which proves the transport but not the HARNESS. A harness that never
# publishes `working` makes this whole mechanism inert without failing
# anything: the baseline is never `working`, so a departure from it never
# happens, and a stopped worker is never reported. That is not hypothetical -
# docs/verification/runtime-backends.md "Submit confirmation" records Claude
# Code 2.1.236 on Herdr 0.8.0 holding agent_status=idle through an entire
# landed turn, including a multi-second tool call.
#
# So assert the property directly against whatever agents are registered on
# this host right now. This is observation only: no pane is created, steered,
# or closed, and nothing is submitted.
LIVE_SESSION=${FM_STANDING_WORKER_LIVE_SESSION:-default}
LIVE_PANES=$(env PATH="$HERDR_ORIGINAL_PATH" herdr --session "$LIVE_SESSION" pane list 2>/dev/null \
  | jq -r '(.result.panes // [])[] | .pane_id' 2>/dev/null)

if [ -z "$LIVE_PANES" ]; then
  echo "skip: live: no panes in session $LIVE_SESSION to sample harness status reporting"
else
  SAMPLED=0
  SAW_WORKING=0
  SEEN_KINDS=
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    body=$(env PATH="$HERDR_ORIGINAL_PATH" herdr --session "$LIVE_SESSION" agent get "$p" 2>/dev/null) || continue
    kind=$(printf '%s' "$body" | jq -r '.result.agent.agent // empty' 2>/dev/null)
    status=$(printf '%s' "$body" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
    [ -n "$kind" ] || continue
    SAMPLED=$((SAMPLED + 1))
    case " $SEEN_KINDS " in *" $kind "*) ;; *) SEEN_KINDS="$SEEN_KINDS $kind" ;; esac
    # Any status the classifier accepts proves the harness publishes a real
    # lifecycle rather than a frozen placeholder.
    case "$status" in
      working) SAW_WORKING=1 ;;
      idle|done|blocked) ;;
      *) fail "live: harness '$kind' published agent_status '$status' on herdr $HERDR_VERSION, which the stop classifier does not accept" ;;
    esac
  done <<EOF
$LIVE_PANES
EOF
  if [ "$SAMPLED" -eq 0 ]; then
    echo "skip: live: no registered agents in session $LIVE_SESSION to sample"
  elif [ "$SAW_WORKING" -eq 1 ]; then
    pass "live: a registered harness publishes working on herdr $HERDR_VERSION (sampled$SEEN_KINDS)"
  else
    # Not a failure: every sampled agent may genuinely be idle right now. It is
    # reported, because a host that can never observe `working` cannot prove
    # this mechanism is armed.
    echo "skip: live: sampled$SEEN_KINDS on herdr $HERDR_VERSION were all stopped; re-run while an agent is mid-turn to prove working is published"
  fi
fi
