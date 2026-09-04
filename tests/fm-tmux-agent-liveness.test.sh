#!/usr/bin/env bash
# tests/fm-tmux-agent-liveness.test.sh - portable regression for the tmux
# agent-liveness classifier (bin/backends/tmux.sh).
#
# It runs REAL processes in a REAL tmux server on a private socket (`-L`), and
# needs no harness and no credentials, so it runs everywhere CI runs tmux. The
# live per-harness counterpart is tests/fm-harness-liveness-drift-live-e2e.test.sh.
#
# The defect it exists for: a harness that rewrites its own process title made
# `#{pane_current_command}` report a version string, the classifier could not
# attribute the pane, and supervision lost the agent. The version-string case
# below carries the proof that the verdict never depends on a single name
# surface: it drives the two sources apart on purpose and asserts that
# divergence, so it cannot go quietly vacuous. tmux and `ps -o comm=` read
# different name surfaces, and which one a given construction blinds differs
# between macOS and Linux, so every case asserts only the platform-independent
# property that the verdict itself is correct.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-liveness-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-liveness.XXXXXX")
SESSION=liveness

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

# A `tmux` shim on PATH so bin/backends/tmux.sh's bare `tmux` calls reach the
# private socket and never touch the host's real sessions.
mkdir -p "$LAB/shim" "$LAB/bin" "$LAB/bin/claude" "$LAB/bin/decoy" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# Stand-in "harness" binaries. These are SYMLINKS to a real long-running system
# binary, never copies: a copied platform binary fails code-signing validation
# and is killed on macOS arm64. The symlink name is what the kernel records as
# the executable identity, which is exactly the signal under test.
ln -s "$SLEEP_BIN" "$LAB/bin/claude-link"
ln -s "$SLEEP_BIN" "$LAB/bin/pi"
ln -s "$SLEEP_BIN" "$LAB/bin/notaharness"
# muse's installed binary is muse-bin-<version>: the launcher execs it, so the
# version is the LIVE process name and it changes on every auto-update. Unlike
# Claude Code's version-named binary there is no `muse` path component to fall
# back on (~/.local/bin/muse-bin-<version>), so the executable name is the ONLY
# signal, and `muse` alone is a common English fragment that must not widen into
# a substring match. The last two names are the decoys that would be misread.
ln -s "$SLEEP_BIN" "$LAB/bin/muse-bin-0.1.0-R708.1"
ln -s "$SLEEP_BIN" "$LAB/bin/musescore"
ln -s "$SLEEP_BIN" "$LAB/bin/amuse"
ln -s "$SLEEP_BIN" "$LAB/bin/muse-binary"
ln -s "$SLEEP_BIN" "$LAB/bin/muse-bind"

# A launcher whose own process identity is a bare shell, running the harness as
# a child in the same foreground process group - the shape the real Pi Launcher
# path takes, and the one where trusting a single name source can produce a
# false `dead`.
cat > "$LAB/bin/agent-launcher" <<SH
#!/bin/sh
"$LAB/bin/pi" 900 &
wait
SH
chmod +x "$LAB/bin/agent-launcher"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n idle -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# Run the pane's process DIRECTLY as the window command rather than typing into
# a shell, so no case depends on interactive shell readiness.
new_window() {  # <name> <cmd...>
  local name=$1
  shift
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$name" -c "$LAB/wt" -- "$@" \
    || fail "could not create window $name"
}

wait_for_state() {  # <target> <expected> [tries]
  local target=$1 expected=$2 tries=${3:-100} got i=0
  while [ "$i" -lt "$tries" ]; do
    got=$(fm_backend_agent_state tmux "$target")
    [ "$got" = "$expected" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  printf 'last verdict for %s was %s (expected %s); title=%s comms=[%s]\n' \
    "$target" "${got:-<none>}" "$expected" \
    "$(fm_backend_tmux_current_command "$target")" \
    "$(fm_backend_tmux_foreground_comms "$target" | tr '\n' ' ')" >&2
  return 1
}

# Does the tmux current-command source, on its own, name a verified harness?
title_classifies_agent() {  # <target>
  local name
  name=$(fm_backend_tmux_current_command "$1" 2>/dev/null)
  [ "$(fm_backend_tmux_classify_process_name "$name")" = agent ]
}

# Does the foreground-process-group identity, including argv[0], name one?
comms_classify_agent() {  # <target>
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$(fm_backend_tmux_classify_process_name "$name")" = agent ] && return 0
  done <<EOF
$(fm_backend_tmux_foreground_comms "$1")
EOF
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$(fm_backend_tmux_classify_process_name '' "$name")" = agent ] && return 0
  done <<EOF
$(fm_backend_tmux_foreground_argv0s "$1")
EOF
  return 1
}

# The core anti-brittleness assertion: the two name sources must genuinely
# DISAGREE for this case, so a verdict of alive proves the surviving source
# carried it. Without this the divergence cases could silently go vacuous.
assert_sources_disagree() {  # <target> <label>
  local t=0 c=0
  title_classifies_agent "$1" && t=1
  comms_classify_agent "$1" && c=1
  [ $((t + c)) -eq 1 ] || fail \
    "$2: the two name sources were expected to disagree, but title=$t comms=$c (title='$(fm_backend_tmux_current_command "$1")' comms='$(fm_backend_tmux_foreground_comms "$1" | tr '\n' ' ')')"
}

# --- a harness-named foreground process -------------------------------------
# Invoking the symlink by its harness name proves the ordinary positive path
# with a real process. macOS exposes different names for the symlink through
# tmux and ps, while Linux can expose the symlink name through both, so the
# version-string case below owns the cross-platform divergence assertion.

new_window agent "$LAB/bin/claude-link" 900
wait_for_state "$SESSION:agent" alive \
  || fail "a running harness-named foreground process must classify alive"
pass "tmux liveness: a harness-named foreground process classifies alive"

# --- muse's version-suffixed binary name ------------------------------------
# A muse crewmate pane misclassified here reads as a dead endpoint, so a healthy
# worker would be torn down or relaunched. The decoys below are what keep the
# fix from being a substring match that claims unrelated programs.

new_window muse "$LAB/bin/muse-bin-0.1.0-R708.1" 900
wait_for_state "$SESSION:muse" alive \
  || fail "muse's version-suffixed binary name must classify alive"
pass "tmux liveness: muse's version-suffixed muse-bin-<version> classifies alive"

for decoy in musescore amuse muse-binary muse-bind; do
  new_window "decoy-$decoy" "$LAB/bin/$decoy" 900
  wait_for_state "$SESSION:decoy-$decoy" ambiguous \
    || fail "'$decoy' merely contains 'muse' and must not classify as a live agent pane"
done
pass "tmux liveness: unrelated muse-containing command names stay ambiguous"

# --- a version name blinds one source ---------------------------------------
# Giving a genuine harness-named executable the version-string argv[0] that
# Claude Code 2.1.220 reports drives the two sources apart on both supported
# platforms and proves the surviving source carries the verdict. This needs a
# real executable file rather than a symlink, because macOS takes the title
# from the resolved target's name, so it is skipped where no C compiler exists.

CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
if [ -n "$CC_BIN" ] &&
  printf '%s\n' '#include <unistd.h>' 'int main(void){for(;;)sleep(60);return 0;}' > "$LAB/spin.c" &&
  "$CC_BIN" -o "$LAB/bin/claude/2.1.220" "$LAB/spin.c" 2>/dev/null &&
  "$CC_BIN" -o "$LAB/bin/decoy/2.1.220" "$LAB/spin.c" 2>/dev/null; then
  new_window titled "$LAB/bin/claude/2.1.220"
  wait_for_state "$SESSION:titled" alive \
    || fail "a version-named executable under a harness install path must classify alive"
  assert_sources_disagree "$SESSION:titled" "version-string process name"
  pass "tmux liveness: a version-named executable under a harness install path classifies alive"

  new_window path-decoy "$LAB/bin/decoy/2.1.220"
  wait_for_state "$SESSION:path-decoy" ambiguous \
    || fail "a version-named executable without a whole harness path component must stay ambiguous"
  pass "tmux liveness: a version-named executable under a decoy path stays ambiguous"
else
  echo "skip: no C compiler, so the version-string process-name case cannot build its executable"
fi

# --- neither source names a harness: no invented agent ----------------------

new_window unknown bash -c "exec -a 2.1.220 '$LAB/bin/notaharness' 900"
wait_for_state "$SESSION:unknown" ambiguous \
  || fail "a foreground process no name source attributes must stay ambiguous"
pass "tmux liveness: a process neither name source attributes stays ambiguous rather than inventing an agent"

# --- a launcher whose own identity reads as a bare shell --------------------
# The single-source classifier would read this pane as an idle shell and call
# it dead - the one verdict that can start a duplicate agent on a live worktree.

new_window launcher "$LAB/bin/agent-launcher"
wait_for_state "$SESSION:launcher" alive \
  || fail "a launcher running a harness child must classify alive, never dead"
comms_classify_agent "$SESSION:launcher" \
  || fail "the launcher's harness child must be visible in the foreground process group"
pass "tmux liveness: a launcher whose own identity reads as a bare shell classifies alive from its harness child"

# --- an idle shell is still confidently dead --------------------------------

wait_for_state "$SESSION:idle" dead \
  || fail "an idle shell pane must classify dead"
pass "tmux liveness: an idle shell pane classifies dead"

# --- a harness-named BACKGROUND process must not fake an agent --------------
# Scoping to the foreground process group is what prevents this false alive; a
# descendant walk of the pane would report this pane as running an agent.
# `set -m` gives the background job its own process group, which is what an
# interactive shell does for a job an exited agent left behind.

new_window background bash -c "set -m; '$LAB/bin/claude-link' 900 & printf '%s\n' \"\$!\" > '$LAB/bg.pid'; exec /bin/sh"
bg_pid=
for _ in $(seq 1 100); do
  [ -s "$LAB/bg.pid" ] && bg_pid=$(cat "$LAB/bg.pid") && break
  sleep 0.1
done
[ -n "$bg_pid" ] || fail "the background harness-named process never started"
kill -0 "$bg_pid" 2>/dev/null \
  || fail "the background harness-named process is not running, so this case would prove nothing"
wait_for_state "$SESSION:background" dead \
  || fail "a pane whose only harness-named process is backgrounded must classify dead"
kill -0 "$bg_pid" 2>/dev/null \
  || fail "the background harness-named process died during the check, so this case proves nothing"
pass "tmux liveness: a harness-named background process in an idle pane still classifies dead"

# --- an absent window never inherits tmux's active-window fallback ----------
# tmux answers a display-message for an absent target from the CLIENT's active
# window instead of failing, so both raw name reads can describe a completely
# different pane. The classifier's window-membership check is what contains
# that, and this case proves the composed verdict does not inherit it.

fm_backend_tmux_foreground_comms "$SESSION:no-such-window" >/dev/null \
  || fail "the foreground-comms read must stay best-effort for an absent window"
[ "$(fm_backend_agent_state tmux "$SESSION:no-such-window")" = missing ] \
  || fail "an absent window in a readable session must classify missing, not whatever the fallback pane runs"
pass "tmux liveness: an absent window classifies missing rather than inheriting tmux's active-window fallback"

# The same fallback reached the CHEAP probe too. fm_backend_target_exists is a
# boolean that could not return false: its tmux arm was a bare
# `display-message -t <target>`, which the fallback answers from the active
# window for ANY name, so the session-start fleet digest printed `endpoint:
# alive` for a task whose window had been gone for days. The raw-primitive
# assertion first is what keeps this case non-vacuous: it proves the trap is
# still live in this tmux, so the probe's false is the containment working and
# not tmux having changed under the test.
tmux display-message -p -t "$SESSION:no-such-window" '#{pane_id}' >/dev/null 2>&1 \
  || fail "the raw pane read no longer resolves an absent window, so this case would prove nothing about the probe"
if fm_backend_target_exists tmux "$SESSION:no-such-window" "no-such-window"; then
  fail "the cheap existence probe must reject an absent window instead of inheriting tmux's active-window fallback"
fi
pass "tmux liveness: the cheap existence probe rejects an absent window"

fm_backend_target_exists tmux "$SESSION:idle" "idle" \
  || fail "the cheap existence probe must still accept a window that really exists"
pass "tmux liveness: the cheap existence probe still accepts a present window"

if fm_backend_target_exists tmux "no-such-session-$$:idle" "idle"; then
  fail "the cheap existence probe must reject a target in a session that does not exist"
fi
pass "tmux liveness: the cheap existence probe rejects an absent session"

# --- the shared tmux target parser -----------------------------------------
# Every tmux liveness read now resolves through one owner,
# fm_backend_tmux_target_presence, because three separate approximations of
# tmux target parsing (this probe, the recovery classifier, and
# fm-crew-state.sh's pane_readable) each mis-parsed a different target shape.
# The cases below are the shapes that were mis-parsed, each reproduced against
# a real tmux server. Every one of them FAILS against the pre-parser code.
#
# The probe's boolean collapses both `missing` and `unreadable` onto false,
# while the recovery-grade classifier keeps them apart, so the presence
# vocabulary is asserted directly alongside the boolean.

[ "$(fm_backend_tmux_target_presence "$SESSION:idle")" = present ] \
  || fail "a real window must read present"
[ "$(fm_backend_tmux_target_presence "$SESSION:no-such-window")" = missing ] \
  || fail "an absent window in a readable session must read missing"
[ "$(fm_backend_tmux_target_presence "no-such-session-$$:idle")" = missing ] \
  || fail "an authoritatively absent session must read missing"
[ "$(fm_backend_tmux_target_presence "$SESSION:a:b")" = unreadable ] \
  || fail "a multi-colon target cannot be parsed safely and must read unreadable, never missing"
if fm_backend_target_exists tmux "$SESSION:a:b"; then
  fail "a multi-colon tmux target must not fall through to a raw pane read, which tmux answers from the active window"
fi
[ "$(fm_backend_tmux_target_presence ":idle")" = unreadable ] \
  || fail "an empty session component is ambiguous and must read unreadable"
pass "tmux liveness: the shared target parser keeps missing and unreadable apart"

# A window INDEX is a valid tmux target and firstmate ships one as a default:
# bin/fm-supervisor-target-lib.sh sets FM_SUPERVISOR_TARGET_DEFAULT=firstmate:0,
# the documented away-mode fallback. Rejecting it would stop the supervise
# daemon starting and make it defer every escalation to the captain.
idle_index=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:idle" '#{window_index}')
[ -n "$idle_index" ] || fail "could not read the idle window's index"
fm_backend_target_exists tmux "$SESSION:$idle_index" \
  || fail "a live window addressed by INDEX must be accepted; firstmate's own documented supervisor default is session:0"
if fm_backend_target_exists tmux "$SESSION:99999"; then
  fail "an ABSENT window index must still be rejected; tmux answers it from the active window just like an absent name"
fi
pass "tmux liveness: live window indexes are accepted and absent ones are not"

# Index beats name in tmux's own resolution, and the parser must not invert it.
# With index 0 named `zero` and index 1 named `0`, tmux resolves `:0` to INDEX
# 0. A name-first parser would answer about a DIFFERENT window than every other
# tmux call reaches - confidently wrong, which is worse than the fallback this
# whole change removes.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s ambig -n zero \
  || fail "could not create the ambiguity session"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t ambig: -n 0 \
  || fail "could not create the name-versus-index collision window"
collide=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t 'ambig:0' '#{window_index}#{window_name}')
[ "$collide" = "0zero" ] \
  || fail "this tmux did not resolve ambig:0 to index 0 (got '$collide'), so the collision case would prove nothing"
[ "$(fm_backend_tmux_target_presence 'ambig:0')" = present ] \
  || fail "the parser must accept the collision target that tmux itself resolves"
[ "$(fm_backend_tmux_target_presence 'ambig:zero')" = present ] \
  || fail "the window named zero must still resolve by name"
pass "tmux liveness: window index beats window name exactly as tmux resolves it"

# tmux accepts a unique session-name PREFIX, so a recorded target for a session
# that no longer exists could resolve against a different, longer-named one and
# report liveness about an unrelated window.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s prefixlong -n only \
  || fail "could not create the prefix session"
"$REAL_TMUX" -L "$SOCKET" display-message -p -t 'prefix:only' '#{session_name}' >/dev/null 2>&1 \
  || fail "this tmux does not prefix-match sessions, so the prefix case would prove nothing"
[ "$("$REAL_TMUX" -L "$SOCKET" display-message -p -t 'prefix:only' '#{session_name}')" = prefixlong ] \
  || fail "expected the unanchored prefix target to resolve against prefixlong"
if fm_backend_target_exists tmux "prefix:only"; then
  fail "a target naming a session that does not exist must be rejected, even when a unique prefix match does"
fi
fm_backend_target_exists tmux "prefixlong:only" \
  || fail "the exact session must still be accepted"
pass "tmux liveness: the session component is exact, not a unique prefix"

# tmux splits a target at the dot itself, so `session:fm-task.a` reaches window
# `fm-task` even when a window named `fm-task.a` exists beside it. Stripping at
# the last dot and accepting the prefix window therefore confirms presence
# about the wrong window. Task ids may contain dots (bin/fm-pr-lib.sh permits
# them), so the ambiguous form reads unreadable - never missing, which would
# license a duplicate spawn - while a real pane selector still resolves.
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n 'fm-dotted' \
  || fail "could not create the dotted-prefix window"
[ "$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:fm-dotted.a" '#{window_name}')" = fm-dotted ] \
  || fail "this tmux did not split fm-dotted.a at the dot, so the dotted case would prove nothing"
if fm_backend_target_exists tmux "$SESSION:fm-dotted.a"; then
  fail "an ambiguous dotted target must not be reported alive off the prefix window it accidentally reaches"
fi
[ "$(fm_backend_tmux_target_presence "$SESSION:fm-dotted.a")" = unreadable ] \
  || fail "an ambiguous dotted target must read unreadable, so it can never license a duplicate spawn"
pass "tmux liveness: an ambiguous dotted target is never confirmed off a prefix window"

# tmux's own id handles carry no session component at all. The supervisor
# target is one of these: bin/fm-supervisor-target-lib.sh returns $TMUX_PANE
# directly, which tmux sets to a bare %N, and away mode reaches the captain
# through it. Verified on tmux 3.6b: an absent %pane or @window id also exits
# 0 printing an empty line, so exit status alone could not reject them either.
idle_pane=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:idle" '#{pane_id}')
idle_window=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:idle" '#{window_id}')
[ -n "$idle_pane" ] && [ -n "$idle_window" ] \
  || fail "could not read the idle window's own tmux ids"
case "$idle_pane" in %*) ;; *) fail "expected a %-prefixed pane id, got '$idle_pane'" ;; esac

fm_backend_target_exists tmux "$idle_pane" \
  || fail "a bare pane id with no session component must be accepted; it is the captain's own supervisor target"
fm_backend_target_exists tmux "$idle_window" \
  || fail "the cheap existence probe must accept a live window id"
if fm_backend_target_exists tmux '%99999'; then
  fail "the cheap existence probe must reject an absent pane id"
fi
if fm_backend_target_exists tmux '@99999'; then
  fail "the cheap existence probe must reject an absent window id"
fi
pass "tmux liveness: bare pane and window ids resolve, and absent ones are rejected"

# A pane-qualified target must still work, and an absent pane index inside a
# PRESENT window must not ride in on the window alone - tmux answers that from
# the window's active pane.
fm_backend_target_exists tmux "$SESSION:idle.0" \
  || fail "a session:window.pane target for a real pane must be accepted"
if fm_backend_target_exists tmux "$SESSION:idle.99999"; then
  fail "an absent pane index inside a present window must be rejected, not answered from the active pane"
fi
pass "tmux liveness: a pane selector is verified, not assumed from its window"

# --- Cursor's composer: the terminal cursor is NOT a composer locator --------
# Cursor Agent CLI parks its terminal cursor below its footer with cursor_flag 0,
# so tmux's #{cursor_y} answers `unknown` for every Cursor pane state and the
# away-mode escalation guard could never prove the composer empty. The composite
# reader reclassifies a proven-Cursor pane the way every cursorless backend
# already does. These cases drive the two signals apart on purpose: the SAME
# screen must read differently depending only on whether the pane's foreground
# process is genuinely Cursor, and the cursor-anchored source must be asserted
# blind so the case cannot go quietly vacuous.

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

ln -s "$SLEEP_BIN" "$LAB/bin/cursor-agent"
ln -s "$SLEEP_BIN" "$LAB/bin/notcursor"

# Cursor's real screen shape: a BARE composer row carrying its U+2192 glyph, two
# footer rows below it, and the terminal cursor left on a blank row past the
# footer - exactly where cursor-agent 2026.08.11-e8db854 parks it. An IDLE
# composer draws its placeholder de-emphasised (SGR 2), which is what separates
# it from real typed text once the capture preserves styling; a plain-bright row
# is genuine input. Both forms are reproduced here rather than assumed.
cursor_screen() {  # <composer-text> <ghost 0|1>
  local text=$1 ghost=$2 open='' close=''
  if [ "$ghost" = 1 ]; then
    open=$(printf '\033[2m')
    close=$(printf '\033[0m')
  fi
  printf '\n  \xe2\x86\x92 %s%s%s\n\n  Cursor Grok 4.5 High                    Run Everything\n  %s \xc2\xb7 main\n\n' \
    "$open" "$text" "$close" "$LAB/wt"
}

open_composer_pane() {  # <window> <binary> <composer-text> <ghost 0|1>
  local window=$1 binary=$2 text=$3 ghost=$4
  new_window "$window" bash -c "$(declare -f cursor_screen); LAB='$LAB'; cursor_screen '$text' '$ghost'; exec '$binary' 900"
  local i=0
  while [ "$i" -lt 100 ]; do
    case "$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:$window" 2>/dev/null)" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  fail "pane $window never rendered its composer"
}

cursor_anchored_verdict() {  # <target>
  local cy pane
  cy=$(fm_tmux_composer_cursor_row "$1")
  pane=$(fm_tmux_composer_capture "$1")
  fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$pane" "$cy"
}

open_composer_pane cursor-idle "$LAB/bin/cursor-agent" 'Plan, search, build anything' 1
fm_tmux_pane_is_cursor "$SESSION:cursor-idle" \
  || fail "a pane whose foreground process is cursor-agent must be identified as Cursor"
[ "$(cursor_anchored_verdict "$SESSION:cursor-idle")" = unknown ] \
  || fail "the cursor-anchored source must be blind here, or this case proves nothing about the fallback"
[ "$(fm_tmux_composer_state "$SESSION:cursor-idle")" = empty ] \
  || fail "an idle Cursor composer must read empty; without it every away-mode escalation defers forever"
pass "cursor composer: an idle Cursor pane reads empty even though the cursor row is blind"

open_composer_pane cursor-typed "$LAB/bin/cursor-agent" 'half typed captain text' 0
[ "$(cursor_anchored_verdict "$SESSION:cursor-typed")" = unknown ] \
  || fail "the cursor-anchored source must be blind here too"
[ "$(fm_tmux_composer_state "$SESSION:cursor-typed")" = pending ] \
  || fail "real unsubmitted text in a Cursor composer must read pending, never empty; otherwise an escalation would merge with the captain's own half-typed line"
pass "cursor composer: real typed text still reads pending, so the injection guard holds"

# The SAME rendered screen, with only the foreground process identity changed.
open_composer_pane notcursor-idle "$LAB/bin/notcursor" 'Plan, search, build anything' 1
if fm_tmux_pane_is_cursor "$SESSION:notcursor-idle"; then
  fail "a pane running a non-Cursor binary must not be identified as Cursor"
fi
[ "$(fm_tmux_composer_state "$SESSION:notcursor-idle")" = unknown ] \
  || fail "the reclassification must be gated on Cursor's own process identity; the strict blank-cursor-row posture stays in force for every other harness"
pass "cursor composer: an identical screen stays unknown when the pane is not Cursor"

# A Cursor agent that exited leaves its rendered composer on screen while the
# foreground process becomes a plain shell. Typing an escalation there would run
# it as a shell command, so this must never read empty.
new_window cursor-exited bash -c "$(declare -f cursor_screen); LAB='$LAB'; cursor_screen 'Plan, search, build anything' 1; exec /bin/sh"
for _ in $(seq 1 100); do
  case "$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:cursor-exited" 2>/dev/null)" in
    *'Plan, search, build anything'*) break ;;
  esac
  sleep 0.1
done
if fm_tmux_pane_is_cursor "$SESSION:cursor-exited"; then
  fail "a pane whose Cursor process exited must not still identify as Cursor"
fi
[ "$(fm_tmux_composer_state "$SESSION:cursor-exited")" != empty ] \
  || fail "a dead-shell pane still showing Cursor's composer must never read empty"
pass "cursor composer: a stale Cursor screen over a dead shell never reads empty"

cleanup_all
trap - EXIT
