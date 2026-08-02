#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture - mode, yolo flag, and declared
# base-branch override - from the data/projects.md registry.
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
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#   - <name> [<mode> base=<branch>] - <desc> (added <date>)  -> development base branch override
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
# base=<branch> (orthogonal, optional) = the branch workers develop on, for the rare
#   project whose development branch is NOT its remote's default branch. It is an
#   escape hatch, not the normal mechanism: bin/fm-base-branch.sh resolves the base
#   from the remote's own current default whenever no override is declared, so a
#   project that develops on its remote default needs no entry at all.
#   The bracket tokens are order-independent, so `[direct-PR +yolo base=develop]`
#   and `[direct-PR base=develop +yolo]` mean the same thing.
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate. A malformed base= declaration is
# a hard error instead: silently ignoring it would put workers back on the wrong branch,
# which is the exact failure this override exists to prevent.
# Usage: fm-project-mode.sh [--raw] <project-name>
#        fm-project-mode.sh --base <project-name>   print the declared base branch,
#                                                   or nothing when none is declared
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
QUERY=mode
if [ "${1:-}" = "--raw" ]; then
  RAW=1
  shift
elif [ "${1:-}" = "--base" ]; then
  QUERY=base
  shift
fi
NAME=${1:?usage: fm-project-mode.sh [--raw|--base] <project-name>}

if [ ! -f "$REG" ]; then
  if [ "$QUERY" = base ]; then
    exit 0
  fi
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

# awk emits "<mode>\t<yolo>\t<declared>\t<base>" (one line) or nothing if the
# project is absent. <declared> distinguishes "no base= token at all" from a
# base= token with nothing usable after it, which must be a hard error rather
# than a silent fall back to the remote default.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; base=""; declared=0;
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      # The mode still comes from the first bracket token only, exactly as before,
      # so every pre-existing entry parses to the same mode it always did.
      if (a[1] != "" && a[1] != "+yolo" && a[1] !~ /^base=/) mode = a[1];
      for (j=1; j<=k; j++) {
        if (a[j] == "+yolo") yolo="on";
        else if (a[j] ~ /^base=/) { declared=1; base = substr(a[j], 6) }
      }
    }
    printf "%s\t%s\t%s\t%s\n", mode, yolo, declared, base; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  if [ "$QUERY" = base ]; then
    exit 0
  fi
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

IFS=$'\t' read -r mode yolo declared base <<EOF
$parsed
EOF

if [ "$QUERY" = base ]; then
  [ "$declared" = 1 ] || exit 0
  # An entry that declares base= must name a usable branch. A `base=` with nothing
  # after it, or one carrying junk like a stray bracket, is a registry typo;
  # falling back to the remote default here would silently hand workers the wrong
  # branch, so refuse instead.
  case "$base" in
    ''|*[!A-Za-z0-9._/-]*|-*|*..*|*/|/*)
      echo "error: project \"$NAME\" declares an unusable base branch \"$base\" in $REG" >&2
      exit 1
      ;;
  esac
  printf '%s\n' "$base"
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
