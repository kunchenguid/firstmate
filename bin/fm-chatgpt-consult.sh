#!/usr/bin/env bash
# fm-chatgpt-consult.sh - Firstmate-owned ChatGPT consultation client.
# Usage: fm-chatgpt-consult.sh --prompt-file FILE --mode audit|plan
#          --thread THREAD-ID
#
# Builds one openai-responses request from the prompt file, stamps it with the
# Codex turn identity the local bridge requires (bin/fm-chatgpt-bridge-lib.sh
# owns that contract), POSTs it to the already-running loopback bridge, and
# prints ChatGPT's response text to stdout and nothing else.
#
# --thread is required and names the Firstmate-owned turn-identity id stamped
# into every request. It does not carry conversation continuity by itself:
# the bridge replays prior turns only via previous_response_id chaining or
# history inside the request, and this client sends neither (the lib owns the
# verified details). Each call is one self-contained turn, so Firstmate
# includes any prior context it needs considered in the prompt file.
#
# This is a consultation channel, not a Pi provider: no harness, no model
# registry, no account pin, no local-tool execution. The bridge lifecycle
# stays external - this script never installs, authenticates, or repairs the
# bridge. An unreachable or failing bridge is a reported prerequisite
# (nonzero exit, diagnostic on stderr, no response on stdout), never a setup
# step. docs/configuration.md "ChatGPT consultation channel" owns the
# user-facing contract.
set -u

LIBDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-chatgpt-bridge-lib.sh
. "$LIBDIR/fm-chatgpt-bridge-lib.sh"

usage() {
  printf 'usage: %s --prompt-file FILE --mode audit|plan --thread ID\n' "$(basename "$0")" >&2
}

PROMPT_FILE="" MODE="" THREAD="" MODEL="$FM_CHATGPT_WEB_MODEL"
while [ $# -gt 0 ]; do
  case "$1" in
    --prompt-file) PROMPT_FILE=${2:-}; shift 2 ;;
    --mode) MODE=${2:-}; shift 2 ;;
    --thread) THREAD=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'fm-chatgpt: unknown argument %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$PROMPT_FILE" ] || { printf 'fm-chatgpt: --prompt-file is required\n' >&2; usage; exit 2; }
[ -f "$PROMPT_FILE" ] || { printf 'fm-chatgpt: prompt file not found: %s\n' "$PROMPT_FILE" >&2; exit 2; }
case "$MODE" in
  audit|plan) ;;
  *) printf 'fm-chatgpt: --mode must be audit or plan\n' >&2; usage; exit 2 ;;
esac
[ -n "$THREAD" ] || { printf 'fm-chatgpt: --thread is required (Firstmate owns the turn-identity id)\n' >&2; usage; exit 2; }
command -v curl >/dev/null 2>&1 || { printf 'fm-chatgpt: consultation needs curl\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'fm-chatgpt: consultation needs jq\n' >&2; exit 1; }

BRIDGE_URL=$(fm_chatgpt_bridge_url) || exit 1

case "$MODE" in
  audit)
    INSTRUCTIONS="You are a senior code-review auditor. Read the objective and context below and return audit findings: risks, correctness gaps, and missing edge cases, ordered by severity. Return findings only, no execution plan."
    ;;
  plan)
    INSTRUCTIONS="You are a senior implementation planner. Read the objective, context, and any findings below and return a concrete step-by-step execution plan a junior worker can follow without further design decisions. Return the plan only."
    ;;
esac

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
REQUEST="$WORK/request.json"
RESPONSE="$WORK/response.json"

jq -n --arg m "$MODEL" --arg n "$INSTRUCTIONS" --rawfile p "$PROMPT_FILE" \
  '{model: $m, instructions: $n, input: [{role: "user", content: $p}]}' > "$REQUEST" || exit 1
fm_chatgpt_stamp_turn "$THREAD" "$REQUEST" >/dev/null || exit 1

HTTP=$(curl -s -o "$RESPONSE" -w '%{http_code}' -m 120 \
  -X POST "$BRIDGE_URL/responses" \
  -H 'content-type: application/json' \
  --data-binary "@$REQUEST") || {
  printf 'fm-chatgpt: bridge unreachable at %s; start the codex-chatgpt-web bridge before consulting\n' "$BRIDGE_URL" >&2
  exit 1
}
case "$HTTP" in
  2*) ;;
  *)
    printf 'fm-chatgpt: bridge request failed with HTTP %s: %s\n' "$HTTP" "$(head -c 500 "$RESPONSE")" >&2
    exit 1
    ;;
esac

TEXT=$(jq -r '[(.output // [])[] | select(.type == "message") | (.content // [])[] | select(.type == "output_text" or .type == "text") | .text] | join("\n")' "$RESPONSE")
[ -n "$TEXT" ] || {
  printf 'fm-chatgpt: bridge returned no response text (HTTP %s)\n' "$HTTP" >&2
  exit 1
}
printf '%s\n' "$TEXT"
