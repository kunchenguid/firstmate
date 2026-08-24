#!/usr/bin/env bash
# Canonical absent-is-default paths in a Firstmate operational home.

_FM_HOME_LAYOUT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_HOME_LAYOUT_LIB_DIR="."
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

fm_home_path_absence_status() {
  local home_kind=$1 home=$2 path=$3 state=${4:-$2/state} config=${5:-$2/config} status
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
    data/routing-outcomes.jsonl|state/.afk|\
    state/.trace-context-effective)
      printf 'OPTIONAL\n'
      return 0
      ;;
  esac
  printf 'REQUIRED\n'
}
