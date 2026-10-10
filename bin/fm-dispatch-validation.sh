#!/usr/bin/env bash
# fm-dispatch-validation.sh - opt-in resolved dispatch validation wire owner.
# Usage: fm-dispatch-validation.sh VALIDATOR SNAPSHOT HOME STATE DATA CONFIG
#        ID KIND PROJECT MODE BASE EFFECTIVE_BRIEF
# --help prints this contract. Called only for fresh ship/scout spawns when
# CONFIG/dispatch-validator exists (including a dangling symlink). It must be
# a readable executable regular file. Absence adds no dependency or subprocess.
# Relaunch, promotion and secondmate dispatch are outside this first version.
#
# Requires python3 only when configured. The validator receives one UTF-8 JSON
# object on stdin, schema_version=1, with home, state_dir, data_dir, config_dir,
# task_id, kind, project, delivery_mode, base_branch, relaunch=false,
# effective_brief_path, brief_sha256 and request_sha256. Empty non-applicable
# fields are null.
# request_sha256 hashes the UTF-8, sorted-key, compact JSON object before adding
# request_sha256 (ensure_ascii=false); brief_sha256 hashes the exact brief bytes.
#
# Within 5 seconds the executable must exit 0 and emit exactly one JSON object:
# {"schema_version":1,"decision":"allow","request_sha256":"<request digest>"}
# "refuse" is the only other decision. Extra keys, duplicate keys, non-JSON,
# wrong types/digests, nonzero exit, timeout and I/O errors all refuse. Stdout
# and stderr each have a 65536-byte limit; stderr is forwarded as the diagnostic.
# The timeout uses fm_run_timed, including its process-group cleanup.
#
# Changes to the effective brief during validation or before launch refuse.
# On allow, SNAPSHOT
# receives the accepted bytes with mode 0400; spawn delivers this private,
# uniquely named copy on every harness/backend path, retaining it for readers
# that consume a path after launch. A later brief-change refusal uses spawn's
# existing abort cleanup; an already allocated endpoint/worktree may remain
# for recovery, but no worker is launched. The validator is trusted local policy,
# not a security sandbox against other processes running as the home owner.
set -u
if [ "${1:-}" = --help ]; then
  sed -n '2,/^set -u/{ /^set -u/d; s/^# \{0,1\}//; p; }' "$0"
  exit 0
fi
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ "$#" -ne 12 ]; then
  echo 'error: dispatch validation needs a resolved dispatch' >&2
  exit 1
fi
if [ ! -f "$1" ] || [ ! -r "$1" ] || [ ! -x "$1" ]; then
  echo "error: dispatch validator must be a readable executable regular file: $1" >&2
  exit 1
fi
command -v python3 >/dev/null 2>&1 || {
  echo 'error: configured dispatch validation requires python3' >&2
  exit 1
}
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
status=0
fm_run_timed 5 python3 "$SCRIPT_DIR/fm-dispatch-validation.py" "$@" || status=$?
if [ "$status" -ne 0 ]; then
  echo "error: dispatch validation refused (exit $status): $1" >&2
  exit 1
fi
