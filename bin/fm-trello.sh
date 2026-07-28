#!/usr/bin/env bash
# Trello control-plane REST wrapper. The Atlassian gateway and the Trello CLI
# cannot post comments, so the control plane talks to api.trello.com directly,
# authed with the board credentials in config/trello.env.
#
# Inert by default: with config/trello.env absent (no key/token/board) every
# subcommand is a silent no-op (exit 0), so a non-Trello user sees zero change.
# --help/usage always work regardless of config.
#
# api.trello.com is an EXTERNAL host. Every subcommand except pause/start/help
# reaches it and needs curl + jq; document that dependency where you invoke this.
#
# Subcommands:
#   comment     <card> <text>        POST /1/cards/<id>/actions/comments
#   move        <card> <lane-name>   PUT  /1/cards/<id> idList=<resolved>
#   describe    <card> <text>        PUT  /1/cards/<id> desc=<text>
#   create-card <lane-name> <name>   POST /1/cards idList=<resolved> name=<text>
#   label       <card> add|remove <label>   add/remove a label by name
#   list-cards  <lane-name>          GET  /1/lists/<id>/cards (prints id<TAB>name)
#   get-card    <card>               GET  /1/cards/<id> (prints JSON)
#   bind        <task-id> <card>     record trello_card=<card> in the task meta
#   unbind      <task-id>            drop the trello_card= binding
#   card-for    <task-id>            print the bound card id
#   pause                            create state/.trello-paused (poll hibernates)
#   start                            remove state/.trello-paused and arm the watcher
#
# Lane names resolve to list ids dynamically from the board (GET
# /1/boards/<shortlink>/lists); no id is ever hardcoded. Card ids are a shortLink
# or a full card id.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-trello-lib.sh
. "$SCRIPT_DIR/fm-trello-lib.sh"
# Resolve config up front so trello_configured reflects the real credentials for
# every code path (pause/start and the network subcommands alike).
trello_load_config

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

die() { printf '%s\n' "$*" >&2; exit 1; }

# A mutating REST call must fail loudly (non-zero + stderr) so the caller notices;
# but the whole CLI is a silent no-op when Trello mode is off.
need_configured_or_noop() {
  trello_configured || exit 0
}

need_tools() {
  command -v curl >/dev/null 2>&1 || die "trello: curl is required (api.trello.com is an external host)"
  command -v jq   >/dev/null 2>&1 || die "trello: jq is required"
}

# Resolve a lane name argument to a list id, or fail with a clear message.
resolve_lane() {
  local id
  id=$(trello_lane_id "$1") || die "trello: cannot resolve lane '$1' on the board (is the list named for it?)"
  printf '%s' "$id"
}

cmd=${1:-}
case "$cmd" in
  ''|-h|--help|help) usage; exit 0 ;;
esac
shift || true

# pause/start only touch local state; still a no-op when Trello mode is off.
case "$cmd" in
  pause)
    need_configured_or_noop
    mkdir -p "$STATE" 2>/dev/null || die "trello: cannot write state"
    : > "$STATE/.trello-paused" || die "trello: cannot create pause flag"
    echo "trello: paused - the board poll will hibernate until 'start'"
    exit 0
    ;;
  start)
    need_configured_or_noop
    rm -f "$STATE/.trello-paused" 2>/dev/null || true
    echo "trello: resumed - board poll active"
    # Arm the watcher so the poll runs even with no fleet work (Trello mode keeps
    # the watcher up, X-mode style). Best-effort; tests set FM_TRELLO_NO_ARM=1.
    if [ -z "${FM_TRELLO_NO_ARM:-}" ] && [ -x "$SCRIPT_DIR/fm-watch-arm.sh" ]; then
      # Trello is sourced first and X last so a home running both control planes
      # keeps the faster X-mode cadence.
      # shellcheck source=/dev/null
      [ -f "$FM_HOME/config/trello-mode.env" ] && . "$FM_HOME/config/trello-mode.env"
      # shellcheck source=/dev/null
      [ -f "$FM_HOME/config/x-mode.env" ] && . "$FM_HOME/config/x-mode.env"
      "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 || true
    fi
    exit 0
    ;;
esac

# Everything below reaches the network.
need_configured_or_noop
need_tools

case "$cmd" in
  comment)
    [ $# -ge 2 ] || die "usage: fm-trello.sh comment <card> <text>"
    card=$1; text=$2
    trello_safe_cardid "$card" || die "trello: unsafe card id '$card'"
    body=$(mktemp "${TMPDIR:-/tmp}/fm-trello.XXXXXX") || die "trello: mktemp failed"
    trap 'rm -f "$body"' EXIT
    code=$(trello_api POST "1/cards/$card/actions/comments" "$body" --data-urlencode "text=$text") \
      || die "trello: comment request failed (transport)"
    case "$code" in 200|201) ;; *) die "trello: comment failed (HTTP $code)" ;; esac
    trello_bump_seen "$card" || true
    echo "$card"
    ;;
  move)
    [ $# -ge 2 ] || die "usage: fm-trello.sh move <card> <lane-name>"
    card=$1; lane=$2
    trello_safe_cardid "$card" || die "trello: unsafe card id '$card'"
    list=$(resolve_lane "$lane") || exit 1
    body=$(mktemp "${TMPDIR:-/tmp}/fm-trello.XXXXXX") || die "trello: mktemp failed"
    trap 'rm -f "$body"' EXIT
    code=$(trello_api PUT "1/cards/$card" "$body" --data-urlencode "idList=$list") \
      || die "trello: move request failed (transport)"
    case "$code" in 200) ;; *) die "trello: move failed (HTTP $code)" ;; esac
    trello_bump_seen "$card" || true
    echo "$card"
    ;;
  describe)
    [ $# -ge 2 ] || die "usage: fm-trello.sh describe <card> <text>"
    card=$1; text=$2
    trello_safe_cardid "$card" || die "trello: unsafe card id '$card'"
    body=$(mktemp "${TMPDIR:-/tmp}/fm-trello.XXXXXX") || die "trello: mktemp failed"
    trap 'rm -f "$body"' EXIT
    code=$(trello_api PUT "1/cards/$card" "$body" --data-urlencode "desc=$text") \
      || die "trello: describe request failed (transport)"
    case "$code" in 200) ;; *) die "trello: describe failed (HTTP $code)" ;; esac
    trello_bump_seen "$card" || true
    echo "$card"
    ;;
  create-card)
    [ $# -ge 2 ] || die "usage: fm-trello.sh create-card <lane-name> <name>"
    lane=$1; name=$2
    list=$(resolve_lane "$lane") || exit 1
    body=$(mktemp "${TMPDIR:-/tmp}/fm-trello.XXXXXX") || die "trello: mktemp failed"
    trap 'rm -f "$body"' EXIT
    code=$(trello_api POST "1/cards" "$body" --data-urlencode "idList=$list" --data-urlencode "name=$name") \
      || die "trello: create-card request failed (transport)"
    case "$code" in 200|201) ;; *) die "trello: create-card failed (HTTP $code)" ;; esac
    newid=$(jq -r '.id // .shortLink // ""' "$body" 2>/dev/null)
    [ -n "$newid" ] || die "trello: create-card returned no id"
    trello_bump_seen "$newid" || true
    echo "$newid"
    ;;
  label)
    [ $# -ge 3 ] || die "usage: fm-trello.sh label <card> add|remove <label>"
    card=$1; action=$2; label=$3
    trello_safe_cardid "$card" || die "trello: unsafe card id '$card'"
    body=$(mktemp "${TMPDIR:-/tmp}/fm-trello.XXXXXX") || die "trello: mktemp failed"
    trap 'rm -f "$body"' EXIT
    # Resolve the label name to a board label id.
    lbcode=$(trello_api GET "1/boards/$TRELLO_BOARD/labels?fields=id,name" "$body") \
      || die "trello: label lookup failed (transport)"
    [ "$lbcode" = "200" ] || die "trello: label lookup failed (HTTP $lbcode)"
    labelid=$(jq -r --arg n "$label" '
      def norm: ascii_downcase | gsub("[^a-z0-9]"; "");
      [ .[] | select((.name | norm) == ($n | ascii_downcase | gsub("[^a-z0-9]"; ""))) ][0].id // empty' "$body" 2>/dev/null)
    [ -n "$labelid" ] || die "trello: no board label named '$label'"
    case "$action" in
      add)    code=$(trello_api POST "1/cards/$card/idLabels" "$body" --data-urlencode "value=$labelid") || die "trello: label add request failed (transport)" ;;
      remove) code=$(trello_api DELETE "1/cards/$card/idLabels/$labelid" "$body") || die "trello: label remove request failed (transport)" ;;
      *) die "usage: fm-trello.sh label <card> add|remove <label>" ;;
    esac
    case "$code" in 200|201) ;; *) die "trello: label $action failed (HTTP $code)" ;; esac
    trello_bump_seen "$card" || true
    echo "$card"
    ;;
  list-cards)
    [ $# -ge 1 ] || die "usage: fm-trello.sh list-cards <lane-name>"
    list=$(resolve_lane "$1") || exit 1
    body=$(mktemp "${TMPDIR:-/tmp}/fm-trello.XXXXXX") || die "trello: mktemp failed"
    trap 'rm -f "$body"' EXIT
    code=$(trello_api GET "1/lists/$list/cards?fields=id,name" "$body") \
      || die "trello: list-cards request failed (transport)"
    [ "$code" = "200" ] || die "trello: list-cards failed (HTTP $code)"
    jq -r '.[] | "\(.id)\t\(.name)"' "$body" 2>/dev/null || true
    ;;
  get-card)
    [ $# -ge 1 ] || die "usage: fm-trello.sh get-card <card>"
    card=$1
    trello_safe_cardid "$card" || die "trello: unsafe card id '$card'"
    body=$(mktemp "${TMPDIR:-/tmp}/fm-trello.XXXXXX") || die "trello: mktemp failed"
    trap 'rm -f "$body"' EXIT
    code=$(trello_api GET "1/cards/$card?fields=id,name,idList,desc,dateLastActivity,labels" "$body") \
      || die "trello: get-card request failed (transport)"
    [ "$code" = "200" ] || die "trello: get-card failed (HTTP $code)"
    jq '.' "$body" 2>/dev/null || cat "$body"
    ;;
  bind)
    [ $# -ge 2 ] || die "usage: fm-trello.sh bind <task-id> <card>"
    taskid=$1; card=$2
    trello_safe_cardid "$card" || die "trello: unsafe card id '$card'"
    trello_meta_bind "$taskid" "$card" || die "trello: cannot bind (no meta for '$taskid'?)"
    # Record the card's current state as seen so the binding itself never wakes.
    trello_bump_seen "$card" || true
    echo "$card"
    ;;
  unbind)
    [ $# -ge 1 ] || die "usage: fm-trello.sh unbind <task-id>"
    trello_meta_unbind "$1" || die "trello: cannot unbind '$1'"
    echo "$1"
    ;;
  card-for)
    [ $# -ge 1 ] || die "usage: fm-trello.sh card-for <task-id>"
    trello_meta_card "$1"
    ;;
  *)
    die "trello: unknown subcommand '$cmd' (try --help)"
    ;;
esac
