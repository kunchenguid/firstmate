#!/usr/bin/env bash
# Shared GitLab issue-URL identity for firstmate.
#
# One canonical parse of an issue URL, so every surface that accepts one -
# bin/fm-gitlab-issue.sh, bin/fm-brief.sh's --issue, and bin/fm-spawn.sh's
# --issue - accepts and refuses exactly the same URLs and records exactly the
# same canonical spelling. The host and project-path rules themselves stay in
# bin/fm-pr-lib.sh, which owns them for every GitLab surface.
#
# fm_gitlab_issue_url_parse <url>
#   Accepts https://<host>/<group>[/<subgroup>...]/<project>/-/issues/<iid>.
#   Nested subgroups are ordinary path segments; a trailing "#note_<id>"
#   fragment and one trailing "/" are ignored. The host must be a plain DNS
#   name (no port, no userinfo) and is lowercased before use; the project path
#   is validated by bin/fm-pr-lib.sh's GitLab rules, which refuse the reserved
#   "-" segment. Returns 0 and sets FM_GITLAB_ISSUE_HOST,
#   FM_GITLAB_ISSUE_PATH, FM_GITLAB_ISSUE_IID, and FM_GITLAB_ISSUE_URL - the
#   canonical URL rebuilt from those parts, which is what callers store.
#   Returns non-zero and leaves all four empty for anything else.
#
# Sourced by the scripts above and by tests. No side effects on source beyond
# its sourced library.

_FM_GITLAB_ISSUE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_GITLAB_ISSUE_LIB_DIR/fm-pr-lib.sh"

FM_GITLAB_ISSUE_HOST=
FM_GITLAB_ISSUE_PATH=
FM_GITLAB_ISSUE_IID=
FM_GITLAB_ISSUE_URL=

# shellcheck disable=SC2034 # The four FM_GITLAB_ISSUE_* results are read by sourcing callers.
fm_gitlab_issue_url_parse() {  # <url>
  local raw=${1-} pattern host path iid
  local LC_ALL=C
  FM_GITLAB_ISSUE_HOST=
  FM_GITLAB_ISSUE_PATH=
  FM_GITLAB_ISSUE_IID=
  FM_GITLAB_ISSUE_URL=
  raw=${raw%%#*}
  # The path class contains "/" and "-", so this match is greedy to the last
  # "/-/issues/"; any earlier separator lands inside the captured path, where
  # fm_pr_gitlab_path_valid refuses the reserved "-" segment.
  pattern='^https://([A-Za-z0-9.-]{1,253})/([A-Za-z0-9._/-]+)/-/issues/([1-9][0-9]*)/?$'
  [[ "$raw" =~ $pattern ]] || return 1
  path=${BASH_REMATCH[2]}
  iid=${BASH_REMATCH[3]}
  host=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
  fm_pr_gitlab_host_valid "$host" || return 1
  fm_pr_gitlab_path_valid "$path" || return 1
  FM_GITLAB_ISSUE_HOST=$host
  FM_GITLAB_ISSUE_PATH=$path
  FM_GITLAB_ISSUE_IID=$iid
  FM_GITLAB_ISSUE_URL="https://$host/$path/-/issues/$iid"
}
