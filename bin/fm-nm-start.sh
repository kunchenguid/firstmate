#!/usr/bin/env bash
# Start-only guard for no-mistakes. Reattach with `no-mistakes axi run` instead.
# Usage: fm-nm-start.sh [axi run flags...]
# Checks ALL runs on this repository/branch, regardless of head or age, using
# the read-only daemon database. Any run still active, or an unreadable
# inventory, refuses a new launch; a handed_off run is terminal for the worker
# (its CI monitoring ended with the PR open), so a new head may start a new
# run. The daemon remains the atomic branch-custody authority.
# NM_HOME and config/nm-home-resolver follow fm-nm-run-lib.sh for reads; launch
# keeps the ambient home, exactly like that library's other driving commands.
# No daemon administration, branch mutation, abort, or automatic gate answers.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  printf '%s\n' 'Usage: fm-nm-start.sh [axi run flags...]' \
    'Starts only when no run is busy on this repository/branch; unreadable state refuses.' \
    'For an existing run use no-mistakes axi run without new-run flags.'
  exit 0
fi
for arg in "$@"; do
  case "$arg" in --yes|-y) echo 'fm-nm-start: automatic gate answers are forbidden' >&2; exit 2 ;; esac
done
branch=$(git symbolic-ref --quiet --short HEAD) || { echo 'fm-nm-start: detached HEAD; refusing launch' >&2; exit 2; }
overview=$(fm_nm_run_checked "$PWD" 10 axi) || { echo 'fm-nm-start: run inventory unavailable; refusing launch' >&2; exit 2; }
repo=$(fm_nm_strip_quotes "$(fm_nm_field "$overview" repo)")
# Starts are never redirected by the read-only home resolver. Refuse if its
# database would describe a different home than the one the launch would use.
resolved=$(fm_nm_home_resolver_home "$PWD")
if [ -n "$resolved" ]; then
  echo 'fm-nm-start: set NM_HOME explicitly to the resolved home before launch' >&2
  exit 2
fi
python3 - "$repo" "$branch" "$(fm_nm_state_db "$PWD")" <<'PY'
import sqlite3
import sys
from contextlib import closing
from pathlib import Path

repo, branch, database = sys.argv[1:]
try:
    if not Path(repo).is_absolute():
        raise ValueError("repository identity unavailable")
    with closing(sqlite3.connect(Path(database).as_uri() + "?mode=ro", uri=True, timeout=5)) as db:
        repos = db.execute("SELECT id FROM repos WHERE working_path = ?", (repo,)).fetchall()
        if len(repos) != 1:
            raise ValueError("repository inventory ambiguous or unavailable")
        busy = db.execute(
            "SELECT id FROM runs WHERE repo_id = ? AND branch = ? "
            "AND (status IS NULL OR status NOT IN ('completed', 'failed', 'cancelled', 'handed_off'))",
            (repos[0][0], branch),
        ).fetchall()
    if busy:
        print("fm-nm-start: branch busy; reattach, do not start another run: " +
              ", ".join(str(row[0]) for row in busy), file=sys.stderr)
        sys.exit(2)
except (ValueError, OSError, sqlite3.Error) as error:
    print("fm-nm-start: unreadable run inventory; refusing launch: " + str(error), file=sys.stderr)
    sys.exit(2)
PY
exec no-mistakes axi run "$@"
