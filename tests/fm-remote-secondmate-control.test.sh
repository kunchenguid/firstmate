#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-control)
CODE="$TMP_ROOT/code"
REMOTE_HOME="$TMP_ROOT/home"
CONTROL_STATE="$REMOTE_HOME/state/parent-route"
WORLD="$TMP_ROOT/world"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
EVENTS="$TMP_ROOT/events.jsonl"
mkdir -p "$CODE" "$REMOTE_HOME/bin" "$REMOTE_HOME/config" "$REMOTE_HOME/data" "$CONTROL_STATE" "$WORLD" "$TMP_ROOT/user-home"
cp -R "$ROOT/bin" "$CODE/bin"
cp "$ROOT/AGENTS.md" "$REMOTE_HOME/AGENTS.md"
printf 'ios\n' > "$REMOTE_HOME/.fm-secondmate-home"
touch "$CONTROL_STATE/.last-watcher-beat" "$REMOTE_HOME/state/.last-watcher-beat"
: > "$EVENTS"

for command in fm-spawn.sh fm-control.sh fm-teardown.sh fm-update.sh; do
  cat > "$CODE/bin/$command" <<'SH'
#!/usr/bin/env bash
jq -nc --arg command "${0##*/}" --arg state "${FM_STATE_OVERRIDE:-}" --arg home "$FM_HOME" \
  '{command:$command,state:$state,home:$home}' >> "$FM_CONTROL_TEST_EVENTS"
case "${0##*/}" in
  fm-spawn.sh|fm-update.sh) printf 'fixture operation refused\n' >&2; exit 1 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$CODE/bin/$command"
done

cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
if [ "$*" = '-o lstart= -p 42' ]; then
  [ "$LC_ALL" = C ] && [ "$TZ" = UTC0 ] || exit 1
  printf 'Wed Mar 19 10:11:12 2025\n'
else
  exec "$FM_CONTROL_TEST_PS" "$@"
fi
SH
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
world=$FM_CONTROL_TEST_WORLD
case "${1:-} ${2:-}" in
  'status --json') printf '{"client":{"version":"0.9.3","protocol":22},"server":{"running":true}}\n' ;;
  'session list') printf '{"sessions":[{"name":"fm-remote","running":true,"socket_path":"%s/fm-remote.sock"}]}\n' "$world" ;;
  'pane get')
    if [ -e "$world/gone" ]; then
      printf '{"error":{"code":"pane_not_found"}}\n'
    else
      printf '{"result":{"pane":{"pane_id":"w1:p1","tab_id":"w1:t1","foreground_cwd":"%s/unrelated"}}}\n' "$world"
    fi
    ;;
  'tab get') printf '{"result":{"tab":{"tab_id":"w1:t1","label":"fm-ios"}}}\n' ;;
  'pane process-info') printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","shell_pid":42,"foreground_processes":[{"pid":43,"name":"claude","argv0":"claude","argv":["claude"]}]}}}\n' ;;
  'agent get')
    if [ -e "$world/no-agent" ]; then
      printf '{"error":{"code":"agent_not_found"}}\n'
    elif [ -e "$world/working" ]; then
      rm "$world/working"
      printf '{"result":{"agent":{"agent":"claude","agent_status":"working"}}}\n'
    else
      printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n'
    fi
    ;;
  'pane read') printf '%s\n' "$*" >> "$world/reads"; cat "$world/screen" ;;
  'pane send-text'|'pane run') printf '%s\n' "$*" >> "$world/writes" ;;
  'pane send-keys') printf '%s\n' "$*" >> "$world/writes"; touch "$world/working" ;;
  'pane close') printf '%s\n' "$*" >> "$world/closes"; touch "$world/gone" ;;
esac
SH
fm_fake_exit0 "$FAKEBIN" sleep
chmod +x "$FAKEBIN/ps" "$FAKEBIN/herdr"
REAL_PS=$(command -v ps)

write_route() {
  local path=$1 identity=$2
  fm_write_meta "$path" backend=herdr window=fm-remote:w1:p1 endpoint_task_id=ios \
    "worktree=$REMOTE_HOME" "project=$REMOTE_HOME" "home=$REMOTE_HOME" \
    kind=secondmate harness=claude model=default effort=default \
    herdr_session=fm-remote herdr_workspace_id=w1 herdr_tab_id=w1:t1 herdr_pane_id=w1:p1 \
    "herdr_process_identity=$identity"
}
run_control() {
  FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$CODE" FM_STATE_OVERRIDE="$REMOTE_HOME/state" \
    HOME="$TMP_ROOT/user-home" PATH="$FAKEBIN:$PATH" FM_CONTROL_TEST_PS="$REAL_PS" \
    FM_CONTROL_TEST_WORLD="$WORLD" FM_CONTROL_TEST_EVENTS="$EVENTS" \
    "$CODE/bin/fm-remote-secondmate-control.sh" "$@"
}
CURRENT='ps:42:Wed Mar 19 10:11:12 2025'
OLD='ps:42:Tue Mar 19 10:11:12 2024'
write_route "$CONTROL_STATE/ios.meta" "$CURRENT"
write_route "$REMOTE_HOME/state/ios.meta" "$OLD"
printf 'OWNED-SCREEN\n❯\n' > "$WORLD/screen"
[ "$(run_control state ios)" = alive ] || fail 'state did not consult the owning route record'
OUT=$(run_control launch ios claude - - herdr) || fail 'an already-live owned route was refused'
assert_contains "$OUT" 'target=fm-remote:w1:p1' 'launch did not return its existing owned route'
[ ! -s "$EVENTS" ] || fail 'launch replaced an already-live owned endpoint'
OUT=$(run_control capture ios) || fail 'owned capture failed'
assert_contains "$OUT" OWNED-SCREEN 'owned capture did not reach its pane'
[ "$(run_control observe ios)" = idle ] || fail 'owned observation failed'
run_control key ios Enter > "$TMP_ROOT/key.out" 2> "$TMP_ROOT/key.err" || fail "owned key failed: $(cat "$TMP_ROOT/key.err")"
[ -s "$WORLD/writes" ] || fail 'the key subprocess did not use the owning route context'
rm -f "$WORLD/working"
: > "$WORLD/writes"
run_control send ios 'owned request' > "$TMP_ROOT/send.out" 2> "$TMP_ROOT/send.err" || fail 'owned durable send failed'
[ -s "$WORLD/writes" ] || fail 'owned doorbell did not reach its pane'
pass 'owned remote state, launch, capture, observation, key and doorbell use parent-route records'

write_route "$CONTROL_STATE/ios.meta" "$OLD"
write_route "$REMOTE_HOME/state/ios.meta" "$CURRENT"
printf 'UNRELATED-SCREEN\n❯\n' > "$WORLD/screen"
: > "$WORLD/reads"; : > "$WORLD/writes"; : > "$WORLD/closes"; : > "$EVENTS"
rm -f "$WORLD/working"
[ "$(run_control state ios)" = missing ] || fail 'a stale remote route borrowed ordinary-home ownership'
[ -z "$(run_control capture ios)" ] || fail 'capture returned an unrelated pane screen'
[ "$(run_control observe ios)" = unknown ] || fail 'observation trusted an unrelated pane'
if run_control key ios C-c > "$TMP_ROOT/foreign-key.out" 2> "$TMP_ROOT/foreign-key.err"; then
  fail 'a stale route interrupted the unrelated pane'
fi
run_control send ios 'foreign request' > "$TMP_ROOT/foreign-send.out" 2> "$TMP_ROOT/foreign-send.err" || fail 'the stale-route steer was not durably retained'
if run_control launch ios claude - - herdr > "$TMP_ROOT/foreign-launch.out" 2> "$TMP_ROOT/foreign-launch.err"; then
  fail 'launch returned a stale live route instead of attempting recovery'
fi
jq -es 'any(.[]; .command=="fm-spawn.sh")' "$EVENTS" >/dev/null || fail 'stale launch never reached recovery'
[ ! -s "$WORLD/reads" ] && [ ! -s "$WORLD/writes" ] && [ ! -s "$WORLD/closes" ] || fail 'a stale route read, steered or closed the unrelated endpoint'
shopt -s nullglob
records=("$CONTROL_STATE/ios.inbox/"*.msg)
[ "${#records[@]}" -ge 2 ] || fail 'steers were not retained under the owning route state'
pass 'stale remote endpoints remain missing, unread and unsteered despite a matching ordinary-home record'

write_route "$CONTROL_STATE/ios.meta" "$CURRENT"
write_route "$REMOTE_HOME/state/ios.meta" "$OLD"
touch "$WORLD/no-agent"
: > "$EVENTS"
run_control launch ios claude - - herdr > "$TMP_ROOT/dead-launch.out" 2> "$TMP_ROOT/dead-launch.err" \
  && fail 'the fixture replacement should refuse after owned dead-endpoint cleanup'
[ -s "$WORLD/closes" ] || fail 'owned dead endpoint close consulted ordinary-home state'
rm -f "$WORLD/no-agent" "$WORLD/gone" "$WORLD/working"
run_control relaunch ios claude - - >/dev/null || fail 'relaunch delegation failed'
run_control retire ios --force >/dev/null 2> "$TMP_ROOT/retire.err" || fail 'retirement delegation failed'
if run_control update ios > "$TMP_ROOT/update.out" 2> "$TMP_ROOT/update.err"; then
  fail 'the fixture root update should refuse'
fi
jq -es --arg state "$CONTROL_STATE" --arg root_state "$CODE/state" '
  all(.[]; if .command=="fm-update.sh" then .state==$root_state else .state==$state end)
  and any(.[]; .command=="fm-control.sh")
  and any(.[]; .command=="fm-teardown.sh")
  and any(.[]; .command=="fm-update.sh")
' "$EVENTS" >/dev/null || fail 'a subprocess crossed the endpoint/code-root state boundary'
pass 'close, recovery, relaunch and retirement retain route state while code-root update uses root state'
