#!/usr/bin/env bash
# fm-refresh-ci-timings.sh - rebuild tests/fm-test-ci-timings.tsv from measured
# CI timing artifacts.
#
# The shard packer in bin/fm-test-run.sh reads that file. Each row is the
# slowest successful duration_ms for one tests/*.test.sh across the selected
# green main runs. Failed or cancelled scripts are ignored, so a timeout does
# not become a packing weight.
#
# Usage:
#   fm-refresh-ci-timings.sh --from-dir <dir> [--out <path>]
#   fm-refresh-ci-timings.sh --from-main [--limit <n>] [--repo <owner/name>] [--out <path>]
#   fm-refresh-ci-timings.sh --runs <id,id,...> [--repo <owner/name>] [--out <path>]
#   fm-refresh-ci-timings.sh --help
#
# --from-dir walks an already-downloaded artifact tree (the same layout
# `gh run download` writes) and does not talk to the network.
# --from-main lists the newest successful main CI runs with `gh run list` and
# downloads their fm-test-timing-* artifacts.
# --runs downloads the named run ids.
# Default --out is tests/fm-test-ci-timings.tsv under this repository.
# Default --limit is 3. Default --repo is kunchenguid/firstmate.
#
# Exit status: 0 wrote the table, 2 usage or missing tools/input.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-refresh-ci-timings: %s\n' "$*" >&2
  exit 2
}

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SELF_DIR/.." && pwd -P)"
MODE=
FROM_DIR=
RUNS=
LIMIT=3
REPO=kunchenguid/firstmate
OUT="$ROOT/tests/fm-test-ci-timings.tsv"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --from-dir)
      [ "$#" -ge 2 ] || die "--from-dir requires a directory"
      MODE=from-dir
      FROM_DIR=$2
      shift 2
      ;;
    --from-dir=*)
      MODE=from-dir
      FROM_DIR=${1#*=}
      shift
      ;;
    --from-main)
      MODE=from-main
      shift
      ;;
    --runs)
      [ "$#" -ge 2 ] || die "--runs requires a comma-separated list of run ids"
      MODE=runs
      RUNS=$2
      shift 2
      ;;
    --runs=*)
      MODE=runs
      RUNS=${1#*=}
      shift
      ;;
    --limit)
      [ "$#" -ge 2 ] || die "--limit requires a positive integer"
      LIMIT=$2
      shift 2
      ;;
    --limit=*)
      LIMIT=${1#*=}
      shift
      ;;
    --repo)
      [ "$#" -ge 2 ] || die "--repo requires owner/name"
      REPO=$2
      shift 2
      ;;
    --repo=*)
      REPO=${1#*=}
      shift
      ;;
    --out)
      [ "$#" -ge 2 ] || die "--out requires a path"
      OUT=$2
      shift 2
      ;;
    --out=*)
      OUT=${1#*=}
      shift
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$MODE" ] || die "select --from-dir, --from-main, or --runs (see --help)"
case "$LIMIT" in
  ''|*[!0-9]*|0) die "--limit must be a positive integer, got ${LIMIT:-<empty>}" ;;
esac

aggregate_dir() {  # <dir> <out> <source-label>
  local dir=$1 out=$2 label=$3
  [ -d "$dir" ] || die "artifact directory not found: $dir"
  command -v python3 >/dev/null 2>&1 || die "python3 is required to read timing JSON"
  python3 - "$dir" "$out" "$label" <<'PY'
import json, sys
from pathlib import Path

root = Path(sys.argv[1])
out = Path(sys.argv[2])
label = sys.argv[3]
max_ms = {}
json_files = list(root.rglob("*.json"))
if not json_files:
    sys.exit("fm-refresh-ci-timings: no JSON files under " + str(root))
for path in json_files:
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        continue
    if not isinstance(doc, dict) or doc.get("kind") == "aggregate":
        continue
    for row in doc.get("scripts") or []:
        script = row.get("path") or ""
        if not script.startswith("tests/") or not script.endswith(".test.sh"):
            continue
        try:
            exit_code = int(row.get("exit") or 0)
            duration = int(row.get("duration_ms") or 0)
        except (TypeError, ValueError):
            continue
        if exit_code != 0 or duration < 0:
            continue
        if duration >= max_ms.get(script, -1):
            max_ms[script] = duration
if not max_ms:
    sys.exit("fm-refresh-ci-timings: no successful script timings in " + str(root))
lines = [
    "# Firstmate CI portable timing hints.",
    "# Each duration_ms is the slowest successful sample of that tests/*.test.sh",
    "# script across the listed green main CI runs.",
    "# bin/fm-test-run.sh reads this file to pack portable parallel and serial shards.",
    "# Refresh with: bin/fm-refresh-ci-timings.sh --from-dir <downloaded-artifacts>",
    "# or: bin/fm-refresh-ci-timings.sh --from-main --limit 3",
    f"# source_runs: {label}",
    "# refreshed: " + __import__("datetime").date.today().isoformat(),
    "path\tduration_ms",
]
for script in sorted(max_ms):
    lines.append(f"{script}\t{max_ms[script]}")
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"fm-refresh-ci-timings: wrote {out} scripts={len(max_ms)}")
PY
}

download_runs() {  # <comma-ids> <dest>
  local ids=$1 dest=$2 id rest
  command -v gh >/dev/null 2>&1 || die "gh is required to download CI artifacts"
  mkdir -p "$dest"
  rest=$ids
  [ -n "$rest" ] || die "--runs listed no run ids"
  while [ -n "$rest" ]; do
    case "$rest" in
      *,*)
        id=${rest%%,*}
        rest=${rest#*,}
        ;;
      *)
        id=$rest
        rest=
        ;;
    esac
    case "$id" in
      ''|*[!0-9]*) die "run id must be numeric, got ${id:-<empty>}" ;;
    esac
    gh run download "$id" -R "$REPO" --dir "$dest/$id" --pattern 'fm-test-timing-*' \
      || die "failed to download timing artifacts for run $id"
  done
}

case "$MODE" in
  from-dir)
    aggregate_dir "$FROM_DIR" "$OUT" "local-dir"
    ;;
  from-main)
    command -v gh >/dev/null 2>&1 || die "gh is required to list main CI runs"
    command -v python3 >/dev/null 2>&1 || die "python3 is required to parse gh JSON"
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-refresh-ci-timings.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT
    ids=$(gh run list -R "$REPO" --branch main --workflow CI --status success \
      --limit "$LIMIT" --json databaseId \
      | python3 -c 'import json,sys; print(",".join(str(r["databaseId"]) for r in json.load(sys.stdin)))')
    [ -n "$ids" ] || die "no successful main CI runs found for $REPO"
    download_runs "$ids" "$tmp/artifacts"
    aggregate_dir "$tmp/artifacts" "$OUT" "$ids"
    ;;
  runs)
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-refresh-ci-timings.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT
    download_runs "$RUNS" "$tmp/artifacts"
    aggregate_dir "$tmp/artifacts" "$OUT" "$RUNS"
    ;;
esac
