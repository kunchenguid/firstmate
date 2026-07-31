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
# `runs?limit=1` fallback covers its absence and the JSON output records which
# source answered in `runStatusSource`.
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
#   FM_CURSOR_TIMEOUT     per-request timeout in seconds (default 30)
#
# Exit status:
#   0  success
#   2  usage error
#   3  not configured (no CURSOR_API_KEY) or a required tool is missing
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
  umask 077
  CFG=$(mktemp "${TMPDIR:-/tmp}/.fm-cursor-auth.XXXXXX") \
    || die 3 "could not create a private file for the API key"
  chmod 600 "$CFG" || die 3 "could not restrict permissions on the API key file"
  printf 'header = "Authorization: Bearer %s"\nsilent\nshow-error\nmax-time = %s\n' \
    "$token" "$TIMEOUT" > "$CFG" || die 3 "could not write the API key file"
  BODY=$(mktemp "${TMPDIR:-/tmp}/.fm-cursor-body.XXXXXX") \
    || die 3 "could not create a response file"
}

# GET <path>; leaves the response body in $BODY. Fails loudly with the API's own
# message, never with raw headers.
api_get() {  # <path>
  local path=$1 code
  code=$(curl --config "$CFG" -o "$BODY" -w '%{http_code}' "$API_BASE$path" 2>/dev/null) || code=000
  case $code in
    200) return 0 ;;
    000) die 4 "could not reach ${API_BASE} (network, proxy, or timeout after ${TIMEOUT}s)" ;;
    401|403) die 4 "the Cursor API rejected the key (HTTP $code)$(api_message). Check CURSOR_API_KEY, or regenerate it at https://cursor.com/dashboard/api" ;;
    404) die 4 "not found (HTTP 404)$(api_message)" ;;
    429) die 4 "rate limited by the Cursor API (HTTP 429)$(api_message). Retry in a minute" ;;
    *) die 4 "the Cursor API returned HTTP $code$(api_message)" ;;
  esac
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

# Latest run status for one agent. Echoes "<status> <runId> <source>".
# Prefers the caller-supplied latestRunId, falls back to the runs list, and
# reports "none none none" for an agent that has no run yet.
latest_run_status() {  # <agent-id> <latest-run-id-or-empty>
  local agent=$1 run=$2 status
  if [ -n "$run" ] && [ "$run" != null ]; then
    if valid_agent_id "$run"; then
      api_get "/v1/agents/$agent/runs/$run"
      status=$(jq -r '.status // "none"' "$BODY")
      printf '%s %s %s' "$status" "$run" latestRunId
      return 0
    fi
  fi
  api_get "/v1/agents/$agent/runs?limit=1"
  status=$(jq -r '(.items // [])[0].status // "none"' "$BODY")
  run=$(jq -r '(.items // [])[0].id // "none"' "$BODY")
  if [ "$status" = none ]; then
    printf 'none none none'
  else
    printf '%s %s %s' "$status" "$run" runs-list
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

trunc() {  # <string> <width>
  local s=$1 w=$2
  if [ "${#s}" -gt "$w" ]; then
    printf '%s...' "${s:0:$((w - 3))}"
  else
    printf '%s' "$s"
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
  # parallel requests is the fastest way to meet the API's rate limiter.
  local resolved='[]'
  if [ "$resolve_runs" -eq 1 ]; then
    local n i row agent_id run_id triple
    n=$(printf '%s' "$agents" | jq 'length')
    i=0
    while [ "$i" -lt "$n" ]; do
      row=$(printf '%s' "$agents" | jq -c ".[$i]")
      agent_id=$(printf '%s' "$row" | jq -r '.id')
      run_id=$(printf '%s' "$row" | jq -r '.latestRunId')
      if valid_agent_id "$agent_id"; then
        triple=$(latest_run_status "$agent_id" "$run_id")
      else
        triple='none none none'
      fi
      # shellcheck disable=SC2086  # triple is three space-free tokens by construction
      set -- $triple
      resolved=$(printf '%s' "$resolved" | jq -c \
        --argjson row "$row" --arg s "$1" --arg r "$2" --arg src "$3" \
        '. + [$row + {runStatus: $s, runId: $r, runStatusSource: $src}]')
      i=$((i + 1))
    done
  else
    resolved=$(printf '%s' "$agents" | jq -c \
      'map(. + {runStatus: "unresolved", runId: "", runStatusSource: "skipped"})')
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

  local count
  count=$(printf '%s' "$resolved" | jq 'length')
  if [ "$count" -eq 0 ]; then
    echo "No Cursor Cloud agents found."
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
  local i=0 row
  while [ "$i" -lt "$count" ]; do
    row=$(printf '%s' "$resolved" | jq -c ".[$i]")
    local id run life upd envl repos name
    id=$(printf '%s' "$row" | jq -r '.id')
    run=$(printf '%s' "$row" | jq -r '.runStatus')
    life=$(printf '%s' "$row" | jq -r '.lifecycle | ascii_downcase')
    upd=$(printf '%s' "$row" | jq -r '.updatedAt' | tr T ' ' | cut -c1-16)
    local env_name
    env_name=$(printf '%s' "$row" | jq -r '.envName')
    envl=$(env_label "$env_name" "$(printf '%s' "$row" | jq -r '.envType')")
    # Truncate first, then append the default marker, so a long environment name
    # can never swallow the marker the way it would if the assembled label were
    # cut to width.
    envl=$(trunc "$envl" 18)
    if [ -n "$default_env" ] && [ "$env_name" = "$default_env" ]; then
      envl="$envl *"
    fi
    repos=$(printf '%s' "$row" | jq -r '.repos | length')
    name=$(printf '%s' "$row" | jq -r '.name')
    if [ "$include_archived" = true ]; then
      # shellcheck disable=SC2059
      printf "$row_fmt" "${id: -8}" "$run" "$life" "$upd" "$envl" "$repos" "$(trunc "$name" 34)"
    else
      # shellcheck disable=SC2059
      printf "$row_fmt" "${id: -8}" "$run" "$upd" "$envl" "$repos" "$(trunc "$name" 34)"
    fi
    i=$((i + 1))
  done

  local running named
  running=$(printf '%s' "$resolved" | jq '[.[] | select(.runStatus == "RUNNING" or .runStatus == "CREATING")] | length')
  named=$(printf '%s' "$resolved" | jq -r '[.[] | select(.envName != "") | .envName] | unique | length')
  echo
  printf '%s agent(s) shown, %s with a run in flight' "$count" "$running"
  [ "$named" -eq 0 ] || printf ', across %s named environment(s)' "$named"
  printf '.\n'
  if [ "$filtering" -eq 1 ]; then
    printf 'Filtered to environment %s: %s of %s fetched agent(s) match. --limit bounds the fetch, not the matches, so raise it if a match is missing.\n' \
      "$env_filter" "$count" "$fetched"
  fi
  if [ "$resolve_runs" -eq 1 ]; then
    echo 'RUN is the latest run status and is what says whether work is happening.'
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
  local agent_json triple
  agent_json=$(jq -c '.' "$BODY")
  triple=$(latest_run_status "$agent" "$(printf '%s' "$agent_json" | jq -r '.latestRunId // ""')")
  # shellcheck disable=SC2086  # triple is three space-free tokens by construction
  set -- $triple

  if [ "$json" -eq 1 ]; then
    printf '%s' "$agent_json" | jq \
      --arg s "$1" --arg r "$2" --arg src "$3" '{
        schema: "fm-cursor-show.v1",
        latestRun: {status: $s, id: $r, source: $src},
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
  printf '  latest run   %s\n' "$1"
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
