#!/usr/bin/env bash
# Credentialed Droid drift guard: exact ancestry, busy footer, Stop hook,
# composer delivery, interrupt, exit, scout relaunch, and Fish-backed ship exit
# through fm-control
# in an isolated tmux server and HOME.
# Opt-in because this submits real prompts; no shared backend is driven.
# FM_DROID_LIVE_MODEL optionally selects an authenticated model; otherwise the
# configured session model is retained while reasoning is pinned to dynamic.
set -u
unset FM_BUSY_REGEX
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_DROID_SIGNALS_LIVE droid tmux jq treehouse tasks-axi fish
DROID_BIN=$(command -v droid)
REAL_TMUX=$(command -v tmux)
FISH_BIN=$(command -v fish)
VERSION=$("$DROID_BIN" --version)
LAB=$(fm_test_tmproot fm-droid-signals)
SOCKET="fm-droid-signals-$$"
TARGET=droid-signals:droid
cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  if [ -n "${scout_id:-}" ] && [ -f "$LAB/fleet/state/$scout_id.meta" ]; then
    HOME="$LAB/home" FM_HOME="$LAB/fleet" "$ROOT/bin/fm-teardown.sh" "$scout_id" >/dev/null 2>&1 || true
  fi
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf -- "$LAB"
  fm_test_cleanup
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { printf 'not ok - Droid %s: %s\n' "$VERSION" "$1" >&2; exit 1; }
. "$ROOT/bin/fm-tasks-axi-lib.sh"
fm_tasks_axi_compatible || fail "scout teardown requires compatible tasks-axi (>= $FM_TASKS_AXI_MIN)"
# Read credentials into a private throwaway HOME without exposing their bytes.
mkdir -p "$LAB/home/.factory" "$LAB/workspace" "$LAB/state"
chmod 700 "$LAB/home" "$LAB/home/.factory"
for name in settings.json config.json auth.encrypted auth.v2.file auth.v2.key auth.v2.loginkeychain; do
  [ ! -f "$HOME/.factory/$name" ] || cp "$HOME/.factory/$name" "$LAB/home/.factory/$name"
done
# Global primary hooks and pre-existing folder trust do not belong in this lab.
if [ -f "$LAB/home/.factory/settings.json" ]; then
  jq 'del(.hooks,.trustedFolders,.enabledPlugins)' "$LAB/home/.factory/settings.json" > "$LAB/home/.factory/settings.clean.json"
  mv "$LAB/home/.factory/settings.clean.json" "$LAB/home/.factory/settings.json"
fi
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
model=${FM_DROID_LIVE_MODEL:-}
if [ -z "$model" ] && [ -f "$LAB/home/.factory/settings.json" ]; then
  model=$(jq -r '.sessionDefaultSettings.model // empty' "$LAB/home/.factory/settings.json")
fi
jq -n --arg model "$model" --arg cmd "touch '$LAB/state/turn-ended'" \
  '{sessionDefaultSettings:({autonomyLevel:"high",autonomyMode:"auto-high",interactionMode:"auto",reasoningEffort:"dynamic"} + (if $model == "" then {} else {model:$model} end)),hooks:{Stop:[{hooks:[{type:"command",command:$cmd}]}]}}' > "$LAB/state/settings.json"
git -C "$LAB/workspace" init -q -b main
git -C "$LAB/workspace" -c user.name=guard -c user.email=guard@local commit -q --allow-empty -m init
git -C "$LAB/workspace" worktree add -q "$LAB/task" -b guard
HOME="$LAB/home" "$ROOT/bin/fm-droid-trust.sh" "$LAB/task" "$LAB/workspace" >/dev/null || fail 'exact-worktree trust registration failed'

printf '# Droid guard\nOnly execute the explicit verification commands in the prompt.\n' > "$LAB/task/AGENTS.md"
capture() { "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -60; }
submit() {
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "$1" || fail 'cannot type prompt'
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter || fail 'cannot submit prompt'
}
# The sum proves a model response rather than matching the echoed prompt.
# The detection command writes into the lab, and the sleep holds a real busy turn.
prompt="Use Execute to run bash '$ROOT/bin/fm-harness.sh' > '$LAB/state/identity'; run sleep 8 after that command succeeds. Add 12345 and 67890 and reply only with the sum."
# Start the CLI directly: typing this long command before a shell has entered
# raw mode can truncate it at the terminal's canonical input limit.
"$REAL_TMUX" -L "$SOCKET" -f /dev/null new-session -d -s droid-signals -n droid -c "$LAB/task" -x 140 -y 45 \
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
  -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI -u FM_OMP_HARNESS \
  FM_TASK_ID=droid-signals HOME="$LAB/home" FM_HOME="$LAB/home" \
  FM_STATE_OVERRIDE="$LAB/state" FM_ROOT_OVERRIDE="$ROOT" \
  "$DROID_BIN" --settings "$LAB/state/settings.json" --auto high "$prompt" \
  || fail 'cannot create isolated tmux server'
busy=0
for _ in $(seq 1 180); do
  screen=$(capture) || fail 'cannot capture real Droid viewport'
  # Wait for a rendered frame carrying both native signals before blinding.
  footer_blinded=${screen//Press ESC to stop/}
  if [ "$footer_blinded" != "$screen" ] && printf '%s' "$footer_blinded" | fm_busy_droid_tail_busy; then
    busy=1
    break
  fi
  [ ! -e "$LAB/state/turn-ended" ] || break
  sleep 1
done
if [ "$busy" != 1 ]; then
  [ -z "${FM_DROID_LIVE_CAPTURE:-}" ] || printf '%s\n' "$screen" > "$FM_DROID_LIVE_CAPTURE"
  fail 'independent working signals no longer match the busy guard'
fi
footer_blinded=${screen//Press ESC to stop/}
[ "$footer_blinded" != "$screen" ] || fail 'footer-blinding probe checked nothing'
printf '%s' "$footer_blinded" | fm_busy_droid_tail_busy || fail 'working spinner lost busy state without the interrupt hint'
spinner_blinded=$(printf '%s' "$screen" | sed -E "s/$FM_DROID_SPINNER_FRAMES_RE//g")
[ "$spinner_blinded" != "$screen" ] || fail 'spinner-blinding probe checked nothing'
printf '%s' "$spinner_blinded" | fm_busy_droid_tail_busy || fail 'interrupt hint lost busy state without the spinner'
pass "Droid $VERSION independent working signals match the scoped busy guard"
for _ in $(seq 1 180); do
  [ ! -e "$LAB/state/turn-ended" ] || break
  sleep 1
done
[ -e "$LAB/state/turn-ended" ] || fail 'Stop settings hook did not fire'
[ "$(cat "$LAB/state/identity" 2>/dev/null)" = droid ] || fail 'tool subprocess ancestry did not detect Droid'
for _ in $(seq 1 30); do
  screen=$(capture)
  if ! printf '%s' "$screen" | fm_busy_droid_tail_busy; then break; fi
  sleep 1
done
printf '%s' "$screen" | grep -q '80,\?235' || fail 'computed response not observed'
if printf '%s' "$screen" | fm_busy_droid_tail_busy; then fail 'idle turn retains the busy footer'; fi
printf '%s' "$screen" | grep -q 'Auto (High)' || fail 'template autonomy lost to user session defaults'
pass "Droid $VERSION trusted worktree brief runs, exact ancestry detects Droid, and Stop fires"
mkdir -p "$LAB/shim"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
# Exercise the backend's actual cursor and foreground identity, not a
# cursorless approximation of the vendor's rendered screen.
. "$ROOT/bin/fm-tmux-lib.sh"
verdict=$(PATH="$LAB/shim:$PATH" fm_tmux_composer_state "$TARGET")
[ "$verdict" = empty ] || fail "idle composer classified $verdict"
pass "Droid $VERSION idle composer permits delivery"
submit /settings
sleep 1
screen=$(capture)
printf '%s' "$screen" | grep -q 'Default reasoning level.*Dynamic.*overridden by runtime --settings flag' || fail 'runtime dynamic effort was not applied'
if [ -n "$model" ]; then
  printf '%s' "$screen" | grep -q 'Default model.*overridden by runtime --settings flag' || fail 'native settings did not apply the requested model'
fi
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape
pass "Droid $VERSION process-local dynamic effort and requested model apply in native settings"
rm "$LAB/state/turn-ended"
submit 'Use Execute to run sleep 60. Afterwards add 45678 and 12345 and reply only with the sum.'
busy=0
for _ in $(seq 1 120); do
  screen=$(capture)
  if printf '%s' "$screen" | fm_busy_droid_tail_busy; then busy=1; break; fi
  sleep 1
done
[ "$busy" = 1 ] || fail 'second prompt never became busy'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape
for _ in $(seq 1 60); do
  screen=$(capture)
  if ! printf '%s' "$screen" | fm_busy_droid_tail_busy; then break; fi
  sleep 1
done
if printf '%s' "$screen" | fm_busy_droid_tail_busy; then fail 'single Escape did not interrupt'; fi
pass "Droid $VERSION single Escape interrupts a running turn"
current=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}')
[ "$current" = droid ] || fail 'Droid process was not live before the exit check'
submit /quit
for _ in $(seq 1 60); do
  current=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)
  [ "$current" = droid ] || break
  sleep 1
done
[ "$current" != droid ] || fail '/quit left Droid running'
pass "Droid $VERSION /quit exits the agent"
printf 'DROID_LIVE_RESULT version=%s detection=pass launch=pass busy=pass stop=pass composer=pass profile=pass interrupt=pass exit=pass\n' "$VERSION"

HOME="$LAB/home" "$ROOT/bin/fm-droid-trust.sh" --remove "$LAB/task" "$LAB/workspace" >/dev/null || fail 'exact-worktree trust cleanup failed'
physical=$(cd "$LAB/task" && pwd -P)
jq -e --arg logical "$LAB/task" --arg physical "$physical" '.trustedFolders | has($logical) == false and has($physical) == false' "$LAB/home/.factory/settings.json" >/dev/null || fail 'native settings retained task trust'
printf 'ok - Droid %s exact-worktree trust is retired after exit\n' "$VERSION"

# Verify recovery through the same public lifecycle entrypoints as a scout.
scout_id="droid-recovery-$$"
(
  "$ROOT/bin/fm-lab-home.sh" create "$LAB/fleet" >/dev/null || fail 'cannot create scout lab home'
  git clone -q "$LAB/workspace" "$LAB/project" || fail 'cannot create scout project'
  git -C "$LAB/project" config user.name guard
  git -C "$LAB/project" config user.email guard@local
  printf 'tmux\n' > "$LAB/fleet/config/backend"
  printf 'manual\n' > "$LAB/fleet/config/backlog-backend"
  mkdir -p "$LAB/fleet/data/$scout_id"
  report="$LAB/fleet/data/$scout_id/report.md"
  printf '# Task\nCalculate 12345 + 67890. Use Execute to write only the sum to %s and reply with it. Do not perform other tasks.\n' \
    "$report" > "$LAB/fleet/data/$scout_id/brief.md"
  export HOME="$LAB/home" FM_HOME="$LAB/fleet" TREEHOUSE_ROOT="$LAB/pool"
  export SHELL
  SHELL=$(command -v bash)
  unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s firstmate -x 140 -y 45 -c "$LAB/project" \
    "$SHELL" --noprofile --norc || fail 'cannot create scout endpoint'
  "$REAL_TMUX" -L "$SOCKET" set-option -g default-shell "$SHELL"
  export TMUX
  TMUX=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t firstmate '#{socket_path},#{pid},0')
  "$ROOT/bin/fm-spawn.sh" "$scout_id" "$LAB/project" --scout --harness droid --effort dynamic \
    || fail 'public scout launch failed'
  TARGET="firstmate:fm-$scout_id"
  wait_scout_idle() {
    for _ in $(seq 1 180); do
      if [ -f "$LAB/fleet/state/$scout_id.turn-ended" ] \
         && [ "$(PATH="$LAB/shim:$PATH" fm_tmux_composer_state "$TARGET")" = empty ] \
         && ! capture | fm_busy_droid_tail_busy; then
        return 0
      fi
      sleep 1
    done
    return 1
  }
  wait_scout_idle || fail 'scout did not complete its first turn with an empty composer'
  [ "$(tr -d '[:space:]' < "$report")" = 80235 ] || fail 'scout did not write the computed result'
  # The replacement must produce a new report and Stop event, not reuse either.
  rm "$report" "$LAB/fleet/state/$scout_id.turn-ended"
  "$ROOT/bin/fm-control.sh" "$scout_id" relaunch --note 'Repeat the original arithmetic verification and write the report again; do not perform other tasks.' \
    || fail 'idle scout relaunch through fm-control failed'
  wait_scout_idle || fail 'replacement scout did not complete its turn with an empty composer'
  [ "$(tr -d '[:space:]' < "$report")" = 80235 ] || fail 'replacement scout did not write the computed result'
  jq -e '.sessionDefaultSettings.reasoningEffort == "dynamic"' "$LAB/fleet/state/$scout_id.droid-settings.json" >/dev/null \
    || fail 'replacement lost the recorded dynamic effort'
  "$ROOT/bin/fm-control.sh" "$scout_id" exit || fail 'replacement scout exit through fm-control failed'
  # The verified arithmetic-only report leaves no captain decision pending.
  "$ROOT/bin/fm-captain-hold.sh" complete "$scout_id" --none || fail 'cannot inventory the completed arithmetic report'
  "$ROOT/bin/fm-teardown.sh" "$scout_id" || fail 'recovered scout teardown failed'
  pass "Droid $VERSION public scout relaunch completes a replacement turn with dynamic effort"

  # Treehouse launches the ship through tmux's default shell. Fish can remain
  # pane_current_command even while Droid owns the foreground input.
  "$REAL_TMUX" -L "$SOCKET" set-option -g default-shell "$FISH_BIN"
  ship_id="droid-fish-$$"
  report="$LAB/fleet/data/$ship_id/report.md"
  mkdir -p "$LAB/fleet/data/$ship_id"
  printf '# Task\n## Captain'\''s intent\nCalculate 12345 + 67890. Use Execute to write only the sum to "%s" and reply with it. Do not change project files, start validation, or perform other tasks.\n\n## Firstmate spec\nVerify launch only.\n' \
    "$report" > "$LAB/fleet/data/$ship_id/brief.md"
  "$ROOT/bin/fm-spawn.sh" "$ship_id" "$LAB/project" --harness droid --effort dynamic --mode no-mistakes --yolo off \
    || fail 'public Fish-backed ship launch failed'
  TARGET="firstmate:fm-$ship_id"
  for _ in $(seq 1 180); do
    [ ! -f "$LAB/fleet/state/$ship_id.turn-ended" ] || break
    sleep 1
  done
  [ -f "$LAB/fleet/state/$ship_id.turn-ended" ] && [ "$(tr -d '[:space:]' < "$report")" = 80235 ] \
    || fail 'Fish-backed ship did not complete its report and Stop hook'
  for _ in $(seq 1 30); do
    capture | fm_busy_droid_tail_busy || break
    sleep 1
  done
  PATH="$LAB/shim:$PATH" fm_tmux_pane_is_droid "$TARGET" || fail 'Fish-backed pane lacks exact foreground Droid identity'
  current=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}')
  cy=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{cursor_y}')
  printf 'DROID_FISH_IDLE command=%s cursor=%s\n' "$current" "$cy"
  [ "$(PATH="$LAB/shim:$PATH" fm_tmux_composer_state "$TARGET")" = empty ] \
    || fail 'Fish-backed idle composer was not proven empty'
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l 'unsent draft'
  if "$ROOT/bin/fm-control.sh" "$ship_id" exit > "$LAB/draft-exit.log" 2>&1; then
    fail 'Fish-backed exit accepted an unsent draft'
  fi
  capture | grep -q 'unsent draft' || fail 'Fish-backed refused exit lost the draft'
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" C-u
  for _ in $(seq 1 30); do
    [ "$(PATH="$LAB/shim:$PATH" fm_tmux_composer_state "$TARGET")" != empty ] || break
    sleep 1
  done
  "$ROOT/bin/fm-control.sh" "$ship_id" exit || fail 'idle Fish-backed ship exit through fm-control failed'
  if PATH="$LAB/shim:$PATH" fm_tmux_pane_is_droid "$TARGET"; then
    fail 'Fish-backed ship retained a foreground Droid after exit'
  fi
  pass "Droid $VERSION public Fish-backed ship exit preserves drafts and stops the idle agent"
)
