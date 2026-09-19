# shellcheck shell=bash
# Shared terminal-outcome admission predicate.
# Usage: . bin/fm-terminal-outcome-lib.sh
#
# fm_terminal_outcome_pending_absent <state-dir> returns 0 when no unresolved
# terminal outcome is present and 1 with FM_TERMINAL_OUTCOME_ERROR set when the
# terminal-outcome state is unresolved or unrecognized.

# shellcheck disable=SC2034 # Public result consumed by sourcing callers.
FM_TERMINAL_OUTCOME_ERROR=

fm_terminal_outcome_pending_absent() {  # <state-dir>
  local state=$1 directory record name fingerprint
  FM_TERMINAL_OUTCOME_ERROR=
  directory="$state/terminal-outcomes"
  if [ ! -e "$directory" ] && [ ! -L "$directory" ]; then
    return 0
  fi
  if [ ! -d "$directory" ] || [ -L "$directory" ]; then
    FM_TERMINAL_OUTCOME_ERROR="terminal outcome state is unresolved at $directory"
    return 1
  fi
  for record in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
    if [ ! -e "$record" ] && [ ! -L "$record" ]; then
      continue
    fi
    if [ ! -f "$record" ] || [ -L "$record" ]; then
      FM_TERMINAL_OUTCOME_ERROR="terminal outcome state is unresolved at $record"
      return 1
    fi
    name=${record##*/}
    fingerprint=${name%.*}
    case "${#fingerprint}" in
      16|32) ;;
      *)
        FM_TERMINAL_OUTCOME_ERROR="terminal outcome state is unrecognized at $record"
        return 1
        ;;
    esac
    case "$fingerprint" in *[!A-Fa-f0-9]*)
      FM_TERMINAL_OUTCOME_ERROR="terminal outcome state is unrecognized at $record"
      return 1
      ;;
    esac
    case "$name" in
      *.pending)
        FM_TERMINAL_OUTCOME_ERROR="unresolved terminal outcome is present at $record"
        return 1
        ;;
      *.presented|*.reported) ;;
      *)
        FM_TERMINAL_OUTCOME_ERROR="terminal outcome state is unrecognized at $record"
        return 1
        ;;
    esac
  done
  return 0
}
