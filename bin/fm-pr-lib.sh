#!/usr/bin/env bash
# Shared validation and atomic artifact helpers for merge polling on the
# supported forges. Callers must validate task IDs and raw PR/MR URLs before
# constructing task paths or performing any side effect.
#
# The stored identity is provider-tagged: provider, url, host, path, number.
# "path" is the full project path, which is owner/repository on GitHub and an
# arbitrarily nested group/subgroup/project namespace on GitLab. A GitLab
# project can sit at any depth, so no owner/repository pair can address one and
# the sidecar carries the whole path instead. GitLab also runs on self-hosted
# instances, so the host is part of that identity rather than a constant. Every
# consumer re-derives the identity from the stored URL and refuses any record
# whose parts do not reconstruct that exact URL.
#
# A validated exact merged result is retired through a private receipt only
# after its durable wake is appended.
# The receipt binds the terminal observation to the canonical registration and
# lets a restart finish fixed-path removal without executing state-file bytes.
# A current merge-queue ejection is not terminal: the poll stays armed, and a
# private dequeued marker records the ejection identity the watcher already
# woke so the same event is silent on later polls. A private enqueued marker
# records the one automatic enqueuePullRequest allowed for that armed PR.

FM_PR_PROVIDER=
FM_PR_URL=
FM_PR_HOST=
FM_PR_PATH=
FM_PR_OWNER=
FM_PR_REPO=
FM_PR_NUMBER=
FM_PR_DATA_PROVIDER=
FM_PR_DATA_URL=
FM_PR_DATA_HOST=
FM_PR_DATA_PATH=
FM_PR_DATA_NUMBER=
FM_PR_META_PROVIDER=
FM_PR_META_URL=
FM_PR_META_HOST=
FM_PR_META_PATH=
FM_PR_META_NUMBER=
FM_PR_REG_ID=
FM_PR_REG_PROVIDER=
FM_PR_REG_URL=
FM_PR_REG_HOST=
FM_PR_REG_PATH=
FM_PR_REG_NUMBER=
FM_PR_REG_DATA_HASH=
FM_PR_REG_TEMPLATE_HASH=
FM_PR_REG_DATA_IDENTITY=
FM_PR_REG_CHECK_IDENTITY=
FM_PR_POLL_DATA_TMP=
FM_PR_POLL_CHECK_TMP=
FM_PR_POLL_REG_TMP=
FM_PR_POLL_DATA_DEST=
FM_PR_POLL_CHECK_DEST=
FM_PR_POLL_REG_DEST=
FM_PR_POLL_EXPECT_ID=
FM_PR_POLL_EXPECT_PROVIDER=
FM_PR_POLL_EXPECT_URL=
FM_PR_POLL_EXPECT_HOST=
FM_PR_POLL_EXPECT_PATH=
FM_PR_POLL_EXPECT_NUMBER=
FM_PR_POLL_EXPECT_DATA_HASH=
FM_PR_POLL_EXPECT_TEMPLATE_HASH=
FM_PR_POLL_EXPECT_DATA_IDENTITY=
FM_PR_POLL_EXPECT_CHECK_IDENTITY=
FM_PR_POLL_TEMPLATE=
FM_PR_POLL_STATE_DEVICE=
FM_PR_POLL_SNAPSHOT_ID=
FM_PR_POLL_SNAPSHOT_PROVIDER=
FM_PR_POLL_SNAPSHOT_URL=
FM_PR_POLL_SNAPSHOT_HOST=
FM_PR_POLL_SNAPSHOT_PATH=
FM_PR_POLL_SNAPSHOT_NUMBER=
FM_PR_POLL_SNAPSHOT_DATA_HASH=
FM_PR_POLL_SNAPSHOT_TEMPLATE_HASH=
FM_PR_POLL_SNAPSHOT_DATA_IDENTITY=
FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY=
FM_PR_POLL_SNAPSHOT_REG_HASH=
FM_PR_POLL_SNAPSHOT_REG_IDENTITY=
FM_PR_RETIRE_ID=
FM_PR_RETIRE_PROVIDER=
FM_PR_RETIRE_URL=
FM_PR_RETIRE_HOST=
FM_PR_RETIRE_PATH=
FM_PR_RETIRE_NUMBER=
FM_PR_RETIRE_DATA_HASH=
FM_PR_RETIRE_TEMPLATE_HASH=
FM_PR_RETIRE_DATA_IDENTITY=
FM_PR_RETIRE_CHECK_IDENTITY=
FM_PR_RETIRE_REG_HASH=
FM_PR_RETIRE_REG_IDENTITY=
FM_PR_RETIRE_RECEIPT_HASH=
FM_PR_RETIRE_RECEIPT_IDENTITY=
FM_PR_POLL_RETIREMENT_REJECTED=
FM_PR_DEQUEUED_REASON=
FM_PR_DEQUEUED_AT=
FM_PR_DEQUEUED_PROVIDER=
FM_PR_DEQUEUED_HOST=
FM_PR_DEQUEUED_PATH=
FM_PR_DEQUEUED_NUMBER=
FM_PR_POLL_STALE_PROVIDER=
FM_PR_POLL_STALE_URL=
FM_PR_POLL_STALE_HOST=
FM_PR_POLL_STALE_PATH=
FM_PR_POLL_STALE_NUMBER=
FM_PR_PRESERVE_ID=
FM_PR_PRESERVE_PROVIDER=
FM_PR_PRESERVE_URL=
FM_PR_PRESERVE_HOST=
FM_PR_PRESERVE_PATH=
FM_PR_PRESERVE_NUMBER=
FM_PR_PRESERVE_DATA_HASH=
FM_PR_PRESERVE_TEMPLATE_HASH=
FM_PR_PRESERVE_DATA_IDENTITY=
FM_PR_PRESERVE_CHECK_IDENTITY=
FM_PR_PRESERVE_REG_HASH=
FM_PR_PRESERVE_REG_IDENTITY=
FM_PR_POLL_PRESERVE_REJECTED=
FM_PR_ENQUEUED_COUNT=
FM_PR_ENQUEUED_REASON=
FM_PR_ENQUEUED_PROVIDER=
FM_PR_ENQUEUED_HOST=
FM_PR_ENQUEUED_PATH=
FM_PR_ENQUEUED_NUMBER=

fm_task_id_path_safe() {
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_pr_task_id_valid() {
  local id=${1-}
  fm_task_id_path_safe "$id"
}

fm_task_id_creation_valid() {
  local id=${1-}
  fm_pr_task_id_valid "$id" || return 1
  [ "${#id}" -le 64 ]
}

# GitLab serves self-hosted instances, so the host is part of the identity
# rather than a constant. It is accepted only as a lowercase DNS name with no
# userinfo, port, or trailing dot, which keeps one canonical spelling per MR.
# github.com is refused here even though its shape is otherwise valid: it is
# GitHub's own host and never a GitLab instance, so a URL like
# https://github.com/o/r/-/merge_requests/1 (a typo'd or spoofed GitHub URL)
# would otherwise be armed as a GitLab watch that can never succeed.
fm_pr_gitlab_host_valid() {
  local host=${1-} label
  local LC_ALL=C
  local -a labels
  [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || return 1
  [ "$host" != github.com ] || return 1
  case "$host" in
    .*|*.|*..*|*[!a-z0-9.-]*) return 1 ;;
  esac
  IFS=. read -ra labels <<< "$host"
  for label in "${labels[@]}"; do
    [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
    case "$label" in
      -*|*-) return 1 ;;
    esac
  done
}

# A GitLab project path is group[/subgroup...]/project, so at least two
# segments and no fixed depth. GitLab reserves "-" as its route separator and
# forbids a leading hyphen, ".git", and ".atom", so none of those can name a
# real namespace and each is refused here.
fm_pr_gitlab_path_valid() {
  local path=${1-} segment
  local LC_ALL=C
  local -a segments
  [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || return 1
  case "$path" in
    /*|*/|*//*) return 1 ;;
  esac
  IFS=/ read -ra segments <<< "$path"
  [ "${#segments[@]}" -ge 2 ] && [ "${#segments[@]}" -le 20 ] || return 1
  for segment in "${segments[@]}"; do
    [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || return 1
    case "$segment" in
      .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
  done
}

# Parse a canonical PR or MR URL into the provider-tagged identity. Validation
# is strict and per provider: the GitHub username and repository rules are
# unchanged, and GitLab gets its own host and namespace rules rather than a
# loosened GitHub rule.
#
# FM_PR_OWNER and FM_PR_REPO are additionally set for github because
# bin/fm-pr-merge.sh addresses GitHub by owner/repository. A gitlab URL leaves
# them empty, and that path addresses the project by FM_PR_HOST and FM_PR_PATH
# instead, so a merge request on any instance resolves without a hardcoded host.
fm_pr_url_parse() {
  local raw=${1-} pattern host path
  local LC_ALL=C
  FM_PR_PROVIDER=
  FM_PR_URL=
  FM_PR_HOST=
  FM_PR_PATH=
  FM_PR_OWNER=
  FM_PR_REPO=
  FM_PR_NUMBER=
  pattern='^https://github\.com/([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])/([A-Za-z0-9._-]{1,100})/pull/([1-9][0-9]*)$'
  if [[ "$raw" =~ $pattern ]]; then
    [[ "${BASH_REMATCH[1]}" != *--* ]] || return 1
    [ "${BASH_REMATCH[2]}" != . ] && [ "${BASH_REMATCH[2]}" != .. ] || return 1
    FM_PR_PROVIDER=github
    FM_PR_URL=$raw
    FM_PR_HOST=github.com
    FM_PR_PATH="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    # Consumed by bin/fm-pr-merge.sh, which addresses GitHub by owner/repository.
    # shellcheck disable=SC2034
    FM_PR_OWNER=${BASH_REMATCH[1]}
    # shellcheck disable=SC2034
    FM_PR_REPO=${BASH_REMATCH[2]}
    FM_PR_NUMBER=${BASH_REMATCH[3]}
    return 0
  fi
  # The path class contains "/" and "-", so this match is greedy to the last
  # "/-/merge_requests/". Any earlier separator therefore lands inside the
  # captured path, where the reserved "-" segment is refused.
  pattern='^https://([a-z0-9.-]{1,253})/([A-Za-z0-9._/-]+)/-/merge_requests/([1-9][0-9]*)$'
  [[ "$raw" =~ $pattern ]] || return 1
  host=${BASH_REMATCH[1]}
  path=${BASH_REMATCH[2]}
  fm_pr_gitlab_host_valid "$host" || return 1
  fm_pr_gitlab_path_valid "$path" || return 1
  FM_PR_PROVIDER=gitlab
  FM_PR_URL=$raw
  FM_PR_HOST=$host
  FM_PR_PATH=$path
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

fm_pr_file_inode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %i "$1" 2>/dev/null
  else
    stat -c %i "$1" 2>/dev/null
  fi
}

fm_pr_file_identity() {
  local device inode
  device=$(fm_pr_file_device "$1") || return 1
  inode=$(fm_pr_file_inode "$1") || return 1
  [ -n "$device" ] && [ -n "$inode" ] || return 1
  printf '%s:%s\n' "$device" "$inode"
}

fm_pr_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_pr_private_file_valid() {
  local path=$1 mode=$2 device=$3
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(fm_pr_file_mode "$path")" = "$mode" ] || return 1
  [ "$(fm_pr_file_device "$path")" = "$device" ] || return 1
  [ "$(fm_pr_file_link_count "$path")" = 1 ]
}

fm_pr_regular_destination_or_absent() {
  local path=$1
  [ ! -L "$path" ] || return 1
  if [ -e "$path" ]; then
    [ -f "$path" ] && [ "$(fm_pr_file_link_count "$path")" = 1 ]
  fi
}

fm_pr_regular_destination_on_device_or_absent() {
  local path=$1 device=$2
  fm_pr_regular_destination_or_absent "$path" || return 1
  [ ! -e "$path" ] || [ "$(fm_pr_file_device "$path")" = "$device" ]
}

fm_pr_metadata_identity_parse() {
  local file=$1 line value pr_count=0 seen_pr=0 post_pr_invalid=0
  FM_PR_META_PROVIDER=
  FM_PR_META_URL=
  FM_PR_META_HOST=
  FM_PR_META_PATH=
  FM_PR_META_NUMBER=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(fm_pr_file_link_count "$file")" = 1 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      pr=*)
        pr_count=$((pr_count + 1))
        [ "$pr_count" -eq 1 ] || continue
        value=${line#pr=}
        if fm_pr_url_parse "$value"; then
          FM_PR_META_PROVIDER=$FM_PR_PROVIDER
          FM_PR_META_URL=$FM_PR_URL
          FM_PR_META_HOST=$FM_PR_HOST
          FM_PR_META_PATH=$FM_PR_PATH
          FM_PR_META_NUMBER=$FM_PR_NUMBER
        fi
        seen_pr=1
        ;;
      pr_head=*)
        if [ "$seen_pr" -eq 1 ]; then
          value=${line#pr_head=}
          fm_pr_head_valid "$value" || post_pr_invalid=1
        fi
        ;;
      x_request=*|x_request_ts=*|x_followups=*|x_platform=*|x_reply_max_chars=*)
        ;;
      *)
        [ "$seen_pr" -eq 0 ] || post_pr_invalid=1
        ;;
    esac
  done < "$file"
  [ "$pr_count" -eq 1 ] || return 1
  [ "$post_pr_invalid" -eq 0 ] || return 1
  [ -n "$FM_PR_META_URL" ]
}

# Sidecar layout: provider, url, host, path, number, one per line. A sidecar
# written before the provider tag existed has a URL on its first line and one
# line fewer, so it fails both the field count and the provider comparison and
# is refused rather than misread as a provider-tagged record.
fm_pr_poll_data_parse() {
  local file=$1 provider url host path number
  FM_PR_DATA_PROVIDER=
  FM_PR_DATA_URL=
  FM_PR_DATA_HOST=
  FM_PR_DATA_PATH=
  FM_PR_DATA_NUMBER=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 8< "$file" || return 1
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r url <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  fm_pr_url_parse "$url" || return 1
  [ "$provider" = "$FM_PR_PROVIDER" ] || return 1
  [ "$host" = "$FM_PR_HOST" ] || return 1
  [ "$path" = "$FM_PR_PATH" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  FM_PR_DATA_PROVIDER=$FM_PR_PROVIDER
  FM_PR_DATA_URL=$FM_PR_URL
  FM_PR_DATA_HOST=$FM_PR_HOST
  FM_PR_DATA_PATH=$FM_PR_PATH
  FM_PR_DATA_NUMBER=$FM_PR_NUMBER
}

# Registration layout: version tag, task id, then the same provider-tagged
# identity as the sidecar, then the two hashes and the two file identities.
# The version tag moved to v2 with the provider tag, so a registration written
# by the previous release is recognised as old and refused.
fm_pr_poll_registration_parse() {
  local file=$1 version id provider url host path number data_hash template_hash data_identity check_identity
  FM_PR_REG_ID=
  FM_PR_REG_PROVIDER=
  FM_PR_REG_URL=
  FM_PR_REG_HOST=
  FM_PR_REG_PATH=
  FM_PR_REG_NUMBER=
  FM_PR_REG_DATA_HASH=
  FM_PR_REG_TEMPLATE_HASH=
  FM_PR_REG_DATA_IDENTITY=
  FM_PR_REG_CHECK_IDENTITY=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 7< "$file" || return 1
  IFS= read -r version <&7 || { exec 7<&-; return 1; }
  IFS= read -r id <&7 || { exec 7<&-; return 1; }
  IFS= read -r provider <&7 || { exec 7<&-; return 1; }
  IFS= read -r url <&7 || { exec 7<&-; return 1; }
  IFS= read -r host <&7 || { exec 7<&-; return 1; }
  IFS= read -r path <&7 || { exec 7<&-; return 1; }
  IFS= read -r number <&7 || { exec 7<&-; return 1; }
  IFS= read -r data_hash <&7 || { exec 7<&-; return 1; }
  IFS= read -r template_hash <&7 || { exec 7<&-; return 1; }
  IFS= read -r data_identity <&7 || { exec 7<&-; return 1; }
  IFS= read -r check_identity <&7 || { exec 7<&-; return 1; }
  if IFS= read -r _extra <&7; then
    exec 7<&-
    return 1
  fi
  exec 7<&-
  [ "$version" = fm-pr-poll-registration-v2 ] || return 1
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$provider" = "$FM_PR_PROVIDER" ] || return 1
  [ "$host" = "$FM_PR_HOST" ] || return 1
  [ "$path" = "$FM_PR_PATH" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  [[ "$data_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$template_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$data_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$check_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  FM_PR_REG_ID=$id
  FM_PR_REG_PROVIDER=$FM_PR_PROVIDER
  FM_PR_REG_URL=$FM_PR_URL
  FM_PR_REG_HOST=$FM_PR_HOST
  FM_PR_REG_PATH=$FM_PR_PATH
  FM_PR_REG_NUMBER=$FM_PR_NUMBER
  FM_PR_REG_DATA_HASH=$data_hash
  FM_PR_REG_TEMPLATE_HASH=$template_hash
  FM_PR_REG_DATA_IDENTITY=$data_identity
  FM_PR_REG_CHECK_IDENTITY=$check_identity
}

fm_pr_poll_cleanup() {
  [ -z "$FM_PR_POLL_DATA_TMP" ] || rm -f -- "$FM_PR_POLL_DATA_TMP"
  [ -z "$FM_PR_POLL_CHECK_TMP" ] || rm -f -- "$FM_PR_POLL_CHECK_TMP"
  [ -z "$FM_PR_POLL_REG_TMP" ] || rm -f -- "$FM_PR_POLL_REG_TMP"
  FM_PR_POLL_DATA_TMP=
  FM_PR_POLL_CHECK_TMP=
  FM_PR_POLL_REG_TMP=
}

fm_pr_poll_revoke_final() {
  local failed=0
  # Neutralize the runnable name first so a failed rearm cannot consume state
  # whose transactional registration did not commit successfully.
  if [ -e "$FM_PR_POLL_CHECK_DEST" ] || [ -L "$FM_PR_POLL_CHECK_DEST" ]; then
    rm -f -- "$FM_PR_POLL_CHECK_DEST" || failed=1
  fi
  if [ -e "$FM_PR_POLL_REG_DEST" ] || [ -L "$FM_PR_POLL_REG_DEST" ]; then
    rm -f -- "$FM_PR_POLL_REG_DEST" || failed=1
  fi
  if [ -e "$FM_PR_POLL_DATA_DEST" ] || [ -L "$FM_PR_POLL_DATA_DEST" ]; then
    rm -f -- "$FM_PR_POLL_DATA_DEST" || failed=1
  fi
  [ ! -e "$FM_PR_POLL_CHECK_DEST" ] && [ ! -L "$FM_PR_POLL_CHECK_DEST" ] || failed=1
  [ ! -e "$FM_PR_POLL_REG_DEST" ] && [ ! -L "$FM_PR_POLL_REG_DEST" ] || failed=1
  [ ! -e "$FM_PR_POLL_DATA_DEST" ] && [ ! -L "$FM_PR_POLL_DATA_DEST" ] || failed=1
  return "$failed"
}

fm_pr_poll_prepare() {
  local state=$1 id=$2 provider=$3 url=$4 host=$5 path=$6 number=$7 template=$8
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$provider" = "$FM_PR_PROVIDER" ] || return 1
  [ "$host" = "$FM_PR_HOST" ] || return 1
  [ "$path" = "$FM_PR_PATH" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  [ -f "$template" ] || return 1

  [ ! -L "$state" ] || return 1
  mkdir -p "$state" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  umask 077
  FM_PR_POLL_DATA_DEST="$state/$id.pr-poll"
  FM_PR_POLL_CHECK_DEST="$state/$id.check.sh"
  FM_PR_POLL_REG_DEST="$state/$id.pr-poll-registration"
  FM_PR_POLL_EXPECT_ID=$id
  FM_PR_POLL_EXPECT_PROVIDER=$provider
  FM_PR_POLL_EXPECT_URL=$url
  FM_PR_POLL_EXPECT_HOST=$host
  FM_PR_POLL_EXPECT_PATH=$path
  FM_PR_POLL_EXPECT_NUMBER=$number
  FM_PR_POLL_TEMPLATE=$template
  FM_PR_POLL_STATE_DEVICE=$(fm_pr_file_device "$state") || return 1
  [ -n "$FM_PR_POLL_STATE_DEVICE" ] || return 1
  FM_PR_POLL_DATA_TMP=$(mktemp "$state/.fm-pr-poll-data.XXXXXX") || return 1
  FM_PR_POLL_CHECK_TMP=$(mktemp "$state/.fm-pr-poll-check.XXXXXX") || {
    fm_pr_poll_cleanup
    return 1
  }
  FM_PR_POLL_REG_TMP=$(mktemp "$state/.fm-pr-poll-registration.XXXXXX") || {
    fm_pr_poll_cleanup
    return 1
  }

  if ! printf '%s\n%s\n%s\n%s\n%s\n' "$provider" "$url" "$host" "$path" "$number" > "$FM_PR_POLL_DATA_TMP" \
    || ! chmod 0600 "$FM_PR_POLL_DATA_TMP" \
    || ! fm_pr_private_file_valid "$FM_PR_POLL_DATA_TMP" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! fm_pr_poll_data_parse "$FM_PR_POLL_DATA_TMP" \
    || [ "$FM_PR_DATA_PROVIDER" != "$provider" ] \
    || [ "$FM_PR_DATA_URL" != "$url" ] \
    || [ "$FM_PR_DATA_HOST" != "$host" ] \
    || [ "$FM_PR_DATA_PATH" != "$path" ] \
    || [ "$FM_PR_DATA_NUMBER" != "$number" ] \
    || ! cp "$template" "$FM_PR_POLL_CHECK_TMP" \
    || ! chmod 0600 "$FM_PR_POLL_CHECK_TMP" \
    || ! fm_pr_private_file_valid "$FM_PR_POLL_CHECK_TMP" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! cmp -s "$template" "$FM_PR_POLL_CHECK_TMP"; then
    fm_pr_poll_cleanup
    return 1
  fi
  FM_PR_POLL_EXPECT_DATA_HASH=$(fm_pr_sha256 "$FM_PR_POLL_DATA_TMP") || { fm_pr_poll_cleanup; return 1; }
  FM_PR_POLL_EXPECT_TEMPLATE_HASH=$(fm_pr_sha256 "$FM_PR_POLL_CHECK_TMP") || { fm_pr_poll_cleanup; return 1; }
  FM_PR_POLL_EXPECT_DATA_IDENTITY=$(fm_pr_file_identity "$FM_PR_POLL_DATA_TMP") || { fm_pr_poll_cleanup; return 1; }
  FM_PR_POLL_EXPECT_CHECK_IDENTITY=$(fm_pr_file_identity "$FM_PR_POLL_CHECK_TMP") || { fm_pr_poll_cleanup; return 1; }
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-registration-v2 "$id" "$provider" "$url" "$host" "$path" "$number" \
      "$FM_PR_POLL_EXPECT_DATA_HASH" "$FM_PR_POLL_EXPECT_TEMPLATE_HASH" \
      "$FM_PR_POLL_EXPECT_DATA_IDENTITY" "$FM_PR_POLL_EXPECT_CHECK_IDENTITY" \
      > "$FM_PR_POLL_REG_TMP" \
    || ! chmod 0600 "$FM_PR_POLL_REG_TMP" \
    || ! fm_pr_private_file_valid "$FM_PR_POLL_REG_TMP" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! fm_pr_poll_registration_parse "$FM_PR_POLL_REG_TMP" \
    || [ "$FM_PR_REG_ID" != "$id" ] \
    || [ "$FM_PR_REG_DATA_HASH" != "$FM_PR_POLL_EXPECT_DATA_HASH" ] \
    || [ "$FM_PR_REG_TEMPLATE_HASH" != "$FM_PR_POLL_EXPECT_TEMPLATE_HASH" ]; then
    fm_pr_poll_cleanup
    return 1
  fi
}

fm_pr_poll_publish_prepared() {
  [ -n "$FM_PR_POLL_DATA_TMP" ] && [ -n "$FM_PR_POLL_CHECK_TMP" ] \
    && [ -n "$FM_PR_POLL_REG_TMP" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_DATA_DEST" "$FM_PR_POLL_STATE_DEVICE" || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_REG_DEST" "$FM_PR_POLL_STATE_DEVICE" || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_CHECK_DEST" "$FM_PR_POLL_STATE_DEVICE" || return 1

  if ! mv -f -- "$FM_PR_POLL_DATA_TMP" "$FM_PR_POLL_DATA_DEST"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
  FM_PR_POLL_DATA_TMP=
  if ! fm_pr_private_file_valid "$FM_PR_POLL_DATA_DEST" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || [ "$(fm_pr_file_identity "$FM_PR_POLL_DATA_DEST")" != "$FM_PR_POLL_EXPECT_DATA_IDENTITY" ] \
    || [ "$(fm_pr_sha256 "$FM_PR_POLL_DATA_DEST")" != "$FM_PR_POLL_EXPECT_DATA_HASH" ] \
    || ! fm_pr_poll_data_parse "$FM_PR_POLL_DATA_DEST" \
    || [ "$FM_PR_DATA_PROVIDER" != "$FM_PR_POLL_EXPECT_PROVIDER" ] \
    || [ "$FM_PR_DATA_URL" != "$FM_PR_POLL_EXPECT_URL" ] \
    || [ "$FM_PR_DATA_HOST" != "$FM_PR_POLL_EXPECT_HOST" ] \
    || [ "$FM_PR_DATA_PATH" != "$FM_PR_POLL_EXPECT_PATH" ] \
    || [ "$FM_PR_DATA_NUMBER" != "$FM_PR_POLL_EXPECT_NUMBER" ]; then
    fm_pr_poll_revoke_final || true
    return 1
  fi

  if ! mv -f -- "$FM_PR_POLL_REG_TMP" "$FM_PR_POLL_REG_DEST"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
  FM_PR_POLL_REG_TMP=
  if ! fm_pr_private_file_valid "$FM_PR_POLL_REG_DEST" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! fm_pr_poll_registration_parse "$FM_PR_POLL_REG_DEST" \
    || [ "$FM_PR_REG_ID" != "$FM_PR_POLL_EXPECT_ID" ] \
    || [ "$FM_PR_REG_PROVIDER" != "$FM_PR_POLL_EXPECT_PROVIDER" ] \
    || [ "$FM_PR_REG_URL" != "$FM_PR_POLL_EXPECT_URL" ] \
    || [ "$FM_PR_REG_HOST" != "$FM_PR_POLL_EXPECT_HOST" ] \
    || [ "$FM_PR_REG_PATH" != "$FM_PR_POLL_EXPECT_PATH" ] \
    || [ "$FM_PR_REG_NUMBER" != "$FM_PR_POLL_EXPECT_NUMBER" ] \
    || [ "$FM_PR_REG_DATA_HASH" != "$FM_PR_POLL_EXPECT_DATA_HASH" ] \
    || [ "$FM_PR_REG_TEMPLATE_HASH" != "$FM_PR_POLL_EXPECT_TEMPLATE_HASH" ] \
    || [ "$FM_PR_REG_DATA_IDENTITY" != "$FM_PR_POLL_EXPECT_DATA_IDENTITY" ] \
    || [ "$FM_PR_REG_CHECK_IDENTITY" != "$FM_PR_POLL_EXPECT_CHECK_IDENTITY" ]; then
    fm_pr_poll_revoke_final || true
    return 1
  fi

  if ! fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_CHECK_DEST" "$FM_PR_POLL_STATE_DEVICE" \
    || ! mv -f -- "$FM_PR_POLL_CHECK_TMP" "$FM_PR_POLL_CHECK_DEST"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
  FM_PR_POLL_CHECK_TMP=
  if ! fm_pr_poll_artifacts_valid "${FM_PR_POLL_CHECK_DEST%/*}" "$FM_PR_POLL_EXPECT_ID" "$FM_PR_POLL_TEMPLATE"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
}

fm_pr_poll_artifacts_valid() {
  local state=$1 id=$2 template=$3 state_device check data registration meta data_hash template_hash data_identity check_identity
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  meta="$state/$id.meta"
  fm_pr_private_file_valid "$check" 600 "$state_device" || return 1
  fm_pr_private_file_valid "$data" 600 "$state_device" || return 1
  fm_pr_private_file_valid "$registration" 600 "$state_device" || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_pr_file_link_count "$meta")" = 1 ] || return 1
  cmp -s "$template" "$check" || return 1
  fm_pr_poll_data_parse "$data" || return 1
  data_hash=$(fm_pr_sha256 "$data") || return 1
  template_hash=$(fm_pr_sha256 "$check") || return 1
  data_identity=$(fm_pr_file_identity "$data") || return 1
  check_identity=$(fm_pr_file_identity "$check") || return 1
  fm_pr_poll_registration_parse "$registration" || return 1
  [ "$FM_PR_REG_ID" = "$id" ] || return 1
  [ "$FM_PR_REG_PROVIDER" = "$FM_PR_DATA_PROVIDER" ] || return 1
  [ "$FM_PR_REG_URL" = "$FM_PR_DATA_URL" ] || return 1
  [ "$FM_PR_REG_HOST" = "$FM_PR_DATA_HOST" ] || return 1
  [ "$FM_PR_REG_PATH" = "$FM_PR_DATA_PATH" ] || return 1
  [ "$FM_PR_REG_NUMBER" = "$FM_PR_DATA_NUMBER" ] || return 1
  [ "$FM_PR_REG_DATA_HASH" = "$data_hash" ] || return 1
  [ "$FM_PR_REG_TEMPLATE_HASH" = "$template_hash" ] || return 1
  [ "$FM_PR_REG_DATA_IDENTITY" = "$data_identity" ] || return 1
  [ "$FM_PR_REG_CHECK_IDENTITY" = "$check_identity" ] || return 1
  fm_pr_metadata_identity_parse "$meta" || return 1
  [ "$FM_PR_META_PROVIDER" = "$FM_PR_DATA_PROVIDER" ] || return 1
  [ "$FM_PR_META_URL" = "$FM_PR_DATA_URL" ] || return 1
  [ "$FM_PR_META_HOST" = "$FM_PR_DATA_HOST" ] || return 1
  [ "$FM_PR_META_PATH" = "$FM_PR_DATA_PATH" ] || return 1
  [ "$FM_PR_META_NUMBER" = "$FM_PR_DATA_NUMBER" ]
}

fm_pr_poll_snapshot_capture() {
  local state=$1 id=$2 template=$3 registration
  fm_pr_poll_artifacts_valid "$state" "$id" "$template" || return 1
  registration="$state/$id.pr-poll-registration"
  FM_PR_POLL_SNAPSHOT_REG_HASH=$(fm_pr_sha256 "$registration") || return 1
  FM_PR_POLL_SNAPSHOT_REG_IDENTITY=$(fm_pr_file_identity "$registration") || return 1
  FM_PR_POLL_SNAPSHOT_ID=$id
  FM_PR_POLL_SNAPSHOT_PROVIDER=$FM_PR_DATA_PROVIDER
  FM_PR_POLL_SNAPSHOT_URL=$FM_PR_DATA_URL
  FM_PR_POLL_SNAPSHOT_HOST=$FM_PR_DATA_HOST
  FM_PR_POLL_SNAPSHOT_PATH=$FM_PR_DATA_PATH
  FM_PR_POLL_SNAPSHOT_NUMBER=$FM_PR_DATA_NUMBER
  FM_PR_POLL_SNAPSHOT_DATA_HASH=$FM_PR_REG_DATA_HASH
  FM_PR_POLL_SNAPSHOT_TEMPLATE_HASH=$FM_PR_REG_TEMPLATE_HASH
  FM_PR_POLL_SNAPSHOT_DATA_IDENTITY=$FM_PR_REG_DATA_IDENTITY
  FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY=$FM_PR_REG_CHECK_IDENTITY
}

# --- poll-program refresh -----------------------------------------------------
# An armed poll carries a byte copy of bin/fm-pr-poll.sh, so shipping any change
# to that program invalidates every poll armed before the change: the copy no
# longer compares equal to the template and the watcher can only report the
# check as unauthenticated until a human re-arms it. That copy is still provably
# the one its own registration recorded, and its sidecar and task metadata still
# agree, so the poll is stale rather than untrusted, and the two are told apart
# here. Only the poll program itself is refreshed; no other artifact is migrated
# and no other kind of mismatch is repaired.
fm_pr_poll_template_stale() {  # <state> <id> <template>
  local state=$1 id=$2 template=$3 state_device check data registration meta
  FM_PR_POLL_STALE_PROVIDER=
  FM_PR_POLL_STALE_URL=
  FM_PR_POLL_STALE_HOST=
  FM_PR_POLL_STALE_PATH=
  FM_PR_POLL_STALE_NUMBER=
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  [ -f "$template" ] && [ ! -L "$template" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  meta="$state/$id.meta"
  # A poll holding a retirement receipt is being removed, not kept alive, and
  # that receipt is bound to the exact artifacts a refresh would replace.
  [ ! -e "$state/$id.pr-poll-retirement" ] && [ ! -L "$state/$id.pr-poll-retirement" ] || return 1
  # An unfinished set-aside still owns these same artifacts until it is
  # recovered, so a second refresh never starts on top of one.
  [ ! -e "$state/$id.pr-poll-preserve" ] && [ ! -L "$state/$id.pr-poll-preserve" ] || return 1
  fm_pr_private_file_valid "$check" 600 "$state_device" || return 1
  fm_pr_private_file_valid "$data" 600 "$state_device" || return 1
  fm_pr_private_file_valid "$registration" 600 "$state_device" || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_pr_file_link_count "$meta")" = 1 ] || return 1
  # Equal bytes are not stale, and the caller's failure then has another cause.
  if cmp -s "$template" "$check"; then
    return 1
  fi
  fm_pr_poll_data_parse "$data" || return 1
  fm_pr_poll_registration_parse "$registration" || return 1
  [ "$FM_PR_REG_ID" = "$id" ] || return 1
  [ "$FM_PR_REG_PROVIDER" = "$FM_PR_DATA_PROVIDER" ] || return 1
  [ "$FM_PR_REG_URL" = "$FM_PR_DATA_URL" ] || return 1
  [ "$FM_PR_REG_HOST" = "$FM_PR_DATA_HOST" ] || return 1
  [ "$FM_PR_REG_PATH" = "$FM_PR_DATA_PATH" ] || return 1
  [ "$FM_PR_REG_NUMBER" = "$FM_PR_DATA_NUMBER" ] || return 1
  [ "$FM_PR_REG_DATA_HASH" = "$(fm_pr_sha256 "$data")" ] || return 1
  [ "$FM_PR_REG_DATA_IDENTITY" = "$(fm_pr_file_identity "$data")" ] || return 1
  # The published copy must be exactly the one this registration recorded, so an
  # edited or swapped check program is never mistaken for an older release.
  [ "$FM_PR_REG_TEMPLATE_HASH" = "$(fm_pr_sha256 "$check")" ] || return 1
  [ "$FM_PR_REG_CHECK_IDENTITY" = "$(fm_pr_file_identity "$check")" ] || return 1
  fm_pr_metadata_identity_parse "$meta" || return 1
  [ "$FM_PR_META_PROVIDER" = "$FM_PR_DATA_PROVIDER" ] || return 1
  [ "$FM_PR_META_URL" = "$FM_PR_DATA_URL" ] || return 1
  [ "$FM_PR_META_HOST" = "$FM_PR_DATA_HOST" ] || return 1
  [ "$FM_PR_META_PATH" = "$FM_PR_DATA_PATH" ] || return 1
  [ "$FM_PR_META_NUMBER" = "$FM_PR_DATA_NUMBER" ] || return 1
  FM_PR_POLL_STALE_PROVIDER=$FM_PR_DATA_PROVIDER
  FM_PR_POLL_STALE_URL=$FM_PR_DATA_URL
  FM_PR_POLL_STALE_HOST=$FM_PR_DATA_HOST
  FM_PR_POLL_STALE_PATH=$FM_PR_DATA_PATH
  FM_PR_POLL_STALE_NUMBER=$FM_PR_DATA_NUMBER
}

# The publication a refresh drives revokes every name it touched as soon as any
# step fails, which is right for an initial arm - nothing was armed before it -
# but would turn a refused refresh into a disarmed poll: the task would lose the
# check the watcher reports, and its merge or ejection would then sleep with
# nobody to wake. The artifacts a refresh is about to replace are therefore set
# aside first and put back if the refresh does not complete.
#
# The set-aside is durable rather than held in the refreshing process: a receipt
# naming those exact artifacts is published before the first rename, and the
# copies are set aside under fixed names bound to it. An interruption anywhere
# in a refresh therefore leaves either a poll that is still armed or that
# receipt, which the next cycle recovers or reports. Copies are set aside and
# put back by rename, so what returns is the exact inode the registration
# recorded rather than an equal-looking copy, and the restored poll is armed on
# its previous program, reported by its caller, and refreshable again next time.
fm_pr_poll_preserve_parse() {
  local file=$1 version id provider url host path number data_hash template_hash
  local data_identity check_identity reg_hash reg_identity _extra
  FM_PR_PRESERVE_ID=
  FM_PR_PRESERVE_PROVIDER=
  FM_PR_PRESERVE_URL=
  FM_PR_PRESERVE_HOST=
  FM_PR_PRESERVE_PATH=
  FM_PR_PRESERVE_NUMBER=
  FM_PR_PRESERVE_DATA_HASH=
  FM_PR_PRESERVE_TEMPLATE_HASH=
  FM_PR_PRESERVE_DATA_IDENTITY=
  FM_PR_PRESERVE_CHECK_IDENTITY=
  FM_PR_PRESERVE_REG_HASH=
  FM_PR_PRESERVE_REG_IDENTITY=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 9< "$file" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r id <&9 || { exec 9<&-; return 1; }
  IFS= read -r provider <&9 || { exec 9<&-; return 1; }
  IFS= read -r url <&9 || { exec 9<&-; return 1; }
  IFS= read -r host <&9 || { exec 9<&-; return 1; }
  IFS= read -r path <&9 || { exec 9<&-; return 1; }
  IFS= read -r number <&9 || { exec 9<&-; return 1; }
  IFS= read -r data_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r template_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r data_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r check_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r reg_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r reg_identity <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = fm-pr-poll-preserve-v1 ] || return 1
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$provider" = "$FM_PR_PROVIDER" ] || return 1
  [ "$host" = "$FM_PR_HOST" ] || return 1
  [ "$path" = "$FM_PR_PATH" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  [[ "$data_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$template_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$reg_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$data_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$check_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$reg_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  FM_PR_PRESERVE_ID=$id
  FM_PR_PRESERVE_PROVIDER=$provider
  FM_PR_PRESERVE_URL=$url
  FM_PR_PRESERVE_HOST=$host
  FM_PR_PRESERVE_PATH=$path
  FM_PR_PRESERVE_NUMBER=$number
  FM_PR_PRESERVE_DATA_HASH=$data_hash
  FM_PR_PRESERVE_TEMPLATE_HASH=$template_hash
  FM_PR_PRESERVE_DATA_IDENTITY=$data_identity
  FM_PR_PRESERVE_CHECK_IDENTITY=$check_identity
  FM_PR_PRESERVE_REG_HASH=$reg_hash
  FM_PR_PRESERVE_REG_IDENTITY=$reg_identity
}

fm_pr_poll_preserve_receipt_valid() {  # <state> <id>
  local state=$1 id=$2 receipt state_device
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-preserve"
  fm_pr_private_file_valid "$receipt" 600 "$state_device" || return 1
  fm_pr_poll_preserve_parse "$receipt" || return 1
  [ "$FM_PR_PRESERVE_ID" = "$id" ]
}

fm_pr_poll_preserve_artifact_matches() {  # <path> <device> <identity> <hash>
  local path=$1 device=$2 identity=$3 hash=$4
  fm_pr_private_file_valid "$path" 600 "$device" || return 1
  [ "$(fm_pr_file_identity "$path")" = "$identity" ] || return 1
  [ "$(fm_pr_sha256 "$path")" = "$hash" ]
}

fm_pr_poll_preserve_set_aside() {  # <source> <destination> <device>
  local source=$1 destination=$2 device=$3
  fm_pr_regular_destination_on_device_or_absent "$destination" "$device" || return 1
  mv -f -- "$source" "$destination" || return 1
  fm_pr_private_file_valid "$destination" 600 "$device"
}

fm_pr_poll_preserve_put_back() {  # <preserved> <destination> <device> <identity> <hash>
  local preserved=$1 destination=$2 device=$3 identity=$4 hash=$5
  [ -e "$preserved" ] || [ -L "$preserved" ] || return 0
  fm_pr_poll_preserve_artifact_matches "$preserved" "$device" "$identity" "$hash" || return 1
  fm_pr_regular_destination_on_device_or_absent "$destination" "$device" || return 1
  mv -f -- "$preserved" "$destination"
}

# Put back every artifact the receipt still owns, and retire the receipt only
# once all three canonical names hold exactly what it recorded. A receipt that
# cannot be honoured is kept, so the poll it protects keeps being reported by
# the next cycle instead of disappearing.
fm_pr_poll_preserve_recover_one() {  # <state> <id>
  local state=$1 id=$2 receipt state_device
  fm_pr_task_id_valid "$id" || return 1
  receipt="$state/$id.pr-poll-preserve"
  if [ ! -e "$receipt" ] && [ ! -L "$receipt" ]; then
    return 0
  fi
  fm_pr_poll_preserve_receipt_valid "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_poll_preserve_put_back "$state/$id.pr-poll-preserve-data" "$state/$id.pr-poll" \
    "$state_device" "$FM_PR_PRESERVE_DATA_IDENTITY" "$FM_PR_PRESERVE_DATA_HASH" || return 1
  fm_pr_poll_preserve_put_back "$state/$id.pr-poll-preserve-registration" \
    "$state/$id.pr-poll-registration" \
    "$state_device" "$FM_PR_PRESERVE_REG_IDENTITY" "$FM_PR_PRESERVE_REG_HASH" || return 1
  # The runnable name comes back last, and only once the state a run of it reads
  # is back, so a half-restored poll is never executable.
  fm_pr_poll_preserve_put_back "$state/$id.pr-poll-preserve-check" "$state/$id.check.sh" \
    "$state_device" "$FM_PR_PRESERVE_CHECK_IDENTITY" "$FM_PR_PRESERVE_TEMPLATE_HASH" || return 1
  fm_pr_poll_preserve_artifact_matches "$state/$id.pr-poll" "$state_device" \
    "$FM_PR_PRESERVE_DATA_IDENTITY" "$FM_PR_PRESERVE_DATA_HASH" || return 1
  fm_pr_poll_preserve_artifact_matches "$state/$id.pr-poll-registration" "$state_device" \
    "$FM_PR_PRESERVE_REG_IDENTITY" "$FM_PR_PRESERVE_REG_HASH" || return 1
  fm_pr_poll_preserve_artifact_matches "$state/$id.check.sh" "$state_device" \
    "$FM_PR_PRESERVE_CHECK_IDENTITY" "$FM_PR_PRESERVE_TEMPLATE_HASH" || return 1
  # The restored poll must address the pull request this receipt was written
  # for, so a receipt is retired only against the identity it recorded.
  fm_pr_poll_data_parse "$state/$id.pr-poll" || return 1
  [ "$FM_PR_DATA_PROVIDER" = "$FM_PR_PRESERVE_PROVIDER" ] || return 1
  [ "$FM_PR_DATA_URL" = "$FM_PR_PRESERVE_URL" ] || return 1
  [ "$FM_PR_DATA_HOST" = "$FM_PR_PRESERVE_HOST" ] || return 1
  [ "$FM_PR_DATA_PATH" = "$FM_PR_PRESERVE_PATH" ] || return 1
  [ "$FM_PR_DATA_NUMBER" = "$FM_PR_PRESERVE_NUMBER" ] || return 1
  rm -f -- "$receipt" || return 1
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ] || return 1
  rm -f -- "$state/$id.pr-poll-preserve-check" \
    "$state/$id.pr-poll-preserve-registration" "$state/$id.pr-poll-preserve-data"
}

fm_pr_poll_preserve_recover_all() {  # <state>
  local state=$1 receipt id
  FM_PR_POLL_PRESERVE_REJECTED=
  for receipt in "$state"/*.pr-poll-preserve; do
    [ -e "$receipt" ] || [ -L "$receipt" ] || continue
    id=$(basename "$receipt" .pr-poll-preserve)
    if ! fm_pr_task_id_valid "$id" || ! fm_pr_poll_preserve_recover_one "$state" "$id"; then
      FM_PR_POLL_PRESERVE_REJECTED="$FM_PR_POLL_PRESERVE_REJECTED $receipt"
    fi
  done
  [ -z "$FM_PR_POLL_PRESERVE_REJECTED" ]
}

fm_pr_poll_preserve_remove() {  # <state> <id>
  local state=$1 id=$2 artifact
  fm_pr_task_id_valid "$id" || return 1
  for artifact in "$state/$id.pr-poll-preserve" "$state/$id.pr-poll-preserve-check" \
    "$state/$id.pr-poll-preserve-registration" "$state/$id.pr-poll-preserve-data"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    [ -f "$artifact" ] && [ ! -L "$artifact" ] || return 1
    rm -f -- "$artifact" || return 1
  done
}

fm_pr_poll_preserve_save() {  # <state> <id>
  local state=$1 id=$2 state_device receipt tmp check data registration
  local data_hash template_hash reg_hash data_identity check_identity reg_identity
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  receipt="$state/$id.pr-poll-preserve"
  fm_pr_private_file_valid "$check" 600 "$state_device" || return 1
  fm_pr_private_file_valid "$data" 600 "$state_device" || return 1
  fm_pr_private_file_valid "$registration" 600 "$state_device" || return 1
  fm_pr_poll_data_parse "$data" || return 1
  data_hash=$(fm_pr_sha256 "$data") || return 1
  template_hash=$(fm_pr_sha256 "$check") || return 1
  reg_hash=$(fm_pr_sha256 "$registration") || return 1
  data_identity=$(fm_pr_file_identity "$data") || return 1
  check_identity=$(fm_pr_file_identity "$check") || return 1
  reg_identity=$(fm_pr_file_identity "$registration") || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-pr-poll-preserve.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-preserve-v1 "$id" "$FM_PR_DATA_PROVIDER" "$FM_PR_DATA_URL" \
      "$FM_PR_DATA_HOST" "$FM_PR_DATA_PATH" "$FM_PR_DATA_NUMBER" \
      "$data_hash" "$template_hash" "$data_identity" "$check_identity" \
      "$reg_hash" "$reg_identity" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$state_device" \
    || ! fm_pr_poll_preserve_parse "$tmp" \
    || [ "$FM_PR_PRESERVE_ID" != "$id" ] \
    || ! fm_pr_regular_destination_on_device_or_absent "$receipt" "$state_device" \
    || [ -e "$receipt" ] || [ -L "$receipt" ] \
    || ! mv -f -- "$tmp" "$receipt"; then
    rm -f -- "$tmp"
    return 1
  fi
  # Withdrawn in the order a revocation uses: the runnable name first, so no run
  # of the check can observe state that is on its way out.
  if ! fm_pr_poll_preserve_set_aside "$check" "$state/$id.pr-poll-preserve-check" "$state_device" \
    || ! fm_pr_poll_preserve_set_aside "$registration" \
      "$state/$id.pr-poll-preserve-registration" "$state_device" \
    || ! fm_pr_poll_preserve_set_aside "$data" "$state/$id.pr-poll-preserve-data" "$state_device"; then
    fm_pr_poll_preserve_recover_one "$state" "$id" || true
    return 1
  fi
  fm_pr_poll_preserve_receipt_valid "$state" "$id"
}

# The receipt goes first: once the refreshed poll is published and valid, a copy
# that outlives an interruption must never be put back over it.
fm_pr_poll_preserve_discard() {  # <state> <id>
  local state=$1 id=$2 receipt
  fm_pr_task_id_valid "$id" || return 1
  receipt="$state/$id.pr-poll-preserve"
  rm -f -- "$receipt" || return 1
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ] || return 1
  rm -f -- "$state/$id.pr-poll-preserve-check" \
    "$state/$id.pr-poll-preserve-registration" "$state/$id.pr-poll-preserve-data"
}

# Re-arm a stale poll on the identity it already carries, through the same
# transactional publication an initial arm uses, so a partial refresh revokes
# rather than leaving a half-updated poll. A caller that cannot re-arm still
# reports the check, so a refused refresh is loud rather than silent, and the
# poll it refused to refresh is left armed on the program it already carried.
fm_pr_poll_template_refresh() {  # <state> <id> <template>
  local state=$1 id=$2 template=$3 previous_umask rc=0
  fm_pr_poll_template_stale "$state" "$id" "$template" || return 1
  previous_umask=$(umask)
  fm_pr_poll_prepare "$state" "$id" "$FM_PR_POLL_STALE_PROVIDER" "$FM_PR_POLL_STALE_URL" \
    "$FM_PR_POLL_STALE_HOST" "$FM_PR_POLL_STALE_PATH" "$FM_PR_POLL_STALE_NUMBER" "$template" \
    || rc=1
  # Nothing is set aside until the replacement is fully staged, so a refresh
  # that cannot even prepare leaves the armed poll untouched.
  [ "$rc" -ne 0 ] || fm_pr_poll_preserve_save "$state" "$id" || rc=1
  [ "$rc" -ne 0 ] || fm_pr_poll_publish_prepared || rc=1
  umask "$previous_umask"
  if [ "$rc" -eq 0 ] && fm_pr_poll_artifacts_valid "$state" "$id" "$template"; then
    fm_pr_poll_preserve_discard "$state" "$id" || return 1
    return 0
  fi
  fm_pr_poll_preserve_recover_one "$state" "$id" || true
  return 1
}

fm_pr_poll_snapshot_matches() {
  local state=$1 id=$2 template=$3 registration reg_hash reg_identity
  [ -n "$FM_PR_POLL_SNAPSHOT_ID" ] && [ "$id" = "$FM_PR_POLL_SNAPSHOT_ID" ] || return 1
  fm_pr_poll_artifacts_valid "$state" "$id" "$template" || return 1
  registration="$state/$id.pr-poll-registration"
  reg_hash=$(fm_pr_sha256 "$registration") || return 1
  reg_identity=$(fm_pr_file_identity "$registration") || return 1
  [ "$FM_PR_DATA_PROVIDER" = "$FM_PR_POLL_SNAPSHOT_PROVIDER" ] || return 1
  [ "$FM_PR_DATA_URL" = "$FM_PR_POLL_SNAPSHOT_URL" ] || return 1
  [ "$FM_PR_DATA_HOST" = "$FM_PR_POLL_SNAPSHOT_HOST" ] || return 1
  [ "$FM_PR_DATA_PATH" = "$FM_PR_POLL_SNAPSHOT_PATH" ] || return 1
  [ "$FM_PR_DATA_NUMBER" = "$FM_PR_POLL_SNAPSHOT_NUMBER" ] || return 1
  [ "$FM_PR_REG_DATA_HASH" = "$FM_PR_POLL_SNAPSHOT_DATA_HASH" ] || return 1
  [ "$FM_PR_REG_TEMPLATE_HASH" = "$FM_PR_POLL_SNAPSHOT_TEMPLATE_HASH" ] || return 1
  [ "$FM_PR_REG_DATA_IDENTITY" = "$FM_PR_POLL_SNAPSHOT_DATA_IDENTITY" ] || return 1
  [ "$FM_PR_REG_CHECK_IDENTITY" = "$FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY" ] || return 1
  [ "$reg_hash" = "$FM_PR_POLL_SNAPSHOT_REG_HASH" ] || return 1
  [ "$reg_identity" = "$FM_PR_POLL_SNAPSHOT_REG_IDENTITY" ]
}

fm_pr_poll_retirement_parse() {
  local file=$1 version id provider url host path number data_hash template_hash
  local data_identity check_identity reg_hash reg_identity result _extra
  FM_PR_RETIRE_ID=
  FM_PR_RETIRE_PROVIDER=
  FM_PR_RETIRE_URL=
  FM_PR_RETIRE_HOST=
  FM_PR_RETIRE_PATH=
  FM_PR_RETIRE_NUMBER=
  FM_PR_RETIRE_DATA_HASH=
  FM_PR_RETIRE_TEMPLATE_HASH=
  FM_PR_RETIRE_DATA_IDENTITY=
  FM_PR_RETIRE_CHECK_IDENTITY=
  FM_PR_RETIRE_REG_HASH=
  FM_PR_RETIRE_REG_IDENTITY=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 9< "$file" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r id <&9 || { exec 9<&-; return 1; }
  IFS= read -r provider <&9 || { exec 9<&-; return 1; }
  IFS= read -r url <&9 || { exec 9<&-; return 1; }
  IFS= read -r host <&9 || { exec 9<&-; return 1; }
  IFS= read -r path <&9 || { exec 9<&-; return 1; }
  IFS= read -r number <&9 || { exec 9<&-; return 1; }
  IFS= read -r data_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r template_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r data_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r check_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r reg_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r reg_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r result <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = fm-pr-poll-retirement-v1 ] || return 1
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$provider" = "$FM_PR_PROVIDER" ] || return 1
  [ "$host" = "$FM_PR_HOST" ] || return 1
  [ "$path" = "$FM_PR_PATH" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  [[ "$data_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$template_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$data_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$check_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$reg_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$reg_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [ "$result" = merged ] || return 1
  FM_PR_RETIRE_ID=$id
  FM_PR_RETIRE_PROVIDER=$provider
  FM_PR_RETIRE_URL=$url
  FM_PR_RETIRE_HOST=$host
  FM_PR_RETIRE_PATH=$path
  FM_PR_RETIRE_NUMBER=$number
  FM_PR_RETIRE_DATA_HASH=$data_hash
  FM_PR_RETIRE_TEMPLATE_HASH=$template_hash
  FM_PR_RETIRE_DATA_IDENTITY=$data_identity
  FM_PR_RETIRE_CHECK_IDENTITY=$check_identity
  FM_PR_RETIRE_REG_HASH=$reg_hash
  FM_PR_RETIRE_REG_IDENTITY=$reg_identity
}

fm_pr_poll_retirement_receipt_valid() {
  local state=$1 id=$2 receipt state_device meta
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-retirement"
  fm_pr_private_file_valid "$receipt" 600 "$state_device" || return 1
  fm_pr_poll_retirement_parse "$receipt" || return 1
  [ "$FM_PR_RETIRE_ID" = "$id" ] || return 1
  meta="$state/$id.meta"
  fm_pr_metadata_identity_parse "$meta" || return 1
  [ "$FM_PR_META_PROVIDER" = "$FM_PR_RETIRE_PROVIDER" ] || return 1
  [ "$FM_PR_META_URL" = "$FM_PR_RETIRE_URL" ] || return 1
  [ "$FM_PR_META_HOST" = "$FM_PR_RETIRE_HOST" ] || return 1
  [ "$FM_PR_META_PATH" = "$FM_PR_RETIRE_PATH" ] || return 1
  [ "$FM_PR_META_NUMBER" = "$FM_PR_RETIRE_NUMBER" ] || return 1
  FM_PR_RETIRE_RECEIPT_HASH=$(fm_pr_sha256 "$receipt") || return 1
  FM_PR_RETIRE_RECEIPT_IDENTITY=$(fm_pr_file_identity "$receipt") || return 1
}

fm_pr_poll_retirement_data_valid() {
  local state=$1 id=$2 state_device data data_hash data_identity
  state_device=$(fm_pr_file_device "$state") || return 1
  data="$state/$id.pr-poll"
  fm_pr_private_file_valid "$data" 600 "$state_device" || return 1
  fm_pr_poll_data_parse "$data" || return 1
  data_hash=$(fm_pr_sha256 "$data") || return 1
  data_identity=$(fm_pr_file_identity "$data") || return 1
  [ "$FM_PR_DATA_PROVIDER" = "$FM_PR_RETIRE_PROVIDER" ] || return 1
  [ "$FM_PR_DATA_URL" = "$FM_PR_RETIRE_URL" ] || return 1
  [ "$FM_PR_DATA_HOST" = "$FM_PR_RETIRE_HOST" ] || return 1
  [ "$FM_PR_DATA_PATH" = "$FM_PR_RETIRE_PATH" ] || return 1
  [ "$FM_PR_DATA_NUMBER" = "$FM_PR_RETIRE_NUMBER" ] || return 1
  [ "$data_hash" = "$FM_PR_RETIRE_DATA_HASH" ] || return 1
  [ "$data_identity" = "$FM_PR_RETIRE_DATA_IDENTITY" ]
}

fm_pr_poll_retirement_registration_valid() {
  local state=$1 id=$2 state_device registration reg_hash reg_identity
  state_device=$(fm_pr_file_device "$state") || return 1
  registration="$state/$id.pr-poll-registration"
  fm_pr_private_file_valid "$registration" 600 "$state_device" || return 1
  fm_pr_poll_registration_parse "$registration" || return 1
  reg_hash=$(fm_pr_sha256 "$registration") || return 1
  reg_identity=$(fm_pr_file_identity "$registration") || return 1
  [ "$FM_PR_REG_ID" = "$id" ] || return 1
  [ "$FM_PR_REG_PROVIDER" = "$FM_PR_RETIRE_PROVIDER" ] || return 1
  [ "$FM_PR_REG_URL" = "$FM_PR_RETIRE_URL" ] || return 1
  [ "$FM_PR_REG_HOST" = "$FM_PR_RETIRE_HOST" ] || return 1
  [ "$FM_PR_REG_PATH" = "$FM_PR_RETIRE_PATH" ] || return 1
  [ "$FM_PR_REG_NUMBER" = "$FM_PR_RETIRE_NUMBER" ] || return 1
  [ "$FM_PR_REG_DATA_HASH" = "$FM_PR_RETIRE_DATA_HASH" ] || return 1
  [ "$FM_PR_REG_TEMPLATE_HASH" = "$FM_PR_RETIRE_TEMPLATE_HASH" ] || return 1
  [ "$FM_PR_REG_DATA_IDENTITY" = "$FM_PR_RETIRE_DATA_IDENTITY" ] || return 1
  [ "$FM_PR_REG_CHECK_IDENTITY" = "$FM_PR_RETIRE_CHECK_IDENTITY" ] || return 1
  [ "$reg_hash" = "$FM_PR_RETIRE_REG_HASH" ] || return 1
  [ "$reg_identity" = "$FM_PR_RETIRE_REG_IDENTITY" ]
}

fm_pr_poll_retirement_check_valid() {
  local state=$1 id=$2 state_device check check_hash check_identity
  state_device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  fm_pr_private_file_valid "$check" 600 "$state_device" || return 1
  check_hash=$(fm_pr_sha256 "$check") || return 1
  check_identity=$(fm_pr_file_identity "$check") || return 1
  [ "$check_hash" = "$FM_PR_RETIRE_TEMPLATE_HASH" ] || return 1
  [ "$check_identity" = "$FM_PR_RETIRE_CHECK_IDENTITY" ]
}

fm_pr_poll_retirement_state_valid() {
  local state=$1 id=$2 check data registration has_check=0 has_data=0 has_registration=0
  fm_pr_poll_retirement_receipt_valid "$state" "$id" || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  [ ! -e "$check" ] && [ ! -L "$check" ] || has_check=1
  [ ! -e "$data" ] && [ ! -L "$data" ] || has_data=1
  [ ! -e "$registration" ] && [ ! -L "$registration" ] || has_registration=1
  if [ "$has_check" -eq 1 ]; then
    [ "$has_data" -eq 1 ] && [ "$has_registration" -eq 1 ] || return 1
    fm_pr_poll_retirement_check_valid "$state" "$id" || return 1
    fm_pr_poll_retirement_data_valid "$state" "$id" || return 1
    fm_pr_poll_retirement_registration_valid "$state" "$id" || return 1
    return 0
  fi
  if [ "$has_registration" -eq 1 ]; then
    [ "$has_data" -eq 1 ] || return 1
    fm_pr_poll_retirement_data_valid "$state" "$id" || return 1
    fm_pr_poll_retirement_registration_valid "$state" "$id" || return 1
    return 0
  fi
  [ "$has_data" -eq 0 ] || fm_pr_poll_retirement_data_valid "$state" "$id"
}

fm_pr_poll_retirement_remove_exact() {
  local path=$1 state_device=$2 expected_identity=$3 expected_hash=$4
  fm_pr_private_file_valid "$path" 600 "$state_device" || return 1
  [ "$(fm_pr_file_identity "$path")" = "$expected_identity" ] || return 1
  [ "$(fm_pr_sha256 "$path")" = "$expected_hash" ] || return 1
  rm -f -- "$path" || return 1
  [ ! -e "$path" ] && [ ! -L "$path" ]
}

fm_pr_poll_retirement_discard_obsolete() {
  local state=$1 id=$2 template=$3 receipt registration state_device
  local receipt_hash receipt_identity current_reg_hash current_reg_identity
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-retirement"
  fm_pr_private_file_valid "$receipt" 600 "$state_device" || return 1
  fm_pr_poll_retirement_parse "$receipt" || return 1
  [ "$FM_PR_RETIRE_ID" = "$id" ] || return 1
  receipt_hash=$(fm_pr_sha256 "$receipt") || return 1
  receipt_identity=$(fm_pr_file_identity "$receipt") || return 1
  fm_pr_poll_artifacts_valid "$state" "$id" "$template" || return 1
  registration="$state/$id.pr-poll-registration"
  current_reg_hash=$(fm_pr_sha256 "$registration") || return 1
  current_reg_identity=$(fm_pr_file_identity "$registration") || return 1
  if [ "$current_reg_hash" = "$FM_PR_RETIRE_REG_HASH" ] \
    && [ "$current_reg_identity" = "$FM_PR_RETIRE_REG_IDENTITY" ] \
    && [ "$FM_PR_REG_DATA_IDENTITY" = "$FM_PR_RETIRE_DATA_IDENTITY" ] \
    && [ "$FM_PR_REG_CHECK_IDENTITY" = "$FM_PR_RETIRE_CHECK_IDENTITY" ]; then
    return 1
  fi
  fm_pr_poll_retirement_remove_exact "$receipt" "$state_device" \
    "$receipt_identity" "$receipt_hash"
}

fm_pr_poll_retirement_publish() {
  local state=$1 id=$2 template=$3 result=$4 receipt state_device tmp
  [ "$result" = merged ] || return 1
  fm_pr_poll_snapshot_matches "$state" "$id" "$template" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-retirement"
  fm_pr_regular_destination_on_device_or_absent "$receipt" "$state_device" || return 1
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ] || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-pr-poll-retirement.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-retirement-v1 \
      "$FM_PR_POLL_SNAPSHOT_ID" \
      "$FM_PR_POLL_SNAPSHOT_PROVIDER" \
      "$FM_PR_POLL_SNAPSHOT_URL" \
      "$FM_PR_POLL_SNAPSHOT_HOST" \
      "$FM_PR_POLL_SNAPSHOT_PATH" \
      "$FM_PR_POLL_SNAPSHOT_NUMBER" \
      "$FM_PR_POLL_SNAPSHOT_DATA_HASH" \
      "$FM_PR_POLL_SNAPSHOT_TEMPLATE_HASH" \
      "$FM_PR_POLL_SNAPSHOT_DATA_IDENTITY" \
      "$FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY" \
      "$FM_PR_POLL_SNAPSHOT_REG_HASH" \
      "$FM_PR_POLL_SNAPSHOT_REG_IDENTITY" \
      merged > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$state_device" \
    || ! fm_pr_poll_retirement_parse "$tmp" \
    || [ "$FM_PR_RETIRE_ID" != "$id" ] \
    || ! fm_pr_poll_snapshot_matches "$state" "$id" "$template" \
    || ! fm_pr_regular_destination_on_device_or_absent "$receipt" "$state_device" \
    || [ -e "$receipt" ] || [ -L "$receipt" ] \
    || ! mv -f -- "$tmp" "$receipt"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_poll_retirement_receipt_valid "$state" "$id" || return 1
}

fm_pr_poll_retirement_recover_one() {
  local state=$1 id=$2 template=$3 receipt state_device check data registration
  local receipt_hash receipt_identity
  fm_pr_task_id_valid "$id" || return 1
  receipt="$state/$id.pr-poll-retirement"
  if [ ! -e "$receipt" ] && [ ! -L "$receipt" ]; then
    return 0
  fi
  if ! fm_pr_poll_retirement_state_valid "$state" "$id"; then
    fm_pr_poll_retirement_discard_obsolete "$state" "$id" "$template" && return 0
    return 1
  fi
  state_device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  receipt_hash=$FM_PR_RETIRE_RECEIPT_HASH
  receipt_identity=$FM_PR_RETIRE_RECEIPT_IDENTITY
  if [ -e "$check" ] || [ -L "$check" ]; then
    fm_pr_poll_retirement_remove_exact "$check" "$state_device" \
      "$FM_PR_RETIRE_CHECK_IDENTITY" "$FM_PR_RETIRE_TEMPLATE_HASH" || return 1
  fi
  if [ -e "$registration" ] || [ -L "$registration" ]; then
    fm_pr_poll_retirement_remove_exact "$registration" "$state_device" \
      "$FM_PR_RETIRE_REG_IDENTITY" "$FM_PR_RETIRE_REG_HASH" || return 1
  fi
  if [ -e "$data" ] || [ -L "$data" ]; then
    fm_pr_poll_retirement_remove_exact "$data" "$state_device" \
      "$FM_PR_RETIRE_DATA_IDENTITY" "$FM_PR_RETIRE_DATA_HASH" || return 1
  fi
  fm_pr_poll_retirement_remove_exact "$receipt" "$state_device" \
    "$receipt_identity" "$receipt_hash" || return 1
  [ ! -e "$check" ] && [ ! -L "$check" ] \
    && [ ! -e "$registration" ] && [ ! -L "$registration" ] \
    && [ ! -e "$data" ] && [ ! -L "$data" ] \
    && [ ! -e "$receipt" ] && [ ! -L "$receipt" ]
}

fm_pr_poll_retirement_recover_all() {
  local state=$1 template=$2 receipt id
  FM_PR_POLL_RETIREMENT_REJECTED=
  for receipt in "$state"/*.pr-poll-retirement; do
    [ -e "$receipt" ] || [ -L "$receipt" ] || continue
    id=$(basename "$receipt" .pr-poll-retirement)
    if ! fm_pr_task_id_valid "$id" \
      || ! fm_pr_poll_retirement_recover_one "$state" "$id" "$template"; then
      FM_PR_POLL_RETIREMENT_REJECTED="$FM_PR_POLL_RETIREMENT_REJECTED $receipt"
    fi
  done
  [ -z "$FM_PR_POLL_RETIREMENT_REJECTED" ]
}

# --- merge-notification canonical-identity marker ----------------------------
# A merged-PR poll retires (fm_pr_poll_retirement_recover_one) in the same
# watcher cycle that detects it, which is normally enough on its own to stop a
# duplicate detection: the check.sh is gone, so nothing re-polls it. The
# exception is the same poll re-registered after its merge was already
# surfaced. Its retirement state is scoped to one registration, so this marker
# carries the canonical PR identity across registrations for the task. Only a
# matching identity is a no-op; a different PR for the same task reaches its
# role-routed supervision destination and replaces the marker when its first
# outcome is published.
fm_pr_poll_merge_marker_matches() {  # <marker> <device> <provider> <host> <path> <number>
  local marker=$1 device=$2 expected_provider=$3 expected_host=$4 expected_path=$5 expected_number=$6
  local version provider host path number
  fm_pr_private_file_valid "$marker" 600 "$device" || return 1
  exec 8< "$marker" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  [ "$version" = fm-pr-poll-merge-notified-v1 ] \
    && [ "$provider" = "$expected_provider" ] \
    && [ "$host" = "$expected_host" ] \
    && [ "$path" = "$expected_path" ] \
    && [ "$number" = "$expected_number" ]
}

fm_pr_poll_merge_already_notified() {  # <state> <id> <provider> <host> <path> <number>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 marker state_device
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  marker="$state/$id.pr-poll-merge-notified"
  fm_pr_poll_merge_marker_matches "$marker" "$state_device" \
    "$provider" "$host" "$path" "$number"
}

fm_pr_poll_merge_mark_notified() {  # <state> <id> <provider> <host> <path> <number>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 marker tmp state_device
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  marker="$state/$id.pr-poll-merge-notified"
  fm_pr_regular_destination_on_device_or_absent "$marker" "$state_device" || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-pr-poll-merge-notified.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-merge-notified-v1 "$provider" "$host" "$path" "$number" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_poll_merge_marker_matches "$tmp" "$state_device" \
      "$provider" "$host" "$path" "$number" \
    || ! fm_pr_regular_destination_on_device_or_absent "$marker" "$state_device" \
    || ! mv -f -- "$tmp" "$marker" \
    || ! fm_pr_poll_merge_marker_matches "$marker" "$state_device" \
      "$provider" "$host" "$path" "$number"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Removed at teardown alongside the other per-task PR-poll artifacts
# (bin/fm-teardown.sh) so a retired task id leaves no residue behind.
fm_pr_poll_merge_notified_remove() {  # <state> <id>
  local state=$1 id=$2 marker
  fm_pr_task_id_valid "$id" || return 1
  marker="$state/$id.pr-poll-merge-notified"
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  rm -f -- "$marker"
}

# --- merge-queue ejection identity marker ------------------------------------
# The poll keeps emitting the same dequeued line while that ejection is current.
# This marker records the exact reason and forge timestamp already woken, so the
# watcher absorbs later identical polls without retiring the still-open watch.
# A later ejection with a new timestamp is a different identity and wakes again.
# bin/fm-pr-enqueue.sh owns the automatic re-queue bound separately.
fm_pr_poll_dequeued_line_parse() {  # <line>
  local line=$1 rest
  FM_PR_DEQUEUED_REASON=
  FM_PR_DEQUEUED_AT=
  case "$line" in
    dequeued:*) ;;
    *) return 1 ;;
  esac
  rest=${line#dequeued:}
  case "$rest" in
    *:*) ;;
    *) return 1 ;;
  esac
  FM_PR_DEQUEUED_REASON=${rest%%:*}
  FM_PR_DEQUEUED_AT=${rest#*:}
  [[ "$FM_PR_DEQUEUED_REASON" =~ ^[A-Za-z0-9_]+$ ]] || return 1
  [[ "$FM_PR_DEQUEUED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$ ]] || return 1
}

fm_pr_poll_lock_path() {  # <state> <id>
  local state=$1 id=$2
  fm_pr_task_id_valid "$id" || return 1
  [ -n "$state" ] || return 1
  case "$state" in *$'\n'*) return 1 ;; esac
  printf '%s/.pr-poll-%s.lock\n' "$state" "$id"
}

fm_pr_poll_dequeued_identity_parse() {  # <marker> <device>
  local marker=$1 device=$2 version provider host path number reason created
  FM_PR_DEQUEUED_PROVIDER=
  FM_PR_DEQUEUED_HOST=
  FM_PR_DEQUEUED_PATH=
  FM_PR_DEQUEUED_NUMBER=
  FM_PR_DEQUEUED_REASON=
  FM_PR_DEQUEUED_AT=
  fm_pr_private_file_valid "$marker" 600 "$device" || return 1
  exec 8< "$marker" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  IFS= read -r reason <&8 || { exec 8<&-; return 1; }
  IFS= read -r created <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  [ "$version" = fm-pr-poll-dequeued-v1 ] || return 1
  [ "$provider" = github ] || [ "$provider" = gitlab ] || return 1
  [ -n "$host" ] && [ -n "$path" ] || return 1
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$reason" =~ ^[A-Za-z0-9_]+$ ]] || return 1
  [[ "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$ ]] || return 1
  # Consumed by bin/fm-pr-enqueue.sh after sourcing this library.
  # shellcheck disable=SC2034
  FM_PR_DEQUEUED_PROVIDER=$provider
  # shellcheck disable=SC2034
  FM_PR_DEQUEUED_HOST=$host
  # shellcheck disable=SC2034
  FM_PR_DEQUEUED_PATH=$path
  # shellcheck disable=SC2034
  FM_PR_DEQUEUED_NUMBER=$number
  FM_PR_DEQUEUED_REASON=$reason
  FM_PR_DEQUEUED_AT=$created
}

fm_pr_poll_dequeued_marker_matches() {  # <marker> <device> <provider> <host> <path> <number> <reason> <created>
  local marker=$1 device=$2 expected_provider=$3 expected_host=$4 expected_path=$5
  local expected_number=$6 expected_reason=$7 expected_created=$8
  local version provider host path number reason created
  fm_pr_private_file_valid "$marker" 600 "$device" || return 1
  exec 8< "$marker" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  IFS= read -r reason <&8 || { exec 8<&-; return 1; }
  IFS= read -r created <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  [ "$version" = fm-pr-poll-dequeued-v1 ] \
    && [ "$provider" = "$expected_provider" ] \
    && [ "$host" = "$expected_host" ] \
    && [ "$path" = "$expected_path" ] \
    && [ "$number" = "$expected_number" ] \
    && [ "$reason" = "$expected_reason" ] \
    && [ "$created" = "$expected_created" ]
}

fm_pr_poll_dequeued_already_notified() {  # <state> <id> <provider> <host> <path> <number> <reason> <created>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 reason=$7 created=$8
  local marker state_device
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  marker="$state/$id.pr-poll-dequeued"
  fm_pr_poll_dequeued_marker_matches "$marker" "$state_device" \
    "$provider" "$host" "$path" "$number" "$reason" "$created"
}

fm_pr_poll_dequeued_mark_notified() {  # <state> <id> <provider> <host> <path> <number> <reason> <created>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 reason=$7 created=$8
  local marker tmp state_device
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  marker="$state/$id.pr-poll-dequeued"
  fm_pr_regular_destination_on_device_or_absent "$marker" "$state_device" || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-pr-poll-dequeued.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-dequeued-v1 "$provider" "$host" "$path" "$number" "$reason" "$created" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_poll_dequeued_marker_matches "$tmp" "$state_device" \
      "$provider" "$host" "$path" "$number" "$reason" "$created" \
    || ! fm_pr_regular_destination_on_device_or_absent "$marker" "$state_device" \
    || ! mv -f -- "$tmp" "$marker" \
    || ! fm_pr_poll_dequeued_marker_matches "$marker" "$state_device" \
      "$provider" "$host" "$path" "$number" "$reason" "$created"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_pr_poll_dequeued_remove() {  # <state> <id>
  local state=$1 id=$2 marker
  fm_pr_task_id_valid "$id" || return 1
  marker="$state/$id.pr-poll-dequeued"
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  rm -f -- "$marker"
}

# --- automatic enqueuePullRequest attempt marker -----------------------------
# One automatic re-queue is allowed per ejection: the armed PR identity together
# with the instant the forge recorded the removal, which is what the dequeued
# marker already treats as one ejection. The marker also carries how many
# automatic attempts this armed PR identity has already spent, across every
# ejection of it, because a delivery that fails deterministically inside the
# merge group is ejected again on each attempt and would otherwise be re-queued
# without end. bin/fm-pr-enqueue.sh is the only writer.
fm_pr_poll_enqueued_marker_parse() {  # <marker> <device>
  local marker=$1 device=$2 version provider host path number created count reason
  FM_PR_ENQUEUED_COUNT=
  FM_PR_ENQUEUED_REASON=
  FM_PR_ENQUEUED_PROVIDER=
  FM_PR_ENQUEUED_HOST=
  FM_PR_ENQUEUED_PATH=
  FM_PR_ENQUEUED_NUMBER=
  FM_PR_ENQUEUED_AT=
  fm_pr_private_file_valid "$marker" 600 "$device" || return 1
  exec 8< "$marker" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  IFS= read -r created <&8 || { exec 8<&-; return 1; }
  IFS= read -r count <&8 || { exec 8<&-; return 1; }
  IFS= read -r reason <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  [ "$version" = fm-pr-poll-enqueued-v1 ] || return 1
  case "$count" in
    [1-9]|[1-9][0-9]*) ;;
    *) return 1 ;;
  esac
  [[ "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$ ]] || return 1
  [[ "$reason" =~ ^[A-Za-z0-9_]+$ ]] || return 1
  FM_PR_ENQUEUED_COUNT=$count
  FM_PR_ENQUEUED_REASON=$reason
  FM_PR_ENQUEUED_PROVIDER=$provider
  FM_PR_ENQUEUED_HOST=$host
  FM_PR_ENQUEUED_PATH=$path
  FM_PR_ENQUEUED_NUMBER=$number
  FM_PR_ENQUEUED_AT=$created
}

fm_pr_poll_enqueued_already() {  # <state> <id> <provider> <host> <path> <number> <created>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 created=$7
  local marker state_device
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  marker="$state/$id.pr-poll-enqueued"
  fm_pr_poll_enqueued_marker_parse "$marker" "$state_device" || return 1
  [ "$FM_PR_ENQUEUED_PROVIDER" = "$provider" ] \
    && [ "$FM_PR_ENQUEUED_HOST" = "$host" ] \
    && [ "$FM_PR_ENQUEUED_PATH" = "$path" ] \
    && [ "$FM_PR_ENQUEUED_NUMBER" = "$number" ] \
    && [ "$FM_PR_ENQUEUED_AT" = "$created" ]
}

# How many automatic attempts this armed PR identity has already spent. A marker
# naming another pull request belongs to a previous delivery and counts as none.
fm_pr_poll_enqueued_attempts() {  # <state> <id> <provider> <host> <path> <number>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 marker state_device
  FM_PR_ENQUEUED_ATTEMPTS=0
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  marker="$state/$id.pr-poll-enqueued"
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 0
  fi
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_poll_enqueued_marker_parse "$marker" "$state_device" || return 1
  [ "$FM_PR_ENQUEUED_PROVIDER" = "$provider" ] \
    && [ "$FM_PR_ENQUEUED_HOST" = "$host" ] \
    && [ "$FM_PR_ENQUEUED_PATH" = "$path" ] \
    && [ "$FM_PR_ENQUEUED_NUMBER" = "$number" ] || return 0
  FM_PR_ENQUEUED_ATTEMPTS=$FM_PR_ENQUEUED_COUNT
}

fm_pr_poll_enqueued_mark() {  # <state> <id> <provider> <host> <path> <number> <created> <reason>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 created=$7 reason=$8
  local marker tmp state_device next
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  [[ "$reason" =~ ^[A-Za-z0-9_]+$ ]] || return 1
  # The count carried forward is what a readable marker already recorded. A
  # marker that cannot be read carries nothing, and the atomic write below
  # replaces it rather than refusing: a marker left unreadable is a marker that
  # bounds nothing.
  fm_pr_poll_enqueued_attempts "$state" "$id" "$provider" "$host" "$path" "$number" \
    || FM_PR_ENQUEUED_ATTEMPTS=0
  next=$((FM_PR_ENQUEUED_ATTEMPTS + 1))
  state_device=$(fm_pr_file_device "$state") || return 1
  marker="$state/$id.pr-poll-enqueued"
  fm_pr_regular_destination_on_device_or_absent "$marker" "$state_device" || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-pr-poll-enqueued.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-enqueued-v1 "$provider" "$host" "$path" "$number" "$created" "$next" "$reason" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_poll_enqueued_marker_parse "$tmp" "$state_device" \
    || [ "$FM_PR_ENQUEUED_COUNT" != "$next" ] \
    || [ "$FM_PR_ENQUEUED_REASON" != "$reason" ] \
    || ! fm_pr_regular_destination_on_device_or_absent "$marker" "$state_device" \
    || ! mv -f -- "$tmp" "$marker" \
    || ! fm_pr_poll_enqueued_already "$state" "$id" "$provider" "$host" "$path" "$number" "$created"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_pr_poll_enqueued_remove() {  # <state> <id>
  local state=$1 id=$2 marker
  fm_pr_task_id_valid "$id" || return 1
  marker="$state/$id.pr-poll-enqueued"
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  rm -f -- "$marker"
}
