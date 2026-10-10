#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-orca-typed-restart)

for mode in restart healthy healthy-retry; do
  fixture="$TMP_ROOT/$mode"
  mkdir -p "$fixture/fakebin" "$fixture/root/bin" "$fixture/state" "$fixture/worktree"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/root/bin/fm-guard.sh"
  chmod +x "$fixture/root/bin/fm-guard.sh"
  printf 'window=fm-typed\nendpoint_task_id=typed\nterminal=old\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nbackend=orca\n' \
    "$fixture/worktree" "$fixture/worktree" > "$fixture/state/typed.meta"
  : > "$fixture/composer"
  cat > "$fixture/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "$1" = 1.2 ] && [ "$FM_ORCA_TYPED_MODE" = restart ]; then
  : > "$FM_ORCA_TYPED_FIXTURE/restarted"
  : > "$FM_ORCA_TYPED_FIXTURE/composer"
fi
SH
  cat > "$fixture/fakebin/orca" <<'JS'
#!/usr/bin/env node
const fs = require('fs');
const dir = process.env.FM_ORCA_TYPED_FIXTURE;
const mode = process.env.FM_ORCA_TYPED_MODE;
const args = process.argv.slice(2);
const terminal = args[args.indexOf('--terminal') + 1];
const reply = result => console.log(JSON.stringify({ok: true, result}));
fs.appendFileSync(dir + '/calls', JSON.stringify(args) + '\n');
if (args[0] === 'status') {
  reply({runtime: {reachable: true, state: 'ready'}});
} else if (args[1] === 'list') {
  reply({terminals: [{handle: 'live', connected: true, writable: true}], truncated: false});
} else if (args[1] === 'read') {
  const body = terminal === 'live' ? '' : fs.readFileSync(dir + '/composer', 'utf8');
  const rule = '─'.repeat(body.length + 4);
  reply({terminal: {tail: ['╭' + rule + '╮', '│ > ' + body + ' │', '╰' + rule + '╯']}});
} else if (args[1] === 'send') {
  if (args.includes('--enter')) {
    fs.appendFileSync(dir + '/enters', terminal + '\n');
    if (terminal === 'old' && fs.existsSync(dir + '/restarted')) {
      console.log(JSON.stringify({ok: false, error: {code: 'terminal_handle_stale'}}));
      process.exitCode = 1;
    } else {
      if (mode === 'healthy-retry' && !fs.existsSync(dir + '/swallowed')) {
        fs.writeFileSync(dir + '/swallowed', '1');
      } else {
        fs.writeFileSync(dir + '/submitted', fs.readFileSync(dir + '/composer', 'utf8'));
        fs.writeFileSync(dir + '/composer', '');
      }
      reply({send: {accepted: true}});
    }
  } else {
    const text = args[args.indexOf('--text') + 1];
    fs.appendFileSync(dir + '/typed', text + '\n');
    fs.appendFileSync(dir + '/composer', text);
    reply({send: {accepted: true}});
  }
} else {
  reply({terminal: {handle: terminal, connected: true, writable: true}});
}
JS
  chmod +x "$fixture/fakebin/orca" "$fixture/fakebin/sleep"
  rc=0
  PATH="$fixture/fakebin:$PATH" FM_ORCA_TYPED_FIXTURE="$fixture" FM_ORCA_TYPED_MODE="$mode" \
    FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture/root" FM_STATE_OVERRIDE="$fixture/state" \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    bash "$ROOT/bin/fm-send.sh" typed /status > "$fixture/out" 2>&1 || rc=$?
  [ "$(cat "$fixture/typed")" = /status ] || fail "$mode: slash command was retyped"
  if [ "$mode" = restart ]; then
    [ "$rc" = 3 ] || fail "restart: expected unconfirmed exit 3, got $rc: $(cat "$fixture/out")"
    assert_contains "$(cat "$fixture/out")" "changed terminal endpoints" "restart did not explain the unconfirmed send"
    assert_contains "$(cat "$fixture/out")" "fm-peek.sh" "restart did not provide an inspection action"
    [ "$(cat "$fixture/enters")" = $'old\nlive' ] || fail "restart: Enter retried after endpoint change"
    [ ! -s "$fixture/submitted" ] || fail "restart unexpectedly submitted the lost command"
  else
    [ "$rc" = 0 ] || fail "$mode: original endpoint send failed: $(cat "$fixture/out")"
    [ "$(cat "$fixture/submitted")" = /status ] || fail "$mode: slash command was not submitted"
    expected=old
    [ "$mode" != healthy-retry ] || expected=$'old\nold'
    [ "$(cat "$fixture/enters")" = "$expected" ] || fail "$mode: original Enter budget changed"
  fi
done
pass "Typed Orca endpoint changes are unconfirmed without retyping or further Enter"
