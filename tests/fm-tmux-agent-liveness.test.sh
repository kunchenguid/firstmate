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
command -v mkfifo >/dev/null 2>&1 \
  || { echo "not ok - mkfifo is required for process-readiness fixtures" >&2; exit 1; }
CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
[ -n "$CC_BIN" ] \
  || { echo "not ok - a C compiler is required for real process-identity fixtures" >&2; exit 1; }

fm_liveness_process_snapshot() {
  ps -eo pid=,ppid=,pgid=,lstart=,args= | \
    awk -v prefix="$FM_LIVENESS_TMP_ROOT/fm-liveness." '
      index($0, prefix) && ($0 ~ /\/bin\// || $0 ~ /\.fifo([ ]|$)/) {print}
    ' | sort
}

fm_cleanup_registry_snapshot() {
  local path
  for path in "$FM_LIVENESS_TMP_ROOT"/.fm-test-cleanup.*; do
    [ -f "$path" ] && printf '%s\n' "$path"
  done | sort
}

FM_LIVENESS_TMP_ROOT=${TMPDIR:-/tmp}
FM_LIVENESS_TMP_ROOT=${FM_LIVENESS_TMP_ROOT%/}
process_baseline=$(fm_liveness_process_snapshot)
registry_baseline=$(fm_cleanup_registry_snapshot)

REAL_TMUX=$(command -v tmux)
SOCKET="fm-liveness-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-liveness.XXXXXX")
SESSION=liveness
mkdir -p "$LAB/state"
FM_STATE_OVERRIDE="$LAB/state"
export FM_STATE_OVERRIDE
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
TEST_SHELL_PGID=$(ps -o pgid= -p "$$" | tr -d ' ')
OWNED_PIDS=()
OWNED_PGIDS=()
OWNED_IDENTITIES=()

record_owned_process() {  # <pid> <label>
  local pid=$1 label=$2 pgid identity args
  case "$pid" in '' | *[!0-9]*) fail "$label published an invalid pid" ;; esac
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ') || pgid=
  identity=$(fm_pid_identity "$pid" 2>/dev/null) || identity=
  args=$(ps -o args= -p "$pid" 2>/dev/null) || args=
  case "$pgid" in '' | *[!0-9]*) fail "$label has no readable process group" ;; esac
  [ "$pgid" -gt 1 ] && [ "$pgid" != "$TEST_SHELL_PGID" ] \
    || fail "$label resolved to the caller/session process group"
  [ -n "$identity" ] && [ "${args#*"$LAB/"}" != "$args" ] \
    || fail "$label is not attributable to this exact test fixture"
  OWNED_PIDS+=("$pid")
  OWNED_PGIDS+=("$pgid")
  OWNED_IDENTITIES+=("$identity")
}

owned_process_matches() {  # <array-index>
  local index=$1 pid=${OWNED_PIDS[$1]} expected=${OWNED_IDENTITIES[$1]} current pgid args
  current=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$current" = "$expected" ] || return 1
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
  [ "$pgid" = "${OWNED_PGIDS[$index]}" ] || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  [ "${args#*"$LAB/"}" != "$args" ]
}

wait_owned_process_exit() {  # <array-index>
  local index=$1 attempt=0
  while [ "$attempt" -lt 40 ] && owned_process_matches "$index"; do
    sleep 0.05
    attempt=$((attempt + 1))
  done
  ! owned_process_matches "$index"
}

terminate_owned_process_groups() {
  local index pgid
  for ((index = 0; index < ${#OWNED_PIDS[@]}; index++)); do
    owned_process_matches "$index" || continue
    pgid=${OWNED_PGIDS[$index]}
    [ "$pgid" != "$TEST_SHELL_PGID" ] || continue
    kill -TERM -- "-$pgid" 2>/dev/null || true
  done
  for ((index = 0; index < ${#OWNED_PIDS[@]}; index++)); do
    wait_owned_process_exit "$index" && continue
    owned_process_matches "$index" || continue
    pgid=${OWNED_PGIDS[$index]}
    [ "$pgid" != "$TEST_SHELL_PGID" ] || continue
    kill -KILL -- "-$pgid" 2>/dev/null || true
    wait_owned_process_exit "$index" || true
  done
}

cleanup_all() {
  terminate_owned_process_groups
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  terminate_owned_process_groups
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT
trap 'cleanup_all; exit 130' INT
trap 'cleanup_all; exit 143' TERM

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

# Stand-in harnesses are real compiled processes. Each writes `ready` to the
# FIFO passed as argv[1] only after its executable has started, then blocks in
# pause(2). That gives both tmux and ps a genuine executable identity and gives
# the test a condition to synchronize on without polling process state.
cat > "$LAB/blocker.c" <<'C'
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  int fd;
  const char ready[] = "ready\n";
  if (argc != 2) return 2;
  fd = open(argv[1], O_WRONLY);
  if (fd < 0) return 3;
  if (write(fd, ready, strlen(ready)) != (ssize_t)strlen(ready)) return 4;
  close(fd);
  for (;;) pause();
}
C
compile_named_blocker() {  # <path>
  "$CC_BIN" -o "$1" "$LAB/blocker.c" \
    || fail "could not compile process fixture ${1##*/}"
}

compile_named_blocker "$LAB/bin/claude-link"
compile_named_blocker "$LAB/bin/claud-link"
compile_named_blocker "$LAB/bin/pi"
compile_named_blocker "$LAB/bin/notaharness"
# muse's installed binary is muse-bin-<version>: the launcher execs it, so the
# version is the LIVE process name and it changes on every auto-update. Unlike
# Claude Code's version-named binary there is no `muse` path component to fall
# back on (~/.local/bin/muse-bin-<version>), so the executable name is the ONLY
# signal, and `muse` alone is a common English fragment that must not widen into
# a substring match. The last two names are the decoys that would be misread.
compile_named_blocker "$LAB/bin/muse-bin-0.1.0-R708.1"
compile_named_blocker "$LAB/bin/musescore"
compile_named_blocker "$LAB/bin/amuse"
compile_named_blocker "$LAB/bin/muse-binary"
compile_named_blocker "$LAB/bin/muse-bind"

# A launcher whose own process identity is a bare shell, running the harness as
# a child in the same foreground process group - the shape the real Pi Launcher
# path takes, and the one where trusting a single name source can produce a
# false `dead`.
cat > "$LAB/bin/agent-launcher" <<SH
#!/bin/sh
"$LAB/bin/pi" "\$3" &
child=\$!
printf '%s\n' "\$child" > "\$2"
IFS= read -r child_ready < "\$3"
[ "\$child_ready" = ready ] || exit 4
printf 'ready\n' > "\$1"
wait "\$child"
SH
chmod +x "$LAB/bin/agent-launcher"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

# Run the pane's process DIRECTLY as the window command rather than typing into
# a shell, so no case depends on interactive shell readiness.
new_window() {  # <name> <cmd...>
  local name=$1 window_id
  shift
  window_id=$("$REAL_TMUX" -L "$SOCKET" new-window -dP -F '#{window_id}' \
    -t "$SESSION:" -n "$name" -c "$LAB/wt" -- "$@") \
    || fail "could not create window $name"
  # Pin the semantic name before any lookup. Otherwise tmux may automatically
  # rename a fast-starting window, after which a name lookup silently falls
  # back to an unrelated active pane.
  "$REAL_TMUX" -L "$SOCKET" set-window-option -t "$window_id" automatic-rename off >/dev/null \
    || fail "could not disable automatic rename for $name"
  "$REAL_TMUX" -L "$SOCKET" set-window-option -t "$window_id" allow-rename off >/dev/null \
    || fail "could not disable process rename for $name"
  "$REAL_TMUX" -L "$SOCKET" rename-window -t "$window_id" "$name" \
    || fail "could not pin window name $name"
}

open_ready_fifo() {  # <label>
  READY_FIFO="$LAB/ready-$1.fifo"
  rm -f "$READY_FIFO"
  mkfifo "$READY_FIFO" || fail "could not create readiness FIFO for $1"
  exec 9<>"$READY_FIFO" || fail "could not open readiness FIFO for $1"
}

await_ready_fifo() {  # <label>
  local label=$1 signal=
  if ! IFS= read -r -t 10 signal <&9 || [ "$signal" != ready ]; then
    exec 9>&-
    fail "$label did not signal process readiness"
  fi
  exec 9>&-
  rm -f "$READY_FIFO"
}

new_blocker_window() {  # <window> <binary>
  local window=$1 binary=$2
  shift 2
  open_ready_fifo "$window"
  new_window "$window" "$binary" "$READY_FIFO" "$@"
  await_ready_fifo "$window"
}

assert_state() {  # <target> <expected> <message>
  local target=$1 expected=$2 message=$3 got
  got=$(fm_backend_agent_state tmux "$target")
  [ "$got" = "$expected" ] || fail \
    "$message (got $got; title=$(fm_backend_tmux_current_command "$target"); comms=[$(fm_backend_tmux_foreground_comms "$target" | tr '\n' ' ')])"
}

# The initial idle pane has its own handshake too, so even the negative shell
# assertion later observes a shell that has definitely exec'd, not tmux startup.
open_ready_fifo idle
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n idle -c "$LAB/wt" -- \
  bash -c "printf 'ready\\n' > '$READY_FIFO'; exec bash" \
  || fail "could not start the private tmux server"
await_ready_fifo idle

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
# Invoking the compiled fixture by its harness name proves the ordinary positive
# path with a real process. The version-string case below owns the deliberate
# cross-platform divergence assertion.

new_blocker_window agent "$LAB/bin/claude-link"
assert_state "$SESSION:agent" alive \
  "a running harness-named foreground process must classify alive"
pass "tmux liveness: a harness-named foreground process classifies alive"

new_blocker_window near-miss "$LAB/bin/claud-link"
assert_state "$SESSION:near-miss" ambiguous \
  "a near-miss executable name must not spoof a harness identity"
pass "tmux liveness: a near-miss executable name stays ambiguous"

# --- muse's version-suffixed binary name ------------------------------------
# A muse crewmate pane misclassified here reads as a dead endpoint, so a healthy
# worker would be torn down or relaunched. The decoys below are what keep the
# fix from being a substring match that claims unrelated programs.

new_blocker_window muse "$LAB/bin/muse-bin-0.1.0-R708.1"
assert_state "$SESSION:muse" alive \
  "muse's version-suffixed binary name must classify alive"
pass "tmux liveness: muse's version-suffixed muse-bin-<version> classifies alive"

for decoy in musescore amuse muse-binary muse-bind; do
  new_blocker_window "decoy-$decoy" "$LAB/bin/$decoy"
  assert_state "$SESSION:decoy-$decoy" ambiguous \
    "'$decoy' merely contains 'muse' and must not classify as a live agent pane"
done
pass "tmux liveness: unrelated muse-containing command names stay ambiguous"

# --- a version name blinds one source ---------------------------------------
# Giving a genuine harness-named executable the version-string argv[0] that
# Claude Code 2.1.220 reports drives the two sources apart on both supported
# platforms and proves the surviving source carries the verdict. This needs a
# real executable file because macOS takes the title from the resolved target's
# name.

compile_named_blocker "$LAB/bin/claude/2.1.220"
compile_named_blocker "$LAB/bin/decoy/2.1.220"
new_blocker_window titled "$LAB/bin/claude/2.1.220"
assert_state "$SESSION:titled" alive \
  "a version-named executable under a harness install path must classify alive"
assert_sources_disagree "$SESSION:titled" "version-string process name"
pass "tmux liveness: a version-named executable under a harness install path classifies alive"

new_blocker_window path-decoy "$LAB/bin/decoy/2.1.220"
assert_state "$SESSION:path-decoy" ambiguous \
  "a version-named executable without a whole harness path component must stay ambiguous"
pass "tmux liveness: a version-named executable under a decoy path stays ambiguous"

# --- neither source names a harness: no invented agent ----------------------

new_blocker_window unknown "$LAB/bin/notaharness"
assert_state "$SESSION:unknown" ambiguous \
  "a foreground process no name source attributes must stay ambiguous"
pass "tmux liveness: a process neither name source attributes stays ambiguous rather than inventing an agent"

# --- a launcher whose own identity reads as a bare shell --------------------
# The single-source classifier would read this pane as an idle shell and call
# it dead - the one verdict that can start a duplicate agent on a live worktree.

launcher_child_pid_file="$LAB/launcher-child.pid"
launcher_child_ready_fifo="$LAB/launcher-child-ready.fifo"
mkfifo "$launcher_child_ready_fifo" || fail "could not create launcher child readiness FIFO"
new_blocker_window launcher "$LAB/bin/agent-launcher" \
  "$launcher_child_pid_file" "$launcher_child_ready_fifo"
launcher_child_pid=$(cat "$launcher_child_pid_file")
rm -f "$launcher_child_ready_fifo"
record_owned_process "$launcher_child_pid" "the launcher harness child"
assert_state "$SESSION:launcher" alive \
  "a launcher running a harness child must classify alive, never dead"
comms_classify_agent "$SESSION:launcher" \
  || fail "the launcher's harness child must be visible in the foreground process group"
pass "tmux liveness: a launcher whose own identity reads as a bare shell classifies alive from its harness child"

# --- an idle shell is still confidently dead --------------------------------

assert_state "$SESSION:idle" dead \
  "an idle shell pane must classify dead"
pass "tmux liveness: an idle shell pane classifies dead"

# --- a harness-named BACKGROUND process must not fake an agent --------------
# Scoping to the foreground process group is what prevents this false alive; a
# descendant walk of the pane would report this pane as running an agent.
# `set -m` gives the background job its own process group, which is what an
# interactive shell does for a job an exited agent left behind.

open_ready_fifo background
mkfifo "$LAB/background-child-ready.fifo" || fail "could not create child readiness FIFO"
new_window background bash -c "set -m; '$LAB/bin/claude-link' '$LAB/background-child-ready.fifo' & bg=\$!; printf '%s\n' \"\$bg\" > '$LAB/bg.pid'; IFS= read -r child_ready < '$LAB/background-child-ready.fifo'; [ \"\$child_ready\" = ready ] || exit 4; printf 'ready\n' > '$READY_FIFO'; exec /bin/sh"
await_ready_fifo background
bg_pid=$(cat "$LAB/bg.pid")
[ -n "$bg_pid" ] || fail "the background harness-named process did not record its pid"
record_owned_process "$bg_pid" "the background harness child"
kill -0 "$bg_pid" 2>/dev/null \
  || fail "the background harness-named process is not running, so this case would prove nothing"
assert_state "$SESSION:background" dead \
  "a pane whose only harness-named process is backgrounded must classify dead"
kill -0 "$bg_pid" 2>/dev/null \
  || fail "the background harness-named process died during the check, so this case proves nothing"
pass "tmux liveness: a harness-named background process in an idle pane still classifies dead"

case "${FM_TMUX_LIVENESS_RESIDUE_CHILD:-}" in
  early-exit) exit 0 ;;
  induced-failure) fail "induced cleanup-path failure" ;;
  '') ;;
  *) fail "unknown residue-child mode" ;;
esac

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

compile_named_blocker "$LAB/bin/cursor-agent"
compile_named_blocker "$LAB/bin/notcursor"

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
  open_ready_fifo "$window"
  new_window "$window" bash -c "$(declare -f cursor_screen); LAB='$LAB'; cursor_screen '$text' '$ghost'; exec '$binary' '$READY_FIFO'"
  await_ready_fifo "$window"
  case "$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:$window" 2>/dev/null)" in
    *"$text"*) return 0 ;;
  esac
  fail "pane $window did not preserve its rendered composer"
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
open_ready_fifo cursor-exited
new_window cursor-exited bash -c "$(declare -f cursor_screen); LAB='$LAB'; cursor_screen 'Plan, search, build anything' 1; printf 'ready\\n' > '$READY_FIFO'; exec /bin/sh"
await_ready_fifo cursor-exited
if fm_tmux_pane_is_cursor "$SESSION:cursor-exited"; then
  fail "a pane whose Cursor process exited must not still identify as Cursor"
fi
[ "$(fm_tmux_composer_state "$SESSION:cursor-exited")" != empty ] \
  || fail "a dead-shell pane still showing Cursor's composer must never read empty"
pass "cursor composer: a stale Cursor screen over a dead shell never reads empty"

cleanup_all
trap - EXIT INT TERM

assert_residue_unchanged() {  # <process-before> <registry-before> <label>
  local process_before=$1 registry_before=$2 label=$3 process_after registry_after
  process_after=$(fm_liveness_process_snapshot)
  registry_after=$(fm_cleanup_registry_snapshot)
  [ "$process_after" = "$process_before" ] \
    || fail "$label left a new $FM_LIVENESS_TMP_ROOT/fm-liveness.* process"
  [ "$registry_after" = "$registry_before" ] \
    || fail "$label changed the cleanup registry set"
}

run_residue_child() {  # <mode> <baseline-processes> <baseline-registries>
  local mode=$1 process_before=$2 registry_before=$3 log rc
  log=$(mktemp "${TMPDIR:-/tmp}/fm-liveness-residue.XXXXXX") \
    || fail "could not allocate residue child log"
  if FM_TMUX_LIVENESS_RESIDUE_CHILD="$mode" \
    bash "$ROOT/tests/fm-tmux-agent-liveness.test.sh" >"$log" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  case "$mode:$rc" in
    early-exit:0)
      grep -Fxq 'ok - tmux liveness: a harness-named background process in an idle pane still classifies dead' "$log" \
        || { rm -f "$log"; fail "early-exit residue child did not reach its cleanup hook"; }
      ;;
    induced-failure:1)
      grep -Fxq 'not ok - induced cleanup-path failure' "$log" \
        || { rm -f "$log"; fail "induced-failure residue child failed before its intended cleanup hook"; }
      ;;
    early-exit:*) rm -f "$log"; fail "early-exit residue child unexpectedly failed with $rc" ;;
    induced-failure:0) rm -f "$log"; fail "induced-failure residue child unexpectedly passed" ;;
    induced-failure:*) rm -f "$log"; fail "induced-failure residue child exited $rc instead of 1" ;;
    *) rm -f "$log"; fail "unknown residue child result $mode:$rc" ;;
  esac
  rm -f "$log"
  assert_residue_unchanged "$process_before" "$registry_before" "$mode cleanup"
}

assert_residue_unchanged "$process_baseline" "$registry_baseline" "successful cleanup"
run_residue_child early-exit "$process_baseline" "$registry_baseline"
run_residue_child induced-failure "$process_baseline" "$registry_baseline"
pass "tmux liveness: success, early-exit, and failure cleanup leave no process or registry residue"
