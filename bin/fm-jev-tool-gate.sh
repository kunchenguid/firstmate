#!/usr/bin/env bash
# Remainder Jev tool-gate after the deterministic arm-command policy.
#
# Usage:
#   fm-jev-tool-gate.sh --command <cmd>
#
# Always runs bin/fm-arm-command-policy.mjs first. A deterministic deny stops
# here and never reaches Jev, even in shadow. An allow may then ask Jev a
# Choice {allow, deny, need_human} and append one JSONL line to
# $FM_HOME/state/jev-tool-gate.jsonl.
#
# Default FM_JEV_TOOL_GATE=shadow: log the Choice and still allow. Live Jev
# deny/allow stays off. Live mode requires FM_JEV_TOOL_GATE=live plus both
# presence files $FM_HOME/config/jev-tool-gate-live and
# $FM_HOME/config/jev-tool-gate-live-ack, and still cannot override a
# deterministic deny. Hard-shipping live remainder deny into watcher-arm or
# PreToolUse paths is a do-not; this script is the documented remainder hook,
# not a replacement for bin/fm-arm-pretool-check.sh.
#
# Exit:
#   0  deterministic allow (shadow, skipped Jev, or live Jev allow)
#   2  deterministic deny, live Jev deny/need_human, or usage error
#
# bin/fm-jev-lib.sh owns the Jev call. The script header owns mode resolution,
# the log path, and the Choice question. See docs/arm-pretool-check.md and
# docs/configuration.md "Jev remainder tool-gate".
set -u

usage() {
  cat <<'EOF'
Usage: fm-jev-tool-gate.sh --command <cmd>

Run the deterministic arm-command policy first. A deny never reaches Jev.
An allow may shadow-log a Jev Choice {allow, deny, need_human}.
Default FM_JEV_TOOL_GATE=shadow. Live remainder deny needs FM_JEV_TOOL_GATE=live
plus config/jev-tool-gate-live and config/jev-tool-gate-live-ack.
Hard-shipping live Jev deny/allow onto watcher-arm or PreToolUse paths is a do-not.
EOF
}

CMD=""
CMD_SET=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { printf 'jev-tool-gate: --command requires a value\n' >&2; usage >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'jev-tool-gate: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  printf 'jev-tool-gate: --command is required\n' >&2
  usage >&2
  exit 2
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || {
  printf 'jev-tool-gate: could not resolve script directory\n' >&2
  exit 2
}
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || {
  printf 'jev-tool-gate: could not resolve code root\n' >&2
  exit 2
}
ACTIVE_HOME=${FM_HOME:-$ROOT}
POLICY="$ROOT/bin/fm-arm-command-policy.mjs"
LOG_PATH="$ACTIVE_HOME/state/jev-tool-gate.jsonl"
LIVE_FILE="$ACTIVE_HOME/config/jev-tool-gate-live"
LIVE_ACK="$ACTIVE_HOME/config/jev-tool-gate-live-ack"

_fm_jev_tool_gate_mode() {
  local env_mode=${FM_JEV_TOOL_GATE:-shadow}
  case "$env_mode" in
    live)
      if [ -f "$LIVE_FILE" ] && [ -f "$LIVE_ACK" ]; then
        printf 'live\n'
        return 0
      fi
      ;;
  esac
  printf 'shadow\n'
}

_fm_jev_tool_gate_fail_open() {
  # Remainder only. A policy or Jev miss must not become a hard deny.
  exit 0
}

if ! command -v node >/dev/null 2>&1; then
  _fm_jev_tool_gate_fail_open
fi
[ -f "$POLICY" ] || _fm_jev_tool_gate_fail_open

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" --root "$ROOT" --home "$ACTIVE_HOME" 2>/dev/null) || _fm_jev_tool_gate_fail_open
[ -n "$POLICY_OUTPUT" ] || _fm_jev_tool_gate_fail_open

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
DECISION=${DECISION%%$'\n'*}
if [ "$DECISION" = deny ]; then
  REST=${POLICY_OUTPUT#*"$TAB"}
  CODE=${REST%%"$TAB"*}
  REASON=${REST#*"$TAB"}
  REASON=${REASON%%$'\n'*}
  if [ -n "$CODE" ] && [ "$CODE" != "$REST" ] && [ -n "$REASON" ]; then
    printf 'jev-tool-gate: deterministic deny [%s] %s\n' "$CODE" "$REASON" >&2
  else
    printf 'jev-tool-gate: deterministic deny\n' >&2
  fi
  exit 2
fi
[ "$DECISION" = allow ] || _fm_jev_tool_gate_fail_open

MODE=$(_fm_jev_tool_gate_mode)

# shellcheck source=bin/fm-jev-lib.sh
. "$ROOT/bin/fm-jev-lib.sh"

COMPACT=""
if COMPACT=$(fm_jev_compact_state "$CMD"); then
  :
else
  _fm_jev_tool_gate_fail_open
fi

QUESTIONS='{"gate":{"type":"choice","instructions":"Should this already-allowlisted command proceed?","criteria":{"allow":"Safe to run as submitted","deny":"Must not run","need_human":"A human should review before running"}}}'

RESP=""
DECIDE_CODE=0
RESP=$(fm_jev_decide "$COMPACT" "$QUESTIONS") || DECIDE_CODE=$?

CHOICE=""
CONFIDENCE=""
ERROR=""
if [ "$DECIDE_CODE" -ne 0 ]; then
  ERROR="jev-call-failed:$DECIDE_CODE"
else
  CHOICE=$(printf '%s' "$RESP" | jq -r '.answers.gate.choice // empty' 2>/dev/null || true)
  CONFIDENCE=$(printf '%s' "$RESP" | jq -r '.answers.gate.confidence // empty' 2>/dev/null || true)
  case "$CHOICE" in
    allow|deny|need_human) ;;
    *)
      ERROR="invalid-choice"
      CHOICE=""
      ;;
  esac
fi

APPLIED=false
if [ "$MODE" = live ] && { [ "$CHOICE" = deny ] || [ "$CHOICE" = need_human ]; }; then
  APPLIED=true
fi

LOG_PAYLOAD=$(jq -n \
  --arg mode "$MODE" \
  --arg policy "allow" \
  --arg command "$COMPACT" \
  --arg choice "$CHOICE" \
  --arg confidence "$CONFIDENCE" \
  --arg applied "$APPLIED" \
  --arg error "$ERROR" \
  --arg route "${FM_JEV_LAST_ROUTE:-}" \
  --arg model "${FM_JEV_LAST_MODEL:-}" \
  --arg latency "${FM_JEV_LAST_LATENCY_MS:-}" \
  '{
    event: "jev-tool-gate",
    mode: $mode,
    policy: $policy,
    command: $command,
    choice: (if $choice == "" then null else $choice end),
    confidence: (if $confidence == "" then null else ($confidence | tonumber? // $confidence) end),
    applied: ($applied == "true"),
    error: (if $error == "" then null else $error end),
    route: (if $route == "" then null else $route end),
    model: (if $model == "" then null else $model end),
    latency_ms: (if $latency == "" then null else ($latency | tonumber? // $latency) end)
  }' 2>/dev/null) || LOG_PAYLOAD=""

if [ -n "$LOG_PAYLOAD" ]; then
  fm_jev_log_call "$LOG_PAYLOAD" "$LOG_PATH" || true
fi

if [ "$APPLIED" = true ]; then
  printf 'jev-tool-gate: live remainder %s\n' "$CHOICE" >&2
  exit 2
fi
exit 0
