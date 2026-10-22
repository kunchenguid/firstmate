#!/usr/bin/env bash
# tests/fm-rex-palette.test.sh - fake-rex-CLI tests for Firstmate's Rex
# command palette: the installer (bin/fm-rex-palette.sh) and the action
# runtime (bin/fm-rex-popup.sh plan and its popup bodies). A small fake `rex`
# answers `keymap`, `config check|reload`, `actions`, `ls`, `block inspect`,
# and `api call`, and logs every call; jq is real. The Lua module and the
# popups on a real server are covered by tests/fm-rex-palette-smoke.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the rex adapter)"; exit 0; }

unset TMUX TMUX_PANE HERDR_ENV REX_SESSION REX_BLOCK REX_SERVER REX_CLIENT REX_BIN_DIR FM_REX_SERVER 2>/dev/null || true

TMP_ROOT=$(fm_test_tmproot fm-rex-palette-tests)
export FM_BACKEND_REX_BUNDLE_BIN="$TMP_ROOT/no-bundled-rex"
FAKE="$TMP_ROOT/fake"
mkdir -p "$FAKE/bin" "$FAKE/inspect"
export FM_REX_FAKE="$FAKE"
export REX_BIN_DIR="$FAKE/bin"
export FM_REX_SERVER=unix:///tmp/fm-rex-palette-fake.sock

# Responses: config-path (keymap), check.exit, ls.json, inspect/<block>.json
# (absent -> exit 3), api-call.json; every call is logged to $FAKE/log.
cat >"$FAKE/bin/rex" <<'SH'
#!/usr/bin/env bash
set -u
F="${FM_REX_FAKE:?}"
printf '%s\n' "$*" >>"$F/log"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -S) shift 2 ;;
    --autostart=false) shift ;;
    *) break ;;
  esac
done
case "$1 ${2:-}" in
  "keymap --json") jq -nc --arg p "$(cat "$F/config-path")" '{config:{path:$p}}' ;;
  "config check")
    code=$(cat "$F/check.exit" 2>/dev/null || echo 0)
    [ "$code" = 0 ] || echo "error: bad config" >&2
    exit "$code"
    ;;
  "config reload") echo "generation: 2" ;;
  "actions --json") printf '{"actions":[{"name":"fm_fleet"},{"name":"captain_scratch"}]}\n' ;;
  "ls --json") cat "$F/ls.json" ;;
  "block inspect")
    f="$F/inspect/${3#block:}.json"
    [ -f "$f" ] || exit 3
    cat "$f"
    ;;
  "api call") cat "$F/api-call.json" 2>/dev/null || echo '{}' ;;
  *) echo "fake rex: unexpected $*" >&2; exit 1 ;;
esac
SH
chmod +x "$FAKE/bin/rex"

INSTALLER="$ROOT/bin/fm-rex-palette.sh"
POPUP="$ROOT/bin/fm-rex-popup.sh"
CFG_DIR="$TMP_ROOT/rexcfg"
CFG="$CFG_DIR/init.lua"
mkdir -p "$CFG_DIR"
printf '%s' "$CFG" >"$FAKE/config-path"
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/state" "$FM_HOME/data" "$FM_HOME/config"

file_mode() { case "$(uname -s)" in Darwin) stat -f '%Lp' "$1" ;; *) stat -c '%a' "$1" ;; esac; }
backups() { find "$CFG_DIR" -name 'init.lua.fm-backup.*' | wc -l | tr -d ' '; }

# --- installer -----------------------------------------------------------------

out=$("$INSTALLER" install 2>&1) || fail "install into an absent config failed: $out"
[ -f "$CFG" ] || fail "install did not create the absent config"
assert_equals "-- >>> firstmate palette >>>" "$(head -1 "$CFG")" "the created config starts with the begin marker"
assert_contains "$(cat "$CFG")" "-- firstmate created this file" "a created config carries the created marker"
assert_contains "$(cat "$CFG")" "home = \"$FM_HOME\"" "the block records FM_HOME"
assert_contains "$(cat "$CFG")" "server = \"$FM_REX_SERVER\"" "the block records an explicitly chosen server"
assert_contains "$(cat "$FAKE/log")" "config reload" "install reloads the server config"
"$INSTALLER" uninstall >/dev/null 2>&1 || fail "uninstall of a created config failed"
[ ! -e "$CFG" ] || fail "uninstall left a config that only Firstmate had created"
pass "install creates an absent config with a created marker, and uninstall deletes it again"

out=$(FM_REX_SERVER='' REX_SERVER=unix:///tmp/fm-rex-palette-pane.sock "$INSTALLER" install 2>&1) || fail "install from a Rex pane failed: $out"
assert_contains "$(cat "$CFG")" 'server = "unix:///tmp/fm-rex-palette-pane.sock"' "the block records the pane's REX_SERVER"
FM_REX_SERVER='' REX_SERVER=unix:///tmp/fm-rex-palette-pane.sock "$INSTALLER" uninstall >/dev/null 2>&1 || fail "uninstall from a Rex pane failed"
pass "install from a Rex pane records that pane's server"

# The captain's own file, without a trailing newline.
rm -f "$CFG_DIR"/init.lua.fm-backup.*
printf -- '-- captain\nrex.bind("cmd+d", "pane.split", { direction = "right" })\nrex.action{ name = "mine", title = "Mine", run = function() end }' >"$CFG"
chmod 640 "$CFG"
cp "$CFG" "$TMP_ROOT/orig.lua"
: >"$FAKE/log"
"$INSTALLER" install >/dev/null 2>&1 || fail "install into the captain's config failed"
assert_equals "-- >>> firstmate palette >>>" "$(head -1 "$CFG")" "the block goes at the top so the captain's later lines win"
end_line=$(grep -n -x -F -- '-- <<< firstmate palette <<<' "$CFG" | cut -d: -f1)
tail -n +$((end_line + 1)) "$CFG" | cmp -s - "$TMP_ROOT/orig.lua" || fail "the captain's lines changed under the block"
assert_not_contains "$(cat "$CFG")" "firstmate created this file" "an existing config carries no created marker"
assert_equals 640 "$(file_mode "$CFG")" "install keeps the config's permission bits"
assert_equals 1 "$(backups)" "install backs up the captain's config"
cmp -s "$(find "$CFG_DIR" -name 'init.lua.fm-backup.*' | head -1)" "$TMP_ROOT/orig.lua" || fail "the backup is not the captain's original file"
pass "install puts the block on top, keeps the captain's lines and mode, and backs the file up"

: >"$FAKE/log"
out=$("$INSTALLER" install 2>&1) || fail "a second install failed"
assert_contains "$out" "unchanged" "a second install reports nothing to change"
assert_equals 1 "$(backups)" "an unchanged install writes no second backup"
assert_contains "$(cat "$FAKE/log")" "config reload" "an unchanged install still reloads, so a rerun after a failed reload loads the block"
[ "$(grep -c -x -F -- '-- >>> firstmate palette >>>' "$CFG")" = 1 ] || fail "a second install duplicated the block"
pass "install is idempotent and reloads even when the file is unchanged"

"$INSTALLER" uninstall >/dev/null 2>&1 || fail "uninstall failed"
cmp -s "$CFG" "$TMP_ROOT/orig.lua" || fail "uninstall did not restore the captain's file byte for byte"
out=$("$INSTALLER" uninstall 2>&1) || fail "uninstall without a block failed"
assert_contains "$out" "not installed" "uninstall without a block reports it"
pass "uninstall restores the captain's file byte for byte"

# A block the captain moved down is replaced where it is.
"$INSTALLER" install >/dev/null 2>&1 || fail "reinstall failed"
{ printf -- '-- moved\n'; cat "$CFG"; } >"$TMP_ROOT/moved.lua"
cp "$TMP_ROOT/moved.lua" "$CFG"
"$INSTALLER" install >/dev/null 2>&1 || fail "install over a moved block failed"
assert_equals "-- moved" "$(head -1 "$CFG")" "install keeps a moved block where the captain put it"
"$INSTALLER" uninstall >/dev/null 2>&1 || fail "uninstall of a moved block failed"
{ printf -- '-- moved\n'; cat "$TMP_ROOT/orig.lua"; } | cmp -s - "$CFG" || fail "uninstall of a moved block changed other lines"
cp "$TMP_ROOT/orig.lua" "$CFG"
pass "install and uninstall handle a block the captain moved"

# Refusals leave the file untouched.
{ printf -- '-- >>> firstmate palette >>>\n'; cat "$TMP_ROOT/orig.lua"; } >"$CFG"
cp "$CFG" "$TMP_ROOT/unbalanced.lua"
n=$(backups)
if out=$("$INSTALLER" install 2>&1); then fail "install accepted an unbalanced marker"; fi
assert_contains "$out" "1 begin and 0 end" "the refusal names the unbalanced markers"
cmp -s "$CFG" "$TMP_ROOT/unbalanced.lua" || fail "a refused install changed the file"
if "$INSTALLER" uninstall >/dev/null 2>&1; then fail "uninstall accepted an unbalanced marker"; fi
cmp -s "$CFG" "$TMP_ROOT/unbalanced.lua" || fail "a refused uninstall changed the file"
assert_equals "$n" "$(backups)" "a refusal writes no backup"
cp "$TMP_ROOT/orig.lua" "$CFG"
echo 1 >"$FAKE/check.exit"
if out=$("$INSTALLER" install 2>&1); then fail "install proceeded past a failing config check"; fi
assert_contains "$out" "config check failed" "a failing check is reported"
cmp -s "$CFG" "$TMP_ROOT/orig.lua" || fail "a failing check still changed the file"
[ -z "$(find "$CFG_DIR" -name '.init.lua.fm-palette.*')" ] || fail "a failing check left its temp file"
rm -f "$FAKE/check.exit"
if out=$(FM_REX_SERVER=https://ds9.example.ts.net "$INSTALLER" install 2>&1); then fail "install accepted a remote server"; fi
assert_contains "$out" "only on this machine's own Rex server" "a remote server is refused"
pass "unbalanced markers, a failing config check, and a remote server are refused without writing"

# A symlinked config is edited at its target.
mkdir -p "$TMP_ROOT/dotfiles"
cp "$TMP_ROOT/orig.lua" "$TMP_ROOT/dotfiles/init.lua"
rm -f "$CFG"
ln -s "$TMP_ROOT/dotfiles/init.lua" "$CFG"
"$INSTALLER" install >/dev/null 2>&1 || fail "install through a symlink failed"
[ -L "$CFG" ] || fail "install replaced the symlink with a file"
assert_equals "-- >>> firstmate palette >>>" "$(head -1 "$TMP_ROOT/dotfiles/init.lua")" "install edits the symlink's target"
"$INSTALLER" uninstall >/dev/null 2>&1 || fail "uninstall through a symlink failed"
cmp -s "$TMP_ROOT/dotfiles/init.lua" "$TMP_ROOT/orig.lua" || fail "uninstall through a symlink did not restore the target"
rm -f "$CFG"
pass "a symlinked config is edited at its target and the link survives"

# --- plan --------------------------------------------------------------------------

STATE="$FM_HOME/state"
LSID=01a16300-0000-7000-8000-00000000000a
LBID=01a16300-0000-7000-8000-00000000000b
LWID=01a16300-0000-7000-8000-00000000000c
MSID=01a16300-0000-7000-8000-0000000000d1
MBID=01a16300-0000-7000-8000-0000000000d2
FMLOCAL=01a16300-0000-7000-8000-0000000000e1
now=$(date +%s)
printf 'window=%s:%s\nbackend=rex\nkind=ship\nproject=demo\nrex_server=%s\nrex_session_id=%s\nrex_window_id=%s\nrex_block_id=%s\npr=https://github.com/o/r/pull/9\n' \
  "$LSID" "$LBID" "$FM_REX_SERVER" "$LSID" "$LWID" "$LBID" >"$STATE/demo.meta"
printf 'working [at=%s]: started\n' "$now" >"$STATE/demo.status"
printf 'window=remote:mate1\nkind=secondmate\nremote_host=ds9\nremote_backend=rex\nremote_target=%s:%s\n' "$MSID" "$MBID" >"$STATE/mate1.meta"
jq -nc --arg s "session:$FMLOCAL" '{sessions:[{session_id:"session:other",label:"captain"},{session_id:$s,label:"fm-local"}]}' >"$FAKE/ls.json"

out=$("$POPUP" plan this --session "session:$LSID" --block "block:$LBID") || fail "plan this on a worker pane failed"
assert_equals demo "$(printf '%s' "$out" | jq -r .task)" "a local pane resolves to its task"
assert_equals "session:$LSID" "$(printf '%s' "$out" | jq -r .layer.session_id)" "a local popup opens in the focused session"
assert_equals "this demo" "$(printf '%s' "$out" | jq -r '.layer.command[-2:] | join(" ")')" "the popup runs the this body for the task"
assert_equals "FM_HOME=$FM_HOME" "$(printf '%s' "$out" | jq -r '.layer.command[] | select(startswith("FM_HOME="))')" "the popup carries FM_HOME"
assert_equals null "$(printf '%s' "$out" | jq -c .select)" "a local popup does not move the view"
if out=$("$POPUP" plan peek --session "session:$LSID" --block block:01a16300-0000-7000-8000-0000000000ff 2>&1); then
  fail "plan peek accepted a pane that is no worker"
fi
assert_contains "$out" "not a Firstmate worker" "a foreign pane is refused with a reason"
out=$("$POPUP" plan note --session "session:$LSID" --block block:01a16300-0000-7000-8000-0000000000ff) || fail "plan note on a foreign pane failed"
assert_equals "note" "$(printf '%s' "$out" | jq -r '.layer.command[-1]')" "a note from a foreign pane names no task"
pass "plan resolves a local pane to its task and opens the popup in place"

out=$("$POPUP" plan this --server ds9 --session "session:$MSID" --block "block:$MBID") || fail "plan this on a remote mate pane failed"
assert_equals "mate1 remote-mate" "$(printf '%s' "$out" | jq -r '"\(.task) \(.pane)"')" "a remote second mate's own pane resolves to it"
assert_equals "session:$FMLOCAL" "$(printf '%s' "$out" | jq -r .layer.session_id)" "a remote pane's popup opens in the local fm-local session"
assert_equals "session:$FMLOCAL" "$(printf '%s' "$out" | jq -r .select.session_id)" "the app is asked to show that local session"
out=$("$POPUP" plan answer --server ds9 --session "session:$MSID" --block block:01a16300-0000-7000-8000-0000000000d9) || fail "plan answer on a remote worker pane failed"
assert_equals "mate1 remote-worker" "$(printf '%s' "$out" | jq -r '"\(.task) \(.pane)"')" "a pane in the second mate's session resolves to the second mate"
assert_equals "answer mate1" "$(printf '%s' "$out" | jq -r '.layer.command[-2:] | join(" ")')" "the answer popup names the second mate"
if out=$("$POPUP" plan this --server ds9 --session session:01a16300-0000-7000-8000-0000000000f0 --block "block:$LBID" 2>&1); then
  fail "a pane on another host matched a local task's block id"
fi
jq -nc '{sessions:[]}' >"$FAKE/ls.json"
if out=$("$POPUP" plan this --server ds9 --session "session:$MSID" --block "block:$MBID" 2>&1); then
  fail "a remote pane's popup opened without a local fm-local session"
fi
assert_contains "$out" "fm-local" "the refusal names the missing local session"
pass "plan resolves panes on another host to their second mate and shows popups on this machine"

# goto: a decision outranks a blocker, which outranks a done PR.
for t in alpha bravo charlie; do
  printf 'window=%s:%s\nbackend=rex\nkind=ship\nrex_session_id=%s\nrex_window_id=%s\nrex_block_id=%s\n' \
    "$LSID" "$LBID" "$LSID" "$LWID" "$LBID" >"$STATE/$t.meta"
done
printf 'done [at=%s]: PR https://github.com/o/r/pull/1 checks green\n' "$now" >"$STATE/alpha.status"
printf 'blocked [at=%s]: tests hang\n' "$now" >"$STATE/bravo.status"
printf 'needs-decision [at=%s] [key=db]: which db?\n' "$now" >"$STATE/charlie.status"
jq -nc --arg w "window:$LWID" '{block:{placement:"placed", window_id:$w}}' >"$FAKE/inspect/$LBID.json"
out=$("$POPUP" plan goto) || fail "plan goto failed"
assert_equals charlie "$(printf '%s' "$out" | jq -r .task)" "goto picks the worker waiting on a decision first"
assert_equals "session:$LSID window:$LWID" "$(printf '%s' "$out" | jq -r '"\(.select.session_id) \(.select.window_id)"')" "goto selects the task's session and live window"
rm -f "$STATE/charlie.status"
assert_equals bravo "$("$POPUP" plan goto | jq -r .task)" "goto picks a blocker before a done PR"
jq -nc --arg s "session:$FMLOCAL" '{sessions:[{session_id:$s,label:"fm-local"}]}' >"$FAKE/ls.json"
out=$("$POPUP" plan goto --task mate1) || fail "plan goto --task on a remote mate failed"
assert_equals "session:$FMLOCAL" "$(printf '%s' "$out" | jq -r .select.session_id)" "goto shows the local fm-local session for a remote second mate, never another host's session id"
assert_contains "$(printf '%s' "$out" | jq -r .message)" "another host" "goto says the second mate runs on another host"
rm -f "$STATE/alpha.status" "$STATE/bravo.status"
if out=$("$POPUP" plan goto 2>&1); then fail "goto succeeded with nobody waiting"; fi
assert_contains "$out" "no worker is waiting" "goto reports that nobody waits"
rm -f "$STATE/alpha.meta" "$STATE/bravo.meta" "$STATE/charlie.meta"
pass "goto ranks waiting workers and selects their tab"

# away: toggle by the recorded block's placement; never closes it.
ASID=01a16300-0000-7000-8000-0000000000a1
ABID=01a16300-0000-7000-8000-0000000000a2
printf 'rex\t%s:%s\t%s\n' "$ASID" "$ABID" "$FM_REX_SERVER" >"$STATE/.afk-daemon-terminal"
jq -nc '{block:{placement:"detached"}}' >"$FAKE/inspect/$ABID.json"
: >"$FAKE/log"
out=$("$POPUP" plan away --session "session:$ASID" --block "block:$LBID") || fail "plan away (show) failed"
assert_equals shown "$(printf '%s' "$out" | jq -r .away)" "a hidden away pane is shown"
assert_contains "$(cat "$FAKE/log")" "session.move_block" "showing moves the block into the layout"
assert_contains "$(cat "$FAKE/log")" "\"anchor_block_id\":\"block:$LBID\"" "the away pane is shown beside the focused pane"
assert_equals null "$(printf '%s' "$out" | jq -c .select)" "showing in the focused session does not move the view"
jq -nc '{block:{placement:"placed"}}' >"$FAKE/inspect/$ABID.json"
: >"$FAKE/log"
out=$("$POPUP" plan away --session "session:$ASID" --block "block:$LBID") || fail "plan away (hide) failed"
assert_equals hidden "$(printf '%s' "$out" | jq -r .away)" "a shown away pane is hidden"
assert_contains "$(cat "$FAKE/log")" "session.detach_block" "hiding detaches the block"
assert_not_contains "$(cat "$FAKE/log")" "close" "hiding never closes the away pane"
rm -f "$STATE/.afk-daemon-terminal"
if out=$("$POPUP" plan away --session "session:$ASID" 2>&1); then fail "away succeeded without an away record"; fi
assert_contains "$out" "away mode is not running" "away without a record says so"
pass "away shows and hides the recorded away pane without closing it"

# --- popup bodies --------------------------------------------------------------

printf 'needs-decision [at=%s] [key=pick-db]: Postgres (A) or SQLite (B)?\n' "$now" >"$STATE/demo.status"
notes() { cat "$STATE"/inbox/*.note 2>/dev/null; }
out=$(printf '1\nB, SQLite is fine\n\n' | "$POPUP" answer demo 2>&1) || fail "the answer body failed: $out"
assert_contains "$(notes)" "Answer for demo [key=pick-db]: B, SQLite is fine" "an answer files a keyed inbox note"
assert_contains "$(notes)" "request_id=rex-palette-" "an answer note carries a request id"
rm -rf "$STATE/inbox"
out=$(printf '\n' | "$POPUP" answer demo 2>&1) || fail "a cancelled answer failed"
[ -z "$(notes)" ] || fail "a cancelled answer filed a note"
out=$(printf 'please rebase first\n\n' | "$POPUP" note demo 2>&1) || fail "the note body failed"
assert_contains "$(notes)" "About demo: please rebase first" "a note about a task names it"
rm -rf "$STATE/inbox"
out=$(printf '1\nn\n' | "$POPUP" merge demo 2>&1) || fail "a declined merge request failed"
[ -z "$(notes)" ] || fail "a declined merge request filed a note"
out=$(printf '1\ny\n\n' | "$POPUP" merge demo 2>&1) || fail "the merge body failed"
assert_contains "$(notes)" "Merge request: https://github.com/o/r/pull/9 (task demo)" "a merge request files a note with the PR URL"
pass "the answer, note, and merge popups only file captain inbox notes"

out=$(printf '\n' | "$POPUP" this mate1 2>&1) || fail "the this body failed: $out"
assert_contains "$out" "Task:      mate1 (secondmate)" "a task without a project names only its kind"
assert_contains "$out" "Latest:    no status yet" "a task without a status line says so"
pass "the this popup omits the project and names a missing status for a task without them"
