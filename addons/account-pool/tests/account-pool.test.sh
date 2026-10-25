#!/usr/bin/env bash
# account-pool: drive the fm-spawn and fm-control hook lines (the exact form a Kun fm-spawn.sh and
# fm-control.sh carry) against a stub byokit-accounts and a throwaway config. Add-on present = the
# pool pick lands in the launch line and record, and relaunch --account rests and moves; add-on
# absent = every hook line is a silent no-op (Kun behavior). These are the pool cases that lived in
# the fork's tests/fm-worker-account.test.sh and tests/fm-control-relaunch.test.sh.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
w=$(mktemp -d "${TMPDIR:-/tmp}/account-pool-test.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
mkdir -p "$w/config" "$w/folder-acct1" "$w/folder-acct2" "$w/bin" "$w/empty" "$w/pool" "$w/cfg-bad" "$w/cfg-link" "$w/cfg-ok"
printf 'state=%s\ncommand=%s\n' "$w/pool" "$w/bin/byokit-accounts" > "$w/config/account-pool"
printf '# a comment\n\ncommand=/usr/bin/byokit-accounts\n' > "$w/cfg-bad/account-pool"
ln -s "$w/missing" "$w/cfg-link/account-pool"
ln -s "$w/config/account-pool" "$w/cfg-ok/account-pool"
printf 'fm_run_timed() { shift; "$@"; }\n' > "$w/bin/fm-timeout-lib.sh"
# The stub pool: pick answers TEST_PICK (FOLDER = acct1's folder), or TEST_PICK_RESTED once an account
# rests, else acct1 until it rests, then acct2, or the --prefer id, in the tool's own store variable;
# an answer without "ok":true exits 1. status names a go* account's tool opencode. Every call is logged.
cat > "$w/bin/byokit-accounts" <<'POOL'
#!/usr/bin/env bash
echo "$*" >> "$TMPDIR/pool.log"
case $1 in
  status) case $2 in go*) echo '{"tool":"opencode"}' ;; *) echo '{"tool":"claude"}' ;; esac ;;
  rest) touch "$TMPDIR/rested-$2" ;;
  pick)
    a=${TEST_PICK:-}; [ ! -e "$TMPDIR/rested-acct1" ] || a=${TEST_PICK_RESTED:-$a}
    if [ -z "$a" ]; then
      id=acct1; [ ! -e "$TMPDIR/rested-acct1" ] || id=acct2; [ "$4" != --prefer ] || id=$5
      case $2 in codex) v=CODEX_HOME ;; pi) v=PI_CODING_AGENT_DIR ;; *) v=CLAUDE_CONFIG_DIR ;; esac
      a="{\"ok\":true,\"id\":\"$id\",\"set\":{\"$v\":\"$TMPDIR/folder-$id\"},\"unset\":[\"ANTHROPIC_API_KEY\",\"CLAUDE_CODE_OAUTH_TOKEN\"]}"
    fi
    echo "${a//FOLDER/$TMPDIR/folder-acct1}"
    case $a in *'"ok":true'*) ;; *) echo "error: No $2 account can take a run right now." >&2; exit 1 ;; esac ;;
esac
POOL
# The synthetic workers print the account environment the launch line gave them.
cat > "$w/bin/claude" <<'WORKER'
#!/usr/bin/env bash
echo "worker CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR-unset} CODEX_HOME=${CODEX_HOME-unset} ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY-unset} CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN-unset}"
WORKER
cp "$w/bin/claude" "$w/bin/codex"
chmod +x "$w/bin/byokit-accounts" "$w/bin/claude" "$w/bin/codex"
# The hook lines at their call sites, in fm-spawn.sh order; TEST_PANE runs the launch line in a pane
# whose ambient environment names another login.
cat > "$w/fake-spawn.sh" <<'FAKE'
CONFIG=$TEST_CONFIG HARNESS=${TEST_HARNESS:-claude} WORKER_ACCOUNT=${TEST_PIN:-} SPAWN_ACCOUNT= RELAUNCH=0
SCRIPT_DIR=$TEST_BIN LAUNCH=$HARNESS
shell_quote() { printf '%q' "$1"; }
_fm_ap=${FM_ADDONS_DIR:-${FM_HOME:-$SCRIPT_DIR/..}/projects/firstmate-addons}/account-pool/bin/fm-account-pool-lib.sh; { [ -r "$_fm_ap" ] && . "$_fm_ap"; } || fm_account_hook() { :; }
eval "$(fm_account_hook argv "$@")"
case " $* " in *" --relaunch "*) RELAUNCH=1 ;; esac
fm_account_hook spawn-validate || exit 1
[ -z "${TEST_RAW:-}" ] || fm_account_hook raw-launch "$CONFIG" || exit 1
fm_account_hook spawn-pick "$HARNESS" "$CONFIG" "$WORKER_ACCOUNT" "${POOL_ACCOUNT_WANT:-}" || exit 1
[ "$HARNESS" != claude ] || [ -z "${CLAUDE_CONFIG_DIR:-}" ] || LAUNCH="CLAUDE_CONFIG_DIR=$(shell_quote "$CLAUDE_CONFIG_DIR") $LAUNCH"
fm_account_hook launch-prefix "$HARNESS" "$WORKER_ACCOUNT"
fm_account_hook spawn-line
fm_account_hook record-line
echo "launch=$LAUNCH spawn_account=$SPAWN_ACCOUNT args=$*"
[ -z "${TEST_PANE:-}" ] || env CLAUDE_CONFIG_DIR=/ambient ANTHROPIC_API_KEY=pane-key CLAUDE_CODE_OAUTH_TOKEN=pane-token PATH="$TEST_BIN:$PATH" bash -c "$LAUNCH"
FAKE
# fm-control.sh's lines: parse, verb check, preflight pool half, last pre-stop step, spawn args.
cat > "$w/fake-control.sh" <<'FAKE'
SCRIPT_DIR=$TEST_BIN VERB=$1 CONFIG=$TEST_CONFIG HARNESS=${TEST_HARNESS:-claude}
shift
fm_worker_account_resolve() { [ -z "${TEST_PIN:-}" ] || printf 'ordinary\t\t\n'; }
_fm_ap=${FM_ADDONS_DIR:-${FM_HOME:-$SCRIPT_DIR/..}/projects/firstmate-addons}/account-pool/bin/fm-account-pool-lib.sh; { [ -r "$_fm_ap" ] && . "$_fm_ap"; } || fm_account_hook() { :; }
eval "$(fm_account_hook argv "$@")"
[ "$#" -eq 0 ] || { echo "error: unexpected argument '$1'" >&2; exit 1; }
fm_account_hook control-validate "$VERB" || exit 1
fm_account_hook relaunch-pre "$HARNESS" "$CONFIG" "${TEST_TO:-}" "$TEST_RECORDED" "${TEST_FROM:-}" t1 || exit 1
fm_account_hook relaunch-commit "$HARNESS" "$CONFIG" "$TEST_RECORDED" || exit 1
spawn_args=(t1 --relaunch --harness "$HARNESS")
fm_account_hook spawn-args
FM_CONTROL_RELAUNCH_TX=tx bash "$TEST_SPAWN" "${spawn_args[@]}"
FAKE
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }
run() { # run <addons-dir> <script> [args...]: sets out and rc, from a fresh pool
  local a=$1 s=$2; shift 2
  rm -f "$w"/rested-*; : > "$w/pool.log"
  out=$(env -i PATH="$PATH" HOME="$w" TMPDIR="$w" FM_ADDONS_DIR="$a" TEST_BIN="$w/bin" TEST_CONFIG="${CFG:-$w/config}" \
    TEST_RAW="${TEST_RAW:-}" TEST_PIN="${TEST_PIN:-}" TEST_RECORDED="${TEST_RECORDED-acct1}" TEST_HARNESS="${TEST_HARNESS:-}" \
    TEST_PICK="${TEST_PICK:-}" TEST_PICK_RESTED="${TEST_PICK_RESTED:-}" TEST_FROM="${TEST_FROM:-}" TEST_TO="${TEST_TO:-}" \
    TEST_PANE="${TEST_PANE:-}" TEST_SPAWN="$w/fake-spawn.sh" bash "$w/$s" "$@" 2>&1); rc=$?
}
run1() { is "$1" "$rc|${out##*$'\n'}" "$2"; }
run2() { is "$1" "$(grep -c "$2" "$w/pool.log")" "$3"; }
has() { local got=no; case $out in *"$2"*) got=yes ;; esac; is "$1" "$rc|$got" "${3:-1}|yes"; } # <name> <text> [rc]
refusal='{"ok":false,"tool":"claude","reason":"No claude account can take a run right now.","rows":[{"id":"pa_a","name":"Work","state":"resting"},{"id":"pa_b","name":"Personal","state":"signed_out"}]}'

run "$addons" fake-spawn.sh
is "present: the pick lands in the launch line, spawned line and record" "$rc|$out" "0|account=acct1
launch=env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR=$w/folder-acct1 claude spawn_account= account=acct1 args="
TEST_RAW=1 run "$addons" fake-spawn.sh;       has "present: a raw launch is refused while the pool exists" "use a named harness"
run2 "  ... before the pool is asked" "." 0
run "$w/empty" fake-spawn.sh;                 is "absent: every hook line is a silent no-op" "$rc|$out" "0|launch=claude spawn_account= args="
TEST_RAW=1 run "$w/empty" fake-spawn.sh;      is "absent: a raw launch is not refused" "$rc" 0

TEST_PANE=1 run "$addons" fake-spawn.sh; run1 "the worker runs on the picked folder with the pick's unset list shed" "0|worker CLAUDE_CONFIG_DIR=$w/folder-acct1 CODEX_HOME=unset ANTHROPIC_API_KEY=unset CLAUDE_CODE_OAUTH_TOKEN=unset"
run2 "  ... and the pool is asked for the mapped tool in the pool folder" "^pick claude --json --state $w/pool$" 1
TEST_PICK='{"ok":true,"id":"acct1","set":{"CLAUDE_CONFIG_DIR":"FOLDER"},"unset":[]}' TEST_PANE=1 run "$addons" fake-spawn.sh
run1 "an empty unset list sheds nothing" "0|worker CLAUDE_CONFIG_DIR=$w/folder-acct1 CODEX_HOME=unset ANTHROPIC_API_KEY=pane-key CLAUDE_CODE_OAUTH_TOKEN=pane-token"
TEST_HARNESS=codex TEST_PANE=1 run "$addons" fake-spawn.sh; run1 "a codex worker runs on CODEX_HOME=<folder>" "0|worker CLAUDE_CONFIG_DIR=/ambient CODEX_HOME=$w/folder-acct1 ANTHROPIC_API_KEY=unset CLAUDE_CODE_OAUTH_TOKEN=unset"
TEST_HARNESS=pi-signed run "$addons" fake-spawn.sh; run2 "pi-signed picks from the pi pool" "^pick pi " 1
TEST_HARNESS=opencode run "$addons" fake-spawn.sh; is "an unmapped harness keeps its launch and never asks the pool" "$rc|$out|$(wc -l < "$w/pool.log")" "0|launch=opencode spawn_account= args=|0"
TEST_PIN=x run "$addons" fake-spawn.sh;       is "a pin wins and the pool is never asked" "$rc|$out|$(wc -l < "$w/pool.log")" "0|launch=claude spawn_account= args=|0"
TEST_PICK=$refusal run "$addons" fake-spawn.sh
run1 "a failed pick refuses, naming who is resting or signed out and the login to do" "1|error: config/account-pool cannot start a claude worker: No claude account can take a run right now. (Work resting, Personal signed out); add or sign in to an account with '$w/bin/byokit-accounts add claude', then retry"
while IFS= read -r answer; do
  TEST_PICK=$answer run "$addons" fake-spawn.sh; has "an unusable answer refuses: $answer" "answered with an unusable claude account selection"
done <<'ANSWERS'
{"ok":true,"id":"pa_x","set":{"CLAUDE_CONFIG_DIR":"FOLDER"},"unset":"ANTHROPIC_API_KEY"}
{"ok":true,"id":"pa_x","set":{"CLAUDE_CONFIG_DIR":"FOLDER"},"unset":[123]}
{"ok":true,"id":"pa_x","set":{"CLAUDE_CONFIG_DIR":"FOLDER"},"unset":["A B"]}
{"ok":true,"id":"pa_x","set":{"CLAUDE_CONFIG_DIR":"FOLDER"},"unset":["1BAD"]}
{"ok":true,"id":"pa_x","set":{"HOME":"FOLDER"},"unset":[]}
{"ok":true,"id":"pa_x","set":{"CLAUDE_CONFIG_DIR":"FOLDER/missing"},"unset":[]}
{"ok":true,"id":"../x","set":{"CLAUDE_CONFIG_DIR":"FOLDER"},"unset":[]}
ANSWERS
CFG=$w/cfg-bad run "$addons" fake-spawn.sh;   has "a pool file with no state= refuses" "config/account-pool must name the pool folder"
CFG=$w/cfg-link run "$addons" fake-spawn.sh;  has "a broken config/account-pool symlink refuses" "config/account-pool must be a readable regular file"
CFG=$w/cfg-ok run "$addons" fake-spawn.sh;    has "a config/account-pool symlink to a readable file is a usable pool" "account=acct1" 0

run "$addons" fake-control.sh relaunch --account next
run1 "relaunch --account next: the replacement launches on the next account, no key or token" \
  "0|launch=env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR=$w/folder-acct2 claude spawn_account= account=acct2 args=t1 --relaunch --harness claude"
run2 "relaunch --account next: the recorded account rests once, before the stop" "^rest acct1 " 1
run "$addons" fake-control.sh relaunch --account=acct2; run2 "relaunch --account <id>: nothing rests" "^rest " 0
is "relaunch --account <id>: the launch is on exactly that account" "$rc|${out##*account=}" "0|acct2 args=t1 --relaunch --harness claude"
run2 "  ... asked with --prefer <id>" "^pick claude --json --prefer acct2 " 2
run "$addons" fake-control.sh relaunch; is "relaunch with no --account keeps the plain pick" "$rc|${out##*account=}|$(grep -c 'prefer\|^rest ' "$w/pool.log")" "0|acct1 args=t1 --relaunch --harness claude|0"
TEST_PICK=$refusal run "$addons" fake-control.sh relaunch; has "relaunch with no free account refuses before the stop" "cannot start a claude worker"
TEST_PICK_RESTED=$refusal run "$addons" fake-control.sh relaunch --account next; has "next on a one-account pool rests it, then refuses" "cannot start a claude worker"
run2 "  ... after one rest" "^rest acct1 " 1
TEST_PICK='{"ok":true,"id":"pa_other","set":{"CLAUDE_CONFIG_DIR":"FOLDER"},"unset":[]}' run "$addons" fake-control.sh relaunch --account pa_wanted
has "a pick answering another account refuses" "answered with account 'pa_other' rather than the requested account 'pa_wanted'"
TEST_RECORDED=go1 run "$addons" fake-control.sh relaunch --account next; run1 "relaunch --account next off an OpenCode Go account is refused" "1|error: '--account next' cannot move an account of tool 'opencode' automatically; move this worker by hand with 'bin/fm-control.sh t1 relaunch --account <id>'"
run2 "  ... and nothing rests" "^rest " 0
TEST_HARNESS=pi TEST_FROM=opencode-go/glm run "$addons" fake-control.sh relaunch --account next; has "next off a worker on the opencode-go provider is refused" "cannot move a worker on the opencode-go provider automatically"
TEST_HARNESS=pi TEST_FROM=opencode-go/glm TEST_TO=pi/sonnet run "$addons" fake-control.sh relaunch --account next
has "  ... even when --model switches the replacement" "cannot move a worker on the opencode-go provider automatically"
run2 "  ... and nothing rests or picks" "^rest \|^pick " 0
TEST_RECORDED='' run "$addons" fake-control.sh relaunch --account next; run1 "relaunch --account next with no recorded account is refused" "1|error: '--account next' moves the account the running worker launched on, and task t1 records none; move it with '--account <id>' instead"
TEST_PIN=1 run "$addons" fake-control.sh relaunch --account acct2; run1 "relaunch --account under a pin is refused" "1|error: this home pins claude workers to one account, and the pin wins over --account 'acct2'; change or remove the pin file, or relaunch without --account"
run2 "  ... without asking the pool" "." 0
CFG=$w/empty run "$addons" fake-control.sh relaunch --account next; run1 "relaunch --account with no pool is refused" "1|error: --account needs this home's account pool: config/account-pool naming state=<pool folder>"
TEST_HARNESS=opencode run "$addons" fake-control.sh relaunch --account acct2; has "relaunch --account on a harness with no pool tool is refused" "(claude, codex, pi, pi-signed), not 'opencode'"
run2 "  ... without asking the pool" "." 0
run "$addons" fake-control.sh exit --account next; run1 "--account on another verb is refused" "1|error: --account applies to 'relaunch' only"
run "$addons" fake-control.sh relaunch --account; run1 "--account with no value is refused" "1|error: --account requires a value"
run "$addons" fake-control.sh relaunch --account ../x; run2 "a malformed --account: the pool is never asked" "." 0
run1 "a malformed --account is refused" "1|error: --account takes 'next' or one account id, not '../x'"
run "$addons" fake-control.sh relaunch --account 'pa two words'; has "an --account with spaces is refused" "--account takes 'next' or one account id"
run "$addons" fake-spawn.sh --account next;   run1 "a fresh launch refuses --account" "1|error: --account applies to a relaunch only; a fresh launch picks its pool account on its own"
run "$addons" fake-spawn.sh --relaunch --account next; run1 "a direct relaunch --account next is refused" "1|error: --account next rests the recorded account only in fm-control's pre-stop gate; a direct relaunch would ignore it and may re-pick the same account - use 'bin/fm-control.sh <task-id> relaunch --account next'"
CFG=$w/empty run "$addons" fake-spawn.sh --relaunch --account pa_named; has "a direct relaunch --account with no pool refuses, never the ambient login" "no account pool for claude workers"
TEST_HARNESS=opencode run "$addons" fake-spawn.sh --relaunch --account pa_named; has "  ... and on a harness with no pool tool" "no account pool for opencode workers"
run "$w/empty" fake-control.sh relaunch --account next; run1 "absent: --account stays the caller's own argument" "1|error: unexpected argument '--account'"
# Shared model-pool helper (JSON pick/next) forced-limit journey; same add-on tree.
if bash "$addons/account-pool/tests/model-pool.test.sh"; then echo "ok - model-pool forced-limit"; else echo "not ok - model-pool forced-limit"; fails=$((fails + 1)); fi
[ "$fails" -eq 0 ]
