#!/usr/bin/env bash
# fm-brett-chat-nachschub.sh - mirror this home's chat answers to the gex,
# deletions included.
#
# Direction HEIM -> GEX, docking beside the board's own bin/brett-nachschub
# (installed copy: ~/.local/lib/captain-brett/bin/brett-nachschub), which
# pushes cards, images, envelopes, and receipts but does not know about
# data/chat-antworten. This script owns that one directory:
#
#   data/chat-antworten/  ->  <gex>:/root/captain-brett/data/chat-antworten/
#
# Deletions are part of the contract (rsync --delete): removing an answer
# locally removes it from the board's store, so the directory as a whole is
# the standing truth. A MISSING source directory mirrors nothing and fails
# nothing - before the first answer there is no state to lose, and an absent
# directory must never read as an order to wipe the target.
#
# After every run a mirror probe compares the target listing against the
# source listing; any divergence is a loud failure, because a silently stale
# store would show the captain answers firstmate has already taken back.
# Card-store deletion matching is a different post (backlog item
# fm-brett-nachschub-loeschabgleich) and deliberately not built here twice.
#
# Commands:
#   fm-brett-chat-nachschub.sh [--gex host] [--ziel pfad]
#   fm-brett-chat-antwort.sh --help   print this command summary
#
# Cadence wiring is a home deployment step (a user timer beside
# brett-nachschub.timer); the helper runs this script opportunistically after
# each answer, and every run is idempotent.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
QUELLE="$FM_HOME/data/chat-antworten"
GEX=gex
ZIEL=/root/captain-brett/data/chat-antworten
SSH_ZUG=(ssh -o BatchMode=yes -o ConnectTimeout=10)

usage() {
  cat <<'EOF'
Usage:
  fm-brett-chat-nachschub.sh [--gex host] [--ziel pfad]

Mirrors data/chat-antworten/ to the gex with deletion semantics and proves
the result with a listing probe. Absent source directory: nothing to mirror,
exit 0. Anything else that goes wrong exits nonzero and loudly.
EOF
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --gex)
      shift
      [ "$#" -gt 0 ] || { printf 'fm-brett-chat-nachschub: --gex braucht einen Host\n' >&2; exit 2; }
      GEX=$1
      ;;
    --ziel)
      shift
      [ "$#" -gt 0 ] || { printf 'fm-brett-chat-nachschub: --ziel braucht einen Pfad\n' >&2; exit 2; }
      ZIEL=$1
      ;;
    -h | --help) usage; exit 0 ;;
    *) printf 'fm-brett-chat-nachschub: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ ! -d "$QUELLE" ]; then
  printf 'chat-nachschub: %s fehlt - nichts zu spiegeln\n' "$QUELLE"
  exit 0
fi

if ! rsync -a --delete --exclude='.??*' -- "$QUELLE/" "$GEX:$ZIEL/"; then
  printf 'NACHSCHUB SCHEITERT: rsync nach %s:%s brach ab\n' "$GEX" "$ZIEL" >&2
  exit 1
fi

lokal=$(CDPATH='' cd -- "$QUELLE" && ls | sort) || {
  printf 'NACHSCHUB SCHEITERT: %s unlesbar bei der Spiegelprobe\n' "$QUELLE" >&2
  exit 1
}
if ! ziel_liste=$("${SSH_ZUG[@]}" "$GEX" "cd '$ZIEL' && ls" ); then
  printf 'NACHSCHUB SCHEITERT: Ziel listing am gex unlesbar (%s:%s)\n' "$GEX" "$ZIEL" >&2
  exit 1
fi
ziel_liste=$(printf '%s' "$ziel_liste" | sort)

if [ "$lokal" != "$ziel_liste" ]; then
  printf 'NACHSCHUB SCHEITERT: Spiegelprobe findet Unterschiede zwischen %s und %s:%s\n' \
    "$QUELLE" "$GEX" "$ZIEL" >&2
  diff <(printf '%s\n' "$lokal") <(printf '%s\n' "$ziel_liste") >&2 || :
  exit 1
fi

anzahl=$(printf '%s' "$lokal" | grep -c . || :)
printf 'chat-nachschub: ok (%s Dateien am Ziel, Loeschungen eingespult)\n' "${anzahl:-0}"
