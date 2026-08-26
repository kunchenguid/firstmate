#!/usr/bin/env bash
# fm-mandat-check.sh - TOR: Captain-Klassen-Pfadliste (Plan Entwurf C Punkt 4).
# A diff that touches a captain-reserved path class holds for the captain
# instead of landing quietly; a repo with no mandate file at all holds too -
# HR2' (AGENTS.md): "a hit or a missing mandate file holds for the captain".
#
# Usage:
#   fm-mandat-check.sh <repo> <branch-oder-range> [--repo-dir <pfad>]
#       checks the diff for <repo> against its mandate. Exit 0 = frei.
#       Exit 3 = Captain-Klasse or missing mandate; stdout carries one
#       "<klasse>\t<muster>\t<getroffene datei>" row per hit (or the literal
#       line "alles hold: kein Mandat" when no mandate file exists at all);
#       stderr carries the loud refusal (source quote + named Ausweg).
#   fm-mandat-check.sh erweitern <repo> --klasse <k> --muster '<glob>' \
#       --grund '<text>' [--repo-dir <pfad>]
#       appends <glob> to <k> in the active mandate file (anyone may do this
#       immediately - no captain word required for the extension itself) and
#       deposits a Rücklauf-Markerdatei with a 14-day return deadline.
#   fm-mandat-check.sh --help
#
# MANDAT-FILE FORMAT (this TOR is Ein-Eigner of this format):
#   A section headed by the exact line "# Captain-Klassen", followed by one
#   line per class: "<klasse>: <glob1>, <glob2>, ..." - comma-separated glob
#   patterns, whitespace around each pattern trimmed. The section ends at the
#   next line starting with "#" or at EOF. Valid classes (fixed, closed set):
#     geld nutzerdaten sicherheit oeffentlich vision destruktiv
#   Any other class name in the file is a format error and aborts loudly
#   (L33: unknown value = abort, never a silent fallback) - never silently
#   ignored, since an ignored line would silently widen the free path.
#
# SOURCE PATH (per repo, read priority):
#   1. <repo-dir>/MANDAT.md               - the project's own mandate, once
#                                            it has migrated one in.
#   2. $FM_HOME/data/mandat/<repo>.md      - Übergangszeit fallback for repos
#                                            that have not migrated yet.
#   Both missing => exit 3 "alles hold: kein Mandat" (fail-closed, explicit
#   in Entwurf C Punkt 4 - a repo nobody has classified yet is not "frei",
#   it is unclassified, and unclassified holds).
#   <repo-dir> defaults to $FM_HOME/projects/<repo>; --repo-dir overrides it.
#
# GLOB CHOICE: bash pattern matching (`[[ "$file" == $pattern ]]`), not git
# pathspec. Reasons: the mandate file is edited by hand by whoever names a
# captain class, and bash globs (*, ?, [...]) are the syntax every maintainer
# here already reads in this file's own header comments and in other bin/
# scripts (fm-gex-drift.sh's PATH FILTER uses the same idiom) - no pathspec
# magic characters (":(exclude)", "**" with git's recursive meaning) to learn
# or get subtly wrong. Trade-off, documented: bash's `*` also crosses `/`
# (no globstar distinction), so "payments/*" already matches
# "payments/x/y.ts" - broader than a naive reader might expect. Pick patterns
# accordingly, or use "payments/*.ts" etc. to narrow.
#
# DIFF WINDOW: <branch-oder-range> is either a plain branch/ref name - in
# which case the diff is merge-base(<default-branch>, <ref>)..<ref> - or an
# explicit git range containing ".." (e.g. "A...B"), passed straight to
# `git diff --name-only`. <default-branch> is read from the repo's
# refs/remotes/origin/HEAD, falling back to a local main/master branch.
#
# TOR CONTRACT (general, all TOREN):
#   1. First checks its Scharfschalt-Flag $FM_HOME/state/.tor-mandat-scharf.
#      Absent => exit 0, silent passage (Übergangsregel: TOREN are built but
#      go live only after whole-system verification). This is unconditional -
#      even a missing mandate does not refuse while the TOR is unarmed.
#   2. Armed and refusing => LOUD: the refusal names the source it read
#      (Entwurf C Punkt 4 wording, or the matched "<klasse>: <muster>" line
#      itself) AND a concrete Ausweg, in the refusal message itself.
#   3. Every decision (armed or not, hit or free) writes one JSONL line via
#      fm_tor_log from bin/fm-tor-log-lib.sh (state/tor-log/mandat.jsonl,
#      append-only). That lib is being built alongside this script; if it is
#      not present yet, a local no-op stands in (marked TOR-LOG-LIB below) so
#      this script runs standalone either way.
#
# `erweitern` is NOT gated by the Scharfschalt-Flag - "erweitern darf jeder
# sofort" (Entwurf C Punkt 4): widening a boundary is a documented, dated,
# immediately-reversible act, not a captain-word gate. It refuses instead
# under HR1 (AGENTS.md, untouchable: "the firstmate never writes into
# projects") whenever the active mandate file is inside the project checkout
# (<repo-dir>/MANDAT.md exists) - that file only changes through the
# project's own delivery path, never a direct write from here. In that case
# `erweitern` writes nothing (no fallback edit, no marker - nothing was
# actually widened) and names the delivery path as the Ausweg instead. When
# no project MANDAT.md exists yet, `erweitern` targets (and creates, if
# needed) the Übergangszeit fallback file directly.
#
# Building the Brett-Karte from a Rücklauf-Markerdatei is NOT owned here -
# only the marker file itself: $FM_HOME/state/mandat-rücklauf/<repo>-<utc
# timestamp>.md, key: value lines (repo, klasse, muster, grund, erstellt,
# frist = today + 14 days).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FLAG="$STATE/.tor-mandat-scharf"
TOR_NAME="mandat"
KNOWN_KLASSEN=" geld nutzerdaten sicherheit oeffentlich vision destruktiv "

if [ -f "$SCRIPT_DIR/fm-tor-log-lib.sh" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/fm-tor-log-lib.sh"
else
  # TODO-Marker: TOR-LOG-LIB - bin/fm-tor-log-lib.sh not yet built; local
  # no-op fallback keeps this TOR runnable standalone until it lands.
  fm_tor_log() { :; }
fi

usage() { sed -n '2,39p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 2; }

is_known_klasse() {
  case "$KNOWN_KLASSEN" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

default_branch() {
  local dir="$1" ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# parse_mandat <file>: fills global arrays K_LIST/P_LIST with one entry per
# (klasse, glob) pair found in the file's "# Captain-Klassen" section.
K_LIST=()
P_LIST=()
parse_mandat() {
  local file="$1" insec=0 line klasse rest pat
  K_LIST=()
  P_LIST=()
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$insec" -eq 0 ]; then
      case "$line" in
        '# Captain-Klassen'*) insec=1 ;;
      esac
      continue
    fi
    case "$line" in
      '#'*) insec=0; continue ;;
    esac
    if [[ "$line" =~ ^([a-z]+):[[:space:]]*(.*)$ ]]; then
      klasse="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[2]}"
      is_known_klasse "$klasse" || die "unknown Captain-Klasse '$klasse' in $file (known: geld nutzerdaten sicherheit oeffentlich vision destruktiv)"
      IFS=',' read -ra parts <<< "$rest"
      for pat in "${parts[@]}"; do
        pat="$(trim "$pat")"
        [ -n "$pat" ] || continue
        K_LIST+=("$klasse")
        P_LIST+=("$pat")
      done
    fi
  done < "$file"
}

# append_pattern <file> <klasse> <muster>: appends <muster> to the existing
# "<klasse>: ..." line in <file>'s Captain-Klassen section, or adds a new
# "<klasse>: <muster>" line at the end of that section if none exists yet.
append_pattern() {
  local file="$1" klasse="$2" muster="$3" tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  awk -v k="$klasse" -v p="$muster" '
    BEGIN { insec = 0; done = 0 }
    /^# Captain-Klassen[[:space:]]*$/ {
      print; insec = 1; next
    }
    insec && /^#/ {
      if (!done) { print k ": " p; done = 1 }
      insec = 0; print; next
    }
    insec && $0 ~ ("^" k ":") {
      sub(/[[:space:]]*$/, "")
      print $0 ", " p
      done = 1
      next
    }
    { print }
    END {
      if (insec && !done) { print k ": " p }
      if (!insec && !done) { print "# Captain-Klassen"; print k ": " p }
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

cmd="${1:-}"
case "$cmd" in
  --help|-h|"")
    usage
    exit 0
    ;;
  erweitern)
    shift
    repo="${1:-}"
    [ -n "$repo" ] || die "erweitern needs <repo>"
    shift
    klasse=""
    muster=""
    grund=""
    repo_dir_override=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --klasse) klasse="${2:-}"; shift 2 ;;
        --muster) muster="${2:-}"; shift 2 ;;
        --grund) grund="${2:-}"; shift 2 ;;
        --repo-dir) repo_dir_override="${2:-}"; shift 2 ;;
        *) die "erweitern: unknown argument '$1'" ;;
      esac
    done
    [ -n "$klasse" ] || die "erweitern needs --klasse"
    [ -n "$muster" ] || die "erweitern needs --muster"
    [ -n "$grund" ] || die "erweitern needs --grund"
    is_known_klasse "$klasse" || die "unknown Captain-Klasse '$klasse' (known: geld nutzerdaten sicherheit oeffentlich vision destruktiv)"

    repo_dir="${repo_dir_override:-$FM_HOME/projects/$repo}"
    project_file="$repo_dir/MANDAT.md"
    fallback_file="$FM_HOME/data/mandat/$repo.md"

    if [ -f "$project_file" ]; then
      echo "error: MANDAT TOR (repo '$repo'): refusing to extend '$project_file' directly." >&2
      echo "  source: AGENTS.md HR1 (untouchable) - \"the firstmate never writes into projects\"." >&2
      echo "  Ausweg: land the class '$klasse' / pattern '$muster' via $repo's own delivery path (a PR that edits its MANDAT.md), citing: $grund" >&2
      echo "  Nothing was written; no Rücklauf-Markerdatei was created." >&2
      fm_tor_log "$TOR_NAME" mandat-erweitern-refused warn - "$repo klasse=$klasse muster=$muster: active mandate is project-owned"
      exit 2
    fi

    mkdir -p "$FM_HOME/data/mandat"
    if [ ! -f "$fallback_file" ]; then
      printf '# Captain-Klassen\n' > "$fallback_file"
    fi
    append_pattern "$fallback_file" "$klasse" "$muster"

    mkdir -p "$STATE/mandat-rücklauf"
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    marker="$STATE/mandat-rücklauf/$repo-$ts.md"
    frist="$(date -u -d '+14 days' +%F)"
    {
      printf 'repo: %s\n' "$repo"
      printf 'klasse: %s\n' "$klasse"
      printf 'muster: %s\n' "$muster"
      printf 'grund: %s\n' "$grund"
      printf 'erstellt: %s\n' "$(utc_now)"
      printf 'frist: %s\n' "$frist"
    } > "$marker"

    fm_tor_log "$TOR_NAME" mandat-erweitern warn erweitern "$repo klasse=$klasse muster=$muster"
    echo "extended $fallback_file: $klasse += $muster"
    echo "Rücklauf-Marker: $marker (Frist $frist)"
    exit 0
    ;;
  *)
    repo="$cmd"
    shift
    branch_or_range="${1:-}"
    [ -n "$branch_or_range" ] || die "missing <branch-oder-range>"
    shift
    repo_dir_override=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo-dir) repo_dir_override="${2:-}"; shift 2 ;;
        *) die "unknown argument '$1'" ;;
      esac
    done

    if [ ! -f "$FLAG" ]; then
      fm_tor_log "$TOR_NAME" mandat-scharf-off gruen - "$repo $branch_or_range: TOR unarmed, silent passage"
      exit 0
    fi

    repo_dir="${repo_dir_override:-$FM_HOME/projects/$repo}"
    [ -d "$repo_dir" ] || die "repo-dir '$repo_dir' does not exist"
    git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1 || die "repo-dir '$repo_dir' is not a git repository"

    project_file="$repo_dir/MANDAT.md"
    fallback_file="$FM_HOME/data/mandat/$repo.md"
    if [ -f "$project_file" ]; then
      mandat_file="$project_file"
    elif [ -f "$fallback_file" ]; then
      mandat_file="$fallback_file"
    else
      echo "alles hold: kein Mandat" >&2
      echo "error: MANDAT TOR (repo '$repo'): alles hold: kein Mandat." >&2
      echo "  source: Plan Entwurf C Punkt 4 - \"FEHLEN BEIDE => exit 3 'alles hold: kein Mandat' (fail-closed, ausdrücklich)\"." >&2
      echo "  missing: $project_file and $fallback_file (Übergangszeit-Fallback) - neither exists." >&2
      echo "  Ausweg: land a MANDAT.md into the project via its delivery path, or run:" >&2
      echo "    fm-mandat-check.sh erweitern $repo --klasse <klasse> --muster '<glob>' --grund '<text>'" >&2
      echo "  which creates + extends the fallback file immediately (no project write, so HR1 does not apply here)." >&2
      fm_tor_log "$TOR_NAME" mandat-fehlt rot - "$repo $branch_or_range: neither $project_file nor $fallback_file exists"
      exit 3
    fi

    if [[ "$branch_or_range" == *..* ]]; then
      files_raw="$(git -C "$repo_dir" diff --name-only "$branch_or_range")" || die "git diff failed for range '$branch_or_range' in $repo_dir"
    else
      default="$(default_branch "$repo_dir")" || die "cannot resolve a default branch in $repo_dir"
      base="$(git -C "$repo_dir" merge-base "$default" "$branch_or_range" 2>/dev/null)" || die "no merge-base between '$default' and '$branch_or_range' in $repo_dir"
      files_raw="$(git -C "$repo_dir" diff --name-only "$base" "$branch_or_range")" || die "git diff failed for $base..$branch_or_range in $repo_dir"
    fi
    mapfile -t FILES <<< "$files_raw"

    parse_mandat "$mandat_file"

    hits=0
    struck_klassen=""
    for i in "${!K_LIST[@]}"; do
      klasse="${K_LIST[$i]}"
      pat="${P_LIST[$i]}"
      for f in "${FILES[@]}"; do
        [ -n "$f" ] || continue
        # shellcheck disable=SC2053  # deliberate glob match, see header GLOB CHOICE
        if [[ "$f" == $pat ]]; then
          printf '%s\t%s\t%s\n' "$klasse" "$pat" "$f"
          hits=$((hits + 1))
          case "$struck_klassen" in
            *" $klasse "*) : ;;
            *) struck_klassen="$struck_klassen $klasse " ;;
          esac
        fi
      done
    done

    if [ "$hits" -gt 0 ]; then
      echo "error: MANDAT TOR (repo '$repo'): Captain-Klasse getroffen ($hits Treffer:${struck_klassen%  }) - siehe Zeilen oben." >&2
      echo "  source: $mandat_file, Abschnitt 'Captain-Klassen' (Plan Entwurf C Punkt 4)." >&2
      echo "  Ausweg: get the captain's explicit word for this change, or broaden the boundary yourself via:" >&2
      echo "    fm-mandat-check.sh erweitern $repo --klasse <klasse> --muster '<glob>' --grund '<text>'" >&2
      echo "  (effective immediately; opens a 14-day Rücklauf-Marker for board review)." >&2
      fm_tor_log "$TOR_NAME" mandat-treffer rot - "$repo $branch_or_range: $hits hit(s), klassen:$struck_klassen"
      exit 3
    fi

    fm_tor_log "$TOR_NAME" mandat-frei gruen - "$repo $branch_or_range: frei"
    exit 0
    ;;
esac
