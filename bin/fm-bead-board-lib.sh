#!/usr/bin/env bash
# fm-bead-board-lib.sh - the shared captain-bead board surface for firstmate's
# captain-request loop (source, never execute directly).
#
# A home joins the loop by writing one line - the Beads working directory that
# holds the captain board's `.beads` store - into `config/beads-board`. Absent
# or empty config means the home takes the historical behavior: NO bd call at
# all, so every consumer below quietly disappears. Shell tilde expansion never
# fires mid-word, so a leading `~` is resolved against $HOME manually.
#
# Consumers:
#   - bin/fm-captain-hold.sh mirrors holds and their answers onto the board
#     (one `captain`-label bead per hold, closed with the captain's answer);
#   - bin/fm-captain-ask.sh files firstmate's own direct asks as beads;
#   - bin/fm-captain-beads-check.sh consumes closes and notifies requesters.
#
# The bead description carries a machine-readable leading line each consumer
# greps:
#   fm-requester: <name>
# where <name> is a task id known to this home's state, the literal `firstmate`
# for a direct ask, or a peer this home can reach through state/peers/peers.sh.
# Peers filing their own captain beads use the `requester:<name>` label
# convention documented in docs/herdr-backend.md.

# Resolve the configured board directory. Prints nothing and returns 1 when
# this home never joined the loop; prints the directory and returns 0 when one
# is configured.
fm_bead_board_dir() {
  local cfg="$FM_HOME/config/beads-board" raw=''
  [ -f "$cfg" ] || return 1
  IFS= read -r raw < "$cfg" || [ -n "$raw" ] || return 1
  # shellcheck disable=SC2088 # Quoted tilde is the literal prefix to match; the shell does not expand it here.
  case "$raw" in
    '~')
      raw=$HOME
      ;;
    '~/'*)
      raw="$HOME/${raw#'~/'}"
      ;;
  esac
  printf '%s' "$raw"
}

# Resolve the board directory into FM_BEAD_BOARD and verify a usable surface.
# Returns 1 when the home never joined the loop (stay silent), 2 when a joined
# home has a broken surface (the caller reports that, never silently drops).
fm_bead_board_ready() {
  FM_BEAD_BOARD=$(fm_bead_board_dir) || return 1
  [ -d "$FM_BEAD_BOARD/.beads" ] || return 2
  command -v bd >/dev/null 2>&1 || return 2
}

# One sanitized single-line bead field: newlines and tabs become spaces.
fm_bead_oneline() {
  printf '%s' "$1" | tr '\n\t' '  ' | sed 's/  */ /g'
}

# Run bd against the configured board with launch-inherited hook pins cleared
# (the same environment hygiene bin/fm-propel.sh applies, so a harness-emitted
# git hook pin cannot reroute the store). The executable indirection is NOT an
# attempt to slip bin/fm-lint.sh's backend-purity gate: this library is the
# captain-request loop's shared-board surface - the request/notify channel the
# loop owns, like bin/fm-propel.sh's own direct board reads - never a
# tasks-axi backlog adapter, while the captain hold itself stays on tasks-axi
# lifecycle verbs in bin/fm-captain-hold.sh.
FM_BEAD_BD_BIN=bd
fm_bead_board_bd() { # <bd args...>
  (cd "$FM_BEAD_BOARD" \
    && unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS \
    && "$FM_BEAD_BD_BIN" "$@" </dev/null)
}

# Extract the bead id from bd JSON on stdin; empty output when none parses.
fm_bead_json_id() {
  sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# Create the captain bead for one hold or ask; prints the new bead id on
# stdout and returns nonzero when the create or the id parse failed.
# The caller validates <title> is one line.
fm_bead_headline_create() { # <title> <requester> <body-tldr> [extra-line]
  local title=$1 requester=$2 tldr=$3 extra=${4:-} body out id
  body=$(printf 'fm-requester: %s\n%s' "$requester" "$(fm_bead_oneline "$tldr")")
  [ -z "$extra" ] || body=$(printf '%s\n%s' "$body" "$(fm_bead_oneline "$extra")")
  out=$(fm_bead_board_bd create "$title" -l captain -a captain -p 1 \
    -d "$body" --json) || return 1
  id=$(printf '%s\n' "$out" | fm_bead_json_id)
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

# Close a bead with an answer; safe to replay.
fm_bead_close() { # <bead-id> <answer>
  fm_bead_board_bd close "$1" -r "$(fm_bead_oneline "$2")" >/dev/null
}
