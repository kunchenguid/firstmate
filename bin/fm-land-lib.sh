# shellcheck shell=bash
# fm-land-lib.sh - shared landing guards for local-only and PR merge paths.
#
# Source this file. bin/fm-merge-local.sh and bin/fm-pr-merge.sh consult it
# before landing work onto a project's default branch. docs/configuration.md
# "Landing behind-main guard" owns the threshold override.
#
# A branch is "behind" the default by the number of commits reachable from the
# default tip that are not reachable from the branch tip (default..branch in
# rev-list terms is ahead; branch..default is behind).

FM_LAND_MAX_BEHIND_MAIN_DEFAULT=20

fm_land_max_behind_main() {
  local max=${FM_LAND_MAX_BEHIND_MAIN:-$FM_LAND_MAX_BEHIND_MAIN_DEFAULT}
  case "$max" in ''|*[!0-9]*) max=$FM_LAND_MAX_BEHIND_MAIN_DEFAULT ;; esac
  printf '%s' "$max"
}

# Echo how many commits on <default> are not reachable from <branch> in <repo>.
# Returns non-zero when the count cannot be determined.
fm_land_commits_behind_default() {  # <repo> <branch> <default>
  local repo=$1 branch=$2 default=$3 count
  count=$(git -C "$repo" rev-list --count "$branch..$default" 2>/dev/null) || return 1
  case "$count" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$count"
}

# 0 when <branch> in <repo> is at or beyond the configured behind-main ceiling.
fm_land_branch_too_far_behind_default() {  # <repo> <branch> <default>
  local repo=$1 branch=$2 default=$3 behind max
  behind=$(fm_land_commits_behind_default "$repo" "$branch" "$default") || return 1
  max=$(fm_land_max_behind_main)
  [ "$behind" -ge "$max" ]
}

# Refuse landing when too far behind; prints a REFUSED line to stderr and returns 1.
fm_land_refuse_if_too_far_behind_default() {  # <repo> <branch> <default> [<label>]
  local repo=$1 branch=$2 default=$3 label=${4:-$branch} behind max
  behind=$(fm_land_commits_behind_default "$repo" "$branch" "$default") || {
    echo "REFUSED: could not measure how far $label is behind $default" >&2
    return 1
  }
  max=$(fm_land_max_behind_main)
  if [ "$behind" -ge "$max" ]; then
    echo "REFUSED: $label is $behind commits behind $default (>= $max); not landing to main; keep the branch and rebase later." >&2
    return 1
  fi
  return 0
}
