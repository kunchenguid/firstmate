#!/usr/bin/env bash
# Durable ownership of the authority under which a task's merge was accepted.
#
# The away-posture record (state/.afk-contract) and the task's recorded yolo
# posture are resolved only at the merge gate. After a forge accepts the merge,
# bin/fm-pr-merge.sh persists that answer as:
#   state/<task-id>.merge-authority
#   fm-merge-authority-v1
#   <provider>
#   <host>
#   <path>
#   <number>
#   <authority>                 yolo | away-grant | attended
# The identity is the canonical identity parsed from the task's pr= metadata.
# The file is atomically published, mode 0600, single-link, and on the state
# filesystem. A poll consumes it only when all identity fields match its own
# validated snapshot. Missing, malformed, or mismatched state means external;
# it is never resolved again from a later away-posture record.
#
# Resolution authorizes nothing by itself. bin/fm-pr-merge.sh owns the merge
# gate and persists only after a forge command succeeds. bin/fm-watch.sh reads
# the record only after the poll has observed a landed merge, then retires it
# after durable outcome publication. Teardown removes any remaining record.
#
# Sourced by those scripts and by tests. No side effects on source beyond its
# sourced libraries.

_FM_MERGE_AUTHORITY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_MERGE_AUTHORITY_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$_FM_MERGE_AUTHORITY_LIB_DIR/fm-afk-contract.sh"

# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_AUTHORITY=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_AUTHORITY_REASON=

fm_merge_authority_resolve() {  # <home> <state> <meta> <task-id>
  local home=${1-} state=${2-} meta=${3-} id=${4-}
  local yolo='' grants grant
  FM_MERGE_AUTHORITY=
  FM_MERGE_AUTHORITY_REASON='invalid'
  [ -n "$home" ] && [ -n "$state" ] && [ -n "$meta" ] && [ -n "$id" ] || return 1

  if ! fm_afk_contract_present "$state"; then
    FM_MERGE_AUTHORITY='attended'
    FM_MERGE_AUTHORITY_REASON='attended'
    return 0
  fi
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    "$_FM_MERGE_AUTHORITY_LIB_DIR/fm-afk-contract.sh" validate >/dev/null 2>&1; then
    FM_MERGE_AUTHORITY_REASON='record-unreadable'
    return 1
  fi
  if [ -f "$meta" ]; then
    yolo=$(grep '^yolo=' "$meta" | tail -1 | cut -d= -f2- || true)
  fi
  if [ "$yolo" = on ]; then
    FM_MERGE_AUTHORITY='yolo'
    FM_MERGE_AUTHORITY_REASON='granted'
    return 0
  fi
  grants=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    "$_FM_MERGE_AUTHORITY_LIB_DIR/fm-afk-contract.sh" grants 2>/dev/null) || {
    FM_MERGE_AUTHORITY_REASON='grants-unreadable'
    return 1
  }
  while IFS= read -r grant; do
    [ "$grant" = "$id" ] || continue
    FM_MERGE_AUTHORITY='away-grant'
    FM_MERGE_AUTHORITY_REASON='granted'
    return 0
  done <<EOF
$grants
EOF
  FM_MERGE_AUTHORITY_REASON='not-granted'
  return 1
}

fm_merge_authority_record_matches() {  # <record> <device> <provider> <host> <path> <number>
  local record=$1 device=$2 expected_provider=$3 expected_host=$4 expected_path=$5 expected_number=$6
  local version provider host path number authority
  fm_pr_private_file_valid "$record" 600 "$device" || return 1
  exec 8< "$record" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  IFS= read -r authority <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  case "$authority" in yolo|away-grant|attended) ;; *) return 1 ;; esac
  [ "$version" = fm-merge-authority-v1 ] \
    && [ "$provider" = "$expected_provider" ] \
    && [ "$host" = "$expected_host" ] \
    && [ "$path" = "$expected_path" ] \
    && [ "$number" = "$expected_number" ] || return 1
  FM_MERGE_AUTHORITY=$authority
}

fm_merge_authority_persist() {  # <state> <task-id> <meta> <authority>
  local state=$1 id=$2 meta=$3 authority=$4 record tmp state_device
  fm_pr_task_id_valid "$id" || return 1
  case "$authority" in yolo|away-grant|attended) ;; *) return 1 ;; esac
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_metadata_identity_parse "$meta" || return 1
  record="$state/$id.merge-authority"
  fm_pr_regular_destination_on_device_or_absent "$record" "$state_device" || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-merge-authority.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-merge-authority-v1 "$FM_PR_META_PROVIDER" "$FM_PR_META_HOST" \
      "$FM_PR_META_PATH" "$FM_PR_META_NUMBER" "$authority" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_merge_authority_record_matches "$tmp" "$state_device" \
      "$FM_PR_META_PROVIDER" "$FM_PR_META_HOST" "$FM_PR_META_PATH" "$FM_PR_META_NUMBER" \
    || ! fm_pr_regular_destination_on_device_or_absent "$record" "$state_device" \
    || ! mv -f -- "$tmp" "$record" \
    || ! fm_merge_authority_record_matches "$record" "$state_device" \
      "$FM_PR_META_PROVIDER" "$FM_PR_META_HOST" "$FM_PR_META_PATH" "$FM_PR_META_NUMBER"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_merge_authority_read() {  # <state> <task-id> <provider> <host> <path> <number>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 record state_device
  FM_MERGE_AUTHORITY='external'
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  record="$state/$id.merge-authority"
  fm_merge_authority_record_matches "$record" "$state_device" \
    "$provider" "$host" "$path" "$number"
}

fm_merge_authority_remove() {  # <state> <task-id>
  local state=$1 id=$2 record state_device
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  record="$state/$id.merge-authority"
  [ -e "$record" ] || [ -L "$record" ] || return 0
  fm_pr_private_file_valid "$record" 600 "$state_device" || return 1
  rm -f -- "$record"
}
