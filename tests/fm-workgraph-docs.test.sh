#!/usr/bin/env bash
# Focused documentation ownership checks for the portable WorkGraph surface.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

require_text() {
  local file=$1 text=$2 label=$3
  [ -f "$file" ] && [ ! -L "$file" ] || fail "$label file"
  grep -Fq -- "$text" "$file" || fail "$label text"
}

require_text "$ROOT/docs/configuration.md" \
  '## WorkGraph storage and parallelism' 'configuration owner'
require_text "$ROOT/docs/configuration.md" \
  'config/parallelism' 'parallelism persistence'
require_text "$ROOT/docs/configuration.md" \
  'fm-workgraph-migrate.sh rebuild-state' 'rebuild owner'
pass 'configuration owns WorkGraph persistence and rebuild state'

require_text "$ROOT/docs/scripts.md" \
  'fm-parallelism.sh' 'parallelism script inventory'
require_text "$ROOT/docs/scripts.md" \
  'fm-workgraph.sh' 'workgraph script inventory'
require_text "$ROOT/docs/scripts.md" \
  'fm-workgraph-migrate.sh' 'migration script inventory'
require_text "$ROOT/docs/scripts.md" \
  'fm-workgraph-dispatch-lib.sh' 'dispatch library inventory'
require_text "$ROOT/docs/scripts.md" \
  'fm-workgraph-gate-lib.sh' 'gate library inventory'
pass 'script inventory names every WorkGraph command owner'

require_text "$ROOT/docs/workgraph.md" \
  'is accepted only in command-line mode positions and is persisted and reported as' \
  'canonical on mode'
require_text "$ROOT/docs/workgraph.md" \
  'fm-spawn.sh` is the contract-bound enforcement point' \
  'dispatch enforcement'
require_text "$ROOT/docs/workgraph.md" \
  'Audit slices are read-only.' 'audit ownership'
require_text "$ROOT/docs/workgraph.md" \
  'legacy active record as broadly exclusive' 'legacy fail closed'
require_text "$ROOT/docs/workgraph.md" \
  'lock://FIRSTMATE-INTEGRATION' 'integration serialization'
pass 'operator contract owns mode, admission, audit, legacy, and integration invariants'

bash "$ROOT/bin/fm-parallelism.sh" --help >/dev/null \
  || fail 'parallelism help'
bash "$ROOT/bin/fm-workgraph.sh" --help >/dev/null \
  || fail 'workgraph help'
bash "$ROOT/bin/fm-workgraph-migrate.sh" --help >/dev/null \
  || fail 'migration help'
pass 'documented WorkGraph command surfaces expose help'
