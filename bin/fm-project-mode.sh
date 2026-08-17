#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture and gitflow branches from the
# data/projects.md registry.
#
# Default: prints two words "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
# --branches: prints two words "<production> <staging>" - the gitflow branches
# declared for this (home, repo). Either may be empty; a branch-less entry
# prints empty production (gflow-02 enforces the add-time requirement).
#
# MECHANICAL CONSUMERS ONLY. This answers "what did the captain register for this
# project in THIS home", never "how does this task ship". A task's delivery mode
# and yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The mode/yolo consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice. The --branches accessor
# is read by the gflow epic gates (gflow-02/03/04/06).
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# Gitflow branches are (home, repo)-scoped: the SAME repo can carry different
# branches in different homes (e.g. cashio = production=master in infina but
# production=master-insurtech in aimica), so they live per-entry in each home's
# registry, declared as key=value tokens INSIDE the annotation brackets:
#   - <name> [<mode> production=main] - <desc> (added <date>)
#   - <name> [<mode> production=master staging=release] - ...
#   - <name> [<mode> +yolo production=main] - ...
# Order inside the brackets is free; mode (if present) stays first. production is
# required going forward but backward compatible: an entry without it still
# parses and --branches reports empty production, so nothing breaks mid-migration.
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = merge authority only: when on, firstmate merges green,
#   in-scope work itself (AGENTS.md section 7).
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
# --raw and --branches are mutually exclusive.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate. --branches on an
# unknown/missing project prints empty branches and warns.
# Usage: fm-project-mode.sh [--raw|--branches] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
BRANCHES=0
case "${1:-}" in
  --raw) RAW=1; shift ;;
  --branches) BRANCHES=1; shift ;;
esac
NAME=${1:?usage: fm-project-mode.sh [--raw|--branches] <project-name>}

if [ ! -f "$REG" ]; then
  if [ "$BRANCHES" -eq 1 ]; then
    echo "warn: no registry at $REG; no branches for $NAME" >&2
    echo " "
  else
    echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
    echo "no-mistakes off"
  fi
  exit 0
fi

# awk emits "<mode>\t<yolo>\t<production>\t<staging>" (one line) or nothing if
# the project is absent. Branch fields are key=value tokens inside the brackets.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; prod=""; stg="";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      # A bare first token that is not a flag or key=value is the mode.
      if (a[1] != "" && a[1] != "+yolo" && a[1] !~ /=/) mode = a[1];
      for (j=1; j<=k; j++) {
        if (a[j] == "+yolo") yolo = "on";
        else if (a[j] ~ /^production=/) { prod = a[j]; sub(/^production=/, "", prod) }
        else if (a[j] ~ /^staging=/)    { stg  = a[j]; sub(/^staging=/, "", stg) }
      }
    }
    print mode "\t" yolo "\t" prod "\t" stg; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  if [ "$BRANCHES" -eq 1 ]; then
    echo "warn: project \"$NAME\" not in registry; no branches" >&2
    echo " "
  else
    echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
    echo "no-mistakes off"
  fi
  exit 0
fi

IFS=$'\t' read -r mode yolo production staging <<EOF
$parsed
EOF

if [ "$BRANCHES" -eq 1 ]; then
  echo "$production $staging"
  exit 0
fi

case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
