#!/usr/bin/env bash
# Call one approved bytedcli MCP tool with its arguments supplied by a private
# JSON file over stdin. This is the sole private-payload transport used by the
# iDA remote-agent adapter.
#
# Usage:
#   fm-bytedcli-mcp-call.sh ida_deep_research_create <mode-0600-arguments.json>
#
# The arguments file must be a regular, single-link, current-user-owned 0600
# file. Tool arguments never appear in this process's argv. The helper starts
# only the official installed `bytedcli mcp --allow-domains ida --all-tools`
# stdio server, performs MCP initialize plus tools/call, and emits the bounded
# normalized JSON returned by the selected bytedcli command. Raw JSON-RPC and
# private request bytes are never emitted.
set -u

tool=${1-}
input=${2-}
[ "$#" -eq 2 ] || { printf 'usage: fm-bytedcli-mcp-call.sh <tool> <private-arguments.json>\n' >&2; exit 2; }
case "$tool" in
  ida_deep_research_create) ;;
  *) printf 'error: unsupported private-payload MCP tool: %s\n' "$tool" >&2; exit 1 ;;
esac

file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1" 2>/dev/null; else stat -c %a "$1" 2>/dev/null; fi
}
file_links() {
  if [ "$(uname)" = Darwin ]; then stat -f %l "$1" 2>/dev/null; else stat -c %h "$1" 2>/dev/null; fi
}
file_owner() {
  if [ "$(uname)" = Darwin ]; then stat -f %u "$1" 2>/dev/null; else stat -c %u "$1" 2>/dev/null; fi
}

if ! { [ -f "$input" ] && [ ! -L "$input" ] \
    && [ "$(file_mode "$input")" = 600 ] \
    && [ "$(file_links "$input")" = 1 ] \
    && [ "$(file_owner "$input")" = "$(id -u)" ] \
    && jq -e 'type == "object"' "$input" >/dev/null 2>&1; }; then
  printf 'error: MCP arguments must be a safe mode-0600 JSON object\n' >&2
  exit 1
fi

root=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-bytedcli-mcp.XXXXXX") \
  || { printf 'error: cannot create private MCP temporary storage\n' >&2; exit 1; }
trap 'rm -rf -- "$root"' EXIT
request="$root/request.ndjson"
response="$root/response.ndjson"
error="$root/error"
{
  jq -cn '{jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:"2025-06-18",capabilities:{},clientInfo:{name:"firstmate",version:"1"}}}'
  jq -cn '{jsonrpc:"2.0",method:"notifications/initialized",params:{}}'
  jq -cn --arg tool "$tool" --slurpfile arguments "$input" \
    '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:$tool,arguments:$arguments[0]}}'
} >"$request" || { printf 'error: cannot build MCP request\n' >&2; exit 1; }
chmod 0600 "$request"

if ! BYTEDCLI_NO_AUTO_UPGRADE=1 bytedcli --as user mcp --allow-domains ida --all-tools \
    <"$request" >"$response" 2>"$error"; then
  code=MCP_TRANSPORT_ERROR
  case "$(tr '[:lower:]' '[:upper:]' <"$error")" in
    *AUTH*|*SSO*|*FORBIDDEN*|*HTTP*401*|*HTTP*403*) code=MCP_TRANSPORT_AUTH ;;
    *TIMEOUT*|*TIMED*OUT*) code=MCP_TRANSPORT_TIMEOUT ;;
    *NETWORK*|*FETCH*FAILED*|*ECONN*|*UNAVAILABLE*|*HTTP*50[234]*) code=MCP_TRANSPORT_UNAVAILABLE ;;
  esac
  jq -n --arg code "$code" \
    '{status:"error",data:null,error:{code:$code,message:"bytedcli MCP transport failed"}}'
  exit 1
fi

line=$(jq -c 'select(.id == 2)' "$response" 2>/dev/null | tail -1)
[ -n "$line" ] || {
  jq -n '{status:"error",data:null,error:{code:"MCP_RESPONSE_MISSING",message:"bytedcli MCP returned no tool response"}}'
  exit 1
}
if printf '%s\n' "$line" | jq -e '.error | type == "object"' >/dev/null 2>&1; then
  jq -n '{status:"error",data:null,error:{code:"MCP_TOOL_ERROR",message:"bytedcli MCP tool failed"}}'
  exit 1
fi
text=$(printf '%s\n' "$line" | jq -r '.result.content[]? | select(.type == "text") | .text' | tail -1)
if [ -z "$text" ] || ! printf '%s\n' "$text" | jq -e . >/dev/null 2>&1; then
  jq -n '{status:"error",data:null,error:{code:"MCP_RESULT_INVALID",message:"bytedcli MCP returned no normalized JSON result"}}'
  exit 1
fi
printf '%s\n' "$text" | jq -c .
printf '%s\n' "$line" | jq -e '.result.isError != true' >/dev/null 2>&1
