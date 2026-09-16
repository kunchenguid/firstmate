#!/usr/bin/env bash
# Opt-in real Pi/Herdr regression for the live /tasks widget with Calm on and off.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PI_TASKS_HERDR_LIVE_E2E herdr jq pi python3

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-"$ROOT/bin/fm-herdr-lab.sh"}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name tasks-live-widget)
TMP_ROOT=$(fm_test_tmproot fm-pi-tasks-herdr-live-e2e)
PROJECT="$TMP_ROOT/project"
HOME_DIR="$TMP_ROOT/home"
PI_CONFIG="$TMP_ROOT/pi-config"
SESSIONS="$TMP_ROOT/sessions"
PANE=

cleanup() {
  local rc=$?
  trap - EXIT
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || rc=1
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr task-widget lab"

mkdir -p "$PROJECT/.pi/extensions/lib" "$PROJECT/bin" "$HOME_DIR/config" "$HOME_DIR/state" "$PI_CONFIG" "$SESSIONS"
cp "$ROOT/.pi/extensions/fm-tasks.ts" "$PROJECT/.pi/extensions/fm-tasks.ts"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$PROJECT/.pi/extensions/fm-calm.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$PROJECT/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$PROJECT/.pi/extensions/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$PROJECT/.pi/extensions/lib/fm-operational-input.ts"
printf 'off\n' >"$HOME_DIR/config/calm"
printf '%s\n' '{"terminal":{"clearOnShrink":true}}' >"$PI_CONFIG/settings.json"
printf '%s\n' '{"type":"module"}' >"$PROJECT/package.json"
: >"$HOME_DIR/task-widget-invocations"
started_at=$(date -u -v-5S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d '5 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
printf '[{"id":"live-task","ref":"t1","name":"live-widget","status":"working","outcome":"WIDGET_INITIAL","started_at":"%s"}]\n' \
  "$started_at" >"$HOME_DIR/widget-data.json"
cat >"$PROJECT/bin/fm-tasks.sh" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = --json ] || exit 2
printf 'call\n' >>"${FM_HOME:?}/task-widget-invocations"
cat "$FM_HOME/widget-data.json"
SH
chmod +x "$PROJECT/bin/fm-tasks.sh"

OUT=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create \
  --cwd "$PROJECT" --label tasks-live --no-focus)
PANE=$(printf '%s' "$OUT" | jq -r '.result.root_pane.pane_id')
PI_CMD=$(printf 'cd %q && env FM_HOME=%q FM_ROOT_OVERRIDE=%q FM_PI_TASKS_REFRESH_MS=500 FM_PI_TASKS_EVENT_REFRESH_MIN_MS=100 PI_CODING_AGENT_DIR=%q PI_OFFLINE=1 pi --approve --no-context-files --no-extensions -e .pi/extensions/fm-calm.ts -e .pi/extensions/fm-tasks.ts --session-dir %q' \
  "$PROJECT" "$HOME_DIR" "$PROJECT" "$PI_CONFIG" "$SESSIONS")
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$PANE" "$PI_CMD" >/dev/null \
  || fail "could not launch the real Pi task-widget fixture"

pane_text() {
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$PANE" --source recent --lines 120 2>/dev/null || true
}
wait_for_text() {
  local expected=$1 i=0 text=
  while [ "$i" -lt 120 ]; do
    text=$(pane_text)
    printf '%s' "$text" | grep -Fq "$expected" && return 0
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s\n' "$text" >&2
  return 1
}
wait_for_absence() {
  local rejected=$1 i=0 text=
  while [ "$i" -lt 80 ]; do
    text=$(pane_text)
    if ! printf '%s' "$text" | grep -Fq "$rejected"; then return 0; fi
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s\n' "$text" >&2
  return 1
}
send_command() {
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$PANE" "$1" >/dev/null
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" enter >/dev/null
}
transcript_lines() {
  local file
  file=$(find "$SESSIONS" -type f -name '*.jsonl' -print | head -1)
  [ -n "$file" ] || { printf '0\n'; return; }
  wc -l <"$file" | tr -d ' '
}
current_elapsed() {
  pane_text | grep 'WIDGET_INITIAL' | tail -1 | grep -Eo '[0-9]+:[0-9]{2}:[0-9]{2}' | head -1
}

wait_for_text "(openai)" || fail "real Pi did not reach its ready composer"
sleep 0.5
if pane_text | grep -Fq WIDGET_INITIAL; then fail "task widget was visible at Pi startup"; fi
before=$(transcript_lines)
send_command /tasks
wait_for_text WIDGET_INITIAL || fail "first /tasks did not open the live table"
first=$(current_elapsed)
[ -n "$first" ] || fail "live table did not show authoritative elapsed time"
second=$first
for _ in $(seq 1 12); do
  sleep 0.25
  second=$(current_elapsed)
  [ -n "$second" ] && [ "$second" != "$first" ] && break
done
[ -n "$second" ] && [ "$second" != "$first" ] \
  || fail "elapsed display did not increment locally"
third=$second
for _ in $(seq 1 12); do
  sleep 0.25
  third=$(current_elapsed)
  [ -n "$third" ] && [ "$third" != "$second" ] && break
done
[ -n "$third" ] && [ "$third" != "$second" ] \
  || fail "elapsed display did not produce a second increment"
after=$(transcript_lines)
[ "$after" = "$before" ] || fail "/tasks or elapsed ticks grew the Pi transcript ($before -> $after)"

# Calm toggles own only above-editor presentation. The live task table remains
# below the editor in both modes without being removed or recreated.
send_command /calm
for _ in $(seq 1 40); do
  [ "$(cat "$HOME_DIR/config/calm" 2>/dev/null)" = on ] && break
  sleep 0.1
done
[ "$(cat "$HOME_DIR/config/calm")" = on ] || fail "Calm did not turn on"
wait_for_text WIDGET_INITIAL || fail "Calm-on toggle hid the task widget"
send_command /calm
for _ in $(seq 1 40); do
  [ "$(cat "$HOME_DIR/config/calm" 2>/dev/null)" = off ] && break
  sleep 0.1
done
[ "$(cat "$HOME_DIR/config/calm")" = off ] || fail "Calm did not turn off"
wait_for_text WIDGET_INITIAL || fail "Calm-off toggle hid the task widget"

printf '[{"id":"live-task","ref":"t1","name":"live-widget","status":"ready","outcome":"WIDGET_REFRESHED","started_at":"%s"}]\n' \
  "$started_at" >"$HOME_DIR/widget-data.json"
wait_for_text WIDGET_REFRESHED || fail "fallback refresh did not update the visible task row"
send_command /tasks
wait_for_absence WIDGET_REFRESHED || fail "second /tasks did not hide the live table"
calls_hidden=$(wc -l <"$HOME_DIR/task-widget-invocations" | tr -d ' ')
sleep 1.5
[ "$(wc -l <"$HOME_DIR/task-widget-invocations" | tr -d ' ')" = "$calls_hidden" ] \
  || fail "hidden task widget leaked its refresh timer"

send_command /reload
wait_for_text "Reloaded keybindings, extensions, skills, prompts, themes, and context files" \
  || fail "real Pi did not complete reload"
wait_for_absence WIDGET_REFRESHED || fail "task widget reopened after Pi reload"
calls_reloaded=$(wc -l <"$HOME_DIR/task-widget-invocations" | tr -d ' ')
sleep 1.5
[ "$(wc -l <"$HOME_DIR/task-widget-invocations" | tr -d ' ')" = "$calls_reloaded" ] \
  || fail "reloaded hidden widget leaked a process or timer"

herdr_version=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" status --json \
  | jq -r '.server.version // .client.version // "unknown"')
printf 'ok - real Pi %s in isolated Herdr %s toggled one live task widget, advanced elapsed time twice without transcript growth, refreshed task data, coexisted with Calm on and off, hid cleanly, and stayed hidden without work after reload\n' \
  "$(pi --version)" "$herdr_version"
