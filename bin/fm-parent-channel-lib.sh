#!/usr/bin/env bash
# fm-parent-channel-lib.sh - the one owner of a secondmate home's parent channel.
#
# WHY THIS EXISTS. A secondmate is a firstmate in its own home, and nobody reads
# its chat: the captain and the main firstmate see only what is appended to the
# parent channel. AGENTS.md tells every firstmate to reach the captain and to
# address the captain in every response, so a mate model reliably "reports" a
# PR-ready result, a finding, a decision, a blocker, or a failure in its own
# chat and skips the one status-file append that would actually deliver it.
# Four such misses were observed on 2026-09-02 across two mate homes; the
# watcher had delivered the parent's request each time and the work was done.
# The problem is therefore not one missed PR notice but every captain-facing
# outcome that depends on the model remembering to write to the channel.
# The fix is structural: every script that RECORDS a captain-facing outcome in a
# mate home publishes it on the parent channel itself, so delivery never
# depends on the model. This library owns where that channel lives and how a
# line is appended to it. The publishers are:
#   - bin/fm-inactive-reconcile.sh   a direct child's terminal done or failed
#                                    ledger line, on every watcher poll, plus
#                                    the silent-ledger inactive-outcome fallback
#   - bin/fm-pr-check.sh             a registered PR-ready line carrying the
#                                    canonical URL
#   - bin/fm-captain-hold.sh         a task held for the captain and its answer
#   - bin/fm-merge-outcome-lib.sh    a merged PR
#   - bin/fm-teardown.sh             the child's final ledger line, refusing to
#                                    remove the child while it is undelivered
#   - bin/fm-secondmate-report.sh     a marked request's correlated answer,
#                                    with this resolver choosing its destination
# The mate's own appends are reserved for judgement (bin/fm-brief.sh charter).
# docs/secondmate-parent-channel.md records the design and its coverage.
#
# THE CHANNEL. It is resolved from the home's own durable identity and parent
# binding, never from a caller's choice:
#   - the .fm-secondmate-home marker names the mate's id in its parent home;
#   - the .fm-secondmate-parent record (bin/fm-secondmate-parent-lib.sh) names
#     the route: a local route reports into the parent home's
#     state/<mate-id>.status, a remote route into this home's own
#     state/parent-replies.status, which the parent's remote reply adapter
#     mirrors line for line into that same parent file
#     (docs/remote-secondmates.md).
# The parent watcher classifies lines there exactly as it classifies any
# crewmate's status stream, so a captain-relevant line becomes a parent wake.
#
# Line syntax and retry equivalence are owned by fm-classify-lib.sh.
# An existing destination must be a regular, non-symlinked file; a missing one
# is created with its directory.
#
# Return codes, shared by every entry point that resolves the channel:
#   0  resolved, or appended / already present
#   1  this is a main home (no .fm-secondmate-home marker): nothing to report
#   2  the identity marker exists but is unusable (symlink, NUL, bad id)
#   3  the parent binding is missing or unreadable
#   4  the append itself failed
# A caller that has already recorded the outcome locally must surface a
# non-zero return rather than treat it as delivered.
#
# Sourced by the publishers above and by tests. No side effects on source.

_FM_PARENT_CHANNEL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$_FM_PARENT_CHANNEL_LIB_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_PARENT_CHANNEL_LIB_DIR/fm-classify-lib.sh"

# shellcheck disable=SC2034 # Output globals read by sourcing callers.
FM_PARENT_CHANNEL_ID=
# shellcheck disable=SC2034 # Output globals read by sourcing callers.
FM_PARENT_CHANNEL_ROUTE=

# A mate id is used as a file-name component in the parent home, so it is
# accepted only when it is path-safe: no empty value, leading dot, slash, or
# character outside [A-Za-z0-9._-].
_fm_parent_channel_id_valid() {  # <id>
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# The secondmate identity of <home>, printed, or non-zero for a main home (1)
# or an unusable identity marker (2).
fm_parent_channel_home_id() {  # <home>
  local home=$1 marker id
  marker="$home/.fm-secondmate-home"
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 1
  fi
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  [ "$(wc -c < "$marker")" -eq "$(LC_ALL=C tr -d '\0' < "$marker" | wc -c)" ] || return 2
  id=$(cat "$marker" 2>/dev/null) || return 2
  _fm_parent_channel_id_valid "$id" || return 2
  printf '%s\n' "$id"
}

# Resolve the channel destination for <home> whose state dir is <state>.
# Prints the destination path and sets FM_PARENT_CHANNEL_ID and
# FM_PARENT_CHANNEL_ROUTE. Returns 1 for a main home, 2 for an unusable
# marker, 3 for a missing or unreadable parent binding.
fm_parent_channel_destination() {  # <home> <state>
  local home=$1 state=$2 id rc=0
  FM_PARENT_CHANNEL_ID=
  FM_PARENT_CHANNEL_ROUTE=
  id=$(fm_parent_channel_home_id "$home") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" || return 3
  case "$FM_SECONDMATE_PARENT_ROUTE" in
    local)
      [ -n "$FM_SECONDMATE_PARENT_HOME" ] || return 3
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ID=$id
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ROUTE=local
      printf '%s/state/%s.status\n' "$FM_SECONDMATE_PARENT_HOME" "$id"
      ;;
    remote)
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ID=$id
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ROUTE=remote
      printf '%s/parent-replies.status\n' "$state"
      ;;
    *) return 3 ;;
  esac
}

# Fold <text> onto one bounded line, so a note copied from a child ledger or a
# hold reason cannot break the channel's line framing.
fm_parent_channel_clean_note() {  # <text>
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-1200
}

# Append <line> once, using fm-classify-lib.sh's retry contract.
# Pass relay for historical copies to bypass stamping without changing retry
# equivalence; omitting it declares a newly emitted event.
fm_parent_channel_append_once() {  # <path> <line> [relay]
  local path=$1 line=$2
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
  else
    mkdir -p "$(dirname "$path")" || return 1
  fi
  if status_event_recorded "$path" "$line"; then
    return 0
  fi
  if [ "${3:-}" != relay ]; then
    line=$(status_stamp_line "$line")
  fi
  printf '%s\n' "$line" >> "$path"
}

# Publish one parent-facing line from <home>. See the return codes above.
fm_parent_channel_report() {  # <home> <state> <line>
  local home=$1 state=$2 line=$3 destination rc=0
  destination=$(fm_parent_channel_destination "$home" "$state") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  fm_parent_channel_append_once "$destination" "$line" || return 4
}
