#!/usr/bin/env bash
# Live Lavish listener-reply guard (live-harness-optin family).
#
# Run explicitly with FM_LAVISH_REPLY_LIVE_E2E=1.
# The guard opens one isolated real Lavish session without opening a browser,
# arms the real process-event listener, sends a reply through the public host
# command, and verifies the real session page exposes it to the Conversation
# panel as agent chat.
# An absent lavish-axi is reported as a skip because ordinary CI does not carry
# the optional live review tool.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${FM_LAVISH_REPLY_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_LAVISH_REPLY_LIVE_E2E=1 to run the live Lavish listener-reply guard"
  exit 0
fi

if ! command -v lavish-axi >/dev/null 2>&1; then
  echo "skip: FM_LAVISH_REPLY_LIVE_E2E=1 but lavish-axi is not installed"
  exit 0
fi
command -v node >/dev/null 2>&1 \
  || { echo "not ok - FM_LAVISH_REPLY_LIVE_E2E=1 but node is not installed" >&2; exit 1; }

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lavish-reply-live.XXXXXX")
HOME_DIR="$LAB/home"
ARTIFACT="$LAB/board.html"
CLAIMS="$LAB/claims"
mkdir -p "$HOME_DIR" "$CLAIMS"
chmod 700 "$HOME_DIR" "$CLAIMS"
cat > "$ARTIFACT" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Lavish reply live guard</title></head>
<body style="background:#fff;color:#111"><main><h1>Lavish reply live guard</h1></main></body>
</html>
HTML

cleanup() {
  local rc=$?
  trap - EXIT
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent-lavish.sh" retire "$ARTIFACT" >/dev/null 2>&1 || true
  lavish-axi end "$ARTIFACT" >/dev/null 2>&1 || true
  rm -rf "$LAB"
  exit "$rc"
}
trap cleanup EXIT

open_out=$(lavish-axi "$ARTIFACT" --no-open) || fail "could not open the throwaway Lavish session"
url=$(printf '%s\n' "$open_out" | sed -n 's/^  url: "\(.*\)"$/\1/p' | head -1)
[ -n "$url" ] || fail "Lavish did not report the throwaway session URL"

FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ARTIFACT" >/dev/null \
  || fail "could not arm the real Lavish listener"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null \
  || fail "could not start the real Lavish listener"

source_id=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ARTIFACT")
ready=0
for _ in $(seq 1 100); do
  if [ -s "$HOME_DIR/state/procevent/$source_id.child" ]; then
    ready=1
    break
  fi
  sleep 0.1
done
[ "$ready" -eq 1 ] || fail "the real Lavish listener did not publish its runner-owned child"

token="listener-reply-live-$PPID-$$"
host_status="$HOME_DIR/state/lavish-reply-live.status"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_LAVISH_HOST_STATUS_FILE="$host_status" \
  "$ROOT/bin/fm-procevent-lavish.sh" reply "$ARTIFACT" "$token" >/dev/null \
  || fail "the public reply command failed"

seen=0
for _ in $(seq 1 100); do
  if node -e '
    const [url, token] = process.argv.slice(1);
    fetch(url).then((response) => response.text()).then((html) => {
      process.exit(html.includes(token) ? 0 : 1);
    }).catch(() => process.exit(1));
  ' "$url" "$token"; then
    seen=1
    break
  fi
  sleep 0.1
done
[ "$seen" -eq 1 ] \
  || fail "the listener-mediated --agent-reply did not reach the real Conversation session"

version=$(lavish-axi --version 2>/dev/null | head -1 || printf 'version-unknown')
pass "Lavish $version displays a reply sent through the watcher-owned listener"
