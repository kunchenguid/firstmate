#!/usr/bin/env bash
# tests/fm-backend-rex-composer-live-e2e.test.sh - the live composer guard for
# the Rex adapter (live-harness-optin family), the Rex counterpart of
# tests/fm-composer-matrix-live-e2e.test.sh.
#
# Rex's composer read is harness-dependent twice over: the shared classifier's
# shapes come from vendor-rendered screens, and the adapter anchors them on the
# cursor position Rex reports, falling back to the cursorless bottom-most shape
# when that read is unknown (fm_backend_rex_composer_state). Per
# .agents/skills/firstmate-coding-guidelines that must be proven against the
# REAL harnesses on a REAL Rex server. This guard launches every INSTALLED
# verified harness idle in its own tab of one fm-test- session and requires:
#   - the adapter's verdict to reach `empty`, failing loudly with the harness
#     name and version;
#   - the same proven-idle screen read cursorless never to be `pending`, the
#     one verdict that skips a steer's doorbell.
#
# Run explicitly with FM_REX_COMPOSER_LIVE=1. No prompt is ever submitted, so
# no model tokens are spent, and no key is ever sent to a harness. Each tab
# runs its harness with the vendors' own auto-update switches off where they
# exist, so the guard installs nothing. Isolation is tests/rex-test-safety.sh's
# private server and state-changing call guard.
# An absent harness is reported and skipped; a run that verified nothing fails.
# Harnesses start with the repository root as cwd, which the operator's
# machine has normally trusted; a trust dialog is an unreadable composer and
# correctly fails that harness. Refresh docs/verification/runtime-backends.md
# ("Rex") from this guard's output after any harness or Rex upgrade.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fm_live_gate opt-in FM_REX_COMPOSER_LIVE jq
CHECKED=0
FAILED=0
fail() {
  printf 'not ok - %s\n' "$1" >&2
  rex_test_cleanup
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

# shellcheck source=tests/rex-test-safety.sh
. "$ROOT/tests/rex-test-safety.sh"
trap rex_test_cleanup EXIT
rex_test_prepare || { rc=$?; [ "$rc" = 1 ] && exit 0; exit "$rc"; }

# The vendors' own auto-update switches: Claude Code, OpenCode, and the Muse
# launcher read these from the environment, and Cursor Agent takes a flag.
NO_UPDATE_ENV=(DISABLE_AUTOUPDATER=1 OPENCODE_DISABLE_AUTOUPDATE=1 MUSE_NO_AUTO_UPDATE=1)

PAIR=$(rex_test_new_session composer) || fail "could not create the test's own fm-test- session"
read -r SID _ <<<"$PAIR"

harness_version() {  # <binary>
  env "${NO_UPDATE_ENV[@]}" "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

# check_harness_idle_empty: launch <name> idle in its own tab and poll the
# adapter's verdict until it proves the composer empty.
check_harness_idle_empty() {  # <name> <launch-cmd...>
  local name=$1 version out bid t verdict='' i=0 budget=${FM_REX_COMPOSER_LIVE_POLLS:-45}
  shift
  version=$(harness_version "$1")
  out=$(fm_backend_rex_cli window new -s "$SID" "fm-test-$name" --focus=false --cwd "$ROOT" --json \
    -- env "${NO_UPDATE_ENV[@]}" "$@") || fail "$name ($version): could not open its tab"
  bid=$(printf '%s' "$out" | jq -r '.block_ids[0] // empty')
  fm_backend_rex_id_valid block "$bid" || fail "$name ($version): rex returned no block id"
  fm_backend_rex_cli block call -s "$SID" -b "$bid" resize \
    "{\"columns\":$FM_BACKEND_REX_COLUMNS,\"rows\":$FM_BACKEND_REX_ROWS}" >/dev/null 2>&1 || true
  t=$(fm_backend_rex_target "$SID" "$bid")
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_backend_composer_state rex "$t")
    [ "$verdict" = empty ] && break
    i=$((i + 1))
    sleep 1
  done
  if [ "$verdict" != empty ]; then
    printf '# %s screen tail at failure:\n' "$name" >&2
    fm_backend_capture rex "$t" 40 2>/dev/null | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
    FAILED=1
    printf 'not ok - %s (%s): idle composer never classified empty on rex (last verdict: %s)\n' \
      "$name" "$version" "${verdict:-unreadable}" >&2
  else
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): real idle composer classifies empty on rex"
    check_harness_idle_cursorless "$name" "$version" "$t"
  fi
  fm_backend_rex_cli block close -s "$SID" "$bid" >/dev/null 2>&1 || true
}

# check_harness_idle_cursorless: the same proven-idle screen without the
# cursor, the read the adapter falls back to; it must never be `pending`.
check_harness_idle_cursorless() {  # <name> <version> <target>
  local name=$1 version=$2 t=$3 verdict
  fm_backend_rex_screen_read "$t" || {
    FAILED=1
    printf 'not ok - %s (%s): cursorless re-read could not read the proven-idle screen\n' "$name" "$version" >&2
    return 0
  }
  verdict=$(fm_backend_rex_composer_classify "$t" "$FM_BACKEND_REX_SCREEN" '')
  if [ "$verdict" = pending ]; then
    FAILED=1
    printf 'not ok - %s (%s): a proven-idle composer read cursorless as pending on rex\n' "$name" "$version" >&2
  else
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): the same idle screen read cursorless is not pending (verdict: $verdict)"
  fi
}

for h in claude codex opencode pi grok kimi muse; do
  if command -v "$h" >/dev/null 2>&1; then
    check_harness_idle_empty "$h" "$h"
  else
    note "harness absent, not verified here: $h"
  fi
done

[ "$CHECKED" -gt 0 ] || fail "no installed harness was verified; refusing a vacuous pass"
rex_test_assert_isolated
[ "$FAILED" -eq 0 ] || exit 1
