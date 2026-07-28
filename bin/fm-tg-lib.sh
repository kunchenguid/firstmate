#!/usr/bin/env bash
# Shared library for firstmate's private Telegram bridge.
#
# This file is sourced, never executed. It is the single owner of the bridge's
# wire mechanics and private-state schema; policy for what a message may cause
# lives in the agent-only `telegram-respond` skill, and the operator-facing
# contract lives in docs/configuration.md "Telegram bridge (.env)".
#
# Inert by default. Every entry point resolves configuration first and does
# nothing at all when FM_TELEGRAM_BOT_TOKEN is absent or empty, so a home that
# never opts in writes no files, contacts no host, and changes no behavior.
#
# Token handling, which the rest of this file depends on:
#   - The Bot API puts the token in the URL PATH, so the token would land in
#     `curl`'s argv and be readable by any local process through `ps`. Every
#     request is therefore issued through a `curl --config` stream piped on
#     stdin, so the token never appears in an argument vector, on disk, in a log
#     line, in an error message, or in any state file. It is streamed rather
#     than written to a temporary because the watcher SIGKILLs a check that
#     outruns its budget, and no cleanup can run after that.
#   - The token is validated against BotFather's shape before use, so a
#     malformed value is refused rather than interpolated into a config file.
#   - fmtg_redact scrubs the token from anything a caller is about to print.
#
# It defines, grouped by concern:
#   config     fmtg_load_config, fmtg_active, fmtg_redact, fmtg_now
#   budget     fmtg_budget_open, fmtg_budget_remaining
#   arming     fmtg_poll_shim_content, fmtg_poll_shim_valid
#   paths      fmtg_dir, fmtg_request_id_valid, fmtg_update_id_valid
#   wire       fmtg_api_call <method> <payload-file|-> <body-file>
#   pairing    fmtg_pairing_set/get/clear/attempt, fmtg_peer_set/get/clear,
#              fmtg_random_code, fmtg_code_hash
#   inbound    fmtg_offset_get/set, fmtg_seen_claim, fmtg_normalize_text_program,
#              fmtg_rate_allow
#   recovery   fmtg_announce_count, fmtg_announce_bump
#   context    fmtg_context_set/get/clear/prune
#   outbound   fmtg_send_text, fmtg_outbox_record
#   task link  fmtg_meta_get, fmtg_meta_link_set, fmtg_meta_link_clear
#   publish    fmtg_publish_arm, fmtg_publish_attempt, fmtg_publish_confirm,
#              fmtg_publish_show, fmtg_publish_clear
#
# Callers must have FM_HOME set before calling fmtg_load_config. jq and curl are
# required for live calls; jq alone is enough for dry-run and local state work.

FM_TG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-private-artifact-lib.sh
. "$FM_TG_LIB_DIR/fm-private-artifact-lib.sh"
# shellcheck source=bin/fm-message-split-lib.sh
. "$FM_TG_LIB_DIR/fm-message-split-lib.sh"
# shellcheck source=bin/fm-env-file-lib.sh
. "$FM_TG_LIB_DIR/fm-env-file-lib.sh"

# Unambiguous code alphabet: no 0/O, no 1/I/l, so a code read aloud or typed on a
# phone cannot become a different valid code.
FMTG_CODE_ALPHABET='23456789ABCDEFGHJKMNPQRSTUVWXYZ'

# Seconds held back from the watcher's per-check budget, twice: once so curl's
# deadline lands before the watcher's kill, and once more so Telegram closes the
# long poll before curl's deadline. Sized for the slowest realistic tail of one
# cycle's local work (a full batch of jq-normalized updates plus the prune).
FMTG_BUDGET_RESERVE=5

# Floor for a call issued when almost nothing is left: a sub-second deadline
# would only guarantee failure, and this still lands inside the reserve.
FMTG_BUDGET_MIN=2

# --- config -----------------------------------------------------------------

# Resolve the bridge settings. An explicit environment variable always wins over
# the home's .env, matching the X-mode precedence so one home can be driven by
# either. Sets:
#   FMTG_TOKEN        the bot token, or "" when the bridge is off
#   FMTG_TOKEN_BAD    "1" when a token is present but malformed
#   FMTG_API          API base, default https://api.telegram.org
#   FMTG_DRY          "1" in dry-run preview mode
#   FMTG_POLL_TIMEOUT long-poll seconds held open per getUpdates call
#   FMTG_CHECK_TIMEOUT   the watcher's per-check kill budget this poll runs under
#   FMTG_REQUEST_TIMEOUT curl deadline for one API call, inside that budget
#   FMTG_MAX_CHARS    per-message outbound budget
#   FMTG_MAX_MESSAGES cap on one split reply
#   FMTG_MAX_TEXT     inbound text bound, above which a message is "oversized"
#   FMTG_RATE_MAX / FMTG_RATE_WINDOW   accepted-message rate limit
#   FMTG_PAIR_TTL / FMTG_PAIR_ATTEMPTS pairing offer lifetime and attempt budget
#   FMTG_PUBLISH_TTL  publish-confirmation lifetime
#   FMTG_RECOVERY_SECS  age after which a still-pending inbox entry re-wakes
#   FMTG_RECOVERY_MAX   re-announcements one stranded entry may ever cause
# shellcheck disable=SC2034 # Every FMTG_* here is read by callers after sourcing.
fmtg_load_config() {
  local env_file="${FM_TELEGRAM_ENV_FILE:-$FM_HOME/.env}" dry raw
  if [ -n "${FM_TELEGRAM_BOT_TOKEN+x}" ]; then
    FMTG_TOKEN=${FM_TELEGRAM_BOT_TOKEN-}
  else
    FMTG_TOKEN=$(fm_env_file_get FM_TELEGRAM_BOT_TOKEN "$env_file")
  fi
  FMTG_TOKEN_BAD=
  if [ -n "$FMTG_TOKEN" ] && ! fmtg_token_shape_valid "$FMTG_TOKEN"; then
    FMTG_TOKEN_BAD=1
    FMTG_TOKEN=
  fi

  if [ -n "${FM_TELEGRAM_API_URL+x}" ]; then
    FMTG_API=${FM_TELEGRAM_API_URL-}
  else
    FMTG_API=$(fm_env_file_get FM_TELEGRAM_API_URL "$env_file")
  fi
  [ -n "$FMTG_API" ] || FMTG_API='https://api.telegram.org'
  FMTG_API=${FMTG_API%/}
  # The base is written into a quoted curl config value, so anything outside a
  # plain http(s) URL is refused rather than escaped.
  printf '%s' "$FMTG_API" | grep -Eq '^https?://[A-Za-z0-9._~-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$' \
    || FMTG_API='https://api.telegram.org' 

  if [ -n "${FM_TELEGRAM_DRY_RUN+x}" ]; then
    dry=${FM_TELEGRAM_DRY_RUN-}
  else
    dry=$(fm_env_file_get FM_TELEGRAM_DRY_RUN "$env_file")
  fi
  case "$(printf '%s' "$dry" | tr '[:upper:]' '[:lower:]')" in
    ''|0|false|no|off) FMTG_DRY="" ;;
    *) FMTG_DRY=1 ;;
  esac

  raw=${FM_TELEGRAM_POLL_TIMEOUT:-}
  case "$raw" in ''|*[!0-9]*) raw=20 ;; esac
  [ "$raw" -ge 0 ] 2>/dev/null || raw=20
  [ "$raw" -le 45 ] 2>/dev/null || raw=45
  FMTG_POLL_TIMEOUT=$raw

  # The long poll is bounded by the watcher's budget, not only by its own
  # ceiling. bin/fm-watch.sh runs the poll as one *.check.sh under
  # `timeout $FM_CHECK_TIMEOUT` and passes that budget down, and a check the
  # watcher kills produces no output at all: no wake, no telegram-error, just a
  # bridge that quietly stops delivering. So the request deadline reserves
  # FMTG_BUDGET_RESERVE seconds of the budget for this cycle's own state work,
  # and the long poll ends one further reserve earlier, so Telegram closes the
  # connection before curl's deadline and curl returns before the kill. These are
  # the ceilings; what any single call actually gets is whatever is left of the
  # budget the caller opened (fmtg_budget_open).
  raw=${FM_CHECK_TIMEOUT:-}
  case "$raw" in ''|*[!0-9]*) raw=30 ;; esac
  [ "$raw" -ge 10 ] 2>/dev/null || raw=10
  FMTG_CHECK_TIMEOUT=$raw
  FMTG_REQUEST_TIMEOUT=$(( FMTG_CHECK_TIMEOUT - FMTG_BUDGET_RESERVE ))
  [ "$FMTG_REQUEST_TIMEOUT" -ge "$FMTG_BUDGET_RESERVE" ] || FMTG_REQUEST_TIMEOUT=$FMTG_BUDGET_RESERVE
  raw=$(( FMTG_REQUEST_TIMEOUT - FMTG_BUDGET_RESERVE ))
  [ "$raw" -ge 0 ] || raw=0
  [ "$FMTG_POLL_TIMEOUT" -le "$raw" ] || FMTG_POLL_TIMEOUT=$raw

  # Telegram rejects a sendMessage body over 4096 UTF-16 code units. 3900 leaves
  # headroom for the numbering suffix and for characters that count as two units.
  raw=${FM_TELEGRAM_MAX_CHARS:-}
  case "$raw" in ''|*[!0-9]*) raw=3900 ;; esac
  [ "$raw" -ge 100 ] 2>/dev/null || raw=100
  [ "$raw" -le 3900 ] 2>/dev/null || raw=3900
  FMTG_MAX_CHARS=$raw

  raw=${FM_TELEGRAM_MAX_MESSAGES:-}
  case "$raw" in ''|*[!0-9]*) raw=8 ;; esac
  [ "$raw" -ge 1 ] 2>/dev/null || raw=8
  [ "$raw" -le 25 ] 2>/dev/null || raw=25
  FMTG_MAX_MESSAGES=$raw

  raw=${FM_TELEGRAM_MAX_TEXT:-}
  case "$raw" in ''|*[!0-9]*) raw=4096 ;; esac
  [ "$raw" -ge 16 ] 2>/dev/null || raw=16
  [ "$raw" -le 16384 ] 2>/dev/null || raw=16384
  FMTG_MAX_TEXT=$raw

  raw=${FM_TELEGRAM_RATE_MAX:-}
  case "$raw" in ''|*[!0-9]*) raw=60 ;; esac
  [ "$raw" -ge 1 ] 2>/dev/null || raw=60
  FMTG_RATE_MAX=$raw

  raw=${FM_TELEGRAM_RATE_WINDOW:-}
  case "$raw" in ''|*[!0-9]*) raw=3600 ;; esac
  [ "$raw" -ge 1 ] 2>/dev/null || raw=3600
  FMTG_RATE_WINDOW=$raw

  raw=${FM_TELEGRAM_PAIR_TTL:-}
  case "$raw" in ''|*[!0-9]*) raw=900 ;; esac
  [ "$raw" -ge 30 ] 2>/dev/null || raw=30
  [ "$raw" -le 3600 ] 2>/dev/null || raw=3600
  FMTG_PAIR_TTL=$raw

  raw=${FM_TELEGRAM_PAIR_ATTEMPTS:-}
  case "$raw" in ''|*[!0-9]*) raw=5 ;; esac
  [ "$raw" -ge 1 ] 2>/dev/null || raw=5
  [ "$raw" -le 20 ] 2>/dev/null || raw=20
  FMTG_PAIR_ATTEMPTS=$raw

  raw=${FM_TELEGRAM_PUBLISH_TTL:-}
  case "$raw" in ''|*[!0-9]*) raw=86400 ;; esac
  [ "$raw" -ge 60 ] 2>/dev/null || raw=86400
  FMTG_PUBLISH_TTL=$raw

  raw=${FM_TELEGRAM_RECOVERY_SECS:-}
  case "$raw" in ''|*[!0-9]*) raw=300 ;; esac
  [ "$raw" -ge 30 ] 2>/dev/null || raw=300
  FMTG_RECOVERY_SECS=$raw

  raw=${FM_TELEGRAM_RECOVERY_MAX:-}
  case "$raw" in ''|*[!0-9]*) raw=3 ;; esac
  [ "$raw" -ge 1 ] 2>/dev/null || raw=3
  [ "$raw" -le 20 ] 2>/dev/null || raw=20
  FMTG_RECOVERY_MAX=$raw
}

# BotFather issues "<numeric bot id>:<opaque secret>". Anything else is refused
# before it can be interpolated into a curl config file or a URL.
fmtg_token_shape_valid() {
  case "$1" in
    *[!0-9A-Za-z_:-]*) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq '^[0-9]{5,20}:[A-Za-z0-9_-]{20,128}$'
}

fmtg_active() {
  [ -n "${FMTG_TOKEN:-}" ]
}

# The generated watcher shim. Bootstrap writes exactly these bytes at mode 0700,
# and the watcher runs bin/fm-tg-poll.sh only after confirming the file still
# matches them, so a state file can never become an execution vector.
fmtg_poll_shim_content() {  # <home> <root>
  local home=$1 root=$2
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-bootstrap.sh - Telegram bridge poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted poll script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$root/bin/fm-tg-poll.sh")"
}

fmtg_poll_shim_valid() {  # <file> <home> <root>
  local file=$1 home=$2 root=$3
  fm_private_single_link_file_mode_valid "$file" 700 || return 1
  cmp -s "$file" <(fmtg_poll_shim_content "$home" "$root")
}

# Replace the live token with a fixed marker anywhere in stdin. Every diagnostic
# that could conceivably carry a URL or a curl error passes through this first.
fmtg_redact() {
  if [ -z "${FMTG_TOKEN:-}" ]; then
    cat
    return 0
  fi
  FMTG_REDACT_TOKEN=$FMTG_TOKEN awk '
    BEGIN { t = ENVIRON["FMTG_REDACT_TOKEN"] }
    {
      if (t != "") {
        out = ""
        rest = $0
        while ((i = index(rest, t)) > 0) {
          out = out substr(rest, 1, i - 1) "<redacted-token>"
          rest = substr(rest, i + length(t))
        }
        $0 = out rest
      }
      print
    }
  '
}

# --- budget -----------------------------------------------------------------
#
# The watcher kills the whole CHECK, not one request, so a cycle that issues more
# than one call - the long poll, then a pairing confirmation for a code redeemed
# inside it - has to spend ONE budget across all of them. A per-call deadline
# would let the second call start a fresh full-length request just as the first
# one used up the cycle, and the kill that follows destroys the wake rather than
# the request.
#
# A caller the watcher runs therefore opens the budget once, and every call then
# gets what is LEFT of it. A caller the watcher does not run - a reply, a pairing
# command, a task command - never opens one and keeps the plain per-call
# deadline, because nothing is going to kill it partway through.

fmtg_budget_open() {  # <now>
  local now=$1
  case "$now" in
    ''|*[!0-9]*) return 1 ;;
  esac
  FMTG_BUDGET_DEADLINE=$(( now + ${FMTG_REQUEST_TIMEOUT:-25} ))
}

# Seconds a call started right now may run for.
fmtg_budget_remaining() {
  local now left max
  max=${FMTG_REQUEST_TIMEOUT:-25}
  if [ -z "${FMTG_BUDGET_DEADLINE:-}" ]; then
    printf '%s' "$max"
    return 0
  fi
  now=$(fmtg_now) || { printf '%s' "$FMTG_BUDGET_MIN"; return 0; }
  left=$(( FMTG_BUDGET_DEADLINE - now ))
  [ "$left" -le "$max" ] || left=$max
  [ "$left" -ge "$FMTG_BUDGET_MIN" ] || left=$FMTG_BUDGET_MIN
  printf '%s' "$left"
}

fmtg_now() {
  local now=${FMTG_NOW_OVERRIDE:-}
  if [ -z "$now" ]; then
    now=$(date +%s) || return 1
  fi
  case "$now" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#now}" -le 18 ] || return 1
  printf '%s' "$now"
}

# --- paths and identifier validation ----------------------------------------

# Every bridge artifact lives under one owner-only directory inside this home's
# state, so a second firstmate home can never read or drain this home's bridge.
fmtg_dir() {
  printf '%s' "${FMTG_STATE:-$STATE}/telegram"
}

fmtg_request_id_valid() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

fmtg_update_id_valid() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 19 ]
}

fmtg_chat_id_valid() {
  case "$1" in
    -*) case "${1#-}" in ''|*[!0-9]*) return 1 ;; esac ;;
    *) case "$1" in ''|*[!0-9]*) return 1 ;; esac ;;
  esac
  [ "${#1}" -le 20 ]
}

fmtg_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# --- wire -------------------------------------------------------------------

# Issue one Bot API call. <payload-file> is a JSON file to POST, or "-" for a
# bodyless GET-style call. The response body is written to <body-file> and the
# HTTP status is printed. The token reaches curl only through the config stream
# on stdin, so it never enters argv and never exists as a file that a killed
# call could strand.
fmtg_api_call() {
  local method=$1 payload=$2 body=$3 code rc=0
  fmtg_active || return 1
  case "$method" in
    ''|*[!A-Za-z]*) return 1 ;;
  esac
  command -v curl >/dev/null 2>&1 || return 1
  code=$({
    printf 'url = "%s/bot%s/%s"\n' "$FMTG_API" "$FMTG_TOKEN" "$method"
    printf 'silent\n'
    printf 'max-time = %s\n' "$(fmtg_budget_remaining)"
    printf 'output = "%s"\n' "$body"
    printf 'write-out = "%%{http_code}"\n'
    if [ "$payload" != - ]; then
      printf 'request = "POST"\n'
      printf 'header = "Content-Type: application/json"\n'
      printf 'data-binary = "@%s"\n' "$payload"
    fi
  } | curl --config - 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return 1
  case "$code" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$code"
}

# --- pairing ----------------------------------------------------------------

fmtg_random_code() {
  local n=${1:-8} out
  out=$(LC_ALL=C tr -dc "$FMTG_CODE_ALPHABET" < /dev/urandom 2>/dev/null \
    | dd bs=1 "count=$n" 2>/dev/null) || return 1
  [ "${#out}" -eq "$n" ] || return 1
  printf '%s' "$out"
}

# Hash a pairing or publish code with its per-record salt. Only this digest is
# ever written to disk, so a reader of the state directory cannot replay a code.
fmtg_code_hash() {
  local salt=$1 code=$2
  printf '%s:%s' "$salt" "$code" | fmtg_sha256
}

fmtg_pairing_set() {  # <label> <project> <code> <created> <expires>
  local label=$1 project=$2 code=$3 created=$4 expires=$5 salt hash dir
  salt=$(fmtg_random_code 16) || return 1
  hash=$(fmtg_code_hash "$salt" "$code") || return 1
  dir=$(fmtg_dir)
  jq -cn --arg label "$label" --arg project "$project" --arg salt "$salt" \
    --arg hash "$hash" --argjson created "$created" --argjson expires "$expires" \
    '{label:$label, project:$project, salt:$salt, code_sha256:$hash,
      created_at:$created, expires_at:$expires, attempts:0}' \
    | fm_private_artifact_publish_stdin "$dir" pairing.json 600
}

fmtg_pairing_get() {
  local dir
  dir=$(fmtg_dir)
  fm_private_artifact_file_valid "$dir" pairing.json 600 || return 1
  cat "$dir/pairing.json"
}

fmtg_pairing_clear() {
  local dir
  dir=$(fmtg_dir)
  rm -f -- "$dir/pairing.json" 2>/dev/null || true
  [ ! -e "$dir/pairing.json" ]
}

# Record one consumed pairing attempt. Returns 1 when the offer has no attempts
# left, so an attacker gets a bounded number of guesses per offer.
fmtg_pairing_attempt() {
  local dir record attempts
  dir=$(fmtg_dir)
  record=$(fmtg_pairing_get) || return 1
  attempts=$(printf '%s' "$record" | jq -r '.attempts // 0') || return 1
  case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
  attempts=$(( attempts + 1 ))
  printf '%s' "$record" | jq -c --argjson n "$attempts" '.attempts = $n' \
    | fm_private_artifact_publish_stdin "$dir" pairing.json 600 || return 1
  [ "$attempts" -le "${FMTG_PAIR_ATTEMPTS:-5}" ]
}

fmtg_peer_set() {  # <label> <project> <user_id> <chat_id> <paired_at>
  local label=$1 project=$2 user=$3 chat=$4 at=$5 dir
  dir=$(fmtg_dir)
  jq -cn --arg label "$label" --arg project "$project" \
    --argjson user "$user" --argjson chat "$chat" --argjson at "$at" \
    '{label:$label, project:$project, user_id:$user, chat_id:$chat, paired_at:$at}' \
    | fm_private_artifact_publish_stdin "$dir" peer.json 600
}

fmtg_peer_get() {
  local dir
  dir=$(fmtg_dir)
  fm_private_artifact_file_valid "$dir" peer.json 600 || return 1
  cat "$dir/peer.json"
}

fmtg_peer_clear() {
  local dir
  dir=$(fmtg_dir)
  rm -f -- "$dir/peer.json" 2>/dev/null || true
  [ ! -e "$dir/peer.json" ]
}

# --- inbound ----------------------------------------------------------------

fmtg_offset_get() {
  local dir value
  dir=$(fmtg_dir)
  if ! fm_private_artifact_file_valid "$dir" offset 600; then
    printf '0'
    return 0
  fi
  value=$(cat "$dir/offset" 2>/dev/null) || { printf '0'; return 0; }
  case "$value" in
    ''|*[!0-9]*) printf '0'; return 0 ;;
  esac
  [ "${#value}" -le 19 ] || { printf '0'; return 0; }
  printf '%s' "$value"
}

fmtg_offset_set() {
  local dir=$1 value=$2
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$value" | fm_private_artifact_publish_stdin "$dir" offset 600
}

# Atomically claim the durable per-update marker. 0 = this poll claimed it,
# 1 = an earlier poll already did, 2 = the claim could not be recorded. The
# marker outlives the inbox entry, so a message drained by the agent is never
# re-created when Telegram redelivers the same update after a crash.
fmtg_seen_claim() {  # <update_id> <now>
  local update=$1 now=$2 dir rc
  fmtg_update_id_valid "$update" || return 2
  dir="$(fmtg_dir)/seen"
  jq -cn --arg id "$update" --argjson at "$now" '{update_id:$id, seen_at:$at}' \
    | fm_private_artifact_publish_stdin_once "$dir" "$update.json" 600
  rc=$?
  return "$rc"
}

# The jq program that turns one raw Telegram message into safe stored text.
# It is a program fragment, not a filter call, so the poll can splice it into a
# larger expression and every caller normalizes identically:
#   - CRLF and lone CR become LF, so line handling is platform-independent;
#   - C0 controls other than tab and newline, plus DEL, are removed, so terminal
#     escape sequences and NUL cannot survive into anything that renders them;
#   - leading and trailing whitespace is trimmed.
# The result is still untrusted DATA. It is written into JSON with jq and read
# back from a file; it is never interpolated into a shell command or a path.
fmtg_normalize_text_program() {
  cat <<'JQ'
  (split("\u0000") | join(""))
  | gsub("\r\n"; "\n")
  | gsub("\r"; "\n")
  | gsub("[\u0001-\u0008\u000b\u000c\u000e-\u001f\u007f]"; "")
  | gsub("^[[:space:]]+|[[:space:]]+$"; "")
JQ
}

# Bounded accept rate. Returns 0 while the current window still has budget and 1
# once it is exhausted, so a flood costs one wake, not one wake per message.
fmtg_rate_allow() {  # <now>
  local now=$1 dir record start count
  dir=$(fmtg_dir)
  start=0
  count=0
  if fm_private_artifact_file_valid "$dir" limits.json 600; then
    record=$(cat "$dir/limits.json" 2>/dev/null) || record=
    if [ -n "$record" ]; then
      start=$(printf '%s' "$record" | jq -r '.window_start // 0' 2>/dev/null) || start=0
      count=$(printf '%s' "$record" | jq -r '.accepted // 0' 2>/dev/null) || count=0
    fi
  fi
  case "$start" in ''|*[!0-9]*) start=0 ;; esac
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "$start" -eq 0 ] || [ $(( now - start )) -ge "${FMTG_RATE_WINDOW:-3600}" ] \
    || [ "$now" -lt "$start" ]; then
    start=$now
    count=0
  fi
  count=$(( count + 1 ))
  jq -cn --argjson start "$start" --argjson count "$count" \
    '{window_start:$start, accepted:$count}' \
    | fm_private_artifact_publish_stdin "$dir" limits.json 600 || return 1
  [ "$count" -le "${FMTG_RATE_MAX:-60}" ]
}

# --- bounded re-announcement -------------------------------------------------
#
# The recovery sweep re-announces an inbox entry whose wake was lost, and that
# has to be bounded: an entry the agent cannot drain - a reply that keeps
# failing, a turn interrupted between the seen claim and the reply - would
# otherwise wake firstmate once per recovery window forever, which for an
# unattended home is hundreds of turns off one stuck message.
#
# The budget is counted per request in its OWN record rather than inside the
# inbox entry, because rewriting that entry would race the agent draining it and
# could resurrect a message that was already answered. The record dies with the
# entry it bounds (fmtg_prune), never on a timer, so a spent budget cannot
# silently restore the wake loop.

fmtg_announce_count() {  # <request_id>
  local rid=$1 dir count
  fmtg_request_id_valid "$rid" || { printf '0'; return 0; }
  dir="$(fmtg_dir)/announce"
  if ! fm_private_artifact_file_valid "$dir" "$rid.json" 600; then
    printf '0'
    return 0
  fi
  count=$(jq -r '.announces // 0' "$dir/$rid.json" 2>/dev/null) || count=0
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  printf '%s' "$count"
}

# Record one re-announcement and print the running count. Returns 1 when the
# count cannot be made durable, so a caller never announces work it cannot bound.
fmtg_announce_bump() {  # <request_id> <now>
  local rid=$1 now=$2 dir count
  fmtg_request_id_valid "$rid" || return 1
  dir="$(fmtg_dir)/announce"
  count=$(fmtg_announce_count "$rid")
  count=$(( count + 1 ))
  jq -cn --arg rid "$rid" --argjson n "$count" --argjson at "$now" \
    '{request_id:$rid, announces:$n, last_announce_at:$at}' \
    | fm_private_artifact_publish_stdin "$dir" "$rid.json" 600 || return 1
  printf '%s' "$count"
}

# --- durable per-request reply context --------------------------------------
#
# The chat a reply must go back to is pinned at pairing time, but a request's
# own message context (which chat, which message, when) has to survive the inbox
# cleanup that follows a handled message, so a later milestone or final reply can
# still address the right conversation. These records are pruned on the same
# bounded schedule as the seen markers.

fmtg_context_set() {  # <request_id> <chat_id> <message_id> <now>
  local rid=$1 chat=$2 msg=$3 now=$4 dir
  fmtg_request_id_valid "$rid" || return 1
  dir="$(fmtg_dir)/context"
  jq -cn --arg rid "$rid" --argjson chat "$chat" --argjson msg "$msg" \
    --argjson at "$now" \
    '{request_id:$rid, chat_id:$chat, message_id:$msg, recorded_at:$at}' \
    | fm_private_artifact_publish_stdin "$dir" "$rid.json" 600
}

fmtg_context_get() {  # <request_id>
  local rid=$1 dir
  fmtg_request_id_valid "$rid" || return 1
  dir="$(fmtg_dir)/context"
  fm_private_artifact_file_valid "$dir" "$rid.json" 600 || return 1
  cat "$dir/$rid.json"
}

fmtg_context_clear() {  # <request_id>
  local rid=$1 dir
  fmtg_request_id_valid "$rid" || return 1
  dir="$(fmtg_dir)/context"
  rm -f -- "$dir/$rid.json" 2>/dev/null || true
  [ ! -e "$dir/$rid.json" ]
}

# Drop context and seen records past the retention window. Bounded retention is
# what keeps an opted-in home from accumulating request metadata indefinitely.
# Re-announce records are retained differently: they are bookkeeping for one
# inbox entry, so each one lives exactly as long as the entry it bounds.
# Orphaned publication temporaries go too - they carry message content, and no
# scan that looks for published names can see them.
fmtg_prune() {  # <now>
  local now=$1 max_age dir sub file at device inbox
  max_age=${FM_TELEGRAM_RETENTION_SECS:-604800}
  case "$max_age" in ''|*[!0-9]*) max_age=604800 ;; esac
  [ "$max_age" -le 2592000 ] 2>/dev/null || max_age=2592000
  inbox="$(fmtg_dir)/inbox"
  for sub in context seen announce; do
    dir="$(fmtg_dir)/$sub"
    device=$(fm_private_artifact_dir_device "$dir" 2>/dev/null) || continue
    while IFS= read -r -d '' file; do
      if ! fm_private_single_link_file_mode_valid "$file" 600 "$device"; then
        rm -f -- "$file" 2>/dev/null || true
        continue
      fi
      if [ "$sub" = announce ]; then
        [ -e "$inbox/${file##*/}" ] || rm -f -- "$file" 2>/dev/null || true
        continue
      fi
      at=$(jq -r '(.recorded_at // .seen_at // empty) | tostring' "$file" 2>/dev/null) || at=
      case "$at" in ''|*[!0-9]*) rm -f -- "$file" 2>/dev/null || true; continue ;; esac
      if [ "$at" -gt "$now" ] || [ $(( now - at )) -gt "$max_age" ]; then
        rm -f -- "$file" 2>/dev/null || true
      fi
    done < <(find "$dir" -type f -name '*.json' -print0 2>/dev/null)
  done
  # Far longer than any publish this home can still be running: the watcher kills
  # a poll at FMTG_CHECK_TIMEOUT, so anything this old is provably abandoned.
  fm_private_artifact_sweep_temps "$(fmtg_dir)" "$now" 600
  return 0
}

# --- outbound ---------------------------------------------------------------

# Record a would-be or failed send so it can be inspected or retried without
# repeating whatever action produced the text.
fmtg_outbox_record() {  # <name> <json>
  local name=$1 record=$2 dir
  dir="$(fmtg_dir)/outbox"
  printf '%s\n' "$record" | fm_private_artifact_publish_stdin "$dir" "$name.json" 600
}

# Send one already-split chunk to a pinned chat.
#
# No parse_mode is ever set. That is the bridge's entire escaping contract: with
# no markup parser enabled, Telegram treats the body as literal text, so agent or
# quoted-user text containing *, _, [, ` or a stray backslash is delivered
# verbatim and can never be mis-parsed into markup or rejected as an unbalanced
# entity. Text reaches the API as a JSON string built by jq, never by shell
# interpolation. Prints the HTTP status.
fmtg_send_text() {  # <chat_id> <text> <body-file>
  local chat=$1 text=$2 body=$3 payload code
  fmtg_chat_id_valid "$chat" || return 1
  payload=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tg-msg.XXXXXX") || return 1
  if ! jq -cn --argjson chat "$chat" --arg text "$text" \
    '{chat_id:$chat, text:$text, disable_web_page_preview:true}' > "$payload"; then
    rm -f -- "$payload"
    return 1
  fi
  local rc
  code=$(fmtg_api_call sendMessage "$payload" "$body")
  rc=$?
  rm -f -- "$payload"
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$code"
}

# --- task link --------------------------------------------------------------

# Give <dest> the same permission bits as <src>. GNU chmod --reference does not
# exist on macOS, so the mode is read portably and reapplied.
fmtg_copy_mode() {  # <src> <dest>
  local src=$1 dest=$2 mode
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$src" 2>/dev/null) || mode=
  else
    mode=$(stat -c %a "$src" 2>/dev/null) || mode=
  fi
  case "$mode" in
    ''|*[!0-7]*) mode=600 ;;
  esac
  chmod "$mode" "$dest" 2>/dev/null || true
}

# Print the value of the last "key=value" line in <meta-file>. Returns non-zero
# and prints nothing when the file, the key, or the value is missing, so a caller
# can tell "not linked" from "linked to something" instead of reading both as an
# empty line.
fmtg_meta_get() {  # <meta-file> <key>
  local meta=$1 key=$2 value
  [ -f "$meta" ] || return 1
  value=$(grep -E "^${key}=" "$meta" 2>/dev/null | tail -n1 | cut -d= -f2-) || return 1
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# Record which Telegram request a task answers, so milestone and final replies
# can find the conversation later. Written into the task's own meta file next to
# the X-mode link fields, using the same rewrite-in-place discipline.
fmtg_meta_link_set() {  # <meta-file> <request_id> <chat_id> <now>
  local meta=$1 rid=$2 chat=$3 now=$4 tmp
  [ -f "$meta" ] || return 1
  fmtg_request_id_valid "$rid" || return 1
  fmtg_chat_id_valid "$chat" || return 1
  tmp=$(umask 077; mktemp "$(dirname "$meta")/.fm-tg-meta.XXXXXX") || return 1
  {
    grep -v -E '^(tg_request|tg_chat|tg_request_ts)=' "$meta" 2>/dev/null || true
    printf 'tg_request=%s\n' "$rid"
    printf 'tg_chat=%s\n' "$chat"
    printf 'tg_request_ts=%s\n' "$now"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  fmtg_copy_mode "$meta" "$tmp"
  mv -f -- "$tmp" "$meta" || { rm -f -- "$tmp"; return 1; }
}

fmtg_meta_link_clear() {  # <meta-file>
  local meta=$1 tmp
  [ -f "$meta" ] || return 0
  tmp=$(umask 077; mktemp "$(dirname "$meta")/.fm-tg-meta.XXXXXX") || return 1
  { grep -v -E '^(tg_request|tg_chat|tg_request_ts)=' "$meta" 2>/dev/null || true; } > "$tmp" \
    || { rm -f -- "$tmp"; return 1; }
  fmtg_copy_mode "$meta" "$tmp"
  mv -f -- "$tmp" "$meta" || { rm -f -- "$tmp"; return 1; }
}

# --- publish gate -----------------------------------------------------------
#
# A request from the paired human authorizes preparing a change and showing a
# preview. It does NOT authorize landing that change. This gate is the
# mechanical half of that rule: arming records the exact prepared change, and a
# confirmation is accepted only when it carries the matching one-time code AND
# the prepared change is still byte-for-byte the one that was previewed.

fmtg_publish_task_valid() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

fmtg_publish_arm() {  # <task-id> <project> <head> <code> <now> <expires>
  local task=$1 project=$2 head=$3 code=$4 now=$5 expires=$6 dir salt hash
  fmtg_publish_task_valid "$task" || return 1
  salt=$(fmtg_random_code 16) || return 1
  hash=$(fmtg_code_hash "$salt" "$code") || return 1
  dir="$(fmtg_dir)/publish"
  jq -cn --arg task "$task" --arg project "$project" --arg head "$head" \
    --arg salt "$salt" --arg hash "$hash" \
    --argjson now "$now" --argjson expires "$expires" \
    '{task_id:$task, project:$project, head:$head, salt:$salt, code_sha256:$hash,
      armed_at:$now, expires_at:$expires, consumed_at:null, attempts:0}' \
    | fm_private_artifact_publish_stdin "$dir" "$task.json" 600
}

# Consume one confirmation attempt against an armed record. Returns 1 once the
# budget is spent, so a wrong confirmation cannot be retried indefinitely.
fmtg_publish_attempt() {  # <task-id>
  local task=$1 dir record attempts
  fmtg_publish_task_valid "$task" || return 1
  dir="$(fmtg_dir)/publish"
  record=$(fmtg_publish_show "$task") || return 1
  attempts=$(printf '%s' "$record" | jq -r '.attempts // 0') || return 1
  case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
  attempts=$(( attempts + 1 ))
  printf '%s' "$record" | jq -c --argjson n "$attempts" '.attempts = $n' \
    | fm_private_artifact_publish_stdin "$dir" "$task.json" 600 || return 1
  [ "$attempts" -le "${FMTG_PAIR_ATTEMPTS:-5}" ]
}

fmtg_publish_show() {  # <task-id>
  local task=$1 dir
  fmtg_publish_task_valid "$task" || return 1
  dir="$(fmtg_dir)/publish"
  fm_private_artifact_file_valid "$dir" "$task.json" 600 || return 1
  cat "$dir/$task.json"
}

fmtg_publish_clear() {  # <task-id>
  local task=$1 dir
  fmtg_publish_task_valid "$task" || return 1
  dir="$(fmtg_dir)/publish"
  rm -f -- "$dir/$task.json" 2>/dev/null || true
  [ ! -e "$dir/$task.json" ]
}

# Validate a confirmation against an armed record. Exit codes are distinct so a
# caller can tell the human exactly why a confirmation was refused:
#   0 accepted (and atomically consumed)   4 expired
#   3 nothing armed for this task          5 code does not match
#   6 prepared change moved since preview   7 already used
#   1 malformed input or state write failure
fmtg_publish_confirm() {  # <task-id> <supplied-code> <current-head> <now>
  local task=$1 supplied=$2 head=$3 now=$4 dir record salt want got expires consumed recorded_head
  fmtg_publish_task_valid "$task" || return 1
  dir="$(fmtg_dir)/publish"
  record=$(fmtg_publish_show "$task") || return 3
  consumed=$(printf '%s' "$record" | jq -r '.consumed_at // "null"') || return 1
  [ "$consumed" = null ] || return 7
  expires=$(printf '%s' "$record" | jq -r '.expires_at // 0') || return 1
  case "$expires" in ''|*[!0-9]*) return 1 ;; esac
  [ "$now" -le "$expires" ] || return 4
  salt=$(printf '%s' "$record" | jq -r '.salt // ""') || return 1
  want=$(printf '%s' "$record" | jq -r '.code_sha256 // ""') || return 1
  [ -n "$salt" ] && [ -n "$want" ] || return 1
  got=$(fmtg_code_hash "$salt" "$supplied") || return 1
  [ "$got" = "$want" ] || return 5
  recorded_head=$(printf '%s' "$record" | jq -r '.head // ""') || return 1
  [ "$recorded_head" = "$head" ] || return 6
  printf '%s' "$record" | jq -c --argjson at "$now" '.consumed_at = $at' \
    | fm_private_artifact_publish_stdin "$dir" "$task.json" 600 || return 1
}
