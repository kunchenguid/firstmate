#!/usr/bin/env bash
# Quota-exhaustion process-event adapter.
#
# Usage:
#   fm-procevent-quota.sh arm [--interval <secs>] [--threshold <percent>] [--provider <provider>] [--codex-home <path>]
#   fm-procevent-quota.sh poll [--interval <secs>] [--threshold <percent>] [--provider <provider>] [--codex-home <path>] [--timeout <secs>]
#   fm-procevent-quota.sh classify <result-file>
#   fm-procevent-quota.sh terminal <result-file>
#   fm-procevent-quota.sh source-id [--provider <provider>] [--codex-home <path>]
#   fm-procevent-quota.sh retire [--provider <provider>] [--codex-home <path>]
#
# arm        Register a recurring quota-axi --json poll that wakes firstmate
#            when the tracked provider's effectivePercentRemaining drops below
#            <threshold> (default 10%) or when its runway.status becomes
#            exhausted_now. The condition is deterministic, the action is only
#            the durable `check: procevent:quota:<seq>` wake, and the watch is
#            registered through `bin/fm-procevent.sh register`.
# poll       The blocking child the generic runner executes; never run this
#            directly in a conversational turn. It polls `quota-axi --json`
#            until quota drops below the threshold or an error stops the watch.
# classify   Print the captured outcome class: low, exhausted, error, or unknown.
# terminal   Every quota poll is terminal because the source fires at most once.
# source-id  Print the canonical source id.
# retire     Stop the aggregate watch, or the matching provider watch when
#            --provider is supplied, and retire the registration.
#
# The canonical source id is `quota` for the aggregate tracked provider.
# A provider named with --provider sets the tracked provider and the source id
# becomes `quota-<provider>`.
#
# --codex-home <path> is the Codex ACCOUNT axis, the same axis fm-spawn.sh
# launches a worker on: the directory holding the auth.json of the ChatGPT
# account whose quota this watch tracks. quota-axi reads that account from
# CODEX_HOME exactly as the codex CLI does, so a watch armed without the flag
# reports the ambient ~/.codex account and is no evidence for a worker
# launched on ~/.codex-3. The flag is accepted only with --provider codex, may
# be absolute or `~/`-prefixed (`~/` expands against this user's $HOME), and
# arm refuses a directory with no non-empty auth.json before registering
# anything (bin/fm-codex-home-lib.sh owns that check). Each poll reads through
# bin/fm-quota-axi-lib.sh's fm_quota_axi_read_codex_home, so an account that
# is signed out mid-watch ends the watch with an error wake rather than
# silently reporting the default account. The source id becomes
# `quota-codex-<basename>-<8 hex of the physical path>`, one watch per account
# even when callers use path aliases, and the result document adds a
# `codex_home: <physical path>` line.
# Without the flag the registration, the poll, and the result are byte-identical
# to before.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

DEFAULT_INTERVAL=60
DEFAULT_THRESHOLD=10

SOURCE_ID_BASE=quota

CANONICAL_SOURCE_ID=
PROVIDER=
CODEX_HOME_ARG=
CODEX_HOME_RESOLVED=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

resolve_provider() {
  local LC_ALL=C
  PROVIDER=${1:-}
  if [ -n "$PROVIDER" ]; then
    [[ "$PROVIDER" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "invalid provider: $PROVIDER"
    CANONICAL_SOURCE_ID="$SOURCE_ID_BASE-$PROVIDER"
  else
    CANONICAL_SOURCE_ID=$SOURCE_ID_BASE
    PROVIDER=
  fi
  fm_procevent_source_id_valid "$CANONICAL_SOURCE_ID" || die "source id is not path-safe: $CANONICAL_SOURCE_ID"
}

# codex_home_slug <physical-path>
# A path-safe, unique-per-account tail for the source id: the home's basename
# (leading dots dropped, unsafe bytes folded to dashes, bounded) plus a short
# digest of the whole path so two accounts sharing a basename never share a
# watch.
codex_home_slug() {
  local path=$1 base hash
  local LC_ALL=C
  base=${path##*/}
  base=${base#"${base%%[!.]*}"}
  base=$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-32)
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$path" | shasum -a 256 | awk '{print substr($1,1,8)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$path" | sha256sum | awk '{print substr($1,1,8)}')
  else
    hash=$(printf '%s' "$path" | cksum | awk '{printf "%08x", $1}')
  fi
  printf '%s%s\n' "${base:+$base-}" "$hash"
}

# resolve_codex_home
# Binds the Codex account axis after resolve_provider: expands --codex-home,
# requires --provider codex, and derives the per-account source id. Existence
# of the account is checked separately (arm before registering, every poll
# before reading) so retire and source-id still resolve a signed-out account.
resolve_codex_home() {
  CODEX_HOME_RESOLVED=
  [ -n "$CODEX_HOME_ARG" ] || return 0
  [ "$PROVIDER" = codex ] || die "--codex-home applies only to --provider codex; this watch tracks ${PROVIDER:-the aggregate}"
  fm_codex_home_expand "$CODEX_HOME_ARG" || die "--codex-home refused: $FM_CODEX_HOME_ERROR"
  CODEX_HOME_RESOLVED=$FM_CODEX_HOME_PATH
  CANONICAL_SOURCE_ID="$SOURCE_ID_BASE-codex-$(codex_home_slug "$CODEX_HOME_RESOLVED")"
  fm_procevent_source_id_valid "$CANONICAL_SOURCE_ID" || die "source id is not path-safe: $CANONICAL_SOURCE_ID"
}

positive_number() {
  local n=${1-}
  local LC_ALL=C
  [[ "$n" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  [ "$n" != 0 ] && [[ ! "$n" =~ ^0+(\.0+)?$ ]]
}

positive_int() { case "${1-}" in ''|*[!0-9]*) return 1 ;; 0) return 1 ;; *) return 0 ;; esac }

valid_percent() {
  local n=${1-}
  local LC_ALL=C
  [[ "$n" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  jq -en --arg n "$n" '($n | tonumber) <= 100' >/dev/null 2>&1
}

# quota_json [timeout]
# Run `quota-axi --json` bounded by the given timeout, under the selected Codex
# account's CODEX_HOME when one was armed. A missing or incompatible quota-axi,
# or a selected account with no non-empty auth.json, is an error condition, not
# a signal to fire.
quota_json() {
  local timeout=${1:-} output
  if [ -n "$timeout" ]; then
    fm_quota_axi_compatible "$timeout" >/dev/null 2>&1 || return 2
    if [ -n "$CODEX_HOME_RESOLVED" ]; then
      output=$(fm_quota_axi_read_codex_home --timeout "$timeout" "$CODEX_HOME_RESOLVED" --json 2>/dev/null) || return 2
    else
      output=$(fm_run_timed "$timeout" quota-axi --json 2>/dev/null </dev/null) || return 2
    fi
  else
    fm_quota_axi_compatible >/dev/null 2>&1 || return 2
    if [ -n "$CODEX_HOME_RESOLVED" ]; then
      output=$(fm_quota_axi_read_codex_home "$CODEX_HOME_RESOLVED" --json 2>/dev/null) || return 2
    else
      output=$(quota-axi --json 2>/dev/null </dev/null) || return 2
    fi
  fi
  printf '%s\n' "$output"
}

# read_failure_detail
# One line naming why quota_json failed, so an account that was signed out
# mid-watch is reported as that rather than as a generic quota-axi failure.
read_failure_detail() {
  if [ -n "$CODEX_HOME_RESOLVED" ] && ! fm_codex_home_validate "$CODEX_HOME_RESOLVED"; then
    printf 'codex quota read refused: %s\n' "$FM_CODEX_HOME_ERROR"
  else
    printf 'quota-axi --json failed or quota-axi is missing/incompatible\n'
  fi
}

# condition_status <json> [provider] [threshold]
# Print healthy, low, exhausted, or error for the tightest known applicable
# quota scope.
condition_status() {
  local json=$1 provider=${2:-} threshold=${3:-$DEFAULT_THRESHOLD}
  printf '%s\n' "$json" | fm_quota_json_valid || { printf 'error\n'; return; }
  printf '%s\n' "$json" | jq -r --arg provider "$provider" --arg threshold "$threshold" '
    def classify($availability):
      ($availability | map(select(.status == "known"))) as $known |
      if ($availability | length) == 0 then "error"
      elif any($availability[]; (.runway.status // "") == "exhausted_now") then "exhausted"
      elif ($known | length) == 0 then "healthy"
      elif any($known[]; .effectivePercentRemaining < ($threshold | tonumber)) then "low"
      else "healthy"
      end;
    if (.providers | type) != "array" then "error"
    elif $provider == "" then
      if (.providers | length) == 0 then "healthy"
      elif ([.providers[]?.quotaSemantics.effectiveAvailability[]?] | length) == 0 then "healthy"
      else classify([.providers[]?.quotaSemantics.effectiveAvailability[]?])
      end
    else
      ([.providers[]? | select(.provider == $provider)] | first) as $p |
      if ($p // null) == null then "error"
      elif ($p.quotaSemantics.effectiveAvailability | length) == 0 and
           ($p.quotaSemantics.status == "unknown" or $p.quotaSemantics.status == "partial") then "healthy"
      else classify($p.quotaSemantics.effectiveAvailability // [])
      end
    end
  ' 2>/dev/null || printf 'error\n'
}

# details <json> [provider]
# Print a one-line summary of the quota state for the result document.
details() {
  local json=$1 provider=${2:-}
  printf '%s\n' "$json" | jq -c --arg provider "$provider" '
    def best_detail($availability):
      ($availability | map(select(.status == "known"))) as $known |
      ($availability | map(select((.runway.status // "") == "exhausted_now"))) as $exhausted |
      if ($exhausted | length) > 0 then ($exhausted | min_by(.effectivePercentRemaining // 101))
      elif ($known | length) > 0 then ($known | min_by(.effectivePercentRemaining))
      else null
      end;
    if $provider == "" then
      {
        provider: "aggregate",
        summary: [
          (.providers[]? |
            { provider: .provider,
              best: best_detail(.quotaSemantics.effectiveAvailability // [])
            }
          )
        ]
      }
    else
      (.providers[]? | select(.provider == $provider)) as $p |
      {
        provider: $provider,
        best: best_detail($p.quotaSemantics.effectiveAvailability // [])
      }
    end
  ' 2>/dev/null
}

# parse_scope_args <args...>
# Shared by source-id and retire: an optional provider (positional or
# --provider) plus the optional --codex-home account.
parse_scope_args() {
  local provider=
  CODEX_HOME_ARG=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --provider)   [ -n "${2-}" ] || die "--provider needs a value"; provider=$2; shift 2 ;;
      --codex-home) [ -n "${2-}" ] || die "--codex-home needs a value"; CODEX_HOME_ARG=$2; shift 2 ;;
      -*) usage ;;
      *) [ -z "$provider" ] || usage; provider=$1; shift ;;
    esac
  done
  resolve_provider "$provider"
  resolve_codex_home
}

cmd_source_id() {
  parse_scope_args "$@"
  printf '%s\n' "$CANONICAL_SOURCE_ID"
}

cmd_arm() {
  local interval=$DEFAULT_INTERVAL threshold=$DEFAULT_THRESHOLD
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval)  positive_number "${2-}" || die "--interval needs a positive number"; interval=$2; shift 2 ;;
      --threshold) valid_percent "${2-}" || die "--threshold needs a percent 0-100"; threshold=$2; shift 2 ;;
      --provider)  [ -n "${2-}" ] || die "--provider needs a value"; resolve_provider "$2"; shift 2 ;;
      --codex-home) [ -n "${2-}" ] || die "--codex-home needs a value"; CODEX_HOME_ARG=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  resolve_provider "$PROVIDER"
  resolve_codex_home
  local account=()
  if [ -n "$CODEX_HOME_RESOLVED" ]; then
    fm_codex_home_validate "$CODEX_HOME_RESOLVED" || die "--codex-home refused: $FM_CODEX_HOME_ERROR"
    account=(--codex-home "$CODEX_HOME_RESOLVED")
  fi
  fm_quota_axi_compatible 5 >/dev/null 2>&1 || die "quota-axi is missing or below the compatibility floor"
  local timeout
  timeout=$(perl -e 'print int($ARGV[0] * 0.8 + 0.5)' "$interval") || timeout=30
  [ "$timeout" -ge 5 ] || timeout=5
  "$SCRIPT_DIR/fm-procevent.sh" register quota "$CANONICAL_SOURCE_ID" \
    -- "$SCRIPT_DIR/fm-procevent-quota.sh" poll --interval "$interval" --threshold "$threshold" --provider "$PROVIDER" ${account[@]+"${account[@]}"} --timeout "$timeout" || exit 1
  printf 'armed: %s\n' "$CANONICAL_SOURCE_ID"
  printf 'provider: %s\n' "${PROVIDER:-(aggregate)}"
  [ -z "$CODEX_HOME_RESOLVED" ] || printf 'codex_home: %s\n' "$CODEX_HOME_RESOLVED"
  printf 'threshold: %s%%\n' "$threshold"
  printf 'interval: %ss\n' "$interval"
}

# For use inside the runner: parse the spec argv and run one condition evaluation.
# This is intentionally not the public `arm` path; the runner calls this command
# directly, so the argv must match the registration.
cmd_poll() {
  local interval=$DEFAULT_INTERVAL threshold=$DEFAULT_THRESHOLD timeout=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval)  [ "$#" -ge 2 ] || die "--interval needs a positive number"; interval=$2; shift 2 ;;
      --threshold) [ "$#" -ge 2 ] || die "--threshold needs a percent 0-100"; threshold=$2; shift 2 ;;
      --provider)  [ "$#" -ge 2 ] || die "--provider needs a value"; PROVIDER=$2; shift 2 ;;
      --codex-home) [ "$#" -ge 2 ] || die "--codex-home needs a value"; CODEX_HOME_ARG=$2; shift 2 ;;
      --timeout)   [ "$#" -ge 2 ] || die "--timeout needs a positive integer"; timeout=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  positive_number "$interval" || die "--interval needs a positive number"
  valid_percent "$threshold" || die "--threshold needs a percent 0-100"
  [ -z "$timeout" ] || positive_int "$timeout" || die "--timeout needs a positive integer"
  resolve_provider "$PROVIDER"
  resolve_codex_home
  local json detail status polls=0
  while :; do
    polls=$((polls + 1))
    if ! json=$(quota_json "${timeout:-}"); then
      printf 'quota: %s\n' "$CANONICAL_SOURCE_ID"
      [ -z "$CODEX_HOME_RESOLVED" ] || printf 'codex_home: %s\n' "$CODEX_HOME_RESOLVED"
      printf 'status: error\n'
      printf 'detail: %s\n' "$(read_failure_detail)"
      printf 'condition_polls: %s\n' "$polls"
      exit 0
    fi
    status=$(condition_status "$json" "$PROVIDER" "$threshold")
    case "$status" in
      healthy) sleep "$interval"; continue ;;
      low|exhausted) : ;;
      *) status=error ;;
    esac
    detail=$(details "$json" "$PROVIDER")
    printf 'quota: %s\n' "$CANONICAL_SOURCE_ID"
    [ -z "$CODEX_HOME_RESOLVED" ] || printf 'codex_home: %s\n' "$CODEX_HOME_RESOLVED"
    printf 'status: %s\n' "$status"
    printf 'detail: %s\n' "$detail"
    printf 'condition_polls: %s\n' "$polls"
    exit 0
  done
}

cmd_classify() {
  local file=${1-} status
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(awk '
    $0 == "output:" { exit }
    /^status: / { sub(/^status: /, ""); print; exit }
  ' "$file")
  case "$status" in
    low|exhausted|error) printf '%s\n' "$status" ;;
    *) printf 'unknown\n' ;;
  esac
}

cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  [ "$(cmd_classify "$file")" != unknown ]
}

cmd_retire() {
  parse_scope_args "$@"
  "$SCRIPT_DIR/fm-procevent.sh" retire "$CANONICAL_SOURCE_ID"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
