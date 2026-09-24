#!/usr/bin/env bash
# fm-control-lib.sh - the ONE executable owner of firstmate's agent lifecycle
# CONTROL-PLANE mechanics.
#
# Data plane vs control plane (captain-approved root architecture, 2026-07-13).
# bin/fm-send.sh is the DATA plane: conversational text for the agent to read,
# always routing-marked for a kind=secondmate target so the reply comes back
# through the status path. That marking is exactly right for a message and
# exactly wrong for a lifecycle command: a marked "/quit" arrives as ordinary
# chat ("[fm-from-firstmate] /quit") that the agent reasons ABOUT instead of
# executing. bin/fm-control.sh is the CONTROL plane: allowlisted lifecycle
# verbs addressed to an exact task id, with the per-harness mechanics owned
# here rather than improvised per harness in agent prose.
#
# This file owns three capability tables plus their pure artifact-path tables
# and nothing else. It has no side effects, runs no backend command, and reads
# no state, so it can be sourced by a test as a pure contract:
#
#   1. Verb allowlist. There is no arbitrary-text and no generic raw-key entry
#      point on the control plane; a caller either names an allowlisted verb or
#      is refused.
#   2. Per-harness control mechanics: which key interrupts a running turn, how
#      many times it must be sent, whether the composer needs clearing after
#      that key, which adapter-owned cancellation acknowledgement is observable,
#      which command exits the agent, and which task kinds the adapter is
#      verified to run. These are the empirically verified facts previously
#      carried only in the harness-adapters skill's per-adapter tables; that
#      skill now points here so one executable owner holds them, and
#      bin/fm-send.sh's --key path reads the same table rather than a second
#      copy of it.
#   3. Per-backend capability: which named keys a runtime backend can deliver,
#      and whether the backend has a recovery-grade agent-state classifier
#      (bin/fm-backend.sh's fm_backend_agent_state) able to PROVE that an agent
#      stopped. A verb whose postcondition cannot be proven on the recorded
#      backend is refused rather than performed blind.
#
# `resume` is deliberately NOT a verb. It is not deterministic across the
# retained adapters have no verified common pane-resume contract
# at all. `relaunch` covers the same need deterministically for every adapter,
# because the brief on disk - not a harness-private session - is the durable
# instruction.

# The complete control-plane verb allowlist, one per line.
fm_control_verbs() {
  cat <<'EOF'
interrupt
exit
relaunch
EOF
}

fm_control_verb_allowed() {  # <verb>
  case "${1-}" in
    interrupt|exit|relaunch) return 0 ;;
  esac
  return 1
}

# Historical identities are readable, but never authorize launch or control.
fm_control_harness_removed() {
  case "${1-}" in
    claude*|opencode*|grok*|kimi*|cursor*|gemini*|muse*|rovo*|omp|agy|pi-signed) return 0 ;;
  esac
  return 1
}

fm_control_require_recoverable_harness() { # <recorded-harness>
  if fm_control_harness_removed "${1-}"; then
    echo "error: historical harness '$1' is no longer supported; automatic recovery and cleanup refused. Preserve the task record and worktree, then arrange an explicit migration to pi, codex, or traex." >&2
    return 1
  fi
  return 0
}

# Maintained harness control mechanics. Unsupported records are refused before
# any lifecycle input is sent; they are never normalized into a replacement.
fm_control_harness_supported() {
  case "${1-}" in pi|codex|traex) return 0 ;; esac
  return 1
}

fm_control_harness_family() {
  fm_control_harness_supported "${1-}" || return 1
  printf '%s' "$1"
}

fm_control_harness_supports_kind() {
  fm_control_harness_supported "${1-}" || return 1
  [ "$1" != traex ] || [ "${2-}" != secondmate ]
}

fm_control_interrupt_key() {
  fm_control_harness_supported "${1-}" || return 1
  printf Escape
}

fm_control_interrupt_repeat() {
  fm_control_harness_supported "${1-}" || return 1
  printf 1
}

fm_control_interrupt_clear_key() {
  fm_control_harness_supported "${1-}" || return 1
  [ "$1" != traex ] || printf C-u
}

fm_control_interrupt_ack_source() {
  fm_control_harness_supported "${1-}" || return 1
  printf none
}

fm_control_exit_command() {
  case "${1-}" in
    pi|codex) printf /quit ;;
    traex) printf /exit ;;
    *) return 1 ;;
  esac
}

# Which named keys a backend adapter can deliver. Every session provider
# normalizes Enter, Ctrl+C, and the Ctrl+U composer clear; Orca's terminal API
# exposes only an interrupt and an Enter, so it can deliver neither Escape nor
# Ctrl+U (bin/backends/orca.sh's fm_backend_orca_send_key).
fm_control_backend_supports_key() {  # <backend> <key>
  local backend=${1-} key=${2-}
  case "$backend" in
    tmux|herdr|zellij|cmux)
      case "$key" in Escape|Enter|C-c|C-u) return 0 ;; esac
      ;;
    orca)
      case "$key" in Enter|C-c) return 0 ;; esac
      ;;
  esac
  return 1
}

# Whether <backend> has a recovery-grade agent-state classifier. Only tmux and
# herdr implement fm_backend_agent_state; zellij, orca, and cmux report
# `unverified`, so no reading of theirs can prove an agent stopped. The control
# plane refuses a stop-proving verb there instead of reporting an unprovable
# transition as success.
fm_control_backend_state_verified() {  # <backend>
  case "${1-}" in
    tmux|herdr) return 0 ;;
  esac
  return 1
}

# Only Pi creates per-task wiring in maintained adapters.
fm_control_harness_wiring_paths() { # <harness> <worktree> <state-dir> <id>
  [ -n "${2-}" ] && [ -n "${3-}" ] && [ -n "${4-}" ] || return 1
  case "${1-}" in pi) printf '%s/%s.pi-ext.ts\n' "$3" "$4" ;; esac
}
