#!/usr/bin/env bash
# Shared config, REST, lane, marker, and meta-binding helpers for the Trello
# control plane (fm-trello.sh and fm-trello-poll.sh).
#
# The Trello control plane is opt-in: a user drops TRELLO_API_KEY, TRELLO_TOKEN,
# and TRELLO_BOARD_SHORTLINK into the firstmate home's gitignored
# config/trello.env. Until then every entry point here is a hard no-op, so a
# non-Trello user sees zero behavior change - exactly like X mode's .env gate.
#
# api.trello.com is an EXTERNAL host. Nothing here reaches it unless the config
# is present; callers that need the network document that dependency.
#
# This file is sourced, never executed. It defines:
#   trello_env_get <key> <file>        - read one KEY=VALUE from a .env-style file
#   trello_load_config                 - resolve TRELLO_KEY/TRELLO_TOKEN/
#                                        TRELLO_BOARD/TRELLO_API (env wins over file)
#   trello_configured                  - 0 when key+token+board are all set
#   trello_curl <method> <url> <out> [curl-args...]
#                                      - authed request; key/token stay OUT of argv
#                                        via a 0600 -K config file; prints HTTP code
#   trello_api <method> <path> <out> [curl-args...]
#                                      - trello_curl against $TRELLO_API/<path>
#   trello_lists_json                  - board lists JSON (memoized per process)
#   trello_lane_id <lane-name>         - resolve a lane name to its list id
#   trello_lane_name_for <list-id>     - resolve a list id back to its lane name
#   trello_safe_cardid <id>            - 0 when id is a safe path slug
#   trello_marker_path <cardid>        - state/.trello-seen-<cardid>
#   trello_marker_read <cardid>        - print date/list/go/comment state or nothing
#   trello_marker_write <cardid> <date> <list-id> [go-state] [comment-count]
#   trello_bump_seen <cardid>          - fetch the card and record its current marker
#   trello_meta_bind <taskid> <cardid> - write trello_card=<cardid> into the task meta
#   trello_meta_unbind <taskid>        - remove the trello_card= line
#   trello_meta_card <taskid>          - print the bound card id, if any
# Callers must have FM_HOME set (or rely on FM_ROOT) before calling
# trello_load_config; STATE is resolved from the same overrides bootstrap uses.

# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent.
trello_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}   # strip leading whitespace
  val=${val%"${val##*[![:space:]]}"}   # strip trailing whitespace (incl. CR)
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

# Resolve the control-plane settings into TRELLO_KEY, TRELLO_TOKEN, TRELLO_BOARD,
# and TRELLO_API. An explicit environment variable always wins over the config
# file; the API base defaults to the production host so a normal user configures
# only the three board credentials. FM_TRELLO_ENV_FILE can point direct client
# calls at another config file; bootstrap activation still keys off
# $FM_HOME/config/trello.env.
trello_load_config() {
  local env_file="${FM_TRELLO_ENV_FILE:-${FM_HOME:-$FM_ROOT}/config/trello.env}"
  if [ -n "${TRELLO_API_KEY+x}" ]; then TRELLO_KEY=${TRELLO_API_KEY-}; else TRELLO_KEY=$(trello_env_get TRELLO_API_KEY "$env_file"); fi
  if [ -n "${TRELLO_TOKEN+x}" ]; then TRELLO_TOKEN=${TRELLO_TOKEN-}; else TRELLO_TOKEN=$(trello_env_get TRELLO_TOKEN "$env_file"); fi
  if [ -n "${TRELLO_BOARD_SHORTLINK+x}" ]; then TRELLO_BOARD=${TRELLO_BOARD_SHORTLINK-}; else TRELLO_BOARD=$(trello_env_get TRELLO_BOARD_SHORTLINK "$env_file"); fi
  if [ -n "${TRELLO_API_BASE+x}" ]; then TRELLO_API=${TRELLO_API_BASE-}; else TRELLO_API=$(trello_env_get TRELLO_API_BASE "$env_file"); fi
  [ -n "$TRELLO_API" ] || TRELLO_API="https://api.trello.com"
  TRELLO_API=${TRELLO_API%/}
}

# 0 when all three board credentials are present. This is the single gate that
# keeps the whole control plane inert for a non-Trello user.
trello_configured() {
  [ -n "${TRELLO_KEY:-}" ] && [ -n "${TRELLO_TOKEN:-}" ] && [ -n "${TRELLO_BOARD:-}" ]
}

# Authed request to an absolute Trello URL. Writes the response body to <out> and
# prints the HTTP status code, exactly like fm-x-poll.sh's curl usage so callers
# branch on the code. key and token are appended as query params (Trello's auth
# scheme) but written into a 0600 -K config file rather than the command line, so
# they never appear in `ps`/argv - the same discipline as X mode's bearer header
# temp file. Returns non-zero (no code printed) on a transport failure.
trello_curl() {
  local method=$1 url=$2 out=$3; shift 3
  local sep cfg code rc
  case "$url" in *\?*) sep='&' ;; *) sep='?' ;; esac
  cfg=$(mktemp "${TMPDIR:-/tmp}/fm-trello-curl.XXXXXX") || return 1
  chmod 600 "$cfg" 2>/dev/null || true
  printf 'url = "%s%skey=%s&token=%s"\n' "$url" "$sep" "$TRELLO_KEY" "$TRELLO_TOKEN" > "$cfg" || { rm -f "$cfg"; return 1; }
  code=$(curl -m "${FM_TRELLO_TIMEOUT:-10}" -s -o "$out" -w '%{http_code}' -X "$method" "$@" -K "$cfg" 2>/dev/null)
  rc=$?
  rm -f "$cfg"
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$code"
}

# trello_curl against $TRELLO_API/<path>; <path> starts with "1/...".
trello_api() {
  local method=$1 path=$2 out=$3; shift 3
  trello_curl "$method" "$TRELLO_API/$path" "$out" "$@"
}

# Board lists JSON, fetched once per process and memoized in _TRELLO_LISTS_JSON.
# Prints the JSON array on success; prints nothing and returns non-zero on failure.
trello_lists_json() {
  if [ -n "${_TRELLO_LISTS_JSON:-}" ]; then
    printf '%s' "$_TRELLO_LISTS_JSON"
    return 0
  fi
  local body code
  body=$(mktemp "${TMPDIR:-/tmp}/fm-trello-lists.XXXXXX") || return 1
  code=$(trello_api GET "1/boards/$TRELLO_BOARD/lists?fields=id,name" "$body") || { rm -f "$body"; return 1; }
  if [ "$code" != "200" ]; then rm -f "$body"; return 1; fi
  _TRELLO_LISTS_JSON=$(cat "$body")
  rm -f "$body"
  [ -n "$_TRELLO_LISTS_JSON" ] || return 1
  printf '%s' "$_TRELLO_LISTS_JSON"
}

# Normalize a lane/list name for matching: lowercase, keep only [a-z0-9]. This
# drops emoji prefixes and separators so "🔨 In Progress" and "In Progress" and
# "in-progress" all collapse to "inprogress".
trello_norm() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'
}

# Resolve a lane name (friendly, e.g. "In Progress", or a keyword, e.g. "ready")
# to its board list id, querying the board dynamically - IDs are never hardcoded
# because every user's board differs. Matches the first list whose normalized
# name contains the normalized query. Prints the id, or nothing (non-zero) when
# unresolved.
trello_lane_id() {
  local query lists id
  query=$(trello_norm "$1")
  [ -n "$query" ] || return 1
  lists=$(trello_lists_json) || return 1
  id=$(printf '%s' "$lists" | jq -r --arg q "$query" '
    def norm: ascii_downcase | gsub("[^a-z0-9]"; "");
    [ .[] | select((.name | norm) | contains($q)) ][0].id // empty' 2>/dev/null) || return 1
  [ -n "$id" ] || return 1
  printf '%s' "$id"
}

# Resolve a board list id back to its lane name. Prints the name or nothing.
trello_lane_name_for() {
  local lists name
  lists=$(trello_lists_json) || return 1
  name=$(printf '%s' "$lists" | jq -r --arg id "$1" '.[] | select(.id == $id) | .name' 2>/dev/null | head -n1) || return 1
  printf '%s' "$name"
}

# 0 when the card id/shortLink is a safe path slug. Card ids are relay/board
# issued (24-hex or an 8-char shortLink), but never trust one into a path - the
# same path-traversal guard fm-x-poll.sh applies to request_id.
trello_safe_cardid() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

trello_marker_path() {
  printf '%s/.trello-seen-%s' "${STATE:-${FM_HOME:-$FM_ROOT}/state}" "$1"
}

# Print the seen marker as
# "<dateLastActivity>\t<idList>\t<go-state>\t<comment-count>".
# The last two fields are additive: readers accept legacy date/list-only markers.
trello_marker_read() {
  local p; p=$(trello_marker_path "$1")
  [ -f "$p" ] || return 0
  cat "$p" 2>/dev/null || true
}

trello_marker_write() {
  local p state go_state comments
  p=$(trello_marker_path "$1")
  state=${STATE:-${FM_HOME:-$FM_ROOT}/state}
  go_state=${4:-}
  comments=${5:-}
  mkdir -p "$state" 2>/dev/null || return 1
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$go_state" "$comments" > "$p" 2>/dev/null || return 1
}

# Fetch the current card and record its dateLastActivity + list id as the seen
# marker. Every mutating fm-trello.sh command calls this after its change so the
# poll never wakes firstmate for firstmate's own edit; only a later captain edit
# advances dateLastActivity past this marker. Best-effort: a fetch failure leaves
# the marker as-is and returns non-zero.
trello_bump_seen() {
  local cardid=$1 body code date list go_state comments
  trello_safe_cardid "$cardid" || return 1
  body=$(mktemp "${TMPDIR:-/tmp}/fm-trello-bump.XXXXXX") || return 1
  code=$(trello_api GET "1/cards/$cardid?fields=dateLastActivity,idList,labels,badges" "$body") || { rm -f "$body"; return 1; }
  if [ "$code" != "200" ]; then rm -f "$body"; return 1; fi
  date=$(jq -r '.dateLastActivity // ""' "$body" 2>/dev/null)
  list=$(jq -r '.idList // ""' "$body" 2>/dev/null)
  go_state=$(jq -r '
    if any(.labels[]?; ((.name // "") | ascii_downcase | gsub("[^a-z0-9]"; "")) == "go")
    then "1" else "0" end' "$body" 2>/dev/null)
  comments=$(jq -r '.badges.comments // 0' "$body" 2>/dev/null)
  rm -f "$body"
  trello_marker_write "$cardid" "$date" "$list" "$go_state" "$comments"
}

# Write/replace trello_card=<cardid> in the task meta. The meta is firstmate-owned
# operational state; this is the single writer of the outbound binding the poll
# reads to route per-task nudges and holds.
trello_meta_bind() {
  local taskid=$1 cardid=$2 meta other tmp state
  state=${STATE:-${FM_HOME:-$FM_ROOT}/state}
  meta="$state/$taskid.meta"
  [ -f "$meta" ] || return 1

  # Establish the requested binding first, then remove this exact card from every
  # other task. This makes bind the mutation-time owner of the one-card/one-task
  # invariant without discarding unrelated card bindings.
  tmp=$(mktemp "$state/.fm-trello-meta.XXXXXX") || return 1
  grep -v '^trello_card=' "$meta" > "$tmp" 2>/dev/null || true
  printf 'trello_card=%s\n' "$cardid" >> "$tmp"
  mv -f "$tmp" "$meta" 2>/dev/null || { rm -f "$tmp"; return 1; }

  for other in "$state"/*.meta; do
    [ -f "$other" ] || continue
    [ "$other" != "$meta" ] || continue
    grep -Fx "trello_card=$cardid" "$other" >/dev/null 2>&1 || continue
    tmp=$(mktemp "$state/.fm-trello-meta.XXXXXX") || return 1
    grep -v -F -x "trello_card=$cardid" "$other" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$other" 2>/dev/null || { rm -f "$tmp"; return 1; }
  done
}

trello_meta_unbind() {
  local taskid=$1 meta tmp state
  state=${STATE:-${FM_HOME:-$FM_ROOT}/state}
  meta="$state/$taskid.meta"
  [ -f "$meta" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-trello-meta.XXXXXX") || return 1
  grep -v '^trello_card=' "$meta" > "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$meta" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

trello_meta_card() {
  local taskid=$1 meta state
  state=${STATE:-${FM_HOME:-$FM_ROOT}/state}
  meta="$state/$taskid.meta"
  [ -f "$meta" ] || return 0
  grep -E '^trello_card=' "$meta" 2>/dev/null | tail -n1 | sed 's/^trello_card=//' || true
}
