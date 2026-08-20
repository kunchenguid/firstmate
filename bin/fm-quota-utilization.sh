#!/usr/bin/env bash
# Report weekly quota utilization from existing quota-axi readers.
# Usage: fm-quota-utilization.sh [--snapshot FILE]... [--observations FILE]
#        [--json] [--intake] [--provider NAME] [--accounts-from-config]
#        [report|outcomes]
#
# This is the single owner of the fleet weekly utilization check. It reuses
# quota-axi snapshots and never creates a daemon, dashboard, auto-tuner, second
# router, or work-holding gate. quota-axi remains data-only.
#
# Widget metric, matching the personal/public ai-quota-widget design: for each
# account, utilization percent is percentUsed of that account's tightest
# all_models window, plus the reset countdown to that window's resetsAt.
# Account-wide weekly windows bind every model. Named-model windows are
# additional bounds. A short idle session window is not spare capacity when the
# binding weekly window is ahead of pace.
#
# Default `report` prints one line per account and one degrade line per skipped
# source. `--intake` is a named alias of `--json` for the routing consumer: both
# emit the same computed object, which already names the healthier
# binding-weekly reserve among reported accounts so routing can use it as a
# later equivalent-fit tie-break. `outcomes` prints the
# end-of-window table from `--observations` JSONL: expired unused percent versus
# exhausted-early seconds. holdReadyWork and weakenReasoningClass are always
# false.
#
# Alternate account homes: `--accounts-from-config` reads
# config/claude-account-profiles and runs quota-axi once per mapped
# CLAUDE_CONFIG_DIR. Ambient CODEX_HOME is forwarded unchanged because quota-axi
# already reads $CODEX_HOME/auth.json. Missing or failed readers print
# `quota: <source> skipped: <exact cause>` and the command still exits 0.
# `--provider NAME` scopes the live read, the Claude profile loop, the reported
# accounts, and the observations the outcomes table covers.
# `--snapshot` replaces live quota-axi for tests. FM_QUOTA_UTILIZATION_NOW is a
# test-only fixed ISO-8601 clock. FM_QUOTA_UTILIZATION_TIMEOUT bounds each live
# quota-axi call, default 8 seconds.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
COMPUTE="$SCRIPT_DIR/fm-quota-utilization.mjs"

SNAPSHOTS=()
OBSERVATIONS=
FORMAT=text
MODE=report
PROVIDER=
ACCOUNTS_FROM_CONFIG=0
TIMEOUT=${FM_QUOTA_UTILIZATION_TIMEOUT:-8}

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --snapshot)
      [ $# -ge 2 ] || { echo "error: --snapshot requires a file" >&2; exit 2; }
      SNAPSHOTS+=("$2")
      shift 2
      ;;
    --observations)
      [ $# -ge 2 ] || { echo "error: --observations requires a file" >&2; exit 2; }
      OBSERVATIONS=$2
      shift 2
      ;;
    --json)
      FORMAT=json
      shift
      ;;
    --intake)
      MODE=intake
      FORMAT=json
      shift
      ;;
    --provider)
      [ $# -ge 2 ] || { echo "error: --provider requires a name" >&2; exit 2; }
      PROVIDER=$2
      shift 2
      ;;
    --accounts-from-config)
      ACCOUNTS_FROM_CONFIG=1
      shift
      ;;
    report|outcomes)
      MODE=$1
      shift
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# A non-positive bound is not a bound: `timeout 0` and the Perl fallback's
# `alarm 0` both disable the deadline, so a hung quota-axi would run unbounded.
case "$TIMEOUT" in
  ''|*[!0-9]*|0*) TIMEOUT=8 ;;
esac

now=${FM_QUOTA_UTILIZATION_NOW:-}
if [ -z "$now" ]; then
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
fi

# Bounded execution, mirroring bin/fm-vendor-auth-probe.sh's run_timed ladder so
# a macOS host without coreutils still gets a hard bound instead of an unbounded
# provider read on the session-start path. Exit 124 means the bound was hit.
bounded_exec_available() {
  command -v timeout >/dev/null 2>&1 ||
    command -v gtimeout >/dev/null 2>&1 ||
    command -v perl >/dev/null 2>&1
}

run_quota_axi() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT" quota-axi "$@" </dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$TIMEOUT" quota-axi "$@" </dev/null
  else
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' \
      "$TIMEOUT" quota-axi "$@" </dev/null
  fi
}

# A skip line lands verbatim in the session-start digest, so vendor stderr is
# collapsed, stripped of control bytes, and capped: an unhandled node stack must
# not become a multi-kilobyte digest line. Cause slugs are far shorter than the
# cap and survive intact.
CAUSE_MAX_CHARS=120

axi_cause() {  # <exit-code> <stderr-file>
  local rc=$1 file=$2 cause
  cause=$(tr -d '\000-\010\013\014\016-\037\177' < "$file" \
    | tr -s '[:space:]' ' ' \
    | sed 's/^ *//; s/ *$//')
  if [ "${#cause}" -gt "$CAUSE_MAX_CHARS" ]; then
    cause="${cause:0:$CAUSE_MAX_CHARS}..."
  fi
  [ -n "$cause" ] || cause="quota-axi exited $rc"
  if [ "$rc" -eq 124 ]; then
    cause="quota-axi exceeded its ${TIMEOUT}s bound"
  fi
  printf '%s\n' "$cause"
}

collect_live_snapshots() {
  local tmp json rc=0 cause profile_file line alias dir
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-quota-util.XXXXXX") || return 1
  if ! command -v quota-axi >/dev/null 2>&1; then
    printf '%s\n' '{"account":"default","error":"quota-axi not on PATH"}'
    rm -f "$tmp"
    return 0
  fi
  if ! bounded_exec_available; then
    printf '%s\n' '{"account":"default","error":"no bounded-execution helper (timeout, gtimeout, or perl) available"}'
    rm -f "$tmp"
    return 0
  fi
  if [ -n "$PROVIDER" ]; then
    json=$(run_quota_axi --provider "$PROVIDER" --json 2>"$tmp") || rc=$?
  else
    json=$(run_quota_axi --json 2>"$tmp") || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    cause=$(axi_cause "$rc" "$tmp")
    printf '%s\n' "$(jq -nc --arg cause "$cause" '{account:"default",error:$cause}')"
  else
    printf '%s\n' "$(jq -nc --argjson snapshot "$json" '{account:"default",snapshot:$snapshot}')"
  fi
  rm -f "$tmp"

  [ "$ACCOUNTS_FROM_CONFIG" -eq 1 ] || return 0
  case "$PROVIDER" in
    ''|claude) ;;
    *) return 0 ;;
  esac
  profile_file="$CONFIG/claude-account-profiles"
  [ -f "$profile_file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      *=*) alias=${line%%=*}; dir=${line#*=} ;;
      *) continue ;;
    esac
    [ -d "$dir" ] || {
      printf '%s\n' "$(jq -nc --arg account "$alias" --arg cause "CLAUDE_CONFIG_DIR missing" \
        '{account:$account,provider:"claude",error:$cause}')"
      continue
    }
    tmp=$(mktemp "${TMPDIR:-/tmp}/fm-quota-util.XXXXXX") || continue
    rc=0
    json=$(CLAUDE_CONFIG_DIR="$dir" run_quota_axi --provider claude --json 2>"$tmp") || rc=$?
    if [ "$rc" -ne 0 ]; then
      cause=$(axi_cause "$rc" "$tmp")
      printf '%s\n' "$(jq -nc --arg account "$alias" --arg cause "$cause" \
        '{account:$account,provider:"claude",error:$cause}')"
    else
      printf '%s\n' "$(jq -nc --arg account "$alias" --argjson snapshot "$json" \
        '{account:$account,snapshot:$snapshot}')"
    fi
    rm -f "$tmp"
  done < "$profile_file"
}

build_payload() {
  local rows observations_json snapshot_json snapshot_json_file
  if [ "${#SNAPSHOTS[@]}" -gt 0 ]; then
    snapshot_json='[]'
    for snapshot_json_file in "${SNAPSHOTS[@]}"; do
      [ -f "$snapshot_json_file" ] || { echo "error: snapshot not found: $snapshot_json_file" >&2; exit 2; }
      snapshot_json=$(jq -nc --argjson acc "$snapshot_json" --slurpfile snap "$snapshot_json_file" \
        '$acc + [{account:"default", snapshot:$snap[0]}]')
    done
  elif [ "$MODE" = outcomes ]; then
    # `outcomes` is derived purely from --observations, so a live provider read
    # here would cost a bounded quota-axi call whose output is discarded.
    snapshot_json='[]'
  else
    rows=$(collect_live_snapshots)
    if [ -n "$rows" ]; then
      snapshot_json=$(printf '%s\n' "$rows" | jq -s '.')
    else
      snapshot_json='[]'
    fi
  fi
  if [ -n "$OBSERVATIONS" ]; then
    [ -f "$OBSERVATIONS" ] || { echo "error: observations not found: $OBSERVATIONS" >&2; exit 2; }
    observations_json=$(jq -s '.' "$OBSERVATIONS")
  else
    observations_json='[]'
  fi
  jq -nc --arg now "$now" --arg provider "$PROVIDER" \
    --argjson snapshots "$snapshot_json" --argjson observations "$observations_json" \
    '{now:$now, provider:(if $provider == "" then null else $provider end), snapshots:$snapshots, observations:$observations}'
}

payload=$(build_payload) || exit 2
result=$(printf '%s\n' "$payload" | node "$COMPUTE") || exit 2

print_text_report() {
  local text
  text=$(printf '%s\n' "$result" | jq -r '
    (.accounts[]? |
      "quota: \(.provider) \(.account): \(.utilizationPercent // "unknown")% used (\(.tightestWindowId // "unknown")) resets in \(.resetCountdownSeconds // "unknown")s \(.verdict) reserve=\(.bindingWeeklyReservePercentPoints // "unknown") hold=no"),
    (.degraded[]? |
      "quota: \(.provider)\(if (.account // "default") == "default" then "" else " " + .account end) skipped: \(.cause)")
  ')
  if [ -n "$text" ]; then
    printf '%s\n' "$text"
  else
    printf '%s\n' '(none)'
  fi
}

print_outcomes_text() {
  printf '%s\n' "$result" | jq -r '
    ["provider","account","window","outcome","unusedPercent","exhaustedEarlySeconds"],
    (.outcomes[]? | [(.provider // ""), (.account // ""), (.windowId // ""), (.kind // ""), (.unusedPercent // "" | tostring), (.exhaustedEarlySeconds // "" | tostring)])
    | @tsv
  '
}

if [ "$MODE" = outcomes ]; then
  if [ "$FORMAT" = json ]; then
    printf '%s\n' "$result"
  else
    print_outcomes_text
  fi
  exit 0
fi

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$result"
  exit 0
fi

print_text_report
exit 0
