#!/usr/bin/env bash
# tests/fm-composer-matrix-live-e2e.test.sh - the live composer-matrix guard
# (live-harness-optin family; task fm-composer-thin-adapter-refactor-r1).
#
# The shared composer classifier's shape catalogue (bin/fm-composer-lib.sh) is
# built entirely from vendor-rendered signals, so per
# .agents/skills/firstmate-coding-guidelines it must be proven against the
# REAL harnesses: a stub can only confirm the assumption already written into
# the stub. This guard launches every INSTALLED verified harness idle in an
# isolated tmux server and requires the real fm_tmux_composer_state to reach
# `empty`, failing loudly with the harness name and version. It also proves:
#   - the strict blank-row posture live: a plain shell pane with a blank
#     cursor row must classify unknown and defer injection;
#   - the zellij false-positive regression live (when zellij is installed): a
#     pane whose content changes for reasons unrelated to submission must NOT
#     report a delivered send, and a real claude-in-zellij `dump-screen
#     --ansi` capture must classify empty through the zellij thin adapter;
#   - the CURSORLESS read of the same real idle pane, which is the read every
#     non-tmux backend performs and the one a vendor's own footer rows can
#     break: a harness that renders a statusLine or mode hint below its
#     composer must never make an idle composer read `pending`, because that
#     verdict is what skips a steer's doorbell fleet-wide;
#   - the Pi model selector live (when pi is installed): /model opened on a
#     throwaway provider is named from real rendered rows, and the typed-send
#     path refuses it without typing the text or pressing Enter.
#
# Run explicitly with FM_COMPOSER_MATRIX_LIVE=1. No prompt is ever submitted
# to any harness, so no model tokens are spent. An absent harness is reported
# explicitly and skipped; a run that verified nothing fails rather than
# passing vacuously. Refresh docs/verification/runtime-backends.md ("Composer
# classification matrix") from this guard's output after any harness upgrade.
#
# Folder trust: harnesses are launched with the repo root as cwd, which the
# operator's machine has normally already trusted; a trust dialog is a real
# unreadable-composer state and correctly fails that harness's check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_COMPOSER_MATRIX_LIVE tmux

SOCKET="fm-cmx-live-$$"
SESSION="cmxlive"
ZELLIJ_SESSION="fm-cmx-live-zj-$$"
CHECKED=0
FAILED=0
# The throwaway Pi agent directory, tracked as soon as it is created so a
# failed run removes it too: `fail` exits through cleanup, which runs before
# this section's own removals.
PI_DIR=

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  [ -z "${ZJ_BG:-}" ] || kill "$ZJ_BG" 2>/dev/null || true
  if command -v zellij >/dev/null 2>&1; then
    zellij delete-session --force "$ZELLIJ_SESSION" >/dev/null 2>&1 || true
  fi
  [ -z "${PI_DIR:-}" ] || fm_test_remove_tree "$PI_DIR"
  PI_DIR=
}
trap cleanup EXIT

# The library under test, driven against the private socket through a PATH
# shim so its bare `tmux` calls stay isolated from any live fleet.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-cmx-live.XXXXXX")
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -c "$ROOT"

harness_version() {  # <binary>
  "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

check_harness_idle_empty() {  # <name> <launch-cmd...>
  local name=$1 win="hx-$1" verdict='' i=0 budget=${FM_COMPOSER_MATRIX_LIVE_POLLS:-45} version dismissed=0 startup_screen
  shift
  version=$(harness_version "$1")
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$ROOT" -- "$@" \
    || fail "$name ($version): could not launch in the isolated tmux server"
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_tmux_composer_state "$SESSION:$win")
    [ "$verdict" = empty ] && break
    i=$((i + 1))
    # A fresh harness may park on a vendor update-available modal (observed
    # live: codex 0.146.0 and opencode 1.14.46), which the strict classifier
    # correctly refuses to call a composer. Dismiss it once, mid-budget, with
    # a single Escape - the one key that submits nothing anywhere and is how
    # the audit declined the same prompts. Never Enter: on codex's dialog
    # Enter would RUN the upgrade.
    if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
      # Trust prompts also accept Escape, but there it exits the harness and
      # erases the actionable failure surface. Preserve those prompts; only
      # dismiss a non-trust startup modal.
      startup_screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null || true)
      if ! printf '%s\n' "$startup_screen" | grep -qi 'trust'; then
        tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Escape 2>/dev/null || true
      fi
      dismissed=1
    fi
    sleep 1
  done
  if [ "$verdict" != empty ]; then
    printf '# %s pane tail at failure:\n' "$name" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null \
      | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
    FAILED=1
    printf 'not ok - %s (%s): idle composer never classified empty (last verdict: %s)\n' \
      "$name" "$version" "${verdict:-unreadable}" >&2
  else
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): real idle composer classifies empty"
    check_harness_idle_cursorless "$name" "$version" "$SESSION:$win"
  fi
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

# The same proven-idle pane read the way every cursorless backend reads it
# (herdr, zellij, cmux, orca): no #{cursor_y} to anchor the shape, so the
# bottom-most shape on the screen wins. A vendor footer drawn BELOW the
# composer - a statusLine, a permission-mode hint - lives exactly where that
# rule looks, and a footer row opening with an agent prompt glyph used to be
# selected as a composer holding typed text, skipping every doorbell to that
# worker (live regression, claude 2.x on herdr 0.8.0, 2026-09-20).
# `pending` is the one verdict that blocks a steer, so that is what this
# refuses; `unknown` stays legitimate for a shape only identity can prove,
# unless CMX_REQUIRE_CURSORLESS_EMPTY=1 names a shape that must prove itself.
check_harness_idle_cursorless() {  # <name> <version> <target>
  local name=$1 version=$2 target=$3 pane caps verdict identity
  pane=$(fm_tmux_composer_capture "$target") || {
    FAILED=1
    printf 'not ok - %s (%s): cursorless re-read could not capture the proven-idle pane\n' \
      "$name" "$version" >&2
    return 0
  }
  caps=$(printf 'styled=1\ncursor=0\nidentity=1\nrows=0')
  verdict=$(fm_composer_classify_screen "$caps" "$pane")
  if [ "$verdict" = need-identity ]; then
    if ! identity=$(fm_tmux_composer_identity "$target") || [ -z "$identity" ]; then
      identity='probe-absent'
    fi
    verdict=$(fm_composer_classify_screen "$caps" "$pane" '' "$identity")
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  if [ "$verdict" = pending ]; then
    printf '# %s cursorless pane tail:\n' "$name" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$target" 2>/dev/null \
      | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
    FAILED=1
    printf 'not ok - %s (%s): a proven-idle composer read cursorless as pending; every steer to this harness would skip its doorbell\n' \
      "$name" "$version" >&2
  elif [ "${CMX_REQUIRE_CURSORLESS_EMPTY:-0}" = 1 ] && [ "$verdict" != empty ]; then
    printf '# %s cursorless pane tail:\n' "$name" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$target" 2>/dev/null \
      | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
    FAILED=1
    printf 'not ok - %s (%s): a proven-idle composer read cursorless as %s, expected empty; away-mode delivery to this pane would defer forever\n' \
      "$name" "$version" "${verdict:-unreadable}" >&2
  else
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): the same idle pane read cursorless is not pending (verdict: $verdict)"
  fi
}

# --- 1. Every installed verified harness must reach a proven-empty composer --
for h in claude codex opencode pi grok kimi muse; do
  if command -v "$h" >/dev/null 2>&1; then
    check_harness_idle_empty "$h" "$h"
  else
    note "harness absent, not verified here: $h"
  fi
done
# A named claude session (`claude -n <name>`) right-aligns that name in the
# rule above its composer; the cursorless read must still prove it empty, or
# away-mode delivery to a named primary on a cursorless backend defers forever.
if command -v claude >/dev/null 2>&1; then
  CMX_REQUIRE_CURSORLESS_EMPTY=1 check_harness_idle_empty claude-named claude -n fm-cmx-named
else
  note "harness absent, not verified here: claude-named"
fi

# --- 2. The strict blank-row posture, live ----------------------------------
# A plain shell pane parked on a blank line between two rules (the audit's
# sleep-pane counterexample): the permissive rule read this empty; strict must
# defer.
tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n strictblank -c "$ROOT" \
  -- bash -c 'printf "────────────────────────\n\n"; printf "\033[A"; exec sleep 300'
sleep 1
verdict=$(fm_tmux_composer_state "$SESSION:strictblank")
if [ "$verdict" = unknown ]; then
  if fm_pane_input_pending "$SESSION:strictblank"; then
    CHECKED=$((CHECKED + 1))
    pass "strict posture live: a blank shell row classifies unknown and injection defers"
  else
    FAILED=1
    printf 'not ok - strict posture live: pane_input_pending did not defer on an unknown verdict\n' >&2
  fi
else
  FAILED=1
  printf 'not ok - strict posture live: blank shell row classified %s, expected unknown\n' "${verdict:-unreadable}" >&2
fi
tmux -L "$SOCKET" kill-window -t "$SESSION:strictblank" 2>/dev/null || true

# --- 3. zellij: real classifier + the false-positive regression -------------
if command -v zellij >/dev/null 2>&1; then
  zj_version=$(zellij --version 2>/dev/null | head -1)
  [ -n "$zj_version" ] || zj_version='version-unknown'
  export FM_ROOT_OVERRIDE="$ROOT"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source zellij 2>/dev/null \
    || fail "zellij ($zj_version): adapter source failed"

  zellij delete-session --force "$ZELLIJ_SESSION" >/dev/null 2>&1 || true
  zellij --session "$ZELLIJ_SESSION" options --default-shell bash >/dev/null 2>&1 &
  ZJ_BG=$!
  i=0
  while [ "$i" -lt 10 ] && ! fm_backend_zellij_session_exists "$ZELLIJ_SESSION"; do
    i=$((i + 1))
    sleep 0.5
  done
  fm_backend_zellij_session_exists "$ZELLIJ_SESSION" \
    || fail "zellij ($zj_version): probe session setup failed"
  panes=$(fm_backend_zellij_cli "$ZELLIJ_SESSION" action list-panes --json 2>/dev/null) \
    || fail "zellij ($zj_version): pane discovery command failed"
  pane_id=$(printf '%s' "$panes" | jq -r '.[]? | select(.is_plugin == false) | .id' 2>/dev/null | head -1)
  case "$pane_id" in
    ''|*[!0-9]*) fail "zellij ($zj_version): pane discovery returned no terminal pane" ;;
  esac
  target="$ZELLIJ_SESSION:$pane_id"

  fm_backend_zellij_send_literal "$target" 'while sleep 1; do date; done' \
    || fail "zellij ($zj_version): clock probe setup write failed"
  fm_backend_zellij_send_key "$target" Enter \
    || fail "zellij ($zj_version): clock probe setup submit failed"
  sleep 2
  probe='# audit-probe-never-submitted'
  fm_backend_zellij_send_literal "$target" "$probe" \
    || fail "zellij ($zj_version): false-positive probe write failed"
  sleep 0.5
  probe_capture=$(fm_backend_zellij_capture "$target" 40 2>/dev/null) \
    || fail "zellij ($zj_version): false-positive probe capture failed"
  case "$probe_capture" in
    *"$probe"*) ;;
    *) fail "zellij ($zj_version): false-positive probe text was not visible after typing" ;;
  esac
  verdict=$(fm_composer_submit_retry_core fm_backend_zellij_send_key fm_backend_zellij_composer_state \
    "$target" 2 0.5 2>/dev/null)
  case "$verdict" in
    pending|unknown)
      CHECKED=$((CHECKED + 1))
      pass "zellij ($zj_version): unrelated pane change never confirms delivery (verdict: $verdict)"
      ;;
    send-failed)
      FAILED=1
      printf 'not ok - zellij (%s): false-positive probe text was not typed (send-failed)\n' "$zj_version" >&2
      ;;
    *)
      FAILED=1
      printf 'not ok - zellij (%s): false-positive probe returned unexpected verdict %s (expected pending or unknown)\n' \
        "$zj_version" "${verdict:-none}" >&2
      ;;
  esac
  kill "$ZJ_BG" 2>/dev/null || true
  ZJ_BG=
  zellij delete-session --force "$ZELLIJ_SESSION" >/dev/null 2>&1 || true
else
  note "harness absent, not verified here: zellij (false-positive regression not exercised)"
fi

# --- 4. The Pi model selector, live -----------------------------------------
# Whether a rendered screen is the /model selector is a vendor-surface fact, so
# the guard that refuses to submit it must be proven against the installed pi
# and not only against a recorded frame. It is: the frame is what a vendor
# release can change, and reading it wrong is silent - the guard simply never
# fires (the live regression this section was written from).
# The launch uses a throwaway agent directory whose models.json declares a
# provider on an unreachable port (provider id `localfake`), so /model lists
# rows on a host with no authorised login, no provider is called, and nothing
# is submitted: this section spends no model tokens and touches no operator
# credentials or settings.
check_pi_model_selector() {  # <name> <version>
  local name=$1 version=$2 dir win target screen dialog probe err out rc
  local i=0 polled=0 budget=${FM_COMPOSER_MATRIX_LIVE_POLLS:-45}
  probe='live-guard probe: this text must not reach the selector'
  win='pi-model'
  target="$SESSION:$win"
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-cmx-pi.XXXXXX")
  PI_DIR=$dir
  mkdir -p "$dir/agent"
  cat > "$dir/agent/models.json" <<'JSON'
{
  "providers": {
    "localfake": {
      "name": "Local Fake",
      "baseUrl": "http://127.0.0.1:9/v1",
      "api": "openai-completions",
      "apiKey": "localfake",
      "models": [
        { "id": "alpha-model-one", "contextWindow": 128000 },
        { "id": "beta-model-two", "contextWindow": 128000 },
        { "id": "gamma-model-three", "contextWindow": 128000 }
      ]
    }
  }
}
JSON
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$dir" -- \
    env PI_CODING_AGENT_DIR="$dir/agent" "$name" \
    || fail "$name ($version): could not launch with the throwaway provider"
  # Wait for a proven-idle composer before typing: a slash command sent into a
  # half-drawn TUI would prove nothing about the selector.
  while [ "$i" -lt "$budget" ]; do
    [ "$(fm_tmux_composer_state "$target")" = empty ] && break
    i=$((i + 1))
    sleep 1
  done
  [ "$i" -lt "$budget" ] \
    || fail "$name ($version): the throwaway session never reached an idle composer, so the selector was not driven"
  tmux -L "$SOCKET" send-keys -t "$target" -l '/model' 2>/dev/null \
    || fail "$name ($version): could not type /model"
  sleep 1
  tmux -L "$SOCKET" send-keys -t "$target" Enter 2>/dev/null \
    || fail "$name ($version): could not submit /model"
  i=0
  while [ "$i" -lt "$budget" ]; do
    screen=$(fm_tmux_composer_capture "$target" 2>/dev/null) || screen=''
    if dialog=$(fm_composer_blocking_dialog "$screen"); then
      polled=1
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  if [ "$polled" -eq 0 ]; then
    printf '# %s (%s) pane tail at failure:\n' "$name" "$version" >&2
    printf '%s\n' "$screen" | grep '[^[:space:]]' | tail -18 | sed 's/^/#   /' >&2
    tmux -L "$SOCKET" kill-window -t "$target" 2>/dev/null || true
    fm_test_remove_tree "$dir"
    PI_DIR=
    FAILED=1
    printf 'not ok - %s (%s): the /model selector was not named by its rendered rows; a steer to this harness would submit into it\n' \
      "$name" "$version" >&2
    return 0
  fi
  # Move the highlight off the current model, so the `→` cursor and the `✓`
  # current marker sit on different rows the way they do in real use.
  tmux -L "$SOCKET" send-keys -t "$target" Down 2>/dev/null || true
  sleep 1
  # The safety property itself: the real entry point every steer uses must
  # refuse before it types, and must not press Enter either.
  err=$(mktemp "${TMPDIR:-/tmp}/fm-cmx-pi-err.XXXXXX")
  rc=0
  fm_backend_send_text_submit tmux "$target" "$probe" 0 0 0 >/dev/null 2>"$err" || rc=$?
  out=$(fm_tmux_composer_capture "$target" 2>/dev/null || true)
  if [ "$rc" -eq 0 ]; then
    FAILED=1
    printf 'not ok - %s (%s): a typed submit onto the open model selector was accepted\n' \
      "$name" "$version" >&2
  elif ! grep -F 'blocked on a prompt: Pi model selector' "$err" >/dev/null; then
    FAILED=1
    printf 'not ok - %s (%s): the refusal did not name the model selector (got: %s)\n' \
      "$name" "$version" "$(tr '\n' ' ' < "$err")" >&2
  elif printf '%s' "$out" | grep -F "$probe" >/dev/null; then
    FAILED=1
    printf 'not ok - %s (%s): the probe text reached the open model selector\n' \
      "$name" "$version" >&2
  elif ! fm_composer_blocking_dialog "$out" >/dev/null; then
    FAILED=1
    printf 'not ok - %s (%s): the selector was answered or closed by the refused submit\n' \
      "$name" "$version" >&2
  else
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): the /model selector is named from its rendered rows, and a typed submit to it types nothing and sends no Enter"
  fi
  fm_test_remove_tree "$err"
  tmux -L "$SOCKET" send-keys -t "$target" Escape 2>/dev/null || true
  tmux -L "$SOCKET" kill-window -t "$target" 2>/dev/null || true
  fm_test_remove_tree "$dir"
  PI_DIR=
}

if command -v pi >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  check_pi_model_selector pi "$(harness_version pi)"
else
  note "harness absent, not verified here: pi (model-selector dialog guard not exercised)"
fi

# --- refuse a vacuous pass ---------------------------------------------------
[ "$FAILED" -eq 0 ] || fail "live composer-matrix guard observed failures above"
[ "$CHECKED" -gt 0 ] || fail "live composer-matrix guard verified nothing (no harness installed?); refusing a vacuous pass"
pass "live composer-matrix guard verified $CHECKED live surface(s)"
