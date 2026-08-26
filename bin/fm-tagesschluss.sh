#!/usr/bin/env bash
# fm-tagesschluss.sh - the fleet's daily day close (plan v3 U1.2; captain's word:
# "Ja, der Tageschluss ist ab jetzt pflicht." - EN: the day close is mandatory).
#
# Usage:
#   fm-tagesschluss.sh run             full day close (20:00 timer entry point)
#   fm-tagesschluss.sh vorwarn         set the 19:30 pre-warning marker: no new
#                                      launches tonight (bin/fm-spawn.sh enforces it)
#   fm-tagesschluss.sh morgenpruefung  post-boot morning check; lifts ONLY a
#                                      tagesschluss-origin stop, and only on green;
#                                      runs the write-free backpass analysis pass
#                                      FIRST (bin/fm-backpass-analyse.sh owns its
#                                      mechanics), so accepted-proposal material is
#                                      settled before any home wakes; a backpass
#                                      failure is recorded, never flips the verdict
#   fm-tagesschluss.sh defer --grund "<text>" --bis YYYY-MM-DD   defer the reboot
#   fm-tagesschluss.sh defer --clear
#   fm-tagesschluss.sh status
#   fm-tagesschluss.sh install [--enable]   write the systemd user units
#   fm-tagesschluss.sh --help
#
# run: keeps an existing stop untouched (a captain stop is NEVER overwritten or
# lifted; contract: bin/fm-fleet-stop.sh), else sets the tagesschluss-origin
# stop; waits for every task in state/*.meta to reach a safe halt (crew state
# done|blocked|paused|failed|parked via bin/fm-crew-state.sh; working/unknown
# wait until the timeout - unknown is NOT idle); runs bin/fm-forensik.sh; writes
# the day report; sends the captain a German three-liner via the notifier; then
# reboots the LOCAL machine only when FM_TAGESSCHLUSS_REBOOT=1 (the installed
# timer sets it; nothing else does) and no long-run deferral is registered.
# Remote servers are never touched. A failed forensics run or an unfinished
# halt is recorded as "abschluss=befund: ..." - the morning check then keeps
# the stop and warns the captain instead of lifting.
#
# State and output (this header is the single owner):
#   state/.tagesschluss-vorwarn    line 1 "date=<local %F>"; binding only on that
#                                  date - bin/fm-spawn.sh refuses new launches
#                                  while it names today, and cleans a stale one
#   state/.tagesschluss-langlauf   line 1 "bis=<local %F>", then the reason;
#                                  defers the nightly reboot while today <= bis
#   data/tagesschluss/<date>/bericht.md         the day report; final line
#                                               "abschluss=ok" or "abschluss=befund: ..."
#   data/tagesschluss/<date>/morgenpruefung.md  the morning check's verdict
#   data/tagesschluss/<date>/streichliste.md    bin/fm-streichliste.sh's verbatim
#                                               strike-candidate report
#   (extraktion.tsv, forensik.md, lehren-kandidaten.md are owned by bin/fm-forensik.sh)
#
# Environment: FM_TAGESSCHLUSS_REBOOT (=1 arms the reboot), FM_TAGESSCHLUSS_REBOOT_CMD
# (default "systemctl reboot"), FM_TAGESSCHLUSS_NOTIFY (default claw-notify; "" off),
# FM_TAGESSCHLUSS_STATE_CMD (default bin/fm-crew-state.sh), FM_TAGESSCHLUSS_HALT_TIMEOUT
# (seconds, default 1200), FM_TAGESSCHLUSS_HALT_POLL (default 30),
# FM_TAGESSCHLUSS_UNIT_DIR (default ~/.config/systemd/user), FM_TAGESSCHLUSS_SYSTEMCTL
# (default systemctl), FM_TAGESSCHLUSS_STREICHLISTE_CMD (default bin/fm-streichliste.sh).
#
# run also calls bin/fm-streichliste.sh (the drift-brake strike-candidate
# list, single owner of that report) and writes its output verbatim to
# data/tagesschluss/<date>/streichliste.md - informational only, like the
# backpass pass below: a failure is recorded in bericht.md but never becomes
# a befund and never keeps the day-close stop.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="$FM_HOME/state"
OUT_ROOT="$FM_HOME/data/tagesschluss"
FLEET_STOP="$FM_ROOT/bin/fm-fleet-stop.sh"
FORENSIK="$FM_ROOT/bin/fm-forensik.sh"
NOTIFY="${FM_TAGESSCHLUSS_NOTIFY-claw-notify}"
STATE_CMD="${FM_TAGESSCHLUSS_STATE_CMD:-$FM_ROOT/bin/fm-crew-state.sh}"
HALT_TIMEOUT="${FM_TAGESSCHLUSS_HALT_TIMEOUT:-1200}"
HALT_POLL="${FM_TAGESSCHLUSS_HALT_POLL:-30}"
UNIT_DIR="${FM_TAGESSCHLUSS_UNIT_DIR:-$HOME/.config/systemd/user}"
SYSTEMCTL="${FM_TAGESSCHLUSS_SYSTEMCTL:-systemctl}"

usage() { sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
heute() { date +%F; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

notify_captain() { # best-effort; failure is recorded by the caller, never fatal
  [ -n "$NOTIFY" ] || return 1
  command -v "$NOTIFY" >/dev/null 2>&1 || return 1
  "$NOTIFY" "$1" --prio "${2:-info}" --projekt default >/dev/null 2>&1
}

langlauf_active() {
  [ -f "$STATE/.tagesschluss-langlauf" ] || return 1
  local bis
  bis="$(sed -n '1s/^bis=//p' "$STATE/.tagesschluss-langlauf")"
  [ -n "$bis" ] || return 1
  [ "$(heute)" \> "$bis" ] && return 1
  return 0
}

task_ids() {
  [ -d "$STATE" ] || return 0
  find "$STATE" -maxdepth 1 -name '*.meta' -printf '%f\n' 2>/dev/null | sed 's/\.meta$//' | sort
}

crew_state_of() { # first word after "state: " from the authoritative reader
  "$STATE_CMD" "$1" 2>/dev/null | sed -n '1s/^state: \([a-z-]*\).*/\1/p'
}

cmd="${1:-}"
case "$cmd" in
  run)
    datum="$(heute)"
    out="$OUT_ROOT/$datum"
    mkdir -p "$out"
    befunde=""

    # 1. Stop: never overwrite an existing flag; set our own origin otherwise.
    if "$FLEET_STOP" status >/dev/null 2>&1; then
      stop_origin="$("$FLEET_STOP" origin)"
      stop_note="stop already active (origin=$stop_origin) - left untouched"
    else
      "$FLEET_STOP" set --origin tagesschluss \
        --wortlaut "Tagesschluss $datum 20:00 - automatischer weicher Stopp (Captain-Order: 'Ja, der Tageschluss ist ab jetzt pflicht.')" >/dev/null
      stop_origin="tagesschluss"
      stop_note="tagesschluss stop set"
    fi

    # 2. Safe halt: wait for every recorded task; unknown is NOT idle.
    nicht_still=""
    deadline=$(( $(date +%s) + HALT_TIMEOUT ))
    while :; do
      nicht_still=""
      while IFS= read -r id; do
        [ -n "$id" ] || continue
        s="$(crew_state_of "$id")"
        case "$s" in
          done|blocked|paused|failed|parked) ;;
          *) nicht_still="${nicht_still:+$nicht_still }$id" ;;
        esac
      done < <(task_ids)
      [ -z "$nicht_still" ] && break
      [ "$(date +%s)" -ge "$deadline" ] && break
      sleep "$HALT_POLL"
    done
    if [ -n "$nicht_still" ]; then
      befunde="${befunde:+$befunde; }halt timeout: still working: $nicht_still"
    fi

    # 3. Daily forensics (candidates only; the ledger is never auto-written).
    if FM_HOME="$FM_HOME" "$FORENSIK" run --datum "$datum" >"$out/.forensik.log" 2>&1; then
      forensik_note="forensik ok ($(sed -n '1p' "$out/forensik.md" 2>/dev/null || echo 'report missing'))"
      [ -f "$out/forensik.md" ] || befunde="${befunde:+$befunde; }forensik reported ok but wrote no report"
    else
      forensik_note="forensik FAILED (see $out/.forensik.log)"
      befunde="${befunde:+$befunde; }forensik failed"
    fi

    # 3b. Streichliste (drift-brake report): informational only, never a
    # befund and never blocks the day close - see the file-level comment.
    sl_cmd="${FM_TAGESSCHLUSS_STREICHLISTE_CMD:-$FM_ROOT/bin/fm-streichliste.sh}"
    if [ -x "$sl_cmd" ]; then
      if sl_out="$(FM_HOME="$FM_HOME" "$sl_cmd" 2>&1)"; then
        printf '%s\n' "$sl_out" > "$out/streichliste.md"
        streichliste_note="$out/streichliste.md"
      else
        sl_rc=$?
        printf '%s\n' "$sl_out" > "$out/streichliste.md"
        streichliste_note="FAILED (rc=$sl_rc, see $out/streichliste.md)"
      fi
    else
      streichliste_note="skipped (bin/fm-streichliste.sh not executable)"
    fi

    # 4. Reboot decision.
    if langlauf_active; then
      reboot_note="reboot deferred: registered long run ($(sed -n '2p' "$STATE/.tagesschluss-langlauf" 2>/dev/null))"
      will_reboot="no"
    elif [ "${FM_TAGESSCHLUSS_REBOOT:-}" = "1" ]; then
      reboot_note="rebooting the local machine after the report"
      will_reboot="yes"
    else
      reboot_note="reboot disarmed (FM_TAGESSCHLUSS_REBOOT unset - arming happens with the landed timer)"
      will_reboot="no"
    fi

    # 5. Day report.
    abschluss="ok"
    [ -n "$befunde" ] && abschluss="befund: $befunde"
    {
      echo "# Tagesschluss $datum"
      echo "geschlossen: $(utc_now)"
      echo "stop: $stop_note"
      echo "halt: ${nicht_still:+NOT all halted: $nicht_still}${nicht_still:-all recorded tasks at a safe halt}"
      echo "forensik: $forensik_note"
      echo "streichliste: $streichliste_note"
      echo "reboot: $reboot_note"
      echo "abschluss=$abschluss"
    } > "$out/bericht.md"

    # 6. German three-liner to the captain (his address stays German).
    if [ -z "$befunde" ]; then z1="Tagesschluss $datum: Flotte sauber angehalten."; else z1="Tagesschluss $datum: angehalten MIT Befund ($befunde)."; fi
    z2="Auswertung: $forensik_note"
    if [ "$will_reboot" = "yes" ]; then z3="Der Rechner startet jetzt neu; die Morgenpruefung meldet sich."; else z3="Kein Neustart heute ($reboot_note)."; fi
    if ! notify_captain "$z1
$z2
$z3" "$([ -z "$befunde" ] && echo info || echo warn)"; then
      echo "zustellung: Telegram-Dreizeiler NICHT zugestellt" >> "$out/bericht.md"
    fi

    echo "day close done: $out/bericht.md (abschluss=$abschluss)"
    if [ "$will_reboot" = "yes" ]; then
      ${FM_TAGESSCHLUSS_REBOOT_CMD:-systemctl reboot}
    fi
    ;;
  vorwarn)
    mkdir -p "$STATE"
    printf 'date=%s\n' "$(heute)" > "$STATE/.tagesschluss-vorwarn"
    echo "pre-warning zone set for $(heute): no new launches tonight"
    ;;
  morgenpruefung)
    # 0. Write-free backpass analysis pass, BEFORE anything is lifted or woken.
    backpass_note="backpass: skipped (not executable)"
    bp_cmd="${FM_TAGESSCHLUSS_BACKPASS_CMD:-$FM_ROOT/bin/fm-backpass-analyse.sh}"
    if [ "${FM_TAGESSCHLUSS_BACKPASS:-1}" = "1" ] && [ -x "$bp_cmd" ]; then
      if bp_out="$(FM_HOME="$FM_HOME" "$bp_cmd" run 2>&1)"; then
        backpass_note="$(printf '%s\n' "$bp_out" | sed -n '1p')"
      else
        bp_rc=$?
        backpass_note="backpass: FEHLER (rc=$bp_rc): $(printf '%s\n' "$bp_out" | sed -n '1p')"
      fi
    elif [ "${FM_TAGESSCHLUSS_BACKPASS:-1}" != "1" ]; then
      backpass_note="backpass: ausgeschaltet (FM_TAGESSCHLUSS_BACKPASS=0)"
    fi
    rm -f "$STATE/.tagesschluss-vorwarn"
    letzter="$(find "$OUT_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)"
    verdict=""
    if [ -z "$letzter" ] || [ ! -f "$letzter/bericht.md" ]; then
      verdict="ROT: no day report found under $OUT_ROOT"
    elif ! grep -q '^abschluss=ok$' "$letzter/bericht.md"; then
      verdict="ROT: last day close ended with findings: $(grep '^abschluss=' "$letzter/bericht.md")"
    elif [ ! -f "$letzter/forensik.md" ]; then
      verdict="ROT: forensics report missing in $letzter"
    else
      verdict="GRUEN"
    fi
    lift_note="no stop active"
    if "$FLEET_STOP" status >/dev/null 2>&1; then
      origin="$("$FLEET_STOP" origin)"
      if [ "$origin" != "tagesschluss" ]; then
        lift_note="captain stop stands - not touched (only his word lifts it)"
      elif [ "$verdict" = "GRUEN" ]; then
        "$FLEET_STOP" lift --only-origin tagesschluss >/dev/null
        lift_note="tagesschluss stop lifted"
      else
        lift_note="tagesschluss stop KEPT (verdict not green)"
        notify_captain "Morgenpruefung: der Tagesschluss-Stopp bleibt stehen - $verdict. Ich sehe es mir an; heben nur nach Durchsicht." warn || true
      fi
    fi
    {
      echo "# Morgenpruefung $(heute)"
      echo "geprueft: $(utc_now)"
      echo "verdict: $verdict"
      echo "stop: $lift_note"
      echo "$backpass_note"
    } > "${letzter:-$OUT_ROOT}/morgenpruefung.md" 2>/dev/null || {
      mkdir -p "$OUT_ROOT"
      printf 'verdict: %s\nstop: %s\n' "$verdict" "$lift_note" > "$OUT_ROOT/morgenpruefung-$(heute).md"
    }
    echo "morgenpruefung: $verdict; $lift_note"
    [ "$verdict" = "GRUEN" ] || exit 1
    ;;
  defer)
    shift
    grund="" bis="" clear="no"
    while [ $# -gt 0 ]; do
      case "$1" in
        --grund) grund="${2:-}"; shift 2 ;;
        --bis) bis="${2:-}"; shift 2 ;;
        --clear) clear="yes"; shift ;;
        *) echo "error: unknown argument '$1' for defer" >&2; exit 2 ;;
      esac
    done
    if [ "$clear" = "yes" ]; then
      rm -f "$STATE/.tagesschluss-langlauf"
      echo "long-run deferral cleared"
      exit 0
    fi
    [[ "$bis" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "error: defer requires --bis YYYY-MM-DD" >&2; exit 2; }
    [ -n "${grund//[[:space:]]/}" ] || { echo "error: defer requires --grund with the run being protected" >&2; exit 2; }
    mkdir -p "$STATE"
    printf 'bis=%s\n%s\n' "$bis" "$grund" > "$STATE/.tagesschluss-langlauf"
    echo "reboot deferred until after $bis: $grund"
    ;;
  status)
    echo "vorwarn: $( [ -f "$STATE/.tagesschluss-vorwarn" ] && cat "$STATE/.tagesschluss-vorwarn" || echo none )"
    echo "langlauf: $( [ -f "$STATE/.tagesschluss-langlauf" ] && tr '\n' ' ' < "$STATE/.tagesschluss-langlauf" || echo none )"
    echo "letzter bericht: $(find "$OUT_ROOT" -name bericht.md 2>/dev/null | sort | tail -1 || true)"
    ;;
  install)
    shift || true
    enable="no"
    [ "${1:-}" = "--enable" ] && enable="yes"
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/fm-tagesschluss.service" <<UNIT
[Unit]
Description=Firstmate day close (20:00): soft stop, forensics, report, reboot

[Service]
Type=oneshot
Environment=FM_HOME=$FM_HOME
Environment=FM_TAGESSCHLUSS_REBOOT=1
ExecStart=$FM_ROOT/bin/fm-tagesschluss.sh run
UNIT
    cat > "$UNIT_DIR/fm-tagesschluss.timer" <<UNIT
[Unit]
Description=Firstmate day close at 20:00

[Timer]
OnCalendar=*-*-* 20:00:00
Persistent=false

[Install]
WantedBy=timers.target
UNIT
    cat > "$UNIT_DIR/fm-tagesschluss-vorwarn.service" <<UNIT
[Unit]
Description=Firstmate day-close pre-warning (19:30): no new launches tonight

[Service]
Type=oneshot
Environment=FM_HOME=$FM_HOME
ExecStart=$FM_ROOT/bin/fm-tagesschluss.sh vorwarn
UNIT
    cat > "$UNIT_DIR/fm-tagesschluss-vorwarn.timer" <<UNIT
[Unit]
Description=Firstmate day-close pre-warning at 19:30

[Timer]
OnCalendar=*-*-* 19:30:00
Persistent=false

[Install]
WantedBy=timers.target
UNIT
    echo "units written to $UNIT_DIR (fm-tagesschluss, fm-tagesschluss-vorwarn)"
    if [ "$enable" = "yes" ]; then
      "$SYSTEMCTL" --user daemon-reload
      "$SYSTEMCTL" --user enable --now fm-tagesschluss.timer fm-tagesschluss-vorwarn.timer
      echo "timers enabled"
    else
      echo "not enabled - arm with: $0 install --enable (only after the U2 landing incl. the deadman switch)"
    fi
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
