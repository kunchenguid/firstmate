#!/usr/bin/env bash
# Thin shim to the globally-installed `ledger` CLI (the canonical Frozen Gate
# Ledger harness). Computes nothing itself — the false-green guard (no born-green,
# mutation-on-freeze, baseline integrity) lives in `ledger`. "Done" = `ledger
# verify` leaves the WIP drain list empty (exit 0).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # -> repo root so test_ref paths resolve

if ! command -v ledger >/dev/null 2>&1; then
  echo "ledger CLI not on PATH — install via claude-pm-system/scripts/install-global.sh" >&2
  exit 2
fi

exec ledger verify --dir gates
