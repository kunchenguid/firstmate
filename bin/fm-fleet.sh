#!/usr/bin/env bash
# fm-fleet.sh — FirstMate federation CLI. Coordinates multiple operators through a
# shared, cross-uid-safe, data-only KB. See docs/fleet-quickstart.md,
# docs/fleet-addon.md, and .agents/skills/federation/SKILL.md.
#
# Usage:
#   fm-fleet.sh preflight                    (which tier is this home ready for; read-only)
#   fm-fleet.sh admiral [status|enable|disable]
#                                            (cross-operator tier opt-in; config/admiral)
#   fm-fleet.sh init
#   fm-fleet.sh register  <op> <scopes-csv> <home> [accounts]
#   fm-fleet.sh heartbeat <op>
#   fm-fleet.sh leave     <op>
#   fm-fleet.sh queue   <id> <scope> <desc...>
#   fm-fleet.sh claim   <id> <operator>
#   fm-fleet.sh handoff <id> <to-operator>
#   fm-fleet.sh drain   <id>                 (migrate a drained operator's item to one with headroom; cap + "fleet out of tokens" state)
#   fm-fleet.sh reap    [ttl-seconds]        (default 86400)
#   fm-fleet.sh route   <scope>              (echoes owning operator)
#   fm-fleet.sh budget                       (exit 0 iff local headroom >= FM_FLEET_QUOTA_MIN
#                                             and, under conservation pressure, the worst
#                                             fresh reserve >= FM_FLEET_RESERVE_MIN)
#   fm-fleet.sh quota                        (per-surface headroom + pace report)
#   fm-fleet.sh models                       (model family -> surfaces table)
#   fm-fleet.sh pick    <model-family>       (best surface with headroom: sustainable
#                                             pace first, then map order)
#   fm-fleet.sh status
#   fm-fleet.sh view    [--follow]
#
# Fleet dir resolves from: FM_FLEET_DIR -> $FM_HOME/config/fleet-dir -> /opt/agents/fleet
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-fleet-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-fleet-lib.sh"
DIR=$(fm_fleet_dir)

cmd=${1:-}; shift || true

# Every verb that touches an existing fleet must find one first. `init` creates it;
# quota/models/pick are surface-local and need no fleet at all.
case "$cmd" in
  # preflight/admiral exist precisely to be usable BEFORE there is a fleet: one
  # reports what a tier would need, the other records the opt-in that turns the
  # cross-operator tier on. Requiring a fleet for either would be circular.
  init|budget|quota|models|pick|preflight|admiral|'') : ;;
  # register/heartbeat/leave are how you BECOME an operator, and they already need
  # write access to the shared dir (POSIX group), so they skip the ownership check.
  register|heartbeat|leave) fm_fleet_assert_initialized "$DIR" || exit 1 ;;
  *) fm_fleet_assert_usable "$DIR" || exit 1 ;;
esac

case "$cmd" in
  init)    fm_fleet_init "$DIR"; echo "fleet initialized at $DIR" ;;
  queue)   id=$1; scope=$2; shift 2; fm_fleet_queue "$DIR" "$id" "$scope" "$*" ;;
  claim)   fm_fleet_claim "$DIR" "$1" "$2" ;;
  handoff) fm_fleet_handoff "$DIR" "$1" "$2" ;;
  drain)   fm_fleet_drain_handoff "$DIR" "$1" ;;
  reap)    fm_fleet_reap "$DIR" "${1:-86400}" ;;
  route)   fm_fleet_route "$DIR" "$1" ;;
  status)  fm_fleet_status "$DIR" ;;
  view)    fm_fleet_view "$DIR" "${1:-}" ;;
  register)  op=$1; scopes=$2; home=$3; shift 3; fm_fleet_register "$DIR" "$op" "$scopes" "$home" "${1:-}" ;;
  heartbeat) fm_fleet_heartbeat "$DIR" "$1" ;;
  leave)     fm_fleet_leave "$DIR" "$1" ;;
  budget)    rc=0; fm_fleet_budget_ok || rc=1; echo "$fm_fleet_budget_reason"; exit "$rc" ;;
  preflight) exec "$SCRIPT_DIR/fm-fleet-preflight.sh" "$@" ;;
  # The cross-operator opt-in, following the config/berths idiom: a gitignored flag
  # file whose ABSENCE leaves this home behaving exactly as a solo home always has.
  # Enabling records consent; it installs nothing and needs no root.
  admiral)
    case "${1:-status}" in
      enable)
        mkdir -p "$FM_HOME/config"
        : > "$FM_HOME/config/admiral"
        echo "admiral: enabled — this home now participates in the cross-operator tier"
        echo "  store: $("$SCRIPT_DIR/fm-handoff-doc.sh" where | head -1)"
        ;;
      disable)
        rm -f "$FM_HOME/config/admiral"
        echo "admiral: disabled — this home is solo again; nothing else changed"
        ;;
      status)
        if [ -f "$FM_HOME/config/admiral" ]; then
          echo "admiral: enabled (config/admiral present)"
        else
          echo "admiral: disabled (config/admiral absent — the default)"
          echo "  enable with: bin/fm-fleet.sh admiral enable"
        fi
        ;;
      *) echo "usage: fm-fleet.sh admiral [status|enable|disable]" >&2; exit 1 ;;
    esac
    ;;
  quota)     fm_fleet_quota_report ;;
  models)    fm_fleet_models_report ;;
  pick)      fm_fleet_pick_surface "${1:?usage: fm-fleet.sh pick <model-family>}" ;;
  *) echo "usage: fm-fleet.sh preflight|admiral|init|register|heartbeat|leave|queue|claim|handoff|drain|reap|route|budget|quota|models|pick|status|view" >&2; exit 1 ;;
esac
