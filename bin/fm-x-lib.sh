#!/usr/bin/env bash
# Shared config resolution for the X-mode connector client (fm-x-poll.sh and
# fm-x-reply.sh). X mode is opt-in: a user drops a non-empty FMX_PAIRING_TOKEN
# into the firstmate home's .env. FMX_ENV_FILE can point direct client calls at
# another .env-style file, but bootstrap activation still checks $FM_HOME/.env.
# Until then polling is a hard no-op; replies can still run in FMX_DRY_RUN
# preview mode without a token.
#
# This file is sourced, never executed. It defines:
#   fmx_env_get <key> <file>   - read one KEY=VALUE from a .env-style file
#   fmx_load_config            - resolve FMX_TOKEN, FMX_RELAY, FMX_DRY, FMX_MAX,
#                                and FMX_THREAD_MAX (env wins over .env)
#   fmx_auth_header_file       - write the bearer header to a 0600 temp file
#   fmx_split_thread <max> <cap> - split a reply (stdin) into a numbered thread
#   fmx_image_payload_file <path> <client> <payload-file> - encode one image
#                                attachment to a JSON file and print preview JSON
#   fmx_reply_payload_json <request_id> <chunks> <n> [image-json-file]
#                                - build the answer/followup POST body
#   fmx_reply_outbox_json <request_id> <chunks> <n> <followup-0|1> [image-preview-json]
#                                - build the dry-run record without image bytes
#   fmx_post_json <endpoint> <payload-file> - POST JSON to the relay, printing HTTP code
# Callers must have FM_HOME set before calling fmx_load_config.

# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset".
fmx_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}   # strip leading whitespace
  val=${val%"${val##*[![:space:]]}"}   # strip trailing whitespace (incl. CR)
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

# Resolve the X-mode settings into FMX_TOKEN, FMX_RELAY, FMX_DRY, FMX_MAX, and
# FMX_THREAD_MAX. An explicit environment variable always wins over the .env
# file; the relay URL defaults to the production host so a normal user configures
# only the token. FMX_RELAY has any trailing slash trimmed so callers can append
# "/connector/..." cleanly.
# FMX_DRY is set to "1" when FMX_DRY_RUN is a truthy value (anything other than
# unset/empty/0/false/no/off), and "" otherwise: preview mode, where the client
# composes a reply but records it instead of posting (see fm-x-reply.sh).
fmx_load_config() {
  local env_file="${FMX_ENV_FILE:-$FM_HOME/.env}" dry
  if [ -n "${FMX_PAIRING_TOKEN+x}" ]; then
    FMX_TOKEN=${FMX_PAIRING_TOKEN-}
  else
    FMX_TOKEN=$(fmx_env_get FMX_PAIRING_TOKEN "$env_file")
  fi
  if [ -n "${FMX_RELAY_URL+x}" ]; then
    FMX_RELAY=${FMX_RELAY_URL-}
  else
    FMX_RELAY=$(fmx_env_get FMX_RELAY_URL "$env_file")
  fi
  [ -n "$FMX_RELAY" ] || FMX_RELAY="https://myfirstmate.io"
  FMX_RELAY=${FMX_RELAY%/}
  if [ -n "${FMX_DRY_RUN+x}" ]; then
    dry=${FMX_DRY_RUN-}
  else
    dry=$(fmx_env_get FMX_DRY_RUN "$env_file")
  fi
  # shellcheck disable=SC2034 # FMX_DRY is read by callers (fm-x-reply.sh) after sourcing.
  case "$(printf '%s' "$dry" | tr '[:upper:]' '[:lower:]')" in
    ''|0|false|no|off) FMX_DRY="" ;;
    *) FMX_DRY=1 ;;
  esac

  # Per-tweet character budget for thread-splitting (default 280, X non-premium),
  # and the maximum number of tweets in one auto-split thread (anti-spam cap).
  local maxraw threadraw
  if [ -n "${FMX_X_REPLY_MAX_CHARS+x}" ]; then maxraw=${FMX_X_REPLY_MAX_CHARS-}; else maxraw=$(fmx_env_get FMX_X_REPLY_MAX_CHARS "$env_file"); fi
  case "$maxraw" in ''|*[!0-9]*) maxraw=280 ;; esac
  [ "$maxraw" -ge 50 ] 2>/dev/null || maxraw=50
  # shellcheck disable=SC2034 # FMX_MAX is read by callers (fm-x-reply.sh) after sourcing.
  FMX_MAX=$maxraw
  if [ -n "${FMX_X_THREAD_MAX+x}" ]; then threadraw=${FMX_X_THREAD_MAX-}; else threadraw=$(fmx_env_get FMX_X_THREAD_MAX "$env_file"); fi
  case "$threadraw" in ''|*[!0-9]*) threadraw=25 ;; esac
  [ "$threadraw" -ge 1 ] 2>/dev/null || threadraw=25
  # shellcheck disable=SC2034 # FMX_THREAD_MAX is read by callers (fm-x-reply.sh) after sourcing.
  FMX_THREAD_MAX=$threadraw
}

# Split a reply into a numbered thread of <=<max>-codepoint chunks, packing on
# word boundaries and hard-splitting any single over-long word. A reply that
# already fits in one tweet is returned as a single UNNUMBERED chunk; longer
# replies get " (k/n)" suffixes. At most <cap> tweets are produced; if the reply
# would need more, the last kept tweet is marked with an ellipsis. Reads the
# reply text on stdin and prints a compact JSON array of chunks. Length is
# codepoint-based (via jq); the relay remains the final authority and trims.
fmx_split_thread() {
  jq -Rsc --argjson limit "$1" --argjson cap "$2" '
    def hardsplit($b): . as $s | [range(0; ($s|length); $b) as $i | $s[$i:$i+$b]];
    def split_thread($limit; $cap):
      (gsub("[[:space:]]+"; " ") | gsub("^ +| +$"; "")) as $norm
      | if ($norm | length) == 0 then []
        elif ($norm | length) <= $limit then [$norm]
        else
          ($cap | tostring | length) as $digits
          | (4 + 2 * $digits) as $suffixw
          | (if ($limit - $suffixw - 1) < 1 then 1 else ($limit - $suffixw - 1) end) as $budget
          | [ $norm | split(" ")[] | if (length > $budget) then hardsplit($budget)[] else . end ] as $words
          | (reduce $words[] as $w ({chunks: [], cur: ""};
              (if .cur == "" then $w else .cur + " " + $w end) as $cand
              | if ($cand | length) <= $budget then .cur = $cand
                else .chunks += [.cur] | .cur = $w end
            )) as $st
          | ($st.chunks + (if $st.cur != "" then [$st.cur] else [] end)) as $raw
          | (if ($raw | length) > $cap
              then ($raw[0:$cap] | (.[($cap - 1)] += "…"))
              else $raw end) as $kept
          | ($kept | length) as $n
          | [ range(0; $n) as $i | $kept[$i] + " (\($i + 1)/\($n))" ]
        end;
    split_thread($limit; $cap)
  '
}

fmx_auth_header_file() {
  local file
  case "$FMX_TOKEN" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-x-auth.XXXXXX") || return 1
  chmod 600 "$file" 2>/dev/null || { rm -f "$file"; return 1; }
  printf 'Authorization: Bearer %s\n' "$FMX_TOKEN" > "$file" || { rm -f "$file"; return 1; }
  printf '%s\n' "$file"
}

fmx_image_media_type_from_path() {
  local path=$1 lower detected
  lower=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *.png) printf 'image/png\n' ;;
    *.jpg|*.jpeg) printf 'image/jpeg\n' ;;
    *.gif) printf 'image/gif\n' ;;
    *.webp) printf 'image/webp\n' ;;
    *.bmp) printf 'image/bmp\n' ;;
    *.tif|*.tiff) printf 'image/tiff\n' ;;
    *)
      if command -v file >/dev/null 2>&1; then
        detected=$(file --mime-type -b -- "$path" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        case "$detected" in
          image/png|image/jpeg|image/pjpeg|image/gif|image/webp|image/bmp|image/tiff) printf '%s\n' "$detected" ;;
          *) return 1 ;;
        esac
      else
        return 1
      fi
      ;;
  esac
}

# fmx_image_payload_file <path> <client-name> <payload-file>: validate and encode
# a local outbound image. The relay payload object is written to <payload-file>.
# The compact preview object is printed for FMX_DRY_RUN outbox records.
fmx_image_payload_file() {
  local path=$1 client=${2:-fm-x-reply} payload_file=${3:-} media_type bytes
  if [ -z "$payload_file" ]; then
    echo "$client: missing image payload destination" >&2
    return 1
  fi
  if [ ! -e "$path" ]; then
    echo "$client: image file does not exist: $path" >&2
    return 1
  fi
  if [ ! -f "$path" ]; then
    echo "$client: image path is not a regular file: $path" >&2
    return 1
  fi
  if [ ! -r "$path" ]; then
    echo "$client: image file is not readable: $path" >&2
    return 1
  fi
  media_type=$(fmx_image_media_type_from_path "$path") || {
    echo "$client: unsupported image media type for: $path" >&2
    return 1
  }
  command -v base64 >/dev/null 2>&1 || {
    echo "$client: base64 not found" >&2
    return 1
  }
  bytes=$(wc -c < "$path" | tr -d '[:space:]') || {
    echo "$client: cannot stat image file: $path" >&2
    return 1
  }
  if [ "$bytes" = 0 ]; then
    echo "$client: image file is empty: $path" >&2
    return 1
  fi
  if ! (set -o pipefail; base64 < "$path" | tr -d '\n\r' \
    | jq -Rsc --arg media_type "$media_type" \
      '{media_type:$media_type,data_base64:.}' > "$payload_file"); then
    rm -f "$payload_file"
    echo "$client: cannot read image file: $path" >&2
    return 1
  fi
  jq -cn \
    --arg media_type "$media_type" \
    --arg source_path "$path" \
    --argjson bytes "$bytes" \
    '{media_type:$media_type,bytes:$bytes,source_path:$source_path}'
}

fmx_reply_payload_json() {
  local rid=$1 chunks=$2 n=$3 image_json_file=${4:-}
  if [ -n "$image_json_file" ]; then
    if [ "$n" -le 1 ]; then
      printf '%s' "$chunks" | jq -c --arg rid "$rid" --slurpfile image "$image_json_file" \
        '{request_id:$rid, text:(.[0] // ""), image:$image[0]}'
    else
      printf '%s' "$chunks" | jq -c --arg rid "$rid" --slurpfile image "$image_json_file" \
        '{request_id:$rid, text:.[0], texts:., image:$image[0]}'
    fi
  else
    if [ "$n" -le 1 ]; then
      printf '%s' "$chunks" | jq -c --arg rid "$rid" '{request_id:$rid, text:(.[0] // "")}'
    else
      printf '%s' "$chunks" | jq -c --arg rid "$rid" '{request_id:$rid, text:.[0], texts:.}'
    fi
  fi
}

fmx_reply_outbox_json() {
  local rid=$1 chunks=$2 n=$3 followup=$4 image_preview_json=${5:-}
  if [ -n "$image_preview_json" ]; then
    if [ "$followup" = 1 ]; then
      if [ "$n" -le 1 ]; then
        printf '%s' "$chunks" | jq -c --arg rid "$rid" --argjson image "$image_preview_json" \
          '{request_id:$rid, text:(.[0] // ""), image:$image, endpoint:"followup"}'
      else
        printf '%s' "$chunks" | jq -c --arg rid "$rid" --argjson image "$image_preview_json" \
          '{request_id:$rid, text:.[0], texts:., image:$image, endpoint:"followup"}'
      fi
    else
      if [ "$n" -le 1 ]; then
        printf '%s' "$chunks" | jq -c --arg rid "$rid" --argjson image "$image_preview_json" \
          '{request_id:$rid, text:(.[0] // ""), image:$image}'
      else
        printf '%s' "$chunks" | jq -c --arg rid "$rid" --argjson image "$image_preview_json" \
          '{request_id:$rid, text:.[0], texts:., image:$image}'
      fi
    fi
  else
    if [ "$followup" = 1 ]; then
      if [ "$n" -le 1 ]; then
        printf '%s' "$chunks" | jq -c --arg rid "$rid" \
          '{request_id:$rid, text:(.[0] // ""), endpoint:"followup"}'
      else
        printf '%s' "$chunks" | jq -c --arg rid "$rid" \
          '{request_id:$rid, text:.[0], texts:., endpoint:"followup"}'
      fi
    else
      if [ "$n" -le 1 ]; then
        printf '%s' "$chunks" | jq -c --arg rid "$rid" '{request_id:$rid, text:(.[0] // "")}'
      else
        printf '%s' "$chunks" | jq -c --arg rid "$rid" '{request_id:$rid, text:.[0], texts:.}'
      fi
    fi
  fi
}

fmx_post_json() (
  local endpoint=$1 payload_file=$2 auth_header_file code rc
  command -v curl >/dev/null 2>&1 || return 127
  [ -r "$payload_file" ] || return 2
  auth_header_file=$(fmx_auth_header_file) || return 3
  trap 'rm -f "$auth_header_file"' EXIT
  trap 'rm -f "$auth_header_file"; exit 143' HUP INT TERM
  code=$(curl -m 10 -s -o /dev/null -w '%{http_code}' \
    -X POST \
    -H "@$auth_header_file" \
    -H 'Content-Type: application/json' \
    --data-binary "@$payload_file" \
    "$FMX_RELAY/connector/$endpoint" 2>/dev/null)
  rc=$?
  rm -f "$auth_header_file"
  trap - EXIT HUP INT TERM
  [ "$rc" = 0 ] || return 4
  printf '%s\n' "$code"
)

# --- task <-> X-request link (state/<id>.meta backed) -----------------------
#
# When an X mention spawns real work, the task is linked to its originating
# mention by two lines in state/<id>.meta:
#   x_request=<request_id>     the relay-issued id the follow-up posts against
#   x_request_ts=<epoch>       when the link was made, for the 24h follow-up window
# On the task's terminal completion firstmate posts ONE follow-up reply to that
# request (within the window) and clears the link. These helpers own the
# read/write/clear so fm-x-link.sh and fm-x-followup.sh never hand-edit meta and
# the rewrite stays atomic and preserves every other meta line.

# fmx_meta_get <meta> <key>: print the value of the last "key=value" line in
# <meta>, or nothing (and succeed) when the file or key is absent. Callers treat
# empty output as "unset".
fmx_meta_get() {
  local meta=$1 key=$2 line
  [ -f "$meta" ] || return 0
  line=$(grep -E "^${key}=" "$meta" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  printf '%s' "${line#*=}"
}

fmx_meta_tmp() {
  local meta=$1 dir base
  dir=${meta%/*}
  base=${meta##*/}
  [ "$dir" != "$meta" ] || dir=.
  [ -d "$dir" ] || return 1
  mktemp "$dir/.${base}.fm-x.XXXXXX"
}

# fmx_meta_link_set <meta> <request_id> <epoch>: atomically (re)write the
# x_request/x_request_ts lines, dropping any prior link and preserving every
# other meta line. Returns non-zero if <meta> is missing or the rewrite fails.
fmx_meta_link_set() {
  local meta=$1 rid=$2 ts=$3 tmp
  [ -f "$meta" ] || return 1
  tmp=$(fmx_meta_tmp "$meta") || return 1
  if ! { grep -vE '^x_request=|^x_request_ts=' "$meta" || true; } > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  printf 'x_request=%s\n' "$rid" >> "$tmp" || { rm -f "$tmp"; return 1; }
  printf 'x_request_ts=%s\n' "$ts" >> "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
}

# fmx_meta_link_clear <meta>: atomically remove the x_request/x_request_ts lines
# while preserving every other meta line. Idempotent: succeeds whether or not a
# link is present, and is a no-op when <meta> is missing.
fmx_meta_link_clear() {
  local meta=$1 tmp
  [ -f "$meta" ] || return 0
  tmp=$(fmx_meta_tmp "$meta") || return 1
  if ! { grep -vE '^x_request=|^x_request_ts=' "$meta" || true; } > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  mv -f "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
}
