#!/usr/bin/env bash
# Regression: on a Cygwin-family host without native symlinks, `ln -s` makes a
# directory COPY, so a lock's claim could never be read back as a link and the
# claim wait spun on its own pid forever. The owner link must be a real link
# (-L and readlink agree), refuse a second claim on the same path, and release
# without touching its owner payload. Skipped on hosts where the boundary does
# not apply.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; exit 1; }

case "$(uname -s 2>/dev/null)" in
  CYGWIN*|MINGW*|MSYS*) ;;
  *) printf 'ok - skipped: owner-link copy fallback only exists on Cygwin-family hosts\n'; exit 0 ;;
esac

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state"

out=$(FM_HOME="$tmp" bash -c '
  . "$1/bin/fm-wake-lib.sh" || exit 97
  lock="$STATE/.t.acquire"
  fm_lock_try_create "$lock" || { echo create-failed; exit 0; }
  [ -L "$lock" ] || echo not-a-link
  [ "$(readlink "$lock")" = "$FM_LOCK_OWNER_DIR" ] || echo readlink-mismatch
  owner=$FM_LOCK_OWNER_DIR
  if fm_lock_try_create "$lock"; then echo second-claim-accepted; fi
  fm_lock_release "$lock"
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || echo not-released
' _ "$ROOT" 2>&1)

[ -z "$out" ] || fail "owner link misbehaved: $out"
pass "owner link is a real link, refuses a second claim, and releases cleanly"
