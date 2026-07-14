#!/usr/bin/env bash
# Shared validation and atomic artifact helpers for GitHub PR merge polling.
# Callers must validate task IDs and raw PR URLs before constructing task paths
# or performing any side effect.

FM_PR_URL=
FM_PR_OWNER=
FM_PR_REPO=
FM_PR_NUMBER=
FM_PR_DATA_URL=
FM_PR_DATA_OWNER=
FM_PR_DATA_REPO=
FM_PR_DATA_NUMBER=
FM_PR_POLL_DATA_TMP=
FM_PR_POLL_CHECK_TMP=
FM_PR_POLL_DATA_DEST=
FM_PR_POLL_CHECK_DEST=
FM_PR_POLL_EXPECT_URL=
FM_PR_POLL_EXPECT_OWNER=
FM_PR_POLL_EXPECT_REPO=
FM_PR_POLL_EXPECT_NUMBER=
FM_PR_POLL_TEMPLATE=
FM_PR_POLL_STATE_DEVICE=

fm_pr_task_id_valid() {
  local id=${1-}
  local LC_ALL=C
  [ "${#id}" -ge 1 ] && [ "${#id}" -le 64 ] || return 1
  [[ "$id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

fm_pr_url_parse() {
  local raw=${1-} pattern
  local LC_ALL=C
  FM_PR_URL=
  FM_PR_OWNER=
  FM_PR_REPO=
  FM_PR_NUMBER=
  pattern='^https://github\.com/([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])/([A-Za-z0-9._-]{1,100})/pull/([1-9][0-9]*)$'
  [[ "$raw" =~ $pattern ]] || return 1
  [[ "${BASH_REMATCH[1]}" != *--* ]] || return 1
  [ "${BASH_REMATCH[2]}" != . ] && [ "${BASH_REMATCH[2]}" != .. ] || return 1
  FM_PR_URL=$raw
  FM_PR_OWNER=${BASH_REMATCH[1]}
  FM_PR_REPO=${BASH_REMATCH[2]}
  FM_PR_NUMBER=${BASH_REMATCH[3]}
}

fm_pr_head_valid() {
  local head=${1-}
  local LC_ALL=C
  [[ "$head" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]]
}

fm_pr_file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

fm_pr_file_device() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %d "$1" 2>/dev/null
  else
    stat -c %d "$1" 2>/dev/null
  fi
}

fm_pr_file_link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_pr_regular_destination_or_absent() {
  local path=$1
  [ ! -L "$path" ] || return 1
  if [ -e "$path" ]; then
    [ -f "$path" ]
  fi
}

fm_pr_regular_destination_on_device_or_absent() {
  local path=$1 device=$2
  fm_pr_regular_destination_or_absent "$path" || return 1
  [ ! -e "$path" ] || [ "$(fm_pr_file_device "$path")" = "$device" ]
}

fm_pr_poll_data_parse() {
  local file=$1 url owner repo number
  FM_PR_DATA_URL=
  FM_PR_DATA_OWNER=
  FM_PR_DATA_REPO=
  FM_PR_DATA_NUMBER=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 8< "$file" || return 1
  IFS= read -r url <&8 || { exec 8<&-; return 1; }
  IFS= read -r owner <&8 || { exec 8<&-; return 1; }
  IFS= read -r repo <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  fm_pr_url_parse "$url" || return 1
  [ "$owner" = "$FM_PR_OWNER" ] || return 1
  [ "$repo" = "$FM_PR_REPO" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  FM_PR_DATA_URL=$FM_PR_URL
  FM_PR_DATA_OWNER=$FM_PR_OWNER
  FM_PR_DATA_REPO=$FM_PR_REPO
  FM_PR_DATA_NUMBER=$FM_PR_NUMBER
}

fm_pr_poll_cleanup() {
  [ -z "$FM_PR_POLL_DATA_TMP" ] || rm -f -- "$FM_PR_POLL_DATA_TMP"
  [ -z "$FM_PR_POLL_CHECK_TMP" ] || rm -f -- "$FM_PR_POLL_CHECK_TMP"
  FM_PR_POLL_DATA_TMP=
  FM_PR_POLL_CHECK_TMP=
}

fm_pr_poll_revoke_final() {
  local failed=0
  # Neutralize the runnable name first so a failed rearm cannot consume a
  # sidecar whose publication did not commit successfully.
  if [ -e "$FM_PR_POLL_CHECK_DEST" ] || [ -L "$FM_PR_POLL_CHECK_DEST" ]; then
    rm -f -- "$FM_PR_POLL_CHECK_DEST" || failed=1
  fi
  if [ -e "$FM_PR_POLL_DATA_DEST" ] || [ -L "$FM_PR_POLL_DATA_DEST" ]; then
    rm -f -- "$FM_PR_POLL_DATA_DEST" || failed=1
  fi
  [ ! -e "$FM_PR_POLL_CHECK_DEST" ] && [ ! -L "$FM_PR_POLL_CHECK_DEST" ] || failed=1
  [ ! -e "$FM_PR_POLL_DATA_DEST" ] && [ ! -L "$FM_PR_POLL_DATA_DEST" ] || failed=1
  return "$failed"
}

fm_pr_poll_prepare() {
  local state=$1 id=$2 url=$3 owner=$4 repo=$5 number=$6 template=$7
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$owner" = "$FM_PR_OWNER" ] || return 1
  [ "$repo" = "$FM_PR_REPO" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  [ -f "$template" ] || return 1

  [ ! -L "$state" ] || return 1
  mkdir -p "$state" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  umask 077
  FM_PR_POLL_DATA_DEST="$state/$id.pr-poll"
  FM_PR_POLL_CHECK_DEST="$state/$id.check.sh"
  FM_PR_POLL_EXPECT_URL=$url
  FM_PR_POLL_EXPECT_OWNER=$owner
  FM_PR_POLL_EXPECT_REPO=$repo
  FM_PR_POLL_EXPECT_NUMBER=$number
  FM_PR_POLL_TEMPLATE=$template
  FM_PR_POLL_STATE_DEVICE=$(fm_pr_file_device "$state") || return 1
  [ -n "$FM_PR_POLL_STATE_DEVICE" ] || return 1
  FM_PR_POLL_DATA_TMP=$(mktemp "$state/.fm-pr-poll-data.XXXXXX") || return 1
  FM_PR_POLL_CHECK_TMP=$(mktemp "$state/.fm-pr-poll-check.XXXXXX") || {
    fm_pr_poll_cleanup
    return 1
  }

  if ! printf '%s\n%s\n%s\n%s\n' "$url" "$owner" "$repo" "$number" > "$FM_PR_POLL_DATA_TMP" \
    || ! chmod 0600 "$FM_PR_POLL_DATA_TMP" \
    || ! fm_pr_poll_data_parse "$FM_PR_POLL_DATA_TMP" \
    || [ "$FM_PR_DATA_URL" != "$url" ] \
    || [ "$FM_PR_DATA_OWNER" != "$owner" ] \
    || [ "$FM_PR_DATA_REPO" != "$repo" ] \
    || [ "$FM_PR_DATA_NUMBER" != "$number" ] \
    || ! cp "$template" "$FM_PR_POLL_CHECK_TMP" \
    || ! chmod 0600 "$FM_PR_POLL_CHECK_TMP" \
    || ! cmp -s "$template" "$FM_PR_POLL_CHECK_TMP"; then
    fm_pr_poll_cleanup
    return 1
  fi
}

fm_pr_poll_publish_prepared() {
  [ -n "$FM_PR_POLL_DATA_TMP" ] && [ -n "$FM_PR_POLL_CHECK_TMP" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_DATA_DEST" "$FM_PR_POLL_STATE_DEVICE" || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_CHECK_DEST" "$FM_PR_POLL_STATE_DEVICE" || return 1

  if ! mv -f -- "$FM_PR_POLL_DATA_TMP" "$FM_PR_POLL_DATA_DEST"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
  FM_PR_POLL_DATA_TMP=
  if ! [ -f "$FM_PR_POLL_DATA_DEST" ] || [ -L "$FM_PR_POLL_DATA_DEST" ] \
    || [ "$(fm_pr_file_mode "$FM_PR_POLL_DATA_DEST")" != 600 ] \
    || [ "$(fm_pr_file_device "$FM_PR_POLL_DATA_DEST")" != "$FM_PR_POLL_STATE_DEVICE" ] \
    || ! fm_pr_poll_data_parse "$FM_PR_POLL_DATA_DEST" \
    || [ "$FM_PR_DATA_URL" != "$FM_PR_POLL_EXPECT_URL" ] \
    || [ "$FM_PR_DATA_OWNER" != "$FM_PR_POLL_EXPECT_OWNER" ] \
    || [ "$FM_PR_DATA_REPO" != "$FM_PR_POLL_EXPECT_REPO" ] \
    || [ "$FM_PR_DATA_NUMBER" != "$FM_PR_POLL_EXPECT_NUMBER" ]; then
    fm_pr_poll_revoke_final || true
    return 1
  fi

  if ! fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_CHECK_DEST" "$FM_PR_POLL_STATE_DEVICE" \
    || ! mv -f -- "$FM_PR_POLL_CHECK_TMP" "$FM_PR_POLL_CHECK_DEST"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
  FM_PR_POLL_CHECK_TMP=
  if ! [ -f "$FM_PR_POLL_CHECK_DEST" ] || [ -L "$FM_PR_POLL_CHECK_DEST" ] \
    || [ "$(fm_pr_file_mode "$FM_PR_POLL_CHECK_DEST")" != 600 ] \
    || [ "$(fm_pr_file_device "$FM_PR_POLL_CHECK_DEST")" != "$FM_PR_POLL_STATE_DEVICE" ] \
    || ! cmp -s "$FM_PR_POLL_TEMPLATE" "$FM_PR_POLL_CHECK_DEST"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
}

fm_pr_poll_artifacts_valid() {
  local state=$1 id=$2 template=$3 state_device
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  [ -f "$state/$id.check.sh" ] && [ ! -L "$state/$id.check.sh" ] || return 1
  [ -f "$state/$id.pr-poll" ] && [ ! -L "$state/$id.pr-poll" ] || return 1
  [ "$(fm_pr_file_mode "$state/$id.check.sh")" = 600 ] || return 1
  [ "$(fm_pr_file_mode "$state/$id.pr-poll")" = 600 ] || return 1
  [ "$(fm_pr_file_device "$state/$id.check.sh")" = "$state_device" ] || return 1
  [ "$(fm_pr_file_device "$state/$id.pr-poll")" = "$state_device" ] || return 1
  cmp -s "$template" "$state/$id.check.sh" || return 1
  fm_pr_poll_data_parse "$state/$id.pr-poll"
}
