#!/usr/bin/env bash
# bin/fm-process-identity-lib.sh - the ONE fleet-wide owner of the
# process-name vocabulary every session-provider adapter uses to answer "is
# this process a verified harness agent, an idle shell, or something else?".
#
# WHY THIS EXISTS: the vocabulary started inside bin/backends/tmux.sh, whose
# own header already named it "the single owner ... so the two independent
# name sources can never drift into disagreeing about what a given name
# means". The moment a second adapter needed the same verdict
# (bin/backends/ryder.sh, whose agent-state classifier reads the same harness
# and shell names from a different primitive), keeping the decision inside one
# adapter would have forced exactly the copy the composer classifier was
# consolidated out of (bin/fm-composer-lib.sh). One owner here means a newly
# verified harness is taught to the fleet once.
#
# Each adapter still owns its own PROCESS DISCOVERY, because the primitives
# genuinely differ: tmux reads a pane tty and filters on the foreground process
# group, while ryder's session host reports the foreground process group leader
# and the pty's tty directly. Once an adapter holds a candidate executable path
# and argv[0] it hands both here for the shared verdict.
#
# Re-sourcing is a cheap idempotent redefinition, so this file needs no include
# guard (matching bin/fm-composer-lib.sh and bin/fm-tmux-lib.sh).

FM_PROCESS_IDENTITY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# fm_harness_path_name, the exact-path-component harness matcher this verdict
# falls back to for version-named harness executables.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_PROCESS_IDENTITY_LIB_DIR/fm-session-lock-lib.sh"

# fm_process_classify_name: `agent` for a verified harness, `shell` for an idle
# login/interactive shell, `other` for anything else.
#
# Both a command path and an argv[0] are accepted because the two supported
# platforms report different things in their respective name fields: macOS
# reports argv[0] in `ps -o comm=`, while procps on Linux reports the kernel
# exec name and ignores argv[0], so a version-named Claude Code binary is
# identified by its install path on one and by argv[0] on the other. Either
# naming a harness is enough, which is the safe direction: a false `other` only
# withholds a recovery, while a false `shell` would license one.
fm_process_classify_name() {  # <path> [argv0] -> agent|shell|other
  local path=$1 argv0=${2:-} base
  base=${path##*/}
  base=${base#-}
  case "$base" in
    # muse is anchored rather than globbed like its neighbours: its installed
    # binary is muse-bin-<version> (the launcher execs it, so the version is the
    # live process name and changes on every auto-update), and unlike `claude` or
    # `codex` the substring `muse` is a common English fragment - a *muse* glob
    # would classify musescore or amuse as a live agent pane. The install path
    # cannot carry it either: ~/.local/bin/muse-bin-<version> has no `muse` path
    # COMPONENT, so the fm_harness_path_name fallback below never fires for it.
    muse|muse-bin-*) printf 'agent' ;;
    *claude*|*codex*|*opencode*|*grok*|*kimi*|pi|pi-signed|pi-launcher|Pi) printf 'agent' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'shell' ;;
    *)
      if fm_harness_path_name "$path" >/dev/null || fm_harness_path_name "$argv0" >/dev/null; then
        printf 'agent'
      else
        printf 'other'
      fi
      ;;
  esac
}
