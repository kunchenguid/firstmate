#!/usr/bin/env bash
# fm-totmann-relaunch-lib.sh - what the dead-man types, and whether it worked.
#
# Usage (sourced by bin/fm-totmann.sh, the only production caller):
#   . "$FM_ROOT/bin/fm-totmann-relaunch-lib.sh"
#   fm_totmann_relaunch_default          print the relaunch command for the seat
#   fm_totmann_fehlstart_grund <text>    name the failure a pane capture shows
#   fm_totmann_fehlstart_ausweg <grund>  print the operator's way out of it
#   fm_totmann_resume_dialog_pending <text>  0 when the summary-vs-full resume
#                                        chooser is open on the pane
#
# Usage (executed, for tests and one-off shell checks):
#   fm-totmann-relaunch-lib.sh <function> [args...]
#
# One owner: this file owns BOTH halves of the revival's account question -
# which command revives the seat, and how a revival that landed nowhere is
# recognized. bin/fm-totmann.sh keeps only the hook that calls in.
#
# --- half 1: the relaunch command -------------------------------------------
# The seat is a managed state, not a literal. `claude2 --continue` used to sit
# hardcoded in three places (fm-totmann's default, ~/.local/bin/fm-deadman.sh,
# fm-lastverteilung), so every seat move had to be repeated by hand and a
# missed one revived the session on the wrong Anthropic account. The single
# source is the account ledger config/konten.tsv, read through
# bin/fm-konten-lib.sh: the storage holding role `firstmate` decides, and its
# wrapper name is the command. FM_TOTMANN_RELAUNCH_CMD stays as an explicit
# override for tests and for a captain-ordered one-off.
#
# A ledger that cannot be read is NEVER papered over with a guessed wrapper: a
# guessed `claudeN --continue` starts the leadership session on a stranger's
# account. The function fails loudly (status 2, reason on stderr) and the
# caller must refuse the revival.
#
# --- half 2: did the revival actually land? ---------------------------------
# Measured failure (seat move to konto-2, O-0083): the dead-man typed its
# relaunch, tmux accepted the keys, the script reported "revived" - and the
# pane held a CLI that had answered `No conversation found` and dropped back to
# a bare shell. `--continue` resumes a conversation of THAT storage; after an
# account move the new storage has none. Same class of silent nothing: a
# storage that never finished onboarding shows the setup wizard, and a storage
# that never accepted the project's trust dialog shows that prompt. In all
# three the revival looks successful and the fleet stands still until a human
# notices.
#
# So the revival reads its own result back: after a short settle the target
# pane is captured, and a capture matching one of the markers below is a failed
# start, reported loudly and aborted - never armed with a kicker that would
# type into an empty shell.
#
# The marker set is deliberately small and literal; each entry is a string the
# harness prints in exactly that situation. Tests and one-off overrides replace
# the whole set through FM_TOTMANN_FEHLSTART_MARKER, in the format below.

# Markers: one entry per line, `<extended regex>#<short reason>`.
# `#` never appears inside these regexes, so it is a safe separator.
FM_TOTMANN_FEHLSTART_MARKER="${FM_TOTMANN_FEHLSTART_MARKER:-\
No conversation found#kein Gespraech auf diesem Konto (--continue ins Leere)
Welcome to Claude Code#Ersteinrichtung offen (Onboarding-Assistent)
Choose the text style#Ersteinrichtung offen (Onboarding-Assistent)
Select login method#nicht angemeldet (Anmeldeauswahl)
Log in with your Claude account#nicht angemeldet (Anmeldeauswahl)
Do you trust the files in this#Vertrauensdialog offen fuer dieses Verzeichnis}"

fm_totmann_relaunch_warn() { printf 'fm-totmann-relaunch: %s\n' "$*" >&2; }

# fm_totmann_relaunch_lib_dir: where this file lives (the real bin/, never an
# FM_ROOT_OVERRIDE a test pointed elsewhere - the ledger reader must be found).
fm_totmann_relaunch_lib_dir() {
  (cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
}

# fm_totmann_relaunch_default: the command that revives the firstmate seat.
# Status 0 and the command on stdout, or status 2 and a named reason on stderr.
fm_totmann_relaunch_default() {
  local bin lib sitz wrapper
  bin="$(fm_totmann_relaunch_lib_dir)"
  lib="$bin/fm-konten-lib.sh"
  if [ ! -f "$lib" ]; then
    fm_totmann_relaunch_warn "account ledger reader missing: $lib - cannot derive the seat, refusing to guess a wrapper"
    return 2
  fi
  # Sourced in a subshell: the library must not leak its helpers into the
  # dead-man, and a `set` flag of the caller must survive untouched.
  # shellcheck source=bin/fm-konten-lib.sh
  sitz="$(. "$lib" && fm_firstmate_sitz)" || {
    fm_totmann_relaunch_warn "no firstmate seat in the account ledger (config/konten.tsv) - refusing to guess"
    return 2
  }
  # shellcheck source=bin/fm-konten-lib.sh
  wrapper="$(. "$lib" && fm_konto_wrapper "$sitz")" || {
    fm_totmann_relaunch_warn "seat '$sitz' has no wrapper name in the account ledger - refusing to guess"
    return 2
  }
  printf '%s --continue\n' "$wrapper"
}

# fm_totmann_fehlstart_grund <capture-text>: names the failure the capture
# shows. Status 0 plus the reason when one matched, status 1 when the capture
# looks like a started session.
fm_totmann_fehlstart_grund() {
  local text=${1-} zeile regex grund
  [ -n "$text" ] || return 1
  while IFS= read -r zeile; do
    [ -n "$zeile" ] || continue
    regex=${zeile%%#*}
    grund=${zeile#*#}
    [ -n "$regex" ] || continue
    if printf '%s' "$text" | grep -Eq -- "$regex"; then
      printf '%s\n' "$grund"
      return 0
    fi
  done <<< "$FM_TOTMANN_FEHLSTART_MARKER"
  return 1
}

# --- half 2b: the summary-vs-full resume chooser -----------------------------
# Measured rendering (bundle strings of the installed claude 2.1.246, extracted
# 26.08.2026; seen live after a revival the same morning - journal entry in
# data/umbau-2026-08/journal.md): a --continue onto a large session stops at a
# chooser titled "This session is <age> old and <tokens> tokens." offering
# "Resume from summary (recommended)", "Resume full session as-is" and
# "Don't ask me again". Unlike the failure markers above this one has a safe
# default: plain Enter selects the highlighted first option, the summary -
# measured live with exactly that keypress - and re-anchoring comes from the
# files anyway, so full history is never needed. The chooser is therefore
# ANSWERED by the revival (bin/fm-totmann.sh, bounded Enters), never reported.
#
# Vocabulary: one extended regex, deliberately two independent verbatim
# substrings of the measured rendering (question sentence and option label) so
# a single vendor string is never load-bearing. Override seam for tests and
# version drift; a changed rendering is fixed here and in the test fixture,
# never guessed at call time.
FM_TOTMANN_RESUME_DIALOG_REGEX="${FM_TOTMANN_RESUME_DIALOG_REGEX:-Resuming the full session will consume|Resume from summary}"

# fm_totmann_resume_dialog_pending <capture-text>: status 0 when the capture
# shows the summary-vs-full resume chooser, status 1 otherwise (an empty
# capture included).
fm_totmann_resume_dialog_pending() {
  local text=${1-}
  [ -n "$text" ] || return 1
  printf '%s' "$text" | grep -Eq -- "$FM_TOTMANN_RESUME_DIALOG_REGEX"
}

# fm_totmann_fehlstart_ausweg <grund>: the operator's way out, named so the
# notification carries a next step and not just an alarm.
fm_totmann_fehlstart_ausweg() {
  case "${1-}" in
    *"--continue ins Leere"*)
      printf 'Sitz frisch starten (ohne --continue) oder den Sitz per bin/fm-sitzwechsel.sh zurueckziehen\n' ;;
    *Onboarding*|*Anmeldeauswahl*)
      printf 'Der Captain oeffnet den Wrapper einmal von Hand und schliesst Einrichtung/Anmeldung ab\n' ;;
    *Vertrauensdialog*)
      printf 'Den Wrapper einmal von Hand im Firstmate-Verzeichnis starten und den Vertrauensdialog bestaetigen\n' ;;
    *)
      printf 'Den Sitz von Hand pruefen: config/konten.tsv und den Wrapper des Sitzes\n' ;;
  esac
}

fm_totmann_relaunch_usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  case "${1:-}" in
    ''|-h|--help) fm_totmann_relaunch_usage; exit 0 ;;
    fm_totmann_relaunch_default|fm_totmann_fehlstart_grund|fm_totmann_fehlstart_ausweg|fm_totmann_resume_dialog_pending)
      fn=$1
      shift
      "$fn" "$@"
      exit $?
      ;;
    *)
      fm_totmann_relaunch_warn "unknown function '$1' - see $(basename "${BASH_SOURCE[0]}") --help"
      exit 2
      ;;
  esac
fi
