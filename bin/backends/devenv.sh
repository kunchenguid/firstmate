#!/usr/bin/env bash
# devenv.sh - fixed-command SSH transport for the Expanly devenv protocol.
#
# Public function:
#   fm_backend_devenv_request <host> <request-json>
#
# Requests are sent only on stdin. The sole remote argv after the validated
# host is the installed fm-devenv-remote.sh path. Responses are capped at
# 65536 bytes and must match firstmate.devenv.v1 and the request id.

FM_BACKEND_DEVENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-devenv-lib.sh
. "$FM_BACKEND_DEVENV_DIR/../fm-devenv-lib.sh"

# The quoted tilde is intentionally sent for expansion by the remote shell.
# shellcheck disable=SC2088
FM_BACKEND_DEVENV_REMOTE_COMMAND='~/.local/share/firstmate-expanly/current/bin/fm-devenv-remote.sh'
FM_BACKEND_DEVENV_MAX_RESPONSE_BYTES=65536

fm_backend_devenv_request() (
  [ "$#" -eq 2 ] || return 2
  local host=$1 request=$2 request_bytes request_id response_file response_bytes
  local pipe_status response

  fm_devenv_vm_valid "$host" || return 1
  request_bytes=$(printf '%s' "$request" | LC_ALL=C wc -c | tr -d '[:space:]') || return 1
  [ "$request_bytes" -le 65536 ] || return 1
  request_id=$(printf '%s' "$request" | jq -cer -s '
    if (
      length == 1
      and (.[0] | type == "object")
      and (.[0] | keys == ["environment","lease","operation","payload","request_id","schema","vm"])
      and .[0].schema == "firstmate.devenv.v1"
      and (.[0].request_id | type == "string" and test("^[0-9a-f]{32}$"))
      and (.[0].operation | type == "string")
      and (.[0].environment | type == "string")
      and (.[0].vm | type == "string")
      and (.[0].payload | type == "object")
    ) then .[0].request_id else error("invalid request") end
  ' 2>/dev/null) || return 1

  response_file=$(mktemp "${TMPDIR:-/tmp}/fm-devenv-response.XXXXXX") || return 1
  trap 'rm -f -- "$response_file"' EXIT
  printf '%s' "$request" \
    | ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" "$FM_BACKEND_DEVENV_REMOTE_COMMAND" \
    | LC_ALL=C head -c "$((FM_BACKEND_DEVENV_MAX_RESPONSE_BYTES + 1))" > "$response_file"
  pipe_status=("${PIPESTATUS[@]}")
  response_bytes=$(LC_ALL=C wc -c < "$response_file" | tr -d '[:space:]') || return 1
  [ "$response_bytes" -le "$FM_BACKEND_DEVENV_MAX_RESPONSE_BYTES" ] || return 1
  [ "${pipe_status[1]}" -eq 0 ] || return 1

  response=$(jq -ce -s --arg request_id "$request_id" '
    if (
      length == 1
      and (.[0] | type == "object")
      and (.[0] | keys == ["error","ok","request_id","result","schema"])
      and .[0].schema == "firstmate.devenv.v1"
      and .[0].request_id == $request_id
      and (.[0].ok | type == "boolean")
      and (
        if .[0].ok then
          (.[0].result | type == "object") and .[0].error == null
        else
          .[0].result == null
          and (.[0].error | type == "object")
          and (.[0].error | keys == ["code","message"])
          and (.[0].error.code | type == "string" and length > 0 and length <= 64)
          and (.[0].error.message | type == "string" and length > 0 and length <= 160)
        end
      )
    ) then .[0] else error("invalid response") end
  ' "$response_file" 2>/dev/null) || return 1
  printf '%s\n' "$response"
)
