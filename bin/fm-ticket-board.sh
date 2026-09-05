#!/usr/bin/env bash
# fm-ticket-board.sh - build and arm the captain-facing ticket board.
#
# The board is a Lavish page at a stable path: the shipped template
# (.agents/skills/ticket-board/assets/board-template.html) plus one injected
# fm-ticket-board.v1 JSON payload, which IS the durable ticket store - there is
# no separate composed-payload step, unlike the bearings board. The captain
# creates a ticket by typing plain text into the board's own Lavish
# conversation panel (window.lavish's built-in "Send to Agent" mechanism, no
# custom form on the page); bin/fm-ticket-board-consume.sh is the receiving
# side that turns a captured message into a ticket record in the store and
# calls this script's `build` again to republish.
#
# Usage:
#   fm-ticket-board.sh init     [<store.json>]
#   fm-ticket-board.sh build    [<store.json>]
#   fm-ticket-board.sh validate [<store.json>]
#   fm-ticket-board.sh set-status <ticket-id> <backlog|in_progress|done> [<store.json>]
#   fm-ticket-board.sh path
#   fm-ticket-board.sh store
#
# init         Create an empty fm-ticket-board.v1 store at <store.json>
#              (default: the stable store path from `store`). Idempotent:
#              prints `exists: <path>` and does nothing if a store already
#              exists there, so it is always safe to run defensively.
# build        Validate the store and inject it into a fresh copy of the
#              shipped template at the stable board path. Establish or resume
#              the Lavish session on that board BEFORE arming its process-event
#              source, so a registered poll can never race a session that does
#              not exist (same ordering fm-bearings-board.sh uses). Unlike the
#              bearings board, this board carries no captain decisions, so
#              there is nothing to bind through bin/fm-captain-hold.sh - a new
#              ticket is a work item the captain is creating, not an answer to
#              a question firstmate posed. Output starts with `board: <path>`,
#              then includes lavish-axi's session output and:
#                served: <path>
#                armed: <source-id>            (first registration)
#                already-armed: <source-id>    (registration already present)
#              This board is persistent, unlike a one-shot review artifact, so
#              `build` verifies the session it gets back from `lavish-axi
#              "$board"` actually reports status "opened" rather than trusting
#              the exit code alone - verified live, `lavish-axi` exits 0 and
#              prints status "user-ended" without reopening when the captain
#              explicitly ended that session from the browser (Send & End, or
#              More -> End session), which is also what happens to the session
#              that just delivered a captain-typed ticket via Send & End. When
#              the status is not "opened", `build` deliberately retries once
#              with `lavish-axi "$board" --reopen` - safe and idempotent even
#              when the session was already live - and only then fails loudly
#              if the board still cannot be served, so a caller never sees a
#              false `served:` line against a dead session. A captain closing
#              the board without typing anything still ends that source's
#              registration with no wake, because that is genuinely not news
#              (see bin/fm-procevent-lavish.sh's `silent`/`terminal` contract);
#              this self-heals the moment anything next calls `build`, which
#              re-registers the source, but nothing calls `build` on its own
#              schedule, so a captain report of "a typed ticket never
#              appeared" with no other board activity since should prompt an
#              agent to run `build` by hand.
#              Refuses if the store is missing or malformed, and never
#              touches an existing board in that case.
# validate     Validate an fm-ticket-board.v1 store without building or
#              publishing anything: exits 0 when it satisfies the schema,
#              exits 1 with a diagnostic otherwise. The single owner of that
#              schema check - `build` and `set-status` use it internally, and
#              bin/fm-ticket-board-consume.sh reuses this subcommand rather
#              than reimplementing it before publishing a staged store.
# set-status   Convenience for the documented "firstmate updates ticket status
#              by re-running the build script with an updated JSON store"
#              operator flow: set one ticket's status in place, then rebuild.
#              Refuses on an unknown ticket id or an unknown status value.
# path         Print the stable board path for this home.
# store        Print the stable store path for this home.
#
# Validation is fail-closed: the store must be valid JSON with
# schema=fm-ticket-board.v1, and every ticket must carry a slug id, a
# non-empty title, a status in {backlog, in_progress, done}, and a non-empty
# created timestamp. Anything else refuses before the existing board is
# touched.
#
# The board path is stable - $FM_HOME/.lavish/ticket-board.html - so a
# re-invocation rebuilds the same file in place, which keeps the same Lavish
# session URL and the same canonical process-event source id. The store path
# is stable at $FM_HOME/data/tickets.json (or $FM_DATA_OVERRIDE/tickets.json),
# the durable record bin/fm-ticket-board-consume.sh appends to. Injection
# escapes every `<` in the compact JSON as the < string escape, so a
# ticket body containing "</script>" can never terminate the data block early.
#
# FM_TICKET_BOARD_TEMPLATE overrides the shipped template path (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

TEMPLATE="${FM_TICKET_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/ticket-board/assets/board-template.html}"
PLACEHOLDER='__FM_TICKET_BOARD_DATA__'
BOARD_SCHEMA=fm-ticket-board.v1
STATUSES='backlog in_progress done'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-ticket-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/ticket-board.html\n' "$FM_HOME"; }
store_path() { printf '%s/tickets.json\n' "$DATA"; }

# Read the `status:` field of an `lavish-axi <artifact>` invocation's own
# leading `session:` block. Same shape bin/fm-procevent-lavish.sh reads from a
# captured poll RESULT, but this reads the interactive open/reopen command's
# own stdout instead, so it stays local rather than reusing that adapter's
# private helper across an unrelated data flow.
session_status() {  # <lavish-axi output>
  awk '
    $0 == "session:" { in_s=1; next }
    in_s && $0 !~ /^[[:space:]]/ { exit }
    in_s && $0 ~ /^[[:space:]]+status:[[:space:]]*[A-Za-z_-]+[[:space:]]*$/ {
      sub(/^[[:space:]]+status:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' <<<"$1"
}

is_status() {
  local s
  for s in $STATUSES; do
    [ "$s" = "$1" ] && return 0
  done
  return 1
}

validate_store() {  # <store.json>
  jq -e --arg schema "$BOARD_SCHEMA" --arg statuses "$STATUSES" '
    def nonempty_string: type == "string" and length > 0;
    def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
    def ticket_item:
      type == "object"
      and (.id | slug(128))
      and (.title | nonempty_string)
      and (.status as $s | ($statuses | split(" ")) | index($s) != null)
      and (.created | nonempty_string)
      and ((has("body") | not) or (.body | type == "string"));
    type == "object"
    and (.schema == $schema)
    and (.generated | nonempty_string)
    and (.tickets | type == "array")
    and ([.tickets[] | ticket_item] | all)
    and ([.tickets[].id] | length == (. | unique | length))
  ' "$1" >/dev/null
}

command_init() {
  local store=${1:-$(store_path)}
  [ "$#" -le 1 ] || { usage >&2; exit 2; }
  if [ -e "$store" ]; then
    printf 'exists: %s\n' "$store"
    return 0
  fi
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  (umask 077; mkdir -p "${store%/*}") || fail "cannot create ${store%/*}"
  local tmp
  tmp=$(umask 077; mktemp "${store%/*}/.tickets.XXXXXX") || fail "cannot stage the store"
  jq -n --arg schema "$BOARD_SCHEMA" --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema: $schema, generated: $generated, tickets: []}' > "$tmp" \
    || { rm -f -- "$tmp"; fail "cannot compose an empty store"; }
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$store"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the store"
  fi
  printf 'created: %s\n' "$store"
}

command_build() {
  local data=${1:-$(store_path)} board json tmp sid extracted
  [ "$#" -le 1 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "ticket store does not exist: $data (run: $0 init)"
  jq empty "$data" 2>/dev/null || fail "ticket store is not valid JSON: $data"
  validate_store "$data" || fail "ticket store does not satisfy $BOARD_SCHEMA: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "board template does not carry exactly one data slot: $TEMPLATE"

  json=$(jq -c . "$data") || fail "cannot compact the ticket store"
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}

  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || fail "cannot create ${board%/*}"
  tmp=$(umask 077; mktemp "${board%/*}/.board.XXXXXX") || fail "cannot stage the board"
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{BOARD_JSON}/" "$TEMPLATE" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot inject the board data"
  fi
  if grep -qxF "$PLACEHOLDER" "$tmp"; then
    rm -f -- "$tmp"
    fail "the board data slot survived injection"
  fi
  # Round-trip the injected payload back out of the built page, so a board that
  # would fail to parse in the browser fails here instead.
  extracted=$(sed -n '/<script id="ticket-board-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "the built board does not carry a readable $BOARD_SCHEMA payload"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the board"
  fi
  printf 'board: %s\n' "$board"

  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  local session_out status
  session_out=$(lavish-axi "$board") || fail "cannot establish the board Lavish session"
  status=$(session_status "$session_out")
  if [ "$status" != opened ]; then
    # A persistent captain board must keep accepting tickets even after the
    # captain ends the session from the browser - verified live, `lavish-axi`
    # exits 0 and reports status "user-ended" without reopening unless told
    # to. Reopen deliberately here rather than trusting that exit code and
    # publishing a false `served:` line against a dead session.
    session_out=$(lavish-axi "$board" --reopen) || fail "cannot reopen the board Lavish session"
    status=$(session_status "$session_out")
  fi
  [ "$status" = opened ] || fail "lavish-axi did not report an open board session (status: ${status:-unknown})"
  printf '%s\n' "$session_out"
  printf 'served: %s\n' "$board"

  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board") \
    || fail "cannot derive the board source id"

  if "$SCRIPT_DIR/fm-procevent.sh" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid"; then
    printf 'already-armed: %s\n' "$sid"
  else
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm the board as a process-event source"
    printf 'armed: %s\n' "$sid"
  fi
}

command_validate() {
  local data=${1:-$(store_path)}
  [ "$#" -le 1 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "ticket store does not exist: $data (run: $0 init)"
  jq empty "$data" 2>/dev/null || fail "ticket store is not valid JSON: $data"
  validate_store "$data" || fail "ticket store does not satisfy $BOARD_SCHEMA: $data"
  printf 'valid: %s\n' "$data"
}

command_set_status() {
  local id=${1-} status=${2-} data=${3:-$(store_path)} tmp
  [ -n "$id" ] && [ -n "$status" ] || { usage >&2; exit 2; }
  [ "$#" -le 3 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "ticket store does not exist: $data (run: $0 init)"
  jq empty "$data" 2>/dev/null || fail "ticket store is not valid JSON: $data"
  validate_store "$data" || fail "ticket store does not satisfy $BOARD_SCHEMA: $data"
  is_status "$status" || fail "unknown status: $status (expected one of: $STATUSES)"
  jq -e --arg id "$id" 'any(.tickets[]; .id == $id)' "$data" >/dev/null \
    || fail "no ticket with id: $id"

  tmp=$(umask 077; mktemp "${data%/*}/.tickets.XXXXXX") || fail "cannot stage the store"
  jq --arg id "$id" --arg status "$status" \
    '.tickets |= map(if .id == $id then .status = $status else . end)' \
    "$data" > "$tmp" || { rm -f -- "$tmp"; fail "cannot update the ticket status"; }
  validate_store "$tmp" || { rm -f -- "$tmp"; fail "the updated store no longer satisfies $BOARD_SCHEMA"; }
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$data"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the updated store"
  fi
  printf 'updated: %s -> %s\n' "$id" "$status"
  command_build "$data"
}

case "${1-}" in
  init) shift; command_init "$@" ;;
  build) shift; command_build "$@" ;;
  validate) shift; command_validate "$@" ;;
  set-status) shift; command_set_status "$@" ;;
  path) board_path ;;
  store) store_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
