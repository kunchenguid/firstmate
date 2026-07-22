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

if ! fm_delivery_validate_id "$ID"; then
  echo "error: invalid task id: $ID" >&2
  exit 2
fi
case "$SEQ" in ''|*[!0-9]*) echo "error: seq must be a non-negative integer" >&2; exit 2 ;; esac
if ! fm_delivery_validate_id "$ADAPTER"; then
  echo "error: invalid evidence adapter: $ADAPTER" >&2
  exit 2
fi
case " $(fm_delivery_phase_list) " in
  *" $PHASE "*) ;;
  *) echo "error: invalid delivery phase: $PHASE" >&2; exit 2 ;;
esac

EV_PARENT="$DATA/$ID/evidence"
EV_DIR="$EV_PARENT/$SEQ-$ADAPTER"
EV_LOCK="$EV_PARENT/.$SEQ-$ADAPTER.lock"
EV_STAGE=

cleanup_evidence_stage() {
  [ -z "$EV_STAGE" ] || rm -rf "$EV_STAGE"
  rmdir "$EV_LOCK" 2>/dev/null || true
}

run_evidence() {
  local start_at end_at exit_code meta tmp_stdout tmp_stderr candidate_sha manifest_hash
  mkdir -p "$EV_PARENT" || return 1
  chmod 700 "$DATA/$ID" "$EV_PARENT" || return 1
  if ! mkdir "$EV_LOCK" 2>/dev/null; then
    echo "error: evidence sequence $SEQ-$ADAPTER is busy or already publishing for $ID" >&2
    return 1
  fi
  trap cleanup_evidence_stage EXIT HUP INT TERM
  [ ! -e "$EV_DIR" ] || { echo "error: evidence sequence $SEQ-$ADAPTER already exists for $ID" >&2; return 1; }
  EV_STAGE=$(mktemp -d "$EV_PARENT/.tmp.$SEQ-$ADAPTER.XXXXXX") || return 1
  chmod 700 "$EV_STAGE" || return 1

  # Decode JSON argv with python3 and execute via python3 subprocess to avoid
  # shell evaluation entirely. The command runs in the task worktree if one can
  # be discovered from metadata, else the current directory.
  local wt=
  if [ -f "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$ID.meta" ]; then
    wt=$(grep '^worktree=' "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$ID.meta" | cut -d= -f2- || true)
  fi
  [ -n "$wt" ] && [ -d "$wt" ] || wt=$PWD

  tmp_stdout="$EV_STAGE/stdout.txt"
  tmp_stderr="$EV_STAGE/stderr.txt"
  start_at=$(fm_delivery_timestamp)
  exit_code=$(python3 - "$wt" "$tmp_stdout" "$tmp_stderr" "$ARGV_JSON" <<'PYEOF'
import json, sys, subprocess, os
wt, out_path, err_path, argv_json = sys.argv[1:5]
try:
    argv = json.loads(argv_json)
    if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
        raise ValueError("argv must be a non-empty JSON array of strings")
    if os.path.basename(argv[0]) in {"sh", "bash", "dash", "zsh", "fish"}:
        raise ValueError("shell interpreters are not valid deterministic evidence commands")
except Exception as e:
    print(f"error: invalid argv JSON: {e}", file=sys.stderr)
    sys.exit(2)
with open(out_path, "w") as out_f, open(err_path, "w") as err_f:
    try:
        result = subprocess.run(argv, cwd=wt, stdout=out_f, stderr=err_f, text=True, check=False)
        print(result.returncode if result.returncode >= 0 else 128 + (-result.returncode))
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
    return 1
  fi
  if ! fm_delivery_redact_volatile_provider_fields "$tmp_stderr"; then
    return 1
  fi

  candidate_sha=$(grep '^candidateSha=' "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$ID.meta" 2>/dev/null | cut -d= -f2- || true)
  if [ -z "$candidate_sha" ] && { [ -d "$wt/.git" ] || [ -f "$wt/.git" ]; }; then
    candidate_sha=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null || true)
  fi
  if ! fm_delivery_validate_sha "$candidate_sha"; then
    echo "error: evidence requires an exact candidate SHA from task metadata or worktree HEAD" >&2
    return 1
  fi
  candidate_sha=$(fm_delivery_sha_lower "$candidate_sha")

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
    "files": ["stdout.txt", "stderr.txt"]
}
print(json.dumps(doc, indent=2))
PYEOF
)
  printf '%s\n' "$meta" > "$EV_STAGE/meta.json" || return 1
  manifest_hash=$(fm_delivery_write_manifest "$EV_STAGE" "$EV_STAGE/MANIFEST.sha256") || return 1
  chmod 400 "$EV_STAGE/stdout.txt" "$EV_STAGE/stderr.txt" "$EV_STAGE/meta.json" "$EV_STAGE/MANIFEST.sha256" || return 1
  mv "$EV_STAGE" "$EV_DIR" || return 1
  EV_STAGE=
  rmdir "$EV_LOCK" || return 1
  trap - EXIT HUP INT TERM

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
