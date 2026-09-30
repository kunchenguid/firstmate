#!/usr/bin/env bash
# fm-herdr-pins.sh - keep the agents the captain talks to pinned in Herdr's
# sidebar Agents panel.
#
# Usage:
#   fm-herdr-pins.sh sync [<id>]
#   fm-herdr-pins.sh clear <id>
#   fm-herdr-pins.sh tag <session> <pane> <rank> <host> <label>
#   fm-herdr-pins.sh untag <session> <pane>
#   fm-herdr-pins.sh view <session>
#
# Herdr has no native pin. Each pinned agent's pane instead carries three
# display tokens reported under source `firstmate-pins` (pin_rank, pin_label,
# pin_host), and every Herdr session that hosts one carries a static agent view
# (source `firstmate:pins`, label "Pinned") that shows only panes with a
# pin_rank token, sorted by it. Herdr keeps neither across a server restart,
# and a relaunch can land an agent in a new pane, so Firstmate re-applies both
# at secondmate launch and relaunch, at primary session start, and on the
# secondmate liveness tick. docs/configuration.md "Pinned Herdr agents" owns
# the config/pinned-agents schema and the operator-facing behavior.
#
# sync applies every config entry this home owns, or only <id>'s, and names
# each rejected config line on stderr. It resolves each agent's CURRENT pane
# from its recorded endpoint, never from a stored pane id: `self` is this
# firstmate's own supervisor pane (bin/fm-supervisor-target-lib.sh), a local
# secondmate is its validated state/<id>.meta endpoint, and a remote secondmate
# is tagged on its own host through `fm-remote-secondmate-control.sh pin`,
# which reads that host's endpoint record and installs the view on its
# fm-remote session. A remote host that does not answer (ssh exit 255 or the
# per-call bound) is skipped for the rest of that pass, so one sleeping machine
# costs one bounded call rather than one per agent it hosts.
#
# clear removes <id>'s tokens when the config pins <id>; secondmate retirement
# calls it.
#
# tag, untag, and view are the host-local primitives: they act on one exact
# pane or session of the local Herdr server and exit non-zero when Herdr does
# not confirm. bin/fm-remote-secondmate-control.sh's pin and unpin verbs use
# them on a remote secondmate's host.
#
# Best effort by contract: sync and clear always exit 0, print one line per
# entry (`pinned`, `cleared`, or `skipped <id>: <reason>`), and are silent
# no-ops without config/pinned-agents. An agent not on Herdr, or a missing or
# unreachable Herdr (or python3, for the view), is skipped. Callers discard
# the output and never fail a spawn, relaunch, retirement, or liveness pass on
# it.
#
# Environment:
#   FM_HERDR_PINS_REMOTE_TIMEOUT seconds per remote pin/unpin call (default 45)
#   FM_HERDR_PINS_VIEW_SETTER    view transport (default
#                                bin/backends/herdr-agent-view.py)
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PINS_CONFIG="$CONFIG/pinned-agents"
PIN_SOURCE=firstmate-pins

usage() { sed -n '5,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

CMD=${1:-}
case "$CMD" in
  sync|clear)
    # The off path costs one file test and sources nothing.
    [ -f "$PINS_CONFIG" ] || exit 0
    ;;
  tag|untag|view) ;;
  *) usage ;;
esac

CALL_TIMEOUT=10
REMOTE_TIMEOUT=${FM_HERDR_PINS_REMOTE_TIMEOUT:-}
case "$REMOTE_TIMEOUT" in ''|*[!0-9]*|0) REMOTE_TIMEOUT=45 ;; esac
VIEW_SETTER=${FM_HERDR_PINS_VIEW_SETTER:-$SCRIPT_DIR/backends/herdr-agent-view.py}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

valid_rank() { case "$1" in [0-9][0-9]) [ "$1" != 00 ] ;; *) return 1 ;; esac; }
valid_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
valid_host() {
  case "$1" in ''|*[!A-Za-z0-9._@-]*) return 1 ;; esac
  [ "${#1}" -le 32 ]
}
valid_label() {
  case "$1" in ''|*[[:cntrl:]]*) return 1 ;; esac
  [ "${#1}" -le 48 ]
}

# --- config ------------------------------------------------------------------

# pins_parse: accepted entries as `<rank>\t<id>\t<host>\t<label>` on stdout,
# one rejection per line on stderr. Every entry names its host explicitly. A
# later line for an id already accepted is rejected rather than silently
# winning.
pins_parse() {
  local line n=0 rank id host label seen='|'
  [ -f "$PINS_CONFIG" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    read -r rank id host label <<< "$line"
    case "$rank" in ''|'#'*) continue ;; esac
    if [ -z "$label" ] || [ "$host" = - ]; then
      printf 'pinned-agents line %s: missing host or label; expected <rank> <id> <host> <label>\n' "$n" >&2
      continue
    fi
    case "$rank" in
      [0-9]|[0-9][0-9]) rank=$(printf '%02d' "$((10#$rank))") ;;
      *) rank=bad ;;
    esac
    if ! valid_rank "$rank" || ! valid_id "$id" || ! valid_host "$host" || ! valid_label "$label"; then
      printf 'pinned-agents line %s: expected <rank 1-99> <self|secondmate-id> <host> <label>\n' "$n" >&2
      continue
    fi
    case "$seen" in
      *"|$id|"*)
        printf 'pinned-agents line %s: %s is already pinned by an earlier line\n' "$n" "$id" >&2
        continue
        ;;
    esac
    seen="$seen$id|"
    printf '%s\t%s\t%s\t%s\n' "$rank" "$id" "$host" "$label"
  done < "$PINS_CONFIG"
}

# --- host-local Herdr primitives ---------------------------------------------

pins_herdr() {  # <session> <herdr-args...>
  local session=$1
  shift
  command -v herdr >/dev/null 2>&1 || return 127
  fm_backend_source herdr >/dev/null 2>&1 || return 1
  fm_backend_herdr_client_select "$session" >/dev/null 2>&1
  HERDR_SESSION="$session" fm_run_timed "$CALL_TIMEOUT" "$(fm_backend_herdr_bin)" "$@" --session "$session" </dev/null >/dev/null 2>&1
}

pins_tag() {  # <session> <pane> <rank> <host> <label>
  pins_herdr "$1" pane report-metadata "$2" --source "$PIN_SOURCE" \
    --token "pin_rank=$3" --token "pin_label=$5" --token "pin_host=$4"
}

pins_untag() {  # <session> <pane>
  pins_herdr "$1" pane report-metadata "$2" --source "$PIN_SOURCE" \
    --clear-token pin_rank --clear-token pin_label --clear-token pin_host
}

pins_view() {  # <session>
  local session=$1 sock
  command -v herdr >/dev/null 2>&1 || return 127
  [ -n "${FM_HERDR_PINS_VIEW_SETTER:-}" ] || command -v python3 >/dev/null 2>&1 || return 127
  fm_backend_source herdr >/dev/null 2>&1 || return 1
  sock=$(fm_backend_herdr_socket_path "$session")
  [ -n "$sock" ] || return 1
  fm_run_timed "$CALL_TIMEOUT" "$VIEW_SETTER" "$sock" </dev/null >/dev/null 2>&1
}

# --- endpoint resolution -----------------------------------------------------

# pins_resolve <id>: sets PIN_KIND (local|remote|skip), PIN_SESSION and
# PIN_PANE for a local pane, PIN_REMOTE_HOST for a remote secondmate, and
# PIN_REASON on skip. Every value is read from the endpoint's current record,
# so a relaunch into a new pane is followed.
pins_resolve() {
  local id=$1 meta backend target
  PIN_KIND=skip PIN_SESSION='' PIN_PANE='' PIN_REMOTE_HOST='' PIN_REASON=''
  if [ "$id" = self ]; then
    backend=$(discover_supervisor_backend) || { PIN_REASON="no supervisor pane detected"; return 0; }
    [ "$backend" = herdr ] || { PIN_REASON="supervisor pane is on $backend, not herdr"; return 0; }
    target=$(discover_supervisor_target) || { PIN_REASON="no supervisor pane detected"; return 0; }
  else
    meta="$STATE/$id.meta"
    [ -f "$meta" ] && [ ! -L "$meta" ] || { PIN_REASON="no endpoint record"; return 0; }
    [ "$(fm_meta_get "$meta" kind)" = secondmate ] || { PIN_REASON="not a secondmate"; return 0; }
    PIN_REMOTE_HOST=$(fm_meta_get "$meta" remote_host)
    if [ -n "$PIN_REMOTE_HOST" ]; then
      PIN_KIND=remote
      return 0
    fi
    fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1 \
      || { PIN_REASON="endpoint record does not validate"; return 0; }
    [ "$FM_BACKEND_VALIDATED_BACKEND" = herdr ] \
      || { PIN_REASON="endpoint is on $FM_BACKEND_VALIDATED_BACKEND, not herdr"; return 0; }
    target=$FM_BACKEND_VALIDATED_TARGET
  fi
  PIN_SESSION=${target%%:*}
  PIN_PANE=${target#*:}
  if [ -z "$PIN_SESSION" ] || [ -z "$PIN_PANE" ] || [ "$PIN_PANE" = "$target" ]; then
    PIN_REASON="endpoint target '$target' is not a herdr pane"
    return 0
  fi
  PIN_KIND=local
}

pins_remote() {  # <id> <control-verb-args...>
  local id=$1
  shift
  fm_run_timed "$REMOTE_TIMEOUT" "$SCRIPT_DIR/fm-on.sh" "$id" \
    fm-remote-secondmate-control.sh "$@" </dev/null >/dev/null 2>&1
}

# --- verbs -------------------------------------------------------------------

cmd_sync() {
  local only=${1:-} entries rank id host label rc views='|' down='|'
  if [ -n "$only" ]; then
    valid_id "$only" || usage
  fi
  entries=$(pins_parse)
  while IFS=$'\t' read -r rank id host label; do
    [ -n "$id" ] || continue
    [ -z "$only" ] || [ "$id" = "$only" ] || continue
    pins_resolve "$id"
    case "$PIN_KIND" in
      local)
        if pins_tag "$PIN_SESSION" "$PIN_PANE" "$rank" "$host" "$label"; then
          printf 'pinned %s %s:%s\n' "$id" "$PIN_SESSION" "$PIN_PANE"
        else
          printf 'skipped %s: herdr did not confirm the tokens\n' "$id"
        fi
        case "$views" in
          *"|$PIN_SESSION|"*) ;;
          *)
            pins_view "$PIN_SESSION" || printf 'skipped view %s: herdr did not confirm the view\n' "$PIN_SESSION"
            views="$views$PIN_SESSION|"
            ;;
        esac
        ;;
      remote)
        case "$down" in
          *"|$PIN_REMOTE_HOST|"*)
            printf 'skipped %s: host %s unreachable this pass\n' "$id" "$PIN_REMOTE_HOST"
            continue
            ;;
        esac
        if pins_remote "$id" pin "$id" "$rank" "$host" "$label"; then rc=0; else rc=$?; fi
        if [ "$rc" -eq 0 ]; then
          printf 'pinned %s remote\n' "$id"
        elif [ "$rc" -eq 255 ] || fm_timed_out "$rc"; then
          printf 'skipped %s: host %s unreachable this pass\n' "$id" "$PIN_REMOTE_HOST"
          down="$down$PIN_REMOTE_HOST|"
        else
          printf 'skipped %s: remote pin did not complete\n' "$id"
        fi
        ;;
      *) printf 'skipped %s: %s\n' "$id" "$PIN_REASON" ;;
    esac
  done <<< "$entries"
}

cmd_clear() {
  local id=$1
  valid_id "$id" || usage
  pins_parse 2>/dev/null | cut -f2 | grep -Fx -- "$id" >/dev/null || return 0
  pins_resolve "$id"
  case "$PIN_KIND" in
    local)
      pins_untag "$PIN_SESSION" "$PIN_PANE" \
        || { printf 'skipped %s: herdr did not confirm the clear\n' "$id"; return 0; }
      ;;
    remote)
      pins_remote "$id" unpin "$id" \
        || { printf 'skipped %s: remote unpin did not complete\n' "$id"; return 0; }
      ;;
    *) printf 'skipped %s: %s\n' "$id" "$PIN_REASON"; return 0 ;;
  esac
  printf 'cleared %s\n' "$id"
}

case "$CMD" in
  sync) [ "$#" -le 2 ] || usage; cmd_sync "${2:-}"; exit 0 ;;
  clear) [ "$#" -eq 2 ] || usage; cmd_clear "$2"; exit 0 ;;
  tag)
    [ "$#" -eq 6 ] || usage
    if ! valid_id "$2" || [ -z "$3" ] || ! valid_rank "$4" || ! valid_host "$5" || ! valid_label "$6"; then
      usage
    fi
    pins_tag "$2" "$3" "$4" "$5" "$6"
    ;;
  untag)
    [ "$#" -eq 3 ] || usage
    if ! valid_id "$2" || [ -z "$3" ]; then usage; fi
    pins_untag "$2" "$3"
    ;;
  view)
    [ "$#" -eq 2 ] || usage
    valid_id "$2" || usage
    pins_view "$2"
    ;;
esac
