#!/usr/bin/env bash
# Reconcile the zellij-only supervisor tab for this firstmate home.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source zellij

usage() {
  cat <<'EOF'
usage: fm-supervisor-panes.sh

Reconcile the zellij-only supervisor tab for active non-secondmate crews.
EOF
}

discover_zellij_task_ids() {
  local meta id kind backend target_session target
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(fm_meta_get "$meta" kind)
    [ -n "$kind" ] || kind=ship
    [ "$kind" = secondmate ] && continue
    backend=$(fm_backend_of_meta "$meta")
    [ "$backend" = zellij ] || continue
    target=$(fm_backend_target_of_meta "$meta")
    case "$target" in
      *:*) target_session=${target%%:*} ;;
      *) target_session=$(fm_meta_get "$meta" zellij_session) ;;
    esac
    [ -n "$target_session" ] || target_session=$ZELLIJ_SESSION
    [ "$target_session" = "$ZELLIJ_SESSION" ] || continue
    id=$(basename "$meta" .meta)
    printf '%s\n' "$id"
  done | LC_ALL=C sort -u
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

ZELLIJ_SESSION=$(fm_backend_zellij_session)
mapfile -t TASK_IDS < <(discover_zellij_task_ids)
fm_backend_zellij_supervisor_reconcile "$ZELLIJ_SESSION" "${TASK_IDS[@]}"
