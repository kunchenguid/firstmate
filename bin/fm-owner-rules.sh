#!/usr/bin/env bash
# fm-owner-rules.sh - the shared owner-rules surface and the command that writes it.
#
# Usage:
#   fm-owner-rules.sh init [--force]
#   fm-owner-rules.sh add --words "<the owner's own words>" --scope <scope> \
#     --enforce <where it is enforced> [--date YYYY-MM-DD] [--title <one line>]
#   fm-owner-rules.sh audit [--fail] [--source <file-or-directory>]...
#
# The surface is $DATA/owner-rules.md: one entry per standing owner decision,
# each carrying the owner's verbatim words, the date, the scope, and the code or
# contract that enforces it. It is the only shared home for an owner correction.
# bin/fm-session-start.sh prints it in every session's context digest, so every
# worker in every project reads it; a correction that lives in one agent's
# memory or notes instead is what `audit` exists to catch.
#
# init    Write the surface header and the standing decisions already given.
#         Refuses to overwrite an existing surface unless --force is passed.
# add     Append one entry. It refuses an entry that carries no owner words, no
#         scope, or no enforcement point, an enforcement point that names a
#         missing repository path, words already recorded in this surface, and
#         words holding a line break (one entry is one line per field).
#         --date defaults to today in UTC and must be YYYY-MM-DD.
# audit   Report every owner quote that a private memory, notes or agent-config
#         file still holds and that this surface, the shared captain files, and
#         the tracked code never carry: a rule enforced only in one agent's
#         memory. Exit 0 with findings by default (a report); --fail makes
#         findings fatal. Sources default to $DATA/learnings.md plus every path
#         named in $CONFIG/owner-rule-sources (one file or directory per line,
#         `~` allowed), plus each --source given. A directory contributes its
#         *.md and *.txt files.
#         The quote test is verbatim and literal, so a paraphrase is invisible
#         to it, and JSONL session logs are not parsed - export the text you
#         want checked into a notes file and point a source at it.
#         ponytail: verbatim quote matching only, add paraphrase scoring if a
#         real correction is ever missed this way.
#
# Entry format, machine-readable by this command and readable as prose:
#   ## 2026-10-25 - Questions go on the board
#   - Scope: every captain-facing reply
#   - Enforced by: bin/fm-turnend-guard.sh; bin/fm-question-card.sh
#   - Owner's words: "..."
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SURFACE="$DATA/owner-rules.md"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'fm-owner-rules: %s\n' "$1" >&2; exit 2; }

flow() { printf '%s' "$1" | tr '\n\t' '  ' | tr -s ' ' | sed 's/^ //; s/ $//'; }

surface_header() {
  cat <<'EOF'
# Owner rules

Standing decisions the owner gave the fleet, one entry each, in his own words.
This is the only shared home for an owner correction: workers read it with the session digest, and a rule kept in one agent's memory is not a rule.
Write entries with `bin/fm-owner-rules.sh add`; find quotes still trapped in private notes with `bin/fm-owner-rules.sh audit`.
EOF
}

seed_entries() {
  cat <<'EOF'

## 2026-10-25 - Corrections become rules, not one agent's memory
- Scope: every owner correction, in every project
- Enforced by: bin/fm-owner-rules.sh; bin/fm-session-start.sh
- Owner's words: "also these corrections I make should be in juggernaut not just in your memory the whole system should understand these things"

## 2026-10-25 - Questions go on the board
- Scope: every captain-facing reply that asks him something
- Enforced by: bin/fm-turnend-guard.sh; bin/fm-question-card.sh
- Owner's words: "if you ask questions as well make sure they are posted, posting questions will be stricter way of working"

## 2026-10-25 - A captain ask is top priority and is never dropped
- Scope: intake, triage, and every plan change
- Enforced by: bin/fm-tasks-axi.sh; bin/fm-captain-ask-lib.sh
- Owner's words: "Going forward what ever I am asking is top top priority and has to be done side stuff that shows up and adds scope creep needs my approval nothing gets silently dropped or descoped without me knowing form what I had told"

## 2026-10-25 - No added scope; new ideas go to a board card first
- Scope: every task's brief and every review finding
- Enforced by: bin/fm-brief.sh; bin/fm-dod-lib.sh
- Owner's words: "Adding scope is a strict no no from now on if you need to add something I should know and should be presented as a plan / decision in sign off"

## 2026-10-25 - A blocked-captain item waits; the work keeps moving
- Scope: any item held for the owner
- Enforced by: bin/fm-captain-hold.sh; .agents/skills/captain-hold-lifecycle/SKILL.md
- Owner's words: "Agents management is under your responsibility ... things to keep moving is your responsibility if something is blocked on me keep it blocked move to something that is unblocked and wait on the blocked thing for me"

## 2026-10-25 - Direct pull request with proof is the default route
- Scope: routing every change to a delivery path
- Enforced by: bin/fm-project-mode.sh; bin/fm-spawn.sh
- Owner's words: "we are somehow abusing no mistakes ... most of it can go as a direct PR with the done-done check alone"

## 2026-10-25 - Backlog intake is strict; every item carries its justification
- Scope: filing work in any home
- Enforced by: bin/fm-tasks-axi.sh
- Owner's words: "pushing work into backlog be strict what sort of work it is and every thing should have justification not just busy work"
EOF
}

cmd_init() {
  local force=0
  [ "${1:-}" = --force ] && force=1
  mkdir -p "$DATA" || die "cannot create $DATA"
  if [ -e "$SURFACE" ] && [ "$force" -eq 0 ]; then
    die "$SURFACE already exists; pass --force to rewrite it"
  fi
  { surface_header; seed_entries; } > "$SURFACE" || die "cannot write $SURFACE"
  printf 'wrote %s\n' "$SURFACE"
}

require_repo_paths() {  # <enforcement point> -> refuse a named path that does not exist
  local token path
  for token in $(printf '%s' "$1" | tr ';,()' '    '); do
    case "$token" in
      */*) ;;
      *) continue ;;
    esac
    case "$token" in
      *://*) continue ;;
    esac
    path=$token
    case "$path" in
      /*) ;;
      *) path="$FM_ROOT/$path" ;;
    esac
    [ -e "$path" ] || die "the enforcement point names $token, which does not exist in this checkout (fix --enforce)"
  done
}

words_already_recorded() {  # <normalized words>
  [ -f "$SURFACE" ] || return 1
  grep -Fq -- "$1" "$SURFACE"
}

cmd_add() {
  local words='' scope='' enforce='' date='' title=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --words) shift; [ $# -gt 0 ] || die "--words needs a value"; words=$1 ;;
      --scope) shift; [ $# -gt 0 ] || die "--scope needs a value"; scope=$1 ;;
      --enforce) shift; [ $# -gt 0 ] || die "--enforce needs a value"; enforce=$1 ;;
      --date) shift; [ $# -gt 0 ] || die "--date needs a value"; date=$1 ;;
      --title) shift; [ $# -gt 0 ] || die "--title needs a value"; title=$1 ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done

  [ -n "$words" ] || die "refused: the entry needs the owner's own words (--words \"...\")"
  if [ "$(printf '%s' "$words" | wc -l | tr -d ' ')" -ne 0 ]; then
    die "refused: --words must be one line; quote the sentence he said"
  fi
  words=$(flow "$words")
  [ "$(printf '%s' "$words" | wc -w | tr -d ' ')" -ge 3 ] \
    || die "refused: --words needs at least three words of his own; a paraphrase is not a rule"

  scope=$(flow "$scope")
  [ -n "$scope" ] || die "refused: the entry needs a scope (--scope <where it applies>)"

  enforce=$(flow "$enforce")
  case "$enforce" in
    ''|none|None|NONE|n/a|N/A|-|todo|TODO)
      die "refused: the entry needs an enforcement point; a rule with nothing enforcing it is a wish (--enforce <script or contract>)" ;;
  esac
  require_repo_paths "$enforce"

  [ -n "$date" ] || date=$(date -u +%Y-%m-%d)
  case "$date" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) die "refused: --date must be YYYY-MM-DD (got '$date')" ;;
  esac

  [ -n "$title" ] || title=$(printf '%s' "$words" | cut -c1-60)
  title=$(flow "$title")

  mkdir -p "$DATA" || die "cannot create $DATA"
  [ -f "$SURFACE" ] || { surface_header > "$SURFACE" || die "cannot write $SURFACE"; }
  words_already_recorded "$words" && die "refused: these words are already recorded in $SURFACE"

  {
    printf '\n## %s - %s\n' "$date" "$title"
    printf -- '- Scope: %s\n' "$scope"
    printf -- '- Enforced by: %s\n' "$enforce"
    printf -- '- Owner'"'"'s words: "%s"\n' "$words"
  } >> "$SURFACE" || die "cannot write $SURFACE"
  printf 'recorded: %s\n' "$title"
}

normalize() { tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' ' ' | tr -s ' \n' ' '; }

audit_sources() {
  local extra=$1 src rest
  [ -f "$DATA/learnings.md" ] && printf '%s\n' "$DATA/learnings.md"
  if [ -f "$CONFIG/owner-rule-sources" ]; then
    while IFS= read -r src; do
      src=$(printf '%s' "$src" | sed 's/[[:space:]]*$//')
      case "$src" in ''|'#'*) continue ;; esac
      rest=${src#\~}
      [ "$rest" = "$src" ] || src="$HOME$rest"
      printf '%s\n' "$src"
    done < "$CONFIG/owner-rule-sources"
  fi
  [ -z "$extra" ] || printf '%s\n' "$extra"
}

audit_files() {  # <source list file> -> the text files to scan
  local src f
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    if [ -d "$src" ]; then
      find "$src" -maxdepth 2 -type f \( -name '*.md' -o -name '*.txt' \) 2>/dev/null \
        | LC_ALL=C sort | head -n 200 | sed 's/^/S /'
    elif [ -f "$src" ]; then
      printf 'S %s\n' "$src"
    fi
  done < "$1"
}

cmd_audit() {
  local fail=0 extra=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --fail) fail=1 ;;
      --source) shift; [ $# -gt 0 ] || die "--source needs a value"; extra="$extra$1
" ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done

  local tmp rc=0 quoted='' quotes unscanned=0 finding
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-owner-rules.XXXXXX") || die "cannot create a temporary directory"
  trap 'rm -f -- "$tmp"/* 2>/dev/null; rmdir -- "$tmp" 2>/dev/null || true' EXIT
  audit_sources "$extra" > "$tmp/sources" || true
  audit_files "$tmp/sources" > "$tmp/files" || true

  {
    for f in "$SURFACE" "$DATA/captain.md" "$DATA/captain-shared.md" "$FM_ROOT/AGENTS.md"; do
      [ -f "$f" ] && cat "$f"
    done
    find "$FM_ROOT/bin" "$FM_ROOT/docs" "$FM_ROOT/.agents/skills" -type f 2>/dev/null \
      | grep -v '^'"$FM_ROOT"'/bin/fm-owner-rules.sh$' | while IFS= read -r f; do cat "$f" 2>/dev/null; done
  } | normalize > "$tmp/surface" 2>/dev/null || true

  local f
  quoted=''
  while IFS= read -r f; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    quoted="$quoted$(LC_ALL=C awk '
      { while (match($0, /"[^"]{8,}"/)) {
          q = substr($0, RSTART + 1, RLENGTH - 2)
          print FILENAME "\t" FNR "\t" q
          $0 = substr($0, RSTART + RLENGTH)
        } }' "$f" 2>/dev/null | LC_ALL=C awk -F'\t' '
      { n = split($3, w, /[^A-Za-z0-9]+/); c = 0
        for (i = 1; i <= n; i++) if (length(w[i]) > 1) c++
        if (c >= 4) print }' 2>/dev/null)"$'\n'
  done < <(cut -c3- "$tmp/files")

  quotes=$(printf '%s' "$quoted" | grep -c . || true)
  [ "$quotes" -gt 0 ] || unscanned=1
  while IFS=$'\t' read -r file line text; do
    [ -n "$file" ] || continue
    finding=$(printf '%s' "$text" | normalize)
    grep -Fq -- "$finding" "$tmp/surface" && continue
    rc=1
    printf 'private: %s:%s\n  words: "%s"\n  fix: bin/fm-owner-rules.sh add --words "%s" --scope <scope> --enforce <script or contract>\n' \
      "$file" "$line" "$text" "$text"
  done <<< "$quoted"

  if [ "$unscanned" -eq 1 ]; then
    printf 'no owner quotes found in %s source path(s); nothing to report (name more sources in %s)\n' \
      "$(grep -c . "$tmp/sources" 2>/dev/null || printf 0)" "$CONFIG/owner-rule-sources"
  elif [ "$rc" -eq 0 ]; then
    printf 'clean: all %s quoted owner words in the scanned notes are already in the shared surface or the code\n' "$quotes"
  else
    printf 'flagged: quoted owner words above live only in a private note; record each one with bin/fm-owner-rules.sh add\n'
  fi
  [ "$fail" -eq 1 ] && [ "$rc" -ne 0 ] && exit 1
  exit 0
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  init) cmd_init "$@" ;;
  add) cmd_add "$@" ;;
  audit) cmd_audit "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
