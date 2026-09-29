#!/usr/bin/env bash
# Move a secondmate's parent binding to the primary that runs this command.
#
# Usage:
#   fm-secondmate-takeover.sh claim <secondmate-id>
#   fm-secondmate-takeover.sh restore <secondmate-id>
#   fm-secondmate-takeover.sh show <secondmate-id>
#
# WHY. A persistent secondmate can be reached by two primaries: the one that
# provisioned it over the remote route, and one running on the mate's own host.
# Only the mate's durable .fm-secondmate-parent binding decides where its replies
# land, so whichever primary last wrote that record silently owns the return
# channel while the other keeps steering and waiting. bin/fm-send.sh,
# bin/fm-spawn.sh, and the host-local leg in bin/fm-remote-secondmate-control.sh
# now refuse rather than supervise a mate whose binding names the other parent,
# and this command is the one supported way to move that binding.
#
# claim binds the mate to THIS home and preserves the binding it displaces, so
# restore hands the mate back to the other parent in one command. Both moves are
# available from either side, which is what keeps a remote mate usable from the
# captain's own machine and from its host without either primary guessing.
#
# The route comes from this home's data/secondmates.md record for <secondmate-id>,
# never from a flag: a remote record makes this the remote parent and writes
# route=remote through the host-local leg, while a local record makes this a
# parent on the mate's own filesystem and writes route=local naming this home.
# bin/fm-secondmate-parent-lib.sh owns the record bytes and the swap for both.
#
# show prints the live binding and the preserved one and changes nothing.
#
# After a claim this command reports the replies the displaced parent was still
# waiting on. Those expectations live in the displaced parent's own home, so they
# are named exactly when that home is readable here and reported as unreachable
# otherwise; either way the report says where the mate's replies land from now on.
# A claim that finds the mate already bound to this parent displaces nothing,
# keeps the preserved binding, and says so instead of reporting a displacement.
# docs/remote-secondmates.md owns the operator procedure.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REGISTRY="$DATA/secondmates.md"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

this_home() { CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P; }

resolve_route() { # <id>; sets ROUTE_REMOTE, ROUTE_HOST, ROUTE_HOME
  local id=$1
  case "$id" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $id" ;; esac
  [ -f "$REGISTRY" ] && [ ! -L "$REGISTRY" ] \
    || die "this home has no secondmate registry at $REGISTRY, so it supervises no secondmate to take over"
  secondmate_registry_line_for_id "$REGISTRY" "$id" \
    || die "this home's secondmate registry has no single usable record for $id"
  ROUTE_REMOTE=$SECONDMATE_REGISTRY_REMOTE
  ROUTE_HOST=$SECONDMATE_REGISTRY_HOST
  ROUTE_HOME=$SECONDMATE_REGISTRY_HOME
  case "$ROUTE_HOME" in /*) ;; *) die "registered secondmate home for $id is not absolute: $ROUTE_HOME" ;; esac
}

require_local_home() { # <id>
  local id=$1 marker
  [ -d "$ROUTE_HOME" ] && [ ! -L "$ROUTE_HOME" ] \
    || die "secondmate home is unavailable or unsafe: $ROUTE_HOME"
  marker="$ROUTE_HOME/.fm-secondmate-home"
  [ -f "$marker" ] && [ ! -L "$marker" ] || die "$ROUTE_HOME is not a seeded secondmate home"
  [ "$(cat "$marker")" = "$id" ] || die "$ROUTE_HOME belongs to another secondmate, not $id"
}

print_binding() { # <label> <record-path>
  local label=$1 record=$2
  if fm_secondmate_parent_record_parse "$record"; then
    case "$FM_SECONDMATE_PARENT_ROUTE" in
      local) printf '%s: a firstmate home on this secondmate'\''s own host, %s\n' "$label" "$FM_SECONDMATE_PARENT_HOME" ;;
      remote) printf '%s: a firstmate reaching it over the remote route%s\n' "$label" \
        "${FM_SECONDMATE_PARENT_HOST:+ (host alias $FM_SECONDMATE_PARENT_HOST)}" ;;
    esac
  else
    printf '%s: none recorded, or unreadable\n' "$label"
  fi
}

# Where the mate's replies land now, and which of them the displaced parent was
# still waiting on. A displaced remote parent's records live on another machine,
# so they are reported as unreachable rather than guessed at.
report_replies() { # <id> <displaced-route> <displaced-parent-home>
  local id=$1 was_route=$2 was_home=$3 lines
  printf 'replies now land in %s/state/%s.status\n' "$(this_home)" "$id"
  if lines=$(fm_pending_reply_open_summaries "$STATE" "$id"); then
    printf 'this home is still waiting on these replies, which can now arrive:\n%s\n' "$lines"
  fi
  if [ -z "$was_route" ]; then
    printf 'no previous parent was displaced by this take-over\n'
    return 0
  fi
  if [ "$was_route" != local ] || [ -z "$was_home" ]; then
    printf 'the displaced parent reached this secondmate over the remote route from another machine: any reply it is still waiting on will arrive here instead, and its own records cannot be read from this home\n'
    return 0
  fi
  if [ ! -d "$was_home" ] || [ -L "$was_home" ]; then
    printf 'the displaced parent home %s cannot be read from here: any reply it is still waiting on will arrive here instead\n' "$was_home"
    return 0
  fi
  if lines=$(fm_pending_reply_open_summaries "$was_home/state" "$id"); then
    printf 'the displaced parent %s was still waiting on these replies, which will now arrive here instead:\n%s\n' "$was_home" "$lines"
  else
    printf 'the displaced parent %s was waiting on no replies from this secondmate\n' "$was_home"
  fi
}

cmd_claim() { # <id>
  local id=$1 was_route was_home leg_out lines
  resolve_route "$id"
  if [ "$ROUTE_REMOTE" = 1 ]; then
    [ -n "$ROUTE_HOST" ] || die "registered remote secondmate $id has no host alias"
    leg_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh takeover "$id" "$ROUTE_HOST" </dev/null) \
      || die "the take-over did not complete on the secondmate's host; the reason is in the output above"
    printf '%s\n' "$leg_out"
    printf 'replies now land in the secondmate home'\''s state/parent-replies.status and are mirrored into %s/state/%s.status\n' \
      "$(this_home)" "$id"
    # The displaced parent's own expectations are on the mate's host, so say so
    # rather than implying this home can account for them.
    if printf '%s\n' "$leg_out" | grep -q '^displaced=no$'; then
      printf 'this take-over displaced no parent\n'
    elif printf '%s\n' "$leg_out" | grep -q '^prior_route=local$'; then
      printf 'the displaced parent was a firstmate on the secondmate'\''s own host: any reply it was waiting on arrives here instead, and its own records stay on that host\n'
    else
      printf 'no parent on the secondmate'\''s own host was displaced by this take-over\n'
    fi
    if lines=$(fm_pending_reply_open_summaries "$STATE" "$id"); then
      printf 'this home is still waiting on these replies, which can now arrive:\n%s\n' "$lines"
    fi
    return 0
  fi
  require_local_home "$id"
  was_route=
  was_home=
  if fm_secondmate_parent_record_parse "$(fm_secondmate_parent_path "$ROUTE_HOME")"; then
    was_route=$FM_SECONDMATE_PARENT_ROUTE
    was_home=$FM_SECONDMATE_PARENT_HOME
  fi
  fm_secondmate_parent_locked "$ROUTE_HOME" fm_secondmate_parent_rebind "$ROUTE_HOME" local "$(this_home)" \
    || die "$FM_SECONDMATE_PARENT_ERROR"
  if [ "$FM_SECONDMATE_PARENT_DISPLACED" = 0 ] && [ -n "$was_route" ]; then
    printf 'takeover: %s is already bound to this home %s; nothing was displaced\n' "$id" "$(this_home)"
    was_route=
    was_home=
  else
    printf 'takeover: %s is now bound to this home %s\n' "$id" "$(this_home)"
    print_binding 'displaced parent, preserved for restore' "$(fm_secondmate_parent_prior_path "$ROUTE_HOME")"
  fi
  report_replies "$id" "$was_route" "$was_home"
}

cmd_restore() { # <id>
  local id=$1 was_route was_home now_route leg_out
  resolve_route "$id"
  if [ "$ROUTE_REMOTE" = 1 ]; then
    leg_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh takeover-restore "$id" </dev/null) \
      || die "the restore did not complete on the secondmate's host; the reason is in the output above"
    printf '%s\n' "$leg_out"
    printf 'this home no longer receives replies from %s; they land with the parent named above\n' "$id"
    return 0
  fi
  require_local_home "$id"
  was_route=
  was_home=
  if fm_secondmate_parent_record_parse "$(fm_secondmate_parent_path "$ROUTE_HOME")"; then
    was_route=$FM_SECONDMATE_PARENT_ROUTE
    was_home=$FM_SECONDMATE_PARENT_HOME
  fi
  fm_secondmate_parent_locked "$ROUTE_HOME" fm_secondmate_parent_restore "$ROUTE_HOME" || die "$FM_SECONDMATE_PARENT_ERROR"
  fm_secondmate_parent_record_parse "$(fm_secondmate_parent_path "$ROUTE_HOME")" \
    || die "the restored parent binding is unreadable: $(fm_secondmate_parent_path "$ROUTE_HOME")"
  now_route=$FM_SECONDMATE_PARENT_ROUTE
  printf 'takeover-restore: %s is now bound to its previous parent\n' "$id"
  print_binding 'current parent' "$(fm_secondmate_parent_path "$ROUTE_HOME")"
  print_binding 'displaced parent, preserved for restore' "$(fm_secondmate_parent_prior_path "$ROUTE_HOME")"
  if [ "$now_route" = local ] && [ "$(_fm_secondmate_parent_realpath "$FM_SECONDMATE_PARENT_HOME")" = "$(this_home)" ]; then
    report_replies "$id" "$was_route" "$was_home"
  else
    printf 'this home no longer receives replies from %s; they land with the parent named above\n' "$id"
  fi
}

cmd_show() { # <id>
  local id=$1
  resolve_route "$id"
  if [ "$ROUTE_REMOTE" = 1 ]; then
    "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh parent "$id" </dev/null
    return 0
  fi
  require_local_home "$id"
  print_binding 'current parent' "$(fm_secondmate_parent_path "$ROUTE_HOME")"
  print_binding 'displaced parent, preserved for restore' "$(fm_secondmate_parent_prior_path "$ROUTE_HOME")"
}

case "${1:-}" in
  claim) shift; [ $# -eq 1 ] || usage; cmd_claim "$1" ;;
  restore) shift; [ $# -eq 1 ] || usage; cmd_restore "$1" ;;
  show) shift; [ $# -eq 1 ] || usage; cmd_show "$1" ;;
  -h|--help|'') usage ;;
  *) usage ;;
esac
