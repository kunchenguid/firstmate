#!/usr/bin/env bash
# Shared PR/MR record reads, validation, and atomic artifact helpers for merge
# polling on the supported forges. Callers must validate task IDs and raw PR/MR
# URLs before constructing task paths or performing any side effect.
#
# The stored identity is provider-tagged: provider, url, host, path, number.
# "path" is the full project path, which is owner/repository on GitHub and
# Forgejo, an arbitrarily nested group/subgroup/project namespace on GitLab, and
# an arbitrarily nested project name on Gerrit, where "number" is the change
# number. A GitLab or Gerrit project can sit at any depth, so no
# owner/repository pair can address one and the sidecar carries the whole path
# instead. GitLab, Gerrit, and Forgejo all run on self-hosted instances, and
# Gerrit runs nowhere else, so the host is part of that identity rather than a
# constant. GitHub runs on github.com and on GitHub Enterprise (Cloud *.ghe.com
# and Enterprise Server), so its host is part of that identity too. Every
# consumer re-derives the identity
# from the stored URL and refuses any record whose parts do not reconstruct that
# exact URL.
#
# Registered poll generations bind to their original hashes and file objects,
# so a repository template update does not invalidate an armed poll. The watcher
# executes the current repository poll with validated data, never the registered
# state-file copy. Control relaunch metadata may follow the preserved PR identity
# fields.
#
# A validated exact merged result is retired through a private receipt only
# after its durable wake is appended.
# The receipt binds the terminal observation to the canonical registration and
# lets a restart finish fixed-path removal without executing state-file bytes.

_FM_PR_LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
FM_PR_DATA_PREFERENCE=
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
FM_PR_POLL_EXPECT_PREFERENCE=
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
FM_PR_POLL_SNAPSHOT_PREFERENCE=
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

# GitLab, Gerrit, and Forgejo all serve self-hosted instances, so the host is part of the
# identity rather than a constant. It is accepted only as a lowercase DNS name
# with no userinfo, port, or trailing dot, which keeps one canonical spelling per
# change. github.com is refused here even though its shape is otherwise valid:
# it is GitHub's own host and never another forge's instance, so a URL like
# https://github.com/o/r/-/merge_requests/1 (a typo'd or spoofed GitHub URL)
# would otherwise be armed as a watch that can never succeed.
fm_pr_forge_host_valid() {
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

# Unlike GitLab, a Forgejo/Gitea project has no subgroup nesting: it is always
# exactly owner/repository, so each segment is validated the same way GitHub's
# owner and repo are, minus GitHub's specific hyphen-run and length rules.
fm_pr_forgejo_segment_valid() {
  local segment=${1-}
  local LC_ALL=C
  [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 100 ] || return 1
  case "$segment" in
    .|..|*.git|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# A GitHub pull request URL names its host, and github.com is the only GitHub
# host accepted without being declared: every other host must be listed in this
# home's config/github-hosts (fm_github_host_allowed), so a look-alike such as
# github.com.evil or evilgithub.com is refused rather than armed as a watch that
# can never succeed. That list is the captain's own statement that a host is a
# GitHub host this home uses, which no URL shape can prove on its own.
# docs/configuration.md "GitHub Enterprise hosts" owns the file format.
# An unreadable list, an absent one, and a host it does not name all refuse.
# Only an exact line match authorizes, so a malformed or comment line can never
# authorize anything and needs no separate validation.
fm_github_host_allowed() {  # <host>
  local host=${1-} file line
  local LC_ALL=C
  [ -n "$host" ] || return 1
  [ "$host" != github.com ] || return 0
  fm_pr_forge_host_valid "$host" || return 1
  file="${FM_CONFIG_OVERRIDE:-${FM_HOME:-$_FM_PR_LIB_ROOT}/config}/github-hosts"
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" = "$host" ] && return 0
  done < "$file"
  return 1
}

# gh and gh-axi address the host in GH_HOST, from the pull request URL, or from
# the clone's own origin, in that order of specificity. A GitHub Enterprise host
# is not any tool's default one, so every GitHub call on a pull request path
# exports it once through here and its children inherit it. github.com keeps the
# ambient behavior it always had, byte for byte.
fm_pr_github_host_export() {  # <host>
  case ${1-} in
    ''|github.com) return 0 ;;
  esac
  GH_HOST=$1
  export GH_HOST
}

# Parse a canonical pull request, merge request, or Gerrit change URL into the
# provider-tagged identity. Validation is strict and per provider: the GitHub
# username and repository rules are unchanged, and GitLab, Gerrit, and Forgejo
# each get their own namespace rules rather than a loosened GitHub rule.
#
# FM_PR_OWNER and FM_PR_REPO are additionally set for github and forgejo
# because bin/fm-pr-merge.sh addresses both by owner/repository. A gitlab or
# gerrit URL leaves them empty, and those paths address the project by FM_PR_HOST and
# FM_PR_PATH instead, so a change on any instance resolves without a hardcoded
# host.
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
  pattern='^https://([a-z0-9.-]{1,253})/([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])/([A-Za-z0-9._-]{1,100})/pull/([1-9][0-9]*)$'
  if [[ "$raw" =~ $pattern ]]; then
    host=${BASH_REMATCH[1]}
    fm_github_host_allowed "$host" || return 1
    [[ "${BASH_REMATCH[2]}" != *--* ]] || return 1
    [ "${BASH_REMATCH[3]}" != . ] && [ "${BASH_REMATCH[3]}" != .. ] || return 1
    FM_PR_PROVIDER=github
    FM_PR_URL=$raw
    FM_PR_HOST=$host
    FM_PR_PATH="${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
    # Consumed by bin/fm-pr-merge.sh, which addresses GitHub by owner/repository.
    # shellcheck disable=SC2034
    FM_PR_OWNER=${BASH_REMATCH[2]}
    # shellcheck disable=SC2034
    FM_PR_REPO=${BASH_REMATCH[3]}
    FM_PR_NUMBER=${BASH_REMATCH[4]}
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
  if [[ "$raw" =~ $pattern ]]; then
    host=${BASH_REMATCH[1]}
    path=${BASH_REMATCH[2]}
    fm_pr_forge_host_valid "$host" || return 1
    fm_pr_gerrit_path_valid "$path" || return 1
    FM_PR_PROVIDER=gerrit
    FM_PR_URL=$raw
    FM_PR_HOST=$host
    FM_PR_PATH=$path
    FM_PR_NUMBER=${BASH_REMATCH[3]}
    return 0
  fi
  # Forgejo/Gitea serve pulls at owner/repo/pulls/<n>: plural "pulls", no "/-/"
  # route separator and no "/+/" change separator, so this shape never collides
  # with the GitLab or Gerrit patterns above.
  pattern='^https://([a-z0-9.-]{1,253})/([A-Za-z0-9._-]{1,100})/([A-Za-z0-9._-]{1,100})/pulls/([1-9][0-9]*)$'
  [[ "$raw" =~ $pattern ]] || return 1
  host=${BASH_REMATCH[1]}
  fm_pr_forge_host_valid "$host" || return 1
  fm_pr_forgejo_segment_valid "${BASH_REMATCH[2]}" || return 1
  fm_pr_forgejo_segment_valid "${BASH_REMATCH[3]}" || return 1
  FM_PR_PROVIDER=forgejo
  FM_PR_URL=$raw
  FM_PR_HOST=$host
  FM_PR_PATH="${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
  # Consumed by bin/fm-pr-merge.sh, which addresses Forgejo by owner/repository.
  # shellcheck disable=SC2034
  FM_PR_OWNER=${BASH_REMATCH[2]}
  # shellcheck disable=SC2034
  FM_PR_REPO=${BASH_REMATCH[3]}
  FM_PR_NUMBER=${BASH_REMATCH[4]}
}

fm_pr_head_valid() {
  local head=${1-}
  local LC_ALL=C
  [[ "$head" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]]
}

# Resolve the PR number for a task copy's branch via gh-axi, run inside that
# copy so gh-axi resolves the copy's own repository. Echoes the number on a
# single match and returns 0; returns non-zero on no match or any lookup
# failure, so callers treat it as "no PR found" (fail-safe). bin/fm-teardown.sh
# reads any state for its landed check; bin/fm-pr-health.sh reads open PRs to
# enroll a branch whose PR was never recorded.
fm_pr_number_from_branch() {  # <worktree> <branch> [open|closed|all]
  local wt=$1 branch=$2 state=${3:-all} out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$wt" && gh-axi pr list --state "$state" --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
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
      control_relaunch_tx=*|x_request=*|x_request_ts=*|x_followups=*|x_platform=*|x_reply_max_chars=*)
        # Lifecycle and relay fields may be appended after the PR identity.
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

# Sidecar layout: provider, url, host, path, number, one per line, plus an
# optional sixth line naming the project's recorded Forgejo CLI preference
# (auto|tea|fgj|fj). A sidecar written before the provider tag existed has a URL
# on its first line and one line fewer, so it fails both the field count and the
# provider comparison and is refused rather than misread as a provider-tagged
# record. A sidecar with no preference line is read as `auto`, so a poll armed
# before this line existed keeps the selection it always had.
fm_pr_poll_data_parse() {
  local file=$1 provider url host path number preference optional
  FM_PR_DATA_PROVIDER=
  FM_PR_DATA_URL=
  FM_PR_DATA_HOST=
  FM_PR_DATA_PATH=
  FM_PR_DATA_NUMBER=
  FM_PR_DATA_PREFERENCE=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 8< "$file" || return 1
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r url <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  preference=auto
  if IFS= read -r optional <&8; then
    preference=$optional
    if IFS= read -r _extra <&8; then
      exec 8<&-
      return 1
    fi
  fi
  exec 8<&-
  case "$preference" in
    auto|tea|fgj|fj) ;;
    *) return 1 ;;
  esac
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
  FM_PR_DATA_PREFERENCE=$preference
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
  local state=$1 id=$2 provider=$3 url=$4 host=$5 path=$6 number=$7 template=$8 preference=${9:-auto}
  local poll_preference_line
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$provider" = "$FM_PR_PROVIDER" ] || return 1
  [ "$host" = "$FM_PR_HOST" ] || return 1
  [ "$path" = "$FM_PR_PATH" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  case "$preference" in
    auto|tea|fgj|fj) ;;
    *) return 1 ;;
  esac
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
  FM_PR_POLL_EXPECT_PREFERENCE=$preference
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

  poll_preference_line=
  [ "$preference" = auto ] || poll_preference_line=$preference$'\n'
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s' "$provider" "$url" "$host" "$path" "$number" "$poll_preference_line" > "$FM_PR_POLL_DATA_TMP" \
    || ! chmod 0600 "$FM_PR_POLL_DATA_TMP" \
    || ! fm_pr_private_file_valid "$FM_PR_POLL_DATA_TMP" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! fm_pr_poll_data_parse "$FM_PR_POLL_DATA_TMP" \
    || [ "$FM_PR_DATA_PROVIDER" != "$provider" ] \
    || [ "$FM_PR_DATA_URL" != "$url" ] \
    || [ "$FM_PR_DATA_HOST" != "$host" ] \
    || [ "$FM_PR_DATA_PATH" != "$path" ] \
    || [ "$FM_PR_DATA_NUMBER" != "$number" ] \
    || [ "$FM_PR_DATA_PREFERENCE" != "$preference" ] \
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
    || [ "$FM_PR_DATA_NUMBER" != "$FM_PR_POLL_EXPECT_NUMBER" ] \
    || [ "$FM_PR_DATA_PREFERENCE" != "$FM_PR_POLL_EXPECT_PREFERENCE" ]; then
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
  # Authenticate the published generation against its registration below, not
  # against a template that may have changed during a repository update.
  # The watcher executes this repository's current poll with validated data;
  # it never executes the registered state-file bytes.
  [ -f "$template" ] && [ ! -L "$template" ] || return 1
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
# both hashes match the registered generation, and the three
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
  FM_PR_POLL_SNAPSHOT_PREFERENCE=$FM_PR_DATA_PREFERENCE
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
  [ "$FM_PR_DATA_PREFERENCE" = "$FM_PR_POLL_SNAPSHOT_PREFERENCE" ] || return 1
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

fm_pr_github_read_record_with_gh() {  # <host> <owner> <repo> <number>
  local host=$1 owner=$2 repo=$3 number=$4 fields line total=0 named=0
  local state='' merged=''
  FM_PR_RECORD_STATE=
  FM_PR_RECORD_MERGED=

  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(GH_HOST=$host gh api graphql \
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

fm_pr_github_read_record_with_gh_axi() {  # <host> <owner> <repo> <number>
  local host=$1 owner=$2 repo=$3 number=$4 output state
  FM_PR_RECORD_STATE=
  FM_PR_RECORD_MERGED=
  if ! output=$(GH_HOST=$host gh-axi pr view "$number" --repo "$owner/$repo" 2>/dev/null); then
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

fm_pr_github_read_record() {  # <host> <owner> <repo> <number>
  if command -v gh >/dev/null 2>&1 && fm_pr_github_read_record_with_gh "$@"; then
    return 0
  fi
  command -v gh-axi >/dev/null 2>&1 || return 1
  fm_pr_github_read_record_with_gh_axi "$@"
}

# GitHub required-check reading shared by bin/fm-pr-merge.sh and
# bin/fm-park.sh. These read the repository named by PR_OWNER and PR_REPO,
# which the caller sets.
github_urlencode_path_segment() {
  local LC_ALL=C input=$1 encoded='' char octet hex
  while [ -n "$input" ]; do
    char=${input%"${input#?}"}
    input=${input#?}
    case "$char" in
      [-._~a-zA-Z0-9]) encoded=$encoded$char ;;
      *)
        printf -v octet '%d' "'$char"
        [ "$octet" -ge 0 ] || octet=$((octet + 256))
        printf -v hex '%02X' "$octet"
        encoded=$encoded%$hex
        ;;
    esac
  done
  printf '%s' "$encoded"
}

# Whether a failed branch-rules read (the gh stderr given) is GitHub's
# plan-gated 403 ("Upgrade to GitHub Pro or make this repository public"),
# which means the repository's plan cannot expose branch rules at all, on
# GitHub or GitHub Enterprise Server - not that this script failed to read
# them, and not that the token lacks a permission. Such a repository has no
# active ruleset rule of any kind. Any other failure (auth, rate limit,
# network, a 404, an unrelated 403) is not this and stays unreadable.
github_branch_rules_unavailable_on_plan() {
  case "$1" in
    *"Upgrade to GitHub Pro or make this repository public"*) return 0 ;;
  esac
  return 1
}

FM_PR_GITHUB_REQUIRED=
FM_PR_GITHUB_REQUIRED_ERROR=
github_read_required_contexts() {
  local base=$1 branch_path branch_json rules_json classic='' ruleset='' api_err api_err_text
  FM_PR_GITHUB_REQUIRED='[]'
  FM_PR_GITHUB_REQUIRED_ERROR=
  branch_path=$(github_urlencode_path_segment "$base")

  if ! branch_json=$(gh api "repos/$PR_OWNER/$PR_REPO/branches/$branch_path" 2>/dev/null) \
    || [ -z "$branch_json" ] \
    || ! classic=$(printf '%s' "$branch_json" | jq -c '
      if type != "object" or (.protected | type) != "boolean" then
        error("branch payload is unreadable")
      elif .protected == false then
        empty
      elif (.protection.required_status_checks | type) != "object" then
        error("branch protection summary is unreadable")
      else
        .protection.required_status_checks
        | ((.checks // []) | if type == "array" then .[] else error("invalid checks") end
           | {context, app_id}),
          ((.contexts // []) | if type == "array" then .[] else error("invalid contexts") end
           | {context: ., app_id: null})
        | if (.context | type) == "string" and (.context | length) > 0
             and (.app_id == null or (.app_id | type) == "number")
          then . else error("invalid required check") end
        | if .app_id == -1 then .app_id = null else . end
      end' 2>/dev/null); then
    classic=''
    FM_PR_GITHUB_REQUIRED_ERROR="the branch protection summary for base branch $base could not be read"
  fi

  if ! api_err=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-required-rules.XXXXXX"); then
    FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
  else
    if ! rules_json=$(gh api --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/$branch_path" 2>"$api_err"); then
      api_err_text=$(cat "$api_err" 2>/dev/null)
      if ! github_branch_rules_unavailable_on_plan "$api_err_text"; then
        FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
      fi
    elif [ -z "$rules_json" ] || ! ruleset=$(printf '%s' "$rules_json" | jq -c '
        if type != "array" then error("rules payload is unreadable") else .[] end
        | select(type != "object" or .type == "required_status_checks")
        | if type == "object" and (.parameters.required_status_checks | type) == "array"
          then .parameters.required_status_checks[] else error("invalid required check rule") end
        | if type == "object" and (.context | type) == "string" and (.context | length) > 0
             and (.integration_id == null or (.integration_id | type) == "number")
          then {context, app_id: .integration_id} else error("invalid required check rule") end
        | if .app_id == -1 then .app_id = null else . end' 2>/dev/null); then
      ruleset=''
      FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
    fi
    rm -f "$api_err"
  fi

  FM_PR_GITHUB_REQUIRED=$(printf '%s\n%s\n' "$classic" "$ruleset" | jq -sc '
    unique_by([.context, .app_id]) | group_by(.context)
    | map(if any(.[]; .app_id != null) then map(select(.app_id != null)) else . end) | add // []')
  [ -z "$FM_PR_GITHUB_REQUIRED_ERROR" ]
}

github_required_checks_missing() {
  local json=$1 required=$2 producers=$3
  printf '%s' "$json" | jq -r --argjson required "$required" --argjson producers "$producers" '
    if (.statusCheckRollup | type) != "array" then error("no check rollup") else . end
    | .statusCheckRollup as $reported
    | $required
    | map(. as $requirement
      | select(any($reported[];
          if $requirement.app_id == null then
            (if .__typename == "CheckRun" then .name else .context end) == $requirement.context
          elif .__typename == "CheckRun" then
            .name == $requirement.context
            and any($producers[]; .name == $requirement.context and .app.id == $requirement.app_id)
          else
            .context == $requirement.context
          end) | not)
      | .context) | unique[]
  ' 2>/dev/null || return 1
}

# Reads the check runs at <head> with their producing app into
# FM_PR_GITHUB_PRODUCERS, only when a required check in FM_PR_GITHUB_REQUIRED
# names its app; '[]' otherwise or when the read fails, which returns 1.
FM_PR_GITHUB_PRODUCERS='[]'
github_read_required_producers() {  # <head>
  local head=$1 runs
  FM_PR_GITHUB_PRODUCERS='[]'
  printf '%s' "$FM_PR_GITHUB_REQUIRED" | jq -e 'any(.[]; .app_id != null)' >/dev/null || return 0
  if ! runs=$(gh api --paginate "repos/$PR_OWNER/$PR_REPO/commits/$head/check-runs" 2>/dev/null) \
    || [ -z "$runs" ] \
    || ! FM_PR_GITHUB_PRODUCERS=$(printf '%s' "$runs" | jq -sc --arg head "$head" '
      [ .[] | if (.check_runs | type) == "array" then .check_runs[] else error("invalid check runs") end
        | if (.name | type) == "string" and (.app.id | type) == "number" and .head_sha == $head
          then . else error("invalid check producer") end ]' 2>/dev/null); then
    # shellcheck disable=SC2034 # read by the callers
    FM_PR_GITHUB_PRODUCERS='[]'
    return 1
  fi
}

# Reads one merge request's state and its own head commit (the MR's sha, never
# a merge, squash, or merge-train commit, which is what lets bin/fm-teardown.sh
# prove a squash-merged or merge-train-merged copy landed).
fm_pr_gitlab_read_record() {  # <host> <path> <number>
  local host=$1 path=$2 number=$3 project_url json fields line
  local total=0 named=0 state='' merged='' head=''
  FM_PR_RECORD_STATE=
  FM_PR_RECORD_MERGED=
  FM_PR_RECORD_HEAD=
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
        "merged=" + (if .state == "merged" then "true" else "false" end),
        "head=" + (if (.sha | type) == "string" then .sha else "" end)
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
      head=*) head=${line#head=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 3 ] || [ "$total" -ne 3 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; }; then
    return 1
  fi

  # Consumed by bin/fm-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  FM_PR_RECORD_STATE=$state
  # Consumed by bin/fm-crew-state.sh passed_pr_detail and bin/fm-teardown.sh.
  # shellcheck disable=SC2034
  FM_PR_RECORD_MERGED=$merged
  # Consumed by bin/fm-teardown.sh pr_is_merged; empty when the forge omitted it.
  # shellcheck disable=SC2034
  FM_PR_RECORD_HEAD=$head
}

# --- Forgejo CLI resolution -------------------------------------------------
#
# A Forgejo pull request is reached through one of several Forgejo CLIs, and
# this block is the single owner that picks one and its host login for a pull
# request. bin/fm-pr-poll.sh keeps its own copy of the whole selection because
# the watcher body sources nothing; every other reader (bin/fm-pr-merge.sh,
# bin/fm-crew-state.sh, bin/fm-teardown.sh, bin/fm-pr-check.sh) goes through
# these functions.
#
# A CLI can serve firstmate's contract only when it can make a raw
# authenticated REST request against the instance. Every read here is the same
# REST record with the same field names, and the merge must carry Forgejo's
# head_commit_id so a merge stays bound to the head this run verified. Two of
# the recognized CLIs can:
#   tea   `tea api --login <name> --repo <owner>/<repo> [-X <method>] [-f k=v] <endpoint>`
#   fgj   `fgj api <endpoint> --hostname <host> [-X <method>] [-f k=v]`
# `fj` (forgejo-cli) cannot. It exposes no authenticated request passthrough at
# all, its pull request views print only localized human prose with no commit
# id anywhere, and its own merge request is built with head_commit_id fixed to
# null, so it can neither bind a merge to a verified head nor report one. A
# resolved `fj` is therefore refused by every operation that needs the record,
# loudly and by name, rather than reading a rendered line as state or merging
# unbound; docs/forgejo-cli-alternatives.md holds the empirical record.
#
# A CLI is selected by explicit configuration first (a project's registered
# `forge=forgejo:<cli>` registry binding) and by what is
# installed second: FM_PR_FORGEJO_CLI_ORDER is tried in order and the first CLI
# that is installed AND holds exactly one login for <host> wins, so a home that
# has tea keeps its exact previous behaviour and a home that has only fj gets a
# legible refusal instead of "tea not found". Zero logins for <host> in a CLI's
# own store, or several, refuses rather than guesses, mirroring the tea login
# match this block replaces.

# The recognized Forgejo CLIs, in the order an unnamed project tries them.
FM_PR_FORGEJO_CLI_ORDER='tea fgj fj'

# The CLI and host login fm_pr_forgejo_resolve selected: consumed by the
# fm_pr_forgejo_* helpers below and by every caller's own diagnostics.
FM_PR_FORGEJO_CLI=
FM_PR_FORGEJO_LOGIN=

# 0 when <cli> exposes an authenticated raw REST request, which is what every
# reader and the head-bound merge need. `fj` does not, and never will by
# accident: the capability is declared here rather than inferred from a flag.
fm_pr_forgejo_cli_api_capable() {  # <cli>
  case "${1:-}" in
    tea|fgj) return 0 ;;
  esac
  return 1
}

fm_pr_forgejo_cli_installed() {  # <cli>
  command -v "${1:-}" >/dev/null 2>&1
}

# tea addresses a repo by slug only and takes the host from a named login, so
# the one login registered for <host> is printed by name, and zero or several
# matches fail rather than pick one. The list is parsed as JSON with jq rather
# than split on quotes per line, because tea's JSON is not guaranteed to put
# each field on its own line: a login printed as one compact object would hand
# a line-oriented split the name where it expects the url, and arming would
# then refuse every host. A login matches when its url's host - scheme,
# userinfo, port, and path stripped - is exactly <host>.
# shellcheck disable=SC2016 # $h is a jq variable bound by --arg, not a shell one.
FM_PR_FORGEJO_LOGIN_JQ='
  if type == "array" then
    [ .[]
      | select(type == "object" and (.name | type) == "string" and (.name | length) > 0
               and (.url | type) == "string")
      | select((.url
                | sub("^[A-Za-z][A-Za-z0-9+.-]*://"; "")
                | sub("[/?#].*$"; "")
                | sub("^.*@"; "")
                | sub(":[0-9]+$"; "")) == $h)
      | .name ]
    | if length == 1 then .[0] else error("not exactly one matching login") end
  else
    error("login list is not an array")
  end'
fm_pr_forgejo_login() {  # <host>
  command -v tea >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  tea login list --output json 2>/dev/null | jq -er --arg h "$1" "$FM_PR_FORGEJO_LOGIN_JQ" 2>/dev/null
}

# fgj keeps its own auth store: one entry per instance hostname, selected on the
# command line with --hostname. `fgj auth status` prints one
# "  <bullet> <host> (user: <name>)" line per configured instance, so the
# configured hostnames are read from that report and never from the config file,
# which also holds each instance's token. Zero or several lines naming <host>
# fails rather than picking one.
fm_pr_forgejo_fgj_login() {  # <host>
  command -v fgj >/dev/null 2>&1 || return 1
  local status
  status=$(fgj auth status 2>/dev/null) || return 1
  printf '%s\n' "$status" | awk -v h="$1" '
    /\(user: [^)]*\)[[:space:]]*$/ {
      line = $0
      sub(/[[:space:]]*\(user: [^)]*\)[[:space:]]*$/, "", line)
      n = split(line, field, /[[:space:]]+/)
      if (n >= 1 && field[n] == h) matched++
    }
    END { if (matched != 1) exit 1; print h }
  '
}

# fj keeps one login per instance and prints the bare hostnames one per line
# with `fj auth list` (its "no logins" message goes to stderr, leaving stdout
# empty). Zero or several lines naming <host> fails rather than picking one.
# fj still cannot serve firstmate's contract - see the resolver note above - but
# its store is read here so a target host can be recognized as fj's and refused
# by name instead of looking unconfigured.
fm_pr_forgejo_fj_login() {  # <host>
  command -v fj >/dev/null 2>&1 || return 1
  local status
  status=$(fj auth list 2>/dev/null) || return 1
  printf '%s\n' "$status" | awk -v h="$1" '$0 == h { matched++ } END { if (matched != 1) exit 1; print h }'
}

# The host login a given CLI would use for <host>, read from that CLI's own
# store. Prints the token the CLI itself wants (`--login` for tea, `--hostname`
# for fgj, `--host` for fj) and fails when that CLI has no, or an ambiguous,
# login for <host>.
fm_pr_forgejo_cli_login() {  # <cli> <host>
  case "${1:-}" in
    tea) fm_pr_forgejo_login "${2:-}" ;;
    fgj) fm_pr_forgejo_fgj_login "${2:-}" ;;
    fj) fm_pr_forgejo_fj_login "${2:-}" ;;
    *) return 1 ;;
  esac
}

# Resolve the Forgejo CLI and its own host login for <host> in one place.
# <preference> is `auto` (or empty) or one of tea|fgj|fj. An explicit preference
# is honored and REFUSED when that CLI is not installed or holds no single login
# for <host>, rather than silently falling back to another CLI; `auto` walks
# FM_PR_FORGEJO_CLI_ORDER and takes the first installed CLI holding exactly one
# login for <host>. Sets FM_PR_FORGEJO_CLI and FM_PR_FORGEJO_LOGIN and returns 0
# on success; clears both and returns 1 otherwise.
# The caller decides whether the resolved CLI can serve the operation it needs
# (fm_pr_forgejo_cli_api_capable); this function only answers "which CLI, which
# login", so a caller can report `fj` by name instead of reporting nothing.
fm_pr_forgejo_resolve() {  # <host> [<preference>]
  local host=${1:-} preference=${2:-auto} cli login
  FM_PR_FORGEJO_CLI=
  FM_PR_FORGEJO_LOGIN=
  case "$host" in
    ''|*[!a-z0-9.-]*) return 1 ;;
  esac
  case "$preference" in
    ''|auto) ;;
    tea|fgj|fj)
      fm_pr_forgejo_cli_installed "$preference" || return 1
      login=$(fm_pr_forgejo_cli_login "$preference" "$host") || return 1
      [ -n "$login" ] || return 1
      FM_PR_FORGEJO_CLI=$preference
      FM_PR_FORGEJO_LOGIN=$login
      return 0
      ;;
    *) return 1 ;;
  esac
  for cli in $FM_PR_FORGEJO_CLI_ORDER; do
    fm_pr_forgejo_cli_installed "$cli" || continue
    login=$(fm_pr_forgejo_cli_login "$cli" "$host") || continue
    [ -n "$login" ] || continue
    FM_PR_FORGEJO_CLI=$cli
    FM_PR_FORGEJO_LOGIN=$login
    return 0
  done
  return 1
}

# One authenticated REST request through the CLI fm_pr_forgejo_resolve chose.
# <method> is GET or POST; <owner>/<repo> are the pull request's own repository;
# <suffix> is the endpoint path after the repository ("pulls/9",
# "commits/<sha>/status?limit=50&page=1", or empty for the repository itself);
# and any remaining arguments are passed through verbatim, which is how a POST
# names its body fields ("-f Do=merge" "-f head_commit_id=<sha>"). tea and fgj
# spell those fields the same way, so callers stay CLI-agnostic.
# The response body is printed verbatim on stdout and NO redirection is applied
# here: tea writes an HTTP error body to stdout while fgj writes it to stderr
# and exits non-zero, so each caller chooses between discarding that error and
# quoting it, and the existing read-back-rather-than-trust-the-exit-status
# judgement keeps working for both.
# Returns 1 and runs nothing when no CLI was resolved, the resolved one cannot
# make a raw request (fj), or the arguments do not fit the method, so a caller
# can never mistake a rendered line for the record.
fm_pr_forgejo_api() {  # <method> <owner> <repo> <suffix> [<cli-args>...]
  local method=${1:-GET} owner=${2:-} repo=${3:-} suffix=${4:-}
  shift 4
  [ -n "$owner" ] && [ -n "$repo" ] || return 1
  [ -n "$FM_PR_FORGEJO_CLI" ] || return 1
  fm_pr_forgejo_cli_api_capable "$FM_PR_FORGEJO_CLI" || return 1
  fm_pr_forgejo_cli_installed "$FM_PR_FORGEJO_CLI" || return 1
  if [ "$method" = GET ]; then
    # A GET read carries any query string in <suffix>, never as a field.
    [ "$#" -eq 0 ] || return 1
  else
    [ "$#" -gt 0 ] || return 1
  fi
  case "$FM_PR_FORGEJO_CLI" in
    tea)
      local tea_endpoint="/repos/{owner}/{repo}"
      [ -z "$suffix" ] || tea_endpoint="$tea_endpoint/$suffix"
      if [ "$method" = GET ]; then
        tea api --login "$FM_PR_FORGEJO_LOGIN" --repo "$owner/$repo" "$tea_endpoint"
      else
        tea api --login "$FM_PR_FORGEJO_LOGIN" --repo "$owner/$repo" \
          -X "$method" "$tea_endpoint" "$@"
      fi
      ;;
    fgj)
      local fgj_endpoint="repos/$owner/$repo"
      [ -z "$suffix" ] || fgj_endpoint="$fgj_endpoint/$suffix"
      if [ "$method" = GET ]; then
        fgj api "$fgj_endpoint" --hostname "$FM_PR_FORGEJO_LOGIN"
      else
        fgj api "$fgj_endpoint" --hostname "$FM_PR_FORGEJO_LOGIN" -X "$method" "$@"
      fi
      ;;
    *) return 1 ;;
  esac
}

# The Forgejo CLI a task's project registered, read from the task's own
# metadata: `auto` unless the project's registry forge binding names one
# (`forge=forgejo:<cli>`). An absent or unreadable registry, an unknown project,
# or any unexpected value resolves to `auto`, which is the same default
# bin/fm-project-mode.sh reports, so a registry gap never silently pins a CLI.
# Every warning fm-project-mode.sh writes about an absent project goes to
# /dev/null: this is a lookup, and the caller reports its own refusal.
# bin/fm-pr-poll.sh, which sources nothing, is handed the resolved preference
# through the registered poll sidecar (fm_pr_poll_prepare) instead of calling
# this.
FM_PR_FORGEJO_CLI_PREFERENCE=
fm_pr_forgejo_cli_preference() {  # <task-meta-file>
  FM_PR_FORGEJO_CLI_PREFERENCE=auto
  local meta=${1:-} project preference
  [ -n "$meta" ] && [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  project=$(grep '^project=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$project" ] || return 0
  project=$(basename "$project")
  [ -n "$project" ] || return 0
  [ -x "$_FM_PR_LIB_ROOT/bin/fm-project-mode.sh" ] || return 0
  preference=$(FM_HOME="${FM_HOME:-$_FM_PR_LIB_ROOT}" \
    "$_FM_PR_LIB_ROOT/bin/fm-project-mode.sh" --forge-cli "$project" 2>/dev/null) || return 0
  case "$preference" in
    tea|fgj|fj) FM_PR_FORGEJO_CLI_PREFERENCE=$preference ;;
    auto) ;;
    *) return 0 ;;
  esac
}

# The state, merged flag, and head commit of one Forgejo pull request, read from
# the REST record through the resolved CLI so the credential never leaves that
# CLI. "tea api" exits 0 on an HTTP error and prints the error body instead, so
# only a record whose state, merged, and head.sha fields all have the expected
# types is accepted; anything else returns 1 for an honest unknown.
# <preference> is the project's recorded Forgejo CLI preference
# (fm_pr_forgejo_cli_preference); the caller resolves it from the task's own
# metadata and passes it here, so a project that registered a CLI is read
# through that CLI, while a project that named none stays on `auto` and reads
# exactly as before.
# The merge watch (bin/fm-pr-poll.sh), the terminal read
# (bin/fm-crew-state.sh), and teardown's merged proof (bin/fm-teardown.sh) all
# take this same read, so all three agree with the merge path about the CLI.
# A preference that resolves to a CLI which cannot make the request (`fj`)
# returns an honest unknown rather than reading a rendered line as state.
fm_pr_forgejo_read_record() {  # <host> <path> <number> [<preference>]
  local host=$1 path=$2 number=$3 preference=${4:-auto} owner repo json fields line
  local total=0 named=0 state='' merged='' head=''
  FM_PR_RECORD_STATE=
  FM_PR_RECORD_MERGED=
  FM_PR_RECORD_HEAD=
  command -v jq >/dev/null 2>&1 || return 1
  case "$number" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$path" in
    */*/*|/*|*/) return 1 ;;
  esac
  owner=${path%%/*}
  repo=${path#*/}
  [ "$owner" != "$path" ] || return 1
  fm_pr_forgejo_resolve "$host" "$preference" || return 1
  if ! json=$(fm_pr_forgejo_api GET "$owner" "$repo" "pulls/$number" 2>/dev/null) \
    || [ -z "$json" ]; then
    return 1
  fi
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" and (.state | type) == "string" and .state != ""
        and (.merged | type) == "boolean" and (.head.sha | type) == "string"
      then
        "state=" + .state,
        "merged=" + (.merged | tostring),
        "head=" + .head.sha
      else
        error("invalid pull request record")
      end' 2>/dev/null); then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      head=*) head=${line#head=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 3 ] || [ "$total" -ne 3 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; }; then
    return 1
  fi

  # Consumed by bin/fm-crew-state.sh passed_pr_detail.
  # shellcheck disable=SC2034
  FM_PR_RECORD_STATE=$state
  # Consumed by bin/fm-crew-state.sh passed_pr_detail and bin/fm-teardown.sh.
  # shellcheck disable=SC2034
  FM_PR_RECORD_MERGED=$merged
  # Consumed by bin/fm-teardown.sh pr_is_merged.
  # shellcheck disable=SC2034
  FM_PR_RECORD_HEAD=$head
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

# --- degraded ready-PR marker -------------------------------------------------
# A ready PR/MR that degraded after its ready report - GitHub required checks
# turning failing, GitLab leaving an active merge train or a failing head
# pipeline - wakes once per observed head/pipeline identity. The marker below
# carries the identity that last woke, so the same degraded state stays silent
# on later polls while a changed identity (a new head, a new failing pipeline)
# wakes again. The identity is what the static poll (bin/fm-pr-poll.sh) emits
# after its "degraded " prefix, and both sides validate it so a forged or
# malformed line can never enter the marker.
fm_pr_poll_degraded_identity_valid() {  # <identity>
  local identity=${1-} value
  local LC_ALL=C
  case $identity in
    head=*)
      value=${identity#head=}
      [ "${#value}" -eq 40 ] || return 1
      case $value in
        *[!0-9a-f]*) return 1 ;;
      esac
      ;;
    pipeline=*)
      value=${identity#pipeline=}
      case $value in
        [1-9]*) ;;
        *) return 1 ;;
      esac
      case $value in
        *[!0-9]*) return 1 ;;
      esac
      [ "${#value}" -le 18 ] || return 1
      ;;
    train=on|train=dropped) ;;
    *) return 1 ;;
  esac
}

fm_pr_poll_degraded_marker_matches() {  # <marker> <device> <provider> <host> <path> <number> <identity>
  local marker=$1 device=$2 expected_provider=$3 expected_host=$4 expected_path=$5 expected_number=$6 expected_identity=$7
  local version provider host path number identity
  fm_pr_private_file_valid "$marker" 600 "$device" || return 1
  exec 8< "$marker" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  IFS= read -r identity <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  [ "$version" = fm-pr-poll-degraded-notified-v1 ] \
    && [ "$provider" = "$expected_provider" ] \
    && [ "$host" = "$expected_host" ] \
    && [ "$path" = "$expected_path" ] \
    && [ "$number" = "$expected_number" ] \
    && [ "$identity" = "$expected_identity" ]
}

fm_pr_poll_degraded_already_notified() {  # <state> <id> <provider> <host> <path> <number> <identity>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 identity=$7 marker state_device
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_poll_degraded_identity_valid "$identity" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  if [ "$identity" = train=on ]; then
    marker="$state/$id.pr-poll-train"
  else
    marker="$state/$id.pr-poll-degraded"
  fi
  fm_pr_poll_degraded_marker_matches "$marker" "$state_device" \
    "$provider" "$host" "$path" "$number" "$identity"
}

fm_pr_poll_degraded_mark_notified() {  # <state> <id> <provider> <host> <path> <number> <identity>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 identity=$7 marker tmp state_device
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_poll_degraded_identity_valid "$identity" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  if [ "$identity" = train=on ]; then
    marker="$state/$id.pr-poll-train"
  else
    marker="$state/$id.pr-poll-degraded"
  fi
  fm_pr_regular_destination_on_device_or_absent "$marker" "$state_device" || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-pr-poll-degraded.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-degraded-notified-v1 "$provider" "$host" "$path" "$number" "$identity" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_poll_degraded_marker_matches "$tmp" "$state_device" \
      "$provider" "$host" "$path" "$number" "$identity" \
    || ! fm_pr_regular_destination_on_device_or_absent "$marker" "$state_device" \
    || ! mv -f -- "$tmp" "$marker" \
    || ! fm_pr_poll_degraded_marker_matches "$marker" "$state_device" \
      "$provider" "$host" "$path" "$number" "$identity"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Removed at teardown alongside the other per-task PR-poll artifacts
# (bin/fm-teardown.sh) so a retired task id leaves no residue behind.
fm_pr_poll_degraded_remove() {  # <state> <id>
  local state=$1 id=$2 marker
  fm_pr_task_id_valid "$id" || return 1
  marker="$state/$id.pr-poll-degraded"
  [ ! -e "$marker" ] && [ ! -L "$marker" ] || {
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    rm -f -- "$marker" || return 1
  }
  fm_pr_poll_train_clear "$state" "$id"
}

# Forgets that the merge request was seen on its merge train; the watcher calls
# it after waking for a drop, so only a later re-queue arms the next drop wake.
fm_pr_poll_train_clear() {  # <state> <id>
  local state=$1 id=$2 marker
  fm_pr_task_id_valid "$id" || return 1
  marker="$state/$id.pr-poll-train"
  [ ! -e "$marker" ] && [ ! -L "$marker" ] || {
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    rm -f -- "$marker"
  }
}
