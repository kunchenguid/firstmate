#!/usr/bin/env bash
# fm-claude-cost.sh - report the Claude Code subscription's current "extra
# usage" dollar spend against its monthly limit, on demand.
#
# Usage:
#   fm-claude-cost.sh [--json]
#   fm-claude-cost.sh --help
#
# This calls the same internal endpoint the Claude Code CLI itself uses for
# its `/status` command and footer usage display:
#
#   GET https://api.anthropic.com/api/oauth/usage
#   Header: anthropic-beta: oauth-2025-04-20
#   Header: Authorization: Bearer <accessToken from ~/.claude/.credentials.json>
#
# That endpoint is internal and undocumented (no official support guarantee),
# not the Anthropic Admin Usage & Cost API, which is organization-wide and
# needs a separate admin-issued key.
# See data/claude-code-cost-tracking-pesquisa/report.md (captain-private, not
# tracked) for the investigation that established this.
#
# The endpoint is reported to rate-limit (HTTP 429) aggressively under tight
# polling, so this script is deliberately a plain on-demand check with no
# scheduling of its own: run it by hand, or from cron/a watcher check at a
# sensible cadence (no more than about once an hour). Wiring automatic hourly
# scheduling through a registered watcher check is a possible future addition,
# not implemented here.
#
# The OAuth access token is never printed, logged, or placed on a command
# line: it is written to a private (mode 600) curl config file and passed via
# `curl -K`, so it cannot appear in this script's own output or in another
# process's view of argv (e.g. `ps`).
set -eu
export LC_ALL=C

SCRIPT_NAME=fm-claude-cost.sh

usage() {
  cat <<'EOF'
Usage:
  fm-claude-cost.sh [--json]   print the current extra-usage spend and limit
  fm-claude-cost.sh --help     print this help

Reads the OAuth access token from ~/.claude/.credentials.json (override with
FM_CLAUDE_CREDENTIALS_FILE) and queries the same internal usage endpoint the
Claude Code CLI footer uses. Prints a one-line human-readable summary by
default, or the full JSON response with --json.

Env overrides (for testing; none are required for normal use):
  FM_CLAUDE_CREDENTIALS_FILE  path to the credentials JSON (default: ~/.claude/.credentials.json)
  FM_CLAUDE_USAGE_URL         usage endpoint URL (default: the real Anthropic endpoint)
  FM_CLAUDE_COST_TIMEOUT      request timeout in seconds, 1..60 (default: 15)
EOF
}

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  exit 1
}

die_usage() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  usage >&2
  exit 2
}

JSON_OUT=0
case "${1:-}" in
  --json) JSON_OUT=1 ;;
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) die_usage "unknown argument: $1" ;;
esac
if [ "$#" -gt 1 ]; then
  die_usage "unexpected extra argument: $2"
fi

for tool in curl jq mktemp awk; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required but not found on PATH"
done

CREDENTIALS_FILE=${FM_CLAUDE_CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}
USAGE_URL=${FM_CLAUDE_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}

TIMEOUT=${FM_CLAUDE_COST_TIMEOUT:-15}
case "$TIMEOUT" in
  ''|*[!0-9]*) die "FM_CLAUDE_COST_TIMEOUT must be a whole number from 1 to 60" ;;
esac
if [ "$TIMEOUT" -lt 1 ] || [ "$TIMEOUT" -gt 60 ]; then
  die "FM_CLAUDE_COST_TIMEOUT must be a whole number from 1 to 60"
fi

[ -f "$CREDENTIALS_FILE" ] || die "no credentials file at $CREDENTIALS_FILE (log in with the claude CLI first)"

TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null) \
  || die "could not parse $CREDENTIALS_FILE as JSON"
[ -n "$TOKEN" ] || die "no claudeAiOauth.accessToken found in $CREDENTIALS_FILE"

CURL_CFG=
BODY_FILE=
cleanup() {
  [ -z "$CURL_CFG" ] || rm -f -- "$CURL_CFG"
  [ -z "$BODY_FILE" ] || rm -f -- "$BODY_FILE"
}
trap cleanup EXIT

# Headers go through a private curl config file rather than -H on the command
# line, so the bearer token never appears in this script's own output or in
# another process's view of this process's argv.
CURL_CFG=$(mktemp) || die "could not create a temporary curl config file"
chmod 600 "$CURL_CFG" || die "could not set permissions on the temporary curl config file"
{
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN"
  printf 'header = "anthropic-beta: oauth-2025-04-20"\n'
} > "$CURL_CFG"
TOKEN=REDACTED

BODY_FILE=$(mktemp) || die "could not create a temporary response file"

set +e
HTTP_CODE=$(curl -s -K "$CURL_CFG" -o "$BODY_FILE" -w '%{http_code}' \
  --max-time "$TIMEOUT" "$USAGE_URL")
CURL_STATUS=$?
set -e

if [ "$CURL_STATUS" -ne 0 ]; then
  die "request to the usage endpoint failed (curl exit $CURL_STATUS, network or timeout)"
fi

case "$HTTP_CODE" in
  200) ;;
  429)
    die "usage endpoint rate-limited this request (HTTP 429) - it does not tolerate tight polling, wait and retry later"
    ;;
  401|403)
    die "usage endpoint rejected the credentials (HTTP $HTTP_CODE) - the Claude Code login may need to be refreshed"
    ;;
  *)
    die "usage endpoint returned an unexpected status (HTTP $HTTP_CODE)"
    ;;
esac

jq -e . "$BODY_FILE" >/dev/null 2>&1 || die "usage endpoint returned a response that is not valid JSON"

if [ "$JSON_OUT" -eq 1 ]; then
  jq . "$BODY_FILE"
  exit 0
fi

# The "spend" object already carries the human dollar figures the CLI footer
# shows (used/limit as minor units + exponent, plus a rounded percent), so it
# is preferred over hand-computing from "extra_usage". Fall back to
# "extra_usage" if "spend" is absent or its "enabled" field is explicitly
# false, for resilience against upstream response shape drift on this
# undocumented endpoint.
SUMMARY=$(jq -r '
  def money(obj):
    if obj == null then null
    else (obj.amount_minor / pow(10; obj.exponent)) end;
  if (.spend // null) != null and (.spend.enabled != false) then
    {
      used: money(.spend.used),
      limit: money(.spend.limit),
      currency: (.spend.used.currency // .spend.limit.currency // "USD"),
      percent: .spend.percent,
      severity: .spend.severity,
      source: "spend"
    }
  elif (.extra_usage // null) != null and (.extra_usage.is_enabled // false) then
    {
      used: (.extra_usage.used_credits / pow(10; (.extra_usage.decimal_places // 2))),
      limit: (.extra_usage.monthly_limit / pow(10; (.extra_usage.decimal_places // 2))),
      currency: (.extra_usage.currency // "USD"),
      percent: (.extra_usage.utilization | floor),
      severity: null,
      source: "extra_usage"
    }
  else
    null
  end
  | if . == null then "NONE"
    else [.used, .limit, .currency, .percent, (.severity // "n/a")] | @tsv
    end
' "$BODY_FILE") || die "could not read spend data from the usage response"

if [ "$SUMMARY" = NONE ]; then
  printf 'Claude Code extra usage is not enabled or not reported for this account.\n'
  exit 0
fi

IFS="$(printf '\t')" read -r USED LIMIT CURRENCY PERCENT SEVERITY <<EOF
$SUMMARY
EOF
unset IFS

USED_FMT=$(awk -v n="$USED" 'BEGIN { printf "%.2f", n }')
LIMIT_FMT=$(awk -v n="$LIMIT" 'BEGIN { printf "%.2f", n }')

printf 'Claude Code extra usage: %s %s of %s %s (%s%%) - %s\n' \
  "$CURRENCY" "$USED_FMT" "$CURRENCY" "$LIMIT_FMT" "$PERCENT" "$SEVERITY"
