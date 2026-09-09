#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# Herdr backend tests drive the real fm-spawn/fm-teardown but do not source
# tests/lib.sh, so exempt them from the gate-lifecycle refusal here too (see
# tests/lib.sh and bin/fm-gate-refuse-lib.sh for why firstmate's own suite,
# which the no-mistakes gate runs from a gate worktree, must be exempt).
export FM_GATE_REFUSE_BYPASS=1

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

# herdr_forget_inherited_pane: drop the Herdr PANE identity this test process
# inherited from whatever terminal it was started in.
#
# Herdr injects HERDR_ENV, HERDR_PANE_ID, HERDR_TAB_ID, HERDR_WORKSPACE_ID,
# HERDR_SOCKET_PATH, and HERDR_SESSION into every process it manages a pane for
# (verified 0.7.5 - docs/verification/runtime-backends.md), and a test run from
# inside a Herdr pane inherits all of them. Spawn now treats that pane as the
# authoritative parent to place workers next to, so a leaked identity from the
# developer's own session would follow the test into its isolated lab session
# and be refused there as a cross-session parent - a result that depends on
# where the suite was launched from, not on what it asserts.
#
# Call this before exporting the lab HERDR_SESSION in any suite whose subject is
# the per-home container path. A suite that means to exercise a launcher-bound
# spawn sets HERDR_PANE_ID itself, to a pane it created in its own lab session.
herdr_forget_inherited_pane() {
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
}

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}

# herdr_pin_bare_pane_shell: make every pane this test's lab server opens run a
# bare shell that loads no user rc files, by pointing the server at a throwaway
# Herdr config in <scratch-dir> (HERDR_CONFIG_PATH, herdr's own documented
# override).
#
# A guard that asserts the ABSENCE of an agent depends on the adapter's
# lone-idle-childless-shell proof succeeding
# (bin/backends/herdr.sh's fm_backend_herdr_pane_idle_shell_pid), and a pane
# whose shell is the contributor's own login shell can never satisfy it when
# that shell keeps a persistent child: powerlevel10k's gitstatusd, a zsh-async
# worker, and some direnv setups all leave one. Such a pane reads `live`, the
# guard fails, and the failure looks like a product break while being purely a
# property of the machine it ran on. Pinning the shell leaves the assertion
# depending only on the classifier, and the pane still holds a genuine idle
# shell - exactly the shape an exited agent leaves behind.
#
# Export it before the lab server starts (before provisioning, and before any
# adapter call that would start the server itself); a server already running
# for the session keeps the config it booted with.
herdr_pin_bare_pane_shell() { # <scratch-dir>
  local dir=$1 bash_bin
  bash_bin=$(command -v bash) || return 1
  mkdir -p "$dir" || return 1
  cat > "$dir/bare-pane-shell" <<EOF
#!$bash_bin
unset ENV BASH_ENV
exec "$bash_bin" --noprofile --norc -i
EOF
  chmod +x "$dir/bare-pane-shell" || return 1
  cat > "$dir/herdr-config.toml" <<EOF
[terminal]
default_shell = "$dir/bare-pane-shell"
shell_mode = "non_login"
EOF
  export HERDR_CONFIG_PATH="$dir/herdr-config.toml"
}

# herdr_occupy_pane: give <pane-id> a real foreground process, so a fixture
# that means "a live agent is here" is genuinely live.
#
# `herdr pane report-agent` registers an agent RECORD, and a record is not
# evidence that an agent PROCESS is running: no herdr agent_status reports that
# an agent exited, so the adapter's liveness classifier corroborates every
# registration against the pane's real terminal ownership
# (bin/backends/herdr.sh's fm_backend_herdr_pane_agent_state). A registration
# left over a bare idle shell is therefore correctly classified agent-free.
# A live-agent fixture must occupy the terminal as well as register, or it
# asserts nothing - and worse, it can pass by accident on a pane whose shell has
# not settled yet, which is a silently vacuous test rather than a failing one.
#
# The occupant ignores SIGINT so it also models an agent surviving its
# interrupt key. This waits for the pane to actually take it up and returns
# non-zero if it never does, so a caller can never proceed on an unoccupied
# pane believing it is live.
#
# The wait identifies THIS occupant by a per-call marker carried in its own
# command line, never merely by "something other than the shell owns the
# foreground". A pane run lands as text in a shell that may still be starting
# up, and that shell's own startup children can own the foreground for a moment
# before the occupant arrives; a caller that returned on that transient would
# proceed against an unoccupied pane and assert nothing - the exact vacuous
# fixture this helper exists to prevent (observed: an occupancy that reported
# success while `pane process-info` still showed the lone shell, which then let
# tests/fm-backend-herdr-smoke.test.sh's live-duplicate case fail
# intermittently).
herdr_occupy_pane() { # <session> <pane-id>
  local session=$1 pane=$2 attempt=0 info marker
  local max_attempts=${HERDR_OCCUPY_PANE_POLLS:-40}
  marker="fm-occupied-$$-$(printf '%s' "$pane" | tr -c 'a-zA-Z0-9' '-')"
  fm_herdr_lab_cli "$session" pane run "$pane" \
    "sh -c 'trap \"\" INT; : $marker; while :; do sleep 1; done'" >/dev/null 2>&1 || return 1
  while [ "$attempt" -lt "$max_attempts" ]; do
    info=$(fm_herdr_lab_cli "$session" pane process-info --pane "$pane" 2>/dev/null) || info=
    if printf '%s' "$info" | jq -e --arg m "$marker" '
      .result.process_info
      | (.shell_pid | type == "number")
        and (.foreground_process_group_id | type == "number")
        and (.foreground_process_group_id != .shell_pid)
        and ([.foreground_processes[]? | select((.cmdline // "") | contains($m))] | length > 0)
    ' >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
    attempt=$((attempt + 1))
  done
  return 1
}
