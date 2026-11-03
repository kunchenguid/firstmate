#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-orca-typed-restart)

for mode in restart restart-failure restart-dialog healthy healthy-retry enter-failure enter-failure-submitted replacement-failure replacement-pending replacement-healthy; do
  fixture="$TMP_ROOT/$mode"
  mkdir -p "$fixture/fakebin" "$fixture/root/bin" "$fixture/state" "$fixture/worktree"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/root/bin/fm-guard.sh"
  chmod +x "$fixture/root/bin/fm-guard.sh"
  printf 'window=fm-typed\nendpoint_task_id=typed\nterminal=old\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nbackend=orca\n' \
    "$fixture/worktree" "$fixture/worktree" > "$fixture/state/typed.meta"
  : > "$fixture/composer"
  cat > "$fixture/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "$1" = 1.2 ] && [[ "$FM_ORCA_TYPED_MODE" = restart* ]]; then
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
  if (terminal === 'live' && mode === 'restart-dialog') {
    reply({terminal: {tail: ['Background work is running', '❯ 1. Exit and stop tasks', 'Enter to confirm · Esc to cancel']}});
    process.exit(0);
  }
  const body = terminal === 'live' && mode === 'restart' ? '' : fs.readFileSync(dir + '/composer', 'utf8');
  const rule = '─'.repeat(body.length + 4);
  reply({terminal: {tail: ['╭' + rule + '╮', '│ > ' + body + ' │', '╰' + rule + '╯']}});
} else if (args[1] === 'send') {
  if (args.includes('--enter')) {
    fs.appendFileSync(dir + '/enters', terminal + '\n');
    if (mode === 'enter-failure-submitted') {
      // The keystroke reached the pane before the runtime reported the error,
      // so the command ran and the composer is empty.
      fs.writeFileSync(dir + '/submitted', fs.readFileSync(dir + '/composer', 'utf8'));
      fs.writeFileSync(dir + '/composer', '');
      console.log(JSON.stringify({ok: false, error: {code: 'send_failed', message: 'temporary runtime error'}}));
      process.exitCode = 1;
    } else if (mode === 'enter-failure' || mode === 'replacement-failure' || (mode === 'restart-failure' && terminal === 'live')) {
      console.log(JSON.stringify({ok: false, error: {code: 'send_failed', message: 'temporary runtime error'}}));
      process.exitCode = 1;
    } else if (terminal === 'old' && fs.existsSync(dir + '/restarted')) {
      console.log(JSON.stringify({ok: false, error: {code: 'terminal_handle_stale'}}));
      process.exitCode = 1;
    } else {
      if (mode === 'replacement-pending' || (mode === 'healthy-retry' && !fs.existsSync(dir + '/swallowed'))) {
        fs.writeFileSync(dir + '/swallowed', '1');
      } else {
        fs.writeFileSync(dir + '/submitted', fs.readFileSync(dir + '/composer', 'utf8'));
        fs.writeFileSync(dir + '/composer', '');
      }
      reply({send: {accepted: true}});
    }
  } else {
    if (mode.startsWith('replacement-') && terminal === 'old') {
      console.log(JSON.stringify({ok: false, error: {code: 'terminal_handle_stale'}}));
      process.exit(1);
    }
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
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=2 \
    bash "$ROOT/bin/fm-send.sh" typed /status > "$fixture/out" 2>&1 || rc=$?
  [ "$(cat "$fixture/typed")" = /status ] || fail "$mode: slash command was retyped"
  if [[ "$mode" = restart* ]]; then
    [ "$rc" = 3 ] || fail "restart: expected unconfirmed exit 3, got $rc: $(cat "$fixture/out")"
    assert_contains "$(cat "$fixture/out")" "changed terminal endpoints" "restart did not explain the unconfirmed send"
    assert_contains "$(cat "$fixture/out")" "inspect the replacement pane for the recorded worktree in Orca's UI" "restart did not provide a usable inspection action"
    assert_not_contains "$(cat "$fixture/out")" "fm-peek.sh" "restart directed inspection to the stale recorded endpoint"
    expected=$'old\nlive'
    [ "$mode" != restart-dialog ] || expected=old
    [ "$(cat "$fixture/enters")" = "$expected" ] || fail "$mode: unexpected Enter attempts"
    [ ! -s "$fixture/submitted" ] || fail "restart unexpectedly submitted the lost command"
  elif [ "$mode" = replacement-failure ] || [ "$mode" = replacement-pending ]; then
    [ "$rc" = 3 ] || fail "$mode: expected unconfirmed exit 3, got $rc: $(cat "$fixture/out")"
    assert_contains "$(cat "$fixture/out")" "inspect the replacement pane for the recorded worktree in Orca's UI" "$mode: missing usable inspection action"
    assert_not_contains "$(cat "$fixture/out")" "fm-peek.sh" "$mode: inspection uses stale endpoint"
    [ "$(cat "$fixture/composer")" = /status ] || fail "$mode: accepted text lost"
    expected=live
    [ "$mode" != replacement-pending ] || expected=$'live\nlive'
    [ "$(cat "$fixture/enters")" = "$expected" ] || fail "$mode: unexpected Enter attempts"
  elif [ "$mode" = enter-failure ]; then
    [ "$rc" = 3 ] || fail "enter-failure: expected unconfirmed exit 3, got $rc: $(cat "$fixture/out")"
    assert_contains "$(cat "$fixture/out")" "submission is unconfirmed" "enter-failure did not report the failed Enter as unconfirmed"
    assert_contains "$(cat "$fixture/out")" "do not retype or blindly resend" "enter-failure invited a duplicate send"
    assert_not_contains "$(cat "$fixture/out")" "text not sent" "enter-failure claimed the accepted text was not sent"
    [ "$(cat "$fixture/enters")" = old ] || fail "enter-failure: Enter was retried after a non-stale failure"
    assert_contains "$(cat "$fixture/out")" "fm-peek.sh" "original endpoint lost inspection guidance"
    [ ! -s "$fixture/submitted" ] || fail "enter-failure unexpectedly submitted the command"
  elif [ "$mode" = enter-failure-submitted ]; then
    # The Enter reported failure, but the read proves the text left the pane:
    # that is a delivered submit, and retrying it would double-send.
    [ "$rc" = 0 ] || fail "enter-failure-submitted: expected delivered exit 0, got $rc: $(cat "$fixture/out")"
    [ "$(cat "$fixture/submitted")" = /status ] || fail "enter-failure-submitted: command was not recorded as submitted"
    [ "$(cat "$fixture/enters")" = old ] || fail "enter-failure-submitted: Enter was retried after a non-stale failure"
    [ ! -s "$fixture/composer" ] || fail "enter-failure-submitted: composer did not clear"
    assert_not_contains "$(cat "$fixture/out")" "text not sent" "enter-failure-submitted claimed the accepted text was not sent"
  else
    [ "$rc" = 0 ] || fail "$mode: original endpoint send failed: $(cat "$fixture/out")"
    [ "$(cat "$fixture/submitted")" = /status ] || fail "$mode: slash command was not submitted"
    expected=old
    [ "$mode" != replacement-healthy ] || expected=live
    [ "$mode" != healthy-retry ] || expected=$'old\nold'
    [ "$(cat "$fixture/enters")" = "$expected" ] || fail "$mode: original Enter budget changed"
  fi
done
pass "Typed Orca endpoint changes and failed Enters are unconfirmed without retyping or further Enter"
