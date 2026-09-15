#!/usr/bin/env bash
# Opt-in live guard for Codex's vendor-controlled fresh-directory trust menu.
# It submits one small prompt and verifies the prompt is accepted and reaches
# Codex's working row after Firstmate's documented safe choice.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CODEX_TRUST_LIVE_E2E codex tmux

CODEX_BIN=$(command -v codex 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
[ -n "$CODEX_BIN" ] || { printf 'not ok - codex is not installed\n' >&2; exit 1; }
[ -n "$REAL_TMUX" ] || { printf 'not ok - tmux is not installed\n' >&2; exit 1; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-trust-live.XXXXXX") || exit 1
SOCKET="fm-codex-trust-$$"
SESSION=codex-trust
TARGET="$SESSION:codex"

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf -- "$LAB"
}
fail() {
  printf 'not ok - %s\n' "$1" >&2
  cleanup
  exit 1
}
trap cleanup EXIT

mkdir -p "$LAB/project" "$LAB/codex-home" || fail "could not create the isolated Codex lab"
git -C "$LAB/project" init -q || fail "could not initialize the isolated Codex repository"
for config in auth.json config.toml; do
  [ -f "$HOME/.codex/$config" ] || fail "missing ~/.codex/$config for the live guard"
  cp "$HOME/.codex/$config" "$LAB/codex-home/$config" || fail "could not stage Codex $config"
done
PROJECT=$(cd "$LAB/project" && pwd -P) || fail "could not resolve the isolated Codex repository"
CODEX_HOME_DIR=$(cd "$LAB/codex-home" && pwd -P) || fail "could not resolve the isolated Codex home"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n codex -x 140 -y 40 -c "$PROJECT" \
  "CODEX_HOME='$CODEX_HOME_DIR' '$CODEX_BIN' --dangerously-bypass-approvals-and-sandbox 'Reply exactly FM_CODEX_TRUST_OK and do nothing else'" \
  || fail "could not start the isolated Codex pane"

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -120 2>/dev/null || true
}

screen=
for _ in $(seq 1 60); do
  screen=$(capture)
  case "$screen" in
    *"Do you trust the contents of this directory?"*"1. Yes, continue"*"2. No, quit"*) break ;;
  esac
  sleep 0.5
done
case "$screen" in
  *"Do you trust the contents of this directory?"*"1. Yes, continue"*"2. No, quit"*) ;;
  *) fail "Codex did not render the verified fresh-directory trust menu" ;;
esac

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not accept Codex's preselected safe trust choice"

for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in
    *"• Working ("*"esc to interrupt"*)
      printf 'ok - codex %s reached the working row after the verified trust choice\n' "$("$CODEX_BIN" --version)"
      exit 0
      ;;
  esac
  sleep 0.5
done
fail "Codex did not begin processing the supplied prompt after trust acceptance"
