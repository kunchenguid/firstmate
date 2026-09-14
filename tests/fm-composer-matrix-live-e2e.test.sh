#!/usr/bin/env bash
# tests/fm-composer-matrix-live-e2e.test.sh - the live composer-matrix guard
# (live-harness-optin family; task fm-composer-thin-adapter-refactor-r1).
#
# The shared composer classifier's shape catalogue (bin/fm-composer-lib.sh) is
# built entirely from vendor-rendered signals, so per
# .agents/skills/firstmate-coding-guidelines it must be proven against the
# REAL harnesses: a stub can only confirm the assumption already written into
# the stub. Default mode launches every INSTALLED verified harness idle in an
# isolated tmux server and requires the real fm_tmux_composer_state to reach
# `empty`, failing loudly with the harness name and version. It also proves:
#   - the strict blank-row posture live: a plain shell pane with a blank
#     cursor row must classify unknown and defer injection;
#   - the zellij false-positive regression live (when zellij is installed): a
#     pane whose content changes for reasons unrelated to submission must NOT
#     report a delivered send, and a real claude-in-zellij `dump-screen
#     --ansi` capture must classify empty through the zellij thin adapter.
#
# Run default mode with FM_COMPOSER_MATRIX_LIVE=1. No prompt is submitted, so no
# model tokens are spent. An absent harness is reported and skipped; a run that
# verified nothing fails. Refresh docs/verification/runtime-backends.md
# ("Composer classification matrix") from this guard after a harness upgrade.
#
# Codex-animation-only mode instead reuses prepared idle and draft Herdr panes.
# A nonempty FM_COMPOSER_CODEX_LAB_SESSION selects it; FM_COMPOSER_CODEX_LIVE=1
# opts in, and the verification record owns the complete command and pane inputs.
#
# In default mode, harnesses launch with the repo root as cwd, which the
# operator's machine has normally trusted; a trust dialog is an unreadable
# composer state and correctly fails that harness's check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# A prepared guarded Herdr lab can refresh the Codex animation evidence
# without needing tmux or provisioning any pane in the operator session.
# Supply two real panes: animated idle and animated draft.
if [ -n "${FM_COMPOSER_CODEX_LAB_SESSION:-}" ]; then
  fm_live_gate opt-in FM_COMPOSER_CODEX_LIVE herdr codex
  . "$ROOT/bin/fm-composer-lib.sh"
  codex_composer_region() {
    local region_screen=$1 region_plain region_row
    region_plain=$(printf '%s\n' "$region_screen" | fm_composer_strip_ansi)
    _fm_composer_scan_screen "$region_plain" ''
    region_row=$FM_COMPOSER_SCAN_BARE_ROW
    [ "$region_row" -ge 1 ] || return 1
    printf '%s\n' "$region_screen" | sed -n "$((region_row)), $((region_row + 2))p"
  }
  lab_helper=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
  version=$(codex --version)
  for case_name in IDLE TYPED; do
    pane_var="FM_COMPOSER_CODEX_LAB_$case_name"
    pane=${!pane_var:-}
    [ -n "$pane" ] || fail "$version: missing $pane_var for the prepared lab"
    screen=$("$lab_helper" run "$FM_COMPOSER_CODEX_LAB_SESSION" pane read "$pane" --source visible --format ansi) \
      || fail "$version: cannot capture $case_name"
    [ -n "$screen" ] || fail "$version: empty $case_name capture"
    case "$case_name" in IDLE) expected=empty ;; *) expected=pending ;; esac
    actual=$(fm_composer_classify_screen styled=1 "$screen")
    [ "$actual" = "$expected" ] || fail "$version: $case_name expected $expected, got $actual"
    if [ "$case_name" = IDLE ]; then
      screen_region=$(codex_composer_region "$screen") \
        || fail "$version: cannot isolate the first idle composer region"
      sleep 0.2
      next_screen=$("$lab_helper" run "$FM_COMPOSER_CODEX_LAB_SESSION" pane read "$pane" --source visible --format ansi) \
        || fail "$version: cannot recapture IDLE"
      [ -n "$next_screen" ] || fail "$version: empty IDLE recapture"
      next_actual=$(fm_composer_classify_screen styled=1 "$next_screen")
      [ "$next_actual" = empty ] || fail "$version: IDLE recapture expected empty, got $next_actual"
      next_region=$(codex_composer_region "$next_screen") \
        || fail "$version: cannot isolate the second idle composer region"
      [ "$screen_region" != "$next_region" ] \
        || fail "$version: idle composer animation is absent; live case would be vacuous"
    fi
    pass "$version: real Codex $case_name composer classifies $expected"
  done
  exit 0
fi

fm_live_gate opt-in FM_COMPOSER_MATRIX_LIVE tmux

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
