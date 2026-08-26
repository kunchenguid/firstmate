#!/usr/bin/env bash
# fm-register-invarianten-lib.sh - the ONE owner of the three register
# invariants the captain's order of 25.08. put on the firstmate
# ("Registerordnung messbar", plan crispy-launching-cookie Z.91/92/198):
#
#   (a) ZIEL      every open post names the product goal it serves,
#                 as the head-line field "(ziel: <repo>/<anker>)"
#   (b) EIGNER    every open post has a nameable owner
#   (c) PLANLOS   no active post sits longer than 7 days without a plan
#                 approval record, and the reminder carries the three valid
#                 answers verbatim
#
# Nothing else owns these three. Callers (bin/fm-register.sh check, the
# Tagesschluss) source this file and print what it returns; they never
# re-derive a rule from it.
#
# Usage:
#   . bin/fm-register-invarianten-lib.sh
#   fm_register_invarianten <backlog-datei> [<heim>]
#
#   <backlog-datei>  a canonical backlog in the data/backlog.md shape.
#   <heim>           the home whose state/, config/ and data/ carry the arming
#                    flag, the area mapping and the secondmate list. Default:
#                    the backlog file's grandparent (<heim>/data/backlog.md).
#
#   stdout  one line per finding, newest rule wording:
#             ziel fehlt: <id>
#             ziel fehlt: <id> - ROT: Ziel-Tor scharf seit <datum>, Posten seit
#               <datum> - (ziel: <repo>/<anker>) nachtragen
#             eigner fehlt: <id> - <what the line carries today>
#             planlos seit <N> Tagen: <id> - planen | parken mit Grund |
#               streichen vorschlagen
#   exit    0 clean, 1 findings (a red one says ROT in its own line),
#           2 error (unreadable backlog, unusable date)
#
# WHICH LINES ARE READ. Only open head lines ("- [ ] <id> - ...") under the
# sections "## In flight" and "## Queued", and only the structured fields ON
# that head line. Done never counts, and prose inside an entry body never
# counts - entries quote each other's syntax constantly, exactly as
# fm-register.sh dead-edges already learned.
#
# (a) ZIEL - WARN IN THE TRANSITION, RED ONLY AFTER ARMING AND TOUCH.
# The field occurs zero times in today's stock (plan Z.96: "0x ziel:"), so a
# gate that blocks on day one would either stop the fleet or be routed around.
# The plan's transition rule is "Nachzug bei Beruehrung, 14 Tage Warnung vor
# Block" (Z.88/143): a missing goal is a WARN line for everyone, and turns RED
# only for posts the fleet TOUCHED after the gate was armed.
#   arming flag: <heim>/state/.register-ziel-scharf
#   flag date:   its first line when that is a YYYY-MM-DD date (the deliberate,
#                auditable form), else the file's mtime date
#   red when:    the flag exists AND the post's own "(since <datum>)" is
#                strictly after the flag date - i.e. the post was created or
#                re-dated after the fleet was warned, so nobody was surprised.
# The 14 days live in the ARMING ACT, not here: the flag is not to be written
# before the warning has stood for 14 days. This library records the flag date
# in every red line and in its Tor-Log entry so that promise stays checkable
# afterwards. A flag whose date cannot be read is loud on stderr and leaves
# every finding at WARN - an unreadable arming never turns anything red, and
# never silently disappears either.
#
# (b) EIGNER - THE CHEAPEST HONEST CARRIER, WHICH IS TODAY'S "(repo: ...)".
# The plan asks for "kein Posten ohne ziel:/Eigner". No backlog line carries a
# "(wer: ...)" field today, and inventing one would mean a migration of every
# line before the invariant could say anything true. What the format DOES carry
# is "(repo: <repo>)", and the fleet already resolves a repo to a named owner
# twice over: data/secondmates.md maps a project to its sm-*, and
# config/register-bereiche maps a repo to the area the firstmate keeps. So the
# owner is read, cheapest first:
#   1. "(wer: <sm-*|firstmate>)" on the head line, when a line ever grows one -
#      honored immediately, so the richer carrier needs no change here later.
#   2. "(repo: -)" or "(repo: firstmate)" -> firstmate itself.
#   3. "(repo: <p>)" where <p> is in a secondmate's "projects:" -> that sm-*.
#   4. "(repo: <r>)" where <r> has a line in config/register-bereiche -> the
#      area the firstmate keeps.
#   5. anything else - no repo field at all, or a repo no home and no area
#      claims - has NO owner and is reported.
# Step 5 is where the honesty sits: fm-register.sh renders an unmapped repo
# under its own name and a missing repo under "Betrieb", but a rendering
# fallback is not an ownership claim, and this invariant refuses to read it as
# one. config/register-bereiche is local and gitignored; a home without it
# simply loses carrier 4, which widens what is reported, never what passes.
#
# (c) PLANLOS - AGE, NOT SILENCE, AND THREE ANSWERS THAT ARE ALL VALID.
# A post counts as planned when a plan approval record exists for its id
# (bin/fm-plan-approval.sh owns the record: state/<task-id>.plan-approval).
# The record can live in this home or in any secondmate home listed in
# data/secondmates.md, because the approving instance is the primary home while
# the record is written into the officer home that will run the work.
# HELD POSTS ARE EXEMT BY DESIGN: a line carrying "(hold: ...)",
# "(hold-kind: ...)" or "(hold-until: ...)" has already been answered with
# "parken mit Grund". Re-reminding it would make parking a worse answer than
# pretending to plan, and the plan is explicit that "parken ist vollwertig
# (kein Vortaeusch-Anreiz)" (Z.92).
# Threshold: 7 days ("Anmahnung ab Tag 7", plan Z.92), inclusive - a post whose
# since date is exactly 7 days back is reminded. Override for tests:
# FM_REGISTER_PLANLOS_TAGE.
# The three answers are printed VERBATIM in every reminder line, because a
# reminder that does not name its exits trains the fleet to ignore it.
#
# CLOCK. `date +%F`, pinned by tests through FM_REGISTER_INVARIANTEN_TODAY
# (YYYY-MM-DD), which fails loudly when it is not a date.
#
# TOR-LOG. Invariant (a) is the only one with an arming flag, so it is the only
# one that logs: exactly one summary line per sweep to the gate "register-ziel"
# via fm_tor_log (bin/fm-tor-log-lib.sh) - gruen when no goal is missing, warn
# in the transition, rot when at least one touched post was refused. One line
# per sweep, never one per post: the sweep is the decision. (b) and (c) are
# reports without an arming flag and log nothing.
#
# This library WRITES NOTHING except that log line. It never edits a backlog,
# never creates a field, and never closes a post.

if [ -z "${FM_REGISTER_INVARIANTEN_LIB_SOURCED:-}" ]; then
  FM_REGISTER_INVARIANTEN_LIB_SOURCED=1
  _fm_ri_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$_fm_ri_dir/fm-tor-log-lib.sh" ]; then
    # shellcheck source=bin/fm-tor-log-lib.sh
    # shellcheck disable=SC1091
    . "$_fm_ri_dir/fm-tor-log-lib.sh"
  fi
  unset _fm_ri_dir
fi
if ! declare -F fm_tor_log >/dev/null 2>&1; then
  # The log is bookkeeping, never the work: a home without the log library
  # still gets its findings.
  fm_tor_log() { :; }
fi

# The field separator between the extractor and the sweep. Deliberately NOT a
# tab: tab is an IFS whitespace character, so `read` would collapse the runs
# that an absent (repo: ...) plus an absent (wer: ...) produce, and every later
# field would shift by one. US (\037) is non-whitespace, cannot appear in a
# backlog line, and keeps empty fields empty.
FM_RI_SEP=$'\037'

# fm_register_invarianten_felder <backlog-datei>
# -> one record per open post, FM_RI_SEP-separated:
#    id | since | ziel(0|1) | repo | wer | hold(0|1)
fm_register_invarianten_felder() {
  awk '
    /^## In flight/ { sec = "inflight"; next }
    /^## Queued/    { sec = "queued";   next }
    /^## /          { sec = "other";    next }
    sec != "inflight" && sec != "queued" { next }
    /^- \[ \] / {
      line = substr($0, 7)
      id = line
      sub(/ - .*/, "", id)
      if (id == "") next
      ziel = (line ~ /\(ziel: [^)]*\)/) ? 1 : 0
      repo = ""
      if (match(line, /\(repo: [^)]*\)/)) repo = substr(line, RSTART + 7, RLENGTH - 8)
      wer = ""
      if (match(line, /\(wer: [^)]*\)/)) wer = substr(line, RSTART + 6, RLENGTH - 7)
      since = ""
      if (match(line, /\(since [^)]*\)/)) since = substr(line, RSTART + 7, RLENGTH - 8)
      hold = 0
      if (line ~ /\(hold: / || line ~ /\(hold-kind: / || line ~ /\(hold-until: /) hold = 1
      printf "%s%s%s%s%d%s%s%s%s%s%d\n", id, SEP, since, SEP, ziel, SEP, repo, SEP, wer, SEP, hold
    }
  ' SEP="$FM_RI_SEP" "$1"
}

# fm_register_invarianten <backlog-datei> [<heim>]
fm_register_invarianten() {
  local backlog=${1:-} heim=${2:-}
  if [ -z "$backlog" ] || [ ! -f "$backlog" ]; then
    printf 'fm-register-invarianten: keine lesbare Backlog-Datei: %s\n' "${backlog:-<leer>}" >&2
    return 2
  fi
  if [ -z "$heim" ]; then
    heim=$(cd "$(dirname "$backlog")/.." 2>/dev/null && pwd) || heim=""
    if [ -z "$heim" ]; then
      printf 'fm-register-invarianten: Heim zu %s nicht aufloesbar\n' "$backlog" >&2
      return 2
    fi
  fi

  local heute heute_ep
  heute=${FM_REGISTER_INVARIANTEN_TODAY:-$(date +%F)}
  case "$heute" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *)
      printf 'fm-register-invarianten: FM_REGISTER_INVARIANTEN_TODAY ist kein Datum (JJJJ-MM-TT): %s\n' "$heute" >&2
      return 2 ;;
  esac
  heute_ep=$(date -d "$heute" +%s 2>/dev/null) || {
    printf 'fm-register-invarianten: Datum unlesbar: %s\n' "$heute" >&2
    return 2
  }

  local planlos_tage=${FM_REGISTER_PLANLOS_TAGE:-7}
  case "$planlos_tage" in
    ''|*[!0-9]*)
      printf 'fm-register-invarianten: FM_REGISTER_PLANLOS_TAGE ist keine Tageszahl: %s\n' "$planlos_tage" >&2
      return 2 ;;
  esac

  # --- (a) arming -----------------------------------------------------------
  local flag="$heim/state/.register-ziel-scharf" flag_datum='' flag_ep=''
  if [ -f "$flag" ]; then
    flag_datum=$(head -n 1 "$flag" 2>/dev/null | tr -d '[:space:]')
    case "$flag_datum" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) flag_datum=$(date -r "$flag" +%F 2>/dev/null) || flag_datum='' ;;
    esac
    if [ -n "$flag_datum" ]; then
      flag_ep=$(date -d "$flag_datum" +%s 2>/dev/null) || flag_ep=''
    fi
    if [ -z "$flag_ep" ]; then
      printf 'fm-register-invarianten: Ziel-Tor ist scharf (%s), aber sein Flag-Datum ist unlesbar - alle Ziel-Befunde bleiben WARN\n' \
        "$flag" >&2
    fi
  fi

  # --- (b) owner carriers ---------------------------------------------------
  # Deliberately not `local`: fm_register_invarianten_eigner reads them, and a
  # named global pair is clearer than relying on bash's dynamic scoping.
  unset FM_RI_SM_VON_REPO FM_RI_BEREICH_VON_REPO
  declare -gA FM_RI_SM_VON_REPO=() FM_RI_BEREICH_VON_REPO=()
  local sm_zeile smid projects hm p
  local -a state_dirs=("$heim/state")
  local sm_datei="$heim/data/secondmates.md"
  if [ -f "$sm_datei" ]; then
    while IFS= read -r sm_zeile; do
      case "$sm_zeile" in '- sm-'*) ;; *) continue ;; esac
      smid=${sm_zeile#- }
      smid=${smid%% *}
      projects=''
      case "$sm_zeile" in
        *'projects: '*)
          projects=${sm_zeile##*projects: }
          projects=${projects%%;*}
          projects=${projects%%)*} ;;
      esac
      hm=''
      case "$sm_zeile" in
        *'home: '*)
          hm=${sm_zeile#*home: }
          hm=${hm%%;*}
          hm=${hm%%)*} ;;
      esac
      [ -z "$hm" ] || state_dirs+=("$hm/state")
      for p in ${projects//,/ }; do
        [ -n "$p" ] || continue
        FM_RI_SM_VON_REPO["$p"]=$smid
      done
    done < "$sm_datei"
  fi

  local bereiche="${FM_CONFIG_OVERRIDE:-$heim/config}/register-bereiche"
  local tab titel repos r
  tab=$(printf '\t')
  if [ -f "$bereiche" ]; then
    while IFS="$tab" read -r titel repos; do
      case "$titel" in ''|'#'*) continue ;; esac
      for r in $repos; do
        [ -n "$r" ] || continue
        FM_RI_BEREICH_VON_REPO["$r"]=$titel
      done
    done < "$bereiche"
  fi

  # --- sweep ----------------------------------------------------------------
  local id since ziel repo wer hold since_ep alter
  local offen=0 ziel_fehlt=0 ziel_rot=0 eigner_fehlt=0 planlos=0 befunde=0
  while IFS="$FM_RI_SEP" read -r id since ziel repo wer hold; do
    [ -n "$id" ] || continue
    offen=$((offen + 1))

    since_ep=''
    alter=''
    if [ -n "$since" ]; then
      since_ep=$(date -d "$since" +%s 2>/dev/null) || since_ep=''
    fi
    if [ -n "$since_ep" ]; then
      alter=$(( (heute_ep - since_ep) / 86400 ))
    fi

    # (a) ziel
    if [ "$ziel" = 0 ]; then
      ziel_fehlt=$((ziel_fehlt + 1))
      befunde=1
      if [ -n "$flag_ep" ] && [ -n "$since_ep" ] && [ "$since_ep" -gt "$flag_ep" ]; then
        ziel_rot=$((ziel_rot + 1))
        printf 'ziel fehlt: %s - ROT: Ziel-Tor scharf seit %s, Posten seit %s - (ziel: <repo>/<anker>) nachtragen\n' \
          "$id" "$flag_datum" "$since"
      else
        printf 'ziel fehlt: %s\n' "$id"
      fi
    fi

    # (b) eigner
    if ! fm_register_invarianten_eigner "$wer" "$repo"; then
      eigner_fehlt=$((eigner_fehlt + 1))
      befunde=1
      if [ -n "$repo" ]; then
        printf 'eigner fehlt: %s - (repo: %s) kennt weder ein Zweitoffiziers-Heim noch einen Bereich; (wer: sm-<x>|firstmate) nachtragen\n' \
          "$id" "$repo"
      else
        printf 'eigner fehlt: %s - kein (repo:)- und kein (wer:)-Feld auf der Zeile\n' "$id"
      fi
    fi

    # (c) planlos
    if [ "$hold" = 0 ] && [ -n "$alter" ] && [ "$alter" -ge "$planlos_tage" ]; then
      if ! fm_register_invarianten_plan "$id" "${state_dirs[@]}"; then
        planlos=$((planlos + 1))
        befunde=1
        printf 'planlos seit %s Tagen: %s - planen | parken mit Grund | streichen vorschlagen\n' \
          "$alter" "$id"
      fi
    fi
  done < <(fm_register_invarianten_felder "$backlog")

  local verdikt=gruen ausweg='-'
  if [ "$ziel_rot" -gt 0 ]; then
    verdikt=rot
    ausweg='ziel-nachtragen'
  elif [ "$ziel_fehlt" -gt 0 ]; then
    verdikt=warn
    ausweg='uebergangszeit-nachzug-bei-beruehrung'
  fi
  fm_tor_log register-ziel - "$verdikt" "$ausweg" \
    "backlog=$backlog offen=$offen ziel-fehlt=$ziel_fehlt rot=$ziel_rot eigner-fehlt=$eigner_fehlt planlos=$planlos flag=${flag_datum:--}"

  [ "$befunde" = 0 ] || return 1
  return 0
}

# fm_register_invarianten_eigner <wer-feld> <repo-feld> -> 0 when an owner is
# nameable. Carrier order is the header's list, cheapest first.
fm_register_invarianten_eigner() {
  local wer=${1:-} repo=${2:-}
  case "$wer" in
    sm-*|firstmate) return 0 ;;
  esac
  case "$repo" in
    '') return 1 ;;
    '-'|firstmate) return 0 ;;
  esac
  [ -z "${FM_RI_SM_VON_REPO[$repo]:-}" ] || return 0
  [ -z "${FM_RI_BEREICH_VON_REPO[$repo]:-}" ] || return 0
  return 1
}

# fm_register_invarianten_plan <task-id> <state-dir>... -> 0 when a plan
# approval record for the id exists in any of the given state directories.
fm_register_invarianten_plan() {
  local id=$1 dir
  shift
  for dir in "$@"; do
    [ -f "$dir/$id.plan-approval" ] && return 0
  done
  return 1
}
