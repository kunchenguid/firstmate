#!/usr/bin/env bash
# fm-chatgpt-bridge-lib.sh - the single owner of Firstmate's ChatGPT
# consultation bridge contract: bridge URL resolution, model slug handling,
# and Codex turn-metadata stamping.
# Usage: . bin/fm-chatgpt-bridge-lib.sh
#
# The bridge is the already-installed codex-chatgpt-web daemon, loopback only.
# Nothing here installs it, authenticates it, or touches its session state.
# Callers fail closed when the bridge is unreachable; setup stays external.
#
# This is a consultation channel, not a Pi provider.
# It registers nothing with Pi, touches no spawn path, and needs no entry in
# config/pi-account. docs/configuration.md "ChatGPT consultation channel"
# owns the user-facing contract; this file owns the mechanics.
#
# Wire facts ported from the unmerged reference branch
# fm/pi-chatgpt-web-202610030755
# (.pi/extensions/fm-chatgpt-web-provider.ts as observed 2026-10-03):
# the bridge speaks openai-responses at /v1, routes on the qualified
# `chatgpt-web/<id>` slug (a bare id falls into native Codex passthrough and
# fails against the loopback key), and requires every browser-backed turn to
# carry body.client_metadata["x-codex-turn-metadata"] plus stable Codex item
# ids. Continuity is NOT keyed by the supplied thread id alone (verified
# against the bridge source): history replay is keyed solely on
# previous_response_id, the thread+model conversation key is consumed only on
# the local-tools retained-conversation path this stateless browser turn never
# takes, and the Luna checkpoint store requires the prior assistant answer
# inside the current input. This client sends neither, so every consultation
# is one self-contained turn; the thread id rides the metadata for turn
# identity and Firstmate-side task bookkeeping only.

FM_CHATGPT_WEB_PROVIDER="chatgpt-web"
FM_CHATGPT_WEB_MODEL_ID="gpt-5.6-luna"
FM_CHATGPT_WEB_MODEL="$FM_CHATGPT_WEB_PROVIDER/$FM_CHATGPT_WEB_MODEL_ID"
FM_CHATGPT_WEB_DEFAULT_BASE_URL="http://127.0.0.1:17841/v1"

# fm_chatgpt_bridge_url
# Prints the bridge base URL: $CHATGPT_WEB_BRIDGE_URL when set, else the
# loopback default. Refuses a non-loopback override on stderr with status 1,
# because the consultation channel is loopback-only by contract.
fm_chatgpt_bridge_url() {
  local override="${CHATGPT_WEB_BRIDGE_URL:-}"
  if [ -z "$override" ]; then
    printf '%s\n' "$FM_CHATGPT_WEB_DEFAULT_BASE_URL"
    return 0
  fi
  case "$override" in
    http://127.0.0.1*|http://localhost*|http://\[::1\]*)
      printf '%s\n' "$override"
      return 0
      ;;
  esac
  printf 'fm-chatgpt: refusing non-loopback bridge URL %s (loopback-only contract)\n' "$override" >&2
  return 1
}

# fm_chatgpt_model_slug [model]
# Prints the bridge-routable slug for a bare model id or a qualified
# `chatgpt-web/<id>` selector. Defaults to the Luna model. Refuses anything
# else on stderr with status 1; the doubled `chatgpt-web/chatgpt-web/<id>`
# is never valid.
fm_chatgpt_model_slug() {
  local model="${1:-$FM_CHATGPT_WEB_MODEL}"
  case "$model" in
    "$FM_CHATGPT_WEB_PROVIDER"/"$FM_CHATGPT_WEB_PROVIDER"/*)
      printf 'fm-chatgpt: refusing doubled model selector %s\n' "$model" >&2
      return 1
      ;;
    "$FM_CHATGPT_WEB_PROVIDER"/*)
      printf '%s\n' "$model"
      return 0
      ;;
    */*)
      printf 'fm-chatgpt: refusing model %s (only %s/* routes to the bridge)\n' "$model" "$FM_CHATGPT_WEB_PROVIDER" >&2
      return 1
      ;;
    *)
      printf '%s/%s\n' "$FM_CHATGPT_WEB_PROVIDER" "$model"
      return 0
      ;;
  esac
}

# fm_chatgpt_hash <content>
# Prints the full hex sha256 of the content string.
fm_chatgpt_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  else
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  fi
}

# fm_chatgpt_stable_id <prefix> <content>
# Prints `<prefix>_<32 hex>` over the sha256 of the content string, the
# shell twin of the reference extension's stableId.

# fm_chatgpt_stamp_turn <thread-id> <request-json-file>
# Stamps a Responses request file in place with the Codex turn identity the
# bridge requires: the qualified model slug, a deterministic turn id, the
# x-codex-turn-metadata client metadata, and stable message item ids.
# Needs jq. Prints the turn id on stdout.
fm_chatgpt_stamp_turn() {
  local thread_id=$1 request_file=$2
  command -v jq >/dev/null 2>&1 || {
    printf 'fm-chatgpt: stamping needs jq\n' >&2
    return 1
  }
  [ -n "$thread_id" ] || {
    printf 'fm-chatgpt: stamping needs a thread id\n' >&2
    return 1
  }
  local model slug cwd turn_key turn_id tmp count i key msg_id
  model=$(jq -r '.model // empty' "$request_file") || return 1
  slug=$(fm_chatgpt_model_slug "$model") || return 1
  cwd=$PWD
  tmp=$(mktemp) || return 1
  jq --arg slug "$slug" '.model = $slug' "$request_file" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$request_file"
  turn_key=$(jq -c --arg m "$slug" '[$m, .input, .instructions]' "$request_file") || return 1
  turn_id="turn_$(fm_chatgpt_hash "$turn_key" | cut -c1-32)"
  jq --arg thread "$thread_id" \
    --arg turn "$turn_id" \
    --arg cwd "$cwd" \
    '.client_metadata = ((.client_metadata // {}) + {"x-codex-turn-metadata": ({
        thread_id: $thread, turn_id: $turn, cwd: $cwd,
        workspace_roots: [$cwd], sandbox: "dangerFullAccess"
      } | tojson)})' "$request_file" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$request_file"
  # Stable message item ids keyed on index, role, and content, matching the
  # reference extension's stableId. Role-only items also gain the message type.
  count=$(jq 'if (.input | type) == "array" then (.input | length) else 0 end' "$request_file") || return 1
  i=0
  while [ "$i" -lt "$count" ]; do
    if [ "$(jq -r --argjson i "$i" '.input[$i] | type' "$request_file")" = object ] \
      && [ -z "$(jq -r --argjson i "$i" '.input[$i].id // empty' "$request_file")" ]; then
      key=$(jq -c --argjson i "$i" '[$i, .input[$i].role, .input[$i].content]' "$request_file") || return 1
      msg_id="msg_$(fm_chatgpt_hash "$key" | cut -c1-32)"
      jq --argjson i "$i" --arg id "$msg_id" \
        '.input[$i] |= (if .type == null and (.role | type) == "string" then . + {type: "message"} else . end | . + {id: $id})' \
        "$request_file" > "$tmp" || { rm -f "$tmp"; return 1; }
      mv "$tmp" "$request_file"
    fi
    i=$((i + 1))
  done
  printf '%s\n' "$turn_id"
}
