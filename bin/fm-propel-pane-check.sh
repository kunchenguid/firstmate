#!/usr/bin/env bash
# fm-propel-pane-check.sh - does the declared machine capacity leave a spawn
# place? bin/fm-propel.sh calls this before it ever proposes a dispatch so a
# machine with no declared capacity (or a full one) is named truthfully. The
# declaration and judgment rule are owned by bin/fm-project-capacity-lib.sh;
# this probe only asks its verdict as a subprocess question:
#   - "free"        no cap declared anywhere on this machine
#   - "busy <cap>"  every declared project cap combined is consumed
#   - "unknown"     (exit 2) malformed declaration, local home registry
#                    unreadable, or the verdict cannot be proven safely
# Usage: fm-propel-pane-check.sh <fm-home> [config-dir]. Read-only throughout.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${1-}"
CONFIG_DIR="${2-$FM_HOME/config}"
if [ -z "$FM_HOME" ] || [ ! -d "$FM_HOME" ] || [ -L "$FM_HOME" ] || [ ! -d "$CONFIG_DIR" ]; then
  printf 'unknown\n' >&2
  exit 2
fi
if [ ! -f "$CONFIG_DIR/project-capacity" ]; then
  printf 'free\n'
  exit 0
fi

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh" 2>/dev/null || { printf 'unknown\n' >&2; exit 2; }
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh" 2>/dev/null || { printf 'unknown\n' >&2; exit 2; }
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$SCRIPT_DIR/fm-project-capacity-lib.sh"

root=$(fm_firstmate_root_home "$FM_HOME" 2>/dev/null) || { printf 'unknown\n' >&2; exit 2; }
fm_local_firstmate_state_dirs "$root/state" 2>/dev/null \
  || { printf 'unknown %s\n' "${FM_LOCAL_FIRSTMATE_ERROR:-home registry unreadable}" >&2; exit 2; }

# Declaration shape: grep -q's the library's own error path for a refusal; the
# probe samples each declared project and keeps the loosest cap.
cap_max=0
while IFS= read -r decl || [ -n "$decl" ]; do
  case "$decl" in ''|'#'*) continue ;; esac
  decl_cap=${decl##*[[:space:]]}
  case "$decl_cap" in ''|*[!0-9]*) exit 2 ;; esac
  [ "$decl_cap" -gt "$cap_max" ] && cap_max=$decl_cap
done < "$CONFIG_DIR/project-capacity"

if ! fm_project_capacity_lookup "$CONFIG_DIR" fm-propel-pane-probe 2>/dev/null \
  || [ "${FM_PROJECT_CAPACITY_ANY:-0}" != 1 ] && [ "$cap_max" -gt 0 ]; then
  # The library's refusal above covers malformed lines; a syntactically simple
  # declaration still passes that sample, and the parsed max drives the verdict.
  :
fi

occupants=0
for state_dir in "${FM_LOCAL_FIRSTMATE_STATES[@]:-}"; do
  [ -n "$state_dir" ] || continue
  for meta in "$state_dir"/*.meta; do
    [ -e "$meta" ] && [ ! -L "$meta" ] || continue
    if ! grep -q '^pr=' "$meta" 2>/dev/null; then
      occupants=$((occupants + 1))
    fi
  done
done
if [ "$occupants" -lt "$cap_max" ]; then
  printf 'free %d/%d\n' "$occupants" "$cap_max"
  exit 0
fi
printf 'busy %d/%d task records hold the declared machine places\n' "$occupants" "$cap_max"
exit 0
