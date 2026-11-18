#!/usr/bin/env bash
# tests/fm-remote-secondmate-hc.test.sh - a remote second mate on the herdr-core
# (hc) backend, through its host-local control plane
# (bin/fm-remote-secondmate-control.sh) and the parent-side route check in
# bin/fm-spawn.sh:
#
#   A) a launch whose session core does not answer is refused before any hc
#      call, so it never starts a core the app does not show; a launch with a
#      live core runs the ordinary host-local hc secondmate spawn in the remote
#      hc session, under exactly that session and no inherited hc routing
#      marker, and records and reports the hc route; the mate's terminal
#      carries the Herdr.app labels that place it in its own space.
#   B) state, route, a repeated launch, a steer, and a key all reach that
#      endpoint without creating another terminal.
#   C) a record outside the remote hc session, or on another backend, is
#      refused rather than reached.
#   D) a finished mate is replaced: its husk is removed and a fresh terminal
#      is launched.
#   E) a dead core socket reads unreadable and starts no core.
#   F) the session override and the runtime-directory pin behave as
#      bin/fm-remote-hc-lib.sh documents.
#   G) host-local retirement closes the mate's terminal and removes its home.
#
# tests/fm-remote-secondmate-lifecycle-e2e.test.sh owns the parent side: it
# records a well-formed hc route and refuses a malformed one.
#
# The core is the stateful fake in tests/hc-fake-fixture.sh, and its socket is
# a live listener at hc's XDG_RUNTIME_DIR layout, so nothing here can reach a
# real core.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/hc-fake-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/hc-fake-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-hc)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
# A short runtime directory keeps the core socket inside the sun_path limit.
HC_RUN=$(TMPDIR=/tmp fm_test_tmproot fm-rsm-hc-run)
mkdir -p "$HC_RUN"
cleanup() {
  local pid
  for pid in $(jobs -p); do
    kill "$pid" 2>/dev/null || true
  done
  fm_test_remove_tree "$TMP_ROOT"
  fm_test_remove_tree "$HC_RUN"
}
trap cleanup EXIT
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
SESSION=fmtest
fm_test_live_unix_sock "$HC_RUN/herdr-core/$SESSION.sock" || fail "could not park the fake core socket"

HC_DIR="$TMP_ROOT/hc"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN" "$HC_DIR"
write_hc_fake_cli "$FAKEBIN/herdr-core" "D='$HC_DIR'"
ln -sf "$(command -v git)" "$FAKEBIN/git"
ln -sf "$(command -v jq)" "$FAKEBIN/jq"
ln -sf "$(command -v node)" "$FAKEBIN/node"
ln -sf "$(command -v python3)" "$FAKEBIN/python3"
for tool in treehouse claude; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/$tool"
  chmod +x "$FAKEBIN/$tool"
done

ID=sm-hc
HOME_DIR="$TMP_ROOT/home-$ID"
mkdir -p "$HOME_DIR/bin" "$HOME_DIR/data"
printf '# Firstmate\n' > "$HOME_DIR/AGENTS.md"
printf '%s\n' "$ID" > "$HOME_DIR/.fm-secondmate-home"
printf '# Charter\n\nStand by until steering arrives.\n' > "$HOME_DIR/data/charter.md"
git -C "$HOME_DIR" init -q
ACCOUNT_HOME="$TMP_ROOT/account-home"
mkdir -p "$ACCOUNT_HOME"
META="$HOME_DIR/state/parent-route/$ID.meta"

# The remote job worker runs every command under env -i, so the control plane
# sees only what is set here. HC_SOCKET and HC_TERMINAL_* stand in for markers
# a caller could carry; the launch must drop them.
ctl() {
  env -i PATH="$FAKEBIN:$BASE_PATH" HOME="$ACCOUNT_HOME" TMUX='' \
    FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_REMOTE_HC_SESSION="${CTL_SESSION:-$SESSION}" XDG_RUNTIME_DIR="${CTL_RUNTIME:-$HC_RUN}" \
    HC_SOCKET=/nonexistent/inherited.sock HC_TERMINAL_ID=t99 HC_TERMINAL_SOCKET=/nonexistent/terminal.sock \
    "$ROOT/bin/fm-remote-secondmate-control.sh" "$@"
}
hc_terminal_count() {
  find "$HC_DIR" -maxdepth 1 -name 't*.json' | wc -l | tr -d ' '
}
# shellcheck disable=SC2016 # the $0 root expands in the child shell.
mate_tag() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source hc >/dev/null 2>&1; fm_backend_hometag' "$ROOT"
}

# --- A) launch ---------------------------------------------------------------

NO_CORE_RUN="$HC_RUN/no-core"
mkdir -p "$NO_CORE_RUN/herdr-core"
if CTL_RUNTIME="$NO_CORE_RUN" ctl launch "$ID" claude - - hc > "$TMP_ROOT/no-core.out" 2>&1; then
  fail "a launch was accepted although no core answers for the remote hc session"
fi
assert_grep "no herdr-core core answers for session $SESSION" "$TMP_ROOT/no-core.out" \
  "the no-core refusal did not name the missing core"
assert_grep 'connect this machine from Herdr.app or start its user service' "$TMP_ROOT/no-core.out" \
  "the no-core refusal did not name the human remedy"
[ ! -s "$HC_DIR/log" ] || fail "a launch with no live core called hc, which would start a core the app does not show"
[ ! -e "$META" ] || fail "a launch with no live core recorded an endpoint"
pass "A a launch with no live core for the remote hc session is refused and calls no hc"

ctl launch "$ID" claude - - hc > "$TMP_ROOT/launch.out" 2> "$TMP_ROOT/launch.err"
expect_code 0 "$?" "host-local remote secondmate launch on hc failed"$'\n'"$(cat "$TMP_ROOT/launch.err")"
assert_grep 'backend=hc' "$TMP_ROOT/launch.out" "the printed route did not report hc"
assert_grep "target=$SESSION:t1" "$TMP_ROOT/launch.out" "the hc endpoint target is outside the remote hc session"
assert_grep "hc_session=$SESSION" "$TMP_ROOT/launch.out" "the printed route did not report the hc session"
assert_grep 'backend=hc' "$META" "endpoint metadata did not record the hc backend"
assert_grep "hc_session=$SESSION" "$META" "endpoint metadata did not record the hc session"
assert_grep 'hc_terminal=t1' "$META" "endpoint metadata did not record the hc terminal"
run_line=$(grep $'\x1frun\x1f' "$HC_DIR/log" | head -1)
[ -n "$run_line" ] || fail "the launch created no hc terminal"
assert_contains "$run_line" "HC_SESSION=$SESSION"$'\x1f' "the terminal was created outside the remote hc session"
assert_contains "$run_line" "XDG_RUNTIME_DIR=$HC_RUN"$'\x1f' "the terminal was created without the core's runtime directory"
if grep -q 'nonexistent' "$HC_DIR/log"; then
  fail "an inherited hc routing marker reached the core"
fi
[ "$(jq -r '.labels["herdr.space"]' "$HC_DIR/t1.json")" = "fm-$(mate_tag)" ] \
  || fail "the mate's terminal is not placed in its own Herdr.app space"
[ "$(jq -r '.labels["firstmate.task"]' "$HC_DIR/t1.json")" = "fm-$ID" ] \
  || fail "the mate's terminal does not carry its task label"
pass "A launch runs the host-local hc secondmate spawn in the remote hc session and records its route"

# --- B) reaching the endpoint -------------------------------------------------

[ "$(ctl state "$ID" 2>/dev/null)" = alive ] || fail "the hc endpoint did not read alive from its host-local route"
ctl route "$ID" > "$TMP_ROOT/route.out" 2>&1 || fail "route failed: $(cat "$TMP_ROOT/route.out")"
assert_grep 'backend=hc' "$TMP_ROOT/route.out" "route did not report hc"
assert_grep "hc_session=$SESSION" "$TMP_ROOT/route.out" "route did not report the hc session"
ctl launch "$ID" claude - - hc > "$TMP_ROOT/relaunch-alive.out" 2>&1 \
  || fail "a launch over a live hc endpoint failed: $(cat "$TMP_ROOT/relaunch-alive.out")"
[ "$(hc_terminal_count)" = 1 ] || fail "a launch over a live hc endpoint created another terminal"
sent_before=$(wc -l < "$HC_DIR/sent" | tr -d ' ')
ctl send "$ID" "routed work for the hc mate" > "$TMP_ROOT/send.out" 2>&1 \
  || fail "a steer to the hc mate failed: $(cat "$TMP_ROOT/send.out")"
grep -rqs 'routed work for the hc mate' "$HOME_DIR/state/parent-route/$ID.inbox" \
  || fail "the steer was not durably recorded in the hc mate's inbox"
[ "$(wc -l < "$HC_DIR/sent" | tr -d ' ')" -gt "$sent_before" ] \
  || fail "the steer's doorbell never reached the hc terminal: $(cat "$TMP_ROOT/send.out"; tail -6 "$HC_DIR/log" | tr '\037' ' ')"
ctl key "$ID" Escape > "$TMP_ROOT/key.out" 2>&1 || fail "a key to the hc mate failed: $(cat "$TMP_ROOT/key.out")"
grep -q $'\x1fkeys\x1f' "$HC_DIR/log" || fail "the key never reached the hc terminal"
pass "B state, route, repeated launch, steer, and key reach the hc endpoint without a second terminal"

# --- C) refusals --------------------------------------------------------------

if CTL_SESSION=other ctl route "$ID" > "$TMP_ROOT/other-session.out" 2>&1; then
  fail "a record outside the remote hc session was reached"
fi
assert_grep "expected 'other'" "$TMP_ROOT/other-session.out" "the out-of-session refusal did not name the expected session"
[ "$(CTL_SESSION=other ctl state "$ID" 2>/dev/null)" = unverified ] \
  || fail "a record outside the remote hc session was not classified unverified"
if ctl launch "$ID" claude - - herdr > "$TMP_ROOT/other-backend.out" 2>&1; then
  fail "a herdr launch over a recorded hc endpoint was accepted"
fi
assert_grep "recorded on backend 'hc', expected 'herdr'" "$TMP_ROOT/other-backend.out" \
  "the cross-backend refusal did not name both backends"
if ctl launch "$ID" claude - - tmux > "$TMP_ROOT/bad-backend.out" 2>&1; then
  fail "a tmux remote secondmate launch was accepted"
fi
assert_grep 'runs only on the herdr, rex, or hc backend' "$TMP_ROOT/bad-backend.out" \
  "an unsupported remote backend was not refused by name"
if CTL_SESSION='bad/session' ctl route "$ID" > "$TMP_ROOT/bad-session.out" 2>&1; then
  fail "an invalid hc session override was accepted"
fi
[ "$(hc_terminal_count)" = 1 ] || fail "a refused call created or removed a terminal"
pass "C records outside the remote hc session or on another backend are refused"

# --- D) replacing a finished mate ---------------------------------------------

jq '.state="finished" | .foreground=null' "$HC_DIR/t1.json" > "$HC_DIR/t1.tmp" && mv "$HC_DIR/t1.tmp" "$HC_DIR/t1.json"
case "$(ctl state "$ID" 2>/dev/null)" in
  dead | missing) ;;
  *) fail "a finished hc mate did not read dead or missing" ;;
esac
ctl launch "$ID" claude - - hc > "$TMP_ROOT/replace.out" 2>&1 \
  || fail "a finished hc mate was not replaced: $(cat "$TMP_ROOT/replace.out")"
[ ! -e "$HC_DIR/t1.json" ] || fail "the finished mate's husk was left behind"
assert_grep "target=$SESSION:t2" "$TMP_ROOT/replace.out" "the replacement did not record a fresh terminal"
[ "$(ctl state "$ID" 2>/dev/null)" = alive ] || fail "the replacement hc mate did not read alive"
pass "D a finished hc mate is replaced after its husk is removed"

# --- E) a dead core socket ----------------------------------------------------

calls_before=$(wc -l < "$HC_DIR/log" | tr -d ' ')
DEAD_RUN="$HC_RUN/dead"
mkdir -p "$DEAD_RUN/herdr-core"
[ "$(CTL_RUNTIME="$DEAD_RUN" ctl state "$ID" 2>/dev/null)" = unreadable ] \
  || fail "an hc endpoint behind a dead core socket did not read unreadable"
[ "$(wc -l < "$HC_DIR/log" | tr -d ' ')" = "$calls_before" ] \
  || fail "a read behind a dead core socket called hc, which would start an empty core"
pass "E a dead core socket reads unreadable without calling hc"

# --- F) the session and runtime-directory owner -------------------------------

# shellcheck disable=SC2016 # expanded by the child shell.
[ "$(env -u FM_REMOTE_HC_SESSION bash -c '. "$0/bin/fm-remote-hc-lib.sh"; fm_remote_hc_session' "$ROOT")" = default ] \
  || fail "the remote hc session is not the default core the app shows"
# shellcheck disable=SC2016 # expanded by the child shell.
if FM_REMOTE_HC_SESSION='-x' bash -c '. "$0/bin/fm-remote-hc-lib.sh"; fm_remote_hc_session' "$ROOT" >/dev/null 2>&1; then
  fail "an option-shaped session override was accepted"
fi
# shellcheck disable=SC2016 # expanded by the child shell.
[ "$(XDG_RUNTIME_DIR=/keep/me bash -c '. "$0/bin/fm-remote-hc-lib.sh"; fm_remote_hc_runtime_env; printf %s "$XDG_RUNTIME_DIR"' "$ROOT")" = /keep/me ] \
  || fail "an explicit runtime directory was overridden"
# The pin follows the systemd per-user runtime-directory convention,
# <root>/<uid>, under a root this test owns: it exports a directory this account
# owns, and never one that is a symlink or belongs to another account.
# shellcheck disable=SC2016 # expanded by the child shell.
pin_from() { # <run-user-root> [path-prefix]
  env -u XDG_RUNTIME_DIR PATH="${2:+$2:}$PATH" FM_REMOTE_HC_RUN_USER_ROOT="$1" \
    bash -c '. "$0/bin/fm-remote-hc-lib.sh"; fm_remote_hc_runtime_env; printf %s "${XDG_RUNTIME_DIR:-}"' "$ROOT"
}
PIN_ROOT="$TMP_ROOT/run-user"
mkdir -p "$PIN_ROOT/$(id -u)"
[ "$(pin_from "$PIN_ROOT")" = "$PIN_ROOT/$(id -u)" ] \
  || fail "an absent runtime directory was not pinned to this account's <root>/<uid>"
[ -z "$(pin_from "$TMP_ROOT/no-run-user")" ] \
  || fail "a runtime directory was pinned although <root>/<uid> does not exist"
LINK_ROOT="$TMP_ROOT/run-user-link"
mkdir -p "$LINK_ROOT"
ln -s "$PIN_ROOT/$(id -u)" "$LINK_ROOT/$(id -u)"
[ -z "$(pin_from "$LINK_ROOT")" ] || fail "a symlinked <root>/<uid> was pinned"
if [ "$(id -u)" != 0 ]; then
  # /usr is a real directory owned by root on every supported host, so an id
  # that names it presents a runtime directory owned by another account.
  OTHER_ID="$TMP_ROOT/other-id"
  mkdir -p "$OTHER_ID"
  printf '#!/usr/bin/env bash\nprintf usr\n' > "$OTHER_ID/id"
  chmod +x "$OTHER_ID/id"
  [ -z "$(pin_from / "$OTHER_ID")" ] || fail "a runtime directory owned by another account was pinned"
fi
pass "F the session override and the runtime-directory pin behave as documented"

# --- G) retirement ------------------------------------------------------------

ctl retire "$ID" > "$TMP_ROOT/retire.out" 2>&1
expect_code 0 "$?" "host-local retirement of an hc mate failed"$'\n'"$(cat "$TMP_ROOT/retire.out")"
[ ! -e "$HC_DIR/t2.json" ] || fail "retirement left the hc mate's terminal behind"
assert_absent "$HOME_DIR" "retirement left the hc mate's home behind"
pass "G host-local retirement closes the hc mate's terminal and removes its home"

echo "ALL TESTS PASSED"
