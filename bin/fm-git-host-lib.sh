#!/usr/bin/env bash
# fm-git-host-lib.sh - git-host classification and PR/MR URL parsing.
#
# firstmate's PR/merge/teardown machinery is GitHub-only today: it shells out to
# gh/gh-axi, parses https://github.com/<owner>/<repo>/pull/<n> URLs, and fetches
# refs/pull/<n>/head. This library is the foundation increment for adding GitLab
# support: it centralizes the two host-dependent primitives every later increment
# needs, so the merge/check path (increment #2) and the teardown landed-work path
# (increment #3) each consume ONE parser instead of re-spelling host-detection and
# URL-shape logic. The rationale (host inferred from a project's `origin` remote
# rather than a registry field; the `pr=`/`pr_head=` meta contract staying
# host-agnostic; `glab` called directly like fm-pr-check.sh already calls raw gh)
# is recorded in docs/glab-backend.md.
#
# Two host kinds are recognized, `github` and `gitlab`; anything else is
# `unknown`. GitLab covers gitlab.com AND self-hosted gitlab.* hostnames, so the
# classifier stays general even though the captain's projects are on gitlab.com.
#
# Sourced by later bin/ scripts and by the tests. No side effects on source, no
# network, no globals written. set -u / set -e safe. Pure string functions.
#
# ---------------------------------------------------------------------------
# Output contract (stable; increments #2/#3 parse this):
#
#   fm_git_remote_host <remote-url>
#     Prints the bare hostname of a git remote URL (as produced by
#     `git remote get-url origin`) on stdout, no trailing path/port/user, then a
#     newline. Handles scp-like SSH (git@host:path), scheme SSH
#     (ssh://[user@]host[:port]/path), and https/http/git URLs. Returns non-zero
#     and prints nothing for a URL with no recognizable host (e.g. a local path).
#
#   fm_git_host_classify <remote-url>
#     Prints exactly one token - `github`, `gitlab`, or `unknown` - and a
#     newline. Always returns 0: an unparseable or unrecognized URL classifies as
#     `unknown`, never an error. Tolerates a trailing `.git` and trailing slashes
#     because those live in the path, which host extraction discards.
#
#   fm_pr_url_parse <pr-or-mr-url>
#     Parses a PR or MR web URL. On a recognized URL, prints ONE tab-separated
#     record and a newline:
#         <kind>\t<host>\t<path>\t<number>
#       kind   - `github` or `gitlab`
#       host   - the hostname (e.g. github.com, gitlab.com, gitlab.example.com)
#       path   - the repo/namespace path: exactly `<owner>/<repo>` for GitHub;
#                the full variable-depth namespace for GitLab (one or more
#                segments, e.g. goosehead-insurance/custom-dev/goosehead-apps),
#                captured greedily up to the `/-/merge_requests/` marker.
#       number - the PR number or MR iid.
#     Returns 0 on a match. On any malformed/unrecognized URL it returns non-zero
#     and prints NOTHING to stdout (no partial garbage), mirroring the reject
#     discipline of bin/fm-pr-merge.sh's parse_pr_url. Recognized shapes:
#       GitHub: https://github.com/<owner>/<repo>/pull/<n>   (path = 2 segments)
#       GitLab: https://<host>/<namespace>/-/merge_requests/<iid>
#     A trailing slash is tolerated on both shapes.
# ---------------------------------------------------------------------------

# fm_git_remote_host <remote-url> -> hostname on stdout (no newline-only path),
# non-zero when no host can be extracted.
fm_git_remote_host() {  # <remote-url>
  local url=$1 host
  case "$url" in
    ssh://*|https://*|http://*|git://*)
      # scheme://[user@]host[:port]/path
      host=${url#*://}     # strip scheme
      host=${host#*@}      # strip optional user@ (unchanged when absent)
      host=${host%%/*}     # strip path
      host=${host%%:*}     # strip optional :port
      ;;
    *:*)
      # scp-like SSH: [user@]host:path (the case that has no scheme)
      host=${url%%:*}      # host part before the first colon
      host=${host#*@}      # strip optional user@
      ;;
    *)
      return 1
      ;;
  esac
  [ -n "$host" ] || return 1
  printf '%s\n' "$host"
}

# fm_git_host_classify <remote-url> -> github|gitlab|unknown (always returns 0).
fm_git_host_classify() {  # <remote-url>
  local host
  host=$(fm_git_remote_host "$1") || { printf 'unknown\n'; return 0; }
  case "$host" in
    github.com|*.github.com) printf 'github\n' ;;
    gitlab.com|gitlab.*|*.gitlab.com) printf 'gitlab\n' ;;
    *) printf 'unknown\n' ;;
  esac
  return 0
}

# fm_pr_url_parse <pr-or-mr-url> -> "<kind>\t<host>\t<path>\t<number>" on stdout,
# non-zero with empty stdout on any malformed URL.
fm_pr_url_parse() {  # <pr-or-mr-url>
  local url=$1
  # GitLab MR: https://<host>/<namespace>/-/merge_requests/<iid>. The namespace
  # is variable-depth (one or more segments), captured greedily up to the single
  # /-/merge_requests/ marker. Restricted char classes reject spaces and shell
  # metacharacters, so a crafted URL fails to match rather than yielding garbage.
  if [[ "$url" =~ ^https://([A-Za-z0-9._-]+)/([A-Za-z0-9._/-]+)/-/merge_requests/([0-9]+)/?$ ]]; then
    printf 'gitlab\t%s\t%s\t%s\n' \
      "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi
  # GitHub PR: https://github.com/<owner>/<repo>/pull/<n>, exactly two path
  # segments before /pull/. Mirrors bin/fm-pr-merge.sh's owner/repo grammar.
  if [[ "$url" =~ ^https://(github\.com)/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    if [[ "${BASH_REMATCH[2]}" != *- ]]; then
      printf 'github\t%s\t%s/%s\t%s\n' \
        "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
      return 0
    fi
  fi
  return 1
}
