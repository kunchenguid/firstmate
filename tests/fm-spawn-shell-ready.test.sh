#!/usr/bin/env bash
# Behavior tests for the spawn shell-readiness gate.
#
# THE INCIDENT (2026-08-26). Two registered secondmates, cellarsky-sm and
# hermes-jarvis-sm, were found as bare zsh prompts rather than running agents.
# Their launch line had been typed into a shell that was not at a prompt, so
# `claude --dangerously-skip-permissions "<charter>"` was consumed as raw text
# and died on a zsh parse error. firstmate had already recorded a meta and
# registered them as live supervisors; nothing noticed for weeks.
#
# ROOT CAUSE. fm-spawn inferred shell readiness from pane_current_path changing
# after `treehouse get`. That proves a chdir happened. It does not prove the
# shell returned to a prompt, and `tmux send-keys` has no acknowledgment
# channel to tell the difference.
#
# THE GUARDS, pinned here:
#   GUARD 1 (prevention)  wait_shell_ready - a bounded echo round-trip that only
#           succeeds on positive proof the shell ran a command line.
#   GUARD 2 (detection)   launch_failed - reads the pane after launch and reports
#           a shell error rather than a silent dead pane.
#
# BOTH SURFACES, and that is the point. bin/fm-spawn.sh calls the HERDR pair -
# fm_herdr_wait_shell_ready and fm_herdr_launch_failed - and no longer calls the
# tmux twins at all, so a file that exercised only the tmux pair was green while
# proving nothing about the path every crewmate is now launched through. The
# tmux cases stay for the drain, which is still live until the last pre-cutover
# meta is gone. Each pair is pinned on the same three properties, because the
# incident does not care which multiplexer typed the line.
# All of it is hermetic over fakes; no real pane is created on either surface.
set -u

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=bin/fm-herdr.sh
. "$ROOT/bin/fm-herdr.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-shell-ready)

# A fake tmux whose pane content is whatever $PANE_FILE holds. With
# READY_MODE=echo it appends the probe marker on send-keys, mimicking a shell
# that actually ran the command. With READY_MODE=deaf it swallows input,
# mimicking a shell that is mid-command and not at a prompt.
make_fake_tmux() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  send-keys)
    [ "${READY_MODE:-deaf}" = echo ] || exit 0
    for a in "$@"; do
      case "$a" in
        "printf '%s\n' "*) printf '%s\n' "${a##*\' }" >> "$PANE_FILE" ;;
      esac
    done
    exit 0 ;;
  capture-pane)
    cat "$PANE_FILE" 2>/dev/null; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

FB=$(make_fake_tmux "$TMP_ROOT")
PATH="$FB:$PATH"; export PATH
HFB=$(fm_herdr_fake_server "$TMP_ROOT/herdr")
PATH="$HFB:$PATH"; export PATH
export FM_SHELL_READY_POLL=0.01

# --- GUARD 1: readiness probe -----------------------------------------------

# A shell that echoes the probe back is ready. This is the ONLY positive signal
# the gate accepts - not a cwd change, not elapsed time.
test_ready_when_shell_echoes() {
  PANE_FILE="$TMP_ROOT/pane-ready.txt"; export PANE_FILE
  : > "$PANE_FILE"
  READY_MODE="echo"; export READY_MODE
  if fm_tmux_wait_shell_ready fake:0 3; then
    pass "ready shell: probe round-trips, gate opens"
  else
    fail "ready shell: gate refused a shell that echoed the marker"
  fi
}

# A shell that never echoes is NOT ready, and the gate must time out rather
# than fall through. This is the case that produced the dead secondmates.
test_not_ready_when_shell_is_deaf() {
  PANE_FILE="$TMP_ROOT/pane-deaf.txt"; export PANE_FILE
  : > "$PANE_FILE"
  READY_MODE="deaf"; export READY_MODE
  if fm_tmux_wait_shell_ready fake:0 1; then
    fail "deaf shell: gate opened on a shell that never ran the probe"
  else
    pass "deaf shell: gate stayed shut and timed out"
  fi
}

# The echoed COMMAND line also contains the marker. Only the output line, alone
# on its own line, counts - otherwise the probe would pass on the echo of its
# own keystrokes and prove nothing.
test_echoed_command_line_is_not_proof() {
  PANE_FILE="$TMP_ROOT/pane-cmdonly.txt"; export PANE_FILE
  READY_MODE="deaf"; export READY_MODE
  printf "%s\n" "\$ printf '%s\\n' fmready999 " > "$PANE_FILE"
  if fm_tmux_wait_shell_ready fake:0 1; then
    fail "command echo: gate accepted its own keystroke echo as proof"
  else
    pass "command echo: keystroke echo alone is not accepted as proof"
  fi
}

# --- GUARD 2: post-launch verification --------------------------------------

# The real observed failure text must be caught.
test_detects_the_observed_parse_error() {
  PANE_FILE="$TMP_ROOT/pane-parse.txt"; export PANE_FILE
  cat > "$PANE_FILE" <<'EOF'
(base) stoneevenson@Air firstmate % claude --dangerously-skip-permissions You are a secondmate
zsh: parse error near `do'
(base) stoneevenson@Air firstmate %
EOF
  if fm_tmux_launch_failed fake:0; then
    pass "detection: the 2026-08-26 zsh parse error is caught"
  else
    fail "detection: missed the exact failure that killed two secondmates"
  fi
}

test_detects_command_not_found() {
  PANE_FILE="$TMP_ROOT/pane-cnf.txt"; export PANE_FILE
  printf '%s\n' "zsh: command not found: firstmate" > "$PANE_FILE"
  if fm_tmux_launch_failed fake:0; then
    pass "detection: command-not-found is caught"
  else
    fail "detection: missed command-not-found"
  fi
}

# A healthy agent pane must NOT trip the detector, or every spawn fails.
test_healthy_agent_pane_is_not_flagged() {
  PANE_FILE="$TMP_ROOT/pane-healthy.txt"; export PANE_FILE
  cat > "$PANE_FILE" <<'EOF'
* Brewed for 6m 38s
  new task? /clear to save 368.4k tokens
> esc to interrupt
EOF
  if fm_tmux_launch_failed fake:0; then
    fail "false positive: a healthy running agent pane was flagged as failed"
  else
    pass "healthy pane: not flagged"
  fi
}


# --- THE SAME THREE PROPERTIES ON THE SURFACE fm-spawn ACTUALLY USES ---------
#
# fm-spawn calls these two; the tmux pair above survives only for the drain. So
# the incident's guard is only really guarded here.

test_herdr_ready_when_shell_echoes() {
  HERDR_PANE_FILE="$TMP_ROOT/hpane-ready.txt"; export HERDR_PANE_FILE
  : > "$HERDR_PANE_FILE"
  HERDR_RUN_MODE="echo"; export HERDR_RUN_MODE
  if fm_herdr_wait_shell_ready w9:p2 3; then
    pass "herdr ready shell: probe round-trips, gate opens"
  else
    fail "herdr ready shell: gate refused a shell that echoed the marker"
  fi
}

test_herdr_not_ready_when_shell_is_deaf() {
  HERDR_PANE_FILE="$TMP_ROOT/hpane-deaf.txt"; export HERDR_PANE_FILE
  : > "$HERDR_PANE_FILE"
  HERDR_RUN_MODE="deaf"; export HERDR_RUN_MODE
  if fm_herdr_wait_shell_ready w9:p2 1; then
    fail "herdr deaf shell: gate opened on a shell that never ran the probe"
  else
    pass "herdr deaf shell: gate stayed shut and timed out"
  fi
}

# The command line the probe types CONTAINS the marker, so a pane holding only
# that echo must not satisfy the gate - otherwise readiness is proven by the
# keystrokes rather than by the shell, which is the whole defect.
test_herdr_echoed_command_line_is_not_proof() {
  HERDR_PANE_FILE="$TMP_ROOT/hpane-cmdonly.txt"; export HERDR_PANE_FILE
  : > "$HERDR_PANE_FILE"
  HERDR_RUN_MODE="cmd"; export HERDR_RUN_MODE
  if fm_herdr_wait_shell_ready w9:p2 1; then
    fail "herdr command echo: gate accepted its own keystroke echo as proof"
  else
    pass "herdr command echo: keystroke echo alone is not accepted as proof"
  fi
  unset HERDR_RUN_MODE
}

test_herdr_detects_the_observed_parse_error() {
  HERDR_PANE_FILE="$TMP_ROOT/hpane-parse.txt"; export HERDR_PANE_FILE
  cat > "$HERDR_PANE_FILE" <<'EOF'
(base) stoneevenson@Air firstmate % claude --dangerously-skip-permissions You are a secondmate
zsh: parse error near `do'
(base) stoneevenson@Air firstmate %
EOF
  if fm_herdr_launch_failed w9:p2; then
    pass "herdr detection: the 2026-08-26 zsh parse error is caught"
  else
    fail "herdr detection: missed the exact failure that killed two secondmates"
  fi
}

test_herdr_detects_command_not_found() {
  HERDR_PANE_FILE="$TMP_ROOT/hpane-cnf.txt"; export HERDR_PANE_FILE
  printf '%s\n' "zsh: command not found: firstmate" > "$HERDR_PANE_FILE"
  if fm_herdr_launch_failed w9:p2; then
    pass "herdr detection: command-not-found is caught"
  else
    fail "herdr detection: missed command-not-found"
  fi
}

test_herdr_healthy_agent_pane_is_not_flagged() {
  HERDR_PANE_FILE="$TMP_ROOT/hpane-healthy.txt"; export HERDR_PANE_FILE
  cat > "$HERDR_PANE_FILE" <<'EOF'
* Brewed for 6m 38s
  new task? /clear to save 368.4k tokens
> esc to interrupt
EOF
  if fm_herdr_launch_failed w9:p2; then
    fail "herdr false positive: a healthy running agent pane was flagged as failed"
  else
    pass "herdr healthy pane: not flagged"
  fi
}

# And the wiring: a guard fm-spawn does not call guards nothing. This is the
# assertion whose absence let the tmux-only file above stay green.
test_fm_spawn_uses_the_herdr_guards() {
  local body
  body=$(grep -vE '^[[:space:]]*#' "$ROOT/bin/fm-spawn.sh")
  case "$body" in
    *fm_herdr_wait_shell_ready*) : ;;
    *) fail "fm-spawn does not gate shell readiness on the surface it launches on" ;;
  esac
  case "$body" in
    *fm_herdr_launch_failed*) : ;;
    *) fail "fm-spawn does not verify the launch on the surface it launches on" ;;
  esac
  pass "wiring: fm-spawn gates and verifies through the herdr guards it actually uses"
}

test_ready_when_shell_echoes
test_not_ready_when_shell_is_deaf
test_echoed_command_line_is_not_proof
test_detects_the_observed_parse_error
test_detects_command_not_found
test_healthy_agent_pane_is_not_flagged
test_herdr_ready_when_shell_echoes
test_herdr_not_ready_when_shell_is_deaf
test_herdr_echoed_command_line_is_not_proof
test_herdr_detects_the_observed_parse_error
test_herdr_detects_command_not_found
test_herdr_healthy_agent_pane_is_not_flagged
test_fm_spawn_uses_the_herdr_guards

