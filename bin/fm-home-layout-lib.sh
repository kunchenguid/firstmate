#!/usr/bin/env bash
# Canonical absent-is-default paths in a Firstmate operational home.

_FM_HOME_LAYOUT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_HOME_LAYOUT_LIB_DIR="."
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$_FM_HOME_LAYOUT_LIB_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$_FM_HOME_LAYOUT_LIB_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_HOME_LAYOUT_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$_FM_HOME_LAYOUT_LIB_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-slack-lib.sh
. "$_FM_HOME_LAYOUT_LIB_DIR/fm-slack-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$_FM_HOME_LAYOUT_LIB_DIR/fm-pending-reply-lib.sh"

fm_home_layout_kind() {
  local home=$1
  if fm_root_is_secondmate_home "$home"; then
    printf 'secondmate\n'
  else
    printf 'primary\n'
  fi
}

fm_home_markdown_link_payload() {
  local input=$1 char i depth=1 escaped=0 payload=
  FM_HOME_MARKDOWN_LINK_PAYLOAD=
  FM_HOME_MARKDOWN_LINK_REST=
  for ((i = 0; i < ${#input}; i++)); do
    char=${input:i:1}
    if [ "$escaped" -eq 1 ]; then
      payload=$payload$char
      escaped=0
      continue
    fi
    case "$char" in
      \\)
        payload=$payload$char
        escaped=1
        ;;
      '(')
        payload=$payload$char
        depth=$((depth + 1))
        ;;
      ')')
        depth=$((depth - 1))
        if [ "$depth" -eq 0 ]; then
          FM_HOME_MARKDOWN_LINK_PAYLOAD=$payload
          FM_HOME_MARKDOWN_LINK_REST=${input:i+1}
          return 0
        fi
        payload=$payload$char
        ;;
      *) payload=$payload$char ;;
    esac
  done
  return 1
}

fm_home_markdown_link_destination() {
  local payload=$1 destination='' char next i normalized='' escaped=0 closed=0
  case "$payload" in
    \<*)
      for ((i = 1; i < ${#payload}; i++)); do
        char=${payload:i:1}
        if [ "$escaped" -eq 1 ]; then
          destination=$destination$char
          escaped=0
          continue
        fi
        case "$char" in
          \\)
            destination=$destination$char
            escaped=1
            ;;
          \>)
            closed=1
            break
            ;;
          *) destination=$destination$char ;;
        esac
      done
      [ "$closed" -eq 1 ] || return 1
      ;;
    *) destination=${payload%%[[:space:]]*} ;;
  esac
  for ((i = 0; i < ${#destination}; i++)); do
    char=${destination:i:1}
    if [ "$char" = \\ ] && [ "$i" -lt $((${#destination} - 1)) ]; then
      next=${destination:i+1:1}
      case "$next" in
        '('|')'|'<'|'>')
          normalized=$normalized$next
          i=$((i + 1))
          continue
          ;;
      esac
    fi
    normalized=$normalized$char
  done
  [ -n "$normalized" ] || return 1
  printf '%s' "$normalized"
}

fm_home_pointer_declares_primary_only() {
  local before=$1 after=$2 before_lower after_lower marker
  before_lower=$(printf '%s' "$before" | tr '[:upper:]' '[:lower:]')
  after_lower=$(printf '%s' "$after" | tr '[:upper:]' '[:lower:]')
  for marker in \
    'primary home owns ' 'primary home contains ' 'primary home keeps ' \
    'primary home only: ' 'primary home only ' 'primary-home-only: ' \
    'primary-home-only '
  do
    case "$before_lower" in
      *' in the primary home only: '*|*' in primary home only: '*|\
      *' is primary-home-only: '*)
        continue
        ;;
    esac
    [ "${before_lower: -${#marker}}" = "$marker" ] && return 0
  done
  for marker in \
    ' in the primary home only' ' is in the primary home only' \
    ' in primary home only' ' is primary-home-only' \
    ' (primary-home-only)' ' (primary home only)'
  do
    [ "${after_lower:0:${#marker}}" = "$marker" ] && return 0
  done
  return 1
}

FM_HOME_PRIMARY_ONLY_POINTER_DATA=
FM_HOME_PRIMARY_ONLY_POINTER_PATHS=

fm_home_primary_only_pointer_paths() {
  local data=$1
  local shared=$data/captain-shared.md line rest before after tok normalized
  [ -f "$shared" ] && [ ! -L "$shared" ] && [ -r "$shared" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    rest=$line
    while [[ "$rest" == *'`'* ]]; do
      before=${rest%%\`*}
      rest=${rest#*\`}
      [[ "$rest" == *'`'* ]] || break
      tok=${rest%%\`*}
      rest=${rest#*\`}
      after=$rest
      fm_home_pointer_declares_primary_only "$before" "$after" || continue
      normalized=$tok
      case "$normalized" in
        data/*|config/*|state/*|bin/*|docs/*)
          printf '%s\n' "$normalized"
          ;;
      esac
    done
    rest=$line
    while [[ "$rest" == *']('* ]]; do
      before=${rest%%']('*}
      rest=${rest#*](}
      fm_home_markdown_link_payload "$rest" || break
      tok=$FM_HOME_MARKDOWN_LINK_PAYLOAD
      rest=$FM_HOME_MARKDOWN_LINK_REST
      after=$rest
      fm_home_pointer_declares_primary_only "$before" "$after" || continue
      normalized=$(fm_home_markdown_link_destination "$tok") || continue
      normalized=${normalized%%[\?#]*}
      case "$normalized" in
        data/*|config/*|state/*|bin/*|docs/*)
          printf '%s\n' "$normalized"
          ;;
      esac
    done
  done < "$shared"
  return 0
}

fm_home_primary_only_pointer_declared() {
  local data=$1 path=$2 declared
  if [ "$FM_HOME_PRIMARY_ONLY_POINTER_DATA" != "$data" ]; then
    FM_HOME_PRIMARY_ONLY_POINTER_DATA=$data
    FM_HOME_PRIMARY_ONLY_POINTER_PATHS=
    FM_HOME_PRIMARY_ONLY_POINTER_PATHS=$(fm_home_primary_only_pointer_paths "$data" 2>/dev/null || true)
  fi
  while IFS= read -r declared; do
    [ "$declared" = "$path" ] && return 0
  done <<< "$FM_HOME_PRIMARY_ONLY_POINTER_PATHS"
  return 1
}

fm_home_path_absence_status() {
  local home_kind=$1 home=$2 path=$3 state=${4:-$2/state} config=${5:-$2/config} data=${6:-$2/data} status marker_home_kind
  if status=$(fmx_home_path_absence_status "$home" "$path"); then
    printf '%s\n' "$status"
    return 0
  fi
  if status=$(fm_pf_home_path_absence_status "$home" "$path"); then
    printf '%s\n' "$status"
    return 0
  fi
  if status=$(fm_procevent_home_path_absence_status "$home" "$state" "$path"); then
    printf '%s\n' "$status"
    return 0
  fi
  if status=$(fms_home_path_absence_status "$home" "$state" "$config" "$path"); then
    printf '%s\n' "$status"
    return 0
  fi
  if status=$(fm_pending_reply_home_path_absence_status "$state" "$path"); then
    printf '%s\n' "$status"
    return 0
  fi
  marker_home_kind=$(fm_home_layout_kind "$home")
  if [ "$marker_home_kind" = secondmate ] \
    && fm_home_primary_only_pointer_declared "$data" "$path"; then
    printf 'OPTIONAL\n'
    return 0
  fi
  case "$path" in
    data/charter.md)
      if [ "$home_kind" = primary ]; then
        printf 'OPTIONAL\n'
      else
        printf 'REQUIRED\n'
      fi
      return 0
      ;;
    .env|\
    config/crew-harness|config/crew-dispatch.json|config/claude-account-profiles|\
    config/secondmate-harness|config/backlog-backend|config/backend|config/calm|\
    config/herdr-presentation-spaces|config/trace-context|config/cmux-socket-password|\
    config/wedge-alarm|config/x-mode.env|config/slack-captain-channel|\
    config/slack-captain-user|config/slack-captain-cadence|\
    config/slack-captain-comms-lines|config/slack-captain-comms-chars|\
    config/slack-captain.env|config/startup-memory-budget|config/model-catalog.json|\
    config/auto-quota-drain.json|data/backlog.md|data/captain.md|data/learnings.md|\
    data/captain-shared.md|data/model-routing.md|data/projects.md|data/secondmates.md|\
    data/done-archive.md|data/quota-cooldowns.json|\
    data/routing-outcomes.jsonl|data/review-outcomes.jsonl|state/.afk|\
    state/.trace-context-effective)
      printf 'OPTIONAL\n'
      return 0
      ;;
  esac
  printf 'REQUIRED\n'
}
