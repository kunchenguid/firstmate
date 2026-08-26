#!/usr/bin/env bash
set -u
ROOT=/tmp/fmrepro/repo
TMP_ROOT=$(mktemp -d /tmp/fmid.XXXXXX)
REMOTE_ROOT="$TMP_ROOT/remote-root"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
mkdir -p "$REMOTE_ROOT/bin" "$ACCOUNT_HOME"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export HOME="$ACCOUNT_HOME"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
. "$ROOT/bin/fm-remote-job-lib.sh"
echo "--- compose_operator_path:"
if fm_remote_job_compose_operator_path "$ACCOUNT_HOME"; then echo "compose OK"; else echo "compose FAILED"; fi
echo "OPERATOR_PATH=$FM_REMOTE_JOB_OPERATOR_PATH"
echo "--- operator_tool git:"
git_bin=$(fm_remote_job_operator_tool git) && echo "git_bin=$git_bin" || echo "operator_tool git FAILED"
echo "--- hash-object root string:"
printf '%s' "$REMOTE_ROOT" | "$git_bin" hash-object --stdin || echo "root hash FAILED rc=$?"
echo "--- hash-object lib file:"
"$git_bin" hash-object -- "$REMOTE_ROOT/bin/fm-remote-job-lib.sh" || echo "lib hash FAILED rc=$?"
echo "--- full identity:"
if out=$(fm_remote_job_code_identity "$REMOTE_ROOT" "$ACCOUNT_HOME"); then
  echo "identity OK: $out"
else
  echo "identity FAILED"
fi
echo "--- verbose retrace:"
set -x
fm_remote_job_code_identity "$REMOTE_ROOT" "$ACCOUNT_HOME" || true
set +x
rm -rf "$TMP_ROOT"
