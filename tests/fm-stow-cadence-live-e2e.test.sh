#!/usr/bin/env bash
set -u

if [ "${FM_STOW_CADENCE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_STOW_CADENCE_LIVE_E2E=1 with the four live target configurations"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$ROOT/bin/fm-stow-cadence-lab.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

checked=0
for spec in CLAUDE:claude CODEX:codex PI:pi PI_SIGNED:pi-signed; do
  prefix=${spec%%:*}
  harness=${spec#*:}
  sender_name="FM_STOW_LIVE_${prefix}_SENDER_HOME"
  home_name="FM_STOW_LIVE_${prefix}_TARGET_HOME"
  endpoint_name="FM_STOW_LIVE_${prefix}_TARGET"
  backend_name="FM_STOW_LIVE_${prefix}_BACKEND"
  sender=${!sender_name:-}
  target_home=${!home_name:-}
  target=${!endpoint_name:-}
  backend=${!backend_name:-tmux}
  [ -n "$sender" ] && [ -n "$target_home" ] && [ -n "$target" ] \
    || fail "$harness live sender, target home, and endpoint are required"

  output=$(FM_HOME="$sender" "$LAB" run --target-home "$target_home" \
    --target "$target" --backend "$backend" --harness "$harness" \
    --wait-seconds 60 2>&1) || fail "$harness live cadence failed: $output"
  case "$output" in
    success:*) ;;
    *) fail "$harness did not produce a fresh due-to-started success: $output" ;;
  esac
  pass "$(date -u +%Y-%m-%d) $harness real sender produced a correlated stow receipt"
  checked=$((checked + 1))
done

[ "$checked" -eq 4 ] || fail "all four supported harness adapters must be checked"
