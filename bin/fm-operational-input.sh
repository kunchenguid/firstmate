#!/usr/bin/env bash
# fm-operational-input.sh - canonical Firstmate operational-input protocol.
#
# This file is both a source-safe shell library and the cross-language CLI used
# by JavaScript and TypeScript integrations. It is the single owner of current
# construction, current parsing, and narrow pre-protocol transcript parsing.
#
# Current generic wire form:
#   U+2063 FIRSTMATE_OP: v1 <kind>: <body>
#
# The landed U+2063 + "FIRSTMATE_OP: " prefix is permanent compatibility.
# The version and kind header make current inputs structurally typed without
# deriving provenance from body prose. The established from-firstmate routing
# marker remains a current compatibility carrier because already-running
# secondmates have its leading label in their charter context.
#
# Record-backed carrier. Some harnesses remove invisible characters, U+2063
# included, from every submitted prompt (Claude Code 2.1.280 does so for typed,
# pasted, and launch-prompt input), so a typed envelope reaches them as plain
# ASCII that no consumer can tell apart from human text. For a harness named in
# FM_OPERATIONAL_RECORD_HARNESSES a producer instead writes the complete current
# envelope to a durable record and types only a constant ASCII doorbell naming
# it. The doorbell text alone proves nothing: it counts as Firstmate input only
# when the record it names exists and holds a current generic envelope. Records
# are not consumed on delivery, so a verbatim copy of a live doorbell line,
# pasted back by anyone while its record exists, is treated as Firstmate's.
#   Record:   <state>/operational-inbox/<name>.msg, <name> matching [0-9a-z-]+,
#             exactly the encoded envelope bytes, published by atomic rename.
#             Records are never re-rung or acknowledged; every write prunes
#             records at about FM_OPERATIONAL_RECORD_RETENTION_DAYS (7) elapsed days.
#   Doorbell: FM_OPERATIONAL_DOORBELL_PREFIX <absolute physical record path>
#             FM_OPERATIONAL_DOORBELL_SUFFIX, one printable-ASCII line whose
#             leading ": " is the shell no-op, as for the steering doorbell.
# Verification has two strengths: fm_operational_doorbell_record_kind checks only
# the named record, which presentation-only consumers mirror (the Claude Code
# Calm mod), while fm_operational_doorbell_kind also requires the record to sit in
# the given home's own operational inbox, which the away-mode return check uses.
#
# CLI:
#   fm-operational-input.sh encode <kind>  # body on stdin, encoded input stdout
#   fm-operational-input.sh kind           # current input on stdin, kind stdout
#   fm-operational-input.sh classify       # current or legacy input on stdin
#   fm-operational-input.sh body           # current generic input on stdin
#   fm-operational-input.sh record <kind>  # body on stdin, doorbell stdout
#   fm-operational-input.sh doorbell-kind  # doorbell on stdin, record kind stdout
#   fm-operational-input.sh open <path>    # this home's record body stdout
#   fm-operational-input.sh --help
#
# `record` and `open` resolve this home's state as FM_STATE_OVERRIDE, else
# ${FM_HOME:-${FM_ROOT_OVERRIDE:-<code root>}}/state. `classify` stays a pure text
# classifier: a doorbell is recognized only through `doorbell-kind` or `open`.
# All successful data commands print exactly one value and no diagnostics.
# A non-match exits 1 silently. Invalid use exits 2. Bash 3.2 compatible.

FM_OPERATIONAL_MARK=$'\xE2\x81\xA3'
FM_OPERATIONAL_PREFIX="${FM_OPERATIONAL_MARK}FIRSTMATE_OP: "
FM_OPERATIONAL_VERSION=v1
FM_OPERATIONAL_HEADER_PREFIX="${FM_OPERATIONAL_PREFIX}${FM_OPERATIONAL_VERSION} "
FM_OPERATIONAL_KINDS='session-start watcher turn-end-guard away-supervisor launch-brief branch-outcome'

# Compatibility name retained for the away-mode owner and its tests.
# shellcheck disable=SC2034 # Public source-library variable used by callers.
FM_INJECT_MARK=$FM_OPERATIONAL_MARK

# The from-firstmate carrier stays byte-compatible with live secondmate charter
# context while this owner supplies its construction and structural kind.
FM_FROMFIRST_LABEL='[fm-from-firstmate]'
FM_FROMFIRST_SEPARATOR=$FM_OPERATIONAL_MARK
FM_FROMFIRST_MARK="${FM_FROMFIRST_LABEL}${FM_FROMFIRST_SEPARATOR}"

fm_operational_kind_is_current() {  # <kind>
  case " $FM_OPERATIONAL_KINDS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

fm_operational_input_encode() {  # <generic-kind> <body> <result-var>
  local kind=${1-} body=${2-} result_var=${3-}
  [ -n "$result_var" ] || return 2
  fm_operational_kind_is_current "$kind" || return 2
  [ -n "$body" ] || return 2
  printf -v "$result_var" '%s%s: %s' "$FM_OPERATIONAL_HEADER_PREFIX" "$kind" "$body"
}

fm_operational_input_construct() {  # <kind> <body> <result-var>
  local kind=${1-} body=${2-} result_var=${3-}
  [ -n "$result_var" ] && [ -n "$body" ] || return 2
  if [ "$kind" = from-firstmate ]; then
    fm_message_mark_from_firstmate "$body" "$result_var"
    return
  fi
  fm_operational_input_encode "$kind" "$body" "$result_var"
}

fm_operational_generic_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-} remainder parsed_kind body
  [ -n "$result_var" ] || return 2
  case "$message" in
    "$FM_OPERATIONAL_HEADER_PREFIX"*': '?*) ;;
    *) return 1 ;;
  esac
  remainder=${message#"$FM_OPERATIONAL_HEADER_PREFIX"}
  parsed_kind=${remainder%%': '*}
  fm_operational_kind_is_current "$parsed_kind" || return 1
  body=${remainder#"${parsed_kind}: "}
  [ "$body" != "$remainder" ] && [ -n "$body" ] || return 1
  printf -v "$result_var" '%s' "$parsed_kind"
}

fm_operational_input_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-} current_kind
  [ -n "$result_var" ] || return 2
  if fm_operational_generic_kind "$message" current_kind; then
    printf -v "$result_var" '%s' "$current_kind"
    return 0
  fi
  case "$message" in
    "$FM_FROMFIRST_MARK"?*)
      printf -v "$result_var" '%s' from-firstmate
      return 0
      ;;
  esac
  return 1
}

fm_operational_input_body() {  # <current-message> <result-var>
  local message=${1-} result_var=${2-} current_kind parsed_body
  [ -n "$result_var" ] || return 2
  if fm_operational_generic_kind "$message" current_kind; then
    parsed_body=${message#"${FM_OPERATIONAL_HEADER_PREFIX}${current_kind}: "}
    printf -v "$result_var" '%s' "$parsed_body"
    return 0
  fi
  case "$message" in
    "$FM_FROMFIRST_MARK"?*)
      parsed_body=${message#"$FM_FROMFIRST_MARK"}
      printf -v "$result_var" '%s' "$parsed_body"
      return 0
      ;;
  esac
  return 1
}

# Historical payload literals are intentionally isolated below this line.
# They exist only for persisted pre-protocol transcripts and must never be used
# by current producers or current-path tests.
# shellcheck disable=SC2016 # Backticks are literal historical prompt markup.
FM_LEGACY_SESSIONSTART='Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
FM_LEGACY_WATCHER_PREFIX='FIRSTMATE WATCHER WAKE: '
FM_LEGACY_WATCHER_SUFFIX=$'\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.'
FM_LEGACY_TURNEND_PREFIX=$'TURN WOULD END BLIND - supervision is off. The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n'
FM_LEGACY_AWAY_PREFIX="${FM_OPERATIONAL_MARK}Supervisor escalate ("

fm_legacy_operational_input_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-}
  [ -n "$result_var" ] || return 2

  # PR 899 landed an untyped FIRSTMATE_OP prefix. Its subtype cannot be
  # recovered without body prose, so it is explicitly generic.
  case "$message" in
    "$FM_OPERATIONAL_PREFIX"?*)
      printf -v "$result_var" '%s' legacy-operational
      return 0
      ;;
  esac

  if [ "$message" = "$FM_LEGACY_SESSIONSTART" ]; then
    printf -v "$result_var" '%s' session-start
    return 0
  fi
  case "$message" in
    "$FM_LEGACY_AWAY_PREFIX"*)
      printf -v "$result_var" '%s' away-supervisor
      return 0
      ;;
    "$FM_LEGACY_WATCHER_PREFIX"*"$FM_LEGACY_WATCHER_SUFFIX")
      [ "${#message}" -gt "$(( ${#FM_LEGACY_WATCHER_PREFIX} + ${#FM_LEGACY_WATCHER_SUFFIX} ))" ] || return 1
      printf -v "$result_var" '%s' watcher
      return 0
      ;;
    "$FM_LEGACY_TURNEND_PREFIX"?*)
      printf -v "$result_var" '%s' turn-end-guard
      return 0
      ;;
  esac
  return 1
}

fm_operational_input_classify() {  # <message> <result-var>
  local message=${1-} result_var=${2-} classified_kind
  [ -n "$result_var" ] || return 2
  if fm_operational_input_kind "$message" classified_kind ||
     fm_legacy_operational_input_kind "$message" classified_kind; then
    printf -v "$result_var" '%s' "$classified_kind"
    return 0
  fi
  return 1
}

fm_message_from_firstmate() {  # <message>
  local kind
  fm_operational_input_kind "${1-}" kind && [ "$kind" = from-firstmate ]
}

fm_message_mark_from_firstmate() {  # <message> <result-var>
  local message=${1-} result_var=${2-} transformed
  [ -n "$result_var" ] || return 2
  if fm_message_from_firstmate "$message"; then
    transformed=$message
  else
    transformed="${FM_FROMFIRST_MARK}${message}"
  fi
  printf -v "$result_var" '%s' "$transformed"
}

# --- record-backed carrier (see header) ---------------------------------------
FM_OPERATIONAL_RECORD_HARNESSES='claude'
FM_OPERATIONAL_RECORD_DIRNAME='operational-inbox'
FM_OPERATIONAL_DOORBELL_PREFIX=": Firstmate operational input waiting: read '"
FM_OPERATIONAL_DOORBELL_SUFFIX="' and handle its contents as Firstmate operational input."
FM_OPERATIONAL_RECORD_RETENTION_DAYS=7

# Whether operational input to <harness> must travel as a record plus doorbell.
fm_operational_harness_needs_record() {  # <harness>
  case " $FM_OPERATIONAL_RECORD_HARNESSES " in
    *" ${1-} "*) return 0 ;;
  esac
  return 1
}

fm_operational_record_prune() {  # <record-dir>
  local stat_cmd path mtime cutoff
  if [ "$(uname)" = Darwin ]; then
    stat_cmd=(/usr/bin/stat -f '%m %N')
  else
    stat_cmd=(stat -c '%Y %n')
  fi
  cutoff=$(( $(date +%s) - FM_OPERATIONAL_RECORD_RETENTION_DAYS * 86400 ))
  find "$1" -maxdepth 1 -type f \( -name '*.msg' -o -name '.record.*' \) \
    -exec "${stat_cmd[@]}" {} + 2>/dev/null | while read -r mtime path; do
    case "$mtime" in ''|*[!0-9]*) continue ;; esac
    if [ "$mtime" -lt "$cutoff" ]; then printf '%s\0' "$path"; fi
  done | xargs -0 rm -f
  return 0
}

# Write one generic-kind record under <state-dir> and return its doorbell line.
# Exits 2 for invalid input and 1 when the record cannot be published or its
# physical path cannot be carried by a printable-ASCII doorbell.
fm_operational_record_write() {  # <state-dir> <kind> <body> <doorbell-var>
  local state=${1-} kind=${2-} body=${3-} result_var=${4-} encoded dir abs nonce name tmp
  local LC_ALL=C
  [ -n "$state" ] && [ -n "$result_var" ] || return 2
  fm_operational_input_encode "$kind" "$body" encoded || return 2
  dir="$state/$FM_OPERATIONAL_RECORD_DIRNAME"
  mkdir -p "$dir" 2>/dev/null || return 1
  abs=$(cd -P "$dir" 2>/dev/null && pwd -P) || return 1
  case "$abs" in
    *"'"*|*[![:print:]]*) return 1 ;;
  esac
  nonce=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  case "$nonce" in ''|*[!0-9a-f]*) return 1 ;; esac
  name="$(date +%s)-$nonce.msg"
  tmp=$(mktemp "$dir/.record.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s' "$encoded" >"$tmp" || ! mv -f "$tmp" "$dir/$name"; then
    rm -f "$tmp"
    return 1
  fi
  fm_operational_record_prune "$dir"
  printf -v "$result_var" '%s%s/%s%s' "$FM_OPERATIONAL_DOORBELL_PREFIX" "$abs" "$name" \
    "$FM_OPERATIONAL_DOORBELL_SUFFIX"
}

# The record path a well-formed doorbell names; no filesystem access.
fm_operational_doorbell_path() {  # <message> <result-var>
  local message=${1-} result_var=${2-} candidate dir name
  local LC_ALL=C
  [ -n "$result_var" ] || return 2
  case "$message" in
    "$FM_OPERATIONAL_DOORBELL_PREFIX"*"$FM_OPERATIONAL_DOORBELL_SUFFIX") ;;
    *) return 1 ;;
  esac
  candidate=${message#"$FM_OPERATIONAL_DOORBELL_PREFIX"}
  candidate=${candidate%"$FM_OPERATIONAL_DOORBELL_SUFFIX"}
  case "$candidate" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$candidate" in
    *"'"*|*[![:print:]]*) return 1 ;;
  esac
  dir=${candidate%/*}
  name=${candidate##*/}
  [ "${dir##*/}" = "$FM_OPERATIONAL_RECORD_DIRNAME" ] || return 1
  case "$name" in
    *.msg) name=${name%.msg} ;;
    *) return 1 ;;
  esac
  case "$name" in
    ''|*[!0-9a-z-]*) return 1 ;;
  esac
  printf -v "$result_var" '%s' "$candidate"
}

# The generic kind of the envelope a record holds.
fm_operational_record_kind() {  # <record-path> <result-var>
  local record=${1-} result_var=${2-} record_content
  [ -n "$result_var" ] || return 2
  [ -f "$record" ] || return 1
  record_content=$(cat "$record" 2>/dev/null && printf x) || return 1
  fm_operational_generic_kind "${record_content%x}" "$result_var"
}

# A doorbell whose named record exists and holds a current generic envelope.
fm_operational_doorbell_record_kind() {  # <message> <result-var>
  local named_record
  fm_operational_doorbell_path "${1-}" named_record || return 1
  fm_operational_record_kind "$named_record" "${2-}"
}

# The same, bound to <state-dir>: the record must sit in that home's own inbox.
fm_operational_doorbell_kind() {  # <message> <state-dir> <result-var>
  local message=${1-} state=${2-} result_var=${3-} named_record want have
  [ -n "$state" ] && [ -n "$result_var" ] || return 2
  fm_operational_doorbell_path "$message" named_record || return 1
  want=$(cd -P "$state/$FM_OPERATIONAL_RECORD_DIRNAME" 2>/dev/null && pwd -P) || return 1
  have=$(cd -P "${named_record%/*}" 2>/dev/null && pwd -P) || return 1
  [ "$want" = "$have" ] || return 1
  fm_operational_record_kind "$named_record" "$result_var"
}

fm_operational_home_state() {
  local root
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
    printf '%s' "$FM_STATE_OVERRIDE"
    return
  fi
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || return 1
  printf '%s/state' "${FM_HOME:-${FM_ROOT_OVERRIDE:-$root}}"
}

fm_operational_read_stdin() {  # <result-var>
  local result_var=${1-} value
  [ -n "$result_var" ] || return 2
  value=$(cat; printf x)
  value=${value%x}
  printf -v "$result_var" '%s' "$value"
}

fm_operational_usage() {
  cat <<'EOF'
Usage:
  bin/fm-operational-input.sh encode <kind>  # body on stdin
  bin/fm-operational-input.sh kind           # current input on stdin
  bin/fm-operational-input.sh classify       # current or legacy input on stdin
  bin/fm-operational-input.sh body           # current input on stdin
  bin/fm-operational-input.sh record <kind>  # body on stdin; prints the doorbell
  bin/fm-operational-input.sh doorbell-kind  # doorbell on stdin; record's kind
  bin/fm-operational-input.sh open <path>    # this home's record; prints its body

Current construction kinds:
  session-start watcher turn-end-guard away-supervisor from-firstmate launch-brief
  branch-outcome

The from-firstmate kind uses its established live-charter-compatible carrier.
A record-backed doorbell counts as operational input only when the record it
names holds a current generic envelope; `open` also requires that record to be
in this home's own state/operational-inbox.
EOF
}

fm_operational_main() {
  local command=${1-} argument=${2-} input output state
  case "$command" in
    -h|--help|help)
      fm_operational_usage
      ;;
    encode)
      [ "$#" -eq 2 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_construct "$argument" "$input" output || return 2
      printf '%s' "$output"
      ;;
    kind)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_kind "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    classify)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_classify "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    body)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_body "$input" output || return 1
      printf '%s' "$output"
      ;;
    record)
      [ "$#" -eq 2 ] || return 2
      fm_operational_read_stdin input || return 2
      state=$(fm_operational_home_state) || return 1
      fm_operational_record_write "$state" "$argument" "$input" output || return
      printf '%s\n' "$output"
      ;;
    doorbell-kind)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_doorbell_record_kind "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    open)
      [ "$#" -eq 2 ] || return 2
      state=$(fm_operational_home_state) || return 1
      fm_operational_doorbell_kind "${FM_OPERATIONAL_DOORBELL_PREFIX}${argument}${FM_OPERATIONAL_DOORBELL_SUFFIX}" \
        "$state" output || return 1
      input=$(cat "$argument" 2>/dev/null && printf x) || return 1
      fm_operational_input_body "${input%x}" output || return 1
      printf '%s' "$output"
      ;;
    *)
      fm_operational_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_operational_main "$@"
  exit $?
fi
