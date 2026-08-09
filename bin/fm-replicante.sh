#!/usr/bin/env bash
# fm-replicante.sh - maintain the incremental Firstmate backup on H:.
#
# The normal destination is exactly /mnt/h/Firstmate-Backup.
# The source is exactly /home/ale/firstmate.
# run creates content-addressed objects and immutable full-tree snapshot
# manifests, so changed bytes are copied once and deleted source paths remain
# available through older snapshots.
# verify checks snapshot and object hashes; --restore-test also reconstructs a
# temporary tree and compares its content and symbolic links.
# restore writes one selected snapshot to a new H: recovery directory.
#
# Normal operation does not accept source or destination overrides.
# Tests use REPLICANTE_TEST_MODE=1 with explicit temporary fixture paths.
#
# Usage:
#   fm-replicante.sh run [--retain <count>]
#   fm-replicante.sh verify [--snapshot <id>] [--all] [--restore-test]
#   fm-replicante.sh restore --snapshot <id> --output <directory> [--apply-modes]
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-replicante.py" "$@"
