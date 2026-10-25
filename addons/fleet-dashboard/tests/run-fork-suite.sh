#!/usr/bin/env bash
# Runs the moved fm-dashboard behavior suite against this add-on's dashboard.
# Takes a Firstmate checkout (argument or FM_FIRSTMATE_DIR; with neither, a
# fresh clone), clones it into a scratch tree, swaps in this add-on's
# fm-dashboard.sh, its fm-dashboard/ app and the moved test, runs the test
# there and exits with its status.
set -eu

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ADDON=$(dirname "$HERE")

FORK=${1:-${FM_FIRSTMATE_DIR:-https://github.com/umeranjum17/firstmate}}
case "$FORK" in
  *://*) ;;
  *) FORK="file://$(cd "$FORK" && pwd)" ;;
esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-dashboard-fork-suite.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
TREE="$TMP/firstmate"

git clone --depth 1 --quiet "$FORK" "$TREE"

rm -rf "$TREE/bin/fm-dashboard"
cp "$ADDON/fm-dashboard.sh" "$TREE/bin/fm-dashboard.sh"
cp "$ADDON/task_rows.py" "$TREE/bin/task_rows.py"
cp -R "$ADDON/fm-dashboard" "$TREE/bin/fm-dashboard"
cp "$HERE/fm-dashboard.test.sh" "$TREE/tests/fm-dashboard.test.sh"
chmod +x "$TREE/bin/fm-dashboard.sh" "$TREE/tests/fm-dashboard.test.sh"

cd "$TREE"
FM_ADDONS_DIR=$(cd "$ADDON/.." && pwd) bash tests/fm-dashboard.test.sh
