#!/usr/bin/env bash
# fm-quota-preflight.sh - advisory quota pre-flight for one worker launch.
#
# Usage: fm-quota-preflight.sh <harness> <model> [--effort <level>]
#                              [--provider <id>] [--quota-scope <scope>]
#                              [--snapshot <path>]
#
# Prints one `quota-preflight:` notice when quota-axi reports the launch's
# provider `exhausted_now` on a scope that applies to <model>, and nothing
# otherwise. It never refuses a launch and always exits 0: dispatch choice
# belongs to the quota-array-dispatch skill and bin/fm-dispatch-resolve.sh, and
# this is only the last look before a worker is started on a candidate that is
# already out of quota and would stall on its first request.
#
# bin/fm-spawn.sh runs it for every ship and scout launch, including a relaunch,
# in a home that declares dispatch profiles (config/crew-dispatch.json).
#
# The provider is, in order: --provider; the `provider` (and `quota_scope`) a
# profile in config/crew-dispatch.json declares for exactly this harness and
# model; the harness's single provider family (bin/fm-quota-axi-lib.sh).
# A launch with no provider resolved, a home declaring "shared_quota": true,
# FM_QUOTA_PREFLIGHT=off, an absent or failing quota-axi, or an invalid snapshot
# all print nothing. The snapshot is one `quota-axi --json` read bounded by
# FM_QUOTA_PREFLIGHT_TIMEOUT seconds (10), or the --snapshot file.
# Applicable scopes and the account-row join are the quota-array-dispatch
# eligibility contract, implemented once in FM_QUOTA_ROW_JQ.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

case "${1:-}" in
  -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

HARNESS=${1:-}
MODEL=${2:-}
[ -n "$HARNESS" ] || exit 0
shift
[ "$#" -eq 0 ] || shift
PROVIDER=
QUOTA_SCOPE=
EFFORT=
ACCOUNT=
ACCOUNT_ROOT=
ACCOUNT_LANE=
SNAPSHOT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --effort) EFFORT=${2:-}; shift 2 || exit 0 ;;
    --account) ACCOUNT=${2:-}; shift 2 || exit 0 ;;
    --account-root) ACCOUNT_ROOT=${2:-}; shift 2 || exit 0 ;;
    --account-lane|--lane) ACCOUNT_LANE=${2:-}; shift 2 || exit 0 ;;
    --provider) PROVIDER=${2:-}; shift 2 || exit 0 ;;
    --quota-scope) QUOTA_SCOPE=${2:-}; shift 2 || exit 0 ;;
    --snapshot) SNAPSHOT=${2:-}; shift 2 || exit 0 ;;
    *) exit 0 ;;
  esac
done
[ "${FM_QUOTA_PREFLIGHT:-on}" != off ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
[ "$MODEL" != default ] || MODEL=
if [ -z "$ACCOUNT_ROOT" ] && [ -n "$ACCOUNT" ]; then
  case "$ACCOUNT" in
    ordinary) ACCOUNT_ROOT="${HOME:-}/.claude" ;;
    /*) ACCOUNT_ROOT=$ACCOUNT ;;
  esac
fi

CONFIG="${FM_CONFIG_OVERRIDE:-${FM_HOME:+$FM_HOME/config}}"
RULES=
[ -z "$CONFIG" ] || [ ! -f "$CONFIG/crew-dispatch.json" ] || RULES="$CONFIG/crew-dispatch.json"
if [ -n "$RULES" ]; then
  [ "$(jq -r '.shared_quota // false' "$RULES" 2>/dev/null)" != true ] || exit 0
  if [ -z "$PROVIDER" ]; then
    single_provider=$(fm_quota_single_provider_for_harness "$HARNESS" 2>/dev/null || true)
    declared=$(jq -r --arg h "$HARNESS" --arg m "$MODEL" --arg e "$EFFORT" --arg single_p "$single_provider" '
        def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
        [ ((.rules // [])[] | profiles(.use)[], profiles(.default)[]), profiles(.default)[] ]
        | map(select(.harness == $h and ((.model // "") == $m)))
        | map({provider: (.provider // $single_p), quota_scope: (.quota_scope // ""), effort: (.effort // "")})
        | map(select(.provider != ""))
        | (if ($e != "" and $e != "default") then
             (map(select(.effort == $e)) as $effort
              | if ($effort | length) > 0 then $effort else . end)
           else . end)
        | map({provider, quota_scope})
        | unique_by([.provider, .quota_scope])
        | if length > 1 then "ambiguous"
          elif length == 1 then .[0] | "\(.provider)\t\(.quota_scope)"
          else "" end
      ' "$RULES" 2>/dev/null) || declared=
    [ "$declared" != ambiguous ] || exit 0
    if [ -n "$declared" ]; then
      PROVIDER=${declared%%$'\t'*}
      [ -n "$QUOTA_SCOPE" ] || QUOTA_SCOPE=${declared#*$'\t'}
    fi
  fi
fi
[ -n "$PROVIDER" ] || PROVIDER=$(fm_quota_single_provider_for_harness "$HARNESS" 2>/dev/null) || PROVIDER=
[ -n "$PROVIDER" ] || exit 0

if [ -n "$SNAPSHOT" ]; then
  snap=$(cat "$SNAPSHOT" 2>/dev/null) || exit 0
else
  command -v quota-axi >/dev/null 2>&1 || exit 0
  quota_command=(quota-axi --json)
  if [ -n "$ACCOUNT_ROOT" ]; then
    case "$HARNESS" in
      claude)
        quota_command=(env -u QUOTA_AXI_SNAPSHOT CLAUDE_CONFIG_DIR="$ACCOUNT_ROOT" quota-axi --provider claude --profile-only --json)
        ;;
      pi|pi-signed)
        quota_command=(env -u QUOTA_AXI_SNAPSHOT PI_CODING_AGENT_DIR="$ACCOUNT_ROOT" quota-axi --json)
        ;;
    esac
  fi
  if command -v timeout >/dev/null 2>&1; then
    snap=$(timeout "${FM_QUOTA_PREFLIGHT_TIMEOUT:-10}" "${quota_command[@]}" 2>/dev/null) || exit 0
  else
    snap=$("${quota_command[@]}" 2>/dev/null) || exit 0
  fi
fi
printf '%s' "$snap" | fm_quota_json_valid || exit 0

printf '%s' "$snap" | jq -r --arg h "$HARNESS" --arg m "$MODEL" --arg p "$PROVIDER" --arg qs "$QUOTA_SCOPE" --arg lane "$ACCOUNT_LANE" \
  "$FM_QUOTA_ROW_JQ"'
  . as $q |
  (quota_row($q; $p; (if $lane == "" then quota_lane($h; $m) else $lane end))) as $row |
  if $row == null then empty else
    [ ($row.quotaSemantics.effectiveAvailability // [])[]
      | select(quota_scope_applies($m; $qs))
      | select((.runway.status // "") == "exhausted_now") ]
    | first // empty
    | "quota-preflight: \($h)\(if $m == "" then "" else ":" + $m end) provider \($p) is exhausted_now at \(.scope)" +
      (if (.effectivePercentRemaining | type) == "number" then " (\(.effectivePercentRemaining)% left)" else "" end) +
      "; this worker will stall on its first request - choose the next same-group candidate"
  end' 2>/dev/null || true
exit 0
