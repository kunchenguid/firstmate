#!/usr/bin/env bash
# fm-compaction-check.sh - resolve the compaction trigger point of the pi
# sessions firstmate launches, and fail loudly when one is mis-sized.
#
# Usage:
#   fm-compaction-check.sh                print one line per session scope
#   fm-compaction-check.sh --all          same as above (explicit)
#   fm-compaction-check.sh --diagnostics  print the unsafe and error verdicts,
#                                         and nothing else
#
# THE ARITHMETIC (single owner: this file, function trigger_percent):
#   trigger_percent = (contextWindow - reserveTokens) / contextWindow * 100
# That is pi's own rule: pi compacts when
# contextTokens > contextWindow - reserveTokens, so reserveTokens is the margin
# held back below the window and the trigger point is where the window runs out
# of room for the answer. A too-small reserve therefore means "compaction fires
# too late" (effectively never, for a large window), and a reserve at or above
# the window means "compaction fires on every turn".
#
# SCOPE AND RESOLUTION
# One line per session scope firstmate launches:
#   primary        the firstmate primary session, cwd = the primary home.
#   global-scope   the pairing a session receives in a cwd with no project
#                  .pi/settings.json (firstmate launches crewmates into such
#                  worktrees), reported from the global settings file's own
#                  defaultProvider/defaultModel and reserveTokens.
#   secondmate-<id>  one per entry in the primary home's data/secondmates.md,
#                  cwd = that entry's home, model = the shared
#                  config/secondmate-harness pin ("<harness> [<model>] [<effort>]").
# A session's model follows pi's own settings precedence: the session cwd's
# .pi/settings.json over the global settings.json, merged key by key. The
# effective reserveTokens follows the same precedence over the same pair, and so
# does the effective compaction.enabled. That flag decides whether the reserve is
# judged at all: pi's shouldCompact returns false when enabled is false, so a
# scope that deliberately disables compaction never compacts and its reserveTokens
# is irrelevant. An ABSENT enabled key resolves to pi's own
# DEFAULT_COMPACTION_SETTINGS default, which is true, so an absent key keeps the
# reserve judging exactly as before. A NON-boolean enabled is a configuration
# defect, and this checker reports it as an error instead of reproducing pi's
# coercion: pi resolves it by JS truthiness (settings-manager.js
# getCompactionEnabled is `this.settings.compaction?.enabled ?? true`, and
# compaction.js shouldCompact short-circuits on `!settings.enabled`), so null and
# a truthy value such as "yes" or 1 resolve enabled while 0 and "" resolve
# disabled. Adopting that coercion would silently guess which of those the
# operator meant, so the divergence is deliberate and loud rather than silent.
# Project trust is assumed: pi ignores an untrusted project's settings, and
# firstmate relies on ~/.pi/agent/trust.json covering its homes (the standing
# setup carries a "/" entry, which pi's nearest-ancestor lookup applies to every
# home). A non-pi secondmate harness is skipped, because pi's compaction
# settings do not govern it. A host with no pi installed is skipped too: the
# check cannot say anything about a fleet that launches no pi sessions, and its
# noisy failure would be a permanent false alarm there.
#
# THE MODEL LIST
# Context windows come from `pi --list-models`, never from a hardcoded table.
# That command can return a PARTIAL list - whole providers missing - while still
# exiting 0, so this checker reads it up to FM_COMPACTION_MODELS_ATTEMPTS times
# (default 3) and unions the rows. A re-read happens only while some scope is
# still unresolved, so a healthy host pays exactly one invocation, and the
# worst case is bounded at three.
# A scope that stays unresolved is never silent:
#   reason=model-list-missing-provider  the scope's provider is absent from a
#                                       list that was read successfully, which
#                                       is the signature of a partial list
#   reason=model-not-in-pi-model-list   the provider is present but the model is
#                                       not
#   reason=model-id-ambiguous           a bare model id is served by more than
#                                       one provider
# If no attempt yields a usable list at all, the checker reports that once, as
# `session=all`, and exits 2.
#
# VERDICTS AND VISIBILITY
#   ok        trigger point is above 0% and at or below the limit
#   unsafe    trigger point is above the limit (reason=trigger-above-limit),
#             the reserve is not below the window at all
#             (reason=reserve-not-below-window), which compacts every turn,
#             the effective reasoning level is set from two conflicting
#             sources (reason=thinking-level-dual-source), the model's output
#             ceiling is below the fleet floor
#             (reason=output-budget-below-ceiling), or that ceiling exceeds
#             the reserve (reason=output-budget-exceeds-reserve)
#   skipped   no verdict is needed here: a non-pi harness, no pi installed, or a
#             scope whose effective compaction.enabled is false, which pi
#             short-circuits before the reserve is ever consulted
#   error     the scope has a verdict to give but an input is missing, absent,
#             or inconsistent
# --diagnostics is the session-start digest's view. It prints every unsafe line
# and every error line, and nothing else: one bounded line per affected scope,
# never a table. Only `ok` and `skipped` stay quiet, because neither withholds a
# verdict. A checker that can hide an unjudged scope is exactly how a mis-sized
# reserve goes unnoticed, so an incomplete list is reported rather than swallowed.
#
# Exit status: 0 every scope ok or skipped, 1 at least one unsafe, 2 at least one error.
#
# INPUTS (every one overridable so tests and fixtures can substitute them):
#   FM_COMPACTION_GLOBAL_SETTINGS   default ${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/settings.json
#   FM_COMPACTION_PRIMARY_HOME      default $FM_HOME, else the parent recorded in
#                                   $FM_HOME/.fm-secondmate-parent
#   FM_COMPACTION_SECONDMATES_FILE  default <primary home>/data/secondmates.md
#   FM_COMPACTION_HARNESS_FILE      default <primary home>/config/secondmate-harness
#   FM_COMPACTION_MODELS_CMD        default "pi --no-extensions --offline --list-models"
#                                   (splits on whitespace; --offline and
#                                   --no-extensions keep it fast and quiet on the
#                                   session-start critical path)
#   FM_COMPACTION_MODELS_ATTEMPTS   default 3; how many times the model list may
#                                   be read while a scope is unresolved
#   FM_COMPACTION_MAX_TRIGGER_PERCENT  default 60
#   FM_COMPACTION_MIN_OUTPUT_TOKENS  default 32768; the minimum model output
#                                   (max-out) ceiling a resolved scope may
#                                   report without an unsafe verdict
#
# Each emitted line also names the scope's effective reasoning level and the
# file that set it, so a per-home override of defaultThinkingLevel is visible
# rather than silent, and two conflicting sources are reported as unsafe.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

DEFAULT_MAX_TRIGGER_PERCENT=60
DEFAULT_MODELS_ATTEMPTS=3
DEFAULT_MIN_OUTPUT_TOKENS=32768
PI_DEFAULT_RESERVE_TOKENS=16384
# pi's own DEFAULT_COMPACTION_SETTINGS is
# {enabled: true, reserveTokens: 16384, keepRecentTokens: 20000}, read from
# @earendil-works/pi-coding-agent 0.85.1
# dist/bundle/chunks/chunk-JVUZSMYM.js. Its shouldCompact short-circuits on
# enabled, so an absent key must default to enabled and keep the reserve judging.
PI_DEFAULT_COMPACTION_ENABLED=true
CONFIG_DIR_NAME=.pi

MODE=all
VERDICT_WORST=0

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

die_usage() {
  printf 'fm-compaction-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) MODE=all ;;
    --diagnostics) MODE=diagnostics ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done

# --- inputs -----------------------------------------------------------------

GLOBAL_SETTINGS=${FM_COMPACTION_GLOBAL_SETTINGS:-${PI_CODING_AGENT_DIR:-${HOME:-}/.pi/agent}/settings.json}
DEFAULT_MODELS_CMD="pi --no-extensions --offline --list-models"
MODELS_CMD=${FM_COMPACTION_MODELS_CMD:-$DEFAULT_MODELS_CMD}
MODELS_ATTEMPTS=${FM_COMPACTION_MODELS_ATTEMPTS:-$DEFAULT_MODELS_ATTEMPTS}
MAX_TRIGGER_PERCENT=${FM_COMPACTION_MAX_TRIGGER_PERCENT:-$DEFAULT_MAX_TRIGGER_PERCENT}

case "$MAX_TRIGGER_PERCENT" in
  ''|*[!0-9.]*) die_usage "FM_COMPACTION_MAX_TRIGGER_PERCENT must be a positive number" ;;
esac
awk -v m="$MAX_TRIGGER_PERCENT" 'BEGIN { exit !(m > 0) }' \
  || die_usage "FM_COMPACTION_MAX_TRIGGER_PERCENT must be a positive number"
case "$MODELS_ATTEMPTS" in
  ''|*[!0-9]*) die_usage "FM_COMPACTION_MODELS_ATTEMPTS must be a positive integer" ;;
esac
[ "$MODELS_ATTEMPTS" -ge 1 ] || die_usage "FM_COMPACTION_MODELS_ATTEMPTS must be a positive integer"

# MLX/syslog local models were raised to a 32768-token output ceiling on
# 2026-10-09; a smaller ceiling leaves no room for the compaction summary to
# coexist with a full answer. Applied to every resolved scope as a fleet-wide
# minimum output budget, and overridable for a deliberate exception.
MIN_OUTPUT_TOKENS=${FM_COMPACTION_MIN_OUTPUT_TOKENS:-$DEFAULT_MIN_OUTPUT_TOKENS}
case "$MIN_OUTPUT_TOKENS" in
  ''|*[!0-9]*) die_usage "FM_COMPACTION_MIN_OUTPUT_TOKENS must be a positive integer" ;;
esac
[ "$MIN_OUTPUT_TOKENS" -ge 1 ] || die_usage "FM_COMPACTION_MIN_OUTPUT_TOKENS must be a positive integer"

# The primary home whose secondmate registry and harness pin are authoritative.
# A secondmate home records its parent in .fm-secondmate-parent, so a check run
# there still audits the whole fleet's primary-owned configuration.
PRIMARY_HOME=${FM_COMPACTION_PRIMARY_HOME:-}
if [ -z "$PRIMARY_HOME" ]; then
  PRIMARY_HOME=$FM_HOME
  parent_marker="$FM_HOME/.fm-secondmate-parent"
  if [ -f "$parent_marker" ]; then
    parent_home=$(sed -n 's/^parent_home=//p' "$parent_marker" | head -1)
    if [ -n "$parent_home" ] && [ -d "$parent_home" ]; then
      PRIMARY_HOME=$parent_home
    fi
  fi
fi
SECONDMATES_FILE=${FM_COMPACTION_SECONDMATES_FILE:-$PRIMARY_HOME/data/secondmates.md}
HARNESS_FILE=${FM_COMPACTION_HARNESS_FILE:-$PRIMARY_HOME/config/secondmate-harness}

# --- verdict bookkeeping ----------------------------------------------------

bump_verdict() {
  case "$1" in
    error) VERDICT_WORST=2 ;;
    unsafe) [ "$VERDICT_WORST" -eq 2 ] || VERDICT_WORST=1 ;;
  esac
}

# print_line <verdict> <name> <cwd> <model> <window> <reserve> <source> [<reason>] [<detail>]
#   [<thinking-level>] [<thinking-source>]
# Only `ok` and `skipped` are quiet in diagnostics mode: neither withholds a
# verdict, while `unsafe` and `error` both do.
print_line() {
  local verdict=$1 name=$2 cwd=$3 model=$4 window=$5 reserve=$6 source=$7
  local reason=${8:-} detail=${9:-} thinking=${10:-} thinking_source=${11:-}
  local suffix='' thinking_field=''
  bump_verdict "$verdict"
  if [ "$MODE" = diagnostics ] && [ "$verdict" != unsafe ] && [ "$verdict" != error ]; then
    return 0
  fi
  if [ -n "$thinking" ]; then
    thinking_field=" thinking=$thinking thinkingSource=${thinking_source:-builtin-pi-default}"
  fi
  if [ -n "$reason" ]; then
    suffix=" reason=$reason"
  fi
  if [ -n "$detail" ]; then
    suffix="$suffix ($detail)"
  fi
  printf 'COMPACTION: %s session=%s cwd=%s model=%s window=%s reserveTokens=%s source=%s%s%s\n' \
    "$verdict" "$name" "$cwd" "$model" "$window" "$reserve" "$source" "$thinking_field" "$suffix"
}

# --- model list -------------------------------------------------------------

MODEL_TABLE=
MODEL_ROWS=
MODELS_ATTEMPT_ERROR=
MODELS_UNAVAILABLE_REASON=
MODEL_TABLE_READY=0

# One read of the model-list command. Appends usable rows to MODEL_ROWS and sets
# MODELS_ATTEMPT_ERROR when this attempt produced none. Returns 0 when the
# attempt produced usable rows.
one_model_read() {
  local -a argv=()
  local raw table
  MODELS_ATTEMPT_ERROR=
  if [ "$MODELS_CMD" = "$DEFAULT_MODELS_CMD" ] && ! command -v pi >/dev/null 2>&1; then
    MODELS_ATTEMPT_ERROR="pi-not-installed"
    return 1
  fi
  # shellcheck disable=SC2206 # intentional word split: the override is a command line
  argv=($MODELS_CMD)
  if [ "${#argv[@]}" -eq 0 ]; then
    MODELS_ATTEMPT_ERROR="empty-model-list-command"
    return 1
  fi
  if ! raw=$("${argv[@]}" 2>/dev/null); then
    MODELS_ATTEMPT_ERROR="model-list-command-failed"
    return 1
  fi
  # The context column is printed with decimal suffixes (131.1K is 131072 rounded
  # to four significant figures), so K is 1000 and M is 1000000 here.
  table=$(printf '%s\n' "$raw" | awk '
    function to_tokens(value,  n) {
      n = value
      if (value ~ /[Kk]$/) { sub(/[Kk]$/, "", n); return int(n * 1000 + 0.5) }
      if (value ~ /[Mm]$/) { sub(/[Mm]$/, "", n); return int(n * 1000000 + 0.5) }
      if (value ~ /^[0-9]+$/) return int(n)
      return 0
    }
    NR == 1 && $1 == "provider" { next }
    NF >= 3 && $1 ~ /[^[:space:]]/ {
      tokens = to_tokens($3)
      if (tokens > 0) printf "%s|%s|%d|%s|%d|%s\n", $1, $2, tokens, $3, to_tokens($4), $4
    }
  ')
  if [ -z "$table" ]; then
    MODELS_ATTEMPT_ERROR="model-list-empty"
    return 1
  fi
  if [ -z "$MODEL_ROWS" ]; then
    MODEL_ROWS=$table
  else
    MODEL_ROWS=$(printf '%s\n%s\n' "$MODEL_ROWS" "$table")
  fi
  return 0
}

# Union of every row seen so far, one row per provider|model, first read wins.
build_model_table() {
  MODEL_TABLE=$(printf '%s\n' "$MODEL_ROWS" | awk -F'|' 'NF >= 4 && !seen[$1 "|" $2]++ { print }')
}

# window_row <provider> <model> -> "tokens|display|max-out|max-out-display" when the row exists
window_row() {
  printf '%s\n' "$MODEL_TABLE" | awk -F'|' -v p="$1" -v m="$2" \
    '$1 == p && $2 == m { print $3 "|" $4 "|" $5 "|" $6; found = 1 } END { if (!found) exit 1 }'
}

# provider_rows <provider> -> any row for that provider ("" when the whole
# provider is absent, which is how a partial list shows up)
provider_rows() {
  printf '%s\n' "$MODEL_TABLE" | awk -F'|' -v p="$1" '$1 == p { print; exit }'
}

# model_rows <model> -> "provider|tokens|display|max-out|max-out-display" for every provider serving it
model_rows() {
  printf '%s\n' "$MODEL_TABLE" | awk -F'|' -v m="$1" '$2 == m { print $1 "|" $3 "|" $4 "|" $5 "|" $6 }'
}

# resolve_window <provider|"-"> <model> -> WINDOW_TOKENS WINDOW_DISPLAY WINDOW_MAXOUT
#   WINDOW_MAXOUT_DISPLAY WINDOW_ERROR
resolve_window() {
  local provider=$1 model=$2 rows count rest
  [ "$provider" != "-" ] || provider=
  WINDOW_TOKENS=
  WINDOW_DISPLAY=
  WINDOW_MAXOUT=
  WINDOW_MAXOUT_DISPLAY=
  WINDOW_ERROR=
  if [ -n "$provider" ]; then
    if ! rows=$(window_row "$provider" "$model"); then
      rows=
      case "$model" in
        */*)
          # Both a bare pi model id and a "provider/id" spec appear in firstmate
          # configuration, so retry the split form before concluding anything.
          if split=$(window_row "${model%%/*}" "${model#*/}"); then
            provider=${model%%/*}
            rows=$split
          fi
          ;;
      esac
    fi
    if [ -z "$rows" ]; then
      if [ -n "$(provider_rows "$provider")" ]; then
        WINDOW_ERROR="model-not-in-pi-model-list"
      else
        WINDOW_ERROR="model-list-missing-provider"
      fi
      return 1
    fi
    WINDOW_TOKENS=${rows%%|*}
    rest=${rows#*|}
    WINDOW_DISPLAY=${rest%%|*}
    rest=${rest#*|}
    WINDOW_MAXOUT=${rest%%|*}
    WINDOW_MAXOUT_DISPLAY=${rest#*|}
    return 0
  fi
  rows=$(model_rows "$model")
  count=$(printf '%s\n' "$rows" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    WINDOW_ERROR="model-not-in-pi-model-list"
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    WINDOW_ERROR="model-id-ambiguous"
    return 1
  fi
  WINDOW_TOKENS=$(printf '%s\n' "$rows" | cut -d'|' -f2)
  WINDOW_DISPLAY=$(printf '%s\n' "$rows" | cut -d'|' -f3)
  WINDOW_MAXOUT=$(printf '%s\n' "$rows" | cut -d'|' -f4)
  WINDOW_MAXOUT_DISPLAY=$(printf '%s\n' "$rows" | cut -d'|' -f5)
  return 0
}

# --- settings ---------------------------------------------------------------

GLOBAL_JSON='{}'
PROJECT_JSON='{}'
PROJECT_SETTINGS_PATH=
SETTINGS_ERROR=

# read_json_file <path> -> compact JSON on stdout; absent file yields {}
# An unusable jq (missing, or a stub that prints nothing) must not look like an
# empty settings object, so an existing file whose read yields nothing is an
# error the caller reports by path.
read_json_file() {
  local out
  [ -f "$1" ] || { printf '%s' '{}'; return 0; }
  if ! out=$(jq -c . "$1" 2>/dev/null) || [ -z "$out" ]; then
    return 1
  fi
  printf '%s' "$out"
}

# load_settings_pair <cwd> -> GLOBAL_JSON, PROJECT_JSON, PROJECT_SETTINGS_PATH
load_settings_pair() {
  local cwd=$1
  PROJECT_SETTINGS_PATH="$cwd/$CONFIG_DIR_NAME/settings.json"
  SETTINGS_ERROR=
  if ! GLOBAL_JSON=$(read_json_file "$GLOBAL_SETTINGS"); then
    SETTINGS_ERROR="unreadable-json:$GLOBAL_SETTINGS"
    return 1
  fi
  if ! PROJECT_JSON=$(read_json_file "$PROJECT_SETTINGS_PATH"); then
    SETTINGS_ERROR="unreadable-json:$PROJECT_SETTINGS_PATH"
    return 1
  fi
  return 0
}

# resolve_settings_model <cwd> -> MODEL_PROVIDER MODEL_ID MODEL_SOURCE
# The project file wins when it names a model; otherwise the global file does.
# The provider falls back independently, exactly as pi merges the two objects.
resolve_settings_model() {
  local cwd=$1
  MODEL_PROVIDER=$(printf '%s' "$PROJECT_JSON" | jq -r '.defaultProvider // empty')
  MODEL_ID=$(printf '%s' "$PROJECT_JSON" | jq -r '.defaultModel // empty')
  if [ -n "$MODEL_ID" ]; then
    MODEL_SOURCE="$cwd/$CONFIG_DIR_NAME/settings.json"
  else
    MODEL_ID=$(printf '%s' "$GLOBAL_JSON" | jq -r '.defaultModel // empty')
    MODEL_SOURCE="$GLOBAL_SETTINGS"
  fi
  [ -n "$MODEL_PROVIDER" ] || MODEL_PROVIDER=$(printf '%s' "$GLOBAL_JSON" | jq -r '.defaultProvider // empty')
}

# effective_reserve -> RESERVE RESERVE_SOURCE RESERVE_ERROR
# Effective reserveTokens for the cwd whose settings are loaded: the project
# value when that file sets it, else the global value, else pi's built-in default.
effective_reserve() {
  local has_project has_global value
  RESERVE=
  RESERVE_SOURCE=
  RESERVE_ERROR=
  has_project=$(printf '%s' "$PROJECT_JSON" | jq -r \
    'if (.compaction? | type) == "object" then (.compaction | has("reserveTokens")) else false end')
  has_global=$(printf '%s' "$GLOBAL_JSON" | jq -r \
    'if (.compaction? | type) == "object" then (.compaction | has("reserveTokens")) else false end')
  if [ "$has_project" = true ]; then
    value=$(printf '%s' "$PROJECT_JSON" | jq -r '.compaction.reserveTokens')
    RESERVE_SOURCE=$PROJECT_SETTINGS_PATH
  elif [ "$has_global" = true ]; then
    value=$(printf '%s' "$GLOBAL_JSON" | jq -r '.compaction.reserveTokens')
    RESERVE_SOURCE=$GLOBAL_SETTINGS
  else
    value=$PI_DEFAULT_RESERVE_TOKENS
    RESERVE_SOURCE="builtin-pi-default"
  fi
  case "$value" in
    ''|*[!0-9]*)
      RESERVE_ERROR="reserveTokens-is-not-a-non-negative-integer"
      return 1
      ;;
  esac
  RESERVE=$value
  return 0
}

# effective_enabled -> ENABLED ENABLED_ERROR
# Effective compaction.enabled for the cwd whose settings are loaded: the project
# value when that file sets it, else the global value, else pi's built-in default.
# Same project-over-global precedence as effective_reserve.
effective_enabled() {
  local has_project has_global value
  ENABLED=
  ENABLED_ERROR=
  has_project=$(printf '%s' "$PROJECT_JSON" | jq -r \
    'if (.compaction? | type) == "object" then (.compaction | has("enabled")) else false end')
  has_global=$(printf '%s' "$GLOBAL_JSON" | jq -r \
    'if (.compaction? | type) == "object" then (.compaction | has("enabled")) else false end')
  if [ "$has_project" = true ]; then
    value=$(printf '%s' "$PROJECT_JSON" | jq -r '.compaction.enabled')
  elif [ "$has_global" = true ]; then
    value=$(printf '%s' "$GLOBAL_JSON" | jq -r '.compaction.enabled')
  else
    value=$PI_DEFAULT_COMPACTION_ENABLED
  fi
  case "$value" in
    true | false) ENABLED=$value ;;
    *)
      ENABLED_ERROR="compaction-enabled-is-not-a-boolean"
      return 1
      ;;
  esac
  return 0
}

# resolve_thinking_level -> THINKING_LEVEL THINKING_SOURCE THINKING_CONFLICT
#
# The effective defaultThinkingLevel for the loaded settings pair: the project
# value when the file sets it, else the global value, else `unset` (pi's own
# built-in default, which firstmate does not own and cannot name). The value and
# its source are reported on every scope line so a lane's reasoning budget is
# explicit rather than silently inherited.
#
# THINKING_CONFLICT is non-empty when BOTH files set the key to different
# values: two sources for one lane's reasoning budget is exactly the unexplained
# per-home override this check exists to surface. It does not change the value -
# choosing the single source is the captain's call - it only makes the
# disagreement loud.
resolve_thinking_level() {
  local has_project has_global global_value
  THINKING_LEVEL=
  THINKING_SOURCE=
  THINKING_CONFLICT=
  has_project=$(printf '%s' "$PROJECT_JSON" | jq -r 'if has("defaultThinkingLevel") then true else false end' 2>/dev/null || printf 'false')
  has_global=$(printf '%s' "$GLOBAL_JSON" | jq -r 'if has("defaultThinkingLevel") then true else false end' 2>/dev/null || printf 'false')
  if [ "$has_project" = true ]; then
    THINKING_LEVEL=$(printf '%s' "$PROJECT_JSON" | jq -r '.defaultThinkingLevel // empty' 2>/dev/null || true)
    THINKING_SOURCE=$PROJECT_SETTINGS_PATH
  fi
  if [ "$has_global" = true ]; then
    global_value=$(printf '%s' "$GLOBAL_JSON" | jq -r '.defaultThinkingLevel // empty' 2>/dev/null || true)
    if [ -z "$THINKING_LEVEL" ]; then
      THINKING_LEVEL=$global_value
      THINKING_SOURCE=$GLOBAL_SETTINGS
    fi
    if [ "$has_project" = true ] && [ "$THINKING_LEVEL" != "$global_value" ]; then
      THINKING_CONFLICT="project=$THINKING_LEVEL global=$global_value"
    fi
  fi
  if [ -z "$THINKING_LEVEL" ]; then
    THINKING_LEVEL='unset'
    THINKING_SOURCE=builtin-pi-default
  fi
}

# --- scope table ------------------------------------------------------------

# Every scope is collected before any window is resolved, so an incomplete model
# list can be retried across the whole set instead of being concluded per scope.
# Fields, tab separated and always non-empty ("-" is the placeholder):
#   name cwd provider model model_source reserve reserve_source error_reason
#   reserve_error window_tokens window_display window_error
SCOPE_TABLE=

add_scope_record() {
  local rec
  rec=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}")
  SCOPE_TABLE="${SCOPE_TABLE}${rec}"$'\n'
}

# add_scope_from_settings <name> <cwd>
add_scope_from_settings() {
  local name=$1 cwd=$2 provider=- model=- model_source=- reserve=- reserve_source=- error_reason=-
  if ! load_settings_pair "$cwd"; then
    add_scope_record "$name" "$cwd" - - "$SETTINGS_ERROR" - - "$SETTINGS_ERROR" - - - -
    return 0
  fi
  resolve_settings_model "$cwd"
  provider=${MODEL_PROVIDER:--}
  [ "$provider" != "" ] || provider=-
  model=${MODEL_ID:--}
  [ "$model" != "" ] || model=-
  model_source=${MODEL_SOURCE:--}
  if [ "$model" = "-" ]; then
    error_reason="no-model-configured"
  fi
  # Resolve enabled before the reserve: a scope pi will never compact must not be
  # judged by a reserve pi ignores. A disabled scope is recorded as skipped.
  if [ "$error_reason" = - ]; then
    if effective_enabled; then
      if [ "$ENABLED" = false ]; then
        error_reason="compaction-disabled"
      fi
    else
      error_reason=$ENABLED_ERROR
    fi
  fi
  if [ "$error_reason" = - ]; then
    if effective_reserve; then
      reserve=$RESERVE
      reserve_source=$RESERVE_SOURCE
    else
      reserve_source=${RESERVE_SOURCE:--}
      reserve_source=${reserve_source:--}
      error_reason=$RESERVE_ERROR
    fi
  fi
  add_scope_record "$name" "$cwd" "$provider" "$model" "$model_source" \
    "$reserve" "$reserve_source" "$error_reason" - - - -
}

# add_scope_from_pin <id> <home>: a secondmate's model comes from the shared
# config/secondmate-harness pin, whose model the launch passes as --model.
add_scope_from_pin() {
  local id=$1 home=$2 name line=- harness=- sm_model=- provider=-
  local model=- model_source=- error_reason=- reserve=- reserve_source=-
  name="secondmate-$id"
  if [ -z "$home" ] || [ ! -d "$home" ]; then
    add_scope_record "$name" "${home:--}" - - - - - registry-home-missing - - - -
    return 0
  fi
  if ! load_settings_pair "$home"; then
    add_scope_record "$name" "$home" - - "$SETTINGS_ERROR" - - "$SETTINGS_ERROR" - - - -
    return 0
  fi
  if [ -f "$HARNESS_FILE" ]; then
    line=$(awk 'NF && $1 !~ /^#/ { print; exit }' "$HARNESS_FILE")
  fi
  if [ -n "$line" ]; then
    read -r harness sm_model _rest <<<"$line" || true
  fi
  if [ -n "$line" ] && [ "$harness" != pi ]; then
    add_scope_record "$name" "$home" - - "$HARNESS_FILE" - - harness-not-pi - - - -
    return 0
  fi
  if [ -n "${sm_model:-}" ]; then
    provider=$(printf '%s' "$PROJECT_JSON" | jq -r '.defaultProvider // empty')
    [ -n "$provider" ] || provider=$(printf '%s' "$GLOBAL_JSON" | jq -r '.defaultProvider // empty')
    model=$sm_model
    model_source=$HARNESS_FILE
  else
    # No model in the pin: the home's merged settings supply the starting model.
    resolve_settings_model "$home"
    provider=${MODEL_PROVIDER:--}
    model=${MODEL_ID:--}
    model_source=${MODEL_SOURCE:--}
    if [ "$model" = - ]; then
      error_reason="no-model-configured"
    fi
  fi
  if [ "$error_reason" = - ]; then
    if effective_enabled; then
      if [ "$ENABLED" = false ]; then
        error_reason="compaction-disabled"
      fi
    else
      error_reason=$ENABLED_ERROR
    fi
  fi
  if [ "$error_reason" = - ]; then
    if effective_reserve; then
      reserve=$RESERVE
      reserve_source=$RESERVE_SOURCE
    else
      reserve_source=${RESERVE_SOURCE:--}
      reserve_source=${reserve_source:--}
      error_reason=$RESERVE_ERROR
    fi
  fi
  add_scope_record "$name" "$home" "${provider:--}" "$model" "$model_source" \
    "$reserve" "$reserve_source" "$error_reason" - - - -
}

# --- resolution passes ------------------------------------------------------

# Resolve the reserve for every scope that has not been resolved yet, and fold
# any window already found on an earlier attempt through unchanged.
resolve_scopes() {
  local new_table='' rec
  local name cwd provider model model_source reserve reserve_source error_reason
  local reserve_error w_tokens w_display w_error
  while IFS=$'\t' read -r name cwd provider model model_source reserve reserve_source \
    error_reason reserve_error w_tokens w_display w_error; do
    [ -n "$name" ] || continue
    if [ "$error_reason" = - ] && [ "$w_tokens" = - ]; then
      # Not resolved yet, or resolved only against an incomplete attempt: try
      # again against everything the model list has yielded so far.
      resolve_window "$provider" "$model" || true
      if [ -n "$WINDOW_TOKENS" ]; then
        w_tokens=$WINDOW_TOKENS
        w_display=$WINDOW_DISPLAY
        w_error=-
      else
        w_tokens=-
        w_display=-
        w_error=$WINDOW_ERROR
      fi
    fi
    rec=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$name" "$cwd" "$provider" "$model" "$model_source" "$reserve" "$reserve_source" \
      "$error_reason" "$reserve_error" "$w_tokens" "$w_display" "$w_error")
    new_table="${new_table}${rec}"$'\n'
  done < <(printf '%s' "$SCOPE_TABLE")
  SCOPE_TABLE=$new_table
}

# Scopes still withholding a verdict because the model list did not cover them.
count_unresolved_scopes() {
  local count=0 rec
  local name cwd provider model model_source reserve reserve_source error_reason
  local reserve_error w_tokens w_display w_error
  while IFS=$'\t' read -r name cwd provider model model_source reserve reserve_source \
    error_reason reserve_error w_tokens w_display w_error; do
    [ -n "$name" ] || continue
    if [ "$error_reason" = - ] && [ "$w_error" != - ]; then
      count=$((count + 1))
    fi
  done < <(printf '%s' "$SCOPE_TABLE")
  printf '%s' "$count"
}

# trigger_percent <window-tokens> <reserve-tokens>
trigger_percent() {
  awk -v w="$1" -v r="$2" 'BEGIN { printf "%.1f", (w - r) / w * 100 }'
}

# Emit one line for every collected scope.
emit_scopes() {
  local rec
  local name cwd provider model model_source reserve reserve_source error_reason
  local reserve_error w_tokens w_display w_error model_display percent verdict reason detail
  local maxout maxout_display
  while IFS=$'\t' read -r name cwd provider model model_source reserve reserve_source \
    error_reason reserve_error w_tokens w_display w_error; do
    [ -n "$name" ] || continue
    if [ "$provider" = - ]; then
      model_display=$model
    else
      model_display="$provider/$model"
    fi
    # Resolve the effective reasoning level and the model's output ceiling for
    # this scope. Both are reported on every line so an inherited budget is
    # visible rather than silent, and the output ceiling is judged below.
    load_settings_pair "$cwd" >/dev/null 2>&1 || true
    resolve_thinking_level
    maxout=
    maxout_display=
    if [ "$model" != - ]; then
      if resolve_window "$provider" "$model"; then
        maxout=$WINDOW_MAXOUT
        maxout_display=$WINDOW_MAXOUT_DISPLAY
      fi
    fi
    if [ "$error_reason" = harness-not-pi ]; then
      print_line skipped "$name" "$cwd" - - - "$model_source" harness-not-pi "" "$THINKING_LEVEL" "$THINKING_SOURCE"
      continue
    fi
    if [ "$error_reason" = compaction-disabled ]; then
      print_line skipped "$name" "$cwd" "$model_display" - - "$model_source" compaction-disabled "" "$THINKING_LEVEL" "$THINKING_SOURCE"
      continue
    fi
    if [ "$error_reason" != - ]; then
      print_line error "$name" "$cwd" "$model_display" - - "$model_source" "$error_reason" "" "$THINKING_LEVEL" "$THINKING_SOURCE"
      continue
    fi
    if [ "$w_error" != - ]; then
      print_line error "$name" "$cwd" "$model_display" - - "$model_source" "$w_error" "" "$THINKING_LEVEL" "$THINKING_SOURCE"
      continue
    fi
    if [ "$reserve_error" != - ]; then
      print_line error "$name" "$cwd" "$model_display" "$w_display" - "$reserve_source" "$reserve_error" "" "$THINKING_LEVEL" "$THINKING_SOURCE"
      continue
    fi
    percent=$(trigger_percent "$w_tokens" "$reserve")
    verdict=ok
    reason=
    detail="trigger=$percent% limit=$MAX_TRIGGER_PERCENT%"
    if [ "$reserve" -ge "$w_tokens" ]; then
      verdict=unsafe
      reason="reserve-not-below-window"
    elif awk -v p="$percent" -v m="$MAX_TRIGGER_PERCENT" 'BEGIN { exit !(p > m) }'; then
      verdict=unsafe
      reason="trigger-above-limit"
    elif [ -n "$THINKING_CONFLICT" ]; then
      # Two files set the reasoning level to different values: the effective
      # value is real, but its single owner is not. Report it and leave the
      # choice to the captain.
      verdict=unsafe
      reason="thinking-level-dual-source"
      detail="$THINKING_CONFLICT"
    elif [ -n "$maxout" ] && [ "$maxout" -gt 0 ] && [ "$maxout" -lt "$MIN_OUTPUT_TOKENS" ]; then
      # The model's output ceiling is below the local-model floor, so a full
      # answer cannot coexist with the compaction summary allowance.
      verdict=unsafe
      reason="output-budget-below-ceiling"
      detail="output=${maxout_display:-$maxout} ceiling=$MIN_OUTPUT_TOKENS"
    elif [ -n "$maxout" ] && [ "$maxout" -gt 0 ] && [ "$maxout" -gt "$reserve" ]; then
      # The answer budget exceeds the reserve the compaction trigger holds
      # back, so the reserve cannot actually hold a full answer.
      verdict=unsafe
      reason="output-budget-exceeds-reserve"
      detail="output=$maxout reserve=$reserve"
    fi
    print_line "$verdict" "$name" "$cwd" "$model_display" "$w_display" "$reserve" \
      "$reserve_source" "$reason" "$detail" "$THINKING_LEVEL" "$THINKING_SOURCE"
  done < <(printf '%s' "$SCOPE_TABLE")
}

# --- run --------------------------------------------------------------------

# 1. Collect every scope, with its reserve, without touching the model list.
if [ -d "$PRIMARY_HOME" ]; then
  add_scope_from_settings primary "$PRIMARY_HOME"
else
  add_scope_record primary "$PRIMARY_HOME" - - - - - primary-home-missing - - - -
fi

# The global scope is the pairing a session in a cwd with no project settings
# receives; it is the only row that reports the global file's own reserve.
PROJECT_JSON='{}'
PROJECT_SETTINGS_PATH=
if ! GLOBAL_JSON=$(read_json_file "$GLOBAL_SETTINGS"); then
  add_scope_record global-scope - - - "$GLOBAL_SETTINGS" - - unreadable-json - - - -
else
  global_provider=$(printf '%s' "$GLOBAL_JSON" | jq -r '.defaultProvider // empty')
  global_model=$(printf '%s' "$GLOBAL_JSON" | jq -r '.defaultModel // empty')
  if [ -z "$global_model" ]; then
    add_scope_record global-scope - "${global_provider:--}" - "$GLOBAL_SETTINGS" - - no-model-configured - - - -
  elif ! effective_enabled; then
    add_scope_record global-scope - "${global_provider:--}" "$global_model" \
      "$GLOBAL_SETTINGS" - - "$ENABLED_ERROR" - - - -
  elif [ "$ENABLED" = false ]; then
    add_scope_record global-scope - "${global_provider:--}" "$global_model" \
      "$GLOBAL_SETTINGS" - - compaction-disabled - - - -
  else
    reserve=$PI_DEFAULT_RESERVE_TOKENS
    reserve_source="builtin-pi-default"
    has_global=$(printf '%s' "$GLOBAL_JSON" | jq -r \
      'if (.compaction? | type) == "object" then (.compaction | has("reserveTokens")) else false end')
    if [ "$has_global" = true ]; then
      reserve=$(printf '%s' "$GLOBAL_JSON" | jq -r '.compaction.reserveTokens')
      reserve_source=$GLOBAL_SETTINGS
      case "$reserve" in
        ''|*[!0-9]*) add_scope_record global-scope - "${global_provider:--}" "$global_model" \
          "$GLOBAL_SETTINGS" - "$reserve_source" reserveTokens-is-not-a-non-negative-integer - - - - ;;
        *) add_scope_record global-scope - "${global_provider:--}" "$global_model" \
          "$GLOBAL_SETTINGS" "$reserve" "$reserve_source" - - - - - ;;
      esac
    else
      add_scope_record global-scope - "${global_provider:--}" "$global_model" \
        "$GLOBAL_SETTINGS" "$reserve" "$reserve_source" - - - - -
    fi
  fi
fi

if [ -f "$SECONDMATES_FILE" ]; then
  while IFS='|' read -r sm_id sm_home; do
    [ -n "$sm_id" ] || continue
    add_scope_from_pin "$sm_id" "$sm_home"
  done < <(awk '
    /^- / {
      id = $2
      if (match($0, /\(home: [^;)]+/)) {
        home = substr($0, RSTART + 7, RLENGTH - 7)
        gsub(/^[ \t]+|[ \t]+$/, "", home)
        printf "%s|%s\n", id, home
      }
    }
  ' "$SECONDMATES_FILE")
fi

# 2. Read the model list, re-reading only while a scope is still unresolved.
#    A partial list from a successful read is the reason this loops.
attempt=1
while :; do
  if one_model_read; then
    MODEL_TABLE_READY=1
    MODELS_UNAVAILABLE_REASON=
  else
    MODELS_UNAVAILABLE_REASON=$MODELS_ATTEMPT_ERROR
  fi
  build_model_table
  resolve_scopes
  [ "$(count_unresolved_scopes)" -gt 0 ] || break
  [ "$attempt" -lt "$MODELS_ATTEMPTS" ] || break
  attempt=$((attempt + 1))
done

# 3. Emit. With no usable list at all the whole check is unjudgeable, so that
#    case is one bounded line rather than one line per scope.
if [ "$MODEL_TABLE_READY" -eq 0 ]; then
  case "$MODELS_UNAVAILABLE_REASON" in
    pi-not-installed|model-list-empty)
      # An empty model list is a legitimate state on a host with no configured
      # providers (or a pi install that has not been pointed at a provider yet).
      # Reporting it as `error` is a false alarm: the check simply cannot
      # resolve a model, which is the same situation as pi-not-installed.
      print_line skipped all - - - - "${MODELS_CMD%% *}" "$MODELS_UNAVAILABLE_REASON"
      exit 0
      ;;
  esac
  print_line error all - - - - "$MODELS_CMD" "$MODELS_UNAVAILABLE_REASON"
  exit 2
fi

emit_scopes

exit "$VERDICT_WORST"
