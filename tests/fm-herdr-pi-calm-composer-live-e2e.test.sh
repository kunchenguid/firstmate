#!/usr/bin/env bash
# Live Herdr+Pi Calm composer guard (live-harness-optin family).
#
# Pi Calm's cursorless Herdr presentation leaves the separator composer above
# a dollar-prefixed usage footer.
# This guard launches real Pi with Calm on, verifies the shared classifier
# proves the idle composer empty, and verifies visible draft text stays pending.
#
# Run explicitly with FM_HERDR_PI_CALM_COMPOSER_LIVE=1 after a Pi, Calm, or
# Herdr upgrade, and before refreshing the matching runtime-backends record.
# Every Herdr operation, including adapter calls, is routed through the named
# lab helper and never through the captain's default session.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_HERDR_PI_CALM_COMPOSER_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_HERDR_PI_CALM_COMPOSER_LIVE=1 to run the live Herdr+Pi Calm composer guard"
  exit 0
fi

for tool in herdr jq pi; do
  command -v "$tool" >/dev/null 2>&1 \
    || fail "FM_HERDR_PI_CALM_COMPOSER_LIVE=1 but $tool is not installed"
done
[ -x "$HERDR_LAB_HELPER" ] \
  || fail "FM_HERDR_PI_CALM_COMPOSER_LIVE=1 but the Herdr lab helper is not executable at $HERDR_LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-pi-calm-composer-live) \
  || fail "could not generate the isolated Herdr lab session name"
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-pi-calm-composer.XXXXXX") \
  || fail "could not create the live-test temporary root"
CALM_HOME="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
PI_AGENT_ROOT=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
PI_MCP_EXTENSION="$PI_AGENT_ROOT/npm/node_modules/pi-mcp-adapter/index.ts"
[ -f "$PI_MCP_EXTENSION" ] \
  || fail "FM_HERDR_PI_CALM_COMPOSER_LIVE=1 but pi-mcp-adapter is not installed at $PI_MCP_EXTENSION"
PI_RUNTIME_AGENT_DIR="$TMP_ROOT/pi-agent"
mkdir -p "$CALM_HOME/config" "$FAKEBIN" "$PI_RUNTIME_AGENT_DIR"
printf 'on\n' > "$CALM_HOME/config/calm"
printf '%s\n' '{"mcpServers":{"synthetic":{"command":"/usr/bin/true","lifecycle":"lazy"}}}' \
  > "$CALM_HOME/mcp.json"
export HERDR_LAB_HELPER HERDR_LAB_SESSION

# Install the exact isolation teardown before provisioning; the richer cleanup
# below replaces it only after the named lab exists.
trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"' EXIT
PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab session"

cleanup() {
  local status=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"; then
    status=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

# The adapter appends the session flag before this wrapper sees the call.
# Strip it and re-route through the lab helper so a missing or foreign session
# fails closed during the live test.
cat > "$FAKEBIN/herdr" <<SHIM
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$HERDR_LAB_SESSION" ] || {
    echo "live-test wrapper refused foreign Herdr session" >&2
    exit 97
  }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "live-test wrapper requires trailing --session $HERDR_LAB_SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "\${args[@]}"
SHIM
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$ORIGINAL_PATH"
export HERDR_SESSION="$HERDR_LAB_SESSION"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() {
  env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}

WORKSPACE_JSON=$(lab workspace create --cwd "$ROOT" --label fm-pi-calm-composer --no-focus) \
  || fail "could not create the isolated Pi Calm workspace"
PANE=$(printf '%s' "$WORKSPACE_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a root pane"
TARGET="$HERDR_LAB_SESSION:$PANE"
PI_VERSION=$(PATH="$ORIGINAL_PATH" pi --version 2>/dev/null | head -1 || printf 'unknown')
HERDR_VERSION=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'unknown')

lab pane run "$PANE" \
  "cd '$ROOT' && env PI_CODING_AGENT_DIR='$PI_RUNTIME_AGENT_DIR' FM_ROOT_OVERRIDE='$CALM_HOME' pi --offline --approve --no-session --no-context-files --no-extensions -e '$ROOT/.pi/extensions/fm-calm.ts' -e '$PI_MCP_EXTENSION' --mcp-config '$CALM_HOME/mcp.json' --model openai-codex/gpt-5.6-sol --thinking medium --tools bash" \
  >/dev/null \
  || fail "could not launch Pi ($PI_VERSION) with Calm on under Herdr ($HERDR_VERSION)"

idle=0
stable=0
i=0
while [ "$i" -lt 240 ]; do
  agent_status=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
  case "$agent_status" in
    idle|done)
      stable=$((stable + 1))
      if [ "$stable" -ge 4 ]; then
        idle=1
        break
      fi
      ;;
    *) stable=0 ;;
  esac
  i=$((i + 1))
  sleep 0.25
done
[ "$idle" = 1 ] \
  || fail "Pi ($PI_VERSION) with Calm on under Herdr ($HERDR_VERSION) never reached stable idle"

verdict=$(fm_backend_herdr_composer_state "$TARGET")
[ "$verdict" = empty ] \
  || fail "Pi ($PI_VERSION) with Calm on under Herdr ($HERDR_VERSION) classified its idle composer as '$verdict', not empty"

draft="FM_PI_CALM_PENDING_$$_$RANDOM"
lab pane send-text "$PANE" "$draft" >/dev/null \
  || fail "Pi ($PI_VERSION) with Calm on under Herdr ($HERDR_VERSION) could not receive the pending-draft probe"
sleep 0.5
verdict=$(fm_backend_herdr_composer_state "$TARGET")
[ "$verdict" = pending ] \
  || fail "Pi ($PI_VERSION) with Calm on under Herdr ($HERDR_VERSION) classified visible draft text as '$verdict', not pending"

pass "live Herdr Pi Calm composer: Pi ($PI_VERSION) on Herdr ($HERDR_VERSION) is empty when idle and pending with visible text"
