#!/usr/bin/env bash
# Tests for bin/fm-ground.sh (per-repo ground-truth resolution).
#
# Ground truth is what stops a crewmate re-improvising a repo's architecture, so
# the resolver has to return the file's content verbatim, resolve a repo by name
# or by path to the same key, and stay silent and non-fatal when a repo has none:
# grounding is additive and must never block a dispatch.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GROUND="$ROOT/bin/fm-ground.sh"
TMP_ROOT=

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-ground-tests.XXXXXX")

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data/repos"
printf 'repo-path: /opt/acme\n\n- Storage is Postgres, never SQLite.\n' > "$HOME_DIR/data/repos/acme.md"
printf '%s\n' '- Deploys run on Cloudflare Workers.' > "$HOME_DIR/data/repos/beta.md"

run_ground() { FM_HOME="$HOME_DIR" "$GROUND" "$@"; }

rc_of() {
  set +e
  FM_HOME="$HOME_DIR" "$GROUND" "$@" >/dev/null 2>&1
  local rc=$?
  set -e
  printf '%s' "$rc"
}

# The whole file reaches the caller: a truncated or reformatted ground truth is
# how a worker ends up acting on half the constraints.
out=$(run_ground acme)
case "$out" in
  *"Storage is Postgres, never SQLite."*) pass "ground truth is printed verbatim" ;;
  *) fail "ground truth body was not printed: $out" ;;
esac

# A path and a bare name must resolve to the same key, so orchestrating a repo by
# its checkout path never silently loses its ground truth.
out=$(run_ground /some/where/acme)
case "$out" in
  *"Storage is Postgres, never SQLite."*) pass "a repo path resolves to the same key as its name" ;;
  *) fail "path form did not resolve to the same ground truth: $out" ;;
esac
out=$(run_ground /some/where/acme.git/)
case "$out" in
  *"Storage is Postgres, never SQLite."*) pass "a trailing slash and .git suffix still resolve" ;;
  *) fail "a .git/trailing-slash path did not resolve: $out" ;;
esac

# repo-path: is what makes a repo outside projects/ first-class.
out=$(run_ground --path acme)
[ "$out" = "/opt/acme" ] || fail "--path did not return the declared repo-path: $out"
pass "--path returns the declared external repo path"

# A repo with ground truth but no repo-path: is an ordinary projects/ clone.
[ "$(rc_of --path beta)" = "0" ] || fail "--path on a file without repo-path should still exit 0"
[ -z "$(run_ground --path beta)" ] || fail "--path printed a path for a file that declares none"
pass "--path is empty for a repo that declares no external path"

out=$(run_ground --list | sort | tr '\n' ' ')
[ "$out" = "acme beta " ] || fail "--list did not enumerate both repos: $out"
pass "--list enumerates every repo with ground truth"

[ "$(rc_of --check acme)" = "0" ] || fail "--check on a present repo did not exit 0"
[ "$(rc_of --check nosuchrepo)" = "1" ] || fail "--check on an absent repo did not exit 1"
pass "--check reports presence through its exit status"

# The absent case must be silent and non-fatal: fm-brief.sh warns and scaffolds
# anyway, so a hard failure here would block dispatch on an ungrounded repo.
[ "$(rc_of nosuchrepo)" = "0" ] || fail "an absent ground truth must exit 0, not fail"
[ -z "$(run_ground nosuchrepo)" ] || fail "an absent ground truth must print nothing"
pass "an absent ground truth is silent and non-fatal"

# A home with no data/repos/ at all is the pre-adoption state, not an error.
EMPTY_HOME="$TMP_ROOT/empty"
mkdir -p "$EMPTY_HOME/data"
if [ "$(FM_HOME="$EMPTY_HOME" "$GROUND" --list >/dev/null 2>&1; echo $?)" = "0" ]; then
  pass "a home with no ground-truth directory lists nothing and exits 0"
else
  fail "a home with no ground-truth directory did not exit 0"
fi

[ "$(rc_of)" = "2" ] || fail "no argument should be a usage error (exit 2)"
pass "no argument is a usage error"
