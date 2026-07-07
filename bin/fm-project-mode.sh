#!/usr/bin/env bash
# Resolve a project's delivery mode and yolo flag from the project registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# data/projects.json is the machine registry when present.
# data/projects.md remains the legacy human registry fallback.
# Usage: fm-project-mode.sh <project-name-or-path>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME=${1:?usage: fm-project-mode.sh <project-name-or-path>}

mode=$("$SCRIPT_DIR/fm-project-resolve.sh" --field mode "$NAME")
yolo=$("$SCRIPT_DIR/fm-project-resolve.sh" --field yolo "$NAME")

case "$mode" in
  no-mistakes|direct-PR|local-only) ;;
  *) mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac

echo "$mode $yolo"
