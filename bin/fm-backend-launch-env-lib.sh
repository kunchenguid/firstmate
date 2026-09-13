#!/usr/bin/env bash
# bin/fm-backend-launch-env-lib.sh - the single owner of the color-control
# variables that must never ride into a long-lived session-provider server.
#
# Every spawn-capable backend births a server or detached session that outlives
# the launch, and each one hands its own startup environment to every pane it
# later creates (docs/verification/runtime-backends.md, "a long-lived tmux or
# Herdr server hands panes the environment it was started with"). A secondmate
# or agent that launches firstmate under NO_COLOR=1 therefore bleaches every
# later crew pane, and the leak does not self-heal: NO_COLOR is not in tmux's
# default `update-environment` set, so a later client attach does not repair it.
#
# The launcher's color preference describes the LAUNCHER's terminal, never the
# crew panes, so no backend wants it propagated. Each adapter calls this in the
# subshell that starts its server; the list lives here once so tmux, Herdr, and
# zellij cannot drift apart.
#
# Scope: color control only. Firstmate home/directory overrides and harness
# identity markers are scrubbed per-backend, because which of those a given
# server may keep is a backend-specific, empirically verified decision.

# fm_backend_launch_env_color_scrub: drop every color-suppression and
# color-forcing variable from the current (sub)shell, so the server about to be
# started inherits the terminal's own color behavior instead of the launcher's.
fm_backend_launch_env_color_scrub() {
  unset NO_COLOR FORCE_COLOR CLICOLOR CLICOLOR_FORCE
}
