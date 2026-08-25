#!/usr/bin/env bash
# fm-sitzwechsel.sh - the ONE way to move the firstmate seat to another account.
#
# Usage:
#   fm-sitzwechsel.sh <ziel-speicher> --alte-rolle <rolle> [--dry-run]
#                     [--ohne-verlauf]
#   fm-sitzwechsel.sh --help
#
# Options:
#   --alte-rolle <rolle>  what the seat being LEFT becomes (usually
#                         restverbrauch). Required: the tool refuses to invent a
#                         role for the account it just emptied.
#   --dry-run             print every step and refusal, write nothing.
#   --ohne-verlauf        proceed although the old seat has no session file to
#                         carry over (the conversation thread is then lost;
#                         durable state lives in data/, not in the thread).
#
# One owner: this script is the only writer of the `rolle` column in
# config/konten.tsv (owner of the file format: that file's header). Reading is
# bin/fm-konten-lib.sh. Moving the seat by hand - editing the ledger, copying a
# .jsonl, changing a wrapper in a brief - is exactly the split-brain this tool
# exists to end.
#
# WHY. A seat move is three things that were never done together: the session
# thread lives in <storage>/projects/<slug of $FM_HOME>/, so `--continue` on the
# new account starts blank unless the newest .jsonl is copied across; the ledger
# has to be re-stamped or every reader still points at the old seat; and several
# consumers are not converted yet and keep their own defaults. Doing two of the
# three leaves the fleet reviving firstmate on the account it just left.
#
# What it does NOT do (deliberately, v1): no tmux. It never types into a window,
# never kills a session, never restarts anything. It prepares the move and
# prints the exact command to type. The totmann/spawn wiring is a later wave.
#
# Order of operations, fail-closed: preflight -> session migration -> ledger
# rewrite. The ledger is re-stamped only after the thread is in place, so an
# abort never leaves a ledger that points at a seat without its history.
#
# Preflight refusals (each names its way out):
#   - target is already the seat
#   - target not startable per fm_konto_startfaehig for $FM_HOME (onboarding or
#     trust dialog missing) - a readable quota is NOT proof (learnings:46)
#   - --alte-rolle missing, unknown, or `firstmate` (two seats is not a state)
#   - no session file to carry over, without --ohne-verlauf
# Auth freshness is a WARNING only, best effort, from the renewal log:
#   $FM_KONTO_AUTH_STATE (default ~/.local/state/fm-konto-auth).
#
# Environment:
#   FM_HOME                  firstmate home whose thread moves (default: repo)
#   FM_KONTEN_AKTE           ledger override (see bin/fm-konten-lib.sh)
#   FM_KONTO_AUTH_STATE      auth renewal state dir for the freshness warning
#   FM_TOTMANN_TARGET        window named in the follow-up hint (default firstmate:0)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
AUTH_STATE="${FM_KONTO_AUTH_STATE:-$HOME/.local/state/fm-konto-auth}"
TARGET_WINDOW="${FM_TOTMANN_TARGET:-firstmate:0}"

# shellcheck source=bin/fm-konten-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-konten-lib.sh"

usage() { sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'fm-sitzwechsel: %s\n' "$1" >&2; exit "${2:-1}"; }
say() { printf '%s\n' "$*"; }
warn() { printf 'fm-sitzwechsel: WARNUNG: %s\n' "$*" >&2; }

ZIEL=""
ALTE_ROLLE=""
DRYRUN=0
OHNE_VERLAUF=0

while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRYRUN=1 ;;
    --ohne-verlauf) OHNE_VERLAUF=1 ;;
    --alte-rolle)
      shift
      [ $# -gt 0 ] || die "--alte-rolle needs a value (known: $FM_KONTEN_ROLLEN)"
      ALTE_ROLLE=$1
      ;;
    --alte-rolle=*) ALTE_ROLLE=${1#--alte-rolle=} ;;
    -*) die "unknown option '$1' - see --help" ;;
    *)
      [ -z "$ZIEL" ] || die "only one <ziel-speicher> is accepted (got '$ZIEL' and '$1')"
      ZIEL=$1
      ;;
  esac
  shift
done

[ -n "$ZIEL" ] || die "usage: fm-sitzwechsel.sh <ziel-speicher> --alte-rolle <rolle> [--dry-run]"

# fm_sitz_slug <pfad>: Claude Code's project-directory key for a working
# directory - every character outside [A-Za-z0-9-] becomes a dash, so
# /home/fridjof/firstmate -> -home-fridjof-firstmate. Generalised from
# ~/.local/bin/fm-umzug-konto1, which only ever guessed it from an existing
# directory name and therefore could not create the target directory itself.
fm_sitz_slug() {
  printf '%s\n' "$1" | sed 's/[^A-Za-z0-9-]/-/g'
}

# fm_sitz_auth_warnung <speicher>: best-effort freshness note from the token
# renewal state. Never fails the run - a stale note must not block a seat move.
fm_sitz_auth_warnung() {
  local speicher=$1 nummer datei zeile count
  case $speicher in
    konto-*) nummer=${speicher#konto-} ;;
    *) return 0 ;;
  esac
  datei="$AUTH_STATE/konto$nummer.failures"
  if [ -r "$datei" ]; then
    count=$(tr -cd '0-9,:"{} a-z' < "$datei" | sed -n 's/.*"count":[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
      warn "auth renewal for $speicher has $count recorded failure(s) ($datei) - check the login before you rely on the seat"
    fi
  fi
  if [ -r "$AUTH_STATE/verlauf.log" ]; then
    zeile=$(grep "konto$nummer:" "$AUTH_STATE/verlauf.log" 2>/dev/null | tail -1 || true)
    case $zeile in
      *fehlgeschlagen*)
        warn "last auth log line for $speicher reports a failure: $zeile"
        ;;
    esac
  fi
  return 0
}

# --- Preflight -------------------------------------------------------------
AKTE="$(fm_konten_akte)"
[ -f "$AKTE" ] || die "ledger missing: $AKTE" 2

# Unknown speicher aborts loudly here (status 2 from the library).
ZIEL_PFAD="$(fm_konto_pfad "$ZIEL")" || exit 2
ZIEL_ROLLE_ALT="$(fm_konto_rolle "$ZIEL")" || exit 2
ZIEL_WRAPPER="$(fm_konto_wrapper "$ZIEL")" || exit 2

SITZ="$(fm_firstmate_sitz)" || die "no speicher carries rolle firstmate in $AKTE - fix the ledger before moving the seat" 2
SITZ_PFAD="$(fm_konto_pfad "$SITZ")" || exit 2

if [ "$ZIEL" = "$SITZ" ]; then
  die "$ZIEL already holds the firstmate seat ($AKTE) - nothing to move; pick another target, or fix the ledger if the seat is recorded wrong"
fi

if [ -z "$ALTE_ROLLE" ]; then
  die "what does $SITZ become once the seat leaves it? Rerun with --alte-rolle <rolle> (known: $FM_KONTEN_ROLLEN; usually restverbrauch) - this tool does not invent a role for the account it empties"
fi
fm_konten_rolle_bekannt "$ALTE_ROLLE" \
  || die "unknown --alte-rolle '$ALTE_ROLLE' - known: $FM_KONTEN_ROLLEN"
[ "$ALTE_ROLLE" != "firstmate" ] \
  || die "--alte-rolle firstmate would leave two seats - the firstmate seat is exclusive (O-0083); pass restverbrauch or offiziere-worker"

if ! fm_konto_startfaehig "$ZIEL" "$FM_HOME"; then
  die "$ZIEL is not startable for $FM_HOME - open a session there once by hand ($ZIEL_WRAPPER in $FM_HOME), finish onboarding and accept the trust dialog, then rerun. Refusing to move the seat onto a storage that drops the session into the setup wizard."
fi

fm_sitz_auth_warnung "$ZIEL"

# --- Session migration -----------------------------------------------------
SLUG="$(fm_sitz_slug "$FM_HOME")"
QUELL_DIR="$SITZ_PFAD/projects/$SLUG"
ZIEL_DIR="$ZIEL_PFAD/projects/$SLUG"

NEUESTE=""
if [ -d "$QUELL_DIR" ]; then
  NEUESTE=$(find "$QUELL_DIR" -maxdepth 1 -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-)
fi
if [ -z "$NEUESTE" ] && [ "$OHNE_VERLAUF" -eq 0 ]; then
  die "no session file under $QUELL_DIR - '$ZIEL_WRAPPER --continue' would start blank. Rerun with --ohne-verlauf if that is intended (durable state lives in data/, not in the thread), or check FM_HOME=$FM_HOME."
fi

say "Sitzwechsel: $SITZ -> $ZIEL"
say "  ledger      : $AKTE"
say "  FM_HOME     : $FM_HOME (slug $SLUG)"
say "  alter Sitz  : $SITZ ($SITZ_PFAD) -> rolle $ALTE_ROLLE"
say "  neuer Sitz  : $ZIEL ($ZIEL_PFAD), bisher rolle $ZIEL_ROLLE_ALT"
if [ -n "$NEUESTE" ]; then
  say "  Verlauf     : $(basename "$NEUESTE") -> $ZIEL_DIR/"
else
  say "  Verlauf     : keiner (--ohne-verlauf) - der neue Sitz startet ohne Gespraechsfaden"
fi

if [ "$DRYRUN" -eq 1 ]; then
  say ""
  say "--dry-run: nichts geschrieben."
else
  if [ -n "$NEUESTE" ]; then
    mkdir -p "$ZIEL_DIR"
    cp -a "$NEUESTE" "$ZIEL_DIR/" \
      || die "copying $NEUESTE to $ZIEL_DIR failed - ledger left untouched, the seat did not move"
    say ""
    say "kopiert: $(basename "$NEUESTE") -> $ZIEL_DIR/"
  fi

  TMP_AKTE="$AKTE.tmp.$$"
  awk -F'\t' -v OFS='\t' -v ziel="$ZIEL" -v sitz="$SITZ" -v alt="$ALTE_ROLLE" '
    /^#/ || NF < 5 { print; next }
    $1 == ziel { $4 = "firstmate"; print; next }
    $1 == sitz { $4 = alt; print; next }
    { print }
  ' "$AKTE" > "$TMP_AKTE" || { rm -f "$TMP_AKTE"; die "rewriting $AKTE failed"; }
  mv "$TMP_AKTE" "$AKTE"
  say "umgetragen: rolle firstmate steht jetzt bei $ZIEL, $SITZ ist $ALTE_ROLLE"
fi

# --- Follow-ups this tool deliberately does NOT perform ---------------------
say ""
say "Was JETZT von Hand kommt (dieses Werkzeug fasst kein tmux an):"
say "  1. In der laufenden Firstmate-Sitzung: /exit"
say "     (danach erneut ausfuehren, sonst fehlen die letzten Nachrichten in der Kopie)"
say "  2. Im Fenster $TARGET_WINDOW tippen:  $ZIEL_WRAPPER --continue"
say ""
say "Noch nicht umgebaute Konsumenten - bis zur Einhak-Welle von Hand pruefen:"
say "  - bin/fm-totmann.sh: Wiederbelebung nutzt FM_TOTMANN_RELAUNCH_CMD (Default"
say "    'claude4 --continue'), liest die Akte NICHT. Passt der Default nicht zu"
say "    $ZIEL_WRAPPER, belebt der Totmann auf dem falschen Konto wieder."
say "  - ~/.local/bin/fm-lastverteilung: FM_LB_FIRSTMATE_KONTO haelt das"
say "    Firstmate-Konto aus der Worker-Verteilung; Wert muss ${ZIEL#konto-} sein."
say "  - bin/fm-spawn.sh / config/crew-dispatch.json: Konto-Profile der Crew"
say "    zeigen weiter auf ihre eigenen Wrapper."
say "  - Auftraege/Briefe mit fest getipptem Wrapper-Namen."
