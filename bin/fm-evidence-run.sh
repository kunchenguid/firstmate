#!/usr/bin/env bash
# Hashed write-once deterministic evidence execution.
# Usage:
#   fm-evidence-run.sh run <task-id> <phase> <seq> <adapter> <argv-json-array>
#
# Executes the argv without shell evaluation, writes stdout/stderr/metadata to
# data/<id>/evidence/<seq>-<adapter>/, hashes every file plus a manifest, and
# refuses to overwrite an existing sequence. Adapter ids are versioned so a
# receipt can name the exact validator that consumed the evidence.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-delivery-lib.sh
. "$SCRIPT_DIR/fm-delivery-lib.sh"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -ge 6 ] || { usage >&2; exit 2; }
CMD=$1
ID=$2
PHASE=$3
SEQ=$4
ADAPTER=$5
ARGV_JSON=$6

if ! printf '%s' "$ID" | grep -qxE '[A-Za-z0-9._-]+'; then
  echo "error: invalid task id: $ID" >&2
  exit 2
fi
case "$SEQ" in ''|*[!0-9]*) echo "error: seq must be a non-negative integer" >&2; exit 2 ;; esac

EV_DIR="$DATA/$ID/evidence/$SEQ-$ADAPTER"
[ -e "$EV_DIR" ] && { echo "error: evidence sequence $SEQ-$ADAPTER already exists for $ID" >&2; exit 1; }

run_evidence() {
  local start_at end_at exit_code meta tmp_stdout tmp_stderr
  mkdir -p "$EV_DIR"
  chmod 700 "$EV_DIR"

  # Decode JSON argv with python3 and execute via python3 subprocess to avoid
  # shell evaluation entirely. The command runs in the task worktree if one can
  # be discovered from metadata, else the current directory.
  local wt=
  if [ -f "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$ID.meta" ]; then
    wt=$(grep '^worktree=' "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$ID.meta" | cut -d= -f2- || true)
  fi
  [ -n "$wt" ] && [ -d "$wt" ] || wt=$PWD

  tmp_stdout=$(mktemp)
  tmp_stderr=$(mktemp)
  start_at=$(fm_delivery_timestamp)
  exit_code=$(python3 - "$wt" "$tmp_stdout" "$tmp_stderr" "$ARGV_JSON" <<'PYEOF'
import json, sys, subprocess, os
wt, out_path, err_path, argv_json = sys.argv[1:5]
try:
    argv = json.loads(argv_json)
    if not isinstance(argv, list) or not all(isinstance(a, str) for a in argv):
        raise ValueError("argv must be a JSON array of strings")
except Exception as e:
    print(f"error: invalid argv JSON: {e}", file=sys.stderr)
    sys.exit(2)
with open(out_path, "w") as out_f, open(err_path, "w") as err_f:
    try:
        result = subprocess.run(argv, cwd=wt, stdout=out_f, stderr=err_f, text=True, check=False)
        print(result.returncode)
    except FileNotFoundError:
        print(127)
    except Exception as e:
        err_f.write(f"evidence-run error: {e}\n")
        print(1)
PYEOF
)
  end_at=$(fm_delivery_timestamp)

  # Refuse volatile provider fields before publication.
  if ! fm_delivery_redact_volatile_provider_fields "$tmp_stdout"; then
    rm -f "$tmp_stdout" "$tmp_stderr"
    return 1
  fi
  if ! fm_delivery_redact_volatile_provider_fields "$tmp_stderr"; then
    rm -f "$tmp_stdout" "$tmp_stderr"
    return 1
  fi

  mv "$tmp_stdout" "$EV_DIR/stdout.txt"
  mv "$tmp_stderr" "$EV_DIR/stderr.txt"

  candidate_sha=$(grep '^candidateSha=' "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$ID.meta" 2>/dev/null | cut -d= -f2- || true)
  candidate_sha=${candidate_sha:-unknown}

  meta=$(python3 - "$ID" "$PHASE" "$SEQ" "$ADAPTER" "$ARGV_JSON" "$start_at" "$end_at" "$exit_code" "$candidate_sha" <<'PYEOF'
import json, sys
id, phase, seq, adapter, argv_json, started, completed, exit_code, candidate_sha = sys.argv[1:10]
try:
    argv = json.loads(argv_json)
except Exception:
    argv = []
doc = {
    "schemaVersion": "firstmate.evidence-run.v1",
    "taskId": id,
    "phase": phase,
    "sequence": int(seq),
    "adapter": adapter,
    "argv": argv,
    "startedAt": started,
    "completedAt": completed,
    "exitCode": int(exit_code),
    "candidateSha": candidate_sha,
    "files": []
}
print(json.dumps(doc, indent=2))
PYEOF
)
  printf '%s\n' "$meta" > "$EV_DIR/meta.json"

  # Hash every file and append to meta.json.
  local manifest
  manifest=$(cd "$EV_DIR" && find . -type f | sort | while IFS= read -r rel; do
    rel=${rel#./}
    [ -n "$rel" ] || continue
    printf '%s  %s\n' "$(fm_delivery_file_hash "$EV_DIR/$rel")" "$rel"
  done)
  printf '%s\n' "$manifest" > "$EV_DIR/MANIFEST.sha256"
  local manifest_hash
  manifest_hash=$(printf '%s\n' "$manifest" | sha256sum | awk '{print $1}')

  # Update meta.json with manifest hash.
  local tmp_meta
  tmp_meta=$(mktemp)
  printf '%s\n' "$meta" > "$tmp_meta"
  meta=$(python3 - "$manifest_hash" "$tmp_meta" <<'PYEOF'
import json, sys
manifest_hash, meta_path = sys.argv[1:3]
with open(meta_path) as f:
    meta = json.loads(f.read())
meta["manifestSha256"] = manifest_hash
print(json.dumps(meta, indent=2))
PYEOF
)
  rm -f "$tmp_meta"
  printf '%s\n' "$meta" > "$EV_DIR/meta.json"

  chmod 400 "$EV_DIR/stdout.txt" "$EV_DIR/stderr.txt" "$EV_DIR/meta.json" "$EV_DIR/MANIFEST.sha256"

  echo "$EV_DIR"
  echo "manifestSha256=$manifest_hash"
  if [ "$exit_code" -ne 0 ]; then
    return "$exit_code"
  fi
  return 0
}

case "$CMD" in
  run) run_evidence ;;
  *) usage >&2; exit 2 ;;
esac
