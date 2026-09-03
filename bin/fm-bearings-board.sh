#!/usr/bin/env bash
# fm-bearings-board.sh - build and arm the /bearings lavish fleet board.
#
# The board is the captain-facing interactive surface of /bearings lavish: the
# shipped template (.agents/skills/bearings/assets/board-template.html) plus one
# injected fm-bearings-board.v1 JSON payload. This script owns the mechanics so
# the invoking agent's per-run work stays "compose the JSON, run build" - the
# agent never authors board UI at invocation time.
#
# Usage:
#   fm-bearings-board.sh build <data.json>
#   fm-bearings-board.sh path
#
# build      Validate the payload and inject it into a fresh copy of the shipped
#            template at the stable board path. Establish or resume the Lavish
#            session on that board BEFORE binding and arming its answer source,
#            so a registered poll can never race a session that does not exist.
#            Bind to the keyed-answer intake (bin/fm-captain-hold.sh) ALWAYS
#            precedes arm, so the board can never produce an answer that has
#            nowhere to go (captain-hold-lifecycle's ordering rule, enforced
#            here rather than left to agent memory). Output starts with
#            `board: <path>`, then includes lavish-axi's session output and
#            the remaining status:
#              served: <path>
#              bound: <source-id>
#              armed: <source-id>            (first registration)
#              already-armed: <source-id>    (registration already present)
# path       Print the stable board path for this home.
#
# Validation is fail-closed: the payload must be valid JSON with
# schema=fm-bearings-board.v1 and every renderer-consumed field must satisfy
# the fm-bearings-board.v1 types and item invariants below. Every fleet row and
# Captain's Call item explicitly carries `repo`; the composer fills it from the
# snapshot and task records wherever known, and uses null or an empty string
# only as the deliberate genuinely-no-repo marker. In that exceptional case
# the template may display the routing id. Anything else refuses before the
# existing board is touched.
#
# The board path is stable - $FM_HOME/.lavish/bearings-board.html - so a
# re-invocation rebuilds the same file in place, which keeps the same Lavish
# session URL and the same canonical process-event source id. Injection escapes
# every `<` in the compact JSON as the \u003c string escape, so a payload string
# containing "</script>" can never terminate the data block early.
#
# FM_BEARINGS_BOARD_TEMPLATE overrides the shipped template path (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATUS_PAGE_SCRIPT="${FM_STATUS_PAGE_SCRIPT:-$SCRIPT_DIR/fm-status-page.sh}"

TEMPLATE="${FM_BEARINGS_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/board-template.html}"
PLACEHOLDER='__FM_BEARINGS_BOARD_DATA__'
BOARD_SCHEMA=fm-bearings-board.v1

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-bearings-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/bearings-board.html\n' "$FM_HOME"; }

publish_journal_path() { printf '%s/.bearings-status-page-publish.json\n' "$DATA"; }

recover_interrupted_publish() {
  local journal board page board_backup page_backup board_had page_had page_tmp restore_board restore_page
  journal=$(publish_journal_path)
  [ -e "$journal" ] || return 0
  [ -f "$journal" ] && [ ! -L "$journal" ] || fail "interrupted publish journal is invalid"
  board=$(jq -r '.board // empty' "$journal")
  page=$(jq -r '.page // empty' "$journal")
  board_backup=$(jq -r '.board_backup // empty' "$journal")
  page_backup=$(jq -r '.page_backup // empty' "$journal")
  page_tmp=$(jq -r '.page_tmp // empty' "$journal")
  board_had=$(jq -r '.board_had // empty' "$journal")
  page_had=$(jq -r '.page_had // empty' "$journal")
  if ! { [ "$board" = "$(board_path)" ] && [ "$page" = "$DATA/status-page.html" ] \
    && [ "$board_backup" = "${board%/*}/.bearings-status-page.board-backup" ] \
    && [ "$page_backup" = "$DATA/.bearings-status-page.page-backup" ] \
    && [ "$page_tmp" = "$DATA/.bearings-status-page.staged" ] \
    && { [ "$board_had" = true ] || [ "$board_had" = false ]; } \
    && { [ "$page_had" = true ] || [ "$page_had" = false ]; }; }; then
    fail "interrupted publish journal is malformed"
  fi
  if [ "$board_had" = true ]; then
    [ -f "$board_backup" ] || fail "cannot restore the board after an interrupted publish"
  fi
  if [ "$page_had" = true ]; then
    [ -f "$page_backup" ] || fail "cannot restore the static status page after an interrupted publish"
  fi
  if [ "$board_had" = true ]; then
    restore_board=$(umask 077; mktemp "${board%/*}/.bearings-status-page.restore.XXXXXX") \
      || fail "cannot stage board recovery"
    cp "$board_backup" "$restore_board" || { rm -f -- "$restore_board"; fail "cannot stage board recovery"; }
  fi
  if [ "$page_had" = true ]; then
    restore_page=$(umask 077; mktemp "$DATA/.bearings-status-page.restore.XXXXXX") \
      || { rm -f -- "${restore_board:-}"; fail "cannot stage static status page recovery"; }
    cp "$page_backup" "$restore_page" \
      || { rm -f -- "${restore_board:-}" "$restore_page"; fail "cannot stage static status page recovery"; }
  fi
  if [ "$board_had" = true ]; then
    mv -f -- "$restore_board" "$board" || fail "cannot restore the board after an interrupted publish"
  else
    rm -f -- "$board"
  fi
  if [ "$page_had" = true ]; then
    mv -f -- "$restore_page" "$page" || fail "cannot restore the static status page after an interrupted publish"
  else
    rm -f -- "$page"
  fi
  rm -f -- "$page_tmp" "$journal" "$board_backup" "$page_backup"
}

validate_payload() {  # <data.json>
  jq -e --arg schema "$BOARD_SCHEMA" '
    def nonempty_string: type == "string" and length > 0;
    def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
    def repo_marker: has("repo") and (.repo == null or (.repo | type == "string"));
    def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
    def optional_https_url($name):
      (has($name) | not)
      or (.[$name]
        | type == "string"
          and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$"));
    def call_item:
      type == "object"
      and (.key | slug(128))
      and (.type == "decision" or .type == "merge" or .type == "credential")
      and repo_marker
      and (.title | nonempty_string)
      and (.options | type == "array")
      and ((.options | length) > 0 or .allow_freeform == true)
      and ([.options[]
        | type == "object"
          and (.value | slug(128))
          and (.label | nonempty_string)
          and optional_string("hint")] | all)
      and (optional_string("about"))
      and (optional_string("decide"))
      and (optional_string("detail"))
      and (optional_https_url("pr_url"))
      and (optional_string("freeform_hint"))
      and ((has("close") | not) or (.close == "done" or .close == "release"))
      and ((has("allow_freeform") | not) or (.allow_freeform | type == "boolean"))
      and ((has("recommend_value") | not)
        or ((.recommend_value | slug(128))
          and (.recommend_value as $recommend | [.options[].value] | index($recommend) != null)))
      and (if .type == "merge" then (.risk | nonempty_string) else true end);
    def underway_item:
      type == "object" and repo_marker and (.id | nonempty_string)
      and (.state | nonempty_string) and (.doing | nonempty_string) and (.kind | nonempty_string);
    def landed_item:
      type == "object" and repo_marker and (.id | nonempty_string)
      and (.what | nonempty_string) and (.owner | nonempty_string)
      and optional_https_url("pr_url");
    def charted_item:
      type == "object" and repo_marker and (.id | slug(128))
      and (.title | nonempty_string) and (.reason | type == "string")
      and (.dispatchable | type == "boolean")
      and ((has("kind") | not) or (.kind == "queued" or .kind == "warning"))
      and (if .kind == "warning" then .dispatchable == false else true end);
    type == "object"
    and (.schema == $schema)
    and (.home | nonempty_string)
    and (.generated | nonempty_string)
    and (.prs_live | type == "boolean")
    and (.captains_call | type == "array")
    and (.underway | type == "array")
    and (.landed | type == "array")
    and (.charted | type == "array")
    and ((has("charted_more") | not)
      or ((.charted_more | type == "number") and (.charted_more >= 0) and (.charted_more | floor == .)))
    and ((has("charted_warning_more") | not)
      or ((.charted_warning_more | type == "number") and (.charted_warning_more >= 0) and (.charted_warning_more | floor == .)))
    and ([.captains_call[] | call_item] | all)
    and ([.underway[] | underway_item] | all)
    and ([.landed[] | landed_item] | all)
    and ([.charted[] | charted_item] | all)
  ' "$1" >/dev/null
}

command_build() {
  local data=${1-} board json tmp sid extracted page page_tmp board_backup page_backup journal journal_tmp board_had=false page_had=false
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  recover_interrupted_publish
  [ -f "$data" ] || fail "board data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "board data is not valid JSON: $data"
  validate_payload "$data" || fail "board data does not satisfy $BOARD_SCHEMA: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "board template does not carry exactly one data slot: $TEMPLATE"

  json=$(jq -c . "$data") || fail "cannot compact the board data"
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
  extracted=$(sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "the built board does not carry a readable $BOARD_SCHEMA payload"
  fi
  (umask 077; mkdir -p "$DATA") || { rm -f -- "$tmp"; fail "cannot create $DATA"; }
  page="$DATA/status-page.html"
  page_tmp="$DATA/.bearings-status-page.staged"
  rm -f -- "$page_tmp"
  (umask 077; : > "$page_tmp") \
    || { rm -f -- "$tmp"; fail "cannot stage the static status page"; }
  if ! FM_STATUS_PAGE_OUTPUT="$page_tmp" "$STATUS_PAGE_SCRIPT" >/dev/null; then
    rm -f -- "$tmp" "$page_tmp"
    fail "cannot refresh the static status page"
  fi

  board_backup="${board%/*}/.bearings-status-page.board-backup"
  page_backup="$DATA/.bearings-status-page.page-backup"
  rm -f -- "$board_backup" "$page_backup"
  if [ -e "$board" ]; then
    cp "$board" "$board_backup" || { rm -f -- "$tmp" "$page_tmp" "$board_backup" "$page_backup"; fail "cannot back up the board"; }
    board_had=true
  fi
  if [ -e "$page" ]; then
    cp "$page" "$page_backup" || { rm -f -- "$tmp" "$page_tmp" "$board_backup" "$page_backup"; fail "cannot back up the static status page"; }
    page_had=true
  fi
  journal=$(publish_journal_path)
  journal_tmp=$(umask 077; mktemp "$DATA/.bearings-status-page.journal.XXXXXX") \
    || { rm -f -- "$tmp" "$page_tmp" "$board_backup" "$page_backup"; fail "cannot stage the publish journal"; }
  jq -n --arg board "$board" --arg page "$page" --arg board_backup "$board_backup" \
    --arg page_backup "$page_backup" --arg page_tmp "$page_tmp" \
    --argjson board_had "$board_had" --argjson page_had "$page_had" \
    '{board:$board,page:$page,board_backup:$board_backup,page_backup:$page_backup,page_tmp:$page_tmp,board_had:$board_had,page_had:$page_had}' \
    > "$journal_tmp" || { rm -f -- "$tmp" "$page_tmp" "$board_backup" "$page_backup" "$journal_tmp"; fail "cannot write the publish journal"; }
  mv -f -- "$journal_tmp" "$journal" || { rm -f -- "$tmp" "$page_tmp" "$board_backup" "$page_backup" "$journal_tmp"; fail "cannot publish the transaction journal"; }
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    recover_interrupted_publish
    fail "cannot publish the board"
  fi
  if [ "${FM_BEARINGS_BOARD_TEST_ABORT_AFTER_BOARD_PUBLISH:-0}" = 1 ]; then
    exit 93
  fi
  if ! mv -f -- "$page_tmp" "$page"; then
    recover_interrupted_publish
    fail "cannot publish the static status page"
  fi
  rm -f -- "$journal" "$board_backup" "$page_backup"
  printf 'board: %s\n' "$board"

  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  lavish-axi "$board" || fail "cannot establish the board Lavish session"
  printf 'served: %s\n' "$board"

  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board") \
    || fail "cannot derive the board source id"
  "$SCRIPT_DIR/fm-captain-hold.sh" bind "$sid" --any-origin >/dev/null \
    || fail "cannot bind the board source to the any-origin intake"
  printf 'bound: %s (any-origin)\n' "$sid"

  if "$SCRIPT_DIR/fm-procevent.sh" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid"; then
    printf 'already-armed: %s\n' "$sid"
  else
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm the board as a process-event source"
    printf 'armed: %s\n' "$sid"
  fi
}

case "${1-}" in
  build) shift; command_build "$@" ;;
  path) board_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
