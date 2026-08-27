#!/usr/bin/env bash
# fm-herdr-workspaces.sh — one herdr workspace per fleet project, and a naming
# rule for agent panes.
#
# THE ORGANISING RULE (captain's standing order, 2026-08-27):
#   * every project gets its OWN workspace, labelled with the project name
#   * every agent pane is NAMED FOR THE WORK IT IS DOING, not for a task id
#
# A task id like `afs-resources-r7` tells you nothing at a glance. `afs/resource
# -registry` tells you what that pane is for without attaching to it. herdr
# addresses agents by unique name (`herdr agent prompt <name> ...`), so the name
# is not decoration - it is the address, and a good one makes the fleet legible
# from the workspace list alone.
#
# Naming convention:  <project-short>/<what-the-work-is>
#   afs/resource-registry      afs/doc-index         cellarsky/booking-fix
#   mac-config/cutover-guard   stone-skills/lint-edges
# Keep it under 28 chars so it fits the sidebar (herdr's sidebar_width is 30). Kebab-case, no task suffix -
# the id lives in state/<id>.meta, which is where an id belongs.
#
# Usage:
#   fm-herdr-workspaces.sh              show the plan, change nothing
#   fm-herdr-workspaces.sh --apply      create the missing workspaces
#   fm-herdr-workspaces.sh --name <target> <project> <work>   name an agent pane
set -euo pipefail

FM_HOME="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REGISTRY="$FM_HOME/data/projects.md"
PROJECTS_DIR="$FM_HOME/projects"

die() { printf 'fm-herdr-workspaces: %s\n' "$1" >&2; exit 1; }

herdr_up() { herdr session list 2>/dev/null | awk '$1=="default"{print $2}' | grep -q running; }

require_herdr() {
  command -v herdr >/dev/null 2>&1 || die "herdr is not on PATH"
  herdr_up || die "no herdr server is running — run \`herdr\` to start or attach it, then retry"
}

# --name: apply the convention to a live agent pane.
if [ "${1:-}" = "--name" ]; then
  require_herdr
  [ $# -ge 4 ] || die "usage: --name <target> <project-short> <what-the-work-is>"
  target=$2; proj=$3; shift 3
  work=$(printf '%s' "$*" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9/-' | sed 's/--*/-/g; s/^-//; s/-$//')
  name="$proj/$work"
  [ "${#name}" -le 28 ] || die "name '$name' is ${#name} chars; keep it short enough to read in the tab bar"
  herdr agent rename "$target" "$name" >/dev/null || die "rename failed for $target"
  printf 'named %s -> %s\n' "$target" "$name"
  exit 0
fi

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

[ -f "$REGISTRY" ] || die "no project registry at $REGISTRY"
require_herdr

existing=$(herdr workspace list 2>/dev/null || true)

printf '%-26s %-9s %s\n' PROJECT STATUS CWD
printf '%-26s %-9s %s\n' "-------" "------" "---"
made=0; skipped=0; missing=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  cwd="$PROJECTS_DIR/$name"
  if [ ! -d "$cwd" ]; then
    printf '%-26s %-9s %s\n' "$name" "NO-DIR" "$cwd"; missing=$((missing+1)); continue
  fi
  if printf '%s' "$existing" | grep -qw -- "$name"; then
    printf '%-26s %-9s %s\n' "$name" "exists" "$cwd"; skipped=$((skipped+1)); continue
  fi
  if [ "$APPLY" = 1 ]; then
    herdr workspace create --cwd "$cwd" --label "$name" --no-focus >/dev/null \
      && { printf '%-26s %-9s %s\n' "$name" "CREATED" "$cwd"; made=$((made+1)); } \
      || printf '%-26s %-9s %s\n' "$name" "FAILED" "$cwd"
  else
    printf '%-26s %-9s %s\n' "$name" "would-add" "$cwd"; made=$((made+1))
  fi
done < <(sed -n 's/^- \([a-z0-9][a-z0-9._-]*\) .*/\1/p' "$REGISTRY")

printf '\n'
if [ "$APPLY" = 1 ]; then
  printf 'created %s, already present %s, no directory %s\n' "$made" "$skipped" "$missing"
else
  printf 'plan only: %s to create, %s present, %s missing a directory\n' "$made" "$skipped" "$missing"
  printf 'run with --apply to create them.\n'
fi
