#!/usr/bin/env bash
# fm-lndev-captain-broker.sh - firstmate-local lndev attach-as-captain broker.
#
# Subcommands:
#   serve                         listen on $FM_HOME/state/lndev-captain.sock
#   mint                          mint a hashed capability handle after strict lndev probes
#   verify-audit                  verify the local hash-chained audit log
#
# Mechanics and schemas live under bin/fm-lndev-captain-broker/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec node "$ROOT/bin/fm-lndev-captain-broker/src/cli.mjs" "$@"
