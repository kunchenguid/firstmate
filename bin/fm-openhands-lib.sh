#!/usr/bin/env bash
# OpenHands driver identity: the one owner of the args-level match that names
# an openhands worker process. The OpenHands adapter is a firstmate-owned
# Python driver (bin/fm-openhands-worker.py) run under an OpenHands SDK venv
# interpreter, so neither a kernel process name nor an argv[0] can name it:
# both read as the interpreter (the comm is python3.12 and argv[0] is the venv
# path). The driver's own filename is the one structural token that identifies
# the process, it is firstmate-owned, and no vendor release can change it.
# Anchored on the full filename so an unrelated command merely carrying the
# openhands fragment in some argument never matches.
# Sourced by bin/fm-harness.sh and bin/fm-agent-process-lib.sh. This file is
# sourced by scripts and has no side effects on source.

FM_OPENHANDS_DRIVER_MARKER='fm-openhands-worker.py'

fm_openhands_args_are_openhands() {  # <flattened-args>
  case "${1:-}" in
    *"$FM_OPENHANDS_DRIVER_MARKER"*) return 0 ;;
    *) return 1 ;;
  esac
}
