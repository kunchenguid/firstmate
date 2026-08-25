#!/usr/bin/env bash
# fm-tracker-notify.sh - the watcher poll behind firstmate's GitHub issue wake.
#
# Armed by `fm-tracker.sh watch`, run by bin/fm-watch.sh as a registered custom
# check, and read as a wake only when it prints a line.
#
# Why this is a trigger rather than a per-issue poll:
#
#   GET /notifications is ONE endpoint covering every repository, issue and
#   thread the account can see, so no issue is ever polled individually. It
#   returns an ETag and states its own cadence in X-Poll-Interval. A conditional
#   re-request carrying If-None-Match returns 304 Not Modified and consumes ZERO
#   rate limit. That is the overwhelmingly common case, so watching is free.
#
# The notifications inbox does NOT carry an account's own actions. When the
# captain and firstmate share one GitHub account - the current fleet setup - a
# captain's answer produces no notification at all. That is why this poll has a
# second, equally conditional source: the per-repository issue-comment feed,
# which does see same-account comments. Both are ETag-conditional and both are
# silent on 304, so the fallback also costs nothing when nothing happened.
#
# Measured against github.com on 2026-08-25; docs/verification/github-tracker-wake.md
# owns the exact commands and output behind both claims.
#
# This poll is silent on every error, exactly like bin/fm-pr-poll.sh: a failed
# lookup must never be readable as a comment that did not arrive.
#
# Usage: fm-tracker-notify.sh --task <task-id>
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh" 2>/dev/null || exit 0
# shellcheck source=bin/fm-tracker-lib.sh
. "$SCRIPT_DIR/fm-tracker-lib.sh" 2>/dev/null || exit 0

GH=${FM_TRACKER_GH:-gh}
PARSER="$SCRIPT_DIR/fm-tracker-parse.py"
PYTHON=${FM_TRACKER_PYTHON:-python3}
# One wake line names at most this many issues; any remainder is counted.
MAX_NAMED=5
# Stop issuing requests before FM_CHECK_TIMEOUT would fire, so a slow network
# degrades into a quiet cycle rather than a killed check.
DEADLINE=$(( $(date +%s) + ${FM_TRACKER_POLL_BUDGET:-20} ))

TASK=
while [ "$#" -gt 0 ]; do
  case $1 in
    --task) [ "$#" -gt 1 ] || exit 0; TASK=$2; shift 2 ;;
    --task=*) TASK=${1#--task=}; shift ;;
    *) exit 0 ;;
  esac
done

fm_pr_task_id_valid "$TASK" || exit 0
fm_tracker_state_root_valid "$STATE" || exit 0
fm_tracker_watch_armed "$STATE" "$TASK" || exit 0
WATCH=$FM_TRACKER_ARTIFACT
fm_tracker_artifact_path "$STATE" "$TASK" .tracker-cursor || exit 0
CURSOR=$FM_TRACKER_ARTIFACT
command -v "$GH" >/dev/null 2>&1 || exit 0
command -v "$PYTHON" >/dev/null 2>&1 || exit 0
[ -f "$PARSER" ] && [ ! -L "$PARSER" ] || exit 0

# ---------------------------------------------------------------------------
# Watch list
# ---------------------------------------------------------------------------

REPOS=()
{
  IFS= read -r _magic || exit 0
  while IFS= read -r watched_line; do
    [ -n "$watched_line" ] || continue
    fm_tracker_repo_parse "$watched_line" || exit 0
    REPOS+=("$FM_TRACKER_OWNER/$FM_TRACKER_REPO")
  done
} < "$WATCH" || exit 0
[ "${#REPOS[@]}" -gt 0 ] || exit 0
[ "${#REPOS[@]}" -le "$FM_TRACKER_MAX_WATCHED_REPOS" ] || exit 0
REPO_CSV=$(printf '%s,' "${REPOS[@]}")

# ---------------------------------------------------------------------------
# Cursor
#
# A flat key=value store holding one ETag and one position per source. A missing
# or malformed cursor reseeds: the first run after arming establishes position
# silently, so arming a watch never wakes firstmate on history.
# ---------------------------------------------------------------------------

# Held as newline-separated key=value text rather than an associative array:
# stock macOS Bash is 3.2, which has no `declare -A`, and this poll must degrade
# into a quiet cycle rather than into a silent permanent failure there. On 3.2
# the array form failed, wrote no cursor, and still exited 0 - indistinguishable
# from an inbox where nothing happened, so the wake would simply never fire.
CUR_DATA=''

cur_load() {
  local first=''
  [ -f "$CURSOR" ] && [ ! -L "$CURSOR" ] || return 0
  IFS= read -r first < "$CURSOR" 2>/dev/null || return 0
  [ "$first" = "$FM_TRACKER_CURSOR_MAGIC" ] || return 0
  CUR_DATA=$(sed 1d "$CURSOR" 2>/dev/null)
}

cur_get() {  # <key>
  local key=$1 line
  while IFS= read -r line; do
    case $line in
      "$key="*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done <<EOF
$CUR_DATA
EOF
  printf ''
}

cur_set() {  # <key> <value>
  local key=$1 value=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $line in
      "$key="*) continue ;;
    esac
    out="$out$line
"
  done <<EOF
$CUR_DATA
EOF
  CUR_DATA="$out$key=$value"
}

save_cursor() {
  local tmp
  tmp=$(mktemp "$STATE/.fm-tracker-cursor.XXXXXX" 2>/dev/null) || return 0
  {
    printf '%s\n' "$FM_TRACKER_CURSOR_MAGIC"
    printf '%s\n' "$CUR_DATA"
  } > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 0; }
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 0; }
  mv -f -- "$tmp" "$CURSOR" 2>/dev/null || rm -f -- "$tmp"
}

cur_load
SEEDING=0
[ -n "$(cur_get seeded)" ] || SEEDING=1

# ---------------------------------------------------------------------------
# One conditional request
# ---------------------------------------------------------------------------

# Sets HTTP_STATUS, HTTP_ETAG, HTTP_INTERVAL and HTTP_BODY. gh exits non-zero on
# a 304, which is a success here, so the status line is the authority and the
# exit code is deliberately ignored. Any failure reports status 000, which every
# caller treats as "nothing happened".
http_get() {  # <path> <etag>
  local path=$1 etag=$2 raw line
  local -a args=(api -i "$path")
  HTTP_STATUS=000
  HTTP_ETAG=
  HTTP_INTERVAL=
  HTTP_BODY=
  [ "$(date +%s)" -lt "$DEADLINE" ] || return 0
  [ -z "$etag" ] || args+=(-H "If-None-Match: $etag")
  raw=$("$GH" "${args[@]}" 2>/dev/null) || true
  [ -n "$raw" ] || return 0
  while IFS= read -r line; do
    line=${line%$'\r'}
    case $line in
      HTTP/*) HTTP_STATUS=${line#* } ; HTTP_STATUS=${HTTP_STATUS%% *} ;;
      [Ee][Tt][Aa][Gg]:\ *) [ -n "$HTTP_ETAG" ] || HTTP_ETAG=${line#*: } ;;
      [Xx]-[Pp][Oo][Ll][Ll]-[Ii][Nn][Tt][Ee][Rr][Vv][Aa][Ll]:\ *) HTTP_INTERVAL=${line#*: } ;;
      '') break ;;
    esac
  done <<EOF
$raw
EOF
  HTTP_BODY=$(printf '%s\n' "$raw" | awk 'body { print } !body && /^\r?$/ { body = 1 }')
}

# ---------------------------------------------------------------------------
# Hits
# ---------------------------------------------------------------------------

HITS=()
add_hit() {  # <slug> <number>
  local slug=$1 num=$2 seen
  [ -n "$slug" ] || return 0
  fm_tracker_issue_number_valid "$num" || return 0
  for seen in "${HITS[@]+"${HITS[@]}"}"; do
    [ "$seen" = "$slug#$num" ] && return 0
  done
  HITS+=("$slug#$num")
}

# Filter one response body, advancing NEW_CURSOR and recording every issue whose
# thread moved since the stored position.
collect() {  # <mode> <slug> <since>  ; body on stdin
  local mode=$1 slug=$2 since=$3 field_a field_b
  NEW_CURSOR=$since
  while IFS=$'\t' read -r field_a field_b; do
    case $field_a in
      CURSOR) [ -z "$field_b" ] || NEW_CURSOR=$field_b ;;
      '') ;;
      *) add_hit "$field_a" "$field_b" ;;
    esac
  done < <(FM_PARSE_MODE="$mode" FM_PARSE_SLUG="$slug" FM_PARSE_SINCE="$since" \
    FM_PARSE_REPOS="$REPO_CSV" "$PYTHON" "$PARSER" 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Source 1: the notifications inbox - one endpoint for every repository
#
# GitHub states its own cadence in X-Poll-Interval. Honour it as a floor: never
# re-request sooner than the server asked, whatever the watcher's own check
# interval happens to be set to.
# ---------------------------------------------------------------------------

now=$(date +%s)
next=$(cur_get notifications_next)
case $next in
  ''|*[!0-9]*) next=0 ;;
esac
if [ "$next" -le "$now" ]; then
  http_get "/notifications?per_page=50" "$(cur_get notifications_etag)"
  case $HTTP_STATUS in
    200)
      [ -z "$HTTP_ETAG" ] || cur_set notifications_etag "$HTTP_ETAG"
      collect notifications '' "$(cur_get notifications_since)" <<EOF
$HTTP_BODY
EOF
      [ -z "$NEW_CURSOR" ] || cur_set notifications_since "$NEW_CURSOR"
      ;;
    304)
      [ -z "$HTTP_ETAG" ] || cur_set notifications_etag "$HTTP_ETAG"
      ;;
  esac
  interval=${HTTP_INTERVAL:-}
  case $interval in
    ''|*[!0-9]*|0) interval=$FM_TRACKER_DEFAULT_POLL_INTERVAL ;;
  esac
  cur_set notifications_next "$((now + interval))"
  cur_set notifications_interval "$interval"
fi

# ---------------------------------------------------------------------------
# Source 2: the per-repository issue-comment feed
#
# One request per watched repository, catching what the inbox structurally
# cannot: a comment left by the same account firstmate is authenticated as.
# ---------------------------------------------------------------------------

for slug in "${REPOS[@]}"; do
  key=${slug//\//__}
  key=${key//-/_}
  key=${key//./_}
  since=$(cur_get "comments_since_$key")
  path="/repos/$slug/issues/comments?sort=updated&direction=desc&per_page=30"
  [ -z "$since" ] || path="$path&since=$since"
  http_get "$path" "$(cur_get "comments_etag_$key")"
  case $HTTP_STATUS in
    200)
      [ -z "$HTTP_ETAG" ] || cur_set "comments_etag_$key" "$HTTP_ETAG"
      collect comments "$slug" "$since" <<EOF
$HTTP_BODY
EOF
      [ -z "$NEW_CURSOR" ] || cur_set "comments_since_$key" "$NEW_CURSOR"
      ;;
    304)
      [ -z "$HTTP_ETAG" ] || cur_set "comments_etag_$key" "$HTTP_ETAG"
      ;;
  esac
done

cur_set seeded 1
save_cursor

# The seeding run establishes position and never wakes firstmate on history.
[ "$SEEDING" -eq 0 ] || exit 0
[ "${#HITS[@]}" -gt 0 ] || exit 0

named=()
for hit in "${HITS[@]}"; do
  [ "${#named[@]}" -lt "$MAX_NAMED" ] || break
  named+=("$hit")
done
extra=$(( ${#HITS[@]} - ${#named[@]} ))
line="issue comment:$(printf ' %s' "${named[@]}")"
[ "$extra" -le 0 ] || line="$line (+$extra more)"
printf '%s\n' "$line"
