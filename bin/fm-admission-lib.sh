#!/usr/bin/env bash
# fm-admission-lib.sh - the outside-the-host inputs of bin/fm-capacity.sh --admit.
#
# Sourced, never executed. bin/fm-capacity.sh owns the verdict and the limits
# (docs/configuration.md "Lane capacity" owns the config keys); this library
# reads the two facts a home's own probes cannot see, each one cached for
# a short time so a batch of spawns does not repeat the read, and each one
# failing open (a non-zero return, which the caller treats as "unknown"):
#
#   fm_admission_fleet_working <script-dir> <state-dir>
#       Prints the number of workers working right now across this home and
#       every registered secondmate home, from bin/fm-worker-table.sh --json
#       (its totals.working). Only a working row counts; a parked listener
#       never does (FM_ADMISSION_WORKER_TABLE replaces the table command, for
#       tests). A home's cached rows are as old as that home's cache, which
#       bin/fm-worker-table.sh --refresh keeps under five minutes.
#
#   fm_admission_github_counts <project-dir> <state-dir>
#       Prints "<ci-queued> <open-prs> <merge-queue>" for the project's GitHub
#       origin: queued Actions runs created within the last 24 hours (an older
#       queued run is a zombie and is never counted), open pull requests, and
#       merge-queue entries. It reads through gh-axi, bounded to
#       FM_ADMISSION_GH_TIMEOUT seconds (default 15); a project whose origin is
#       not on github.com, a missing gh-axi, a timeout, or an unreadable answer
#       returns 1.
#
# The cache lives in <state-dir> as .admission-*.cache files holding one
# "<epoch> <payload>" line; FM_ADMISSION_CACHE_TTL (default 60 seconds, 0 turns
# the cache off) bounds its age. The reserved-review census below is uncached
# and is read only by the explicitly marked spawn path under its shared lock.

# Reserved review allowance. Only fm-spawn.sh's explicit --merge-review scout
# path calls this while holding <root-home>/state/.review-admission.lock until
# metadata publication (or failed-start cleanup). config/review-capacity in the
# root home is one positive integer, at most six digits; absent means 3.
# Every local home's merge_review=1 task record occupies a place until cleanup;
# ordinary task records cannot spend this allowance. Requires the wake and
# backend libraries for the local-home census and metadata reads.
fm_admission_review_capacity() {  # <config-dir> <state-dir>
  local file=$1/review-capacity state meta value
  FM_REVIEW_CAPACITY=3
  FM_REVIEW_OCCUPANTS=0
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -f "$file" ] && [ -r "$file" ] || return 1
    value=$(< "$file")
    case "$value" in ''|*[!0-9]*|0*) return 1 ;; esac
    [ "${#value}" -le 6 ] || return 1
    FM_REVIEW_CAPACITY=$value
  fi
  fm_local_firstmate_state_dirs "$2" || return 1
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    [ ! -e "$state" ] || { [ -d "$state" ] && [ -r "$state" ] && [ -x "$state" ]; } || return 1
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      [ -r "$meta" ] || return 1
      [ "$(fm_meta_get "$meta" merge_review)" = 1 ] || continue
      FM_REVIEW_OCCUPANTS=$((FM_REVIEW_OCCUPANTS + 1))
    done
  done
}

_fm_admission_is_uint() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

_fm_admission_ttl() {
  local ttl=${FM_ADMISSION_CACHE_TTL:-60}
  _fm_admission_is_uint "$ttl" || ttl=60
  printf '%s\n' "$ttl"
}

# Print the payload of a fresh cache file; return 1 when absent, stale or odd.
_fm_admission_cache_read() {  # <file>
  local file=$1 ttl line stamp payload now
  ttl=$(_fm_admission_ttl)
  [ "$ttl" -gt 0 ] && [ -f "$file" ] && [ ! -L "$file" ] || return 1
  IFS= read -r line < "$file" || [ -n "$line" ] || return 1
  stamp=${line%% *}
  payload=${line#* }
  _fm_admission_is_uint "$stamp" || return 1
  now=$(date +%s)
  [ "$stamp" -le "$now" ] && [ $((now - stamp)) -lt "$ttl" ] || return 1
  printf '%s\n' "$payload"
}

_fm_admission_cache_write() {  # <file> <payload>
  local file=$1 tmp
  [ "$(_fm_admission_ttl)" -gt 0 ] || return 0
  [ ! -L "$file" ] || return 0
  tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
  if printf '%s %s\n' "$(date +%s)" "$2" > "$tmp" 2>/dev/null; then
    mv -f -- "$tmp" "$file" 2>/dev/null || rm -f -- "$tmp"
  else
    rm -f -- "$tmp"
  fi
}

fm_admission_fleet_working() {  # <script-dir> <state-dir>
  local script_dir=$1 state=$2 cache payload out working table
  cache="$state/.admission-fleet.cache"
  if payload=$(_fm_admission_cache_read "$cache"); then
    printf '%s\n' "$payload"
    return 0
  fi
  command -v jq >/dev/null 2>&1 || return 1
  table=${FM_ADMISSION_WORKER_TABLE:-$script_dir/fm-worker-table.sh}
  [ -x "$table" ] || return 1
  out=$(fm_run_timed 30 "$table" --json 2>/dev/null) || return 1
  working=$(printf '%s' "$out" | jq -r '.totals.working | select(type == "number")' 2>/dev/null) || return 1
  _fm_admission_is_uint "$working" || return 1
  _fm_admission_cache_write "$cache" "$working"
  printf '%s\n' "$working"
}

# owner/repo of a github.com origin (https, ssh, scp-like); returns 1 otherwise.
_fm_admission_github_slug() {  # <project-dir>
  local url path
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  case "$url" in
    https://github.com/*|http://github.com/*) path=${url#*://github.com/} ;;
    https://*@github.com/*) path=${url#*@github.com/} ;;
    ssh://git@github.com/*|ssh://github.com/*) path=${url#*github.com/} ;;
    git@github.com:*) path=${url#git@github.com:} ;;
    *) return 1 ;;
  esac
  path=${path%.git}
  path=${path%/}
  case "$path" in
    */*/*|*[!A-Za-z0-9._/-]*|/*|*/|"") return 1 ;;
    */*) printf '%s\n' "$path" ;;
    *) return 1 ;;
  esac
}

fm_admission_github_counts() {  # <project-dir> <state-dir>
  local project=$1 state=$2 slug owner repo key cache payload timeout queued graph
  slug=$(_fm_admission_github_slug "$project") || return 1
  owner=${slug%%/*}
  repo=${slug#*/}
  key=$(printf '%s' "$slug" | tr -c 'A-Za-z0-9._-' '_')
  cache="$state/.admission-github.$key.cache"
  if payload=$(_fm_admission_cache_read "$cache"); then
    printf '%s\n' "$payload"
    return 0
  fi
  command -v gh-axi >/dev/null 2>&1 || return 1
  timeout=${FM_ADMISSION_GH_TIMEOUT:-15}
  _fm_admission_is_uint "$timeout" && [ "$timeout" -gt 0 ] || timeout=15
  # Queued runs older than a day are zombies: they never start and must not
  # inflate the depth that holds new starts.
  queued=$(fm_run_timed "$timeout" gh-axi api "/repos/$slug/actions/runs?status=queued&per_page=100" \
    --jq '[.workflow_runs[] | select((.created_at | fromdateiso8601) > (now - 86400))] | length' 2>/dev/null) || return 1
  _fm_admission_is_uint "$queued" || return 1
  graph=$(fm_run_timed "$timeout" gh-axi api POST graphql \
    --raw-field "query=query{repository(owner:\"$owner\",name:\"$repo\"){pullRequests(states:OPEN){totalCount} mergeQueue{entries{totalCount}}}}" \
    --jq '.data.repository | [.pullRequests.totalCount, (.mergeQueue.entries.totalCount // 0)] | @tsv' 2>/dev/null) || return 1
  graph=$(printf '%s' "$graph" | tr '\t' ' ')
  case "$graph" in
    *[!0-9\ ]*|""|" "*|*" ") return 1 ;;
  esac
  payload="$queued $graph"
  case "$payload" in
    *" "*" "*) ;;
    *) return 1 ;;
  esac
  _fm_admission_cache_write "$cache" "$payload"
  printf '%s\n' "$payload"
}
