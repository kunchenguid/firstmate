#!/usr/bin/env bash
# fm-brett-chat-lib.sh - shared reading of the board's chat-answer format
# contract for everything on the firstmate side of the Brett-Chat round trip.
#
# The contract's owner is the board:
# projects/captain-brett/data/chat-antworten/README.md (implementation:
# src/brett/sammler/chat.py there). This library enforces exactly those rules
# - no more, no less - so a file the helper writes can never be a file the
# board rejects red, and a file the checker treats as an answer is a file the
# board renders as one:
#
#   * an optional "# "-title as the very first line,
#   * the header region runs to the first line starting "##"; inside it,
#     "<name>: <value>" lines collect fields, names compare case-insensitively
#     and the last occurrence wins, anything else is inert,
#   * "antwort-auf" (an answer-id: letters, digits, dot, underscore, dash,
#     1..64 chars), "von", and "gesendet" (ISO timestamp) are all mandatory,
#   * body headings are "##" plus whitespace plus name; "Wort"
#     (case-insensitive) is the one recognized section and its text must be
#     non-empty, every other section name is a loud rejection, never prose.
#
# Consumers: bin/fm-brett-chat-antwort.sh (writes and refuses) and
# bin/fm-brett-antworten.sh (recognizes the answer that closes an open
# chat-message marker). Sourced, never executed.
set -u

#: The answer-id alphabet of the journal - the same form everywhere.
chat_bezug_ok() {  # <id> -> exit 0 when it is a well-formed reference
  case $1 in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "$(printf '%s' "$1" | wc -c | tr -d ' ')" -le 64 ]
}

chat_gesendet_ok() {  # <raw value> -> exit 0 when the stamp parses like the board's
  case $1 in
    '' | *[!0-9T:.+-]*) return 1 ;;
  esac
  case $1 in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) ;;
    *) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9]{2}:[0-9]{2}(:[0-9]{2}([.][0-9]+)?)?)?([+-][0-9]{2}:?[0-9]{2}|Z)?$' \
    || return 1
  # Fractional seconds are fine for the board; GNU date chokes on them, so
  # that one part is stripped before the calendar check.
  local v
  v=$(printf '%s' "$1" | sed -E 's/[.]([0-9]+)([+-][0-9]{2}:?[0-9]{2}|Z)?$/\2/')
  [ -n "$(date -d "$v" +%s 2>/dev/null)" ]
}

chat_antwort_fehler() {  # <datei> -> one rejection line per violation; empty output = valid
  local datei=$1 bezug von gesendet wort fremd
  if [ ! -f "$datei" ] || [ ! -r "$datei" ]; then
    printf 'Datei fehlt oder ist unlesbar\n'
    return 0
  fi
  {
    IFS= read -r bezug
    IFS= read -r von
    IFS= read -r gesendet
    IFS= read -r wort
    IFS= read -r fremd
  } < <(LC_ALL=C awk '
    BEGIN { kopf = 1 }
    NR == 1 && /^# / { next }
    kopf && /^##/ { kopf = 0 }
    kopf {
      z = $0
      sub(/\r$/, "", z)
      if (match(z, /^[A-Za-z-]+:/)) {
        name = tolower(substr(z, 1, RLENGTH - 1))
        wert = substr(z, RLENGTH + 1)
        gsub(/^[ \t]+/, "", wert)
        gsub(/[ \t]+$/, "", wert)
        gsub(/\t/, " ", wert)
        feld[name] = wert
      }
      next
    }
    {
      z = $0
      sub(/\r$/, "", z)
      if (z ~ /^##[ \t]/) {
        name = substr(z, 3)
        gsub(/^[ \t]+|[ \t]+$/, "", name)
        low = tolower(name)
        if (low == "wort") { imwort = 1 }
        else { fremd = fremd (fremd == "" ? "" : ", ") "\"" name "\"" }
        next
      }
      if (imwort) {
        gsub(/\t/, " ", z)
        if (z != "" && wort != "") wort = wort " "
        wort = wort z
      }
    }
    END {
      gsub(/^[ \t]+|[ \t]+$/, "", wort)
      print feld["antwort-auf"]
      print feld["von"]
      print feld["gesendet"]
      print wort
      print fremd
    }
  ' "$datei")

  if [ -z "$bezug" ]; then
    printf 'antwort-auf fehlt - eine Antwort ohne Bezug findet ihre Nachricht nicht\n'
  elif ! chat_bezug_ok "$bezug"; then
    printf 'antwort-auf ist keine Antwort-ID: %.40s\n' "$bezug"
  fi
  [ -n "$von" ] || printf 'von fehlt - jeder Eintrag im Faden nennt seinen Absender\n'
  if [ -z "$gesendet" ]; then
    printf 'gesendet fehlt - jeder Eintrag im Faden trägt seinen Zeitpunkt\n'
  elif ! chat_gesendet_ok "$gesendet"; then
    printf 'gesendet ist kein ISO-Zeitstempel: %.40s\n' "$gesendet"
  fi
  [ -n "$wort" ] || printf 'Abschnitt "## Wort" fehlt oder ist leer - es gibt nichts zu lesen\n'
  [ -z "$fremd" ] || printf 'unbekannte Abschnitte: %s\n' "$fremd"
  return 0
}

chat_antwort_fuer() {  # <verzeichnis> <antwort-auf-id> -> filename of the first valid answer; nonzero if none
  local verzeichnis=$1 id=$2 f bezug
  [ -d "$verzeichnis" ] || return 1
  chat_bezug_ok "$id" || return 1
  for f in "$verzeichnis"/*.md; do
    [ -f "$f" ] || continue
    case $(basename "$f") in README*) continue ;; esac
    bezug=$(LC_ALL=C awk '
      NR == 1 && /^# / { next }
      /^##/ { exit }
      {
        z = $0
        sub(/\r$/, "", z)
        if (match(tolower(z), /^antwort-auf:/)) {
          wert = substr(z, RLENGTH + 1)
          gsub(/^[ \t]+/, "", wert)
          gsub(/[ \t]+$/, "", wert)
          print wert
          exit
        }
      }' "$f")
    [ "$bezug" = "$id" ] || continue
    [ -z "$(chat_antwort_fehler "$f")" ] || continue
    printf '%s\n' "$(basename "$f")"
    return 0
  done
  return 1
}
