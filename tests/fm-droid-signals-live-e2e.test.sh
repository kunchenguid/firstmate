#!/usr/bin/env bash
# Credentialed Droid drift guard: exact ancestry, busy footer, Stop hook,
# composer delivery, interrupt, and exit in an isolated tmux server and HOME.
# Opt-in because this submits real prompts; no shared backend is driven.
# FM_DROID_LIVE_MODEL optionally selects an authenticated model; otherwise the
# configured session model is retained while reasoning is pinned to dynamic.
set -u
unset FM_BUSY_REGEX
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_DROID_SIGNALS_LIVE droid tmux jq
DROID_BIN=$(command -v droid)
REAL_TMUX=$(command -v tmux)
VERSION=$("$DROID_BIN" --version)
LAB=$(fm_test_tmproot fm-droid-signals)
SOCKET="fm-droid-signals-$$"
TARGET=droid-signals:droid
cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf -- "$LAB"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { printf 'not ok - Droid %s: %s\n' "$VERSION" "$1" >&2; exit 1; }
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
"$REAL_TMUX" -L "$SOCKET" new-session -d -s droid-signals -n droid -c "$LAB/task" -x 140 -y 45 \
  || fail 'cannot create isolated tmux server'
capture() { "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -60; }
submit() {
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "$1" || fail 'cannot type prompt'
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter || fail 'cannot submit prompt'
}
# The sum proves a model response rather than matching the echoed prompt.
# The detection command writes into the lab, and the sleep holds a real busy turn.
prompt="Use Execute to run bash '$ROOT/bin/fm-harness.sh' > '$LAB/state/identity'; run sleep 8 after that command succeeds. Add 12345 and 67890 and reply only with the sum."
printf -v command 'env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI -u FM_OMP_HARNESS FM_TASK_ID=droid-signals HOME=%q FM_HOME=%q FM_STATE_OVERRIDE=%q FM_ROOT_OVERRIDE=%q %q --settings %q --auto high %q' \
  "$LAB/home" "$LAB/home" "$LAB/state" "$ROOT" "$DROID_BIN" "$LAB/state/settings.json" "$prompt"
submit "$command"
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
caps=$'styled=0\ncursor=0\nidentity=0'
verdict=$(fm_composer_classify_screen "$caps" "$screen")
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
