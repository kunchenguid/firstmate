#!/usr/bin/env bash
# Tests for bin/fm-pr-lib.sh's fm_pr_url_parse: the canonical URL parser that
# every forge-aware firstmate script consults to know the provider, host, path,
# and PR number. Coverage:
#
#   (a) GitHub PR URL parses with provider=github, host=github.com
#   (b) GitLab MR URL parses with provider=gitlab, host from the URL
#   (c) Gitea PR URL parses with provider=gitea, host from the URL
#   (d) Gitea-shaped URL on github.com is refused (no spoofing)
#   (e) Gitea-shaped URL with leading/trailing path noise is refused
#   (f) Empty input refuses
#   (g) Number-zero URL refuses (PR numbers start at 1)
#   (h) Host with uppercase letters refuses (canonical lowercase DNS)
#   (i) Empty host refuses
#   (j) Path with reserved "-" segment refuses (GitLab convention applies to
#       Gitea too because the host/path validators are shared)
#   (k) Plausible but malformed URL refuses
#
# Run with: bash tests/fm-pr-url-parse.test.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$ROOT/bin/fm-pr-lib.sh"

pass=0 fail=0
report() {
  if [ "$1" = 0 ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$2"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n' "$2" >&2
  fi
}

# (a) GitHub
fm_pr_url_parse "https://github.com/octocat/Hello-World/pull/42"
[ "$FM_PR_PROVIDER" = github ] && [ "$FM_PR_HOST" = github.com ] \
  && [ "$FM_PR_PATH" = octocat/Hello-World ] && [ "$FM_PR_NUMBER" = 42 ]
  report "$?" "github PR parses"

# (b) GitLab
fm_pr_url_parse "https://gitlab.example.com/group/sub/proj/-/merge_requests/7"
[ "$FM_PR_PROVIDER" = gitlab ] && [ "$FM_PR_HOST" = gitlab.example.com ] \
  && [ "$FM_PR_PATH" = group/sub/proj ] && [ "$FM_PR_NUMBER" = 7 ]
  report "$?" "gitlab MR parses with host and nested path"

# (c) Gitea
fm_pr_url_parse "https://git.vrvlab.dev/popovikj/stela/pulls/4"
[ "$FM_PR_PROVIDER" = gitea ] && [ "$FM_PR_HOST" = git.vrvlab.dev ] \
  && [ "$FM_PR_PATH" = popovikj/stela ] && [ "$FM_PR_NUMBER" = 4 ]
  report "$?" "gitea PR parses with /pulls/<n>"

# (d) Gitea shape on github.com is refused
fm_pr_url_parse "https://github.com/octocat/Hello-World/pulls/42" || rc=$?
rc=0
fm_pr_url_parse "https://github.com/octocat/Hello-World/pulls/42" || rc=$?
[ "$rc" != 0 ]
report "$?" "gitea-shaped URL on github.com refuses"

# (e) Gitea URL with a stray suffix is refused
rc=0
fm_pr_url_parse "https://git.vrvlab.dev/popovikj/stela/pulls/4/extra" || rc=$?
[ "$rc" != 0 ]
report "$?" "gitea URL with trailing /extra refuses"

# (f) Empty input refuses
rc=0
fm_pr_url_parse "" || rc=$?
[ "$rc" != 0 ]
report "$?" "empty URL refuses"

# (g) Zero PR number refuses
rc=0
fm_pr_url_parse "https://git.vrvlab.dev/popovikj/stela/pulls/0" || rc=$?
[ "$rc" != 0 ]
report "$?" "zero PR number refuses"

# (h) Uppercase host refuses
rc=0
fm_pr_url_parse "https://GIT.VRVLAB.DEV/popovikj/stela/pulls/4" || rc=$?
[ "$rc" != 0 ]
report "$?" "uppercase host refuses"

# (i) Empty host (between scheme and slash) refuses
rc=0
fm_pr_url_parse "https:///popovikj/stela/pulls/4" || rc=$?
[ "$rc" != 0 ]
report "$?" "empty host refuses"

# (j) Reserved "-" segment in path refuses (GitLab convention applied)
rc=0
fm_pr_url_parse "https://git.vrvlab.dev/-/stela/pulls/4" || rc=$?
[ "$rc" != 0 ]
report "$?" "path starting with reserved - refuses"

# (k) Garbage refuses
rc=0
fm_pr_url_parse "not a url at all" || rc=$?
[ "$rc" != 0 ]
report "$?" "garbage refuses"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]