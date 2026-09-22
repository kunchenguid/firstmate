#!/usr/bin/env bash
# Live guard for the rendered provider quota-wall signal that
# bin/fm-busy-lib.sh classifies and bin/fm-crew-state.sh surfaces as `quota`.
#
# The wall is a vendor-rendered surface, so a synthetic transcript alone cannot
# prove it exists (the portable regression in tests/fm-crew-state.test.sh pins
# the logic; this guard proves the rendering). It drives the REAL installed
# OpenCode TUI against a local 429 stub provider whose error body carries a
# quota message, so OpenCode paints its own retry modal - the exact shape the
# fleet incident measured - without spending any real model tokens. It then
# proves the same task reads `working` from its busy record before the modal
# renders and `quota` once it does.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_live_gate default-on FM_QUOTA_WALL_LIVE opencode tmux node

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENCODE_BIN=$(command -v opencode 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
NODE_BIN=$(command -v node 2>/dev/null || true)
SOCKET="fm-quota-wall-live-$$"
SESSION=quota-wall-live
ID=quota-wall-live
LAB=
NODE_PID=

[ -n "$OPENCODE_BIN" ] || fail "opencode is not installed"
[ -n "$REAL_TMUX" ] || fail "tmux is not installed"
[ -n "$NODE_BIN" ] || fail "node is not installed"
OPENCODE_VERSION=$("$OPENCODE_BIN" --version) || fail "opencode --version failed"

lab_pid_is_safe() {  # <pid>
  local pid=$1 cmd
  cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$cmd" in
    *"$LAB"*) return 0 ;;
  esac
  return 1
}

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  if [ -n "$NODE_PID" ] && lab_pid_is_safe "$NODE_PID"; then
    kill -TERM "$NODE_PID" 2>/dev/null || true
  fi
  sleep 0.3
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

trap cleanup EXIT

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null || true
}

crew_state() {  # read the injected task's current state through the real reader
  env -u FM_CREW_STATE_META_OVERRIDE -u FM_CREW_STATE_STATUS_OVERRIDE \
    PATH="$LAB/bin:$PATH" FM_STATE_OVERRIDE="$LAB/state" \
    "$ROOT/bin/fm-crew-state.sh" "$ID"
}

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-wall-live.XXXXXX") || fail "could not create the isolated lab"
mkdir -p "$LAB/workspace" "$LAB/config/opencode" "$LAB/data" "$LAB/cache" "$LAB/state" "$LAB/bin" \
  || fail "could not lay out the isolated lab"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated workspace"
git -C "$LAB/workspace" config user.email "guard@local" || fail "could not configure the isolated workspace"
git -C "$LAB/workspace" config user.name "guard" || fail "could not configure the isolated workspace"
git -C "$LAB/workspace" commit -q --allow-empty -m init || fail "could not seed the isolated workspace"
git -C "$LAB/workspace" checkout -q -b fm/quota-wall-live || fail "could not branch the isolated workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated workspace"

# A local stub answers every provider request with 429 and a quota message, so
# the real OpenCode CLI renders its own retry modal with no model tokens spent.
PORTFILE="$LAB/port"
"$NODE_BIN" -e '
const http = require("http");
const fs = require("fs");
const server = http.createServer((req, res) => {
  res.writeHead(429, { "content-type": "application/json" });
  res.end(JSON.stringify({
    error: {
      message: "weekly usage limit reached. It will reset in 1 day 14 hours",
      type: "rate_limit_error"
    }
  }));
});
server.listen(0, "127.0.0.1", () => fs.writeFileSync(process.argv[1], String(server.address().port)));
' "$PORTFILE" &
NODE_PID=$!
for _ in $(seq 1 60); do
  [ -s "$PORTFILE" ] && break
  sleep 0.1
done
[ -s "$PORTFILE" ] || fail "the 429 stub never reported its port"
PORT=$(cat "$PORTFILE")

# shellcheck disable=SC2016  # "$schema" is a literal JSON key, not a shell expansion.
printf '{"$schema":"https://opencode.ai/config.json","provider":{"openai":{"options":{"baseURL":"http://127.0.0.1:%s/v1","apiKey":"stub-key"}}},"model":"openai/gpt-4o-mini"}\n' "$PORT" \
  > "$LAB/config/opencode/opencode.json" || fail "could not write the isolated OpenCode config"

# The reader resolves the guard's tmux server through the PATH shim, exactly
# as it resolves a task's own backend socket in production.
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/bin/tmux" \
  || fail "could not write the tmux shim"
chmod +x "$LAB/bin/tmux" || fail "could not make the tmux shim executable"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -x 120 -y 40 -c "$WORKSPACE" \
  "env XDG_CONFIG_HOME='$LAB/config' XDG_DATA_HOME='$LAB/data' XDG_CACHE_HOME='$LAB/cache' XDG_STATE_HOME='$LAB/state' OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 '$OPENCODE_BIN'" \
  || fail "could not start the isolated OpenCode TUI"
for _ in $(seq 1 120); do
  capture | grep -Fq "$OPENCODE_VERSION" && break
  sleep 0.5
done
capture | grep -Fq "$OPENCODE_VERSION" || fail "the isolated OpenCode TUI never reached its composer"

printf 'kind=scout\nharness=opencode\nbackend=tmux\nwindow=%s\nworktree=%s\n' "$SESSION" "$WORKSPACE" \
  > "$LAB/state/$ID.meta" || fail "could not write the task metadata"
"$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" "$ID" --state busy --source opencode-plugin --event session-status \
  >/dev/null || fail "could not seed the busy record"

# Negative control: a busy record with no wall rendered reads working, so the
# quota verdict below cannot be vacuous.
before=$(crew_state)
case "$before" in
  *"state: working"*) pass "a busy OpenCode worker without a rendered wall reads working" ;;
  *) fail "a busy OpenCode worker without a wall should read working, got: $before" ;;
esac

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "Say hi" || fail "could not type the prompt"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter || fail "could not submit the prompt"

after=
for _ in $(seq 1 180); do
  after=$(crew_state)
  case "$after" in *"state: quota"*) break ;; esac
  sleep 0.5
done
case "$after" in
  *"state: quota"*) ;;
  *) capture >&2; fail "the real OpenCode quota retry modal never classified as quota, got: $after" ;;
esac
case "$after" in
  *"source: pane"*) ;;
  *) fail "the quota verdict must be attributed to the pane, got: $after" ;;
esac

# Prove the verdict came from the live vendor surface: the captured pane tail
# itself must match the rendered matcher.
capture | fm_busy_quota_tail_wall \
  || { capture >&2; fail "the live OpenCode wall pane did not match fm_busy_quota_tail_wall"; }

pass "OpenCode $OPENCODE_VERSION real 429 quota retry modal classifies as quota, not working"
