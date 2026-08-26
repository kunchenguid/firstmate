#!/usr/bin/env bash
# tests/fm-tagesschluss.test.sh - the day close must stop softly, never touch a
# captain stop, report honestly, reboot only when armed, and reopen only on green:
#
#   1. run with an empty fleet sets a tagesschluss-origin stop, writes the day
#      report with abschluss=ok, sends the German three-liner, and does NOT
#      reboot while FM_TAGESSCHLUSS_REBOOT is unset.
#   2. morgenpruefung on that green report lifts the tagesschluss stop.
#   3. run over an existing CAPTAIN stop leaves flag bytes untouched, and the
#      morning check refuses to lift it even on green.
#   4. A task that never reaches a safe halt is recorded as a finding
#      (abschluss=befund), and the morning check then KEEPS the day-close stop.
#   5. With FM_TAGESSCHLUSS_REBOOT=1 the reboot command fires; a registered
#      long-run deferral suppresses it (divergence asserted both ways).
#   6. vorwarn: a same-day marker makes fm-spawn refuse with the pre-warning
#      reason; a stale marker is cleaned and does not block.
#   8. the morning check runs the write-free backpass analysis first; its
#      summary line lands in morgenpruefung.md, and a failing pass is recorded
#      without blocking the green lift.
#   9. install writes the four systemd user units without calling systemctl;
#      --enable calls it.
#
# Isolation: throwaway FM_HOME; notifier, reboot, systemctl, and the crew-state
# reader are shims. Nothing touches the live fleet or the real machine.
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` cannot misfire.
# shellcheck disable=SC2016 # shim bodies intentionally carry a literal "$1".
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS="$REPO/bin/fm-tagesschluss.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_A="$TMP/home"
mkdir -p "$HOME_A/state" "$HOME_A/data" "$TMP/shims" "$TMP/units"
DATUM="$(date +%F)"
OUT="$HOME_A/data/tagesschluss/$DATUM"

printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> %q/notify.log\nexit 0\n' "$TMP" > "$TMP/shims/claw-notify"
printf '#!/usr/bin/env bash\necho reboot >> %q/reboot.log\n' "$TMP" > "$TMP/shims/fake-reboot"
printf '#!/usr/bin/env bash\necho "$*" >> %q/systemctl.log\n' "$TMP" > "$TMP/shims/systemctl-shim"
printf '#!/usr/bin/env bash\necho "state: paused · source: test · shim"\n' > "$TMP/shims/state-paused"
printf '#!/usr/bin/env bash\necho "state: working · source: test · shim"\n' > "$TMP/shims/state-working"
chmod +x "$TMP/shims/"*
PATH="$TMP/shims:$PATH"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }
mkdir -p "$TMP/leere-wurzel"
run_ts() {
  FM_HOME="$HOME_A" FM_TAGESSCHLUSS_STATE_CMD="$TMP/shims/state-paused" \
  FM_TAGESSCHLUSS_HALT_TIMEOUT=1 FM_TAGESSCHLUSS_HALT_POLL=1 \
  FM_TAGESSCHLUSS_REBOOT_CMD="$TMP/shims/fake-reboot" \
  FM_TAGESSCHLUSS_UNIT_DIR="$TMP/units" FM_TAGESSCHLUSS_SYSTEMCTL="$TMP/shims/systemctl-shim" \
  FM_FORENSIK_ROOTS="$TMP/leere-wurzel" \
  FM_TAGESSCHLUSS_BACKPASS="${FM_TAGESSCHLUSS_BACKPASS-0}" \
  "$TS" "$@"
}

# --- 1. plain run: stop set, report ok, three-liner sent, no reboot --------
run_ts run >/dev/null || fail "run must succeed on an empty fleet"
[ "$(FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" origin)" = "tagesschluss" ] \
  && ok "run sets a tagesschluss-origin stop" || fail "run must set a tagesschluss-origin stop"
grep -q '^abschluss=ok$' "$OUT/bericht.md" && ok "the day report closes with abschluss=ok" \
  || fail "an empty clean fleet must close with abschluss=ok"
[ -f "$TMP/notify.log" ] && [ "$(wc -l < "$TMP/notify.log")" = 3 ] \
  && ok "the captain gets exactly the German three-liner" \
  || fail "the notifier must receive a three-line message (got $(wc -l < "$TMP/notify.log" 2>/dev/null || echo 0))"
grep -q Tagesschluss "$TMP/notify.log" || fail "the three-liner must be German and name the day close"
[ ! -f "$TMP/reboot.log" ] && ok "no reboot while FM_TAGESSCHLUSS_REBOOT is unset" \
  || fail "an unarmed run must never reboot"
[ -f "$OUT/streichliste.md" ] && grep -q '^# Streichliste' "$OUT/streichliste.md" \
  && ok "run writes the strike-candidate report via bin/fm-streichliste.sh" \
  || fail "run must write $OUT/streichliste.md via bin/fm-streichliste.sh"
grep -q '^streichliste: ' "$OUT/bericht.md" \
  && ok "the day report names the streichliste step" \
  || fail "bericht.md must note the streichliste step"

# --- 2. green morning check lifts the day-close stop -----------------------
run_ts morgenpruefung >/dev/null || fail "a green morning check must exit 0"
FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" status >/dev/null 2>&1 \
  && fail "the green morning check must lift the tagesschluss stop" \
  || ok "the green morning check lifts the tagesschluss stop"
grep -q 'verdict: GRUEN' "$OUT/morgenpruefung.md" || fail "the morning verdict must be recorded"

# --- 3. a captain stop is never overwritten or lifted ----------------------
FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" set --wortlaut "Alle Heime alles stoppen." >/dev/null
flag_before="$(cat "$HOME_A/state/.fleet-stop")"
run_ts run >/dev/null || fail "run over a captain stop must still succeed"
[ "$(cat "$HOME_A/state/.fleet-stop")" = "$flag_before" ] \
  && ok "run leaves a captain stop byte-identical" || fail "run must not touch a captain stop"
run_ts morgenpruefung >/dev/null || fail "the morning check over a captain stop must still run green"
FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" status >/dev/null 2>&1 \
  && ok "the morning check never lifts a captain stop" \
  || fail "a captain stop must survive the morning check"
FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" lift >/dev/null

# --- 4. an unhalted task becomes a finding and keeps the stop --------------
printf 'window=x\n' > "$HOME_A/state/haenger.meta"
rm -f "$TMP/notify.log"
FM_TAGESSCHLUSS_STATE_CMD="$TMP/shims/state-working" FM_HOME="$HOME_A" \
  FM_TAGESSCHLUSS_HALT_TIMEOUT=1 FM_TAGESSCHLUSS_HALT_POLL=1 \
  FM_FORENSIK_ROOTS="$TMP/leere-wurzel" \
  FM_TAGESSCHLUSS_REBOOT_CMD="$TMP/shims/fake-reboot" "$TS" run >/dev/null \
  || fail "run with an unhalted task must still complete"
grep -q '^abschluss=befund: .*haenger' "$OUT/bericht.md" \
  && ok "an unhalted task is recorded as a finding naming the task" \
  || fail "the halt timeout must become a named finding"
if run_ts morgenpruefung >/dev/null 2>&1; then
  fail "the morning check on a finding must exit nonzero"
else
  ok "the morning check on a finding exits nonzero"
fi
[ "$(FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" origin 2>/dev/null)" = "tagesschluss" ] \
  && ok "the day-close stop is KEPT on a finding" \
  || fail "a finding must keep the day-close stop"
rm -f "$HOME_A/state/haenger.meta"
FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" lift >/dev/null

# --- 5. reboot arming and long-run deferral --------------------------------
FM_TAGESSCHLUSS_REBOOT=1 run_ts run >/dev/null || fail "an armed run must succeed"
[ -f "$TMP/reboot.log" ] && ok "FM_TAGESSCHLUSS_REBOOT=1 fires the reboot command" \
  || fail "an armed run must call the reboot command"
rm -f "$TMP/reboot.log"
FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" lift >/dev/null
run_ts defer --grund "bezahlter Messlauf" --bis "$(date -d '+1 day' +%F)" >/dev/null || fail "defer must register"
FM_TAGESSCHLUSS_REBOOT=1 run_ts run >/dev/null || fail "a deferred run must succeed"
[ ! -f "$TMP/reboot.log" ] && ok "a registered long run suppresses the reboot" \
  || fail "the deferral must suppress the reboot"
grep -q 'deferred' "$OUT/bericht.md" || fail "the deferral must be named in the report"
run_ts defer --clear >/dev/null
FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" lift >/dev/null

# --- 6. pre-warning zone gates new launches, stale markers clean up --------
run_ts vorwarn >/dev/null
spawn_out=$(FM_HOME="$HOME_A" "$REPO/bin/fm-spawn.sh" neu /nowhere 2>&1)
if printf '%s' "$spawn_out" | grep -q "pre-warning zone"; then
  ok "fm-spawn refuses a new launch in the pre-warning zone"
else
  fail "fm-spawn must refuse with the pre-warning reason (got: $spawn_out)"
fi
printf 'date=2020-01-01\n' > "$HOME_A/state/.tagesschluss-vorwarn"
spawn_out2=$(FM_HOME="$HOME_A" "$REPO/bin/fm-spawn.sh" neu /nowhere 2>&1)
if printf '%s' "$spawn_out2" | grep -q "pre-warning zone"; then
  fail "a stale marker must not block launches"
else
  ok "a stale marker does not block (divergent refusal)"
fi
[ ! -f "$HOME_A/state/.tagesschluss-vorwarn" ] && ok "the stale marker is cleaned" \
  || fail "fm-spawn must clean a stale marker"

# --- 8. the morning check runs the write-free backpass pass before lifting --
printf '#!/usr/bin/env bash\necho "stub-run args=$* home=${FM_HOME:-unset}" >> %q/bp-stub.log\necho "backpass: STUB OK"\n' "$TMP" > "$TMP/shims/bp-ok"
printf '#!/usr/bin/env bash\necho "stub exploded" >&2\nexit 7\n' > "$TMP/shims/bp-fail"
chmod +x "$TMP/shims/bp-ok" "$TMP/shims/bp-fail"
rm -f "$TMP/bp-stub.log"

FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" set --origin tagesschluss --wortlaut test >/dev/null
FM_TAGESSCHLUSS_BACKPASS=1 FM_TAGESSCHLUSS_BACKPASS_CMD="$TMP/shims/bp-ok" run_ts morgenpruefung >/dev/null \
  || fail "the morning check with a passing backpass stub must exit 0"
grep -q '^backpass: STUB OK$' "$OUT/morgenpruefung.md" \
  && ok "the template summary line lands in morgenpruefung.md" \
  || fail "morgenpruefung.md must carry the backpass summary line"
grep -q 'args=run' "$TMP/bp-stub.log" && ok "the stub is invoked with the run command" \
  || fail "backpass hook must call the analyse script with 'run'"
FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" status >/dev/null 2>&1 \
  && fail "green verdict with passing backpass must still lift the stop" \
  || ok "green verdict lifts the stop after a passing backpass pass"

FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" set --origin tagesschluss --wortlaut test >/dev/null
run_ts_morgen_with_fail() {
  FM_HOME="$HOME_A" FM_TAGESSCHLUSS_STATE_CMD="$TMP/shims/state-paused" \
  FM_TAGESSCHLUSS_HALT_TIMEOUT=1 FM_TAGESSCHLUSS_HALT_POLL=1 \
  FM_TAGESSCHLUSS_REBOOT_CMD="$TMP/shims/fake-reboot" \
  FM_TAGESSCHLUSS_UNIT_DIR="$TMP/units" FM_TAGESSCHLUSS_SYSTEMCTL="$TMP/shims/systemctl-shim" \
  FM_FORENSIK_ROOTS="$TMP/leere-wurzel" FM_TAGESSCHLUSS_BACKPASS=1 FM_TAGESSCHLUSS_BACKPASS_CMD="$TMP/shims/bp-fail" \
  "$TS" "$@"
}
run_ts_morgen_with_fail morgenpruefung >/dev/null \
  || fail "a failing backpass pass must not block the green morning check"
grep -q '^backpass: FEHLER (rc=7)' "$OUT/morgenpruefung.md" \
  && ok "a failing backpass is recorded as FEHLER with its code" \
  || fail "the failure note must name the return code"
FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" status >/dev/null 2>&1 \
  && fail "a backpass failure must not keep a green day-close stop" \
  || ok "the stop still lifts on green despite the backpass failure"


# --- 9. install writes units; systemctl only with --enable -----------------
run_ts install >/dev/null || fail "install must write the units"
for u in fm-tagesschluss.service fm-tagesschluss.timer fm-tagesschluss-vorwarn.service fm-tagesschluss-vorwarn.timer; do
  [ -f "$TMP/units/$u" ] || fail "install must write $u"
done
[ ! -f "$TMP/systemctl.log" ] && ok "install without --enable never calls systemctl" \
  || fail "plain install must not call systemctl"
run_ts install --enable >/dev/null || fail "install --enable must succeed"
grep -q 'enable --now fm-tagesschluss.timer' "$TMP/systemctl.log" \
  && ok "install --enable arms the timers via systemctl" \
  || fail "install --enable must call systemctl enable"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-tagesschluss.test.sh: all checks passed"
  exit 0
fi
echo "fm-tagesschluss.test.sh: $FAILS check(s) FAILED"
exit 1
