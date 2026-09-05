#!/usr/bin/env bash
# Shared deploy classification: what is pending, and which of it the captain owns.
#
# One classifier, sourced by bin/fm-deploy-status.sh (which reports) and
# bin/fm-deploy.sh (which refuses), so the two can never disagree about whether
# a range needs the captain's permission.
#
# The safety decision is made on the whole range's changed-path set
# (`git diff --name-only <from> <to>`), never per commit. A merge commit's
# `git diff-tree` output is empty, so a per-commit walk would silently report a
# merged design change as auto-deployable. Per-commit listing is used only for
# the human-readable pending display.
#
# A policy file is a plain list of path patterns, one per line, `#` comments and
# blank lines ignored. A pattern is a bash pattern in which `*` matches any
# characters INCLUDING `/`, so `dashboard/v2/src/**` covers the whole subtree and
# `openspec/changes/dashboard-v21-*` covers every file under every matching
# directory. docs/configuration.md owns the operator-facing description.
#
# No policy file means no deploy automation for that project at all: every entry
# point that consumes this library stays inert rather than defaulting to
# auto-deployable. Absence is the off switch, not permission.
#
# Sourced only; no side effects on source.

# fm_deploy_config_dir <home>
fm_deploy_config_dir() { printf '%s/config' "${1%/}"; }

# fm_deploy_policy_file <home> <project>
fm_deploy_policy_file() {
  printf '%s/deploy-policy/%s' "$(fm_deploy_config_dir "$1")" "$2"
}

# fm_deploy_target_file <home> <project>
fm_deploy_target_file() {
  printf '%s/deploy-target/%s' "$(fm_deploy_config_dir "$1")" "$2"
}

# fm_deploy_policy_readable <file>
# A policy must be a regular file, never a symlink: it decides what ships
# without the captain, so it is not something an unrelated link may redirect.
fm_deploy_policy_readable() {
  [ -n "${1:-}" ] && [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]
}

# fm_deploy_policy_patterns <policy-file>
# Prints one pattern per line, comments and blanks removed.
fm_deploy_policy_patterns() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    # Trim surrounding whitespace without a subshell.
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
  done <"$1"
}

# fm_deploy_path_captain_pattern <path> <pattern>...
# Prints the first pattern that claims <path> and returns 0; returns 1 when none
# does.
fm_deploy_path_captain_pattern() {
  local path=$1 pattern
  shift
  for pattern in "$@"; do
    # Deliberately unquoted: $pattern is a bash pattern, and `*` crosses `/`
    # here because this is string matching, not pathname expansion.
    # shellcheck disable=SC2053
    if [[ $path == $pattern ]]; then
      printf '%s\n' "$pattern"
      return 0
    fi
  done
  return 1
}

# fm_deploy_sha_valid <sha>
# A deployed checkout must report a full 40-hex commit. Anything else - a branch
# name, a short sha, an error string - is a checkout that deploy/PROVISIONING.md
# forbids ("an exact commit, never a moving branch"), and must surface rather
# than be treated as a deployable baseline.
fm_deploy_sha_valid() {
  case "${1:-}" in
    *[!0-9a-f]* | '') return 1 ;;
  esac
  [ "${#1}" -eq 40 ]
}

# fm_deploy_classify <repo> <from-sha> <to-sha> <policy-file>
#
# Sets, on success:
#   FM_DEPLOY_PENDING       newline-separated "<short-sha> <subject>" pending commits
#   FM_DEPLOY_PENDING_COUNT how many
#   FM_DEPLOY_CAPTAIN       newline-separated "<pattern>\t<path>" captain-owned matches
#   FM_DEPLOY_CAPTAIN_COUNT how many changed paths the captain owns
#
# Returns 2 when the range is not a fast-forward: the host is on a commit that
# is not an ancestor of the target, so "what is pending" has no honest answer
# and nothing may be deployed on that basis.
fm_deploy_classify() {
  local repo=$1 from=$2 to=$3 policy=$4
  local patterns=() path claimed
  # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
  FM_DEPLOY_PENDING=''
  FM_DEPLOY_PENDING_COUNT=0
  FM_DEPLOY_CAPTAIN=''
  FM_DEPLOY_CAPTAIN_COUNT=0

  git -C "$repo" rev-parse --verify --quiet "$from^{commit}" >/dev/null || return 2
  git -C "$repo" rev-parse --verify --quiet "$to^{commit}" >/dev/null || return 2
  git -C "$repo" merge-base --is-ancestor "$from" "$to" || return 2

  if [ "$from" = "$to" ]; then
    return 0
  fi

  FM_DEPLOY_PENDING=$(git -C "$repo" log --no-merges --format='%h %s' "$from..$to") || return 1
  if [ -n "$FM_DEPLOY_PENDING" ]; then
    # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
    FM_DEPLOY_PENDING_COUNT=$(printf '%s\n' "$FM_DEPLOY_PENDING" | wc -l | tr -d ' ')
  fi

  if fm_deploy_policy_readable "$policy"; then
    mapfile -t patterns < <(fm_deploy_policy_patterns "$policy")
  fi
  [ "${#patterns[@]}" -gt 0 ] || return 0

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if claimed=$(fm_deploy_path_captain_pattern "$path" "${patterns[@]}"); then
      FM_DEPLOY_CAPTAIN="${FM_DEPLOY_CAPTAIN}${claimed}	${path}
"
      FM_DEPLOY_CAPTAIN_COUNT=$((FM_DEPLOY_CAPTAIN_COUNT + 1))
    fi
  done < <(git -C "$repo" diff --name-only "$from" "$to")

  return 0
}

# fm_deploy_json_escape <text>
# Minimal JSON string escaping for the durable ledger.
fm_deploy_json_escape() {
  local s=${1:-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  printf '%s' "$s"
}
