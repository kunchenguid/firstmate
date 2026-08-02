#!/usr/bin/env bash
# Behavior tests for the Claude long-turn watcher-continuity PreToolUse gate.
# shellcheck disable=SC1091,SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-continuity-pretool-check.sh"
POLICY="$ROOT/bin/fm-continuity-command-policy.mjs"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-continuity-pretool.XXXXXX")
TMP_ROOT=$(CDPATH='' cd -- "$TMP_ROOT" && pwd -P)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
WATCH_PID=

cleanup() {
	[ -z "$WATCH_PID" ] || kill "$WATCH_PID" 2>/dev/null || true
	fm_test_cleanup
}
trap cleanup EXIT

make_primary() {
	mkdir -p "$PRIMARY/bin" "$STATE"
	git init -q "$PRIMARY"
	printf '# fixture\n' >"$PRIMARY/AGENTS.md"
	cp "$CHECK" "$POLICY" \
		"$ROOT/bin/fm-arm-command-policy.mjs" \
		"$ROOT/bin/fm-supervision-lib.sh" \
		"$ROOT/bin/fm-primary-scope-lib.sh" \
		"$ROOT/bin/fm-wake-lib.sh" \
		"$PRIMARY/bin/"
	: >"$PRIMARY/bin/fm-watch.sh"
	chmod +x "$PRIMARY/bin/fm-continuity-pretool-check.sh" "$PRIMARY/bin/fm-continuity-command-policy.mjs"
}

run_check() {
	local command=$1 rc=0
	shift
	: >"$OUT"
	: >"$ERR"
	env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" "$@" \
		"$PRIMARY/bin/fm-continuity-pretool-check.sh" --command "$command" >"$OUT" 2>"$ERR" || rc=$?
	return "$rc"
}

expect_allow() {
	local label=$1 command=$2 rc=0
	shift 2
	run_check "$command" "$@" || rc=$?
	[ "$rc" -eq 0 ] || fail "$label must allow, got exit $rc: $(cat "$ERR")"
	[ ! -s "$OUT" ] || fail "$label allow wrote stdout: $(cat "$OUT")"
	[ ! -s "$ERR" ] || fail "$label allow wrote stderr: $(cat "$ERR")"
}

expect_deny() {
	local label=$1 command=$2 code=${3:-} rc=0
	run_check "$command" || rc=$?
	[ "$rc" -eq 2 ] || fail "$label must deny with exit 2, got $rc"
	[ ! -s "$OUT" ] || fail "$label deny wrote stdout: $(cat "$OUT")"
	jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 ||
		fail "$label deny omitted Claude's permission decision: $(cat "$ERR")"
	if [ -n "$code" ]; then
		jq -e --arg code "$code" '.systemMessage | startswith("[watcher-continuity]") and contains($code)' "$ERR" >/dev/null 2>&1 ||
			fail "$label deny omitted '$code': $(cat "$ERR")"
	fi
}

record_healthy_watcher() {
	local identity
	sleep 60 &
	WATCH_PID=$!
	# shellcheck source=bin/fm-wake-lib.sh
	. "$PRIMARY/bin/fm-wake-lib.sh"
	identity=$(fm_pid_identity "$WATCH_PID") || fail "fixture watcher identity could not be read"
	mkdir -p "$STATE/.watch.lock"
	printf '%s\n' "$WATCH_PID" >"$STATE/.watch.lock/pid"
	printf '%s\n' "$PRIMARY" >"$STATE/.watch.lock/fm-home"
	printf '%s\n' "$PRIMARY/bin/fm-watch.sh" >"$STATE/.watch.lock/watcher-path"
	printf '%s\n' "$identity" >"$STATE/.watch.lock/pid-identity"
	: >"$STATE/.last-watcher-beat"
}

clear_watcher() {
	if [ -n "$WATCH_PID" ]; then
		kill "$WATCH_PID" 2>/dev/null || true
		wait "$WATCH_PID" 2>/dev/null || true
	fi
	WATCH_PID=
	rm -rf "$STATE/.watch.lock" "$STATE/.last-watcher-beat"
}

assert_policy() {
	local expected=$1 command=$2 actual
	actual=$(node "$POLICY" --root "$PRIMARY" --command "$command") || fail "policy invocation failed: $command"
	if [ "$expected" = allow ]; then
		[ -z "$actual" ] || fail "policy expected allow for '$command', got '$actual'"
		return
	fi
	case "$actual" in
	deny | deny$'\t'*) : ;;
	*) fail "policy expected deny for '$command', got '$actual'" ;;
	esac
}

make_primary
: >"$STATE/task.meta"

# Executed command classification uses the shared lexer/program resolver.
for command in \
	'bin/fm-send.sh task go' \
	'./bin/fm-send.sh task go' \
	"$PRIMARY/bin/fm-send.sh task go" \
	'(bin/fm-send.sh task go)' \
	'echo "$(bin/fm-send.sh task go)"' \
	"bash -lc 'bin/fm-send.sh task go'" \
	'source bin/fm-send.sh task go' \
	"eval 'bin/fm-send.sh task go'" \
	"bash <<< 'bin/fm-send.sh task go'" \
	$'bash <<\'EOF\'\nbin/fm-send.sh task go\nEOF'; do
	assert_policy deny "$command"
done
pass "direct, absolute, grouped, substituted, shell -c, sourced, eval, here-string, and heredoc fleet execution is classified"

for command in \
	"echo 'bin/fm-send.sh task go'" \
	"printf '%s\\n' 'bin/fm-send.sh task go'" \
	"bash -n -c 'bin/fm-send.sh task go'" \
	'bash <<< "$payload"' \
	'if false; then bin/fm-send.sh task go; fi' \
	'/tmp/unrelated/bin/fm-send.sh task go' \
	'bin/fm-send.sh "unterminated'; do
	assert_policy allow "$command"
done
pass "quoted, non-executed, cross-home, malformed, and opaque controls preserve compatibility"

for command in \
	'bin/fm-wake-drain.sh' \
	'bin/fm-watch-arm.sh' \
	'bin/fm-watch-arm.sh --restart' \
	"source '$PRIMARY/config/x-mode.env'; bin/fm-watch-arm.sh" \
	'bin/fm-teardown.sh finished-task'; do
	expect_allow "supported recovery command '$command'" "$command"
done
expect_deny "forced cleanup" 'bin/fm-teardown.sh finished-task --force' 'drop --force'
expect_deny "expanded cleanup argument" 'bin/fm-teardown.sh "$task_id"' 'shell-expanded arguments'
expect_deny "globbed cleanup argument" 'bin/fm-teardown.sh task-*' 'shell-expanded arguments'
pass "wake drain, Claude arm recovery, and literal cleanup stay available while forced or expanded cleanup is denied"

expect_allow "ordinary shell command" 'printf ok'
expect_deny "unhealthy in-flight fleet operation" 'bin/fm-send.sh task go' 'Claude Code background task'
record_healthy_watcher
expect_allow "healthy in-flight fleet operation" 'bin/fm-send.sh task go'
touch -t 200001010000 "$STATE/.last-watcher-beat"
expect_deny "stale-beacon fleet operation" 'bin/fm-send.sh task go'
clear_watcher
rm -f "$STATE/task.meta"
expect_allow "idle-home fleet operation" 'bin/fm-send.sh task go'
pass "the gate keys on real work plus an identity-matched live lock and fresh beacon"

: >"$STATE/task.meta"
record_healthy_watcher
printf '%s\n' "$TMP_ROOT/other-home" >"$STATE/.watch.lock/fm-home"
expect_deny "cross-home lock identity" 'bin/fm-send.sh task go'
printf '%s\n' "$PRIMARY" >"$STATE/.watch.lock/fm-home"
printf '%s\n' "$TMP_ROOT/other-watch.sh" >"$STATE/.watch.lock/watcher-path"
expect_deny "cross-watcher path identity" 'bin/fm-send.sh task go'
clear_watcher
pass "another home or process identity cannot satisfy this home's health proof"

# A marked secondmate home remains a primary for its own isolated fleet.
SECOND="$TMP_ROOT/second"
git -C "$PRIMARY" worktree add -q -b fixture-second "$SECOND"
mkdir -p "$SECOND/bin" "$SECOND/state"
printf '# fixture\n' >"$SECOND/AGENTS.md"
printf 'sm-fixture\n' >"$SECOND/.fm-secondmate-home"
cp "$PRIMARY/bin/"* "$SECOND/bin/"
: >"$SECOND/state/task.meta"
rc=0
FM_ROOT_OVERRIDE="$SECOND" FM_HOME="$SECOND" FM_STATE_OVERRIDE="$SECOND/state" \
	"$SECOND/bin/fm-continuity-pretool-check.sh" --command 'bin/fm-send.sh task go' >"$OUT" 2>"$ERR" || rc=$?
[ "$rc" -eq 2 ] || fail "marked secondmate primary must be guarded, got exit $rc"
pass "marked secondmate homes guard their own isolated fleet"

# A linked task worktree remains outside the shared primary-scope owner.
CHILD="$TMP_ROOT/child"
git -C "$PRIMARY" config user.name fixture
git -C "$PRIMARY" config user.email fixture@example.invalid
git -C "$PRIMARY" add AGENTS.md
git -C "$PRIMARY" commit -qm fixture
git -C "$PRIMARY" worktree add -q -b fixture-child "$CHILD"
mkdir -p "$CHILD/bin" "$CHILD/state"
printf '# fixture\n' >"$CHILD/AGENTS.md"
cp "$PRIMARY/bin/"* "$CHILD/bin/"
: >"$CHILD/state/task.meta"
rc=0
FM_ROOT_OVERRIDE="$CHILD" FM_HOME="$CHILD" FM_STATE_OVERRIDE="$CHILD/state" \
	"$CHILD/bin/fm-continuity-pretool-check.sh" --command 'bin/fm-send.sh task go' >"$OUT" 2>"$ERR" || rc=$?
[ "$rc" -eq 0 ] || fail "child task copy must be unaffected, got exit $rc: $(cat "$ERR")"
pass "child task copies are outside the continuity gate"

# Dependency and transport degradation are silent fail-open compatibility paths.
for payload in '' '{bad-json' '{}' '{"tool_name":"Bash","tool_input":{}}'; do
	rc=0
	printf '%s' "$payload" | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
		"$PRIMARY/bin/fm-continuity-pretool-check.sh" >"$OUT" 2>"$ERR" || rc=$?
	[ "$rc" -eq 0 ] || fail "malformed transport must allow, got $rc"
	[ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "malformed transport allow wrote output"
done
FAKEBIN="$TMP_ROOT/no-node"
mkdir -p "$FAKEBIN"
for tool in bash cat dirname git jq mkdir pwd; do
	target=$(command -v "$tool") || fail "missing fixture dependency: $tool"
	ln -s "$target" "$FAKEBIN/$tool"
done
rc=0
PATH="$FAKEBIN" FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
	"$PRIMARY/bin/fm-continuity-pretool-check.sh" --command 'bin/fm-send.sh task go' >"$OUT" 2>"$ERR" || rc=$?
[ "$rc" -eq 0 ] || fail "missing Node must fail open, got $rc"
[ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "missing Node fail-open wrote output"
pass "malformed input and dependency degradation fail open silently"

# Drive the command registered on Claude's real hook/settings surface.
HOOK_COMMAND=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("fm-continuity-pretool-check.sh")) | .command' "$ROOT/.claude/settings.json")
[ -n "$HOOK_COMMAND" ] && [ "$HOOK_COMMAND" != null ] || fail "Claude settings do not register the continuity hook"
: >"$STATE/task.meta"
rc=0
payload=$(jq -cn '{tool_name:"Bash",tool_input:{command:"bin/fm-send.sh task go"}}')
printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$PRIMARY" FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
	bash -c "$HOOK_COMMAND" >"$OUT" 2>"$ERR" || rc=$?
[ "$rc" -eq 2 ] || fail "registered Claude hook must deny with exit 2, got $rc"
[ ! -s "$OUT" ] || fail "registered Claude deny wrote stdout"
jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 || fail "registered Claude deny shape is invalid"
pass "the tracked Claude Bash PreToolUse registration invokes the continuity gate"

command -v shellcheck >/dev/null 2>&1 || fail "shellcheck is required"
shellcheck "$CHECK" >/dev/null 2>&1 || fail "continuity hook is not shellcheck-clean"
pass "continuity hook is shellcheck-clean"
