#!/usr/bin/env bash
# Shared PR/MR record reads, validation, and atomic artifact helpers for merge
# polling on the supported forges. Callers must validate task IDs and raw PR/MR
# URLs before constructing task paths or performing any side effect.
#
# The stored identity is provider-tagged: provider, url, host, path, number.
# "path" is the full project path, which is owner/repository on GitHub,
# workspace/repository on Bitbucket Cloud, an arbitrarily nested
# group/subgroup/project namespace on GitLab, and an arbitrarily nested project
# name on Gerrit, where "number" is the change number. A GitLab or Gerrit project can sit at any depth, so no
# owner/repository pair can address one and the sidecar carries the whole path
# instead. Both also run on self-hosted instances, and Gerrit runs nowhere else,
# so the host is part of that identity rather than a constant. Every consumer re-derives the identity
# from the stored URL and refuses any record whose parts do not reconstruct that
# exact URL.
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
FM_PR_POLL_REARM_DATA_IDENTITY=
FM_PR_POLL_REARM_CHECK_IDENTITY=
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
FM_PR_RECORD_STATE=
FM_PR_RECORD_MERGED=
FM_PR_POLL_RETIREMENT_REJECTED=
FM_PR_BITBUCKET_STATUS=
FM_PR_BITBUCKET_BODY=
FM_PR_BITBUCKET_VALUES=
FM_PR_BITBUCKET_STATE=
FM_PR_BITBUCKET_DRAFT=
FM_PR_BITBUCKET_HEAD=
FM_PR_BITBUCKET_HEAD_REPORTED=
FM_PR_BITBUCKET_SOURCE_BRANCH=
FM_PR_BITBUCKET_DEST_BRANCH=
FM_PR_BITBUCKET_JSON=

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

# GitLab and Gerrit both serve self-hosted instances, so the host is part of the
# identity rather than a constant. It is accepted only as a lowercase DNS name
# with no userinfo, port, or trailing dot, which keeps one canonical spelling per
# change. github.com and bitbucket.org are refused here even though their shape
# is otherwise valid: each is its own forge's only host and never another
# forge's instance, so a URL like https://github.com/o/r/-/merge_requests/1 (a
# typo'd or spoofed GitHub URL) would otherwise be armed as a watch that can
# never succeed.
fm_pr_forge_host_valid() {
  local host=${1-} label
  local LC_ALL=C
  local -a labels
  [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || return 1
  [ "$host" != github.com ] && [ "$host" != bitbucket.org ] || return 1
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

# A Gerrit project name is itself a path at no fixed depth, and it needs no
# enclosing group, so a single segment is canonical here where GitLab needs at
# least two. Gerrit reserves no route segment inside the name, so nothing
# corresponds to GitLab's "-": the change URL's literal "/+/" is what ends the
# project instead. A ".git" suffix is refused because Gerrit strips it and the
# stripped name is the canonical one, and a leading hyphen is refused because a
# project path is what names the project to any CLI that takes one, where a
# leading hyphen reads as an option instead.
fm_pr_gerrit_path_valid() {
  local path=${1-} segment
  local LC_ALL=C
  local -a segments
  [ "${#path}" -ge 1 ] && [ "${#path}" -le 1024 ] || return 1
  case "$path" in
    /*|*/|*//*) return 1 ;;
  esac
  IFS=/ read -ra segments <<< "$path"
  [ "${#segments[@]}" -ge 1 ] && [ "${#segments[@]}" -le 20 ] || return 1
  for segment in "${segments[@]}"; do
    [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || return 1
    case "$segment" in
      .|..|-*|*.git|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
  done
}

# A Bitbucket Cloud workspace ID is lowercase letters, digits, "-", and "_", and
# a repository slug additionally allows ".", so each has exactly one canonical
# spelling, which is the one the API's own pull request links use. A leading
# hyphen is refused because a path segment must never read as an option, and
# "." and ".." never name a repository.
fm_pr_bitbucket_path_valid() {
  local path=${1-} workspace repo
  local LC_ALL=C
  case "$path" in
    */*/*|/*|*/) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  workspace=${path%%/*}
  repo=${path#*/}
  [ "${#workspace}" -ge 1 ] && [ "${#workspace}" -le 100 ] || return 1
  [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || return 1
  case "$workspace" in
    -*|*[!a-z0-9_-]*) return 1 ;;
  esac
  case "$repo" in
    .|..|-*|*[!a-z0-9._-]*) return 1 ;;
  esac
}

# Parse a canonical pull request, merge request, or Gerrit change URL into the
# provider-tagged identity. Validation is strict and per provider: the GitHub
# username and repository rules are unchanged, and Bitbucket, GitLab, and
# Gerrit each get their own namespace rules rather than a loosened GitHub rule.
#
# FM_PR_OWNER and FM_PR_REPO are additionally set for github because
# bin/fm-pr-merge.sh addresses GitHub by owner/repository. A bitbucket, gitlab,
# or gerrit URL leaves them empty, and those paths address the project by
# FM_PR_HOST and FM_PR_PATH instead, so a change on any instance resolves
# without a hardcoded host. Bitbucket Cloud has one host, so its URL is
# https://bitbucket.org/<workspace>/<repository>/pull-requests/<number> and
# nothing else; a Bitbucket Data Center URL is not one and is refused.
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
  pattern='^https://bitbucket\.org/([^/]+/[^/]+)/pull-requests/([1-9][0-9]*)$'
  if [[ "$raw" =~ $pattern ]]; then
    path=${BASH_REMATCH[1]}
    fm_pr_bitbucket_path_valid "$path" || return 1
    FM_PR_PROVIDER=bitbucket
    FM_PR_URL=$raw
    FM_PR_HOST=bitbucket.org
    FM_PR_PATH=$path
    FM_PR_NUMBER=${BASH_REMATCH[2]}
    return 0
  fi
  # The path class contains "/" and "-", so this match is greedy to the last
  # "/-/merge_requests/". Any earlier separator therefore lands inside the
  # captured path, where the reserved "-" segment is refused.
  pattern='^https://([a-z0-9.-]{1,253})/([A-Za-z0-9._/-]+)/-/merge_requests/([1-9][0-9]*)$'
  if [[ "$raw" =~ $pattern ]]; then
    host=${BASH_REMATCH[1]}
    path=${BASH_REMATCH[2]}
    fm_pr_forge_host_valid "$host" || return 1
    fm_pr_gitlab_path_valid "$path" || return 1
    FM_PR_PROVIDER=gitlab
    FM_PR_URL=$raw
    FM_PR_HOST=$host
    FM_PR_PATH=$path
    FM_PR_NUMBER=${BASH_REMATCH[3]}
    return 0
  fi
  # A Gerrit change URL is https://<host>/c/<project>/+/<number>. "+" is outside
  # the path class, so the project can never contain the "/+/" separator and this
  # match needs no greediness argument: a second "/+/" makes the URL match
  # nothing rather than splitting somewhere else. The project keeps its whole
  # nested path for the same reason GitLab's does, so it is never flattened into
  # an owner/repository pair that cannot address it.
  pattern='^https://([a-z0-9.-]{1,253})/c/([A-Za-z0-9._/-]+)/\+/([1-9][0-9]*)$'
  [[ "$raw" =~ $pattern ]] || return 1
  host=${BASH_REMATCH[1]}
  path=${BASH_REMATCH[2]}
  fm_pr_forge_host_valid "$host" || return 1
  fm_pr_gerrit_path_valid "$path" || return 1
  FM_PR_PROVIDER=gerrit
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

# The one reading of a GitHub pull request's draft state. Prints "true" or
# "false" for a boolean isDraft and nothing for anything else, so a caller can
# tell a positive draft from an unreadable payload. bin/fm-pr-merge.sh refuses
# a merge unless this prints "false"; bin/fm-pr-check.sh refuses to arm a merge
# poll only when it prints "true".
fm_pr_json_draft_state() {  # <pull-request-json>
  printf '%s' "${1-}" | jq -r '
    if type == "object" and (.isDraft | type) == "boolean" then (.isDraft | tostring) else "" end
  ' 2>/dev/null || true
}

fm_pr_file_mode() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

fm_pr_file_device() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %d "$1" 2>/dev/null
  else
    stat -c %d "$1" 2>/dev/null
  fi
}

fm_pr_file_link_count() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_pr_file_inode() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %i "$1" 2>/dev/null
  else
    stat -c %i "$1" 2>/dev/null
  fi
}

# device:inode names one file object, since an inode number is unique only
# within its filesystem. The device part is not stable across a volume remount:
# APFS can renumber st_dev on reboot while every inode and byte is unchanged, so
# an identity persisted before the remount no longer matches the live file
# (fm_pr_poll_registration_rerecord_device).
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

# Callers pass the containing directory's device read in the same invocation,
# never a persisted one, so this compares two live readings and survives a
# remount that renumbers the volume. It refuses a file that is not on that
# directory's own filesystem, such as one bind-mounted over the name, which is
# also what keeps same-directory rename publication atomic.
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

# The caller holds the task's poll publication lock while publishing this
# prepared generation, so no registration can name another generation's files.
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
  local state=$1 id=$2 template=$3 data_identity check_identity
  fm_pr_poll_artifacts_content_valid "$state" "$id" "$template" || return 1
  data_identity=$(fm_pr_file_identity "$state/$id.pr-poll") || return 1
  check_identity=$(fm_pr_file_identity "$state/$id.check.sh") || return 1
  # The recorded identities bind the registration to the exact sidecar and
  # check file objects published in its own transaction, so a byte-identical
  # replacement or a torn re-arm pairing one generation's check with another's
  # registration is refused.
  [ "$FM_PR_REG_DATA_IDENTITY" = "$data_identity" ] || return 1
  [ "$FM_PR_REG_CHECK_IDENTITY" = "$check_identity" ]
}

# Everything fm_pr_poll_artifacts_valid proves except that the registration's
# recorded file identities name the live sidecar and check. Success alone is
# never authentication. On success FM_PR_DATA_*, FM_PR_REG_*, and FM_PR_META_*
# hold the parsed records.
fm_pr_poll_artifacts_content_valid() {
  local state=$1 id=$2 template=$3 state_device check data registration meta data_hash template_hash
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
  fm_pr_poll_registration_parse "$registration" || return 1
  [ "$FM_PR_REG_ID" = "$id" ] || return 1
  [ "$FM_PR_REG_PROVIDER" = "$FM_PR_DATA_PROVIDER" ] || return 1
  [ "$FM_PR_REG_URL" = "$FM_PR_DATA_URL" ] || return 1
  [ "$FM_PR_REG_HOST" = "$FM_PR_DATA_HOST" ] || return 1
  [ "$FM_PR_REG_PATH" = "$FM_PR_DATA_PATH" ] || return 1
  [ "$FM_PR_REG_NUMBER" = "$FM_PR_DATA_NUMBER" ] || return 1
  [ "$FM_PR_REG_DATA_HASH" = "$data_hash" ] || return 1
  [ "$FM_PR_REG_TEMPLATE_HASH" = "$template_hash" ] || return 1
  fm_pr_metadata_identity_parse "$meta" || return 1
  [ "$FM_PR_META_PROVIDER" = "$FM_PR_DATA_PROVIDER" ] || return 1
  [ "$FM_PR_META_URL" = "$FM_PR_DATA_URL" ] || return 1
  [ "$FM_PR_META_HOST" = "$FM_PR_DATA_HOST" ] || return 1
  [ "$FM_PR_META_PATH" = "$FM_PR_DATA_PATH" ] || return 1
  [ "$FM_PR_META_NUMBER" = "$FM_PR_DATA_NUMBER" ]
}

# A registration armed before a volume remount can name a device number the
# kernel has since reassigned (fm_pr_file_identity). This proves that is the
# only difference: every artifact passes fm_pr_poll_artifacts_content_valid, so
# the check is byte-identical to the template, both hashes match, and the three
# poll artifacts are private, single-link, and on the state directory's live
# device; both recorded identities name one device; each recorded inode equals
# its live inode; and that recorded device differs from the live one. A
# replaced, altered, re-moded, relinked, or foreign-device artifact fails a proof
# here and stays refused. A pending retirement receipt owns its artifacts, so
# none is re-recorded while one exists. On success
# FM_PR_POLL_REARM_DATA_IDENTITY and FM_PR_POLL_REARM_CHECK_IDENTITY hold the
# live identities.
fm_pr_poll_registration_device_shifted() {  # <state> <id> <template>
  local state=$1 id=$2 template=$3 state_device recorded_device receipt data_identity check_identity
  FM_PR_POLL_REARM_DATA_IDENTITY=
  FM_PR_POLL_REARM_CHECK_IDENTITY=
  fm_pr_task_id_valid "$id" || return 1
  [ -f "$state/$id.pr-poll-registration" ] || return 1
  receipt="$state/$id.pr-poll-retirement"
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ] || return 1
  fm_pr_poll_artifacts_content_valid "$state" "$id" "$template" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  data_identity=$(fm_pr_file_identity "$state/$id.pr-poll") || return 1
  check_identity=$(fm_pr_file_identity "$state/$id.check.sh") || return 1
  recorded_device=${FM_PR_REG_DATA_IDENTITY%%:*}
  [ "${FM_PR_REG_CHECK_IDENTITY%%:*}" = "$recorded_device" ] || return 1
  [ "$recorded_device" != "$state_device" ] || return 1
  [ "$data_identity" = "$state_device:${FM_PR_REG_DATA_IDENTITY#*:}" ] || return 1
  [ "$check_identity" = "$state_device:${FM_PR_REG_CHECK_IDENTITY#*:}" ] || return 1
  FM_PR_POLL_REARM_DATA_IDENTITY=$data_identity
  FM_PR_POLL_REARM_CHECK_IDENTITY=$check_identity
}

# Rewrite a device-shifted registration (fm_pr_poll_registration_device_shifted)
# so it names the live device, changing no other line. The caller holds the
# task's control lock and poll publication lock, which serialize this with the
# watcher's validated check and retirement, teardown, bin/fm-pr-merge.sh, and
# direct bin/fm-pr-check.sh publication. The proof is repeated just before the
# rename, which proceeds only while the registration is still the exact file
# object and bytes first proven.
# Success means the strict fm_pr_poll_artifacts_valid accepts the result.
fm_pr_poll_registration_rerecord_device() {  # <state> <id> <template>
  local state=$1 id=$2 template=$3 state_device registration tmp reg_hash reg_identity
  local id_line provider url host path number data_hash template_hash data_identity check_identity
  fm_pr_poll_registration_device_shifted "$state" "$id" "$template" || return 1
  registration="$state/$id.pr-poll-registration"
  id_line=$FM_PR_REG_ID
  provider=$FM_PR_REG_PROVIDER
  url=$FM_PR_REG_URL
  host=$FM_PR_REG_HOST
  path=$FM_PR_REG_PATH
  number=$FM_PR_REG_NUMBER
  data_hash=$FM_PR_REG_DATA_HASH
  template_hash=$FM_PR_REG_TEMPLATE_HASH
  data_identity=$FM_PR_POLL_REARM_DATA_IDENTITY
  check_identity=$FM_PR_POLL_REARM_CHECK_IDENTITY
  state_device=$(fm_pr_file_device "$state") || return 1
  reg_hash=$(fm_pr_sha256 "$registration") || return 1
  reg_identity=$(fm_pr_file_identity "$registration") || return 1
  tmp=$(mktemp "$state/.fm-pr-poll-registration.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-registration-v2 "$id_line" "$provider" "$url" "$host" "$path" "$number" \
      "$data_hash" "$template_hash" "$data_identity" "$check_identity" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$state_device" \
    || ! fm_pr_poll_registration_parse "$tmp" \
    || [ "$FM_PR_REG_ID" != "$id" ] \
    || [ "$FM_PR_REG_URL" != "$url" ] \
    || [ "$FM_PR_REG_DATA_HASH" != "$data_hash" ] \
    || [ "$FM_PR_REG_TEMPLATE_HASH" != "$template_hash" ] \
    || [ "$FM_PR_REG_DATA_IDENTITY" != "$data_identity" ] \
    || [ "$FM_PR_REG_CHECK_IDENTITY" != "$check_identity" ] \
    || ! fm_pr_poll_registration_device_shifted "$state" "$id" "$template" \
    || [ "$FM_PR_POLL_REARM_DATA_IDENTITY" != "$data_identity" ] \
    || [ "$FM_PR_POLL_REARM_CHECK_IDENTITY" != "$check_identity" ] \
    || [ "$(fm_pr_sha256 "$registration")" != "$reg_hash" ] \
    || [ "$(fm_pr_file_identity "$registration")" != "$reg_identity" ] \
    || ! fm_pr_regular_destination_on_device_or_absent "$registration" "$state_device" \
    || ! mv -f -- "$tmp" "$registration"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_poll_artifacts_valid "$state" "$id" "$template"
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

fm_pr_github_read_record_with_gh() {  # <owner> <repo> <number>
  local owner=$1 repo=$2 number=$3 fields line total=0 named=0
  local state='' merged=''
  FM_PR_RECORD_STATE=
  FM_PR_RECORD_MERGED=

  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged}}}' \
    -F "owner=$owner" -F "repo=$repo" -F "number=$number" \
    --jq '.data.repository.pullRequest | "state=" + (.state // ""), "merged=" + (.merged | tostring)' \
    2>/dev/null) || [ -z "$fields" ]; then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 2 ] || [ "$total" -ne 2 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; }; then
    return 1
  fi

  # Consumed by bin/fm-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  FM_PR_RECORD_STATE=$state
  # Consumed by bin/fm-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  FM_PR_RECORD_MERGED=$merged
}

fm_pr_github_read_record_with_gh_axi() {  # <owner> <repo> <number>
  local owner=$1 repo=$2 number=$3 output state
  FM_PR_RECORD_STATE=
  FM_PR_RECORD_MERGED=
  if ! output=$(gh-axi pr view "$number" --repo "$owner/$repo" 2>/dev/null); then
    return 1
  fi
  if ! state=$(printf '%s\n' "$output" | awk '
    $1 == "state:" { count++; value=$2 }
    END { if (count == 1 && value != "") print value; else exit 1 }
  '); then
    return 1
  fi
  case "$state" in
    MERGED|merged)
      # Consumed by bin/fm-crew-state.sh passed_pr_detail.
      # shellcheck disable=SC2034
      FM_PR_RECORD_STATE=MERGED
      # Consumed by bin/fm-crew-state.sh passed_pr_detail.
      # shellcheck disable=SC2034
      FM_PR_RECORD_MERGED=true
      ;;
    OPEN|open)
      # Consumed by bin/fm-crew-state.sh passed_pr_detail.
      # shellcheck disable=SC2034
      FM_PR_RECORD_STATE=OPEN
      # Consumed by bin/fm-crew-state.sh passed_pr_detail.
      # shellcheck disable=SC2034
      FM_PR_RECORD_MERGED=false
      ;;
    CLOSED|closed)
      # Consumed by bin/fm-crew-state.sh passed_pr_detail.
      # shellcheck disable=SC2034
      FM_PR_RECORD_STATE=CLOSED
      # Consumed by bin/fm-crew-state.sh passed_pr_detail.
      # shellcheck disable=SC2034
      FM_PR_RECORD_MERGED=false
      ;;
    *)
      return 1
      ;;
  esac
}

fm_pr_github_read_record() {  # <owner> <repo> <number>
  if command -v gh >/dev/null 2>&1 && fm_pr_github_read_record_with_gh "$@"; then
    return 0
  fi
  command -v gh-axi >/dev/null 2>&1 || return 1
  fm_pr_github_read_record_with_gh_axi "$@"
}

fm_pr_gitlab_read_record() {  # <host> <path> <number>
  local host=$1 path=$2 number=$3 project_url json fields line
  local total=0 named=0 state='' merged=''
  FM_PR_RECORD_STATE=
  FM_PR_RECORD_MERGED=
  command -v glab >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  project_url="https://$host/$path"

  if ! json=$(GITLAB_HOST="$host" glab mr view "$number" -R "$project_url" -F json 2>/dev/null) \
    || [ -z "$json" ]; then
    return 1
  fi
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" and (.state | type == "string") and .state != "" then
        "state=" + .state,
        "merged=" + (if .state == "merged" then "true" else "false" end)
      else
        error("invalid merge request state")
      end' 2>/dev/null); then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 2 ] || [ "$total" -ne 2 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; }; then
    return 1
  fi

  # Consumed by bin/fm-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  FM_PR_RECORD_STATE=$state
  # Consumed by bin/fm-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  FM_PR_RECORD_MERGED=$merged
}

# gerrit-axi resolves its server from the current directory's origin remote
# first, so the host is passed explicitly from the parsed identity and a read
# outside a clone still reaches the right server. A change number is
# server-global and --host pins the server, so the number alone names the
# change and the project path is not part of the read. Prints the one record
# whose change number is exactly <number> as compact JSON, and fails on any
# other reading. The record's own url field is not compared against the stored
# URL, because Gerrit composes it from gerrit.canonicalWebUrl and omits it when
# that setting is unset, which would turn every read on such a server into a
# permanent unknown.
fm_pr_gerrit_read_change() {  # <host> <number>
  local host=$1 number=$2 json
  command -v gerrit-axi >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  case "$number" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if ! json=$(gerrit-axi show "$number" --host "$host" --json 2>/dev/null) \
    || [ -z "$json" ]; then
    return 1
  fi
  printf '%s' "$json" | jq -c --argjson change "$number" '
    if type == "object" and .ok == true and (.changes | type) == "array" then
      [.changes[] | select((.change | type) == "number" and .change == $change)] as $match
      | if ($match | length) == 1 and ($match[0] | type) == "object"
        then $match[0]
        else error("no exact change record")
        end
    else
      error("invalid gerrit record")
    end' 2>/dev/null
}

# The status of one Gerrit change. The status is the only field read: a merged
# change and an approved-but-unsubmitted one report the same submit,
# submittable, and blocked_on values, so only the status separates them.
fm_pr_gerrit_read_record() {  # <host> <number>
  local record state merged=false
  FM_PR_RECORD_STATE=
  FM_PR_RECORD_MERGED=
  record=$(fm_pr_gerrit_read_change "$1" "$2") || return 1
  state=$(printf '%s' "$record" | jq -r '
    if (.status | type) == "string" and .status != "" and (.status | test("\n") | not)
    then .status
    else error("no status")
    end' 2>/dev/null) || return 1
  [ -n "$state" ] || return 1
  [ "$state" != MERGED ] || merged=true

  # Consumed by bin/fm-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  FM_PR_RECORD_STATE=$state
  # Consumed by bin/fm-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  FM_PR_RECORD_MERGED=$merged
}

# The current patch set revision of one Gerrit change, read from the same exact
# record as its status above. Consumed by bin/fm-dod-lib.sh's named-head gate,
# which accepts a published change only when this revision carries the worker
# copy's HEAD tree. It is a live read and never a recorded pr_head: the next
# amend replaces it.
fm_pr_gerrit_read_revision() {  # <host> <number>
  local record revision
  FM_PR_RECORD_REVISION=
  record=$(fm_pr_gerrit_read_change "$1" "$2") || return 1
  revision=$(printf '%s' "$record" | jq -r '
    if (.revision | type) == "string" then .revision else error("no revision") end' 2>/dev/null) \
    || return 1
  fm_pr_head_valid "$revision" || return 1
  # Consumed by bin/fm-dod-lib.sh fm_dod_gerrit_change_carries_head.
  # shellcheck disable=SC2034
  FM_PR_RECORD_REVISION=$revision
}

# --- Bitbucket Cloud REST API 2.0 --------------------------------------------
# Bitbucket Cloud has no CLI firstmate can rely on, so its reads and its merge
# go through curl against this one fixed API base. The credential is the one
# the no-mistakes pipeline already uses to open Bitbucket pull requests:
# NO_MISTAKES_BITBUCKET_EMAIL and NO_MISTAKES_BITBUCKET_API_TOKEN, an Atlassian
# API token used as HTTP Basic auth (docs/configuration.md owns the setup). It
# is read from the environment only and handed to curl on stdin as a config
# line, never as an argument, so it never appears in a process listing, and it
# is never printed, logged, or recorded. curl's -q comes first so no ambient
# .curlrc can add options to a request that carries it.
FM_PR_BITBUCKET_API=https://api.bitbucket.org/2.0

# Prints what a Bitbucket read or merge still needs, joined for a refusal, and
# nothing when every requirement is present.
fm_pr_bitbucket_missing_requirements() {
  local missing=''
  command -v curl >/dev/null 2>&1 || missing="curl"
  command -v jq >/dev/null 2>&1 || missing="${missing:+$missing, }jq"
  [ -n "${NO_MISTAKES_BITBUCKET_EMAIL:-}" ] \
    || missing="${missing:+$missing, }the NO_MISTAKES_BITBUCKET_EMAIL environment variable"
  [ -n "${NO_MISTAKES_BITBUCKET_API_TOKEN:-}" ] \
    || missing="${missing:+$missing, }the NO_MISTAKES_BITBUCKET_API_TOKEN environment variable"
  printf '%s' "$missing"
}

# One request to the Bitbucket API. <api-path> is relative to the fixed base
# and is built only from a validated identity. Sets FM_PR_BITBUCKET_STATUS to
# the HTTP status and FM_PR_BITBUCKET_BODY to the response body whenever curl
# completed, and succeeds only on a 2xx status, so a caller that needs to tell
# an accepted-but-pending merge from a refusal can read the status either way.
# shellcheck disable=SC2034 # FM_PR_BITBUCKET_STATUS is read by sourcing callers.
fm_pr_bitbucket_request() {  # <method> <api-path> [<json-body>]
  local method=$1 path=$2 body=${3-} credential out code
  local -a args
  FM_PR_BITBUCKET_STATUS=
  FM_PR_BITBUCKET_BODY=
  [ -z "$(fm_pr_bitbucket_missing_requirements)" ] || return 1
  credential="$NO_MISTAKES_BITBUCKET_EMAIL:$NO_MISTAKES_BITBUCKET_API_TOKEN"
  credential=${credential//\\/\\\\}
  credential=${credential//\"/\\\"}
  args=(-q -sS -K - -X "$method" -H 'Accept: application/json'
    --connect-timeout 10 --max-time "${FM_PR_BITBUCKET_MAX_TIME:-60}" -w '\n%{http_code}')
  if [ -n "$body" ]; then
    args+=(-H 'Content-Type: application/json' --data-binary "$body")
  fi
  out=$(printf 'user = "%s"\n' "$credential" \
    | curl "${args[@]}" "$FM_PR_BITBUCKET_API/$path" 2>/dev/null) || return 1
  code=${out##*$'\n'}
  if [ "$code" = "$out" ]; then
    out=
  else
    out=${out%$'\n'*}
  fi
  [[ "$code" =~ ^[0-9]{3}$ ]] || return 1
  FM_PR_BITBUCKET_STATUS=$code
  FM_PR_BITBUCKET_BODY=$out
  case "$code" in
    2??) return 0 ;;
  esac
  return 1
}

# Every value of one paginated Bitbucket collection, as one JSON array in
# FM_PR_BITBUCKET_VALUES. A "next" link is followed only while it stays under
# the fixed API base, so a response can never steer the credential at another
# host, and a collection that does not end within the page bound is a failed
# read rather than a silently truncated one.
fm_pr_bitbucket_get_all() {  # <api-path>
  local path=$1 page=0 next values='[]' page_values
  FM_PR_BITBUCKET_VALUES=
  while :; do
    page=$((page + 1))
    [ "$page" -le 50 ] || return 1
    fm_pr_bitbucket_request GET "$path" || return 1
    page_values=$(printf '%s' "$FM_PR_BITBUCKET_BODY" | jq -c '
      if type == "object" and (.values | type) == "array" then .values
      else error("not a paginated collection") end' 2>/dev/null) || return 1
    values=$(jq -cn --argjson a "$values" --argjson b "$page_values" '$a + $b') || return 1
    next=$(printf '%s' "$FM_PR_BITBUCKET_BODY" | jq -r '
      if .next == null then "" elif (.next | type) == "string" then .next
      else error("invalid next link") end' 2>/dev/null) || return 1
    [ -n "$next" ] || break
    case "$next" in
      "$FM_PR_BITBUCKET_API"/*) path=${next#"$FM_PR_BITBUCKET_API"/} ;;
      *) return 1 ;;
    esac
  done
  FM_PR_BITBUCKET_VALUES=$values
}

# Resolve a commit hash as the API reports it to the full 40-character hash.
# A pull request reports its head as an abbreviated hash, so the repository's
# own commit read supplies the full one, which must extend the abbreviation.
fm_pr_bitbucket_resolve_commit() {  # <path> <hash>
  local path=$1 hash=$2 full
  local LC_ALL=C
  [[ "$hash" =~ ^[0-9a-f]{7,40}$ ]] || return 1
  if [ "${#hash}" -eq 40 ]; then
    printf '%s' "$hash"
    return 0
  fi
  fm_pr_bitbucket_request GET "repositories/$path/commit/$hash?fields=hash" || return 1
  full=$(printf '%s' "$FM_PR_BITBUCKET_BODY" | jq -r '
    if type == "object" and (.hash | type) == "string" then .hash else error("no hash") end' 2>/dev/null) \
    || return 1
  [[ "$full" =~ ^[0-9a-f]{40}$ ]] || return 1
  [ "${full#"$hash"}" != "$full" ] || return 1
  printf '%s' "$full"
}

# Make one Bitbucket pull request commit present in a local copy. Bitbucket
# has no pull ref, so a missing commit is fetched from origin by the pull
# request's source branch while that branch exists, then by hash.
fm_pr_bitbucket_fetch_commit() {  # <worktree> <full-hash> <source-branch>
  local wt=$1 hash=$2 source=${3-}
  fm_pr_head_valid "$hash" || return 1
  git -C "$wt" cat-file -e "$hash^{commit}" 2>/dev/null && return 0
  git -C "$wt" remote get-url origin >/dev/null 2>&1 || return 1
  if [ -n "$source" ] && git check-ref-format --branch "$source" >/dev/null 2>&1; then
    git -C "$wt" fetch --quiet origin "refs/heads/$source" >/dev/null 2>&1 || true
  fi
  git -C "$wt" cat-file -e "$hash^{commit}" 2>/dev/null \
    || git -C "$wt" fetch --quiet origin "$hash" >/dev/null 2>&1 || return 1
  git -C "$wt" cat-file -e "$hash^{commit}" 2>/dev/null
}

# One live read of a Bitbucket pull request. Sets FM_PR_BITBUCKET_STATE (OPEN,
# MERGED, DECLINED, or SUPERSEDED), FM_PR_BITBUCKET_DRAFT ("true", "false", or
# empty when the payload carries no boolean draft), FM_PR_BITBUCKET_HEAD_REPORTED
# (the head exactly as reported, which is abbreviated), FM_PR_BITBUCKET_HEAD,
# both branch names, and FM_PR_BITBUCKET_JSON. With the default "resolve",
# FM_PR_BITBUCKET_HEAD is the full hash resolved live; with "reported" it is
# left empty, for a read after a merge whose source branch may already be gone.
# The record must be the exact pull request asked for, and every field a
# caller relies on must be present, or the read fails.
# shellcheck disable=SC2034 # These results are read by sourcing callers.
fm_pr_bitbucket_read_pull_request() {  # <path> <number> [resolve|reported]
  local path=$1 number=$2 head_mode=${3:-resolve} fields line total=0 named=0
  local state='' draft='' head='' source='' dest=''
  local LC_ALL=C
  FM_PR_BITBUCKET_STATE=
  FM_PR_BITBUCKET_DRAFT=
  FM_PR_BITBUCKET_HEAD=
  FM_PR_BITBUCKET_HEAD_REPORTED=
  FM_PR_BITBUCKET_SOURCE_BRANCH=
  FM_PR_BITBUCKET_DEST_BRANCH=
  FM_PR_BITBUCKET_JSON=
  fm_pr_bitbucket_path_valid "$path" || return 1
  case "$number" in
    ''|0*|*[!0-9]*) return 1 ;;
  esac
  fm_pr_bitbucket_request GET "repositories/$path/pullrequests/$number" || return 1
  fields=$(printf '%s' "$FM_PR_BITBUCKET_BODY" | jq -r --argjson number "$number" '
    if type == "object" and .id == $number
       and (.state | type) == "string" and .state != ""
       and (.source.commit.hash | type) == "string"
       and (.source.branch.name | type) == "string"
       and (.destination.branch.name | type) == "string" and .destination.branch.name != ""
    then
      "state=" + .state,
      "draft=" + (if (.draft | type) == "boolean" then (.draft | tostring) else "" end),
      "head=" + .source.commit.hash,
      "source=" + .source.branch.name,
      "dest=" + .destination.branch.name
    else
      error("not the requested pull request")
    end' 2>/dev/null) || return 1
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      draft=*) draft=${line#draft=} ;;
      head=*) head=${line#head=} ;;
      source=*) source=${line#source=} ;;
      dest=*) dest=${line#dest=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  [ "$named" -eq 5 ] && [ "$total" -eq 5 ] || return 1
  [[ "$head" =~ ^[0-9a-f]{7,40}$ ]] || return 1
  FM_PR_BITBUCKET_JSON=$FM_PR_BITBUCKET_BODY
  FM_PR_BITBUCKET_HEAD_REPORTED=$head
  if [ "$head_mode" = resolve ]; then
    FM_PR_BITBUCKET_HEAD=$(fm_pr_bitbucket_resolve_commit "$path" "$head") || return 1
  fi
  FM_PR_BITBUCKET_STATE=$state
  FM_PR_BITBUCKET_DRAFT=$draft
  FM_PR_BITBUCKET_SOURCE_BRANCH=$source
  FM_PR_BITBUCKET_DEST_BRANCH=$dest
}

# The state of one Bitbucket pull request, in the shape every other provider's
# record read gives bin/fm-crew-state.sh. It is one request, because a state
# read needs no head.
fm_pr_bitbucket_read_record() {  # <path> <number>
  local path=$1 number=$2 state merged=false
  FM_PR_RECORD_STATE=
  FM_PR_RECORD_MERGED=
  fm_pr_bitbucket_path_valid "$path" || return 1
  case "$number" in
    ''|0*|*[!0-9]*) return 1 ;;
  esac
  fm_pr_bitbucket_request GET "repositories/$path/pullrequests/$number?fields=id,state" || return 1
  state=$(printf '%s' "$FM_PR_BITBUCKET_BODY" | jq -r --argjson number "$number" '
    if type == "object" and .id == $number and (.state | type) == "string"
       and .state != "" and (.state | test("\n") | not)
    then .state else error("not the requested pull request") end' 2>/dev/null) || return 1
  [ "$state" != MERGED ] || merged=true
  # Consumed by bin/fm-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  FM_PR_RECORD_STATE=$state
  # Consumed by bin/fm-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  FM_PR_RECORD_MERGED=$merged
}

# Every commit status reported on one commit, as a JSON array of
# {key, name, state} in FM_PR_BITBUCKET_VALUES. A status is identified by its
# key, which Bitbucket keeps unique per commit, so the key is the check name
# every refusal and waiver uses. A status whose key or state is not a string
# makes the whole read fail rather than be dropped.
fm_pr_bitbucket_read_statuses() {  # <path> <full-hash>
  local path=$1 head=$2 values
  fm_pr_head_valid "$head" || return 1
  fm_pr_bitbucket_get_all "repositories/$path/commit/$head/statuses?pagelen=100" || return 1
  values=$(printf '%s' "$FM_PR_BITBUCKET_VALUES" | jq -c '
    map(if type == "object" and (.key | type) == "string" and .key != ""
           and (.state | type) == "string"
        then {key, name: (.name // .key | tostring), state}
        else error("invalid commit status") end)' 2>/dev/null) || return 1
  FM_PR_BITBUCKET_VALUES=$values
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
