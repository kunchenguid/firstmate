#!/usr/bin/env bash
# Live guard for the vendor-emitted Claude account-profile auth predicate.
#
# The portable regression in tests/fm-spawn-dispatch-profile.test.sh drives a
# fake Claude CLI, so it can only confirm the assumption written into that fake.
# This guard runs the real installed CLI against the real predicate and pins the
# one fact the fake cannot establish: that `claude auth status --json` reports on
# the store named by CLAUDE_CONFIG_DIR rather than the ambient default. If the
# vendor ever ignored that variable, the preflight would accept a profile
# directory holding no credential.
#
# docs/verification/dispatch-auth.md records the dated result and names this
# script as the command that refreshes it.
set -u

if [ "${FM_CLAUDE_ACCOUNT_PROFILE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_ACCOUNT_PROFILE_LIVE_E2E=1 to run the installed-Claude account-profile auth guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/bin/fm-claude-account-profile-lib.sh"

VERSION=unknown

fail() {
  printf 'not ok - claude %s: %s\n' "$VERSION" "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

command -v claude >/dev/null 2>&1 || fail "claude is not installed, so this guard checked nothing"
command -v jq >/dev/null 2>&1 || fail "jq is not installed, so the predicate cannot be evaluated"
VERSION=$(claude --version 2>/dev/null | head -n 1)
[ -n "$VERSION" ] || fail "could not read the installed CLI version"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-account-profile-live.XXXXXX")
cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

# Precondition, not a result. The default store's path is deliberately not
# guessed: on claude 2.1.233 an explicit CLAUDE_CONFIG_DIR=$HOME/.claude reports
# no session while an unset variable reports the real one, so only the CLI can
# say whether this host has an account at all. Without one, the isolation
# assertion below would refuse for the wrong reason and prove nothing.
ambient_status=$(env -u CLAUDE_CONFIG_DIR claude auth status --json 2>/dev/null </dev/null) \
  || fail "no native Claude session on this host, so the isolation check would prove nothing; run claude auth login first"
printf '%s\n' "$ambient_status" \
  | jq -e '.loggedIn == true and .authMethod == "claude.ai" and .apiProvider == "firstParty"' >/dev/null \
  || fail "the default store holds no paid native session, so the isolation check would prove nothing; run claude auth login first"
pass "installed claude reports a paid native session for the default store"

ISOLATED="$LAB/empty-profile"
mkdir -p "$ISOLATED"
chmod 0700 "$ISOLATED"
if fm_claude_account_profile_preflight live-isolated "$ISOLATED"; then
  fail "auth status accepted a credential-free directory while the default store is authenticated, so CLAUDE_CONFIG_DIR is not honored and every profile would bind the same account"
fi
pass "installed claude honors CLAUDE_CONFIG_DIR: a credential-free profile directory is refused"

case "$FM_CLAUDE_ACCOUNT_PROFILE_ERROR" in
  '') fail "the refusal published no diagnostic" ;;
  *"$ISOLATED"*) fail "the refusal diagnostic leaked the profile directory" ;;
esac
pass "the refusal names the profile alias without leaking a configuration directory"

# The positive binding path needs a real second-account profile directory, which
# exists only after the operator completes that native login. It is reported
# either way rather than skipped silently.
if [ -n "${FM_CLAUDE_ACCOUNT_PROFILE_LIVE_DIR:-}" ]; then
  LIVE_DIR=$(CDPATH='' cd -- "$FM_CLAUDE_ACCOUNT_PROFILE_LIVE_DIR" && pwd -P) \
    || fail "FM_CLAUDE_ACCOUNT_PROFILE_LIVE_DIR is not a resolvable directory"
  fm_claude_account_profile_preflight live-profile "$LIVE_DIR" \
    || fail "the mapped profile directory is not a paid native session ($FM_CLAUDE_ACCOUNT_PROFILE_ERROR)"
  pass "the mapped profile directory holds its own paid native session"
else
  printf '# not checked: set FM_CLAUDE_ACCOUNT_PROFILE_LIVE_DIR to an authenticated profile directory to cover the positive binding path\n'
fi

BOUND_START=$(date +%s)
FM_CLAUDE_ACCOUNT_PROFILE_TIMEOUT=1 fm_claude_account_profile_preflight live-bound "$ISOLATED" && \
  fail "the bounded preflight accepted a credential-free directory"
BOUND_ELAPSED=$(( $(date +%s) - BOUND_START ))
[ "$BOUND_ELAPSED" -le 10 ] \
  || fail "the native auth command ran ${BOUND_ELAPSED}s under a 1s bound, so the hard bound is not enforced"
pass "the native auth command is hard-bounded on this host"

printf '# claude account-profile live auth guard passed against claude %s\n' "$VERSION"
