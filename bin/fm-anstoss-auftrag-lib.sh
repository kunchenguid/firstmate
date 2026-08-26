# shellcheck shell=bash
# fm-anstoss-auftrag-lib.sh - the ONE owner of the question a watcher must ask a
# moving lane: WHICH COMMISSIONED POST is this movement about? (Flottenordnung
# v2, rebuild plan step 6, L98: a watcher that only measures motion breeds
# work that looks busy and answers to nobody.)
#
# Usage:
#   . bin/fm-anstoss-auftrag-lib.sh
#   fm_auftrag_check  <id> <meta> <home> <state-dir>   0 = ok, 1 = ALARM
#   fm_auftrag_ladder <id> <detail> <state-dir> <interval-seconds>
#
# WHY A SEPARATE CLASS. The Anstoss-Automat's other two ladders answer "is this
# lane stuck?" and their remedy is a nudge typed into the pane. A lane working
# without a commissioned post is the opposite failure: it is not stuck, it is
# unaccounted for, and typing "keep going" into it would deepen exactly the
# damage. This class therefore NEVER sends anything to the lane; it wakes
# firstmate, who owns the register, and firstmate alone decides.
#
# WHAT COUNTS AS A POST REFERENCE (this header is the single owner):
#   (a) the backlog backend carries the lane's task id as `in_flight`, or
#   (b) the lane's meta carries BOTH `account=` and `spawn_gen=` (the fields a
#       v2 spawn writes) AND its brief $HOME/data/<id>/brief.md carries an
#       `Order-Bezug:` line with a non-empty value.
#   (b) asks whether the brief ANSWERS the order question at all, not which
#   answer it gives: `--order O-xx` and `--no-order-reason <text>` both render
#   that line, and bin/fm-brief.sh owns which answers are acceptable. Reading
#   the brief instead of only the backlog is what lets a fresh v2 spawn work in
#   the window between dispatch and the backlog's own state transition.
#
# TRANSITION RULE (rebuild plan, "Anstoss v2 nur fuer Neu-Spawns"). A lane whose
# meta carries NO `account=` predates v2. It is Bestand and never raises this
# alarm - it produces, ONLY when it also fails (a), exactly ONE inventory line
# naming it as reconciliation work (marker
# state/.anstoss-inventur-<id>, so the next sweep is silent), which is what the
# one-off lane-to-post reconciliation works from. Suppressing the alarm here is
# deliberate: the four standing lanes of the cutover would otherwise wake
# firstmate every sweep for a condition he already knows and has scheduled.
#
# ARMING. Like every gate of this fleet the class checks
# state/.tor-arbeit-ohne-auftrag-scharf before it can raise anything. Missing
# flag = silent pass (the transition state: built, measured, not yet live), but
# the pass is recorded as one gruen Tor-Log line naming `tor-nicht-scharf`, so
# "the gate is off" and "the gate never looked" stay distinguishable (L03).
# The backlog state itself is read BEFORE the flag: it is a pure read, the
# caller needs it for its own in_flight condition and its stage-2 fingerprint,
# and an unarmed gate must not change what the rest of the sweep sees.
#
# TOR-LOG. Gate name `arbeit-ohne-auftrag`, one line per decision that matters:
# rot per raised alarm (with the lane and the counter), warn once per Bestand
# lane (the inventory), gruen when an alarm was withheld because the flag is
# absent. A lane holding a proper post reference logs nothing - healthy state is
# the overwhelming majority and would drown the log.
#
# LADDER. Counter state/.anstoss-auftrag-<id>, clock
# state/.anstoss-auftragzeit-<id>. The first sighting reports immediately (the
# register is wrong NOW), then repeats once per <interval-seconds> while the
# condition persists - the same shape as the O-0018 escalation half, minus every
# typed line. The clock is this class's own, never the shared
# .anstoss-last-<id>: a nudge sent by another ladder must not silence an
# unaccounted lane, and this class's report must not delay a nudge.
#
# The refusal message names its SOURCE and its EXITS, because a wake that only
# says "wrong" makes the reader guess what would be right.

# shellcheck source=bin/fm-tor-log-lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-tor-log-lib.sh"

FM_AUFTRAG_TOR=arbeit-ohne-auftrag

# The LAST value of `key=` in a meta file, or empty. Deliberately local to this
# library (rather than fm_meta_get from bin/fm-backend.sh) so the class can be
# sourced and tested on its own.
fm_auftrag_meta_field() {  # <meta-file> <key>
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Backlog state of <id>, or empty when unreadable. An unreadable premise is
# never resolved toward an alarm: without (a) the class falls through to (b).
fm_auftrag_backlog_state() {  # <id> <home>
  (cd "$2" 2>/dev/null &&
    tasks-axi show "$1" --file "$2/data/backlog.md" 2>/dev/null ||
    true) |
    sed -n 's/^[[:space:]]*state:[[:space:]]*//p' | head -1
}

# The brief's Order-Bezug value, or exit 1 when the brief or the line is absent.
fm_auftrag_brief_order() {  # <id> <home>
  local brief="$2/data/$1/brief.md"
  [ -f "$brief" ] || return 1
  sed -n 's/^[[:space:]]*Order-Bezug:[[:space:]]*//p' "$brief" | head -1 | grep -q '[^[:space:]]'
}

# One inventory sighting per Bestand lane. Sets FM_AUFTRAG_INVENTUR=1 exactly on
# the sweep that first sees the lane, so the CALLER writes the audit line into
# its own check log (bin/fm-anstoss.sh stays the single writer of that file).
fm_auftrag_inventur() {  # <id> <state-dir> <posten-state>
  local marker="$2/.anstoss-inventur-$1"
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_AUFTRAG_INVENTUR=0
  [ -e "$marker" ] && return 0
  date +%Y-%m-%dT%H:%M:%S%z > "$marker" 2>/dev/null || return 0
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_AUFTRAG_INVENTUR=1
  fm_tor_log "$FM_AUFTRAG_TOR" bestand-lane warn uebergangsregel-bestand \
    "id=$1 meta-ohne-account posten=${3:--} einmalige-inventur"
  return 0
}

# The class itself. Returns 1 ONLY for a v2 lane without a post reference while
# the gate is armed; every other outcome returns 0.
#   FM_AUFTRAG_POSTEN    backlog state read for <id> ('' = unreadable)
#   FM_AUFTRAG_VERDICT   ok-in-flight | ok-brief | bestand | tor-nicht-scharf |
#                        ohne-auftrag
#   FM_AUFTRAG_INVENTUR  1 on the sweep that first inventories a Bestand lane
#   FM_AUFTRAG_DETAIL    the loud one-line refusal (source + exits), alarm only
fm_auftrag_check() {  # <id> <meta> <home> <state-dir>
  local id=$1 meta=$2 home=$3 state=$4 konto gen
  FM_AUFTRAG_VERDICT=''
  FM_AUFTRAG_DETAIL=''
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_AUFTRAG_INVENTUR=0
  FM_AUFTRAG_POSTEN=$(fm_auftrag_backlog_state "$id" "$home")

  if [ "$FM_AUFTRAG_POSTEN" = in_flight ]; then
    FM_AUFTRAG_VERDICT=ok-in-flight
    return 0
  fi

  konto=$(fm_auftrag_meta_field "$meta" account)
  gen=$(fm_auftrag_meta_field "$meta" spawn_gen)

  if [ -z "$konto" ]; then
    FM_AUFTRAG_VERDICT=bestand
    fm_auftrag_inventur "$id" "$state" "$FM_AUFTRAG_POSTEN"
    return 0
  fi

  if [ -n "$gen" ] && fm_auftrag_brief_order "$id" "$home"; then
    FM_AUFTRAG_VERDICT=ok-brief
    return 0
  fi

  if [ ! -f "$state/.tor-$FM_AUFTRAG_TOR-scharf" ]; then
    # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
    FM_AUFTRAG_VERDICT='tor-nicht-scharf'
    fm_tor_log "$FM_AUFTRAG_TOR" - gruen tor-nicht-scharf \
      "id=$id posten=${FM_AUFTRAG_POSTEN:--} konto=$konto spawn_gen=${gen:--} alarm-zurueckgehalten"
    return 0
  fi

  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_AUFTRAG_VERDICT=ohne-auftrag
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_AUFTRAG_DETAIL="Bahn $id arbeitet ohne Auftrag: kein Posten-Bezug (Backlog-Zustand: ${FM_AUFTRAG_POSTEN:-unbekannt}, Brief ohne 'Order-Bezug:'-Zeile). Quelle: Flottenordnung v2, Registerordnung - kein arbeitender Posten ohne Auftrag (L98). Auswege: den Posten im Backlog auf in_flight setzen (tasks-axi start $id), ODER data/$id/brief.md eine 'Order-Bezug:'-Zeile geben (bin/fm-brief.sh --order O-xx oder --no-order-reason), ODER die Bahn beenden (bin/fm-teardown.sh $id). Kein Weiter-Anstoss an die Bahn - der Entscheid bleibt bei Firstmate."
  return 1
}

# The report ladder. Prints the wake line for firstmate when the spacing gate
# lets it through; nothing is ever sent to the lane.
#   FM_AUFTRAG_ACTION / FM_AUFTRAG_REASON feed the caller's check log.
fm_auftrag_ladder() {  # <id> <detail> <state-dir> <interval-seconds>
  local id=$1 detail=$2 state=$3 gate=$4 now count last next
  now=$(date +%s)
  count=$(cat "$state/.anstoss-auftrag-$id" 2>/dev/null || echo 0)
  case "$count" in '' | *[!0-9]*) count=0 ;; esac
  last=$(cat "$state/.anstoss-auftragzeit-$id" 2>/dev/null || echo 0)
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  case "$gate" in '' | *[!0-9]*) gate=600 ;; esac

  if [ "$count" -gt 0 ] && [ "$((now - last))" -lt "$gate" ]; then
    FM_AUFTRAG_ACTION=uebersprungen
    FM_AUFTRAG_REASON="spacing-wait-$((now - last))s<${gate}s"
    return 0
  fi

  next=$((count + 1))
  printf '%s\n' "$next" > "$state/.anstoss-auftrag-$id" 2>/dev/null || true
  printf '%s\n' "$now" > "$state/.anstoss-auftragzeit-$id" 2>/dev/null || true
  printf 'anstoss: %s (%d. Meldung)\n' "$detail" "$next"
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_AUFTRAG_ACTION=gemeldet
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_AUFTRAG_REASON="arbeit-ohne-auftrag-$next"
  fm_tor_log "$FM_AUFTRAG_TOR" arbeit-ohne-auftrag rot \
    posten-eintragen-oder-order-bezug-oder-beenden \
    "id=$id meldung=$next posten=${FM_AUFTRAG_POSTEN:--}"
  return 0
}
