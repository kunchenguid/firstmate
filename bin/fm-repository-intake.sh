#!/usr/bin/env bash
# fm-repository-intake.sh - daily, evidence-backed GitHub repository intake.
#
# Usage:
#   fm-repository-intake.sh [--json|--attention-fingerprint] [--refresh|--show]
#   fm-repository-intake.sh --record-outcome <trusted-json-file> [--json]
#
# The default is --refresh-if-due: once per Asia/Kolkata calendar day it reads
# every project registered in data/projects.md, resolves its local GitHub origin,
# and discovers all open issues and pull requests through gh-axi. The checkpoint
# is private fleet state under data/repository-intake/. docs/repository-intake.md
# owns the evidence, retention, authority, and recovery contracts.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

if ! command -v node >/dev/null 2>&1; then
  echo "fm-repository-intake: node not found" >&2
  exit 2
fi

exec node "$SCRIPT_DIR/fm-repository-intake.mjs" \
  --root "$FM_ROOT" \
  --home "$FM_HOME" \
  "$@"
