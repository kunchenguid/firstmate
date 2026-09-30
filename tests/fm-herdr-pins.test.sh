#!/usr/bin/env bash
# tests/fm-herdr-pins.test.sh - behavior coverage for bin/fm-herdr-pins.sh, the
# opt-in helper that keeps the captain's pinned agents tagged in Herdr's
# sidebar Agents view, plus the remote host-local pin verbs in
# bin/fm-remote-secondmate-control.sh and the liveness-tick cadence in
# bin/fm-secondmate-liveness-lib.sh.
#
# Herdr is a PATH fake that records every call, the agent-view transport is the
# documented FM_HERDR_PINS_VIEW_SETTER seam, and the remote transport is faked
# at the SSH boundary exactly as the other remote-secondmate suites fake it. No
# real Herdr server is contacted.
#
# The guarantees under test:
#   - Without config/pinned-agents, sync and clear are silent no-ops that never
#     call Herdr.
#   - sync accepts the documented line shape, zero-pads ranks, keeps label
#     spacing, and names malformed lines, lines without an explicit host, and
#     repeated ids.
#   - sync tags each agent's CURRENT pane from its recorded endpoint (self from
#     the supervisor pane, a local secondmate from its validated meta, a remote
#     secondmate through its host's pin verb) and installs the view once per
#     local session; a pane move is followed on the next pass.
#   - Agents not on Herdr, missing records, a missing or failing Herdr never
#     fail the pass, and a remote host that does not answer is tried once per
#     pass rather than once per agent it hosts.
#   - sync is idempotent; clear clears only an id the config pins.
#   - The remote pin and unpin verbs act on the host's own endpoint record.
#   - The liveness tick re-asserts at most once per FM_HERDR_PINS_SECS while the
#     session-start pass always re-asserts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP=$(fm_test_tmproot fm-herdr-pins)
HOME_DIR="$TMP/home"
FAKEBIN=$(fm_fakebin "$TMP/fake")
HERDR_LOG="$TMP/herdr.log"
VIEW_LOG="$TMP/view.log"
SSH_LOG="$TMP/ssh.log"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
: > "$HERDR_LOG"
: > "$VIEW_LOG"
: > "$SSH_LOG"

{
  printf -- '- ios - iOS delivery (host: remote-mac; root: /srv/fm; home: /srv/fm-home; scope: iOS; projects: alpha; added 2026-08-01)\n'
  printf -- '- mac - Mac helper (host: remote-mac; root: /srv/fm; home: /srv/fm-home-mac; scope: Mac; projects: alpha; added 2026-08-01)\n'
} > "$HOME_DIR/data/secondmates.md"

# The fake herdr records one line per call and answers the session socket read.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "session list")
    printf '{"sessions":[{"name":"fm-lab-pins","socket_path":"/tmp/fm-lab-pins.sock"},{"name":"fm-remote","socket_path":"/tmp/fm-remote.sock"}]}\n'
    exit 0
    ;;
  "status --json") exit 1 ;;
esac
printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"
[ "${FAKE_HERDR_FAIL:-0}" = 1 ] && exit 1
exit 0
SH
chmod +x "$FAKEBIN/herdr"

cat > "$FAKEBIN/view-setter" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_VIEW_LOG"
[ "${FAKE_HERDR_FAIL:-0}" = 1 ] && exit 4
exit 0
SH
chmod +x "$FAKEBIN/view-setter"

# FAKE_SSH_FAIL=<status> makes every call exit with it after it is logged;
# FAKE_SSH_SLEEP=<secs> makes every call hang that long first;
# FAKE_SSH_STDERR=<text> is printed on stderr, as the remote command's own.
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$1" = remote-mac ] || exit 91
[ "$2" = fm-remote-entrypoint.sh ] || exit 92
perl -MMIME::Base64=decode_base64 -e '
  my @args = split(/\0/, decode_base64($ARGV[0]));
  print join("|", @args), "\n";
' "$6" >> "$FAKE_SSH_LOG"
[ "${FAKE_SSH_SLEEP:-0}" = 0 ] || sleep "$FAKE_SSH_SLEEP"
[ -z "${FAKE_SSH_STDERR:-}" ] || printf '%s\n' "$FAKE_SSH_STDERR" >&2
exit "${FAKE_SSH_FAIL:-0}"
SH
chmod +x "$FAKEBIN/fake-ssh"

# pins <args...>: run the helper as the primary in its own Herdr pane.
pins() {
  env -u TMUX -u TMUX_PANE -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND \
    PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" \
    HERDR_ENV=1 HERDR_PANE_ID="${PIN_SELF_PANE:-w1:p1}" HERDR_SESSION=fm-lab-pins \
    FAKE_HERDR_LOG="$HERDR_LOG" FAKE_VIEW_LOG="$VIEW_LOG" FAKE_SSH_LOG="$SSH_LOG" \
    FAKE_HERDR_FAIL="${FAKE_HERDR_FAIL:-0}" FAKE_SSH_FAIL="${FAKE_SSH_FAIL:-0}" \
    FAKE_SSH_SLEEP="${FAKE_SSH_SLEEP:-0}" FAKE_SSH_STDERR="${FAKE_SSH_STDERR:-}" \
    FM_HERDR_PINS_REMOTE_TIMEOUT="${FM_HERDR_PINS_REMOTE_TIMEOUT:-45}" \
    FM_HERDR_PINS_VIEW_SETTER="$FAKEBIN/view-setter" FM_SSH_BIN="$FAKEBIN/fake-ssh" \
    "$ROOT/bin/fm-herdr-pins.sh" "$@" 2>&1
}

reset_logs() { : > "$HERDR_LOG"; : > "$VIEW_LOG"; : > "$SSH_LOG"; }

write_local_mate() {  # <id> <pane>
  fm_write_meta "$HOME_DIR/state/$1.meta" \
    "window=fm-lab-pins:$2" \
    "endpoint_task_id=$1" \
    "worktree=$HOME_DIR/homes/$1" \
    "project=$HOME_DIR/homes/$1" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "backend=herdr" \
    "herdr_session=fm-lab-pins" \
    "herdr_workspace_id=w7" \
    "herdr_tab_id=w7:t1" \
    "herdr_pane_id=$2" \
    "home=$HOME_DIR/homes/$1"
}

write_remote_mate() {  # <id> <home>
  fm_write_meta "$HOME_DIR/state/$1.meta" \
    "window=remote:$1" \
    "endpoint_task_id=$1" \
    "worktree=$2" \
    "project=/srv/fm" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$2" \
    "remote_host=remote-mac" \
    "remote_root=/srv/fm" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w3:p2"
}

TOKENS_SOURCE='--source firstmate-pins'
CLEAR_TOKENS='--clear-token pin_rank --clear-token pin_label --clear-token pin_host'

# --- off: no config ----------------------------------------------------------
OUT=$(pins sync); RC=$?
expect_code 0 "$RC" "sync without config"
assert_equals "" "$OUT" "sync without config should print nothing"
OUT=$(pins clear legal); RC=$?
expect_code 0 "$RC" "clear without config"
assert_equals "" "$OUT" "clear without config should print nothing"
[ ! -s "$HERDR_LOG" ] && [ ! -s "$VIEW_LOG" ] || fail "the off path must never call Herdr"
pass "with no config the helper is a silent no-op"

# --- parsing and rejection ----------------------------------------------------
cat > "$HOME_DIR/config/pinned-agents" <<'EOF'
# rank id host label
1 self VPS First   Mate

  3   ghost   Mac   Ghost
  # indented comment
0 zero Mac Zero
100 big Mac Big
x word Mac Word
2 bad/id Mac Bad
5 legal2 bad^host Label
4 legal Mac
6 legal - Legal Clerk
7 legal Mac Legal Again
8 legal Mac Legal Twice
EOF
reset_logs
OUT=$(pins sync); RC=$?
expect_code 0 "$RC" "sync with rejected lines"$'\n'"$OUT"
assert_equals "pane report-metadata w1:p1 $TOKENS_SOURCE --token pin_rank=01 --token pin_label=First   Mate --token pin_host=VPS --session fm-lab-pins" \
  "$(cat "$HERDR_LOG")" "only the valid local line should be tagged, zero-padded and with its label spacing"
assert_contains "$OUT" "skipped ghost: no endpoint record" "an indented valid line should be accepted"
assert_contains "$OUT" "skipped legal: no endpoint record" "the first well-formed line for an id should be accepted"
for n in 6 7 8 9 10; do
  assert_contains "$OUT" "pinned-agents line $n: expected" "line $n should be rejected as malformed"
done
for n in 11 12; do
  assert_contains "$OUT" "pinned-agents line $n: missing host or label" "line $n should be rejected for lacking an explicit host"
done
assert_contains "$OUT" "pinned-agents line 14: legal is already pinned" "a repeated id should be rejected"
for id in zero big word legal2; do
  assert_not_contains "$OUT" "skipped $id:" "rejected line for $id must not be applied"
done
pass "sync accepts the documented shape and names every rejected line"

# --- sync: self, local mate, remote mate, and skipped entries -----------------
write_local_mate legal w7:p2
write_remote_mate ios /srv/fm-home
fm_write_meta "$HOME_DIR/state/tmuxmate.meta" \
  "window=firstmate:fm-tmuxmate" "endpoint_task_id=tmuxmate" "worktree=/x" "project=/x" \
  "harness=claude" "kind=secondmate" "mode=secondmate" "home=/x"
cat > "$HOME_DIR/config/pinned-agents" <<'EOF'
1 self     VPS Firstmate
2 legal    Mac Legal Clerk
3 ios      WSL Power BI
4 tmuxmate Mac Tmux Mate
5 ghost    Mac Ghost
EOF
reset_logs
OUT=$(pins sync); RC=$?
expect_code 0 "$RC" "sync"$'\n'"$OUT"
assert_contains "$OUT" "pinned self fm-lab-pins:w1:p1" "self should be pinned on its own pane"
assert_contains "$OUT" "pinned legal fm-lab-pins:w7:p2" "the local mate should be pinned on its recorded pane"
assert_contains "$OUT" "pinned ios remote" "the remote mate should be pinned on its host"
assert_contains "$OUT" "skipped tmuxmate: endpoint is on tmux, not herdr" "a tmux mate should be skipped"
assert_contains "$OUT" "skipped ghost: no endpoint record" "a missing mate should be skipped"
assert_grep "pane report-metadata w1:p1 $TOKENS_SOURCE --token pin_rank=01 --token pin_label=Firstmate --token pin_host=VPS --session fm-lab-pins" \
  "$HERDR_LOG" "self tokens were not reported on the supervisor pane"
assert_grep "pane report-metadata w7:p2 $TOKENS_SOURCE --token pin_rank=02 --token pin_label=Legal Clerk --token pin_host=Mac --session fm-lab-pins" \
  "$HERDR_LOG" "the local mate's tokens were not reported on its recorded pane"
assert_equals 2 "$(wc -l < "$HERDR_LOG" | tr -d ' ')" "only the two local herdr panes should be tagged locally"
assert_equals "/tmp/fm-lab-pins.sock" "$(cat "$VIEW_LOG")" "the view should be installed exactly once on the shared local session"
assert_equals "fm-remote-secondmate-control.sh|pin|ios|03|WSL|Power BI" "$(cat "$SSH_LOG")" \
  "the remote mate should be pinned through its host's pin verb with its configured host"
pass "sync pins self, local, and remote agents on their current endpoints and skips the rest"

# --- idempotence --------------------------------------------------------------
cp "$HERDR_LOG" "$TMP/herdr.first"
cp "$VIEW_LOG" "$TMP/view.first"
cp "$SSH_LOG" "$TMP/ssh.first"
reset_logs
OUT2=$(pins sync); RC=$?
expect_code 0 "$RC" "second sync"
assert_equals "$OUT" "$OUT2" "a second sync should report the same outcome"
cmp -s "$HERDR_LOG" "$TMP/herdr.first" || fail "a second sync should issue identical herdr calls"
cmp -s "$VIEW_LOG" "$TMP/view.first" || fail "a second sync should install the same view"
cmp -s "$SSH_LOG" "$TMP/ssh.first" || fail "a second sync should send the same remote pin"
pass "sync is idempotent"

# --- a relaunch into a new pane is followed ----------------------------------
write_local_mate legal w8:p5
reset_logs
PIN_SELF_PANE=w2:p9 pins sync >/dev/null
assert_grep "pane report-metadata w8:p5 $TOKENS_SOURCE --token pin_rank=02" "$HERDR_LOG" \
  "the mate's new recorded pane should be tagged"
assert_grep "pane report-metadata w2:p9 $TOKENS_SOURCE --token pin_rank=01" "$HERDR_LOG" \
  "self should follow the supervisor pane"
assert_no_grep "w7:p2" "$HERDR_LOG" "the old pane must never be addressed"
pass "each pass resolves the current pane rather than a stored one"

# --- single-id sync touches only that id -------------------------------------
reset_logs
OUT=$(pins sync legal)
assert_equals "pinned legal fm-lab-pins:w8:p5" "$OUT" "a single-id sync should report only that id"
assert_equals 1 "$(wc -l < "$HERDR_LOG" | tr -d ' ')" "a single-id sync should tag only that pane"
[ ! -s "$SSH_LOG" ] || fail "a single-id sync must not touch other agents"
pass "a single-id sync pins only that agent"

# --- self outside Herdr is skipped ------------------------------------------
reset_logs
OUT=$(env TMUX_PANE=%3 PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" \
  FAKE_HERDR_LOG="$HERDR_LOG" FAKE_VIEW_LOG="$VIEW_LOG" \
  FM_HERDR_PINS_VIEW_SETTER="$FAKEBIN/view-setter" \
  "$ROOT/bin/fm-herdr-pins.sh" sync self 2>&1); RC=$?
expect_code 0 "$RC" "sync self under tmux"
assert_equals "skipped self: supervisor pane is on tmux, not herdr" "$OUT" "self under tmux should be skipped"
[ ! -s "$HERDR_LOG" ] || fail "self under tmux must not call Herdr"
pass "self is skipped when this firstmate is not on Herdr"

# --- failures never fail the pass --------------------------------------------
reset_logs
OUT=$(FAKE_HERDR_FAIL=1 FAKE_SSH_FAIL=1 pins sync); RC=$?
expect_code 0 "$RC" "sync with Herdr and the remote failing"
assert_contains "$OUT" "skipped legal: herdr did not confirm the tokens" "an unconfirmed tag should be reported"
assert_contains "$OUT" "skipped view fm-lab-pins: herdr did not confirm the view" "an unconfirmed view should be reported"
assert_contains "$OUT" "skipped ios: remote pin did not complete" "a failed remote pin should be reported"
OUT=$(env PATH="$BASE_PATH" FM_HOME="$HOME_DIR" HERDR_ENV=1 HERDR_PANE_ID=w1:p1 \
  FM_HERDR_PINS_VIEW_SETTER="$FAKEBIN/view-setter" FAKE_VIEW_LOG="$VIEW_LOG" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" FAKE_SSH_LOG="$SSH_LOG" \
  "$ROOT/bin/fm-herdr-pins.sh" sync legal 2>&1); RC=$?
expect_code 0 "$RC" "sync without herdr installed"
assert_equals "skipped legal: herdr did not confirm the tokens" \
  "$(printf '%s\n' "$OUT" | head -1)" "a missing herdr should be reported, not fatal"
pass "an unreachable or missing Herdr never fails the pass"

# --- an unreachable remote host is tried once per pass ------------------------
write_remote_mate mac /srv/fm-home-mac
cat > "$HOME_DIR/config/pinned-agents" <<'EOF'
1 self VPS Firstmate
3 ios  Mac Power BI
4 mac  Mac Mac
5 legal Mac Legal Clerk
EOF
reset_logs
OUT=$(FAKE_SSH_FAIL=255 pins sync); RC=$?
expect_code 0 "$RC" "sync with an unreachable remote host"$'\n'"$OUT"
assert_contains "$OUT" "skipped ios: host remote-mac unreachable this pass" "a transport failure should mark the host unreachable"
assert_contains "$OUT" "skipped mac: host remote-mac unreachable this pass" "a later agent on that host should be skipped"
assert_equals "fm-remote-secondmate-control.sh|pin|ios|03|Mac|Power BI" "$(cat "$SSH_LOG")" \
  "an unreachable host should be contacted only once per pass"
assert_contains "$OUT" "pinned legal fm-lab-pins:w8:p5" "a local agent listed after the host should still be pinned"
reset_logs
START=$(date +%s)
OUT=$(FAKE_SSH_SLEEP=30 FM_HERDR_PINS_REMOTE_TIMEOUT=1 pins sync); RC=$?
ELAPSED=$(( $(date +%s) - START ))
expect_code 0 "$RC" "sync with a remote host that hangs"$'\n'"$OUT"
assert_contains "$OUT" "skipped mac: host remote-mac unreachable this pass" "a timed-out host should be skipped for the rest of the pass"
assert_equals 1 "$(wc -l < "$SSH_LOG" | tr -d ' ')" "a hanging host should be contacted only once per pass"
[ "$ELAPSED" -lt 15 ] || fail "a hanging host should cost one bounded call, took ${ELAPSED}s"
reset_logs
OUT=$(FAKE_SSH_FAIL=1 pins sync)
assert_contains "$OUT" "skipped ios: remote pin did not complete" "a remote-side refusal should be reported"
assert_contains "$OUT" "skipped mac: remote pin did not complete" "a remote-side refusal should not skip the host's other agents"
assert_equals 2 "$(wc -l < "$SSH_LOG" | tr -d ' ')" "a host that answers should be tried for each of its agents"
pass "an unreachable remote host costs one bounded call per pass"

# --- a remote code root older than the pin verbs is skipped quietly ----------
reset_logs
OUT=$(FAKE_SSH_FAIL=1 FAKE_SSH_STDERR='error: unknown command: pin' pins sync); RC=$?
expect_code 0 "$RC" "sync against a host without the pin verb"$'\n'"$OUT"
assert_contains "$OUT" "skipped ios: remote pin did not complete" \
  "a host without the pin verb should be skipped like any refused pin"
assert_contains "$OUT" "skipped mac: remote pin did not complete" \
  "a host without the pin verb should be skipped for each of its agents"
assert_contains "$OUT" "pinned legal fm-lab-pins:w8:p5" "local agents should still be pinned"
case "$OUT" in *"unknown command"*) fail "the old host's own error should not leak into the pass output" ;; esac
printf '3 ios Mac Power BI\n' > "$HOME_DIR/config/pinned-agents"
OUT=$(FAKE_SSH_FAIL=1 FAKE_SSH_STDERR='error: unknown command: unpin' pins clear ios); RC=$?
expect_code 0 "$RC" "clear against a host without the unpin verb"
assert_equals "skipped ios: remote unpin did not complete" "$OUT" \
  "a clear against a host without the unpin verb should be skipped quietly"
pass "a remote Firstmate that predates pinning is a quiet non-fatal skip"

# --- clear <id> ---------------------------------------------------------------
printf '2 legal Mac Legal Clerk\n3 ios Mac Power BI\n' > "$HOME_DIR/config/pinned-agents"
reset_logs
OUT=$(pins clear legal); RC=$?
expect_code 0 "$RC" "clear"
assert_equals "cleared legal" "$OUT" "clear should report the cleared id"
assert_equals "pane report-metadata w8:p5 $TOKENS_SOURCE $CLEAR_TOKENS --session fm-lab-pins" "$(cat "$HERDR_LOG")" \
  "clear did not clear the mate's tokens"
[ ! -s "$VIEW_LOG" ] || fail "clear must not touch the view"
OUT=$(pins clear ios); RC=$?
expect_code 0 "$RC" "remote clear"
assert_equals "cleared ios" "$OUT" "a remote clear should report the cleared id"
assert_equals "fm-remote-secondmate-control.sh|unpin|ios" "$(cat "$SSH_LOG")" \
  "a remote clear should go through the host's unpin verb"
reset_logs
OUT=$(pins clear mac); RC=$?
expect_code 0 "$RC" "clear of an unpinned id"
assert_equals "" "$OUT" "clearing an id the config does not pin should print nothing"
[ ! -s "$HERDR_LOG" ] && [ ! -s "$SSH_LOG" ] || fail "clearing an id the config does not pin must not call Herdr or the remote host"
pass "clear removes the tokens of an agent the config pins and ignores the rest"

# --- remote host-local pin and unpin verbs ------------------------------------
MATE_HOME="$TMP/mate-home"
mkdir -p "$MATE_HOME/bin" "$MATE_HOME/state/parent-route" "$MATE_HOME/config"
printf 'ios\n' > "$MATE_HOME/.fm-secondmate-home"
: > "$MATE_HOME/AGENTS.md"
fm_write_meta "$MATE_HOME/state/parent-route/ios.meta" \
  "window=fm-remote:w3:p2" "endpoint_task_id=ios" "worktree=$MATE_HOME" "project=$MATE_HOME" \
  "harness=claude" "kind=secondmate" "mode=secondmate" "backend=herdr" "herdr_session=fm-remote" \
  "herdr_workspace_id=w3" "herdr_tab_id=w3:t1" "herdr_pane_id=w3:p2" "home=$MATE_HOME"
control() {
  env PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$MATE_HOME" FAKE_HERDR_LOG="$HERDR_LOG" FAKE_VIEW_LOG="$VIEW_LOG" \
    FAKE_HERDR_FAIL="${FAKE_HERDR_FAIL:-0}" FM_HERDR_PINS_VIEW_SETTER="$FAKEBIN/view-setter" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" "$@" 2>&1
}
reset_logs
OUT=$(control pin ios 03 Mac "Power BI"); RC=$?
expect_code 0 "$RC" "remote pin verb"$'\n'"$OUT"
assert_equals "pane report-metadata w3:p2 $TOKENS_SOURCE --token pin_rank=03 --token pin_label=Power BI --token pin_host=Mac --session fm-remote" \
  "$(cat "$HERDR_LOG")" "the pin verb should tag the host's recorded pane in fm-remote"
assert_equals "/tmp/fm-remote.sock" "$(cat "$VIEW_LOG")" "the pin verb should install the view on fm-remote"
reset_logs
OUT=$(control unpin ios); RC=$?
expect_code 0 "$RC" "remote unpin verb"$'\n'"$OUT"
assert_equals "pane report-metadata w3:p2 $TOKENS_SOURCE $CLEAR_TOKENS --session fm-remote" \
  "$(cat "$HERDR_LOG")" "the unpin verb should clear the host's pane tokens"
[ ! -s "$VIEW_LOG" ] || fail "the unpin verb must not touch the view"
OUT=$(FAKE_HERDR_FAIL=1 control pin ios 03 Mac "Power BI"); RC=$?
expect_code 1 "$RC" "a remote pin Herdr does not confirm should fail its verb"
assert_contains "$OUT" "herdr did not confirm the pin tokens" "the refusal should say Herdr did not confirm"
reset_logs
OUT=$(control pin ios 3 Mac "Power BI"); RC=$?
expect_code 1 "$RC" "a malformed rank should be refused"
[ ! -s "$HERDR_LOG" ] || fail "a malformed rank must never reach Herdr"
pass "the remote pin and unpin verbs act on the host's own endpoint record"

# --- liveness tick cadence ----------------------------------------------------
printf '1 self VPS Firstmate\n' > "$HOME_DIR/config/pinned-agents"
rm -f "$HOME_DIR/state/.herdr-pins-tick"
# shellcheck disable=SC2016 # the child shell expands its own script
tick() {  # <full|poll>
  env -u TMUX -u TMUX_PANE PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_ROOT="$ROOT" \
    STATE="$HOME_DIR/state" CONFIG="$HOME_DIR/config" \
    HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SESSION=fm-lab-pins \
    FAKE_HERDR_LOG="$HERDR_LOG" FAKE_VIEW_LOG="$VIEW_LOG" \
    FM_HERDR_PINS_VIEW_SETTER="$FAKEBIN/view-setter" FM_HERDR_PINS_SECS=3600 \
    bash -c '. "$FM_ROOT/bin/fm-secondmate-liveness-lib.sh"; fm_secondmate_liveness_pins "$1"' _ "$1"
}
reset_logs
tick poll || fail "the poll pass should never fail"
assert_equals 1 "$(wc -l < "$HERDR_LOG" | tr -d ' ')" "the first poll pass should re-assert"
tick poll
assert_equals 1 "$(wc -l < "$HERDR_LOG" | tr -d ' ')" "a poll pass inside the cadence should not re-assert"
tick full
assert_equals 2 "$(wc -l < "$HERDR_LOG" | tr -d ' ')" "the session-start pass should always re-assert"
rm -f "$HOME_DIR/config/pinned-agents" "$HOME_DIR/state/.herdr-pins-tick"
reset_logs
tick poll
[ ! -s "$HERDR_LOG" ] || fail "the tick must not call Herdr when pins are off"
assert_absent "$HOME_DIR/state/.herdr-pins-tick" "the tick must leave no marker when pins are off"
pass "the liveness tick re-asserts on its own cadence and session start always does"

# --- an idle home pinning only self is re-pinned by session start -------------
# A Herdr restart ends the primary's own process, so the resumed primary runs
# session start again; its deferred network stage re-asserts the pins with no
# watcher and no secondmates in the home.
IDLE_HOME="$TMP/idle-home"
mkdir -p "$IDLE_HOME/data" "$IDLE_HOME/state" "$IDLE_HOME/config"
printf '1 self VPS Firstmate\n' > "$IDLE_HOME/config/pinned-agents"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/gh"
chmod +x "$FAKEBIN/gh"
reset_logs
OUT=$(env -u TMUX -u TMUX_PANE -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND \
  PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$IDLE_HOME" FM_BOOTSTRAP_NETWORK=only FM_INHERITABLE_CONFIG='' \
  HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SESSION=fm-lab-pins \
  FAKE_HERDR_LOG="$HERDR_LOG" FAKE_VIEW_LOG="$VIEW_LOG" FM_HERDR_PINS_VIEW_SETTER="$FAKEBIN/view-setter" \
  "$ROOT/bin/fm-bootstrap.sh" 2>&1); RC=$?
expect_code 0 "$RC" "the session-start network stage in an idle home"$'\n'"$OUT"
assert_equals "pane report-metadata w1:p1 $TOKENS_SOURCE --token pin_rank=01 --token pin_label=Firstmate --token pin_host=VPS --session fm-lab-pins" \
  "$(cat "$HERDR_LOG")" "session start should re-pin self in a home with no secondmates"
assert_equals "/tmp/fm-lab-pins.sock" "$(cat "$VIEW_LOG")" "session start should re-install the view on self's session"
assert_absent "$IDLE_HOME/state/.herdr-pins-tick" "session start should not need the watcher's cadence marker"
pass "session start re-pins self in an idle home without a watcher"

# --- the agent-view transport sends only its fixed request --------------------
if command -v python3 >/dev/null 2>&1; then
  SOCK_DIR=$(mktemp -d /tmp/fmhp.XXXXXX)
  VIEW_SOCK="$SOCK_DIR/s"
  # serve_once <response-json>: accept one request on VIEW_SOCK, record it, reply.
  serve_once() {
    python3 - "$VIEW_SOCK" "$SOCK_DIR/request" "$1" <<'PY' &
import os, socket, sys
path, out, reply = sys.argv[1:]
if os.path.exists(path):
    os.unlink(path)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(1)
srv.settimeout(10)
conn, _ = srv.accept()
data = b""
while b"\n" not in data:
    chunk = conn.recv(4096)
    if not chunk:
        break
    data += chunk
open(out, "wb").write(data)
conn.sendall(reply.encode() + b"\n")
conn.close()
PY
    SERVER_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$VIEW_SOCK" ] && break; sleep 0.2; done
  }
  serve_once '{"id":"fm-herdr-pins","result":{"type":"agent_view","active":true,"source":"firstmate:pins","label":"Pinned"}}'
  "$ROOT/bin/backends/herdr-agent-view.py" "$VIEW_SOCK"; RC=$?
  wait "$SERVER_PID"
  expect_code 0 "$RC" "an active agent_view response should confirm the view"
  REQ=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "$SOCK_DIR/request")
  assert_equals '{"id": "fm-herdr-pins", "method": "agent.view.set", "params": {"filter": {"field": {"token": "pin_rank"}, "op": "exists"}, "label": "Pinned", "sort": [{"field": {"token": "pin_rank"}, "order": "asc"}], "source": "firstmate:pins"}}' \
    "$REQ" "the transport should send the fixed Pinned view"
  serve_once '{"id":"fm-herdr-pins","result":{"type":"agent_view","active":false,"source":null,"label":null}}'
  "$ROOT/bin/backends/herdr-agent-view.py" "$VIEW_SOCK"; RC=$?
  wait "$SERVER_PID"
  expect_code 4 "$RC" "an inactive agent_view response should not confirm the view"
  serve_once '{"id":"fm-herdr-pins","error":{"code":"unknown_method","message":"no such method"}}'
  "$ROOT/bin/backends/herdr-agent-view.py" "$VIEW_SOCK"; RC=$?
  wait "$SERVER_PID"
  expect_code 4 "$RC" "a Herdr build without agent views should be refused"
  "$ROOT/bin/backends/herdr-agent-view.py" "$VIEW_SOCK" clear; RC=$?
  expect_code 2 "$RC" "an extra argument should be refused before connecting"
  rm -rf "$SOCK_DIR"
  pass "the agent-view transport sends only the fixed view request"
else
  echo "skip: python3 not found for the agent-view transport cases"
fi
