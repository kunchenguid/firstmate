#!/usr/bin/env bash
# tests/fm-composer-pi-codex-banner-live-e2e.test.sh - the live guard for the
# Pi Codex usage-limit banner shape (live-harness-optin family; issue #5000).
#
# bin/fm-composer-lib.sh admits a Pi separator pair with a stale identity
# status as `empty` when the last non-blank row above the pair is the fixed
# banner Pi draws once a turn ended on Codex's usage limit
# (FM_COMPOSER_PI_TERMINAL_ERROR_RE_DEFAULT). That banner text and the solid
# rule beneath it are vendor-rendered, so per
# .agents/skills/firstmate-coding-guidelines the byte fixtures in
# tests/fm-composer-lib.test.sh are not enough on their own: this guard
# launches the INSTALLED pi in an isolated tmux server against a local stub
# Codex endpoint that answers every request with the usage-limit stream
# error, submits one prompt, captures the resulting screen with styling
# preserved, and requires the shared classifier to read it `empty` under the
# cursorless Herdr profile with the stale `working` and `unknown` statuses the
# incident left behind, and under the cursor-anchored tmux read. It also
# requires Pi's rendered banner row to match the declared pattern, so a Pi
# release that respells the banner fails here naming pi and `pi --version`
# instead of silently returning the fleet to the refusal.
#
# No provider request leaves the machine: the stub answers on 127.0.0.1, the
# fake Codex credential is a structurally valid JWT carrying only the account
# claim Pi's provider parses, and PI_CODING_AGENT_DIR isolates every config
# read. The prompt costs no model tokens, so the gate is default-on wherever
# pi, tmux, and node are installed (fm_live_gate): FM_COMPOSER_PI_BANNER_LIVE=1
# forces it (an absent tool then fails instead of skipping) and =0 disables it.
# A run that verified nothing fails rather than passing vacuously.
# Refresh docs/verification/runtime-backends.md ("Pi Codex usage-limit banner")
# from this guard's output after any pi upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_COMPOSER_PI_BANNER_LIVE pi tmux node

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SOCKET="fm-pi-banner-$$"
SESSION="pibanner"
WIN="pi"
CHECKED=0
STUB_PID=

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  [ -z "$STUB_PID" ] || kill "$STUB_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-banner-live.XXXXXX")
mkdir -p "$WORK/pi"

# The library under test, driven against the private socket through a PATH
# shim so its bare `tmux` calls stay isolated from any live fleet.
REAL_TMUX=$(command -v tmux)
cat > "$WORK/tmux" <<EOS
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
EOS
chmod +x "$WORK/tmux"
PATH="$WORK:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

VERSION=$(pi --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || VERSION='version-unknown'

# The stub Codex endpoint: every SSE request answers with the exact stream
# error event Pi's Codex provider turns into `Codex error: <message>`; the
# websocket transport Pi tries first is refused so Pi falls back to SSE.
cat > "$WORK/stub.mjs" <<'JS'
import http from "node:http";
const message = "The usage limit has been reached";
const server = http.createServer((req, res) => {
  req.on("data", () => {});
  req.on("end", () => {
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write(`data: ${JSON.stringify({ type: "error", message })}\n\n`);
    res.end();
  });
});
server.on("upgrade", (_req, socket) => socket.destroy());
server.listen(0, "127.0.0.1", () => console.log(server.address().port));
JS
node "$WORK/stub.mjs" > "$WORK/port" 2>/dev/null &
STUB_PID=$!
i=0
while [ ! -s "$WORK/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
PORT=$(cat "$WORK/port" 2>/dev/null)
case "$PORT" in ''|*[!0-9]*) fail "pi ($VERSION): the stub Codex endpoint did not start" ;; esac

b64url() { printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '=\n'; }
JWT="$(b64url '{"alg":"none","typ":"JWT"}').$(b64url '{"https://api.openai.com/auth":{"chatgpt_account_id":"fm-live-guard"}}').unsigned"
printf '{"providers":{"openai-codex":{"baseUrl":"http://127.0.0.1:%s","apiKey":"%s"}}}\n' "$PORT" "$JWT" > "$WORK/pi/models.json"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 120 -y 40 -c "$WORK"
tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$WIN" -c "$WORK" -- \
  env PI_CODING_AGENT_DIR="$WORK/pi" pi --model openai-codex/gpt-5.5 --no-session --no-context-files \
  || fail "pi ($VERSION): could not launch in the isolated tmux server"

# Wait for the idle composer before submitting, so the prompt lands in Pi
# rather than in a startup dialog.
budget=${FM_COMPOSER_PI_BANNER_LIVE_POLLS:-45}
i=0
while [ "$i" -lt "$budget" ]; do
  [ "$(fm_tmux_composer_state "$SESSION:$WIN")" = empty ] && break
  i=$((i + 1)); sleep 1
done
[ "$i" -lt "$budget" ] || fail "pi ($VERSION): idle composer never classified empty before the prompt"
tmux send-keys -t "$SESSION:$WIN" -l 'hello there'
tmux send-keys -t "$SESSION:$WIN" Enter

CAPS_CURSORLESS=$(printf 'styled=1\ncursor=0\nidentity=1\nrows=%s' "$FM_COMPOSER_CAPTURE_LINES")
styled=''
plain=''
i=0
while [ "$i" -lt "$budget" ]; do
  styled=$(tmux capture-pane -e -p -t "$SESSION:$WIN" 2>/dev/null | tail -n "$FM_COMPOSER_CAPTURE_LINES")
  plain=$(printf '%s\n' "$styled" | fm_composer_strip_ansi)
  case "$plain" in *'Codex error'*) break ;; esac
  i=$((i + 1)); sleep 1
done
[ "$i" -lt "$budget" ] || {
  printf '# pi pane tail without a banner:\n' >&2
  printf '%s\n' "$plain" | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
  fail "pi ($VERSION): the stub usage-limit error never rendered a Codex error banner"
}
sleep 1
styled=$(tmux capture-pane -e -p -t "$SESSION:$WIN" 2>/dev/null | tail -n "$FM_COMPOSER_CAPTURE_LINES")
plain=$(printf '%s\n' "$styled" | fm_composer_strip_ansi)

# The vendor string itself: Pi's banner row must match the declared pattern
# whole, so a respelled banner fails here rather than at the next incident.
banner_row=$(printf '%s\n' "$plain" | grep -m1 'Codex error' || true)
fm_composer_normalize_trim_var banner_row
note "pi ($VERSION): rendered banner row: $banner_row"
printf '%s' "$banner_row" | grep -qE "$FM_COMPOSER_PI_TERMINAL_ERROR_RE_DEFAULT" \
  || fail "pi ($VERSION): the rendered banner '$banner_row' no longer matches FM_COMPOSER_PI_TERMINAL_ERROR_RE_DEFAULT"

for status in working unknown idle; do
  verdict=$(fm_composer_classify_screen "$CAPS_CURSORLESS" "$styled" '' "$(printf 'pi\t%s' "$status")")
  if [ "$verdict" = empty ]; then
    CHECKED=$((CHECKED + 1))
    pass "pi ($VERSION): banner screen classifies empty on the cursorless styled read with a $status status"
  else
    printf '# pi pane tail at failure:\n' >&2
    printf '%s\n' "$plain" | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
    fail "pi ($VERSION): banner screen classified '$verdict' on the cursorless styled read with a $status status"
  fi
done
verdict=$(fm_composer_classify_screen "$CAPS_CURSORLESS" "$styled" '' probe-absent)
[ "$verdict" = unknown ] \
  || fail "pi ($VERSION): the banner must not prove a pane with no pi identity, got '$verdict'"
CHECKED=$((CHECKED + 1))
pass "pi ($VERSION): the banner over the same screen with the identity probe absent stays unknown"

tmux_verdict=$(fm_tmux_composer_state "$SESSION:$WIN")
if [ "$tmux_verdict" = empty ]; then
  CHECKED=$((CHECKED + 1))
  pass "pi ($VERSION): banner screen classifies empty on the cursor-anchored tmux read"
else
  fail "pi ($VERSION): banner screen classified '$tmux_verdict' on the cursor-anchored tmux read"
fi

[ "$CHECKED" -gt 0 ] || fail "live pi banner guard verified nothing; refusing a vacuous pass"
pass "live pi banner guard verified $CHECKED live surface(s)"
