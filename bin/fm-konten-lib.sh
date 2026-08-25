#!/usr/bin/env bash
# fm-konten-lib.sh - the one reader of the account ledger config/konten.tsv.
#
# Usage (sourced, the normal case):
#   . "$FM_ROOT/bin/fm-konten-lib.sh"
#   fm_konto_pfad <speicher>              print CLAUDE_CONFIG_DIR of a storage
#   fm_konto_rolle <speicher>             print its role
#   fm_konto_fuer_rolle <rolle>           print the FIRST storage holding a role
#   fm_firstmate_sitz                     print the storage holding `firstmate`
#   fm_konto_wrapper <speicher>           basis -> claude, konto-N -> claudeN
#   fm_konto_startfaehig <speicher> <projektpfad>
#                                         0 when a session can actually start
#                                         there, 1 with a loud reason otherwise
#   fm_konten_speicher                    list every storage key, ledger order
#   fm_konten_akte                        print the ledger path in use
#
# Usage (executed, for tests and one-off shell checks):
#   fm-konten-lib.sh <function> [args...]
#   fm-konten-lib.sh --help
#
# One owner: config/konten.tsv is the single source of the seating order, and
# this library is its single reader. Nothing else may parse that file, hardcode
# a `~/.claudeN` path, or infer a seat from a wrapper name. The `rolle` column
# is rewritten by exactly one tool, bin/fm-sitzwechsel.sh.
#
# Ledger location, in order: $FM_KONTEN_AKTE, else $FM_HOME/config/konten.tsv,
# else <repo>/config/konten.tsv. A `$HOME` prefix stored in the `pfad` column is
# expanded on read, so the file stays portable and tests can point HOME at a
# fixture.
#
# Loudness contract (L33, L45, learnings:46):
#   - an unknown `speicher` is a loud abort: message on stderr, status 2. It is
#     never resolved to a guessed path, because a guessed CLAUDE_CONFIG_DIR
#     silently starts a session on the wrong Anthropic account.
#   - an unknown or missing `rolle` is likewise status 2, not a default.
#   - a role nobody holds is status 1 with a named reason.
#   - fm_konto_startfaehig NEVER answers "yes" from missing evidence. Readable
#     quota is not proof of startability: a storage that never finished the
#     interactive setup, or never accepted the trust dialog for the project,
#     drops an agent into the onboarding wizard instead of into work. It checks
#     `hasCompletedOnboarding` and `projects[<projektpfad>].hasTrustDialogAccepted`
#     in <pfad>/.claude.json (python3, falling back to jq) and says which half
#     is missing: `onboarding fehlt` / `trust fehlt fuer <pfad>`. No parser and
#     no readable file are both "not startable", stated out loud.
#
# Shell options are set only when this file is EXECUTED (see the dispatcher at
# the end). A sourced library must not change its caller's `set` flags.

FM_KONTEN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_KONTEN_LIB_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_KONTEN_LIB_DIR/.." && pwd)}"

# Closed set of roles; see the ledger header. Kept here so a typo in the file
# is caught on read instead of steering a spawn.
FM_KONTEN_ROLLEN="firstmate offiziere-worker restverbrauch captain-handbetrieb"

fm_konten_warn() { printf 'fm-konten: %s\n' "$*" >&2; }

# fm_konten_akte: the ledger path in use.
fm_konten_akte() {
  if [ -n "${FM_KONTEN_AKTE:-}" ]; then
    printf '%s\n' "$FM_KONTEN_AKTE"
    return 0
  fi
  if [ -n "${FM_HOME:-}" ] && [ -f "$FM_HOME/config/konten.tsv" ]; then
    printf '%s\n' "$FM_HOME/config/konten.tsv"
    return 0
  fi
  printf '%s\n' "$FM_KONTEN_LIB_ROOT/config/konten.tsv"
}

# fm_konten_expand <pfad>: expand a stored `$HOME` or `~` prefix.
fm_konten_expand() {
  local p=$1
  # shellcheck disable=SC2016 # the ledger stores the literal text `$HOME`.
  case $p in
    '$HOME'/*) printf '%s\n' "$HOME/${p#\$HOME/}" ;;
    '$HOME')   printf '%s\n' "$HOME" ;;
    '~'/*)     printf '%s\n' "$HOME/${p#\~/}" ;;
    *)         printf '%s\n' "$p" ;;
  esac
}

# fm_konten_feld <speicher> <spaltennummer>: raw column value, loud on unknown.
fm_konten_feld() {
  local gesucht=$1 spalte=$2 akte
  akte="$(fm_konten_akte)"
  if [ ! -f "$akte" ]; then
    fm_konten_warn "ledger missing: $akte (expected the account ledger config/konten.tsv)"
    return 2
  fi
  local speicher pfad konto rolle bemerkung
  while IFS=$'\t' read -r speicher pfad konto rolle bemerkung; do
    case $speicher in ''|'#'*) continue ;; esac
    [ "$speicher" = "$gesucht" ] || continue
    case $spalte in
      1) printf '%s\n' "$speicher" ;;
      2) printf '%s\n' "$pfad" ;;
      3) printf '%s\n' "$konto" ;;
      4) printf '%s\n' "$rolle" ;;
      5) printf '%s\n' "$bemerkung" ;;
      *) fm_konten_warn "internal: unknown column $spalte"; return 2 ;;
    esac
    return 0
  done < "$akte"
  fm_konten_warn "unknown speicher '$gesucht' in $akte - known: $(fm_konten_speicher | tr '\n' ' ')"
  return 2
}

# fm_konten_speicher: every storage key, in ledger order.
fm_konten_speicher() {
  local akte speicher rest
  akte="$(fm_konten_akte)"
  [ -f "$akte" ] || return 2
  while IFS=$'\t' read -r speicher rest; do
    case $speicher in ''|'#'*) continue ;; esac
    printf '%s\n' "$speicher"
  done < "$akte"
}

# fm_konto_pfad <speicher>: CLAUDE_CONFIG_DIR of that storage.
fm_konto_pfad() {
  [ $# -eq 1 ] || { fm_konten_warn "usage: fm_konto_pfad <speicher>"; return 2; }
  local roh
  roh="$(fm_konten_feld "$1" 2)" || return 2
  if [ -z "$roh" ]; then
    fm_konten_warn "speicher '$1' has an empty pfad column in $(fm_konten_akte)"
    return 2
  fi
  fm_konten_expand "$roh"
}

# fm_konto_konto <speicher>: the Anthropic login of that storage.
fm_konto_konto() {
  [ $# -eq 1 ] || { fm_konten_warn "usage: fm_konto_konto <speicher>"; return 2; }
  local wert
  wert="$(fm_konten_feld "$1" 3)" || return 2
  if [ -z "$wert" ]; then
    fm_konten_warn "speicher '$1' has an empty anthropic_konto column"
    return 2
  fi
  printf '%s\n' "$wert"
}

# fm_konto_rolle <speicher>: the role of that storage; unknown role aborts loud.
fm_konto_rolle() {
  [ $# -eq 1 ] || { fm_konten_warn "usage: fm_konto_rolle <speicher>"; return 2; }
  local rolle
  rolle="$(fm_konten_feld "$1" 4)" || return 2
  if [ -z "$rolle" ]; then
    fm_konten_warn "speicher '$1' has an empty rolle column in $(fm_konten_akte)"
    return 2
  fi
  fm_konten_rolle_bekannt "$rolle" || {
    fm_konten_warn "speicher '$1' carries unknown rolle '$rolle' - known: $FM_KONTEN_ROLLEN"
    return 2
  }
  printf '%s\n' "$rolle"
}

# fm_konten_rolle_bekannt <rolle>: 0 when the role is part of the closed set.
fm_konten_rolle_bekannt() {
  local kandidat=$1 bekannt
  for bekannt in $FM_KONTEN_ROLLEN; do
    [ "$kandidat" = "$bekannt" ] && return 0
  done
  return 1
}

# fm_konto_fuer_rolle <rolle>: the FIRST storage holding that role.
fm_konto_fuer_rolle() {
  [ $# -eq 1 ] || { fm_konten_warn "usage: fm_konto_fuer_rolle <rolle>"; return 2; }
  local gesucht=$1 akte
  fm_konten_rolle_bekannt "$gesucht" || {
    fm_konten_warn "unknown rolle '$gesucht' - known: $FM_KONTEN_ROLLEN"
    return 2
  }
  akte="$(fm_konten_akte)"
  if [ ! -f "$akte" ]; then
    fm_konten_warn "ledger missing: $akte"
    return 2
  fi
  local speicher pfad konto rolle bemerkung
  while IFS=$'\t' read -r speicher pfad konto rolle bemerkung; do
    case $speicher in ''|'#'*) continue ;; esac
    [ "$rolle" = "$gesucht" ] || continue
    printf '%s\n' "$speicher"
    return 0
  done < "$akte"
  fm_konten_warn "no speicher carries rolle '$gesucht' in $akte"
  return 1
}

# fm_firstmate_sitz: the storage holding the exclusive firstmate seat.
fm_firstmate_sitz() { fm_konto_fuer_rolle firstmate; }

# fm_konto_wrapper <speicher>: the launcher name for that storage.
fm_konto_wrapper() {
  [ $# -eq 1 ] || { fm_konten_warn "usage: fm_konto_wrapper <speicher>"; return 2; }
  fm_konten_feld "$1" 1 >/dev/null || return 2
  case $1 in
    basis) printf 'claude\n' ;;
    konto-[0-9]|konto-[0-9][0-9]) printf 'claude%s\n' "${1#konto-}" ;;
    *)
      fm_konten_warn "speicher '$1' has no wrapper naming rule (expected basis or konto-<N>)"
      return 2
      ;;
  esac
}

# fm_konto_startfaehig <speicher> <projektpfad>: can a session really start?
fm_konto_startfaehig() {
  [ $# -eq 2 ] || { fm_konten_warn "usage: fm_konto_startfaehig <speicher> <projektpfad>"; return 2; }
  local speicher=$1 projekt=$2 pfad json
  pfad="$(fm_konto_pfad "$speicher")" || return 2
  json="$pfad/.claude.json"
  if [ ! -r "$json" ]; then
    fm_konten_warn "$speicher nicht startfaehig: onboarding fehlt ($json unreadable or absent)"
    return 1
  fi
  local rc=0
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$json" "$projekt" <<'PY'
import json, sys
pfad, projekt = sys.argv[1], sys.argv[2]
try:
    with open(pfad, encoding="utf-8") as fh:
        daten = json.load(fh)
except Exception:
    sys.exit(3)
if not isinstance(daten, dict):
    sys.exit(3)
if daten.get("hasCompletedOnboarding") is not True:
    sys.exit(1)
projekte = daten.get("projects")
if not isinstance(projekte, dict):
    sys.exit(2)
eintrag = projekte.get(projekt)
if not isinstance(eintrag, dict) or eintrag.get("hasTrustDialogAccepted") is not True:
    sys.exit(2)
sys.exit(0)
PY
    rc=$?
  elif command -v jq >/dev/null 2>&1; then
    if ! jq -e . "$json" >/dev/null 2>&1; then
      rc=3
    elif ! jq -e '.hasCompletedOnboarding == true' "$json" >/dev/null 2>&1; then
      rc=1
    elif ! jq -e --arg p "$projekt" '(.projects[$p].hasTrustDialogAccepted) == true' "$json" >/dev/null 2>&1; then
      rc=2
    fi
  else
    fm_konten_warn "$speicher nicht startfaehig: kein Parser (python3/jq) - startability unverifiable, refusing to guess"
    return 1
  fi
  case $rc in
    0) return 0 ;;
    1) fm_konten_warn "$speicher nicht startfaehig: onboarding fehlt ($json)"; return 1 ;;
    2) fm_konten_warn "$speicher nicht startfaehig: trust fehlt fuer $projekt ($json)"; return 1 ;;
    3) fm_konten_warn "$speicher nicht startfaehig: $json unlesbar (no valid JSON object)"; return 1 ;;
    *) fm_konten_warn "$speicher nicht startfaehig: unexpected parser status $rc"; return 1 ;;
  esac
}

fm_konten_usage() { sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# Executed directly: dispatch to one function so tests and shell one-liners get
# the real exit status (unknown speicher -> 2) without sourcing gymnastics.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  case "${1:-}" in
    ''|-h|--help) fm_konten_usage; exit 0 ;;
  esac
  case "$1" in
    fm_konto_pfad|fm_konto_rolle|fm_konto_konto|fm_konto_fuer_rolle|fm_firstmate_sitz|\
    fm_konto_wrapper|fm_konto_startfaehig|fm_konten_speicher|fm_konten_akte)
      fn=$1
      shift
      "$fn" "$@"
      exit $?
      ;;
    *)
      fm_konten_warn "unknown function '$1' - see $(basename "${BASH_SOURCE[0]}") --help"
      exit 2
      ;;
  esac
fi
