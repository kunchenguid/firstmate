#!/usr/bin/env bash
# fm-freigabenotiz-lib.sh - the ONE owner of the 5-question Freigabenotiz, the
# approval class vocabulary, the acceptance-block fingerprint, and the
# destructive-marker tripwire.
#
# Usage:
#   . bin/fm-freigabenotiz-lib.sh
#   fm_freigabe_klasse_valid <klasse>            0 known / 1 unknown
#   fm_freigabe_klasse_braucht_vorlage <klasse>  0 needs a captain wording / 1 not
#   fm_freigabe_order_valid <O-xxxx>             0 well-formed order id / 1 not
#   fm_freigabe_notiz_check <datei>              0 answers all five / 1 + error
#   fm_freigabe_abnahme_block <brief>            the acceptance block's lines
#   fm_freigabe_abnahme_sha <brief>              hex64 fingerprint, or "-"
#   fm_freigabe_tripwire <brief>                 0 TRIPPED (markers on stdout) / 1 clean
#   fm_freigabe_mandat_hinweis <brief> <home>    prints a HINWEIS line, always 0
#
# WHY. Firstmate's plan review is a SUBSTANTIVE judgment that takes minutes, not
# a byte signature over a brief (AGENTS.md, Roles: "the 5-question Freigabenotiz
# - content, minutes, never byte signatures"). A cryptographic hash over a whole
# brief proved only that nobody edited a file; it never proved that anyone read
# it. So the thing that gets signed is the note in which the firstmate answers
# five questions in his own words, plus the class he assigned the undertaking.
# The machine can check that all five questions were ANSWERED and that the class
# carries the captain's wording where the fleet requires one; the CONTENT of the
# answers is firstmate's judgment and no tool grades it.
#
# THE FIVE QUESTIONS (this file is the single owner of their machine-readable
# form). The note answers each on ONE line:
#   F1 Praemissen: <what this undertaking assumes to be true>
#   F2 Abnahme:    <how anyone will see it worked>
#   F3 Vision:     <which VISION.md frame this serves>
#   F4 Budget:     <what it may cost, in time or money>
#   F5 Betroffene: <who feels it if it goes wrong>
# "Praemissen" and "Prämissen" are both accepted; nothing else is. Leading
# whitespace is allowed, an empty answer is not: a marker with nothing behind
# the colon is an unanswered question, and unanswered means refused.
#
# THE ACCEPTANCE BLOCK. The one part of a brief that stays byte-bound is its
# "## Abnahme (maschinenlesbar)" block, because that block is what the work will
# be measured against (bin/fm-abnahme.sh owns the block's MEANING and its point
# syntax; this file owns only its fingerprint). fm_freigabe_abnahme_sha prints
# "-" when a brief carries no such block, and a hash of the block's lines when
# it does, so ADDING or REMOVING the block is as much a change as editing it.
#
# THE TRIPWIRE. A "routine" class is a claim that nothing irreversible is in
# play. When the brief itself contradicts that claim, the mismatch is surfaced
# LOUDLY rather than resolved by the tool: the markers are printed and the human
# either re-classifies or states, on the record, why the routine class still
# holds. The tripwire never decides; it refuses to let the contradiction pass
# unremarked.
#
# A TRIPPED tripwire is a RETURN VALUE, not a failure: a caller under `set -e`
# must take the verdict in an `if`, or its own shell dies on the answer it
# asked for.
#
# No side effects on source. set -u / set -e safe.

FM_FREIGABE_KLASSEN="routine destruktiv produkt"
FM_FREIGABE_KLASSEN_MIT_VORLAGE="destruktiv produkt"

FM_FREIGABE_NOTIZ_ERROR=""

# An empty argument can never match: no entry in the vocabulary is empty, and
# " <empty> " would need two adjacent spaces in the list to match.
fm_freigabe_klasse_valid() { # <klasse>
  case " $FM_FREIGABE_KLASSEN " in
    *" ${1:-} "*) return 0 ;;
  esac
  return 1
}

fm_freigabe_klasse_braucht_vorlage() { # <klasse> -> 0 when a captain wording is required
  case " $FM_FREIGABE_KLASSEN_MIT_VORLAGE " in
    *" ${1:-} "*) return 0 ;;
  esac
  return 1
}

# Order ids are minted as O-%04d by bin/fm-order.sh; more digits stay valid so a
# fleet that outgrows four never needs this validator changed.
fm_freigabe_order_valid() { # <order-id>
  [[ ${1:-} =~ ^O-[0-9]{4,}$ ]]
}

fm_freigabe_sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

# 0 when the note answers all five questions; 1 with FM_FREIGABE_NOTIZ_ERROR set
# to a refusal that names exactly which ones are missing.
fm_freigabe_notiz_check() { # <notiz-datei>
  local file=${1:-} n label pattern missing=""
  FM_FREIGABE_NOTIZ_ERROR=""
  if [ -z "$file" ] || [ ! -f "$file" ] || [ -L "$file" ]; then
    FM_FREIGABE_NOTIZ_ERROR="the Freigabenotiz is not an ordinary file: ${file:-<none>}"
    return 1
  fi
  for n in 1 2 3 4 5; do
    case "$n" in
      1) label='F1 Praemissen'
         pattern='^[[:space:]]*F1[[:space:]]+(Praemissen|Prämissen):[[:space:]]*[^[:space:]]' ;;
      2) label='F2 Abnahme'
         pattern='^[[:space:]]*F2[[:space:]]+Abnahme:[[:space:]]*[^[:space:]]' ;;
      3) label='F3 Vision'
         pattern='^[[:space:]]*F3[[:space:]]+Vision:[[:space:]]*[^[:space:]]' ;;
      4) label='F4 Budget'
         pattern='^[[:space:]]*F4[[:space:]]+Budget:[[:space:]]*[^[:space:]]' ;;
      5) label='F5 Betroffene'
         pattern='^[[:space:]]*F5[[:space:]]+Betroffene:[[:space:]]*[^[:space:]]' ;;
    esac
    if ! grep -Eq "$pattern" "$file" 2>/dev/null; then
      missing="${missing:+$missing, }$label"
    fi
  done
  if [ -n "$missing" ]; then
    # shellcheck disable=SC2034 # read by the sourcing caller, which prints it
    FM_FREIGABE_NOTIZ_ERROR="the Freigabenotiz $file leaves these questions unanswered: $missing (each needs one line '<marker>: <answer>', and an empty answer is no answer)"
    return 1
  fi
  return 0
}

# The lines INSIDE the acceptance block, header excluded, block ended by the
# next "## " heading or by EOF. Mirrors bin/fm-abnahme.sh, which owns what the
# block means; this reproduces only where it starts and stops.
fm_freigabe_abnahme_block() { # <brief>
  [ -f "${1:-}" ] || return 0
  awk '
    /^## Abnahme \(maschinenlesbar\)$/ { found=1; next }
    found && /^## / { exit }
    found { print }
  ' "$1" 2>/dev/null
  return 0
}

fm_freigabe_abnahme_has_block() { # <brief>
  [ -f "${1:-}" ] || return 1
  grep -qx '## Abnahme (maschinenlesbar)' "$1" 2>/dev/null
}

# hex64 over the block's lines, or the literal "-" when the brief carries no
# block at all. The two are deliberately distinguishable: a brief that GAINS an
# acceptance block after approval changed what the work is measured against.
fm_freigabe_abnahme_sha() { # <brief>
  if ! fm_freigabe_abnahme_has_block "${1:-}"; then
    printf '%s\n' '-'
    return 0
  fi
  fm_freigabe_abnahme_block "$1" | fm_freigabe_sha256_stdin
}

# 0 = TRIPPED, with one marker per line on stdout. 1 = clean.
# The first group is scanned over the whole brief (an irreversible command is
# irreversible wherever it is written); the German verbs are scanned only inside
# the acceptance block, where "leeren"/"löschen" describe the delivered result
# rather than incidental prose.
fm_freigabe_tripwire() { # <brief>
  local brief=${1:-} hit=1 marker block
  [ -f "$brief" ] || return 1
  for marker in 'rm -rf' 'truncate' '--force'; do
    if grep -iqF -- "$marker" "$brief" 2>/dev/null; then
      printf '%s\n' "$marker"
      hit=0
    fi
  done
  for marker in 'DROP ' 'DELETE FROM'; do
    if grep -qF -- "$marker" "$brief" 2>/dev/null; then
      printf '%s\n' "${marker% }"
      hit=0
    fi
  done
  block=$(fm_freigabe_abnahme_block "$brief")
  if [ -n "$block" ]; then
    for marker in 'leeren' 'löschen' 'loeschen'; do
      if printf '%s\n' "$block" | grep -iqF -- "$marker" 2>/dev/null; then
        printf '%s (Abnahmeblock)\n' "$marker"
        hit=0
      fi
    done
  fi
  return "$hit"
}

# The repo a brief names, or empty. Briefs carry no mandatory repo field, so
# this reads the optional machine-readable "repo: <name>" line and nothing else.
fm_freigabe_brief_repo() { # <brief>
  local repo
  [ -f "${1:-}" ] || return 0
  repo=$(awk 'match($0, /^[ \t]*repo:[ \t]*/) { print substr($0, RSTART + RLENGTH); exit }' "$1" 2>/dev/null)
  repo=${repo%%[[:space:]]*}
  case "$repo" in
    ''|*[!A-Za-z0-9._-]*) return 0 ;;
    .|..) return 0 ;;
  esac
  printf '%s\n' "$repo"
}

# One HINWEIS line when the brief names a repo that has no mandate file on
# either path bin/fm-mandat-check.sh reads. Never fatal, never a refusal: a
# missing mandate does not stop the plan, it stops the MERGE (HR2'), and the
# firstmate is better off hearing that at approval time than at landing time.
fm_freigabe_mandat_hinweis() { # <brief> <home>
  local brief=${1:-} home=${2:-} repo
  repo=$(fm_freigabe_brief_repo "$brief")
  [ -n "$repo" ] || return 0
  [ -n "$home" ] || return 0
  if [ -f "$home/projects/$repo/MANDAT.md" ] || [ -f "$home/data/mandat/$repo.md" ]; then
    return 0
  fi
  printf 'HINWEIS: projects/%s/MANDAT.md is missing - mandate file missing - merge will hold everything (bin/fm-mandat-check.sh)\n' "$repo"
  return 0
}
