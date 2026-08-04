#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints four words to stdout: "<mode> <yolo> <tiered> <ci-tests>" where mode is
# one of no-mistakes|direct-PR|local-only and the other three are on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode,
# yolo, tiered, and ci-tests are resolved by firstmate at intake and passed
# explicitly to bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh
# (AGENTS.md section 7). The consumers are bin/fm-fleet-sync.sh (skip
# local-only clones), bin/fm-home-seed.sh (refuse local-only seeding, run
# no-mistakes init), and bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                             -> no-mistakes off off off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)                     -> <mode> off off off
#   - <name> [<mode> +yolo] - <desc> (added <date>)               -> <mode> on off off
#   - <name> [<mode> +tiered] - <desc> (added <date>)             -> <mode> off on off
#   - <name> [<mode> +tiered +ci-tests] - <desc> (added <date>)   -> <mode> off on on
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
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#   AGENTS.md section 7 is the single owner of authority exceptions, including
#   ask-user contract expansion and stronger captain boundaries.
# tiered (orthogonal, no-mistakes only) = when on, a small/low-risk diff (per
#   bin/fm-tier.sh) runs a trimmed gate instead of the full pipeline; review and
#   CI are never skipped, and any doubt escalates to the full gate. See AGENTS.md
#   project management for the tier definitions.
# ci-tests (orthogonal, meaningful only when tiered is on) = when on, this
#   project's CI already runs the same test suite the local `test` gate step
#   would run, so a tier=1 run also skips local `test` (no point duplicating
#   CI). Default off keeps local `test` in every tier.
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off off off"
# and warns to stderr, so a typo never silently drops the gate.
# Usage: fm-project-mode.sh [--raw] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
if [ "${1:-}" = "--raw" ]; then
  RAW=1
  shift
fi
NAME=${1:?usage: fm-project-mode.sh [--raw] <project-name>}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off off off" >&2
  echo "no-mistakes off off off"
  exit 0
fi

# awk emits "<mode> <yolo> <tiered> <ci-tests>" (one line) or nothing if the
# project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; tiered="off"; citests="off";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo" && a[1] != "+tiered" && a[1] != "+ci-tests") mode = a[1];
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") yolo="on";
        if (a[j]=="+tiered") tiered="on";
        if (a[j]=="+ci-tests") citests="on";
      }
    }
    print mode, yolo, tiered, citests; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off off off" >&2
  echo "no-mistakes off off off"
  exit 0
fi

read -r mode yolo tiered citests <<EOF
$parsed
EOF
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off off off" >&2; mode=no-mistakes; yolo=off; tiered=off; citests=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
case "$tiered" in on|off) ;; *) tiered=off ;; esac
case "$citests" in on|off) ;; *) citests=off ;; esac
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo $tiered $citests"
