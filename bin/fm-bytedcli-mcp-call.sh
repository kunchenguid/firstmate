#!/usr/bin/env bash
# Call the approved iDA command through bytedcli's domain-restricted MCP
# run_command tool with private arguments supplied by a mode-0600 JSON file.
# This is the sole private-payload transport used by the iDA remote agent.
#
# Usage:
#   fm-bytedcli-mcp-call.sh capabilities
#   fm-bytedcli-mcp-call.sh ida_deep_research_create <mode-0600-arguments.json>
#
# The submission arguments file must be a regular, single-link,
# current-user-owned 0600 file. Its prompt is encoded into an MCP stdin request
# and never appears in this process's argv. `capabilities` verifies that the
# domain-restricted MCP server advertises the required official iDA command.
# Raw JSON-RPC, private request bytes, and raw command listings are never
# emitted. The capability check includes the official optional --model field so
# an explicit dispatch selection cannot reach an older incompatible create
# parser.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-ida-remote-lib.sh
. "$SCRIPT_DIR/fm-ida-remote-lib.sh"

mode=${1-}
input=${2-}
case "$mode:$#" in
  capabilities:1|capabilities-followup:1) mcp_tool=list_commands ;;
  ida_deep_research_create:2) mcp_tool=run_command ;;
  *) printf 'usage: fm-bytedcli-mcp-call.sh capabilities | ida_deep_research_create <private-arguments.json>\n' >&2; exit 2 ;;
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

if [ "$mode" = ida_deep_research_create ] && ! {
  [ -f "$input" ] && [ ! -L "$input" ] \
    && [ "$(file_mode "$input")" = 600 ] \
    && [ "$(file_links "$input")" = 1 ] \
    && [ "$(file_owner "$input")" = "$(id -u)" ] \
    && jq -e '
      type == "object"
      and ((keys - ["agentId","content","model","name","timeoutMs","sessionId"]) | length == 0)
      and (.content | type == "string" and length > 0 and length <= 262144)
      and (.name | type == "string" and test("^firstmate:[A-Za-z0-9._-]+:[0-9a-f]{16}$") and length <= 220)
      and (.timeoutMs | type == "string" and test("^[1-9][0-9]*$"))
      and ((has("agentId") | not) or (.agentId | type == "string" and test("^[0-9]+$")))
      and ((has("model") | not) or (.model | type == "string" and test("^[A-Za-z0-9._:/+-]+$") and length <= 160))
      and ((has("sessionId") | not) or (.sessionId | type == "string" and test("^[1-9][0-9]*$")))
    ' "$input" >/dev/null 2>&1
}; then
  printf 'error: MCP arguments must match the safe iDA create schema in a mode-0600 JSON object\n' >&2
  exit 1
fi

root=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-bytedcli-mcp.XXXXXX") \
  || { printf 'error: cannot create private MCP temporary storage\n' >&2; exit 1; }
trap 'rm -rf -- "$root"' EXIT
request="$root/request.ndjson"
response="$root/response.ndjson"
error="$root/error"
if [ "$mode" = capabilities ] || [ "$mode" = capabilities-followup ]; then
  jq -cn '{domain:"ida",verbose:true}' >"$root/arguments.json" \
    || { printf 'error: cannot build MCP capability request\n' >&2; exit 1; }
else
  jq -r '
    (["ida","--region","sg","deep-research","create",
      "--content",("[Firstmate session marker: " + .name + "]\n\n" + .content),
      "--name",.name,"--timeout-ms",.timeoutMs]
     + (if has("agentId") then ["--agent-id",.agentId] else [] end)
     + (if has("model") then ["--model",.model] else [] end))
    + (if has("sessionId") then ["--session-id",.sessionId,"--no-wait"] else [] end)
    | map(@sh) | join(" ")
  ' "$input" >"$root/command" || { printf 'error: cannot build private iDA command\n' >&2; exit 1; }
  jq -cn --rawfile command "$root/command" '{command:($command | rtrimstr("\n"))}' >"$root/arguments.json" \
    || { printf 'error: cannot build MCP command request\n' >&2; exit 1; }
fi
chmod 0600 "$root/arguments.json"
{
  jq -cn '{jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:"2025-06-18",capabilities:{},clientInfo:{name:"firstmate",version:"1"}}}'
  jq -cn '{jsonrpc:"2.0",method:"notifications/initialized",params:{}}'
  jq -cn --arg tool "$mcp_tool" --slurpfile arguments "$root/arguments.json" \
    '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:$tool,arguments:$arguments[0]}}'
} >"$request" || { printf 'error: cannot build MCP request\n' >&2; exit 1; }
chmod 0600 "$request"

# Keep `mcp` as the first non-option token so bytedcli retains its stdio server;
# select the required user identity through the CLI's equivalent environment input.
if ! BYTECLOUD_AUTH_AS=user fm_ida_run_bytedcli mcp --allow-domains ida \
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

mcp_error() { # <safe-source-text>
  local upper code=MCP_TOOL_ERROR message='bytedcli MCP tool failed'
  upper=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  case "$upper" in
    *RATE*LIMIT*|*TOO*MANY*REQUEST*|*HTTP*429*|*QUOTA*) code=MCP_TOOL_RATE_LIMITED; message='bytedcli MCP tool was rate limited' ;;
    *AUTH*|*SSO*|*FORBIDDEN*|*PERMISSION*DENIED*|*HTTP*401*|*HTTP*403*) code=MCP_TOOL_AUTH; message='bytedcli MCP tool was denied by authentication or permission' ;;
    *UNSUPPORTED*|*NOT*IMPLEMENTED*|*UNKNOWN*COMMAND*) code=MCP_TOOL_UNSUPPORTED; message='bytedcli MCP tool is unsupported' ;;
    *TIMEOUT*|*TIMED*OUT*) code=MCP_TOOL_TIMEOUT; message='bytedcli MCP tool timed out' ;;
    *NETWORK*|*FETCH*FAILED*|*ECONN*|*UNAVAILABLE*|*HTTP*50[234]*) code=MCP_TOOL_UNAVAILABLE; message='bytedcli MCP tool is unavailable' ;;
    *NOT*FOUND*|*HTTP*404*) code=MCP_TOOL_NOT_FOUND; message='bytedcli MCP tool target was not found' ;;
  esac
  jq -n --arg code "$code" --arg message "$message" \
    '{status:"error",data:null,error:{code:$code,message:$message}}'
  exit 1
}

if ! jq -s -e 'type == "array" and all(.[]; type == "object")' "$response" >/dev/null 2>&1; then
  jq -n '{status:"error",data:null,error:{code:"MCP_RESPONSE_INVALID",message:"bytedcli MCP returned malformed JSON-RPC output"}}'
  exit 1
fi
response_count=$(jq -s '[.[] | select(.id == 2)] | length' "$response")
case "$response_count" in
  0)
    if jq -s -e 'any(.[]; (.id | tostring) == "2")' "$response" >/dev/null 2>&1; then
      jq -n '{status:"error",data:null,error:{code:"MCP_RESPONSE_INVALID",message:"bytedcli MCP returned a tool response with invalid identity"}}'
      exit 1
    fi
    jq -n '{status:"error",data:null,error:{code:"MCP_RESPONSE_MISSING",message:"bytedcli MCP returned no tool response"}}'
    exit 1
    ;;
  1) ;;
  *)
    jq -n '{status:"error",data:null,error:{code:"MCP_RESPONSE_AMBIGUOUS",message:"bytedcli MCP returned duplicate tool responses"}}'
    exit 1
    ;;
esac
line=$(jq -c 'select(.id == 2)' "$response")
if ! printf '%s\n' "$line" | jq -e '
    .jsonrpc == "2.0"
    and ((has("result") and (has("error") | not)) or (has("error") and (has("result") | not)))
  ' >/dev/null 2>&1; then
  jq -n '{status:"error",data:null,error:{code:"MCP_RESPONSE_INVALID",message:"bytedcli MCP returned an invalid tool response"}}'
  exit 1
fi
if printf '%s\n' "$line" | jq -e '.error | type == "object"' >/dev/null 2>&1; then
  error_text=$(printf '%s\n' "$line" | jq -r '[.error.code?,.error.message?] | map(select(type == "string" or type == "number")) | map(tostring) | join(" ")')
  mcp_error "$error_text"
fi
if ! printf '%s\n' "$line" | jq -e '
    (.result | type == "object")
    and (.result.content | type == "array")
    and all(.result.content[]; type == "object")
    and ((.result | has("isError") | not) or (.result.isError | type == "boolean"))
  ' >/dev/null 2>&1; then
  jq -n '{status:"error",data:null,error:{code:"MCP_RESPONSE_INVALID",message:"bytedcli MCP returned an invalid tool result"}}'
  exit 1
fi
text=$(printf '%s\n' "$line" | jq -r '[.result.content[]? | select(.type == "text") | .text] | join("\n")')
if printf '%s\n' "$line" | jq -e '.result.isError == true' >/dev/null 2>&1; then
  mcp_error "$text"
fi
if [ "$mode" = capabilities ] || [ "$mode" = capabilities-followup ]; then
  capability_ready=true
  for required in \
      'bytedcli ida deep-research create' '--content' '--name' '--model' '--timeout-ms' \
      'bytedcli ida session raw list' '--agent-id' \
      'bytedcli ida session get' '--session-id' \
      'bytedcli ida chat completion close'; do
    case "$text" in *"$required"*) ;; *) capability_ready=false ;; esac
  done
  if [ "$mode" = capabilities-followup ]; then
    for required in '--session-id' '--no-wait' 'bytedcli ida deep-research list' 'bytedcli ida deep-research get'; do
      case "$text" in *"$required"*) ;; *) capability_ready=false ;; esac
    done
  fi
  if [ "$capability_ready" = true ]; then
    jq -cn '{status:"success",data:{command:"bytedcli ida deep-research create",required_options:["--content","--name","--model","--timeout-ms"]},error:null}'
  else
    jq -n '{status:"error",data:null,error:{code:"MCP_CAPABILITY_UNSUPPORTED",message:"required iDA deep-research create command is unavailable"}}'
    exit 1
  fi
elif [ -z "$text" ] || ! printf '%s\n' "$text" | jq -e . >/dev/null 2>&1; then
  jq -n '{status:"error",data:null,error:{code:"MCP_RESULT_INVALID",message:"bytedcli MCP returned no normalized JSON result"}}'
  exit 1
else
  printf '%s\n' "$text" | jq -c .
  printf '%s\n' "$text" | jq -e '.status == "success" and .error == null' >/dev/null 2>&1
fi
