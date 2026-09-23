#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                       -> no-mistakes off github  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)               -> <mode> off github
#   - <name> [<mode> +yolo] - <desc> (added <date>)         -> <mode> on github
#   - <name> [<mode> forge:<forge>] - <desc> (added <date>) -> <mode> off <forge>
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi (or the project's registered forge
#                          CLI), no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = merge authority only: when on, firstmate merges green,
#   in-scope work itself (AGENTS.md section 7).
# forge (orthogonal) = which forge CLI a worker uses for this project's PR
#   operations: github (default, gh-axi), gitlab (glab), or forgejo (tea).
#   bin/fm-pr-lib.sh's URL-driven provider dispatch already handles a GitLab
#   or Forgejo PR/MR once it exists; this token is what a generated brief and
#   Definition of done read before any PR exists, to name the right CLI.
#
# Both bracket tokens are order-independent and optional; either, both, or
# neither may be present. --raw prints the registered annotation unmapped, so
# a caller that must tell a conditional policy apart from a flat mode sees
# "no-mistakes-prod-only" itself. --forge prints only the resolved forge.
#
# An unknown/missing project, unknown mode, or unknown forge falls back to its
# documented default and warns to stderr, so a typo never silently drops the
# gate or points a worker at the wrong CLI.
# Usage: fm-project-mode.sh [--raw|--forge] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
FORGE_ONLY=0
case "${1:-}" in
  --raw) RAW=1; shift ;;
  --forge) FORGE_ONLY=1; shift ;;
esac
NAME=${1:?usage: fm-project-mode.sh [--raw|--forge] <project-name>}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off github" >&2
  if [ "$FORGE_ONLY" -eq 1 ]; then
    echo github
  else
    echo "no-mistakes off"
  fi
  exit 0
fi

# awk emits "<mode> <yolo> <forge>" (one line) or nothing if the project is
# absent. Both bracket tokens are found by scanning every token rather than by
# position, so "[forge:forgejo no-mistakes +yolo]" and "[no-mistakes +yolo
# forge:forgejo]" resolve identically; the mode is whichever token is neither
# "+yolo" nor "forge:*".
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; forge="github"; mode_set=0;
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      for (j=1; j<=k; j++) {
        if (a[j] == "+yolo") { yolo="on" }
        else if (a[j] ~ /^forge:/) { forge=substr(a[j], 7) }
        else if (a[j] != "" && !mode_set) { mode=a[j]; mode_set=1 }
      }
    }
    print mode, yolo, forge; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off github" >&2
  if [ "$FORGE_ONLY" -eq 1 ]; then
    echo github
  else
    echo "no-mistakes off"
  fi
  exit 0
fi

mode=$(printf '%s' "$parsed" | cut -d' ' -f1)
yolo=$(printf '%s' "$parsed" | cut -d' ' -f2)
forge=$(printf '%s' "$parsed" | cut -d' ' -f3)
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
case "$forge" in
  github|gitlab|forgejo) ;;
  *) echo "warn: unknown forge \"$forge\" for $NAME; defaulting to github" >&2; forge=github ;;
esac
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
if [ "$FORGE_ONLY" -eq 1 ]; then
  echo "$forge"
else
  # Exactly two words, unchanged from before the forge token existed: every
  # existing caller and test asserts this shape, some with a strict equality
  # check, so forge is never appended here even though it was already parsed
  # above. Query it separately with --forge.
  echo "$mode $yolo"
fi
