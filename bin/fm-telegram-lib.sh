# shellcheck shell=bash
# fm-telegram-lib.sh - the one owner of Firstmate's outward Telegram cards:
# what a card may contain, how it is refused, and how it becomes durable.
#
# WHY THIS EXISTS. bin/fm-parent-channel-lib.sh already made captain-facing
# outcomes structural rather than remembered: the script that records the
# durable evidence publishes the outcome itself. But that channel is resolved
# from a secondmate home's parent binding, so in the captain's own MAIN home
# every publisher fires and delivers to nowhere - the design assumed the
# captain is sitting in that home's chat. This library supplies the missing
# route: a home that has configured Telegram gets the same outcomes as a card
# on the captain's phone, from the same publishers, with no dependence on the
# model remembering to send.
#
# Sends only. This library never reads from Telegram: getUpdates is never
# called anywhere in this repository, so a card cannot carry an instruction
# back and nothing that arrives at the bot can reach Firstmate.
#
# INERT BY DEFAULT, the way the relay is (bin/fm-x-poll.sh): no automatic path
# changes behavior in a home without configuration. There is no feature flag
# to get wrong - configuration presence IS the enablement. Publishers and the
# drain remain silent and cleanup is unchanged. The deliberate arm command
# refuses when these required inputs are unavailable:
#   config/telegram-chat-id     the numeric destination chat, required
#   config/telegram-token-path  optional path to the bot token file, default
#                               $HOME/.mist-telegram-token
#   config/telegram-secret-files  optional extra credential files, one path per
#                               line, whose contents a card may never carry
# The home holds only the PATH; the token itself is read at use time, never
# copied into state, a card, a log, or an error message.
#
# AN OUTBOX, NEVER A SYNCHRONOUS SEND, and this is a correctness requirement
# rather than a preference. bin/fm-pr-check.sh and bin/fm-teardown.sh sit on
# the critical path of landing work, and teardown REFUSES to remove a child
# while its channel line is undelivered. A blocking HTTPS call under that
# refusal would let a Telegram outage block work from landing, which is worse
# than having no notifications at all. So a publisher only appends to a durable
# local outbox - a directory write that cannot fail on network - and
# bin/fm-telegram-send.sh drains it out of band. Every entry point here is
# local, bounded, and reports its own problems on stderr rather than returning
# a failure a publisher would have to handle.
#
# THE FOUR CARDS. AGENTS.md section 9's escalation classes, one publisher each:
#   decision  a task is held for the captain      bin/fm-captain-hold.sh
#   pr-ready  a PR is registered for review       bin/fm-pr-check.sh
#   failed    a child's terminal outcome failed   bin/fm-inactive-reconcile.sh
#   landed    a PR merged                         bin/fm-merge-outcome-lib.sh
# A child that finishes successfully sends no card of its own: its captain
# facing card is the pr-ready one its PR registration already sent. Card volume
# is itself a safety property - a channel that fires too often gets muted, and
# a muted channel is worse than none because it looks like coverage - so a new
# class needs a reason, not just a new event.
#
# WHAT A CARD IS BUILT FROM. Typed fields the publisher already holds, never a
# parent-channel or status line. Those use the machine shape
# "<state> [key=<slug>]: <note>", and AGENTS.md section 9 forbids relaying that
# to the captain. The API cannot express "send this line", and
# fm_telegram_card_render additionally REFUSES a field that still carries that
# shape, so a future caller cannot smuggle one through free text.
#
# WHAT A CARD MAY NEVER CARRY. Everything sent to a bot is stored in plaintext
# on Telegram's servers - bot chats are ordinary cloud chats and Telegram's
# end-to-end Secret Chats are not available to bots at all - and every card is
# permanently in scrollback on every logged-in device. Two rules follow, and
# they are deliberately different:
#   - A SECRET is a hard refusal. fm_telegram_refuse_if_secret is a positive
#     check against the real values of this home's known credential files, the
#     shape fleet-dashboard's collect.py already uses, not a blocklist of
#     patterns. A refused card is dropped loudly, never silently, because a
#     send that silently drops is worse than one that fails.
#   - An INTERNAL IDENTIFIER is redacted, not refused. AGENTS.md section 9
#     forbids internal identifiers in captain-facing text. The scrubber removes
#     absolute paths, machine key=value fragments, fm/<name> branch refs, and
#     verified harness names; refusing on them would silently suppress genuine
#     failure cards, so the card still goes.
#
# Sourced by bin/fm-parent-channel-lib.sh, by bin/fm-telegram-send.sh, and by
# tests. No side effects on source.

_FM_TELEGRAM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$_FM_TELEGRAM_LIB_DIR/fm-pr-lib.sh"

# The outbox lives under the home's state directory, one file per card holding
# exactly the text that will be sent and nothing else.
FM_TELEGRAM_OUTBOX_DIRNAME="telegram-outbox"
# Bounded ledger of card keys already delivered, so a publisher that reports
# the same outcome twice cannot produce a second card.
FM_TELEGRAM_DELIVERED_BASENAME=".delivered"
FM_TELEGRAM_DELIVERED_KEEP=200
# A phone card that does not fit on a screen is not read. These bounds are well
# inside Telegram's own 4096-character message ceiling.
FM_TELEGRAM_FIELD_MAX=300
FM_TELEGRAM_CARD_MAX=1000
FM_TELEGRAM_FIELD_BYTES_MAX=1200
FM_TELEGRAM_CARD_BYTES_MAX=4000
# A credential value shorter than this is not distinctive enough to test a card
# against; collect.py uses the same floor for the same reason.
FM_TELEGRAM_SECRET_MIN=8
FM_TELEGRAM_SECRET_FILE_MAX=1048576
FM_TELEGRAM_SECRET_LIST_MAX=65536
FM_TELEGRAM_SECRET_FILES_MAX=100

# Output globals, set by fm_telegram_config_load.
# shellcheck disable=SC2034 # Read by sourcing callers.
FM_TELEGRAM_CHAT_ID=
# shellcheck disable=SC2034 # Read by sourcing callers.
FM_TELEGRAM_TOKEN_FILE=
FM_TELEGRAM_SECRET_ERROR_PATH=
# shellcheck disable=SC2034 # Read by sourcing callers.
FM_TELEGRAM_CONFIG_ERROR=

_fm_telegram_config_dir() {  # <home>
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-$1/config}"
}

# The whole content of a small local config file, or non-zero when it is
# absent, a symlink, or unreadable. Trailing newlines are dropped; a config
# value is one line.
_fm_telegram_config_read() {  # <home> <name>
  local dir file value
  dir=$(_fm_telegram_config_dir "$1")
  file="$dir/$2"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  value=$(head -1 "$file" 2>/dev/null) || return 1
  value=${value%$'\r'}
  # An operator writing a value by hand leaves surrounding blanks; a config item
  # that reads as absent because of one trailing space would look exactly like a
  # home that never opted in, which is the one failure this feature must not have.
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# A Telegram chat id is a whole number, negative for a group or channel.
_fm_telegram_chat_id_valid() {  # <id>
  case "${1-}" in
    ''|-) return 1 ;;
    -*) case "${1#-}" in ''|*[!0-9]*) return 1 ;; esac ;;
    *) case "$1" in *[!0-9]*) return 1 ;; esac ;;
  esac
}

# Resolve this home's Telegram configuration into FM_TELEGRAM_CHAT_ID and
# FM_TELEGRAM_TOKEN_FILE. Returns 0 only when the home is fully configured and
# the token file is present and usable. A home without a chat-id configuration
# returns 1 in silence; an opted-in home with unusable token configuration
# returns 2 with an actionable error for operator-facing callers.
fm_telegram_config_load() {  # <home>
  local home=$1 chat token device dir chat_setting token_setting
  FM_TELEGRAM_CHAT_ID=
  FM_TELEGRAM_TOKEN_FILE=
  FM_TELEGRAM_CONFIG_ERROR=
  dir=$(_fm_telegram_config_dir "$home")
  chat_setting="$dir/telegram-chat-id"
  if [ ! -e "$chat_setting" ] && [ ! -L "$chat_setting" ]; then
    return 1
  fi
  if [ ! -f "$chat_setting" ] || [ -L "$chat_setting" ] || [ ! -r "$chat_setting" ]; then
    FM_TELEGRAM_CONFIG_ERROR="chat id setting $chat_setting must be a readable regular file containing a numeric chat id"
    return 2
  fi
  chat=$(_fm_telegram_config_read "$home" telegram-chat-id) || {
    FM_TELEGRAM_CONFIG_ERROR="chat id setting $chat_setting must contain a numeric chat id"
    return 2
  }
  _fm_telegram_chat_id_valid "$chat" || {
    FM_TELEGRAM_CONFIG_ERROR="chat id setting $chat_setting must contain a numeric chat id"
    return 2
  }
  token_setting="$dir/telegram-token-path"
  if [ -e "$token_setting" ] || [ -L "$token_setting" ]; then
    if [ ! -f "$token_setting" ] || [ -L "$token_setting" ] || [ ! -r "$token_setting" ]; then
      FM_TELEGRAM_CONFIG_ERROR="token path setting $token_setting must be a readable regular file containing the bot token file path"
      return 2
    fi
    token=$(_fm_telegram_config_read "$home" telegram-token-path) || {
      FM_TELEGRAM_CONFIG_ERROR="token path setting $token_setting must contain the bot token file path"
      return 2
    }
  else
    token="$HOME/.mist-telegram-token"
  fi
  # A leading "~/" in the recorded path is expanded here, because the path is
  # config data rather than shell input and never passes through an expansion.
  [ "${token#\~/}" = "$token" ] || token="$HOME/${token#\~/}"
  if [ ! -e "$token" ] && [ ! -L "$token" ]; then
    FM_TELEGRAM_CONFIG_ERROR="token file $token is missing"
    return 2
  fi
  if [ ! -f "$token" ] || [ -L "$token" ] || [ ! -r "$token" ]; then
    FM_TELEGRAM_CONFIG_ERROR="token file $token must be a readable regular file owned by the current user with mode 0600"
    return 2
  fi
  if [ ! -s "$token" ]; then
    FM_TELEGRAM_CONFIG_ERROR="token file $token is empty"
    return 2
  fi
  device=$(fm_pr_file_device "$token") || {
    FM_TELEGRAM_CONFIG_ERROR="token file $token could not be checked"
    return 2
  }
  if ! fm_pr_private_file_valid "$token" 600 "$device"; then
    FM_TELEGRAM_CONFIG_ERROR="token file $token must be owned by the current user with mode 0600"
    return 2
  fi
  fm_telegram_token_usable "$token" || {
    # shellcheck disable=SC2034 # Read by sourcing callers.
    FM_TELEGRAM_CONFIG_ERROR="token file $token must contain exactly one usable token line"
    return 2
  }
  # shellcheck disable=SC2034 # Read by sourcing callers.
  FM_TELEGRAM_CHAT_ID=$chat
  # shellcheck disable=SC2034 # Read by sourcing callers.
  FM_TELEGRAM_TOKEN_FILE=$token
}

# A bot token is an opaque credential the sender puts into a curl config file
# and into a URL, so it is accepted only in the shape that survives both: one
# line with no whitespace, quote, or backslash. A file that does not hold one is
# treated as no token at all rather than sent anywhere, and the value itself is
# never printed by this check or any caller.
fm_telegram_token_usable() {  # <token-file>
  local first rest
  first=$(head -1 "$1" 2>/dev/null) || return 1
  first=${first%$'\r'}
  case "$first" in
    ''|*[[:space:]]*|*'"'*|*[\\]*) return 1 ;;
  esac
  rest=$(tail -n +2 "$1" 2>/dev/null | tr -d '[:space:]') || return 1
  [ -z "$rest" ]
}

# True when this home has opted in. Silent either way.
fm_telegram_enabled() {  # <home>
  fm_telegram_config_load "$1" >/dev/null 2>&1
}

# --- content safety ---------------------------------------------------------

# Every credential value this home knows about, one per line, long enough to be
# distinctive. The bot token is always included: a card must never carry the
# credential that sends it. Additional files are named one per line in
# config/telegram-secret-files, which is local and gitignored, because the
# credential set is a property of the operator's machine and never of this
# shared template.
_fm_telegram_secret_candidate_safe() {  # <text> <candidate>
  [ "${#2}" -lt "$FM_TELEGRAM_SECRET_MIN" ] && return 0
  case "$1" in
    *"$2"*) return 1 ;;
  esac
  return 0
}

fm_telegram_refuse_if_secret() {  # <home> <text>
  local home=$1 text=$2 dir list file value candidate bare files='' bytes count=0
  FM_TELEGRAM_SECRET_ERROR_PATH=
  dir=$(_fm_telegram_config_dir "$home")
  list="$dir/telegram-secret-files"
  [ -z "$FM_TELEGRAM_TOKEN_FILE" ] || files=$FM_TELEGRAM_TOKEN_FILE
  if [ -e "$list" ] || [ -L "$list" ]; then
    if [ ! -f "$list" ] || [ -L "$list" ] || [ ! -r "$list" ]; then
      FM_TELEGRAM_SECRET_ERROR_PATH=$list
      return 2
    fi
    bytes=$(LC_ALL=C wc -c < "$list" 2>/dev/null | tr -d '[:space:]') || {
      FM_TELEGRAM_SECRET_ERROR_PATH=$list
      return 2
    }
    if [ "$bytes" -gt "$FM_TELEGRAM_SECRET_LIST_MAX" ]; then
      FM_TELEGRAM_SECRET_ERROR_PATH=$list
      return 2
    fi
    files="${files}${files:+$'\n'}$(cat "$list" 2>/dev/null)" || {
      FM_TELEGRAM_SECRET_ERROR_PATH=$list
      return 2
    }
  fi
  while IFS= read -r file || [ -n "$file" ]; do
    case "$file" in
      ''|'#'*) continue ;;
    esac
    count=$((count + 1))
    if [ "$count" -gt "$FM_TELEGRAM_SECRET_FILES_MAX" ]; then
      FM_TELEGRAM_SECRET_ERROR_PATH=$list
      return 2
    fi
    [ "${file#\~/}" = "$file" ] || file="$HOME/${file#\~/}"
    if [ ! -f "$file" ] || [ -L "$file" ] || [ ! -r "$file" ]; then
      FM_TELEGRAM_SECRET_ERROR_PATH=$file
      return 2
    fi
    bytes=$(LC_ALL=C wc -c < "$file" 2>/dev/null | tr -d '[:space:]') || {
      FM_TELEGRAM_SECRET_ERROR_PATH=$file
      return 2
    }
    if [ "$bytes" -gt "$FM_TELEGRAM_SECRET_FILE_MAX" ]; then
      FM_TELEGRAM_SECRET_ERROR_PATH=$file
      return 2
    fi
    while IFS= read -r value || [ -n "$value" ]; do
      value=${value%$'\r'}
      _fm_telegram_secret_candidate_safe "$text" "$value" || return 1
      case "$value" in
        *=*)
          candidate=${value#*=}
          _fm_telegram_secret_candidate_safe "$text" "$candidate" || return 1
          case "$candidate" in
            \"*\") bare=${candidate#\"}; bare=${bare%\"} ;;
            \'*\') bare=${candidate#\'}; bare=${bare%\'} ;;
            *) bare='' ;;
          esac
          [ -z "$bare" ] || _fm_telegram_secret_candidate_safe "$text" "$bare" || return 1
          ;;
      esac
    done < "$file"
  done <<< "$files"
  return 0
}

# The machine shape a parent-channel or status line uses. A field carrying it
# is a forwarded line rather than a typed fact, and no card may be built from
# one; this is the structural half of "never forward a raw status line", the
# other half being that the API takes fields and has no line parameter at all.
fm_telegram_looks_like_status_line() {  # <text>
  local text=$1
  case "$text" in
    *'[key='*']: '*) return 0 ;;
  esac
  case "$text" in
    'working: '*|'done: '*|'failed: '*|'blocked: '*|'paused: '*) return 0 ;;
    'needs-decision: '*|'resolved: '*|'captain-held: '*) return 0 ;;
  esac
  return 1
}

# Fold free text onto one bounded line and remove the internal identifiers
# AGENTS.md section 9 keeps out of captain-facing text: absolute filesystem
# paths; machine key=value fragments that name a task, worktree, branch,
# harness, delivery mode, or endpoint; fm/<name> branch refs; and the verified
# harness names claude, codex, opencode, pi, pi-signed, grok, kimi, cursor, and
# muse. A URL survives, because a PR link is the single most useful thing a
# phone card carries and its own repository name is already the operator's
# recorded choice.
fm_telegram_utf8_truncate() {  # <character-limit> <byte-limit>
  local character_limit=$1 byte_limit=$2 locale_name='' value='' bytes candidate character count=0
  for candidate in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8 UTF-8; do
    if LC_ALL="$candidate" locale charmap 2>/dev/null | grep -Eiq '^UTF-?8$'; then
      locale_name=$candidate
      break
    fi
  done
  [ -n "$locale_name" ] || return 1
  while [ "$count" -lt "$character_limit" ] \
    && IFS= LC_ALL="$locale_name" read -r -n 1 character; do
    [ -n "$character" ] || character=$'\n'
    value+=$character
    count=$((count + 1))
  done
  bytes=$(printf '%s' "$value" | LC_ALL=C wc -c | tr -d '[:space:]') || return 1
  [ "$bytes" -le "$byte_limit" ] || return 1
  printf '%s' "$value"
}

_fm_telegram_token_core() {  # <token>
  local value=$1 first last
  while [ -n "$value" ]; do
    first=${value:0:1}
    case "$first" in [[:alnum:]_./-]) break ;; esac
    value=${value:1}
  done
  while [ -n "$value" ]; do
    last=${value: -1}
    case "$last" in [[:alnum:]_./-]) break ;; esac
    value=${value%?}
  done
  printf '%s' "$value"
}

_fm_telegram_internal_name() {  # <name>
  case "$1" in
    child|task|fingerprint|key|mode|yolo|harness|backend|window|worktree|branch|report|pane|session) return 0 ;;
  esac
  return 1
}

_fm_telegram_internal_value() {  # <value>
  case "$1" in
    fm/*|claude|codex|opencode|pi-signed|pi|grok|kimi|cursor|muse) return 0 ;;
  esac
  return 1
}

_fm_telegram_scrub_token() {  # <token>
  local token=$1 name='' separator='' value core
  core=$(_fm_telegram_token_core "$token")
  if [[ "$core" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
    printf '%s' "$token"
    return 0
  fi
  case "$token" in
    *=*) name=${token%%=*}; separator='='; value=${token#*=} ;;
    *:*) name=${token%%:*}; separator=':'; value=${token#*:} ;;
    *) value=$token ;;
  esac
  if [ -n "$separator" ]; then
    name=$(_fm_telegram_token_core "$name")
    core=$(_fm_telegram_token_core "$value")
    if [[ "$core" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
      printf '%s' "$token"
      return 0
    fi
    _fm_telegram_internal_name "$name" && return 0
    case "$core" in /*) printf '%s%s' "$name" "$separator"; return 0 ;; esac
    if _fm_telegram_internal_value "$core"; then
      printf '%s%s' "$name" "$separator"
    else
      printf '%s' "$token"
    fi
    return 0
  fi
  case "$core" in /*) return 0 ;; esac
  _fm_telegram_internal_value "$core" && return 0
  printf '%s' "$token"
}

fm_telegram_scrub() {  # <text>
  local folded token scrubbed output=''
  local -a tokens=()
  folded=$(printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ')
  read -r -a tokens <<< "$folded"
  for token in "${tokens[@]}"; do
    scrubbed=$(_fm_telegram_scrub_token "$token")
    [ -z "$scrubbed" ] || output="${output}${output:+ }$scrubbed"
  done
  printf '%s' "$output" \
    | fm_telegram_utf8_truncate "$FM_TELEGRAM_FIELD_MAX" "$FM_TELEGRAM_FIELD_BYTES_MAX"
}

# --- card templates ---------------------------------------------------------

# The four card classes, each a fixed template over named fields. Prints the
# card text. Returns 2 for an unknown class or a missing required field, and 3
# when a field still carries a machine line shape.
#
# Fields are given as name=value arguments; a name outside the class's own set
# is refused rather than ignored, so a publisher cannot quietly widen what a
# card carries.
fm_telegram_card_render() {  # <class> <name=value>...
  local class=$1 arg name value
  local title='' reason='' project='' url='' note=''
  shift
  for arg in "$@"; do
    case "$arg" in *=*) ;; *) return 2 ;; esac
    name=${arg%%=*}
    value=${arg#*=}
    if fm_telegram_looks_like_status_line "$value"; then
      return 3
    fi
    if [ "$name" = url ]; then
      value=$(printf '%s' "$value" \
        | LC_ALL=C tr '\t\r\n' '   ' \
        | LC_ALL=C sed -E -e 's/[[:space:]]+/ /g' -e 's/^ //' -e 's/ $//' \
        | fm_telegram_utf8_truncate "$FM_TELEGRAM_FIELD_MAX" "$FM_TELEGRAM_FIELD_BYTES_MAX")
    else
      value=$(fm_telegram_scrub "$value")
    fi
    case "$name" in
      title) title=$value ;;
      reason) reason=$value ;;
      project) project=$value ;;
      url) url=$value ;;
      note) note=$value ;;
      *) return 2 ;;
    esac
  done
  case "$class" in
    decision)
      [ -n "$title" ] || return 2
      printf 'Decision waiting\n%s\n' "$title"
      [ -z "$reason" ] || printf '%s\n' "$reason"
      ;;
    pr-ready)
      [ -n "$url" ] || return 2
      printf 'Ready for your review\n'
      [ -z "$project" ] || printf '%s\n' "$project"
      printf '%s\n' "$url"
      ;;
    failed)
      [ -n "$project" ] || return 2
      printf 'Work stopped\n%s\n' "$project"
      [ -z "$note" ] || printf '%s\n' "$note"
      ;;
    landed)
      [ -n "$url" ] || return 2
      printf 'Work landed\n'
      [ -z "$project" ] || printf '%s\n' "$project"
      printf '%s\n' "$url"
      ;;
    *) return 2 ;;
  esac
}

# --- outbox -----------------------------------------------------------------

fm_telegram_outbox_dir() {  # <state>
  printf '%s/%s\n' "$1" "$FM_TELEGRAM_OUTBOX_DIRNAME"
}

_fm_telegram_key_hash() {  # <key>
  local out
  if command -v shasum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}')
  else
    return 1
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "${out:0:16}"
}

fm_telegram_event_digest() {  # <locally-held canonical identity>
  _fm_telegram_key_hash "$1"
}

# A card key must be usable as a file-name component, the same rule the parent
# channel applies to a mate id.
_fm_telegram_key_valid() {  # <key>
  local LC_ALL=C
  case "${1-}" in
    ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# True when this key has already been delivered. The ledger holds the same card
# identity a card file's name carries, so the sender can record a delivery
# knowing only the file it sent. The ledger is bounded, so a very old identity
# can age out and produce one duplicate card; the design this implements
# accepts a duplicate and never a miss.
fm_telegram_delivered() {  # <state> <key>
  local ledger hash
  ledger="$(fm_telegram_outbox_dir "$1")/$FM_TELEGRAM_DELIVERED_BASENAME"
  [ -f "$ledger" ] && [ ! -L "$ledger" ] || return 1
  hash=$(_fm_telegram_key_hash "$1|$2") || return 1
  grep -Fqx -- "$hash" "$ledger" 2>/dev/null
}

# Record one delivered card and trim the ledger to its bound. The argument is
# the card identity its file name carries, not the publisher's key.
fm_telegram_mark_delivered() {  # <state> <card-identity>
  local dir ledger tmp
  dir=$(fm_telegram_outbox_dir "$1")
  ledger="$dir/$FM_TELEGRAM_DELIVERED_BASENAME"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  fm_pr_regular_destination_or_absent "$ledger" || return 1
  printf '%s\n' "$2" >> "$ledger" || return 1
  chmod 0600 "$ledger" 2>/dev/null || true
  if [ "$(wc -l < "$ledger" 2>/dev/null || echo 0)" -gt "$FM_TELEGRAM_DELIVERED_KEEP" ]; then
    tmp=$(umask 077; mktemp "$dir/.delivered.XXXXXX" 2>/dev/null) || return 0
    if tail -n "$FM_TELEGRAM_DELIVERED_KEEP" "$ledger" > "$tmp" 2>/dev/null; then
      chmod 0600 "$tmp" 2>/dev/null || true
      mv -f -- "$tmp" "$ledger" 2>/dev/null || rm -f -- "$tmp"
    else
      rm -f -- "$tmp"
    fi
  fi
}

# The card file this key would occupy. Naming is epoch-then-key so a plain sort
# drains roughly in the order the outcomes happened; cards are independent
# notifications, so ordering within one second is deliberately unspecified.
_fm_telegram_card_path() {  # <state> <key>
  local hash
  hash=$(_fm_telegram_key_hash "$1|$2") || return 1
  printf '%s/%s-%s.card\n' "$(fm_telegram_outbox_dir "$1")" "$(date +%s)" "$hash"
}

# True when a card for <key> is already queued.
fm_telegram_queued() {  # <state> <key>
  local dir hash
  dir=$(fm_telegram_outbox_dir "$1")
  hash=$(_fm_telegram_key_hash "$1|$2") || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  ls "$dir"/*-"$hash".card >/dev/null 2>&1
}

# One loud local diagnostic. A refused or undeliverable card is never silent:
# the whole point of the feature is that the captain learns about work he has
# to act on, so a card that will not be sent has to be visible where it was
# refused.
_fm_telegram_actionable() {  # <message>
  printf 'actionable: telegram card %s\n' "$1" >&2
}

# Queue one card for <class> from typed fields.
#
# THE PUBLISHER CONTRACT. This is called from scripts on the critical path of
# landing work, so it does exactly one local directory write and never a
# network call, never a lock wait, and never anything a caller has to handle:
# every failure is reported here on stderr and the caller's own return code is
# untouched. Returns 0 when a card was queued, was already queued, or the home
# has not opted in; 3 when the card was refused for content; 1 on a local
# failure to write it.
fm_telegram_notify() {  # <home> <state> <class> <key> <name=value>...
  local home=$1 state=$2 class=$3 key=$4 card path tmp rc=0 secret_rc=0
  shift 4
  fm_telegram_config_load "$home" >/dev/null 2>&1 || return 0
  _fm_telegram_key_valid "$key" || { _fm_telegram_actionable "has an unusable key"; return 1; }
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  card=$(fm_telegram_card_render "$class" "$@") || rc=$?
  case "$rc" in
    0) ;;
    3)
      _fm_telegram_actionable "for $class was refused: a field carried a raw status line"
      return 3
      ;;
    *)
      _fm_telegram_actionable "for $class could not be built from the fields given"
      return 3
      ;;
  esac
  card=$(printf '%s' "$card" \
    | fm_telegram_utf8_truncate "$FM_TELEGRAM_CARD_MAX" "$FM_TELEGRAM_CARD_BYTES_MAX") || {
    _fm_telegram_actionable "for $class could not be bounded as valid UTF-8"
    return 3
  }
  fm_telegram_refuse_if_secret "$home" "$card" || secret_rc=$?
  case "$secret_rc" in
    0) ;;
    1) _fm_telegram_actionable "for $class was refused: it would have carried a credential value"; return 3 ;;
    *) _fm_telegram_actionable "for $class was refused: credential file could not be checked: $FM_TELEGRAM_SECRET_ERROR_PATH"; return 3 ;;
  esac
  mkdir -p "$(fm_telegram_outbox_dir "$state")" 2>/dev/null || return 1
  chmod 0700 "$(fm_telegram_outbox_dir "$state")" 2>/dev/null || true
  # Delivery moves monotonically from queued to both queued-and-delivered and
  # finally delivered-only. Observe that transition in the same order so a
  # publisher racing the sender cannot see both states as absent.
  if fm_telegram_queued "$state" "$key" || fm_telegram_delivered "$state" "$key"; then
    return 0
  fi
  path=$(_fm_telegram_card_path "$state" "$key") || return 1
  fm_pr_regular_destination_or_absent "$path" || return 1
  tmp=$(umask 077; mktemp "$(fm_telegram_outbox_dir "$state")/.card.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$card" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    _fm_telegram_actionable "for $class could not be written to the outbox"
    return 1
  fi
  return 0
}
