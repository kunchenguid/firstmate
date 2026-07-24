#!/usr/bin/env bash
# Launch the FirstMate primary Pi session with explicit xhigh thinking.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

for arg in "$@"; do
  case "$arg" in
    --thinking|--thinking=*)
      echo "error: fm-pi-primary.sh owns the primary Pi thinking level (xhigh)" >&2
      exit 2
      ;;
  esac
done

cd "$FM_ROOT"
exec pi --thinking xhigh "$@"
