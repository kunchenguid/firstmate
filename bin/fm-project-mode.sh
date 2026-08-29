#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Default usage prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
# --branch-prefix instead prints one value: the project's registered ship-branch
# prefix, "fm/" when the project registers none, is unregistered, or the registry
# is absent, so every existing installation keeps its current "fm/<task-id>"
# branch names unchanged.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode,
# yolo, and ship-branch prefix are resolved by firstmate at intake and passed
# explicitly to bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md
# section 7; bin/fm-brief.sh's own header owns the --branch-prefix flag it accepts).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                                 -> no-mistakes off fm/  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)                        -> <mode> off fm/
#   - <name> [<mode> +yolo] - <desc> (added <date>)                  -> <mode> on fm/
#   - <name> [<mode> +yolo branch=<prefix>] - <desc> (added <date>)  -> <mode> <yolo> <prefix>
#   Bracket tokens are order-independent: +yolo and branch=<prefix> are recognized
#   by their own shape wherever they appear, and whichever token is left over is
#   the mode. <prefix> must not contain a space; an empty override ("branch=")
#   resolves to "" for a bare "<task-id>" ship branch instead of the legacy
#   "fm/<task-id>".
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
# branch=<prefix> (orthogonal) = overrides the "fm/" ship-branch prefix so a
#   project's branch and PR do not read as firstmate-authored, e.g. for a
#   third-party repo that does not use this tooling. Query it with
#   --branch-prefix; it never appears in the default "<mode> <yolo>" output, so
#   existing mechanical callers are unaffected by its presence.
#
# --raw prints the registered mode annotation unmapped, so a caller that must
# tell a conditional policy apart from a flat mode sees "no-mistakes-prod-only"
# itself. Not combined with --branch-prefix, which has no conditional-policy leg.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" (or
# "fm/" under --branch-prefix) and warns to stderr, so a typo never silently
# drops the gate.
# Usage: fm-project-mode.sh [--raw] <project-name>
#        fm-project-mode.sh --branch-prefix <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
BRANCH_PREFIX_QUERY=0
case "${1:-}" in
  --raw) RAW=1; shift ;;
  --branch-prefix) BRANCH_PREFIX_QUERY=1; shift ;;
esac
NAME=${1:?usage: fm-project-mode.sh [--raw|--branch-prefix] <project-name>}

if [ ! -f "$REG" ]; then
  if [ "$BRANCH_PREFIX_QUERY" -eq 1 ]; then
    echo "warn: no registry at $REG; defaulting $NAME to branch prefix fm/" >&2
    echo "fm/"
  else
    echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
    echo "no-mistakes off"
  fi
  exit 0
fi

# awk emits "<mode> <yolo> <branch-prefix>" (one line) or nothing if the project
# is absent. None of the three fields can contain a space (the bracket content is
# itself whitespace-tokenized), so plain space-separated output round-trips safely.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; branch="fm/";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      # Tokens are order-independent: +yolo and branch=<prefix> are recognized by
      # their own shape wherever they appear, and whatever token is left over is
      # the mode.
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") { yolo="on"; continue }
        if (a[j] ~ /^branch=/) { branch = substr(a[j], 8); continue }
        if (a[j] != "") mode = a[j];
      }
    }
    print mode, yolo, branch; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  if [ "$BRANCH_PREFIX_QUERY" -eq 1 ]; then
    echo "warn: project \"$NAME\" not in registry; defaulting to branch prefix fm/" >&2
    echo "fm/"
  else
    echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
    echo "no-mistakes off"
  fi
  exit 0
fi

read -r mode yolo branch <<<"$parsed"
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac

if [ "$BRANCH_PREFIX_QUERY" -eq 1 ]; then
  echo "$branch"
  exit 0
fi

# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
