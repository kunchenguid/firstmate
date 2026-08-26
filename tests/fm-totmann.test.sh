#!/usr/bin/env bash
# tests/fm-totmann.test.sh - the dead-man revival must judge liveness from
# structural evidence and only ever touch its one target window:
#
#   1. A live session-lock pid means alive - even with a bare-shell pane.
#   2. A pane with a live child process means alive without any lock.
#   3. A bare-shell pane plus a dead lock pid means dead; `check` types the
#      relaunch into the target window exactly once (debounce), and the
#      unrelated worker window never receives it.
#   4. Divergence is asserted in both directions (alive cases revive nothing).
#   5. A missing tmux session is recreated and revived (the reboot path).
#   6. A present fleet stop does not block the revival (leadership returns;
#      the stop keeps everything else down).
#   7. A boot newer than the last recorded revival is a BOOT REVIVAL: it types
#      exactly one /clear before arming the kicker with an existing stamp file.
#   8. A day-hang revival (boot older than the last revival) arms the kicker
#      without ever clearing.
#   9. When the fresh digest never arrives, the boot path still clears on its
#      deadline fallback and still arms the kicker (bounded, no hang).
#
# Isolation: throwaway FM_HOMEs and a private tmux server (-L socket); the
# notifier is disabled. Cases 1-6 pin day-hang mode via an unparseable proc-stat
# and an empty kicker. Cases 7-9 swap in a fake FM_ROOT whose fm-tmux-lib.sh
# stub records every call instead of touching tmux screens, plus a stub kicker
# recording its argv. Nothing touches the live fleet.
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` cannot misfire.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOTMANN="$REPO/bin/fm-totmann.sh"
TMP="$(mktemp -d)"
export TMP
SOCK="totmann-test-$$"
trap 'tmux -L "$SOCK" kill-server 2>/dev/null; rm -rf "$TMP"' EXIT
HOME_A="$TMP/home"
mkdir -p "$HOME_A/state"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

run() {
  FM_HOME="$HOME_A" FM_TOTMANN_TMUX="-L $SOCK" FM_TOTMANN_TARGET="fmtest:0" \
  FM_TOTMANN_RELAUNCH_CMD="echo REVIVED >> $TMP/revive.log" FM_TOTMANN_NOTIFY="" \
  FM_TOTMANN_DEBOUNCE=1800 FM_TOTMANN_PROC_STAT="$TMP/procstat-day" \
  FM_TOTMANN_ERGEBNIS_SECS=0 \
  FM_TOTMANN_ANSTOSS="" "$TOTMANN" "$@"
}
revive_count() { [ -f "$TMP/revive.log" ] && wc -l < "$TMP/revive.log" | tr -d ' ' || echo 0; }
wait_for_count() { # wait_for_count <n> -> 0 when revive.log reaches n lines
  for _ in $(seq 1 50); do
    [ "$(revive_count)" = "$1" ] && return 0
    sleep 0.1
  done
  return 1
}

printf 'not-a-procstat\n' > "$TMP/procstat-day"
tmux -L "$SOCK" new-session -d -s fmtest -c "$TMP" || { echo "tmux unavailable" >&2; exit 1; }
tmux -L "$SOCK" new-window -t fmtest:1 -n worker -c "$TMP"

# --- 1. live lock pid -> alive, even with a bare-shell pane ----------------
sleep 300 &
LOCK_PID=$!
echo "$LOCK_PID" > "$HOME_A/state/.lock"
if run status >/dev/null; then
  ok "live lock pid reads as alive"
else
  fail "a live lock pid must read as alive"
fi
run check >/dev/null || fail "check on an alive session must exit 0"
[ "$(revive_count)" = 0 ] && ok "an alive session is never revived" \
  || fail "check must not revive an alive session"

# --- 2. pane child process -> alive without any lock -----------------------
kill "$LOCK_PID" 2>/dev/null; wait "$LOCK_PID" 2>/dev/null
tmux -L "$SOCK" send-keys -t fmtest:0 'sleep 300' Enter
for _ in $(seq 1 50); do
  pane_pid="$(tmux -L "$SOCK" display-message -p -t fmtest:0 '#{pane_pid}')"
  pgrep -P "$pane_pid" >/dev/null 2>&1 && break
  sleep 0.1
done
if run status >/dev/null; then
  ok "a pane with a live child reads as alive (dead lock pid ignored)"
else
  fail "a pane child must read as alive"
fi
tmux -L "$SOCK" send-keys -t fmtest:0 C-c

# --- 3. bare shell + dead lock -> dead; revive once, target window only ----
for _ in $(seq 1 50); do
  pane_pid="$(tmux -L "$SOCK" display-message -p -t fmtest:0 '#{pane_pid}')"
  pgrep -P "$pane_pid" >/dev/null 2>&1 || break
  sleep 0.1
done
if run status >/dev/null 2>&1; then
  fail "a bare shell with a dead lock pid must read as dead"
else
  ok "bare shell plus dead lock pid reads as dead"
fi
run check >/dev/null || fail "check on a dead session must revive and exit 0"
wait_for_count 1 && ok "the relaunch command reached the target window" \
  || fail "the relaunch command must reach the target window (got $(revive_count))"
run check >/dev/null || fail "the debounced second check must exit 0"
sleep 0.5
[ "$(revive_count)" = 1 ] && ok "the debounce prevents a second revival" \
  || fail "a second check inside the debounce must not revive again"
if tmux -L "$SOCK" capture-pane -p -t fmtest:1 | grep -q REVIVED; then
  fail "the worker window must never receive the relaunch"
else
  ok "the worker window stays untouched"
fi

# --- 5. missing session is recreated (the reboot path) ---------------------
tmux -L "$SOCK" kill-server 2>/dev/null
rm -f "$HOME_A/state/.totmann-last-restart" "$TMP/revive.log"
run check >/dev/null || fail "check after a server loss must revive and exit 0"
tmux -L "$SOCK" has-session -t fmtest 2>/dev/null && ok "the session is recreated after a reboot" \
  || fail "check must recreate the missing session"
wait_for_count 1 && ok "the recreated session receives the relaunch" \
  || fail "the recreated session must receive the relaunch"

# --- 6. a fleet stop does not block the leadership revival -----------------
FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" set --wortlaut "Alle Heime alles stoppen." >/dev/null
rm -f "$HOME_A/state/.totmann-last-restart" "$TMP/revive.log"
tmux -L "$SOCK" kill-server 2>/dev/null
run check >/dev/null || fail "check under a fleet stop must still revive"
wait_for_count 1 && ok "the fleet stop does not block the leadership revival" \
  || fail "the revival must run under a fleet stop"

# --- fixtures for the boot-vs-day-hang cases (7-9) -------------------------
FAKEROOT="$TMP/fakeroot"
mkdir -p "$FAKEROOT/bin"
cat > "$FAKEROOT/bin/fm-tmux-lib.sh" <<'STUB'
#!/usr/bin/env bash
# test stub: records every call into $FMSTUB_LOG and answers from files in
# ${FMSTUB_DIR:-$TMP/stub-default}; nothing touches real tmux screens.
fmstub_note() { printf '%s\n' "$*" >>"$FMSTUB_LOG"; }
fmstub_answer() { cat "${FMSTUB_DIR:-$TMP/stub-default}/$1" 2>/dev/null; }
fm_pane_busy_state() { fmstub_note "busy:$1"; fmstub_answer busy; }
fm_tmux_composer_state() { fmstub_note "composer:$1"; fmstub_answer composer; }
fm_tmux_submit_core() { fmstub_note "submit:$1:$2"; fmstub_answer verdict; }
STUB
mkdir -p "$TMP/stub-default"
printf 'idle\n' > "$TMP/stub-default/busy"
printf 'empty\n' > "$TMP/stub-default/composer"
printf 'empty\n' > "$TMP/stub-default/verdict"
KICKER="$TMP/kicker-stub"
cat > "$KICKER" <<STUB
#!/usr/bin/env bash
printf 'kicker:%s|%s|%s\n' "\$1" "\$2" "\$3" >>"\${FMSTUB_LOG:?}"
STUB
chmod +x "$KICKER"
NOW=$(date +%s)
BT=$((NOW - 4000)) # the machine booted well over a debounce ago
STAMP_OLD=$((BT - 120))

run_mode() { # run_mode <state-home> <procstat> -> check, boot-capable env
  FM_HOME="$1" FM_ROOT_OVERRIDE="$FAKEROOT" FM_TOTMANN_TMUX="-L $SOCK" \
  FM_TOTMANN_TARGET="fmtest:0" FM_TOTMANN_RELAUNCH_CMD="echo REVIVED-M >> $TMP/revive-mode.log" \
  FM_TOTMANN_NOTIFY="" FM_TOTMANN_DEBOUNCE=60 FM_TOTMANN_READY_SECS=10 \
  FM_TOTMANN_ERGEBNIS_SECS=0 \
  FM_TOTMANN_PROC_STAT="$2" FM_TOTMANN_ANSTOSS="$KICKER" \
  FMSTUB_LOG="${FMSTUB_LOG:-$TMP/mode-stub.log}" \
  "$TOTMANN" check
}

# --- 7. boot newer than the last revival -> one /clear, then the kicker ----
BOOTPS="$TMP/procstat-boot"
printf 'cpu  x\nbtime %d\nintr 0\n' "$BT" > "$BOOTPS"
HOME_M="$TMP/home-mode"
mkdir -p "$HOME_M/state"
printf '%d\n' "$((BT - 100))" > "$HOME_M/state/.totmann-last-restart"
touch -d "@$STAMP_OLD" "$HOME_M/state/.startup-network.timings"
: > "$TMP/mode-stub.log"; rm -f "$TMP/revive-mode.log"
( sleep 0.6; touch "$HOME_M/state/.startup-network.timings" ) & # first digest lands
TOUCHER=$!
if run_mode "$HOME_M" "$BOOTPS" >"$TMP/boot-run.out" 2>&1; then
  ok "the boot revival exits 0"
else
  fail "the boot revival must exit 0: $(cat "$TMP/boot-run.out")"
fi
wait "$TOUCHER" 2>/dev/null || true
grep -q REVIVED-M "$TMP/revive-mode.log" \
  && ok "the boot revival relaunches the seat" \
  || fail "the boot revival must type the relaunch"
[ "$(grep -c '^submit:fmtest:0:/clear$' "$TMP/mode-stub.log")" = 1 ] \
  && ok "the boot path types exactly one /clear" \
  || fail "the boot path must submit exactly one /clear (log: $(tr '\n' ';' < "$TMP/mode-stub.log"))"
grep -q '^warn:' "$TMP/boot-run.out" \
  && fail "a proven boot clear must not warn ($(cat "$TMP/boot-run.out"))" \
  || ok "the proven boot clear stays silent about fallbacks"
SUB_LINE=$(grep -n '^submit:' "$TMP/mode-stub.log" | head -1 | cut -d: -f1)
KICK_LINE=$(grep -n '^kicker:' "$TMP/mode-stub.log" | head -1 | cut -d: -f1)
if [ -n "$SUB_LINE" ] && [ -n "$KICK_LINE" ] && [ "$SUB_LINE" -lt "$KICK_LINE" ]; then
  ok "the /clear is submitted before the kicker is armed"
else
  fail "ordering broken: submit at ${SUB_LINE:-none}, kicker at ${KICK_LINE:-none}"
fi
KICK_REC=$(grep '^kicker:' "$TMP/mode-stub.log" | head -1)
case "$KICK_REC" in
  'kicker:--hintergrund|fmtest:0|'*)
    STAMP_GIVEN=${KICK_REC#'kicker:--hintergrund|fmtest:0|'}
    [ -f "$STAMP_GIVEN" ] && ok "the kicker receives an existing stamp file" \
      || fail "the stamped file $STAMP_GIVEN must exist for the kicker"
    ;;
  *) fail "the kicker must be called as --hintergrund <target> <stamp>, got: $KICK_REC" ;;
esac

# --- 8. day-hang (boot older than the last revival) -> kick without clear --
printf '%d\n' "$((NOW - 120))" > "$HOME_M/state/.totmann-last-restart" # after the boot
SUB_BEFORE=$(grep -c '^submit:' "$TMP/mode-stub.log")
KICK_BEFORE=$(grep -c '^kicker:' "$TMP/mode-stub.log")
run_mode "$HOME_M" "$BOOTPS" >/dev/null 2>&1 || fail "the day-hang revival must exit 0"
[ "$(grep -c '^submit:' "$TMP/mode-stub.log")" = "$SUB_BEFORE" ] \
  && ok "the day-hang path never clears" \
  || fail "the day-hang path must not submit a /clear"
[ "$(grep -c '^kicker:' "$TMP/mode-stub.log")" = "$((KICK_BEFORE + 1))" ] \
  && ok "the day-hang path arms the kicker" \
  || fail "the day-hang path must arm the kicker once"
[ "$(wc -l < "$TMP/revive-mode.log" | tr -d ' ')" = 2 ] \
  && ok "both revivals typed the relaunch" \
  || fail "expected two relaunch lines, got $(cat "$TMP/revive-mode.log")"

# --- 9. digest never arrives -> deadline fallback clears, no hang ----------
HOME_D="$TMP/home-deadline"
mkdir -p "$HOME_D/state"
printf '%d\n' "$((BT - 100))" > "$HOME_D/state/.totmann-last-restart"
OVER="$TMP/stub-overrun"
mkdir -p "$OVER"
printf 'busy\n' > "$OVER/busy"; printf 'pending\n' > "$OVER/composer"; printf 'pending\n' > "$OVER/verdict"
: > "$TMP/dl-stub.log"
DL_OUT=$(FM_HOME="$HOME_D" FM_ROOT_OVERRIDE="$FAKEROOT" FM_TOTMANN_TMUX="-L $SOCK" \
  FM_TOTMANN_TARGET="fmtest:0" FM_TOTMANN_RELAUNCH_CMD="echo REVIVED-D >> $TMP/revive-dl.log" \
  FM_TOTMANN_NOTIFY="" FM_TOTMANN_DEBOUNCE=60 FM_TOTMANN_READY_SECS=2 \
  FM_TOTMANN_ERGEBNIS_SECS=0 \
  FM_TOTMANN_PROC_STAT="$BOOTPS" FM_TOTMANN_ANSTOSS="$KICKER" \
  FMSTUB_LOG="$TMP/dl-stub.log" FMSTUB_DIR="$OVER" \
  "$TOTMANN" check 2>&1) && DL_RC=0 || DL_RC=$?
[ "$DL_RC" = 0 ] && ok "the deadline fallback exits 0 (no hang)" \
  || fail "the deadline fallback must not hang or crash (rc=$DL_RC): $DL_OUT"
grep -q '^submit:fmtest:0:/clear$' "$TMP/dl-stub.log" \
  && ok "the deadline fallback still clears" \
  || fail "the deadline fallback must attempt the /clear"
grep -q '^kicker:' "$TMP/dl-stub.log" \
  && ok "the deadline fallback still arms the kicker" \
  || fail "the deadline fallback must arm the kicker"
printf '%s\n' "$DL_OUT" | grep -q 'warn:' \
  && ok "the unproven clear warns loudly" \
  || fail "an unconfirmed /clear must warn: $DL_OUT"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-totmann.test.sh: all checks passed"
  exit 0
fi
echo "fm-totmann.test.sh: $FAILS check(s) FAILED"
exit 1
