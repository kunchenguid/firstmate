#!/usr/bin/env bash
# Follow only PRs/MRs the captain explicitly asks about, without inventing a task.
# Usage: fm-pr-follow.sh add <url> --requested <captain-words>
#        fm-pr-follow.sh remove <url> | list | arm | poll
# config/pr-follow is opt-in, absent by default. add requires a live model-free
# outcome surface. Pi/pi-signed and Claude's activated Calm mod publish the
# private state/.pr-follow-surface JSON heartbeat {surface,owner,epoch}: owner
# matches .lock and epoch is at most 30 seconds old. Claude's heartbeat also
# carries session, which must match .lock-session; a Pi home has no such file.
# Other primaries refuse enrollment. An unavailable surface pauses observation
# and reports once until it returns; it never falls back to model-only delivery.
#
# Durable data/pr-follows.json is {schema:"fm-pr-follows.v1",surface_missing:false,
# cursor:<last-attempted-url>,follows:[{url,requested,generation,revision,observation}]}.
# Each pass starts after cursor, so a slow read cannot starve later follows.
# Registration saves
# a forge baseline, not a notification. An unchanged add preserves it. remove
# stops only this explicit follow, never task monitoring or ownership.
# Mutations serialize under state/.pr-follows.lock and replace the file atomically.
# The observer is fm-pr-poll.sh --snapshot. arm registers one ordinary check with
# the existing watcher, never a separate process or poll loop. Each read has a
# five-second limit. A pass always reads one follow, then starts no further read
# within ten seconds of the watcher's check timeout (FM_CHECK_TIMEOUT, default 30,
# also used when it is not a positive number); the next pass resumes after cursor.
#
# A changed merged/closed state, a check name that newly fails (or any failing
# check on a new head), or a review value that changes to requested changes
# appends a notice to the existing branch outcome store.
# Forge state/conclusion words and URL are preserved, control characters are
# removed. Notice keys include the generation, revision, and exact observation
# before the baseline advances. Retries reuse the line; a changed observation
# after interruption cannot collide with the previous append.
# Informational follows never wake a model. Non-merge events on a URL currently
# recorded by a ship task also queue an action wake. Task-owned merge polling,
# cleanup and backlog remain entirely on their existing path.
# No forge writes, discovery, contribution enrollment, or ownership inference
# from a follow. Terminal follows remain until removed, so reopening is observed.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

fail() { printf 'fm-pr-follow: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; }
STORE="$DATA/pr-follows.json"
HELD=0
TMP=
cleanup() {
  [ -z "$TMP" ] || rm -f -- "$TMP"
  [ "$HELD" = 0 ] || fm_lock_release "$STATE/.pr-follows.lock" || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

surface_available() {
  local owner session
  [ -f "$STATE/.pr-follow-surface" ] && [ ! -L "$STATE/.pr-follow-surface" ] || return 1
  owner=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  session=$(cat "$STATE/.lock-session" 2>/dev/null) || session=
  [ -n "$owner" ] || return 1
  jq -e --arg owner "$owner" --arg session "$session" --argjson now "$(date +%s)" '
    .owner == $owner
    and (.surface == "pi" or (.surface == "claude-calm" and $session != "" and .session == $session))
    and (.epoch | type == "number") and .epoch <= $now and $now - .epoch <= 30
  ' "$STATE/.pr-follow-surface" >/dev/null 2>&1
}

load_store() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] && [ -d "$DATA" ] && [ ! -L "$DATA" ] || fail 'home data/state directories unavailable'
  fm_lock_acquire_wait "$STATE/.pr-follows.lock" || fail 'could not lock follows'
  HELD=1
  fm_pr_regular_destination_on_device_or_absent "$STORE" "$(fm_pr_file_device "$DATA")" || fail 'unsafe follow record'
  if [ -e "$STORE" ]; then
    RECORD=$(jq -ce '
      select(.schema == "fm-pr-follows.v1" and (.surface_missing | type == "boolean") and (.follows | type == "array"))
      | select(all(.follows[]; (.url | type == "string") and (.requested | type == "string" and length > 0)
        and (.generation | type == "string" and test("^[A-Za-z0-9._-]+$"))
        and (.revision | type == "number" and . >= 0 and . == floor)
        and (.observation | (.state | IN("OPEN","CLOSED","MERGED","opened","locked","closed","merged"))
          and (.head | type == "string" and test("^[0-9a-fA-F]{40}$"))
          and (.review | type == "string") and (.checks | type == "array")
          and all(.checks[]; (.name | type == "string") and (.status | type == "string")))))
      | select((.follows | map(.url) | unique | length) == (.follows | length))
    ' "$STORE") || fail 'unreadable follow record; nothing replaced'
  else
    RECORD='{"schema":"fm-pr-follows.v1","surface_missing":false,"cursor":"","follows":[]}'
  fi
}

save_store() {
  TMP=$(umask 077; mktemp "$DATA/.pr-follow.XXXXXX") || return 1
  printf '%s\n' "$RECORD" > "$TMP"
  fm_pr_regular_destination_on_device_or_absent "$STORE" "$(fm_pr_file_device "$DATA")" || fail 'unsafe follow destination'
  mv -f -- "$TMP" "$STORE"
  TMP=
}

snapshot() {
  local raw provider
  fm_pr_url_parse "$1" || return 1
  provider=$FM_PR_PROVIDER
  case "$provider" in github|gitlab) ;; *) return 1 ;; esac
  raw=$(fm_run_timed 5 bash "$SCRIPT_DIR/fm-pr-poll.sh" --snapshot \
    "$provider" "$FM_PR_URL" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER") || return 1
  # latest_checks is also the contribution and health observers' newest-run rule.
  printf '%s\n' "$raw" | jq -ce -L "$SCRIPT_DIR" --arg provider "$provider" '
    include "fm-contributions";
    if $provider == "github" then
      select(has("statusCheckRollup") and has("reviewDecision"))
      | {state,head:.headRefOid,review:(.reviewDecision // ""),
       checks:([.statusCheckRollup[]? | {name:(.name // .context // "check"),
         started_at:(.startedAt // .createdAt // ""),status:(.conclusion // .state // ""),
         failing:((.conclusion // .state // "") | IN("FAILURE","ERROR","TIMED_OUT","STARTUP_FAILURE","ACTION_REQUIRED","CANCELLED"))}]
         | latest_checks | map(select(.failing) | {name,status}))}
    else
      select(has("head_pipeline") and has("detailed_merge_status"))
      | .sha as $head
      | {state,head:$head,review:(.detailed_merge_status // ""),
         checks:([.head_pipeline? | select(. != null and .sha == $head and (.status | IN("failed","canceled"))) | {name:"pipeline",status}])}
    end
    | select((.state | IN("OPEN","CLOSED","MERGED","opened","locked","closed","merged"))
      and (.head | type == "string" and test("^[0-9a-fA-F]{40}$")) and (.review | type == "string"))
  '
}

arm() {
  local staged
  [ -e "$CONFIG/pr-follow" ] || fail 'config/pr-follow is absent; following is off'
  fm_pr_regular_destination_on_device_or_absent "$STATE/pr-follow.check.sh" "$(fm_pr_file_device "$STATE")" || fail 'unsafe check destination'
  staged=$(umask 077; mktemp "$STATE/.pr-follow-check.XXXXXX")
  printf '%s\n' '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")" \
    "export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")" \
    "export FM_CONFIG_OVERRIDE=$(printf '%q' "$CONFIG")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-pr-follow.sh") poll" > "$staged"
  chmod 700 "$staged"
  mv -f -- "$staged" "$STATE/pr-follow.check.sh"
  "$SCRIPT_DIR/fm-check-register.sh" pr-follow
}

action_tasks() {
  local meta kind pr
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    kind=$(sed -n 's/^kind=//p' "$meta" | tail -1)
    [ "$kind" != scout ] && [ "$kind" != secondmate ] || continue
    pr=$(sed -n 's/^pr=//p' "$meta" | tail -1)
    [ "$pr" = "$1" ] || continue
    basename "$meta" .meta
  done
}

cmd=${1:-}
shift 2>/dev/null || true
case "$cmd" in
  -h|--help) usage; exit 0 ;;
  poll)
    [ -e "$CONFIG/pr-follow" ] && [ -e "$STORE" ] || exit 0
    [ "$#" = 0 ] || fail 'poll takes no arguments'
    load_store
    [ "$(printf '%s' "$RECORD" | jq '.follows | length')" != 0 ] || exit 0
    if ! surface_available; then
      if [ "$(printf '%s' "$RECORD" | jq '.surface_missing')" = false ]; then
        printf 'PR following paused: no active model-free outcome surface; use Pi or Claude with the Calm mod.\n'
        RECORD=$(printf '%s' "$RECORD" | jq -c '.surface_missing=true')
        save_store
      fi
      exit 0
    fi
    if [ "$(printf '%s' "$RECORD" | jq '.surface_missing')" = true ]; then
      RECORD=$(printf '%s' "$RECORD" | jq -c '.surface_missing=false')
      save_store
    fi
    timeout=${FM_CHECK_TIMEOUT:-30}
    case "$timeout" in ''|*[!0-9]*) timeout=30 ;; esac
    [ "$timeout" -gt 0 ] || timeout=30
    attempted=0
    while IFS= read -r url; do
      [ "$attempted" = 0 ] || [ "$SECONDS" -lt "$((timeout - 10))" ] || break
      attempted=1
      if [ "$(printf '%s' "$RECORD" | jq -r '.cursor // ""')" != "$url" ]; then
        RECORD=$(printf '%s' "$RECORD" | jq -c --arg url "$url" '.cursor=$url')
        save_store
      fi
      current=$(snapshot "$url" 2>/dev/null) || continue
      previous=$(printf '%s' "$RECORD" | jq -c --arg url "$url" '.follows[] | select(.url == $url)')
      [ "$current" != "$(printf '%s' "$previous" | jq -c '.observation')" ] || continue
      notices=$(printf '%s' "$current" | jq -r --argjson previous "$previous" --arg url "$url" '
        $previous.observation as $p
        | if (.state | IN("MERGED","merged","CLOSED","closed")) then
            if .state != $p.state then "\(.state): \($url)" else empty end
          else
            (if (.checks | length) > 0 and (.head != $p.head or ([.checks[].name] - [$p.checks[].name] | length) > 0) then
              "Checks \([.checks[] | .name + ": " + .status] | join(", ")) on \(.head[:7]): \($url)" else empty end),
            (if (.review | IN("CHANGES_REQUESTED","requested_changes")) and .review != $p.review then
              "Review \(.review): \($url)" else empty end)
          end
        | gsub("[\u0000-\u001f\u007f-\u009f]"; " ")')
      revision=$(printf '%s' "$previous" | jq '.revision + 1')
      generation=$(printf '%s' "$previous" | jq -r '.generation')
      n=0
      while IFS= read -r notice; do
        [ -n "$notice" ] || continue
        n=$((n + 1))
        bash "$SCRIPT_DIR/fm-branch-outcome.sh" append --task fleet --verdict notice \
          --wake "pr-follow:$generation:$revision:$n:$current" --summary "$notice" >/dev/null
        case "$(printf '%s' "$current" | jq -r '.state')" in MERGED|merged) continue ;; esac
        for task in $(action_tasks "$url"); do
          fm_wake_append check "pr-follow:$task" "check: followed PR needs action for $task: $notice"
        done
      done <<EOF_NOTICES
$notices
EOF_NOTICES
      RECORD=$(printf '%s' "$RECORD" | jq -c --arg url "$url" --argjson current "$current" --argjson revision "$revision" \
        '(.follows[] | select(.url == $url)) |= (.observation=$current | .revision=$revision)')
      save_store
    done < <(printf '%s' "$RECORD" | jq -r '.cursor as $cursor | [.follows[].url] | ((index($cursor) // -1) + 1) as $i | (.[$i:] + .[:$i])[]')
    ;;
  add)
    [ "$#" = 3 ] && [ "$2" = --requested ] && [ -n "$3" ] || fail 'add requires <url> --requested <captain-words>'
    [ -e "$CONFIG/pr-follow" ] || fail 'config/pr-follow is absent; following is off'
    surface_available || fail 'no active model-free outcome surface; enrollment requires Pi or Claude with the Calm mod'
    fm_pr_url_parse "$1" || fail 'invalid PR/MR URL'
    case "$FM_PR_PROVIDER" in github|gitlab) ;; *) fail 'following supports GitHub PRs and GitLab merge requests' ;; esac
    url=$FM_PR_URL
    requested=$3
    load_store
    if ! printf '%s' "$RECORD" | jq -e --arg url "$url" 'any(.follows[]; .url == $url)' >/dev/null; then
      observation=$(snapshot "$url" 2>/dev/null) || fail 'could not read the forge baseline; no follow created'
      TMP=$(umask 077; mktemp "$DATA/.pr-follow.XXXXXX")
      generation="$(date +%s)-${TMP##*/}"
      rm -f -- "$TMP"; TMP=
      RECORD=$(printf '%s' "$RECORD" | jq -c --arg url "$url" --arg requested "$requested" --arg generation "$generation" --argjson observation "$observation" \
        '.follows += [{url:$url,requested:$requested,generation:$generation,revision:0,observation:$observation}]')
      save_store
    fi
    arm >/dev/null
    printf 'Following %s\n' "$url"
    ;;
  remove)
    [ "$#" = 1 ] || fail 'remove requires <url>'
    fm_pr_url_parse "$1" || fail 'invalid PR/MR URL'
    url=$FM_PR_URL
    load_store
    RECORD=$(printf '%s' "$RECORD" | jq -c --arg url "$url" '.follows |= map(select(.url != $url))')
    save_store
    printf 'Stopped following %s\n' "$url"
    ;;
  list)
    [ "$#" = 0 ] || fail 'list takes no arguments'
    load_store
    printf '%s' "$RECORD" | jq -r '.follows[] | [.url,.requested] | @tsv'
    ;;
  arm) [ "$#" = 0 ] || fail 'arm takes no arguments'; arm ;;
  *) usage >&2; exit 2 ;;
esac
