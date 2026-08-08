#!/usr/bin/env bash
# fm-pr-url-lib.sh - parses a PR URL into forge, host, owner, repo, and number.
#
# Three forges are recognized by URL shape alone, never by a hostname allowlist:
#   GitHub    - https://github.com/<owner>/<repo>/pull/<number>          (singular "pull")
#   Gitea     - https://<host>/<owner>/<repo>/pulls/<number>             (plural "pulls",
#               any self-hosted host)
#   Bitbucket - https://<host>/<workspace>/<repo>/pull-requests/<number> (plural
#               "pull-requests", any host; bitbucket.org for Cloud, a self-hosted
#               host for Server/Data Center)
# This is the shared recognition point so fm-pr-check.sh, fm-pr-merge.sh, and
# fm-teardown.sh dispatch consistently (gh, tea, or a manual Bitbucket path)
# instead of each duplicating the regex.
#
# fm_parse_pr_url <url>: on a match, sets FM_PR_FORGE (github|gitea|bitbucket),
# FM_PR_HOST, FM_PR_OWNER, FM_PR_REPO, FM_PR_NUMBER and returns 0. On no match,
# clears all five and returns 1; the caller reports its own error message.
#
# Sourced by fm-pr-check.sh, fm-pr-merge.sh, fm-teardown.sh, and their tests. No
# side effects on source. set -u / set -e safe.

# shellcheck disable=SC2034 # FM_PR_* are read by callers (fm-pr-check.sh, fm-pr-merge.sh, fm-teardown.sh) after sourcing.
fm_parse_pr_url() {
  local url=$1
  FM_PR_FORGE=
  FM_PR_HOST=
  FM_PR_OWNER=
  FM_PR_REPO=
  FM_PR_NUMBER=
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    [[ "${BASH_REMATCH[1]}" == *- ]] && return 1
    FM_PR_FORGE=github
    FM_PR_HOST=github.com
    FM_PR_OWNER=${BASH_REMATCH[1]}
    FM_PR_REPO=${BASH_REMATCH[2]}
    FM_PR_NUMBER=${BASH_REMATCH[3]}
    return 0
  fi
  if [[ "$url" =~ ^https://([A-Za-z0-9.-]+(:[0-9]+)?)/([A-Za-z0-9][A-Za-z0-9._-]{0,38})/([A-Za-z0-9._-]+)/pulls/([0-9]+)/?$ ]]; then
    FM_PR_FORGE=gitea
    FM_PR_HOST=${BASH_REMATCH[1]}
    FM_PR_OWNER=${BASH_REMATCH[3]}
    FM_PR_REPO=${BASH_REMATCH[4]}
    FM_PR_NUMBER=${BASH_REMATCH[5]}
    return 0
  fi
  if [[ "$url" =~ ^https://([A-Za-z0-9.-]+(:[0-9]+)?)/([A-Za-z0-9][A-Za-z0-9._-]{0,38})/([A-Za-z0-9._-]+)/pull-requests/([0-9]+)/?$ ]]; then
    FM_PR_FORGE=bitbucket
    FM_PR_HOST=${BASH_REMATCH[1]}
    FM_PR_OWNER=${BASH_REMATCH[3]}
    FM_PR_REPO=${BASH_REMATCH[4]}
    FM_PR_NUMBER=${BASH_REMATCH[5]}
    return 0
  fi
  return 1
}
