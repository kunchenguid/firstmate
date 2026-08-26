#!/usr/bin/env bash
# fm-abnahme.sh - the acceptance TOR: no task is called done on prose alone.
#
# Usage:
#   fm-abnahme.sh check-brief <task-id> [--brief <datei>]
#   fm-abnahme.sh check-report <task-id> [--report <datei>] [--legacy]
#   fm-abnahme.sh --help
#
# File contract (this header is the single owner):
#   data/<task-id>/brief.md carries a block this tool owns:
#     ## Abnahme (maschinenlesbar)
#     - [A<n>] <Kriterium> :: beleg=klickbeleg|testlauf|messung|diff|foto|sonstig
#   A brief whose header carries the line "Captain-Flaeche: ja" (anywhere in
#   the file, exact match) MUST carry at least one beleg=klickbeleg point.
#   data/<task-id>/report.md (or --report <datei>) answers it, one line per
#   brief point, no more, no less:
#     A<n>: erfüllt|nicht-erfüllt|unklar - <Beleg-Pfad oder Grund>
#   "erfüllt" requires an existing evidence file at
#   data/<task-id>/belege/<relativer Pfad aus der Zeile>. "unklar - <Grund>"
#   and "nicht-erfüllt - <Grund>" need no evidence and are fully valid
#   verdicts. Any other line shape is prose, not a verdict, and is rejected.
#
# Art-Prüfung (evidence must match its declared kind): beleg=testlauf needs a
# line "gelaufen: <n> Tests, exit=<rc>" inside the evidence file (or, for a
# directory of evidence, inside one file in it); beleg=klickbeleg needs an
# image file (or a directory holding one) or a .txt transcript. A declared
# "erfüllt" whose evidence fails that check is not rejected outright - it is
# GELB (exit 3, Firstmate must look): the machine cannot tell a genuine
# substance mismatch from a mislabeled but real beleg. beleg=sonstig is
# always GELB on "erfüllt" for the same reason - it names no checkable kind.
# beleg=messung/diff/foto carry no mechanical Art-Prüfung beyond the file
# existing; that is a Substanzprüfung Firstmate must do by hand regardless.
#
# --legacy: a report against a brief with no Abnahme block prints "LEGACY:
# Punkte vom Firstmate nachzutragen" and exits 3 (GELB) - never green, so a
# legacy task can be finished but never silently waved through. Once
# state/.abnahme-legacy-verfall holds a UTC date (YYYY-MM-DD) that has
# passed, the same legacy report turns ROT: the grace period for
# retrofitting old briefs runs out.
#
# Scharfschalt-Flag: state/.tor-abnahme-scharf. Missing it means the gate is
# built but not live yet (transition rule) - both subcommands check it FIRST,
# before touching any brief or report, and exit 0 in total silence when it is
# absent. Every armed decision - green, yellow, or red - is written as one
# JSONL line via fm_tor_log (bin/fm-tor-log-lib.sh) to
# state/tor-log/abnahme.jsonl, so the gate's history survives the session
# that produced it.
#
# WHY. A "done" that only exists as a captain-facing sentence cannot be
# checked by anyone later, and a report that grades its own work in prose
# drifts toward "fixed" meaning "I changed some code." This tool makes the
# brief name its own acceptance criteria up front, machine-checks that the
# report actually answers them one for one, and refuses to call unverifiable
# evidence green by accident - unclear stays unclear, mismatched evidence
# stays a human's call, and a missing point or a paragraph where a verdict
# belongs is a loud, cited refusal, never a silent pass.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
FLAG="$STATE/.tor-abnahme-scharf"
TOR="abnahme"

usage() { sed -n '2,56p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 2; }

if [ -f "$SCRIPT_DIR/fm-tor-log-lib.sh" ]; then
  # shellcheck source=bin/fm-tor-log-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-tor-log-lib.sh"
else
  # TODO-TOR-LOG-LIB: bin/fm-tor-log-lib.sh not built yet; local no-op stand-in.
  # Signature once it lands: fm_tor_log <tor> <regel-id> <verdikt:gruen|rot|warn> <ausweg-genutzt|-> <kontext>
  fm_tor_log() { :; }
fi

tor_armed() { [ -f "$FLAG" ]; }

declare -A POINT_ART

abnahme_block() { # abnahme_block <brief-file> -> lines inside the Abnahme block
  awk '
    /^## Abnahme \(maschinenlesbar\)$/ { found=1; next }
    found && /^## / { exit }
    found { print }
  ' "$1" 2>/dev/null
  return 0
}

parse_brief_points() { # parse_brief_points <brief-file>; sets global POINT_ART
  local file="$1" line
  POINT_ART=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^-\ \[A([0-9]+)\]\ .+\ ::\ beleg=(klickbeleg|testlauf|messung|diff|foto|sonstig)$ ]]; then
      POINT_ART["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
  done < <(abnahme_block "$file")
  return 0
}

brief_captain_flaeche() { grep -qx 'Captain-Flaeche: ja' "$1" 2>/dev/null; }

sorted_point_numbers() { printf '%s\n' "${!POINT_ART[@]}" | sort -n; }

testlauf_ok() { # testlauf_ok <beleg-path> -> evidence carries the run-count line
  local path="$1"
  if [ -d "$path" ]; then
    grep -rlqE '^gelaufen: [0-9]+ Tests, exit=[0-9]+$' "$path" >/dev/null 2>&1
  else
    grep -qE '^gelaufen: [0-9]+ Tests, exit=[0-9]+$' "$path" >/dev/null 2>&1
  fi
}

is_image_or_txt() { # is_image_or_txt <path> -> true for one file, name-based
  case "${1,,}" in
    *.png|*.jpg|*.jpeg|*.gif|*.webp|*.bmp|*.txt) return 0 ;;
    *) return 1 ;;
  esac
}

klickbeleg_ok() { # klickbeleg_ok <beleg-path> -> image file(s) or .txt transcript
  local path="$1" f found=1
  if [ -d "$path" ]; then
    while IFS= read -r -d '' f; do
      if is_image_or_txt "$f"; then
        found=0
      fi
    done < <(find "$path" -maxdepth 1 -type f -print0 2>/dev/null)
    return $found
  fi
  is_image_or_txt "$path"
}

# judge_erfuellt <task> <n> <rel-beleg-path> <belege-dir>
# Prints its verdict and logs it. Return code carries the verdict for
# aggregation: 0 gruen, 3 gelb (Substanzprüfung Firstmate nötig), 1 rot.
judge_erfuellt() {
  local task="$1" n="$2" relpath="$3" belege="$4" art="${POINT_ART[$2]}" path
  path="$belege/$relpath"
  if [ ! -e "$path" ]; then
    echo "ABNAHME-TOR ROT: A$n als 'erfüllt' gemeldet, aber die Beleg-Datei fehlt: \"$relpath\" (erwartet unter '$belege/')." >&2
    echo "Ausweg: Beleg-Datei unter '$belege/$relpath' ablegen, oder das Urteil auf 'unklar - <Grund>' setzen." >&2
    fm_tor_log "$TOR" beleg-fehlt rot beleg-ablegen-oder-unklar "task=$task punkt=A$n art=$art"
    return 1
  fi
  case "$art" in
    sonstig)
      echo "ABNAHME-TOR GELB: A$n (beleg=sonstig) 'erfüllt' mit Beleg \"$relpath\" - Substanzprüfung Firstmate nötig."
      fm_tor_log "$TOR" art-sonstig warn - "task=$task punkt=A$n"
      return 3
      ;;
    testlauf)
      if testlauf_ok "$path"; then
        fm_tor_log "$TOR" art-testlauf gruen - "task=$task punkt=A$n"
        return 0
      fi
      echo "ABNAHME-TOR GELB: A$n (beleg=testlauf) - \"$relpath\" ohne Zeile 'gelaufen: <n> Tests, exit=<rc>' - Substanzprüfung Firstmate nötig."
      fm_tor_log "$TOR" art-mismatch warn - "task=$task punkt=A$n art=testlauf"
      return 3
      ;;
    klickbeleg)
      if klickbeleg_ok "$path"; then
        fm_tor_log "$TOR" art-klickbeleg gruen - "task=$task punkt=A$n"
        return 0
      fi
      echo "ABNAHME-TOR GELB: A$n (beleg=klickbeleg) - \"$relpath\" ist kein Bild und kein .txt-Transkript - Substanzprüfung Firstmate nötig."
      fm_tor_log "$TOR" art-mismatch warn - "task=$task punkt=A$n art=klickbeleg"
      return 3
      ;;
    *)
      fm_tor_log "$TOR" "art-$art" gruen - "task=$task punkt=A$n"
      return 0
      ;;
  esac
}

cmd_check_brief() {
  tor_armed || exit 0

  local task="${1:-}" brief=""
  [ -n "$task" ] || die "check-brief requires <task-id>"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --brief) [ $# -ge 2 ] || die "--brief requires a value"; brief="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$brief" ] || brief="$DATA/$task/brief.md"

  if [ ! -f "$brief" ]; then
    echo "ABNAHME-TOR ROT: kein Brief unter '$brief' gefunden." >&2
    echo "Ausweg: Brief unter '$brief' anlegen mit einem '## Abnahme (maschinenlesbar)'-Block." >&2
    fm_tor_log "$TOR" brief-fehlt rot brief-anlegen "task=$task brief=$brief"
    exit 1
  fi

  parse_brief_points "$brief"
  local count=${#POINT_ART[@]}

  if [ "$count" -lt 1 ]; then
    echo "ABNAHME-TOR ROT: Brief '$brief' hat keinen wohlgeformten Abnahmepunkt. Quelle: Vertrag im Header dieses Tors - '## Abnahme (maschinenlesbar)' mit '- [A<n>] <Kriterium> :: beleg=<art>'." >&2
    echo "Ausweg: mindestens einen wohlgeformten Punkt im Block '## Abnahme (maschinenlesbar)' ergänzen." >&2
    fm_tor_log "$TOR" brief-mindestpunkt rot punkt-ergaenzen "task=$task brief=$brief"
    exit 1
  fi

  if brief_captain_flaeche "$brief"; then
    local has_klick=1 n
    while IFS= read -r n; do
      [ "${POINT_ART[$n]}" = klickbeleg ] && has_klick=0
    done < <(sorted_point_numbers)
    if [ "$has_klick" -ne 0 ]; then
      echo "ABNAHME-TOR ROT: Brief '$brief' trägt Kopfzeile \"Captain-Flaeche: ja\", aber kein Punkt mit beleg=klickbeleg." >&2
      echo "Ausweg: einen Punkt '- [A<n>] <Kriterium> :: beleg=klickbeleg' ergänzen, der den Klickbeleg im Interface fordert." >&2
      fm_tor_log "$TOR" captain-flaeche-klickbeleg rot klickbeleg-punkt-ergaenzen "task=$task brief=$brief"
      exit 1
    fi
    fm_tor_log "$TOR" captain-flaeche-klickbeleg gruen - "task=$task brief=$brief"
  fi

  fm_tor_log "$TOR" brief-mindestpunkt gruen - "task=$task brief=$brief"
  echo "GRUEN: Brief '$brief' hat $count wohlgeformte(n) Abnahmepunkt(e)."
  exit 0
}

cmd_check_report() {
  tor_armed || exit 0

  local task="${1:-}" report="" legacy=0
  [ -n "$task" ] || die "check-report requires <task-id>"
  shift
  local brief="$DATA/$task/brief.md"
  while [ $# -gt 0 ]; do
    case "$1" in
      --report) [ $# -ge 2 ] || die "--report requires a value"; report="$2"; shift 2 ;;
      --legacy) legacy=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$report" ] || report="$DATA/$task/report.md"
  local belege="$DATA/$task/belege"

  parse_brief_points "$brief"
  local count=${#POINT_ART[@]}

  if [ "$count" -lt 1 ]; then
    if [ "$legacy" -eq 1 ]; then
      local verfall_file="$STATE/.abnahme-legacy-verfall"
      if [ -f "$verfall_file" ]; then
        local verfall_date today
        verfall_date="$(tr -d ' \t\r\n' < "$verfall_file")"
        today="$(date -u +%F)"
        if [[ "$verfall_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ "$today" > "$verfall_date" ]]; then
          echo "ABNAHME-TOR ROT: Legacy-Frist überschritten. Quelle: state/.abnahme-legacy-verfall = \"$verfall_date\", heute = \"$today\"." >&2
          echo "Ausweg: Abnahmeblock in '$brief' nachtragen, dann check-report ohne --legacy erneut ausführen." >&2
          fm_tor_log "$TOR" legacy-verfall rot abnahmeblock-nachtragen "task=$task verfall=$verfall_date"
          exit 1
        fi
      fi
      echo "LEGACY: Punkte vom Firstmate nachzutragen"
      fm_tor_log "$TOR" legacy warn abnahmeblock-nachtragen "task=$task brief=$brief"
      exit 3
    fi
    echo "ABNAHME-TOR ROT: Brief '$brief' hat keinen '## Abnahme (maschinenlesbar)'-Block bzw. keinen wohlgeformten Punkt." >&2
    echo "Ausweg: Abnahmeblock im Brief nachtragen, oder check-report mit --legacy aufrufen." >&2
    fm_tor_log "$TOR" kein-abnahmeblock rot legacy-oder-nachtragen "task=$task brief=$brief"
    exit 1
  fi

  if [ ! -f "$report" ]; then
    echo "ABNAHME-TOR ROT: kein Bericht unter '$report' gefunden. Quelle: Brief '$brief' fordert $count Abnahmepunkt(e)." >&2
    echo "Ausweg: Bericht unter '$report' anlegen, je Punkt genau eine Zeile 'A<n>: erfüllt|nicht-erfüllt|unklar - <Beleg-Pfad oder Grund>'." >&2
    fm_tor_log "$TOR" bericht-fehlt rot bericht-anlegen "task=$task report=$report"
    exit 1
  fi

  local -A SEEN=()
  local worst=gruen line n urteil rest jrc

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if [[ "$line" =~ ^A([0-9]+):\ (erfüllt|nicht-erfüllt|unklar)\ -\ (.+)$ ]]; then
      n="${BASH_REMATCH[1]}"; urteil="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
      if [ -z "${POINT_ART[$n]+x}" ]; then
        echo "ABNAHME-TOR ROT: Urteilszeile für A$n hat keine Entsprechung im Brief '$brief': \"$line\"" >&2
        echo "Ausweg: die Zeile entfernen, oder Punkt A$n im Brief ergänzen." >&2
        fm_tor_log "$TOR" punkt-unbekannt rot zeile-entfernen "task=$task punkt=A$n"
        worst=rot
        continue
      fi
      if [ -n "${SEEN[$n]:-}" ]; then
        echo "ABNAHME-TOR ROT: mehr als eine Urteilszeile für A$n im Bericht '$report': \"$line\"" >&2
        echo "Ausweg: genau eine Urteilszeile je Punkt führen, die doppelte Zeile entfernen." >&2
        fm_tor_log "$TOR" punkt-doppelt rot zeile-entfernen "task=$task punkt=A$n"
        worst=rot
        continue
      fi
      SEEN[$n]=1
      case "$urteil" in
        unklar)
          fm_tor_log "$TOR" punkt-urteil gruen - "task=$task punkt=A$n urteil=unklar"
          ;;
        nicht-erfüllt)
          fm_tor_log "$TOR" punkt-urteil gruen - "task=$task punkt=A$n urteil=nicht-erfuellt"
          ;;
        erfüllt)
          if judge_erfuellt "$task" "$n" "$rest" "$belege"; then
            jrc=0
          else
            jrc=$?
          fi
          case "$jrc" in
            3) [ "$worst" = rot ] || worst=warn ;;
            1) worst=rot ;;
          esac
          ;;
      esac
    else
      echo "ABNAHME-TOR ROT: Prosa statt Urteilszeile im Bericht '$report': \"$line\"" >&2
      echo "Ausweg: Zeile im Format 'A<n>: erfüllt|nicht-erfüllt|unklar - <Beleg-Pfad oder Grund>' schreiben." >&2
      fm_tor_log "$TOR" prosa rot format-korrigieren "task=$task report=$report"
      worst=rot
    fi
  done < "$report"

  while IFS= read -r n; do
    if [ -z "${SEEN[$n]:-}" ]; then
      echo "ABNAHME-TOR ROT: kein Urteil für A$n im Bericht '$report'. Quelle: Brief '$brief' Punkt A$n." >&2
      echo "Ausweg: Zeile 'A$n: erfüllt|nicht-erfüllt|unklar - <Beleg-Pfad oder Grund>' in '$report' ergänzen." >&2
      fm_tor_log "$TOR" punkt-fehlt rot zeile-ergaenzen "task=$task punkt=A$n"
      worst=rot
    fi
  done < <(sorted_point_numbers)

  case "$worst" in
    gruen)
      echo "GRUEN: Bericht '$report' erfüllt den Abnahme-Vertrag für $count Punkt(e)."
      fm_tor_log "$TOR" gesamturteil gruen - "task=$task report=$report"
      exit 0
      ;;
    warn)
      echo "ABNAHME-TOR GELB: Substanzprüfung Firstmate nötig für Bericht '$report'." >&2
      fm_tor_log "$TOR" gesamturteil warn - "task=$task report=$report"
      exit 3
      ;;
    *)
      fm_tor_log "$TOR" gesamturteil rot - "task=$task report=$report"
      exit 1
      ;;
  esac
}

case "${1:-}" in
  -h|--help|"") usage; exit 0 ;;
esac
sub="$1"; shift
case "$sub" in
  check-brief) cmd_check_brief "$@" ;;
  check-report) cmd_check_report "$@" ;;
  *) usage >&2; die "unknown subcommand: $sub" ;;
esac
