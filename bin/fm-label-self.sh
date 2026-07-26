#!/usr/bin/env bash
# fm-label-self.sh - give firstmate's OWN terminal endpoint a standing label.
#
# Why: every worker endpoint firstmate spawns is labeled fm-<task-id>, but
# firstmate's own pane is launched by the captain and so carries whatever the
# runtime defaults to (a bare "1" under herdr, a positional name under tmux).
# The supervisor was therefore the one endpoint with no visible front door,
# which is how a captain came to issue cross-lane instructions into a crewmate
# pane on 2026-07-26. This labels the caller's own endpoint so the supervisor
# is identifiable at a glance.
#
# Usage: fm-label-self.sh [--label <label>]
#   --label <label>  override the resolved label (default: FM_SELF_LABEL, else
#                    "firstmate"). An EXPLICITLY EMPTY label - FM_SELF_LABEL= or
#                    --label "" - is the documented no-op, used by the test
#                    suite so a run from inside a real terminal never relabels
#                    the developer's own window or tab.
#   -h, --help       print this header.
#
# Contract: ALWAYS exits 0 - this is a cosmetic convenience run from
# bin/fm-session-start.sh, never a gate. It prints NOTHING when the endpoint
# was labeled, and exactly one plain-English `note:` line explaining why not
# otherwise. That keeps a routine session start silent and keeps a failure from
# looking like an actionable bootstrap diagnostic.
#
# Refusals, all of which protect endpoint IDENTITY rather than cosmetics:
#   - A SECONDMATE home is refused outright. A secondmate's own endpoint was
#     created by the parent's fm-spawn.sh and is labeled fm-<secondmate-id>;
#     that label is the parent's identity handle for it
#     (fm_backend_expected_label_of_selector, and herdr's label-matched
#     recovery in fm_backend_herdr_list_live), so renaming it would break the
#     parent's send/peek/recovery path.
#   - Any label starting with `fm-` is refused, because that prefix is the
#     reserved task-endpoint namespace: herdr's recovery scan treats every
#     fm-* tab in a home's workspace as a live task.
#   - An endpoint that cannot be IDENTIFIED is refused. The caller's own
#     endpoint is resolved exactly once, through fm_backend_self_endpoint_id,
#     and that one id is handed to both the current-label read and the rename:
#     two separate resolutions could disagree, so the refusal below could pass
#     on one endpoint while the rename landed on another. A backend whose
#     ambient markers cannot name the caller's own endpoint reports that and
#     renames nothing.
#   - An endpoint that ALREADY carries an fm- label is refused. A crewmate or
#     scout working in a firstmate-repo worktree runs bin/fm-session-start.sh
#     too, and its home has no secondmate marker and resolves the same
#     "firstmate" label, so every other refusal here passes: without reading the
#     label the endpoint currently carries, this step would rename a live
#     fm-<task-id> worker endpoint to "firstmate", dropping it out of the
#     namespace fm_backend_herdr_list_live scans for recovery and orphan
#     discovery, and putting the supervisor's name on a crewmate pane - the
#     exact incident above, inverted. The current label is read through
#     fm_backend_current_self_label and this FAILS CLOSED: a label that cannot
#     be read at all is not evidence the endpoint is safe to rename, so it is
#     refused too.
#   - A runtime with no verified self-label operation is reported, not faked.
#
# The runtime is resolved with fm_backend_detect (the runtime this process is
# CURRENTLY executing inside), never fm_backend_name: config/backend names the
# backend NEW TASKS spawn into, which can legitimately differ from the terminal
# the captain launched firstmate in.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

# The secondmate-home marker written by bin/fm-home-seed.sh. Read directly
# rather than through the herdr adapter, because this refusal must hold for
# every runtime, including ones with no herdr adapter loaded.
SECONDMATE_MARKER=".fm-secondmate-home"

LABEL=${FM_SELF_LABEL-firstmate}
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --label) LABEL=${2:-}; shift 2 || exit 0 ;;
    *) printf 'note: fm-label-self.sh ignored unknown argument %s\n' "$1"; exit 0 ;;
  esac
done

note() { printf 'note: %s\n' "$1"; exit 0; }

[ -n "$LABEL" ] || note "self-labeling is switched off (empty label), so this firstmate's own terminal tab is unchanged."
case "$LABEL" in
  fm-*) note "refused to label this firstmate's own terminal tab '$LABEL': the fm- prefix is reserved for worker endpoints." ;;
esac

if [ -f "$FM_HOME/$SECONDMATE_MARKER" ]; then
  note "this is a secondmate home, so its own endpoint keeps the fm- label the main firstmate reaches it by."
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

RUNTIME=$(fm_backend_detect 2>/dev/null) || RUNTIME=""
[ -n "$RUNTIME" ] || note "this firstmate is not running inside a terminal runtime that can label its own tab."

# stderr is captured to its own file rather than folded into the command
# substitution: the value below is what the `fm-*` worker-endpoint refusal
# matches on, and a warning printed alongside a successful read would otherwise
# prepend text to it, break the prefix match, and let this step rename a live
# worker endpoint. A missing sink degrades to dropping the explanatory detail,
# never to mixing it into the label.
ERRFILE=$(mktemp "${TMPDIR:-/tmp}/fm-label-self-detail.XXXXXX" 2>/dev/null) || ERRFILE=""
ERRSINK=${ERRFILE:-/dev/null}
trap '[ -z "$ERRFILE" ] || rm -f "$ERRFILE"' EXIT

# The captured stderr of the last call, collapsed to one line so a note stays a
# single line.
detail() {
  local text=""
  [ -n "$ERRFILE" ] && [ -s "$ERRFILE" ] && text=$(tr '\n' ' ' < "$ERRFILE")
  printf '%s' "${text:-no detail reported}"
}

# Resolve the caller's OWN endpoint exactly once and address both the read and
# the rename below through that one id, so a refusal can never pass on one
# endpoint while the rename lands on another.
ENDPOINT=$(fm_backend_self_endpoint_id "$RUNTIME" 2>"$ERRSINK") || ENDPOINT=""
[ -n "$ENDPOINT" ] || \
  note "could not work out which $RUNTIME terminal tab this firstmate is running in, so nothing was renamed. $(detail)"

CURRENT=$(fm_backend_current_self_label "$RUNTIME" "$ENDPOINT" 2>"$ERRSINK") || \
  note "could not read what this terminal tab is currently called in $RUNTIME, so it was left alone rather than risk renaming a worker endpoint. $(detail)"
case "$CURRENT" in
  fm-*) note "this terminal tab is already a worker endpoint called '$CURRENT', so it was left alone: that is the name firstmate reaches its crew by, and this pane is not firstmate." ;;
esac

fm_backend_label_self "$RUNTIME" "$LABEL" "$ENDPOINT" >/dev/null 2>"$ERRSINK" || \
  note "could not label this firstmate's own terminal tab in $RUNTIME; it keeps its previous name. $(detail)"

exit 0
