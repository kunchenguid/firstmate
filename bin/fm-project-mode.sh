#!/usr/bin/env bash
# Parse a project's REGISTERED annotation from the data/projects.md registry.
# This script is the one owner of that line's format.
# Default read: the delivery posture, printed as two words "<mode> <yolo>" where
# mode is one of no-mistakes|direct-PR|local-only and yolo is on|off.
# --branch read: the project's registered WORKING BRANCH, printed alone.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init),
# bin/fm-spawn.sh's advisory registry-deviation notice, and bin/fm-spawn.sh's
# --branch read, which decides the branch a fresh pooled slot is reset to and is
# a placement decision rather than an advisory one.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# The bracket annotation also carries an optional working-branch token:
#   - <name> [<mode> branch=<branch>] - <desc> (added <date>)
# It records which branch the captain actually works this project on, for the
# projects whose working branch is not the remote's own default branch. The
# tokens are order-independent, so [no-mistakes branch=develop +yolo] is the same
# annotation as [no-mistakes +yolo branch=develop] and as
# [branch=develop no-mistakes +yolo]: the mode is whichever token is neither
# `+yolo` nor `branch=`, wherever it sits.
# A `branch=` left with no value is a half-written registration rather than an
# absent token, so it is refused exactly as `branch=-` is: reading it as absent
# would send a pooled slot silently onto the remote default, the failure this
# token exists to remove.
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
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
#
# --branch has no such fallback, deliberately, and it never folds "no branch is
# registered" together with "the registered branch is one git rejects", because
# a caller must be free to fall back on the first and refuse on the second:
#   exit 0  prints the registered working branch to stdout
#   exit 1  prints nothing; the registry records no working branch here
#   exit 3  prints nothing to stdout and names the offending token on stderr;
#           the project registers a branch= token that git's own syntax check
#           rejects, which is a registry error rather than an absent branch
# A guessed branch is exactly the failure this token exists to remove, so the
# caller receives one of those three answers rather than an invented one.
# Usage: fm-project-mode.sh [--raw | --branch] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
BRANCH_ONLY=0
case "${1:-}" in
  --raw) RAW=1; shift ;;
  --branch) BRANCH_ONLY=1; shift ;;
esac
NAME=${1:?usage: fm-project-mode.sh [--raw | --branch] <project-name>}

if [ ! -f "$REG" ]; then
  if [ "$BRANCH_ONLY" -eq 1 ]; then
    exit 1
  fi
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

# awk emits "<mode> <yolo> <branch-present> <branch>" (one line) or nothing if
# the project is absent. Whether a branch was registered is carried by its own
# 0/1 field rather than by a reserved branch name: git's syntax check accepts
# every placeholder that could be spelled here, "-" included, so no value of the
# branch field can stand for its own absence. A `branch=` written with no value
# is present and malformed for the same reason, never absent.
# The mode is the first token that is neither `+yolo` nor `branch=`, so every
# token spelling of one annotation resolves to the same posture.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; present=0; branch="-"; mode_set=0;
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") yolo="on";
        else if (a[j] ~ /^branch=/) { present=1; branch=substr(a[j], 8) }
        else if (a[j] != "" && mode_set==0) { mode=a[j]; mode_set=1 }
      }
    }
    print mode, yolo, present, branch; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  if [ "$BRANCH_ONLY" -eq 1 ]; then
    exit 1
  fi
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

read -r mode yolo branch_present branch <<EOF
$parsed
EOF

if [ "$BRANCH_ONLY" -eq 1 ]; then
  # A registered branch is reported only when git's own syntax check accepts it,
  # so a typo is reported as a registry error rather than passed on as a ref
  # expression that could resolve somewhere unintended. The full refs/heads/ form
  # keeps the check purely syntactic and usable outside any repository, unlike
  # --branch, which also expands shorthand such as @{-1}. A leading dash passes
  # that check but is refused too: every caller hands this answer to git as an
  # operand, where such a name is read as an option instead.
  if [ "$branch_present" -eq 0 ]; then
    exit 1
  fi
  case "$branch" in -*) branch_bad=1 ;; *) branch_bad=0 ;; esac
  if [ "$branch_bad" -eq 1 ] || ! git check-ref-format "refs/heads/$branch" >/dev/null 2>&1; then
    echo "error: project \"$NAME\" registers branch=\"$branch\", which is not a valid branch name" >&2
    exit 3
  fi
  echo "$branch"
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
