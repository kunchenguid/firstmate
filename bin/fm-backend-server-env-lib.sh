#!/usr/bin/env bash
# bin/fm-backend-server-env-lib.sh - the single owner of which launcher
# environment a Firstmate-birthed session-provider server must not keep.
#
# The Herdr, tmux, and zellij adapters can each birth a long-lived server from
# whatever Firstmate call happens to need it first, and each server hands its
# own startup environment to every pane it later creates, for its whole life
# (docs/herdr-backend.md "Current transport behavior"). Anything that caller
# carried for itself alone therefore gets frozen into the server and leaks into
# every later pane: a one-task per-call override pointing at a since-deleted
# temporary folder makes every pane's bin/fm-crew-state.sh answer "no
# metadata", and a launching Claude Code session's child-session marker turns
# transcript saving off for every Claude session later started in a pane.
#
# The scrub is by namespace, not by a hand-kept list of the names seen so far,
# so a new per-call override or a new agent-session marker cannot slip through:
#
# - Firstmate's own namespace, FM_* and FMX_*. Firstmate never relies on a
#   server-inherited value in it: every pane Firstmate launches receives its
#   home, harness, and role explicitly on its own launch command (fm-spawn.sh),
#   and operator settings live in config/ and .env files rather than in the
#   launcher environment.
# - Agent-session identity. Every CLAUDE_* name, which is where Claude Code
#   stamps its per-session markers (CLAUDECODE, CLAUDE_CODE_CHILD_SESSION,
#   CLAUDE_CODE_SESSION_ID, CLAUDE_CODE_MESSAGING_*, CLAUDE_ENV_FILE,
#   CLAUDE_PID, CLAUDE_PROJECT_DIR, CLAUDE_EFFORT, ...), except the operator
#   account and provider selection a pane's own Claude session needs to
#   authenticate at all (fm_backend_server_env_keep). Plus the cross-vendor
#   AI_AGENT marker and the exact identity markers of the other harnesses.
#
# Everything else - PATH, HOME, locale, terminal, SSH and GPG agents, proxies,
# display, unrelated tool credentials, and the backend's own session routing
# such as HERDR_SESSION - passes through unchanged. Only a server BIRTH is
# scrubbed; an already-running server is never restarted or re-environmented.

# fm_backend_server_env_keep <name>: succeed when <name>, although inside a
# scrubbed namespace, is genuine operator account or provider selection.
fm_backend_server_env_keep() {  # <name>
  case "$1" in
    CLAUDE_CONFIG_DIR|CLAUDE_CODE_OAUTH_TOKEN|\
    CLAUDE_CODE_USE_BEDROCK|CLAUDE_CODE_USE_VERTEX|CLAUDE_CODE_USE_FOUNDRY|\
    CLAUDE_CODE_SKIP_BEDROCK_AUTH|CLAUDE_CODE_SKIP_VERTEX_AUTH|CLAUDE_CODE_SKIP_FOUNDRY_AUTH|\
    CLAUDE_CODE_CLIENT_CERT|CLAUDE_CODE_CLIENT_KEY|CLAUDE_CODE_CLIENT_KEY_PASSPHRASE)
      return 0 ;;
  esac
  return 1
}

# fm_backend_server_env_drop_names: print, one per line, every exported name in
# the current shell that a server birth must not keep.
fm_backend_server_env_drop_names() {
  local name
  while IFS= read -r name; do
    case "$name" in
      FM_*|FMX_*) ;;
      CLAUDE*|AI_AGENT) fm_backend_server_env_keep "$name" && continue ;;
      CURSOR_AGENT|CURSOR_INVOKED_AS|PI_CODING_AGENT|GROK_AGENT) ;;
      *) continue ;;
    esac
    printf '%s\n' "$name"
  done < <(compgen -e)
}

# fm_backend_server_env_scrub: unset every name fm_backend_server_env_drop_names
# prints. Call it only inside the subshell that is about to birth the server,
# after anything that still needs those values has already been resolved.
fm_backend_server_env_scrub() {
  local name
  while IFS= read -r name; do
    unset "$name"
  done < <(fm_backend_server_env_drop_names)
}
