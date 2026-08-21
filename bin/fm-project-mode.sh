#!/usr/bin/env bash
# Resolve a project's registered delivery posture and path from data/projects.md.
# The default output remains two words: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
# --path prints only the resolved project path for mechanical consumers.
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
#   - <name> - <desc> (added <date>)                              -> no-mistakes off (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)                      -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)                -> <mode> on
#   - <name> [<mode> +yolo] - <desc> (path: <path>; added <date>)  -> <mode> on
#
# The path field is optional for compatibility. Without it, --path resolves to
# "$FM_HOME/projects/<name>". A path beginning with "projects/" is relative to
# the firstmate home, an absolute path is used as written, "~/..." is relative
# to $HOME, and any other relative path is under "$HOME/dpe". Path values must
# be one whitespace-free path without registry delimiters or traversal components.
# The resolved path is exposed by --path so callers never need to reparse this file.
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
# to stderr, so a typo never silently drops the gate. A malformed declared path is
# an error, including for --path, and never silently falls back to projects/<name>.
# Usage: fm-project-mode.sh [--raw] [--path] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
PATH_REQUESTED=0
NAME=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --raw) RAW=1 ;;
    --path) PATH_REQUESTED=1 ;;
    --) shift; [ "$#" -eq 1 ] || { echo "usage: fm-project-mode.sh [--raw] [--path] <project-name>" >&2; exit 2; }; NAME=$1; break ;;
    -*) echo "usage: fm-project-mode.sh [--raw] [--path] <project-name>" >&2; exit 2 ;;
    *) [ -z "$NAME" ] || { echo "usage: fm-project-mode.sh [--raw] [--path] <project-name>" >&2; exit 2; }; NAME=$1 ;;
  esac
  shift
done
[ -n "$NAME" ] || { echo "usage: fm-project-mode.sh [--raw] [--path] <project-name>" >&2; exit 2; }

fallback_path() {
  printf '%s/%s\n' "${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}" "$NAME"
}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  if [ "$PATH_REQUESTED" -eq 1 ]; then
    fallback_path
  else
    echo "no-mistakes off"
  fi
  exit 0
fi

# awk emits mode, yolo, path-present, and the declared path as tab-separated
# fields. The shell validates and resolves the path because it owns HOME and
# FM_HOME, while callers never need to parse the registry line themselves.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; path_present=0; path="";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo") mode = a[1];
      for (j=1; j<=k; j++) if (a[j]=="+yolo") yolo="on";
    }
    if ($0 ~ /[[:space:]]\(path:/) {
      path_present=1;
      suffix=$0;
      sub(/^.*[[:space:]]\(path:[[:space:]]*/, "", suffix);
      if (suffix !~ /;[[:space:]]*added[[:space:]]+[^)]*\)[[:space:]]*$/) {
        print "ERROR\tpath annotation must end with ; added <date>)";
        exit
      }
      sub(/;[[:space:]]*added[[:space:]]+[^)]*\)[[:space:]]*$/, "", suffix);
      path=suffix;
    }
    print mode "\t" yolo "\t" path_present "\t" path; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  if [ "$PATH_REQUESTED" -eq 1 ]; then
    fallback_path
  else
    echo "no-mistakes off"
  fi
  exit 0
fi

case "$parsed" in
  ERROR$'\t'*)
    echo "error: project \"$NAME\" has ${parsed#*$'\t'}" >&2
    exit 1
    ;;
esac
IFS=$'\t' read -r mode yolo path_present declared_path <<EOF
$parsed
EOF

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

resolved_path=
if [ "$path_present" = 1 ]; then
  case "$declared_path" in
    ''|*[[:space:]]*|*';'*|*'('*|*')'*|*'|'*|*'='*|*'//'*)
      echo "error: project \"$NAME\" has invalid path \"$declared_path\"" >&2
      exit 1
      ;;
  esac
  case "/$declared_path/" in
    */../*|*/./*)
      echo "error: project \"$NAME\" has invalid path \"$declared_path\"" >&2
      exit 1
      ;;
  esac
  case "$declared_path" in
    projects/*)
      [ -n "${declared_path#projects/}" ] \
        || { echo "error: project \"$NAME\" has invalid path \"$declared_path\"" >&2; exit 1; }
      resolved_path="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}/${declared_path#projects/}"
      ;;
    /*) resolved_path=$declared_path ;;
    '~') resolved_path=${HOME:?HOME must be set to resolve project paths} ;;
    '~/'*) resolved_path="${HOME:?HOME must be set to resolve project paths}/${declared_path:2}" ;;
    *) resolved_path="${HOME:?HOME must be set to resolve project paths}/dpe/$declared_path" ;;
  esac
fi

if [ "$PATH_REQUESTED" -eq 1 ]; then
  if [ "$path_present" = 1 ]; then
    printf '%s\n' "$resolved_path"
  else
    fallback_path
  fi
  exit 0
fi

echo "$mode $yolo"
