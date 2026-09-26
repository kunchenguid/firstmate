#!/usr/bin/env bash
# Backend-neutral harness-process identity.
# Herdr passes independent kernel-name and argv0 evidence to this classifier.
# A surviving positive agent identity prevents duplicate launch; disagreement
# that proves no agent is never guessed from a registration or a pane title.
# tests/fm-agent-process.test.sh proves real process-name divergence without a
# terminal; tests/fm-agent-process-live-e2e.test.sh proves Herdr integration.

# shellcheck source=bin/fm-session-lock-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-session-lock-lib.sh"
# Only maintained harness identities count as a known agent. An unrecognized
# live process stays other/ambiguous, never evidence that a task may be destroyed.
fm_agent_process_classify_name() { # <path> [argv0] -> agent|shell|other
  local path=$1 argv0=${2:-} base
  base=${path##*/}
  base=${base#-}
  case "$base" in
    *codex*|pi|pi-launcher|Pi|traex|traecli) printf agent ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf shell ;;
    *)
      if fm_harness_path_name "$path" >/dev/null || fm_harness_path_name "$argv0" >/dev/null; then
        printf agent
      else
        printf other
      fi ;;
  esac
}

# fm_agent_process_classify: one process, from every identity surface a
# backend can hand over, as agent|shell|other. Any single surface naming a
# verified harness carries `agent`, because a false negative is the one outcome
# that launches a duplicate agent onto a live worktree; `shell` needs every
# readable surface to agree the process is a shell; anything else is `other`.
#
#   <name>   the kernel process name (ps comm, or Herdr's process-info .name):
#            on Linux the exec name, on macOS argv[0] truncated to 16 bytes.
#   <argv0>  argv[0] as the process reports it - a bare name or an install
#            path, whichever the launcher used (empty when unknown).
#   <args> and [pid] are accepted for the shared backend calling convention.
fm_agent_process_classify() {  # <name> <argv0> <args> [pid] -> agent|shell|other
  local name=${1:-} argv0=${2:-} by_name by_argv0
  by_name=$(fm_agent_process_classify_name "$name" "$argv0")
  [ "$by_name" != agent ] || { printf 'agent'; return 0; }
  if [ -n "$argv0" ]; then
    # argv[0] is classified as a path in its own right, so a bare `pi` or a
    # `-zsh` login name reads by basename and an install path by component.
    by_argv0=$(fm_agent_process_classify_name "$argv0" "$argv0")
    [ "$by_argv0" != agent ] || { printf 'agent'; return 0; }
  else
    by_argv0=$by_name
  fi
  if [ "$by_name" = shell ] && [ "$by_argv0" = shell ]; then
    printf 'shell'
  else
    printf 'other'
  fi
}
