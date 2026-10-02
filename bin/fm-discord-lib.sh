#!/usr/bin/env bash
# Shared Discord integration library for Firstmate's first-class Discord channel.
#
# Firstmate has no TypeScript ChatIntegration interface; the closest existing
# abstraction is the Relay (fm-x-*) bash contract: .env secrets via
# bin/fm-env-lib.sh (env wins over file), private state artifacts under
# state/ with mode 600/700, inbox/outbox JSON files, thread-split helpers,
# and watcher wakes shaped as "<kind> <id>". This library adapts that
# contract to a directly-connected Discord bot instead of introducing a
# parallel architecture:
#
#   discord_send_message <channel-id> <text>  -> bin/fm-discord-send.sh
#   discord_get_messages <channel-id>         -> bin/fm-discord-poll.sh
#
# Secrets (never logged): DISCORD_CLIENT_ID, DISCORD_CLIENT_SECRET,
# DISCORD_BOT_TOKEN, DISCORD_PUBLIC_KEY via $FM_HOME/.env (or
# DISCORD_ENV_FILE override); environment wins over the file, matching the
# Relay contract. Non-secret guild/channel binding lives in
# config/discord.json (mode 600). Inbound authorization is owner-only for
# this pass: DISCORD_OWNER_USER_ID names the single authorized user; every
# inbound path refuses closed when the sender, guild, channel, or
# configuration is unknown, before anything reaches the agent pipeline.
#
# This file is sourced, never executed. Callers set their own shell options;
# this library must not set -u itself. It defines:
#   discord_load_config      - resolve DISCORD_* into DISCORD_* vars
#   discord_redact <text>    - strip token-looking substrings for logs
#   discord_config_path      - print config/discord.json path for this home
#   discord_state_dir <name> - ensure state/discord-<name> exists (0700)
#   discord_chunk_text       - split stdin into Discord-unit-safe chunks
#   discord_api <method> <path> [body-file] [out-file] - authenticated REST call
#   discord_oauth_authorize_url <redirect> <state> - print OAuth2 install URL
#   discord_oauth_state_new / discord_oauth_state_check <state> - CSRF protection
#   discord_is_self <author-id> - 0 when the author is our own bot user
#   discord_self_known       - 0 when the bot user id is resolved
#   discord_seen_claim <event-id> - atomically claim a dedup marker; 0=new
#   discord_require_guild <guild-id> - 0 when guild is the configured one
#   discord_authorize_sender <user> <guild> <channel> - owner-only routing gate
#   discord_validate_config  - fail-closed configuration check for operators
#   discord_poll_shim_content / discord_poll_shim_valid - watcher shim contract
#   discord_mode_setup       - arm/remove the watcher shim + cadence (bootstrap)
#
# Callers must have FM_HOME set. Nothing here prints a secret.

_DISCORD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-env-lib.sh
. "$_DISCORD_LIB_DIR/fm-env-lib.sh"

DISCORD_API_BASE_DEFAULT="https://discord.com/api/v10"
# OAuth2 token exchange is unversioned upstream; keep it off the /v10 base.
DISCORD_OAUTH_BASE_DEFAULT="https://discord.com/api"
# Chunk budget in Discord UTF-16 code units (see discord_chunk_text), kept
# below the 2000-unit API limit.
DISCORD_CHUNK_BUDGET=1990
# Minimal permission bits the bot operations need: Send Messages (2048) for
# outbound replies plus Read Message History (65536) for the bounded REST
# poll fallback. Request nothing else: no administrator, no manage-server,
# no View Channel override beyond what the install guild already grants.
DISCORD_MIN_PERMISSIONS="67584"
# Minimal OAuth2 scopes for bot install + slash commands. No privileged scopes.
DISCORD_OAUTH_SCOPES="bot applications.commands"
# Minimal gateway intents: GUILDS (1<<0) for guild/channel structure plus
# GUILD_MESSAGES (1<<9), which is the intent that actually delivers
# MESSAGE_CREATE. Message content intent (1<<15) is NOT enabled by default;
# see docs/discord-integration.md for the isolated opt-in.
# DISCORD_INTENT_* bits live in bin/fm-discord-gateway.py, the single place
# that identifies to the Gateway; see docs/discord-integration.md for the
# operator view.
# OAuth CSRF state lifetime: single-use and rejected after ten minutes.
DISCORD_OAUTH_STATE_TTL=600
# Dedup marker retention, mirroring the Relay's seven-day offer registry.
DISCORD_SEEN_RETENTION_DAYS=7

discord_env_file() {
  printf '%s\n' "${DISCORD_ENV_FILE:-${FM_HOME:-}/.env}"
}

discord_load_config() {
  local env_file
  env_file=$(discord_env_file)
  if [ -n "${DISCORD_CLIENT_ID+x}" ]; then DISCORD_CLIENT_ID=${DISCORD_CLIENT_ID-}; else DISCORD_CLIENT_ID=$(fmx_env_get DISCORD_CLIENT_ID "$env_file"); fi
  if [ -n "${DISCORD_CLIENT_SECRET+x}" ]; then DISCORD_CLIENT_SECRET=${DISCORD_CLIENT_SECRET-}; else DISCORD_CLIENT_SECRET=$(fmx_env_get DISCORD_CLIENT_SECRET "$env_file"); fi
  if [ -n "${DISCORD_BOT_TOKEN+x}" ]; then DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN-}; else DISCORD_BOT_TOKEN=$(fmx_env_get DISCORD_BOT_TOKEN "$env_file"); fi
  if [ -n "${DISCORD_PUBLIC_KEY+x}" ]; then DISCORD_PUBLIC_KEY=${DISCORD_PUBLIC_KEY-}; else DISCORD_PUBLIC_KEY=$(fmx_env_get DISCORD_PUBLIC_KEY "$env_file"); fi
  if [ -n "${DISCORD_GUILD_ID+x}" ]; then DISCORD_GUILD_ID=${DISCORD_GUILD_ID-}; else DISCORD_GUILD_ID=$(fmx_env_get DISCORD_GUILD_ID "$env_file"); fi
  if [ -n "${DISCORD_OWNER_USER_ID+x}" ]; then DISCORD_OWNER_USER_ID=${DISCORD_OWNER_USER_ID-}; else DISCORD_OWNER_USER_ID=$(fmx_env_get DISCORD_OWNER_USER_ID "$env_file"); fi
  if [ -n "${DISCORD_CHANNEL_IDS+x}" ]; then DISCORD_CHANNEL_IDS=${DISCORD_CHANNEL_IDS-}; else DISCORD_CHANNEL_IDS=$(fmx_env_get DISCORD_CHANNEL_IDS "$env_file"); fi
  if [ -n "${DISCORD_CHANNEL_ID+x}" ]; then DISCORD_CHANNEL_ID=${DISCORD_CHANNEL_ID-}; else DISCORD_CHANNEL_ID=$(fmx_env_get DISCORD_CHANNEL_ID "$env_file"); fi
  if [ -n "${DISCORD_BOT_USER_ID+x}" ]; then DISCORD_BOT_USER_ID=${DISCORD_BOT_USER_ID-}; else DISCORD_BOT_USER_ID=$(fmx_env_get DISCORD_BOT_USER_ID "$env_file"); fi
  if [ -n "${DISCORD_SEND_CHANNEL_IDS+x}" ]; then DISCORD_SEND_CHANNEL_IDS=${DISCORD_SEND_CHANNEL_IDS-}; else DISCORD_SEND_CHANNEL_IDS=$(fmx_env_get DISCORD_SEND_CHANNEL_IDS "$env_file"); fi
  if [ -n "${DISCORD_REDIRECT_URI+x}" ]; then DISCORD_REDIRECT_URI=${DISCORD_REDIRECT_URI-}; else DISCORD_REDIRECT_URI=$(fmx_env_get DISCORD_REDIRECT_URI "$env_file"); fi
  if [ -n "${DISCORD_API_BASE+x}" ]; then :; else DISCORD_API_BASE=$(fmx_env_get DISCORD_API_BASE "$env_file"); fi
  [ -n "${DISCORD_API_BASE:-}" ] || DISCORD_API_BASE="$DISCORD_API_BASE_DEFAULT"
  DISCORD_API_BASE=${DISCORD_API_BASE%/}
  if [ -n "${DISCORD_OAUTH_BASE+x}" ]; then :; else DISCORD_OAUTH_BASE=$(fmx_env_get DISCORD_OAUTH_BASE "$env_file"); fi
  [ -n "${DISCORD_OAUTH_BASE:-}" ] || DISCORD_OAUTH_BASE="$DISCORD_OAUTH_BASE_DEFAULT"
  DISCORD_OAUTH_BASE=${DISCORD_OAUTH_BASE%/}
  # Message-content intent is an isolated opt-in, never default-on.
  if [ -n "${DISCORD_MESSAGE_CONTENT+x}" ]; then :; else DISCORD_MESSAGE_CONTENT=$(fmx_env_get DISCORD_MESSAGE_CONTENT "$env_file"); fi
  case "$(printf '%s' "${DISCORD_MESSAGE_CONTENT:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) DISCORD_MESSAGE_CONTENT=1 ;;
    *) DISCORD_MESSAGE_CONTENT="" ;;
  esac
  export DISCORD_CLIENT_ID DISCORD_CLIENT_SECRET DISCORD_BOT_TOKEN DISCORD_PUBLIC_KEY
  export DISCORD_GUILD_ID DISCORD_OWNER_USER_ID DISCORD_CHANNEL_IDS DISCORD_SEND_CHANNEL_IDS
  export DISCORD_CHANNEL_ID DISCORD_BOT_USER_ID
  export DISCORD_REDIRECT_URI DISCORD_API_BASE DISCORD_OAUTH_BASE DISCORD_MESSAGE_CONTENT
}

discord_redact() {
  # Replace Discord token shapes (three base64url segments) and any loaded
  # secret value with *** so logs never carry credentials. Secrets are
  # substituted with literal bash replacement (never interpolated into a
  # regex) so hostile characters in a secret cannot alter the match.
  local text=${1:-} secret
  text=$(printf '%s' "$text" | sed -E 's/[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_.-]{5,}\.[A-Za-z0-9_.-]{10,}/***/g')
  for secret in "${DISCORD_BOT_TOKEN:-}" "${DISCORD_CLIENT_SECRET:-}"; do
    [ -n "$secret" ] && [ "${#secret}" -ge 8 ] || continue
    text=${text//"$secret"/***}
  done
  printf '%s' "$text"
}

discord_config_path() {
  local cfg="${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}"
  printf '%s/discord.json\n' "$cfg"
}

discord_private_dir() {
  # Ensure $1 exists as a real directory (never a symlink) with the given
  # mode, creating it when absent. Prints the path; non-zero on any refusal.
  local dir=$1 mode=${2:-700}
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  else
    (umask 077; mkdir -p "$dir" 2>/dev/null) || return 1
  fi
  chmod "$mode" "$dir" 2>/dev/null || return 1
  printf '%s\n' "$dir"
}

discord_state_dir() {
  local state="${FM_STATE_OVERRIDE:-${FM_HOME:-}/state}"
  discord_private_dir "$state/$1" 700
}

discord_configured() {
  [ -n "${DISCORD_BOT_TOKEN:-}" ] && [ -n "${DISCORD_CLIENT_ID:-}" ]
}

discord_config_json() {
  # Print a config/discord.json field (or empty) without ever failing loudly.
  local field=$1 cfg
  cfg=$(discord_config_path)
  [ -f "$cfg" ] || return 0
  jq -r --arg f "$field" '.[$f] // empty' "$cfg" 2>/dev/null || true
}

discord_effective_guild() {
  if [ -n "${DISCORD_GUILD_ID:-}" ]; then printf '%s\n' "$DISCORD_GUILD_ID"; return 0; fi
  discord_config_json guild_id
}

discord_effective_owner() {
  if [ -n "${DISCORD_OWNER_USER_ID:-}" ]; then printf '%s\n' "$DISCORD_OWNER_USER_ID"; return 0; fi
  discord_config_json owner_user_id
}

discord_effective_bot_id() {
  if [ -n "${DISCORD_BOT_USER_ID:-}" ]; then printf '%s\n' "$DISCORD_BOT_USER_ID"; return 0; fi
  discord_config_json bot_user_id
}

discord_effective_channel() {
  if [ -n "${DISCORD_CHANNEL_ID:-}" ]; then printf '%s\n' "$DISCORD_CHANNEL_ID"; return 0; fi
  discord_config_json poll_channel_id
}

discord_channel_allowed() {
  # 0 when the channel passes the optional DISCORD_CHANNEL_IDS allowlist.
  # An empty allowlist permits any channel inside the authorized guild.
  local channel=${1:-} allow
  allow=${DISCORD_CHANNEL_IDS:-}
  [ -n "$allow" ] || return 0
  [ -n "$channel" ] || return 1
  case ",$allow," in *",$channel,"*) return 0 ;; *) return 1 ;; esac
}

discord_authorize_sender() {
  # Owner-only inbound gate for this pass, checked before anything reaches
  # the agent pipeline. Broader policies plug in here later without
  # rewriting the callers: every inbound path funnels through this one
  # function. Fails closed on unknown sender, guild, channel, or missing
  # configuration. Prints nothing; callers log the redacted refusal.
  local user=${1:-} guild=${2:-} channel=${3:-} owner want
  [ -n "$user" ] || return 1
  owner=$(discord_effective_owner)
  [ -n "$owner" ] || return 1
  [ "$user" = "$owner" ] || return 1
  want=$(discord_effective_guild)
  [ -n "$want" ] || return 1
  [ -n "$guild" ] && [ "$guild" = "$want" ] || return 1
  discord_channel_allowed "$channel" || return 1
  return 0
}

discord_require_guild() {
  # 0 when guild-id matches the configured guild. Fails closed: with no
  # guild configured (env or verified config), nothing is accepted.
  local guild=${1:-} want
  want=$(discord_effective_guild)
  [ -n "$want" ] || return 1
  [ -n "$guild" ] && [ "$guild" = "$want" ]
}

discord_is_self() {
  # 0 (true) when author-id matches our bot user id from env or config.
  local author=${1:-} self
  self=$(discord_effective_bot_id)
  [ -n "$author" ] && [ -n "$self" ] && [ "$author" = "$self" ]
}

discord_self_known() {
  # 0 when the bot user id is resolved. Polling refuses until this holds so
  # a half-configured home can never loop on its own replies.
  [ -n "$(discord_effective_bot_id)" ]
}

discord_validate_config() {
  # Fail-closed configuration check for operators and tests. Prints one
  # diagnostic per problem to stderr; 0 only when inbound routing is fully
  # armed (token, guild, owner, resolved bot id).
  local rc=0
  discord_load_config
  if [ -z "${DISCORD_BOT_TOKEN:-}" ]; then echo "discord: DISCORD_BOT_TOKEN not configured" >&2; rc=1; fi
  if [ -z "$(discord_effective_guild)" ]; then echo "discord: no guild binding (run init/callback/verify or set DISCORD_GUILD_ID)" >&2; rc=1; fi
  if [ -z "$(discord_effective_owner)" ]; then echo "discord: DISCORD_OWNER_USER_ID not configured; inbound routing refuses everything until the owner is set" >&2; rc=1; fi
  if ! discord_self_known; then echo "discord: bot user id unknown (run verify); polling refuses until it is resolved" >&2; rc=1; fi
  return "$rc"
}

discord_diag_throttled() {
  # Print a misconfiguration diagnostic at most once per <ttl> seconds so a
  # watcher-cadence poll does not spam stderr every cycle. Always succeeds.
  local name=$1 ttl=$2; shift 2
  local dir marker now last
  dir=$(discord_state_dir "discord-diag") 2>/dev/null || { printf '%s\n' "$*"; return 0; }
  case "$name" in ''|.*|*[!A-Za-z0-9._-]*) printf '%s\n' "$*"; return 0 ;; esac
  marker="$dir/$name"
  now=$(date +%s)
  last=$(cat "$marker" 2>/dev/null || printf '0')
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -ge "$ttl" ]; then
    printf '%s' "$now" > "$marker" 2>/dev/null || true
    printf '%s\n' "$*"
  fi
  return 0
}

discord_chunk_text() {
  # Split stdin into Discord-safe chunks, printed as a JSON array. Length is
  # measured in Discord's UTF-16 code units (astral characters such as emoji
  # occupy two units each while jq length counts codepoints), so a chunk can
  # never exceed the 2000-unit API limit no matter the script mix. Splits on
  # paragraph/line/word boundaries; hard-splits only a single over-long
  # unit, regrouped by the same unit measure.
  local budget=${1:-$DISCORD_CHUNK_BUDGET}
  jq -Rsc --argjson limit "$budget" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def ulen: length + ((explode | map(select(. > 65535)) | length));
    def hardsplit($b):
      explode as $cps
      | (reduce $cps[] as $cp ({runs:[], cur:[], w:0};
           (if $cp > 65535 then 2 else 1 end) as $u
           | if .w + $u > $b and ((.cur | length) > 0)
             then .runs += [(.cur | implode)] | .cur = [$cp] | .w = $u
             else .cur += [$cp] | .w += $u end)) as $st
      | $st.runs + (if ($st.cur | length) > 0 then [($st.cur | implode)] else [] end);
    def wordsplit($b):
      (gsub("[[:space:]]+"; " ") | trim) as $norm
      | if ($norm|ulen) == 0 then []
        else [ $norm | split(" ")[] | if (ulen > $b) then hardsplit($b)[] else . end ]
          | (reduce .[] as $w ({chunks:[],cur:""};
              (if .cur == "" then $w else .cur + " " + $w end) as $cand
              | if ($cand|ulen) <= $b then .cur = $cand
                else .chunks += (if .cur == "" then [] else [.cur] end) | .cur = $w end))
          as $st | $st.chunks + (if $st.cur != "" then [$st.cur] else [] end) end;
    trim as $norm
    | if ($norm|ulen) == 0 then []
      elif ($norm|ulen) <= $limit then [$norm]
      else (($norm | split("\n\n") | map(trim) | map(select(length > 0))) as $units
        | (reduce $units[] as $u ({chunks:[],cur:""};
            if ($u|ulen) > $limit then
              (if .cur != "" then .chunks += [.cur] | .cur = "" else . end)
              | .chunks += ($u | wordsplit($limit))
            else (if .cur == "" then $u else .cur + "\n\n" + $u end) as $cand
              | if ($cand|ulen) <= $limit then .cur = $cand
                else .chunks += (if .cur == "" then [] else [.cur] end) | .cur = $u end
            end)) as $st
        | $st.chunks + (if $st.cur != "" then [$st.cur] else [] end)) end
  '
}

discord_chunk_units() {
  # Print the Discord UTF-16 unit length of stdin. Exposed for tests.
  jq -Rsc 'length + ((explode | map(select(. > 65535)) | length))'
}

discord_auth_header_file() {
  local file
  case "${DISCORD_BOT_TOKEN:-}" in ''|*$'\n'*|*$'\r'*) return 1 ;; esac
  file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-discord-auth.XXXXXX") || return 1
  chmod 600 "$file" 2>/dev/null || { rm -f "$file"; return 1; }
  printf 'Authorization: Bot %s\n' "$DISCORD_BOT_TOKEN" > "$file" || { rm -f "$file"; return 1; }
  printf '%s\n' "$file"
}

# discord_api <method> <api-path> [body-file] [out-file]
# Prints "<http-code> <retry-after-secs-or-0>" on stdout. Honors 429
# Retry-After (header first, then JSON body) and never logs the token.
# Runs in a subshell so its temp-file EXIT trap can never clobber the
# caller's own EXIT trap (mirroring fmx_post_json in bin/fm-x-lib.sh).
discord_api() (
  local method=$1 path=$2 body_file=${3:-} out_file=${4:-/dev/null}
  local auth code retry_after dump
  command -v curl >/dev/null 2>&1 || return 127
  [ -n "${DISCORD_BOT_TOKEN:-}" ] || return 3
  auth=$(discord_auth_header_file) || return 3
  dump=$(mktemp "${TMPDIR:-/tmp}/fm-discord-hdr.XXXXXX") || { rm -f "$auth"; return 1; }
  trap 'rm -f "$auth" "$dump"' EXIT
  trap 'rm -f "$auth" "$dump"; exit 143' HUP INT TERM
  if [ -n "$body_file" ]; then
    code=$(curl -m 15 -s -D "$dump" -o "$out_file" -w '%{http_code}' -X "$method" \
      -H "@$auth" -H 'Content-Type: application/json' --data-binary "@$body_file" \
      "$DISCORD_API_BASE$path" 2>/dev/null)
  else
    code=$(curl -m 15 -s -D "$dump" -o "$out_file" -w '%{http_code}' -X "$method" \
      -H "@$auth" -H 'Accept: application/json' \
      "$DISCORD_API_BASE$path" 2>/dev/null)
  fi
  # shellcheck disable=SC2181
  [ "$?" = 0 ] || { rm -f "$auth" "$dump"; trap - EXIT HUP INT TERM; return 4; }
  retry_after=$(grep -i '^retry-after:' "$dump" 2>/dev/null | tail -n1 | awk '{print $2}' | tr -d '\r' || true)
  case "$retry_after" in ''|*[!0-9.]*) retry_after=0 ;; esac
  if [ "$code" = 429 ] && [ "$retry_after" = 0 ] && [ -s "$out_file" ]; then
    retry_after=$(jq -r '.retry_after // 0' "$out_file" 2>/dev/null || printf '0')
    case "$retry_after" in ''|*[!0-9.]*) retry_after=0 ;; esac
  fi
  rm -f "$auth" "$dump"
  trap - EXIT HUP INT TERM
  printf '%s %s\n' "$code" "$retry_after"
)

discord_oauth_authorize_url() {
  # discord_oauth_authorize_url <redirect-uri> <state> [permissions]
  local redirect=$1 state=$2 perms=${3:-$DISCORD_MIN_PERMISSIONS} scope
  scope=$(printf '%s' "$DISCORD_OAUTH_SCOPES" | sed 's/ /%20/g')
  printf 'https://discord.com/oauth2/authorize?client_id=%s&permissions=%s&scope=%s&redirect_uri=%s&response_type=code&state=%s\n' \
    "$DISCORD_CLIENT_ID" "$perms" "$scope" "$(printf '%s' "$redirect" | jq -sRr @uri)" "$(printf '%s' "$state" | jq -sRr @uri)"
}

discord_oauth_state_new() {
  local state_dir state_file token
  state_dir=$(discord_state_dir "discord-oauth") || return 1
  state_file="$state_dir/state"
  if command -v openssl >/dev/null 2>&1; then
    token=$(openssl rand -hex 16 2>/dev/null) || token=
  fi
  if [ -z "${token:-}" ] && [ -r /dev/urandom ]; then
    token=$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n') || token=
  fi
  # Fail closed when no CSPRNG is available rather than minting a
  # predictable state token.
  [ -n "${token:-}" ] || return 1
  (umask 077; printf '%s' "$token" > "$state_file") || return 1
  chmod 600 "$state_file" 2>/dev/null || return 1
  printf '%s\n' "$token"
}

discord_file_age() {
  # Print the age of $1 in seconds, or a large number when unknowable.
  local file=$1 mtime now
  if [ "$(uname)" = Darwin ]; then mtime=$(/usr/bin/stat -f %m "$file" 2>/dev/null); else mtime=$(stat -c %Y "$file" 2>/dev/null); fi
  now=$(date +%s)
  case "$mtime" in ''|*[!0-9]*) printf '999999999\n'; return 0 ;; esac
  printf '%s\n' $((now - mtime))
}

discord_oauth_state_check() {
  # Single-use CSRF check with a short TTL: a matching state is consumed
  # (deleted) on first success, so a leaked value is never replayable, and
  # states older than DISCORD_OAUTH_STATE_TTL are refused.
  local want=$1 state_dir state_file have
  state_dir=$(discord_state_dir "discord-oauth") || return 1
  state_file="$state_dir/state"
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  have=$(cat "$state_file" 2>/dev/null) || return 1
  [ -n "$want" ] && [ -n "$have" ] && [ "$want" = "$have" ] || return 1
  [ "$(discord_file_age "$state_file")" -le "$DISCORD_OAUTH_STATE_TTL" ] || { rm -f "$state_file"; return 1; }
  rm -f "$state_file"
}

discord_seen_claim() {
  # Atomically claim dedup marker state/discord-seen/<event-id>. Returns
  # 0=new (caller processes), 1=duplicate, 2=error. Markers older than
  # DISCORD_SEEN_RETENTION_DAYS are pruned on each claim so the store stays
  # bounded like the Relay's offer registry.
  local id=$1 dir file tmp
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*) return 2 ;; esac
  dir=$(discord_state_dir "discord-seen") || return 2
  file="$dir/$id"
  [ -e "$file" ] && return 1
  tmp=$(umask 077; mktemp "$dir/.claim.XXXXXX" 2>/dev/null) || return 2
  if ! printf '%s\n' "$(date +%s)" > "$tmp" || ! chmod 600 "$tmp"; then rm -f "$tmp"; return 2; fi
  if ln -- "$tmp" "$file" 2>/dev/null; then rm -f "$tmp"; else rm -f "$tmp"; [ -e "$file" ] && return 1; return 2; fi
  find "$dir" -type f -mtime +"$DISCORD_SEEN_RETENTION_DAYS" -delete 2>/dev/null || true
  return 0
}

# --- watcher wiring (owned here; armed by fm-bootstrap.sh, run by fm-watch.sh)
#
# When this home's .env carries a non-empty DISCORD_BOT_TOKEN, bootstrap arms
# the native poll into the existing watcher dispatch with two idempotent,
# gitignored artifacts:
#   state/discord-watch.check.sh - byte-static identity shim; the watcher
#                                  validates its bytes and invokes
#                                  bin/fm-discord-poll.sh directly (no channel
#                                  argument: the poll resolves its channel
#                                  from configuration and stays silent when
#                                  the REST fallback is unconfigured)
#   config/discord-mode.env      - exports FM_CHECK_INTERVAL=30, sourced before
#                                  the watcher starts so a Discord instance
#                                  polls at the 30s cadence
# On opt-out (no token, or empty) it removes any such artifacts so the
# instance reverts to the default cadence. Absent a token AND with no
# leftover artifacts it is a complete no-op.

discord_poll_shim_content() {
  local home=$1 root=$2
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-bootstrap.sh - Discord native poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted poll script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$root/bin/fm-discord-poll.sh")"
}

discord_single_link_file_valid() {
  local file=$1 mode=${2:-} device links m
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    links=$(/usr/bin/stat -f %l "$file" 2>/dev/null) || return 1
    device=$(/usr/bin/stat -f %d "$file" 2>/dev/null) || return 1
    m=$(/usr/bin/stat -f %Lp "$file" 2>/dev/null) || return 1
  else
    links=$(stat -c %h "$file" 2>/dev/null) || return 1
    device=$(stat -c %d "$file" 2>/dev/null) || return 1
    m=$(stat -c %a "$file" 2>/dev/null) || return 1
  fi
  [ "$links" = 1 ] || return 1
  if [ -n "${3-}" ]; then [ "$device" = "$3" ] || return 1; fi
  [ -z "$mode" ] || [ "$m" = "$mode" ]
}

discord_poll_shim_valid() {
  local file=$1 home=$2 root=$3
  discord_single_link_file_valid "$file" 700 || return 1
  cmp -s "$file" <(discord_poll_shim_content "$home" "$root")
}

discord_write_artifact() {
  # Atomically write <content> to <dest> with <mode>, refusing symlinks and
  # verifying bytes after the move. Content arrives via stdin.
  local dest=$1 mode=$2 parent tmp parent_device
  parent=${dest%/*}
  [ "$parent" != "$dest" ] || return 1
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    parent_device=$(/usr/bin/stat -f %d "$parent" 2>/dev/null) || return 1
  else
    parent_device=$(stat -c %d "$parent" 2>/dev/null) || return 1
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    discord_single_link_file_valid "$dest" "" "$parent_device" || return 1
  fi
  tmp=$(umask 077; mktemp "$parent/.fm-discord-mode.XXXXXX" 2>/dev/null) || return 1
  if ! cat > "$tmp" || ! chmod "$mode" "$tmp"; then rm -f -- "$tmp"; return 1; fi
  if { [ -e "$dest" ] || [ -L "$dest" ]; } \
    && ! discord_single_link_file_valid "$dest" "" "$parent_device"; then
    rm -f -- "$tmp"; return 1
  fi
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
  discord_single_link_file_valid "$dest" "$mode" "$parent_device"
}

discord_mode_setup() {
  local home state config env_file token shim cadence shim_body cadence_body root
  home="${FM_HOME:-}"
  [ -n "$home" ] || return 0
  state="${FM_STATE_OVERRIDE:-$home/state}"
  config="${FM_CONFIG_OVERRIDE:-$home/config}"
  env_file="${DISCORD_ENV_FILE:-$home/.env}"
  root="${FM_ROOT:-${FM_ROOT_OVERRIDE:-$(cd "$_DISCORD_LIB_DIR/.." && pwd)}}"
  shim="$state/discord-watch.check.sh"
  cadence="$config/discord-mode.env"
  token=
  if [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
    token=$DISCORD_BOT_TOKEN
  else
    token=$(fmx_env_get DISCORD_BOT_TOKEN "$env_file")
  fi
  if [ -e "$shim" ] || [ -L "$shim" ]; then
    [ -f "$shim" ] && [ ! -L "$shim" ] || rm -f -- "$shim" 2>/dev/null || true
  fi
  if [ -z "$token" ]; then
    # Opt-out: drop any Discord artifacts; stay silent unless we removed some.
    if [ -e "$shim" ] || [ -L "$shim" ] || [ -e "$cadence" ] || [ -L "$cadence" ]; then
      rm -f -- "$shim" "$cadence" 2>/dev/null
      if [ ! -e "$shim" ] && [ ! -e "$cadence" ]; then
        echo "DISCORD: Discord mode off - removed native poll shim and 30s cadence"
      else
        echo "DISCORD: Discord mode off - failed to remove native poll shim or 30s cadence"
      fi
    fi
    return 0
  fi
  for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "MISSING: $tool (Discord poll dependency)"
      return 0
    fi
  done
  mkdir -p "$state" "$config" 2>/dev/null || { echo "DISCORD: Discord mode off - cannot create state/config dirs"; return 0; }
  case "$home" in
    /*) ;;
    *) home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || { echo "DISCORD: Discord mode off - cannot resolve home"; return 0; } ;;
  esac
  shim_body=$(discord_poll_shim_content "$home" "$root")
  printf '%s\n' "$shim_body" | discord_write_artifact "$shim" 700 \
    || { echo "DISCORD: Discord mode off - failed to arm native poll shim"; return 0; }
  discord_poll_shim_valid "$shim" "$home" "$root" \
    || { echo "DISCORD: Discord mode off - failed to arm native poll shim"; return 0; }
  cadence_body=$(cat <<'EOF'
# Auto-generated by fm-bootstrap.sh - Discord native poll watcher cadence.
# Source this before the active harness protocol starts a watcher process so
# fm-watch.sh polls the Discord check every 30s. Homes without Discord have no
# such file and keep the default 300s cadence.
export FM_CHECK_INTERVAL=30
EOF
)
  printf '%s\n' "$cadence_body" | discord_write_artifact "$cadence" 600 \
    || { echo "DISCORD: Discord mode off - failed to arm 30s cadence"; return 0; }
  echo "DISCORD: Discord mode on - native poll armed via state/discord-watch.check.sh; 30s watcher cadence in config/discord-mode.env"
}
