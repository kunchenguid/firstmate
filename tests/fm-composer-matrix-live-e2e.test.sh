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
#   - claude's CURSORLESS verdict (the herdr/zellij/cmux/orca profile, which
#     has no cursor row to anchor on) against the real tmux `capture-pane -e`
#     tail, idle and with typed text, both plain and with the ultracode
#     session mode whose label claude writes into the composer's top rule
#     (task afk-inject-fullscreen-wedge; the cursor-anchored check above
#     cannot see that failure).
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${FM_COMPOSER_MATRIX_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_COMPOSER_MATRIX_LIVE=1 to run the live composer-matrix guard"
  exit 0
fi

command -v tmux >/dev/null 2>&1 || { echo "not ok - FM_COMPOSER_MATRIX_LIVE=1 but tmux is not installed" >&2; exit 1; }

SOCKET="fm-cmx-live-$$"
SESSION="cmxlive"
ZELLIJ_SESSION="fm-cmx-live-zj-$$"
CHECKED=0
FAILED=0

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  [ -z "${ZJ_BG:-}" ] || kill "$ZJ_BG" 2>/dev/null || true
  if command -v zellij >/dev/null 2>&1; then
    zellij delete-session --force "$ZELLIJ_SESSION" >/dev/null 2>&1 || true
  fi
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
  fi
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

# --- 1. Every installed verified harness must reach a proven-empty composer --
for h in claude codex opencode pi grok kimi muse; do
  if command -v "$h" >/dev/null 2>&1; then
    check_harness_idle_empty "$h" "$h"
  else
    note "harness absent, not verified here: $h"
  fi
done

# --- 1b. claude: the cursorless verdict, plain and mode-labelled -------------
# The cursor-anchored read above never asks whether the bare `❯` row's rules
# pair up, so it passed all along while every cursorless backend deferred for
# a night: claude's ultracode session mode writes its label into the composer's
# top rule (`──── ultracode ─`), the labelled rule was not a rule, and the
# solid rule below the glyph read as a lone separator. Classify the real tmux
# tail with the cursorless herdr capability profile instead, idle and with a
# never-submitted probe typed, resolving `need-identity` exactly as an adapter
# without a live identity would. The labelled rule is the one shape this step
# exists to prove, so a launch whose top rule carries no label (the mode is
# unavailable on this machine, or claude moved the label) fails naming the
# harness and version instead of passing over it: the plain check alone must
# never let the guard exit green with the titled rule unread. Run the guard
# where the mode is available before trusting refreshed evidence.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
CAPS_CURSORLESS=$'styled=1\ncursor=0\nidentity=1\nrows=20'

# tmux prints every visible row of the grid, trailing blank rows included,
# while `herdr pane read --source recent` ends at the last written row. The
# classic renderer draws its composer near the top of a fresh 50-row grid, so
# a raw 20-row tail of the grid is blank there and reads unknown, whereas the
# fullscreen renderer parks its composer at the bottom and the two tails
# agree. Drop the rows that are blank after ANSI stripping and whitespace
# trimming first, then keep the last 20 exactly as the herdr adapter bounds
# its read, so either renderer is read the same way without forcing a tui.
content_tail() {  # <window> [capture-pane flags...] -> the last 20 rows ending at the last written row
  local win=$1 captured plain row n=0 last=0
  shift
  captured=$(tmux -L "$SOCKET" capture-pane -p "$@" -t "$SESSION:$win" 2>/dev/null) || return 1
  plain=$(printf '%s\n' "$captured" | fm_composer_strip_ansi)
  while IFS= read -r row; do
    n=$((n + 1))
    fm_composer_normalize_trim_var row
    [ -z "$row" ] || last=$n
  done <<EOF
$plain
EOF
  printf '%s\n' "$captured" | head -n "$last" | tail -n 20
}

cursorless_verdict() {  # <window> -> verdict, resolving need-identity like an adapter without identity
  local screen verdict
  screen=$(content_tail "$1" -e)
  verdict=$(fm_composer_classify_screen "$CAPS_CURSORLESS" "$screen")
  [ "$verdict" != need-identity ] \
    || verdict=$(fm_composer_classify_screen "$CAPS_CURSORLESS" "$screen" '' probe-absent)
  printf '%s' "$verdict"
}

check_claude_cursorless() {  # <label> <want-mode-label:0|1> <launch-cmd...>
  local label=$1 want_label=$2 win="cl-$1" verdict='' i=0 budget=${FM_COMPOSER_MATRIX_LIVE_POLLS:-45} version plain
  shift 2
  version=$(harness_version claude)
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$ROOT" -- "$@" \
    || fail "claude $label ($version): could not launch in the isolated tmux server"
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_tmux_composer_state "$SESSION:$win")
    [ "$verdict" = empty ] && break
    i=$((i + 1))
    sleep 1
  done
  if [ "$verdict" != empty ]; then
    FAILED=1
    printf 'not ok - claude %s (%s): idle composer never reached empty under the cursor-anchored read (last verdict: %s)\n' \
      "$label" "$version" "${verdict:-unreadable}" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  plain=$(content_tail "$win")
  if [ "$want_label" = 1 ] && ! printf '%s\n' "$plain" | grep -q '─.*ultracode'; then
    FAILED=1
    printf 'not ok - claude %s (%s): the ultracode label was not drawn in the composer rule (mode unavailable on this machine, or the shape changed); cursorless mode-label case NOT verified\n' \
      "$label" "$version" >&2
    printf '# claude %s pane tail at failure:\n' "$label" >&2
    printf '%s\n' "$plain" | grep '[^[:space:]]' | tail -6 | sed 's/^/#   /' >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  verdict=$(cursorless_verdict "$win")
  if [ "$verdict" != empty ]; then
    FAILED=1
    printf 'not ok - claude %s (%s): idle composer classified %s under the cursorless profile, expected empty\n' \
      "$label" "$version" "${verdict:-unreadable}" >&2
    printf '# claude %s pane tail at failure:\n' "$label" >&2
    printf '%s\n' "$plain" | grep '[^[:space:]]' | tail -6 | sed 's/^/#   /' >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  tmux -L "$SOCKET" send-keys -t "$SESSION:$win" -l 'audit probe never submitted' 2>/dev/null || true
  sleep 1
  verdict=$(cursorless_verdict "$win")
  if [ "$verdict" != pending ]; then
    FAILED=1
    printf 'not ok - claude %s (%s): typed text classified %s under the cursorless profile, expected pending\n' \
      "$label" "$version" "${verdict:-unreadable}" >&2
  else
    CHECKED=$((CHECKED + 1))
    pass "claude $label ($version): cursorless verdict reads the real composer empty when idle and pending when typed"
  fi
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

if command -v claude >/dev/null 2>&1; then
  check_claude_cursorless plain 0 claude
  check_claude_cursorless ultracode 1 claude --settings '{"ultracode":true}'
else
  note "harness absent, not verified here: claude (cursorless verdict not exercised)"
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

# --- refuse a vacuous pass ---------------------------------------------------
[ "$FAILED" -eq 0 ] || fail "live composer-matrix guard observed failures above"
[ "$CHECKED" -gt 0 ] || fail "live composer-matrix guard verified nothing (no harness installed?); refusing a vacuous pass"
pass "live composer-matrix guard verified $CHECKED live surface(s)"
