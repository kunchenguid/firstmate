#!/usr/bin/env bash
# fm-brett-antworten.sh - wake path, recording, and receipting for captain
# answers that the captain-brett board delivers into this home's
# data/brett-antworten directory.
#
# The board writes every captain answer as a durable card file named
# <zeit>-<entscheid>-<hash>.md. This script is the receiver side of that
# delivery: it turns new cards into wakes and records wherever recording is
# mechanical, so neither a human nor a memory has to think of it.
#
# Commands:
#   fm-brett-antworten.sh check      scan, record, receipt, report (default)
#   fm-brett-antworten.sh bemerkungen  list the open captain-remark markers
#   fm-brett-antworten.sh bemerkung-erledigt <antwort-id> --vermerk <text>
#                                    record where the remark was routed and retire its marker
#   fm-brett-antworten.sh nachrichten  list the open chat-message markers
#   fm-brett-antworten.sh arm        write and register state/brett-antworten.check.sh
#   fm-brett-antworten.sh disarm     remove the check shim and its trust binding
#   fm-brett-antworten.sh --selftest verify the sources this check needs
#   fm-brett-antworten.sh --help     print this command summary
#
# The full mechanics contract lives in the header block below the commands:
#
# check pipeline:
#   1. A card is pending while quittungen/<id>.json is missing. Receipts are
#      written only by the project's brett-quittung tool and are the
#      processed-marker: a receipted card never fires again, an unreceipted
#      one keeps standing in the wake text until a hand resolves it.
#   2. Card headers are parsed strictly (antwort-id, entscheid, art,
#      gesendet, schonfrist-bis, ersetzt, plus the "Wort des Captains"
#      body). Known arts are the board's wahl, vertagt, zurueckgenommen,
#      and nachricht; anything else, a missing required field, a filename
#      mismatch, or an unparseable timestamp is a loud FEHLER finding on
#      that card, never a silent skip, and the card stays pending. A
#      vertagt or wahl head records its "Wort des Captains" verbatim
#      through the intake; a zurueckgenommen head is receipted as
#      withdrawn and never fed. A nachricht head is the captain's chat:
#      it books nothing anywhere (a message is not a card answer), and
#      its own handling owns step 10 below.
#   3. Cards inside their schonfrist are deferred to a later sweep because
#      the captain may still withdraw them; the deferral horizon is
#      FM_BRETT_ANTWORTEN_GRACE_HORIZON seconds (default 3600). A schonfrist
#      further out than the horizon is itself a loud finding.
#   4. Replacement chains: a card whose ersetzt field names another card
#      makes that other card invalid. Only chain heads are recorded;
#      superseded cards are receipted with an "ersetz durch" vermerk as
#      evidence and never fed. Edges are read from valid cards only; a
#      dangling reference, a duplicate claim on one target, or a circular
#      chain is a loud finding that holds its group back.
#   5. Each head with art wahl is piped to the one keyed-answer intake:
#        printf '%s\t%s\t%s\n' <entscheid> <wort> brett:<antwort-id>
#          | bin/fm-captain-hold.sh answers --source "brett:<antwort-id>"
#      That intake owns every rule about captain-held tasks, replay
#      digests, and close modes; this script maps nothing and closes
#      nothing itself. The omitted fourth keyed-answer field means the
#      default done close; a release-mode answer must be routed by hand
#      like an officer-home answer. A head whose card carries a non-empty
#      "## Bemerkung" body feeds the remark as the intake's fifth field
#      instead, so the booking records it as its own line; a remark-less
#      head keeps the exact three-field line above.
#   6. On "closed:" the card is receipted through the project's
#      brett-quittung with CAPTAIN_BRETT_ANTWORTEN pointed at this home's
#      data/brett-antworten. A crash between feeding and receipting replays
#      safely: the intake's digest match answers "closed:" again and only
#      the missing receipt runs, so no answer block is ever written twice.
#   7. A head the intake skips is classified, never filed silently:
#      no such captain-held task here means the key is looked up in every
#      home listed in data/secondmates.md; an open captain-held row there
#      becomes an offizier meldung with NO foreign-home recording (that
#      stays firstmate/officer hand); anything else stays unbekannt.
#      "already closed" is reported separately, because a newer word for an
#      answered post needs a hand decision before it lands.
#   8. Exactly one line is printed when anything was handled, marked,
#      reported, or failed; every new answer wakes even when fully
#      auto-handled, because the captain spoke. Silence means nothing
#      pending beyond grace deferrals.
#   9. The captain's remark is mandatory cargo (order O-0054: "Mein Freitext
#      ist oft wichtiger als die Antwort. Bitte nimm den zwingend mit.").
#      Before a card with a non-empty "## Bemerkung" body may be consumed,
#      this check secures a durable marker state/brett-bemerkungen/<antwort-id>.md
#      recording entscheid, the collapsed remark, and a verbleib field naming
#      what the sweep did with the card (verbucht, offizier:<name>, unbekannt,
#      schon-geschlossen, nicht-captain-gehalten, zurueckgenommen); a card
#      whose marker cannot be written, or whose remark exceeds 4000 bytes, is
#      held back with a loud FEHLER instead of being booked without its
#      remark. Every open marker keeps standing in the wake line as a leading
#      "bemerkung-vorhanden(<antwort-id>)" token, across restarts and even
#      when nothing else is pending, until a hand routes the remark and
#      retires the marker with
#        fm-brett-antworten.sh bemerkung-erledigt <antwort-id> --vermerk <wohin/wie>
#      which appends the routing note and moves the marker to
#      state/brett-bemerkungen/erledigt/ as durable evidence. `bemerkungen`
#      lists the open markers with their remark text.
#
#  10. A chat message (art nachricht) stays its own open kind until this
#      home answers it: past its schonfrist, the sweep secures a durable
#      marker state/brett-chat-nachrichten/<antwort-id>.md carrying the
#      collapsed message word, and every open marker stands in the wake
#      line as a leading "chat-nachricht(<antwort-id>)" token - never an
#      unbekannt finding, never a captain-hold booking. The marker closes
#      when a format-valid answer file naming the message in its
#      antwort-auf exists under data/chat-antworten/ (format contract:
#      bin/fm-brett-chat-lib.sh; written by bin/fm-brett-chat-antwort.sh):
#      that sweep receipts the card with a "chat-beantwortet" vermerk,
#      retires the marker to erledigt/ with the answer filename as
#      evidence, and reports "chat-beantwortet(<id>)" once. Until then the
#      card keeps nagging like any other unanswered board word.
#      `nachrichten` lists the open message markers with their text.
#
# Paths follow the house overrides: FM_ROOT_OVERRIDE, FM_HOME, and
# FM_STATE_OVERRIDE resolve as in fm-tool-update-check.sh. The brett tool is
# taken from <home>/projects/captain-brett/bin/brett-quittung, falling back to
# PATH, so a fixture home can stand in for tests. CAPTAIN_BRETT_ANTWORTEN is
# always set by this script for its own brett-quittung calls; an ambient value
# is deliberately not inherited, because a stale value is exactly how receipts
# go looking in the wrong directory.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ANTWORTEN="$FM_HOME/data/brett-antworten"
CHAT_ANTWORTEN="$FM_HOME/data/chat-antworten"
SECONDMATES="$FM_HOME/data/secondmates.md"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
BRETT_QUITTUNG="$PROJECTS/captain-brett/bin/brett-quittung"
CAPTAIN_HOLD="$SCRIPT_DIR/fm-captain-hold.sh"
CHECK_ID=brett-antworten
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
GRACE_HORIZON=${FM_BRETT_ANTWORTEN_GRACE_HORIZON:-3600}
MAX_LIST=5
BEMERKUNG_DIR="$STATE/brett-bemerkungen"
BEMERKUNG_DONE_DIR="$BEMERKUNG_DIR/erledigt"
BEMERKUNG_MAX=4000
CHAT_MARKER_DIR="$STATE/brett-chat-nachrichten"
CHAT_MARKER_DONE_DIR="$CHAT_MARKER_DIR/erledigt"
CHAT_WORT_MAX=4000

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-brett-chat-lib.sh
. "$SCRIPT_DIR/fm-brett-chat-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-brett-antworten.sh check     scan data/brett-antworten, record mechanically
                                  recordable answers through the keyed intake,
                                  receipt them on the board, print one line when
                                  the captain's words need attention (default)
  fm-brett-antworten.sh bemerkungen  list open captain-remark markers with their text
  fm-brett-antworten.sh bemerkung-erledigt <antwort-id> --vermerk <text>
                                  record where the remark was routed / how it was
                                  answered, retire the marker to erledigt/
  fm-brett-antworten.sh nachrichten list open chat-message markers with their text
  fm-brett-antworten.sh arm       write and register state/brett-antworten.check.sh
  fm-brett-antworten.sh disarm    remove the check shim and its trust binding
  fm-brett-antworten.sh --selftest  verify the sources this check needs
  fm-brett-antworten.sh --help    print this summary

The full mechanics contract is owned by the header comment of this script.
EOF
}

die_usage() {
  printf 'fm-brett-antworten: %s\n' "$1" >&2
  usage >&2
  exit 2
}

quittung_bin() {
  if [ -x "$BRETT_QUITTUNG" ]; then
    printf '%s\n' "$BRETT_QUITTUNG"
  elif command -v brett-quittung >/dev/null 2>&1; then
    command -v brett-quittung
  else
    return 1
  fi
}

iso_epoch() {  # <timestamp> -> epoch seconds on stdout, nonzero on garbage
  local v
  v=$(printf '%s' "$1" | sed -E 's/[.]([0-9]+)([+-][0-9]{2}:?[0-9]{2}|Z)$/\2/')
  date -d "$v" +%s 2>/dev/null
}

# --- findings ----------------------------------------------------------------
# Counters plus capped id lists keep the printed line bounded.

N_VERBUCHT=0 L_VERBUCHT=
N_ERSATZ=0 L_ERSATZ=
N_ZURUECK=0 L_ZURUECK=
N_OFFIZIER=0 L_OFFIZIER=
N_UNBEKANNT=0 L_UNBEKANNT=
N_GESCHLOSSEN=0 L_GESCHLOSSEN=
N_BEMERKUNG=0 L_BEMERKUNG=
N_CHAT=0 L_CHAT=
N_CHAT_ZU=0 L_CHAT_ZU=
F_FEHLER=

list_add() {  # <L-var> <N-var> <token>
  local lv=$1 nv=$2 token=$3 cur n
  cur=${!lv:-}
  case " $cur " in
    *" $token "*) return 0 ;;
  esac
  n=$(printf '%s' "${!nv:-0}")
  case $cur in
    '') ;;
    *) [ "$(printf '%s' "$cur" | wc -w)" -ge "$MAX_LIST" ] && return 0 ;;
  esac
  printf -v "$lv" '%s%s%s' "$cur" "${cur:+ }" "$token"
  printf -v "$nv" '%s' "$((n + 1))"
}

fehler_add() {
  local text=$1
  case " $F_FEHLER " in
    *" $text "*) return 0 ;;
  esac
  printf -v F_FEHLER '%s%s%s' "$F_FEHLER" "${F_FEHLER:+ }" "$text"
}

# Every still-open remark marker keeps standing in the wake line, whatever
# else the sweep found, so the supervising firstmate cannot treat the answer
# as fully handled while the captain's free text is unrouted (order O-0054).
scan_open_bemerkungen() {
  local f
  [ -d "$BEMERKUNG_DIR" ] || return 0
  for f in "$BEMERKUNG_DIR"/*.md; do
    [ -f "$f" ] || continue
    list_add L_BEMERKUNG N_BEMERKUNG "$(basename "${f%.md}")"
  done
}

# Every still-open chat-message marker keeps standing in the wake line the
# same way (header step 10): an unanswered message is an open conversational
# turn, whatever else the sweep found.
scan_open_chat_nachrichten() {
  local f
  [ -d "$CHAT_MARKER_DIR" ] || return 0
  for f in "$CHAT_MARKER_DIR"/*.md; do
    [ -f "$f" ] || continue
    list_add L_CHAT N_CHAT "$(basename "${f%.md}")"
  done
}

summary_line() {
  local out=brett-antworten
  scan_open_chat_nachrichten
  scan_open_bemerkungen
  [ "$N_CHAT" -gt 0 ] && out+=" $N_CHAT chat-nachricht(${L_CHAT// /,});"
  [ "$N_BEMERKUNG" -gt 0 ] && out+=" $N_BEMERKUNG bemerkung-vorhanden(${L_BEMERKUNG// /,});"
  [ "$N_VERBUCHT" -gt 0 ] && out+=" $N_VERBUCHT verbucht(${L_VERBUCHT// /,});"
  [ "$N_ERSATZ" -gt 0 ] && out+=" $N_ERSATZ als ersetzt markiert(${L_ERSATZ// /,});"
  [ "$N_CHAT_ZU" -gt 0 ] && out+=" $N_CHAT_ZU chat-beantwortet(${L_CHAT_ZU// /,});"
  [ "$N_ZURUECK" -gt 0 ] && out+=" $N_ZURUECK zurueckgenommen(${L_ZURUECK// /,});"
  [ "$N_OFFIZIER" -gt 0 ] && out+=" offizier-nicht-verbucht(${L_OFFIZIER// /,});"
  [ "$N_UNBEKANNT" -gt 0 ] && out+=" unbekannt(${L_UNBEKANNT// /,});"
  [ "$N_GESCHLOSSEN" -gt 0 ] && out+=" schon-geschlossen(${L_GESCHLOSSEN// /,});"
  [ -n "$F_FEHLER" ] && out+=" FEHLER($F_FEHLER);"
  [ "$out" != brett-antworten ] && printf '%s\n' "$out"
  return 0
}

# --- officer-home lookup ------------------------------------------------------

officer_name_for_key() {  # <key> -> secondmate name on stdout, nonzero if none
  local key=$1 line name home backlog
  [ -f "$SECONDMATES" ] || return 1
  while IFS= read -r line; do
    case $line in
      -*" (home: "*) ;;
      *) continue ;;
    esac
    name=${line%% - *}
    name=${name#- }
    home=${line#*"(home: "}
    home=${home%%;*}
    case $home in
      /*) ;;
      *) continue ;;
    esac
    backlog=$home/data/backlog.md
    [ -f "$backlog" ] || continue
    if awk -v k="$key" \
      'index($0, "- [ ] " k " ") == 1 && index($0, "(hold-kind: captain)") > 0 { f = 1 }
       END { exit !f }' "$backlog"; then
      printf '%s\n' "$name"
      return 0
    fi
  done < "$SECONDMATES"
  return 1
}

# --- card parsing -------------------------------------------------------------
# Parsed fields land in C_* variables; parse_card returns nonzero with C_ERR
# set when the card is malformed enough to refuse processing it.

C_FILE='' C_ID='' C_KEY='' C_ART='' C_SENT='' C_GRACE='' C_REPL=''
C_WORT='' C_BEM='' C_EPOCH='' C_GRACE_EP='' C_ERR=''

card_field() {  # <file> <field-name> -> value on stdout ("-" stands for empty)
  awk -v f="$2" '
    /^## / { exit }
    index($0, f ": ") == 1 { sub("^" f ": ", ""); print; exit }
  ' "$1"
}

card_wort() {  # <file> -> body of "## Wort des Captains" until the next heading
  awk '
    /^## / {
      if (inw) { exit }
      if ($0 ~ /^## Wort des Captains/) { inw = 1 }
      next
    }
    inw { sub(/\r$/, ""); gsub(/\t/, " "); gsub(/^[ \t]+|[ \t]+$/, ""); if ($0 != "" && buf != "") buf = buf " "; buf = buf $0 }
    END { gsub(/ +/, " ", buf); print buf }
  ' "$1"
}

card_bemerkung() {  # <file> -> body of "## Bemerkung" until the next heading
  awk '
    /^## / {
      if (inb) { exit }
      if ($0 ~ /^## Bemerkung/) { inb = 1 }
      next
    }
    inb { sub(/\r$/, ""); gsub(/\t/, " "); gsub(/^[ \t]+|[ \t]+$/, ""); if ($0 != "" && buf != "") buf = buf " "; buf = buf $0 }
    END { gsub(/ +/, " ", buf); print buf }
  ' "$1"
}

parse_card() {  # <file>
  C_FILE=$1
  C_ID='' C_KEY='' C_ART='' C_SENT='' C_GRACE='' C_REPL=''
  C_WORT='' C_BEM='' C_EPOCH='' C_GRACE_EP='' C_ERR=''
  local stem base
  base=$(basename "$C_FILE")
  stem=${base%.md}
  C_ID=$(card_field "$C_FILE" antwort-id)
  C_KEY=$(card_field "$C_FILE" entscheid)
  C_ART=$(card_field "$C_FILE" art)
  C_SENT=$(card_field "$C_FILE" gesendet)
  C_GRACE=$(card_field "$C_FILE" schonfrist-bis)
  C_REPL=$(card_field "$C_FILE" ersetzt)
  C_WORT=$(card_wort "$C_FILE")
  C_BEM=$(card_bemerkung "$C_FILE")
  # The board writes "-" for an empty field elsewhere on the card; an absent
  # section and a lone dash both mean the captain left no remark.
  [ "$C_BEM" != - ] || C_BEM=
  if [ "$stem" != "$C_ID" ]; then
    C_ERR="datei-heisst-anders-als-$C_ID"
    return 1
  fi
  case $C_KEY in
    '' | *[!a-z0-9-]* ) C_ERR="entscheid-unlesbar"; return 1 ;;
  esac
  case $C_ART in
    wahl | vertagt | zurueckgenommen | nachricht) ;;
    *) C_ERR="unbekannte-art-$C_ART"; return 1 ;;
  esac
  C_EPOCH=$(iso_epoch "$C_SENT")
  case $C_EPOCH in
    '' | *[!0-9]* ) C_ERR="gesendet-unlesbar"; return 1 ;;
  esac
  case $C_GRACE in
    '' | -) C_GRACE_EP= ;;
    *)
      C_GRACE_EP=$(iso_epoch "$C_GRACE")
      case $C_GRACE_EP in
        '' | *[!0-9]* ) C_ERR="schonfrist-unlesbar"; return 1 ;;
      esac
      ;;
  esac
  case $C_REPL in
    '' | -) C_REPL= ;;
    *)
      case $C_REPL in
        # Real antwort-id values carry the uppercase T of their ISO time
        # prefix, so the reference accepts exactly that alphabet.
        *[!A-Za-z0-9-]*) C_ERR="ersetz-verweis-unlesbar"; return 1 ;;
      esac
      ;;
  esac
  if [ "$C_ART" != zurueckgenommen ] && [ -z "$(printf '%s' "$C_WORT" | tr -d '[:space:]')" ]; then
    C_ERR="wort-des-captains-fehlt"
    return 1
  fi
  return 0
}

# --- board receipt ------------------------------------------------------------

receipt_card() {  # <antwort-id> <vermerk> -> nonzero leaves the card nagging
  local id=$1 vermerk=$2 bin
  bin=$(quittung_bin) || {
    fehler_add "brett-quittung-fehlt"
    return 1
  }
  if ! CAPTAIN_BRETT_ANTWORTEN="$ANTWORTEN" "$bin" \
    "$id" --von firstmate --vermerk "$vermerk" >/dev/null 2>&1; then
    fehler_add "quittung-scheitert-$id"
    return 1
  fi
  [ -f "$ANTWORTEN/quittungen/$id.json" ] || {
    fehler_add "quittung-unbelegt-$id"
    return 1
  }
  return 0
}

# --- captain-remark markers ---------------------------------------------------
# Contract: header step 9. The marker is written BEFORE the card may be
# consumed, so no crash window can receipt a card and lose its remark.

bemerkung_marker_path() { printf '%s/%s.md\n' "$BEMERKUNG_DIR" "$1"; }
bemerkung_done_path() { printf '%s/%s.md\n' "$BEMERKUNG_DONE_DIR" "$1"; }

bemerkung_marker_ensure() {  # <antwort-id> <entscheid> <bemerkung>
  local id=$1 key=$2 bem=$3 dest tmp
  dest=$(bemerkung_marker_path "$id")
  [ ! -f "$dest" ] || return 0
  [ ! -f "$(bemerkung_done_path "$id")" ] || return 0
  (umask 077; mkdir -p "$BEMERKUNG_DIR") || return 1
  [ -d "$BEMERKUNG_DIR" ] && [ ! -L "$BEMERKUNG_DIR" ] || return 1
  tmp=$(umask 077; mktemp "$BEMERKUNG_DIR/.marker.XXXXXX" 2>/dev/null) || return 1
  if ! {
    printf 'schema: fm-brett-bemerkung.v1\n'
    printf 'antwort-id: %s\n' "$id"
    printf 'entscheid: %s\n' "$key"
    printf 'verbleib: offen\n'
    printf 'angelegt: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'bemerkung: %s\n' "$bem"
  } > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# Best-effort verbleib rewrite on an OPEN marker; a retired marker stays as
# the hand resolved it. Failure is reported loudly by the caller.
bemerkung_marker_verbleib() {  # <antwort-id> <verbleib>
  local id=$1 verbleib=$2 dest tmp
  dest=$(bemerkung_marker_path "$id")
  [ -f "$dest" ] || return 0
  tmp=$(umask 077; mktemp "$BEMERKUNG_DIR/.marker.XXXXXX" 2>/dev/null) || return 1
  if ! awk -v v="$verbleib" '/^verbleib: /{ print "verbleib: " v; next } { print }' \
    "$dest" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
  return 0
}

bem_mark() {  # <antwort-id> <bemerkung> <verbleib>; loud on a failed rewrite
  [ -n "$2" ] || return 0
  bemerkung_marker_verbleib "$1" "$3" || fehler_add "bemerkung-verbleib-$1"
  return 0
}

# --- chat-message markers ------------------------------------------------------
# Contract: header step 10. Same durability shape as the captain-remark
# markers: written BEFORE anything else may treat the message as handled, and
# closed only by a format-valid answer file (never by a hand command).

chat_marker_path() { printf '%s/%s.md\n' "$CHAT_MARKER_DIR" "$1"; }
chat_marker_done_path() { printf '%s/%s.md\n' "$CHAT_MARKER_DONE_DIR" "$1"; }

chat_marker_ensure() {  # <antwort-id> <wort>
  local id=$1 wort=$2 dest tmp
  dest=$(chat_marker_path "$id")
  [ ! -f "$dest" ] || return 0
  [ ! -f "$(chat_marker_done_path "$id")" ] || return 0
  (umask 077; mkdir -p "$CHAT_MARKER_DIR") || return 1
  [ -d "$CHAT_MARKER_DIR" ] && [ ! -L "$CHAT_MARKER_DIR" ] || return 1
  tmp=$(umask 077; mktemp "$CHAT_MARKER_DIR/.nachricht.XXXXXX" 2>/dev/null) || return 1
  if ! {
    printf 'schema: fm-brett-chat-nachricht.v1\n'
    printf 'antwort-id: %s\n' "$id"
    printf 'verbleib: offen\n'
    printf 'angelegt: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'wort: %s\n' "$wort"
  } > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
  return 0
}

chat_marker_close() {  # <antwort-id> <antwortdatei>; nonzero leaves the marker open
  local id=$1 datei=$2 src dest tmp
  src=$(chat_marker_path "$id")
  [ -f "$src" ] || return 0
  (umask 077; mkdir -p "$CHAT_MARKER_DONE_DIR") || return 1
  tmp=$(umask 077; mktemp "$CHAT_MARKER_DIR/.nachricht.XXXXXX" 2>/dev/null) || return 1
  if ! {
    cat "$src"
    printf 'beantwortet: %s\n' "$datei"
    printf 'erledigt: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  } > "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$(chat_marker_done_path "$id")"; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$src"
  return 0
}

# --- the check ----------------------------------------------------------------

action_check() {
  local f id key bem e line reason off now rest verdict src tgt antwortdatei
  local -A valid_seen=() file_of=() is_pending=() replaced_by=() hold_back=()
  local -a all_files=() good=() sorted=()

  # Open remark markers outlive their receipted cards, so even a sweep with
  # nothing on the board must still print them (summary_line scans them).
  [ -d "$ANTWORTEN" ] || { summary_line; return 0; }
  for f in "$ANTWORTEN"/*.md; do
    [ -e "$f" ] || continue
    all_files+=("$f")
  done
  [ "${#all_files[@]}" -gt 0 ] || { summary_line; return 0; }

  # Pass 1: parse every file. A malformed PENDING card is a loud finding that
  # stays pending; a malformed receipted card is settled history and stays
  # quiet. Parseable cards contribute their replacement edge whether or not
  # their own receipt already ran, because a late-arriving card superseded by
  # an already-recorded answer must be marked as evidence, never fed.
  for f in ${all_files[@]+"${all_files[@]}"}; do
    id=$(basename "${f%.md}")
    if ! parse_card "$f"; then
      if [ ! -f "$ANTWORTEN/quittungen/$id.json" ]; then
        fehler_add "$id:${C_ERR}"
      fi
      continue
    fi
    valid_seen[$C_ID]=1
    file_of[$C_ID]=$f
    if [ ! -f "$ANTWORTEN/quittungen/$C_ID.json" ]; then
      is_pending[$C_ID]=1
      good+=("$f")
    fi
  done
  # Nothing feedable must not swallow loud findings from pass 1: a sweep whose
  # only card is malformed still has to print its FEHLER line.
  [ "${#good[@]}" -gt 0 ] || { summary_line; return 0; }

  # Pass 2: validate replacement edges among parseable cards.
  for id in "${!valid_seen[@]}"; do
    parse_card "${file_of[$id]}" || continue
    src=$id
    tgt=$C_REPL
    [ -n "$tgt" ] || continue
    if [ "$tgt" = "$src" ]; then
      if [ -n "${is_pending[$src]:-}" ]; then
        fehler_add "$src:ersetz-kreis-auf-sich-selbst"
        hold_back[$src]=1
      fi
      continue
    fi
    if [ -z "${valid_seen[$tgt]:-}" ]; then
      if [ -n "${is_pending[$src]:-}" ]; then
        fehler_add "$src:ersetz-verweis-fehlt-$tgt"
        hold_back[$src]=1
      fi
      continue
    fi
    if [ -n "${replaced_by[$tgt]:-}" ] && [ "${replaced_by[$tgt]}" != "$src" ]; then
      if [ -n "${is_pending[$src]:-}" ] || [ -n "${is_pending[${replaced_by[$tgt]}]:-}" ]; then
        fehler_add "doppelte-ersetz-behaupterung-$tgt"
      fi
      hold_back[$src]=1
      hold_back[${replaced_by[$tgt]}]=1
      hold_back[$tgt]=1
      continue
    fi
    replaced_by[$tgt]=$src
  done

  # Pass 3: circular chains would circle forever and must never resolve
  # silently; every PENDING member of a walked cycle is held back loudly,
  # while a cycle wholly among settled receipts stays quiet like any other
  # settled history.
  for f in ${good[@]+"${good[@]}"}; do
    parse_card "$f" || continue
    id=$C_ID
    local -A walked=()
    local c pend
    pend=
    while :; do
      if [ -n "${walked[$id]:-}" ]; then
        for c in "${!walked[@]}"; do
          if [ -n "${is_pending[$c]:-}" ]; then
            pend=1
            hold_back[$c]=1
          fi
        done
        [ -n "$pend" ] && fehler_add "ersetz-kette-kreist-$id"
        break
      fi
      walked[$id]=1
      id=${replaced_by[$id]:-}
      [ -n "$id" ] || break
      [ -z "${hold_back[$id]:-}" ] || break
    done
  done

  # Pass 4: feed chain heads, oldest first, and classify whatever the intake
  # refuses. Cards still inside their schonfrist are deferred to a later sweep.
  for f in ${good[@]+"${good[@]}"}; do
    parse_card "$f" || continue
    [ -z "${hold_back[$C_ID]:-}" ] || continue
    [ -z "${replaced_by[$C_ID]:-}" ] || continue
    sorted+=("${C_EPOCH}_$C_ID")
  done
  for e in $(printf '%s\n' ${sorted[@]+"${sorted[@]}"} | sort); do
    parse_card "${file_of[${e#*_}]}" || continue
    id=$C_ID
    key=$C_KEY
    bem=$C_BEM
    now=$(date +%s)
    if [ -n "$C_GRACE_EP" ] && [ "$C_GRACE_EP" -gt "$now" ]; then
      rest=$((C_GRACE_EP - now))
      if [ "$rest" -le "$GRACE_HORIZON" ]; then
        continue  # the captain can still withdraw it; a later sweep owns it
      fi
      fehler_add "$id:schonfrist-zu-weit-in-der-zukunft"
      continue
    fi
    # Header step 10: the captain's chat is its own kind. It books nothing
    # (a message is not a card answer), stands as chat-nachricht until an
    # answer file closes it, and receipts only as answered.
    if [ "$C_ART" = nachricht ]; then
      antwortdatei=$(chat_antwort_fuer "$CHAT_ANTWORTEN" "$id")
      if [ -n "$antwortdatei" ]; then
        # Secure the evidence marker even on the fast path (answer arrived
        # before the first sweep), then close it BEFORE receipting: if any
        # step is interrupted the card stays pending and replays into this
        # same branch, while the reverse order could strand a closed marker
        # beside a card that never stopped nagging.
        if ! chat_marker_ensure "$id" "$C_WORT" \
          || ! chat_marker_close "$id" "$antwortdatei"; then
          fehler_add "chat-marker-abschluss-$id"
          continue
        fi
        if receipt_card "$id" "chat-beantwortet durch fm-brett-chat-antwort"; then
          list_add L_CHAT_ZU N_CHAT_ZU "$id"
        fi
        continue
      fi
      if [ "$(printf '%s' "$C_WORT" | wc -c | tr -d ' ')" -gt "$CHAT_WORT_MAX" ]; then
        fehler_add "$id:chat-wort-zu-lang"
        continue
      fi
      if ! chat_marker_ensure "$id" "$C_WORT"; then
        fehler_add "$id:chat-marker-scheitert"
        continue
      fi
      list_add L_CHAT N_CHAT "$id"
      continue
    fi
    # Order O-0054: the remark marker must exist before the card may be
    # consumed; a card that cannot secure it stays pending and nags loudly.
    if [ -n "$bem" ]; then
      if [ "$(printf '%s' "$bem" | wc -c | tr -d ' ')" -gt "$BEMERKUNG_MAX" ]; then
        fehler_add "$id:bemerkung-zu-lang"
        continue
      fi
      if ! bemerkung_marker_ensure "$id" "$key" "$bem"; then
        fehler_add "$id:bemerkung-marker-scheitert"
        continue
      fi
    fi
    if [ "$C_ART" = zurueckgenommen ]; then
      if receipt_card "$id" "zurueckgenommen"; then
        list_add L_ZURUECK N_ZURUECK "$id"
        bem_mark "$id" "$bem" zurueckgenommen
      fi
      continue
    fi
    local out
    if [ -n "$bem" ]; then
      out=$(printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$C_WORT" "brett:$id" '' "$bem" |
        FM_HOME="$FM_HOME" "$CAPTAIN_HOLD" answers --source "brett:$id" 2>&1)
    else
      out=$(printf '%s\t%s\t%s\n' "$key" "$C_WORT" "brett:$id" |
        FM_HOME="$FM_HOME" "$CAPTAIN_HOLD" answers --source "brett:$id" 2>&1)
    fi
    verdict=
    while IFS= read -r line; do
      case $line in
        "closed: "*) verdict=closed ;;
        "skipped: "*) [ -n "$verdict" ] || verdict=skipped ;;
      esac
    done <<< "$out"
    if [ "$verdict" = closed ]; then
      if receipt_card "$id" "automatisch verbucht durch fm-brett-antworten"; then
        list_add L_VERBUCHT N_VERBUCHT "$id"
        bem_mark "$id" "$bem" verbucht
      fi
      continue
    fi
    if [ "$verdict" != skipped ]; then
      fehler_add "intake-antwort-unlesbar-$id"
      continue
    fi
    reason=$(printf '%s\n' "$out" | sed -n 's/^skipped: .* (\(.*\))$/\1/p' | head -1)
    case $reason in
      'no captain-held task with that id' | absent)
        if off=$(officer_name_for_key "$key"); then
          list_add L_OFFIZIER N_OFFIZIER "$key@$off"
          bem_mark "$id" "$bem" "offizier:$off"
        else
          list_add L_UNBEKANNT N_UNBEKANNT "$id"
          bem_mark "$id" "$bem" unbekannt
        fi
        ;;
      'already closed')
        list_add L_GESCHLOSSEN N_GESCHLOSSEN "$id"
        bem_mark "$id" "$bem" schon-geschlossen
        ;;
      'not held for the captain')
        list_add L_UNBEKANNT N_UNBEKANNT "$id:nicht-captain-gehalten"
        bem_mark "$id" "$bem" nicht-captain-gehalten
        ;;
      *)
        list_add L_UNBEKANNT N_UNBEKANNT \
          "$id:$(printf '%s' "$reason" | tr -c 'a-z0-9' '-')"
        bem_mark "$id" "$bem" unbekannt
        ;;
    esac
  done

  # Pass 5: mark superseded cards as evidence on the board, but only on the
  # word of a replacement claim that was itself trusted this sweep.
  for f in ${good[@]+"${good[@]}"}; do
    parse_card "$f" || continue
    [ -z "${hold_back[$C_ID]:-}" ] || continue
    src=${replaced_by[$C_ID]:-}
    [ -n "$src" ] || continue
    [ -z "${hold_back[$src]:-}" ] || continue
    if receipt_card "$C_ID" "ersetz durch $src"; then
      list_add L_ERSATZ N_ERSATZ "$C_ID"
    fi
  done

  summary_line
  return 0
}

# --- remark hand commands -----------------------------------------------------

action_bemerkungen() {
  local f id key verbleib bem found=
  if [ -d "$BEMERKUNG_DIR" ]; then
    for f in "$BEMERKUNG_DIR"/*.md; do
      [ -f "$f" ] || continue
      found=1
      id=$(sed -n 's/^antwort-id: //p' "$f" | head -1)
      key=$(sed -n 's/^entscheid: //p' "$f" | head -1)
      verbleib=$(sed -n 's/^verbleib: //p' "$f" | head -1)
      bem=$(sed -n 's/^bemerkung: //p' "$f" | head -1)
      printf 'offen: %s [%s] verbleib=%s\n  %s\n' \
        "${id:-$(basename "${f%.md}")}" "${key:--}" "${verbleib:--}" "${bem:--}"
    done
  fi
  [ -n "$found" ] || printf 'keine offenen Bemerkungen\n'
  return 0
}

action_bemerkung_erledigt() {
  local id=${1:-} vermerk='' src dest tmp
  [ "$#" -ge 1 ] || die_usage "bemerkung-erledigt braucht eine antwort-id"
  shift
  while [ "$#" -gt 0 ]; do
    case $1 in
      --vermerk) shift; vermerk=${1:-} ;;
      *) die_usage "unknown bemerkung-erledigt argument: $1" ;;
    esac
    shift
  done
  case $id in
    '' | *[!A-Za-z0-9-]*) die_usage "antwort-id unlesbar: $id" ;;
  esac
  [ -n "$vermerk" ] || die_usage "--vermerk '<wohin geroutet / wie beantwortet>' ist Pflicht"
  src=$(bemerkung_marker_path "$id")
  dest=$(bemerkung_done_path "$id")
  if [ ! -f "$src" ]; then
    if [ -f "$dest" ]; then
      printf 'schon erledigt: %s\n' "$id"
      return 0
    fi
    printf 'fm-brett-antworten: keine offene Bemerkung %s\n' "$id" >&2
    return 1
  fi
  (umask 077; mkdir -p "$BEMERKUNG_DONE_DIR") || {
    printf 'fm-brett-antworten: kann %s nicht anlegen\n' "$BEMERKUNG_DONE_DIR" >&2
    return 1
  }
  tmp=$(umask 077; mktemp "$BEMERKUNG_DIR/.marker.XXXXXX" 2>/dev/null) || {
    printf 'fm-brett-antworten: kann den Vermerk nicht anlegen\n' >&2
    return 1
  }
  if ! {
    cat "$src"
    printf 'erledigt: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'vermerk: %s\n' "$(printf '%s' "$vermerk" | tr '\n\r\t' '   ')"
  } > "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    printf 'fm-brett-antworten: kann den Vermerk nicht schreiben\n' >&2
    return 1
  fi
  rm -f -- "$src"
  printf 'erledigt: %s\n' "$id"
  return 0
}

# --- chat-message listing -----------------------------------------------------

action_nachrichten() {
  local f id verbleib wort found=
  if [ -d "$CHAT_MARKER_DIR" ]; then
    for f in "$CHAT_MARKER_DIR"/*.md; do
      [ -f "$f" ] || continue
      found=1
      id=$(sed -n 's/^antwort-id: //p' "$f" | head -1)
      verbleib=$(sed -n 's/^verbleib: //p' "$f" | head -1)
      wort=$(sed -n 's/^wort: //p' "$f" | head -1)
      printf 'offen: %s verbleib=%s\n  %s\n' \
        "${id:-$(basename "${f%.md}")}" "${verbleib:--}" "${wort:--}"
    done
  fi
  [ -n "$found" ] || printf 'keine offenen Chat-Nachrichten\n'
  return 0
}

# --- arm / disarm -------------------------------------------------------------
# Mirrors fm-tool-update-check.sh: guards run before anything is written, bytes
# arrive by rename, and a failed or interrupted arm never leaves a shim without
# its trust binding, because an unregistered shim is rejected loudly on every
# watcher cycle instead of being inert.

SHIM_WRITE_TMP=
ARM_BACKUP=

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-brett-antworten.sh - captain board answer poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-brett-antworten.sh") check"
}

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-brett-antworten-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-brett-antworten-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

arm_interrupted() {
  arm_rollback
  printf 'fm-brett-antworten: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'fm-brett-antworten: python3 is missing, receipts could never run\n' >&2
    return 1
  fi
  if ! quittung_bin >/dev/null; then
    printf 'fm-brett-antworten: no executable brett-quittung under %s\n' "$BRETT_QUITTUNG" >&2
    return 1
  fi
  if [ ! -x "$CAPTAIN_HOLD" ]; then
    printf 'fm-brett-antworten: %s is missing\n' "$CAPTAIN_HOLD" >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  case $FM_HOME in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-brett-antworten: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-brett-antworten: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-brett-antworten: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-brett-antworten: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_selftest() {
  local ok=1 home
  [ -x "$CAPTAIN_HOLD" ] || { echo "SELFTEST FAIL: $CAPTAIN_HOLD fehlt"; ok=0; }
  if command -v python3 >/dev/null 2>&1; then
    if bin=$(quittung_bin); then
      echo "SELFTEST OK: brett-quittung unter $bin"
    else
      echo "SELFTEST FAIL: kein ausfuehrbares brett-quittung unter $BRETT_QUITTUNG"
      ok=0
    fi
  else
    echo "SELFTEST FAIL: python3 fehlt"
    ok=0
  fi
  if [ -d "$ANTWORTEN" ]; then
    echo "SELFTEST OK: Antwortordner $ANTWORTEN lesbar"
  else
    echo "SELFTEST OK: Antwortordner $ANTWORTEN noch nicht angelegt (leer ist ok)"
  fi
  if [ -d "$CHAT_ANTWORTEN" ]; then
    echo "SELFTEST OK: Chat-Antwortordner $CHAT_ANTWORTEN lesbar"
  else
    echo "SELFTEST OK: Chat-Antwortordner $CHAT_ANTWORTEN noch nicht angelegt (leer ist ok)"
  fi
  if [ -f "$SECONDMATES" ]; then
    while IFS= read -r home; do
      [ -d "$home" ] || { echo "SELFTEST FAIL: Offiziers-Heim $home fehlt"; ok=0; }
    done < <(sed -n 's/^.*(home: \([^;)]*\);.*/\1/p' "$SECONDMATES")
    echo "SELFTEST OK: secondmates.md lesbar"
  else
    echo "SELFTEST OK: keine Offiziere registriert (secondmates.md abwesend)"
  fi
  [ "$ok" = 1 ] && echo "SELFTEST OK"
  [ "$ok" = 1 ]
}

case ${1:-check} in
  check) action_check ;;
  bemerkungen) action_bemerkungen ;;
  bemerkung-erledigt) shift; action_bemerkung_erledigt "$@" ;;
  nachrichten) action_nachrichten ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  --selftest) action_selftest ;;
  -h | --help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
