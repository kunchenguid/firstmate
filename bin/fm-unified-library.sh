#!/usr/bin/env bash
# fm-unified-library.sh - Firstmate adapter for OSBAMBAM Unified Library lookups.
#
# This is a thin read-only adapter. It does not copy, index, or store OSBAMBAM
# cards, sources, memory, or backlog state. Search, open, and trace call the
# existing OSBAMBAM library CLI. Recall calls the existing brain.js memory
# helper. Intake, promotion, and outcome writes stay with the OSBAMBAM
# Librarian/library owner; this adapter prints those commands and refuses to
# execute them.
#
# Usage:
#   fm-unified-library.sh recall "<query>"
#   fm-unified-library.sh search "<issue>"
#   fm-unified-library.sh open <CARD-ID>
#   fm-unified-library.sh trace <CARD-ID>
#   fm-unified-library.sh record-outcome <CARD-ID> {worked|failed|mixed|unknown}
#       [--evidence <text>] [--run-id <id>]
#   fm-unified-library.sh writes
#   fm-unified-library.sh --help
#
# Environment:
#   FM_OSBAMBAM_ROOT  OSBAMBAM root. Defaults to
#                     /Users/brycemajdick/Desktop/OSBAMBAM when that
#                     directory exists. library.py and brain.js are
#                     derived from it.
#
# Search always requests three cards and open always uses a 4000 budget, the
# contract's fixed lookup surface. The library CLI already orders
# verified cards first. When a search returns no verified card, the adapter
# reports that finding instead of inventing one. Draft cards remain prior art,
# not authority. record-outcome prints the library-owner command for the
# outcome rather than writing a local receipt.
# The script header owns these exact flags and paths; the unified-library
# skill owns when to load this adapter and how to treat the results.
set -euo pipefail

DEFAULT_OSBAMBAM_ROOT="/Users/brycemajdick/Desktop/OSBAMBAM"
SEARCH_LIMIT=3
OPEN_BUDGET=4000

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit "${1:-2}"
}

resolve_osbambam_root() {
  if [ -n "${FM_OSBAMBAM_ROOT:-}" ]; then
    printf '%s\n' "$FM_OSBAMBAM_ROOT"
    return 0
  fi
  if [ -d "$DEFAULT_OSBAMBAM_ROOT" ]; then
    printf '%s\n' "$DEFAULT_OSBAMBAM_ROOT"
    return 0
  fi
  die "OSBAMBAM root not found; set FM_OSBAMBAM_ROOT"
}

require_file() {
  local path=$1 label=$2
  [ -f "$path" ] || die "$label not found: $path"
}

print_writes() {
  local librarian_py="$OSBAMBAM_ROOT/os/scripts/librarian.py"
  cat <<EOF
This adapter does not write OSBAMBAM.
It does not copy cards, sources, memory, or backlog state.
Route source-linked research intake through the Librarian owner:
  python3 $librarian_py research <path>
Route source registration through the library owner:
  python3 $LIBRARY_PY intake <path>
Promote a card only through the library owner after its source locator, applicability, and cheapest rejection test are checked:
  python3 $LIBRARY_PY card-status <CARD-ID> verified --evidence <text>
Record an application outcome through the library owner:
  python3 $LIBRARY_PY record-outcome <CARD-ID> {worked|failed|mixed|unknown} [--evidence <text>] [--run-id <id>]
Memory recall remains read-only:
  node $BRAIN_JS recall "<query>"
EOF
}

annotate_search() {
  python3 -c '
import json
import sys

raw = sys.stdin.read()
try:
    data = json.loads(raw)
except json.JSONDecodeError as exc:
    sys.stderr.write("error: library search did not return JSON: %s\n" % exc)
    sys.stdout.write(raw)
    sys.exit(1)
if not isinstance(data, dict):
    sys.stderr.write("error: library search did not return a JSON object\n")
    sys.stdout.write(raw)
    sys.exit(1)
cards = data.get("cards") or []
if not isinstance(cards, list):
    cards = []
verified = [c for c in cards if isinstance(c, dict) and c.get("status") == "verified"]
if not verified:
    data["verified_finding"] = "no verified relevant card"
data["adapter"] = {
    "cards_are_not_authority_over_domain_gates": True,
    "drafts_are_prior_art": True,
}
json.dump(data, sys.stdout, indent=2, ensure_ascii=False, sort_keys=True)
sys.stdout.write("\n")
'
}

cmd_recall() {
  local query=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage 0 ;;
      --*) die "unknown recall option: $1" ;;
      *)
        [ -z "$query" ] || die "recall takes one query"
        query=$1
        shift
        ;;
    esac
  done
  [ -n "$query" ] || die "recall needs a query"
  require_file "$BRAIN_JS" "brain.js"
  command -v node >/dev/null 2>&1 || die "node is required for recall"
  node "$BRAIN_JS" recall "$query"
}

cmd_search() {
  local query=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage 0 ;;
      --*) die "unknown search option: $1" ;;
      *)
        [ -z "$query" ] || die "search takes one issue"
        query=$1
        shift
        ;;
    esac
  done
  [ -n "$query" ] || die "search needs an issue"
  require_file "$LIBRARY_PY" "library.py"
  command -v python3 >/dev/null 2>&1 || die "python3 is required for search"
  local out rc=0
  set +e
  out=$(python3 "$LIBRARY_PY" search "$query" --limit "$SEARCH_LIMIT")
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out"
    exit "$rc"
  fi
  printf '%s\n' "$out" | annotate_search
}

cmd_open() {
  local identifier=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage 0 ;;
      --*) die "unknown open option: $1" ;;
      *)
        [ -z "$identifier" ] || die "open takes one card id"
        identifier=$1
        shift
        ;;
    esac
  done
  [ -n "$identifier" ] || die "open needs a card id"
  require_file "$LIBRARY_PY" "library.py"
  python3 "$LIBRARY_PY" open "$identifier" --budget "$OPEN_BUDGET"
}

cmd_trace() {
  local identifier=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage 0 ;;
      --*) die "unknown trace option: $1" ;;
      *)
        [ -z "$identifier" ] || die "trace takes one card id"
        identifier=$1
        shift
        ;;
    esac
  done
  [ -n "$identifier" ] || die "trace needs a card id"
  require_file "$LIBRARY_PY" "library.py"
  python3 "$LIBRARY_PY" trace "$identifier"
}

cmd_record_outcome() {
  local card_id="" outcome="" evidence="" run_id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --evidence)
        [ -n "${2-}" ] || die "--evidence needs a value"
        evidence=$2
        shift 2
        ;;
      --run-id)
        [ -n "${2-}" ] || die "--run-id needs a value"
        run_id=$2
        shift 2
        ;;
      --help|-h) usage 0 ;;
      --*) die "unknown record-outcome option: $1" ;;
      *)
        if [ -z "$card_id" ]; then
          card_id=$1
        elif [ -z "$outcome" ]; then
          outcome=$1
        else
          die "record-outcome takes one card id and one outcome"
        fi
        shift
        ;;
    esac
  done
  [ -n "$card_id" ] || die "record-outcome needs a card id"
  case "$outcome" in
    worked|failed|mixed|unknown) ;;
    *) die "outcome must be worked, failed, mixed, or unknown" ;;
  esac
  local -a owner_cmd=(python3 "$LIBRARY_PY" record-outcome "$card_id" "$outcome")
  [ -z "$evidence" ] || owner_cmd+=(--evidence "$evidence")
  [ -z "$run_id" ] || owner_cmd+=(--run-id "$run_id")
  local rendered
  rendered=$(printf '%q ' "${owner_cmd[@]}")
  printf 'Outcome %s for %s is a library-owner write; this adapter does not execute it.\n' "$outcome" "$card_id"
  printf 'Record it through the library owner:\n  %s\n' "${rendered% }"
}

[ "$#" -gt 0 ] || usage 2
case "$1" in
  -h|--help) usage 0 ;;
esac

OSBAMBAM_ROOT="$(resolve_osbambam_root)"
LIBRARY_PY="$OSBAMBAM_ROOT/os/scripts/library.py"
BRAIN_JS="$OSBAMBAM_ROOT/rubric-second-brain/brain.js"

case "$1" in
  recall) shift; cmd_recall "$@" ;;
  search) shift; cmd_search "$@" ;;
  open) shift; cmd_open "$@" ;;
  trace) shift; cmd_trace "$@" ;;
  record-outcome) shift; cmd_record_outcome "$@" ;;
  writes) print_writes ;;
  *)
    printf 'error: unknown command: %s\n' "$1" >&2
    print_writes >&2
    exit 2
    ;;
esac
