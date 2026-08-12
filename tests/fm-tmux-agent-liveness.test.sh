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
export HOME="$LAB"
SESSION=liveness
CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)

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
PATH="$LAB/shim:$LAB/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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
# An unrelated executable that merely happens to be named agent: it must never
# classify as a live agent pane.
ln -s "$SLEEP_BIN" "$LAB/bin/agent"
# Cursor's legacy alias as it is actually installed - a symlink into Cursor's
# own versioned cursor-agent binary. A direct link to sleep would canonicalize
# to /usr/bin/sleep and would not model the structural proof under test.
mkdir -p "$LAB/.local/share/cursor-agent/versions/2026.08.04-aaa8809"
if [ -n "$CC_BIN" ] &&
  printf '%s\n' '#include <stdio.h>' '#include <string.h>' '#include <unistd.h>' 'int main(int argc,char **argv){if(argc > 1 && strcmp(argv[1],"--help") == 0){puts("Usage: cursor-agent [OPTIONS]");puts("Start the Cursor Agent");puts("CURSOR_API_ENDPOINT  override api2.cursor.sh");return 0;}for(;;)sleep(60);return 0;}' > "$LAB/cursor-spin.c" &&
  "$CC_BIN" -o "$LAB/.local/share/cursor-agent/versions/2026.08.04-aaa8809/cursor-agent" "$LAB/cursor-spin.c" 2>/dev/null; then
  ln -s "$LAB/.local/share/cursor-agent/versions/2026.08.04-aaa8809/cursor-agent" \
    "$LAB/.local/share/cursor-agent/versions/2026.08.04-aaa8809/agent"
  mkdir -p "$LAB/.local/bin"
  ln -s "$LAB/.local/share/cursor-agent/versions/2026.08.04-aaa8809/cursor-agent" \
    "$LAB/.local/bin/cursor-agent"
else
  echo "skip: no C compiler, so the Cursor alias install-tree case cannot build its canonical binary"
fi
# A decoy install tree whose directory is merely named agent.
mkdir -p "$LAB/agent/versions/current"
ln -s "$SLEEP_BIN" "$LAB/agent/versions/current/agent"

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
  local pid name argv0 args
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$(fm_backend_tmux_classify_process_name "$name")" = agent ] && return 0
  done <<EOF
$(fm_backend_tmux_foreground_comms "$1")
EOF
  while IFS=$'\t' read -r pid name argv0 args; do
    [ -n "$name" ] || continue
    [ "$(fm_backend_tmux_classify_process_name "$name" "$argv0" "$args" "$pid")" = agent ] && return 0
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
# --- cursor-agent: MainThread kernel exec name -------------------------------

"$REAL_TMUX" -L "$SOCKET" new-window -t "$SESSION" -n cmainthrd bash -c "exec -a MainThread '$SLEEP_BIN' 30"
# A bare MainThread exec name without a cursor-agent path component must NOT
# classify alive: no name source attributes it to a harness, so the readable
# foreground group (a non-shell) stays ambiguous, never an invented agent.
if [ "$(fm_backend_agent_state tmux "$SESSION:cmainthrd" 2>/dev/null)" = alive ]; then
  fail "a bare 'MainThread' foreground process must not classify alive (no cursor-agent path context)"
fi
"$REAL_TMUX" -L "$SOCKET" kill-window -t "$SESSION:cmainthrd" 2>/dev/null || true
pass "tmux liveness: a bare MainThread exec name without cursor-agent path is not alive"

# --- cursor-agent: MainThread with cursor-agent argv0 ------------------------

CURSOR_BINARY="$LAB/.local/share/cursor-agent/versions/2026.08.04-aaa8809/cursor-agent"
if [ -x "$CURSOR_BINARY" ]; then
  "$REAL_TMUX" -L "$SOCKET" new-window -t "$SESSION" -n cursorargv0 bash -c "CURSOR_AGENT=1 exec -a '$CURSOR_BINARY' '$CURSOR_BINARY' 30"
  wait_for_state "$SESSION:cursorargv0" alive 2>/dev/null \
    || fail "a Cursor install-path argv0 must classify alive"
  pass "tmux liveness: a validated Cursor install path classifies alive"
  "$REAL_TMUX" -L "$SOCKET" kill-window -t "$SESSION:cursorargv0" 2>/dev/null || true
fi
"$REAL_TMUX" -L "$SOCKET" new-window -t "$SESSION" -n cursordecoy bash -c "exec -a cursor-agent '$SLEEP_BIN' 30"
if [ "$(fm_backend_agent_state tmux "$SESSION:cursordecoy" 2>/dev/null)" = alive ]; then
  fail "a decoy process basename cursor-agent must not classify alive"
fi
"$REAL_TMUX" -L "$SOCKET" kill-window -t "$SESSION:cursordecoy" 2>/dev/null || true
pass "tmux liveness: a decoy cursor-agent basename does not classify alive"

# --- cursor legacy alias: agent, proven by its install tree ------------------

CURSOR_ALIAS="$LAB/.local/share/cursor-agent/versions/2026.08.04-aaa8809/agent"
if [ -x "$CURSOR_ALIAS" ]; then
  "$REAL_TMUX" -L "$SOCKET" new-window -t "$SESSION" -n cursoralias bash -c "CURSOR_AGENT=1 exec -a '$CURSOR_ALIAS' '$CURSOR_ALIAS' 30"
  wait_for_state "$SESSION:cursoralias" alive 2>/dev/null \
    || fail "a legacy agent alias inside Cursor's install tree must classify alive"
  "$REAL_TMUX" -L "$SOCKET" kill-window -t "$SESSION:cursoralias" 2>/dev/null || true
  pass "tmux liveness: a Cursor legacy alias proven by its install tree classifies alive"
fi

# --- negative: unrelated executables named agent -----------------------------

# An arbitrary executable whose basename is agent, and an unrelated install
# tree whose DIRECTORY is named agent. Neither is Cursor, and classifying
# either as a live agent pane would let firstmate read an unrelated process as
# a working crewmate.
"$REAL_TMUX" -L "$SOCKET" new-window -t "$SESSION" -n unrelagent bash -c "exec -a '$LAB/bin/agent' '$LAB/bin/agent' 30"
sleep 1
if [ "$(fm_backend_agent_state tmux "$SESSION:unrelagent" 2>/dev/null)" = alive ]; then
  fail "an unrelated executable named agent must not classify as a live agent pane"
fi
"$REAL_TMUX" -L "$SOCKET" kill-window -t "$SESSION:unrelagent" 2>/dev/null || true

DECOY_AGENT="$LAB/agent/versions/current/agent"
"$REAL_TMUX" -L "$SOCKET" new-window -t "$SESSION" -n decoyagent bash -c "exec -a '$DECOY_AGENT' '$DECOY_AGENT' 30"
sleep 1
if [ "$(fm_backend_agent_state tmux "$SESSION:decoyagent" 2>/dev/null)" = alive ]; then
  fail "an install tree merely named agent/ must not classify as a live agent pane"
fi
"$REAL_TMUX" -L "$SOCKET" kill-window -t "$SESSION:decoyagent" 2>/dev/null || true
pass "tmux liveness: unrelated agent executables and agent/ directory components are not Cursor"

# --- cursor-agent: negative case (~/.cursor path should not match) ------------

ln -sf "$SLEEP_BIN" "$LAB/bin/notcursor"
"$REAL_TMUX" -L "$SOCKET" new-window -t "$SESSION" -n cursorneg bash -c "exec -a notcursor '$LAB/bin/notcursor' 30"
if [ "$(fm_backend_agent_state tmux "$SESSION:cursorneg" 2>/dev/null)" = alive ]; then
  fail "a non-cursor process must not classify alive (over-broad matching hazard)"
fi
"$REAL_TMUX" -L "$SOCKET" kill-window -t "$SESSION:cursorneg" 2>/dev/null || true
pass "tmux liveness: a non-cursor process does not classify alive"

cleanup_all
trap - EXIT
