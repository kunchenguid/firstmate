#!/usr/bin/env bash
# Codemode-specific cases sourced by fm-calm-pi-extension.test.sh.

# Copy Calm into a private module root without loading any other Firstmate extension.
prepare_codemode_fixture() {
  local fixture=$1 dependency dependency_root
  mkdir -p "$fixture/lib" "$fixture/node_modules/@earendil-works" "$fixture/home/config" "$fixture/agent" "$fixture/sessions"
  cp "$EXT" "$fixture/fm-calm.ts"
  cp -RL "$ROOT/.pi/extensions/lib/". "$fixture/lib/"
  ln -s "$PI_PACKAGE_DIR" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  for dependency in @earendil-works/pi-tui @earendil-works/pi-ai typebox; do
    dependency_root="$PI_PACKAGE_DIR/node_modules/$dependency"
    if [ ! -f "$dependency_root/package.json" ]; then dependency_root="$PI_PACKAGE_DIR/../../$dependency"; fi
    [ -f "$dependency_root/package.json" ] || fail "installed Pi dependency unavailable: $dependency"
    ln -s "$dependency_root" "$fixture/node_modules/$dependency"
  done
  printf '%s\n' '{"type":"module"}' > "$fixture/package.json"
  printf 'on\n' > "$fixture/home/config/calm"
}

# Exercise renderer registration and real installed components without executing tools.
test_codemode_rendering() {
  local fixture="$TMP_ROOT/codemode-rendering" out
  if [ ! -f "$PI_PACKAGE_DIR/package.json" ] || ! command -v node >/dev/null 2>&1; then
    echo 'skip: installed Pi and node are needed for the Codemode renderer cases'
    return
  fi
  prepare_codemode_fixture "$fixture"
  out=$(EXT="$fixture/fm-calm.ts" VISIBILITY="$fixture/lib/fm-calm-visibility.ts" FM_HOME="$fixture/home" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" PI_TUI_PACKAGE_DIR="$fixture/node_modules/@earendil-works/pi-tui" \
    node "$ROOT/tests/assets/fm-calm-codemode-rendering.mjs" 2>&1) || fail "Codemode rendering failed: $out"
  printf '%s\n' "$out"
}

# Stop only the servers created for this Codemode test and verify the Herdr tripwire.
cleanup_codemode_e2e() {
  if [ -n "${CODEMODE_TMUX_DIR:-}" ]; then
    TMUX_TMPDIR="$CODEMODE_TMUX_DIR" tmux -L codemode kill-server 2>/dev/null || true
    "$ROOT/bin/fm-lab-home.sh" teardown "$CODEMODE_LAB_HOME" || return 1
    CODEMODE_TMUX_DIR=
  fi
  if [ -n "${CODEMODE_HERDR_SESSION:-}" ]; then
    "$ROOT/bin/fm-herdr-lab.sh" teardown "$CODEMODE_HERDR_SESSION" || return 1
    CODEMODE_HERDR_SESSION=
  fi
}

# Submit literal text and Enter through the private terminal's own input path.
codemode_submit() {
  if [ -n "${CODEMODE_TMUX_DIR:-}" ]; then
    TMUX_TMPDIR="$CODEMODE_TMUX_DIR" tmux -L codemode send-keys -t codemode -l "$1"
    TMUX_TMPDIR="$CODEMODE_TMUX_DIR" tmux -L codemode send-keys -t codemode Enter
  else
    "$ROOT/bin/fm-herdr-lab.sh" run "$CODEMODE_HERDR_SESSION" pane run "$CODEMODE_PANE" "$1"
  fi
}

# Send one stock Pi expansion key to the isolated TUI.
codemode_expand() {
  if [ -n "${CODEMODE_TMUX_DIR:-}" ]; then
    TMUX_TMPDIR="$CODEMODE_TMUX_DIR" tmux -L codemode send-keys -t codemode C-o
  else
    "$ROOT/bin/fm-herdr-lab.sh" run "$CODEMODE_HERDR_SESSION" pane send-keys "$CODEMODE_PANE" ctrl+o
  fi
}

# Launch one Pi command in a fresh workspace of the private Herdr session.
codemode_herdr_launch() {
  local fixture=$1 launch=$2 workspace
  workspace=$("$ROOT/bin/fm-herdr-lab.sh" run "$CODEMODE_HERDR_SESSION" workspace create --cwd "$fixture" --env "HOME=$fixture" --env "ZDOTDIR=$fixture" --no-focus) \
    || fail 'could not create the private Herdr Codemode workspace'
  CODEMODE_PANE=$(printf '%s' "$workspace" | jq -er '.result.root_pane.pane_id') || fail 'Herdr workspace create did not return a pane id'
  "$ROOT/bin/fm-herdr-lab.sh" run "$CODEMODE_HERDR_SESSION" pane run "$CODEMODE_PANE" "$launch" || fail 'could not launch the private Herdr Codemode test'
}

# Exit Pi through its stock empty-editor shortcut rather than submitting a model prompt.
codemode_exit() {
  if [ -n "${CODEMODE_TMUX_DIR:-}" ]; then
    TMUX_TMPDIR="$CODEMODE_TMUX_DIR" tmux -L codemode send-keys -t codemode C-d
  else
    "$ROOT/bin/fm-herdr-lab.sh" run "$CODEMODE_HERDR_SESSION" pane send-keys "$CODEMODE_PANE" ctrl+d
  fi
}

# Capture only the live viewport so erased rows cannot pass from stale scrollback.
codemode_capture() {
  if [ -n "${CODEMODE_TMUX_DIR:-}" ]; then
    TMUX_TMPDIR="$CODEMODE_TMUX_DIR" tmux -L codemode capture-pane -p -t codemode
  else
    "$ROOT/bin/fm-herdr-lab.sh" run "$CODEMODE_HERDR_SESSION" pane read "$CODEMODE_PANE" --source visible --format text --raw
  fi | node -e 'let text=""; process.stdin.on("data", part => text += part); process.stdin.on("end", () => process.stdout.write(text.replace(/\x1b\[[0-9;]*m/g, "").replace(/\r/g, "")));'
}

# Await one expected settled rendering with a bounded wait and a diagnostic snapshot.
codemode_wait() {
  local file=$1 needle=$2 attempt=0
  while [ "$attempt" -lt 100 ]; do
    codemode_capture > "$file"
    grep -Fq "$needle" "$file" && return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  fail "Pi Codemode did not render $needle: $(< "$file")"
}

# Await the gapless Calm-hidden rendering, reporting the last failed assertion on timeout.
codemode_wait_hidden() {
  local file=$1 attempt=0
  while [ "$attempt" -lt 100 ]; do
    codemode_capture > "$file"
    assert_codemode_hidden "$file" 2>/dev/null && return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  assert_codemode_hidden "$file"
}

# Assert both absence and the exact no-tool geometry around the visible final reply.
assert_codemode_hidden() {
  local file=$1
  node - "$file" <<'JS'
const assert = require("node:assert/strict");
const rows = require("node:fs").readFileSync(process.argv[2], "utf8").split("\n").map(row => row.trim());
for (const needle of ["text(await", "tools.read", "tools.fm_branch_outcomes", "OUTCOME_PRIVATE_RAW", "CODEMODE_READ_PRIVATE", "ordinary.txt", "seq=7"]) {
  assert(!rows.some(row => row.includes(needle)), `Calm leaked ${needle}`);
}
const baseline = rows.indexOf("BASELINE_FINAL") - rows.indexOf("GENUINE_BASELINE");
const actual = rows.indexOf("AFTER_CODEMODE") - rows.indexOf("GENUINE_CODEMODE");
assert(baseline > 0 && rows.includes("GENUINE_CODEMODE") && rows.includes("AFTER_CODEMODE"), "genuine content missing from viewport");
assert.equal(actual, baseline, "Codemode left residual spacing");
JS
}

# Drive real installed Pi, its Codemode sandbox, toggles, exports and restored history.
test_codemode_terminal_e2e() {
  local fixture="$TMP_ROOT/codemode-e2e" launch session_file tui_mode
  if ! command -v pi >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1 || [ ! -f "$PI_PACKAGE_DIR/dist/extensions/codemode/renderer.js" ]; then
    echo 'skip: installed Pi Codemode and node are needed for the Codemode TUI case'
    return
  fi
  if ! command -v tmux >/dev/null 2>&1 && { ! command -v herdr >/dev/null 2>&1 || [ "${HERDR_ENV:-}" != 1 ]; }; then
    echo 'skip: tmux or a Herdr-managed environment is needed for the Codemode TUI case'
    return
  fi
  prepare_codemode_fixture "$fixture"
  cp "$ROOT/tests/assets/fm-calm-codemode-provider.ts" "$fixture/provider.ts"
  printf 'CODEMODE_READ_PRIVATE\n' > "$fixture/sample.txt"
  printf 'ORDINARY_READ_PRIVATE\n' > "$fixture/ordinary.txt"
  printf '%s\n' '{"theme":"dark","quietStartup":true,"compaction":{"enabled":false}}' > "$fixture/agent/settings.json"
  tui_mode=
  if pi --help 2>&1 | grep -q -- '--tui-mode'; then tui_mode='--tui-mode fullscreen'; fi
  launch="cd '$fixture' && exec env HOME='$fixture' FM_HOME='$fixture/home' PI_CODING_AGENT_DIR='$fixture/agent' CODEMODE_CONTEXT='$fixture/context.jsonl' CODEMODE_EVENTS='$fixture/events.jsonl' PI_OFFLINE=1 pi --approve --no-context-files --no-skills --no-prompt-templates --no-extensions -e ./fm-calm.ts -e ./provider.ts -e builtin:codemode --tools read,codemode,fm_branch_outcomes --session-dir '$fixture/sessions' --model calm-codemode-test/deterministic $tui_mode"
  printf '%s\n' '#!/usr/bin/env bash' "$launch \"\$@\"" > "$fixture/launch.sh"
  launch="bash '$fixture/launch.sh'"
  if command -v tmux >/dev/null 2>&1; then
    CODEMODE_LAB_HOME="$fixture/terminal-home"
    "$ROOT/bin/fm-lab-home.sh" create "$CODEMODE_LAB_HOME" >/dev/null || fail 'could not create the private Codemode lab home'
    CODEMODE_TMUX_DIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$CODEMODE_LAB_HOME") || fail 'could not create the private Codemode tmux socket dir'
    TMUX_TMPDIR="$CODEMODE_TMUX_DIR" tmux -L codemode new-session -d -s codemode -x 120 -y 44 "$launch" || fail 'could not launch the private tmux Codemode test'
  else
    CODEMODE_HERDR_SESSION=$("$ROOT/bin/fm-herdr-lab.sh" name firstmate-calm-codemode) || fail 'could not name the private Herdr Codemode test'
    "$ROOT/bin/fm-herdr-lab.sh" provision "$CODEMODE_HERDR_SESSION" || fail 'could not provision the private Herdr Codemode test'
    codemode_herdr_launch "$fixture" "$launch"
  fi
  codemode_wait "$fixture/start.txt" CODEMODE_TEST_READY
  if grep -Fq CODEMODE_RENDERER_UNAVAILABLE "$fixture/start.txt"; then
    assert_contains "$(< "$fixture/start.txt")" 'pi.registerToolRenderer() is unavailable' 'missing Codemode capability was not disclosed'
    codemode_submit /calm-codemode-test
    codemode_wait "$fixture/unsupported.txt" AFTER_CODEMODE
    assert_contains "$(< "$fixture/unsupported.txt")" OUTCOME_PRIVATE_RAW 'unsupported renderer changed stock execution'
    codemode_submit "/export $fixture/export.html"
    codemode_wait "$fixture/unsupported-export.txt" 'Session exported to:'
    cleanup_codemode_e2e || fail 'unsupported Codemode cleanup failed'
    pass "Pi $(pi --version) discloses its unavailable Codemode renderer capability and preserves stock execution and export"
    return
  fi
  codemode_submit /calm-codemode-baseline
  codemode_wait "$fixture/baseline.txt" BASELINE_FINAL
  codemode_submit /calm-codemode-test
  codemode_wait "$fixture/hidden.txt" AFTER_CODEMODE
  assert_codemode_hidden "$fixture/hidden.txt" || fail 'Codemode was not gaplessly hidden'
  session_file=$(find "$fixture/sessions" -name '*.jsonl' -type f | head -1)
  cp "$session_file" "$fixture/original.jsonl"
  codemode_expand
  codemode_wait "$fixture/hidden-expanded.txt" 'Tool output: expanded'
  assert_codemode_hidden "$fixture/hidden-expanded.txt" || fail 'expansion exposed Codemode under Calm'
  codemode_submit /calm
  codemode_wait "$fixture/stock-expanded.txt" OUTCOME_EXPANDED_TAIL
  assert_contains "$(< "$fixture/stock-expanded.txt")" 'tools.fm_branch_outcomes' 'Calm off did not restore the original script'
  codemode_expand
  codemode_wait "$fixture/stock-collapsed.txt" 'more lines'
  assert_contains "$(< "$fixture/stock-collapsed.txt")" OUTCOME_PRIVATE_RAW 'collapse lost the stock Codemode output'
  assert_not_contains "$(< "$fixture/stock-collapsed.txt")" OUTCOME_EXPANDED_TAIL 'collapse kept the expanded Codemode output'
  codemode_submit /calm
  codemode_wait_hidden "$fixture/rehidden.txt" || fail 'Calm toggle did not rehide Codemode'
  codemode_submit "/export $fixture/export.html"
  codemode_wait "$fixture/export.txt" 'Session exported to:'
  assert_codemode_hidden "$fixture/export.txt" || fail 'export left Codemode visible'
  cmp "$session_file" "$fixture/original.jsonl" || fail 'toggles or export changed persisted messages'
  codemode_exit
  sleep 1
  if [ -n "${CODEMODE_TMUX_DIR:-}" ]; then
    TMUX_TMPDIR="$CODEMODE_TMUX_DIR" tmux -L codemode kill-session -t codemode 2>/dev/null || true
    TMUX_TMPDIR="$CODEMODE_TMUX_DIR" tmux -L codemode new-session -d -s codemode -x 120 -y 44 "$launch --session '$session_file'" || fail 'could not relaunch the private tmux Codemode test'
  else
    codemode_herdr_launch "$fixture" "$launch --session '$session_file'"
  fi
  codemode_wait "$fixture/restored.txt" AFTER_CODEMODE
  assert_codemode_hidden "$fixture/restored.txt" || fail 'restart exposed Codemode history'
  codemode_submit /calm
  codemode_wait "$fixture/restored-stock.txt" OUTCOME_PRIVATE_RAW
  assert_contains "$(< "$fixture/restored-stock.txt")" 'tools.fm_branch_outcomes' 'restart did not restore ordinary Codemode presentation'
  cmp "$session_file" "$fixture/original.jsonl" || fail 'restart or restored toggles changed persisted messages'
  SESSION_FILE="$fixture/original.jsonl" CODEMODE_FIXTURE="$fixture" node "$ROOT/tests/assets/fm-calm-codemode-content.mjs" || fail 'Codemode context, execution, history or export changed'
  cleanup_codemode_e2e || fail 'Codemode terminal cleanup or default-session tripwire failed'
  pass "Pi $(pi --version) Codemode TUI hides repeated script/nested calls gaplessly, restores stock expansion/history and preserves context, usage, session and export"
}
