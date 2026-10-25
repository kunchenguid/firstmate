#!/usr/bin/env bash
# The supervisor-work guard end to end: install into a throwaway HOME, run the
# installed hook against fixture homes, a linked worktree and a worker session,
# then uninstall. Needs a Firstmate checkout (FM_CODE_ROOT) for the scope predicate
# and the shell lexer, and fails (not skips) without jq or node.
# shellcheck disable=SC2016 # single-quoted commands are literal payloads for the guard.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CK=${FM_CODE_ROOT:-}
[ -n "$CK" ] && [ -f "$CK/bin/fm-primary-scope-lib.sh" ] \
  || { echo "FAIL: set FM_CODE_ROOT to a Firstmate checkout"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node is required"; exit 1; }

TMP=$(mktemp -d)
on_exit() {
  rm -rf -- "$TMP"
}
trap on_exit EXIT
export HOME=$TMP/home XDG_DATA_HOME=$TMP/xdg
mkdir -p "$HOME" "$XDG_DATA_HOME"
DEST=$XDG_DATA_HOME/fm-supervisor-guard
HOOK=$DEST/fm-supervisor-work-pretool-check.sh
SETTINGS=$HOME/.claude/settings.json
FAILS=0

check() {
  if "$@"; then echo "PASS: $CHECK_NAME"; else echo "FAIL: $CHECK_NAME"; FAILS=$((FAILS + 1)); fi
}

# make_home <dir>: a fixture Firstmate home, a plain checkout with AGENTS.md, bin and
# state, and the checkout's scope lib and lexer linked in, as the real home has them.
make_home() {
  mkdir -p "$1/bin" "$1/state"
  git init -q "$1"
  : > "$1/AGENTS.md"
  ln -s "$CK/bin/fm-primary-scope-lib.sh" "$1/bin/fm-primary-scope-lib.sh"
  ln -s "$CK/bin/fm-arm-command-policy.mjs" "$1/bin/fm-arm-command-policy.mjs"
}

FMH=$(cd "$TMP" && pwd -P)/fmhome
make_home "$FMH"

# run_hook <command> <session-dir>: the installed hook on one Bash payload.
run_hook() {
  local payload
  payload=$(jq -nc --arg c "$1" --arg d "$2" '{tool_input: {command: $c}, cwd: $d}')
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$2" "$HOOK"
}

# expect <want-exit> <command> [session-dir] [deny-code]: exit status, empty stdout,
# and on deny the Claude decision object naming the code; on allow, empty stderr.
expect() {
  local want=$1 command=$2 session=${3:-$FMH} code=${4:-} rc=0
  run_hook "$command" "$session" >"$TMP/out" 2>"$TMP/err" || rc=$?
  [ "$rc" = "$want" ] || return 1
  [ ! -s "$TMP/out" ] || return 1
  if [ "$want" = 0 ]; then
    [ ! -s "$TMP/err" ]
  else
    jq -e --arg c "[$code]" '.systemMessage | startswith($c)' "$TMP/err" >/dev/null
  fi
}

CHECK_NAME="dry run writes nothing"
"$HERE/install.sh" --dry-run "$FMH" >/dev/null
check test ! -e "$SETTINGS" && check test ! -e "$DEST"

CHECK_NAME="install copies the guard and records the home"
"$HERE/install.sh" "$FMH" >/dev/null
check test -x "$HOOK" && check test "$(cat "$DEST/home")" = "$FMH"

CHECK_NAME="install registers one Bash PreToolUse hook"
check jq -e '[.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[] | select(.command | contains("fm-supervisor-work-pretool-check.sh"))] | length == 1' "$SETTINGS"

CHECK_NAME="reinstall is idempotent"
cp "$SETTINGS" "$TMP/settings.once"
"$HERE/install.sh" "$FMH" >/dev/null
check cmp -s "$SETTINGS" "$TMP/settings.once"

CHECK_NAME="primary session denies a no-mistakes run with exit 2 and stdout empty"
out=$(run_hook 'no-mistakes axi run --intent x' "$FMH" 2>"$TMP/err")
rc=$?
check test "$rc" = 2 && check test -z "$out" && check jq -e '.systemMessage | startswith("[supervisor-no-mistakes-run]")' "$TMP/err"

CHECK_NAME="a crew-owned run is refused however it is wrapped or backgrounded"
check expect 2 'no-mistakes axi respond --action fix --note ok' "$FMH" supervisor-no-mistakes-run
check expect 2 'cd ~/firstmate/work && no-mistakes axi respond --action fix' "$FMH" supervisor-no-mistakes-run
check expect 2 'sleep 110; no-mistakes axi run --wait' "$FMH" supervisor-no-mistakes-run
check expect 2 'timeout 1700 no-mistakes axi run --wait' "$FMH" supervisor-no-mistakes-run
check expect 2 'nohup no-mistakes axi respond --action fix &' "$FMH" supervisor-no-mistakes-run
check expect 2 'no-mistakes --json axi run' "$FMH" supervisor-no-mistakes-run

CHECK_NAME="reading a run record stays allowed in the primary session"
check expect 0 'no-mistakes axi status'
check expect 0 'no-mistakes axi status --json'

CHECK_NAME="a sleep of 60 seconds or less is allowed, a longer one is denied"
check expect 0 'sleep 30'
check expect 0 'sleep 60'
check expect 0 'sleep 1m'
check expect 2 'sleep 120' "$FMH" supervisor-poll-in-turn
check expect 2 'sleep 1m30s' "$FMH" supervisor-poll-in-turn
check expect 2 'sleep "$WAIT"' "$FMH" supervisor-poll-in-turn
check expect 2 "$(printf 'sle\\\nep 120')" "$FMH" supervisor-poll-in-turn

CHECK_NAME="a for, while or until loop whose body sleeps is denied"
check expect 2 'for i in $(seq 10); do sleep 5; no-mistakes axi status; done' "$FMH" supervisor-poll-in-turn
check expect 2 'while :; do sleep 5; done' "$FMH" supervisor-poll-in-turn
check expect 2 'until [ -f done ]; do sleep 30; done' "$FMH" supervisor-poll-in-turn
check expect 0 'for f in *.log; do wc -l "$f"; done'

CHECK_NAME="sleep inside quoted data is not a sleep"
check expect 0 "git commit -m 'never sleep 90 in a turn'"

CHECK_NAME="a malformed payload fails open with no output"
out=$(printf '%s' 'not json at all' | CLAUDE_PROJECT_DIR="$FMH" "$HOOK" 2>"$TMP/err")
rc=$?
check test "$rc" = 0 && check test -z "$out" && check test ! -s "$TMP/err"

CHECK_NAME="a linked worktree of the home is a worker and stays allowed"
git -C "$FMH" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$FMH" worktree add -q "$TMP/wt" -b wt-check
check expect 0 'no-mistakes axi run --intent x' "$TMP/wt"
check expect 0 'sleep 110' "$TMP/wt"

CHECK_NAME="a session outside the registered home stays allowed"
check expect 0 'sleep 120' "$TMP"

CHECK_NAME="a secondmate lead may not type into a pane, a primary may read one"
SECOND=$(cd "$TMP" && pwd -P)/secondmate
make_home "$SECOND"
printf 'sm-fixture\n' > "$SECOND/.fm-secondmate-home"
git -C "$SECOND" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
"$HERE/install.sh" "$SECOND" >/dev/null
check expect 2 'herdr pane send-text "yes"' "$SECOND" supervisor-pane-typing
check expect 2 'herdr pane send-keys Enter' "$SECOND" supervisor-pane-typing
check expect 2 'tmux send-keys -t worker Enter' "$SECOND" supervisor-pane-typing
check expect 2 'herdr pane send-text "go"; sleep 25; herdr pane send-keys Enter' "$SECOND" supervisor-pane-typing
check expect 0 'herdr pane capture' "$SECOND"
"$HERE/install.sh" "$FMH" >/dev/null

CHECK_NAME="removing one of two homes keeps the other guarded"
"$HERE/uninstall.sh" "$SECOND" >/dev/null
check test "$(cat "$DEST/home")" = "$FMH"
check expect 2 'no-mistakes axi run --intent x' "$FMH" supervisor-no-mistakes-run
check expect 0 'no-mistakes axi run --intent x' "$SECOND"
check expect 0 'no-mistakes axi run --intent x' "$TMP"

CHECK_NAME="uninstall removes the hook and the installed files"
"$HERE/uninstall.sh" >/dev/null
check jq -e '[.hooks.PreToolUse[]?.hooks[]?.command? | select(contains("fm-supervisor-work-pretool-check.sh"))] | length == 0' "$SETTINGS"
check test ! -e "$HOOK" && check test ! -e "$DEST/home"

CHECK_NAME="uninstall is idempotent"
"$HERE/uninstall.sh" >/dev/null
check test "$?" = 0

CHECK_NAME="uninstall leaves a settings file without this hook untouched"
printf '{"theme": "dark"}\n' > "$SETTINGS"
cp "$SETTINGS" "$TMP/settings.plain"
"$HERE/uninstall.sh" >/dev/null
check cmp -s "$SETTINGS" "$TMP/settings.plain"

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS check(s) failed"
  exit 1
fi
echo "all supervisor-work guard checks passed"
