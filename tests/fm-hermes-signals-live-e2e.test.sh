#!/usr/bin/env bash
# Credentialed Hermes TUI guard. Use a throwaway, already configured profile:
# FM_HERMES_SIGNALS_LIVE=1 FM_HERMES_LIVE_HOME=<throwaway-root>
# FM_HERMES_LIVE_PROFILE=<name> (default worker). Never sends gateway messages or assigns
# domain work. The profile's own model and auth are used unchanged.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_HERMES_SIGNALS_LIVE hermes tmux jq python3
: "${FM_HERMES_LIVE_HOME:?provide a configured throwaway Hermes root}"
PROFILE=${FM_HERMES_LIVE_PROFILE:-worker}
HERMES_BIN=$(command -v hermes)
REAL_TMUX=$(command -v tmux)
VERSION="hermes $($HERMES_BIN --version 2>/dev/null | head -1)"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/hm.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
SOCKET="$LAB/tmux.sock"
cleanup() {
  "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1 || true
  if [ "${FM_HERMES_LIVE_KEEP:-0}" = 1 ]; then
    printf 'Hermes guard evidence: %s\n' "$LAB"
  else
    chmod -R u+w "$LAB" >/dev/null 2>&1 || true
    rm -rf "$LAB"
  fi
}
trap cleanup EXIT
fail() { printf 'not ok - %s: %s (evidence %s)\n' "$VERSION" "$1" "$LAB" >&2; exit 1; }
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# Observe the real first-run offer on a fresh uncredentialed profile. This
# sends no model prompt and never touches the configured live-check profile.
# shellcheck source=bin/fm-hermes-lib.sh
. "$ROOT/bin/fm-hermes-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
CONSENT_ROOT="$LAB/consent-root"
mkdir -p "$CONSENT_ROOT/profiles/consent"
printf '%s\n' '{"model":{"default":"gpt-6-astra","provider":"openai-codex"}}' > "$CONSENT_ROOT/profiles/consent/config.yaml"
printf 'exec env HERMES_HOME=%q %q -p consent --tui\n' "$CONSENT_ROOT" "$HERMES_BIN" > "$LAB/consent.sh"
"$REAL_TMUX" -S "$SOCKET" new-session -d -s native-consent -x 140 -y 44 "bash '$LAB/consent.sh'" || fail 'consent pane launch failed'
consent_seen=0
for _ in $(seq 1 240); do
  consent_screen=$("$REAL_TMUX" -S "$SOCKET" capture-pane -p -t native-consent)
  if [ "$(fm_hermes_startup_screen "$consent_screen")" = decline ]; then
    printf '%s\n' "$consent_screen" > "$LAB/consent.txt"
    "$REAL_TMUX" -S "$SOCKET" send-keys -t native-consent Enter
    consent_seen=1
    break
  fi
  sleep 0.5
done
[ "$consent_seen" = 1 ] || fail 'native selected No thanks offer not recognized'
for _ in $(seq 1 180); do
  consent_screen=$("$REAL_TMUX" -S "$SOCKET" capture-pane -p -t native-consent)
  [ "$(fm_hermes_startup_screen "$consent_screen")" = ready ] && break
  sleep 0.5
done
[ "$(fm_hermes_startup_screen "$consent_screen")" = ready ] || fail 'declining the native consent did not reach TUI readiness'
consent=$(HERMES_HOME="$CONSENT_ROOT" "$HERMES_BIN" -p consent config get telemetry.shared_metrics --json)
printf '%s\n' "$consent" | jq -e '.enabled == false and .send == false and .offer_version == 2' >/dev/null || fail 'native consent did not record decline'
"$REAL_TMUX" -S "$SOCKET" kill-session -t native-consent
pass "$VERSION: native first-run offer recognized, No thanks confirmed, TUI ready and decline persisted"
H="$LAB/home"
WT="$LAB/wt"
PROJ="$LAB/project"
ID=hermes-live
fm_test_spawn_home "$H" hermes
fm_git_worktree "$PROJ" "$WT" hermes-live
fm_test_spawn_brief "$H" "$ID" "Runtime verification only: use your terminal tool to write the sum of 12345 and 67890 into answer.txt. Run '$ROOT/bin/fm-harness.sh' and write its output into harness.txt. Append 'working: harmless live check' to '$H/state/$ID.status'. Do no other work, use no memory tools, do not delegate, send no messages, and do no domain work. Later read and acknowledge Firstmate's instruction inbox when its doorbell arrives."
fakebin=$(make_spawn_fakebin "$LAB/fake" claude)
ln -s "$HERMES_BIN" "$fakebin/hermes"
# Allocation is fixture-owned here; after staging, the real pane below must
# independently prove brief processing, native hooks and composer identity.
mv "$fakebin/tmux" "$fakebin/tmux-base"
cat > "$fakebin/tmux" <<'SH_TMUX'
#!/bin/sh
if [ "$1" = capture-pane ]; then
  printf ' ─ ready │ model │ 1s\n worker ❯ \n'
  exit 0
fi
exec "$(dirname "$0")/tmux-base" "$@"
SH_TMUX
chmod +x "$fakebin/tmux"

export HERMES_HOME="$FM_HERMES_LIVE_HOME"
unset HERMES_MANAGED_DIR
FM_FAKE_LAUNCH_LOG="$LAB/launch.sh" fm_test_run_spawn "$H" "$WT" "$fakebin" "$ID" "$PROJ" \
  --scout --harness hermes --hermes-profile "$PROFILE" > "$LAB/spawn.log" 2>&1 \
  || fail "fm-spawn: $(cat "$LAB/spawn.log")"
mkdir -p "$LAB/bin"
printf '#!/bin/sh\nexec "%s" -S "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/bin/tmux"
chmod +x "$LAB/bin/tmux"
export PATH="$LAB/bin:$PATH" FM_HOME="$H"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
TARGET="firstmate:fm-$ID"
"$REAL_TMUX" -S "$SOCKET" new-session -d -s firstmate -n "fm-$ID" -x 140 -y 44 -c "$WT" \
  "/bin/sh '$LAB/launch.sh'; exec /bin/bash --noprofile --norc" || fail 'could not launch visible pane'
capture() { tmux capture-pane -p -e -t "$TARGET"; }
wait_file() {
  local path=$1 i
  for i in $(seq 1 360); do [ -s "$path" ] && return 0; sleep 0.5; done
  capture > "$LAB/screen.ansi"
  fail "timed out waiting for ${path##*/}"
}
wait_idle() {
  local _
  for _ in $(seq 1 240); do
    if [ "$(fm_busy_classify tmux "$TARGET" hermes "$ID" "$H/state")" = 'idle hermes-hook' ]; then return 0; fi
    sleep 0.5
  done
  capture > "$LAB/screen.ansi"
  fail 'native end hook did not settle'
}
wait_file "$WT/answer.txt"
wait_file "$WT/harness.txt"
wait_file "$H/state/$ID.status"
[ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] || fail 'wrong launch result'
[ "$(tr -d '[:space:]' < "$WT/harness.txt")" = hermes ] || fail 'wrong tool harness detection'
wait_idle
[ -f "$H/state/$ID.turn-ended" ] || fail 'native end notification absent'
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'live worker not classified alive'
capture > "$LAB/idle.ansi"
[ "$(fm_backend_composer_state tmux "$TARGET")" = empty ] || fail 'idle composer not empty'
pass "$VERSION: interactive brief, native profile, tools, status, identity, busy and turn-end"
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime steering check: write 1147 into steer.txt. Read this exact instruction record through your Firstmate inbox and acknowledge it by moving its .msg into handled/. Use no memory, do not delegate or message anyone.' > "$LAB/send.log" 2>&1 || fail "steer: $(cat "$LAB/send.log")"
wait_file "$WT/steer.txt"
wait_file "$H/state/$ID.inbox/handled/001.msg"
wait_idle
pass "$VERSION: real steering inbox read and acknowledgement"
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/idle-interrupt.log" 2>&1 || fail "idle interrupt: $(cat "$LAB/idle-interrupt.log")"
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'idle interrupt exited the worker'
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime interrupt check only: run sleep 45 in your terminal tool, wait for it to finish, then write finished into after-sleep.txt. Do no other work.' > "$LAB/send2.log" 2>&1 || fail 'interrupt probe steer'
seen_busy=0
for _ in $(seq 1 240); do
  if [ "$(fm_busy_classify tmux "$TARGET" hermes "$ID" "$H/state")" = 'busy hermes-hook' ] && capture | fm_composer_strip_ansi | fm_busy_lines_match hermes; then seen_busy=1; break; fi
  sleep 0.5
done
[ "$seen_busy" = 1 ] || fail 'native semantic and rendered busy not observed'
capture > "$LAB/busy.ansi"
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/interrupt.log" 2>&1 || fail "interrupt: $(cat "$LAB/interrupt.log")"
wait_idle
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'interrupt exited the worker'
pass "$VERSION: idle interrupt preserves process; double-Escape cancels a turn and native end settles"
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "exit: $(cat "$LAB/exit.log")"
[ "$(fm_backend_agent_state tmux "$TARGET")" = dead ] || fail '/quit did not return to shell'
"$ROOT/bin/fm-control.sh" "$ID" relaunch --note "Harmless adapter verification: repeat only the original brief checks; do no other work." > "$LAB/relaunch.log" 2>&1 || fail "relaunch: $(cat "$LAB/relaunch.log")"
wait_idle
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'replacement not alive'
grep -q "hermes_profile=$PROFILE" "$H/state/$ID.meta" || fail 'relaunch lost profile'
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/final-exit.log" 2>&1 || fail 'replacement exit failed'
pass "$VERSION: /quit and deterministic relaunch retain profile and task endpoint"
