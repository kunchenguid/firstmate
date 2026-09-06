#!/usr/bin/env bash
# tests/fm-backlog-transition-lib.test.sh - unit tests for the recorded-close
# marker validator (bin/fm-backlog-transition-lib.sh). These drive
# fm_backlog_close_marker_stage through its function interface against a real
# on-disk home; no backlog backend and no harness are required.
#
# Focus: the `--pr` completion-link argument. A self-hosted Gitea/Forgejo
# instance can be plain http on a non-standard port (bin/fm-pr-lib.sh), so the
# validator must accept that PR URL when the instance base URL is allow-listed
# in config/gitea-instances - and still reject a plain-http URL for any host
# that is not.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$ROOT/bin/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$ROOT/bin/fm-backlog-transition-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backlog-transition-lib)

FM_HOME="$TMP_ROOT/home"
export FM_HOME
mkdir -p "$FM_HOME/state" "$FM_HOME/data" "$FM_HOME/config"

MARKER="$FM_HOME/state/.probe.backlog-close.test"

# stage_pr <config-body> <pr-url>: write config/gitea-instances, then stage a
# close marker carrying that --pr link. Returns the stage exit status; leaves
# the staged file at $MARKER on success.
stage_pr() {
  printf '%s' "$1" > "$FM_HOME/config/gitea-instances"
  rm -f "$MARKER"
  fm_backlog_close_marker_stage "$MARKER" probe "$FM_HOME/data" spawn-1 \
    "$FM_HOME/state" "$FM_HOME/config" 0 --pr "$2"
}

# --- allow-listed plain-http Gitea PR URL is accepted ----------------------

if stage_pr 'http://alps:3222'$'\n' 'http://alps:3222/babbarc/server-ops/pulls/1'; then
  grep -qx 'arg=http://alps:3222/babbarc/server-ops/pulls/1' "$MARKER" \
    || fail "the staged marker did not carry the plain-http Gitea PR link verbatim"
  pass "stage accepts a plain-http Gitea PR URL whose instance is allow-listed and records it verbatim"
else
  fail "stage rejected an allow-listed plain-http Gitea PR URL: $FM_BACKLOG_TRANSITION_ERROR"
fi

# --- a plain-http PR URL for a non-allow-listed host is still rejected -----

if stage_pr '' 'http://alps:3222/babbarc/server-ops/pulls/1'; then
  fail "stage accepted a plain-http Gitea PR URL with no allow-list entry"
fi
[ -n "$FM_BACKLOG_TRANSITION_ERROR" ] \
  || fail "stage rejected the unlisted plain-http URL without setting an error"
pass "stage rejects a plain-http PR URL whose instance is not allow-listed"

if stage_pr 'http://alps:3222'$'\n' 'http://elsewhere:3222/owner/repo/pulls/1'; then
  fail "stage accepted a plain-http PR URL for a host outside the allow-list"
fi
pass "stage rejects a plain-http PR URL for a host that is not the allow-listed one"

# --- https URLs keep their pre-existing generic acceptance ----------------

if ! stage_pr '' 'https://github.com/babbarc/server-ops/pull/1'; then
  fail "stage rejected an https GitHub PR URL: $FM_BACKLOG_TRANSITION_ERROR"
fi
pass "stage still accepts an https GitHub PR URL with no Gitea allow-list configured"

if ! stage_pr '' 'https://gitea.example.com/babbarc/server-ops/pulls/1'; then
  fail "stage rejected an https Gitea PR URL: $FM_BACKLOG_TRANSITION_ERROR"
fi
pass "stage still accepts an https Gitea PR URL without requiring an allow-list entry"

# --- the scheme strip handles both schemes -------------------------------

# A bare scheme with no authority or path must fail the shape check under
# either scheme (the strip must not leave a stale https:// prefix behind).
if stage_pr 'http://alps:3222'$'\n' 'http://'; then
  fail "stage accepted a bare http:// scheme with no host or path"
fi
if stage_pr '' 'https://'; then
  fail "stage accepted a bare https:// scheme with no host or path"
fi
pass "stage rejects a bare scheme under both http and https after the scheme strip"

# --- fm_backlog_done records a Gitea link as a note, not a structured --pr ---
#
# The backlog backend rejects a structured --pr link that does not end in
# /pull/<n>, so a Gitea/Forgejo PR URL is applied as a completion note instead.
# GitHub and GitLab keep the structured link.

BACKLOG="$FM_HOME/data/backlog.md"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$BACKLOG"

done_with_pr() {  # <id> <pr-url>
  tasks-axi add "$1" "row for $1" --file "$BACKLOG" >/dev/null
  tasks-axi start "$1" --file "$BACKLOG" >/dev/null
  fm_backlog_done "$FM_HOME/data" "$1" --pr "$2"
}

done_with_pr gitea-note 'http://alps:3222/babbarc/server-ops/pulls/1' \
  || fail "fm_backlog_done failed on a Gitea PR URL: $FM_BACKLOG_TRANSITION_ERROR"
show=$(tasks-axi show gitea-note --file "$BACKLOG")
printf '%s\n' "$show" | grep -q 'body: "PR http://alps:3222/babbarc/server-ops/pulls/1"' \
  || fail "the Gitea PR link was not recorded as a completion note: $show"
printf '%s\n' "$show" | grep -q 'links: none' \
  || fail "the Gitea PR link was written to the structured link field: $show"
pass "fm_backlog_done records a Gitea PR URL as a completion note and leaves the structured link empty"

done_with_pr github-link 'https://github.com/babbarc/server-ops/pull/9' \
  || fail "fm_backlog_done failed on a GitHub PR URL: $FM_BACKLOG_TRANSITION_ERROR"
show=$(tasks-axi show github-link --file "$BACKLOG")
printf '%s\n' "$show" | grep -q 'links: "pr:https://github.com/babbarc/server-ops/pull/9"' \
  || fail "a GitHub PR URL lost its structured link: $show"
pass "fm_backlog_done keeps a GitHub PR URL in the structured link field"

echo "# fm-backlog-transition-lib.test.sh: all assertions passed"
