#!/usr/bin/env bash
# fm-cursor.sh - read-only view of THIS operator's own Cursor Cloud agents.
#
# Cursor Cloud agents run on Cursor's infrastructure, not in a firstmate
# worktree or terminal endpoint, so they are deliberately NOT a runtime backend
# (bin/fm-backend.sh) and NOT a harness (bin/fm-harness.sh): there is no pane to
# capture, no composer to submit into, and no local checkout to isolate. This
# helper is the companion-surface pattern instead, the same boundary
# docs/codex-app-backend.md draws for Codex Desktop threads. It creates no task
# records and registers no watcher check, so no supervision path can mistake a
# cloud agent for a stalled local crewmate.
#
# The mapping onto firstmate's own nouns is: a Cursor AGENT is a task, and a
# Cursor ENVIRONMENT is the project. An environment is a named, multi-repo,
# secret-bearing context, and `POST /v1/agents` accepts either a named `env` or a
# bare `repos` list - the API documents them as mutually exclusive. An agent
# therefore belongs to its environment, never to one of the repositories inside
# it, and a change spanning a front end and a back end is one agent in one
# environment rather than several tasks. Both `list` and `show` lead with the
# environment for that reason; an agent created from a bare repo list has no
# environment name and is shown as the ad-hoc case.
#
# Usage:
#   fm-cursor.sh list  [--json] [--all] [--limit <n>] [--no-runs] [--env [<name>]]
#   fm-cursor.sh show  <agent-id> [--json]
#   fm-cursor.sh runs  <agent-id> [--json] [--limit <n>]
#   fm-cursor.sh usage <agent-id> [--json]
#   fm-cursor.sh -h | --help
#
# Subcommands:
#   list   Agents newest-first, each with its ENVIRONMENT and the status of its
#          LATEST RUN. Archived agents are hidden unless --all is passed.
#   show   One agent's detail: its environment, every repository in that
#          environment, and the status of its latest run.
#   runs   Run history for one agent: status, start, duration, and any PR URL.
#   usage  Token usage for one agent, totalled and per run.
#
# Options:
#   --json        Emit a stable JSON document instead of the human table.
#                 Schemas: fm-cursor-list.v1, fm-cursor-show.v1,
#                 fm-cursor-runs.v1, fm-cursor-usage.v1.
#   --all         list only: include ARCHIVED agents.
#   --limit <n>   list: agents to fetch, 1-100, default 20.
#                 runs: runs to fetch, 1-100, default 20.
#   --no-runs     list only: skip latest-run resolution. One API call instead of
#                 1+N, at the cost of the only column that says what is actually
#                 running.
#   --env [<name>]
#                 list only: show only agents in that environment. A bare --env
#                 means this home's default from config/cursor-environment, and
#                 fails when no default is configured. Cursor's list endpoint has
#                 no environment filter, so this narrows the fetched page
#                 client-side: --limit bounds the FETCH, not the matches, and the
#                 footer reports both counts. Filtering happens before run
#                 resolution, so a narrow --env costs far fewer requests.
#
# The default environment never filters implicitly. `list` always shows every
# environment and marks the default with `*`, because silently hiding most of the
# fleet would misrepresent it; the default is the intended TARGET for a future
# operation that needs an environment, not a view preference.
#
# Why list resolves runs by default: an agent's own `status` field is LIFECYCLE
# only - the enum is ACTIVE|ARCHIVED and the Cursor API documents it as "agent
# lifecycle state; execution status lives on runs". ACTIVE therefore means "not
# archived", NOT "currently running": a finished agent stays ACTIVE until
# somebody archives it. Reporting agent status as if it were execution status is
# the single easiest way to misread this fleet, so `list` resolves each agent's
# latest run and reports the run status enum
# (CREATING|RUNNING|FINISHED|ERROR|CANCELLED|EXPIRED) as the primary column.
# Resolution prefers the `latestRunId` field that list items carry in practice;
# that field is NOT in Cursor's published schema, so a per-agent
# `runs?limit=1` fallback covers both its absence AND a fast path whose request
# fails, and the JSON output records which source answered in `runStatusSource`:
# `latestRunId`, `runs-list`, `resolution-failed`, or `skipped` for --no-runs.
# Run resolution is deliberately NON-FATAL, in `show` exactly as in `list`. The
# fast path is reached through that undocumented field, so a stale value there
# says nothing about whether the agent exists, and exiting with "not found" for an
# agent whose own GET just succeeded would be actively misleading. A failed fast
# path therefore ALWAYS falls through to the fallback, and when both fail the run
# is reported as `unknown` WITH its reason - the HTTP status and the API's own
# message - so a 429 mid-listing can never be mistaken for a rejected key or for
# runs that are simply gone. `list` groups those reasons into its footer and
# degrades only the rows that failed; `--json` carries one per agent in
# `runStatusReason`. What still fails loudly is the TOP-LEVEL request of each
# subcommand - the agent list, one agent, its runs, its usage - because there a
# non-200 means the operation itself failed and nothing is left to show.
#
# Activation: read-only, and inert until this home opts in by putting a non-empty
# CURSOR_API_KEY in its gitignored .env, mirroring how X mode gates on
# FMX_PAIRING_TOKEN. The key is read from that file ONLY. This helper never
# consults the macOS keychain, `cursor-agent`'s stored credentials, or an ambient
# CURSOR_API_KEY in the environment: an undocumented credential lifted from
# another tool's store is not a supported Cursor credential, and an ambient
# variable would silently change which account firstmate speaks for.
#
# Credential handling: the key is passed to curl through a mode-0600 config file
# that is removed on every exit path, never through argv, because a process
# argument is world-readable via `ps`. The key is never printed, never logged,
# and never included in an error message; HTTP failures report the status code
# and the API's own `message` field only.
#
# Every call is a GET. This helper has no verb that creates, steers, cancels,
# archives, or deletes anything, so it cannot alter the operator's fleet.
#
# Files:
#   $FM_HOME/.env                     CURSOR_API_KEY, the activation gate
#   $FM_HOME/config/cursor-environment
#                                     optional default environment name: the
#                                     first non-empty, non-comment line, trimmed,
#                                     used verbatim. Absent means no default.
#
# Environment:
#   FM_HOME               home whose .env and config/ are read (default: this checkout)
#   FM_CURSOR_ENV_FILE    read the key from this .env-style file instead
#   FM_CONFIG_OVERRIDE    read config/ from this directory instead
#   FM_CURSOR_API_BASE    API base URL (default https://api.cursor.com)
#   FM_CURSOR_TIMEOUT     per-request timeout in seconds, a whole number from 1
#                         to 3600 (default 30)
#
# Exit status:
#   0  success
#   2  usage error
#   3  not configured (no CURSOR_API_KEY), misconfigured (a key or timeout this
#      helper refuses to hand to curl), or a required tool is missing
#   4  the API rejected or failed the request
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# fmx_env_get is the repo's single .env-style reader (last assignment wins,
# tolerates `export ` and one layer of quotes). Reuse it rather than rolling a
# second parser; bin/fm-public-followup-lib.sh depends on it the same way.
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
API_BASE=${FM_CURSOR_API_BASE:-https://api.cursor.com}
API_BASE=${API_BASE%/}
TIMEOUT=${FM_CURSOR_TIMEOUT:-30}

# This home's default environment, from config/cursor-environment: the first
# non-empty, non-comment line with surrounding whitespace trimmed, matching how
# bin/fm-harness.sh reads config/secondmate-harness. Absent file, or a file with
# only blank and comment lines, means this home has no default. The name is used
# verbatim otherwise, because Cursor environment names contain spaces and are
# case-sensitive.
default_environment() {
  local line
  [ -f "$CONFIG/cursor-environment" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    printf '%s' "$line"
    return 0
  done < "$CONFIG/cursor-environment"
}

CFG=
BODY=
cleanup() {
  [ -z "$CFG" ] || rm -f -- "$CFG"
  [ -z "$BODY" ] || rm -f -- "$BODY"
}
trap cleanup EXIT HUP INT TERM

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {  # <exit-code> <message...>
  local code=$1
  shift
  printf 'fm-cursor: %s\n' "$*" >&2
  exit "$code"
}

require_tools() {
  local tool
  for tool in curl jq; do
    command -v "$tool" >/dev/null 2>&1 \
      || die 3 "$tool is required (install: brew install $tool  # or the platform's package manager)"
  done
}

# Arm curl with the operator's key in a mode-0600 config file. The key never
# reaches argv, so it is not visible in `ps`.
arm_auth() {
  local env_file token
  env_file=${FM_CURSOR_ENV_FILE:-$FM_HOME/.env}
  token=$(fmx_env_get CURSOR_API_KEY "$env_file")
  if [ -z "$token" ]; then
    die 3 "Cursor Cloud is not configured for this home. Put a non-empty CURSOR_API_KEY in $env_file (create the key at https://cursor.com/dashboard/api). Until then this helper does nothing."
  fi
  # Refuse a key carrying characters that curl config quoting would mangle or
  # that could inject a second directive. Real keys are URL-safe base64.
  case $token in
    *[!A-Za-z0-9._~+/=-]*)
      die 3 "the CURSOR_API_KEY in $env_file contains unexpected characters; re-copy it from https://cursor.com/dashboard/api" ;;
  esac
  # The same config file carries the bearer header, and curl config syntax is one
  # directive per line, so an unvalidated timeout is an injection point: a value
  # holding a newline would append arbitrary directives (proxy, url, output) next
  # to the key. Digits only, and a range, so a typo also fails legibly instead of
  # degrading into an opaque "could not reach" error.
  valid_timeout "$TIMEOUT" \
    || die 3 "FM_CURSOR_TIMEOUT must be a whole number of seconds from 1 to 3600"
  umask 077
  CFG=$(mktemp "${TMPDIR:-/tmp}/.fm-cursor-auth.XXXXXX") \
    || die 3 "could not create a private file for the API key"
  chmod 600 "$CFG" || die 3 "could not restrict permissions on the API key file"
  printf 'header = "Authorization: Bearer %s"\nsilent\nshow-error\nmax-time = %s\n' \
    "$token" "$TIMEOUT" > "$CFG" || die 3 "could not write the API key file"
  BODY=$(mktemp "${TMPDIR:-/tmp}/.fm-cursor-body.XXXXXX") \
    || die 3 "could not create a response file"
}

# GET <path>; leaves the response body in $BODY. Returns 0 only on HTTP 200, and
# otherwise returns non-zero with the explanation in $API_ERROR instead of
# exiting, so a caller can choose between dying and degrading one row of a view.
# The explanation carries the status and the API's own message, never raw headers.
API_ERROR=
api_try_get() {  # <path>
  local path=$1 code
  API_ERROR=
  code=$(curl --config "$CFG" -o "$BODY" -w '%{http_code}' "$API_BASE$path" 2>/dev/null) || code=000
  case $code in
    200) return 0 ;;
    000) API_ERROR="could not reach ${API_BASE} (network, proxy, or timeout after ${TIMEOUT}s)" ;;
    401|403) API_ERROR="the Cursor API rejected the key (HTTP $code)$(api_message). Check CURSOR_API_KEY, or regenerate it at https://cursor.com/dashboard/api" ;;
    404) API_ERROR="not found (HTTP 404)$(api_message)" ;;
    429) API_ERROR="rate limited by the Cursor API (HTTP 429)$(api_message). Retry in a minute" ;;
    *) API_ERROR="the Cursor API returned HTTP $code$(api_message)" ;;
  esac
  # Collapse to one line here, at the single point every explanation is built:
  # callers carry it through newline- and unit-separator-delimited records, and
  # the API's `message` field is data this helper does not control.
  API_ERROR=${API_ERROR//$'\n'/ }
  API_ERROR=${API_ERROR//$'\r'/ }
  API_ERROR=${API_ERROR//$'\t'/ }
  API_ERROR=${API_ERROR//$'\037'/ }
  return 1
}

# GET <path> or die. The right shape for a fetch whose failure leaves nothing to
# show: every top-level fetch, including the `list` page itself.
api_get() {  # <path>
  api_try_get "$1" || die 4 "$API_ERROR"
}

# The API's own error text, when the body is JSON carrying one. Never the body
# wholesale, so a surprise payload cannot spill into a log.
api_message() {
  local msg
  msg=$(jq -r 'if type == "object" and (.message? | type) == "string" then .message else empty end' \
    "$BODY" 2>/dev/null) || return 0
  [ -n "$msg" ] || return 0
  printf ': %s' "$msg"
}

valid_agent_id() {  # <id>
  case $1 in
    '' | *[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

valid_limit() {  # <n>
  case $1 in
    '' | *[!0-9]*) return 1 ;;
    *) [ "$1" -ge 1 ] && [ "$1" -le 100 ] ;;
  esac
}

# Digits only, then a range. The 5-or-more-digit pattern is refused before any
# arithmetic so an absurd value cannot reach `[ -ge ]` at all.
valid_timeout() {  # <seconds>
  case $1 in
    '' | *[!0-9]* | ?????*) return 1 ;;
    *) [ "$1" -ge 1 ] && [ "$1" -le 3600 ] ;;
  esac
}

# One resolution record: status, run id, provenance, and the reason the status is
# `unknown`, joined by unit separators so a reason containing spaces survives.
run_status_record() {  # <status> <run-id> <source> [reason]
  printf '%s\037%s\037%s\037%s' "$1" "$2" "$3" "${4:-}"
}
RUN_STATUS=
RUN_ID=
RUN_SOURCE=
RUN_REASON=

# Read one record back into RUN_STATUS, RUN_ID, RUN_SOURCE, and RUN_REASON.
read_run_status_record() {  # <record>
  IFS=$(printf '\037') read -r RUN_STATUS RUN_ID RUN_SOURCE RUN_REASON <<EOF
$1
EOF
}

# Latest run status for one agent, as a run_status_record.
# Prefers the caller-supplied latestRunId, falls back to the runs list, and
# reports "none" for an agent that has no run yet.
#
# A failed fast-path request ALWAYS falls through to the runs-list fallback: the
# latestRunId that drove it is not in Cursor's published schema, so a stale or
# removed run id answering 404 says nothing about the agent itself. When the
# fallback fails too, resolution reports `unknown` with the reason attached and
# never exits, in every caller: `list` degrades that one row and keeps going, and
# `show` renders the agent it already fetched successfully rather than dying with
# a status that would read as "no such agent".
latest_run_status() {  # <agent-id> <latest-run-id-or-empty>
  local agent=$1 run=$2 status
  if [ -n "$run" ] && [ "$run" != null ]; then
    if valid_agent_id "$run"; then
      if api_try_get "/v1/agents/$agent/runs/$run"; then
        status=$(jq -r '.status // "none"' "$BODY")
        run_status_record "$status" "$run" latestRunId
        return 0
      fi
    fi
  fi
  if ! api_try_get "/v1/agents/$agent/runs?limit=1"; then
    run_status_record unknown none resolution-failed "$API_ERROR"
    return 0
  fi
  status=$(jq -r '(.items // [])[0].status // "none"' "$BODY")
  run=$(jq -r '(.items // [])[0].id // "none"' "$BODY")
  if [ "$status" = none ]; then
    run_status_record none none none
  else
    run_status_record "$status" "$run" runs-list
  fi
}

# Display label for the agent's environment, which is where the work actually
# lives. A named environment prints its name; an agent created from a bare repo
# list has no name, so it prints as the ad-hoc case rather than as a blank that
# would read like missing data.
env_label() {  # <env-name> <env-type>
  if [ -n "$1" ]; then
    printf '%s' "$1"
  else
    printf '(ad-hoc %s)' "${2:-cloud}"
  fi
}

# Footer for an --env-narrowed view. Emitted whatever the match count is,
# including zero: Cursor's list endpoint has no environment filter, so --limit
# bounds the FETCH and a missing match may simply be on the next page. Reporting
# only "none found" would read as "this home has no cloud agents".
filtered_footer() {  # <matched> <fetched> <env-name>
  printf 'Filtered to environment %s: %s of %s fetched agent(s) match. --limit bounds the fetch, not the matches, so raise it if a match is missing.\n' \
    "$3" "$1" "$2"
  if [ "$1" -eq 0 ] && [ "$2" -gt 0 ]; then
    printf 'Agents were fetched, so this is not an empty fleet: none of the %s fetched is in %s. Drop --env to see every environment.\n' \
      "$2" "$3"
  fi
}

cmd_list() {
  local json=0 include_archived=false limit=20 resolve_runs=1 env_filter='' filtering=0
  local default_env
  default_env=$(default_environment)
  while [ "$#" -gt 0 ]; do
    case $1 in
      --json) json=1 ;;
      --all) include_archived=true ;;
      --no-runs) resolve_runs=0 ;;
      --env)
        # Optional argument: a bare --env means "this home's default".
        filtering=1
        if [ "$#" -ge 2 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ]; then
          env_filter=$2
          shift
        elif [ "$#" -ge 2 ] && [ -z "$2" ]; then
          # An empty name would quietly select the ad-hoc agents, whose envName is
          # "". Refuse instead of guessing which of the two was meant.
          die 2 "--env needs a non-empty environment name; omit the name to use this home's default"
        else
          [ -n "$default_env" ] || die 2 "--env with no name needs a default environment in $CONFIG/cursor-environment; pass --env <name> instead"
          env_filter=$default_env
        fi
        ;;
      --env=*)
        filtering=1
        env_filter=${1#--env=}
        [ -n "$env_filter" ] || die 2 "--env= needs a name"
        ;;
      --limit)
        [ "$#" -ge 2 ] || die 2 "--limit needs a value"
        valid_limit "$2" || die 2 "--limit must be a whole number from 1 to 100"
        limit=$2
        shift
        ;;
      --limit=*)
        valid_limit "${1#--limit=}" || die 2 "--limit must be a whole number from 1 to 100"
        limit=${1#--limit=}
        ;;
      *) die 2 "unknown option for list: $1" ;;
    esac
    shift
  done

  api_get "/v1/agents?limit=$limit&includeArchived=$include_archived"
  local agents fetched
  agents=$(jq -c '[(.items // [])[] | {
      id, name: (.name // ""), lifecycle: (.status // "UNKNOWN"),
      latestRunId: (.latestRunId // ""), createdAt: (.createdAt // ""),
      updatedAt: (.updatedAt // ""), url: (.url // ""),
      envType: (.env.type // ""), envName: (.env.name // ""),
      repos: [(.repos // [])[] | .url]
    }]' "$BODY")
  fetched=$(printf '%s' "$agents" | jq 'length')

  # Filter BEFORE resolving runs: run resolution costs one request per agent, so
  # narrowing first is the difference between one extra request and N.
  if [ "$filtering" -eq 1 ]; then
    agents=$(printf '%s' "$agents" | jq -c --arg e "$env_filter" 'map(select(.envName == $e))')
  fi

  # Resolve each agent's latest run one at a time. Serial on purpose: a burst of
  # parallel requests is the fastest way to meet the API's rate limiter. The ids
  # come out of one jq pass and the resolved records are stitched back on in one
  # more, rather than rebuilding the whole accumulating array once per agent.
  local resolved='[]'
  if [ "$resolve_runs" -eq 1 ]; then
    local statuses='' agent_id run_id record
    while IFS=$(printf '\t') read -r agent_id run_id; do
      # One record per line, unconditionally: the stitch below matches records to
      # agents by position, so skipping an unusable row would shift every status
      # after it onto the wrong agent.
      if valid_agent_id "$agent_id"; then
        record=$(latest_run_status "$agent_id" "$run_id")
      else
        record=$(run_status_record none none none)
      fi
      statuses="$statuses$record"$'\n'
    done <<EOF
$(printf '%s' "$agents" | jq -r '.[] | [.id, .latestRunId] | @tsv')
EOF
    resolved=$(printf '%s' "$agents" | jq -c --arg statuses "$statuses" '
      ($statuses | split("\n") | map(select(length > 0) | split("\u001f"))) as $t
      | to_entries
      | map(.value + {
          runStatus: $t[.key][0], runId: $t[.key][1], runStatusSource: $t[.key][2],
          runStatusReason: (if ($t[.key][3] // "") == "" then null else $t[.key][3] end)
        })')
  else
    resolved=$(printf '%s' "$agents" | jq -c \
      'map(. + {
        runStatus: "unresolved", runId: "", runStatusSource: "skipped",
        runStatusReason: null
      })')
  fi

  if [ "$json" -eq 1 ]; then
    printf '%s' "$resolved" | jq \
      --arg base "$API_BASE" --argjson archived "$include_archived" \
      --arg defaultEnv "$default_env" --arg envFilter "$env_filter" \
      --argjson fetched "$fetched" \
      --argjson resolvedRuns "$([ "$resolve_runs" -eq 1 ] && echo true || echo false)" '{
        schema: "fm-cursor-list.v1",
        base: $base,
        archivedIncluded: $archived,
        runsResolved: $resolvedRuns,
        defaultEnvironment: (if $defaultEnv == "" then null else $defaultEnv end),
        environmentFilter: (if $envFilter == "" then null else $envFilter end),
        fetched: $fetched,
        count: length,
        summary: {
          running: [.[] | select(.runStatus == "RUNNING" or .runStatus == "CREATING")] | length,
          multiRepo: [.[] | select((.repos | length) > 1)] | length,
          namedEnvironments: ([.[] | select(.envName != "") | .envName] | unique),
          byLifecycle: (group_by(.lifecycle) | map({key: .[0].lifecycle, value: length}) | from_entries),
          byRunStatus: (group_by(.runStatus) | map({key: .[0].runStatus, value: length}) | from_entries),
          byEnvironment: (group_by(.envName)
            | map({key: (if .[0].envName == "" then "(ad-hoc)" else .[0].envName end), value: length})
            | from_entries)
        },
        agents: .
      }'
    return 0
  fi

  # One pass for every count the footer needs, rather than one jq per number.
  local counts count running named unresolved
  counts=$(printf '%s' "$resolved" | jq -r '[
      length,
      ([.[] | select(.runStatus == "RUNNING" or .runStatus == "CREATING")] | length),
      ([.[] | select(.envName != "") | .envName] | unique | length),
      ([.[] | select(.runStatusSource == "resolution-failed")] | length)
    ] | @tsv')
  IFS=$(printf '\t') read -r count running named unresolved <<EOF
$counts
EOF

  if [ "$count" -eq 0 ]; then
    echo "No Cursor Cloud agents found."
    # An empty FILTERED view is a different fact from an empty fleet, and the
    # --limit caveat matters most exactly here: the match may be one page away.
    if [ "$filtering" -eq 1 ]; then
      filtered_footer "$count" "$fetched" "$env_filter"
    fi
    return 0
  fi

  # LIFECYCLE earns a column only with --all: without it every listed agent is
  # ACTIVE by construction, so the column would be a constant.
  local row_fmt='%-9s %-10s %-16s %-20s %5s  %s\n'
  if [ "$include_archived" = true ]; then
    row_fmt='%-9s %-10s %-9s %-16s %-20s %5s  %s\n'
    # shellcheck disable=SC2059  # row_fmt is a trusted local format string
    printf "$row_fmt" AGENT RUN LIFECYCLE UPDATED ENVIRONMENT REPOS NAME
  else
    # shellcheck disable=SC2059
    printf "$row_fmt" AGENT RUN UPDATED ENVIRONMENT REPOS NAME
  fi
  # One jq pass renders every cell, including the environment label, its
  # truncation, and the default marker, then the read loop only pads columns.
  # A unit separator rather than a tab, because tab is IFS whitespace to `read`
  # and an empty middle cell - an agent with no updatedAt - would collapse the
  # row by one column.
  local sep
  sep=$(printf '\037')
  # Truncate the environment label first, then append the default marker, so a
  # long environment name can never swallow the marker the way it would if the
  # assembled label were cut to width.
  printf '%s' "$resolved" | jq -r --arg defaultEnv "$default_env" '
    def trunc($w): if length > $w then .[0:($w - 3)] + "..." else . end;
    .[]
    | ((if .envName != "" then .envName
        else "(ad-hoc " + (if .envType != "" then .envType else "cloud" end) + ")" end)
       | trunc(18)) as $envl
    | [
        .id,
        .runStatus,
        (.lifecycle | ascii_downcase),
        (.updatedAt | gsub("T"; " ") | .[0:16]),
        (if $defaultEnv != "" and .envName == $defaultEnv then $envl + " *" else $envl end),
        (.repos | length | tostring),
        (.name | trunc(34))
      ] | join("\u001f")' |
  while IFS="$sep" read -r id run life upd envl repos name; do
    if [ "$include_archived" = true ]; then
      # shellcheck disable=SC2059
      printf "$row_fmt" "${id: -8}" "$run" "$life" "$upd" "$envl" "$repos" "$name"
    else
      # shellcheck disable=SC2059
      printf "$row_fmt" "${id: -8}" "$run" "$upd" "$envl" "$repos" "$name"
    fi
  done

  echo
  printf '%s agent(s) shown, %s with a run in flight' "$count" "$running"
  [ "$named" -eq 0 ] || printf ', across %s named environment(s)' "$named"
  printf '.\n'
  if [ "$filtering" -eq 1 ]; then
    filtered_footer "$count" "$fetched" "$env_filter"
  fi
  if [ "$resolve_runs" -eq 1 ]; then
    echo 'RUN is the latest run status and is what says whether work is happening.'
    if [ "$unresolved" -gt 0 ]; then
      printf 'RUN is unknown for %s agent(s) whose latest run could not be fetched; every other row is unaffected.\n' \
        "$unresolved"
      # Name the reasons, grouped, so a mid-listing 429 reads as rate limiting and
      # can never look identical to a rejected key or to runs that are simply gone.
      printf '%s' "$resolved" | jq -r '
        [.[] | select(.runStatusSource == "resolution-failed")
             | (.runStatusReason // "no reason reported")]
        | group_by(.) | map({reason: .[0], n: length}) | sort_by(-.n)[]
        | "  " + (.n | tostring) + " of them: " + .reason'
    fi
  else
    echo 'RUN was not resolved (--no-runs), so nothing here says whether work is happening.'
  fi
  if [ "$include_archived" = true ]; then
    echo 'LIFECYCLE active means "not archived" - a finished agent stays active until archived.'
  else
    echo 'Every agent listed is unarchived, which says nothing about whether it ran; pass --all to include archived ones.'
  fi
  echo 'ENVIRONMENT is where the work runs and carries that environment'"'"'s repositories and secrets; REPOS is how many repositories it spans.'
  echo 'An agent belongs to its environment, not to any single repository; use show for the repository list.'
  if [ -n "$default_env" ]; then
    if [ "$filtering" -eq 1 ]; then
      printf '* marks this home'"'"'s default environment, %s, from config/cursor-environment.\n' "$default_env"
    else
      printf '* marks this home'"'"'s default environment, %s, from config/cursor-environment; every environment is still listed.\n' "$default_env"
      printf 'Pass --env to narrow to %s, or --env <name> for another environment.\n' "$default_env"
    fi
  fi
  printf 'Agent ids are shown short; use the full id from --json with show, runs, or usage.\n'
}

cmd_show() {
  local json=0 agent=''
  while [ "$#" -gt 0 ]; do
    case $1 in
      --json) json=1 ;;
      -*) die 2 "unknown option for show: $1" ;;
      *)
        [ -z "$agent" ] || die 2 "show takes exactly one agent id"
        agent=$1
        ;;
    esac
    shift
  done
  [ -n "$agent" ] || die 2 "show needs an agent id (see: fm-cursor.sh list)"
  valid_agent_id "$agent" || die 2 "not a valid agent id: $agent"

  api_get "/v1/agents/$agent"
  local agent_json
  agent_json=$(jq -c '.' "$BODY")
  read_run_status_record \
    "$(latest_run_status "$agent" "$(printf '%s' "$agent_json" | jq -r '.latestRunId // ""')")"

  if [ "$json" -eq 1 ]; then
    printf '%s' "$agent_json" | jq \
      --arg s "$RUN_STATUS" --arg r "$RUN_ID" --arg src "$RUN_SOURCE" \
      --arg reason "$RUN_REASON" '{
        schema: "fm-cursor-show.v1",
        latestRun: {
          status: $s, id: $r, source: $src,
          reason: (if $reason == "" then null else $reason end)
        },
        agent: .
      }'
    return 0
  fi

  local env_name env_type repo_count
  env_name=$(printf '%s' "$agent_json" | jq -r '.env.name // ""')
  env_type=$(printf '%s' "$agent_json" | jq -r '.env.type // ""')
  repo_count=$(printf '%s' "$agent_json" | jq '(.repos // []) | length')

  printf '%s\n' "$(printf '%s' "$agent_json" | jq -r '.name // "(unnamed)"')"
  printf '  id           %s\n' "$(printf '%s' "$agent_json" | jq -r '.id')"
  printf '  environment  %s (%s)\n' "$(env_label "$env_name" "$env_type")" "${env_type:-unknown}"
  if [ -n "$RUN_REASON" ]; then
    printf '  latest run   %s (%s)\n' "$RUN_STATUS" "$RUN_REASON"
  else
    printf '  latest run   %s\n' "$RUN_STATUS"
  fi
  printf '  lifecycle    %s\n' "$(printf '%s' "$agent_json" | jq -r '.status // "UNKNOWN" | ascii_downcase')"
  printf '  created      %s\n' "$(printf '%s' "$agent_json" | jq -r '.createdAt // "-"')"
  printf '  updated      %s\n' "$(printf '%s' "$agent_json" | jq -r '.updatedAt // "-"')"
  printf '  url          %s\n' "$(printf '%s' "$agent_json" | jq -r '.url // "-"')"
  printf '  repositories %s in this environment\n' "$repo_count"
  printf '%s' "$agent_json" | jq -r '(.repos // [])[] | "                 " + .url'
  echo
  if [ -n "$env_name" ]; then
    printf 'This agent runs in the %s environment, which carries its own repositories and secrets; it does not belong to any single repository.\n' "$env_name"
    local default_env
    default_env=$(default_environment)
    if [ -n "$default_env" ] && [ "$env_name" = "$default_env" ]; then
      echo 'That is this home'"'"'s default environment from config/cursor-environment.'
    fi
  else
    echo 'This agent was created from a repository list rather than a named environment, so it carries no predefined environment secrets.'
  fi
  echo 'lifecycle active means "not archived"; the latest run status above is what says whether work is happening.'
  if [ -n "$RUN_REASON" ]; then
    echo 'That latest run status is unknown because the request for it failed, not because the agent is idle; everything above it came back fine.'
  fi
}

cmd_runs() {
  local json=0 agent='' limit=20
  while [ "$#" -gt 0 ]; do
    case $1 in
      --json) json=1 ;;
      --limit)
        [ "$#" -ge 2 ] || die 2 "--limit needs a value"
        valid_limit "$2" || die 2 "--limit must be a whole number from 1 to 100"
        limit=$2
        shift
        ;;
      --limit=*)
        valid_limit "${1#--limit=}" || die 2 "--limit must be a whole number from 1 to 100"
        limit=${1#--limit=}
        ;;
      -*) die 2 "unknown option for runs: $1" ;;
      *)
        [ -z "$agent" ] || die 2 "runs takes exactly one agent id"
        agent=$1
        ;;
    esac
    shift
  done
  [ -n "$agent" ] || die 2 "runs needs an agent id (see: fm-cursor.sh list)"
  valid_agent_id "$agent" || die 2 "not a valid agent id: $agent"

  api_get "/v1/agents/$agent/runs?limit=$limit"
  if [ "$json" -eq 1 ]; then
    jq --arg a "$agent" '{
      schema: "fm-cursor-runs.v1",
      agentId: $a,
      count: ((.items // []) | length),
      runs: [(.items // [])[] | {
        id, status, createdAt, updatedAt, durationMs,
        branches: [(.git.branches // [])[] | {repoUrl, branch, prUrl}]
      }]
    }' "$BODY"
    return 0
  fi

  local count
  count=$(jq '(.items // []) | length' "$BODY")
  if [ "$count" -eq 0 ]; then
    echo "No runs on this agent yet."
    return 0
  fi
  printf '%-9s %-10s %-16s %-9s %s\n' RUN STATUS STARTED DURATION PR
  jq -r '
    def dur: if . == null then "-"
      else (. / 1000 | floor) as $s
        | if $s < 60 then ($s | tostring) + "s"
          else (($s / 60 | floor) | tostring) + "m" + (($s % 60) | tostring) + "s" end
      end;
    (.items // [])[] | [
      (.id // "-"), (.status // "-"), (.createdAt // "-"), (.durationMs | dur),
      ([(.git.branches // [])[] | .prUrl // empty] | if length == 0 then "-" else join(" ") end)
    ] | @tsv' "$BODY" |
  while IFS=$(printf '\t') read -r rid status started dur pr; do
    printf '%-9s %-10s %-16s %-9s %s\n' \
      "${rid: -8}" "$status" "$(printf '%s' "$started" | tr T ' ' | cut -c1-16)" "$dur" "$pr"
  done
  echo
  echo 'Each follow-up prompt to an agent is a new run; only one run can be active at a time.'
  echo 'A PR URL belongs to the pull request itself, not necessarily to the first repository listed for the agent.'
  echo 'Run ids are shown short; use --json for the full ids.'
}

cmd_usage() {
  local json=0 agent=''
  while [ "$#" -gt 0 ]; do
    case $1 in
      --json) json=1 ;;
      -*) die 2 "unknown option for usage: $1" ;;
      *)
        [ -z "$agent" ] || die 2 "usage takes exactly one agent id"
        agent=$1
        ;;
    esac
    shift
  done
  [ -n "$agent" ] || die 2 "usage needs an agent id (see: fm-cursor.sh list)"
  valid_agent_id "$agent" || die 2 "not a valid agent id: $agent"

  api_get "/v1/agents/$agent/usage"
  if [ "$json" -eq 1 ]; then
    # costAvailable is a capability fact, not an opinion: the Cloud Agents API
    # exposes no price or charge field anywhere, so a consumer should not hunt
    # for one. Money lives only on the Admin API, behind an admin-only key.
    jq --arg a "$agent" '{
      schema: "fm-cursor-usage.v1",
      agentId: $a,
      costAvailable: false,
      totalUsage: (.totalUsage // {}),
      runs: [(.runs // [])[] | {id, usage}]
    }' "$BODY"
    return 0
  fi

  printf 'Token usage for %s across %s run(s)\n' "$agent" "$(jq '(.runs // []) | length' "$BODY")"
  jq -r '(.totalUsage // {}) | to_entries[] | [.key, (.value | tostring)] | @tsv' "$BODY" |
  while IFS=$(printf '\t') read -r label value; do
    printf '  %-17s %s\n' "$label" "$value"
  done
  echo
  echo 'Cursor reports tokens only; this API exposes no cost figure, so firstmate cannot report spend here.'
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
SUB=$1
shift
case $SUB in
  -h|--help|help) usage; exit 0 ;;
  list|show|runs|usage) ;;
  *) die 2 "unknown subcommand: $SUB (expected list, show, runs, or usage)" ;;
esac

require_tools
arm_auth
"cmd_$SUB" "$@"
