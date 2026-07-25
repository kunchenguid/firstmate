#!/usr/bin/env bash
exec python3 "$(cd "$(dirname "$0")/.." && pwd)/phase2/lib/eventd.py" --home "${FM_HOME:-$(cd "$(dirname "$0")/.." && pwd)}" "$@"
