#!/usr/bin/env bash
# Shared validation and atomic artifact helpers for merge polling on the
# supported forges and captain-bound GitHub PR presentation receipts. Callers
# must validate task IDs and raw PR/MR URLs before constructing task paths or
# performing any side effect.
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
FM_PR_REPLACE_ID=
FM_PR_REPLACE_PROVIDER=
FM_PR_REPLACE_URL=
FM_PR_REPLACE_HOST=
FM_PR_REPLACE_PATH=
FM_PR_REPLACE_NUMBER=
FM_PR_REPLACE_PRIOR_HEAD=
FM_PR_REPLACE_EXPECTED_HEAD=
FM_PR_REPLACE_DATA_HASH=
FM_PR_REPLACE_TEMPLATE_HASH=
FM_PR_REPLACE_DATA_IDENTITY=
FM_PR_REPLACE_CHECK_IDENTITY=
FM_PR_REPLACE_REG_HASH=
FM_PR_REPLACE_REG_IDENTITY=
FM_PR_REPLACE_RECEIPT_HASH=
FM_PR_REPLACE_RECEIPT_IDENTITY=
# shellcheck disable=SC2034 # Read by fm-pr-check.sh after sourcing this library.
FM_PR_POLL_REPLACEMENT_ACTIVE=0
# shellcheck disable=SC2034 # Read by fm-pr-check.sh after sourcing this library.
FM_PR_POLL_REPLACEMENT_COMPLETE=0
FM_PR_PRESENTATION_URL=
FM_PR_PRESENTATION_HEAD=
FM_PR_PRESENTATION_BASE_REF=
FM_PR_PRESENTATION_BASE=
FM_PR_PRESENTATION_NONCE=

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
# them empty; teaching the merge path about GitLab is a separate change, and
# until then it refuses a GitLab URL rather than merging anything.
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

fm_pr_toon_base64_field_parse() {
  local data=$1 key=$2 line encoded decoded count=0
  case "$key" in
    ''|*[!A-Za-z0-9_]*) return 1 ;;
  esac
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key":\ *)
        count=$((count + 1))
        encoded=${line#*: }
        ;;
    esac
  done <<< "$data"
  [ "$count" -eq 1 ] && [ -n "$encoded" ] || return 1
  [[ "$encoded" =~ ^[A-Za-z0-9+/]*={0,2}$ ]] || return 1
  [ $(( ${#encoded} % 4 )) -eq 0 ] || return 1
  if decoded=$(printf '%s' "$encoded" | base64 --decode 2>/dev/null); then
    :
  elif decoded=$(printf '%s' "$encoded" | base64 -D 2>/dev/null); then
    :
  else
    return 1
  fi
  [ -n "$decoded" ] || return 1
  printf '%s\n' "$decoded"
}

fm_pr_presentation_nonce_valid() {
  local nonce=${1-}
  local LC_ALL=C
  [[ "$nonce" =~ ^[0-9a-f]{32}$ ]]
}

fm_pr_presentation_nonce_new() {
  local nonce
  nonce=$(LC_ALL=C od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]') || return 1
  fm_pr_presentation_nonce_valid "$nonce" || return 1
  printf '%s\n' "$nonce"
}

fm_pr_presentation_lock_acquire() {
  local lockdir=$1 attempts=${FM_PR_PRESENTATION_LOCK_ATTEMPTS:-300} attempt=0 rc
  case "$attempts" in
    ''|*[!0-9]*) attempts=300 ;;
  esac
  [ "$attempts" -ge 1 ] && [ "$attempts" -le 600 ] || attempts=300
  while [ "$attempt" -lt "$attempts" ]; do
    if fm_lock_try_acquire "$lockdir"; then
      return 0
    else
      rc=$?
    fi
    [ "$rc" -eq 1 ] || return "$rc"
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$attempts" ] || break
    sleep 0.1
  done
  return 1
}

fm_pr_url_encode_ref_path() {
  local input=$1 output='' char value encoded i
  local LC_ALL=C
  for ((i = 0; i < ${#input}; i++)); do
    char=${input:i:1}
    case "$char" in
      [A-Za-z0-9._~/-]) output+=$char ;;
      *)
        printf -v value '%d' "'$char"
        printf -v encoded '%%%02X' "$value"
        output+=$encoded
        ;;
    esac
  done
  printf '%s\n' "$output"
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

fm_pr_fd_path() {
  local fd=$1
  if [ -e "/proc/$$/fd/$fd" ]; then
    printf '/proc/%s/fd/%s' "$$" "$fd"
  elif [ -e "/dev/fd/$fd" ]; then
    printf '/dev/fd/%s' "$fd"
  else
    return 1
  fi
}

fm_pr_fd_stat() {  # <format> <fd>
  local format=$1 fd=$2 path
  path=$(fm_pr_fd_path "$fd") || return 1
  if [ "$(uname)" = Darwin ]; then
    stat -Lf "$format" "$path" 2>/dev/null
  else
    stat -Lc "$format" "$path" 2>/dev/null
  fi
}

fm_pr_fd_identity() {
  local fd=$1 device inode
  device=$(fm_pr_fd_stat %d "$fd") || return 1
  inode=$(fm_pr_fd_stat %i "$fd") || return 1
  [ -n "$device" ] && [ -n "$inode" ] || return 1
  printf '%s:%s\n' "$device" "$inode"
}

fm_pr_fd_mode() {
  local fd=$1 path
  path=$(fm_pr_fd_path "$fd") || return 1
  if [ "$(uname)" = Darwin ]; then stat -Lf %Lp "$path" 2>/dev/null
  else stat -Lc %a "$path" 2>/dev/null; fi
}

fm_pr_fd_link_count() {
  local fd=$1 path
  path=$(fm_pr_fd_path "$fd") || return 1
  if [ "$(uname)" = Darwin ]; then stat -Lf %l "$path" 2>/dev/null
  else stat -Lc %h "$path" 2>/dev/null; fi
}

fm_pr_private_fd_valid() {
  local fd=$1 mode=$2 device=$3
  [ "$(fm_pr_fd_mode "$fd")" = "$mode" ] || return 1
  [ "$(fm_pr_fd_stat %d "$fd")" = "$device" ] || return 1
  [ "$(fm_pr_fd_link_count "$fd")" = 1 ]
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

# A presentation receipt is an immutable approval boundary: ordinary PR polls
# may refresh task metadata, but only fm-pr-present.sh may replace this file.
fm_pr_presentation_parse() {
  local file=$1 version url head base_ref base nonce _extra state_device path_identity fd_identity
  FM_PR_PRESENTATION_URL=
  FM_PR_PRESENTATION_HEAD=
  FM_PR_PRESENTATION_BASE_REF=
  FM_PR_PRESENTATION_BASE=
  FM_PR_PRESENTATION_NONCE=
  [ ! -L "$file" ] || return 1
  state_device=$(fm_pr_file_device "$(dirname "$file")") || return 1
  exec 8< "$file" || return 1
  if ! fm_pr_private_fd_valid 8 600 "$state_device" \
    || [ -L "$file" ] \
    || ! path_identity=$(fm_pr_file_identity "$file") \
    || ! fd_identity=$(fm_pr_fd_identity 8) \
    || [ "$path_identity" != "$fd_identity" ]; then
    exec 8<&-
    return 1
  fi
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r url <&8 || { exec 8<&-; return 1; }
  IFS= read -r head <&8 || { exec 8<&-; return 1; }
  IFS= read -r base_ref <&8 || { exec 8<&-; return 1; }
  IFS= read -r base <&8 || { exec 8<&-; return 1; }
  IFS= read -r nonce <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then exec 8<&-; return 1; fi
  exec 8<&-
  [ "$version" = firstmate-pr-presentation-v2 ] || return 1
  case "$url" in pr=*) url=${url#pr=} ;; *) return 1 ;; esac
  case "$head" in presented_pr_head=*) head=${head#presented_pr_head=} ;; *) return 1 ;; esac
  case "$base_ref" in presented_pr_base_ref=*) base_ref=${base_ref#presented_pr_base_ref=} ;; *) return 1 ;; esac
  case "$base" in presented_pr_base=*) base=${base#presented_pr_base=} ;; *) return 1 ;; esac
  case "$nonce" in presentation_nonce=*) nonce=${nonce#presentation_nonce=} ;; *) return 1 ;; esac
  fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ] || return 1
  fm_pr_head_valid "$head" && fm_pr_head_valid "$base" \
    && git check-ref-format "refs/heads/$base_ref" >/dev/null 2>&1 \
    && fm_pr_presentation_nonce_valid "$nonce" || return 1
  FM_PR_PRESENTATION_URL=$FM_PR_URL
  FM_PR_PRESENTATION_HEAD=$head
  FM_PR_PRESENTATION_BASE_REF=$base_ref
  FM_PR_PRESENTATION_BASE=$base
  FM_PR_PRESENTATION_NONCE=$nonce
}

fm_pr_presentation_cleanup_parse() {
  local file=$1 version url head _extra state_device path_identity fd_identity
  if fm_pr_presentation_parse "$file"; then
    return 0
  fi
  FM_PR_PRESENTATION_URL=
  FM_PR_PRESENTATION_HEAD=
  FM_PR_PRESENTATION_BASE_REF=
  FM_PR_PRESENTATION_BASE=
  FM_PR_PRESENTATION_NONCE=
  [ ! -L "$file" ] || return 1
  state_device=$(fm_pr_file_device "$(dirname "$file")") || return 1
  exec 8< "$file" || return 1
  if ! fm_pr_private_fd_valid 8 600 "$state_device" \
    || [ -L "$file" ] \
    || ! path_identity=$(fm_pr_file_identity "$file") \
    || ! fd_identity=$(fm_pr_fd_identity 8) \
    || [ "$path_identity" != "$fd_identity" ]; then
    exec 8<&-
    return 1
  fi
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r url <&8 || { exec 8<&-; return 1; }
  IFS= read -r head <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then exec 8<&-; return 1; fi
  exec 8<&-
  [ "$version" = firstmate-pr-presentation-v1 ] || return 1
  case "$url" in pr=*) url=${url#pr=} ;; *) return 1 ;; esac
  case "$head" in presented_pr_head=*) head=${head#presented_pr_head=} ;; *) return 1 ;; esac
  fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ] && fm_pr_head_valid "$head" || return 1
  FM_PR_PRESENTATION_URL=$FM_PR_URL
  FM_PR_PRESENTATION_HEAD=$head
}

fm_pr_presentation_publish() {
  local state=$1 id=$2 url=$3 head=$4 base_ref=$5 base=$6 nonce=$7 dest tmp state_device canonical_url
  fm_pr_task_id_valid "$id" && fm_pr_url_parse "$url" \
    && [ "$FM_PR_PROVIDER" = github ] && fm_pr_head_valid "$head" \
    && git check-ref-format "refs/heads/$base_ref" >/dev/null 2>&1 \
    && fm_pr_head_valid "$base" && fm_pr_presentation_nonce_valid "$nonce" || return 1
  canonical_url=$FM_PR_URL
  dest="$state/$id.pr-presentation"
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_regular_destination_on_device_or_absent "$dest" "$state_device" || return 1
  tmp=$(mktemp "$state/.fm-pr-presentation.XXXXXX") || return 1
  if ! printf 'firstmate-pr-presentation-v2\npr=%s\npresented_pr_head=%s\npresented_pr_base_ref=%s\npresented_pr_base=%s\npresentation_nonce=%s\n' \
      "$canonical_url" "$head" "$base_ref" "$base" "$nonce" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$state_device" \
    || ! fm_pr_presentation_parse "$tmp" \
    || [ "$FM_PR_PRESENTATION_URL" != "$canonical_url" ] \
    || [ "$FM_PR_PRESENTATION_HEAD" != "$head" ] \
    || [ "$FM_PR_PRESENTATION_BASE_REF" != "$base_ref" ] \
    || [ "$FM_PR_PRESENTATION_BASE" != "$base" ] \
    || [ "$FM_PR_PRESENTATION_NONCE" != "$nonce" ] \
    || ! mv -f -- "$tmp" "$dest" \
    || ! fm_pr_presentation_parse "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_pr_presentation_invalidate() {
  local state=$1 id=$2 dest state_device
  fm_pr_task_id_valid "$id" || return 1
  dest="$state/$id.pr-presentation"
  [ -e "$dest" ] || [ -L "$dest" ] || return 0
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$dest" 600 "$state_device" || return 1
  rm -f -- "$dest"
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
      # Teardown appends its own pooled-slot state after the PR identity. These
      # lines carry no PR identity, so they are tolerated rather than read as
      # tampering with the record.
      slot_returned=*|slot_returning=*)
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
# by the previous release is recognised as old and refused. The non-executing
# migration in bin/fm-pr-check-migrate.sh then rebuilds that poll from the
# task's recorded pull request URL.
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

# A guarded direct-PR replacement cannot atomically rename its three poll
# files. This receipt instead makes every crash point recoverable. It binds the
# exact old generation and the expected new head. Recovery removes only a
# validated old or partial-new generation, then deterministically republishes
# the expected generation.
fm_pr_poll_replacement_parse() {
  local file=$1 version id provider url host path number prior_head expected_head
  local data_hash template_hash data_identity check_identity reg_hash reg_identity _extra
  FM_PR_REPLACE_ID=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 8< "$file" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r id <&8 || { exec 8<&-; return 1; }
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r url <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  IFS= read -r prior_head <&8 || { exec 8<&-; return 1; }
  IFS= read -r expected_head <&8 || { exec 8<&-; return 1; }
  IFS= read -r data_hash <&8 || { exec 8<&-; return 1; }
  IFS= read -r template_hash <&8 || { exec 8<&-; return 1; }
  IFS= read -r data_identity <&8 || { exec 8<&-; return 1; }
  IFS= read -r check_identity <&8 || { exec 8<&-; return 1; }
  IFS= read -r reg_hash <&8 || { exec 8<&-; return 1; }
  IFS= read -r reg_identity <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then exec 8<&-; return 1; fi
  exec 8<&-
  [ "$version" = fm-pr-poll-replacement-v1 ] || return 1
  fm_pr_task_id_valid "$id" && fm_pr_url_parse "$url" || return 1
  [ "$provider" = "$FM_PR_PROVIDER" ] && [ "$host" = "$FM_PR_HOST" ] \
    && [ "$path" = "$FM_PR_PATH" ] && [ "$number" = "$FM_PR_NUMBER" ] || return 1
  fm_pr_head_valid "$prior_head" && fm_pr_head_valid "$expected_head" \
    && [ "$prior_head" != "$expected_head" ] || return 1
  [[ "$data_hash" =~ ^[0-9a-f]{64}$ ]] && [[ "$template_hash" =~ ^[0-9a-f]{64}$ ]] \
    && [[ "$data_identity" =~ ^[0-9]+:[0-9]+$ ]] \
    && [[ "$check_identity" =~ ^[0-9]+:[0-9]+$ ]] \
    && [[ "$reg_hash" =~ ^[0-9a-f]{64}$ ]] \
    && [[ "$reg_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  FM_PR_REPLACE_ID=$id
  FM_PR_REPLACE_PROVIDER=$provider
  FM_PR_REPLACE_URL=$url
  FM_PR_REPLACE_HOST=$host
  FM_PR_REPLACE_PATH=$path
  FM_PR_REPLACE_NUMBER=$number
  FM_PR_REPLACE_PRIOR_HEAD=$prior_head
  FM_PR_REPLACE_EXPECTED_HEAD=$expected_head
  FM_PR_REPLACE_DATA_HASH=$data_hash
  FM_PR_REPLACE_TEMPLATE_HASH=$template_hash
  FM_PR_REPLACE_DATA_IDENTITY=$data_identity
  FM_PR_REPLACE_CHECK_IDENTITY=$check_identity
  FM_PR_REPLACE_REG_HASH=$reg_hash
  FM_PR_REPLACE_REG_IDENTITY=$reg_identity
}

fm_pr_poll_replacement_receipt_valid() {
  local state=$1 id=$2 expected_head=$3 receipt state_device meta recorded_head count=0
  receipt="$state/$id.pr-poll-replacement"
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$receipt" 600 "$state_device" || return 1
  fm_pr_poll_replacement_parse "$receipt" || return 1
  [ "$FM_PR_REPLACE_ID" = "$id" ] && [ "$FM_PR_REPLACE_EXPECTED_HEAD" = "$expected_head" ] || return 1
  meta="$state/$id.meta"
  fm_pr_metadata_identity_parse "$meta" || return 1
  [ "$FM_PR_META_PROVIDER" = "$FM_PR_REPLACE_PROVIDER" ] \
    && [ "$FM_PR_META_URL" = "$FM_PR_REPLACE_URL" ] \
    && [ "$FM_PR_META_HOST" = "$FM_PR_REPLACE_HOST" ] \
    && [ "$FM_PR_META_PATH" = "$FM_PR_REPLACE_PATH" ] \
    && [ "$FM_PR_META_NUMBER" = "$FM_PR_REPLACE_NUMBER" ] || return 1
  recorded_head=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in pr_head=*) count=$((count + 1)); recorded_head=${line#pr_head=} ;; esac
  done < "$meta"
  [ "$count" -eq 1 ] \
    && { [ "$recorded_head" = "$FM_PR_REPLACE_PRIOR_HEAD" ] \
      || [ "$recorded_head" = "$FM_PR_REPLACE_EXPECTED_HEAD" ]; } || return 1
  FM_PR_REPLACE_RECEIPT_HASH=$(fm_pr_sha256 "$receipt") || return 1
  FM_PR_REPLACE_RECEIPT_IDENTITY=$(fm_pr_file_identity "$receipt") || return 1
}

fm_pr_poll_replacement_publish() {
  local state=$1 id=$2 prior_head=$3 expected_head=$4 receipt tmp state_device
  fm_pr_poll_snapshot_matches "$state" "$id" "$FM_PR_POLL_TEMPLATE" || return 1
  [ "$FM_PR_POLL_SNAPSHOT_ID" = "$id" ] || return 1
  fm_pr_head_valid "$prior_head" && fm_pr_head_valid "$expected_head" \
    && [ "$prior_head" != "$expected_head" ] || return 1
  receipt="$state/$id.pr-poll-replacement"
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_regular_destination_on_device_or_absent "$receipt" "$state_device" || return 1
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ] || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-pr-poll-replacement.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-replacement-v1 "$id" "$FM_PR_POLL_SNAPSHOT_PROVIDER" \
      "$FM_PR_POLL_SNAPSHOT_URL" "$FM_PR_POLL_SNAPSHOT_HOST" \
      "$FM_PR_POLL_SNAPSHOT_PATH" "$FM_PR_POLL_SNAPSHOT_NUMBER" \
      "$prior_head" "$expected_head" "$FM_PR_POLL_SNAPSHOT_DATA_HASH" \
      "$FM_PR_POLL_SNAPSHOT_TEMPLATE_HASH" "$FM_PR_POLL_SNAPSHOT_DATA_IDENTITY" \
      "$FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY" "$FM_PR_POLL_SNAPSHOT_REG_HASH" \
      "$FM_PR_POLL_SNAPSHOT_REG_IDENTITY" > "$tmp" \
    || ! chmod 0600 "$tmp" || ! fm_pr_private_file_valid "$tmp" 600 "$state_device" \
    || ! fm_pr_poll_replacement_parse "$tmp" || [ "$FM_PR_REPLACE_ID" != "$id" ] \
    || ! fm_pr_poll_snapshot_matches "$state" "$id" "$FM_PR_POLL_TEMPLATE" \
    || ! mv -f -- "$tmp" "$receipt"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_poll_replacement_receipt_valid "$state" "$id" "$expected_head"
}

fm_pr_poll_replacement_old_state_valid() {
  local state=$1 id=$2 check data registration hc=0 hd=0 hr=0 state_device
  state_device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"; data="$state/$id.pr-poll"; registration="$state/$id.pr-poll-registration"
  [ ! -e "$check" ] && [ ! -L "$check" ] || hc=1
  [ ! -e "$data" ] && [ ! -L "$data" ] || hd=1
  [ ! -e "$registration" ] && [ ! -L "$registration" ] || hr=1
  if [ "$hc" -eq 1 ]; then
    [ "$hd" -eq 1 ] && [ "$hr" -eq 1 ] || return 1
    fm_pr_private_file_valid "$check" 600 "$state_device" \
      && [ "$(fm_pr_sha256 "$check")" = "$FM_PR_REPLACE_TEMPLATE_HASH" ] \
      && [ "$(fm_pr_file_identity "$check")" = "$FM_PR_REPLACE_CHECK_IDENTITY" ] || return 1
  fi
  if [ "$hr" -eq 1 ]; then
    [ "$hd" -eq 1 ] || return 1
    fm_pr_private_file_valid "$registration" 600 "$state_device" \
      && [ "$(fm_pr_sha256 "$registration")" = "$FM_PR_REPLACE_REG_HASH" ] \
      && [ "$(fm_pr_file_identity "$registration")" = "$FM_PR_REPLACE_REG_IDENTITY" ] || return 1
  fi
  if [ "$hd" -eq 1 ]; then
    fm_pr_private_file_valid "$data" 600 "$state_device" \
      && [ "$(fm_pr_sha256 "$data")" = "$FM_PR_REPLACE_DATA_HASH" ] \
      && [ "$(fm_pr_file_identity "$data")" = "$FM_PR_REPLACE_DATA_IDENTITY" ] || return 1
  fi
}

fm_pr_poll_replacement_partial_new_valid() {
  local state=$1 id=$2 template=$3 state_device check data registration hc=0 hd=0 hr=0
  local data_hash data_identity check_hash check_identity
  state_device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"; data="$state/$id.pr-poll"; registration="$state/$id.pr-poll-registration"
  [ ! -e "$check" ] && [ ! -L "$check" ] || hc=1
  [ ! -e "$data" ] && [ ! -L "$data" ] || hd=1
  [ ! -e "$registration" ] && [ ! -L "$registration" ] || hr=1
  [ "$hc" -eq 0 ] || { [ "$hd" -eq 1 ] && [ "$hr" -eq 1 ]; } || return 1
  [ "$hr" -eq 0 ] || [ "$hd" -eq 1 ] || return 1
  if [ "$data" ] && [ "$hd" -eq 1 ]; then
    fm_pr_private_file_valid "$data" 600 "$state_device" && fm_pr_poll_data_parse "$data" \
      && [ "$FM_PR_DATA_PROVIDER" = "$FM_PR_REPLACE_PROVIDER" ] \
      && [ "$FM_PR_DATA_URL" = "$FM_PR_REPLACE_URL" ] || return 1
    data_hash=$(fm_pr_sha256 "$data") || return 1
    data_identity=$(fm_pr_file_identity "$data") || return 1
  fi
  if [ "$hc" -eq 1 ]; then
    fm_pr_private_file_valid "$check" 600 "$state_device" && cmp -s "$template" "$check" || return 1
    check_hash=$(fm_pr_sha256 "$check") || return 1
    check_identity=$(fm_pr_file_identity "$check") || return 1
  fi
  if [ "$hr" -eq 1 ]; then
    fm_pr_private_file_valid "$registration" 600 "$state_device" \
      && fm_pr_poll_registration_parse "$registration" \
      && [ "$FM_PR_REG_ID" = "$id" ] && [ "$FM_PR_REG_URL" = "$FM_PR_REPLACE_URL" ] \
      && [ "$FM_PR_REG_DATA_HASH" = "$data_hash" ] \
      && [ "$FM_PR_REG_DATA_IDENTITY" = "$data_identity" ] || return 1
    if [ "$hc" -eq 1 ]; then
      [ "$FM_PR_REG_TEMPLATE_HASH" = "$check_hash" ] \
        && [ "$FM_PR_REG_CHECK_IDENTITY" = "$check_identity" ] || return 1
    fi
  fi
}

fm_pr_poll_replacement_remove_present() {
  local state=$1 id=$2 state_device path hash identity suffix
  state_device=$(fm_pr_file_device "$state") || return 1
  for suffix in check.sh pr-poll-registration pr-poll; do
    path="$state/$id.$suffix"
    [ -e "$path" ] || [ -L "$path" ] || continue
    hash=$(fm_pr_sha256 "$path") && identity=$(fm_pr_file_identity "$path") || return 1
    fm_pr_poll_retirement_remove_exact "$path" "$state_device" "$identity" "$hash" || return 1
  done
}

fm_pr_poll_replacement_finish() {
  local state=$1 id=$2 template=$3 expected_head=$4 receipt state_device
  fm_pr_poll_replacement_receipt_valid "$state" "$id" "$expected_head" || return 1
  fm_pr_poll_artifacts_valid "$state" "$id" "$template" || return 1
  [ "$FM_PR_DATA_URL" = "$FM_PR_REPLACE_URL" ] || return 1
  receipt="$state/$id.pr-poll-replacement"
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_poll_retirement_remove_exact "$receipt" "$state_device" \
    "$FM_PR_REPLACE_RECEIPT_IDENTITY" "$FM_PR_REPLACE_RECEIPT_HASH"
}

fm_pr_poll_replacement_recover_one() {
  local state=$1 id=$2 template=$3 expected_head=$4 receipt artifact_count=0 artifact
  FM_PR_POLL_REPLACEMENT_ACTIVE=0
  FM_PR_POLL_REPLACEMENT_COMPLETE=0
  receipt="$state/$id.pr-poll-replacement"
  [ -e "$receipt" ] || [ -L "$receipt" ] || return 0
  fm_pr_poll_replacement_receipt_valid "$state" "$id" "$expected_head" || return 1
  FM_PR_POLL_REPLACEMENT_ACTIVE=1
  if fm_pr_poll_artifacts_valid "$state" "$id" "$template"; then
    if grep -qxF "pr_head=$expected_head" "$state/$id.meta"; then
      fm_pr_poll_replacement_finish "$state" "$id" "$template" "$expected_head" || return 1
      # shellcheck disable=SC2034 # Read by fm-pr-check.sh after this helper returns.
      FM_PR_POLL_REPLACEMENT_ACTIVE=0
      # shellcheck disable=SC2034 # Read by fm-pr-check.sh after this helper returns.
      FM_PR_POLL_REPLACEMENT_COMPLETE=1
      return 0
    fi
  fi
  for artifact in "$state/$id.check.sh" "$state/$id.pr-poll" "$state/$id.pr-poll-registration"; do
    [ ! -e "$artifact" ] && [ ! -L "$artifact" ] || artifact_count=$((artifact_count + 1))
  done
  [ "$artifact_count" -eq 0 ] && return 0
  if fm_pr_poll_replacement_old_state_valid "$state" "$id" \
    || fm_pr_poll_replacement_partial_new_valid "$state" "$id" "$template"; then
    fm_pr_poll_replacement_remove_present "$state" "$id" || return 1
    return 0
  fi
  return 1
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
