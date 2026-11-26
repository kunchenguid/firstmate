#!/usr/bin/env bash
# Token-free cockpit truth pass; cockpit-sync.py --help owns the mechanics.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I "$here/cockpit-sync.py" "$@"
