#!/usr/bin/env bash
# Token-free real Pi CLI/TUI + SDK guard in a private pseudo-terminal.
# No Herdr lifecycle, live home, credentials, network or installed-source edits.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_PI_BRANCH_STATUS_LIVE pi node npm python3
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
TMP_ROOT=$(fm_test_tmproot fm-pi-branch-status-live)
export FM_STATUS_LAB="$TMP_ROOT"
mkdir -p "$TMP_ROOT/.pi/extensions/lib" "$TMP_ROOT/bin" "$TMP_ROOT/agent" "$TMP_ROOT/state" "$TMP_ROOT/config" "$TMP_ROOT/node_modules/@earendil-works"
cp "$ROOT/.pi/extensions/fm-branch-supervision.ts" "$ROOT/.pi/extensions/fm-branch-status.ts" "$TMP_ROOT/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/"*.ts "$TMP_ROOT/.pi/extensions/lib/"
cp "$ROOT/bin/fm-feishu-state.mjs" "$TMP_ROOT/bin/"
cp "$ROOT/tests/branch-status-live-fixture.ts" "$TMP_ROOT/driver.ts"
ln -s "$PI_PACKAGE_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$TMP_ROOT/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" "$TMP_ROOT/node_modules/@earendil-works/pi-ai"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$TMP_ROOT/node_modules/typebox"
cat > "$TMP_ROOT/agent/models.json" <<'JSON'
{"providers":{"status-lab":{"baseUrl":"https://branch-status.invalid/v1","api":"openai-completions","apiKey":"synthetic","models":[{"id":"lab","name":"lab","contextWindow":16384,"maxTokens":256}]}}}
JSON
printf '%s\n' '{"retry":{"enabled":false},"compaction":{"enabled":false},"tuiMode":"regular"}' > "$TMP_ROOT/agent/settings.json"
FM_HOME="$TMP_ROOT" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/state" FM_CONFIG_OVERRIDE="$TMP_ROOT/config" PI_CODING_AGENT_DIR="$TMP_ROOT/agent" \
  python3 "$ROOT/tests/branch-status-live.py" || fail "real Pi $(pi --version) branch status guard failed"
pass "real Pi $(pi --version) renders idle, processing, completed result, MAIN fallback, ownership failure, disabled, error and unknown/stale"
