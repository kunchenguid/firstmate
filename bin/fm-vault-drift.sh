#!/usr/bin/env bash
# fm-vault-drift.sh - read-only documentation-vault drift detector.
#
# Prints one "VAULT_DRIFT: <project>: <problem>" line per vault problem found in
# this home's project clones, then exits 0. Silent = every vault is either
# current or absent by design. Detection only: it never writes a vault, never
# writes anything under projects/, and never touches the captain's live Obsidian
# copy - a vault is curated knowledge, so every remedy is a human or crewmate
# decision, not an automatic sync.
#
# Usage: fm-vault-drift.sh [--help]
#
# Projects come from data/projects.md when that registry exists (falling back to
# the clone directories under projects/), and every vault shape is established by
# INSPECTING the clone rather than by trusting the registry prose.
#
# Vault locations per project, deduplicated:
#   - an anchored data-vault path declared in the clone's root .gitignore
#     (a "/vault" or "/<dir>/vault" line), which declares an EXTERNAL vault;
#   - a tracked directory named vault/ that carries the OKF bundle marker
#     00-Home.md, which is an IN-REPO vault (a tracked directory named vault
#     WITHOUT that marker is some other directory - e.g. a test fixture - and is
#     deliberately ignored, so it can never raise a false alarm);
#   - a root-level "vault" symlink whose resolved target carries the OKF marker,
#     however it got there.
#
# Each location is classified and reported as one of:
#   link absent    - an external vault is declared but nothing is linked here, so
#                    drift cannot be measured at all. This is the failure that
#                    hides staleness, and it is reported separately from staleness
#                    because the remedy is different.
#   link broken    - the symlink exists but its target does not.
#   target invalid - a declared location resolves without the OKF marker, or a
#                    recognized bundle is not in a separate Git repository.
#   in-repo vault stale   - fixable inside an ordinary project worktree.
#   external vault stale  - NOT fixable from a project worktree: the vault is a
#                    separate repo, so the work belongs to that repo's own clone.
#
# Staleness is measured as project commits landed since the vault's own last
# commit, plus the window between those two commits. Both endpoints are commit
# timestamps, never the wall clock, so a run is deterministic and repeatable.
# A location is reported stale only when at least one project commit landed since
# the vault's last commit AND either threshold is crossed:
#   FM_VAULT_DRIFT_COMMITS  commits behind (default 20)
#   FM_VAULT_DRIFT_DAYS     days in the drift window (default 7)
# A non-numeric override warns on stderr and falls back to its default rather
# than silently disabling the check.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REGISTRY="$DATA/projects.md"

# The OKF vault bundle marker. Every vault in the fleet carries it at its root,
# and nothing else named vault/ does, so it is what separates a knowledge vault
# from a directory that merely shares the name.
VAULT_MARKER=00-Home.md

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  echo "usage: fm-vault-drift.sh [--help]" >&2
  exit 0
fi
[ $# -eq 0 ] || { echo "usage: fm-vault-drift.sh [--help]" >&2; exit 1; }

threshold() {
  local name=$1 value=$2 fallback=$3
  case "$value" in
    ''|*[!0-9]*)
      echo "vault-drift: invalid $name '$value'; using $fallback" >&2
      printf '%s\n' "$fallback"
      ;;
    *) printf '%s\n' "$value" ;;
  esac
}

COMMITS_THRESHOLD=$(threshold FM_VAULT_DRIFT_COMMITS "${FM_VAULT_DRIFT_COMMITS:-20}" 20)
DAYS_THRESHOLD=$(threshold FM_VAULT_DRIFT_DAYS "${FM_VAULT_DRIFT_DAYS:-7}" 7)

report() {
  printf 'VAULT_DRIFT: %s: %s\n' "$1" "$2"
}

# project_names: registered project names, one per line, in registry order.
# Falls back to the clone directory names so a home with no registry (or a clone
# that was never registered) is still inspected rather than silently skipped.
project_names() {
  local seen=" " name proj
  if [ -f "$REGISTRY" ]; then
    while read -r name; do
      [ -n "$name" ] || continue
      case "$seen" in *" $name "*) continue ;; esac
      seen="$seen$name "
      printf '%s\n' "$name"
    done < <(awk '$1=="-" && $2!="" { print $2 }' "$REGISTRY")
  fi
  [ -d "$PROJECTS" ] || return 0
  for proj in "$PROJECTS"/*; do
    [ -d "$proj" ] || continue
    name=$(basename "$proj")
    case "$seen" in *" $name "*) continue ;; esac
    seen="$seen$name "
    printf '%s\n' "$name"
  done
}

# declared_paths <proj>: anchored vault paths from the clone's root .gitignore.
# An anchored "/vault" or "/<dir>/vault" line is the project declaring that a
# vault belongs there but lives outside the repo.
declared_paths() {
  local proj=$1
  [ -f "$proj/.gitignore" ] || return 0
  awk '
    { sub(/\r$/, ""); sub(/[ \t]+$/, "") }
    /^\// {
      p = $0
      sub(/\/$/, "", p)
      if (p ~ /\/vault$/) print substr(p, 2)
    }
  ' "$proj/.gitignore"
}

# tracked_vault_paths <proj>: tracked directories named vault that carry the OKF
# bundle marker. The marker check is what keeps an unrelated tracked directory
# named vault (a test fixture, a sample tree) from ever being reported.
tracked_vault_paths() {
  local proj=$1 path
  git -C "$proj" rev-parse --verify --quiet HEAD >/dev/null 2>&1 || return 0
  while read -r path; do
    [ -n "$path" ] || continue
    git -C "$proj" cat-file -e "HEAD:$path/$VAULT_MARKER" 2>/dev/null || continue
    printf '%s\n' "$path"
  done < <(git -C "$proj" ls-tree -d -r --name-only HEAD 2>/dev/null | grep -E '(^|/)vault$' || true)
}

# vault_paths <proj>: every candidate location, deduplicated, deterministic order.
vault_paths() {
  local proj=$1 seen=" " path
  {
    declared_paths "$proj"
    tracked_vault_paths "$proj"
    [ -L "$proj/vault" ] && printf '%s\n' vault
  } | while read -r path; do
    [ -n "$path" ] || continue
    case "$seen" in *" $path "*) continue ;; esac
    seen="$seen$path "
    printf '%s\n' "$path"
  done
}

# drift_window_days <vault-epoch> <head-epoch>: whole days between the two
# commits, floored at 0 so a vault ahead of the project never reads as negative.
drift_window_days() {
  local days=$(((${2} - ${1}) / 86400))
  [ "$days" -ge 0 ] || days=0
  printf '%s\n' "$days"
}

is_stale() {
  local behind=$1 days=$2
  [ "$behind" -gt 0 ] || return 1
  [ "$behind" -ge "$COMMITS_THRESHOLD" ] || [ "$days" -ge "$DAYS_THRESHOLD" ]
}

# report_stale <name> <shape> <rel> <detail-suffix> <vault-epoch> <vault-date> <head-epoch> <behind>
report_stale() {
  local name=$1 shape=$2 rel=$3 suffix=$4 vault_ts=$5 vault_date=$6 head_ts=$7 behind=$8 days
  days=$(drift_window_days "$vault_ts" "$head_ts")
  is_stale "$behind" "$days" || return 0
  case "$shape" in
    in-repo)
      report "$name" "in-repo vault stale at $rel/ - vault last updated $vault_date, $behind project commits landed since, drift window ${days}d; a crewmate can refresh it in its own worktree"
      ;;
    external)
      report "$name" "external vault stale at $rel$suffix - vault last updated $vault_date, $behind project commits landed since, drift window ${days}d; the vault is a separate repo, which an isolated project worktree cannot write, so dispatch the update against that repo's own clone"
      ;;
  esac
}

# check_external <name> <proj> <rel> <vault-repo-dir> <detail-suffix> <declared>
check_external() {
  local name=$1 proj=$2 rel=$3 dir=$4 suffix=$5 declared=$6 top vault_repo project_repo vault_ts vault_date head_ts behind
  if [ ! -f "$dir/$VAULT_MARKER" ]; then
    if [ "$declared" -eq 1 ]; then
      report "$name" "external vault target invalid at $rel$suffix - $VAULT_MARKER marker missing, so this declared location is not a valid OKF bundle and vault drift cannot be measured"
    fi
    return 0
  fi
  if ! top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null); then
    report "$name" "external vault target invalid at $rel$suffix - the OKF bundle is not in a Git repository, so vault drift cannot be measured"
    return 0
  fi
  vault_repo=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  project_repo=$(git -C "$proj" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  if [ "$vault_repo" = "$project_repo" ]; then
    report "$name" "external vault target invalid at $rel$suffix - the resolved Git repository is the project repository, not a separate vault repository, so vault drift cannot be measured"
    return 0
  fi
  vault_ts=$(git -C "$top" log -1 --format=%ct 2>/dev/null) || return 0
  [ -n "$vault_ts" ] || return 0
  vault_date=$(git -C "$top" log -1 --format=%cd --date=short 2>/dev/null) || return 0
  head_ts=$(git -C "$proj" log -1 --format=%ct 2>/dev/null) || return 0
  [ -n "$head_ts" ] || return 0
  # An external vault has no shared history with the project, so "landed since"
  # is a timestamp comparison. --since is inclusive of its own second, so start
  # one second after the vault commit to count only what landed after it.
  behind=$(git -C "$proj" rev-list --count "--since=@$((vault_ts + 1))" HEAD 2>/dev/null) || return 0
  report_stale "$name" external "$rel" "$suffix" "$vault_ts" "$vault_date" "$head_ts" "$behind"
}

# check_in_repo <name> <proj> <rel>
check_in_repo() {
  local name=$1 proj=$2 rel=$3 vault_commit vault_ts vault_date head_ts behind
  vault_commit=$(git -C "$proj" log -1 --format=%H -- "$rel" 2>/dev/null) || return 0
  [ -n "$vault_commit" ] || return 0
  vault_ts=$(git -C "$proj" log -1 --format=%ct "$vault_commit" 2>/dev/null) || return 0
  vault_date=$(git -C "$proj" log -1 --format=%cd --date=short "$vault_commit" 2>/dev/null) || return 0
  head_ts=$(git -C "$proj" log -1 --format=%ct HEAD 2>/dev/null) || return 0
  behind=$(git -C "$proj" rev-list --count "$vault_commit..HEAD" 2>/dev/null) || return 0
  report_stale "$name" in-repo "$rel" "" "$vault_ts" "$vault_date" "$head_ts" "$behind"
}

# check_location <name> <proj> <rel>: classify one candidate location by what is
# actually on disk and in the index, and report only a real problem.
check_location() {
  local name=$1 proj=$2 rel=$3 full="$2/$3" target declared=0
  if declared_paths "$proj" | grep -Fxq "$rel"; then
    declared=1
  fi
  if [ -L "$full" ]; then
    target=$(readlink "$full")
    if [ ! -e "$full" ]; then
      if [ "$declared" -eq 1 ]; then
        report "$name" "external vault link broken at $rel -> $target (target missing); the vault content is not reachable from this clone, so its drift cannot be measured"
      fi
      return 0
    fi
    check_external "$name" "$proj" "$rel" "$full" " -> $target" "$declared"
    return 0
  fi
  if [ -d "$full" ]; then
    if git -C "$proj" cat-file -e "HEAD:$rel/$VAULT_MARKER" 2>/dev/null; then
      check_in_repo "$name" "$proj" "$rel"
    elif [ "$declared" -eq 1 ] || [ -e "$full/.git" ]; then
      # An untracked, ignored clone of the vault repo sitting in place of a
      # symlink: same external shape, same remedy.
      check_external "$name" "$proj" "$rel" "$full" "" "$declared"
    fi
    return 0
  fi
  # Nothing there. Only a declared external vault is a problem: a tracked vault
  # path that is merely missing from a dirty checkout is not this check's business.
  if [ "$declared" -eq 1 ]; then
    report "$name" "external vault link absent at $rel - the project declares an external vault there but this clone has none, so vault drift cannot be measured here at all; restore the link in the clone, or track the vault through its own registered repo"
  fi
}

command -v git >/dev/null 2>&1 || exit 0

while read -r name; do
  [ -n "$name" ] || continue
  proj="$PROJECTS/$name"
  [ -d "$proj" ] || continue
  git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || continue
  while read -r rel; do
    [ -n "$rel" ] || continue
    check_location "$name" "$proj" "$rel"
  done < <(vault_paths "$proj")
done < <(project_names)

exit 0
