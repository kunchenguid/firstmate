#!/usr/bin/env bash
# tests/fm-composer-codex-idle-live-e2e.test.sh - the live codex idle-screen
# guard (live-harness-optin family; task fm-composer-codex-idle-furniture).
#
# codex-cli 0.154.0 draws animation furniture around its idle composer: a
# braille "starfield" on the rows around the bare `›` prompt (and behind its
# dim `Ask Codex to do anything` placeholder), with a bright model/path/title
# status footer beneath it. The shared classifier (bin/fm-composer-lib.sh)
# must read those rows as furniture, not typed input, or every steering
# doorbell into an idle codex pane is deferred as "pending text". Those rows
# are vendor-rendered, so per .agents/skills/firstmate-coding-guidelines the
# byte fixture in tests/fm-composer-lib.test.sh is not enough on its own: this
# guard launches the INSTALLED codex idle in an isolated Herdr session, captures
# its screen with styling preserved, and requires the classifier to reach
# `empty` through BOTH capability profiles that read it in production - the
# Herdr adapter read (fm_backend_herdr_composer_state) and the cursorless styled
# read that Herdr uses, which is the profile that failed live. It
# fails naming codex and `codex --version`.
#
# Reading an idle screen submits no prompt, so no model tokens are spent and
# the gate is default-on wherever codex and Herdr are installed (fm_live_gate):
# FM_COMPOSER_CODEX_IDLE_LIVE=1 forces it (an absent codex then fails instead
# of skipping) and =0 disables it. A run that verified nothing fails rather
# than passing vacuously. Whether the starfield was actually drawn during the
# read is reported as a note, because codex need not animate it under every
# model or mode; the `empty` verdict is required either way.
# Refresh docs/verification/runtime-backends.md ("Composer classification
# matrix") from this guard's output after any codex upgrade.
#
# Folder trust: codex is launched with the repo root as cwd, which the
# operator's machine has normally already trusted; a trust dialog is a real
# unreadable-composer state and correctly fails the check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_COMPOSER_CODEX_IDLE_LIVE codex herdr jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CHECKED=0
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }
# Every terminal operation, including adapter subprocesses, uses the lab owner.
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
CLEAN_PATH=$PATH
SESSION=$("$HELPER" name "${FM_HERDR_LAB_TASK:-composer-live}") || exit 1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-composer-live.XXXXXX")
cleanup() {
  PATH="$CLEAN_PATH" "$HELPER" teardown "$SESSION" || exit 1
  rm -rf "$LAB"
}
trap cleanup EXIT
"$HELPER" provision "$SESSION" || fail 'lab provision failed'
herdr_test_guard_cli "$SESSION" "$LAB/shim" "$HELPER" || fail 'lab guard failed'
export PATH="$LAB/shim:$PATH" HERDR_SESSION="$SESSION"
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail 'Herdr adapter unavailable'
container_raw=$(fm_backend_herdr_container_ensure "$ROOT") || fail 'container failed'
container=${container_raw%%$'\t'*}
new_pane() {
  local label=$1 ids cmd
  shift
  ids=$(fm_backend_herdr_create_task "$container" "$label" "$ROOT") || fail 'pane failed'
  read -r _ PANE <<< "$ids"
  printf -v cmd '%q ' "$@"
  fm_backend_herdr_send_text_line "$SESSION:$PANE" "exec $cmd" || fail 'launch failed'
}
VERSION=$(codex --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || VERSION=version-unknown
new_pane codex-idle codex
# The cursorless styled read exactly as bin/backends/herdr.sh describes its
# ANSI capture: a bounded styled tail plus the shared capability facts, with
# the lazy identity pass answered `probe-absent` because no identity probe is
# needed for a bare composer.
CAPS_CURSORLESS=$(printf 'styled=1\ncursor=0\nidentity=1\nrows=%s' "$FM_COMPOSER_CAPTURE_LINES")
classify_cursorless() {  # <styled-screen>
  local verdict
  verdict=$(fm_composer_classify_screen "$CAPS_CURSORLESS" "$1")
  if [ "$verdict" = need-identity ]; then
    verdict=$(fm_composer_classify_screen "$CAPS_CURSORLESS" "$1" '' probe-absent)
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  printf '%s' "$verdict"
}

budget=${FM_COMPOSER_CODEX_IDLE_LIVE_POLLS:-45}
i=0
herdr_verdict=''
cursorless_verdict=''
styled=''
dismissed=0
while [ "$i" -lt "$budget" ]; do
  herdr_verdict=$(fm_backend_herdr_composer_state "$SESSION:$PANE")
  styled=$(fm_backend_herdr_capture_ansi "$SESSION:$PANE" "$FM_COMPOSER_CAPTURE_LINES" 2>/dev/null | tail -n "$FM_COMPOSER_CAPTURE_LINES")
  cursorless_verdict=$(classify_cursorless "$styled")
  if [ "$herdr_verdict" = empty ] && [ "$cursorless_verdict" = empty ]; then
    break
  fi
  i=$((i + 1))
  # A fresh codex may park on a vendor update-available modal (observed live
  # on codex 0.146.0), which the strict classifier correctly refuses to call a
  # composer. Dismiss it once, mid-budget, with a single Escape - the one key
  # that submits nothing. Never Enter: on codex's dialog Enter would RUN the
  # upgrade. A trust prompt also accepts Escape, but there it exits codex and
  # erases the actionable failure surface, so it is left alone.
  if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
    if ! fm_backend_herdr_capture "$SESSION:$PANE" "$FM_COMPOSER_CAPTURE_LINES" 2>/dev/null | grep -qi 'trust'; then
      "$HELPER" run "$SESSION" pane send-keys "$PANE" Escape 2>/dev/null || true
    fi
    dismissed=1
  fi
  sleep 1
done

# Report what codex actually drew, so a refreshed verification record can say
# whether the starfield was exercised rather than assuming it.
plain=$(printf '%s\n' "$styled" | fm_composer_strip_ansi)
starfield=no
while IFS= read -r row; do
  if _fm_composer_row_is_braille_furniture "$row"; then starfield=yes; break; fi
done <<PLAIN
$plain
PLAIN
placeholder=no
case "$plain" in *'Ask Codex to do anything'*) placeholder=yes ;; esac
note "codex ($VERSION): starfield furniture observed=$starfield placeholder observed=$placeholder"

if [ "$herdr_verdict" = empty ] && [ "$cursorless_verdict" = empty ]; then
  CHECKED=$((CHECKED + 1))
  pass "codex ($VERSION): real idle screen classifies empty on the Herdr adapter read and the cursorless styled read"
else
  printf '# codex pane tail at failure:\n' >&2
  printf '%s\n' "$plain" | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
  fail "codex ($VERSION): idle screen never classified empty (Herdr read: ${herdr_verdict:-unreadable}, cursorless styled read: ${cursorless_verdict:-unreadable})"
fi

[ "$CHECKED" -gt 0 ] || fail "live codex idle-screen guard verified nothing; refusing a vacuous pass"
pass "live codex idle-screen guard verified $CHECKED live surface(s)"
