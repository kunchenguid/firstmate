#!/usr/bin/env bash
# Label THIS home's herdr workspace + firstmate entrypoint pane at session start.
#
# Usage: fm-herdr-home-label.sh
#
# Runs on the locked, fresh session-start path (composed by fm-session-start.sh
# next to fm-herdr-session-cleanup.sh). No-op unless firstmate itself is CURRENTLY
# executing inside a herdr pane - detected by fm_backend_detect (which resolves
# innermost-first, so a tmux nested inside a herdr pane correctly does NOT match)
# plus the HERDR_WORKSPACE_ID/HERDR_PANE_ID the herdr client injects into the
# entrypoint pane.
#
# It gives this home's workspace a display label = the home's own workspace
# label and titles the entrypoint pane "<label> · firstmate". The label is
# fm_backend_herdr_workspace_label - the SAME single source of truth spawn,
# recovery (fm_backend_herdr_list_live), and cleanup resolve a home's workspace
# by, so labeling the entrypoint workspace here keeps it findable rather than
# renaming it out from under those paths. For a primary home that label is the
# FM_HOME basename (the home name); a secondmate home keeps its "2ndmate-<id>".
# Idempotent: a rename sets the label to the exact value, so re-running session
# start keeps one label with no duplicate. Every error warns and returns success
# so startup continues.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

fm_herdr_home_label_warn() {
  printf 'warning: herdr home labeling: %s\n' "$*" >&2
}

fm_herdr_home_label() {
  local detected label session workspace pane

  command -v herdr >/dev/null 2>&1 || return 0
  # Only when firstmate's live runtime is genuinely herdr. fm_backend_detect
  # returns tmux when a tmux runs nested inside a herdr pane, so this no-ops
  # on tmux/other backends exactly as required.
  detected=$(fm_backend_detect) || return 0
  [ "$detected" = herdr ] || return 0

  workspace="${HERDR_WORKSPACE_ID:-}"
  pane="${HERDR_PANE_ID:-}"
  [ -n "$workspace" ] && [ -n "$pane" ] || {
    fm_herdr_home_label_warn 'herdr workspace/pane id missing from the entrypoint environment'
    return 0
  }

  fm_backend_source herdr || {
    fm_herdr_home_label_warn 'herdr backend helpers are unavailable'
    return 0
  }
  # The one source of truth spawn/recovery/cleanup also resolve this home's
  # workspace by, so the entrypoint workspace stays findable rather than being
  # renamed to a string those paths do not search for.
  label=$(fm_backend_herdr_workspace_label)
  [ -n "$label" ] || {
    fm_herdr_home_label_warn 'home workspace label is empty; leaving labels unchanged'
    return 0
  }
  session=$(fm_backend_herdr_session)

  fm_backend_herdr_cli "$session" workspace rename "$workspace" "$label" >/dev/null 2>&1 \
    || fm_herdr_home_label_warn "workspace '$workspace' rename to '$label' was refused"
  fm_backend_herdr_cli "$session" pane rename "$pane" "$label · firstmate" >/dev/null 2>&1 \
    || fm_herdr_home_label_warn "pane '$pane' rename to '$label · firstmate' was refused"
  return 0
}

if [ "${FM_HERDR_HOME_LABEL_SOURCE_ONLY:-0}" != 1 ]; then
  fm_herdr_home_label
  exit 0
fi
