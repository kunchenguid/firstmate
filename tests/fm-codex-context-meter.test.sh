#!/usr/bin/env bash
# Behavior tests for the opt-in Codex context meter and reversible installer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

METER="$ROOT/bin/fm-codex-context-meter.sh"
INSTALLER="$ROOT/bin/fm-codex-context-meter-install.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-context-meter)

cleanup_context_meter() {
  rm -rf "$TMP_ROOT"
}
trap cleanup_context_meter EXIT

expect_silent_zero() {
  local label=$1
  shift
  local out status=0
  out=$("$@" 2>&1) || status=$?
  expect_code 0 "$status" "$label must exit zero"
  [ -z "$out" ] || fail "$label must be silent, got: $out"
}

make_fake_herdr() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
exit "${FM_FAKE_HERDR_EXIT:-0}"
SH
  chmod +x "$dir/herdr"
}

run_meter() {
  local pane=$1 transcript=$2 fakebin=$3 event=${4:-PostToolUse}
  printf '{"hook_event_name":"%s","transcript_path":"%s"}\n' "$event" "$transcript" \
    | HERDR_PANE_ID="$pane" FM_FAKE_HERDR_LOG="$TMP_ROOT/herdr.log" \
      PATH="$fakebin:$PATH" "$METER"
}

test_active_context_and_post_compaction() {
  local case_dir transcript fakebin out status=0 token_bytes
  case_dir="$TMP_ROOT/active"
  transcript="$case_dir/transcript.jsonl"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir"
  make_fake_herdr "$fakebin"
  cat > "$transcript" <<'EOF'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":987654},"last_token_usage":{"total_tokens":216653},"model_context_window":258400}}}
EOF
  : > "$TMP_ROOT/herdr.log"

  out=$(run_meter pane-active "$transcript" "$fakebin") || status=$?
  expect_code 0 "$status" "normal context meter hook"
  [ -z "$out" ] || fail "normal context meter hook printed output: $out"
  assert_grep 'report-metadata pane-active --source firstmate:codex-context --agent codex --token context=████████░░ 216.7k / 258.4k · 84%' \
    "$TMP_ROOT/herdr.log" "meter did not report the active-context numerator and 84% bar"
  assert_no_grep '987' "$TMP_ROOT/herdr.log" "meter used cumulative total_token_usage"
  token_bytes=$(sed 's/^.*--token context=//' "$TMP_ROOT/herdr.log" | wc -c | tr -d ' ')
  [ "$token_bytes" -lt 80 ] || fail "reported context token exceeded Herdr's 80-byte ceiling"

  cat >> "$transcript" <<'EOF'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1200000},"last_token_usage":{"total_tokens":42000},"model_context_window":258400}}}
EOF
  : > "$TMP_ROOT/herdr.log"
  out=$(run_meter pane-active "$transcript" "$fakebin" PostCompact) || status=$?
  expect_code 0 "$status" "post-compaction context meter hook"
  [ -z "$out" ] || fail "post-compaction context meter hook printed output: $out"
  assert_grep 'context=██░░░░░░░░ 42.0k / 258.4k · 16%' "$TMP_ROOT/herdr.log" \
    "post-compaction hook did not immediately report the lower active count"
  pass "Codex context meter uses active usage and follows compaction immediately"
}

test_hook_failure_paths_are_silent() {
  local case_dir transcript fakebin no_jq out status=0 missing
  case_dir="$TMP_ROOT/fail-open"
  transcript="$case_dir/transcript.jsonl"
  fakebin="$case_dir/fakebin"
  missing="$case_dir/missing.jsonl"
  mkdir -p "$case_dir"
  make_fake_herdr "$fakebin"
  printf '{malformed\n' > "$transcript"
  : > "$TMP_ROOT/herdr.log"

  expect_silent_zero "malformed transcript" run_meter pane-fail "$transcript" "$fakebin"
  expect_silent_zero "missing transcript" run_meter pane-fail "$missing" "$fakebin"
  expect_silent_zero "missing pane id" run_meter '' "$transcript" "$fakebin"
  out=$(printf '{malformed' | HERDR_PANE_ID=pane-fail PATH="$fakebin:$PATH" "$METER" 2>&1) \
    || status=$?
  expect_code 0 "$status" "malformed hook payload"
  [ -z "$out" ] || fail "malformed hook payload printed output: $out"

  no_jq=$(fm_fakebin "$case_dir/no-jq")
  ln -s "$(command -v bash)" "$no_jq/bash"
  out=$(printf '{"hook_event_name":"PostToolUse","transcript_path":"%s"}\n' "$transcript" \
    | HERDR_PANE_ID=pane-fail PATH="$no_jq" "$METER" 2>&1) || status=$?
  expect_code 0 "$status" "missing jq hook"
  [ -z "$out" ] || fail "missing jq hook printed output: $out"

  printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":10},"model_context_window":100}}}' > "$transcript"
  out=$(FM_FAKE_HERDR_EXIT=9 run_meter pane-fail "$transcript" "$fakebin") || status=$?
  expect_code 0 "$status" "failed Herdr report"
  [ -z "$out" ] || fail "failed Herdr report printed output: $out"
  pass "Codex context meter is silent and fail-open for absent, malformed, and reporting failures"
}

write_install_fixtures() {
  local home=$1 herdr_config=$2
  mkdir -p "$home/.codex" "$(dirname "$herdr_config")"
  cat > "$home/.codex/hooks.json" <<'EOF'
{
  "description": "captain hooks",
  "hooks": {
    "Stop": [{"matcher": "foreign", "hooks": [{"type": "command", "command": "printf foreign", "timeout": 17}]}]
  },
  "captain": {"keep": true}
}
EOF
  cat > "$home/.codex/config.toml" <<'EOF'
# Captain Codex config.
model = "gpt-test"

[tui]
status_line = ["model-with-reasoning", "git-branch"] # keep footer comment
theme = "nord"

[mcp_servers.example]
command = "example"
EOF
  cat > "$herdr_config" <<'EOF'
# Captain Herdr config.
[theme]
name = "nord"

[ui.sidebar.agents]
row_gap = 1
rows = [["state_icon", "workspace"], ["agent"]]

[ui.sidebar.agents.rows_by_agent]
claude = [["state_icon", "workspace"], ["terminal_title_stripped"]]
EOF
}

test_installer_preserves_merges_and_uninstalls() {
  local case_dir home codex_home herdr_config original_hooks original_codex original_herdr
  local once_hooks once_codex once_herdr once_state
  case_dir="$TMP_ROOT/install"
  home="$case_dir/home"
  codex_home="$home/.codex"
  herdr_config="$case_dir/herdr/config.toml"
  write_install_fixtures "$home" "$herdr_config"
  original_hooks="$case_dir/hooks.original"
  original_codex="$case_dir/codex.original"
  original_herdr="$case_dir/herdr.original"
  cp "$codex_home/hooks.json" "$original_hooks"
  cp "$codex_home/config.toml" "$original_codex"
  cp "$herdr_config" "$original_herdr"

  HOME="$home" CODEX_HOME="$codex_home" HERDR_CONFIG_PATH="$herdr_config" \
    "$INSTALLER" install >/dev/null || fail "context meter install failed"

  python3 - "$codex_home/hooks.json" "$codex_home/config.toml" "$herdr_config" <<'PY' \
    || fail "installed Codex or Herdr config did not retain the required semantics"
import json
import sys
import tomllib

with open(sys.argv[1], encoding="utf-8") as stream:
    hooks = json.load(stream)
with open(sys.argv[2], "rb") as stream:
    codex = tomllib.load(stream)
with open(sys.argv[3], "rb") as stream:
    herdr = tomllib.load(stream)

assert hooks["description"] == "captain hooks"
assert hooks["captain"] == {"keep": True}
assert hooks["hooks"]["Stop"][0]["matcher"] == "foreign"
for event in ("SessionStart", "PostToolUse", "PostCompact", "Stop"):
    owned = [
        hook
        for group in hooks["hooks"][event]
        for hook in group["hooks"]
        if "fm-codex-context-meter.sh" in hook.get("command", "")
    ]
    assert len(owned) == 1
    assert owned[0]["timeout"] == 2

assert codex["model"] == "gpt-test"
assert codex["tui"]["theme"] == "nord"
assert codex["mcp_servers"]["example"]["command"] == "example"
for item in ("context-used", "context-window-size", "used-tokens"):
    assert item in codex["tui"]["status_line"]

assert herdr["theme"]["name"] == "nord"
assert herdr["ui"]["sidebar"]["agents"]["row_gap"] == 1
assert herdr["ui"]["sidebar"]["agents"]["rows_by_agent"]["claude"][1] == ["terminal_title_stripped"]
assert herdr["ui"]["sidebar"]["agents"]["rows_by_agent"]["codex"] == [
    ["state_icon", "workspace"], ["agent"], ["$context"]
]
PY
  HERDR_CONFIG_PATH="$herdr_config" herdr config check >/dev/null \
    || fail "real Herdr config validation rejected the installed \$context row"

  once_hooks="$case_dir/hooks.once"
  once_codex="$case_dir/codex.once"
  once_herdr="$case_dir/herdr.once"
  once_state="$case_dir/state.once"
  cp "$codex_home/hooks.json" "$once_hooks"
  cp "$codex_home/config.toml" "$once_codex"
  cp "$herdr_config" "$once_herdr"
  cp "$codex_home/.firstmate-codex-context-meter.json" "$once_state"
  HOME="$home" CODEX_HOME="$codex_home" HERDR_CONFIG_PATH="$herdr_config" \
    "$INSTALLER" install >/dev/null || fail "second context meter install failed"
  cmp -s "$once_hooks" "$codex_home/hooks.json" || fail "second install changed hooks.json bytes"
  cmp -s "$once_codex" "$codex_home/config.toml" || fail "second install changed Codex config bytes"
  cmp -s "$once_herdr" "$herdr_config" || fail "second install changed Herdr config bytes"
  cmp -s "$once_state" "$codex_home/.firstmate-codex-context-meter.json" \
    || fail "second install changed ownership receipt bytes"

  HOME="$home" CODEX_HOME="$codex_home" HERDR_CONFIG_PATH="$herdr_config" \
    "$INSTALLER" uninstall >/dev/null || fail "context meter uninstall failed"
  cmp -s "$original_hooks" "$codex_home/hooks.json" || fail "uninstall did not restore hooks bytes"
  cmp -s "$original_codex" "$codex_home/config.toml" || fail "uninstall did not restore Codex config bytes"
  cmp -s "$original_herdr" "$herdr_config" || fail "uninstall did not restore Herdr config bytes"
  assert_absent "$codex_home/.firstmate-codex-context-meter.json" \
    "uninstall left its ownership receipt"
  pass "context meter installer preserves config, is byte-idempotent, and uninstalls exactly"
}

test_uninstall_after_drift_removes_only_owned_values() {
  local case_dir home codex_home herdr_config
  case_dir="$TMP_ROOT/drift"
  home="$case_dir/home"
  codex_home="$home/.codex"
  herdr_config="$case_dir/herdr/config.toml"
  write_install_fixtures "$home" "$herdr_config"
  HOME="$home" CODEX_HOME="$codex_home" HERDR_CONFIG_PATH="$herdr_config" \
    "$INSTALLER" install >/dev/null || fail "drift fixture install failed"

  python3 - "$codex_home/hooks.json" "$codex_home/config.toml" "$herdr_config" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    hooks = json.load(stream)
hooks["hooks"]["Stop"].append({"hooks": [{"type": "command", "command": "printf later"}]})
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(hooks, stream, indent=2)
    stream.write("\n")

for path, marker, addition in (
    (sys.argv[2], '"used-tokens"]', ', "session-id"]'),
    (sys.argv[3], '["$context"]]', ', ["terminal_title"]]'),
):
    with open(path, encoding="utf-8") as stream:
        text = stream.read()
    assert marker in text
    with open(path, "w", encoding="utf-8") as stream:
        stream.write(text.replace(marker, marker[:-1] + addition, 1))
PY

  HOME="$home" CODEX_HOME="$codex_home" HERDR_CONFIG_PATH="$herdr_config" \
    "$INSTALLER" uninstall >/dev/null || fail "drifted uninstall failed"
  python3 - "$codex_home/hooks.json" "$codex_home/config.toml" "$herdr_config" <<'PY' \
    || fail "drifted uninstall removed captain-owned values"
import json
import sys
import tomllib

with open(sys.argv[1], encoding="utf-8") as stream:
    hooks = json.load(stream)
with open(sys.argv[2], "rb") as stream:
    codex = tomllib.load(stream)
with open(sys.argv[3], "rb") as stream:
    herdr = tomllib.load(stream)

commands = [entry["command"] for group in hooks["hooks"]["Stop"] for entry in group["hooks"]]
assert "printf foreign" in commands
assert "printf later" in commands
assert not any("fm-codex-context-meter.sh" in command for command in commands)
assert "session-id" in codex["tui"]["status_line"]
assert "context-used" not in codex["tui"]["status_line"]
assert ["terminal_title"] in herdr["ui"]["sidebar"]["agents"]["rows_by_agent"]["codex"]
assert ["$context"] not in herdr["ui"]["sidebar"]["agents"]["rows_by_agent"]["codex"]
PY
  pass "drifted uninstall removes only Firstmate-owned hooks, footer fields, and \$context row"
}

test_active_context_and_post_compaction
test_hook_failure_paths_are_silent
test_installer_preserves_merges_and_uninstalls
test_uninstall_after_drift_removes_only_owned_values
