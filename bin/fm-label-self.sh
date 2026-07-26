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

OUT=$(fm_backend_label_self "$RUNTIME" "$LABEL" 2>&1) || \
  note "could not label this firstmate's own terminal tab in $RUNTIME; it keeps its previous name. ${OUT:-no detail reported}"

exit 0
