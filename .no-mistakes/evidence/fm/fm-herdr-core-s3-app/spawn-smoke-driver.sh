#!/usr/bin/env bash
# tests/fm-backend-hc-appdetect-smoke.test.sh - real herdr-core end-to-end
# proof of Herdr.app runtime auto-detection: bin/fm-spawn.sh selecting the hc
# backend from the app's own signals with no explicit backend configured
# (docs/hc-backend.md "Runtime auto-detection").
#
# Three cases run a REAL spawn end to end, because detection is a
# fm-spawn-time decision (tests/fm-backend.test.sh owns the fake-env matrix):
#
#   A. app-terminal: the spawn env carries HC_TERMINAL_ID/HC_TERMINAL_SOCKET
#      of a live, herdr.space-labeled lab terminal - the exact claim an
#      app-created terminal makes. The label is verified through the core and
#      hc is selected, and meta records backend_detect=app-terminal.
#   B. app-window: no terminal markers; a live herdr-app.sock under a scratch
#      HERDR_APP_HOME selects hc with backend_detect=app-window.
#   C. explicit: config/backend=hc plus the same app-terminal env selects hc
#      but writes NO backend_detect= line - explicit selection never runs
#      detection.
#   D. no core: the same live window over an HC_SESSION with no running core
#      resolves the default backend with a notice and starts no core (the
#      decision point only; a tmux spawn is out of this smoke's scope).
#
# Everything lands in a bin/fm-hc-lab.sh session (unique fm-hclab-*
# HC_SESSION, scratch XDG roots, a pinned FM_HC_SOCKET, and a fleet-state
# tripwire); the fake app window is a plain python unix listener, never a
# real app, and tests/hc-test-safety.sh owns the only sanctioned teardown.
# Skips cleanly when no resolved Core binary, jq, treehouse, or python3 is
# available; a provisioning or teardown failure is a FAIL, not a skip.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

fail() {
  "$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" ls --all --json >&2
  for t in t1 t2 t3; do "$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" read "$t" --lines 300 >&2; done
  printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

HC_BIN=${FM_HC_BIN:-}
[ -n "$HC_BIN" ] || HC_BIN=$(command -v herdr-core 2>/dev/null || true)
[ -n "$HC_BIN" ] || HC_BIN=$(command -v hc 2>/dev/null || true)
if [ -z "$HC_BIN" ] || [ ! -x "$HC_BIN" ]; then
  echo "skip: hc not found (install via bin/fm-install-hc.sh or set FM_HC_BIN)"
  exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the hc adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the socket probes)"; exit 0; }
export FM_HC_BIN=$HC_BIN

# shellcheck source=tests/hc-test-safety.sh
. "$ROOT/tests/hc-test-safety.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-hc-appdetect)

HC_TEST_SES=fm-hclab-s

cleanup_lab() {
  local rc=$?
  trap - EXIT
  if [ -n "${APPSOCK_PID:-}" ]; then kill "$APPSOCK_PID" 2>/dev/null; wait "$APPSOCK_PID" 2>/dev/null; fi
  [ -n "${WT:-}" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT" >/dev/null 2>&1
  hc_test_safe_teardown "$ROOT" "$HC_TEST_SES" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_lab EXIT

"$ROOT/bin/fm-hc-lab.sh" provision "$HC_TEST_SES" \
  || fail "hc lab could not provision with $HC_BIN"
HC_TEST_SOCK=$("$ROOT/bin/fm-hc-lab.sh" socket "$HC_TEST_SES")
[ -n "$HC_TEST_SOCK" ] || fail "hc lab provisioned without a socket"
hc_test_refuse_if_unsafe "$HC_TEST_SES" \
  || fail "provisioned session '$HC_TEST_SES' does not satisfy the lab safety contract"

HC_LAB_DIR=$(hc_test_lab_dir)/$HC_TEST_SES
export HC_SESSION=$HC_TEST_SES FM_HC_SOCKET=$HC_TEST_SOCK
export XDG_STATE_HOME="$HC_LAB_DIR/env/xdg-state" \
  XDG_CONFIG_HOME="$HC_LAB_DIR/env/xdg-config" \
  XDG_DATA_HOME="$HC_LAB_DIR/env/xdg-data"
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET HERDR_APP_HOME

FM_HOME_DIR=$TMP_ROOT/home
PROJ=$TMP_ROOT/scratch-project
# <root-home>/state must exist: the shared Treehouse project lock resolves
# under it (bin/fm-wake-lib.sh fm_treehouse_project_lock_path).
mkdir -p "$FM_HOME_DIR/state" "$PROJ"
export FM_HOME=$FM_HOME_DIR FM_ROOT_OVERRIDE=$ROOT

STATE=$TMP_ROOT/state DATA=$TMP_ROOT/data CONFIG=$TMP_ROOT/config
mkdir -p "$STATE" "$DATA" "$CONFIG"

git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

HOMETAG=$(bash -c '. "'"$ROOT"'/bin/fm-backend.sh"; fm_backend_source hc >/dev/null 2>&1; fm_backend_hometag')
[ -n "$HOMETAG" ] || fail "could not resolve the test home's hometag"

write_brief() {
  mkdir -p "$DATA/$1"
  cat > "$DATA/$1/brief.md" <<EOF
# Task
## Captain's intent
Exercise Herdr.app backend auto-detection for $1.

## Firstmate spec
Verify the real spawn path selects hc.
EOF
}

# The scrubbed marker surface every spawn shares: nothing ambient may leak a
# surface claim into detection (the ambient pane's own HERDR_* included).
# HC_TERMINAL_*/HERDR_APP_HOME stay unset at file level instead, so each case
# can pass them through this list untouched.
SCRUB="env -u TMUX -u FM_BACKEND -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION \
  -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u CMUX_WORKSPACE_ID \
  -u __CFBundleIdentifier -u PASEO_AGENT_ID -u TERM_PROGRAM -u REX_BLOCK -u REX_SESSION"

spawn_one() {  # <id> <launch-line> -> spawn with the caller's extra env already in place
  write_brief "$1"
  $SCRUB FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$1" "$PROJ" "$2" --mode no-mistakes --yolo off "${@:3}"
}

teardown_one() {  # <id>
  printf "\n--- %s spawn output ---\n%s\n" "$1" "$OUT"
  case "$1" in appdets1) cat "$TMP_ROOT/a.err" ;; appdetw1) cat "$TMP_ROOT/b.err" ;; appdetc1) cat "$TMP_ROOT/c.err" ;; *) cat "$TMP_ROOT/extra.err" ;; esac
  cat "$STATE/$1.meta"
  WT=$(grep '^worktree=' "$STATE/$1.meta" 2>/dev/null | cut -d= -f2-)
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" \
    "$ROOT/bin/fm-teardown.sh" "$1" >/dev/null 2>&1 \
    || fail "fm-teardown.sh failed for $1"
  WT=
}

assert_task_labels() {  # <id> <terminal-addr>
  local labels
  labels=$("$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" get "$2" --json \
    | jq -r '.labels["herdr.space"], .labels["herdr.tab"], .labels["firstmate.task"], .labels["firstmate.home"]' 2>/dev/null) \
    || fail "hc get on the spawned task terminal failed for $1"
  printf "worker %s (%s) labels:\n%s\n" "$1" "$2" "$labels"
  [ "$(printf '%s\n' "$labels" | sed -n 1p)" = "fm-$HOMETAG" ] \
    || fail "$1's herdr.space must be fm-$HOMETAG, got: $labels"
  [ "$(printf '%s\n' "$labels" | sed -n 2p)" = "$HOMETAG-fm-$1" ] \
    || fail "$1's herdr.tab must be $HOMETAG-fm-$1, got: $labels"
  [ "$(printf '%s\n' "$labels" | sed -n 3p)" = "fm-$1" ] \
    || fail "$1's firstmate.task must be fm-$1, got: $labels"
  [ "$(printf '%s\n' "$labels" | sed -n 4p)" = "$HOMETAG" ] \
    || fail "$1's firstmate.home must be $HOMETAG, got: $labels"
}

# --- Case A: app-terminal ---------------------------------------------------
# A lab terminal carrying herdr.space, created the way the app creates every
# terminal; the spawn env claims to run inside it.
APP_TERM=$("$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" run --bg --no-parent \
  --label herdr.space=fm-app --label herdr.tab=app-probe 2>/dev/null \
  | jq -r '.address // empty')
[ -n "$APP_TERM" ] || fail "could not create the labeled app-terminal stand-in"

ID=appdets1
OUT=$(HC_TERMINAL_ID=$APP_TERM HC_TERMINAL_SOCKET=$HC_TEST_SOCK \
  spawn_one "$ID" "sh -c 'echo appdetect-terminal-ok'" 2>"$TMP_ROOT/a.err")
rc=$?
[ "$rc" -eq 0 ] || fail "fm-spawn.sh under the app-terminal signal failed"$'\n'"--- stdout ---"$'\n'"$OUT"$'\n'"--- stderr ---"$'\n'"$(cat "$TMP_ROOT/a.err")"
case "$OUT" in *"spawned $ID "*) : ;; *) fail "unexpected spawn output: $OUT" ;; esac
grep -q 'NOTICE: auto-detected a Herdr-app-projected terminal' "$TMP_ROOT/a.err" \
  || fail "the app-terminal notice must name the signal"$'\n'"$(cat "$TMP_ROOT/a.err")"
META=$STATE/$ID.meta
grep -q '^backend=hc$' "$META" || fail "meta must record backend=hc"$'\n'"$(cat "$META")"
grep -q '^backend_detect=app-terminal$' "$META" \
  || fail "meta must record backend_detect=app-terminal"$'\n'"$(cat "$META")"
grep -q "^hc_session=$HC_TEST_SES\$" "$META" || fail "meta must record hc_session"$'\n'"$(cat "$META")"
WORKER_TERM=$(grep '^hc_terminal=' "$META" | cut -d= -f2-)
[ -n "$WORKER_TERM" ] || fail "meta must record hc_terminal"
assert_task_labels "$ID" "$WORKER_TERM"
teardown_one "$ID"
pass "app-terminal: spawn env claiming a herdr.space-labeled terminal auto-selects hc, notices, records backend_detect=app-terminal, and labels the worker"

# --- Case B: app-window -----------------------------------------------------
# AF_UNIX caps near 104 bytes; the app socket must live under a short dir.
APPHOME=$(mktemp -d "$EVIDENCE/app.XXXXXX") || fail "mktemp for the app home failed"
python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(5); time.sleep(300)' \
  "$APPHOME/herdr-app.sock" >/dev/null 2>&1 &
APPSOCK_PID=$!
sleep 0.3

ID=appdetw1
OUT=$(HERDR_APP_HOME=$APPHOME spawn_one "$ID" "sh -c 'echo appdetect-window-ok'" 2>"$TMP_ROOT/b.err")
rc=$?
[ "$rc" -eq 0 ] || fail "fm-spawn.sh under the app-window signal failed"$'\n'"--- stdout ---"$'\n'"$OUT"$'\n'"--- stderr ---"$'\n'"$(cat "$TMP_ROOT/b.err")"
grep -q 'NOTICE: auto-detected a live Herdr app window' "$TMP_ROOT/b.err" \
  || fail "the app-window notice must name the signal"$'\n'"$(cat "$TMP_ROOT/b.err")"
META=$STATE/$ID.meta
grep -q '^backend=hc$' "$META" || fail "meta must record backend=hc"$'\n'"$(cat "$META")"
grep -q '^backend_detect=app-window$' "$META" \
  || fail "meta must record backend_detect=app-window"$'\n'"$(cat "$META")"
WORKER_TERM=$(grep '^hc_terminal=' "$META" | cut -d= -f2-)
assert_task_labels "$ID" "$WORKER_TERM"
teardown_one "$ID"
pass "app-window: a live herdr-app.sock under the resolved app home auto-selects hc with backend_detect=app-window"

# --- Case D: a live window over a session with no running core --------------
# The adapter's container_ensure starts a missing core, so detection must
# refuse instead of selecting hc for a session nobody started. No pin names
# the lab core here; the session is never provisioned.
ABSENT_SES=$HC_TEST_SES-none
# shellcheck disable=SC2016 # positional params expand in the child shell.
OUT=$($SCRUB -u FM_HC_SOCKET HERDR_APP_HOME="$APPHOME" HC_SESSION="$ABSENT_SES" \
  FM_CONFIG_OVERRIDE="$CONFIG" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_name' _ "$ROOT" 2>"$TMP_ROOT/d.err")
[ "$OUT" = tmux ] || fail "a live window over a stopped session must keep the default backend, got '$OUT'"$'\n'"$(cat "$TMP_ROOT/d.err")"
grep -q "hc session '$ABSENT_SES' has no running core" "$TMP_ROOT/d.err" \
  || fail "the refusal notice must name the session it would not start"$'\n'"$(cat "$TMP_ROOT/d.err")"
for probe in "$XDG_STATE_HOME/herdr-core/$ABSENT_SES" "${XDG_RUNTIME_DIR:-$TMP_ROOT/no-runtime}/herdr-core/$ABSENT_SES.sock"; do
  [ ! -e "$probe" ] || fail "resolving the backend started core state at $probe"
done
kill "$APPSOCK_PID" 2>/dev/null; wait "$APPSOCK_PID" 2>/dev/null; APPSOCK_PID=
pass "app-window: a live window over a session with no running core keeps the default and starts nothing"

# --- Case C: explicit config/backend wins, detection skipped ----------------
printf 'hc\n' > "$CONFIG/backend"
APP_TERM2=$("$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" run --bg --no-parent \
  --label herdr.space=fm-app --label herdr.tab=app-probe-2 2>/dev/null \
  | jq -r '.address // empty')
[ -n "$APP_TERM2" ] || fail "could not create the second labeled stand-in"

ID=appdetc1
OUT=$(HC_TERMINAL_ID=$APP_TERM2 HC_TERMINAL_SOCKET=$HC_TEST_SOCK \
  spawn_one "$ID" "sh -c 'echo appdetect-explicit-ok'" 2>"$TMP_ROOT/c.err")
rc=$?
[ "$rc" -eq 0 ] || fail "fm-spawn.sh with explicit config/backend=hc failed"$'\n'"--- stdout ---"$'\n'"$OUT"$'\n'"--- stderr ---"$'\n'"$(cat "$TMP_ROOT/c.err")"
META=$STATE/$ID.meta
grep -q '^backend=hc$' "$META" || fail "explicit config/backend=hc must record backend=hc"$'\n'"$(cat "$META")"
if grep -q '^backend_detect=' "$META"; then
  fail "an explicit selection must not record backend_detect (detection never ran)"$'\n'"$(cat "$META")"
fi
if grep -q 'NOTICE: auto-detected' "$TMP_ROOT/c.err"; then
  fail "an explicit selection must not print the auto-detect notice"$'\n'"$(cat "$TMP_ROOT/c.err")"
fi
teardown_one "$ID"
rm -f "$CONFIG/backend"
pass "explicit: config/backend=hc wins over the app signals and records no detection provenance"

# Explicit CLI beats contradictory config and the genuine app-terminal candidate.
printf 'tmux\n' > "$CONFIG/backend"
ID=appdetcli1
OUT=$(HC_TERMINAL_ID=$APP_TERM2 HC_TERMINAL_SOCKET=$HC_TEST_SOCK spawn_one "$ID" "sh -c 'echo explicit-cli-ok'" --backend hc 2>"$TMP_ROOT/extra.err")
[ "$?" -eq 0 ] || fail "explicit CLI spawn failed"
grep -q '^backend=hc$' "$STATE/$ID.meta" || fail "CLI did not beat config"
! grep -q '^backend_detect=' "$STATE/$ID.meta" || fail "explicit CLI emitted detection metadata"
! grep -q 'NOTICE: auto-detected' "$TMP_ROOT/extra.err" || fail "explicit CLI emitted detection notice"
teardown_one "$ID"
rm "$CONFIG/backend"
pass "explicit --backend hc overrides config/backend=tmux and app signals without detection metadata"

# Default tmux stays on a private named server; never contact the operator socket.
mkdir -p "$EVIDENCE/t"
export TMUX_TMPDIR="$EVIDENCE/t"
tmux -L fm-lab new-session -d -s primary -c "$PROJ" 'sleep 300' || fail "private tmux fixture failed"
export TMUX=$(tmux -L fm-lab display-message -p '#{socket_path},#{pid},0')
SCRUB=${SCRUB/-u TMUX /}
ID=appdettmux1
OUT=$(spawn_one "$ID" "sh -c 'echo default-tmux-ok'" 2>"$TMP_ROOT/extra.err")
rc=$?
if [ "$rc" -ne 0 ]; then tmux -L fm-lab kill-server; fail "default tmux spawn failed"; fi
if grep -q '^backend' "$STATE/$ID.meta" || grep -q 'NOTICE: auto-detected' "$TMP_ROOT/extra.err"; then
  tmux -L fm-lab kill-server; fail "default tmux gained backend fields or notice"
fi
teardown_one "$ID"
tmux -L fm-lab kill-server || fail "private tmux teardown failed"
unset TMUX TMUX_TMPDIR
pass "default tmux spawn retains metadata without backend or backend_detect and stays silent"
echo FM_TEST_COMPLETE
