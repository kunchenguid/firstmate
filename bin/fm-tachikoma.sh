#!/usr/bin/env bash
# Manual routing CLI; --help and the module README own its public interface.
set -eu
exec node "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/modules/tachikoma/src/adapters/cli.mjs" "$@"
