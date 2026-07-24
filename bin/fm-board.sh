#!/usr/bin/env bash
# fm-board.sh - one-glance terminal board of all fleet work, grouped by project.
#
# Renders, per project from data/projects.md:
#   - in-flight / queued / done items from the tasks-axi backlog (id, kind, source)
#   - a "no live crew" flag on any in-flight item with no matching tmux window,
#     so backlog drift (a task left in_flight after its crew is gone) is visible
#   - live open PR / issue counts per project via gh-axi (skip with --no-gh)
#
# Deliberately low-cost: no daemon, one render per invocation. For a live view,
# wrap it: `watch -c -n 30 bin/fm-board.sh`. Read-only; respects FM_HOME so a
# secondmate home boards its own fleet.
#
# Usage: fm-board.sh [--no-gh]
#   --no-gh   skip the GitHub PR/issue counts (no network; instant)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

WITH_GH=1
[ "${1:-}" = "--no-gh" ] && WITH_GH=0

PROJECTS_MD="$FM_HOME/data/projects.md"

# Colors only on an interactive terminal and when NO_COLOR is unset.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RST=$'\e[0m'
  CYAN=$'\e[36m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'
else
  BOLD=; DIM=; RST=; CYAN=; GRN=; YEL=; BLU=
fi

command -v tasks-axi >/dev/null 2>&1 || { echo "fm-board: tasks-axi not on PATH" >&2; exit 1; }

# Normalize every backlog item (active + done) to a single tab-separated table:
#   id \t state \t kind \t repo \t title
# tasks-axi prints rows as:  <2 spaces>id,state,kind,repo,"title with, commas"
norm_tasks() {
  # `tasks-axi list` (no filter) already returns every state, done included.
  ( cd "$FM_HOME" && tasks-axi list 2>/dev/null ) \
    | grep -E '^  [A-Za-z0-9]' \
    | while IFS= read -r row; do
        row="${row#  }"
        IFS=, read -r id state kind repo rest <<<"$row"
        rest="${rest%\"}"; rest="${rest#\"}"
        printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$state" "$kind" "$repo" "$rest"
      done
}
NORM="$(norm_tasks)"

# Live crew windows across all sessions, used to flag stale in_flight entries.
LIVE_WINS="$(tmux list-windows -a 2>/dev/null | grep -oE 'fm-[A-Za-z0-9._-]+' || true)"

# owner/repo slug from a project's origin remote (git@ or https, .git stripped).
gh_slug() {
  local url
  url="$(git -C "$FM_HOME/projects/$1" remote get-url origin 2>/dev/null)" || return 1
  printf '%s\n' "$url" | sed -E 's#^git@github.com:##; s#^https?://github.com/##; s#\.git$##'
}

# "<open-PRs> <open-issues>" for a slug, "- -" if gh can't answer.
gh_counts() {
  local slug="$1" pr is
  pr="$(gh-axi pr list --repo "$slug" 2>/dev/null | sed -n 's/^count: //p' | head -1)"
  is="$(gh-axi issue list --repo "$slug" 2>/dev/null | sed -n 's/^count: //p' | head -1)"
  printf '%s %s\n' "${pr:--}" "${is:--}"
}

# source tag "src:X" for a task, read by id from its full backlog line
# (tasks-axi list truncates long titles before the tag), else "-".
src_tag() { # id
  local line s
  line="$(grep -m1 -E "^- \[[ x]\] $1 " "$FM_HOME/data/backlog.md" 2>/dev/null)"
  s="$(printf '%s\n' "$line" | grep -oE 'src:[A-Za-z0-9._-]+' | head -1)"
  [ -n "$s" ] && printf '%s\n' "${s#src:}" || printf -- '-\n'
}

# short landed-ref for a done item, read by id from the backlog Done line
# (tasks-axi list truncates titles before the URL): PR number, report, or local-main.
done_ref() {
  local line pr
  line="$(grep -m1 -E "^- \[x\] $1 " "$FM_HOME/data/backlog.md" 2>/dev/null)"
  pr="$(printf '%s\n' "$line" | grep -oE 'pull/[0-9]+' | head -1)"
  [ -n "$pr" ] && { printf 'PR%s\n' "${pr#pull/}"; return; }
  printf '%s\n' "$line" | grep -qE 'report\.md' && { echo report; return; }
  printf '%s\n' "$line" | grep -qi 'local main' && { echo local; return; }
  echo '-'
}

row_out() { # glyph color id col3 extra
  printf "  %s%s%s  %-26.26s %s%-7s%s %s%-11s%s %s\n" \
    "$2" "$1" "$RST" "$3" "$DIM" "$4" "$RST" "$DIM" "${5:--}" "$RST" "${6:-}"
}

printf "%sFIRSTMATE BOARD%s   %s%s%s\n" "$BOLD" "$RST" "$DIM" "$(date '+%Y-%m-%d %H:%M')" "$RST"
printf "%s* in flight   ~ queued   + done      ! = in-flight item with no live crew (backlog drift)%s\n\n" "$DIM" "$RST"

if [ ! -f "$PROJECTS_MD" ]; then
  echo "fm-board: no project registry at $PROJECTS_MD" >&2
  exit 1
fi

grep -E '^- ' "$PROJECTS_MD" | while IFS= read -r line; do
  name="$(printf '%s\n' "$line" | sed -E 's/^- +([^ ]+).*/\1/')"
  mode="$(printf '%s\n' "$line" | grep -oE '\[[^]]+\]' | head -1)"
  [ -n "$name" ] || continue

  gh_str=""
  if [ "$WITH_GH" = 1 ]; then
    slug="$(gh_slug "$name" 2>/dev/null || true)"
    if [ -n "$slug" ]; then
      read -r nprs nis <<<"$(gh_counts "$slug")"
      gh_str="   ${BLU}gh${RST} ${nprs} open PR · ${nis} open issue"
    fi
  fi
  printf "%s%s%s %s%s%s%s\n" "$BOLD$CYAN" "$name" "$RST" "$DIM" "$mode" "$RST" "$gh_str"

  found_any=0
  for st in in_flight queued "done"; do
    rows="$(printf '%s\n' "$NORM" | awk -F'\t' -v r="$name" -v s="$st" '$4==r && $2==s')"
    [ -n "$rows" ] || continue
    found_any=1
    n=$(printf '%s\n' "$rows" | grep -c .)
    # Keep done glanceable: newest few, note the rest.
    [ "$st" = "done" ] && [ "$n" -gt 6 ] && rows="$(printf '%s\n' "$rows" | head -6)"
    printf '%s\n' "$rows" | while IFS=$'\t' read -r id state kind repo _; do
      case "$st" in
        in_flight)
          extra=""
          printf '%s\n' "$LIVE_WINS" | grep -qx "fm-$id" || extra="${YEL}! no live crew${RST}"
          row_out "*" "$GRN" "$id" "$kind" "$(src_tag "$id")" "$extra" ;;
        queued)
          row_out "~" "$YEL" "$id" "$kind" "$(src_tag "$id")" "" ;;
        done)
          row_out "+" "$DIM" "$id" "$kind" "$(done_ref "$id")" "" ;;
      esac
    done
    [ "$st" = "done" ] && [ "$n" -gt 6 ] && printf "  %s+ %d older done%s\n" "$DIM" "$((n - 6))" "$RST"
  done
  [ "$found_any" = 1 ] || printf "  %s(no tracked items)%s\n" "$DIM" "$RST"
  echo
done
