#!/usr/bin/env bash
# tests/fm-agy-live-e2e.test.sh - the live Anti-Gravity CLI (agy) adapter guard
# (live-harness-optin family).
#
# Every Agy-facing check in the adapter reads something the vendor renders or
# emits: the workspace-trust dialog, the separated composer, the `esc to cancel`
# busy footer, the Stop hook payload, the ANTIGRAVITY_AGENT marker in tool
# children, the Escape interrupt banner, and the /exit resume line. Per .agents/skills/firstmate-coding-guidelines those are
# proven here against the REAL binary through the real control plane: one
# fm-spawn into a throwaway Firstmate home with its own treehouse pool on a
# private tmux socket, then fm-crew-state, fm-send, fm-control interrupt and
# exit, and fm-teardown, failing loudly with the Agy version on any drift.
# The lab project commits a project-owned `.agents/hooks.json` and a hookless
# `.agent/` directory, so one run also proves live that Agy still merges
# coexisting customization roots, that spawn borrows the project's hookless
# root instead of creating one, and that teardown leaves both project roots
# standing while retiring only the task hook it installed.
#
# Run explicitly with FM_AGY_LIVE_E2E=1. It spends a small number of real model
# tokens: five short turns on the cheapest listed Flash tier (override with
# FM_AGY_LIVE_MODEL). Nothing under ~/.gemini is edited; the only side effect
# outside the lab is Agy's own trust record for the lab's disposable worktree
# path. FM_AGY_LIVE_TIMEOUT bounds each wait (seconds, default 240). A passing
# run removes its lab; a failing run tears the task down, kills its private
# tmux server, and preserves the lab directory by name for inspection.
# Refresh docs/verification/agy-harness.md from this guard's `#` notes after
# any Agy upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_AGY_LIVE_E2E agy tmux jq treehouse git

# The guard may itself run inside tmux (a crewmate pane, a no-mistakes gate)
# and inside a no-mistakes lifecycle refusal; both must not leak into the lab.
unset TMUX TMUX_PANE NO_MISTAKES_GATE

SOCKET="fm-agy-live-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-live.XXXXXX") || fail "could not create the Agy live lab"
LAB=$(cd "$LAB" && pwd -P)
TASK="agylive-$$"
TIMEOUT=${FM_AGY_LIVE_TIMEOUT:-240}
EFFORT=low
MODEL=${FM_AGY_LIVE_MODEL:-}
PROJ="$LAB/projects/agyprobe"
PAYLOADS="$LAB/payloads.jsonl"
MARKER="$LAB/state/$TASK.turn-ended"
SPAWNED=0
TORN_DOWN=0
PASSED=0
SURVEY_SEEN=0

note() { printf '# %s\n' "$1"; }
indent() { sed 's/^/#   /'; }

cleanup() {
  if [ "$SPAWNED" -eq 1 ] && [ "$TORN_DOWN" -eq 0 ]; then
    FM_HOME="$LAB" "$ROOT/bin/fm-teardown.sh" "$TASK" --force >/dev/null 2>&1 || true
  fi
  tmux kill-server >/dev/null 2>&1 || true
  if [ "$PASSED" -eq 1 ]; then
    rm -rf -- "$LAB"
  else
    printf '# lab preserved for inspection: %s\n' "$LAB" >&2
  fi
}
trap cleanup EXIT

bounded() {  # <seconds> <command...>
  if command -v timeout >/dev/null 2>&1; then
    timeout "$@"
  else
    shift
    "$@"
  fi
}

# --- 1. Version and command surface (no model tokens) ------------------------
VERSION=$(agy --version 2>/dev/null </dev/null | head -1 | tr -d '\r')
[ -n "$VERSION" ] || fail "agy --version printed nothing"
note "agy --version: $VERSION"
HELP=$(agy --help 2>&1 </dev/null)
for flag in --model --effort --dangerously-skip-permissions --continue --conversation --prompt-interactive --print; do
  printf '%s\n' "$HELP" | grep -qE "^[[:space:]]*$flag([[:space:]]|$)" \
    || fail "agy $VERSION: --help no longer advertises $flag, which the adapter relies on"
done
pass "agy $VERSION: --help still advertises every flag the adapter uses"

EFFORT_OUT=$(bounded 30 agy --effort xhigh --print 'Reply exactly probe' </dev/null 2>&1)
EFFORT_RC=$?
[ "$EFFORT_RC" -ne 0 ] \
  || fail "agy $VERSION accepted --effort xhigh; bin/fm-spawn.sh's effort mapping now omits a value this release supports"
printf '%s\n' "$EFFORT_OUT" | grep -q 'valid: low, medium, high' \
  || fail "agy $VERSION rejected --effort xhigh with an unrecognized message: $EFFORT_OUT"
note "agy --effort xhigh --print exited $EFFORT_RC: $(printf '%s\n' "$EFFORT_OUT" | head -1)"
pass "agy $VERSION: --effort still accepts only low, medium, and high"

MODELS=$(agy models 2>/dev/null </dev/null | grep -E '^[a-z0-9.-]+[[:space:]]')
[ -n "$MODELS" ] || fail "agy $VERSION: 'agy models' listed nothing (is this account signed in?)"
note "agy models:"
printf '%s\n' "$MODELS" | indent
if [ -z "$MODEL" ]; then
  MODEL=$(printf '%s\n' "$MODELS" | awk '$1 ~ /^gemini-[0-9.]+-flash-low$/ { print $1; exit }')
fi
[ -n "$MODEL" ] || fail "agy $VERSION: 'agy models' listed no gemini-*-flash-low tier; set FM_AGY_LIVE_MODEL"
note "probe model: $MODEL effort: $EFFORT"

# --- 2. Throwaway home, project, treehouse pool, and private tmux server -----
mkdir -p "$LAB/config" "$LAB/data" "$LAB/state" "$LAB/shim" "$LAB/treehouse" \
  "$PROJ/.agents" "$PROJ/.agent"
touch "$LAB/state/.last-watcher-beat"
export TREEHOUSE_ROOT="$LAB/treehouse"

REAL_TMUX=$(command -v tmux)
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

# The project owns .agents/hooks.json and a hookless .agent directory, so spawn
# must borrow .agent. The project hook captures every Stop payload it receives
# and answers execution zero once with the same continue decision
# bin/fm-turnend-guard-agy.sh emits, so the one-follow-up bound the primary
# guard relies on is exercised for real.
JQ_BIN=$(command -v jq)
cat > "$LAB/capture-stop.sh" <<SH
#!/usr/bin/env bash
payload=\$(cat)
printf '%s\n' "\$payload" >> "$PAYLOADS"
if [ ! -e "$LAB/continued" ] \\
   && [ "\$(printf '%s' "\$payload" | "$JQ_BIN" -r '.executionNum // empty' 2>/dev/null)" = 0 ]; then
  : > "$LAB/continued"
  printf '%s\n' '{"decision":"continue","reason":"Reply exactly AGY_NATIVE_CONTINUE_DONE and stop."}'
else
  printf '{}\n'
fi
SH
chmod +x "$LAB/capture-stop.sh"
# The same project root also registers a PreToolUse probe on run_command. Agy
# reads the decision from the hook's STDOUT and treats any nonzero exit as a
# failed hook, so the four renderings below are driven for real: silence, a
# returned {}, a deny object at exit 0, and the same object at exit 2. That is
# what pins the transport bin/fm-arm-pretool-check.sh --agy and the tracked
# .agents/hooks.json depend on.
cat > "$LAB/pretool-probe.sh" <<SH
#!/usr/bin/env bash
payload=\$(cat)
cmd=\$(printf '%s' "\$payload" | "$JQ_BIN" -r '.toolCall.args.CommandLine // empty' 2>/dev/null)
case "\$cmd" in
  *fm-agy-seatbelt-rc2*)
    printf 'deny-object-exit2\n' >> "$LAB/pretool.log"
    printf '%s\n' '{"decision":"deny","reason":"FIRSTMATE_AGY_PRETOOL_DENY"}'
    exit 2
    ;;
  *fm-agy-seatbelt-deny*)
    printf 'deny-object-exit0\n' >> "$LAB/pretool.log"
    printf '%s\n' '{"decision":"deny","reason":"FIRSTMATE_AGY_PRETOOL_DENY"}'
    ;;
  *fm-agy-seatbelt-object*)
    printf 'empty-object-exit0\n' >> "$LAB/pretool.log"
    printf '%s\n' '{}'
    ;;
  *fm-agy-seatbelt-allow*)
    printf 'silent-exit0\n' >> "$LAB/pretool.log"
    ;;
esac
exit 0
SH
chmod +x "$LAB/pretool-probe.sh"
jq -n --arg stop "bash '$LAB/capture-stop.sh'" --arg pre "bash '$LAB/pretool-probe.sh'" \
  '{"fm-live-payload-capture":{"Stop":[{"type":"command","command":$stop,"timeout":10}]},
    "fm-live-pretool-probe":{"PreToolUse":[{"matcher":"run_command","hooks":[{"type":"command","command":$pre,"timeout":10}]}]}}' \
  > "$PROJ/.agents/hooks.json"
printf 'project-owned customization root\n' > "$PROJ/.agent/keep.md"
printf 'Agy live adapter probe\n' > "$PROJ/README.md"
git -C "$PROJ" init -q -b main || fail "could not initialize the lab project"
git -C "$PROJ" config user.email 'agy-live@example.invalid'
git -C "$PROJ" config user.name 'agy live guard'
git -C "$PROJ" add README.md .agents/hooks.json .agent/keep.md
git -C "$PROJ" commit -qm 'fixture: Agy live adapter probe' || fail "could not commit the lab project"

tmux new-session -d -s firstmate -x 200 -y 50 -c "$LAB" || fail "could not start the private tmux server"

FM_HOME="$LAB" "$ROOT/bin/fm-brief.sh" "$TASK" agyprobe --scout >/dev/null 2>&1 \
  || fail "could not scaffold the Agy probe brief"
BRIEF="$LAB/data/$TASK/brief.md"
awk -v task="Live adapter probe. Run exactly this shell command in your current working directory, as one command line: printf ok > .fm-agy-live-probe; '$ROOT/bin/fm-harness.sh' > .fm-agy-live-harness; printf '%s' \"\${ANTIGRAVITY_AGENT:-unset}\" > .fm-agy-live-marker
Then reply with exactly the single line AGY_LIVE_OK and stop.
Do not write a report, do not append to the status file, and do not run any other command." \
  -v spec='None beyond the captain'"'"'s intent above: the probe is the whole task.' \
  '$0 == "{TASK}" { print task; next } $0 == "{FIRSTMATE_SPEC}" { print spec; next } { print }' \
  "$BRIEF" > "$BRIEF.tmp" && mv "$BRIEF.tmp" "$BRIEF"

# --- 3. Real spawn: trust, composer, pointer delivery, hook registration -----
SPAWNED=1
TRUST_TAIL=''
FM_HOME="$LAB" bounded 300 "$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ" \
  --scout --harness agy --model "$MODEL" --effort "$EFFORT" > "$LAB/spawn.log" 2>&1 &
SPAWN_PID=$!
# Watch the pane spawn creates so the trust dialog it accepts is recorded too.
while kill -0 "$SPAWN_PID" 2>/dev/null; do
  if [ -z "$TRUST_TAIL" ]; then
    SCREEN=$(tmux capture-pane -p -t "firstmate:fm-$TASK" 2>/dev/null || true)
    case "$SCREEN" in
      *'Do you trust the contents of this project'*)
        TRUST_TAIL=$(printf '%s\n' "$SCREEN" | grep '[^[:space:]]' | tail -6)
        ;;
    esac
  fi
  sleep 0.2
done
wait "$SPAWN_PID"
SPAWN_RC=$?
SPAWN_OUT=$(cat "$LAB/spawn.log")
[ "$SPAWN_RC" -eq 0 ] || fail "agy $VERSION: fm-spawn failed (rc=$SPAWN_RC): $SPAWN_OUT"
case "$SPAWN_OUT" in
  *"spawned $TASK harness=agy"*) ;;
  *) fail "agy $VERSION: fm-spawn did not report the Agy launch: $SPAWN_OUT" ;;
esac
note "fm-spawn: $(printf '%s\n' "$SPAWN_OUT" | grep '^spawned ' | head -1)"

META="$LAB/state/$TASK.meta"
WINDOW=$(awk -F= '/^window=/ { print $2 }' "$META")
WT=$(awk -F= '/^worktree=/ { print $2 }' "$META")
[ -n "$WINDOW" ] && [ -n "$WT" ] || fail "spawn recorded no endpoint or worktree"
TOKEN_FILE="$LAB/state/$TASK.agy-turnend-token"
TOKEN=$(sed -n '1p' "$TOKEN_FILE")
HOOK_ROOT=$(sed -n '2p' "$TOKEN_FILE")
HOOK_OWNER=$(sed -n '3p' "$TOKEN_FILE")
[ "$HOOK_ROOT" = .agent ] \
  || fail "spawn chose '$HOOK_ROOT' instead of borrowing the project's hookless .agent root beside its occupied .agents"
[ "$HOOK_OWNER" = preexisting ] \
  || fail "spawn recorded the borrowed .agent root as '$HOOK_OWNER', not preexisting"
[ -f "$WT/.agent/hooks.json" ] || fail "the task hook was not installed in the borrowed root"
cmp -s "$WT/.agents/hooks.json" "$PROJ/.agents/hooks.json" \
  || fail "spawn altered the project-owned .agents/hooks.json"
[ -f "$LAB/state/agy-turn-end.d/$TOKEN" ] || fail "spawn registered no private auth entry for token $TOKEN"
note "task hook root: $HOOK_ROOT ($HOOK_OWNER); project .agents/hooks.json untouched"
if [ -n "$TRUST_TAIL" ]; then
  note "trust dialog rendered on the fresh worktree and accepted by spawn:"
  printf '%s\n' "$TRUST_TAIL" | indent
else
  note "trust dialog: not observed while spawn ran (path already trusted, or accepted between polls)"
fi
pass "agy $VERSION: fm-spawn launched bare, delivered the brief pointer, and armed the task hook in the borrowed root"

pane() { tmux capture-pane -p -t "$WINDOW" 2>/dev/null; }
pane_tail() { pane | grep '[^[:space:]]' | tail -"${1:-6}"; }
crew_state() { FM_HOME="$LAB" bounded 30 "$ROOT/bin/fm-crew-state.sh" "$TASK" 2>/dev/null | head -1; }
composer_state() { FM_COMPOSER_HARNESS=agy fm_tmux_composer_state "$WINDOW"; }

BUSY_SEEN=0
BUSY_TAIL=''
wait_marker() {  # returns 0 once the real Stop hook touched the task marker
  local i=0 state
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ -e "$MARKER" ] && return 0
    if [ "$BUSY_SEEN" -eq 0 ] && [ $((i % 2)) -eq 0 ]; then
      state=$(crew_state)
      case "$state" in
        *'harness busy (agy-regex)'*)
          BUSY_SEEN=1
          BUSY_TAIL=$(pane_tail 4)
          ;;
      esac
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# Agy may render a one-time feedback survey over the composer after a turn;
# it is dismissed with its own "0 Skip" choice, never Enter, and recorded.
LAST_VERDICT=''
wait_idle_composer() {
  local i=0 verdict='' dismissed=0
  while [ "$i" -lt 60 ]; do
    verdict=$(composer_state)
    if [ "$verdict" = empty ]; then
      return 0
    fi
    if [ "$dismissed" -eq 0 ] && pane | grep -q "How's the CLI experience so far"; then
      SURVEY_SEEN=1
      note "agy $VERSION rendered its post-turn feedback survey over the composer; dismissing it with its own 0 (Skip) choice"
      tmux send-keys -t "$WINDOW" 0
      dismissed=1
    fi
    sleep 1
    i=$((i + 1))
  done
  LAST_VERDICT=$verdict
  return 1
}

# --- 4. Brief turn: unattended tool call, Stop hooks, continue, idle ---------
wait_marker || fail "agy $VERSION: the task Stop hook never touched state/$TASK.turn-ended within ${TIMEOUT}s after brief delivery"
[ -f "$WT/.fm-agy-live-probe" ] \
  || fail "agy $VERSION: the brief's shell command did not run unattended under --dangerously-skip-permissions"
pane | grep -q 'AGY_LIVE_OK' || fail "agy $VERSION: the brief turn did not reply AGY_LIVE_OK"
DETECTED=$(cat "$WT/.fm-agy-live-harness" 2>/dev/null || true)
TOOL_MARKER=$(cat "$WT/.fm-agy-live-marker" 2>/dev/null || true)
[ "$DETECTED" = agy ] \
  || fail "agy $VERSION: bin/fm-harness.sh run from inside a real Agy tool call detected '${DETECTED:-nothing}', not agy (marker in the tool child: '${TOOL_MARKER:-unset}')"
note "harness detection from inside the Agy tool call: fm-harness.sh printed '$DETECTED' with ANTIGRAVITY_AGENT='$TOOL_MARKER'"
pass "agy $VERSION: a tool child carries ANTIGRAVITY_AGENT and bin/fm-harness.sh detects agy from inside the live session"
payload_count() { jq -s 'length' "$PAYLOADS" 2>/dev/null || printf 0; }
[ "$(payload_count)" -ge 1 ] \
  || fail "agy $VERSION: the project-owned .agents Stop hook did not fire beside the task hook in .agent, so customization roots no longer merge"
jq -se --arg wt "$WT" 'all(.[]; .workspacePaths == [$wt])' "$PAYLOADS" >/dev/null \
  || fail "agy $VERSION: a Stop payload's workspacePaths no longer names exactly the task worktree"
note "Stop payload (execution zero, paths elided): $(jq -sc '.[0] | del(.transcriptPath, .artifactDirectoryPath)' "$PAYLOADS")"
pass "agy $VERSION: one Stop fired the project hook and the task hook, and the task hook touched the bound marker"
i=0
while [ "$i" -lt "$TIMEOUT" ] && [ "$(payload_count)" -lt 2 ]; do
  sleep 1
  i=$((i + 1))
done
EXECS=$(jq -sc 'map(.executionNum)' "$PAYLOADS")
[ "$EXECS" = '[0,1]' ] \
  || fail "agy $VERSION: the hook's continue decision did not produce exactly one follow-up execution within ${TIMEOUT}s (executionNum sequence $EXECS)"
[ "$(jq -s '[.[].conversationId] | unique | length' "$PAYLOADS")" -eq 1 ] \
  || fail "agy $VERSION: the continued execution changed conversation identity"
i=0
while [ "$i" -lt 60 ] && ! pane | grep -q 'AGY_NATIVE_CONTINUE_DONE'; do
  sleep 1
  i=$((i + 1))
done
pane | grep -q 'AGY_NATIVE_CONTINUE_DONE' \
  || fail "agy $VERSION: the continued execution did not deliver the hook's reason to the model"
pass "agy $VERSION: a Stop continue decision forced exactly one same-conversation follow-up, and the next Stop was allowed"
if wait_idle_composer; then
  pass "agy $VERSION: the real idle composer classifies empty through the shared separated-composer proof"
else
  fail "agy $VERSION: the idle composer never classified empty (last verdict: ${LAST_VERDICT:-unreadable}); tail: $(pane_tail 5 | tr '\n' '|')"
fi
note "idle composer tail:"
pane_tail 4 | indent

# --- 5. Steer through fm-send: doorbell honored, Stop hook fires again ------
rm -f "$MARKER"
FM_HOME="$LAB" "$ROOT/bin/fm-send.sh" "$TASK" \
  'Reply with exactly the single line AGY_STEER_OK. Do not run any command other than the inbox handling you were given.' \
  >/dev/null 2>&1 || fail "fm-send refused the live steer"
wait_marker || fail "agy $VERSION: no Stop hook fired within ${TIMEOUT}s after the fm-send steer"
[ -f "$LAB/state/$TASK.inbox/handled/001.msg" ] \
  || fail "agy $VERSION: the worker did not acknowledge the steering inbox record (no mv into handled/)"
pane | grep -q 'AGY_STEER_OK' || fail "agy $VERSION: the steered turn did not reply AGY_STEER_OK"
pass "agy $VERSION: fm-send's doorbell was read, acted on, acknowledged, and closed by the task Stop hook"

# --- 6. PreToolUse decision transport ---------------------------------------
# Agy renders a returned `{}` as a deny with an empty reason, so a seatbelt that
# answers an allowed command with an object silently blocks every shell call in
# a primary. Only silence allows.
rm -f "$MARKER"
FM_HOME="$LAB" "$ROOT/bin/fm-send.sh" "$TASK" \
  'Use your shell tool four separate times, once per numbered command line below, never combining them into one command line. 1) printf x > .fm-agy-seatbelt-allow  2) printf x > .fm-agy-seatbelt-object  3) printf x > .fm-agy-seatbelt-deny  4) printf x > .fm-agy-seatbelt-rc2 . A policy hook is expected to block some of them and that is the expected result: never retry a blocked one, and never create those files any other way. After all four attempts reply with exactly the single line AGY_SEATBELT_OK.' \
  >/dev/null 2>&1 || fail "fm-send refused the seatbelt steer"
wait_marker || fail "agy $VERSION: no Stop hook fired within ${TIMEOUT}s after the seatbelt steer"
PRETOOL_LOG="$LAB/pretool.log"
for rendering in silent-exit0 empty-object-exit0 deny-object-exit0 deny-object-exit2; do
  grep -qx "$rendering" "$PRETOOL_LOG" 2>/dev/null \
    || fail "agy $VERSION: the PreToolUse hook never received the $rendering probe; the worker did not attempt all four commands"
done
[ -f "$WT/.fm-agy-seatbelt-allow" ] \
  || fail "agy $VERSION: a PreToolUse hook that returned NOTHING at exit 0 did not allow the command; the seatbelt's allow rendering has drifted"
assert_seatbelt_blocked() {  # <sentinel> <what the hook returned>
  [ ! -e "$WT/.fm-agy-seatbelt-$1" ] \
    || fail "agy $VERSION: a PreToolUse hook that returned $2 did not block the command"
}
assert_seatbelt_blocked object 'an empty object {} at exit 0'
assert_seatbelt_blocked deny 'a deny decision object at exit 0'
assert_seatbelt_blocked rc2 'a deny decision object at exit 2'
note "PreToolUse renderings driven live: silence allowed, {} blocked, deny object blocked at exit 0 and at exit 2"
DENY_RENDER=$(pane | grep -i 'denied by pre-tool hook' | tail -1 | sed 's/^[[:space:]]*//')
if [ -n "$DENY_RENDER" ]; then
  note "deny surfaced to the model as: $DENY_RENDER"
else
  note "deny reason rendering not visible in the collapsed pane; the blocked sentinels are the assertion"
fi
pass "agy $VERSION: only a silent PreToolUse hook allows, and a returned object at either exit status blocks"

# --- 7. Busy footer and interrupt through fm-control -------------------------
rm -f "$MARKER"
FM_HOME="$LAB" "$ROOT/bin/fm-send.sh" "$TASK" \
  'Run exactly this shell command: sleep 120. Then reply with exactly the single line AGY_SLEEP_DONE.' \
  >/dev/null 2>&1 || fail "fm-send refused the long-turn steer"
i=0
while [ "$i" -lt "$TIMEOUT" ] && [ ! -f "$LAB/state/$TASK.inbox/handled/003.msg" ]; do
  sleep 1
  i=$((i + 1))
done
[ -f "$LAB/state/$TASK.inbox/handled/003.msg" ] \
  || fail "agy $VERSION: the worker did not acknowledge the third steering record within ${TIMEOUT}s"
BUSY_STATE=''
for _ in $(seq 1 30); do
  BUSY_STATE=$(crew_state)
  case "$BUSY_STATE" in *'harness busy (agy-regex)'*) break ;; esac
  sleep 1
done
case "$BUSY_STATE" in
  *'harness busy (agy-regex)'*) ;;
  *) fail "agy $VERSION: fm-crew-state never read the running sleep turn as busy (last: ${BUSY_STATE:-none}); the esc to cancel footer has drifted" ;;
esac
BUSY_TAIL=$(pane_tail 4)
note "busy pane tail (fm-crew-state: $BUSY_STATE):"
printf '%s\n' "$BUSY_TAIL" | indent
pass "agy $VERSION: a running turn classifies busy through the agy-regex footer source"

INT_OUT=$(FM_HOME="$LAB" "$ROOT/bin/fm-control.sh" "$TASK" interrupt 2>&1) \
  || fail "fm-control interrupt failed: $INT_OUT"
case "$INT_OUT" in
  *"interrupt-delivered $TASK harness=agy"*) ;;
  *) fail "fm-control interrupt reported something other than delivery: $INT_OUT" ;;
esac
note "fm-control: $INT_OUT"
# Two independent signals answer "did the single Escape cancel the turn?", and
# either carries a positive verdict, because the `Interrupted` banner is a
# rendering rather than the outcome. On 1.1.28 Agy may run a steered shell
# command through its own background task tracker (`N task(s)` in the footer);
# Escape then returns the agent to idle with no banner at all. The stage is not
# vacuous either way: the pane was just proved busy above, so the busy footer
# clearing is a real transition.
BANNER=0
BUSY_CLEARED=0
i=0
while [ "$i" -lt 60 ]; do
  pane | grep -q 'Interrupted' && BANNER=1
  case "$(crew_state)" in
    *'harness busy (agy-regex)'*) ;;
    *) BUSY_CLEARED=1 ;;
  esac
  if { [ "$BANNER" -eq 1 ] || [ "$BUSY_CLEARED" -eq 1 ]; } && [ "$(composer_state)" = empty ]; then
    break
  fi
  sleep 1
  i=$((i + 1))
done
[ "$BANNER" -eq 1 ] || [ "$BUSY_CLEARED" -eq 1 ] \
  || fail "agy $VERSION: within 60s of a single Escape the pane rendered no Interrupted banner AND fm-crew-state still read the turn busy; tail: $(pane_tail 5 | tr '\n' '|')"
wait_idle_composer || fail "agy $VERSION: the composer did not return to empty after the interrupt (last verdict: ${LAST_VERDICT:-unreadable})"
if [ "$BANNER" -eq 1 ]; then
  note "interrupt banner: $(pane | grep 'Interrupted' | tail -1 | sed 's/^[[:space:]]*//')"
else
  note "no Interrupted banner this run: Agy tracked the steered command as a background task, and Escape returned the agent to idle with the busy footer cleared"
fi
pass "agy $VERSION: single Escape ended the busy turn and returned the composer to idle"

# --- 8. Exit through fm-control, then teardown -------------------------------
EXIT_OUT=$(FM_HOME="$LAB" "$ROOT/bin/fm-control.sh" "$TASK" exit 2>&1) \
  || fail "fm-control exit failed: $EXIT_OUT"
case "$EXIT_OUT" in
  *"stopped $TASK harness=agy"*) ;;
  *) fail "fm-control exit reported something other than a stop: $EXIT_OUT" ;;
esac
pane | grep -q 'agy --conversation=' \
  || fail "agy $VERSION: /exit no longer prints the agy --conversation=<id> resume command; tail: $(pane_tail 5 | tr '\n' '|')"
note "exit tail:"
pane_tail 3 | indent
pass "agy $VERSION: /exit stopped the agent and printed the exact-conversation resume command"

printf 'Live adapter probe; the guard output is the deliverable.\n' > "$LAB/data/$TASK/report.md"
FM_HOME="$LAB" "$ROOT/bin/fm-captain-hold.sh" complete "$TASK" --none >/dev/null 2>&1 \
  || fail "could not attest the probe's empty captain-call inventory before teardown"
TD_OUT=$(FM_HOME="$LAB" "$ROOT/bin/fm-teardown.sh" "$TASK" 2>&1) || fail "fm-teardown failed: $TD_OUT"
TORN_DOWN=1
[ ! -e "$WT/.agent/hooks.json" ] || fail "teardown left the task hook in the borrowed .agent root"
[ -f "$WT/.agent/keep.md" ] || fail "teardown removed the project's borrowed .agent root or its content"
cmp -s "$WT/.agents/hooks.json" "$PROJ/.agents/hooks.json" \
  || fail "teardown touched the project-owned .agents/hooks.json"
[ ! -e "$WT/.fm-agy-turnend" ] || fail "teardown left the worktree turn-end pointer"
[ ! -e "$LAB/state/agy-turn-end.d/$TOKEN" ] || fail "teardown left the private auth entry"
[ ! -e "$TOKEN_FILE" ] || fail "teardown left the task token record"
pass "agy $VERSION: teardown retired only the task hook, pointer, and registry entry and left both project roots standing"

[ "$SURVEY_SEEN" -eq 0 ] || note "the post-turn feedback survey appeared once during this run and was skipped"
PASSED=1
pass "live Agy adapter guard: agy $VERSION drove spawn, hooks, steer, seatbelt decisions, busy, interrupt, exit, and teardown end to end"
