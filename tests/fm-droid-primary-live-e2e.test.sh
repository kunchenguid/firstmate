#!/usr/bin/env bash
# Opt-in live guard for Droid's primary hook, foreground-tool, and composer facts.
# Requires an authenticated Droid installation and spends model tokens.
# Set FM_DROID_SPAWN_LIVE_ONLY=1 to refresh only the spawn trust/model evidence.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_DROID_PRIMARY_LIVE_E2E,FM_DROID_SPAWN_LIVE_ONLY droid tmux jq git

REAL_TMUX=$(command -v tmux)
SOCKET="fm-droid-primary-live-$$"
LAB=$(fm_test_tmproot fm-droid-primary-live)
PROJECT="$LAB/project"
SESSION=droid-primary-live

# Copy only the local authentication/configuration needed by this opt-in guard.
# Vendor writes and trust registration must never reach the operator's HOME.
mkdir -p "$LAB/home/.factory"
chmod 700 "$LAB/home" "$LAB/home/.factory"
for name in settings.json config.json auth.encrypted auth.v2.file auth.v2.key auth.v2.loginkeychain; do
  [ ! -f "$HOME/.factory/$name" ] || cp "$HOME/.factory/$name" "$LAB/home/.factory/$name"
done
if [ -f "$LAB/home/.factory/settings.json" ]; then
  jq 'del(.hooks,.trustedFolders,.enabledPlugins)' "$LAB/home/.factory/settings.json" >"$LAB/home/.factory/settings.clean.json"
  mv "$LAB/home/.factory/settings.clean.json" "$LAB/home/.factory/settings.json"
fi
export HOME="$LAB/home"

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

mkdir -p "$PROJECT/.factory" "$LAB/shim"
git init -q "$PROJECT"

cat >"$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# Drive the actual spawn gate with a fresh linked worktree on the same private
# tmux socket. The fake pool only supplies the lab-owned worktree; Droid and
# the entire settings, trust-answer, and progress-confirmation path are real.
SPAWN_PROJECT="$LAB/spawn-project"
SPAWN_WT="$LAB/spawn-worktree"
FLEET_HOME="$LAB/fleet"
SPAWN_ID=droid-live-spawn
SPAWN_SESSION=droid-spawn-live
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SPAWN_SESSION" -n setup -c "$PROJECT"
fm_git_worktree "$SPAWN_PROJECT" "$SPAWN_WT" droid-live-worktree
fm_test_spawn_home "$FLEET_HOME" droid
fm_test_spawn_brief "$FLEET_HOME" "$SPAWN_ID" \
  'Reply with exactly DROID_LIVE_SPAWN_READY and end your turn. Do not use tools.'
cat >"$LAB/shim/treehouse" <<SH
#!/usr/bin/env bash
case "\${1:-}" in get) printf '%s\n' '$SPAWN_WT' ;; esac
SH
chmod +x "$LAB/shim/treehouse"

# Establish the control arm without submitting a prompt. This worktree has
# never been opened, and launch must be proven to have needed trust handling.
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SPAWN_SESSION:" -n trust-control -c "$SPAWN_WT" -- droid --auto high
control=
for _ in $(seq 1 120); do
  control=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SPAWN_SESSION:trust-control" -S -0)
  if printf '%s' "$control" | grep -Fq 'Trust this folder?'; then break; fi
  sleep 0.5
done
printf '%s' "$control" | grep -Fq 'Trust this folder?' ||
  fail "Droid $(droid --version): fresh-worktree control did not expose folder trust"
printf '%s' "$control" | grep -Eq '^> 1\. Trust this folder[[:space:]]*$' ||
  fail "Droid $(droid --version): affirmative trust selection drifted"
printf '%s' "$control" | grep -Fq '2. Exit without trusting' ||
  fail "Droid $(droid --version): negative trust choice drifted"
printf '%s' "$control" | grep -Fq 'Enter to confirm' ||
  fail "Droid $(droid --version): trust navigation hint drifted"
"$REAL_TMUX" -L "$SOCKET" kill-window -t "$SPAWN_SESSION:trust-control"

if ! spawn_output=$(FM_HOME="$FLEET_HOME" FM_ROOT_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
  TMUX="$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SPAWN_SESSION:setup" '#{socket_path}'),1,0" \
  bash "$ROOT/bin/fm-spawn.sh" "$SPAWN_ID" "$SPAWN_PROJECT" --scout --harness droid 2>&1); then
  printf '%s\n' "$spawn_output"
  fail "Droid $(droid --version): real spawn did not clear folder trust and start its brief"
fi
assert_contains "$spawn_output" "spawned $SPAWN_ID harness=droid" 'live Droid spawn did not report success'
spawn_target=$(sed -n 's/^window=//p' "$FLEET_HOME/state/$SPAWN_ID.meta")
spawn_capture=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$spawn_target" -S -0) ||
  fail "Droid $(droid --version): launched pane could not be captured"
if printf '%s' "$spawn_capture" | grep -Fq 'Trust this folder?'; then
  fail "Droid $(droid --version): successful spawn still shows folder trust"
fi
jq -e '(.sessionDefaultSettings // {}) | has("model") | not' \
  "$FLEET_HOME/state/$SPAWN_ID.droid-settings.json" >/dev/null ||
  fail "Droid $(droid --version): default observation pinned the model"
assert_equals "default" "$(sed -n 's/^model=//p' "$FLEET_HOME/state/$SPAWN_ID.meta")" 'live Droid launch lost default selection'
spawn_gen=$(sed -n 's/^spawn_gen=//p' "$FLEET_HOME/state/$SPAWN_ID.meta")
observation="$FLEET_HOME/state/$SPAWN_ID.meta.droid-model.$spawn_gen"
observed_model=
for _ in $(seq 1 120); do
  [ ! -s "$observation" ] || observed_model=$(cat "$observation")
  [ -z "$observed_model" ] || break
  sleep 0.5
done
case "$observed_model" in '' | default | unknown-at-spawn) fail 'live Droid did not report a concrete runtime model' ;; esac
bash "$ROOT/bin/fm-droid-model.sh" reconcile "$FLEET_HOME/state/$SPAWN_ID.meta" "$spawn_gen"
assert_equals "$observed_model" "$(sed -n 's/^effective_model=//p' "$FLEET_HOME/state/$SPAWN_ID.meta")" 'live Droid runtime reconciliation failed'
printf 'Droid %s live spawn: trust cleared; effective_model=%s; runtime model override absent\n' \
  "$(droid --version)" "$observed_model"
pass "Droid live spawn: fresh-worktree folder trust is answered and the default model is observed"

# Exercise a real exact native pin against a conflicting project default.
# The installed catalog must advertise both IDs; there is no guessed fallback.
PIN_MODEL=gpt-6.1-sol
bash "$ROOT/bin/fm-droid-model.sh" resolve "$PIN_MODEL" >/dev/null ||
  fail "Droid $(droid --version): native pin is not in the installed catalog"
bash "$ROOT/bin/fm-droid-model.sh" resolve auto >/dev/null ||
  fail "Droid $(droid --version): conflicting default is not in the installed catalog"
mkdir -p "$SPAWN_WT/.factory"
printf '.factory/\n' >>"$SPAWN_PROJECT/.git/info/exclude"
printf '%s\n' '{"sessionDefaultSettings":{"model":"auto","reasoningEffort":"low"}}' \
  >"$SPAWN_WT/.factory/settings.local.json"
# Retire only the lab-owned default probe before reusing its scratch worktree.
# Keep model selection verification independent of rendered composer lifecycle.
"$REAL_TMUX" -L "$SOCKET" kill-window -t "$spawn_target"
SPAWN_ID=droid-live-pin
fm_test_spawn_brief "$FLEET_HOME" "$SPAWN_ID" \
  'Reply with exactly DROID_LIVE_PIN_READY and end your turn. Do not use tools.'
if ! pinned_spawn_output=$(FM_HOME="$FLEET_HOME" FM_ROOT_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
  TMUX="$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SPAWN_SESSION:setup" '#{socket_path}'),1,0" \
  bash "$ROOT/bin/fm-spawn.sh" "$SPAWN_ID" "$SPAWN_PROJECT" --scout --harness droid \
  --model "$PIN_MODEL" --effort high 2>&1); then
  printf '%s\n' "$pinned_spawn_output"
  fail "Droid $(droid --version): exact native pin spawn failed"
fi
spawn_gen=$(sed -n 's/^spawn_gen=//p' "$FLEET_HOME/state/$SPAWN_ID.meta")
for _ in $(seq 1 120); do
  bash "$ROOT/bin/fm-droid-model.sh" reconcile "$FLEET_HOME/state/$SPAWN_ID.meta" "$spawn_gen"
  [ "$(sed -n 's/^effective_model=//p' "$FLEET_HOME/state/$SPAWN_ID.meta")" != "$PIN_MODEL" ] || break
  sleep 0.5
done
assert_equals "$PIN_MODEL" "$(sed -n 's/^model=//p' "$FLEET_HOME/state/$SPAWN_ID.meta")" 'live spawn changed requested native ID'
assert_equals "$PIN_MODEL" "$(sed -n 's/^effective_model=//p' "$FLEET_HOME/state/$SPAWN_ID.meta")" 'live spawn did not reconcile runtime native ID'
spawn_target=$(sed -n 's/^window=//p' "$FLEET_HOME/state/$SPAWN_ID.meta")
# Capture the model row once per incarnation, and exclude the autonomy label:
# Auto (High) is not evidence of the model's reasoning effort.
pin_capture=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$spawn_target" -S -0)
pin_indicator=$(printf '%s\n' "$pin_capture" | sed -n '/GPT-6[.]1 Sol/p' | sed 's/Auto.*//')
if printf '%s' "$pin_indicator" | grep -Fq '(High)'; then
  printf 'Droid %s live spawn: requested=%s/high; observed=%s/(High); project default=auto/low\n' \
    "$(droid --version)" "$PIN_MODEL" "$PIN_MODEL"
else
  printf 'Droid %s live spawn: observed=%s; effort indicator unverified (no model-row High indicator)\n' \
    "$(droid --version)" "$PIN_MODEL"
fi
pass 'Droid live spawn: exact native runtime model overrides conflicting project defaults'

# Let the lab's synthetic prompt finish before the one bounded relaunch probe.
for _ in $(seq 1 120); do
  [ ! -f "$FLEET_HOME/state/$SPAWN_ID.turn-ended" ] || break
  sleep 0.5
done
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
if relaunch_output=$(FM_HOME="$FLEET_HOME" FM_ROOT_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
  fm_run_timed 90 bash "$ROOT/bin/fm-control.sh" "$SPAWN_ID" relaunch --effort medium \
  --note 'Reply with exactly DROID_LIVE_RELAUNCH_READY and end your turn. Do not use tools.' 2>&1); then
  spawn_target=$(sed -n 's/^window=//p' "$FLEET_HOME/state/$SPAWN_ID.meta")
  relaunch_capture=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$spawn_target" -S -0)
  relaunch_indicator=$(printf '%s\n' "$relaunch_capture" | sed -n '/GPT-6[.]1 Sol/p' | sed 's/Auto.*//')
  if printf '%s' "$relaunch_indicator" | grep -Fq '(Medium)'; then
    printf 'Droid %s live relaunch: observed=%s/(Medium) after high-to-medium change\n' "$(droid --version)" "$PIN_MODEL"
  else
    printf 'Droid %s live relaunch: effort indicator unverified (no model-row Medium indicator)\n' "$(droid --version)"
  fi
else
  # Keep this optional evidence boundary explicit without copying other startup
  # diagnostics, which can include account or provider information.
  if printf '%s' "$relaunch_output" | grep -Fq "composer state is 'pending-unproven'"; then
    printf '%s\n' 'Droid live relaunch: unverified; composer guard refused pending-unproven state before /quit'
  else
    printf '%s\n' 'Droid live relaunch: unverified; bounded control probe did not confirm replacement'
  fi
fi

if [ "${FM_DROID_SPAWN_LIVE_ONLY:-0}" = 1 ]; then
  printf 'ok - Droid %s spawn live verification complete\n' "$(droid --version)"
  exit 0
fi

cat >"$PROJECT/.factory/sessionstart.sh" <<'SH'
#!/usr/bin/env bash
cat > .factory/sessionstart-payload.json
printf '%s\n' 'Startup nonce: DROID_LIVE_SESSIONSTART_8291. When asked, report SESSIONSTART_OBSERVED_ followed by the nonce.'
SH

cat >"$PROJECT/.factory/pretool.sh" <<'SH'
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

cat >"$PROJECT/.factory/stop.sh" <<'SH'
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

cat >"$PROJECT/.factory/settings.json" <<'JSON'
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
  if [ "$trust_confirmed" -eq 0 ] &&
    printf '%s' "$capture" | grep -q 'Trust this folder?'; then
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:hooks" Enter
    trust_confirmed=1
  fi
  if [ -s "$PROJECT/.factory/stop-payloads.jsonl" ] &&
    [ "$(wc -l <"$PROJECT/.factory/stop-payloads.jsonl" | tr -d ' ')" -ge 2 ] &&
    printf '%s' "$capture" | grep -q 'DROID_LIVE_STOP_ALLOW'; then
    break
  fi
  sleep 0.5
done

printf '%s' "$capture" | grep -q 'SESSIONSTART_OBSERVED_DROID_LIVE_SESSIONSTART_8291' ||
  fail "Droid SessionStart stdout did not reach model-visible context"
[ ! -e "$PROJECT/droid-live-denied-sentinel" ] ||
  fail "Droid PreToolUse denial did not stop the command before execution"
jq -e 'select(.hook_event_name == "SessionStart" and .source == "startup")' \
  "$PROJECT/.factory/sessionstart-payload.json" >/dev/null ||
  fail "Droid SessionStart payload did not carry source=startup"
jq -s -e 'any(.[]; .hook_event_name == "PreToolUse" and .tool_name == "Execute" and .tool_input.command == "touch droid-live-denied-sentinel")' \
  "$PROJECT/.factory/pretool-payloads.jsonl" >/dev/null ||
  fail "Droid PreToolUse payload shape drifted"
jq -s -e 'length >= 2 and .[0].stop_hook_active == false and .[1].stop_hook_active == true' \
  "$PROJECT/.factory/stop-payloads.jsonl" >/dev/null ||
  fail "Droid Stop blocking or stop_hook_active loop semantics drifted"
pass "Droid live primary hooks: project settings, SessionStart, PreToolUse, Stop blocking, and loop guard"

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

for _ in $(seq 1 60); do
  [ "$(fm_tmux_composer_state "$SESSION:hooks")" = empty ] && break
  sleep 0.25
done
fm_tmux_pane_is_droid "$SESSION:hooks" ||
  fail "Droid live pane lost exact foreground-process identity"
[ "$(fm_tmux_composer_state "$SESSION:hooks")" = empty ] ||
  fail "Droid live idle composer did not classify empty"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:hooks" -l DROID_LIVE_TYPED
sleep 0.5
[ "$(fm_tmux_composer_state "$SESSION:hooks")" = pending ] ||
  fail "Droid live typed composer did not classify pending"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:hooks" C-u
pass "Droid live composer: detached cursor remains safe for idle and typed input"

"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n foreground -c "$PROJECT" -- \
  droid --auto high \
  "Run this exact foreground shell command: bash -lc 'touch .factory/foreground-running; sleep 20; rm .factory/foreground-running; echo DROID_LIVE_TOOL_DONE'. While it is still running, visibly publish the concatenation of DROID_LIVE_MIDCALL_ and UPDATE. After it completes, publish the concatenation of DROID_LIVE_FOREGROUND_ and FINISHED."

running_capture=
for _ in $(seq 1 80); do
  running_capture=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:foreground" -S -80 2>/dev/null || true)
  if [ -e "$PROJECT/.factory/foreground-running" ] &&
    printf '%s' "$running_capture" | grep -q 'Press ESC to stop'; then
    break
  fi
  sleep 0.25
done
[ -e "$PROJECT/.factory/foreground-running" ] ||
  fail "Droid live foreground probe was no longer active during its busy capture"
printf '%s' "$running_capture" | grep -q 'Press ESC to stop' ||
  fail "Droid live foreground probe never exposed the verified busy token"
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
' ||
  fail "Droid did not resume reasoning after the foreground tool completed"
pass "Droid live foreground tool: no reasoning continuation until tool completion"

printf 'ok - Droid %s primary live verification complete\n' "$(droid --version)"
