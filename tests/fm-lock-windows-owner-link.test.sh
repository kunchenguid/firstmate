#!/usr/bin/env bash
# Regression: on a Cygwin-family host without native symlinks, `ln -s` makes a
# directory COPY, so a lock's claim could never be read back as a link and the
# claim wait spun on its own pid forever. The owner link must be a real link
# (-L and readlink agree), refuse a second claim on the same path, and release
# together with its owner directory, and the staged-owner sweep must keep the
# published owner - also when the home is reached through
# the drive spelling of a mount-aliased directory and its name carries cmd
# metacharacters. Skipped on hosts where the boundary does not apply.
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
win=$(cygpath -m "$tmp") || exit 1
drive_spelled="$(cygpath -u "${win%%/*}\\")${win#*/}"

check_home() {  # <label> <home>
  local label=$1 home=$2 out status
  mkdir -p "$home/state" || fail "$label: cannot create state directory"
  out=$(FM_HOME="$home" bash -c '
    . "$1/bin/fm-wake-lib.sh" || exit 97
    lock="$STATE/.t.acquire"
    fm_lock_try_create "$lock" || { echo create-failed; exit 1; }
    owner=$FM_LOCK_OWNER_DIR
    [ -L "$lock" ] || echo not-a-link
    [ "$(readlink "$lock")" = "$owner" ] || echo readlink-mismatch
    [ -d "$owner" ] || echo owner-missing
    if fm_lock_try_create "$lock"; then echo second-claim-accepted; fi
    [ "$(readlink "$lock")" = "$owner" ] || echo first-claim-disturbed
    fm_lock_release "$lock"
    [ ! -e "$lock" ] && [ ! -L "$lock" ] || echo not-released
    FM_LOCK_OWNER_SCOPE=sweep
    fm_lock_try_create "$lock" || { echo scoped-create-failed; exit 1; }
    owner=$FM_LOCK_OWNER_DIR
    staged=$(mktemp -d "$lock.owner.sweep.XXXXXX") || exit 1
    fm_lock_discard_staged_owners "$lock" sweep "$(cat "$owner/pid")"
    [ -f "$owner/pid" ] || echo published-owner-swept
    [ ! -e "$staged" ] || echo staged-owner-kept
    fm_lock_release "$lock"
    [ ! -e "$lock" ] && [ ! -L "$lock" ] || echo scoped-not-released
    [ ! -e "$owner" ] || echo owner-left-behind
    leftovers=$(ls -A "$STATE")
    [ -z "$leftovers" ] || echo "state-not-empty: $leftovers"
    echo done
  ' _ "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "$label: lock shell exited $status: $out"
  [ "$out" = done ] || fail "$label: owner link misbehaved: $out"
  pass "$label: owner link is a real link, refuses a second claim, and releases cleanly"
}

check_home "plain home" "$tmp/plain"
check_home "drive-spelled home with cmd metacharacters" "$drive_spelled/r&d (x) home"
