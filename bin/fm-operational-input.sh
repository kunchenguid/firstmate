#!/usr/bin/env bash
# fm-operational-input.sh - canonical Firstmate operational-input protocol.
#
# This file is both a source-safe shell library and the cross-language CLI used
# by JavaScript and TypeScript integrations. It is the single owner of current
# construction, current parsing, and narrow pre-protocol transcript parsing.
#
# Current generic wire form, for every kind INJECTED into a running agent:
#   U+2063 FIRSTMATE_OP: v1 <kind>: <body>
#
# Current generic wire form, for a kind listed in FM_OPERATIONAL_UNMARKED_KINDS:
#   FIRSTMATE_OP: v1 <kind>: <body>
#
# The unmarked form is the marked form minus its leading U+2063, and is accepted
# on parse ONLY for a declared unmarked kind, so no injected kind can be forged
# without the mark. See FM_OPERATIONAL_UNMARKED_KINDS below for why launch-brief
# is the one kind that carries it.
#
# The landed U+2063 + "FIRSTMATE_OP: " prefix is permanent compatibility.
# The version and kind header make current inputs structurally typed without
# deriving provenance from body prose. The established from-firstmate routing
# marker remains a current compatibility carrier because already-running
# secondmates have its leading label in their charter context.
#
# CLI:
#   fm-operational-input.sh encode <kind>  # body on stdin, encoded input stdout
#   fm-operational-input.sh kind           # current input on stdin, kind stdout
#   fm-operational-input.sh classify       # current or legacy input on stdin
#   fm-operational-input.sh body           # current generic input on stdin
#   fm-operational-input.sh --help
#
# All successful data commands print exactly one value and no diagnostics.
# A non-match exits 1 silently. Invalid use exits 2. Bash 3.2 compatible.

FM_OPERATIONAL_MARK=$'\xE2\x81\xA3'
FM_OPERATIONAL_PREFIX="${FM_OPERATIONAL_MARK}FIRSTMATE_OP: "
FM_OPERATIONAL_VERSION=v1
FM_OPERATIONAL_HEADER_PREFIX="${FM_OPERATIONAL_PREFIX}${FM_OPERATIONAL_VERSION} "
FM_OPERATIONAL_KINDS='session-start watcher turn-end-guard away-supervisor launch-brief'

# launch-brief is the one kind that is never INJECTED into a running agent: it is
# passed as the agent's argv launch prompt by bin/fm-spawn.sh. The leading U+2063
# mark exists to make injected input unforgeable by a human typing at a composer,
# a property an argv launch prompt cannot need, so launch-brief carries the same
# versioned envelope without the zero-width mark. Every injected kind keeps the
# marked envelope and its anti-forgery guarantee unchanged.
#
# This is load-bearing, not cosmetic: agents set their terminal pane title from
# their own launch prompt, and tmux 3.7b aborts the ENTIRE server on a title
# containing U+2063 ("utf8proc_wcwidth(02063) returned 0" ->
# "fatal: xreallocarray: zero size"), killing every window at once. The header
# alone is not enough for that: an unmarked kind's body is captain-supplied
# text, so fm_operational_input_encode strips U+2063 from it and the whole
# envelope carries no mark in any position.
FM_OPERATIONAL_UNMARKED_KINDS='launch-brief'
# Derived, never re-typed: the unmarked header is exactly the marked header with
# its leading U+2063 removed, so the two forms cannot drift apart.
FM_OPERATIONAL_UNMARKED_HEADER_PREFIX="${FM_OPERATIONAL_HEADER_PREFIX#"$FM_OPERATIONAL_MARK"}"

fm_operational_kind_is_unmarked() {  # <kind>
  case " $FM_OPERATIONAL_UNMARKED_KINDS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

fm_operational_header_for_kind() {  # <kind> <result-var>
  local header_kind=${1-} header_result_var=${2-}
  [ -n "$header_result_var" ] || return 2
  if fm_operational_kind_is_unmarked "$header_kind"; then
    printf -v "$header_result_var" '%s' "$FM_OPERATIONAL_UNMARKED_HEADER_PREFIX"
  else
    printf -v "$header_result_var" '%s' "$FM_OPERATIONAL_HEADER_PREFIX"
  fi
}

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

# Convention for every <result-var> function below: EVERY local is prefixed with
# a per-function tag, with no exception for the parameters. This is not
# stylistic. Under bash dynamic scoping an unprefixed local silently shadows a
# caller's own result-variable name, so the write lands on the local, the
# function still returns 0, and the caller reads an empty value instead of an
# error. tests/fm-operational-input.test.sh locks this by round-tripping the
# public entry points through every plausible caller-side name.
fm_operational_input_encode() {  # <generic-kind> <body> <result-var>
  local encode_kind=${1-} encode_body=${2-} encode_result_var=${3-} encode_header
  [ -n "$encode_result_var" ] || return 2
  fm_operational_kind_is_current "$encode_kind" || return 2
  [ -n "$encode_body" ] || return 2
  fm_operational_header_for_kind "$encode_kind" encode_header || return 2
  # An unmarked kind guarantees a mark-free envelope in every position, not just
  # in its header: the body is captain-supplied text and a pane title built from
  # it aborts the whole tmux server on a single U+2063. A body that is nothing
  # but marks encodes to no body at all, which is invalid use.
  if fm_operational_kind_is_unmarked "$encode_kind"; then
    encode_body=${encode_body//"$FM_OPERATIONAL_MARK"/}
    [ -n "$encode_body" ] || return 2
  fi
  printf -v "$encode_result_var" '%s%s: %s' "$encode_header" "$encode_kind" "$encode_body"
}

fm_operational_input_construct() {  # <kind> <body> <result-var>
  local construct_kind=${1-} construct_body=${2-} construct_result_var=${3-}
  [ -n "$construct_result_var" ] && [ -n "$construct_body" ] || return 2
  if [ "$construct_kind" = from-firstmate ]; then
    fm_message_mark_from_firstmate "$construct_body" "$construct_result_var"
    return
  fi
  fm_operational_input_encode "$construct_kind" "$construct_body" "$construct_result_var"
}

# Single owner of current-envelope splitting for both the marked and the
# unmarked header. An unmarked header is accepted only for a kind declared in
# FM_OPERATIONAL_UNMARKED_KINDS, so no injected kind can be forged without the
# zero-width mark.
fm_operational_generic_split() {  # <message> <kind-result-var> <body-result-var>
  local split_message=${1-} split_kind_var=${2-} split_body_var=${3-}
  local split_header split_remainder split_kind split_body
  [ -n "$split_kind_var" ] && [ -n "$split_body_var" ] || return 2
  case "$split_message" in
    "$FM_OPERATIONAL_HEADER_PREFIX"*': '?*) split_header=$FM_OPERATIONAL_HEADER_PREFIX ;;
    "$FM_OPERATIONAL_UNMARKED_HEADER_PREFIX"*': '?*) split_header=$FM_OPERATIONAL_UNMARKED_HEADER_PREFIX ;;
    *) return 1 ;;
  esac
  split_remainder=${split_message#"$split_header"}
  split_kind=${split_remainder%%': '*}
  fm_operational_kind_is_current "$split_kind" || return 1
  if [ "$split_header" = "$FM_OPERATIONAL_UNMARKED_HEADER_PREFIX" ]; then
    fm_operational_kind_is_unmarked "$split_kind" || return 1
  fi
  split_body=${split_remainder#"${split_kind}: "}
  [ "$split_body" != "$split_remainder" ] && [ -n "$split_body" ] || return 1
  printf -v "$split_kind_var" '%s' "$split_kind"
  printf -v "$split_body_var" '%s' "$split_body"
}

fm_operational_generic_kind() {  # <message> <result-var>
  # shellcheck disable=SC2034 # Declared local so the splitter's write stays scoped.
  local gkind_message=${1-} gkind_result_var=${2-} gkind_parsed_kind gkind_parsed_body
  [ -n "$gkind_result_var" ] || return 2
  fm_operational_generic_split "$gkind_message" gkind_parsed_kind gkind_parsed_body || return 1
  printf -v "$gkind_result_var" '%s' "$gkind_parsed_kind"
}

fm_operational_input_kind() {  # <message> <result-var>
  local kind_message=${1-} kind_result_var=${2-} kind_current
  [ -n "$kind_result_var" ] || return 2
  if fm_operational_generic_kind "$kind_message" kind_current; then
    printf -v "$kind_result_var" '%s' "$kind_current"
    return 0
  fi
  case "$kind_message" in
    "$FM_FROMFIRST_MARK"?*)
      printf -v "$kind_result_var" '%s' from-firstmate
      return 0
      ;;
  esac
  return 1
}

fm_operational_input_body() {  # <current-message> <result-var>
  # shellcheck disable=SC2034 # Declared local so the splitter's write stays scoped.
  local body_message=${1-} body_result_var=${2-} body_current_kind body_parsed
  [ -n "$body_result_var" ] || return 2
  if fm_operational_generic_split "$body_message" body_current_kind body_parsed; then
    printf -v "$body_result_var" '%s' "$body_parsed"
    return 0
  fi
  case "$body_message" in
    "$FM_FROMFIRST_MARK"?*)
      body_parsed=${body_message#"$FM_FROMFIRST_MARK"}
      printf -v "$body_result_var" '%s' "$body_parsed"
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
  local legacy_message=${1-} legacy_result_var=${2-}
  [ -n "$legacy_result_var" ] || return 2

  # PR 899 landed an untyped FIRSTMATE_OP prefix. Its subtype cannot be
  # recovered without body prose, so it is explicitly generic.
  case "$legacy_message" in
    "$FM_OPERATIONAL_PREFIX"?*)
      printf -v "$legacy_result_var" '%s' legacy-operational
      return 0
      ;;
  esac

  if [ "$legacy_message" = "$FM_LEGACY_SESSIONSTART" ]; then
    printf -v "$legacy_result_var" '%s' session-start
    return 0
  fi
  case "$legacy_message" in
    "$FM_LEGACY_AWAY_PREFIX"*)
      printf -v "$legacy_result_var" '%s' away-supervisor
      return 0
      ;;
    "$FM_LEGACY_WATCHER_PREFIX"*"$FM_LEGACY_WATCHER_SUFFIX")
      [ "${#legacy_message}" -gt "$(( ${#FM_LEGACY_WATCHER_PREFIX} + ${#FM_LEGACY_WATCHER_SUFFIX} ))" ] || return 1
      printf -v "$legacy_result_var" '%s' watcher
      return 0
      ;;
    "$FM_LEGACY_TURNEND_PREFIX"?*)
      printf -v "$legacy_result_var" '%s' turn-end-guard
      return 0
      ;;
  esac
  return 1
}

fm_operational_input_classify() {  # <message> <result-var>
  local classify_message=${1-} classify_result_var=${2-} classify_kind
  [ -n "$classify_result_var" ] || return 2
  if fm_operational_input_kind "$classify_message" classify_kind ||
     fm_legacy_operational_input_kind "$classify_message" classify_kind; then
    printf -v "$classify_result_var" '%s' "$classify_kind"
    return 0
  fi
  return 1
}

fm_message_from_firstmate() {  # <message>
  local fromfirst_kind
  fm_operational_input_kind "${1-}" fromfirst_kind && [ "$fromfirst_kind" = from-firstmate ]
}

fm_message_mark_from_firstmate() {  # <message> <result-var>
  local mark_message=${1-} mark_result_var=${2-} mark_transformed
  [ -n "$mark_result_var" ] || return 2
  if fm_message_from_firstmate "$mark_message"; then
    mark_transformed=$mark_message
  else
    mark_transformed="${FM_FROMFIRST_MARK}${mark_message}"
  fi
  printf -v "$mark_result_var" '%s' "$mark_transformed"
}

fm_operational_read_stdin() {  # <result-var>
  local stdin_result_var=${1-} stdin_value
  [ -n "$stdin_result_var" ] || return 2
  stdin_value=$(cat; printf x)
  stdin_value=${stdin_value%x}
  printf -v "$stdin_result_var" '%s' "$stdin_value"
}

fm_operational_usage() {
  cat <<'EOF'
Usage:
  bin/fm-operational-input.sh encode <kind>  # body on stdin
  bin/fm-operational-input.sh kind           # current input on stdin
  bin/fm-operational-input.sh classify       # current or legacy input on stdin
  bin/fm-operational-input.sh body           # current input on stdin

Current construction kinds:
  session-start watcher turn-end-guard away-supervisor from-firstmate launch-brief

The from-firstmate kind uses its established live-charter-compatible carrier.
EOF
}

fm_operational_main() {
  local command=${1-} argument=${2-} input output
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
