#!/usr/bin/env bash
# Shared reads and validation for the forge=external review rail: a project
# whose reviews are created by a review tool that uploads its own snapshot of
# the worker's local commits, so a worker never pushes a branch to publish
# (bin/fm-project-mode.sh's header owns the binding; docs/external-review-forge.md
# owns the design). Sourced by bin/fm-dod-lib.sh, bin/fm-spawn.sh, and
# bin/fm-review-check.sh.
#
# The home configuration lives under the gitignored config directory
# (docs/configuration.md "External review tool" owns the schema):
#   external-review.md      required; the worker instructions for the home's
#                           review tool, rendered verbatim into the Definition
#                           of done.
#   external-review-url     optional; one ERE a ready review URL must match in full.
#   external-review-backup  optional; line 1 names the personal backup remote,
#                           optional line 2 is `prefix=<ref-prefix>` (default
#                           `backup/`).
# Every reader refuses an unusable file rather than proceeding without it,
# because a worker with no upload instructions, or a spawn without the backup
# protection the captain configured, would otherwise improvise a push.

FM_REVIEW_URL=
FM_REVIEW_BACKUP_REMOTE=
FM_REVIEW_BACKUP_PREFIX=

# shellcheck source=bin/fm-pr-lib.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-pr-lib.sh"

# The config directory the renderers and spawn read, resolved the same way
# bin/fm-dod-lib.sh resolves config/wait-no-turns.
fm_external_review_config_dir() {
  printf '%s\n' "${CONFIG:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}}"
}

# 0 when <path> is absent; 1 when it is a readable regular file; 2 (with an
# error on stderr) when it exists but cannot be used.
fm_external_review_file_state() {  # <path>
  local path=$1
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  if [ -f "$path" ] && [ -r "$path" ]; then
    return 1
  fi
  echo "error: $path must be a readable regular file" >&2
  return 2
}

# Validate a ready review URL and set FM_REVIEW_URL. It must be https with a
# valid host, carry no whitespace, control character, query, or fragment, and
# must not be a forge pull request or change URL bin/fm-pr-lib.sh parses, so a
# review= record and a pr= record can never name the same thing. When
# <config>/external-review-url exists its one ERE must match the whole URL.
fm_external_review_url_parse() {  # <url> [<config-dir>]
  local raw=${1-} cfg=${2:-} pattern host file ere rc=0
  local LC_ALL=C
  FM_REVIEW_URL=
  [ -n "$cfg" ] || cfg=$(fm_external_review_config_dir)
  case "$raw" in
    *[[:space:][:cntrl:]]*|*'?'*|*'#'*) return 1 ;;
  esac
  pattern='^https://([a-z0-9.-]{1,253})(/[^[:space:]]*)?$'
  [[ "$raw" =~ $pattern ]] || return 1
  host=${BASH_REMATCH[1]}
  fm_pr_forge_host_valid "$host" || return 1
  if ( fm_pr_url_parse "$raw" ); then
    return 1
  fi
  file="$cfg/external-review-url"
  fm_external_review_file_state "$file" || rc=$?
  case "$rc" in
    0) ;;
    1)
      ere=$(grep -v '^[[:space:]]*$' "$file" | head -n 1)
      if [ -z "$ere" ]; then
        echo "error: $file holds no pattern" >&2
        return 1
      fi
      printf '%s\n' "$raw" | grep -Eqx -e "$ere" || return 1
      ;;
    *) return 1 ;;
  esac
  # shellcheck disable=SC2034 # Output global read by sourcing callers.
  FM_REVIEW_URL=$raw
  return 0
}

# Print the verbatim body of <config>/external-review.md. Refuses a missing,
# unreadable, or empty adapter, and one carrying a `Delivery contract: mode=`
# line, which would compete with the contract line bin/fm-spawn.sh reads.
fm_external_review_adapter_body() {  # [<config-dir>]
  local cfg=${1:-} file body rc=0
  [ -n "$cfg" ] || cfg=$(fm_external_review_config_dir)
  file="$cfg/external-review.md"
  fm_external_review_file_state "$file" || rc=$?
  case "$rc" in
    0)
      echo "error: forge=external needs $file, the worker instructions for this home's review tool (docs/configuration.md \"External review tool\"); without it a worker has no way to publish except a push" >&2
      return 1 ;;
    1) ;;
    *) return 1 ;;
  esac
  body=$(cat "$file") || {
    echo "error: $file must be a readable regular file" >&2
    return 1
  }
  if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
    echo "error: $file is empty; it must hold the worker instructions for this home's review tool" >&2
    return 1
  fi
  if printf '%s\n' "$body" | grep -q '^Delivery contract: mode='; then
    echo "error: $file must not carry a 'Delivery contract: mode=' line; the delivery contract is rendered by bin/fm-dod-lib.sh" >&2
    return 1
  fi
  printf '%s\n' "$body"
}

# Read the optional personal backup remote and set FM_REVIEW_BACKUP_REMOTE and
# FM_REVIEW_BACKUP_PREFIX; both stay empty when no backup is configured. A
# backup prefix must be non-empty and form a valid branch name; the remote must
# be a plain remote name and never `origin`.
fm_external_review_backup() {  # [<config-dir>]
  local cfg=${1:-} file remote second prefix rc=0
  FM_REVIEW_BACKUP_REMOTE=
  FM_REVIEW_BACKUP_PREFIX=
  [ -n "$cfg" ] || cfg=$(fm_external_review_config_dir)
  file="$cfg/external-review-backup"
  fm_external_review_file_state "$file" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) ;;
    *) return 1 ;;
  esac
  remote=$(sed -n '1p' "$file")
  second=$(sed -n '2p' "$file")
  if [ -n "$(sed -n '3,$p' "$file" | tr -d '[:space:]')" ]; then
    echo "error: $file holds more than a remote line and an optional prefix= line" >&2
    return 1
  fi
  case "$remote" in
    ''|-*|*[!A-Za-z0-9._-]*)
      echo "error: $file line 1 must name a git remote (letters, digits, '.', '_', '-')" >&2
      return 1 ;;
    origin)
      echo "error: $file names origin; the backup remote is the captain's personal remote, never the shared origin" >&2
      return 1 ;;
  esac
  prefix=backup/
  if [ -n "$second" ]; then
    case "$second" in
      prefix=*) prefix=${second#prefix=} ;;
      *)
        echo "error: $file line 2 must be prefix=<ref-prefix>" >&2
        return 1 ;;
    esac
  fi
  if [ -z "$prefix" ] || ! git check-ref-format "refs/heads/${prefix}x" >/dev/null 2>&1; then
    echo "error: $file backup prefix '$prefix' must be non-empty and form a valid branch name" >&2
    return 1
  fi
  # shellcheck disable=SC2034 # Output globals read by sourcing callers.
  FM_REVIEW_BACKUP_REMOTE=$remote
  # shellcheck disable=SC2034 # Output globals read by sourcing callers.
  FM_REVIEW_BACKUP_PREFIX=$prefix
  return 0
}

# 0 when a backup prefix stays out of the task's delivery namespace: it must not
# equal or start with a non-empty task branch prefix. 1 otherwise, with a reason.
fm_external_review_prefix_disjoint() {  # <backup-prefix> <task-prefix>
  local backup=$1 task=$2
  [ -n "$task" ] || return 0
  case "$backup" in
    "$task"*)
      echo "error: backup prefix '$backup' equals or starts with the task branch prefix '$task'; a durable copy must never read as a delivery branch" >&2
      return 1 ;;
  esac
  return 0
}

# A remote URL in the one spelling the push guard compares: trailing slashes
# and one trailing .git removed.
fm_external_review_url_normalize() {  # <url>
  local url=$1
  while [ "${url%/}" != "$url" ]; do url=${url%/}; done
  url=${url%.git}
  while [ "${url%/}" != "$url" ]; do url=${url%/}; done
  printf '%s\n' "$url"
}

# Print the normalized fetch and push URLs of every remote <name> in <repo>,
# one per line, deduplicated. Prints nothing when the remote is absent.
fm_external_review_remote_urls() {  # <repo> <remote>
  local repo=$1 name=$2 url
  {
    git -C "$repo" remote get-url --all "$name" 2>/dev/null
    git -C "$repo" remote get-url --push --all "$name" 2>/dev/null
  } | while IFS= read -r url; do
    [ -z "$url" ] || fm_external_review_url_normalize "$url"
  done | awk '!seen[$0]++'
}
