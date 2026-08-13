#!/usr/bin/env bash
# Opt-in credentialed proof that --on-submit really reaches a model.
#
# The unit suite mocks the router agent, so it can prove the wiring shape but not
# that a live harness answers. This test drives the real
# bin/fm-captain-message-router.sh --on-submit with NO agent override against an
# isolated home, so the owner launches the configured Cursor model itself and
# the verdict must come back with confidence=model.
#
# Set FM_CAPTAIN_ROUTER_MODEL to pin a model this Cursor account exposes
# (the built-in default is cursor-grok-4.6-low).
set -u

if [ "${FM_CAPTAIN_ROUTER_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CAPTAIN_ROUTER_LIVE_E2E=1 to run the live router-model regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v git >/dev/null 2>&1 || fail "git not found"
# shellcheck source=bin/fm-cursor-lib.sh
. "$ROOT/bin/fm-cursor-lib.sh"
fm_cursor_resolve_binary >/dev/null 2>&1 || fail "Cursor Agent CLI not found"

LAB="$ROOT/.captain-router-live-e2e.$$"
HOME_DIR="$LAB/home"
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT

mkdir -p "$HOME_DIR/bin" "$HOME_DIR/state" "$HOME_DIR/config"
git init -q "$HOME_DIR"
git -C "$HOME_DIR" -c user.name=fmtest -c user.email=fmtest@example.invalid \
  commit -q --allow-empty -m init
: >"$HOME_DIR/AGENTS.md"

run() {
  local mode=$1
  shift
  FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-captain-message-router.sh" "$mode" "$@"
}

# Two distinct sessions so the model has a real routing choice to make.
printf 'Do you want me to start the blender glb export pipeline fix now?' |
  run --on-settle --session-id sess-blender >/dev/null
printf 'Shall I rewrite the captain-message router so the model always decides?' |
  run --on-settle --session-id sess-router >/dev/null

HISTORY="$LAB/history.txt"
cat >"$HISTORY" <<'EOF'
user: the router keeps calling my ordinary replies a new topic
assistant: right - the deterministic layer only matched literal words. Shall I rewrite the captain-message router so the model always decides?
EOF

# An ordinary in-conversation reply that shares no literal tokens with the
# current anchors. The old deterministic layer called this new/det.
MESSAGE='I thought it was supposed to be classifying my messages to you.'

OUT=$(printf '%s' "$MESSAGE" |
  run --on-submit --session-id sess-router --chat-history-file "$HISTORY") ||
  fail "live submit exited non-zero"

printf 'live verdict line: %s\n' "$OUT"
printf 'failures.log:\n'
cat "$HOME_DIR/state/captain-router/failures.log" 2>/dev/null || true

case "$OUT" in
*confidence=model*) ;;
*) fail "live submit did not reach a model (got: $OUT)" ;;
esac
case "$OUT" in
verdict=same\ target=sess-router\ *) ;;
*) fail "live model did not keep an in-conversation reply in its own session (got: $OUT)" ;;
esac

EXPLANATIONS="$HOME_DIR/state/captain-router/explanations.log"
[ -s "$EXPLANATIONS" ] || fail "live model verdict recorded no explanation"
printf 'explanations.log:\n'
cat "$EXPLANATIONS"

printf 'ok - live router model returns a verdict with an explanation\n'
