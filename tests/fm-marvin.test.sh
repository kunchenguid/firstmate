#!/usr/bin/env bash
# Quota pace rules, fake ports, CLI/JSONL composition, and static terminal layout.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node --test "$ROOT/modules/marvin/tests/"*.test.mjs
