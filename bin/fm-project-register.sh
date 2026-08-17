#!/usr/bin/env bash
# Append a project registry entry to data/projects.md, FAIL-CLOSED on a missing
# production branch (gflow-02, epic gflow "Cong #1").
#
# Registration is the point where a repo enters a home. The epic's captain
# decision Q2 ("branch AND epic mandatory, no exceptions") makes declaring the
# repo's production branch a precondition of registering it: no --production ->
# refuse, write nothing. This is the deterministic gate the project-management
# skill's add/clone/create procedure routes registration through, so the rule is
# runtime-enforced rather than left to agent memory.
#
# Usage:
#   fm-project-register.sh --production <branch> [--staging <branch>] \
#       [--mode <mode>] [--yolo] <name> <description...>
#
# --production <branch>  REQUIRED. The repo's production/default branch in THIS
#                        home. Missing or empty -> refuse (exit 2), no write.
# --staging <branch>     Optional gitflow staging/release branch.
# --mode <mode>          Registered delivery posture (no-mistakes|direct-PR|
#                        local-only|no-mistakes-prod-only). Default no-mistakes,
#                        matching the registry's legacy default.
# --yolo                 Register the +yolo posture (routine approval authority).
# <name>                 Project name (the projects/<name> clone dir). No spaces.
# <description...>       Free-form description; the remaining args, joined.
#
# The (home, repo)-scoped branches are written as key=value tokens inside the
# annotation brackets, in the format owned by bin/fm-project-mode.sh:
#   - <name> [<mode> [+yolo] production=<p> [staging=<s>]] - <desc> (added <YYMMDD>)
# fm-project-mode.sh --branches reads them back.
#
# Fail-closed and atomic: every input is validated BEFORE any write, a duplicate
# name is refused, and the entry is appended in one operation, so a refusal never
# leaves a partial registration. Rolling back a clone created earlier in the
# add/clone/create procedure is that procedure's responsibility (it resolves the
# production branch up front, before cloning, so a refusal costs no state).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"

usage() {
  echo "usage: fm-project-register.sh --production <branch> [--staging <branch>] [--mode <mode>] [--yolo] <name> <description...>" >&2
}

PRODUCTION=""
STAGING=""
MODE="no-mistakes"
YOLO=0
PRODUCTION_SET=0
POSITIONAL=()

while [ $# -gt 0 ]; do
  case "$1" in
    --production) PRODUCTION_SET=1; PRODUCTION="${2:-}"; shift 2 ;;
    --staging)    STAGING="${2:-}"; shift 2 ;;
    --mode)       MODE="${2:-}"; shift 2 ;;
    --yolo)       YOLO=1; shift ;;
    --)           shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done ;;
    -*)           usage; echo "error: unknown flag \"$1\"" >&2; exit 2 ;;
    *)            POSITIONAL+=("$1"); shift ;;
  esac
done

# --- Fail-closed gate: production branch is mandatory. ---
if [ "$PRODUCTION_SET" -eq 0 ] || [ -z "$PRODUCTION" ]; then
  usage
  echo "error: --production <branch> is required to register a project; every repo must declare its production branch (epic gflow, no exceptions). Refusing to register without one." >&2
  exit 2
fi

if [ "${#POSITIONAL[@]}" -lt 1 ]; then
  usage
  echo "error: project name is required" >&2
  exit 2
fi
NAME="${POSITIONAL[0]}"
DESC=""
if [ "${#POSITIONAL[@]}" -ge 2 ]; then
  DESC="${POSITIONAL[*]:1}"
fi

# --- Validate every field before touching the registry. ---
# A registry entry is line-based and its annotation is space- and bracket-
# delimited, so names and branches must not contain whitespace or brackets that
# would corrupt the parser (bin/fm-project-mode.sh).
valid_token() { case "$1" in *[[:space:]]*|*'['*|*']'*) return 1 ;; *) return 0 ;; esac; }

valid_token "$NAME" || { echo "error: project name \"$NAME\" must not contain whitespace or brackets" >&2; exit 2; }
valid_token "$PRODUCTION" || { echo "error: production branch \"$PRODUCTION\" must not contain whitespace or brackets" >&2; exit 2; }
if [ -n "$STAGING" ]; then
  valid_token "$STAGING" || { echo "error: staging branch \"$STAGING\" must not contain whitespace or brackets" >&2; exit 2; }
fi
case "$MODE" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "error: unknown mode \"$MODE\" (expected no-mistakes|direct-PR|local-only|no-mistakes-prod-only)" >&2; exit 2 ;;
esac
if [ -z "$DESC" ]; then
  echo "error: a project description is required" >&2
  exit 2
fi

# --- Refuse a duplicate rather than writing a second, conflicting entry. ---
if [ -f "$REG" ] && awk -v n="$NAME" '$1=="-" && $2==n { found=1 } END { exit !found }' "$REG"; then
  echo "error: project \"$NAME\" is already registered in $REG; refusing to add a duplicate entry" >&2
  exit 2
fi

# --- Build the annotation: mode first, then +yolo, then branch key=values. ---
annotation="$MODE"
[ "$YOLO" -eq 1 ] && annotation="$annotation +yolo"
annotation="$annotation production=$PRODUCTION"
[ -n "$STAGING" ] && annotation="$annotation staging=$STAGING"

line="- $NAME [$annotation] - $DESC (added $(date +%y%m%d))"

mkdir -p "$DATA"
if [ ! -f "$REG" ]; then
  printf '# Projects\n\n' > "$REG"
fi
printf '%s\n' "$line" >> "$REG"
echo "registered: $line"
