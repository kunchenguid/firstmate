#!/usr/bin/env bash
# fm-artifact-manifest.sh - write, verify, or reference a worker's artifact manifest.
#
# A worker's result is its artifacts, not its chat. This entry point writes the
# machine-readable manifest the parent channel points at, verifies it by
# recomputing every hash, or prints the parent-channel reference. Kinds are a
# closed allowlist (patch, test-log, review-report, report, trace) owned by
# bin/fm-artifact-lib.sh; a transcript, chat log, or session dump is refused.
#
# Usage:
#   fm-artifact-manifest.sh write --task <id> --artifact <kind>=<path> [--artifact ...]
#   fm-artifact-manifest.sh verify --task <id>
#   fm-artifact-manifest.sh ref --task <id>
#
# <path> is the home-relative data/<id>/... form. `write` stores the manifest at
# data/<id>/artifacts.json and prints its path; `verify` re-hashes every entry
# and prints the reason on failure; `ref` prints the parent-channel suffix
# `artifacts=data/<id>/artifacts.json artifacts_sha256=<hex>` only when the
# manifest verifies.
#
# Exit codes:
#   0  success
#   2  usage or invalid task id
#   3  an artifact kind is not allowed, or its path is missing, unsafe, or
#      outside data/<task>/
#   4  hashing or writing the manifest failed
#   5  the manifest does not verify
#
# Keep artifact output under $DATA/$ID/: ship briefs already allow that, and the
# scout brief allows it alongside the report and status file.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-artifact-lib.sh
. "$SCRIPT_DIR/fm-artifact-lib.sh"

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# //; s/^#$//'
}

COMMAND=
TASK=
ARTIFACTS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    write|verify|ref)
      [ -z "$COMMAND" ] || { echo "error: more than one command given" >&2; exit 2; }
      COMMAND=$1
      shift
      ;;
    --task)
      [ "$#" -ge 2 ] || { echo "error: --task needs a value" >&2; exit 2; }
      TASK=$2
      shift 2
      ;;
    --artifact)
      [ "$#" -ge 2 ] || { echo "error: --artifact needs <kind>=<path>" >&2; exit 2; }
      ARTIFACTS+=("$2")
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[ -n "$COMMAND" ] || { usage >&2; exit 2; }
fm_artifact_task_valid "$TASK" || { echo "error: invalid task id: ${TASK:-<empty>}" >&2; exit 2; }
[ -d "$DATA" ] || { echo "error: data directory is unavailable: $DATA" >&2; exit 2; }

case "$COMMAND" in
  write)
    [ "${#ARTIFACTS[@]}" -gt 0 ] || { echo "error: write needs at least one --artifact" >&2; exit 2; }
    manifest=$(fm_artifact_manifest_write "$DATA" "$TASK" "${ARTIFACTS[@]}")
    rc=$?
    case "$rc" in
      0) printf '%s\n' "$manifest" ;;
      2) echo "error: invalid task id" >&2; exit 2 ;;
      3) echo "error: artifact kind is not allowed, or its path is missing, unsafe, or outside data/$TASK/" >&2; exit 3 ;;
      4) echo "error: hashing an artifact failed" >&2; exit 4 ;;
      *) echo "error: cannot write data/$TASK/artifacts.json" >&2; exit 4 ;;
    esac
    ;;
  verify)
    if reason=$(fm_artifact_manifest_verify "$DATA" "$TASK" "$DATA/$TASK/artifacts.json"); then
      printf 'verified: data/%s/artifacts.json\n' "$TASK"
    else
      printf 'error: %s\n' "${reason:-manifest does not verify}" >&2
      exit 5
    fi
    ;;
  ref)
    fm_artifact_manifest_ref "$DATA" "$TASK"
    ;;
esac
