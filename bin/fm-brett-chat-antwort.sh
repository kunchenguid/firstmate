#!/usr/bin/env bash
# fm-brett-chat-antwort.sh - write one answer file for a captain chat message
# onto the Brett-Chat round trip.
#
# The board reads this home's data/chat-antworten directory fresh on every
# render; dropping a format-valid file there IS the whole delivery route
# (contract owner: projects/captain-brett/data/chat-antworten/README.md,
# enforced here through bin/fm-brett-chat-lib.sh). This helper composes that
# file and refuses loudly rather than writing anything the board would reject
# red: a silently swallowed answer would be indistinguishable from no answer.
#
# Commands:
#   fm-brett-chat-antwort.sh <antwort-auf-id> "Antworttext ..."
#                                    join several words with single spaces
#   fm-brett-chat-antwort.sh <antwort-auf-id> --file <pfad>
#                                    take the word verbatim from a file
#   fm-brett-chat-antwort.sh --help  print this command summary
#
# Options:
#   --ohne-nachschub  skip the immediate mirror run after a successful write;
#                     the periodic mirror still picks the file up later
#
# Mechanics:
#   * The reference id must be a journal answer-id (chat_bezug_ok).
#   * The word must be non-empty and must not carry its own "## " heading -
#     headings are section structure on the board, so embedded ones would
#     become foreign sections and a red rejection there.
#   * The file lands as data/chat-antworten/<zeit>-<antwort-auf-id>.md
#     (numbered suffix on a same-second collision), written tmp-then-rename,
#     validated against the contract BEFORE the rename, so a refused write
#     leaves nothing behind. The written path is printed on success.
#   * After a successful write the sibling bin/fm-brett-chat-nachschub.sh runs
#     once for immediacy; its failure is reported loudly on stderr but does
#     not fail the command - the answer is durable locally either way, and
#     the periodic run retries the push.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
CHAT_DIR="$FM_HOME/data/chat-antworten"
NACHSCHUB="$SCRIPT_DIR/fm-brett-chat-nachschub.sh"

# shellcheck source=bin/fm-brett-chat-lib.sh
. "$SCRIPT_DIR/fm-brett-chat-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-brett-chat-antwort.sh <antwort-auf-id> "Antworttext ..."
  fm-brett-chat-antwort.sh <antwort-auf-id> --file <pfad>
  fm-brett-chat-antwort.sh [--ohne-nachschub] ...

Writes one format-valid answer file under data/chat-antworten/ and prints the
written path. The format contract is owned by the board
(projects/captain-brett/data/chat-antworten/README.md); anything it does not
know is refused here instead of being written for a red rejection there.
EOF
}

die_usage() {
  printf 'fm-brett-chat-antwort: %s\n' "$1" >&2
  usage >&2
  exit 2
}

id=
text=
text_file=
ohne_nachschub=0

if [ "$#" -eq 0 ]; then
  usage
  exit 0
fi

while [ "$#" -gt 0 ]; do
  case $1 in
    --file)
      [ -z "$text_file" ] || die_usage "--file twice"
      shift
      [ "$#" -gt 0 ] || die_usage "--file braucht einen Pfad"
      text_file=$1
      ;;
    --ohne-nachschub) ohne_nachschub=1 ;;
    -h | --help) usage; exit 0 ;;
    --*) die_usage "unknown option: $1" ;;
    *)
      if [ -z "$id" ]; then id=$1
      elif [ -z "$text" ]; then text=$1
      else text="$text $1"
      fi
      ;;
  esac
  shift
done

[ -n "$id" ] || die_usage "antwort-auf-id fehlt"

if ! chat_bezug_ok "$id"; then
  printf 'fm-brett-chat-antwort: antwort-auf ist keine Antwort-ID: %.40s\n' "$id" >&2
  exit 2
fi

if [ -n "$text_file" ]; then
  [ -z "$text" ] || die_usage "entweder Wort als Wortlaut oder --file, nicht beides"
  [ -f "$text_file" ] && [ -r "$text_file" ] \
    || { printf 'fm-brett-chat-antwort: Wortdatei fehlt oder ist unlesbar: %s\n' "$text_file" >&2; exit 1; }
  text=$(cat "$text_file")
fi

# A heading inside the word would arrive at the board as a foreign section,
# i.e. as a red rejection - refuse it here, where nothing has been written.
if printf '%s\n' "$text" | grep -qn '^##[[:space:]]'; then
  printf 'fm-brett-chat-antwort: der Wortlaut enthaelt eine eigene "## "-Ueberschrift; Abschnitte gehoeren dem Format\n' >&2
  exit 1
fi
if [ -z "$(printf '%s' "$text" | tr -d '[:space:]')" ]; then
  printf 'fm-brett-chat-antwort: der Wortlaut ist leer - es gibt nichts zu lesen\n' >&2
  exit 1
fi

mkdir -p "$CHAT_DIR" || { printf 'fm-brett-chat-antwort: kann %s nicht anlegen\n' "$CHAT_DIR" >&2; exit 1; }
[ -d "$CHAT_DIR" ] && [ ! -L "$CHAT_DIR" ] \
  || { printf 'fm-brett-chat-antwort: %s ist kein Verzeichnis\n' "$CHAT_DIR" >&2; exit 1; }

zeit=$(date '+%Y%m%dT%H%M%S')
ziel="$CHAT_DIR/$zeit-$id.md"
n=0
while [ -e "$ziel" ]; do
  n=$((n + 1))
  ziel="$CHAT_DIR/$zeit-$id-$n.md"
done

tmp=$(mktemp "$CHAT_DIR/.antwort.XXXXXX") || {
  printf 'fm-brett-chat-antwort: kann die Antwortdatei nicht anlegen\n' >&2
  exit 1
}
if ! {
  printf '# Antwort des Firstmate\n'
  printf 'antwort-auf: %s\n' "$id"
  printf 'von: firstmate\n'
  printf 'gesendet: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/')"
  printf '\n'
  printf '## Wort\n'
  printf '%s\n' "$text"
} > "$tmp" || ! chmod 0644 "$tmp"; then
  rm -f -- "$tmp"
  printf 'fm-brett-chat-antwort: kann die Antwortdatei nicht schreiben\n' >&2
  exit 1
fi

# Refuse BEFORE the rename: a rejected composition must leave nothing behind.
fehler=$(chat_antwort_fehler "$tmp")
if [ -n "$fehler" ]; then
  rm -f -- "$tmp"
  printf 'fm-brett-chat-antwort: abgewiesen, nichts geschrieben:\n%s\n' "$fehler" >&2
  exit 1
fi

mv -f -- "$tmp" "$ziel" || {
  rm -f -- "$tmp"
  printf 'fm-brett-chat-antwort: kann die Antwortdatei nicht ablegen\n' >&2
  exit 1
}
printf 'antwort geschrieben: %s\n' "$ziel"

if [ "$ohne_nachschub" = 1 ] || [ ! -x "$NACHSCHUB" ]; then
  exit 0
fi
if ! "$NACHSCHUB"; then
  printf 'fm-brett-chat-antwort: der sofortige Nachschub scheiterte; die Antwort liegt dauerhaft hier und der periodische Lauf holt sie zum gex nach\n' >&2
fi
exit 0
